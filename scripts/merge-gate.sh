#!/usr/bin/env bash
# scripts/merge-gate.sh — process one worker's ready-to-merge marker.
# Serialized via flock; rebases the branch onto current main, re-runs gates
# against the rebased state, fast-forwards main if everything passes, or
# rejects (reopen issue + blocked label + comment) otherwise.
#
# Usage: merge-gate.sh <worker-id>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

worker=${1:?"usage: merge-gate.sh <worker-id>"}
marker="$(state_dir)/ready-to-merge/$worker.json"

if [ ! -f "$marker" ]; then
  log_warn "no marker for $worker; skipping"
  exit 0
fi

branch=$(jq -r .branch "$marker")
issue=$(jq -r .issue "$marker")
tree=$(jq -r .worktree "$marker")
role=$(jq -r .role "$marker")

# Acquire the merge lock — strictly one merge at a time across the whole
# orchestrator. Other workers' merge-gate calls block here.
exec 200>"$(state_dir)/merge.lock"
flock -x 200

log_info "merge-gate: worker=$worker role=$role branch=$branch issue=$issue"

# Fetch latest main and the worker's branch.
git -C "$REPO_ROOT" fetch origin main "$branch" 2>&1 | sed 's/^/  fetch: /'

# Make sure local main is current.
git -C "$REPO_ROOT" checkout main >/dev/null 2>&1
git -C "$REPO_ROOT" pull --ff-only origin main 2>&1 | sed 's/^/  pull: /' || true

# Rebase the worker's branch (in its worktree) onto current main.
if [ -d "$tree" ]; then
  rebase_dir="$tree"
else
  log_warn "worktree $tree missing; treating as a planner/auditor commit on main directly"
  rebase_dir="$REPO_ROOT"
fi

if [ -d "$tree" ]; then
  if ! git -C "$tree" rebase origin/main 2>"$tree/.rebase.log"; then
    git -C "$tree" rebase --abort 2>/dev/null || true
    if [ "$issue" != "null" ] && [ -n "$issue" ]; then
      gh issue reopen "$issue" 2>/dev/null || true
      gh issue edit "$issue" --add-label "blocked" 2>/dev/null || true
      gh issue comment "$issue" --body "Merge gate: rebase onto current main produced conflicts. Reopening for retry against current main." 2>/dev/null || true
      [ -f "$tree/.rebase.log" ] && gh issue comment "$issue" --body-file "$tree/.rebase.log" 2>/dev/null || true
    fi
    report_error "$worker" "${issue:-?}" "rebase conflict" "$tree/.rebase.log"
    "$SCRIPT_DIR/cleanup-worker.sh" "$worker" "$tree" "$branch"
    exit 1
  fi
fi

# Re-run gates against the rebased state.
gates_log="$rebase_dir/.gates.log"
: > "$gates_log"
if [ -d "$tree" ]; then
  if ! ( cd "$tree" && "$SCRIPT_DIR/gates.sh" ) >"$gates_log" 2>&1; then
    if [ "$issue" != "null" ] && [ -n "$issue" ]; then
      gh issue reopen "$issue" 2>/dev/null || true
      gh issue edit "$issue" --add-label "blocked" 2>/dev/null || true
      gh issue comment "$issue" --body "Merge gate: post-rebase gates failed. See log below." 2>/dev/null || true
      gh issue comment "$issue" --body-file "$gates_log" 2>/dev/null || true
    fi
    report_error "$worker" "${issue:-?}" "post-rebase gates failed" "$gates_log"
    "$SCRIPT_DIR/cleanup-worker.sh" "$worker" "$tree" "$branch"
    exit 1
  fi
fi

# Fast-forward merge to main from the repo root and push.
if [ -d "$tree" ]; then
  if ! git -C "$REPO_ROOT" merge --ff-only "$branch" 2>&1 | sed 's/^/  merge: /'; then
    if [ "$issue" != "null" ] && [ -n "$issue" ]; then
      gh issue reopen "$issue" 2>/dev/null || true
      gh issue edit "$issue" --add-label "blocked" 2>/dev/null || true
      gh issue comment "$issue" --body "Merge gate: ff-only merge failed unexpectedly after successful rebase. Likely concurrent main update — retrying on next iteration may succeed." 2>/dev/null || true
    fi
    report_error "$worker" "${issue:-?}" "ff-only merge failed" "$gates_log"
    "$SCRIPT_DIR/cleanup-worker.sh" "$worker" "$tree" "$branch"
    exit 1
  fi
fi

git -C "$REPO_ROOT" push origin main 2>&1 | sed 's/^/  push: /'

# A successful merge to main invalidates the last-clean-playtest sha because
# the playtest didn't exercise the new commits.
invalidate_playtest_sha

log_info "merge-gate: SUCCESS worker=$worker branch=$branch issue=$issue (HEAD=$(git -C "$REPO_ROOT" rev-parse --short HEAD))"

"$SCRIPT_DIR/cleanup-worker.sh" "$worker" "$tree" "$branch"
exit 0
