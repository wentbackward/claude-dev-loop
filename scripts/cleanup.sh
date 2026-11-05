#!/usr/bin/env bash
# Classify every local and remote branch, and delete the leftovers of merged and abandoned work.
#
# Usage: cleanup.sh [--apply] [--include closed] [--include stale] [--verbose]
#
# Without --apply it only reports (a dry run). Merged is decided by the merge ledger of merge-train.sh,
# then by the PR list (gh), never by git ancestry alone: a squash merge leaves none. Classes:
#   merged    the ledger or a merged PR has this tip (or the same changes), or the base contains it
#   helper    train-* and replay-* refs outside a live train; agent worktree branches with no own commits
#   closed    its PR was closed unmerged, or the issue its name points at (<type>/<n>-...) was closed
#   stale     no PR, no open issue, no commit for cleanup.stale_days (default 14)
#   keep      an open PR or issue, a worktree has it checked out, a live train, the base, a recent branch,
#             or a merged PR whose branch moved on since (each kept branch is listed with its reason)
#
# --apply deletes "merged" and "helper" (local and remote), moves the notes of merged PRs to
# notes/merged/, and removes notes there and gate logs older than cleanup.keep_days (default 30).
# "closed" needs --include closed (the user's OK) unless "factory" is "dark"; "stale" needs
# --include stale unless "factory" is "dark". Before deleting, every deleted tip that the base does not
# contain is saved to ~/.dev-loop/<repo>/archive/branches-<time>.bundle
# (restore one: git fetch <bundle> refs/heads/<branch>:refs/heads/<branch>).
# Remote deletions run as the gate identity in identity mode.
#
# Exit: 0 done, 2 usage/config.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"

apply="" verbose="" include=" "
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=yes ;;
    --verbose) verbose=yes ;;
    --include)
      case "${2:-}" in closed | stale) include+="$2 " ;; *) dl_die "--include takes closed or stale" ;; esac
      shift
      ;;
    *) dl_die "usage: cleanup.sh [--apply] [--include closed] [--include stale] [--verbose]" ;;
  esac
  shift
done
dl_load_config required
command -v gh >/dev/null 2>&1 || dl_die "gh (GitHub CLI) is not installed"
cd "$DL_ROOT" || exit 2
stale_days=$(cfg cleanup.stale_days 14)
keep_days=$(cfg cleanup.keep_days 30)
[[ "$stale_days" =~ ^[0-9]+$ && "$keep_days" =~ ^[0-9]+$ ]] || dl_die "cleanup.stale_days and cleanup.keep_days must be whole days"
factory=$(cfg factory collaborative)
[ "$factory" = dark ] && include+="closed stale "
git fetch -q --prune "$DL_REMOTE" || dl_die "git fetch $DL_REMOTE failed"
base="$DL_REMOTE/$DL_BASE"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- The evidence -------------------------------------------------------------------------------------
# Live trains: a gate in progress (its pid alive) and a green train waiting to merge.
live=" "
running=$(dl_running_file)
if [ -f "$running" ] && read -r pid branches <"$running" && kill -0 "$pid" 2>/dev/null; then
  live+="$branches "
fi
[ -f "$(dl_train_file)" ] && live+=$(awk '{printf "%s ", $1}' "$(dl_train_file)")

dl_ledger_heads >"$work/ledger"
"$scripts_dir/as-role.sh" orchestrator gh pr list --state all --limit 10000 \
  --json headRefName,headRefOid,state,number \
  --jq '.[] | [.headRefName, .headRefOid, .state, (.number | tostring)] | @tsv' >"$work/prs" ||
  dl_die "gh pr list failed"
"$scripts_dir/as-role.sh" orchestrator gh issue list --state all --limit 10000 \
  --json number,state,stateReason \
  --jq '.[] | [(.number | tostring), .state, (.stateReason // "")] | @tsv' >"$work/issues" ||
  dl_die "gh issue list failed"
git worktree list --porcelain | awk '/^worktree / {p = substr($0, 10)} /^branch refs\/heads\// {print substr($0, 19) "\t" p}' >"$work/worktrees"
git for-each-ref --merged "$base" --format='%(refname)' refs/heads "refs/remotes/$DL_REMOTE" >"$work/contained"
now=$(date +%s)

