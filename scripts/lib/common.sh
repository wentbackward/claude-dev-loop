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

# dl_running_file: where gate-train.sh records the train it is building ("<pid> <branch>..."), removed
# when it ends, so cleanup.sh never touches the refs of a train in progress.
dl_running_file() {
  printf '%s/train-running.txt\n' "$DL_STATE"
}

# dl_ledger_file: one JSON line per branch merge-train.sh merged (the record cleanup.sh trusts first).
dl_ledger_file() {
  printf '%s/merged.jsonl\n' "$DL_STATE"
}

# dl_json_string VALUE: VALUE as a JSON string (git refs and hashes need only \ and " escaped).
dl_json_string() {
  local value=${1//\\/\\\\}
  printf '"%s"' "${value//\"/\\\"}"
}

# dl_ledger_append BRANCH SOURCE_HEAD PUSHED_HEAD GATED_HEAD GATED_TREE PR MERGE_COMMIT
dl_ledger_append() {
  mkdir -p "$DL_STATE" &&
    printf '{"branch":%s,"source_head":%s,"head":%s,"gated":%s,"gated_tree":%s,"pr":%s,"merge_commit":%s,"merged_at":%s}\n' \
      "$(dl_json_string "$1")" "$(dl_json_string "$2")" "$(dl_json_string "$3")" "$(dl_json_string "$4")" \
      "$(dl_json_string "$5")" "$(dl_json_string "$6")" "$(dl_json_string "$7")" \
      "$(dl_json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" >>"$(dl_ledger_file)"
}

# dl_ledger_heads: "<branch> <head>" lines, one per head the ledger accepts as merged (source and pushed).
dl_ledger_heads() {
  local ledger
  ledger=$(dl_ledger_file)
  [ -s "$ledger" ] || return 0
  if dl_have_jq; then
    jq -r '.branch as $b | [.source_head, .head] | unique[] | select(. != "") | "\($b) \(.)"' "$ledger" 2>/dev/null
  else
    python3 -I -c '
import json, sys
for line in open(sys.argv[1]):
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    for head in sorted({entry.get("source_head", ""), entry.get("head", "")} - {""}):
        print(entry["branch"], head)
' "$ledger" 2>/dev/null
  fi
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

# dl_archive_note BRANCH: move the branch's notes file to the merged notes directory (if it exists).
dl_archive_note() {
  local note
  note=$(dl_note_file "$1")
  [ -f "$note" ] || return 0
  mkdir -p "$(dl_notes_merged_dir)" && mv -f "$note" "$(dl_notes_merged_dir)/"
}

# dl_remove_merged_local BRANCH HEAD...: after BRANCH merged, delete its local branch when its tip is one
# of the merged HEADs, removing a clean worktree that has it checked out first. Prints what it kept, and why.
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
    elif ! git -C "$DL_ROOT" worktree remove "$path" >/dev/null 2>&1; then
      echo "kept local $branch: its worktree $path has changes"
      return 0
    fi
  fi
  git -C "$DL_ROOT" branch -q -D "$branch" >/dev/null 2>&1 || echo "kept local $branch: git branch -D failed"
}
