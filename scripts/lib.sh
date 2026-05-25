#!/usr/bin/env bash
# scripts/lib.sh — shared functions for the autoimprove framework.
# Sourced by other scripts. Do not execute directly.

# Resolve repo root regardless of where caller cd'd to.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# ----------------------------------------------------------------------------
# Logging / error reporting
# ----------------------------------------------------------------------------

# Colored error line to stderr. Same primitive a future TUI can consume.
report_error() {
  local worker=$1 issue=$2 reason=$3 logfile=$4
  printf '\033[31m[ERROR]\033[0m worker %s (issue #%s) failed: %s. Log: %s\n' \
    "$worker" "$issue" "$reason" "$logfile" >&2
}

log() {
  printf '[autoimprove] %s\n' "$*"
}

log_info() {
  printf '\033[36m[autoimprove]\033[0m %s\n' "$*"
}

log_warn() {
  printf '\033[33m[autoimprove]\033[0m %s\n' "$*" >&2
}

# ----------------------------------------------------------------------------
# Portability shims
# ----------------------------------------------------------------------------

# sha256 of a file. macOS has shasum; Linux has sha256sum. Either works.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Lines of a file in reverse order. macOS has `tail -r`; GNU has `tac`.
# Both fall back to an awk reversal.
reverse_lines() {
  if command -v tac >/dev/null 2>&1; then
    tac "$1"
  elif tail -r </dev/null >/dev/null 2>&1; then
    tail -r "$1"
  else
    awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$1"
  fi
}

# Date parsing: ISO-8601 UTC string → epoch seconds. macOS uses
# `date -j -f`; GNU uses `date -d`. Returns 0 on failure.
iso8601_to_epoch() {
  local s=$1
  date -d "$s" +%s 2>/dev/null \
    || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$s" +%s 2>/dev/null \
    || echo 0
}

# ----------------------------------------------------------------------------
# State helpers
# ----------------------------------------------------------------------------

state_dir() { echo "$REPO_ROOT/state"; }

# Compute the on-disk worktree path that `sbx run --branch <branch>` creates
# for a given (worker_id, branch). sbx normalizes '/' → '-' in branch names
# when building the worktree directory, so a branch like
#   iter/planner-bootstrap-p-XXX
# lands at
#   $REPO_ROOT/.sbx/<worker_id>-worktrees/iter-planner-bootstrap-p-XXX
# Every script that needs the host-visible worktree path must go through
# this helper. (Verified via sbx create test on 2026-05-24.)
worktree_path_for() {
  local wid=$1 branch=$2
  local dir
  dir=$(printf '%s' "$branch" | tr '/' '-')
  echo "$REPO_ROOT/.sbx/${wid}-worktrees/${dir}"
}

# Write a worker state file. Called by spawn helpers; one schema for every
# role so sweep_stale_workers + count_live_workers see them uniformly.
write_worker_state() {
  local wid=$1 role=$2 issue=$3 branch=$4 worktree=$5 context=${6:-}
  # null-coerce issue if empty
  local issue_json="null"
  case "$issue" in
    ''|null) issue_json="null" ;;
    *) issue_json="$issue" ;;
  esac
  cat > "$(state_dir)/workers/$wid.json" <<EOF
{"worker":"$wid","role":"$role","context":"$context","issue":$issue_json,"branch":"$branch","worktree":"$worktree","started_at":"$(date -u +%FT%TZ)"}
EOF
}

# ----------------------------------------------------------------------------
# Spec hash and audit history
# ----------------------------------------------------------------------------

spec_hash() {
  if [ -f "$REPO_ROOT/SPEC.md" ]; then
    sha256_file "$REPO_ROOT/SPEC.md"
  else
    echo ""
  fi
}

