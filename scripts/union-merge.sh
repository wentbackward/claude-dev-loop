#!/usr/bin/env bash
# The git merge driver for merge.union_files (gate-train.sh and merge-train.sh pass it per command only:
# -c merge.dl-union.driver=..., with an attributes file naming it; it is never written to any git config).
#
# Usage: union-merge.sh BASE OURS THEIRS   (git's %O %A %B; the result is written to OURS)
#
# Keeps both sides of every conflicting hunk whole, ours (in a rebase: the base being stacked on) first, then
# theirs (the branch), and never merges lines inside a hunk: git merge-file in diff3 style, whose hunks are
# not refined the way merge=union's are, with the base part of each hunk dropped. Then it checks that no
# added line was lost: every line must appear in the result at least ours + theirs - base times. A file with
# a line that looks like a long conflict marker, a failed merge-file, or a failed check is a conflict (exit 1),
# so the train stops as it would without the option.
set -u
[ $# -eq 3 ] || { echo "usage: union-merge.sh BASE OURS THEIRS" >&2; exit 2; }
base=$1 ours=$2 theirs=$3
size=32

# marker_like FILE...: true when a line of a FILE starts with $size of one of git's marker characters.
marker_like() {
  awk -v n="$size" 'BEGIN { split("< | = >", c, " "); for (i in c) { m = sprintf("%" n "s", ""); gsub(/ /, c[i], m); mk[m] = 1 } }
    substr($0, 1, n) in mk { found = 1; exit }
    END { exit !found }' "$@"
}

# keep_both: merge-file's diff3 output on stdin with the base part of each conflict dropped (ours, then theirs).
keep_both() {
  awk -v n="$size" '
    function run(ch,   m) { m = sprintf("%" n "s", ""); gsub(/ /, ch, m); return m }
    BEGIN { lt = run("<"); bar = run("|"); eq = run("="); gt = run(">"); part = "" }
    { head = substr($0, 1, n); rest = substr($0, n + 1) }
    head == lt && (rest == "" || rest ~ /^ /) { part = "ours"; next }
    head == bar && (rest == "" || rest ~ /^ /) { part = "base"; next }
    head == eq && rest == "" { part = "theirs"; next }
    head == gt && (rest == "" || rest ~ /^ /) { part = ""; next }
    part != "base" { print }'
}

# lines_kept RESULT: true when every line appears in RESULT at least ours + theirs - base times.
lines_kept() {
  awk 'FILENAME == ARGV[1] { b[$0]++; next } FILENAME == ARGV[2] { o[$0]++; next }
    FILENAME == ARGV[3] { t[$0]++; next } { r[$0]++ }
    END { for (l in o) if (r[l] + b[l] < o[l] + t[l]) exit 1
          for (l in t) if (r[l] + b[l] < o[l] + t[l]) exit 1 }' "$base" "$ours" "$theirs" "$1"
}

marker_like "$base" "$ours" "$theirs" && exit 1
result=$(mktemp "${TMPDIR:-/tmp}/dev-loop-union-result.XXXXXX") || exit 1
trap 'rm -f "$result" "$result.raw"' EXIT
git merge-file -p --diff3 --marker-size="$size" "$ours" "$base" "$theirs" >"$result.raw"
rc=$?
[ "$rc" -le 127 ] || exit 1
keep_both <"$result.raw" >"$result"
lines_kept "$result" || exit 1
cat "$result" >"$ours"
