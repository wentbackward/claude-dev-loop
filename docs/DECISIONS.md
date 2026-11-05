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

## 2026-11-05 — The branch-config fallback fetches the branch first (#9)

- **Decision:** before reading a branch's `.dev-loop.json`, `dl_load_train_config` fetches that one branch
  (`+refs/heads/<branch>:refs/remotes/<remote>/<branch>`, a failed fetch only warns, and the scripts' own fetch then stops the run) and then prefers
  `<remote>/<branch>`, else the local branch. When the config names another remote, only
  `<remote>/<branch>` counts (after its own fetch); when it is missing the scripts stop with a message
  naming it, even if a local branch exists, since the gate stacks `<remote>/<branch>`.
- **Reason:** the gate and the merge check `<remote>/<branch>` right after their own fetch, so the config
  should come from the same commit; one targeted fetch is cheap and keeps a stale tracking ref out.
- **Alternatives:** preferring the local branch when it is ahead (would read a config the gate does not
  check, from unpushed commits); falling back to the local branch when the other remote lacks it (the
  gate then fails later with a less clear message).

## 2026-11-05 — Self-ignoring caches (#11): which folders may be judged file by file

- **Decision:** a new key `merge.rebuildable_caches` (default `node_modules .venv venv __pycache__
  .pytest_cache .mypy_cache .ruff_cache .tox .next .turbo .parcel-cache`) names the folders whose files
  count as build output one by one, when git lists them individually (a cache with its own `.gitignore`).
  A name counts that way only when it is also in `merge.rebuildable`, which keeps its meaning (whole
  entries, default the output folders plus the caches); output folders (`dist build target out coverage
  htmlcov .coverage`) count only as a whole entry, as before. Secret and data names are one list
  (`DL_SECRET_STRONG_PATTERNS` and `DL_SECRET_BROAD_PATTERNS` in `scripts/lib/common.sh`, split by
  #15), matched without regard to case both on a listed entry and by the scan inside a rebuildable
  directory.
- **Reason:** results in an output folder that ignores itself (`out/results.csv`) are not rebuildable,
  while a tool cache's files always are; a separate key leaves existing `merge.rebuildable` settings
  meaning what they did, and requiring both keys means removing a name from `merge.rebuildable` always
  keeps its files.
- **Alternatives:** one list with the ancestor rule for every name (deletes results under `build/`); a
  fixed cache list without a key (no way to add a project's own cache); a marker per entry in
  `merge.rebuildable` (changes the shape of an existing key).

## 2026-11-05 — Component cards and the architecture ratchet (#13): edges, mapping and the gate stage

- **Decision:** the ratchet is on when `architecture.check` is set (`templates/dev-loop.json` carries an
  empty one). The check prints `<from> <to>` edges whose ends are repository paths, or component names
  (an end that matches no card's glob but equals a component's name is that component); a leading `./`
  is dropped. A path belongs to the card whose matching glob is the longest (the first card file in byte
  order on a tie); globs support `*` (also matching `/`) and `?` only. A card is a Markdown file of the
  cards folder whose first line is `---` (other files, an index, are not cards); unknown header keys are
  ignored, `# comments` after a value are stripped, and a `depends_on` line that is present but empty
  allows no dependency. A composition root is never flagged as undeclared, but an upward dependency or a
  cycle is still flagged for it. A component's size is the line count of its tracked text files
  (`git grep -I -c ''`). A budget entry is identified by its component, so it stays known while the
  component is no bigger than its baselined size, and an added baseline entry is one with a new key or a
  bigger budget size. A broken card, a malformed edge line and a failing check command are red (exit 1)
  and block `--baseline`; a missing config, a bad `budget`, an unknown ref, a missing cards folder or a
  folder without cards are config errors (exit 2). The checkout is the current worktree when its HEAD is
  the ref and no tracked file is modified (untracked files do not count, so a gate worktree with build
  output is used in place), else a temporary worktree. In the gate the stage runs after `gate_setup`, so
  a dependency tool the project installs there is available; it checks the train's top once, and only
  when that is red re-checks each train ref in order (checked out in the gate worktree) to name the
  branches, each for the new lines it brings first. The baseline rule compares each branch's baseline
  with the one below it in the train and needs any non-blank line under `## Architecture` in its notes.
  The config is read from the main checkout; the cards and the baseline from the branch.
- **Reason:** the simplest deterministic rules that fit #13 and stay off by default; paths are what every
  dependency tool can print, and component names make a component-level tool usable without a mapping.
  Keying budgets by component keeps the ratchet useful for sizes, which change on every commit.
- **Alternatives:** module names mapped through a separate table (a second source of truth beside the
  cards); the first matching card instead of the longest glob (a broad card would swallow nested ones);
  the stage right after the docs check, before `gate_setup` (the project's tool might not be installed
  yet); checking every train ref on every run (one run of the tool per branch even when green); comparing
  budget lines as plain text (every commit that touches a component over budget would be red).

## 2026-11-05 — Broad secret names are not searched for inside dependency folders (#15)

- **Decision:** the secret and data names are two readonly lists in `scripts/lib/common.sh`:
  `DL_SECRET_STRONG_PATTERNS` (`.env`, `.env.*`, `*.env`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.sqlite`,
  `*.sqlite3`, `*.sqlite-*`, `*.db`) and `DL_SECRET_BROAD_PATTERNS` (`id_rsa*`, `id_ed25519*`, `id_ecdsa*`,
  `id_dsa*`, `credentials*`, `secrets*`). An entry git lists one by one is checked against both. The scan
  inside a rebuildable folder uses both, except when the folder is, or lies inside, a dependency or cache
  folder (any path component in `merge.rebuildable_caches`, so `.venv/lib/` of a `.venv` with its own
  `.gitignore` counts): there only the strong list is used. The lists are set once, so sourcing
  `common.sh` twice does not fail on `readonly`.
- **Reason:** vendored packages ship files such as `credentials.js` or `secrets.py`, which kept every
  merged worktree with a populated `node_modules/` or `.venv/`. Output folders (`build`, `dist`, `out`,
  `target`, ...) hold what a project's own tools write, where `credentials.json` is likely real; there a
  false match only keeps a worktree, while a missed one deletes a secret for good.
- **Alternatives:** the strong list in every rebuildable folder (deletes `build/credentials.json`); an
  allow-list of vendored file extensions (`*.js`, `*.py`), which grows with every ecosystem; judging only
  the last path component (`.venv/lib/` would be scanned with the broad names again).

## 2026-11-05 — The doc-audit marker and the slice loop's config (#21)

- **Decision:** the last doc audit is a marker file in the repository's state directory,
  `~/.dev-loop/<repo>/doc-audit.txt` (`paths.sh doc-audit`), holding one UTC time
  (`2026-01-31T12:00:00Z`). The orchestrator writes it after it reads the doc-auditor's report. `doctor.sh`
  counts the merge ledger's entries whose `merged_at` is later (all of them without a marker), prints
  `docs audit <n> merges since the last audit`, and notes `doc audit due` at `docs.audit_every` (default
  10, a positive number). A marker that is not such a time is MISSING. `docs.prd` is a path or a list of
  paths; doctor prints each and reports a missing one. The audit and PRD lines need `docs.aspects`, like
  the rest of the docs output. The doc-auditor acts as the tester in identity mode (it opens issues).
- **Reason:** the ledger already lives in the state directory and records `merged_at`, so a time next to
  it is all doctor needs; ISO UTC times compare as text in jq and python3. The auditor is read-only, so the
  orchestrator, which owns the loop's state, records the audit. A file outside git keeps the audit from
  needing a commit or a merge of its own.
- **Alternatives:** a tracked file in the repository (each audit would need a branch and a merge); a label
  or comment on the auditor's tickets (needs GitHub and fails when an audit finds no drift); the ledger's
  line count at the audit (breaks when the ledger is pruned or rewritten).

## 2026-11-05 — Ratchet integrity (#17): loosening card edits, kept fixed entries, placeholder reasons

- **Decision:** a card header edit is a loosening edit when it makes violations disappear, measured, not
  classified: `arch-check.sh --loosened <from> <ref>` runs `architecture.check` once in a checkout of
  `<ref>` and judges its edges and line counts twice, by the cards of `<from>` and by those of `<ref>`; a
  violation (by its baseline key) that only the cards of `<from>` report is hidden. It covers every kind of
  edit the issue lists (`depends_on`, `max_lines`, `layer`, `paths`, `kind`) and a removed card, and needs
  no list of field rules to keep in step with the checks. The gate runs it per branch against the train
  ref below it, only for a branch without a reason whose card headers (the parsed header lines, not the
  free text) changed, so a train without header edits runs the tool no extra time.
- A fixed entry: the gate takes the entries the train's top reports as `fixed`; only when there are some
  does it run `arch-check.sh` on the base, and the ones that occur there (by key) are red. The branches are
  then checked in order (as for a new violation) and the first whose train ref reports the entry as fixed
  is named. A train in which one branch fixes an entry and a later one brings it back is green: the merged
  result equals the base. A reason does not excuse a kept fixed entry (removing it is always possible).
- A reason is a line under `## Architecture` with a letter or digit that is not a placeholder. After list
  markers, emphasis and trailing punctuation are stripped, a line is a placeholder when it starts with
  `none`, `nothing`, `n/a`, `na`, `todo`, `tbd`, `tba`, `fixme`, `xxx`, `nil`, `null`, `no`, `empty`,
  `later`, `not applicable`, `not needed`, `none needed`, `no change(s)` or `nothing to report/add/say`
  (any case), followed by nothing or, after spaces, by a non-word character (`:`, `(`, `,`, `;`, a dash).
  So `none: no architecture change` and `No, core must ...` are not reasons, while `none of the edges ...`
  and `no-op rename ...` (a hyphen right after the word joins it) are. HTML comment lines do not count.
  A determined author can still write a sentence that says nothing; the reviewer judges that.
- A change to the `architecture` block of a branch's `.dev-loop.json` (its JSON as `json_get` prints it,
  compared with the train ref below) needs the same reason: the gate reads the main checkout's config, so
  a branch's `check: "true"` would otherwise apply unchecked after its merge. `docs` and `checks` are a
  separate issue.
- When `arch-check.sh` cannot judge the base (exit 2) while the top reports fixed entries, the gate ends
  with exit 2 rather than passing them.
- Two cards listing the identical `paths` glob are an error on the later card (byte order), naming the
  other; the same glob twice in one card is not.
- **Reason:** the simplest deterministic rules that close the gaps of #13 without a tool run per branch on
  every train.
- **Alternatives:** classifying header changes field by field (also red for a widened `depends_on` that
  hides nothing, and a second rule set to keep true); running the tool on every train ref and the base on
  every train (one run per branch even when nothing changed); a reason excusing a kept fixed entry.

## 2026-11-05 — The gate's own rules need a reason under `## Config` (#22)

- **Decision (the orchestrator's, after review):** deny by default. Any change to a branch's
  `.dev-loop.json` needs a reason under `## Config`; the red line names the top-level keys that changed.
  There is no list of gate-relevant keys: every key the plugin reads runs, routes or deletes something
  (`deploy` runs after merges, `format` on every edit, `heavy.clean_temp` globs are deleted, `notes_dir`
  and `logs_dir` are cleaned, `gate_worktree` is checked out and pruned, `remote` and `base_branch` decide
  where pushes and merges go), and a key added later is covered without a change here. A first draft
  flagged a list of 14 keys and called `heavy` "machine resources"; the review showed that wrong.
- `architecture` is judged by #17's rule only: a branch that changes only `architecture` needs the
  `## Architecture` reason, not also a `## Config` one (one reason for one change).
- Each top-level key (taken literally, dots included) compares as compact JSON with sorted keys (`jq -cS`,
  or `json.dumps(sort_keys=True)` without jq) between the train ref below the branch (or the base) and the
  branch's train ref, so a reordered or reformatted file is no change; #17's `architecture` comparison
  uses the same normalization. Array order still counts (the checks run in that order). A deleted file
  changes every key it had; a file that is not a JSON object on one side is named as `.dev-loop.json`.
- A branch whose base has no `.dev-loop.json` is not judged: it adds the first rules (the setup branch),
  and the user reviews the setup.
- The check runs right after stacking, before the docs stage, and needs no config: it reads only git
  objects and the notes. The red line names the keys, not the before and after values (the diff shows
  them).
- The reason rules move to `scripts/lib/reasons.sh` (`dl_notes_reason FILE SECTION`), shared by
  `## Architecture` and `## Config`. The placeholder filter also drops trailing filler (`yet`, `at all`,
  `needed`, `required`, `for now`), repeated placeholders (`none none`, `n/a n/a`), repeated list markers
  (`-- none`) and `nope`, `none yet`, `none required`, `nothing changed`, `not relevant`, `no reason`.
  A placeholder word, a comma and at least three more words that are not a placeholder is a reason
  (`No, the check was redundant`; `none, n/a` and `No, none` are not), which changes #17's rule for
  `No, <sentence>`. A placeholder word and a colon stays a placeholder (`none: ...`), because the notes
  template uses `none: <reason>` as its placeholder. The filter only stops lazy placeholders (`ok` or
  `see above` pass it); the reviewer judges every reason.
- **Reason:** the simplest rule that closes the gap #17 closed for `architecture` without a list to keep
  true, with one shared filter.
- **Alternatives:** an allowlist of gate-relevant keys (missed keys that run or delete things, and every
  new key needs a decision); judging the direction of each change (tighter or looser), which needs a rule
  per key and is the reviewer's job; requiring both reasons for an `architecture` change; reading the
  config from the branch (then a branch would judge itself).
