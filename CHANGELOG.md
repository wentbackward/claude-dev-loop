# Changelog

All notable changes to this plugin. Versions follow [Semantic Versioning](https://semver.org/).

## 0.5.0 — 2026-11-05

- Branch lifecycle: branches are short-lived and the plugin removes what it made.
  - `merge-train.sh` records every merge in a ledger (`~/.dev-loop/<repo>/merged.jsonl`), deletes the
    local branch after the merge (removing its worktree first when that is clean; `merge.delete_local`),
    moves the notes file to `notes/merged/`, and deletes the train's `train-*` refs once the whole train
    merged. It names any branch it kept, and why.
  - `gate-train.sh` deletes the `train-*` refs of earlier trains (red ones, and branches no longer in a
    train), keeping a green train still waiting to merge, and records the train it is building.
  - `cleanup.sh`: classifies every local and remote branch (merged, helper, closed, stale, keep) from the
    ledger, the PR list (a replayed copy with the same changes counts as merged) and the issues; a dry run
    unless `--apply`; saves the deleted tips to a bundle and checks it before deleting; deletes only at
    the classified tip; never deletes a remote branch outside the loop (`github.feature_patterns`);
    closed and stale branches need `--include` unless `"factory": "dark"`; removes merged notes and old
    gate logs and reports after `cleanup.keep_days`, nothing else in the logs directory.
  - `doctor.sh` notes leftover train/replay refs, merged branches still local, and more than 200 local
    branches.

## 0.4.0 — 2026-11-05

- Gate options, all off by default (the gate behaves exactly as before without them):
  - `affected`: a check entry (or plain command) run first, after `gate_setup`, with `DL_CHANGED_FILES`
    naming a file that lists the paths the train changes against the base (`train-changed-files.txt` in
    the logs directory, kept until the next train). Without `affected` the list is not made.
  - `parallel`: the checks run at the same time, each in its own process group and heavy ones in their
    own `heavy.sh` slot; result lines print in config order.
  - `fail_fast`: after the first failure the remaining checks are skipped and running ones are stopped
    (SIGTERM to the process group, SIGKILL after `DEV_LOOP_STOP_GRACE_SECONDS`, default 10); they print as
    `<name> skipped` or `<name> stopped (log: ...)`; a check that had already ended with 0 keeps its
    `rc=0`.
  - A SIGTERM, SIGINT or SIGHUP to the gate in parallel mode stops the running checks the same way and
    ends `TRAIN RED`. Without `setsid` (macOS) the process groups are made with `perl`.
  - `doctor.sh` validates `parallel`, `fail_fast` and `affected`, prints them, and rejects duplicate
    check names and a check named `affected` (each name is a log file).
- `heavy.sh`: the command no longer inherits the slot lock, so a server that outlives a killed heavy
  command no longer keeps the slot; SIGTERM, SIGINT and SIGHUP release the slot once the command has
  ended.

## 0.3.0 — 2026-11-02

- `doctor` skill: `/dev-loop:doctor` runs `doctor.sh` in any project and explains the fix for each problem.

## 0.2.0 — 2026-10-31

- `models` in `.dev-loop.json`: the model per agent (e.g. `sonnet` for the code-reviewer, `haiku` for the
  verifier). The orchestrator passes it on every agent launch; `doctor.sh` prints and validates it.
- Agent lifetimes in the `dev-loop` skill: an implementer serves exactly one ticket and is replaced by a
  fresh one after 3 review rounds or a context compaction; every review round, test-engineer and verifier
  task gets a fresh agent.
- Migrating a hand-built loop: the `setup` skill finds the leftovers (project agents that shadow the
  plugin's, duplicate hooks, private gate scripts, old workflow sections, memories, stale worktrees), moves
  the project specifics into `CLAUDE.md` and `.dev-loop.json`, and archives the rest with the user's OK.
  `doctor.sh` reports shadowing agents as a problem and duplicate hooks and agent worktrees as notes.

## 0.1.0 — 2026-10-19

First release.

- Skills: `dev-loop` (the orchestrator workflow with implementer and reviewer prompt templates), `setup`
  (bootstrap a project), `gate` and `merge`.
- Agents: `implementer`, `code-reviewer`, `test-engineer`, `verifier`.
- Hooks: format-on-edit (PostToolUse), stop gate with a 5-block loop guard (Stop), role guard for identity
  mode (PreToolUse). All are no-ops without `.dev-loop.json`.
- Scripts: `heavy.sh` (machine-wide heavy-job queue with slots, memory cap, per-slot ports and stale temp
  cleanup), `gate-train.sh` (one full check run per train of ready branches), `merge-train.sh` (ordered
  squash merges verified against the gated trees), `open-pr.sh`, `paths.sh`, `doctor.sh`.
- Optional identity mode: `as-role.sh`, GitHub App and machine-user identities, `github-protect.sh`
  (rulesets, dry run by default), `setup-identities.sh` (GitHub App manifest flow), app manifests per role.
- Templates: `CLAUDE.md`, `DECISIONS.md`, `dev-loop.json`, `settings.json` deny rules.
- Tests: `tests/smoke.sh` and `tests/identity.sh` on throwaway repositories, with no network.
