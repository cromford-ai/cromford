#!/bin/bash
# bin/lib/mc-prequeue.d/learned.sh — THE HUB CARRIES THE LEARNED SUITES AND THE
# TRACE SWITCH TO THE PRE-QUEUE GATE (BH-6335). Sourced by
# bin/lib/mc-prequeue.sh's hook loop, never executed; no side effect at source time.
#
# pq_learned_args prints up to four gh argv words, or nothing:
#   -f learned=<list>  the suites that failed merge-queue batches lately, from
#                      bin/prequeue-learned.sh --list --harness $MC_H, when that
#                      exits 0 and prints the strict comma list of tests/*.sh
#   -f trace=1         when the MC_PREQUEUE_TRACE knob is 1 and MC_H carries
#                      bin/test-trace-safety.sh
# pq_dispatch calls it only when suites is empty and word-splits the output into
# the gh argv. No MC_H, no script, a failure, or a malformed list: that pair is
# not printed, so the dispatch goes out exactly as before.
pq_learned_args() {
  local s v
  [ -n "${MC_H:-}" ] || return 0
  s="$MC_H/bin/prequeue-learned.sh"
  if [ -r "$s" ] && v=$(bash "$s" --list --harness "$MC_H" 2>/dev/null) \
     && [[ $v =~ ^tests/(mc/)?[A-Za-z0-9._-]+\.sh(,tests/(mc/)?[A-Za-z0-9._-]+\.sh)*$ ]]; then
    printf '%s %s\n' -f "learned=$v"
  fi
  [ "$(pq_knob MC_PREQUEUE_TRACE)" = 1 ] && [ -r "$MC_H/bin/test-trace-safety.sh" ] && printf '%s %s\n' -f trace=1
  return 0
}
