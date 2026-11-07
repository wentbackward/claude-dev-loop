# shellcheck shell=bash
# Permission rules the loop needs in Claude Code settings: the rules of templates/settings.json, the project's
# own commands (.dev-loop.json), and the plugin's scripts at this machine's plugin path. Shared by
# permissions.sh (which merges them into the project's settings) and doctor.sh (which checks them).
# Needs common.sh. Rules follow the Claude Code syntax: Bash(<command>), where * matches any text (spaces
# and slashes too) and a trailing ":*" is the same as a trailing " *" (see docs/DECISIONS.md).

# The plugin scripts the loop runs through the Bash tool with any arguments. heavy.sh and as-role.sh run the
# command they are given, so they get exact rules for the loop's own uses only (dl_perm_plugin_rules).
DL_PERM_SCRIPTS="gate-train merge-train doctor cleanup paths docs-check docs-archive arch-check arch-evidence
open-pr repush permissions"

# dl_perm_valid FILE: true when FILE holds a JSON object.
dl_perm_valid() {
  if dl_have_jq; then
    jq -e 'type == "object" and ((.permissions // {}) | type == "object")' "$1" >/dev/null 2>&1
  else
    python3 -I -c '
import json, sys
try:
    value = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if isinstance(value, dict) and isinstance(value.get("permissions") or {}, dict) else 1)
' "$1" 2>/dev/null
  fi
}

# dl_perm_rules FILE LIST: the string rules of permissions.LIST (allow, ask, deny) in FILE, one per line;
# nothing for a missing or invalid file.
dl_perm_rules() {
  [ -f "$1" ] || return 0
  if dl_have_jq; then
    jq -r --arg l "$2" 'try (.permissions[$l][] | strings) catch empty' "$1" 2>/dev/null
  else
    python3 -I -c '
import json, sys
try:
    rules = json.load(open(sys.argv[1]))["permissions"][sys.argv[2]]
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(0)
for rule in rules if isinstance(rules, list) else []:
    if isinstance(rule, str):
        print(rule)
' "$1" "$2" 2>/dev/null
  fi
}

