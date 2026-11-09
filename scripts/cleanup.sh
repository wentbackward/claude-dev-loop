#!/usr/bin/env bash
# Classify every local and remote branch, and delete the leftovers of merged and abandoned work.
#
# Usage: cleanup.sh [--apply] [--include closed] [--include stale] [--include worktrees] [--verbose]
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
# Worktrees of merged branches (the ledger or a merged PR at the tip; not "the base contains it") that
# merge-train.sh kept for their changes are listed too: path, branch, modified and untracked files (the
# first names), and "remove" or "keep" with the reason. --apply --include worktrees archives each "remove"
# one first, to a new ~/.dev-loop/<repo>/archive/worktrees-<time>/<branch>/ (changes.patch and
# staged.patch against HEAD, untracked.tar, manifest.txt with a restore line) and checks the archive,
# checks that the worktree still matches it, moves it aside and checks again, then removes it and deletes
# its branch at the merged tip (bundled like the others). Always kept: the main checkout and the gate
# worktree (real paths), a locked one, one with submodules, per-worktree refs or another worktree inside,
# a merge, rebase, cherry-pick or revert in progress, assume-unchanged or skip-worktree files, ignored files that are not build output (merge.rebuildable) or
# a folder it cannot read, and one with a file changed (mtime or ctime) in the last
# DEV_LOOP_WORKTREE_SETTLE_MINUTES (default 10; an agent may still work there).
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
      case "${2:-}" in
        closed | stale | worktrees) include+="$2 " ;;
        *) dl_die "--include takes closed, stale or worktrees" ;;
      esac
      shift
      ;;
    *) dl_die "usage: cleanup.sh [--apply] [--include closed] [--include stale] [--include worktrees] [--verbose]" ;;
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

# classify SCOPE NAME TIP DATE [any]: prints "<class>\t<scope>\t<name>\t<tip>\t<reason>"; with "any",
# as if no worktree had the branch checked out.
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
    [ -n "$worktree" ] && [ -z "${5:-}" ] && { out keep "checked out in $worktree"; return; }
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

# --- Worktrees kept for changes ----------------------------------------------------------------------------
# DEV_LOOP_WORKTREE_SETTLE_MINUTES (default 10): keep a worktree with a file changed (mtime or ctime) within
# that many minutes; 0 turns the time check off (for tests, which cannot backdate a ctime).
settle_minutes=${DEV_LOOP_WORKTREE_SETTLE_MINUTES:-10}
[[ "$settle_minutes" =~ ^[0-9]+$ ]] || dl_die "DEV_LOOP_WORKTREE_SETTLE_MINUTES must be whole minutes"

# real_path PATH: PATH with its symlinks resolved when it exists, else normalized.
real_path() {
  (cd -P -- "$1" 2>/dev/null && pwd -P) || dl_normalize "$1"
}
main_dir=$(real_path "$DL_ROOT")
gate_dir=$(real_path "$(dl_gate_dir)")

# nested_worktree PATH: the first other registered worktree inside the worktree at PATH.
nested_worktree() {
  local dir other
  dir=$(real_path "$1")
  git worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r other; do
    other=$(real_path "$other")
    [ "$other" != "$dir" ] && dl_path_under "$other" "$dir" && { printf '%s\n' "$other"; break; }
  done
}

# recent_or_unreadable PATH [moved]: "recent <file>" for a file changed within the settle window, "unreadable
# <error>" when find cannot read everything; nothing when neither. With "moved" the worktree's own folder is
# left out of the time test: moving it aside set its ctime to now.
recent_or_unreadable() {
  local found top=0
  [ -z "${2:-}" ] || top=1
  if [ "$settle_minutes" -gt 0 ]; then
    found=$(find "$1" -mindepth "$top" -name .git -prune -o \( -mmin -"$settle_minutes" -o -cmin -"$settle_minutes" \) \
      -print 2>"$work/find.err" | head -n 1)
    [ -z "$found" ] || { printf 'recent %s\n' "$found"; return; }
  else
    find "$1" -name .git -prune -o -print >/dev/null 2>"$work/find.err"
  fi
  [ ! -s "$work/find.err" ] || printf 'unreadable %s\n' "$(head -n 1 "$work/find.err")"
}

