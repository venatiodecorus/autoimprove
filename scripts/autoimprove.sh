#!/usr/bin/env bash
# scripts/autoimprove.sh — the orchestrator daemon.
#
# Runs the parallel build/test/audit loop until the auditor declares
# satisfied twice in a row (with no intervening spec change), or until
# MAX_ITERATIONS hits, or until you Ctrl+C. State is on-disk; safe to
# restart cold.
#
# Tuning knobs (env vars):
#   N_PARALLEL              builders to run concurrently (default 2)
#   MAX_ITERATIONS          hard stop after this many ticks (default 200)
#   LOOP_SLEEP_S            sleep between ticks (default 5)
#   WORKER_TIMEOUT_S        kill workers older than this (default 1800)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

N_PARALLEL="${N_PARALLEL:-3}"
MAX_ITERATIONS="${MAX_ITERATIONS:-200}"
LOOP_SLEEP_S="${LOOP_SLEEP_S:-5}"
WORKER_TIMEOUT_S="${WORKER_TIMEOUT_S:-1800}"
export WORKER_TIMEOUT_S

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
         "$(worktrees_dir)" "$REPO_ROOT/milestones"
touch "$(state_dir)/audit-history.jsonl"

trap 'log_info "received SIGINT/SIGTERM, exiting after current drain"; exit 0' INT TERM

log_info "starting orchestrator: N_PARALLEL=$N_PARALLEL MAX_ITERATIONS=$MAX_ITERATIONS"

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
    worker_id="p-$(uuidgen 2>/dev/null | cut -c1-8 || date +%s)"
    if acquire_role_lock planner; then
      "$SCRIPT_DIR/spawn-worker.sh" planner "bootstrap" "$worker_id" "$REPO_ROOT" || \
        report_error "$worker_id" "?" "planner bootstrap exited non-zero" \
          "$(state_dir)/workers/$worker_id.stderr"
      release_role_lock planner
    fi
    sleep "$LOOP_SLEEP_S"
    continue
  fi

  # --- stale worker sweep ---------------------------------------------------
  sweep_stale_workers

  # --- dispatch builders ----------------------------------------------------
  live=$(count_live_workers)
  slots=$((N_PARALLEL - live))
  if [ "$slots" -gt 0 ]; then
    issues=$(pick_top_issues "$slots")
    for issue in $issues; do
      worker_id="b-$(uuidgen 2>/dev/null | cut -c1-8 || date +%s%N)"
      slug=$(slug_for_issue "$issue")
      branch="iter/${issue}-${slug}"
      worktree="$(worktrees_dir)/${issue}-${slug}"

      # Create the worktree from current main on a fresh branch
      if ! git -C "$REPO_ROOT" worktree add -b "$branch" "$worktree" origin/main 2>/dev/null; then
        log_warn "failed to create worktree for issue #$issue; skipping"
        continue
      fi

      cat > "$(state_dir)/workers/$worker_id.json" <<EOF
{"worker":"$worker_id","role":"builder","issue":$issue,"branch":"$branch","worktree":"$worktree","started_at":"$(date -u +%FT%TZ)"}
EOF
      log_info "dispatch builder: worker=$worker_id issue=#$issue branch=$branch"
      "$SCRIPT_DIR/spawn-worker.sh" builder "$issue" "$worker_id" "$worktree" &
    done
  fi

  # --- phase advance --------------------------------------------------------
  if phase_complete; then
    if acquire_role_lock planner; then
      worker_id="p-$(uuidgen 2>/dev/null | cut -c1-8 || date +%s)"
      log_info "phase complete → planner phase-advance"
      "$SCRIPT_DIR/spawn-worker.sh" planner "phase-advance" "$worker_id" "$REPO_ROOT" || \
        report_error "$worker_id" "?" "planner phase-advance failed" \
          "$(state_dir)/workers/$worker_id.stderr"
      release_role_lock planner
    fi
  fi

  # --- playtest + audit barrier ---------------------------------------------
  if ready_for_serial_stage; then
    if ! last_playtest_is_current; then
      if acquire_role_lock playtester; then
        worker_id="t-$(uuidgen 2>/dev/null | cut -c1-8 || date +%s)"
        log_info "main is unplaytested → playtester"
        if "$SCRIPT_DIR/spawn-worker.sh" playtester "" "$worker_id" "$REPO_ROOT"; then
          # If playtester filed no new issues, record HEAD as the clean-playtest sha
          if [ "$(count_open_issues)" -eq 0 ]; then
            record_clean_playtest
            log_info "playtest clean at $(git rev-parse --short HEAD)"
          else
            log_info "playtester filed $(count_open_issues) new issue(s)"
          fi
        else
          report_error "$worker_id" "?" "playtester exited non-zero" \
            "$(state_dir)/workers/$worker_id.stderr"
        fi
        release_role_lock playtester
      fi
    elif plan_exhausted; then
      if acquire_role_lock auditor; then
        worker_id="a-$(uuidgen 2>/dev/null | cut -c1-8 || date +%s)"
        log_info "plan exhausted & playtest current → auditor"
        "$SCRIPT_DIR/spawn-worker.sh" auditor "" "$worker_id" "$REPO_ROOT" || \
          report_error "$worker_id" "?" "auditor exited non-zero" \
            "$(state_dir)/workers/$worker_id.stderr"
        release_role_lock auditor
        # If gaps found, run planner in gap-convert mode next
        if last_audit_found_gaps; then
          if acquire_role_lock planner; then
            worker_id="p-$(uuidgen 2>/dev/null | cut -c1-8 || date +%s)"
            log_info "audit found gaps → planner gap-convert"
            "$SCRIPT_DIR/spawn-worker.sh" planner "gap-convert" "$worker_id" "$REPO_ROOT" || \
              report_error "$worker_id" "?" "planner gap-convert failed" \
                "$(state_dir)/workers/$worker_id.stderr"
            release_role_lock planner
          fi
        fi
      fi
    fi
  fi

  sleep "$LOOP_SLEEP_S"
done

log_info "hit MAX_ITERATIONS=$MAX_ITERATIONS without termination; exiting"
exit 2
