#!/bin/bash
# tests/lesson-propose.bh-5807-test.sh — BH-5807 (BH-5794.2): propose fixes for
# repeat causes. Drives the SHIPPED bin/lesson-propose.sh against the REAL
# worker routes (worker/jobs/src/routes/lesson-propose.js, ledger.js and
# model-routes.js) over a node:sqlite file built from the REAL jobs schema
# (composed from schema.d/).
#
# WHAT IS STUBBED. bin/agent-call.sh (it counts calls and answers from
# $FXT/answer with rc $FXT/ac.rc), GET /api/settings (empty), and `gh` on PATH:
# a small fake GitHub that answers `api -i -X <METHOD> <path>` from the files
# under $FXT/gh (issues/<n>.json, pulls/<n>.json, repo/<path>), records every
# call in $FXT/gh.log and every --input body in $FXT/gh/in.<n>.json. Nothing
# here reaches a model, GitHub or the real worker. The worker's clock and the
# lane's clock are both pinned to $NOW (D60).
#
# Sections here: L1-L5 (with L1b, L3b, L5r), the files, M1 and C1 (no model
# literal, the cron line) and A (the real prompt files carry the anchors the
# lane edits). The other sections are in its sibling parts:
# tests/lesson-propose-cooldown.bh-9465-test.sh (L6-L12),
# tests/lesson-propose-delivery.bh-9465-test.sh (L13-L18, with L18b-L18d) and
# tests/lesson-propose-ledger.bh-9465-test.sh (L19, K, T, the worker's node
# suite). The shared setup is tests/lib/lesson-propose-fixture.bh-9465.sh.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lesson-propose.bh-5807-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
LP_NAME=lesson-propose
. "$(dirname "$0")/lib/lesson-propose-fixture.bh-9465.sh" || exit 1

LANE="$DIR/bin/lesson-propose.sh"
ROUTE="$DIR/worker/jobs/src/routes/lesson-propose.js"
FRAG="$DIR/worker/jobs/schema.d/202610160504-bh-5807-lesson-propose.sql"
CRON="$DIR/cron/lanes/733-lesson-propose.cron"
for f in "$LANE" "$FRAG" "$CRON" "$DIR/catalog/lanes.d/lesson-propose.json" "$DIR/catalog/llm-sites.d/5807-lesson-propose.json"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
check "M1 no hardcoded model string in the lane or the schema fragment" \
  '[ -f "$LANE" ] && [ -f "$FRAG" ] && ! grep -nE "claude-(opus|sonnet|haiku|fable)|grok-[0-9]" "$LANE" "$FRAG"'
check "C1 cron: daily at 06:41, behind the hub lease" \
  'grep -qE "^41 6 \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/lesson-propose.sh " "$CRON" 2>/dev/null'
# A: the lane edits the real prompt files at run time; their anchors must exist.
check "A1 plan-contract §10 ends with the '- docs/OPERATING' bullet the lane inserts above" \
  'awk "/^## 10\\./{s=1;next} /^## /{s=0} s" "$DIR/prompts/plan-contract.md" | grep -q "^- docs/OPERATING"'
check "A2 build-discipline carries **D<n> rules the lane numbers after" \
  'grep -qE "^- \*\*D[0-9]+ " "$DIR/prompts/build-discipline.md"'
lp_setup

# ═════ L1: 3 findings in one category from 3 verdicts -> 1 plan-lesson PR ════
reset
trig test-cannot-fail 3
FP=$(fp_of test-cannot-fail "$IDS")
printf '%s\n' "$PLAN" > "$T/answer"
run
check "L1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
eq "L1 one model call" "$(calls)" 1
LINE1=$(head -1 "$T/agentcalls" 2>/dev/null)
check "L1 agent-call: stage lesson-propose, lane, role lesson.propose, fp lesson-propose:<fp>, no tools ($LINE1)" \
  'grep -qE "^lesson-propose fleet [^ ]+ [0-9]+ .*\|lesson-propose\|lesson.propose\|lesson-propose:$FP\|1$" <<<"$LINE1"'
check "L1 the findings enter the prompt as untrusted input" 'grep -q "UNTRUSTED INPUT" "$T/prompt.1" 2>/dev/null && grep -q "finding of verdict" "$T/prompt.1"'
eq "L1 one POST pulls" "$(ghn POST "repos/$R/pulls")" 1
eq "L1 one PUT of plan-contract" "$(ghn PUT "repos/$R/contents/prompts/plan-contract.md")" 1
PC=$(put_content 1 2>/dev/null)
check "L1 the new bullet sits directly above the §10 '- docs/OPERATING' line" \
  'grep -B1 "^- docs/OPERATING" <<<"$PC" | head -1 | grep -qF -- "- A plan names one mutation per acceptance test - and the test it turns red. (lesson-propose: test-cannot-fail)"'
