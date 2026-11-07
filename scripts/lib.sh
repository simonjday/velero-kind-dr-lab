# shellcheck shell=bash
# Shared helpers. macOS ships bash 3.2 - no associative arrays / mapfile here.

# shellcheck source=scripts/env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
mkdir -p "${STATE_DIR}"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  ✘ %s\033[0m\n' "$*" >&2; exit 1; }
banner() { printf '\n\033[1;35m==== %s ====\033[0m\n' "$*"; }

pause() {
  # DEMO_AUTO=1 skips interactive pauses (CI / dry runs)
  [ "${DEMO_AUTO:-0}" = "1" ] && return 0
  printf '\033[2m  ⏎ press enter to continue...\033[0m'; read -r _
}

ctx_for() {
  case "$1" in
    primary) echo "${PRIMARY_CTX}" ;;
    dr)      echo "${DR_CTX}" ;;
    *)       die "unknown cluster role '$1' (expected primary|dr)" ;;
  esac
}

cluster_for() {
  case "$1" in
    primary) echo "${PRIMARY_CLUSTER}" ;;
    dr)      echo "${DR_CLUSTER}" ;;
    *)       die "unknown cluster role '$1'" ;;
  esac
}

k()  { local c; c="$(ctx_for "$1")"; shift; kubectl --context "${c}" "$@"; }
v()  { local c; c="$(ctx_for "$1")"; shift; velero --kubecontext "${c}" "$@"; }

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$(cluster_for "$1")"; }

cluster_reachable() { k "$1" --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; }

# wait_until <timeout-seconds> <description> <command...>
wait_until() {
  local timeout="$1" desc="$2"; shift 2
  local start; start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if [ $(( $(date +%s) - start )) -ge "${timeout}" ]; then
      die "timed out after ${timeout}s waiting for: ${desc}"
    fi
    sleep 3
  done
  ok "${desc}"
}

bsl_available() {
  [ "$(k "$1" -n velero get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null)" = "Available" ]
}

backup_phase() {
  k "$1" -n velero get backup "$2" -o jsonpath='{.status.phase}' 2>/dev/null
}

backup_completed() { [ "$(backup_phase "$1" "$2")" = "Completed" ]; }

set_bsl_mode() {
  # $1 role, $2 ReadWrite|ReadOnly
  k "$1" -n velero patch backupstoragelocation default --type merge \
    -p "{\"spec\":{\"accessMode\":\"$2\"}}" >/dev/null
  ok "$(ctx_for "$1"): BackupStorageLocation 'default' -> $2"
}

psql_q() {
  # psql_q <role> <namespace> <sql>
  k "$1" -n "$2" exec postgres-0 -c postgres -- \
    psql -U postgres -d demo -tAc "$3"
}

# Deterministic data fingerprint: row count + md5 of every row.
db_fingerprint() {
  psql_q "$1" "${2:-${DEMO_NS}}" \
    "SELECT count(*) || ':' || md5(string_agg(id || '|' || item || '|' || created_at::text, ',' ORDER BY id)) FROM orders;"
}

s3_url() { cat "${STATE_DIR}/s3url" 2>/dev/null || echo "http://${S3_CONTAINER}:${S3_PORT}"; }

aws_s3() {
  docker run --rm --network kind \
    -e AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
    -e AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
    -e AWS_DEFAULT_REGION="${S3_REGION}" \
    "${AWSCLI_IMAGE}" --endpoint-url "http://${S3_CONTAINER}:${S3_PORT}" "$@"
}

writer_replicas() {
  k "$1" -n "${2:-${DEMO_NS}}" get deploy order-writer -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0
}

set_writer() {
  # set_writer <role> <replicas> - scales the live-traffic generator
  k "$1" -n "${DEMO_NS}" scale deploy/order-writer --replicas="$2" >/dev/null
  if [ "$2" -gt 0 ]; then ok "$(ctx_for "$1"): order-writer ON (1 insert/s)"
  else ok "$(ctx_for "$1"): order-writer OFF"; fi
}

# Strict before/after fingerprints need a quiet database
quiesce_writer_for_flow() {
  if [ "$(writer_replicas "$1")" != "0" ]; then
    warn "order-writer is running - pausing it so the fingerprint comparison is meaningful"
    set_writer "$1" 0
    k "$1" -n "${DEMO_NS}" wait --for=delete pod -l app=order-writer --timeout=60s >/dev/null 2>&1 || true
  fi
}

# Per-row hashes, for comparing a restored prefix of the table against the source
row_hashes() {
  psql_q "$1" "${DEMO_NS}" \
    "SELECT id || '|' || md5(item || '|' || created_at::text) FROM orders ORDER BY id;"
}

active_role() { cat "${STATE_DIR}/active" 2>/dev/null || echo primary; }
set_active_role() { echo "$1" > "${STATE_DIR}/active"; ok "active site is now: $1"; }
