#!/usr/bin/env bash
# Deploys the demo workload to a cluster and seeds PostgreSQL.
# Usage: 04-deploy-demo-app.sh [primary|dr] [rows]
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

role="${1:-primary}"
rows="${2:-1000}"

banner "Demo app -> $(ctx_for "$role")/${DEMO_NS}"
k "$role" apply -f "${LAB_ROOT}/k8s/demo-app.yaml" >/dev/null
wait_until 180 "postgres-0 Ready" \
  k "$role" -n "${DEMO_NS}" wait --for=condition=Ready pod/postgres-0 --timeout=5s
wait_until 120 "web Available" \
  k "$role" -n "${DEMO_NS}" wait --for=condition=Available deploy/web --timeout=5s

psql_q "$role" "${DEMO_NS}" "CREATE TABLE IF NOT EXISTS orders (
  id serial PRIMARY KEY, item text NOT NULL, created_at timestamptz NOT NULL DEFAULT now());" >/dev/null
psql_q "$role" "${DEMO_NS}" \
  "INSERT INTO orders(item) SELECT 'seed-' || g FROM generate_series(1, ${rows}) g;" >/dev/null

ok "seeded ${rows} rows"
echo "  fingerprint (rows:md5): $(db_fingerprint "$role")"
