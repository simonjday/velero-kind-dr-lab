#!/usr/bin/env bash
# FLOW 1 - Operational recovery: "someone deleted the namespace"
# Backup ns -> delete ns -> restore -> prove data identical.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"

role="$(active_role)"
ts="$(date +%Y%m%d-%H%M%S)"
bk="ns-${DEMO_NS}-${ts}"

banner "FLOW 1: namespace backup & restore on $(ctx_for "$role")"
quiesce_writer_for_flow "$role"

log "1. Baseline"
before="$(db_fingerprint "$role")"
echo "   fingerprint before: ${before}"
k "$role" -n "${DEMO_NS}" get all,pvc,cm,secret -o name | sed 's/^/   /'
pause

log "2. Backup namespace (FSB/Kopia for the PVC, pre-hook runs CHECKPOINT)"
v "$role" backup create "${bk}" --include-namespaces "${DEMO_NS}" --ttl 72h --wait
v "$role" backup describe "${bk}" --details | sed -n '1,200p'
k "$role" -n velero get podvolumebackups -l "velero.io/backup-name=${bk}" -o json \
  | jq -r -f "${LAB_ROOT}/jq/podvolume-summary.jq" | column -t -s $'\t'
pause

log "3. Disaster: delete the namespace"
k "$role" delete namespace "${DEMO_NS}" --wait
k "$role" get ns "${DEMO_NS}" 2>&1 | sed 's/^/   /' || true
pause

log "4. Restore"
v "$role" restore create "restore-${bk}" --from-backup "${bk}" --wait
v "$role" restore describe "restore-${bk}" --details | sed -n '1,120p'
wait_until 180 "postgres-0 Ready after restore" \
  k "$role" -n "${DEMO_NS}" wait --for=condition=Ready pod/postgres-0 --timeout=5s

log "   Note the init container Velero injected to block start-up until the volume data landed:"
k "$role" -n "${DEMO_NS}" get pod postgres-0 -o jsonpath='{range .spec.initContainers[*]}{.name}{"  "}{.image}{"\n"}{end}' | sed 's/^/   /'

log "5. Verify"
after="$(db_fingerprint "$role")"
echo "   before: ${before}"
echo "   after : ${after}"
[ "${before}" = "${after}" ] || die "fingerprint mismatch"
ok "data identical - FLOW 1 PASSED"

cat <<'EOF'

  Teaching points
  - Restore is additive: had the namespace still existed, existing objects would be
    SKIPPED (default --existing-resource-policy=none). Velero never rewinds a live PVC.
  - To roll back corrupted data in place: delete the PVC/workload (or the ns) first,
    or restore into a new namespace (flow 4) and cut over.
EOF
