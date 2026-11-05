---
name: doctor
description: Check that this machine and repository are ready for the dev loop - prerequisites (git, gh login, jq or python3, flock, systemd scopes), the project config and its resolved paths, models per agent, and leftovers of a hand-built loop - then explain each problem and how to fix it. Use when asked to run the doctor, check the dev-loop setup, or find out why the loop, the gate or a hook is not working.
---

# Doctor

Run it from the project (any worktree of it works):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh
```

It never changes anything. Each line starts with `ok`, `note` (works, but worth a look) or `MISSING` (a
problem), and the last line is `doctor: ready` or `doctor: <n> problem(s)`.

## Report

Lead with the verdict (ready, or how many problems), then one line per `MISSING` and `note` with its fix.
Leave out the `ok` lines unless the user asks for them. Common fixes:

| line | fix |
|------|-----|
| `MISSING gh is not logged in` | the user runs `! gh auth login` (interactive; never run it for them) |
| `MISSING .dev-loop.json` or `CLAUDE.md` | the `setup` skill of this plugin |
| `MISSING "checks"` | add the full checks to `.dev-loop.json` (see `templates/dev-loop.json`) |
| `MISSING git remote <name>` | set `remote` in `.dev-loop.json`, or add the remote |
| `MISSING models.<agent>` | use `inherit`, `haiku`, `sonnet`, `opus` or `fable` |
| `MISSING .claude/agents/<agent>.md shadows ...` | the `setup` skill's "Migrate a hand-built loop" step |
| `note project <event> hooks` | compare them with the plugin's hooks; remove copies (same step) |
| `note <n> agent worktrees` | remove the merged ones (same step; ask first, save uncommitted work) |
| `note ... train/replay refs ..., ... merged branches still local` | `cleanup.sh` (dry run), then `--apply` |
| `note <n> local branches` | `cleanup.sh` (dry run): it classifies them; delete closed/stale only on the user's OK |
| `note jq`, `flock` or `systemd` | optional: install it, or accept the fallback the note names |

Fix only what the user asks you to. Anything that deletes files, worktrees or memories needs the user's
OK first. After a fix, run the doctor again and report the new verdict.
