#!/usr/bin/env bash
# FLOW 5 - Failback: rebuild/restart the original primary, move service back, re-arm the standby.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"
S="${LAB_ROOT}/scripts"

[ "$(active_role)" = "dr" ] || die "active site is '$(active_role)' - failback only makes sense after flow 2"
ts="$(date +%Y%m%d-%H%M%S)"
bk="failback-${ts}"

banner "FLOW 5: failback ${DR_CTX} -> ${PRIMARY_CTX}"

log "1. Bring the primary back"
if cluster_exists primary; then
  docker start "${PRIMARY_CLUSTER}-control-plane" "${PRIMARY_CLUSTER}-worker" >/dev/null
  wait_until 180 "${PRIMARY_CTX} API back" cluster_reachable primary
  wait_until 180 "${PRIMARY_CTX} nodes Ready" \
    k primary wait --for=condition=Ready nodes --all --timeout=5s
else
  "${S}/01-clusters.sh" primary
  "${S}/03-install-velero.sh" primary ReadOnly
fi
# FENCING: a restarted primary still has its schedules and a ReadWrite BSL - it could
# push a backup of its stale state into the shared bucket. Fence it immediately.
v primary schedule pause --all 2>/dev/null || true
set_bsl_mode primary ReadOnly
# ...and a revived primary would also resume taking traffic against its stale DB
if k primary -n "${DEMO_NS}" get deploy order-writer >/dev/null 2>&1; then set_writer primary 0; fi
pause

log "2. Stale state check: a 'stopped' primary still has the pre-disaster namespace"
if k primary get ns "${DEMO_NS}" >/dev/null 2>&1; then
  echo "   stale fingerprint on primary: $(db_fingerprint primary 2>/dev/null || echo n/a)"
  warn "restores skip existing objects, so the stale namespace must go first"
  k primary delete ns "${DEMO_NS}" --wait
fi
pause

log "3. Quiesce + final backup on DR (planned failback => RPO ~0)"
v dr schedule pause dr-demo-hourly 2>/dev/null || true
writer_was="$(writer_replicas dr)"
k dr -n "${DEMO_NS}" scale deploy/web --replicas=0
set_writer dr 0   # stop traffic: from here no write can be lost
k dr -n "${DEMO_NS}" wait --for=delete pod -l app=order-writer --timeout=60s >/dev/null 2>&1 || true
psql_q dr "${DEMO_NS}" "INSERT INTO orders(item) SELECT 'while-on-dr-' || g FROM generate_series(1,100) g;" >/dev/null
src="$(db_fingerprint dr)"
v dr backup create "${bk}" --include-namespaces "${DEMO_NS}" --ttl 168h --wait
wait_until 180 "${PRIMARY_CTX} sees ${bk}" backup_completed primary "${bk}"
pause

log "4. Restore on primary, promote it"
v primary restore create "restore-${bk}" --from-backup "${bk}" --wait
wait_until 300 "postgres-0 Ready on primary" \
  k primary -n "${DEMO_NS}" wait --for=condition=Ready pod/postgres-0 --timeout=5s
dst="$(db_fingerprint primary)"
echo "   dr     : ${src}"; echo "   primary: ${dst}"
[ "${src}" = "${dst}" ] || die "fingerprint mismatch"
ok "data identical - planned failback lost nothing (RPO 0)"
k primary -n "${DEMO_NS}" scale deploy/web --replicas=2
if [ "${writer_was:-0}" != "0" ]; then set_writer primary "${writer_was}"; fi

log "5. Swap roles: primary RW + active, DR RO + standby with workload removed"
set_bsl_mode primary ReadWrite
set_bsl_mode dr ReadOnly
v dr schedule delete dr-demo-hourly --confirm 2>/dev/null || true
k dr delete ns "${DEMO_NS}" --wait=false
set_active_role primary
ok "FLOW 5 PASSED - back to steady state"
