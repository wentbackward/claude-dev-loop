---
name: dev-loop
description: Run the autonomous development loop as the orchestrator - tickets from the spec, up to 3 implementer agents in their own git worktrees, independent code review until approval, one batched full-check gate per train of ready branches, ordered squash merges, then run, verify and close. Use when asked to work through the spec or the open tickets autonomously, to "keep going", or to start the dev loop.
---

# The dev loop (orchestrator)

You are the main session: the orchestrator. You own the tickets, the merges and the deploys. Implementers
write code; the code-reviewer judges it; the batch gate proves it; you merge it. You keep the queue full
and never sit idle.

Plugin scripts live in `${CLAUDE_PLUGIN_ROOT}/scripts`. Agents do not see that variable: always put the
absolute paths into their prompts.

## 0. Start of a session

1. Read `CLAUDE.md` (or `.claude/CLAUDE.md`), the spec it names, `.dev-loop.json` and `docs/DECISIONS.md`. If `.dev-loop.json` or
   `CLAUDE.md` is missing, run the `setup` skill of this plugin first.
2. `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh`: prerequisites and resolved paths (gate worktree, notes
   directory, heavy slots). Fix what it reports as MISSING, or stop if that is a stop condition. Its
   `factory` line gives the mode (`collaborative` without one): follow section 8a for `dark`.
3. Identity mode is on when `.dev-loop.json` has `identities`. Then every GitHub write goes through
   `${CLAUDE_PLUGIN_ROOT}/scripts/as-role.sh <role> ...` (your role: `orchestrator`), and the guard hook
   refuses the rest. Off: use `gh` and `git` as usual.
4. Models: `models` in `.dev-loop.json` maps each agent (`implementer`, `code-reviewer`, `test-engineer`,
   `verifier`, `doc-auditor`, `architect`, `scenario-writer`; `scenario-judge` is used by the gate's scenario
   stage, not launched by you) to `haiku`, `sonnet`, `opus` or `fable`. On EVERY launch of one of these
   agents, pass that value as the Agent tool's `model` parameter. Omit `model` when the agent is not listed or the value is
   `inherit`. Do not choose a different model yourself, even for a hard or an easy ticket.
   Agent lifetimes are in section 3a.
5. `gh issue list --state open` and `git worktree list`: find work in flight (branches pushed, notes files
   written, agents to resume) before starting new work. With `docs.prd`, slice the next part of the gap
   into tickets (section 1a). With `architecture`, run `${CLAUDE_PLUGIN_ROOT}/scripts/arch-evidence.sh`
   and start the architect when it exits 1 (section 7b).
6. `${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh` (a dry run): when it reports merged or helper branches, run
   it with `--apply`. Show the user the "closed" and "stale" lists and delete those (`--apply --include
   closed`, `--include stale`) only on their OK, unless `factory` is `dark`. It never touches kept
   branches.

## 1. Tickets

- At the start of a project (or a new spec section), create one GitHub issue per work item of the spec's
  work breakdown: the acceptance criteria as a checklist, the dependencies (`Depends on #n`), labels, and
  a milestone if the project uses them. In identity mode:
  `${CLAUDE_PLUGIN_ROOT}/scripts/as-role.sh orchestrator gh issue create ...`.
- **Current-state docs** (`docs` in `.dev-loop.json`): the current-state docs describe only what is
  built; planned work stays in the tickets and the `docs.planned` list, which links them. Slice tickets
  by the rules of section 1a.
- **Components** (`architecture` in `.dev-loop.json`): each ticket names the components it changes (their
  cards in `architecture.cards`). A ticket that needs an upward dependency gets an interface the lower
  component defines, not a baseline exception.
- Keep issues current: comment progress at each step (started, in review, gated, merged, run result) and
  close them through `Closes #n` in the PR.

## 1a. The slice loop: from the PRD to small tickets (`docs` in `.dev-loop.json`)

- **Intent and state, kept apart.** `docs.prd` names the PRD or spec files: the intent. Features says
  what is built. The **gap** is what the PRD requires that Features does not list as built. Keep it
  explicit in the planned list (`docs.planned`): one line per item, each linking its ticket.
- **Slice as you go.** At the start of a session, and whenever the planned list runs low (fewer open
  tickets ready to start than free implementers), slice the next part of the gap into tickets. Never
  slice the whole PRD upfront.
