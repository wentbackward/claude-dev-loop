#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # pass/fail never fail; single quotes are expanded by the inner shell
# Smoke test of the plugin's hooks and scripts on a throwaway project with a local bare origin.
# No network, no real GitHub: `gh` is tests/fake-gh. Each run makes a new work dir under TMPDIR, removed at
# the end of a green run unless DEV_LOOP_KEEP_WORK=1 (scripts/lib/workdirs.sh); a red run keeps and names it.
#
# Usage: tests/smoke.sh [--section <id or name>]... [--list]
#   (none)            run every section
#   --section <id>    run the shared setup, then only that section and the sections it needs (smoke_needs),
#                     in file order, then the summary; <id> is a section number (11, 11b) or text from one
#                     of the section's comment lines (the first match wins). Repeatable.
#   --list            print each section's id, the sections it needs, and its title
#
# A section starts at a line "# <n>. " or "# <n><letter>. " whose number is not below the previous
# section's (so a numbered list inside a section is not one) and ends where the next starts; the summary
# from the line 'dl_suite_end smoke' on is shared. A section that uses the state or helpers of earlier ones
# names them in smoke_needs.
set -u
plugin=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
smoke_file="$plugin/tests/${BASH_SOURCE[0]##*/}"

# smoke_usage: the Usage block of this header.
smoke_usage() {
  awk '/^# Usage:/ { on = 1 } on && !/^#/ { exit } on && /^#$/ { exit } on { sub(/^# ?/, ""); print }' "$smoke_file"
}

# smoke_needs ID: the sections whose state or helpers section ID uses directly (the runner adds theirs).
smoke_needs() {
  case $1 in
    2) echo 1 ;;
    3 | 4 | 6 | 7 | 10 | 11 | 13 | 15 | 25) echo 2 ;;
    5) echo 4 ;;
    8 | 9) echo 7 ;;
    11c) echo 11b ;;
    12) echo 5 6 8 9 10 11 ;;
    14) echo 13 ;;
    14b) echo 14 ;;
    14c) echo 11b 14b ;;
    16) echo 10 12 14 15 ;;
    26) echo 16 ;;
    27b) echo 27 ;;
  esac
}

# smoke_sections: one line per section, "<id> TAB <first line> TAB <last line> TAB <title>", in file order.
smoke_sections() {
  awk 'BEGIN { OFS = "\t"; last = -1 }
    /^dl_suite_end smoke / { foot = NR; exit }
    match($0, /^# [0-9]+[a-z]?\. /) {
      id = substr($0, 3, RLENGTH - 4)
      if (id + 0 >= last) {
        if (cur != "") print cur, start, NR - 1, title
        last = id + 0; cur = id; start = NR; title = substr($0, RLENGTH + 1)
      }
    }
    END { if (cur != "") print cur, start, foot - 1, title }' "$smoke_file"
}

# smoke_find ID_OR_NAME: the id of the section with that id, else of the one holding the first comment line
# (a line starting "# ") that contains the text; fails when there is none.
smoke_find() {
  local lineno
  smoke_sections | awk -F'\t' -v id="$1" '$1 == id { print id; found = 1; exit } END { exit !found }' && return 0
  [ -n "$1" ] || return 1
  lineno=$(awk -v name="$1" -v from="$(smoke_sections | head -n 1 | cut -f2)" \
    'NR >= from && /^dl_suite_end smoke / { exit } NR >= from && index($0, "# ") == 1 && index($0, name) { print NR; exit }' \
    "$smoke_file")
  [ -n "$lineno" ] || return 1
  smoke_sections | awk -F'\t' -v n="$lineno" '$2 <= n && n <= $3 { print $1; exit }'
}

# smoke_closure ID...: the ids and every section they need, space separated.
smoke_closure() {
  local todo="$*" seen="" id
  while [ -n "$todo" ]; do
    id=${todo%% *}
    todo=${todo#"$id"}
    todo=${todo# }
    case " $seen " in *" $id "*) continue ;; esac
    seen="${seen:+$seen }$id"
    todo="$todo${todo:+ }$(smoke_needs "$id")"
    todo=${todo% }
  done
  echo "$seen"
}

# smoke_code IDS: the code of the sections in IDS in file order, a cd into the shared project before one
# whose predecessor is skipped, then the shared summary.
smoke_code() {
  local id first lastl ran=yes
  while IFS="$(printf '\t')" read -r id first lastl _; do
    case " $1 " in
      *" $id "*)
        [ "$ran" = yes ] || echo 'cd "$work/project" || exit 1'
        sed -n "${first},${lastl}p" "$smoke_file"
        ran=yes
        ;;
      *) ran=no ;;
    esac
  done < <(smoke_sections)
  sed -n '/^dl_suite_end smoke /,$p' "$smoke_file"
}

smoke_select=""
smoke_list=""
while [ $# -gt 0 ]; do
  case $1 in
    -h | --help)
      smoke_usage
      exit 0
      ;;
    --list) smoke_list=yes ;;
    --section)
      if [ $# -lt 2 ]; then
        echo "smoke: --section needs a section id or name" >&2
        smoke_usage >&2
        exit 2
      fi
      smoke_id=$(smoke_find "$2") || {
        echo "smoke: no section matches '$2' (tests/smoke.sh --list)" >&2
        exit 2
      }
      smoke_select="${smoke_select:+$smoke_select }$smoke_id"
      shift
      ;;
    *)
      echo "smoke: unknown argument $1" >&2
      smoke_usage >&2
      exit 2
      ;;
  esac
  shift
done
if [ -n "$smoke_list" ]; then
  while IFS="$(printf '\t')" read -r smoke_id _ _ smoke_title; do
    printf '%s\tneeds: %s\t%s\n' "$smoke_id" "$(smoke_needs "$smoke_id")" "$smoke_title"
  done < <(smoke_sections)
  exit 0
fi
[ -z "$smoke_select" ] || smoke_select=$(smoke_closure "$smoke_select")

# shellcheck source=../scripts/lib/workdirs.sh
. "$plugin/scripts/lib/workdirs.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-smoke.XXXXXX")
# Named at once, so the gate records a run that never reaches its summary (a crash, a signal, a stall).
echo "started smoke (work dir $work)"
export DEV_LOOP_HOME="$work/home" DEV_LOOP_LOCK_DIR="$work/locks" DEV_LOOP_GH_SETTLE_SECONDS=0 DEV_LOOP_STOP_GRACE_SECONDS=2
export FAKE_GH_DIR="$work/gh" GIT_CONFIG_GLOBAL="$work/gitconfig" SMOKE_WORK="$work"
# doctor reads Claude Code's settings: fake ones under $work, never the real ~/.claude or managed settings.
export DEV_LOOP_CLAUDE_DIR="$work/claude" DEV_LOOP_MANAGED_SETTINGS="$work/managed-settings.json"
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

# A section run (--section): only the chosen sections and those they need, then the summary.
if [ -n "$smoke_select" ]; then
  eval "$(smoke_code "$smoke_select")"
  exit
fi

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

# The stop gate blocks only on untracked files of this session (#74): older ones are a note, once.
stop_session() { # stop_session ID [TRANSCRIPT]: the hook's exit code, its stdout in $work/stop.out
  printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "${2:-}" |
    CLAUDE_PROJECT_DIR="$work/project" "$plugin/hooks/stop-gate.sh" >"$work/stop.out" 2>/dev/null
  echo $?
}
transcript="$work/transcript.jsonl"
printf '{"type":"summary"}\n{"type":"user","timestamp":"2021-06-01T12:00:00.000Z"}\n' >"$transcript"
touch -t 202001010000 "older notes.txt"
old_nl=$(printf 'older\nline.txt')
touch -t 202001010000 "$old_nl"
expect "stop gate does not block on untracked files older than the session" 0 "$(stop_session s1 "$transcript")"
grep -q 'systemMessage' "$work/stop.out" && grep -q 'older notes.txt' "$work/stop.out" &&
  pass "stop gate notes the older untracked files" || fail "no note of the older untracked files: $(cat "$work/stop.out")"
expect "stop gate's note is valid JSON with the newline name" "true" \
  "$(jq -r '.systemMessage | contains("older\nline.txt")' "$work/stop.out" 2>/dev/null)"
stop_session s1 "$transcript" >/dev/null
expect "stop gate notes the older untracked files only once per session" "" "$(cat "$work/stop.out")"
echo new >"new file.txt"
expect "stop gate blocks on an untracked file created during the session" 2 "$(stop_session s1 "$transcript")"
rm "new file.txt"
new_nl=$(printf 'new\nline.txt')
echo new >"$new_nl"
expect "stop gate blocks on a new untracked file with a newline in its name" 2 "$(stop_session s1 "$transcript")"
rm "$new_nl"
echo "line three" >>src.txt
expect "stop gate blocks on tracked modifications with older untracked files" 2 "$(stop_session s1 "$transcript")"
git checkout -q src.txt
expect "stop gate passes with only older untracked files" 0 "$(stop_session s1 "$transcript")"
expect "stop gate without a session id blocks on any untracked file" 2 "$(stop_session "")"
# The session starts at the transcript's first timestamp, not at the hook's first run.
touch -t 202201010000 during.txt
expect "stop gate's first run blocks on an untracked file made after the transcript's start" 2 \
  "$(stop_session s3 "$transcript")"
rm during.txt
# Without a transcript the hook's first run in the session marks its start.
expect "stop gate's first run without a transcript does not block on older untracked files" 0 "$(stop_session s2)"
echo new >after.txt
touch -t 209901010000 after.txt
expect "stop gate blocks on an untracked file created after its first run" 2 "$(stop_session s2)"
rm after.txt
# A transcript without a timestamp falls back to the hook's first run.
printf '{"type":"summary"}\n' >"$work/no-stamp.jsonl"
expect "stop gate's first run with a timestamp-less transcript does not block on older files" 0 \
  "$(stop_session s4 "$work/no-stamp.jsonl")"
echo new >after.txt
touch -t 209901010000 after.txt
expect "stop gate with a timestamp-less transcript blocks on a file made after its first run" 2 \
  "$(stop_session s4 "$work/no-stamp.jsonl")"
rm after.txt
# A file whose mtime is exactly the session's start second counts as the session's.
TZ=UTC touch -t 202106011200.00 exact.txt
expect "stop gate blocks on an untracked file at exactly the session's start" 2 "$(stop_session s1 "$transcript")"
rm exact.txt
# Leading-dash names are file names, not find options.
touch -t 202001010000 -- -dash.txt
expect "stop gate does not block on an older untracked leading-dash name" 0 "$(stop_session s1 "$transcript")"
rm -- -dash.txt
echo new >-new-dash.txt
expect "stop gate blocks on a new untracked leading-dash name" 2 "$(stop_session s1 "$transcript")"
rm -- -new-dash.txt
# A transcript whose first timestamp is in the future starts the session now, not then (#76).
printf '{"type":"user","timestamp":"2099-01-01T00:00:00.000Z"}\n' >"$work/future.jsonl"
expect "stop gate's first run with a future transcript start does not block on older files" 0 \
  "$(stop_session s5 "$work/future.jsonl")"
echo new >after.txt
expect "stop gate clamps a future transcript start to now: a new untracked file blocks" 2 \
  "$(stop_session s5 "$work/future.jsonl")"
rm after.txt
echo new >"new file.txt"
echo "line three" >>src.txt
awk '{ sub(/"fast_check"/, "\"stop_gate\": {\"require_clean_tree\": false}, \"fast_check\""); print }' \
  .dev-loop.json >"$work/cfg.json"
expect "stop gate with require_clean_tree false ignores new and tracked changes" 0 \
  "$(DEV_LOOP_CONFIG="$work/cfg.json" stop_session s1 "$transcript")"
git checkout -q src.txt
rm "new file.txt" "older notes.txt" "$old_nl"

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
gate_events="$("$plugin/scripts/paths.sh" events)"
expect "the gate's heavy jobs carry the gate's pid (gate_pid) in their slot events" \
  "$(jq -r 'select(.event == "train-started") | .pid' "$gate_events" | tail -n 1)" \
  "$(jq -r 'select(.who == "heavy" and .event == "slot-acquired") | .gate_pid' "$gate_events" | tail -n 1)"

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
mkdir -p "$work/project/.claude/agents" && echo "---" >"$work/project/.claude/agents/code-reviewer.md"
out=$("$plugin/scripts/doctor.sh" 2>&1)
expect "doctor flags a project agent that shadows the plugin's" yes \
  "$(echo "$out" | grep -q "MISSING .claude/agents/code-reviewer.md shadows" && echo yes || echo no)"
rm -r "$work/project/.claude/agents"
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' >"$work/project/.claude/settings.json"
expect "doctor notes a project Stop hook" yes \
  "$("$plugin/scripts/doctor.sh" 2>&1 | grep -q "note    project Stop hooks" && echo yes || echo no)"
rm "$work/project/.claude/settings.json"
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
    echo "$?") $(DEV_LOOP_CONFIG="$plugin/templates/dev-loop.json" "$plugin/scripts/doctor.sh" 2>&1 |
    grep -v "current-state docs off" | grep -c "docs ")"

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
  "$(audit_doctor "$work/audit-prdonly.json" | grep -v "current-state docs off" | grep -c "docs audit\|docs prd\|doc audit")"
printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "./check.sh"}]}\n' >"$work/audit-nodocs.json"
expect "without docs doctor prints no audit or PRD lines" 0 \
  "$(audit_doctor "$work/audit-nodocs.json" | grep -v "current-state docs off" | grep -c "docs audit\|docs prd\|doc audit")"
expect "the template's docs block keeps the audit off" 0 \
  "$(audit_doctor "$plugin/templates/dev-loop.json" | grep -v "current-state docs off" | grep -c "docs ")"
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
grep -qF "scenario-writer" "$plugin/CHANGELOG.md" &&
  pass "the changelog names the scenario writer" || fail "no changelog entry for the scenario writer"

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
printf '%s\n' "$out" | grep -qE '^scenarios red: 2 judged, 0 required unsatisfied, ' &&
  pass "the red line counts no sealed required failure (#40)" || fail "the red line counts a sealed required failure"
jgate '"checks": ['"$done_check"']' '"scenarios": {"dir": "'"$jstore"'", "judge": "'"$work"'/fake-judge.sh", "heavy": false, "sealed": 1, "min_satisfaction": 0.5}'
expect "a sealed required failure alone, mean above min_satisfaction, still makes the train red (#40)" "1 TRAIN RED" \
  "$rc $(printf '%s\n' "$out" | tail -n 1)"
printf '%s\n' "$out" | grep -qxF "scenarios red: 2 judged, 0 required unsatisfied, mean 0.65" &&
  printf '%s\n' "$out" | grep -qxF "scenarios sealed: 2 judged, 1 unsatisfied" &&
  pass "the sealed failure stays in its own count, out of the required count (#40)" || fail "sealed-only red output"
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
printf '%s\n' "$out" | grep -qE '^scenarios red: 2 judged, 1 required unsatisfied, ' &&
  pass "the red line of a mixed store counts only the non-sealed required failure (#40)" ||
  fail "the red line of a mixed store counts the sealed required failure"
printf '%s\n' "$out" | cat - "$stage_log" | grep -qE "$sealed_id|SEALED-MISSING" &&
  fail "the sealed scenario of a mixed store is named" || pass "the sealed scenario of a mixed store is not named"
grep -qiE "daemon that calls .setsid.*escapes" "$plugin/README.md" && grep -qF "setsid" "$plugin/docs/DECISIONS.md" &&
  pass "the README and DECISIONS record that a setsid daemon escapes the stop (#40)" ||
  fail "the setsid limit of the scenario stop is not documented"
printf '{"scenarios": {"dir": "%s", "sealed": 0.5}}\n' "$jstore" >"$work/judge-sealed.json"
expect "dl_scenario_sealed takes a scenario file or an id, with scenarios.sealed as the default share" "yes yes no" \
  "$(scen_config="$work/judge-sealed.json" scenlib 'for x in "$1" "$(basename "$1" .md)"; do dl_scenario_sealed "$x" && printf "yes " || printf "no "; done; dl_scenario_sealed "$(basename "$1" .md)" 0 && echo yes || echo no' "$jstore/$sealed_id.md")"

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

# A judge that runs longer than scenarios.judge_seconds is stopped and counts as invalid, also on the rejudge.
jstore_reset
jscenario login true 0.9
rm -f "$work/judge.pids"
jgate '"checks": ['"$done_check"']' '"scenarios": {"dir": "'"$jstore"'", "heavy": false, "judge_seconds": 1,
  "judge": "echo $$ >>\"$SMOKE_WORK/judge.pids\"; exec sleep 300"}'
expect "a judge over judge_seconds makes the train red" "1 TRAIN RED" "$rc $(printf '%s\n' "$out" | tail -n 1)"
printf '%s\n' "$out" | grep -qxF "scenario login unsatisfied (0, required): invalid judge output (the judge ran longer than 1 s)" &&
  pass "a judge over judge_seconds counts as invalid" || fail "no timeout line"
expect "a judge over judge_seconds is rejudged once" 2 "$(grep -c . "$work/judge.pids" 2>/dev/null)"
# shellcheck disable=SC2046  # the pid list splits on purpose
expect "a judge over judge_seconds is stopped" "" "$(alive $(cat "$work/judge.pids" 2>/dev/null))"

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
  "claude -p \""*"\" --agent dev-loop:scenario-judge --model sonnet "*) pass "the default judge uses the agent and models.scenario-judge" ;;
  *) fail "default judge command: $judge_cmd" ;;
esac
case $(scen_config="$work/scen-default.json" scenlib 'dl_scenarios_judge_command') in
  *--model*) fail "the default judge passes --model without models.scenario-judge" ;;
  "claude -p \""*"\" --agent dev-loop:scenario-judge --no-session"*) pass "the default judge inherits the model without models.scenario-judge" ;;
  *) fail "no default judge command" ;;
esac
# The default command, run with a fake claude that prints its arguments: the prompt follows -p, and no
# variadic option (--add-dir, --allowedTools) is followed by a separate argument it would swallow.
mkdir -p "$work/fake-claude"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' >"$work/fake-claude/claude" && chmod +x "$work/fake-claude/claude"
judge_args=$(PATH="$work/fake-claude:$PATH" DL_SCENARIO_FILE="$jstore/x.md" DL_SCENARIO_ID=x DL_SCENARIO_TARGET=http://t/ \
  bash -c "$judge_cmd")
expect "the default judge gets its prompt right after -p" "-p|Judge the scenario x in $jstore/x.md against the running system: http://t/. End with the JSON object." \
  "$(printf '%s\n' "$judge_args" | sed -n '1,2p' | paste -sd'|' -)"
printf '%s\n' "$judge_args" | grep -qxE -- '--add-dir|--allowedTools|--allowed-tools|--disallowedTools|--mcp-config|--betas|--file|--plugin-dir' &&
  fail "a variadic option of the default judge takes a separate argument: $judge_args" ||
  pass "the default judge passes variadic options as --option=value"
printf '%s\n' "$judge_args" | grep -qxF -- "--add-dir=$jstore" && printf '%s\n' "$judge_args" | grep -qxF -- "--model" &&
  pass "the default judge adds the scenario's folder and the model" || fail "default judge arguments: $judge_args"
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
section_1b=$(awk '/^## 1b\./ { on = 1; next } /^## / { on = 0 } on' "$plugin/skills/dev-loop/SKILL.md")
printf '%s\n' "$section_1b" | grep -qF "dl_scenario_sealed" && printf '%s\n' "$section_1b" | grep -qiE "sealed scenarios.* only as a count" &&
  printf '%s\n' "$section_1b" | grep -qF "never by id or title" &&
  pass "the dev-loop skill lists sealed scenarios on the issue only as a count, told apart by dl_scenario_sealed" ||
  fail "section 1b does not keep sealed scenarios off the issue"
judge_agent="$plugin/agents/scenario-judge.md"
awk 'NR == 1, /^tools:/' "$judge_agent" 2>/dev/null | grep -qE '^name: scenario-judge$' &&
  grep -E '^tools:' "$judge_agent" | grep -vqE 'Write|Edit' && pass "the scenario-judge agent exists and cannot write" ||
  fail "no read-only scenario-judge agent"
grep -qF '"missing"' "$judge_agent" && grep -qF '"satisfied"' "$judge_agent" && pass "the judge's brief defines its JSON" ||
  fail "the judge's brief lacks the JSON"
grep -qF "scenario-judge" "$plugin/skills/gate/SKILL.md" && grep -qF "scenarios.judge" "$plugin/README.md" &&
  pass "the gate skill and the README document the scenario stage" || fail "the scenario stage is not documented"
git checkout -q -f main

# Factory preset (#34): "factory" is collaborative (default) or dark; dark turns scenarios on by default
# (an explicit "scenarios", false and null included, wins), needs a store with a valid required scenario
# (doctor MISSING, gate TRAIN RED), and keeps one list of stop conditions for both modes.
cd "$work/project" || exit 1
git fetch -q origin
git checkout -q -B feat/34-dark origin/main
echo "line dark" >>src.txt && git commit -q -am "feat: dark (Refs #34)" && git push -q -u origin feat/34-dark
git checkout -q main
fstore="$work/factory-store"
# fconfig NAME JSON_MEMBERS: write $work/factory-NAME.json with these members besides checks.
fconfig() {
  printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "true", "heavy": false}]%s}\n' "${2:+, $2}" \
    >"$work/factory-$1.json"
}
# factory_lib NAME CODE: run CODE with the scenario library and config NAME, with jq and with python3.
factory_lib() {
  local code='. "$0/scripts/lib/common.sh"; . "$0/scripts/lib/scenarios.sh"; dl_load_config; eval "$1"'
  DEV_LOOP_CONFIG="$work/factory-$1.json" bash -c "$code" "$plugin" "$2" 2>&1
  printf '|'
  DEV_LOOP_NO_JQ=1 DEV_LOOP_CONFIG="$work/factory-$1.json" bash -c "$code" "$plugin" "$2" 2>&1
}
fconfig none ""
fconfig collab '"factory": "collaborative"'
fconfig dark '"factory": "dark"'
fconfig night '"factory": "night"'
fconfig dark-off '"factory": "dark", "scenarios": false'
fconfig dark-null '"factory": "dark", "scenarios": null'
fconfig dark-on '"factory": "dark", "scenarios": {"dir": "'"$fstore"'"}'
fconfig plain-off '"scenarios": false'
fconfig plain-null '"scenarios": null'
fconfig plain-on '"scenarios": {}'
for name in none collab dark night; do
  expect "dl_factory reads factory ($name), with jq and with python3" \
    "$(case $name in dark) echo "dark|dark" ;; *) echo "collaborative|collaborative" ;; esac)" \
    "$(factory_lib "$name" 'dl_factory' | tr -d '\n')"
done
for pair in none:"off default" collab:"off default" dark:"on preset" dark-off:"off explicit" dark-null:"off explicit" \
  dark-on:"on explicit" plain-off:"off explicit" plain-null:"off explicit" plain-on:"on explicit"; do
  name=${pair%%:*} want=${pair#*:}
  expect "scenarios with config $name: $want, with jq and with python3" "$want|$want" \
    "$(factory_lib "$name" 'dl_scenarios_setting' | tr -d '\n')"
  on=${want%% *}
  expect "dl_scenarios_on with config $name is $on" "$on|$on" \
    "$(factory_lib "$name" 'dl_scenarios_on && echo on || echo off' | tr -d '\n')"
done
expect "a dark factory's store defaults to ~/.dev-loop/<repo>/scenarios" "$DEV_LOOP_HOME/project/scenarios" \
  "$(DEV_LOOP_CONFIG="$work/factory-dark.json" "$plugin/scripts/paths.sh" scenarios)"

# doctor: the mode, where the scenarios setting came from, a bad mode, and a dark factory without a store.
fdoctor() { out=$(DEV_LOOP_CONFIG="$work/factory-$1.json" "$plugin/scripts/doctor.sh" 2>&1); }
fdoctor none
expect "doctor without factory prints no factory line" 0 "$(printf '%s\n' "$out" | grep -cE '^ +factory |factory:')"
fdoctor night
printf '%s\n' "$out" | grep -qF 'MISSING factory: "night" is not collaborative or dark' &&
  pass "doctor reports a factory that is neither collaborative nor dark" || fail "no MISSING for factory night"
fdoctor collab
printf '%s\n' "$out" | grep -qE '^ +factory +collaborative, scenarios off \(default\)$' &&
  pass "doctor prints the collaborative mode" || fail "no collaborative factory line: $out"
fdoctor dark
printf '%s\n' "$out" | grep -qE '^ +factory +dark, scenarios on \(preset\)$' &&
  pass "doctor marks scenarios set by the dark preset with (preset)" || fail "no (preset) mark: $out"
printf '%s\n' "$out" | grep -qE '^MISSING factory dark: no scenario store with a valid required scenario' &&
  pass "doctor reports a dark factory without a scenario store as MISSING" || fail "no MISSING for a dark factory without a store"
fdoctor dark-off
printf '%s\n' "$out" | grep -qE '^ +factory +dark, scenarios off \(explicit\)$' &&
  ! printf '%s\n' "$out" | grep -q '^MISSING factory' &&
  pass "an explicit scenarios false wins over the dark preset in doctor" || fail "dark with scenarios false: $out"
rm -rf "$fstore" && mkdir -p "$fstore"
printf -- '---\nid: browse\ntitle: Browse\nrequired: false\n---\nbody\n' >"$fstore/browse.md"
printf -- '---\nid: login\nrequired: true\n---\nbody\n' >"$fstore/login.md"
fdoctor dark-on
printf '%s\n' "$out" | grep -qE '^ +factory +dark, scenarios on \(explicit\)$' && pass "doctor marks explicit scenarios with (explicit)" ||
  fail "no (explicit) mark: $out"
printf '%s\n' "$out" | grep -qE '^MISSING factory dark: no scenario store with a valid required scenario' &&
  pass "a store whose only required scenario is invalid is not enough for a dark factory" ||
  fail "no MISSING for a store without a valid required scenario"
printf -- '---\nid: login\ntitle: Log in\nrequired: true\n---\nbody\n' >"$fstore/login.md"
fdoctor dark-on
printf '%s\n' "$out" | grep -q '^MISSING factory' && fail "a dark factory with a valid required scenario is reported: $out" ||
  pass "a dark factory with a valid required scenario passes doctor"
expect "dl_scenarios_ready: yes for a store with a valid required scenario, no for a missing store" "yes|yes no|no" \
  "$(factory_lib dark-on 'dl_scenarios_ready "$(dl_scenarios_dir)" && echo yes || echo no' | tr -d '\n') $(
    factory_lib dark 'dl_scenarios_ready "$(dl_scenarios_dir)" && echo yes || echo no' | tr -d '\n')"

# The gate: a dark factory without a usable store is red with the reason; with one, the stage judges it.
fgate() { # fgate NAME: gate feat/34-dark with config NAME; sets out and rc
  rm -f "$work/factory-judge.log"
  out=$(DEV_LOOP_CONFIG="$work/factory-$1.json" "$plugin/scripts/gate-train.sh" feat/34-dark 2>&1)
  rc=$?
}
fgate dark
expect "a dark factory without a scenario store ends TRAIN RED" "1 TRAIN RED" "$rc $(printf '%s\n' "$out" | tail -n 1)"
printf '%s\n' "$out" | grep -qE '^scenarios red: factory dark needs a scenario store with at least one valid required scenario' &&
  pass "the red train gives the reason" || fail "no dark store reason in: $out"
fgate dark-off
expect "a dark factory with scenarios false has no scenario stage" "0 TRAIN GREEN 0" \
  "$rc $(printf '%s\n' "$out" | tail -n 1) $(printf '%s\n' "$out" | grep -ci scenario)"
fgate none
expect "without factory the gate has no scenario stage" "0 TRAIN GREEN 0" \
  "$rc $(printf '%s\n' "$out" | tail -n 1) $(printf '%s\n' "$out" | grep -ci scenario)"
cat >"$work/factory-judge.sh" <<'EOF'
#!/usr/bin/env bash
echo "$DL_SCENARIO_ID" >>"$SMOKE_WORK/factory-judge.log"
printf '{"id": "%s", "satisfied": 1, "required": true, "evidence": "ok", "missing": ""}\n' "$DL_SCENARIO_ID"
EOF
chmod +x "$work/factory-judge.sh"
fconfig dark-judge '"factory": "dark", "scenarios": {"dir": "'"$fstore"'", "judge": "'"$work"'/factory-judge.sh", "heavy": false}'
fgate dark-judge
expect "a dark factory with a valid required scenario judges it and is green" "0 TRAIN GREEN browse login" \
  "$rc $(printf '%s\n' "$out" | tail -n 1) $(LC_ALL=C sort "$work/factory-judge.log" 2>/dev/null | paste -sd' ' -)"

