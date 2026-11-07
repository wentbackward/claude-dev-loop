#!/usr/bin/env bash
# What is the loop doing? The gate, the heavy slots, the loop worktrees, the last merge, the open tickets,
# the orchestrator's last event and a verdict, from any terminal or session, without waking the session.
#
# Usage: status.sh [--json] [--no-gh]
#
# Read-only: it reads files (train-running.txt, the event logs, the stage logs, the notes, the ledger) and
# git, and asks `gh` for the open tickets unless --no-gh. It never writes, signals or locks anything (a
# process is "alive" when `ps -p` lists it; a slot is "held" when its slot-acquired event has no release
# and its pid is alive). The heavy slots are read from the event logs of every repository under
# ~/.dev-loop (DEV_LOOP_HOME), since the slots are shared machine-wide.
#
# The last line is the verdict:
#   verdict: idle                                      no gate, no heavy job of this repository, no loop
#                                                      worktree with unmerged work, no orchestrator event
#                                                      within the threshold ("idle (the last gate died:
#                                                      train-running.txt is stale)" when its pid has ended)
#   verdict: working                                   activity within the threshold
#   verdict: waiting on <what> (output <n>s ago)       a running gate stage, a heavy job of this repository,
#                                                      or an orchestrator event whose name starts with
#                                                      "waiting" (what: its detail, else the rest of the name)
#   verdict: possibly stalled: no event or output for <n> min
# "Output" is the newest of: this repository's events, the running stage logs, train-running.txt, and the
# commits and notes files of the loop worktrees; while the gate runs, only the gate-side evidence (stage
# logs, train-running.txt, this repository's gate events), so other work (an implementer's commits or
# heavy jobs) never hides a frozen stage. Other repositories' events never count. The threshold is watchdog.stall_minutes (default 30).
#
# --json prints one object (the contract; fields are only added, never renamed):
#   {"repo", "now" (UTC),
#    "verdict": {"state": "idle|working|waiting|stalled", "what": str|null, "quiet_seconds": n|null,
#                "stall_minutes": n, "line": str, "gate_died": bool},
#    "gate": {"running": bool, "stale": bool (train-running.txt names a dead pid), "pid": n|null,
#             "train": [branch], "elapsed_seconds": n|null,
#             "stages": [{"name", "elapsed_seconds", "log", "log_bytes", "quiet_seconds"}]},
#    "heavy": {"slots": n, "held": [{"slot", "pid", "repo", "seconds", "command"}],
#              "waiting": [{"pid", "repo", "seconds", "command"}]},
#    "worktrees": [{"branch", "path", "ticket", "merged", "commit_age_seconds", "notes_age_seconds",
#                   "pushed", "unpushed_commits", "ahead", "behind"}],
#    "last_merge": {"branch", "ticket", "merged_at", "age_seconds"}|null, "open_tickets": n|null,
#    "orchestrator": {"event", "detail", "ticket", "age_seconds"}|null}
# Exit: 0, 2 usage or not in a repository.
set -u
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$scripts_dir/lib/common.sh"

json="" use_gh=yes
for arg in "$@"; do
  case $arg in
    --json) json=yes ;;
    --no-gh) use_gh="" ;;
    *) dl_die "usage: status.sh [--json] [--no-gh]" ;;
  esac
done
dl_load_config
[ -n "$DL_ROOT" ] || dl_die "not inside a git repository"
now=$(date +%s)
stall_minutes=$(cfg watchdog.stall_minutes 30)
case $stall_minutes in "" | *[!0-9]*) stall_minutes=30 ;; esac
stall_minutes=$((10#$stall_minutes))

# alive PID: true when the process exists (ps, so nothing is signalled).
alive() {
  case ${1:-} in "" | *[!0-9]*) return 1 ;; esac
  ps -p "$1" >/dev/null 2>&1
}

# file_info FILE: "<seconds since it changed> <bytes>" (nothing when the file is missing or neither python3
# nor perl can read its time).
file_info() {
  [ -e "$1" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 -I -c '
import os, sys, time
s = os.stat(sys.argv[1])
print(max(0, int(time.time() - s.st_mtime)), s.st_size)' "$1" 2>/dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -e '@s = stat($ARGV[0]) or exit 0; $a = time - $s[9]; print(($a < 0 ? 0 : $a), " ", $s[7], "\n")' "$1"
  fi
}

# iso_epoch TIME: the seconds since 1970 of a UTC time like 2026-01-31T12:00:00Z (nothing if not one).
iso_epoch() {
  if dl_have_jq; then
    jq -n -r --arg t "$1" '$t | try fromdateiso8601 catch empty' 2>/dev/null
  else
    python3 -I -c '
import calendar, sys, time
try:
    print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))
except ValueError:
    pass' "$1" 2>/dev/null
  fi
}

