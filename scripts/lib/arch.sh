# shellcheck shell=bash
# Helpers for the component cards and the architecture fitness checks ("architecture" in .dev-loop.json),
# shared by arch-check.sh, arch-evidence.sh, gate-train.sh, merge-train.sh and doctor.sh. Source
# scripts/lib/common.sh and run dl_load_config first. Tagged lines separate the results: "E<TAB>error", "V<TAB>violation", "N<TAB>path in no component",
# "S<TAB>layer<TAB>name<TAB>kind<TAB>lines<TAB>budget" (one per component), "D<TAB>from<TAB>to" (one per
# dependency between two components).

# shellcheck source=reasons.sh
. "$(dirname "${BASH_SOURCE[0]}")/reasons.sh"

# dl_arch_on: the project configures an architecture check command; without it nothing changes.
dl_arch_on() {
  [ -n "$(cfg architecture.check "")" ]
}

# dl_arch_cards_dir: the folder of the component cards (default docs/architecture), without a trailing /.
dl_arch_cards_dir() {
  cfg architecture.cards docs/architecture | sed 's:/*$::'
}

# dl_arch_baseline_path: the file of known violations (default docs/architecture/baseline.txt).
dl_arch_baseline_path() {
  cfg architecture.baseline docs/architecture/baseline.txt
}

