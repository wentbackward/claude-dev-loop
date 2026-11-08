#!/usr/bin/env bash
# Record one orchestrator step in the event log (~/.dev-loop/<repo>/events.jsonl), for status.sh.
#
# Usage: event.sh <event> [key=value ...]
#   e.g. event.sh agent-started ticket=12 branch=feat/12-x
#        event.sh waiting detail="gate train feat/12-x feat/13-y"
#        event.sh agent-reported ticket=12
#        event.sh idle detail="nothing in flight"
#
# Writes one JSON line {"t": "<UTC>", "who": "orchestrator", "event": "<event>", "<key>": "<value>", ...}; every
# value is a string; keys are lowercase letters, digits and _ (t, who and event cannot be set). An event
# whose name starts with "waiting" makes the status verdict "waiting on <detail, else the rest of the
# name>" until a gate result or a merge of a branch it names comes after it; agent-started (and
# watchdog-resumed) keeps the verdict working until agent-reported or a merge of that ticket; idle ends
# every agent in flight and the loop worktrees unchanged since. Exit 0 always once it has an event (a
# write error is ignored), 2 without one.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"

[ -n "${1:-}" ] || dl_die "usage: event.sh <event> [key=value ...]"
dl_load_config
dl_event orchestrator "$@"
exit 0
