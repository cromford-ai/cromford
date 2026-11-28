# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9468-row-cap.sh — BH-9468 (#9369 fix 4): a time
# cap on the READ PHASE of one row of the rung loop.
#
# WHY. Hub, 2026-11-09: one row held a tick for 504 s of reads. The tick's
# wall bound (BR_TICK_MAX_SECS) is asked only BETWEEN rows, so every row
# behind it waited.
#
# THE DESIGN. A fix round holds a row for up to 90 minutes, and RUNGS ARE
# SERIAL AND STAY SERIAL (the driver's tick-budget comment). So the cap never
# detaches a row and never stops a row that has started to act:
#   - the row subshell stays in the foreground; no second row starts;
#   - a watchdog (a background job of the lane) sleeps BR_ROW_MAX_SECS, then
#     stops the row ONLY if the row has not COMMITTED yet;
#   - a row COMMITS at its first call of a rung entry point or a state writer
#     (the COMMIT LIST in _brrc_wrap). br_cron_unlock is first on the list: every rung of
#     the main ladder passes it before its dispatch, and every LLM call, pool
#     build, push and comment runs after it. Before its commit br_one only
#     reads (key, hold gates, merged check, ladder choice).
# The commit marker and the watchdog's `capped` marker are written under one
# flock, so a row can never write after the watchdog decided to stop it.
#
# A STOPPED ROW IS CARRIED: one `row cap: <p>/<rkey> carried` line, no rung
# counted (the driver maps it to rc 3), br_note_untouched, and the loop goes
# on to the next row in the same tick. NO STARVATION: a row carried
# BR_ROW_CARRY_MAX times runs uncapped the next time it is dispatched.
#
# THE LEDGER. $ST/.row-carry[-<project>].tsv, lines `<p>\t<rkey>\t<count>`,
# rewritten whole each tick (tmp + mv). It holds only rows still in CANDS, so
# it never grows past the candidate list (its retention rule).
#
# Not armed: BR_ROW_MAX_SECS=0, a one-PR run (BR_ONLY_PR) and a hopped rung
# (BR_FIX_HERE=1). Each of those was started for one row on purpose.
#
# Call sites in bin/blocked-resolver.sh's rung loop, each one guarded
# `command -v` line:
#   brrc_row_begin <p> <rkey>        before the row subshell
#   brrc_row_pid                     first line inside the row subshell
#   brrc_row_end <p> <rkey> <rc>     after the profile hook; rc 0 = carried
#   brrc_tick_end                    after the loop
# BR_OPT_OFF=bh-9468-row-cap does not source this file: rows run unbounded.

# _brrc_int <name> <value> <fallback> <what> — a non-negative integer, or
#   the fallback with one `say` line (<what> names the fallback in it).
_brrc_int() {
  local n="$1" v="$2" d="$3" w="$4"
  case "$v" in
    ''|*[!0-9]*)
      say "row cap: $n='$v' is not a non-negative integer — $w"
      v="$d" ;;
  esac
  printf '%s' "$((10#$v))"
}

# brrc_knobs — read the three knobs once per run.
brrc_knobs() {
  [ "${_BRRC_KNOBS:-}" = 1 ] && return 0
  _BRRC_KNOBS=1
  # Fallback 120; settings row lane.blocked-resolver.br_row_max_secs. 0 = off.
  BRRC_MAX=$(_brrc_int BR_ROW_MAX_SECS "${BR_ROW_MAX_SECS:-120}" 120 "the cap is 120 s")
  # Fallback 1; settings row lane.blocked-resolver.br_row_carry_max.
  BRRC_CARRY_MAX=$(_brrc_int BR_ROW_CARRY_MAX "${BR_ROW_CARRY_MAX:-1}" 1 "a row runs uncapped after 1 carry")
  # Fallback 10; settings row lane.blocked-resolver.br_row_kill_grace_secs.
  BRRC_GRACE=$(_brrc_int BR_ROW_KILL_GRACE_SECS "${BR_ROW_KILL_GRACE_SECS:-10}" 10 "the grace is 10 s")
  [ "$BRRC_GRACE" -ge 1 ] || BRRC_GRACE=1
  declare -gA BRRC_CARRY=()
  BRRC_FILE="$ST/.row-carry${ONLY:+-$ONLY}.tsv"
  local p k c
  if [ -r "$BRRC_FILE" ]; then
    while IFS=$'\t' read -r p k c; do
      [ -n "$p" ] && [ -n "$k" ] || continue
      case "$c" in ''|*[!0-9]*) continue ;; esac
      BRRC_CARRY["$p"$'\t'"$k"]="$c"
    done < "$BRRC_FILE"
  fi
  return 0
}

