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

# dl_docs_days_between FROM TO: whole days from the date FROM to the date TO (each YYYY-MM-DD, optionally
# followed by a time, which is ignored); nothing when either is not such a date. Portable: no date -d.
dl_docs_days_between() {
  local d
  for d in "$1" "$2"; do
    case $d in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;; *) return 0 ;; esac
  done
  awk -v from="${1:0:10}" -v to="${2:0:10}" '
    # civil: days since 0000-03-01 of a proleptic Gregorian date "YYYY-MM-DD".
    function civil(s,   y, m, d, era, yoe, doy) {
      y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
      if (m <= 2) y--
      era = int(y / 400); yoe = y - era * 400
      doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
      return era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    }
    BEGIN { print civil(to) - civil(from) }'
}

# dl_docs_planned_rows FILE...: the rows of the planned list, one "<file>\t<line>\t<ticket>\t<text>" each
# (ticket empty when the row has no #n). A row is a list item or a table body row outside code blocks
# (a rule like * * * is not one); in a file with a heading whose text starts with the word "Planned", only
# the rows of that section count.
dl_docs_planned_rows() {
  local file
  for file in "$@"; do
    awk -v file="$file" '
      # ticket: the first #n in s that is not part of a word, a path, an entity or an anchor like #2-scope.
      function ticket(s,   rest, after) {
        rest = " " s
        while (match(rest, "[^A-Za-z0-9_/&]#[0-9]+")) {
          after = substr(rest, RSTART + RLENGTH, 1)
          if (after !~ /[A-Za-z0-9_-]/) return substr(rest, RSTART + 2, RLENGTH - 2)
          rest = substr(rest, RSTART + RLENGTH)
        }
        return ""
      }
      /^[ \t]*(```|~~~)/ { fence = !fence; next }
      fence { next }
      /^#+[ \t]/ {
        match($0, /^#+/)
        if (section && RLENGTH <= level) section = 0
        title = tolower($0); sub(/^#+[ \t]+/, "", title)
        if (!section && title ~ /^planned([^a-z-]|$)/) { section = 1; level = RLENGTH; sections = 1 }
        next
      }
      /^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/ && /-/ && /\|/ {
        if (n > 0 && line[n] == NR - 1 && table[n]) n--
        next
      }
      /^[ \t]*([-*_][ \t]*)([-*_][ \t]*)([-*_][ \t]*)+$/ { next }
      /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/ || /^[ \t]*\|/ {
        text = $0; gsub(/^[ \t]+|[ \t]+$/, "", text)
        n++; line[n] = NR; table[n] = ($0 ~ /^[ \t]*\|/); row[n] = text; num[n] = ticket(text); in_section[n] = section
      }
      END {
        for (i = 1; i <= n; i++)
          if (!sections || in_section[i]) printf "%s\t%s\t%s\t%s\n", file, line[i], num[i], row[i]
      }' "$DL_ROOT/$file"
  done
}

# dl_docs_planned_branch N: a loop branch <type>/N-* exists for ticket N, local or on the remote.
dl_docs_planned_branch() {
  local name
  while IFS= read -r name; do
    name=${name#refs/heads/}
    name=${name#"refs/remotes/$DL_REMOTE/"}
    case $name in */"$1"-*) dl_loop_branch "$name" && return 0 ;; esac
  done < <(git -C "$DL_ROOT" for-each-ref --format='%(refname)' refs/heads "refs/remotes/$DL_REMOTE")
  return 1
}

# dl_docs_planned_notes PATH [MAX_DAYS]: one note per planned row (files under PATH) that needs care: no
# ticket number, a ticket closed or missing, or (with MAX_DAYS) open longer than that with no loop branch.
# The tickets come from one gh call; without gh access one note says the rows were not checked.
dl_docs_planned_notes() {
  local max=${2:-} rows file line number text issues state reason created days today
  rows=$(cd "$DL_ROOT" && find "$1" -type f ! -path '*/.git/*' 2>/dev/null | LC_ALL=C sort |
    while IFS= read -r file; do dl_docs_planned_rows "$file"; done)
  [ -n "$rows" ] || return 0
  # Fields are read split on \037: a tab is whitespace to read, so an empty field would vanish.
  while IFS=$'\037' read -r file line number text; do
    [ -z "$number" ] && echo "planned row at $file:$line has no ticket number: \"${text:0:60}\" (link its ticket, or keep the intent in the PRD)"
  done < <(printf '%s\n' "$rows" | tr '\t' '\037')
  printf '%s\n' "$rows" | cut -f3 | grep -q . || return 0
  issues=$(cd "$DL_ROOT" && gh issue list --state all --limit 10000 --json number,state,stateReason,createdAt \
    --jq '.[] | [(.number | tostring), .state, (.stateReason // ""), .createdAt] | @tsv' 2>/dev/null) || {
    echo "planned rows not checked: gh issue list failed (gh missing, not logged in or offline)"
    return 0
  }
  today=$(date -u +%Y-%m-%d)
  while IFS= read -r number; do
    IFS=$'\037' read -r _ state reason created <<<"$(printf '%s\n' "$issues" | awk -F'\t' -v n="$number" '$1 == n {print; exit}' |
      tr '\t' '\037')"
    case ${state:-} in
      "") echo "planned row #$number: no such ticket, link the row's ticket" ;;
      CLOSED)
        if [ "$reason" = NOT_PLANNED ]; then echo "planned row #$number: ticket closed as not planned, remove the row"
        else echo "planned row #$number: ticket closed, move it to Features"; fi
        ;;
      OPEN)
        [ -n "$max" ] || continue
        days=$(dl_docs_days_between "$created" "$today")
        [ -n "$days" ] && [ "$days" -gt "$max" ] && ! dl_docs_planned_branch "$number" &&
          echo "planned row #$number: open $days days with no branch (over planned_max_days $max): close it as not planned and remove the row; the PRD keeps the intent"
        ;;
    esac
  done < <(printf '%s\n' "$rows" | cut -f3 | grep . | awk '!seen[$0]++')
}

# dl_docs_journals: the append-only journals (docs.journals, default docs/DECISIONS.md), one per line.
dl_docs_journals() {
  local count i
  case $(cfg docs.journals "") in
    "") echo docs/DECISIONS.md ;;
    "["*)
      count=$(cfg_len docs.journals)
      for ((i = 0; i < count; i++)); do cfg "docs.journals.$i"; done
      ;;
    *) cfg docs.journals ;;
  esac
}

# dl_docs_line_count FILE: the number of lines of FILE, a last line without a newline included.
dl_docs_line_count() {
  awk 'END {print NR}' "$1"
}

# DL_DOCS_FENCE_AWK: awk functions for CommonMark code fences, put before an awk program. in_fence(line)
# is true for a fence line and for every line inside a fence: a fence opens with 3 or more ` or ~ after at
# most 3 spaces, and closes only on the same character, at least as many, and nothing but spaces after.
# shellcheck disable=SC2016  # awk code, not shell
DL_DOCS_FENCE_AWK='
function fence_run(line,   i, n, c) {
  i = 1
  while (i <= 4 && substr(line, i, 1) == " ") i++
  if (i > 4) return ""
  c = substr(line, i, 1)
  if (c != "`" && c != "~") return ""
  n = 0
  while (substr(line, i + n, 1) == c) n++
  if (n < 3) return ""
  fence_rest = substr(line, i + n)
  return c n
}
function in_fence(line,   run) {
  run = fence_run(line)
  if (open_fence == "") { open_fence = run; return run != "" }
  if (run != "" && substr(run, 1, 1) == substr(open_fence, 1, 1) && substr(run, 2) + 0 >= substr(open_fence, 2) + 0 &&
      fence_rest ~ /^[ \t\r]*$/) open_fence = ""
  return 1
}
'

# dl_docs_links < markdown: the link targets of Markdown text, outside fenced and inline code.
dl_docs_links() {
  LC_ALL=C awk "$DL_DOCS_FENCE_AWK"'
    in_fence($0) { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      while (match(line, /\]\([^)]*\)/)) {
        print substr(line, RSTART + 2, RLENGTH - 3)
        line = substr(line, RSTART + RLENGTH)
      }
    }'
}

