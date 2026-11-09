# dev-loop: an autonomous multi-agent development loop for Claude Code

`dev-loop` is a Claude Code plugin that runs a project the way a small, disciplined team would. The main
session is the orchestrator. It turns the spec into tickets and hands each ticket to an implementer agent,
which works test-first in its own git worktree. An independent code-reviewer agent checks every branch
until it approves. Approved branches are then proven together by one batched full-check run (the gate),
merged in order with one squash merge per ticket, run for real and verified.

It came out of months of running real projects this way. The rules it encodes are the ones that held up:
the reviewer is independent of the implementer, a red gate is never merged, the full suite runs once per
batch instead of once per branch, and heavy jobs queue so the machine never runs out of memory. Decisions
the spec leaves open go into a log, and the user hears results in plain language.

## Install

Pin the marketplace to a release tag (the latest is `v0.8.2`):

```text
/plugin marketplace add wentbackward/claude-dev-loop@v0.8.2
/plugin install dev-loop@claude-dev-loop
```

From a shell, the same is `claude plugin marketplace add wentbackward/claude-dev-loop@v0.8.2`, then
`claude plugin install dev-loop@claude-dev-loop` (add `--scope project` to enable it for one project).

**Settings that already name the marketplace.** When the user, managed or project settings declare it in
`extraKnownMarketplaces` (for example settings copied from another machine), Claude Code accepts
`marketplace add` only from exactly the source that entry lists, including its `ref`. Any other source
fails with:

```text
Error: Cannot add marketplace "claude-dev-loop": its source doesn't match its extraKnownMarketplaces entry in user or managed settings; add it from the source that entry lists, or change the entry.
```

The fix is to add it from the entry's source: an entry with `"repo": "wentbackward/claude-dev-loop"` and
`"ref": "v0.8.2"` is added with `claude plugin marketplace add wentbackward/claude-dev-loop@v0.8.2`; or
change the entry's `"ref"` first and add it from that ref. `/dev-loop:doctor` prints the entries it finds
and the exact command when they do not match the marketplace Claude Code configured.

**Moving to a new release.** Change the `"ref"` in the settings entry to the new tag (when there is one),
add the marketplace from the new tag (`claude plugin marketplace add wentbackward/claude-dev-loop@<new
tag>`), then run `claude plugin update dev-loop@claude-dev-loop`.

Requirements: `git` (2.31 or later), `gh` (logged in), `bash`, and `jq` or `python3`. Optional: `flock`
and a systemd user session (`systemd-run --user`), which give the heavy-job queue its locks and memory cap.
`setup-identities.sh` also needs `openssl` and `curl`.

## Set up a project

In the project, ask Claude to run the **setup** skill (`/dev-loop:setup`). It looks at the repository
first: language, toolchain, Makefile, CI, spec. Then it asks only for what it could not find out. It writes:

- `CLAUDE.md` from the template: operating mode, stop conditions, workflow, engineering, test and safety
  rules;
- `docs/DECISIONS.md`, the decisions log (date, decision, reason, alternatives);
- `.dev-loop.json`, the project config (see below);
- permission rules in `.claude/settings.json`: what the loop runs is allowed, releases and tags ask, force
  pushes, `sudo`, `.env` and role credentials are denied (see Permission modes);
- Makefile targets that are missing (`fmt`, `fmt-check`, `lint`, `typecheck`, `test`, `cov`, `check`,
  `e2e`).

`/dev-loop:doctor` (the script: `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh`) checks the prerequisites and
prints the paths it resolved, and the plugin's marketplace source and pin in the user, managed and project
settings (read only; it prints only those entries). `DEV_LOOP_CLAUDE_DIR` (default `CLAUDE_CONFIG_DIR`,
else `~/.claude`) and `DEV_LOOP_MANAGED_SETTINGS` point it at other files.

## The loop

Start it with `/dev-loop:dev-loop` or simply "work through the open tickets".

1. **Tickets.** One GitHub issue per work item, with acceptance criteria and dependencies.
2. **Implementers.** At most 3 at a time, one ticket each, each in its own worktree
   (`feat/<n>-<slug>`). Each one writes the failing tests first, then the code, and runs only targeted
   tests and the fast check. It makes small Conventional Commits (`Refs #n`), pushes its branch and writes
   a PR notes file. That file sits outside git; its first line is a plain title, then a summary,
   `Closes #n`, the doc changes (`## Docs`), the reasons for new architecture exceptions
   (`## Architecture`, when there are any) and the test evidence. Implementers never open or merge PRs.
3. **Review.** The `code-reviewer` agent reviews every branch, independently of the implementer's own
   review. It reproduces suspected bugs as throwaway tests, and applies a deeper checklist on paths that
   touch money, orders, auth or deleting data. Must-fix items go back to the implementer, and the branch is
   reviewed again until `VERDICT: APPROVE`.
4. **Batch gate.** `gate-train.sh b1 b2 ...` stacks the approved branches, in merge order, on the latest
   base in a separate gate worktree. It then runs the configured checks once on the top of the stack. A red
   train is never merged, not even for an apparent flake: re-run it, then bisect. A branch that conflicts
   drops out of the train and is rebased after the others merge, then published as `<branch>-v2` with
   `repush.sh` (the loop never force-pushes). The output names the conflicting files (`TRAIN conflict
   in: ...`). Append-only logs that every branch adds to (`CHANGELOG.md` `## Unreleased`,
   `docs/DECISIONS.md`) need not conflict: list them in `merge.union_files` (off by default; literal
   paths from the repository root). The stacking then merges those files with the plugin's merge driver
   `scripts/union-merge.sh`. A merge that git does without a conflict is git's own result, as without the
   option: the driver diffs with histogram, as git's own merge does, and needs git 2.43 or later (an older
   git makes every listed file's merge a conflict, never a different diff). A change both sides made the
   same way is kept once only in such a clean merge: next to the sides' own entries git sees a conflict and
   the train stops. A merge with conflicts is resolved only when in every conflict hunk both sides only
   added lines: each hunk is kept whole, the base side's lines first, then the branch's, with no lines
   merged inside them (git's own `merge=union` would fold lines both entries share, such as
   `- **Alternatives:** none.`, into one copy); the lines outside the hunks merge as git merges them. Anything
   else stops the train as today: a hunk where a side changed or deleted existing lines (an amended entry
   next to a new one, a delete against an edit), both sides creating the file with different content
   (add/add), a file with a line that starts with 32 of one of git's conflict-marker characters, or a
   failing driver. CRLF files keep their CRs. The driver and a temporary `core.attributesFile` are passed to
   that one rebase with `git -c`; the user's and the repository's git config and `.gitattributes` are never
   changed. A conflict in any other file stops the train as before, and a merge driver that the repository's
   `.gitattributes` (or `.git/info/attributes`) or the user's own global attributes set for a listed file
   wins. Two branches that make the very same file need no merge: git keeps one copy, with or without the
   option. The checks then run on the merged result as on any other. The gate reads its
   rules from the main checkout's `.dev-loop.json`, so a branch that changes that file in any way needs a
   reason under `## Config` in its notes: every key the plugin reads runs, routes or deletes something (`checks`,
   `deploy`, `format`, `heavy.clean_temp`, `notes_dir`, `remote`, ...), so there is no list of harmless
   keys, and a new key is covered too. The file compares as JSON with sorted keys, so a reformatting is no
   change; a deleted file changes every key. Without a reason the gate names the branch and the changed
   top-level keys and ends `TRAIN RED` right after stacking. `architecture` is judged only by its own rule
   (a reason under `## Architecture`, see Architecture ratchet). The first `.dev-loop.json` on a base (the
   setup branch) is not judged by this check, and the gate says so (`first .dev-loop.json on <base>, not
   judged: the user reviews it (<branch>)`). Every key is compared, also `""`; a key that is not a plain
   name (`""`, or one with a quote, a backslash or a control character such as a newline) is named as its
   JSON string. A file that is not exactly one JSON document (trailing text, two documents) counts as
   unparseable with jq and with python3 alike; two different unparseable files are a change named
   `.dev-loop.json`. Reasons follow the placeholder
   rules of `## Architecture`. The filter only stops lazy placeholders (`ok` or `see above` pass it): the
   reviewer reads every `## Architecture` and `## Config` reason and judges it, and loosening the gate's
   rules (a weaker or removed check, a narrower docs map) needs the user's OK in collaborative mode.
5. **Merge.** `merge-train.sh b1 b2 ...` replays each branch on the current base and checks that its tree
   is exactly the gated tree. A branch that already contains the base with that tree merges as it is; a
   branch behind the base gets a merge commit with the gated tree on top (its parents: the gated head and
   the base), pushed as a plain fast-forward, never forced. It opens the PR from the notes file (a leading
   `#` in the title is stripped) and squash-merges exactly that head, whose squash is the gated tree. If
   the base moved in between, it asks for a new gate. The replay resolves conflicts in the
   `merge.union_files` with the same driver as the gate, so a base that gained a log entry since the gate
   means a re-gate (the tree differs), not a rebase; the replayed tree must still equal the gated one.
6. **Run and verify.** Jobs that a merged ticket added are run for real, and the `verifier` agent checks
   their outputs. Deploys happen only when the user is not in the middle of using the system, and are
   checked afterwards.
7. **Keep the queue full.** After every merge or report the next ticket starts. Long jobs run in the
   background. The loop stops only for its stop conditions: missing credentials, a cost cap, a spec
   contradiction that changes stored data, or anything unsafe or irreversible.

### Components

| kind | name | job |
|------|------|-----|
| skill | `dev-loop` | the orchestrator workflow, with the exact implementer and reviewer prompt templates |
| skill | `setup` | bootstrap a project (CLAUDE.md, DECISIONS.md, `.dev-loop.json`, permission rules, Makefile) |
| skill | `gate` / `merge` | run the batch gate and the ordered merge, and read their results |
| skill | `doctor` | check the machine and the project (`/dev-loop:doctor`), and explain each problem's fix |
| skill | `status` | what the loop is doing now, without waking its session (`/dev-loop:status`; see Status) |
| agent | `implementer` | one ticket, test first, in its worktree; pushes and writes the notes file |
| agent | `code-reviewer` | strict independent review; must fix / should fix; verdict |
| agent | `test-engineer` | failing tests from the acceptance criteria, before the code |
| agent | `verifier` | read-only audit of a real run's outputs |
| agent | `doc-auditor` | read-only audit of the current-state docs and component cards; one ticket per drift, a maintenance list for housekeeping |
| agent | `architect` | read-only architecture review from the merge evidence; refactoring tickets and extraction-ladder steps |
| agent | `scenario-writer` | writes the holdout scenarios for a ticket in the scenario store, from the spec (see Holdout scenarios) |
| script | `docs-check.sh` | checks a range keeps the current-state docs true (see Current-state docs) |
| script | `docs-archive.sh` | moves the oldest journal entries and finished specs to `docs/archive/` (dry run by default; see Current-state docs) |
| script | `arch-check.sh` | checks a commit against its component cards and the baseline (see Architecture ratchet) |
| script | `arch-evidence.sh` | the architecture signals from the merge ledger, the cards and git (see Merge evidence and the architect) |
| script | `permissions.sh` | merges the loop's permission rules into the project's settings (dry run by default; see Permission modes) |
| script | `status.sh` / `event.sh` | read-only status and verdict; the orchestrator's steps into the event log (see Status) |
| script | `cleanup.sh` | classify every branch and remove merged and abandoned leftovers (see Branch lifecycle) |
| script | `union-merge.sh` | the merge driver for `merge.union_files`, passed per command by the gate and the merge (see The loop, step 4) |
| script | `repush.sh` | publish a rebased branch as `<branch>-vN` instead of force-pushing it (see Branch lifecycle) |
| hook | format-on-edit | runs `format` on each edited file (PostToolUse) |
| hook | stop gate | blocks the stop while `fast_check` is red or work is uncommitted (a modified tracked file, or an untracked file newer than the session); gives up after 5 blocks |
| hook | role guard | in every loop project: refuses git commands that hit a stop condition (see Permission modes: the git guard; off with `"guard": false`); with `targeted`: refuses a targeted runner's arguments off its safe list (see Permission modes: targeted commands); with scenarios on: keeps the scenario store from the coding agents; identity mode: GitHub writes only through `as-role.sh` with the agent's role (PreToolUse) |

Every script under `scripts/` prints its usage for `-h` or `--help` as its first argument and exits 0
without touching anything; the scripts that take branches (`gate-train.sh`, `merge-train.sh`, `repush.sh`,
`open-pr.sh`) refuse any other argument starting with `-` with exit 2 and the usage.

All hooks do nothing in a project without `.dev-loop.json`, so the plugin is safe to install globally.