check "L1 nothing else in the file moved" '[ "$(grep -vF "(lesson-propose: test-cannot-fail)" <<<"$PC")" = "$(plan_fixture)" ]'
PRB=$(jq -r '.body' "$T/gh/pulls/7001.json" 2>/dev/null)
for pr in 601 602 603; do
  check "L1 the PR body lists evidence PR $R#$pr with its report URL" 'grep -qF "$R#$pr" <<<"$PRB" && grep -qF "https://github.com/$R/pull/$pr#lr" <<<"$PRB"'
done
check "L1 the PR body names the category id and name" 'grep -qF "test-cannot-fail" <<<"$PRB" && grep -qF "Test cannot fail or uses unreal fixtures" <<<"$PRB"'
check "L1 the PR body says the expected BLOCKs avoided" 'grep -qF "Expected BLOCKs avoided: up to 3 in 14 days" <<<"$PRB"'
check "L1 the PR body carries the marker" 'grep -qF "<!-- lesson-propose: test-cannot-fail fp=$FP -->" <<<"$PRB"'
check "L1 the never-merges line is the last body line above the trailer block" '[ "$(grep -v "^$" <<<"$PRB" | grep -v "^Harness-" | tail -1)" = "Opened by bin/lesson-propose.sh. It never merges." ]'
check "L1 the PR body ends with the BH-4015 trailer block (lane, no ticket)" '[ "$(tail -n 2 <<<"$PRB")" = "$(printf "Harness-Job: lane:lesson-propose\nHarness-Ticket: none")" ]'
check "L1 no em dash in the PR body or the file" '! grep -q "—" <<<"$PRB$PC"'
check "L1 the PR title carries the tag" 'jq -r .title "$T/gh/pulls/7001.json" | grep -qF "[lesson:test-cannot-fail]"'
check "L1 the branch is harness/lesson-<category>-<fp8>" 'grep -qx "harness/lesson-test-cannot-fail-${FP:0:8}" "$T/gh/refs"'
eq "L1 ledger open" "$(led_st test-cannot-fail)" open
eq "L1 ledger number" "$(led_d test-cannot-fail number)" 7001
eq "L1 ledger path" "$(led_d test-cannot-fail path)" prompts/plan-contract.md
eq "L1 ledger fp" "$(led_d test-cannot-fail fp)" "$FP"
check "L1 one summary line" 'grep -qE " triggers=1 clusters=0 categories_added=0 proposed=1 filed=0 held=0 skipped=0 failed=0 calls=1$" "$H/logs/lesson-propose.log"'
check "L1 no network outside the stubs" '[ ! -s "$T/net.log" ]'

# ═════ L2: a second run with the same fixtures: 0 calls, 0 writes ════════════
W=$(writes)
LI=$(ghn GET "repos/$R/issues")
run
eq "L2 still one call" "$(calls)" 1
# The ledger row decides first: a live-open PR skips before the open-list search.
eq "L2 the open lists were not read (the ledger row decided)" "$(ghn GET "repos/$R/issues")" "$LI"
eq "L2 no new GitHub write" "$(writes)" "$W"
eq "L2 the row stays open" "$(led_st test-cannot-fail)" open
check "L2 the open PR was read live" 'grep -q "^GET repos/$R/pulls/7001$" "$T/gh.log"'

# ═════ L1b: a builder-rule answer appends D<max+1> to build-discipline ═══════
reset
trig test-cannot-fail 3
printf '%s\n' "$BUILDER" > "$T/answer"
run
eq "L1b one PUT of build-discipline" "$(ghn PUT "repos/$R/contents/prompts/build-discipline.md")" 1
BD=$(put_content 1 2>/dev/null)
check "L1b the new rule is D67 under a dated heading" \
  'grep -qF "## Added 2026-10-14 (lesson-propose: test-cannot-fail)" <<<"$BD" && grep -qF -- "- **D67 Break each new test once.** Break the code each new test pins" <<<"$BD"'
check "L1b the file is the fixture plus the append" '[ "$(head -n "$(bd_fixture | wc -l)" <<<"$BD")" = "$(bd_fixture)" ]'
eq "L1b ledger path" "$(led_d test-cannot-fail path)" prompts/build-discipline.md

# ═════ L3: an infra category files a bug, no model call ══════════════════════
reset
trig rp-repo-setup-failed 3
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "L3 no model call" "$(calls)" 0
eq "L3 one POST issues" "$(ghn POST "repos/$R/issues")" 1
eq "L3 no POST pulls" "$(ghn POST "repos/$R/pulls")" 0
check "L3 the issue carries the ai-build label" 'jq -e "[.labels[].name] | index(\"ai-build\")" "$T/gh/issues/7001.json" >/dev/null 2>&1'
check "L3 the issue title is Lesson: ... [lesson:rp-repo-setup-failed]" 'jq -r .title "$T/gh/issues/7001.json" | grep -qE "^Lesson: .+ \[lesson:rp-repo-setup-failed\]$"'
check "L3 the issue body names the evidence and the expected BLOCKs" \
  'jq -r .body "$T/gh/issues/7001.json" | grep -qF "Expected BLOCKs avoided: up to 3 in 14 days" && jq -r .body "$T/gh/issues/7001.json" | grep -qF "$R#601"'
