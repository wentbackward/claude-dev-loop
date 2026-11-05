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
echo "app/store/s.py app/ui/u.py" >>edges.txt && git commit -q -am "feat: store uses ui"
arch_check --baseline >/dev/null
expect "the known violations of the base" "cycle core store ui|undeclared store -> ui|upward store -> ui" \
  "$(paste -sd'|' - <docs/architecture/baseline.txt)"
git commit -q -am "chore: known violations" && git push -q origin main
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
  "1 cycle core store ui|undeclared store -> ui|upward store -> ui|upward util -> ui" "$rc $hidden"
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
expect "reworded placeholders are not reasons" "no no no no no no no no no no" "$(reason_of "none (not configured)") \
$(reason_of "n/a (not applicable)") $(reason_of "none, n/a") $(reason_of "- none needed") $(reason_of "nothing to report") \
$(reason_of "Not applicable.") $(reason_of "none – x") $(reason_of "No, none") \
$(reason_of "no changes") $(reason_of "TODO; later")"
expect "sentences that start with a placeholder word are reasons" "yes yes" \
  "$(reason_of "- no-op rename of the util glob") $(reason_of "None of the edges cross a layer; store reads ui types")"

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

# A renamed component's old violations show as hidden, and the message says so.
sed 's/^component: store$/component: storage/' docs/architecture/store.md >store.new && mv store.new docs/architecture/store.md
sed 's/^depends_on: store$/depends_on: storage/' docs/architecture/core.md >core.new && mv core.new docs/architecture/core.md
loosen feat/121-rename
echo "$out" | grep -q "renamed or removed component" && pass "hidden violations may be a renamed component's, the message says" ||
  fail "rename message: $out"

# A branch that changes "architecture" in .dev-loop.json needs a reason too.
git checkout -q -B feat/122-config origin/main
jq '. + {"architecture": {"check": "true"}}' .dev-loop.json >cfg.new && mv cfg.new .dev-loop.json
git commit -q -am "chore: switch the architecture check off" && git push -q -u origin feat/122-config
git checkout -q main
notes122=$(DEV_LOOP_CONFIG="$work/arch.json" "$plugin/scripts/paths.sh" notes feat/122-config)
rm -f "$notes122" "$work/arch-checks-ran"
gate_arch "$work/arch.json" feat/122-config >/dev/null
expect "a branch that changes the architecture config without a reason is red" "1 TRAIN RED" \
  "$rc $(echo "$out" | tail -n 1)"
echo "$out" | grep "arch-check red for feat/122-config" | grep -F ".dev-loop.json" | grep -qF "## Architecture" &&
  pass "the message names the branch, the config and the notes section" || fail "config message: $out"
[ ! -e "$work/arch-checks-ran" ] && pass "an architecture config change stops the train before the checks" ||
  fail "the checks ran after an architecture config change"
printf 'feat: x (#122)\n\n## Architecture\n- the edge scan moves to the new tool in #123\n' >"$notes122"
gate_arch "$work/arch.json" feat/122-config >/dev/null
expect "a branch that changes the architecture config with a reason is green" "0 TRAIN GREEN" \
  "$rc $(echo "$out" | tail -n 1)"
rm -f "$notes122"

# A base that arch-check cannot judge stops the gate (exit 2) instead of passing the fixed entries.
git checkout -q -B main origin/main && git rm -q -r docs/architecture && git commit -q -m "chore: no cards" &&
  git push -q origin main
git checkout -q -B feat/124-cards origin/main && git checkout -q origin/main~1 -- docs/architecture &&
  echo "upward util -> cli" >>docs/architecture/baseline.txt && git add docs && git commit -q -m "docs: cards" &&
  git push -q -u origin feat/124-cards
git checkout -q main
gate_arch "$work/arch.json" feat/124-cards >/dev/null
echo "$out" | grep -q "arch-check error on the base" && [ "$rc" -eq 2 ] &&
  pass "an error on the base while judging fixed entries ends the gate with exit 2" || fail "base error: rc $rc: $out"
expect "no line of the implementer's steps is over 110 characters" "" "$(awk 'FNR > 5 && length > 110' "$plugin/agents/implementer.md")"

# 14b. The gate's own rules (#22): a branch that changes a gate-relevant key of .dev-loop.json needs a reason
# under "## Config"; config blocks compare as normalized JSON; the placeholder filter knows filler and repeats.
expect "trailing filler and repeated placeholders are not reasons" "no no no no no no no no no no no no no no" \
  "$(reason_of "none yet") $(reason_of "- none required") $(reason_of "Nothing changed.") $(reason_of "not relevant") \
$(reason_of "no reason") $(reason_of "nope") $(reason_of "n/a n/a") $(reason_of "none none") $(reason_of "-- none") \
$(reason_of "none needed yet") $(reason_of "not needed at all") $(reason_of "none for now") \
$(reason_of "no changes required") $(reason_of "N/A for now: later")"
expect "sentences that start with a placeholder word are still reasons" "yes yes yes" \
  "$(reason_of "none of the edges are new") $(reason_of "no-op rename of the util glob") \
$(reason_of "nothing at all reads the old glob since #95")"
expect "a placeholder word, a comma and three more words is a reason; fewer, or a colon, is not" "yes no no no no" \
  "$(reason_of "No, the check was redundant") $(reason_of "none, n/a") $(reason_of "No, none") \
$(reason_of "none, nothing to add") $(reason_of "none: the edges are all known")"
config_reason_of() { # config_reason_of HEADING TEXT...: "yes" when notes with these lines under ## HEADING have a Config reason
  printf 'fix: x\n\n## %s\n' "$1" >"$work/reason.md"
  shift
  printf '%s\n' "$@" >>"$work/reason.md"
  bash -c '. "$1/scripts/lib/common.sh"; . "$1/scripts/lib/reasons.sh"; dl_notes_reason "$2" config && echo yes || echo no' \
    _ "$plugin" "$work/reason.md"
}
expect "a reason under ## Config counts, a placeholder or another section does not" "yes no no" \
  "$(config_reason_of Config "- lint runs inside ./check.sh since #139") $(config_reason_of Config "none yet") \
$(config_reason_of Architecture "- lint runs inside ./check.sh since #139")"
normalized() { # normalized JSON: the value at "block" as normalized JSON, with jq and with the python3 fallback
  printf '%s' "$1" | bash -c '. "$1/scripts/lib/common.sh"; . "$1/scripts/lib/reasons.sh"; dl_json_normalized block' _ "$plugin"
  printf '%s' "$1" | DEV_LOOP_NO_JQ=1 bash -c '. "$1/scripts/lib/common.sh"; . "$1/scripts/lib/reasons.sh"
    dl_json_normalized block' _ "$plugin"
}
expect "a block prints as compact JSON with sorted keys, with jq and with python3" \
  '{"a":{"c":[1,{"x":2,"y":1}],"d":2},"b":"s"} {"a":{"c":[1,{"x":2,"y":1}],"d":2},"b":"s"}' \
  "$(normalized '{"block": {"b": "s", "a": {"d": 2, "c": [1, {"y": 1, "x": 2}]}}}' | paste -sd' ' -)"
expect "a missing block prints nothing, with jq and with python3" "" "$(normalized '{"other": 1}')"

