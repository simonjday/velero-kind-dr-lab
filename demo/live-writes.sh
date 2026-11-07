#!/usr/bin/env bash
# Toggle simulated live traffic (1 INSERT/s) on the active site.
# Usage: live-writes.sh on|off [primary|dr]
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"

state="${1:?usage: $0 on|off [primary|dr]}"
role="${2:-$(active_role)}"
case "${state}" in
  on)  set_writer "$role" 1
       wait_until 60 "writer pod Ready" \
         k "$role" -n "${DEMO_NS}" wait --for=condition=Ready pod -l app=order-writer --timeout=5s
       sleep 3
       echo "   latest rows:"
       psql_q "$role" "${DEMO_NS}" "SELECT id, item, created_at FROM orders ORDER BY id DESC LIMIT 3;" | sed 's/^/   /' ;;
  off) set_writer "$role" 0 ;;
  *)   die "usage: $0 on|off [primary|dr]" ;;
esac
