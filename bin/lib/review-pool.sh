#!/bin/bash
# bin/lib/review-pool.sh — BH-5284: run a review lane's units of work K at a
# time on one box. Shared by bin/lead-review.sh (lead reviews) and
# bin/review-prs.sh (builder re-reviews). Sourced, never executed; defining
# functions is its only effect at source time.
#
# WHY. Both lanes reviewed one PR at a time. A lead review takes 7-9 minutes,
# so a tick capped at LEAD_REVIEW_DEADLINE_S=3600 did 6-8 an hour while the
# lead line reached 58 PRs on 2026-10-07. Each review already owns its own
# scratch worktree, agent session and per-(pr, head) claim (job_open rc 9 on a
# second runner), so running several at once is safe; it was just not done.
#
# THE SHAPE. The tick stays the one place that decides WHAT runs and in which
# order. For each unit it calls rpool_start, which forks a worker subshell, and
# then rpool_gate_wait, which blocks until the worker opens its GATE: a point
# the lane chooses after the cheap, ordered part of the unit (the claim, for a
# lead review; every read and ledger write before the paid call, for a builder
# review). Everything before the gate is therefore still serial and in queue
# order, exactly as before; only the expensive tail (host suite, agent call,
# posting) overlaps. A worker that exits before reaching its gate opens it on
# the way out, so a skip never stalls the tick.
#
# A WORKER
#   * gets its own scratch dir as TMPDIR ($RPOOL_DIR/tmp.<id>), removed when it
#     exits, together with whatever the lane's RPOOL_ON_EXIT hook cleans (the
#     lead review's worktree). Only SIGKILL skips that; the tick's collect then
#     removes the scratch dir.
#   * when the lane sets RPOOL_TMP_PREFIX (lead-review: lr), also gets its own
#     dir under the tmp path, <prefix><tickpid>-<id> (mode 711), exported as
#     RPOOL_TMP_OWN (empty and not exported when there is none), for what must live on /tmp (the rules pack's snapshot,
#     which nobody must reach). Its EXIT trap removes it; after a SIGKILL the
#     tick's collect does, and rpool_finish removes any <prefix><tickpid>-* that
#     is left. The path is built from the tick pid and the id only. When the
#     dir cannot be made, the worker runs without it (one log line). Empty
#     (review-prs) = no dir.
#   * writes its result word ($RPOOL_RESULT, set by the lane) to
#     $RPOOL_DIR/<id>.r as the LAST thing its EXIT trap does, so the tick reads
#     an outcome only from a worker that is done.
#   * is never abandoned: the tick waits for every worker it started
#     (rpool_wait_all) before its summary, so a worker still running at the
#     tick's deadline finishes and records its verdict. Its claim and heartbeat
#     are its own (opened inside the worker), so they stay valid throughout.
#     A tick that ends early (TERM, INT) leaves a live worker's scratch to the
#     worker: rpool_finish removes nothing while one of its workers runs (BH-6984).
#   * when the lane sets RPOOL_LIVE_DIR (lead-review: state/lead-review/pool),
#     holds the file <dir>/<tickpid>-<id> (its pid) while it runs, so a LATER
#     tick of the lane counts it (rpool_box_running) against the slot cap
#     while this tick waits for it with its tick lock released (BH-6984). Its
#     EXIT trap removes the file; after a SIGKILL the tick's collect does, and
#     a file whose pid is gone is not counted and is removed by the count.
#
# GUARDRAILS (all read with the lane's knob prefix P, LEAD_REVIEW or REVIEW):
#   P_CONCURRENCY      K, resolved by the lane (registry knob, settings row
#                      lane.<id>.<p>_concurrency). Default 10. 0 = NO CAP: every
#                      eligible unit starts, bounded only by the guardrails
#                      below (and the lane's own start cap, if set).
#   P_BOX_MAX          a hard cap on this box. 0 or unset = derived from three
#                      terms, in this order:
#                        cpu     vCPUs / P_WORKER_CPUS (default 1);
#                        memory  MemAvailable / P_WORKER_MEM_MB (registry
#                                default 700 for lead-review, measured, and
#                                2048 for review-prs; 2048 here only when the
#                                registry cannot be read);
#                                when the tmp path is tmpfs, its use is RAM:
#                                (MemAvailable - tmpfs used) /
#                                (P_WORKER_MEM_MB + P_WORKER_TMP_MB);
#                        tmp     (free /tmp - P_TMP_MIN_MB) / P_WORKER_TMP_MB
#                                (default 256).
#                      The memory and tmp terms add back the workers other
#                      ticks still run here (rpool_others), which already
#                      use their share of what is free (BH-6984).
#                      The smallest wins (a tie keeps the earlier term) and is
#                      logged once a tick as `concurrency capped at N by
#                      cpu|memory|tmp (<inputs>)`. A term it cannot read is
#                      skipped. Never below 1. The two worker knobs are
#                      registry knobs of both lanes: LEAD_REVIEW_WORKER_CPUS,
#                      LEAD_REVIEW_WORKER_MEM_MB, REVIEW_WORKER_CPUS and
#                      REVIEW_WORKER_MEM_MB.
#   P_TMP_MIN_MB       no NEW worker starts while free space under
#                      $REVIEW_POOL_TMP_PATH (default /tmp) is below it
#                      (default 1536). One alert line per low episode
#                      (state/review-pool-tmp-low.<lane>, removed when space
#                      is back). Unreadable space = fail open.
#   the spend cap      rpool_spend_ok asks bin/lib/llm-gate.sh's
#                      llm_gate_precall (the lane's LLM_USD_CAP_DAY) before a
#                      start, at most once per REVIEW_POOL_SPEND_TTL_S (60) per
#                      project. Over the cap = no new start; agent-call.sh still
#                      gates every call itself (rc 74, nothing billed).
#
#   rate limits        a worker whose agent call failed with a 429, an
#                      "overloaded" or an account concurrency limit
#                      (rpool_rate_limited on its output) records NO verdict and
#                      reports `ratelimited`; the lane releases the work exactly
#                      as it does a before-billing refusal, and it never counts
#                      as a failed review. The pool then pauses NEW starts for
#                      P_RATE_BACKOFF_S (default 60), doubling on each repeat up
#                      to 900s, reset by the next review that ends normally. The
#                      pause is a file (state/review-pool-backoff.<lane>), so it
#                      outlives the tick, and it is logged once when it begins.
#
# API
#   rpool_init <lane> <prefix> <k> <dir> <logfn>  sets RPOOL_K (box-capped)
#                               and RPOOL_CAP_BY, the guardrail that set it:
#                               box_max, cpu, memory, tmp, or empty (BH-5617), and
#                               RPOOL_CAP_WHY, the text of its log line.
#                               It first runs the /tmp sweep once
#                               ($REVIEW_POOL_TMP_SWEEP, default
#                               $HARNESS/bin/tmp-sweep.sh; empty = off), bounded
#                               at 120 s, rc ignored, so stale scratch is gone
#                               before free /tmp sizes the pool (BH-5608).
#   rpool_tmp_ok                rc 0 = room to start a worker
#   rpool_spend_ok <stage> <project>  rc 0 = under the cap or unknown
#   rpool_start <id> <cmd...>   fork a worker running <cmd...>
#   rpool_gate_open             (in a worker) let the tick start the next unit
#   rpool_gate_wait <id>        block until <id>'s gate is open
#   rpool_reap                  collect finished workers, never blocks
#   rpool_wait_one              block until one worker finishes, collect it
#   rpool_wait_all              collect every worker
#   rpool_running               the number of live workers of this tick
#   rpool_box_running           that plus the live workers other ticks of the
#                               lane left running on this box (RPOOL_LIVE_DIR)
#   rpool_finish                remove $RPOOL_DIR and any <prefix><tickpid>-* left
#   rpool_rate_limited <out>    rc 0 when <out>/<out>.err reads as a rate limit
#   rpool_rate_hit / rpool_rate_ok   start or extend / clear the backoff
#   rpool_paused                rc 0 while new starts are paused (RPOOL_PAUSE_LEFT)
# A collected worker calls the lane's `rpool_on_result <id> <result>`.

