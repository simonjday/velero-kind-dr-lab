#!/usr/bin/env bash
# FLOW 2 - Site DR: lose the primary cluster, recover on the DR cluster.
# DISASTER_MODE=stop   (default) docker-stop the primary's nodes (reversible)
# DISASTER_MODE=delete           kind delete the primary (true loss)
#
# Two verification modes, chosen automatically:
#  - quiet DB (order-writer off): strict whole-table fingerprint, before == after
#  - live DB  (order-writer on, see demo/live-writes.sh): the restored table must be an
#    exact PREFIX of what the primary held at the moment of disaster; the missing tail
#    is the data loss, measured in rows and seconds (= the real RPO).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"

mode="${DISASTER_MODE:-stop}"
[ "$(active_role)" = "primary" ] || die "active site is '$(active_role)'; run flow-5-failback.sh first"
ts="$(date +%Y%m%d-%H%M%S)"
bk="dr-${ts}"
live=0; [ "$(writer_replicas primary)" != "0" ] && live=1
LIVE_TAIL_SECONDS="${LIVE_TAIL_SECONDS:-20}"

banner "FLOW 2: cluster DR ${PRIMARY_CTX} -> ${DR_CTX} (disaster=${mode}, live-writes=${live})"

log "1. Generate fresh business data on primary"
psql_q primary "${DEMO_NS}" "INSERT INTO orders(item) SELECT 'pre-dr-${ts}-' || g FROM generate_series(1,250) g;" >/dev/null
before="$(db_fingerprint primary)"
echo "   fingerprint: ${before}"
pause

log "2. Backup (namespace + the cluster-scoped objects it references, e.g. its PVs)"
v primary backup create "${bk}" \
  --include-namespaces "${DEMO_NS}" \
  --ttl 168h --wait
pause

log "3. Standby picks the backup up from the shared bucket (BSL sync, default 1m)"
v dr backup-location get
wait_until 180 "${DR_CTX} sees backup ${bk} as Completed" backup_completed dr "${bk}"
v dr backup get
pause

if [ "${live}" = "1" ]; then
  log "3b. Business carries on after the backup - these writes are NOT in ${bk}"
  sleep "${LIVE_TAIL_SECONDS}"
  echo "   rows written since backup started: $(psql_q primary "${DEMO_NS}" \
    "SELECT count(*) FROM orders WHERE created_at >= '$(k primary -n velero get backup "${bk}" -o jsonpath='{.status.startTimestamp}')';")"
fi

log "4. DISASTER"
# Last look at the primary: its final state, captured from the DB's own clock
primary_max="$(psql_q primary "${DEMO_NS}" "SELECT max(id) FROM orders;")"
t0_db="$(psql_q primary "${DEMO_NS}" "SELECT now();")"
row_hashes primary > "${STATE_DIR}/primary-rows-at-disaster.txt"
t0=$(date +%s)
case "${mode}" in
  stop)
    docker stop "${PRIMARY_CLUSTER}-control-plane" "${PRIMARY_CLUSTER}-worker" >/dev/null
    ok "primary nodes stopped" ;;
  delete)
    kind delete cluster --name "${PRIMARY_CLUSTER}"
    ok "primary cluster deleted" ;;
  *) die "DISASTER_MODE must be stop|delete" ;;
esac
if cluster_reachable primary; then die "primary still reachable?"; fi
ok "${PRIMARY_CTX} is gone (last row id ${primary_max} at ${t0_db})"
pause

log "5. Declare DR: promote standby BSL to ReadWrite, restore"
set_bsl_mode dr ReadWrite
v dr restore create "restore-${bk}" --from-backup "${bk}" --wait
wait_until 300 "postgres-0 Ready on DR" \
  k dr -n "${DEMO_NS}" wait --for=condition=Ready pod/postgres-0 --timeout=5s
wait_until 120 "web Available on DR" \
  k dr -n "${DEMO_NS}" wait --for=condition=Available deploy/web --timeout=5s
t1=$(date +%s)
set_active_role dr

log "6. Verify"
if [ "${live}" = "0" ]; then
  after="$(db_fingerprint dr)"
  echo "   primary (pre-disaster): ${before}"
  echo "   dr      (restored)    : ${after}"
  [ "${before}" = "${after}" ] || die "fingerprint mismatch"
  ok "data identical - FLOW 2 PASSED"
else
  # Rows created before the disaster can only have come from the backup
  restored_max="$(psql_q dr "${DEMO_NS}" "SELECT max(id) FROM orders WHERE created_at < '${t0_db}';")"
  row_hashes dr | awk -F'|' -v m="${restored_max}" '$1 <= m' > "${STATE_DIR}/dr-rows-restored.txt"
  awk -F'|' -v m="${restored_max}" '$1 <= m' "${STATE_DIR}/primary-rows-at-disaster.txt" > "${STATE_DIR}/primary-rows-prefix.txt"
  if cmp -s "${STATE_DIR}/primary-rows-prefix.txt" "${STATE_DIR}/dr-rows-restored.txt"; then
    ok "restored rows 1..${restored_max} are byte-identical to the primary's"
  else
    die "restored prefix differs from primary - inspect ${STATE_DIR}/*rows*.txt"
  fi
  rpo_s="$(psql_q dr "${DEMO_NS}" \
    "SELECT round(extract(epoch FROM (timestamptz '${t0_db}' - created_at)))::int FROM orders WHERE id = ${restored_max};")"
  echo "   primary's last row   : ${primary_max}"
  echo "   newest restored row  : ${restored_max}"
  echo "   LOST WRITES          : $(( primary_max - restored_max )) rows  (≈ ${rpo_s}s of business = actual RPO)"
  echo "   new writes on DR     : $(psql_q dr "${DEMO_NS}" "SELECT count(*) FROM orders WHERE created_at > '${t0_db}';") (writer restored with replicas=1, service resumed)"
  ok "FLOW 2 PASSED (live mode)"
fi
echo "   measured RTO (disaster -> app ready): $(( t1 - t0 ))s"
v dr restore describe "restore-${bk}" | sed -n '1,40p'

log "7. Re-establish protection on the new active site"
v dr schedule create dr-demo-hourly --schedule "@every 1h" \
  --include-namespaces "${DEMO_NS}" --ttl 72h 2>/dev/null || ok "schedule exists"
v dr schedule get

cat <<EOF

  Teaching points
  - The bucket was the only thing that crossed the 'site' boundary - it lived outside both clusters.
  - The standby ran ReadOnly until DR was declared, so it could not prune or overwrite primary backups.
  - Writes made after ${bk} was taken are gone: that gap is your RPO; schedule frequency sets it.
  - Live mode: the DR database carries on its id sequence from the backup (plus Postgres' small
    crash-recovery skip), so ids the primary had already used can be issued again for DIFFERENT
    rows. The sites have diverged - which is why failback is a one-way copy (flow 5), never a merge.
  - Next: demo/flow-5-failback.sh brings the primary back and returns service to it.
EOF
