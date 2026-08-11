# CephFS Setup on Rook External Clusters

This document describes how to configure CephFS (via Rook external mode) on a Kubernetes cluster managed by Sidero Omni. The setup connects the cluster to the shared Proxmox Ceph cluster.

## Architecture

All CEDILLE clusters (`k8s-cedille-production-v2`, `k8s-shared`, `k8s-cedille-sandbox`) connect to the **same** external Ceph cluster hosted on the Proxmox hypervisor nodes (pve01–pve08, `10.0.21.51`–`10.0.21.58`).

```
┌─────────────────────────────────────────────────────────┐
│  External Ceph Cluster (Proxmox)                        │
│  FSID: 87389894-c75d-4013-b884-19172b41d653             │
│  Mons: 10.0.21.51-58:6789                               │
│  Filesystems:                                           │
│    - CephFS (metadata: CephFS_metadata, data: CephFS_data) │
│    - Shared_Ceph (metadata: Shared_Ceph_metadata, ...)  │
│  Pools: k8s (RBD), CephFS_data, CephFS_metadata         │
└─────────────────┬───────────────────────────────────────┘
                  │ Ceph CSI (TCP)
        ┌─────────┴──────────┐
        │                    │
   production-v2          sandbox
   (Connected ✓)          (Connecting — needs setup)
```

## Prerequisites

- SSH access to a Proxmox node (e.g., `root@10.0.21.51`)
- `kubectl` configured to the target cluster
- Python 3 available on the Proxmox node (present by default on Proxmox)
- The `rook-ceph-operator` must be running in the target cluster

## Component Overview

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| `rook-ceph-operator` | `rook-ceph` | Manages all Rook CRDs and CSI deployments |
| `csi-cephfsplugin` (DaemonSet) | `rook-ceph` | Mounts CephFS volumes on nodes |
| `csi-cephfsplugin-provisioner` | `rook-ceph` | Provisions new CephFS PVCs |
| `CephCluster` (external) | `rook-ceph-external` | Tracks external Ceph connection state |
| `rook-csi-cephfs-node` | `rook-ceph-external` | Ceph key for node-level CephFS access |
| `rook-csi-cephfs-provisioner` | `rook-ceph-external` | Ceph key for provisioning |
| `rook-ceph-mon` | `rook-ceph-external` | Mon endpoints + admin key |
| `StorageClass: cephfs` | cluster-wide | PVC provisioner for CephFS |

## StorageClass

The `cephfs` StorageClass is now defined in `common/rook/ressources/storageclasses.yaml` and deployed to all clusters via ArgoCD. Key parameters:

```yaml
parameters:
  clusterID: rook-ceph-external  # matches CephCluster resource name
  fsName: CephFS                  # Ceph filesystem name
  pool: CephFS_data               # data pool
```

The StorageClass will exist in all clusters but volumes can only be provisioned once the `CephCluster` reaches `Connected` phase (i.e., once credentials are imported).

## Importing Credentials (One-Time Setup per Cluster)

The `CephCluster` reaches `Connected` only when the Ceph external credentials are imported. This must be done once per cluster.

### Using the import script

```bash
# Run from this machine (requires SSH to Proxmox and kubectl to target cluster)
KUBECONFIG=/tmp/kubeconfig-sandbox.yaml \
  bash common/rook/import-external-cluster.sh
```

The script:
1. Downloads `rook-ceph-external-cluster-details-exporter.py` from the Rook GitHub releases
2. Runs it on `root@10.0.21.51` to extract Ceph credentials
3. Applies them to the `rook-ceph-external` namespace via `import-external-cluster.sh`

### Manual import (alternative)

If the script fails, do the steps manually:

**Step 1** — On a Proxmox node, download and run the exporter:

```bash
ssh root@10.0.21.51
curl -fsSL https://raw.githubusercontent.com/rook/rook/v1.15.7/deploy/examples/external-cluster-details-exporter.py \
  -o /tmp/exporter.py
python3 /tmp/exporter.py \
  --ceph-conf /etc/ceph/ceph.conf \
  --rbd-data-pool-name k8s \
  --cephfs-filesystem-name CephFS \
  --cephfs-data-pool-name CephFS_data \
  --cephfs-metadata-pool-name CephFS_metadata \
  > /tmp/cluster-details.json
cat /tmp/cluster-details.json
```

**Step 2** — Back on the management machine, apply the import:

```bash
export ROOK_EXTERNAL_CLUSTER_DETAILS=$(cat /tmp/cluster-details.json)
export NAMESPACE=rook-ceph-external
export KUBECONFIG=/tmp/kubeconfig-sandbox.yaml
curl -fsSL https://raw.githubusercontent.com/rook/rook/v1.15.7/deploy/examples/import-external-cluster.sh | bash
```

### Verify the import

```bash
kubectl get cephcluster -n rook-ceph-external
# Expected: phase=Connected, state=Connected

kubectl get secret -n rook-ceph-external
# Expected: rook-ceph-mon, rook-csi-cephfs-node, rook-csi-cephfs-provisioner, etc.

kubectl get storageclass cephfs
# Expected: cephfs (default) — rook-ceph.cephfs.csi.ceph.com
```

## Cluster Status Reference

| Cluster | CephCluster Phase | cephfs SC | ceph-rbd SC |
|---------|------------------|-----------|-------------|
| production-v2 | Connected ✓ | ✓ (default) | ✓ |
| k8s-shared | Connected ✓ | ✓ (default) | ✓ |
| sandbox | Connecting ✗ | ✓ (SC exists, non-functional) | ✓ (non-functional) |

## Troubleshooting

**CephCluster stuck in Connecting:**
- Verify no credentials secrets exist: `kubectl get secret -n rook-ceph-external`
- If empty, run the import script

**CSI provisioner logs show auth errors:**
```bash
kubectl logs -n rook-ceph deploy/csi-cephfsplugin-provisioner -c csi-cephfsplugin
```

**CephFS mount fails on a node (globalmount already exists):**
This happens after a node restarts and leaves stale kubelet mount directories.
```bash
# Find the CSI plugin pod on the affected node
kubectl get pod -n rook-ceph -l app=csi-cephfsplugin -o wide
# Delete it to force remount
kubectl delete pod -n rook-ceph <csi-cephfsplugin-pod-name>
```

**Test a CephFS PVC:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cephfs-test
spec:
  accessModes: [ReadWriteMany]
  storageClassName: cephfs
  resources:
    requests:
      storage: 1Gi
```
