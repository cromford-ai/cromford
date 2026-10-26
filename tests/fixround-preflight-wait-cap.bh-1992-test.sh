#!/bin/bash
# tests/fixround-preflight-wait-cap.bh-1992-test.sh — BH-1992 items 1 and 2: the
# fix-round preflight (BH-1794) can neither starve a PR nor truncate its body.
#
# ITEM 1. `wait` and `skip` were answered on every tick with no per-head count,
# so a check-run stuck pending, or a head no CI ever ran on, parked a PR for
# ever, one event row per tick.
#   W1  six waits on one head, then the seventh tick runs the round (through
#       br_fix_round, the production entry point, up to the agent call)
#   W2  BR_PREFLIGHT_WAIT_MAX=0 is off: never capped
#   W3  `skip` (a red-CI park green at head) is counted on the same cap
#   W4  CI `none` on a head first waited on 31 min ago reads as unreadable, and
#       the round runs; 10 min ago it still waits
#   W5  a head that moved restarts the count
#   W6  a wait that cannot be recorded runs the round (it would repeat forever)
# ITEM 2. A `harness:live-ci` begin marker with no end made the splice drop
# every line after it, and that truncated body was PATCHed to the PR.
#   S1  begin with no end -> rc 4, no PATCH, body byte-identical
#   S2  a second begin while one is open -> rc 4, no PATCH
#   S3  a balanced body is still spliced in place; an end-only body is not refused
#   S4  the refusal alerts ONCE per PR, record first then send
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/fixround-preflight-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
frpx_setup
frpx_fr_setup
# shellcheck source=bin/lib/fixround-preflight.sh
. "$LIB"
NOW=$(date -u +%s)

# ============================================================================
# W1 — six waits on one head, the seventh tick runs the round
# ============================================================================
reset_gh; reset_rec; rm -f "$T/agent.log"
RUNS "$NEW" in_progress; PRBODY "$NEW" "$STALE_BODY"
printf '%s\n' "$OLD_FINDINGS" > "$T/findings.txt"
for i in 1 2 3 4 5 6; do FR head-not-reapproved; done
[ "$(grep -c "wait on ${NEW:0:8}" "$T/events.log" 2>/dev/null)" = 6 ] && ok || bad "W1 six ticks on a pending head must be six wait rows: $(cat "$T/events.log" 2>/dev/null)"
[ "$(lines "$T/agent.log")" = 0 ] && ok || bad "W1 no agent call while the head is under its wait cap"
[ "$(jq -r '.preflight_wait_n // 0' "$T/rec.json" 2>/dev/null)" = 6 ] && ok || bad "W1 the record must count six waits on this head: $(cat "$T/rec.json" 2>/dev/null)"
FR head-not-reapproved
[ "$(lines "$T/agent.log")" = 1 ] && ok || bad "W1 the seventh tick on the same head must run the fix round (agent calls $(lines "$T/agent.log"); terminal: $(cat "$T/terminal.log" 2>/dev/null))"
grep -q 'LIVE STATE OF THIS PULL REQUEST' "$T/prompt.txt" 2>/dev/null && ok || bad "W1 the capped round must still be briefed from the live state"
grep -q "fix on ${NEW:0:8}: waited 6 ticks on ${NEW:0:8}" "$T/events.log" 2>/dev/null && ok || bad "W1 the round's event row must say it was the wait cap: $(tail -1 "$T/events.log" 2>/dev/null)"

# ============================================================================
# W2 — BR_PREFLIGHT_WAIT_MAX=0 means no cap
# ============================================================================
reset_gh; reset_rec; rm -f "$T/agent.log"
RUNS "$NEW" in_progress; PRBODY "$NEW" "$STALE_BODY"
for i in 1 2 3 4 5 6 7; do BR_PREFLIGHT_WAIT_MAX=0 FR head-not-reapproved; done
[ "$(lines "$T/agent.log")" = 0 ] && ok || bad "W2 BR_PREFLIGHT_WAIT_MAX=0 must never cap a wait (agent calls $(lines "$T/agent.log"))"
[ "$(grep -c "wait on ${NEW:0:8}" "$T/events.log" 2>/dev/null)" = 7 ] && ok || bad "W2 seven wait rows with the cap off"

# ============================================================================
# W3 — `skip` is counted per head on the same cap
# ============================================================================
reset_gh; reset_rec
RUNS "$NEW" success; PRBODY "$NEW" "$STALE_BODY"
RCS=""
for i in 1 2 3 4 5 6 7; do RCS="$RCS$(PRE red-ci-twice "" | head -1)"; done
[ "$RCS" = 1111110 ] && ok || bad "W3 a red-CI park green at head skips six ticks and runs the round on the seventh (rcs $RCS)"
[ "$(grep -c "skip on ${NEW:0:8}" "$T/events.log" 2>/dev/null)" = 6 ] && ok || bad "W3 six skip rows: $(cat "$T/events.log" 2>/dev/null)"

