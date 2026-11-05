#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # pass/fail never fail; single quotes are expanded by the inner shell
# Smoke test of the plugin's hooks and scripts on a throwaway project with a local bare origin.
# No network, no real GitHub: `gh` is tests/fake-gh. Run: tests/smoke.sh   (TMPDIR picks the work dir)
set -u
plugin=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-smoke.XXXXXX")
export DEV_LOOP_HOME="$work/home" DEV_LOOP_LOCK_DIR="$work/locks" DEV_LOOP_GH_SETTLE_SECONDS=0 DEV_LOOP_STOP_GRACE_SECONDS=2
export FAKE_GH_DIR="$work/gh" GIT_CONFIG_GLOBAL="$work/gitconfig" SMOKE_WORK="$work"
git config --global user.name tester
git config --global user.email tester@example.invalid
git config --global init.defaultBranch main
mkdir -p "$work/bin" && ln -s "$plugin/tests/fake-gh" "$work/bin/gh"
export PATH="$work/bin:$PATH"

passed=0
failed=0
pass() { echo "PASS $*"; passed=$((passed + 1)); }
fail() { echo "FAIL $*"; failed=$((failed + 1)); }
expect() { # expect DESCRIPTION EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# The project: one source file, a check that fails when the source contains BROKEN.
git init -q --bare "$work/origin.git"
git clone -q "$work/origin.git" "$work/project" 2>/dev/null
cd "$work/project" || exit 1
cat >check.sh <<'EOF'
#!/usr/bin/env bash
echo "port=${SMOKE_PORT:-unset} slot=${DEV_LOOP_SLOT:-unset}"
! grep -q BROKEN src.txt && echo "3 passed"
EOF
chmod +x check.sh
echo "line one" >src.txt
git add . && git commit -q -m "chore: start" && git push -q origin main

# 1. Hooks without config are no-ops.
edit_input='{"tool_input":{"file_path":"'"$work/project/src.txt"'"}}'
printf '%s' "$edit_input" | "$plugin/hooks/format-on-edit.sh"
expect "format hook without config exits 0" 0 $?
[ ! -e fmt.log ] && pass "format hook without config runs nothing" || fail "format hook ran without config"
echo dirty >dirty.txt
echo '{}' | CLAUDE_PROJECT_DIR="$work/project" "$plugin/hooks/stop-gate.sh" 2>/dev/null
expect "stop gate without config exits 0 on a dirty tree" 0 $?
rm dirty.txt

# 2. Hooks with config run the configured commands.
cat >.dev-loop.json <<'EOF'
{
  "base_branch": "main",
  "fast_check": "test ! -e fast-fail",
  "format": "echo formatted {file} >> fmt.log",
  "format_extensions": [".txt"],
  "checks": [
    {"name": "unit", "command": "./check.sh", "summary": "passed|failed"},
    {"name": "lint", "command": "test -x check.sh", "heavy": false}
  ],
  "heavy": {"slots": 2, "port_env": "SMOKE_PORT", "port_base": 9100, "port_step": 10, "poll_seconds": 1}
}
EOF
printf 'fmt.log\nfast-fail\n' >.gitignore
git add . && git commit -q -m "chore: dev-loop config" && git push -q origin main
printf '%s' "$edit_input" | "$plugin/hooks/format-on-edit.sh"
grep -q "formatted $work/project/src.txt" fmt.log 2>/dev/null && pass "format hook runs the format command" ||
  fail "format hook did not run the format command"
printf '%s' '{"tool_input":{"file_path":"'"$work/project/check.sh"'"}}' | "$plugin/hooks/format-on-edit.sh"
expect "format hook skips other extensions" 1 "$(wc -l <fmt.log | tr -d ' ')"

stop() { echo '{}' | CLAUDE_PROJECT_DIR="$work/project" "$plugin/hooks/stop-gate.sh" 2>/dev/null; echo $?; }
expect "stop gate passes on a clean tree with a green fast check" 0 "$(stop)"
touch fast-fail
expect "stop gate blocks on a red fast check" 2 "$(stop)"
for _ in 2 3 4 5; do stop >/dev/null; done
expect "stop gate lets Claude stop after 5 blocks" 0 "$(stop)"
rm fast-fail
echo dirty >dirty.txt
expect "stop gate blocks on uncommitted work" 2 "$(stop)"
rm dirty.txt
expect "stop gate passes again once clean" 0 "$(stop)"

# 3. heavy.sh: a distinct port per slot, and a third command waits while two hold both slots.
expect "heavy.sh exports the slot port" "9110" "$("$plugin/scripts/heavy.sh" bash -c 'echo $SMOKE_PORT' 2>/dev/null)"
start=$(date +%s)
for n in 1 2 3; do
  "$plugin/scripts/heavy.sh" bash -c "echo start $n \$(date +%s) slot \$DEV_LOOP_SLOT; sleep 3; echo end $n \$(date +%s)" \
    >"$work/heavy-$n.out" 2>"$work/heavy-$n.err" &
  sleep 0.3
done
wait
cat "$work"/heavy-*.out
grep -q "all 2 slots busy" "$work/heavy-3.err" && pass "third heavy command reports that it waits" ||
  fail "third heavy command did not wait"
third_start=$(awk '/^start 3/ {print $3}' "$work/heavy-3.out")
first_end=$(awk '/^end 1/ {print $3}' "$work/heavy-1.out")
[ -n "$third_start" ] && [ "$third_start" -ge "$first_end" ] && pass "third heavy command starts only after a slot frees" ||
  fail "third heavy command started at $third_start before the first ended at $first_end"
echo "heavy: 3 commands of 3 s on 2 slots took $(($(date +%s) - start)) s"
# A killed heavy command whose server escaped into its own session must not keep the slot.
setsid "$plugin/scripts/heavy.sh" bash -c \
  'setsid sleep 30 </dev/null >/dev/null 2>&1 & echo $! >"$SMOKE_WORK/stray.pid"; exec sleep 30' >/dev/null 2>&1 &
heavy_group=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$work/stray.pid" ] && break; sleep 0.3; done
kill -TERM -- "-$heavy_group" 2>/dev/null
wait "$heavy_group" 2>/dev/null
expect "a killed heavy command's escaped server does not hold its slot" "9110" \
  "$("$plugin/scripts/heavy.sh" bash -c 'echo $SMOKE_PORT' 2>/dev/null)"
kill "$(cat "$work/stray.pid")" 2>/dev/null

# 4. gate-train.sh stacks two branches (the second built on the first) and runs the checks once.
git checkout -q -b feat/1-first
echo "line two" >>src.txt && git commit -q -am "feat: second line (Refs #1)" && git push -q -u origin feat/1-first
git checkout -q -b feat/2-second
echo "other" >other.txt && git add other.txt && git commit -q -m "feat: other file (Refs #2)" && git push -q -u origin feat/2-second
git checkout -q main
echo "README" >README && git add README && git commit -q -m "docs: readme" && git push -q origin main
notes=$("$plugin/scripts/paths.sh" notes-dir)
mkdir -p "$notes"
printf '# feat: second line (#1)\n\n## Summary\n- adds a line\n\nCloses #1\n' >"$("$plugin/scripts/paths.sh" notes feat/1-first)"
printf 'feat: other file (#2)\n\nCloses #2\n' >"$("$plugin/scripts/paths.sh" notes feat/2-second)"

out=$("$plugin/scripts/gate-train.sh" feat/1-first feat/2-second 2>&1)
rc=$?
echo "$out"
expect "gate-train is green for two good branches" 0 "$rc"
gate=$("$plugin/scripts/paths.sh" gate)
expect "train-feat/2-second carries only the two branch commits on main" 2 \
  "$(git -C "$gate" rev-list --count origin/main..train-feat/2-second)"
echo "$out" | grep -q "^3 passed" && pass "gate prints the check summary" || fail "no check summary"

# 5. merge-train.sh merges in order with the fake gh and strips a leading '#' from the title.
out=$("$plugin/scripts/merge-train.sh" feat/1-first feat/2-second 2>&1)
rc=$?
echo "$out"
expect "merge-train merges the green train" 0 "$rc"
git fetch -q origin
expect "origin main has both squash commits" "feat: other file (#2)|feat: second line (#1)" \
  "$(git log --format=%s -2 origin/main | paste -sd'|')"
expect "PR title has no leading '#'" "feat: second line (#1)" "$(cat "$FAKE_GH_DIR/feat_1-first.title")"
grep -q "Closes #1" "$FAKE_GH_DIR/feat_1-first.body" && pass "PR body is the rest of the notes file" || fail "PR body"
git ls-remote --exit-code origin feat/1-first >/dev/null 2>&1 && fail "merged branch not deleted" ||
  pass "merged branches are deleted on origin"
expect "merged branches are deleted locally" "" "$(git branch --list feat/1-first feat/2-second)"
expect "the train refs go once the whole train merged" "" "$(git branch --list 'train-feat/*')"
expect "the notes files move to notes/merged" "pr-feat_1-first.md pr-feat_2-second.md" \
  "$(for f in "$notes"/merged/pr-*.md; do basename "$f"; done | paste -sd' ')"
expect "the ledger records both merges with their PR numbers" "feat/1-first 1|feat/2-second 2" \
  "$(jq -r '"\(.branch) \(.pr)"' "$DEV_LOOP_HOME/project/merged.jsonl" | paste -sd'|')"

# 6. A red train is reported red and cannot be merged.
git checkout -q -B feat/3-broken origin/main
echo BROKEN >>src.txt && git commit -q -am "feat: break it (Refs #3)" && git push -q -u origin feat/3-broken
printf 'feat: break it (#3)\n\nCloses #3\n' >"$("$plugin/scripts/paths.sh" notes feat/3-broken)"
"$plugin/scripts/gate-train.sh" feat/3-broken >/dev/null 2>&1
expect "gate-train is red for a failing check" 1 $?
"$plugin/scripts/merge-train.sh" feat/3-broken >/dev/null 2>&1
expect "merge-train refuses a red train" 8 $?

# 7. The tree check: base moved after the gate -> the replayed tree differs -> refuse (re-gate).
git checkout -q -B feat/4-ok origin/main
echo ok >ok.txt && git add ok.txt && git commit -q -m "feat: ok (Refs #4)" && git push -q -u origin feat/4-ok
printf 'feat: ok (#4)\n\nCloses #4\n' >"$("$plugin/scripts/paths.sh" notes feat/4-ok)"
"$plugin/scripts/gate-train.sh" feat/4-ok >/dev/null 2>&1
expect "gate-train is green for feat/4-ok" 0 $?
git checkout -q -B side origin/main
echo moved >moved.txt && git add moved.txt && git commit -q -m "chore: main moved" && git push -q origin side:main
"$plugin/scripts/merge-train.sh" feat/4-ok >/dev/null 2>&1
expect "merge-train refuses when the tree differs from the gated one" 4 $?

# 8. The branch changed after the gate -> refuse.
"$plugin/scripts/gate-train.sh" feat/4-ok >/dev/null 2>&1
git checkout -q feat/4-ok && echo more >>ok.txt && git commit -q -am "feat: more (Refs #4)" && git push -q origin feat/4-ok
"$plugin/scripts/merge-train.sh" feat/4-ok >/dev/null 2>&1
expect "merge-train refuses a branch that changed since the gate" 6 $?

# 9. A rebase conflict names the branch.
git checkout -q -B feat/5-conflict origin/main~1
echo conflict >moved.txt && git add moved.txt && git commit -q -m "feat: conflict (Refs #5)" && git push -q -u origin feat/5-conflict
out=$("$plugin/scripts/gate-train.sh" feat/5-conflict 2>&1)
expect "gate-train stops on a conflict and names the branch" "3 TRAIN rebase conflict at feat/5-conflict" "$? $(echo "$out" | tail -1)"

# 10. Gate options (affected, parallel, fail_fast), each with its own config through DEV_LOOP_CONFIG.
git fetch -q origin
git checkout -q -B feat/6-fast origin/main
echo fast >fast.txt && echo "line three" >>src.txt && git add fast.txt src.txt &&
  git commit -q -m "feat: fast (Refs #6)" && git push -q -u origin feat/6-fast
# gate_with JSON_MEMBERS: gate feat/6-fast with these config members; sets out, rc and elapsed (seconds).
gate_with() {
  printf '{"base_branch": "main", %s, "heavy": {"slots": 2, "port_env": "SMOKE_PORT", "port_base": 9100, "port_step": 10, "poll_seconds": 1}}\n' \
    "$1" >"$work/gate.json"
  rm -f "$work"/order.log "$work"/changed.txt "$work"/marker "$work"/slow.pids
  local start
  start=$(date +%s)
  out=$(DEV_LOOP_CONFIG="$work/gate.json" "$plugin/scripts/gate-train.sh" feat/6-fast 2>&1)
  rc=$?
  elapsed=$(($(date +%s) - start))
  echo "$out"
  echo "(gate took $elapsed s)"
}
result_lines() { echo "$out" | grep -E '^[A-Za-z0-9_.-]+ (rc=[0-9]+|stopped|skipped)' | cut -d' ' -f1-2 | paste -sd'|'; }
alive() { # alive PID...: the PIDs still running, space separated
  local pid living=""
  for pid in "$@"; do kill -0 "$pid" 2>/dev/null && living+="$pid "; done
  printf '%s' "${living% }"
}

# Defaults: the checks run one after the other, all of them, even after a failure.
gate_with '"checks": [
  {"name": "a", "command": "sleep 3; echo a-done changed=${DL_CHANGED_FILES:-unset}"},
  {"name": "b", "command": "exit 3", "heavy": false},
  {"name": "c", "command": "sleep 3; echo c-done"}]'
