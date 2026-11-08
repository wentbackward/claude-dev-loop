#!/usr/bin/env bash
# The plugin's marketplace as Claude Code sees it: the extraKnownMarketplaces entries in the user, managed
# and project settings, the marketplace Claude Code configured, and the installed version. Read only, and
# only these entries: no other settings content is ever printed. Needs common.sh (json_get).

# dl_mp_plugin_root: the plugin's own folder (the parent of scripts/).
dl_mp_plugin_root() {
  (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
}

# dl_mp_name: the marketplace's name, from the plugin's marketplace.json (default claude-dev-loop).
dl_mp_name() {
  local name
  name=$(json_get name <"$(dl_mp_plugin_root)/.claude-plugin/marketplace.json" 2>/dev/null)
  printf '%s\n' "${name:-claude-dev-loop}"
}

# dl_mp_plugin_id: the installed plugin's id, <plugin>@<marketplace>.
dl_mp_plugin_id() {
  local name
  name=$(json_get name <"$(dl_mp_plugin_root)/.claude-plugin/plugin.json" 2>/dev/null)
  printf '%s@%s\n' "${name:-dev-loop}" "$(dl_mp_name)"
}

# dl_mp_claude_dir: Claude Code's user folder (DEV_LOOP_CLAUDE_DIR, else CLAUDE_CONFIG_DIR, else ~/.claude).
dl_mp_claude_dir() {
  printf '%s\n' "${DEV_LOOP_CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
}

# dl_mp_managed_settings: the managed settings file of this OS (DEV_LOOP_MANAGED_SETTINGS overrides it).
dl_mp_managed_settings() {
  if [ -n "${DEV_LOOP_MANAGED_SETTINGS:-}" ]; then
    printf '%s\n' "$DEV_LOOP_MANAGED_SETTINGS"
  elif [ "$(uname -s)" = Darwin ]; then
    printf '%s\n' "/Library/Application Support/ClaudeCode/managed-settings.json"
  else
    printf '%s\n' "/etc/claude-code/managed-settings.json"
  fi
}

# dl_mp_source FILE PATH: print "<kind>\t<repo, url or path>\t<ref>" of the marketplace source object at
# the dotted PATH of the JSON FILE; nothing when the file or the source is missing.
dl_mp_source() {
  local json kind loc ref
  [ -f "$1" ] && [ -r "$1" ] || return 0
  json=$(json_get "$2" <"$1" 2>/dev/null)
  [ -n "$json" ] || return 0
  kind=$(dl_mp_field "$json" source)
  loc=$(dl_mp_field "$json" repo)
  [ -n "$loc" ] || loc=$(dl_mp_field "$json" url)
  [ -n "$loc" ] || loc=$(dl_mp_field "$json" path)
  ref=$(dl_mp_field "$json" ref)
  [ -n "$kind$loc" ] && printf '%s\t%s\t%s\n' "$kind" "$loc" "$ref"
  return 0
}

# dl_mp_field JSON KEY: the value of KEY in the JSON object, without tabs, carriage returns or newlines (so
# a value can never split a doctor line).
dl_mp_field() {
  printf '%s' "$1" | json_get "$2" | tr -d '\t\r\n'
}

# dl_mp_add_arg KIND LOCATOR REF: the argument of `claude plugin marketplace add` for that source
# (owner/repo@ref for GitHub, url#ref for a git URL, the path otherwise).
dl_mp_add_arg() {
  if [ -z "$3" ]; then
    printf '%s\n' "$2"
  elif [ "$1" = github ]; then
    printf '%s@%s\n' "$2" "$3"
  else
    printf '%s#%s\n' "$2" "$3"
  fi
}

# dl_mp_installed_version ROOT: the highest version of this plugin installed at user scope or for the
# project ROOT, from Claude Code's installed_plugins.json; nothing when none.
dl_mp_installed_version() {
  local file id i scope project version best="" real
  file="$(dl_mp_claude_dir)/plugins/installed_plugins.json"
  [ -f "$file" ] && [ -r "$file" ] || return 0
  id=$(dl_mp_plugin_id)
  real=$(cd "$1" 2>/dev/null && pwd -P)
  for ((i = 0; ; i++)); do
    scope=$(json_get "plugins.$id.$i.scope" <"$file")
    [ -n "$scope" ] || break
    project=$(json_get "plugins.$id.$i.projectPath" <"$file")
    version=$(json_get "plugins.$id.$i.version" <"$file" | tr -d '\t\r\n')
    [ "$scope" = user ] || [ "$project" = "$1" ] || [ "$project" = "$real" ] || continue
    if [ -z "$best" ] || dl_version_older "$best" "$version"; then best=$version; fi
  done
  [ -n "$best" ] && printf '%s\n' "$best"
  return 0
}

# dl_version_older A B: true when version A (a leading v is ignored) is older than B; false when either is
# not a dotted number.
dl_version_older() {
  awk -v a="${1#v}" -v b="${2#v}" 'BEGIN {
    if (a !~ /^[0-9]+(\.[0-9]+)*$/ || b !~ /^[0-9]+(\.[0-9]+)*$/) exit 1
    n = split(a, x, "."); m = split(b, y, "."); if (m > n) n = m
    for (i = 1; i <= n; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1
  }'
}
