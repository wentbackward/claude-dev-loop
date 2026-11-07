---
name: status
description: Show what the dev loop is doing right now without waking the session that runs it - the batch gate and its current stage (with how long ago its log last grew), the heavy-job slots and what holds them, each loop worktree, the last merge, open tickets, the orchestrator's last step, and a verdict (idle, working, waiting on something, or possibly stalled). Use when asked for the loop's status, whether the loop or the gate is stuck or still running, or what the loop is waiting on.
---

# Status

Run it from the project (any worktree of it, any terminal or session):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/status.sh            # add --no-gh to skip the open-ticket count
```

It only reads: files under `~/.dev-loop/<repo>/` (the event log `events.jsonl`, `train-running.txt`, the
stage logs, the notes, the ledger), git, and `gh issue list` for the count. It never writes, signals or
locks anything, so it is safe to run while the loop works. `--json` prints the same as one object.

## Report

Lead with the last line, the verdict, in plain words, then the evidence behind it:

| verdict | what to tell the user |
|---------|-----------------------|
| `idle` | nothing is running: no gate, no heavy job of this project, no agent worktree with unmerged work, no recent orchestrator step |
| `working` | agents or the orchestrator did something within the threshold (name the newest: a commit, a notes file, an event) |
| `waiting on gate stage <name> (output <n>s ago)` | the batch gate is running that stage, and its log grew <n> seconds ago: it is alive, just slow; give the stage's elapsed time |
| `waiting on heavy job in slot <n> ...` | a heavy command of this project holds that slot |
| `waiting on <what> ...` | the orchestrator's last step said it waits on that (agents, a review, ...) |
| `possibly stalled: no event or output for <n> min` | nothing moved for longer than `watchdog.stall_minutes` (default 30): no event, no stage log growth, no commit or notes change |

For `possibly stalled`, point at the evidence: the gate line (is its pid alive? which stage, how long?),
the stage log (`tail` it to see where it stopped), the heavy slots (a job holding a slot for a long time),
and the worktrees whose commit and notes are oldest. Do not kill processes or remove files on your own:
suggest the step and wait for the user's OK. A gate whose pid has ended but still shows in
`train-running.txt` was killed; re-running the gate is the fix.
