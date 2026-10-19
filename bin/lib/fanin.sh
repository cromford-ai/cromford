#!/bin/bash
# bin/lib/fanin.sh — the fan-in assertion (BH-186): every PR a lane enumerates
# leaves through exactly one accounted outcome, and a run where
# enumerated != accounted says so.
#
# Sourced by bin/merge-conductor.sh and bin/reconcile-prs.sh, the two lanes that
# start PR work (the operator, 2026-09-24; merge-sweep no longer runs on cron and is not
# wired). Never executed.
#
# THE LEDGER. One scratch file per run, $HARNESS/state/fanin/<lane>/<scope>.<pid>:
#   E <id>             one line per enumerated PR
#   A <id> <outcome>   one line per accounted PR
#   X <id> signal=<SIG> after=<N>s   a worker wrapper TERMed/INTed/HUPed
#                      before its body returned (BH-4842): no A line, so the id
#                      stays missing, and the alert says why
#   T signal=<SIG> after=<N>s        the run's own shell signalled, written by
#                      the traps fanin_trap_run installs (caller opt-in)
# Appends take a flock on the file itself, because the conductor's per-PR
# workers write in parallel.
#
# THE STAGE (BH-4842). fanin_run_sub points FANIN_STAGE_FILE (a plain shell
# var, NOT exported) at <ledger dir>/.stage/<ledger name>/<id>, and mc_log
# overwrites it with every line the worker logs. A missing id's alert carries
# the last one, flattened and cut to FANIN_STAGE_MAX chars (160, a text-shape
# constant). fanin_end and the orphan reap delete the run's .stage dir.
#
# THE STREAK (BH-4842). <ledger dir>/.streak, TSV `id<TAB>count<TAB>epoch`,
# rewritten under a flock on .streak.lock by every report: a missing id +1, an
# id whose worker FINISHED removed, every other id untouched (deferred:solo,
# deferred:window, killed:deadline from mc_worker_bounded, a ` signal=` death
# and a lock-skip (skipped:locked, READY held:worker-locked) all keep it: a
# solo run killed at its deadline, or still holding the PR's lock while a
# batch fire skips it, must not send the PR back to batches), a row older than
# 7 days dropped. fanin_streak <id> reads it. A run killed
# between its alert and its rm is reported twice by design (below), and so
# counts twice: the PR is isolated one run sooner, no worse.
#
# ACCOUNTED BY CONSTRUCTION. The per-PR body only ever runs inside fanin_run
# (same shell) or fanin_run_sub (a subshell), and the wrapper writes the A line
# after the body returns, whichever return it took. What escapes the wrapper — a
# body that `exit`s the lane, a worker that is SIGKILLed — writes no A line, and
# that is what the check catches:
#   - the run reaches fanin_end: the id is named `missing:`;
#   - the run itself died: the next fanin_begin of the same lane+scope finds the
#     ledger (its pid is dead, and a zombie counts as dead), alerts with "(run died before fan-in)" and
#     deletes it. A dead ledger that is fully accounted is deleted silently.
#
# OUTPUT. fanin_end writes ONE line to the lane's own log on a non-empty run:
#   <ts> FANIN <lane> <scope>: enumerated N accounted M (<outcome> <n>, ...)
# and on a mismatch one alert through bin/lane-alert.sh --severity warn:
#   ALERT FANIN <lane> <scope>: enumerated N accounted M missing: <id>... [double: <id>...]
# The orphan path appends " (run died before fan-in)", then " run: signal=<SIG>
# after=<N>s" when the dead run left a T line. Either path then appends
# " why: <id> [signal=<SIG> after=<N>s] [stage: \"<line>\"]; ..." for each
# missing id that has a stamp or a stage; with neither, the text is unchanged.
# An empty run writes nothing; a healthy run sends no alert.
#
# FAIL-OPEN. Every function returns 0 and never fails its caller. With no ledger
# (fanin_begin not called, or the state dir unwritable) every function is a
# silent no-op, and the two run wrappers still run the body. The FANIN_* globals
# are deliberately NOT exported: a detached child that sources this lib must not
# append to its parent's ledger.

# BH-6462: the per-worker call trace (mc_worker_bounded, mc_fanin_outcome). A
# box missing the file traces nothing, and a kill reads `calls: none`.
# shellcheck source=bin/lib/call-trace.sh
[ -r "${BASH_SOURCE[0]%/*}/call-trace.sh" ] && . "${BASH_SOURCE[0]%/*}/call-trace.sh" 2>/dev/null

_fanin_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

_fanin_append() { # _fanin_append <file> <line>
  { flock 8 2>/dev/null; printf '%s\n' "$2" >&8; } 2>/dev/null 8>>"$1"
  return 0
}

# _fanin_pid_live <pid> — rc 0 when the pid is a running (or stopped) process.
# `kill -0` alone says yes to a zombie, and a SIGKILLed tick's ledger pid is an
# orphan zombie until PID 1 reaps it (BH-2247), so a zombie (stat state Z or X)
# is dead, and so is a pid that vanishes between the two checks. With no /proc
# (FANIN_PROC is a test seam for its root) the kill -0 answer stands.
_fanin_pid_live() {
  local proc="${FANIN_PROC:-/proc}" s
  kill -0 "$1" 2>/dev/null || return 1
  [ -d "$proc/self" ] || return 0
  s=$(cat "$proc/$1/stat" 2>/dev/null) || return 1
  s=${s##*) }
  case "${s%% *}" in Z|X) return 1 ;; esac
  return 0
}

# _fanin_stage_dir <ledger> — where the run's per-id stage files live. Dot-led,
# so fanin_begin's "<scope>.*" ledger glob never matches it.
_fanin_stage_dir() { printf '%s/.stage/%s' "${1%/*}" "${1##*/}"; }
_fanin_safe_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

# _fanin_why <ledger> <missing ids> <xs> — "<id> [signal=… after=…s] [stage:
# \"…\"]; …" for each missing id with a stamp (xs: RS-separated id GS stamp)
# or a stage file; empty when no id has either.
_fanin_why() {
  local file="$1" sd id st stamp part out="" max="${FANIN_STAGE_MAX:-160}" seen=" " r
  case "$max" in ''|*[!0-9]*) max=160 ;; esac
  sd=$(_fanin_stage_dir "$file")
  for id in $2; do
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    stamp=""
    while IFS=$'\035' read -r -d $'\036' r st; do [ "$r" = "$id" ] && stamp="$st"; done <<<"${3:+$3$'\036'}"
    st=""
    [ -f "$sd/$(_fanin_safe_id "$id")" ] && st=$(tr '\t\n"' "  '" < "$sd/$(_fanin_safe_id "$id")" 2>/dev/null)
    st="${st% }"; st="${st:0:$max}"
    [ -n "$stamp" ] || [ -n "$st" ] || continue
    part="$id${stamp:+ $stamp}${st:+ stage: \"$st\"}"
    out="${out:+$out; }$part"
  done
  printf '%s' "$out"
}

# _fanin_streak_update <ledger> <missing ids> — the streak file (header). Never
# creates the file for a run with nothing missing, nor with no root (BH-2613:
# no root writes nothing, and fanin_streak reads it only under one); fail-open
# on every error.
_fanin_streak_update() {
  local file="$1" sf now tmp
  [ -n "${HARNESS:-${H:-}}" ] || return 0
  sf="${file%/*}/.streak"; tmp="$sf.tmp.$BASHPID"
  [ -n "$2" ] || [ -s "$sf" ] || return 0
  now=$(date +%s)
  ( flock -w 5 7 2>/dev/null || exit 0
    [ -f "$sf" ] || : > "$sf" 2>/dev/null || exit 0
    awk -v now="$now" -v miss="$2" '
      BEGIN { n = split(miss, mm, " "); for (i = 1; i <= n; i++) bump[mm[i]] = 1 }
      FNR == NR { if ($1 == "A") { id = $2; o = $0; sub(/^A [^ ]+ ?/, "", o); if (o !~ /^(deferred|killed):/ && o !~ /^skipped:locked/ && o !~ /held:worker-locked/ && o !~ / signal=/) clear[id] = 1 }
                  next }
      { split($0, f, "\t"); id = f[1]
        if (id == "" || f[3] !~ /^[0-9]+$/ || f[3] + 604800 < now) next
        if (id in bump) { print id "\t" (f[2] + 1) "\t" now; done[id] = 1 }
        else if (!(id in clear)) print $0 }
      END { for (id in bump) if (!(id in done)) print id "\t1\t" now }' "$file" "$sf" > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$sf" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    exit 0
  ) 7>>"$sf.lock" 2>/dev/null
  return 0
}

