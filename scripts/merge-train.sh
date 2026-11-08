#!/usr/bin/env bash
# Merge a green train (gate-train.sh) in order, one squash merge per branch.
#
# Usage: merge-train.sh <branch> [<branch> ...]   (the gated branches in gate order; after a stop, the
#                                                  ones not merged yet, same order)
#
# Refuses unless the last gate-train.sh run was GREEN for these branches. For each branch: replay its own
# commits onto the current <remote>/<base> and verify the tree equals the gated train-<branch> tree. When
# the branch already contains the base and has that tree, it merges as it is; otherwise a merge commit with
# the gated tree and two parents (the branch head, the base) is pushed to the branch as a plain
# fast-forward, never forced (the remote refuses it when the branch moved). Then: create the PR if missing
# (title and body from the notes file: first line title, a leading "#" is stripped, the rest is the body),
# squash-merge exactly that head (--match-head-commit; its squash is the gated tree, since the head
# contains the base), confirm the PR is MERGED and delete the remote branch.
#
# After each merge: append the merge to the ledger (~/.dev-loop/<repo>/merged.jsonl, read by cleanup.sh and
# arch-evidence.sh: the heads, the PR, the merge commit, and the evidence: the files the merge changed,
# their components through the cards (with "architecture"), the lines added and deleted, the review rounds
# and the ticket from the notes file),
# delete the local branch when its tip is the merged head (removing its worktree first when that is clean;
# otherwise it says what it kept and why), and move the notes file to notes/merged/. When the whole train
# has merged, delete its train-<branch> refs. merge.delete_local: false keeps the local branches.
#
# Identity mode (.dev-loop.json "identities"): pushes, the commit status and the merge run as the gate
# identity, a missing PR is opened as the implementer, and the PR must carry an approval (reviewer
# identity) on the pushed head. The gate posts the required status (github.status_context, default
# "dev-loop/gate") on that head, so the server-side ruleset lets only gated, approved heads merge.
#
# Exit: 0 all merged, 2 usage/config, 3 replay conflict, 4 tree differs from the gated one (re-gate),
# 5 notes file missing, 6 branch changed since the gate, 7 PR not merged, 8 not gated green,
# 9 approval missing on the pushed head (have the reviewer approve, then re-run with the remaining branches).
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
dl_branch_args "$0" "$@"
# shellcheck source=lib/identity.sh
. "$scripts_dir/lib/identity.sh"
# shellcheck source=lib/arch.sh
. "$scripts_dir/lib/arch.sh"

