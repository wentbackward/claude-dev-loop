# CLAUDE.md — claude-dev-loop

The dev-loop plugin for Claude Code: an autonomous, test-first, multi-agent development loop (tickets,
worktree implementers, independent review, a batched merge gate, ordered merges). It is mostly bash: skills
and agent briefs in Markdown, scripts in `scripts/`, hooks in `hooks/`, templates in `templates/`. The
source of truth for what it does is the open and closed GitHub issues plus `README.md` and the skills;
`CHANGELOG.md` records each change.

## Operating mode: autonomous

- Work end to end without asking for approval: ticket, build, test, commit, review, gate, merge. The
  workflow is the `dev-loop` skill of this plugin, installed from the latest release: the released
  version builds the next one. Never edit the installed copy under `~/.claude/plugins/`.
- When the issue is silent, choose the simplest option that fits it, record it in `docs/DECISIONS.md`, and
  continue.

### Stop conditions (the only reasons to stop and ask)

1. A release: the version number, the tag and the GitHub release happen only on the user's go.
2. Anything outside this repository: other projects are read-only evidence; never
   change their files, branches or issues, and never change the user's Claude settings or plugin installs.
3. The issue contradicts itself in a way that changes what users of the plugin rely on.
4. Anything irreversible on GitHub other than the loop's own branch and PR operations (deleting issues,
   releases or tags, rewriting `main`).

## Workflow loop

1. **Tickets:** one GitHub issue per piece of work, with acceptance criteria; large features are split
   into numbered parts (5a, 5b, ...), each its own issue.
2. **Branch per ticket:** `feat/<issue>-<slug>` (or `fix/`, `chore/`, `docs/`), each in its own worktree.
3. **Test first:** failing smoke tests (`tests/smoke.sh`, `tests/identity.sh`) for each criterion.
4. **Targeted checks while implementing:** `make lint`, and the test section you touched with
   `tests/smoke.sh --section <id or name>` (`--list` names them), from a fresh `mktemp -d` directory with
   `TMPDIR` set to it. The gate runs `make check` once per batch.
5. **Commits:** small Conventional Commits, each `Refs #<n>`.
6. **Review:** the `code-reviewer` agent on every branch; fix every must-fix item; a fresh reviewer per
   round until APPROVE.
7. **Gate and merge:** `gate-train.sh`, then `merge-train.sh`; never merge red.
8. Every user-visible change gets an entry under `## Unreleased` in `CHANGELOG.md` and the README and skill
   text that describe it, in the same branch.

## Engineering rules

- Bash, `set -u`, shellcheck clean (`make lint`). Python helpers only with `python3 -I`, ruff clean.
- **Portable to Linux and macOS:** bash 3.2 features only; no GNU-only tool options (`find -printf`,
  `xargs -r`, `sed -i` without a suffix, `touch -d`, `date -d`); prefer plain globs, `awk`, `git`.
- JSON through `json_get` and `cfg` in `scripts/lib/common.sh` (jq, else python3).
- Every option is off or backwards compatible by default: a project without the new key behaves as before.
- Anything that deletes is a dry run by default, conditional on what was classified, archived first, and
  tested for the dangerous direction (what must never be deleted).
- Tests run on throwaway repositories with a local bare origin and `tests/fake-gh`; no network, no real
  GitHub, nothing outside `$TMPDIR`.
- Small functions with one job, clear names, a one-line comment that states intent for each function; no
  dead or commented-out code.

## Secrets and safety

- This repository is public. No personal identifiers, private project names, private paths or hostnames,
  account numbers or credentials in tracked files, commits, issues or PRs. Evidence from other projects is
  described without naming them.
- Never read `.env` files or credential files.

## Installing the plugin here

The project enables `dev-loop@claude-dev-loop` (`.claude/settings.json`). On a fresh machine add the
marketplace at the latest release tag first: `claude plugin marketplace add
wentbackward/claude-dev-loop@<latest tag>`, then `claude plugin install dev-loop@claude-dev-loop --scope
project`. After a release, move the pin to the new tag and run `claude plugin update`.

## Commands you will use

- `make lint` — the fast check (also the Stop hook).
- `make check` — validate, lint, smoke and identity tests (the gate runs it).
- `gh issue list --state open` — ticket status.
