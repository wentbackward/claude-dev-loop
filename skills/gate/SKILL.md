---
name: gate
description: Run the batch gate - stack one or more approved branches on the latest base in merge order and run the project's full checks once on the stack, with heavy checks queued machine-wide under a memory cap. Use when branches are reviewed and approved and ready to merge.
---

# Batch gate

One full check run proves a whole train of ready branches, so N branches cost one run instead of 2N, and
the machine is never loaded with parallel full suites.

## Run it

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/gate-train.sh <branch-1> <branch-2> ...
```

- Branches in merge order: dependencies first, a stacked branch right after the branch it stacks on.
- Only branches whose last review verdict is APPROVE, pushed to the remote.
- Run it in the background (`run_in_background: true`); it takes as long as the full checks. Keep working
  on other tickets meanwhile; you are notified when it ends.
- The checks are `checks` in `.dev-loop.json`. Heavy ones (the default) run through `heavy.sh`: they wait
  for one of `heavy.slots` machine-wide slots, run under `heavy.memory_max`, and get their own port in
  `heavy.port_env`. Logs: `${CLAUDE_PLUGIN_ROOT}/scripts/paths.sh logs`.

## Read the result (last line)

- `TRAIN GREEN` (exit 0): recorded for the merge. Run the `merge` skill with the same branches in the same
  order, right away.
- `TRAIN RED` (exit 1): read the failing check's log. **Never merge a red train**, even if it looks like a
  flake. Re-run once. If it is still red, bisect: gate the first half, then the second, until the culprit
  branch is found; send the failing output to its implementer; gate and merge the rest without it. Open an
  issue for a test that is genuinely flaky.
- `TRAIN rebase conflict at <branch>` (exit 3): drop that branch, gate the others, and have its implementer
  rebase it onto the new base after they merge (`git rebase --onto <remote>/<base> <old base> <branch>`
  when it was stacked).
- Exit 2: configuration problem; the message names it (often: no `checks` in `.dev-loop.json`).

The gate runs in its own worktree (`gate_worktree`, default `../<repo>-gate`), detached, so it never
touches the main checkout or the implementers' worktrees. Branches are rebased only locally as
`train-<branch>`; nothing is pushed by the gate.