# fanin_streak <id> — how many reports in a row named <id> missing in the lane
# of the current fanin_begin; 0 when absent, unreadable or no ledger root.
fanin_streak() {
  local h="${HARNESS:-${H:-}}" n
  [ -n "$h" ] && [ -n "${FANIN_LANE:-}" ] || { echo 0; return 0; }
  n=$(awk -F'\t' -v id="$1" '$1 == id { v = $2 } END { print v + 0 }' "$h/state/fanin/$FANIN_LANE/.streak" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo "$n"
  return 0
}

# _fanin_report <ledger> <lane> <scope> <log> [note] — the tally, the summary
# line and the alert. With a note (the orphan path) only a mismatch is reported.
_fanin_report() {
  local file="$1" lane="$2" scope="$3" log="$4" note="${5:-}" res en ac missing double tally run xs why label text h
  [ -f "$file" ] || return 0
  res=$(awk '
    $1 == "E" { e[$2]++; en++; if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2 } next }
    $1 == "A" { a[$2]++; ac++; id = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); o = ($0 == "" ? "unlabelled" : $0)
                if (!(o in t)) oo[++m] = o; t[o]++
                if (!(id in seen)) { seen[id] = 1; order[++n] = id } next }
    $1 == "X" { id = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); x[id] = $0; next }
    $1 == "T" { $1 = ""; sub(/^ +/, ""); run = $0; next }
    END {
      mi = ""; db = ""; ta = ""; xs = ""
      for (i = 1; i <= n; i++) { id = order[i]
        for (k = a[id] + 0; k < e[id] + 0; k++) mi = mi " " id
        if (a[id] + 0 > e[id] + 0) db = db " " id
        if (a[id] + 0 < e[id] + 0 && (id in x)) xs = xs "\036" id "\035" x[id] }
      for (i = 1; i <= m; i++) ta = ta (i > 1 ? ", " : "") oo[i] " " t[oo[i]]
      printf "%d\037%d\037%s\037%s\037%s\037%s\037%s\n", en, ac, substr(mi, 2), substr(db, 2), ta, run, substr(xs, 2)
    }' "$file" 2>/dev/null) || return 0
  IFS=$'\037' read -r en ac missing double tally run xs <<<"$res"
  [ "${en:-0}" -gt 0 ] || [ "${ac:-0}" -gt 0 ] || return 0
  label="$lane${scope:+ $scope}"
  if [ -z "$note" ]; then
    printf '%s FANIN %s: enumerated %s accounted %s (%s)\n' "$(_fanin_stamp)" "$label" "$en" "$ac" "$tally" >> "$log" 2>/dev/null
  fi
  _fanin_streak_update "$file" "$missing"
  [ -n "$missing" ] || [ -n "$double" ] || return 0
  text="ALERT FANIN $label: enumerated $en accounted $ac"
  [ -n "$missing" ] && text="$text missing: $missing"
  [ -n "$double" ] && text="$text double: $double"
  [ -n "$note" ] && text="$text $note"
  [ -n "$run" ] && text="$text run: $run"
  why=$(_fanin_why "$file" "$missing" "$xs")
  [ -n "$why" ] && text="$text why: $why"
  [ -n "$note" ] && printf '%s %s\n' "$(_fanin_stamp)" "$text" >> "$log" 2>/dev/null
  # The alert goes through the root's lane-alert.sh or ALERTS.log; with no root
  # there is neither, and only the caller's $log line above is written.
  h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  if [ -x "$h/bin/lane-alert.sh" ]; then
    "$h/bin/lane-alert.sh" --severity warn "$lane" "$text" >/dev/null 2>&1 || true
  else
    printf '%s %s\n' "$(_fanin_stamp)" "$text" >> "$h/logs/ALERTS.log" 2>/dev/null
  fi
  return 0
}

# fanin_begin <lane> <scope> <logfile> — open this run's ledger. First reports
# and deletes the ledgers of dead runs of the same lane+scope. A ledger whose
# pid is alive is a parallel run and is left alone — unless the pid is this
# shell's own, which can only be a dead run's pid reused. A zombie pid is a
# dead run (_fanin_pid_live).
fanin_begin() {
  local lane="$1" scope="${2:-}" log="$3" dir safe f pid
  unset FANIN_FILE
  FANIN_LANE="$lane"; FANIN_SCOPE="$scope"; FANIN_LOG="$log"
  # No root = no ledger: FANIN_FILE stays unset, as when the mkdir fails.
  [ -n "${HARNESS:-${H:-}}" ] || return 0
  dir="${HARNESS:-${H:-}}/state/fanin/$lane"
  safe=$(printf '%s' "${scope:-run}" | tr -c 'A-Za-z0-9._-' '_')
  mkdir -p "$dir" 2>/dev/null || return 0
  for f in "$dir/$safe".*; do
    [ -f "$f" ] || continue
    pid="${f##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" != "$BASHPID" ] && _fanin_pid_live "$pid" && continue
    _fanin_report "$f" "$lane" "$scope" "$log" "(run died before fan-in)"
    rm -rf "$(_fanin_stage_dir "$f")" 2>/dev/null
    rm -f "$f" 2>/dev/null
  done
  f="$dir/$safe.$BASHPID"
  : > "$f" 2>/dev/null || return 0
  FANIN_FILE="$f"
  return 0
}

fanin_enumerate() { # fanin_enumerate <id>
  [ -n "${FANIN_FILE:-}" ] || return 0
  _fanin_append "$FANIN_FILE" "E $1"
}

fanin_account() { # fanin_account <id> <outcome...>
  [ -n "${FANIN_FILE:-}" ] || return 0
  local id="$1"; shift
  _fanin_append "$FANIN_FILE" "A $id ${*:-unlabelled}"
}

# fanin_run <id> <outcome-var> <fn> [args...] — run fn in THIS shell (it may set
# the lane's globals), then account the outcome fn left in <outcome-var>, or
# `unlabelled`, plus ` rc=N` on a non-zero return. The body must hold no
# `continue`/`break`/`exit`: bash lets a `continue` in a function act on the
# caller's loop, which would skip the accounting — and the check would say so.
fanin_run() {
  local id="$1" var="$2" fn="$3" rc out
  shift 3
  printf -v "$var" '%s' ""
  "$fn" "$@"; rc=$?
  out="${!var:-unlabelled}"
  [ "$rc" = 0 ] || out="$out rc=$rc"
  fanin_account "$id" "$out"
  return 0
}