# has_submodules PATH: the worktree at PATH has a gitlink in its index or a modules directory.
has_submodules() {
  local modules
  [ -z "$(git -C "$1" ls-files -s 2>/dev/null | awk '$1 == 160000 {print; exit}')" ] || return 0
  modules=$(git -C "$1" rev-parse --git-path modules 2>/dev/null) || return 1
  case "$modules" in /*) ;; *) modules=$1/$modules ;; esac
  [ -d "$modules" ]
}

# operation_in_progress PATH: the worktree at PATH is in a merge, rebase, cherry-pick, revert or sequence, or
# has unmerged index entries.
operation_in_progress() {
  local name state
  for name in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-apply rebase-merge sequencer; do
    state=$(git -C "$1" rev-parse --git-path "$name" 2>/dev/null) || return 0
    case "$state" in /*) ;; *) state=$1/$state ;; esac
    [ ! -e "$state" ] || return 0
  done
  [ -n "$(git -C "$1" ls-files -u 2>/dev/null | head -n 1)" ]
}

# worktree_verdict PATH BRANCH [moved]: "remove", or "keep: <reason>", for the worktree of a merged BRANCH;
# "moved" when PATH is the worktree moved aside (see recent_or_unreadable).
worktree_verdict() {
  local dir found
  dir=$(real_path "$1")
  [ "$dir" != "$main_dir" ] || { echo "keep: the main checkout"; return; }
  [ "$dir" != "$gate_dir" ] || { echo "keep: the gate worktree"; return; }
  [ "$(dl_worktree_of "$2" | sed -n 2p)" != locked ] || { echo "keep: locked"; return; }
  found=$(nested_worktree "$1")
  [ -z "$found" ] || { echo "keep: holds another worktree ($found)"; return; }
  ! operation_in_progress "$1" || { echo "keep: a merge/rebase/cherry-pick is in progress"; return; }
  # A submodule's git dir and per-worktree refs live in the worktree's own git dir, which the removal deletes.
  ! has_submodules "$1" || { echo "keep: has submodules"; return; }
  found=$(git -C "$1" for-each-ref --format='%(refname)' refs/worktree refs/bisect 2>/dev/null | head -n 1)
  [ -z "$found" ] || { echo "keep: has per-worktree refs ($found)"; return; }
  # Assume-unchanged (lowercase) and skip-worktree (S) entries hide local changes from the diff.
  found=$(git -C "$1" ls-files -v 2>/dev/null | awk '/^([a-z]|S) / {print substr($0, 3); exit}')
  [ -z "$found" ] || { echo "keep: has assume-unchanged or skip-worktree files ($found)"; return; }
  found=$(dl_unrebuildable_ignored "$1")
  [ -z "$found" ] || { echo "keep: holds ignored files that are not build output ($found)"; return; }
  found=$(recent_or_unreadable "$1" "${3:-}")
  case "$found" in
    recent*) echo "keep: changed in the last $settle_minutes minutes (an agent may still work there)" ;;
    unreadable*) echo "keep: a file or folder could not be read (${found#unreadable })" ;;
    *) echo remove ;;
  esac
}

# worktree_contents PATH: "<n> modified, <m> untracked[: <the first five file names> ...]".
worktree_contents() {
  local names
  names=$(git --no-optional-locks -C "$1" status --porcelain 2>/dev/null | cut -c4- | head -n 6 | paste -sd' ' -)
  [ "$(printf '%s\n' "$names" | wc -w)" -le 5 ] || names="$(printf '%s\n' "$names" | cut -d' ' -f1-5) ..."
  printf '%s modified, %s untracked%s\n' \
    "$(git --no-optional-locks -C "$1" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')" \
    "$(git -C "$1" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')" "${names:+: $names}"
}

# aside_note PATH BRANCH: on stderr, a note when the registered worktree PATH is missing but a folder moved
# aside from it (PATH.removing-<pid>) is there: a move aside that did not finish.
aside_note() {
  local sibling
  for sibling in "$1".removing-*; do
    [ -d "$sibling" ] || continue
    printf 'note: worktree %s (%s) is missing, but %s is there (a move aside that did not finish); run git worktree repair %s and git worktree move %s %s\n' \
      "$1" "$2" "$sibling" "$sibling" "$sibling" "$1" >&2
  done
}

# worktree_is PATH BRANCH: the worktree at PATH is a worktree's top folder with BRANCH checked out (a
# porcelain path cut at a newline names some other folder).
worktree_is() {
  local top
  [ "$(git -C "$1" symbolic-ref -q HEAD 2>/dev/null)" = "refs/heads/$2" ] || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] &&
    [ "$(real_path "$top")" = "$(real_path "$1")" ]
}

# merged_worktrees: "<branch>\t<tip>\t<path>\t<verdict>" for each worktree whose branch the ledger or a
# merged PR has at its tip (containment alone is a fresh branch, never enough).
merged_worktrees() {
  local name path tip reason
  while IFS=$'\t' read -r name path; do
    [ -d "$path" ] || { aside_note "$path" "$name"; continue; }
    worktree_is "$path" "$name" || continue
    tip=$(git rev-parse -q --verify "refs/heads/$name") || continue
    reason=$(classify local "$name" "$tip" "$(git log -1 --format=%ct "$tip")" any | awk -F'\t' '$1 == "merged" {print $5}')
    case "$reason" in "in the merge ledger" | "merged PR "*) ;; *) continue ;; esac
    printf '%s\t%s\t%s\t%s\n' "$name" "$tip" "$path" "$(worktree_verdict "$path" "$name")"
  done <"$work/worktrees"
}

merged_worktrees >"$work/kept-worktrees"
if [ -s "$work/kept-worktrees" ]; then
  echo "worktrees of merged branches ($(wc -l <"$work/kept-worktrees" | tr -d ' ')); --apply --include worktrees archives and removes the ones marked remove:"
  while IFS=$'\t' read -r name _ path verdict; do
    case "$verdict" in
      remove) printf 'remove  %s  %s  (%s)\n' "$path" "$name" "$(worktree_contents "$path")" ;;
      *) printf 'keep    %s  %s  (%s)  %s\n' "$path" "$name" "$(worktree_contents "$path")" "${verdict#keep: }" ;;
    esac
  done <"$work/kept-worktrees"
fi

if [ -z "$apply" ]; then
  if [ "$factory" = dark ]; then what="merged, helper, superseded, closed and stale"; else
    what="merged, helper and superseded; closed and stale need --include"
  fi
  echo "cleanup: dry run ($factory factory); --apply deletes $what"
  exit 0
fi

# --- Apply ------------------------------------------------------------------------------------------------
failed=0

# worktree_diff PATH [--cached]: the worktree's (or the index's) changes against HEAD as a binary patch with
# a/ and b/ prefixes, whatever the user's diff config (no external diff, textconv or color).
worktree_diff() {
  git -C "$1" diff-index -p --binary --no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/ \
    ${2:+"$2"} HEAD
}

# archive_slot BASE: create and print a new directory BASE (BASE-2, BASE-3, ... when it exists).
archive_slot() {
  local dir=$1 n=1
  mkdir -p "$(dirname "$1")" || return 1
  until mkdir "$dir" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -le 99 ] && [ -w "$(dirname "$1")" ] || return 1
    dir=$1-$n
  done
  printf '%s\n' "$dir"
}

# archive_worktree PATH BRANCH TIP DIR: write the uncommitted changes of the worktree at PATH to the new
# directory DIR (changes.patch, staged.patch, untracked.z and untracked.tar, manifest.txt) and check that
# they hold them; fails when anything is off.
archive_worktree() {
  local path=$1 dir=$4
  git -C "$path" update-index -q --refresh >/dev/null 2>&1
  worktree_diff "$path" >"$dir/changes.patch" || return 1
  worktree_diff "$path" --cached >"$dir/staged.patch" || return 1
  git -C "$path" ls-files -z --others --exclude-standard >"$dir/untracked.z" || return 1
  (cd "$path" && tar -cf "$dir/untracked.tar" --null -T "$dir/untracked.z") || return 1
  {
    printf 'worktree: %s\nbranch: %s\ntip: %s\narchived: %s\n' "$path" "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'restore: git worktree add <path> %s, then in it git apply --cached staged.patch,\n' "$3"
    printf '  git apply --binary changes.patch and tar -xf untracked.tar\n'
    if git merge-base --is-ancestor "$3" "$base" 2>/dev/null; then
      printf '  (the base contains %s)\n' "$3"
    else
      printf '  (the base does not contain %s: first git fetch <bundle> refs/heads/%s:refs/heads/%s, from the\n' "$3" "$2" "$2"
      printf '  branches-<time>.bundle this run of cleanup.sh printed)\n'
    fi
    printf 'modified:\n'
    git --no-optional-locks -C "$path" status --porcelain --untracked-files=no
    printf 'untracked:\n'
    tr '\0' '\n' <"$dir/untracked.z"
  } >"$dir/manifest.txt" || return 1
  # The patches must reverse-apply to the worktree and the index as they are, the tar must list every
  # untracked file (a name with a newline cannot be checked, so it fails).
  [ ! -s "$dir/changes.patch" ] || git -C "$path" apply --check -R --binary "$dir/changes.patch" 2>/dev/null || return 1
  [ ! -s "$dir/staged.patch" ] || git -C "$path" apply --cached --check -R --binary "$dir/staged.patch" 2>/dev/null || return 1
  tr '\0' '\n' <"$dir/untracked.z" | LC_ALL=C sort >"$work/untracked.want"
  tar -tf "$dir/untracked.tar" | LC_ALL=C sort >"$work/untracked.got" || return 1
  [ "$(tr -cd '\0' <"$dir/untracked.z" | wc -c | tr -d ' ')" = "$(wc -l <"$work/untracked.got" | tr -d ' ')" ] &&
    cmp -s "$work/untracked.want" "$work/untracked.got"
}

# worktree_current PATH BRANCH TIP [moved]: the worktree at PATH is still removable, with BRANCH at TIP
# checked out.
worktree_current() {
  [ "$(worktree_verdict "$1" "$2" "${4:-}")" = remove ] &&
    [ "$(git rev-parse -q --verify "refs/heads/$2")" = "$3" ] &&
    [ "$(git -C "$1" rev-parse -q --verify HEAD)" = "$3" ] &&
    [ "$(dl_worktree_of "$2" | head -n 1)" = "$1" ]
}

# worktree_as_archived PATH BRANCH TIP DIR [moved]: worktree_current, and the worktree's changes, index and
# untracked files are exactly those archived in DIR.
worktree_as_archived() {
  worktree_current "$1" "$2" "$3" "${5:-}" || return 1
  git -C "$1" update-index -q --refresh >/dev/null 2>&1
  worktree_diff "$1" | cmp -s - "$4/changes.patch" &&
    worktree_diff "$1" --cached | cmp -s - "$4/staged.patch" &&
    git -C "$1" ls-files -z --others --exclude-standard | cmp -s - "$4/untracked.z"
}

# drop_archive SLOT: remove the archive SLOT this run made for a worktree that is kept whole at its path (it
# still holds everything, and an incomplete archive would only pile up).
drop_archive() {
  case "$1" in "$archive_dir"/?*) rm -rf -- "$1" ;; esac
}

# The worktrees marked remove: each checked again, archived and checked, checked once more, then removed.
if [[ "$include" == *" worktrees "* ]] && grep -q $'\tremove$' "$work/kept-worktrees"; then
  archive_dir=$DL_STATE/archive/worktrees-$(date +%Y%m%d-%H%M%S)
  while IFS=$'\t' read -r name tip path verdict; do
    [ "$verdict" = remove ] || continue
    slot=""
    if ! worktree_current "$path" "$name" "$tip"; then
      echo "kept worktree $path: it changed since the classification"
      continue
    fi
    if ! slot=$(archive_slot "$archive_dir/${name//\//_}") || ! archive_worktree "$path" "$name" "$tip" "$slot"; then
      echo "kept worktree $path: its archive could not be written or checked (removed)"
      drop_archive "$slot"
      failed=$((failed + 1))
      continue
    fi
    echo "archived worktree $path to $slot"
    if ! worktree_as_archived "$path" "$name" "$tip" "$slot"; then
      echo "kept worktree $path: it changed while it was archived (its incomplete archive $slot is removed)"
      drop_archive "$slot"
      continue
    fi
    # Moved aside, a new tool call by an agent working there fails on the missing path. A process whose cwd
    # is inside keeps writing into the moved folder by relative path, silently, and when the second check
    # misses those writes they go with it: that window stays open.
    aside=$path.removing-$$
    if [ -e "$aside" ]; then
      echo "kept worktree $path: it could not be moved aside ($aside exists; its incomplete archive $slot is removed)"
      drop_archive "$slot"
      failed=$((failed + 1))
      continue
    fi
    if ! git worktree move "$path" "$aside" >/dev/null 2>&1; then
      if [ -e "$aside" ]; then
        echo "kept worktree $path: the move to $aside failed half-way; nothing was removed, check both paths (git worktree repair $aside), the archive $slot stays"
      else
        echo "kept worktree $path: it could not be moved aside (its incomplete archive $slot is removed)"
        drop_archive "$slot"
      fi
      failed=$((failed + 1))
      continue
    fi
    if ! worktree_as_archived "$aside" "$name" "$tip" "$slot" moved; then
      if git worktree move "$aside" "$path" >/dev/null 2>&1; then
        echo "kept worktree $path: it changed after it was moved aside (its incomplete archive $slot is removed)"
        drop_archive "$slot"
      else
        echo "kept worktree $aside: it changed after it was moved aside from $path, and could not be moved back (the archive $slot stays)"
        failed=$((failed + 1))
      fi
      continue
    fi
    if ! git worktree remove --force "$aside" >/dev/null 2>&1; then
      echo "not removed: worktree $aside (moved aside from $path; the archive $slot stays)"
      failed=$((failed + 1))
      continue
    fi
    # Its branch is merged at this tip now that no worktree has it: the deletions below take it.
    awk -F'\t' -v OFS='\t' -v n="$name" -v t="$tip" '$1 == "keep" && $2 == "local" && $3 == n && $4 == t {
        $1 = "merged"; $5 = "merged, its worktree archived and removed" } { print }' "$report" >"$work/report.new" &&
      cat "$work/report.new" >"$report"
  done <"$work/kept-worktrees"
  rmdir "$archive_dir" 2>/dev/null
fi

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
