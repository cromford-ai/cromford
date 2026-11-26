#!/bin/bash
# tests/lesson-propose-cooldown.bh-9465-test.sh — BH-5807: bin/lesson-propose.sh,
# sections L6-L12: the merged cooldown, a blank answer, the marker heal, outages
# and a fresh drafting row.
# Drives the SHIPPED bin/lesson-propose.sh against the REAL worker routes
# (worker/jobs/src/routes/lesson-propose.js, ledger.js and model-routes.js)
# over a node:sqlite file built from the REAL jobs schema. The shared setup and
# the stubs are tests/lib/lesson-propose-fixture.bh-9465.sh; the other
# sections are in tests/lesson-propose.bh-5807-test.sh and its sibling parts.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lesson-propose-cooldown.bh-9465-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
LP_NAME=lesson-propose-cooldown
. "$(dirname "$0")/lib/lesson-propose-fixture.bh-9465.sh" || exit 1

LANE="$DIR/bin/lesson-propose.sh"
ROUTE="$DIR/worker/jobs/src/routes/lesson-propose.js"
FRAG="$DIR/worker/jobs/schema.d/202610160504-bh-5807-lesson-propose.sql"
CRON="$DIR/cron/lanes/733-lesson-propose.cron"
lp_setup

# ═════ L6/L7: the merged cooldown ════════════════════════════════════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
put_led test-cannot-fail merged "$(jq -nc --arg at "$(iso_ago 13)" '{fp:"0000000000000000", at:$at, target:"plan-lesson", kind:"pr", number:42}')"
run
eq "L6 merged 13 days ago: no call" "$(calls)" 0
eq "L6 no write" "$(writes)" 0
reset
trig test-cannot-fail 4
printf '%s\n' "$PLAN" > "$T/answer"
put_led test-cannot-fail merged "$(jq -nc --arg at "$(iso_ago 15)" '{fp:"0000000000000000", at:$at, target:"plan-lesson", kind:"pr", number:42}')"
run
eq "L7 merged 15 days ago with a 4th verdict: one call" "$(calls)" 1
eq "L7 a new PR" "$(ghn POST "repos/$R/pulls")" 1

# ═════ L8: a blank answer is empty and terminal for that evidence ════════════
reset
trig test-cannot-fail 3
printf '\n' > "$T/answer"
run
eq "L8 one call" "$(calls)" 1
eq "L8 empty" "$(led_st test-cannot-fail)" empty
run
eq "L8 rerun: no new call" "$(calls)" 1
printf '%s\n' '{"target":"none","title":"","text":"","acceptance_tests":[],"why":"nothing to learn"}' > "$T/answer"
finding test-cannot-fail
run
eq "L8 a new verdict (new fp): one more call" "$(calls)" 2
eq "L8 target none is empty too" "$(led_st test-cannot-fail)" empty
eq "L8 nothing filed" "$(writes)" 0
# L8b: the window slides. A verdict that ages out changes the fp, but it is
# not new evidence: the empty row stays terminal. A closed (rejected) lesson too.
reset
trig test-cannot-fail 4
OLD=${IDS%%,*}
printf '\n' > "$T/answer"
run
eq "L8b one call" "$(calls)" 1
q "UPDATE block_findings SET verdict_at=? WHERE verdict_id=?" "$(iso_ago 20)" "$OLD" >/dev/null
q "UPDATE verdicts SET created_at=? WHERE id=?" "$(iso_ago 20)" "$OLD" >/dev/null
run
eq "L8b a verdict aged out (new fp, no new id): no new call" "$(calls)" 1
eq "L8b still empty" "$(led_st test-cannot-fail)" empty
finding test-cannot-fail
run
eq "L8b a new verdict id: one more call" "$(calls)" 2
reset
trig test-cannot-fail 4
OLD=${IDS%%,*}
put_led test-cannot-fail closed "$(jq -nc --arg fp "$(fp_of test-cannot-fail "$IDS")" --argjson s "[${IDS}]" '{fp:$fp, kind:"pr", number:7001, path:"prompts/plan-contract.md", seen:$s, attempts:1}')"
q "UPDATE block_findings SET verdict_at=? WHERE verdict_id=?" "$(iso_ago 20)" "$OLD" >/dev/null
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "L8b a closed lesson, a verdict aged out: no call" "$(calls)" 0
eq "L8b a closed lesson, a verdict aged out: no PR" "$(ghn POST "repos/$R/pulls")" 0

# ═════ L9: the marker on an open issue heals a lost ledger row ══════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
jq -nc '{number:4242, state:"open", title:"Lesson: something [lesson:test-cannot-fail]", body:"x\n<!-- lesson-propose: test-cannot-fail fp=1111111111111111 -->\n", html_url:"https://github.com/example-org/cromford/issues/4242"}' > "$T/gh/issues/4242.json"
run
eq "L9 no call" "$(calls)" 0
eq "L9 no write" "$(writes)" 0
eq "L9 the row is back to open with that issue" "$(led_st test-cannot-fail)/$(led_d test-cannot-fail number)" open/4242
# The marker must name THIS category: another category's marker is no hit.
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
jq -nc '{number:4243, state:"open", title:"x", body:"<!-- lesson-propose: test-cannot-fail-two fp=1 -->", html_url:"https://github.com/example-org/cromford/issues/4243"}' > "$T/gh/issues/4243.json"
run
eq "L9b another category's marker: one call" "$(calls)" 1

# ═════ L10: a ledger outage stops the whole tick ═════════════════════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
: > "$T/fail.GET._api_ledger"
run
eq "L10 no call" "$(calls)" 0
eq "L10 no GitHub write" "$(writes)" 0
eq "L10 no claim" "$(claims)" 0
eq "L10 no ledger row" "$(led_st test-cannot-fail)" none
check "L10 one log line names the outage" 'grep -q "ledger" "$H/logs/lesson-propose.log"'

# ═════ L11: the open-issue list unreadable: no claim, no call ════════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
echo 500 > "$T/gh/issues.list.status"
run
eq "L11 no claim" "$(claims)" 0
eq "L11 no call" "$(calls)" 0
eq "L11 no write" "$(writes)" 0

# ═════ L12: a fresh drafting row (another tick holds it): no call ════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
put_led test-cannot-fail drafting '{}'
run
eq "L12 no call" "$(calls)" 0
eq "L12 one claim, refused" "$(claims)" 1
eq "L12 the row is still drafting" "$(led_st test-cannot-fail)" drafting


echo "$LP_NAME: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
