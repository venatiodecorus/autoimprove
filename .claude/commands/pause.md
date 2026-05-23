---
description: Pause or resume the autoimprove loop without killing it.
allowed-tools: Bash(./scripts/pause.sh:*)
argument-hint: [on|off|status]
---

Pause or resume the running autoimprove daemon. Status defaults if no arg.

```
./scripts/pause.sh $ARGUMENTS
```

While paused, the orchestrator drains any in-flight work (so nothing is left half-merged), then sleeps until you `pause.sh off`. Spec edits made during a pause are picked up automatically on resume — the spec-hash check invalidates prior audit verdicts so the loop can't accidentally terminate just after you extended scope.
