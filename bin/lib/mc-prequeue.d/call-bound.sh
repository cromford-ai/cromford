#!/bin/bash
# bin/lib/mc-prequeue.d/call-bound.sh — EACH PREQUEUE CALL IS NAMED, TIMED AND
# BOUNDED (BH-7029). Sourced by bin/lib/mc-prequeue.sh's hook loop, never
# executed; no side effect at source time.
#
# WHY. The prequeue step ran past MC_STEP_TIMEOUT_S (240 s) and the kill named
# only the step. The call trace (bin/lib/call-trace.sh) records a call when it
# ENDS, so the call that ran at the kill was never in it.
#
# THE CALL FILE. One line, `<epoch>\t<path>\t<r|w>\t<shell pid>\t<start cs>`:
# the call in flight, its path (`resolve/merge-test` for a call inside a call),
# read or write, the shell that runs it ($BASHPID) and its start in
# centiseconds since boot (/proc/uptime). It is MC_CALL_FILE (<mark>.call, a
# local of mc_worker_bounded, which the step watchdog reads at a kill), or a
# private mktemp file while pq_gate runs outside a bounded worker. With
# neither, pq_call only times and logs.
#
#   pq_call [-w] <name> <cmd> [args...]
#       Runs <cmd> IN THIS SHELL (the hooks set PQ_* and memo arrays in place),
#       with the call file naming it, then logs
#       `<slug>#<num> PREQUEUE_CALL call=<path> took=<s.s>s rc=<rc>` and returns
#       <cmd>'s rc. -w marks a write (a push, a dispatch, a commit status).
#       Once the budget passed it runs nothing, logs `... skipped=over-budget`
#       and returns 124.
#   pq_over               rc 0 once this gate's budget passed
#   _pq_budget_start <s>  the timer: after <s> seconds it writes <file>.over
#                         (with the call in flight) and, when that call is a
#                         read, kills it (_pq_call_kill)
#   _pq_budget_stop       stops the timer, removes .over and the private file
#
# THE KILL (_pq_call_kill). Only a READ is killed: a write runs to its end and
# every later call is refused. The targets are the direct children of the
# shell that runs the call, in that shell's session, that started at or after
# the call did. A child from before the call (an async log write), a setsid
# child (a detached lane) and the timer itself are never touched. Each target
# gets TERM with its tree (_mc_kill_tree), then KILL 3 s later if it is still
# there.

_pq_cs=(); _pq_cl=(); _pq_cf=""; _pq_tp=""; _pq_priv=""

pq_over() { [ -n "$_pq_cf" ] && [ -e "$_pq_cf.over" ]; }

