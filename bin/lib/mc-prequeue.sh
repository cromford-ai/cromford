#!/bin/bash
# bin/lib/mc-prequeue.sh — THE PRE-QUEUE ISOLATION GATE (BH-4545, slice BH-4547).
# Sourced by bin/merge-conductor.sh, never executed.
#
# THE CONTRACT. Before a READY head is marked ready or enqueued, the conductor
# asks pq_gate. It answers one word, sets PQ_VERDICT to it, and sets PQ_MAIN,
# PQ_WHY and PQ_SUITES:
#   proceed  enqueue as before (gate off, a non-red verdict, or no verdict)
#   hold     leave the row READY this tick; PQ_WHY says why (main tip unreadable)
#   red      park the row prequeue-red; PQ_SUITES names at least one suite
#   rebase   a reused green whose head conflicts with current main (BH-5572);
#            PQ_WHY names the paths, the row goes to NEEDS_REBASE
#   defer    not dispatched: a later READY check refuses this head this tick
#            (BH-5572); PQ_WHY names it, and the caller must not enqueue
# Every proceed/red answer publishes prequeue-verdict through
# mc-prequeue.d/status.sh (BH-5441); hold, rebase and defer publish nothing.
#
# THE STORE. One file per (PR, head, main tip), one line each:
#   $MC_STATE_DIR/prequeue/<owner_repo>_<num>_<head>_<main>[_<fp>]
#   <state> <dispatched_at> <run_id|-> [alerted] <suites, comma-joined>
# state is green|no-selection|conflict|could-not-run|pending|red. Any other word
# proceeds, and so does a red that names no suite: nothing parks unnamed.
#
# THE HOOKS. Nothing in this file writes a verdict. Siblings drop a file into
# bin/lib/mc-prequeue.d/ that defines pq_resolve <slug> <num> <url> <head>
# <main> <path>; on a miss or a pending entry the gate asks it. Without one, a
# miss proceeds, which is the conductor's behaviour before this gate existed.
# Two hooks run before the cache read and can hold a head: pq_restamp
# (mc-prequeue.d/restamp.sh, BH-6842) and pq_mignum
# (mc-prequeue.d/migration-numbers.sh, BH-7671), which renumbers a head's added
# migration whose number main or a queued PR took, pushes, and holds.
#
# THE KNOBS (lane merge-conductor; defaults in PQ_KNOB_DEFAULTS below):
# MC_PREQUEUE_GATE is the gate itself. No seed row ships for
# lane.merge-conductor.mc_prequeue_gate (BH-8062, option 1): the code fallback 1
# keeps the CI pre-queue gate on beside the builder's selection gate
# (bin/selection-gate.sh). An operator sets the row to 0 per
# docs/notes/2026-10-24-BH-8062-builder-selection-gate.md; rollback: the row to 1.
# 0 skips only the verdict (cache read, pq_resolve, dispatch). When pq_restamp or
# pq_mignum can act (pq_restamp_wanted / pq_mignum_wanted, no network), the
# main-tip read and both hooks still run, so an unreadable tip still holds.
# MC_PREQUEUE_FRESH_COMMITS (BH-6335) is how many commits behind the current
# main a reused non-red verdict's main may be (mc-prequeue.d/dispatch.sh).
# MC_PREQUEUE_TRACE (BH-6335) 1 asks the gate to run its suites under the trace
# (mc-prequeue.d/learned.sh).
# MC_PREQUEUE_IMPACT_REUSE (BH-6924) 1 reuses an older main's green verdict when
# the main move misses the PR's impact set; MC_PREQUEUE_IMPACT_MAX_S bounds the
# age of that verdict (mc-prequeue.d/impact-reuse.sh).
#
# THE CALL BUDGET (BH-7029, knob MC_PREQUEUE_CALL_BUDGET_S, default 150, 0 =
# off). Each call of the gate (main-tip, restamp, resolve and the resolver's
# own calls, status) runs through pq_call (mc-prequeue.d/call-bound.sh): one
# PREQUEUE_CALL timing line each. The gate's calls share one budget, never
# above 3/4 of MC_STEP_TIMEOUT_S nor past MC_WORKER_DEADLINE_AT minus 15 s.
# When it passes, a read in flight is killed, no later call starts, and the
# answer is hold with PQ_WHY and one PREQUEUE_CALL_TIMEOUT line naming the call:
# the row stays READY, the next tick asks again, and nothing the gate learned
# past the budget counts. A budget under 1 s holds at once, with no call.
#
# THE GIT LOCK WAIT (BH-7376, knob MC_PREQUEUE_GIT_LOCK_WAIT_S, default 5). The
# gate never sits on the project's git lock: pq_restamp (a write, so the call
# budget never cuts it) and pq_merge_test waited MC_GIT_LOCK_WAIT (180 s) for a
# lock rebase workers hold, and a keyed READY run's prequeue step took up to
# 265 s (hub, 2026-10-17/18) until `timeout` killed the run before enqueue.
# A busy lock is a hold (restamp) or no answer (merge test), and the next run
# asks again. A dispatch never waits for its run: pq_dispatch writes `pending`
# for (PR, head, main) and the gate holds; a later run reads the verdict.