# events_tsv FILE...: each event of the files as "repo<TAB>epoch<TAB>who<TAB>event<TAB>branch<TAB>ticket
# <TAB>stage<TAB>rc<TAB>slot<TAB>pid<TAB>log<TAB>detail" (repo: the name of the file's directory; "-" for a
# missing field; lines that are not JSON objects are skipped).
events_tsv() {
  [ $# -gt 0 ] || return 0
  if dl_have_jq; then
    jq -R -r 'def f: if . == null or . == "" then "-" else tostring | gsub("[\t\n\r]"; " ") end;
      (input_filename | split("/") | .[-2]) as $repo | fromjson? | select(type == "object")
      | [$repo, (.t | strings | try fromdateiso8601 catch null), .who, .event, .branch, .ticket, .stage, .rc,
         .slot, .pid, .log, .detail] | map(f) | join("\t")' "$@" 2>/dev/null
  else
    python3 -I -c '
import calendar, json, os, sys, time
def f(value):
    if value is None or value == "":
        return "-"
    return str(value).replace("\t", " ").replace("\n", " ").replace("\r", " ")
sys.stdout.reconfigure(errors="replace")
for path in sys.argv[1:]:
    repo = os.path.basename(os.path.dirname(path))
    try:
        lines = open(path, encoding="utf-8", errors="replace").readlines()
    except OSError:
        continue
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict):
            continue
        try:
            epoch = calendar.timegm(time.strptime(str(e.get("t")), "%Y-%m-%dT%H:%M:%SZ"))
        except ValueError:
            epoch = None
        keys = ("who", "event", "branch", "ticket", "stage", "rc", "slot", "pid", "log", "detail")
        print("\t".join(f(v) for v in [repo, epoch] + [e.get(k) for k in keys]))
' "$@" 2>/dev/null
  fi
}

# dur SECONDS: a short duration (45s, 12m, 3h).
dur() {
  if [ "$1" -lt 120 ]; then echo "${1}s"; elif [ "$1" -lt 7200 ]; then echo "$(($1 / 60))m"; else echo "$(($1 / 3600))h"; fi
}

# quiet_seen SECONDS [gate]: count one piece of evidence; quiet is the age of the newest, gate_quiet the
# age of the newest gate-side evidence (stage logs, train-running.txt, this repository's gate events; the
# gate's own heavy jobs show in their stage logs), the only evidence for the verdict while the gate runs.
quiet="" gate_quiet=""
quiet_seen() {
  case ${1:-} in "" | *[!0-9]*) return 0 ;; esac
  if [ -z "$quiet" ] || [ "$1" -lt "$quiet" ]; then quiet=$1; fi
  [ "${2:-}" = gate ] || return 0
  if [ -z "$gate_quiet" ] || [ "$1" -lt "$gate_quiet" ]; then gate_quiet=$1; fi
}

# jnum VALUE / jstr VALUE: VALUE as a JSON number or string, null when empty.
jnum() { dl_json_number "${1:-}"; }
jstr() { if [ -n "${1:-}" ]; then dl_json_string "$1"; else printf 'null'; fi; }

