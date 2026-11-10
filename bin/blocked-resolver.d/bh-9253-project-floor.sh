# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9253-project-floor.sh — BH-9253: every project
# with parked work keeps a floor of rungs in a tick, and a tick that ran 0
# rungs while its own hand-offs got no ack writes one alert line.
#
# WHY. hub-2, 2026-11-08 11:58Z: `rungs=0/50 reason=drained visited=[project-5]`
# and `HANDOFF-WAIT summary: 50 hand-off(s) not dispatched this tick`. Six
# parked cromford PRs waited behind project-5 tick after tick, and no
# line said that a tick dispatched nothing.
#
# THE FLOOR (BR_PROJECT_FLOOR, row lane.blocked-resolver.br_project_floor,
# fallback 1, 0 = off). A reservation inside the main loop, not a hard slice:
# a row is skipped (not a break) when its project already holds >= floor rungs
# AND N + reserve >= EFF_PER_TICK, where reserve is the sum of floor - NP[q]
# over every other non-held project q that still has rows ahead in the list and
# holds fewer than floor rungs. A one-project run has reserve 0 and runs as
# before. The skipped row goes to br_note_untouched and waits for the next tick.
#
# THE ALERT (BR_ZERO_DISPATCH_ALERT, row lane.blocked-resolver.br_zero_dispatch_alert,
# fallback 1, 0 = off). After bhw_sweep: when N = 0 and at least one of THIS
# run's own candidates (non-held projects) has no `dispatched`, `lock-held`,
# `held` or `acted` ack at or after BHW_TICK_AT, ONE
# `bin/alert-line.sh --id br-zero-dispatch:<scope>` line. It reads only the ack
# files of this run's own rows, never the shared tick-cands or wait.tsv, so a
# sibling project run cannot make it fire or keep it quiet.
#
# Call sites in bin/blocked-resolver.sh, each one guarded `command -v` line:
#   brpf_init            after the ALLORDER/NPROJ pass
#   brpf_take <pb>       on every row the loop reads (after the empty-RKEY test)
#   brpf_skip <pb>       after the per-project share check
#   brpf_zero_alert      after bhw_sweep
# Log lines: PROJECT_FLOOR (once per project per tick, on a skip only) and
# ZERO_DISPATCH (once per tick, with the alert).

# brpf_floor — the floor, a non-negative integer (fallback 1).
brpf_floor() {
  local v="${BR_PROJECT_FLOOR:-1}"
  case "$v" in
    ''|*[!0-9]*)
      [ "${_BRPF_BADSAID:-}" = 1 ] || { _BRPF_BADSAID=1; say "PROJECT_FLOOR: BR_PROJECT_FLOOR='$v' is not a non-negative integer — the floor is 1"; }
      v=1 ;;
  esac
  printf '%s' "$((10#$v))"
}

# brpf_init — BRPF_LEFT[<bucket>] = the rows per project bucket in CANDS (an
#   empty project is "-"), held projects left out. BRPF_SAID resets. Both
#   knobs are read HERE, once, at their fleet values: br_env_for_project
#   applies each project's own rows as the loop moves on, and a floor that
#   changed with the row's project would not be one tick budget.
brpf_init() {
  local line xp xk xb
  declare -gA BRPF_LEFT=()
  BRPF_SAID=" "
  BRPF_FL=$(brpf_floor)
  BRPF_ZA="${BR_ZERO_DISPATCH_ALERT:-1}"
  for line in ${CANDS[@]+"${CANDS[@]}"}; do
    IFS=$'\t' read -r _ xp xk _ <<<"$line"
    [ -n "${xk:-}" ] || continue
    xb="${xp:--}"
    if [ "$xb" != - ] && command -v lane_project_held >/dev/null 2>&1 \
       && lane_project_held blocked-resolver "$xb"; then continue; fi
    BRPF_LEFT[$xb]=$(( ${BRPF_LEFT[$xb]:-0} + 1 ))
  done
  return 0
}

# brpf_take <bucket> — this row of <bucket> is no longer ahead in the list.
brpf_take() {
  local b="${1:--}"
  [ -n "${BRPF_LEFT[$b]+x}" ] || return 0
  [ "${BRPF_LEFT[$b]}" -gt 0 ] && BRPF_LEFT[$b]=$(( BRPF_LEFT[$b] - 1 ))
  return 0
}

