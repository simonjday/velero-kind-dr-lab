#!/usr/bin/env bash
# FLOW 3 - Scheduled protection, retention (TTL) and on-demand runs from a schedule.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"

role="$(active_role)"
sched="dr-demo-every-5m"

banner "FLOW 3: schedules & retention on $(ctx_for "$role")"

log "1. Create a schedule: every 5 min, keep each backup 1h"
v "$role" schedule create "${sched}" \
  --schedule "*/5 * * * *" \
  --include-namespaces "${DEMO_NS}" \
  --ttl 1h \
  --labels lab.velero/flow=3 2>/dev/null || ok "schedule ${sched} exists"
v "$role" schedule get
k "$role" -n velero get schedule "${sched}" -o yaml | sed -n '/^spec:/,/^status:/p'
pause

log "2. Don't wait for cron - trigger a run from the schedule template"
v "$role" backup create --from-schedule "${sched}" --wait
v "$role" backup get -l "velero.io/schedule-name=${sched}"
pause

log "3. Pause / resume (e.g. during a change window or a failover)"
v "$role" schedule pause "${sched}"
k "$role" -n velero get schedule "${sched}" -o jsonpath='{.spec.paused}{"\n"}' | sed 's/^/   paused=/'
v "$role" schedule unpause "${sched}"
pause

log "4. Retention: expiry is stamped on each backup; GC controller deletes it + its bucket data"
k "$role" -n velero get backups -o json | jq -r -f "${LAB_ROOT}/jq/backup-summary.jq" | column -t -s $'\t'

cat <<EOF

  Teaching points
  - Schedule frequency is your RPO. TTL x frequency is your retention depth.
  - --from-schedule reuses the schedule's spec - ideal for a pre-change 'last good' backup.
  - Kopia repos are maintained by Jobs in the velero ns (velero.io BackupRepository CRs);
    deleting backups does not instantly free bucket space until maintenance runs.
  - Clean up: velero --kubecontext $(ctx_for "$role") schedule delete ${sched} --confirm
EOF