# If the SPEC.md hash differs from state/spec.hash, append an invalidation
# marker to audit history so previous "satisfied" verdicts no longer count
# toward termination, and update the stored hash.
maybe_invalidate_audit_history() {
  local current stored
  current=$(spec_hash)
  stored=$(cat "$(state_dir)/spec.hash" 2>/dev/null || echo "")
  if [ "$current" != "$stored" ]; then
    if [ -n "$stored" ] && [ -n "$current" ]; then
      printf '{"timestamp":"%s","type":"invalidation","reason":"spec_hash_changed","old_hash":"%s","new_hash":"%s"}\n' \
        "$(date -u +%FT%TZ)" "$stored" "$current" \
        >> "$(state_dir)/audit-history.jsonl"
      log_info "SPEC.md changed — invalidated previous audit verdicts"
    fi
    echo "$current" > "$(state_dir)/spec.hash"
  fi
}

# Return the most recent non-invalidation audit line (verdict JSON), or empty.
# Implemented via single-pass awk so it works without `tac`: we reset the
# buffer on every invalidation marker, so end-of-file leaves only entries
# after the last invalidation.
recent_audit_lines() {
  local hist="$(state_dir)/audit-history.jsonl"
  [ -f "$hist" ] || return 0
  awk '
    /"type":"invalidation"/ { buf=""; next }
    { buf = buf $0 "\n" }
    END { printf "%s", buf }
  ' "$hist"
}