[ $# -gt 0 ] || dl_die "usage: merge-train.sh <branch> [<branch> ...]"
dl_load_train_config --recorded "$1"
command -v gh >/dev/null 2>&1 || dl_die "gh (GitHub CLI) is not installed"
gate=$(dl_gate_dir)
[ -d "$gate" ] || dl_die "no gate worktree at $gate (run gate-train.sh first)"
train_file=$(dl_train_file)
delete_branch=$(cfg merge.delete_branch true)
delete_local=$(cfg merge.delete_local true)
merge_method=$(cfg merge.method squash)
status_context=$(cfg github.status_context "dev-loop/gate")
identity_mode=""
dl_identities_enabled && identity_mode=yes
post_status=$(cfg github.post_status "${identity_mode:+true}")

as_role() { "$scripts_dir/as-role.sh" "$@"; }
trap 'dl_event merge merge-ended rc="$?"' EXIT
dl_event merge merge-started branches="$*"

[ -f "$train_file" ] || { echo "MERGE refused: no green train recorded (run gate-train.sh)"; exit 8; }
pending=$(awk '$4 != "merged" {printf "%s ", $1}' "$train_file")
if [ "$pending" != "$* " ]; then
  echo "MERGE refused: the green train still to merge is: ${pending% }"
  exit 8
fi

# record BRANCH FIELD VALUE: update the train file (field 2 = the branch's head on the remote, field 4 =
# state, field 5 = the head the gate tested, kept once a merge commit moved field 2, field 6 = the merge
# commit about to be pushed, recorded before the push so a run that stopped right after it can resume).
record() {
  awk -v b="$1" -v f="$2" -v v="$3" '$1 == b {$f = v} {print}' "$train_file" >"$train_file.tmp" &&
    mv "$train_file.tmp" "$train_file"
}

# up_to_date TIP GATED: TIP contains the base and has the GATED tree, so its squash merge is that tree.
up_to_date() {
  git merge-base --is-ancestor "$DL_REMOTE/$DL_BASE" "$1" &&
    [ "$(git rev-parse "$1^{tree}")" = "$(git rev-parse "$2^{tree}")" ]
}

for branch in "$@"; do
  note=$(dl_note_file "$branch")
  if [ ! -f "$note" ] && ! (cd "$DL_ROOT" && as_role gate gh pr view "$branch" >/dev/null 2>&1); then
    echo "MERGE missing notes file $note (and no PR exists for $branch)"
    exit 5
  fi
done

previous=$(awk '$4 == "merged" {b = $1} END {print b}' "$train_file")
for branch in "$@"; do
  read -r _ source_head gated _ tested_head pushing <<<"$(awk -v b="$branch" '$1 == b' "$train_file")"
  tested_head=${tested_head:-$source_head}
  cd "$gate" || exit 2
  git fetch -q --prune "$DL_REMOTE" || dl_die "git fetch $DL_REMOTE failed"
  [ "$(git rev-parse "train-$branch" 2>/dev/null)" = "$gated" ] ||
    { echo "MERGE refused: train-$branch is not the gated head"; exit 8; }
  # A run that stopped between the push of its merge commit and recording it: the remote has that commit.
  if [ -n "$pushing" ] && [ "$(git rev-parse "$DL_REMOTE/$branch" 2>/dev/null)" = "$pushing" ]; then
    record "$branch" 2 "$pushing"
    source_head=$pushing
  fi
  if [ "$(git rev-parse "$DL_REMOTE/$branch" 2>/dev/null)" != "$source_head" ]; then
    echo "MERGE $branch changed on $DL_REMOTE since the gate: re-gate it"
    exit 6
  fi
  if [ -z "$previous" ]; then
    from=$(git merge-base "train-$branch" "$DL_REMOTE/$DL_BASE")
  else
    from="train-$previous"
  fi
  git checkout -q -B "replay-$branch" "train-$branch"
  if ! git rebase -q --onto "$DL_REMOTE/$DL_BASE" "$from" "replay-$branch" >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1
    git checkout -q --detach "$DL_REMOTE/$DL_BASE"
    echo "MERGE replay conflict at $branch"
    exit 3
  fi
  if ! git diff --quiet "$gated" HEAD; then
    git checkout -q --detach "$DL_REMOTE/$DL_BASE"
    echo "MERGE tree differs from the gated one at $branch ($DL_BASE moved): re-gate"
    exit 4
  fi
  changed=$(git diff -z --name-only "$DL_REMOTE/$DL_BASE" HEAD | dl_json_list_z)
  read -r added deleted <<<"$(dl_diff_lines "$DL_REMOTE/$DL_BASE" HEAD)"
  components=""
  dl_arch_on && components=$(git diff -z --name-only "$DL_REMOTE/$DL_BASE" HEAD | dl_z_lines | dl_arch_components_at HEAD)
  head=$source_head
  if ! up_to_date "$source_head" "$gated"; then
    head=$(git commit-tree "$gated^{tree}" -p "$source_head" -p "$DL_REMOTE/$DL_BASE" \
      -m "Merge $DL_BASE into $branch" -m "The tree the batch gate tested (train-$branch), as a fast-forward of $branch.") ||
      { git checkout -q --detach "$DL_REMOTE/$DL_BASE"; echo "MERGE could not create the merge commit for $branch"; exit 2; }
    record "$branch" 5 "$tested_head"
    record "$branch" 6 "$head"
    if ! as_role gate git push -q "$DL_REMOTE" "$head:$branch"; then
      git checkout -q --detach "$DL_REMOTE/$DL_BASE"
      echo "MERGE push rejected for $branch (changed since the gate?)"
      exit 6
    fi
    record "$branch" 2 "$head"
  fi
  git checkout -q --detach "$DL_REMOTE/$DL_BASE"
  git branch -q -D "replay-$branch"

  cd "$DL_ROOT" || exit 2
  "$scripts_dir/open-pr.sh" "$branch" >/dev/null || { echo "MERGE could not open the PR for $branch"; exit 7; }
  if [ "$post_status" = true ]; then
    as_role gate gh api -X POST "repos/$(dl_github_repo)/statuses/$head" -f state=success \
      -f context="$status_context" -f description="batch gate green (tree of the gated train)" >/dev/null ||
      { echo "MERGE could not post the $status_context status on $branch"; exit 7; }
  fi
  if [ -n "$identity_mode" ]; then
    decision=$(as_role gate gh pr view "$branch" --json reviewDecision --jq .reviewDecision 2>/dev/null)
    if [ "$decision" != APPROVED ]; then
      echo "MERGE $branch needs the reviewer's approval on $head (review decision: ${decision:-none})."
      echo "      Have the code-reviewer confirm and approve, then run: merge-train.sh $(awk '$4 != "merged" {printf "%s ", $1}' "$train_file")"
      exit 9
    fi
  fi
  sleep "${DEV_LOOP_GH_SETTLE_SECONDS:-3}"
  as_role gate gh pr merge "$branch" "--$merge_method" --match-head-commit "$head" >/dev/null 2>&1
  state=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    state=$(as_role gate gh pr view "$branch" --json state --jq .state 2>/dev/null)
    [ "$state" = MERGED ] && break
    sleep "${DEV_LOOP_GH_SETTLE_SECONDS:-3}"
  done
  if [ "$state" != MERGED ]; then
    echo "MERGE PR for $branch is ${state:-unknown}, not MERGED"
    exit 7
  fi
  record "$branch" 4 merged
  note=$(dl_note_file "$branch")
  dl_ledger_append "$branch" "$tested_head" "$head" "$gated" "$(git -C "$gate" rev-parse "$gated^{tree}")" \
    "$(as_role gate gh pr view "$branch" --json number --jq .number 2>/dev/null)" \
    "$(as_role gate gh pr view "$branch" --json mergeCommit --jq .mergeCommit.oid 2>/dev/null)" \
    "$(dl_notes_ticket "$note" "$branch")" "$(dl_notes_review_rounds "$note")" "$added" "$deleted" "$changed" "$components"
  [ "$delete_branch" = false ] || as_role gate git push -q "$DL_REMOTE" --delete "$branch" >/dev/null 2>&1
  git fetch -q --prune "$DL_REMOTE"
  [ "$delete_local" = false ] || dl_remove_merged_local "$branch" "$tested_head" "$head"
  dl_event merge merged branch="$branch" ticket="$(dl_notes_ticket "$note" "$branch")"
  dl_archive_note "$branch"
  # Fast-forward the main checkout only when it is on the base branch and clean.
  if [ "$(git rev-parse --abbrev-ref HEAD)" = "$DL_BASE" ] && [ -z "$(git status --porcelain)" ]; then
    git merge -q --ff-only "$DL_REMOTE/$DL_BASE" >/dev/null 2>&1
  fi
  echo "merged $branch -> $(git log --oneline -1 "$DL_REMOTE/$DL_BASE")"
  previous=$branch
done
# The train refs are needed until the whole train has merged (each replay starts at the previous one).
while read -r branch _; do
  git -C "$DL_ROOT" branch -q -D "train-$branch" >/dev/null 2>&1
done <"$train_file"
rm -f "$train_file"
echo "notes of the merged branches moved to $(dl_notes_merged_dir)"
