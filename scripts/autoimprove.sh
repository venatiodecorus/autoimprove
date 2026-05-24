#!/usr/bin/env bash
# scripts/autoimprove.sh — the orchestrator daemon.
#
# Runs the parallel build/test/audit loop until the auditor declares
# satisfied twice in a row (with no intervening spec change), or until
# MAX_ITERATIONS hits, or until you Ctrl+C. State is on-disk; safe to
# restart cold.
#
# Tuning knobs (env vars):
#   N_PARALLEL              builders to run concurrently (default 3)
#   MAX_ITERATIONS          hard stop after this many ticks (default 200)
#   LOOP_SLEEP_S            sleep between ticks (default 5)
#   WORKER_TIMEOUT_S        kill workers older than this (default 1800)
#   BLOCKED_RETRY_S         after this many seconds, blocked issues are
#                           re-tried (label stripped). Default 3600.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

N_PARALLEL="${N_PARALLEL:-3}"
MAX_ITERATIONS="${MAX_ITERATIONS:-200}"
LOOP_SLEEP_S="${LOOP_SLEEP_S:-5}"
WORKER_TIMEOUT_S="${WORKER_TIMEOUT_S:-1800}"
BLOCKED_RETRY_S="${BLOCKED_RETRY_S:-3600}"
export WORKER_TIMEOUT_S BLOCKED_RETRY_S

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

cd "$REPO_ROOT"

# Host needs gh CLI auth to read/write issues; sandboxes have their own
# github creds via `sbx secret`. No GH_TOKEN env var required on the host.
if ! gh auth status >/dev/null 2>&1; then
  log_warn "gh not authenticated on the host. Run 'gh auth login' first."
  exit 1
fi

if ! command -v sbx >/dev/null 2>&1; then
  log_warn "sbx (Docker AI Sandboxes) not found in PATH."
  log_warn "Install Docker Desktop with AI Sandboxes enabled."
  exit 1
fi

# Sandboxes get their Anthropic and GitHub credentials from `sbx secret`, not
# from host env vars. Verify both are configured globally before we dispatch
# any workers.
sbx_secrets=$(sbx secret ls 2>/dev/null || true)
if ! printf '%s\n' "$sbx_secrets" | awk '$1 == "(global)" { print $2 }' | grep -qx anthropic; then
  log_warn "sbx secret 'anthropic' not configured globally."
  log_warn "Run: sbx secret set -g anthropic    (or 'sbx secret set -g anthropic --oauth')"
  exit 1
fi
if ! printf '%s\n' "$sbx_secrets" | awk '$1 == "(global)" { print $2 }' | grep -qx github; then
  log_warn "sbx secret 'github' not configured globally."
  log_warn "Run: gh auth token | sbx secret set -g github"
  exit 1
fi

if [ ! -f "$REPO_ROOT/BRIEF.md" ]; then
  log_warn "BRIEF.md missing. Write your project pitch there first."
  exit 1
fi

mkdir -p "$(state_dir)/workers" "$(state_dir)/ready-to-merge" \
         "$REPO_ROOT/milestones" "$REPO_ROOT/.sbx"
touch "$(state_dir)/audit-history.jsonl"

# Track backgrounded child PIDs so Ctrl+C can drain them.
child_pids=()
on_signal() {
  log_info "received SIGINT/SIGTERM; sending SIGTERM to ${#child_pids[@]} child(ren)"
  for pid in "${child_pids[@]:-}"; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  done
  exit 0
}
trap on_signal INT TERM

log_info "starting orchestrator: N_PARALLEL=$N_PARALLEL MAX_ITERATIONS=$MAX_ITERATIONS"

# ---------------------------------------------------------------------------
# Dispatch helpers
# ---------------------------------------------------------------------------

# Spawn a worker in the background, record its PID. Caller supplies role,
# context, worker_id, branch.
spawn_bg() {
  local role=$1 ctx=$2 wid=$3 br=$4
  "$SCRIPT_DIR/spawn-worker.sh" "$role" "$ctx" "$wid" "$br" &
  child_pids+=("$!")
}

# Spawn a serial-stage worker (planner/playtester/auditor) backgrounded
# under its role lock. The lock is released by the subshell when the
# worker exits, so the main loop stays responsive.
spawn_serial_stage() {
  local role=$1 ctx=$2 wid=$3 br=$4
  if ! acquire_role_lock "$role"; then
    return 1
  fi
  (
    "$SCRIPT_DIR/spawn-worker.sh" "$role" "$ctx" "$wid" "$br" || \
      report_error "$wid" "?" "$role $ctx exited non-zero" \
        "$(state_dir)/workers/$wid.stderr"
    release_role_lock "$role"
  ) &
  child_pids+=("$!")
  return 0
}

