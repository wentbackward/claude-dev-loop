#!/usr/bin/env bash
# Publish a rebased branch under a new name instead of force-pushing it: <branch>-v2, then -v3, ...
#
# Usage: repush.sh [<branch>]     (default: the branch checked out in the current directory)
#
# Picks the next free version (no branch of that name on the remote or locally, and no notes file of that
# name), creates it at the branch's head, moves the worktree that has the branch checked out onto it, and
# pushes it with a plain `git push -u` (never forced; as the implementer identity in identity mode). The
# notes file is copied to the new name, with a line recording what it supersedes and at which tips (the
# local head and the remote branch's head): "Supersedes `<branch>` at <sha> [<sha>] (...)", placed before
# the notes' closing "Generated with" footer when they end with one. cleanup.sh deletes the old branch
# only while its tips are still the recorded ones. The old branch is never
# deleted or moved, locally or on the remote: cleanup.sh removes it once a later version has merged, and
# open-pr.sh closes its PR when the new one opens. Prints the new branch name as its last line.
#
# Exit: 0 pushed, 2 usage/config (no such branch, the base branch, a dirty worktree), 3 the push failed.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
dl_branch_args "$0" "$@"

[ $# -le 1 ] || dl_die "usage: repush.sh [<branch>]"
dl_load_config
[ -n "$DL_ROOT" ] || dl_die "not inside a git repository"
branch=${1:-$(git symbolic-ref -q --short HEAD)}
[ -n "$branch" ] || dl_die "no branch given and HEAD is detached"
head=$(git rev-parse -q --verify "refs/heads/$branch") || dl_die "no local branch $branch"
case "$branch" in
  "$DL_BASE" | main | master | develop | trunk) dl_die "refusing to re-push the base branch $branch" ;;
esac
worktree=$(dl_worktree_of "$branch" | head -n 1)
if [ -n "$worktree" ] && [ -n "$(git -C "$worktree" status --porcelain)" ]; then
  dl_die "$worktree has uncommitted changes: commit them (or move them away) first"
fi

# taken NAME: a branch of that name exists on the remote or locally, or a notes file has that name.
taken() {
  printf '%s\n' "$remote_heads" | awk -v r="refs/heads/$1" '$2 == r {found = 1} END {exit !found}' && return 0
  git rev-parse -q --verify "refs/heads/$1" >/dev/null && return 0
  [ -e "$(dl_note_file "$1")" ]
}

# with_supersedes NOTES LINE: NOTES with LINE added after a blank line, before the closing
# "Generated with [Claude Code]" footer line when the notes end with one, so the PR body still ends with it.
with_supersedes() {
  LC_ALL=C awk -v line="$2" '{ text[NR] = $0 } $0 != "" { last = NR }
    END {
      footer = last && index(text[last], "\360\237\244\226 Generated with ") == 1
      end = footer ? last - 1 : NR
      while (footer && end > 0 && text[end] == "") end--
      for (i = 1; i <= end; i++) print text[i]
      print ""
      print line
      if (footer) { print ""; print text[last] }
    }' "$1"
}

remote_heads=$(git ls-remote --heads "$DL_REMOTE") || dl_die "git ls-remote $DL_REMOTE failed"
root=$branch version=1
if [[ "$branch" =~ ^(.+)-v([0-9]+)$ ]]; then
  root=${BASH_REMATCH[1]}
  version=$((10#${BASH_REMATCH[2]}))
fi
next=$((version + 1))
[ "$next" -ge 2 ] || next=2
while taken "$root-v$next"; do next=$((next + 1)); done
new=$root-v$next

git branch -q "$new" "$head" || dl_die "could not create the branch $new"
if [ -n "$worktree" ] && ! git -C "$worktree" checkout -q "$new"; then
  git update-ref -d "refs/heads/$new" "$head"
  dl_die "could not switch $worktree to $new"
fi
if ! "$scripts_dir/as-role.sh" implementer git -C "${worktree:-$DL_ROOT}" push -q -u "$DL_REMOTE" "$new"; then
  # Undo only what this run created: the worktree goes back, the new name (at the same head) goes.
  [ -z "$worktree" ] || git -C "$worktree" checkout -q "$branch"
  git update-ref -d "refs/heads/$new" "$head"
  echo "repush: the push of $new failed; nothing changed" >&2
  exit 3
fi

# The tips the old branch has now, locally and on the remote: the record cleanup.sh checks before deleting.
tips=$head
remote_tip=$(printf '%s\n' "$remote_heads" | awk -v r="refs/heads/$branch" '$2 == r {print $1}')
[ -z "$remote_tip" ] || [ "$remote_tip" = "$head" ] || tips="$tips $remote_tip"
old_note=$(dl_note_file "$branch")
new_note=$(dl_note_file "$new")
if [ -f "$old_note" ]; then
  supersedes="Supersedes \`$branch\` at $tips (re-pushed under a new name after a rebase, never force-pushed)."
  if ! { mkdir -p "$(dirname "$new_note")" && with_supersedes "$old_note" "$supersedes" >"$new_note"; } 2>/dev/null; then
    dl_warn "WARNING: $new is pushed, but its notes file could not be written: copy $old_note to $new_note"
    dl_warn "and add the line: Supersedes \`$branch\` at $tips"
  fi
else
  dl_warn "no notes file for $branch ($old_note): write $new_note"
fi
echo "repush: pushed $branch as $new at $(git rev-parse --short "$head"); $branch is left as it was" >&2
printf '%s\n' "$new"
