#!/usr/bin/env bash
# scripts/cleanup-worker.sh — tear down a worker's worktree and state files
# after merge gate completes (success or rejection).
#
# Usage: cleanup-worker.sh <worker-id> [<worktree>] [<branch>]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

worker=${1:?"usage: cleanup-worker.sh <worker-id> [<worktree>] [<branch>]"}
tree=${2:-}
branch=${3:-}

# Remove worker state files
rm -f "$(state_dir)/workers/$worker.json"
rm -f "$(state_dir)/workers/$worker.stdout"
rm -f "$(state_dir)/workers/$worker.stderr"
rm -f "$(state_dir)/ready-to-merge/$worker.json"

# Remove worktree
if [ -n "$tree" ] && [ -d "$tree" ]; then
  git -C "$REPO_ROOT" worktree remove --force "$tree" 2>/dev/null || rm -rf "$tree"
fi

# Delete the branch (locally and on origin). Safe because either it merged
# (FFed into main, so its commits live there now) or it was rejected (no
# value in keeping it). If it was rejected and the issue reopened, the next
# builder iteration gets a fresh branch anyway.
if [ -n "$branch" ]; then
  git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null || true
  git -C "$REPO_ROOT" push origin --delete "$branch" 2>/dev/null || true
fi