# The role guard decides "scenarios on" by the same rule: for each config, it refuses the implementer a
# read of the store exactly when dl_scenarios_on is true.
git init -q "$work/darkproj"
# dguard JSON: the guard's exit status for an implementer's Read of the default store of darkproj, whose
# .dev-loop.json is JSON (read from the project, so the hook's quick no-op check is covered too).
dguard() {
  printf '%s\n' "$1" >"$work/darkproj/.dev-loop.json"
  printf '{"tool_name": "Read", "cwd": "%s", "agent_type": "dev-loop:implementer", "tool_input": {"file_path": "%s"}}' \
    "$work/darkproj" "$DEV_LOOP_HOME/darkproj/scenarios/a.md" |
    CLAUDE_PROJECT_DIR="$work/darkproj" "$plugin/hooks/guard-role.sh" 2>/dev/null
  echo $?
}
expect "guard: a dark factory without a scenarios key hides the default store from the implementer" 2 \
  "$(dguard '{"factory": "dark"}')"
expect "guard: a dark factory with scenarios false lets the implementer read it" 0 \
  "$(dguard '{"factory": "dark", "scenarios": false}')"
expect "guard: scenarios null and a collaborative factory leave the guard off" "0 0" \
  "$(dguard '{"factory": "dark", "scenarios": null}') $(dguard '{"factory": "collaborative"}')"
fconfig dark-off-text '"factory": "dark", "scenarios": "false"'
fconfig plain-off-text '"scenarios": "false"'
same=0
for name in none collab dark night dark-off dark-null dark-on plain-off plain-null plain-on dark-off-text plain-off-text; do
  lib=$(factory_lib "$name" 'dl_scenarios_on && echo 2 || echo 0' | cut -d'|' -f1 | tr -d '\n')
  at=$(DEV_LOOP_CONFIG="$work/factory-$name.json" python3 -I "$plugin/hooks/guard-role.py" --scenarios-dir "$work/project")
  hook=$(printf '{"tool_name": "Read", "cwd": "%s", "agent_type": "dev-loop:implementer", "tool_input": {"file_path": "%s/a.md"}}' \
    "$work/project" "$at" | DEV_LOOP_CONFIG="$work/factory-$name.json" CLAUDE_PROJECT_DIR="$work/project" \
    "$plugin/hooks/guard-role.sh" 2>/dev/null; echo $?)
  [ "$lib" = "$hook" ] && same=$((same + 1)) || echo "  config $name: dl_scenarios_on says $lib, the guard $hook"
done
expect "guard: the hook and dl_scenarios_on agree on every factory and scenarios config" 12 "$same"

# One list of stop conditions for both modes; the skills and the README describe the preset.
skill="$plugin/skills/dev-loop/SKILL.md"
expect "the dev-loop skill has exactly one stop-conditions list" 1 "$(grep -c 'Stop and ask the user only for' "$skill")"
expect "no other skill keeps its own stop-conditions list" "" \
  "$(grep -l 'Stop and ask the user only for' "$plugin"/skills/*/SKILL.md | grep -v '/dev-loop/')"
factory_section=$(awk '/^## .*Factory mode/ { on = 1; next } on && /^## / { exit } on' "$skill")
[ -n "$factory_section" ] && printf '%s\n' "$factory_section" | grep -qF "section 8" &&
  ! printf '%s\n' "$factory_section" | grep -qiE 'only for:|stop and ask' &&
  pass "the Factory mode section points to the one list and has no stop conditions of its own" ||
  fail "the Factory mode section is missing or lists its own stop conditions"
grep -A6 '^## 8\.' "$skill" | grep -qiE 'every mode|both modes' && pass "the stop conditions say they hold in every mode" ||
  fail "the stop conditions do not say they hold in every mode"
grep -qF '"factory"' "$plugin/skills/setup/SKILL.md" && grep -qi 'go dark' "$plugin/skills/setup/SKILL.md" &&
  pass "the setup skill asks for the mode and has a go-dark step" || fail "the setup skill lacks the mode or go dark"
grep -qF 'MISSING factory' "$plugin/skills/doctor/SKILL.md" && pass "the doctor skill explains the factory problems" ||
  fail "the doctor skill lacks the factory rows"
grep -qE '^## Factory preset' "$plugin/README.md" && grep -qF '| `scenarios` |' "$plugin/README.md" &&
  pass "the README has the factory preset section and table" || fail "the README lacks the factory preset"
git checkout -q -f main

# Planned-list hygiene (#45): with docs.planned, doctor reads each planned row's ticket through one batched
# gh call and notes rows whose ticket closed, rows open past docs.planned_max_days with no loop branch, and
# rows without a ticket number. Notes only; nothing changes without docs or docs.planned.
pwork="$work/planned"
git init -q --bare "$pwork/origin.git"
git clone -q "$pwork/origin.git" "$pwork/project" 2>/dev/null
cd "$pwork/project" || exit 1
mkdir -p docs
printf '# Features\n\n## Search\n\n- **Tickets:** added in #101\n\n## Planned (not built yet)\n\n| Item | Ticket |\n|------|--------|\n| Theta | #107 |\n\n## Notes\n\n- not a planned row (#101)\n' \
  >docs/features.md
cat >docs/planned.md <<'EOF'
# Planned

- Alpha (#101)
- Beta (#102)
- Gamma (#103)
- Delta (#104)
- Epsilon (#105)
- Zeta (#106)
- Eta (#199), see [the PRD](prd.md#2-scope)
- No ticket here

```
- #150 inside a code block is not a row
```
EOF
echo one >src.txt
git add . && git commit -q -m "chore: start" && git push -q -u origin main
git branch -q feat/104-delta
git push -q origin main:refs/heads/fix/105-epsilon
git fetch -q origin
git branch -q chore/103x-not-a-loop-branch-of-103
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '101\tCLOSED\tCOMPLETED\t2020-01-01T00:00:00Z\n102\tCLOSED\tNOT_PLANNED\t2020-01-01T00:00:00Z\n' >"$pwork/issues.tsv"
printf '103\tOPEN\t\t2020-01-01T00:00:00Z\n104\tOPEN\t\t2020-01-01T00:00:00Z\n' >>"$pwork/issues.tsv"
printf '105\tOPEN\t\t2020-01-01T00:00:00Z\n106\tOPEN\t\t%s\n107\tOPEN\t\t%s\n' "$now_iso" "$now_iso" >>"$pwork/issues.tsv"
# pconfig NAME DOCS_MEMBERS: write $pwork/NAME.json with a docs block of these members.
pconfig() {
  printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "true", "heavy": false}]%s}\n' \
    "${2:+, \"docs\": {$2}}" >"$pwork/$1.json"
}
# pdoctor NAME: doctor's output with config NAME and a fake GitHub holding $pwork/issues.tsv.
pdoctor() {
  rm -rf "$pwork/gh" && mkdir -p "$pwork/gh" && cp "$pwork/issues.tsv" "$pwork/gh/issues.tsv"
  FAKE_GH_DIR="$pwork/gh" DEV_LOOP_HOME="$pwork/home" DEV_LOOP_CONFIG="$pwork/$1.json" "$plugin/scripts/doctor.sh" 2>&1
}
# The notes dir is in additionalDirectories (#70), so the only MISSING lines left would be about the rows.
mkdir -p "$pwork/project/.claude"
printf '{"permissions": {"additionalDirectories": ["%s"]}}\n' "$pwork/home/project/notes" \
  >"$pwork/project/.claude/settings.local.json"
pconfig aged '"aspects": {"features": "docs/features.md"}, "planned": "docs/planned.md", "planned_max_days": 30'
out=$(pdoctor aged)
echo "$out"
expect "planned: a row whose ticket closed as completed is noted" \
  "note    planned row #101: ticket closed, move it to Features" "$(echo "$out" | grep -F 'planned row #101')"
expect "planned: a row whose ticket closed as not planned is noted" \
  "note    planned row #102: ticket closed as not planned, remove the row" "$(echo "$out" | grep -F 'planned row #102')"
echo "$out" | grep -E '^note    planned row #103: open [0-9]+ days with no branch \(over planned_max_days 30\): close it as not planned and remove the row; the PRD keeps the intent$' >/dev/null &&
  pass "planned: a row open past planned_max_days with no loop branch is noted" || fail "no note for the old row #103"
expect "planned: a local loop branch <type>/<n>-* keeps an old row quiet" "" "$(echo "$out" | grep -F 'planned row #104')"
expect "planned: a remote-only loop branch keeps an old row quiet" "" "$(echo "$out" | grep -F 'planned row #105')"
expect "planned: a young open row is not noted" "" "$(echo "$out" | grep -F 'planned row #106')"
expect "planned: a row whose ticket does not exist is noted" \
  "note    planned row #199: no such ticket, link the row's ticket" "$(echo "$out" | grep -F 'planned row #199')"
echo "$out" | grep -E '^note    planned row .*docs/planned.md:10.* has no ticket number' | grep -qF 'No ticket here' &&
  pass "planned: a row with no ticket number is noted" || fail "no note for the row without a ticket"
expect "planned: a link anchor like #2-scope is not a ticket" "" "$(echo "$out" | grep -E 'planned row #2[^0-9]')"
expect "planned: lines in a code block are not rows" "" "$(echo "$out" | grep -F '#150')"
expect "planned: rows are notes, never MISSING" "" "$(echo "$out" | grep -E '^MISSING .*planned')"
expect "planned: doctor makes one gh call for all rows" 1 "$(grep -c 'gh issue list' "$pwork/gh/calls.log")"
grep -F 'gh issue list' "$pwork/gh/calls.log" | grep -qF 'createdAt' && pass "planned: the call asks for createdAt" ||
  fail "the gh call does not ask for createdAt"

pconfig noage '"aspects": {"features": "docs/features.md"}, "planned": "docs/planned.md"'
out=$(pdoctor noage)
expect "planned: without planned_max_days there is no age check" "" "$(echo "$out" | grep -F 'days with no branch')"
expect "planned: without planned_max_days closed rows are still noted" 2 "$(echo "$out" | grep -cE 'planned row #10[12]:')"
pconfig badage '"aspects": {"features": "docs/features.md"}, "planned": "docs/planned.md", "planned_max_days": "soon"'
expect "planned: an invalid planned_max_days is MISSING" \
  'MISSING docs.planned_max_days: "soon" is not a positive number' "$(pdoctor badage | grep -F 'planned_max_days')"
pconfig zeroage '"aspects": {"features": "docs/features.md"}, "planned": "docs/planned.md", "planned_max_days": 0'
out=$(pdoctor zeroage)
expect "planned: a planned_max_days of 0 keeps the age check off" "0 0" \
  "$(echo "$out" | grep -c '^MISSING docs.planned_max_days') $(echo "$out" | grep -c 'days with no branch')"

pconfig section '"aspects": {"features": "docs/features.md"}, "planned": "docs/features.md", "planned_max_days": 30'
out=$(pdoctor section)
expect "planned: in a file with a Planned heading only that section's rows count" "" \
  "$(echo "$out" | grep -E 'planned row (#101|.*no ticket)')"
expect "planned: a table header is not a row; a young table row is quiet" "" "$(echo "$out" | grep -E 'planned row')"
printf '107\tCLOSED\tCOMPLETED\t2020-01-01T00:00:00Z\n' >"$pwork/issues-107.tsv"
cp "$pwork/issues.tsv" "$pwork/issues-all.tsv" && grep -v '^107' "$pwork/issues-all.tsv" >"$pwork/issues.tsv"
cat "$pwork/issues-107.tsv" >>"$pwork/issues.tsv"
expect "planned: a table row's ticket is read" "note    planned row #107: ticket closed, move it to Features" \
  "$(pdoctor section | grep -F 'planned row #107')"
cp "$pwork/issues-all.tsv" "$pwork/issues.tsv"

printf '# Notes\n\n- Lambda (#199)\n\n## Unplanned things\n\n- Iota (#101)\n\n## Planned-list hygiene\n\n- Kappa (#102)\n\n* * *\n- - -\n***\n___\n' \
  >docs/other.md
pconfig other '"aspects": {"features": "docs/features.md"}, "planned": "docs/other.md"'
out=$(pdoctor other)
expect "planned: headings like Unplanned things or Planned-list hygiene do not open a planned section" 3 \
  "$(echo "$out" | grep -cE 'planned row #(10[12]|199):')"
expect "planned: a thematic break (* * *, - - -, ***) is not a row" "" "$(echo "$out" | grep -F 'no ticket number')"
mkdir -p "$pwork/nogh" && printf '#!/usr/bin/env bash\nexit 1\n' >"$pwork/nogh/gh" && chmod +x "$pwork/nogh/gh"
out=$(PATH="$pwork/nogh:$PATH" pdoctor aged)
expect "planned: without gh access one note says the rows were not checked" 1 \
  "$(echo "$out" | grep -c '^note    planned rows not checked')"
expect "planned: without gh access no row is judged by its ticket" "" "$(echo "$out" | grep -E 'planned row #')"

pconfig nodocs ''
pconfig noplanned '"aspects": {"features": "docs/features.md"}'
for name in nodocs noplanned; do
  out=$(pdoctor "$name")
  expect "planned: doctor with config $name prints no planned lines" "" "$(echo "$out" | grep -E 'planned row')"
  expect "planned: doctor with config $name makes no issue call" 0 "$(cat "$pwork/gh/calls.log" 2>/dev/null | grep -c 'gh issue list')"
done
expect "planned: the notes leave doctor's verdict unchanged" "$(pdoctor noplanned | tail -n 1)" "$(pdoctor aged | tail -n 1)"

days() { bash -c '. "$1/scripts/lib/common.sh"; . "$1/scripts/lib/docs.sh"; dl_docs_days_between "$2" "$3"' _ "$plugin" "$@"; }
expect "planned: days between dates across a leap day" 2 "$(days 2020-02-28T10:00:00Z 2020-03-01)"
expect "planned: days between dates across a year" 1 "$(days 2019-12-31T23:59:59Z 2020-01-01T00:00:00Z)"
expect "planned: days between dates across centuries" 9806 "$(days 2000-01-01 2026-11-06)"
expect "planned: days between an unreadable date and today are empty" "" "$(days soon 2026-11-06)"

grep -qF '`docs.planned_max_days`' "$plugin/README.md" && grep -qF 'planned row #<n>' "$plugin/skills/doctor/SKILL.md" &&
  grep -qF '"planned_max_days"' "$plugin/templates/dev-loop.json" &&
  pass "planned: the README, the doctor skill and the template describe planned_max_days" ||
  fail "planned: the docs lack planned_max_days"
cd "$work/project" || exit 1
git checkout -q -f main


# 17. docs-archive.sh (#44): journal compaction and spec archiving (dry run by default, only with "docs").
git init -q "$work/archive-project"
cd "$work/archive-project" || exit 1
mkdir -p docs/specs
printf '# Features\n' >docs/features.md
printf '# PRD\n' >docs/specs/prd.md
printf '# Old spec\n\nDone. See [web](https://example.invalid/x) and [top](#old-spec).\n' >docs/specs/old.md
printf '# Gone spec\n' >docs/specs/gone.md
printf '# Linked spec\n\nSee [the PRD](prd.md).\n' >docs/specs/linked.md
printf '# Index\n\n- [old](specs/old.md#old-spec)\n- [prd](specs/prd.md)\n' >docs/index.md
git add . && git commit -q -m "docs: start"
aconfig() { # aconfig NAME DOCS_JSON: an archive test config with that docs block (none for an empty one)
  if [ -n "$2" ]; then printf '{"base_branch": "main", "docs": %s}\n' "$2"; else echo '{"base_branch": "main"}'; fi \
    >"$work/archive-$1.json"
}
aconfig on '{"aspects": {"features": "docs/features.md"}, "prd": ["docs/specs/prd.md"], "max_lines": 15}'
aconfig log '{"aspects": {"features": "docs/features.md"}, "journals": ["docs/LOG.md"], "max_lines": 15}'
aconfig off ''
archive() { # archive CONFIG ARGS...: run docs-archive.sh with that config; sets out and rc
  out=$(DEV_LOOP_CONFIG="$work/archive-$1.json" "$plugin/scripts/docs-archive.sh" "${@:2}" 2>&1)
  rc=$?
  echo "$out"
}
# journal_fixture [crlf|no-eol] [FILE]: a 27-line journal: preamble 1-4, standing decisions 5-8, entries at
# 9-13, 14-20 (a fence holding "## "), 21-24 and 25-27; no archive folder.
journal_fixture() {
  local file=${2:-docs/DECISIONS.md}
  rm -rf docs/archive
  cat >"$work/journal.txt" <<'EOF'
# Decisions log

One entry per decision. Newest last.

## Standing decisions

- keep it simple ([entry](#2026-01-03--third))

## 2026-01-01 — First

- **Decision:** a.
See [web](https://example.invalid/x) and [top](#first).

## 2026-01-02 — Second with a fence

```sh
## not a heading
echo hi
```

## 2026-01-03 — Third

- c

## 2026-01-04 — Fourth

- d
EOF
  case ${1:-} in
    crlf) awk '{printf "%s\r\n", $0}' "$work/journal.txt" >"$file" ;;
    no-eol) printf '%s' "$(cat "$work/journal.txt")" >"$file" ;;
    *) cp "$work/journal.txt" "$file" ;;
  esac
  cp "$file" "$work/journal-original"
}
# round_trip LIVE ARCHIVE: the live file's first 8 lines, the archive, then the rest equal the original.
round_trip() {
  { head -n 8 "$1"; cat "$2"; tail -n +9 "$1"; } | cmp -s - "$work/journal-original"
}
arch1=docs/archive/DECISIONS-2026-01-01--2026-01-02.md

archive off journal --apply
expect "docs-archive without docs is a config error" 2 "$rc"
journal_fixture
archive off journal --apply
cmp -s docs/DECISIONS.md "$work/journal-original" && [ ! -e docs/archive ] &&
  pass "without docs docs-archive writes nothing" || fail "docs-archive wrote without docs"
archive on
expect "docs-archive without a command is a usage error" 2 "$rc"
archive on journal --keep many
expect "docs-archive with a bad --keep is a usage error" 2 "$rc"

archive on journal
expect "the journal dry run exits 0" 0 "$rc"
cmp -s docs/DECISIONS.md "$work/journal-original" && [ ! -e docs/archive ] &&
  pass "the journal dry run is the default and writes nothing" || fail "the dry run wrote"
echo "$out" | grep -F "would move 2 entries" | grep -qF "$arch1" &&
  pass "the dry run names the entry count and the archive file" || fail "dry run output: $out"
printf '%s\n' "$out" | grep -qF -- "## 2026-01-02 — Second with a fence" &&
  ! printf '%s\n' "$out" | grep -qF -- "## not a heading" &&
  pass "the dry run lists each entry, and a fenced ## is not an entry" || fail "dry run entries: $out"

archive on journal --apply
expect "the journal apply exits 0" 0 "$rc"
expect "the live file is within max_lines" 15 "$(awk 'END {print NR}' docs/DECISIONS.md)"
[ -f "$arch1" ] && round_trip docs/DECISIONS.md "$arch1" &&
  pass "byte-exact round trip: preamble and standing decisions, archive, rest equal the original" ||
  fail "round trip failed"
expect "the oldest whole entries moved, the fenced entry whole" "2026-01-01 2026-01-02 1" \
  "$(grep -o '^## 2026-01-0[0-9]' "$arch1" | cut -c4- | paste -sd' ' -) $(grep -c '^## not a heading' "$arch1")"
expect "the preamble and standing decisions stay in place" "# Decisions log|## Standing decisions|## 2026-01-03 — Third" \
  "$(sed -n '1p;5p;9p' docs/DECISIONS.md | paste -sd'|' -)"
cp "$arch1" "$work/arch1-copy"

# A second run appends a new archive file and never edits the first.
printf '\n## 2026-01-05 — Fifth\n\n- e\n\n## 2026-01-06 — Sixth\n\n- f\n' >>docs/DECISIONS.md
cp docs/DECISIONS.md "$work/journal-second"
archive on journal --apply
arch2=docs/archive/DECISIONS-2026-01-03--2026-01-04.md
expect "a second run writes a new archive file" "0 yes" "$rc $([ -f "$arch2" ] && echo yes)"
cmp -s "$arch1" "$work/arch1-copy" && pass "a second run leaves the first archive untouched" ||
  fail "the first archive changed"
{ head -n 8 docs/DECISIONS.md; cat "$arch2"; tail -n +9 docs/DECISIONS.md; } | cmp -s - "$work/journal-second" &&
  pass "the second run round-trips too" || fail "second round trip failed"

# An archive name that exists is never overwritten: the next free name is used.
journal_fixture
mkdir -p docs/archive && echo existing >"$arch1"
archive on journal --apply
expect "an existing archive name gets a -2 suffix" "0 existing" \
  "$rc $(cat "$arch1")"
round_trip docs/DECISIONS.md docs/archive/DECISIONS-2026-01-01--2026-01-02-2.md &&
  pass "the suffixed archive round-trips" || fail "suffixed archive round trip failed"

journal_fixture crlf
archive on journal --apply
expect "a CRLF journal is compacted" 0 "$rc"
round_trip docs/DECISIONS.md "$arch1" && pass "byte-exact round trip with CRLF line ends" || fail "CRLF round trip"
journal_fixture no-eol
archive on journal --apply
round_trip docs/DECISIONS.md "$arch1" && [ "$(tail -c 1 docs/DECISIONS.md)" = d ] &&
  pass "byte-exact round trip without a trailing newline" || fail "no-eol round trip"

journal_fixture
archive on journal --apply --keep 100
expect "a journal under budget is a no-op" "0 yes" \
  "$rc $(cmp -s docs/DECISIONS.md "$work/journal-original" && [ ! -e docs/archive ] && echo yes)"
echo "$out" | grep -qi "within" && pass "the no-op says the journal is within budget" || fail "no-op output: $out"
archive on journal docs/DECISIONS.md --keep 22 --apply
expect "--keep sets the budget (one entry moves)" "0 2026-01-01" \
  "$rc $(grep -o '^## 2026-01-0[0-9]' docs/archive/DECISIONS-2026-01-01--2026-01-01.md | cut -c4- | paste -sd' ' -)"

# The dangerous direction: a failed verification leaves every file untouched; links that would break refuse.
journal_fixture
DEV_LOOP_ARCHIVE_TEST_CORRUPT=1 archive on journal --apply
expect "a failed verification exits non-zero" 1 "$rc"
cmp -s docs/DECISIONS.md "$work/journal-original" && [ ! -e docs/archive ] &&
  pass "a failed verification leaves every file untouched" || fail "files changed after a failed verification"
echo "$out" | grep -qi "verif" && pass "the failure says the verification failed" || fail "verification output: $out"
journal_fixture
awk '$0 == "- **Decision:** a." {$0 = "- **Decision:** a, see [features](features.md)."} 1' "$work/journal-original" >docs/DECISIONS.md
cp docs/DECISIONS.md "$work/journal-original"
archive on journal --apply
expect "a relative link that would break in the archive refuses" 1 "$rc"
echo "$out" | grep -qF "(features.md)" && pass "the refusal names the link" || fail "link refusal: $out"
cmp -s docs/DECISIONS.md "$work/journal-original" && [ ! -e docs/archive ] &&
  pass "a link refusal writes nothing" || fail "a link refusal wrote"
git checkout -q -- docs && git clean -qfd docs

# docs.journals names the journals; docs/DECISIONS.md is the default only without it.
journal_fixture "" docs/LOG.md
journal_fixture
archive log journal --apply
expect "docs.journals picks the journal to compact" "0 yes no" \
  "$rc $([ -f docs/archive/LOG-2026-01-01--2026-01-02.md ] && echo yes) $([ -e "$arch1" ] && echo yes || echo no)"
cmp -s docs/DECISIONS.md "$work/journal-original" && pass "a journal not in docs.journals is untouched" ||
  fail "docs/DECISIONS.md changed"
rm -rf docs/archive docs/LOG.md

# Code fences follow CommonMark: a ~~~ block holding ``` closes only on ~~~, a fence indented 4 spaces is
# not one; the link rule shares the fence rule.
rm -rf docs/archive
printf '# Log\n\n## 2026-02-01 — Tilde\n\n~~~\n```\n## fake\n~~~\n\n## 2026-02-02 — Indented\n\n    ```\n\n## 2026-02-03 — Real\n\n- r\n\n## 2026-02-04 — Last\n' \
  >docs/DECISIONS.md
cp docs/DECISIONS.md "$work/journal-original"
archive on journal --keep 1
expect "the entries are the headings outside CommonMark fences" "2026-02-01 2026-02-02 2026-02-03" \
  "$(printf '%s\n' "$out" | grep -o '^docs-archive:   ## [^ ]*' | awk '{print $3}' | paste -sd' ' -)"
printf '%s\n' "$out" | grep -qF "## fake" && fail "a ## inside a ~~~ block holding \`\`\` was taken for an entry" ||
  pass "a \`\`\` line does not close a ~~~ fence"
expect "the link rule uses the same fences" "real.md" \
  "$(printf '~~~\n```\n[a](fake.md)\n~~~\n    ```\n[b](real.md)\n' |
    bash -c '. "$1/scripts/lib/common.sh" && . "$1/scripts/lib/docs.sh" && dl_docs_links' _ "$plugin" | paste -sd' ' -)"

# The newest entry always stays; a newest-first journal is refused.
archive on journal --keep 1 --apply
expect "the newest entry stays in the live file" "0 2026-02-04" \
  "$rc $(grep -o '^## 2026-02-0[0-9]' docs/DECISIONS.md | cut -c4- | paste -sd' ' -)"
{ head -n 2 docs/DECISIONS.md; cat docs/archive/DECISIONS-2026-02-01--2026-02-03.md; tail -n +3 docs/DECISIONS.md; } |
  cmp -s - "$work/journal-original" && pass "the CommonMark-fence journal round-trips" || fail "fence round trip"
rm -rf docs/archive
printf '## 2026-04-01 — a\n## 2026-04-02 — b\n## Standing decisions\n- s\n' >docs/DECISIONS.md
archive on journal --keep 1 --apply
expect "the newest entry stays when the standing decisions come last" "0 2026-04-02" \
  "$rc $(grep -o '^## 2026-04-0[0-9]' docs/DECISIONS.md | cut -c4- | paste -sd' ' -)"
rm -rf docs/archive
printf '# Log\n\n## 2026-03-02 — Newer\n\n- b\n\n## 2026-03-01 — Older\n\n- a\n' >docs/DECISIONS.md
cp docs/DECISIONS.md "$work/journal-original"
archive on journal --keep 1 --apply
expect "a newest-first journal is refused" "1 yes" \
  "$rc $(cmp -s docs/DECISIONS.md "$work/journal-original" && [ ! -e docs/archive ] && echo yes)"
echo "$out" | grep -qi "newest last" && pass "the refusal says the journal must be newest last" || fail "newest-first: $out"

# doctor notes a journal over max_lines.
journal_fixture
out=$(DEV_LOOP_CONFIG="$work/archive-on.json" "$plugin/scripts/doctor.sh" 2>&1)
echo "$out" | grep -qF "journal docs/DECISIONS.md has 27 lines, over max_lines 15 (compact it: docs-archive.sh journal)" &&
  pass "doctor notes a journal over max_lines" || fail "doctor journal note: $out"
expect "doctor without docs notes no journal" 0 \
  "$(DEV_LOOP_CONFIG="$work/archive-off.json" "$plugin/scripts/doctor.sh" 2>&1 | grep -c "journal docs/")"
rm -f docs/DECISIONS.md
grep -q '^## Standing decisions' "$plugin/templates/DECISIONS.md" && pass "the DECISIONS template has a standing decisions section" ||
  fail "no standing decisions in the template"

# spec: refuse a file the config names; report links to it; move it verbatim and leave a pointer.
archive on spec docs/specs/prd.md --apply
expect "spec refuses a file docs.prd names" "1 yes" \
  "$rc $(git diff --quiet && [ ! -e docs/archive ] && echo yes)"
echo "$out" | grep -qF "docs.prd" && pass "the refusal names docs.prd" || fail "prd refusal: $out"
archive on spec docs/features.md --apply
expect "spec refuses a current-state aspect" "1 yes" "$rc $(git diff --quiet && [ ! -e docs/archive ] && echo yes)"
archive on spec docs/specs/linked.md --apply
expect "spec refuses a spec whose relative link would break" "1 yes" \
  "$rc $(git diff --quiet && [ ! -e docs/archive ] && echo yes)"
echo "$out" | grep -qF "(prd.md)" && pass "the spec link refusal names the link" || fail "spec link refusal: $out"
archive on spec docs/specs/old.md
expect "the spec dry run writes nothing" "0 yes" "$rc $(git diff --quiet && [ ! -e docs/archive ] && echo yes)"
echo "$out" | grep -F "docs/index.md" | grep -qF "specs/old.md" && pass "links in other docs to the spec are reported" ||
  fail "no link report: $out"
echo "$out" | grep -qF "docs/archive/specs/old.md" && pass "the spec dry run names the destination" || fail "spec dry run: $out"
DEV_LOOP_ARCHIVE_TEST_CORRUPT=1 archive on spec docs/specs/old.md --apply
expect "a failed spec verification writes nothing" "1 yes" \
  "$rc $(git diff --quiet && [ ! -e docs/archive/specs/old.md ] && echo yes)"
mkdir -p docs/archive
DEV_LOOP_ARCHIVE_TEST_CORRUPT=1 archive on spec docs/specs/old.md --apply
expect "a failed spec move removes only the folders it created" "1 yes no" \
  "$rc $([ -d docs/archive ] && echo yes) $([ -e docs/archive/specs ] && echo yes || echo no)"
rmdir docs/archive
aconfig dot '{"aspects": {"features": "./docs/features.md"}, "prd": ["./docs/specs/prd.md"]}'
archive dot spec docs/specs/prd.md
expect "spec matches a config path written with ./" 1 "$rc"
archive dot spec docs/features.md
expect "spec matches an aspect written with ./" 1 "$rc"
archive on spec docs/specs/old.md --apply
expect "spec moves the file verbatim" "0 yes" \
  "$rc $(git show HEAD:docs/specs/old.md | cmp -s - docs/archive/specs/old.md && echo yes)"
expect "spec leaves a one-line pointer that links the archive" "1 yes" \
  "$(awk 'END {print NR}' docs/specs/old.md) $(grep -qF '](../archive/specs/old.md)' docs/specs/old.md && echo yes)"
git show HEAD:docs/specs/old.md >docs/specs/old.md
archive on spec docs/specs/old.md --apply
expect "spec never overwrites an archived spec" "1 yes" \
  "$rc $(git show HEAD:docs/specs/old.md | cmp -s - docs/archive/specs/old.md && echo yes)"
archive on spec docs/specs/gone.md --no-pointer --apply
expect "spec --no-pointer leaves no file behind" "0 no yes" \
  "$rc $([ -e docs/specs/gone.md ] && echo yes || echo no) $([ -f docs/archive/specs/gone.md ] && echo yes)"
archive on spec docs/specs/prd.md --force --apply
expect "spec --force archives a file the config names" "0 yes" "$rc $([ -f docs/archive/specs/prd.md ] && echo yes)"
cd "$work/project" || exit 1
# 18. Docs maintenance (#47): the dev-loop skill's maintenance ticket on the audit's cadence, and the
# doc-auditor's housekeeping list in its report (the auditor stays read-only).
maint_skill="$plugin/skills/dev-loop/SKILL.md"
maint=$(awk '/^#+ / { on = ($0 ~ /^#+ .*Docs maintenance/) } on' "$maint_skill")
printf '%s\n' "$maint" | grep -qF 'docs.audit_every' && printf '%s\n' "$maint" | grep -qiE 'after (the|each) (doc )?audit' &&
  pass "the dev-loop skill has a Docs maintenance section on the doc audit's cadence" ||
  fail "no Docs maintenance section on the audit's cadence"
printf '%s\n' "$maint" | grep -qF 'docs: maintenance' && printf '%s\n' "$maint" | grep -qiE 'one .*ticket' &&
  pass "docs maintenance is one docs: maintenance ticket" || fail "no single docs: maintenance ticket"
maint_items=0
for want in 'doctor' 'planned' 'docs-archive.sh journal' 'Standing decisions' 'docs-archive.sh spec' 'split'; do
  printf '%s\n' "$maint" | grep -qF "$want" && maint_items=$((maint_items + 1))
done
expect "the maintenance ticket lists doctor's notes, planned rows, journals, specs and splits" 6 "$maint_items"
printf '%s\n' "$maint" | grep -qiE 'at most one .*per ticket' && pass "docs maintenance splits at most one doc per ticket" ||
  fail "no one-split-per-ticket rule"
printf '%s\n' "$maint" | grep -qiE 'not planned' && printf '%s\n' "$maint" | grep -qiE "user's OK" &&
  printf '%s\n' "$maint" | grep -qiE 'collaborative' && printf '%s\n' "$maint" | grep -qiE 'dark.*(automatic|without asking)' &&
  pass "closing a stale ticket needs the user's OK in collaborative mode and is automatic in dark mode" ||
  fail "no collaborative/dark rule for closing stale tickets"
printf '%s\n' "$maint" | grep -qiE 'nothing to do' && printf '%s\n' "$maint" | grep -qiE 'reviewed' &&
  printf '%s\n' "$maint" | grep -qiE 'gated' && pass "docs maintenance is skipped when empty and reviewed and gated like any ticket" ||
  fail "docs maintenance does not say skipped, reviewed and gated"
awk '/^## 8a\./ { on = 1; next } /^## / { on = 0 } on' "$maint_skill" | grep -qiE 'not planned' &&
  pass "factory mode dark closes stale tickets as not planned without asking" || fail "section 8a lacks the stale-ticket rule"
auditor="$plugin/agents/doc-auditor.md"
grep -E '^tools:' "$auditor" | grep -vqE 'Write|Edit' && grep -qiE 'never edits files' "$auditor" &&
  grep -qiE 'you do not change files' "$auditor" && pass "the doc-auditor brief still forbids edits" ||
  fail "the doc-auditor brief no longer forbids edits"
auditor_report=$(awk '/^## Report/ { on = 1; next } /^## / { on = 0 } on' "$auditor")
printf '%s\n' "$auditor_report" | grep -qiE 'maintenance list' && pass "the doc-auditor report has a maintenance list" ||
  fail "no maintenance list in the doc-auditor report"
grep -qiE 'one ticket per drift' "$auditor" && grep -qiE 'housekeeping' "$auditor" &&
  pass "the doc-auditor keeps one ticket per real drift and lists housekeeping instead" || fail "auditor: drift vs housekeeping"
grep -qF 'Docs maintenance' "$plugin/README.md" && grep -qF 'docs: maintenance' "$plugin/README.md" &&
  pass "the README describes docs maintenance" || fail "the README lacks docs maintenance"

# 19. Docs adoption (#46): doctor notes when the current-state docs are off (a note, never MISSING), setup
# step 3b describes a gradual adoption path, and the planned-row parser follows CommonMark fences.
awork="$work/adopt"
git init -q --bare "$awork/origin.git"
git clone -q "$awork/origin.git" "$awork/project" 2>/dev/null
cd "$awork/project" || exit 1
mkdir -p docs
printf '# Features\n' >docs/features.md
printf '# Project\n' >CLAUDE.md
git add . && git commit -q -m "chore: start" && git push -q -u origin main
# adoctor NAME DOCS_MEMBERS: doctor's output with a config holding a docs block of these members (none if empty).
adoctor() {
  printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "true", "heavy": false}]%s}\n' \
    "${2:+, \"docs\": {$2}}" >"$awork/$1.json"
  DEV_LOOP_HOME="$awork/home" DEV_LOOP_CONFIG="$awork/$1.json" "$plugin/scripts/doctor.sh" 2>&1
}
docs_off_note="note    current-state docs off: no docs check, no doc audit, no planned list; adopt them with the setup skill's step 3b"
off_out=$(adoctor off "")
on_out=$(adoctor on '"aspects": {"features": "docs/features.md"}')
expect "adopt: doctor without docs prints the docs-off note" "$docs_off_note" \
  "$(echo "$off_out" | grep -F 'current-state docs off')"