git checkout -q -f main && git reset -q --hard origin/main && git clean -qfd
git checkout -q origin/main~1 -- docs/architecture
cat >.dev-loop.json <<'EOF'
{
  "base_branch": "main",
  "notes_dir": "",
  "checks": [
    {"name": "unit", "command": "./check.sh", "heavy": false},
    {"name": "lint", "command": "test -x check.sh", "heavy": false}
  ],
  "docs": {"aspects": {"features": "docs/features.md"},
           "map": [{"paths": ["src.txt"], "aspect": "features"}, {"paths": ["check.sh"], "aspect": "features"}]},
  "merge": {"method": "squash", "delete_branch": true},
  "architecture": {"check": "./tools/edges.sh", "budget": 100}
}
EOF
git add -A docs .dev-loop.json && git commit -q -m "chore: the gate's rules" && git push -q origin main
rules_branch() { # rules_branch BRANCH JQ_FILTER: a branch off main whose .dev-loop.json is the filter's output
  git checkout -q -B "$1" origin/main
  jq "$2" .dev-loop.json >cfg.new && mv cfg.new .dev-loop.json
  git commit -q -am "chore: $1" && git push -q -u origin "$1" 2>/dev/null
  git checkout -q main
}
rules_gate() { # rules_gate BRANCH [NOTES_LINE...]: gate BRANCH with these notes (none: no notes file); prints
  # the exit code and the last line, keeps the output in rules-out.txt
  local notes
  notes=$(DEV_LOOP_CONFIG="$work/arch.json" "$plugin/scripts/paths.sh" notes "$1")
  rm -f "$notes" "$work/arch-checks-ran"
  [ $# -gt 1 ] && { printf 'fix: x\n\n'; printf '%s\n' "${@:2}"; } >"$notes"
  gate_arch "$work/arch.json" "$1" >"$work/rules-out.txt"
  rm -f "$notes"
  echo "$rc $(tail -n 1 "$work/rules-out.txt")"
}
rules_branch feat/140-drop-check '.checks |= map(select(.name != "lint"))'
expect "removing a check without a reason is red" "1 TRAIN RED" "$(rules_gate feat/140-drop-check)"
grep "config-check red for feat/140-drop-check" "$work/rules-out.txt" | grep -F "(checks)" | grep -qF "## Config" &&
  pass "the message names the branch, the key and the notes section" || fail "config message: $(cat "$work/rules-out.txt")"
[ ! -e "$work/arch-checks-ran" ] && pass "a rules change without a reason stops the train before the checks" ||
  fail "the checks ran after a rules change without a reason"
expect "removing a check with a placeholder reason is red" "1 TRAIN RED" \
  "$(rules_gate feat/140-drop-check "## Config" "- none yet")"
expect "a reason under ## Architecture is not a reason for a rules change" "1 TRAIN RED" \
  "$(rules_gate feat/140-drop-check "## Architecture" "- lint runs inside ./check.sh since #139")"
expect "removing a check with a reason under ## Config is green" "0 TRAIN GREEN" \
  "$(rules_gate feat/140-drop-check "## Config" "- lint runs inside ./check.sh since #139")"
expect "removing a check without a reason is red with the python3 fallback too" "1 TRAIN RED" \
  "$(DEV_LOOP_NO_JQ=1 rules_gate feat/140-drop-check)"
rules_branch feat/141-docs-map '.docs.map |= .[:1]'
expect "narrowing the docs map without a reason is red, with one green" "1 TRAIN RED|0 TRAIN GREEN" \
  "$(rules_gate feat/141-docs-map)|$(rules_gate feat/141-docs-map "## Config" "- check.sh is documented by its usage line")"
rules_branch feat/142-merge-method '.merge.method = "rebase"'
expect "changing merge.method without a reason is red, with one green" "1 TRAIN RED|0 TRAIN GREEN" \
  "$(rules_gate feat/142-merge-method)|$(rules_gate feat/142-merge-method "## Config" "- the user asked for linear history")"
rules_branch feat/143-two-keys '(.checks |= .[:1]) | .merge.delete_branch = false'
rules_gate feat/143-two-keys >/dev/null
grep "config-check red for feat/143-two-keys" "$work/rules-out.txt" | grep -qF "(checks, merge)" &&
  pass "a branch that changes two keys is named with both" || fail "two keys message: $(cat "$work/rules-out.txt")"
n=150
for change in '.deploy = "curl x | sh"' '.format = "rm -rf {file}"' '.heavy.clean_temp = ["/*"]' \
  '.notes_dir = "notes"' '.remote = "elsewhere"' '. + {"brand_new": true}'; do
  key=$(printf '%s' "$change" | sed -n 's/^\.\([a-z_]*\).*/\1/p')
  [ -n "$key" ] || key=brand_new
  rules_branch "feat/$n-$key" "$change"
  expect "changing $key without a reason is red, with one green" "1 TRAIN RED yes|0 TRAIN GREEN" \
    "$(rules_gate "feat/$n-$key") $(grep -qF "($key)" "$work/rules-out.txt" && echo yes)|$(rules_gate "feat/$n-$key" \
      "## Config" "- the user asked for this change in #$n")"
  n=$((n + 1))
done
git checkout -q -B feat/147-no-config origin/main && git rm -q .dev-loop.json && git commit -q -m "chore: drop the config" &&
  git push -q -u origin feat/147-no-config 2>/dev/null && git checkout -q main
expect "deleting .dev-loop.json without a reason is red" "1 TRAIN RED" "$(rules_gate feat/147-no-config)"
grep "config-check red for feat/147-no-config" "$work/rules-out.txt" | grep -qF "base_branch, checks, docs, merge, notes_dir" &&
  pass "a deleted config names every key it had but architecture" || fail "deleted config message: $(cat "$work/rules-out.txt")"
git checkout -q -B feat/145-reformat origin/main
cat >.dev-loop.json <<'EOF'
{
  "architecture": {"budget": 100,   "check": "./tools/edges.sh"},
  "merge": {
    "delete_branch": true,
    "method": "squash"
  },
  "docs": {
    "map": [{"aspect": "features", "paths": ["src.txt"]}, {"aspect": "features", "paths": ["check.sh"]}],
    "aspects": {"features": "docs/features.md"}
  },
  "checks": [{"heavy": false, "command": "./check.sh", "name": "unit"},
             {"heavy": false, "command": "test -x check.sh", "name": "lint"}],
  "notes_dir": "",
  "base_branch": "main"
}
EOF
git commit -q -am "style: reorder the config" && git push -q -u origin feat/145-reformat 2>/dev/null && git checkout -q main
expect "a reordered and reformatted config (also architecture) needs no reason" "0 TRAIN GREEN" \
  "$(rules_gate feat/145-reformat)"
grep -q "red for feat/145-reformat" "$work/rules-out.txt" && fail "a reformatting was flagged: $(cat "$work/rules-out.txt")" ||
  pass "a reformatting is not named"
expect "a reordered config needs no reason with the python3 fallback too" "0 TRAIN GREEN" \
  "$(DEV_LOOP_NO_JQ=1 rules_gate feat/145-reformat)"
git checkout -q -B feat/146-plain origin/main && echo plain >>src.txt && git commit -q -am "feat: plain" &&
  git push -q -u origin feat/146-plain 2>/dev/null && git checkout -q main
expect "a branch without a config change needs no reason" "0 TRAIN GREEN" "$(rules_gate feat/146-plain)"
reviewer="$plugin/agents/code-reviewer.md"
grep -qF "## Config" "$reviewer" && grep -qF "## Architecture" "$reviewer" && grep -qi "collaborative" "$reviewer" &&
  pass "the reviewer brief reads every Architecture and Config reason and asks the user before loosening" ||
  fail "the reviewer brief lacks the rules review"
grep -qF "\`## Config\`" "$plugin/README.md" && grep -qF "see above" "$plugin/README.md" &&
  grep -qF "see above" "$reviewer" && pass "the README and the reviewer say the filter stops only lazy placeholders" ||
  fail "README or reviewer lack ## Config or the filter's limits"
git checkout -q -f main && git clean -qfd

# 14c. Config-check edges (#25): the first config is announced, not silently skipped; every key is named
# (also "" and keys with a newline, as JSON strings); two different invalid files differ; jq and python3
# agree that trailing garbage and concatenated documents are not JSON.
git init -q "$work/cfgedge"
cfg_commit() { # cfg_commit TEXT: in cfgedge, a commit whose tree holds only .dev-loop.json with TEXT ("-": none)
  local blob tree
  if [ "$1" = - ]; then
    tree=$(git -C "$work/cfgedge" mktree </dev/null)
  else
    blob=$(printf '%s' "$1" | git -C "$work/cfgedge" hash-object -w --stdin)
    tree=$(printf '100644 blob %s\t.dev-loop.json\n' "$blob" | git -C "$work/cfgedge" mktree)
  fi
  git -C "$work/cfgedge" commit-tree -m config "$tree"
}
rules_changed() { # rules_changed BEFORE AFTER: the names dl_gate_rules_changed gives, comma-joined, as "jq|python3"
  local from to nojq
  from=$(cfg_commit "$1")
  to=$(cfg_commit "$2")
  for nojq in "" 1; do
    printf '%s\n' "$(cd "$work/cfgedge" && DEV_LOOP_NO_JQ=$nojq bash -c '. "$1/scripts/lib/common.sh"
      . "$1/scripts/lib/reasons.sh"; dl_gate_rules_changed "$2" "$3"' _ "$plugin" "$from" "$to" | paste -sd, -)"
  done | paste -sd'|' -
}
expect "a key named \"\" is compared and named as \"\", with jq and with python3" '""|""' \
  "$(rules_changed '{"": 1, "checks": []}' '{"": 2, "checks": []}')"
expect "a key with a newline is named as one JSON string, with jq and with python3" '"a\nb"|"a\nb"' \
  "$(rules_changed '{"a": 1, "a\nb": 1}' '{"a": 1, "a\nb": 2}')"
expect "an unchanged key with a newline is not named" "|" "$(rules_changed '{"a\nb": 1}' '{ "a\nb" : 1 }')"
expect "two different invalid files are named as the file, with jq and with python3" ".dev-loop.json|.dev-loop.json" \
  "$(rules_changed '{bad' '{worse')"
expect "the same invalid file is no change" "|" "$(rules_changed '{bad' '{bad')"
expect "trailing garbage makes the file unparseable, with jq and with python3" "checks|checks" \
  "$(rules_changed '{"checks": 1}' '{"checks": 1} x')"
expect "concatenated documents are unparseable, with jq and with python3" "checks|checks" \
  "$(rules_changed '{"checks": 1}' '{"checks": 1}{"deploy": "x"}')"
expect "a NaN or Infinity in the file never hides a change, with jq and with python3" "yes yes|" \
  "$(rules_changed '{"a": NaN, "checks": 1}' '{"a": Infinity, "checks": 2}' | awk -F'|' '{print ($1 != "") ? "yes" : "no", ($2 != "") ? "yes" : "no"}')|$(rules_changed '{"a": NaN}' '{"a": NaN}' | tr -d '|')"
expect "a change to architecture alone is still not named" "|" \
  "$(rules_changed '{"architecture": {"budget": 1}}' '{"architecture": {"budget": 2}}')"
expect "a first config is not judged by the key comparison" "|" "$(rules_changed - '{"deploy": "x"}')"
expect "trailing garbage and concatenated documents normalize to nothing, with jq and with python3" "" \
  "$(normalized '{"block": 1} x'; normalized '{"block": 1}{"block": 2}')"
setup_project setup-first origin
setup_branch setup-first origin
cd "$work/setup-first" || exit 1
out=$(env -u DEV_LOOP_CONFIG "$plugin/scripts/gate-train.sh" chore/80-setup 2>&1)
rc=$?
expect "the gate says that the first config goes unjudged, and stays green" "0 yes" \
  "$rc $(echo "$out" | grep -qF "first .dev-loop.json on main, not judged: the user reviews it" && echo yes || echo no)"
cd "$work/project" || exit 1
rules_gate feat/146-plain >/dev/null
grep -qF "first .dev-loop.json" "$work/rules-out.txt" && fail "a branch on a base with a config got the notice" ||
  pass "a branch on a base that has a config gets no first-config notice"
grep -qF "first \`.dev-loop.json\`" "$reviewer" && grep -qF "line by line" "$reviewer" &&
  pass "the reviewer brief reads a first config with deploy or format commands line by line" ||
  fail "the reviewer brief lacks the first-config rule"
git checkout -q -f main && git clean -qfd

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

# 16. Merge evidence and the architect (#19): the ledger's new fields, arch-evidence.sh on a seeded ledger
# and fake cards, doctor's architect line and the architect's brief (all but the ledger fields only with
# "architecture" configured). The edge list comes from the fake command tools/edges.sh.
git checkout -q -f main && git reset -q --hard origin/main && git clean -qfd
ledger_of() { # ledger_of BRANCH FILTER: the jq FILTER of BRANCH's last entry in the smoke ledger
  jq -c --arg b "$1" "select(.branch == \$b) | $2" "$DEV_LOOP_HOME/project/merged.jsonl" | tail -n 1
}
expect "merge-train records the files, lines, ticket and review rounds of a merge" \
  '[["src.txt"],{"added":1,"deleted":0},1,1]' "$(ledger_of feat/1-first '[.files, .lines, .ticket, .review_rounds]')"
expect "without architecture a merge records no components" '[]' "$(ledger_of feat/1-first .components)"
expect "the ledger keeps its old fields" '["feat/2-second","2"]' "$(ledger_of feat/2-second '[.branch, .pr]')"
common_fn() { # common_fn FUNCTION ARGS...: run a helper of scripts/lib/common.sh (config loaded)
  bash -c '. "$1/scripts/lib/common.sh"; dl_load_config; f=$2; shift 2; "$f" "$@"' _ "$plugin" "$@"
}
printf 'feat: x (#7)\n\nCloses #7\n\n## Review fixes\n- a\n\n## Review fixes (round 3)\n- b\n' >"$work/rounds.md"
expect "the review rounds are one plus a Review fixes section per round" 3 \
  "$(common_fn dl_notes_review_rounds "$work/rounds.md")"
printf 'feat: x\n\nReview rounds: 4\n\n## Review fixes\n- a\n' >"$work/rounds-recorded.md"
expect "a Review rounds line the orchestrator records wins" 4 "$(common_fn dl_notes_review_rounds "$work/rounds-recorded.md")"
expect "without a notes file the review rounds are unknown (0)" 0 "$(common_fn dl_notes_review_rounds "$work/none.md")"
expect "the ticket is the notes' Closes #n, else the branch's number, else none" "7|31|" \
  "$(common_fn dl_notes_ticket "$work/rounds.md" feat/9-x)|$(common_fn dl_notes_ticket "$work/none.md" fix/31-y)|$(
    common_fn dl_notes_ticket "$work/none.md" topic)"

# Fake cards: a cycle core -> store -> ui -> core, store using the top layer, core with a fan-out of 3, a
# composition root with a fan-out of 4, two run-time components (a service and a job) connected in code.
rm -rf docs/architecture app edges.txt
mkdir -p docs/architecture app/store app/core app/api app/worker app/ui app/cli tools
card store.md "component: store" "layer: 0" "paths: app/store/*"
card core.md "component: core" "layer: 1" "paths: app/core/*" "max_lines: 2"
card api.md "component: api" "layer: 2" "kind: service" "paths: app/api/*"
card worker.md "component: worker" "layer: 2" "kind: job" "paths: app/worker/*"
card ui.md "component: ui" "layer: 3" "paths: app/ui/*"
card cli.md "component: cli" "layer: 3" "kind: composition-root" "paths: app/cli/*"
printf '1\n2\n3\n4\n' >app/core/c.py
for file in app/store/s.py app/api/a.py app/worker/w.py app/ui/u.py app/cli/main.py; do echo 1 >"$file"; done
printf '#!/usr/bin/env bash\ncat edges.txt\n' >tools/edges.sh && chmod +x tools/edges.sh
printf '%s\n' "core store" "core api" "core worker" "store ui" "ui core" "api worker" "cli ui" "cli core" "cli store" \
  "cli api" >edges.txt