RPOOL_K=1; RPOOL_DIR=""; RPOOL_LANE=""; RPOOL_PFX=""; RPOOL_LOGFN=""; RPOOL_CAP_BY=""; RPOOL_CAP_WHY=""
RPOOL_TMP_PREFIX=""; RPOOL_LIVE_DIR=""
RPOOL_STARTED=0
declare -gA _RPOOL_PIDS=()   # pid -> id
declare -gA _RPOOL_SPEND_AT=() _RPOOL_SPEND_RC=()

# _rpool_sleep — the poll pause as a BUILTIN (read -t on a pipe nobody writes),
# not a forked `sleep`: a forked child inherits the caller's fds, and a tick
# killed mid-wait would leave it holding the lane's tick lock (fd 7) after it.
_RPOOL_SFD=""
_rpool_sleep() {
  local t="${REVIEW_POOL_POLL_S:-0.2}"
  if [ -z "$_RPOOL_SFD" ]; then exec {_RPOOL_SFD}<> <(:) 2>/dev/null || _RPOOL_SFD=none; fi
  if [ "$_RPOOL_SFD" = none ]; then sleep "$t"; else read -r -t "$t" -u "$_RPOOL_SFD" _ 2>/dev/null; fi
  return 0
}
_rpool_log() { [ -n "$RPOOL_LOGFN" ] && "$RPOOL_LOGFN" "$*"; return 0; }
_rpool_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) [ "$1" -gt 0 ] ;; esac; }
_rpool_knob() { local v="${RPOOL_PFX}_$1"; v="${!v:-}"; _rpool_int "$v" && { printf '%s' "$v"; return; }; printf '%s' "$2"; }
_rpool_tmp_path() { printf '%s' "${REVIEW_POOL_TMP_PATH:-/tmp}"; }
# _rpool_own_tmp <id> — a worker's own dir, <tmp path>/<prefix><tickpid>-<id>;
# rc 1 when RPOOL_TMP_PREFIX is empty or either part is not a plain name. $$ is
# the tick's pid in the tick and in every worker subshell alike.
_rpool_own_tmp() {
  case "$RPOOL_TMP_PREFIX" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/%s%s-%s' "$(_rpool_tmp_path)" "$RPOOL_TMP_PREFIX" "$$" "$1"
}
# _rpool_tmp_free_mb — free MB under the tmp path; rc 1 when unreadable.
_rpool_tmp_free_mb() {
  local f
  f=$(df -Pk "$(_rpool_tmp_path)" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }')
  case "$f" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$f"
}
# _rpool_tmp_used_mb — MB in use under the tmp path; 0 when unreadable.
_rpool_tmp_used_mb() {
  local u
  u=$(df -Pk "$(_rpool_tmp_path)" 2>/dev/null | awk 'NR == 2 { print int($3 / 1024) }')
  case "$u" in ''|*[!0-9]*) u=0 ;; esac
  printf '%s' "$u"
}
_rpool_tmp_fstype() { [ -n "${REVIEW_POOL_TMP_FSTYPE:-}" ] && { printf '%s' "$REVIEW_POOL_TMP_FSTYPE"; return; }; stat -f -c %T "$(_rpool_tmp_path)" 2>/dev/null; }
# _rpool_ncpu — vCPUs on this box; rc 1 when nothing answers.
_rpool_ncpu() {
  local c="${REVIEW_POOL_NPROC:-}"
  _rpool_int "$c" || c=$(nproc 2>/dev/null)
  _rpool_int "$c" || c=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
  _rpool_int "$c" || return 1
  printf '%s' "$c"
}
_rpool_mem_free_mb() {
  local m
  m=$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' "${REVIEW_POOL_MEMINFO:-/proc/meminfo}" 2>/dev/null)
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$m"
}

