#!/usr/bin/env bash
# Stop hook: Claude may not stop while the project's fast checks are red or work is uncommitted.
# Only the fast checks run here (seconds, e.g. format and lint): the full suite is the batch gate's job
# (gate-train.sh through heavy.sh), and running it on every stop would delay every reply and load the machine.
# Exit 2 blocks the stop and feeds stderr back to Claude, which keeps working. After stop_gate.max_blocks
# consecutive blocks (default 5) it lets Claude stop, so an unfixable state cannot loop forever.
# Config (.dev-loop.json): "fast_check" (command), "stop_gate": {"require_clean_tree": true, "max_blocks": 5}.
# A no-op outside a git repository or without .dev-loop.json.
set -u
hooks_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/lib/common.sh
. "$hooks_dir/../scripts/lib/common.sh"

cat >/dev/null
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
repo=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
DL_CONFIG=${DEV_LOOP_CONFIG:-$repo/.dev-loop.json}
[ -f "$DL_CONFIG" ] || exit 0
cd "$repo" || exit 0

counter_file="$(git rev-parse --path-format=absolute --git-dir)/dev-loop-stop-count"
max_blocks=$(cfg stop_gate.max_blocks 5)
fast_check=$(cfg fast_check "")
require_clean=$(cfg stop_gate.require_clean_tree true)

reason=""
if [ -n "$fast_check" ] && ! output=$(bash -c "$fast_check" 2>&1); then
  reason="the fast check ($fast_check) is failing. Fix it before stopping. Last output:
$(printf '%s\n' "$output" | tail -n 40)"
elif [ "$require_clean" != false ] && [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  reason="there are uncommitted changes. Commit them (Conventional Commits, reference the issue) or discard them before stopping."
fi

if [ -z "$reason" ]; then
  rm -f "$counter_file"
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
