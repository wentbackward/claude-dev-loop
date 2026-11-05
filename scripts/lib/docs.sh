# shellcheck shell=bash
# Helpers for the current-state docs ("docs" in .dev-loop.json), shared by docs-check.sh, gate-train.sh and
# doctor.sh. Source scripts/lib/common.sh and run dl_load_config first.

# dl_docs_aspects: one "<name><TAB><path>" line per docs aspect, in config order (a trailing / dropped).
dl_docs_aspects() {
  [ -n "${DL_CONFIG:-}" ] && [ -f "$DL_CONFIG" ] || return 0
  if dl_have_jq; then
    jq -r '(.docs.aspects // {}) | if type == "object" then to_entries[] | "\(.key)\t\(.value)" else empty end' \
      "$DL_CONFIG" 2>/dev/null
  else
    python3 -I -c '
import json, sys
try:
    aspects = (json.load(open(sys.argv[1])).get("docs") or {}).get("aspects") or {}
except (ValueError, AttributeError):
    sys.exit(0)
if isinstance(aspects, dict):
    for name, path in aspects.items():
        print("%s\t%s" % (name, path))
' "$DL_CONFIG" 2>/dev/null
  fi | sed 's:/*$::'
}

# dl_docs_on: the project configures current-state docs (at least one aspect); without them nothing changes.
dl_docs_on() {
  [ -n "$(dl_docs_aspects)" ]
}

# dl_docs_aspect_path NAME: the path of an aspect (nothing, status 1, when the aspect is not configured).
dl_docs_aspect_path() {
  dl_docs_aspects | awk -F'\t' -v name="$1" '$1 == name {print $2; found = 1; exit} END {exit !found}'
}

# dl_docs_glob_match FILE PATTERN: FILE matches the shell glob PATTERN, where * also matches /.
dl_docs_glob_match() {
  # shellcheck disable=SC2053  # the pattern is a glob on purpose
  [[ "$1" == $2 ]]
}

# dl_docs_rule_patterns INDEX: the path globs of map rule INDEX, one per line.
dl_docs_rule_patterns() {
  local j
  for ((j = 0; j < $(cfg_len "docs.map.$1.paths"); j++)); do cfg "docs.map.$1.paths.$j"; done
}

# dl_docs_rule_docs INDEX: the aspect names of map rule INDEX, one per line.
dl_docs_rule_docs() {
  local j
  for ((j = 0; j < $(cfg_len "docs.map.$1.docs"); j++)); do cfg "docs.map.$1.docs.$j"; done
}

# dl_docs_rule_matches INDEX < files: the files (one per line on stdin) that map rule INDEX covers.
dl_docs_rule_matches() {
  local patterns file pattern
  patterns=$(dl_docs_rule_patterns "$1")
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    while IFS= read -r pattern; do
      [ -n "$pattern" ] && dl_docs_glob_match "$file" "$pattern" && { printf '%s\n' "$file"; break; }
    done <<<"$patterns"
  done
}

# dl_docs_prd: the PRD or spec files (docs.prd: a path or a list of paths), one per line.
dl_docs_prd() {
  local count i
  count=$(cfg_len docs.prd)
  if [ "$count" -gt 0 ]; then
    for ((i = 0; i < count; i++)); do cfg "docs.prd.$i"; done
  else
    case $(cfg docs.prd "") in "" | "["* | "{"*) ;; *) cfg docs.prd ;; esac
  fi
}
