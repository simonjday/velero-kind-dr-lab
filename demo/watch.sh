#!/usr/bin/env bash
# Live single-cluster dashboard for presenting. Run one per terminal pane:
#   demo/watch.sh primary      demo/watch.sh dr
# Shows: reachability, BSL mode, latest backups/restores, demo pods + nodes, PVC->PV,
# and the orders table (rows, newest id, newest row age) refreshed every INTERVAL seconds.
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"

role="${1:?usage: $0 primary|dr}"
ctx="$(ctx_for "$role")"
INTERVAL="${INTERVAL:-2}"
kk() { kubectl --context "${ctx}" --request-timeout=3s "$@" 2>/dev/null; }

render() {
  local now; now="$(date +%H:%M:%S)"
  if ! kk get --raw=/readyz >/dev/null; then
    printf '\033[1;41m %s  DOWN / UNREACHABLE \033[0m  %s  (active site: %s)\n' "${ctx}" "${now}" "$(active_role)"
    return
  fi
  local tag="standby"; [ "$(active_role)" = "${role}" ] && tag="ACTIVE"
  printf '\033[1;42m %s  UP \033[0m  %s  [%s]\n\n' "${ctx}" "${now}" "${tag}"

  echo "BACKUP STORAGE LOCATION"
  kk -n velero get backupstoragelocations -o json | jq -r -f "${LAB_ROOT}/jq/bsl-summary.jq" | column -t -s $'\t'
  echo
  echo "LATEST BACKUPS"
  kk -n velero get backups -o json | jq -r -f "${LAB_ROOT}/jq/backup-summary.jq" \
    | awk 'NR==1{h=$0; next}{a[NR]=$0} END{print h; for(i=NR-3;i<=NR;i++) if(i in a) print a[i]}' \
    | cut -f1-3,5,6 | column -t -s $'\t'
  echo
  echo "LATEST RESTORES"
  kk -n velero get restores --sort-by=.metadata.creationTimestamp \
    -o custom-columns=NAME:.metadata.name,FROM:.spec.backupName,PHASE:.status.phase,WARN:.status.warnings,ERR:.status.errors \
    | tail -n 4
  echo
  echo "NAMESPACE ${DEMO_NS}"
  if ! kk get ns "${DEMO_NS}" >/dev/null; then
    printf '  \033[1;31m(namespace does not exist)\033[0m\n'; return
  fi
  kk -n "${DEMO_NS}" get pods \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,INIT:.spec.initContainers[*].name,NODE:.spec.nodeName'
  echo
  kk -n "${DEMO_NS}" get pvc \
    -o custom-columns='PVC:.metadata.name,STATUS:.status.phase,PV:.spec.volumeName,CLASS:.spec.storageClassName'
  echo
  echo "ORDERS TABLE  (writer replicas: $(kk -n "${DEMO_NS}" get deploy order-writer -o jsonpath='{.spec.replicas}'))"
  kk -n "${DEMO_NS}" exec postgres-0 -c postgres -- psql -U postgres -d demo -P pager=off -c \
    "SELECT count(*) AS rows, max(id) AS newest_id,
            to_char(max(created_at),'HH24:MI:SS') AS newest_at,
            round(extract(epoch FROM now()-max(created_at)))::int AS age_s,
            (SELECT item FROM orders ORDER BY id DESC LIMIT 1) AS newest_item
     FROM orders;" || printf '  \033[2m(postgres not answering yet)\033[0m\n'
}

while true; do
  out="$(render)"
  printf '\033[H\033[2J%s\n' "${out}"
  sleep "${INTERVAL}"
done