cat >"$work/evidence.json" <<'EOF'
{
  "base_branch": "main",
  "checks": [{"name": "unit", "command": "./check.sh", "heavy": false}],
  "architecture": {"check": "./tools/edges.sh", "cadence": 20, "scatter": 3, "growth": 2, "co_change": 75,
                   "co_change_min": 3, "hotspot": 2, "cycle": 2, "fan_out": 2, "review_rounds": 3},
  "models": {"architect": "opus"}
}
EOF
git add -A docs app tools edges.txt && git commit -q -m "feat: evidence components"
DEV_LOOP_CONFIG="$work/evidence.json" "$plugin/scripts/arch-check.sh" --baseline >/dev/null 2>&1
git add docs && git commit -q -m "chore: evidence baseline" && git push -q origin main

# With architecture, merge-train records the components of the merged files through the cards.
git checkout -q -b feat/130-fields
printf '2\n3\n' >>app/store/s.py && echo 1 >app/api/new.py && git add app && git commit -q -m "feat: fields (Refs #130)" &&
  git push -q -u origin feat/130-fields
git checkout -q main
printf 'feat: fields (#130)\n\nCloses #130\n\n## Review fixes\n- a\n\n## Review fixes\n- b\n' \
  >"$(DEV_LOOP_CONFIG="$work/evidence.json" "$plugin/scripts/paths.sh" notes feat/130-fields)"
out=$(DEV_LOOP_CONFIG="$work/evidence.json" "$plugin/scripts/gate-train.sh" feat/130-fields 2>&1)
expect "the evidence branch is gated green" "TRAIN GREEN" "$(echo "$out" | tail -n 1)"
out=$(DEV_LOOP_CONFIG="$work/evidence.json" "$plugin/scripts/merge-train.sh" feat/130-fields 2>&1)
expect "the evidence branch merges" 0 "$?"
expect "with architecture a merge records its files, components, lines, ticket and review rounds" \
  '[["app/api/new.py","app/store/s.py"],["api","store"],{"added":3,"deleted":0},130,3]' \
  "$(ledger_of feat/130-fields '[.files, .components, .lines, .ticket, .review_rounds]')"
git fetch -q origin && git reset -q --hard origin/main
# Unusual file names: the ledger stores the real paths as valid JSON (a byte that is not UTF-8 becomes
# U+FFFD), with jq and with python3, and the readers keep going after such a line.
git checkout -q -b feat/131-names
for name in 'app/store/q"b\c.py' $'app/store/t\tb.py' $'app/store/bad\xff.py' $'app/store/n\nl.py'; do
  echo 1 >"$name"
done
git add app && git commit -q -m "feat: odd names (Refs #131)" && git push -q -u origin feat/131-names
git checkout -q main
printf 'feat: odd names (#131)\n\nCloses #131\n' \
  >"$(DEV_LOOP_CONFIG="$work/evidence.json" "$plugin/scripts/paths.sh" notes feat/131-names)"
DEV_LOOP_CONFIG="$work/evidence.json" "$plugin/scripts/gate-train.sh" feat/131-names >/dev/null 2>&1
DEV_LOOP_NO_JQ=1 DEV_LOOP_CONFIG="$work/evidence.json" "$plugin/scripts/merge-train.sh" feat/131-names >/dev/null 2>&1
expect "a merge with unusual file names merges" 0 "$?"
odd_files='["app/store/bad'$'\xef\xbf\xbd''.py","app/store/n\nl.py","app/store/q\"b\\c.py","app/store/t\tb.py"]'
expect "the ledger stores the real paths of unusual names, and their components" "[$odd_files,[\"store\"]]" \
  "$(ledger_of feat/131-names '[.files, .components]')"
python3 -I -c 'import json, sys; [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]' \
  "$DEV_LOOP_HOME/project/merged.jsonl" 2>/dev/null && pass "every ledger line is valid UTF-8 JSON for python3" ||
  fail "python3 cannot read the ledger"
expect "jq and python3 encode file lists alike" \
  "$(printf 'a"b\\c\0t\tb\0bad\377.py\0n\nl\0' | common_fn dl_json_list_z)" \
  "$(printf 'a"b\\c\0t\tb\0bad\377.py\0n\nl\0' | DEV_LOOP_NO_JQ=1 common_fn dl_json_list_z)"
expect "a JSON string escapes control characters and keeps other text" '"a\tb\nc\"d\\e\u0001f é"' \
  "$(common_fn dl_json_string $'a\tb\nc"d\\e\001f é')"
expect "a JSON string replaces a byte that is not UTF-8" '"x'$'\xef\xbf\xbd''y"' "$(common_fn dl_json_string $'x\xffy')"
# A jq that cuts its standard input at the first NUL (as jq 1.6's raw slurp may) makes the encoder use
# python3, and a merge still records every path; the real jq is used when it reads NULs whole.
expect "the encoder uses jq when it reads NUL-separated input whole" jq "$(common_fn dl_json_z_tool)"
mkdir -p "$work/nul-jq"
cat >"$work/nul-jq/jq" <<EOF
#!/usr/bin/env bash
python3 -I -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().split(b"\0")[0])' | "$(command -v jq)" "\$@"
EOF
chmod +x "$work/nul-jq/jq"
expect "a jq that cuts input at a NUL makes the encoder use python3" "python3 [\"a\",\"b\"]" \
  "$(PATH="$work/nul-jq:$PATH" common_fn dl_json_z_tool) $(printf 'a\0b\0' | PATH="$work/nul-jq:$PATH" common_fn dl_json_list_z)"
git checkout -q -b feat/134-nul-jq
echo 1 >app/store/one.py && echo 1 >app/store/two.py && git add app && git commit -q -m "feat: two (Refs #134)" &&
  git push -q -u origin feat/134-nul-jq
git checkout -q main
printf 'feat: two (#134)\n\nCloses #134\n' >"$(DEV_LOOP_CONFIG="$work/evidence.json" "$plugin/scripts/paths.sh" notes feat/134-nul-jq)"
DEV_LOOP_CONFIG="$work/evidence.json" "$plugin/scripts/gate-train.sh" feat/134-nul-jq >/dev/null 2>&1
PATH="$work/nul-jq:$PATH" DEV_LOOP_CONFIG="$work/evidence.json" "$plugin/scripts/merge-train.sh" feat/134-nul-jq >/dev/null 2>&1
expect "with a jq that cuts input at a NUL the ledger still holds every path" '["app/store/one.py","app/store/two.py"]' \
  "$(ledger_of feat/134-nul-jq .files)"
expect "without jq or python3 able to read NULs, names are kept except those with a tab or line break" \
  '["a\"b\\c","d.py"]' "$(printf 'a"b\\c\0t\tb\0d.py\0n\nl\0' | DEV_LOOP_JSON_Z=bash common_fn dl_json_list_z)"
expect "without jq or python3, the line form drops the names the JSON form drops" "a|c d" \
  "$(printf 'a\0t\tb\0n\nl\0c d\0x\001y\0' | DEV_LOOP_JSON_Z=bash common_fn dl_z_lines | paste -sd '|' -)"
expect "with jq the line form keeps every name, a tab or line break as a space" "a|t b|n l" \
  "$(printf 'a\0t\tb\0n\nl\0' | common_fn dl_z_lines | paste -sd '|' -)"
# The tool pick probes jq once per process tree: subshells (pipelines, command substitutions) and child
# scripts reuse it, while DEV_LOOP_NO_JQ, DEV_LOOP_JSON_Z and a changed PATH still pick again.
mkdir -p "$work/count-jq"
cat >"$work/count-jq/jq" <<EOF
#!/usr/bin/env bash
[ "\${*: -1}" = 'split("\u0000")' ] && echo probe >>"$work/count-jq/probes"
exec "$(command -v jq)" "\$@"
EOF
chmod +x "$work/count-jq/jq"
: >"$work/count-jq/probes"
PATH="$work/count-jq:$PATH" bash -c '. "$1/scripts/lib/common.sh"
  a=$(printf "a\0" | dl_json_list_z); b=$(printf "b\0" | dl_z_lines); c=$(dl_json_string "$(printf "c\td")")
  printf "d\0" | dl_json_list_z >/dev/null
  bash -c ". \"\$1/scripts/lib/common.sh\"; printf \"e\0\" | dl_z_lines >/dev/null" _ "$1"' _ "$plugin"
expect "the jq probe runs once for many calls in subshells and a child script" 1 \
  "$(grep -c probe "$work/count-jq/probes")"
expect "an inherited pick yields to DEV_LOOP_NO_JQ, DEV_LOOP_JSON_Z and a changed PATH" "jq python3 bash python3" \
  "$(bash -c '. "$1/scripts/lib/common.sh"; dl_json_z_tool >/dev/null
    echo "$(dl_json_z_tool) $(DEV_LOOP_NO_JQ=1 bash -c ". \"\$1/scripts/lib/common.sh\"; dl_json_z_tool" _ "$1")" \
      "$(DEV_LOOP_JSON_Z=bash bash -c ". \"\$1/scripts/lib/common.sh\"; dl_json_z_tool" _ "$1")" \
      "$(PATH="$2:$PATH" bash -c ". \"\$1/scripts/lib/common.sh\"; dl_json_z_tool" _ "$1")"' _ "$plugin" "$work/nul-jq")"
printf '{"branch":"feat/132-raw","source_head":"r\377w","head":"raw2"}\n{"branch":"feat/133-after","head":"after"}\n' \
  >>"$DEV_LOOP_HOME/project/merged.jsonl"
DEV_LOOP_NO_JQ=1 common_fn dl_ledger_heads 2>/dev/null | grep -qxF "feat/133-after after" &&
  pass "the ledger readers keep going after a line that is not UTF-8 (python3)" ||
  fail "dl_ledger_heads stops at a line that is not UTF-8"
expect "the ledger count keeps going after a line that is not UTF-8 (python3)" \
  "$(common_fn dl_ledger_count_since)" "$(DEV_LOOP_NO_JQ=1 common_fn dl_ledger_count_since)"
git fetch -q origin && git reset -q --hard origin/main

# A seeded ledger: an old line without the new fields (its files come from git), a line that is not
# JSON, a merge across four components with five review rounds, and a ticket merged twice.
printf '2\n3\n4\n' >>app/ui/u.py && git commit -q -am "feat: ui grows"
c1=$(git rev-parse HEAD)
git commit -q --allow-empty -m "feat: wide" && c2=$(git rev-parse HEAD)
git commit -q --allow-empty -m "feat: pair" && c3=$(git rev-parse HEAD)
git commit -q --allow-empty -m "fix: pair again" && c4=$(git rev-parse HEAD)
evidence_home="$work/home-evidence"
mkdir -p "$evidence_home/project"
{
  printf '{"branch":"feat/140-old","source_head":"x","head":"x","gated":"x","gated_tree":"x","pr":"1","merge_commit":"%s","merged_at":"2026-02-01T10:00:00Z"}\n' "$c1"
  echo 'not json'
  printf '{"branch":"feat/141-wide","merge_commit":"%s","merged_at":"2026-02-02T10:00:00Z","files":["app/core/c.py","app/store/s.py","app/api/a.py","app/worker/w.py"],"components":[],"lines":{"added":4,"deleted":0},"review_rounds":5,"ticket":141}\n' "$c2"
  printf '{"branch":"feat/142-pair","merge_commit":"%s","merged_at":"2026-02-03T10:00:00Z","files":["app/core/c.py","app/store/s.py"],"components":["core","store"],"lines":{"added":2,"deleted":1},"review_rounds":1,"ticket":142}\n' "$c3"
  printf '{"branch":"fix/142-again","merge_commit":"%s","merged_at":"2026-02-04T10:00:00Z","files":["app/core/c.py","app/store/s.py"],"components":["core","store"],"lines":{"added":1,"deleted":1},"review_rounds":1,"ticket":142}\n' "$c4"
} >"$evidence_home/project/merged.jsonl"
evidence() { # evidence CONFIG ARGS...: run arch-evidence.sh with the seeded ledger; sets out and rc
  local config=$1
  shift
  out=$(DEV_LOOP_HOME="$evidence_home" DEV_LOOP_CONFIG="$config" "$plugin/scripts/arch-evidence.sh" "$@" 2>&1)
  rc=$?
  echo "$out"
}
findings() { echo "$out" | sed '1,/^runtime /d' | paste -sd'|' -; }
before_status=$(git status --porcelain) before_ledger=$(cksum <"$evidence_home/project/merged.jsonl")
before_state=$(ls -a "$evidence_home/project") before_worktrees=$(git worktree list | wc -l)
evidence "$work/evidence.json"
expect "arch-evidence exits 1 when a signal is over its threshold" 1 "$rc"
expect "arch-evidence names the window first" \
  "arch-evidence: 4 merges from 2026-02-01T10:00:00Z to 2026-02-04T10:00:00Z, 6 components" "$(echo "$out" | head -n 1)"
