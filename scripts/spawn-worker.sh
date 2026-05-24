#!/usr/bin/env bash
# scripts/spawn-worker.sh — launch one sandbox running Claude Code as a
# specific agent role, wait for it to finish, and route its exit marker
# into the correct state location.
#
# Usage: spawn-worker.sh <role> <context> <worker-id> <branch>
#
# role:     builder | planner | playtester | auditor
# context:  issue number (builder) or mode string (planner) or empty
# worker-id: unique identifier for this run (also the sandbox name)
# branch:   branch name to create. sbx --branch creates a worktree at
#           $REPO_ROOT/.sbx/<worker-id>-worktrees/<branch>.
#
# Sandbox model:
#   - Workspace is the repo root; sbx --branch creates a per-worker git
#     worktree under .sbx/ that is accessible to both host and sandbox.
#   - Secrets (ANTHROPIC_API_KEY, GH_TOKEN) live in `sbx secret` and are
#     injected by the sbx proxy; we never read them on the host.
#   - The agent prompt and flags are forwarded to claude after `--`.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

role=${1:?"usage: spawn-worker.sh <role> <context> <worker-id> <branch>"}
context=${2:-}
worker_id=${3:?"missing worker-id"}
branch=${4:?"missing branch"}

# sbx --branch creates this path. The host reads .marker.json from here
# after the sandbox exits. The sandbox sees both the repo root and the
# worktree (with the branch already checked out in the worktree).
worktree="$REPO_ROOT/.sbx/${worker_id}-worktrees/${branch}"

stdout_log="$(state_dir)/workers/$worker_id.stdout"
stderr_log="$(state_dir)/workers/$worker_id.stderr"

# Per-role guidance about where the agent should work and what marker to
# write. The agent reads .claude/agents/<role>.md for full instructions.
read -r -d '' prompt <<EOF || true
You are operating as the **$role** agent. Read .claude/agents/$role.md and follow it exactly.

Worker ID:  $worker_id
Context:    $context
Branch:     $branch
Worktree:   $worktree

You are in a Docker sandbox. The repo root is mounted; your dedicated
git worktree is at $worktree on the branch '$branch'. cd into it before
making any changes. The host orchestrator owns merging — do NOT push to
main or merge anything yourself.

On completion, write a marker at $worktree/.marker.json with:
  {"worker":"$worker_id","role":"$role","status":"<status>","branch":"<branch or null>","issue":<n or null>,"details":"..."}

Auditors additionally include a "verdict" field with the full audit JSON.

Status values:
  ready-to-merge — you pushed a branch ready for the merge gate (builder/planner/playtester-with-evidence)
  no-op          — you finished without pushing a branch (auditor, playtester with no findings)
  blocked        — you gave up after one fix attempt or the work was malformed
EOF

# Launch the sandbox.
#
# sbx contract (`sbx run --help`):
#   sbx run [flags] AGENT [PATH...] [-- AGENT_ARGS...]
#   --branch <name>  Creates a git worktree on the given branch at
#                    $REPO_ROOT/.sbx/<sandbox-name>-worktrees/<branch>.
#   --name <name>    Names the sandbox (we use the worker_id so cleanup
#                    is straightforward).
#
# Secrets come from `sbx secret`, never the host environment. There is no
# --env, no --workspace, no --prompt flag.
#
# `set -e` is intentionally NOT in effect for this call: we want the exit
# code so we can include it in the error report if sbx itself crashed.
sbx run \
  --name "$worker_id" \
  --branch "$branch" \
  claude "$REPO_ROOT" \
  -- \
  --print \
  --dangerously-skip-permissions \
  --max-turns 100 \
  "$prompt" \
  >"$stdout_log" 2>"$stderr_log"
exit_code=$?

# Best-effort cleanup of the sandbox container. The worktree stays on
# disk so the host can read the marker; we tear that down separately
# in cleanup-worker.sh after merge-gate has processed (or rejected) it.
# For roles that don't go through merge-gate (no-op / blocked), we
# tear down the worktree here.

marker_path="$worktree/.marker.json"
if [ ! -f "$marker_path" ]; then
  report_error "$worker_id" "?" "no marker file (likely crash, exit=$exit_code)" "$stderr_log"
  # Tear down the sandbox + worktree + branch so we don't leak.
  sbx rm --force "$worker_id" >/dev/null 2>&1 || true
  rm -f "$(state_dir)/workers/$worker_id.json"
  exit 1
fi

status=$(jq -r .status "$marker_path" 2>/dev/null || echo "unknown")

# Enrich the marker with host-known fields the agent doesn't (and shouldn't)
# write itself: the worktree path the merge-gate needs to operate on. We
# add this before the marker leaves the worktree because merge-gate.sh
# reads .worktree from it.
enrich_marker() {
  local tmp
  tmp=$(mktemp)
  jq --arg wt "$worktree" '. + {worktree: $wt}' "$marker_path" > "$tmp" \
    && mv "$tmp" "$marker_path"
}

# For auditors, lift the verdict out and append it to the global audit
# history on the host. The auditor itself only writes to its marker —
# it has no access to state/audit-history.jsonl in its sandbox.
record_audit_verdict() {
  local verdict
  verdict=$(jq -c '.verdict // empty' "$marker_path" 2>/dev/null || true)
  if [ -z "$verdict" ] || [ "$verdict" = "null" ]; then
    log_warn "auditor $worker_id wrote no verdict; treating as gap-not-found"
    return
  fi
  printf '%s\n' "$verdict" >> "$(state_dir)/audit-history.jsonl"
}

# If the playtester finished with no findings (no-op + issues_filed == 0),
# record the current HEAD as the clean-playtest sha so the auditor can
# proceed. issues_filed is part of the playtester marker schema.
maybe_record_clean_playtest() {
  local filed
  filed=$(jq -r '.issues_filed // 0' "$marker_path" 2>/dev/null || echo 0)
  if [ "$filed" = "0" ]; then
    record_clean_playtest
    log_info "playtest clean at $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  else
    log_info "playtester filed $filed issue(s); main remains unplaytested"
  fi
}

case "$status" in
  ready-to-merge)
    enrich_marker
    mv "$marker_path" "$(state_dir)/ready-to-merge/$worker_id.json"
    # Sandbox container can go away; worktree stays for merge-gate.
    sbx stop "$worker_id" >/dev/null 2>&1 || true
    ;;
  no-op)
    case "$role" in
      auditor)    record_audit_verdict ;;
      playtester) maybe_record_clean_playtest ;;
    esac
    # Nothing to merge; full teardown.
    sbx rm --force "$worker_id" >/dev/null 2>&1 || true
    rm -f "$(state_dir)/workers/$worker_id.json"
    ;;
  blocked)
    issue=$(jq -r .issue "$marker_path" 2>/dev/null || echo "?")
    details=$(jq -r .details "$marker_path" 2>/dev/null || echo "no details")
    report_error "$worker_id" "$issue" "agent marked blocked: $details" "$stderr_log"
    sbx rm --force "$worker_id" >/dev/null 2>&1 || true
    rm -f "$(state_dir)/workers/$worker_id.json"
    ;;
  *)
    report_error "$worker_id" "?" "marker has unknown status: $status (sbx exit=$exit_code)" "$stderr_log"
    sbx rm --force "$worker_id" >/dev/null 2>&1 || true
    rm -f "$(state_dir)/workers/$worker_id.json"
    ;;
esac

exit 0
