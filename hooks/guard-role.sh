#!/usr/bin/env bash
# PreToolUse hook: git commands that a stop condition forbids are refused in every loop project (unless
# "guard": false); the implementer, test-engineer and code-reviewer may not touch the holdout scenario
# store; in identity mode, GitHub writes only through as-role.sh with the agent's own role, no merges or
# repository admin by agents, no reads of role credentials (logic in guard-role.py).
# A no-op without python3 or without .dev-loop.json; without "scenarios", "factory" or "identities" only
# Bash calls reach guard-role.py.
command -v python3 >/dev/null 2>&1 || exit 0
guard="$(dirname "${BASH_SOURCE[0]}")/guard-role.py"
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -z "${DEV_LOOP_CONFIG:-}" ]; then
  config="$CLAUDE_PROJECT_DIR/.dev-loop.json"
  [ -f "$config" ] || { cat >/dev/null; exit 0; }
  if ! grep -qsE '"(identities|scenarios|factory)"' "$config"; then
    event=$(cat)
    printf '%s' "$event" | grep -qE '"tool_name"[[:space:]]*:[[:space:]]*"Bash"' || exit 0
    exec python3 -I "$guard" <<<"$event"
  fi
fi
exec python3 -I "$guard"
