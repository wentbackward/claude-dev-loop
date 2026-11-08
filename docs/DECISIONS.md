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

## 2026-11-05 — Merge evidence and the architect (#19): ledger fields, signals and thresholds

- **Decision:** `merge-train.sh` computes the evidence in the gate worktree right after the replay: `files`
  and `lines` from `git diff <remote>/<base> <replayed head>` (exactly what the squash commit changes;
  names read NUL-separated and stored as real paths, JSON-escaped, a byte that is not UTF-8 replaced by
  U+FFFD so every line stays valid UTF-8 JSON; `arch-evidence.sh` reads a tab or a line break in a name
  as a space), encoded by jq only when a probe shows it reads NUL-separated input whole (jq 1.6's
  raw slurp may stop at the first NUL), else by python3; with neither, by bash, which drops names that hold
  a tab, a line break or another control character and keeps other bytes as they are (the bash line form
  that `arch-evidence.sh` and the `components` field read drops the same names, #27). The line counts of
  `dl_arch_line_counts` and of the growth signal still split a path with a tab or a line break, so such a
  file may be miscounted there: a heuristic for the evidence only, never what the ledger stores, `components` through the cards
  of the replayed head (empty without `architecture.check`), `ticket` from the notes' first `Closes`,
  `Fixes` or `Resolves #n`, else the branch's `<type>/<n>-` number, else `null`, and `review_rounds` from a
  `Review rounds: <n>` line in the notes, else one plus each `Review fixes` heading, `0` without a notes
  file. The fields are always written, so every new line has the same shape.
- `arch-evidence.sh` maps the ledger's `files` through today's cards, not the `components` recorded at
  merge time, so the signals follow renamed and split components; a line without `files` gets them from
  its merge commit. Its default window is the merges since the architect's marker
  (`~/.dev-loop/<repo>/architect.txt`, one UTC time, written by the orchestrator after a run, as for the
  doc audit), else the last `architecture.cadence` merges; doctor uses the same window.
- Growth is today's lines of a component minus its lines at the parent of the window's first merge commit
  (`git grep -c` on that commit, mapped by today's cards). Hotspots count the merges that touched a file.
  Co-change compares the merges in which both components changed with those in which either changed.
  A reopened ticket is a ticket with more than one merge in the ledger, one of them in the window.
  Misplaced shared code is an edge into a component of the highest layer from a lower layer. Run time vs
  code: two cards of kind `service`, `job` or `store` where one reaches the other through the code edges.
  Every threshold is "more than", except co-change ("at least" a share, over a minimum count); misplaced,
  runtime, reopened tickets and budgets have none: each finding counts.
- The architect has no Write or Edit tool and writes nothing itself: card and Architecture doc updates are
  a docs ticket that goes through the loop like any other. It opens issues, so the role guard maps it to
  the tester, like the doc-auditor.
- **Reason:** the simplest deterministic signals that need only the ledger, the cards, the edge command
  and git; no GitHub call and no extra state besides one marker.
- **Alternatives:** per-file line counts in the ledger (a bigger ledger for one signal); the recorded
  `components` (stale after a card change); a window of calendar time (merges per day vary); the architect
  editing cards on its own branch (an agent that writes, against the read-only brief).

## 2026-11-05 — The NUL tool pick runs once per process tree; one rule for both bash fallbacks (#27)

- **Decision:** `scripts/lib/common.sh` picks the tool for NUL-separated names (jq, python3 or bash) when it
  loads, not on first use, so pipelines and command substitutions inherit the pick instead of probing jq
  again each time. It exports the pick (`DL_JSON_Z_TOOL`) with the inputs it depends on (`DL_JSON_Z_FOR`:
  `DEV_LOOP_NO_JQ`, `DEV_LOOP_JSON_Z` and `PATH`), so a child script that sources the library reuses it and
  picks again only when one of those differs. The bash fallbacks of `dl_json_list_z` and `dl_z_lines`
  both drop a name that holds a control character (one helper, `_dl_z_plain`), so the line form lists
  exactly the names the JSON form stores.
- **Reason:** the simplest cache that survives subshells, with no state file; the overrides keep working.
  One rule makes the components of a merge match its recorded files on a machine without jq or python3.
- **Alternatives:** callers picking before each pipeline (every new caller must remember); a cache file in
  the state directory (state to clean up and to invalidate); rewording the comment only (the probe still
  runs per call); keeping such names in the bash line form (then it lists names the ledger lacks). Cost:
  one jq run each time a script that sources the library starts in a fresh environment, also when it
  never reads NUL-separated names.

## 2026-11-05 — Config-check edges (#25): keys as JSON strings, strict single documents

- **Decision:** the config-change check lists top-level keys as JSON strings (`keys[] | @json`, and
  `json.dumps(key, ensure_ascii=False)` with DEL escaped as jq does in the python3 fallback), so `""` and
  keys with a newline are one line each and compared like any key. A message names a key bare when it is
  a plain name and as its JSON string otherwise (`""`, `"a\nb"`), rather than documenting such keys as
  unsupported. Both readers accept only exactly one JSON document: jq reads with `-s` and keeps a
  one-element input, python3 rejects extra data. When neither side parses, the raw texts are compared.
  python3 also treats `NaN` and `Infinity` as unparseable, while jq 1.7 and later reads them as null and a
  large number: the two paths differ there, but the raw comparison means python3 flags every change jq
  flags (stricter, never looser); a test pins that both flag such a change and neither flags no change. The first-config notice is printed by `gate-train.sh` per branch that adds the file,
  with the branch name in parentheses after the text the issue asked for.
- **Reason:** naming them correctly costs one encoding step in the existing pipeline, while "unsupported"
  would leave a silent hole in a check that guards the gate's own rules; slurping is the one jq mode whose
  verdict python3's `json.loads` can match.
- **Alternatives:** NUL-separated key lists (needs the shared NUL helpers another ticket is changing in
  `common.sh`); documenting newline keys as unsupported; `jq --seq` or `input` loops for strict parsing
  (more code, the same verdict).

## 2026-11-05 — Scenario store (#30): format, defaults and what doctor reports

- **Decision:** the store is on when `.dev-loop.json` has a `scenarios` key (`{}` uses the defaults), and
  it is not in `templates/dev-loop.json`, since its presence turns it on. `scenarios.dir` defaults to the
  state directory's `scenarios` folder (`~/.dev-loop/<repo>/scenarios`, so `DEV_LOOP_HOME` moves it too);
  a configured `dir` expands `~` and `<repo>` (the repository's folder name) and resolves a relative path
  against the main worktree. The store holds every `*.md` file at any depth except under `.git` (it may be
  a git repository). The front matter is a YAML subset read by awk: `key: value` lines at the start of a
  line, the first occurrence of a key wins, values in single or double quotes are taken up to the closing
  quote, ` # comments` after unquoted values are dropped, lists are `[a, b]`, CRLF line ends are accepted.
  `required` must be exactly `true` or `false`; a missing `required` is invalid too. A duplicate `id` is
  reported on each later file in path order. The required count counts every file with `required: true`,
  valid or not. `doctor.sh` reports invalid files and thresholds outside 0..1 as MISSING; a store that
  does not exist yet or lies inside the repository is a note, since nothing runs the scenarios yet.
- **Reason:** the smallest parser that reads the documented format without a YAML library (portable
  bash and awk); a missing `required` is more likely an oversight than a choice, and the judge needs to
  know which scenarios must pass.
- **Alternatives:** a YAML library through python3 (a dependency for five keys); `required` defaulting to
  `false` (a forgotten line would silently demote a scenario); a missing store as MISSING (it would make
  doctor red for a project that has just turned the key on; the dark preset of #2 makes it MISSING there).

## 2026-11-05 — Scenario isolation (#31): what the role guard refuses, and to whom

- **Decision:** the scenario check runs before the identity-mode checks whenever `.dev-loop.json` has a
  `scenarios` key (the shell wrapper's quick exit now looks for `"scenarios"` as well as `"identities"`),
  and the identity-mode checks are unchanged. The refused agent types are a fixed set, `implementer`,
  `test-engineer` and `code-reviewer` (plugin prefixes ignored); every other agent type and the main
  session are allowed, so `guard.agents` does not affect it. It covers Read, Grep and Glob (the `path`, and
  for Glob the pattern joined to it), Edit, Write, MultiEdit and NotebookEdit (`file_path`,
  `notebook_path`), and Bash: a literal spelling of the store (absolute, symlink-resolved, `~`, `$HOME`,
  `${HOME}`) anywhere in the command, then each word of each simple command, without a redirection prefix
  and after each `=`, with `~` and `$VARS` expanded, relative to the working directory as changed by `cd`,
  resolved through symlinks, and glob-expanded. A path that names a directory above the store is allowed.
  The Python resolution mirrors `dl_scenarios_dir` (including `<repo>`, a non-string `dir` as compact
  JSON, and the main worktree root from `git rev-parse --show-toplevel` when the common dir is not
  `.git`, which also changes where the guard looks for the config in that rare layout); a smoke test
  compares it with `paths.sh scenarios` for five configs from the main and a linked worktree.
  `guard-role.py --scenarios-dir [DIR]` prints the resolved path for that test. No deny rule in
  `templates/settings.json`.
  Any error while checking a call by one of the three agent types (a NUL byte in a path, an odd event)
  refuses it (fail closed), so a crash never lets it through or skips the identity checks after it. When
  the event's cwd is outside any git repository, the config and the store come from `CLAUDE_PROJECT_DIR`
  (the scenario check only; the identity checks read the config as before).
- **Reason:** the smallest change that meets #31: the agent type is the only thing that tells the judge
  from the implementer in one OS session, and deny rules cannot do that.
- **Alternatives:** a configurable list of refused agents (no need yet); refusing searches of directories
  above the store (would refuse ordinary `grep -r` of a home directory); shelling out to `paths.sh` from the
  hook (a bash start per tool call, and it reads the config again).

## 2026-11-05 — Scenario writer (#33): where its steps sit, what the issue shows, doctor's models line

- **Decision:** the orchestrator's scenario steps are a new section 1b of the `dev-loop` skill (next to
  ticket creation), not a step inside section 1. The writer runs once per ticket, after the issue exists
  and before the implementer starts, as a fresh agent. The issue comment lists each new or changed
  scenario as `id`, title, `required` and new or changed, never its body or file path, since the
  implementer reads the issue. The writer stops instead of writing when `paths.sh scenarios` points
  inside the repository. `doctor.sh` adds `scenario-writer` to its models line only when `scenarios` is on
  or `models.scenario-writer` is set (an unknown value is reported then, also without `scenarios`), so the
  output of a project without scenarios is unchanged.
- **Reason:** the store's acceptance criterion says a project without `scenarios` sees no change, and its
  smoke test checks that doctor prints no scenario lines then; titles are what the user needs to find a
  scenario in the store to review it, and nothing more should reach the coding agents.
- **Alternatives:** always listing `scenario-writer=inherit` (changes every project's doctor output);
  listing nothing in the issue (the user would not know what to review); showing the scenario text in the
  issue (leaks it to the implementer).

## 2026-11-05 — Scenario stage (#32): contracts of run and judge, rejudge, sealed and affected rules

- **Decision:** the stage is its own script, `scripts/scenario-stage.sh`, which `gate-train.sh` adds as
  the last stage `scenarios` whenever `scenarios` is configured (so `parallel`, `fail_fast`, the log file
  and the result line come for free); in sequential mode it is skipped when a check failed. `scenarios.run`
  is started in its own process group; its first non-empty output line is the address
  (`DL_SCENARIO_TARGET`), it may keep running or exit, it is stopped with a running judge (TERM to both process
  groups, KILL after 2 s, so it fits in the gate's default 10 s grace period; under a 3 s grace the gate
  may KILL the stage first and orphan the system's session, a limit we accept) when the stage ends, and ending or a silence of `scenarios.run_seconds` (120) before that line is red. The judge is a
  shell command run once per scenario with `DL_SCENARIO_FILE`, `DL_SCENARIO_ID`, `DL_SCENARIO_TARGET` in
  the environment; its verdict is its last stdout line starting with `{`, which must be a JSON object
  with the scenario's own `id` and `satisfied` from 0 to 1; anything else, a non-zero exit, or a run
  longer than `scenarios.judge_seconds` (600; its process group is stopped), scores 0.
  The front matter's `required` counts, not the judge's. A run below `pass` is rejudged once and the better
  run counts (for the decision and the mean). The mean is over every judged scenario. A scenario is sealed
  when `cksum(id) mod 1000 < sealed * 1000`. With `affected`, a scenario runs when it is required or a
  `spec` or `tags` item occurs (ignoring case) as a substring of a changed path. An invalid store is red
  without naming files; an empty or missing store is green without starting the system. The default
  judge is `claude -p "<prompt>" --agent dev-loop:scenario-judge [--model <models.scenario-judge>]
  --no-session-persistence --permission-mode dontAsk --allowedTools=Read,Grep,Glob,Bash
  --add-dir=<the scenario's folder>`: the prompt right after `-p` and `=` on the variadic options, which
  would otherwise take the prompt as one more value.
- **Reason:** the gate decides from plain numbers, so the agent can be replaced by any command and tested
  with a fake; a per-id hash keeps the sealed set stable as the store grows and across affected subsets;
  substring matching is the simplest rule that errs on judging more, not less; the stage log and the gate
  summary are the only text meant for implementers, so they carry only ids, scores and `missing` lines.
- **Alternatives:** inlining the stage in `gate-train.sh` (a larger script that other tickets edit); a
  readiness probe or a `scenarios.stop` command (more config for what process groups already do); taking
  the mean of the last runs (a flaky judge would lower the mean of a passing scenario); sealing the first
  share in hash order (the set would change with the store's size); matching whole path segments (a
  `spec: alerts` would miss `alert_rules.py`).

## 2026-11-05 — The factory preset (#34): one rule for "scenarios on", read in one place

- **Decision:** `dl_factory` (in `scripts/lib/common.sh`, next to `cfg`) returns `dark` or `collaborative`;
  any other value counts as collaborative and `doctor.sh` reports it. `dl_scenarios_setting` returns
  whether scenarios are on and the source: `explicit` when the config has a top-level `scenarios` key
  (`false`, `null`, `""` and the string `"false"` turn them off, anything else on), else `preset` (on) with `dark`, else
  `default` (off). A new `cfg_has KEY` tells a key set to `null` from a missing one, which `cfg` cannot.
  The dark store requirement is "at least one scenario file with `required: true` and no problems of its
  own" (`dl_scenarios_ready`); it applies whenever the factory is dark and scenarios are on, explicit or
  preset. The gate checks it in the scenario stage (one `scenarios red:` line, so it prints in the
  summary); `doctor.sh` prints the `factory` line only when `factory` is set, so the output without it
  stays as before.
- **Reason:** the issue says an explicit option always wins over the preset, and the review of #30 asked
  for `"scenarios": false` to mean off. One rule in one function keeps the gate, doctor and paths in
  step; the role guard hook applies the same rule in Python.
- **Alternatives:** a separate `scripts/lib/factory.sh` (one function did not need its own file);
  failing the gate before the checks in `gate-train.sh` (a second place that decides about scenarios);
  treating an unknown mode as an error everywhere (would stop the gate over a typo doctor already names).

## 2026-11-07 — Scenario stage (#40): the red count leaves out sealed scenarios; setsid daemons escape the stop

- **Decision:** the `<k> required unsatisfied` of the `scenarios red:` line counts only required scenarios
  that are not sealed; a sealed required failure counts in `scenarios sealed: <n> judged, <k> unsatisfied`
  only and still makes the stage red, so a train red only through a sealed scenario prints `0 required
  unsatisfied`. A daemon that `scenarios.run` starts in a session of its own (`setsid`, a double fork)
  leaves the process group the stage stops and keeps running; this is a documented limit (README,
  Stopping), not handled by the stage.
- **Reason:** counting a sealed required failure in `<k>` told the reader that a sealed scenario was
  required, a small leak beyond the sealed count. Finding escaped daemons would need a process scan
  (`ps`, `/proc`) that differs between Linux and macOS and could kill processes the stage did not start;
  `scenarios.run` knows its own daemons and can stop them.
- **Alternatives:** a separate sealed-required count on the sealed line (more detail about the sealed
  share than the issue allows); dropping `<k>` from the red line (loses what the implementer needs);
  a `scenarios.stop` command (more config for a case a `trap` in `scenarios.run` covers); a cgroup or
  systemd scope for the system (Linux only).

## 2026-11-07 — Planned-list hygiene in doctor (#45): what a row is, one gh call, 0 is off

- **Decision:** a planned row is a Markdown list item or a table body row (not the header, not inside a
  fenced code block, not a thematic break such as `* * *`); its ticket is the first `#n` that is not part of a word, a path, an HTML entity or
  an anchor such as `#2-scope`. In a file with a heading whose text starts with the word "Planned" (not
  "Unplanned things", not "Planned-list hygiene"), only that section's rows count, so a planned list kept at the end of the Features file (`templates/FEATURES.md`) does not judge
  the Features entries. The tickets come from one `gh issue list --state all --json
  number,state,stateReason,createdAt` call, made only when a row has a number. Only `NOT_PLANNED` reads
  as "not planned"; every other closed reason reads as completed. A number GitHub does not list as an issue
  gets a `no such ticket` note. `docs.planned_max_days` of `0` or empty is off (the template ships `0`), any
  other non-number is MISSING. Days are counted from the ticket's creation date to today in UTC with an awk
  civil-day formula (no `date -d`).
- **Reason:** one call costs the same for any number of rows; the Features template keeps its planned list
  in the same file; `0` lets the template list the key without turning the check on.
- **Alternatives:** one `gh issue view` per row (N calls); treating `DUPLICATE` as not planned (the issue
  names only "not planned"); counting from the ticket's last update (an edit would hide an idle ticket).

## 2026-11-07 — docs-archive.sh (#44): dates, archive names, links and the verification

- **Decision:** an entry is a line starting `## ` outside a CommonMark code fence (at most 3 spaces of
  indent, 3 or more of one character, closed only by the same character at least as long; the link rule of
  `docs-check.sh` uses the same fences, shared in `scripts/lib/docs.sh`). A journal must be newest last:
  one whose first dated entry is newer than its last is refused, and the newest entry never moves.
  its date is the `YYYY-MM-DD` right after `## `, and the archive is named from the first and last moved
  entries that have one (`undated` when none has). Only the contiguous run of entries before the
  `## Standing decisions` section (or after it, when it comes first) moves, oldest first, until the live
  file is within budget; a run that cannot reach the budget moves whole and the script says so. A taken
  archive name gets `-2`, `-3`, ...; an archive file is created with noclobber and never edited. The
  archive holds the moved bytes only (no header), so the check is exact: the live file with the archive
  put back after the kept prefix equals the original (`cmp`), with the expected line counts; the archive is
  written first, then the live file, so a failure in between loses nothing. Moved text with a relative
  link that would not resolve from the archive folder is refused with the link named, never rewritten.
  Paths are from the top of the current worktree (the branch that commits the move); the archive folder
  is fixed at `docs/archive/`. Without `docs` the script is a config error (exit 2), like `docs-check.sh`.
  The dangerous direction is tested through `DEV_LOOP_ARCHIVE_TEST_CORRUPT`, a test-only hook that changes
  the temporary archive copy before the check; it fails safe (set by mistake, the run only refuses and
  writes nothing). Config paths are normalized (`./docs/f.md` is `docs/f.md`) before `spec` compares
  them, and a failed `spec` removes only the folders that run created. The link helpers of `docs-check.sh` moved to `scripts/lib/docs.sh` so both
  scripts use one link rule. `doctor.sh` counts a last line without a newline as a line for journals.
- **Reason:** byte-exact moves and a byte-exact check are the simplest way to prove nothing is lost; a
  rewrite of links would change the moved bytes and make the check approximate. A contiguous run keeps the
  check a single insertion point.
- **Alternatives:** rewriting relative links (verbatim no more, the check would need a model of the
  rewrite); a header in each archive file (the check would have to strip it); a `docs.archive` key for the
  folder (no need yet); moving entries from both sides of a standing section placed in the middle (two
  insertion points to verify).

## 2026-11-07 — Docs maintenance (#47): a subsection of the doc audit, closing stale tickets before it starts

- **Decision:** "Docs maintenance" is a `###` subsection at the end of the `dev-loop` skill's section 7a
  (the doc audit), not a new numbered section, so the references to sections 7b and 7c (the doctor skill's
  note table among them) stay true. The orchestrator closes stale planned tickets itself before the
  maintenance ticket starts (on the user's OK in collaborative mode, without asking in dark mode); the
  implementer only removes their rows, so closing issues stays an orchestrator action. An oversized doc
  is one over `docs.max_lines`, the budget `doctor.sh` already notes.
- **Reason:** one cadence and one place to read; implementers never change other tickets' state.
- **Alternatives:** renumbering 7b and 7c (breaks cross-references in files another ticket edits); a new
  `docs.maintenance_every` key (no need: the audit's cadence is what the ticket asks for); letting the
  implementer close stale tickets (an issue write outside its own ticket).

## 2026-11-07 — Docs adoption (#46): the docs-off note and the gradual path

- **Decision:** without `docs` (no aspects), `doctor.sh` prints one note in place of the docs lines:
  `current-state docs off: no docs check, no doc audit, no planned list; adopt them with the setup skill's
  step 3b`. It is a note, so `doctor: ready` and the problem count are unchanged. The gradual adoption
  path is a new item 6 of setup step 3b, next to the one-time rebuild (item 5), not a replacement of it:
  a small project can still rebuild at once. The planned-row parser (`dl_docs_planned_rows`) uses the
  shared CommonMark fence helper `DL_DOCS_FENCE_AWK`, so the planned list, the link rule and the journal
  compaction read fences the same way. Existing smoke tests that counted `docs ` or `doc audit` lines in a
  docs-off doctor run now drop the note line first; what they assert (no docs lines without docs) holds.
- **Reason:** a project without docs had no hint that the feature exists; a note costs nothing and never
  blocks the loop. Large hand-written docs cannot be rebuilt in one session, so each adoption step must
  leave the gate green on its own. One fence rule avoids rows counted from inside a `~~~` block that
  holds a backtick fence line.
- **Alternatives:** a MISSING line (would block every project that chose to stay without docs); printing
  the note only when a `docs` folder exists (a guess about the project); replacing the one-time rebuild
  with the gradual path (more steps than a small project needs).

## 2026-11-07 — Permissions (#54): the permission rule syntax, and where the plugin-script rules live

- **Decision:** the loop's rules use the Claude Code permission rule syntax as documented at
  code.claude.com/docs/en/permissions, permission-modes and settings (read on 2026-11-07, Claude Code
  2.1.x): `Bash(<command>)`, where `*` may stand anywhere and matches any text, spaces and slashes
  included; a trailing `:*` equals a trailing ` *`; a trailing ` *` that is the only wildcard also matches
  the bare command and keeps a word boundary (`Bash(ls *)` matches `ls` and `ls -la`, not `lsof`). A
  compound command (`&&`, `||`, `;`, `|`, `&`) is checked per part: every part needs an allow, a deny or
  ask on any part applies, so `permissions.sh` writes one exact rule per part of `fast_check` and of each
  check. Rules are checked deny, then ask, then allow, across all settings files merged; a deny anywhere
  wins. Deny rules block and ask rules ask in every mode, `bypassPermissions` included; allow rules have no
  effect in bypass mode. `${CLAUDE_PLUGIN_ROOT}` is not expanded in permission rules (the docs list where it
  is substituted, and permission rules are not among them; it is not exported to Bash tool commands), and
  `~` is documented only for Read and Edit rules. So `permissions.sh` resolves the plugin's path when it
  runs and writes the script rules with the version directory as a wildcard
  (`<cache>/<marketplace>/dev-loop/*/scripts/<script>.sh` and the same with ` *`), outside the plugin cache
  the plain path. Those rules hold a machine path, so they go to `.claude/settings.local.json`, which the
  script adds to `.gitignore`; everything else goes to the shared `.claude/settings.json`. `doctor.sh`
  matches rules with the same semantics (`scripts/lib/permissions.sh`).
- **Reason:** a literal `${CLAUDE_PLUGIN_ROOT}` rule would match nothing; a path with the version in it
  goes stale on every plugin update; a rule with a leading `*` (`Bash(*/scripts/gate-train.sh *)`) would
  also allow any command that merely names the script (`rm ... /x/scripts/gate-train.sh`). A machine path
  in a committed file would leak the user's home directory into a public repository.
- **Wildcards cannot exclude arguments:** `Bash(git push -u origin feat/*)` would also match
  `git push -u origin feat/x:refs/heads/main`, `... --force` or `... :feat/b` (a delete). So the only push
  allowed is the exact `git push -u <remote> HEAD`, and the implementer brief and the `dev-loop` skill push
  in that form (an exact rule carries no extra argument; `repush.sh` and `merge-train.sh` push inside
  scripts, where rules do not apply). As a second line, the template denies force pushes and asks for
  tag, `refs/`, mirror, all, delete and base-branch pushes with patterns that match anywhere and between
  `git` and `push` (`Bash(*git*push*--force*)` also catches `git -c a=b push --force` and
  `git -C . push -f`). A colon refspec cannot be matched in general: a rule ending in `:*` is read as a
  trailing ` *`, so `Bash(*git*push*:*)` would ask for every push; the script names the colon forms it
  needs instead (`:<base>`, `:<base> *`, `:<branch pattern>`, and `refs/`). `heavy.sh` and `as-role.sh`
  run any command they are given, so they get exact rules for the loop's uses only (`heavy.sh <project
  command>`, `as-role.sh implementer git push -u <remote> HEAD`); other uses ask in the default mode. A deny
  on `*git*push*--force*` or `*gh pr merge*--admin*` also refuses a command that merely contains those
  strings (a commit message or PR body quoting one); the agent writes the message without the literal flag
  or passes it in a file (`git commit -F`, `gh pr create --body-file`). Options that make git run a
  command of its own ask, matched anywhere: `git rebase --exec`/`-x`, `git fetch`/`git pull`
  `--upload-pack`, and `git -c <key>=<value>` before `fetch` or `pull`. The project's commands become
  exact allow rules as written, so a `*` in one is a wildcard in its rule and a trailing `:*` a prefix; the
  project's commands are trusted, and the README says so. `git diff`, `git log` and
  `git show` with `--output=<file>`, and `git fetch +<ref>:<ref>`, stay allowed: they write only inside the
  repository. The `Read`/`Edit` deny rules on `.env` do not stop `cat .env` through Bash; a Bash ask rule
  on `*.env*` would also ask for `.env.example` and every path with `.env` in it, so the README states the
  limit and `CLAUDE.md`'s rule stays the guard. Releases, tags and tag pushes ask in every mode; other
  commands outside the repository are in no allow rule, so they ask in the default mode, the classifier
  judges them in auto mode, and in bypass mode only the stop conditions hold them back (the issue's "still
  ask in every mode" holds for what the rules can name).
- **Other choices:** the merge is a script (`permissions.sh`, dry run by default) instead of a jq line in
  the setup skill, so it is tested and doctor shares its rule list. It appends missing rules after the
  existing ones in each list and never removes or reorders one; an invalid settings file is left untouched
  (exit 2). The allow list adds `git add`, `git commit`, `gh issue close`, `gh pr diff` and `gh pr checks`
  to the issue's list (the loop runs them) and leaves out `git branch`, `git checkout` and `gh pr merge`
  (they delete or discard; merges happen inside `merge-train.sh`). `cleanup.sh` is allowed, `cleanup.sh
  --apply` asks. `scenario-stage.sh` is not listed: the gate runs it, not the Bash tool. Doctor's checks
  are exact-string: a broader rule the user wrote does not count as covering a loop rule (a note, never a
  problem). Doctor tests each deny rule against a fixed set of sample loop commands plus the project's
  commands.
- **Alternatives:** a PreToolUse hook that approves the plugin's scripts (hook commands do expand
  `${CLAUDE_PLUGIN_ROOT}`): more moving parts, and a hook's allow is still overridden by deny rules, so the
  doctor check would be the same; rules on `bash <script>` (would change every command the skills print);
  `Bash(*/scripts/*.sh *)` (allows any command that names such a path).

## 2026-11-07 — Never force-push: a rebased branch is re-pushed as `<branch>-vN` (#53)

- **Decision:** `scripts/repush.sh [<branch>]` (default: the checked-out branch) publishes a rebased
  branch as `<root>-vN`, where `<root>` is the name without a trailing `-v<digits>` and N is the first
  number above the branch's own version (1 for an unsuffixed name) that is free on the remote, locally and
  as a notes file, so nothing of an earlier attempt is overwritten. It switches the worktree that has the
  branch checked out to the new name (the implementer keeps working there), refuses a worktree with any
  `git status --porcelain` output (untracked files too) and the base or a long-lived branch, and undoes
  only what it created when the push fails (exit 3). The notes file is copied with a trailing line
  ``Supersedes `<old>` at <local tip> [<remote tip>] ...`` (the old branch's tips at the re-push); a missing notes file is a warning, not a refusal, since the push is what
  must not be lost. `open-pr.sh` closes the open PRs of `<root>`, `<root>-v2`, ... below N, as the
  implementer (it opened them), with a comment naming the new PR, but only those the new branch
  supersedes: its notes name them on a `Supersedes` line (repush.sh writes one per re-push, and the copy
  keeps the earlier ones), or their PR head is an ancestor of its head. Without the new PR's number it
  closes nothing. A failure there is a warning. A failed notes copy in repush.sh is a visible warning,
  not a failure: the push already happened.
  `cleanup.sh` classifies a loop branch `superseded` when a later version of the same root is in the
  ledger or has a merged PR and the notes of a merged later version (live, or archived in
  `notes/merged/`) record this branch at exactly its current tip, each ref (local, remote) checked on
  its own; ancestry cannot be used after a rebase. Without a record (a same-name branch of other work)
  or at another tip (commits after the re-push) the branch is kept with that reason, unless the base
  contains it, when the older rules decide as before; the check runs after the open-PR and merged checks (an open PR keeps the
  branch) and before the closed-PR check, so a branch whose PR `open-pr.sh` closed is deleted without
  `--include closed`. It is deleted with `--apply` like `merged`, with the same bundle archive first, and
  its notes file moves to `notes/merged/` once the branch is gone. A slug that itself ends in `-v<n>`
  (`feat/12-api-v2`) is read as version n of `feat/12-api`; both names carry the same ticket number, so
  the only effect on cleanup is on branches of that same ticket, and `open-pr.sh` leaves the PR of an
  unrelated `feat/12-api` open.
- **Reason:** deny rules, Claude Code's auto mode and GitHub rulesets refuse force pushes, and the old
  branch is evidence until the new one merges. Deriving the predecessors from the name needs no extra
  state; the `Supersedes` line documents it in the PR body.
- **Alternatives:** reading the predecessor from the `Supersedes` line only (breaks when the notes file
  is missing or edited); deleting the old branch right after the re-push (loses it if the new one never
  merges); `-rN` or date suffixes (`-vN` is what was already used by hand). `merge-train.sh`'s own replay
  push kept its `--force-with-lease` on the gated head at the time (superseded by #57: the merge now
  pushes a fast-forward merge commit, never forced).

## 2026-11-07 — Status and the event log (#55)

- **Decision:** every event value is a JSON string (`rc`, `pid` and `ticket` too), so the line format is
  one rule and `event.sh` needs no types. The log rotates at a fixed 1 MiB (`DEV_LOOP_EVENTS_MAX_BYTES`
  for tests, no config key) with one old file, by a `mv` before the append; two writers rotating at once
  can at worst drop the older `.1`. Heavy slot holders come from the `slot-acquired` events without a
  `slot-released` of every repository's event log under `~/.dev-loop` (the slots are machine-wide) and a
  live pid (`ps -p`): probing the flock would take the lock, and `heavy.sh` outside a repository writes
  no events, so such a job is not listed. "Seconds since the log last grew" is the log's modification
  age (python3, else perl), not a sample over time, so `status.sh` returns at once. The gate's running
  stages are those its last `train-started` (same pid) started and did not end; a gate without events (an
  older version) shows its newest stage log. The verdict counts as evidence this repository's events,
  the running stage logs, `train-running.txt` and the commits and notes files of loop worktrees whose
  branch is not in the ledger; it is `idle` when nothing runs or waits, no unmerged loop worktree exists
  and the orchestrator's last event is older than the threshold. While the gate runs, only gate-side
  evidence counts (stage logs, `train-running.txt`, this repository's gate events; the gate's own heavy
  jobs show in their stage logs), so an implementer's commits or heavy jobs never hide a frozen stage; other repositories' heavy events never count as this
  repository's activity. A gate job queued in `heavy.sh` behind a busy machine writes nothing while it
  waits, so it is linked to the gate deterministically: `gate-train.sh` exports its pid as `DL_GATE_PID`
  to its stages, `heavy.sh` records it as `gate_pid` in its `queued` and `slot-acquired` events, and a
  live queued job whose `gate_pid` equals the running gate's pid gives `waiting on heavy slot (queued)`,
  never a stall; a queued job without it (an implementer's) or with another pid counts for nothing.
  Walking `ps` parent chains from the heavy job to the gate was rejected: it differs between Linux and
  macOS and breaks when a process in between exits or re-parents. A stage silent for longer than
  `watchdog.stall_minutes` still reads as possibly stalled; a slow silent suite needs a higher value,
  and a watchdog confirms before acting. A dead gate pid in `train-running.txt` (a killed gate) is said in the idle
  verdict and flagged in `--json` (`verdict.gate_died`, `gate.stale`). The orchestrator's `waiting` events name
  what it waits on (`detail`, else the rest of the event name). `status.sh` does not fetch (a fetch
  writes refs), so pushed and ahead/behind use the local remote-tracking refs.
- **Reason:** the smallest contracts that let a later watchdog (#56) read the verdict and the event log,
  with no write, signal or lock from the reader and no slowdown or failure for the writers.
- **Alternatives:** typed values (numbers for `rc`, `pid`; one more rule per key); a holder file per slot
  written by `heavy.sh` (more state in the lock directory, a larger change to `heavy.sh`); sampling the
  log size over 20 s (slow, and the modification time says the same); `stat` (its options differ between
  Linux and macOS).

## 2026-11-07 — Merge without a force push: a fast-forward merge commit with the gated tree (#57)

- **Decision:** `merge-train.sh` still replays each branch onto the current base and checks the replayed
  tree against the gated one (exits 3 and 4 unchanged). When the branch already contains the base and has
  the gated tree, it merges as it is, with no push. Otherwise it creates a merge commit whose tree is the
  gated tree and whose parents are the gated head and the base (`git commit-tree`), and pushes it to the
  same branch with a plain push: a fast-forward, which the remote refuses when the branch moved (exit 6,
  as before). The squash merge of a head that contains the base is that head's tree, so the merged tree is
  the gated tree. The train file gets a fifth field, the gated head, once the branch moved, so a re-run
  (after exit 9 or 7) finds the pushed head up to date and merges it without another push, and the
  ledger's `source_head` and the local-branch deletion keep using the gated head. A sixth field records
  the merge commit before its push; a re-run adopts the remote branch's head as the pushed one only when it
  equals that recorded commit (otherwise the branch changed since the gate: exit 6).
- **Reason:** the smallest change that never force-pushes: the PR, its number, its review thread and the
  notes stay; no new branch names, no superseded PR to close, nothing extra for `cleanup.sh`. The ledger
  accepts both the gated head and the pushed one, so the original branch is classified `merged`. In
  identity mode the status is posted on the pushed head and the approval is needed on it, as with the
  former force push (the ruleset dismisses stale approvals either way). The squash itself is still a
  3-way merge against the base at merge time: if the base moves between the push and the merge, the
  result can differ from the gated tree, the same exposure as before (`--match-head-commit` pins the
  head, the ruleset's strict status check requires the head to be up to date with the base).
- **Alternatives:** push the replay as `<branch>-vN` and open a new PR from the carried notes (a new PR
  per merge of a branch behind the base, a closed PR per merge, a Supersedes record and a cleanup pass for
  every one); push the squash commit to the base directly (needs a ruleset bypass; not by default); merge
  the PR as is and accept a 3-way merge result (the merged tree would no longer be guaranteed to equal the
  gated one).

## 2026-11-07 — Stall watchdog: the gate's stall timeout and the heartbeat (#56)

- **Decision:** `stall_minutes` is per stage (a check entry, `affected`, `scenarios`), a positive whole
  number of minutes; anything else is off with a warning, so a typo never stops a healthy check. A stage
  with it always runs in its own process group (also in sequential mode, through the parallel runner for
  that one stage), since only a group can be stopped with everything it started; stages without it run as
  before. "Has not grown" is the log's byte count, sampled every half second by the gate's own poll loop
  (no background process). A heavy stage counts as started only once its log has `heavy.sh`'s `slot ...
  acquired` line, so time queued for a slot never counts. A stall counts as a failure for `fail_fast`.
  The unit is overridable with `DEV_LOOP_STALL_UNIT_SECONDS` (environment only, for tests), like
  `DEV_LOOP_STOP_GRACE_SECONDS`. The heartbeat is skill text, not a script: the orchestrator schedules a
  fallback wake-up with whatever scheduling tool the session has (else a background command that waits
  and exits), reads `status.sh --json`, and confirms a stall (CPU time of the stage's processes growing,
  worktree changes) before acting; it may stop only the gate's own stage processes and the heavy jobs its
  gate started. `"watchdog": false` turns the heartbeat off; `status.sh` keeps its default threshold.
- **Reason:** the stall timeout bounds silence, not run time, so long healthy suites that print are never
  killed, and it reuses the `fail_fast` stop path. A scheduling tool differs between sessions, so the
  skill names the behaviour, not one tool; confirming before acting keeps a slow silent suite from being
  killed on `status.sh`'s "possibly".
- **Alternatives:** a total timeout per check (kills slow but healthy suites); a separate watchdog daemon
  (a process outside the session that would need its own lifecycle and permissions); the log's
  modification time instead of its size (the same signal, but needs python3 or perl per poll); acting on
  `possibly stalled` without confirming.

## 2026-11-07 — doctor checks the marketplace pin without the network (#64)

- **Decision:** `doctor.sh` reads the `extraKnownMarketplaces.<marketplace>.source` entries of the user
  settings (`$DEV_LOOP_CLAUDE_DIR/settings.json`, default `CLAUDE_CONFIG_DIR`, else `~/.claude`), the managed
  settings (`/etc/claude-code/managed-settings.json` on Linux, `/Library/Application
  Support/ClaudeCode/managed-settings.json` on macOS, or `DEV_LOOP_MANAGED_SETTINGS`) and the project's
  `.claude/settings.json` and `settings.local.json`, and compares each with the marketplace in
  `plugins/known_marketplaces.json` (source kind, repo or url or path, and ref, all exact). A mismatch is
  MISSING (the state in which `marketplace add` fails); an entry with no configured marketplace is a note
  with the add command, since Claude Code may still add it itself when the folder is trusted. The installed
  version is the highest in `plugins/installed_plugins.json` at user scope or for this project; a pin older
  than it is a note, once per ref. The add argument is `owner/repo@ref` for GitHub (the form that worked
  in the reported case) and `url#ref` for a git URL. The latest release is not looked up: doctor makes no
  network call.
- **Reason:** the error comes from a mismatch between the settings entry and the configured marketplace,
  which both files show without the network; a `gh release view` can hang offline and has no portable
  timeout (no GNU `timeout` on macOS), and the installed version already shows a pin that was not moved.
- **Alternatives:** `gh release view` for the latest tag (slow or failing offline); MISSING for an entry
  not added yet (a fresh machine with copied settings is not broken); comparing the repo case-insensitively
  (Claude Code compares the entry as written).
- **Decision (release step):** the README's install tag names the current release, and the smoke tests
  hold it equal to the version in `.claude-plugin/plugin.json`, so a release bumps the README's tag with
  the version in the release commit. This is a step of this repository's release only: the `dev-loop`
  skill's "Before a release" is generic for every project, so it does not name this README. Values doctor prints from the settings are
  stripped of tabs and newlines, and unreadable files are skipped without an error.

## 2026-11-08 — The status verdict follows what is moving (#67)

- **Decision:** a `waiting` event (the orchestrator's last event) names the branches in its `branch` key
  and the words of its `detail` that contain a `/`, with quotes, brackets and trailing punctuation
  stripped; a word with `://` (a URL) or whose last segment ends in `.<letters>` (a file name such as
  `docs/DECISIONS.md`) is not a branch, so when unsure the wait holds. The ledger also ends an agent in
  flight when it records the agent's ticket or branch merged at or after its start (an `agent-reported`
  never recorded must not read as stalled once the work merged). With the gate not running, it is over once, after it,
  a `train-ended` of a train (its `train-started` branches) with one of them, or a `merged` event of one,
  is in the event log, or a ledger entry of one has a `merged_at` at or after the wait's time. A wait that
  names no branch (`agents for #11 #12`, `waiting-review`) holds until the orchestrator's next event, which
  replaces it as the last event anyway. An agent is in flight from `agent-started` (or `watchdog-resumed`)
  with a ticket (else a branch) until `agent-reported` of the same ticket or branch, a `merged` event of it,
  or an `idle` event, which ends them all. `idle` also leaves out of the verdict the loop worktrees whose
  last commit and notes are older than it. The verdict is `idle` when nothing runs, no wait holds, no loop
  worktree counts and no agent is in flight, whatever the age of the last event; otherwise the stall
  threshold and the old order apply, so `stalled` is unchanged (an agent that never reports and a worktree
  that stopped moving become possibly stalled after `watchdog.stall_minutes`). `--json` adds
  `verdict.wait_ended` and `verdict.agents`.
- **Reason:** every piece of evidence is already read by `status.sh` (gate events, merge events, the
  ledger), so the verdict needs no new writer; position in the log orders events without clock
  comparisons, and the ledger covers merges whose event was not written. Branches are the names a gate and
  a merge record, so they are the reliable link; ticket numbers in a wait's text are left to the next event.
- **Alternatives:** ending a wait after a fixed age (hides a real long gate); matching tickets named in a
  wait's detail against reports (a partial report would end a wait on several agents); a separate
  "nothing in flight" flag file (a second writer and state to clean up).

## 2026-11-08 — The stop gate's session start (#74)

- **Decision:** the session's start is the first `"timestamp"` (UTC, ISO 8601) in the transcript named by
  the Stop hook input's `transcript_path`; when there is none, it is the hook's first run in the session.
  The hook keeps it as the mtime of a marker file per `session_id` in `<git dir>/dev-loop-sessions/`
  (set with `TZ=UTC touch -t`), and an untracked file (`git ls-files -z --others --exclude-standard`)
  blocks unless `find <marker> -newer ./<file>` lists the marker (the marker strictly newer than the
  file), so a file whose mtime equals the start second blocks; a session start known only from the
  first run protects files made after the first stop, and a file made with an old mtime (`cp -p`, `mv`,
  an archive) counts as older. Markers older than 30 days are removed when a new one
  is made. The note on older files is a `systemMessage` (exit 0), once per session (a `<marker>.noted`
  file). A hook input without a session id keeps the old rule: every untracked file blocks.
- **Reason:** the Stop hook first runs at the end of the session's first turn, so a marker made then
  would let files of that turn pass; the transcript's first event is the real start. `touch -t` and
  `find -newer` behave the same on Linux and macOS, unlike `stat` or `date -d`. The git directory is
  per worktree and already holds the hook's block counter, so the hook needs no change in the shared
  library's state paths.
- **Alternatives:** the transcript file's creation time (not portable; its mtime changes on every
  message); a marker under the loop's state dir `~/.dev-loop/<repo>/` (the hook does not load the loop
  config, and the git directory scopes the marker to the worktree); blocking once to show the note to
  Claude (the issue says older files must not block).

## 2026-11-08 — Script help: the first argument, and branch scripts refuse every leading dash (#75)

- **Decision:** `dl_help` in `scripts/lib/common.sh` handles `-h` / `--help` only as a script's first
  argument, for every script; `dl_branch_args` checks every argument of the scripts whose arguments are
  all branches (`gate-train.sh`, `merge-train.sh`, `repush.sh`, `open-pr.sh`): help anywhere prints the
  usage and exits 0, any other leading `-` is exit 2 with the usage. The usage is the script's own
  `# Usage:` header block (up to the next blank comment line), so it has one source; `doctor.sh` got one.
  Scripts with their own option parsers keep rejecting unknown options as before, so `cleanup.sh --apply
  --help` is a usage error (exit 2), not help.
- **Reason:** `heavy.sh` and `as-role.sh` pass the rest of their arguments to a command, and `event.sh`
  takes `key=value` pairs, so only the first argument can mean help everywhere; a git branch name can
  never start with `-`, so a leading dash in a branch script is always a mistake. One line per script
  keeps the change small next to other branches editing the same scripts.
- **Alternatives:** a `-h|--help)` case in each parser (many edits, and nothing for scripts without a
  parser); a separate usage text per script (a second copy that drifts from the header).
