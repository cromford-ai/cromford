# shellcheck shell=bash
# bin/merge-conductor.d/bh-8706-queue-paused.sh - A PR THAT LEFT THE MERGE
# QUEUE PAUSED BY THE MAIN-RED BREAKER IS NOT AN EJECTION (BH-8706). Sourced
# by bin/merge-conductor.sh (the BH-7453 fragment block); no side effect at
# source time.
#
# mc_queue_left_paused <key> <head> [slug [red-flag]] — the queue-left
# `paused)` arm calls it with the tick's $MAIN_RED (the flag name in force, or
# empty when main is green). It writes one `qpaused <key> <head>` attempt mark and one log line per
# head. It counts no strike and does not move the row. Always rc 0.
#   STRANDED (BH-8706 review): the pause label on a repo with NO main-red flag
#   means nothing will take it off (the breaker lane is off, or its row was
#   lost). The first green sighting writes `qpausedgreen`; the second (one
#   tick later, so a normal resume has had its tick) sends ONE warn per head.
mc_queue_left_paused() {
  local key="$1" head="$2" slug="${3:-}" red="${4:-}"
  if ! mc_attempt_has "qpaused $key $head" 2>/dev/null; then
    mc_attempt_put "qpaused $key $head"
    mc_log "$key left the merge queue PAUSED by the main-red breaker on ${head:0:8} — not an ejection, no strike (BH-8706)"
  fi
  [ -n "$slug" ] || return 0
  [ -n "$red" ] && return 0
  if ! mc_attempt_has "qpausedgreen $key $head" 2>/dev/null; then
    mc_attempt_put "qpausedgreen $key $head"; return 0
  fi
  mc_attempt_has "qpausedwarn $key $head" 2>/dev/null && return 0
  mc_attempt_put "qpausedwarn $key $head"
  mc_alert "$key" QUEUED "carries ${MAIN_RED_BREAKER_PAUSE_LABEL:-merge-queue-paused} on ${head:0:8} but main on $slug is green — nothing resumes it. Check bin/main-red-breaker.sh (lane on? logs/main-red-breaker.log), or remove the label and post \`@mergifyio requeue\` (BH-8706)"
  return 0
}

# mc_queue_left_resumed <key> <head> — rc 0: hold this tick, not an ejection.
#   bin/main-red-breaker.sh removed the pause label and asked Mergify to take
#   the PR back. Mergify answers in ~40-60 s; a conductor read in that window
#   sees an OPEN PR with no queue witness. A `qpaused` mark on this head (the
#   conductor's own, or the breaker's before its requeue) buys ONE tick of
#   grace (`qresumed` mark). A second sighting counts as usual.
mc_queue_left_resumed() {
  mc_attempt_has "qpaused $1 $2" 2>/dev/null || return 1
  mc_attempt_has "qresumed $1 $2" 2>/dev/null && return 1
  mc_attempt_put "qresumed $1 $2"
  mc_log "$1 left the merge queue on ${2:0:8} after a main-red pause — held one tick while Mergify takes it back, no ejection counted (BH-8706)"
  return 0
}
