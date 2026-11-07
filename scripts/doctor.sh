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

# shellcheck source=lib/docs.sh
. "$scripts_dir/lib/docs.sh"

# doctor_docs: print the current-state docs config; report missing paths, files over docs.max_lines,
# planned rows that need care (docs.planned, docs.planned_max_days) and map rules that match no tracked file.
doctor_docs() {
  local name path max file lines i count names tracked days note
  max=$(cfg docs.max_lines 1000)
  case $max in "" | *[!0-9]* | 0) missing "docs.max_lines: \"$max\" is not a positive number"; max=1000 ;; esac
  while IFS=$'\t' read -r name path; do
    echo "        docs aspect   $name $path"
    if [ ! -e "$DL_ROOT/$path" ]; then
      missing "docs aspect $name: $path does not exist"
      continue
    fi
    while IFS= read -r file; do
      grep -Iq . "$file" 2>/dev/null || continue
      lines=$(wc -l <"$file" | tr -d ' ')
      [ "$lines" -gt "$max" ] &&
        optional "${file#"$DL_ROOT"/} has $lines lines, over docs.max_lines $max (split it: an index and one file per area)"
    done < <(find "$DL_ROOT/$path" -type f ! -path '*/.git/*' | LC_ALL=C sort)
  done < <(dl_docs_aspects)
  path=$(cfg docs.planned "")
  days=$(cfg docs.planned_max_days "")
  case $days in
    "") ;;
    *[!0-9]*) missing "docs.planned_max_days: \"$days\" is not a positive number"; days="" ;;
    *) days=$((10#$days)) && [ "$days" -gt 0 ] || days="" ;;
  esac
  if [ -n "$path" ]; then
    echo "        docs planned  $path"
    if [ -e "$DL_ROOT/$path" ]; then
      while IFS= read -r note; do optional "$note"; done < <(dl_docs_planned_notes "$path" "$days")
    else
      missing "docs.planned: $path does not exist"
    fi
  fi
  echo "        docs budget   max_lines $max"
  doctor_prd
  doctor_audit
  tracked=$(git -C "$DL_ROOT" ls-files)
  count=$(cfg_len docs.map)
  for ((i = 0; i < count; i++)); do
    names=$(dl_docs_rule_docs "$i" | paste -sd' ' -)
    echo "        docs map      $((i + 1)): $(dl_docs_rule_patterns "$i" | paste -sd' ' -) -> $names"
    while IFS= read -r name; do
      dl_docs_aspect_path "$name" >/dev/null || missing "docs.map rule $((i + 1)): \"$name\" is not in docs.aspects"
    done < <(dl_docs_rule_docs "$i")
    [ -n "$(printf '%s\n' "$tracked" | dl_docs_rule_matches "$i" | head -n 1)" ] ||
      optional "docs map rule $((i + 1)) ($(dl_docs_rule_patterns "$i" | paste -sd' ' -)) matches no tracked file"
  done
}

# doctor_prd: print the PRD or spec files (docs.prd) and report a missing one.
doctor_prd() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    echo "        docs prd      $path"
    [ -e "$DL_ROOT/$path" ] || missing "docs.prd: $path does not exist"
  done < <(dl_docs_prd)
}

# doctor_marker_time FILE LABEL: set marker_time to the UTC time in the marker FILE (empty without one);
# report a marker that holds no such time as MISSING, naming it LABEL.
doctor_marker_time() {
  marker_time=""
  [ -f "$1" ] || return 0
  marker_time=$(head -n 1 "$1")
  case $marker_time in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *)
      missing "$2 $1: \"$marker_time\" is not a UTC time like 2026-01-31T12:00:00Z"
      marker_time=""
      ;;
  esac
}

# doctor_audit: print the merges since the last doc audit (merge ledger and audit marker), note when an audit
# is due (docs.audit_every merges, default 10), and report a bad cadence or marker.
doctor_audit() {
  local every marker since merges
  every=$(cfg docs.audit_every 10)
  case $every in "" | *[!0-9]* | 0) missing "docs.audit_every: \"$every\" is not a positive number"; every=10 ;; esac
  marker=$(dl_doc_audit_file)
  doctor_marker_time "$marker" "doc audit marker"
  since=$marker_time
  merges=$(dl_ledger_count_since "$since")
  echo "        docs audit    $merges merges since the last audit (${since:-none recorded}; every $every)"
  [ "$merges" -ge "$every" ] &&
    optional "doc audit due: $merges merges since the last audit (run the doc-auditor, then record it: date -u +%Y-%m-%dT%H:%M:%SZ >$marker)"
}

# shellcheck source=lib/arch.sh
. "$scripts_dir/lib/arch.sh"

