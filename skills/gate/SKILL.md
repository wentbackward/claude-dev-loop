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

## Faster red trains (opt-in)

By default the checks run one after the other and all of them run, even after a failure. Three options in
`.dev-loop.json` make a red train show sooner:

```json
"affected": {"command": "make test-affected", "summary": "passed|failed"},
"parallel": true,
"fail_fast": true
```

- `affected` (a check entry, or a plain command; heavy unless `"heavy": false`): runs first, after
  `gate_setup`, as `affected`. `DL_CHANGED_FILES` names a file listing the paths the train changes against
  the base (`git diff --name-only --no-renames`, one per line; deleted paths and both names of a rename included); the project's command picks the
  tests those paths touch. The variable is set for `gate_setup` and every check too. The list is
  `train-changed-files.txt` in the logs directory and stays there until the next train. Without
  `affected` no list is made and the variable is not set.
- `parallel`: the checks start at the same time, each in its own process group with its own log; each
  heavy one takes its own `heavy.sh` slot (and port), so with fewer free slots the rest wait as usual. The
  result lines print in config order once all have ended.
- `fail_fast`: after the first failure (affected or a check), checks not started yet print as
  `<name> skipped`, and running ones are stopped: SIGTERM to their whole process group (heavy.sh, the
  command and the servers it started in that group), SIGKILL after 10 s (`DEV_LOOP_STOP_GRACE_SECONDS`).
  They print as `<name> stopped (log: ...)`; one that had already ended with 0 prints its `rc=0`.
  heavy.sh frees its slot as soon as its command has ended. Stopping the gate itself (SIGTERM, SIGINT or
  SIGHUP) while parallel checks run stops them the same way and ends `TRAIN RED`.
  A server that daemonizes into its own session escapes the stop: keep e2e servers as children.

Every stage needs its own name, because the name is its log file: two checks with the same name, or a
check named `affected`, are a configuration error (`doctor.sh` reports them).

A stopped or skipped check is not a result: after fixing the failure, the re-run still has to pass every
check before the train is green.

## Current-state docs (opt-in)

With `docs` configured in `.dev-loop.json` (at least one aspect), the gate runs
`${CLAUDE_PLUGIN_ROOT}/scripts/docs-check.sh` for each branch right after stacking, on that branch's own
commits only (from the train ref below it, or the base, to `train-<branch>`), with its notes file. A
branch is red when it changes code a `docs.map` rule covers without changing one of that rule's docs, and
its notes' `## Docs` section has no `none: <reason>` line; or when a changed Markdown file has a relative
link that does not resolve. The gate prints `docs-check red for <branch> (...)` with the problems and ends
`TRAIN RED` before `gate_setup` and the checks. Without `docs` this stage does not run.

## Read the result (last line)

- `TRAIN GREEN` (exit 0): recorded for the merge. Run the `merge` skill with the same branches in the same
  order, right away.
- `TRAIN RED` (exit 1): read the failing check's log (the `rc=` line that is not `rc=0`; `stopped` and
  `skipped` checks did not finish). **Never merge a red train**, even if it looks like a
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