expect "default gate runs every check in order, even after a failure" "a rc=0|b rc=3|c rc=0" "$(result_lines)"
expect "default gate is red with exit 1" "1 TRAIN RED" "$rc $(echo "$out" | tail -1)"
[ "$elapsed" -ge 6 ] && pass "default gate runs the checks sequentially" || fail "default gate took $elapsed s (< 6)"
logs=$("$plugin/scripts/paths.sh" logs)
grep -q "a-done changed=unset" "$logs/train-a.log" && [ ! -e "$logs/train-changed-files.txt" ] &&
  pass "default gate lists no changed files" || fail "default gate computed DL_CHANGED_FILES"

# affected: runs first (through heavy.sh), gets the changed files, and its summary is printed.
gate_with '"parallel": true,
  "affected": {"command": "echo affected >>\"$SMOKE_WORK/order.log\"; cp \"$DL_CHANGED_FILES\" \"$SMOKE_WORK/changed.txt\"; echo \"2 affected passed\"", "summary": "affected passed"},
  "checks": [{"name": "unit", "command": "sleep 1; echo unit >>\"$SMOKE_WORK/order.log\"", "heavy": false},
             {"name": "e2e", "command": "sleep 1; echo e2e >>\"$SMOKE_WORK/order.log\""}]'
expect "affected gate is green" "0 TRAIN GREEN" "$rc $(echo "$out" | tail -1)"
expect "affected runs before the checks" "affected" "$(head -1 "$work/order.log" 2>/dev/null)"
expect "affected gets the files the train changes" "fast.txt|src.txt" "$(sort "$work/changed.txt" 2>/dev/null | paste -sd'|')"
expect "affected is reported first, then the checks in config order" "affected rc=0|unit rc=0|e2e rc=0" "$(result_lines)"
echo "$out" | grep -q "^2 affected passed" && pass "affected summary is printed" || fail "no affected summary"
grep -q '^\[heavy.sh\] slot' "$("$plugin/scripts/paths.sh" logs)/train-affected.log" 2>/dev/null &&
  pass "affected runs through heavy.sh by default" || fail "affected did not run through heavy.sh"

# affected as a plain command string.
gate_with '"affected": "cp \"$DL_CHANGED_FILES\" \"$SMOKE_WORK/changed.txt\"", "checks": [{"name": "unit", "command": "true", "heavy": false}]'
expect "a plain-string affected runs first with the changed files" "0 affected rc=0|unit rc=0 fast.txt|src.txt" \
  "$rc $(result_lines) $(sort "$work/changed.txt" 2>/dev/null | paste -sd'|')"

# affected fails without fail_fast: the checks still run, the train is red.
gate_with '"affected": "exit 5", "checks": [{"name": "unit", "command": "touch \"$SMOKE_WORK/marker\"", "heavy": false}]'
expect "failed affected without fail_fast still runs the checks" "1 TRAIN RED yes" \
  "$rc $(echo "$out" | tail -1) $([ -e "$work/marker" ] && echo yes || echo no)"

# affected fails with fail_fast: nothing else runs.
gate_with '"fail_fast": true, "affected": {"command": "exit 5", "heavy": false},
  "checks": [{"name": "unit", "command": "touch \"$SMOKE_WORK/marker\"", "heavy": false}]'
expect "failed affected with fail_fast is red with exit 1" "1 TRAIN RED" "$rc $(echo "$out" | tail -1)"
[ ! -e "$work/marker" ] && pass "failed affected with fail_fast stops the train" || fail "a check ran after affected failed"
expect "failed affected with fail_fast reports the skipped checks" "affected rc=5|unit skipped" "$(result_lines)"

# parallel: the checks overlap, each heavy one in its own slot (own port), every log is written.
gate_with '"parallel": true, "checks": [
  {"name": "a", "command": "sleep 3; echo a-done port=$SMOKE_PORT"},
  {"name": "c", "command": "sleep 3; echo c-done port=$SMOKE_PORT"},
  {"name": "n", "command": "sleep 3; echo n-done", "heavy": false}]'
expect "parallel gate is green" "0 TRAIN GREEN" "$rc $(echo "$out" | tail -1)"
[ "$elapsed" -lt 6 ] && pass "parallel checks overlap ($elapsed s for three 3 s checks)" ||
  fail "parallel gate took $elapsed s (>= 6)"
expect "parallel results are reported in config order" "a rc=0|c rc=0|n rc=0" "$(result_lines)"
logs=$("$plugin/scripts/paths.sh" logs)
expect "parallel checks each write their own log" "a-done|c-done|n-done" \
  "$(cat "$logs/train-a.log" "$logs/train-c.log" "$logs/train-n.log" 2>/dev/null | grep -o '^[acn]-done' | paste -sd'|')"
ports=$(cat "$logs/train-a.log" "$logs/train-c.log" 2>/dev/null | grep -o 'port=[0-9][0-9]*' | sort -u | wc -l | tr -d ' ')
expect "parallel heavy checks run in separate slots" 2 "$ports"
expect "a green parallel train is recorded for merge-train" "feat/6-fast pending" \
  "$(awk '{print $1, $4}' "$DEV_LOOP_HOME/project/train-green.txt" 2>/dev/null)"

# parallel without fail_fast: a failure does not stop the others.
gate_with '"parallel": true, "checks": [
  {"name": "x", "command": "sleep 2; echo x-done", "heavy": false},
  {"name": "y", "command": "exit 4", "heavy": false}]'
expect "parallel gate without fail_fast lets the others finish" "1 x rc=0|y rc=4" "$rc $(result_lines)"

# parallel + fail_fast: a failure stops a long sibling, its children (even one ignoring SIGTERM) and heavy.sh.
gate_with '"parallel": true, "fail_fast": true, "checks": [
  {"name": "slow", "command": "echo $$ $PPID >\"$SMOKE_WORK/slow.pids\"; (trap \"\" TERM; exec sleep 300) & echo $! >>\"$SMOKE_WORK/slow.pids\"; sleep 300 & echo $! >>\"$SMOKE_WORK/slow.pids\"; wait"},
  {"name": "quiet", "command": "trap \"exit 0\" TERM; sleep 300 & wait", "heavy": false},
  {"name": "bad", "command": "sleep 1; exit 3", "heavy": false}]'
expect "fail_fast gate is red with exit 1" "1 TRAIN RED" "$rc $(echo "$out" | tail -1)"
expect "fail_fast reports the failure, the stopped sibling and one that ended with 0" \
  "slow stopped|quiet rc=0|bad rc=3" "$(result_lines)"
[ "$elapsed" -lt 10 ] && pass "fail_fast stops the sibling promptly ($elapsed s)" || fail "fail_fast took $elapsed s"
# shellcheck disable=SC2046  # the pid list splits on purpose
expect "fail_fast leaves no process of the stopped check behind" "" "$(alive $(cat "$work/slow.pids" 2>/dev/null))"
[ -s "$work/slow.pids" ] && pass "the stopped check had started" || fail "the slow check never started"
expect "fail_fast leaves no heavy slot held" "9110" \
  "$(DEV_LOOP_CONFIG="$work/gate.json" "$plugin/scripts/heavy.sh" bash -c 'echo $SMOKE_PORT' 2>/dev/null)"

# fail_fast without parallel: the remaining checks are skipped.
gate_with '"fail_fast": true, "checks": [
  {"name": "bad", "command": "exit 3", "heavy": false},
  {"name": "unit", "command": "touch \"$SMOKE_WORK/marker\"", "heavy": false}]'
expect "sequential fail_fast skips the remaining checks" "1 bad rc=3|unit skipped no" \
  "$rc $(result_lines) $([ -e "$work/marker" ] && echo yes || echo no)"

# The gate itself gets SIGTERM while parallel checks run: it stops them and reports red.
cat >"$work/gate.json" <<'EOF'
{"base_branch": "main", "parallel": true,
 "checks": [{"name": "long", "command": "echo $$ $PPID >\"$SMOKE_WORK/slow.pids\"; sleep 300 & echo $! >>\"$SMOKE_WORK/slow.pids\"; wait"}],
 "heavy": {"slots": 2, "port_env": "SMOKE_PORT", "port_base": 9100, "port_step": 10, "poll_seconds": 1}}
EOF
rm -f "$work/slow.pids"
DEV_LOOP_CONFIG="$work/gate.json" "$plugin/scripts/gate-train.sh" feat/6-fast >"$work/term.out" 2>&1 &
gate_pid=$!
for _ in $(seq 50); do [ "$(wc -w <"$work/slow.pids" 2>/dev/null)" = 3 ] && break; sleep 0.2; done
kill -TERM "$gate_pid"
wait "$gate_pid"
rc=$?
expect "a gate stopped by SIGTERM is red with exit 1" "1 TRAIN RED" "$rc $(tail -1 "$work/term.out")"
grep -q "^long stopped" "$work/term.out" && pass "a gate stopped by SIGTERM reports the stopped check" ||
  fail "no stopped line after SIGTERM"
# shellcheck disable=SC2046  # the pid list splits on purpose
expect "a gate stopped by SIGTERM leaves no check process behind" "" "$(alive $(cat "$work/slow.pids" 2>/dev/null))"
expect "a gate stopped by SIGTERM leaves no heavy slot held" "9110" \
  "$(DEV_LOOP_CONFIG="$work/gate.json" "$plugin/scripts/heavy.sh" bash -c 'echo $SMOKE_PORT' 2>/dev/null)"

# Without setsid on PATH the gate starts its process groups with perl.
mkdir -p "$work/nosetsid"
IFS=: read -r -a path_dirs <<<"$PATH"
for dir in "${path_dirs[@]}"; do
  [ -d "$dir" ] && find "$dir" -mindepth 1 -maxdepth 1 ! -name setsid -exec ln -s -t "$work/nosetsid" {} + 2>/dev/null
done
expect "the test PATH hides setsid" "" "$(PATH="$work/nosetsid" command -v setsid)"
PATH="$work/nosetsid" gate_with '"parallel": true, "fail_fast": true, "checks": [
  {"name": "slow", "command": "echo $$ $PPID >\"$SMOKE_WORK/slow.pids\"; sleep 300 & echo $! >>\"$SMOKE_WORK/slow.pids\"; wait"},
  {"name": "bad", "command": "sleep 1; exit 3", "heavy": false}]'
expect "the perl fallback stops the sibling" "1 slow stopped|bad rc=3" "$rc $(result_lines)"
# shellcheck disable=SC2046  # the pid list splits on purpose
expect "the perl fallback leaves no process behind" "" "$(alive $(cat "$work/slow.pids" 2>/dev/null))"
git checkout -q main

# 11. doctor flags the leftovers of a hand-built loop.
mkdir -p .claude/agents && echo "---" >.claude/agents/code-reviewer.md
out=$("$plugin/scripts/doctor.sh" 2>&1)
expect "doctor flags a project agent that shadows the plugin's" yes \
  "$(echo "$out" | grep -q "MISSING .claude/agents/code-reviewer.md shadows" && echo yes || echo no)"
rm -r .claude/agents
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' >.claude/settings.json
expect "doctor notes a project Stop hook" yes \
  "$("$plugin/scripts/doctor.sh" 2>&1 | grep -q "note    project Stop hooks" && echo yes || echo no)"
rm .claude/settings.json
printf '{"checks": ["true"], "parallel": "yes", "affected": {"summary": "x"}}\n' >"$work/doctor.json"
out=$(DEV_LOOP_CONFIG="$work/doctor.json" "$plugin/scripts/doctor.sh" 2>&1)
expect "doctor flags a parallel that is not true or false" yes \
  "$(echo "$out" | grep -q 'MISSING parallel: "yes" is not true or false' && echo yes || echo no)"
expect "doctor flags an affected stage without a command" yes \
  "$(echo "$out" | grep -q 'MISSING affected: no "command"' && echo yes || echo no)"
printf '{"checks": [{"name": "unit", "command": "true"}, {"name": "unit", "command": "true"}, {"name": "affected", "command": "true"}]}\n' \
  >"$work/doctor.json"
out=$(DEV_LOOP_CONFIG="$work/doctor.json" "$plugin/scripts/doctor.sh" 2>&1)
expect "doctor flags two checks with the same name" yes \
  "$(echo "$out" | grep -q 'MISSING check name "unit" is used twice' && echo yes || echo no)"
expect "doctor flags a check named affected" yes \
  "$(echo "$out" | grep -q 'MISSING check name "affected" is reserved' && echo yes || echo no)"
printf '{"checks": ["true"], "parallel": true, "fail_fast": true, "affected": "make test-affected"}\n' >"$work/doctor.json"
expect "doctor prints the gate options" "gate options  affected on, parallel true, fail_fast true" \
  "$(DEV_LOOP_CONFIG="$work/doctor.json" "$plugin/scripts/doctor.sh" 2>&1 | grep -o 'gate options.*')"

