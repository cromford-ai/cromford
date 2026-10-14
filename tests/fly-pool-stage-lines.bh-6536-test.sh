#!/bin/bash
# tests/fly-pool-stage-lines.bh-6536-test.sh — BH-6536: the pool tick says why
# a ticket held by a human step is not queued.
#
# bin/review-rescue.sh and the triage pre-check write one reason row per ticket
# in this flow, locally as state/ticket-stage/<p>.tsv (nh_sd_stage_put). The
# real bin/fly-pool.sh, driven through tests/lib/pool-reap-fixture.sh, prints
# one line per row in the window whose key has no queue file this tick:
#   P1  a recent row, no queue file: `pool project-5: TK-232 not queued :: <state>: <reason>`
#   P2  a queue file for that key: no stage line
#   P3  a row older than NH_SD_STAGE_MAX_AGE_S: no stage line
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/pool-reap-fixture.sh" || exit 1
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
prf_setup
# The stage-line lib and its sub-libs, as a box has them.
scratch_install_closure bin/lib/needs-human.sh "$H" >/dev/null || { echo "FAIL: cannot install bin/lib/needs-human.sh"; exit 1; }
SF="$H/state/ticket-stage/project-5.tsv"
REASON="fixture: @operator-w posted HUMAN-STEP-DONE at 2026-10-13T09:00:00Z; bin/review-rescue.sh checks build project-5-TK-232-1"
stage_row() { # stage_row <age-seconds> — NOW is prf_setup's one clock read
  mkdir -p "$(dirname "$SF")"
  printf 'TK-232\treview\thuman-step-done\t%s\t%s\n' "$(date -u -d "@$((NOW - $1))" '+%Y-%m-%dT%H:%M:%SZ')" "$REASON" > "$SF"
}
LINE="pool project-5: TK-232 not queued :: human-step-done: $REASON"
write_fly_stub

# ── P1: a recent row, nothing queued ──────────────────────────────────────
{
  prf_reset
  stage_row 600
  prf_run_pool
  grep -qF "$LINE" "$H/logs/fly-pool.log" && ok || bad "P1: no stage line in the pool log: $(grep -F 'pool project-5' "$H/logs/fly-pool.log")"
  [ "$(grep -cF 'TK-232 not queued' "$H/logs/fly-pool.log")" = 1 ] && ok || bad "P1: exactly one stage line per tick"
}

# ── P2: the key is queued this tick ───────────────────────────────────────
{
  prf_reset
  stage_row 600
  queue_job TK-232
  prf_run_pool
  grep -qF 'pool project-5: queued=1' "$H/logs/fly-pool.log" && ok || bad "P2: the tick never reached the queue line: $(tail -3 "$H/logs/fly-pool.log")"
  grep -qF 'TK-232 not queued' "$H/logs/fly-pool.log" && bad "P2: a queued key printed a stage line" || ok
}

# ── P3: the row is older than the window ──────────────────────────────────
{
  prf_reset
  stage_row 700000
  prf_run_pool
  grep -qF 'pool project-5: queued=0' "$H/logs/fly-pool.log" && ok || bad "P3: the tick never reached the queue line: $(tail -3 "$H/logs/fly-pool.log")"
  grep -qF 'TK-232 not queued' "$H/logs/fly-pool.log" && bad "P3: a row past NH_SD_STAGE_MAX_AGE_S printed a stage line" || ok
}

echo "fly-pool-stage-lines: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