# doctor_arch: print the component map (by layer, sizes against budgets) of the working tree; report broken
# cards and a failing architecture.check as MISSING; note files in no component and the baseline size.
doctor_arch() {
  local cards baseline results layer name kind lines max entries
  cards=$(dl_arch_cards_dir)
  baseline=$(dl_arch_baseline_path)
  echo "        arch check    $(cfg architecture.check)"
  echo "        arch cards    $cards"
  dl_arch_budget >/dev/null || missing "architecture.budget: \"$(cfg architecture.budget "")\" is not a number"
  if [ ! -d "$DL_ROOT/$cards" ]; then
    missing "architecture.cards: $cards does not exist"
    return
  fi
  results=$(dl_arch_analyse "$DL_ROOT")
  while IFS=$'\t' read -r layer name kind lines max; do
    [ -n "$name" ] || continue
    if [ "$max" = - ]; then max=""; else max="/$max"; fi
    printf '        arch layer %-3s %-16s %-16s %s%s lines\n' "$layer" "$name" "$kind" "$lines" "$max"
  done < <(printf '%s\n' "$results" | dl_arch_tagged S | LC_ALL=C sort -t$'\t' -k1,1n -k2,2)
  [ -n "$(printf '%s\n' "$results" | dl_arch_tagged S)$(printf '%s\n' "$results" | dl_arch_tagged E)" ] ||
    missing "no component cards in $cards (a card is a Markdown file whose first line is ---; templates/COMPONENT.md)"
  while IFS= read -r line; do
    [ -n "$line" ] && missing "architecture: $line"
  done < <(printf '%s\n' "$results" | dl_arch_tagged E)
  while IFS= read -r line; do
    [ -n "$line" ] && optional "component over its line budget: $line"
  done < <(printf '%s\n' "$results" | dl_arch_tagged V | grep '^budget ')
  while IFS= read -r line; do
    [ -n "$line" ] && optional "no component: $line (add it to a card's paths, or leave it out of architecture.check)"
  done < <(printf '%s\n' "$results" | dl_arch_tagged N | LC_ALL=C sort -u)
  if [ -f "$DL_ROOT/$baseline" ]; then
    entries=$(grep -cv '^[[:space:]]*\(#.*\)\{0,1\}$' "$DL_ROOT/$baseline")
    optional "architecture baseline: $entries entries ($baseline)"
  else
    optional "architecture baseline: none yet (arch-check.sh --baseline writes $baseline)"
  fi
  doctor_architect
}

# doctor_architect: print the merges since the architect last ran (merge ledger and architect marker) and the
# evidence signals over their thresholds in that window (arch-evidence.sh); note when the architect is due
# (architecture.cadence merges, or a signal); report bad thresholds and a bad marker.
doctor_architect() {
  local cadence marker since merges signals line
  while IFS= read -r line; do
    [ -n "$line" ] && missing "$line"
  done < <(dl_arch_bad_thresholds)
  cadence=$(dl_arch_threshold cadence) || cadence=20
  marker=$(dl_architect_file)
  doctor_marker_time "$marker" "architect marker"
  since=$marker_time
  merges=$(dl_ledger_count_since "$since")
  echo "        arch architect  $merges merges since the architect last ran (${since:-none recorded}; every $cadence)"
  signals=$(dl_arch_evidence "$DL_ROOT" "${since:-$cadence}" | dl_arch_tagged F | cut -f1 | uniq -c |
    awk '{ printf "%s%s %s", sep, $2, $1; sep = ", " }')
  echo "        arch signals    ${signals:-none over their thresholds}"
  if [ "$merges" -ge "$cadence" ] || [ -n "$signals" ]; then
    optional "architect due: $merges merges since its last run, signals: ${signals:-none} (arch-evidence.sh, then the architect agent; record the run: date -u +%Y-%m-%dT%H:%M:%SZ >$marker)"
  fi
}

# shellcheck source=lib/scenarios.sh
. "$scripts_dir/lib/scenarios.sh"

# doctor_factory: print the operating mode and whether scenarios are on, marked (preset), (explicit) or
# (default); report a mode other than collaborative or dark. Silent without "factory".
doctor_factory() {
  local mode setting
  mode=$(cfg factory "")
  [ -n "$mode" ] || return 0
  case $mode in
    collaborative | dark) ;;
    *) missing "factory: \"$mode\" is not collaborative or dark" ;;
  esac
  setting=$(dl_scenarios_setting)
  echo "        factory       $(dl_factory), scenarios ${setting% *} (${setting#* })"
}