expect "adopt: doctor with empty aspects prints the docs-off note" "$docs_off_note" \
  "$(adoctor empty '"aspects": {}' | grep -F 'current-state docs off')"
expect "adopt: doctor with docs prints no docs-off note" "" "$(echo "$on_out" | grep -F 'current-state docs off')"
expect "adopt: the docs-off note is never MISSING" "" "$(echo "$off_out" | grep -E '^MISSING .*docs off')"
expect "adopt: the docs-off note adds no problem to the doctor's verdict" "$(echo "$on_out" | tail -n 1)" \
  "$(echo "$off_out" | tail -n 1)"

# The planned-row parser uses the shared CommonMark fence helper: a ``` line inside a ~~~ block does not
# end the fence, and an indented ``` (4 spaces) does not open one.
printf '# Planned\n\n~~~\n```\n- Fenced (#150)\n~~~\n- Real (#7)\n\n    ```\n- After an indented line (#8)\n' \
  >docs/planned.md
planned_rows() { # planned_rows FILE: the ticket numbers of the planned rows dl_docs_planned_rows finds
  DL_ROOT="$awork/project" bash -c '. "$1/scripts/lib/common.sh" && . "$1/scripts/lib/docs.sh" &&
    dl_docs_planned_rows "$2"' _ "$plugin" "$1" | cut -f3 | paste -sd' ' -
}
expect "adopt: a \`\`\` line inside a ~~~ fence does not end it early" "7 8" "$(planned_rows docs/planned.md)"
printf '# Planned\n\n````\n```\n- Fenced (#151)\n````\n- Real (#9)\n' >docs/planned.md
expect "adopt: a fence closes only on a run at least as long" "9" "$(planned_rows docs/planned.md)"

# Setup step 3b's gradual adoption path, and the README, doctor skill and CHANGELOG that describe it.
step3b=$(awk '/^## 3b\./ {on = 1; print; next} /^## / {on = 0} on' "$plugin/skills/setup/SKILL.md")
for phrase in "Gradual adoption" "only the Features aspect" "empty \`map\`" "docs.prd" "planned list" \
  "docs-archive.sh spec" "docs-archive.sh journal" "--apply" "Standing decisions" "rules one aspect at a time" \
  "docs maintenance tickets" "one split per ticket"; do
  printf '%s\n' "$step3b" | grep -qF -- "$phrase" && pass "adopt: setup step 3b names \"$phrase\"" ||
    fail "setup step 3b does not name \"$phrase\""
done
gradual=$(printf '%s\n' "$step3b" | awk '/Gradual adoption/ {on = 1} on')
printf '%s\n' "$gradual" | grep -n 'templates/FEATURES.md\|empty `map`' | head -n 1 | grep -qF 'templates/FEATURES.md' &&
  pass "adopt: the gradual path creates the Features file before the empty map turns the docs on" ||
  fail "the gradual path does not create the Features file first"
printf '%s\n' "$gradual" | grep -qF "Docs maintenance" && pass "adopt: the gradual path points at the Docs maintenance step" ||
  fail "the gradual path does not point at Docs maintenance"
grep -qF "current-state docs off" "$plugin/README.md" && grep -qiF "gradual adoption" "$plugin/README.md" &&
  pass "adopt: the README describes the docs-off note and the gradual adoption path" ||
  fail "the README lacks the docs-off note or the gradual adoption path"
grep -qF "note current-state docs off" "$plugin/skills/doctor/SKILL.md" &&
  pass "adopt: the doctor skill has a row for the docs-off note" || fail "no doctor skill row for the docs-off note"
grep -qF "#46" "$plugin/CHANGELOG.md" &&
  pass "adopt: CHANGELOG has an entry for #46" || fail "no CHANGELOG #46 entry"
# 20. Permissions (#54): permissions.sh merges the loop's allow, ask and deny rules into the project's
# .claude/settings.json (and the plugin-script rules, which hold this machine's plugin path, into
# .claude/settings.local.json), only adding; doctor reads only the project's two files and reports a deny
# that blocks a loop command (MISSING) and a missing or stale allow list (notes).
mwork="$work/perm"
git init -q --bare "$mwork/origin.git"
git clone -q "$mwork/origin.git" "$mwork/project" 2>/dev/null
cd "$mwork/project" || exit 1
printf '# Project\n' >CLAUDE.md
mkdir -p "$mwork/cache/mk/dev-loop" "$mwork/home/.claude"
ln -s "$plugin" "$mwork/cache/mk/dev-loop/9.9.9"
mroot="$mwork/cache/mk/dev-loop/9.9.9"
mscripts="$mwork/cache/mk/dev-loop/*/scripts"
# A user-level settings file that would block the loop: doctor must never read it.
printf '{"permissions": {"deny": ["Bash(gh pr:*)"]}}\n' >"$mwork/home/.claude/settings.json"
git add . && git commit -q -m "chore: start" && git push -q -u origin main
# mconfig FAST_CHECK [BASE]: write the project config with this fast check, two checks (one compound) and the
# base branch BASE (default main).
mconfig() {
  printf '{"base_branch": "'"${2:-main}"'", "fast_check": "%s", "checks": [{"name": "unit", "command": "make check"}, "./e2e.sh --all | tee e2e.log"]}\n' \
    "$1" >"$mwork/config.json"
}
mconfig "test -x run.sh && make lint"
# mperm ARGS: permissions.sh from the plugin's cache-layout path, in the project.
mperm() {
  (cd "$mwork/project" && HOME="$mwork/home" DEV_LOOP_HOME="$mwork/state" DEV_LOOP_CONFIG="$mwork/config.json" \
    "$mroot/scripts/permissions.sh" "$@" 2>&1)
}
# mdoctor: doctor's output from the plugin's cache-layout path, in the project.
mdoctor() {
  (cd "$mwork/project" && HOME="$mwork/home" DEV_LOOP_HOME="$mwork/state" DEV_LOOP_CONFIG="$mwork/config.json" \
    "$mroot/scripts/doctor.sh" 2>&1)
}
# mrules FILE LIST: the rules of permissions.LIST in FILE, one per line.
mrules() {
  bash -c '. "$1/scripts/lib/common.sh" && . "$1/scripts/lib/permissions.sh" && dl_perm_rules "$2" "$3"' _ \
    "$plugin" "$1" "$2"
}
# mdecide COMMAND: deny, ask, allow or none for COMMAND under the project's two settings files.
mdecide() {
  bash -c '. "$1/scripts/lib/common.sh" && . "$1/scripts/lib/permissions.sh" && dl_perm_decision "$2" "$3" "$4"' _ \
    "$plugin" "$1" "$mwork/project/.claude/settings.json" "$mwork/project/.claude/settings.local.json"
}

# Doctor without .claude/settings.json: one note, and otherwise the same output as with complete rules.
no_settings=$(mdoctor)
expect "perm: without .claude/settings.json doctor prints exactly one permissions line" 1 \
  "$(printf '%s\n' "$no_settings" | grep -c 'permissions: ')"
printf '%s\n' "$no_settings" | grep -q '^note    permissions: no .claude/settings.json' &&
  pass "perm: the missing settings file is a note" || fail "perm: no note for a missing .claude/settings.json"

# The merge keeps every existing rule and key, adds the loop's rules, and only adds.
mkdir -p "$mwork/project/.claude"
cat >"$mwork/project/.claude/settings.json" <<'EOF'
{
  "model": "custom",
  "permissions": {
    "allow": ["Bash(npm test)", "WebFetch"],
    "ask": ["Bash(git push origin main)"],
    "deny": ["Bash(curl *)", "Bash(sudo:*)"],
    "defaultMode": "default"
  },
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "true"}]}]}
}
EOF
printf '{"permissions": {"allow": ["Bash(ls *)"]}}\n' >"$mwork/project/.claude/settings.local.json"
cp "$mwork/project/.claude/settings.json" "$mwork/before.json"
cp "$mwork/project/.claude/settings.local.json" "$mwork/before-local.json"
dry=$(mperm)
cmp -s "$mwork/project/.claude/settings.json" "$mwork/before.json" &&
  cmp -s "$mwork/project/.claude/settings.local.json" "$mwork/before-local.json" &&
  pass "perm: permissions.sh without --apply changes nothing" || fail "perm: the dry run changed a settings file"
printf '%s\n' "$dry" | grep -qF '.claude/settings.json: + allow Bash(make lint)' &&
  printf '%s\n' "$dry" | grep -qF ".claude/settings.local.json: + allow Bash($mscripts/gate-train.sh *)" &&
  printf '%s\n' "$dry" | tail -n 1 | grep -q 'dry run' && pass "perm: the dry run lists the rules it would add" ||
  fail "perm: the dry run does not list the rules ($dry)"
for nojq in "" 1; do
  label=${nojq:+ (python3)}
  cp "$mwork/before.json" "$mwork/project/.claude/settings.json"
  cp "$mwork/before-local.json" "$mwork/project/.claude/settings.local.json"
  DEV_LOOP_NO_JQ=$nojq mperm --apply >/dev/null
  expect "perm: the merge keeps every existing allow rule first, in order$label" "Bash(npm test) WebFetch" \
    "$(mrules "$mwork/project/.claude/settings.json" allow | head -n 2 | paste -sd' ' -)"
  expect "perm: the merge keeps the existing ask and deny rules$label" "Bash(git push origin main)|Bash(curl *) Bash(sudo:*)" \
    "$(mrules "$mwork/project/.claude/settings.json" ask | head -n 1)|$(mrules "$mwork/project/.claude/settings.json" deny |
      head -n 2 | paste -sd' ' -)"
  expect "perm: the merge keeps the other keys$label" "custom default true" \
    "$(json_get_py() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["model"], d["permissions"]["defaultMode"], d["hooks"]["Stop"][0]["hooks"][0]["command"])' "$1"; }
      json_get_py "$mwork/project/.claude/settings.json")"
  expect "perm: no rule is duplicated (sudo deny stays once)$label" 1 \
    "$(mrules "$mwork/project/.claude/settings.json" deny | grep -cxF 'Bash(sudo:*)')"
  missing_rules=""
  for list in allow ask deny; do
    while IFS= read -r rule; do
      mrules "$mwork/project/.claude/settings.json" "$list" | grep -qxF -- "$rule" || missing_rules="$missing_rules $list:$rule"
    done < <(mrules "$plugin/templates/settings.json" "$list")
  done
  expect "perm: every template rule is in the merged settings$label" "" "$missing_rules"
  for rule in "Bash(test -x run.sh)" "Bash(make lint)" "Bash(make check)" "Bash(./e2e.sh --all)" "Bash(tee e2e.log)" \
    "Bash(git push -u origin HEAD)"; do
    mrules "$mwork/project/.claude/settings.json" allow | grep -qxF -- "$rule" &&
      pass "perm: the project allow list has $rule$label" ||
      fail "perm: the project allow list lacks $rule$label"
  done
  expect "perm: the local file keeps its own rule first and gets the plugin scripts$label" \
    "Bash(ls *) Bash($mscripts/gate-train.sh)" \
    "$(mrules "$mwork/project/.claude/settings.local.json" allow | head -n 2 | paste -sd' ' -)"
  mrules "$mwork/project/.claude/settings.json" allow | grep -qF "$mwork" &&
    fail "perm: the shared settings file holds a machine path$label" ||
    pass "perm: the shared settings file holds no machine path$label"
  expect "perm: a second run adds nothing$label" "permissions: complete" "$(DEV_LOOP_NO_JQ=$nojq mperm --apply | tail -n 1)"
done
git -C "$mwork/project" check-ignore -q .claude/settings.local.json && pass "perm: the local settings file is ignored by git" ||
  fail "perm: .claude/settings.local.json is not ignored"
printf '{"permissions": [' >"$mwork/broken.json"
cp "$mwork/broken.json" "$mwork/project/.claude/settings.json"
mperm --apply >/dev/null
expect "perm: an invalid settings file is refused and left untouched" "0" \
  "$(cmp -s "$mwork/project/.claude/settings.json" "$mwork/broken.json"; echo $?)"
cp "$mwork/before.json" "$mwork/project/.claude/settings.json"
mperm --apply >/dev/null

# The decision for each command under the merged rules: the loop's commands are allowed, the dangerous ones
# are denied or ask (in every mode, bypass included), and the rest is at least not allowed (it prompts in the
# default mode).
# mstrict LABEL COMMAND...: each COMMAND is denied or asks.
mstrict() {
  local label=$1 cmd decision
  shift
  for cmd in "$@"; do
    decision=$(mdecide "$cmd")
    case $decision in deny | ask) pass "perm: \"$cmd\" is $decision$label" ;; *) fail "perm: \"$cmd\" is $decision$label" ;; esac
  done
}
for cmd in "git fetch origin" "git status" "git push -u origin HEAD" "git rebase origin/main" \
  "git worktree add ../p-54 -b feat/54-x origin/main" "gh issue view 54" "gh issue create --title x --body y" \
  "gh pr create --title x --body-file n.md" "gh pr comment 3 --body ok" "gh pr list" "make lint" "make check" \
  "$mroot/scripts/gate-train.sh feat/1-a feat/2-b" "$mroot/scripts/doctor.sh" "$mroot/scripts/cleanup.sh" \
  "$mroot/scripts/repush.sh feat/1-a" "$mroot/scripts/permissions.sh" "$mroot/scripts/heavy.sh make check" \
  "$mroot/scripts/status.sh --json --no-gh" "$mroot/scripts/event.sh agent-started ticket=55" \
  "$mroot/scripts/as-role.sh implementer git push -u origin HEAD"; do
  expect "perm: the loop command \"$cmd\" is allowed" allow "$(mdecide "$cmd")"
done
mstrict "" "git push --force origin feat/1-a" "git push -f origin feat/1-a" "git push -u origin HEAD --force" \
  "git push -u origin HEAD --force-with-lease" "git push -u origin HEAD -f" "git push -u origin +HEAD" \
  "git push origin HEAD:+feat/1-a" "git -c a=b push --force" "git -C . push -f" "git --git-dir=x push +main" \
  "git push -u origin HEAD --tags" "git push origin --follow-tags" "git push -u origin HEAD refs/tags/v1" \
  "git push -u origin feat/x:refs/heads/main" "git push -u origin feat/x:main -q" "git push origin HEAD:refs/heads/main" \
  "git push -u origin main" "git push origin main --quiet" "git push -u origin feat/a :feat/b" \
  "git push origin --delete feat/b" "git push origin -d feat/b" "git push --mirror origin" "git push --all origin" \
  "git tag v1.0" "git tag -a v1 -m x" "gh release create v1.0" "gh repo delete o/r --yes" "gh pr merge --admin 3" \
  "gh pr merge 3 --squash --admin" "$mroot/scripts/as-role.sh implementer git push --force" \
  "$mroot/scripts/as-role.sh implementer git push origin HEAD:main" "$mroot/scripts/heavy.sh gh release create v1" \
  "$mroot/scripts/heavy.sh git push origin HEAD:refs/heads/main" "$mroot/scripts/cleanup.sh --apply --include closed" \
  "git worktree remove --force ../p-54" "git worktree remove -f ../p-54" "git worktree remove -f -f ../p-54" \
  "git -C . worktree remove --force ../p-54" "git rebase --exec 'make test' origin/main" "git rebase -x 'rm -rf x' main" \
  "git -C . rebase --exec=true main" "git fetch --upload-pack='touch x' origin" "git pull --upload-pack=x origin" \
  "git -c core.sshCommand=x fetch origin" "git -c protocol.ext.allow=always pull origin"
for cmd in "git push origin v1.0" "git push -u origin feat/1-a" "git push -u origin feat/1-a main" \
  "$mroot/scripts/heavy.sh rm -rf build" "$mroot/scripts/as-role.sh orchestrator gh api -X DELETE x"; do
  decision=$(mdecide "$cmd")
  case $decision in deny | ask | none) pass "perm: \"$cmd\" is not allowed ($decision)" ;; *) fail "perm: \"$cmd\" is $decision" ;; esac
done
# A base branch not named main: the base rules follow base_branch.
mconfig "test -x run.sh && make lint" master
mperm --apply >/dev/null
mstrict " (base master)" "git push -u origin feat/x HEAD:master" "git push origin master" "git push -u origin HEAD:master -q" \
  "git push origin HEAD:refs/heads/master"
expect "perm: the loop push stays allowed with base master" allow "$(mdecide "git push -u origin HEAD")"
mconfig "test -x run.sh && make lint"
# Over the template alone: no allow rule matches a force push, a repository delete, a release, a tag or an
# admin merge at all.
template_allow=$(mrules "$plugin/templates/settings.json" allow)
for cmd in "git push --force" "git push -f origin main" "gh repo delete o/r" "gh release create v1" "git tag v1" \
  "git push origin --tags" "gh pr merge --admin 3" "gh pr merge 3"; do
  hit=$(printf '%s\n' "$template_allow" | while IFS= read -r rule; do
    bash -c '. "$1/scripts/lib/common.sh" && . "$1/scripts/lib/permissions.sh" && dl_perm_match "$2" "$3"' _ \
      "$plugin" "$rule" "$cmd" && echo "$rule"
  done)
  expect "perm: no template allow rule matches \"$cmd\"" "" "$hit"
done
# The rule matcher follows the documented syntax: :* and a trailing " *" match the bare command, a word
# boundary holds, * matches spaces, and other glob characters are literal.
mmatch() { bash -c '. "$1/scripts/lib/common.sh" && . "$1/scripts/lib/permissions.sh" && dl_perm_match "$2" "$3" && echo y || echo n' _ "$plugin" "$1" "$2"; }
expect "perm: matcher semantics" "y y y n y n y n y y n" "$(mmatch 'Bash(ls *)' ls) $(mmatch 'Bash(ls:*)' 'ls -la') \
$(mmatch 'Bash(ls *)' 'ls -la') $(mmatch 'Bash(ls *)' lsof) $(mmatch 'Bash(ls*)' lsof) $(mmatch 'Bash(git * main)' 'git push') \
$(mmatch 'Bash(git * main)' 'git push origin main') $(mmatch 'Bash(a?)' ab) $(mmatch Bash anything) \
$(mmatch 'Bash(make lint)' 'make lint') $(mmatch 'Read(./.env)' 'cat .env')"

# Doctor: complete rules print nothing new; the same output as without settings, less the one note.
complete_out=$(mdoctor)
expect "perm: doctor prints nothing about complete permissions" "" "$(printf '%s\n' "$complete_out" | grep 'permissions')"
expect "perm: doctor output without settings is the complete output plus one note and the uncovered notes dir" \
  "$(printf '%s\n' "$complete_out" | grep -v 'project Stop hooks\|^doctor: ')" \
  "$(printf '%s\n' "$no_settings" | grep -v '^note    permissions: \|^MISSING notes: \|^doctor: ')"
# A stale allow list: the fast check changed.
mconfig "make fmt-check lint"
printf '%s\n' "$(mdoctor)" | grep -qF 'note    permissions: the allow list lacks the project commands: Bash(make fmt-check lint)' &&
  pass "perm: doctor notes a fast_check missing from the allow list" || fail "perm: no note for a stale allow list"
mconfig "test -x run.sh && make lint"
# Missing loop rules: a plugin script rule removed.
cp "$mwork/project/.claude/settings.local.json" "$mwork/local-full.json"
printf '{"permissions": {"allow": ["Bash(ls *)"]}}\n' >"$mwork/project/.claude/settings.local.json"
printf '%s\n' "$(mdoctor)" | grep -qE '^note    permissions: the allow list lacks [0-9]+ of the loop.s rules' &&
  pass "perm: doctor notes missing loop rules" || fail "perm: no note for missing loop rules"
# No allow list at all.
printf '{"permissions": {"deny": ["Bash(sudo:*)"], "additionalDirectories": ["%s"]}}\n' "$mwork/state/project/notes" \
  >"$mwork/project/.claude/settings.json"
rm "$mwork/project/.claude/settings.local.json"
out=$(mdoctor)
printf '%s\n' "$out" | grep -qF 'note    permissions: no allow list' && pass "perm: doctor notes a missing allow list" ||
  fail "perm: no note for a missing allow list"
expect "perm: a missing allow list adds no problem to the doctor's verdict" "$(printf '%s\n' "$complete_out" | tail -n 1)" \
  "$(printf '%s\n' "$out" | tail -n 1)"
# A deny rule that blocks a loop command is MISSING, in either project file; the user's file is never read.
cp "$mwork/before.json" "$mwork/project/.claude/settings.json"
cp "$mwork/local-full.json" "$mwork/project/.claude/settings.local.json"
mperm --apply >/dev/null
printf '{"permissions": {"allow": [], "deny": ["Bash(gh pr:*)"]}}\n' >"$mwork/project/.claude/settings.local.json"
out=$(mdoctor)
printf '%s\n' "$out" | grep -qF 'MISSING permissions: deny rule Bash(gh pr:*) in .claude/settings.local.json blocks "gh pr' &&
  pass "perm: doctor reports a deny on gh pr as MISSING" || fail "perm: no MISSING for a deny on gh pr"
[ "$(printf '%s\n' "$out" | tail -n 1)" != "$(printf '%s\n' "$complete_out" | tail -n 1)" ] &&
  pass "perm: a blocking deny adds a problem to the doctor's verdict" || fail "perm: a blocking deny left the verdict unchanged"
cp "$mwork/local-full.json" "$mwork/project/.claude/settings.local.json"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["permissions"]["deny"].append("Bash(*/scripts/gate-train.sh*)"); json.dump(d, open(sys.argv[1], "w"))' \
  "$mwork/project/.claude/settings.json"