events_file=$(dl_events_file)
repo_events=""
[ -f "$events_file" ] && repo_events=$(events_tsv "$events_file")
# newest_event [WHO...]: the epoch of this repository's newest event (of these writers only, if named).
newest_event() {
  printf '%s\n' "$repo_events" | awk -F'\t' -v who=" $* " '
    $2 != "-" && (who == "  " || index(who, " " $3 " ")) && $2 > m {m = $2} END {if (m) print m}'
}
newest=$(newest_event)
[ -z "$newest" ] || quiet_seen "$((now - newest))"
newest=$(newest_event gate)
[ -z "$newest" ] || quiet_seen "$((now - newest))" gate

# --- The gate: train-running.txt and its pid, the stages started since its train-started event. ---
gate_pid="" gate_train="" gate_running="" gate_elapsed="" gate_lines=() stage_json=""
running_file=$(dl_running_file)
[ -f "$running_file" ] && read -r gate_pid gate_train <"$running_file"
alive "$gate_pid" && gate_running=yes

# gate_stages: "start<TAB>epoch" of the last train-started event of the running gate, then a
# "stage<TAB>name<TAB>epoch<TAB>log" line per stage started and not ended since.
gate_stages() {
  printf '%s\n' "$repo_events" | awk -F'\t' -v pid="$gate_pid" '
    $3 != "gate" { next }
    $4 == "train-started" { on = ($10 == pid); start = $2; n = 0; split("", st); next }
    !on { next }
    $4 == "stage-started" { n++; st[$7] = n; ep[$7] = $2; lg[$7] = $11 }
    $4 == "stage-ended" { delete st[$7] }
    END {
      if (!on) exit
      print "start\t" start
      for (s in st) print st[s] "\t" s "\t" ep[s] "\t" lg[s] | "sort -n"
    }'
}

# add_stage NAME EPOCH LOG: one running stage (human line, JSON entry, its log's age as evidence).
add_stage() {
  local name=$1 epoch=$2 log=$3 info age="" bytes="" elapsed=""
  [ "$log" = - ] && log=""
  case $epoch in "" | *[!0-9]*) ;; *) elapsed=$((now - epoch)) ;; esac
  [ -z "$log" ] || info=$(file_info "$log")
  [ -z "${info:-}" ] || read -r age bytes <<<"$info"
  quiet_seen "$age" gate
  gate_lines+=("  stage $name: ${elapsed:+$(dur "$elapsed"), }${age:+output ${age}s ago, }${bytes:+$bytes bytes, }log ${log:-unknown}")
  stage_json+="${stage_json:+,}{\"name\":$(dl_json_string "$name"),\"elapsed_seconds\":$(jnum "$elapsed"),\"log\":$(jstr "$log"),\"log_bytes\":$(jnum "$bytes"),\"quiet_seconds\":$(jnum "$age")}"
  [ -n "${first_stage:-}" ] || first_stage=$name
}

first_stage=""
if [ -n "$gate_running" ]; then
  quiet_seen "$(file_info "$running_file" | awk '{print $1}')" gate
  while IFS=$'\t' read -r kind a b c; do
    case $kind in
      start) case $a in "" | *[!0-9]*) ;; *) gate_elapsed=$((now - a)) ;; esac ;;
      [0-9]*) add_stage "$a" "$b" "$c" ;;
    esac
  done < <(gate_stages)
  if [ -z "$stage_json" ]; then # a gate without events (an older version): its newest stage log
    # shellcheck disable=SC2012  # log names are train-<name>.log, no line breaks
    newest_log=$(ls -t "$(dl_logs_dir)"/train-*.log 2>/dev/null | head -n 1)
    [ -z "$newest_log" ] || add_stage "$(basename "$newest_log" .log | sed 's/^train-//')" "" "$newest_log"
  fi
fi

