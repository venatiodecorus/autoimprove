---
description: First-time project setup — initializes git, creates the GitHub repo, sets up labels.
allowed-tools: Bash(./scripts/bootstrap.sh:*), Read
---

Run the bootstrap script:

```
./scripts/bootstrap.sh $ARGUMENTS
```

Optional arg: a custom repo name (defaults to the current directory's basename).

Idempotent — safe to re-run if something didn't take.
