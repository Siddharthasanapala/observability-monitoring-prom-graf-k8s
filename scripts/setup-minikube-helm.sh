#!/usr/bin/env bash
# setup-minikube-helm.sh — full platform deployment via ArgoCD, deploying Helm charts only.
#
# Creates a fresh Minikube cluster (same sizing as scripts/01-setup-minikube.sh), installs
# ArgoCD, and seeds a dedicated App-of-Apps (bootstrap/root-app-helmbased.yaml ->
# argocd-apps-helmbased/) whose 7 child Applications are ALL Helm-chart sources:
#   cert-manager, kube-prometheus-stack, loki, promtail, tempo, otel-collector
#   (official upstream charts) + observability-minikube (this repo's own chart: namespaces,
#   RBAC, NetworkPolicy, ClusterIssuer, dashboards, alert rules, the reference workload)
#
# Nothing here runs `helm install` directly — ArgoCD is the only thing that talks to the
# cluster from step 4 onward, same discipline as the raw-manifest flow in
# scripts/02-bootstrap-argocd.sh / bootstrap/root-app.yaml. This is that flow's sibling: same
# ArgoCD, same App-of-Apps pattern, a completely separate Application tree
# (argocd-apps-helmbased/, not argocd-apps/) so the two never collide on one cluster.
#
# WHY THIS ORDER, SPECIFICALLY: observability-minikube's own PrometheusRule/ServiceMonitor
# CRs need the Prometheus Operator CRDs (from kube-prometheus-stack) and its ClusterIssuer
# needs cert-manager's CRDs. Unlike a plain `helm install` sequence, this doesn't need manual
# wait/ordering at the script level — argocd-apps-helmbased/observability-minikube.yaml carries
# `sync-wave: "1"` plus a retry/backoff block, so ArgoCD itself retries automatically until
# those CRDs exist (same proven pattern as argocd-apps/security.yaml in the raw-manifest flow).
#
# WHY NOT ONE SINGLE UMBRELLA CHART: unchanged from before — grafana/tempo has no
# namespaceOverride and always installs into .Release.Namespace, so one Helm release can't
# reproduce this platform's real multi-namespace design if Tempo is a dependency of it. Each
# component stays its own ArgoCD Application/Helm chart instead.
set -uo pipefail

PROFILE="minikube"
CPUS=4
MEMORY=8192
K8S_VERSION="v1.35.1"
DRIVER="docker"
CNI="calico"

echo "############################################################"
echo "# 0. Preflight"
echo "############################################################"
for tool in minikube kubectl helm argocd; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool not found on PATH"; exit 1; }
done
echo "  minikube, kubectl, helm, argocd all present."

echo ""
echo "############################################################"
echo "# 1. Minikube cluster provisioning"
echo "############################################################"
minikube start \
  -p "${PROFILE}" \
  --cpus="${CPUS}" \
  --memory="${MEMORY}" \
  --kubernetes-version="${K8S_VERSION}" \
  --driver="${DRIVER}" \
  --cni="${CNI}" \
  --addons=metrics-server \
  --addons=storage-provisioner \
  --addons=default-storageclass \
  --addons=ingress

echo ""
echo "############################################################"
echo "# 2. Waiting for Calico CNI (NetworkPolicy enforcement needs this ready"
echo "#    before observability-minikube's NetworkPolicies sync, or enforcement can be flaky)"
echo "############################################################"
kubectl -n kube-system rollout status daemonset/calico-node --timeout=180s

echo ""
echo "############################################################"
echo "# 3. ArgoCD install + Helm-based App-of-Apps bootstrap"
echo "############################################################"
bash scripts/02-bootstrap-argocd.sh bootstrap/root-app-helmbased.yaml

