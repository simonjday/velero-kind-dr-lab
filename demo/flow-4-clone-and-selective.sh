#!/usr/bin/env bash
# FLOW 4 - Restore variants without touching production:
#   a) clone the namespace under a new name (DR test / forensic copy)
#   b) selective restore of one tier by label
#   c) existing-resource-policy=update to repair drifted config
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"

role="$(active_role)"
ts="$(date +%Y%m%d-%H%M%S)"
bk="clone-src-${ts}"
clone_ns="${DEMO_NS}-clone"

banner "FLOW 4: clone & selective restores on $(ctx_for "$role")"
quiesce_writer_for_flow "$role"

v "$role" backup create "${bk}" --include-namespaces "${DEMO_NS}" --ttl 24h --wait
src="$(db_fingerprint "$role")"

log "a) Namespace mapping: ${DEMO_NS} -> ${clone_ns} (prod untouched)"
k "$role" delete ns "${clone_ns}" --ignore-not-found --wait >/dev/null
v "$role" restore create "clone-${ts}" --from-backup "${bk}" \
  --namespace-mappings "${DEMO_NS}:${clone_ns}" --wait
wait_until 240 "postgres-0 Ready in ${clone_ns}" \
  k "$role" -n "${clone_ns}" wait --for=condition=Ready pod/postgres-0 --timeout=5s
clone="$(db_fingerprint "$role" "${clone_ns}")"
echo "   source: ${src}"; echo "   clone : ${clone}"
[ "${src}" = "${clone}" ] || die "clone mismatch"
ok "clone matches source"
k "$role" -n "${DEMO_NS}" get pvc; k "$role" -n "${clone_ns}" get pvc
pause

log "b) Selective restore by label: only tier=frontend into a scratch namespace"
k "$role" delete ns "${DEMO_NS}-web" --ignore-not-found --wait >/dev/null
v "$role" restore create "web-only-${ts}" --from-backup "${bk}" \
  --namespace-mappings "${DEMO_NS}:${DEMO_NS}-web" \
  --selector tier=frontend \
  --include-resources deployments --wait
k "$role" -n "${DEMO_NS}-web" get deploy,pods
warn "web pods will fail to mount: the ConfigMap was filtered out - selective restores need their dependencies"
pause

log "c) Config drift repair: mutate a ConfigMap, restore with --existing-resource-policy=update"
k "$role" -n "${DEMO_NS}" patch configmap web-content --type merge \
  -p '{"data":{"index.html":"<h1>DEFACED</h1>"}}' >/dev/null
k "$role" -n "${DEMO_NS}" get cm web-content -o jsonpath='{.data.index\.html}{"\n"}' | sed 's/^/   now: /'
v "$role" restore create "repair-${ts}" --from-backup "${bk}" \
  --include-resources configmaps --existing-resource-policy update --wait
k "$role" -n "${DEMO_NS}" get cm web-content -o jsonpath='{.data.index\.html}{"\n"}' | sed 's/^/   after: /'

log "Cleanup scratch namespaces"
k "$role" delete ns "${clone_ns}" "${DEMO_NS}-web" --ignore-not-found --wait=false >/dev/null
ok "FLOW 4 done"
