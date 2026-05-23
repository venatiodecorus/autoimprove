---
description: Manually invoke the planner. Use this to extend SPEC.md, re-prioritize, or write a fresh spec after close-milestone.sh.
allowed-tools: Task, Bash(gh:*), Bash(git:*), Read, Write, Edit
argument-hint: [free-form goal]
---

Run the planner agent with the goal: `$ARGUMENTS` (if empty, the planner will refine SPEC.md/PLAN.md based on current repo state).

1. Spawn the `planner` subagent with prompt: *"Run a planner iteration per your agent definition in `.claude/agents/planner.md`. This is a manual `/plan` invocation. Goal: `$ARGUMENTS` (if empty, refine the current SPEC/PLAN to match recent activity)."*
2. Report what changed (SPEC.md updated? new phases? issues filed?).

This invokes the planner in **manual mode** — it does NOT run inside a Docker Sandbox. It runs in your current Claude Code session against the working directory.

Common use cases:
- `/plan "add multiplayer support"` — extends the current milestone's SPEC.md
- `/plan` (no args) — refine/triage based on current state
- `/plan "draft the next milestone — focus on enemy AI and combat balance"` — after `close-milestone.sh` left a stub
