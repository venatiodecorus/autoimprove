#!/usr/bin/env bash
# scripts/monitor.sh — launch a tmux session that runs the orchestrator and
# monitors all observable state.
#
# Usage:
#   ./scripts/monitor.sh          # create-or-attach the session
#   AUTOIMPROVE_TMUX_SESSION=foo ./scripts/monitor.sh   # custom session name
#
# Layout (5 windows; cycle with C-b n / C-b p):
#   loop      — runs ./scripts/autoimprove.sh, tees stdout to state/orchestrator.log
#   dash      — colored snapshot from scripts/dashboard.sh (refreshes every 2s)
#   workers   — live tail of every state/workers/*.{stdout,stderr}, picks up new ones
#   sbx       — `sbx ls` refresh
#   git       — git log + git status refresh
#
# Detach: C-b d   (orchestrator keeps running; reattach with ./scripts/monitor.sh)
# Kill session: C-b : kill-session   (also stops the orchestrator)

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

# --- Window: loop --- (orchestrator)
# Use tee so state/orchestrator.log captures the same output for post-hoc replay.
tmux new-session -d -s "$SESSION" -n loop -c "$REPO_ROOT"
tmux send-keys -t "$SESSION":loop \
  "./scripts/autoimprove.sh 2>&1 | tee state/orchestrator.log" C-m

# --- Window: dash --- (colored snapshot every 2s, flicker-free)
# The dashboard makes a few gh + sbx calls per render which take ~1s total.
# Plain `clear; ./dashboard.sh` leaves the screen blank during those calls,
# causing a visible flash on every tick. Render to a variable first, then
# atomically: cursor-home (\033[H) + content + erase-to-end (\033[J). That
# overwrites old content top-down so there's no blank moment.
tmux new-window -t "$SESSION" -n dash -c "$REPO_ROOT"
tmux send-keys -t "$SESSION":dash \
  "printf '\\033[2J'; while :; do out=\$(./scripts/dashboard.sh 2>/dev/null); printf '\\033[H%s\\033[J' \"\$out\"; sleep 2; done" C-m

# --- Window: workers --- (live worker logs, dynamic tail)
# Dispatched as a standalone bash script so the dynamic glob loop works
# regardless of the user's interactive shell (zsh would otherwise error
# out on the unmatched glob).
tmux new-window -t "$SESSION" -n workers -c "$REPO_ROOT"
tmux send-keys -t "$SESSION":workers "./scripts/_tail-workers.sh" C-m

# --- Window: sbx --- (sandbox-level view)
tmux new-window -t "$SESSION" -n sbx -c "$REPO_ROOT"
tmux send-keys -t "$SESSION":sbx \
  "while :; do clear; printf 'sbx ls   (refresh 3s)\n\n'; sbx ls 2>&1; sleep 3; done" C-m

# --- Window: git --- (history + working tree)
tmux new-window -t "$SESSION" -n git -c "$REPO_ROOT"
tmux send-keys -t "$SESSION":git \
  "while :; do clear; printf '== git log --oneline -20 ==\n'; git log --oneline -20; printf '\n== git status --short ==\n'; git status --short; sleep 5; done" C-m

# Land on the dashboard window by default.
tmux select-window -t "$SESSION":dash

exec tmux attach -t "$SESSION"
