#!/usr/bin/env bash
# Print the dev-loop paths of the current repository, so prompts and notes use absolute paths.
#
# Usage: paths.sh notes <branch> | notes-dir | logs | events | gate | state | doc-audit | architect | scenarios | config | root
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
# shellcheck source=lib/scenarios.sh
. "$scripts_dir/lib/scenarios.sh"

dl_load_config
[ -n "$DL_ROOT" ] || dl_die "not inside a git repository"
case "${1:-}" in
  notes)
    [ -n "${2:-}" ] || dl_die "usage: paths.sh notes <branch>"
    mkdir -p "$(dl_notes_dir)"
    dl_note_file "$2"
    ;;
  notes-dir) dl_notes_dir ;;
  logs) dl_logs_dir ;;
  events) dl_events_file ;;
  gate) dl_gate_dir ;;
  state) printf '%s\n' "$DL_STATE" ;;
  doc-audit)
    mkdir -p "$DL_STATE"
    dl_doc_audit_file
    ;;
  architect)
    mkdir -p "$DL_STATE"
    dl_architect_file
    ;;
  scenarios) dl_scenarios_dir ;;
  config) printf '%s\n' "$DL_CONFIG" ;;
  root) printf '%s\n' "$DL_ROOT" ;;
  *) dl_die "usage: paths.sh notes <branch> | notes-dir | logs | events | gate | state | doc-audit | architect | scenarios | config | root" ;;
esac
