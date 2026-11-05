# shellcheck shell=bash
# The holdout scenario store: where the scenarios live (scenarios.dir), what a scenario file holds, and
# whether it is valid, and the helpers of the gate's scenario stage. Source scripts/lib/common.sh first (and
# scripts/lib/reasons.sh for dl_scenario_verdict) and call dl_load_config.
#
# A scenario is one Markdown file with front matter between two --- lines: `key: value` lines, lists as
# `[a, b]`, values optionally quoted, ` # comments` after unquoted values. Keys: id, title, spec, tags,
# required (true or false). The body below the front matter must not be empty.

# dl_scenarios_setting: whether scenarios are on and where that came from: `on|off explicit` when the config
# has "scenarios" (false, null, "" and "false" turn them off, anything else on), else `on preset` with "factory":
# "dark", else `off default`. hooks/guard-role.py applies the same rule.
dl_scenarios_setting() {
  if cfg_has scenarios; then
    case $(cfg scenarios "") in
      "" | false) echo "off explicit" ;;
      *) echo "on explicit" ;;
    esac
  elif [ "$(dl_factory)" = dark ]; then
    echo "on preset"
  else
    echo "off default"
  fi
}

# dl_scenarios_on: true when scenarios are on (opt-in with a scenarios block, or by the dark factory preset).
dl_scenarios_on() {
  case $(dl_scenarios_setting) in on*) return 0 ;; *) return 1 ;; esac
}

# dl_scenarios_dir: the absolute store directory; scenarios.dir with ~ and <repo> expanded, relative paths
# against the main worktree, default ~/.dev-loop/<repo>/scenarios (the state directory).
dl_scenarios_dir() {
  local configured
  configured=$(cfg scenarios.dir "")
  if [ -z "$configured" ]; then
    printf '%s/scenarios\n' "$DL_STATE"
  else
    dl_resolve "${configured//"<repo>"/$DL_REPO}"
  fi
}

# dl_scenarios_files DIR: the scenario files (*.md at any depth, not under .git; a symlink to a file counts),
# sorted, one per line.
dl_scenarios_files() {
  local file
  [ -d "$1" ] || return 0
  find "${1%/}" -name '*.md' \( -type f -o -type l \) ! -path '*/.git/*' | LC_ALL=C sort |
    while IFS= read -r file; do
      [ -f "$file" ] && printf '%s\n' "$file"
    done
}

# shellcheck disable=SC2016  # an awk program
_dl_scenario_awk='
function clean(v, q, rest, i) {
  gsub(/\t/, " ", v)
  sub(/^[ \t]+/, "", v)
  q = substr(v, 1, 1)
  if (q == "\"" || q == "\047") {
    rest = substr(v, 2)
    i = index(rest, q)
    if (i) return substr(rest, 1, i - 1)
  }
  if (v ~ /^#/) return ""
  sub(/[ \t]+#.*$/, "", v)
  sub(/[ \t]+$/, "", v)
  return v
}
{ sub(/\r$/, "") }
NR == 1 { sub(/^\357\273\277/, "") }
NR == 1 { if ($0 ~ /^---[ \t]*$/) { state = 1; next } else exit }
state == 1 && /^---[ \t]*$/ { state = 2; next }
state == 1 && match($0, /^[A-Za-z_][A-Za-z0-9_-]*:/) {
  key = substr($0, 1, RLENGTH - 1)
  if (!(key in seen)) { seen[key] = 1; print key "\t" clean(substr($0, RLENGTH + 1)) }
  next
}
state == 2 && /[^ \t]/ { body = 1; exit }
END { print "@shape\t" (state == 0 ? "none" : state == 1 ? "unclosed" : body ? "ok" : "empty") }
'

# dl_scenario_front FILE: the parsed front matter as `key<TAB>value` lines (first occurrence of a key wins),
# then `@shape<TAB>ok|empty|unclosed|none` (empty: no body; none: no front matter). A UTF-8 BOM is ignored.
dl_scenario_front() {
  LC_ALL=C awk "$_dl_scenario_awk" "$1"
}

# _dl_scenario_value KEY < front: the value of KEY in dl_scenario_front output.
_dl_scenario_value() {
  awk -F'\t' -v key="$1" '$1 == key { print substr($0, length(key) + 2); exit }'
}

# dl_scenario_field FILE KEY: the value of KEY in the front matter of FILE (quotes and comments removed).
dl_scenario_field() {
  dl_scenario_front "$1" | _dl_scenario_value "$2"
}

# dl_scenario_list FILE KEY: the items of a list field ([a, b]) one per line; a plain value is one item.
dl_scenario_list() {
  dl_scenario_field "$1" "$2" | awk '{
    v = $0
    if (v ~ /^\[.*\]$/) v = substr(v, 2, length(v) - 2)
    n = split(v, items, ",")
    for (i = 1; i <= n; i++) {
      item = items[i]
      gsub(/^[ \t]+|[ \t]+$/, "", item)
      if (item ~ /^".*"$/ || item ~ /^\047.*\047$/) item = substr(item, 2, length(item) - 2)
      if (item != "") print item
    }
  }'
}

# dl_scenario_problems FILE: the reasons FILE is invalid on its own, one per line (duplicates are a store
# matter: dl_scenarios_validate).
dl_scenario_problems() {
  local front required
  front=$(dl_scenario_front "$1")
  case $(printf '%s\n' "$front" | _dl_scenario_value @shape) in
    none) echo "no front matter (the first line must be ---)" && return ;;
    unclosed) echo "front matter is not closed (no second --- line)" && return ;;
    empty) echo "empty body (describe the user, the steps and what satisfied looks like)" ;;
  esac
  [ -n "$(printf '%s\n' "$front" | _dl_scenario_value id)" ] || echo "missing id"
  [ -n "$(printf '%s\n' "$front" | _dl_scenario_value title)" ] || echo "missing title"
  required=$(printf '%s\n' "$front" | _dl_scenario_value required)
  case $required in
    true | false) ;;
    *) echo "required: \"$required\" is not true or false" ;;
  esac
}

