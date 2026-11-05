# shellcheck shell=bash
# Reasons in a branch's notes and the gate's own rules in .dev-loop.json, shared by gate-train.sh and
# lib/arch.sh. Source scripts/lib/common.sh first.

# The gate-relevant keys of .dev-loop.json: the checks and options that judge a branch, and the settings that
# change how the loop merges, deletes, stops and separates roles. "architecture" has its own rule (lib/arch.sh).
DL_GATE_RULE_KEYS="checks gate_setup affected parallel fail_fast fast_check docs merge cleanup stop_gate models
factory identities github"

# dl_notes_reason FILE SECTION: the notes file's "## SECTION" section (any case) has a reason: a line of text
# that is not a placeholder ("none", "n/a", "TODO", "not applicable" and the like, in any case, also repeated,
# followed by filler such as "yet" or "for now", or by punctuation and more, as in "none: ..." or
# "n/a (...)"); "none of the edges ..." and "no-op rename ..." are reasons.
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
        if (rest == "" || rest !~ /^[a-z0-9]/ || placeholder(rest)) return 1
      }
      return 0
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

# dl_gate_rules_changed FROM TO: the gate-relevant keys whose values differ between .dev-loop.json at commit
# FROM and at commit TO (normalized JSON), one per line; nothing when FROM has no .dev-loop.json (a setup
# branch adds the first rules, it loosens none).
dl_gate_rules_changed() {
  local before after key
  before=$(git show "$1:.dev-loop.json" 2>/dev/null) || return 0
  after=$(git show "$2:.dev-loop.json" 2>/dev/null)
  for key in $DL_GATE_RULE_KEYS; do
    [ "$(printf '%s' "$before" | dl_json_normalized "$key")" = "$(printf '%s' "$after" | dl_json_normalized "$key")" ] ||
      echo "$key"
  done
}
