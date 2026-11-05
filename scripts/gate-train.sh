#!/usr/bin/env bash
# Gate a batch of ready branches with ONE full run of the project's checks (a merge train).
#
# Usage: gate-train.sh <branch> [<branch> ...]          (branches in merge order)
#
# In the gate worktree, stacks each <remote>/<branch> on the latest <remote>/<base> in order, keeping each
# branch's rebased head as train-<branch>. A branch already stacked on the previous one in the train replays
# only its own commits (rebase --onto), so no branch ever carries foreign commits. Then it runs every check
# of .dev-loop.json "checks" once on the top of the stack; heavy checks run through heavy.sh, so the
# machine-wide slot limit and memory cap apply.
#
# Options (.dev-loop.json, all off by default):
#   "affected": {"command", "summary", "heavy"} (or a plain command): run first, after gate_setup, with
#     DL_CHANGED_FILES naming a file that lists the paths the train changes against the base, one per line
#     (train-changed-files.txt in the logs directory, kept until the next train; also set for gate_setup
#     and the checks). Without "affected" the list is not made and the variable is not set.
#   "parallel": true    run the checks at the same time (each heavy one in its own heavy.sh slot), each in
#                       its own process group; the results print in config order once all have ended.
#   "fail_fast": true   after the first failure (affected or a check), skip the checks not started yet and
#                       stop the running ones (SIGTERM to their process groups, SIGKILL after
#                       DEV_LOOP_STOP_GRACE_SECONDS, default 10); they print as "<name> stopped", or
#                       with their rc when they had ended with 0. A SIGTERM, SIGINT or SIGHUP to this
#                       script in parallel mode stops the running checks the same way (TRAIN RED).
#
# Before stacking, it deletes the train-<branch> refs of earlier trains (red ones, or those of branches no
# longer in a train) for loop branches (github.feature_patterns); it keeps those of this train and of a
# green train still waiting to merge, and never touches other branches whose names start with train-. While it
# runs, the train is recorded in train-running.txt, so cleanup.sh leaves its refs alone.
#
# Exit: 0 TRAIN GREEN (recorded for merge-train.sh), 1 TRAIN RED, 2 usage/config, 3 rebase conflict
# (the output names the branch: drop it from the train, rebase it after the others merge).
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"

[ $# -gt 0 ] || dl_die "usage: gate-train.sh <branch> [<branch> ...]"
dl_load_train_config "$1"
[ "$(cfg_len checks)" -gt 0 ] || dl_die "no \"checks\" in $DL_CONFIG"

gate=$(dl_ensure_gate_worktree) || exit 2
logs=$(dl_logs_dir)
mkdir -p "$logs" "$DL_STATE" || dl_die "cannot create $logs"
train_file=$(dl_train_file)
running_file=$(dl_running_file)
printf '%s %s\n' "$$" "$*" >"$running_file"
trap 'rm -f "$running_file"' EXIT

# Stale train refs: everything but this train and the unmerged branches of a waiting green train.
keep_train=" $* "
[ -f "$train_file" ] && keep_train+=$(awk '$4 != "merged" {printf "%s ", $1}' "$train_file")
rm -f "$train_file"
cd "$gate" || exit 2

git fetch -q --prune "$DL_REMOTE" || dl_die "git fetch $DL_REMOTE failed"
git rebase --abort >/dev/null 2>&1
git checkout -q --detach "$DL_REMOTE/$DL_BASE" || dl_die "cannot check out $DL_REMOTE/$DL_BASE"
git for-each-ref --format='%(refname:strip=2)' refs/heads | while read -r ref; do # (a ref glob stops at "/")
  [[ "$ref" == train-* && "$keep_train" != *" ${ref#train-} "* ]] && dl_loop_branch "${ref#train-}" &&
    git branch -q -D "$ref" >/dev/null 2>&1
done

base_ref="$DL_REMOTE/$DL_BASE"
previous=""
records=""

# upstream_of BRANCH: the commit after which the branch's own commits start.
upstream_of() {
  if [ -n "$previous" ] && git merge-base --is-ancestor "$DL_REMOTE/$previous" "$DL_REMOTE/$1"; then
    git rev-parse "$DL_REMOTE/$previous"
  else
    git merge-base "$DL_REMOTE/$1" "$DL_REMOTE/$DL_BASE"
  fi
}

for branch in "$@"; do
  git rev-parse -q --verify "$DL_REMOTE/$branch^{commit}" >/dev/null ||
    dl_die "$DL_REMOTE/$branch does not exist (push the branch first)"
  source_head=$(git rev-parse "$DL_REMOTE/$branch")
  git branch -q -f "train-$branch" "$source_head"
  git checkout -q "train-$branch"
  if ! git rebase -q --onto "$base_ref" "$(upstream_of "$branch")" >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1
    git checkout -q --detach "$DL_REMOTE/$DL_BASE"
    echo "TRAIN rebase conflict at $branch"
    exit 3
  fi
  base_ref="train-$branch"
  previous=$branch
  records+="$branch $source_head $(git rev-parse HEAD) pending"$'\n'
  echo "stacked $branch -> $(git rev-parse --short HEAD)"
done

if [ -n "$(cfg affected "")" ]; then
  DL_CHANGED_FILES="$logs/train-changed-files.txt"
  git diff --name-only --no-renames "$DL_REMOTE/$DL_BASE" HEAD >"$DL_CHANGED_FILES" ||
    dl_die "cannot list the changed files"
  export DL_CHANGED_FILES
fi

setup=$(cfg gate_setup "")
if [ -n "$setup" ]; then
  if ! bash -c "$setup" >"$logs/train-setup.log" 2>&1; then
    echo "gate_setup failed (log: $logs/train-setup.log)"
    echo "TRAIN RED"
    exit 1
  fi
fi

# entry_field PATH FIELD DEFAULT: a field of the check entry at PATH; a plain string entry is its command.
entry_field() {
  local entry
  entry=$(cfg "$1" "")
  case "$entry" in
    "{"*) cfg "$1.$2" "$3" ;;
    *) if [ "$2" = command ]; then printf '%s\n' "$entry"; else printf '%s\n' "$3"; fi ;;
  esac
}