rpool_init() { # rpool_init <lane> <prefix> <k> <dir> <logfn>
  local k="${3:-1}" box n reason="" mem tmp per min h="${HARNESS:-${H:-}}" sw ncpu wc used tper oth
  RPOOL_LANE="$1"; RPOOL_PFX="$2"; RPOOL_DIR="$4"; RPOOL_LOGFN="${5:-}"
  RPOOL_STARTED=0; _RPOOL_PIDS=(); RPOOL_CAP_BY=""; RPOOL_CAP_WHY=""
  mkdir -p "$RPOOL_DIR" 2>/dev/null
  [ -n "$RPOOL_LIVE_DIR" ] && mkdir -p "$RPOOL_LIVE_DIR" 2>/dev/null
  case "$k" in 0) k=1000; reason="" ;; *) _rpool_int "$k" || k=1 ;; esac
  # The sweep's own flock makes a second concurrent tick's call a no-op, and
  # its own lane gate honours flags/lane-off-tmp-sweep.
  sw="${REVIEW_POOL_TMP_SWEEP-${h:+$h/bin/tmp-sweep.sh}}"
  [ -n "$sw" ] && [ -x "$sw" ] && timeout 120 "$sw" >/dev/null 2>&1
  box=$(_rpool_knob BOX_MAX "")
  if [ -n "$box" ]; then
    [ "$box" -lt "$k" ] && { k=$box; reason="${RPOOL_PFX}_BOX_MAX=$box"; RPOOL_CAP_BY=box_max; }
  else
    if ncpu=$(_rpool_ncpu); then
      wc=$(_rpool_knob WORKER_CPUS 1); n=$((ncpu / wc))
      [ "$n" -lt "$k" ] && { k=$n; reason="cpu (${ncpu} vCPU, ${wc} a worker)"; RPOOL_CAP_BY=cpu; }
    fi
    oth=$(rpool_others)
    if mem=$(_rpool_mem_free_mb); then
      per=$(_rpool_knob WORKER_MEM_MB 2048)
      if [ "$(_rpool_tmp_fstype)" = tmpfs ]; then
        used=$(_rpool_tmp_used_mb); tper=$(_rpool_knob WORKER_TMP_MB 256)
        n=$(( (mem - used) / (per + tper) + oth ))
        [ "$n" -lt "$k" ] && { k=$n; reason="memory (${mem}MB free, ${used}MB in tmpfs $(_rpool_tmp_path), ${per}+${tper}MB a worker)"; RPOOL_CAP_BY=memory; }
      else
        n=$((mem / per + oth))
        [ "$n" -lt "$k" ] && { k=$n; reason="memory (${mem}MB free, ${per}MB a worker)"; RPOOL_CAP_BY=memory; }
      fi
    fi
    if tmp=$(_rpool_tmp_free_mb); then
      per=$(_rpool_knob WORKER_TMP_MB 256); min=$(_rpool_knob TMP_MIN_MB 1536)
      n=$(( (tmp - min) / per + oth ))
      [ "$n" -lt "$k" ] && { k=$n; reason="tmp ($(_rpool_tmp_path) ${tmp}MB free, ${min}MB floor, ${per}MB a worker)"; RPOOL_CAP_BY=tmp; }
    fi
  fi
  [ "$k" -lt 1 ] && k=1
  RPOOL_K=$k; RPOOL_CAP_WHY="$reason"
  [ -n "$reason" ] && _rpool_log "concurrency capped at $k by $reason"
  return 0
}

