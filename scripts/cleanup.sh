#!/usr/bin/env bash
# Classify every local and remote branch, and delete the leftovers of merged and abandoned work.
#
# Usage: cleanup.sh [--apply] [--include closed] [--include stale] [--verbose]
#
# Merged is decided by the merge ledger of merge-train.sh, then by the PR list (gh); a squash merge leaves
# no ancestry. Branches outside the loop (names not matching github.feature_patterns, default feat/* fix/*
# chore/* docs/*) are only ever deleted locally, and only as stale; the PR and ledger rules never apply to
# them. Classes:
#   merged    the ledger or a merged PR has this tip (or a replayed copy with the same changes); a local
#             loop branch the base contains
#   helper    local train-<branch> and replay-<branch> refs of loop branches outside a live train; local
#             agent worktree branches with no commits of their own
#   superseded  a later version of it (<branch>-vN from repush.sh, N above its own) merged (ledger or
#             PR), whose notes (live or in notes/merged) record "Supersedes `<branch>` at <sha>..." with
#             this tip; never while that version is unmerged, nor while its own PR is open. Without a
#             record, or at another tip (moved on since the re-push), it is kept, with the reason
#   closed    its PR was closed unmerged at this tip, or its issue (<type>/<n>-...) closed as not planned
#   stale     no PR, no open issue, no commit for cleanup.stale_days (default 14); remote: loop branches only
#   keep      everything else, listed with its reason: an open PR or issue, a worktree has it checked out,
#             a live train, the base, recent, moved on after its PR, or not a loop branch
#
# Without --apply it is a dry run: it still fetches (with --prune) and writes the classification to
# <logs_dir>/cleanup-<time>.tsv, and deletes nothing. --apply deletes "merged", "helper" and
# "superseded", locally and on the remote; "closed" needs --include closed and "stale" --include stale
# (the user's OK), unless "factory" is "dark". Each deletion is conditional on the tip that was
# classified. Before deleting, every tip the base does not contain is saved to
# ~/.dev-loop/<repo>/archive/branches-<time>.bundle and checked there; restore with git fetch <bundle>
# refs/heads/<branch>:refs/heads/<branch> (a remote-only branch:
# refs/remotes/<remote>/<branch>:refs/heads/<branch>). --apply also moves the notes files of merged PRs
# and of superseded branches whose branch is gone to notes/merged/, and removes, after cleanup.keep_days
# (default 30), notes there and old gate logs and cleanup reports (never other files in the logs
# directory).
# Remote deletions run as the gate identity in identity mode. Needs git 2.9 or later.
#
# Exit: 0 done, 1 some deletions failed (listed), 2 usage/config.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
dl_help "$0" "${1:-}"

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
[[ "$stale_days" =~ ^[0-9]+$ && "$keep_days" =~ ^[0-9]+$ ]] ||
  dl_die "cleanup.stale_days and cleanup.keep_days must be whole days"
factory=$(dl_factory)
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
git worktree list --porcelain |
  awk '/^worktree / {p = substr($0, 10)} /^branch refs\/heads\// {print substr($0, 19) "\t" p}' >"$work/worktrees"
{ awk '{print $1}' "$work/ledger"; awk -F'\t' '$3 == "MERGED" {print $1}' "$work/prs"; } |
  sort -u >"$work/merged-names"