# 11b. A setup branch that adds .dev-loop.json merges with the main checkout on the base, which has no
#      config yet: gate-train.sh and merge-train.sh read it from the branch, without DEV_LOOP_CONFIG, and say so.
setup_project() { # setup_project NAME REMOTE: a project on main without .dev-loop.json, its bare origin as REMOTE
  git init -q --bare "$work/$1.git"
  git clone -q -o "$2" "$work/$1.git" "$work/$1" 2>/dev/null
  (cd "$work/$1" && echo one >src.txt && git add . && git commit -q -m "chore: start" && git push -q "$2" main)
}
setup_branch() { # setup_branch NAME REMOTE: chore/80-setup adds the config (remote REMOTE), pushed; back on main
  (cd "$work/$1" && git checkout -q -b chore/80-setup &&
    printf '{"remote": "%s", "checks": [{"name": "unit", "command": "echo 1 passed", "heavy": false}]}\n' "$2" \
      >.dev-loop.json && git add .dev-loop.json && git commit -q -m "chore: set up the dev loop (Refs #80)" &&
    git push -q -u "$2" chore/80-setup && git checkout -q main)
}
setup_project setup-project origin
setup_branch setup-project origin
cd "$work/setup-project" || exit 1
mkdir -p "$DEV_LOOP_HOME/setup-project/notes"
printf 'chore: set up the dev loop (#80)\n\nCloses #80\n' >"$DEV_LOOP_HOME/setup-project/notes/pr-chore_80-setup.md"
out=$(env -u DEV_LOOP_CONFIG "$plugin/scripts/gate-train.sh" chore/80-setup 2>&1)
rc=$?
echo "$out"
expect "gate-train is green for a setup branch while the main checkout has no config" 0 "$rc"
echo "$out" | grep -q "config read from origin/chore/80-setup:.dev-loop.json" &&
  pass "gate-train says it read the config from the setup branch" || fail "gate-train config source: $out"
out=$(env -u DEV_LOOP_CONFIG "$plugin/scripts/merge-train.sh" chore/80-setup 2>&1)
rc=$?
echo "$out"
expect "merge-train merges the setup branch with the main checkout on the base" 0 "$rc"
echo "$out" | grep -q "config read from origin/chore/80-setup:.dev-loop.json" &&
  pass "merge-train says it read the config from the recorded train's first branch" || fail "merge-train config source: $out"
expect "the base now carries the config and the main checkout fast-forwarded" "main yes" \
  "$(git rev-parse --abbrev-ref HEAD) $([ -f .dev-loop.json ] && echo yes || echo no)"
# The config names another remote: it is read from that remote's branch, and the gate uses that remote.
setup_project setup-upstream upstream
setup_branch setup-upstream upstream
cd "$work/setup-upstream" || exit 1
out=$(env -u DEV_LOOP_CONFIG "$plugin/scripts/gate-train.sh" chore/80-setup 2>&1)
rc=$?
echo "$out"
expect "gate-train reads a setup branch whose config names another remote" "0 yes" \
  "$rc $(echo "$out" | grep -q "config read from upstream/chore/80-setup:.dev-loop.json" && echo yes || echo no)"
out=$(env -u DEV_LOOP_CONFIG "$plugin/scripts/gate-train.sh" 2>&1)
expect "without branches, a missing config is still a usage error" 2 "$?"
out=$(env -u DEV_LOOP_CONFIG "$plugin/scripts/gate-train.sh" feat/81-nothing 2>&1)
expect "a branch without a config keeps today's error" "2 yes" \
  "$? $(echo "$out" | grep -q "no config at" && echo yes || echo no)"
cd "$work/project" || exit 1

# 11c. The branch-config fallback (#9): a leftover copy is never read, the branch is fetched before its config
#      is read, a missing branch on the config's remote is named, and a local branch is named as refs/heads/.
cd "$work/setup-project" || exit 1
printf '{"checks": []}\n' >"$DEV_LOOP_HOME/setup-project/branch-config.json"
git checkout -q -b feat/82-next && echo two >>src.txt && git commit -q -am "feat: next (Refs #82)" &&
  git push -q -u origin feat/82-next && git checkout -q main
out=$(env -u DEV_LOOP_CONFIG "$plugin/scripts/gate-train.sh" feat/82-next 2>&1)
rc=$?
expect "a leftover branch-config.json is ignored once the main checkout has its own config" "0 no" \
  "$rc $(echo "$out" | grep -q "config read from\|branch-config.json" && echo yes || echo no)"
setup_project setup-noconfig origin
cd "$work/setup-noconfig" || exit 1
mkdir -p "$DEV_LOOP_HOME/setup-noconfig"
printf '{"checks": [{"name": "unit", "command": "echo 1 passed", "heavy": false}]}\n' \
  >"$DEV_LOOP_HOME/setup-noconfig/branch-config.json"
git checkout -q -b feat/83-plain && echo two >>src.txt && git commit -q -am "feat: plain (Refs #83)" &&
  git push -q -u origin feat/83-plain && git checkout -q main
out=$(env -u DEV_LOOP_CONFIG "$plugin/scripts/gate-train.sh" feat/83-plain 2>&1)
expect "a leftover branch-config.json is ignored when a later run finds no config at all" "2 yes" \
  "$? $(echo "$out" | grep -q "no config at $work/setup-noconfig/.dev-loop.json" && echo yes || echo no)"
# The remote-tracking ref is stale (the branch moved on origin since the last fetch): the fresh config is read.
setup_project setup-stale origin
setup_branch setup-stale origin
git clone -q -b chore/80-setup "$work/setup-stale.git" "$work/setup-stale-2" 2>/dev/null
(cd "$work/setup-stale-2" && sed 's/1 passed/2 passed/' .dev-loop.json >cfg.tmp && mv cfg.tmp .dev-loop.json &&
  git commit -q -am "chore: fix the check (Refs #80)" && git push -q origin chore/80-setup)
cd "$work/setup-stale" || exit 1
out=$(env -u DEV_LOOP_CONFIG "$plugin/scripts/gate-train.sh" chore/80-setup 2>&1)
rc=$?
expect "the branch is fetched before its config is read (a stale remote-tracking ref is not used)" "0 yes" \
  "$rc $(grep -q '2 passed' "$DEV_LOOP_HOME/setup-stale/branch-config.json" && echo yes || echo no)"
# The config names another remote, where the branch is missing: said so, not "no config at".
setup_project setup-noupstream origin
cd "$work/setup-noupstream" || exit 1
git checkout -q -b chore/80-setup &&
  printf '{"remote": "upstream", "checks": [{"name": "unit", "command": "echo 1 passed"}]}\n' >.dev-loop.json &&
  git add .dev-loop.json && git commit -q -m "chore: set up the dev loop (Refs #80)" &&
  git push -q -u origin chore/80-setup && git checkout -q main
out=$(env -u DEV_LOOP_CONFIG "$plugin/scripts/gate-train.sh" chore/80-setup 2>&1)
rc=$?
expect "a config naming another remote without the branch there says so" "2 yes no" \
  "$rc $(echo "$out" | grep -q "names remote upstream, but upstream/chore/80-setup is missing" && echo yes || echo no) $(echo "$out" | grep -q "no config at" && echo yes || echo no)"
# A branch that exists only locally: the source line names it as refs/heads/<branch>.
setup_project setup-local origin
cd "$work/setup-local" || exit 1
git checkout -q -b chore/80-setup &&
  printf '{"checks": [{"name": "unit", "command": "echo 1 passed"}]}\n' >.dev-loop.json &&
  git add .dev-loop.json && git commit -q -m "chore: set up the dev loop (Refs #80)" && git checkout -q main
out=$(env -u DEV_LOOP_CONFIG "$plugin/scripts/gate-train.sh" chore/80-setup 2>&1)
echo "$out" | grep -q "config read from refs/heads/chore/80-setup:.dev-loop.json" &&
  pass "the source line names a local branch as refs/heads/<branch>" || fail "local branch source line: $out"
echo "$out" | grep -q "could not fetch origin/chore/80-setup; reading the config from" &&
  pass "a failed fetch of the branch is a warning, not silent" || fail "fetch warning: $out"
# The fallback exports DEV_LOOP_CONFIG inside the script that loads it, never into the shell that ran it.
seen=$( (unset DEV_LOOP_CONFIG; . "$plugin/scripts/lib/common.sh"; dl_load_train_config chore/80-setup >/dev/null 2>&1
  echo "${DEV_LOOP_CONFIG:-unset}") )
# shellcheck disable=SC2031  # the subshell's export must not reach this shell: that is the check
expect "the fallback exports DEV_LOOP_CONFIG where it runs, not in the caller's shell" \
  "$DEV_LOOP_HOME/setup-local/branch-config.json unset" "$seen ${DEV_LOOP_CONFIG-unset}"
cd "$work/project" || exit 1

# 12. Branch lifecycle: gate and merge clean up after themselves, cleanup.sh classifies the rest.
git checkout -q -f main && git reset -q --hard origin/main && git clean -qfd
expect "the next gate removed the red train's refs" "" "$(git branch --list train-feat/3-broken)"
branch_on() { # branch_on NAME FILE: a branch from origin/main with one commit adding FILE, pushed
  git checkout -q -B "$1" origin/main && echo "$1" >"$2" && git add "$2" && git commit -q -m "feat: $2" &&
    git push -q -u origin "$1" && git checkout -q main
}
note_for() { printf 'feat: %s\n\nbody\n' "$1" >"$("$plugin/scripts/paths.sh" notes "$1")"; }

# A waiting green train keeps its refs through the next gate; a worktree with changes keeps its branch.
branch_on feat/21-waiting w21.txt
"$plugin/scripts/gate-train.sh" feat/21-waiting >/dev/null 2>&1
branch_on feat/22-dirty w22.txt
note_for feat/22-dirty
git worktree add -q "$work/wt22" feat/22-dirty && echo change >>"$work/wt22/w22.txt"
"$plugin/scripts/gate-train.sh" feat/22-dirty >/dev/null 2>&1
[ -n "$(git branch --list train-feat/21-waiting)" ] && pass "the refs of a waiting green train survive the next gate" ||
  fail "the refs of a waiting green train were deleted"
out=$("$plugin/scripts/merge-train.sh" feat/22-dirty 2>&1)
echo "$out" | grep -q "kept local feat/22-dirty: its worktree $work/wt22 has changes" &&
  pass "merge-train keeps a branch whose worktree has changes, and says so" || fail "dirty worktree: $out"
[ -d "$work/wt22" ] && [ -n "$(git branch --list feat/22-dirty)" ] && pass "the dirty worktree and its branch stay" ||
  fail "the dirty worktree or its branch went"
git worktree remove --force "$work/wt22"
# A locked worktree, and one holding an ignored .env file, keep their merged branches.
branch_on feat/48-locked w48.txt && note_for feat/48-locked
branch_on feat/49-env w49.txt && note_for feat/49-env
git worktree add -q "$work/wt48" feat/48-locked && git worktree lock "$work/wt48"
git worktree add -q "$work/wt49" feat/49-env && printf '.env\nnode_modules/\n' >>"$(git rev-parse --git-common-dir)/info/exclude" &&
  echo SECRET=x >"$work/wt49/.env"
branch_on feat/52-output w52.txt && note_for feat/52-output
git worktree add -q "$work/wt52" feat/52-output && printf 'build/\n' >>"$(git rev-parse --git-common-dir)/info/exclude" &&
  mkdir -p "$work/wt52/build" && echo SECRET=x >"$work/wt52/build/local.env" && echo o >"$work/wt52/w52.txt.bak" &&
  rm "$work/wt52/w52.txt.bak"
branch_on feat/51-build w51.txt && note_for feat/51-build
git worktree add -q "$work/wt51" feat/51-build && mkdir -p "$work/wt51/web/node_modules/pkg" && echo x >"$work/wt51/web/node_modules/pkg/i.js"
# Self-ignoring caches (their own .gitignore with *) list their files one by one; they are build output too.
branch_on feat/53-caches w53.txt && note_for feat/53-caches
git worktree add -q "$work/wt53" feat/53-caches && mkdir -p "$work/wt53/.ruff_cache/0.1" "$work/wt53/.pytest_cache/v" \
  "$work/wt53/node_modules/pkg" && echo '*' >"$work/wt53/.ruff_cache/.gitignore" &&
  echo 'Signature: 8a477f597d28d172789f06886806bc55' >"$work/wt53/.ruff_cache/CACHEDIR.TAG" &&
  echo x >"$work/wt53/.ruff_cache/0.1/123" && echo '*' >"$work/wt53/.pytest_cache/.gitignore" &&
  echo x >"$work/wt53/.pytest_cache/v/lastfailed" && echo x >"$work/wt53/node_modules/pkg/i.js"
branch_on feat/54-cache-key w54.txt && note_for feat/54-cache-key
git worktree add -q "$work/wt54" feat/54-cache-key && mkdir -p "$work/wt54/.ruff_cache" &&
  echo '*' >"$work/wt54/.ruff_cache/.gitignore" && echo KEY >"$work/wt54/.ruff_cache/x.pem"
# Results in an output folder with its own .gitignore, and a key deep in a cache, keep their worktrees.
branch_on feat/55-results w55.txt && note_for feat/55-results
git worktree add -q "$work/wt55" feat/55-results && mkdir -p "$work/wt55/out" && echo '*' >"$work/wt55/out/.gitignore" &&
  echo 1,2 >"$work/wt55/out/results.csv"
branch_on feat/56-deep-key w56.txt && note_for feat/56-deep-key
git worktree add -q "$work/wt56" feat/56-deep-key && mkdir -p "$work/wt56/.ruff_cache/0.1" &&
  echo '*' >"$work/wt56/.ruff_cache/.gitignore" && echo KEY >"$work/wt56/.ruff_cache/0.1/x.key"
