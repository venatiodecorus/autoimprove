#!/usr/bin/env bash
# scripts/spawn-worker.sh — launch one sandbox running Claude Code as a
# specific agent role, wait for it to finish, and route its exit marker
# into the correct state location.
#
# Usage: spawn-worker.sh <role> <context> <worker-id> <worktree>
#
# role:     builder | planner | playtester | auditor
# context:  issue number (builder) or mode string (planner) or empty
# worker-id: unique identifier for this run
# worktree: directory mounted into the sandbox as the workspace
#
# Sandbox model:
#   - Workspace is a positional arg to `sbx run claude <path>`.
#   - Secrets (ANTHROPIC_API_KEY, GH_TOKEN) live in `sbx secret` and are
#     injected by the sbx proxy; we never read them on the host.
#   - The agent prompt and flags are forwarded to claude after `--`.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

role=${1:?"usage: spawn-worker.sh <role> <context> <worker-id> <worktree>"}
context=${2:-}
worker_id=${3:?"missing worker-id"}
worktree=${4:?"missing worktree path"}

stdout_log="$(state_dir)/workers/$worker_id.stdout"
stderr_log="$(state_dir)/workers/$worker_id.stderr"

# Construct the prompt. Each agent reads its own .claude/agents/<role>.md
# definition; this prompt just hands it the orchestrator-provided context.
read -r -d '' prompt <<EOF || true
You are operating as the **$role** agent. Read .claude/agents/$role.md and follow it exactly.

Worker ID: $worker_id
Context: $context
Worktree: $worktree

You are in a Docker sandbox with the project folder mounted at $worktree.
The host orchestrator handles merge serialization — do NOT run git operations against main.

On completion, write a marker at $worktree/.marker.json with:
  {"worker":"$worker_id","role":"$role","status":"<status>","branch":"<branch or null>","issue":<n or null>,"details":"..."}

Status values:
  ready-to-merge — you pushed a branch ready for the merge gate (builder/planner)
  no-op          — you finished without pushing a branch (playtester/auditor)
  blocked        — you gave up after one fix attempt or the work was malformed
EOF

# Launch the sandbox.
#
# sbx contract (verified via `sbx run --help`):
#   sbx run [flags] AGENT [PATH...] [-- AGENT_ARGS...]
#   - PATH... are workspaces mounted into the sandbox (first becomes the cwd).
#   - Args after `--` are forwarded to the agent.
#   - There is no --workspace, no --env, and no --prompt flag. Secrets are
#     pulled from `sbx secret` (the sbx proxy injects them at runtime).
#
# We name the sandbox per-worker so concurrent runs don't collide, and we
# pass --dangerously-skip-permissions because there's no human to approve
# tool calls inside the sandbox.
sbx run \
  --name "$worker_id" \
  claude "$worktree" \
  -- \
  --print \
  --dangerously-skip-permissions \
  "$prompt" \
  >"$stdout_log" 2>"$stderr_log"
exit_code=$?

# Best-effort: remove the sandbox so we don't accumulate stopped containers.
# Failure here is non-fatal — the next run with the same --name would reuse
# it anyway, but cleanup keeps `sbx ls` legible.
sbx rm "$worker_id" >/dev/null 2>&1 || true

# Process the marker the agent left behind.
marker_path="$worktree/.marker.json"
if [ ! -f "$marker_path" ]; then
  report_error "$worker_id" "?" "no marker file (likely crash, exit=$exit_code)" "$stderr_log"
  rm -f "$(state_dir)/workers/$worker_id.json"
  exit 1
fi

status=$(jq -r .status "$marker_path" 2>/dev/null || echo "unknown")
case "$status" in
  ready-to-merge)
    mv "$marker_path" "$(state_dir)/ready-to-merge/$worker_id.json"
    ;;
  no-op)
    rm -f "$marker_path" "$(state_dir)/workers/$worker_id.json"
    ;;
  blocked)
    issue=$(jq -r .issue "$marker_path" 2>/dev/null || echo "?")
    details=$(jq -r .details "$marker_path" 2>/dev/null || echo "no details")
    report_error "$worker_id" "$issue" "agent marked blocked: $details" "$stderr_log"
    rm -f "$marker_path" "$(state_dir)/workers/$worker_id.json"
    ;;
  *)
    report_error "$worker_id" "?" "marker has unknown status: $status" "$stderr_log"
    rm -f "$marker_path" "$(state_dir)/workers/$worker_id.json"
    ;;
esac

exit 0
