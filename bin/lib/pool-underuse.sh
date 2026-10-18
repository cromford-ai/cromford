#!/bin/bash
# bin/lib/pool-underuse.sh — the pool's under-use alert: work is queued, slots
# are free, and the pool still builds far less than it could (BH-7382).
#
# The stall alert (bin/lib/pool-stall.sh) only fires when NOTHING is building
# and no slot is free. A pool that builds 5 while 22 wait and the cap would
# take more never matched it: on 2026-10-18 project-6-os sat like that for
# hours, with every spawned build refused at the context gate, and no line said
# so.
#
# TWO HALVES, the pool-stall.sh shape.
#   1. pool_underuse_verdict: pure. Every input is an argument, the answer is
#      one line. tests/fly-pool-underuse.bh-7382-test.sh drives it as a table.
#   2. pool_underuse_tick: runs in bin/fly-pool.sh's own shell after the spawn
#      budget. It reads the caller's P QUEUED BUDGET CAP POOL LISTING LIST_OK
#      and say, so the hotspot file carries one call line.
#
# The root is ${HARNESS:-} and nothing else (D43): with no root the tick does
# nothing and returns non-zero.

_pu_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# pool_underuse_verdict <queued> <building|unknown> <cap> <since_epoch|-> <now>
#                       <threshold_s> <queue_min> <pct>
# -> `clear`, `pending<TAB><age_s>` or `underuse<TAB><age_s>`.
# Capacity is the cap when one is set (> 0), else building + queued (with no
# cap every queued job gets a machine, so that is what the pool should run).
# Under-used now: queued > queue_min AND building*100 < pct*capacity. A count
# this tick could not read (building `unknown`) is never under-use. The age is
# now - since, `-` is age 0; age >= threshold is `underuse`. threshold 0 = off.
# A non-number in any input is `clear` and rc 2.
pool_underuse_verdict() {
  local q="${1:-}" b="${2:-}" cap="${3:-}" since="${4:-}" now="${5:-}" thr="${6:-}" qmin="${7:-}" pct="${8:-}" capacity age
  _pu_int "$q" && _pu_int "$cap" && _pu_int "$now" && _pu_int "$thr" && _pu_int "$qmin" && _pu_int "$pct" \
    || { printf 'clear\n'; return 2; }
  case "$since" in -) ;; *) _pu_int "$since" || { printf 'clear\n'; return 2; } ;; esac
  [ "$b" = unknown ] && { printf 'clear\n'; return 0; }
  _pu_int "$b" || { printf 'clear\n'; return 2; }
  [ "$thr" = 0 ] && { printf 'clear\n'; return 0; }
  if [ "$cap" -gt 0 ]; then capacity="$cap"; else capacity=$((b + q)); fi
  if [ "$q" -le "$qmin" ] || [ $((b * 100)) -ge $((pct * capacity)) ]; then
    printf 'clear\n'; return 0
  fi
  age=0; [ "$since" = - ] || age=$((now - since))
  [ "$age" -lt 0 ] && age=0
  if [ "$age" -ge "$thr" ]; then printf 'underuse\t%s\n' "$age"; else printf 'pending\t%s\n' "$age"; fi
  return 0
}

# _pu_knob <ENV> <default> <max> — the knob as a number, or the default with
# one say line naming the bad value (D11).
_pu_knob() {
  local n="${1:-}" d="${2:-}" mx="${3:-}" v
  v="${!n:-$d}"
  if ! _pu_int "$v" || { [ -n "$mx" ] && [ "$v" -gt "$mx" ]; }; then
    command -v say >/dev/null 2>&1 && say "$n=$v is not a number of 0-$mx — using $d"
    v="$d"
  fi
  printf '%s\n' "$v"
}

# pool_underuse_tick — after the spawn budget, beside pool_stall_tick.
# building = job files whose machine this tick's listing has `started`;
# orphans = job files on a machine the listing does not return. An unusable
# listing makes building `unknown`, which is never an alert (the BH-7107 rule).
# Keeps state/pool-underuse/<p>.json {since} while under-used and removes it on
# a clear tick. On `underuse`: one say line every tick, and one ALERTS line per
# project per hour (flag alerted-pool-underuse-<p>-h<HH>-<YYYYmmdd> through
# bin/lib/flags.sh, set before the send).
pool_underuse_tick() {
  local root="${HARNESS:-}" thr qmin pct q cap bl=0 orph=0 f m st sf since now out vst age capacity af tmp captxt
  [ -n "$root" ] && [ -n "${P:-}" ] || return 1
  thr=$(_pu_knob POOL_UNDERUSE_ALERT_S 900 86400)
  qmin=$(_pu_knob POOL_UNDERUSE_QUEUE_MIN 5 100000)
  pct=$(_pu_knob POOL_UNDERUSE_PCT 50 100)
  q="${QUEUED:-}"; cap="${CAP:-0}"
  _pu_int "$cap" || cap=0
  if [ "${LIST_OK:-0}" = 1 ] && [ -s "${LISTING:-}" ]; then
    for f in "${POOL:-}"/*.json; do
      [ -f "$f" ] || continue
      m=$(jq -r '.machine // ""' "$f" 2>/dev/null)
      st=$(jq -r --arg m "$m" '[.[] | select(.id == $m) | (.state // "")][0] // "absent"' "$LISTING" 2>/dev/null)
      case "$st" in started) bl=$((bl + 1)) ;; absent) orph=$((orph + 1)) ;; esac
    done
  else
    bl=unknown
  fi
  sf="$root/state/pool-underuse/$P.json"
  since=$(jq -r '.since // "-"' "$sf" 2>/dev/null); _pu_int "$since" || since=-
  now=$(date +%s)
  out=$(pool_underuse_verdict "$q" "$bl" "$cap" "$since" "$now" "$thr" "$qmin" "$pct")
  vst="${out%%	*}"; age="${out#*	}"
  [ "$vst" = clear ] && { rm -f "$sf"; return 0; }
  [ "$since" = - ] && since="$now"
  mkdir -p "$root/state/pool-underuse" 2>/dev/null
  tmp="$sf.tmp.$$"
  jq -nc --argjson s "$since" '{since:$s}' > "$tmp" 2>/dev/null && mv -f "$tmp" "$sf" || rm -f "$tmp"
  [ "$vst" = underuse ] || return 0
  if [ "$cap" -gt 0 ]; then capacity="$cap"; captxt="$cap"; else capacity=$((bl + q)); captxt=unlimited; fi
  out="under-used for $((age / 60))m: queued $q, building $bl of capacity $capacity (${pct}% floor); orphans $orph, spawning ${BUDGET:-?}, cap=$captxt"
  command -v say >/dev/null 2>&1 && say "$out"
  af="alerted-pool-underuse-$P-$(date -u +h%H-%Y%m%d)"
  command -v flag_set >/dev/null 2>&1 \
    || . "$(dirname "${BASH_SOURCE[0]}")/flags.sh" 2>/dev/null || true
  # No flags lib: no hourly dedup, so no alert (every tick would page). The
  # say line above still records the under-use.
  if ! command -v flag_has >/dev/null 2>&1; then
    command -v say >/dev/null 2>&1 && say "pool-underuse: alert not sent (bin/lib/flags.sh did not load)"
    return 0
  fi
  flag_has --cached "$af" 2>/dev/null && return 0
  flag_set "$af" on "pool-underuse: alert sent" >/dev/null 2>&1
  HARNESS="$root" "$root/bin/alert-line.sh" "[pool/$P] $out"
  return 0
}
