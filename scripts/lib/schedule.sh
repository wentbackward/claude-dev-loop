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

# dl_schedule_tz_warning: one line when schedule.timezone names no known zone (date then silently uses UTC,
# so items come due hours early or late); nothing otherwise.
dl_schedule_tz_warning() {
  local tz
  tz=$(dl_schedule_tz)
  dl_schedule_tz_ok "$tz" ||
    printf 'dev-loop: warning: schedule.timezone "%s" is not a known time zone, so the times below are read in UTC\n' "$tz"
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

# The awk date functions the schedule shares: days_from_civil and civil (Howard Hinnant) turn a date into a
# day number and back (the horizon of check), and weekday gives a date's day of the week (windows), with no
# date command, so GNU and BSD systems agree.
_DL_SCHEDULE_AWK_DAYS='
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
    # weekday DATE: 1 (Monday) to 7 (Sunday) for a "YYYY-MM-DD" date; day 0 (0000-03-01) was a Wednesday.
    function weekday(date) {
      return (day_number(substr(date, 1, 4) + 0, substr(date, 6, 2) + 0, substr(date, 9, 2) + 0) + 2) % 7 + 1
    }
'

# dl_schedule_windows: one "<name><TAB><spec>" line per window of schedule.windows, in config order; nothing
# without the key (a window tag is then only a label).
dl_schedule_windows() {
  [ -n "${DL_CONFIG:-}" ] && [ -f "$DL_CONFIG" ] || return 0
  if dl_have_jq; then
    jq -r '(.schedule.windows? // {}) | if type == "object" then to_entries[] | "\(.key)\t\(.value)" else empty end' \
      "$DL_CONFIG" 2>/dev/null
  else
    python3 -I -c '
import json, sys
try:
    schedule = json.load(open(sys.argv[1])).get("schedule")
    windows = schedule.get("windows") if isinstance(schedule, dict) else None
except (ValueError, AttributeError):
    sys.exit(0)
if isinstance(windows, dict):
    for name, spec in windows.items():
        print("%s\t%s" % (name, spec if isinstance(spec, str) else json.dumps(spec)))
' "$DL_CONFIG" 2>/dev/null
  fi
}

# dl_schedule_window_notes < rows: the window problems of the dl_schedule_rows rows on stdin, one
# tab-separated line each: "OUTSIDE<TAB><line><TAB><window><TAB><spec>" (the item's time is outside its
# window), "BADWINDOW<TAB><line><TAB><window><TAB><spec>" (its window does not parse), "UNKNOWN<TAB><line>
# <TAB><window>" (schedule.windows does not name it), and "BADWINDOW<TAB>0<TAB><name><TAB><spec>" once per
# malformed window. A window is "<days> <HH:MM>-<HH:MM>" in schedule.timezone: days "daily" or a comma list
# of Mon..Sun and ranges (Mon-Fri, Fri-Mon); from the start (inclusive) to the end (exclusive, 24:00 allowed);
# an end before the start runs past midnight into the next day. Nothing at all without schedule.windows.
dl_schedule_window_notes() {
  local windows
  windows=$(dl_schedule_windows)
  [ -n "$windows" ] || {
    cat >/dev/null
    return 0
  }
  DL_SCHEDULE_WINDOWS=$windows awk -F'\t' "$_DL_SCHEDULE_AWK_DAYS"'
    # day_index NAME: 1 (Mon) to 7 (Sun), 0 for anything else.
    function day_index(s,    i) {
      s = tolower(s)
      i = index("mon tue wed thu fri sat sun ", s " ")
      return (length(s) == 3 && i % 4 == 1) ? (i + 3) / 4 : 0
    }
    # clock_ok T END: T is a clock time HH:MM (24:00 too when END).
    function clock_ok(t, end) {
      if (t !~ /^[0-9][0-9]:[0-9][0-9]$/) return 0
      if (end && t == "24:00") return 1
      return substr(t, 1, 2) + 0 <= 23 && substr(t, 4, 2) + 0 <= 59
    }
    # parse NAME SPEC: 1 when SPEC is a window; sets on[NAME, day], from[NAME] and to[NAME].
    function parse(name, spec,    f, n, parts, k, a, b, d, range) {
      sub(/^[ \t]+/, "", spec); sub(/[ \t]+$/, "", spec)
      if (split(spec, f, /[ \t]+/) != 2 || split(f[2], range, "-") != 2) return 0
      if (!clock_ok(range[1], 0) || !clock_ok(range[2], 1) || range[1] == range[2]) return 0
      from[name] = range[1]; to[name] = range[2]
      if (tolower(f[1]) == "daily") { for (d = 1; d <= 7; d++) on[name, d] = 1; return 1 }
      n = split(f[1], parts, ",")
      for (k = 1; k <= n; k++) {
        if (split(parts[k], range, "-") > 2) return 0
        a = day_index(range[1]); b = (parts[k] ~ /-/) ? day_index(range[2]) : a
        if (!a || !b) return 0
        for (d = a; d != b; d = d % 7 + 1) on[name, d] = 1
        on[name, b] = 1
      }
      return 1
    }
    # inside NAME TIME: 1 when "YYYY-MM-DD HH:MM" is in the window (after midnight counts for the day before).
    function inside(name, t,    w, clock) {
      w = weekday(substr(t, 1, 10)); clock = substr(t, 12, 5)
      if (from[name] < to[name]) return on[name, w] && clock >= from[name] && clock < to[name]
      return (on[name, w] && clock >= from[name]) || (on[name, w == 1 ? 7 : w - 1] && clock < to[name])
    }
    BEGIN {
      OFS = "\t"
      n = split(ENVIRON["DL_SCHEDULE_WINDOWS"], lines, "\n")
      for (i = 1; i <= n; i++) {
        tab = index(lines[i], "\t")
        if (!tab) continue
        name = substr(lines[i], 1, tab - 1); spec[name] = substr(lines[i], tab + 1)
        good[name] = parse(name, spec[name])
        if (!good[name]) print "BADWINDOW", 0, name, spec[name]
      }
    }
    $1 == "MALFORMED" || $5 == "-" || NF < 6 { next }
    !($5 in spec) { print "UNKNOWN", $3, $5; next }
    !good[$5] { print "BADWINDOW", $3, $5, spec[$5]; next }
    !inside($5, $2) { print "OUTSIDE", $3, $5, spec[$5] }'
}

# dl_schedule_window_message KIND WINDOW SPEC: the warning for one window note (OUTSIDE or BADWINDOW).
dl_schedule_window_message() {
  case $1 in
    OUTSIDE) printf 'outside window %s (%s)\n' "$2" "$3" ;;
    BADWINDOW) printf 'window %s is not "<days> HH:MM-HH:MM" (days: daily, Mon..Sun, Mon-Fri, comma lists): "%s"\n' "$2" "$3" ;;
  esac
}

# dl_schedule_rows NOW DAYS [FILE, "-" for stdin]: one tab-separated row per pending item, sorted by time
# then line: class (OVERDUE: a day before today; DUE: today, at or before NOW; UPCOMING: after NOW, within
# DAYS days; LATER), time, line number, ticket, window, what. Malformed item lines come first, as
# "MALFORMED<TAB><line>".
dl_schedule_rows() {
  local file=${3:-$(dl_schedule_file)}
  [ "$file" = - ] || [ -f "$file" ] || return 0
  awk -v now="$1" -v days="$2" "$_DL_SCHEDULE_AWK_DAYS"'
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
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
