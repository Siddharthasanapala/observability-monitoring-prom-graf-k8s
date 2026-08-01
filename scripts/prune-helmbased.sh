#!/usr/bin/env bash
# prune-helmbased.sh — full, one-shot teardown of the ArgoCD-driven Helm-based deployment
# created by scripts/setup-minikube-helm.sh.
#
# Destroys, in order: every kubectl port-forward process, the ArgoCD CLI session, the
# root-app-of-apps-helmbased Application (its resources-finalizer cascades deletion through
# every child Application it owns — cert-manager, kube-prometheus-stack, loki, promtail,
# tempo, otel-collector, observability-minikube — pruning everything they deployed), this
# flow's port-forward log directory, and the Minikube cluster/profile itself (including its
# underlying Docker container). Nothing in this repository is touched — rebuild any time with
# scripts/setup-minikube-helm.sh.
#
# Sibling of scripts/prune.sh (which tears down the raw-manifest ArgoCD flow via
# root-app-of-apps instead of root-app-of-apps-helmbased) — kept separate so the two
# deployment methods' teardowns can never be confused for each other.
#
# Deliberately non-strict (no `set -e`): a teardown script must keep going even if an individual
# step fails because that thing was already gone. The cascade-delete step is given a generous
# timeout but isn't fatal if it doesn't finish in time — deleting the Minikube cluster afterward
# removes everything regardless.
set -uo pipefail

echo "############################################################"
echo "# prune-helmbased.sh — destroying the ArgoCD-driven Helm-based implementation"
echo "############################################################"
echo "This will: kill all port-forwards, log out of ArgoCD, cascade-delete the"
echo "root-app-of-apps-helmbased Application (which prunes everything it deployed), and"
echo "DELETE the Minikube cluster/profile (including its Docker container). Everything is"
echo "reconstructible via scripts/setup-minikube-helm.sh — nothing in this repo is touched."
echo ""

# ============================================================
# 1. Kill every kubectl port-forward process
# ============================================================
echo "==> [1/6] Killing all kubectl processes (port-forwards)"
powershell.exe -NoProfile -Command "Get-Process -Name kubectl -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue" 2>&1 || true
sleep 1
REMAINING=$(powershell.exe -NoProfile -Command "(Get-Process -Name kubectl -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -d '\r\n ')
if [ "${REMAINING:-0}" = "0" ]; then
  echo "    OK — no kubectl processes remain"
else
  echo "    WARNING — ${REMAINING} kubectl process(es) still running, continuing anyway"
fi

# ============================================================
# 2. Log out of the ArgoCD CLI session (best-effort — harmless if already unreachable)
# ============================================================
echo "==> [2/6] Logging out of ArgoCD CLI session"
argocd logout localhost:8080 >/dev/null 2>&1 || true
echo "    done (non-fatal either way)"

# ============================================================
# 3. Cascade-delete the Helm-based flow's root Application (best-effort — harmless if the
#    cluster/ArgoCD is already gone or it was never applied)
# ============================================================
echo "==> [3/6] Cascade-deleting root-app-of-apps-helmbased (prunes all 7 child Applications"
echo "    and everything they deployed, via its resources-finalizer)"
kubectl delete application root-app-of-apps-helmbased -n argocd --wait=true --timeout=180s 2>&1 || echo "    WARNING — cascade delete didn't finish cleanly, continuing anyway (Minikube deletion below removes everything regardless)"

# ============================================================
# 4. Remove this flow's port-forward log directories
# ============================================================
PF_LOG_DIR="${TMPDIR:-/tmp}/setup-minikube-helm-pf-logs"
echo "==> [4/6] Removing port-forward log directories"
rm -rf "$PF_LOG_DIR" 2>/dev/null || true
rm -f "${TMPDIR:-/tmp}/argocd-port-forward.log" 2>/dev/null || true
echo "    done"

# ============================================================
# 5. Delete the Minikube cluster/profile entirely
# ============================================================
echo "==> [5/6] Deleting the Minikube profile (this removes the cluster and its"
echo "    underlying Docker container)"
minikube delete -p minikube 2>&1 || true

STRAY=$(docker ps -aq --filter "name=^minikube$" 2>/dev/null || true)
if [ -n "$STRAY" ]; then
  echo "    Stray minikube Docker container found — removing it directly"
  docker rm -f "$STRAY" >/dev/null 2>&1 || true
fi

# ============================================================
# 6. Final verification
# ============================================================
echo "==> [6/6] Verifying nothing is left running"
KCTL_LEFT=$(powershell.exe -NoProfile -Command "(Get-Process -Name kubectl -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -d '\r\n ')
PROFILE_LEFT=$(minikube profile list 2>/dev/null | grep -c "minikube" || true)
DOCKER_LEFT=$(docker ps -aq --filter "name=^minikube$" 2>/dev/null || true)

echo ""
echo "############################################################"
echo "# SUMMARY"
echo "############################################################"
echo "  kubectl processes remaining : ${KCTL_LEFT:-0}"
echo "  minikube profile remaining  : $([ "${PROFILE_LEFT:-0}" -gt 0 ] && echo 'YES — check manually' || echo 'none')"
echo "  stray minikube container    : $([ -n "$DOCKER_LEFT" ] && echo 'YES — check manually' || echo 'none')"
echo ""
if [ "${KCTL_LEFT:-0}" = "0" ] && [ "${PROFILE_LEFT:-0}" = "0" ] && [ -z "$DOCKER_LEFT" ]; then
  echo "  Clean. Everything has been torn down."
  echo "  Rebuild any time with: bash scripts/setup-minikube-helm.sh"
else
  echo "  Something above wasn't fully clean — re-run this script, or check the"
  echo "  flagged item manually (e.g. 'minikube delete -p minikube --purge')."
fi
echo "############################################################"
