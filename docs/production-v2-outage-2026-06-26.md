# Production-v2 Cluster Outage: 2026-06-26

**Cluster:** `k8s-cedille-production-v2`  
**Duration:** ~1 day (2026-06-26 to 2026-06-27)  
**Impact:** All 10 nodes offline, all hosted services unreachable  
**Root cause:** MTU mismatch on Proxmox VLAN bridge + missing explicit ens19 DHCP config in Omni

## Timeline

| Time (UTC) | Event |
|------------|-------|
| 2026-06-26 | Network/firewall change on Proxmox changes MTU on vmbr1 bridge to 9216 |
| 2026-06-26 | All 10 nodes lose SideroLink connectivity to Omni (0/10 RUNNING) |
| 2026-06-26 | All hosted services become unreachable |
| 2026-06-26 | MTU fix applied to Proxmox VM NICs (`mtu=1` on net1) |
| 2026-06-27 | Explicit `ens19: dhcp: true` added to all Omni machine patches |
| 2026-06-27 | 6/6 workers and 3/4 CPs come back online immediately |
| 2026-06-27 | Worker-5 static IP assigned (10.5.10.50) to resolve DHCP conflict |
| 2026-06-27 | CP-2 recovers (was stuck in BOOTING due to etcd peer URL issue) |
| 2026-06-27 | Post-recovery: all services show 503 due to stale Flannel annotation |
| 2026-06-27 | Flannel annotation fix + CSI plugin restart restore services |

## Root Causes

### 1. Proxmox Bridge MTU 9216 → WireGuard PMTU Black Hole

**What happened:**  
A network configuration change set the `vmbr1` bridge (VLAN 1010, the Kubernetes main network) MTU to 9216 (jumbo frames). Talos VMs on that bridge inherited this MTU. WireGuard (used by SideroLink) set its MTU to 9156 (bridge MTU minus 60 bytes overhead). The resulting WireGuard UDP packets were 9216 bytes — silently dropped by the OPNsense firewall interface on VLAN 1010 (which has MTU 1500). This caused all SideroLink gRPC TLS handshakes to fail, disconnecting all nodes from Omni.

**Fix:**  
Set `mtu=1` on `net1` (VLAN 1010) for all 10 VMs via Proxmox CLI. The value `1` is a Proxmox sentinel meaning "inherit the VLAN sub-interface MTU" (1500), not the bridge MTU (9216).

```bash
# Applied to VMs 1010000-1010003 (CPs) and 1010010-1010015 (workers)
# on pve01-pve07 (10.0.21.51-57)
qm set <vmid> --net1 "virtio=<MAC>,bridge=vmbr1,tag=1010,mtu=1"
```

**Why it wasn't caught sooner:**  
WireGuard PMTU black holes are silent — packets are dropped without ICMP Fragmentation Needed messages when the path doesn't support PMTU discovery (common in internal VLANs). The TLS handshake failure looked like a network connectivity issue rather than an MTU issue.

### 2. ens19 (VLAN 1010) Not Reliably Coming Up Without Explicit Talos Config

**What happened:**  
All Omni per-machine config patches defined `ens18` (VLAN 500) and `ens20` (VLAN 247) explicitly, but `ens19` (VLAN 1010, the main Kubernetes network) was absent. Without an explicit entry, Talos did not reliably bring up ens19 and complete DHCP on VLAN 1010 after a cold boot.

**Fix:**  
Added `ens19: dhcp: true` explicitly to all 10 machine config patches in Omni. Even though DHCP is the default behavior, the explicit entry ensures Talos always brings up the interface.

```yaml
# Added to every machine's Omni patch (by MAC address selector)
machine:
  network:
    interfaces:
      - deviceSelector:
          hardwareAddr: <ens19-mac>
        dhcp: true
```

**This was the critical fix** — once applied, 9 of 10 nodes came back online immediately.

### 3. Worker-5 DHCP Conflict (10.5.10.2 = OPNsense's Own IP)

**What happened:**  
OPNsense's DHCP pool for VLAN 1010 starts at `10.5.10.2`, but `10.5.10.2` is also OPNsense's own static IP on that interface. Worker-5 received this address via DHCP, creating a routing loop: traffic destined for the gateway was being routed to the node itself.

**Fix:**  
Assigned worker-5 a static IP via Omni config patch:
- MAC: `bc:24:11:23:01:52` (ens19)
- IP: `10.5.10.50/24`
- Gateway: `10.5.10.2`

```yaml
# Omni patch ID: 600-e6103206-c158-04b7-417c-3b704f15b295
machine:
  network:
    interfaces:
      - deviceSelector:
          hardwareAddr: bc:24:11:23:01:52
        dhcp: false
        addresses:
          - 10.5.10.50/24
        routes:
          - network: 0.0.0.0/0
            gateway: 10.5.10.2
```

