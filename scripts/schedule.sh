#!/usr/bin/env bash
# The durable schedule of time-bound loop work: items that must happen at a set time (a check after a
# nightly job, a run while an external system is open, a re-measurement after a date). The file lives
# outside git (paths.sh schedule, ~/.dev-loop/<repo>/schedule.md) and survives restarts; the SessionStart
# hook runs "check" at every session start when .dev-loop.json has "schedule".
#
# Usage: schedule.sh add <YYYY-MM-DD> <HH:MM> <#ticket|-> <window|-> <what to do...>
#        schedule.sh done <line|#ticket>
#        schedule.sh list
#        schedule.sh check [--days <n>]
#
# One line per item: "- YYYY-MM-DD HH:MM | #<ticket> | <window tag or -> | <what to do>", in the time zone
# schedule.timezone (default: the machine's). add appends an item (once: the same item again is a no-op);
# done marks the item on that line, or every pending item of that ticket, "- [x] ..."; list prints every
# pending item with its line and class; check prints the OVERDUE (a day before today), DUE (today, at or
# before now) and UPCOMING (within schedule.days days, default 7, or --days) items and nothing when there
# are none. Malformed item lines are ignored, with a warning on stderr. DEV_LOOP_NOW="YYYY-MM-DD HH:MM"
# replaces the clock (tests). Exit: 0, 1 nothing to mark done, 2 usage.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"
dl_help "$0" "${1:-}"
# shellcheck source=lib/schedule.sh
. "$scripts_dir/lib/schedule.sh"

# usage_error MESSAGE: the message and the usage on stderr, exit 2.
usage_error() {
  echo "dev-loop: $1" >&2
  dl_usage "$0" >&2
  exit 2
}

# now_checked: the schedule's current time; a malformed DEV_LOOP_NOW is an error, not a silent wrong clock.
now_checked() {
  local now
  now=$(dl_schedule_now)
  case $now in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]) printf '%s\n' "$now" ;;
    *) dl_die "the current time \"$now\" is not YYYY-MM-DD HH:MM (DEV_LOOP_NOW?)" ;;
  esac
}

# rows [DAYS]: the classified pending items at $now; warns once on stderr about the malformed lines it skipped.
rows() {
  local all bad
  all=$(dl_schedule_rows "$now" "${1:-$(dl_schedule_days)}")
  bad=$(printf '%s\n' "$all" | awk -F'\t' '$1 == "MALFORMED" { s = s (s ? ", " : "") $2 } END { print s }')
  [ -z "$bad" ] || dl_warn "$(dl_schedule_file): malformed lines ignored: $bad"
  printf '%s\n' "$all" | grep -v '^MALFORMED' | grep . || true
}

# print_row CLASS TIME LINE TICKET WINDOW WHAT: one item for people and for the session context.
print_row() {
  printf '%-8s %s | %s | %s | %s (line %s)\n' "$1" "$2" "$4" "$5" "$6" "$3"
}

# schedule_add DATE TIME TICKET WINDOW WHAT...: append a valid item, once.
schedule_add() {
  [ $# -ge 5 ] || usage_error "add needs a date, a time, a ticket (or -), a window (or -) and what to do"
  local file time="$1 $2" ticket=$3 window=$4 what line
  file=$(dl_schedule_file)
  case $ticket in [0-9]*) ticket="#$ticket" ;; "") ticket=- ;; esac
  [ -n "$window" ] || window=-
  case $ticket$window in *"|"*) usage_error "the ticket and the window cannot hold \"|\" (the field separator)" ;; esac
  shift 4
  what="$*"
  case $what in *$'\n'* | *$'\r'*) usage_error "what to do must be one line" ;; esac
  line=$(dl_schedule_line "$time" "$ticket" "$window" "$what")
  # The item must read back as an item: the same parser as check, on the line alone.
  if printf '%s\n' "$line" | dl_schedule_rows "0000-01-01 00:00" 0 - | grep -q '^MALFORMED'; then
    usage_error "not a valid item: $line (date YYYY-MM-DD, time HH:MM, ticket #<n> or -, window a word or -)"
  fi
  mkdir -p "$(dirname "$file")" || dl_die "cannot create $(dirname "$file")"
  if [ -f "$file" ] && grep -qxF -- "$line" "$file"; then
    echo "already scheduled (line $(grep -nxF -- "$line" "$file" | head -n 1 | cut -d: -f1)): $line"
    return 0
  fi
  if [ ! -s "$file" ]; then
    {
      echo "# dev-loop schedule of $DL_REPO, time zone $(tz_name)."
      echo "# One line per item: - YYYY-MM-DD HH:MM | #ticket | window | what to do. Done items: - [x] ..."
      echo
    } >"$file" || dl_die "cannot write $file"
  fi
  printf '%s\n' "$line" >>"$file" || dl_die "cannot write $file"
  echo "scheduled (line $(wc -l <"$file" | tr -d ' ')): $line"
}

