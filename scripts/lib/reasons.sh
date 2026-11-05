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

# dl_json_normalized PATH < json: the value at PATH as compact JSON with sorted keys (nothing when missing),
# so two blocks that differ only in key order or whitespace print the same.
dl_json_normalized() {
  if dl_have_jq; then
    jq -cS --arg p "$1" '
      ($p | if . == "" then [] else split(".") | map(tonumber? // .) end) as $k
      | (try getpath($k) catch null) | if . == null then empty else . end' 2>/dev/null
  else
    python3 -I -c '
import json, sys
try:
    value = json.load(sys.stdin)
    for key in [p for p in sys.argv[1].split(".") if p]:
        value = value[int(key)] if isinstance(value, list) else value[key]
except (KeyError, IndexError, ValueError, TypeError):
    sys.exit(0)
if value is not None:
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))
' "$1" 2>/dev/null
  fi
}

# dl_json_keys < json: the top-level keys of a JSON object, sorted, one per line (nothing for another value).
dl_json_keys() {
  if dl_have_jq; then
    jq -r 'if type == "object" then keys[] else empty end' 2>/dev/null
  else
    python3 -I -c '
import json, sys
try:
    value = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
if isinstance(value, dict):
    print("\n".join(sorted(value)))
' 2>/dev/null
  fi
}

# dl_json_top KEY < json: the value of the top-level KEY (taken literally, dots included) as compact JSON with
# sorted keys; nothing when the document is not an object or has no such key.
dl_json_top() {
  if dl_have_jq; then
    jq -cS --arg k "$1" 'if type == "object" and has($k) then .[$k] else empty end' 2>/dev/null
  else
    python3 -I -c '
import json, sys
try:
    value = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
if isinstance(value, dict) and sys.argv[1] in value:
    print(json.dumps(value[sys.argv[1]], sort_keys=True, separators=(",", ":")))
' "$1" 2>/dev/null
  fi
}

# dl_json_object TEXT: TEXT is a JSON object.
dl_json_object() {
  case $(printf '%s' "$1" | dl_json_normalized "") in "{"*) return 0 ;; esac
  return 1
}

# dl_gate_rules_changed FROM TO: every top-level key of .dev-loop.json but "architecture" (#17 judges it)
# whose value differs between commit FROM and commit TO (normalized JSON), one per line, or ".dev-loop.json"
# when the file changed but no key can be named (it is not a JSON object on one side). Nothing when FROM has no .dev-loop.json: the
# setup branch adds the first rules, and the user reviews the setup.
dl_gate_rules_changed() {
  local before after key named=""
  before=$(git show "$1:.dev-loop.json" 2>/dev/null) || return 0
  after=$(git show "$2:.dev-loop.json" 2>/dev/null)
  while IFS= read -r key; do
    [ -n "$key" ] && [ "$key" != architecture ] || continue
    [ "$(printf '%s' "$before" | dl_json_top "$key")" = "$(printf '%s' "$after" | dl_json_top "$key")" ] ||
      { printf '%s\n' "$key"; named=yes; }
  done < <({ printf '%s' "$before" | dl_json_keys; printf '%s' "$after" | dl_json_keys; } | LC_ALL=C sort -u)
  [ -z "$named" ] || return 0
  dl_json_object "$before" && dl_json_object "$after" && return 0
  [ "$(printf '%s' "$before" | dl_json_normalized "")" = "$(printf '%s' "$after" | dl_json_normalized "")" ] ||
    echo .dev-loop.json
}