# dl_docs_resolve_link DIR TARGET: the repository path TARGET points to from DIR, with . and .. resolved;
# status 1 when it goes above the repository root.
dl_docs_resolve_link() {
  local part parts=() out=() IFS=/
  read -r -a parts <<<"${1:+$1/}$2"
  for part in "${parts[@]}"; do
    case "$part" in
      "" | .) ;;
      ..)
        [ ${#out[@]} -gt 0 ] || return 1
        unset "out[$((${#out[@]} - 1))]"
        ;;
      *) out+=("$part") ;;
    esac
  done
  [ ${#out[@]} -eq 0 ] || printf '%s' "${out[*]}"
  echo
}

# dl_docs_link_target LINK: the path part of a link: <path with spaces> up to the ">", else up to the first
# space (a title follows it); without #anchor and ?query, %20 decoded to a space.
dl_docs_link_target() {
  local target
  case "$1" in
    "<"*) target=${1#<} && target=${target%%>*} ;;
    *) target=${1%%[[:space:]]*} ;;
  esac
  target=${target%%#*}
  target=${target%%\?*}
  printf '%s\n' "${target//%20/ }"
}

# dl_docs_relative_link LINK: LINK is a relative path link the link rule checks (not an anchor, an absolute
# path or a URL with a scheme); prints its target.
dl_docs_relative_link() {
  local target
  case "$1" in "#"* | /* | "") return 1 ;; esac
  target=$(dl_docs_link_target "$1")
  [[ "$target" =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]] && return 1
  [ -n "$target" ] || return 1
  printf '%s\n' "$target"
}
