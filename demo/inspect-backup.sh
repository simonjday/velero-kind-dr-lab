#!/usr/bin/env bash
# Opens up a backup so the audience can SEE what Velero stored:
#  1) the object layout in the bucket   2) the resource tarball contents
#  3) one resource exactly as captured  4) the Kopia repository for volume data
# Usage: inspect-backup.sh [backup-name]   (default: newest backup)
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"

role="$(active_role)"
bk="${1:-$(k "$role" -n velero get backups --sort-by=.metadata.creationTimestamp \
          -o jsonpath='{.items[-1:].metadata.name}')}"
[ -n "${bk}" ] || die "no backups found"
banner "Inside backup ${bk}"

log "1. Bucket layout for this backup"
aws_s3 s3 ls "s3://${S3_BUCKET}/backups/${bk}/"
pause

log "2. Resource tarball (downloaded via the BSL publicUrl -> localhost:${S3_PORT})"
work="${STATE_DIR}/inspect"; rm -rf "${work}"; mkdir -p "${work}"
( cd "${work}" && v "$role" backup download "${bk}" -o "${bk}.tar.gz" >/dev/null )
tar -tzf "${work}/${bk}.tar.gz" | grep "namespaces/${DEMO_NS}/" | sort | sed 's/^/   /'
pause

log "3. The postgres StatefulSet exactly as Velero captured it (trimmed)"
tar -xzf "${work}/${bk}.tar.gz" -C "${work}"
f="$(find "${work}/resources/statefulsets.apps" -name 'postgres.json' | head -1)"
jq '{kind, name: .metadata.name, annotations: .spec.template.metadata.annotations, vct: [.spec.volumeClaimTemplates[].metadata.name]}' "$f"
pause

log "4. Volume data is NOT in the tarball - it is in the Kopia repository"
aws_s3 s3 ls "s3://${S3_BUCKET}/kopia/" || true
aws_s3 s3 ls "s3://${S3_BUCKET}/kopia/${DEMO_NS}/" | head -15 || true
echo "   (content-addressed, deduplicated, encrypted blobs - one repo per namespace)"
k "$role" -n velero get podvolumebackups -l "velero.io/backup-name=${bk}" -o json \
  | jq -r -f "${LAB_ROOT}/jq/podvolume-summary.jq" | column -t -s $'\t'