# ============================================================================
# W4 — no CI on this head after BR_PREFLIGHT_NOCI_S reads as unreadable
# ============================================================================
reset_gh; reset_rec; rm -f "$T/agent.log"
PRBODY "$NEW" "$STALE_BODY"   # no runs, no checks: CI `none`
jq -nc --arg h "$NEW" --argjson f "$((NOW - 600))" '{preflight_wait_head:$h, preflight_wait_n:1, preflight_wait_first:$f}' > "$T/rec.json"
FR head-not-reapproved
[ "$(lines "$T/agent.log")" = 0 ] && ok || bad "W4 ten minutes of no CI is still a wait"
jq -nc --arg h "$NEW" --argjson f "$((NOW - 1860))" '{preflight_wait_head:$h, preflight_wait_n:2, preflight_wait_first:$f}' > "$T/rec.json"
FR head-not-reapproved
[ "$(lines "$T/agent.log")" = 1 ] && ok || bad "W4 31 minutes with no CI on the head must run the round (agent calls $(lines "$T/agent.log"))"
grep -q "CI on ${NEW:0:12}: UNREADABLE" "$T/prompt.txt" 2>/dev/null && ok || bad "W4 the brief must say the CI is unreadable: $(head -c 800 "$T/prompt.txt" 2>/dev/null)"
grep -q 'read as unreadable' "$T/prompt.txt" 2>/dev/null && ok || bad "W4 the brief must say why: no CI in N minutes"
grep -q "no CI on ${NEW:0:8} after 31 minutes, read as unreadable" "$T/say.log" 2>/dev/null && ok || bad "W4 the tick line must name the timeout: $(tail -2 "$T/say.log" 2>/dev/null)"
# BR_PREFLIGHT_NOCI_S=0 is off: the same record waits.
reset_rec; rm -f "$T/agent.log"
jq -nc --arg h "$NEW" --argjson f "$((NOW - 1860))" '{preflight_wait_head:$h, preflight_wait_n:2, preflight_wait_first:$f}' > "$T/rec.json"
[ "$(BR_PREFLIGHT_NOCI_S=0 PRE head-not-reapproved "$OLD_FINDINGS" | head -1)" = 1 ] && ok || bad "W4 BR_PREFLIGHT_NOCI_S=0 must turn the no-CI timeout off"

# ============================================================================
# W5 — a head that moved restarts the count
# ============================================================================
reset_gh; reset_rec
RUNS "$NEW" in_progress; RUNS "$MOVED" in_progress; PRBODY "$NEW" "$STALE_BODY"
for i in 1 2 3 4 5; do PRE head-not-reapproved "$OLD_FINDINGS" >/dev/null; done
[ "$(jq -r '.preflight_wait_n' "$T/rec.json")" = 5 ] && ok || bad "W5 five waits on the first head"
[ "$(PRE head-not-reapproved "$OLD_FINDINGS" "$MOVED" | head -1)" = 1 ] && ok || bad "W5 the moved head must wait, not run the round"
[ "$(jq -r '.preflight_wait_n' "$T/rec.json")" = 1 ] && [ "$(jq -r '.preflight_wait_head' "$T/rec.json")" = "$MOVED" ] \
  && ok || bad "W5 the count must restart at 1 on the moved head: $(cat "$T/rec.json")"

# ============================================================================
# W6 — a wait that cannot be recorded runs the round
# ============================================================================
reset_gh; reset_rec
RUNS "$NEW" in_progress; PRBODY "$NEW" "$STALE_BODY"; touch "$T/rec-ro"
[ "$(PRE head-not-reapproved "$OLD_FINDINGS" | head -1)" = 0 ] && ok || bad "W6 an unrecorded wait repeats forever, so the round must run"
rm -f "$T/rec-ro"

# ============================================================================
# S1-S3 — the splice refuses an unbalanced begin marker
# ============================================================================
CI_GREEN() { RUNS "$NEW" success; frp_ci "$SLUG" "$NEW"; }
reset_gh
S1_BODY="intro
<!-- harness:live-ci:begin -->
old
## Evidence
KEEP-ME"
PRBODY "$NEW" "$S1_BODY"
frp_body_refresh "$SLUG" 7 "$(CI_GREEN)" ""; RC=$?
[ "$RC" = 4 ] && ok || bad "S1 a begin marker with no end must be refused with rc 4 (got $RC)"
[ "$(patches)" = 0 ] && ok || bad "S1 no PATCH may be sent on a refused splice"
[ "$(body)" = "$S1_BODY" ] && ok || bad "S1 the body must be left byte-identical: $(body)"

