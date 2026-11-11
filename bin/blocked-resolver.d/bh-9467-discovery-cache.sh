# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9467-discovery-cache.sh — BH-9467 (#9369 fix 3):
# incremental discovery. br_from_builds and br_from_rebuilds remember, per
# path, the path's signature and the decision they took on it, and skip a path
# whose signature has not changed since the last tick. And a one-PR run does
# not walk the build dirs or the queue rows at all.
#
# WHY. On 2026-11-09 the hub's cromford discovery took 906 s
# (rebuilds:416, builds:403): every tick read every build dir's RESULT and
# every open record, to take the same decision as the tick before.
#
# THE CACHE. One file per source and scope, at depth 1 of $ST (no record glob
# reads it), rewritten whole each tick (tmp + mv):
#   $ST/.disc-cache-<builds|rebuilds>-<project|fleet>.tsv
#     #bdc1\t<fleet.conf mtime>\t<BR_RECORD_MAX_AGE_DAYS>\t<project list>
#     <path>\t<signature>\t<skip|retired|wait>\t<epoch noted>
# A header that does not match discards the whole file (a fleet.conf edit
# moves project ownership and board prefixes). Only the paths seen this tick
# are written, so the file is bounded by the live dirs and records, and a
# deleted dir leaves it on the next write. Losing the file costs one full read.
#
# THE SIGNATURE. A build dir: `<dir mtime>:<RESULT mtime or ->` (a marker,
# RESULT, REAPED, COMMENTED or .review-rescued file created or removed moves
# the dir mtime; pr-url-reconcile's in-place rewrite moves the RESULT mtime).
# A record: `<mtime>:<size>`. One find per source per tick gives all of them.
#
# THE DECISIONS. The source notes a path only when its decision depends on
# nothing but the path (bdc_note): `skip`, `retired` (a skip that still counts
# in retired_skipped), or `wait` (a rebuild with no result yet, kept for
# BR_DISCOVERY_RECHECK_MIN minutes, because a remote result moves no local
# mtime). Every other path (an emitted row, a time floor, a state read) gets no
# entry and is read again next tick.
#
# Knobs (catalog/lanes.d/blocked-resolver.knobs.d/):
#   BR_DISCOVERY_CACHE        1   0 = off: every path is read, no file
#   BR_DISCOVERY_RECHECK_MIN  30  minutes a rebuild wait is kept; 0 = never kept
# A one-PR run (BR_ONLY_PR) never reads or writes a cache file.
# Call sites, one line each, in bin/lib/br/discovery.sh. BR_OPT_OFF=
# bh-9467-discovery-cache does not source this file: each source then runs as
# it did before, and a one-PR run walks every source again.

# bdc_knob <name> <default> — a non-negative integer knob into $_BDC_KNOB. A
#   non-number is said once per run and the default is used.
bdc_knob() {
  local n="$1" d="$2" v
  v="${!n:-$d}"
  case "$v" in
    ''|*[!0-9]*)
      case " ${_BDC_KNOB_SAID:-} " in
        *" $n "*) ;;
        *) say "$n is '$v', not a number — the fallback $d is used"
           _BDC_KNOB_SAID="${_BDC_KNOB_SAID:-} $n" ;;
      esac
      v="$d" ;;
  esac
  _BDC_KNOB="$v"
}

# bdc_on — rc 0 when the cache is on for this run.
bdc_on() {
  [ -z "${BR_ONLY_PR:-}" ] || return 1
  bdc_knob BR_DISCOVERY_CACHE 1
  [ "$_BDC_KNOB" != 0 ]
}

# bdc_file <source> — the cache path for this run's scope.
bdc_file() { printf '%s/.disc-cache-%s-%s.tsv' "$ST" "$1" "${ONLY:-fleet}"; }

