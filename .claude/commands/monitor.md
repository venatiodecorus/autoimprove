---
description: Launch the autoimprove orchestrator inside a tmux session with live monitoring panes.
allowed-tools: Bash(./scripts/monitor.sh:*), Bash(./scripts/dashboard.sh:*), Read
---

The monitor is a tmux session that runs the orchestrator and tails everything observable. Start it from your terminal:

```
./scripts/monitor.sh
```

Idempotent: if the session already exists, it just attaches. Detach with `C-b d` (orchestrator keeps running). Kill the whole session (and the orchestrator) with `C-b : kill-session`.

**Layout — Window 1 `main`** (3 panes):

```
┌──────────────────┬─────────────────────┐
│ dashboard        │   workers           │
├──────────────────┤   (live agent       │
│ orchestrator     │    activity)        │
└──────────────────┴─────────────────────┘
```

| Pane | What it shows |
| --- | --- |
| dashboard | Workers / merges / issues / audits / playtest / sandboxes, refreshed every 2s, flicker-free |
| orchestrator | `./scripts/autoimprove.sh`, output tee'd to `state/orchestrator.log` |
| workers | Live tail of every `state/workers/*.{stdout,stderr}`, prefixed with worker id |

**Window 2 `extras`** — git log+status and raw `sbx ls`, for deep debugging. Cycle with `C-b n`.

Tips:
- `C-b ←/→/↑/↓` or click between panes (mouse mode is on).
- `C-b z` zoom current pane to fullscreen (toggle).
- `C-b [` enter scrollback mode (q to exit).

Tuning knobs (env vars before launching):

- `AUTOIMPROVE_TMUX_SESSION` — session name (default `autoimprove`). Useful for multiple loops in parallel.
- All orchestrator env vars apply: `N_PARALLEL`, `MAX_ITERATIONS`, `LOOP_SLEEP_S`, `WORKER_TIMEOUT_S`, `BLOCKED_RETRY_S`, `MAX_CONSECUTIVE_FAILURES`.

Worker logs are produced by piping `claude --output-format stream-json --verbose` through `scripts/_claude-pretty.jq`, so each line is one significant event: tool call, tool result, assistant text, or final summary. Plain-text sbx status lines are preserved with a `[raw]` prefix.

For a one-shot snapshot without tmux: `./scripts/dashboard.sh`.