# tz_name: the configured zone, or "local".
tz_name() {
  local tz
  tz=$(dl_schedule_tz)
  printf '%s\n' "${tz:-local}"
}

# schedule_done LINE|#TICKET: mark that pending item, or every pending item of the ticket, done.
schedule_done() {
  [ $# -eq 1 ] && [ -n "$1" ] || usage_error "done needs one line number or #ticket"
  local file lines field target=$1
  file=$(dl_schedule_file)
  case $target in
    \#[0-9]*) field=4 ;;
    "" | *[!0-9]*) usage_error "done needs a line number or #ticket, not \"$target\"" ;;
    *) field=3 ;;
  esac
  lines=$(dl_schedule_rows "0000-01-01 00:00" 0 |
    awk -F'\t' -v f="$field" -v t="$target" '$1 != "MALFORMED" && $f == t { print $3 }')
  if [ -z "$lines" ]; then
    echo "dev-loop: no pending item matches $target in $file" >&2
    exit 1
  fi
  if ! awk -v lines=" $(printf '%s\n' "$lines" | tr '\n' ' ')" 'index(lines, " " NR " ") { sub(/^- /, "- [x] ") } { print }' \
    "$file" >"$file.new.$$" || ! mv "$file.new.$$" "$file"; then
    rm -f "$file.new.$$"
    dl_die "cannot write $file"
  fi
  for target in $lines; do echo "done (line $target): $(sed -n "${target}p" "$file")"; done
}

# schedule_list: every pending item, in time order, or a line saying there is none.
schedule_list() {
  local found="" class time line ticket window what
  while IFS=$'\t' read -r class time line ticket window what; do
    [ -n "$class" ] || continue
    found=yes
    print_row "$class" "$time" "$line" "$ticket" "$window" "$what"
  done < <(rows)
  [ -n "$found" ] || echo "no scheduled items ($(dl_schedule_file))"
}

# schedule_check [DAYS]: the overdue, due and upcoming items under one header line; nothing when none.
schedule_check() {
  local due
  due=$(rows "$1" | awk -F'\t' '$1 != "LATER"')
  [ -n "$due" ] || return 0
  echo "dev-loop schedule ($(dl_schedule_file), time zone $(tz_name), now $now):"
  printf '%s\n' "$due" | while IFS=$'\t' read -r class time line ticket window what; do
    print_row "$class" "$time" "$line" "$ticket" "$window" "$what"
  done
}

dl_load_config
[ -n "$DL_ROOT" ] || dl_die "not inside a git repository"
command=${1:-}
[ $# -eq 0 ] || shift
now=$(now_checked) || exit 2
case $command in
  add) schedule_add "$@" ;;
  done) schedule_done "$@" ;;
  list)
    [ $# -eq 0 ] || usage_error "list takes no arguments"
    schedule_list
    ;;
  check)
    days=$(dl_schedule_days)
    if [ "${1:-}" = --days ]; then
      case ${2:-} in "" | *[!0-9]*) usage_error "--days needs a whole number" ;; esac
      days=$((10#$2))
      shift 2
    fi
    [ $# -eq 0 ] || usage_error "unknown argument to check: $1"
    schedule_check "$days"
    ;;
  *) usage_error "unknown command \"$command\"" ;;
esac