# Vendored files named like secrets (credentials.js) are output; a .env in a dependency folder is not (#15).
branch_on feat/57-vendored w57.txt && note_for feat/57-vendored
git worktree add -q "$work/wt57" feat/57-vendored && mkdir -p "$work/wt57/node_modules/pkg/lib" &&
  echo x >"$work/wt57/node_modules/pkg/credentials.js" && echo x >"$work/wt57/node_modules/pkg/lib/secrets.js" &&
  echo x >"$work/wt57/node_modules/pkg/id_map.js"
branch_on feat/58-dep-env w58.txt && note_for feat/58-dep-env
git worktree add -q "$work/wt58" feat/58-dep-env && mkdir -p "$work/wt58/node_modules/pkg" &&
  echo x >"$work/wt58/node_modules/pkg/credentials.js" && echo SECRET=x >"$work/wt58/node_modules/.env"
# A .venv with its own .gitignore lists its folders one by one; vendored names in them are output too.
branch_on feat/61-venv w61.txt && note_for feat/61-venv
git worktree add -q "$work/wt61" feat/61-venv && mkdir -p "$work/wt61/.venv/lib/site/pkg" &&
  echo '*' >"$work/wt61/.venv/.gitignore" && echo x >"$work/wt61/.venv/lib/site/pkg/credentials.py"
# In an output folder ignored as a whole, broad names still keep the worktree (a false negative deletes).
branch_on feat/59-build-creds w59.txt && note_for feat/59-build-creds
git worktree add -q "$work/wt59" feat/59-build-creds && mkdir -p "$work/wt59/build" &&
  echo x >"$work/wt59/build/credentials.json" && echo x >"$work/wt59/build/id_rsa"
branch_on feat/60-dist-secrets w60.txt && note_for feat/60-dist-secrets
git worktree add -q "$work/wt60" feat/60-dist-secrets && printf 'dist/\n' >>"$(git rev-parse --git-common-dir)/info/exclude" &&
  mkdir -p "$work/wt60/dist/sub" && echo x >"$work/wt60/dist/sub/secrets.json"
git branch -q train-person-work origin/main
"$plugin/scripts/gate-train.sh" feat/48-locked feat/49-env feat/51-build feat/52-output feat/53-caches \
  feat/54-cache-key feat/55-results feat/56-deep-key feat/57-vendored feat/58-dep-env \
  feat/59-build-creds feat/60-dist-secrets feat/61-venv >/dev/null 2>&1
out=$("$plugin/scripts/merge-train.sh" feat/48-locked feat/49-env feat/51-build feat/52-output feat/53-caches \
  feat/54-cache-key feat/55-results feat/56-deep-key feat/57-vendored feat/58-dep-env \
  feat/59-build-creds feat/60-dist-secrets feat/61-venv 2>&1)
echo "$out" | grep -q "kept local feat/48-locked: its worktree $work/wt48 is locked" &&
  pass "merge-train keeps a branch whose worktree is locked" || fail "locked worktree: $out"
echo "$out" | grep -q "kept local feat/49-env: its worktree $work/wt49 holds ignored files that are not build output (.env)" &&
  [ -f "$work/wt49/.env" ] && pass "merge-train keeps a worktree holding a .env file" || fail ".env worktree: $out"
[ ! -d "$work/wt51" ] && [ -z "$(git branch --list feat/51-build)" ] &&
  pass "merge-train removes a worktree whose ignored files are only build output" || fail "build-only worktree kept: $out"
[ -f "$work/wt52/build/local.env" ] && pass "a file inside an ignored build directory that is not all output keeps its worktree" ||
  fail "wt52 removed: $out"
[ ! -d "$work/wt53" ] && [ -z "$(git branch --list feat/53-caches)" ] &&
  pass "merge-train removes a worktree holding only self-ignoring caches, .pytest_cache and node_modules" ||
  fail "cache-only worktree kept: $out"
echo "$out" | grep -q "kept local feat/54-cache-key: its worktree $work/wt54 holds ignored files that are not build output (.ruff_cache/x.pem)" &&
  [ -f "$work/wt54/.ruff_cache/x.pem" ] && pass "a key inside a self-ignoring cache keeps its worktree" ||
  fail "wt54: $out"
echo "$out" | grep -q "kept local feat/55-results: its worktree $work/wt55 holds ignored files that are not build output (out/results.csv)" &&
  [ -f "$work/wt55/out/results.csv" ] && pass "results listed one by one in a self-ignoring output folder keep their worktree" ||
  fail "wt55: $out"
echo "$out" | grep -q "kept local feat/56-deep-key: its worktree $work/wt56 holds ignored files that are not build output (.ruff_cache/0.1/x.key)" &&
  [ -f "$work/wt56/.ruff_cache/0.1/x.key" ] && pass "a key in a folder nested in a self-ignoring cache keeps its worktree" ||
  fail "wt56: $out"
[ ! -d "$work/wt57" ] && [ -z "$(git branch --list feat/57-vendored)" ] &&
  pass "merge-train removes a worktree whose node_modules only holds vendored files named like secrets" ||
  fail "wt57 kept: $out"
echo "$out" | grep -q "kept local feat/58-dep-env: its worktree $work/wt58 holds ignored files that are not build output (node_modules/.env)" &&
  [ -f "$work/wt58/node_modules/.env" ] && pass "a .env inside node_modules keeps its worktree" || fail "wt58: $out"
[ ! -d "$work/wt61" ] && [ -z "$(git branch --list feat/61-venv)" ] &&
  pass "merge-train removes a worktree whose self-ignoring .venv only holds vendored files named like secrets" ||
  fail "wt61 kept: $out"
echo "$out" | grep -q "kept local feat/59-build-creds: its worktree $work/wt59 holds ignored files that are not build output (build/" &&
  [ -f "$work/wt59/build/credentials.json" ] && [ -f "$work/wt59/build/id_rsa" ] &&
  pass "credentials and keys by a broad name in an ignored build folder keep their worktree" || fail "wt59: $out"
echo "$out" | grep -q "kept local feat/60-dist-secrets: its worktree $work/wt60 holds ignored files that are not build output (dist/sub/secrets.json)" &&
  [ -f "$work/wt60/dist/sub/secrets.json" ] && pass "secrets.json deep in an ignored dist folder keeps its worktree" ||
  fail "wt60: $out"