# same_changes TIP OTHER: TIP and OTHER bring the same changes onto the base (a replayed or rebased copy).
same_changes() {
  git cat-file -e "$2^{commit}" 2>/dev/null || return 1
  [ "$(git rev-parse "$1^{tree}")" = "$(git rev-parse "$2^{tree}")" ] && return 0
  local mine theirs
  mine=$(git diff "$(git merge-base "$1" "$base")" "$1" | git patch-id --stable | cut -d' ' -f1)
  theirs=$(git diff "$(git merge-base "$2" "$base")" "$2" | git patch-id --stable | cut -d' ' -f1)
  [ -n "$mine" ] && [ "$mine" = "$theirs" ]
}

# classify SCOPE NAME TIP DATE: prints "<class>\t<scope>\t<name>\t<tip>\t<reason>".
classify() {
  local scope=$1 name=$2 tip=$3 date=$4 ref worktree number pr_state="" line
  ref=refs/heads/$name
  [ "$scope" = remote ] && ref=refs/remotes/$DL_REMOTE/$name
  out() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$scope" "$name" "$tip" "$2"; }
  case "$name" in
    "$DL_BASE" | HEAD) out keep "the base branch"; return ;;
    train-* | replay-*)
      if [[ "$live" == *" ${name#*-} "* ]]; then out keep "a live train"; else out helper "gate ref outside a live train"; fi
      return
      ;;
  esac
  [[ "$live" == *" $name "* ]] && { out keep "in a live train"; return; }
  if [ "$scope" = local ]; then
    worktree=$(awk -F'\t' -v b="$name" '$1 == b {print $2; exit}' "$work/worktrees")
    [ -n "$worktree" ] && { out keep "checked out in $worktree"; return; }
    if [[ "$name" == worktree-agent-* ]] && [ "$(git rev-list --count "$base..$tip")" = 0 ]; then
      out helper "agent worktree branch with no commits of its own"
      return
    fi
  fi
  if grep -qxF -- "$ref" "$work/contained"; then out merged "the base contains it"; return; fi
  if grep -qxF -- "$name $tip" "$work/ledger"; then out merged "in the merge ledger"; return; fi
  while IFS=$'\t' read -r _ oid state number; do
    case "$state" in
      OPEN) out keep "open PR #$number"; return ;;
      MERGED)
        if [ "$oid" = "$tip" ] || same_changes "$tip" "$oid"; then out merged "merged PR #$number"; return; fi
        pr_state="merged PR #$number, but the branch moved on since"
        ;;
      CLOSED) [ -n "$pr_state" ] || pr_state="closed PR #$number" ;;
    esac
  done < <(awk -F'\t' -v b="$name" '$1 == b' "$work/prs")
  case "$pr_state" in
    "merged PR"*) out keep "$pr_state"; return ;;
    "closed PR"*) out closed "$pr_state, not merged"; return ;;
  esac
  if [[ "$name" =~ ^[a-z]+/([0-9]+)[-_] ]]; then
    number=${BASH_REMATCH[1]}
    line=$(awk -F'\t' -v n="$number" '$1 == n' "$work/issues")
    case "$line" in
      *$'\tOPEN\t'*) out keep "issue #$number is open"; return ;;
      *$'\tCLOSED\t'*) out closed "issue #$number closed ($(cut -f3 <<<"$line" | tr 'A-Z_' 'a-z ')), no merged PR"; return ;;
    esac
  fi
  if [ $(((now - date) / 86400)) -ge "$stale_days" ]; then
    out stale "no PR, no open issue, last commit $(((now - date) / 86400)) days ago"
  else
    out keep "recent ($(((now - date) / 86400)) days), no PR yet"
  fi
}

report=$(dl_logs_dir)/cleanup-$(date +%Y%m%d-%H%M%S).tsv
mkdir -p "$(dirname "$report")" || dl_die "cannot create $(dirname "$report")"
{
  git for-each-ref --format='%(refname:strip=2) %(objectname) %(committerdate:unix)' refs/heads |
    while read -r name tip date; do classify local "$name" "$tip" "$date"; done
  git for-each-ref --format='%(refname:strip=3) %(objectname) %(committerdate:unix)' "refs/remotes/$DL_REMOTE" |
    while read -r name tip date; do classify remote "$name" "$tip" "$date"; done
} >"$report"

for class in merged helper closed stale keep; do
  printf '%-7s %5s local %5s remote\n' "$class" \
    "$(awk -F'\t' -v c="$class" '$1 == c && $2 == "local"' "$report" | wc -l | tr -d ' ')" \
    "$(awk -F'\t' -v c="$class" '$1 == c && $2 == "remote"' "$report" | wc -l | tr -d ' ')"
