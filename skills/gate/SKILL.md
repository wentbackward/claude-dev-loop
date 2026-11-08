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

## Stall timeout (opt-in)

A check that hangs (a test waiting forever, a server that never stops) keeps the train running until
someone notices. `stall_minutes` in a check entry (and in `affected` or `scenarios`) bounds the silence,
not the run time:

```json
{"name": "e2e", "command": "make e2e", "stall_minutes": 20}
```

The stage then runs in its own process group (also without `parallel`), and when its log has not grown
for that many minutes the gate stops the group as `fail_fast` does (SIGTERM, SIGKILL after the grace
period) and prints `<name> stalled: no output for <n> min (log: ...)`; the train is `TRAIN RED`, and
with `fail_fast` the checks not started are skipped. A check whose log keeps growing is never stopped,
however long it runs. A heavy check waiting in `heavy.sh` for a slot is not stalled: its clock starts
when it gets the slot. Without `stall_minutes` nothing changes; a value that is not a positive whole
number is off, with a warning. Pick it above the longest silence of a healthy run (a suite that prints
nothing until it ends needs its whole run time). `DEV_LOOP_STALL_UNIT_SECONDS` (default 60) is the length
of one such minute, for tests (anything but a positive whole number: 60, with a warning).

## The gate's own rules

The gate reads its settings from the main checkout's `.dev-loop.json`, so a branch's edits to them apply
unchecked once it merges. Right after stacking, a branch that changes its `.dev-loop.json` in any
top-level key (compared with the train ref below it as JSON with sorted keys, so a reformatting is no
change; a deleted file changes every key) is red unless its notes say why under `## Config`:
`config-check red for <branch>: it changes .dev-loop.json (<keys>) ...`, and the train ends `TRAIN RED`
before the docs stage and the checks. There is no list of harmless keys: each one runs, routes or deletes
something. The placeholder rules are those of `## Architecture` (below). `architecture` is judged only by
its own rule; a branch that adds the first `.dev-loop.json` on a base (setup) is not judged, the user
reviews the setup, and the gate prints `first .dev-loop.json on <base>, not judged: the user reviews it
(<branch>)`. A key that is not a plain name (`""`, a newline in it) is named as its JSON string; two
different files that are not one JSON document each are named `.dev-loop.json`.

## Current-state docs (opt-in)

With `docs` configured in `.dev-loop.json` (at least one aspect), the gate runs
`${CLAUDE_PLUGIN_ROOT}/scripts/docs-check.sh` for each branch right after stacking, on that branch's own
commits only (from the train ref below it, or the base, to `train-<branch>`), with its notes file. A
branch is red when it changes code a `docs.map` rule covers without changing one of that rule's docs, and
its notes' `## Docs` section has no `none: <reason>` line; or when a changed Markdown file has a relative
link that does not resolve. The gate prints `docs-check red for <branch> (...)` with the problems and ends
`TRAIN RED` before `gate_setup` and the checks. The rules come from the main checkout's `.dev-loop.json`
(as every gate setting), so a branch cannot change the rules of its own check. Without `docs` this stage
does not run.

## Architecture ratchet (opt-in)