# dl_arch_budget: the default line budget per component (0: none); status 1 when it is not a number.
dl_arch_budget() {
  local budget
  budget=$(cfg architecture.budget 0)
  case $budget in "" | *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((10#$budget))"
}

# dl_arch_cards DIR: one "C<TAB>card<TAB>component<TAB>layer<TAB>kind<TAB>paths<TAB>listed<TAB>depends_on
# <TAB>max_lines" line per card in DIR's cards folder (a Markdown file whose first line is ---), and an
# "E<TAB>problem" line per broken card. Other Markdown files (an index) are not cards.
dl_arch_cards() {
  local dir=$1 folder file files=()
  folder=$dir/$(dl_arch_cards_dir)
  while IFS= read -r file; do
    [ -f "$file" ] && files+=("$file")
  done < <(printf '%s\n' "$folder"/*.md | LC_ALL=C sort)
  [ ${#files[@]} -gt 0 ] || return 0
  LC_ALL=C awk -v root="$dir/" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function problem(text) { print "E\t" card ": " text; bad = 1 }
    function finish(   kind, listed) {
      if (!is_card) return
      bad = 0
      if (state != 2) { problem("no closing \"---\" line after the header"); return }
      if (f["component"] !~ /^[A-Za-z0-9_.-]+$/) problem("\"component\" is \"" f["component"] "\", not a plain name")
      if (f["layer"] !~ /^[0-9]+$/) problem("\"layer\" is \"" f["layer"] "\", not a number (0 at the bottom)")
      kind = ("kind" in f && f["kind"] != "") ? f["kind"] : "component"
      if (kind !~ /^(component|composition-root|service|job|store)$/)
        problem("\"kind\" is \"" kind "\", not component, composition-root, service, job or store")
      if (f["paths"] == "") problem("no \"paths\"")
      if ("max_lines" in f && f["max_lines"] !~ /^[1-9][0-9]*$/)
        problem("\"max_lines\" is \"" f["max_lines"] "\", not a positive number")
      if (bad) return
      listed = ("depends_on" in f) ? 1 : 0
      print "C\t" card "\t" f["component"] "\t" (f["layer"] + 0) "\t" kind "\t" f["paths"] "\t" listed "\t" \
        f["depends_on"] "\t" f["max_lines"]
    }
    FNR == 1 {
      finish()
      card = substr(FILENAME, length(root) + 1)
      split("", f)
      is_card = (trim($0) == "---")
      state = is_card ? 1 : 0
      next
    }
    state == 1 {
      line = trim($0)
      if (line == "---") { state = 2; next }
      if (line == "" || line ~ /^#/) next
      if (line !~ /^[A-Za-z_]+[ \t]*:/) { problem("header line \"" line "\" is not \"key: value\""); next }
      key = trim(substr(line, 1, index(line, ":") - 1))
      value = " " substr(line, index(line, ":") + 1)
      sub(/[ \t]+#.*$/, "", value)
      gsub(/[ \t,]+/, " ", value)
      f[key] = trim(value)
    }
    END { finish() }' "${files[@]}"
}

# dl_arch_line_counts DIR: "<path><TAB><lines>" for each tracked text file of the checkout DIR.
dl_arch_line_counts() {
  git -C "$1" -c core.quotePath=false grep -I -c -z -e '' -- 2>/dev/null | tr '\0' '\t'
}

# The awk functions that map paths to components, shared by the analysis and the evidence: they read the
# cards from n, name, patterns, pattern, regex and index_of.
# shellcheck disable=SC2016  # an awk program: $1 and friends are awk fields
_dl_arch_map_awk='
# glob_re GLOB: an anchored regular expression for a shell glob where * also matches / (? is one character).
function glob_re(glob,   i, c, re) {
  re = "^"
  for (i = 1; i <= length(glob); i++) {
    c = substr(glob, i, 1)
    if (c == "*") re = re ".*"
    else if (c == "?") re = re "."
    else if (index("\\^$.|+(){}[]", c)) re = re "\\" c
    else re = re c
  }
  return re "$"
}
# component_of PATH: the component whose matching glob is the longest (the first card on a tie), else the
# component named PATH, else "".
function component_of(path,   i, k, best, best_length) {
  sub(/^\.\//, "", path)
  if (path in memo) return memo[path]
  best = ""; best_length = -1
  for (i = 1; i <= n; i++)
    for (k = 1; k <= patterns[i]; k++)
      if (length(pattern[i, k]) > best_length && path ~ regex[i, k]) { best = i; best_length = length(pattern[i, k]) }
  if (best == "" && path in index_of) best = index_of[path]
  memo[path] = best
  return best
}
# sorted_names LIST: the space-separated component indexes of LIST as their sorted names.
function sorted_names(list,   items, count, i, j, tmp, out) {
  count = split(list, items, " ")
  for (i = 1; i <= count; i++) items[i] = name[items[i]]
  for (i = 2; i <= count; i++)
    for (j = i; j > 1 && items[j - 1] > items[j]; j--) { tmp = items[j]; items[j] = items[j - 1]; items[j - 1] = tmp }
  out = items[1]
  for (i = 2; i <= count; i++) out = out " " items[i]
  return out
}
'

# The analysis of dl_arch_analyse: part 1 the cards, part 2 the line counts, part 3 the edges.
# shellcheck disable=SC2016  # an awk program
_dl_arch_analyse_awk=$_dl_arch_map_awk'
# check_cards: every depends_on name has a card (once, after the cards are read).
function check_cards(   i, k, names, list) {
  checked = 1
  for (i = 1; i <= n; i++) {
    names = split(deps[i], list, " ")
    for (k = 1; k <= names; k++)
      if (!(list[k] in index_of)) print "E\t" card[i] ": depends_on names \"" list[k] "\", which has no card"
  }
}
part == 1 {
  if ($1 != "C") next
  if ($3 in index_of) { print "E\t" $2 ": component \"" $3 "\" is also defined in " card[index_of[$3]]; next }
  n++
  card[n] = $2; name[n] = $3; layer[n] = $4 + 0; kind[n] = $5; listed[n] = $7; deps[n] = $8; max[n] = $9
  index_of[$3] = n
  patterns[n] = split($6, list, " ")
  for (k = 1; k <= patterns[n]; k++) {
    pattern[n, k] = list[k]; regex[n, k] = glob_re(list[k])
    if (list[k] in glob_card && glob_card[list[k]] != $2)
      print "E\t" $2 ": paths glob \"" list[k] "\" is also in " glob_card[list[k]] " (one card per glob)"
    else glob_card[list[k]] = $2
  }
  dependencies = split($8, list, " ")
  for (k = 1; k <= dependencies; k++) allowed[n, list[k]] = 1
  next
}
!checked { check_cards() }
part == 2 {
  i = component_of($1)
  if (i != "") lines[i] += $2
  next
}
part == 3 {
  line = $0
  sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line)
  if (line == "" || line ~ /^#/) next
  if (split(line, ends, /[ \t]+/) != 2) { print "E\tarchitecture.check printed \"" line "\", not \"<from> <to>\""; next }
  a = component_of(ends[1]); b = component_of(ends[2])
  if (a == "") { sub(/^\.\//, "", ends[1]); print "N\t" ends[1] }
  if (b == "") { sub(/^\.\//, "", ends[2]); print "N\t" ends[2] }
  if (a == "" || b == "" || a == b || ((a, b) in edge)) next
  edge[a, b] = 1
  adjacent[a] = adjacent[a] " " b
}
END {
  if (!checked) check_cards()
  for (key in edge) {
    split(key, pair, SUBSEP); a = pair[1]; b = pair[2]
    print "D\t" name[a] "\t" name[b]
    if (layer[a] < layer[b]) print "V\tupward " name[a] " -> " name[b]
    if (kind[a] != "composition-root" && listed[a] && !((a, name[b]) in allowed))
      print "V\tundeclared " name[a] " -> " name[b]
  }
  # Reachability from every component (breadth first), then each strongly connected group once.
  for (i = 1; i <= n; i++) {
    queue = adjacent[i]
    while (queue != "") {
      count = split(queue, items, " "); queue = ""
      for (k = 1; k <= count; k++) {
        if ((i, items[k]) in reach) continue
        reach[i, items[k]] = 1
        queue = queue " " adjacent[items[k]]
      }
    }
  }
  for (i = 1; i <= n; i++) {
    if (i in grouped) continue
    members = i; size = 1
    for (j = i + 1; j <= n; j++)
      if ((i, j) in reach && (j, i) in reach) { members = members " " j; size++; grouped[j] = 1 }
    if (size > 1) print "V\tcycle " sorted_names(members)
  }
  for (i = 1; i <= n; i++) {
    limit = (max[i] != "") ? max[i] + 0 : budget + 0
    if (limit > 0 && lines[i] + 0 > limit) print "V\tbudget " name[i] " " (lines[i] + 0) "/" limit
    print "S\t" layer[i] "\t" name[i] "\t" kind[i] "\t" (lines[i] + 0) "\t" (limit > 0 ? limit : "-")
  }
}
'

# dl_arch_analyse DIR: run architecture.check in the checkout DIR, map its edges and files to the cards,
# and print the tagged results (errors, violations, files in no component, component sizes).
dl_arch_analyse() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-arch.XXXXXX") || return 2
  _dl_arch_gather "$1" "$tmp"
  _dl_arch_evaluate "$1" "$tmp"
  rm -rf "$tmp"
}

# _dl_arch_gather DIR TMP: the edges of architecture.check (TMP/edges, a failure as an error in TMP/errors)
# and the line counts (TMP/counts) of the checkout DIR.
_dl_arch_gather() {
  local dir=$1 tmp=$2 rc
  : >"$tmp/errors"
  (cd "$dir" && bash -c "$(cfg architecture.check)") >"$tmp/edges" 2>"$tmp/stderr" </dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'E\tarchitecture.check failed (rc %s): %s\n' "$rc" "$(tail -n 1 "$tmp/stderr")" >"$tmp/errors"
    : >"$tmp/edges"
  fi
  dl_arch_line_counts "$dir" >"$tmp/counts"
}

# _dl_arch_evaluate ROOT TMP: the tagged results of the facts in TMP judged by the cards under ROOT.
_dl_arch_evaluate() {
  local budget
  budget=$(dl_arch_budget) || budget=0
  dl_arch_cards "$1" >"$2/cards"
  awk -F'\t' '$1 == "E"' "$2/cards"
  cat "$2/errors"
  LC_ALL=C awk -F'\t' -v budget="$budget" "$_dl_arch_analyse_awk" part=1 "$2/cards" part=2 "$2/counts" part=3 "$2/edges"
}

# dl_arch_extract_cards REF DEST: the cards folder of commit REF, under DEST at its repository path
# (nothing when REF has no cards folder).
dl_arch_extract_cards() {
  local folder
  folder=$(dl_arch_cards_dir)
  mkdir -p "$2" || return 1
  git cat-file -e "$1:$folder" 2>/dev/null || return 0
  git archive "$1" "$folder" | tar -xf - -C "$2"
}

# dl_arch_headers_changed FROM TO: the card headers (what the checks read) of commit TO differ from FROM's.
dl_arch_headers_changed() {
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-arch-cards.XXXXXX") || return 0
  dl_arch_extract_cards "$1" "$tmp/from" && dl_arch_extract_cards "$2" "$tmp/to"
  [ "$(dl_arch_cards "$tmp/from")" != "$(dl_arch_cards "$tmp/to")" ]
  rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# dl_arch_loosened DIR ROOT: the violations of the checkout DIR under the cards below ROOT (another commit's)
# that DIR's own cards no longer report, one per line: what DIR's card edits hide.
dl_arch_loosened() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-arch.XXXXXX") || return 2
  _dl_arch_gather "$1" "$tmp"
  _dl_arch_evaluate "$2" "$tmp" | dl_arch_tagged V | LC_ALL=C sort -u >"$tmp/old"
  _dl_arch_evaluate "$1" "$tmp" | dl_arch_tagged V | LC_ALL=C sort -u >"$tmp/new"
  dl_arch_compare "$tmp/old" "$tmp/new" | dl_arch_tagged fixed
  rm -rf "$tmp"
}

# dl_arch_tagged TAG < results: the lines of one tag, without it.
dl_arch_tagged() {
  awk -v tag="$1" 'index($0, tag "\t") == 1 { print substr($0, length(tag) + 2) }'
}

# The comparison of dl_arch_compare: part 1 the baseline, part 2 the current violations.
# shellcheck disable=SC2016  # an awk program
_dl_arch_compare_awk='
function key(line,   words) {
  if (line !~ /^budget /) return line
  split(line, words, " ")
  return "budget " words[2]
}
function size(line,   words, parts) {
  split(line, words, " ")
  split(words[3], parts, "/")
  return parts[1] + 0
}
{ sub(/[ \t\r]+$/, "") }
$0 == "" || /^#/ { next }
part == 1 { known[key($0)] = $0; next }
{
  k = key($0)
  seen[k] = 1
  if (!(k in known) || (k ~ /^budget / && size($0) > size(known[k]))) print "new\t" $0
  else print "known\t" $0
}
END { for (k in known) if (!(k in seen)) print "fixed\t" known[k] }
'

# dl_arch_compare BASELINE CURRENT: each violation of the file CURRENT as "new<TAB>line" or "known<TAB>line",
# and each entry of the file BASELINE that no longer occurs as "fixed<TAB>line". A budget entry is known
# while the component is no bigger than its baselined size. Blank and # lines of BASELINE are ignored.
dl_arch_compare() {
  LC_ALL=C awk "$_dl_arch_compare_awk" part=1 "$1" part=2 "$2" | LC_ALL=C sort
}

# dl_arch_notes_reason FILE: the notes file's "## Architecture" section has a reason (dl_notes_reason).
dl_arch_notes_reason() {
  dl_notes_reason "$1" architecture
}

# dl_arch_baseline_growth FROM TO: the baseline entries of commit TO that commit FROM does not have (or a
# budget entry that grew), one per line.
dl_arch_baseline_growth() {
  local baseline
  baseline=$(dl_arch_baseline_path)
  dl_arch_compare <(git show "$1:$baseline" 2>/dev/null) <(git show "$2:$baseline" 2>/dev/null) | dl_arch_tagged new
}

# dl_arch_components_of ROOT < PATHS: the components (sorted, separated by spaces) that the paths, one per
# line, map to through the cards under ROOT.
dl_arch_components_of() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-arch.XXXXXX") || return 2
  cat >"$tmp/paths"
  dl_arch_cards "$1" >"$tmp/cards"
  LC_ALL=C awk -F'\t' "$_dl_arch_map_awk$_dl_arch_load_awk"'
    part == 1 && $1 == "C" { _dl_arch_load_card() }
    part == 2 { i = component_of($0); if (i != "" && !(i in found)) { found[i] = 1; list = list " " i } }
    END { if (list != "") print sorted_names(list) }' part=1 "$tmp/cards" part=2 "$tmp/paths"
  rm -rf "$tmp"
}

# dl_arch_components_at REF < PATHS: the components the paths map to through the cards of commit REF.
dl_arch_components_at() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-arch-cards.XXXXXX") || return 2
  dl_arch_extract_cards "$1" "$tmp" && dl_arch_components_of "$tmp"
  rm -rf "$tmp"
}

# dl_arch_thresholds: the evidence thresholds, "<key> <default>" per line (architecture.<key>).
dl_arch_thresholds() {
  printf '%s\n' "cadence 20" "scatter 3" "growth 500" "co_change 75" "co_change_min 3" "hotspot 5" "cycle 3" \
    "fan_out 5" "review_rounds 3"
}

# dl_arch_threshold KEY: architecture.KEY or its default, as a number; status 1 when it is not a whole
# number (cadence: 0 too).
dl_arch_threshold() {
  local value
  value=$(cfg "architecture.$1" "$(dl_arch_thresholds | awk -v k="$1" '$1 == k {print $2}')")
  case $value in "" | *[!0-9]*) return 1 ;; esac
  [ "$1" != cadence ] || [ "$((10#$value))" -gt 0 ] || return 1
  printf '%s\n' "$((10#$value))"
}

# dl_arch_bad_thresholds: one "architecture.<key>: "<value>" is not a number" line per bad threshold.
dl_arch_bad_thresholds() {
  local key
  while read -r key _; do
    dl_arch_threshold "$key" >/dev/null || printf 'architecture.%s: "%s" is not a number\n' "$key" "$(cfg "architecture.$key" "")"
  done < <(dl_arch_thresholds)
}

# dl_arch_default_since: the evidence window by default: the merges since the architect last ran (the time
# in its marker), else the last architecture.cadence merges.
dl_arch_default_since() {
  local marker since=""
  marker=$(dl_architect_file)
  [ -f "$marker" ] && since=$(head -n 1 "$marker")
  case $since in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) printf '%s\n' "$since" ;;
    *) dl_arch_threshold cadence || echo 20 ;;
  esac
}

# The signals of dl_arch_evidence: part 1 the cards, part 2 the analysis (S, V and D lines), part 3 the line
# counts at the window's start, part 4 the ledger rows (M lines with the window flag last, F lines). Each
# finding prints as "<order><TAB><signal><TAB><line>".
# shellcheck disable=SC2016  # an awk program
_dl_arch_evidence_awk='
function add(order, signal, line) { print order "\t" signal "\t" line }
part == 1 { if ($1 == "C") { _dl_arch_load_card(); if (layer[n] > top) top = layer[n] } next }
part == 2 {
  if ($1 == "S") now[$3] = $5
  else if ($1 == "V" && $2 ~ /^budget /) add(1, "size", $2)
  else if ($1 == "V" && $2 ~ /^cycle /) {
    members = substr($2, 7)
    size = split(members, words, " ")
    if (size > cycle_max) add(5, "cycle", size " components: " members)
  } else if ($1 == "D" && ($2 in index_of) && ($3 in index_of)) {
    a = index_of[$2]; b = index_of[$3]
    if (!((a, b) in edge)) { edge[a, b] = 1; out[a] = out[a] " " b; degree[a]++ }
  }
  next
}
part == 3 { i = component_of($1); if (i != "") old[i] += $2; next }
part == 4 && $1 == "M" {
  m = $2; branch[m] = $3; rounds[m] = $6; in_window[m] = $9
  if ($4 != "") { merges_of[$4]++; branches_of[$4] = branches_of[$4] " " $3; if ($9) ticket_in_window[$4] = 1 }
  next
}
part == 4 && $1 == "F" && in_window[$2] {
  m = $2
  if (!((m, $3) in file_seen)) { file_seen[m, $3] = 1; churn[$3]++ }
  i = component_of($3)
  if (i != "" && !((m, i) in touched)) { touched[m, i] = 1; components[m] = components[m] " " i; count[m]++ }
}
# reaches A B: B depends on A through the code, directly or through other components (breadth first).
function reaches(a, b,   queue, items, total, k, visited) {
  queue = out[a]
  while (queue != "") {
    total = split(queue, items, " "); queue = ""
    for (k = 1; k <= total; k++) {
      if (items[k] == b) return 1
      if (items[k] in visited) continue
      visited[items[k]] = 1
      queue = queue " " out[items[k]]
    }
  }
  return 0
}
END {
  if (has_start) for (i = 1; i <= n; i++) if (now[name[i]] - old[i] > growth) add(1, "size", "growth " name[i] " +" (now[name[i]] - old[i]) " lines")
  for (m in in_window) {
    if (!in_window[m]) continue
    if (count[m] > scatter) add(2, "scatter", branch[m] " " count[m] " components: " sorted_names(components[m]))
    total = split(components[m], list, " ")
    for (x = 1; x <= total; x++) {
      changes[list[x]]++
      for (y = x + 1; y <= total; y++) {
        a = list[x]; b = list[y]
        if (name[a] > name[b]) { a = list[y]; b = list[x] }
        together[a, b]++
      }
    }
    if (rounds[m] ~ /^[0-9]+$/ && rounds[m] + 0 > rounds_max) add(8, "friction", "rounds " branch[m] " " rounds[m] " rounds")
  }
  for (key in together) {
    split(key, pair, SUBSEP); a = pair[1]; b = pair[2]
    union = changes[a] + changes[b] - together[key]
    if (together[key] >= co_change_min && together[key] * 100 >= co_change * union)
      add(3, "co-change", name[a] " " name[b] " " together[key] "/" union " merges")
  }
  for (path in churn) if (churn[path] > hotspot) add(4, "hotspot", path " " churn[path] " merges")
  for (key in edge) {
    split(key, pair, SUBSEP); a = pair[1]; b = pair[2]
    if (layer[b] == top && layer[a] < top) add(6, "misplaced", name[a] " -> " name[b] " (" name[b] " is in the top layer, " top ")")
  }
  for (a = 1; a <= n; a++)
    if (kind[a] != "composition-root" && degree[a] > fan_out) add(7, "fan-out", name[a] " " degree[a] " components: " sorted_names(out[a]))
  for (t in merges_of) if (merges_of[t] > 1 && (t in ticket_in_window)) add(8, "friction", "reopened #" t " " merges_of[t] " merges:" branches_of[t])
  for (a = 1; a <= n; a++) {
    if (kind[a] !~ /^(service|job|store)$/) continue
    for (b = 1; b <= n; b++)
      if (b != a && kind[b] ~ /^(service|job|store)$/ && reaches(a, b))
        add(9, "runtime", name[a] " -> " name[b] " (separate at run time, connected in code)")
  }
}
'

# The card loader of the programs that read dl_arch_cards lines and use the map functions.
# shellcheck disable=SC2016  # an awk program
_dl_arch_load_awk='
# _dl_arch_load_card: add the card of the current "C" line to the component tables.
function _dl_arch_load_card(   k, list) {
  n++
  name[n] = $3; layer[n] = $4 + 0; kind[n] = $5; index_of[$3] = n
  patterns[n] = split($6, list, " ")
  for (k = 1; k <= patterns[n]; k++) { pattern[n, k] = list[k]; regex[n, k] = glob_re(list[k]) }
}
'

# dl_arch_evidence ROOT SINCE: the evidence signals of the checkout ROOT over the ledger window SINCE (a
# number of merges, or a time: the merges after it), as tagged lines: "E<TAB>error", one
# "W<TAB>merges<TAB>first merged_at<TAB>last merged_at<TAB>components" line, and the findings
# "F<TAB>signal<TAB>line" in signal order, each signal's lines sorted. Read-only: it writes only to a
# temporary directory it removes.
dl_arch_evidence() {
  local root=$1 tmp start="" first
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/dev-loop-evidence.XXXXXX") || return 2
  dl_arch_analyse "$root" >"$tmp/analysis"
  awk -F'\t' '$1 == "E"' "$tmp/analysis"
  dl_arch_cards "$root" >"$tmp/cards"
  dl_ledger_rows >"$tmp/rows"
  _dl_arch_window "$2" "$tmp/rows" >"$tmp/flagged"
  { cat "$tmp/flagged"; _dl_arch_old_files "$root" "$tmp/flagged"; } >"$tmp/window"
  first=$(awk -F'\t' '$1 == "M" && $9 == 1 { print $7; exit }' "$tmp/window")
  [ -n "$first" ] && start=$(git -C "$root" rev-parse -q --verify "$first^1^{commit}" 2>/dev/null)
  if [ -n "$start" ]; then
    git -C "$root" -c core.quotePath=false grep -I -c -z -e '' "$start" -- 2>/dev/null | tr '\0' '\t' |
      sed "s/^$start://" >"$tmp/old"
  else
    : >"$tmp/old"
  fi
  awk -F'\t' -v components="$(awk -F'\t' '$1 == "C"' "$tmp/cards" | wc -l | tr -d ' ')" '
    $1 == "M" && $9 == 1 { count++; if (first == "") first = $5; last = $5 }
    END { print "W\t" count + 0 "\t" first "\t" last "\t" components }' "$tmp/window"
  LC_ALL=C awk -F'\t' -v has_start="${start:+1}" \
    -v scatter="$(dl_arch_threshold scatter || echo 3)" -v growth="$(dl_arch_threshold growth || echo 500)" \
    -v co_change="$(dl_arch_threshold co_change || echo 75)" -v co_change_min="$(dl_arch_threshold co_change_min || echo 3)" \
    -v hotspot="$(dl_arch_threshold hotspot || echo 5)" -v cycle_max="$(dl_arch_threshold cycle || echo 3)" \
    -v fan_out="$(dl_arch_threshold fan_out || echo 5)" -v rounds_max="$(dl_arch_threshold review_rounds || echo 3)" \
    "$_dl_arch_map_awk$_dl_arch_load_awk$_dl_arch_evidence_awk" part=1 "$tmp/cards" part=2 "$tmp/analysis" part=3 "$tmp/old" \
    part=4 "$tmp/window" | LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k3,3 | awk -F'\t' '{ print "F\t" $2 "\t" $3 }'
  rm -rf "$tmp"
}

# _dl_arch_window SINCE ROWS: the ledger rows of the file ROWS, each M line with a last field 1 when the merge
# is in the window SINCE (the last SINCE merges, or the merges after the time SINCE), else 0.
_dl_arch_window() {
  awk -F'\t' -v since="$1" '
    NR == FNR { if ($1 == "M") total++; next }
    $1 == "M" {
      k++
      inside = (since ~ /^[0-9]+$/) ? (k > total - since) : ($5 > since)
      print $0 "\t" (inside ? 1 : 0)
      next
    }
    { print }' "$2" "$2"
}

# _dl_arch_old_files ROOT WINDOW: F lines for the merges in WINDOW that list no files (ledger lines from
# before the evidence fields), from their merge commits in the repository ROOT.
_dl_arch_old_files() {
  local n commit
  while IFS=$'\t' read -r n commit; do
    git -C "$1" rev-parse -q --verify "$commit^{commit}" >/dev/null 2>&1 || continue
    git -C "$1" -c core.quotePath=false diff-tree -r --root --no-commit-id --name-only "$commit" 2>/dev/null |
      awk -v n="$n" '{ print "F\t" n "\t" $0 }'
  done < <(awk -F'\t' '$1 == "M" && $8 == 0 && $9 == 1 && $7 != "" { print $2 "\t" $7 }' "$2")
}