The stop gate blocks on an untracked file only when it is not older than the session's start: the first
timestamp in the session's transcript, else (no transcript, or one without a timestamp) the hook's first
run in that session, so then it only protects files created after the first stop. The start is a marker
under the repository's git directory, `dev-loop-sessions/`. The comparison is by modification time, so a
file the session made with an old mtime (`cp -p`, `mv`, an extracted archive) counts as older and does
not block. Older untracked files, such as an owner's notes or
another session's file, do not block; the hook lists them once per session as a note. Modified tracked
files always block. Without a session id in the hook input every untracked file blocks, as before;
`stop_gate.require_clean_tree: false` turns the tree check off.

## Testing without overloading the machine

Several agents running full test suites at the same time can exhaust a machine's memory: everything swaps,
or the kernel kills processes. The plugin makes "one heavy job at a time, per slot" a hard rule:

- **`heavy.sh` is a machine-wide queue.** `scripts/heavy.sh <command>` waits for one of `heavy.slots`
  slots (default 2) and then runs the command. The slots are shared by every repository, worktree and
  Claude session of the user on the machine. The locks live in the user's runtime directory
  (`$XDG_RUNTIME_DIR/dev-loop-heavy-slots`), not in a repository. A third command waits
  (`all 2 slots busy, waiting`) until a slot frees.
- **Memory cap.** With `heavy.memory_max` set (e.g. `"8G"`) the command runs in a transient systemd user
  scope (`systemd-run --user --scope -p MemoryMax=...`). The cap applies to the whole process tree, so a
  runaway suite is stopped and the rest of the machine keeps working. Without a systemd user session the
  command runs without the cap, with a warning.
- **A port per slot.** With `heavy.port_env` set, each slot exports its own port
  (`port_base + slot * port_step`), so two e2e servers never collide. Implementers use ports outside that
  range.
- **Stale temp cleanup.** Before each run it deletes temp entries it knows about once they are older than
  `heavy.clean_temp_minutes`: the `heavy.clean_temp` globs, pytest base directories beyond the newest 5,
  and dead locks.
- **One full run per batch.** `gate-train.sh` runs every heavy check through `heavy.sh`. A train of N ready
  branches costs one full run, not N (or 2N, when each branch is checked before and after its rebase).
- **Red trains end early (opt-in).** `affected` runs the tests the train's changed files touch before
  anything else, `parallel` runs the checks side by side (each heavy one in its own slot), and
  `fail_fast` stops the rest of the train at the first failure, killing the running checks' process
  groups so their servers and slots are freed. All three are off by default; see the `gate` skill.
- **A hung check is stopped (opt-in).** With `stall_minutes` in a check entry (or `affected`,
  `scenarios`), the gate stops a stage whose log has not grown for that many minutes (its whole process
  group, as `fail_fast` does) and reports `<name> stalled: no output for <n> min`; the train is red. A
  check whose log keeps growing is never stopped, and a heavy check queued in `heavy.sh` for a slot is not
  stalled (its clock starts with the slot). Off by default; see the `gate` skill.
- **Implementers run targeted tests only.** The agent brief and the loop say so: tests for what they
  touched plus the fast check. Anything heavy goes through `heavy.sh` or is left to the gate.
- **The Stop hook runs only `fast_check`**, which takes seconds. Running the full suite on every stop
  would delay every reply.

## Status: what is the loop doing?

A session waiting on a 20-minute gate looks the same as a stalled one, and asking it wakes it.
`/dev-loop:status` (the script: `${CLAUDE_PLUGIN_ROOT}/scripts/status.sh`) answers from any terminal or
session, read-only: it never writes, signals or locks anything.

- **The gate:** running or not (`train-running.txt` and its pid), the train, each running stage with its
  elapsed time, its log, and how many seconds ago the log last grew.
- **Heavy slots:** how many are in use and what holds each (pid, repository, command), read from the event
  logs of every repository under `~/.dev-loop`, since the slots are machine-wide.
- **Loop worktrees:** branch, ticket, last commit age, notes file age, pushed or not, ahead and behind the
  base (from the local remote-tracking refs; it does not fetch).
- **The last merge** (the ledger), the **open tickets** count (`gh issue list`; `--no-gh` skips it), and
  the **orchestrator's last event** with its age, and the **agents in flight** (`agent-started` or
  `watchdog-resumed` not yet followed by `agent-reported`, a merge of that ticket (a `merged` event or
  the ledger), or an `idle` event).
- **The verdict**, the last line: `idle` (nothing running and nothing in flight; a recent event on its own
  is not work), `working` (a loop worktree with unmerged work, or an agent in flight; worktrees unchanged
  since the orchestrator's last `idle` event do not count), `waiting on <what> (output <n>s ago)` (a
  running gate stage, a heavy job of this repository, or the orchestrator's last `waiting` event while it
  holds: a wait that names branches, such as `waiting detail="gate feat/12-x"`, is over once a gate
  result of a train with one of them or a merge of one came after it, from the event log or the ledger;
  file names and URLs in its detail are not branches),
  `waiting on heavy slot (queued)` (the running gate's own job waits in `heavy.sh` for a free slot, for
  example behind another repository's long job), or
  `possibly stalled: no event or output for <n> min`, when the newest evidence (an event, a stage log, a
  worktree commit or notes file) is older than `watchdog.stall_minutes` (default 30). While the gate
  runs, only its own evidence counts (stage logs, `train-running.txt`, this repository's gate events, a
  live queued heavy job of this gate), so an implementer's commits or heavy jobs never hide a frozen
  stage; other repositories' events never count. A stage that prints nothing for longer than
  `stall_minutes` reads as possibly stalled, so a project with slow silent suites needs a higher
  `stall_minutes`; the orchestrator's heartbeat (below) confirms before it acts on the verdict.
  A gate killed without cleaning up shows as `idle (the last gate died: train-running.txt is stale)`.
- **`--json`** prints one object for machines; its fields are listed at the top of `scripts/status.sh`
  and are only ever added to.

The **event log** `~/.dev-loop/<repo>/events.jsonl` (`paths.sh events`) has one JSON line per step:
`{"t": "<UTC>", "who": "gate|merge|heavy|orchestrator", "event": "...", ...}`, every other value a string.
`gate-train.sh` writes `train-started` (`pid`, `branches`), `stage-started` (`stage`, `log`),
`stage-ended` (`stage`, `rc`, or `result: stopped`) and `train-ended` (`rc`, `result`: green, red,
conflict, error); `merge-train.sh` writes `merge-started`, `merged` (`branch`, `ticket`) and `merge-ended`
(`rc`); `heavy.sh` writes `queued`, `slot-acquired` and `slot-released` (`slot`, `pid`, `rc`, the command as
`detail`, and `gate_pid` when the gate runs the job: `gate-train.sh` exports its pid as `DL_GATE_PID`). The orchestrator records its own steps with `scripts/event.sh <event> [key=value ...]` (for
example `event.sh agent-started ticket=12`, `event.sh agent-reported ticket=12`,
`event.sh waiting detail="gate train feat/12-x"`, and `event.sh idle detail="nothing in flight"` at the
end of a session or after a release). Each line is
one append; at 1 MiB the log moves to `events.jsonl.1` (one old file kept). A failed write is ignored, so
the log never fails a gate, and nothing but `status.sh` reads it.

**The heartbeat (stall watchdog).** Background notifications wake the orchestrator when a job ends, not
when a command hangs or an agent never reports. So when it only waits, the `dev-loop` skill (section 2a)
has it record `waiting` with `event.sh` and schedule a fallback wake-up in `watchdog.wake_minutes`
(default 25) with the session's scheduling tool (or a background command that waits that long and
exits). On waking it runs `status.sh --json`: something moved, it waits again; `stalled`, it confirms
first (is the stage's process tree still using CPU? did the agent's worktree change?) and only then acts:
a hung loop command is stopped after reading its log tail (only the gate's own stage processes and the
heavy jobs its gate started), an agent with no report is resumed or replaced. It records what it did
with `event.sh`, and never kills anything that is not the loop's own. `"watchdog": false` turns the
heartbeat off.

## Branch lifecycle

Branches are short-lived: a branch exists from its first push until its ticket is resolved, then it goes,
locally and on the remote. Squash merges leave no ancestry, so "merged" is decided by the plugin's own
record, never by `git branch --merged`.

| Thing | Removed |
|---|---|
| remote feature branch | by `merge-train.sh` after the merge (`merge.delete_branch`) |
| local feature branch and its worktree | by `merge-train.sh` after the merge, when the local tip is the merged head and the worktree is clean (only when its ignored files are all build output, `merge.rebuildable`; a worktree holding `.env`, keys or local data is kept); otherwise it says what it kept and why (`merge.delete_local`) |
| `train-<branch>` | by `merge-train.sh` once the whole train merged; by the next `gate-train.sh` for red trains and branches no longer in a train |
| `replay-<branch>` | by `merge-train.sh` right after use |
| notes file | moved to `notes/merged/` on merge; removed by `cleanup.sh` after `cleanup.keep_days` |
| gate logs | the latest train's are kept; older ones by `cleanup.sh` after `cleanup.keep_days` |

`merge-train.sh` appends every merge to a ledger, `~/.dev-loop/<repo>/merged.jsonl` (branch, source and
pushed head, gated head and tree, PR, merge commit, time, and the evidence `arch-evidence.sh` reads: the
`files` the merge changed, their `components` (empty without `architecture`), the `lines` added and
deleted, the `review_rounds` and the `ticket`). `scripts/cleanup.sh` classifies every local and
remote branch from the ledger, then the PR list (a replayed copy counts when it brings the same changes),
then the issue its name points at (`<type>/<n>-...`):

