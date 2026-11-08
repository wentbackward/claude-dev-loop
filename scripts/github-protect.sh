#!/usr/bin/env bash
# Set up the server-side gates on GitHub (repository rulesets) for identity mode. Idempotent: rulesets
# are matched by name and updated in place. Dry run by default: prints the plan (API calls and bodies).
#
# Usage: github-protect.sh [--apply] [--admin-bypass]
#   --apply         make the changes (with the owner's own gh login, which needs admin on the repository)
#   --admin-bypass  let repository admins bypass the base-branch rules through a PR (emergency use)
#
# Rulesets (names start with "dev-loop:"):
#   base branch      PR required, 1 approval, stale approvals dismissed, approval of the most recent push
#                    required (the last pusher cannot approve), squash only, required status
#                    github.status_context ("dev-loop/gate") from the gate app only, branch up to date,
#                    no force push, no deletion; nobody bypasses.
#   feature branches github.feature_patterns (feat/*, fix/*, chore/*, docs/*): only the implementer and gate
#                    apps may create, update or delete them (app identities only; see README).
#   other branches   no new branches outside the base and the feature patterns.
# Rulesets need a public repository, or GitHub Pro/Team/Enterprise for a private one.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
dl_help "$0" "${1:-}"
# shellcheck source=lib/identity.sh
. "$scripts_dir/lib/identity.sh"

apply="" admin_bypass=""
for argument in "$@"; do
  case "$argument" in
    --apply) apply=yes ;;
    --admin-bypass) admin_bypass=yes ;;
    *) dl_die "usage: github-protect.sh [--apply] [--admin-bypass]" ;;
  esac
done
dl_load_config required
repo=$(dl_github_repo) || dl_die "cannot tell the GitHub repository (set github.repo in .dev-loop.json)"
context=$(cfg github.status_context "dev-loop/gate")

# app_id ROLE: the role's GitHub App id, empty for a machine-user token or no identity.
app_id() {
  [ "$(cfg "identities.$1.type" "")" = app ] && cfg "identities.$1.app_id" ""
}

# json_list ITEMS...: a JSON array of strings.
json_list() {
  local first=yes item
  printf '['
  for item in "$@"; do
    [ -n "$first" ] || printf ','
    printf '"%s"' "$item"
    first=""
  done
  printf ']'
}

patterns=()
count=$(cfg_len github.feature_patterns)
if [ "$count" -gt 0 ]; then
  for ((i = 0; i < count; i++)); do patterns+=("$(cfg "github.feature_patterns.$i")"); done
else
  patterns=("feat/*" "fix/*" "chore/*" "docs/*")
fi
feature_refs=()
for pattern in "${patterns[@]}"; do feature_refs+=("refs/heads/$pattern"); done

gate_app=$(app_id gate)
implementer_app=$(app_id implementer)
status_check="{\"context\":\"$context\"${gate_app:+,\"integration_id\":$gate_app}}"
base_bypass="[]"
[ -z "$admin_bypass" ] || base_bypass='[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]'

base_body=$(cat <<EOF
{"name":"dev-loop: base branch","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["refs/heads/$DL_BASE"],"exclude":[]}},
 "bypass_actors":$base_bypass,
 "rules":[
  {"type":"deletion"},
  {"type":"non_fast_forward"},
  {"type":"pull_request","parameters":{"required_approving_review_count":1,"dismiss_stale_reviews_on_push":true,
   "require_last_push_approval":true,"require_code_owner_review":false,"required_review_thread_resolution":false,
   "allowed_merge_methods":["squash"]}},
  {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,
   "do_not_enforce_on_create":false,"required_status_checks":[$status_check]}}
 ]}
EOF
)

feature_bypass=""
for id in $implementer_app $gate_app; do
  feature_bypass+="${feature_bypass:+,}{\"actor_id\":$id,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}"
done
feature_body=$(cat <<EOF
{"name":"dev-loop: feature branches","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":$(json_list "${feature_refs[@]}"),"exclude":[]}},
 "bypass_actors":[$feature_bypass],
 "rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}]}
EOF
)
other_body=$(cat <<EOF
{"name":"dev-loop: other branches","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["~ALL"],"exclude":$(json_list "refs/heads/$DL_BASE" "${feature_refs[@]}")}},
 "bypass_actors":[],
 "rules":[{"type":"creation"}]}
EOF
)

notes=()
[ -n "$gate_app" ] || notes+=("the gate is not a GitHub App: any identity with commit-status write could post $context")
if [ -z "$implementer_app" ] || [ -z "$gate_app" ]; then
  notes+=("feature-branch pushes are limited by token permissions only (ruleset bypass lists take apps, not users)")
fi

# upsert NAME BODY: create the ruleset or update the one with the same name.
upsert() {
  local name=$1 body=$2 id=""
  if [ -n "$apply" ]; then
    id=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2>/dev/null | head -n 1)
  fi
  if [ -z "$apply" ]; then
    echo "PLAN POST repos/$repo/rulesets  (PUT repos/$repo/rulesets/<id> if \"$name\" exists)"
    printf '%s\n' "$body" | sed 's/^/     /'
  elif [ -n "$id" ]; then
    printf '%s' "$body" | gh api -X PUT "repos/$repo/rulesets/$id" --input - >/dev/null &&
      echo "updated ruleset \"$name\" ($id)"
  else
    printf '%s' "$body" | gh api -X POST "repos/$repo/rulesets" --input - >/dev/null &&
      echo "created ruleset \"$name\""
  fi
}

echo "repository $repo, base branch $DL_BASE, required status $context${gate_app:+ (gate app $gate_app)}"
upsert "dev-loop: base branch" "$base_body" || exit 1
if [ -n "$feature_bypass" ]; then
  upsert "dev-loop: feature branches" "$feature_body" || exit 1
fi
upsert "dev-loop: other branches" "$other_body" || exit 1
for note in "${notes[@]}"; do echo "note: $note"; done
[ -n "$apply" ] || echo "dry run: nothing changed. Run with --apply to make these changes."
