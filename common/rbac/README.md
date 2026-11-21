# RBAC for Omni accounts (POC)

This directory is the Kubernetes half of the Omni access-control model. The
Omni half (AccessPolicies) lives in
[`Plateforme-Cedille/terraform/modules/user`](https://github.com/ClubCedille/Plateforme-Cedille/blob/main/terraform/modules/user/main.tf).

The short version, straight from the Omni docs:

- An AccessPolicy `role:` is an **Omni** role (`None`, `Reader`, `Operator`,
  `Admin`). It is **not** a Kubernetes ClusterRole name.
- A rule with `role: Operator` or `role: Admin` makes Omni add the Kubernetes
  `system:masters` group automatically. That is cluster-admin on that cluster
  and **RBAC cannot take it away**.
- `kubernetes.impersonate.groups` is the only bridge to Kubernetes. Omni
  impersonates those group names; each one must be bound to a Role or
  ClusterRole in the cluster. This directory provides those bindings.

References:

- <https://docs.siderolabs.com/omni/security-and-authentication/security-model>
- <https://docs.siderolabs.com/omni/security-and-authentication/how-to-manage-acls>
- <https://docs.siderolabs.com/omni/reference/acls>

## Access matrix

| Omni account role | ACL `role` | ACL `impersonate.groups` | Result in Kubernetes |
| ----------------- | ---------- | ------------------------ | -------------------- |
| `None` | none | none | No access. Kubeconfig only via `omnictl`. |
| `Reader` | `Reader` | `cedille-reader` | Read-only (no Secrets). |
| `Reader` | `Reader` | `cedille-operator` | Manage workloads, no cluster scope, no RBAC. |
| `Reader` | `Reader` | `cedille-operator` + namespace `RoleBinding` | Operator limited to that namespace. |
| `Operator` / `Admin` | any | any | **Cluster-admin everywhere** via `system:masters`. Cannot be restricted. |

The important consequence: to get least privilege, keep humans at Omni role
`None` or `Reader`, and express the Kubernetes level with groups. Only give
`Operator`/`Admin` to people who should be cluster-admin on every cluster.

## What is deployed

| File | Purpose |
| ---- | ------- |
| `ressources/cedille-reader.yaml` | ClusterRole, read-only, deliberately excludes Secrets. |
| `ressources/cedille-operator.yaml` | ClusterRole, namespaced workload management, no RBAC, no cluster scope. |
| `ressources/bindings.yaml` | ClusterRoleBindings for the `cedille-reader` and `cedille-operator` groups. |
| `rbac.argoapp.yml` | ApplicationSet that applies the above to every cluster registered in Argo CD. |
| `examples/omni-access-policy.yaml` | Example Omni ACL using the groups. Not applied by Argo. |
| `examples/namespace-rolebinding.yaml` | Example of limiting `cedille-operator` to one namespace. |
| `verify.sh` | `kubectl auth can-i` smoke test to run with a real user kubeconfig. |

There is deliberately **no** `admin` ClusterRole here. Defining a ClusterRole
named `admin` would overwrite the Kubernetes built-in `admin` role and turn
every namespace `RoleBinding` that references it into `*/*/*`. Omni
`Operator`/`Admin` already get cluster-admin through `system:masters`.

## Rollout

1. Merge this ApplicationSet. It only creates the two ClusterRoles and two
   bindings; nobody gains access until an ACL references the groups.
2. Update the Omni ACL generator so it emits `cedille-reader` /
   `cedille-operator` instead of `reader` + username (see the POC change in
   `Plateforme-Cedille`).
3. The POC targets `k8s-shared`. Make sure the ACL rules actually use that
   name: set the Terraform Cloud `cluster_name` variable to `k8s-shared`
   (the repo default is now `k8s-shared`, but the workspace value wins).
   The current generated files still say `cedille-cluster`, which does not
   exist, so those rules match nothing.
   Note: retargeting **all** generated ACLs also applies each user's
   `cluster_role` on `k8s-shared`; every `Operator` user gets `system:masters`
   there. Review that before regenerating the whole `omni/` directory.
4. Apply the resulting AccessPolicy with `omnictl apply -f ...` as an Omni
   `Admin`. Omni runs the `spec.tests` block and rejects the policy if the
   expected role/groups do not match.

## Verify

Use the **actual user's** kubeconfig (downloaded from Omni), then:

```bash
./verify.sh reader
./verify.sh operator
```

The checks assert both the positive and negative cases, e.g. a reader can
list pods but cannot read Secrets or delete anything, and an operator can
create a Deployment but cannot delete a Node or create a RoleBinding.

Do not run the checks with an admin or `system:masters` kubeconfig: they will
all pass and prove nothing.
