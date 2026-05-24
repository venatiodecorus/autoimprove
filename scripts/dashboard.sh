#!/usr/bin/env bash
# scripts/dashboard.sh — one-shot status snapshot for the orchestrator.
#
# Designed to be invoked repeatedly from a loop, e.g.:
#   while :; do clear; ./scripts/dashboard.sh; sleep 2; done
# which is what scripts/monitor.sh runs in its tmux 'dash' window.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# ----- ANSI helpers ---------------------------------------------------------
b()      { printf '\033[1m%s\033[0m'  "$1"; }
dim()    { printf '\033[2m%s\033[0m'  "$1"; }
cyan()   { printf '\033[36m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }
green()  { printf '\033[32m%s\033[0m' "$1"; }
red()    { printf '\033[31m%s\033[0m' "$1"; }

fmt_age() {
  local s=$1
  if [ "$s" -lt 60 ]; then
    printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%dm%02ds' $((s/60)) $((s%60))
  else
    printf '%dh%02dm' $((s/3600)) $(((s%3600)/60))
  fi
}

# ----- Header ---------------------------------------------------------------
head_short=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')
branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
echo "$(b 'autoimprove')  HEAD $(cyan "$head_short")  branch $(cyan "$branch")  $(date '+%H:%M:%S')"
echo

# ----- Workers --------------------------------------------------------------
n_live=$(count_live_workers)
echo "$(b "WORKERS")  $(dim "(live: $n_live)")"
now_epoch=$(date +%s)
any=0
for f in "$(state_dir)/workers/"*.json; do
  [ -e "$f" ] || continue
  any=1
  wid=$(jq -r .worker "$f"        2>/dev/null || echo '?')
  role=$(jq -r .role "$f"          2>/dev/null || echo '?')
  context=$(jq -r '.context // ""' "$f" 2>/dev/null || echo '')
  issue=$(jq -r '.issue // "—"'    "$f" 2>/dev/null || echo '—')
  br=$(jq -r .branch "$f"          2>/dev/null || echo '')
  started=$(jq -r .started_at "$f" 2>/dev/null || echo '')
  started_epoch=$(iso8601_to_epoch "$started")
  age=$(( now_epoch - started_epoch ))
  br_short=$(echo "$br" | sed 's|^iter/||; s|^audit-|audit/|' | cut -c1-46)
  role_label="$role"
  [ -n "$context" ] && role_label="$role/$context"
  printf '  %s  %-18s  issue:%-4s  %-46s  %s\n' \
    "$(cyan "$wid")" "$role_label" "$issue" "$br_short" "$(dim "$(fmt_age "$age") ago")"
done
[ "$any" -eq 0 ] && echo "  $(dim '(none)')"
echo

# ----- Pending merges -------------------------------------------------------
n_merge=$(count_pending_merges)
echo "$(b "READY TO MERGE")  $(dim "($n_merge)")"
any=0
for f in "$(state_dir)/ready-to-merge/"*.json; do
  [ -e "$f" ] || continue
  any=1
  wid=$(jq -r .worker "$f"     2>/dev/null || echo '?')
  role=$(jq -r .role "$f"      2>/dev/null || echo '?')
  issue=$(jq -r '.issue // "—"' "$f" 2>/dev/null || echo '—')
  br=$(jq -r .branch "$f"      2>/dev/null || echo '')
  printf '  %s  %-12s  issue:%-4s  %s\n' "$(yellow "$wid")" "$role" "$issue" "$br"
done
[ "$any" -eq 0 ] && echo "  $(dim '(none)')"
echo

# ----- Issues ---------------------------------------------------------------
# Suppress count_open_issues' stderr warning — the dashboard re-renders every
# 2s, the orchestrator's own log already surfaces gh outages, and we don't
# want every refresh to print a fresh warning line.
open=$(count_open_issues 2>/dev/null)
if [ "$open" = "-1" ]; then
  echo "$(b "ISSUES")  $(red 'gh unreachable')"
else
  high=$(gh issue list --state open --label priority/high   --json number --jq length 2>/dev/null || echo '?')
  med=$( gh issue list --state open --label priority/medium --json number --jq length 2>/dev/null || echo '?')
  low=$( gh issue list --state open --label priority/low    --json number --jq length 2>/dev/null || echo '?')
  blk=$( gh issue list --state open --label blocked         --json number --jq length 2>/dev/null || echo '?')
  echo "$(b "ISSUES")  $(dim "(open: $open)")  high:$high  medium:$med  low:$low  $(yellow "blocked:$blk")"
fi
echo

# ----- Audit / gap-convert --------------------------------------------------
echo "$(b "AUDIT")"
last=$(grep -v '"type":"invalidation"' "$(state_dir)/audit-history.jsonl" 2>/dev/null | tail -1)
if [ -z "$last" ]; then
  echo "  $(dim '(no verdicts since last invalidation)')"
else
  sat=$( echo "$last" | jq -r '.satisfied'      2>/dev/null || echo '?')
  conf=$(echo "$last" | jq -r '.confidence'     2>/dev/null || echo '?')
  gaps=$(echo "$last" | jq -r '.gaps | length'  2>/dev/null || echo '?')
  ts=$(  echo "$last" | jq -r '.timestamp // ""' 2>/dev/null || echo '')
  if [ -n "$ts" ]; then
    age=$(( now_epoch - $(iso8601_to_epoch "$ts") ))
    age_label="$(fmt_age "$age") ago"
  else
    age_label=""
  fi
  if [ "$sat" = "true" ]; then
    echo "  last: $(green satisfied)  confidence=$conf  $(dim "$age_label")"
  else
    echo "  last: $(yellow 'not satisfied')  confidence=$conf  gaps=$gaps  $(dim "$age_label")"
  fi

  # Gap-convert sentinel state
  if gap_convert_needed; then
    echo "  gap-convert: $(yellow 'needed') $(dim '(will spawn next tick)')"
  elif [ -f "$(state_dir)/gap-convert.last-source-hash" ]; then
    stored=$(cat "$(state_dir)/gap-convert.last-source-hash" 2>/dev/null | cut -c1-12)
    echo "  gap-convert: $(green 'processed for current audit') $(dim "(hash $stored…)")"
  fi
fi
echo

# ----- Playtest -------------------------------------------------------------
if last_playtest_is_current; then
  sha=$(cat "$(state_dir)/last-playtest.sha" 2>/dev/null | cut -c1-7)
  echo "$(b "PLAYTEST")  $(green 'clean') $(dim "(at $sha)")"
else
  echo "$(b "PLAYTEST")  $(yellow 'stale / not yet run')"
fi
echo

# ----- Phase ----------------------------------------------------------------
cur=$(current_phase_number)
if [ -z "$cur" ]; then
  echo "$(b "PHASE")  $(green 'all phases complete')"
else
  echo "$(b "PHASE")  current: $(cyan "$cur")"
fi
echo

# ----- Sandboxes ------------------------------------------------------------
echo "$(b "SANDBOXES")  $(dim '(sbx ls)')"
if command -v sbx >/dev/null 2>&1; then
  sbx ls 2>/dev/null | tail -n +2 | head -20 | sed 's/^/  /' || true
else
  echo "  $(red 'sbx not in PATH')"
fi