# doctor_scenarios: print the scenario store and its settings, the number of scenarios and of required ones;
# report bad thresholds and each invalid scenario file; note a store inside the repository or not yet made.
doctor_scenarios() {
  local dir key value file reason
  dir=$(dl_scenarios_dir)
  echo "        scenarios     $dir"
  [ "$(dl_factory)" = dark ] && ! dl_scenarios_ready "$dir" &&
    missing "factory dark: no scenario store with a valid required scenario in $dir (write scenarios from the spec, see the setup skill's go-dark step, or set \"scenarios\": false)"
  echo "        scenarios     run $(cfg scenarios.run none), judge $(cfg scenarios.judge "scenario-judge agent"), pass $(cfg scenarios.pass 0.8), min_satisfaction $(cfg scenarios.min_satisfaction 0.9), sealed $(cfg scenarios.sealed 0)"
  for key in pass min_satisfaction sealed; do
    value=$(cfg "scenarios.$key" "")
    [ -z "$value" ] || dl_scenarios_share_ok "$value" ||
      missing "scenarios.$key: \"$value\" is not a number from 0 to 1"
  done
  case "$dir/" in
    "$DL_ROOT"/*) optional "the scenario store $dir is inside the repository: the coding agents can read it (keep it outside, e.g. ~/.dev-loop/<repo>/scenarios)" ;;
  esac
  if [ ! -d "$dir" ]; then
    optional "scenario store $dir does not exist yet (create it and add scenarios like templates/scenario.md)"
    return
  fi
  echo "        scenarios     $(dl_scenarios_count "$dir") files, $(dl_scenarios_required_count "$dir") required"
  while IFS=$'\t' read -r file reason; do
    [ -n "$file" ] && missing "scenario $file: $reason"
  done < <(dl_scenarios_validate "$dir")
}

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
    if [ "$name" = affected ] || { [ "$name" = scenarios ] && dl_scenarios_on; }; then
      missing "check name \"$name\" is reserved for the $name stage (rename the check)"
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
  agents="implementer code-reviewer test-engineer verifier doc-auditor architect"
  # The scenario agents are listed when scenarios are on or their model is set, so the line is unchanged without.
  { dl_scenarios_on || [ -n "$(cfg models.scenario-writer "")" ]; } && agents="$agents scenario-writer"
  { dl_scenarios_on || [ -n "$(cfg models.scenario-judge "")" ]; } && agents="$agents scenario-judge"
  for agent in $agents; do
    model=$(cfg "models.$agent" inherit)
    case $model in
      inherit | haiku | sonnet | opus | fable) models="${models:+$models }$agent=$model" ;;
      *) missing "models.$agent: \"$model\" is not one of inherit, haiku, sonnet, opus, fable" ;;
    esac
  done
  echo "        models        $models"
  dl_docs_on && doctor_docs
  dl_arch_on && doctor_arch
  doctor_factory
  dl_scenarios_on && doctor_scenarios
  if [ -f "$DL_ROOT/CLAUDE.md" ]; then ok "CLAUDE.md"; elif [ -f "$DL_ROOT/.claude/CLAUDE.md" ]; then
    ok ".claude/CLAUDE.md"
  else missing "CLAUDE.md or .claude/CLAUDE.md (run the setup skill)"; fi
  if [ -f "$DL_ROOT/docs/DECISIONS.md" ]; then ok "docs/DECISIONS.md"; else optional "no docs/DECISIONS.md"; fi
  # Leftovers of a hand-built loop (the setup skill's "Migrate" step removes them).
  for agent in implementer code-reviewer test-engineer verifier doc-auditor architect scenario-judge; do
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
    [[ "$ref" == train-* || "$ref" == replay-* ]] && [[ "$live" != *" ${ref#*-} "* ]] && dl_loop_branch "${ref#*-}" &&
      echo "$ref"
  done | wc -l)
  merged_local=$(printf '%s\n' "$locals" | grep -cxF -f <(dl_ledger_heads) 2>/dev/null)
  if [ "$helpers" -gt 0 ] || [ "${merged_local:-0}" -gt 0 ]; then
    optional "$helpers train/replay refs outside a live train, ${merged_local:-0} merged branches still local (cleanup.sh)"
  fi
  if [ "$(printf '%s\n' "$locals" | wc -l)" -gt 200 ]; then
    optional "$(printf '%s\n' "$locals" | wc -l | tr -d ' ') local branches: cleanup.sh classifies them (dry run)"
  fi
  stale=$(find "$DL_ROOT/.claude/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  [ "$stale" -gt 0 ] && optional "$stale agent worktrees in .claude/worktrees (remove the merged ones)"
fi
[ "$problems" -eq 0 ] && echo "doctor: ready" || echo "doctor: $problems problem(s)"
[ "$problems" -eq 0 ]