# Terminated when the last two non-invalidation entries are both satisfied=true
# at confidence=high, AND there is no intervening invalidation between them.
terminated() {
  local recent count
  recent=$(recent_audit_lines)
  [ -z "$recent" ] && return 1
  count=$(printf '%s' "$recent" | tail -2 | jq -s '
    if length < 2 then 0
    elif all(.[]; .satisfied == true and .confidence == "high") then 2
    else 0 end
  ' 2>/dev/null || echo 0)
  [ "$count" = "2" ]
}

# Hash of the most recent non-invalidation audit line. Used to fingerprint
# which audit triggered gap-convert.
last_audit_line_hash() {
  local recent last
  recent=$(recent_audit_lines)
  [ -z "$recent" ] && { echo ""; return; }
  last=$(printf '%s' "$recent" | tail -1)
  [ -z "$last" ] && { echo ""; return; }
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$last" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$last" | shasum -a 256 | awk '{print $1}'
  fi
}

last_audit_found_gaps() {
  local recent last
  recent=$(recent_audit_lines)
  [ -z "$recent" ] && return 1
  last=$(printf '%s' "$recent" | tail -1)
  [ -z "$last" ] && return 1
  [ "$(echo "$last" | jq -r '.satisfied' 2>/dev/null)" = "false" ] && \
    [ "$(echo "$last" | jq '.gaps | length' 2>/dev/null)" -gt 0 ]
}

# gap-convert sentinel: hash of the audit line that triggered the most
# recent gap-convert attempt. Set when the orchestrator spawns gap-convert;
# cleared when the spawn fails or is swept. A successful gap-convert
# eventually triggers a new audit with a different hash, so the next
# check naturally moves on.
gap_convert_needed() {
  last_audit_found_gaps || return 1
  local current stored
  current=$(last_audit_line_hash)
  [ -z "$current" ] && return 1
  stored=$(cat "$(state_dir)/gap-convert.last-source-hash" 2>/dev/null || echo "")
  [ "$current" != "$stored" ]
}

record_gap_convert_attempt() {
  last_audit_line_hash > "$(state_dir)/gap-convert.last-source-hash"
}

clear_gap_convert_attempt() {
  rm -f "$(state_dir)/gap-convert.last-source-hash"
}

# ----------------------------------------------------------------------------
# Playtest staleness
# ----------------------------------------------------------------------------

# A playtest is "current" iff it ran with zero bugs AND HEAD on main matches
# the SHA stored when that playtest completed cleanly.
last_playtest_is_current() {
  local sha_file="$(state_dir)/last-playtest.sha"
  [ -f "$sha_file" ] || return 1
  local stored head
  stored=$(cat "$sha_file")
  head=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
  [ "$stored" = "$head" ] && [ -n "$head" ]
}

record_clean_playtest() {
  git -C "$REPO_ROOT" rev-parse HEAD > "$(state_dir)/last-playtest.sha"
}

invalidate_playtest_sha() {
  rm -f "$(state_dir)/last-playtest.sha"
}

# ----------------------------------------------------------------------------
# Worker accounting
# ----------------------------------------------------------------------------

# NOTE: do NOT use `ls *.json | wc -l` here — under bash 5 + set -euo
# pipefail, an empty glob makes ls exit non-zero, pipefail propagates,
# and the entire orchestrator dies silently from the calling
# `live=$(count_live_workers)` substitution. The glob-iteration pattern
# below is safe regardless of how many files match (zero or more).
count_live_workers() {
  local count=0 f
  for f in "$(state_dir)/workers/"*.json; do
    [ -f "$f" ] && count=$((count + 1))
  done
  echo "$count"
}

count_pending_merges() {
  local count=0 f
  for f in "$(state_dir)/ready-to-merge/"*.json; do
    [ -f "$f" ] && count=$((count + 1))
  done
  echo "$count"
}

# Returns the count of open GitHub issues, or "-1" if gh is unreachable.
# Callers MUST treat -1 as "unknown; don't make a decision this tick."
count_open_issues() {
  local out
  out=$(gh issue list --state open --json number --jq 'length' 2>/dev/null)
  if [ -z "$out" ]; then
    log_warn "count_open_issues: gh issue list failed (network/auth/rate limit); treating as unknown"
    echo "-1"
    return
  fi
  echo "$out"
}

# All three drained → safe to run a serial stage (playtest or audit).
# Returns false (1) on gh failure too — we'd rather skip a tick than
# spuriously fire serial stages against unknown state.
ready_for_serial_stage() {
  local open
  open=$(count_open_issues)
  [ "$open" = "0" ] || return 1
  [ "$(count_pending_merges)" -eq 0 ] || return 1
  [ "$(count_live_workers)" -eq 0 ] || return 1
}

# Workers older than WORKER_TIMEOUT_S are presumed dead; clean them up.
# For serial-stage workers (planner/playtester/auditor), also release the
# role lock so future iterations of that role can dispatch.
sweep_stale_workers() {
  local timeout="${WORKER_TIMEOUT_S:-1800}"
  local now=$(date +%s)
  for f in "$(state_dir)/workers/"*.json; do
    [ -e "$f" ] || continue
    local started worker role issue tree branch age started_epoch
    started=$(jq -r .started_at "$f" 2>/dev/null || echo "")
    [ -z "$started" ] && continue
    started_epoch=$(iso8601_to_epoch "$started")
    age=$((now - started_epoch))
    if [ "$age" -gt "$timeout" ]; then
      worker=$(jq -r .worker "$f")
      role=$(jq -r .role "$f")
      issue=$(jq -r .issue "$f")
      tree=$(jq -r .worktree "$f")
      branch=$(jq -r .branch "$f" 2>/dev/null || echo "")
      report_error "$worker" "$issue" "timeout after ${age}s (role=$role)" \
        "$(state_dir)/workers/$worker.stderr"

      # Builder-specific: reopen the issue with a blocked label so it cycles.
      if [ "$role" = "builder" ] && [ "$issue" != "null" ]; then
        gh issue reopen "$issue" 2>/dev/null || true
        gh issue edit "$issue" --add-label "blocked" 2>/dev/null || true
      fi

      # If this was a gap-convert planner, clear the sentinel so the next
      # tick can re-trigger gap-convert against the same audit.
      local ctx
      ctx=$(jq -r '.context // ""' "$f" 2>/dev/null || echo "")
      if [ "$role" = "planner" ] && [ "$ctx" = "gap-convert" ]; then
        clear_gap_convert_attempt
      fi

      # Release role lock for serial workers so the role can run again.
      case "$role" in
        planner|playtester|auditor) release_role_lock "$role" ;;
      esac

      "$REPO_ROOT/scripts/cleanup-worker.sh" "$worker" "$tree" "$branch" 2>/dev/null || true
    fi
  done
}