expect "a summary table of every signal comes before the findings" \
  "signal|size|scatter|co-change|hotspot|cycle|misplaced|fan-out|friction|runtime" \
  "$(echo "$out" | sed -n '2,11p' | awk '{print $1}' | paste -sd'|' -)"
expect "the table counts the findings per signal" "2 1 1 2 1 1 1 2 1" \
  "$(echo "$out" | sed -n '3,11p' | awk '{print $2}' | paste -sd' ' -)"
expect "arch-evidence prints each signal as a stable line" \
  "size budget core 4/2|size growth ui +3 lines|scatter feat/141-wide 4 components: api core store worker|co-change core store 3/3 merges|hotspot app/core/c.py 3 merges|hotspot app/store/s.py 3 merges|cycle 3 components: core store ui|misplaced store -> ui (ui is in the top layer, 3)|fan-out core 3 components: api store worker|friction reopened #142 2 merges: feat/142-pair fix/142-again|friction rounds feat/141-wide 5 rounds|runtime api -> worker (separate at run time, connected in code)" \
  "$(findings)"
echo "$out" | grep -q "fan-out cli" && fail "a composition root's fan-out is a signal" ||
  pass "a composition root's fan-out is not a signal"
first=$out
evidence "$work/evidence.json" >/dev/null
expect "arch-evidence is deterministic" "$first" "$out"
DEV_LOOP_NO_JQ=1 evidence "$work/evidence.json" >/dev/null
expect "arch-evidence prints the same without jq" "$first" "$out"
expect "arch-evidence changes nothing (tree, ledger, state, worktrees)" \
  "$before_status|$before_ledger|$before_state|$before_worktrees" \
  "$(git status --porcelain)|$(cksum <"$evidence_home/project/merged.jsonl")|$(ls -a "$evidence_home/project")|$(git worktree list | wc -l)"
evidence "$work/evidence.json" --since 2
expect "--since <n> keeps the last n merges" \
  "size budget core 4/2|cycle 3 components: core store ui|misplaced store -> ui (ui is in the top layer, 3)|fan-out core 3 components: api store worker|friction reopened #142 2 merges: feat/142-pair fix/142-again|runtime api -> worker (separate at run time, connected in code)" \
  "$(findings)"
evidence "$work/evidence.json" --since 2026-02-02
expect "--since <date> keeps the merges from that date" \
  "arch-evidence: 3 merges from 2026-02-02T10:00:00Z to 2026-02-04T10:00:00Z, 6 components" "$(echo "$out" | head -n 1)"
printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "./check.sh"}], "architecture": {"check": "./tools/edges.sh"}}\n' \
  >"$work/evidence-default.json"
evidence "$work/evidence-default.json"
expect "the default thresholds (scatter 3, growth 500, co-change 75% of 3, hotspot 5, cycle 3, fan-out 5, rounds 3)" \
  "size budget core 4/2|scatter feat/141-wide 4 components: api core store worker|co-change core store 3/3 merges|misplaced store -> ui (ui is in the top layer, 3)|friction reopened #142 2 merges: feat/142-pair fix/142-again|friction rounds feat/141-wide 5 rounds|runtime api -> worker (separate at run time, connected in code)" \
  "$(findings)"
sed 's/"hotspot": 2/"hotspot": "often"/' "$work/evidence.json" >"$work/evidence-bad.json"
evidence "$work/evidence-bad.json" >/dev/null
expect "a threshold that is not a number is a config error" 2 "$rc"
echo "$out" | grep -qF "architecture.hotspot" && pass "the error names the threshold" || fail "threshold error: $out"
evidence "$work/evidence.json" --since soon >/dev/null
expect "a --since that is neither a count nor a date is a usage error" 2 "$rc"
evidence "$work/nodocs.json" >/dev/null
expect "arch-evidence without architecture is a config error" 2 "$rc"
mkdir -p docs/clean && card ../clean/store.md "component: store" "layer: 0" "paths: app/*"
sed -e 's#"./tools/edges.sh"#"true", "cards": "docs/clean"#' "$work/evidence.json" >"$work/evidence-clean.json"
evidence "$work/evidence-clean.json" --since 2099-01-01
expect "no signal over its threshold exits 0" "0 arch-evidence: 0 merges, 1 components" "$rc $(echo "$out" | head -n 1)"

# doctor: the merges since the architect last ran, the signals over their thresholds, models.architect.
architect_doctor() { # architect_doctor CONFIG: doctor's output with the seeded ledger
  DEV_LOOP_HOME="$evidence_home" DEV_LOOP_CONFIG="$1" "$plugin/scripts/doctor.sh" 2>&1
}
out=$(architect_doctor "$work/evidence.json")
echo "$out" | grep -E "arch architect +4 merges since the architect last ran" | grep -qF "none recorded; every 20" &&
  pass "doctor prints the merges since the architect last ran, with the cadence" || fail "no architect line: $out"
echo "$out" | grep -E "arch signals +" | grep -qF "size 2, scatter 1, co-change 1, hotspot 2, cycle 1, misplaced 1, fan-out 1, friction 2, runtime 1" &&
  pass "doctor prints the signals over their thresholds" || fail "no signals line: $out"
echo "$out" | grep -E "^note .*architect due" | grep -qF "arch-evidence.sh" && pass "doctor notes that the architect is due" ||
  fail "no architect due note: $out"
echo "$out" | grep -qF "architect=opus" && pass "doctor prints the architect's model" || fail "no architect model: $out"
marker=$(DEV_LOOP_HOME="$evidence_home" DEV_LOOP_CONFIG="$work/evidence.json" "$plugin/scripts/paths.sh" architect)
expect "paths.sh architect names the architect marker in the state directory" "$evidence_home/project/architect.txt" "$marker"
echo 2026-02-03T12:00:00Z >"$marker"
architect_doctor "$work/evidence.json" | grep -E "arch architect +1 merges since the architect last ran" |
  grep -qF "2026-02-03T12:00:00Z" && pass "only merges after the architect marker count" || fail "no count of 1"
echo 2026-02-05T12:00:00Z >"$marker"
architect_doctor "$work/evidence-clean.json" | grep -qE "^note .*architect due" && fail "the architect is due without a reason" ||
  pass "the architect is not due below the cadence without a signal since its last run"
echo soon >"$marker"
architect_doctor "$work/evidence.json" | grep -E "^MISSING .*architect.txt" >/dev/null &&
  pass "doctor reports an architect marker that is not a UTC time" || fail "no MISSING for a bad architect marker"
rm -f "$marker"
sed -e 's/"opus"/"gpt"/' -e 's/"cadence": 20/"cadence": "often"/' "$work/evidence.json" >"$work/evidence-bad.json"
out=$(architect_doctor "$work/evidence-bad.json")
echo "$out" | grep -qE '^MISSING models.architect: "gpt"' && pass "doctor reports an unknown architect model" ||
  fail "no MISSING for models.architect"
echo "$out" | grep -qE '^MISSING architecture.cadence: "often"' && pass "doctor reports a bad architecture threshold" ||
  fail "no MISSING for architecture.cadence"
expect "doctor without architecture prints no architect lines" 0 \
  "$(architect_doctor "$work/nodocs.json" | grep -c "architect \|arch signals")"
expect "the template lists the architect's cadence, scatter and model" "20 3 opus" \
  "$(python3 -I -c 'import json, sys; c = json.load(open(sys.argv[1]))
print(c["architecture"].get("cadence"), c["architecture"].get("scatter"), c["models"].get("architect"))' \
    "$plugin/templates/dev-loop.json" 2>/dev/null)"
architect="$plugin/agents/architect.md"
grep -q "^name: architect$" "$architect" 2>/dev/null && pass "the architect agent exists" || fail "no agents/architect.md"
grep "^tools:" "$architect" 2>/dev/null | grep -qv "Write\|Edit" && pass "the architect's tools list has no Write or Edit" ||
  fail "the architect's tools are not read-only"
grep -qi "extraction ladder" "$architect" && grep -qF "user's go" "$architect" &&
  pass "the architect's brief keeps the extraction ladder's last step for the user's go" || fail "no ladder in the brief"
grep -qF "arch-evidence.sh" "$skill" && grep -qF "architecture.cadence" "$skill" && grep -qF "models.architect" "$skill" &&
  pass "the dev-loop skill starts the architect on cadence or signals" || fail "the dev-loop skill lacks the architect"
git checkout -q -f main && git reset -q --hard origin/main && git clean -qfd

# Scenario store (#30): where the holdout scenarios live, their format and validation; doctor reports them.
cd "$work/project" || exit 1
scen="$work/scenarios"
mkdir -p "$scen/billing" "$scen/.git"
scenario() { # scenario FILE: write a scenario from stdin into the store
  cat >"$scen/$1"
}
scenario login.md <<'EOF'
---
id: login
title: "A returning user logs in"   # a comment
spec: [auth, "accounts"]
tags: [smoke]
required: true
---
## User and goal
A returning user wants to see their dashboard.
EOF
scenario billing/invoice.md <<'EOF'
---
id: invoice
title: The user downloads an invoice
spec: billing
tags: []
required: false
---
The user opens billing and downloads last month's invoice.
EOF
printf -- '---\r\nid: crlf\r\ntitle: Windows line ends\r\nrequired: TRUE\r\n---\r\nbody\r\n' >"$scen/crlf.md"
scenario no-id.md <<'EOF'
---
title: No id
required: false
---
body
EOF
scenario no-title.md <<'EOF'
---
id: untitled
required: false
---
body
EOF
scenario same-id.md <<'EOF'
---
id: login
title: Same id as login.md
required: false
---
body
EOF
scenario maybe.md <<'EOF'
---
id: maybe
title: Required is neither true nor false
required: yes
---
body
EOF
scenario no-required.md <<'EOF'
---
id: unsure
title: No required line
---
body
EOF
scenario empty.md <<'EOF'
---
id: empty
title: Nothing below the front matter
required: true
---

