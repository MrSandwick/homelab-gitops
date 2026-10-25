#!/usr/bin/env bash
# Backs up cluster state to /var/backups/homelab on the control plane.
# Run as root from cron (needs /etc/kubernetes). Keeps the last 7 good backups.
#
# Critical steps: etcd snapshot, control-plane certificates, manifests.
#   If one fails, the folder is renamed *-FAILED and never counts as a backup.
# Optional step: Grafana data (needs the worker). A failure gives status PARTIAL.
# Rotation always runs. PARTIAL and FAIL are reported to Slack directly.
set -uo pipefail
umask 077

CLUSTER="homelab"
export KUBECONFIG=/etc/kubernetes/admin.conf
DEST=/var/backups/homelab
KEEP=7
SLACK_URL_FILE=/etc/homelab-deadman/slack-url
GRAFANA_PVC="${GRAFANA_PVC:-prometheus-grafana}"        # overridable for tests
GRAFANA_TIMEOUT="${GRAFANA_TIMEOUT:-120s}"

OUT="$DEST/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
chmod 700 "$DEST" "$OUT"
# always hand the files back to the admin user, even if a step fails
trap 'chown -R baatyr:baatyr "$DEST"' EXIT

failed_critical=()
failed_optional=()

step() {   # step <critical|optional> <name> <function>
  local kind=$1 name=$2 fn=$3
  echo "--- $name"
  if "$fn"; then
    echo "    ok"
  else
    echo "    FAILED"
    if [ "$kind" = critical ]; then failed_critical+=("$name"); else failed_optional+=("$name"); fi
  fi
}

# 1. etcd snapshot (contains every Secret in clear text: keep the backup private)
backup_etcd() {
  kubectl -n kube-system exec etcd-mgktec-master -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/lib/etcd/backup-snapshot.db \
  && mv /var/lib/etcd/backup-snapshot.db "$OUT/etcd-snapshot.db"
}

# 2. control-plane certificates
backup_pki() {
  tar czf "$OUT/pki.tar.gz" -C /etc/kubernetes pki
}

# 3. Helm values and manifests
backup_manifests() {
  tar czf "$OUT/k8s-manifests.tar.gz" -C /home/baatyr k8s-manifests
}

# 4. Grafana data: a short-lived pod mounts the volume read-only (the Grafana image has no tar)
backup_grafana() {
  local rc=0
  kubectl -n monitoring delete pod grafana-backup --ignore-not-found > /dev/null
  kubectl -n monitoring apply -f - <<POD || return 1
apiVersion: v1
kind: Pod
metadata:
  name: grafana-backup
  namespace: monitoring
spec:
  restartPolicy: Never
  containers:
    - name: backup
      image: busybox:1.36
      command: ["sleep", "600"]
      volumeMounts:
        - name: data
          mountPath: /data
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $GRAFANA_PVC
POD
  kubectl -n monitoring wait --for=condition=Ready pod/grafana-backup --timeout="$GRAFANA_TIMEOUT" \
    && kubectl -n monitoring exec grafana-backup -- tar czf - -C /data . > "$OUT/grafana-data.tar.gz" \
    || rc=1
  # clean up in every case, so a failed run does not leave a pod behind
  kubectl -n monitoring delete pod grafana-backup --wait=false --ignore-not-found > /dev/null
  [ $rc -eq 0 ] || rm -f "$OUT/grafana-data.tar.gz"
  return $rc
}

step critical "etcd snapshot"        backup_etcd
step critical "certificates (pki)"   backup_pki
step critical "manifests"            backup_manifests
step optional "Grafana data"         backup_grafana

# result
if [ ${#failed_critical[@]} -gt 0 ]; then
  STATUS=FAIL
elif [ ${#failed_optional[@]} -gt 0 ]; then
  STATUS=PARTIAL
else
  STATUS=OK
fi
echo "$STATUS" > "$OUT/STATUS"
if [ "$STATUS" = FAIL ]; then
  mv "$OUT" "$OUT-FAILED"
  OUT="$OUT-FAILED"
fi

# 5. rotation: keep the last $KEEP good backups, drop FAILED folders after 7 days
ls -1dt "$DEST"/*/ 2>/dev/null | grep -v -- '-FAILED/$' | tail -n +$((KEEP + 1)) | xargs -r rm -rf
find "$DEST" -maxdepth 1 -type d -name '*-FAILED' -mtime +7 -exec rm -rf {} +

echo "status: $STATUS, backup in $OUT"

# 6. report problems to Slack (silent on OK)
if [ "$STATUS" != OK ] && [ -r "$SLACK_URL_FILE" ]; then
  if [ "$STATUS" = FAIL ]; then icon=":red_circle:"; else icon=":large_orange_circle:"; fi
  msg="$icon *[$CLUSTER] Nightly backup: $STATUS* ($(date -u '+%Y-%m-%d %H:%M UTC'))"
  for s in "${failed_critical[@]}"; do msg+=$'\n'"• critical step failed: $s"; done
  for s in "${failed_optional[@]}"; do msg+=$'\n'"• optional step failed: $s"; done
  msg+=$'\n'"• folder: $OUT"
  python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$msg" \
    | curl -s -m 10 -X POST -H 'Content-Type: application/json' --data @- "$(cat "$SLACK_URL_FILE")" > /dev/null
fi

[ "$STATUS" != FAIL ]
