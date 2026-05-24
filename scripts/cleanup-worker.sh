#!/usr/bin/env bash
# scripts/cleanup-worker.sh — tear down a worker's sandbox + worktree +
# branch and remove its state files after merge-gate has processed it.
#
# Usage: cleanup-worker.sh <worker-id> [<worktree>] [<branch>]
#
# The worktree and branch arguments are informational (used in logs);
# the actual teardown is done by `sbx rm --force <worker-id>`, which
# removes the sandbox container, the .sbx/<worker-id>-worktrees/<branch>
# directory, and the branch in one shot.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

worker=${1:?"usage: cleanup-worker.sh <worker-id> [<worktree>] [<branch>]"}
tree=${2:-}
branch=${3:-}

# Remove worker state files first so a re-entrant cleanup is a no-op.
rm -f "$(state_dir)/workers/$worker.json"
rm -f "$(state_dir)/workers/$worker.stdout"
rm -f "$(state_dir)/workers/$worker.stderr"
rm -f "$(state_dir)/ready-to-merge/$worker.json"

# sbx rm --force tears down the sandbox container, the per-worker
# worktree under .sbx/, and the associated branch. If the sandbox is
# already gone (e.g., it was rejected before merge), this is a no-op.
sbx rm --force "$worker" >/dev/null 2>&1 || true

# Safety net: if for some reason sbx didn't fully clean the worktree
# (older sbx versions, partial failure), make sure git's worktree
# registry doesn't accumulate stale entries.
if [ -n "$tree" ] && [ -d "$tree" ]; then
  git -C "$REPO_ROOT" worktree remove --force "$tree" 2>/dev/null || rm -rf "$tree"
fi
# And if a branch was left behind, drop it.
if [ -n "$branch" ]; then
  git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null || true
  git -C "$REPO_ROOT" push origin --delete "$branch" 2>/dev/null || true
fi
