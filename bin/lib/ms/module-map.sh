# shellcheck shell=bash
# bin/lib/module-map.sh — the generic module loader and its order engine.
# Sourced, never run. docs/MODULE-MAP.md has the pattern.
#
# A MODULE is a `<dir>/<name>.sh` file whose header line, the first line in its
# first 30 lines that starts with "# module:", reads
#
#   # module: <name> after: <dep> <dep>...
#
# <name> and every <dep> match [a-z0-9][a-z0-9_-]*. Deps are separated by
# spaces or commas. "after:" with nothing after it, or no "after:", means no
# deps. <name> must be the file's basename without ".sh". A .sh file with no
# "# module:" line is not a module: it is never loaded and never checked. A
# "# module:" line that does not match the grammar is an error, not a skip, so
# a typo never drops a module silently.
#
#   mm_order <dir>   print the load order, one name per line. Kahn's sort; among
#                    the modules that are ready, the LC_ALL=C first name goes
#                    first. rc 1 on any error (each one a line on stderr:
#                    unknown dep, cycle, name/basename mismatch, malformed
#                    header, zero modules), rc 2 when <dir> is not a directory.
#   mm_load <dir>    source every module of <dir> in order. The order is
#                    <dir>/MODULES when that file is readable (it is generated
#                    by bin/module-map-build.sh), else mm_order over the
#                    headers. Every listed file is checked readable BEFORE any
#                    is sourced, so a missing file sources nothing. rc 0 all
#                    sourced, rc 1 a missing file or a bad order (nothing
#                    sourced) or a module whose source failed (the modules
#                    before it stay sourced; the message names the failed one),
#                    rc 2 when <dir> is not a directory.
#
# mm_load sources at FUNCTION scope: a module's top-level `declare`, `typeset`
# or `local` with no -g would be local to mm_load and lost when it returns.
# bin/module-map-build.sh --check refuses such a line. mm_load's own variables
# are locals named _mm_*, so a module's top-level assignment is never captured.

_MM_NAME_RE='^[a-z0-9][a-z0-9_-]*$'
_MM_HEADER_RE='^# module: ([a-z0-9][a-z0-9_-]*)( after:([ ,]+[a-z0-9][a-z0-9_-]*)*)?$'

