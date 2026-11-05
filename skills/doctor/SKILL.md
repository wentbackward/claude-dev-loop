---
name: doctor
description: Check that this machine and repository are ready for the dev loop - prerequisites (git, gh login, jq or python3, flock, systemd scopes), the project config and its resolved paths, models per agent, the current-state docs, the component map, and leftovers of a hand-built loop - then explain each problem and how to fix it. Use when asked to run the doctor, check the dev-loop setup, or find out why the loop, the gate or a hook is not working.
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
| `MISSING .dev-loop.json` or `CLAUDE.md` (neither `CLAUDE.md` nor `.claude/CLAUDE.md`) | the `setup` skill of this plugin |
| `MISSING "checks"` | add the full checks to `.dev-loop.json` (see `templates/dev-loop.json`) |
| `MISSING git remote <name>` | set `remote` in `.dev-loop.json`, or add the remote |
| `MISSING models.<agent>` | use `inherit`, `haiku`, `sonnet`, `opus` or `fable` |
| `MISSING .claude/agents/<agent>.md shadows ...` | the `setup` skill's "Migrate a hand-built loop" step |
| `note project <event> hooks` | compare them with the plugin's hooks; remove copies (same step) |
| `note <n> agent worktrees` | remove the merged ones (same step; ask first, save uncommitted work) |
| `note ... train/replay refs ..., ... merged branches still local` | `cleanup.sh` (dry run), then `--apply` |
| `note <n> local branches` | `cleanup.sh` (dry run): it classifies them; delete closed/stale only on the user's OK |
| `MISSING docs aspect <name>: <path> does not exist` | create the doc (the `setup` skill's step 3b), or fix the path in `docs.aspects` |
| `MISSING docs.map rule <n>: "<name>" is not in docs.aspects` | name a configured aspect, or add the aspect |
| `note <file> has <n> lines, over docs.max_lines` | split it: an index and one file per area |
| `note docs map rule <n> (...) matches no tracked file` | fix the globs (`*` also matches `/`), or drop the rule |
| `MISSING docs.prd: <path> does not exist` | fix the path in `docs.prd`, or drop a PRD that was archived |
| `MISSING docs.audit_every: ...` | a positive number of merges (default 10) |
| `MISSING doc audit marker ...` | write one UTC time to it: `date -u +%Y-%m-%dT%H:%M:%SZ >"$(paths.sh doc-audit)"` |
| `note doc audit due` | run the `doc-auditor` (the `dev-loop` skill's section 7a), then record the audit as the note says |
| `MISSING architecture: <card>: ...` | fix the card's header (see `templates/COMPONENT.md`) |
| `MISSING architecture: architecture.check failed ...` | run the command by hand in the project and fix it |
| `MISSING architecture.cards: ... does not exist` or `no component cards` | the `setup` skill's step 3c, or fix `architecture.cards` |
| `note component over its line budget` | split the component, or raise its `max_lines` with a reason in the decisions log |
| `note no component: <path>` | add the path to a card's `paths`, or leave it out of `architecture.check` |
| `note architecture baseline: <n> entries` | known violations; each ticket that fixes one removes it |
| `note architect due` | run the architecture review (the `dev-loop` skill's section 7b), then record the run as the note says |
| `MISSING architecture.<threshold>: ...` | a whole number (`cadence` at least 1); the defaults are in the README |
| `MISSING architect marker ...` | write one UTC time to it: `date -u +%Y-%m-%dT%H:%M:%SZ >"$(paths.sh architect)"` |
| `MISSING scenario <file>: <reason>` | fix the scenario's front matter or body (see `templates/scenario.md`); a duplicate id gets a new id |
| `MISSING scenarios.<key>: ... is not a number from 0 to 1` | set `pass`, `min_satisfaction` or `sealed` to a share such as `0.8` |
| `note scenario store ... does not exist yet` | create the folder (`paths.sh scenarios`) and add scenarios written from the spec |
| `note the scenario store ... is inside the repository` | move it outside every worktree (the default `~/.dev-loop/<repo>/scenarios`) |
| `note jq`, `flock` or `systemd` | optional: install it, or accept the fallback the note names |

Fix only what the user asks you to. Anything that deletes files, worktrees or memories needs the user's
OK first. After a fix, run the doctor again and report the new verdict.
