---
description: Launch the autoimprove orchestrator inside a tmux session with live monitoring panes.
allowed-tools: Bash(./scripts/monitor.sh:*), Bash(./scripts/dashboard.sh:*), Read
---

The monitor is a tmux session that runs the orchestrator and tails everything observable. Start it from your terminal:

```
./scripts/monitor.sh
```

Idempotent: if the session already exists, it just attaches. Detach with `C-b d` (orchestrator keeps running). Kill the whole session with `C-b : kill-session` (also stops the orchestrator).

Windows:

| Window | What it shows |
| --- | --- |
| `loop` | The orchestrator itself (stdout teed to `state/orchestrator.log`) |
| `dash` | Colored snapshot every 2s — workers, ready-to-merge, issue counts, last audit, gap-convert state, playtest staleness, current phase, sbx sandboxes |
| `workers` | Live tail of every `state/workers/*.{stdout,stderr}`. Picks up new workers as they appear; each line is prefixed with the worker id |
| `sbx` | `sbx ls` refreshed every 3s |
| `git` | `git log --oneline -20` and `git status --short`, refreshed every 5s |

Tuning knobs (env vars when launching):

- `AUTOIMPROVE_TMUX_SESSION` — session name (default `autoimprove`). Useful if you want multiple loops in parallel.
- All the orchestrator's existing env vars (`N_PARALLEL`, `MAX_ITERATIONS`, `LOOP_SLEEP_S`, `WORKER_TIMEOUT_S`, `BLOCKED_RETRY_S`) — set them before running `./scripts/monitor.sh`.

Worker logs are produced by piping `claude --output-format stream-json --verbose` through `scripts/_claude-pretty.jq`, so each line in the `workers` window is one significant event: tool call, tool result, assistant text, or final summary.

If you just want the snapshot once (no tmux), run `./scripts/dashboard.sh` on its own.