EOF
scenario plain.md <<'EOF'
Just text, no front matter.
EOF
scenario open.md <<'EOF'
---
id: open
title: Front matter never closed
required: false
EOF
echo "not a scenario" >"$scen/notes.txt"
echo "---" >"$scen/.git/HEAD.md"
scenlib() { # scenlib CODE [ARG]: run CODE (ARG is its $1) with the scenario library loaded, in the throwaway project
  DEV_LOOP_CONFIG="${scen_config:-$work/scen.json}" bash -c '. "$0/scripts/lib/common.sh"; . "$0/scripts/lib/scenarios.sh"
dl_load_config; code=$1; shift; eval "$code"' "$plugin" "$1" "${2:-}" 2>&1
}
printf '{"checks": ["true"], "scenarios": {"dir": "%s", "run": "make scenario-env", "pass": 0.8}}\n' "$scen" >"$work/scen.json"
printf '{"checks": ["true"]}\n' >"$work/scen-none.json"
expect "paths.sh scenarios prints scenarios.dir" "$scen" \
  "$(DEV_LOOP_CONFIG="$work/scen.json" "$plugin/scripts/paths.sh" scenarios)"
printf '{"checks": ["true"], "scenarios": {}}\n' >"$work/scen-default.json"
expect "paths.sh scenarios defaults to ~/.dev-loop/<repo>/scenarios" "$DEV_LOOP_HOME/project/scenarios" \
  "$(DEV_LOOP_CONFIG="$work/scen-default.json" "$plugin/scripts/paths.sh" scenarios)"
printf '{"checks": ["true"], "scenarios": {"dir": "~/stores/<repo>/scenarios"}}\n' >"$work/scen-repo.json"
expect "paths.sh scenarios expands ~ and <repo> in scenarios.dir" "$HOME/stores/project/scenarios" \
  "$(DEV_LOOP_CONFIG="$work/scen-repo.json" "$plugin/scripts/paths.sh" scenarios)"
expect "the library knows when scenarios are configured" "on off" \
  "$(scenlib 'dl_scenarios_on && echo on || echo off') $(scen_config="$work/scen-none.json" scenlib 'dl_scenarios_on && echo on || echo off')"
expect "the library lists the Markdown files of the store, sorted, subfolders included, .git left out" \
  "billing/invoice.md crlf.md empty.md login.md maybe.md no-id.md no-required.md no-title.md open.md plain.md same-id.md" \
  "$(scenlib 'dl_scenarios_files "$(dl_scenarios_dir)"' | sed "s#^$scen/##" | paste -sd' ' -)"
expect "a store that does not exist lists no files" "" "$(scenlib 'dl_scenarios_files /nonexistent/store')"
expect "the library reads front-matter fields, without quotes or comments" "login|A returning user logs in|true" \
  "$(scenlib 'f=$(dl_scenarios_dir)/login.md; echo "$(dl_scenario_field "$f" id)|$(dl_scenario_field "$f" title)|$(dl_scenario_field "$f" required)"')"
expect "a list field reads one item per line, a scalar as one item, [] as none" "auth accounts|billing|" \
  "$(scenlib 'd=$(dl_scenarios_dir); echo "$(dl_scenario_list "$d/login.md" spec | paste -sd" " -)|$(dl_scenario_list "$d/billing/invoice.md" spec)|$(dl_scenario_list "$d/billing/invoice.md" tags)"')"
expect "a field outside the front matter is not read" "" \
  "$(scenlib 'dl_scenario_field "$(dl_scenarios_dir)/plain.md" id')"
expect "front matter with CRLF line ends reads clean values" "crlf|TRUE" \
  "$(scenlib 'f=$(dl_scenarios_dir)/crlf.md; echo "$(dl_scenario_field "$f" id)|$(dl_scenario_field "$f" required)"')"
out=$(scenlib 'dl_scenarios_validate "$(dl_scenarios_dir)"; echo "rc=$?"')
echo "$out"
invalid() { # invalid FILE REASON: the validation names FILE with REASON
  printf '%s\n' "$out" | grep -F "$1" | grep -qF "$2" && pass "validation: $1 is invalid ($2)" ||
    fail "validation does not report $1 with '$2': $out"
}
invalid no-id.md "missing id"
invalid no-title.md "missing title"
invalid same-id.md "duplicate id login (also in login.md)"
invalid maybe.md 'required: "yes" is not true or false'
invalid no-required.md 'required: "" is not true or false'
invalid crlf.md 'required: "TRUE" is not true or false'
invalid empty.md "empty body"
invalid plain.md "no front matter"
invalid open.md "front matter is not closed"
for good in login.md billing/invoice.md; do
  printf '%s\n' "$out" | awk -F'\t' -v f="$good" '$1 == f { found = 1 } END { exit !found }' && fail "validation reports the valid $good" || pass "validation accepts the valid $good"
done
expect "validation fails when a file is invalid" "rc=1" "$(printf '%s\n' "$out" | tail -n 1)"
expect "validation prints one line per problem, file then reason" 9 "$(printf '%s\n' "$out" | grep -c $'^[^\t]*\.md\t')"
mkdir -p "$work/scen-edge"
printf -- '---\nid: a\\b\ntitle: Backslash id\nrequired: false\n---\nbody\n' >"$work/scen-edge/one.md"
printf -- '---\nid: a\\b\ntitle: Same backslash id\nrequired: false\n---\nbody\n' >"$work/scen-edge/two.md"
printf -- '\357\273\277---\nid: bom\ntitle: Starts with a byte order mark\nrequired: true\n---\nbody\n' >"$work/scen-edge/bom.md"
mkdir -p "$work/scen-target" && cp "$scen/login.md" "$work/scen-target/linked.md"
ln -s "$work/scen-target/linked.md" "$work/scen-edge/linked.md"
ln -s "$work/scen-target" "$work/scen-edge/dir.md"
out=$(scenlib 'dl_scenarios_validate "$1"; echo "rc=$?"' "$work/scen-edge")
expect "a duplicate id with a backslash is found, nothing else is invalid" \
  "two.md	duplicate id a\\b (also in one.md)|rc=1" "$(printf '%s\n' "$out" | paste -sd'|' -)"
expect "a symlinked scenario file is listed, a symlinked folder named *.md is not" "bom.md linked.md one.md two.md" \
  "$(scenlib 'dl_scenarios_files "$1"' "$work/scen-edge" | sed "s#^$work/scen-edge/##" | paste -sd' ' -)"
expect "a UTF-8 byte order mark before the front matter is ignored" "bom true" \
  "$(scenlib 'echo "$(dl_scenario_field "$1/bom.md" id) $(dl_scenario_field "$1/bom.md" required)"' "$work/scen-edge")"
mkdir -p "$work/scen-good" && cp "$scen/login.md" "$scen/billing/invoice.md" "$work/scen-good/"
expect "validation of a store with only valid files passes silently" "rc=0" \
  "$(scenlib 'dl_scenarios_validate "$1"; echo "rc=$?"' "$work/scen-good")"
expect "the library counts the scenarios and the required ones (exactly true)" "11 2" \
  "$(scenlib 'd=$(dl_scenarios_dir); echo "$(dl_scenarios_count "$d") $(dl_scenarios_required_count "$d")"')"
out=$(DEV_LOOP_CONFIG="$work/scen.json" "$plugin/scripts/doctor.sh" 2>&1)
echo "$out" | grep -E "^ +scenarios +$scen\$" >/dev/null && pass "doctor prints the scenario store" || fail "no store line: $out"
echo "$out" | grep -E "^ +scenarios +11 files, 2 required" >/dev/null && pass "doctor prints the count and the required count" ||
  fail "no count line: $out"
expect "doctor reports each invalid scenario file as MISSING" 9 "$(echo "$out" | grep -c "^MISSING scenario ")"
echo "$out" | grep -qF "MISSING scenario same-id.md: duplicate id login" && pass "doctor names the file and the reason" ||
  fail "no reason in doctor: $out"
printf '{"checks": ["true"], "scenarios": {"dir": "%s", "pass": 2, "min_satisfaction": "high", "sealed": 0.2}}\n' "$scen" >"$work/scen-bad.json"
out=$(DEV_LOOP_CONFIG="$work/scen-bad.json" "$plugin/scripts/doctor.sh" 2>&1)
echo "$out" | grep -qE '^MISSING scenarios.pass: "2" is not a number from 0 to 1' && pass "doctor reports a pass threshold over 1" ||
  fail "no MISSING for scenarios.pass: $out"
echo "$out" | grep -qE '^MISSING scenarios.min_satisfaction: "high"' && pass "doctor reports a threshold that is not a number" ||
  fail "no MISSING for scenarios.min_satisfaction"
echo "$out" | grep -qE '^MISSING scenarios.sealed' && fail "doctor reports a valid sealed share" || pass "doctor accepts sealed 0.2"
out=$(DEV_LOOP_CONFIG="$work/scen-default.json" "$plugin/scripts/doctor.sh" 2>&1)
echo "$out" | grep -E "^note .*scenario store $DEV_LOOP_HOME/project/scenarios does not exist" >/dev/null &&
  pass "doctor notes a scenario store that does not exist yet" || fail "no note for a missing store: $out"
printf '{"checks": ["true"], "scenarios": {"dir": "scenarios"}}\n' >"$work/scen-inside.json"
DEV_LOOP_CONFIG="$work/scen-inside.json" "$plugin/scripts/doctor.sh" 2>&1 | grep -E "^note .*inside the repository" >/dev/null &&
  pass "doctor notes a scenario store inside the repository" || fail "no note for a store inside the repository"
expect "doctor without scenarios prints no scenario lines" 0 \
  "$(DEV_LOOP_CONFIG="$work/scen-none.json" "$plugin/scripts/doctor.sh" 2>&1 | grep -ci "scenario")"
expect "doctor's output without scenarios is unchanged by an empty store directory" \
  "$(DEV_LOOP_CONFIG="$work/scen-none.json" "$plugin/scripts/doctor.sh" 2>&1)" \
  "$(mkdir -p "$DEV_LOOP_HOME/project/scenarios"; DEV_LOOP_CONFIG="$work/scen-none.json" "$plugin/scripts/doctor.sh" 2>&1)"
rmdir "$DEV_LOOP_HOME/project/scenarios"
example="$plugin/templates/scenario.md"
mkdir -p "$work/scen-example" && cp "$example" "$work/scen-example/"
expect "the example scenario in templates/ is valid" "1 rc=0" \
  "$(scenlib 'echo "$(dl_scenarios_count "$1") $(dl_scenarios_validate "$1"; echo "rc=$?")"' "$work/scen-example")"
grep -qF "scenarios.dir" "$plugin/README.md" && grep -qF "min_satisfaction" "$plugin/README.md" &&
  grep -qF "templates/scenario.md" "$plugin/README.md" && pass "the README documents the scenario keys and the example" ||
  fail "the README lacks the scenario keys"

