# Repo conventions

This file is read by every agent (planner, builder, playtester, auditor) before they act. Keep it short and authoritative.

## Repo layout

```
BRIEF.md                long-lived project pitch (rarely changes)
SPEC.md                 current milestone's authoritative spec
PLAN.md                 current milestone's phased roadmap

scripts/                framework code (orchestrator, merge gate, etc.)
  gates.sh              project quality gates — written by the planner on bootstrap;
                        the only file under scripts/ any agent may edit (planner only)

.claude/                Claude Code config
  agents/               agent definitions (builder, planner, playtester, auditor)
  commands/             slash commands

state/                  runtime state (gitignored)
.sbx/                   per-worker git worktrees managed by sbx (gitignored)
milestones/             archived previous milestones
```

> **Customize this file** to add project-specific guidance: where the source code lives, how to run the dev server, what your tech stack is, anything that affects how agents should work.

## Project-specific conventions

> Examples:
>
> - "Source lives under `app/`. Tests live under `tests/`. Don't put anything game-specific anywhere else."
> - "Use TypeScript strict mode; never `any`."
> - "Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:`, etc)."
> - "The dev server runs on `localhost:5173` via `npm run dev` from `app/`."
> - "Git identity: commits should be authored by `Claude <noreply@anthropic.com>`."

## Quality gates

Defined in `scripts/gates.sh`. The merge gate runs this against every rebased branch. If it exits non-zero, the branch is rejected and its issue reopens with the failure log attached. The **planner** writes this file during bootstrap mode based on the tech stack chosen in `SPEC.md`; the human never edits it.

## Sandbox credentials

Sandboxes pull `ANTHROPIC_API_KEY` and `GH_TOKEN` from `sbx secret`, not from host env vars. `./scripts/bootstrap.sh` registers your `gh` token automatically and prompts for the Anthropic key if missing. Verify with `sbx secret ls`.

## What agents must NOT do

These are enforced in the agent definitions; documenting them here for cross-reference:

- The **builder** never merges to main, never pushes to main, never picks its own issue, never edits anything under `scripts/`.
- The **planner** never edits project source code. Allowed surface: `SPEC.md`, `PLAN.md`, `scripts/gates.sh`, and GitHub issues.
- The **playtester** never edits code; only commits its evidence files under `.llm/playtests/`.
- The **auditor** is strictly read-only; writes only its verdict line and exit marker.

## The loop in one paragraph

The orchestrator (`scripts/autoimprove.sh`) reads repo state, dispatches up to `N_PARALLEL` builders against the top unblocked GitHub issues, waits for them to push branches, serially rebases-and-merges those branches through the merge gate, and once the queue is fully drained spawns a playtester (which may file new bug issues) and then an auditor (which compares state to SPEC.md). The loop ends when the auditor declares the spec satisfied twice in a row.