done
echo "report: $report"
if [ -n "$verbose" ]; then
  awk -F'\t' '{printf "%-7s %-6s %s  (%s)\n", $1, $2, $3, $5}' "$report"
else
  awk -F'\t' '$1 == "closed" || $1 == "stale" {printf "%-7s %-6s %s  (%s)\n", $1, $2, $3, $5}' "$report" | head -n 40
fi

# --- Notes of merged PRs --------------------------------------------------------------------------------
notes_to_archive() {
  local file branch
  for file in "$(dl_notes_dir)"/pr-*.md; do
    [ -f "$file" ] || continue
    branch=$(basename "$file" .md)
    branch=${branch#pr-}
    awk -F'\t' -v k="$branch" '{n = $1; gsub("/", "_", n)} n == k {s[$3] = 1} END {exit !(s["MERGED"] && !s["OPEN"])}' \
      "$work/prs" && printf '%s\n' "$file"
  done
}

if [ -z "$apply" ]; then
  echo "dry run: $(notes_to_archive | wc -l | tr -d ' ') notes files of merged PRs would move to notes/merged/"
  echo "cleanup: dry run ($factory factory); --apply deletes merged and helper$( [ "$factory" = dark ] && echo ", closed and stale" || echo "; closed and stale need --include")"
  exit 0
fi

# --- Apply ------------------------------------------------------------------------------------------------
awk -F'\t' -v inc="$include" '$1 == "merged" || $1 == "helper" || index(inc, " " $1 " ") {print}' "$report" >"$work/delete"
if [ -s "$work/delete" ]; then
  archive=$DL_STATE/archive/branches-$(date +%Y%m%d-%H%M%S).bundle
  mkdir -p "$(dirname "$archive")"
  {
    awk -F'\t' -v r="$DL_REMOTE" '{print ($2 == "local" ? "refs/heads/" : "refs/remotes/" r "/") $3}' "$work/delete"
    echo "^$base"
  } | git bundle create "$archive" --stdin >/dev/null 2>"$work/bundle.err"
  if [ -s "$archive" ]; then
    echo "archived the deleted tips to $archive"
  elif grep -q "empty bundle" "$work/bundle.err"; then
    echo "nothing to archive: the base contains every deleted tip"
  else
    cat "$work/bundle.err" >&2
    dl_die "could not write the archive bundle; nothing deleted"
  fi
  awk -F'\t' '$2 == "local" {print $3}' "$work/delete" >"$work/delete-local"
  awk -F'\t' '$2 == "remote" {print $3}' "$work/delete" >"$work/delete-remote"
  [ ! -s "$work/delete-local" ] || xargs -n 100 git branch -q -D <"$work/delete-local" >/dev/null 2>&1
  [ ! -s "$work/delete-remote" ] ||
    xargs -n 50 "$scripts_dir/as-role.sh" gate git push -q "$DL_REMOTE" --delete <"$work/delete-remote" >/dev/null 2>&1
  git fetch -q --prune "$DL_REMOTE"
  echo "deleted $(awk -F'\t' '$2 == "local"' "$work/delete" | wc -l | tr -d ' ') local and $(awk -F'\t' '$2 == "remote"' "$work/delete" | wc -l | tr -d ' ') remote branches"
fi

moved=0
while read -r file; do
  mkdir -p "$(dl_notes_merged_dir)" && mv -f "$file" "$(dl_notes_merged_dir)/" && moved=$((moved + 1))
done < <(notes_to_archive)
echo "moved $moved notes files of merged PRs to $(dl_notes_merged_dir)"
find "$(dl_notes_merged_dir)" -maxdepth 1 -type f -name 'pr-*.md' -mtime +"$keep_days" -delete 2>/dev/null

# Gate logs: the current stages' logs are always the latest train's; others go after keep_days.
current=" train-setup.log train-changed-files.txt "
[ -n "$(cfg affected "")" ] && current+="train-affected.log "
for ((i = 0; i < $(cfg_len checks); i++)); do
  name=$(cfg "checks.$i.name" "check-$((i + 1))")
  case "$(cfg "checks.$i" "")" in "{"*) ;; *) name="check-$((i + 1))" ;; esac
  current+="train-${name//[^A-Za-z0-9_.-]/_}.log "
done
find "$(dl_logs_dir)" -maxdepth 1 -type f -mtime +"$keep_days" | while read -r file; do
  [[ "$current" == *" $(basename "$file") "* ]] || rm -f "$file"
done
echo "cleanup: done"