# Scenario isolation (#31): the role guard keeps the store from the implementer, test-engineer and reviewer.
iso="$work/iso"
iso_home="$work/iso-home"
mkdir -p "$iso_home"
git init -q "$iso/guardproj"
printf '{"scenarios": {"dir": "~/.dev-loop/<repo>/holdout"}}\n' >"$iso/guardproj/.dev-loop.json"
git -C "$iso/guardproj" add . && git -C "$iso/guardproj" commit -q -m "chore: start"
git -C "$iso/guardproj" worktree add -q -b feat/1-x "$iso/guardproj-1" 2>/dev/null
store="$iso_home/.dev-loop/guardproj/holdout"
mkdir -p "$store" "$iso_home/.dev-loop/guardproj/holdout-old" && echo secret >"$store/a.md"
ln -s "$store" "$iso/peek"
ln -s "$store/a.md" "$iso/peek-file"
sguard() { # sguard AGENT TOOL KEY VALUE [CWD] [CONFIG] -> exit status of the guard on that tool call
  python3 -I -c 'import json, sys; print(json.dumps({"tool_name": sys.argv[2], "cwd": sys.argv[5],
    "agent_type": sys.argv[1] or None, "tool_input": {sys.argv[3]: sys.argv[4]}}))' \
    "$1" "$2" "$3" "$4" "${5:-$iso/guardproj-1}" |
    HOME="$iso_home" DEV_LOOP_HOME="$iso_home/.dev-loop" CLAUDE_PROJECT_DIR="${5:-$iso/guardproj-1}" \
      DEV_LOOP_CONFIG="${6:-}" "$plugin/hooks/guard-role.sh" 2>/dev/null
  echo $?
}
expect "isolation: the implementer may not Read a scenario" 2 "$(sguard dev-loop:implementer Read file_path "$store/a.md")"
expect "isolation: the test-engineer may not Grep the store" 2 "$(sguard dev-loop:test-engineer Grep path "$store")"
expect "isolation: the code-reviewer may not Glob the store" 2 "$(sguard dev-loop:code-reviewer Glob pattern "$store/**/*.md")"
expect "isolation: the implementer may not Write into the store" 2 "$(sguard dev-loop:implementer Write file_path "$store/new.md")"
expect "isolation: the implementer may not Edit a scenario" 2 "$(sguard implementer Edit file_path "$store/a.md")"
expect "isolation: the implementer may not cat the store via ~" 2 \
  "$(sguard dev-loop:implementer Bash command 'cat ~/.dev-loop/guardproj/holdout/a.md')"
expect "isolation: the tester may not list the store via \$HOME" 2 \
  "$(sguard dev-loop:test-engineer Bash command 'ls "$HOME/.dev-loop/guardproj/holdout"')"
expect "isolation: a relative path into the store is refused" 2 \
  "$(sguard dev-loop:implementer Bash command 'cat ../../iso-home/.dev-loop/guardproj/holdout/a.md')"
expect "isolation: a relative path after cd into the store's parent is refused" 2 \
  "$(sguard dev-loop:implementer Bash command "cd $iso_home/.dev-loop/guardproj && grep -r x holdout")"
expect "isolation: a relative Read path into the store is refused" 2 \
  "$(sguard dev-loop:code-reviewer Read file_path '../../iso-home/.dev-loop/guardproj/holdout/a.md')"
expect "isolation: a Read through a symlink to the store is refused" 2 "$(sguard dev-loop:implementer Read file_path "$iso/peek/a.md")"
expect "isolation: a cat of a symlink to a scenario file is refused" 2 \
  "$(sguard dev-loop:implementer Bash command "cat $iso/peek-file")"
