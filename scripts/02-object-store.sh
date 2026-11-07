#!/usr/bin/env bash
# Runs SeaweedFS (S3 gateway) as a standalone container on the 'kind' docker
# network - i.e. OUTSIDE both clusters, so it survives the loss of either.
# Data lives in a named docker volume.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

banner "Object storage: SeaweedFS S3 on docker network 'kind'"

docker network inspect kind >/dev/null 2>&1 || die "docker network 'kind' missing - run 01-clusters.sh first"

# S3 identities file generated from env.sh so creds live in one place
cat > "${STATE_DIR}/s3.json" <<EOF
{
  "identities": [
    {
      "name": "velero",
      "credentials": [
        { "accessKey": "${S3_ACCESS_KEY}", "secretKey": "${S3_SECRET_KEY}" }
      ],
      "actions": ["Admin", "Read", "Write"]
    }
  ]
}
EOF

if docker ps -a --format '{{.Names}}' | grep -qx "${S3_CONTAINER}"; then
  docker start "${S3_CONTAINER}" >/dev/null
  ok "container ${S3_CONTAINER} already exists (started)"
else
  docker volume create "${S3_VOLUME}" >/dev/null
  docker run -d --name "${S3_CONTAINER}" --restart unless-stopped \
    --network kind \
    -p "127.0.0.1:${S3_PORT}:8333" \
    -p "127.0.0.1:8888:8888" \
    -v "${S3_VOLUME}:/data" \
    -v "${STATE_DIR}/s3.json:/etc/seaweedfs/s3.json:ro" \
    "${SEAWEEDFS_IMAGE}" \
    server -dir=/data -s3 -s3.config=/etc/seaweedfs/s3.json \
           -master.volumeSizeLimitMB=1024 >/dev/null
  ok "started ${S3_CONTAINER} (${SEAWEEDFS_IMAGE})"
fi

wait_until 90 "S3 endpoint answering on localhost:${S3_PORT}" \
  sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${S3_PORT}/)\" != 000 ]"

# Bucket (idempotent). SeaweedFS needs a few seconds after boot before it allocates volumes.
if aws_s3 s3api head-bucket --bucket "${S3_BUCKET}" >/dev/null 2>&1; then
  ok "bucket s3://${S3_BUCKET} exists"
else
  wait_until 60 "bucket s3://${S3_BUCKET} created" aws_s3 s3 mb "s3://${S3_BUCKET}"
fi

# Round-trip write test
echo "lab-probe $(date)" | docker run --rm -i --network kind \
  -e AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" -e AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
  -e AWS_DEFAULT_REGION="${S3_REGION}" "${AWSCLI_IMAGE}" \
  --endpoint-url "http://${S3_CONTAINER}:${S3_PORT}" s3 cp - "s3://${S3_BUCKET}/.probe" >/dev/null
aws_s3 s3 rm "s3://${S3_BUCKET}/.probe" >/dev/null
ok "S3 put/delete round-trip OK"

# Can pods inside each cluster reach it by container name?
s3url="http://${S3_CONTAINER}:${S3_PORT}"
for role in primary dr; do
  cluster_reachable "$role" || { warn "$(ctx_for "$role") not reachable - skipping pod probe"; continue; }
  code="$(k "$role" -n default run s3-probe --rm -i --quiet --restart=Never \
          --image="${CURL_IMAGE}" -- -s -o /dev/null -w '%{http_code}' "${s3url}/" 2>/dev/null || true)"
  if echo "${code}" | grep -Eq '^[1-5][0-9][0-9]'; then
    ok "$(ctx_for "$role"): pod -> ${s3url} (HTTP ${code})"
  else
    ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "${S3_CONTAINER}")"
    s3url="http://${ip}:${S3_PORT}"
    warn "$(ctx_for "$role"): DNS for '${S3_CONTAINER}' failed from pods; falling back to ${s3url} (changes if container is recreated)"
  fi
done
echo "${s3url}" > "${STATE_DIR}/s3url"
ok "in-cluster S3 URL: ${s3url}"
ok "SeaweedFS filer UI: http://127.0.0.1:8888/buckets/${S3_BUCKET}/"
