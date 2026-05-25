#!/usr/bin/env bash
# scripts/cleanup-worker.sh — tear down a worker's sandbox + worktree +
# branch and remove its state files after merge-gate has processed it.
#
# Usage: cleanup-worker.sh <worker-id> [<worktree>] [<branch>]
#
# Worker stdout/stderr logs are PRESERVED — they're moved into
# state/workers/done/ so:
#   (a) the monitor's workers pane keeps showing what the agent did,
#   (b) you can post-hoc inspect a finished run.
# Periodically purge state/workers/done/ manually when it grows too large.
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

# Active-worker JSON: remove (worker is no longer active).
rm -f "$(state_dir)/workers/$worker.json"
rm -f "$(state_dir)/ready-to-merge/$worker.json"

# Worker logs: archive into done/ instead of deleting so we can review them.
done_dir="$(state_dir)/workers/done"
mkdir -p "$done_dir"
for ext in stdout stderr fetch.log; do
  src="$(state_dir)/workers/$worker.$ext"
  if [ -f "$src" ]; then
    mv "$src" "$done_dir/$worker.$ext" 2>/dev/null || rm -f "$src"
  fi
done

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
