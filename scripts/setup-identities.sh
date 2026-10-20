#!/usr/bin/env bash
# One-command setup of per-role GitHub identities (GitHub Apps), run by the repository owner in a terminal.
#
# Usage: setup-identities.sh [--roles "implementer tester reviewer gate orchestrator"] [--yes] [--no-protect]
#
# For each role without an app yet: opens the browser on GitHub's "new app" form, prefilled from
# templates/github-apps/<role>.json (one "Create GitHub App" click), receives the code on a one-shot local
# listener, exchanges it for the app id and private key, and stores the key (0600) under
# ~/.config/dev-loop/<owner>/. Then, for each app not installed on this repository yet, opens its install
# page (one "Install" click, with this repository selected) and waits for the installation. Writes the
# "identities" block into .dev-loop.json and runs github-protect.sh (plan, then apply on confirm).
# Idempotent and resumable: existing apps, keys and installations are reused. Apps are per owner, so a
# second repository of the same owner needs only the install clicks.
#
# Environment: DEV_LOOP_CREDENTIALS_DIR (default ~/.config/dev-loop), DEV_LOOP_BROWSER (command that opens a
# URL), DEV_LOOP_GITHUB_WEB (default https://github.com), DEV_LOOP_LISTEN_PORT (default: a free port).
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin_dir=$(dirname "$scripts_dir")
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
# shellcheck source=lib/identity.sh
. "$scripts_dir/lib/identity.sh"

roles=$DL_ROLES yes="" protect=yes
while [ $# -gt 0 ]; do
  case "$1" in
    --roles) roles=$2; shift 2 ;;
    --yes) yes=yes; shift ;;
    --no-protect) protect=""; shift ;;
    *) dl_die "usage: setup-identities.sh [--roles \"...\"] [--yes] [--no-protect]" ;;
  esac
done
for command in python3 openssl curl; do
  command -v "$command" >/dev/null 2>&1 || dl_die "$command is required"