# _brrc_wrap — wrap every defined name of the COMMIT LIST below once:
#   f() { brrc_commit f || return 143; _brrc_orig_f "$@"; }
#   It re-checks each name on every call (the _br_prof_wrap idiom): a lib that
#   is sourced again puts the bare function back.
_brrc_wrap() {
  local f body
  # THE COMMIT LIST: the names whose first call commits a row. Rung and
  # adoption entry points first, then every state writer. An undefined name
  # (an opt module that is off) is skipped.
  local list="br_cron_unlock br_fix_adopt br_fix_heal br_opt_external_rung
    br_opt_carry_rung br_opt_conflict_rung br_opt_ci_cap_rung br_opt_stale_rung
    br_data_lane_route br_contested_hold br_needs_human_park br_resolve_ticket_merged
    br_save br_json_edit br_record br_event br_set_outcome br_set_wait br_job_add
    br_tkey_put mc_row_put mc_transition br_opt_unchanged_mark"
  for f in $list; do
    declare -F "$f" >/dev/null 2>&1 || continue
    body=$(declare -f "$f")
    case "$body" in *"brrc_commit $f "*) continue ;; esac
    eval "$(printf '%s\n' "$body" | sed "1s/^$f /_brrc_orig_$f /")"
    eval "$f() { brrc_commit $f || return 143; _brrc_orig_$f \"\$@\"; }"
  done
  return 0
}

# brrc_commit <name> — mark this armed row committed, unless the watchdog
#   already stopped it. rc 1 = stopped: the wrapped body must not run. In the
#   row shell itself the row ends 143 at once; in a nested subshell the TERM
#   the watchdog sends ends it. A no-op outside an armed row.
brrc_commit() {
  [ -n "${BRRC_ROWPID:-}" ] && [ -n "${BRRC_DIR:-}" ] || return 0
  [ "${BRRC_COMMITTED:-}" = 1 ] && return 0
  local rc=0
  {
    flock -x 7 2>/dev/null
    if [ -e "$BRRC_DIR/capped" ]; then rc=1
    else printf '%s\n' "${1:-?}" >> "$BRRC_DIR/committed"; fi
  } 7>>"$BRRC_DIR/lock"
  if [ "$rc" = 1 ]; then
    [ "$BASHPID" = "$BRRC_ROWPID" ] && exit 143
    return 1
  fi
  BRRC_COMMITTED=1
  return 0
}

# brrc_row_begin <p> <rkey> — arm the cap for this row (the lane shell).
brrc_row_begin() {
  local p="${1:-}" k="${2:-}" n lane
  BRRC_DIR=""; BRRC_WPID=""
  brrc_knobs
  [ "$BRRC_MAX" -gt 0 ] || return 0
  [ -z "${br_only_pr_run:-}" ] || return 0
  [ "${BR_FIX_HERE:-0}" != 1 ] || return 0
  n="${BRRC_CARRY["$p"$'\t'"$k"]:-0}"
  if [ "$n" -gt 0 ] && [ "$n" -ge "$BRRC_CARRY_MAX" ]; then
    say "row cap: $p/$k runs uncapped this tick — carried $n time(s) before"
    return 0
  fi
  _brrc_wrap
  if [ -z "${BRRC_RUNDIR:-}" ] || [ ! -d "$BRRC_RUNDIR" ]; then
    BRRC_RUNDIR=$(mktemp -d "${TMPDIR:-/tmp}/br-row-cap.XXXXXX" 2>/dev/null) || {
      say "row cap: no scratch dir — $p/$k runs uncapped"; BRRC_RUNDIR=""; return 0; }
  fi
  BRRC_DIR="$BRRC_RUNDIR/row"
  rm -rf "$BRRC_DIR" 2>/dev/null; mkdir -p "$BRRC_DIR" 2>/dev/null || { BRRC_DIR=""; return 0; }
  # $BASHPID is read HERE: inside the `&` it would name the watchdog itself.
  lane="$BASHPID"
  _brrc_watch "$lane" </dev/null >/dev/null 2>&1 &
  BRRC_WPID=$!
  return 0
}

# brrc_row_pid — the first line inside the row subshell.
brrc_row_pid() {
  [ -n "${BRRC_DIR:-}" ] || return 0
  BRRC_ROWPID="$BASHPID"; BRRC_COMMITTED=""
  printf '%s\n' "$BASHPID" > "$BRRC_DIR/pid"
}

# _brrc_tree <pid> — <pid> and every descendant, one "pid ppid" per line,
#   CHILDREN FIRST: a signal to a parent first would re-parent its children,
#   and the ppid check in _brrc_signal would then pass them over.
_brrc_tree() {
  local q=("$1") c x pp
  while [ "${#q[@]}" -gt 0 ]; do
    x="${q[0]}"; q=("${q[@]:1}")
    pp=$(ps -o ppid= -p "$x" 2>/dev/null | tr -d ' ')
    [ -n "$pp" ] || continue
    printf '%s %s\n' "$x" "$pp"
    for c in $(pgrep -P "$x" 2>/dev/null); do q+=("$c"); done
  done | tac
}

