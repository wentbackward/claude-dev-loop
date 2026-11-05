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

```text
/plugin marketplace add wentbackward/claude-dev-loop
/plugin install dev-loop@claude-dev-loop
```

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
- deny rules in `.claude/settings.json` (force pushes, `sudo`, `.env`, role credentials, ...);
- Makefile targets that are missing (`fmt`, `fmt-check`, `lint`, `typecheck`, `test`, `cov`, `check`,
  `e2e`).

`/dev-loop:doctor` (the script: `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh`) checks the prerequisites and
prints the paths it resolved.

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
   drops out of the train and is rebased after the others merge.
5. **Merge.** `merge-train.sh b1 b2 ...` replays each branch on the current base and checks that its tree
   is exactly the gated tree. It pushes the branch, opens the PR from the notes file (a leading `#` in the
   title is stripped) and squash-merges exactly that head. If the base moved in between, it asks for a new
   gate.
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
| skill | `setup` | bootstrap a project (CLAUDE.md, DECISIONS.md, `.dev-loop.json`, deny rules, Makefile) |
| skill | `gate` / `merge` | run the batch gate and the ordered merge, and read their results |
| skill | `doctor` | check the machine and the project (`/dev-loop:doctor`), and explain each problem's fix |
| agent | `implementer` | one ticket, test first, in its worktree; pushes and writes the notes file |
| agent | `code-reviewer` | strict independent review; must fix / should fix; verdict |
| agent | `test-engineer` | failing tests from the acceptance criteria, before the code |
| agent | `verifier` | read-only audit of a real run's outputs |
| agent | `doc-auditor` | read-only audit of the current-state docs and component cards; one ticket per drift |
| script | `docs-check.sh` | checks a range keeps the current-state docs true (see Current-state docs) |
| script | `arch-check.sh` | checks a commit against its component cards and the baseline (see Architecture ratchet) |
| script | `cleanup.sh` | classify every branch and remove merged and abandoned leftovers (see Branch lifecycle) |
| hook | format-on-edit | runs `format` on each edited file (PostToolUse) |
| hook | stop gate | blocks the stop while `fast_check` is red or work is uncommitted; gives up after 5 blocks |
| hook | role guard | identity mode only: GitHub writes only through `as-role.sh` with the agent's role (PreToolUse) |

All hooks do nothing in a project without `.dev-loop.json`, so the plugin is safe to install globally.

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
- **Implementers run targeted tests only.** The agent brief and the loop say so: tests for what they
  touched plus the fast check. Anything heavy goes through `heavy.sh` or is left to the gate.
- **The Stop hook runs only `fast_check`**, which takes seconds. Running the full suite on every stop
  would delay every reply.

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
pushed head, gated head and tree, PR, merge commit, time). `scripts/cleanup.sh` classifies every local and
remote branch from the ledger, then the PR list (a replayed copy counts when it brings the same changes),
then the issue its name points at (`<type>/<n>-...`):