PQ_KNOB_DEFAULTS="MC_PREQUEUE_GATE=1 MC_PREQUEUE_FRESH_S=1800 MC_PREQUEUE_DEADLINE_S=2400 MC_PREQUEUE_REUSE=1 MC_BATCH_SOLO=1 MC_BATCH_SOLO_MAX_MEMBERS=13 MC_PREQUEUE_FRESH_COMMITS=3 MC_PREQUEUE_TRACE=1 MC_PREQUEUE_IMPACT_REUSE=1 MC_PREQUEUE_IMPACT_MAX_S=21600 MC_PREQUEUE_CALL_BUDGET_S=150 MC_PREQUEUE_GIT_LOCK_WAIT_S=5"

# pq_knob <NAME> — a merge-conductor lane knob for this project, a non-negative
#   integer, else its default from PQ_KNOB_DEFAULTS (the _bej_knob pattern).
pq_knob() {
  local n="${1:-}" d="" kv v
  for kv in $PQ_KNOB_DEFAULTS; do [ "${kv%%=*}" = "$n" ] && d="${kv#*=}"; done
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$n" "${P:-}" 2>/dev/null)
  else v="${!n:-}"; fi
  case "$v" in ''|*[!0-9]*) v="$d" ;; esac
  printf '%s' "$v"
}

# pq_key <slug> <num> <head> <main> [fp] -> the cache path for that key.
pq_key() { printf '%s/prequeue/%s_%s_%s_%s%s' "${MC_STATE_DIR:-}" "${1//\//_}" "$2" "$3" "$4" "${5:+_$5}"; }

# pq_cache_get <path> -> the entry's one line, or nothing.
pq_cache_get() { [ -r "${1:-}" ] && head -n1 "$1" 2>/dev/null; return 0; }

# pq_cache_put <path> <state> <dispatched_at> <run_id> <suites> [alerted]
#   One atomic write (tmp + mv). rc != 0 when it could not be written.
pq_cache_put() {
  local f="${1:-}" t
  [ -n "$f" ] && [ -n "${2:-}" ] || return 1
  t="$f.tmp.$$"
  mkdir -p "${f%/*}" 2>/dev/null \
    && printf '%s %s %s%s %s\n' "$2" "${3:--}" "${4:--}" "${6:+ alerted}" "${5:-}" > "$t" 2>/dev/null \
    && mv -f "$t" "$f" 2>/dev/null || { rm -f "$t" 2>/dev/null; return 1; }
}

# _pq_budget_s — the gate's effective call budget in seconds (THE CALL BUDGET):
#   the knob, capped by the step timeout and the worker deadline. 0 = off; a
#   value under 1 with the knob on is printed as is (the caller holds at once).
_pq_budget_s() {
  local b st now
  b=$(pq_knob MC_PREQUEUE_CALL_BUDGET_S)
  [ "$b" = 0 ] && { echo 0; return 0; }
  st=${MC_STEP_TIMEOUT_S:-240}; [[ "$st" =~ ^[0-9]+$ ]] || st=240
  [ "$st" -gt 0 ] && [ $((st * 3 / 4)) -lt "$b" ] && b=$((st * 3 / 4))
  if [[ "${MC_WORKER_DEADLINE_AT:-}" =~ ^[0-9]+$ ]]; then
    printf -v now '%(%s)T' -1
    [ $((MC_WORKER_DEADLINE_AT - now - 15)) -lt "$b" ] && b=$((MC_WORKER_DEADLINE_AT - now - 15))
  fi
  [ "$b" -ge 1 ] || b=-1
  echo "$b"
}

