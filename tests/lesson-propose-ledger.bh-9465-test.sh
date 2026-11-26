#!/bin/bash
# tests/lesson-propose-ledger.bh-9465-test.sh — BH-5807: bin/lesson-propose.sh,
# sections L19 (the 4000-char ledger detail), K (knobs), T (triggers unreadable)
# and the worker's own node suite.
# Drives the SHIPPED bin/lesson-propose.sh against the REAL worker routes
# (worker/jobs/src/routes/lesson-propose.js, ledger.js and model-routes.js)
# over a node:sqlite file built from the REAL jobs schema. The shared setup and
# the stubs are tests/lib/lesson-propose-fixture.bh-9465.sh; the other
# sections are in tests/lesson-propose.bh-5807-test.sh and its sibling parts.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lesson-propose-ledger.bh-9465-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
LP_NAME=lesson-propose-ledger
. "$(dirname "$0")/lib/lesson-propose-fixture.bh-9465.sh" || exit 1
# The node suite below loads worker/jobs/src/index.js (BH-6452, BH-6540).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1

LANE="$DIR/bin/lesson-propose.sh"
ROUTE="$DIR/worker/jobs/src/routes/lesson-propose.js"
FRAG="$DIR/worker/jobs/schema.d/202610160504-bh-5807-lesson-propose.sql"
CRON="$DIR/cron/lanes/733-lesson-propose.cron"
lp_setup

# ═════ L19: the ledger detail stays under the 4000 chars the worker keeps ═════
# PUT /api/ledger cuts a detail at 4000 chars, and a cut detail is no JSON.
# bulk <category> <first-id> <count> <days>: count BLOCK verdicts, one finding
# each, in two statements (one node call each, not 2*count). The verdicts
# spread over 5 PRs (pr = i % 5 + 1): the triggers count DISTINCT verdicts, and
# the lane looks up each PR's judged mode on the hub twice, so one PR per
# verdict cost 400-1400 lookups a tick that no L19 check reads.
bulk() {
  local sha; sha=$(printf 'b%.0s' $(seq 40))
  q "WITH RECURSIVE c(i) AS (SELECT CAST(?1 AS INTEGER) UNION ALL SELECT i + 1 FROM c WHERE i < ?1 + ?2 - 1)
     INSERT INTO verdicts (id, repo, pr, head_sha, verdict, source, reviewer, report_url, note, created_at)
     SELECT i, '$R', i % 5 + 1, '$sha', 'BLOCK', 'lead', 'mac-lead', 'https://github.com/$R/pull/' || (i % 5 + 1) || '#lr', 'n', ?3 FROM c" \
    "$2" "$3" "$(iso_ago "$4")" >/dev/null
  q "WITH RECURSIVE c(i) AS (SELECT CAST(?1 AS INTEGER) UNION ALL SELECT i + 1 FROM c WHERE i < ?1 + ?2 - 1)
     INSERT INTO block_findings (verdict_id, n, repo, pr, ticket, head_sha, source, category, raw_category, confidence, cause, files, infra_false, text, model, verdict_at, created_at)
     SELECT i, 1, '$R', i % 5 + 1, 'BH-9001', '$sha', 'lead', ?4, '', 0.8, 'cause of ' || i, '[\"bin/x.sh\"]', 0, '- [BLOCK] bin/x.sh: finding of verdict ' || i, 'm', ?3, ?3 FROM c" \
    "$2" "$3" "$(iso_ago "$4")" "$1" >/dev/null
}
age() { q "UPDATE block_findings SET verdict_at=?3 WHERE verdict_id BETWEEN ?1 AND ?2" "$1" "$2" "$(iso_ago 20)" >/dev/null; }
seen_n() { led "$1" | jq -r '.detail | fromjson | .seen | length'; }
# L19a: 400 verdict ids over two ticks. `seen` keeps the window, not every id.
reset
bulk test-cannot-fail 200001 200 5
printf '\n' > "$T/answer"
run
eq "L19a tick 1: one call" "$(calls)" 1
eq "L19a tick 1: seen holds the 200 window ids" "$(seen_n test-cannot-fail)" 200
age 200001 200200
bulk test-cannot-fail 200201 200 2
run
eq "L19a tick 2: 200 new ids, one more call" "$(calls)" 2
eq "L19a tick 2: seen holds the 200 window ids, not 400" "$(seen_n test-cannot-fail)" 200
check "L19a tick 2: seen is the new window" '[ "$(led test-cannot-fail | jq -r ".detail | fromjson | .seen | min")" = 200201 ]'
run
eq "L19a tick 3: same evidence, no call" "$(calls)" 2
# L19b: a window too large for the ledger. 700 six-digit ids are about 4900
# chars of `seen`: the row stores seen_max, parses, and still dedups.
reset
bulk test-cannot-fail 300001 700 5
printf '\n' > "$T/answer"
run
eq "L19b one call" "$(calls)" 1
eq "L19b empty" "$(led_st test-cannot-fail)" empty
check "L19b the detail is JSON, at most 4000 chars" 'led test-cannot-fail | jq -e ".detail | (fromjson | type == \"object\") and length <= 4000" >/dev/null'
eq "L19b seen_max is the largest id" "$(led_d test-cannot-fail seen_max)" 300700
eq "L19b no seen list" "$(led_d test-cannot-fail seen)" null
check "L19b one log line names seen_max" '[ "$(grep -c "seen (700 ids) is stored as seen_max" "$H/logs/lesson-propose.log")" = 1 ]'
age 300001 300010
run
eq "L19b 10 ids aged out (new fp, no new id): no call" "$(calls)" 1
eq "L19b still empty" "$(led_st test-cannot-fail)" empty
finding test-cannot-fail
q "UPDATE verdicts SET id=400001 WHERE id=?" "$FID" >/dev/null
q "UPDATE block_findings SET verdict_id=400001 WHERE verdict_id=?" "$FID" >/dev/null
run
eq "L19b an id above seen_max: one more call" "$(calls)" 2
# L19c: a full-size check draft over a large window is stored whole: the
# undelivered and open rows parse, so the next tick reads the lesson live.
reset
bulk test-cannot-fail 300001 700 5
jq -nc '{target:"check", title:("t" * 200), text:("x" * 1500), acceptance_tests:[range(6) | ("a\"" * 150)], why:("w" * 400)}' > "$T/answer"
run
eq "L19c one issue" "$(ghn POST "repos/$R/issues")" 1
eq "L19c open" "$(led_st test-cannot-fail)" open
check "L19c the open detail is JSON, at most 4000 chars" 'led test-cannot-fail | jq -e ".detail | (fromjson | .number | type == \"number\") and length <= 4000" >/dev/null'
run
eq "L19c rerun: the open issue is read live, no call" "$(calls)" 1
eq "L19c rerun: no new issue" "$(ghn POST "repos/$R/issues")" 1
# L19d: an open row whose detail was cut (no JSON) is not stuck: one log
# line, and the marker search finds the open issue and heals the row.
reset
trig test-cannot-fail 3
jq -nc '{number:7001, state:"open", title:"Lesson: x [lesson:test-cannot-fail]", body:"", html_url:"https://github.com/example-org/cromford/issues/7001"}' > "$T/gh/issues/7001.json"
put_led test-cannot-fail open '{"fp":"0000000000000000","kind":"issue","number":70'
printf '%s\n' "$PLAN" > "$T/answer"
run
check "L19d the cut detail is logged" 'grep -q "test-cannot-fail: the open ledger detail is no JSON" "$H/logs/lesson-propose.log"'
eq "L19d no call" "$(calls)" 0
eq "L19d the row is healed to #7001" "$(led_st test-cannot-fail)/$(led_d test-cannot-fail number)" open/7001
eq "L19d nothing filed" "$(writes)" 0

