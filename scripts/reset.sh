#!/usr/bin/env bash
# Return the lab to its post-up.sh starting state WITHOUT rebuilding clusters
# (typically 2-4 min vs 5-8 min for teardown --purge + up.sh).
#
#   - primary brought back if stopped (docker start) or deleted (rebuilt + Velero RW)
#   - schedules, restores and (unless --keep-backups) all backups removed
#   - demo/scratch namespaces removed from both clusters
#   - BSL modes: primary ReadWrite, dr ReadOnly; active site = primary
#   - dr-demo redeployed on primary with fresh seed data, order-writer off
#
# Usage: reset.sh [--keep-backups] [--rows N]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${here}/lib.sh"

keep_backups=0; rows=1000
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-backups) keep_backups=1 ;;
    --rows) shift; rows="${1:?--rows needs a number}" ;;
    *) die "unknown option $1 (use --keep-backups, --rows N)" ;;
  esac
  shift
done
NAMESPACES="${DEMO_NS} ${DEMO_NS}-clone ${DEMO_NS}-web"
start=$(date +%s)

banner "Reset: object store"
"${here}/02-object-store.sh" >/dev/null 2>&1 || true   # starts the container if stopped (idempotent)
wait_until 60 "S3 answering on localhost:${S3_PORT}" \
  sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${S3_PORT}/)\" != 000 ]"

banner "Reset: clusters reachable"
if ! cluster_exists primary; then
  warn "primary was deleted - rebuilding"
  "${here}/01-clusters.sh" primary
  "${here}/02-object-store.sh"
  "${here}/03-install-velero.sh" primary ReadWrite
elif ! cluster_reachable primary; then
  log "primary nodes stopped - starting them"
  docker start "${PRIMARY_CLUSTER}-control-plane" "${PRIMARY_CLUSTER}-worker" >/dev/null
  wait_until 180 "${PRIMARY_CTX} API back" cluster_reachable primary
  wait_until 180 "${PRIMARY_CTX} nodes Ready" k primary wait --for=condition=Ready nodes --all --timeout=5s
else
  ok "${PRIMARY_CTX} reachable"
fi
if ! cluster_exists dr; then
  warn "dr was deleted - rebuilding"
  "${here}/01-clusters.sh" dr
  "${here}/02-object-store.sh"
  "${here}/03-install-velero.sh" dr ReadOnly
elif ! cluster_reachable dr; then
  docker start "${DR_CLUSTER}-control-plane" "${DR_CLUSTER}-worker" >/dev/null
  wait_until 180 "${DR_CTX} API back" cluster_reachable dr
fi

banner "Reset: stop all writers and schedules (fence both sites)"
for role in primary dr; do
  if k "$role" -n "${DEMO_NS}" get deploy order-writer >/dev/null 2>&1; then set_writer "$role" 0; fi
  v "$role" schedule delete --all --confirm >/dev/null 2>&1 || true
  ok "$(ctx_for "$role"): schedules deleted"
done

banner "Reset: Velero history"
# Restore deletion also removes restore logs from the bucket -> needs a RW location
set_bsl_mode dr ReadWrite
for role in primary dr; do
  v "$role" restore delete --all --confirm >/dev/null 2>&1 || true
  ok "$(ctx_for "$role"): restores deleted"
done

if [ "${keep_backups}" = "0" ]; then
  # Delete from ONE site only (primary). The bucket is shared: DR's BSL sync then drops
  # its copies of the Backup CRs. Velero also removes the backups' Kopia snapshots;
  # repository maintenance reclaims the space later.
  set_bsl_mode dr ReadOnly
  v primary backup delete --all --confirm >/dev/null 2>&1 || true
  wait_until 300 "all backup folders gone from s3://${S3_BUCKET}/backups/" \
    sh -c "[ -z \"\$(docker run --rm --network kind -e AWS_ACCESS_KEY_ID=${S3_ACCESS_KEY} \
      -e AWS_SECRET_ACCESS_KEY=${S3_SECRET_KEY} -e AWS_DEFAULT_REGION=${S3_REGION} ${AWSCLI_IMAGE} \
      --endpoint-url http://${S3_CONTAINER}:${S3_PORT} s3 ls s3://${S3_BUCKET}/backups/ 2>/dev/null)\" ]"
  wait_until 180 "${PRIMARY_CTX}: no Backup CRs left" \
    sh -c "[ -z \"\$(kubectl --context ${PRIMARY_CTX} -n velero get backups -o name 2>/dev/null)\" ]"
  # DR: BSL sync prunes CRs whose objects vanished from the bucket. If any linger,
  # deleting the CR directly is safe now - the bucket has nothing left to re-sync.
  for _ in $(seq 1 30); do
    [ -z "$(k dr -n velero get backups -o name 2>/dev/null)" ] && break
    sleep 3
  done
  k dr -n velero delete backups --all >/dev/null 2>&1 || true
  ok "${DR_CTX}: no Backup CRs left"
else
  ok "--keep-backups: backups left in place (they will show in both clusters)"
fi

banner "Reset: namespaces"
for role in primary dr; do
  for ns in ${NAMESPACES}; do
    k "$role" delete ns "${ns}" --ignore-not-found --wait=false >/dev/null
  done
done
for role in primary dr; do
  for ns in ${NAMESPACES}; do
    wait_until 180 "$(ctx_for "$role"): ns ${ns} gone" \
      sh -c "! kubectl --context $(ctx_for "$role") get ns ${ns} >/dev/null 2>&1"
  done
done

banner "Reset: roles"
set_bsl_mode primary ReadWrite
set_bsl_mode dr ReadOnly
for role in primary dr; do wait_until 120 "$(ctx_for "$role"): BSL Available" bsl_available "$role"; done
set_active_role primary
rm -rf "${STATE_DIR}/inspect" "${STATE_DIR}"/*rows*.txt

"${here}/04-deploy-demo-app.sh" primary "${rows}"

banner "Reset complete in $(( $(date +%s) - start ))s"
"${here}/status.sh"
