---
name: setup
description: Bootstrap a project for the dev loop - write CLAUDE.md from the template, docs/DECISIONS.md, .dev-loop.json (check, format and gate commands), .claude/settings.json deny rules and missing Makefile targets, asking only for what cannot be inferred. Use when starting the dev loop in a new or existing repository, or when doctor.sh reports missing setup.
---

# Set up a project for the dev loop

Templates: `${CLAUDE_PLUGIN_ROOT}/templates/`. Never overwrite an existing file wholesale: merge into it and
show the user what changed.

## 1. Inspect (do not ask what you can find out)

- `git rev-parse --show-toplevel`, `git remote -v`, the default branch
  (`git symbolic-ref refs/remotes/origin/HEAD`), `gh repo view --json nameWithOwner,visibility`.
- Language and toolchain from the files present: `pyproject.toml`/`uv.lock` (Python, uv), `package.json` +
  lock file (Node: npm, pnpm, yarn, bun), `Cargo.toml` (Rust), `go.mod` (Go), `Gemfile`, `pom.xml` or
  `build.gradle`, a `Makefile`, `.pre-commit-config.yaml`, CI workflows (they show the real check commands).
- The spec: `docs/*SPEC*.md`, `SPEC.md`, `docs/spec/`, or a design doc the README links.
- An existing `CLAUDE.md`, `.claude/settings.json`, `.dev-loop.json`, `docs/DECISIONS.md`.
- Leftovers of a hand-built loop (the project ran its own loop before the plugin, or started from an early
  copy of it); see step 3a:
  - `.claude/agents/` files named `implementer`, `code-reviewer`, `test-engineer` or `verifier` (they
    shadow the plugin's agents), or agents that do the same job under another name (a data or QA auditor
    is an early `verifier`).
  - Hooks in `.claude/settings.json` and scripts in `.claude/hooks/` that format on edit or gate the Stop
    (the plugin brings its own; both would run).
  - Gate, merge-train, heavy-queue or PR-opening scripts the project or `CLAUDE.md` refers to, inside or
    outside the repository, and the notes and logs they keep.
  - `CLAUDE.md` workflow sections that describe their own gate or merge (full checks per branch, merging
    with `gh pr merge` by hand, a private script path).
  - The project's Claude memories (`~/.claude/projects/<project path with / as ->/memory/`) that tell the
    session to use that tooling.
  - Worktrees: `git worktree list`, `.claude/worktrees/` and `../<repo>-*` directories of merged work.

## 2. Ask once, only for what is still unknown

In one question round (AskUserQuestion if available), with your inferred answer as the default option:
the language/toolchain if ambiguous, the fast check and the full check commands if no Makefile or CI
shows them, the spec location if none was found, and the cost cap and project-specific dangers for the
stop conditions. Skip any question whose answer you already have.

## 3. Write

1. **`.dev-loop.json`** from `templates/dev-loop.json`:
   - `fast_check`: seconds, e.g. format check + lint (`make fmt-check lint`, `npm run lint`,
     `cargo fmt --check && cargo clippy -q`, `gofmt -l . | (! grep .) && go vet ./...`).
   - `format`: formats one file, `{file}` is the path (`uv run ruff format {file}`,
     `npx prettier --write {file}`, `rustfmt {file}`, `gofmt -w {file}`), with `format_extensions`.
   - `checks`: the full checks in order (`make check`, `make e2e`, ...), `"heavy": false` for quick ones,
     a `summary` regex that picks the result lines from the log.
   - `affected`, `parallel`, `fail_fast`: off unless the user wants faster red trains (see the `gate`
     skill). `affected` needs a project command that maps the changed files (`$DL_CHANGED_FILES`) to
     the tests they touch; `parallel` needs `heavy.slots` and `memory_max` that fit the checks at once.
   - `heavy`: `slots` 2 and `memory_max` about half the machine's RAM (`free -g`), `port_env` if e2e
     servers read their port from an environment variable.
   - `models`: keep the template's choice per agent unless the user named models; `inherit` means the
     main session's model.
   - Remove keys you do not need (`gate_setup`, `deploy`, `identities`, ...). Leave `notes_dir` empty
     (notes then live in `~/.dev-loop/<repo>/notes`, outside git and shared by all worktrees).
