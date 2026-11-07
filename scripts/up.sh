#!/usr/bin/env bash
# One-shot bootstrap: prereqs -> 2 kind clusters -> SeaweedFS -> Velero x2 -> demo app
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${here}/lib.sh"

start=$(date +%s)
"${here}/00-prereqs.sh"
"${here}/01-clusters.sh" primary dr
"${here}/02-object-store.sh"
"${here}/03-install-velero.sh" primary ReadWrite
"${here}/03-install-velero.sh" dr ReadOnly
"${here}/04-deploy-demo-app.sh" primary 1000
set_active_role primary

banner "Lab ready in $(( $(date +%s) - start ))s"
cat <<EOF
  Contexts : ${PRIMARY_CTX} (active, BSL ReadWrite)
             ${DR_CTX} (standby, BSL ReadOnly)
  S3       : $(s3_url)  (host: http://localhost:${S3_PORT}, filer UI http://127.0.0.1:8888)
  Next     : demo/flow-1-namespace-restore.sh
EOF