# The deep scan finds strong and broad names, or only strong ones in strong mode; the lists are readonly.
scan=$(bash -c '. "$1/scripts/lib/common.sh"; d=$2; mkdir -p "$d/a/b" "$d/k" "$d/c"
  : >"$d/a/credentials.py"; : >"$d/a/b/secrets.json"; : >"$d/a/b/id_rsa"; : >"$d/k/x.pem"; : >"$d/c/secrets.json"
  printf "a=[%s] k=[%s] " "$(dl_secret_in "$d/a" strong)" "$(dl_secret_in "$d/k" strong)"
  printf "full-c=[%s] full-k=[%s] " "$(dl_secret_in "$d/c")" "$(dl_secret_in "$d/k")"
  [ -n "$(dl_secret_in "$d/a")" ] && printf "full-a "
  (DL_SECRET_STRONG_PATTERNS=(x)) 2>/dev/null || printf "strong-ro "
  (DL_SECRET_BROAD_PATTERNS=(x)) 2>/dev/null || printf "broad-ro "
  . "$1/scripts/lib/common.sh" && printf "resourced"' _ "$plugin" "$work/scan15")
expect "the deep scan finds broad and strong names, strong mode only strong ones; the lists are readonly" \
  "a=[] k=[$work/scan15/k/x.pem] full-c=[$work/scan15/c/secrets.json] full-k=[$work/scan15/k/x.pem] full-a strong-ro broad-ro resourced" "$scan"
rm -rf "$work/scan15"
# Secret and data names inside a cache are matched without regard to case; ordinary cache files are output.
judged=$(bash -c '. "$1/scripts/lib/common.sh"; shift
  for e in "$@"; do if dl_rebuildable_entry " .ruff_cache build out " " .ruff_cache " "$e"; then echo "y $e"; else echo "n $e"; fi; done' _ \
  "$plugin" .ruff_cache/.ENV .ruff_cache/a.DB .ruff_cache/id_rsa .ruff_cache/id_ed25519.pub .ruff_cache/id_ecdsa \
  .ruff_cache/id_dsa .ruff_cache/credentials .ruff_cache/secrets.json .ruff_cache/k.pfx .ruff_cache/k.P12 \
  .ruff_cache/d.sqlite-wal .ruff_cache/0.1/x.KEY build/results.csv out/x.o .ruff_cache/CACHEDIR.TAG \
  .ruff_cache/0.1/ build/ | tr '\n' ' ')
expect "secret and data names in a cache are never output, whatever their case; outputs only as a whole" \
  "n .ruff_cache/.ENV n .ruff_cache/a.DB n .ruff_cache/id_rsa n .ruff_cache/id_ed25519.pub n .ruff_cache/id_ecdsa n .ruff_cache/id_dsa n .ruff_cache/credentials n .ruff_cache/secrets.json n .ruff_cache/k.pfx n .ruff_cache/k.P12 n .ruff_cache/d.sqlite-wal n .ruff_cache/0.1/x.KEY n build/results.csv n out/x.o y .ruff_cache/CACHEDIR.TAG y .ruff_cache/0.1/ y build/ " \
  "$judged"
[ -n "$(git branch --list train-person-work)" ] && pass "the gate never deletes a person's train-* branch" ||
  fail "the gate deleted train-person-work"
git worktree unlock "$work/wt48" && git worktree remove --force "$work/wt48" && git worktree remove --force "$work/wt49"
git branch -q -D train-person-work
git worktree remove --force "$work/wt52" && git worktree remove --force "$work/wt54" && git worktree remove --force "$work/wt55"
git worktree remove --force "$work/wt56" && git worktree remove --force "$work/wt58"
git worktree remove --force "$work/wt59" && git worktree remove --force "$work/wt60"

# Leftovers from before the ledger: merged by PR, replayed, moved on, closed, not planned, open, stale.
gh_pr() { gh pr create --head "$1" --title "$1" --body-file /dev/null >/dev/null; }
branch_on feat/23-merged w23.txt && gh_pr feat/23-merged && gh pr merge feat/23-merged --squash >/dev/null
note_for feat/23-merged
git fetch -q origin
git checkout -q -B feat/24-replayed origin/main~1 && echo r >w24.txt && git add w24.txt && git commit -q -m "feat: w24"
git checkout -q -B replayed-copy origin/main && git cherry-pick feat/24-replayed >/dev/null &&
  git push -q -f origin replayed-copy:feat/24-replayed && git checkout -q main && git branch -q -D replayed-copy
git fetch -q origin && gh_pr feat/24-replayed && gh pr merge feat/24-replayed --squash >/dev/null
git push -q origin --delete feat/24-replayed
branch_on feat/25-moved w25.txt && gh_pr feat/25-moved && gh pr merge feat/25-moved --squash >/dev/null
git checkout -q feat/25-moved && echo more >>w25.txt && git commit -q -am "feat: more" && git checkout -q main
branch_on feat/26-closed w26.txt && gh_pr feat/26-closed && echo CLOSED >"$FAKE_GH_DIR/feat_26-closed.state"
branch_on fix/27-dropped w27.txt
branch_on feat/28-open w28.txt
git checkout -q -B spike-old origin/main && echo old >old.txt && git add old.txt &&
  GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" git commit -q -m "spike" && git checkout -q main
printf '27\tCLOSED\tNOT_PLANNED\n28\tOPEN\t\n' >"$FAKE_GH_DIR/issues.tsv"
git branch -q train-feat/50-stale origin/main                              # a gate ref no train needs
git fetch -q origin

class_of() { awk -F'\t' -v s="$2" -v b="$3" '$2 == s && $3 == b {print $1}' "$1"; }
out=$("$plugin/scripts/cleanup.sh" 2>&1)
report=$(echo "$out" | sed -n 's/^report: //p')
for row in "merged local feat/23-merged" "merged local feat/24-replayed" "keep local feat/25-moved" \
  "closed local feat/26-closed" "closed remote feat/26-closed" "closed local fix/27-dropped" \
  "keep local feat/28-open" "stale local spike-old" "keep local main" "helper local train-feat/50-stale"; do
  read -r want scope name <<<"$row"
  expect "cleanup classifies $scope $name as $want" "$want" "$(class_of "$report" "$scope" "$name")"
done
grep -qF "feat/22-dirty"$'\t'"$(git rev-parse feat/22-dirty)"$'\t'"in the merge ledger" "$report" &&
  pass "the ledger decides first" || fail "feat/22-dirty not classified by the ledger"
grep -q "feat/25-moved.*moved on since" "$report" && pass "a kept branch is reported with its reason" ||
  fail "no reason for feat/25-moved"
[ -n "$(git branch --list feat/23-merged)" ] && pass "a dry run deletes nothing" || fail "the dry run deleted a branch"

out=$("$plugin/scripts/cleanup.sh" --apply 2>&1)
echo "$out"
expect "--apply deletes the merged and helper branches" "" \
  "$(git branch --list feat/23-merged feat/24-replayed train-feat/50-stale)"
expect "--apply keeps closed, stale and kept branches without --include" \
  "feat/25-moved feat/26-closed feat/28-open fix/27-dropped spike-old" \
  "$(git branch --list --format='%(refname:short)' feat/25-moved feat/26-closed fix/27-dropped feat/28-open spike-old | paste -sd' ')"
[ -f "$notes/merged/pr-feat_23-merged.md" ] && pass "cleanup moves the notes of a merged PR" || fail "notes not moved"
bundle=$(echo "$out" | sed -n 's/^archived [0-9]* tips to //p')
git fetch -q "$bundle" refs/heads/feat/24-replayed:refs/heads/restored 2>/dev/null &&
  expect "the bundle restores a deleted squash-merged branch" "feat: w24" "$(git log -1 --format=%s restored)" ||
  fail "the bundle does not restore feat/24-replayed"
git branch -q -D restored 2>/dev/null

"$plugin/scripts/cleanup.sh" --apply --include stale >/dev/null 2>&1
expect "--include stale deletes the stale branch" "" "$(git branch --list spike-old)"
jq '. + {factory: "dark"}' .dev-loop.json >"$work/dark.json"
DEV_LOOP_CONFIG="$work/dark.json" "$plugin/scripts/cleanup.sh" --apply >/dev/null 2>&1
expect "a dark factory deletes closed branches without --include" "" \
  "$(git branch --list feat/26-closed fix/27-dropped)"
git ls-remote --exit-code origin feat/26-closed >/dev/null 2>&1 && fail "closed remote branch kept in dark mode" ||
  pass "a dark factory deletes the closed remote branch too"
expect "kept branches survive every run" "feat/25-moved feat/28-open" \
  "$(git branch --list --format='%(refname:short)' feat/25-moved feat/28-open | paste -sd' ')"

# The reviewer's cases: the dangerous direction of every rule.
git push -q origin origin/main~1:refs/heads/develop                       # a long-lived branch behind main
git checkout -q -B release-1 origin/main && echo r >rel.txt && git add rel.txt && git commit -q -m "release" &&
  git push -q -u origin release-1 && git checkout -q main && gh_pr release-1 && gh pr merge release-1 --squash >/dev/null
git fetch -q origin                                                          # a non-loop branch with a merged PR
git checkout -q -B "fix/42-it's" origin/main && echo q >q.txt && git add q.txt && git commit -q -m "fix: q" &&
  git push -q -u origin "fix/42-it's" && git checkout -q main                # a quote in the name
printf '42\tCLOSED\tNOT_PLANNED\n' >>"$FAKE_GH_DIR/issues.tsv"
branch_on feat/43-reopened w43.txt && gh_pr feat/43-reopened && echo CLOSED >"$FAKE_GH_DIR/feat_43-reopened.state"
git checkout -q feat/43-reopened && echo more >>w43.txt && git commit -q -am "feat: new work" &&
  git push -q && git checkout -q main                                          # closed PR, then new work
branch_on feat/44-remote-only w44.txt && gh_pr feat/44-remote-only && git branch -q -D feat/44-remote-only
echo CLOSED >"$FAKE_GH_DIR/feat_44-remote-only.state"
branch_on fix/45-checked-out w45.txt && printf '45\tCLOSED\tNOT_PLANNED\n' >>"$FAKE_GH_DIR/issues.tsv"
git worktree add -q "$work/wt45" fix/45-checked-out
git branch -q train-station-fix origin/main                                 # a person's branch, not a gate ref
git checkout -q -B master origin/main && echo m >m.txt && git add m.txt &&
  GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" git commit -q -m "old master" && git checkout -q main   # long-lived, old
git branch -q train-feat/46-live origin/main && printf '%s feat/46-live\n' "$$" >"$DEV_LOOP_HOME/project/train-running.txt"
branch_on feat/47-old-note w47.txt && gh_pr feat/47-old-note && gh pr merge feat/47-old-note --squash >/dev/null
note_for feat/47-old-note && touch -t 202001010000 "$("$plugin/scripts/paths.sh" notes feat/47-old-note)"
mkdir -p "$DEV_LOOP_HOME/project/logs" && echo keep >"$DEV_LOOP_HOME/project/logs/important.txt" &&
  touch -t 202001010000 "$DEV_LOOP_HOME/project/logs/important.txt"
git fetch -q origin
out=$(DEV_LOOP_CONFIG="$work/dark.json" "$plugin/scripts/cleanup.sh" --apply 2>&1)
echo "$out"
report=$(echo "$out" | sed -n 's/^report: //p')
for row in "keep remote develop" "keep remote release-1" "keep local release-1" "closed local fix/42-it's" "keep local feat/43-reopened" \
  "keep local fix/45-checked-out" "keep local train-station-fix" "keep local train-feat/46-live" \
  "keep local master"; do
  read -r want scope name <<<"$row"
  expect "cleanup classifies $scope $name as $want" "$want" "$(class_of "$report" "$scope" "$name")"
done
git ls-remote --exit-code origin develop >/dev/null && pass "a remote branch behind main is never deleted" ||
  fail "develop was deleted"
git ls-remote --exit-code origin feat/43-reopened >/dev/null && [ -n "$(git branch --list feat/43-reopened)" ] &&
  pass "a closed PR's branch with new work is kept" || fail "feat/43-reopened deleted"
expect "a branch with a quote in its name is deleted, locally and remotely" "0 0" \
  "$(git branch --list "fix/42-it's" | wc -l | tr -d ' ') $(git ls-remote origin "fix/42-it's" | wc -l | tr -d ' ')"
echo "$out" | grep -q "deleted [0-9]* local and [0-9]* remote" && ! echo "$out" | grep -q "not deleted" &&
  pass "every planned deletion is confirmed" || fail "deletions failed: $out"
bundle=$(echo "$out" | sed -n 's/^archived [0-9]* tips to //p')
git fetch -q "$bundle" "refs/remotes/origin/feat/44-remote-only:refs/heads/restored44" 2>/dev/null &&
  pass "the bundle holds a remote-only branch" || fail "the bundle lacks the remote-only branch"
git branch -q -D restored44 2>/dev/null
[ -n "$(git branch --list fix/45-checked-out)" ] && pass "a dark factory keeps a branch a worktree has checked out" ||
  fail "fix/45-checked-out deleted"
[ -f "$notes/merged/pr-feat_47-old-note.md" ] && pass "an old notes file survives its move to notes/merged" ||
  fail "the old notes file was deleted on archiving"
[ -f "$DEV_LOOP_HOME/project/logs/important.txt" ] && pass "cleanup leaves other files in the logs directory" ||
  fail "cleanup deleted a non-gate file"
rm -f "$DEV_LOOP_HOME/project/train-running.txt"
git branch -q -D train-feat/46-live
git worktree remove --force "$work/wt45"
echo first >"$work/pr-feat_60-twice.md" && echo second >"$work/pr-feat_60-twice.b" &&
  bash -c '. "$1/scripts/lib/common.sh"; dl_load_config; dl_archive_note_file "$2"; mv "$3" "$2"; dl_archive_note_file "$2"' \
    _ "$plugin" "$work/pr-feat_60-twice.md" "$work/pr-feat_60-twice.b"
expect "a note archived twice under one name keeps both" "first second" \
  "$(cat "$notes"/merged/pr-feat_60-twice*.md | sort | paste -sd' ')"
expect "the JSON of a branch name with quotes and backslashes parses" 'a"b\c' \
  "$(bash -c '. "$1/scripts/lib/common.sh"; dl_json_string "a\"b\\c"' _ "$plugin" | jq -r .)"

expect "doctor reports a missing CLAUDE.md" "MISSING CLAUDE.md or .claude/CLAUDE.md (run the setup skill)" \
  "$([ ! -e CLAUDE.md ] && "$plugin/scripts/doctor.sh" 2>&1 | grep -F 'MISSING CLAUDE.md')"
mkdir -p .claude && echo "# rules" >.claude/CLAUDE.md
expect "doctor accepts .claude/CLAUDE.md" "ok      .claude/CLAUDE.md" \
  "$("$plugin/scripts/doctor.sh" 2>&1 | grep -F '.claude/CLAUDE.md')"
rm .claude/CLAUDE.md
git branch -q train-feat/99-left origin/main
expect "doctor counts the leftover train refs" "1 train/replay refs outside a live train, 0 merged branches still local (cleanup.sh)" \
  "$("$plugin/scripts/doctor.sh" 2>&1 | sed -n 's/^note    \(.*train\/replay refs.*\)$/\1/p')"
git branch -q -D train-feat/99-left

# 13. Current-state docs: docs-check.sh, the gate's docs stage and doctor (all only with "docs" configured).
git checkout -q -f main && git reset -q --hard origin/main && git clean -qfd
mkdir -p docs/architecture lib
printf '# Features\n\n- one\n' >docs/features.md
printf '# Architecture\n\n1\n2\n3\n4\n5\n' >docs/architecture/index.md
echo a >lib/a.sh
git add docs lib && git commit -q -m "docs: current-state docs" && git push -q origin main
cat >"$work/docs.json" <<'EOF'
{
  "base_branch": "main",
  "checks": [{"name": "unit", "command": "touch \"$SMOKE_WORK/docs-checks-ran\"; ./check.sh", "heavy": false}],
  "docs": {
    "aspects": {"features": "docs/features.md", "architecture": "docs/architecture", "security": "docs/security.md"},
    "planned": "docs/features.md",
    "map": [
      {"paths": ["lib/*"], "docs": ["features", "architecture"]},
      {"paths": ["nowhere/*.py"], "docs": ["features"]}
    ],
    "max_lines": 5
  }
}
EOF
docs_check() { # docs_check FROM TO [NOTES]: run docs-check.sh with the docs config; sets out and rc
  out=$(DEV_LOOP_CONFIG="$work/docs.json" "$plugin/scripts/docs-check.sh" "$@" 2>&1)
  rc=$?
  echo "$out"
}
commit_files() { # commit_files MESSAGE FILE...: append a line to each FILE and commit
  local message=$1 file
  shift
  for file in "$@"; do mkdir -p "$(dirname "$file")" && echo "change" >>"$file" && git add "$file"; done
  git commit -q -m "$message"
}
c0=$(git rev-parse HEAD)
git checkout -q -b feat/70-docs
commit_files "feat: lib change" lib/a.sh
docs_check "$c0" HEAD
expect "docs-check is red for mapped code without a doc change" 1 "$rc"
echo "$out" | grep -F "lib/a.sh" | grep -F "rule 1" | grep -F "lib/*" | grep -F "features" | grep -qF "architecture" &&
  pass "the docs-check message names the file, the rule and its docs" || fail "docs-check message: $out"
echo "$out" | grep -qF "nowhere" && fail "docs-check reported a rule that matched nothing" ||
  pass "docs-check reports only the rules the change matches"
printf 'feat: x\n\n## Summary\nnone: in the wrong section\n\n## Docs\n- docs/features.md\n' >"$work/notes-wrong.md"
docs_check "$c0" HEAD "$work/notes-wrong.md"
expect "a none line outside ## Docs does not count" 1 "$rc"
printf 'feat: x\n\n## Docs\nnone:   \n\n## Test evidence\nnone: later\n' >"$work/notes-empty.md"
docs_check "$c0" HEAD "$work/notes-empty.md"
expect "a none line without a reason does not count" 1 "$rc"
printf 'feat: x\n\n## Docs\n- NONE: a refactor with unchanged behaviour\n\n## Test evidence\n' >"$work/notes-none.md"
docs_check "$c0" HEAD "$work/notes-none.md"
expect "docs-check is green with none: <reason> in ## Docs (any case)" 0 "$rc"
docs_check "$c0" HEAD "$work/no-such-notes.md"
expect "a missing notes file gives no exemption" 1 "$rc"
commit_files "docs: architecture" docs/architecture/index.md
docs_check "$c0" HEAD
expect "docs-check is green when a doc of the rule (a folder aspect) changed" 0 "$rc"
git checkout -q -B feat/70-docs "$c0" && commit_files "feat: lib and features" lib/a.sh docs/features.md
docs_check "$c0" HEAD
expect "docs-check is green when a doc of the rule (a file aspect) changed" 0 "$rc"
git checkout -q -B feat/70-docs "$c0" && commit_files "feat: unmapped" other.txt
docs_check "$c0" HEAD
expect "docs-check is green for a change no rule maps" 0 "$rc"

# Relative links in changed Markdown files must resolve in <to>.
git checkout -q -B feat/70-docs "$c0"
cat >docs/guide.md <<'EOF'
# Guide
See [the source](../src.txt), [features](features.md#one) and [the folder](./architecture/).
[top](#guide), [web](https://example.invalid/x), [mail](mailto:someone@example.invalid), ![logo](architecture/index.md "title")
Inline `[code](not-checked.md)` is code.
```
[fenced](not-checked-either.md)
```
EOF
git add docs/guide.md && git commit -q -m "docs: guide"
docs_check "$c0" HEAD
expect "docs-check is green for links that resolve (../, ./, #anchor, title, http, mailto, code)" 0 "$rc"
printf '# Broken\n[gone](missing.md) and [up](../../outside.md) and [ok](guide.md)\n' >docs/broken.md
git add docs/broken.md && git commit -q -m "docs: broken"
docs_check "$c0" HEAD
expect "docs-check is red for a broken relative link" 1 "$rc"
echo "$out" | grep -F "docs/broken.md" | grep -qF "missing.md" && pass "the link message names the file and the link" ||
  fail "link message: $out"
echo "$out" | grep -qF "outside.md" && pass "a link above the repository root is broken" || fail "outside link not reported"
echo "$out" | grep -qF "guide.md)" && fail "a valid link was reported" || pass "valid links in a red file are not reported"
git rm -q docs/broken.md && git commit -q -m "docs: remove broken"
docs_check "$c0" HEAD
expect "a Markdown file deleted in the range is not link-checked" 0 "$rc"

# Paths with non-ASCII names, angle-bracket and %20 links, and a from that is not an ancestor of to.
git checkout -q -B feat/70-docs "$c0"
printf '# Caf\303\251\n[gone](missing-too.md)\n' >"$(printf 'docs/caf\303\251.md')"
git add docs && git commit -q -m "docs: non-ascii name"
docs_check "$c0" HEAD
expect "a changed Markdown file with a non-ASCII name is link-checked" 1 "$rc"
echo "$out" | grep -F "missing-too.md" | grep -qF "$(printf 'docs/caf\303\251.md')" &&
  pass "the link message names the non-ASCII file as it is" || fail "non-ASCII link message: $out"
git checkout -q -B feat/70-docs "$c0" && commit_files "feat: non-ascii lib" "$(printf 'lib/\303\251.sh')"
docs_check "$c0" HEAD
expect "a mapped file with a non-ASCII name needs its docs" 1 "$rc"
git checkout -q -B feat/70-docs "$c0"
mkdir -p "docs/my dir" && echo t >"docs/my dir/t.md"
printf '# Spaces\n[a](<my dir/t.md>) [b](<my dir/t.md> "title") [c](my%%20dir/t.md#x) [d](features.md "a title")\n' >docs/spaces.md
git add docs && git commit -q -m "docs: spaces"
docs_check "$c0" HEAD
expect "angle-bracket links with spaces and %20 links resolve" 0 "$rc"
git checkout -q -B feat/70-docs "$c0" && commit_files "feat: unmapped" other.txt
branch_head=$(git rev-parse HEAD)
git checkout -q -B docs-moved-base "$c0" && commit_files "feat: base moved" lib/moved.sh
docs_check docs-moved-base "$branch_head"
expect "docs-check compares from the merge base when the base moved on" 0 "$rc"
echo "$out" | grep -qF "lib/moved.sh" && fail "the base's own change was judged as the branch's" ||
  pass "the base's own changes are not judged as the branch's"
git checkout -q main && git branch -q -D docs-moved-base

out=$("$plugin/scripts/docs-check.sh" 2>&1)
expect "docs-check without arguments is a usage error" 2 "$?"
docs_check "$c0" no-such-ref
expect "docs-check with an unknown ref is an error" 2 "$rc"
out=$(DEV_LOOP_CONFIG="$work/gate.json" "$plugin/scripts/docs-check.sh" "$c0" HEAD 2>&1)
expect "docs-check without docs in the config is a config error" 2 "$?"
sed 's/"docs": \["features"\]/"docs": ["nosuch"]/' "$work/docs.json" >"$work/docs-bad.json"
out=$(DEV_LOOP_CONFIG="$work/docs-bad.json" "$plugin/scripts/docs-check.sh" "$c0" HEAD 2>&1)
expect "a map rule naming an unknown aspect is a config error" 2 "$?"
echo "$out" | grep -qF "nosuch" && pass "the config error names the unknown aspect" || fail "unknown aspect: $out"

# The gate checks each branch's own commits, after stacking and before the checks.
git checkout -q -B feat/72-documented "$c0" && commit_files "feat: b and features" lib/b.sh docs/features.md &&
  git push -q -u origin feat/72-documented
git checkout -q -B feat/71-undocumented "$c0" && commit_files "feat: c" lib/c.sh && git push -q -u origin feat/71-undocumented
git checkout -q main
rm -f "$(DEV_LOOP_CONFIG="$work/docs.json" "$plugin/scripts/paths.sh" notes feat/71-undocumented)" "$work/docs-checks-ran"
out=$(DEV_LOOP_CONFIG="$work/docs.json" "$plugin/scripts/gate-train.sh" feat/72-documented feat/71-undocumented 2>&1)
rc=$?
echo "$out"
expect "the gate is red when a branch's own commits lack their docs" "1 TRAIN RED" "$rc $(echo "$out" | tail -n 1)"
echo "$out" | grep "feat/71-undocumented" | grep -qF "docs" && pass "the docs failure names the branch" ||
  fail "the branch is not named: $out"
echo "$out" | grep -q "red for feat/72-documented" && fail "the documented branch was reported" ||
  pass "a branch is judged on its own commits, not the docs of the branch below it"
[ ! -e "$work/docs-checks-ran" ] && ! echo "$out" | grep -q "^unit " && pass "the docs failure stops the train before the checks" ||
  fail "the checks ran after a docs failure"
printf 'feat: c (#71)\n\n## Docs\nnone: internal helper, no behaviour a user sees\n' \
  >"$(DEV_LOOP_CONFIG="$work/docs.json" "$plugin/scripts/paths.sh" notes feat/71-undocumented)"
out=$(DEV_LOOP_CONFIG="$work/docs.json" "$plugin/scripts/gate-train.sh" feat/72-documented feat/71-undocumented 2>&1)
rc=$?
echo "$out"
expect "the gate reads the branch's notes file for none: <reason>" "0 TRAIN GREEN" "$rc $(echo "$out" | tail -n 1)"
[ -e "$work/docs-checks-ran" ] && pass "the checks run after a green docs stage" || fail "the checks did not run"
rm -f "$(DEV_LOOP_CONFIG="$work/docs.json" "$plugin/scripts/paths.sh" notes feat/71-undocumented)"
printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "./check.sh", "heavy": false}]}\n' >"$work/nodocs.json"
out=$(DEV_LOOP_CONFIG="$work/nodocs.json" "$plugin/scripts/gate-train.sh" feat/71-undocumented 2>&1)
rc=$?
echo "$out"
expect "without docs in the config the gate does not check docs" "0 TRAIN GREEN" "$rc $(echo "$out" | tail -n 1)"

# doctor prints the aspects and reports missing paths, oversized files and rules that match nothing.
out=$(DEV_LOOP_CONFIG="$work/docs.json" "$plugin/scripts/doctor.sh" 2>&1)
echo "$out"
echo "$out" | grep -E "docs aspect +features +docs/features.md" >/dev/null && pass "doctor prints the aspects" ||
  fail "doctor does not print the aspects"
echo "$out" | grep -E "^MISSING docs aspect security" | grep -qF "docs/security.md" &&
  pass "doctor reports a missing aspect path as MISSING" || fail "no MISSING for docs/security.md"
echo "$out" | grep -E "^note .*docs/architecture/index.md has 7 lines" | grep -qF "max_lines 5" &&
  pass "doctor notes a current-state file over max_lines" || fail "no note for the oversized file"
echo "$out" | grep -E "^note .*map rule 2" | grep -qF "nowhere/*.py" && pass "doctor notes a map rule that matches no file" ||
  fail "no note for the map rule that matches nothing"
echo "$out" | grep -E "^note .*map rule 1" >/dev/null && fail "doctor noted a map rule that matches files" ||
  pass "doctor does not note a map rule that matches files"
expect "doctor without docs prints no docs lines" 0 \
  "$(DEV_LOOP_CONFIG="$work/nodocs.json" "$plugin/scripts/doctor.sh" 2>&1 | grep -c "docs aspect\|docs map\|max_lines")"
expect "the template's empty docs block keeps the docs off" "2 0" \
  "$(DEV_LOOP_CONFIG="$plugin/templates/dev-loop.json" "$plugin/scripts/docs-check.sh" "$c0" HEAD >/dev/null 2>&1
    echo "$?") $(DEV_LOOP_CONFIG="$plugin/templates/dev-loop.json" "$plugin/scripts/doctor.sh" 2>&1 | grep -c "docs ")"

