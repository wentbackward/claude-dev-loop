#!/usr/bin/env bash
# Archive the journals and finished specs of the current-state docs ("docs" in .dev-loop.json).
#
# Usage: docs-archive.sh journal [<file>] [--keep <lines>] [--apply]
#        docs-archive.sh spec <file> [--no-pointer] [--force] [--apply]
#
# A dry run by default: it prints exactly what would move and writes nothing; --apply writes.
#   journal  For each journal (<file>, else every docs.journals entry, default docs/DECISIONS.md) over its
#            budget (--keep, else docs.max_lines, default 1000): move the oldest whole entries ("## "
#            headings outside code fences), verbatim, to docs/archive/<NAME>-<first date>--<last date>.md
#            until the live file is within budget. The preamble (text before the first entry) and a
#            "## Standing decisions" section stay in place; only the run of entries before that section (or
#            after it, when it comes first) moves. An archive file is never edited: a taken name gets -2,
#            -3, ... It verifies that the live file with the archive put back equals the original, byte for
#            byte, before writing anything.
#   spec     Move a finished spec to docs/archive/specs/ verbatim and leave a one-line pointer in its place
#            (none with --no-pointer). It refuses a file that a docs aspect or docs.prd still names (unless
#            --force) and an existing destination, and reports the links in other Markdown files to it.
# Both refuse moved text with a relative link that would no longer resolve from the archive (docs-check's
# link rule), naming the link. Paths are relative to the top of the current worktree.
#
# Exit: 0 done (or nothing to do), 1 refused or verification failed (nothing written), 2 usage or config.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
# shellcheck source=lib/docs.sh
. "$scripts_dir/lib/docs.sh"

usage="usage: docs-archive.sh journal [<file>] [--keep <lines>] [--apply] | spec <file> [--no-pointer] [--force] [--apply]"
archive_dir=docs/archive
tmp=""
trap '[ -z "$tmp" ] || rm -rf "$tmp"' EXIT

# say MESSAGE...: one line of output.
say() {
  echo "docs-archive: $*"
}

# refuse MESSAGE...: report why nothing is written and exit 1.
refuse() {
  say "$*; nothing written" >&2
  exit 1
}

