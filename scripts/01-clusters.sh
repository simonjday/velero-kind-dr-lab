#!/usr/bin/env bash
# Creates the kind clusters on Docker Desktop and installs the FSB-friendly StorageClass.
# Usage: 01-clusters.sh [primary|dr ...]   (default: both)
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

roles="${*:-primary dr}"

for role in ${roles}; do
  name="$(cluster_for "$role")"
  banner "kind cluster: ${name} (${role})"

  if cluster_exists "$role"; then
    ok "cluster ${name} already exists"
  else
    kind create cluster --name "${name}" --image "${KIND_NODE_IMAGE}" \
      --config "${LAB_ROOT}/config/kind-cluster.yaml" --wait 120s
  fi

  wait_until 120 "${name}: nodes Ready" \
    k "$role" wait --for=condition=Ready nodes --all --timeout=5s

  # Swap default StorageClass: standard (hostPath) -> local-fsb (local PVs)
  k "$role" apply -f "${LAB_ROOT}/k8s/storageclass-local-fsb.yaml" >/dev/null
  k "$role" patch storageclass standard -p \
    '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null
  ok "${name}: default StorageClass -> local-fsb"

  # Probe: confirm PVs come out as spec.local (FSB-compatible)
  k "$role" delete -f "${LAB_ROOT}/k8s/pv-probe.yaml" --ignore-not-found --wait >/dev/null
  k "$role" apply  -f "${LAB_ROOT}/k8s/pv-probe.yaml" >/dev/null
  wait_until 120 "${name}: probe PVC bound" \
    sh -c "[ \"\$(kubectl --context $(ctx_for "$role") -n default get pvc pv-probe -o jsonpath='{.status.phase}')\" = Bound ]"
  pv="$(k "$role" -n default get pvc pv-probe -o jsonpath='{.spec.volumeName}')"
  if [ -n "$(k "$role" get pv "$pv" -o jsonpath='{.spec.local.path}')" ]; then
    ok "${name}: provisioned PV is type 'local' -> FSB will work"
  else
    warn "${name}: PV is NOT type 'local' (hostPath?) - Velero FSB will skip it. Check local-path-provisioner version."
  fi
  k "$role" delete -f "${LAB_ROOT}/k8s/pv-probe.yaml" --ignore-not-found >/dev/null
done

echo; kind get clusters
