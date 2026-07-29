#!/usr/bin/env bash
# prune.sh — full, one-shot teardown of the entire local implementation.
#
# Destroys, in order: every kubectl port-forward process, the ArgoCD CLI session,
# this platform's port-forward log directory, and the Minikube cluster/profile itself
# (including its underlying Docker container). Nothing in this repository — no manifests,
# no docs, no generated deliverables — is touched. This only removes locally-running
# infrastructure state, all of which scripts/complete-setup.sh can recreate from Git.
#
# Deliberately non-strict (no `set -e`): a teardown script must keep going even if an
# individual step fails because that thing was already gone — the goal is "make sure
# everything is gone by the end," not "abort on the first already-clean step."
set -uo pipefail

echo "############################################################"
echo "# prune.sh — destroying the entire local implementation"
echo "############################################################"
echo "This will: kill all port-forwards, log out of ArgoCD, and DELETE the Minikube"
echo "cluster/profile (including its Docker container). Everything is reconstructible"
echo "from Git via scripts/complete-setup.sh — nothing in this repo itself is touched."
echo ""

# ============================================================
# 1. Kill every kubectl port-forward process
# ============================================================
# git-bash's own process signalling doesn't reliably reach native Windows kubectl.exe
# processes (seen repeatedly this session) — shell out to PowerShell for this specifically.
echo "==> [1/5] Killing all kubectl processes (port-forwards)"
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
echo "==> [2/5] Logging out of ArgoCD CLI session"
argocd logout localhost:8080 >/dev/null 2>&1 || true
echo "    done (non-fatal either way)"

# ============================================================
# 3. Remove this platform's port-forward log directory
# ============================================================
PF_LOG_DIR="${TMPDIR:-/tmp}/complete-setup-pf-logs"
echo "==> [3/5] Removing port-forward log directory ($PF_LOG_DIR)"
rm -rf "$PF_LOG_DIR" 2>/dev/null || true
echo "    done"

# ============================================================
# 4. Delete the Minikube cluster/profile entirely
# ============================================================
echo "==> [4/5] Deleting the Minikube profile (this removes the cluster and its"
echo "    underlying Docker container — the actual 'even minikube must be removed' step)"
minikube delete -p minikube 2>&1 || true

# Defensive check: minikube delete should remove its own Docker container, but confirm
# and force-remove it if anything was left behind (e.g. a prior interrupted delete).
STRAY=$(docker ps -aq --filter "name=^minikube$" 2>/dev/null || true)
if [ -n "$STRAY" ]; then
  echo "    Stray minikube Docker container found — removing it directly"
  docker rm -f "$STRAY" >/dev/null 2>&1 || true
fi

# ============================================================
# 5. Final verification
# ============================================================
echo "==> [5/5] Verifying nothing is left running"
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
  echo "  Rebuild any time with: bash scripts/complete-setup.sh"
else
  echo "  Something above wasn't fully clean — re-run this script, or check the"
  echo "  flagged item manually (e.g. 'minikube delete -p minikube --purge')."
fi
echo "############################################################"
