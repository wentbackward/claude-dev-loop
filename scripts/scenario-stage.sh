#!/usr/bin/env bash
# The gate's scenario stage: judge the gated tree against the holdout scenarios (scenarios in .dev-loop.json).
#
# Usage: scenario-stage.sh   (gate-train.sh runs it in the gate worktree, on the train's top)
#
# Picks the scenarios of the store (with "affected": those whose spec or tags occur in a path of
# DL_CHANGED_FILES, plus every required one), starts scenarios.run in its own process group and takes the
# first line it prints as the address of the system, then runs the judge command (scenarios.judge, default
# the scenario-judge agent) once per scenario with DL_SCENARIO_FILE, DL_SCENARIO_ID and DL_SCENARIO_TARGET.
# A scenario below scenarios.pass, or with invalid judge output, is judged once more; its better run counts.
# Green needs every required scenario at >= pass and the mean at >= scenarios.min_satisfaction.
#
# The output never holds scenario text: an unsatisfied scenario is named with the judge's "missing" line, and
# the sealed share (scenarios.sealed, chosen by id) is only counted. A judge that runs longer than
# scenarios.judge_seconds (default 600) is stopped and counts as invalid. Each judge result is recorded in
# train-scenario-results.jsonl in the logs directory, the judge's own output in train-scenario-judge/, the
# output of scenarios.run in train-scenarios-run.log. The system and a running judge are stopped (their
# process groups, KILL after 2 s) when the stage ends, also on SIGTERM, SIGINT or SIGHUP.
#
# Exit: 0 green, 1 red, 2 config error.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
# shellcheck source=lib/reasons.sh
. "$scripts_dir/lib/reasons.sh"
# shellcheck source=lib/scenarios.sh
. "$scripts_dir/lib/scenarios.sh"
dl_load_config required

pass=$(cfg scenarios.pass 0.8)
min_satisfaction=$(cfg scenarios.min_satisfaction 0.9)
sealed_share=$(cfg scenarios.sealed 0)
for value in "$pass" "$min_satisfaction" "$sealed_share"; do
  dl_scenarios_share_ok "$value" ||
    { echo "scenarios error: a threshold is not a number from 0 to 1 (doctor.sh names it)"; exit 2; }
done
run_seconds=$(cfg scenarios.run_seconds 120)
judge_seconds=$(cfg scenarios.judge_seconds 600)
for value in "$run_seconds" "$judge_seconds"; do
  case $value in
    "" | *[!0-9]*) echo "scenarios error: run_seconds and judge_seconds must be whole seconds"; exit 2 ;;
  esac
done
logs=$(dl_logs_dir)
results="$logs/train-scenario-results.jsonl"
judge_dir="$logs/train-scenario-judge"
run_log="$logs/train-scenarios-run.log"
mkdir -p "$logs" || exit 2
rm -rf "$judge_dir" && rm -f "$results" "$run_log" && mkdir -p "$judge_dir" || exit 2
store=$(dl_scenarios_dir)
judge=$(dl_scenarios_judge_command)
run_pid="" judge_pid=""

# selected_scenarios: the scenario files to judge, one per line.
selected_scenarios() {
  local file
  while IFS= read -r file; do
    if [ -n "${DL_CHANGED_FILES:-}" ] && [ "$(dl_scenario_field "$file" required)" != true ] &&
      ! dl_scenario_affected "$file" "$DL_CHANGED_FILES"; then
      continue
    fi
    printf '%s\n' "$file"
  done < <(dl_scenarios_files "$store")
}

# stop_groups PID...: stop these process groups (TERM, then KILL after 2 s), well inside the gate's grace
# period (DEV_LOOP_STOP_GRACE_SECONDS, default 10) when the gate stops this stage.
stop_groups() {
  local pid alive
  for pid in "$@"; do kill -TERM -- "-$pid" 2>/dev/null; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    alive=""
    for pid in "$@"; do kill -0 -- "-$pid" 2>/dev/null && alive=yes; done
    [ -n "$alive" ] || return 0
    sleep 0.2
  done
  for pid in "$@"; do kill -KILL -- "-$pid" 2>/dev/null; done
}

# stop_all: stop the running judge and the system scenarios.run started.
stop_all() {
  # shellcheck disable=SC2086  # the empty ones drop out on purpose
  [ -z "$run_pid$judge_pid" ] || stop_groups $run_pid $judge_pid
  run_pid="" judge_pid=""
}
trap stop_all EXIT
trap 'exit 1' TERM INT HUP

