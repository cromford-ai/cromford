#!/bin/bash
# bin/lib/pool-launch-limit.sh — the per-tick machine launch limit of the Fly
# pool SPAWN walk, shared by every project tick one bin/fly-pool-tick.sh run
# starts (BH-8915).
#
# On 2026-10-29 a re-put backlog made the pool start 60-75 machines in one tick
# and Fly's machines API rate limit refused most of them. The limit counts
# launches in this tick across projects and holds the rest for the next tick.
# It does not cap how many machines run: the pool cap does that.
#
# The count. bin/fly-pool-tick.sh makes one tick dir per wrapper run
# (state/fly-pool-launch/<UTC stamp>.<pid>/) and exports it as
# POOL_LAUNCH_TICK_DIR. A launch slot is the dir "$POOL_LAUNCH_TICK_DIR/<n>",
# n = 1..limit, and the first `mkdir` that succeeds is the slot. mkdir is atomic
# across processes, so parallel project ticks never take more than `limit`
# slots, and no flock is needed. With no POOL_LAUNCH_TICK_DIR (a tick started
# by hand, on a lane-run machine or on another box) the count is in this
# process only. A POOL_LAUNCH_TICK_DIR that is set and is not a dir (pruned
# under a tick that ran past POOL_TICK_HARD_LIMIT_S) refuses every slot for the
# rest of that tick: fail closed, the rows wait for the next tick.
#
#   pll_limit       prints the limit: POOL_LAUNCH_PER_TICK, settings row
#                   lane.fly-pool.pool_launch_per_tick
#                   (catalog/lanes.d/fly-pool.knobs.d/POOL_LAUNCH_PER_TICK.json).
#                   Unset or empty: the documented fallback 20. A value that is
#                   not a number in 0..1000: 20 and one line. 0 = no limit.
#   pll_take        rc 0 = one launch slot taken (limit 0: always, no write).
#                   rc 1 = the limit is spent this tick. Caller's shell, never
#                   `$( )`: the in-process count lives in _PLL_N.
#   pll_spent       rc 0 when limit > 0 and every slot is taken. Writes nothing.
#   pll_used        prints the number of slots taken this tick.
#   pll_held_line   when PLL_HELD > 0, says the one held line of the tick.
#
# The limit is PLL_LIMIT when the caller set it (bin/fly-pool.sh reads it once
# per tick), else pll_limit. Uses `say` when the caller has it, else stderr.
# Defines functions only.

_PLL_N=0
# The last slot number this process took. Slots fill as a prefix (every taker
# tries 1, 2, ... in order and slots are never removed), so the next free slot
# is above it and a take starts there instead of at 1.
_PLL_LAST=0

_pll_say() { if declare -F say >/dev/null 2>&1; then say "$@"; else echo "$*" >&2; fi; }

pll_limit() {
  local v="${POOL_LAUNCH_PER_TICK:-}"
  [ -n "$v" ] || { echo 20; return 0; }
  case "$v" in
    *[!0-9]*) v="" ;;
    *) if [ "${#v}" -gt 4 ] || [ "$((10#$v))" -gt 1000 ]; then v=""; else v=$((10#$v)); fi ;;
  esac
  if [ -z "$v" ]; then
    _pll_say "POOL_LAUNCH_PER_TICK=$POOL_LAUNCH_PER_TICK is not a number of launches (0-1000) — using 20"
    v=20
  fi
  echo "$v"
}

_pll_lim() {
  case "${PLL_LIMIT:-}" in
    ''|*[!0-9]*) pll_limit ;;
    *) echo "$PLL_LIMIT" ;;
  esac
}

pll_used() {
  local d="${POOL_LAUNCH_TICK_DIR:-}"
  if [ -z "$d" ]; then echo "$_PLL_N"; return 0; fi
  [ -d "$d" ] || { echo 0; return 0; }
  find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

pll_spent() {
  local lim d="${POOL_LAUNCH_TICK_DIR:-}"
  lim=$(_pll_lim)
  [ "$lim" -gt 0 ] || return 1
  if [ -n "$d" ] && [ ! -d "$d" ]; then return 0; fi
  [ "$(pll_used)" -ge "$lim" ]
}

pll_take() {
  local lim n d="${POOL_LAUNCH_TICK_DIR:-}"
  lim=$(_pll_lim)
  [ "$lim" -gt 0 ] || return 0
  if [ -z "$d" ]; then
    [ "$_PLL_N" -lt "$lim" ] || return 1
    _PLL_N=$((_PLL_N + 1)); return 0
  fi
  [ -d "$d" ] || return 1
  for ((n = _PLL_LAST + 1; n <= lim; n++)); do
    if mkdir "$d/$n" 2>/dev/null; then _PLL_N=$((_PLL_N + 1)); _PLL_LAST=$n; return 0; fi
  done
  return 1
}

pll_held_line() {
  local lim
  [ "${PLL_HELD:-0}" -gt 0 ] 2>/dev/null || return 0
  lim=$(_pll_lim)
  _pll_say "launch limit: held $PLL_HELD launch(es) past pool_launch_per_tick=$lim ($(pll_used) of $lim used this tick across projects) — they wait for the next tick"
}
