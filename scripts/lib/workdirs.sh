# shellcheck shell=bash
# The work dirs of the plugin's own test suites (tests/smoke.sh, tests/identity.sh): each run makes one with
# `mktemp -d "$TMPDIR/<prefix>.XXXXXX"`. Removal only ever touches such a dir: a real directory (not a
# symlink) owned by the user, directly in TMPDIR (default /tmp), named <prefix>.<6 letters or digits>.
# Standalone: needs nothing else sourced.

# The suites' name prefixes, the only ones dl_work_dir_ok accepts.
DL_WORK_PREFIXES="dev-loop-smoke dev-loop-identity"

# dl_tmp_dir: TMPDIR (default /tmp) with symlinks resolved; fails when it does not exist.
dl_tmp_dir() {
  (cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)
}

# dl_work_dir_ok PATH PREFIX: PATH is a suite's own mktemp dir: PREFIX is one of DL_WORK_PREFIXES, PATH is
# a directory and not a symlink, owned by the user, its parent is TMPDIR and its name is PREFIX.XXXXXX.
dl_work_dir_ok() {
  local path=$1 prefix=$2 name parent tmp
  case " $DL_WORK_PREFIXES " in *" $prefix "*) ;; *) return 1 ;; esac
  path=${path%/}
  [ -n "$path" ] && [ -d "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  name=${path##*/}
  case $name in "$prefix".[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) return 1 ;; esac
  case $path in */*) parent=${path%/*} ;; *) parent=. ;; esac
  parent=$(cd "${parent:-/}" 2>/dev/null && pwd -P) || return 1
  tmp=$(dl_tmp_dir) || return 1
  [ "$parent" = "$tmp" ]
}

# dl_remove_work_dir PATH PREFIX: remove PATH when dl_work_dir_ok accepts it; fails (removing nothing) when
# it does not, and when the removal fails.
dl_remove_work_dir() {
  dl_work_dir_ok "$1" "$2" || return 1
  rm -rf "${1%/}" 2>/dev/null
  [ ! -e "${1%/}" ]
}

# dl_suite_end SUITE WORK PASSED FAILED: print the suite's summary line; on a green run (FAILED 0) remove
# its work dir (prefix dev-loop-SUITE) unless DEV_LOOP_KEEP_WORK=1, else keep it and name it. Returns 0
# only on a green run.
dl_suite_end() {
  local where="work dir $2"
  if [ "$4" -eq 0 ] && [ "${DEV_LOOP_KEEP_WORK:-}" != 1 ]; then
    cd / || return 1
    if dl_remove_work_dir "$2" "dev-loop-$1"; then where="work dir removed"; else where="$where, not removed"; fi
  fi
  echo "$1: $3 passed, $4 failed ($where)"
  [ "$4" -eq 0 ]
}

# dl_prune_work_dirs RECORD LOG...: the gate's pruning. Add the work dirs the LOGs name ("(work dir PATH)"
# or "(work dir PATH, ...)") to the RECORD file, then for each prefix keep only the newest recorded dir that
# still exists and remove the older ones (dl_remove_work_dir, so only a suite's own dir); RECORD keeps the
# dirs left. Nothing the logs do not name is touched.
dl_prune_work_dirs() {
  local record=$1 path prefix newest kept=""
  shift
  [ $# -gt 0 ] && cat "$@" 2>/dev/null | sed -n 's/.*(work dir \(\/[^,)]*\)[,)].*/\1/p' |
    while IFS= read -r path; do
      grep -qxF -- "$path" "$record" 2>/dev/null || printf '%s\n' "$path" >>"$record"
    done
  [ -f "$record" ] || return 0
  for prefix in $DL_WORK_PREFIXES; do
    newest=""
    while IFS= read -r path; do
      dl_work_dir_ok "$path" "$prefix" || continue
      [ -z "$newest" ] || dl_remove_work_dir "$newest" "$prefix" || kept+="$newest"$'\n'
      newest=$path
    done <"$record"
    [ -z "$newest" ] || kept+="$newest"$'\n'
  done
  printf '%s' "$kept" >"$record.tmp.$$" && mv -f "$record.tmp.$$" "$record"
}
