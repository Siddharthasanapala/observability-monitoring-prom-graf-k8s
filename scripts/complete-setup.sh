#!/usr/bin/env bash
# complete-setup.sh — full from-scratch bootstrap of the entire observability platform,
# for re-running after a Minikube teardown (e.g. `minikube delete`) days/weeks later.
#
# This does NOT duplicate the logic already in scripts/01/02/validate.sh — it chains them,
# and adds the parts that were previously done by hand/interactively during original
# development: waiting for Calico to be ready before NetworkPolicy-dependent apps sync,
# waiting for every ArgoCD Application to actually reach Synced/Healthy (rather than just
# applying the root Application and walking away), and opening browser access at the end.
#
# Precondition this script CANNOT enforce: the `siddhu` branch on GitHub must already have
# whatever state you want deployed — ArgoCD pulls from origin, not your local working tree.
# If you have uncommitted/unpushed changes (e.g. a manifest fix), commit and push them BEFORE
# running this, or the fresh cluster will reproduce whatever bug you fixed locally.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "############################################################"
echo "# 0. Preflight"
echo "############################################################"

for f in bootstrap/root-app.yaml scripts/01-setup-minikube.sh scripts/02-bootstrap-argocd.sh scripts/validate.sh; do
  [ -f "$f" ] || { echo "FATAL: expected file '$f' not found — run this from the repo root."; exit 1; }
done

MISSING_TOOLS=()
for tool in minikube kubectl argocd git node; do
  command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS+=("$tool")
done
if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
  echo "FATAL: missing required tools: ${MISSING_TOOLS[*]}"
  exit 1
fi
echo "  All required tools present: minikube, kubectl, argocd, git, node."

BRANCH_HEAD=$(git ls-remote origin refs/heads/siddhu 2>/dev/null | cut -f1 || true)
LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null || true)
if [ -n "$BRANCH_HEAD" ] && [ -n "$LOCAL_HEAD" ] && [ "$BRANCH_HEAD" != "$LOCAL_HEAD" ]; then
  echo "  NOTE: local HEAD ($LOCAL_HEAD) differs from origin/siddhu ($BRANCH_HEAD)."
  echo "        ArgoCD deploys from origin/siddhu, not your local checkout — make sure"
  echo "        origin/siddhu already has everything you want deployed."
fi
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  echo "  WARNING: uncommitted local changes present. These will NOT be deployed — only"
  echo "           what's pushed to origin/siddhu is. Ctrl+C now if that's not intended."
  sleep 5
fi

echo ""
echo "############################################################"
echo "# 1. Minikube cluster provisioning"
echo "############################################################"
bash scripts/01-setup-minikube.sh

echo ""
echo "############################################################"
echo "# 2. Waiting for Calico CNI (NetworkPolicy enforcement needs this ready"
echo "#    before namespaces/network-policies sync, or enforcement can be flaky)"
echo "############################################################"
kubectl -n kube-system rollout status daemonset/calico-node --timeout=180s

echo ""
echo "############################################################"
echo "# 3. ArgoCD install + App-of-Apps bootstrap"
echo "############################################################"
bash scripts/02-bootstrap-argocd.sh

echo ""
echo "############################################################"
echo "# 4. Waiting for all ArgoCD Applications to reach Synced/Healthy"
echo "#    (self-healing retries are expected/normal here — e.g. 'security' waits on"
echo "#    cert-manager's CRDs, several apps wait on 'namespaces' creating their target"
echo "#    namespace first. Give it time rather than treating early failures as fatal.)"
echo "############################################################"
TIMEOUT_SECONDS=1500   # 25 minutes — image pulls + PVC binds + Alertmanager cluster gossip settling
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
    echo "  application <name> -n argocd'. Continuing to validate.sh so you get a full picture."
    break
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""
echo "############################################################"
echo "# 5. Running the end-to-end validation gate (scripts/validate.sh)"
echo "############################################################"
set +e
bash scripts/validate.sh
VALIDATE_EXIT=$?
set -e
if [ "$VALIDATE_EXIT" -ne 0 ]; then
  echo ""
  echo "  validate.sh reported failures above — the cluster is up but not 100% clean."
  echo "  Re-run 'bash scripts/validate.sh' after investigating; it's safe to re-run any time."
fi

echo ""
echo "############################################################"
echo "# 6. Opening browser access (background port-forwards)"
echo "############################################################"
PF_LOG_DIR="${TMPDIR:-/tmp}/complete-setup-pf-logs"
mkdir -p "$PF_LOG_DIR"

start_pf() {
  local name="$1" ns="$2" svc="$3" ports="$4"
  nohup kubectl port-forward -n "$ns" "svc/$svc" "$ports" > "$PF_LOG_DIR/pf-$name.log" 2>&1 &
  disown
}
start_pf argocd       argocd        argocd-server                        8080:443
start_pf grafana      observability kube-prometheus-stack-grafana        3000:80
start_pf prometheus   observability kube-prometheus-stack-prometheus     9090:9090
start_pf alertmanager observability kube-prometheus-stack-alertmanager   9093:9093
sleep 3

echo "  ArgoCD:       https://localhost:8080  (self-signed cert — click through the warning)"
echo "  Grafana:      http://localhost:3000"
echo "  Prometheus:   http://localhost:9090"
echo "  Alertmanager: http://localhost:9093"
echo ""
echo "  Credentials (run these yourself — not printed here):"
echo "    ArgoCD admin password:"
echo "      kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo"
echo "    Grafana admin password:"
echo "      kubectl get secret kube-prometheus-stack-grafana -n observability -o jsonpath='{.data.admin-password}' | base64 -d; echo"
echo ""
echo "  Port-forward logs: $PF_LOG_DIR/"
echo "  These port-forwards run in the background and die when this shell/terminal closes —"
echo "  re-run just section 6 (or the four 'kubectl port-forward' commands above) any time."

echo ""
echo "############################################################"
echo "# Done."
echo "############################################################"
