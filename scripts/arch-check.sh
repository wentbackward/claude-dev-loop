#!/usr/bin/env bash
# Check a commit against the component cards and the baseline of known violations ("architecture" in
# .dev-loop.json), or write that baseline.
#
# Usage: arch-check.sh <ref>                 check <ref> against its baseline
#        arch-check.sh --baseline [<ref>]    write the violations of <ref> (default HEAD) to the baseline
#                                            file of this worktree, sorted, to be committed
#        arch-check.sh --loosened <from> <ref>
#                                            the violations of <ref> that its card header edits since
#                                            <from> hide: <ref>'s code judged by <from>'s cards reports
#                                            them, by its own cards not
#
# Deterministic: it reads the cards (architecture.cards, default docs/architecture/: each Markdown file
# whose first line is ---) at <ref>, runs architecture.check in a checkout of <ref> and maps each edge it
# prints ("<from> <to>", one per line: repository paths, or component names) to its components through
# the cards' "paths" globs (* also matches /, the longest matching glob wins). The checkout is this
# worktree when its HEAD is <ref> and no tracked file is modified, else a temporary worktree. Violations,
# one stable line each:
#   upward A -> B          A's layer is below B's (0 is the bottom)
#   undeclared A -> B      A's card lists depends_on without B (composition roots are never flagged)
#   cycle A B C            a group of components that depend on each other, its members sorted
#   budget A <lines>/<max> A's tracked text files have more lines than its max_lines (architecture.budget)
# A file in no component is a note, not a violation. With the baseline (architecture.baseline, default
# docs/architecture/baseline.txt, read at <ref>), each violation prints as new or known, and each baseline
# entry that no longer occurs as fixed; a budget entry stays known while the component does not grow.
#
# Exit: 0 every violation is in the baseline, 1 a new violation or an error at <ref> (a broken card, a
# failing architecture.check), 2 usage or config error. With --loosened: 0 nothing hidden (also when no
# card header changed: then the check command does not run), 1 hidden violations, 2 usage or config error.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
# shellcheck source=lib/arch.sh
. "$scripts_dir/lib/arch.sh"

# usage: print the usage and exit 2.
usage() { dl_die "usage: arch-check.sh <ref> | arch-check.sh --baseline [<ref>] | arch-check.sh --loosened <from> <ref>"; }
mode=check
if [ "${1:-}" = --baseline ]; then
  mode=baseline
  shift
  [ $# -le 1 ] || usage
  ref=${1:-HEAD}
elif [ "${1:-}" = --loosened ]; then
  mode=loosened
  [ $# -eq 3 ] || usage
  from=$2 ref=$3
else
  [ $# -eq 1 ] || usage
  ref=$1
fi
dl_load_config required
dl_arch_on || dl_die "no \"architecture.check\" in $DL_CONFIG: nothing to check"
dl_arch_budget >/dev/null || dl_die "architecture.budget: \"$(cfg architecture.budget "")\" is not a number"
commit=$(git rev-parse -q --verify "$ref^{commit}") || dl_die "$ref is not a commit"
if [ "$mode" = loosened ]; then
  from_commit=$(git rev-parse -q --verify "$from^{commit}") || dl_die "$from is not a commit"
  if ! dl_arch_headers_changed "$from_commit" "$commit"; then
    echo "arch-check: ok: no card header changed between $from and $ref"
    exit 0
  fi
fi
top=$(git rev-parse --show-toplevel) || dl_die "not inside a git worktree"
cards=$(dl_arch_cards_dir)
baseline=$(dl_arch_baseline_path)

# A checkout of the commit: this worktree when it is at the commit with no tracked file modified.
temporary=$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-arch-tree.XXXXXX") || dl_die "cannot create a temporary directory"
trap 'git worktree remove --force "$temporary/tree" >/dev/null 2>&1; rm -rf "$temporary"' EXIT
if [ "$(git rev-parse HEAD)" = "$commit" ] && [ -z "$(git status --porcelain --untracked-files=no)" ]; then
  checkout=$top
else
  git worktree add -q --detach "$temporary/tree" "$commit" >/dev/null 2>&1 || dl_die "cannot check out $ref"
  checkout=$temporary/tree
fi
[ -d "$checkout/$cards" ] || dl_die "no component cards: $cards does not exist at $ref"

if [ "$mode" = loosened ]; then
  dl_arch_extract_cards "$from_commit" "$temporary/from" || dl_die "cannot read the cards of $from"
  hidden=$(dl_arch_loosened "$checkout" "$temporary/from")
  if [ -z "$hidden" ]; then
    echo "arch-check: ok: the card header edits between $from and $ref hide no violation"
    exit 0
  fi
  printf '%s\n' "$hidden" | sed 's/^/arch-check: hidden by a card edit: /'
  echo "arch-check: $(printf '%s\n' "$hidden" | wc -l | tr -d ' ') violation(s) hidden by card header edits between $from and $ref"
  exit 1
fi

results=$(dl_arch_analyse "$checkout")
[ -n "$(printf '%s\n' "$results" | dl_arch_tagged S)$(printf '%s\n' "$results" | dl_arch_tagged E)" ] ||
  dl_die "no component cards in $cards at $ref (a card is a Markdown file whose first line is ---)"
errors=$(printf '%s\n' "$results" | dl_arch_tagged E)
violations=$(printf '%s\n' "$results" | dl_arch_tagged V | LC_ALL=C sort -u)
[ -z "$errors" ] || printf '%s\n' "$errors" | sed 's/^/arch-check: error: /'

if [ "$mode" = baseline ]; then
  if [ -n "$errors" ]; then
    echo "arch-check: the baseline is not written while $ref has errors"
    exit 1
  fi
  mkdir -p "$(dirname "$top/$baseline")" || dl_die "cannot create the folder of $baseline"
  if [ -n "$violations" ]; then printf '%s\n' "$violations"; fi >"$top/$baseline" || dl_die "cannot write $baseline"
  echo "arch-check: wrote $(grep -c . "$top/$baseline") entries to $baseline"
  exit 0
fi

compared=$(dl_arch_compare <(cat "$checkout/$baseline" 2>/dev/null) <(printf '%s\n' "$violations" | sed '/^$/d'))
new=$(printf '%s\n' "$compared" | dl_arch_tagged new)
known=$(printf '%s\n' "$compared" | dl_arch_tagged known)
fixed=$(printf '%s\n' "$compared" | dl_arch_tagged fixed)
[ -z "$new" ] || printf '%s\n' "$new" | sed 's/^/arch-check: new /'
[ -z "$known" ] || printf '%s\n' "$known" | sed 's/^/arch-check: known /'
[ -z "$fixed" ] || printf '%s\n' "$fixed" | sed 's/^/arch-check: fixed /; s/$/ (remove it from the baseline)/'
printf '%s\n' "$results" | dl_arch_tagged N | LC_ALL=C sort -u | sed 's/^/arch-check: note: no component: /'
# count LINES: the number of lines of LINES (0 when empty).
count() { if [ -n "$1" ]; then printf '%s\n' "$1" | wc -l | tr -d ' '; else echo 0; fi; }
if [ -n "$errors" ] || [ -n "$new" ]; then
  echo "arch-check: $(count "$new") new violation(s), $(count "$errors") error(s) at $ref"
  exit 1
fi
echo "arch-check: ok ($ref): $(count "$known") known, $(count "$fixed") fixed"
