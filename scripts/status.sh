#!/usr/bin/env bash
# Lab dashboard: BSLs, backups, pod-volume backups, bucket layout, data fingerprints.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
J="${LAB_ROOT}/jq"

echo "Active site: $(active_role)"
for role in primary dr; do
  banner "$(ctx_for "$role")"
  if ! cluster_reachable "$role"; then warn "unreachable (stopped/deleted)"; continue; fi
  echo "-- BackupStorageLocations"
  k "$role" -n velero get backupstoragelocations -o json | jq -r -f "${J}/bsl-summary.jq" | column -t -s $'\t'
  echo "-- Backups"
  k "$role" -n velero get backups -o json | jq -r -f "${J}/backup-summary.jq" | column -t -s $'\t'
  echo "-- PodVolumeBackups"
  k "$role" -n velero get podvolumebackups -o json | jq -r -f "${J}/podvolume-summary.jq" | column -t -s $'\t'
  if k "$role" -n "${DEMO_NS}" get pod postgres-0 >/dev/null 2>&1; then
    echo "-- ${DEMO_NS} fingerprint: $(db_fingerprint "$role" 2>/dev/null || echo n/a)"
  fi
done

banner "s3://${S3_BUCKET} (top level)"
aws_s3 s3 ls "s3://${S3_BUCKET}/" || true
aws_s3 s3 ls "s3://${S3_BUCKET}/backups/" || true