# fanin_run_sub <id> <outcome-fn> <fn> [args...] — run fn in a subshell, so even
# an `exit` inside it comes back here, then account `<outcome-fn> <rc> args...`
# (its stdout) plus ` rc=N` on a non-zero status, and ` signal=<SIG>` when that
# status is a signal death (rc >= 129) the wrapper itself survived, unless the
# outcome already starts `killed:`.
#
# SIGNALLED (BH-4842). The body runs as a background child the wrapper waits on,
# so a TERM/INT/HUP to the wrapper interrupts the wait at once: _fanin_sub_signal
# TERMs the body, writes `X <id> signal=<SIG> after=<N>s` and exits
# 128+n with no A line — the id stays missing and the alert says why. The traps
# the caller had are put back afterwards, so a foreground call leaks none, and
# a `&` wrapper gets none of its parent's (bash would show them to `trap -p`).
# FANIN_STAGE_FILE is set for the body only (header: THE STAGE).
fanin_run_sub() {
  local id="$1" ofn="$2" fn="$3" rc out saved sd
  shift 3
  local _FANIN_SUB_ID="$id" _FANIN_SUB_T0="$SECONDS" _FANIN_SUB_PID="" FANIN_STAGE_FILE=""
  if [ -n "${FANIN_FILE:-}" ]; then
    sd=$(_fanin_stage_dir "$FANIN_FILE")
    mkdir -p "$sd" 2>/dev/null && FANIN_STAGE_FILE="$sd/$(_fanin_safe_id "$id")"
  fi
  # In a subshell, bash shows the PARENT's traps until the subshell's first
  # `trap` call, and none of them is installed here. The no-op RETURN reset
  # clears that view, so `saved` holds only the traps this shell really has
  # and a `&` wrapper does not install its parent's _fanin_run_signal.
  trap - RETURN
  saved=$(trap -p TERM INT HUP)
  trap '_fanin_sub_signal TERM 143' TERM
  trap '_fanin_sub_signal INT 130' INT
  trap '_fanin_sub_signal HUP 129' HUP
  ( "$fn" "$@" ) <&0 &
  _FANIN_SUB_PID=$!
  wait "$_FANIN_SUB_PID"; rc=$?
  trap - TERM INT HUP
  eval "$saved"
  [ -n "${FANIN_FILE:-}" ] || return 0
  out=$("$ofn" "$rc" "$@" 2>/dev/null)
  [ -n "$out" ] || out=unlabelled
  [ "$rc" = 0 ] || out="$out rc=$rc"
  # An outcome that already names the kill (mc_fanin_outcome's killed:deadline,
  # BH-4918) says why on its own; the signal name is for every other death.
  case "$out" in killed:*) ;; *)
    [ "$rc" -ge 129 ] && [ "$rc" -le 192 ] && out="$out signal=$(kill -l $((rc - 128)) 2>/dev/null || echo $((rc - 128)))" ;;
  esac
  fanin_account "$id" "$out"
  return 0
}

# _fanin_sub_signal <SIG> <rc> — fanin_run_sub's trap (above). The body is
# always sent TERM: bash ignores INT in an async child of a non-interactive
# shell, so forwarding INT itself would leave the body running.
_fanin_sub_signal() {
  [ -n "${_FANIN_SUB_PID:-}" ] && kill -TERM "$_FANIN_SUB_PID" 2>/dev/null
  [ -n "${FANIN_FILE:-}" ] && _fanin_append "$FANIN_FILE" "X ${_FANIN_SUB_ID:-?} signal=$1 after=$((SECONDS - ${_FANIN_SUB_T0:-$SECONDS}))s"
  exit "$2"
}

# fanin_trap_run — caller opt-in, right after fanin_begin: a TERM/INT/HUP to the
# run's own shell writes `T signal=<SIG> after=<N>s` into the ledger and exits
# 128+n, so the next fanin_begin's "(run died before fan-in)" alert says how.
# The caller's EXIT trap still fires on that exit.
fanin_trap_run() {
  _FANIN_RUN_T0=$SECONDS
  trap '_fanin_run_signal TERM 143' TERM
  trap '_fanin_run_signal INT 130' INT
  trap '_fanin_run_signal HUP 129' HUP
  return 0
}
_fanin_run_signal() {
  [ -n "${FANIN_FILE:-}" ] && _fanin_append "$FANIN_FILE" "T signal=$1 after=$((SECONDS - ${_FANIN_RUN_T0:-$SECONDS}))s"
  exit "$2"
}

# fanin_end — tally, summary line, alert on a mismatch, delete the ledger. The
# alert goes out BEFORE the delete, so a run killed between the two re-reports
# on the next begin: a duplicate at worst, never a lost alert.
fanin_end() {
  [ -n "${FANIN_FILE:-}" ] || return 0
  _fanin_report "$FANIN_FILE" "$FANIN_LANE" "$FANIN_SCOPE" "$FANIN_LOG"
  rm -rf "$(_fanin_stage_dir "$FANIN_FILE")" 2>/dev/null
  rm -f "$FANIN_FILE" 2>/dev/null
  unset FANIN_FILE
  return 0
}