**Note:** The OPNsense DHCP pool minimum should be raised above `10.5.10.2` to prevent this from happening again.

## Secondary Issues Found During Recovery

### Stale Flannel Annotation Causing 503s

After the cluster came back online, **all services returned HTTP 503**. Root cause:

- MetalLB elected worker-5 as the L2 speaker for `142.137.247.79` (the external IP)
- All external traffic arrived at worker-5
- Worker-5's Flannel node annotation `flannel.alpha.coreos.com/public-ip` still had `10.5.10.32` (a transient DHCP lease from the early recovery phase before the static IP took effect)
- Worker-5's actual IP was `10.5.10.50`
- Backend pods on other nodes sent replies to `10.5.10.32` (wrong), packets were lost, all requests returned `503 UF (Upstream connection Failure)` from Envoy

**Fix:**
```bash
kubectl annotate node k8s-cedille-production-v2-worker-5 \
  flannel.alpha.coreos.com/public-ip=10.5.10.50 --overwrite
kubectl delete pod -n kube-system <kube-flannel-pod-on-worker-5>
```

### CP-2 etcd Stale Peer URL

After rebooting CP-2 (which had changed from 10.5.10.26 to 10.5.10.33), its etcd peer URL remained `https://10.5.10.26:2380`. This caused "failed to publish local member to cluster through raft" errors. CP-2 eventually self-healed, but if it had not:

```bash
# Find and remove the stale member from a healthy CP
talosctl --nodes <healthy-cp-ip> etcd members
talosctl --nodes <healthy-cp-ip> etcd remove-member <stale-member-id>
```

**Recommendation:** Assign static IPs to all control plane nodes to prevent etcd peer URL staleness across reboots. See the VLAN layout below for available addresses.

### Stale CSI globalmount After Cluster Restart

After the cluster restart, `csi-cephfsplugin` on worker-5 had a stale kubelet mount directory for `planifets-qdrant`. Fix: delete the CSI plugin pod to force kubelet to clean up the stale directory.

```bash
kubectl delete pod -n rook-ceph <csi-cephfsplugin-pod-on-worker-5>
```

## Network Layout Reference

```
Interface  VLAN   Subnet              Role
─────────────────────────────────────────────────────────
ens18      500    (disabled)          Inter-node (unused)
ens19      1010   10.5.10.0/24        Kubernetes main; DHCP from OPNsense (gw: 10.5.10.2)
ens20      247    142.137.247.0/24    WAN/external; static route on workers only
```

**IMPORTANT:** Always include `ens19` explicitly in Omni config patches with `dhcp: true`.  
Without it, Talos may not bring up the interface after cold boots.

### IP Assignments (VLAN 1010, 10.5.10.0/24)

| Node | Role | IP |
|------|------|----|
| CP-1 | Control Plane | DHCP (~10.5.10.3) |
| CP-2 | Control Plane | DHCP (~10.5.10.33) — recommend static |
| CP-3 | Control Plane | DHCP |
| CP-4 | Control Plane | DHCP |
| Worker-1 through Worker-4 | Worker | DHCP |
| Worker-5 | Worker (MetalLB speaker) | **Static: 10.5.10.50** |
| Worker-6 | Worker | DHCP |

**Recommendation:** Assign static IPs to all 4 control planes (e.g., 10.5.10.101–104) to prevent etcd peer URL churn.

## Proxmox Host Reference

| Host | IP |
|------|----|
| pve01 | 10.0.21.51 |
| pve02 | 10.0.21.52 |
| pve03 | 10.0.21.53 |
| pve04 | 10.0.21.54 |
| pve05 | 10.0.21.55 |
| pve06 | 10.0.21.56 |
| pve07 | 10.0.21.57 |
| pve08 | 10.0.21.58 |

## Lessons Learned

1. **MTU on Proxmox bridges is not inherited as expected.** After any Proxmox network change, verify `mtu=1` is set on VM NICs for VLANs that traverse non-jumbo-frame paths (OPNsense/WAN-facing). WireGuard amplifies MTU mismatches because it adds fixed overhead.

2. **Always explicitly define ens19 in Omni patches.** DHCP is implicit but not reliably applied without an explicit interface entry. Any future machine config changes should include `ens19: dhcp: true`.

3. **MetalLB + Flannel node annotations must be correct.** After any node IP change, verify `flannel.alpha.coreos.com/public-ip` matches the actual node IP. If MetalLB elects that node as L2 speaker and the annotation is wrong, all external traffic silently fails.

4. **CP nodes should have static IPs.** etcd peer URLs are bound to IP at initial registration. DHCP-assigned IPs that change after reboot break etcd peer communication. Assign static IPs via Omni patches for all control planes.

5. **DHCP pool on OPNsense should not include the gateway IP.** The gateway `10.5.10.2` must be excluded from the DHCP pool range to prevent the type of conflict that hit worker-5.