reset_gh
S2_BODY="intro
<!-- harness:live-ci:begin -->
x
<!-- harness:live-ci:end -->
<!-- harness:live-ci:begin -->
tail"
PRBODY "$NEW" "$S2_BODY"
frp_body_refresh "$SLUG" 7 "$(CI_GREEN)" ""; RC=$?
[ "$RC" = 4 ] && [ "$(patches)" = 0 ] && ok || bad "S2 a second begin left open must be refused with no PATCH (rc $RC, patches $(patches))"
[ "$(body)" = "$S2_BODY" ] && ok || bad "S2 the body must be left byte-identical"
# the end-first reversal: an end, then a begin that never closes
reset_gh
PRBODY "$NEW" "a
<!-- harness:live-ci:end -->
b
<!-- harness:live-ci:begin -->
c"
frp_body_refresh "$SLUG" 7 "$(CI_GREEN)" ""; RC=$?
[ "$RC" = 4 ] && [ "$(patches)" = 0 ] && ok || bad "S2 end-then-begin leaves a begin open at EOF and must be refused (rc $RC)"

reset_gh
PRBODY "$NEW" "intro
<!-- harness:live-ci:begin -->
old
<!-- harness:live-ci:end -->

## Evidence
KEEP-ME"
frp_body_refresh "$SLUG" 7 "$(CI_GREEN)" ""; RC=$?
B=$(body)
[ "$RC" = 0 ] && [ "$(patches)" = 1 ] && ok || bad "S3 a balanced body must still be spliced (rc $RC, patches $(patches))"
grep -q '^old$' <<<"$B" && bad "S3 the old block content must be replaced" || ok
grep -q "CI on ${NEW:0:12}: GREEN" <<<"$B" && grep -q KEEP-ME <<<"$B" && [ "$(grep -c 'harness:live-ci:begin' <<<"$B")" = 1 ] \
  && ok || bad "S3 the block is replaced in place and the rest kept: $B"
reset_gh
PRBODY "$NEW" "intro
<!-- harness:live-ci:end -->
## Evidence
KEEP-ME"
frp_body_refresh "$SLUG" 7 "$(CI_GREEN)" ""; RC=$?
B=$(body)
[ "$RC" = 0 ] && grep -q KEEP-ME <<<"$B" && grep -q "CI on ${NEW:0:12}: GREEN" <<<"$B" \
  && ok || bad "S3 an end-only marker is an ordinary line and must not be refused (rc $RC): $B"

# ============================================================================
# S4 — the refusal alerts once per PR (record first, then send)
# ============================================================================
AFTER_PUSH() {
  bash -c '. "$1"; . "$2"; . "$3"; br_preflight_after_push "$4" "$5" "$6" tproj ck' _ \
    "$LIB" "$T/stubs.sh" "$T/pre.sh" "$SLUG" "$URL" "$NEW"
}
reset_gh; reset_rec
PRBODY "$NEW" "$S1_BODY"
AFTER_PUSH; AFTER_PUSH
[ "$(lines "$T/alerts.log")" = 1 ] && ok || bad "S4 two ticks on the same broken body must alert exactly once (got $(lines "$T/alerts.log"))"
grep -q "begin marker with no end" "$T/alerts.log" 2>/dev/null && grep -qF "$URL" "$T/alerts.log" && ok || bad "S4 the alert must name the PR and the defect: $(cat "$T/alerts.log" 2>/dev/null)"
[ "$(jq -r '.marker_alerted[0] // ""' "$T/rec.json" 2>/dev/null)" = "$URL" ] && ok || bad "S4 the record must hold the alerted URL"
[ "$(patches)" = 0 ] && [ "$(body)" = "$S1_BODY" ] && ok || bad "S4 the body must be left alone across ticks"
# ...a record that will not take the mark sends nothing (and retries next tick).
reset_rec; touch "$T/rec-ro"
AFTER_PUSH
[ "$(lines "$T/alerts.log")" = 0 ] && ok || bad "S4 an alert whose record write failed must not be sent (it would repeat every tick)"
rm -f "$T/rec-ro"
# ...the fix path writes no body before the round (BH-8339: the body is written
# only after a push that landed, AFTER_PUSH above), so it neither alerts nor PATCHes...
reset_gh; reset_rec
RUNS "$NEW" failure; PRBODY "$NEW" "$S1_BODY"
[ "$(PRE head-not-reapproved "1. HIGH src/a.ts:1 bug" | head -1)" = 0 ] && ok || bad "S4 a broken body costs the round nothing"
[ "$(lines "$T/alerts.log")" = 0 ] && [ "$(patches)" = 0 ] && [ "$(body)" = "$S1_BODY" ] && ok || bad "S4 the fix path must not touch the body before the round (alerts $(lines "$T/alerts.log"), patches $(patches))"
# ...and the preflight's own refreshes alert the same way: the review-lane evidence route...
# rc 4 is not 0 or 3, so the round runs.
reset_gh; reset_rec
RUNS "$NEW" success; PRBODY "$NEW" "$S1_BODY"
[ "$(PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 0 ] && ok || bad "S4 an evidence route whose body refused the block must fall back to the fix round"
[ "$(lines "$T/alerts.log")" = 1 ] && [ "$(patches)" = 0 ] && ok || bad "S4 the evidence route's refusal must alert once and send no PATCH"
[ "$(lines "$T/comments.log")" = 0 ] && ok || bad "S4 no re-review request may be posted when the body refused the block"

echo "fixround-preflight-wait-cap.bh-1992: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