| Class | What | `--apply` |
|---|---|---|
| merged | in the ledger or a merged PR at this tip (or a replayed copy with the same changes); a local loop branch the base contains | deleted |
| helper | local `train-*`/`replay-*` refs of loop branches outside a live train, local agent worktree branches without own commits | deleted |
| superseded | a later version (`<branch>-vN`, `repush.sh`) merged and its notes record this tip (``Supersedes `<branch>` at <sha>``); without a record or after new commits: kept until deleted by hand | deleted |
| closed | PR closed unmerged at this tip, or its issue closed as not planned | with `--include closed` (the user's OK); automatic with `"factory": "dark"` |
| stale | no PR, no open issue, idle for `cleanup.stale_days` (remote: loop branches only) | with `--include stale`; automatic with `"factory": "dark"` |
| keep | open PR or issue, checked out in a worktree, a live train, recent, moved on after its PR, or a remote branch outside the loop (`develop`, `release-*`) | never |

Branches outside the loop are never judged by PRs or the ledger: locally they can only be stale, remotely they are always kept. `main`, `master`, `develop`, `trunk` and the remote's default branch are always kept. The gate deletes only `train-*` refs of loop branches.

**Never a force push.** The deny rules, Claude Code's auto mode and GitHub rulesets can all refuse a
force push, so a branch that was rebased after it was pushed (a gate rebase conflict, a merge replay
conflict, a stacked branch whose lower branch merged) is published under a new name:
`scripts/repush.sh [<branch>]` (default: the checked-out branch) picks the next free `<branch>-v2`,
`-v3`, ... (free on the remote, locally and in the notes directory), pushes it with a plain `git push -u`
(as the implementer in identity mode), switches the worktree to it, and copies the notes file with a
``Supersedes `<branch>` at <sha> [<sha>]`` line recording the old branch's local and remote tips (before
the notes' closing `Generated with` footer line when there is one, so the PR body still ends with it). It
refuses a dirty worktree and the base branch, never deletes or moves the old branch, and prints the new
name last. `open-pr.sh` (also run by `merge-train.sh`) closes the open PRs of the earlier versions a
`-vN` branch supersedes (its notes name them on a `Supersedes` line, or their head is an ancestor of its
head), with a comment pointing to the new PR, and closes nothing when it cannot read the new PR's number.
`cleanup.sh` deletes the old branches as `superseded` once the new one has merged, each ref only while
its tip is a recorded one, and moves their notes to `notes/merged/`. An old version without a record, or
one that moved on since the re-push, is kept until the user deletes it by hand: `--include closed` and
`--include stale` do not touch it. The record lives in the notes files, so once the merged version's
archived notes are removed after `cleanup.keep_days` they no longer count as a record. The tooling takes
`<type>/<n>-<slug>-vN` names like any other: they match the feature patterns, and the ticket is still
`<n>`.

Loop branches are the ones matching `github.feature_patterns` (default `feat/* fix/* chore/* docs/*`).
Every deletion is conditional on the tip that was classified (`update-ref` with the old value, a push
lease on the remote), and the count printed is read back from the result. Needs git 2.9 or later.

It is a dry run without `--apply` (it still fetches with `--prune`), writes the full classification (with the reason for every kept
branch) to the logs directory, and saves every deleted tip to a bundle in `~/.dev-loop/<repo>/archive/`
first and checks the bundle holds each one: `git fetch <bundle> refs/heads/<branch>:refs/heads/<branch>`
restores one (a remote-only branch: `refs/remotes/<remote>/<branch>`). Old gate logs and cleanup reports
go after `cleanup.keep_days`; other files in the logs directory are never touched. `doctor.sh` notes
leftovers it can count without GitHub.

**Worktrees kept for changes.** `merge-train.sh` removes only a clean worktree; one with modified or
untracked files keeps its branch, and the "kept local ... has changes" line names
`cleanup.sh --apply --include worktrees`. `cleanup.sh` lists the worktrees of merged branches (the ledger
or a merged PR at the tip; a branch the base merely contains is new work and is not listed) with their
modified and untracked file counts and the first file names, each `remove` or `keep` with the reason; the
listing takes no index lock (`git --no-optional-locks`). With `--apply --include worktrees` it writes each
`remove` one to a new `~/.dev-loop/<repo>/archive/worktrees-<time>/<branch>/` (a `-2`, `-3` suffix when
two branch names map to one folder): `changes.patch` and `staged.patch` (the worktree and the index
against `HEAD`, binary, whatever the user's diff config), `untracked.tar`, and `manifest.txt` with the
branch, tip, file lists and a restore line. It checks that the patches reverse-apply and the tar lists
every untracked file, checks that the worktree's changes, index and untracked files still match the
archive, moves the worktree aside (`<path>.removing-<pid>`) and checks again (on a difference it moves it
back and keeps it), then removes it with `git worktree remove --force` and deletes the branch at the
merged tip (saved to the bundle when the base does not contain it). Always kept: the main checkout and the
gate worktree (compared as real paths, so a symlinked `worktrees_dir` counts), a locked worktree, one with
submodules (their git dirs belong to the worktree), per-worktree refs (`refs/worktree/*`, `refs/bisect/*`)
or another worktree inside it, one in a merge, rebase, cherry-pick or revert, one with assume-unchanged or
skip-worktree files, ignored files that are not build output (`merge.rebuildable`) or a folder it cannot
read, and one with any file changed (mtime or ctime) in the last 10 minutes (an agent may still work
there; `DEV_LOOP_WORKTREE_SETTLE_MINUTES` sets the window, 0 turns it off; the folder's own ctime after
the move does not count). A worktree kept after its archive was written gets that incomplete archive
removed; a move aside that fails half-way is reported with both paths, and the next dry run notes the
`.removing-*` folder. An independent repository (not a submodule) inside an ignored folder that counts as
build output is deleted with the worktree, its commits included, as `merge-train.sh` already does. Restore
one as its manifest says: `git worktree add <path> <tip>` (when the base does not contain the tip, first
fetch the branch from the bundle that run printed), then `git apply --cached staged.patch`,
`git apply --binary changes.patch` and `tar -xf untracked.tar` in it.

## Current-state docs (optional)

The spec is written once and every ticket after it is a change to it, so nothing says what the system does
now. With a `docs` block in `.dev-loop.json`, the loop keeps one current-state doc per aspect true on
every merge:

```json
"docs": {
  "aspects": {"features": "docs/features", "architecture": "docs/architecture.md", "operations": "docs/operations.md"},
  "planned": "docs/planned.md",
  "map": [
    {"paths": ["src/api/*", "src/cli.py"], "docs": ["features", "architecture"]},
    {"paths": ["deploy/*"], "docs": ["operations"]}
  ],
  "max_lines": 1000,
  "prd": ["docs/specs/prd.md"],
  "audit_every": 10,
  "planned_max_days": 60
}
```

- **Aspects** name a file or a folder (an index and one file per area). They describe only what is built;
  planned work stays in the tickets and the `planned` list. `docs/DECISIONS.md` stays the only history
  (its old entries in `docs/archive/`, see Journals and the archive).
- **The map** says which docs describe which code. `paths` are shell globs matched against the whole
  repository path, where `*` also matches `/` (`src/api/*` covers `src/api/v1/users.py`).
- **The agents.** Each ticket names the doc sections it changes; for a feature, the change to Features is
  written first. The implementer updates the docs in the same branch and writes a required `## Docs`
  section in its notes: the doc changes, or `none: <reason>`. The reviewer treats a false or missing doc
  change as a must fix. A spec whose work has all merged is archived.
- **`scripts/docs-check.sh <from> <to> [<notes file>]`** (deterministic; exit 0 green, 1 red, 2 usage or
  config) is red when a file changed in the range matches a map rule but none of that rule's docs changed
  and the notes' `## Docs` section has no `none: <reason>` line, or when a changed Markdown file has a
  relative link (`[x](path)`, `[x](path#anchor)`, `[x](<path with spaces>)`, `%20`) that does not resolve
  in `<to>`. Links with a scheme, anchors, absolute paths, links in code, reference-style links and
  targets with nested parentheses are not checked. A `<from>` that is not an ancestor of `<to>` is
  replaced by their merge base, so `docs-check.sh origin/main HEAD` judges only the branch's own changes.
  Each message names the file, the rule and its docs.
- **The gate** runs it for each branch of a train right after stacking, on that branch's own commits with
  its notes file, and ends `TRAIN RED` naming the branch before `gate_setup` and the checks. It reads
  `docs` from the main checkout's `.dev-loop.json`, so a branch cannot change the rules of its own check.
- **The slice loop.** `prd` names the PRD or spec files (optional, one or several): the intent, kept
  apart from Features, the state. The orchestrator keeps the gap between them in the planned list, each
  entry linking its ticket, and slices the next part of the gap into tickets at the start of a session
  and when the list runs low, never the whole PRD upfront. A ticket changes one component where possible
  (an interface change first, then each consumer), fits one implementer's context, starts with the
  Features change for a feature, and names its `Docs:` and `Components:` in its body. As it merges, its
  planned entry moves to Features in the same branch; a PRD section whose work has all merged is marked
  done or archived (`docs-archive.sh spec`).
- **The `doc-auditor`** (read-only by its brief; its tools include Bash, which can write, and the role
  guard covers only GitHub writes) compares each current-state doc and component card with the code and,
  where it is safe, the running system (CLI help, endpoints, config keys, jobs), and opens one ticket per
  drift with the evidence; housekeeping goes in its report as a maintenance list instead. It runs every
  `audit_every` merges (default 10), when the user asks, and before a release; before a release the
  orchestrator also checks the planned list and Features against the tickets merged since the last one.
  The orchestrator records each audit in `~/.dev-loop/<repo>/doc-audit.txt` (`paths.sh doc-audit`, one
  UTC time).
- **`doctor.sh`** prints the aspects, the planned list, the PRD files and the map; reports a missing aspect
  path or PRD file as MISSING; notes files and journals over `max_lines` and map rules that match no
  tracked file; and prints the merges since the last audit (from the merge ledger and the audit marker),
  with a `doc audit due` note at `audit_every`.
- **Planned-list hygiene.** A ticket never lives only to hold a memory: the PRD holds the intent, the
  planned list only what is actively sliced. `doctor.sh` reads each planned row's ticket (`#n`) with one
  `gh issue list` call and notes a row whose ticket closed as completed (`move it to Features`), closed as
  not planned (`remove the row`) or does not exist, and a row with no ticket number. With
  `planned_max_days`, it also notes a row whose ticket is open longer than that with no loop branch
  (`<type>/<n>-*`, local or remote): close it as not planned and remove the row. A row is a list item or
  a table body row outside code fences (CommonMark, the same rule as for links; a rule like `* * *` is
  not one); in a file with a heading whose text starts with the word "Planned" (the end of
  `templates/FEATURES.md`), only that section's rows count. These are notes, never MISSING; without `gh`
  access one note says the rows were not checked.
- **Docs maintenance.** The auditor finds, a normal implementer cleans up. On the audit's cadence, right
  after it, the orchestrator opens one `docs: maintenance` ticket listing `doctor.sh`'s docs notes at that
  time (it prints them on every run; they become a ticket only on this cadence) and the auditor's
  maintenance list: planned rows to move or remove, journals over budget (`docs-archive.sh journal`, then
  refresh `## Standing decisions`), finished specs (`docs-archive.sh spec`) and at most one oversized doc to
  split per ticket. Stale tickets are closed as not planned, with a comment, the same way as cleanup's
  closed and stale branches: with the user's OK in collaborative mode, without asking in `factory: dark`; a
  declined one keeps its row, and the next `doctor.sh` run notes it again. The ticket is implemented,
  reviewed and gated like any other, and skipped when there is nothing to do (the `dev-loop` skill, section
  7a).

### Journals and the archive

A journal is an append-only Markdown file whose `## ` headings are its entries, newest last (required):
`docs.journals` (default `["docs/DECISIONS.md"]`). It keeps growing, so like a long session log it is
compacted: the oldest whole entries move, verbatim, to `docs/archive/`, and the live file keeps the recent
ones. A `## Standing decisions` section at the top of a journal lists, one line each, the decisions still
in force, each linking its entry wherever it lives (the live file or an archive file); compaction keeps
the section in place, and keeping it true is model work, a maintenance ticket reviewed like any change.
Finished specs move to `docs/archive/specs/` the same way.

```
scripts/docs-archive.sh journal [<file>] [--keep <lines>] [--apply]
scripts/docs-archive.sh spec <file> [--no-pointer] [--force] [--apply]
```

- **A dry run by default.** Without `--apply` it prints exactly what would move (the lines, each entry
  heading, the archive file) and writes nothing. Without `docs` it is a config error and changes nothing.
- **`journal`** works on `<file>`, else on every journal. When one is over its budget (`--keep`, else
  `docs.max_lines`), it moves the oldest entries until the live file is within budget, to
  `docs/archive/<NAME>-<first date>--<last date>.md` (the dates of the first and last moved entry
  headings, `## 2026-11-05 — ...`; `undated` without one). The preamble (the text before the first entry)
  and the `## Standing decisions` section stay where they are; only the run of entries before that section
  (or after it, when it comes first) moves, and the newest entry always stays. A journal whose first dated
  entry is newer than its last (newest first) is refused. `## ` inside a code fence is not an entry; fences
  follow CommonMark (a fence closes only on its own character, at least as long; a line indented 4 spaces
  is not a fence), the same rule `docs-check.sh` uses for links. An archive file is
  never edited or overwritten: a taken name gets `-2`, `-3`, ... Before writing, it checks that the live
  file with the archive put back equals the original byte for byte (CRLF and a missing last newline
  included); otherwise it writes nothing and exits 1. A journal within budget is left alone.
- **`spec <file>`** moves a finished spec to `docs/archive/specs/` byte for byte and leaves a one-line
  pointer linking it (none with `--no-pointer`). It refuses a file that a docs aspect or `docs.prd` still
  names (unless `--force`) and a destination that exists, and reports the links in other Markdown files
  that point to the spec.
- **Links.** Moved text with a relative link that would not resolve from the archive folder (the link
  rule of `docs-check.sh`) is refused with the link named; nothing is rewritten, so what moves stays
  verbatim. Make such a link resolve from both places, or use a URL, then run it again.
- **Exit:** 0 done or nothing to do, 1 refused (nothing written), 2 usage or config error. `doctor.sh`
  notes a journal over `docs.max_lines`: `journal docs/DECISIONS.md has <n> lines, over max_lines <m>
  (compact it: docs-archive.sh journal)`.
- **Setup** proposes the layout, the map and the planned list, and for an existing project rebuilds the
  current-state docs once, one aspect at a time, each reviewed by the user. Templates:
  `templates/FEATURES.md` and the "Documentation" section of `templates/CLAUDE.md`.
- **Gradual adoption.** A project with large hand-written docs (many files, some over `max_lines`, specs
  mixed with built state) adopts them in steps instead (setup step 3b.6), so the loop never stalls:
  the Features file first (from `templates/FEATURES.md`), then `docs` with only the Features aspect and
  an empty `map` (nothing turns red; oversized files are only notes); then a mixed "built + planned" file is split (built items to Features, unbuilt ones to the
  PRD in `prd`, or to the planned list only when sliced into a ticket); finished specs are archived and
  the journal compacted once (`docs-archive.sh`, a dry run, then `--apply`, then the `## Standing
  decisions` section is written); `map` rules are added one aspect at a time; oversized docs are left to
  docs maintenance tickets (see Docs maintenance), one split per ticket.

Without `docs` (or with no aspects, as in `templates/dev-loop.json`) none of this runs, and `doctor.sh`
prints one note: `current-state docs off: no docs check, no doc audit, no planned list; adopt them with
the setup skill's step 3b`. It is a note, not MISSING: `doctor: ready` is unchanged.

## Architecture ratchet (optional)

Agents add dependencies wherever the code they read suggests one, and a codebase drifts into one big
cycle. With an `architecture` block in `.dev-loop.json`, each component has a card that says what it owns,
its layer and what it may use, and the gate keeps every new dependency inside those rules while the known
violations may only shrink:

```json
"architecture": {
  "cards": "docs/architecture/",
  "check": "python3 tools/import_edges.py",
  "baseline": "docs/architecture/baseline.txt",
  "budget": 8000
}
```

- **A component card** is one Markdown file per component in `cards` (from `templates/COMPONENT.md`),
  with a header the scripts read and free text after it (responsibility, public interface):

  ```
  ---
  component: storage
  layer: 0
  kind: component        # or: composition-root; service, job, store (run-time components)
  paths: src/app/storage/* src/app/catalogue.py
  depends_on: instruments
  max_lines: 8000
  ---
  ```

  `layer` is a number, 0 at the bottom; no dependency may go up a layer. `paths` are globs on the
  repository path where `*` also matches `/`; a file belongs to the card whose matching glob is longest.
  `depends_on` is optional: when the line is there (even empty), a dependency on any other component is
  flagged. A composition root (entry points, the CLI, the job runner, app wiring) may depend on the layers
  below it without listing them; its fan-out is not flagged. `service`, `job` and `store` mark run-time
  components (a process, a scheduled job, a data store), checked like any component; `arch-evidence.sh`
  reports two of them connected in code. `max_lines` overrides `budget`; without
  either, the component has no budget. A Markdown file in the folder whose first line is not `---` (an index) is not a card.
- **`check`** is the project's own command (an `ast` scan, import-linter, dependency-cruiser...), run at
  the repository root. It prints one edge per line, `<from> <to>`: repository paths, or component names.
  The plugin ships no dependency tool.
- **`scripts/arch-check.sh <ref>`** (deterministic; exit 0 when every violation is in the baseline, 1 for a
  new violation or an error at `<ref>` such as a broken card or a failing `check`, 2 for a usage or config
  error) reads the cards at `<ref>`, runs `check` in a checkout of `<ref>` (this worktree when it is at
  `<ref>` with no tracked file modified, else a temporary worktree) and prints one stable line per
  violation, as `new` or `known`: `upward A -> B`, `undeclared A -> B`, `cycle A B C` (a group of
  components that depend on each other, once, its members sorted) and `budget A <lines>/<max>` (the
  lines of the component's tracked text files). A baseline entry that no longer occurs prints as
  `fixed ... (remove it from the baseline)`. A file in no component is a note.
- **The ratchet.** `arch-check.sh --baseline [<ref>]` writes today's violations to the baseline file,
  sorted, to be committed. A budget entry stays known while the component does not grow past its
  baselined size. In the gate a branch may add baseline entries only with a reason under `## Architecture`
  in its notes, so by default the baseline only shrinks. The same reason is needed for a card header edit
  that makes violations disappear (a name added to `depends_on`, a higher `max_lines` or `layer`, narrower
  `paths`, a new composition root): `arch-check.sh --loosened <from> <ref>` judges the code of `<ref>` by
  the cards of `<from>` and lists what `<ref>`'s cards hide (exit 1), without running `check` when no
  header changed (a renamed or removed component's violations show there under its old name). A branch
  that changes the `architecture` block of its `.dev-loop.json` needs the same reason, since the gate
  reads the main checkout's config (compared as JSON with sorted keys, so a reformatting is no change). A
  placeholder (`none`, `n/a`, `TODO`, `-`, `not applicable`, `nope`, `no reason`, `not relevant` and the
  like, also repeated, as in `none none`, followed by filler, as in `none yet` or `not needed for now`, or
  by punctuation, as in `none: ...` (the notes template's placeholder) or `none (...)`) is not a reason; a
  sentence such as `none of the edges ...`, or a placeholder word, a comma and at least three more words
  (`No, the check was redundant`), is. The filter only stops lazy placeholders (`ok` or `see above` pass
  it): the reviewer reads every reason.
  Two cards with the same `paths` glob are a broken card.
- **The gate** runs after `gate_setup` and before the checks: the baseline and card rules for each branch,
  then `arch-check.sh` on the train's top. When the top is red, or reports as fixed a baseline entry that
  occurred at the base, each branch's train ref is checked in order and named with the new lines it brings
  or the fixed entries it keeps (`arch-check red for <branch>`: the branch that fixes an entry removes it,
  so a later branch cannot bring it back as known), and the train ends `TRAIN RED`. An entry already stale
  at the base is only reported. The config comes from the main checkout's `.dev-loop.json`; the cards and
  the baseline from the branch.
- **`doctor.sh`** prints the components by layer with their sizes against their budgets, reports a broken
  card or a failing `check` as MISSING, and notes components over budget, files in no component and the
  baseline size.
- **The agents.** Each ticket names its components and is sliced to one where possible (the interface
  first, then the consumers). The implementer keeps the cards true and allows a new dependency only
  through the cards, or says why under `## Architecture`. The reviewer treats a false card or a new upward
  dependency solved by an exception as a must fix: the fix is an interface the lower layer defines. Setup
  drafts the first component map from the code, asks the user to confirm the boundaries and layers, and
  records the baseline.

Without `architecture.check` (empty in `templates/dev-loop.json`) none of this runs.

### Merge evidence and the architect

The ratchet keeps new code inside the cards; the `architect` agent asks whether the cards are still the
right ones. It reads evidence, not impressions:

- **The merge ledger** records per merge the `files` it changed (against the base it was replayed on), their
  `components` through the cards of the merged head, the `lines` added and deleted, the `review_rounds`
  (a `Review rounds: <n>` line in the notes file, else one plus a `## Review fixes` heading per round)
  and the `ticket` (the notes' `Closes #n`, else the branch's number). Older lines stay valid.
- **`scripts/arch-evidence.sh [--since <n> | --since <time>]`** (deterministic and read-only; exit 0
  without a signal over its threshold, 1 with one, 2 for a usage or config error) reads the ledger window
  (by default the merges since the architect last ran, else the last `cadence` merges), the cards, the
  edges of `check` and git, and prints the window, a summary table and one stable line per finding:

  | signal | finding | threshold (`architecture.*`, default) |
  |--------|---------|-----------|
  | size | `size budget A <lines>/<max>`, `size growth A +<n> lines` | over the budget; `growth` (500) lines in the window |
  | scatter | `scatter <branch> <n> components: ...` | more than `scatter` (3) components in one merge |
  | co-change | `co-change A B <t>/<u> merges` | together in `co_change` (75) % of the merges that changed either, at least `co_change_min` (3) |
  | hotspot | `hotspot <path> <n> merges` | a file in more than `hotspot` (5) merges |
  | cycle | `cycle <n> components: ...` | more than `cycle` (3) components |
  | misplaced | `misplaced A -> B (...)` | any lower layer using a component of the top layer (UI, CLI) |
  | fan-out | `fan-out A <n> components: ...` | more than `fan_out` (5) dependencies; composition roots are exempt |
  | friction | `friction rounds <branch> <n> rounds`, `friction reopened #<t> <n> merges: ...` | more than `review_rounds` (3) rounds; a ticket merged twice |
  | runtime | `runtime A -> B (...)` | two run-time components (cards with `kind: service`, `job` or `store`) connected in code |

  A ledger line without `files` gets them from its merge commit.
- **The `architect` agent** (read-only by its brief; its tools include Bash, which can write, and the
  role guard covers only GitHub writes; `models.architect`) reads the evidence, the cards, the
  current-state docs, the PRD and the planned list. It keeps the run-time map (services, jobs, stores)
  and the code map apart, and proposes small refactoring tickets (extract, split, merge, move behind an
  interface, invert a dependency; behaviour unchanged, the existing tests as the safety net), card and
  Architecture doc updates as a docs ticket, and steps on the **extraction ladder**: a clean layer, then a
  package with a public API in the same repository, then a separate repository or service. The last step
  needs the user's go in every mode. It never edits code, merges or closes tickets.
- **The loop** runs `arch-evidence.sh` at the start of a session and every `cadence` (20) merges, starts
  the architect when a signal is over its threshold or the cadence is reached, records each run in
  `~/.dev-loop/<repo>/architect.txt` (`paths.sh architect`, one UTC time), and schedules its tickets next
  to feature work, ahead of it only for a red signal. **`doctor.sh`** prints the merges since the
  architect last ran and the signals over their thresholds, and notes `architect due`.

## Holdout scenarios (optional)

The gate proves that the tests pass, not that the software does what its users need. Holdout scenarios are
end-to-end user scenarios kept outside the codebase, where the coding agents never see them. This part is
the **scenario store** (where the scenarios live and what a valid one is), the guard that keeps it
from the coding agents, the **scenario writer**, and the gate's **scenario stage**, which judges every
train against them on the running system.

```json
"scenarios": {
  "dir": "~/.dev-loop/<repo>/scenarios",
  "run": "make scenario-env",
  "judge": "<command; default: the scenario-judge agent>",
  "pass": 0.8,
  "min_satisfaction": 0.9,
  "sealed": 0.2
}
```

- **Opt-in:** without a `scenarios` key nothing changes; `"scenarios": {}` turns the store on with the
  defaults, and `"scenarios": false` (or `null`) keeps it off. `"factory": "dark"` turns it on by default
  (see [Factory preset](#factory-preset-collaborative-or-dark)).
- **`scenarios.dir`** is the store, default `~/.dev-loop/<repo>/scenarios` (the state directory, outside
  every worktree); `~` and `<repo>` are expanded, a relative path is taken from the repository root.
  `paths.sh scenarios` prints the resolved directory. The other keys are the scenario stage's (below).
- **One Markdown file per scenario** (`*.md` at any depth of the store, not under `.git`; a symlink to a
  file counts, a UTF-8 byte order mark is ignored), with front
  matter between two `---` lines: `id` (unique in the store), `title`, `spec` (the spec sections it
  covers), `tags`, `required: true|false` (required scenarios must pass, the rest are scored). The body
  describes the user and their goal, the preconditions and fixtures, the steps, and what "satisfied"
  looks like in user terms. Write scenarios from the spec, never from the code. Example:
  [`templates/scenario.md`](templates/scenario.md).
- **The front matter** is a small YAML subset: `key: value` lines, lists as `[a, b]`, values optionally
  in quotes, ` # comments` after an unquoted value. Nested keys and multi-line values are not read.
- **Invalid:** no front matter, front matter that is not closed, a missing `id` or `title`, a duplicate
  `id` (reported on every file after the first, in path order), `required` other than `true` or `false`
  (also when missing), an empty body.
- **`doctor.sh`** prints the store, the settings, the number of scenarios and of required ones, and reports
  each invalid file as `MISSING scenario <file>: <reason>` and a `pass`, `min_satisfaction` or `sealed`
  that is not a number from 0 to 1. It notes a store that does not exist yet, or one inside the
  repository (the coding agents can read it there).
- The functions (`scripts/lib/scenarios.sh`): `dl_scenarios_on`, `dl_scenarios_dir`,
  `dl_scenarios_files`, `dl_scenario_front`, `dl_scenario_field`, `dl_scenario_list`,
  `dl_scenario_problems`, `dl_scenarios_validate`, `dl_scenarios_count`, `dl_scenarios_required_count`,
  `dl_scenarios_share_ok`, and for the stage
  `dl_scenarios_judge_command`, `dl_scenario_sealed`, `dl_scenario_affected`, `dl_scenario_verdict`.

**The scenario stage** (`scripts/scenario-stage.sh`, run by `gate-train.sh` as the stage `scenarios`
whenever `scenarios` is configured):

- **When:** after the checks pass (a failed check prints `scenarios skipped`), or alongside them with
  `parallel`; `fail_fast` stops it like a check. It runs in the gate worktree on the train's top, heavy
  unless `"heavy": false` in the `scenarios` block. An empty store judges nothing and starts nothing.
- **`scenarios.run`** starts the system against fakes in its own process group; the first line it prints
  is how to reach it (a URL, a command), passed to the judge as `DL_SCENARIO_TARGET`. It may keep running
  (a server in the foreground) or exit after printing. It is stopped when the stage ends. Ending before it
  prints a line, or printing nothing in `scenarios.run_seconds` (default 120), is red. Without `run` the
  target is empty. Keep servers as its children: one that daemonizes into its own session (`setsid`, a
  double fork) leaves the process group and is not stopped; stop it yourself (see Stopping below).
- **`scenarios.judge`** judges one scenario, run once per scenario with `DL_SCENARIO_FILE`,
  `DL_SCENARIO_ID` and `DL_SCENARIO_TARGET`; its last line that starts with `{` is the verdict
  `{"id", "satisfied": 0..1, "required", "evidence", "missing"}`. The default is headless Claude Code with
  the [`scenario-judge`](agents/scenario-judge.md) agent on `models.scenario-judge`: `claude -p "<prompt>"
  --agent dev-loop:scenario-judge --model <model> --permission-mode dontAsk
  --allowedTools=Read,Grep,Glob,Bash --add-dir=<the scenario's folder> ...` (the prompt right after `-p`,
  and `=` on the options that take several values, so none of them takes the prompt). Output without a
  valid verdict (no JSON object, another id, `satisfied` not from 0 to 1, a non-zero exit, or a run longer
  than `scenarios.judge_seconds`, default 600, after which its process group is stopped) counts as 0.
- **Rejudge:** a scenario below `scenarios.pass` is judged once more; its better run counts, so it fails
  only when both runs fail.
- **Green** needs every required scenario at `>= scenarios.pass` and the mean of all judged scenarios at
  `>= scenarios.min_satisfaction`. Red prints `scenario <id> unsatisfied (<score>, required|scored):
  <missing>` for each unsatisfied scenario that is not sealed, then `scenarios red: <n> judged, <k>
  required unsatisfied, mean ...`, where `<k>` counts only the required scenarios that are not sealed;
  `TRAIN RED` follows. The `missing` line is what goes back to the implementer; the scenario text never
  does, and the stage never prints it.
- **Sealed:** `scenarios.sealed` is the share of scenarios that are only counted (`scenarios sealed: <n>
  judged, <k> unsatisfied`), never named and never described, as a check on overfitting to the feedback.
  A sealed required failure makes the train red through this count alone; it is not in the red line's
  required count.
  A scenario is sealed when the checksum of its id modulo 1000 is below `sealed * 1000`, so the choice
  depends only on the id; `dl_scenario_sealed <file|id> [share]` (default `scenarios.sealed`) tells.
- **With `affected`:** only the scenarios with a `spec` or `tags` item that occurs in a path the train
  changes (`DL_CHANGED_FILES`, ignoring case) run, plus every required one.
- **Invalid store:** any invalid scenario file makes the stage red (`scenarios red: <n> invalid scenario
  file(s)`, without naming them; `doctor.sh` does).
- **Logs** (`paths.sh logs`): `train-scenarios.log` (the stage's lines, safe to forward),
  `train-scenario-results.jsonl` (one line per judge run: `scenario`, `run`, `sealed`, `valid`, the
  judge's `result` JSON or the `error`), `train-scenario-judge/` (each judge run's own output) and
  `train-scenarios-run.log`. The last three hold the judge's evidence, sealed ids and their results, and
  whatever the system printed: **never show them, or the logs directory, to an implementer**, a
  test-engineer or a code-reviewer; they are for the human. Forward only the `missing` text of a
  `scenario <id> unsatisfied` line.
- **Stopping:** when the stage ends, or the gate stops it (`fail_fast`, or a signal), it stops the
  system's and a running judge's process groups: SIGTERM, SIGKILL after 2 s, inside the gate's grace
  period (`DEV_LOOP_STOP_GRACE_SECONDS`, default 10). With a grace period under 3 s the gate may kill the
  stage first and the system's session is left running. The stop reaches only the process group
  `scenarios.run` started: a daemon that calls `setsid` (or otherwise starts a session of its own) escapes
  it and keeps running. Have `scenarios.run` keep its servers in the foreground, or let it stop its own
  daemons (a `trap` on TERM that kills them, or a pid file the next run reads).

### Isolation: the agent-type guard

The isolation is the role guard hook (PreToolUse), by agent type. With scenarios on (a `scenarios` block,
or `"factory": "dark"` without `"scenarios": false`), identity mode or not, it refuses `Read`, `Grep`, `Glob`, `Edit`, `Write`, `MultiEdit`, `NotebookEdit` and Bash
calls by the `implementer`, `test-engineer` and `code-reviewer` agents that name a path inside
`scenarios.dir`: absolute, with `~` or `$HOME`, relative to the working directory (also after a `cd` in
the same command), through a symlink into the store, or a shell glob that matches a file in it. The main
session, the `scenario-judge`, the `scenario-writer` and every other agent type are allowed. With
scenarios off it refuses nothing. The guard resolves the store like `paths.sh scenarios`.

There is deliberately no deny rule for the store in `templates/settings.json`: deny rules apply to every
agent, so they would block the judge too.

Limits, honestly: this is best effort, like the identity-mode guard. It reads the command line, not what
runs: a script the agent writes that opens the store, a path built from pieces at run time, or a recursive
search of a directory above the store (`grep -r x ~/.dev-loop`) is not caught. Keep the store outside
every worktree (the default) so ordinary searches never reach it; for strong isolation run the coding
agents as an OS user that cannot read the store.

**Identity mode:** keep the scenarios in their own private repository (cloned to `scenarios.dir`). The
implementer, tester and reviewer apps get no access to the scenarios repository: do not install them on
it, so their tokens cannot read it even outside the local guard.

### Writing scenarios

With `scenarios` configured, the orchestrator (the `dev-loop` skill, section 1b)
runs the `scenario-writer` agent (`models.scenario-writer`) at ticket creation, before the implementer
starts:

- **The writer** reads the ticket and the spec sections it cites, never the code, and writes or updates
  scenario files in the store (`paths.sh scenarios`) in the format above. It writes only inside the store
  (its brief's rule; its tools include Bash and Write, which could write elsewhere), never implements and
  never edits the repository. It stops when the store lies inside the repository.
- **The issue** gets the new and changed scenarios as titles only (`id`, title, `required`, new or
  changed), never their text. The user reviews and edits the scenarios in the store.
- **A red scenario** goes back to the implementer as the behaviour that was missing, in one line in user
  terms, never the scenario's text; a sealed one is only counted.
- **Isolation:** the role guard refuses the store to the implementer, test-engineer and code-reviewer and
  allows the `scenario-writer` (see Isolation above). On top of it, the orchestrator never puts the store
  path or a scenario's text in those agents' prompts, and their briefs never name the store
  (smoke-tested), so they are not sent looking for it.
- **`doctor.sh`** lists `scenario-writer` in its models line when `scenarios` is on or
  `models.scenario-writer` is set; without either the line is unchanged.

## Factory preset: collaborative or dark

One plugin, two operating modes. The core loop is the same in both (tickets, worktree implementers, the
batch gate, ordered merges, the heavy queue, identity mode, the role guard); dark mode adds the scenario
stage and moves where the human looks.

```json
"factory": "dark"
```

| | `collaborative` (default) | `dark` |
|---|---|---|
| `scenarios` | off | on: the gate is red until the store holds at least one valid required scenario |
| Where the human looks | PRs, spec wording, decisions | scenarios (new and changed, listed in the issue), outcomes, the verifier's reports |
| PR review | the `code-reviewer` agent; the human may read any PR | the `code-reviewer` agent only; the orchestrator does not ask the human about diffs |
| Scenario changes | optional | written by the `scenario-writer` at ticket creation; a ticket starts only when its scenarios exist |
| `cleanup.sh --apply` | deletes closed and stale branches only with `--include` (the user's OK) | deletes them too |
| stale planned tickets (docs maintenance) | closed as not planned on the user's OK | closed without asking |

- **The preset only sets defaults.** An explicit option always wins: `"scenarios": false` (or `null`)
  keeps scenarios off in a dark factory, and a `scenarios` block sets the store and the stage as usual.
- **The same in every mode:** the stop conditions (credentials, the cost cap, spec contradictions that
  change stored data or behaviour users rely on, real money or orders, production data, deleting history,
  security settings) and deploy timing. Dark means nobody reviews the code, not that nobody is responsible.
- **`doctor.sh`** prints `factory <mode>, scenarios on|off (preset|explicit|default)` when `factory` is
  set, reports any other value as `MISSING factory: ...`, and reports a dark factory whose store has no
  valid required scenario as `MISSING factory dark: ...`. The gate's scenario stage then ends red with
  `scenarios red: factory dark needs a scenario store with at least one valid required scenario`.
- **The role guard** follows the same rule: in a dark factory it keeps the default store hidden from the
  coding agents unless `scenarios` is explicitly off.
- **Going dark** is a normal config change on a branch: the `setup` skill's go-dark step checks the store,
  runs the `scenario-writer` for the open tickets and records the switch in `docs/DECISIONS.md`.
- The functions: `dl_factory` and `cfg_has` (`scripts/lib/common.sh`), `dl_scenarios_setting` and
  `dl_scenarios_ready` (`scripts/lib/scenarios.sh`).

## Configuration: `.dev-loop.json`

Lives at the repository root and is committed. Every key is optional unless marked.

| key | default | meaning |
|-----|---------|---------|
| `base_branch` | `main` | the branch everything merges into |
| `remote` | `origin` | the remote branches are pushed to |
| `fast_check` | none | seconds-long check (format + lint), run by the Stop hook |
| `targeted` | none | command prefixes implementers run while working (e.g. `["go test ./", "pytest tests/", "make test"]`), each starting with an accepted runner form: `permissions.sh` writes one `Bash(<prefix> *)` allow rule per entry and refuses the others with the reason, and the role guard checks the arguments of every command of those runners against the runner's safe list (see Permission modes: targeted commands); without the key nothing changes |
| `format` | none | formats one file; `{file}` is the quoted path (else appended) |
| `format_extensions` | all | only format files ending in one of these (e.g. `[".py"]`) |
| `checks` (required for the gate) | — | the full checks, in order: `{"name", "command", "heavy": true, "summary": "<regex>"}` or a plain command string; names are unique (each is its log file) and `affected` is reserved |
| `affected` | none | a check entry (or plain command) run first, after `gate_setup`; `DL_CHANGED_FILES` names the file listing the paths the train changes against the base (made only when `affected` is set) |
| `parallel` | `false` | run the checks at the same time, each in its own process group (heavy ones in their own slot); results print in config order |
| `fail_fast` | `false` | after the first failure, skip the checks not started and stop the running ones (their whole process group); they print as `<name> skipped` / `<name> stopped` |
| `gate_setup` | none | command run once in the gate worktree before the checks (e.g. `npm ci`) |
| `gate_worktree` | `../<repo>-gate`, or `<worktrees_dir>/gate` | the gate's own worktree (created on first use) |
| `worktrees_dir` | none (siblings `../<repo>-<n>`) | one directory for the loop's worktrees: implementer worktrees at `<dir>/<n>` (`paths.sh worktree <n>`), the gate at `<dir>/gate` unless `gate_worktree` is set; `permissions.sh --apply` lists it in `permissions.additionalDirectories`, so auto mode edits there without a prompt (setup writes `../<repo>-worktrees`; existing sibling worktrees stay where they are); the path is normalized lexically (`..` and trailing slashes removed, symlinks not resolved) |
| `notes_dir` | `~/.dev-loop/<repo>/notes` | PR notes files `pr-<branch with / as _>.md`, outside git, shared by all worktrees |
| `logs_dir` | `~/.dev-loop/<repo>/logs` | gate logs |
| `heavy.slots` | `2` | machine-wide slots for heavy commands |
| `heavy.memory_max` | none | memory cap per heavy command (systemd `MemoryMax`, e.g. `"8G"`) |
| `heavy.port_env`, `heavy.port_base`, `heavy.port_step` | none, `8600`, `10` | the per-slot port variable |
| `heavy.clean_temp`, `heavy.clean_temp_minutes` | `[]`, `120` | stale temp globs (`$USER` is expanded) and their age |
| `heavy.poll_seconds` | `10` | how often a waiting command retries |
| `watchdog.stall_minutes` | `30` | `status.sh`: minutes without an event or output before the verdict is `possibly stalled`; a stage silent for longer (a slow suite that prints nothing until it ends) reads as stalled, so raise it for such suites; the heartbeat confirms before acting |
| `watchdog.wake_minutes` | `25` | the orchestrator's heartbeat: the fallback wake-up while it waits (see Status) |
| `watchdog` | on | `"watchdog": false` turns the heartbeat off (`status.sh` still reads `stall_minutes`, default 30) |
| `stall_minutes` (in a check entry, `affected`, `scenarios`) | none (off) | the gate stops a stage whose log has not grown for this many minutes: `<name> stalled: no output for <n> min`, the train is red; a stage queued for a heavy slot is not stalled |
| `stop_gate.require_clean_tree`, `stop_gate.max_blocks` | `true`, `5` | the Stop hook's rules; the tree check counts untracked files only when newer than the session |
| `merge.method`, `merge.delete_branch` | `squash`, `true` | how merge-train merges; `delete_branch` is the remote branch |
| `merge.union_files` | `[]` (off) | literal paths from the repository root (no spaces, wildcards or backslashes; such entries are skipped with a warning) whose conflicts the gate's stacking and the merge replay resolve by keeping both conflicting hunks whole, the base first, but only conflict hunks where both sides only added lines (`scripts/union-merge.sh`; a merge git does without a conflict is git's own result, diffed with histogram as git's merge does (git 2.43 or later; an older git makes it a conflict); a hunk where a side changed or deleted existing lines, an add/add, a file with a line starting with 32 or more `<`, `|`, `=` or `>`, or a failing driver counts as a conflict), e.g. `["CHANGELOG.md", "docs/DECISIONS.md"]`; any other conflict still stops the train |
| `merge.delete_local` | `true` | merge-train also deletes the local branch (and its clean worktree) after the merge |
| `merge.rebuildable` | `node_modules dist build target out coverage .venv` and the usual caches | ignored directories a merged worktree may lose when it is removed; a worktree with any other ignored file, or a secret or data file inside these (`.env`, keys, certificates, databases, any case; also `id_rsa`, `credentials*`, `secrets*`, which the search inside a `merge.rebuildable_caches` folder skips since vendored code uses such names), is kept |
| `merge.rebuildable_caches` | `node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .next .turbo .parcel-cache` | the names of `merge.rebuildable` whose files also count one by one (a self-ignoring cache with its own `.gitignore` lists its files, not itself); output folders such as `build` or `out` count only as a whole, so results listed one by one keep the worktree |
| `cleanup.stale_days`, `cleanup.keep_days` | `14`, `30` | `cleanup.sh`: when a branch without PR or open issue is stale; how long merged notes and old gate logs are kept |
| `models.<agent>` | `inherit` | the model per agent (`implementer`, `code-reviewer`, `test-engineer`, `verifier`, `doc-auditor`, `architect`, `scenario-writer`, `scenario-judge`): `haiku`, `sonnet`, `opus`, `fable` or `inherit` (the main session's model), see below |
| `github.repo` | from the remote URL | `owner/name` |
| `github.status_context` | `dev-loop/gate` | the commit status the gate posts (identity mode, or `github.post_status: true`) |
| `github.feature_patterns` | `feat/* fix/* chore/* docs/*` | branches implementers may push (identity rulesets) |
| `identities` | none (mode off) | per-role identities, see below |
| `guard` | on | `"guard": false` turns off the role guard's git check (see Permission modes: the git guard); an object (`guard.agents`) keeps it on |
| `guard.agents` | built in | extra agent-type to roles mapping for the role guard (identity mode; not the scenario isolation) |
| `deploy` | none | the deploy command the orchestrator uses |
| `docs.aspects` | none (docs off; `doctor.sh` notes it) | current-state docs: aspect name to a file or folder; at least one turns the docs check on (see Current-state docs) |
| `docs.planned` | none | the planned list (built and planned are kept apart); `doctor.sh` notes rows whose ticket closed |
| `docs.planned_max_days` | none (off) | `doctor.sh` notes a planned row whose ticket is open longer than this with no loop branch; `0` is off |
| `docs.map` | `[]` | rules `{"paths": [globs], "docs": [aspect names]}`; `*` in a glob also matches `/` |
| `docs.max_lines` | `1000` | the size budget per current-state file and journal (`doctor.sh` notes bigger ones) |
| `docs.journals` | `["docs/DECISIONS.md"]` | the append-only journals `docs-archive.sh journal` compacts (see Journals and the archive) |
| `docs.prd` | none | the PRD or spec files, a path or a list: the intent the slice loop cuts into tickets |
| `docs.audit_every` | `10` | run the `doc-auditor` every this many merges (`doctor.sh` notes when one is due) |
| `architecture.check` | none (off) | the command printing the dependency edges `<from> <to>` (paths or component names); set, it turns the architecture ratchet on (see Architecture ratchet) |
| `architecture.cards` | `docs/architecture/` | the folder of the component cards |
| `architecture.baseline` | `docs/architecture/baseline.txt` | the known violations, one per line, sorted |
| `architecture.budget` | none | the default `max_lines` per component (a card may override it) |
| `architecture.cadence` | `20` | run the `architect` every this many merges; also `arch-evidence.sh`'s window without an architect run |
| `architecture.scatter`, `growth`, `co_change`, `co_change_min`, `hotspot`, `cycle`, `fan_out`, `review_rounds` | `3`, `500`, `75`, `3`, `5`, `3`, `5`, `3` | the evidence thresholds (see Merge evidence and the architect) |
| `factory` | `collaborative` | the operating mode, `collaborative` or `dark`; dark turns `scenarios` on by default and lets `cleanup.sh --apply` delete closed and stale branches (see Factory preset) |
| `scenarios` | off (on with `"factory": "dark"`) | a block turns the scenario store and stage on, `false` or `null` keeps them off |
| `scenarios.dir` | `~/.dev-loop/<repo>/scenarios` | the holdout scenario store (see Holdout scenarios) |
| `scenarios.run` | none | the command that starts the system for the scenario stage; its first output line is how to reach it |
| `scenarios.run_seconds` | `120` | how long the stage waits for that first line |
| `scenarios.judge_seconds` | `600` | how long one judge run may take; a longer one is stopped and counts as invalid |
| `scenarios.judge` | the `scenario-judge` agent | the command that judges one scenario and prints its JSON verdict |
| `scenarios.heavy` | `true` | run the scenario stage through `heavy.sh` |
| `scenarios.pass`, `scenarios.min_satisfaction`, `scenarios.sealed` | `0.8`, `0.9`, `0` | the share each required scenario must reach, the mean the train must reach, the share never reported in detail |

### Models per agent

Each agent runs on the model named in `models`, so cheap work can go to a small model and the hard work
to a large one:

```json
"models": { "implementer": "inherit", "code-reviewer": "sonnet", "test-engineer": "sonnet", "verifier": "haiku",
            "doc-auditor": "sonnet", "architect": "opus", "scenario-writer": "opus",
            "scenario-judge": "sonnet" }
```

The orchestrator passes the model on every agent launch (the Agent tool's `model` parameter, which takes
precedence over the agent's own `model: inherit`). A missing agent, or `inherit`, uses the main session's
model. A resumed agent keeps the model it started with. `doctor.sh` prints the resolved models and
reports unknown names. The gate and the heavy-job queue are scripts and use no model, except the scenario
stage's default judge, which passes `models.scenario-judge` to `claude --model`.

Environment overrides: `DEV_LOOP_CONFIG` (config path), `DEV_LOOP_HOME` (state, default `~/.dev-loop`),
`DEV_LOOP_LOCK_DIR`, `DEV_LOOP_HEAVY_SLOTS`, `DEV_LOOP_NO_JQ=1` (read JSON with python3),
`DEV_LOOP_STOP_GRACE_SECONDS` (how long `fail_fast` waits after SIGTERM before SIGKILL, default 10),
`DEV_LOOP_STALL_UNIT_SECONDS` (the length of one `stall_minutes` minute, default 60; for tests).

Script exit codes are documented at the top of each script and in the `gate` and `merge` skills.

## Per-role GitHub identities (optional)

By default everything runs under the user's own GitHub login with zero setup. Identity mode gives each
role its own GitHub identity, and puts deterministic server-side gates around the agents. They are
enforced by GitHub token permissions and repository rulesets, not by prompts.

| role | who | may |
|------|-----|-----|
| implementer | `implementer` agent | contents write (feature branches only, by ruleset), pull requests write (open PRs); cannot push the base branch, cannot approve its own PRs |
| tester | `test-engineer`, `verifier`, `doc-auditor`, `architect` | issues write, contents read: raise tickets, never push code |
| reviewer | `code-reviewer` | pull requests write (approve / request changes), contents read |
| gate | `gate-train.sh` / `merge-train.sh` only | statuses write (the required `dev-loop/gate` status), contents write, merges |
| orchestrator | main session | issues write, read elsewhere |

The test-engineer's tests are committed locally in the worktree; the implementer identity pushes them.

**Server-side gates** (`scripts/github-protect.sh`: dry run by default, `--apply` to apply; idempotent,
rulesets matched by name):

- base branch: a pull request is required, with 1 approval. Stale approvals are dismissed, and the most
  recent push must be approved by someone else, so the last pusher cannot approve. Squash only. The
  `dev-loop/gate` status is required, from the gate app only (its integration id), and the branch must be
  up to date. No force pushes, no deletion. Nobody bypasses (`--admin-bypass` lets repository admins
  bypass through a PR, for emergencies).
- feature branches (`feat/*`, `fix/*`, `chore/*`, `docs/*`): only the implementer and gate apps may
  create, update or delete them.
- other branches: no new branches outside the base and the feature patterns.

Whatever an agent does locally, a PR cannot reach the base branch without the reviewer identity's approval
and the gate identity's status.

**Plans:** rulesets work on public repositories on every plan. On a private repository they need GitHub Pro,
Team or Enterprise.

**Wiring.** `scripts/as-role.sh <role> <command...>` runs one command with that role's credentials. It
sets `GH_TOKEN` for `gh`, and a git credential helper (plus SSH-to-HTTPS rewrites) through `GIT_CONFIG_*`
environment variables that exist only for that command. Token values never appear in config: the config
points to credential files outside the repository. Apps get short-lived installation tokens, minted from
the app's private key with `openssl` and `curl` and cached (user-only) until shortly before they expire.
The gate posts the status and merges as `gate`; implementers push as `implementer`;
`open-pr.sh` opens PRs as `implementer`; the reviewer submits a real
`gh pr review --approve/--request-changes` as `reviewer`. When the merge commit `merge-train.sh` pushes
onto a branch behind the base dismisses an approval, it stops with exit 9. The reviewer then confirms that
the merge commit brings in only the base (`git diff <base> <head>` is the branch's own change) and approves
again; the re-run merges the head already pushed, without another push.

**Identities.** GitHub Apps are recommended: permissions per app, short-lived tokens, they show as
`name[bot]`, and they need no seats. Machine-user accounts with fine-grained PATs also work
(`{"type": "token", "token_file": "..."}`). Ruleset bypass lists take apps, not individual users, though, so
with machine users the feature-branch limit and the status source rest on token permissions alone.

```json
"identities": {
  "implementer": {"type": "app", "app_id": 123, "installation_id": 456,
                  "key_file": "~/.config/dev-loop/<owner>/implementer.pem"},
  "reviewer":    {"type": "token", "token_file": "~/.config/dev-loop/<owner>/reviewer.token"}
}
```

### Per-role identities in 5 minutes

Ask Claude "set up per-role identities" (the `setup` skill prints the exact command with the plugin's
installed path). Then run that command in your own terminal, not through Claude, from the repository and
logged in to `gh` as an owner or admin of the repository:

```bash
<plugin path>/scripts/setup-identities.sh
```

1. For each of the 5 roles, a browser tab opens GitHub's "Register new GitHub App" form, already filled
   in (name, permissions, no webhook). **Click "Create GitHub App".** That is 5 clicks.
2. For each app, its install page opens. **Choose "Only select repositories", pick this repository, click
   "Install".** That is 5 installs.
3. The script stores each private key under `~/.config/dev-loop/<owner>/` (mode 0600), writes the
   `identities` block into `.dev-loop.json` (key paths only), and prints the ruleset plan. **Answer `y`**
   to apply it.
4. Commit `.dev-loop.json`.

It can be resumed and run again safely: apps, keys and installations that already exist are reused. Apps
belong to the owner, so the next repository of the same owner needs only the install clicks. Options:
`--roles "implementer reviewer gate"` (a subset), `--yes`, `--no-protect`.

### Limits, honestly

On one OS user, every agent could in principle read every credential file within reach. The plugin
reduces this, but does not prevent it:

- deny rules for the credential directory and the token cache (`templates/settings.json`);
- a PreToolUse guard that refuses `git push`, `gh pr create/merge/review`, `gh issue ...` and `gh api`
  writes unless they run through `as-role.sh` with a role the agent may use (implementer: implementer,
  code-reviewer: reviewer, test-engineer, verifier, doc-auditor and architect: tester, main session:
  orchestrator).
  It also refuses any direct use of the gate role, any merge, ruleset or auth command, and any mention of
  the credential paths. With `scenarios`, it also keeps the scenario store from the coding
  agents (see Isolation: the agent-type guard). This is best effort: it parses shell commands and cannot see inside scripts the agent writes;
- for strong isolation, run each role under its own OS user (or container) that holds only its own
  credentials.

The guarantees come from GitHub, not from the local guard. Token permissions decide what each identity can
do at all, and the rulesets decide what can reach the base branch. One gap is known: the implementer app
has contents write, so it could merge a PR that already has the reviewer's approval and the gate's status.
That is the same merge the gate would make.

## Permission modes

The loop runs the same in Claude Code's default, auto and bypass permission modes, because setup writes
the rules it needs. `${CLAUDE_PLUGIN_ROOT}/scripts/permissions.sh` lists the missing rules (a dry run);
`--apply` merges them. It only adds rules: every existing rule and key stays. Applying them is the
owner's step, since an agent may not change its own permissions (auto mode refuses it): the dry run ends
with the one command to run, `! ${CLAUDE_PLUGIN_ROOT}/scripts/permissions.sh --apply` with the plugin's
absolute path (the `!` prefix runs it in the session as the owner), and the setup and doctor skills show
the owner that line and wait instead of editing the settings files.

- `.claude/settings.json` (shared, committed) gets the rules of `templates/settings.json` and the project's
  own:
  - **allow:** the read-only git commands, `git fetch`, `git worktree`, `git add`, `git commit`; exactly
    `git rebase <remote>/<base>`, `git rebase --continue`, `--abort` and `--skip` (any other rebase, such
    as `--onto`, asks); `gh issue` and `gh pr` `view`, `list`, `create`, `comment`, `edit` (and `gh issue close`,
    `gh pr diff`, `gh pr checks`); exactly `git push -u <remote> HEAD`, the one push the loop makes (the
    implementer pushes its checked-out branch in this form); one exact rule for each command of
    `fast_check` and `checks` (a compound command `a && b` gets one rule per part); with `targeted`, one
    `Bash(<prefix> *)` per accepted entry (`Bash(<prefix>*)` when it ends in `/`), whose arguments the
    guard checks (below).
  - **ask**, matched anywhere in a command (also after `git -C <dir>` or `git -c <key>=<value>`): `git tag`,
    `gh release`, pushes with `--tags`, `--follow-tags`, `refs/` (tags and heads), `--mirror`, `--all`,
    `--delete` or `-d`, a push naming the base branch (`<base>`, `:<base>`), a push deleting a loop branch
    (`:feat/...`), `git worktree remove --force` or `-f`, `git rebase --exec` or `-x`, `git fetch` and
    `git pull` with `--upload-pack` or after `git -c <key>=<value>` (each runs a command of its own).
  - **deny**, matched anywhere the same way: force pushes (`--force`, `--force-with-lease`, `-f`, `+<ref>`,
    `:+<ref>`), `gh repo delete`, `gh pr merge --admin`, `sudo`, `.env` and role credentials.
- `.claude/settings.local.json` (this machine only; `permissions.sh --apply` adds it to `.gitignore`) gets
  the plugin's scripts at this machine's plugin path, with the version as a wildcard
  (`~/.claude/plugins/cache/<marketplace>/dev-loop/*/scripts/gate-train.sh *`, written as an absolute
  path), so the rules outlive plugin updates; `cleanup.sh --apply` asks. `heavy.sh` and `as-role.sh` run
  the command they are given, so they are allowed only for the loop's own uses: `heavy.sh <command>` for
  each project command, and `as-role.sh implementer git push -u <remote> HEAD`. Its
  `permissions.additionalDirectories` gets the absolute directories the loop writes with the Write and
  Edit tools outside the project: the notes directory (implementers write their notes file there) and,
  with `worktrees_dir`, that directory and a gate worktree outside it. Auto mode and acceptEdits approve
  edits only in the working directory and these directories; the project's parent directory (or any
  directory that holds the project) is never added, since it would open every sibling project.

In the **default** mode the allow list is what keeps background agents from stalling on a prompt. In
**auto** mode the rules decide before the classifier does. In **bypass** mode allow rules have no effect,
but deny rules still block and ask rules still ask. So in every mode releases, tags and tag pushes ask and
force pushes are refused. Anything else outside the repository is in no allow rule, so it asks in the
default mode; in auto mode the classifier judges it; in bypass mode only the stop conditions in `CLAUDE.md`
hold it back.

Claude Code merges the rules of every settings file, and a deny anywhere wins. `doctor.sh` reads only the
project's `.claude/settings.json` and `.claude/settings.local.json` (their `permissions`; of the user's own
files only the ask rules, below): a deny rule that blocks a command the loop runs is `MISSING`; a missing allow list, or one that
lacks the current `fast_check` and `checks` commands or other loop rules, is a note; complete rules print
nothing. A deny rule that blocks a tag, a release or a tag push is `MISSING` too, since no release could be
made even on the owner's go; the fix is to move it to `ask`, as the template does. The forms it tests are
`git tag v1.2.3`, `git tag -a`, `git tag -s` and `git tag -m` (each with `-m`), `gh release create v1.2.3`,
`git push <remote> v1.2.3`, `git push <remote> refs/tags/v1.2.3`, `git push <remote> tag v1.2.3`,
`git push <remote> --tags`, `git push --tags`, `git push --tags <remote>`, `git push --follow-tags` and
`git push <remote> --follow-tags`, with `<remote>` the configured remote and also `origin` when that
differs. A deny that blocks a loop command is reported in either settings file, also without
`.claude/settings.json`; one that also blocks a tag push (such as `Bash(git push:*)`) is reported once, as
blocking the loop. Without `.claude/settings.json` it prints one note; its notes name the owner's apply
line. A notes directory, a `worktrees_dir` or loop worktrees outside the project and not in
`additionalDirectories` are `MISSING` (in auto mode every edit there asks); sibling worktrees of the old
layout are a note once `worktrees_dir` is set. An ask rule that matches a command the loop runs or one
`.dev-loop.json` configures (`fast_check`, `checks`, `affected`, `gate_setup`, `format`) is a note naming
the file, the rule and the command: auto mode stops for confirmation on it every time, and since
ask beats allow, the fix is to narrow the rule (e.g. to the paths it guards). The gate and the format hook
run `gate_setup`, `affected` and `format` outside the Bash tool, so a rule that matches only those is
worded for them: it stops only when an agent runs that command itself through the Bash tool. For this check it also
reads the `permissions.ask` list of the user settings (`DEV_LOOP_CLAUDE_DIR`, default `CLAUDE_CONFIG_DIR`, else
`~/.claude`), and nothing else there. The template's ask rules match none of these commands.

A wildcard cannot exclude arguments: `git push -u origin feat/*` would also match
`git push -u origin feat/x:main` or `... --tags`. So the only push allowed is the exact one, and the ask
and deny rules match dangerous arguments anywhere as a second line. The same limit applies to the other
wildcard allow rules: `git diff`, `git log` and `git show` accept `--output=<file>` (they write a file),
and `git fetch +<ref>:<ref>` force-updates a local branch. Options that run a command
(`git rebase --exec`/`-x`, `git fetch`/`git pull` `--upload-pack` or `-c`) ask instead. Text rules miss
other spellings of the same option, so the git guard below checks the parsed command as well. The `Read` and
`Edit` deny rules on `.env` cover only those tools: a Bash command such as `cat .env` is not stopped by
them (in the default mode it asks, since no allow rule matches it); the `CLAUDE.md` rule not to read
`.env` files stays the guard.

### The git guard

The git guard is a tripwire, not the boundary. It stops an agent that slips into a git command a stop
condition forbids, and it tells the agent why. It cannot stop an agent that sets out to get around it,
for example with a script it writes and then runs. The real control for the base branch and the tags is
the remote's branch and tag protection (`github-protect.sh`, or the host's own rules), so set that up.

Git accepts many spellings of one option: a unique prefix (`--upl=<cmd>` is `--upload-pack`), bundled
short flags (`-fx <cmd>` is `-f -x <cmd>`), quotes and backslashes (`'-f'`, `\-f`, `--fo\rce`). A text
rule cannot see through them, and `git push -u <remote> HEAD` pushes the base branch when run from a
checkout of it. So the role guard hook (PreToolUse) reads every Bash command in a loop project that names
git. A command names git when it contains the text `git` in any case (so `GIT_*` variables count too) once
quotes, backslashes, braces, commas and line continuations are removed and `$'...'` escapes are decoded,
or when it has a glob that may match `git` (`gi?`, `g[i]t`).

**It fails closed: only plain command lines pass.** A command that names git is checked only when it is
a plain command line. That means literal words (quotes and backslashes are fine, and a leading `~` is the
home directory) joined by `&&`, `||`, `;`, `|` or newlines, plain redirections (`>x`, `2>&1`, `<x`,
`<<<word`), and here-documents whose body expands nothing: a quoted end word (`<<'EOF'`), or an unquoted
one whose body has no `$`, backtick or backslash. Anything else that names git is refused with "write it
plainly", even when nothing in it is dangerous. That covers:

- a `$` outside single quotes or a backtick (variables, `$( )`, `${ }`, `$[ ]`, `$'...'`), a `{`, `}`, `(`
  or `)` outside quotes (brace expansion, groups, subshells, functions), a lone `&`, an unbalanced quote, a
  compound command (`if`, `for`, `while`, `case`, `!`, `[[`, ...) and a here-document without its end line;
- a program that runs a command string: `alias`, `eval`, `builtin`, `command`, `exec`, `source`, `.`,
  `trap`, `watch`, `script`, `flock`, `su`, `sudo`, `busybox`, `xargs`, `parallel`, a shell (`sh`, `bash`,
  `zsh`, ...) given an option or no script file (`bash -c '...'`, `echo ... | bash`), `env -S`,
  `find -exec`/`-ok`, `rg --pre`, `man -H`/`-P`/`--html`/`--pager` and `gh alias`;
- text that reads as a git command (`git push ...`) handed to a program the guard does not know
  (`python3 -c "... git push ..."`, `ssh host 'git push ...'`), as an argument, a here-document or through
  a pipe. Only git, gh and programs that never run their arguments (`echo`, `printf`, `grep`, `cat`, `ls`,
  `head`, ...) may take such text, so commit messages and PR bodies still pass;
- a `cd`, `pushd` or `popd` the guard cannot follow (`cd -`, a glob, one in a pipeline such as
  `cd x | git push`). `cd x & git push` is refused for its lone `&`. Both are refusals on the safe side.

So a commit message goes in as `git commit -F - <<'EOF'` (a quoted end word), not as
`git commit -m "$(cat <<'EOF' ...)"`, and a PR body as `gh pr create --body-file - <<'EOF'`. The loop's own
commands are already plain. Commands that do not name git are not touched by this rule.

**On a plain command line** the guard splits the simple commands and skips variable assignments and the
wrappers `env` (whose `-C`/`--chdir` it follows), `time`, `nohup`, `nice`, `timeout`, `stdbuf`,
`as-role.sh <role>` and `heavy.sh`. It follows `cd`, `pushd`, `popd` and `git -C <dir>`. A `cd` that may
fail or be skipped (`cd x; git push`, `cd x || git push`) leaves the directory before it possible, so the
push is checked in both. Under a program it does not know, every word `git` (or `git-<name>`) starts a git
command, wherever it stands. The guard expands bundled short flags and resolves long-option prefixes
against the options of `fetch`, `pull`, `rebase`, `diff`, `log`, `show`, `worktree remove` and `push` (a
prefix that may mean a dangerous option counts as that option). It refuses the following, with exit 2, the
command, the stop condition and "ask the owner":

- `git -c <key>=<value>` or `--config-env` before any subcommand (config can run a command: aliases,
  pagers, `core.sshCommand`), and `git --exec-path=<dir>`;
- an assignment or `export` of `GIT_*` (`GIT_DIR`, `GIT_CONFIG_*`, ...), `PATH`, `HOME`, `CDPATH`,
  `XDG_CONFIG_HOME`, `BASH_ENV`, `ENV` or `LD_PRELOAD`, as a prefix, on its own or through `env`;
- `git config` that is not a read (`--get*`, `--list`/`-l`, `get`, `list`), since an alias or other config
  can run any command;
- `git submodule foreach`, `git bisect run` and `git filter-branch`, which run command strings;
- `fetch` or `pull` with `--upload-pack`, and `push` with `--receive-pack` or `--exec`;
- `rebase --exec`/`-x`, and a rebase whose rewritten branch is the base branch (the branch argument, else
  the branch checked out where it runs; `--continue`, `--abort`, `--skip` and `--quit` pass);
- `diff`, `log` or `show` with `--output`;
- `worktree remove --force`/`-f`. The owner runs it with Claude Code's `!` prefix (in the session, as the owner)
  (`! git worktree remove --force --force <path>`), as the setup skill's migration step says;
- a push or rebase with `--git-dir` or `--work-tree` (another repository's branch, maybe the base);
- a push that forces (`--force`, `--force-with-lease`, `--force-if-includes`, `-f`, `+<ref>`), deletes
  (`--delete`, `-d`, `:<ref>`, `--prune`), tags (`--tags`, `--follow-tags`, `tag <name>`, `refs/tags/...`
  or a tag name), pushes everything (`--all`, `--branches`, `--mirror`, a refspec with a glob), has more
  than 50 refspecs, or whose source or destination is the base branch (`<base>`, `heads/<base>`,
  `refs/heads/<base>` in any case, and `HEAD`, `@` or no refspec when the base is checked out in a
  directory the push may run in, from `git rev-parse --abbrev-ref HEAD`).

The text checks run on every refspec before any git process starts. The branch checked out and the local
branches and tags (one `git show-ref`) are read once per directory, so even a 100 KB command is checked in
well under a second.

The base branch is `base_branch` from `.dev-loop.json` (default `main`). The check is on in every project
with `.dev-loop.json` (not only with scenarios or identities) and off with `"guard": false`. Projects
without `.dev-loop.json` are not checked. A crash of the guard on a command naming git refuses it, and
so does a Bash event it cannot read (truncated, not UTF-8) whose text names git; a `tool_input` that is
not an object is read as the command. A
differential test (`tests/guard-diff.py`) runs a fixed corpus and seeded random shell texts through bash
with a stub `git`, and fails when bash would push to the base branch and the guard lets it through. A Bash
call that does not name git starts no git process. The ask and deny rules stay as a second layer. `gh`
commands are outside the git guard: the permission rules (and, in identity mode, the role checks) cover
gh writes such as `gh pr merge`, `gh api` and `gh release`.

What the guard does not catch, by design or because it reads only the command text:

- a command that builds the name git without spelling it (`a=g; b=it; $a$b push`, `$(printf ...)`): the
  plain-line rule applies only to commands that name git;
- a script or other file the agent writes (with the Write tool, or `echo ... > x.sh`) and then runs
  (`bash x.sh`, `make`, a test runner), and commands a program reads from a file;
- aliases and functions from the user's shell profile, git aliases, hooks and `push.default` or
  `remote.<name>.push` already in the repository's config, and the session shell's `CDPATH`;
- rewrites of the base branch that stay local: `git branch -f <base>`, `git update-ref refs/heads/<base>`
  and `git reset --hard` on it pass on purpose, since nothing leaves the machine and a later push of the
  base is refused.

The identity and scenario checks use their own best-effort splitter. A command that names git but that
splitter cannot split (an unbalanced quote) is refused there with "cannot be parsed; ask the owner", also
with `"guard": false`. A command without git that cannot be split is not refused for that.

The guard hook and the permission rules are tripwires on the agent's command line; no text match is complete
against full shell syntax. The boundary is the remote's branch and tag protection, so `doctor.sh` reads it
(read only, through `gh api` GETs on a github.com remote, each stopped after `DEV_LOOP_GH_TIMEOUT` seconds,
default 10): one `ok` line when the base branch requires a pull request (or is locked) and blocks force
pushes and deletion, through branch protection that includes administrators or a ruleset, and active tag
rulesets on `refs/tags/v*` restrict creating, updating and deleting release tags, with no bypass for the
current gh login (in solo mode the agent runs as the owner, usually an admin); otherwise a note naming what
is missing. The owner adds them in the repository's Settings > Rules > Rulesets (a branch ruleset for the
base with "Require a pull request", "Block force pushes" and "Restrict deletions"; a tag ruleset for
`refs/tags/v*` with "Restrict creations", "Restrict updates" and "Restrict deletions"; no bypass list), or
with `gh api -X POST repos/<owner>/<repo>/rulesets --input <ruleset.json>`. Without `gh`, logged out,
without the right to read it, with no answer or an answer that is not JSON, or on another host (also a
`github.api_url` for GitHub Enterprise), the note says it could not be checked; it is never `MISSING`.

The deny rules match text, not meaning: `*git*push*--force*` and `*gh pr merge*--admin*` also refuse a
commit message or PR body that quotes such a command. Write those messages without the literal flag, or
pass the text in a file (`git commit -F <file>`, `gh pr create --body-file <file>`).

The project's own commands are trusted: `fast_check` and each `checks` command become allow rules as they
are written. A command containing `*`, `?` or ending in `:*` becomes a wildcard in its rule (`*` matches any
text; a trailing `:*` matches any arguments), so keep those commands free of such characters or accept the
broader rule. The rule syntax the plugin relies on is in `docs/DECISIONS.md`.

### Targeted commands

While implementing, the loop runs targeted tests and formatters (`go test ./pkg -run TestX`,
`pytest tests/test_x.py -k y`, `gofmt -l f.go`, `make test`); without a rule each one asks in auto mode. A
runner wildcard such as `Bash(make *)`, `Bash(go *)` or `Bash(python3 *)` stops the prompts but runs
anything: `make --eval=...`, `make -C ../other`, `make test CC=<cmd>`, `go test -toolexec`/`-exec`/`-o`,
`go env -w` (machine-wide), `pytest -p <plugin>`, `npm test --script-shell=<cmd>`, `npx <package>`,
`python3 -c`. Ask rules cannot fix that: Claude Code's patterns cannot say "any option except these", and
a runner accepts abbreviations (`make --ev`), bundles (`-kC..`), quoting (`'-o'`), tabs and options no list
names. So the plugin pairs a narrow allow rule with the role guard, which sees the parsed argv.

List the exact prefixes in `"targeted"` (`.dev-loop.json`). Each entry must start with an accepted runner
form; `permissions.sh` writes `Bash(<prefix> *)` (or `Bash(<prefix>*)` when the prefix ends in `/`, so
`"go test ./"` allows `go test ./pkg`) into `.claude/settings.json`, and refuses any other entry with the
reason: a path as the program (`./make test`, `/usr/bin/go test`), an interpreter (`python`, `node`, ...),
a shell (`bash -c`), `npx` and its kin, git (the template's exact git rules and the git guard stay in
charge), a bare `make` or `npm run` (name the target or script), an argument off the safe list
(`"go test -toolexec=x"`, `"make test CC=x"`), shell metacharacters, quotes or a wildcard. Without
python3 no entry is written, since the guard runs on python3. `doctor.sh` notes each refused entry.

The role guard then reads every Bash call of the project. For each simple command whose argv starts with
the runner form of an accepted entry (the program by its name, so `/usr/bin/go test` counts; after the
wrappers `time`, `nohup`, `nice`, `timeout`, `stdbuf`), every following argument must be a plain path,
package or test pattern, or a flag on that runner's safe list, with its value where it takes one. The safe
lists, one table in `hooks/guard-role.py`:

| Runner form | Safe flags |
|-------------|------------|
| `go test` | `-run`, `-skip`, `-count`, `-v`, `-race`, `-short`, `-timeout`, `-failfast`, `-cover`, `-covermode`, `-parallel`, `-cpu`, `-bench`, `-benchtime`, `-benchmem`, `-json`, `-shuffle`, `-tags` |
| `go vet` | `-json`, `-tags` |
| `gofmt` | `-l`, `-d`, `-s`, `-e`, `-w` |
| `pytest`, `python -m pytest`, `python3 -m pytest`, `uv run pytest` | `-k`, `-m`, `-x`, `-q`, `-v`, `-s`, `-l`, `-r`, `-n`, `--lf`, `--ff`, `--last-failed`, `--failed-first`, `--exitfirst`, `--quiet`, `--verbose`, `--maxfail`, `--tb`, `--durations`, `--no-header`, `--showlocals` |
| `npm test`, `pnpm test`, `yarn test`, `npm run <script>`, `pnpm run <script>`, `yarn run <script>` | `--silent` |
| `cargo test` | `-q`, `--quiet`, `-v`, `--verbose`, `--release`, `--lib`, `--bins`, `--tests`, `--doc`, `--no-fail-fast`, `-p`, `--package`, `--test`, `--features`, `-F`, `--all-features`, `--no-default-features`, `--workspace`, `-j`, `--jobs`, `--locked`, `--offline` |
| `cargo fmt` | `--check`, `--all`, `-p`, `--package`, `-q`, `--quiet`, `-v`, `--verbose` |
| `make <target>` | `-j` (with an attached or a separate number), `--jobs`, `-k`, `--keep-going`, `-s`, `--silent` |
| `ruff check`, `uv run ruff check` | `--fix`, `--diff`, `-q`, `--quiet`, `--statistics`, `--no-cache` |
| `ruff format`, `uv run ruff format` | `--check`, `--diff`, `-q`, `--quiet`, `--no-cache` |

Go flags take one or two dashes and `-flag=value`; the others take bundled short letters (`-xvs`,
`-kEXPR`), `--long` and `--long=value`. A flag matches only as written in the table, so an abbreviation
(`--ev`, `--basete`) or a flag the table leaves out (`-test.testlogfile=`, `-compiler`, `--basetemp`,
`-p`, `--prefix`, `--target-dir`, `-Z`) is refused; so is `--`, which hands what follows to the runner or
the test binary. A plain argument may not start with `-` or `+`, hold `=` (`make` and `npm` read
`VAR=value` as a setting), a blank or a control character, or be an unquoted glob (the shell expands it,
maybe to a file named like an option). A path, absolute or relative, must stay inside the worktree the
command runs in (`..` and symlinks resolved; `~` is the home directory, so `~/x` is outside). The guard
follows `cd`, `pushd` and `popd` like the git guard, and refuses a targeted command that may run outside
the worktree (`cd ../other && make test`), an output redirection to a file outside it (`> /tmp/out`;
`/dev/null` and `2>&1` pass), a variable set before the runner (`GOFLAGS=...`, `MAKEFLAGS=...`, through
`env` too), a runner started through a program that runs commands (`xargs`, `command`, `exec`, `sudo`,
`bash -c`, ...), and a command line naming a targeted runner that is not plain (a `$` or backtick
expansion, braces, a subshell). A refusal names the argument and the runner forms and says to ask the
owner. The project's exact `fast_check` and `checks` commands pass as written (they have their own exact
rules). The check is on whenever `targeted` lists an accepted entry, also with `"guard": false`; a runner
form no accepted entry names is not checked (it has no allow rule, so it asks as before).

The limit, plainly: **a targeted test still runs the project's own test code.** `go test` runs the
package's tests, `make test` runs the recipe in the Makefile, `npm test` runs the package's script, and
pytest loads `conftest.py`. The guard keeps the runner from running other programs or touching paths
outside the project through its options; it does not judge what the project's code does, and an agent can
still change that code before it runs it. Like the git guard it is a tripwire, not the boundary.

`doctor.sh` notes each allow rule in the project's two settings files (never the user's own) that wildcards
a runner, an interpreter or a git subcommand with destructive options, with the reason: `make *`, `go *`,
`go test *`, `go env *`, `npm *`, `npm run *`, `npm test *`, `npx *`, `pnpm *`, `yarn *`, `cargo *`,
`python *`, `python3 *`, `node *`, `uv run *`, `pytest *`, `bash *`, `sh *`,
`git branch|checkout|restore|switch|stash|reset|clean *`, anything broader such as `Bash`, and any other
wildcard after a runner's name (`Bash(make test *)` without `targeted`). A rule `permissions.sh` wrote for
an accepted entry is not noted. The notes are read only: the owner removes the rule.

## Safety notes

- Agents never read `.env` or credential files, and never write secrets or personal identifiers (real user
  names, account numbers, emails, private hostnames) into the repository, commits, issues or PRs.
- Merges happen only through `merge-train.sh` after a green gate, and never with `--admin`.
- The role guard refuses git commands that hit a stop condition, however their options are spelled
  (see Permission modes: the git guard); `"guard": false` turns that check off.
- With `targeted`, the role guard refuses a targeted runner's arguments that are off its safe list or
  leave the project (see Permission modes: targeted commands). A targeted test still runs the project's
  own test code.
- The plugin touches only the repository, its gate worktree, `~/.dev-loop/<repo>/`, the heavy-slot lock
  directory, and, in identity mode, `~/.config/dev-loop/`. `status.sh` only reads them.
- The scripts never push to the base branch directly, and nothing in the loop force-pushes. The merge
  pushes a feature branch only as a fast-forward of the gated head (a merge commit with the gated tree), so
  the remote refuses it when commits were pushed after the gate. Agents re-push a rebased branch as
  `<branch>-vN` with `repush.sh`.

## Developing the plugin

```bash
make check     # manifests, shellcheck, ruff, then tests/smoke.sh and tests/identity.sh (no network)
```

`tests/smoke.sh` builds a throwaway repository with a local bare origin and a fake `gh`. It covers the
hooks, the heavy queue (3 jobs on 2 slots, a killed job's slot), the gate, the merge, a red train, the
tree check, a branch that moved, a conflict, the gate options (affected, parallel, fail_fast), and
`status.sh` with the event log. `tests/identity.sh` adds fake GitHub API, browser and `gh` stand-ins. It covers
`as-role.sh`, app JWTs and tokens, the guard, the ruleset plan, the manifest flow and identity-mode merges.

Each run makes its own work dir under `TMPDIR` and removes it when every test passed; a red run keeps it
and prints its path, and `DEV_LOOP_KEEP_WORK=1` keeps it always. The gate keeps only the newest red work
dir of each suite. To run part of the smoke test, name sections:

```bash
tests/smoke.sh --list                    # each section's id, the sections it needs, its title
tests/smoke.sh --section 20 --section 'Script help'
```

`--section` takes a section number (`11`, `11b`) or text from one of the section's comment lines, and runs
the shared setup, that section and the earlier sections it needs (`smoke_needs` in the script's header),
then the summary. A new section that uses the state or helpers of an earlier one adds a line there.
A section starts at a `# <n>. ` or `# <n><letter>. ` line at column 0; one numbered below the previous
section makes every mode print that header and exit 2 before running anything, and `make lint` runs
`tests/smoke.sh --list` to catch it. A numbered list inside a section is indented (`#   1. `); so is a
`# <n>. ` line inside a here-document in a test, which at column 0 counts as a header and fails the check.

## License

MIT, see [LICENSE](LICENSE).
