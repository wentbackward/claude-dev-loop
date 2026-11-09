#!/usr/bin/env bash
# The git merge driver for merge.union_files (gate-train.sh and merge-train.sh pass it per command only:
# -c merge.dl-union.driver=..., with an attributes file naming it; it is never written to any git config).
#
# Usage: union-merge.sh BASE OURS THEIRS   (git's %O %A %B; the result is written to OURS)
#
# A file that git merges without a conflict gets git's own result (git merge-file with the histogram diff,
# the one git's own merge in a rebase uses), exactly as without the option. merge-file takes
# --diff-algorithm from git 2.43 on; an older git refuses the option, and the driver then stops (exit 1)
# rather than diff another way. Only a merge with conflicts is resolved here, and only when the base is not
# empty (an add/add, both sides creating the file differently, stops) and in every conflict hunk both sides
# only added lines (the hunk's base part is empty): git merge-file in diff3 style, whose hunks are not
# refined the way merge=union's are (merge=union would fold lines two entries share into one copy), each
# conflict hunk kept whole, ours (in a rebase: the base being stacked on) first, then theirs (the branch). A
# conflict hunk where a side changed or deleted existing lines, a line that starts with 32 of one of git's
# marker characters (<, |, =, >) in any side, or any failure is a conflict (exit 1, OURS unchanged), so the
# train stops as it would without the option. Lines of CRLF files keep their CR; the result of a merge with
# conflicts always ends with a newline, even when a side's last line has none.
set -u
[ $# -eq 3 ] || { echo "usage: union-merge.sh BASE OURS THEIRS" >&2; exit 2; }
base=$1 ours=$2 theirs=$3
size=32

# marker_scan FILE...: print "clean" when no line of a FILE starts with $size of one of git's marker
# characters; prints nothing when one does (or when awk fails, which the caller sees in the status too).
marker_scan() {
  awk -v n="$size" 'BEGIN { split("< | = >", c, " "); for (i in c) { m = sprintf("%" n "s", ""); gsub(/ /, c[i], m); mk[m] = 1 } }
    substr($0, 1, n) in mk { found = 1; exit }
    END { if (!found) print "clean" }' "$@"
}

# keep_both: merge-file's diff3 output on stdin with each conflict kept as ours, then theirs; fails (exit 1)
# when a conflict hunk's base part is not empty (a side changed or deleted existing lines).
keep_both() {
  awk -v n="$size" '
    function run(ch,   m) { m = sprintf("%" n "s", ""); gsub(/ /, ch, m); return m }
    BEGIN { lt = run("<"); bar = run("|"); eq = run("="); gt = run(">"); part = ""; bad = 0 }
    { line = $0; sub(/\r$/, "", line); head = substr(line, 1, n); rest = substr(line, n + 1) }
    head == lt && (rest == "" || rest ~ /^ /) { part = "ours"; next }
    head == bar && (rest == "" || rest ~ /^ /) { part = "base"; next }
    head == eq && rest == "" { part = "theirs"; next }
    head == gt && (rest == "" || rest ~ /^ /) { part = ""; next }
    part == "base" { bad = 1; next }
    { print }
    END { exit bad }'
}

result="" raw=""
trap '[ -z "$result" ] || rm -f "$result"; [ -z "$raw" ] || rm -f "$raw"' EXIT
result=$(mktemp "${TMPDIR:-/tmp}/dev-loop-union-result.XXXXXX") || exit 1
raw=$(mktemp "${TMPDIR:-/tmp}/dev-loop-union-raw.XXXXXX") || exit 1
algo=--diff-algorithm=histogram
git merge-file -p "$algo" "$ours" "$base" "$theirs" >"$result"
rc=$?
[ "$rc" -le 127 ] || exit 1
[ "$rc" -ne 0 ] || { cat "$result" >"$ours"; exit 0; }
[ -s "$base" ] || exit 1
scan=$(marker_scan "$base" "$ours" "$theirs") && [ "$scan" = clean ] || exit 1
git merge-file -p "$algo" --diff3 --marker-size="$size" "$ours" "$base" "$theirs" >"$raw"
[ $? -le 127 ] || exit 1
keep_both <"$raw" >"$result" || exit 1
cat "$result" >"$ours"
