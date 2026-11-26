#!/bin/bash
# bin/ci-verdicts.sh <pure|trace> <verdict-dir> <n> <count> — one fan-in
# check's judgement over the traced shards' verdict files (CI cost cut,
# 2026-09-24).
#
# The corpus runs ONCE per CI run, under bin/test-trace-safety.sh --gate, and
# every shard writes <verdict-dir>/shard-<i>.txt with both verdicts
# (tests=, failed=, hits=, pure=pass|fail, trace=clean|dirty). The two required
# checks each read their own column:
#
#   pure    `Pure-logic gate fixtures`          — every selected test passed
#   trace   `Tests cannot touch a real harness` — no test deleted or redirected
#                                                 outside a temp root
#
# So a failing test never turns the safety check red, and a hit never turns
# the pure-logic check red — each check keeps the meaning Mergify, the merge
# conductor and the main-red detector already read into its name.
#
# RED FOR BOTH, whichever lane is asked, when the evidence is not there:
#   - PLAN_RESULT (needs.plan.result) is not `success`;
#   - any shard 0..n-1 has no verdict file, or one that does not parse — a
#     shard whose infra step died, that was cancelled, or whose scan was rc 2;
#   - a shard reports tests=0, or the shards' tests= do not add up to <count>,
#     the number the plan selected: a split that dropped suites reads exactly
#     like a fast green, so it is refused by arithmetic.
#
# THE SHARD BUDGET (BH-9465). A shard that spends TRACE_SAFETY_SHARD_BUDGET_S
# stops starting tests and still writes its verdict, with three more keys:
# notrun=<k>, timeout_names=<a,b>, notrun_names=<c,d>. A verdict without them
# (an older gate) reads as notrun=0 and no names. The count is tests + notrun,
# so a budget stop names its tests instead of reading as a dropped split.
#   pure   a red shard names its timed-out and not-run tests;
#   trace  notrun > 0 is red: those tests were never traced. A timeout with no
#          hit is a ::warning:: only: its trace was scanned up to the kill.
#
# rc 0 pass, 1 red, 2 usage.
set -uo pipefail
LANE="${1:-}"; VDIR="${2:-}"; N="${3:-}"; COUNT="${4:-}"
case "$LANE" in pure|trace) ;; *) echo "ci-verdicts: lane must be pure or trace, got '$LANE'" >&2; exit 2 ;; esac
case "$N" in ''|*[!0-9]*) echo "ci-verdicts: shard count must be a whole number, got '$N'" >&2; exit 2 ;; esac
case "$COUNT" in ''|*[!0-9]*) echo "ci-verdicts: suite count must be a whole number, got '$COUNT'" >&2; exit 2 ;; esac

RED=0
red() { echo "::error::$*"; RED=1; }

[ "${PLAN_RESULT:-}" = success ] || red "the CI plan job did not succeed (${PLAN_RESULT:-no result}) — nothing this lane could judge ran"
[ "$N" -ge 1 ] || red "the plan published $N shards — a run that tests nothing is not a pass"

SUM=0; BAD_SHARDS=""
for ((i = 0; i < N; i++)); do
  F="$VDIR/shard-$i.txt"
  if [ ! -r "$F" ]; then
    red "shard $i/$N left no verdict — its job died before the scan finished, was cancelled, or its scan could not be trusted (rc 2). Open 'Tests, traced (shard $i/$N)'."
    continue
  fi
  get() { sed -n "s/^$1=//p" "$F" | head -1; }
  TESTS=$(get tests); FAILED=$(get failed); HITS=$(get hits); P=$(get pure); TR=$(get trace)
  NOTRUN=0; grep -q '^notrun=' "$F" && NOTRUN=$(get notrun)
  TO_NAMES=$(get timeout_names); NR_NAMES=$(get notrun_names)
  case "$TESTS$FAILED$HITS" in ''|*[!0-9]*)
    red "shard $i/$N: the verdict does not parse ($(tr '\n' ' ' < "$F"))"; continue ;; esac
  case "$P/$TR" in pass/clean|pass/dirty|fail/clean|fail/dirty) ;; *)
    red "shard $i/$N: the verdict does not parse ($(tr '\n' ' ' < "$F"))"; continue ;; esac
  case "$NOTRUN" in ''|*[!0-9]*)
    red "shard $i/$N: the verdict does not parse ($(tr '\n' ' ' < "$F"))"; continue ;; esac
  [ $((TESTS + NOTRUN)) -gt 0 ] || { red "shard $i/$N ran 0 tests"; continue; }
  # tests + notrun is the shard's share of the plan's count. A shard with a
  # not-run test is red in both lanes, so the count check below never fires on
  # it; the sum keeps a budget stop from also reading as a dropped split.
  SUM=$((SUM + TESTS + NOTRUN))
  # A not-run test is never a pure green, even on a verdict that says pass.
  if [ "$LANE" = pure ] && { [ "$P" != pass ] || [ "$NOTRUN" -gt 0 ]; }; then
    BAD_SHARDS="$BAD_SHARDS $i"
    MSG="shard $i/$N: $FAILED of $TESTS tests failed"
    [ "$NOTRUN" -eq 0 ] || MSG="$MSG, $NOTRUN not run"
    [ -z "$TO_NAMES" ] || MSG="$MSG; timed out: $TO_NAMES"
    [ -z "$NR_NAMES" ] || MSG="$MSG; not run (shard budget): $NR_NAMES"
    red "$MSG. Open 'Tests, traced (shard $i/$N)' — each failing test's output follows its '--- <test> rc=' line."
  fi
  if [ "$LANE" = trace ] && [ "$TR" != clean ]; then
    BAD_SHARDS="$BAD_SHARDS $i"
    red "shard $i/$N: $HITS trace hit(s) — a test deleted or redirected outside a temp root. Open 'Tests, traced (shard $i/$N)' and read its HIT lines."
  fi
  if [ "$LANE" = trace ] && [ "$NOTRUN" -gt 0 ]; then
    BAD_SHARDS="$BAD_SHARDS $i"
    red "shard $i/$N: ${NR_NAMES:-$NOTRUN test(s)} did not run, so they were not traced (the shard budget was spent). Open 'Tests, traced (shard $i/$N)' and read its NOTRUN and TIMEOUT lines."
  fi
  if [ "$LANE" = trace ] && [ -n "$TO_NAMES" ] && [ "$TR" = clean ]; then
    echo "::warning::shard $i/$N: $TO_NAMES timed out; their traces were scanned up to the kill"
  fi
done
unset -f get 2>/dev/null

if [ "$RED" = 0 ] && [ "$SUM" -ne "$COUNT" ]; then
  red "the shards ran $SUM suites but the plan selected $COUNT — a split that drops suites is not a green"
fi

if [ "$RED" = 0 ]; then
  case "$LANE" in
    pure)  echo "pure-logic: all $N shard(s) passed — $SUM suites ran, none failed" ;;
    trace) echo "trace-safety: all $N shard(s) clean — $SUM suites traced, no hit" ;;
  esac
  exit 0
fi
exit 1