git for-each-ref --merged "$base" --format='%(refname)' refs/heads "refs/remotes/$DL_REMOTE" >"$work/contained"
now=$(date +%s)
default_branch=$(git symbolic-ref -q --short "refs/remotes/$DL_REMOTE/HEAD" 2>/dev/null)
default_branch=${default_branch#"$DL_REMOTE/"}

# loop_branch NAME: a branch the loop creates (github.feature_patterns), read once per run.
if [ "$(cfg_len github.feature_patterns)" -eq 0 ]; then
  loop_branch() { case "$1" in feat/* | fix/* | chore/* | docs/*) return 0 ;; *) return 1 ;; esac }
else
  loop_branch() { dl_loop_branch "$1"; }
fi

# same_changes TIP OTHER: TIP and OTHER bring the same changes onto the base (a replayed or rebased copy).
same_changes() {
  git cat-file -e "$2^{commit}" 2>/dev/null || return 1
  [ "$(git rev-parse "$1^{tree}")" = "$(git rev-parse "$2^{tree}")" ] && return 0
  local mine theirs
  mine=$(git diff "$(git merge-base "$1" "$base")" "$1" | git patch-id --stable | cut -d' ' -f1)
  theirs=$(git diff "$(git merge-base "$2" "$base")" "$2" | git patch-id --stable | cut -d' ' -f1)
  [ -n "$mine" ] && [ "$mine" = "$theirs" ]
}

# later_versions NAME: the merged later versions of NAME (<root>-vN, N above NAME's own), oldest first.
later_versions() {
  local root=$1 version=1
  if [[ "$1" =~ ^(.+)-v([0-9]+)$ ]]; then
    root=${BASH_REMATCH[1]}
    version=$((10#${BASH_REMATCH[2]}))
  fi
  awk -v p="$root-v" -v own="$version" 'index($0, p) == 1 {
      n = substr($0, length(p) + 1)
      if (n ~ /^[0-9]+$/ && n + 0 > own) print n "\t" $0
    }' "$work/merged-names" | sort -n | cut -f2
}

# recorded_tips NAME: the tips recorded on "Supersedes `NAME` at <sha>..." lines in the notes files (live
# or archived in notes/merged) of the versions read from stdin.
recorded_tips() {
  local version key file dir
  dir=$(dl_notes_dir)
  while read -r version; do
    key=${version//\//_}
    for file in "$dir/pr-$key.md" "$dir/merged/pr-$key.md" \
      "$dir/merged/pr-$key"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*.md; do
      [ -f "$file" ] || continue
      awk -v p="Supersedes \`$1\` at " 'index($0, p) == 1 {
          n = split(substr($0, length(p) + 1), word, / /)
          for (i = 1; i <= n && word[i] ~ /^[0-9a-f]+$/ && length(word[i]) >= 40; i++) print word[i]
        }' "$file"
    done
  done
}

# classify SCOPE NAME TIP DATE: prints "<class>\t<scope>\t<name>\t<tip>\t<reason>".
classify() {
  local scope=$1 name=$2 tip=$3 date=$4 ref worktree number line days successor recorded
  local open="" merged="" closed="" moved=""
  ref=refs/heads/$name
  [ "$scope" = remote ] && ref=refs/remotes/$DL_REMOTE/$name
  out() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$scope" "$name" "$tip" "$2"; }
  case "$name" in "$DL_BASE" | HEAD | "$default_branch" | main | master | develop | trunk)
    out keep "the base or a long-lived branch"
    return
    ;;
  esac
  if [ "$scope" = local ]; then
    case "$name" in train-* | replay-*)
      if [[ "$live" == *" ${name#*-} "* ]]; then
        out keep "a live train"
        return
      elif loop_branch "${name#*-}"; then
        out helper "gate ref outside a live train"
        return
      fi
      ;;
    esac
  fi
  [[ "$live" == *" $name "* ]] && { out keep "in a live train"; return; }
  if [ "$scope" = local ]; then
    worktree=$(awk -F'\t' -v b="$name" '$1 == b {print $2; exit}' "$work/worktrees")
    [ -n "$worktree" ] && { out keep "checked out in $worktree"; return; }
    if [[ "$name" == worktree-agent-* ]] && [ "$(git rev-list --count "$base..$tip")" = 0 ]; then
      out helper "agent worktree branch with no commits of its own"
      return
    fi
  fi
  # Branches outside the loop (develop, release-*, a person's own): only ever stale, and only locally.
  if ! loop_branch "$name"; then
    if [ "$scope" = remote ]; then out keep "not a loop branch"; return; fi
    days=$(((now - date) / 86400))
    if [ "$days" -ge "$stale_days" ]; then out stale "not a loop branch, last commit $days days ago"; else
      out keep "not a loop branch, recent ($days days)"
    fi
    return
  fi
  if grep -qxF -- "$name $tip" "$work/ledger"; then out merged "in the merge ledger"; return; fi
  while IFS=$'\t' read -r _ oid state number; do
    case "$state" in
      OPEN) open="#$number" ;;
      MERGED)
        if [ "$oid" = "$tip" ] || same_changes "$tip" "$oid"; then merged="#$number"; else moved="merged PR #$number"; fi
        ;;
      CLOSED) if [ "$oid" = "$tip" ]; then closed="#$number"; else moved=${moved:-"closed PR #$number"}; fi ;;
    esac
  done < <(awk -F'\t' -v b="$name" '$1 == b' "$work/prs")
  [ -n "$open" ] && { out keep "open PR $open"; return; }
  [ -n "$merged" ] && { out merged "merged PR $merged"; return; }
  # A merged later version deletes this branch only at the tip its re-push recorded; otherwise the branch
  # is kept, unless the base contains it (the rules below then decide, as before).
  successor=$(later_versions "$name" | tail -n 1)
  if [ -n "$successor" ]; then
    recorded=$(later_versions "$name" | recorded_tips "$name")
    if [ -n "$recorded" ] && printf '%s\n' "$recorded" | grep -qxF -- "$tip"; then
      out superseded "superseded by $successor, which merged, at the recorded tip"
      return
    elif ! grep -qxF -- "$ref" "$work/contained"; then
      if [ -z "$recorded" ]; then
        out keep "a later version ($successor) merged, but no Supersedes record for this branch"
      else
        out keep "superseded by $successor, but moved on since the re-push"
      fi
      return
    fi
  fi
  [ -n "$closed" ] && { out closed "closed PR $closed, not merged"; return; }
  [ -n "$moved" ] && { out keep "$moved, but the branch moved on since"; return; }
  if grep -qxF -- "$ref" "$work/contained"; then
    if [ "$scope" = local ]; then out merged "the base contains it"; else out keep "the base contains it, no PR"; fi
    return
  fi
  if [[ "$name" =~ ^[a-z]+/([0-9]+)[-_] ]]; then
    number=${BASH_REMATCH[1]}
    line=$(awk -F'\t' -v n="$number" '$1 == n' "$work/issues")
    case "$line" in
      *$'\tOPEN\t'*) out keep "issue #$number is open"; return ;;
      *$'\tCLOSED\tNOT_PLANNED') out closed "issue #$number closed as not planned, no PR"; return ;;
    esac
  fi
  days=$(((now - date) / 86400))
  if [ "$days" -ge "$stale_days" ]; then out stale "no PR, no open issue, last commit $days days ago"; else
    out keep "recent ($days days), no PR yet"
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

for class in merged helper superseded closed stale keep; do
  printf '%-10s %5s local %5s remote\n' "$class" \
    "$(awk -F'\t' -v c="$class" '$1 == c && $2 == "local"' "$report" | wc -l | tr -d ' ')" \
    "$(awk -F'\t' -v c="$class" '$1 == c && $2 == "remote"' "$report" | wc -l | tr -d ' ')"
done
echo "report: $report"
if [ -n "$verbose" ]; then
  awk -F'\t' '{printf "%-10s %-6s %s  (%s)\n", $1, $2, $3, $5}' "$report"
else
  awk -F'\t' '$1 == "superseded" || $1 == "closed" || $1 == "stale" {
    printf "%-10s %-6s %s  (%s)\n", $1, $2, $3, $5}' "$report" | head -n 40
fi

# notes_to_archive: notes files of merged PRs (none open) whose branch is gone, locally and remotely.
notes_to_archive() {
  local file key name state
  for file in "$(dl_notes_dir)"/pr-*.md; do
    [ -f "$file" ] || continue
    key=$(basename "$file" .md)
    key=${key#pr-}
    local found="" open=""
    while IFS=$'\t' read -r name _ state _; do
      [ "${name//\//_}" = "$key" ] || continue
      case "$state" in OPEN) open=yes ;; MERGED) found=$name ;; esac
      git rev-parse -q --verify "refs/heads/$name" >/dev/null && open=yes
      git rev-parse -q --verify "refs/remotes/$DL_REMOTE/$name" >/dev/null && open=yes
    done <"$work/prs"
    [ -n "$found" ] && [ -z "$open" ] && printf '%s\n' "$file"
  done
}

# superseded_notes: notes files of superseded branches that are gone, locally and remotely.
superseded_notes() {
  local name file
  awk -F'\t' '$1 == "superseded" {print $3}' "$report" | sort -u | while read -r name; do
    file=$(dl_note_file "$name")
    [ -f "$file" ] || continue
    git rev-parse -q --verify "refs/heads/$name" >/dev/null && continue
    git rev-parse -q --verify "refs/remotes/$DL_REMOTE/$name" >/dev/null && continue
    printf '%s\n' "$file"
  done
}

if [ -z "$apply" ]; then
  if [ "$factory" = dark ]; then what="merged, helper, superseded, closed and stale"; else
    what="merged, helper and superseded; closed and stale need --include"
  fi
  echo "cleanup: dry run ($factory factory); --apply deletes $what"
  exit 0
fi

# --- Apply ------------------------------------------------------------------------------------------------
failed=0
awk -F'\t' -v inc="$include" '$1 == "merged" || $1 == "helper" || $1 == "superseded" ||
  index(inc, " " $1 " ") {print}' "$report" >"$work/delete"
if [ -s "$work/delete" ]; then
  # Archive every tip the base does not contain, and check the bundle has each one before deleting.
  awk -F'\t' -v r="$DL_REMOTE" '{print ($2 == "local" ? "refs/heads/" : "refs/remotes/" r "/") $3}' "$work/delete" |
    grep -vxF -f "$work/contained" >"$work/archive-refs"
  if [ -s "$work/archive-refs" ]; then
    archive=$DL_STATE/archive/branches-$(date +%Y%m%d-%H%M%S).bundle
    mkdir -p "$(dirname "$archive")"
    { cat "$work/archive-refs"; echo "^$base"; } | git bundle create "$archive" --stdin >/dev/null 2>"$work/bundle.err" ||
      { cat "$work/bundle.err" >&2; dl_die "could not write the archive bundle; nothing deleted"; }
    git bundle list-heads "$archive" | awk '{print $2}' >"$work/bundled"
    missing=$(grep -vxF -f "$work/bundled" "$work/archive-refs")
    [ -z "$missing" ] || dl_die "the archive bundle lacks $(echo "$missing" | wc -l | tr -d ' ') tips; nothing deleted"
    echo "archived $(wc -l <"$work/archive-refs" | tr -d ' ') tips to $archive"
  fi

  # Local: delete only at the classified tip, and never a branch a worktree has checked out meanwhile.
  deleted_local=0
  while IFS=$'\t' read -r _ scope name tip _; do
    [ "$scope" = local ] || continue
    if [ -n "$(dl_worktree_of "$name")" ] || ! git update-ref -d "refs/heads/$name" "$tip" 2>/dev/null; then
      echo "not deleted: local $name (checked out or moved since the classification)"
      failed=$((failed + 1))
    else
      deleted_local=$((deleted_local + 1))
    fi
  done <"$work/delete"

  # Remote: in batches, each ref with a lease on the classified tip; success is read back from the remote.
  awk -F'\t' '$2 == "remote" {print $3 "\t" $4}' "$work/delete" >"$work/delete-remote"
  deleted_remote=0
  if [ -s "$work/delete-remote" ]; then
    args=()
    flush() {
      [ ${#args[@]} -gt 0 ] || return 0
      "$scripts_dir/as-role.sh" gate git push -q "$DL_REMOTE" "${args[@]}" </dev/null >/dev/null 2>&1
      args=()
    }
    while IFS=$'\t' read -r name tip; do
      args+=("--force-with-lease=refs/heads/$name:$tip" ":refs/heads/$name")
      [ ${#args[@]} -lt 100 ] || flush
    done <"$work/delete-remote"
    flush
    git fetch -q --prune "$DL_REMOTE"
    while IFS=$'\t' read -r name _; do
      if git rev-parse -q --verify "refs/remotes/$DL_REMOTE/$name" >/dev/null; then
        echo "not deleted: remote $name (rejected, or moved since the classification)"
        failed=$((failed + 1))
      else
        deleted_remote=$((deleted_remote + 1))
      fi
    done <"$work/delete-remote"
  fi
  echo "deleted $deleted_local local and $deleted_remote remote branches"
fi

moved=0
while read -r file; do
  dl_archive_note_file "$file" && moved=$((moved + 1))
done < <({ notes_to_archive; superseded_notes; } | sort -u)
echo "moved $moved notes files of merged and superseded branches to $(dl_notes_merged_dir)"
find "$(dl_notes_merged_dir)" -maxdepth 1 -type f -name 'pr-*.md' -mtime +"$keep_days" -exec rm -f {} + 2>/dev/null

# Gate logs and cleanup reports only: the current stages' logs (the latest train) are always kept.
current=" train-setup.log train-changed-files.txt "
[ -n "$(cfg affected "")" ] && current+="train-affected.log "
for ((i = 0; i < $(cfg_len checks); i++)); do
  case "$(cfg "checks.$i" "")" in "{"*) name=$(cfg "checks.$i.name" "check-$((i + 1))") ;; *) name="check-$((i + 1))" ;; esac
  current+="train-${name//[^A-Za-z0-9_.-]/_}.log "
done
find "$(dl_logs_dir)" -maxdepth 1 -type f \( -name 'train-*.log' -o -name 'cleanup-*.tsv' \) -mtime +"$keep_days" |
  while read -r file; do
    [[ "$current" == *" $(basename "$file") "* ]] || rm -f "$file"
  done
if [ "$failed" -gt 0 ]; then
  echo "cleanup: done, $failed deletions failed (listed above)"
  exit 1
fi
echo "cleanup: done"
