#!/bin/bash
# bin/lib/prr-count.sh — the shadow-read counter of prr_read (BH-10211 C0).
# Sourced, never executed. Defines functions only: no set -e, no exit.
#
# prr_read (bin/lib/prr-shadow.sh) in step shadow adds 1 to one kind per read.
# The counter is a box-local file under logs/, not a log line per read, so a lane's agreed
# reads can be counted without filling logs/prr-shadow.log.
#
#   prr_count_add <lane-id> <kind> [miss-word]
#       kind: agree (record and GitHub norms equal), mismatch (they differ:
#       prr_read also writes its PRR_SHADOW line), miss (the record missed:
#       also adds miss.<word>), skip (no compare: the GitHub read failed or a
#       norm output was empty). A word outside [a-z0-9_:.-] or over 40 chars
#       counts as miss.other. rc 2 on a bad lane id or kind, and nothing is
#       written. Any other failure (no root, lock timeout after
#       PRR_COUNT_LOCK_S seconds, a write error) writes nothing and is rc 0:
#       the counter never fails the lane.
#
#   prr_count_now
#       The counter clock: PRR_COUNT_NOW under HARNESS_TEST_SANDBOX=1, else
#       `date +%s`. The day of a file is the UTC date of this clock.
#
# File: <root>/logs/prr-count/<lane>/<YYYY-MM-DD>.tsv, root ${HARNESS:-${H:-}}.
# Under HARNESS_TEST_SANDBOX=1 a root that is the checkout this file was
# sourced from writes nothing: a test that points HARNESS at its own source
# tree (tests/tracker-seam-ported.bh-8892 does, to source the unblock
# collectors) must never leave a counter file, a tmp or a lock in the
# checkout (BH-10211, the trace-safety HIT of 2026-11-27).
# Rows `<key>\t<value>`: first (epoch of the first counted read that day),
# last (epoch of the newest), agree, mismatch, miss, miss.<word>, skip.
# Written read + add + tmp + mv under `flock -w PRR_COUNT_LOCK_S` on <file>.lock.
# Reader: bin/prr-shadow-ready.sh.
#
# RETENTION: when prr_count_add creates a new day file, it deletes that lane's
# day files (and their .lock files) older than PRR_COUNT_KEEP_DAYS days.
#
# Knobs (catalog/lanes.d/_lib.prr-count.json, settings rows
# lib.prr-count.<lower env>): PRR_COUNT_KEEP_DAYS, PRR_COUNT_LOCK_S, and the
# READY check's PRR_READY_HOURS and PRR_READY_MIN_AGREED. They are resolved
# once per source, the bin/lib/prr-seen.sh way: lib_env_apply in a SUBSHELL,
# so a fail-closed exit there never stops the lane that sourced this file.
if [ -n "${PRR_COUNT_LIB:-}" ]; then return 0 2>/dev/null; fi
PRR_COUNT_LIB=1
_PRR_COUNT_DIR="${BASH_SOURCE[0]%/*}"
# _prr_count_checkout — the checkout root this file was sourced from (physical path).
_prr_count_checkout() { (cd "$_PRR_COUNT_DIR/../.." 2>/dev/null && pwd -P); }
# fallback only: the knob is PRR_COUNT_KEEP_DAYS in catalog/lanes.d/_lib.prr-count.json
_PRR_COUNT_DEFAULT_KEEP_DAYS=14
# fallback only: the knob is PRR_COUNT_LOCK_S in catalog/lanes.d/_lib.prr-count.json
_PRR_COUNT_DEFAULT_LOCK_S=2