# Strip the 'blocked' label from issues whose last activity is older than
# BLOCKED_RETRY_S, so the next dispatch re-picks them.
retry_blocked_issues() {
  local cooldown="${BLOCKED_RETRY_S:-3600}"
  local now_epoch
  now_epoch=$(date +%s)
  local rows
  rows=$(gh issue list --state open --label blocked --limit 50 \
    --json number,updatedAt --jq '.[] | "\(.number) \(.updatedAt)"' 2>/dev/null || true)
  [ -z "$rows" ] && return 0
  while IFS=' ' read -r n updated; do
    [ -z "$n" ] && continue
    local updated_epoch age
    updated_epoch=$(iso8601_to_epoch "$updated")
    age=$((now_epoch - updated_epoch))
    if [ "$age" -ge "$cooldown" ]; then
      if gh issue edit "$n" --remove-label blocked >/dev/null 2>&1; then
        gh issue comment "$n" --body "Cooldown elapsed (${age}s ≥ ${cooldown}s); re-entering build queue." >/dev/null 2>&1 || true
        log_info "retry: stripped 'blocked' from issue #$n (last update ${age}s ago)"
      fi
    fi
  done <<< "$rows"
}

# ----------------------------------------------------------------------------
# Issue picker with dependency filtering
# ----------------------------------------------------------------------------

# Picks up to $1 top open issues by priority (high→medium→low→unlabeled),
# oldest-first within priority, filtering out:
#   - issues with the 'blocked' label
#   - issues that have at least one open blocked_by dependency
#   - issues already assigned to a live worker (read from state/workers/)
pick_top_issues() {
  local k=$1

  # Build the active-issue set portably (no GNU xargs -r).
  local active_issues=""
  local f
  for f in "$(state_dir)/workers/"*.json; do
    [ -f "$f" ] || continue
    local i
    i=$(jq -r '.issue // empty' "$f" 2>/dev/null || true)
    [ -n "$i" ] && [ "$i" != "null" ] && active_issues="$active_issues $i"
  done

  local candidates
  candidates=$(gh issue list --state open --limit 100 --json number,labels --jq '
    map(select(.labels | any(.name == "blocked") | not))
    | sort_by(
        (if   any(.labels[]; .name == "priority/high")   then 0
         elif any(.labels[]; .name == "priority/medium") then 1
         elif any(.labels[]; .name == "priority/low")    then 2
         else 3 end),
        .number
      )
    | .[].number
  ' 2>/dev/null) || candidates=""
  if [ -z "$candidates" ]; then
    return 0
  fi

  local picked=0
  local repo
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || return 0
  for n in $candidates; do
    [ "$picked" -ge "$k" ] && break
    # Skip if already active
    case " $active_issues " in *" $n "*) continue ;; esac
    # Check blocked_by dependencies (best-effort; absent endpoint → 0)
    local blocking
    blocking=$(gh api "repos/$repo/issues/$n/dependencies/blocked_by" \
               --jq '[.[] | select(.state == "open")] | length' 2>/dev/null || echo 0)
    if [ "$blocking" -gt 0 ]; then
      continue
    fi
    echo "$n"
    picked=$((picked + 1))
  done
}

# ----------------------------------------------------------------------------
# Issue → branch slug
# ----------------------------------------------------------------------------

slug_for_issue() {
  local n=$1
  local title
  title=$(gh issue view "$n" --json title --jq .title 2>/dev/null || echo "issue-$n")
  echo "$title" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | tr -s '-' \
    | sed 's/^-//;s/-$//' \
    | cut -d'-' -f1-5
}

# ----------------------------------------------------------------------------
# PLAN.md phase detection
# ----------------------------------------------------------------------------

# Find the current phase (first phase header without the complete sentinel
# after it). Echoes the phase number, or empty if all phases are complete.
current_phase_number() {
  [ -f "$REPO_ROOT/PLAN.md" ] || { echo ""; return; }
  python3 - "$REPO_ROOT/PLAN.md" <<'EOF' 2>/dev/null || echo ""
import re, sys
text = open(sys.argv[1]).read()
phases = list(re.finditer(r'^##\s+Phase\s+(\d+)', text, re.M))
for i, m in enumerate(phases):
    start = m.end()
    end = phases[i+1].start() if i+1 < len(phases) else len(text)
    section = text[start:end]
    if not re.search(r'<!--\s*planner:\s*phase\s+' + m.group(1) + r'\s+complete\s*-->', section, re.I):
        print(m.group(1))
        break
EOF
}

