#!/usr/bin/env bash
# Stop hook: Claude may not stop while the project's fast checks are red or work is uncommitted.
# Only the fast checks run here (seconds, e.g. format and lint): the full suite is the batch gate's job
# (gate-train.sh through heavy.sh), and running it on every stop would delay every reply and load the machine.
# Exit 2 blocks the stop and feeds stderr back to Claude, which keeps working. After stop_gate.max_blocks
# consecutive blocks (default 5) it lets Claude stop, so an unfixable state cannot loop forever.
# Uncommitted work is a modified tracked file or an untracked file newer than the session's start (the first
# timestamp in the session's transcript, else the hook's first run in the session); older untracked files
# (an owner's notes, another session's file) do not block and are noted once per session. Without a
# session id in the hook input every untracked file blocks.
# Config (.dev-loop.json): "fast_check" (command), "stop_gate": {"require_clean_tree": true, "max_blocks": 5}.
# A no-op outside a git repository or without .dev-loop.json.
set -u
hooks_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/lib/common.sh
. "$hooks_dir/../scripts/lib/common.sh"

# transcript_start TRANSCRIPT: the transcript's first UTC timestamp as touch -t wants it (CCYYMMDDhhmm.SS).
transcript_start() {
  local stamp digits
  [ -f "$1" ] || return 0
  stamp=$(grep -m 1 -o '"timestamp": *"[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\(\.[0-9]*\)\{0,1\}Z"' "$1" 2>/dev/null |
    head -n 1)
  digits=$(printf '%s' "${stamp%%.*}" | tr -cd '0-9')
  [ "${#digits}" -ge 14 ] && printf '%s.%s\n' "${digits:0:12}" "${digits:12:2}"
}

# session_marker DIR ID TRANSCRIPT: the path of a file whose mtime is the session's start, made on first use.
session_marker() {
  local marker="$1/${2//[^A-Za-z0-9_-]/_}" start
  if [ ! -e "$marker" ]; then
    mkdir -p "$1" || return 1
    find "$1" -type f -mtime +30 -exec rm -f {} + 2>/dev/null
    start=$(transcript_start "$3")
    if [ -z "$start" ] || ! TZ=UTC touch -t "$start" "$marker" 2>/dev/null; then
      touch "$marker" || return 1
    fi
  fi
  printf '%s\n' "$marker"
}

# sort_untracked MARKER: count the untracked files newer than MARKER (all of them without one) in
# new_untracked, and list the older ones, comma separated, in old_untracked.
sort_untracked() {
  local file
  new_untracked=0
  old_untracked=""
  while IFS= read -r -d '' file; do
    if [ -z "$1" ] || [ -n "$(find "./$file" -prune -newer "$1" 2>/dev/null)" ]; then
      new_untracked=$((new_untracked + 1))
    else
      old_untracked="${old_untracked:+$old_untracked, }$file"
    fi
  done < <(git ls-files -z --others --exclude-standard)
}

input=$(cat)
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
repo=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
DL_CONFIG=${DEV_LOOP_CONFIG:-$repo/.dev-loop.json}
[ -f "$DL_CONFIG" ] || exit 0
cd "$repo" || exit 0

git_dir=$(git rev-parse --path-format=absolute --git-dir)
counter_file="$git_dir/dev-loop-stop-count"
max_blocks=$(cfg stop_gate.max_blocks 5)
fast_check=$(cfg fast_check "")
require_clean=$(cfg stop_gate.require_clean_tree true)
session_id=$(printf '%s' "$input" | json_get session_id)
marker=""
old_untracked=""
if [ -n "$session_id" ]; then
  marker=$(session_marker "$git_dir/dev-loop-sessions" "$session_id" \
    "$(printf '%s' "$input" | json_get transcript_path)") || marker=""
fi

reason=""
if [ -n "$fast_check" ] && ! output=$(bash -c "$fast_check" 2>&1); then
  reason="the fast check ($fast_check) is failing. Fix it before stopping. Last output:
$(printf '%s\n' "$output" | tail -n 40)"
elif [ "$require_clean" != false ]; then
  sort_untracked "$marker"
  if [ -n "$(git status --porcelain --untracked-files=no)" ] || [ "$new_untracked" -gt 0 ]; then
    reason="there are uncommitted changes. Commit them (Conventional Commits, reference the issue) or discard them before stopping."
  fi
fi

if [ -z "$reason" ]; then
  rm -f "$counter_file"
  if [ -n "$marker" ] && [ -n "$old_untracked" ] && [ ! -e "$marker.noted" ]; then
    touch "$marker.noted"
    printf '{"systemMessage": %s}\n' \
      "$(dl_json_string "stop-gate: untracked files older than this session do not block the stop: $old_untracked")"
  fi
  exit 0
fi

count=$(cat "$counter_file" 2>/dev/null || echo 0)
[[ "$count" =~ ^[0-9]+$ ]] || count=0
count=$((count + 1))
if ((count > max_blocks)); then
  rm -f "$counter_file"
  echo "stop-gate: still failing after $max_blocks attempts; allowing the stop. Open an issue that describes the blocker." >&2
  exit 0
fi
echo "$count" >"$counter_file"
echo "stop-gate ($count/$max_blocks): $reason" >&2
exit 2
