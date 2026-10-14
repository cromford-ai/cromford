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
#
# THE KNOBS (lane merge-conductor; defaults in PQ_KNOB_DEFAULTS below):
# MC_PREQUEUE_FRESH_COMMITS (BH-6335) is how many commits behind the current
# main a reused non-red verdict's main may be (mc-prequeue.d/dispatch.sh).
# MC_PREQUEUE_TRACE (BH-6335) 1 asks the gate to run its suites under the trace
# (mc-prequeue.d/learned.sh).

PQ_KNOB_DEFAULTS="MC_PREQUEUE_GATE=1 MC_PREQUEUE_FRESH_S=1800 MC_PREQUEUE_DEADLINE_S=2400 MC_PREQUEUE_REUSE=1 MC_BATCH_SOLO=1 MC_BATCH_SOLO_MAX_MEMBERS=13 MC_PREQUEUE_FRESH_COMMITS=3 MC_PREQUEUE_TRACE=1"

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

# pq_gate <slug> <num> <url> <head> <pbase> — see THE CONTRACT above.
pq_gate() {
  local slug="${1:-}" num="${2:-}" url="${3:-}" head="${4:-}" pbase="${5:-}" raw="" rc=0 path line st rest
  PQ_VERDICT=proceed; PQ_MAIN=""; PQ_WHY=""; PQ_SUITES=""; PQ_PATH=""
  _pq_wf=""
  [ "$(pq_knob MC_PREQUEUE_GATE)" = 0 ] && { declare -F pq_status_gate >/dev/null && pq_status_gate "$slug" "$head" "$url" off; echo proceed; return 0; }
  # An unreadable tip holds, a quota refusal (rc 75) included: never a guess at main.
  [ -n "$pbase" ] && { mc_rest_var raw gh_rest GET "repos/$slug/commits/$pbase" || rc=$?; }
  [ "$rc" = 0 ] && PQ_MAIN=$(jq -r '.sha // empty' <<<"$raw" 2>/dev/null)
  if [ "$rc" != 0 ] || [[ ! "$PQ_MAIN" =~ ^[0-9a-f]{40}$ ]]; then
    PQ_MAIN=""; PQ_WHY="main tip unreadable, asked next tick"; PQ_VERDICT=hold; echo hold; return 0
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
          pq_resolve "$slug" "$num" "$url" "$head" "$PQ_MAIN" "$path" > "$t" 2>/dev/null
          line=$(tail -n1 "$t" 2>/dev/null); rm -f "$t"
        fi
        case "$line" in
          hold) PQ_VERDICT=hold ;;
          red) [ -n "$PQ_SUITES" ] && PQ_VERDICT=red ;;
          rebase) PQ_VERDICT=rebase ;;
          defer) PQ_VERDICT=defer ;;
        esac
      fi ;;
  esac
  declare -F pq_status_gate >/dev/null && pq_status_gate "$slug" "$head" "$url"
  echo "$PQ_VERDICT"
}

for _pq_f in "$(dirname "${BASH_SOURCE[0]}")"/mc-prequeue.d/*.sh; do [ -r "$_pq_f" ] && . "$_pq_f"; done
unset _pq_f