# bdc_begin <builds|rebuilds> [project list] — the current signatures (one
#   find) and the last tick's entries (one builtin read). Sets _BDC_ON.
bdc_begin() {
  local src="$1" pl="${2:-}" f fc fm days hdr line pth rest t m dp
  declare -gA _BDC_SIG=() _BDC_OLD=() _BDC_NEW=()
  _BDC_SRC="$src"; _BDC_D=0; _BDC_H=0; _BDC_R=0; _BDC_ON=0
  bdc_on || return 0
  bdc_knob BR_DISCOVERY_RECHECK_MIN 30; _BDC_RECHECK="$_BDC_KNOB"
  _BDC_ON=1
  f=$(bdc_file "$src")
  fc="${FLEET_CONF:-$H/fleet.conf}"
  fm=$(find "$fc" -maxdepth 0 -printf '%T@' 2>/dev/null) || fm=""
  days="${BR_RECORD_MAX_AGE_DAYS:-14}"
  pl="${pl//$'\n'/,}"
  hdr=$(printf '#bdc1\t%s\t%s\t%s' "${fm:--}" "$days" "${pl:--}")
  _BDC_HDR="$hdr"
  if [ "$src" = builds ]; then
    local -A dm=() rm=()
    while IFS=$'\t' read -r dp t m pth; do
      case "$dp$t" in
        1d) dm["$pth"]="$m" ;;
        2f) rm["${pth%/RESULT}"]="$m" ;;
      esac
    # Depth 1 is the build dirs, depth 2 their RESULT; a dir at depth 2 is
    # pruned. The case above drops everything else.
    done < <(if [ -n "${ONLY:-}" ]; then
               find "$H/builds" -mindepth 1 -maxdepth 2 \( -type d -path "$H/builds/*/*" -prune \) -o \
                    \( -path "$H/builds/$ONLY-*" -o -path "$H/builds/pool-$ONLY-*" \) \( -type d -o -name RESULT \) \
                    -printf '%d\t%y\t%T@\t%p\n' 2>/dev/null
             else
               find "$H/builds" -mindepth 1 -maxdepth 2 \( -type d -path "$H/builds/*/*" -prune \) -o \
                    \( -type d -o -name RESULT \) -printf '%d\t%y\t%T@\t%p\n' 2>/dev/null
             fi)
    for pth in "${!dm[@]}"; do _BDC_SIG["$pth"]="${dm[$pth]}:${rm[$pth]:--}"; done
  else
    while IFS=$'\t' read -r pth m; do
      [ -n "$pth" ] && _BDC_SIG["$pth"]="$m"
    done < <(if [ -n "${ONLY:-}" ]; then
               [ -d "$ST/$ONLY" ] && find "$ST/$ONLY" -mindepth 1 -maxdepth 1 -name '*.json' -type f -printf '%p\t%T@:%s\n' 2>/dev/null
             else
               find "$ST" -mindepth 2 -maxdepth 2 -name '*.json' -type f -printf '%p\t%T@:%s\n' 2>/dev/null
             fi)
  fi
  [ -r "$f" ] || return 0
  line=""
  { IFS= read -r line || [ -n "$line" ]; } < "$f" 2>/dev/null
  if [ "$line" != "$hdr" ]; then
    say "discovery cache $src: the cache header does not match (fleet.conf, the project list or BR_RECORD_MAX_AGE_DAYS changed) — the cache is discarded, every path is read this tick"
    return 0
  fi
  while IFS=$'\t' read -r pth rest; do
    case "$pth" in ''|'#'*) continue ;; esac
    # A row is <sig>\t<decision>\t<epoch>; anything else is ignored.
    [[ "$rest" =~ ^[^$'\t']+$'\t'(skip|retired|wait)$'\t'[0-9]+$ ]] || continue
    _BDC_OLD["$pth"]="$rest"
  done < "$f"
  return 0
}

