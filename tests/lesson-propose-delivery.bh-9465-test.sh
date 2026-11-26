#!/bin/bash
# tests/lesson-propose-delivery.bh-9465-test.sh — BH-5807: bin/lesson-propose.sh,
# sections L13-L18: refused and billed calls, failed delivery, missing anchors,
# the per-tick cap and a held second lesson.
# Drives the SHIPPED bin/lesson-propose.sh against the REAL worker routes
# (worker/jobs/src/routes/lesson-propose.js, ledger.js and model-routes.js)
# over a node:sqlite file built from the REAL jobs schema. The shared setup and
# the stubs are tests/lib/lesson-propose-fixture.bh-9465.sh; the other
# sections are in tests/lesson-propose.bh-5807-test.sh and its sibling parts.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lesson-propose-delivery.bh-9465-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
LP_NAME=lesson-propose-delivery
. "$(dirname "$0")/lib/lesson-propose-fixture.bh-9465.sh" || exit 1

LANE="$DIR/bin/lesson-propose.sh"
ROUTE="$DIR/worker/jobs/src/routes/lesson-propose.js"
FRAG="$DIR/worker/jobs/schema.d/202610160504-bh-5807-lesson-propose.sql"
CRON="$DIR/cron/lanes/733-lesson-propose.cron"
lp_setup

# ═════ L13/L14: refused calls are free, billed failures count ════════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
echo 75 > "$T/ac.rc"
run
eq "L13 rc 75: failed, attempts 0" "$(led_st test-cannot-fail)/$(led_d test-cannot-fail attempts)" failed/0
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
echo 1 > "$T/ac.rc"
run; run
scratch_rm "$T/ac.rc" || exit 1
printf 'I think the tests are weak.\n' > "$T/answer"
run
eq "L14 rc 1 twice and one unparseable answer: failed, attempts 3" "$(led_st test-cannot-fail)/$(led_d test-cannot-fail attempts)" failed/3
eq "L14 three calls" "$(calls)" 3
run
eq "L14 the fourth run: no call" "$(calls)" 3

# ═════ L15: a failed delivery keeps the draft; the next tick delivers it free ═
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
echo 500 > "$T/gh/pulls.post.status"
run
eq "L15 one call" "$(calls)" 1
eq "L15 undelivered" "$(led_st test-cannot-fail)" undelivered
check "L15 the draft is in the ledger" 'led test-cannot-fail | jq -r .detail | jq -r .draft.text | grep -qF "A plan names one mutation per acceptance test"'
check "L15 the log says proposed=0" 'grep -qE " proposed=0 " "$H/logs/lesson-propose.log"'
check "L15 one log line names the step and the HTTP status" 'grep -qE "test-cannot-fail: delivery failed at pulls \(http 500" "$H/logs/lesson-propose.log"'
rm -f "$T/gh/pulls.post.status"
run
eq "L15 next run: no new call" "$(calls)" 1
eq "L15 next run: one PR" "$(ls "$T/gh/pulls" | wc -l | tr -d ' ')" 1
check "L15 the PR carries the same text" 'cat "$T/gh/pulls/"*.json | jq -r .body | grep -qF "A plan names one mutation per acceptance test - and the test it turns red."'
eq "L15 open" "$(led_st test-cannot-fail)" open
check "L15 the second log line says proposed=1 calls=0" 'loglast | grep -qE " proposed=1 .* calls=0$"'

# ═════ L16: no §10 anchor and no ## 11. heading: failed, no PUT ═══════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
printf '# Plan contract\n\n## 9. Something\n\n- one\n' > "$T/gh/repo/prompts/plan-contract.md"
run
eq "L16 failed" "$(led_st test-cannot-fail)" failed
eq "L16 no PUT" "$(grep -c '^PUT ' "$T/gh.log" 2>/dev/null || true)" 0
eq "L16 no PR" "$(ghn POST "repos/$R/pulls")" 0
# With no `- docs/OPERATING` bullet but a ## 11. heading, the bullet goes above ## 11.
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
printf '# Plan contract\n\n## 10. Lessons\n\n- one\n\n## 11. Next\n' > "$T/gh/repo/prompts/plan-contract.md"
run
check "L16b the bullet sits above ## 11." 'put_content 1 | grep -A1 -F "(lesson-propose: test-cannot-fail)" | tail -1 | grep -q "^$" && put_content 1 | grep -A2 -F "(lesson-propose: test-cannot-fail)" | tail -1 | grep -q "^## 11\."'

# ═════ L17: 5 triggers, MAX_PER_TICK=3: 3 deliveries ════════════════════════
reset
for c in test-cannot-fail test-hand-copies-lib evidence-not-bound-to-head missing-live-probe closes-overclaim; do trig "$c" 3; done
printf '%s\n' "$CHECK" > "$T/answer"
run LESSON_PROPOSE_MAX_PER_TICK=3
eq "L17 three calls" "$(calls)" 3
eq "L17 three issues" "$(ghn POST "repos/$R/issues")" 3
eq "L17 two rows untouched" "$(q "SELECT count(*) n FROM ledgers WHERE kind='lesson_proposal'" | jq -r '.[0].n')" 3

