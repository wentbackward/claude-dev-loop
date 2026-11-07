#!/usr/bin/env bash
# Merge the permission rules the loop needs into the project's Claude Code settings, only adding: the template's
# and the project's rules into .claude/settings.json, the plugin-script rules (this machine's plugin path) into
# .claude/settings.local.json. A dry run by default; --apply writes.
#
# Usage: permissions.sh [--apply]
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
# shellcheck source=lib/permissions.sh
. "$scripts_dir/lib/permissions.sh"

# perm_missing FILE KIND: the wanted rules of KIND that FILE lacks, "<list><TAB><rule>" lines, once each.
perm_missing() {
  local list rule
  while IFS=$'\t' read -r list rule; do
    dl_perm_rules "$1" "$list" | grep -qxF -- "$rule" || printf '%s\t%s\n' "$list" "$rule"
  done < <(dl_perm_wanted "$root" "$2") | awk '!seen[$0]++'
}

# perm_add_json MISSING: the missing rules as {"allow": [...], "ask": [...], "deny": [...]} (lists with rules only).
perm_add_json() {
  local list out=""
  for list in allow ask deny; do
    [ -n "$(printf '%s\n' "$1" | awk -F'\t' -v l="$list" '$1 == l')" ] || continue
    out="${out:+$out,}\"$list\":$(printf '%s\n' "$1" | awk -F'\t' -v l="$list" '$1 == l { print $2 }' | dl_json_list)"
  done
  printf '{%s}' "$out"
}

# perm_merge FILE ADD_JSON: append the ADD_JSON lists to FILE's permissions, keeping every other key and rule.
perm_merge() {
  local tmp="$1.dev-loop.tmp"
  if dl_have_jq; then
    jq --argjson add "$2" '.permissions = ((.permissions // {}) as $p
      | reduce ($add | keys_unsorted[]) as $k ($p; .[$k] = ((.[$k] // []) + $add[$k])))' "$1" >"$tmp"
  else
    python3 -I -c '
import json, sys
settings = json.load(open(sys.argv[1]))
permissions = settings.setdefault("permissions", {})
for key, rules in json.loads(sys.argv[2]).items():
    permissions[key] = (permissions.get(key) or []) + rules
sys.stdout.write(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
' "$1" "$2" >"$tmp"
  fi && cat "$tmp" >"$1"
  local status=$?
  rm -f "$tmp"
  return $status
}

apply=""
case ${1:-} in
  --apply) apply=yes ;;
  "") ;;
  *) dl_die "usage: permissions.sh [--apply]" ;;
esac
dl_load_config
[ -n "$DL_ROOT" ] || dl_die "not inside a git repository"
root=$(cd "$scripts_dir/.." && pwd)
total=0
status=0
for kind in shared local; do
  rel=.claude/settings.json
  [ "$kind" = local ] && rel=.claude/settings.local.json
  file="$DL_ROOT/$rel"
  if [ -f "$file" ] && ! dl_perm_valid "$file"; then
    dl_warn "$rel is not a JSON object with a permissions object; left unchanged"
    status=2
    continue
  fi
  missing=$(perm_missing "$file" "$kind")
  [ -n "$missing" ] || continue
  printf '%s\n' "$missing" | awk -F'\t' -v f="$rel" '{ printf "%s: + %s %s\n", f, $1, $2 }'
  total=$((total + $(printf '%s\n' "$missing" | wc -l)))
  [ -n "$apply" ] || continue
  mkdir -p "$DL_ROOT/.claude"
  [ -f "$file" ] || echo '{}' >"$file"
  perm_merge "$file" "$(perm_add_json "$missing")" || { dl_warn "could not write $rel"; status=2; }
done
# The local file holds this machine's plugin path: keep it out of git.
if [ -n "$apply" ] && [ -f "$DL_ROOT/.claude/settings.local.json" ] &&
  ! git -C "$DL_ROOT" check-ignore -q .claude/settings.local.json; then
  [ -n "$(tail -c 1 "$DL_ROOT/.gitignore" 2>/dev/null)" ] && echo >>"$DL_ROOT/.gitignore"
  echo ".claude/settings.local.json" >>"$DL_ROOT/.gitignore"
  echo ".gitignore: + .claude/settings.local.json"
fi
if [ "$total" -eq 0 ]; then
  echo "permissions: complete"
elif [ -n "$apply" ]; then
  echo "permissions: added $total rules"
else
  echo "permissions: $total rules to add (dry run; --apply writes them)"
fi
exit "$status"