| Class | What | `--apply` |
|---|---|---|
| merged | in the ledger or a merged PR at this tip (or a replayed copy with the same changes); a local loop branch the base contains | deleted |
| helper | local `train-*`/`replay-*` refs of loop branches outside a live train, local agent worktree branches without own commits | deleted |
| closed | PR closed unmerged at this tip, or its issue closed as not planned | with `--include closed` (the user's OK); automatic with `"factory": "dark"` |
| stale | no PR, no open issue, idle for `cleanup.stale_days` (remote: loop branches only) | with `--include stale`; automatic with `"factory": "dark"` |
| keep | open PR or issue, checked out in a worktree, a live train, recent, moved on after its PR, or a remote branch outside the loop (`develop`, `release-*`) | never |

Branches outside the loop are never judged by PRs or the ledger: locally they can only be stale, remotely they are always kept. `main`, `master`, `develop`, `trunk` and the remote's default branch are always kept. The gate deletes only `train-*` refs of loop branches.

Loop branches are the ones matching `github.feature_patterns` (default `feat/* fix/* chore/* docs/*`).
Every deletion is conditional on the tip that was classified (`update-ref` with the old value, a push
lease on the remote), and the count printed is read back from the result. Needs git 2.9 or later.

It is a dry run without `--apply` (it still fetches with `--prune`), writes the full classification (with the reason for every kept
branch) to the logs directory, and saves every deleted tip to a bundle in `~/.dev-loop/<repo>/archive/`
first and checks the bundle holds each one: `git fetch <bundle> refs/heads/<branch>:refs/heads/<branch>`
restores one (a remote-only branch: `refs/remotes/<remote>/<branch>`). Old gate logs and cleanup reports
go after `cleanup.keep_days`; other files in the logs directory are never touched. `doctor.sh` notes
leftovers it can count without GitHub.

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
  "audit_every": 10
}
```

- **Aspects** name a file or a folder (an index and one file per area). They describe only what is built;
  planned work stays in the tickets and the `planned` list. `docs/DECISIONS.md` stays the only history.
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
  done or archived.
- **The `doc-auditor`** (read-only by its brief; its tools include Bash, which can write, and the role
  guard covers only GitHub writes) compares each current-state doc and component card with the code and,
  where it is safe, the running system (CLI help, endpoints, config keys, jobs), and opens one ticket per
  drift with the evidence. It runs every `audit_every` merges (default 10), when the user asks, and before
  a release; before a release the orchestrator also checks the planned list and Features against the
  tickets merged since the last one. The orchestrator records each audit in
  `~/.dev-loop/<repo>/doc-audit.txt` (`paths.sh doc-audit`, one UTC time).
- **`doctor.sh`** prints the aspects, the planned list, the PRD files and the map; reports a missing aspect
  path or PRD file as MISSING; notes files over `max_lines` and map rules that match no tracked file; and
  prints the merges since the last audit (from the merge ledger and the audit marker), with a
  `doc audit due` note at `audit_every`.
- **Setup** proposes the layout, the map and the planned list, and for an existing project rebuilds the
  current-state docs once, one aspect at a time, each reviewed by the user. Templates:
  `templates/FEATURES.md` and the "Documentation" section of `templates/CLAUDE.md`.

Without `docs` (or with no aspects, as in `templates/dev-loop.json`) none of this runs.

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
  kind: component        # or: composition-root
  paths: src/app/storage/* src/app/catalogue.py
  depends_on: instruments
  max_lines: 8000
  ---
  ```

  `layer` is a number, 0 at the bottom; no dependency may go up a layer. `paths` are globs on the
  repository path where `*` also matches `/`; a file belongs to the card whose matching glob is longest.
  `depends_on` is optional: when the line is there (even empty), a dependency on any other component is
  flagged. A composition root (entry points, the CLI, the job runner, app wiring) may depend on the layers
  below it without listing them; its fan-out is not flagged. `max_lines` overrides `budget`; without
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
  reads the main checkout's config. A placeholder (`none`, `n/a`, `TODO`, `-`, `not applicable` and the
  like, also followed by punctuation, as in `none: ...` or `none (...)`) is not a reason; a sentence such
  as `none of the edges ...` is. Two cards with the same `paths` glob are a broken card.
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

## Configuration: `.dev-loop.json`

Lives at the repository root and is committed. Every key is optional unless marked.

