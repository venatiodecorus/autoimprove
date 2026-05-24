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
# State helpers
# ----------------------------------------------------------------------------

state_dir() { echo "$REPO_ROOT/state"; }

# ----------------------------------------------------------------------------
# Spec hash and audit history
# ----------------------------------------------------------------------------

spec_hash() {
  if [ -f "$REPO_ROOT/SPEC.md" ]; then
    sha256sum "$REPO_ROOT/SPEC.md" | cut -d' ' -f1
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

# Terminated when the last two non-invalidation entries are both satisfied=true
# at confidence=high, AND there is no intervening invalidation between them.
terminated() {
  local hist="$(state_dir)/audit-history.jsonl"
  [ -f "$hist" ] || return 1
  # Take lines since the most recent invalidation marker (or all lines if none)
  local recent
  recent=$(tac "$hist" | awk '/"type":"invalidation"/{exit} {print}' | tac)
  [ -z "$recent" ] && return 1
  # Need at least 2 verdicts, both satisfied:true confidence:high
  local count
  count=$(printf '%s\n' "$recent" | tail -2 | jq -s '
    if length < 2 then 0
    elif all(.[]; .satisfied == true and .confidence == "high") then 2
    else 0 end
  ' 2>/dev/null || echo 0)
  [ "$count" = "2" ]
}

last_audit_found_gaps() {
  local hist="$(state_dir)/audit-history.jsonl"
  [ -f "$hist" ] || return 1
  local last
  last=$(grep -v '"type":"invalidation"' "$hist" | tail -1)
  [ -z "$last" ] && return 1
  [ "$(echo "$last" | jq -r '.satisfied')" = "false" ] && \
    [ "$(echo "$last" | jq '.gaps | length')" -gt 0 ]
}

# gap-convert sentinel: stores the hash of the last audit verdict that
# triggered a gap-convert run. Lets us spawn gap-convert exactly once per
# new gap-finding audit verdict without re-spawning every tick.
maybe_clear_gap_convert_flag() {
  local hist="$(state_dir)/audit-history.jsonl"
  local flag="$(state_dir)/gap-convert.processed"
  [ -f "$flag" ] || return 0
  [ -f "$hist" ] || { rm -f "$flag"; return 0; }
  local last
  last=$(grep -v '"type":"invalidation"' "$hist" | tail -1)
  # If the most recent audit no longer shows gaps, the cycle moved forward.
  if [ -z "$last" ] || [ "$(echo "$last" | jq -r '.satisfied' 2>/dev/null)" = "true" ]; then
    rm -f "$flag"
  fi
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

count_live_workers() {
  ls "$(state_dir)/workers/"*.json 2>/dev/null | wc -l | tr -d ' '
}

count_pending_merges() {
  ls "$(state_dir)/ready-to-merge/"*.json 2>/dev/null | wc -l | tr -d ' '
}

count_open_issues() {
  gh issue list --state open --json number --jq 'length' 2>/dev/null || echo 0
}

# All three drained → safe to run a serial stage (playtest or audit).
ready_for_serial_stage() {
  [ "$(count_open_issues)" -eq 0 ] && \
  [ "$(count_pending_merges)" -eq 0 ] && \
  [ "$(count_live_workers)" -eq 0 ]
}

# Workers older than WORKER_TIMEOUT_S are presumed dead; clean them up.
sweep_stale_workers() {
  local timeout="${WORKER_TIMEOUT_S:-1800}"
  local now=$(date +%s)
  for f in "$(state_dir)/workers/"*.json; do
    [ -e "$f" ] || continue
    local started worker issue tree branch age
    started=$(jq -r .started_at "$f" 2>/dev/null || echo "")
    [ -z "$started" ] && continue
    local started_epoch
    started_epoch=$(date -d "$started" +%s 2>/dev/null || \
                    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null || echo 0)
    age=$((now - started_epoch))
    if [ "$age" -gt "$timeout" ]; then
      worker=$(jq -r .worker "$f")
      issue=$(jq -r .issue "$f")
      tree=$(jq -r .worktree "$f")
      branch=$(jq -r .branch "$f" 2>/dev/null || echo "")
      report_error "$worker" "$issue" "timeout after ${age}s" \
        "$(state_dir)/workers/$worker.stderr"
      # Reopen issue if it was closed prematurely
      if [ "$issue" != "null" ]; then
        gh issue reopen "$issue" 2>/dev/null || true
        gh issue edit "$issue" --add-label "blocked" 2>/dev/null || true
      fi
      "$REPO_ROOT/scripts/cleanup-worker.sh" "$worker" "$tree" "$branch" 2>/dev/null || true
    fi
  done
}

# Strip the 'blocked' label from issues whose last activity is older than
# BLOCKED_RETRY_S, so the next dispatch re-picks them. This is the simple
# version of "blocked issue triage": after the cooldown, give them one
# more shot. If they fail again, they get blocked again, etc.
retry_blocked_issues() {
  local cooldown="${BLOCKED_RETRY_S:-3600}"
  local now_epoch
  now_epoch=$(date +%s)
  # Read once; up to 50 blocked issues per pass.
  local rows
  rows=$(gh issue list --state open --label blocked --limit 50 \
    --json number,updatedAt --jq '.[] | "\(.number) \(.updatedAt)"' 2>/dev/null || true)
  [ -z "$rows" ] && return 0
  while IFS=' ' read -r n updated; do
    [ -z "$n" ] && continue
    local updated_epoch age
    updated_epoch=$(date -d "$updated" +%s 2>/dev/null || \
                    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated" +%s 2>/dev/null || echo 0)
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
  local active_issues
  active_issues=$(ls "$(state_dir)/workers/"*.json 2>/dev/null \
                  | xargs -r -n1 jq -r '.issue' 2>/dev/null | sort -u | tr '\n' ' ')

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
  ')

  local picked=0
  local repo
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
  for n in $candidates; do
    [ "$picked" -ge "$k" ] && break
    # Skip if already active
    case " $active_issues " in *" $n "*) continue ;; esac
    # Check blocked_by dependencies
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
  # Lowercase, replace non-alnum with -, collapse, trim, max 5 words
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
    if '<!-- planner: phase' not in section.lower() and 'complete -->' not in section.lower():
        # Check that the actual sentinel format is missing
        if not re.search(r'<!--\s*planner:\s*phase\s+' + m.group(1) + r'\s+complete\s*-->', section, re.I):
            print(m.group(1))
            break
EOF
}

# Current phase has all its tracked issues closed? Heuristic: any closed issue
# referencing "phase N" or labeled with the current phase counts; for now we
# rely on the simpler rule that ALL issues are closed (mechanical, no labels
# needed). The orchestrator only triggers phase-advance when total open issues
# is zero anyway, so this becomes "is there a next phase to advance to".
phase_complete() {
  [ "$(count_open_issues)" -eq 0 ] || return 1
  local cur
  cur=$(current_phase_number)
  [ -n "$cur" ]
}

# PLAN.md is exhausted when current_phase_number returns empty.
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
# Per-role serialization (atomic via mkdir)
# ----------------------------------------------------------------------------

# mkdir is atomic across processes on POSIX filesystems, unlike test+write.
# This means /plan (manual) and the daemon can't both run a planner at
# the same time.
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
