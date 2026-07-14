#!/usr/bin/env bash
# Phase 2 — GitOps Foundation: Install & Bootstrap ArgoCD
# From this point forward, nothing is applied with raw `kubectl apply` except ArgoCD's
# own install and the single root App-of-Apps seed Application below. Everything else
# is reconciled by ArgoCD from argocd-apps/ in this repo.
set -euo pipefail

NAMESPACE="argocd"
INSTALL_MANIFEST="bootstrap/argocd-install/install.yaml"
ROOT_APP="bootstrap/root-app.yaml"

echo "==> Creating '${NAMESPACE}' namespace"
kubectl apply -f bootstrap/argocd-install/namespace.yaml

echo "==> Installing ArgoCD (server-side apply — the ApplicationSet CRD exceeds the"
echo "    kubectl.kubernetes.io/last-applied-configuration annotation size limit under"
echo "    a normal client-side apply, so --server-side is required here)"
kubectl apply -n "${NAMESPACE}" -f "${INSTALL_MANIFEST}" --server-side --force-conflicts

echo "==> Waiting for ArgoCD components to become ready"
kubectl -n "${NAMESPACE}" rollout status deployment/argocd-server --timeout=180s
kubectl -n "${NAMESPACE}" rollout status deployment/argocd-repo-server --timeout=180s
kubectl -n "${NAMESPACE}" rollout status deployment/argocd-dex-server --timeout=180s
kubectl -n "${NAMESPACE}" rollout status deployment/argocd-redis --timeout=180s
kubectl -n "${NAMESPACE}" rollout status deployment/argocd-applicationset-controller --timeout=180s
kubectl -n "${NAMESPACE}" rollout status statefulset/argocd-application-controller --timeout=180s

echo "==> Retrieving initial admin password"
ARGO_PWD=$(kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "    Initial admin password: ${ARGO_PWD}"
echo "    (Change this after first login: argocd account update-password)"

echo "==> Starting port-forward to argocd-server on https://localhost:8080 (background)"
kubectl -n "${NAMESPACE}" port-forward svc/argocd-server 8080:443 >/tmp/argocd-port-forward.log 2>&1 &
sleep 4

echo "==> Logging in via argocd CLI"
argocd login localhost:8080 --username admin --password "${ARGO_PWD}" --insecure

echo "==> Applying the root App-of-Apps Application (one-time bootstrap seed)"
kubectl apply -f "${ROOT_APP}"

echo "==> Root Application status"
argocd app get root-app-of-apps || true

echo "==> Done. ArgoCD UI: https://localhost:8080 (username: admin)"
echo "    All further cluster state is now managed via argocd-apps/ in Git — do not kubectl apply workload manifests directly."
