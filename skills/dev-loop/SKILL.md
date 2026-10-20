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

1. Read `CLAUDE.md`, the spec it names, `.dev-loop.json` and `docs/DECISIONS.md`. If `.dev-loop.json` or
   `CLAUDE.md` is missing, run the `setup` skill of this plugin first.
2. `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh`: prerequisites and resolved paths (gate worktree, notes
   directory, heavy slots). Fix what it reports as MISSING, or stop if that is a stop condition.
3. Identity mode is on when `.dev-loop.json` has `identities`. Then every GitHub write goes through
   `${CLAUDE_PLUGIN_ROOT}/scripts/as-role.sh <role> ...` (your role: `orchestrator`), and the guard hook
   refuses the rest. Off: use `gh` and `git` as usual.
4. `gh issue list --state open` and `git worktree list`: find work in flight (branches pushed, notes files
   written, agents to resume) before starting new work.

## 1. Tickets

- At the start of a project (or a new spec section), create one GitHub issue per work item of the spec's
  work breakdown: the acceptance criteria as a checklist, the dependencies (`Depends on #n`), labels, and
  a milestone if the project uses them. In identity mode:
  `${CLAUDE_PLUGIN_ROOT}/scripts/as-role.sh orchestrator gh issue create ...`.
- Keep issues current: comment progress at each step (started, in review, gated, merged, run result) and
  close them through `Closes #n` in the PR.

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

Branch types: `feat/`, `fix/`, `chore/`, `docs/`. Then launch the `implementer` agent (one per ticket) with
this prompt, filled in completely:

```text
Implement ticket #<n>: <title>.
- Worktree: <absolute worktree path>   (branch <branch>, based on <remote>/<base> | stacked on <dependency branch>)
- Notes file (outside git, do not commit): <absolute notes path>
  First line: a plain title, NO leading "#", e.g. "feat(<scope>): <what> (#<n>)". Then a blank line,
  ## Summary, "Closes #<n>", ## Decisions, ## Test evidence (commands and pass counts).
- Dependencies: <none | #m merged | stacked on <branch>>. Files other agents are editing now: <list>; avoid them.
- Tests: write the failing tests first. Run ONLY the tests for what you touch, plus the fast check:
  <fast_check>. Do NOT run the full suite, coverage gate, e2e or long builds: the batch gate runs them
  once for all ready branches. If one heavy run is unavoidable, use
  <plugin>/scripts/heavy.sh <command> (never `timeout <command>`).
- Ports for any server you start: <range outside the gate's heavy.port_base..+N>.
- Commits: small Conventional Commits, each "Refs #<n>". Record open spec questions in docs/DECISIONS.md.
- Push the branch when green: <git push -u <remote> <branch> | <plugin>/scripts/as-role.sh implementer git push -u <remote> <branch>>.
  Never open, approve or merge PRs. Never read .env or credential files. Never write secrets or personal
  identifiers anywhere.
- Report: branch, head commit, tests added per criterion, commands run with results, anything open.
```

## 4. Review loop (every branch, before the gate)

When an implementer reports green:

1. Identity mode: open the PR now so the review lands on GitHub:
   `${CLAUDE_PLUGIN_ROOT}/scripts/open-pr.sh <branch>` (opens it as the implementer from the notes file).
2. Launch the `code-reviewer` agent with:

```text
Review branch <branch> (ticket #<n>: <title>) in <absolute worktree path>, against <remote>/<base>.
Read CLAUDE.md, the ticket and the spec sections it cites. <This change touches <money|orders|auth|
data deletion|...>: apply the deeper safety checklist.> Reproduce suspected bugs as throwaway tests, then
delete them; leave the tree clean. Run only the targeted tests and the fast check (<fast_check>).
<Identity mode: submit your verdict on the PR as the reviewer:
<plugin>/scripts/as-role.sh reviewer gh pr review <branch> --approve|--request-changes --body "...">
Output: Must fix / Should fix lists, then VERDICT: APPROVE or VERDICT: CHANGES REQUIRED.
```

3. CHANGES REQUIRED: resume the same implementer (SendMessage to its agent id) with the must-fix list
   verbatim; when it reports, run the reviewer again. Repeat until `VERDICT: APPROVE`. Should-fix items:
   fix now if cheap, else open a follow-up issue.
4. The review is independent: never skip it because the implementer reviewed itself, and never merge a
   branch whose last verdict is not APPROVE.

## 5. Batch gate (one full run for a train of approved branches)

Use the `gate` skill. In short: when one or more branches are approved, run
`${CLAUDE_PLUGIN_ROOT}/scripts/gate-train.sh <b1> <b2> ...` in merge (dependency) order, in the
background. It stacks them on the latest base and runs every configured check once, heavy ones through
the machine-wide heavy-job queue.

- **GREEN**: merge (step 6).
- **RED**: never merge a red train, not even for an apparent flake. Re-run once to tell a flake from a
  failure. If still red, bisect: gate the first half of the train, then the rest, until the culprit is
  found; send its log excerpt to its implementer; gate and merge the others without it. Open an issue for
  a real flake.
- **Rebase conflict at <branch>**: drop that branch from the train, gate and merge the rest, then have its
  implementer rebase it on the new base and re-gate it.

## 6. Merge in order

Use the `merge` skill: `${CLAUDE_PLUGIN_ROOT}/scripts/merge-train.sh <same branches, same order>`. It
replays each branch on the current base, checks the tree is exactly the gated one, opens the PR from the
notes file if missing, squash-merges and deletes the branch. If the base moved in between (exit 4), re-gate.
In identity mode it posts the required `dev-loop/gate` status and merges as the gate identity; exit 9
means the replay dismissed the approval: have the code-reviewer confirm with `git range-diff` and approve
again, then re-run merge-train with the remaining branches.

After merging: remove the merged worktrees (`git worktree remove <path>`), comment on the issues, start
the next tickets.

Stacked branches: after the lower branch merges, rebase the upper one with
`git rebase --onto <remote>/<base> <old lower head> <upper>` so it never carries foreign commits.

## 7. Run, verify, deploy

- After a ticket that adds or changes a job merges, run it for real (as the spec says), in the background
  for long runs, and record the result in the issue. Then launch the `verifier` agent on the outputs.
- Deploy only when the user is not in the middle of using the system (ask, or follow their schedule), with
  the project's deploy command (`deploy` in `.dev-loop.json` or CLAUDE.md), then verify the deployed system
  (status, health, a smoke check) and report it.

## 8. Decisions and stop conditions

- When the spec is silent, choose the simplest option that fits it, add one entry to `docs/DECISIONS.md`
  (date, decision, reason, alternatives) and continue. Do not stop for it.
- Stop and ask the user only for: a missing or rejected credential; a paid action above the project's cost
  cap; a spec contradiction where both readings change stored data or behaviour the user relies on; anything
  unsafe or irreversible (production data, real money, real orders, deleting history, security settings).

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
