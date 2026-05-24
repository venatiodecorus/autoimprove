---
description: Start the autoimprove orchestrator daemon (host-side, not inside Claude).
allowed-tools: Bash(./scripts/autoimprove.sh:*), Read
---

The autoimprove loop is a long-running shell daemon, not a Claude-driven workflow. Start it from your terminal, not from Claude Code:

```
./scripts/autoimprove.sh
```

Tuning knobs (env vars):
- `N_PARALLEL` — number of parallel builders (default 3)
- `MAX_ITERATIONS` — hard stop (default 200)
- `LOOP_SLEEP_S` — sleep between ticks (default 5)
- `WORKER_TIMEOUT_S` — kill workers older than this (default 1800)
- `BLOCKED_RETRY_S` — strip `blocked` label from issues idle this long (default 3600)

Sandbox credentials (NOT host env vars):
- `sbx secret set -g anthropic` — Anthropic API key for all sandboxed claudes.
- `sbx secret set -g github`    — auto-registered from `gh auth token` by `./scripts/bootstrap.sh`.

Verify with `sbx secret ls`.

Pause/resume from any shell:
```
./scripts/pause.sh on    # drain and sleep
./scripts/pause.sh off   # resume
```

Stop with Ctrl+C; state is on-disk and resume-safe. The orchestrator sends SIGTERM to its in-flight children on shutdown, but `WORKER_TIMEOUT_S` still backstops anything that hangs.