# brpf_skip <bucket> — rc 0 = skip this row (see the header), rc 1 = run it.
brpf_skip() {
  local b="${1:--}" fl q have reserve=0 names=""
  fl="${BRPF_FL:-}"; [ -n "$fl" ] || fl=$(brpf_floor)
  [ "$fl" -gt 0 ] || return 1
  have="${NP[$b]:-0}"
  [ "$have" -ge "$fl" ] || return 1
  for q in "${!BRPF_LEFT[@]}"; do
    [ "$q" = "$b" ] && continue
    [ "${BRPF_LEFT[$q]:-0}" -gt 0 ] || continue
    [ "${NP[$q]:-0}" -lt "$fl" ] || continue
    reserve=$(( reserve + fl - ${NP[$q]:-0} ))
    names="${names:+$names }$q"
  done
  [ "$reserve" -gt 0 ] || return 1
  [ $(( ${N:-0} + reserve )) -ge "${EFF_PER_TICK:-0}" ] || return 1
  case "${BRPF_SAID:- }" in
    *" $b "*) ;;
    *) BRPF_SAID="${BRPF_SAID:- }$b "
       say "PROJECT_FLOOR $b skipped: $reserve rung(s) kept for [$(tr ' ' '\n' <<<"$names" | LC_ALL=C sort | paste -sd' ' -)] (BR_PROJECT_FLOOR=$fl, rungs=${N:-0}/${EFF_PER_TICK:-0})" ;;
  esac
  return 0
}

# _brpf_acked <project> <tkey> <url> — rc 0 when either ack id of the row has
#   an ack of a counted kind at or after BHW_TICK_AT.
_brpf_acked() {
  local d id k tick
  d=$(bhw__dir) || return 1
  tick="${BHW_TICK_AT:-0}"
  for id in "$(bhw_id "$1" "$2" - 2>/dev/null)" "$(bhw_id "$1" - "$3" 2>/dev/null)"; do
    [ -n "$id" ] || continue
    for k in dispatched lock-held held acted; do
      bhw__ackat "$d/acks/$id.$k"
      [ "$BHW_A" -gt 0 ] && [ "$BHW_A" -ge "$tick" ] && return 0
    done
  done
  return 1
}

# brpf_zero_alert — see the header. rc 0 always.
brpf_zero_alert() {
  local on="${BRPF_ZA:-${BR_ZERO_DISPATCH_ALERT:-1}}" line xp xk xurl xtk xpk k=0 oldest="" oldat="" seen=" " id scope
  [ "$on" != 0 ] || return 0
  [ "${BHW_ON:-0}" = 1 ] || return 0
  [ "${N:-0}" = 0 ] || return 0
  command -v bhw_id >/dev/null 2>&1 && command -v bhw__ackat >/dev/null 2>&1 || return 0
  for line in ${CANDS[@]+"${CANDS[@]}"}; do
    IFS=$'\t' read -r _ xp xk _ xurl _ xtk xpk <<<"$line"
    [ -n "${xk:-}" ] || continue
    if [ -n "${xp:-}" ] && [ "$xp" != - ] && command -v lane_project_held >/dev/null 2>&1 \
       && lane_project_held blocked-resolver "$xp"; then continue; fi
    id=$(bhw_id "${xp:-}" "${xtk:--}" "${xurl:--}" 2>/dev/null) || id="${xp:--}/$xk"
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    _brpf_acked "${xp:-}" "${xtk:--}" "${xurl:--}" && continue
    k=$((k + 1)); [ -n "$oldest" ] || oldest="$id"
    # The oldest park by its epoch; a row with no epoch never displaces one.
    case "${xpk:-}" in
      ''|*[!0-9]*) ;;
      *) if [ -z "$oldat" ] || [ "$xpk" -lt "$oldat" ]; then oldat="$xpk"; oldest="$id"; fi ;;
    esac
  done
  [ "$k" -gt 0 ] || return 0
  scope="${ONLY:-fleet}"
  if [ "${OBSERVE:-0}" = 1 ]; then
    say "ZERO_DISPATCH $scope: this tick ran 0 rungs and dispatched 0 of $k hand-off(s) (observe mode: no alert written)"
    return 0
  fi
  say "ZERO_DISPATCH $scope: this tick ran 0 rungs and dispatched 0 of $k hand-off(s) (rungs=0/${EFF_PER_TICK:-0} reason=${STOPREASON:-?}); one br-zero-dispatch alert line"
  HARNESS="$H" "$H/bin/alert-line.sh" --id "br-zero-dispatch:$scope" \
    "[blocked-resolver] $scope: this tick ran 0 rungs and dispatched 0 of $k hand-off(s) (rungs=0/${EFF_PER_TICK:-0} reason=${STOPREASON:-?} visited=[${VISITLIST:-}]); oldest: $oldest" >/dev/null 2>&1 \
    || say "ZERO_DISPATCH $scope: the alert line could not be written"
  return 0
}