# _brrc_signal <sig> <tree lines> — signal each pid whose parent is still the
#   one it had when the tree was read, so a recycled pid is never signalled.
_brrc_signal() {
  local sig="$1" x pp now
  while read -r x pp; do
    [ -n "$x" ] || continue
    now=$(ps -o ppid= -p "$x" 2>/dev/null | tr -d ' ')
    [ "$now" = "$pp" ] || continue
    kill "-$sig" "$x" 2>/dev/null
  done <<<"$2"
}

# _brrc_watch <lane pid> — the watchdog (a background job of the lane).
_brrc_watch() {
  local lane="$1" sp rp tree t
  trap '[ -n "${sp:-}" ] && kill "$sp" 2>/dev/null; exit 0' TERM
  sleep "$BRRC_MAX" & sp=$!
  wait "$sp"; sp=""
  {
    flock -x 7 2>/dev/null
    [ -e "$BRRC_DIR/committed" ] && exit 0
    rp=$(cat "$BRRC_DIR/pid" 2>/dev/null)
    case "$rp" in ''|*[!0-9]*) exit 0 ;; esac
    [ "$(ps -o ppid= -p "$rp" 2>/dev/null | tr -d ' ')" = "$lane" ] || exit 0
    printf '%s\n' "$BRRC_MAX" > "$BRRC_DIR/capped"
    # Read the whole tree BEFORE a signal: a child whose parent died is
    # re-parented, and pgrep -P no longer finds it.
    tree=$(_brrc_tree "$rp")
    _brrc_signal TERM "$tree"
  } 7>>"$BRRC_DIR/lock"
  t=0
  while [ "$t" -lt "$BRRC_GRACE" ]; do
    sleep 1; t=$((t+1))
    kill -0 "$rp" 2>/dev/null || break
  done
  _brrc_signal KILL "$tree"
  exit 0
}

# brrc_row_end <p> <rkey> <rc> — the lane shell, after the row. rc 0 = the
#   row was stopped and is carried (the caller maps it to rc 3).
brrc_row_end() {
  local p="${1:-}" k="${2:-}" rc="${3:-}" d="${BRRC_DIR:-}" n key
  key="$p"$'\t'"$k"
  # A watchdog that capped this row is in its grace and ends by itself (it
  # KILLs what is left of the row's tree), so it is waited on. Any other one
  # is still asleep and is stopped. The row has been reaped here, so a
  # watchdog that wakes now finds no row of the lane and writes nothing.
  if [ -n "${BRRC_WPID:-}" ]; then
    [ -n "$d" ] && [ -e "$d/capped" ] || kill "$BRRC_WPID" 2>/dev/null
    wait "$BRRC_WPID" 2>/dev/null
  fi
  BRRC_DIR=""; BRRC_WPID=""
  if [ -n "$d" ] && [ -e "$d/capped" ]; then
    n=$(( ${BRRC_CARRY[$key]:-0} + 1 ))
    BRRC_CARRY[$key]="$n"
    say "row cap: $p/$k carried — no rung reached in BR_ROW_MAX_SECS=${BRRC_MAX}s (rc $rc); offered again next tick"
    command -v br_opt_readmemo_drop >/dev/null 2>&1 && br_opt_readmemo_drop "${URL:-}"
    return 0
  fi
  [ "${_BRRC_KNOBS:-}" = 1 ] && unset 'BRRC_CARRY[$key]'
  return 1
}

# brrc_tick_end — write the ledger: the rows carried this tick, plus older
#   entries for rows still in CANDS that this tick did not run to an end. A
#   row gone from CANDS drops out. A one-PR run writes nothing.
brrc_tick_end() {
  [ -n "${BRRC_RUNDIR:-}" ] && rm -rf "$BRRC_RUNDIR" 2>/dev/null
  BRRC_RUNDIR=""
  [ -z "${br_only_pr_run:-}" ] || return 0
  brrc_knobs
  local line xp xk key tmp="$BRRC_FILE.tmp.$$" ok=1
  local -A live=()
  for line in ${CANDS[@]+"${CANDS[@]}"}; do
    IFS=$'\t' read -r _ xp xk _ <<<"$line"
    [ -n "$xk" ] && live["$xp"$'\t'"$xk"]=1
  done
  # No ledger and nothing to write: no file.
  if [ "${#BRRC_CARRY[@]}" -eq 0 ] && [ ! -e "$BRRC_FILE" ]; then return 0; fi
  for key in "${!BRRC_CARRY[@]}"; do
    [ -n "${live[$key]+x}" ] || continue
    printf '%s\t%s\n' "$key" "${BRRC_CARRY[$key]}"
  done 2>/dev/null | LC_ALL=C sort > "$tmp" 2>/dev/null || ok=0
  [ "$ok" = 1 ] && mv -f "$tmp" "$BRRC_FILE" 2>/dev/null || ok=0
  if [ "$ok" = 0 ]; then
    rm -f "$tmp" 2>/dev/null
    say "row cap: the carry ledger could not be written to $BRRC_FILE — the next tick reads the previous one"
  fi
  return 0
}
