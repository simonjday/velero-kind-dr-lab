#!/usr/bin/env bash
# Installs Velero (+ AWS plugin, + node-agent/Kopia) into a cluster.
# Usage: 03-install-velero.sh <primary|dr> [ReadWrite|ReadOnly]
#   default mode: primary=ReadWrite, dr=ReadOnly (Velero's recommendation for restore-side clusters)
# Also renders the same install as YAML into gitops/<role>/ for an ArgoCD-managed variant.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

role="${1:?usage: $0 <primary|dr> [ReadWrite|ReadOnly]}"
default_mode=ReadWrite; [ "$role" = "dr" ] && default_mode=ReadOnly
mode="${2:-$default_mode}"
ctx="$(ctx_for "$role")"
s3url="$(s3_url)"

banner "Velero ${VELERO_VERSION} -> ${ctx} (BSL ${mode})"
cluster_reachable "$role" || die "${ctx} not reachable"

creds="${STATE_DIR}/credentials-velero"
umask 077
cat > "${creds}" <<EOF
[default]
aws_access_key_id=${S3_ACCESS_KEY}
aws_secret_access_key=${S3_SECRET_KEY}
EOF
umask 022

install_args=(
  --provider aws
  --image "${VELERO_IMAGE}"
  --plugins "${VELERO_AWS_PLUGIN_IMAGE}"
  --bucket "${S3_BUCKET}"
  --secret-file "${creds}"
  --backup-location-config "region=${S3_REGION},s3ForcePathStyle=true,s3Url=${s3url},publicUrl=http://localhost:${S3_PORT}"
  --use-volume-snapshots=false
  --use-node-agent
  --uploader-type kopia
  --default-volumes-to-fs-backup
)

# GitOps render (contains the credentials Secret in plain text - seal/ESO it before committing)
mkdir -p "${LAB_ROOT}/gitops/${role}"
velero install "${install_args[@]}" --dry-run -o yaml > "${LAB_ROOT}/gitops/${role}/velero-install.yaml"
ok "rendered gitops/${role}/velero-install.yaml"

if k "$role" -n velero get deploy velero >/dev/null 2>&1; then
  ok "velero already installed in ${ctx}"
else
  velero --kubecontext "${ctx}" install "${install_args[@]}" --wait
fi

wait_until 180 "${ctx}: velero deployment Available" \
  k "$role" -n velero wait --for=condition=Available deploy/velero --timeout=5s
wait_until 180 "${ctx}: node-agent DaemonSet ready" \
  k "$role" -n velero rollout status ds/node-agent --timeout=5s

# SeaweedFS + AWS SDK v2 flexible checksums: disable the extra checksum header
# (same workaround the AWS plugin documents for Ceph/B2). Harmless if unneeded.
k "$role" -n velero patch backupstoragelocation default --type merge \
  -p '{"spec":{"config":{"checksumAlgorithm":""}}}' >/dev/null
ok "${ctx}: BSL checksumAlgorithm=\"\""

set_bsl_mode "$role" "${mode}"

wait_until 120 "${ctx}: BackupStorageLocation Available" bsl_available "$role"
v "$role" backup-location get
