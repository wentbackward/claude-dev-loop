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
expect "DEV_LOOP_CONFIG exported by the fallback does not reach the caller" unset "${DEV_LOOP_CONFIG-unset}"
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
echo "$out"
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
git branch -q train-person-work origin/main
"$plugin/scripts/gate-train.sh" feat/48-locked feat/49-env feat/51-build feat/52-output >/dev/null 2>&1
out=$("$plugin/scripts/merge-train.sh" feat/48-locked feat/49-env feat/51-build feat/52-output 2>&1)
echo "$out" | grep -q "kept local feat/48-locked: its worktree $work/wt48 is locked" &&
  pass "merge-train keeps a branch whose worktree is locked" || fail "locked worktree: $out"
echo "$out" | grep -q "kept local feat/49-env: its worktree $work/wt49 holds ignored files that are not build output (.env)" &&
  [ -f "$work/wt49/.env" ] && pass "merge-train keeps a worktree holding a .env file" || fail ".env worktree: $out"
[ ! -d "$work/wt51" ] && [ -z "$(git branch --list feat/51-build)" ] &&
  pass "merge-train removes a worktree whose ignored files are only build output" || fail "build-only worktree kept: $out"
[ -f "$work/wt52/build/local.env" ] && pass "a file inside an ignored build directory that is not all output keeps its worktree" ||
  fail "wt52 removed: $out"
[ -n "$(git branch --list train-person-work)" ] && pass "the gate never deletes a person's train-* branch" ||
  fail "the gate deleted train-person-work"
git worktree unlock "$work/wt48" && git worktree remove --force "$work/wt48" && git worktree remove --force "$work/wt49"
git branch -q -D train-person-work
git worktree remove --force "$work/wt52"

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

echo "smoke: $passed passed, $failed failed (work dir $work)"
[ "$failed" -eq 0 ]