# _mm_header <file> <dir> — print "<name> <dep>..." for <file>'s header.
# rc 0 a module, rc 3 no header (not a module), rc 1 a malformed header
# (the reason printed on stderr).
_mm_header() {
  local f="$1" dir="$2" n=0 line deps
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ "$n" -le 30 ] || break
    line=${line%$'\r'}
    case "$line" in "# module:"*) ;; *) continue ;; esac
    if [[ $line =~ $_MM_HEADER_RE ]]; then
      deps=${BASH_REMATCH[2]# after:}
      deps=${deps//,/ }
      # shellcheck disable=SC2086 # word-split the dep list on purpose
      echo "${BASH_REMATCH[1]}" $deps
      return 0
    fi
    echo "module-map: $dir: ${f##*/}:$n: malformed header \"$line\" (want \"# module: <name> after: <deps>\")" >&2
    return 1
  done < "$f"
  return 3
}

# mm_order <dir> — see the header.
mm_order() {
  local dir="${1:-}" f base hdr rc name d bad=0 pick ready cur next i
  local -A after=() seen=() pos=()
  local -a names=() order=() path=()
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "module-map: $dir: not a directory" >&2; return 2
  fi
  [ "$dir" = / ] || dir=${dir%/}
  for f in "$dir"/*.sh; do
    [ -f "$f" ] || continue
    hdr=$(_mm_header "$f" "$dir"); rc=$?
    [ "$rc" = 3 ] && continue
    [ "$rc" = 0 ] || { bad=1; continue; }
    base=${f##*/}; base=${base%.sh}
    name=${hdr%% *}
    if [ "$name" != "$base" ]; then
      echo "module-map: $dir: $base.sh: header names module $name, and the name must be the basename $base" >&2
      bad=1; continue
    fi
    names+=("$name")
    after[$name]=${hdr#"$name"}
  done
  [ "$bad" = 0 ] || return 1
  if [ "${#names[@]}" = 0 ]; then
    echo "module-map: $dir: zero modules (no .sh file has a \"# module:\" header)" >&2; return 1
  fi
  mapfile -t names < <(printf '%s\n' "${names[@]}" | LC_ALL=C sort)
  for name in "${names[@]}"; do
    for d in ${after[$name]}; do
      [ -n "${after[$d]+x}" ] && continue
      echo "module-map: $dir: $name after: $d, and no module is named $d" >&2; bad=1
    done
  done
  [ "$bad" = 0 ] || return 1
  while [ "${#order[@]}" -lt "${#names[@]}" ]; do
    pick=""
    for name in "${names[@]}"; do
      [ -z "${seen[$name]:-}" ] || continue
      ready=1
      for d in ${after[$name]}; do
        [ -n "${seen[$d]:-}" ] || { ready=0; break; }
      done
      [ "$ready" = 1 ] && { pick=$name; break; }
    done
    if [ -z "$pick" ]; then
      # Nothing is ready, so every module left waits on another one left:
      # walk the first left-over dep from the first left-over name until a
      # name repeats, and print that loop.
      for name in "${names[@]}"; do [ -z "${seen[$name]:-}" ] && { cur=$name; break; }; done
      i=0
      while [ -z "${pos[$cur]:-}" ]; do
        i=$((i + 1)); pos[$cur]=$i; path+=("$cur")
        next=""
        for d in ${after[$cur]}; do [ -z "${seen[$d]:-}" ] && { next=$d; break; }; done
        cur=$next
      done
      f="cycle:"
      for ((i = pos[$cur] - 1; i < ${#path[@]}; i++)); do f="$f ${path[$i]} ->"; done
      echo "module-map: $dir: $f $cur" >&2
      return 1
    fi
    seen[$pick]=1
    order+=("$pick")
  done
  printf '%s\n' "${order[@]}"
}

# _mm_modules_file <file> — print the names a MODULES file lists. rc 1 (the
# reason on stderr) on a line that is not a module name.
_mm_modules_file() {
  local line n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    if ! [[ $line =~ $_MM_NAME_RE ]]; then
      echo "module-map: $1:$n: \"$line\" is not a module name" >&2; return 1
    fi
    echo "$line"
  done < "$1"
}

# mm_load <dir> — see the header.
mm_load() {
  local _mm_dir="${1:-}" _mm_list _mm_n
  if [ -z "$_mm_dir" ] || [ ! -d "$_mm_dir" ]; then
    echo "module-map: $_mm_dir: not a directory" >&2; return 2
  fi
  [ "$_mm_dir" = / ] || _mm_dir=${_mm_dir%/}
  if [ -r "$_mm_dir/MODULES" ]; then
    _mm_list=$(_mm_modules_file "$_mm_dir/MODULES") || return 1
    [ -n "$_mm_list" ] || { echo "module-map: $_mm_dir/MODULES: zero modules" >&2; return 1; }
  else
    _mm_list=$(mm_order "$_mm_dir") || return 1
  fi
  for _mm_n in $_mm_list; do
    [ -f "$_mm_dir/$_mm_n.sh" ] && [ -r "$_mm_dir/$_mm_n.sh" ] && continue
    echo "module-map: $_mm_dir: module $_mm_n has no readable file $_mm_dir/$_mm_n.sh; nothing sourced" >&2
    return 1
  done
  for _mm_n in $_mm_list; do
    # shellcheck disable=SC1090 # the module path is data
    . "$_mm_dir/$_mm_n.sh" || { echo "module-map: $_mm_dir: sourcing module $_mm_n ($_mm_dir/$_mm_n.sh) failed" >&2; return 1; }
  done
  return 0
}