# ---- the merge conductor's outcome (bin/merge-conductor.sh tick_project) -----
# mc_fanin_outcome <rc> <row> — what one pr_worker left behind. The draft and
# UNVERIFIABLE early returns are read off the row itself; every other exit is
# the PR's pr-state.tsv state after the worker (mc_row_field, loaded by the
# driver), or skipped:no-row when it has none. Lives here, not in an mc module,
# so tests/mc/expected-map.d/ needs no row for it.
#
# LOCKED (BH-4842). A worker that found the PR's lock held by an earlier worker
# (a solo run still working it) did no work on the PR: pr_worker leaves
# <FANIN_STAGE_FILE>.locked, and this says `skipped:locked` instead of the
# row's state, or `READY held:worker-locked` for a READY row (the note the
# lock-skip writes, BH-4918). Both keep the streak; the row's state cleared it.
#
# TWO MORE WORDS (BH-4918). A worker mc_worker_bounded killed at its deadline is
# `killed:deadline`, never the state its row happened to be left in. A row the
# worker left READY is `READY held:<kind>` when the READY arm wrote a ready-why
# note for this head during this tick (MC_FANIN_T0, set by tick_project), and
# `READY unexplained` otherwise: no enqueue (that would have made it QUEUED) and
# no recorded hold. Both of those new outcomes write one log line and one warn
# alert per (PR, head), through the attempts ledger.
#
# THE STEP (BH-6346). The deadline mark is `<d>\t<stage>\t<step>\t<step_s>\t
# <earlier>` (THE STEP TRAIL, at mc_step), so the WORKER_DEADLINE line and alert
# end `| step: <step> (<n>s) | earlier: <name>=<n>s ...`, and the Sentry event
# carries a `step` tag. A worker mc_step stopped after a GitHub 401
# left <FANIN_STAGE_FILE>.auth and is `skipped:auth`, which clears the streak: a
# solo run does not cure a bad token.
#
# THE STEP TIMEOUT (BH-6351). The mark's 6th field is the kind of kill
# (`deadline`, or `step-timeout` when one step ran past MC_STEP_TIMEOUT_S) and
# its 7th the step timeout that fired. A step timeout is `killed:step-timeout`:
# one STEP_TIMEOUT line, one warn alert and one Sentry event per (PR, head,
# step), and the row is left as it is for the next tick. The deadline's Sentry
# title names the step and copies no log line (the stage stays in extra). A
# mark from an older writer (2 fields) is kind `deadline`, step `unknown`.
#
# THE HOLD (BH-6670). A step timeout in a read-only step (_mc_step_holdable:
# lane-epoch, head-lag, park-holds) is held, not paged, for the first
# MC_STEP_HOLD_MAX (default 2, 0 = off, not a number = 2) kills per (PR, head,
# step): one `stephold <key> <head> <step>` attempts line, one
# `<key> STEP_HELD step=<s> after <n>s on <head8> (step timeout <t>s, hold <i>
# of <max>): ...` log line, no alert, no Sentry, outcome `killed:slow-read`.
# The worker is still killed and the row is left as it is. The next kill past
# the cap pages STEP_TIMEOUT as above. The STEP_TIMEOUT event's tags add pr
# (the number) and worker_key (<SLUG>#<n>), each sent only when it has a value.
#
# THE TAGS (BH-6347). The Sentry title is `WORKER_DEADLINE: worker killed after
# <d>s on <head8> in step <step>`: the step, never the log-derived stage, which
# is the step when the worker logged nothing (BH-6462; a mark written before
# that still reads `unknown`), and stays in extra.stage. The
# tags add pr (the number), worker_key (<SLUG>#<n>) and deadline_secs (the
# seconds the killer slept), each sent only when it has a value, deadline_secs
# only when it is an integer. Extra adds started_at (the mark's mtime minus d,
# ISO UTC, empty when either is unreadable), deadline_cfg_s and deadline_cap_s
# (the settings this process read), so a capped deadline reads as capped.
#
# THE CALLS (BH-6462). A killed worker leaves <mark>.calls, its call trace
# (bin/lib/call-trace.sh). The WORKER_DEADLINE and STEP_TIMEOUT lines and
# alerts end ` | calls: <call_trace_summary>`, and both Sentry extras carry it
# as `calls` (not the title). It prints only measured counts and seconds; `none` when the
# worker traced no call or left no file. The file goes with the mark.
#
# THE CALL IN FLIGHT (BH-7029). The mark's 8th and 9th fields are the prequeue
# call that ran at the kill (pq_call, bin/lib/mc-prequeue.d/call-bound.sh) and
# its seconds. A mark with no call in flight keeps 7 fields and reads as call
# `none`. With a call, the STEP_TIMEOUT line and alert carry
# ` | call: <path> (<n>s)` before ` | calls:`, and the tags add `call`; with
# none, the line is as before. The Sentry extra always has call and call_s.
# <mark>.call goes with the mark.
mc_fanin_outcome() {
  local num head draft mstate st key mark d stage step step_s earlier mkind sto f ts nh kind text ds mt sa calls hmax hn call call_s cseg lk
  IFS=$'\t' read -r num _ head _ draft mstate _ <<<"${2:-}"
  if [ "$draft" = true ]; then echo skipped:draft; return 0; fi
  if [ "$mstate" = UNVERIFIABLE ]; then echo skipped:unverifiable; return 0; fi
  key="${SLUG:-}#$num"
  mark=$(_mc_deadline_mark "$key")
  if [ -n "$mark" ] && [ -f "$mark" ]; then
    IFS=$'\t' read -r d stage step step_s earlier mkind sto call call_s < "$mark" 2>/dev/null
    call=${call:-none}; [ "$call" = none ] && call_s=""
    # The killer writes the mark just before the TERM, so mtime - d is the start.
    ds=""; sa=""; [[ "${d:-}" =~ ^[0-9]+$ ]] && ds=$d
    mt=$(stat -c %Y "$mark" 2>/dev/null)
    [ -n "$ds" ] && [[ "$mt" =~ ^[0-9]+$ ]] && sa=$(date -u -d "@$((mt - ds))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
    calls=none
    command -v call_trace_summary >/dev/null 2>&1 && calls=$(call_trace_summary "$mark.calls")
    rm -f "$mark" "$mark.calls" "$mark.call" 2>/dev/null
    [ -n "${FANIN_STAGE_FILE:-}" ] && rm -f "$FANIN_STAGE_FILE.auth" 2>/dev/null
    step=${step:-unknown}
    if [ "$mkind" = step-timeout ]; then
      hmax=${MC_STEP_HOLD_MAX:-2}; [[ "$hmax" =~ ^[0-9]+$ ]] || hmax=2
      if [ "$hmax" -gt 0 ] && _mc_step_holdable "$step"; then
        hn=$(mc_attempt_count stephold "$key" "$head $step" 2>/dev/null)
        [[ "$hn" =~ ^[0-9]+$ ]] || hn=0
        if [ "$hn" -lt "$hmax" ]; then
          mc_attempt_put_n stephold "$key" "$head" "$step" 2>/dev/null
          st=$(mc_row_field "$key" 2 2>/dev/null)
          mc_log "$key STEP_HELD step=$step after ${step_s:-?}s on ${head:0:8} (step timeout ${sto:-?}s, hold $((hn + 1)) of $hmax): a read-only step ran slow; worker stopped, row left ${st:-no row}, the next tick works it again | calls: ${calls:-none}" 2>/dev/null
          echo killed:slow-read; return 0
        fi
      fi
      if ! mc_attempt_has "steptimeout $key $head $step" 2>/dev/null; then
        mc_attempt_put "steptimeout $key $head $step" 2>/dev/null
        st=$(mc_row_field "$key" 2 2>/dev/null)
        cseg=""; [ "$call" = none ] || cseg=" | call: $call (${call_s:-?}s)"
        text="step=$step after ${step_s:-?}s on ${head:0:8} (step timeout ${sto:-?}s, worker deadline ${d:-?}s): worker stopped; row left ${st:-no row}, the next tick works it again$cseg | calls: ${calls:-none}"
        mc_log "$key STEP_TIMEOUT $text" 2>/dev/null
        _mc_fanin_alert "STEP_TIMEOUT $key: $text"
        command -v sentry_report >/dev/null 2>&1 && sentry_report warning merge-conductor conductor-step-timeout \
          "STEP_TIMEOUT: step $step passed ${sto:-?}s on ${head:0:8}" \
          "$(jq -nc --arg p "${P:-}" --arg k "$key" --arg h "$head" --arg st "$step" --arg t "${sto:-}" --arg s "${stage:-unknown}" \
               --arg c "${calls:-none}" --arg cl "$call" --arg cs "${call_s:-}" \
               '{project:$p,pr:$k,head:$h,step:$st,step_timeout_s:$t,stage:$s,calls:$c,call:$cl,call_s:$cs,tags:{step:$st}}' 2>/dev/null)" \
          "$(jq -nc --arg s "$step" --arg n "$num" --arg k "$key" --arg c "${call#none}" \
               '{step:$s,pr:$n,worker_key:$k,call:$c} | with_entries(select(.value != ""))' 2>/dev/null)" >/dev/null 2>&1
      fi
      echo killed:step-timeout; return 0
    fi
    if ! mc_attempt_has "workerdeadline $key $head" 2>/dev/null; then
      mc_attempt_put "workerdeadline $key $head" 2>/dev/null
      text="worker killed after ${d:-?}s on ${head:0:8} at stage: ${stage:-unknown} | step: $step (${step_s:-?}s) | earlier: ${earlier:-none} | calls: ${calls:-none}"
      mc_log "$key WORKER_DEADLINE: $text" 2>/dev/null
      _mc_fanin_alert "WORKER_DEADLINE $key: $text"
      # BH-5617. fanin_run_sub reads this function's stdout as the outcome
      # word, so the reporter's output is discarded here as well.
      # A kill in step lock-probe names the PR lock path (BH-7322).
      lk=""; [ "$step" = lock-probe ] && [ -n "${P:-}" ] && declare -F mc_pr_lock >/dev/null && lk=$(mc_pr_lock "$P" "$num")
      command -v sentry_report >/dev/null 2>&1 && sentry_report warning merge-conductor conductor-worker-deadline \
        "WORKER_DEADLINE: worker killed after ${ds:-?}s on ${head:0:8} in step $step${lk:+ (lock $lk)}" \
        "$(jq -nc --arg p "${P:-}" --arg k "$key" --arg h "$head" --arg s "${stage:-unknown}" --arg d "${d:-}" \
             --arg st "$step" --arg ss "${step_s:-}" --arg e "${earlier:-}" --arg sa "${sa:-}" \
             --arg dc "${MC_WORKER_DEADLINE_S:-180}" --arg cap "${MC_WORKER_DEADLINE_CAP_S:-}" --arg c "${calls:-none}" --arg lk "$lk" \
             '{project:$p,pr:$k,head:$h,stage:$s,deadline_s:$d,step:$st,step_s:$ss,earlier:$e,
               started_at:$sa,deadline_cfg_s:$dc,deadline_cap_s:$cap,calls:$c,lock:$lk}' 2>/dev/null)" \
        "$(jq -nc --arg s "$step" --arg n "$num" --arg k "$key" --arg d "$ds" \
             '{step:$s,pr:$n,worker_key:$k,deadline_secs:$d} | with_entries(select(.value != ""))' 2>/dev/null)" >/dev/null 2>&1
    fi
    echo killed:deadline; return 0
  fi
  if [ -n "${FANIN_STAGE_FILE:-}" ] && [ -f "$FANIN_STAGE_FILE.auth" ]; then
    rm -f "$FANIN_STAGE_FILE.auth" 2>/dev/null
    echo skipped:auth; return 0
  fi
  st=$(mc_row_field "$key" 2 2>/dev/null)
  if [ -n "${FANIN_STAGE_FILE:-}" ] && [ -f "$FANIN_STAGE_FILE.locked" ]; then
    rm -f "$FANIN_STAGE_FILE.locked" 2>/dev/null
    [ "$st" = READY ] || { echo skipped:locked; return 0; }
  fi
  if [ "$st" = READY ]; then
    f="${MC_STATE_DIR:-}/ready-why/$(mc_handoff_id "$key" 2>/dev/null)"
    ts=""; nh=""; kind=""
    [ -n "${MC_STATE_DIR:-}" ] && [ -r "$f" ] && IFS=$'\t' read -r ts nh kind _ < "$f" 2>/dev/null
    if [ -n "$kind" ] && [ "$nh" = "$head" ] && [[ "$ts" =~ ^[0-9]+$ ]] && [ "$ts" -ge "${MC_FANIN_T0:-0}" ]; then
      echo "READY held:$kind"; return 0
    fi
    if ! mc_attempt_has "readyunexplained $key $head" 2>/dev/null; then
      mc_attempt_put "readyunexplained $key $head" 2>/dev/null
      text="the worker left the row READY with no enqueue and no recorded hold this tick"
      mc_log "$key READY_UNEXPLAINED on ${head:0:8}: $text" 2>/dev/null
      _mc_fanin_alert "READY_UNEXPLAINED $key on ${head:0:8}: $text"
    fi
    echo "READY unexplained"; return 0
  fi
  echo "${st:-skipped:no-row}"
}

