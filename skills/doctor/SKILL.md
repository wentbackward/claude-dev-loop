---
name: doctor
description: Check that this machine and repository are ready for the dev loop - prerequisites (git, gh login, jq or python3, flock, systemd scopes), the project config and its resolved paths, models per agent, the project's permission rules, the marketplace source and pin in the settings, the current-state docs, the component map, and leftovers of a hand-built loop - then explain each problem and how to fix it. Use when asked to run the doctor, check the dev-loop setup, or find out why the loop, the gate or a hook is not working.
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
Leave out the `ok` lines unless the user asks for them. A fix that changes `.claude/settings.json` or
`.claude/settings.local.json` is the owner's step: the agent may not change its own permissions, so show
the owner the line to run (for the rules `permissions.sh` adds, the dry run's last line,
`! ${CLAUDE_PLUGIN_ROOT}/scripts/permissions.sh --apply` with the plugin's absolute path, run in the
session as the owner) or the rule to move, and wait; never edit those files yourself. Common fixes:

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
| `note permissions: no .claude/settings.json` or `note permissions: no allow list` | the `setup` skill's Permissions step: `permissions.sh` (dry run), then the owner runs `! ${CLAUDE_PLUGIN_ROOT}/scripts/permissions.sh --apply` (the dry run's last line, with the absolute path) |
| `note permissions: the allow list lacks the project commands: ...` or `lacks <n> of the loop's rules` | `fast_check` or `checks` changed, or the plugin moved: the owner runs the `!` apply line the note names |
| `MISSING worktrees: <dir> is outside the working directory and not in permissions.additionalDirectories` or `MISSING notes: <dir> ...` | the owner runs the `!` apply line the line names (it adds the directory to `.claude/settings.local.json`) |
| `MISSING worktrees: <n> loop worktrees outside the working directory ...` | set `"worktrees_dir": "../<repo>-worktrees"` in `.dev-loop.json`, then the owner runs the `!` apply line the line names; existing worktrees stay where they are |
| `MISSING worktrees_dir: <dir> holds the project` | use a dedicated directory such as `../<repo>-worktrees`, never the project's parent |
| `note worktrees: <n> loop worktrees of the old layout ...` | nothing to do: they finish where they are (edits there ask in auto mode until they merge) |
| `MISSING permissions: deny rule <rule> in <file> blocks "<command>"` | remove or narrow that deny rule in the project's settings file (the loop runs the command) |
| `MISSING permissions: deny rule <rule> in <file> blocks "<command>": no release can be made ...` | a deny on `git tag`, `gh release` or a tag push: move it to `ask` in that file (the template asks; releases happen on the owner's go) |
| `note permissions: ask rule <rule> in <file> stops "<command>" ...` | the rule asks for a command the loop runs (ask beats allow, so auto mode stops every time): the owner narrows it in that file, e.g. to the paths it guards; a `... matches inside other words` remark means a leading `*` before a short word such as `*go` also catches `cargo` |
| `note remote protection: <base> on <repo> does not require a pull request, ...` or `release tags (v*) on <repo> are not protected against creation, update, deletion` (also `... for the current gh login (it can bypass ruleset "<name>")` or `admins can push past ...`) | the remote's branch and tag protection is the boundary (the git guard and the permission rules are tripwires): the owner adds a branch ruleset (or branch protection that includes administrators) that requires a pull request and blocks force pushes and deletion, and a tag ruleset for `refs/tags/v*` with the creation, update and deletion rules, both without a bypass for the loop's login, at the settings page the note names or with `gh api -X POST repos/<repo>/rulesets`; never apply it for them |
| `note remote protection: ... could not be checked (...)`, `... is not a GitHub remote` or `github.api_url is ...` | nothing is wrong with the loop: `gh auth login` (the user) or the owner's access lets doctor read it, a hung call stops after `DEV_LOOP_GH_TIMEOUT` seconds; otherwise (GitHub Enterprise too) the owner checks the repository's rules by hand |
| `note current-state docs off: ...` | nothing is wrong; to adopt the docs, the `setup` skill's step 3b (gradual adoption for large existing docs) |
| `MISSING docs aspect <name>: <path> does not exist` | create the doc (the `setup` skill's step 3b), or fix the path in `docs.aspects` |
| `MISSING docs.map rule <n>: "<name>" is not in docs.aspects` | name a configured aspect, or add the aspect |
| `note <file> has <n> lines, over docs.max_lines` | split it: an index and one file per area |
| `note journal <file> has <n> lines, over max_lines <m>` | compact it in a `docs/` ticket: `docs-archive.sh journal` (dry run), then `--apply` |
| `note docs map rule <n> (...) matches no tracked file` | fix the globs (`*` also matches `/`), or drop the rule |
| `MISSING docs.prd: <path> does not exist` | fix the path in `docs.prd`, or drop a PRD that was archived |
| `MISSING docs.audit_every: ...` | a positive number of merges (default 10) |
| `MISSING docs.planned_max_days: ...` | a whole number of days, or `0` (or no key) to keep the age check off |
| `note planned row #<n>: ticket closed, move it to Features` | move the entry to Features (it was built) |
| `note planned row #<n>: ticket closed as not planned, remove the row` | remove the row; the PRD keeps the intent |
| `note planned row #<n>: open <d> days with no branch ...` | close the ticket as not planned and remove the row, or slice it now |
| `note planned row #<n>: no such ticket` | link the row's real ticket (an issue, not a PR) |
| `note planned row at <file>:<line> has no ticket number` | open its ticket and link it, or move the item to the PRD |
| `note planned rows not checked` | `gh auth login` (the user), then run the doctor again |
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
| `MISSING factory: "<value>" is not collaborative or dark` | set `"factory"` to `collaborative` or `dark`, or remove it (collaborative) |
| `MISSING factory dark: no scenario store with a valid required scenario` | the `setup` skill's go-dark step: write scenarios from the spec, at least one `required: true`; or set `"scenarios": false` |
| `factory <mode>, scenarios on\|off (preset\|explicit\|default)` | where the scenarios setting came from: the dark preset, the config, or the default |
| `MISSING marketplace <name>: the <scope> settings entry (<source>) does not match the configured marketplace (...)` | `marketplace add` fails until they match: run the `claude plugin marketplace add <source>` the line names (the user runs it; it is outside the repository), or change that entry's `ref` and add it from that ref |
| `note marketplace <name> is in the <scope> settings but not added yet: ...` | the user runs the `claude plugin marketplace add` command the note names, then installs the plugin |
| `note marketplace <name> is pinned to <ref>, older than the installed plugin <version>` | move the entry's `ref` to the tag the note names, add the marketplace from it, then `claude plugin update dev-loop@claude-dev-loop` (the README's Install section) |
| `marketplace <scope> settings: <source>`, `configured: ...`, `installed: ...` | information: the entries found, the marketplace Claude Code configured, the installed version; nothing without entries |
| `note jq`, `flock` or `systemd` | optional: install it, or accept the fallback the note names |
| `note TMPDIR ...` or `MISSING TMPDIR ...` | under 10% (note) or 2% (MISSING) free space or inodes on TMPDIR's filesystem (default `/tmp`; agents stop when it is full): free space; leftover `dev-loop-smoke.*` / `dev-loop-identity.*` dirs of red test runs can go once no test runs |

Fix only what the user asks you to. Anything that deletes files, worktrees or memories needs the user's
OK first. After a fix, run the doctor again and report the new verdict.
