#!/usr/bin/env bash
# SessionStart hook: put the durable schedule's overdue, due and upcoming items (scripts/schedule.sh check)
# into the session's context, so the orchestrator does the due work first and re-creates in-session timers
# for the upcoming items. Silent (no output, exit 0) outside a git repository, without .dev-loop.json,
# without "schedule" in it, and when nothing is overdue, due or upcoming. Never blocks a session: exit 0.
set -u
hooks_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/lib/common.sh
. "$hooks_dir/../scripts/lib/common.sh"
# shellcheck source=../scripts/lib/schedule.sh
. "$hooks_dir/../scripts/lib/schedule.sh"

cat >/dev/null
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
dl_load_config
[ -n "$DL_ROOT" ] && [ -f "$DL_CONFIG" ] || exit 0
dl_schedule_on || exit 0
items=$("$hooks_dir/../scripts/schedule.sh" check 2>/dev/null) || exit 0
[ -n "$items" ] || exit 0
printf '%s\n' "$items"
echo "Do the OVERDUE and DUE items first (mark each done with ${hooks_dir%/hooks}/scripts/schedule.sh done <line>), then re-create an in-session timer for each UPCOMING item."
exit 0