echo ""
echo "############################################################"
echo "# 4. Waiting for all ArgoCD Applications to reach Synced/Healthy"
echo "#    (retries are expected/normal here — e.g. observability-minikube waits on"
echo "#    cert-manager's and kube-prometheus-stack's CRDs. Give it time rather than"
echo "#    treating early failures as fatal.)"
echo "############################################################"
TIMEOUT_SECONDS=900
POLL_INTERVAL=15
ELAPSED=0
while true; do
  APPS=$(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.sync.status}{"|"}{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
  TOTAL=$(echo "$APPS" | grep -c . || true)
  READY=$(echo "$APPS" | awk -F'|' '$2=="Synced" && $3=="Healthy"' | grep -c . || true)
  echo "  [$(date +%H:%M:%S)] ${READY}/${TOTAL} Applications Synced+Healthy (elapsed ${ELAPSED}s)"
  if [ "$TOTAL" -gt 0 ] && [ "$READY" = "$TOTAL" ]; then
    echo "  All ArgoCD Applications are Synced and Healthy."
    break
  fi
  if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
    echo ""
    echo "  TIMEOUT after ${TIMEOUT_SECONDS}s. Current status:"
    echo "$APPS" | awk -F'|' '{printf "    %-25s sync=%-10s health=%s\n", $1, $2, $3}'
    echo ""
    echo "  Not fatal by itself — inspect with 'argocd app get <name>' or 'kubectl describe"
    echo "  application <name> -n argocd'. Continuing on so you get a full picture."
    break
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""
echo "############################################################"
echo "# 5. Status"
echo "############################################################"
echo "--- ArgoCD Applications ---"
kubectl get applications -n argocd
echo ""
echo "--- Pods across every namespace this platform uses ---"
kubectl get pods -n observability -n logging -n tracing -n demo-app -n cert-manager 2>&1 | grep -v "^$"

echo ""
echo "############################################################"
echo "# 6. Access"
echo "############################################################"
# ArgoCD's own port-forward (started by scripts/02-bootstrap-argocd.sh above, still running in
# the background) already serves the UI — no second one needed here.
PF_LOG_DIR="${TMPDIR:-/tmp}/setup-minikube-helm-pf-logs"
mkdir -p "$PF_LOG_DIR"

start_pf() {
  local name="$1" ns="$2" svc="$3" ports="$4"
  nohup kubectl port-forward -n "$ns" "svc/$svc" "$ports" > "$PF_LOG_DIR/pf-$name.log" 2>&1 &
  disown
}
start_pf grafana      observability kube-prometheus-stack-grafana        3000:80
start_pf prometheus   observability kube-prometheus-stack-prometheus     9090:9090
start_pf alertmanager observability kube-prometheus-stack-alertmanager   9093:9093
sleep 3

echo "  ArgoCD:       https://localhost:8080  (self-signed cert — click through the warning;"
echo "                admin password was printed above by scripts/02-bootstrap-argocd.sh)"
echo "  Grafana:      http://localhost:3000"
echo "  Prometheus:   http://localhost:9090"
echo "  Alertmanager: http://localhost:9093"
echo ""
echo "  Credentials (run this yourself — not printed here):"
echo "    Grafana admin password:"
echo "      kubectl get secret kube-prometheus-stack-grafana -n observability -o jsonpath='{.data.admin-password}' | base64 -d; echo"
echo ""
echo "  Port-forward logs: $PF_LOG_DIR/ (Grafana/Prometheus/Alertmanager), /tmp/argocd-port-forward.log (ArgoCD)"
echo "  These port-forwards run in the background and die when this shell/terminal closes —"
echo "  re-run just this section (or the individual 'kubectl port-forward' commands) any time."
echo "  To tear everything down: bash scripts/prune-helmbased.sh"
echo "############################################################"
echo "# Done. ArgoCD/Grafana/Prometheus/Alertmanager are live in your browser now —"
echo "# nothing else to run. All cluster state from here on is managed by ArgoCD from Git;"
echo "# do not 'helm install'/'kubectl apply' workload manifests directly."
echo "############################################################"
