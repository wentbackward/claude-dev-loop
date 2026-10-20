# shellcheck shell=bash
# Role identities (optional): credentials per role from files outside the repository, never token values
# in config. Requires lib/common.sh and dl_load_config.
#
# .dev-loop.json:
#   "identities": {
#     "implementer": {"type": "app", "app_id": 123, "key_file": "~/.config/dev-loop/<repo>/implementer.pem",
#                     "installation_id": 456},
#     "reviewer":    {"type": "token", "token_file": "~/.config/dev-loop/<repo>/reviewer.token"},
#     ...
#   }
# Roles: implementer, tester, reviewer, gate, orchestrator. No "identities" = identity mode off.

DL_ROLES="implementer tester reviewer gate orchestrator"

# dl_identities_enabled: true when the config names at least one role identity.
dl_identities_enabled() {
  local role
  for role in $DL_ROLES; do
    [ -n "$(cfg "identities.$role.type" "")" ] && return 0
  done
  return 1
}

dl_is_role() {
  case " $DL_ROLES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# dl_github_repo: owner/name of the GitHub repository (config github.repo, else parsed from the remote URL).
dl_github_repo() {
  local configured url
  configured=$(cfg github.repo "")
  if [ -n "$configured" ]; then
    printf '%s\n' "$configured"
    return
  fi
  url=$(git -C "${DL_ROOT:-.}" remote get-url "$DL_REMOTE" 2>/dev/null) || return 1
  url=${url%.git}
  case "$url" in
    git@*:*) printf '%s\n' "${url#*:}" ;;
    ssh://*|https://*|http://*) printf '%s\n' "$url" | sed -E 's#^[a-z]+://([^@/]*@)?[^/]+/##' ;;
    *) return 1 ;;
  esac
}

dl_api_url() {
  cfg github.api_url "https://api.github.com"
}

dl_base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# dl_app_jwt APP_ID KEY_FILE: a 9-minute JWT signed with the GitHub App's private key (RS256).
dl_app_jwt() {
  local app_id=$1 key_file=$2 now header payload signature
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | dl_base64url)
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$app_id" | dl_base64url)
  signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key_file" -binary | dl_base64url) ||
    return 1
  printf '%s.%s.%s\n' "$header" "$payload" "$signature"
}

# dl_api_call METHOD PATH AUTH -> response body (curl; AUTH is the full Authorization header value).
dl_api_call() {
  curl -sS -f -X "$1" -H "Authorization: $3" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$(dl_api_url)$2"
}

# dl_token_cache ROLE: where a minted installation token is kept (user-only, outside the repository).
dl_token_cache() {
  local dir=${XDG_RUNTIME_DIR:-$DL_STATE}/dev-loop-tokens/$DL_REPO
  mkdir -p "$dir" && chmod 700 "$dir"
  printf '%s/%s.json\n' "$dir" "$1"
}

# dl_app_token ROLE: an installation token for the role's GitHub App, cached until 10 minutes before expiry.
dl_app_token() {
  local role=$1 app_id key_file installation jwt response cache token expires
  app_id=$(cfg "identities.$role.app_id" "")
  key_file=$(dl_resolve "$(cfg "identities.$role.key_file" "")")
  [ -n "$app_id" ] || dl_die "identities.$role.app_id is not set"
  [ -f "$key_file" ] || dl_die "the private key for $role is missing (identities.$role.key_file)"
  cache=$(dl_token_cache "$role")
  if [ -f "$cache" ]; then
    token=$(json_get token <"$cache")
    expires=$(json_get expires_epoch <"$cache")
    if [ -n "$token" ] && [ "${expires:-0}" -gt "$(($(date +%s) + 600))" ]; then
      printf '%s\n' "$token"
      return
    fi
  fi
  jwt=$(dl_app_jwt "$app_id" "$key_file") || dl_die "could not sign a JWT for $role"
  installation=$(cfg "identities.$role.installation_id" "")
  if [ -z "$installation" ]; then
    response=$(dl_api_call GET "/repos/$(dl_github_repo)/installation" "Bearer $jwt") ||
      dl_die "the $role app is not installed on $(dl_github_repo)"
    installation=$(printf '%s' "$response" | json_get id)
  fi
  response=$(dl_api_call POST "/app/installations/$installation/access_tokens" "Bearer $jwt") ||
    dl_die "could not mint an installation token for $role"
  token=$(printf '%s' "$response" | json_get token)
  [ -n "$token" ] || dl_die "no token in the installation token response for $role"
  (umask 077 && printf '{"token":"%s","expires_epoch":%s}\n' "$token" "$(($(date +%s) + 3600))" >"$cache")
  printf '%s\n' "$token"
}

# dl_role_token ROLE: the role's token (minted for an app, read from token_file for a machine user).
dl_role_token() {
  local role=$1 type token_file
  type=$(cfg "identities.$role.type" "")
  case "$type" in
    app) dl_app_token "$role" ;;
    token)
      token_file=$(dl_resolve "$(cfg "identities.$role.token_file" "")")
      [ -f "$token_file" ] || dl_die "the token file for $role is missing (identities.$role.token_file)"
      tr -d '[:space:]' <"$token_file"
      echo
      ;;
    "") dl_die "no identity configured for role $role" ;;
    *) dl_die "identities.$role.type must be \"app\" or \"token\" (got \"$type\")" ;;
  esac
}