done
dl_load_config required
repo=$(dl_github_repo) || dl_die "cannot tell the GitHub repository (set github.repo in .dev-loop.json)"
owner=${repo%%/*}
web=${DEV_LOOP_GITHUB_WEB:-https://github.com}
credentials_root=${DEV_LOOP_CREDENTIALS_DIR:-$HOME/.config/dev-loop}
credentials=$credentials_root/$owner
(umask 077 && mkdir -p "$credentials") && chmod 700 "$credentials_root" "$credentials"

# display_path PATH: the path with $HOME written as "~", as stored in .dev-loop.json.
display_path() {
  case "$1" in "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;; *) printf '%s\n' "$1" ;; esac
}

open_url() {
  local opener=${DEV_LOOP_BROWSER:-}
  if [ -z "$opener" ]; then
    if command -v xdg-open >/dev/null 2>&1; then opener=xdg-open; elif command -v open >/dev/null 2>&1; then opener=open; fi
  fi
  echo "  open: $1"
  [ -z "$opener" ] || "$opener" "$1" >/dev/null 2>&1 &
}

free_port() {
  python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

form_url() {
  local type
  type=$(cfg github.owner_type "")
  [ -n "$type" ] || type=$(curl -sS -f "$(dl_api_url)/users/$owner" 2>/dev/null | json_get type)
  if [ "$type" = Organization ]; then
    printf '%s/organizations/%s/settings/apps/new\n' "$web" "$owner"
  else
    printf '%s/settings/apps/new\n' "$web"
  fi
}

# create_app ROLE: the manifest flow for one role; stores ROLE.pem and ROLE.json in the credentials dir.
create_app() {
  local role=$1 port state manifest code_file response name
  port=${DEV_LOOP_LISTEN_PORT:-$(free_port)}
  state=$(openssl rand -hex 16)
  manifest=$(mktemp)
  code_file=$(mktemp)
  name="dev-loop-$role-$owner"
  name=${name:0:34}
  sed -e "s#{{OWNER}}#$owner#g" -e "s#{{REPO}}#$repo#g" -e "s#{{REDIRECT_URL}}#http://127.0.0.1:$port/callback#g" \
    -e "s#\"dev-loop-$role-$owner\"#\"$name\"#" "$plugin_dir/templates/github-apps/$role.json" >"$manifest"
  echo "[$role] create the app: click \"Create GitHub App\" on the page that opens"
  python3 -I "$scripts_dir/lib/manifest_listener.py" "$port" "$manifest" "$(form_url)" "$state" "$code_file" \
    "${DEV_LOOP_LISTEN_TIMEOUT:-600}" &
  local listener=$!
  sleep 0.5
  open_url "http://127.0.0.1:$port/"
  if ! wait "$listener"; then
    rm -f "$manifest" "$code_file"
    dl_die "[$role] no answer from GitHub within the timeout; run the script again to resume"
  fi
  response=$(curl -sS -f -X POST -H "Accept: application/vnd.github+json" \
    "$(dl_api_url)/app-manifests/$(cat "$code_file")/conversions") || dl_die "[$role] code exchange failed"
  rm -f "$manifest" "$code_file"
  (umask 077 && printf '%s' "$response" | json_get pem >"$credentials/$role.pem")
  printf '%s' "$response" | python3 -I -c '
import json, sys
app = json.load(sys.stdin)
print(json.dumps({key: app.get(key) for key in ("id", "slug", "name", "html_url")}, indent=2))
' >"$credentials/$role.json"
  chmod 600 "$credentials/$role.pem" "$credentials/$role.json"
  echo "[$role] created app $(json_get slug <"$credentials/$role.json") (id $(json_get id <"$credentials/$role.json"))"
}

# installation_of ROLE: the app's installation id on this repository, empty when not installed.
installation_of() {
  local jwt
  jwt=$(dl_app_jwt "$(json_get id <"$credentials/$1.json")" "$credentials/$1.pem") || return 0
  dl_api_call GET "/repos/$repo/installation" "Bearer $jwt" 2>/dev/null | json_get id
}

# install_app ROLE: open the install page until the app is installed on this repository; prints the id.
install_app() {
  local role=$1 slug installation waited=0
  installation=$(installation_of "$role")
  if [ -z "$installation" ]; then
    slug=$(json_get slug <"$credentials/$role.json")
    echo "[$role] install the app: choose \"Only select repositories\", select $repo, click \"Install\"" >&2
    open_url "$web/apps/$slug/installations/new" >&2
    while [ -z "$installation" ]; do
      [ "$waited" -lt "${DEV_LOOP_INSTALL_TIMEOUT:-600}" ] || dl_die "[$role] not installed yet; run the script again to resume"
      sleep "${DEV_LOOP_POLL_SECONDS:-5}"
      waited=$((waited + ${DEV_LOOP_POLL_SECONDS:-5}))
      installation=$(installation_of "$role")
    done
  fi
  printf '%s\n' "$installation"
}

# write_identity ROLE INSTALLATION: set identities.ROLE in .dev-loop.json (other keys are kept).
write_identity() {
  local role=$1 installation=$2 slug bot_id
  slug=$(json_get slug <"$credentials/$role.json")
  bot_id=$(curl -sS -f "$(dl_api_url)/users/$slug%5Bbot%5D" 2>/dev/null | json_get id)
  python3 -I - "$DL_CONFIG" "$role" "$(json_get id <"$credentials/$role.json")" "$installation" \
    "$(display_path "$credentials/$role.pem")" "$slug" "$bot_id" <<'PY'
import json, os, sys
path, role, app_id, installation, key_file, slug, bot_id = sys.argv[1:8]
with open(path, encoding="utf-8") as handle:
    config = json.load(handle)
identity = {"type": "app", "app_id": int(app_id), "installation_id": int(installation), "key_file": key_file}
if slug and bot_id:
    identity["git_name"] = f"{slug}[bot]"
    identity["git_email"] = f"{bot_id}+{slug}[bot]@users.noreply.github.com"
config.setdefault("identities", {})[role] = identity
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
os.replace(temporary, path)
PY
}

for role in $roles; do
  dl_is_role "$role" || dl_die "unknown role '$role'"
  if [ -s "$credentials/$role.pem" ] && [ -s "$credentials/$role.json" ]; then
    echo "[$role] app exists: $(json_get slug <"$credentials/$role.json")"
  else
    create_app "$role"
  fi
done
for role in $roles; do
  installation=$(install_app "$role") || exit 2
  write_identity "$role" "$installation"
  echo "[$role] installed on $repo (installation $installation)"
done
echo "identities written to $DL_CONFIG (key files only, no tokens); commit it."

[ -n "$protect" ] || exit 0
"$scripts_dir/github-protect.sh" || exit 1
answer=n
if [ -n "$yes" ]; then answer=y; else read -r -p "Apply these rulesets to $repo? [y/N] " answer; fi
case "$answer" in
  y|Y|yes) "$scripts_dir/github-protect.sh" --apply ;;
  *) echo "not applied; run $(display_path "$scripts_dir")/github-protect.sh --apply later" ;;
esac