printf '%s\n' "$(mdoctor)" | grep -qF 'MISSING permissions: deny rule Bash(*/scripts/gate-train.sh*) in .claude/settings.json blocks' &&
  pass "perm: doctor reports a deny on a plugin script as MISSING" || fail "perm: no MISSING for a deny on the plugin scripts"
cp "$mwork/before.json" "$mwork/project/.claude/settings.json"
mperm --apply >/dev/null
expect "perm: the user's own settings are never read (their deny on gh pr is not reported)" "" \
  "$(mdoctor | grep 'permissions')"

# Docs: the README section, the setup step, the doctor rows, the changelog and the decisions log.
grep -q '^## Permission modes' "$plugin/README.md" && pass "perm: the README has a Permission modes section" ||
  fail "perm: no Permission modes section in the README"
perm_readme=$(awk '/^## Permission modes/ {on = 1; next} /^## / {on = 0} on' "$plugin/README.md")
for phrase in default auto bypass "permissions.sh" "ask" "settings.local.json"; do
  printf '%s\n' "$perm_readme" | grep -qF -- "$phrase" && pass "perm: the README section names \"$phrase\"" ||
    fail "perm: the README section does not name \"$phrase\""
done
grep -qF 'Permissions' "$plugin/skills/setup/SKILL.md" && grep -qF 'permissions.sh' "$plugin/skills/setup/SKILL.md" &&
  pass "perm: the setup skill has a Permissions step running permissions.sh" || fail "perm: no Permissions step in setup"
grep -qF 'note permissions: no allow list' "$plugin/skills/doctor/SKILL.md" &&
  grep -qF 'MISSING permissions: deny rule' "$plugin/skills/doctor/SKILL.md" &&
  pass "perm: the doctor skill has rows for the permissions lines" || fail "perm: no doctor skill rows for permissions"
grep -qF "#54" "$plugin/CHANGELOG.md" && pass "perm: CHANGELOG has an entry for #54" ||
  fail "perm: no CHANGELOG #54 entry"
grep -qF 'permission rule syntax' "$plugin/docs/DECISIONS.md" && pass "perm: the decisions log records the rule syntax" ||
  fail "perm: the decisions log does not record the rule syntax"

# 21. Never force-push (#53): repush.sh re-pushes a rebased branch as <branch>-vN (notes carried over, a plain
# -u push), open-pr.sh closes the superseded PRs, the gate and merge take the new name, cleanup.sh deletes a
# superseded branch only when a later version merged. Its own project, origin and fake GitHub.
export FAKE_GH_DIR="$work/gh-repush"
git init -q --bare "$work/repush.git"
git clone -q "$work/repush.git" "$work/repush" 2>/dev/null
cd "$work/repush" || exit 1
printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "true", "heavy": false}]}\n' >.dev-loop.json
echo one >src.txt
git add . && git commit -q -m "chore: start" && git push -q -u origin main
rnotes() { "$plugin/scripts/paths.sh" notes "$1"; }
remote_tip() { git ls-remote origin "refs/heads/$1" | cut -f1; }
rbranch() { # rbranch NAME: a branch from origin/main with one commit of its own, pushed; back on main
  git checkout -q -B "$1" origin/main && echo "$1" >"f-${1//\//_}.txt" && git add . &&
    git commit -q -m "feat: $1" && git push -q -u origin "$1" && git checkout -q main
}
repush() { # repush DIR ARGS...: run repush.sh in DIR; sets out (stdout) and rc
  out=$(cd "$1" && shift && "$plugin/scripts/repush.sh" "$@" 2>"$work/repush.err")
  rc=$?
}
pr_state() { cat "$FAKE_GH_DIR/${1//\//_}.state" 2>/dev/null; }
rclass() { awk -F'\t' -v s="$2" -v b="$3" '$2 == s && $3 == b {print $1}' "$1"; }

# A branch in its worktree, pushed with its notes; the base moves and the branch is rebased locally.
git worktree add -q -b fix/701-thing "$work/repush-701" origin/main
(cd "$work/repush-701" && echo a >a.txt && git add a.txt && git commit -q -m "fix: a (Refs #701)" &&
  git push -q -u origin fix/701-thing)
printf 'fix(x): the thing (#701)\n\n## Summary\n- a\n\nCloses #701\n' >"$(rnotes fix/701-thing)"
old_head=$(git rev-parse fix/701-thing)
gh pr create --head fix/701-thing --title "fix(x): the thing (#701)" --body-file /dev/null >/dev/null
echo two >>src.txt && git commit -q -am "chore: the base moves" && git push -q origin main
(cd "$work/repush-701" && git fetch -q origin && git rebase -q origin/main)
rebased=$(git rev-parse fix/701-thing)

echo dirty >"$work/repush-701/dirty.txt"
repush "$work/repush-701" fix/701-thing
[ "$rc" -ne 0 ] && pass "repush: refuses a dirty tree" || fail "repush pushed from a dirty tree"
expect "repush: a refused run pushes nothing" "" "$(git ls-remote origin 'refs/heads/fix/701-thing-v*')"
rm "$work/repush-701/dirty.txt"
repush "$work/repush-701" main
[ "$rc" -ne 0 ] && pass "repush: refuses the base branch" || fail "repush re-pushed the base branch"
repush "$work/repush-701" fix/799-missing
[ "$rc" -ne 0 ] && pass "repush: refuses a branch that does not exist" || fail "repush took a missing branch"

repush "$work/repush-701" fix/701-thing
expect "repush: exit 0 on a clean rebased branch" 0 "$rc"
expect "repush: prints the new name as its last line" fix/701-thing-v2 "$(printf '%s\n' "$out" | tail -n 1)"
expect "repush: the new name is on the remote at the rebased head" "$rebased" "$(remote_tip fix/701-thing-v2)"
expect "repush: the old remote branch is never moved" "$old_head" "$(remote_tip fix/701-thing)"
expect "repush: the old local branch is kept" "$rebased" "$(git rev-parse fix/701-thing)"
expect "repush: the worktree continues on the new branch" fix/701-thing-v2 \
  "$(git -C "$work/repush-701" rev-parse --abbrev-ref HEAD)"
expect "repush: a plain -u push, the new branch tracks its own remote branch" origin/fix/701-thing-v2 \
  "$(git -C "$work/repush-701" rev-parse --abbrev-ref '@{upstream}')"
expect "repush: the notes file is carried over to the new name" "fix(x): the thing (#701)" \
  "$(head -n 1 "$(rnotes fix/701-thing-v2)" 2>/dev/null)"
grep -qF 'Closes #701' "$(rnotes fix/701-thing-v2)" 2>/dev/null &&
  grep -qF "Supersedes \`fix/701-thing\` at $rebased $old_head " "$(rnotes fix/701-thing-v2)" &&
  pass "repush: the new notes keep the ticket and record what they supersede, at its local and remote tips" ||
  fail "repush: notes without the Supersedes record"
[ -f "$(rnotes fix/701-thing)" ] && pass "repush: the old notes file is kept" || fail "repush removed the old notes"

# The next free suffix: a version already on the remote, or a notes file of that name, is never reused.
git push -q origin "$old_head:refs/heads/fix/701-thing-v3"
echo stray >"$(rnotes fix/701-thing-v4)"
echo three >>src.txt && git commit -q -am "chore: the base moves again" && git push -q origin main
(cd "$work/repush-701" && git fetch -q origin && git rebase -q origin/main)
repush "$work/repush-701"
expect "repush: without a name it takes the checked-out branch and skips used suffixes" fix/701-thing-v5 \
  "$(printf '%s\n' "$out" | tail -n 1)"
expect "repush: an existing remote version is never overwritten" "$old_head" "$(remote_tip fix/701-thing-v3)"
expect "repush: an existing notes file of a candidate name is never overwritten" stray "$(cat "$(rnotes fix/701-thing-v4)")"
rm -f "$(rnotes fix/701-thing-v4)"
grep -qF 'Supersedes `fix/701-thing-v2`' "$(rnotes fix/701-thing-v5)" 2>/dev/null &&
  pass "repush: a second re-push supersedes the previous version" || fail "repush: v5 notes do not name v2"
grep -nE -- '--force|push[^|]* -f( |$)|[[:space:]]\+refs/|--mirror' "$plugin/scripts/repush.sh" >/dev/null &&
  fail "repush.sh has a forced push" || pass "repush.sh has no forced push"

# The tooling takes <type>/<n>-<slug>-vN names.
expect "names: dl_loop_branch takes a -vN name (default patterns)" yes \
  "$(bash -c '. "$1/scripts/lib/common.sh"; dl_load_config; dl_loop_branch "$2" && echo yes' _ "$plugin" fix/701-thing-v5)"
printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "true"}], "github": {"feature_patterns": ["fix/*"]}}\n' \
  >"$work/repush-patterns.json"
expect "names: dl_loop_branch takes a -vN name (configured patterns)" yes \
  "$(DEV_LOOP_CONFIG="$work/repush-patterns.json" bash -c '. "$1/scripts/lib/common.sh"; dl_load_config; dl_loop_branch "$2" && echo yes' _ "$plugin" fix/701-thing-v5)"
expect "names: the ticket of a -vN branch without notes is its number" 701 \
  "$(bash -c '. "$1/scripts/lib/common.sh"; dl_notes_ticket /nonexistent "$2"' _ "$plugin" fix/701-thing-v5)"
expect "names: paths.sh notes of a -vN branch" pr-fix_701-thing-v5.md "$(basename "$(rnotes fix/701-thing-v5)")"

# open-pr.sh opens the new PR and closes the open PRs of the versions it supersedes, pointing to it.
gh pr create --head fix/701-thing-v2 --title "v2" --body-file /dev/null >/dev/null
"$plugin/scripts/open-pr.sh" fix/701-thing-v5 >/dev/null
expect "open-pr: the new version's PR is open" OPEN "$(pr_state fix/701-thing-v5)"
expect "open-pr: the superseded PRs are closed" "CLOSED CLOSED" "$(pr_state fix/701-thing) $(pr_state fix/701-thing-v2)"
new_pr=$(cat "$FAKE_GH_DIR/fix_701-thing-v5.number")
grep -qF "#$new_pr" "$FAKE_GH_DIR/fix_701-thing.comment" 2>/dev/null &&
  grep -qF "fix/701-thing-v5" "$FAKE_GH_DIR/fix_701-thing.comment" &&
  pass "open-pr: the closed PR's comment points to the new PR" || fail "open-pr: no comment pointing to the new PR"
gh pr create --head fix/702-other --title "other" --body-file /dev/null >/dev/null 2>&1
"$plugin/scripts/open-pr.sh" fix/702-other >/dev/null
expect "open-pr: a branch without a version suffix closes nothing" OPEN "$(pr_state fix/702-other)"
rm -f "$FAKE_GH_DIR"/fix_702-other.*
# A name that only looks like a version closes nothing: neither a Supersedes line nor ancestry links it.
rbranch feat/708-api && gh pr create --head feat/708-api --title api --body-file /dev/null >/dev/null
rbranch feat/708-api-v2 && printf 'feat: api v2 (#708)\n\nCloses #708\n' >"$(rnotes feat/708-api-v2)"
"$plugin/scripts/open-pr.sh" feat/708-api-v2 >/dev/null 2>"$work/openpr.err"
expect "open-pr: an unrelated PR whose name looks like an earlier version stays open" OPEN "$(pr_state feat/708-api)"
grep -qF "left the PR of feat/708-api open" "$work/openpr.err" && pass "open-pr: says why it left that PR open" ||
  fail "open-pr: no warning for the PR it left open"
# Ancestry alone is enough: the new version builds on the old PR's head.
rbranch feat/710-grow && gh pr create --head feat/710-grow --title grow --body-file /dev/null >/dev/null
git checkout -q -B feat/710-grow-v2 feat/710-grow && echo more >>f-feat_710-grow.txt && git commit -q -am "feat: more" &&
  git push -q -u origin feat/710-grow-v2 && git checkout -q main
printf 'feat: grow (#710)\n\nCloses #710\n' >"$(rnotes feat/710-grow-v2)"
"$plugin/scripts/open-pr.sh" feat/710-grow-v2 >/dev/null 2>&1
expect "open-pr: an earlier version whose head the new one contains is closed" CLOSED "$(pr_state feat/710-grow)"
# Without the new PR's number nothing is closed, with a warning.
rbranch feat/709-n && gh pr create --head feat/709-n --title n --body-file /dev/null >/dev/null
rbranch feat/709-n-v2 && printf 'feat: n (#709)\n\nSupersedes `feat/709-n`\n' >"$(rnotes feat/709-n-v2)"
FAKE_GH_FAIL_NUMBER=1 "$plugin/scripts/open-pr.sh" feat/709-n-v2 >/dev/null 2>"$work/openpr.err"
expect "open-pr: without the new PR's number no superseded PR is closed" "OPEN OPEN" \
  "$(pr_state feat/709-n) $(pr_state feat/709-n-v2)"
grep -qF "could not read the PR number of feat/709-n-v2" "$work/openpr.err" &&
  pass "open-pr: warns when it cannot read the new PR's number" || fail "open-pr: no warning without the PR number"

# repush.sh warns visibly when the notes copy fails; the push stands.
git worktree add -q -b fix/711-ro "$work/repush-711" origin/main
(cd "$work/repush-711" && echo r >r.txt && git add r.txt && git commit -q -m "fix: r" && git push -q -u origin fix/711-ro)
printf 'fix: ro (#711)\n' >"$(rnotes fix/711-ro)"
chmod a-w "$("$plugin/scripts/paths.sh" notes-dir)"
repush "$work/repush-711" fix/711-ro
chmod u+w "$("$plugin/scripts/paths.sh" notes-dir)"
expect "repush: a failed notes copy does not undo the push" "0 fix/711-ro-v2" "$rc $(remote_tip fix/711-ro-v2 | sed 's/.\{1,\}/fix\/711-ro-v2/')"
grep -qF "notes file could not be written" "$work/repush.err" &&
  pass "repush: warns visibly when the notes copy fails" || fail "repush: no warning for a failed notes copy"
git worktree remove --force "$work/repush-711"

# The gate and merge take the new name; merge-train opens the PR from the new branch's notes.
out=$("$plugin/scripts/gate-train.sh" fix/701-thing-v5 2>&1)
expect "gate: a -vN branch gates green" 0 "$?"
out=$("$plugin/scripts/merge-train.sh" fix/701-thing-v5 2>&1)
expect "merge: a -vN branch merges" 0 "$?"
expect "merge: the -vN PR is merged" MERGED "$(pr_state fix/701-thing-v5)"
git fetch -q --prune origin

# cleanup.sh: superseded only when a later version merged (ledger or merged PR); the dangerous directions.
git push -q origin "$old_head:refs/heads/fix/701-thing-v6"            # a later version, not merged
rbranch feat/702-other && rbranch feat/702-other-v2                    # successor with an open PR
gh pr create --head feat/702-other-v2 --title v2 --body-file /dev/null >/dev/null
printf 'feat: other (#702)\n\nCloses #702\n' >"$(rnotes feat/702-other)"
rbranch feat/703-gone && rbranch feat/703-gone-v2                      # successor closed unmerged
gh pr create --head feat/703-gone-v2 --title v2 --body-file /dev/null >/dev/null && echo CLOSED >"$FAKE_GH_DIR/feat_703-gone-v2.state"
rbranch feat/704-d && rbranch feat/704-d-v2                            # successor merged by PR only
printf 'feat: d (#704)\n\nSupersedes `feat/704-d` at %s (re-pushed)\n' "$(git rev-parse feat/704-d)" >"$(rnotes feat/704-d-v2)"
rbranch feat/712-api && rbranch feat/712-api-v2                        # same-name successor, no record
gh pr create --head feat/712-api-v2 --title v2 --body-file /dev/null >/dev/null && gh pr merge feat/712-api-v2 --squash >/dev/null
rbranch feat/713-m && rbranch feat/713-m-v2                            # the old branch moved on (locally)
printf 'feat: m (#713)\n\nSupersedes `feat/713-m` at %s\n' "$(git rev-parse feat/713-m)" >"$(rnotes feat/713-m-v2)"
gh pr create --head feat/713-m-v2 --title v2 --body-file /dev/null >/dev/null && gh pr merge feat/713-m-v2 --squash >/dev/null
git branch -q feat/714-c origin/main && rbranch feat/714-c-v2          # contained in the base, no record
gh pr create --head feat/714-c-v2 --title v2 --body-file /dev/null >/dev/null && gh pr merge feat/714-c-v2 --squash >/dev/null
git checkout -q feat/713-m && echo later >>f-feat_713-m.txt && git commit -q -am "feat: after the re-push" && git checkout -q main
gh pr create --head feat/704-d-v2 --title v2 --body-file /dev/null >/dev/null && gh pr merge feat/704-d-v2 --squash >/dev/null
rbranch feat/706-e && gh pr create --head feat/706-e --title e --body-file /dev/null >/dev/null
rbranch feat/706-e-v2 && gh pr create --head feat/706-e-v2 --title v2 --body-file /dev/null >/dev/null &&
  gh pr merge feat/706-e-v2 --squash >/dev/null                        # merged, but the old PR is still open
rbranch feat/707-api && rbranch feat/7070-api-v2                       # another ticket's name is no successor
gh pr create --head feat/7070-api-v2 --title x --body-file /dev/null >/dev/null && gh pr merge feat/7070-api-v2 --squash >/dev/null
rbranch feat/705-plan-v2 && printf '705\tOPEN\t\n' >"$FAKE_GH_DIR/issues.tsv"
git fetch -q origin

out=$("$plugin/scripts/cleanup.sh" 2>&1)
report=$(echo "$out" | sed -n 's/^report: //p')
for row in "superseded local fix/701-thing" "superseded remote fix/701-thing" "superseded local fix/701-thing-v2" \
  "superseded remote fix/701-thing-v2" "keep remote fix/701-thing-v3" "keep remote fix/701-thing-v6" \
  "keep local feat/702-other" "keep remote feat/702-other" "keep local feat/703-gone" "superseded local feat/704-d" \
  "superseded remote feat/704-d" "keep local feat/706-e" "keep local feat/707-api" "keep local feat/705-plan-v2" \
  "keep local feat/712-api" "keep remote feat/712-api" "keep local feat/713-m" "superseded remote feat/713-m" "merged local feat/714-c"; do
  read -r want scope name <<<"$row"
  expect "cleanup: $scope $name is $want" "$want" "$(rclass "$report" "$scope" "$name")"
done
grep -q "^superseded"$'\t'"local"$'\t'"fix/701-thing"$'\t'".*fix/701-thing-v5" "$report" &&
  pass "cleanup: a superseded branch names the version that merged" || fail "cleanup: no successor in the reason"
grep -q "feat/712-api"$'\t'".*no Supersedes record" "$report" &&
  pass "cleanup: a same-name later version without a Supersedes record keeps the branch, and says why" ||
  fail "cleanup: no 'no Supersedes record' reason"
grep -q "^keep"$'\t'"local"$'\t'"feat/713-m"$'\t'".*moved on since the re-push" "$report" &&
  pass "cleanup: a branch with commits after the re-push is kept, and says why" ||
  fail "cleanup: no 'moved on since the re-push' reason"
grep -q "feat/705-plan-v2.*issue #705 is open" "$report" &&
  pass "cleanup: the ticket number of a -vN name is found" || fail "cleanup: no ticket for feat/705-plan-v2"
echo "$out" | grep -q "^superseded local  *fix/701-thing " &&
  pass "cleanup: the dry run lists the superseded branches" || fail "cleanup: the dry run does not list them"
expect "cleanup: the dry run deletes nothing" "$old_head" "$(remote_tip fix/701-thing)"

out=$("$plugin/scripts/cleanup.sh" --apply 2>&1)
echo "$out"
expect "cleanup --apply: superseded branches are deleted locally" "" \
  "$(git branch --list fix/701-thing fix/701-thing-v2 feat/704-d)"
expect "cleanup --apply: superseded branches are deleted on the remote" "" \
  "$(git ls-remote origin refs/heads/fix/701-thing refs/heads/fix/701-thing-v2 refs/heads/feat/704-d)"
expect "cleanup --apply: unrecorded and moved-on originals are kept" "feat/712-api feat/713-m" \
  "$(git branch --list --format='%(refname:short)' feat/712-api feat/713-m | paste -sd' ' -)"
expect "cleanup --apply: a same-name branch without a record is kept on the remote" "$old_head" "$(remote_tip fix/701-thing-v3)"
expect "cleanup --apply: an unmerged successor keeps the original, locally and remotely" "feat/702-other feat/702-other" \
  "$(git branch --list --format='%(refname:short)' feat/702-other) $(git ls-remote origin refs/heads/feat/702-other | sed 's:.*refs/heads/::')"
expect "cleanup --apply: originals of unmerged, open or foreign successors are kept" \
  "feat/703-gone feat/706-e feat/707-api" \
  "$(git branch --list --format='%(refname:short)' feat/703-gone feat/706-e feat/707-api | paste -sd' ' -)"
expect "cleanup --apply: a later unmerged version is kept" "$old_head" "$(remote_tip fix/701-thing-v6)"
bundle=$(echo "$out" | sed -n 's/^archived [0-9]* tips to //p')
git fetch -q "$bundle" "refs/remotes/origin/fix/701-thing:refs/heads/restored701" 2>/dev/null &&
  expect "cleanup --apply: the bundle restores a superseded branch" "$old_head" "$(git rev-parse restored701)" ||
  fail "cleanup: the bundle lacks the superseded remote branch"
git branch -q -D restored701 2>/dev/null
[ -f "$("$plugin/scripts/paths.sh" notes-dir)/merged/pr-fix_701-thing.md" ] &&
  pass "cleanup --apply: the notes of a deleted superseded branch move to notes/merged" ||
  fail "cleanup: the superseded notes file was not archived"
[ -f "$(rnotes feat/702-other)" ] && pass "cleanup --apply: the notes of a kept original stay" || fail "cleanup moved kept notes"

# A notes file that ends with the PR footer keeps it last: the Supersedes line goes before it (#76).
git worktree add -q -b fix/730-footer "$work/repush-730" origin/main
(cd "$work/repush-730" && echo f >f730.txt && git add f730.txt && git commit -q -m "fix: f (Refs #730)" &&
  git push -q -u origin fix/730-footer)
printf 'fix: footer (#730)\n\n## Summary\n- f\n\n\360\237\244\226 Generated with [Claude Code](https://claude.com/claude-code)\n' \
  >"$(rnotes fix/730-footer)"
repush "$work/repush-730" fix/730-footer
expect "repush: a notes file with a footer is carried over" "0 fix/730-footer-v2" "$rc $(printf '%s\n' "$out" | tail -n 1)"
expect "repush: the footer stays the last line, once, after the Supersedes line" \
  "Supersedes|blank|footer|1" \
  "$(tail -n 3 "$(rnotes fix/730-footer-v2)" | awk '/^Supersedes `fix\/730-footer` at / {print "Supersedes"; next}
    /^$/ {print "blank"; next} /Generated with \[Claude Code\]/ {print "footer"; next} {print "other: " $0}' |
    paste -sd'|' -)|$(grep -c 'Generated with' "$(rnotes fix/730-footer-v2)")"
expect "repush: the body before the footer is kept" "- f" "$(sed -n 4p "$(rnotes fix/730-footer-v2)")"
git worktree remove --force "$work/repush-730"

# No skill or agent text tells anyone to force-push; the ones that rebase name repush.sh.
forced=$(grep -rnE -- 'push --force|push -f|--force-with-lease|force-push|force push' "$plugin/skills" "$plugin/agents" |
  grep -viE 'never')
expect "docs: no skill or agent text tells anyone to force-push" "" "$forced"
for file in skills/dev-loop/SKILL.md skills/gate/SKILL.md skills/merge/SKILL.md agents/implementer.md README.md; do
  grep -qF 'repush.sh' "$plugin/$file" && pass "docs: $file names repush.sh" || fail "$file does not name repush.sh"
done
grep -qF 'superseded' "$plugin/README.md" && pass "docs: the README describes the superseded class" ||
  fail "the README lacks the superseded class"
grep -qF "#53" "$plugin/CHANGELOG.md" && pass "docs: CHANGELOG has an entry for #53" ||
  fail "no CHANGELOG #53 entry"
grep -qF 'repush.sh' "$plugin/docs/DECISIONS.md" && pass "docs: DECISIONS records the re-push naming" ||
  fail "DECISIONS has no #53 entry"
export FAKE_GH_DIR="$work/gh"

# 22. Status (#55): the event log (gate, merge, heavy and event.sh lines, valid JSON, rotated with one
# old file kept, write errors ignored) and status.sh (read-only: the gate, the heavy slots, the loop
# worktrees, the last merge, open tickets, the orchestrator's last event and a verdict; --json).
swork="$work/status"
shome="$swork/home"
git init -q --bare "$swork/origin.git"
git clone -q "$swork/origin.git" "$swork/project" 2>/dev/null
cd "$swork/project" || exit 1
cat >.dev-loop.json <<'EOF'
{"base_branch": "main", "checks": [{"name": "unit", "command": "sleep 4; echo unit ok", "heavy": false}],
 "heavy": {"slots": 2, "poll_seconds": 1}}
EOF
echo one >src.txt
git add . && git commit -q -m "chore: start" && git push -q -u origin main
sstate="$shome/project"
sevents="$sstate/events.jsonl"
# senv COMMAND...: run COMMAND with the status section's state, lock directory and fake gh store.
senv() { DEV_LOOP_HOME="$shome" DEV_LOOP_LOCK_DIR="$swork/locks" FAKE_GH_DIR="$swork/gh" "$@"; }
sstatus() { senv "$plugin/scripts/status.sh" --no-gh "$@" 2>&1; }
# valid_lines FILE: "jq|python3" counts of the lines of FILE that parse as JSON objects (all of them: "n|n").
valid_lines() {
  printf '%s|%s' "$(jq -R 'fromjson? | objects | 1' "$1" 2>/dev/null | wc -l | tr -d ' ')" \
    "$(python3 -I -c '
import json, sys
n = 0
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        n += isinstance(json.loads(line), dict)
    except ValueError:
        pass
print(n)' "$1")"
}
# sjson FILTER [STATUS_ARGS...]: the jq FILTER of status.sh --json.
sjson() {
  local filter=$1
  shift
  sstatus --json "$@" | jq -r "$filter" 2>/dev/null
}
# wait_event EVENT [FILE]: wait (up to 15 s) until an event of that name is in the log.
wait_event() {
  local _i
  for _i in $(seq 1 75); do grep -q "\"event\":\"$1\"" "${2:-$sevents}" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}

expect "status: paths.sh events is the event log in the state directory" "$sevents" \
  "$(senv "$plugin/scripts/paths.sh" events)"

# Idle: nothing ran yet, no event log; status reads nothing it cannot find and writes nothing.
mkdir -p "$sstate"
out=$(sstatus)
echo "$out"
expect "status: a fresh project is idle" "verdict: idle" "$(echo "$out" | tail -n 1)"
echo "$out" | grep -q '^gate: not running' && pass "status: idle shows the gate not running" ||
  fail "status: idle gate line"
expect "status: status.sh creates no event log" "" "$(ls "$sstate")"
expect "status: --json is valid for jq" idle "$(sjson .verdict.state)"
sstatus --json | python3 -I -c 'import json, sys; v = json.load(sys.stdin); sys.exit(v["verdict"]["state"] != "idle")' &&
  pass "status: --json is valid for python3" || fail "status: --json not valid for python3"
expect "status: the python3 fallback gives the same verdict" idle \
  "$(DEV_LOOP_NO_JQ=1 sstatus --json | jq -r .verdict.state)"
expect "status: --json has every top-level key" "gate heavy last_merge now open_tickets orchestrator repo verdict worktrees" \
  "$(sjson 'keys | join(" ")')"

# event.sh: one valid JSON line per call, quotes, backslashes, tabs and other scripts kept, who fixed.
senv "$plugin/scripts/event.sh" agent-started ticket=11 'detail=say "hi" \ back	tab é' who=gate t=x \
  'bad key=1' novalue
expect "status: event.sh exits 0" 0 $?
expect "status: event lines are valid JSON for jq and python3" "1|1" "$(valid_lines "$sevents")"
line=$(tail -n 1 "$sevents")
expect "status: event.sh records who orchestrator, the event and its keys" \
  'orchestrator|agent-started|11|say "hi" \ back	tab é|null|null' \
  "$(printf '%s' "$line" | jq -r '[.who, .event, .ticket, .detail, .["bad key"], .novalue] | map(tostring) | join("|")')"
printf '%s' "$line" | jq -e '.t | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null &&
  pass "status: an event has a UTC time" || fail "status: event time $line"
senv "$plugin/scripts/event.sh" 'na"me' 'detail=x"y' && expect "status: a quoted event name stays valid JSON" "2|2" \
  "$(valid_lines "$sevents")"
expect "status: event.sh without an event is a usage error" 2 "$(senv "$plugin/scripts/event.sh" 2>/dev/null; echo $?)"

