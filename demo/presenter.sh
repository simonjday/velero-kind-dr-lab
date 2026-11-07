#!/usr/bin/env bash
# Opens a tmux presenter layout (brew install tmux):
#  ┌──────────────────────┬──────────────────────┐
#  │ watch.sh primary     │ watch.sh dr          │
#  ├──────────────────────┴──────────────────────┤
#  │ driver shell: run the flow scripts here     │
#  └─────────────────────────────────────────────┘
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null || { echo "tmux not found: brew install tmux (or open 3 terminal panes manually)"; exit 1; }
session="velero-demo"
tmux has-session -t "${session}" 2>/dev/null && exec tmux attach -t "${session}"

tmux new-session -d -s "${session}" -x 240 -y 60 -c "${here}/.."
tmux send-keys -t "${session}:0.0" "source scripts/env.sh && clear" C-m
tmux split-window -v -p 65 -t "${session}:0.0" -c "${here}/.."      # top/bottom
tmux split-window -h -p 50 -t "${session}:0.0" -c "${here}/.."      # split top
tmux send-keys -t "${session}:0.0" "demo/watch.sh primary" C-m
tmux send-keys -t "${session}:0.1" "demo/watch.sh dr" C-m
tmux send-keys -t "${session}:0.2" "source scripts/env.sh && clear && echo 'Driver pane: run demo/flow-*.sh here'" C-m
tmux select-pane -t "${session}:0.2"
exec tmux attach -t "${session}"
