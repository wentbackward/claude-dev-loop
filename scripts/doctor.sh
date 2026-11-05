#!/usr/bin/env bash
# Check that this machine and repository have what the dev loop needs, and print the resolved config.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"

problems=0
ok() { echo "ok      $*"; }
missing() {
  echo "MISSING $*"
  problems=$((problems + 1))
}
optional() { echo "note    $*"; }

if command -v git >/dev/null 2>&1; then ok "git $(git --version | cut -d' ' -f3)"; else missing "git"; fi
if command -v jq >/dev/null 2>&1; then ok "jq"; elif command -v python3 >/dev/null 2>&1; then
  optional "jq not found: JSON is read with python3"
else missing "jq or python3 (to read .dev-loop.json)"; fi
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then ok "gh (authenticated)"; else missing "gh is not logged in (gh auth login)"; fi
else missing "gh (GitHub CLI) for issues and PRs"; fi
if command -v flock >/dev/null 2>&1; then ok "flock"; else optional "flock not found: heavy.sh uses lock directories"; fi
if command -v systemd-run >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  ok "systemd user scopes (heavy.memory_max is enforced)"
else optional "no systemd user manager: heavy.memory_max is not enforced"; fi

dl_load_config
if [ -z "$DL_ROOT" ]; then
  missing "a git repository (run inside the project)"
elif [ ! -f "$DL_CONFIG" ]; then
  missing "$DL_CONFIG (run the setup skill)"
else
  ok "config $DL_CONFIG"
  if [ -n "$(json_get "" <"$DL_CONFIG")" ]; then ok "valid JSON"; else missing "valid JSON in $DL_CONFIG"; fi
  if [ "$(cfg_len checks)" -gt 0 ]; then ok "$(cfg_len checks) gate checks"; else missing "\"checks\" in $DL_CONFIG"; fi
  for option in parallel fail_fast; do
    case $(cfg "$option" false) in
      true | false) ;;
      *) missing "$option: \"$(cfg "$option" "")\" is not true or false" ;;
    esac
  done
  affected=$(cfg affected "")
  case $affected in "{"*) affected=$(cfg affected.command "") ;; esac
  # Every stage needs its own name: the name is its log file (train-<name>.log).
  seen=""
  [ -n "$(cfg affected "")" ] && seen=$(cfg affected.name affected | sed 's/[^A-Za-z0-9_.-]/_/g')
  for ((i = 0; i < $(cfg_len checks); i++)); do
    case $(cfg "checks.$i" "") in
      "{"*) name=$(cfg "checks.$i.name" "check-$((i + 1))") ;;
      *) name="check-$((i + 1))" ;;
    esac
    if [ "$name" = affected ]; then
      missing "check name \"affected\" is reserved for the affected stage (rename the check)"
      continue
    fi
    log_name=${name//[^A-Za-z0-9_.-]/_}
    if printf '%s\n' "$seen" | grep -qxF -- "$log_name"; then
      missing "check name \"$name\" is used twice (the stages would share train-$log_name.log)"
    fi
    seen+=$'\n'"$log_name"
  done
  [ -n "$(cfg affected "")" ] && [ -z "$affected" ] && missing "affected: no \"command\""
  if [ "$(cfg parallel false)" = true ] && ! command -v setsid >/dev/null 2>&1 && ! command -v perl >/dev/null 2>&1; then
    missing "setsid or perl (\"parallel\": true runs each check in its own process group)"
  fi
  if git -C "$DL_ROOT" remote get-url "$DL_REMOTE" >/dev/null 2>&1; then ok "remote $DL_REMOTE"; else missing "git remote $DL_REMOTE"; fi
  echo "        base branch   $DL_BASE"
  echo "        gate worktree $(dl_gate_dir)"
  echo "        notes         $(dl_notes_dir)"
  echo "        logs          $(dl_logs_dir)"
  echo "        heavy slots   $(cfg heavy.slots 2), memory cap $(cfg heavy.memory_max none)"
  echo "        gate options  affected $([ -n "$affected" ] && echo on || echo off), parallel $(cfg parallel false), fail_fast $(cfg fail_fast false)"
  models=""
  for agent in implementer code-reviewer test-engineer verifier; do
    model=$(cfg "models.$agent" inherit)
    case $model in
      inherit | haiku | sonnet | opus | fable) models="${models:+$models }$agent=$model" ;;
      *) missing "models.$agent: \"$model\" is not one of inherit, haiku, sonnet, opus, fable" ;;
    esac
  done
  echo "        models        $models"
  if [ -f "$DL_ROOT/CLAUDE.md" ]; then ok "CLAUDE.md"; else missing "CLAUDE.md (run the setup skill)"; fi
  if [ -f "$DL_ROOT/docs/DECISIONS.md" ]; then ok "docs/DECISIONS.md"; else optional "no docs/DECISIONS.md"; fi
  # Leftovers of a hand-built loop (the setup skill's "Migrate" step removes them).
  for agent in implementer code-reviewer test-engineer verifier; do
    [ -f "$DL_ROOT/.claude/agents/$agent.md" ] &&
      missing ".claude/agents/$agent.md shadows the plugin's $agent agent (remove it, keep its project rules in CLAUDE.md)"
  done
  project_settings="$DL_ROOT/.claude/settings.json"
  if [ -f "$project_settings" ]; then
    for event in Stop PostToolUse; do
      [ -n "$(json_get "hooks.$event" <"$project_settings")" ] &&
        optional "project $event hooks in .claude/settings.json run besides the plugin's: check they are not a copy"
    done
  fi
  # Branch leftovers, counted without GitHub (cleanup.sh classifies every branch).
  live=" $(awk '{printf "%s ", $1}' "$(dl_train_file)" 2>/dev/null)$(cut -d' ' -f2- "$(dl_running_file)" 2>/dev/null) "
  locals=$(git -C "$DL_ROOT" for-each-ref --format='%(refname:strip=2) %(objectname)' refs/heads)
  helpers=$(printf '%s\n' "$locals" | while read -r ref _; do
    [[ "$ref" == train-* || "$ref" == replay-* ]] && [[ "$live" != *" ${ref#*-} "* ]] && echo "$ref"
  done | wc -l)
  merged_local=$(printf '%s\n' "$locals" | grep -cxF -f <(dl_ledger_heads) 2>/dev/null)
  if [ "$helpers" -gt 0 ] || [ "${merged_local:-0}" -gt 0 ]; then
    optional "$helpers train/replay refs outside a live train, ${merged_local:-0} merged branches still local (cleanup.sh)"
  fi
  [ "$(printf '%s\n' "$locals" | wc -l)" -gt 200 ] &&
    optional "$(printf '%s\n' "$locals" | wc -l | tr -d ' ') local branches: cleanup.sh classifies them (dry run)"
  stale=$(find "$DL_ROOT/.claude/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  [ "$stale" -gt 0 ] && optional "$stale agent worktrees in .claude/worktrees (remove the merged ones)"
fi
[ "$problems" -eq 0 ] && echo "doctor: ready" || echo "doctor: $problems problem(s)"
[ "$problems" -eq 0 ]