# ═════ K: knobs ══════════════════════════════════════════════════════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
run LESSON_PROPOSE_MAX_PER_TICK=x
check "K1 a junk MAX_PER_TICK: one warn line" '[ "$(grep -c "warn: LESSON_PROPOSE_MAX_PER_TICK=x is not an integer in 1..20; using the default 3" "$H/logs/lesson-propose.log")" = 1 ]'
eq "K1 ... and the default still runs the tick" "$(calls)" 1
reset
trig test-cannot-fail 3
run LESSON_PROPOSE_ENABLED=0
eq "K2 ENABLED=0: no lane request" "$(grep -vc '^GET /api/settings' "$T/reqlog")" 0
eq "K2 ENABLED=0: no GitHub call" "$(n "$T/gh.log")" 0

# ═════ T: the triggers route unreadable, or no model route ═══════════════════
reset
trig test-cannot-fail 3
: > "$T/fail.GET._api_lesson-propose_triggers"
run
eq "T1 triggers unreadable: no call" "$(calls)" 0
eq "T1 no claim" "$(claims)" 0
check "T1 one log line" '[ "$(n "$H/logs/lesson-propose.log")" = 1 ] && grep -q "could not read" "$H/logs/lesson-propose.log"'
reset
trig test-cannot-fail 3
q "DELETE FROM model_routes WHERE role='lesson.propose'" >/dev/null
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "T2 no lesson.propose route: no call" "$(calls)" 0
eq "T2 no claim" "$(claims)" 0
check "T2 the log says so" 'grep -q "no lesson.propose model route" "$H/logs/lesson-propose.log"'

# ═════ the worker half, as its own node suite ════════════════════════════════
if NOUT=$(cd "$DIR/worker/jobs" && TMPDIR="$T/nodetmp" node --test test/lesson-propose.bh-5807.test.js 2>&1); then ok
else bad "node suite worker/jobs/test/lesson-propose.bh-5807.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error|expected|actual' | head -30; fi


echo "$LP_NAME: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
