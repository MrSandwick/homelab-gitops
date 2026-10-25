#!/usr/bin/env bash
# Dead man's switch for the homelab cluster. Runs on the control plane from a systemd timer.
# Checks the API server, node readiness and the always-firing Watchdog alert,
# and posts to Slack directly (not through Alertmanager) when something is wrong.
set -uo pipefail

CLUSTER="homelab"
IGNORE_NODES="nursultan-nitro-an515-57"     # laptop node, often offline by design
REMIND_EVERY=3600                            # repeat a failure message every hour
export KUBECONFIG=/etc/kubernetes/admin.conf
SLACK_URL_FILE=/etc/homelab-deadman/slack-url
STATE_FILE=/var/lib/homelab-deadman/state
AM_PATH="/api/v1/namespaces/monitoring/services/prometheus-kube-prometheus-alertmanager:9093/proxy/api/v2/alerts?filter=alertname%3D%22Watchdog%22"

problems=()

# 1. API server
if ! kubectl get --raw /readyz > /dev/null 2>&1; then
  problems+=("Kubernetes API server is not answering on $(hostname)")
else
  # 2. nodes that are not Ready (except ignored ones)
  notready=$(kubectl get nodes --no-headers | awk -v ign="$IGNORE_NODES" '$1 != ign && $2 != "Ready" {print $1 " (" $2 ")"}')
  if [ -n "$notready" ]; then
    problems+=("Node not Ready: $notready")
  fi

  # 3. Watchdog must be active in Alertmanager, otherwise alerting itself is down
  if ! kubectl get --raw "$AM_PATH" 2>/dev/null | grep -q '"alertname":"Watchdog"'; then
    problems+=("Alerting pipeline is down: Watchdog is not active in Alertmanager (Prometheus or Alertmanager unavailable). Other alerts will NOT be delivered.")
  fi
fi

send_slack() {
  local text="$1"
  python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$text" \
    | curl -s -m 10 -X POST -H 'Content-Type: application/json' --data @- "$(cat "$SLACK_URL_FILE")" > /dev/null
}

now=$(date +%s)
read -r last_state last_sent < "$STATE_FILE" 2>/dev/null || { last_state="OK"; last_sent=0; }

if [ ${#problems[@]} -gt 0 ]; then
  msg=":red_circle: *[$CLUSTER] Dead man's switch* ($(date -u '+%Y-%m-%d %H:%M UTC'))"
  for p in "${problems[@]}"; do msg+=$'\n'"• $p"; done
  echo "$msg"
  if [ "$last_state" != "FAIL" ] || [ $((now - last_sent)) -ge $REMIND_EVERY ]; then
    send_slack "$msg"
    last_sent=$now
  fi
  echo "FAIL $last_sent" > "$STATE_FILE"
else
  echo "OK: API, nodes and Watchdog are fine"
  if [ "$last_state" = "FAIL" ]; then
    send_slack ":large_green_circle: *[$CLUSTER] Dead man's switch*: all checks pass again ($(date -u '+%Y-%m-%d %H:%M UTC'))"
  fi
  echo "OK $now" > "$STATE_FILE"
fi