rpool_tmp_ok() {
  local free min mark h="${HARNESS:-${H:-}}"
  free=$(_rpool_tmp_free_mb) || return 0
  min=$(_rpool_knob TMP_MIN_MB 1536)
  mark="$h/state/review-pool-tmp-low.$RPOOL_LANE"
  if [ "$free" -ge "$min" ]; then rm -f "$mark" 2>/dev/null; return 0; fi
  _rpool_log "no new worker: $(_rpool_tmp_path) has ${free}MB free, below ${RPOOL_PFX}_TMP_MIN_MB=$min"
  if [ -n "$h" ] && [ ! -e "$mark" ]; then
    mkdir -p "$h/state" 2>/dev/null; : > "$mark"
    if [ -x "$h/bin/alert-line.sh" ]; then
      HARNESS="$h" "$h/bin/alert-line.sh" --id "review-pool-tmp-low-$RPOOL_LANE" \
        "[$RPOOL_LANE] $(_rpool_tmp_path) has ${free}MB free, below ${RPOOL_PFX}_TMP_MIN_MB=${min}MB: no new review workers start until it is cleared (BH-5284)" >/dev/null 2>&1
    fi
  fi
  return 1
}

RPOOL_SPEND_REASON=""
rpool_spend_ok() { # rpool_spend_ok <stage> <project> — rc 1 only on a measured refusal
  local st="${1:-}" pj="${2:-}" key now ttl rc
  command -v llm_gate_precall >/dev/null 2>&1 || return 0
  key="$st|$pj"; now=$(date +%s); ttl="${REVIEW_POOL_SPEND_TTL_S:-60}"
  if [ -n "${_RPOOL_SPEND_AT[$key]:-}" ] && [ $((now - _RPOOL_SPEND_AT[$key])) -lt "$ttl" ]; then
    return "${_RPOOL_SPEND_RC[$key]}"
  fi
  llm_gate_precall "$st" "$pj"; rc=$?
  [ "$rc" -eq 2 ] && rc=1 || rc=0
  RPOOL_SPEND_REASON="${LLM_GATE_REASON:-}"
  _RPOOL_SPEND_AT[$key]=$now; _RPOOL_SPEND_RC[$key]=$rc
  return "$rc"
}