# bdc_skip <path> — rc 0 when the path is unchanged since the last tick and
#   its last decision still holds: carried forward and counted. rc 1: read it.
bdc_skip() {
  [ "${_BDC_ON:-0}" = 1 ] || return 1
  local p="$1" cur old osig odec oep
  _BDC_D=$((_BDC_D+1))
  cur="${_BDC_SIG["$p"]:-}"; old="${_BDC_OLD["$p"]:-}"
  [ -n "$cur" ] && [ -n "$old" ] || return 1
  osig="${old%%$'\t'*}"; oep="${old##*$'\t'}"; odec="${old#*$'\t'}"; odec="${odec%$'\t'*}"
  [ "$osig" = "$cur" ] || return 1
  case "$odec" in
    skip) ;;
    retired) command -v bdi_count >/dev/null 2>&1 && bdi_count ;;
    wait)
      [ "${_BDC_RECHECK:-0}" -gt 0 ] || return 1
      [ $(( EPOCHSECONDS - oep )) -ge 0 ] && [ $(( EPOCHSECONDS - oep )) -lt $(( _BDC_RECHECK * 60 )) ] || return 1 ;;
    *) return 1 ;;
  esac
  _BDC_NEW["$p"]="$old"
  _BDC_H=$((_BDC_H+1))
  return 0
}

# bdc_note <path> <skip|retired|wait> — the source decided this path for a
#   reason that depends on the path only. Written at bdc_end.
bdc_note() {
  [ "${_BDC_ON:-0}" = 1 ] || return 0
  local cur="${_BDC_SIG["$1"]:-}"
  [ -n "$cur" ] || return 0
  _BDC_NEW["$1"]="$cur	$2	$EPOCHSECONDS"
  return 0
}

# bdc_volatile <path> — the decision depends on time or on state outside the
#   path: no entry, so the path is read again next tick.
bdc_volatile() {
  [ "${_BDC_ON:-0}" = 1 ] || return 0
  unset '_BDC_NEW[$1]'
  return 0
}

# bdc_read — one RESULT read (builds) or one record read (rebuilds), counted
#   for the bdc_end line.
bdc_read() { _BDC_R=$(( ${_BDC_R:-0} + 1 )); return 0; }

# bdc_end <source> — the atomic rewrite and one line. A failed write is said:
#   the next tick then reads every path.
bdc_end() {
  [ "${_BDC_ON:-0}" = 1 ] || return 0
  local src="$1" f tmp p c=0
  f=$(bdc_file "$src"); tmp="$f.tmp.$$"
  c="${#_BDC_NEW[@]}"
  if { printf '%s\n' "$_BDC_HDR"
       for p in "${!_BDC_NEW[@]}"; do printf '%s\t%s\n' "$p" "${_BDC_NEW[$p]}"; done
     } > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then
    say "discovery cache $src: $_BDC_D path(s), $_BDC_H unchanged and skipped, $_BDC_R read ($c cache rows written)"
  else
    rm -f "$tmp" 2>/dev/null
    say "discovery cache $src: $_BDC_D path(s), $_BDC_H unchanged and skipped, $_BDC_R read — the discovery cache was not written — the next tick reads every path"
  fi
  _BDC_ON=0
  return 0
}

# bdc_one_pr — rc 0 in a one-PR run: br_candidates then skips br_from_queue and
#   br_from_builds. Every row they emit carries url `-`, and the driver's one-PR
#   filter keeps only rows whose url is the PR, so no candidate is lost.
bdc_one_pr() {
  [ -n "${BR_ONLY_PR:-}" ] || return 1
  say "one-PR run for $BR_ONLY_PR: builds and queue sources skipped (their rows carry no PR url)"
  return 0
}

# bdc_one_pr_files <array name> — in a one-PR run, fill the array with the
#   records of this project that name the PR url (ONE grep), and rc 0. rc 1
#   (not a one-PR run, or a grep that did not read): the caller globs as before.
bdc_one_pr_files() {
  local -n _bdc_out="$1"
  local u rc=0 out
  [ -n "${BR_ONLY_PR:-}" ] && [ -n "${ONLY:-}" ] || return 1
  u="https://github.com/${BR_ONLY_PR%#*}/pull/${BR_ONLY_PR##*#}"
  _bdc_out=()
  [ -d "$ST/$ONLY" ] || return 0
  out=$(grep -lF -- "\"$u\"" "$ST/$ONLY"/*.json 2>/dev/null) || rc=$?
  case "$rc" in
    0) mapfile -t _bdc_out <<<"$out" ;;
    1) ;;
    *) say "one-PR run for $BR_ONLY_PR: the record grep did not read (rc $rc) — every record is read"
       return 1 ;;
  esac
  return 0
}
