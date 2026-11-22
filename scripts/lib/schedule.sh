# shellcheck shell=bash
# The durable schedule of time-bound loop work (#111): one Markdown file per project, outside git
# (~/.dev-loop/<repo>/schedule.md), one line per item:
#   - YYYY-MM-DD HH:MM | #<ticket> | <window tag or -> | <what to do>
# in the time zone schedule.timezone (default: the machine's). A done item is kept as "- [x] ..."; any other
# line that starts with "- " and does not parse (a bad date, a missing field) is malformed and ignored. Times
# compare as zero-padded strings in that zone, so nothing needs date arithmetic on a clock time.
# Source scripts/lib/common.sh first and call dl_load_config.

# dl_schedule_on: true when the config has a "schedule" object (or true): the SessionStart hook, status.sh
# and doctor.sh then read the schedule. schedule.sh itself works either way.
dl_schedule_on() {
  case $(cfg schedule "") in "{"* | true) return 0 ;; *) return 1 ;; esac
}

# dl_schedule_file: the schedule file of this repository.
dl_schedule_file() {
  printf '%s/schedule.md\n' "$DL_STATE"
}

# dl_schedule_tz: the configured time zone, empty for the machine's own.
dl_schedule_tz() {
  cfg schedule.timezone ""
}

# dl_schedule_tz_ok ZONE: true when ZONE is empty (local) or names a zone file under /usr/share/zoneinfo
# (where that directory exists; elsewhere every name is accepted).
dl_schedule_tz_ok() {
  [ -z "$1" ] && return 0
  case $1 in /* | *..*) return 1 ;; esac
  [ -d /usr/share/zoneinfo ] || return 0
  [ -f "/usr/share/zoneinfo/$1" ]
}

# dl_schedule_days: how many days ahead "check" lists upcoming items (schedule.days, default 7).
dl_schedule_days() {
  local days
  days=$(cfg schedule.days 7)
  case $days in "" | *[!0-9]*) days=7 ;; esac
  printf '%s\n' "$((10#$days))"
}

# dl_schedule_now: the current time in the schedule's zone as "YYYY-MM-DD HH:MM" (DEV_LOOP_NOW, in that
# form, replaces the clock for tests).
dl_schedule_now() {
  local tz
  if [ -n "${DEV_LOOP_NOW:-}" ]; then
    printf '%s\n' "$DEV_LOOP_NOW"
    return 0
  fi
  tz=$(dl_schedule_tz)
  if [ -n "$tz" ]; then TZ=$tz date '+%Y-%m-%d %H:%M'; else date '+%Y-%m-%d %H:%M'; fi
}

# dl_schedule_rows NOW DAYS [FILE, "-" for stdin]: one tab-separated row per pending item, sorted by time
# then line: class (OVERDUE: a day before today; DUE: today, at or before NOW; UPCOMING: after NOW, within DAYS days;
# LATER), time, line number, ticket, window, what. Malformed item lines come first, as "MALFORMED<TAB><line>".
dl_schedule_rows() {
  local file=${3:-$(dl_schedule_file)}
  [ "$file" = - ] || [ -f "$file" ] || return 0
  awk -v now="$1" -v days="$2" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # days_from_civil and civil (Howard Hinnant), to find the last date of the horizon.
    function day_number(y, m, d,    era, yoe, doy, doe) {
      y -= (m <= 2); era = int(y / 400); yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe
    }
    function civil(z,    era, doe, yoe, y, doy, mp, d, m) {
      era = int(z / 146097); doe = z - era * 146097
      yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
      y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
      mp = int((5 * doy + 2) / 153); d = doy - int((153 * mp + 2) / 5) + 1
      m = mp < 10 ? mp + 3 : mp - 9
      return sprintf("%04d-%02d-%02d", y + (m <= 2), m, d)
    }
    # valid_time T: T is "YYYY-MM-DD HH:MM" and names a real date and clock time.
    function valid_time(t,    y, m, d) {
      if (t !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]$/) return 0
      y = substr(t, 1, 4) + 0; m = substr(t, 6, 2) + 0; d = substr(t, 9, 2) + 0
      if (m < 1 || m > 12 || d < 1 || substr(t, 12, 2) + 0 > 23 || substr(t, 15, 2) + 0 > 59) return 0
      return civil(day_number(y, m, d)) == substr(t, 1, 10)
    }
    BEGIN {
      today = substr(now, 1, 10)
      last = civil(day_number(substr(today, 1, 4) + 0, substr(today, 6, 2) + 0, substr(today, 9, 2) + 0) + days)
      OFS = "\t"
    }
    /^- \[[xX]\]/ { next }
    /^- / {
      n = split(substr($0, 3), f, "|")
      t = trim(f[1]); ticket = trim(f[2]); window = trim(f[3]); what = ""
      for (i = 4; i <= n; i++) what = what (i > 4 ? "|" : "") f[i]
      what = trim(what)
      if (n < 4 || !valid_time(t) || ticket !~ /^(#[0-9]+|-)$/ || window !~ /^[A-Za-z0-9_.-]+$/ || what == "") {
        print sprintf("0 %09d", NR), "MALFORMED", NR
        next
      }
      if (substr(t, 1, 10) < today) class = "OVERDUE"
      else if (t <= now) class = "DUE"
      else if (substr(t, 1, 10) <= last) class = "UPCOMING"
      else class = "LATER"
      print sprintf("1 %s %09d", t, NR), class, t, NR, ticket, window, what
    }' "$file" | LC_ALL=C sort | cut -f2-
}

# dl_schedule_line TIME TICKET WINDOW WHAT: the item as it is written in the file.
dl_schedule_line() {
  printf -- '- %s | %s | %s | %s\n' "$1" "$2" "$3" "$4"
}
