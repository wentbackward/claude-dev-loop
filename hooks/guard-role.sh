#!/usr/bin/env bash
# PreToolUse hook: in identity mode, GitHub writes only through as-role.sh with the agent's own role,
# no merges or repository admin by agents, no reads of role credentials (logic in guard-role.py).
# A no-op without python3 or without "identities" in .dev-loop.json.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -z "${DEV_LOOP_CONFIG:-}" ] &&
  ! grep -qs '"identities"' "$CLAUDE_PROJECT_DIR/.dev-loop.json"; then
  cat >/dev/null
  exit 0
fi
command -v python3 >/dev/null 2>&1 || exit 0
exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/guard-role.py"
