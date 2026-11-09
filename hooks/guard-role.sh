#!/usr/bin/env bash
# PreToolUse hook: git commands that a stop condition forbids are refused in every loop project (unless
# "guard": false); the implementer, test-engineer and code-reviewer may not touch the holdout scenario
# store; in identity mode, GitHub writes only through as-role.sh with the agent's own role, no merges or
# repository admin by agents, no reads of role credentials (logic in guard-role.py).
# A no-op without python3 or without .dev-loop.json; without "scenarios", "factory" or "identities" only
# Bash calls that may run git reach guard-role.py.
command -v python3 >/dev/null 2>&1 || exit 0
guard="$(dirname "${BASH_SOURCE[0]}")/guard-role.py"
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -z "${DEV_LOOP_CONFIG:-}" ]; then
  config="$CLAUDE_PROJECT_DIR/.dev-loop.json"
  [ -f "$config" ] || { cat >/dev/null; exit 0; }
  if ! grep -qsE '"(identities|scenarios|factory)"' "$config"; then
    event=$(cat)
    printf '%s' "$event" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"Bash"' || exit 0
    # Only a command that may run git needs the Python guard: "git" in any case in the event once line
    # continuations, quotes, backslashes, braces and commas are removed, a \u escape (which only the
    # decoded command shows), an ANSI-C string ($'...', which may spell git with escapes) or a glob
    # character (gi? may match git).
    if ! printf '%s' "$event" | grep -qF -e '\u' -e "\$'" -e '*' -e '?' -e '[' &&
      ! printf '%s' "$event" | sed 's/\\\\\\n//g' | tr -d "\\\\\"'{}," | grep -qi git; then
      exit 0
    fi
    exec python3 -I "$guard" --git-only <<<"$event"
  fi
fi
exec python3 -I "$guard"