# ═════ L18: a second lesson on the same prompt file is held ══════════════════
reset
trig logic-alert-blast-radius 4
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "L18 two calls" "$(calls)" 2
eq "L18 one PR" "$(ghn POST "repos/$R/pulls")" 1
eq "L18 the first is open" "$(led_st logic-alert-blast-radius)" open
eq "L18 the second is held" "$(led_st test-cannot-fail)" held
check "L18 the log counts it" 'grep -qE " proposed=1 filed=0 held=1 " "$H/logs/lesson-propose.log"'
jq -c '.state = "closed" | .merged_at = "2026-10-14T10:00:00Z"' "$T/gh/pulls/7001.json" > "$T/gh/m.json" && mv "$T/gh/m.json" "$T/gh/pulls/7001.json"
run
eq "L18 after the first merged: no new call" "$(calls)" 2
eq "L18 the first reads merged" "$(led_st logic-alert-blast-radius)" merged
eq "L18 the held one is delivered" "$(led_st test-cannot-fail)" open
eq "L18 two PRs in all" "$(ghn POST "repos/$R/pulls")" 2
# L18b: the open lesson's category left the trigger set (its verdicts aged
# out), and its PR merged. No lp_one reads that row again, so the hold check
# must read it live: the new lesson is delivered, not held for good.
reset
printf '%s\n' "$PLAN" > "$T/answer"
jq -nc '{number:7001, state:"closed", merged_at:"2026-10-13T10:00:00Z", title:"Lesson: x [lesson:logic-alert-blast-radius]", body:"", html_url:"https://github.com/example-org/cromford/pull/7001"}' > "$T/gh/pulls/7001.json"
echo 7001 > "$T/gh/counter"
put_led logic-alert-blast-radius open '{"fp":"0000000000000000","kind":"pr","number":7001,"path":"prompts/plan-contract.md","seen":[1,2,3]}'
trig test-cannot-fail 3
run
eq "L18b one call" "$(calls)" 1
eq "L18b the stale open row reads merged" "$(led_st logic-alert-blast-radius)" merged
eq "L18b the new lesson is open, not held" "$(led_st test-cannot-fail)" open
eq "L18b one PR" "$(ghn POST "repos/$R/pulls")" 1
check "L18b the log says held=0" 'loglast | grep -qE " proposed=1 filed=0 held=0 "'
# L18d: a backslash in the drafted text reaches the prompt file unchanged.
reset
printf '%s\n' '{"target":"plan-lesson","title":"Quote the regex","text":"Match ids with ^BH-\\d+$ and a tab is \\t.","acceptance_tests":[],"why":"w"}' > "$T/answer"
trig test-cannot-fail 3
run
check "L18d the bullet keeps its backslashes" 'put_content 1 | grep -qF -- "- Match ids with ^BH-\d+\$ and a tab is \t. (lesson-propose: test-cannot-fail)"'
# L18c: held stored drafts cost no call, so they never use a slot: with 3
# held behind a PR that is really open, a 4th category is still drafted.
reset
printf '%s\n' "$CHECK" > "$T/answer"
jq -nc '{number:7001, state:"open", merged_at:null, title:"Lesson: x [lesson:logic-alert-blast-radius]", body:"", html_url:"https://github.com/example-org/cromford/pull/7001"}' > "$T/gh/pulls/7001.json"
echo 7001 > "$T/gh/counter"
put_led logic-alert-blast-radius open '{"fp":"0000000000000000","kind":"pr","number":7001,"path":"prompts/plan-contract.md","seen":[1,2,3]}'
for c in test-hand-copies-lib evidence-not-bound-to-head missing-live-probe; do
  trig "$c" 4
  put_led "$c" held "$(jq -nc --arg fp "$(fp_of "$c" "$IDS")" --argjson d "$PLAN" --argjson s "[${IDS}]" '{fp:$fp, target:"plan-lesson", kind:"pr", path:"prompts/plan-contract.md", attempts:1, seen:$s, draft:$d}')"
done
trig test-cannot-fail 3
run LESSON_PROPOSE_MAX_PER_TICK=3
eq "L18c the three stay held" "$(led_st test-hand-copies-lib)/$(led_st evidence-not-bound-to-head)/$(led_st missing-live-probe)" held/held/held
eq "L18c the 4th is drafted: one call" "$(calls)" 1
eq "L18c the 4th is filed" "$(ghn POST "repos/$R/issues")" 1
eq "L18c no PR" "$(ghn POST "repos/$R/pulls")" 0


echo "$LP_NAME: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