# dl_perm_match RULE COMMAND: true when the Bash permission RULE matches the single COMMAND (Bash and Bash(*)
# match all; other tools' rules match nothing).
dl_perm_match() {
  local body pat stars
  case $1 in
    Bash | "Bash()" | "Bash(*)") return 0 ;;
    "Bash("*")") body=${1#Bash(} && body=${body%)} ;;
    *) return 1 ;;
  esac
  case $body in *:\*) body="${body%:\*} *" ;; esac
  stars=${body//[^*]/}
  # A trailing " *" that is the rule's only wildcard also matches the bare command.
  [ "${#stars}" -eq 1 ] && [ "${body% \*}" != "$body" ] && [ "$2" = "${body% \*}" ] && return 0
  pat=${body//\\/\\\\}
  pat=${pat//\?/\\?}
  pat=${pat//\[/\\[}
  pat=${pat//\]/\\]}
  # shellcheck disable=SC2053  # the rule is a pattern on purpose
  [[ $2 == $pat ]]
}

# dl_perm_decision COMMAND FILE...: deny, ask, allow or none for COMMAND under the rules of the FILEs, in
# Claude Code's order (any deny, then any ask, then any allow).
dl_perm_decision() {
  local cmd=$1 list file rule
  shift
  for list in deny ask allow; do
    for file in "$@"; do
      while IFS= read -r rule; do
        dl_perm_match "$rule" "$cmd" && { echo "$list"; return 0; }
      done < <(dl_perm_rules "$file" "$list")
    done
  done
  echo none
}

# dl_perm_script_dir ROOT: the scripts directory of the plugin at ROOT as a rule pattern. In the plugin cache
# (.../dev-loop/<version>) the version is a wildcard, so the rules outlive plugin updates.
dl_perm_script_dir() {
  if [ "$(basename "$(dirname "$1")")" = dev-loop ]; then
    printf '%s/*/scripts\n' "$(dirname "$1")"
  else
    printf '%s/scripts\n' "$1"
  fi
}

# dl_perm_split COMMAND: the simple commands of a compound COMMAND (split on && || ; | &), one per line,
# without surrounding spaces, subshell parentheses, braces or "!" (Claude Code checks each one).
dl_perm_split() {
  printf '%s\n' "$1" | awk '{
    gsub(/\|\||&&|\|&|;|\||&/, "\n")
    n = split($0, parts, "\n")
    for (i = 1; i <= n; i++) {
      s = parts[i]
      while (s ~ /^[ \t({!]/) s = substr(s, 2)
      while (s ~ /[ \t)}]$/) s = substr(s, 1, length(s) - 1)
      if (s != "") print s
    }
  }'
}

# dl_perm_project_commands: the simple commands of the project's fast_check and checks, one per line, once each.
dl_perm_project_commands() {
  local i command
  {
    [ -n "$(cfg fast_check "")" ] && dl_perm_split "$(cfg fast_check)"
    for ((i = 0; i < $(cfg_len checks); i++)); do
      case $(cfg "checks.$i" "") in
        "{"*) command=$(cfg "checks.$i.command" "") ;;
        *) command=$(cfg "checks.$i" "") ;;
      esac
      [ -n "$command" ] && dl_perm_split "$command"
    done
  } | awk '!seen[$0]++'
}

# dl_perm_feature_patterns: the loop's branch patterns (github.feature_patterns, default feat/* fix/* chore/*
# docs/*), one per line.
dl_perm_feature_patterns() {
  local i count
  count=$(cfg_len github.feature_patterns)
  [ "$count" -eq 0 ] && { printf '%s\n' 'feat/*' 'fix/*' 'chore/*' 'docs/*'; return; }
  for ((i = 0; i < count; i++)); do cfg "github.feature_patterns.$i"; done
}

# dl_perm_project_rules: "<list><TAB><rule>" lines for the project's shared settings beyond the template: the
# one exact push the loop makes (the checked-out branch to the remote; a wildcard would also allow any extra
# argument), prompts for a push that names the base branch or deletes a loop branch, and one exact rule per
# project command. No rule ends in ":*", which Claude Code reads as a trailing " *".
dl_perm_project_rules() {
  local pattern command
  printf 'allow\tBash(git push -u %s HEAD)\n' "$DL_REMOTE"
  printf 'ask\tBash(*git*push* %s)\nask\tBash(*git*push* %s *)\n' "$DL_BASE" "$DL_BASE"
  printf 'ask\tBash(*git*push*:%s)\nask\tBash(*git*push*:%s *)\n' "$DL_BASE" "$DL_BASE"
  while IFS= read -r pattern; do
    [ "$pattern" = "*" ] || printf 'ask\tBash(*git*push* :%s)\n' "$pattern"
  done < <(dl_perm_feature_patterns)
  while IFS= read -r command; do
    printf 'allow\tBash(%s)\n' "$command"
  done < <(dl_perm_project_commands)
}

# dl_perm_template_rules TEMPLATE: "<list><TAB><rule>" lines of the template's allow, ask and deny rules.
dl_perm_template_rules() {
  local list rule
  for list in allow ask deny; do
    while IFS= read -r rule; do printf '%s\t%s\n' "$list" "$rule"; done < <(dl_perm_rules "$1" "$list")
  done
}

# dl_perm_plugin_rules ROOT: "<list><TAB><rule>" lines for the plugin's scripts (with and without arguments),
# heavy.sh with each project command, as-role.sh with the implementer's push, and a prompt for
# cleanup.sh --apply (it deletes branches).
dl_perm_plugin_rules() {
  local dir name command
  dir=$(dl_perm_script_dir "$1")
  for name in $DL_PERM_SCRIPTS; do
    printf 'allow\tBash(%s/%s.sh)\nallow\tBash(%s/%s.sh *)\n' "$dir" "$name" "$dir" "$name"
  done
  while IFS= read -r command; do
    printf 'allow\tBash(%s/heavy.sh %s)\n' "$dir" "$command"
  done < <(dl_perm_project_commands)
  printf 'allow\tBash(%s/as-role.sh implementer git push -u %s HEAD)\n' "$dir" "$DL_REMOTE"
  printf 'ask\tBash(%s/cleanup.sh *--apply*)\n' "$dir"
}

# dl_perm_wanted ROOT KIND: the rules the loop needs in the shared (.claude/settings.json) or local
# (.claude/settings.local.json, which holds this machine's plugin path) settings, "<list><TAB><rule>" lines.
dl_perm_wanted() {
  case $2 in
    shared)
      dl_perm_template_rules "$1/templates/settings.json"
      dl_perm_project_rules
      ;;
    local) dl_perm_plugin_rules "$1" ;;
  esac
}

# dl_perm_loop_samples ROOT: commands the loop runs, one per line, to test deny rules against.
dl_perm_loop_samples() {
  local name
  printf '%s\n' "git fetch $DL_REMOTE" "git status --porcelain" "git log --oneline -3" \
    "git diff $DL_REMOTE/$DL_BASE...HEAD" "git worktree add ../wt -b feat/1-x $DL_REMOTE/$DL_BASE" \
    "git worktree list" "git rebase $DL_REMOTE/$DL_BASE" "git add -A" "git commit -m x" \
    "git push -u $DL_REMOTE HEAD" "gh issue view 1" "gh issue list --state open" "gh issue create --title x" \
    "gh issue comment 1 --body x" "gh pr view 1" "gh pr list" "gh pr create --title x" "gh pr comment 1 --body x"
  for name in $DL_PERM_SCRIPTS; do printf '%s/scripts/%s.sh\n' "$1" "$name"; done
  printf '%s/scripts/as-role.sh implementer git push -u %s HEAD\n' "$1" "$DL_REMOTE"
  dl_perm_project_commands | awk -v h="$1/scripts/heavy.sh" '{ print; print h " " $0 }'

}
