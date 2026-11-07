#!/usr/bin/env bash
# Open the PR of a pushed branch from its notes file (first line the title, a leading "#" stripped, the
# rest the body), as the implementer identity in identity mode. Does nothing when the PR already exists.
# For a re-pushed branch (<branch>-vN, scripts/repush.sh) it then closes the open PRs of the versions it
# supersedes (<branch>, <branch>-v2, ...), each with a comment pointing to the new PR.
#
# Usage: open-pr.sh <branch>        Exit: 0 open (or already open), 2 usage, 5 notes file missing, 7 gh failed
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"

[ $# -eq 1 ] || dl_die "usage: open-pr.sh <branch>"
branch=$1
dl_load_config required
cd "$DL_ROOT" || exit 2

# as_implementer COMMAND...: run COMMAND with the implementer identity (unchanged outside identity mode).
as_implementer() { "$scripts_dir/as-role.sh" implementer "$@"; }

# close_superseded: close the open PRs of the earlier versions of a <root>-vN branch, pointing to this one.
close_superseded() {
  local root version n old number
  [[ "$branch" =~ ^(.+)-v([0-9]+)$ ]] || return 0
  root=${BASH_REMATCH[1]}
  version=$((10#${BASH_REMATCH[2]}))
  number=$(as_implementer gh pr view "$branch" --json number --jq .number 2>/dev/null)
  for ((n = 1; n < version; n++)); do
    old=$root
    [ "$n" -eq 1 ] || old=$root-v$n
    [ "$(as_implementer gh pr view "$old" --json state --jq .state 2>/dev/null)" = OPEN ] || continue
    if as_implementer gh pr close "$old" --comment "Superseded by #$number ($branch): the same work, re-pushed under a new name after a rebase." >/dev/null 2>&1; then
      echo "closed the PR of $old (superseded by $branch)"
    else
      dl_warn "could not close the PR of $old (superseded by $branch)"
    fi
  done
}

if as_implementer gh pr view "$branch" >/dev/null 2>&1; then
  echo "PR for $branch exists"
  close_superseded
  exit 0
fi
note=$(dl_note_file "$branch")
[ -f "$note" ] || { echo "missing notes file $note"; exit 5; }
title=$(head -n 1 "$note" | sed -E 's/^[[:space:]]*#+[[:space:]]*//')
[ -n "$title" ] || { echo "the first line of $note (the PR title) is empty"; exit 5; }
body_file=$(mktemp)
tail -n +2 "$note" | sed -e '/./,$!d' >"$body_file"
as_implementer gh pr create --head "$branch" --base "$DL_BASE" --title "$title" \
  --body-file "$body_file" >/dev/null
rc=$?
rm -f "$body_file"
[ "$rc" -eq 0 ] || { echo "could not create the PR for $branch"; exit 7; }
echo "opened PR for $branch: $title"
close_superseded
