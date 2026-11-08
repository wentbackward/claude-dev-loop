#!/usr/bin/env bash
# Print the architecture evidence of this worktree: signals from the merge ledger, the component cards and
# git, for the architect agent ("architecture" in .dev-loop.json).
#
# Usage: arch-evidence.sh [--since <n> | --since <time>]
#   --since <n>     the last n merges of the ledger
#   --since <time>  the merges after a UTC time (2026-01-31T12:00:00Z), or from a date (2026-01-31) on
#   default         the merges since the architect last ran (paths.sh architect), else the last
#                   architecture.cadence merges (default 20)
#
# Deterministic and read-only: it reads the ledger (~/.dev-loop/<repo>/merged.jsonl), the cards and the
# edges of architecture.check in this worktree, and git; it writes nothing (a temporary directory aside).
# It prints the window, a summary table (one row per signal: its findings and its threshold), then one
# stable line per finding, by signal, each signal's lines sorted:
#   size budget A <lines>/<max>      A is over its line budget
#   size growth A +<n> lines         A grew by more than architecture.growth (500) lines in the window
#   scatter <branch> <n> components: ...
#                                    a merge touched more than architecture.scatter (3) components
#   co-change A B <t>/<u> merges     A and B changed together in at least architecture.co_change (75) % of
#                                    the u merges that changed either, and in at least
#                                    architecture.co_change_min (3) merges
#   hotspot <path> <n> merges        a file changed in more than architecture.hotspot (5) merges
#   cycle <n> components: ...        a cycle of more than architecture.cycle (3) components
#   misplaced A -> B (...)           a lower layer depends on a component of the top layer
#   fan-out A <n> components: ...    A depends on more than architecture.fan_out (5) components (composition
#                                    roots are exempt)
#   friction rounds <branch> <n> rounds
#                                    a branch took more than architecture.review_rounds (3) review rounds
#   friction reopened #<t> <n> merges: ...
#                                    a ticket merged more than once (one of its merges in the window)
#   runtime A -> B (...)             two run-time components (kind service, job or store) connected in code
# The files of a ledger line without them (from before these fields) come from its merge commit.
#
# Exit: 0 no signal over its threshold, 1 a signal over its threshold or an error in the cards or the
# check command, 2 usage or config error.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
dl_help "$0" "${1:-}"
# shellcheck source=lib/arch.sh
. "$scripts_dir/lib/arch.sh"

# usage: print the usage and exit 2.
usage() {
  dl_die "usage: arch-evidence.sh [--since <number of merges> | --since <UTC time or date>]"
}
since=""
if [ $# -gt 0 ]; then
  [ $# -eq 2 ] && [ "$1" = --since ] || usage
  since=$2
  case $since in
    "" | *[!0-9]*)
      [[ $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?)?$ ]] || usage
      ;;
  esac
fi
dl_load_config required
dl_arch_on || dl_die "no \"architecture.check\" in $DL_CONFIG: no evidence to gather"
dl_arch_budget >/dev/null || dl_die "architecture.budget: \"$(cfg architecture.budget "")\" is not a number"
bad=$(dl_arch_bad_thresholds)
[ -z "$bad" ] || dl_die "$(printf '%s\n' "$bad" | head -n 1)"
top=$(git rev-parse --show-toplevel) || dl_die "not inside a git worktree"
[ -d "$top/$(dl_arch_cards_dir)" ] || dl_die "no component cards: $(dl_arch_cards_dir) does not exist"
[ -n "$since" ] || since=$(dl_arch_default_since)

results=$(dl_arch_evidence "$top" "$since")
window=$(printf '%s\n' "$results" | awk -F'\t' '$1 == "W"')
merges=$(printf '%s\n' "$window" | cut -f2) first=$(printf '%s\n' "$window" | cut -f3)
last=$(printf '%s\n' "$window" | cut -f4) components=$(printf '%s\n' "$window" | cut -f5)
if [ "${merges:-0}" -gt 0 ]; then
  echo "arch-evidence: $merges merges from $first to $last, $components components"
else
  echo "arch-evidence: 0 merges, ${components:-0} components"
fi
findings=$(printf '%s\n' "$results" | dl_arch_tagged F)
printf '%-10s %-9s %s\n' signal findings threshold
while IFS='|' read -r signal rule; do
  printf '%-10s %-9s %s\n' "$signal" "$(printf '%s\n' "$findings" | awk -F'\t' -v s="$signal" '$1 == s' | grep -c .)" "$rule"
done <<EOF
size|over its line budget, or grown by more than $(dl_arch_threshold growth) lines
scatter|more than $(dl_arch_threshold scatter) components in one merge
co-change|together in $(dl_arch_threshold co_change)% of their merges, at least $(dl_arch_threshold co_change_min)
hotspot|a file changed in more than $(dl_arch_threshold hotspot) merges
cycle|more than $(dl_arch_threshold cycle) components
misplaced|a lower layer uses the top layer
fan-out|more than $(dl_arch_threshold fan_out) components (composition roots exempt)
friction|more than $(dl_arch_threshold review_rounds) review rounds, or a ticket merged twice
runtime|run-time components (service, job, store) connected in code
EOF
[ -z "$findings" ] || printf '%s\n' "$findings" | awk -F'\t' '{ print $1 " " $2 }'
errors=$(printf '%s\n' "$results" | dl_arch_tagged E)
[ -z "$errors" ] || printf '%s\n' "$errors" | sed 's/^/arch-evidence: error: /'
[ -z "$findings$errors" ]
