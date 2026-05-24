# Autoimprove Framework

A generic, project-agnostic loop that uses parallel Docker Sandboxes to build, test, and audit a project from a spec — iteratively, autonomously, with a clean termination condition.

## What it does

- The **planner** reads `BRIEF.md`, writes `SPEC.md` and `PLAN.md`, files GitHub issues.
- **Builders** (up to N in parallel) each work one issue in a Docker Sandbox on its own git worktree.
- A serialized **merge gate** rebases each builder's branch onto current `main`, re-runs your quality gates, and either fast-forwards or rejects (reopening the issue with the failure log).
- Once the issue queue is empty, a **playtester** exercises the project and files bug issues.
- When the playtest is clean and PLAN.md is exhausted, an **auditor** compares the codebase against SPEC.md and emits a structured verdict.
- Two consecutive "satisfied" verdicts → loop terminates with a milestone-complete message.

Add scope later by editing SPEC.md (the audit count auto-invalidates) or by closing the milestone and starting a fresh one.

## Requirements

- [Docker Desktop with AI Sandboxes](https://docs.docker.com/ai/sandboxes/) (the `sbx` CLI). Early Access — the `sbx run claude` interface may shift; if it does, update `scripts/spawn-worker.sh`.
- [`gh` CLI](https://cli.github.com/) authenticated against your GitHub account on the host.
- `jq`, `git`, `bash` 3.2+, `uuidgen`, and a SHA-256 implementation (`sha256sum` from coreutils on Linux, built-in `shasum` on macOS).
- An Anthropic API key, stored via `sbx secret set -g anthropic` (or OAuth). The host does **not** need it exported.
- Optional: `tmux` for `./scripts/monitor.sh` (see [Monitoring](#monitoring-tmux)).

## Quickstart

1. Extract this framework into an empty directory and `cd` into it:
   ```sh
   mkdir my-project && cd my-project
   tar -xzf /path/to/autoimprove-framework.tar.gz --strip-components=1
   ```

2. Fill in `BRIEF.md` with your project pitch (1–3 paragraphs).

3. Optional: edit `CLAUDE.md` to add project-specific conventions agents should know about (source directories, naming, tech-stack details).

4. Bootstrap git + GitHub repo + labels + `sbx` secrets:
   ```sh
   ./scripts/bootstrap.sh
   ```
   This registers your `gh` token into `sbx secret` automatically and prompts you for any other missing secrets (Anthropic). Sandboxes pull credentials from there — you do not export `GH_TOKEN` or `ANTHROPIC_API_KEY` on the host.

5. Start the loop:
   ```sh
   ./scripts/autoimprove.sh
   ```

   On the first tick, the planner reads BRIEF.md, decides the tech stack, and writes SPEC.md, PLAN.md, `scripts/gates.sh`, and Phase 1 issues. Builders pick up from there. You should not need to hand-edit any script.

## Monitoring (tmux)

While you're tuning, a single command spins up the orchestrator with live monitoring panes:

```sh
./scripts/monitor.sh
```

That launches (or re-attaches to) an `autoimprove` tmux session with a dense two-window layout:

**Window 1 — `main`** (three panes, everything you usually need on one screen):

```
┌──────────────────┬─────────────────────┐
│ dashboard        │                     │
│ (top-left)       │   workers           │
├──────────────────┤   (live agent       │
│ orchestrator     │    activity)        │
│ (bottom-left)    │                     │
└──────────────────┴─────────────────────┘
```

- **dashboard** — Colored snapshot every 2s: workers, ready-to-merge, issue counts by priority, last audit + gap-convert state, playtest staleness, current phase, sbx sandboxes. Flicker-free rendering.
- **orchestrator** — Runs `./scripts/autoimprove.sh`, stdout tee'd to `state/orchestrator.log`. This is where pause/Ctrl+C reaches the loop.
- **workers** — Live tail of every `state/workers/*.{stdout,stderr}`. Picks up new workers as they appear; each line is prefixed with the worker id. Agent activity (tool calls, results, costs) streams here.

**Window 2 — `extras`** (deep debugging; cycle with `C-b n`): `git log + status` on top, raw `sbx ls` on bottom. The dashboard already covers most of this, so you usually won't need it.

Tips:
- `C-b d` detach (orchestrator keeps running). Reattach with `./scripts/monitor.sh`.
- `C-b ←/→/↑/↓` or click — navigate between panes (mouse mode is on).
- `C-b z` zoom current pane to fullscreen (toggle). Useful when worker activity is high-volume.
- `C-b [` enter scrollback mode (q to exit).
- `C-b : kill-session` stop everything including the orchestrator.

Worker activity streams live in the `workers` window because [spawn-worker.sh](scripts/spawn-worker.sh) pipes claude's `--output-format stream-json --verbose` through [scripts/_claude-pretty.jq](scripts/_claude-pretty.jq) — each line is one significant event (tool call, tool result, assistant text, or final summary).

If you just want the snapshot once without tmux, run `./scripts/dashboard.sh` on its own.

## Interacting with a running loop

| Action | Command |
| --- | --- |
| Pause the loop | `./scripts/pause.sh on` |
| Resume | `./scripts/pause.sh off` |
| Check status | `./scripts/pause.sh` |
| Add scope mid-loop | pause, edit `SPEC.md`, unpause (audit history auto-invalidates) |
| Run planner manually | `/plan "describe new scope"` (inside Claude Code) |
| Stop entirely | `Ctrl+C` — state persists on disk; just rerun `autoimprove.sh` to continue |

Errors print inline in the orchestrator's output, like:

```
[ERROR] worker b-a3f2e1c4 (issue #15) failed: post-rebase gates failed. Log: .sbx/b-a3f2e1c4-worktrees/iter/15-add-camera-controls-b-a3f2e1c4/.gates.log
```

## When the loop says "milestone complete"

The auditor agreed twice in a row with high confidence. Two paths forward:

- **Extend this milestone**: edit `SPEC.md` to add scope, restart the loop. The spec-hash check invalidates the audit history so the loop needs at least 2 fresh audits before it can terminate again.
- **Archive and start a new milestone**: run `./scripts/close-milestone.sh <milestone-name>`. The current SPEC, PLAN, and audit history archive to `milestones/NNN-<name>/`. A stub SPEC.md is left at the root reminding you to run `/plan` to write the next milestone.

## Tuning

Set these as env vars before running `autoimprove.sh`:

- `N_PARALLEL` — concurrent builders (default 2; start lower than you think to keep costs visible while you tune)
- `MAX_ITERATIONS` — hard ceiling on loop ticks (default 200)
- `LOOP_SLEEP_S` — sleep between ticks when idle (default 5)
- `WORKER_TIMEOUT_S` — force-kill workers older than this (default 1800)

## Architecture

Single sentence: the orchestrator is a deterministic shell state machine, agents are stateless workers that read a prompt and write a marker on exit.

For the full design rationale — milestone lifecycle, concurrency primitives, termination predicate, conflict policy — see the design doc this framework was generated from.

## Build order if you want to verify pieces incrementally

If something breaks, the easiest way to isolate is:

1. Run `scripts/gates.sh` manually against `main`. Does it pass? (Before the planner has run, this is a no-op stub that exits 0; after planner bootstrap, it runs the real project gates.)
2. Test the merge gate in isolation: create a branch, push it, run `./scripts/merge-gate.sh <fake-worker-id>` with a hand-rolled marker file.
3. Run the orchestrator with `N_PARALLEL=1` to remove concurrency from the picture.
4. Disable termination (return false in `terminated()` in `lib.sh`) so you can watch the auditor produce verdicts without the loop exiting on them. Once verdicts look right, re-enable termination.
5. Confirm sandbox credentials: `sbx secret ls` should list both `anthropic` and `github` in the `(global)` scope.

## License

MIT.