# The stages in order: the affected stage (if configured) first, then the checks.
names=() commands=() heavies=() patterns=() results=() pids=()
add_stage() { # add_stage CONFIG_PATH DEFAULT_NAME
  names+=("$(entry_field "$1" name "$2")")
  commands+=("$(entry_field "$1" command "")")
  heavies+=("$(entry_field "$1" heavy true)")
  patterns+=("$(entry_field "$1" summary "")")
  results+=("")
  pids+=("")
}
first_check=0
if [ -n "$(cfg affected "")" ]; then
  add_stage affected affected
  first_check=1
fi
count=$(cfg_len checks)
for ((i = 0; i < count; i++)); do add_stage "checks.$i" "check-$((i + 1))"; done
stages=${#names[@]}
parallel=$(cfg parallel false)
fail_fast=$(cfg fail_fast false)
grace=${DEV_LOOP_STOP_GRACE_SECONDS:-10}
failed=""

log_of() { printf '%s/train-%s.log\n' "$logs" "${names[$1]//[^A-Za-z0-9_.-]/_}"; }

# stage_command INDEX: the argv that runs a stage (heavy stages through heavy.sh).
stage_command() {
  if [ "${heavies[$1]}" = false ]; then
    stage_argv=(bash -c "${commands[$1]}")
  else
    stage_argv=("$scripts_dir/heavy.sh" bash -c "${commands[$1]}")
  fi
}

# result_line INDEX: the line printed for a stage's outcome.
result_line() {
  case "${results[$1]}" in
    skipped) echo "${names[$1]} skipped" ;;
    stopped) echo "${names[$1]} stopped (log: $(log_of "$1"))" ;;
    *) echo "${names[$1]} ${results[$1]} (log: $(log_of "$1"))" ;;
  esac
}

# record INDEX RC: store a stage's exit status; a failure under fail_fast stops the train.
record() {
  results[$1]="rc=$2"
  if [ "$2" -ne 0 ]; then
    all_green=""
    [ "$fail_fast" = true ] && failed=yes
  fi
}

# run_sequential FROM TO: run stages FROM..TO-1 one after the other, printing each result as it ends.
run_sequential() {
  local i
  for ((i = $1; i < $2; i++)); do
    if [ -n "$failed" ]; then
      results[i]=skipped
    else
      stage_command "$i"
      "${stage_argv[@]}" >"$(log_of "$i")" 2>&1
      record "$i" $?
    fi
    result_line "$i"
  done
}