# _mc_step_holdable <step> — rc 0 for a read-only pr_worker step, where a step
# timeout is held (THE HOLD, at mc_fanin_outcome). head-lag-kick (close/reopen)
# and handoff-sticky (approval rebind, label remove) can be mid-write at a kill,
# so they are not here.
_mc_step_holdable() {
  case "${1:-}" in lane-epoch|head-lag|park-holds) return 0 ;; esac
  return 1
}

# mc_fanin_solo <slug> <num> <n> — BH-4842: hand a PR that has been missing from
# fan-in on <n> runs in a row to its own keyed conductor run (kw_conductor:
# detached, every lock fd closed, deduped per PR by MC_KEYED_WAKE_MIN_S). rc 0
# launched: the caller accounts it deferred:solo and drops it from its batch.
# rc 1 refused (keyed wake off, stamped too recently, no lib): the caller keeps
# the row, so a PR is never dropped without a run that will work it. The run it
# launches carries MC_FANIN_SOLO_RUN=1 (kw_conductor, KW_FANIN_SOLO), which is
# what keeps that run from soloing again.
mc_fanin_solo() {
  local slug="$1" num="$2" n="$3" h="${MC_H:-${HARNESS:-${H:-}}}"
  command -v kw_conductor >/dev/null 2>&1 || { [ -n "$h" ] && . "$h/bin/lib/keyed-wake.sh" 2>/dev/null; }
  if command -v kw_conductor >/dev/null 2>&1 \
     && KW_FANIN_SOLO=1 kw_conductor "$slug" "$num" "missing from fan-in on $n runs in a row — worked alone"; then
    mc_log "$slug#$num FANIN_SOLO: missing from fan-in on $n runs in a row — launched alone (keyed run)"
    return 0
  fi
  mc_log "$slug#$num FANIN_SOLO: missing from fan-in on $n runs in a row — solo launch refused (keyed wake off or launched <${MC_KEYED_WAKE_MIN_S:-120}s ago); kept in this run"
  return 1
}

# mc_fanin_mark_locked — pr_worker's lock-skip calls this (LOCKED, above):
# <FANIN_STAGE_FILE>.locked, read and removed by mc_fanin_outcome. Outside a
# fanin_run_sub body it does nothing. Always rc 0.
mc_fanin_mark_locked() {
  [ -n "${FANIN_STAGE_FILE:-}" ] && : > "$FANIN_STAGE_FILE.locked" 2>/dev/null
  return 0
}

# mc_step <name> — THE STEP TRAIL (BH-6346). pr_worker calls this at each step
# boundary. It appends `<epoch>\t<name>` to MC_STEP_FILE (<mark>.steps, set by
# mc_worker_bounded; unset = no write). A deadline kill reads the trail
# (_mc_steps_summary), so the kill names the step even when the worker logged
# nothing. It also sets MC_STEP_NAME in the worker shell, the step each call
# trace line names (BH-6462, bin/lib/call-trace.sh).
#
# THE 401 STOP. GH_REST_AUTH_FAIL_FILE (<mark>.auth) exists once a GitHub call of
# this worker answered HTTP 401 (bin/lib/gh-rest-auth.sh, and the gh() wrapper of
# bin/lib/gh-limit-logger.sh). Every later gh_rest of the worker is refused with
# no request, and the next boundary writes ONE AUTH_401 line, leaves
# <FANIN_STAGE_FILE>.auth for mc_fanin_outcome and EXITS the worker subshell. Each
# boundary sits where no budget unit is held and no write is half done. Always
# rc 0 when it returns.
#
# THE STEP LINES (BH-6351). Each trail line is `<epoch>\t<name>\t<log flag>`;
# the flag is MC_STEP_LOG (pr_worker sets it to 1 after a READY transition).
# mc_step ends the open step first: `<key> STEP_END step=<prev> took=<n>s` when
# its flag is 1, or when it took MC_STEP_SLOW_S or more (default 60, 0 = off),
# then with ` started=<HH:MM:SSZ>`. With the flag 1 it logs `<key> STEP_START
# step=<name>`. A name outside ^[A-Za-z][A-Za-z0-9:_-]{0,39}$ is written as
# `unknown`. No MC_STEP_FILE: nothing is written or logged.
mc_step() {
  local f="${GH_REST_AUTH_FAIL_FILE:-}" now t0="" prev=""
  if [ -n "$f" ] && [ -e "$f" ]; then
    printf -v now '%(%s)T' -1
    if [ -n "${MC_STEP_FILE:-}" ] && [ -r "$MC_STEP_FILE" ]; then
      IFS=$'\t' read -r t0 _ < "$MC_STEP_FILE" 2>/dev/null
      prev=$(tail -n 1 "$MC_STEP_FILE" 2>/dev/null | cut -f2)
    fi
    [[ "$t0" =~ ^[0-9]+$ ]] || t0=$now
    mc_log "${KEY:-?} AUTH_401: a GitHub call answered HTTP 401 during step ${prev:-start}; worker stopped after $((now - t0))s before step ${1:-?}, the next tick retries" 2>/dev/null
    [ -n "${FANIN_STAGE_FILE:-}" ] && : > "$FANIN_STAGE_FILE.auth" 2>/dev/null
    exit 0
  fi
  MC_STEP_NAME="${1:-?}"
  [ -n "${MC_STEP_FILE:-}" ] || return 0
  local name="${1:-?}" fl=0
  [[ "$name" =~ ^[A-Za-z][A-Za-z0-9:_-]{0,39}$ ]] || name=unknown
  [ "${MC_STEP_LOG:-0}" = 1 ] && fl=1
  _mc_step_end "${KEY:-?}" ""
  printf '%(%s)T\t%s\t%s\n' -1 "$name" "$fl" >> "$MC_STEP_FILE" 2>/dev/null
  [ "$fl" = 1 ] && mc_log "${KEY:-?} STEP_START step=$name" 2>/dev/null
  return 0
}

