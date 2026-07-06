#!/usr/bin/env bash
# Manual first-time Cilium install for a new k8s-foundation cluster.
#
# ArgoCD itself needs a working CNI to schedule its own pods, so Cilium can't
# be bootstrapped by ArgoCD on a fresh cluster (chicken-and-egg). Run this once,
# by hand, right after the cluster is up and kubectl/kubeconfig work but before
# (or while) ArgoCD is being installed. Once ArgoCD is running, the
# "{{.name}}-cilium" Application (common/cilium/cilium.argoapp.yaml) takes over:
# same chart, same release name, same values file, so ArgoCD's first sync is a
# no-op diff and it adopts the release for drift tracking / future upgrades.
#
# Usage: ./bootstrap.sh [chart-version]

set -euo pipefail

CHART_VERSION="${1:-1.17.3}"
VALUES_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helm/values.yaml"

helm repo add cilium https://helm.cilium.io/ >/dev/null
helm repo update cilium >/dev/null

helm upgrade --install cilium cilium/cilium \
  --version "${CHART_VERSION}" \
  --namespace kube-system \
  --create-namespace \
  -f "${VALUES_FILE}" \
  --wait

echo "Cilium ${CHART_VERSION} installed. Waiting for nodes to go Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s
