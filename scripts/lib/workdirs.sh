# shellcheck shell=bash
# The work dirs of the plugin's own test suites (tests/smoke.sh, tests/identity.sh): each run makes one with
# `mktemp -d "$TMPDIR/<prefix>.XXXXXX"`. Removal only ever touches such a dir: a real directory (not a
# symlink) owned by the user, named by an absolute path, directly in TMPDIR (default /tmp), named
# <prefix>.<6 letters or digits>. The suites make a relative TMPDIR absolute first (dl_tmpdir_absolute), so
# their dir is still removed. With TMPDIR=/ nothing is ever removed, on purpose: the resolved parent of a dir
# in / is empty, which never equals /. Standalone: needs nothing else sourced.

# The suites' name prefixes, the only ones dl_work_dir_ok accepts.
DL_WORK_PREFIXES="dev-loop-smoke dev-loop-identity"

# dl_tmp_dir: TMPDIR (default /tmp) with symlinks resolved; fails when it does not exist. Every cd here
# clears CDPATH and ends options with --, so a relative or option-like name means a dir of that name here.
dl_tmp_dir() {
  (CDPATH='' cd -P -- "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)
}

# dl_tmpdir_absolute: make a relative TMPDIR absolute (symlinks resolved), so the suite's work dir path stays
# valid after a cd; TMPDIR stays as it is when it is unset, empty, absolute or does not exist.
dl_tmpdir_absolute() {
  local abs
  case ${TMPDIR:-/} in /*) return 0 ;; esac
  abs=$(CDPATH='' cd -P -- "$TMPDIR" 2>/dev/null && pwd -P) && TMPDIR=$abs
  return 0
}

# dl_work_dir_ok PATH PREFIX: PATH is a suite's own mktemp dir: PREFIX is one of DL_WORK_PREFIXES, PATH is
# absolute, has no `.` or `..` component, is a directory and not a symlink, owned by the user, its name is
# PREFIX.XXXXXX, and on disk (symlinks resolved) its parent is TMPDIR. Prints the resolved path.
dl_work_dir_ok() {
  local path=$1 prefix=$2 name real tmp
  case " $DL_WORK_PREFIXES " in *" $prefix "*) ;; *) return 1 ;; esac
  case $path in /*) ;; *) return 1 ;; esac
  path=${path%/}
  case /$path/ in */./* | */../*) return 1 ;; esac
  [ -n "$path" ] && [ -d "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  name=${path##*/}
  local x='[A-Za-z0-9]'
  # shellcheck disable=SC2254  # the pattern is meant to match
  case $name in "$prefix".$x$x$x$x$x$x) ;; *) return 1 ;; esac
  real=$(CDPATH='' cd -P -- "$path" 2>/dev/null && pwd -P) || return 1
  [ "${real##*/}" = "$name" ] || return 1
  tmp=$(dl_tmp_dir) || return 1
  [ "${real%/*}" = "$tmp" ] || return 1
  printf '%s\n' "$real"
}

# dl_remove_work_dir PATH PREFIX: remove PATH, by its resolved path, when dl_work_dir_ok accepts it; fails
# (removing nothing) when it does not, and when the removal fails.
dl_remove_work_dir() {
  local real
  real=$(dl_work_dir_ok "$1" "$2") && [ -n "$real" ] || return 1
  rm -rf "$real" 2>/dev/null
  [ ! -e "$real" ]
}

# dl_suite_end SUITE WORK PASSED FAILED: print the suite's summary line; on a green run (FAILED 0) remove
# its work dir (prefix dev-loop-SUITE) unless DEV_LOOP_KEEP_WORK=1, else keep it and name it. Returns 0
# only on a green run.
dl_suite_end() {
  local where="work dir $2"
  if [ "$4" -eq 0 ] && [ "${DEV_LOOP_KEEP_WORK:-}" != 1 ]; then
    cd / || return 1
    if dl_remove_work_dir "$2" "dev-loop-$1"; then
      where="work dir removed"
    else where="$where, not removed"; fi
  fi
  echo "$1: $3 passed, $4 failed ($where)"
  [ "$4" -eq 0 ]
}

# dl_work_dir_fresh PATH: something in PATH changed within DEV_LOOP_WORK_DIR_SETTLE_MINUTES (default 10;
# 0 turns it off), as when a straggler of a stopped stage still writes there. find cannot look into a subdir
# it cannot read, so a change in there does not count and such a dir can count as not fresh; rm then fails on
# that subdir, so the dir may be left partly removed, but it stays recorded for a later run.
dl_work_dir_fresh() {
  local minutes=${DEV_LOOP_WORK_DIR_SETTLE_MINUTES:-10}
  case $minutes in '' | *[!0-9]*) minutes=10 ;; esac
  [ "$minutes" -gt 0 ] || return 1
  [ -n "$(find "$1" -mmin "-$minutes" 2>/dev/null | head -n 1)" ]
}

# dl_prune_work_dirs RECORD LOG...: the gate's pruning. Add the work dirs the LOGs name ("(work dir PATH)"
# or "(work dir PATH, ...)") to the RECORD file, then for each prefix keep only the newest recorded dir that
# still exists and remove the older ones (dl_remove_work_dir, so only a suite's own dir) unless they changed
# lately (dl_work_dir_fresh); RECORD keeps the dirs left, in their order. Nothing the logs do not name is
# touched.
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
      dl_work_dir_ok "$path" "$prefix" >/dev/null || continue
      [ -z "$newest" ] || { ! dl_work_dir_fresh "$newest" && dl_remove_work_dir "$newest" "$prefix"; } ||
        kept+="$newest"$'\n'
      newest=$path
    done <"$record"
    [ -z "$newest" ] || kept+="$newest"$'\n'
  done
  printf '%s' "$kept" >"$record.tmp.$$" && mv -f "$record.tmp.$$" "$record"
}
