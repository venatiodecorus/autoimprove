#!/usr/bin/env bash
# scripts/_tail-workers.sh — dynamic tail of every state/workers/<wid>.{stdout,stderr},
# picking up new worker files as they appear. Used by monitor.sh's 'workers' tmux
# window. Lives in its own bash script so it doesn't have to deal with zsh's
# strict-no-match globbing semantics when called via tmux send-keys.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# bash 3.2 compatible nullglob (no associative arrays needed).
shopt -s nullglob

echo "(waiting for workers to appear in $(state_dir)/...)"

# Track which files we've already attached a tail to.
tailed=""

cleanup() {
  # SIGTERM children when the user closes the tmux pane.
  pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT INT TERM

while :; do
  for f in "$(state_dir)/workers/"*.stdout "$(state_dir)/workers/"*.stderr; do
    [ -f "$f" ] || continue
    case " $tailed " in *" $f "*) continue ;; esac
    label=$(basename "$f")
    # tail -n 100 -f catches recent context for late attaches; awk prefixes
    # each line with the worker id so interleaved output stays legible;
    # fflush() forces a flush on every line so monitor sees them live.
    ( tail -n 100 -f "$f" 2>/dev/null \
        | awk -v p="$label" '{print "["p"] "$0; fflush()}' ) &
    tailed="$tailed $f"
  done
  sleep 2
done