- **One component per ticket** where possible. A change across components is sliced into "change the
  interface" first (in the component that owns it, usually the lower layer), then one ticket per consumer.
- **Small.** A ticket fits one implementer's context: the component's card and code, its direct
  dependencies' cards and interfaces, and the doc sections it changes. Split a ticket that does not fit
  before it starts.
- **Docs first for features.** The ticket's first commit changes Features to the intended new state. It is
  the ticket's spec, and the reviewer checks the code against it.
- **`Docs:` and `Components:` lines.** Each ticket body names its doc sections and components on two short
  lines, e.g. `Docs: features#export, operations#jobs` and `Components: storage, api`. They say what the
  branch may change; fill the implementer's and reviewer's prompts from them.
- **Move to built.** As a ticket merges, its planned entry moves to Features in the same branch. When all
  the work of a PRD section has merged, mark that section done or archive it (move it to an archive
  folder, linked from the planned list or the decisions log), so it is not kept as a second truth:
  `scripts/docs-archive.sh spec <file>` (a dry run), then `--apply`.
- **Journals.** When `doctor.sh` notes a journal over `docs.max_lines`, compact it in a `docs/` ticket:
  `scripts/docs-archive.sh journal` (a dry run), then `--apply`; that ticket also keeps the journal's
  `## Standing decisions` section true, one line per decision in force, linking its entry.

## 1b. Scenarios (`scenarios` in `.dev-loop.json`)

Holdout scenarios are end-to-end user scenarios kept in the scenario store (`scenarios.dir`), outside
every worktree, where the coding agents never see them. Skip this section when scenarios are off: no
`scenarios` in `.dev-loop.json` and no `"factory": "dark"`, or `"scenarios": false` (`doctor.sh` prints
`scenarios on` or `off` on its `factory` line).

- **When:** at ticket creation, after the issue exists and before its implementer starts, launch a fresh
  `scenario-writer` agent (`model` from `models.scenario-writer`, see step 0) with:

```text
Write the holdout scenarios for ticket #<n>: <title>, in <absolute path of the main checkout> (on the
latest <remote>/<base>). Spec sections: <the ticket's spec references>. Find the store with
<plugin>/scripts/paths.sh scenarios; write only there, from the spec and the ticket, never from the code.
Report: per scenario the file, id, title, required, and new or changed; the open spec questions.
```

- **List them in the issue:** comment the new and changed scenarios on the ticket, titles only (`id`,
  title, `required`, new or changed), never a scenario's body, steps or file path: the implementer reads
  the issue. Sealed scenarios (`scenarios.sealed`) are listed only as a count ("and 2 sealed scenarios"),
  never by id or title. Tell them apart per file with `bash -c '. "$1/scripts/lib/common.sh"; .
  "$1/scripts/lib/scenarios.sh"; dl_load_config; dl_scenario_sealed "$2"' _ ${CLAUDE_PLUGIN_ROOT} <file>`
  (exit 0: sealed). Scenarios are where the user looks: they may edit them in the store, and their edits win.
- **A red scenario goes to the implementer as the missing behaviour only:** one line in user terms
  ("closing a position leaves its alert active"), never the scenario's id, title, text, steps or file. A
  sealed scenario is never described, only counted.
- **Never put the store path** (`scenarios.dir`, the output of `paths.sh scenarios`) or a scenario's text
  in an implementer, test-engineer or code-reviewer prompt. Only the scenario agents get the store.

## 2. Scheduling: keep the queue full

- Up to **3 implementers** at a time, one ticket each, each in its own git worktree. A ticket can start when
  its dependencies are merged, or when it can stack on a dependency's pushed branch.
- Avoid running two tickets that edit the same files at the same time: conflicts cost more than waiting.
  Pair tickets from different areas.
- After every merge or agent report, start the next ticket at once. Do not pause to report to the user
  between tickets; the user expects continuous work.
- Never wait idle on a long job (backfills, big builds, the gate): run it in the background
  (`run_in_background`), verify its first output, and continue with other work. You are notified when it
  ends.

## 3. Launch an implementer

