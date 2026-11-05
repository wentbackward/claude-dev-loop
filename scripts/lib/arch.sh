# shellcheck shell=bash
# Helpers for the component cards and the architecture fitness checks ("architecture" in .dev-loop.json),
# shared by arch-check.sh, gate-train.sh and doctor.sh. Source scripts/lib/common.sh and run dl_load_config
# first. Tagged lines separate the results: "E<TAB>error", "V<TAB>violation", "N<TAB>path in no component",
# "S<TAB>layer<TAB>name<TAB>kind<TAB>lines<TAB>budget" (one per component).

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
      if (kind != "component" && kind != "composition-root")
        problem("\"kind\" is \"" kind "\", not component or composition-root")
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

# The analysis of dl_arch_analyse: part 1 the cards, part 2 the line counts, part 3 the edges.
# shellcheck disable=SC2016  # an awk program: $1 and friends are awk fields
_dl_arch_analyse_awk='
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
# check_cards: every depends_on name has a card (once, after the cards are read).
function check_cards(   i, k, names, list) {
  checked = 1
  for (i = 1; i <= n; i++) {
    names = split(deps[i], list, " ")
    for (k = 1; k <= names; k++)
      if (!(list[k] in index_of)) print "E\t" card[i] ": depends_on names \"" list[k] "\", which has no card"
  }
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

# dl_arch_notes_reason FILE: the notes file's "## Architecture" section has a reason: a line of text that is
# not a placeholder ("none", "n/a", "TODO", "-" and the like, in any case, also as "none: ...").
dl_arch_notes_reason() {
  [ -n "$1" ] && [ -f "$1" ] || return 1
  awk '
    function placeholder(text,   word) {
      text = tolower(text)
      gsub(/[`*_"]/, "", text)
      sub(/^[ \t]*([-+*>]|[0-9]+[.)])?[ \t]*/, "", text)
      sub(/[ \t.!?]+$/, "", text)
      word = text
      sub(/[ \t]*[:=-].*$/, "", word)
      return word ~ /^(none|nothing|n\/a|na|n\.a|todo|tbd|tba|fixme|xxx|nil|null|no|empty|later)$/
    }
    /^#+[ \t]/ { heading = tolower($0); sub(/^#+[ \t]+/, "", heading); sub(/[ \t]+$/, "", heading)
                 in_section = ($0 ~ /^##[ \t]/ && heading == "architecture"); next }
    in_section && $0 ~ /[A-Za-z0-9]/ && $0 !~ /^[ \t]*<!--/ && !placeholder($0) { found = 1; exit }
    END { exit !found }' "$1"
}

# dl_arch_baseline_growth FROM TO: the baseline entries of commit TO that commit FROM does not have (or a
# budget entry that grew), one per line.
dl_arch_baseline_growth() {
  local baseline
  baseline=$(dl_arch_baseline_path)
  dl_arch_compare <(git show "$1:$baseline" 2>/dev/null) <(git show "$2:$baseline" 2>/dev/null) | dl_arch_tagged new
}