# start_system: start scenarios.run in its own process group and set target to the first line it prints;
# without scenarios.run the target is empty. Red when it ends or times out before printing a line.
start_system() {
  local run deadline
  target=""
  run=$(cfg scenarios.run "")
  [ -n "$run" ] || return 0
  dl_new_session bash -c "$run" </dev/null >"$run_log" 2>&1 &
  run_pid=$!
  deadline=$(($(date +%s) + run_seconds))
  while true; do
    target=$(grep -m 1 '[^[:space:]]' "$run_log" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$target" ] && break
    if ! kill -0 "$run_pid" 2>/dev/null; then
      target=$(grep -m 1 '[^[:space:]]' "$run_log" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -n "$target" ] && break
      echo "scenarios red: scenarios.run ended before printing how to reach the system (log: $run_log)"
      return 1
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "scenarios red: scenarios.run printed nothing in $run_seconds s (log: $run_log)"
      return 1
    fi
    sleep 0.2
  done
  echo "scenarios run: $target"
}

# judge_once FILE ID SEALED RUN: run the judge on one scenario in its own process group (stopped after
# scenarios.judge_seconds) and record its result; sets verdict to the line of dl_scenario_verdict.
judge_once() {
  local out="$judge_dir/$4.out" rc deadline record
  DL_SCENARIO_FILE=$1 DL_SCENARIO_ID=$2 DL_SCENARIO_TARGET=$target \
    dl_new_session bash -c "$judge" </dev/null >"$out" 2>"$judge_dir/$4.err" &
  judge_pid=$!
  deadline=$(($(date +%s) + judge_seconds))
  while kill -0 "$judge_pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.2; done
  if kill -0 "$judge_pid" 2>/dev/null; then
    stop_groups "$judge_pid"
    wait "$judge_pid" 2>/dev/null
    verdict=$(printf 'invalid\tthe judge ran longer than %s s' "$judge_seconds")
  else
    wait "$judge_pid"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      verdict=$(printf 'invalid\tthe judge exited with %s' "$rc")
    else
      verdict=$(dl_scenario_verdict "$2" <"$out")
    fi
  fi
  judge_pid=""
  if [ "${verdict%%$'\t'*}" = ok ]; then
    record="\"valid\": true, \"result\": ${verdict##*$'\t'}, \"error\": null"
  else
    record="\"valid\": false, \"result\": null, \"error\": $(dl_json_string "${verdict#*$'\t'}")"
  fi
  printf '{"scenario": %s, "run": "%s", "sealed": %s, %s}\n' "$(dl_json_string "$2")" "$4" "$3" "$record" >>"$results"
}

# score_of VERDICT: the satisfied value of a verdict line, 0 when it is invalid.
score_of() {
  case $1 in ok*) printf '%s\n' "$1" | cut -f2 ;; *) echo 0 ;; esac
}

# reason_of VERDICT: what an unsatisfied verdict tells the implementer: the missing behaviour, never the
# scenario text.
reason_of() {
  local missing
  case $1 in
    ok*)
      missing=$(printf '%s\n' "$1" | cut -f3)
      printf '%s\n' "${missing:-the judge named no missing behaviour}"
      ;;
    *) printf 'invalid judge output (%s)\n' "${1#*$'\t'}" ;;
  esac
}

files=$(selected_scenarios)
invalid=$(dl_scenarios_validate "$store" | cut -f1 | sort -u | grep -c .)
if [ "$invalid" -gt 0 ]; then
  echo "scenarios red: $invalid invalid scenario file(s) in the store (doctor.sh names them)"
  exit 1
fi
if [ "$(dl_factory)" = dark ] && ! dl_scenarios_ready "$store"; then
  echo "scenarios red: factory dark needs a scenario store with at least one valid required scenario ($store)"
  exit 1
fi
if [ -z "$files" ]; then
  echo "scenarios green: 0 judged (no scenario to judge in $store)"
  exit 0
fi
start_system || exit 1

judged=0 sum=0 required_red=0 sealed_judged=0 sealed_red=0 index=0
while IFS= read -r file; do
  index=$((index + 1))
  id=$(dl_scenario_field "$file" id)
  required=$(dl_scenario_field "$file" required)
  sealed=false
  dl_scenario_sealed "$id" "$sealed_share" && sealed=true && sealed_judged=$((sealed_judged + 1))
  judge_once "$file" "$id" "$sealed" "$index-1"
  best=$verdict
  if ! dl_scenarios_at_least "$(score_of "$best")" "$pass"; then
    judge_once "$file" "$id" "$sealed" "$index-2"
    dl_scenarios_at_least "$(score_of "$best")" "$(score_of "$verdict")" || best=$verdict
  fi
  score=$(score_of "$best")
  judged=$((judged + 1))
  sum=$(awk -v a="$sum" -v b="$score" 'BEGIN { print a + b }')
  kind=scored
  [ "$required" = true ] && kind=required
  if dl_scenarios_at_least "$score" "$pass"; then
    [ "$sealed" = true ] || echo "scenario $id satisfied ($score, $kind)"
    continue
  fi
  [ "$kind" = required ] && required_red=$((required_red + 1))
  if [ "$sealed" = true ]; then
    sealed_red=$((sealed_red + 1))
  else
    echo "scenario $id unsatisfied ($score, $kind): $(reason_of "$best")"
  fi
done <<<"$files"
stop_all

[ "$sealed_judged" -eq 0 ] || echo "scenarios sealed: $sealed_judged judged, $sealed_red unsatisfied"
mean=$(awk -v s="$sum" -v n="$judged" 'BEGIN { print s / n }')
mean_text="mean $(awk -v m="$mean" 'BEGIN { printf "%.2f", m }')"
if [ "$required_red" -eq 0 ] && dl_scenarios_at_least "$mean" "$min_satisfaction"; then
  echo "scenarios green: $judged judged, $mean_text"
  exit 0
fi
dl_scenarios_at_least "$mean" "$min_satisfaction" || mean_text+=" below min_satisfaction $min_satisfaction"
echo "scenarios red: $judged judged, $required_red required unsatisfied, $mean_text"
exit 1