_PRR_COUNT_KV=$(
  exec 3>&1
  _PRR_COUNT_R=$(cd "$_PRR_COUNT_DIR/../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_PRR_COUNT_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  # No registry compose from the repo here (prr-seen.sh has one): prr_read is
  # the hot path of 7 lanes, and a root with no registry (a test scratch root)
  # reads the env value or the code fallback, with no TMPDIR write.
  trap 'printf "%s %s %s %s\n" "${PRR_COUNT_KEEP_DAYS:--}" "${PRR_COUNT_LOCK_S:--}" "${PRR_READY_HOURS:--}" "${PRR_READY_MIN_AGREED:--}" >&3' EXIT
  lib_env_apply prr-count >/dev/null 2>&1)
_PRR_COUNT_KV="${_PRR_COUNT_KV%%$'\n'*}"
if [ -n "$_PRR_COUNT_KV" ]; then
  read -r _prr_k1 _prr_k2 _prr_k3 _prr_k4 <<<"$_PRR_COUNT_KV"
  [ "$_prr_k1" = - ] || PRR_COUNT_KEEP_DAYS="$_prr_k1"
  [ "$_prr_k2" = - ] || PRR_COUNT_LOCK_S="$_prr_k2"
  [ "$_prr_k3" = - ] || PRR_READY_HOURS="$_prr_k3"
  [ "$_prr_k4" = - ] || PRR_READY_MIN_AGREED="$_prr_k4"
  unset _prr_k1 _prr_k2 _prr_k3 _prr_k4
fi
unset _PRR_COUNT_KV

# _prr_count_int <value> <fallback> — the value as digits (at least 1), else the fallback.
_prr_count_int() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) if [ "$((10#$1))" -ge 1 ]; then printf '%s' "$((10#$1))"; else printf '%s' "$2"; fi ;;
  esac
}

prr_count_now() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ "${PRR_COUNT_NOW:-}" =~ ^[0-9]{1,12}$ ]]; then
    printf '%s\n' "$PRR_COUNT_NOW"
  else
    date +%s
  fi
}

# _prr_count_prune <dir> <now> — delete day files older than the keep window.
_prr_count_prune() {
  local d="$1" now="$2" keep cut f b
  keep=$(_prr_count_int "${PRR_COUNT_KEEP_DAYS:-}" "$_PRR_COUNT_DEFAULT_KEEP_DAYS")
  cut=$(date -u -d "@$((now - keep * 86400))" +%F 2>/dev/null) || return 0
  for f in "$d"/*.tsv; do
    [ -e "$f" ] || continue
    b="${f##*/}"; b="${b%.tsv}"
    [[ "$b" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    if [[ "$b" < "$cut" ]]; then rm -f "$f" "$f.lock" 2>/dev/null; fi
  done
  return 0
}

prr_count_add() {
  local lane="${1:-}" kind="${2:-}" word="${3:-}" root="${HARNESS:-${H:-}}"
  local k2="" now day d f fd tmp src new=0 lock_s
  [[ "$lane" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 2
  case "$kind" in
    agree|mismatch|skip) ;;
    miss)
      if [[ "$word" =~ ^[a-z0-9_:.-]{1,40}$ ]]; then k2="miss.$word"; else k2="miss.other"; fi ;;
    *) return 2 ;;
  esac
  [ -n "$root" ] || return 0
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -d "$root" ]; then
    # a root that does not exist yet is never the checkout: mkdir makes it below
    local rp co
    rp=$(cd "$root" 2>/dev/null && pwd -P) || return 0
    co=$(_prr_count_checkout)
    [ -n "$co" ] && [ "$rp" = "$co" ] && return 0
  fi
  now=$(prr_count_now)
  day=$(date -u -d "@$now" +%F 2>/dev/null) || return 0
  d="$root/logs/prr-count/$lane"; f="$d/$day.tsv"
  mkdir -p "$d" 2>/dev/null || return 0
  lock_s=$(_prr_count_int "${PRR_COUNT_LOCK_S:-}" "$_PRR_COUNT_DEFAULT_LOCK_S")
  { exec {fd}>"$f.lock"; } 2>/dev/null || return 0
  if ! flock -w "$lock_s" "$fd" 2>/dev/null; then exec {fd}>&-; return 0; fi
  src="$f"; [ -e "$f" ] || { src=/dev/null; new=1; }
  tmp="$f.tmp.$$"
  awk -F'\t' -v OFS='\t' -v now="$now" -v k1="$kind" -v k2="$k2" '
    NF >= 2 && $1 != "" { if (!($1 in v)) o[++n] = $1; v[$1] = $2 }
    END {
      if (!("first" in v)) { o[++n] = "first"; v["first"] = now }
      if (!("last" in v)) o[++n] = "last"
      v["last"] = now
      if (!(k1 in v)) o[++n] = k1
      v[k1] = v[k1] + 1
      if (k2 != "") { if (!(k2 in v)) o[++n] = k2; v[k2] = v[k2] + 1 }
      for (i = 1; i <= n; i++) print o[i], v[o[i]]
    }' "$src" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null \
    || rm -f "$tmp" 2>/dev/null
  exec {fd}>&-
  [ "$new" = 1 ] && _prr_count_prune "$d" "$now"
  return 0
}
