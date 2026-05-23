#!/usr/bin/env bash
# scripts/bootstrap.sh — first-time setup for a new autoimprove project.
# Idempotent: safe to re-run.
#
# Usage: bootstrap.sh [<repo-name>]
#   Default repo name is the parent directory's basename.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

cd "$REPO_ROOT"

repo_name=${1:-$(basename "$REPO_ROOT")}

# ---------------------------------------------------------------------------
# Step 1 — verify prerequisites
# ---------------------------------------------------------------------------

log_info "checking prerequisites..."

if ! command -v gh >/dev/null 2>&1; then
  log_warn "gh CLI not found. Install from https://cli.github.com/"
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  log_warn "gh not authenticated. Run 'gh auth login' first."
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  log_warn "jq not found. Install jq (it's used everywhere)."
  exit 1
fi
if ! command -v sbx >/dev/null 2>&1; then
  log_warn "sbx (Docker AI Sandboxes) not found. Install Docker Desktop with AI Sandboxes."
  log_warn "You can continue setup; sandboxes are only needed when running the loop."
fi
if ! command -v uuidgen >/dev/null 2>&1; then
  log_warn "uuidgen not found. Worker IDs will fall back to timestamps."
fi

if [ ! -f BRIEF.md ]; then
  log_warn "BRIEF.md missing. Write your project pitch before running the loop."
fi

# ---------------------------------------------------------------------------
# Step 1.5 — configure sbx secrets (anthropic + github)
# ---------------------------------------------------------------------------
#
# Sandboxes get credentials from `sbx secret`, never from host env vars.
# We don't read the secret values here — sbx prompts the user interactively
# (or accepts stdin), and stores them via Docker's credential helper.

setup_sbx_secrets() {
  command -v sbx >/dev/null 2>&1 || return 0

  local listing
  listing=$(sbx secret ls 2>/dev/null || true)
  local globals
  globals=$(printf '%s\n' "$listing" | awk '$1 == "(global)" { print $2 }')

  if ! printf '%s\n' "$globals" | grep -qx anthropic; then
    log_info "sbx secret 'anthropic' not set."
    log_info "  Set it now with one of:"
    log_info "    sbx secret set -g anthropic --oauth          # OAuth flow"
    log_info "    echo \"\$ANTHROPIC_API_KEY\" | sbx secret set -g anthropic   # from env"
  else
    log_info "sbx secret 'anthropic' already configured."
  fi

  if ! printf '%s\n' "$globals" | grep -qx github; then
    if gh auth token >/dev/null 2>&1; then
      log_info "registering github token from gh CLI into sbx (global)..."
      gh auth token | sbx secret set -g github >/dev/null
      log_info "sbx secret 'github' configured."
    else
      log_warn "sbx secret 'github' not set and 'gh auth token' unavailable."
      log_warn "  Run: gh auth login   (then re-run bootstrap)"
    fi
  else
    log_info "sbx secret 'github' already configured."
  fi
}
setup_sbx_secrets

# ---------------------------------------------------------------------------
# Step 2 — initialize git
# ---------------------------------------------------------------------------

if [ ! -d .git ]; then
  log_info "initializing git repo..."
  git init -b main
  git add .
  git commit -m "chore: bootstrap autoimprove framework

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
fi

# ---------------------------------------------------------------------------
# Step 3 — create GitHub repo (private)
# ---------------------------------------------------------------------------

if ! gh repo view >/dev/null 2>&1; then
  log_info "creating private GitHub repo: $repo_name"
  gh repo create "$repo_name" --private --source=. --remote=origin --push
fi

# ---------------------------------------------------------------------------
# Step 4 — create issue labels
# ---------------------------------------------------------------------------

log_info "creating issue labels (idempotent)..."

create_label() {
  gh label create "$1" --color "$2" --description "$3" --force >/dev/null 2>&1 || true
}

create_label "bug"             "d73a4a" "Something is broken"
create_label "enhancement"     "a2eeef" "New feature or improvement"
create_label "chore"           "cfd3d7" "Infra / docs / housekeeping"
create_label "priority/high"   "b60205" "Block other work until resolved"
create_label "priority/medium" "fbca04" "Important but not blocking"
create_label "priority/low"    "0e8a16" "Nice to have"
create_label "blocked"         "000000" "Merge gate rejected; needs another iteration"
create_label "agent/planner"   "1d76db" "Filed by the planner"
create_label "agent/builder"   "5319e7" "Filed by the builder"
create_label "agent/playtester" "c5def5" "Filed by the playtester"
create_label "agent/auditor"   "fef2c0" "Filed by the planner from auditor gaps"

# ---------------------------------------------------------------------------
# Step 5 — ensure framework state directories exist
# ---------------------------------------------------------------------------

mkdir -p state/workers state/ready-to-merge worktrees milestones
touch state/audit-history.jsonl

# Make scripts executable (in case archive extraction didn't preserve perms)
chmod +x scripts/*.sh

# ---------------------------------------------------------------------------
# Step 6 — final commit
# ---------------------------------------------------------------------------

git add -A
git diff --cached --quiet || git commit -m "chore: bootstrap complete

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

if git remote get-url origin >/dev/null 2>&1; then
  git push -u origin main 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

cat <<EOF

✅ Bootstrap complete.

Next steps:
  1. Fill in BRIEF.md with your project pitch (if not already done).
  2. Confirm sbx secrets are set:
       sbx secret ls
     If 'anthropic' is missing, set it (see the bootstrap output above).
  3. Start the loop:
       ./scripts/autoimprove.sh

The first run will dispatch the planner with no SPEC.md. The planner reads
BRIEF.md and writes SPEC.md + PLAN.md, seeds Phase 1 issues, AND writes
scripts/gates.sh tailored to the tech stack it chose. After that, builders
take over.

You should not need to edit any scripts/*.sh files by hand.

EOF
