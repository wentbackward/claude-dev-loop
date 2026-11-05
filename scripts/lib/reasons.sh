# shellcheck shell=bash
# Reasons in a branch's notes and the gate's own rules in .dev-loop.json, shared by gate-train.sh and
# lib/arch.sh. Source scripts/lib/common.sh first.

# dl_notes_reason FILE SECTION: the notes file's "## SECTION" section (any case) has a reason: a line of text
# that is not a placeholder ("none", "n/a", "TODO", "not applicable" and the like, in any case, also repeated,
# followed by filler such as "yet" or "for now", or by punctuation and more, as in "none: ..." or
# "n/a (...)"); "none of the edges ...", "no-op rename ..." and a placeholder word, a comma and at least
# three more words that are not a placeholder ("No, the check was redundant") are reasons.
dl_notes_reason() {
  [ -n "$1" ] && [ -f "$1" ] || return 1
  awk -v section="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" '
    BEGIN {
      count = split("none|nothing|n/a|na|n.a|todo|tbd|tba|fixme|xxx|nil|null|no|nope|empty|later|" \
        "not applicable|not needed|not relevant|none needed|none yet|none required|no change|no changes|" \
        "no reason|nothing changed|nothing to report|nothing to add|nothing to say", words, "|")
      fillers = split("yet|at all|needed|required|for now", filler, "|")
    }
    # starts_word TEXT WORD: TEXT starts with WORD as a whole word (a hyphen right after it joins a word).
    function starts_word(text, word) {
      return substr(text, 1, length(word)) == word && substr(text, length(word) + 1, 1) !~ /[-a-z0-9\/.]/
    }
    # after_fillers TEXT: TEXT without its leading filler words and spaces.
    function after_fillers(text,   i, again) {
      do {
        again = 0
        sub(/^[ \t]+/, "", text)
        for (i = 1; i <= fillers; i++)
          if (starts_word(text, filler[i])) { text = substr(text, length(filler[i]) + 1); again = 1 }
      } while (again)
      return text
    }
    # placeholder TEXT: TEXT is placeholder words, alone, repeated, with filler, or followed by a non-word
    # character (after spaces).
    function placeholder(text,   i, rest) {
      for (i = 1; i <= count; i++) {
        if (!starts_word(text, words[i])) continue
        rest = after_fillers(substr(text, length(words[i]) + 1))
        if (comma_sentence(rest)) continue
        if (rest == "" || rest !~ /^[a-z0-9]/ || placeholder(rest)) return 1
      }
      return 0
    }
    # comma_sentence REST: REST is a comma and at least three words that are not a placeholder.
    function comma_sentence(rest,   tail, parts) {
      if (rest !~ /^,/) return 0
      tail = rest
      sub(/^,[ \t]*/, "", tail)
      return split(tail, parts, /[ \t]+/) >= 3 && !placeholder(tail)
    }
    # placeholder_line LINE: the line, without list markers, emphasis and trailing punctuation, is a placeholder.
    function placeholder_line(text) {
      text = tolower(text)
      gsub(/[`*_"]/, "", text)
      sub(/^[ \t]*(([-+*>]|[0-9]+[.)])[ \t]*)*/, "", text)
      sub(/[ \t.!?]+$/, "", text)
      return placeholder(text)
    }
    /^#+[ \t]/ { heading = tolower($0); sub(/^#+[ \t]+/, "", heading); sub(/[ \t]+$/, "", heading)
                 in_section = ($0 ~ /^##[ \t]/ && heading == section); next }
    in_section && $0 ~ /[A-Za-z0-9]/ && $0 !~ /^[ \t]*<!--/ && !placeholder_line($0) { found = 1; exit }
    END { exit !found }' "$1"
}

# _DL_JSON_PY: the python3 fallback's strict reader, as jq -s reads: load() is the one JSON document on
# stdin, or exits quietly when there is none, more than one or trailing garbage. It also exits on NaN and
# Infinity, which jq (1.7 and later) reads as null and a large number: the file is then unparseable and
# compared as raw text, so a change is still flagged, never missed. name(key) is a key as one JSON string,
# as jq's @json writes it.
_DL_JSON_PY='
import json, sys
def load():
    def reject(constant):
        raise ValueError(constant)
    try:
        return json.loads(sys.stdin.read(), parse_constant=reject)
    except ValueError:
        sys.exit(0)
def name(key):
    return json.dumps(key, ensure_ascii=False).replace("\x7f", "\\u007f")
'

# _DL_JQ_ONE: the jq prefix that keeps a slurped input only when it is exactly one document.
_DL_JQ_ONE='if length == 1 then .[0] else empty end'

# dl_json_normalized PATH < json: the value at PATH as compact JSON with sorted keys (nothing when missing or
# when the input is not exactly one JSON document), so two blocks that differ only in key order or whitespace
# print the same.
dl_json_normalized() {
  if dl_have_jq; then
    jq -s -cS --arg p "$1" "$_DL_JQ_ONE"' as $doc
      | ($p | if . == "" then [] else split(".") | map(tonumber? // .) end) as $k
      | ($doc | try getpath($k) catch null) | if . == null then empty else . end' 2>/dev/null
  else
    python3 -I -c "$_DL_JSON_PY"'
value = load()
try:
    for key in [p for p in sys.argv[1].split(".") if p]:
        value = value[int(key)] if isinstance(value, list) else value[key]
except (KeyError, IndexError, ValueError, TypeError):
    sys.exit(0)
if value is not None:
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))
' "$1" 2>/dev/null
  fi
}

# dl_json_keys < json: the top-level keys of a JSON object, each as one JSON string (so "" and a key with a
# newline are one line too), sorted, one per line; nothing for another value or an unparseable input.
dl_json_keys() {
  if dl_have_jq; then
    jq -s -r "$_DL_JQ_ONE"' | if type == "object" then keys[] | @json else empty end' 2>/dev/null
  else
    python3 -I -c "$_DL_JSON_PY"'
value = load()
if isinstance(value, dict):
    for key in sorted(value):
        print(name(key))
' 2>/dev/null
  fi
}

# dl_json_top KEY < json: the value of the top-level key KEY (a JSON string, as dl_json_keys prints it) as
# compact JSON with sorted keys; nothing when the input is not one JSON object or has no such key.
dl_json_top() {
  if dl_have_jq; then
    jq -s -cS --argjson k "$1" "$_DL_JQ_ONE"' | if type == "object" and has($k) then .[$k] else empty end' \
      2>/dev/null
  else
    python3 -I -c "$_DL_JSON_PY"'
value, key = load(), json.loads(sys.argv[1])
if isinstance(value, dict) and key in value:
    print(json.dumps(value[key], sort_keys=True, separators=(",", ":")))
' "$1" 2>/dev/null
  fi
}

# dl_json_object TEXT: TEXT is a JSON object.
dl_json_object() {
  case $(printf '%s' "$1" | dl_json_normalized "") in "{"*) return 0 ;; esac
  return 1
}

# dl_json_key_name KEY: KEY (a JSON string) as a name for a message: bare when that is unambiguous, else the
# JSON string itself ("" and keys with a quote, a backslash or a control character).
dl_json_key_name() {
  case $1 in
    '""' | *\\*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "${1:1:${#1}-2}" ;;
  esac
}

# dl_gate_rules_changed FROM TO: every top-level key of .dev-loop.json but "architecture" (#17 judges it)
# whose value differs between commit FROM and commit TO (normalized JSON), one name per line (see
# dl_json_key_name), or ".dev-loop.json" when the file changed but no key can be named (it is not one JSON
# object on one side; two unparseable sides compare as raw text). Nothing when FROM has no .dev-loop.json:
# the setup branch adds the first rules, and the user reviews the setup (the gate says so).
dl_gate_rules_changed() {
  local before after key named="" norm_before norm_after
  before=$(git show "$1:.dev-loop.json" 2>/dev/null) || return 0
  after=$(git show "$2:.dev-loop.json" 2>/dev/null)
  while IFS= read -r key; do
    [ "$key" != '"architecture"' ] || continue
    [ "$(printf '%s' "$before" | dl_json_top "$key")" = "$(printf '%s' "$after" | dl_json_top "$key")" ] ||
      { dl_json_key_name "$key"; named=yes; }
  done < <({ printf '%s' "$before" | dl_json_keys; printf '%s' "$after" | dl_json_keys; } | LC_ALL=C sort -u)
  [ -z "$named" ] || return 0
  dl_json_object "$before" && dl_json_object "$after" && return 0
  norm_before=$(printf '%s' "$before" | dl_json_normalized "")
  norm_after=$(printf '%s' "$after" | dl_json_normalized "")
  if [ "$norm_before" != "$norm_after" ] || { [ -z "$norm_before" ] && [ "$before" != "$after" ]; }; then
    echo .dev-loop.json
  fi
}