eq "L3 ledger open, kind issue" "$(led_st rp-repo-setup-failed)/$(led_d rp-repo-setup-failed kind)/$(led_d rp-repo-setup-failed target)" open/issue/harness-bug
check "L3 filed=1 in the log" 'grep -qE " proposed=0 filed=1 .* calls=0$" "$H/logs/lesson-propose.log"'

# L3b: a builder-stage category with 2 of 3 findings infra_false files a bug too.
reset
finding test-cannot-fail "" 1; finding test-cannot-fail "" 1; finding test-cannot-fail "" 0
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "L3b 2 of 3 infra_false: no call" "$(calls)" 0
eq "L3b 2 of 3 infra_false: one issue" "$(ghn POST "repos/$R/issues")" 1
# ... and 1 of 3 is not infra: a model call.
reset
finding test-cannot-fail "" 1; finding test-cannot-fail "" 0; finding test-cannot-fail "" 0
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "L3b 1 of 3 infra_false: one call" "$(calls)" 1
eq "L3b 1 of 3 infra_false: no issue" "$(ghn POST "repos/$R/issues")" 0

# ═════ L4: a check answer files an issue with the acceptance tests ═══════════
reset
trig test-cannot-fail 3
printf '%s\n' "$CHECK" > "$T/answer"
run
eq "L4 one call" "$(calls)" 1
eq "L4 one issue" "$(ghn POST "repos/$R/issues")" 1
eq "L4 no PR" "$(ghn POST "repos/$R/pulls")" 0
IB=$(jq -r .body "$T/gh/issues/7001.json" 2>/dev/null)
check "L4 the body has #### Acceptance tests with both tests" \
  'grep -q "^#### Acceptance tests" <<<"$IB" && grep -qF "a suite that stays green under mutation is red" <<<"$IB" && grep -qF "a suite that goes red under mutation passes" <<<"$IB"'
check "L4 the title is Lesson: <title> [lesson:<category>]" '[ "$(jq -r .title "$T/gh/issues/7001.json")" = "Lesson: Lint tests that cannot fail [lesson:test-cannot-fail]" ]'
eq "L4 ledger target check" "$(led_d test-cannot-fail target)" check
# A check with no acceptance test is failed, attempt counted, nothing filed.
reset
trig test-cannot-fail 3
printf '%s\n' '{"target":"check","title":"x","text":"y","acceptance_tests":[],"why":"z"}' > "$T/answer"
run
eq "L4b a check with no test: failed, attempt 1" "$(led_st test-cannot-fail)/$(led_d test-cannot-fail attempts)" failed/1
eq "L4b nothing filed" "$(writes)" 0

# ═════ L5: a cluster of 3 `other` findings adds a category row ══════════════
reset
finding other "Stale Lockfile"; A=$FID; finding other "stale-lockfile"; B=$FID; finding other "stale lockfile"; C=$FID
printf '%s\n' "$CHECK" > "$T/answer"
run
ROW=$(q "SELECT * FROM block_categories WHERE id='stale-lockfile'" | jq -c '.[0] // {}')
eq "L5 the row is added by lesson-propose" "$(jq -r '.added_by // "none"' <<<"$ROW")" lesson-propose
REASON=$(jq -r '.reason // ""' <<<"$ROW")
check "L5 the reason names 3 verdicts and their ids ($REASON)" '[[ $REASON == *"3 BLOCK verdicts"* && $REASON == *"$A, $B, $C"* ]]'
eq "L5 the name is the most common raw label" "$(jq -r '.name' <<<"$ROW")" "Stale Lockfile"
eq "L5 the 3 findings moved" "$(q "SELECT count(*) n FROM block_findings WHERE category='stale-lockfile'" | jq -r '.[0].n')" 3
eq "L5 the cluster is proposed like a category: one call" "$(calls)" 1
eq "L5 one issue for it" "$(ghn POST "repos/$R/issues")" 1
check "L5 the log counts the cluster and the row" 'grep -qE " triggers=1 clusters=1 categories_added=1 " "$H/logs/lesson-propose.log"'
# Negative: 3 different labels make no row and no call.
reset
finding other "alpha thing"; finding other "beta thing"; finding other "gamma thing"
run
eq "L5n 3 different labels: no new row" "$(q "SELECT count(*) n FROM block_categories WHERE added_by='lesson-propose'" | jq -r '.[0].n')" 0
eq "L5n no call" "$(calls)" 0
check "L5n a tick with no trigger writes no log line" '[ ! -s "$H/logs/lesson-propose.log" ]'
# A retired slug is skipped with a log line, nothing written.
reset
q "UPDATE block_categories SET status='retired' WHERE id='iron-law'" >/dev/null
finding other "Iron Law"; finding other "iron law"; finding other "iron-law"
run
eq "L5r a retired slug: no call" "$(calls)" 0
check "L5r a retired slug: one log line" 'grep -q "cluster iron-law: the category is retired; skipped" "$H/logs/lesson-propose.log"'
eq "L5r the findings stay other" "$(q "SELECT count(*) n FROM block_findings WHERE category='other'" | jq -r '.[0].n')" 3

echo "lesson-propose: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
