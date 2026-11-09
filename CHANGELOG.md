# Changelog

All notable changes to this plugin. Versions follow [Semantic Versioning](https://semver.org/).

## Unreleased

- Remote protection (#88): `doctor.sh` reads, read only, the base branch's protection and rules and the
  tag rulesets of a github.com remote (`gh api` GETs, lists at 100 a page, each call stopped by a watchdog
  after `DEV_LOOP_GH_TIMEOUT` seconds, default 10; after one timeout no further call): one `ok` line when
  the base branch requires a pull request (or is locked) and blocks force pushes and deletion, and active
  tag rulesets on `v*` restrict creation, update and deletion, none of it bypassable by the current gh
  login (classic protection counts only when it includes administrators; a ruleset whose bypass it
  cannot read does not count); otherwise a note naming what is
  missing and the owner step (the repository's rules settings page, or the `gh api` call). No `gh`, not
  logged in, a refusal (403, 404), an answer that is not JSON, no answer, a remote elsewhere or a
  `github.api_url` (GitHub Enterprise): a note that it could not be checked, never `MISSING`. The README's
  Permission modes section says why: the guard and the permission rules are tripwires, the remote's
  protection is the boundary. `tests/fake-gh` answers `gh api` from canned files.
- Ask-rule follow-ups (#91): `dl_perm_rules` reads a permission list that is not an array (an object or a
  string) as no rules under jq too, as python3 already did, so doctor no longer notes the values of an
  object `ask` list. An ask rule that matches only `gate_setup`, `affected` or `format` is worded for them:
  the gate and the format hook run these outside the Bash tool, so the rule stops only an agent that runs
  the command itself through the Bash tool. The DECISIONS entry of #84 names the characters of the
  short-word remark (letters, digits, `_`, `-`).
- Union logs (#95): `merge.union_files` (off by default) lists the append-only logs every branch adds to,
  as literal paths, e.g. `["CHANGELOG.md", "docs/DECISIONS.md"]`. The gate's stacking (`gate-train.sh`)
  and the merge replay (`merge-train.sh`) merge those files with the plugin's merge driver
  `scripts/union-merge.sh`. What git merges without a conflict is git's own result, as without the option
  (the driver diffs with histogram, as git's own merge does; it needs git 2.43 or later, and an older git
  makes the merge a conflict). Only conflict hunks where both sides only added lines are kept whole, the
  base side's first, then the branch's, with no lines merged inside them (unlike git's `merge=union`, which
  folds shared lines into one copy); anything else stops the train as today: a hunk where a side changed or
  deleted existing lines (an amended entry next to a new one), an add/add (both sides creating the file), a
  file with a line like a long conflict marker (32 or more `<`, `|`, `=` or `>`), or a failing driver. CRLF
  files keep their CRs. Two branches that each add an entry gate together and merge in order without a
  rebase or a `-vN` push; a base that gained an entry after the gate is a re-gate
  (exit 4), not a replay conflict. The driver and a temporary attributes file (followed by the user's own
  global attributes) are passed to that one rebase with `git -c`; no git config or `.gitattributes` is
  changed, and a merge driver the repository or the user set for a listed file wins. A conflict in any
  other file stops the train as before, and a conflict now names its files (`TRAIN conflict in: ...`,
  `MERGE conflict in: ...`). Entries with spaces, wildcards or a backslash are skipped with a warning.
- Targeted commands (#72): a new `.dev-loop.json` key `targeted` lists the command prefixes implementers
  run while working (`"go test ./"`, `"pytest tests/"`, `"make test"`, `"npm run lint"`), so targeted tests
  no longer prompt in auto mode. Each entry must start with an accepted runner form (`go test`, `go vet`,
  `gofmt`, `pytest`, `python -m pytest`, `uv run pytest`, `npm test`, `npm run <script>`, `pnpm`/`yarn`
  `test` and `run <script>`, `cargo test`, `cargo fmt`, `make <target>`, `ruff check`, `ruff format`);
  `permissions.sh` writes one `Bash(<prefix> *)` allow rule per accepted entry and refuses the rest with the
  reason (a path as the program, an interpreter, a shell, `npx`, git, a bare `make` or `npm run`, an
  argument off the safe list, shell metacharacters). The role guard then checks the parsed arguments of
  every command of those runners: each must be a plain path, package or pattern inside the project, or a
  flag on that runner's safe list (with its value); anything else (`make --ev=...`, `go test -toolexec`,
  `pytest -p`, `npm test --script-shell`, `cargo test --config`, `VAR=value`, `@file`, a second make
  target, a variable exported or set by a builtin in the same line, `builtin`/`command`/`eval`/`exec`/
  `source` anywhere in the line, `--` (except the test harness's own options after `cargo test --` and
  `go test -args`), a flag value in its own word starting with `-` or `+` (`pytest -k -p evil`), a go
  import path instead of a relative package (`go test std`), a path or `cd` outside the project, a write
  outside it, a line that is not plain) is refused with the argument named and "ask the
  owner". `doctor.sh` notes each wildcard allow rule for a runner, an interpreter or a git subcommand with
  destructive options (`make *`, `go *`, `npm run *`, `npx *`, `python3 *`, `node *`, `uv run *`,
  `pytest *`, `bash *`, `git stash *`, ...) and each refused entry. The setup skill infers `targeted` per
  toolchain. A targeted test still runs the project's own test code. Without the key nothing changes.
- Ask rules (#84): `doctor.sh` notes each ask rule of the project's `.claude/settings.json` and
  `.claude/settings.local.json`, and of the user settings (only their `permissions.ask`), that matches a
  command the loop runs or one `.dev-loop.json` configures (`fast_check`, `checks`, `affected`,
  `gate_setup`, `format`): auto mode stops for confirmation on it every time, and ask beats allow. The
  note names the file, the rule, the command and the fix (narrow it, e.g. to the paths it guards); a rule
  such as `Bash(*go * -o*)` is also said to match inside other words. The template's ask rules match
  nothing. Doctor stays read only.
- Repush notes (#82): `repush.sh` keeps a CRLF notes file CRLF (the Supersedes line and its blank line
  take CRLF when any line of the notes ends in CR, and a CR-only line before the footer counts as blank),
  and notes without a final newline (also ones ending in a bare CR) still end without one; for notes
  ending in a NUL byte no newline is added (BSD awk drops the NUL itself).
  Besides the added Supersedes line, the blank lines before the footer become one and blank lines after it
  are dropped; every other byte is kept.
  `tests/smoke.sh --section` was already matching a section id before a title; a test now covers it.
- Work dir removal (#86): `scripts/lib/workdirs.sh` refuses a work dir named by a relative path, and the
  suites make a relative `TMPDIR` absolute (symlinks resolved) before `mktemp`, so their green dir is
  still removed. With `TMPDIR=/` nothing is ever removed, on purpose (documented in the file's header).
  Its `cd`s ignore an exported `CDPATH` and take a `TMPDIR` such as `-x` as a dir name, and a suite that
  cannot make its work dir (`dl_make_work_dir`: an absolute path other than `/`) stops at once (`cannot make
  a work dir`) instead of running with paths under `/`.
- Test work dirs (#80): `tests/smoke.sh` and `tests/identity.sh` name their work dir on their first line
  (`started smoke (work dir PATH)`, a form the summary patterns `^(smoke|identity): ` do not match) and
  remove it at the end of a green run (the summary says `work dir removed`); a red run keeps it and names
  it as before, and `DEV_LOOP_KEEP_WORK=1` always keeps it. Removal (`scripts/lib/workdirs.sh`) only
  touches the suite's own `mktemp -d` dir: a real directory (not a symlink) owned by the user, directly in
  `TMPDIR` on disk (no `.` or `..` in the path, symlinks resolved), named `dev-loop-smoke.XXXXXX` or
  `dev-loop-identity.XXXXXX`. After the checks, `gate-train.sh` records the work dirs named
  (`(work dir PATH)`) in the logs of the stages that ran in this run, so also a run that crashed or was
  stopped before its summary, in `gate-work-dirs.txt` in the state directory,
  and keeps only the newest recorded one of each suite, removing the older ones under the same rule unless
  something in them changed in the last 10 minutes (`DEV_LOOP_WORK_DIR_SETTLE_MINUTES`); dirs those logs
  never named are left alone. `doctor.sh` reports TMPDIR's free space (`df -P`) and free inodes (`df -i`,
  skipped where it does not work) with the count of leftover test work dirs: a note under 10% free,
  MISSING under 2%.
- Owner steps (#73): `permissions.sh`'s dry run ends with the one command the owner runs to apply it,
  `! <plugin>/scripts/permissions.sh --apply` (the plugin's absolute path); the setup and doctor skills show
  the owner that line and wait, and never edit `.claude/settings*.json` themselves (an agent may not change
  its own permissions). `doctor.sh` reports a deny rule in the project's `.claude/settings.json` or
  `settings.local.json` that blocks a tag, a release or a tag push as MISSING, with the fix: move it to
  `ask`. The forms tested: `git tag v1.2.3`, `git tag -a|-s|-m`, `gh release create v1.2.3`,
  `git push <remote> v1.2.3|refs/tags/v1.2.3|tag v1.2.3|--tags|--follow-tags`, `git push --tags [<remote>]`
  and `git push --follow-tags` (`<remote>` the configured remote, and `origin` when it differs); a deny that
  also blocks a loop command is reported once, as blocking the loop, in either settings file. The printed
  apply line shell-quotes the path, and doctor's permission notes name it. The setup skill makes a push to
  another public repository the project depends on an owner step too.

- Smoke sections in order (#85, developer-facing): a `# <n>. ` section header in `tests/smoke.sh` numbered
  below the previous section's (two appended sections merged in the wrong order) is an error, not part of
  the section before it: `--list`, `--section` and a full run print the header and its line and exit 2
  before running anything. `make lint` runs `tests/smoke.sh --list`, so the Stop hook and the gate catch
  it. The numbered list inside section 22 is indented (`#   1. `) so it is not a header.
- Kept worktrees (#83): `cleanup.sh` lists the worktrees of merged branches (ledger or merged PR) that
  `merge-train.sh` kept for their changes, with their modified and untracked files, each `remove` or
  `keep` with the reason. `--apply --include worktrees` archives each `remove` one first (`changes.patch`
  and `staged.patch` against `HEAD`, `untracked.tar` and `manifest.txt` with a restore line in a new
  `~/.dev-loop/<repo>/archive/worktrees-<time>/<branch>/`, checked), checks that the worktree still
  matches the archive, moves it aside and checks again, then removes it and deletes its branch at the
  merged tip. Always kept: the main checkout and the gate worktree (real paths), locked worktrees, ones
  with submodules, per-worktree refs (`refs/worktree/*`, `refs/bisect/*`), another worktree inside, a
  merge, rebase, cherry-pick or revert in progress, assume-unchanged or skip-worktree files, ignored files
  that are not build output or an unreadable folder, and ones changed in the last 10 minutes (mtime or
  ctime; `DEV_LOOP_WORKTREE_SETTLE_MINUTES`). merge-train's "kept local ... has changes" line and the
  dev-loop and merge skills name that command instead of `git worktree remove --force`.
- Skipped worktrees (#93): a worktree that `cleanup.sh` skips because it does not match its listing (it has
  another branch checked out, as when a path with a newline is cut and names another folder, or its real
  path is not its top folder) gets a `note: skipped worktree <path> (<branch>): <reason>` line on stderr,
  in the dry run and with `--apply`, instead of disappearing silently. What is listed, kept and removed
  does not change.
- Stop gate (#74): an untracked file blocks the stop only when its mtime is not older than the session's start (the
  first timestamp in the session's transcript, else the hook's first run in the session, kept as a marker
  in the git directory's `dev-loop-sessions/`); older untracked files (an owner's notes, another session's
  file) are listed once per session as a note and do not block. Modified tracked files still block, a hook
  input without a session id blocks on every untracked file as before, and
  `stop_gate.require_clean_tree: false` still turns the tree check off.
- Script help (#75): `-h` / `--help` as the first argument of any script under `scripts/` prints its
  usage (the `# Usage:` block of its header) and exits 0, touching nothing; `gate-train.sh --help` no
  longer takes `--help` as a branch. `gate-train.sh`, `merge-train.sh`, `repush.sh` and `open-pr.sh`
  refuse any other argument starting with `-` (exit 2, with the usage) instead of looking for a branch
  of that name.
- Worktrees dir (#70): a new `.dev-loop.json` key `worktrees_dir` puts the implementer worktrees in
  `<dir>/<n>` and the gate in `<dir>/gate` (an explicit `gate_worktree` still wins); without it nothing
  changes (`../<repo>-<n>`, `../<repo>-gate`). `paths.sh worktree <n>` prints the worktree path in either
  layout and `paths.sh worktrees` the directory; the dev-loop skill's launch step uses it.
  `permissions.sh --apply` adds the absolute notes directory and, with the key, the worktrees dir (and a
  gate outside it) to `permissions.additionalDirectories` in `.claude/settings.local.json`, so auto mode
  and acceptEdits edit there without a prompt; it never adds the project's parent. `doctor.sh` reports an
  uncovered notes dir, worktrees dir or sibling loop worktrees as MISSING and notes old-layout worktrees
  (never moved). The setup skill writes `"worktrees_dir": "../<repo>-worktrees"` for new projects.
- Review follow-ups (#76): the stop gate clamps the session start to the current time, so a transcript
  whose first timestamp is in the future no longer lets every untracked file through. A bare `--` given to
  `gate-train.sh`, `merge-train.sh`, `repush.sh` or `open-pr.sh` is refused with a message that branch
  names never start with `-`. `repush.sh` puts its `Supersedes` line before the notes' closing
  `Generated with` footer, so the PR body still ends with it. `tests/smoke.sh --section <id or name>`
  (repeatable) runs the shared setup, that section and the earlier sections it needs, in a new work dir;
  `--list` lists the sections. The implementer and code-reviewer briefs point at such selectors instead of
  ad-hoc runners. Smoke sections 11 and 20 write and remove `.claude/` files only by absolute paths in
  their throwaway projects.
- Git guard (#71): the role guard hook now checks git commands in every project with `.dev-loop.json`
  (not only with scenarios or identities); `"guard": false` turns it off. It fails closed: a Bash command
  that names git (any case, `GIT_*`, a glob that may match git) passes only as a plain command line:
  literal words joined by `&&`, `||`, `;`, `|` or newlines, plain redirections and here-documents that
  expand nothing. `$` and backtick expansions, braces, subshells, functions, compound commands, `alias`,
  `eval`, `sudo`, `xargs`, shells given a command string, `find -exec`, `rg --pre`, `man -H`, and git text
  handed to an unknown program are refused with "write it plainly". On plain lines it follows `cd`,
  `pushd`, `popd`, `env -C` and `git -C` (a `cd` that may fail keeps the old directory in the check),
  skips assignments and wrappers (`env`, `nice`, `timeout`, `stdbuf`, `time`, `nohup`, `as-role.sh`,
  `heavy.sh`), expands bundled short flags and resolves long-option prefixes for `fetch`, `pull`,
  `rebase`, `diff`, `log`, `show`, `worktree remove` and `push`. It refuses `-c`/`--config-env`,
  `--exec-path=`, `GIT_*`/`PATH`/`HOME` assignments, `git config` writes, `submodule foreach`,
  `bisect run`, `filter-branch`, `--upload-pack`, `--receive-pack`, `rebase --exec`/`-x`, a rebase of the
  base branch, `--output`, `worktree remove --force`, and a push that forces, deletes, tags (`tag <name>`
  included), pushes everything (a glob refspec included), has more than 50 refspecs, runs with
  `--git-dir`/`--work-tree`, or whose source or destination is the base branch
  (`git push -u <remote> HEAD` from a checkout of the base included), with the reason and "ask the
  owner". Text checks run before any git process, and git is asked once per directory. A crash of the
  guard on a command naming git refuses it, and so does a Bash hook event it cannot read (truncated, not
  UTF-8) whose text names git. A differential test (`tests/guard-diff.py`, in `make check`)
  holds the guard to bash's reading of a fixed corpus and seeded random shell texts. The identity and
  scenario checks split commands on newlines too, and refuse a command naming git that they cannot parse.
  Commit messages go in as `git commit -F - <<'EOF'` (the implementer and test-engineer briefs say so).
  The README calls the guard a tripwire (the remote's branch and tag protection is the boundary) and lists
  its limits; the setup skill has the owner run `! git worktree remove --force --force <path>`. The
  template's `git rebase *` allow becomes `git rebase --continue`, `--abort` and `--skip`, and
  `permissions.sh` adds the exact `git rebase <remote>/<base>`; any other rebase asks.

## 0.8.2 — 2026-11-08

- Status verdict (#67): `status.sh` no longer trusts a stale `waiting` event: a wait that names branches
  (`waiting detail="gate feat/12-x"`) is over, with the gate not running, once a gate result of a train
  with one of them or a merge of one came after it (from the event log or the ledger); the orchestrator
  line then says `the wait is over: ...`. `working` now needs something in flight: a loop worktree with
  unmerged work, or an agent recorded with `agent-started` (or `watchdog-resumed`) and not yet
  `agent-reported`, merged (a `merged` event or the ledger) or ended; a recent event on its own is `idle`. A new `event.sh idle` event ends
  every agent in flight and leaves loop worktrees unchanged since out of the verdict; the dev-loop skill
  records it at the end of a session or after a release, and `agent-reported` when an agent reports.
  `--json` adds `verdict.wait_ended` and `verdict.agents`; `stalled` is unchanged.

## 0.8.1 — 2026-11-08

- Marketplace pin (#64): the README installs from a release tag
  (`/plugin marketplace add wentbackward/claude-dev-loop@v0.8.0`), explains the error Claude Code gives
  when an `extraKnownMarketplaces` entry in the settings lists another source (add it from the entry's
  source, or change the entry's `ref`), and how to move to a new release (change the `ref`, add from the
  new tag, `claude plugin update dev-loop@claude-dev-loop`). `doctor.sh` prints the marketplace source and
  pin it finds in the user, managed and project settings, the marketplace Claude Code configured and the
  installed version (read only, nothing else from those files). An entry that does not match the configured
  marketplace is MISSING with the exact `claude plugin marketplace add <source>`; an entry not added yet and
  a pin older than the installed plugin are notes. Without any entry nothing new is printed.
  `DEV_LOOP_CLAUDE_DIR` and `DEV_LOOP_MANAGED_SETTINGS` point it at other files.

## 0.8.0 — 2026-11-07

- Merge without a force push (#57): `merge-train.sh` no longer force-pushes the replayed branch. A branch
  that already contains the base with the gated tree merges as it is; a branch behind the base gets a merge
  commit with the gated tree (parents: the gated head and the base), pushed as a plain fast-forward of the
  branch, so the PR, its review thread and its number stay, and an origin that refuses non-fast-forward
  pushes (or a ruleset that forbids force pushes) merges green. The squash of that head is the gated tree.
  The train file keeps the gated head (a fifth field) once the branch moved, so a re-run after exit 9 or 7
  merges the head already pushed without another push (the merge commit is recorded before its push, a
  sixth field, so a run that stopped right after the push resumes too), and the ledger and the
  local-branch cleanup use the gated head. Exit codes are unchanged; exit 9's advice now says how to confirm the merge commit.
- Stall watchdog (#56): `stall_minutes` in a gate check entry (and in `affected` and `scenarios`), off by
  default, runs that stage in its own process group and stops it (SIGTERM, SIGKILL after the grace
  period, as `fail_fast` does) when its log has not grown for that many minutes; it prints `<name>
  stalled: no output for <n> min (log: ...)`, records `stage-ended` with `result: stalled`, the train is
  red, and with `fail_fast` the checks not started are skipped. A stage whose log grows is never stopped,
  and a heavy stage queued in `heavy.sh` for a slot is not stalled (its clock starts with the slot). A
  value that is not a positive whole number is off, with a warning. `DEV_LOOP_STALL_UNIT_SECONDS`
  (default 60) shortens the minute for tests. The `dev-loop` skill has a heartbeat (section 2a): while
  the orchestrator only waits it records `waiting` with `event.sh` and schedules a fallback wake-up in
  `watchdog.wake_minutes` (default 25); on waking it runs `status.sh --json`, waits again when something
  moved, and on `stalled` confirms (CPU of the stage's processes, agent worktree changes) before it stops
  a hung loop command (only the gate's own stage processes) or resumes or replaces an agent per section
  3a, recording what it did. `"watchdog": false` turns the heartbeat off.
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
  file with a ``Supersedes `<branch>` at <sha>`` line recording the old branch's local and remote tips,
  refuses a dirty worktree and the base branch, and never deletes or moves the old branch. `open-pr.sh`
  (also from `merge-train.sh`) closes the open PRs of the earlier versions a `-vN` branch supersedes
  (named on a `Supersedes` line of its notes, or whose head it contains), with a comment pointing to the
  new PR. `cleanup.sh` has a new class, `superseded`: a branch whose later version merged (ledger or
  merged PR) and recorded its current tip is deleted with `--apply` like a merged one, archived first,
  and its notes move to `notes/merged/`. Without a record, or after new commits, it is kept until the
  user deletes it by hand (`--include` does not touch it); a branch whose later version has not merged
  is never touched. The dev-loop, gate and merge skills and the implementer brief say to re-push with
  the helper and never to force-push.
- Status (#55): `scripts/status.sh` and the `/dev-loop:status` skill show what the loop is doing without
  waking its session, read-only: the gate (pid alive, train, each running stage with its elapsed time,
  log and seconds since the log last grew), the heavy slots in use and their holders, each loop worktree
  (ticket, commit and notes age, pushed, ahead/behind), the last merge, the open tickets (`--no-gh`
  skips `gh`) and the orchestrator's last event, then a verdict: `idle`, `working`, `waiting on <what>
  (output <n>s ago)`, `waiting on heavy slot (queued)` (the gate's own job waits for a heavy slot;
  `heavy.sh` records the gate's pid as `gate_pid`) or `possibly stalled: no event or output for <n> min`
  (new key `watchdog.stall_minutes`, default 30; raise it for stages that print nothing for longer). `--json` for machines. A new event log
  `~/.dev-loop/<repo>/events.jsonl` (`paths.sh events`): `gate-train.sh`, `merge-train.sh` and `heavy.sh`
  append one JSON line per step, the orchestrator through the new `scripts/event.sh`; rotated at 1 MiB
  to `events.jsonl.1`; a failed write is ignored. `permissions.sh` allows `status.sh` and `event.sh` with
  the other plugin scripts. Nothing else changes without new config.
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
