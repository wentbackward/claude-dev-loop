# Decisions log

One entry per decision where the spec is silent. Newest last. Format: date, decision, reason, alternatives.

## 2026-11-05 — The plugin is built with its own dev loop

- **Decision:** this repository runs the dev-loop plugin on itself: `.dev-loop.json` (fast check `make lint`, one gate check `make check`), the plugin enabled at project scope from the latest GitHub release, implementer agents in worktrees, the plugin's `code-reviewer`, PRs from notes files, `gate-train.sh` and `merge-train.sh` for every merge. Releases (version, tag, GitHub release) stay a separate step on the user's go.
- **Reason:** using the plugin on itself is its cheapest real test. The gate and merge scripts come from the released plugin, while the gate checks the branch's own code, so the stable version builds the next one.
- **Alternatives:** the method by hand, with direct merges to `main` (what was done up to 0.5.0): it never exercised the scripts being changed. The plugin from the working tree (a local marketplace): the tool would change under its own run.

## 2026-11-05 — The setup branch's config is copied into the state directory

- **Decision:** when the main checkout has no `.dev-loop.json` and `DEV_LOOP_CONFIG` is unset, `gate-train.sh` and `merge-train.sh` copy the config of the branch (`origin/<branch>`, else the local branch; then `<remote>/<branch>` when the config names another remote) to `~/.dev-loop/<repo>/branch-config.json` and export `DEV_LOOP_CONFIG`, so the scripts they run (`heavy.sh`, `open-pr.sh`, `as-role.sh`) read the same config. Without branches, or when the branch has no config, the error stays as before.
- **Reason:** a file in the state directory needs no cleanup trap (both scripts already own their EXIT traps) and is overwritten on the next use; exporting the variable is the existing override every script already honours.
- **Alternatives:** a temporary file removed on exit (would compete with the scripts' own traps); documenting `DEV_LOOP_CONFIG=<(git show ...)` in the setup skill (a manual step, and a process substitution does not reach child scripts reliably).

## 2026-11-05 — Current-state docs (#6): config shape and checks

- **Decision:** the docs are on when `docs.aspects` has at least one entry; `templates/dev-loop.json`
  carries a valid `docs` block with empty `aspects` and `map`, so a project copied from the template
  behaves as before. `docs.planned` is a path, checked by `doctor.sh` like an aspect but not size-checked.
  `docs-check.sh` skips links with any URL scheme (not only http(s) and mailto), absolute paths, links
  inside fenced or inline code, reference-style links (`[x]: path`) and targets with nested parentheses
  (`a_(b).md`), and does not link-check Markdown files deleted in the range. It understands
  `<path with spaces>` and decodes `%20` only (other percent-escapes are not decoded). A `<from>` that is
  not an ancestor of `<to>` is replaced by their merge base. The gate reads `docs` from the main
  checkout's config, so a branch cannot change the rules of its own check. A
  `none: <reason>` line may be a list item and exempts the whole branch, every rule. The gate checks every
  branch of the train and reports all red ones before ending `TRAIN RED`; a config error (exit 2) ends the
  gate with exit 2. A map rule naming an unknown aspect is a config error in `docs-check.sh` and MISSING in
  `doctor.sh`. The helpers live in `scripts/lib/docs.sh`, shared by the three scripts.
- **Reason:** the simplest rules that fit #6, deterministic and off by default; a template block that is
  valid JSON documents the keys where users copy them from.
- **Alternatives:** no `docs` block in the template, documented only in the README (less discoverable); a
  block with example aspects (would turn the check on for projects that copy it unchanged, with paths that
  do not exist); a `none:` per rule (more ceremony than the notes need); stopping at the first red branch
  (hides the others until the next run).
