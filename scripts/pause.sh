#!/usr/bin/env bash
# scripts/pause.sh — pause or resume the autoimprove loop.
#
# Usage:
#   pause.sh on    — loop drains current work and sleeps
#   pause.sh off   — loop resumes
#   pause.sh       — show status

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

case "${1:-status}" in
  on)
    touch "$(state_dir)/pause"
    echo "loop will pause after current drain finishes"
    ;;
  off)
    rm -f "$(state_dir)/pause"
    echo "loop will resume on next tick"
    ;;
  status|"")
    if is_paused; then
      echo "paused"
    else
      echo "running"
    fi
    ;;
  *)
    echo "usage: pause.sh [on|off|status]" >&2
    exit 1
    ;;
esac