2. **`CLAUDE.md`** from `templates/CLAUDE.md`: fill every `{{...}}` placeholder from what you found and
   the answers; delete lines that do not apply. With an existing CLAUDE.md, add only the missing sections
   (operating mode and stop conditions, workflow loop, parallel work, secrets and safety) and keep the
   project's own rules.
3. **`docs/DECISIONS.md`** from `templates/DECISIONS.md` if missing; add a first entry recording the setup
   choices you made without asking.
4. **`.claude/settings.json`**: merge the `permissions.deny` rules of `templates/settings.json` into the
   existing file (union, no duplicates), e.g.
   `jq -s '.[0] * {permissions: {deny: ((.[0].permissions.deny // []) + .[1].permissions.deny | unique)}}' .claude/settings.json ${CLAUDE_PLUGIN_ROOT}/templates/settings.json`.
   The plugin's hooks come with the plugin; do not copy them into the project.
5. **Makefile targets**, only the missing ones, as thin wrappers around the toolchain: `setup`, `fmt`,
   `fmt-check`, `lint`, `typecheck`, `test`, `cov`, `check`, `e2e`. For example (Python with uv):
   `fmt-check: ; uv run ruff format --check .`, `check: fmt-check lint typecheck cov`. Skip this step for
   projects whose scripts (npm scripts, cargo aliases) already cover the commands; point `.dev-loop.json`
   at those instead.
6. Add `.dev-loop/` to `.gitignore` when `notes_dir` or `logs_dir` point inside the repository.

## 3a. Migrate a hand-built loop (only when step 1 found leftovers)

The plugin replaces the copies; the project-specific knowledge in them stays.

1. Before deleting a copy, move what is specific to this project into `CLAUDE.md` (a "Process specifics"
   section): extra tests to run before every push, reserved ports, browser or environment quirks, the
   verification commands and spot checks of an old QA agent, the deploy procedure. Settings the old gate
   used (checks, slots, memory cap, port variable, temp cleanup, setup commands) go into `.dev-loop.json`.
2. Inside the repository, on the setup branch: delete the shadowing agents, the duplicate hooks and their
   `hooks` entries in `.claude/settings.json`, and stale `.gitignore` lines for their state files; replace
   the `CLAUDE.md` workflow sections with the template's; tell the session in `CLAUDE.md` to work through
   the `dev-loop` skill and not to write gate, merge, queue or worktree tooling of its own.
3. Outside the repository, show the user the list and ask before changing anything:
   - Old scripts, notes and logs: move them to an archive directory rather than deleting them. Keep files
     a procedure still reads (for example a deploy log used as a `find -newer` marker).
   - Memories that describe the old tooling: rewrite them to point at the plugin, or delete them.
   - Worktrees: only when no agent is running. Save the uncommitted changes of each one (`git diff HEAD`
     and the untracked files) to the archive, keep every branch, then `git worktree remove --force --force`
     (locked ones included) and `git worktree prune`.
   - Branches: run `${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh` (a dry run), show the user the counts and
     the closed and stale lists, then `--apply` (with `--include closed` / `--include stale` as they
     agree). It saves every deleted tip to a bundle first.
4. Record the migration in `docs/DECISIONS.md`: what was retired, where the project specifics went.

## 4. Check and commit

- `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh` must end with `doctor: ready` (gh authenticated, config valid,
  no project agent shadowing a plugin agent) and print no leftover notes you have not dealt with.
- Run the fast check once and each full check once (through `${CLAUDE_PLUGIN_ROOT}/scripts/heavy.sh`) to
  prove the commands work; fix the config if not.
- Commit on a branch: `chore: set up the dev loop` with the files above, then follow the dev loop to merge
  it (or commit to the base directly in a brand-new repository with no history).

## 5. Optional: one GitHub identity per role

Off by default; the loop works with the user's own GitHub login. If the user wants server-enforced roles
(implementer, tester, reviewer, gate, orchestrator as separate GitHub Apps with repository rulesets), tell
them to run, in their own terminal (not through Claude):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/setup-identities.sh
```

It needs a browser click per app ("Create GitHub App", then "Install") and writes the `identities` block.
Rulesets need a public repository or a paid GitHub plan for a private one. See the README section
"Per-role identities in 5 minutes".