# Rotation: over the cap the log moves to events.jsonl.1 (one old file kept) and a new one starts.
rot="$swork/rot"
for n in $(seq 1 30); do
  DEV_LOOP_EVENTS_MAX_BYTES=400 DEV_LOOP_HOME="$rot" "$plugin/scripts/event.sh" "step-$n" detail="event number $n"
done
[ -s "$rot/project/events.jsonl.1" ] && [ "$(wc -c <"$rot/project/events.jsonl" | tr -d ' ')" -lt 600 ] &&
  pass "status: the log rotates at the cap and keeps the old file as .1" || fail "status: no rotation"
expect "status: only one old file is kept" "events.jsonl events.jsonl.1" "$(cd "$rot/project" && echo *)"
expect "status: the newest event is in the current log" step-30 "$(tail -n 1 "$rot/project/events.jsonl" | jq -r .event)"
rot_lines=$(($(wc -l <"$rot/project/events.jsonl") + 0))
expect "status: the rotated log is valid JSON" "$(wc -l <"$rot/project/events.jsonl.1" | tr -d ' ')|$(wc -l <"$rot/project/events.jsonl.1" | tr -d ' ')" \
  "$(valid_lines "$rot/project/events.jsonl.1")"
expect "status: the current log is valid JSON" "$rot_lines|$rot_lines" "$(valid_lines "$rot/project/events.jsonl")"

# A write error never fails a step: the event log is a directory here.
bad="$swork/bad"
mkdir -p "$bad/project/events.jsonl"
err=$(DEV_LOOP_HOME="$bad" "$plugin/scripts/event.sh" agent-started 2>&1)
expect "status: event.sh ignores a write error" "0|" "$?|$err"
err=$(DEV_LOOP_HOME="$bad" DEV_LOOP_LOCK_DIR="$swork/locks" "$plugin/scripts/heavy.sh" bash -c 'echo ran' 2>/dev/null)
expect "status: heavy.sh runs its command when the event log cannot be written" "0|ran" "$?|$err"

# A real gate with a slow stage: running, its stage and log, a waiting verdict; then the merge's events.
git checkout -q -b feat/7-gated
echo two >>src.txt && git commit -q -am "feat: two (Refs #7)" && git push -q -u origin feat/7-gated
git checkout -q main
mkdir -p "$(senv "$plugin/scripts/paths.sh" notes-dir)"
printf 'feat: two (#7)\n\nCloses #7\n' >"$(senv "$plugin/scripts/paths.sh" notes feat/7-gated)"
senv "$plugin/scripts/gate-train.sh" feat/7-gated >"$swork/gate.out" 2>&1 &
gate_bg=$!
wait_event stage-started || fail "status: the gate wrote no stage-started event"
out=$(sstatus)
echo "$out"
echo "$out" | grep -qE "^gate: running, pid [0-9]+, .*train: feat/7-gated" && pass "status: shows the running gate and its train" ||
  fail "status: no running gate line"
echo "$out" | grep -qE "^  stage unit: .*output [0-9]+s ago.*log .*train-unit.log" &&
  pass "status: shows the running stage, its output age and its log" || fail "status: no stage line"
echo "$out" | tail -n 1 | grep -qE '^verdict: waiting on gate stage unit \(output [0-9]+s ago\)$' &&
  pass "status: a running gate is a waiting verdict" || fail "status: verdict while the gate runs"
expect "status: --json names the running stage" "true|unit|waiting" \
  "$(sjson '[.gate.running, .gate.stages[0].name, .verdict.state] | map(tostring) | join("|")')"
wait "$gate_bg"
expect "status: the gate stays green with events" 0 $?
grep -q '^TRAIN GREEN' "$swork/gate.out" && pass "status: the gate prints TRAIN GREEN as before" || fail "status: gate output"
expect "status: the gate's events in order" "train-started stage-started:unit stage-ended:unit:0 train-ended:0:green" \
  "$(jq -r 'select(.who == "gate") | [.event, .stage, .rc, .result] | map(select(. != null)) | join(":")' "$sevents" | paste -sd' ' -)"
expect "status: train-started records the gate's pid and branches" "feat/7-gated|yes" \
  "$(jq -r 'select(.event == "train-started") | [.branches, (.pid | test("^[0-9]+$") | if . then "yes" else "no" end)] | join("|")' "$sevents")"
expect "status: after the gate the gate is not running" "gate: not running" "$(sstatus | grep '^gate:')"
senv "$plugin/scripts/merge-train.sh" feat/7-gated >"$swork/merge.out" 2>&1
expect "status: the merge is green with events" 0 $?
expect "status: the merge's events" "merge-started:feat/7-gated merged:feat/7-gated:7 merge-ended:0" \
  "$(jq -r 'select(.who == "merge") | [.event, .branches, .branch, .ticket, .rc] | map(select(. != null)) | join(":")' "$sevents" | paste -sd' ' -)"
sstatus | grep -qE '^last merge: feat/7-gated #7, [0-9]+s ago' && pass "status: shows the last merge from the ledger" ||
  fail "status: no last merge line"
expect "status: all event lines so far are valid JSON" "$(wc -l <"$sevents" | tr -d ' ')|$(wc -l <"$sevents" | tr -d ' ')" \
  "$(valid_lines "$sevents")"

# A heavy job holds a slot: status names its slot, pid and repository; the slot is free after release.
DEV_LOOP_HOME="$shome" DEV_LOOP_LOCK_DIR="$swork/locks" "$plugin/scripts/heavy.sh" bash -c 'sleep 4' >/dev/null 2>&1 &
heavy_bg=$!
wait_event slot-acquired || fail "status: heavy.sh wrote no slot-acquired event"
out=$(sstatus)
echo "$out"
echo "$out" | grep -qE "^heavy: 1 of 2 slots in use" && pass "status: counts the heavy slots in use" || fail "status: heavy line"
echo "$out" | grep -qE "^  slot 1: pid $heavy_bg, project, [0-9]+s: bash -c sleep 4" &&
  pass "status: names the slot's holder" || fail "status: no slot holder line"
echo "$out" | tail -n 1 | grep -qE '^verdict: waiting on heavy job in slot 1 \(output [0-9]+s ago\)$' &&
  pass "status: a heavy job of this repository is a waiting verdict" || fail "status: heavy verdict"
expect "status: --json lists the holder" "1|$heavy_bg|project" \
  "$(sjson '.heavy.held[0] | [.slot, .pid, .repo] | map(tostring) | join("|")')"
wait "$heavy_bg"
expect "status: a released slot is free" "heavy: 0 of 2 slots in use" "$(sstatus | grep '^heavy:')"
expect "status: heavy.sh records acquired and released with rc" "slot-acquired:1 slot-released:1:0" \
  "$(jq -r 'select(.who == "heavy") | [.event, .slot, .rc] | map(select(. != null)) | join(":")' "$sevents" | paste -sd' ' -)"

# Loop worktrees, with and without notes; the orchestrator's events drive the verdict.
git worktree add -q -b feat/11-alpha "$swork/wt-alpha" origin/main
(cd "$swork/wt-alpha" && echo a >a.txt && git add a.txt && git commit -q -m "feat: a (Refs #11)" && git push -q -u origin feat/11-alpha)
printf 'feat: a (#11)\n\nCloses #11\n' >"$(senv "$plugin/scripts/paths.sh" notes feat/11-alpha)"
git worktree add -q -b fix/12-beta "$swork/wt-beta" origin/main
(cd "$swork/wt-beta" && echo b >b.txt && git add b.txt && git commit -q -m "fix: b (Refs #12)")
senv "$plugin/scripts/event.sh" agent-started ticket=11
out=$(sstatus)
echo "$out"
echo "$out" | grep -qE "^  feat/11-alpha #11: commit [0-9]+s ago, notes [0-9]+s ago, pushed, ahead 1 behind 0 \($swork/wt-alpha\)$" &&
  pass "status: a worktree with notes, pushed" || fail "status: alpha worktree line"
echo "$out" | grep -qE "^  fix/12-beta #12: commit [0-9]+s ago, no notes, not pushed, ahead 1 behind 0 \($swork/wt-beta\)$" &&
  pass "status: a worktree without notes, not pushed" || fail "status: beta worktree line"
echo "$out" | grep -qE '^orchestrator: agent-started #11, [0-9]+s ago$' && pass "status: shows the orchestrator's last event" ||
  fail "status: orchestrator line"
echo "$out" | grep -q '^worktrees: 2' && pass "status: the main checkout and the gate worktree are not loop worktrees" ||
  fail "status: worktree count"
expect "status: agents at work is a working verdict" "verdict: working" "$(echo "$out" | tail -n 1)"
expect "status: --json worktrees" "feat/11-alpha:11:true:true fix/12-beta:12:false:false" \
  "$(sjson '.worktrees[] | [.branch, .ticket, .pushed, (.notes_age_seconds != null)] | map(tostring) | join(":")' | paste -sd' ' -)"
senv "$plugin/scripts/event.sh" waiting detail="agents for #11 #12"
sstatus | tail -n 1 | grep -qE '^verdict: waiting on agents for #11 #12 \(output [0-9]+s ago\)$' &&
  pass "status: a waiting event of the orchestrator is a waiting verdict" || fail "status: orchestrator waiting verdict"
senv "$plugin/scripts/event.sh" waiting-review
sstatus | tail -n 1 | grep -qE '^verdict: waiting on review \(output [0-9]+s ago\)$' &&
  pass "status: waiting-<what> names what it waits on" || fail "status: waiting-<what> verdict"

# Open tickets through gh (optional): --no-gh skips it.
mkdir -p "$swork/gh"
printf '11\tOPEN\t\n12\tOPEN\t\n13\tOPEN\t\n' >"$swork/gh/issues.tsv"
expect "status: counts open tickets with gh" "open tickets: 3" \
  "$(senv "$plugin/scripts/status.sh" 2>&1 | grep '^open tickets')"
expect "status: --no-gh does not ask gh" "open tickets: not checked (--no-gh)" "$(sstatus | grep '^open tickets')"

# A stalled gate (hand-made state): the train's pid lives, but neither its log nor its events moved.
st_home="$swork/stalled"
st_state="$st_home/project"
mkdir -p "$st_state/logs"
sleep 60 &
stuck=$!
printf '%s feat/8-stuck\n' "$stuck" >"$st_state/train-running.txt"
printf 'e2e output\n' >"$st_state/logs/train-e2e.log"
printf '{"t":"2020-01-01T00:00:00Z","who":"gate","event":"train-started","pid":"%s","branches":"feat/8-stuck"}\n{"t":"2020-01-01T00:00:01Z","who":"gate","event":"stage-started","stage":"e2e","log":"%s"}\n' \
  "$stuck" "$st_state/logs/train-e2e.log" >"$st_state/events.jsonl"
touch -t 202001010000 "$st_state/logs/train-e2e.log" "$st_state/events.jsonl" "$st_state/train-running.txt"
git worktree remove --force "$swork/wt-alpha" && git worktree remove --force "$swork/wt-beta"
stat_st() { DEV_LOOP_HOME="$st_home" DEV_LOOP_LOCK_DIR="$swork/locks" "$plugin/scripts/status.sh" --no-gh "$@" 2>&1; }
out=$(stat_st)
echo "$out"
echo "$out" | grep -qE "^gate: running, pid $stuck, " && pass "status: a stalled gate still shows as running" ||
  fail "status: stalled gate line"
echo "$out" | tail -n 1 | grep -qE '^verdict: possibly stalled: no event or output for [0-9]+ min$' &&
  pass "status: a stage log that stopped growing is possibly stalled" || fail "status: stalled verdict"
expect "status: --json stalled" "stalled|e2e" "$(stat_st --json | jq -r '[.verdict.state, .gate.stages[0].name] | join("|")')"
# While the gate runs, an implementer's fresh commit and notes do not hide the frozen stage.
git worktree add -q -b feat/13-busy "$swork/wt-busy" origin/main
(cd "$swork/wt-busy" && echo c >c.txt && git add c.txt && git commit -q -m "feat: c (Refs #13)")
DEV_LOOP_HOME="$st_home" "$plugin/scripts/paths.sh" notes feat/13-busy >/dev/null
printf 'feat: c (#13)\n\nCloses #13\n' >"$(DEV_LOOP_HOME="$st_home" "$plugin/scripts/paths.sh" notes feat/13-busy)"
stat_st | tail -n 1 | grep -qE '^verdict: possibly stalled: no event or output for [0-9]+ min$' &&
  pass "status: a frozen stage with a fresh worktree commit is still possibly stalled" || fail "status: worktree activity hid a frozen stage"
# A fresh heavy event of this repository (an implementer's heavy job) does not hide the frozen stage either.
cp "$st_state/events.jsonl" "$swork/stalled-events.keep"
printf '{"t":"%s","who":"heavy","event":"queued","pid":"999999","detail":"implementer tests"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$st_state/events.jsonl"
stat_st | tail -n 1 | grep -qE '^verdict: possibly stalled: no event or output for [0-9]+ min$' &&
  pass "status: a frozen stage with a fresh heavy event of this repository is still possibly stalled" ||
  fail "status: a heavy event hid a frozen stage"
cp -p "$swork/stalled-events.keep" "$st_state/events.jsonl"
touch -t 202001010000 "$st_state/events.jsonl"
# The gate's own job queued in heavy.sh (gate_pid is the running gate's pid) is waiting, never stalled; an
# implementer's queued job (no gate_pid, or another gate's) leaves the frozen stage possibly stalled.
# qbg COMMAND... &: run COMMAND in the background with one heavy slot (exec, so $! is the command's pid).
qbg() { DEV_LOOP_HOME="$st_home" DEV_LOOP_LOCK_DIR="$swork/locks-q" DEV_LOOP_HEAVY_SLOTS=1 exec "$@"; }
qbg "$plugin/scripts/heavy.sh" sleep 60 >/dev/null 2>&1 &
q_holder=$!
wait_event slot-acquired "$st_state/events.jsonl" || fail "status: the slot holder wrote no slot-acquired event"
DL_GATE_PID=$stuck qbg "$plugin/scripts/heavy.sh" true >/dev/null 2>&1 &
q_gate=$!
wait_event queued "$st_state/events.jsonl" || fail "status: the gate's queued job wrote no queued event"
expect "status: heavy.sh records the gate's pid in its queued event" "$stuck" \
  "$(jq -r 'select(.event == "queued") | .gate_pid' "$st_state/events.jsonl" | tail -n 1)"
out=$(stat_st)
echo "$out"
expect "status: the gate's own job queued for a heavy slot is waiting, not stalled" \
  "verdict: waiting on heavy slot (queued)" "$(echo "$out" | tail -n 1)"
expect "status: --json names the gate's queued job" "waiting|$q_gate|$stuck" \
  "$(stat_st --json | jq -r '[.verdict.state, .heavy.waiting[0].pid, .heavy.waiting[0].gate_pid] | map(tostring) | join("|")')"
kill "$q_gate" 2>/dev/null
wait "$q_gate" 2>/dev/null
qbg "$plugin/scripts/heavy.sh" true >/dev/null 2>&1 &
q_impl=$!
for _i in $(seq 1 75); do [ "$(grep -c '"event":"queued"' "$st_state/events.jsonl")" -ge 2 ] && break; sleep 0.2; done
stat_st | tail -n 1 | grep -qE '^verdict: possibly stalled: no event or output for [0-9]+ min$' &&
  pass "status: an implementer's queued heavy job plus a frozen stage stays possibly stalled" ||
  fail "status: an implementer's queued job hid a frozen stage"
sleep 60 &
q_other_gate=$!
printf '{"t":"%s","who":"heavy","event":"queued","pid":"%s","gate_pid":"%s","detail":"another gate"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$q_other_gate" "$q_other_gate" >>"$st_state/events.jsonl"
stat_st | tail -n 1 | grep -qE '^verdict: possibly stalled: no event or output for [0-9]+ min$' &&
  pass "status: a queued job of another gate pid does not hide a frozen stage" ||
  fail "status: another gate's queued job hid a frozen stage"
mkdir -p "$st_home/other"
printf '{"t":"%s","who":"heavy","event":"queued","pid":"%s","gate_pid":"%s","detail":"same pid, other repo"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$q_other_gate" "$stuck" >"$st_home/other/events.jsonl"
stat_st | tail -n 1 | grep -qE '^verdict: possibly stalled: no event or output for [0-9]+ min$' &&
  pass "status: another repository's queued job naming this gate's pid does not hide a frozen stage" ||
  fail "status: another repository's queued job with this gate's pid hid a frozen stage"
rm -rf "$st_home/other"
kill "$q_impl" "$q_other_gate" 2>/dev/null
wait "$q_impl" "$q_other_gate" 2>/dev/null
pkill -P "$q_holder" 2>/dev/null
wait "$q_holder" 2>/dev/null
cp -p "$swork/stalled-events.keep" "$st_state/events.jsonl"
touch -t 202001010000 "$st_state/events.jsonl"
# Another repository sharing the heavy queue: its live slot and fresh event show, but never count here.
sleep 60 &
other=$!
mkdir -p "$st_home/other"
printf '{"t":"%s","who":"heavy","event":"slot-acquired","slot":"2","pid":"%s","detail":"other e2e"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$other" >"$st_home/other/events.jsonl"
out=$(stat_st)
echo "$out" | grep -qE "^  slot 2: pid $other, other, [0-9]+s: other e2e$" && pass "status: lists another repository's slot holder" ||
  fail "status: no slot line for the other repository"
echo "$out" | tail -n 1 | grep -qE '^verdict: possibly stalled: no event or output for [0-9]+ min$' &&
  pass "status: another repository's fresh heavy event does not mask a stall" || fail "status: other repository masked the stall"
git worktree remove --force "$swork/wt-busy"
mv "$st_state/train-running.txt" "$swork/train-running.keep"
expect "status: another repository's live slot is not this repository's activity" idle \
  "$(stat_st --json | jq -r .verdict.state)"
mv "$swork/train-running.keep" "$st_state/train-running.txt"
kill "$other" 2>/dev/null
wait "$other" 2>/dev/null
rm -rf "$st_home/other"
printf '{"watchdog": {"stall_minutes": 99999999}, "checks": ["true"]}\n' >"$swork/patient.json"
DEV_LOOP_CONFIG="$swork/patient.json" stat_st | tail -n 1 | grep -qE '^verdict: waiting on gate stage e2e' &&
  pass "status: watchdog.stall_minutes sets the threshold" || fail "status: stall_minutes ignored"
printf 'more\n' >>"$st_state/logs/train-e2e.log"
stat_st | tail -n 1 | grep -qE '^verdict: waiting on gate stage e2e \(output [0-9]+s ago\)$' &&
  pass "status: a growing stage log is waiting again" || fail "status: growing log verdict"
kill "$stuck" 2>/dev/null
wait "$stuck" 2>/dev/null
stat_st | grep -qE "^gate: not running \(train-running.txt names pid $stuck, which has ended\)" &&
  pass "status: a dead gate pid is not running" || fail "status: dead gate pid"
expect "status: a dead gate is said in the idle verdict" "verdict: idle (the last gate died: train-running.txt is stale)" \
  "$(stat_st | tail -n 1)"
expect "status: --json flags the dead gate" "idle|true|true" \
  "$(stat_st --json | jq -r '[.verdict.state, .verdict.gate_died, .gate.stale] | map(tostring) | join("|")')"
expect "status: --json without a dead gate has the flags false" "false|false" \
  "$(sjson '[.verdict.gate_died, .gate.stale] | map(tostring) | join("|")')"

# The verdict follows what is moving (#67): a wait ended by later evidence is over, a fresh event alone is
# not work, and the orchestrator's idle event is honoured (hand-made event logs, times relative to now).
vhome="$swork/verdict"
vstate="$vhome/project"
mkdir -p "$vstate"
vstat() { DEV_LOOP_HOME="$vhome" DEV_LOOP_LOCK_DIR="$swork/locks" "$plugin/scripts/status.sh" --no-gh "$@" 2>&1; }
vverdict() { vstat | tail -n 1; }
vevent() { DEV_LOOP_HOME="$vhome" "$plugin/scripts/event.sh" "$@"; }
# ago SECONDS: the UTC time that many seconds ago.
ago() { jq -n -r --argjson s "$1" 'now - $s | floor | todate'; }
# vlog WHO EVENT SECONDS_AGO [KEY VALUE]...: append one hand-made event to the verdict section's log.
vlog() {
  local who=$1 event=$2 t
  t=$(ago "$3")
  shift 3
  jq -n -c --arg t "$t" --arg who "$who" --arg event "$event" --args \
    '$ARGS.positional as $p | {t: $t, who: $who, event: $event} + ([range(0; $p | length; 2) as $i | {($p[$i]): $p[$i + 1]}] | add // {})' "$@" \
    >>"$vstate/events.jsonl"
}
# vreset: an empty event log, ledger and gate file.
vreset() { rm -f "$vstate/events.jsonl" "$vstate/merged.jsonl" "$vstate/train-running.txt"; }

# 1. A stale gate wait: the gate ran green and merge-train.sh merged that branch after the wait.
vreset
vlog orchestrator waiting 960 detail "gate chore/release-0.8.1"
vlog gate train-started 950 pid 999999 branches chore/release-0.8.1
vlog gate train-ended 760 rc 0 result green
vlog merge merge-started 730 branches chore/release-0.8.1
vlog merge merged 720 branch chore/release-0.8.1 ticket 66
vlog merge merge-ended 719 rc 0
printf '{"branch":"chore/release-0.8.1","ticket":"66","merged_at":"%s"}\n' "$(ago 720)" >"$vstate/merged.jsonl"
out=$(vstat)
echo "$out"
expect "status: a gate wait followed by the merge of its branch is over: idle" "verdict: idle" "$(echo "$out" | tail -n 1)"
expect "status: --json says the wait ended" "idle|true" \
  "$(vstat --json | jq -r '[.verdict.state, .verdict.wait_ended] | map(tostring) | join("|")')"
expect "status: the python3 fallback ends the stale wait too" idle "$(DEV_LOOP_NO_JQ=1 vstat --json | jq -r .verdict.state)"
# The ledger alone (a merge without events) ends the wait.
vreset
vlog orchestrator waiting 960 detail "gate feat/31-x"
printf '{"branch":"feat/31-x","ticket":"31","merged_at":"%s"}\n' "$(ago 720)" >"$vstate/merged.jsonl"
expect "status: a ledger merge of the waited-on branch ends the wait" "verdict: idle" "$(vverdict)"
# A gate result alone (the gate went red, nothing merged) ends the wait for that gate.
vreset
vlog orchestrator waiting 600 detail "gate feat/31-x feat/32-y"
vlog gate train-started 590 pid 999999 branches "feat/31-x feat/32-y"
vlog gate train-ended 300 rc 1 result red
expect "status: a gate result of the waited-on train ends the wait" "verdict: idle" "$(vverdict)"
# A merge or gate result of other branches, or one from before the wait, does not end it.
vreset
vlog gate train-started 900 pid 999999 branches feat/31-x
vlog gate train-ended 800 rc 0 result green
vlog orchestrator waiting 600 detail "gate feat/31-x"
vlog gate train-started 500 pid 999999 branches feat/33-z
vlog gate train-ended 400 rc 0 result green
printf '{"branch":"feat/33-z","ticket":"33","merged_at":"%s"}\n' "$(ago 300)" >"$vstate/merged.jsonl"
vverdict | grep -qE '^verdict: waiting on gate feat/31-x \(output [0-9]+s ago\)$' &&
  pass "status: only evidence of the waited-on branches, after the wait, ends it" || fail "status: unrelated evidence ended a wait"
expect "status: --json says the wait has not ended" "waiting|false" \
  "$(vstat --json | jq -r '[.verdict.state, .verdict.wait_ended] | map(tostring) | join("|")')"
# A real gate wait: the gate runs the waited-on branch, so it is waiting even after an older result.
sleep 60 &
v_gate=$!
printf '%s feat/31-x\n' "$v_gate" >"$vstate/train-running.txt"
vlog gate train-started 5 pid "$v_gate" branches feat/31-x
vverdict | grep -qE '^verdict: waiting on gate \(output [0-9]+s ago\)$' &&
  pass "status: a real gate wait (the gate runs) is still waiting" || fail "status: a running gate is not waiting"
kill "$v_gate" 2>/dev/null
wait "$v_gate" 2>/dev/null
# A wait on agents: a later orchestrator event ends the wait; the agent not yet reported is still working.
vreset
vlog orchestrator agent-started 700 ticket 41
vlog orchestrator agent-started 700 ticket 42
vlog orchestrator waiting 600 detail "agents for #41 #42"
vverdict | grep -qE '^verdict: waiting on agents for #41 #42 \(output [0-9]+s ago\)$' &&
  pass "status: a wait on agents is waiting" || fail "status: agent wait"
vlog orchestrator agent-reported 300 ticket 41
expect "status: after one report the other agent in flight is working" "verdict: working" "$(vverdict)"
vlog orchestrator agent-reported 200 ticket 42
expect "status: when every agent reported it is idle" "verdict: idle" "$(vverdict)"
# Only branch names count: punctuation around a branch is stripped; a file path or a URL never ends a wait.
vreset
vlog orchestrator waiting 600 detail "gate (feat/31-x), see docs/DECISIONS.md and https://example.invalid/a/b"
printf '{"branch":"docs/DECISIONS.md","merged_at":"%s"}\n{"branch":"https://example.invalid/a/b","merged_at":"%s"}\n' \
  "$(ago 300)" "$(ago 300)" >"$vstate/merged.jsonl"
vverdict | grep -qE '^verdict: waiting on gate \(feat/31-x\), see' &&
  pass "status: a file path or a URL in a wait's detail is not a branch" || fail "status: a path ended a wait"
printf '{"branch":"feat/31-x","merged_at":"%s"}\n' "$(ago 200)" >>"$vstate/merged.jsonl"
expect "status: a branch in parentheses in a wait's detail is matched" "verdict: idle" "$(vverdict)"

# 2. A fresh orchestrator event with nothing running and nothing in flight is idle, not working.
vreset
vevent merged detail="chore/release-0.8.1, nothing in flight"
out=$(vstat)
echo "$out"
expect "status: a fresh event with nothing running is idle" "verdict: idle" "$(echo "$out" | tail -n 1)"
# An agent recorded as started and not reported is work in flight; its report, or its merge, ends it.
vevent agent-started ticket=51
expect "status: an agent started and not reported is working" "verdict: working" "$(vverdict)"
expect "status: --json lists the agents in flight" "working|51" \
  "$(vstat --json | jq -r '[.verdict.state, (.verdict.agents | join(" "))] | join("|")')"
vstat | grep -qF 'agents in flight: #51' && pass "status: names the agents in flight" || fail "status: no agents line"
vevent agent-reported ticket=51
expect "status: a reported agent is no longer in flight" "verdict: idle" "$(vverdict)"
vevent agent-started ticket=52 branch=feat/52-m
vlog merge merged 0 branch feat/52-m ticket 52
expect "status: a merged ticket's agent is no longer in flight" "verdict: idle" "$(vverdict)"
# The ledger ends an agent too (an agent-reported never recorded): only a merge after its agent-started.
vreset
printf '{"branch":"feat/61-n","ticket":"61","merged_at":"%s"}\n' "$(ago 900)" >"$vstate/merged.jsonl"
vlog orchestrator agent-started 600 ticket 61
expect "status: a ledger merge before the agent started does not end it" "verdict: working" "$(vverdict)"
printf '{"branch":"feat/61-n","ticket":"61","merged_at":"%s"}\n' "$(ago 300)" >>"$vstate/merged.jsonl"
expect "status: a ledger merge of the agent's ticket after it started ends it" "verdict: idle" "$(vverdict)"
vreset
vlog orchestrator agent-started 600 branch feat/62-o
printf '{"branch":"feat/62-o","merged_at":"%s"}\n' "$(ago 300)" >"$vstate/merged.jsonl"
expect "status: a ledger merge of the agent's branch ends it" "verdict: idle" "$(vverdict)"
# An agent in flight with nothing moving for longer than the threshold is still possibly stalled.
vreset
vlog orchestrator agent-started 7200 ticket 53
vverdict | grep -qE '^verdict: possibly stalled: no event or output for [0-9]+ min$' &&
  pass "status: an agent that never reports is possibly stalled" || fail "status: a silent agent is not stalled"

# 3. The orchestrator's idle event is honoured: agents in flight end, an older worktree does not count.
vevent idle detail="nothing in flight"
out=$(vstat)
echo "$out"
expect "status: an idle event ends the agents in flight" "verdict: idle" "$(echo "$out" | tail -n 1)"
echo "$out" | grep -qE '^orchestrator: idle \(nothing in flight\), [0-9]+s ago$' &&
  pass "status: shows the idle event" || fail "status: idle event line"