phase_complete() {
  local open
  open=$(count_open_issues)
  [ "$open" = "0" ] || return 1
  local cur
  cur=$(current_phase_number)
  [ -n "$cur" ]
}

plan_exhausted() {
  [ -z "$(current_phase_number)" ]
}

# ----------------------------------------------------------------------------
# Pause check
# ----------------------------------------------------------------------------

is_paused() {
  [ -f "$(state_dir)/pause" ]
}

# ----------------------------------------------------------------------------
# Consecutive-failure guard
# ----------------------------------------------------------------------------
#
# When a role fails deterministically (e.g., a config error makes every
# planner bootstrap crash the same way), each retry burns one sbx + claude
# invocation. After MAX_CONSECUTIVE_FAILURES (default 3), auto-pause the
# loop with an actionable message so the user can investigate without
# the meter running.
#
# spawn-worker.sh calls bump_consecutive_failure on crash/blocked and
# reset_consecutive_failure on success. autoimprove.sh's tick calls
# check_failure_cap before dispatching.

consecutive_failure_count() {
  local role=$1
  cat "$(state_dir)/consecutive-failures.$role" 2>/dev/null || echo 0
}

bump_consecutive_failure() {
  local role=$1
  local n
  n=$(consecutive_failure_count "$role")
  echo $((n + 1)) > "$(state_dir)/consecutive-failures.$role"
}

reset_consecutive_failure() {
  local role=$1
  rm -f "$(state_dir)/consecutive-failures.$role"
}

# Returns 0 if any role has hit its failure cap (and the loop should pause).
# Returns 1 otherwise. Touches state/pause and prints a one-time warning
# when the cap is first hit.
check_failure_cap() {
  local cap="${MAX_CONSECUTIVE_FAILURES:-3}"
  local role n
  for role in builder planner playtester auditor; do
    n=$(consecutive_failure_count "$role")
    if [ "$n" -ge "$cap" ]; then
      if [ ! -f "$(state_dir)/pause" ]; then
        log_warn "============================================================"
        log_warn "$role has failed $n consecutive times (cap=$cap); auto-pausing."
        log_warn "Investigate logs:"
        log_warn "  ls state/workers/*.stderr  (per-worker output)"
        log_warn "  cat state/orchestrator.log (orchestrator decisions)"
        log_warn "Once fixed, reset and unpause:"
        log_warn "  rm state/consecutive-failures.$role"
        log_warn "  ./scripts/pause.sh off"
        log_warn "============================================================"
        touch "$(state_dir)/pause"
      fi
      return 0
    fi
  done
  return 1
}

# ----------------------------------------------------------------------------
# Per-role serialization (atomic via mkdir)
# ----------------------------------------------------------------------------

acquire_role_lock() {
  local role=$1
  local lock="$(state_dir)/$role.lock"
  if mkdir "$lock" 2>/dev/null; then
    echo "$$" > "$lock/owner"
    return 0
  fi
  return 1
}

release_role_lock() {
  local role=$1
  rm -rf "$(state_dir)/$role.lock"
}

# ----------------------------------------------------------------------------
# Merge-gate serialization (portable, no flock)
# ----------------------------------------------------------------------------

# mkdir-based lock with stale-pid detection. On macOS we don't have flock,
# and the existing role-lock pattern is the same shape — just split out
# here for the merge gate's "wait until acquired" semantics rather than
# role-lock's "try and skip" semantics.
acquire_merge_lock() {
  local lock="$(state_dir)/merge.lockd"
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -f "$lock/pid" ]; then
      local pid
      pid=$(cat "$lock/pid" 2>/dev/null || echo "")
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        log_warn "merge-gate: removing stale merge lock from dead pid $pid"
        rm -rf "$lock"
        continue
      fi
    fi
    sleep 1
  done
  echo "$$" > "$lock/pid"
}

release_merge_lock() {
  rm -rf "$(state_dir)/merge.lockd"
}