# 14. Architecture: component cards, arch-check.sh, the baseline ratchet in the gate and doctor (all only
# with "architecture" configured). The edge list comes from a fake command: tools/edges.sh prints edges.txt.
git checkout -q -f main && git reset -q --hard origin/main && git clean -qfd
mkdir -p docs/architecture app/store app/core/util app/ui app/cli tools
card() { # card FILE HEADER_LINES...: a component card with that header and a free-text body
  local file=$1
  shift
  { echo "---"; printf '%s\n' "$@"; echo "---"; echo "## Responsibility"; echo "Test component."; } >"docs/architecture/$file"
}
card store.md "component: store" "layer: 0" "kind: component        # or: composition-root" "paths: app/store/*" "depends_on:"
card util.md "component: util" "layer: 0" "paths: app/core/util/*"
card core.md "component: core" "layer: 1" "paths: app/core/* app/core.py" "depends_on: store" "max_lines: 2"
card ui.md "component: ui" "layer: 2" "paths: app/ui/*"
card cli.md "component: cli" "layer: 3" "kind: composition-root" "paths: app/cli/*" "depends_on: ui"
printf '1\n2\n3\n' >app/store/s.py
printf '1\n2\n' >app/core/c.py
echo 1 >app/core/util/u.py
echo 1 >app/ui/u.py
echo 1 >app/cli/main.py
printf '#!/usr/bin/env bash\ncat edges.txt\n' >tools/edges.sh && chmod +x tools/edges.sh
cat >edges.txt <<'EOF'
app/core/c.py app/store/s.py
app/ui/u.py app/core/c.py
app/cli/main.py app/ui/u.py
app/cli/main.py app/store/s.py
app/cli/main.py util
app/store/s.py app/store/s.py
EOF
git add docs app tools edges.txt && git commit -q -m "feat: components" && git push -q origin main
cat >"$work/arch.json" <<'EOF'
{
  "base_branch": "main",
  "checks": [{"name": "unit", "command": "touch \"$SMOKE_WORK/arch-checks-ran\"; ./check.sh", "heavy": false}],
  "architecture": {"check": "./tools/edges.sh", "budget": 100}
}
EOF
arch_check() { # arch_check ARGS...: run arch-check.sh with the architecture config; sets out and rc
  out=$(DEV_LOOP_CONFIG="$work/arch.json" "$plugin/scripts/arch-check.sh" "$@" 2>&1)
  rc=$?
  echo "$out"
}
violations() { echo "$out" | sed -n 's/^arch-check: new //p' | paste -sd'|' -; }
arch_check HEAD
expect "arch-check is green for a clean component map without a baseline" 0 "$rc"
echo "$out" | grep -q "cli" && fail "a composition root's fan-out was flagged" ||
  pass "a composition root's fan-out (undeclared, by name) is not flagged"
echo "$out" | grep -q "no component" && fail "a file was reported in no component: $out" ||
  pass "every edge endpoint maps to a component (globs, names, the longest glob wins)"

# Every kind of violation, from the edge list.
a0=$(git rev-parse HEAD)
git checkout -q -b feat/90-tangle
cat >>edges.txt <<'EOF'
app/store/s.py app/ui/u.py
app/core/c.py app/core/util/u.py
core util
./scripts/stray.py app/store/s.py
EOF
printf '3\n4\n' >>app/core/c.py
git commit -q -am "feat: tangle"
arch_check HEAD
expect "arch-check is red for new violations" 1 "$rc"
expect "arch-check finds upward, undeclared, cycles and budgets as stable sorted lines" \
  "budget core 4/2|cycle core store ui|undeclared core -> util|undeclared store -> ui|upward store -> ui" "$(violations)"
expect "a cycle is shown once" 1 "$(echo "$out" | grep -c "cycle")"
echo "$out" | grep -qxF "arch-check: note: no component: scripts/stray.py" && pass "a file in no component is a note" ||
  fail "no note for scripts/stray.py: $out"
echo "$out" | grep "no component" | grep -q "new" && fail "a file in no component counted as a violation" ||
  pass "a file in no component is not a violation"

# The baseline: --baseline writes a stable sorted file; known violations are green.
arch_check --baseline
expect "arch-check --baseline exits 0" 0 "$rc"
expect "--baseline writes today's violations, sorted" \
  "budget core 4/2|cycle core store ui|undeclared core -> util|undeclared store -> ui|upward store -> ui" \
  "$(paste -sd'|' - <docs/architecture/baseline.txt 2>/dev/null)"
cp docs/architecture/baseline.txt "$work/baseline-1.txt"
arch_check --baseline HEAD
cmp -s docs/architecture/baseline.txt "$work/baseline-1.txt" && pass "--baseline writes the same file twice" ||
  fail "--baseline is not stable"
git add docs/architecture/baseline.txt && git commit -q -m "chore: architecture baseline"
arch_check HEAD
expect "known violations are green" 0 "$rc"
expect "known violations are listed as known" 5 "$(echo "$out" | grep -c '^arch-check: known ')"
echo 5 >>app/core/c.py && git commit -q -am "feat: core grows"
arch_check HEAD
expect "a component that grows past its baselined size is a new violation" "1 budget core 5/2" "$rc $(violations)"
printf '1\n2\n3\n' >app/core/c.py && git commit -q -am "feat: core shrinks"
arch_check HEAD
expect "a component that shrinks under its baselined size stays green" 0 "$rc"
grep -v "app/core/c.py app/core/util/u.py\|^core util" edges.txt >edges.new && mv edges.new edges.txt &&
  git commit -q -am "fix: core no longer uses util"
arch_check HEAD
expect "a fixed violation keeps it green" 0 "$rc"
echo "$out" | grep -qxF "arch-check: fixed undeclared core -> util (remove it from the baseline)" &&
  pass "a fixed baseline entry is reported" || fail "no fixed line: $out"
echo "app/store/s.py app/core/c.py" >>edges.txt && git commit -q -am "feat: store uses core"
arch_check HEAD
expect "a new violation next to known ones is red" "1 undeclared store -> core|upward store -> core" "$rc $(violations)"
tangle=$(git rev-parse HEAD)