# mc_step_read <file> — the trail's last line as `<epoch>\t<name>\t<flag 0|1>`.
# Prints nothing when the file is absent or its last line is malformed.
mc_step_read() {
  local t n fl
  [ -r "${1:-}" ] || return 0
  IFS=$'\t' read -r t n fl _ <<<"$(tail -n 1 "$1" 2>/dev/null)"
  [[ "$t" =~ ^[0-9]+$ ]] && [ -n "$n" ] || return 0
  [ "$fl" = 1 ] || fl=0
  printf '%s\t%s\t%s\n' "$t" "$n" "$fl"
}

# _mc_step_end <key> <result> — the STEP_END line for the open step of
# MC_STEP_FILE, under the rule at mc_step. A non-empty result is appended as
# ` result=<result>`. Always rc 0.
_mc_step_end() {
  local t n fl now took slow line
  IFS=$'\t' read -r t n fl <<<"$(mc_step_read "${MC_STEP_FILE:-}")"
  [ -n "$t" ] || return 0
  printf -v now '%(%s)T' -1
  took=$((now - t)); [ "$took" -ge 0 ] || took=0
  slow=${MC_STEP_SLOW_S:-60}; [[ "$slow" =~ ^[0-9]+$ ]] || slow=60
  if [ "$fl" = 1 ]; then
    line="STEP_END step=$n took=${took}s"
  elif [ "$slow" -gt 0 ] && [ "$took" -ge "$slow" ]; then
    line="STEP_END step=$n took=${took}s started=$(date -u -d "@$t" +%H:%M:%S 2>/dev/null)Z"
  else
    return 0
  fi
  [ -n "$2" ] && line="$line result=$2"
  mc_log "$1 $line" 2>/dev/null
  return 0
}

# mc_step_close <key> <result> — mc_worker_bounded calls this when the worker is
# gone: the last open step ends with ` result=<rc:N|step-timeout|deadline>`
# (same log rule as mc_step), and the trail is removed. Always rc 0.
mc_step_close() {
  [ -n "${MC_STEP_FILE:-}" ] || return 0
  _mc_step_end "${1:-?}" "${2:-}"
  rm -f "$MC_STEP_FILE" 2>/dev/null
  return 0
}

# _mc_steps_summary <step file> <now> [fallback s] — prints
# `<step>\t<step_s>\t<earlier>`: the last step of the trail, its seconds up to
# <now>, and `name=Ns ...` for each step before it, at most 300 bytes (the steps
# that do not fit are counted as ` +N more`). An empty or missing trail is step
# `start` with the fallback seconds (0 when none is given). Never an empty field:
# the mark is read with IFS=tab, which joins empty fields.
_mc_steps_summary() {
  awk -F '\t' -v now="$2" -v fb="${3:-0}" '
    $1 ~ /^[0-9]+$/ && $2 != "" { n++; t[n] = $1; s[n] = $2 }
    END {
      if (!n) { printf "start\t%d\tnone\n", fb; exit }
      e = ""; more = 0
      for (i = 1; i < n; i++) {
        it = s[i] "=" (t[i + 1] - t[i]) "s"
        if (more || length(e) + length(it) + 1 > 285) { more++; continue }
        e = (e == "" ? it : e " " it)
      }
      if (more) e = e " +" more " more"
      if (e == "") e = "none"
      printf "%s\t%d\t%s\n", s[n], now - t[n], e
    }' "$1" 2>/dev/null || printf 'start\t%d\tnone\n' "${3:-0}"
}

# mc_lock_wait_left <configured s> — the seconds a project lock may be waited on
# inside a worker (BH-6346): the configured wait, capped at what is left before
# MC_WORKER_DEADLINE_AT (set by mc_worker_bounded) minus a 15 s margin, the same
# floor as mc_window_cap (under that a worker cannot read a PR and act on it).
# rc 1, nothing printed, when under 1 s is left: the caller must not wait. No
# deadline, or not a number: prints the configured value, rc 0.
mc_lock_wait_left() {
  local w="${1:-}" at="${MC_WORKER_DEADLINE_AT:-}" now left margin=15
  [[ "$at" =~ ^[0-9]+$ ]] || { printf '%s\n' "$w"; return 0; }
  printf -v now '%(%s)T' -1
  left=$(( at - now - margin ))
  [ "$left" -ge 1 ] || return 1
  if [[ "$w" =~ ^[0-9]+$ ]] && [ "$w" -le "$left" ]; then printf '%s\n' "$w"; else printf '%s\n' "$left"; fi
}

# mc_window_cap — BH-4842, THE WINDOW. A keyed backstop run carries
# MC_WORKERS_DONE_BY, the epoch second by which every worker of the run must be
# gone: the backstop's worker cap (WD, its timeout minus 45 s, never under 30 s)
# after the run started. A worker started now may use what is left until then.
# Prints that as the worker's cap, never above MC_WORKER_DEADLINE_CAP_S, and
# rc 0 when it is at least 15 s; rc 1 when it is not, and the caller must not
# start the worker (15 s: under that a worker cannot read a PR and act on it).
# No deadline, or not a number: prints nothing, rc 0 (every run that is not a
# backstop fire is unchanged).
mc_window_cap() {
  local dl="${MC_WORKERS_DONE_BY:-}" left
  [[ "$dl" =~ ^[0-9]+$ ]] || return 0
  left=$(( dl - $(date +%s) ))
  [ "$left" -ge 15 ] || return 1
  [[ "${MC_WORKER_DEADLINE_CAP_S:-}" =~ ^[0-9]+$ ]] && [ "$MC_WORKER_DEADLINE_CAP_S" -gt 0 ] \
    && [ "$MC_WORKER_DEADLINE_CAP_S" -lt "$left" ] && left=$MC_WORKER_DEADLINE_CAP_S
  printf '%s\n' "$left"
}

# mc_window_defer <key> — hand a key the window had no room for back to the
# backstop: one line in MC_WINDOW_DEFER_FILE, appended under a flock (every
# project of the run writes it in parallel), and one log line. No file: the log
# line alone; the key stays a candidate and the next fire takes it anyway.
mc_window_defer() {
  local f="${MC_WINDOW_DEFER_FILE:-}"
  mc_log "$1 WINDOW_DEFERRED: under 15s of worker time left before this run's worker deadline — not started, ${MC_WINDOW_NEXT:-the next backstop fire takes it first}" 2>/dev/null
  [ -n "$f" ] || return 0
  { flock 8 2>/dev/null; printf '%s\n' "$1" >&8; } 2>/dev/null 8>>"$f"
  return 0
}

# _mc_fanin_alert <text> — one warn alert for the merge-conductor lane, through
# the root's lane-alert.sh. With no root, or no lane-alert.sh, the log line the
# caller already wrote is the whole record.
_mc_fanin_alert() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] && [ -x "$h/bin/lane-alert.sh" ] || return 0
  "$h/bin/lane-alert.sh" --severity warn merge-conductor "$1" >/dev/null 2>&1 || true
  return 0
}

# _mc_deadline_mark <key> — the marker a deadline kill leaves for this PR in this
# tick: $MC_STATE_DIR/worker-deadline/<id>.<MC_TICK_ID>. The tick id keeps two
# overlapping ticks of one project from reading each other's. Prints nothing
# without a state dir.
_mc_deadline_mark() {
  [ -n "${MC_STATE_DIR:-}" ] || return 0
  printf '%s/worker-deadline/%s.%s' "$MC_STATE_DIR" "$(mc_handoff_id "$1" 2>/dev/null)" "${MC_TICK_ID:-notick}"
}

