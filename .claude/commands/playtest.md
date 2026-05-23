---
description: Manually invoke the playtester agent. Useful for debugging or one-off testing without restarting the loop.
allowed-tools: Task, Bash(gh:*), Bash(git:*), Read, Bash
---

Run the playtester agent.

1. Spawn the `playtester` subagent with prompt: *"Run a playtester iteration per your agent definition in `.claude/agents/playtester.md`. This is a manual `/playtest` invocation."*
2. Report how many issues were filed (and any crashes).

Note: in production the orchestrator handles playtester serialization automatically — you only need this command for ad-hoc debugging while the loop is paused or stopped.
