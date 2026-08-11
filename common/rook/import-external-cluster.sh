#!/usr/bin/env bash
# Imports Ceph external cluster credentials into a Kubernetes cluster's rook-ceph-external namespace.
# Run this script ONCE per cluster that needs to connect to the external Ceph cluster.
#
# Prerequisites:
#   - kubectl configured to the target cluster (or pass KUBECONFIG)
#   - SSH access to a Proxmox node running Ceph (default: root@10.0.21.51)
#   - python3 available on the Proxmox node
#
# Usage:
#   KUBECONFIG=/path/to/kubeconfig ./import-external-cluster.sh
#   CEPH_NODE=root@10.0.21.52 KUBECONFIG=/tmp/kubeconfig-sandbox.yaml ./import-external-cluster.sh

set -euo pipefail

CEPH_NODE="${CEPH_NODE:-root@10.0.21.51}"
NAMESPACE="rook-ceph-external"
ROOK_VERSION="v1.15.7"
EXPORTER_URL="https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/external-cluster-details-exporter.py"
SCRATCHDIR="/tmp/rook-import-$$"

echo "==> Importing Ceph external cluster credentials into namespace: ${NAMESPACE}"
echo "    Ceph node: ${CEPH_NODE}"

mkdir -p "${SCRATCHDIR}"
trap 'rm -rf "${SCRATCHDIR}"' EXIT

# Download the exporter script
echo "==> Downloading rook external cluster exporter (${ROOK_VERSION})..."
curl -fsSL "${EXPORTER_URL}" -o "${SCRATCHDIR}/exporter.py"

# Copy exporter to Ceph node and run it
echo "==> Running exporter on ${CEPH_NODE}..."
scp -q "${SCRATCHDIR}/exporter.py" "${CEPH_NODE}:/tmp/rook-exporter.py"
ssh "${CEPH_NODE}" "python3 /tmp/rook-exporter.py \
  --ceph-conf /etc/ceph/ceph.conf \
  --rbd-data-pool-name k8s \
  --cephfs-filesystem-name CephFS \
  --cephfs-data-pool-name CephFS_data \
  --cephfs-metadata-pool-name CephFS_metadata \
  2>/dev/null" > "${SCRATCHDIR}/cluster-details.json"

ssh "${CEPH_NODE}" "rm -f /tmp/rook-exporter.py"

if [[ ! -s "${SCRATCHDIR}/cluster-details.json" ]]; then
  echo "ERROR: Exporter produced no output. Check Ceph health on ${CEPH_NODE}."
  exit 1
fi

echo "==> Cluster details extracted. Applying to Kubernetes..."

# Use the import script bundled with rook examples
IMPORT_URL="https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/import-external-cluster.sh"
curl -fsSL "${IMPORT_URL}" -o "${SCRATCHDIR}/import.sh"
chmod +x "${SCRATCHDIR}/import.sh"

# Run the import (sets env vars that the import script reads)
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
export NAMESPACE="${NAMESPACE}"
export ROOK_EXTERNAL_CLUSTER_DETAILS="$(cat "${SCRATCHDIR}/cluster-details.json")"

bash "${SCRATCHDIR}/import.sh"

echo ""
echo "==> Done. Waiting for CephCluster to connect..."
kubectl wait --for=jsonpath='{.status.phase}'=Connected \
  cephcluster/rook-ceph-external -n "${NAMESPACE}" --timeout=120s 2>/dev/null || \
  echo "Timeout waiting — check: kubectl get cephcluster -n ${NAMESPACE}"

echo ""
echo "==> Verify with:"
echo "    kubectl get cephcluster -n ${NAMESPACE}"
echo "    kubectl get secret -n ${NAMESPACE}"
