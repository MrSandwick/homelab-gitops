# Platform (Helm releases)

Values and config for cluster components installed with Helm. No secrets are stored here:
Grafana admin credentials and the Slack webhook live in Kubernetes Secrets
(`grafana-admin`, `alertmanager-slack`) created manually.

| Release | Namespace | Chart | Chart version | Values |
|---|---|---|---|---|
| metallb | metallb-system | metallb/metallb | 0.16.1 | defaults + `metallb/config.yaml` |
| envoy-gateway (release `eg`) | envoy-gateway-system | oci://docker.io/envoyproxy/gateway-helm | v1.9.2 | `envoy-gateway/`, `gateway-routes/`; CRDs installed separately (standard channel) with `crds.enabled=false` |
| local-path-provisioner | local-path-storage | local-path-provisioner | 0.0.37 | `local-path-provisioner/values.yaml` |
| argocd | argocd | argo/argo-cd | 10.9.6 | `argocd/values.yaml` |
| kube-prometheus-stack | monitoring | prometheus-community/kube-prometheus-stack | 91.4.1 | `kube-prometheus-stack/values.yaml` |
| loki | monitoring | grafana-community/loki | 18.15.1 | `loki/values.yaml` |
| alloy | monitoring | grafana/alloy | 1.13.1 | `alloy/values.yaml` |

Upgrade example:

    helm upgrade <release> <repo/chart> -n <namespace> --version <chart version> -f platform/<dir>/values.yaml