# repo_path FILE: FILE (relative to the working directory, or absolute) as a path from the worktree top.
repo_path() {
  local dir
  dir=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  dir=${dir#"$top"}
  dir=${dir#/}
  printf '%s\n' "${dir:+$dir/}$(basename "$1")"
}

# relative_path FROM_DIR TO_PATH: the relative link from the folder FROM_DIR to the file TO_PATH.
relative_path() {
  local from=$1 to=$2 up=""
  while [ -n "$from" ] && [[ "$to" != "$from"/* ]]; do
    case $from in */*) from=${from%/*} ;; *) from="" ;; esac
    up+="../"
  done
  printf '%s\n' "$up${to#"${from:+$from/}"}"
}

# check_moved_links TEXT_FILE DEST_DIR: refuse when a relative link in TEXT_FILE would not resolve from
# DEST_DIR (each such link is named).
check_moved_links() {
  local link target path bad=0
  while IFS= read -r link; do
    target=$(dl_docs_relative_link "$link") || continue
    if ! path=$(dl_docs_resolve_link "$2" "$target") || { [ -n "$path" ] && [ ! -e "$top/$path" ]; }; then
      say "the link ($link) would not resolve from $2" >&2
      bad=1
    fi
  done < <(dl_docs_links <"$1")
  [ "$bad" -eq 0 ] || refuse "rewrite those links (a path that resolves from both places, or a URL)"
}

# corrupt_for_test FILE: the test seam for the dangerous direction: with DEV_LOOP_ARCHIVE_TEST_CORRUPT set,
# change FILE so that the verification must fail.
corrupt_for_test() {
  [ -z "${DEV_LOOP_ARCHIVE_TEST_CORRUPT:-}" ] || printf 'x' >>"$1"
}

# journal_sections FILE: one "<line><TAB><kind><TAB><heading>" per "## " heading outside code fences, kind
# "standing" for the standing decisions section, else "entry"; a last line "<total lines><TAB>end".
journal_sections() {
  awk '
    /^[ \t]*(```|~~~)/ { fenced = !fenced; next }
    fenced { next }
    /^## / {
      heading = $0; sub(/\r$/, "", heading)
      title = tolower(heading); sub(/[ \t]+$/, "", title)
      print NR "\t" (title == "## standing decisions" ? "standing" : "entry") "\t" heading
    }
    END { print NR "\tend" }' "$1"
}

# entry_date HEADING: the date an entry heading starts with ("## 2026-11-05 — ..."), else nothing.
entry_date() {
  [[ "$1" =~ ^##\ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

# write_new SOURCE DEST: copy SOURCE to the new file DEST (under the worktree top), creating its folder;
# fails, writing nothing, when DEST exists.
write_new() {
  mkdir -p "$top/$(dirname "$2")" || return 1
  (set -C && cat "$1" >"$top/$2")
}

# free_name STEM: the first of STEM.md, STEM-2.md, ... that does not exist.
free_name() {
  local n=2 name="$1.md"
  while [ -e "$top/$name" ]; do
    name="$1-$n.md"
    n=$((n + 1))
  done
  printf '%s\n' "$name"
}

# compact_journal FILE: move the oldest entries of the journal FILE to a new archive file until it is
# within budget (a dry run without --apply).
compact_journal() {
  local file=$1 total lines=() kinds=() heads=() line kind heading i first="" last="" end moved date stem
  local from_date="" to_date="" archive
  [ -f "$top/$file" ] || refuse "$file does not exist"
  while IFS=$'\t' read -r line kind heading; do
    [ "$kind" = end ] && { total=$line; continue; }
    lines+=("$line") && kinds+=("$kind") && heads+=("$heading")
  done < <(journal_sections "$top/$file")
  if [ "$total" -le "$keep" ]; then
    say "$file has $total lines, within $keep: nothing to move"
    return 0
  fi
  # The movable run: the entries from the first one up to the standing decisions (or the end).
  for ((i = 0; i < ${#lines[@]}; i++)); do
    if [ -z "$first" ]; then [ "${kinds[i]}" = entry ] && first=$i; continue; fi
    [ "${kinds[i]}" = entry ] || break
  done
  [ -n "$first" ] || { say "$file has $total lines, over $keep, but no entry to move"; return 0; }
  for ((last = first; last < i; last++)); do
    end=$(( last + 1 < ${#lines[@]} ? lines[last + 1] - 1 : total ))
    moved=$((end - lines[first] + 1))
    [ $((total - moved)) -le "$keep" ] && break
  done
  [ "$last" -lt "$i" ] || last=$((i - 1))
  end=$(( last + 1 < ${#lines[@]} ? lines[last + 1] - 1 : total ))
  moved=$((end - lines[first] + 1))
  for ((i = first; i <= last; i++)); do
    date=$(entry_date "${heads[i]}") || continue
    [ -n "$from_date" ] || from_date=$date
    to_date=$date
  done
  stem=$(basename "$file") && stem=${stem%.*}
  archive=$(free_name "$archive_dir/$stem-${from_date:-undated}--${to_date:-undated}")
  [ -z "$tmp" ] || rm -rf "$tmp"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/docs-archive.XXXXXX") || dl_die "cannot make a temporary folder"
  head -n "$((lines[first] - 1))" "$top/$file" >"$tmp/live"
  tail -n "+${lines[first]}" "$top/$file" | head -n "$moved" >"$tmp/archive"
  tail -n "+$((end + 1))" "$top/$file" >>"$tmp/live"
  check_moved_links "$tmp/archive" "$archive_dir"
  say "$file has $total lines, over $keep: $([ -n "$apply" ] && echo moving || echo would move)" \
    "$((last - first + 1)) entr$([ "$last" -eq "$first" ] && echo y || echo ies) (lines ${lines[first]}-$end) to $archive, keeping $((total - moved)) lines"
  [ "$((total - moved))" -le "$keep" ] || say "$file stays over $keep: only the standing decisions and the preamble are left"
  for ((i = first; i <= last; i++)); do say "  ${heads[i]}"; done
  [ -n "$apply" ] || return 0
  corrupt_for_test "$tmp/archive"
  verify_journal "$top/$file" "$tmp" "$((lines[first] - 1))" "$moved" "$((total - moved))" ||
    refuse "verification failed: $file without the moved entries plus $archive is not the original"
  write_new "$tmp/archive" "$archive" || refuse "cannot write $archive"
  cat "$tmp/live" >"$top/$file" || dl_die "cannot write $file; its moved entries are in $archive"
  say "wrote $archive and $file"
}

# verify_journal ORIGINAL TMP PREFIX MOVED KEPT: the live file (TMP/live) with the archive (TMP/archive) put
# back after its first PREFIX lines equals ORIGINAL, byte for byte, with MOVED and KEPT lines.
verify_journal() {
  [ "$(dl_docs_line_count "$2/archive")" -eq "$4" ] && [ "$(dl_docs_line_count "$2/live")" -eq "$5" ] &&
    { head -n "$3" "$2/live"; cat "$2/archive"; tail -n "+$(($3 + 1))" "$2/live"; } | cmp -s - "$1"
}

# named_by_config FILE: the config key that still names FILE (a docs aspect or docs.prd), else status 1.
named_by_config() {
  local name path
  while IFS=$'\t' read -r name path; do
    [ "$1" = "$path" ] || [[ "$1" == "$path"/* ]] && { echo "docs aspect $name ($path)"; return 0; }
  done < <(dl_docs_aspects)
  while IFS= read -r path; do
    [ -n "$path" ] && [ "$1" = "$path" ] && { echo "docs.prd"; return 0; }
  done < <(dl_docs_prd)
  return 1
}

# report_inbound_links FILE DEST: name each link in another tracked Markdown file that points to FILE.
report_inbound_links() {
  local doc dir link target path
  while IFS= read -r doc; do
    [ "$doc" != "$1" ] && [ -f "$top/$doc" ] || continue
    dir=$(dirname "$doc") && [ "$dir" = . ] && dir=""
    while IFS= read -r link; do
      target=$(dl_docs_relative_link "$link") || continue
      path=$(dl_docs_resolve_link "$dir" "$target") || continue
      [ "$path" = "$1" ] &&
        say "$doc links to ($link), which moves to $2$([ -n "$pointer" ] && echo " (the pointer keeps it working)")"
    done < <(dl_docs_links <"$top/$doc")
  done < <(git -C "$top" ls-files -- '*.md' '*.markdown')
}

# archive_spec FILE: move the spec FILE to docs/archive/specs/ and leave a pointer (a dry run without --apply).
archive_spec() {
  local file=$1 dest named
  [ -f "$top/$file" ] || refuse "$file does not exist"
  if named=$(named_by_config "$file") && [ -z "$force" ]; then
    refuse "$file is still named by $named (archive it with --force, or change the config first)"
  fi
  dest="$archive_dir/specs/$(basename "$file")"
  [ ! -e "$top/$dest" ] || refuse "$dest exists"
  check_moved_links "$top/$file" "$archive_dir/specs"
  say "$([ -n "$apply" ] && echo moving || echo would move) $file to $dest" \
    "$([ -n "$pointer" ] && echo "with a pointer left in its place" || echo "with no pointer")"
  report_inbound_links "$file" "$dest"
  [ -n "$apply" ] || return 0
  write_new "$top/$file" "$dest" || refuse "cannot write $dest"
  corrupt_for_test "$top/$dest"
  if ! cmp -s "$top/$file" "$top/$dest"; then
    rm -f "$top/$dest"
    rmdir "$top/$archive_dir/specs" "$top/$archive_dir" 2>/dev/null
    refuse "verification failed: $dest is not a copy of $file"
  fi
  if [ -n "$pointer" ]; then
    printf 'Archived: [%s](%s)\n' "$(basename "$file")" "$(relative_path "$(dirname "$file")" "$dest")" >"$top/$file"
  else
    rm -f "$top/$file"
  fi
  say "wrote $dest$([ -n "$pointer" ] && echo " and the pointer $file")"
}

[ $# -ge 1 ] || dl_die "$usage"
command=$1
shift
apply="" force="" pointer=yes keep="" target=""
while [ $# -gt 0 ]; do
  case $1 in
    --apply) apply=yes ;;
    --force) force=yes ;;
    --no-pointer) pointer="" ;;
    --keep)
      [ $# -ge 2 ] || dl_die "$usage"
      keep=$2
      shift
      ;;
    -*) dl_die "unknown option $1; $usage" ;;
    *)
      [ -z "$target" ] || dl_die "$usage"
      target=$1
      ;;
  esac
  shift
done
case $keep in "" | *[!0-9]*) [ -z "$keep" ] || dl_die "--keep \"$keep\" is not a number" ;; esac
dl_load_config required
dl_docs_on || dl_die "no \"docs.aspects\" in $DL_CONFIG: nothing to archive"
top=$(git rev-parse --show-toplevel 2>/dev/null) || dl_die "not inside a git repository"
top=$(cd "$top" && pwd -P)

case $command in
  journal)
    if [ -z "$keep" ]; then
      keep=$(cfg docs.max_lines 1000)
      case $keep in "" | *[!0-9]* | 0) dl_die "docs.max_lines: \"$keep\" is not a positive number" ;; esac
    fi
    if [ -n "$target" ]; then
      target=$(repo_path "$target") || refuse "$target does not exist"
      compact_journal "$target"
    else
      while IFS= read -r target; do
        [ -n "$target" ] && compact_journal "$target"
      done < <(dl_docs_journals)
    fi
    ;;
  spec)
    [ -n "$target" ] || dl_die "$usage"
    target=$(repo_path "$target") || refuse "$target does not exist"
    archive_spec "$target"
    ;;
  *) dl_die "$usage" ;;
esac
[ -n "$apply" ] || say "dry run, nothing written (--apply to write)"