| key | default | meaning |
|-----|---------|---------|
| `base_branch` | `main` | the branch everything merges into |
| `remote` | `origin` | the remote branches are pushed to |
| `fast_check` | none | seconds-long check (format + lint), run by the Stop hook |
| `format` | none | formats one file; `{file}` is the quoted path (else appended) |
| `format_extensions` | all | only format files ending in one of these (e.g. `[".py"]`) |
| `checks` (required for the gate) | — | the full checks, in order: `{"name", "command", "heavy": true, "summary": "<regex>"}` or a plain command string; names are unique (each is its log file) and `affected` is reserved |
| `affected` | none | a check entry (or plain command) run first, after `gate_setup`; `DL_CHANGED_FILES` names the file listing the paths the train changes against the base (made only when `affected` is set) |
| `parallel` | `false` | run the checks at the same time, each in its own process group (heavy ones in their own slot); results print in config order |
| `fail_fast` | `false` | after the first failure, skip the checks not started and stop the running ones (their whole process group); they print as `<name> skipped` / `<name> stopped` |
| `gate_setup` | none | command run once in the gate worktree before the checks (e.g. `npm ci`) |
| `gate_worktree` | `../<repo>-gate` | the gate's own worktree (created on first use) |
| `notes_dir` | `~/.dev-loop/<repo>/notes` | PR notes files `pr-<branch with / as _>.md`, outside git, shared by all worktrees |
| `logs_dir` | `~/.dev-loop/<repo>/logs` | gate logs |
| `heavy.slots` | `2` | machine-wide slots for heavy commands |
| `heavy.memory_max` | none | memory cap per heavy command (systemd `MemoryMax`, e.g. `"8G"`) |
| `heavy.port_env`, `heavy.port_base`, `heavy.port_step` | none, `8600`, `10` | the per-slot port variable |
| `heavy.clean_temp`, `heavy.clean_temp_minutes` | `[]`, `120` | stale temp globs (`$USER` is expanded) and their age |
| `heavy.poll_seconds` | `10` | how often a waiting command retries |
| `stop_gate.require_clean_tree`, `stop_gate.max_blocks` | `true`, `5` | the Stop hook's rules |
| `merge.method`, `merge.delete_branch` | `squash`, `true` | how merge-train merges; `delete_branch` is the remote branch |
| `merge.delete_local` | `true` | merge-train also deletes the local branch (and its clean worktree) after the merge |
| `merge.rebuildable` | `node_modules dist build target out coverage .venv` and the usual caches | ignored directories a merged worktree may lose when it is removed; a worktree with any other ignored file, or a secret or data file inside these (`.env`, keys, certificates, databases, any case; also `id_rsa`, `credentials*`, `secrets*`, which the search inside a `merge.rebuildable_caches` folder skips since vendored code uses such names), is kept |
| `merge.rebuildable_caches` | `node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .next .turbo .parcel-cache` | the names of `merge.rebuildable` whose files also count one by one (a self-ignoring cache with its own `.gitignore` lists its files, not itself); output folders such as `build` or `out` count only as a whole, so results listed one by one keep the worktree |
| `cleanup.stale_days`, `cleanup.keep_days` | `14`, `30` | `cleanup.sh`: when a branch without PR or open issue is stale; how long merged notes and old gate logs are kept |
| `models.<agent>` | `inherit` | the model per agent (`implementer`, `code-reviewer`, `test-engineer`, `verifier`, `doc-auditor`): `haiku`, `sonnet`, `opus`, `fable` or `inherit` (the main session's model), see below |
| `github.repo` | from the remote URL | `owner/name` |
| `github.status_context` | `dev-loop/gate` | the commit status the gate posts (identity mode, or `github.post_status: true`) |
| `github.feature_patterns` | `feat/* fix/* chore/* docs/*` | branches implementers may push (identity rulesets) |
| `identities` | none (mode off) | per-role identities, see below |
| `guard.agents` | built in | extra agent-type to roles mapping for the role guard |
| `deploy` | none | the deploy command the orchestrator uses |
| `docs.aspects` | none (docs off) | current-state docs: aspect name to a file or folder; at least one turns the docs check on (see Current-state docs) |
| `docs.planned` | none | the planned list (built and planned are kept apart) |
| `docs.map` | `[]` | rules `{"paths": [globs], "docs": [aspect names]}`; `*` in a glob also matches `/` |
| `docs.max_lines` | `1000` | the size budget per current-state file (`doctor.sh` notes bigger ones) |
| `docs.prd` | none | the PRD or spec files, a path or a list: the intent the slice loop cuts into tickets |
| `docs.audit_every` | `10` | run the `doc-auditor` every this many merges (`doctor.sh` notes when one is due) |
| `architecture.check` | none (off) | the command printing the dependency edges `<from> <to>` (paths or component names); set, it turns the architecture ratchet on (see Architecture ratchet) |
| `architecture.cards` | `docs/architecture/` | the folder of the component cards |
| `architecture.baseline` | `docs/architecture/baseline.txt` | the known violations, one per line, sorted |
| `architecture.budget` | none | the default `max_lines` per component (a card may override it) |

### Models per agent

Each agent runs on the model named in `models`, so cheap work can go to a small model and the hard work
to a large one:

```json
"models": { "implementer": "inherit", "code-reviewer": "sonnet", "test-engineer": "sonnet", "verifier": "haiku",
            "doc-auditor": "sonnet" }
```

The orchestrator passes the model on every agent launch (the Agent tool's `model` parameter, which takes
precedence over the agent's own `model: inherit`). A missing agent, or `inherit`, uses the main session's
model. A resumed agent keeps the model it started with. `doctor.sh` prints the resolved models and
reports unknown names. The gate and the heavy-job queue are scripts and use no model.

Environment overrides: `DEV_LOOP_CONFIG` (config path), `DEV_LOOP_HOME` (state, default `~/.dev-loop`),
`DEV_LOOP_LOCK_DIR`, `DEV_LOOP_HEAVY_SLOTS`, `DEV_LOOP_NO_JQ=1` (read JSON with python3),
`DEV_LOOP_STOP_GRACE_SECONDS` (how long `fail_fast` waits after SIGTERM before SIGKILL, default 10).

Script exit codes are documented at the top of each script and in the `gate` and `merge` skills.

## Per-role GitHub identities (optional)

By default everything runs under the user's own GitHub login with zero setup. Identity mode gives each
role its own GitHub identity, and puts deterministic server-side gates around the agents. They are
enforced by GitHub token permissions and repository rulesets, not by prompts.

| role | who | may |
|------|-----|-----|
| implementer | `implementer` agent | contents write (feature branches only, by ruleset), pull requests write (open PRs); cannot push the base branch, cannot approve its own PRs |
| tester | `test-engineer`, `verifier`, `doc-auditor` | issues write, contents read: raise tickets, never push code |
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
`gh pr review --approve/--request-changes` as `reviewer`. When the gate's replay of a branch dismisses an
approval, `merge-train.sh` stops with exit 9. The reviewer then confirms with `git range-diff` and approves
again.

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
  code-reviewer: reviewer, test-engineer, verifier and doc-auditor: tester, main session: orchestrator).
  It also refuses any direct use of the gate role, any merge, ruleset or auth command, and any mention of
  the credential paths. This is best effort: it parses shell commands and cannot see inside scripts the agent writes;
- for strong isolation, run each role under its own OS user (or container) that holds only its own
  credentials.

The guarantees come from GitHub, not from the local guard. Token permissions decide what each identity can
do at all, and the rulesets decide what can reach the base branch. One gap is known: the implementer app
has contents write, so it could merge a PR that already has the reviewer's approval and the gate's status.
That is the same merge the gate would make.

## Safety notes

- Agents never read `.env` or credential files, and never write secrets or personal identifiers (real user
  names, account numbers, emails, private hostnames) into the repository, commits, issues or PRs.
- Merges happen only through `merge-train.sh` after a green gate, and never with `--admin`.
- The plugin touches only the repository, its gate worktree, `~/.dev-loop/<repo>/`, the heavy-slot lock
  directory, and, in identity mode, `~/.config/dev-loop/`.
- The scripts never push to the base branch directly. They push feature branches with
  `--force-with-lease` on the gated head, so commits pushed after the gate are never overwritten.

## Developing the plugin

```bash
make check     # manifests, shellcheck, ruff, then tests/smoke.sh and tests/identity.sh (no network)
```

`tests/smoke.sh` builds a throwaway repository with a local bare origin and a fake `gh`. It covers the
hooks, the heavy queue (3 jobs on 2 slots, a killed job's slot), the gate, the merge, a red train, the
tree check, a branch that moved, a conflict, and the gate options (affected, parallel, fail_fast). `tests/identity.sh` adds fake GitHub API, browser and `gh` stand-ins. It covers
`as-role.sh`, app JWTs and tokens, the guard, the ruleset plan, the manifest flow and identity-mode merges.

## License

MIT, see [LICENSE](LICENSE).
