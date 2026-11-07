#!/usr/bin/env bash
# Non-interactive end-to-end: build lab, run every flow, print status. ~15-20 min on an M3.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export DEMO_AUTO=1
"${here}/../scripts/up.sh"
"${here}/flow-1-namespace-restore.sh"
"${here}/flow-3-schedules.sh"
"${here}/flow-4-clone-and-selective.sh"
DISASTER_MODE="${DISASTER_MODE:-stop}" "${here}/flow-2-cluster-dr.sh"
"${here}/flow-5-failback.sh"
"${here}/../scripts/status.sh"