# new_session COMMAND...: replace this (background) shell with the command as the leader of a new session,
# so its process group id is the background job's pid ($!).
new_session() {
  if command -v setsid >/dev/null 2>&1; then
    exec setsid "$@"
  else
    exec perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"' -- "$@"
  fi
}

# collect INDEX: if the stage's process has ended, record its status (bash keeps it for wait).
collect() {
  [ -n "${pids[$1]}" ] || return 1
  kill -0 "${pids[$1]}" 2>/dev/null && return 1
  wait "${pids[$1]}"
  record "$1" $?
  pids[$1]=""
}

# stop_running: stop every running stage's process group (TERM, then KILL after the grace period). A stage
# whose process still ended with 0 (it had finished when the TERM came) keeps rc=0 instead of "stopped".
stop_running() {
  local i deadline alive
  for ((i = 0; i < stages; i++)); do
    [ -n "${pids[i]}" ] || continue
    collect "$i" && continue
    kill -TERM -- "-${pids[i]}" 2>/dev/null
    results[i]=stopped
    all_green=""
  done
  deadline=$(($(date +%s) + grace))
  while true; do
    alive=""
    for ((i = 0; i < stages; i++)); do
      [ "${results[i]}" = stopped ] && kill -0 -- "-${pids[i]}" 2>/dev/null && alive=yes
    done
    [ -n "$alive" ] && [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 0.2
  done
  for ((i = 0; i < stages; i++)); do
    [ "${results[i]}" = stopped ] || continue
    kill -KILL -- "-${pids[i]}" 2>/dev/null
    wait "${pids[i]}" 2>/dev/null && results[i]="rc=0"
    pids[i]=""
  done
}

# interrupted FROM TO: this script got a signal while stages FROM..TO-1 ran: stop them, report, exit red.
# shellcheck disable=SC2329  # called from the signal trap in run_parallel
interrupted() {
  local i
  stop_running
  for ((i = $1; i < $2; i++)); do [ -z "${results[i]}" ] || result_line "$i"; done
  git checkout -q --detach "$DL_REMOTE/$DL_BASE"
  echo "TRAIN RED"
  exit 1
}

# run_parallel FROM TO: start stages FROM..TO-1 at once, each in its own process group; wait for all,
# or stop the rest after the first failure under fail_fast; then print the results in config order.
run_parallel() {
  local i running
  # shellcheck disable=SC2064  # the range is expanded now on purpose
  trap "interrupted $1 $2" TERM INT HUP
  for ((i = $1; i < $2; i++)); do
    if [ -n "$failed" ]; then
      results[i]=skipped
      continue
    fi
    stage_command "$i"
    new_session "${stage_argv[@]}" </dev/null >"$(log_of "$i")" 2>&1 &
    pids[i]=$!
  done
  while true; do
    running=""
    for ((i = $1; i < $2; i++)); do
      collect "$i" || { [ -n "${pids[i]}" ] && running=yes; }
    done
    if [ -n "$failed" ] && [ -n "$running" ]; then
      echo "fail_fast: a check failed, stopping the others"
      stop_running
      running=""
    fi
    [ -n "$running" ] || break
    sleep 0.5
  done
  trap - TERM INT HUP
  for ((i = $1; i < $2; i++)); do result_line "$i"; done
}

all_green=yes
run_sequential 0 "$first_check"
if [ "$parallel" = true ]; then
  run_parallel "$first_check" "$stages"
else
  run_sequential "$first_check" "$stages"
fi

summary=""
for ((i = 0; i < stages; i++)); do
  case "${results[i]}" in rc=*) ;; *) continue ;; esac
  log=$(log_of "$i")
  if [ -n "${patterns[i]}" ]; then
    summary+="$(grep -E -- "${patterns[i]}" "$log" | tail -n 3)"$'\n'
  else
    summary+="$(tail -n 2 "$log")"$'\n'
  fi
done
printf '%s' "$summary" | sed '/^$/d'

git checkout -q --detach "$DL_REMOTE/$DL_BASE"
if [ -n "$all_green" ]; then
  printf '%s' "$records" >"$train_file"
  echo "TRAIN GREEN"
  exit 0
fi
echo "TRAIN RED"
exit 1