expect "isolation: a glob that matches the store is refused" 2 \
  "$(sguard dev-loop:implementer Bash command "cat $iso_home/.dev-loop/*/holdout/*.md")"
expect "isolation: a store path inside a quoted script is refused" 2 \
  "$(sguard dev-loop:implementer Bash command "python3 -c \"print(open('$store/a.md').read())\"")"
expect "isolation: a redirect from the store is refused" 2 \
  "$(sguard dev-loop:implementer Bash command "wc -l <$store/a.md")"
expect "isolation: the main session may read the store" 0 "$(sguard "" Read file_path "$store/a.md")"
expect "isolation: the scenario-judge may read the store" 0 "$(sguard dev-loop:scenario-judge Bash command "cat $store/a.md")"
expect "isolation: the scenario-writer may write into the store" 0 "$(sguard dev-loop:scenario-writer Write file_path "$store/b.md")"
expect "isolation: the verifier is not refused" 0 "$(sguard dev-loop:verifier Read file_path "$store/a.md")"
expect "isolation: the implementer may read its worktree" 0 "$(sguard dev-loop:implementer Read file_path "$iso/guardproj-1/.dev-loop.json")"
expect "isolation: the implementer may run ordinary commands" 0 \
  "$(sguard dev-loop:implementer Bash command 'git status && grep -r holdout . && cat .dev-loop.json')"
expect "isolation: a sibling directory with the same prefix is not the store" 0 \
  "$(sguard dev-loop:implementer Bash command 'ls ~/.dev-loop/guardproj/holdout-old')"
printf '{"checks": ["true"]}\n' >"$iso/no-scenarios.json"
expect "isolation: without scenarios nothing is refused" 0 \
  "$(sguard dev-loop:implementer Read file_path "$iso_home/.dev-loop/guardproj/scenarios/a.md" "" "$iso/no-scenarios.json")"
python3 -I -c 'import json, sys; json.dump({"scenarios": {}, "identities": {r: {"type": "token", "token_file": "/x/" + r + ".token"}
  for r in ("implementer", "tester", "reviewer", "gate", "orchestrator")}}, open(sys.argv[1], "w"))' "$iso/identity.json"
mkdir -p "$iso_home/.dev-loop/guardproj/scenarios"
expect "isolation: identity mode refuses the default store too" 2 \
  "$(sguard dev-loop:implementer Read file_path "$iso_home/.dev-loop/guardproj/scenarios/a.md" "" "$iso/identity.json")"
expect "isolation: identity mode still refuses a raw push" 2 \
  "$(sguard dev-loop:implementer Bash command 'git push origin HEAD' "" "$iso/identity.json")"
expect "isolation: identity mode still allows a push as the implementer" 0 \
  "$(sguard dev-loop:implementer Bash command "$plugin/scripts/as-role.sh implementer git push origin HEAD" "" "$iso/identity.json")"
expect "isolation: scenarios without identities still allow a raw push" 0 \
  "$(sguard dev-loop:implementer Bash command 'git push origin HEAD')"
printf '{"scenarios": {"dir": "holdout"}}\n' >"$iso/relative.json"
expect "isolation: a relative scenarios.dir is the main worktree's, also from a linked worktree" 2 \
  "$(sguard dev-loop:implementer Bash command "cat $iso/guardproj/holdout/x.md" "" "$iso/relative.json")"
expect "isolation: a relative scenarios.dir does not cover the linked worktree's copy" 0 \
  "$(sguard dev-loop:implementer Read file_path "$iso/guardproj-1/holdout/x.md" "" "$iso/relative.json")"
same=0
# shellcheck disable=SC2088  # the literal ~ is the config value under test
for dir in '' '~/stores/<repo>/scen' 'rel/<repo>' "$iso/abs" number; do
  if [ "$dir" = number ]; then printf '{"scenarios": {"dir": 7}}\n'; elif [ -z "$dir" ]; then printf '{"scenarios": {}}\n'
  else printf '{"scenarios": {"dir": "%s"}}\n' "$dir"; fi >"$iso/sync.json"
  for at in "$iso/guardproj" "$iso/guardproj-1"; do
    from_bash=$(cd "$at" && HOME="$iso_home" DEV_LOOP_HOME="$iso_home/dlh" DEV_LOOP_CONFIG="$iso/sync.json" "$plugin/scripts/paths.sh" scenarios)
    from_python=$(HOME="$iso_home" DEV_LOOP_HOME="$iso_home/dlh" DEV_LOOP_CONFIG="$iso/sync.json" \
      python3 -I "$plugin/hooks/guard-role.py" --scenarios-dir "$at" </dev/null)
    [ -n "$from_bash" ] && [ "$from_bash" = "$from_python" ] && same=$((same + 1)) ||
      echo "  store path differs for dir '$dir' at $at: bash '$from_bash', python '$from_python'"
  done
done
expect "isolation: the guard resolves scenarios.dir exactly like paths.sh scenarios" 10 "$same"
nul_event='{"tool_name": "Read", "cwd": "'"$iso/guardproj-1"'", "agent_type": "dev-loop:implementer", "tool_input": {"file_path": "/x\u0000y"}}'
expect "isolation: a NUL byte in a Read path is refused" 2 \
  "$(printf '%s' "$nul_event" | HOME="$iso_home" CLAUDE_PROJECT_DIR="$iso/guardproj-1" "$plugin/hooks/guard-role.sh" 2>/dev/null; echo $?)"
nul_event='{"tool_name": "Bash", "cwd": "'"$iso/guardproj-1"'", "agent_type": "dev-loop:test-engineer", "tool_input": {"command": "cat /x\u0000y"}}'
expect "isolation: a NUL byte in a Bash command is refused" 2 \
  "$(printf '%s' "$nul_event" | HOME="$iso_home" CLAUDE_PROJECT_DIR="$iso/guardproj-1" "$plugin/hooks/guard-role.sh" 2>/dev/null; echo $?)"
outside_event='{"tool_name": "Bash", "cwd": "'"$iso_home"'", "agent_type": "dev-loop:implementer", "tool_input": {"command": "cat .dev-loop/guardproj/holdout/a.md"}}'
expect "isolation: from a cwd outside any repository the store comes from the project directory" 2 \
  "$(printf '%s' "$outside_event" | HOME="$iso_home" DEV_LOOP_HOME="$iso_home/.dev-loop" CLAUDE_PROJECT_DIR="$iso/guardproj-1" \
    "$plugin/hooks/guard-role.sh" 2>/dev/null; echo $?)"
grep -qi "scenario" "$plugin/templates/settings.json" && fail "templates/settings.json has a scenario deny rule (it would block the judge)" ||
  pass "templates/settings.json has no deny rule that would block the scenario-judge"
grep -qF "agent-type guard" "$plugin/README.md" && grep -qF "no access to the scenarios repository" "$plugin/README.md" &&
  pass "the README explains the agent-type guard and the identity-mode note" || fail "the README lacks the isolation section"

# Scenario writer and the orchestrator's scenario steps (#33): the writer brief writes only to the
# store, from the spec; no implementer, test-engineer or code-reviewer brief or prompt names the store;
# doctor's models line gains scenario-writer only when scenarios are on (or it is set).
writer="$plugin/agents/scenario-writer.md"
skill="$plugin/skills/dev-loop/SKILL.md"
if [ -f "$writer" ]; then pass "the scenario-writer agent exists"; else fail "no agents/scenario-writer.md"; fi
grep -qE '^tools: Read, Grep, Glob, Write, Edit, Bash$' "$writer" 2>/dev/null && pass "the writer has the file tools and Bash" ||
  fail "the writer's tools line is not Read, Grep, Glob, Write, Edit, Bash"
grep -qF "paths.sh scenarios" "$writer" 2>/dev/null && pass "the writer finds the store with paths.sh scenarios" ||
  fail "the writer brief does not name paths.sh scenarios"
grep -qF "You write only inside the scenario store" "$writer" 2>/dev/null && pass "the writer brief says it writes only to the store" ||
  fail "the writer brief does not limit its writes to the store"
grep -qF "never from the code" "$writer" 2>/dev/null && grep -qF "never implement" "$writer" 2>/dev/null &&
  pass "the writer brief writes from the spec, never from the code, and never implements" ||
  fail "the writer brief lacks 'never from the code' or 'never implement'"
for brief in implementer test-engineer code-reviewer; do
  if grep -qiE 'scenarios\.dir|paths\.sh scenarios|scenario store|holdout' "$plugin/agents/$brief.md"; then
    fail "the $brief brief names the scenario store"
  else pass "the $brief brief never names the scenario store"; fi
done
# The prompt templates the skill fills for the coding agents (fenced blocks opening with these words).
coder_prompts=$(awk '/^```/ { if (inblock) { inblock = 0; keep = 0 } else { inblock = 1; first = 1 }; next }
  inblock && first { first = 0; keep = ($0 ~ /^(Implement ticket|Review branch|Write the failing tests)/) }
  inblock && keep' "$skill")
[ -n "$coder_prompts" ] && pass "the skill's implementer and reviewer prompt templates are found" || fail "no prompt templates found"
if printf '%s\n' "$coder_prompts" | grep -qiE 'scenario'; then fail "a coding agent's prompt template mentions scenarios"
else pass "no implementer or reviewer prompt template mentions scenarios"; fi
section=$(awk '/^## / { on = ($0 ~ /^## [0-9a-z]*\.? ?Scenarios/) } on' "$skill")
[ -n "$section" ] && pass "the dev-loop skill has a Scenarios section" || fail "no Scenarios section in the dev-loop skill"
for phrase in "scenario-writer" "models.scenario-writer" "at ticket creation" "titles only" "missing behaviour" \
  "never put the store path"; do
  printf '%s\n' "$section" | grep -qiF "$phrase" && pass "the Scenarios section covers: $phrase" ||
    fail "the Scenarios section lacks: $phrase"
done
writer_model() { # writer_model CONFIG: the models line of doctor.sh
  DEV_LOOP_CONFIG="$1" "$plugin/scripts/doctor.sh" 2>&1 | grep -E '^ +models +'
}
printf '{"checks": ["true"], "scenarios": {}, "models": {"scenario-writer": "sonnet"}}\n' >"$work/writer-on.json"
writer_model "$work/writer-on.json" | grep -qF "scenario-writer=sonnet" && pass "doctor's models line lists scenario-writer" ||
  fail "no scenario-writer in the models line: $(writer_model "$work/writer-on.json")"
printf '{"checks": ["true"], "scenarios": {}}\n' >"$work/writer-default.json"
writer_model "$work/writer-default.json" | grep -qF "scenario-writer=inherit" &&
  pass "doctor lists scenario-writer=inherit when scenarios are on and no model is set" || fail "no scenario-writer=inherit"
printf '{"checks": ["true"]}\n' >"$work/writer-off.json"
writer_model "$work/writer-off.json" | grep -qF "scenario-writer" && fail "doctor lists scenario-writer without scenarios" ||
  pass "doctor's models line is unchanged without scenarios"
printf '{"checks": ["true"], "models": {"scenario-writer": "gpt"}}\n' >"$work/writer-bad.json"
DEV_LOOP_CONFIG="$work/writer-bad.json" "$plugin/scripts/doctor.sh" 2>&1 |
  grep -qF 'MISSING models.scenario-writer: "gpt"' && pass "doctor reports an unknown scenario-writer model, also without scenarios" ||
  fail "no MISSING for models.scenario-writer"
grep -qF "scenario-writer" "$plugin/README.md" && grep -qF "models.scenario-writer" "$plugin/README.md" &&
  pass "the README documents the scenario writer and its model" || fail "the README lacks the scenario writer"
awk '/^## Unreleased/ { on = 1; next } /^## / { on = 0 } on' "$plugin/CHANGELOG.md" | grep -qF "scenario-writer" &&
  pass "the changelog names the scenario writer under Unreleased" || fail "no changelog entry for the scenario writer"
# Scenario judge and gate stage (#32): the gate starts scenarios.run, judges each scenario with the judge
# command (a fake here: it reads its scores from the scenario's own front matter), rejudges a failure once
# and decides green or red; sealed scenarios are only counted, and no scenario text reaches the output.
cd "$work/project" || exit 1
git fetch -q origin
git checkout -q -B feat/32-judge origin/main
mkdir -p billing && echo invoice >billing/invoice.txt && echo "line four" >>src.txt && git add billing src.txt &&
  git commit -q -m "feat: invoices (Refs #32)" && git push -q -u origin feat/32-judge
cat >"$work/fake-judge.sh" <<'EOF'
#!/usr/bin/env bash
# A fake scenario judge: the score of attempt n is the n-th item of fake_scores (the last one repeats).
field() { awk -v k="$1" 'NR > 1 && /^---/ { exit } index($0, k ": ") == 1 { print substr($0, length(k) + 3) }' "$DL_SCENARIO_FILE"; }
id=$(field id)
calls="$SMOKE_WORK/judge-calls.log"
n=$(($(grep -c "^$id " "$calls" 2>/dev/null) + 1))
echo "$id $n id=$DL_SCENARIO_ID target=$DL_SCENARIO_TARGET checks=$([ -e "$SMOKE_WORK/checks-done" ] && echo done || echo running)" >>"$calls"
score=$(field fake_scores | awk -v n="$n" '{ print (n <= NF ? $n : $NF) }')
case $(field fake_output) in
  garbage) echo "I could not decide"; exit 0 ;;
  crash) exit 3 ;;
  other-id) id=someone-else ;;
esac
echo "chatter before the verdict"
printf '{"id": "%s", "satisfied": %s, "required": true, "evidence": "EVIDENCE-%s seen", "missing": "%s"}\n' \
  "$id" "$score" "$id" "$(field fake_missing)"
EOF
chmod +x "$work/fake-judge.sh"
jstore="$work/judge-store"
# jscenario ID REQUIRED SCORES [EXTRA FRONT MATTER]: write a scenario with a secret body into the judge store.
jscenario() {
  printf -- '---\nid: %s\ntitle: Scenario %s\nrequired: %s\nfake_scores: %s\n%s---\nSECRET-BODY-%s: the user does the hidden steps.\n' \
    "$1" "$1" "$2" "$3" "${4:+$4
}" "$1" >"$jstore/$1.md"
}
# jstore_reset: an empty judge store.
jstore_reset() { rm -rf "$jstore" && mkdir -p "$jstore"; }
# jgate JSON_MEMBERS [SCENARIO_MEMBERS]: gate feat/32-judge with these config members and a scenarios block
# (store, fake judge, a run command that records its pid); sets out, rc, stage_log.
jgate() {
  local scen=${2-'"scenarios": {"dir": "'"$jstore"'", "judge": "'"$work"'/fake-judge.sh", "heavy": false,
    "run": "echo $$ >\"$SMOKE_WORK/run.pid\"; echo http://127.0.0.1:9550/; exec sleep 300"}'}
  printf '{"base_branch": "main", %s%s, "heavy": {"slots": 2, "port_env": "SMOKE_PORT", "port_base": 9500, "port_step": 10, "poll_seconds": 1}}\n' \
    "$1" "${scen:+, $scen}" >"$work/jgate.json"
  rm -f "$work/judge-calls.log" "$work/run.pid" "$work/checks-done"
  out=$(DEV_LOOP_CONFIG="$work/jgate.json" "$plugin/scripts/gate-train.sh" feat/32-judge 2>&1)
  rc=$?
  stage_log="$("$plugin/scripts/paths.sh" logs)/train-scenarios.log"
  echo "$out"
}
# judged: the ids the fake judge was called for, with their attempt, sorted.
judged() { awk '{ print $1 "#" $2 }' "$work/judge-calls.log" 2>/dev/null | LC_ALL=C sort | paste -sd' ' -; }
# no_leak WHAT: neither the gate output nor the stage log holds a scenario body, evidence or WHAT.
no_leak() {
  if printf '%s\n' "$out" | cat - "$stage_log" 2>/dev/null | grep -qE "SECRET-BODY|EVIDENCE-${1:-}"; then
    fail "scenario text or evidence leaked into the gate output or the stage log"
  else
    pass "no scenario text or evidence in the gate output or the stage log${1:+ ($1)}"
  fi
}
done_check='{"name": "unit", "command": "touch \"$SMOKE_WORK/checks-done\"", "heavy": false}'

# Without scenarios the gate is as before: no scenario stage, no scenario line.
jstore_reset
jscenario login true 0.9
jgate '"checks": ['"$done_check"']' ""
expect "without scenarios the gate runs only the checks" "0 unit rc=0" "$rc $(result_lines)"
expect "without scenarios the gate prints no scenario line" 0 "$(printf '%s\n' "$out" | grep -ci scenario)"
expect "without scenarios no judge runs" "" "$(judged)"

# Green: the run starts after the checks, each scenario is judged once against the printed address.
jstore_reset
jscenario login true 0.9
jscenario browse false 1 "spec: [catalog]"
jgate '"checks": ['"$done_check"']'
expect "a train whose scenarios are satisfied is green" "0 TRAIN GREEN" "$rc $(printf '%s\n' "$out" | tail -n 1)"
expect "the scenario stage runs after the checks" "unit rc=0|scenarios rc=0" "$(result_lines)"
expect "each scenario is judged once" "browse#1 login#1" "$(judged)"
expect "the judge gets the address scenarios.run printed and the scenario id" \
  "id=login target=http://127.0.0.1:9550/ checks=done" "$(awk '$1 == "login" { print $3, $4, $5 }' "$work/judge-calls.log")"
results="$("$plugin/scripts/paths.sh" logs)/train-scenario-results.jsonl"
expect "each judge result JSON is recorded in the logs" "browse login" \
  "$(grep -o '"id": *"[a-z]*"' "$results" 2>/dev/null | sed 's/.*: *"//; s/"//' | LC_ALL=C sort | paste -sd' ' -)"
run_pid=$(cat "$work/run.pid" 2>/dev/null)
[ -n "$run_pid" ] && pass "scenarios.run was started" || fail "scenarios.run did not start"
expect "the system scenarios.run started is stopped after judging" "" "$(alive "$run_pid")"
printf '%s\n' "$out" | grep -qE '^scenarios green: 2 judged, mean 0\.95' && pass "the gate prints the scenario verdict" ||
  fail "no scenario verdict line"
no_leak

# Red: a required scenario below pass is rejudged once and named with the judge's missing behaviour only.
jstore_reset
jscenario login true 0.9
jscenario flaky true "0.3 0.85"
jscenario alert true "0.2 0.4" 'fake_missing: closing a position leaves its alert active'
jgate '"checks": ['"$done_check"']'
expect "a required scenario below pass makes the train red" "1 TRAIN RED" "$rc $(printf '%s\n' "$out" | tail -n 1)"
expect "a failing scenario is rejudged once, a passing one is not" "alert#1 alert#2 flaky#1 flaky#2 login#1" "$(judged)"
printf '%s\n' "$out" | grep -qxF "scenario alert unsatisfied (0.4, required): closing a position leaves its alert active" &&
  pass "the red train names the unsatisfied scenario with the missing behaviour" || fail "no unsatisfied line for alert"
printf '%s\n' "$out" | grep -q "scenario flaky unsatisfied" && fail "a scenario that passed its rejudge is named" ||
  pass "a scenario that passes its rejudge is satisfied"
printf '%s\n' "$out" | grep -q "scenario login" && fail "a satisfied scenario is in the summary" ||
  pass "the summary names only the unsatisfied scenarios"
expect "every judge run is recorded" 5 "$(grep -c . "$results" 2>/dev/null)"
no_leak

# Red on the mean: every required scenario passes, the mean is below min_satisfaction.
jstore_reset
jscenario login true 0.8
jscenario extra false "0.5 0.6" 'fake_missing: the export button does nothing'
jgate '"checks": ['"$done_check"']' '"scenarios": {"dir": "'"$jstore"'", "judge": "'"$work"'/fake-judge.sh", "heavy": false, "min_satisfaction": 0.75}'
expect "a mean below min_satisfaction makes the train red" "1 TRAIN RED" "$rc $(printf '%s\n' "$out" | tail -n 1)"
printf '%s\n' "$out" | grep -qE '^scenarios red: .*mean 0\.70 below min_satisfaction 0\.75' &&
  pass "the red verdict gives the mean and the threshold" || fail "no mean in the red verdict"
printf '%s\n' "$out" | grep -qxF "scenario extra unsatisfied (0.6, scored): the export button does nothing" &&
  pass "an unsatisfied scored scenario is named with its best score" || fail "no unsatisfied line for extra"
expect "without scenarios.run the judge gets no address" "id=login target= checks=done" \
  "$(awk '$1 == "login" { print $3, $4, $5 }' "$work/judge-calls.log")"

# Invalid judge output (no JSON, a crash, another id) counts as a failure, also on the rejudge.
jstore_reset
jscenario talk true 1 "fake_output: garbage"
jscenario crash true 1 "fake_output: crash"
jscenario wrong true 1 "fake_output: other-id"
jgate '"checks": ['"$done_check"']'
expect "invalid judge output makes the train red" "1 TRAIN RED" "$rc $(printf '%s\n' "$out" | tail -n 1)"
expect "invalid judge output is rejudged once" "crash#1 crash#2 talk#1 talk#2 wrong#1 wrong#2" "$(judged)"
for id in talk crash wrong; do
  printf '%s\n' "$out" | grep -qE "^scenario $id unsatisfied \(0, required\): invalid judge output" &&
    pass "invalid judge output for $id counts as unsatisfied" || fail "no invalid line for $id"
done

# Sealed: with the whole share sealed, failures are only counted, never named or described.
jstore_reset
jscenario login true 0.9
jscenario alert true "0.2 0.4" 'fake_missing: SEALED-MISSING behaviour'
jgate '"checks": ['"$done_check"']' '"scenarios": {"dir": "'"$jstore"'", "judge": "'"$work"'/fake-judge.sh", "heavy": false, "sealed": 1}'
expect "a sealed failure still makes the train red" "1 TRAIN RED" "$rc $(printf '%s\n' "$out" | tail -n 1)"
printf '%s\n' "$out" | grep -qxF "scenarios sealed: 2 judged, 1 unsatisfied" && pass "sealed scenarios are only counted" ||
  fail "no sealed count"
printf '%s\n' "$out" | cat - "$stage_log" | grep -qE "alert|login|SEALED-MISSING" &&
  fail "a sealed scenario is named or described" || pass "sealed scenarios are never named or described"
no_leak "sealed"
expect "the sealed share is chosen by id: none at 0, all at 1, the same every time" "0 20 yes" \
  "$(scenlib 'n0=0 n1=0; for i in $(seq 20); do dl_scenario_sealed "s$i" 0 && n0=$((n0+1)); dl_scenario_sealed "s$i" 1 && n1=$((n1+1)); done
same=yes; for i in $(seq 20); do [ "$(dl_scenario_sealed "s$i" 0.5 && echo y)" = "$(dl_scenario_sealed "s$i" 0.5 && echo y)" ] || same=no; done
echo "$n0 $n1 $same"')"
share=$(scenlib 'n=0; for i in $(seq 200); do dl_scenario_sealed "scenario-$i" 0.2 && n=$((n+1)); done; echo $n')
[ "$share" -ge 20 ] && [ "$share" -le 60 ] && pass "a sealed share of 0.2 seals about a fifth ($share of 200)" ||
  fail "a sealed share of 0.2 sealed $share of 200"
sealed_id=$(scenlib 'for i in $(seq 50); do dl_scenario_sealed "mixed-$i" 0.5 && { echo "mixed-$i"; break; }; done')
open_id=$(scenlib 'for i in $(seq 50); do dl_scenario_sealed "mixed-$i" 0.5 || { echo "mixed-$i"; break; }; done')
jstore_reset
jscenario "$sealed_id" true 0.1 'fake_missing: SEALED-MISSING behaviour'
jscenario "$open_id" true 0.1 'fake_missing: the open one fails'
jgate '"checks": ['"$done_check"']' '"scenarios": {"dir": "'"$jstore"'", "judge": "'"$work"'/fake-judge.sh", "heavy": false, "sealed": 0.5}'
printf '%s\n' "$out" | grep -qxF "scenario $open_id unsatisfied (0.1, required): the open one fails" &&
  printf '%s\n' "$out" | grep -qxF "scenarios sealed: 1 judged, 1 unsatisfied" &&
  pass "a mixed store names the open failure and counts the sealed one" || fail "mixed sealed output"
printf '%s\n' "$out" | cat - "$stage_log" | grep -qE "$sealed_id|SEALED-MISSING" &&
  fail "the sealed scenario of a mixed store is named" || pass "the sealed scenario of a mixed store is not named"

# affected: only the scenarios whose spec or tags occur in a changed path run, plus every required one.
jstore_reset
jscenario login true 0.9 "spec: [auth]"
jscenario invoice false 0.9 "spec: [billing]"
jscenario tagged false 0.9 "tags: [Invoice]"
jscenario alerts false 0.9 "spec: [alerts]
tags: [ui]"
jscenario bare false 0.9
jgate '"affected": {"command": "true", "heavy": false}, "checks": ['"$done_check"']'
expect "with affected, only matching and required scenarios are judged" "invoice#1 login#1 tagged#1" "$(judged)"
expect "with affected the train is green" "0 TRAIN GREEN" "$rc $(printf '%s\n' "$out" | tail -n 1)"
expect "a scenario matches when a spec or tag item occurs in a changed path, in any case" "invoice tagged" \
  "$(printf 'billing/invoice.txt\nsrc.txt\n' >"$work/changed-list"; for f in invoice login tagged alerts bare; do
    scenlib 'dl_scenario_affected "$1" "'"$work"'/changed-list" && basename "$1" .md' "$jstore/$f.md"; done | paste -sd' ' -)"

# Sequential: a failing check skips the scenario stage; nothing is started.
jstore_reset
jscenario login true 0.9
jgate '"checks": [{"name": "bad", "command": "exit 3", "heavy": false}]'
expect "after a failed check the scenario stage is skipped" "1 bad rc=3|scenarios skipped" "$rc $(result_lines)"
expect "after a failed check no judge runs and no system starts" "|no" \
  "$(judged)|$([ -e "$work/run.pid" ] && echo yes || echo no)"

# parallel: the scenarios are judged alongside the checks.
jgate '"parallel": true, "checks": [{"name": "unit", "command": "sleep 3; touch \"$SMOKE_WORK/checks-done\"", "heavy": false}]'
expect "with parallel the scenario stage runs alongside the checks" "0 unit rc=0|scenarios rc=0 checks=running" \
  "$rc $(result_lines) $(awk '{ print $5 }' "$work/judge-calls.log")"

# parallel + fail_fast: a failing check stops the scenario stage and the system it started.
jstore_reset
jscenario slow true 0.9
jgate '"parallel": true, "fail_fast": true, "checks": [{"name": "bad", "command": "sleep 2; exit 3", "heavy": false}]' \
  '"scenarios": {"dir": "'"$jstore"'", "judge": "sleep 300", "heavy": false,
    "run": "echo $$ >\"$SMOKE_WORK/run.pid\"; echo http://127.0.0.1:9551/; exec sleep 300"}'
expect "fail_fast stops the scenario stage" "1 bad rc=3|scenarios stopped" "$rc $(result_lines)"
run_pid=$(cat "$work/run.pid" 2>/dev/null)
[ -n "$run_pid" ] && expect "fail_fast stops the system scenarios.run started" "" "$(alive "$run_pid")" ||
  fail "scenarios.run did not start before fail_fast"

# A run command that ends without printing how to reach the system makes the train red; nothing is judged.
jstore_reset
jscenario login true 0.9
jgate '"checks": ['"$done_check"']' '"scenarios": {"dir": "'"$jstore"'", "judge": "'"$work"'/fake-judge.sh", "heavy": false, "run": "exit 0"}'
expect "a run command that prints no address is red" "1 TRAIN RED" "$rc $(printf '%s\n' "$out" | tail -n 1)"
printf '%s\n' "$out" | grep -qE '^scenarios red: scenarios.run ended before printing how to reach the system' &&
  pass "the gate says the run command printed no address" || fail "no run failure line"
expect "nothing is judged when the system did not start" "" "$(judged)"

# An empty store judges nothing and starts nothing; an invalid store is red without naming its files.
jstore_reset
jgate '"checks": ['"$done_check"']'
expect "an empty store is green and starts nothing" "0 TRAIN GREEN no" \
  "$rc $(printf '%s\n' "$out" | tail -n 1) $([ -e "$work/run.pid" ] && echo yes || echo no)"
printf -- '---\nid: broken\n---\nSECRET-BODY\n' >"$jstore/broken.md"
jgate '"checks": ['"$done_check"']'
expect "an invalid store makes the train red" "1 TRAIN RED" "$rc $(printf '%s\n' "$out" | tail -n 1)"
printf '%s\n' "$out" | grep -qE '^scenarios red: 1 invalid scenario file' && pass "the gate counts the invalid files" ||
  fail "no invalid store line"

# The default judge is headless Claude Code with the scenario-judge agent and models.scenario-judge.
printf '{"checks": ["true"], "scenarios": {}, "models": {"scenario-judge": "sonnet"}}\n' >"$work/judge-model.json"
judge_cmd=$(scen_config="$work/judge-model.json" scenlib 'dl_scenarios_judge_command')
case $judge_cmd in
  "claude -p --agent dev-loop:scenario-judge --model sonnet "*) pass "the default judge uses the agent and models.scenario-judge" ;;
  *) fail "default judge command: $judge_cmd" ;;
esac
case $(scen_config="$work/scen-default.json" scenlib 'dl_scenarios_judge_command') in
  *--model*) fail "the default judge passes --model without models.scenario-judge" ;;
  "claude -p --agent dev-loop:scenario-judge "*) pass "the default judge inherits the model without models.scenario-judge" ;;
  *) fail "no default judge command" ;;
esac
expect "scenarios.judge replaces the default judge" "my-judge --fast" \
  "$(printf '{"scenarios": {"judge": "my-judge --fast"}}\n' >"$work/judge-own.json"; scen_config="$work/judge-own.json" scenlib 'dl_scenarios_judge_command')"
out=$(DEV_LOOP_CONFIG="$work/judge-model.json" "$plugin/scripts/doctor.sh" 2>&1)
echo "$out" | grep -qE '^ +models .*scenario-judge=sonnet' && pass "doctor lists models.scenario-judge" || fail "no scenario-judge model in doctor"
printf '{"checks": ["true"], "models": {"scenario-judge": "gpt"}}\n' >"$work/judge-model-off.json"
DEV_LOOP_CONFIG="$work/judge-model-off.json" "$plugin/scripts/doctor.sh" 2>&1 | grep -qF 'MISSING models.scenario-judge: "gpt"' &&
  pass "doctor checks models.scenario-judge when it is set without scenarios" || fail "no MISSING for models.scenario-judge"
printf '{"checks": [{"name": "scenarios", "command": "true"}], "scenarios": {}}\n' >"$work/judge-name.json"
DEV_LOOP_CONFIG="$work/judge-name.json" "$plugin/scripts/doctor.sh" 2>&1 | grep -qF 'MISSING check name "scenarios" is reserved' &&
  pass "doctor reserves the check name scenarios when scenarios are on" || fail "no reserved-name MISSING for scenarios"
judge_agent="$plugin/agents/scenario-judge.md"
awk 'NR == 1, /^tools:/' "$judge_agent" 2>/dev/null | grep -qE '^name: scenario-judge$' &&
  grep -E '^tools:' "$judge_agent" | grep -vqE 'Write|Edit' && pass "the scenario-judge agent exists and cannot write" ||
  fail "no read-only scenario-judge agent"
grep -qF '"missing"' "$judge_agent" && grep -qF '"satisfied"' "$judge_agent" && pass "the judge's brief defines its JSON" ||
  fail "the judge's brief lacks the JSON"
grep -qF "scenario-judge" "$plugin/skills/gate/SKILL.md" && grep -qF "scenarios.judge" "$plugin/README.md" &&
  pass "the gate skill and the README document the scenario stage" || fail "the scenario stage is not documented"
git checkout -q -f main

echo "smoke: $passed passed, $failed failed (work dir $work)"
[ "$failed" -eq 0 ]
