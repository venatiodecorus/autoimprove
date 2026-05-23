---
description: Start the autoimprove orchestrator daemon (host-side, not inside Claude).
allowed-tools: Bash(./scripts/autoimprove.sh:*), Read
---

The autoimprove loop is a long-running shell daemon, not a Claude-driven workflow. Start it from your terminal, not from Claude Code:

```
./scripts/autoimprove.sh
```

Tuning knobs (env vars):
- `N_PARALLEL` — number of parallel builders (default 2)
- `MAX_ITERATIONS` — hard stop (default 200)
- `LOOP_SLEEP_S` — sleep between ticks (default 5)
- `WORKER_TIMEOUT_S` — kill workers older than this (default 1800)

Required env vars:
- `GH_TOKEN` — usually `$(gh auth token)`
- `ANTHROPIC_API_KEY` — your Anthropic API key

Pause/resume from any shell:
```
./scripts/pause.sh on    # drain and sleep
./scripts/pause.sh off   # resume
```

Stop with Ctrl+C; state is on-disk and resume-safe.
