#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # pass/fail never fail; single quotes are expanded by the inner shell
# Tests of identity mode with fakes (no network, no real GitHub): as-role.sh credentials, the guard hook,
# github-protect.sh plans, setup-identities.sh (manifest flow) and merge-train.sh with role identities.
# Run: tests/identity.sh   (TMPDIR picks the work dir; a green run removes it unless DEV_LOOP_KEEP_WORK=1)
set -u
plugin=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../scripts/lib/workdirs.sh
. "$plugin/scripts/lib/workdirs.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-identity.XXXXXX")
# Named at once, so the gate records a run that never reaches its summary (a crash, a signal, a stall).
echo "started identity (work dir $work)"
REAL_CURL=$(command -v curl)
export REAL_CURL
export DEV_LOOP_HOME="$work/home" DEV_LOOP_LOCK_DIR="$work/locks" DEV_LOOP_GH_SETTLE_SECONDS=0
export XDG_RUNTIME_DIR="$work/runtime" DEV_LOOP_CREDENTIALS_DIR="$work/credentials"
export FAKE_GH_DIR="$work/gh" FAKE_CURL_DIR="$work/curl" GIT_CONFIG_GLOBAL="$work/gitconfig"
export DEV_LOOP_BROWSER="$plugin/tests/fake-browser" DEV_LOOP_POLL_SECONDS=1 DEV_LOOP_LISTEN_TIMEOUT=30
mkdir -p "$work/bin" "$XDG_RUNTIME_DIR"
ln -s "$plugin/tests/fake-gh" "$work/bin/gh"
ln -s "$plugin/tests/fake-curl" "$work/bin/curl"
export PATH="$work/bin:$PATH"
git config --global user.name tester
git config --global user.email tester@example.invalid
git config --global init.defaultBranch main

passed=0
failed=0
pass() { echo "PASS $*"; passed=$((passed + 1)); }
fail() { echo "FAIL $*"; failed=$((failed + 1)); }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

git init -q --bare "$work/origin.git"
git clone -q "$work/origin.git" "$work/project" 2>/dev/null
cd "$work/project" || exit 1
echo one >src.txt
cat >.dev-loop.json <<'EOF'
{"base_branch": "main", "github": {"repo": "owner/project"},
 "checks": [{"name": "unit", "command": "true", "heavy": false}]}
EOF
git add . && git commit -q -m "chore: start" && git push -q origin main

as_role() { "$plugin/scripts/as-role.sh" "$@"; }

# 1. Identity mode off: as-role.sh passes the command through with the user's own credentials.
expect "identity mode off: no role token" "none" "$(unset GH_TOKEN; as_role implementer bash -c 'echo ${GH_TOKEN:-none}')"

# 2. Machine-user tokens: each role gets its own token, for gh and for git.
mkdir -p "$work/credentials/owner" && chmod 700 "$work/credentials/owner"
for role in implementer tester reviewer gate orchestrator; do
  echo "token-$role" >"$work/credentials/owner/$role.token"
done
python3 -I - "$work" <<'PY'
import json, sys
work = sys.argv[1]
config = json.load(open(f"{work}/project/.dev-loop.json"))
config["identities"] = {role: {"type": "token", "token_file": f"{work}/credentials/owner/{role}.token"}
                        for role in ("implementer", "tester", "reviewer", "gate", "orchestrator")}
json.dump(config, open(f"{work}/project/.dev-loop.json", "w"), indent=2)
PY
expect "implementer gets the implementer token" token-implementer "$(as_role implementer bash -c 'echo $GH_TOKEN')"
expect "reviewer gets the reviewer token" token-reviewer "$(as_role reviewer bash -c 'echo $GH_TOKEN')"
expect "git credential helper answers with the role token" "password=token-gate" \
  "$(printf 'protocol=https\nhost=github.com\n\n' | as_role gate git credential fill 2>/dev/null | grep password)"
expect "git rewrites SSH remotes to HTTPS for the role" "https://github.com/owner/project.git" \
  "$(as_role implementer git ls-remote --get-url git@github.com:owner/project.git)"
expect "the token exists only for that command" "" "$(git config --get-all credential.helper)"
as_role nobody true 2>/dev/null
expect "unknown role is refused" 2 $?

