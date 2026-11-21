#!/usr/bin/env bash
# Smoke-test the cedille-reader / cedille-operator RBAC contract.
#
# Run this with the actual Omni user's kubeconfig, never with a
# cluster-admin / system:masters one:
#
#   KUBECONFIG=~/alice-kubeconfig ./verify.sh reader
#   KUBECONFIG=~/bob-kubeconfig   ./verify.sh operator
#
# Optional: NAMESPACE=<ns> to test a namespace other than "default".

set -uo pipefail

mode="${1:-}"
namespace="${NAMESPACE:-default}"
failures=0

if [[ "$mode" != "reader" && "$mode" != "operator" ]]; then
  echo "usage: $0 <reader|operator>" >&2
  exit 2
fi

check() {
  local expected="$1"
  local description="$2"
  shift 2

  local got
  if kubectl auth can-i "$@" --namespace "$namespace" >/dev/null 2>&1; then
    got="yes"
  else
    got="no"
  fi

  if [[ "$got" == "$expected" ]]; then
    printf 'ok    %-62s (%s)\n' "$description" "$got"
  else
    printf 'FAIL  %-62s expected %s, got %s\n' "$description" "$expected" "$got"
    failures=$((failures + 1))
  fi
}

echo "Testing '$mode' contract in namespace '$namespace'"
echo

# Common read-only guarantees.
check yes "get pods"
check yes "list pods/log"
check yes "list deployments.apps"
check yes "list ingresses.networking.k8s.io"
check no  "get secrets"
check no  "delete pods"
check no  "delete nodes"
check no  "create clusterrolebindings.rbac.authorization.k8s.io"

if [[ "$mode" == "reader" ]]; then
  check no "create deployments.apps"
  check no "create configmaps"
else
  check yes "create deployments.apps"
  check yes "create configmaps"
  check yes "create ingresses.networking.k8s.io"
  check yes "delete pods"
  check yes "get secrets"

  # Still not an admin.
  check no "create rolebindings.rbac.authorization.k8s.io"
  check no "create namespaces"
  check no "create customresourcedefinitions.apiextensions.k8s.io"
  check no "create persistentvolumes"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi

echo "all checks passed"
