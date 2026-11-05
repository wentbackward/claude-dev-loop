#!/usr/bin/env bash
# Check that a range of commits keeps the current-state docs true ("docs" in .dev-loop.json).
#
# Usage: docs-check.sh <from> <to> [<notes file>]
#
# Deterministic: it reads only git and the config. It is red when
#   - a file changed in <from>..<to> matches a "docs.map" rule ({"paths": [globs], "docs": [aspects]}), none
#     of that rule's docs (an aspect file, or any file in an aspect folder) changed in the range, and the
#     notes file's "## Docs" section has no line "none: <reason>" (any case, a non-empty reason);
#   - a Markdown file changed in the range (and still there in <to>) has a relative link, [text](path) or
#     [text](path#anchor), that does not resolve in <to>. Links with a scheme (https:, mailto:), anchors
#     (#x), absolute paths (/x), links inside code, reference-style links and targets with nested
#     parentheses are not checked. <path with spaces> and %20 are understood.
# A <from> that is not an ancestor of <to> is replaced by their merge base (only the branch's own changes).
# Globs are shell globs matched against the whole repository path, where * also matches / ("src/*" covers
# src/a/b.py). The gate runs it for each branch of a train on that branch's own commits; an implementer can
# run it on a branch: docs-check.sh origin/main HEAD "$(scripts/paths.sh notes <branch>)".
#
# Exit: 0 green, 1 red (each problem on its own line), 2 usage or config error.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
# shellcheck source=lib/docs.sh
. "$scripts_dir/lib/docs.sh"

[ $# -ge 2 ] && [ $# -le 3 ] || dl_die "usage: docs-check.sh <from> <to> [<notes file>]"
from=$1 to=$2 notes=${3:-}
dl_load_config required
dl_docs_on || dl_die "no \"docs.aspects\" in $DL_CONFIG: nothing to check"
for ref in "$from" "$to"; do
  git rev-parse -q --verify "$ref^{commit}" >/dev/null || dl_die "$ref is not a commit"
done
# A from that is not an ancestor of to (the base moved on): compare from the merge base, so the base's own
# changes are not judged as the branch's.
if ! git merge-base --is-ancestor "$from" "$to"; then
  from=$(git merge-base "$from" "$to") || dl_die "$1 and $to have no common ancestor"
fi

problems=0
problem() {
  echo "docs-check: $*"
  problems=$((problems + 1))
}

# notes_none_reason FILE: the notes file's "## Docs" section has a line "none: <reason>" with a reason.
notes_none_reason() {
  [ -n "$1" ] && [ -f "$1" ] || return 1
  awk '
    /^#+[ \t]/ { heading = tolower($0); sub(/^#+[ \t]+/, "", heading); sub(/[ \t]+$/, "", heading)
                 in_docs = ($0 ~ /^##[ \t]/ && heading == "docs"); next }
    in_docs {
      line = $0
      sub(/^[ \t]*([-*+][ \t]+)?/, "", line)
      if (tolower(substr(line, 1, 5)) == "none:") {
        reason = substr(line, 6); gsub(/[ \t\r]/, "", reason)
        if (reason != "") { found = 1; exit }
      }
    }
    END { exit !found }' "$1"
}

# aspect_changed NAME < files: a changed file is the aspect's file or lies in its folder.
aspect_changed() {
  local path file
  path=$(dl_docs_aspect_path "$1")
  while IFS= read -r file; do
    [ "$file" = "$path" ] || [[ "$file" == "$path"/* ]] && return 0
  done
  return 1
}

# check_map CHANGED: every map rule a changed file matches has one of its docs changed too, or a reason.
check_map() {
  local changed=$1 count i name names matched docs exempt=""
  count=$(cfg_len docs.map)
  for ((i = 0; i < count; i++)); do
    while IFS= read -r name; do
      dl_docs_aspect_path "$name" >/dev/null ||
        dl_die "docs.map rule $((i + 1)) names \"$name\", which is not in docs.aspects"
    done < <(dl_docs_rule_docs "$i")
  done
  notes_none_reason "$notes" && exempt=yes
  for ((i = 0; i < count; i++)); do
    matched=$(printf '%s\n' "$changed" | dl_docs_rule_matches "$i")
    [ -n "$matched" ] || continue
    docs=$(dl_docs_rule_docs "$i")
    while IFS= read -r name; do
      printf '%s\n' "$changed" | aspect_changed "$name" && continue 2
    done <<<"$docs"
    [ -n "$exempt" ] && continue
    names=""
    while IFS= read -r name; do names+="${names:+, }$name ($(dl_docs_aspect_path "$name"))"; done <<<"$docs"
    problem "map rule $((i + 1)) ($(dl_docs_rule_patterns "$i" | paste -sd' ' -)) matches" \
      "$(printf '%s\n' "$matched" | paste -sd' ' -), but none of its docs changed: $names." \
      "Update them in this branch, or write \"none: <reason>\" under \"## Docs\" in the notes."
  done
}

# markdown_links FILE: the link targets of a Markdown file in <to>, outside fenced and inline code.
markdown_links() {
  git show "$to:$1" 2>/dev/null | awk '
    /^[ \t]*(```|~~~)/ { fenced = !fenced; next }
    fenced { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      while (match(line, /\]\([^)]*\)/)) {
        print substr(line, RSTART + 2, RLENGTH - 3)
        line = substr(line, RSTART + RLENGTH)
      }
    }'
}

# resolve_link DIR TARGET: the repository path TARGET points to from DIR, with . and .. resolved; status 1
# when it goes above the repository root.
resolve_link() {
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

# link_target LINK: the path part of a link: <path with spaces> up to the ">", else up to the first space
# (a title follows it); without #anchor and ?query, %20 decoded to a space.
link_target() {
  local target
  case "$1" in
    "<"*) target=${1#<} && target=${target%%>*} ;;
    *) target=${1%%[[:space:]]*} ;;
  esac
  target=${target%%#*}
  target=${target%%\?*}
  printf '%s\n' "${target//%20/ }"
}

# check_links CHANGED: every relative link in the changed Markdown files resolves in <to>.
check_links() {
  local file dir link target path
  while IFS= read -r file; do
    case "$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')" in *.md | *.markdown) ;; *) continue ;; esac
    git cat-file -e "$to:$file" 2>/dev/null || continue
    dir=$(dirname "$file")
    [ "$dir" = . ] && dir=""
    while IFS= read -r link; do
      target=$(link_target "$link")
      case "$link" in "#"* | /* | "") continue ;; esac
      [[ "$target" =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]] && continue
      [ -n "$target" ] || continue
      if ! path=$(resolve_link "$dir" "$target"); then
        problem "$file links to ($link), which goes above the repository root"
      elif [ -n "$path" ] && ! git cat-file -e "$to:$path" 2>/dev/null; then
        problem "$file links to ($link), but $path does not exist in $to"
      fi
    done < <(markdown_links "$file")
  done <<<"$1"
}

# NUL-separated names, so git does not quote non-ASCII or special paths (one name per line from here on).
changed=$(git diff --name-only --no-renames -z "$from" "$to" | tr '\0' '\n') || dl_die "cannot diff $from..$to"
check_map "$changed"
check_links "$changed"
if [ "$problems" -gt 0 ]; then
  echo "docs-check: $problems problem(s) in $from..$to"
  exit 1
fi
echo "docs-check: ok ($from..$to)"
