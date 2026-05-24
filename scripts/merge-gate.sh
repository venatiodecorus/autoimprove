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
# orchestrator. Other workers' merge-gate calls block here. Uses a mkdir
# directory lock so we work on macOS too (no flock).
acquire_merge_lock
trap 'release_merge_lock' EXIT

log_info "merge-gate: worker=$worker role=$role branch=$branch issue=$issue"

# A marker without a worktree path is malformed (host-side enrichment failed
# or the agent crashed before its marker was processed). Reject loudly rather
# than silently consuming it.
if [ -z "$tree" ] || [ "$tree" = "null" ] || [ ! -d "$tree" ]; then
  report_error "$worker" "${issue:-?}" "marker missing or invalid worktree path: '$tree'" \
    "$(state_dir)/workers/$worker.stderr"
  if [ "$issue" != "null" ] && [ -n "$issue" ]; then
    gh issue reopen "$issue" 2>/dev/null || true
    gh issue edit "$issue" --add-label "blocked" 2>/dev/null || true
    gh issue comment "$issue" --body "Merge gate: marker had no valid worktree path; rejecting." 2>/dev/null || true
  fi
  "$SCRIPT_DIR/cleanup-worker.sh" "$worker" "$tree" "$branch"
  exit 1
fi

# Fetch latest main and the worker's branch. If the branch doesn't exist
# on origin (e.g., worker crashed before push), don't let pipefail hang us
# in a forever-retry loop — reject the marker instead.
if ! git -C "$REPO_ROOT" fetch origin main "$branch" 2>"$(state_dir)/workers/$worker.fetch.log"; then
  cat "$(state_dir)/workers/$worker.fetch.log" >&2 || true
  report_error "$worker" "${issue:-?}" "fetch failed (branch '$branch' likely never pushed)" \
    "$(state_dir)/workers/$worker.fetch.log"
  if [ "$issue" != "null" ] && [ -n "$issue" ]; then
    gh issue reopen "$issue" 2>/dev/null || true
    gh issue edit "$issue" --add-label "blocked" 2>/dev/null || true
    gh issue comment "$issue" --body "Merge gate: could not fetch branch '$branch' from origin (worker likely failed to push). See orchestrator log." 2>/dev/null || true
  fi
  "$SCRIPT_DIR/cleanup-worker.sh" "$worker" "$tree" "$branch"
  exit 1
fi

# Make sure local main is current.
git -C "$REPO_ROOT" checkout main >/dev/null 2>&1
git -C "$REPO_ROOT" pull --ff-only origin main 2>&1 | sed 's/^/  pull: /' || true

# Rebase the worker's branch (in its worktree) onto current main.
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

# Re-run gates against the rebased state.
gates_log="$tree/.gates.log"
: > "$gates_log"
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

# Fast-forward merge to main from the repo root and push.
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

git -C "$REPO_ROOT" push origin main 2>&1 | sed 's/^/  push: /'

# Close the issue idempotently on the host side — the merge-gate owns this
# now, not the builder. (Previously the builder closed it before pushing,
# which could leave the issue open if the close call failed even though the
# merge succeeded, causing duplicate-dispatch on the next tick.)
if [ "$issue" != "null" ] && [ -n "$issue" ]; then
  gh issue close "$issue" --comment "Merged: branch \`$branch\` fast-forwarded to main ($(git -C "$REPO_ROOT" rev-parse --short HEAD))." 2>/dev/null || \
    log_warn "post-merge: gh issue close #$issue failed (issue may already be closed)"
fi

# A successful merge to main invalidates the last-clean-playtest sha because
# the playtest didn't exercise the new commits — UNLESS this merge IS the
# playtester's evidence push (no code change, only .llm/playtests/ files).
# Cheap heuristic: if the role is playtester, don't invalidate.
if [ "$role" != "playtester" ]; then
  invalidate_playtest_sha
fi

# If a playtester just merged with zero issues_filed in its marker, mark the
# playtest current. The marker isn't available anymore here (it was moved
# into ready-to-merge and we'll cleanup), but spawn-worker.sh already handles
# the no-op-clean case directly. So nothing to do here.

log_info "merge-gate: SUCCESS worker=$worker branch=$branch issue=$issue (HEAD=$(git -C "$REPO_ROOT" rev-parse --short HEAD))"

"$SCRIPT_DIR/cleanup-worker.sh" "$worker" "$tree" "$branch"
exit 0
