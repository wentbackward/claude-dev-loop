# Changelog

All notable changes to this plugin. Versions follow [Semantic Versioning](https://semver.org/).

## Unreleased

- Permissions (#54): `scripts/permissions.sh` merges the rules the loop needs into the project's settings,
  only adding (a dry run by default, `--apply` writes): `templates/settings.json` gains an allow list (the
  read-only git commands, `git fetch`, `git worktree`, `git rebase`, `git add`, `git commit`, the `gh issue`
  and `gh pr` reads and writes the loop uses) and ask rules (`git tag`, `gh release`, tag, `refs/`, mirror,
  all and delete pushes, `git worktree remove --force` or `-f`), and its deny rules now catch force pushes,
  `gh repo delete` and `gh pr merge --admin` anywhere in a command, also after `git -C` or `git -c`. The
  script adds the one exact push the loop makes (`git push -u <remote> HEAD`; the implementer brief and the
  `dev-loop` skill now push in this form), prompts for a push naming the base branch or deleting a loop
  branch, and one exact rule per `fast_check` and `checks` command to `.claude/settings.json`; and the
  plugin's scripts at this machine's plugin path (version as a wildcard; `heavy.sh` and `as-role.sh` only
  for the loop's own uses) to `.claude/settings.local.json`, which it adds to `.gitignore`. `doctor.sh` reads the `permissions` of
  those two project files only: a deny rule that blocks a loop command is `MISSING`, a missing or stale
  allow list is a note, complete rules print nothing, and without `.claude/settings.json` it prints one
  note. The setup skill's step 4 is now "Permissions"; the README has a "Permission modes" section.
- Never force-push (#53): a branch rebased after it was pushed (a gate rebase conflict, a merge replay
  conflict, a stacked branch whose lower branch merged) is published under a new name with the new
  `scripts/repush.sh [<branch>]`: it picks the next free `<branch>-v2` (`-v3`, ...), pushes it with a
  plain `git push -u` (as the implementer in identity mode), switches the worktree to it, copies the notes
  file with a `Supersedes` line, refuses a dirty worktree and the base branch, and never deletes or moves
  the old branch. `open-pr.sh` (also from `merge-train.sh`) closes the open PRs of the earlier versions a `-vN`
  branch supersedes (named on a `Supersedes` line of its notes, or whose head it contains), with a
  comment pointing to the new PR. `cleanup.sh` has a new class, `superseded`: a
  branch whose later version merged (ledger or merged PR) is deleted with `--apply` like a merged one,
  archived first, and its notes move to `notes/merged/`; a branch whose later version has not merged is
  never touched. The dev-loop, gate and merge skills and the implementer brief say to re-push with the
  helper and never to force-push.
- Docs maintenance (#47; only with `docs` configured): on the doc audit's cadence, right after the audit,
  the orchestrator opens one `docs: maintenance` ticket from `doctor.sh`'s docs notes and the auditor's
  new maintenance list (planned rows to move or remove, journals over budget, finished specs, at most one
  oversized doc to split per ticket), implemented, reviewed and gated like any ticket, skipped when empty.
  Stale planned tickets are closed as not planned with a comment, on the user's OK in collaborative mode,
  without asking in dark mode. The `doc-auditor` lists housekeeping in its report instead of opening a
  ticket for each; real drift still gets one ticket each, and the auditor stays read-only.
- Docs adoption (#46): without `docs`, `doctor.sh` prints one note, `current-state docs off: no docs
  check, no doc audit, no planned list; adopt them with the setup skill's step 3b` (a note, `doctor:
  ready` unchanged). Setup step 3b gains a gradual adoption path for an existing project with large
  hand-written docs: Features only with an empty `map` first, split a mixed built and planned file,
  archive finished specs and compact the journal once (`docs-archive.sh`), add `map` rules one aspect at
  a time, leave oversized docs to docs maintenance tickets. The planned-list rows follow CommonMark code
  fences (a backtick fence line inside a `~~~` block no longer ends it), the same rule as `docs-check.sh`.
- The scenario stage's red line (`scenarios red: <n> judged, <k> required unsatisfied, ...`) counts only
  the required scenarios that are not sealed; a sealed required failure is only in the `scenarios sealed`
  count and still makes the train red. The README and `docs/DECISIONS.md` note that a daemon started by
  `scenarios.run` in a session of its own (`setsid`) escapes the stage's stop (#40).
- Planned-list hygiene (#45): with `docs.planned`, `doctor.sh` reads each planned row's ticket with one
  `gh issue list` call and notes rows whose ticket closed (move it to Features, or remove the row when not
  planned), rows whose ticket does not exist and rows with no ticket number. A new key
  `docs.planned_max_days` (off by default) also notes rows whose ticket is open longer than that with no
  loop branch. Notes only; without `gh` access one note says the rows were not checked.
- Journal compaction and spec archiving (#44; only with `docs` configured): `scripts/docs-archive.sh`, a
  dry run by default (`--apply` writes). `journal [<file>] [--keep <lines>]` moves the oldest whole entries
  of a journal over `docs.max_lines` (new key `docs.journals`, default `["docs/DECISIONS.md"]`), verbatim,
  to a new `docs/archive/<NAME>-<first date>--<last date>.md`, keeping the preamble and a
  `## Standing decisions` section in place; it never edits an archive file and writes nothing unless the
  live file with the archive put back equals the original byte for byte. `spec <file>` moves a finished
  spec to `docs/archive/specs/` and leaves a one-line pointer (`--no-pointer`), refuses a file a docs
  aspect or `docs.prd` names (`--force`), and reports links to it. Moved text whose relative links would
  break is refused, the link named. `doctor.sh` notes a journal over `docs.max_lines`;
  `templates/DECISIONS.md` has a `## Standing decisions` section. A journal must be newest last (a
  newest-first one is refused) and its newest entry always stays.
- `docs-check.sh` follows CommonMark code fences: a backtick fence line inside a `~~~` block no longer ends it, and a
  line indented 4 spaces is not a fence; its link helpers moved to `scripts/lib/docs.sh`, shared with
  `docs-archive.sh` (#44).

## 0.7.0 — 2026-11-05

- The tool that reads NUL-separated file names (jq, python3 or bash) is chosen once per process tree,
  not again in every pipeline and command substitution. Without jq or python3, the line form
  (`dl_z_lines`) drops the same names with control characters as the JSON form (`dl_json_list_z`) (#27).
- The gate's config-change check (#25): the gate prints `first .dev-loop.json on <base>, not judged: the
  user reviews it (<branch>)` for a setup branch instead of saying nothing, and the reviewer reads such a
  first config with `deploy` or `format` commands line by line. A key named `""` is compared too, and a key
  that is not a plain name (a newline in it) is named as its JSON string. Two different invalid files are
  flagged (raw text compared when neither side parses), and jq and python3 agree that trailing garbage and
  concatenated documents are unparseable.
- A holdout scenario store (#30, part 1 of #2; off without `scenarios` in `.dev-loop.json`):
  `scenarios.dir` (default `~/.dev-loop/<repo>/scenarios`), `run`, `pass`, `min_satisfaction`, `sealed`;
  one Markdown file per scenario with front matter (`id`, `title`, `spec`, `tags`, `required`) and an
  example in `templates/scenario.md`. `scripts/lib/scenarios.sh` lists, reads and validates the files;
  `paths.sh scenarios` prints the store; `doctor.sh` prints the store and the counts and reports each
  invalid file.
- Scenario isolation (#31, part 2 of #2): with `scenarios` configured, identity mode or not, the role
  guard refuses `Read`, `Grep`, `Glob`, `Edit`, `Write` and Bash calls by the `implementer`,
  `test-engineer` and `code-reviewer` agents that name a path inside `scenarios.dir` (absolute, `~`,
  `$HOME`, relative, through a symlink or a glob); the main session, `scenario-judge` and `scenario-writer`
  are allowed. Best effort; the README explains the limits and that in identity mode the coding apps get no
  access to a scenarios repository. `templates/settings.json` has no deny rule for the store (it would block
  the judge).
- A `scenario-writer` agent (#33, part 4 of #2): with `scenarios` configured, the orchestrator runs it at
  ticket creation; it writes or updates scenarios in the store from the spec and the ticket, never from
  the code, and writes only inside the store. The `dev-loop` skill's new section 1b lists the new and
  changed scenarios in the issue (titles only), sends a red scenario to the implementer as the missing
  behaviour only, and never puts the store path in an implementer, test-engineer or code-reviewer
  prompt. `models.scenario-writer`; `doctor.sh` lists it in the models line when `scenarios` is on or the
  model is set.
- The scenario judge and the gate's scenario stage (#32, part 3 of #2; off without `scenarios`): after
  the checks pass (or alongside them with `parallel`), `gate-train.sh` runs `scripts/scenario-stage.sh`,
  which starts `scenarios.run`, judges each scenario with `scenarios.judge` (default: the new read-only
  `scenario-judge` agent on `models.scenario-judge`), rejudges a failure once (a judge run
  longer than `scenarios.judge_seconds`, default 600, is stopped and counts as invalid) and is green only with
  every required scenario at `>= pass` and the mean at `>= min_satisfaction`. A red train names each
  unsatisfied scenario with the judge's `missing` line only; the `scenarios.sealed` share is only
  counted. With `affected`, only scenarios whose `spec` or `tags` match a changed path run, plus the
  required ones. Results are recorded in `train-scenario-results.jsonl`; `doctor.sh` lists
  `models.scenario-judge` (with `scenarios`, or when it is set) and reserves the check name `scenarios`.
  `dl_scenario_sealed <file|id>` tells which scenarios are sealed, and the `dev-loop` skill lists sealed
  scenarios on the issue only as a count.
- The factory preset (#34, the last part of #2): `"factory": "collaborative"` (the default) or `"dark"`.
  Dark turns `scenarios` on by default; an explicit option wins, and `"scenarios": false` or `null` now
  keeps scenarios off in every mode (before, any value turned them on). A dark factory whose store has no
  valid required scenario is `MISSING factory dark` in `doctor.sh` and `TRAIN RED` at the gate (`scenarios
  red: factory dark needs ...`). `doctor.sh` prints the mode and marks the scenarios setting `(preset)`,
  `(explicit)` or `(default)`, and reports any other mode. The `dev-loop` skill keeps one list of stop
  conditions for both modes and a "Factory mode" section (section 8a); the `setup` skill asks for the mode
  once and has a go-dark step (3d). The role guard hook applies the same rule, so a dark factory hides
  the default store from the coding agents. Without `factory`, nothing changes.

## 0.6.0 — 2026-11-05

- `gate-train.sh` and `merge-train.sh` merge the setup branch with the main checkout on the base: when the
  main checkout has no `.dev-loop.json` yet, they read it from the branch (merge-train: the first branch of
  the recorded train) and say where it came from (#8).
- The branch-config fallback of #8 fetches the branch before reading its config (a stale
  `<remote>/<branch>` is no longer read), stops with `the config of <ref> names remote <remote>, but
  <remote>/<branch> is missing` instead of `no config at`, and names a local-only branch as
  `refs/heads/<branch>` (#9).
- `doctor.sh` accepts the project instructions at `.claude/CLAUDE.md` as well as `CLAUDE.md`.
- Component cards and an architecture ratchet (off without `architecture.check` in `.dev-loop.json`):
  - `architecture` config: `cards` (default `docs/architecture/`), `check` (the project's command printing
    `<from> <to>` edges, paths or component names), `baseline` (default `docs/architecture/baseline.txt`)
    and `budget` (default `max_lines` per component).
  - A component card per component (`templates/COMPONENT.md`): `component`, `layer`, `kind` (`component`
    or `composition-root`), `paths`, `depends_on`, `max_lines`.
  - `scripts/arch-check.sh <ref>`: upward and undeclared dependencies, cycles and components over budget
    as stable lines, new, known or fixed against the baseline; files in no component as notes;
    `--baseline` writes the sorted baseline.
  - `gate-train.sh` runs it on the train's top after `gate_setup` and before the checks, names the branch
    that brings a new violation and ends `TRAIN RED`; a branch that adds baseline entries needs a reason
    under `## Architecture` in its notes.
  - `doctor.sh` prints the component map with sizes against budgets, reports broken cards, and notes files
    in no component and the baseline size.
  - The setup, dev-loop, gate and doctor skills and the implementer and reviewer agents carry the rules.
- The architecture ratchet can't be loosened quietly (#17): a branch whose card header edits make
  violations disappear (`depends_on`, `max_lines`, `layer`, `paths`, a composition root) needs a reason
  under `## Architecture`, as baseline growth does (`arch-check.sh --loosened <from> <ref>` lists what the
  edits hide), and so does a change to `architecture` in its `.dev-loop.json`; a baseline entry that occurred at the base and a branch fixes must be removed by that
  branch, else the gate is red; placeholders (`none`, `n/a`, `TODO`, `-`, also as `none (...)`) are not reasons; two cards with
  the same `paths` glob are a broken card.
- The gate's own rules need a reason (#22): a branch that changes its `.dev-loop.json` in any key but
  `architecture` (which keeps its `## Architecture` rule) needs a reason under `## Config` in its notes,
  else the gate names the branch and the changed keys and ends `TRAIN RED` right after stacking; the
  first `.dev-loop.json` on a base (setup) is not judged. The file (and `architecture`) compares as JSON
  with sorted keys, so a reformatting is no change. The placeholder filter also stops filler and repeats
  (`none yet`, `not needed for now`, `nope`, `no reason`, `none none`, `-- none`), and accepts a
  placeholder word, a comma and three more words (`No, the check was redundant`). The reviewer reads every
  `## Architecture` and `## Config` reason, and loosening the gate's rules needs the user's OK in
  collaborative mode.
- Current-state docs, kept true by every merge (off without `docs` in `.dev-loop.json`):
  - `docs` config: `aspects` (name to a file or folder), `planned`, `map` rules
    `{"paths": [globs], "docs": [aspects]}` (`*` also matches `/`) and `max_lines` (default 1000).
  - `scripts/docs-check.sh <from> <to> [<notes file>]`: red for mapped code changed without one of its
    docs or a `none: <reason>` in the notes' `## Docs` section, and for broken relative links in changed
    Markdown files.
  - `gate-train.sh` runs it per branch on the branch's own commits right after stacking, and ends
    `TRAIN RED` naming the branch before `gate_setup` and the checks.
  - `doctor.sh` prints the docs config, reports missing aspect paths, and notes files over `max_lines`
    and map rules that match no tracked file.
  - The implementer writes a required `## Docs` notes section; the reviewer makes a false or missing doc
    change a must fix; the dev-loop and setup skills and the templates (`templates/FEATURES.md`, the
    "Documentation" section of `templates/CLAUDE.md`, an empty `docs` block in
    `templates/dev-loop.json`) carry the rules.
- `merge-train.sh` removes merged worktrees that hold self-ignoring caches (`.ruff_cache`, `.pytest_cache`
  with their own `.gitignore`): a file inside a cache or dependency folder (`merge.rebuildable_caches`)
  counts as build output unless it is a secret or data file; output folders (`build`, `out`) still count
  only as a whole. Secret and data names match in any case and include `*.pfx`, `id_rsa*`, `id_ed25519*`,
  `id_ecdsa*`, `id_dsa*`, `credentials*`, `secrets*` and `*.sqlite-*` (#11).
- `merge-train.sh` no longer keeps a merged worktree for vendored files named like secrets
  (`node_modules/pkg/credentials.js`, `.venv/lib/.../secrets.py`): inside a dependency or cache folder
  (`merge.rebuildable_caches`) the scan looks for the strong patterns only (`.env`, `.env.*`, `*.env`,
  `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.sqlite`, `*.sqlite3`, `*.sqlite-*`, `*.db`), so
  `node_modules/.env` still keeps its worktree. The broad names (`credentials*`, `secrets*`, `id_*`) still
  count for an entry git lists one by one and inside output folders (`build/credentials.json`) (#15).
- The slice loop and a doc-auditor (off without `docs` in `.dev-loop.json`) (#21):
  - `docs.prd`: the PRD or spec files (a path or a list); `docs.audit_every`: the doc-audit cadence in
    merges (default 10). `doctor.sh` prints the PRD files (MISSING when one is absent) and the merges since
    the last audit, from the merge ledger and the audit marker (`paths.sh doc-audit`,
    `~/.dev-loop/<repo>/doc-audit.txt`), and notes `doc audit due` at the cadence.
  - The `dev-loop` skill keeps the gap between the PRD and Features in the planned list and slices it as it
    goes: one component and one implementer's context per ticket, the Features change first for a
    feature, `Docs:` and `Components:` lines in each ticket, and the planned entry moved to Features as the
    ticket merges. It runs the doc audit on cadence and before a release, and checks the planned list and
    Features against the merged tickets before a release.
  - A read-only `doc-auditor` agent compares the current-state docs and component cards with the code and
    the running system and opens one ticket per drift; `models.doc-auditor` sets its model (doctor checks
    it) and the role guard lets it act as the tester.
- Merge evidence and an `architect` agent that reads it (#19):
  - Each merge-ledger line also records the `files` the merge changed, their `components` through the
    cards (empty without `architecture`), the `lines` added and deleted, the `review_rounds` (a `Review
    rounds: <n>` line in the notes file, else one plus a `## Review fixes` heading per round) and the
    `ticket`; older lines stay valid.
  - `scripts/arch-evidence.sh [--since <n> | <time>]`, deterministic and read-only: a summary table, then
    one stable line per finding for size (budget, growth), scatter, co-change, hotspots, cycle size,
    misplaced shared code, fan-out outside composition roots, loop friction (review rounds, reopened
    tickets) and run time vs code; exit 1 when a signal is over its threshold. Thresholds:
    `architecture.cadence` (20), `scatter` (3), `growth` (500), `co_change` (75) and `co_change_min` (3),
    `hotspot` (5), `cycle` (3), `fan_out` (5), `review_rounds` (3).
  - Cards may mark run-time components with `kind: service`, `job` or `store`.
  - A read-only `architect` agent (`models.architect`) proposes refactoring tickets and extraction-ladder
    steps; the last step (a separate repository or service) needs the user's go in every mode. The
    `dev-loop` skill runs the evidence at the start of a session and every `architecture.cadence` merges
    and starts the architect on a signal or the cadence; `paths.sh architect` names its marker; `doctor.sh`
    prints the merges since its last run and the signals over their thresholds, and checks the model and
    the thresholds; the role guard lets it act as the tester.

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
