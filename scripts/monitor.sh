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

# --- Window: dash --- (colored snapshot every 2s)
tmux new-window -t "$SESSION" -n dash -c "$REPO_ROOT"
tmux send-keys -t "$SESSION":dash \
  "while :; do clear; ./scripts/dashboard.sh; sleep 2; done" C-m

# --- Window: workers --- (live worker logs, dynamic tail)
# Inline tailer: keeps track of which files it already attached to, spawns a
# new tail -f per new file as it appears. Bash 3.2 compatible (no associative
# arrays). awk prefixes each line with the worker id so interleaved output is
# legible.
tmux new-window -t "$SESSION" -n workers -c "$REPO_ROOT"
tmux send-keys -t "$SESSION":workers "$(cat <<'TAILER'
echo "(waiting for workers to appear in state/workers/...)"
tailed=""
while :; do
  for f in state/workers/*.stdout state/workers/*.stderr; do
    [ -f "$f" ] || continue
    case " $tailed " in *" $f "*) continue ;; esac
    label=$(basename "$f")
    ( tail -n 100 -f "$f" 2>/dev/null \
        | awk -v p="$label" '{print "["p"] "$0; fflush()}' ) &
    tailed="$tailed $f"
  done
  sleep 2
done
TAILER
)" C-m

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