# --- the worker side -----------------------------------------------------------
RPOOL_ID=""; RPOOL_RESULT=""; RPOOL_ON_EXIT=""
rpool_gate_open() { [ -n "$RPOOL_ID" ] && : > "$RPOOL_DIR/$RPOOL_ID.g" 2>/dev/null; return 0; }
_rpool_worker_exit() {
  [ -n "$RPOOL_ON_EXIT" ] && "$RPOOL_ON_EXIT"
  [ -n "$RPOOL_LIVE_DIR" ] && rm -f "$RPOOL_LIVE_DIR/$$-$RPOOL_ID" 2>/dev/null
  rm -rf "$RPOOL_DIR/tmp.$RPOOL_ID" 2>/dev/null
  [ -n "${RPOOL_TMP_OWN:-}" ] && rm -rf --one-file-system -- "$RPOOL_TMP_OWN" 2>/dev/null
  rpool_gate_open
  printf '%s\n' "$RPOOL_RESULT" > "$RPOOL_DIR/$RPOOL_ID.r.tmp" 2>/dev/null \
    && mv -f "$RPOOL_DIR/$RPOOL_ID.r.tmp" "$RPOOL_DIR/$RPOOL_ID.r" 2>/dev/null
}

rpool_start() { # rpool_start <id> <cmd...>
  local id="$1" own; shift
  rm -f "$RPOOL_DIR/$id.g" "$RPOOL_DIR/$id.r" 2>/dev/null
  (
    RPOOL_ID="$id"; RPOOL_RESULT=""; RPOOL_ON_EXIT=""
    [ -n "$RPOOL_LIVE_DIR" ] && printf '%s\n' "$BASHPID" > "$RPOOL_LIVE_DIR/$$-$id" 2>/dev/null
    export -n RPOOL_TMP_OWN 2>/dev/null; RPOOL_TMP_OWN=""
    mkdir -p "$RPOOL_DIR/tmp.$id" 2>/dev/null && export TMPDIR="$RPOOL_DIR/tmp.$id"
    if own=$(_rpool_own_tmp "$id"); then
      if mkdir -m 711 -- "$own" 2>/dev/null; then export RPOOL_TMP_OWN="$own"
      else _rpool_log "worker $id: cannot make $own; it runs without its own tmp dir"; fi
    fi
    trap _rpool_worker_exit EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    "$@"
  ) &
  _RPOOL_PIDS[$!]="$id"; RPOOL_STARTED=$((RPOOL_STARTED + 1))
}