# In a checkout of <ref>: another commit than HEAD, or a dirty worktree, run in a temporary worktree.
worktrees=$(git worktree list | wc -l)
git checkout -q main
arch_check "$tangle"
expect "arch-check of another commit judges that commit" "1 undeclared store -> core|upward store -> core" "$rc $(violations)"
echo "app/ui/u.py app/cli/main.py" >>edges.txt
arch_check HEAD
expect "arch-check of HEAD with uncommitted changes judges the commit" 0 "$rc"
git checkout -q -- edges.txt
expect "arch-check leaves no temporary worktree behind" "$worktrees" "$(git worktree list | wc -l)"

# Broken cards and config errors.
git checkout -q -B feat/91-broken "$a0"
card bad.md "component: bad" "layer: high" "paths: app/bad/*"
printf -- '---\ncomponent: open\nlayer: 0\npaths: x/*\n' >docs/architecture/open.md
git add docs && git commit -q -m "docs: broken cards"
arch_check HEAD
expect "a broken card makes arch-check red" 1 "$rc"
echo "$out" | grep "^arch-check: error:" | grep "docs/architecture/bad.md" | grep -qF "layer" &&
  pass "the error names the card and its bad field" || fail "bad card message: $out"
echo "$out" | grep "^arch-check: error:" | grep -qF "docs/architecture/open.md" &&
  pass "a card without its closing --- is reported" || fail "open card not reported: $out"
arch_check --baseline
expect "--baseline refuses while a card is broken" 1 "$rc"
git checkout -q main
out=$("$plugin/scripts/arch-check.sh" 2>&1)
expect "arch-check without arguments is a usage error" 2 "$?"
arch_check no-such-ref
expect "arch-check with an unknown ref is an error" 2 "$rc"
out=$(DEV_LOOP_CONFIG="$work/nodocs.json" "$plugin/scripts/arch-check.sh" HEAD 2>&1)
expect "arch-check without architecture in the config is a config error" 2 "$?"
sed 's/"budget": 100/"budget": "lots"/' "$work/arch.json" >"$work/arch-bad.json"
out=$(DEV_LOOP_CONFIG="$work/arch-bad.json" "$plugin/scripts/arch-check.sh" HEAD 2>&1)
expect "a budget that is not a number is a config error" 2 "$?"
sed 's#"./tools/edges.sh"#"exit 4"#' "$work/arch.json" >"$work/arch-fails.json"
out=$(DEV_LOOP_CONFIG="$work/arch-fails.json" "$plugin/scripts/arch-check.sh" HEAD 2>&1)
expect "a failing architecture.check is red" 1 "$?"
echo "$out" | grep -q "^arch-check: error: architecture.check failed" && pass "the failing command is named" ||
  fail "failing command message: $out"

# The gate: on the train's top, after the docs stage and before the checks; it names the branch.
git checkout -q -B main origin/main
git checkout -q -B feat/92-innocent "$a0" && echo "app/ui/u.py app/store/s.py" >>edges.txt &&
  git commit -q -am "feat: ui uses store" && git push -q -u origin feat/92-innocent
git checkout -q -B feat/93-upward feat/92-innocent && echo "app/core/c.py app/ui/u.py" >>edges.txt &&
  git commit -q -am "feat: core uses ui" && git push -q -u origin feat/93-upward
git checkout -q main
rm -f "$work/arch-checks-ran"
gate_arch() { # gate_arch CONFIG BRANCH...: run the gate; sets out and rc
  local config=$1
  shift
  out=$(DEV_LOOP_CONFIG="$config" "$plugin/scripts/gate-train.sh" "$@" 2>&1)
  rc=$?
  echo "$out"
}
gate_arch "$work/arch.json" feat/92-innocent feat/93-upward
expect "the gate is red for a new violation" "1 TRAIN RED" "$rc $(echo "$out" | tail -n 1)"
echo "$out" | grep "arch-check red for feat/93-upward" >/dev/null && pass "the architecture failure names the branch" ||
  fail "the branch is not named: $out"
echo "$out" | grep -qF "upward core -> ui" && pass "the gate prints the new violation" || fail "no violation in: $out"
echo "$out" | grep -q "arch-check red for feat/92-innocent" && fail "the innocent branch was named" ||
  pass "a branch without a new violation is not named"
[ ! -e "$work/arch-checks-ran" ] && ! echo "$out" | grep -q "^unit " &&
  pass "the architecture failure stops the train before the checks" || fail "the checks ran after an architecture failure"
git checkout -q -B feat/97-after feat/93-upward && echo after >>src.txt && git commit -q -am "feat: after" &&
  git push -q -u origin feat/97-after
git checkout -q main
gate_arch "$work/arch.json" feat/92-innocent feat/93-upward feat/97-after
echo "$out" | grep -q "arch-check red for feat/93-upward" && ! echo "$out" | grep -q "arch-check red for feat/97-after" &&
  pass "a violation below the train's top names the branch that brought it, not the ones above" ||
  fail "wrong branch named: $out"
expect "the gate leaves its worktree on the base after an architecture failure" "$(git rev-parse origin/main)" \
  "$(git -C "$(DEV_LOOP_CONFIG="$work/arch.json" "$plugin/scripts/paths.sh" gate)" rev-parse HEAD 2>/dev/null)"
gate_arch "$work/nodocs.json" feat/92-innocent feat/93-upward
expect "without architecture in the config the gate does not check it" "0 TRAIN GREEN" "$rc $(echo "$out" | tail -n 1)"
echo "$out" | grep -q "arch-check" && fail "the gate ran arch-check without architecture" ||
  pass "without architecture the gate prints no architecture lines"

# A branch that adds baseline entries needs a reason under "## Architecture" in its notes.
git checkout -q -B feat/94-excepted "$a0" && echo "app/core/c.py app/ui/u.py" >>edges.txt && git add edges.txt &&
  git commit -q -m "feat: core uses ui"
DEV_LOOP_CONFIG="$work/arch.json" "$plugin/scripts/arch-check.sh" --baseline >/dev/null 2>&1
git add docs/architecture/baseline.txt && git commit -q -m "chore: baseline the exception" && git push -q -u origin feat/94-excepted
git checkout -q main
notes94=$(DEV_LOOP_CONFIG="$work/arch.json" "$plugin/scripts/paths.sh" notes feat/94-excepted)
printf 'feat: x (#94)\n\n## Architecture\n\n## Test evidence\n- ok\n' >"$notes94"
rm -f "$work/arch-checks-ran"
gate_arch "$work/arch.json" feat/94-excepted
expect "a branch that adds baseline entries without a reason is red" "1 TRAIN RED" "$rc $(echo "$out" | tail -n 1)"
echo "$out" | grep "arch-check red for feat/94-excepted" | grep -qF "## Architecture" &&
  pass "the message names the branch and the notes section" || fail "baseline growth message: $out"
echo "$out" | grep -qF "upward core -> ui" && pass "the message lists the added entries" || fail "no entries in: $out"
printf 'feat: x (#94)\n\n## Architecture\n- core reads the ui theme until #95 moves it down\n' >"$notes94"
gate_arch "$work/arch.json" feat/94-excepted
expect "a baseline entry with a reason in ## Architecture is green" "0 TRAIN GREEN" "$rc $(echo "$out" | tail -n 1)"
[ -e "$work/arch-checks-ran" ] && pass "the checks run after a green architecture stage" || fail "the checks did not run"
rm -f "$notes94"

# A fixed baseline entry is reported by the gate (the next branch removes it).
git checkout -q -B main origin/main
cp "$work/baseline-1.txt" docs/architecture/baseline.txt && git add docs && git commit -q -m "chore: stale baseline" &&
  git push -q origin main
git checkout -q -B feat/96-plain origin/main && echo more >>src.txt && git commit -q -am "feat: plain" &&
  git push -q -u origin feat/96-plain
git checkout -q main
gate_arch "$work/arch.json" feat/96-plain
expect "fixed baseline entries keep the gate green" "0 TRAIN GREEN" "$rc $(echo "$out" | tail -n 1)"
echo "$out" | grep -F "fixed upward store -> ui" | grep -qF "remove it from the baseline" &&
  pass "the gate reports fixed baseline entries" || fail "no fixed entries in: $out"

# doctor prints the component map with sizes, reports broken cards and notes files in no component.
git checkout -q -B main origin/main
card bad.md "component: bad" "layer: high" "paths: app/bad/*"
echo "lib/loose.sh app/store/s.py" >>edges.txt
out=$(DEV_LOOP_CONFIG="$work/arch.json" "$plugin/scripts/doctor.sh" 2>&1)
echo "$out"
echo "$out" | grep -E "arch +layer 0 +store +component +3/100 lines" >/dev/null &&
  pass "doctor prints a component with its layer, kind and size against the budget" || fail "no store line"
echo "$out" | grep -E "arch +layer 1 +core +component +2/2 lines" >/dev/null &&
  pass "doctor uses a card's max_lines over the default budget" || fail "no core line"
echo "$out" | grep -E "arch +layer 3 +cli +composition-root" >/dev/null && pass "doctor shows a composition root" ||
  fail "no cli line"
[ "$(echo "$out" | grep -E '^ +arch +layer' | awk '{print $3}' | paste -sd' ' -)" = "0 0 1 2 3" ] &&
  pass "doctor lists the components by layer" || fail "components not by layer"
echo "$out" | grep -E "^MISSING .*docs/architecture/bad.md" | grep -qF "layer" && pass "doctor reports a broken card as MISSING" ||
  fail "no MISSING for the broken card"
echo "$out" | grep -E "^note .*no component" | grep -qF "lib/loose.sh" && pass "doctor notes a file in no component" ||
  fail "no note for lib/loose.sh"
echo "$out" | grep -E "^note .*architecture baseline" | grep -qF "5 entries" && pass "doctor notes the baseline size" ||
  fail "no baseline size note"
git checkout -q -- edges.txt && rm -f docs/architecture/bad.md
expect "doctor without architecture prints no architecture lines" 0 \
  "$(DEV_LOOP_CONFIG="$work/nodocs.json" "$plugin/scripts/doctor.sh" 2>&1 | grep -c "arch ")"
expect "the template's empty architecture block keeps the check off" "2 0" \
  "$(DEV_LOOP_CONFIG="$plugin/templates/dev-loop.json" "$plugin/scripts/arch-check.sh" HEAD >/dev/null 2>&1
    echo "$?") $(DEV_LOOP_CONFIG="$plugin/templates/dev-loop.json" "$plugin/scripts/doctor.sh" 2>&1 | grep -c "arch ")"
[ -f "$plugin/templates/COMPONENT.md" ] && grep -q "^kind: component" "$plugin/templates/COMPONENT.md" &&
  pass "the component card template has the header" || fail "no templates/COMPONENT.md"

# Ratchet integrity (#17): a card edit that hides a violation needs a reason, a fixed baseline entry is
# removed by the branch that fixes it, a placeholder is not a reason, and two cards may not share a glob.
git checkout -q -B main origin/main
echo "app/store/s.py app/ui/u.py" >>edges.txt
printf 'undeclared store -> ui\nupward store -> ui\n' >docs/architecture/baseline.txt
git commit -q -am "chore: a known violation" && git push -q origin main
loosen() { # loosen BRANCH: commit the working tree's edits on BRANCH, run arch-check.sh --loosened from main
  git checkout -q -B "$1"
  git add -A docs app edges.txt && git commit -q -m "feat: $1"
  arch_check --loosened origin/main HEAD >/dev/null
  hidden=$(echo "$out" | sed -n 's/^arch-check: hidden by a card edit: //p' | paste -sd'|' -)
  git checkout -q -f main
}
echo "app/core/c.py app/core/util/u.py" >>edges.txt
card core.md "component: core" "layer: 1" "paths: app/core/* app/core.py" "depends_on: store util" "max_lines: 2"
loosen feat/110-depends
expect "a name added to depends_on that hides a violation is a loosening edit" "1 undeclared core -> util" "$rc $hidden"
echo 3 >>app/core/c.py
card core.md "component: core" "layer: 1" "paths: app/core/* app/core.py" "depends_on: store" "max_lines: 5"
loosen feat/111-budget
expect "a raised max_lines that hides a budget violation is a loosening edit" "1 budget core 3/2" "$rc $hidden"
echo "app/core/util/u.py app/ui/u.py" >>edges.txt
card util.md "component: util" "layer: 2" "paths: app/core/util/*"
loosen feat/112-layer
expect "a raised layer that hides an upward dependency is a loosening edit" "1 upward util -> ui" "$rc $hidden"
echo "app/core/util/u.py app/ui/u.py" >>edges.txt
card ui.md "component: ui" "layer: 2" "paths: app/ui/other/*"
loosen feat/113-paths
expect "narrowed paths that hide violations are a loosening edit" \
  "1 undeclared store -> ui|upward store -> ui|upward util -> ui" "$rc $hidden"
echo "app/core/c.py app/core/util/u.py" >>edges.txt
card core.md "component: core" "layer: 1" "kind: composition-root" "paths: app/core/* app/core.py" "depends_on: store" \
  "max_lines: 2"
loosen feat/114-root
expect "turning a card into a composition root that hides a violation is a loosening edit" \
  "1 undeclared core -> util" "$rc $hidden"
card store.md "component: store" "layer: 3" "paths: app/store/*" "depends_on: ui"
loosen feat/115-known
expect "a card edit that hides a baselined violation is a loosening edit too" \
  "1 undeclared store -> ui|upward store -> ui" "$rc $hidden"