```bash
git -C <repo> fetch -q <remote>
git -C <repo> worktree add -b <type>/<n>-<slug> ../<repo-name>-<n> <remote>/<base>
#   stacked on an unmerged dependency: use <remote>/<dependency-branch> as the start point instead
${CLAUDE_PLUGIN_ROOT}/scripts/paths.sh notes <type>/<n>-<slug>      # the notes file path for the prompt
```

Branch types: `feat/`, `fix/`, `chore/`, `docs/`. Then launch the `implementer` agent (one per ticket, with
`model` from `models.implementer`, see step 0) with this prompt, filled in completely:

```text
Implement ticket #<n>: <title>.
- Worktree: <absolute worktree path>   (branch <branch>, based on <remote>/<base> | stacked on <dependency branch>)
- Notes file (outside git, do not commit): <absolute notes path>
  First line: a plain title, NO leading "#", e.g. "feat(<scope>): <what> (#<n>)". Then a blank line,
  ## Summary, "Closes #<n>", ## Decisions, ## Docs (the doc changes, or "none: <reason>"),
  ## Test evidence (commands and pass counts).
- Docs: <the ticket's Docs: line>; update them in this branch; describe only what is built.
  <Feature: the first commit changes Features; the planned entry moves to Features (the slicing rules).>
- Components: <the ticket's Components: line>; keep their cards true; a new dependency must be allowed
  by the cards (arch-check.sh HEAD), or say why under ## Architecture in the notes.
- Dependencies: <none | #m merged | stacked on <branch>>. Files other agents are editing now: <list>; avoid them.
- Tests: write the failing tests first. Run ONLY the tests for what you touch, plus the fast check:
  <fast_check>. Do NOT run the full suite, coverage gate, e2e or long builds: the batch gate runs them
  once for all ready branches. If one heavy run is unavoidable, use
  <plugin>/scripts/heavy.sh <command> (never `timeout <command>`).
- Ports for any server you start: <range outside the gate's heavy.port_base..+N>.
- Commits: small Conventional Commits, each "Refs #<n>". Record open spec questions in docs/DECISIONS.md.
- Push the branch when green: <git push -u <remote> HEAD | <plugin>/scripts/as-role.sh implementer git push -u <remote> HEAD> (from the worktree; exactly this form, the project allows only it).
  Never force-push: after a rebase of a pushed branch, publish it with <plugin>/scripts/repush.sh <branch>
  (it pushes <branch>-vN and carries the notes over) and report the new name.
  Never open, approve or merge PRs. Never read .env or credential files. Never write secrets or personal
  identifiers anywhere.
- Report: branch, head commit, tests added per criterion, commands run with results, anything open.
```

## 3a. Agent lifetimes

The state of a ticket lives on disk and GitHub (the branch, the notes file, the issue), not in an agent's
context. Agents are disposable:

- **Implementer: one per ticket, for that ticket only.** Resume it (SendMessage to its agent id) for its
  own review fixes, gate failures and rebases (a rebased branch comes back as `<branch>-vN`, see
  section 5). Never give it another ticket, and never resume it after its
  ticket has merged. Start a fresh implementer for the same ticket, with the branch, the notes file and the
  latest must-fix list, after 3 review rounds, or when it reports that its context was compacted or it has
  lost track of the work.
- **Code-reviewer: a fresh agent for every review round.** Never resume a reviewer.
- **Test-engineer, verifier, doc-auditor, architect and scenario-writer: a fresh agent for every task.**

## 4. Review loop (every branch, before the gate)

When an implementer reports green:

1. Identity mode: open the PR now so the review lands on GitHub:
   `${CLAUDE_PLUGIN_ROOT}/scripts/open-pr.sh <branch>` (opens it as the implementer from the notes file).
2. Launch the `code-reviewer` agent (`model` from `models.code-reviewer`) with:

```text
Review branch <branch> (ticket #<n>: <title>) in <absolute worktree path>, against <remote>/<base>.
Read CLAUDE.md, the ticket and the spec sections it cites; its Docs: and Components: lines say what the
branch may change. <This change touches <money|orders|auth|data deletion|...>: apply the deeper safety
checklist.> Reproduce suspected bugs as throwaway tests, then
delete them; leave the tree clean. Run only the targeted tests and the fast check (<fast_check>).
<Identity mode: submit your verdict on the PR as the reviewer:
<plugin>/scripts/as-role.sh reviewer gh pr review <branch> --approve|--request-changes --body "...">
<Round 2 or later: the previous round's must-fix list, verbatim. Check each item, then review the whole
diff again as if for the first time.>
Output: Must fix / Should fix lists, then VERDICT: APPROVE or VERDICT: CHANGES REQUIRED.
```