# dl_scenarios_validate DIR: print `<file relative to DIR><TAB><reason>` for each problem (a file may have
# several); exit 1 when there is any. A duplicate id is reported on every file after the first.
dl_scenarios_validate() {
  local dir=${1%/} file rel id first ids="" reason bad=0
  while IFS= read -r file; do
    rel=${file#"$dir"/}
    while IFS= read -r reason; do
      [ -n "$reason" ] && printf '%s\t%s\n' "$rel" "$reason" && bad=1
    done < <(dl_scenario_problems "$file")
    id=$(dl_scenario_field "$file" id)
    [ -n "$id" ] || continue
    first=$(printf '%s\n' "$ids" | id=$id awk -F'\t' '$1 == ENVIRON["id"] { print $2; exit }')
    if [ -n "$first" ]; then
      printf '%s\tduplicate id %s (also in %s)\n' "$rel" "$id" "$first"
      bad=1
    else
      ids+="$id"$'\t'"$rel"$'\n'
    fi
  done < <(dl_scenarios_files "$dir")
  [ "$bad" -eq 0 ]
}

# dl_scenarios_count DIR: the number of scenario files in DIR.
dl_scenarios_count() {
  dl_scenarios_files "$1" | grep -c . || true
}

# dl_scenarios_required_count DIR: the number of scenario files whose required is exactly true.
dl_scenarios_required_count() {
  local file count=0
  while IFS= read -r file; do
    [ "$(dl_scenario_field "$file" required)" = true ] && count=$((count + 1))
  done < <(dl_scenarios_files "$1")
  echo "$count"
}

# dl_scenarios_ready DIR: true when DIR holds at least one valid scenario whose required is true (what a dark
# factory needs).
dl_scenarios_ready() {
  local file
  while IFS= read -r file; do
    [ "$(dl_scenario_field "$file" required)" = true ] && [ -z "$(dl_scenario_problems "$file")" ] && return 0
  done < <(dl_scenarios_files "$1")
  return 1
}

# dl_scenarios_share_ok VALUE: true when VALUE is a number from 0 to 1 (pass, min_satisfaction, sealed).
dl_scenarios_share_ok() {
  printf '%s\n' "$1" | grep -Eq '^(0(\.[0-9]*)?|\.[0-9]+|1(\.0*)?)$'
}

# The gate's scenario stage (scenario-stage.sh) prints these lines into the gate's summary: the unsatisfied
# scenarios that are not sealed, the sealed count and the verdict.
# shellcheck disable=SC2034  # read by gate-train.sh
DL_SCENARIOS_SUMMARY='^scenario .+ unsatisfied \(|^scenarios (sealed|green|red|error):'

# dl_scenarios_judge_command: the command that judges one scenario (scenarios.judge), by default headless
# Claude Code with the scenario-judge agent and models.scenario-judge. It reads DL_SCENARIO_FILE,
# DL_SCENARIO_ID and DL_SCENARIO_TARGET and prints one JSON object as its last JSON line.
dl_scenarios_judge_command() {
  local judge model
  judge=$(cfg scenarios.judge "")
  if [ -n "$judge" ]; then
    printf '%s\n' "$judge"
    return
  fi
  model=$(cfg models.scenario-judge inherit)
  [ "$model" = inherit ] && model="" || model="--model $model "
  # The prompt follows -p and the variadic options (--allowedTools, --add-dir) take =value, so none of them
  # swallows the prompt as another value.
  # shellcheck disable=SC2016  # expanded by the shell that runs the judge
  printf '%s --agent dev-loop:scenario-judge %s%s\n' \
    'claude -p "Judge the scenario $DL_SCENARIO_ID in $DL_SCENARIO_FILE against the running system: ${DL_SCENARIO_TARGET:-the project in the current directory}. End with the JSON object."' \
    "$model" '--no-session-persistence --permission-mode dontAsk --allowedTools=Read,Grep,Glob,Bash --add-dir="$(dirname "$DL_SCENARIO_FILE")"'
}

# dl_scenario_sealed FILE|ID [SHARE]: true when the scenario (a scenario file, or an id) is sealed: only
# counted, never named. SHARE defaults to scenarios.sealed (0). It is sealed when its id's checksum modulo
# 1000 is below SHARE * 1000, so the choice depends only on the id; the orchestrator uses it too.
dl_scenario_sealed() {
  local id=$1 hash
  [ -f "$1" ] && id=$(dl_scenario_field "$1" id)
  hash=$(printf '%s' "$id" | cksum | awk '{ print $1 % 1000 }')
  awk -v h="$hash" -v s="${2:-$(cfg scenarios.sealed 0)}" 'BEGIN { exit !(h < s * 1000) }'
}

# dl_scenario_affected FILE CHANGED: true when an item of the scenario's spec or tags occurs in a path of the
# file CHANGED (one path per line), ignoring case.
dl_scenario_affected() {
  local items
  items=$(dl_scenario_list "$1" spec; dl_scenario_list "$1" tags)
  [ -n "$items" ] && [ -f "$2" ] || return 1
  awk 'NR == FNR { items[tolower($0)]; next }
    { path = tolower($0); for (item in items) if (index(path, item)) { found = 1; exit } }
    END { exit !found }' <(printf '%s\n' "$items") "$2"
}

# dl_scenario_verdict ID < judge output: the judge's verdict from its last line that starts with "{":
# `ok<TAB>satisfied<TAB>missing<TAB>result JSON` or `invalid<TAB>reason` (no JSON object, an id other than ID,
# satisfied not a number from 0 to 1).
dl_scenario_verdict() {
  local line result satisfied id missing
  line=$(awk '/^[ \t]*\{/ { last = $0 } END { print last }')
  result=$(printf '%s' "$line" | dl_json_normalized "")
  case $result in
    "{"*) ;;
    *) printf 'invalid\tno JSON object in the output\n' && return ;;
  esac
  id=$(printf '%s' "$result" | json_get id)
  [ "$id" = "$1" ] || { printf 'invalid\tthe id is not the scenario'"'"'s id\n' && return; }
  satisfied=$(printf '%s' "$result" | json_get satisfied)
  dl_scenarios_share_ok "$satisfied" || { printf 'invalid\tsatisfied is not a number from 0 to 1\n' && return; }
  missing=$(printf '%s' "$result" | json_get missing)
  missing=${missing//[$'\t\r\n']/ }
  printf 'ok\t%s\t%s\t%s\n' "$satisfied" "$missing" "$result"
}

# dl_scenarios_at_least VALUE THRESHOLD: true when the number VALUE is at least THRESHOLD.
dl_scenarios_at_least() {
  awk -v v="$1" -v t="$2" 'BEGIN { exit !(v + 0 >= t + 0) }'
}
