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
| `idle` | nothing is running and nothing is in flight: no gate, no heavy job of this project, no wait that still holds, no agent worktree with unmerged work changed since the orchestrator's last `idle` event, no agent started and not reported; a recent orchestrator step on its own is not work |
| `idle (the last gate died: train-running.txt is stale)` | the last gate was killed before it could clean up; its train did not finish, so re-run the gate |
| `working` | an agent is in flight (the `agents in flight` line) or a loop worktree has unmerged work, and something moved within the threshold (name the newest: a commit, a notes file, an event) |
| `waiting on gate stage <name> (output <n>s ago)` | the batch gate is running that stage, and its log grew <n> seconds ago: it is alive, just slow; give the stage's elapsed time |
| `waiting on heavy job in slot <n> ...` | a heavy command of this project holds that slot |
| `waiting on heavy slot (queued)` | the gate's own heavy check waits in `heavy.sh` for a free slot (all slots are busy, maybe with another project's long job); the gate is alive, not stalled |
| `waiting on <what> ...` | the orchestrator's last step said it waits on that (agents, a review, ...); a wait on a gate or branches ends by itself once a gate result or a merge of those branches came after it (the orchestrator line then says `the wait is over: ...`) |
| `possibly stalled: no event or output for <n> min` | nothing moved for longer than `watchdog.stall_minutes` (default 30): no event, no stage log growth, no commit or notes change; while the gate runs only the gate's own output counts |

For `possibly stalled`, point at the evidence: the gate line (is its pid alive? which stage, how long?),
the stage log (`tail` it to see where it stopped), the heavy slots (a job holding a slot for a long time),
and the worktrees whose commit and notes are oldest. Do not kill processes or remove files on your own:
suggest the step and wait for the user's OK. A gate whose pid has ended but still shows in
`train-running.txt` was killed; re-running the gate is the fix.

The loop's own heartbeat (the `dev-loop` skill, section 2a) reads the same verdict with `--json` when its
fallback wake-up fires, and confirms a stall before it stops anything of the loop's own; a check with
`stall_minutes` is stopped by the gate itself and shows as `<name> stalled: no output for <n> min`.