# Compute a fresh worker_id with a role-specific prefix.
new_worker_id() {
  local prefix=$1
  echo "${prefix}-$(uuidgen 2>/dev/null | cut -c1-8 || date +%s%N)"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

iter=0
while [ "$iter" -lt "$MAX_ITERATIONS" ]; do
  iter=$((iter + 1))

  # --- pause check ----------------------------------------------------------
  while is_paused; do
    # Still drain anything ready to merge, but don't dispatch new work.
    for marker in "$(state_dir)/ready-to-merge/"*.json; do
      [ -e "$marker" ] || continue
      worker_id=$(basename "$marker" .json)
      "$SCRIPT_DIR/merge-gate.sh" "$worker_id" || true
    done
    log_info "paused (state/pause exists); sleeping"
    sleep "$LOOP_SLEEP_S"
  done

  # --- spec hash check ------------------------------------------------------
  maybe_invalidate_audit_history

  # --- keep local main current ----------------------------------------------
  # sbx --branch creates worktrees from local HEAD, so local main must be
  # up to date with origin/main before we dispatch. Cheap when nothing
  # has changed.
  git -C "$REPO_ROOT" checkout main >/dev/null 2>&1 || true
  git -C "$REPO_ROOT" pull --ff-only origin main >/dev/null 2>&1 || true

  # --- drain any ready-to-merge ---------------------------------------------
  for marker in "$(state_dir)/ready-to-merge/"*.json; do
    [ -e "$marker" ] || continue
    worker_id=$(basename "$marker" .json)
    "$SCRIPT_DIR/merge-gate.sh" "$worker_id" || true
  done

  # --- termination check ----------------------------------------------------
  if terminated; then
    log_info "=========================================================="
    log_info "MILESTONE COMPLETE — 2 consecutive 'satisfied' audits."
    log_info "Next steps:"
    log_info "  - Edit SPEC.md to extend scope (audit history invalidates), or"
    log_info "  - Run ./scripts/close-milestone.sh <name> to archive,"
    log_info "    then /plan to write the next milestone's spec."
    log_info "=========================================================="
    exit 0
  fi

  # --- bootstrap: planner with no SPEC.md ----------------------------------
  if [ ! -f "$REPO_ROOT/SPEC.md" ]; then
    log_info "no SPEC.md → planner bootstrap"
    worker_id=$(new_worker_id p)
    branch="iter/planner-bootstrap-${worker_id}"
    spawn_serial_stage planner "bootstrap" "$worker_id" "$branch" || true
    sleep "$LOOP_SLEEP_S"
    continue
  fi

  # --- stale worker sweep + blocked-issue retry ----------------------------
  sweep_stale_workers
  retry_blocked_issues

  # --- dispatch builders ----------------------------------------------------
  live=$(count_live_workers)
  slots=$((N_PARALLEL - live))
  if [ "$slots" -gt 0 ]; then
    issues=$(pick_top_issues "$slots")
    for issue in $issues; do
      worker_id=$(new_worker_id b)
      slug=$(slug_for_issue "$issue")
      # Include worker_id in branch name so retries against the same
      # issue never collide on the branch already-exists check.
      branch="iter/${issue}-${slug}-${worker_id}"
      worktree="$REPO_ROOT/.sbx/${worker_id}-worktrees/${branch}"

      cat > "$(state_dir)/workers/$worker_id.json" <<EOF
{"worker":"$worker_id","role":"builder","issue":$issue,"branch":"$branch","worktree":"$worktree","started_at":"$(date -u +%FT%TZ)"}
EOF
      log_info "dispatch builder: worker=$worker_id issue=#$issue branch=$branch"
      spawn_bg builder "$issue" "$worker_id" "$branch"
    done
  fi

  # --- phase advance --------------------------------------------------------
  if phase_complete; then
    worker_id=$(new_worker_id p)
    branch="iter/planner-phase-advance-${worker_id}"
    if spawn_serial_stage planner "phase-advance" "$worker_id" "$branch"; then
      log_info "phase complete → planner phase-advance (worker=$worker_id)"
    fi
  fi

  # --- playtest + audit barrier ---------------------------------------------
  if ready_for_serial_stage; then
    if ! last_playtest_is_current; then
      worker_id=$(new_worker_id t)
      branch="iter/playtest-${worker_id}"
      if spawn_serial_stage playtester "" "$worker_id" "$branch"; then
        log_info "main is unplaytested → playtester (worker=$worker_id)"
        # We can't synchronously check open-issues count here anymore
        # because the playtester runs in the background. The next tick
        # will see whether new issues were filed and act accordingly;
        # `record_clean_playtest` is now called after a successful
        # merge of the playtester's evidence (or, if no evidence, after
        # the no-op marker is processed — see lib.sh `try_record_clean_playtest`).
      fi
    elif plan_exhausted; then
      worker_id=$(new_worker_id a)
      branch="audit-${worker_id}"
      if spawn_serial_stage auditor "" "$worker_id" "$branch"; then
        log_info "plan exhausted & playtest current → auditor (worker=$worker_id)"
      fi
      # gap-convert is triggered on a subsequent tick once the audit
      # verdict has been appended to history. See last_audit_found_gaps.
    fi
  fi

  # --- gap convert (separate tick from audit so the verdict has landed) ----
  if last_audit_found_gaps && [ ! -f "$(state_dir)/gap-convert.processed" ]; then
    worker_id=$(new_worker_id p)
    branch="iter/planner-gap-convert-${worker_id}"
    if spawn_serial_stage planner "gap-convert" "$worker_id" "$branch"; then
      log_info "audit found gaps → planner gap-convert (worker=$worker_id)"
      touch "$(state_dir)/gap-convert.processed"
    fi
  fi
  # Clear the processed flag once the verdict cycle moves forward (new audit lands).
  maybe_clear_gap_convert_flag

  sleep "$LOOP_SLEEP_S"
done

log_info "hit MAX_ITERATIONS=$MAX_ITERATIONS without termination; exiting"
exit 2
