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

command -v git >/dev/null 2>&1 && ok "git $(git --version | cut -d' ' -f3)" || missing "git"
if command -v jq >/dev/null 2>&1; then ok "jq"; elif command -v python3 >/dev/null 2>&1; then
  optional "jq not found: JSON is read with python3"
else missing "jq or python3 (to read .dev-loop.json)"; fi
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then ok "gh (authenticated)"; else missing "gh is not logged in (gh auth login)"; fi
else missing "gh (GitHub CLI) for issues and PRs"; fi
command -v flock >/dev/null 2>&1 && ok "flock" || optional "flock not found: heavy.sh uses lock directories"
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
  [ -n "$(json_get "" <"$DL_CONFIG")" ] && ok "valid JSON" || missing "valid JSON in $DL_CONFIG"
  [ "$(cfg_len checks)" -gt 0 ] && ok "$(cfg_len checks) gate checks" || missing "\"checks\" in $DL_CONFIG"
  git -C "$DL_ROOT" remote get-url "$DL_REMOTE" >/dev/null 2>&1 && ok "remote $DL_REMOTE" || missing "git remote $DL_REMOTE"
  echo "        base branch   $DL_BASE"
  echo "        gate worktree $(dl_gate_dir)"
  echo "        notes         $(dl_notes_dir)"
  echo "        logs          $(dl_logs_dir)"
  echo "        heavy slots   $(cfg heavy.slots 2), memory cap $(cfg heavy.memory_max none)"
  [ -f "$DL_ROOT/CLAUDE.md" ] && ok "CLAUDE.md" || missing "CLAUDE.md (run the setup skill)"
  [ -f "$DL_ROOT/docs/DECISIONS.md" ] && ok "docs/DECISIONS.md" || optional "no docs/DECISIONS.md"
fi
[ "$problems" -eq 0 ] && echo "doctor: ready" || echo "doctor: $problems problem(s)"
[ "$problems" -eq 0 ]