# _pq_end <verdict> — every answer after the budget started goes out here: the
# timer stops, PQ_VERDICT is set and the word is printed.
_pq_end() { _pq_budget_stop; PQ_VERDICT="$1"; echo "$1"; }

# _pq_over_hold <head> <budget> — the budget passed: one PREQUEUE_CALL_TIMEOUT
#   line naming the call that ran when it passed, and the hold.
_pq_over_hold() {
  local c=""
  { read -r c < "$_pq_cf.over"; } 2>/dev/null
  c="${c:-between-calls}"
  PQ_WHY="prequeue call $c ran past ${2}s; parked this tick, asked next tick"
  mc_log "$_pq_key PREQUEUE_CALL_TIMEOUT call=$c budget=${2}s head=${1:0:8}" 2>/dev/null
  _pq_end hold
}

# pq_gate <slug> <num> <url> <head> <pbase> — see THE CONTRACT above.
pq_gate() {
  local slug="${1:-}" num="${2:-}" url="${3:-}" head="${4:-}" pbase="${5:-}" raw="" rc=0 path line st rest b
  # THE GIT LOCK WAIT (BH-7376): every mc_git_locked call under this gate
  # (pq_restamp, pq_merge_test) waits at most this long for the project's git
  # lock; a busy lock answers hold or no-answer, as it always did. Local, so it
  # ends with the gate.
  local MC_GIT_LOCK_WAIT; MC_GIT_LOCK_WAIT=$(pq_knob MC_PREQUEUE_GIT_LOCK_WAIT_S)
  PQ_VERDICT=proceed; PQ_MAIN=""; PQ_WHY=""; PQ_SUITES=""; PQ_PATH=""
  _pq_wf=""; _pq_key="$slug#$num"; _pq_cs=(); _pq_cl=()
  # THE GATE OFF (BH-8062). MC_PREQUEUE_GATE=0 turns off only the verdict: the
  # cache read and the prequeue-gate.yml dispatch. pq_restamp and pq_mignum
  # below still run when either one can act (its cheap *_wanted check, no
  # network), because a stale stamp or a taken number turns main red after the
  # merge whatever the gate says. When neither can act, no main tip is read.
  local off=0
  if [ "$(pq_knob MC_PREQUEUE_GATE)" = 0 ]; then
    off=1
    if ! { declare -F pq_restamp >/dev/null && { ! declare -F pq_restamp_wanted >/dev/null || pq_restamp_wanted "$slug"; }; } \
       && ! { declare -F pq_mignum >/dev/null && pq_mignum_wanted; }; then
      declare -F pq_status_gate >/dev/null && pq_call -w status pq_status_gate "$slug" "$head" "$url" off; echo proceed; return 0
    fi
  fi
  b=$(_pq_budget_s)
  if [ "$b" = -1 ]; then
    PQ_WHY="no prequeue time left in this worker (worker deadline or step timeout too near); asked next tick"
    mc_log "$_pq_key PREQUEUE_CALL_TIMEOUT call=none budget=0s head=${head:0:8}" 2>/dev/null
    PQ_VERDICT=hold; echo hold; return 0
  fi
  [ "$b" != 0 ] && _pq_budget_start "$b"
  # An unreadable tip holds, a quota refusal (rc 75) included: never a guess at main.
  [ -n "$pbase" ] && { pq_call main-tip mc_rest_var raw gh_rest GET "repos/$slug/commits/$pbase" || rc=$?; }
  pq_over && { _pq_over_hold "$head" "$b"; return 0; }
  [ "$rc" = 0 ] && PQ_MAIN=$(jq -r '.sha // empty' <<<"$raw" 2>/dev/null)
  if [ "$rc" != 0 ] || [[ ! "$PQ_MAIN" =~ ^[0-9a-f]{40}$ ]]; then
    PQ_MAIN=""; PQ_WHY="main tip unreadable, asked next tick"; _pq_end hold; return 0
  fi
  # BH-6842: a stale schema stamp is restamped before the queue (mc-prequeue.d/
  # restamp.sh). A push or a refusal holds this tick and publishes nothing.
  local rs="" rw rn
  declare -F pq_restamp >/dev/null && rs=$(pq_call -w restamp pq_restamp "$slug" "$num" "$head" "$PQ_MAIN" 2>/dev/null | tail -n 1)
  case "$rs" in
    "pushed "*) read -r _ rw rn <<<"$rs"
      PQ_WHY="restamped ${rn:-?} schema fragment(s) to ${rw:0:12}; the new head is asked next tick"; _pq_end hold; return 0 ;;
    "held "*) PQ_WHY="schema restamp held: ${rs#held }"; _pq_end hold; return 0 ;;
  esac
  # BH-7671: a head whose added migration number main or a queued PR took is
  # renumbered before the queue (mc-prequeue.d/migration-numbers.sh). A push or
  # a refusal holds; the pushed head has no approval and is re-reviewed.
  local mn="" mnw mnn
  declare -F pq_mignum >/dev/null && pq_mignum_wanted && mn=$(pq_call -w mignum pq_mignum "$slug" "$num" "$url" "$head" "$PQ_MAIN" 2>/dev/null | tail -n 1)
  case "$mn" in
    "pushed "*) read -r _ mnw mnn <<<"$mn"
      PQ_WHY="renumbered ${mnn:-?} migration(s) to ${mnw:0:12}; the new head is re-reviewed before it queues"; _pq_end hold; return 0 ;;
    "held "*) PQ_WHY="migration number check held: ${mn#held }"; _pq_end hold; return 0 ;;
  esac
  pq_over && { _pq_over_hold "$head" "$b"; return 0; }
  # The gate off (BH-8062, above): the hooks ran and neither held.
  if [ "$off" = 1 ]; then
    _pq_budget_stop; PQ_VERDICT=proceed
    declare -F pq_status_gate >/dev/null && pq_call -w status pq_status_gate "$slug" "$head" "$url" off
    echo proceed; return 0
  fi
  path=$(pq_key "$slug" "$num" "$head" "$PQ_MAIN")
  export PQ_PATH="$path"
  line=$(pq_cache_get "$path")
  read -r st _ _ rest <<<"$line"
  case "$st" in
    red)
      rest="${rest#alerted}"; rest=$(tr -s ' ' ',' <<<"${rest# }"); PQ_SUITES="${rest%,}"
      [ -n "$PQ_SUITES" ] && PQ_VERDICT=red ;;
    ''|pending)
      if declare -F pq_resolve >/dev/null; then
        # The hook runs ONCE, in this shell, so the PQ_* it sets survive; its
        # word comes back through a file. Only an exact word passes, and a red
        # must still name a suite.
        local t; line=""
        if t=$(mktemp "${TMPDIR:-/tmp}/mc-pq.XXXXXX" 2>/dev/null); then
          pq_call resolve pq_resolve "$slug" "$num" "$url" "$head" "$PQ_MAIN" "$path" > "$t" 2>/dev/null
          line=$(tail -n1 "$t" 2>/dev/null); rm -f "$t"
        fi
        # A word the hook reached after the budget passed does not count.
        pq_over && { _pq_over_hold "$head" "$b"; return 0; }
        case "$line" in
          hold) PQ_VERDICT=hold ;;
          red) [ -n "$PQ_SUITES" ] && PQ_VERDICT=red ;;
          rebase) PQ_VERDICT=rebase ;;
          defer) PQ_VERDICT=defer ;;
        esac
      fi ;;
  esac
  # The verdict was reached inside the budget: a slow status write does not
  # undo it. A status the budget refused to start is a hold, never a verdict
  # with no status behind it.
  if declare -F pq_status_gate >/dev/null; then
    pq_call -w status pq_status_gate "$slug" "$head" "$url"
    [ "$?" = 124 ] && pq_over && { _pq_over_hold "$head" "$b"; return 0; }
  fi
  _pq_end "$PQ_VERDICT"
}

# The call-budget defaults when mc-prequeue.d/call-bound.sh is not installed
# (a scratch tree that copies only some hooks): each call runs untimed in this
# shell, the budget never passes, and the gate acts as it did before BH-7029.
# call-bound.sh is sourced after these lines and replaces all four.
pq_call() { [ "${1:-}" = -w ] && shift; shift; "$@"; }
pq_over() { return 1; }
_pq_budget_start() { return 0; }
_pq_budget_stop() { return 0; }

for _pq_f in "$(dirname "${BASH_SOURCE[0]}")"/mc-prequeue.d/*.sh; do [ -r "$_pq_f" ] && . "$_pq_f"; done
unset _pq_f