# --- the tick side -------------------------------------------------------------
rpool_running() { printf '%s' "${#_RPOOL_PIDS[@]}"; }
# rpool_others — the live workers other ticks of the lane run on this box
# (RPOOL_LIVE_DIR; 0 without it). A file whose pid is gone is removed here.
rpool_others() {
  local f p n=0
  [ -n "$RPOOL_LIVE_DIR" ] && [ -d "$RPOOL_LIVE_DIR" ] || { printf 0; return 0; }
  for f in "$RPOOL_LIVE_DIR"/*-*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in "$$-"*) continue ;; esac
    read -r p < "$f" 2>/dev/null || p=""
    if _rpool_int "$p" && _rpool_alive "$p"; then n=$((n + 1)); else rm -f "$f" 2>/dev/null; fi
  done
  printf '%s' "$n"
}
rpool_box_running() { printf '%s' "$(( ${#_RPOOL_PIDS[@]} + $(rpool_others) ))"; }
# _rpool_alive <pid> — rc 0 while it runs. A zombie (exited, not yet waited
# for: what a SIGKILLed worker leaves) is not alive.
_rpool_alive() {
  local st
  if [ -r "/proc/$1/stat" ]; then
    st=$(awk '{ print $3 }' "/proc/$1/stat" 2>/dev/null) || return 1
    [ -n "$st" ] && [ "$st" != Z ]
  else
    st=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
    case "$st" in ''|Z*) return 1 ;; esac
  fi
}
_rpool_collect() { # <pid>: wait, read the result, hand it to the lane
  local pid="$1" id res rc own
  id="${_RPOOL_PIDS[$pid]}"
  wait "$pid" 2>/dev/null; rc=$?
  unset "_RPOOL_PIDS[$pid]"
  res=$(cat "$RPOOL_DIR/$id.r" 2>/dev/null) || res=""
  [ -n "$res" ] || [ -e "$RPOOL_DIR/$id.r" ] || { res=killed; _rpool_log "worker $id ended with no result (rc=$rc)"; }
  rm -f "$RPOOL_DIR/$id.g" "$RPOOL_DIR/$id.r" 2>/dev/null
  rm -rf "$RPOOL_DIR/tmp.$id" 2>/dev/null
  [ -n "$RPOOL_LIVE_DIR" ] && rm -f "$RPOOL_LIVE_DIR/$$-$id" 2>/dev/null
  # what a SIGKILLed worker's trap could not remove; a no-op after a normal exit
  own=$(_rpool_own_tmp "$id") && rm -rf --one-file-system -- "$own" 2>/dev/null
  command -v rpool_on_result >/dev/null 2>&1 && rpool_on_result "$id" "$res"
  return 0
}
_rpool_done() { [ -e "$RPOOL_DIR/${_RPOOL_PIDS[$1]}.r" ] || ! _rpool_alive "$1"; }
rpool_reap() {
  local pid
  for pid in "${!_RPOOL_PIDS[@]}"; do _rpool_done "$pid" && _rpool_collect "$pid"; done
  return 0
}
rpool_wait_one() {
  local pid
  while [ "${#_RPOOL_PIDS[@]}" -gt 0 ]; do
    for pid in "${!_RPOOL_PIDS[@]}"; do
      _rpool_done "$pid" && { _rpool_collect "$pid"; return 0; }
    done
    _rpool_sleep
  done
  return 1
}
rpool_wait_all() { while rpool_wait_one; do :; done; }
rpool_gate_wait() { # rpool_gate_wait <id>
  local id="$1" pid p
  for p in "${!_RPOOL_PIDS[@]}"; do [ "${_RPOOL_PIDS[$p]}" = "$id" ] && pid=$p; done
  [ -n "${pid:-}" ] || return 0
  while [ ! -e "$RPOOL_DIR/$id.g" ] && _rpool_alive "$pid"; do _rpool_sleep; done
  return 0
}
rpool_finish() {
  local d pid
  # A tick that ends while a worker runs (TERM, INT) takes none of its scratch:
  # the worker removes its own when it exits (BH-6984).
  for pid in "${!_RPOOL_PIDS[@]}"; do _rpool_alive "$pid" && return 0; done
  [ -n "$RPOOL_DIR" ] && rm -rf "$RPOOL_DIR" 2>/dev/null
  if d=$(_rpool_own_tmp x); then
    for d in "${d%x}"*; do
      [ -d "$d" ] && [ ! -L "$d" ] && rm -rf --one-file-system -- "$d" 2>/dev/null
    done
  fi
  return 0
}

# --- rate limits ---------------------------------------------------------------
RPOOL_RATELIMIT_RE='(^|[^0-9])(429|529)([^0-9]|$)|rate[ _-]?limit|too many requests|overloaded|concurren(t|cy)[a-z _-]*limit|max(imum)?[ _-]*concurren'
rpool_rate_limited() { # rpool_rate_limited <out-file> — rc 0 when the call was refused for rate or concurrency
  local f="${1:-}"
  [ -n "$f" ] || return 1
  # Only an error envelope is read, never a review: an answer longer than
  # REVIEW_POOL_RATELIMIT_MAX_BYTES (4096) that merely discusses rate limits is
  # a real (billed) outcome. Under a caller's pipefail a missing .err must not
  # fail the pipe, so the text is read first.
  local txt sz
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || sz=0
  [ "${sz:-0}" -le "${REVIEW_POOL_RATELIMIT_MAX_BYTES:-4096}" ] || return 1
  txt=$(cat "$f" "$f.err" 2>/dev/null | head -c 20000) || true
  grep -Eiq "${REVIEW_POOL_RATELIMIT_RE:-$RPOOL_RATELIMIT_RE}" <<<"$txt"
}
_rpool_backoff_file() { local h="${HARNESS:-${H:-}}"; printf '%s/state/review-pool-backoff.%s' "$h" "$RPOOL_LANE"; }
RPOOL_PAUSE_LEFT=0
rpool_paused() {
  local f u c now
  f=$(_rpool_backoff_file); [ -r "$f" ] || return 1
  read -r u c < "$f" 2>/dev/null || return 1
  _rpool_int "${u:-}" || return 1
  now=$(date +%s); RPOOL_PAUSE_LEFT=$((u - now))
  [ "$RPOOL_PAUSE_LEFT" -gt 0 ]
}
rpool_rate_hit() { # a worker was rate limited: pause new starts (no-op while already paused)
  local f u c base max now
  rpool_paused && return 0
  f=$(_rpool_backoff_file); base=$(_rpool_knob RATE_BACKOFF_S 60); max=900
  u=""; c=""; [ -r "$f" ] && read -r u c < "$f" 2>/dev/null
  if _rpool_int "${c:-}"; then c=$((c * 2)); [ "$c" -gt "$max" ] && c=$max; else c=$base; fi
  now=$(date +%s)
  mkdir -p "${f%/*}" 2>/dev/null
  printf '%s %s\n' "$((now + c))" "$c" > "$f.tmp.$BASHPID" 2>/dev/null && mv -f "$f.tmp.$BASHPID" "$f" 2>/dev/null
  _rpool_log "rate limited: an agent call hit a rate or concurrency limit; new starts paused for ${c}s (backoff doubles to ${max}s on a repeat, resets on the next normal review)"
}
rpool_rate_ok() { # a review ended normally: the backoff starts again from the base
  local f; f=$(_rpool_backoff_file)
  [ -e "$f" ] || return 0
  rpool_paused && return 0
  rm -f "$f" 2>/dev/null; return 0
}