# --- Heavy slots: the heavy events of every repository's event log. ---
heavy_slots=${DEV_LOOP_HEAVY_SLOTS:-$(cfg heavy.slots 2)}
held_lines=() held_json="" waiting_json="" held_here=""
heavy_files=()
for file in "${DEV_LOOP_HOME:-$HOME/.dev-loop}"/*/events.jsonl; do [ -f "$file" ] && heavy_files+=("$file"); done

# heavy_jobs: "held<TAB>repo<TAB>pid<TAB>slot<TAB>epoch<TAB>command" for slots acquired and not released,
# "waiting<TAB>repo<TAB>pid<TAB>-<TAB>epoch<TAB>command" for jobs queued and not started.
heavy_jobs() {
  [ ${#heavy_files[@]} -gt 0 ] || return 0
  events_tsv "${heavy_files[@]}" | awk -F'\t' '
    $3 != "heavy" { next }
    { key = $1 "\t" $10 }
    $4 == "queued" { q[key] = $2 "\t" $12 }
    $4 == "slot-acquired" { delete q[key]; h[key] = $9 "\t" $2 "\t" $12 }
    $4 == "slot-released" { delete h[key] }
    END {
      for (k in h) print "held\t" k "\t" h[k]
      for (k in q) { split(q[k], v, "\t"); print "waiting\t" k "\t-\t" v[1] "\t" v[2] }
    }' | sort -t "$(printf '\t')" -k4,4n
}

while IFS=$'\t' read -r kind repo pid slot epoch command; do
  alive "$pid" || continue
  seconds=""
  case $epoch in "" | *[!0-9]*) ;; *) seconds=$((now - epoch)) ;; esac
  entry="\"pid\":$(jnum "$pid"),\"repo\":$(dl_json_string "$repo"),\"seconds\":$(jnum "$seconds"),\"command\":$(dl_json_string "$command")"
  if [ "$kind" = held ]; then
    held_lines+=("  slot $slot: pid $pid, $repo, $(dur "${seconds:-0}"): $command")
    held_json+="${held_json:+,}{\"slot\":$(jnum "$slot"),$entry}"
    [ "$repo" != "$DL_REPO" ] || [ -n "$held_here" ] || held_here=$slot
  else
    held_lines+=("  waiting: pid $pid, $repo, $(dur "${seconds:-0}"): $command")
    waiting_json+="${waiting_json:+,}{$entry}"
  fi
done < <(heavy_jobs)

# --- Loop worktrees: branch, ticket, ages, pushed, ahead/behind the base. ---
worktree_lines=() worktree_json="" active_worktrees=0
base_ref="refs/remotes/$DL_REMOTE/$DL_BASE"
git -C "$DL_ROOT" rev-parse -q --verify "$base_ref" >/dev/null || base_ref="refs/heads/$DL_BASE"
merged_heads=" $(dl_ledger_heads | awk '{printf "%s ", $2}')"

# loop_worktrees: "<path><TAB><branch>" of each worktree (not the main one) on a loop branch.
loop_worktrees() {
  git -C "$DL_ROOT" worktree list --porcelain | awk -v root="$DL_ROOT" '
    /^worktree / { path = substr($0, 10) }
    /^branch refs\/heads\// && path != root { print path "\t" substr($0, 19) }' |
    while IFS=$'\t' read -r path branch; do dl_loop_branch "$branch" && printf '%s\t%s\n' "$path" "$branch"; done
}

# add_worktree PATH BRANCH: one loop worktree (human line, JSON entry, its commit and notes as evidence).
add_worktree() {
  local path=$1 branch=$2 note ticket tip commit_age="" notes_age="" remote pushed=false unpushed="" counts
  local ahead="" behind="" merged=false push_text notes_text
  note=$(dl_note_file "$branch")
  ticket=$(dl_notes_ticket "$note" "$branch")
  tip=$(git -C "$DL_ROOT" rev-parse -q --verify "refs/heads/$branch")
  [[ "$merged_heads" == *" $tip "* ]] && merged=true
  commit_age=$((now - $(git -C "$DL_ROOT" log -1 --format=%ct "$tip")))
  notes_age=$(file_info "$note" | awk '{print $1}')
  remote=$(git -C "$DL_ROOT" rev-parse -q --verify "refs/remotes/$DL_REMOTE/$branch")
  if [ -z "$remote" ]; then
    push_text="not pushed"
  else
    unpushed=$(git -C "$DL_ROOT" rev-list --count "$remote..$tip")
    if [ "$unpushed" -eq 0 ]; then pushed=true push_text=pushed; else push_text="$unpushed commits not pushed"; fi
  fi
  counts=$(git -C "$DL_ROOT" rev-list --left-right --count "$base_ref...$tip" 2>/dev/null)
  [ -z "$counts" ] || read -r behind ahead <<<"$counts"
  if [ "$merged" = false ]; then
    active_worktrees=$((active_worktrees + 1))
    quiet_seen "$commit_age"
    quiet_seen "$notes_age"
  fi
  notes_text="no notes"
  [ -z "$notes_age" ] || notes_text="notes ${notes_age}s ago"
  worktree_lines+=("  $branch${ticket:+ #$ticket}: $([ "$merged" = false ] || echo "merged, ")commit ${commit_age}s ago, $notes_text, $push_text, ahead ${ahead:-?} behind ${behind:-?} ($path)")
  worktree_json+="${worktree_json:+,}{\"branch\":$(dl_json_string "$branch"),\"path\":$(dl_json_string "$path"),\"ticket\":$(jnum "$ticket"),\"merged\":$merged,\"commit_age_seconds\":$(jnum "$commit_age"),\"notes_age_seconds\":$(jnum "$notes_age"),\"pushed\":$pushed,\"unpushed_commits\":$(jnum "$unpushed"),\"ahead\":$(jnum "$ahead"),\"behind\":$(jnum "$behind")}"
}

while IFS=$'\t' read -r path branch; do add_worktree "$path" "$branch"; done < <(loop_worktrees)

# --- The last merge (ledger), the open tickets (gh), the orchestrator's last event. ---
last_merge_line="last merge: none" last_merge_json=null
# (empty fields become "-", since read joins consecutive tabs)
IFS=$'\t' read -r _ _ m_branch m_ticket m_at _ <<<"$(dl_ledger_rows |
  awk -F'\t' -v OFS='\t' '$1 == "M" { for (i = 1; i <= NF; i++) if ($i == "") $i = "-"; print }' | tail -n 1)"
[ "${m_ticket:-}" != - ] || m_ticket=""
[ "${m_at:-}" != - ] || m_at=""
if [ -n "${m_branch:-}" ]; then
  m_epoch=$(iso_epoch "$m_at")
  m_age=""
  [ -z "$m_epoch" ] || m_age=$((now - m_epoch))
  last_merge_line="last merge: $m_branch${m_ticket:+ #$m_ticket}${m_age:+, $(dur "$m_age") ago}"
  last_merge_json="{\"branch\":$(dl_json_string "$m_branch"),\"ticket\":$(jnum "$m_ticket"),\"merged_at\":$(jstr "$m_at"),\"age_seconds\":$(jnum "$m_age")}"
fi

open_tickets="" open_line="open tickets: not checked (--no-gh)"
if [ -n "$use_gh" ]; then
  open_line="open tickets: unknown (gh failed)"
  if numbers=$(cd "$DL_ROOT" && gh issue list --state open --limit 1000 --json number --jq '.[].number' 2>/dev/null); then
    open_tickets=$(printf '%s\n' "$numbers" | grep -c '^[0-9]')
    open_line="open tickets: $open_tickets"
  fi
fi

orch_line="orchestrator: no event yet" orch_json=null orch_event="" orch_detail="" orch_age=""
IFS=$'\t' read -r _ o_epoch _ o_event _ o_ticket _ _ _ _ _ o_detail <<<"$(printf '%s\n' "$repo_events" |
  awk -F'\t' '$3 == "orchestrator"' | tail -n 1)"
if [ -n "${o_event:-}" ]; then
  orch_event=$o_event
  [ "$o_detail" = - ] || orch_detail=$o_detail
  [ "$o_ticket" = - ] && o_ticket=""
  case $o_epoch in "" | *[!0-9]*) ;; *) orch_age=$((now - o_epoch)) ;; esac
  orch_line="orchestrator: $orch_event${o_ticket:+ #$o_ticket}${orch_detail:+ ($orch_detail)}${orch_age:+, $(dur "$orch_age") ago}"
  orch_json="{\"event\":$(dl_json_string "$orch_event"),\"detail\":$(jstr "$orch_detail"),\"ticket\":$(jnum "$o_ticket"),\"age_seconds\":$(jnum "$orch_age")}"
fi

# --- The verdict. ---
threshold=$((stall_minutes * 60))
state="" what=""
if [ -n "$gate_running" ]; then
  what="gate${first_stage:+ stage $first_stage}"
elif [ -n "$held_here" ]; then
  what="heavy job in slot $held_here"
elif [[ "$orch_event" == waiting* ]]; then
  what=${orch_detail:-${orch_event#waiting}}
  what=${what#[-_ ]}
  [ -n "$what" ] || what="something"
fi
# While the gate runs only its own evidence counts, so an implementer's commits never hide a frozen stage.
[ -z "$gate_running" ] || quiet=$gate_quiet
gate_died=false
[ -z "$gate_pid" ] || [ -n "$gate_running" ] || gate_died=true
if [ -z "$what" ] && [ "$active_worktrees" -eq 0 ] && { [ -z "$orch_age" ] || [ "$orch_age" -gt "$threshold" ]; }; then
  state=idle verdict="idle"
  [ "$gate_died" = false ] || verdict="idle (the last gate died: train-running.txt is stale)"
elif [ -n "$quiet" ] && [ "$quiet" -gt "$threshold" ]; then
  state=stalled verdict="possibly stalled: no event or output for $((quiet / 60)) min"
elif [ -n "$what" ]; then
  state=waiting verdict="waiting on $what (output ${quiet:-?}s ago)"
else
  state=working verdict="working"
fi

# --- Output. ---
if [ -n "$gate_running" ]; then
  gate_line="gate: running, pid $gate_pid${gate_elapsed:+, $(dur "$gate_elapsed")} (train: $gate_train)"
elif [ -n "$gate_pid" ]; then
  gate_line="gate: not running (train-running.txt names pid $gate_pid, which has ended)"
else
  gate_line="gate: not running"
fi
held_count=$(printf '%s\n' "${held_lines[@]+"${held_lines[@]}"}" | grep -c '^  slot ')

if [ -n "$json" ]; then
  printf '{"repo":%s,"now":%s,' "$(dl_json_string "$DL_REPO")" "$(dl_json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  printf '"verdict":{"state":"%s","what":%s,"quiet_seconds":%s,"stall_minutes":%s,"line":%s,"gate_died":%s},' \
    "$state" "$(jstr "$what")" "$(jnum "$quiet")" "$stall_minutes" "$(dl_json_string "verdict: $verdict")" "$gate_died"
  printf '"gate":{"running":%s,"stale":%s,"pid":%s,"train":%s,"elapsed_seconds":%s,"stages":[%s]},' \
    "$([ -n "$gate_running" ] && echo true || echo false)" "$gate_died" "$(jnum "$gate_pid")" \
    "$(printf '%s\n' "$gate_train" | tr ' ' '\n' | dl_json_list)" "$(jnum "$gate_elapsed")" "$stage_json"
  printf '"heavy":{"slots":%s,"held":[%s],"waiting":[%s]},' "$(jnum "$heavy_slots")" "$held_json" "$waiting_json"
  printf '"worktrees":[%s],"last_merge":%s,"open_tickets":%s,"orchestrator":%s}\n' \
    "$worktree_json" "$last_merge_json" "$(jnum "$open_tickets")" "$orch_json"
  exit 0
fi

echo "status of $DL_REPO at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "$gate_line"
for line in "${gate_lines[@]+"${gate_lines[@]}"}"; do echo "$line"; done
echo "heavy: $held_count of $heavy_slots slots in use"
for line in "${held_lines[@]+"${held_lines[@]}"}"; do echo "$line"; done
if [ ${#worktree_lines[@]} -eq 0 ]; then echo "worktrees: none"; else echo "worktrees: ${#worktree_lines[@]}"; fi
for line in "${worktree_lines[@]+"${worktree_lines[@]}"}"; do echo "$line"; done
echo "$last_merge_line"
echo "$open_line"
echo "$orch_line"
echo "verdict: $verdict"