vreset
old=$(($(date +%s) - 600))
git worktree add -q -b feat/54-left "$swork/wt-left" origin/main
(cd "$swork/wt-left" && echo l >l.txt && git add l.txt &&
  GIT_COMMITTER_DATE="$old +0000" GIT_AUTHOR_DATE="$old +0000" git commit -q -m "feat: l (Refs #54)")
expect "status: an unmerged loop worktree without an idle event is working" "verdict: working" "$(vverdict)"
vlog orchestrator idle 300 detail "after the release"
expect "status: a worktree unchanged since the idle event does not count" "verdict: idle" "$(vverdict)"
(cd "$swork/wt-left" && echo m >>l.txt && git commit -q -am "feat: m (Refs #54)")
expect "status: a worktree commit after the idle event is working" "verdict: working" "$(vverdict)"
git worktree remove --force "$swork/wt-left"
vreset

# Read-only: no file in the state directories or the lock directory changes while status runs.
snapshot() { find "$shome" "$st_home" "$swork/locks" -exec ls -ld {} + 2>/dev/null | LC_ALL=C sort | cksum; }
before=$(snapshot)
touch "$swork/marker"
sleep 1
sstatus >/dev/null
sstatus --json >/dev/null
senv "$plugin/scripts/status.sh" >/dev/null 2>&1
stat_st >/dev/null
DEV_LOOP_NO_JQ=1 sstatus --json >/dev/null
expect "status: status.sh changes no file in the state or lock directories" "$before|" \
  "$(snapshot)|$(find "$shome" "$st_home" "$swork/locks" -newer "$swork/marker" 2>/dev/null)"

# Docs: README section, the skill, CHANGELOG and decisions.
status_readme=$(awk '/^## / {on = ($0 ~ /^## Status/)} on' "$plugin/README.md")
for phrase in "status.sh" "--json" "--no-gh" "event.sh" "events.jsonl" "watchdog.stall_minutes" "possibly stalled" \
  "/dev-loop:status"; do
  printf '%s\n' "$status_readme" | grep -qF -- "$phrase" && pass "status: the README section names \"$phrase\"" ||
    fail "status: the README section does not name \"$phrase\""
done
grep -q '^name: status$' "$plugin/skills/status/SKILL.md" 2>/dev/null && grep -qF 'status.sh' "$plugin/skills/status/SKILL.md" &&
  pass "status: the status skill runs status.sh" || fail "status: no status skill"
grep -qF 'event.sh' "$plugin/skills/dev-loop/SKILL.md" && pass "status: the dev-loop skill records orchestrator events" ||
  fail "status: the dev-loop skill does not name event.sh"
grep -qF "#55" "$plugin/CHANGELOG.md" && pass "status: CHANGELOG has an entry for #55" ||
  fail "status: no CHANGELOG #55 entry"
grep -qF '(#55)' "$plugin/docs/DECISIONS.md" && pass "status: the decisions log has #55" || fail "status: no #55 decision"
grep -qF 'idle detail="nothing in flight"' "$plugin/skills/dev-loop/SKILL.md" &&
  grep -qF 'agent-reported ticket=' "$plugin/skills/dev-loop/SKILL.md" &&
  pass "status: the dev-loop skill records agent-reported and idle events" || fail "status: skill lacks agent-reported or idle"
printf '%s\n' "$status_readme" | grep -qF 'agent-reported' && printf '%s\n' "$status_readme" | grep -qF 'event.sh idle' &&
  pass "status: the README section names agent-reported and the idle event" || fail "status: README lacks the #67 events"
grep -qF "#67" "$plugin/CHANGELOG.md" && grep -qF '(#67)' "$plugin/docs/DECISIONS.md" &&
  pass "status: CHANGELOG and decisions have #67" || fail "status: no #67 entry"
# 23. Merge without a force push (#57): on an origin that refuses non-fast-forward pushes, a branch behind
# the base merges through a merge commit with the gated tree, pushed as a fast-forward of the branch; a
# re-run after a stop merges the pushed head as it is, without a second push.
mwork="$work/noforce"
git init -q --bare "$mwork/origin.git"
git -C "$mwork/origin.git" config receive.denyNonFastForwards true
git clone -q "$mwork/origin.git" "$mwork/project" 2>/dev/null
cd "$mwork/project" || exit 1
printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "true", "heavy": false}]}\n' >.dev-loop.json
echo one >src.txt
git add . && git commit -q -m "chore: start" && git push -q -u origin main
export FAKE_GH_DIR="$mwork/gh"
mbranch() { # mbranch NAME TICKET: a branch from origin/main with one file of its own and its notes, pushed; back on main
  git checkout -q -B "$1" origin/main && echo "$1" >"f-${1//\//_}.txt" && git add . &&
    git commit -q -m "feat: $1" && git push -q -u origin "$1" && git checkout -q main &&
    mkdir -p "$("$plugin/scripts/paths.sh" notes-dir)" &&
    printf 'feat: %s (#%s)\n\nCloses #%s\n' "$1" "$2" "$2" >"$("$plugin/scripts/paths.sh" notes "$1")"
}
mmove() { echo "$1" >>src.txt && git commit -q -am "chore: the base moves ($1)" && git push -q origin main; }
mmove probe-base
git push -q origin "main~1:main" 2>/dev/null && fail "noforce: the origin accepted a non-fast-forward push" ||
  pass "noforce: the test origin refuses non-fast-forward pushes"

mbranch feat/801-a 801
mbranch feat/802-b 802
mmove two
a_src=$(git rev-parse origin/feat/801-a) b_src=$(git rev-parse origin/feat/802-b)
"$plugin/scripts/gate-train.sh" feat/801-a feat/802-b >/dev/null 2>&1
expect "noforce: the train behind the base gates green" 0 "$?"
gated_tree=$(git rev-parse "train-feat/802-b^{tree}")
out=$("$plugin/scripts/merge-train.sh" feat/801-a feat/802-b 2>&1)
expect "noforce: merge-train merges green on an origin that refuses non-fast-forward pushes" 0 "$?"
git fetch -q --prune origin
expect "noforce: the base's tree is the gated tree" "$gated_tree" "$(git rev-parse 'origin/main^{tree}')"
expect "noforce: both squash commits are on the base" "feat: feat/802-b (#802)|feat: feat/801-a (#801)" \
  "$(git log --format=%s -2 origin/main | paste -sd'|')"
a_head=$(cat "$FAKE_GH_DIR/feat_801-a.head") b_head=$(cat "$FAKE_GH_DIR/feat_802-b.head")
expect "noforce: the merged head of a branch behind the base is a merge commit on the gated head" \
  "$a_src $(git rev-parse origin/main~2)" "$(git log -1 --format=%P "$a_head")"
expect "noforce: the second branch's merged head builds on its gated head and the first squash" \
  "$b_src $(git rev-parse origin/main~1)" "$(git log -1 --format=%P "$b_head")"
expect "noforce: no -vN branch or PR is created" "" \
  "$(git ls-remote origin 'refs/heads/*-v*'; find "$FAKE_GH_DIR" -name '*-v[0-9]*')"
expect "noforce: the ledger keeps the gated source head" "$a_src $a_head" \
  "$(jq -r 'select(.branch == "feat/801-a") | "\(.source_head) \(.head)"' "$DEV_LOOP_HOME/project/merged.jsonl")"
expect "noforce: the merged branches are deleted locally and on the origin" "|" \
  "$(git branch --list feat/801-a feat/802-b)|$(git ls-remote origin 'refs/heads/feat/*')"

# A stop after the push (the merge refused): the re-run merges the pushed head, no second push.
mbranch feat/803-c 803
mmove three
c_src=$(git rev-parse origin/feat/803-c)
"$plugin/scripts/gate-train.sh" feat/803-c >/dev/null 2>&1
FAKE_GH_REQUIRE_APPROVAL=1 "$plugin/scripts/merge-train.sh" feat/803-c >/dev/null 2>&1
expect "noforce: a refused merge stops with exit 7" 7 "$?"
git fetch -q origin
c_pushed=$(git rev-parse origin/feat/803-c)
expect "noforce: the stopped merge pushed a fast-forward of the gated head" "$c_src" \
  "$(git log -1 --format=%P "$c_pushed" | cut -d' ' -f1)"
GH_TOKEN=reviewer gh pr review feat/803-c --approve
FAKE_GH_REQUIRE_APPROVAL=1 "$plugin/scripts/merge-train.sh" feat/803-c >/dev/null 2>&1
expect "noforce: the re-run merges" 0 "$?"
expect "noforce: the re-run merges the head pushed before, without a second push" "$c_pushed" \
  "$(cat "$FAKE_GH_DIR/feat_803-c.head")"
expect "noforce: after the re-run the ledger keeps the gated source head" "$c_src" \
  "$(jq -r 'select(.branch == "feat/803-c") | .source_head' "$DEV_LOOP_HOME/project/merged.jsonl")"
expect "noforce: after the re-run the local branch at the gated head is deleted" "" "$(git branch --list feat/803-c)"

# A run that stopped right after its push, before recording it: the re-run finds the pushed merge commit.
mbranch feat/804-d 804
mmove four
d_src=$(git rev-parse origin/feat/804-d)
"$plugin/scripts/gate-train.sh" feat/804-d >/dev/null 2>&1
FAKE_GH_REQUIRE_APPROVAL=1 "$plugin/scripts/merge-train.sh" feat/804-d >/dev/null 2>&1
git fetch -q origin
d_pushed=$(git rev-parse origin/feat/804-d)
mtrain=$(bash -c '. "$1/scripts/lib/common.sh"; dl_load_config; dl_train_file' _ "$plugin")
awk -v s="$d_src" '{$2 = s; print}' "$mtrain" >"$mtrain.tmp" && mv "$mtrain.tmp" "$mtrain"   # field 2 not recorded yet
GH_TOKEN=reviewer gh pr review feat/804-d --approve
FAKE_GH_REQUIRE_APPROVAL=1 "$plugin/scripts/merge-train.sh" feat/804-d >/dev/null 2>&1
expect "noforce: a re-run after a stop between push and record merges, not exit 6" 0 "$?"
expect "noforce: it merges the merge commit pushed before" "$d_pushed" "$(cat "$FAKE_GH_DIR/feat_804-d.head")"

# No force push of a branch in the merge path; the docs say how it merges.
expect "noforce: no forced push in merge-train.sh or open-pr.sh" "" \
  "$(grep -nE -- '--force|push[^|]* -f( |$)|[[:space:]]\+refs/|--mirror' "$plugin/scripts/merge-train.sh" "$plugin/scripts/open-pr.sh")"
grep -qiF 'fast-forward' "$plugin/skills/merge/SKILL.md" && ! grep -qiF 'lease' "$plugin/skills/merge/SKILL.md" &&
  pass "noforce: the merge skill describes the fast-forward, no lease" || fail "noforce: merge skill text"
grep -qF "#57" "$plugin/CHANGELOG.md" && pass "noforce: CHANGELOG has an entry for #57" ||
  fail "noforce: no CHANGELOG #57 entry"
grep -qF '(#57)' "$plugin/docs/DECISIONS.md" && pass "noforce: the decisions log has #57" || fail "noforce: no #57 decision"
export FAKE_GH_DIR="$work/gh"

cd "$work/project" || exit 1

# 24. Stall watchdog (#56): the gate's per-stage stall_minutes (off by default; a stage whose log has not
# grown for that long is stopped and red, one whose log grows is not, one queued in heavy.sh for a slot is
# not stalled) and the orchestrator heartbeat in the dev-loop skill. DEV_LOOP_STALL_UNIT_SECONDS=1 makes a
# stall "minute" one second.
wwork="$work/watchdog"
git init -q --bare "$wwork/origin.git"
git clone -q "$wwork/origin.git" "$wwork/project" 2>/dev/null
cd "$wwork/project" || exit 1
printf '{"base_branch": "main", "checks": ["true"]}\n' >.dev-loop.json
echo one >src.txt
git add . && git commit -q -m "chore: start" && git push -q -u origin main
git checkout -q -b feat/9-stall
echo two >>src.txt && git commit -q -am "feat: stall (Refs #9)" && git push -q -u origin feat/9-stall
# wgate JSON_MEMBERS: gate feat/9-stall with these config members and a 1-second stall unit; sets out, rc,
# elapsed.
wgate() {
  printf '{"base_branch": "main", %s, "heavy": {"slots": 1, "poll_seconds": 1}}\n' "$1" >"$wwork/gate.json"
  rm -f "$wwork"/stall.pids "$wwork"/marker
  local start
  start=$(date +%s)
  out=$(DEV_LOOP_HOME="$wwork/home" DEV_LOOP_LOCK_DIR="$wwork/locks" DEV_LOOP_CONFIG="$wwork/gate.json" \
    DEV_LOOP_STALL_UNIT_SECONDS=1 SMOKE_WORK="$wwork" "$plugin/scripts/gate-train.sh" feat/9-stall 2>&1)
  rc=$?
  elapsed=$(($(date +%s) - start))
  echo "$out"
  echo "(gate took $elapsed s)"
}
wlines() { echo "$out" | grep -E '^[A-Za-z0-9_.-]+ (rc=[0-9]+|stopped|skipped|stalled:)' | cut -d' ' -f1-2 | paste -sd'|'; }
wevents="$wwork/home/project/events.jsonl"

# A check that prints, then sleeps beyond stall_minutes: stopped, red, with the reason; its processes gone.
wgate '"checks": [{"name": "hang", "heavy": false, "stall_minutes": 2,
  "command": "echo $$ >\"$SMOKE_WORK/stall.pids\"; echo started; sleep 60 & echo $! >>\"$SMOKE_WORK/stall.pids\"; wait"}]'
expect "stall: a silent check is red with exit 1" "1 TRAIN RED" "$rc $(echo "$out" | tail -1)"
echo "$out" | grep -q '^hang stalled: no output for 2 min (log: ' && pass "stall: the stalled check says why" ||
  fail "stall: no 'hang stalled: no output for 2 min' line"
[ "$elapsed" -lt 15 ] && pass "stall: the silent check is stopped promptly ($elapsed s)" || fail "stall: took $elapsed s"
# shellcheck disable=SC2046  # the pid list splits on purpose
expect "stall: no process of the stalled check is left" "" "$(alive $(cat "$wwork/stall.pids" 2>/dev/null))"
grep -q '"event":"stage-ended".*"stage":"hang".*"result":"stalled"' "$wevents" 2>/dev/null &&
  pass "stall: the event log records the stalled stage" || fail "stall: no stage-ended result=stalled event"

# A check whose log keeps growing for longer than stall_minutes is never stopped.
wgate '"checks": [{"name": "busy", "heavy": false, "stall_minutes": 2,
  "command": "for i in 1 2 3 4 5 6 7 8 9 10; do echo tick $i; sleep 0.5; done"}]'
expect "stall: a check whose log grows is not stopped" "0 busy rc=0 TRAIN GREEN" "$rc $(wlines) $(echo "$out" | tail -1)"

# Without stall_minutes nothing changes: a silent check runs to its end.
wgate '"checks": [{"name": "quiet", "heavy": false, "command": "echo started; sleep 4; echo done"}]'
expect "stall: without stall_minutes a silent check runs to its end" "0 quiet rc=0" "$rc $(wlines)"

# A heavy check queued in heavy.sh behind a held slot is not stalled while it waits; its clock starts with
# the slot.
DEV_LOOP_LOCK_DIR="$wwork/locks" DEV_LOOP_CONFIG="$wwork/gate.json" "$plugin/scripts/heavy.sh" sleep 6 \
  >/dev/null 2>&1 &
holder=$!
sleep 1
wgate '"checks": [{"name": "queued", "stall_minutes": 2, "command": "echo got the slot; sleep 1; echo done"}]'
wait "$holder" 2>/dev/null
expect "stall: a check queued for a slot longer than stall_minutes is not stalled" "0 queued rc=0" "$rc $(wlines)"
[ "$elapsed" -ge 4 ] && pass "stall: the queued check did wait for the slot ($elapsed s)" ||
  fail "stall: the queued check did not wait ($elapsed s)"

# A default (heavy) check that prints, then hangs: stalled once it holds its slot; nothing is left, the
# slot is free again.
wgate '"checks": [{"name": "hheavy", "stall_minutes": 2,
  "command": "echo $$ >\"$SMOKE_WORK/stall.pids\"; echo started; sleep 60 & echo $! >>\"$SMOKE_WORK/stall.pids\"; wait"}]'
expect "stall: a silent heavy check is stalled and red" "1 hheavy stalled: TRAIN RED" "$rc $(wlines) $(echo "$out" | tail -1)"
[ "$elapsed" -lt 15 ] && pass "stall: the silent heavy check is stopped promptly ($elapsed s)" ||
  fail "stall: the heavy check took $elapsed s"
# shellcheck disable=SC2046  # the pid list splits on purpose
expect "stall: no process of the stalled heavy check is left" "" "$(alive $(cat "$wwork/stall.pids" 2>/dev/null))"
DEV_LOOP_LOCK_DIR="$wwork/locks" DEV_LOOP_CONFIG="$wwork/gate.json" "$plugin/scripts/heavy.sh" \
  bash -c 'echo "slot $DEV_LOOP_SLOT"' >"$wwork/slot.out" 2>/dev/null &
slot_job=$!
for _ in $(seq 25); do kill -0 "$slot_job" 2>/dev/null || break; sleep 0.2; done
kill "$slot_job" 2>/dev/null
wait "$slot_job" 2>/dev/null
expect "stall: the stalled heavy check's slot is free again" "slot 1" "$(cat "$wwork/slot.out" 2>/dev/null)"
# heavy.sh's "acquired" line is the one the gate waits for (both use common.sh's definitions).
acquired_re=$(bash -c '. "$1/scripts/lib/common.sh"; printf "%s" "$DL_HEAVY_ACQUIRED_RE"' _ "$plugin")
DEV_LOOP_LOCK_DIR="$wwork/locks" DEV_LOOP_CONFIG="$wwork/gate.json" "$plugin/scripts/heavy.sh" true 2>&1 |
  grep -qE "$acquired_re" && [ -n "$acquired_re" ] && pass "stall: heavy.sh prints the line the gate's stall clock waits for" ||
  fail "stall: heavy.sh's acquired line does not match DL_HEAVY_ACQUIRED_RE ('$acquired_re')"

# An invalid DEV_LOOP_STALL_UNIT_SECONDS falls back to 60 with a warning; the gate still runs to its end.
for unit in abc 0; do
  printf '{"base_branch": "main", "checks": [{"name": "unit", "heavy": false, "stall_minutes": 1, "command": "echo started; sleep 3"}]}\n' \
    >"$wwork/gate.json"
  out=$(DEV_LOOP_HOME="$wwork/home" DEV_LOOP_LOCK_DIR="$wwork/locks" DEV_LOOP_CONFIG="$wwork/gate.json" \
    DEV_LOOP_STALL_UNIT_SECONDS=$unit "$plugin/scripts/gate-train.sh" feat/9-stall 2>&1)
  rc=$?
  expect "stall: DEV_LOOP_STALL_UNIT_SECONDS=$unit falls back to 60" "0 unit rc=0" "$rc $(wlines)"
  echo "$out" | grep -q "DEV_LOOP_STALL_UNIT_SECONDS \"$unit\" is not a positive whole number; using 60" &&
    pass "stall: DEV_LOOP_STALL_UNIT_SECONDS=$unit is named" || fail "stall: no warning for DEV_LOOP_STALL_UNIT_SECONDS=$unit"
done

# Sequential with fail_fast: a stalled check fails the train like a failure, the next is skipped.
wgate '"fail_fast": true, "checks": [
  {"name": "hang", "heavy": false, "stall_minutes": 1, "command": "echo started; sleep 60"},
  {"name": "next", "heavy": false, "command": "touch \"$SMOKE_WORK/marker\""}]'
expect "stall: with fail_fast the checks after a stalled one are skipped" "1 hang stalled:|next skipped no" \
  "$rc $(wlines) $([ -e "$wwork/marker" ] && echo yes || echo no)"

# Parallel: only the silent stage stalls; a growing sibling ends green; the train is red.
wgate '"parallel": true, "checks": [
  {"name": "hang", "heavy": false, "stall_minutes": 2, "command": "echo started; sleep 60"},
  {"name": "busy", "heavy": false, "stall_minutes": 2, "command": "for i in 1 2 3 4 5 6 7 8; do echo tick $i; sleep 0.5; done"}]'
expect "stall: in parallel only the silent check is stalled" "1 hang stalled:|busy rc=0" "$rc $(wlines)"
[ "$elapsed" -lt 15 ] && pass "stall: the parallel gate ends promptly ($elapsed s)" || fail "stall: parallel took $elapsed s"

# The affected stage takes stall_minutes too.
wgate '"affected": {"command": "echo started; sleep 60", "heavy": false, "stall_minutes": 1},
  "checks": [{"name": "unit", "heavy": false, "command": "true"}]'
expect "stall: a silent affected stage is stalled" "1 affected stalled:|unit rc=0" "$rc $(wlines)"

# A stall_minutes that is not a positive whole number is off, with a warning.
wgate '"checks": [{"name": "odd", "heavy": false, "stall_minutes": "soon", "command": "echo started; sleep 3"}]'
expect "stall: an invalid stall_minutes is off" "0 odd rc=0" "$rc $(wlines)"
echo "$out" | grep -q 'stall_minutes' && pass "stall: an invalid stall_minutes is named" ||
  fail "stall: no warning for an invalid stall_minutes"

# The skill text: the heartbeat, the stall handling, what it may and may not stop.
wskill=$(awk '/^## / {on = ($0 ~ /^## 2a\. /)} on' "$plugin/skills/dev-loop/SKILL.md")
for phrase in "watchdog.wake_minutes" '"watchdog": false' "status.sh --json" "event.sh" "waiting" "stalled" \
  "scheduling tool" "background command" "CPU" "log tail" "process group" "section 3a" "never" "loop's own"; do
  printf '%s\n' "$wskill" | grep -qF -- "$phrase" && pass "watchdog: the heartbeat section names \"$phrase\"" ||
    fail "watchdog: the heartbeat section does not name \"$phrase\""
done
grep -qF 'stall_minutes' "$plugin/skills/gate/SKILL.md" && pass "watchdog: the gate skill documents stall_minutes" ||
  fail "watchdog: the gate skill does not name stall_minutes"
wreadme=$(cat "$plugin/README.md")
for phrase in "watchdog.wake_minutes" '"watchdog": false' "DEV_LOOP_STALL_UNIT_SECONDS" "stalled: no output for"; do
  printf '%s\n' "$wreadme" | grep -qF -- "$phrase" && pass "watchdog: the README names \"$phrase\"" ||
    fail "watchdog: the README does not name \"$phrase\""
done
grep -qF "#56" "$plugin/CHANGELOG.md" && pass "watchdog: CHANGELOG has an entry for #56" ||
  fail "watchdog: no CHANGELOG #56 entry"
grep -qE '^## .*\(#56\)' "$plugin/docs/DECISIONS.md" && pass "watchdog: the decisions log has #56" || fail "watchdog: no #56 decision"

# 25. Marketplace pin (#64): doctor reports the marketplace source and pin in user, managed and project
# settings (fake files under $work), notes a pin older than the installed plugin, and reports MISSING with
# the exact add command when a settings entry does not match the configured marketplace. Nothing without entries.
cd "$work/project" || exit 1
mroot=$(git rev-parse --show-toplevel)
mkdir -p .claude
mdir="$DEV_LOOP_CLAUDE_DIR"
mpin() { # mpin REF: an extraKnownMarketplaces entry for the plugin, pinned to REF (none: no ref)
  if [ "$1" = none ]; then
    printf '{"extraKnownMarketplaces": {"claude-dev-loop": {"source": {"source": "github", "repo": "wentbackward/claude-dev-loop"}}}, "env": {"SECRET_LIKE": "do-not-print-me"}}\n'
  else
    printf '{"extraKnownMarketplaces": {"claude-dev-loop": {"source": {"source": "github", "repo": "wentbackward/claude-dev-loop", "ref": "%s"}}}, "env": {"SECRET_LIKE": "do-not-print-me"}}\n' "$1"
  fi
}
mknown() { # mknown REF: the marketplace as Claude Code configured it (none: no ref)
  mkdir -p "$mdir/plugins"
  if [ "$1" = none ]; then
    printf '{"claude-dev-loop": {"source": {"source": "github", "repo": "wentbackward/claude-dev-loop"}, "installLocation": "/x"}}\n'
  else
    printf '{"claude-dev-loop": {"source": {"source": "github", "repo": "wentbackward/claude-dev-loop", "ref": "%s"}, "installLocation": "/x"}}\n' "$1"
  fi >"$mdir/plugins/known_marketplaces.json"
}
minstalled() { # minstalled VERSION PROJECT: the plugin installed at project scope for PROJECT
  mkdir -p "$mdir/plugins"
  printf '{"version": 2, "plugins": {"dev-loop@claude-dev-loop": [{"scope": "project", "projectPath": "%s", "version": "%s"}]}}\n' \
    "$2" "$1" >"$mdir/plugins/installed_plugins.json"
}
mreset() { rm -rf "$mdir" "$DEV_LOOP_MANAGED_SETTINGS" .claude/settings.local.json; mkdir -p "$mdir"; }
mdoctor() { "$plugin/scripts/doctor.sh" 2>&1; }

mreset
out=$(mdoctor)
expect "marketplace: without any entries doctor prints no marketplace line" 0 "$(printf '%s\n' "$out" | grep -ci marketplace)"

mreset
mpin v0.8.0 >"$mdir/settings.json"
mknown v0.8.0
out=$(mdoctor)
printf '%s\n' "$out" | grep -qE '^ +marketplace +user settings: wentbackward/claude-dev-loop@v0.8.0 \(github\)$' &&
  pass "marketplace: doctor reports the user settings source and pin" || fail "marketplace: no user settings line in: $out"
printf '%s\n' "$out" | grep -qE '^ +marketplace +configured: wentbackward/claude-dev-loop@v0.8.0 \(github\)$' &&
  pass "marketplace: doctor reports the configured marketplace" || fail "marketplace: no configured line"
expect "marketplace: a matching pin is no problem" 0 "$(printf '%s\n' "$out" | grep -c '^MISSING marketplace')"
expect "marketplace: doctor prints no other settings content" 0 "$(printf '%s\n' "$out" | grep -c 'do-not-print-me\|SECRET_LIKE')"

mknown none
out=$(mdoctor)
expect "marketplace: a settings pin that does not match the configured marketplace is MISSING with the add command" \
  "MISSING marketplace claude-dev-loop: the user settings entry (wentbackward/claude-dev-loop@v0.8.0) does not match the configured marketplace (wentbackward/claude-dev-loop), so marketplace add fails: claude plugin marketplace add wentbackward/claude-dev-loop@v0.8.0" \
  "$(printf '%s\n' "$out" | grep '^MISSING marketplace')"
printf '%s\n' "$out" | tail -n 1 | grep -q 'problem' && pass "marketplace: a mismatch counts as a problem" ||
  fail "marketplace: a mismatch does not count"

mreset
mknown v0.8.0
mpin v0.7.0 >"$DEV_LOOP_MANAGED_SETTINGS"
out=$(mdoctor)
printf '%s\n' "$out" | grep -qE '^ +marketplace +managed settings: wentbackward/claude-dev-loop@v0.7.0 \(github\)$' &&
  pass "marketplace: doctor reports the managed settings pin" || fail "marketplace: no managed settings line"
printf '%s\n' "$out" | grep -qF 'MISSING marketplace claude-dev-loop: the managed settings entry (wentbackward/claude-dev-loop@v0.7.0)' &&
  pass "marketplace: a managed settings mismatch is MISSING" || fail "marketplace: no managed mismatch"

mreset
mknown v0.8.0
mpin v0.8.0 >.claude/settings.local.json
out=$(mdoctor)
printf '%s\n' "$out" | grep -qE '^ +marketplace +project settings \(\.claude/settings\.local\.json\): wentbackward/claude-dev-loop@v0\.8\.0 \(github\)$' &&
  pass "marketplace: doctor reports the project settings pin" || fail "marketplace: no project settings line in: $out"
rm -f .claude/settings.local.json

mreset
mpin v0.8.0 >"$mdir/settings.json"
out=$(mdoctor)
expect "marketplace: a settings entry not added yet is a note with the add command" \
  "note    marketplace claude-dev-loop is in the user settings but not added yet: claude plugin marketplace add wentbackward/claude-dev-loop@v0.8.0" \
  "$(printf '%s\n' "$out" | grep '^note    marketplace')"
expect "marketplace: not added yet is no problem" 0 "$(printf '%s\n' "$out" | grep -c '^MISSING marketplace')"

mreset
mpin v0.7.0 >"$mdir/settings.json"
mknown v0.7.0
minstalled 0.8.0 "$mroot"
out=$(mdoctor)
printf '%s\n' "$out" | grep -qE '^ +marketplace +installed: dev-loop 0\.8\.0$' &&
  pass "marketplace: doctor reports the installed plugin version" || fail "marketplace: no installed line in: $out"
