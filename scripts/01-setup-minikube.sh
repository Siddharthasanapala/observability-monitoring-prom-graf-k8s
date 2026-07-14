#!/usr/bin/env bash
# Phase 1 — Minikube Cluster Provisioning (enterprise-shaped)
# Starts a Minikube cluster sized like a real environment (not `minikube start` defaults)
# with the addons required for the observability stack: metrics-server, storage-provisioner,
# default-storageclass (dynamic PVC provisioning), and ingress.
set -euo pipefail

PROFILE="minikube"
CPUS=4
MEMORY=8192
K8S_VERSION="v1.35.1" # pinned explicitly for reproducibility (resolved from 'stable' at time of writing)
DRIVER="docker"

echo "==> Starting Minikube profile '${PROFILE}' (cpus=${CPUS}, memory=${MEMORY}MB, k8s=${K8S_VERSION}, driver=${DRIVER})"
minikube start \
  -p "${PROFILE}" \
  --cpus="${CPUS}" \
  --memory="${MEMORY}" \
  --kubernetes-version="${K8S_VERSION}" \
  --driver="${DRIVER}" \
  --addons=metrics-server \
  --addons=storage-provisioner \
  --addons=default-storageclass \
  --addons=ingress

echo "==> Verifying addons are enabled"
minikube -p "${PROFILE}" addons list | grep -E "metrics-server|storage-provisioner|default-storageclass|^\| ingress "

echo "==> Cluster nodes"
kubectl get nodes -o wide

echo "==> StorageClasses (dynamic PVC provisioning check)"
kubectl get storageclass

echo "==> Done. Cluster is ready for Phase 2 (ArgoCD bootstrap)."
