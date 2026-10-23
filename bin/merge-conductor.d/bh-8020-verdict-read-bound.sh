# shellcheck shell=bash
# bin/merge-conductor.d/bh-8020-verdict-read-bound.sh - EACH CALL OF THE
# VERDICT-READ STEP IS NAMED, TIMED AND BOUNDED (BH-8020). Sourced by
# bin/merge-conductor.sh (the BH-7453 fragment block); no side effect at
# source time.
#
# WHY. A worker was killed at its 419 s deadline in step verdict-read, and the
# kill named the step but no call (Sentry CROMFORD-HARNESS-T). The step reads
# the build record, then the jobs ledger's /api/verdict up to three times
# (mc_verdict, mc_contradiction_words in bin/lib/mc/classify.sh), each read up
# to about 38 s with _jobs_req's retries, and nothing named the read in flight.
#
# THE CALLS. pr_worker calls mc_vr_begin right after `mc_step verdict-read`.
# From then until mc_vr_end, mc_vr_run (classify.sh) hands each call to
# mc_vr_call under its name: review-file, headbound, ledger-verdict,
# rr-verdict, contradiction (reads) and eject-rebased (a write).
#
#   mc_vr_call [-w] <name> <cmd> [args...]
#       Writes the BH-7029 call line `<epoch>\tverdict-read/<name>\t<r|w>\t
#       <shell pid>\t<start cs>` to MC_CALL_FILE (when set), so a deadline
#       kill names the call (mc_worker_bounded, mc_fanin_outcome). A READ runs
#       under mc_vr_bound_s seconds in a child that never holds the PR lock
#       (fd 9); past the bound its process tree gets TERM, then KILL 3 s later,
#       and the answer is rc 124 with no stdout (a late answer never counts).
#       A WRITE (-w) is named and timed but never cut. After a cut every later
#       call of the step runs nothing and returns 124. Empties MC_CALL_FILE
#       after the call. Returns <cmd>'s rc.
#   mc_vr_end
#       Logs ONE line, `<key> VERDICT_READ took=<s.s>s calls: <name>=<s.s>s
#       rc=<rc> ...`. rc 0 when no read was cut. rc 1 after a cut: pr_worker
#       returns at once (no decision on a partial verdict, the PR lock goes
#       with the worker, the row is left as it is), and a READY row gets the
#       ready-why note `verdict-read-timeout`, so fan-in reads `READY
#       held:verdict-read-timeout`. No alert and no Sentry event for a cut.
#
# A cut writes one line: `<key> VERDICT_READ_TIMEOUT call=verdict-read/<name>
# took=<n>s timeout=<b>s rc=124: ...`.
#
# THE BOUND (mc_vr_bound_s). MC_VERDICT_READ_CALL_TIMEOUT_S (default 45, 0 =
# no bound, not a number = 45; settings row
# lane.merge-conductor.mc_verdict_read_call_timeout_s), never past the worker
# deadline minus 15 s (mc_lock_wait_left). Under 1 s of worker time left: rc 1,
# and the call is not started (a took=0s cut).

