#!/usr/bin/env bash
# Removes clusters and the S3 container. Pass --purge to also delete the backup data volume.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

banner "Teardown"
for role in primary dr; do
  name="$(cluster_for "$role")"
  if cluster_exists "$role"; then kind delete cluster --name "${name}"; ok "deleted ${name}"; fi
done
docker rm -f "${S3_CONTAINER}" >/dev/null 2>&1 && ok "removed ${S3_CONTAINER}" || true
if [ "${1:-}" = "--purge" ]; then
  docker volume rm "${S3_VOLUME}" >/dev/null 2>&1 && ok "removed volume ${S3_VOLUME} (all backups gone)" || true
  rm -rf "${STATE_DIR}" "${LAB_ROOT}/gitops/primary" "${LAB_ROOT}/gitops/dr"
else
  ok "kept volume ${S3_VOLUME} - backups survive; re-run up.sh and they re-sync"
fi
