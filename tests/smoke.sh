#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # pass/fail never fail; single quotes are expanded by the inner shell
# Smoke test of the plugin's hooks and scripts on a throwaway project with a local bare origin.
# No network, no real GitHub: `gh` is tests/fake-gh. Run: tests/smoke.sh   (TMPDIR picks the work dir)
set -u
plugin=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-smoke.XXXXXX")
export DEV_LOOP_HOME="$work/home" DEV_LOOP_LOCK_DIR="$work/locks" DEV_LOOP_GH_SETTLE_SECONDS=0
export FAKE_GH_DIR="$work/gh" GIT_CONFIG_GLOBAL="$work/gitconfig"
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

# 10. doctor flags the leftovers of a hand-built loop.
mkdir -p .claude/agents && echo "---" >.claude/agents/code-reviewer.md
out=$("$plugin/scripts/doctor.sh" 2>&1)
expect "doctor flags a project agent that shadows the plugin's" yes \
  "$(echo "$out" | grep -q "MISSING .claude/agents/code-reviewer.md shadows" && echo yes || echo no)"
rm -r .claude/agents
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' >.claude/settings.json
expect "doctor notes a project Stop hook" yes \
  "$("$plugin/scripts/doctor.sh" 2>&1 | grep -q "note    project Stop hooks" && echo yes || echo no)"
rm .claude/settings.json

echo "smoke: $passed passed, $failed failed (work dir $work)"
[ "$failed" -eq 0 ]