# mc_vr_bound_s — the bound in seconds for one read of the step (THE BOUND).
mc_vr_bound_s() {
  local b="${MC_VERDICT_READ_CALL_TIMEOUT_S:-}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=45
  b=$((10#$b))
  [ "$b" = 0 ] && { echo 0; return 0; }
  if declare -F mc_lock_wait_left >/dev/null; then mc_lock_wait_left "$b"; return; fi
  echo "$b"
}

# _mc_vr_now_us — EPOCHREALTIME in microseconds.
_mc_vr_now_us() { local n="${EPOCHREALTIME//[!0-9]/}"; echo $((10#$n)); }

# _mc_vr_wait_s <n> — wait <n> seconds of wall time with the read builtin, so
# a `sleep` stub on PATH never ends the bound early (the BH-7748 lesson).
_mc_vr_wait_s() {
  local end now r
  end=$(( $(_mc_vr_now_us) + ${1:-0} * 1000000 ))
  while :; do
    now=$(_mc_vr_now_us)
    [ "$now" -lt "$end" ] || return 0
    r=$(( end - now )); printf -v r '%d.%06d' $((r / 1000000)) $((r % 1000000))
    read -rt "$r" <> <(:) 2>/dev/null; [ $? -gt 128 ] || sleep 1
  done
}

# _mc_vr_kill <sig> <pid> — the conductor's _mc_kill_tree when it is loaded.
_mc_vr_kill() {
  if declare -F _mc_kill_tree >/dev/null; then _mc_kill_tree "$1" "$2"; else kill -"$1" "$2" 2>/dev/null; fi
  return 0
}

# _mc_vr_cut <name> <took s> <bound s> — record the cut and log its one line.
_mc_vr_cut() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$MC_VR_DIR/timeout" 2>/dev/null
  mc_log "${KEY:-?} VERDICT_READ_TIMEOUT call=verdict-read/$1 took=$2s timeout=$3s rc=124: the verdict read did not answer; nothing decided on this PR this tick, the next tick reads it again" 2>/dev/null
  return 0
}

# mc_vr_begin — start the step's call record. A private dir holds the calls
# and the cut; a worker killed mid-step leaves it, so dirs over a day old go.
mc_vr_begin() {
  local t="${TMPDIR:-/tmp}"
  find "$t" -mindepth 1 -maxdepth 1 -type d -name 'mc-vr.*' -mmin +1440 -exec rm -rf {} + 2>/dev/null
  unset _MC_VR_ON
  MC_VR_DIR=$(mktemp -d "$t/mc-vr.XXXXXX" 2>/dev/null) || { MC_VR_DIR=""; return 0; }
  MC_VR_T0=$(_mc_vr_now_us)
  _MC_VR_ON=1
  [ -n "${MC_CALL_FILE:-}" ] && : > "$MC_CALL_FILE" 2>/dev/null
  return 0
}

# mc_vr_call [-w] <name> <cmd> [args...] — one call of the step (THE CALLS).
mc_vr_call() {
  local w=r n b rc=0 t0 t1 d up="" out p k cut=0 f="${MC_CALL_FILE:-}"
  [ "${1:-}" = -w ] && { w=w; shift; }
  n="${1:-?}"; shift
  if [ -z "${MC_VR_DIR:-}" ] || [ ! -d "$MC_VR_DIR" ]; then "$@"; return; fi
  if [ -e "$MC_VR_DIR/timeout" ]; then
    printf '%s=0.0s rc=124\n' "$n" >> "$MC_VR_DIR/calls" 2>/dev/null
    return 124
  fi
  b=0
  if [ "$w" = r ] && ! b=$(mc_vr_bound_s); then
    printf '%s=0.0s rc=124\n' "$n" >> "$MC_VR_DIR/calls" 2>/dev/null
    _mc_vr_cut "$n" 0 0
    return 124
  fi
  [ -r /proc/uptime ] && read -r up _ < /proc/uptime 2>/dev/null
  up="${up//[!0-9]/}"
  [ -n "$f" ] && printf '%s\t%s\t%s\t%s\t%s\n' "${EPOCHSECONDS}" "verdict-read/$n" "$w" "$BASHPID" "$up" > "$f" 2>/dev/null
  t0=$(_mc_vr_now_us)
  if [ "$b" = 0 ] || ! out=$(mktemp "$MC_VR_DIR/out.XXXXXX" 2>/dev/null); then
    "$@" || rc=$?
  else
    "$@" > "$out" 9>&- & p=$!
    # Not on the caller's $( ) pipe: the capture would wait for the watchdog.
    ( _mc_vr_wait_s "$b"; : > "$out.to"; _mc_vr_kill TERM "$p"; _mc_vr_wait_s 3; _mc_vr_kill KILL "$p" ) 9>&- </dev/null >/dev/null 2>&1 & k=$!
    wait "$p"; rc=$?
    _mc_vr_kill KILL "$k"; wait "$k" 2>/dev/null
    if [ -e "$out.to" ]; then cut=1; rc=124; else cat "$out" 2>/dev/null; fi
    rm -f "$out" "$out.to" 2>/dev/null
  fi
  t1=$(_mc_vr_now_us)
  [ -n "$f" ] && : > "$f" 2>/dev/null
  d=$(( (t1 - t0) / 100000 )); [ "$d" -ge 0 ] || d=0
  printf '%s=%d.%ds rc=%s\n' "$n" $((d / 10)) $((d % 10)) "$rc" >> "$MC_VR_DIR/calls" 2>/dev/null
  [ "$cut" = 1 ] && _mc_vr_cut "$n" $((d / 10)) "$b"
  return "$rc"
}

# mc_vr_end — the step's one log line; rc 1 when a read was cut (THE CALLS).
mc_vr_end() {
  local d calls n b rc=0
  [ "${_MC_VR_ON:-}" = 1 ] || return 0
  unset _MC_VR_ON
  [ -n "${MC_CALL_FILE:-}" ] && : > "$MC_CALL_FILE" 2>/dev/null
  d=$(( ($(_mc_vr_now_us) - ${MC_VR_T0:-0}) / 100000 )); [ "$d" -ge 0 ] || d=0
  calls=$(tr '\n' ' ' 2>/dev/null < "$MC_VR_DIR/calls"); calls="${calls% }"
  mc_log "${KEY:-?} VERDICT_READ took=$((d / 10)).$((d % 10))s calls: ${calls:-none}" 2>/dev/null
  if [ -e "$MC_VR_DIR/timeout" ]; then
    rc=1
    IFS=$'\t' read -r n _ b 2>/dev/null < "$MC_VR_DIR/timeout"
    if [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] && declare -F mc_ready_why >/dev/null \
       && [ "$(mc_row_field "$KEY" 2 2>/dev/null)" = READY ]; then
      mc_ready_why "$KEY" "$HEAD" verdict-read-timeout \
        "the verdict read (call verdict-read/${n:-?}) did not answer in ${b:-?}s; nothing decided this tick, the next tick reads it again" logged
    fi
  fi
  rm -f "$MC_VR_DIR"/* 2>/dev/null; rmdir "$MC_VR_DIR" 2>/dev/null
  MC_VR_DIR=""
  return "$rc"
}