# 3. GitHub App identity: a signed JWT, an installation token, cached.
openssl genrsa -out "$work/credentials/owner/app.pem" 2048 2>/dev/null
openssl rsa -in "$work/credentials/owner/app.pem" -pubout -out "$work/app.pub" 2>/dev/null
touch "$FAKE_CURL_DIR/installed-555" 2>/dev/null || { mkdir -p "$FAKE_CURL_DIR"; touch "$FAKE_CURL_DIR/installed-555"; }
python3 -I - "$work" <<'PY'
import json, sys
work = sys.argv[1]
path = f"{work}/project/.dev-loop.json"
config = json.load(open(path))
config["identities"]["tester"] = {"type": "app", "app_id": 555, "key_file": f"{work}/credentials/owner/app.pem"}
json.dump(config, open(path, "w"), indent=2)
PY
expect "app role gets an installation token" ghs_installation_9555 "$(as_role tester bash -c 'echo $GH_TOKEN')"
calls=$(wc -l <"$FAKE_CURL_DIR/calls.log")
as_role tester true
expect "the installation token is cached" "$calls" "$(wc -l <"$FAKE_CURL_DIR/calls.log")"
(
  # shellcheck source=../scripts/lib/common.sh
  . "$plugin/scripts/lib/common.sh"
  # shellcheck source=../scripts/lib/identity.sh
  . "$plugin/scripts/lib/identity.sh"
  jwt=$(dl_app_jwt 555 "$work/credentials/owner/app.pem")
  printf '%s' "${jwt%.*}" >"$work/jwt.data"
  sig=${jwt##*.}
  sig=$(printf '%s' "$sig" | tr -- '-_' '+/')
  while [ $((${#sig} % 4)) -ne 0 ]; do sig="$sig="; done
  printf '%s' "$sig" | openssl base64 -d -A >"$work/jwt.sig"
)
openssl dgst -sha256 -verify "$work/app.pub" -signature "$work/jwt.sig" "$work/jwt.data" >/dev/null 2>&1 &&
  pass "the app JWT is signed with the app's key (RS256)" || fail "the app JWT signature does not verify"
expect "the token cache is user-only" 600 "$(stat -c %a "$XDG_RUNTIME_DIR"/dev-loop-tokens/project/tester.json 2>/dev/null)"

# 4. The guard hook.
guard() { # guard AGENT_TYPE COMMAND -> exit status
  python3 -I -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
    "agent_type": sys.argv[2] or None, "tool_input": {"command": sys.argv[3]}}))' "$work/project" "$1" "$2" |
    CLAUDE_PROJECT_DIR="$work/project" "$plugin/hooks/guard-role.sh" 2>/dev/null
  echo $?
}
AS="$plugin/scripts/as-role.sh"
expect "guard: a raw git push is refused" 2 "$(guard dev-loop:implementer 'git push -u origin feat/1-x')"
expect "guard: implementer may push as implementer" 0 "$(guard dev-loop:implementer "$AS implementer git push -u origin feat/1-x")"
expect "guard: implementer may open a PR as implementer" 0 "$(guard dev-loop:implementer "cd /x && $AS implementer gh pr create --fill")"
expect "guard: implementer may not act as reviewer" 2 "$(guard dev-loop:implementer "$AS reviewer gh pr review 3 --approve")"
expect "guard: reviewer may approve as reviewer" 0 "$(guard dev-loop:code-reviewer "$AS reviewer gh pr review 3 --approve")"
expect "guard: reviewer may not push" 2 "$(guard dev-loop:code-reviewer "$AS reviewer git push origin feat/1-x")"
expect "guard: tester may open an issue as tester" 0 "$(guard dev-loop:test-engineer "$AS tester gh issue create -t x -b y")"
expect "guard: tester may not push" 2 "$(guard dev-loop:verifier "$AS tester git push")"
expect "guard: the doc-auditor may open an issue as tester" 0 "$(guard dev-loop:doc-auditor "$AS tester gh issue create -t x -b y")"
expect "guard: the doc-auditor may not push" 2 "$(guard dev-loop:doc-auditor "$AS tester git push")"
expect "guard: the architect may open an issue as tester" 0 "$(guard dev-loop:architect "$AS tester gh issue create -t x -b y")"
expect "guard: the architect may not push" 2 "$(guard dev-loop:architect "$AS tester git push")"
expect "guard: nobody uses the gate identity directly" 2 "$(guard "" "$AS gate gh pr merge 3 --squash")"
expect "guard: a raw merge is refused" 2 "$(guard "" 'gh pr merge 3 --squash')"
expect "guard: the main session may run the merge train" 0 "$(guard "" "$plugin/scripts/merge-train.sh feat/1-x")"
expect "guard: reading credentials is refused" 2 "$(guard "" 'cat ~/.config/dev-loop/owner/gate.pem')"
expect "guard: gh auth token is refused" 2 "$(guard dev-loop:implementer 'gh auth token')"
expect "guard: a push hidden in bash -c is refused" 2 "$(guard dev-loop:implementer "bash -c 'git push origin HEAD'")"
expect "guard: read-only commands pass" 0 "$(guard dev-loop:implementer 'git status && gh pr view 3 && gh api repos/o/r/pulls')"
expect "guard: gh api writes need a role" 2 "$(guard "" 'gh api -X POST repos/o/r/issues -f title=x')"
expect "guard: applying rulesets is for the owner" 2 "$(guard "" "$plugin/scripts/github-protect.sh --apply")"
expect "guard: the Read tool may not open a key file" 2 "$(python3 -I -c 'import json; print(json.dumps({"tool_name": "Read", "tool_input": {"file_path": "/h/.config/dev-loop/o/gate.pem"}}))' |
  CLAUDE_PROJECT_DIR="$work/project" "$plugin/hooks/guard-role.sh" 2>/dev/null; echo $?)"

# 5. github-protect.sh dry run: the plan, with the gate app as the only source of the status.
python3 -I - "$work" <<'PY'
import json, sys
path = f"{sys.argv[1]}/project/.dev-loop.json"
config = json.load(open(path))
config["identities"]["gate"] = {"type": "app", "app_id": 777, "key_file": "x.pem"}
config["identities"]["implementer"] = {"type": "app", "app_id": 666, "key_file": "y.pem"}
json.dump(config, open(path, "w"), indent=2)
PY
plan=$("$plugin/scripts/github-protect.sh")
echo "$plan" | grep -c "^PLAN POST repos/owner/project/rulesets" | grep -qx 3 && pass "protect: plans three rulesets" || fail "protect: plan"
echo "$plan" | grep -q '"context":"dev-loop/gate","integration_id":777' && pass "protect: status required from the gate app" ||
  fail "protect: required status source"
echo "$plan" | grep -q '"require_last_push_approval":true' && pass "protect: last pusher cannot approve" || fail "protect: last push"
echo "$plan" | grep -q '"actor_id":666,"actor_type":"Integration"' && pass "protect: implementer app may push feature branches" ||
  fail "protect: feature bypass"
echo "$plan" | grep -q "dry run: nothing changed" && pass "protect: dry run by default" || fail "protect: dry run"
[ ! -f "$FAKE_GH_DIR/api.log" ] && pass "protect: the dry run makes no API call" || fail "protect: dry run called the API"
"$plugin/scripts/github-protect.sh" --apply >/dev/null
expect "protect --apply creates three rulesets" 3 "$(grep -c "api -X POST repos/owner/project/rulesets" "$FAKE_GH_DIR/api.log")"

# 6. setup-identities.sh: the manifest flow, installs, the identities block, protect; then idempotent.
rm -rf "$FAKE_GH_DIR"
python3 -I - "$work" <<'PY'
import json, sys
path = f"{sys.argv[1]}/project/.dev-loop.json"
config = json.load(open(path))
del config["identities"]
json.dump(config, open(path, "w"), indent=2)
PY
out=$("$plugin/scripts/setup-identities.sh" --roles "implementer gate" --yes 2>&1)
rc=$?
printf '%s\n' "$out" | while IFS= read -r line; do echo "    $line"; done
expect "setup-identities succeeds" 0 "$rc"
expect "the private key is stored user-only" 600 "$(stat -c %a "$work/credentials/owner/gate.pem")"
expect "the manifest asks for the gate's permissions" '{"contents": "write", "pull_requests": "write", "statuses": "write", "metadata": "read"}' \
  "$(python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["default_permissions"]))' "$FAKE_CURL_DIR/manifest-dev-loop-gate-owner.json")"
expect "identities block written" "app 101 9101" "$(python3 -I -c 'import json, sys; g = json.load(open(sys.argv[1]))["identities"]["gate"]; print(g["type"], g["app_id"], g["installation_id"])' .dev-loop.json)"
grep -q "BEGIN" .dev-loop.json && fail "a key leaked into the config" || pass "no key material in the config"
expect "protect applied after setup" 3 "$(grep -c "api -X POST repos/owner/project/rulesets" "$FAKE_GH_DIR/api.log" 2>/dev/null)"
browser_calls=$(wc -l <"$FAKE_CURL_DIR/browser.log")
"$plugin/scripts/setup-identities.sh" --roles "implementer gate" --no-protect >/dev/null 2>&1
expect "setup-identities again: no new clicks" "$browser_calls" "$(wc -l <"$FAKE_CURL_DIR/browser.log")"

# 7. merge-train.sh in identity mode: PR as implementer, status and merge as gate, approval required.
python3 -I - "$work" <<'PY'
import json, sys
work = sys.argv[1]
path = f"{work}/project/.dev-loop.json"
config = json.load(open(path))
config["identities"] = {role: {"type": "token", "token_file": f"{work}/credentials/owner/{role}.token"}
                        for role in ("implementer", "tester", "reviewer", "gate", "orchestrator")}
json.dump(config, open(path, "w"), indent=2)
PY
git add .dev-loop.json && git commit -q -m "chore: identities" && git push -q origin main
git -C "$work/origin.git" config receive.denyNonFastForwards true   # no force push anywhere (#57)
git checkout -q -b feat/1-x
echo two >>src.txt && git commit -q -am "feat: two (Refs #1)" && git push -q -u origin feat/1-x
x_src=$(git rev-parse feat/1-x)
git checkout -q main
echo readme >README && git add README && git commit -q -m "docs: readme" && git push -q origin main
mkdir -p "$("$plugin/scripts/paths.sh" notes-dir)"
printf 'feat: two (#1)\n\nCloses #1\n' >"$("$plugin/scripts/paths.sh" notes feat/1-x)"
"$plugin/scripts/gate-train.sh" feat/1-x >/dev/null
export FAKE_GH_REQUIRE_APPROVAL=1
"$plugin/scripts/merge-train.sh" feat/1-x >/dev/null 2>&1
expect "merge-train stops without the reviewer's approval" 9 $?
grep -q "^\[token-implementer\] gh pr create" "$FAKE_GH_DIR/calls.log" && pass "the PR is opened as the implementer" ||
  fail "PR not opened as implementer"
grep -q "^\[token-gate\] gh api -X POST repos/owner/project/statuses/" "$FAKE_GH_DIR/calls.log" &&
  pass "the gate status is posted as the gate" || fail "gate status"
as_role implementer gh pr review feat/1-x --approve 2>/dev/null
expect "the implementer cannot approve its own PR" 1 $?
as_role reviewer gh pr review feat/1-x --approve
"$plugin/scripts/merge-train.sh" feat/1-x >/dev/null 2>&1
expect "merge-train merges once approved" 0 $?
grep -q "^\[token-gate\] gh pr merge feat/1-x --squash --match-head-commit" "$FAKE_GH_DIR/calls.log" &&
  pass "the merge runs as the gate, pinned to the gated head" || fail "merge identity"
git fetch -q origin
expect "origin main has the squash commit" "feat: two (#1)" "$(git log --format=%s -1 origin/main)"
expect "the merged head is a fast-forward of the gated head, pushed as the gate" "$x_src" \
  "$(git log -1 --format=%P "$(cat "$FAKE_GH_DIR/feat_1-x.head")" | cut -d' ' -f1)"
grep -q "^\[token-gate\] gh api -X POST repos/owner/project/statuses/$(cat "$FAKE_GH_DIR/feat_1-x.head") " "$FAKE_GH_DIR/calls.log" &&
  pass "the gate status is posted on the head that merges" || fail "gate status on the merged head"

dl_suite_end identity "$work" "$passed" "$failed"
