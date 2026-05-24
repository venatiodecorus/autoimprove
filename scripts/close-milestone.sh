#!/usr/bin/env bash
# scripts/close-milestone.sh — archive the current milestone after the
# auditor declares satisfied, and leave stubs for the next milestone.
#
# Usage: close-milestone.sh <milestone-name>
#
# Example: close-milestone.sh movement-poc
#          → milestones/001-movement-poc/{SPEC.md,PLAN.md,AUDIT.md,CHANGELOG.md}

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

cd "$REPO_ROOT"

name=${1:?"usage: close-milestone.sh <milestone-name>"}

if [ ! -f SPEC.md ] || [ ! -f PLAN.md ]; then
  log_warn "SPEC.md or PLAN.md missing; nothing to archive"
  exit 1
fi

# Compute next milestone number
last=$(ls milestones/ 2>/dev/null | grep -E '^[0-9]{3}-' | sort | tail -1 | cut -d- -f1 || echo "")
next=$(printf "%03d" $((${last:-0} + 1)))
dir="milestones/${next}-${name}"

log_info "archiving current milestone to $dir"
mkdir -p "$dir"

git mv SPEC.md "$dir/SPEC.md"
git mv PLAN.md "$dir/PLAN.md"

# Generate AUDIT.md from the audit history
{
  echo "# Audit summary for milestone ${next} (${name})"
  echo ""
  echo "Closed at: $(date -u +%FT%TZ)"
  echo "Final verdict: $(tail -1 state/audit-history.jsonl | jq -r '.satisfied' 2>/dev/null || echo "unknown")"
  echo ""
  echo "## Full verdict history"
  echo ""
  echo '```json'
  if [ -f state/audit-history.jsonl ]; then
    jq -s '.' state/audit-history.jsonl 2>/dev/null || cat state/audit-history.jsonl
  fi
  echo '```'
} > "$dir/AUDIT.md"

# Generate CHANGELOG.md from git log + closed issues
{
  echo "# Changelog for milestone ${next} (${name})"
  echo ""
  echo "## Closed issues"
  echo ""
  gh issue list --state closed --limit 200 --search "closed:>$(date -d '6 months ago' +%Y-%m-%d 2>/dev/null || date -v-6m +%Y-%m-%d)" \
    --json number,title --jq '.[] | "- #\(.number) \(.title)"' 2>/dev/null || \
    echo "(could not enumerate closed issues; run \`gh issue list --state closed\` manually)"
  echo ""
  echo "## Commits"
  echo ""
  echo '```'
  git log --oneline -100
  echo '```'
} > "$dir/CHANGELOG.md"

# Reset state for the next milestone
rm -f state/audit-history.jsonl state/spec.hash state/last-playtest.sha \
      state/gap-convert.last-source-hash state/gap-convert.processed \
      state/consecutive-failures.*
touch state/audit-history.jsonl

# SPEC.md and PLAN.md were `git mv`'d into the archive above; nothing remains
# at the repo root. On the next `./scripts/autoimprove.sh` run, the absence
# of SPEC.md triggers planner bootstrap automatically — that's the contract
# the planner agent definition documents. The human can also kick this off
# manually with `/plan "new milestone scope"` before restarting the loop.

git add .
git commit -m "chore: close milestone ${next} (${name})

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

log_info "milestone ${next}-${name} archived"
log_info "next steps:"
log_info "  - Restart the loop (./scripts/autoimprove.sh) and the planner will"
log_info "    bootstrap a new milestone from BRIEF.md, OR"
log_info "  - Run /plan \"describe the new milestone's scope\" first to seed it."
