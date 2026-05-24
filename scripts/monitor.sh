#!/usr/bin/env bash
# scripts/monitor.sh — launch a tmux session that runs the orchestrator and
# monitors all observable state in a dense split layout.
#
# Usage:
#   ./scripts/monitor.sh
#   AUTOIMPROVE_TMUX_SESSION=foo ./scripts/monitor.sh   # custom session name
#
# Window 1 — 'main' (everything you usually need on one screen):
#   ┌──────────────────┬─────────────────────┐
#   │ dashboard        │                     │
#   │                  │   workers           │
#   ├──────────────────┤   (live agent       │
#   │ orchestrator     │    activity)        │
#   │                  │                     │
#   └──────────────────┴─────────────────────┘
#
# Window 2 — 'extras' (deep debugging; cycle with C-b n):
#   ┌─────────────────────────────────────────┐
#   │ git log + status                        │
#   ├─────────────────────────────────────────┤
#   │ sbx ls                                  │
#   └─────────────────────────────────────────┘
#
# Tips:
#   C-b d              detach (orchestrator keeps running)
#   C-b ←/→/↑/↓        navigate between panes (or click with mouse)
#   C-b n  /  C-b p    cycle windows
#   C-b z              zoom current pane to fullscreen (toggle)
#   C-b [              enter scrollback (q to exit)
#
# The dashboard already covers sbx ls and the orchestrator log covers
# every merge / dispatch / audit decision — the 'extras' window is only
# needed for `git log` history or raw `sbx ls` output beyond what the
# dashboard's tail shows.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SESSION=${AUTOIMPROVE_TMUX_SESSION:-autoimprove}

if ! command -v tmux >/dev/null 2>&1; then
  echo "monitor: tmux not installed."
  echo "  macOS: brew install tmux"
  echo "  Linux: apt install tmux  /  dnf install tmux"
  exit 1
fi

# Already-running session → just attach.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "session '$SESSION' already exists; attaching."
  exec tmux attach -t "$SESSION"
fi

cd "$REPO_ROOT"
mkdir -p state

# ----- Window 1: main (3-pane split) ---------------------------------------
# After both splits, tmux re-indexes panes by SCREEN POSITION (top-to-bottom,
# left-to-right), not by creation order. The final indexing is:
#   pane 0 = top-left      (dashboard)
#   pane 1 = bottom-left   (orchestrator)
#   pane 2 = right         (workers)

tmux new-session -d -s "$SESSION" -n main -c "$REPO_ROOT"
tmux set-option -t "$SESSION" -g mouse on
tmux set-option -t "$SESSION" -g pane-border-status top
tmux set-option -t "$SESSION" -g pane-border-format ' #{pane_title} '

# Split current pane horizontally → new pane to the right (50% width).
tmux split-window -h -p 50 -t "$SESSION":main.0 -c "$REPO_ROOT"

# Split the LEFT pane vertically → new pane below the dashboard (40% height).
tmux split-window -v -p 40 -t "$SESSION":main.0 -c "$REPO_ROOT"

# Label panes (titles persist across the session).
tmux select-pane -t "$SESSION":main.0 -T 'dashboard'
tmux select-pane -t "$SESSION":main.1 -T 'orchestrator'
tmux select-pane -t "$SESSION":main.2 -T 'workers'

# Pane 0 (top-left): flicker-free dashboard refresh.
# Render to a variable first, then atomically: cursor-home + content +
# erase-to-end. No clear-between-renders → no blank flash while gh/sbx
# calls are in flight.
tmux send-keys -t "$SESSION":main.0 \
  "printf '\\033[2J'; while :; do out=\$(./scripts/dashboard.sh 2>/dev/null); printf '\\033[H%s\\033[J' \"\$out\"; sleep 2; done" C-m

# Pane 1 (bottom-left): the orchestrator itself.
tmux send-keys -t "$SESSION":main.1 \
  "./scripts/autoimprove.sh 2>&1 | tee state/orchestrator.log" C-m

# Pane 2 (right): live agent activity.
tmux send-keys -t "$SESSION":main.2 \
  "./scripts/_tail-workers.sh" C-m

# ----- Window 2: extras (git + sbx split) ----------------------------------

tmux new-window -t "$SESSION" -n extras -c "$REPO_ROOT"

# Top pane (existing pane 0 of this window): git log + status.
tmux split-window -v -p 50 -t "$SESSION":extras.0 -c "$REPO_ROOT"

tmux select-pane -t "$SESSION":extras.0 -T 'git'
tmux select-pane -t "$SESSION":extras.1 -T 'sbx ls'

tmux send-keys -t "$SESSION":extras.0 \
  "while :; do clear; printf '== git log --oneline -20 ==\\n'; git log --oneline -20; printf '\\n== git status --short ==\\n'; git status --short; sleep 5; done" C-m

tmux send-keys -t "$SESSION":extras.1 \
  "while :; do clear; printf 'sbx ls   (refresh 3s)\\n\\n'; sbx ls 2>&1; sleep 3; done" C-m

# Land on the main window's dashboard pane.
tmux select-window -t "$SESSION":main
tmux select-pane -t "$SESSION":main.0

exec tmux attach -t "$SESSION"