# _mc_kill_tree <sig> <pid> — signal <pid> and every descendant in ITS session,
# children first. A descendant in another session was detached on purpose
# (`setsid nohup` rebase, re-review, deploy-verify, batch-resolve lanes) and is
# skipped, with everything under it. The tree is collected before anything is
# signalled. With no `ps`, only <pid> is signalled. Always rc 0.
_mc_kill_tree() {
  local sig="$1" root="$2" sid p k ks i=0 q
  [[ "$root" =~ ^[0-9]+$ ]] || return 0
  if ! command -v ps >/dev/null 2>&1; then kill -"$sig" "$root" 2>/dev/null; return 0; fi
  sid=$(ps -o sid= -p "$root" 2>/dev/null | tr -d ' ')
  q=("$root")
  while [ "$i" -lt "${#q[@]}" ]; do
    p=${q[$i]}; i=$((i + 1))
    for k in $(ps -o pid= --ppid "$p" 2>/dev/null); do
      ks=$(ps -o sid= -p "$k" 2>/dev/null | tr -d ' ')
      [ -n "$sid" ] && [ -n "$ks" ] && [ "$ks" != "$sid" ] && continue
      q+=("$k")
    done
  done
  for ((i = ${#q[@]} - 1; i >= 0; i--)); do kill -"$sig" "${q[$i]}" 2>/dev/null; done
  return 0
}

# _mc_floor_row <num> — rc 0 when the keyed READY-arm floor applies to PR
# <num> of SLUG (BH-7376): MC_WORKER_DEADLINE_MIN_S is set (an opted-in keyed
# run, mc_keyed_deadline_floor) AND the PR's pr-state.tsv row is READY. A
# WAIT_CI or HEAD_MOVED row keeps the tick's deadline: only a merge needs the
# whole READY arm, and the hub has no CPU to spare (load 60-70 on 4 cores).
_mc_floor_row() {
  [[ "${MC_WORKER_DEADLINE_MIN_S:-}" =~ ^[0-9]+$ ]] && [ -n "${1:-}" ] && [ -n "${SLUG:-}" ] || return 1
  [ "$(awk -F'\t' -v k="${SLUG,,}#$1" 'tolower($1) == k { print $2; exit }' "${MC_ROWS:-/dev/null}" 2>/dev/null)" = READY ]
}

# mc_worker_deadline_s [num] — the PR worker's deadline in seconds, before any
# PR lock wait (BH-7376): MC_WORKER_DEADLINE_S (default 180, 0 = none, not a
# number = 180), raised to MC_WORKER_DEADLINE_MIN_S when the floor applies to
# PR <num> (_mc_floor_row), then never above MC_WORKER_DEADLINE_CAP_S when
# that is set. 0 stays 0. mc_worker_bounded applies the same rule inline (a
# test extracts it alone); tests/merge-conductor-keyed-timeout-test.sh K12
# proves the two agree.
mc_worker_deadline_s() {
  local d cap
  d=${MC_WORKER_DEADLINE_S:-180}; [[ "$d" =~ ^[0-9]+$ ]] || d=180
  _mc_floor_row "${1:-}" && [ "$d" != 0 ] && [ "$d" -lt "$MC_WORKER_DEADLINE_MIN_S" ] && d=$MC_WORKER_DEADLINE_MIN_S
  cap=${MC_WORKER_DEADLINE_CAP_S:-}
  if [[ "$cap" =~ ^[0-9]+$ ]] && [ "$cap" -gt 0 ] && { [ "$d" = 0 ] || [ "$d" -gt "$cap" ]; }; then d=$cap; fi
  printf '%s\n' "$d"
}

# mc_step_timeout_s <step> [num] — the step timeout the watchdog uses for
# <step> of PR <num> (BH-6351, BH-7376): MC_STEP_TIMEOUT_S (default 240, 0 =
# off); enqueue and merge never under max(MC_MERGE_LOCK_WAIT,
# MC_MERGIFY_WAIT_S) + 10; lock-probe plus MC_PR_LOCK_WAIT_S; prequeue never
# under MC_WORKER_DEADLINE_MIN_S when the READY floor applies (hub: resolve up
# to 211 s, restamp 178 s, so 240 s killed prequeue inside a 490 s deadline).
mc_step_timeout_s() {
  local eff lw mw fl pw
  eff=${MC_STEP_TIMEOUT_S:-240}; [[ "$eff" =~ ^[0-9]+$ ]] || eff=240
  [ "$eff" -gt 0 ] || { echo 0; return 0; }
  case "${1:-}" in
    enqueue|merge)
      lw=${MC_MERGE_LOCK_WAIT:-120}; [[ "$lw" =~ ^[0-9]+$ ]] || lw=120
      mw=${MC_MERGIFY_WAIT_S:-90}; [[ "$mw" =~ ^[0-9]+$ ]] || mw=90
      fl=$(( (lw > mw ? lw : mw) + 10 )); [ "$eff" -lt "$fl" ] && eff=$fl ;;
    lock-probe)
      pw=0; [[ "${MC_PR_LOCK_WAIT_S:-}" =~ ^[0-9]+$ ]] && pw=$MC_PR_LOCK_WAIT_S
      eff=$((eff + pw)) ;;
    prequeue)
      _mc_floor_row "${2:-}" && [ "$eff" -lt "$MC_WORKER_DEADLINE_MIN_S" ] && eff=$MC_WORKER_DEADLINE_MIN_S ;;
  esac
  echo "$eff"
}

# mc_worker_bounded <row> — pr_worker under a deadline (BH-4918). The backstop
# runs the keyed conductor under `timeout`, which signals its whole process
# group, and every worker of the tick is in it: one worker stuck on a slow read
# took the healthy ones, and the tick's enqueue pass, down with it. This kills
# the slow worker alone, with its gh/curl children (which also frees the PR
# lock they inherited on fd 9), and leaves the marker mc_fanin_outcome reads.
#
# The deadline is MC_WORKER_DEADLINE_S (default 180, 0 = none, not a number =
# 180), never above MC_WORKER_DEADLINE_CAP_S when that is set: the backstop sets
# the cap from its own timeout, so the deadline always fires first, whatever the
# settings row says. Runs inside fanin_run_sub's subshell, and returns the
# worker's own status (143 or 137 when it was killed).
#
# BH-6346. With a mark, the worker gets its step trail (MC_STEP_FILE=<mark>.steps,
# first line `start`) and its 401 marker path (GH_REST_AUTH_FAIL_FILE=<mark>.auth);
# with a deadline, MC_WORKER_DEADLINE_AT, the epoch of the kill, which caps every
# project-lock wait (mc_lock_wait_left). All three are locals, never exported: a
# detached child (setsid rebase, re-review) must not inherit a marker that shuts
# its own GitHub reads. The worker always runs in a subshell, so mc_step's exit
# comes back here, and both files are removed when it is gone. Trails older
# than a day (a tick killed whole) are removed by the next worker.
#
# THE STEP TIMEOUT (BH-6351). The watchdog polls the trail every
# MC_STEP_POLL_S (default 5). A step that has run MC_STEP_TIMEOUT_S (default
# 240, 0 = off, not a number = 240) is killed like a deadline, with the mark's
# kind `step-timeout`. The `enqueue` and `merge` steps wait on purpose, so their
# timeout is never under max(MC_MERGE_LOCK_WAIT, MC_MERGIFY_WAIT_S) + 10. The
# `lock-probe` step waits for the PR lock when MC_PR_LOCK_WAIT_S is set (the
# READY re-kick, BH-6000), so its timeout is the step timeout plus that wait. A step
# timeout that is not under the deadline never fires: the deadline names the
# step. A step past MC_STEP_SLOW_S (default 60, 0 = off) logs one
# `<key> STEP_SLOW step=<name> running=<n>s` while it runs. The mark is
# `<d>\t<stage>\t<step>\t<step_s>\t<earlier>\t<kind>\t<step timeout>[\t<call>\t<call_s>]`.
#
# BH-7029. The worker also gets MC_CALL_FILE=<mark>.call (a local like the
# others): the prequeue call in flight (pq_call). The watchdog reads it just
# before it writes the mark: field 8 is the call's path and field 9 its
# seconds, written only when a call runs (any other mark keeps 7 fields). The
# file goes with the mark, or with a normal return.
#
# BH-6462. The worker also gets its call trace (HARNESS_CALL_TRACE_FILE=
# <mark>.calls, a local like the others). A normal return removes it; a kill
# leaves it beside the mark for mc_fanin_outcome. With no log line for the PR,
# the mark's stage is the step, so a known step never reads `unknown`.
mc_worker_bounded() {
  local d cap mark w k rc stage dir t0 step step_s earlier key res pn
  local st slow poll start now left ts sn run eff kind seen s
  local MC_STEP_FILE="" GH_REST_AUTH_FAIL_FILE="" MC_WORKER_DEADLINE_AT="" HARNESS_CALL_TRACE_FILE="" MC_CALL_FILE=""
  local ct cp
  # The same rule as mc_worker_deadline_s, inline: a test extracts this
  # function alone (tests/ready-rekick.bh-6000-test.sh RK12).
  pn="${1%%$'\t'*}"
  d=${MC_WORKER_DEADLINE_S:-180}; [[ "$d" =~ ^[0-9]+$ ]] || d=180
  declare -F _mc_floor_row >/dev/null && _mc_floor_row "$pn" \
    && [ "$d" != 0 ] && [ "$d" -lt "$MC_WORKER_DEADLINE_MIN_S" ] && d=$MC_WORKER_DEADLINE_MIN_S
  cap=${MC_WORKER_DEADLINE_CAP_S:-}
  if [[ "$cap" =~ ^[0-9]+$ ]] && [ "$cap" -gt 0 ] && { [ "$d" = 0 ] || [ "$d" -gt "$cap" ]; }; then d=$cap; fi
  # A run that WAITS for its PR lock (MC_PR_LOCK_WAIT_S, the READY re-kick,
  # BH-6000) gets that wait on top of its deadline: the wait is spent before
  # the worker does any work, so it must not eat the work's own time (Fable
  # review of 9fc9454d1, finding 2).
  if [ "$d" != 0 ] && [[ "${MC_PR_LOCK_WAIT_S:-}" =~ ^[0-9]+$ ]] && [ "${MC_PR_LOCK_WAIT_S}" -gt 0 ]; then d=$((d + MC_PR_LOCK_WAIT_S)); fi
  key="${SLUG:-}#${1%%$'\t'*}"
  mark=$(_mc_deadline_mark "$key")
  if [ -z "$mark" ]; then pr_worker "$@"; return; fi
  dir="${mark%/*}"; mkdir -p "$dir" 2>/dev/null
  # A tick killed whole leaves its workers' trails: nothing came back to remove
  # them. A day is far past any tick, so a live worker's files are never hit.
  find "$dir" -maxdepth 1 -type f \( -name '*.steps' -o -name '*.auth' -o -name '*.calls' -o -name '*.call' -o -name '*.call.over' \) -mmin +1440 -delete 2>/dev/null
  MC_STEP_FILE="$mark.steps"; GH_REST_AUTH_FAIL_FILE="$mark.auth"; HARNESS_CALL_TRACE_FILE="$mark.calls"; MC_CALL_FILE="$mark.call"
  rm -f "$MC_STEP_FILE" "$GH_REST_AUTH_FAIL_FILE" "$HARNESS_CALL_TRACE_FILE" "$MC_CALL_FILE" 2>/dev/null
  printf '%(%s)T\tstart\n' -1 > "$MC_STEP_FILE" 2>/dev/null
  if [ "$d" = 0 ]; then
    ( pr_worker "$@" ); rc=$?
    mc_step_close "$key" "rc:$rc"
    rm -f "$MC_STEP_FILE" "$GH_REST_AUTH_FAIL_FILE" "$HARNESS_CALL_TRACE_FILE" "$MC_CALL_FILE" "$MC_CALL_FILE.over" 2>/dev/null
    return "$rc"
  fi
  st=${MC_STEP_TIMEOUT_S:-240}; [[ "$st" =~ ^[0-9]+$ ]] || st=240
  slow=${MC_STEP_SLOW_S:-60}; [[ "$slow" =~ ^[0-9]+$ ]] || slow=60
  poll=${MC_STEP_POLL_S:-5}; [[ "$poll" =~ ^[0-9]+$ ]] && [ "$poll" -ge 1 ] || poll=5
  # Each step's own timeout (the enqueue/merge floor, the lock-probe wait, the
  # READY prequeue floor) is mc_step_timeout_s, read on every poll below.
  MC_WORKER_DEADLINE_AT=$(( $(date +%s) + d ))
  pr_worker "$@" & w=$!
  (
    # The deadline, or the first step past its timeout, whichever comes first.
    printf -v start '%(%s)T' -1
    kind=deadline; eff=$st; seen=""
    while :; do
      printf -v now '%(%s)T' -1
      left=$(( start + d - now ))
      [ "$left" -gt 0 ] || break
      IFS=$'\t' read -r ts sn _ <<<"$(mc_step_read "$MC_STEP_FILE")"
      if [ -n "$ts" ]; then
        run=$(( now - ts ))
        # One rule for every step's timeout (BH-7376): mc_step_timeout_s.
        eff=$(mc_step_timeout_s "$sn" "$pn")
        if [ "$eff" -gt 0 ] && [ "$eff" -lt "$d" ] && [ "$run" -ge "$eff" ]; then kind=step-timeout; break; fi
        if [ "$slow" -gt 0 ] && [ "$run" -ge "$slow" ] && [ "$seen" != "$ts $sn" ]; then
          seen="$ts $sn"
          mc_log "$key STEP_SLOW step=$sn running=${run}s" 2>/dev/null
        fi
      fi
      s=$poll; [ "$s" -le "$left" ] || s=$left
      sleep "$s"
    done
    # The stage is the last line this tick logged for the PR: already in the
    # log, so it puts nothing new (no argv, no token) in an alert. With no such
    # line it is the step (BH-6462), never `unknown` when the step is known.
    t0=$(date -u -d "@${MC_FANIN_T0:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    stage=$(tail -n 5000 "${MC_LOG:-/dev/null}" 2>/dev/null \
      | awk -v k="${SLUG:-}#${1%%$'\t'*}" -v t="$t0" '(index($0, k " ") || index($0, k ":")) && substr($0, 1, 19) >= t { l = $0 } END { print substr(l, 1, 300) }')
    # The step is the trail's last line (THE STEP TRAIL, at mc_step). No field
    # is written empty: the reader splits on tabs, and IFS joins empty fields.
    IFS=$'\t' read -r step step_s earlier <<<"$(_mc_steps_summary "$MC_STEP_FILE" "$(date +%s)" "$d")"
    stage="${stage//$'\t'/ }"
    # The prequeue call in flight (BH-7029), read before the mark: fields 8
    # and 9 only when a call runs, so every other mark keeps its 7 fields.
    ct=""; cp=""; { IFS=$'\t' read -r ct cp _ < "$MC_CALL_FILE"; } 2>/dev/null
    [[ "$ct" =~ ^[0-9]+$ ]] && [ -n "$cp" ] || cp=""
    printf -v now '%(%s)T' -1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n' "$d" "${stage:-${step:-start}}" "${step:-start}" "${step_s:-$d}" "${earlier:-none}" "$kind" "$eff" \
      "${cp:+$'\t'$cp$'\t'$((now - ct))}" > "$mark" 2>/dev/null
    _mc_kill_tree TERM "$w"; sleep 5; _mc_kill_tree KILL "$w"
  ) & k=$!
  wait "$w"; rc=$?
  _mc_kill_tree TERM "$k"; wait "$k" 2>/dev/null
  res="rc:$rc"
  [ -f "$mark" ] && { IFS=$'\t' read -r _ _ _ _ _ res _ < "$mark"; res=${res:-deadline}; } 2>/dev/null
  mc_step_close "$key" "$res"
  rm -f "$MC_STEP_FILE" "$GH_REST_AUTH_FAIL_FILE" "$MC_CALL_FILE.over" 2>/dev/null
  # A kill wrote the mark: its trace and call file stay for mc_fanin_outcome.
  [ -f "$mark" ] || rm -f "$HARNESS_CALL_TRACE_FILE" "$MC_CALL_FILE" 2>/dev/null
  return "$rc"
}
