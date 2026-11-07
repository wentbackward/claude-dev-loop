---
name: merge
description: Merge a green batch-gate train in order, one squash merge per branch, verifying each replayed tree equals the gated one; opens missing PRs from the notes files. Use right after the gate skill reports TRAIN GREEN.
---

# Merge a green train

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/merge-train.sh <branch-1> <branch-2> ...    # same branches, same order as the gate
```

For each branch it replays the branch's own commits onto the current base, checks that the tree is exactly
the tree the gate tested, pushes it (with a lease on the gated head), opens the PR if there is none (title =
first line of the notes file, without a leading `#`; body = the rest), squash-merges exactly that head,
confirms the PR is MERGED and deletes the branch. Then it records the merge in the ledger, deletes the
local branch (removing its worktree first when that is clean), moves the notes file to `notes/merged/`, and
once the whole train merged it deletes the train's `train-<branch>` refs. A "kept local ..." line names a
branch it left, and why: a worktree with changes, a locked worktree, or local commits that were not
merged. Deal with those (finish or save the work), then let `cleanup.sh` remove them. The notes files live
in `${CLAUDE_PLUGIN_ROOT}/scripts/paths.sh notes-dir`.

## Exit codes

| exit | meaning | what to do |
|------|---------|------------|
| 0 | all merged | read any "kept local" lines, comment on the issues, start the next tickets |
| 3 | replay conflict | the base changed under the train: have the implementer rebase the branch and publish it with `repush.sh <branch>` (never a force push), review the change, gate the `<branch>-vN` it reports |
| 4 | tree differs from the gated one | the base moved since the gate: re-gate the remaining branches |
| 5 | notes file missing | write it (ask the implementer), then re-run |
| 6 | branch changed since the gate | someone pushed after the gate: review and re-gate |
| 7 | PR not merged | read the message (branch protection, checks); fix and re-run |
| 8 | not gated green | run the gate skill first, with exactly these branches |
| 9 | approval missing (identity mode) | the replay dismissed the approval: have a fresh code-reviewer confirm with `git range-diff` and approve again, then re-run with the branches not merged yet |

Never merge by hand around a failure, and never with `--admin`. Never force-push a branch: a rebased one is
re-pushed as `<branch>-vN` with `${CLAUDE_PLUGIN_ROOT}/scripts/repush.sh`. When the PR of a `-vN` branch
is opened (here or by `open-pr.sh`), the open PRs of the versions it supersedes are closed with a comment
pointing to it, and `cleanup.sh` deletes those branches once the new one has merged. Never merge a branch the gate did not
prove green.

In identity mode (`identities` in `.dev-loop.json`) the script pushes, posts the required
`dev-loop/gate` commit status and merges as the gate identity, and opens missing PRs as the implementer.
The repository rulesets (set up with `github-protect.sh`) then refuse any merge without the reviewer's
approval and the gate's status.

## After merging

- Fast-forward the main checkout if the script did not (it does when the checkout is clean and on the base).
- Run jobs that the merged tickets added (in the background), then the `verifier` agent on their outputs.
- Deploy only when the user is not mid-operation; verify after the deploy.