expect "marketplace: a pin older than the installed plugin is a note" \
  "note    marketplace claude-dev-loop is pinned to v0.7.0, older than the installed plugin 0.8.0 (move the ref to v0.8.0, then claude plugin marketplace add wentbackward/claude-dev-loop@v0.8.0)" \
  "$(printf '%s\n' "$out" | grep '^note    marketplace' | sort -u)"
minstalled 0.7.0 "$mroot"
expect "marketplace: a pin equal to the installed plugin is no note" 0 "$(mdoctor | grep -c '^note    marketplace')"
minstalled 0.9.0 "/elsewhere/other-project"
expect "marketplace: an install for another project is not this project's version" 0 "$(mdoctor | grep -c 'installed: dev-loop')"

mreset
mpin none >"$mdir/settings.json"
mknown none
out=$(mdoctor)
printf '%s\n' "$out" | grep -qE '^ +marketplace +user settings: wentbackward/claude-dev-loop \(github\)$' &&
  pass "marketplace: an unpinned entry is reported without a ref" || fail "marketplace: no unpinned line"
expect "marketplace: an unpinned match is no problem" 0 "$(printf '%s\n' "$out" | grep -c '^MISSING marketplace')"
mreset

# Unreadable files are skipped quietly (not as root: root reads them anyway).
if [ "$(id -u)" != 0 ]; then
  mreset
  mpin v0.8.0 >"$mdir/settings.json"
  mknown v0.8.0
  minstalled 0.8.0 "$mroot"
  chmod 000 "$mdir/settings.json" "$mdir/plugins/known_marketplaces.json" "$mdir/plugins/installed_plugins.json"
  out=$(mdoctor)
  chmod 644 "$mdir/settings.json" "$mdir/plugins/known_marketplaces.json" "$mdir/plugins/installed_plugins.json"
  expect "marketplace: unreadable settings and plugin files print no error" 0 \
    "$(printf '%s\n' "$out" | grep -ci 'permission denied\|marketplace')"
fi

# A tab or newline in a source value never splits a doctor line.
mreset
printf '{"extraKnownMarketplaces": {"claude-dev-loop": {"source": {"source": "github", "repo": "wentbackward/claude-dev-loop\\nMISSING fake", "ref": "v0.8.0\\tx"}}}}\n' \
  >"$mdir/settings.json"
out=$(mdoctor)
expect "marketplace: control characters in a source are dropped" \
  "        marketplace   user settings: wentbackward/claude-dev-loopMISSING fake@v0.8.0x (github)|0" \
  "$(printf '%s\n' "$out" | grep 'marketplace   user')|$(printf '%s\n' "$out" | grep -c '^MISSING fake')"
mreset

# The docs: README install from a release tag, the error and how to move a pin; the doctor skill's table.
mversion=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$plugin/.claude-plugin/plugin.json")
minstall=$(awk '/^## / {on = ($0 == "## Install")} on' "$plugin/README.md")
for phrase in "/plugin marketplace add wentbackward/claude-dev-loop@v$mversion" "doesn't match its extraKnownMarketplaces entry" \
  '"ref"' "claude plugin update dev-loop@claude-dev-loop" "doctor"; do
  printf '%s\n' "$minstall" | grep -qF -- "$phrase" && pass "marketplace: the README install section names \"$phrase\"" ||
    fail "marketplace: the README install section does not name \"$phrase\""
done
printf '%s\n' "$minstall" | grep -qxF '/plugin marketplace add wentbackward/claude-dev-loop' &&
  fail "marketplace: the README still installs without a tag" || pass "marketplace: the README installs from a tag"
for phrase in "MISSING marketplace" "not added yet" "older than the installed plugin"; do
  grep -qF -- "$phrase" "$plugin/skills/doctor/SKILL.md" && pass "marketplace: the doctor skill explains \"$phrase\"" ||
    fail "marketplace: the doctor skill does not explain \"$phrase\""
done
grep -qF "#64" "$plugin/CHANGELOG.md" && pass "marketplace: CHANGELOG has an entry for #64" ||
  fail "marketplace: no CHANGELOG #64 entry"
grep -qE '^## .*\(#64\)' "$plugin/docs/DECISIONS.md" && pass "marketplace: the decisions log has #64" || fail "marketplace: no #64 decision"
# 25b. Script help (#75): -h / --help print the usage and exit 0 without touching anything; an unknown option
# of a script that takes branches is a usage error (exit 2), never a branch name.
git init -q --bare "$work/help-origin.git"
git clone -q "$work/help-origin.git" "$work/helpproj" 2>/dev/null
cd "$work/helpproj" || exit 1
printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "true"}]}\n' >.dev-loop.json
git add . && git commit -q -m "chore: start" && git push -q origin main
hstate="$DEV_LOOP_HOME/helpproj"
hrefs=$(git for-each-ref | git hash-object --stdin)
for hscript in gate-train merge-train repush; do
  for hflag in --help -h; do
    hout=$("$plugin/scripts/$hscript.sh" "$hflag" 2>&1)
    expect "help: $hscript.sh $hflag exits 0" 0 $?
    printf '%s\n' "$hout" | head -n 1 | grep -q "^Usage: $hscript.sh" && pass "help: $hscript.sh $hflag prints its usage" ||
      fail "help: $hscript.sh $hflag did not print its usage: $hout"
  done
done
[ ! -e "$hstate" ] && pass "help: --help writes no state (no gate worktree, no events, no logs)" ||
  fail "help: --help wrote $(find "$hstate" | head -n 5 | tr '\n' ' ')"
expect "help: --help changes no ref and no file" "$hrefs|" "$(git for-each-ref | git hash-object --stdin)|$(git status --porcelain)"
expect "help: --help adds no worktree" 1 "$(git worktree list | wc -l | tr -d ' ')"
for hscript in gate-train merge-train repush open-pr; do
  hout=$("$plugin/scripts/$hscript.sh" --bogus 2>&1)
  expect "help: $hscript.sh --bogus exits 2" 2 $?
  printf '%s\n' "$hout" | grep -q "Usage: $hscript.sh" && pass "help: $hscript.sh --bogus prints its usage" ||
    fail "help: $hscript.sh --bogus did not print its usage: $hout"
done
hout=$("$plugin/scripts/gate-train.sh" feat/x --bogus 2>&1)
expect "help: gate-train.sh refuses an unknown option after a branch" 2 $?
hout=$("$plugin/scripts/gate-train.sh" -- feat/x 2>&1)
expect "help: gate-train.sh refuses a bare --" 2 $?
printf '%s\n' "$hout" | grep -qF 'branch names never start with "-"' &&
  pass "help: a bare -- is named as no branch (branch names never start with -)" || fail "help: bare -- message: $hout"
[ ! -e "$hstate" ] && pass "help: an unknown option writes no state" || fail "help: --bogus wrote state"
for hpath in "$plugin"/scripts/*.sh; do
  hscript=$(basename "$hpath")
  hout=$("$hpath" --help 2>&1)
  hcode=$?
  [ "$hcode" -eq 0 ] && printf '%s\n' "$hout" | head -n 1 | grep -q "^Usage: $hscript" &&
    pass "help: $hscript --help prints its usage" || fail "help: $hscript --help (exit $hcode): $(printf '%s\n' "$hout" | head -n 2)"
done
[ ! -e "$hstate" ] && pass "help: no script's --help writes state" || fail "help: a script's --help wrote $(ls "$hstate")"
expect "help: no script's --help changes the repository" "$hrefs|" "$(git for-each-ref | git hash-object --stdin)|$(git status --porcelain)"
# heavy.sh and as-role.sh pass -h / --help on to their command when it is not the first argument (#76).
for hflag in -h --help; do
  expect "help: heavy.sh passes a later $hflag to its command" "$hflag" \
    "$("$plugin/scripts/heavy.sh" printf '%s\n' "$hflag" 2>/dev/null)"
  expect "help: as-role.sh passes a later $hflag to its command" "$hflag" \
    "$("$plugin/scripts/as-role.sh" implementer printf '%s\n' "$hflag" 2>/dev/null)"
done
grep -qF "#75" "$plugin/CHANGELOG.md" && pass "help: CHANGELOG has an entry for #75" || fail "help: no CHANGELOG #75 entry"
# tests/smoke.sh runs chosen sections (#76): the shared setup, the sections they need, in a new work dir.
hsmoke="$plugin/tests/smoke.sh"
hout=$("$hsmoke" --help 2>&1)
expect "smoke: --help exits 0" 0 $?
printf '%s\n' "$hout" | head -n 1 | grep -q '^Usage: tests/smoke.sh' && pass "smoke: --help prints the usage" ||
  fail "smoke: --help did not print the usage: $hout"
hout=$("$hsmoke" --list 2>&1)
expect "smoke: --list exits 0" 0 $?
expect "smoke: --list names sections 1, 11, 20 and 25b" "1|11|20|25b" \
  "$(printf '%s\n' "$hout" | awk '$1 == "1" || $1 == "11" || $1 == "20" || $1 == "25b" {print $1}' | paste -sd'|' -)"
"$hsmoke" --section nope >/dev/null 2>&1
expect "smoke: an unknown section is a usage error" 2 $?
"$hsmoke" --section >/dev/null 2>&1
expect "smoke: --section without a name is a usage error" 2 $?
"$hsmoke" --bogus >/dev/null 2>&1
expect "smoke: an unknown option is a usage error" 2 $?
mkdir -p "$work/nested"
hout=$(cd "$work/nested" && env -u DEV_LOOP_CONFIG TMPDIR="$work/nested" "$hsmoke" --section 2 2>&1)
expect "smoke: --section 2 passes" 0 $?
printf '%s\n' "$hout" | grep -qxF 'PASS format hook without config exits 0' &&
  printf '%s\n' "$hout" | grep -qxF 'PASS stop gate passes on a clean tree with a green fast check' &&
  pass "smoke: --section 2 runs section 2 and the section it needs (1)" || fail "smoke: --section 2 output: $hout"
printf '%s\n' "$hout" | grep -qF 'heavy.sh exports the slot port' && fail "smoke: --section 2 ran section 3" ||
  pass "smoke: --section 2 runs no later section"
printf '%s\n' "$hout" | head -n 1 | grep -qF "started smoke (work dir $work/nested/dev-loop-smoke." &&
  pass "smoke: a section run has its own work dir under TMPDIR" || fail "smoke: section run work dir: $(printf '%s\n' "$hout" | head -n 1)"
expect "smoke: a green section run removes its work dir" "(work dir removed) " \
  "$(printf '%s\n' "$hout" | tail -n 1 | grep -oF '(work dir removed)') $(cd "$work/nested" && for d in dev-loop-smoke.*; do [ -e "$d" ] && echo "$d"; done)"
hout=$(cd "$work/nested" && env -u DEV_LOOP_CONFIG TMPDIR="$work/nested" "$hsmoke" --section 'Hooks without config' 2>&1)
expect "smoke: a section chosen by name passes" 0 $?
printf '%s\n' "$hout" | grep -qxF 'PASS format hook without config exits 0' &&
  ! printf '%s\n' "$hout" | grep -qF 'stop gate passes on a clean tree' &&
  pass "smoke: a name selects the section whose comments contain it" || fail "smoke: --section by name output: $hout"

# 26. Worktrees dir (#70): "worktrees_dir" puts the implementer worktrees in <dir>/<n> and the gate in
# <dir>/gate, one directory permissions.sh lists in permissions.additionalDirectories (auto mode edits
# there without a prompt); doctor reports an uncovered one. Without the key nothing changes.
wwork="$work/wtd"
git init -q --bare "$wwork/origin.git"
git clone -q "$wwork/origin.git" "$wwork/project" 2>/dev/null
cd "$wwork/project" || exit 1
printf '# Project\n' >"$wwork/project/CLAUDE.md"
printf '{"base_branch": "main", "checks": [{"name": "unit", "command": "true", "heavy": false}]}\n' >"$wwork/plain.json"
printf '{"base_branch": "main", "checks": ["true"], "worktrees_dir": "../project-worktrees/"}\n' >"$wwork/wtd.json"
printf '{"base_branch": "main", "checks": ["true"], "worktrees_dir": "../project-worktrees", "gate_worktree": "../elsewhere-gate"}\n' \
  >"$wwork/wtd-gate.json"
printf '{"base_branch": "main", "checks": ["true"], "worktrees_dir": ".."}\n' >"$wwork/wtd-parent.json"
git -C "$wwork/project" add . && git -C "$wwork/project" commit -q -m "chore: start" &&
  git -C "$wwork/project" push -q -u origin main
wroot=$("$plugin/scripts/paths.sh" root)
wparent=$(dirname "$wroot")
wdir="$wparent/project-worktrees"
wnotes="$wwork/home/project/notes"
# Every settings file this section writes or removes is under the throwaway project, by absolute path.
wclaude="$wwork/project/.claude"
# wenv CONFIG COMMAND...: run COMMAND in the project with the config CONFIG and the section's own state.
wenv() { local c=$1; shift; (cd "$wwork/project" && DEV_LOOP_HOME="$wwork/home" DEV_LOOP_CONFIG="$wwork/$c.json" "$@" 2>&1); }
wpaths() { local c=$1; shift; wenv "$c" "$plugin/scripts/paths.sh" "$@"; }

# paths.sh: the old layout without the key, the worktrees dir with it; an explicit gate_worktree wins.
expect "wtd: without worktrees_dir paths.sh worktree 12 is the sibling <parent>/<repo>-12" "$wparent/project-12" \
  "$(wpaths plain worktree 12)"
expect "wtd: without worktrees_dir paths.sh gate is unchanged" "$wroot/../project-gate" "$(wpaths plain gate)"
expect "wtd: without worktrees_dir paths.sh worktrees is the project's parent (the sibling layout)" "$wparent" \
  "$(wpaths plain worktrees)"
expect "wtd: with worktrees_dir paths.sh worktree 12 is <dir>/12" "$wdir/12" "$(wpaths wtd worktree 12)"
expect "wtd: with worktrees_dir paths.sh gate is <dir>/gate" "$wdir/gate" "$(wpaths wtd gate)"
expect "wtd: with worktrees_dir paths.sh worktrees is the absolute dir" "$wdir" "$(wpaths wtd worktrees)"
expect "wtd: an explicit gate_worktree still wins" "$wroot/../elsewhere-gate" "$(wpaths wtd-gate gate)"
wpaths wtd worktree >/dev/null && fail "wtd: paths.sh worktree without a number succeeded" ||
  pass "wtd: paths.sh worktree without a number is a usage error"
wpaths wtd worktree x1 >/dev/null && fail "wtd: paths.sh worktree accepted a non-number" ||
  pass "wtd: paths.sh worktree refuses a non-number"
printf '{"base_branch": "main", "checks": ["true"], "worktrees_dir": "%s/abs-wt"}\n' "$wwork" >"$wwork/wtd-abs.json"
expect "wtd: an absolute worktrees_dir is used as it is" "$wwork/abs-wt/7" "$(wpaths wtd-abs worktree 7)"

# permissions.sh: the dry run lists the additionalDirectories entry, --apply writes it into the local
# settings (absolute, per machine), keeps every other key and rule, and a second run adds nothing.
wperm() { local c=$1; shift; wenv "$c" "$plugin/scripts/permissions.sh" "$@"; }
wdirs() { # wdirs FILE: the additionalDirectories of FILE, space separated
  bash -c '. "$1/scripts/lib/common.sh" && . "$1/scripts/lib/permissions.sh" && dl_perm_rules "$2" additionalDirectories' _ \
    "$plugin" "$1" | paste -sd' ' -
}
expect "wtd: without worktrees_dir permissions.sh adds only the notes dir to additionalDirectories" \
  ".claude/settings.local.json: + additionalDirectories $wnotes" "$(wperm plain | grep additionalDirectories)"
mkdir -p "$wclaude"
printf '{"model": "custom", "permissions": {"allow": ["Bash(ls *)"], "additionalDirectories": ["%s/docs-elsewhere"]}, "env": {"A": "1"}}\n' \
  "$wwork" >"$wwork/local-before.json"
for nojq in "" 1; do
  label=${nojq:+ (python3)}
  rm -f "$wclaude/settings.json"
  cp "$wwork/local-before.json" "$wclaude/settings.local.json"
  out=$(DEV_LOOP_NO_JQ=$nojq wperm wtd)
  cmp -s "$wclaude/settings.local.json" "$wwork/local-before.json" && pass "wtd: the dry run changes nothing$label" ||
    fail "wtd: the dry run changed the local settings$label"
  expect "wtd: the dry run lists the notes dir and the worktrees dir once, not the gate inside it$label" \
    ".claude/settings.local.json: + additionalDirectories $wnotes|.claude/settings.local.json: + additionalDirectories $wdir" \
    "$(printf '%s\n' "$out" | grep additionalDirectories | paste -sd'|' -)"
  DEV_LOOP_NO_JQ=$nojq wperm wtd --apply >/dev/null
  expect "wtd: --apply appends the absolute notes and worktrees dirs after the existing entry$label" \
    "$wwork/docs-elsewhere $wnotes $wdir" \
    "$(wdirs "$wclaude/settings.local.json")"
  expect "wtd: --apply keeps the other keys and rules$label" "custom 1 Bash(ls *)" \
    "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["model"], d["env"]["A"], d["permissions"]["allow"][0])' "$wclaude/settings.local.json")"
  expect "wtd: the shared settings get no machine path$label" "" "$(grep -F "$wwork" "$wclaude/settings.json")"
  expect "wtd: a second run adds nothing$label" "permissions: complete" "$(DEV_LOOP_NO_JQ=$nojq wperm wtd --apply | tail -n 1)"
done
out=$(wperm wtd-gate)
expect "wtd: a gate_worktree outside the worktrees dir is listed too" \
  ".claude/settings.local.json: + additionalDirectories $wparent/elsewhere-gate" "$(printf '%s\n' "$out" | grep additionalDirectories)"
cp "$wwork/local-before.json" "$wclaude/settings.local.json"
printf '{"permissions": {"additionalDirectories": ["%s"]}}\n' "$wparent/project-worktrees/" >"$wclaude/settings.json"
expect "wtd: an entry in the shared settings (trailing slash) already covers the dir" \
  ".claude/settings.local.json: + additionalDirectories $wnotes" "$(wperm wtd | grep additionalDirectories)"
rm "$wclaude/settings.json"
out=$(wperm wtd-parent --apply)
expect "wtd: the project's parent directory is never added" "$wwork/docs-elsewhere $wnotes" "$(wdirs "$wclaude/settings.local.json")"
printf '%s\n' "$out" | grep -q "worktrees_dir.*holds the project" && pass "wtd: permissions.sh warns about a worktrees_dir that holds the project" ||
  fail "wtd: no warning for a worktrees_dir that holds the project ($out)"

# doctor: MISSING for an uncovered worktrees dir, quiet once covered, a note for old-layout siblings,
# MISSING for uncovered sibling loop worktrees without the key; the worktrees are never moved.
wdoctor() { wenv "$1" "$plugin/scripts/doctor.sh"; }
cp "$wwork/local-before.json" "$wclaude/settings.local.json"
expect "wtd: without worktrees_dir and without sibling worktrees doctor prints nothing about worktrees" "" \
  "$(wdoctor plain | grep -i 'worktrees')"
out=$(wdoctor wtd)
printf '%s\n' "$out" | grep -qF "MISSING worktrees: $wdir is outside the working directory and not in permissions.additionalDirectories" &&
  printf '%s\n' "$out" | grep -qF "permissions.sh --apply" && pass "wtd: doctor reports an uncovered worktrees dir as MISSING with the fix" ||
  fail "wtd: no MISSING for an uncovered worktrees dir ($out)"
wperm wtd --apply >/dev/null
out=$(wdoctor wtd)
expect "wtd: doctor is quiet once the worktrees dir is covered" "" "$(printf '%s\n' "$out" | grep -E '^(MISSING|note) +worktrees')"
printf '%s\n' "$out" | grep -qE "^ +worktrees +$wdir\$" && pass "wtd: doctor prints the worktrees dir" ||
  fail "wtd: doctor does not print the worktrees dir"
git -C "$wwork/project" worktree add -q "$wparent/project-31" -b feat/31-old origin/main
out=$(wdoctor wtd)
printf '%s\n' "$out" | grep -qE '^note    worktrees: 1 loop worktrees? of the old layout' &&
  pass "wtd: doctor notes a sibling worktree of the old layout" || fail "wtd: no note for an old-layout worktree ($out)"
[ -d "$wparent/project-31" ] && pass "wtd: doctor leaves the old worktree where it is" || fail "wtd: the old worktree moved"
rm "$wclaude/settings.local.json"
out=$(wdoctor plain)
printf '%s\n' "$out" | grep -qF 'MISSING worktrees: 1 loop worktrees outside the working directory' &&
  printf '%s\n' "$out" | grep -qF '"worktrees_dir"' && pass "wtd: without the key doctor reports uncovered sibling worktrees with the fix" ||
  fail "wtd: no MISSING for uncovered sibling worktrees ($out)"
printf '{"permissions": {"additionalDirectories": ["%s"]}}\n' "$wparent/project-31" >"$wclaude/settings.local.json"
expect "wtd: a sibling worktree covered by additionalDirectories is fine" "" "$(wdoctor plain | grep -i 'worktrees')"
out=$(wdoctor wtd-parent)
printf '%s\n' "$out" | grep -qF 'MISSING worktrees_dir: ' && pass "wtd: doctor reports a worktrees_dir that holds the project" ||
  fail "wtd: no MISSING for a worktrees_dir that holds the project"
git -C "$wwork/project" worktree remove "$wparent/project-31" && git -C "$wwork/project" branch -q -D feat/31-old

# The notes dir: implementers write their notes file there with the Write tool, so it is listed too, with or
# without worktrees_dir; doctor reports it MISSING while uncovered; a notes_dir inside the project needs nothing.
rm -f "$wclaude/settings.json" "$wclaude/settings.local.json"
out=$(wdoctor plain)
printf '%s\n' "$out" | grep -qF "MISSING notes: $wnotes is outside the working directory and not in additionalDirectories" &&
  printf '%s\n' "$out" | grep -qF 'permissions.sh --apply' && pass "wtd: doctor reports an uncovered notes dir as MISSING with the fix" ||
  fail "wtd: no MISSING for an uncovered notes dir ($out)"
wperm plain --apply >/dev/null
expect "wtd: --apply lists the notes dir without worktrees_dir" "$wnotes" "$(wdirs "$wclaude/settings.local.json")"
expect "wtd: doctor is quiet once the notes dir is covered" "" "$(wdoctor plain | grep '^MISSING notes')"
printf '{"base_branch": "main", "checks": ["true"], "notes_dir": "notes"}\n' >"$wwork/notes-inside.json"
rm "$wclaude/settings.local.json"
expect "wtd: a notes_dir inside the project is not added" "" "$(wperm notes-inside | grep additionalDirectories)"
expect "wtd: a notes_dir inside the project is not reported" "" "$(wdoctor notes-inside | grep '^MISSING notes')"

# Status, cleanup and merge-train (dl_worktree_of) find a worktree of the new layout.
wt12=$(wpaths wtd worktree 12)
git -C "$wwork/project" worktree add -q "$wt12" -b feat/12-new origin/main
[ -d "$wdir/12" ] && pass "wtd: git worktree add creates the worktrees dir" || fail "wtd: no worktree at $wdir/12"
wenv wtd "$plugin/scripts/status.sh" --no-gh | grep -qF "feat/12-new #12: " && pass "wtd: status lists a worktree of the new layout" ||
  fail "wtd: status does not list the new-layout worktree"
wenv wtd "$plugin/scripts/cleanup.sh" >/dev/null
wreport=$(find "$wwork/home/project/logs" -name 'cleanup-*.tsv' 2>/dev/null | head -n 1)
grep -qF "checked out in $wt12" "$wreport" 2>/dev/null && pass "wtd: cleanup keeps a branch checked out in the new layout" ||
  fail "wtd: cleanup did not find the new-layout worktree"
expect "wtd: dl_worktree_of (merge-train) finds the new-layout worktree" "$wt12" \
  "$(cd "$wwork/project" && DEV_LOOP_CONFIG="$wwork/wtd.json" common_fn dl_worktree_of feat/12-new)"
git -C "$wwork/project" worktree remove "$wt12"

# The docs: README config table, the dev-loop skill's launch step, setup, the doctor skill and the changelog.
grep -qE '^\| `worktrees_dir` \|' "$plugin/README.md" && pass "wtd: the README config table has worktrees_dir" ||
  fail "wtd: no worktrees_dir row in the README"
wlaunch=$(awk '/^## / { on = ($0 ~ /^## 3\. /) } on' "$plugin/skills/dev-loop/SKILL.md")
printf '%s\n' "$wlaunch" | grep -qF 'paths.sh worktree <n>' && pass "wtd: the launch step uses paths.sh worktree <n>" ||
  fail "wtd: the launch step does not use paths.sh worktree <n>"
printf '%s\n' "$wlaunch" | grep -qF '../<repo-name>-<n>' && fail "wtd: the launch step still hard-codes ../<repo-name>-<n>" ||
  pass "wtd: the launch step hard-codes no sibling path"
grep -qF '"worktrees_dir": "../<repo>-worktrees"' "$plugin/skills/setup/SKILL.md" &&
  grep -qF 'additionalDirectories' "$plugin/skills/setup/SKILL.md" && pass "wtd: the setup skill writes worktrees_dir" ||
  fail "wtd: the setup skill does not write worktrees_dir"
grep -qF 'MISSING worktrees:' "$plugin/skills/doctor/SKILL.md" && pass "wtd: the doctor skill has a row for the worktrees lines" ||
  fail "wtd: no doctor skill row for worktrees"
awk '/^## / { n++ } n == 1' "$plugin/CHANGELOG.md" | grep -qF '#70' && head -n 8 "$plugin/CHANGELOG.md" | grep -q '^## Unreleased' &&
  pass "wtd: CHANGELOG has a #70 entry under Unreleased" || fail "wtd: no #70 entry under ## Unreleased"
# 27. Owner steps (#73): permissions.sh's dry run ends with the one command the owner runs to apply it (the
# agent never edits its own permission settings); doctor reports a deny rule in the project's settings that
# blocks a tag, a release or a tag push as MISSING, with the fix: move it to ask. Quiet with the template.
owork="$work/owner"
git init -q --bare "$owork/origin.git"
git clone -q "$owork/origin.git" "$owork/project" 2>/dev/null
cd "$owork/project" || exit 1
printf '# Project\n' >"$owork/project/CLAUDE.md"
printf '{"base_branch": "main", "fast_check": "make lint", "checks": ["make check"]}\n' >"$owork/config.json"
git -C "$owork/project" add . && git -C "$owork/project" commit -q -m "chore: start" &&
  git -C "$owork/project" push -q -u origin main
# Every settings file this section writes or removes is under the throwaway project, by absolute path.
oclaude="$owork/project/.claude"
mkdir -p "$owork/home/.claude"
# A user-level deny on tags: doctor must never read it.
printf '{"permissions": {"deny": ["Bash(git tag:*)"]}}\n' >"$owork/home/.claude/settings.json"
# oenv COMMAND...: run COMMAND in the project with the section's config, state and home.
oenv() { (cd "$owork/project" && HOME="$owork/home" DEV_LOOP_HOME="$owork/state" DEV_LOOP_CONFIG="$owork/config.json" "$@" 2>&1); }
oapply="! $plugin/scripts/permissions.sh --apply"
for nojq in "" 1; do
  label=${nojq:+ (python3)}
  rm -f "$oclaude/settings.json" "$oclaude/settings.local.json"
  out=$(DEV_LOOP_NO_JQ=$nojq oenv "$plugin/scripts/permissions.sh")
  printf '%s\n' "$out" | tail -n 1 | grep -qF -- "$oapply" &&
    pass "owner: the dry run ends with the owner's apply command$label" ||
    fail "owner: the dry run does not end with \"$oapply\"$label ($(printf '%s\n' "$out" | tail -n 1))"
  printf '%s\n' "$out" | tail -n 1 | grep -q '\-\-apply$' && pass "owner: the apply command is the end of the line$label" ||
    fail "owner: the dry run's last line does not end with --apply$label"
  [ ! -e "$oclaude/settings.json" ] && pass "owner: the dry run writes nothing$label" || fail "owner: the dry run wrote settings$label"
  out=$(DEV_LOOP_NO_JQ=$nojq oenv "$plugin/scripts/permissions.sh" --apply)
  printf '%s\n' "$out" | grep -qF -- "$oapply" && fail "owner: --apply prints the apply command$label" ||
    pass "owner: --apply does not print the apply command$label"
  out=$(DEV_LOOP_NO_JQ=$nojq oenv "$plugin/scripts/permissions.sh")
  expect "owner: with nothing missing the dry run prints only complete$label" "permissions: complete" "$out"
done

# Doctor: quiet with the template's ask rules (and the user's own deny on tags is never read).
odoctor() { DEV_LOOP_NO_JQ=${1:-} oenv "$plugin/scripts/doctor.sh"; }
clean_verdict=$(odoctor | tail -n 1)
expect "owner: doctor is quiet about releases with the template's rules" "" "$(odoctor | grep -i 'release')"
cp "$oclaude/settings.json" "$owork/shared-full.json"
cp "$oclaude/settings.local.json" "$owork/local-full.json"
# oadd_deny FILE RULE: append RULE to permissions.deny of FILE.
oadd_deny() {
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d.setdefault("permissions", {}).setdefault("deny", []).append(sys.argv[2]); json.dump(d, open(sys.argv[1], "w"))' \
    "$1" "$2"
}
for nojq in "" 1; do
  label=${nojq:+ (python3)}
  for rule in "Bash(git tag:*)" "Bash(git tag *)" "Bash(*gh release *)" "Bash(*git*push*--tags*)" \
    "Bash(git push --tags:*)" "Bash(git push --tags)" "Bash(git push --tags origin)" "Bash(git push --follow-tags:*)" \
    "Bash(*--follow-tags*)" "Bash(git push origin refs/tags/*)" "Bash(git push origin tag *)" "Bash(git tag -s:*)" \
    "Bash(git tag -m:*)"; do
    cp "$owork/shared-full.json" "$oclaude/settings.json"
    oadd_deny "$oclaude/settings.json" "$rule"
    out=$(odoctor "$nojq")
    printf '%s\n' "$out" | grep -F "MISSING permissions: deny rule $rule in .claude/settings.json blocks" | grep -qF 'move it to ask' &&
      pass "owner: doctor reports deny $rule as MISSING with the fix$label" ||
      fail "owner: no MISSING with the fix for deny $rule$label ($out)"
  done
  # A broad deny that also blocks a loop command is reported once, by the loop-command check.
  cp "$owork/shared-full.json" "$oclaude/settings.json"
  oadd_deny "$oclaude/settings.json" "Bash(git push:*)"
  out=$(odoctor "$nojq")
  expect "owner: a deny on all pushes is reported once$label" "1" \
    "$(printf '%s\n' "$out" | grep -cF 'deny rule Bash(git push:*) in .claude/settings.json')"
  printf '%s\n' "$out" | grep -F 'deny rule Bash(git push:*) in .claude/settings.json' | grep -qF 'a command the loop runs' &&
    pass "owner: the one report of a deny on all pushes is the loop-command one$label" ||
    fail "owner: a deny on all pushes is not reported as blocking a loop command$label ($out)"
  cp "$owork/shared-full.json" "$oclaude/settings.json"
  oadd_deny "$oclaude/settings.local.json" "Bash(git push origin v*)"
  out=$(odoctor "$nojq")
  printf '%s\n' "$out" | grep -F 'MISSING permissions: deny rule Bash(git push origin v*) in .claude/settings.local.json blocks' |
    grep -qF 'move it to ask' && pass "owner: doctor reports deny git push origin v* in the local file$label" ||
    fail "owner: no MISSING for deny git push origin v* in the local file$label ($out)"
  [ "$(printf '%s\n' "$out" | tail -n 1)" != "$clean_verdict" ] && pass "owner: a deny on tag pushes adds a problem$label" ||
    fail "owner: a deny on tag pushes left the verdict unchanged$label"
  cp "$owork/local-full.json" "$oclaude/settings.local.json"
done
# Only the local file, no shared settings: the deny is still found.
rm -f "$oclaude/settings.json"
printf '{"permissions": {"deny": ["Bash(git tag:*)"]}}\n' >"$oclaude/settings.local.json"
odoctor | grep -qF 'MISSING permissions: deny rule Bash(git tag:*) in .claude/settings.local.json blocks' &&
  pass "owner: a tag deny in the local file is reported without a shared settings file" ||
  fail "owner: no MISSING for a tag deny in the local file alone"
# An ask on tags (the template's) and an unrelated deny are not reported.
printf '{"permissions": {"ask": ["Bash(git tag:*)"], "deny": ["Bash(curl *)"]}}\n' >"$oclaude/settings.local.json"
expect "owner: an ask on tags and an unrelated deny are not reported" "" "$(odoctor | grep 'MISSING permissions')"
rm -f "$oclaude/settings.local.json"

# Doctor's notes on missing or empty permission settings name the owner's apply line, never a bare --apply.
rm -f "$oclaude/settings.json" "$oclaude/settings.local.json"
odoctor | grep -F 'permissions: no .claude/settings.json' | grep -qF -- "$oapply" &&
  pass "owner: the no-settings note names the owner's apply line" || fail "owner: the no-settings note lacks \"$oapply\""
printf '{}\n' >"$oclaude/settings.json"
odoctor | grep -F 'permissions: no allow list' | grep -qF -- "$oapply" &&
  pass "owner: the no-allow-list note names the owner's apply line" || fail "owner: the no-allow-list note lacks \"$oapply\""
expect "owner: no doctor note says the setup skill runs --apply" "" "$(odoctor | grep -F 'permissions step')"
rm -f "$oclaude/settings.json"
# A plugin path with a space: the printed apply line quotes the path and still ends with --apply.
mkdir -p "$owork/sp ace"
cp -R "$plugin/scripts" "$plugin/templates" "$owork/sp ace/"
out=$(oenv "$owork/sp ace/scripts/permissions.sh" | tail -n 1)
ospace="! $(printf '%q' "$owork/sp ace/scripts/permissions.sh") --apply"
printf '%s\n' "$out" | grep -qF -- "$ospace" && printf '%s\n' "$out" | grep -q '\-\-apply$' &&
  pass "owner: the apply line quotes a plugin path with a space" || fail "owner: the apply line does not quote the path ($out)"

# The docs: setup and doctor skills, README, CHANGELOG and decisions.
osetup=$(awk '/^4\. \*\*Permissions\*\*/ { on = 1 } /^5\. / { on = 0 } on' "$plugin/skills/setup/SKILL.md")
printf '%s\n' "$osetup" | grep -qF '! ${CLAUDE_PLUGIN_ROOT}/scripts/permissions.sh --apply' &&
  pass "owner: the setup Permissions step shows the owner's ! apply line" || fail "owner: setup does not show the ! apply line"