echo "More words about the component." >>docs/architecture/core.md
loosen feat/116-body
expect "a card edit outside the header is not a loosening edit" "0 " "$rc $hidden"
card core.md "component: core" "layer: 1" "paths: app/core/* app/core.py" "depends_on: store" "max_lines: 1"
loosen feat/117-tighter
expect "a card edit that tightens the rules is not a loosening edit" "0 " "$rc $hidden"
card dup.md "component: dup" "layer: 0" "paths: app/ui/*"
git checkout -q -B feat/118-overlap && git add docs && git commit -q -m "docs: overlapping card"
arch_check HEAD >/dev/null
expect "two cards with an identical glob are a broken card" 1 "$rc"
echo "$out" | grep "^arch-check: error:" | grep "docs/architecture/dup.md" | grep "app/ui/\*" | grep -qF "ui.md" &&
  pass "the error names both cards and the shared glob" || fail "overlap message: $out"
git checkout -q -f main

# A placeholder under "## Architecture" is not a reason.
reason_of() { # reason_of TEXT...: "yes" when notes with these lines under ## Architecture have a reason
  printf 'feat: x\n\n## Architecture\n' >"$work/reason.md"
  printf '%s\n' "$@" >>"$work/reason.md"
  printf '\n## Test evidence\n- ok\n' >>"$work/reason.md"
  bash -c '. "$1/scripts/lib/common.sh"; . "$1/scripts/lib/arch.sh"; dl_arch_notes_reason "$2" && echo yes || echo no' \
    _ "$plugin" "$work/reason.md"
}
expect "placeholders are not reasons" "no no no no no no no no no" "$(reason_of none) $(reason_of "None.") \
$(reason_of "- n/a") $(reason_of "* TODO") $(reason_of -) $(reason_of "TBD") $(reason_of '`none`') \
$(reason_of "N/A" "- none") $(reason_of "none: no architecture change")"
expect "a sentence is a reason, also next to a placeholder" "yes yes" \
  "$(reason_of "- core reads the ui theme until #95 moves it down") $(reason_of "none" "core needs util for dates")"

# The gate: a loosening edit without a reason is red, with a placeholder red, with a reason green.
git push -q -u origin feat/110-depends 2>/dev/null
notes110=$(DEV_LOOP_CONFIG="$work/arch.json" "$plugin/scripts/paths.sh" notes feat/110-depends)
rm -f "$notes110" "$work/arch-checks-ran"
gate_arch "$work/arch.json" feat/110-depends >/dev/null
expect "a loosening card edit without a reason is red" "1 TRAIN RED" "$rc $(echo "$out" | tail -n 1)"
echo "$out" | grep "arch-check red for feat/110-depends" | grep -qF "## Architecture" &&
  echo "$out" | grep -qF "  undeclared core -> util" && pass "the message names the branch and the hidden violation" ||
  fail "loosening message: $out"
[ ! -e "$work/arch-checks-ran" ] && pass "a loosening edit stops the train before the checks" ||
  fail "the checks ran after a loosening edit"
printf 'feat: x (#110)\n\n## Architecture\n- none\n' >"$notes110"
gate_arch "$work/arch.json" feat/110-depends >/dev/null
expect "a loosening card edit with a placeholder reason is red" "1 TRAIN RED" "$rc $(echo "$out" | tail -n 1)"
printf 'feat: x (#110)\n\n## Architecture\n- core formats dates with util; util is below core\n' >"$notes110"
gate_arch "$work/arch.json" feat/110-depends >/dev/null
expect "a loosening card edit with a reason is green" "0 TRAIN GREEN" "$rc $(echo "$out" | tail -n 1)"
rm -f "$notes110"
git push -q -u origin feat/116-body 2>/dev/null
gate_arch "$work/arch.json" feat/116-body >/dev/null
expect "a card body edit needs no reason" "0 TRAIN GREEN" "$rc $(echo "$out" | tail -n 1)"

# A baseline entry fixed by a branch is removed from the baseline by that branch.
git checkout -q -B feat/119-fixes origin/main && grep -vxF "app/store/s.py app/ui/u.py" edges.txt >edges.new &&
  mv edges.new edges.txt && git commit -q -am "fix: store no longer uses ui" && git push -q -u origin feat/119-fixes
git checkout -q -B feat/120-after feat/119-fixes && echo after >>src.txt && git commit -q -am "feat: after" &&
  git push -q -u origin feat/120-after
git checkout -q main
rm -f "$work/arch-checks-ran"
gate_arch "$work/arch.json" feat/119-fixes feat/120-after >/dev/null
expect "a branch that fixes baseline entries but keeps them is red" "1 TRAIN RED" "$rc $(echo "$out" | tail -n 1)"
echo "$out" | grep "arch-check red for feat/119-fixes" | grep -qF "remove" && echo "$out" | grep -qxF "  upward store -> ui" &&
  pass "the message names the fixing branch and the entries to remove" || fail "stale entry message: $out"
echo "$out" | grep -q "arch-check red for feat/120-after" && fail "the branch above the fix was named" ||
  pass "a branch above the fix is not named for it"
[ ! -e "$work/arch-checks-ran" ] && pass "a kept fixed entry stops the train before the checks" ||
  fail "the checks ran with a kept fixed entry"
git checkout -q feat/119-fixes && : >docs/architecture/baseline.txt && git commit -q -am "chore: remove fixed entries" &&
  git push -q origin feat/119-fixes && git checkout -q main
gate_arch "$work/arch.json" feat/119-fixes >/dev/null
expect "a branch that fixes baseline entries and removes them is green" "0 TRAIN GREEN" "$rc $(echo "$out" | tail -n 1)"
expect "no line of the implementer's steps is over 110 characters" "" "$(awk 'FNR > 5 && length > 110' "$plugin/agents/implementer.md")"

# 15. The slice loop and the doc-auditor: docs.prd, docs.audit_every, the audit marker and doctor's audit
# line (all only with "docs" configured), and the doc-auditor's brief and model.
git checkout -q -f main && git reset -q --hard origin/main && git clean -qfd
mkdir -p docs/specs
printf '# Features\n\n- one\n' >docs/features.md
printf '# PRD\n\n## Part one\n' >docs/specs/prd.md
audit_home="$work/home-audit"
audit_doctor() { # audit_doctor CONFIG: doctor's output with its own state directory (ledger and marker)
  DEV_LOOP_HOME="$audit_home" DEV_LOOP_CONFIG="$1" "$plugin/scripts/doctor.sh" 2>&1
}
cat >"$work/audit.json" <<'EOF'
{
  "base_branch": "main",
  "checks": [{"name": "unit", "command": "./check.sh", "heavy": false}],
  "docs": {"aspects": {"features": "docs/features.md"}, "prd": ["docs/specs/prd.md", "docs/specs/gone.md"],
           "audit_every": 2},
  "models": {"doc-auditor": "sonnet"}
}
EOF
marker=$(DEV_LOOP_HOME="$audit_home" DEV_LOOP_CONFIG="$work/audit.json" "$plugin/scripts/paths.sh" doc-audit)
expect "paths.sh doc-audit names the audit marker in the repository's state directory" \
  "$audit_home/project/doc-audit.txt" "$marker"
[ -d "$audit_home/project" ] && pass "paths.sh doc-audit creates the state directory, so the marker can be written" ||
  fail "no state directory for the marker"
out=$(audit_doctor "$work/audit.json")
echo "$out"
echo "$out" | grep -E "docs prd +docs/specs/prd.md" >/dev/null && pass "doctor prints the PRD files" ||
  fail "doctor does not print docs.prd"
echo "$out" | grep -E "^MISSING docs.prd" | grep -qF "docs/specs/gone.md" && pass "doctor reports a missing PRD file" ||
  fail "no MISSING for docs/specs/gone.md"
echo "$out" | grep -E "docs audit +0 merges since the last audit" | grep -qF "every 2" &&
  pass "doctor prints the merges since the last audit, with the cadence" || fail "no docs audit line"
echo "$out" | grep -qE "^note .*doc audit due" && fail "an audit is due with no merges" ||
  pass "no audit is due without merges"
echo "$out" | grep -qF "doc-auditor=sonnet" && pass "doctor prints the doc-auditor's model" ||
  fail "no doc-auditor in the models line"
mkdir -p "$audit_home/project"
for at in 2026-01-01T10:00:00Z 2026-01-02T10:00:00Z 2026-01-03T10:00:00Z; do
  printf '{"branch":"feat/%s","head":"abc","merged_at":"%s"}\n' "${at%%T*}" "$at" >>"$audit_home/project/merged.jsonl"
done
echo 'not json' >>"$audit_home/project/merged.jsonl"
out=$(audit_doctor "$work/audit.json")
echo "$out" | grep -E "docs audit +3 merges since the last audit" | grep -qF "none recorded" &&
  pass "without a marker every merge in the ledger counts" || fail "no count of 3: $out"
echo "$out" | grep -E "^note .*doc audit due" | grep -qF "$marker" &&
  pass "doctor notes a due audit and how to record it" || fail "no due note: $out"
echo 2026-01-01T12:00:00Z >"$marker"
out=$(audit_doctor "$work/audit.json")
echo "$out" | grep -E "docs audit +2 merges since the last audit" | grep -qF "2026-01-01T12:00:00Z" &&
  pass "only merges after the marker count" || fail "no count of 2: $out"
echo 2026-01-02T12:00:00Z >"$marker"
out=$(audit_doctor "$work/audit.json")
echo "$out" | grep -qE "^note .*doc audit due" && fail "an audit is due below docs.audit_every" ||
  pass "no audit is due below docs.audit_every"
DEV_LOOP_NO_JQ=1 audit_doctor "$work/audit.json" | grep -qE "docs audit +1 merges since the last audit" &&
  pass "the count is the same without jq" || fail "python3 count differs"
echo yesterday >"$marker"
audit_doctor "$work/audit.json" | grep -E "^MISSING .*doc-audit.txt" >/dev/null &&
  pass "doctor reports a marker that is not a UTC time" || fail "no MISSING for a bad marker"
rm -f "$marker"
sed -e 's/"audit_every": 2/"audit_every": "often"/' -e 's/"sonnet"/"gpt"/' \
  -e 's/\["docs\/specs\/prd.md", "docs\/specs\/gone.md"\]/"docs\/specs\/prd.md"/' "$work/audit.json" >"$work/audit-bad.json"
out=$(audit_doctor "$work/audit-bad.json")
echo "$out" | grep -qE '^MISSING docs.audit_every: "often"' && pass "doctor reports a docs.audit_every that is not a number" ||
  fail "no MISSING for audit_every"
echo "$out" | grep -qE '^MISSING models.doc-auditor: "gpt"' && pass "doctor reports an unknown doc-auditor model" ||
  fail "no MISSING for models.doc-auditor"
echo "$out" | grep -E "docs prd +docs/specs/prd.md" >/dev/null && ! echo "$out" | grep -q "^MISSING docs.prd" &&
  pass "docs.prd may be a single path" || fail "a single docs.prd path is not read"
printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "./check.sh"}], "docs": {"aspects": {"features": "docs/features.md"}}}\n' \
  >"$work/audit-default.json"
audit_doctor "$work/audit-default.json" | grep -E "docs audit +3 merges" | grep -qF "every 10" &&
  pass "docs.audit_every defaults to 10" || fail "audit_every default is not 10"
printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "./check.sh"}], "docs": {"prd": ["docs/specs/prd.md"], "audit_every": 1}}\n' \
  >"$work/audit-prdonly.json"
expect "without docs aspects doctor prints no audit or PRD lines" 0 \
  "$(audit_doctor "$work/audit-prdonly.json" | grep -c "docs audit\|docs prd\|doc audit")"
printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "./check.sh"}]}\n' >"$work/audit-nodocs.json"
expect "without docs doctor prints no audit or PRD lines" 0 \
  "$(audit_doctor "$work/audit-nodocs.json" | grep -c "docs audit\|docs prd\|doc audit")"
expect "the template's docs block keeps the audit off" 0 \
  "$(audit_doctor "$plugin/templates/dev-loop.json" | grep -c "docs ")"
expect "the template lists docs.prd, docs.audit_every and the doc-auditor's model" "[] 10 sonnet" \
  "$(python3 -I -c 'import json, sys; c = json.load(open(sys.argv[1]))
print(json.dumps(c["docs"].get("prd")), c["docs"].get("audit_every"), c["models"].get("doc-auditor"))' \
    "$plugin/templates/dev-loop.json" 2>/dev/null)"
auditor="$plugin/agents/doc-auditor.md"
grep -q "^name: doc-auditor$" "$auditor" 2>/dev/null && pass "the doc-auditor agent exists" || fail "no agents/doc-auditor.md"
grep "^tools:" "$auditor" 2>/dev/null | grep -qv "Write\|Edit" && pass "the doc-auditor's tools list has no Write or Edit" ||
  fail "the doc-auditor's tools are not read-only"
skill="$plugin/skills/dev-loop/SKILL.md"
[ "$(grep -c "doc-auditor" "$skill")" -ge 3 ] && grep -qF "Components:" "$skill" && grep -qF "docs.prd" "$skill" &&
  pass "the dev-loop skill starts the doc-auditor and names the ticket lines and the PRD" ||
  fail "the dev-loop skill lacks the slice loop"
git checkout -q -f main && git clean -qfd

echo "smoke: $passed passed, $failed failed (work dir $work)"
[ "$failed" -eq 0 ]