With `architecture.check` configured in `.dev-loop.json`, the gate checks the architecture after
`gate_setup` (so the project's dependency tool can use what it installs) and before the checks:

- a branch whose own commits add entries to the baseline (`architecture.baseline`) is red unless its notes
  have an `## Architecture` section that says why: `arch-check red for <branch>: it adds baseline
  entries ...`, with the entries;
- a branch whose card header edits make violations disappear (a name added to `depends_on`, a higher
  `max_lines` or `layer`, narrower `paths`, a new composition root) is red unless its notes say why under
  `## Architecture`: `arch-check red for <branch>: its card header edits hide violations ...`, with what
  they hide (`arch-check.sh --loosened <train ref below> <train ref>`: the branch's code judged by the
  cards below it; a renamed or removed component's violations show there under its old name);
- a branch that changes the `architecture` block of its `.dev-loop.json` (the gate reads the main
  checkout's, so the change would apply unchecked once merged) is red unless its notes say why:
  `arch-check red for <branch>: it changes "architecture" in .dev-loop.json ...`, with both blocks.
  Both blocks compare as JSON with sorted keys. A placeholder (`none`, `n/a`, `TODO`, `-`,
  `not applicable`, `nope`, `no reason`, also repeated as in `none none`, followed by filler as in
  `none yet` or `not needed for now`, or by punctuation as in `none: ...` or `none (...)`) is not a
  reason, while a placeholder word, a comma and three more words (`No, the check was redundant`) is; the
  filter only stops lazy placeholders, the reviewer reads every reason;
- `${CLAUDE_PLUGIN_ROOT}/scripts/arch-check.sh HEAD` on the train's top. A violation not in the baseline,
  a broken card (also two cards with the same `paths` glob) or a failing `architecture.check` is red: each
  branch's train ref is then checked in order, and `arch-check red for <branch> (<sha>):` lists the new
  lines that branch brings. A baseline entry the top reports as fixed that occurred at the base is red
  too: `arch-check red for <branch>: it fixes baseline entries but keeps them ...` names the first branch
  that fixes it, which removes it from the baseline. Entries that were already stale at the base print as
  `arch-check: fixed ... (remove it from the baseline)` and keep the train green. When the base cannot be
  checked to judge them, the gate ends with exit 2 (`arch-check error on the base`).

Red ends `TRAIN RED` before the checks; a config error (exit 2 of `arch-check.sh`) ends the gate with
exit 2. The config comes from the main checkout; the cards and the baseline from the branch. Without
`architecture` this stage does not run.

## Holdout scenarios (opt-in)

With `scenarios` in `.dev-loop.json`, the gate adds the stage `scenarios`
(`${CLAUDE_PLUGIN_ROOT}/scripts/scenario-stage.sh`): after the checks pass (a failed check prints
`scenarios skipped`), or alongside them with `parallel` (and stopped by `fail_fast` like a check). It
starts `scenarios.run` in the gate worktree on the train's top, takes the first line it prints as the
address of the system, and runs the judge (`scenarios.judge`, default the `scenario-judge` agent on
`models.scenario-judge`) once per scenario; a scenario below `scenarios.pass`, or with invalid judge
output, is judged once more and its better run counts. With `affected`, only the scenarios whose `spec`
or `tags` occur in a changed path run, plus every required one. The script decides, not the agent: green
needs every required scenario at `>= scenarios.pass` and the mean at `>= scenarios.min_satisfaction`.

A red stage prints `scenario <id> unsatisfied (<score>, required|scored): <missing>` for each unsatisfied
scenario that is not sealed, `scenarios sealed: <n> judged, <k> unsatisfied` for the sealed share
(`scenarios.sealed`, chosen by id, never named), and `scenarios red: ...` with the mean. Send the
implementer only the `missing` line of its scenarios: never the scenario file, the judge's evidence or
anything from `train-scenario-results.jsonl`, `train-scenario-judge/` or `train-scenarios-run.log`, which
hold the evidence, the sealed ids and their results for the human: never point an implementer,
test-engineer or reviewer at the logs directory. A judge run longer than `scenarios.judge_seconds`
(default 600) is stopped and counts as invalid. Bisect a red scenario stage like a red check. Without `scenarios` this
stage does not exist and the gate's output is unchanged; a check may not be named `scenarios` then.

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
  when it was stacked; that form is not in the allow list, so it asks for permission). Never force-push it: publish it with `${CLAUDE_PLUGIN_ROOT}/scripts/repush.sh
  <branch>`, which pushes `<branch>-v2` (then `-v3`, ...) and carries the notes file over; review and
  gate that new name. The old branch is left alone until `cleanup.sh` removes it as superseded.
- Exit 2: configuration problem; the message names it (often: no `checks` in `.dev-loop.json`).

The gate runs in its own worktree (`gate_worktree`, default `<worktrees_dir>/gate` or `../<repo>-gate`), detached, so it never
touches the main checkout or the implementers' worktrees. Branches are rebased only locally as
`train-<branch>`; nothing is pushed by the gate.