printf '%s\n' "$osetup" | grep -qiF 'never edit' && pass "owner: the setup step says the agent never edits the settings itself" ||
  fail "owner: setup does not forbid editing the settings"
grep -qiF 'another public repository' "$plugin/skills/setup/SKILL.md" &&
  pass "owner: the setup skill makes pushes to another public repository an owner step" ||
  fail "owner: setup does not name pushes to another public repository"
grep -qF 'move it to `ask`' "$plugin/skills/doctor/SKILL.md" && grep -qF '! ${CLAUDE_PLUGIN_ROOT}/scripts/permissions.sh --apply' \
  "$plugin/skills/doctor/SKILL.md" && pass "owner: the doctor skill has the tag-deny row and the owner's apply line" ||
  fail "owner: the doctor skill lacks the tag-deny row or the apply line"
awk '/^## Permission modes/ {on = 1; next} /^## / {on = 0} on' "$plugin/README.md" | grep -qF '! ${CLAUDE_PLUGIN_ROOT}/scripts/permissions.sh --apply' &&
  pass "owner: the README permissions section shows the owner's apply line" || fail "owner: the README lacks the apply line"
awk '/^## / { n++ } n == 1' "$plugin/CHANGELOG.md" | grep -qF '#73' && pass "owner: CHANGELOG has a #73 entry under Unreleased" ||
  fail "owner: no #73 entry under ## Unreleased"
grep -qF '(#73)' "$plugin/docs/DECISIONS.md" && pass "owner: the decisions log has a #73 entry" || fail "owner: no #73 decision"
cd "$work/project" || exit 1

# 27. Forced failure (#80): red only when DEV_LOOP_SMOKE_FORCE_FAIL=1, so section 27b can run a red suite.
expect "work dirs: the forced failure is off" "" "${DEV_LOOP_SMOKE_FORCE_FAIL:-}"

# 27b. Test work dirs (#80): a green suite removes its work dir, a red one or DEV_LOOP_KEEP_WORK=1 keeps it
# and names it; removal touches only the suite's own mktemp dir in TMPDIR; the gate keeps the newest red
# work dir of each suite named by its logs and removes the older ones, nothing else.
kwork="$work/workdirs"
ktmp="$kwork/tmp"
mkdir -p "$ktmp/other-dir" "$kwork/elsewhere/dev-loop-smoke.abc123" "$kwork/target" "$ktmp/sub/dev-loop-smoke.abc123"
echo keep >"$ktmp/other.txt"
echo keep >"$ktmp/other-dir/file"
echo keep >"$kwork/target/file"
ln -s "$kwork/target" "$ktmp/dev-loop-smoke.link12"
mkdir "$ktmp/dev-loop-smoke.abc123" "$ktmp/dev-loop-identity.abc123" "$ktmp/dev-loop-smoke.x" "$ktmp/not-a-suite.abc123"
# kremove PATH PREFIX: dl_remove_work_dir with TMPDIR=$ktmp; prints its exit status.
kremove() { (TMPDIR="$ktmp" && . "$plugin/scripts/lib/workdirs.sh" && dl_remove_work_dir "$1" "$2"; echo $?); }
expect "work dirs: a path not under TMPDIR is refused" 1 "$(kremove "$kwork/elsewhere/dev-loop-smoke.abc123" dev-loop-smoke)"
[ -d "$kwork/elsewhere/dev-loop-smoke.abc123" ] && pass "work dirs: the dir outside TMPDIR stays" || fail "work dirs: removed a dir outside TMPDIR"
expect "work dirs: a dir in a subdirectory of TMPDIR is refused" 1 "$(kremove "$ktmp/sub/dev-loop-smoke.abc123" dev-loop-smoke)"
expect "work dirs: a symlink is refused" 1 "$(kremove "$ktmp/dev-loop-smoke.link12" dev-loop-smoke)"
[ -L "$ktmp/dev-loop-smoke.link12" ] && [ -f "$kwork/target/file" ] && pass "work dirs: the symlink and its target stay" ||
  fail "work dirs: the symlink or its target went"
expect "work dirs: another suite's prefix is refused" 1 "$(kremove "$ktmp/dev-loop-identity.abc123" dev-loop-smoke)"
expect "work dirs: an unknown prefix is refused" 1 "$(kremove "$ktmp/not-a-suite.abc123" not-a-suite)"
expect "work dirs: a name that is not PREFIX.XXXXXX is refused" 1 "$(kremove "$ktmp/dev-loop-smoke.x" dev-loop-smoke)"
expect "work dirs: TMPDIR itself is refused" 1 "$(kremove "$ktmp" dev-loop-smoke)"
expect "work dirs: a path ending in /.. is refused" 1 "$(kremove "$ktmp/dev-loop-smoke.abc123/.." dev-loop-smoke)"
# A symlink in TMPDIR that points out of it: `..` after it and a dir under it are both outside TMPDIR on disk.
mkdir -p "$kwork/outside/inner" "$kwork/outside/dev-loop-smoke.abc123" "$kwork/outside/inner/dev-loop-smoke.abc123"
ln -s "$kwork/outside/inner" "$ktmp/link"
expect "work dirs: a path through a symlink and .. is refused" 1 "$(kremove "$ktmp/link/../dev-loop-smoke.abc123" dev-loop-smoke)"
[ -d "$kwork/outside/dev-loop-smoke.abc123" ] && pass "work dirs: the dir outside TMPDIR behind symlink/.. stays" ||
  fail "work dirs: removed a dir outside TMPDIR through symlink/.."
expect "work dirs: a dir whose parent is a symlink out of TMPDIR is refused" 1 "$(kremove "$ktmp/link/dev-loop-smoke.abc123" dev-loop-smoke)"
[ -d "$kwork/outside/inner/dev-loop-smoke.abc123" ] && pass "work dirs: the dir behind a symlinked parent stays" ||
  fail "work dirs: removed a dir behind a symlinked parent"
expect "work dirs: a path with a . component is refused" 1 "$(kremove "$ktmp/./dev-loop-identity.abc123" dev-loop-identity)"
[ -d "$ktmp/dev-loop-identity.abc123" ] && pass "work dirs: the dir named through . stays" || fail "work dirs: removed a dir named through ."
rm "$ktmp/link"
expect "work dirs: an empty path is refused" 1 "$(kremove "" dev-loop-smoke)"
expect "work dirs: a missing dir is refused" 1 "$(kremove "$ktmp/dev-loop-smoke.zzz999" dev-loop-smoke)"
expect "work dirs: the suite's own dir is removed" 0 "$(kremove "$ktmp/dev-loop-smoke.abc123" dev-loop-smoke)"
[ ! -e "$ktmp/dev-loop-smoke.abc123" ] && pass "work dirs: the suite's own dir is gone" || fail "work dirs: the dir is still there"
expect "work dirs: everything else in TMPDIR stays" \
  "dev-loop-identity.abc123 dev-loop-smoke.link12 dev-loop-smoke.x not-a-suite.abc123 other-dir other.txt sub" \
  "$(cd "$ktmp" && for f in *; do echo "$f"; done | paste -sd' ' -)"
[ -f "$ktmp/other-dir/file" ] && [ -d "$ktmp/sub/dev-loop-smoke.abc123" ] && pass "work dirs: other files keep their content" ||
  fail "work dirs: other files lost content"

# A whole suite run (section 27, by name) in its own TMPDIR: green removes its dir, red and DEV_LOOP_KEEP_WORK=1 keep it.
# ksuite NAME [VAR=VALUE...]: run tests/smoke.sh --section 'Forced failure' with TMPDIR=$kwork/NAME; sets kout and
# kleft (the dev-loop-smoke.* dirs left in it).
ksuite() {
  local dir="$kwork/$1"
  shift
  mkdir -p "$dir"
  kout=$(env TMPDIR="$dir" DEV_LOOP_SMOKE_FORCE_FAIL= DEV_LOOP_KEEP_WORK= "$@" "$plugin/tests/smoke.sh" --section 'Forced failure' 2>&1 | tail -n 1)
  kleft=$(cd "$dir" && for d in dev-loop-smoke.*; do [ -d "$d" ] && echo "$d"; done)
}
# kexisting FILE: the dirs listed in FILE (one per line) that still exist.
kexisting() { while IFS= read -r d; do [ -d "$d" ] && echo "$d"; done <"$1"; }
ksuite green
expect "work dirs: a green suite says its work dir is removed" "smoke: 1 passed, 0 failed (work dir removed)" "$kout"
expect "work dirs: a green suite leaves no dev-loop-smoke.* dir" "" "$kleft"
ksuite red DEV_LOOP_SMOKE_FORCE_FAIL=1
[ -n "$kleft" ] && [ -d "$kwork/red/$kleft" ] && pass "work dirs: a red suite keeps its work dir" || fail "work dirs: a red suite removed its dir"
expect "work dirs: a red suite names its work dir" "smoke: 0 passed, 1 failed (work dir $kwork/red/$kleft)" "$kout"
ksuite keep DEV_LOOP_KEEP_WORK=1
[ -n "$kleft" ] && pass "work dirs: DEV_LOOP_KEEP_WORK=1 keeps a green suite's dir" || fail "work dirs: DEV_LOOP_KEEP_WORK=1 did not keep it"
expect "work dirs: DEV_LOOP_KEEP_WORK=1 names the dir" "smoke: 1 passed, 0 failed (work dir $kwork/keep/$kleft)" "$kout"
grep -q 'dl_suite_end identity "\$work" "\$passed" "\$failed"' "$plugin/tests/identity.sh" &&
  pass "work dirs: identity.sh ends through dl_suite_end" || fail "work dirs: identity.sh does not end through dl_suite_end"

# The gate: a red check that names its work dir, three times; then a green one.
gtmp="$kwork/gtmp"
mkdir -p "$gtmp" "$kwork/gout/dev-loop-smoke.out123"
mkdir "$gtmp/dev-loop-smoke.decoy1" "$gtmp/dev-loop-identity.decoy1"
echo keep >"$gtmp/other.txt"
ln -s "$kwork/target" "$gtmp/dev-loop-smoke.link12"
git init -q --bare "$kwork/origin.git"
git clone -q "$kwork/origin.git" "$kwork/project" 2>/dev/null
cd "$kwork/project" || exit 1
printf '{"base_branch": "main", "checks": ["true"]}\n' >.dev-loop.json
echo one >src.txt
git add . && git commit -q -m "chore: start" && git push -q -u origin main
git checkout -q -b feat/80-dirs
echo two >>src.txt && git commit -q -am "feat: dirs (Refs #80)" && git push -q -u origin feat/80-dirs
# kgate COMMAND: gate feat/80-dirs with one check running COMMAND (a JSON string), TMPDIR=$gtmp; sets out and rc.
# KSETTLE (in the environment) sets DEV_LOOP_WORK_DIR_SETTLE_MINUTES, default 0 (no settle window).
kgate() {
  kgate_with '"checks": [{"name": "suites", "heavy": false, "command": '"$1"'}]'
}
# kgate_with JSON_MEMBERS: gate feat/80-dirs with these config members, TMPDIR=$gtmp; sets out and rc.
kgate_with() {
  printf '{"base_branch": "main", %s}\n' "$1" >"$kwork/gate.json"
  out=$(TMPDIR="$gtmp" DEV_LOOP_HOME="$kwork/home" DEV_LOOP_LOCK_DIR="$kwork/locks" DEV_LOOP_CONFIG="$kwork/gate.json" \
    DEV_LOOP_WORK_DIR_SETTLE_MINUTES="${KSETTLE:-0}" KWORK="$kwork" "$plugin/scripts/gate-train.sh" feat/80-dirs 2>&1)
  rc=$?
}
kred='"s=$(mktemp -d \"$TMPDIR/dev-loop-smoke.XXXXXX\"); i=$(mktemp -d \"$TMPDIR/dev-loop-identity.XXXXXX\"); echo \"smoke: 0 passed, 1 failed (work dir $s)\"; echo \"identity: 0 passed, 1 failed (work dir $i)\"; echo $s >>\"$KWORK/smoke.made\"; echo $i >>\"$KWORK/identity.made\"; exit 1"'
kgate '"echo \"smoke: 0 passed, 1 failed (work dir $KWORK/gout/dev-loop-smoke.out123)\"; echo \"smoke: (work dir $TMPDIR/dev-loop-smoke.link12)\"; exit 1"'
kgate "$kred"
kgate "$kred"
kgate "$kred"
expect "work dirs: the red gate is red" "1 TRAIN RED" "$rc $(echo "$out" | tail -1)"
expect "work dirs: the gate keeps only the newest red smoke dir" "$(tail -n 1 "$kwork/smoke.made")" \
  "$(kexisting "$kwork/smoke.made")"
expect "work dirs: the gate keeps only the newest red identity dir" "$(tail -n 1 "$kwork/identity.made")" \
  "$(kexisting "$kwork/identity.made")"
[ -d "$gtmp/dev-loop-smoke.decoy1" ] && [ -d "$gtmp/dev-loop-identity.decoy1" ] && [ -f "$gtmp/other.txt" ] &&
  pass "work dirs: the gate leaves dirs its logs never named and other files alone" || fail "work dirs: the gate removed a decoy"
[ -d "$kwork/gout/dev-loop-smoke.out123" ] && pass "work dirs: the gate leaves a named dir outside TMPDIR alone" ||
  fail "work dirs: the gate removed a dir outside TMPDIR"
[ -L "$gtmp/dev-loop-smoke.link12" ] && [ -f "$kwork/target/file" ] && pass "work dirs: the gate leaves a named symlink alone" ||
  fail "work dirs: the gate removed a symlink or its target"
kgate '"echo \"smoke: 3 passed, 0 failed (work dir removed)\""'
expect "work dirs: a green gate keeps the newest red dir" "0 $(tail -n 1 "$kwork/smoke.made")" \
  "$rc $(kexisting "$kwork/smoke.made")"
# A run that dies before its summary (a crash, a signal, a stall) is recorded from its start line; a green run
# that removed its own dir drops out of the record.
kgate '"s=$(mktemp -d \"$TMPDIR/dev-loop-smoke.XXXXXX\"); echo \"started smoke (work dir $s)\"; echo $s >>\"$KWORK/smoke.made\"; kill -9 $$"'
expect "work dirs: the gate keeps a crashed run's dir, named only by its start line, as the newest" \
  "1 $(tail -n 1 "$kwork/smoke.made")" "$rc $(kexisting "$kwork/smoke.made")"
kgate '"s=$(mktemp -d \"$TMPDIR/dev-loop-smoke.XXXXXX\"); echo \"started smoke (work dir $s)\"; rmdir \"$s\"; echo \"smoke: 1 passed, 0 failed (work dir removed)\""'
expect "work dirs: a green run's own removed dir drops out, the newest red one stays" \
  "0 $(tail -n 1 "$kwork/smoke.made")" "$rc $(kexisting "$kwork/smoke.made")"
grep -c '/dev-loop-smoke\.[^/]*$' "$kwork/home/project/gate-work-dirs.txt" | grep -qx 1 &&
  pass "work dirs: the record holds only the kept smoke dir" || fail "work dirs: record: $(cat "$kwork/home/project/gate-work-dirs.txt")"
[ -z "$(find "$kwork/home/project" -name 'gate-work-dirs.txt.tmp.*')" ] && pass "work dirs: no temporary record file is left" ||
  fail "work dirs: a gate-work-dirs.txt.tmp.* file is left"
rm -rf "$gtmp"/dev-loop-smoke.?????? "$gtmp"/dev-loop-identity.??????
kgate '"true"'
expect "work dirs: the record forgets dirs that are gone" "" "$(cat "$kwork/home/project/gate-work-dirs.txt" 2>/dev/null)"

# A skipped stage's log is left over from an earlier run: the dir it names must not cost this run's red dir.
mkdir "$gtmp/dev-loop-smoke.stale1"
printf 'smoke: 0 passed, 1 failed (work dir %s)\n' "$gtmp/dev-loop-smoke.stale1" >"$kwork/home/project/logs/train-two.log"
kgate_with '"fail_fast": true, "checks": [
  {"name": "one", "heavy": false, "command": "s=$(mktemp -d \"$TMPDIR/dev-loop-smoke.XXXXXX\"); echo \"started smoke (work dir $s)\"; echo $s >>\"$KWORK/smoke.made\"; exit 1"},
  {"name": "two", "heavy": false, "command": "true"}]'
expect "work dirs: a skipped stage's stale log does not cost this run's red dir" \
  "1 $(tail -n 1 "$kwork/smoke.made")" "$rc $(kexisting "$kwork/smoke.made")"
[ -d "$gtmp/dev-loop-smoke.stale1" ] && ! grep -qF stale1 "$kwork/home/project/gate-work-dirs.txt" &&
  pass "work dirs: the dir named only by a skipped stage's log is neither recorded nor removed" ||
  fail "work dirs: the skipped stage's dir was recorded or removed"
rmdir "$gtmp/dev-loop-smoke.stale1"

# The settle window (default 10 minutes): an older recorded dir that changed lately is kept for a later run.
KSETTLE=10 kgate "$kred"
expect "work dirs: a recorded dir that changed within the settle window is kept" 2 "$(kexisting "$kwork/smoke.made" | wc -l | tr -d ' ')"
kgate "$kred"
expect "work dirs: without the window the older dirs go on the next run" "$(tail -n 1 "$kwork/smoke.made")" "$(kexisting "$kwork/smoke.made")"

# This project's summary pattern shows the suites' results and Validation, not the start lines.
kgate_with '"checks": [{"name": "check", "heavy": false, "summary": "Validation (passed|failed)|^(smoke|identity): ",
  "command": "echo Validation passed; echo \"started smoke (work dir $TMPDIR/dev-loop-smoke.gone01)\"; echo \"smoke: 3 passed, 0 failed (work dir removed)\"; echo \"started identity (work dir $TMPDIR/dev-loop-identity.gone01)\"; echo \"identity: 2 passed, 0 failed (work dir removed)\""}]'
expect "work dirs: the gate summary shows Validation, smoke and identity, not the start lines" \
  "0|Validation passed|smoke: 3 passed, 0 failed (work dir removed)|identity: 2 passed, 0 failed (work dir removed)|TRAIN GREEN" \
  "$rc|$(echo "$out" | grep -E 'Validation|^(smoke|identity): |^started |^TRAIN' | paste -sd'|' -)"
rm -rf "$gtmp"/dev-loop-smoke.?????? "$gtmp"/dev-loop-identity.??????

# 27c. doctor's TMPDIR check (#80): free space and inodes of TMPDIR's filesystem (df -P, df -i), a note
# under 10% free, MISSING under 2%, with the count of leftover test work dirs; no inode part where df -i fails.
dwork="$work/doctor-tmp"
dtmp="$dwork/tmp"
mkdir -p "$dtmp/dev-loop-smoke.aaaaaa" "$dtmp/dev-loop-identity.bbbbbb" "$dtmp/dev-loop-smoke.cccccc" "$dwork/fakedf"
cat >"$dwork/fakedf/df" <<'DF'
#!/usr/bin/env bash
case " $* " in
  *" -i "*)
    [ -n "${FAKE_DF_INODES:-}" ] || exit 1
    echo "Filesystem      Inodes  IUsed  IFree IUse% Mounted on"
    echo "tmpfs          ${FAKE_DF_INODES} /tmp" ;;
  *)
    echo "Filesystem     1024-blocks    Used Available Capacity Mounted on"
    echo "${FAKE_DF_FS:-tmpfs}          ${FAKE_DF_SPACE} /tmp" ;;
esac
DF
chmod +x "$dwork/fakedf/df"
# kdoctor SPACE INODES: doctor.sh's TMPDIR line with fake df fields (total used free use%); INODES empty: no df -i.
# KTMP and FAKE_DF_FS (in the environment) override TMPDIR and the filesystem name; also prints awk errors.
kdoctor() {
  (cd "$dwork" && PATH="$dwork/fakedf:$PATH" TMPDIR="${KTMP:-$dtmp}" FAKE_DF_SPACE="$1" FAKE_DF_INODES="$2" \
    "$plugin/scripts/doctor.sh" 2>&1 | grep -E 'TMPDIR|awk|division')
}
expect "doctor tmp: plenty of space and inodes is ok, with the leftover count" \
  "ok      TMPDIR $dtmp: 80% space free, 90% inodes free; 3 leftover test work dirs (dev-loop-smoke.*, dev-loop-identity.*)" \
  "$(kdoctor "1000 200 800 20%" "1000 100 900 10%")"
expect "doctor tmp: under 10% free inodes is a note" \
  "note    TMPDIR $dtmp: 80% space free, 5% inodes free; 3 leftover test work dirs (dev-loop-smoke.*, dev-loop-identity.*)" \
  "$(kdoctor "1000 200 800 20%" "1000 950 50 95%")"
expect "doctor tmp: under 2% free space is MISSING" \
  "MISSING TMPDIR $dtmp: 1% space free, 90% inodes free; 3 leftover test work dirs (dev-loop-smoke.*, dev-loop-identity.*)" \
  "$(kdoctor "1000 990 10 99%" "1000 100 900 10%")"
expect "doctor tmp: without df -i the inode part is left out quietly" \
  "note    TMPDIR $dtmp: 5% space free; 3 leftover test work dirs (dev-loop-smoke.*, dev-loop-identity.*)" \
  "$(kdoctor "1000 950 50 95%" "")"
rm -rf "$dtmp"/dev-loop-*
expect "doctor tmp: no leftovers, no count" "ok      TMPDIR $dtmp: 80% space free" "$(kdoctor "1000 200 800 20%" "")"
expect "doctor tmp: a filesystem without inode counts (0) leaves the inode part out" "ok      TMPDIR $dtmp: 80% space free" \
  "$(kdoctor "1000 200 800 20%" "0 0 0 -")"
expect "doctor tmp: a filesystem name with spaces is read from the end of the line" "ok      TMPDIR $dtmp: 80% space free" \
  "$(FAKE_DF_FS="map auto home" kdoctor "1000 200 800 20%" "")"
expect "doctor tmp: a filesystem with no blocks (macOS map auto_home) is skipped without an error" "" \
  "$(FAKE_DF_FS="map auto_home" kdoctor "0 0 0 100%" "")"
expect "doctor tmp: TMPDIR=/ is checked as /" "ok      TMPDIR /: 80% space free" "$(KTMP=/ kdoctor "1000 200 800 20%" "")"
awk '/^## / { n++ } n == 1' "$plugin/CHANGELOG.md" | grep -qF '#80' && head -n 8 "$plugin/CHANGELOG.md" | grep -q '^## Unreleased' &&
  pass "work dirs: CHANGELOG has a #80 entry under Unreleased" || fail "work dirs: no #80 entry under ## Unreleased"
cd "$work/project" || exit 1
dl_suite_end smoke "$work" "$passed" "$failed"
