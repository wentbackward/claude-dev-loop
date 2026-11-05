# CLAUDE.md — {{PROJECT_NAME}}

{{ONE_PARAGRAPH_WHAT_THIS_PROJECT_IS}}
The spec is `{{SPEC_PATH}}`. It is the source of truth.

## Operating mode: autonomous

- Work end to end without asking for approval: plan, ticket, build, test, commit, review, gate, merge, run,
  verify. The workflow is the `dev-loop` skill of the dev-loop plugin.
- Stop and ask only for the items in "Stop conditions" below.
- When the spec is silent, choose the simplest option that fits the spec, record it in `docs/DECISIONS.md`
  (one entry: date, decision, reason, alternatives), and continue. Do not stop for it.
- Never wait idle on a long job. Start it in the background, verify the first output, then continue with
  other tickets.

### Stop conditions (the only reasons to stop and ask)

1. A required credential or key is missing or rejected ({{CREDENTIALS_E_G_API_KEYS_GITHUB_AUTH}}).
2. A paid action would exceed the cost cap: {{COST_CAP_OR_NONE}}.
3. The spec contradicts itself and both readings change the data that gets stored or the behaviour users
   rely on.
4. Anything unsafe or irreversible: production data, real money or orders, deleting history, security
   settings, {{PROJECT_SPECIFIC_DANGERS}}.

## Workflow loop (repeat until the spec's Definition of Done is met)

1. **Tickets.** One GitHub issue per work item of the spec's work breakdown, with acceptance criteria,
   dependencies and labels. Keep issues current; close them through `Closes #n` on merge.
2. **Branch per ticket:** `feat/<issue>-<slug>` (or `fix/`, `chore/`, `docs/`), each in its own worktree.
3. **Test first.** Failing tests from the acceptance criteria, then the code.
4. **Targeted tests only** while implementing, plus the fast check (`{{FAST_CHECK_COMMAND}}`). The full
   checks run once per batch in the gate.
5. **Commit often:** small Conventional Commits (`feat:`, `fix:`, `test:`, `refactor:`, `chore:`,
   `docs:`), each referencing the issue (`Refs #12`).
6. **Review:** the `code-reviewer` agent on every branch diff; fix every "must fix" item; re-review until
   APPROVE.
7. **Batch gate and merge:** approved branches are stacked on the latest `origin/{{BASE_BRANCH}}` and
   checked once (`{{FULL_CHECK_COMMANDS}}`); a green train is merged in order, one squash merge per
   ticket. A red train is never merged. Local checks are the merge gate; {{CI_POLICY_E_G_CI_ONLY_ON_TAGS}}.
8. **Run it.** After a job ticket merges, run the job for real and verify its outputs (the `verifier`
   agent); record the result in the issue.

### Parallel work

- At most 3 implementer agents, one ticket each, each in its own git worktree. The main session owns
  tickets, merges and deploys.
- Merge in dependency order. Stacked branches are rebased with `--onto`, never carrying foreign commits.
- Heavy commands (full suite, e2e, long builds) only through the plugin's `heavy.sh` queue.

## Documentation

The current-state docs say what the system does now: {{DOCS_ASPECTS_E_G_FEATURES_ARCHITECTURE_OPERATIONS}}
(`docs` in `.dev-loop.json`). They are kept true by every merge.

- **Built, not planned.** The current-state docs describe only what is built. Planned work lives in the
  tickets and the planned list (`{{PLANNED_LIST_PATH}}`), which links them. Specs and the PRD are
  proposals: as a ticket merges, its part moves into the current-state docs in the same branch; a spec
  whose work has all merged is archived.
- **Same branch as the code.** Every branch updates the docs it makes untrue. Each ticket names the doc
  sections it changes; for a feature, the change to Features is written first, as the intended state.
- **Notes `## Docs`** (required): the doc changes, or `none: <reason>`. The gate's docs check is red for
  code a `docs.map` rule covers without one of its docs or a reason, and for broken relative links.
- **One fact, one place;** other docs link to it. `docs/DECISIONS.md` is the only history (why). This
  file holds rules for agents, not a description of the system.
- **Small enough to read:** one folder per aspect with an index and one file per area, each under
  `docs.max_lines` lines (`doctor.sh` notes the bigger ones).

## Engineering rules

- {{LANGUAGE_AND_VERSION}}, managed with {{TOOLCHAIN}}. Source under `{{SOURCE_DIR}}`, tests under
  `{{TEST_DIR}}`.
- Tooling: {{FORMATTER}}, {{LINTER}}, {{TYPE_CHECKER}}, {{TEST_RUNNER}}, {{COVERAGE_TOOL}}.
- Make targets (keep them working): `setup`, `fmt`, `fmt-check`, `lint`, `typecheck`, `test` (fast unit
  tests), `cov` (with the coverage gate), `check` (fmt-check + lint + typecheck + cov), `e2e`.
- Coverage gate: {{COVERAGE_PERCENT}}% lines for `{{SOURCE_DIR}}`.
- Clean code:
  - Small functions with one job. Clear names. No abbreviations except domain terms.
  - Pure functions for logic; I/O at the edges.
  - Depend on interfaces, inject dependencies. No module-level state, no singletons.
  - Full type information. No escape hatches (`Any`, `unknown` casts, `unsafe`) without a comment.
  - No bare catch-all error handling. No print debugging; use the project's logger.
  - Configuration only through {{CONFIG_MECHANISM}}. No hard-coded paths.
  - Public functions and types have a one-line doc comment that states intent.
  - Delete dead code. No commented-out code.
- Tests:
  - Unit tests are fast (whole suite under {{UNIT_SUITE_SECONDS}} s), deterministic, no network.
  - External services are replaced by fakes implementing the same interface, plus recorded fixtures.
  - Tests that need a real service are marked and skip when it is unavailable.
  - Property-based tests for invariants (aggregation, round trips, ordering, date logic).
  - One test file per module. Test names state the behaviour.
- Data rules: source data is never modified. Writes are atomic (temp file, then rename). Timestamps carry
  their time zone.

## Secrets and safety

- Secrets live in `.env` (never committed) or the OS keychain. Never print secret values in logs, commits,
  issues, PRs or chat. Agents never read `.env`.
- No personal identifiers (real user names, account numbers, emails, private hostnames) in tracked files,
  commits, issues or PRs. Use role words and placeholders.
- {{PROJECT_SAFETY_RULES_E_G_TEST_ENVIRONMENTS_ONLY_FOR_AGENTS}}
- Do not touch anything outside this repository and {{ALLOWED_EXTERNAL_PATHS_OR_NONE}}.

## Talking to the user

- Plain language; lead with results; no internal jargon or milestone codes.
- Ask only when the answer changes what you do.

## Commands you will use

- `{{RUN_COMMAND}}` — run the project.
- `{{FAST_CHECK_COMMAND}}` — the fast check (also the Stop hook).
- `{{FULL_CHECK_COMMANDS}}` — the full checks (the batch gate runs them; do not run them in parallel).
- `gh issue list --state open` — ticket status.
