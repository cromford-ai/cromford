#!/bin/bash
# gh-identity: app-token
# bin/lib/mc-prequeue.d/hotfix-skip.sh — A FIX-MAIN-RED HEAD SKIPS THE
# PRE-QUEUE VERDICT (BH-8769). Sourced by bin/lib/mc-prequeue.sh's hook loop,
# never executed; no side effect at source time.
#
# WHY. A PR labelled MC_MAIN_RED_LABEL (default fix-main-red) routes to the
# Mergify hotfix queue (.mergify.yml), which runs it in a batch of 1 on main.
# That run is the test. A prequeue-gate.yml run in front of it only delays the
# fix while main is red.
#
# THE RULE (no knob: the hotfix queue is the test). pq_gate asks
# pq_hotfix_skip before its gate-off check. rc 0 when MC_MAIN_RED_LABEL is set,
# PROVIDER is mergify, and the READY row's labels (RAWLBL, the csv pr_worker in
# bin/merge-conductor.sh holds in its dynamic scope, as mc-stale-dequeue.sh and
# mc/rebase.sh read it) hold the label csv-exact and case-sensitive, the
# main_red_exempt match. Then pq_gate takes the BH-8062 gate-off path: no cache
# read, no pq_resolve, no dispatch, no group join, and no BH-8801 fallback.
# pq_restamp, pq_mignum and pq_fastlint still run when they can act, and their
# hold or red still wins. The proceed publishes prequeue-verdict success with
# PQ_OFF_WHY. The eject requeue (ec_requeue_gate in the call stack) never
# skips: an ejected hotfix gets the verdict like any head.
# One `PREQUEUE_SKIPPED` log line per (PR, head), deduped through the attempt
# ledger (`pqskip <slug>#<num> <head>`). No GitHub call.
#
#   pq_hotfix_skip <slug> <num> <head>

pq_hotfix_skip() {
  local slug="${1:-}" num="${2:-}" head="${3:-}"
  [ -n "${MC_MAIN_RED_LABEL:-}" ] && [ "${PROVIDER:-}" = mergify ] || return 1
  case " ${FUNCNAME[*]} " in *" ec_requeue_gate "*) return 1 ;; esac
  case ",${RAWLBL:-}," in *",$MC_MAIN_RED_LABEL,"*) ;; *) return 1 ;; esac
  PQ_OFF_WHY="skipped ($MC_MAIN_RED_LABEL: the hotfix queue runs this head alone)"
  if ! mc_attempt_has "pqskip $slug#$num $head" 2>/dev/null; then
    mc_attempt_put "pqskip $slug#$num $head" 2>/dev/null
    mc_log "$slug#$num PREQUEUE_SKIPPED head=${head:0:12} reason=$PQ_OFF_WHY" 2>/dev/null
  fi
  return 0
}