pq_call() {
  local _pqc_w=r _pqc_n _pqc_p _pqc_f="${_pq_cf:-${MC_CALL_FILE:-}}" _pqc_t0 _pqc_t1 _pqc_up="" _pqc_rc=0 _pqc_d
  [ "${1:-}" = -w ] && { _pqc_w=w; shift; }
  _pqc_n="${1:-?}"; shift
  _pqc_p="${_pq_cs[*]+${_pq_cs[*]} }$_pqc_n"; _pqc_p="${_pqc_p// //}"
  if pq_over; then
    mc_log "${_pq_key:-${KEY:-?}} PREQUEUE_CALL call=$_pqc_p skipped=over-budget" 2>/dev/null
    return 124
  fi
  [ -r /proc/uptime ] && read -r _pqc_up _ < /proc/uptime 2>/dev/null
  _pqc_up="${_pqc_up//[!0-9]/}"
  _pq_cs+=("$_pqc_n")
  _pq_cl+=("${EPOCHSECONDS}"$'\t'"$_pqc_p"$'\t'"$_pqc_w"$'\t'"$BASHPID"$'\t'"$_pqc_up")
  [ -n "$_pqc_f" ] && printf '%s\n' "${_pq_cl[-1]}" > "$_pqc_f" 2>/dev/null
  _pqc_t0="${EPOCHREALTIME//[!0-9]/}"
  "$@" || _pqc_rc=$?
  _pqc_t1="${EPOCHREALTIME//[!0-9]/}"
  unset '_pq_cs[-1]' '_pq_cl[-1]'
  if [ -n "$_pqc_f" ]; then
    if [ "${#_pq_cl[@]}" -gt 0 ]; then printf '%s\n' "${_pq_cl[-1]}" > "$_pqc_f" 2>/dev/null
    else : > "$_pqc_f" 2>/dev/null; fi
  fi
  _pqc_d=$(( (10#$_pqc_t1 - 10#$_pqc_t0) / 100000 )); [ "$_pqc_d" -ge 0 ] || _pqc_d=0
  mc_log "${_pq_key:-${KEY:-?}} PREQUEUE_CALL call=$_pqc_p took=$((_pqc_d / 10)).$((_pqc_d % 10))s rc=$_pqc_rc" 2>/dev/null
  return "$_pqc_rc"
}

# _pq_call_kill <call file> <timer pid> — THE KILL, above. Always rc 0.
_pq_call_kill() {
  local f="$1" tp="$2" cw sh up sid hz k ks st rest kl=()
  [ -r "$f" ] || return 0
  IFS=$'\t' read -r _ _ cw sh up < "$f" 2>/dev/null
  [ "$cw" = r ] && [[ "$sh" =~ ^[0-9]+$ ]] && [[ "$up" =~ ^[0-9]+$ ]] || return 0
  command -v ps >/dev/null 2>&1 || return 0
  hz=$(getconf CLK_TCK 2>/dev/null); [[ "$hz" =~ ^[1-9][0-9]*$ ]] || hz=100
  sid=$(ps -o sid= -p "$sh" 2>/dev/null | tr -d ' ')
  for k in $(ps -o pid= --ppid "$sh" 2>/dev/null); do
    [ "$k" = "$tp" ] && continue
    ks=$(ps -o sid= -p "$k" 2>/dev/null | tr -d ' ')
    [ -n "$sid" ] && [ "$ks" = "$sid" ] || continue
    rest=$(cat "/proc/$k/stat" 2>/dev/null) || continue
    rest="${rest##*) }"; read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ st _ <<<"$rest"
    [[ "$st" =~ ^[0-9]+$ ]] || continue
    [ $(( st * 100 / hz )) -ge "$((10#$up))" ] && kl+=("$k")
  done
  [ "${#kl[@]}" -gt 0 ] || return 0
  for k in "${kl[@]}"; do
    if declare -F _mc_kill_tree >/dev/null; then _mc_kill_tree TERM "$k"; else kill -TERM "$k" 2>/dev/null; fi
  done
  sleep 3
  for k in "${kl[@]}"; do kill -0 "$k" 2>/dev/null || continue
    if declare -F _mc_kill_tree >/dev/null; then _mc_kill_tree KILL "$k"; else kill -KILL "$k" 2>/dev/null; fi
  done
  return 0
}

_pq_budget_start() {
  local b="$1" f
  _pq_tp=""; _pq_priv=""; _pq_cf="${MC_CALL_FILE:-}"
  if [ -z "$_pq_cf" ]; then
    _pq_priv=$(mktemp "${TMPDIR:-/tmp}/mc-pq-call.XXXXXX" 2>/dev/null) || { _pq_priv=""; return 0; }
    _pq_cf="$_pq_priv"
  fi
  f="$_pq_cf"; rm -f "$f.over" 2>/dev/null
  (
    sleep "$b"
    { IFS=$'\t' read -r _ cp _ < "$f"; printf '%s\n' "${cp:-}" > "$f.over"; } 2>/dev/null
    _pq_call_kill "$f" "$BASHPID"
  ) & _pq_tp=$!
}

_pq_budget_stop() {
  if [ -n "$_pq_tp" ]; then
    if declare -F _mc_kill_tree >/dev/null; then _mc_kill_tree TERM "$_pq_tp"; else kill -TERM "$_pq_tp" 2>/dev/null; fi
    wait "$_pq_tp" 2>/dev/null
  fi
  [ -n "$_pq_cf" ] && rm -f "$_pq_cf.over" 2>/dev/null
  [ -n "$_pq_priv" ] && rm -f "$_pq_priv" 2>/dev/null
  _pq_tp=""; _pq_priv=""; _pq_cf=""
  return 0
}
