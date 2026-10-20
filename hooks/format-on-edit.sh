#!/usr/bin/env bash
# PostToolUse hook: run the project's "format" command on the file Claude just edited.
# Config (.dev-loop.json of the file's repository): "format" (a command; "{file}" is replaced by the quoted
# path, else the path is appended) and optional "format_extensions" (e.g. [".py", ".ts"]).
# Never blocks: what the formatter cannot fix is caught by the Stop gate and the batch gate.
# A no-op when the repository has no .dev-loop.json or no "format".
set -u
hooks_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/lib/common.sh
. "$hooks_dir/../scripts/lib/common.sh"

input=$(cat)
file_path=$(printf '%s' "$input" | json_get tool_input.file_path)
[ -n "$file_path" ] && [ -f "$file_path" ] || exit 0

# The file's own repository (an implementer's worktree) decides; it carries the same committed config.
repo=$(git -C "$(dirname "$file_path")" rev-parse --show-toplevel 2>/dev/null) || exit 0
DL_CONFIG=${DEV_LOOP_CONFIG:-$repo/.dev-loop.json}
[ -f "$DL_CONFIG" ] || exit 0
command=$(cfg format "")
[ -n "$command" ] || exit 0

count=$(cfg_len format_extensions)
if [ "$count" -gt 0 ]; then
  matched=""
  for ((i = 0; i < count; i++)); do
    extension=$(cfg "format_extensions.$i" "")
    [[ -n "$extension" && "$file_path" == *"$extension" ]] && matched=yes
  done
  [ -n "$matched" ] || exit 0
fi

quoted=$(printf '%q' "$file_path")
if [[ "$command" == *"{file}"* ]]; then
  command=${command//\{file\}/$quoted}
else
  command="$command $quoted"
fi
(cd "$repo" && bash -c "$command") >/dev/null 2>&1
exit 0