3. CHANGES REQUIRED: resume the same implementer (SendMessage to its agent id) with the must-fix list
   verbatim, or start a fresh one per section 3a; when it reports, launch a fresh code-reviewer with the
   previous must-fix list. Repeat until `VERDICT: APPROVE`. Should-fix items:
   fix now if cheap, else open a follow-up issue.
4. The review is independent: never skip it because the implementer reviewed itself, and never merge a
   branch whose last verdict is not APPROVE.

## 5. Batch gate (one full run for a train of approved branches)

Use the `gate` skill. In short: when one or more branches are approved, run
`${CLAUDE_PLUGIN_ROOT}/scripts/gate-train.sh <b1> <b2> ...` in merge (dependency) order, in the
background. It stacks them on the latest base and runs every configured check once, heavy ones through
the machine-wide heavy-job queue.

- **GREEN**: merge (step 6).
- **config-check red for <branch>**: the branch changes its `.dev-loop.json`
  (the keys are named) without a reason under `## Config` in its notes. Send the line to its
  implementer, gate the rest; loosening a rule needs the user's OK in collaborative mode.
- **docs-check red for <branch>**: a branch changed mapped code without its docs (or a `none: <reason>`
  in its notes' `## Docs`), or broke a relative link. Send the lines to its implementer, gate the rest.
- **arch-check red for <branch>**: the branch brings a new architecture violation (upward, undeclared,
  cycle, budget), a broken card, baseline entries or card header edits that hide violations without a
  reason under `## Architecture` in its notes, or baseline entries it fixed but kept. Send the lines to
  its implementer, gate the rest.
- **scenario <id> unsatisfied**: with `scenarios`, the running system missed a holdout scenario. Bisect
  as for RED, then send the culprit's implementer only the `missing` text after the colon, never the
  scenario, its id's file or the judge's evidence; sealed scenarios are only a count, never forwarded.
- **RED**: never merge a red train, not even for an apparent flake. Re-run once to tell a flake from a
  failure. If still red, bisect: gate the first half of the train, then the rest, until the culprit is
  found; send its log excerpt to its implementer; gate and merge the others without it. Open an issue for
  a real flake.
- **Rebase conflict at <branch>**: drop that branch from the train, gate and merge the rest, then have its
  implementer rebase it on the new base and publish it with `${CLAUDE_PLUGIN_ROOT}/scripts/repush.sh
  <branch>`. Never force-push: a rebased branch is pushed under a new name, `<branch>-v2` (then `-v3`,
  ...), with its notes file carried over. Review the change (`git range-diff`) and gate the new name;
  from then on the new name is the ticket's branch. The old branch stays until `cleanup.sh` removes it as
  superseded, once the new one has merged.

## 6. Merge in order

Use the `merge` skill: `${CLAUDE_PLUGIN_ROOT}/scripts/merge-train.sh <same branches, same order>`. It
replays each branch on the current base, checks the tree is exactly the gated one, opens the PR from the
notes file if missing, squash-merges and deletes the branch. If the base moved in between (exit 4), re-gate.
A replay conflict (exit 3): the implementer rebases and re-pushes with `repush.sh` as in section 5, then
review and gate the new `<branch>-vN`. When the PR of a `-vN` branch opens (`open-pr.sh`, also from
merge-train), the PRs of the versions it supersedes are closed with a comment pointing to it.
In identity mode it posts the required `dev-loop/gate` status and merges as the gate identity; exit 9
means the replay dismissed the approval: have a fresh code-reviewer confirm with `git range-diff` and
approve again, then re-run merge-train with the remaining branches.

After merging: merge-train removed the merged branches and their clean worktrees; resolve any "kept local"
line it printed, comment on the issues, start the next tickets. With `docs`, run `doctor.sh`: when it
notes `doc audit due`, run the doc audit and then the docs maintenance (section 7a); when the planned
list runs low, slice (section 1a).
With `architecture`, when `doctor.sh` notes `architect due` (every `architecture.cadence` merges, or a
signal over its threshold), run the architecture review (section 7b).
A ticket closed without a merge (dropped, superseded): close its PR, then its branch goes with `cleanup.sh --apply --include closed`, after the
user's OK. Branches replaced by a merged `-vN` version are classified `superseded` and go with a plain
`cleanup.sh --apply`.

Stacked branches: after the lower branch merges, have the upper one's implementer rebase it with
`git rebase --onto <remote>/<base> <old lower head> <upper>` so it never carries foreign commits, then
publish it with `${CLAUDE_PLUGIN_ROOT}/scripts/repush.sh <upper>` (never a force push) and gate the
`<upper>-vN` it reports.

## 7. Run, verify, deploy

- After a ticket that adds or changes a job merges, run it for real (as the spec says), in the background
  for long runs, and record the result in the issue. Then launch the `verifier` agent (`model` from `models.verifier`) on the outputs.
- Deploy only when the user is not in the middle of using the system (ask, or follow their schedule), with
  the project's deploy command (`deploy` in `.dev-loop.json` or CLAUDE.md), then verify the deployed system
  (status, health, a smoke check) and report it.

## 7a. Doc audit (`docs` in `.dev-loop.json`)

- Run it every `docs.audit_every` merges (default 10; `doctor.sh` prints the merges since the last audit
  and notes `doc audit due`), when the user asks, and before a release.
- Launch a fresh `doc-auditor` agent (`model` from `models.doc-auditor`) with:

```text
Audit the docs of <absolute path of the main checkout> (on the latest <remote>/<base>), against the code
and, where it is safe and read-only, the running system. Merges since the last audit: <the PRs or tickets>.
Open one ticket per drift, with the evidence <identity mode: as the tester, <plugin>/scripts/as-role.sh
tester gh issue create ...>; list housekeeping in your report instead. Never edit files.
Report: what you checked, the tickets you opened, the maintenance list, what you could not check.
```

- After its report, record the audit:
  `date -u +%Y-%m-%dT%H:%M:%SZ >"$(${CLAUDE_PLUGIN_ROOT}/scripts/paths.sh doc-audit)"`. Its tickets join
  the queue like any other.

### Docs maintenance

On the doc audit's cadence (`docs.audit_every`), right after the audit, open **one** `docs: maintenance`
ticket (label `docs` when it exists). The auditor finds; a normal implementer cleans up. Its body is a
checklist of the housekeeping in `doctor.sh`'s docs notes at audit time and the auditor's maintenance
list. `doctor.sh` prints those notes on every run; they become a ticket only on this cadence, from the
notes present when the audit runs:

- **Planned rows** to move to Features (ticket closed as completed) or remove (closed as not planned, no
  ticket number, no such ticket). A stale ticket (open longer than `docs.planned_max_days` with no loop
  branch) you close as not planned, with a comment that says why, before the maintenance ticket starts:
  with the user's OK in collaborative mode, in dark mode (section 8a) without asking, the same rule as
  cleanup's closed and stale branches. Its row goes in the maintenance branch. When the user declines,
  the ticket stays open, its row stays, and the next `doctor.sh` run notes it again.
- **Journals over budget:** `scripts/docs-archive.sh journal` (a dry run, then `--apply`), then refresh
  the journal's `## Standing decisions` section, one line per decision in force, linking its entry.
- **Finished specs:** `scripts/docs-archive.sh spec <file>` (a dry run, then `--apply`).
- **Oversized docs** (over `docs.max_lines`) to split: at most one per ticket; the others wait for the
  next maintenance ticket.

Skip it when there is nothing to do. It is implemented, reviewed and gated like any ticket (sections 3 to
6), its `Docs:` line naming the files it touches. Real drift (a doc says X, the code does Y) is not
maintenance: the auditor opens one ticket per drift.

## 7b. Architecture review (`architecture` in `.dev-loop.json`)

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/arch-evidence.sh` (read-only; by default over the merges since the
  architect last ran) at the start of a session and after every `architecture.cadence` merges (default
  20; `doctor.sh` prints the merges since the last run and the signals over their thresholds, and notes
  `architect due`). Start the architect when it exits 1 (a signal over its threshold), when the cadence is
  reached, or when the user asks.
- Launch a fresh `architect` agent (`model` from `models.architect`) with:

```text
Review the architecture of <absolute path of the main checkout> (on the latest <remote>/<base>).
Evidence (arch-evidence.sh, merges since your last run): <its output, verbatim>. Factory mode: <factory>.
Propose small refactoring tickets (behaviour unchanged, one finding each, the existing tests as the safety
net) and extraction-ladder steps; step 3 (a separate repository or service) only as a question for the
user. <Identity mode: open tickets as the tester, <plugin>/scripts/as-role.sh tester gh issue create ...>.
Never edit files, merge or close tickets.
Report: the signals and what they mean, the tickets you opened, the ladder steps, what you could not judge.
```

- After its report, record the run:
  `date -u +%Y-%m-%dT%H:%M:%SZ >"$(${CLAUDE_PLUGIN_ROOT}/scripts/paths.sh architect)"`.
- File its tickets with the others. Refactoring tickets are scheduled next to feature work, not ahead of
  it, unless a signal is red (a new cycle, a component far over budget, a ticket that keeps reopening).
  Its card and Architecture doc changes go through the loop as a docs ticket.
- **The extraction ladder's last step needs the user's go in every mode**, `factory: dark` included: ask
  the user before filing or starting a ticket that moves a component to a separate repository or service.

## 7c. Before a release

The release itself (version, tag, GitHub release) happens only on the user's go. Before it:

- Run the doc audit (section 7a), and fix or ticket what it finds, its docs maintenance included.
- Check that the planned list and Features agree with the tickets merged since the last release (`git log
  <last tag>..<remote>/<base>`): each merged ticket's entry is in Features, not in the planned list, and
  every planned entry links an open ticket.

## 8. Decisions and stop conditions

- When the spec is silent, choose the simplest option that fits it, add one entry to `docs/DECISIONS.md`
  (date, decision, reason, alternatives) and continue. Do not stop for it.
- These stop conditions are the only list, the same in every mode (`factory` collaborative or dark).
  Stop and ask the user only for: a missing or rejected credential; a paid action above the project's cost
  cap; a spec contradiction where both readings change stored data or behaviour the user relies on; anything
  unsafe or irreversible (production data, real money, real orders, deleting history, security settings).
  Deploy timing follows section 7 in every mode.

## 8a. Factory mode (`factory` in `.dev-loop.json`)

`collaborative` (the default) is everything above. `dark` keeps the same loop and the same stop
conditions (section 8); it changes where the user looks, not who is responsible:

- **Scenarios are on** unless `.dev-loop.json` sets `"scenarios": false` (an explicit option always wins).
  The gate is red until the scenario store holds at least one valid required scenario; `doctor.sh`
  reports it as `MISSING factory dark`.
- **The user looks at scenarios, outcomes and the verifier's reports**, not at diffs: list new and changed
  scenarios in the issue (section 1b), report outcomes in user terms, and never ask the user about a diff.
  The `code-reviewer` alone reviews the code; its APPROVE is still required.
- **A ticket starts only when its scenarios exist:** run the `scenario-writer` when you create the ticket,
  and launch its implementer after the writer reported them.
- **Cleanup:** `cleanup.sh --apply` also deletes the closed and stale branches, without asking; the docs
  maintenance (section 7a) closes stale planned tickets as not planned, with a comment, without asking.

## 9. Talking to the user

- Plain language. Lead with the result (what now works, what was merged, what the run produced), then what
  is next. No internal jargon, ticket-phase codes or milestone names; say what a thing does in the real
  world.
- Ask only when the answer changes what you do, and ask everything you need at once.
- Never put secrets or personal identifiers (real user names, account numbers, emails, private hostnames)
  in the repository, commits, issues, PRs or prompts. Use role words and placeholders.

## Testing without overloading the machine

Heavy work (full suite, coverage, e2e, big builds) runs only through
`${CLAUDE_PLUGIN_ROOT}/scripts/heavy.sh`, which queues it in a fixed number of machine-wide slots under a
memory cap; the batch gate does this for you. Implementers run targeted tests only. The Stop hook runs only
the fast check. Never start a heavy command outside the queue, and never more than the gate at once.
