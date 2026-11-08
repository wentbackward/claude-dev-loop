#!/usr/bin/env bash
# Run one command with a role's GitHub identity: GH_TOKEN for gh, and a git credential helper (plus
# SSH-to-HTTPS rewrites) that exist only in this command's environment.
#
# Usage: as-role.sh <role> <command> [args...]
#   roles: implementer, tester, reviewer, gate, orchestrator
#
# Identity mode off (no "identities" in .dev-loop.json): runs the command unchanged with the user's own
# credentials, so the same skills work in both modes. Identity mode on: the role must be configured.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
dl_help "$0" "${1:-}"
# shellcheck source=lib/identity.sh
. "$scripts_dir/lib/identity.sh"

[ $# -ge 2 ] || dl_die "usage: as-role.sh <role> <command> [args...]"
role=$1
shift
dl_is_role "$role" || dl_die "unknown role '$role' (roles: $DL_ROLES)"
dl_load_config
export DEV_LOOP_ROLE=$role

if ! dl_identities_enabled; then
  exec "$@"
fi

token=$(dl_role_token "$role") || exit 2
[ -n "$token" ] || dl_die "empty token for $role"
export GH_TOKEN=$token GITHUB_TOKEN=$token DEV_LOOP_ROLE_TOKEN=$token
export GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0

# Git config through the environment (GIT_CONFIG_COUNT): the empty helper resets the user's helpers, the
# second answers with this role's token; SSH remotes are rewritten so the push cannot use the user's SSH key.
count=${GIT_CONFIG_COUNT:-0}
add_git_config() {
  export "GIT_CONFIG_KEY_$count=$1" "GIT_CONFIG_VALUE_$count=$2"
  count=$((count + 1))
}
host=$(cfg github.host github.com)
add_git_config credential.helper ""
# shellcheck disable=SC2016  # expanded by git's shell when the helper runs
add_git_config credential.helper '!f() { test "$1" = get && echo username=x-access-token && echo "password=$DEV_LOOP_ROLE_TOKEN"; }; f'
add_git_config "url.https://$host/.insteadOf" "git@$host:"
add_git_config "url.https://$host/.insteadOf" "ssh://git@$host/"
add_git_config "url.https://$host/.pushInsteadOf" "git@$host:"
add_git_config "url.https://$host/.pushInsteadOf" "ssh://git@$host/"
export GIT_CONFIG_COUNT=$count

name=$(cfg "identities.$role.git_name" "")
email=$(cfg "identities.$role.git_email" "")
if [ -n "$name" ] && [ -n "$email" ]; then
  export GIT_AUTHOR_NAME=$name GIT_COMMITTER_NAME=$name GIT_AUTHOR_EMAIL=$email GIT_COMMITTER_EMAIL=$email
fi
exec "$@"
