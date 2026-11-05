# shellcheck shell=bash
# Shared helpers for the dev-loop scripts: repository paths and the project config (.dev-loop.json).
# JSON is read with jq when it is installed, else with python3 (DEV_LOOP_NO_JQ=1 forces python3).

dl_die() {
  echo "dev-loop: $*" >&2
  exit 2
}

dl_have_jq() {
  [ -z "${DEV_LOOP_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1
}

dl_warn() {
  echo "dev-loop: $*" >&2
}

# json_get PATH < json  -> the value at a dotted path ("heavy.slots", "checks.0.name").
# Strings print raw, other values as JSON, missing or null values print nothing.
json_get() {
  local path=$1
  if dl_have_jq; then
    jq -r --arg p "$path" '
      ($p | if . == "" then [] else split(".") | map(tonumber? // .) end) as $k
      | (try getpath($k) catch null)
      | if . == null then empty elif type == "string" then . else tojson end' 2>/dev/null
  else
    python3 -I -c '
import json, sys
path = [p for p in sys.argv[1].split(".") if p]
try:
    value = json.load(sys.stdin)
    for key in path:
        if isinstance(value, list):
            value = value[int(key)]
        elif isinstance(value, dict):
            value = value[key]
        else:
            raise KeyError(key)
except (KeyError, IndexError, ValueError, TypeError):
    sys.exit(0)
if value is None:
    sys.exit(0)
print(value if isinstance(value, str) else json.dumps(value))
' "$path" 2>/dev/null
  fi
}

# json_len PATH < json  -> the length of the array at PATH (0 when missing or not an array).
json_len() {
  local value
  value=$(json_get "$1")
  if [ -z "$value" ]; then
    echo 0
  elif dl_have_jq; then
    printf '%s' "$value" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || echo 0
  else
    printf '%s' "$value" | python3 -I -c '
import json, sys
value = json.load(sys.stdin)
print(len(value) if isinstance(value, list) else 0)' 2>/dev/null || echo 0
  fi
}

# dl_main_root: the root of the main worktree (where .dev-loop.json lives), from any worktree.
dl_main_root() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  if [ "$(basename "$common")" = ".git" ]; then
    dirname "$common"
  else
    git rev-parse --show-toplevel 2>/dev/null
  fi
}

# dl_load_config [required]: sets DL_ROOT, DL_CONFIG, DL_REPO, DL_STATE and the common settings.
# With "required", a missing repository or config file is an error; otherwise defaults apply.
dl_load_config() {
  local required=${1:-}
  DL_ROOT=$(dl_main_root) || DL_ROOT=""
  if [ -z "$DL_ROOT" ] && [ "$required" = required ]; then
    dl_die "not inside a git repository"
  fi
  DL_CONFIG=${DEV_LOOP_CONFIG:-${DL_ROOT:+$DL_ROOT/.dev-loop.json}}
  if [ "$required" = required ] && [ ! -f "$DL_CONFIG" ]; then
    dl_die "no config at ${DL_CONFIG:-.dev-loop.json}; run the dev-loop setup skill or copy templates/dev-loop.json"
  fi
  DL_REPO=$(basename "${DL_ROOT:-$PWD}")
  DL_STATE=${DEV_LOOP_HOME:-$HOME/.dev-loop}/$DL_REPO
  DL_REMOTE=$(cfg remote origin)
  DL_BASE=$(cfg base_branch main)
}

# dl_load_train_config [--recorded] BRANCH: dl_load_config required, except that when the main checkout has
# no .dev-loop.json yet and DEV_LOOP_CONFIG is unset (a setup branch on its first merge), the config is read
# from the branch (with --recorded, the first branch of the recorded green train first), copied to
# $DL_STATE/branch-config.json and exported as DEV_LOOP_CONFIG for the scripts this one runs.
dl_load_train_config() {
  local recorded="" branch ref="" remote copy
  [ "${1:-}" = --recorded ] && { recorded=yes; shift; }
  dl_load_config
  if [ -z "${DEV_LOOP_CONFIG:-}" ] && [ -n "$DL_ROOT" ] && [ ! -f "$DL_CONFIG" ]; then
    for branch in ${recorded:+"$(awk 'NR == 1 {print $1}' "$(dl_train_file)" 2>/dev/null)"} "${1:-}"; do
      [ -n "$branch" ] && ref=$(dl_branch_config_ref "$branch" origin) && break
    done
    if [ -n "$ref" ]; then
      remote=$(git -C "$DL_ROOT" show "$ref:.dev-loop.json" | json_get remote)
      if [ -n "$remote" ] && [ "$remote" != origin ]; then
        ref=$(dl_branch_config_ref "$branch" "$remote" remote-only) ||
          dl_die "the config of $(dl_ref_name "$ref") names remote $remote, but $remote/$branch is missing (push the branch to $remote)"
      fi
      copy=$DL_STATE/branch-config.json
      { mkdir -p "$DL_STATE" && git -C "$DL_ROOT" show "$ref:.dev-loop.json" >"$copy"; } || dl_die "cannot write $copy"
      export DEV_LOOP_CONFIG=$copy
      echo "dev-loop: config read from $(dl_ref_name "$ref"):.dev-loop.json ($DL_ROOT has none yet)"
    fi
  fi
  dl_load_config required
}

# dl_branch_config_ref BRANCH REMOTE [remote-only]: fetches BRANCH from REMOTE (a failed fetch only warns:
# gate-train.sh and merge-train.sh fetch again right after, and stop if that fails), then prints the full ref
# of REMOTE/BRANCH, else (unless remote-only) of the local BRANCH, the first that has a .dev-loop.json.
dl_branch_config_ref() {
  local ref refs="refs/remotes/$2/$1"
  [ "${3:-}" = remote-only ] || refs="$refs refs/heads/$1"
  git -C "$DL_ROOT" fetch -q "$2" "+refs/heads/$1:refs/remotes/$2/$1" >/dev/null 2>&1 ||
    dl_warn "could not fetch $2/$1; reading the config from the last fetched ref or the local branch"
  for ref in $refs; do
    if git -C "$DL_ROOT" cat-file -e "$ref:.dev-loop.json" 2>/dev/null; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

# dl_ref_name REF: a remote-tracking ref as <remote>/<branch>, any other ref in full (refs/heads/<branch>).
dl_ref_name() {
  case "$1" in
    refs/remotes/*) printf '%s\n' "${1#refs/remotes/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# cfg PATH [DEFAULT]: a value from the project config, or DEFAULT.
cfg() {
  local value=""
  if [ -n "${DL_CONFIG:-}" ] && [ -f "$DL_CONFIG" ]; then
    value=$(json_get "$1" <"$DL_CONFIG")
  fi
  if [ -n "$value" ]; then printf '%s\n' "$value"; else printf '%s\n' "${2:-}"; fi
}

# cfg_len PATH: the length of an array in the project config.
cfg_len() {
  if [ -n "${DL_CONFIG:-}" ] && [ -f "$DL_CONFIG" ]; then json_len "$1" <"$DL_CONFIG"; else echo 0; fi
}

# dl_resolve PATH: an absolute path; relative paths resolve against the main worktree root.
dl_resolve() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    "~"/*) printf '%s\n' "$HOME/${1#"~/"}" ;;
    *) printf '%s\n' "${DL_ROOT:-$PWD}/$1" ;;
  esac
}

dl_notes_dir() {
  local configured
  configured=$(cfg notes_dir "")
  if [ -n "$configured" ]; then dl_resolve "$configured"; else printf '%s\n' "$DL_STATE/notes"; fi
}

dl_logs_dir() {
  local configured
  configured=$(cfg logs_dir "")
  if [ -n "$configured" ]; then dl_resolve "$configured"; else printf '%s\n' "$DL_STATE/logs"; fi
}

dl_gate_dir() {
  dl_resolve "$(cfg gate_worktree "../$DL_REPO-gate")"
}

# dl_note_file BRANCH: the PR notes file of a branch (slashes become underscores).
dl_note_file() {
  printf '%s/pr-%s.md\n' "$(dl_notes_dir)" "${1//\//_}"
}

# dl_train_file: where gate-train.sh records the last green train (branch, source head, gated head).
dl_train_file() {
  printf '%s/train-green.txt\n' "$DL_STATE"
}

# dl_ensure_gate_worktree: create the gate worktree (detached at the base) if it does not exist yet.
dl_ensure_gate_worktree() {
  local gate
  gate=$(dl_gate_dir)
  if [ -d "$gate" ]; then
    git -C "$gate" rev-parse --git-dir >/dev/null 2>&1 || dl_die "$gate exists but is not a git worktree"
    [ "$(cd "$gate" && dl_main_root)" = "$DL_ROOT" ] || dl_die "$gate is a worktree of another repository"
  else
    git -C "$DL_ROOT" fetch -q "$DL_REMOTE" || dl_die "git fetch $DL_REMOTE failed"
    git -C "$DL_ROOT" worktree add -q --detach "$gate" "$DL_REMOTE/$DL_BASE" >/dev/null ||
      dl_die "could not create the gate worktree at $gate"
  fi
  printf '%s\n' "$gate"
}

# dl_loop_branch NAME: NAME matches github.feature_patterns (default feat/* fix/* chore/* docs/*), the
# branches the loop itself creates.
dl_loop_branch() {
  local i count pattern
  count=$(cfg_len github.feature_patterns)
  if [ "$count" -eq 0 ]; then
    case "$1" in feat/* | fix/* | chore/* | docs/*) return 0 ;; *) return 1 ;; esac
  fi
  for ((i = 0; i < count; i++)); do
    pattern=$(cfg "github.feature_patterns.$i")
    # shellcheck disable=SC2053  # the pattern is a glob on purpose
    [[ "$1" == $pattern ]] && return 0
  done
  return 1
}

# dl_running_file: where gate-train.sh records the train it is building ("<pid> <branch>..."), removed
# when it ends, so cleanup.sh never touches the refs of a train in progress.
dl_running_file() {
  printf '%s/train-running.txt\n' "$DL_STATE"
}

# dl_ledger_file: one JSON line per branch merge-train.sh merged (the record cleanup.sh trusts first).
dl_ledger_file() {
  printf '%s/merged.jsonl\n' "$DL_STATE"
}

# dl_json_string VALUE: VALUE as a JSON string. Printable ASCII needs only \ and " escaped; other text goes
# through dl_json_list_z, which escapes control characters and replaces bytes that are not UTF-8 (without
# jq or python3 able to: control characters are dropped, other bytes kept).
dl_json_string() {
  local LC_ALL=C value list
  if [[ $1 == *[^\ -~]* ]]; then
    _dl_json_z_pick
    if [ "$DL_JSON_Z_TOOL" = bash ]; then
      _dl_json_ascii "$(printf '%s' "$1" | tr -d '\000-\037\177')"
      return
    fi
    list=$(printf '%s\0' "$1" | dl_json_list_z)
    list=${list#[}
    printf '%s' "${list%]}"
    return
  fi
  _dl_json_ascii "$1"
}

# _dl_json_ascii VALUE: VALUE as a JSON string with only \ and " escaped.
_dl_json_ascii() {
  local value=${1//\\/\\\\}
  printf '"%s"' "${value//\"/\\\"}"
}

# _dl_json_z_pick: set DL_JSON_Z_TOOL to the tool that encodes NUL-separated names: jq when it reads NULs
# whole (jq 1.6's raw slurp may cut its input at the first NUL), else python3, else bash. It runs when this
# library loads, so pipelines and command substitutions inherit the pick, and exports it with the inputs
# it depends on (DL_JSON_Z_FOR), so child scripts reuse it unless DEV_LOOP_NO_JQ, DEV_LOOP_JSON_Z or PATH
# differ. DEV_LOOP_JSON_Z=bash forces the bash fallback (for tests).
_dl_json_z_pick() {
  local inputs="${DEV_LOOP_NO_JQ:-}|${DEV_LOOP_JSON_Z:-}|$PATH"
  case ${DL_JSON_Z_TOOL:-} in
    jq | python3 | bash) [ "${DL_JSON_Z_FOR:-}" = "$inputs" ] && return 0 ;;
  esac
  if [ "${DEV_LOOP_JSON_Z:-}" = bash ]; then
    DL_JSON_Z_TOOL=bash
  elif dl_have_jq && [ "$(printf 'a\0b\0' | jq -R -s -c 'split("\u0000")' 2>/dev/null)" = '["a","b",""]' ]; then
    DL_JSON_Z_TOOL=jq
  elif command -v python3 >/dev/null 2>&1; then
    DL_JSON_Z_TOOL=python3
  else
    DL_JSON_Z_TOOL=bash
  fi
  DL_JSON_Z_FOR=$inputs
  export DL_JSON_Z_TOOL DL_JSON_Z_FOR
}

# dl_json_z_tool: the tool dl_json_list_z and dl_z_lines use (jq, python3 or bash).
dl_json_z_tool() {
  _dl_json_z_pick
  printf '%s\n' "$DL_JSON_Z_TOOL"
}

# _dl_z_plain NAME: true when NAME is not empty and holds no control character (what the bash fallbacks keep).
_dl_z_plain() {
  [ -n "$1" ] && [ "$(printf '%s' "$1" | tr -d '\000-\037\177')" = "$1" ]
}

# dl_json_list_z < NAMES: the NUL-separated names as a compact JSON array of strings, control characters
# escaped and bytes that are not UTF-8 replaced by U+FFFD. The bash fallback (neither jq nor python3 can)
# drops names with a control character (a tab, a line break) and keeps other bytes as they are.
dl_json_list_z() {
  local name out=""
  _dl_json_z_pick
  case $DL_JSON_Z_TOOL in
    jq) jq -R -s -c 'split("\u0000") | map(select(. != ""))' ;;
    python3)
      python3 -I -c '
import json, sys
names = [n for n in sys.stdin.buffer.read().decode("utf-8", "replace").split("\0") if n]
sys.stdout.buffer.write((json.dumps(names, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))
'
      ;;
    *)
      while IFS= read -r -d '' name; do
        if _dl_z_plain "$name"; then out="${out:+$out,}$(_dl_json_ascii "$name")"; fi
      done
      printf '[%s]\n' "$out"
      ;;
  esac
}

# dl_z_lines < NAMES: the NUL-separated names one per line, as dl_json_list_z stores them (bytes that are
# not UTF-8 replaced by U+FFFD), with tabs and line breaks as spaces (the form dl_ledger_rows prints). The
# bash fallback drops the names dl_json_list_z drops (those with a control character).
dl_z_lines() {
  local name
  _dl_json_z_pick
  case $DL_JSON_Z_TOOL in
    jq) jq -R -s -r 'split("\u0000")[] | select(. != "") | gsub("[\t\n\r]"; " ")' ;;
    python3)
      python3 -I -c '
import sys
for name in sys.stdin.buffer.read().decode("utf-8", "replace").split("\0"):
    if name:
        sys.stdout.buffer.write((" ".join(name.replace("\r", "\n").replace("\t", "\n").split("\n")) + "\n").encode("utf-8"))
'
      ;;
    *)
      while IFS= read -r -d '' name; do
        if _dl_z_plain "$name"; then printf '%s\n' "$name"; fi
      done
      ;;
  esac
}

# dl_json_list < LINES: the non-empty lines as a JSON array of strings.
dl_json_list() {
  local line out=""
  while IFS= read -r line; do
    [ -n "$line" ] && out="${out:+$out,}$(dl_json_string "$line")"
  done
  printf '[%s]' "$out"
}

# dl_json_number VALUE: VALUE when it is a whole number, else null.
dl_json_number() {
  case $1 in "" | *[!0-9]*) printf 'null' ;; *) printf '%s' "$((10#$1))" ;; esac
}

# dl_ledger_append BRANCH SOURCE_HEAD PUSHED_HEAD GATED_HEAD GATED_TREE PR MERGE_COMMIT [TICKET REVIEW_ROUNDS
# ADDED DELETED FILES COMPONENTS]: FILES a JSON array of paths (dl_json_list_z), COMPONENTS separated by
# spaces; missing evidence is written as none (null ticket, 0 rounds and lines, empty lists).
dl_ledger_append() {
  mkdir -p "$DL_STATE" &&
    printf '{"branch":%s,"source_head":%s,"head":%s,"gated":%s,"gated_tree":%s,"pr":%s,"merge_commit":%s,"merged_at":%s,"files":%s,"components":%s,"lines":{"added":%s,"deleted":%s},"review_rounds":%s,"ticket":%s}\n' \
      "$(dl_json_string "$1")" "$(dl_json_string "$2")" "$(dl_json_string "$3")" "$(dl_json_string "$4")" \
      "$(dl_json_string "$5")" "$(dl_json_string "$6")" "$(dl_json_string "$7")" \
      "$(dl_json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "${12:-[]}" \
      "$(printf '%s\n' "${13:-}" | tr ' ' '\n' | dl_json_list)" "$(dl_json_number "${10:-0}")" "$(dl_json_number "${11:-0}")" \
      "$(dl_json_number "${9:-0}")" "$(dl_json_number "${8:-}")" >>"$(dl_ledger_file)"
}

# dl_ledger_heads: "<branch> <head>" lines, one per head the ledger accepts as merged (source and pushed).
dl_ledger_heads() {
  local ledger
  ledger=$(dl_ledger_file)
  [ -s "$ledger" ] || return 0
  if dl_have_jq; then
    jq -R -r 'fromjson? | select(type == "object") | .branch as $b | [.source_head, .head] | unique[]
      | select(. != "" and . != null) | "\($b) \(.)"' "$ledger" 2>/dev/null
  else
    python3 -I -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        entry = json.loads(line)
    except (ValueError, UnicodeError):
        continue
    for head in sorted({entry.get("source_head", ""), entry.get("head", "")} - {""}):
        print(entry["branch"], head)
' "$ledger" 2>/dev/null
  fi
}

# dl_ledger_count_since [TIME]: the number of ledger merges after TIME (a UTC time like 2026-01-31T12:00:00Z),
# or of all merges without TIME; lines that are not JSON do not count.
dl_ledger_count_since() {
  local ledger
  ledger=$(dl_ledger_file)
  [ -s "$ledger" ] || { echo 0; return 0; }
  if dl_have_jq; then
    jq -R --arg t "${1:-}" 'fromjson? | select((.merged_at // "") > $t) | 1' "$ledger" 2>/dev/null | wc -l | tr -d ' '
  else
    python3 -I -c '
import json, sys
count = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        entry = json.loads(line)
    except (ValueError, UnicodeError):
        continue
    if isinstance(entry, dict) and str(entry.get("merged_at") or "") > sys.argv[2]:
        count += 1
print(count)
' "$ledger" "${1:-}" 2>/dev/null || echo 0
  fi
}

# dl_doc_audit_file: the marker the orchestrator writes after each doc audit (one line: its UTC time).
dl_doc_audit_file() {
  printf '%s/doc-audit.txt\n' "$DL_STATE"
}

# dl_architect_file: the marker the orchestrator writes after each architect run (one line: its UTC time).
dl_architect_file() {
  printf '%s/architect.txt\n' "$DL_STATE"
}

# dl_ledger_rows: the valid ledger entries in ledger order, as "M<TAB>n<TAB>branch<TAB>ticket<TAB>merged_at
# <TAB>review_rounds<TAB>merge_commit<TAB>has_files" (has_files: 1 when the entry lists its files; n counts
# from 1), each followed by one "F<TAB>n<TAB>path" line per file. Lines that are not JSON objects are skipped.
dl_ledger_rows() {
  local ledger
  ledger=$(dl_ledger_file)
  [ -s "$ledger" ] || return 0
  if dl_have_jq; then
    jq -n -R -r '
      def clean: tostring | gsub("[\t\n\r]"; " ");
      [inputs | fromjson? | select(type == "object")] | to_entries[] | (.key + 1) as $n | .value
      | (["M", $n, .branch // "", .ticket // "", .merged_at // "", .review_rounds // "", .merge_commit // "",
          (if (.files | type) == "array" then 1 else 0 end)] | map(clean) | join("\t")),
        ((if (.files | type) == "array" then .files[] else empty end) | "F\t\($n)\t\(clean)")' "$ledger" 2>/dev/null
  else
    python3 -I -c '
import json, sys
def clean(value):
    value = "" if value is None else value
    if isinstance(value, bool):
        value = "true" if value else "false"
    return str(value).replace("\t", " ").replace("\n", " ").replace("\r", " ")
sys.stdout.reconfigure(errors="replace")
n = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        entry = json.loads(line)
    except (ValueError, UnicodeError):
        continue
    if not isinstance(entry, dict):
        continue
    n += 1
    files = entry.get("files")
    fields = ["M", n] + [entry.get(k) for k in ("branch", "ticket", "merged_at", "review_rounds", "merge_commit")]
    print("\t".join(clean(f) for f in fields + [1 if isinstance(files, list) else 0]))
    for path in files if isinstance(files, list) else []:
        print("F\t%d\t%s" % (n, clean(path)))
' "$ledger" 2>/dev/null
  fi
}

# dl_notes_ticket NOTES BRANCH: the issue a branch closes: the first "Closes #n" (or Fixes, Resolves) in its
# notes file, else the number in the branch name (feat/<n>-slug), else nothing.
dl_notes_ticket() {
  local ticket=""
  [ -f "$1" ] && ticket=$(grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' "$1" | head -n 1 | sed 's/.*#//')
  [ -n "$ticket" ] || ticket=$(printf '%s\n' "$2" | sed -n 's:^[^/]*/\([0-9][0-9]*\)-.*:\1:p')
  printf '%s\n' "$ticket"
}

# dl_notes_review_rounds NOTES: the code-reviewer rounds of a branch: a "Review rounds: <n>" line the
# orchestrator records, else one plus a "Review fixes" heading per round of fixes; 0 without a notes file.
dl_notes_review_rounds() {
  local rounds
  [ -f "$1" ] || { echo 0; return 0; }
  rounds=$(sed -n 's/^[[:space:]]*[Rr]eview rounds:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" | head -n 1)
  [ -n "$rounds" ] || rounds=$(($(grep -ciE '^#+[[:space:]]+review fixes' "$1") + 1))
  echo "$rounds"
}

# dl_diff_lines FROM TO: "<added> <deleted>", the lines the change from FROM to TO adds and deletes (binary
# files count 0).
dl_diff_lines() {
  git diff --numstat "$1" "$2" | awk '{ if ($1 != "-") a += $1; if ($2 != "-") d += $2 } END { print a + 0, d + 0 }'
}

# dl_worktree_of BRANCH: the path of the worktree that has BRANCH checked out (nothing if none);
# with a second line "locked" when that worktree is locked.
dl_worktree_of() {
  git -C "$DL_ROOT" worktree list --porcelain | awk -v ref="refs/heads/$1" '
    function done() { if (match_ && !printed) { printed = 1; print path; if (locked) print "locked"; exit } }
    /^worktree / {done(); path = substr($0, 10); locked = 0; match_ = 0}
    /^locked/ {locked = 1}
    $0 == "branch " ref {match_ = 1}
    END {done()}'
}

# dl_notes_merged_dir: where the notes files of merged branches go.
dl_notes_merged_dir() {
  printf '%s/merged\n' "$(dl_notes_dir)"
}

# dl_archive_note_file FILE: move a notes file to the merged notes directory, stamped with the time of the
# move (cleanup.keep_days counts from the merge); an earlier archived note of the same name is kept.
dl_archive_note_file() {
  local dir target
  dir=$(dl_notes_merged_dir)
  target=$dir/$(basename "$1")
  [ ! -e "$target" ] || target=$dir/$(basename "$1" .md)-$(date +%Y%m%d-%H%M%S)-$$.md
  mkdir -p "$dir" && mv "$1" "$target" && touch "$target"
}

# dl_archive_note BRANCH: archive the branch's notes file (if it exists).
dl_archive_note() {
  local note
  note=$(dl_note_file "$1")
  [ ! -f "$note" ] || dl_archive_note_file "$note"
}

# Lowercase name patterns of secret and data files, matched without regard to case: never build output.
# The strong ones are checked everywhere; the broad ones also match vendored code (credentials.js), so the
# scan inside a whole dependency or cache folder (merge.rebuildable_caches) leaves them out.
if [ -z "${DL_SECRET_STRONG_PATTERNS+set}" ]; then
  DL_SECRET_STRONG_PATTERNS=(.env '.env.*' '*.env' '*.pem' '*.key' '*.p12' '*.pfx' '*.sqlite' '*.sqlite3'
    '*.sqlite-*' '*.db')
  DL_SECRET_BROAD_PATTERNS=('id_rsa*' 'id_ed25519*' 'id_ecdsa*' 'id_dsa*' 'credentials*' 'secrets*')
  readonly DL_SECRET_STRONG_PATTERNS DL_SECRET_BROAD_PATTERNS
fi

# dl_secret_name NAME: succeeds when NAME looks like a secret or data file (strong or broad, any case).
dl_secret_name() {
  local name pattern
  name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for pattern in "${DL_SECRET_STRONG_PATTERNS[@]}" "${DL_SECRET_BROAD_PATTERNS[@]}"; do
    # shellcheck disable=SC2053 # the pattern is a glob on purpose
    [[ "$name" == $pattern ]] && return 0
  done
  return 1
}

# dl_secret_in DIR [strong]: the first file or directory under DIR whose name is a secret or data name
# (strong or broad; only strong with "strong").
dl_secret_in() {
  local expr=() pattern patterns=("${DL_SECRET_STRONG_PATTERNS[@]}")
  [ "${2:-}" = strong ] || patterns+=("${DL_SECRET_BROAD_PATTERNS[@]}")
  for pattern in "${patterns[@]}"; do
    [ ${#expr[@]} -eq 0 ] || expr+=(-o)
    expr+=(-iname "$pattern")
  done
  find "$1" \( "${expr[@]}" \) -print 2>/dev/null | head -n 1
}

# dl_rebuildable_entry KEEP CACHES ENTRY: succeeds when the ignored ENTRY is build output by name: its
# last component is in KEEP (" a b ... "), or a directory above it is in both KEEP and CACHES and ENTRY is
# not a secret or data file (a self-ignoring cache such as .ruff_cache lists its files one by one).
dl_rebuildable_entry() {
  local keep=$1 caches=$2 path=${3%/} name dir
  name=${path##*/}
  [[ "$keep" == *" $name "* ]] && return 0
  ! dl_secret_name "$name" || return 1
  while [ "$path" != "${path%/*}" ]; do
    path=${path%/*}
    dir=${path##*/}
    [[ "$keep" == *" $dir "* && "$caches" == *" $dir "* ]] && return 0
  done
  return 1
}

# dl_in_cache CACHES ENTRY: succeeds when a component of ENTRY (a/b/) is in CACHES (" a b ... "), so ENTRY
# is a dependency or cache folder or lies inside one (.venv/lib/ of a .venv with its own .gitignore).
dl_in_cache() {
  local caches=$1 path=${2%/}
  while [ -n "$path" ]; do
    [[ "$caches" == *" ${path##*/} "* ]] && return 0
    [ "$path" != "${path%/*}" ] || return 1
    path=${path%/*}
  done
  return 1
}

# dl_cfg_words PATH DEFAULT: the array at PATH in the project config as " a b ... ", or DEFAULT.
dl_cfg_words() {
  local count i words=" "
  count=$(cfg_len "$1")
  [ "$count" -gt 0 ] || { printf '%s\n' "$2"; return 0; }
  for ((i = 0; i < count; i++)); do words+="$(cfg "$1.$i") "; done
  printf '%s\n' "$words"
}

# dl_unrebuildable_ignored WORKTREE: the first ignored file or directory of WORKTREE that is not build
# output (merge.rebuildable, default node_modules dist build target .venv and the usual caches; files
# inside are judged one by one only under merge.rebuildable_caches, default the caches and dependencies).
dl_unrebuildable_ignored() {
  local caches=" node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .next .turbo .parcel-cache "
  local keep entry found mode
  keep=$(dl_cfg_words merge.rebuildable " dist build target out coverage htmlcov .coverage$caches")
  caches=$(dl_cfg_words merge.rebuildable_caches "$caches")
  # A directory listed only because it holds other listed entries (web/ for web/node_modules/) is skipped.
  git -C "$1" ls-files --others --ignored --exclude-standard --directory 2>/dev/null | LC_ALL=C sort -r |
    awk '{ if (index(prev, $0) != 1 || substr($0, length($0)) != "/") print; prev = $0 }' | while read -r entry; do
    # The entry itself must be build output (build/local.env is not), and a build directory must not hold
    # secrets or data (a false match only keeps the worktree); in a dependency or cache folder only a strong
    # name counts, since vendored code is named credentials.js or secrets.py.
    dl_rebuildable_entry "$keep" "$caches" "$entry" || { printf '%s\n' "$entry"; break; }
    if [ -d "$1/$entry" ]; then
      mode=""
      ! dl_in_cache "$caches" "$entry" || mode=strong
      found=$(dl_secret_in "$1/$entry" ${mode:+"$mode"})
      [ -z "$found" ] || { printf '%s\n' "${found#"$1"/}"; break; }
    fi
  done
}

# dl_remove_merged_local BRANCH HEAD...: after BRANCH merged, delete its local branch when its tip is one
# of the merged HEADs, removing a clean worktree that has it checked out first. Removing a worktree removes
# its ignored files too, so only one whose ignored files are all build output goes (merge.rebuildable);
# one holding anything else (.env, keys, local data) is kept. Prints what it kept, and why.
dl_remove_merged_local() {
  local branch=$1 tip head accepted="" worktree
  shift
  tip=$(git -C "$DL_ROOT" rev-parse -q --verify "refs/heads/$branch") || return 0
  for head in "$@"; do [ "$tip" = "$head" ] && accepted=yes; done
  if [ -z "$accepted" ]; then
    echo "kept local $branch: it has commits that were not merged"
    return 0
  fi
  worktree=$(dl_worktree_of "$branch")
  if [ -n "$worktree" ]; then
    local path
    path=$(printf '%s\n' "$worktree" | head -n 1)
    if [ "$path" = "$DL_ROOT" ]; then
      echo "kept local $branch: the main checkout has it checked out"
      return 0
    elif [ "$(printf '%s\n' "$worktree" | sed -n 2p)" = locked ]; then
      echo "kept local $branch: its worktree $path is locked"
      return 0
    elif [ -n "$(dl_unrebuildable_ignored "$path")" ]; then
      echo "kept local $branch: its worktree $path holds ignored files that are not build output ($(dl_unrebuildable_ignored "$path"))"
      return 0
    elif ! git -C "$DL_ROOT" worktree remove "$path" >/dev/null 2>&1; then
      echo "kept local $branch: its worktree $path has changes"
      return 0
    fi
  fi
  git -C "$DL_ROOT" branch -q -D "$branch" >/dev/null 2>&1 || echo "kept local $branch: git branch -D failed"
}

# Pick the NUL tool at load time on purpose, so subshells and child scripts inherit it (#27).
_dl_json_z_pick
