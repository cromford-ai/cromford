#!/bin/bash
# tests/mc-failed-batch.bh-8186-test.sh — BH-8186: the failed-batch record lib
# (bin/lib/mc-failed-batch.sh) and the fragment verbs over stubs. No network,
# no git: gh, git and the conductor's verbs are stubbed in this shell.
#
#   P1-P8  fbh_parse: the BATCH_MAX payload, CHECKS_FAILED, a code that does not
#          count, a `queued` state, the newest comment by (created_at, id) and
#          never by updated_at, no Mergify comment, non-array JSON, a check name
#          with a space and a comma
#   D1-D9  fbh_decide: every row of the decision table, the window edges
#   F1-F4  the record: write/read round trip, a cleared line after failed, a
#          failed line after cleared, the 20-line cap
#   G1-G2  fbh_gc deletes a file past MC_FAILED_BATCH_KEEP_DAYS, keeps a fresh one
#   G5     MC_FAILED_BATCH_GC_INTERVAL_MIN sets the gap between sweeps; F5
#          MC_FAILED_BATCH_KEEP_LINES sets the lines a record keeps
#   K1     MC_FAILED_BATCH=0: mc_fbh_record writes nothing, mc_fbh_apply holds nothing
#   C1     mc_fbh_clear clears only the live record's head
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-failed-batch.bh-8186-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: want '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset MC_FAILED_BATCH MC_FAILED_BATCH_CODES MC_FAILED_BATCH_UNJUDGED_HOLD_S MC_FAILED_BATCH_KEEP_DAYS MC_FAILED_BATCH_KEEP_LINES MC_FAILED_BATCH_GC_INTERVAL_MIN P
# shellcheck source=bin/lib/mc-failed-batch.sh
. "$DIR/bin/lib/mc-failed-batch.sh" || { echo "FAIL: cannot source bin/lib/mc-failed-batch.sh"; exit 1; }

export MC_STATE_DIR="$T/state"; mkdir -p "$MC_STATE_DIR"
export MC_FAILED_BATCH_NOW=1792731960   # the record clock, pinned
MC_ATTEMPTS="$T/attempts.txt"; : > "$MC_ATTEMPTS"
LOG="$T/log.txt"; : > "$LOG"
mc_log() { printf '%s\n' "$*" >> "$LOG"; }
mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS" 2>/dev/null; }
mc_attempt_put() { printf '%s\n' "$1" >> "$MC_ATTEMPTS"; }

H1=3b036d004e90aaaaaaaaaaaaaaaaaaaaaaaaaaaa
# cmt <id> <created_at> <updated_at> <state> <code> <left-sha> <draft> <check> — one mergify[bot] payload comment.
cmt() {
  local pl body
  pl=$(jq -nc --arg s "$4" --arg c "$5" --arg k "$8" '{version:1,state:$s} + (if $c == "" then {} else {dequeue_reason:{code:$c,checks:[$k]}} end)')
  body=$(printf '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n%s\n-*- Mergify Payload End -*-\n-->\n\n# Merge Queue Status\n\n- ❌ **Checks failed** — `2026-10-23 13:30 UTC` · on draft #%s\n- 🚫 **Left the queue** — `2026-10-23 14:06 UTC` · at `%s`\n\n## Reason\n\nFailing checks:\n- ❌ [`%s`](https://x/runs/1)\n' "$pl" "$7" "$6" "$8")
  jq -nc --argjson id "$1" --arg c "$2" --arg u "$3" --arg b "$body" '{id:$id,user:{login:"mergify[bot]",type:"Bot"},created_at:$c,updated_at:$u,body:$b}'
}
arr() { local IFS=,; printf '[%s]' "$*"; }

# ---- P: fbh_parse ------------------------------------------------------------
J=$(arr "$(cmt 6366196632 2026-10-23T05:10:00Z 2026-10-23T19:02:59Z dequeued BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS "$H1" 8165 'Pure-logic gate fixtures')")
eq "P1: the #8127 BATCH_MAX payload parses" "$(fbh_parse "$J")" "BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS	$H1	8165	Pure-logic%20gate%20fixtures"
fbh_code_counts BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS && pass "P1: BATCH_MAX counts" || fail "P1: BATCH_MAX does not count"
J=$(arr "$(cmt 7 2026-10-23T05:10:00Z 2026-10-23T05:10:00Z dequeued CHECKS_FAILED "$H1" 900 ci)")
eq "P2: a CHECKS_FAILED payload parses" "$(fbh_parse "$J" | cut -f1,3,4)" "CHECKS_FAILED	900	ci"
fbh_code_counts CHECKS_FAILED && pass "P2: CHECKS_FAILED counts" || fail "P2: CHECKS_FAILED does not count"
J=$(arr "$(cmt 7 2026-10-23T05:10:00Z 2026-10-23T05:10:00Z dequeued PR_MANUALLY_DEQUEUED "$H1" 900 ci)")
eq "P3: PR_MANUALLY_DEQUEUED parses" "$(fbh_parse "$J" | cut -f1)" PR_MANUALLY_DEQUEUED
fbh_code_counts PR_MANUALLY_DEQUEUED && fail "P3: PR_MANUALLY_DEQUEUED counts" || pass "P3: PR_MANUALLY_DEQUEUED does not count"
fbh_code_counts CONFLICT_WITH_BASE_BRANCH && fail "P3: CONFLICT_WITH_BASE_BRANCH counts" || pass "P3: CONFLICT_WITH_BASE_BRANCH does not count"
fbh_code_counts - && fail "P3: no code counts" || pass "P3: a payload with no code does not count"
MC_FAILED_BATCH_CODES=CHECKS_FAILED fbh_code_counts BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS && fail "P3: the codes knob is not read" || pass "P3: the codes knob is read"
J=$(arr "$(cmt 7 2026-10-23T05:10:00Z 2026-10-23T05:10:00Z queued "" "$H1" 900 ci)")
fbh_parse "$J" >/dev/null; eq "P4: a queued state is rc 1" "$?" 1
# P5 — the older comment was edited later; the newer by created_at wins.
OLD=$(cmt 100 2026-10-23T05:10:00Z 2026-10-23T19:02:59Z dequeued BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS "$H1" 8165 old)
NEW=$(cmt 50 2026-10-23T15:00:00Z 2026-10-23T15:00:00Z dequeued CHECKS_FAILED "$H1" 8200 new)
eq "P5: the newest by (created_at, id), not by updated_at" "$(fbh_parse "$(arr "$NEW" "$OLD")" | cut -f1,3)" "CHECKS_FAILED	8200"
NQ=$(cmt 60 2026-10-23T16:00:00Z 2026-10-23T16:00:00Z queued "" "$H1" 8200 new)
fbh_parse "$(arr "$OLD" "$NQ")" >/dev/null; eq "P5: a newer queued payload hides an older dequeue (rc 1)" "$?" 1
J=$(jq -nc '[{id:1,user:{login:"operator",type:"User"},created_at:"2026-10-23T05:10:00Z",body:"@mergifyio queue"}]')
fbh_parse "$J" >/dev/null; eq "P6: no mergify comment is rc 1" "$?" 1
fbh_parse '{"message":"Not Found"}' >/dev/null; eq "P7: non-array JSON is rc 2" "$?" 2
fbh_parse 'not json' >/dev/null; eq "P7: unreadable JSON is rc 2" "$?" 2
CK='Jobs worker — routes + schema, 100%'
J=$(arr "$(cmt 7 2026-10-23T05:10:00Z 2026-10-23T05:10:00Z dequeued CHECKS_FAILED "$H1" 900 "$CK")")
ENC=$(fbh_parse "$J" | cut -f4)
case "$ENC" in *' '*|*,*) fail "P8: the encoded check holds a space or a comma ('$ENC')" ;; *) pass "P8: the encoded check is one word" ;; esac
eq "P8: a check with a space and a comma round-trips" "$(fbh_dec "$ENC")" "$CK"
# P9 — no dequeue_reason.checks: the Failing checks bullets.
J=$(jq -nc --arg b "$(printf -- '-*- Mergify Payload -*-\n{"state":"dequeued","dequeue_reason":{"code":"CHECKS_FAILED"}}\n-*- Mergify Payload End -*-\n- 🚫 **Left the queue** — `x` · at `%s`\n\nFailing checks:\n- ❌ [`lint`](https://x)\n' "$H1")" '[{id:1,user:{login:"mergify[bot]"},created_at:"2026-10-23T05:10:00Z",body:$b}]')
eq "P9: no checks in the payload: the Failing checks bullets" "$(fbh_parse "$J" | cut -f1,2,4)" "CHECKS_FAILED	$H1	lint"

eq "N1: fbh_now is the pinned clock" "$(fbh_now)" 1792731960
# ---- D: fbh_decide -----------------------------------------------------------
eq "D1: a different patch clears (any solo, any age)" "$(fbh_decide 0 reproduces 99999 86400)" clear:new-patch
eq "D2: an unread patch waits" "$(fbh_decide '?' clean 0 86400)" wait
eq "D3: same patch, solo clean: a bystander" "$(fbh_decide 1 clean 0 86400)" clear:bystander
eq "D4: same patch, solo reproduces: judged" "$(fbh_decide 1 reproduces 999999 86400)" hold-judged
eq "D5: same patch, solo pending: hold" "$(fbh_decide 1 pending 10 86400)" hold
eq "D6: same patch, no solo, one second under the window: hold" "$(fbh_decide 1 - 86399 86400)" hold
eq "D7: same patch, no solo, exactly at the window: clear" "$(fbh_decide 1 - 86400 86400)" clear:window
eq "D8: same patch, could-not-run, past the window: clear" "$(fbh_decide 1 could-not-run 90000 86400)" clear:window
eq "D9: same patch, pending, past the window: clear" "$(fbh_decide 1 pending 86400 86400)" clear:window

# ---- F: the record -------------------------------------------------------------
F=$(fbh_file example-org/cromford 8127)
eq "F0: the record path" "$F" "$MC_STATE_DIR/failed-batch/example-org_cromford_8127"
fbh_append "$F" 100 "$H1" pid1 failed BATCH_MAX 8165 "$ENC"
eq "F1: write and read a failed line" "$(fbh_live "$F" | cut -f2-7)" "$H1	pid1	failed	BATCH_MAX	8165	$ENC"
fbh_append "$F" 200 H2 - cleared:new-patch - - -
eq "F2: a cleared line after failed: no live record" "$(fbh_live "$F")" ""
fbh_append "$F" 300 H3 pid3 failed CHECKS_FAILED 9000 ci
eq "F3: a failed line after a cleared one is live" "$(fbh_live "$F" | cut -f2,4)" "H3	failed"
for i in $(seq 1 30); do fbh_append "$F" "$((400 + i))" "H$i" - pending - - -; done
eq "F4: the record keeps the last 20 lines" "$(wc -l < "$F" | tr -d ' ')" 20
eq "F4: ...the newest line is the last written" "$(tail -1 "$F" | cut -f1)" 430
MC_FAILED_BATCH_KEEP_LINES=5 fbh_append "$F" 500 H500 - pending - - -
eq "F5: MC_FAILED_BATCH_KEEP_LINES is read" "$(wc -l < "$F" | tr -d ' ')" 5

# ---- C: mc_fbh_clear (the fragment) --------------------------------------------
H="$DIR"
# shellcheck source=bin/merge-conductor.d/bh-8186-failed-batch.sh
. "$DIR/bin/merge-conductor.d/bh-8186-failed-batch.sh" || { echo "FAIL: cannot source the fragment"; exit 1; }
F=$(fbh_file example-org/cromford 8128)
fbh_append "$F" 100 "$H1" pid1 failed BATCH_MAX 8165 ci
mc_fbh_clear 'example-org/cromford#8128' OTHERHEAD bystander
eq "C1: a clear for another head leaves the record live" "$(fbh_live "$F" | cut -f2)" "$H1"
mc_fbh_clear 'example-org/cromford#8128' "$H1" bystander
eq "C1: a clear for the live head clears it" "$(fbh_live "$F")" ""
eq "C1: ...as cleared:bystander" "$(tail -1 "$F" | cut -f4)" cleared:bystander

# ---- G: retention ----------------------------------------------------------------
D="$MC_STATE_DIR/failed-batch"
printf 'x\n' > "$D/old_1"; touch -d '20 days ago' "$D/old_1"
printf 'x\n' > "$D/new_1"
rm -f "$D/.gc"
N=$(fbh_gc)
[ ! -e "$D/old_1" ] && pass "G1: a record past 14 days is deleted" || fail "G1: old_1 is still there"
[ -e "$D/new_1" ] && pass "G2: a fresh record is kept" || fail "G2: new_1 was deleted"
eq "G1: fbh_gc names the count" "$N" 1
printf 'x\n' > "$D/old_2"; touch -d '20 days ago' "$D/old_2"
eq "G3: a second gc inside the hour does nothing" "$(fbh_gc)" 0
rm -f "$D/.gc"
eq "G4: MC_FAILED_BATCH_KEEP_DAYS is read" "$(MC_FAILED_BATCH_KEEP_DAYS=30 fbh_gc)" 0
touch -d '10 minutes ago' "$D/.gc"
eq "G5: a stamp 10 minutes old holds the default 60-minute gc" "$(fbh_gc)" 0
eq "G5: MC_FAILED_BATCH_GC_INTERVAL_MIN is read" "$(MC_FAILED_BATCH_GC_INTERVAL_MIN=5 fbh_gc)" 1

# ---- K1: the switch ------------------------------------------------------------
gh_rest_issue_comments() { echo READ >> "$T/reads.txt"; arr "$(cmt 7 2026-10-23T05:10:00Z 2026-10-23T05:10:00Z dequeued CHECKS_FAILED "$H1" 900 ci)"; }
mc_rest_var() { local _o="$1"; shift 2; local _v; _v=$(gh_rest_issue_comments "$@"); printf -v "$_o" '%s' "$_v"; }
mc_record_for() { return 1; }
mc_patch_id_file() { printf '%s/pid.%s' "$T" "$4"; }
mc_git_locked() { return 99; }
: > "$T/reads.txt"
MC_FAILED_BATCH=0 mc_fbh_record example-org/cromford proj 'example-org/cromford#8129' u "$H1"
[ ! -e "$(fbh_file example-org/cromford 8129)" ] && [ ! -s "$T/reads.txt" ] && pass "K1: MC_FAILED_BATCH=0: no read, no record" || fail "K1: a record or a read under the switch off"
mc_fbh_record example-org/cromford proj 'example-org/cromford#8129' u "$H1"
eq "K1: the switch on: the same call records the failure" "$(fbh_live "$(fbh_file example-org/cromford 8129)" | cut -f2,3,4)" "$H1	-	failed"
P=proj; SLUG=example-org/cromford; NUM=8129; KEY="$SLUG#$NUM"; URL=u; HEAD="$H1"; REC=""; STATE=READY; WHY=x
MC_FAILED_BATCH=0 mc_fbh_apply; RC=$?
[ "$RC" = 1 ] && [ "$STATE" = READY ] && pass "K1: MC_FAILED_BATCH=0: mc_fbh_apply holds nothing" || fail "K1: rc=$RC state=$STATE"
mc_fbh_apply; RC=$?
[ "$RC" = 0 ] && [ "$STATE" = WAIT_CI ] && pass "K1: the switch on: the same head is held" || fail "K1: rc=$RC state=$STATE why=$WHY"
# A moved head whose patch-id cannot be read: wait this tick, nothing remembered.
HEAD=4444444444444444444444444444444444444444; STATE=READY
fbh_append "$(fbh_file example-org/cromford 8129)" "$MC_FAILED_BATCH_NOW" "$H1" pidX failed CHECKS_FAILED 900 ci
mc_fbh_apply; RC=$?
[ "$RC" = 0 ] && [ "$STATE" = WAIT_CI ] && case "$WHY" in *"could not be read this tick"*) true ;; *) false ;; esac \
  && pass "K2: an unreadable patch-id waits one tick" || fail "K2: rc=$RC state=$STATE why=$WHY"
grep -q '^fbhsame ' "$MC_ATTEMPTS" && fail "K2: an unjudged compare was remembered" || pass "K2: ...and nothing is remembered"

# ---- A: mc_fbh_apply's other exits --------------------------------------------
# apply_case <num> — a fresh PR <num> at a moved head H4, READY.
H4=5555555555555555555555555555555555555555
apply_case() { NUM="$1"; KEY="$SLUG#$NUM"; HEAD="$H4"; STATE=READY; WHY=x; : > "$LOG"; }
# A1 — pending, and the payload is still unreadable: one more tick of WAIT_CI.
apply_case 8130
fbh_append "$(fbh_file "$SLUG" 8130)" "$MC_FAILED_BATCH_NOW" "$H1" - pending - - -
mc_rest_var() { printf -v "$1" '%s' ""; return 75; }
mc_fbh_apply; RC=$?
[ "$RC" = 0 ] && [ "$STATE" = WAIT_CI ] && [ "$(fbh_live "$(fbh_file "$SLUG" 8130)" | cut -f4)" = pending ] \
  && pass "A1: a pending record whose payload is still unread holds, and stays pending" || fail "A1: rc=$RC state=$STATE record=$(cat "$(fbh_file "$SLUG" 8130)")"
# A2 — pending, and the payload is a manual dequeue: cleared, not held.
apply_case 8131
fbh_append "$(fbh_file "$SLUG" 8131)" "$MC_FAILED_BATCH_NOW" "$H1" - pending - - -
mc_rest_var() { printf -v "$1" '%s' "$(arr "$(cmt 7 2026-10-23T05:10:00Z 2026-10-23T05:10:00Z dequeued PR_MANUALLY_DEQUEUED "$H1" 900 ci)")"; }
mc_fbh_apply; RC=$?
[ "$RC" = 1 ] && [ "$STATE" = READY ] && [ "$(tail -1 "$(fbh_file "$SLUG" 8131)" | cut -f4)" = cleared:not-counted ] \
  && pass "A2: a pending record that reads as a manual dequeue is cleared:not-counted" || fail "A2: rc=$RC state=$STATE record=$(cat "$(fbh_file "$SLUG" 8131)")"
# A3 — the patch-ids differ, but patch_same proves a clean main merge: held, and remembered.
apply_case 8132
fbh_append "$(fbh_file "$SLUG" 8132)" "$MC_FAILED_BATCH_NOW" "$H1" pid-old failed CHECKS_FAILED 900 ci
echo pid-new > "$(mc_patch_id_file "" "$SLUG" 8132 "$H4")"
: > "$T/git.txt"
mc_git_locked() { shift; echo "$*" >> "$T/git.txt"; [ "$1" = mc_patch_same ] && return 0; return 1; }
mc_fbh_apply; RC=$?
[ "$RC" = 0 ] && [ "$STATE" = WAIT_CI ] && case "$WHY" in *"carries the same patch"*) true ;; *) false ;; esac \
  && pass "A3: a clean-main-merge head (mc_patch_same rc 0) is held" || fail "A3: rc=$RC state=$STATE why=$WHY"
grep -qx "fbhsame $KEY $H4 $H1 1" "$MC_ATTEMPTS" && pass "A3: the answer is remembered (fbhsame ... 1)" || fail "A3: no fbhsame line"
: > "$T/git.txt"; STATE=READY
mc_fbh_apply
[ ! -s "$T/git.txt" ] && [ "$STATE" = WAIT_CI ] && pass "A3: a second tick asks git nothing" || fail "A3: git asked again ($(cat "$T/git.txt"))"
# A4 — the git lock cannot be had: wait, nothing remembered.
apply_case 8133
fbh_append "$(fbh_file "$SLUG" 8133)" "$MC_FAILED_BATCH_NOW" "$H1" pid-old failed CHECKS_FAILED 900 ci
echo pid-new > "$(mc_patch_id_file "" "$SLUG" 8133 "$H4")"
mc_git_locked() { return 99; }
mc_fbh_apply; RC=$?
[ "$RC" = 0 ] && [ "$STATE" = WAIT_CI ] && case "$WHY" in *"could not be read this tick"*) true ;; *) false ;; esac \
  && ! grep -q "^fbhsame $KEY " "$MC_ATTEMPTS" && pass "A4: a git lock timeout waits and remembers nothing" || fail "A4: rc=$RC state=$STATE why=$WHY"
# A4b — mc_patch_same could not fetch (rc 1, unjudged): wait, nothing remembered, never cleared:new-patch.
apply_case 8137
fbh_append "$(fbh_file "$SLUG" 8137)" "$MC_FAILED_BATCH_NOW" "$H1" pid-old failed CHECKS_FAILED 900 ci
echo pid-new > "$(mc_patch_id_file "" "$SLUG" 8137 "$H4")"
mc_git_locked() { MC_PATCH_SAME_UNJUDGED=1; return 1; }
mc_fbh_apply; RC=$?
[ "$RC" = 0 ] && [ "$STATE" = WAIT_CI ] && [ "$(fbh_live "$(fbh_file "$SLUG" 8137)" | cut -f4)" = failed ] \
  && ! grep -q "^fbhsame $KEY " "$MC_ATTEMPTS" && pass "A4b: a fetch failure (mc_patch_same rc 1, unjudged) waits, remembers nothing, keeps the record" || fail "A4b: rc=$RC state=$STATE why=$WHY record=$(cat "$(fbh_file "$SLUG" 8137)")"
# A4c — patch_same judged a different patch (rc 1, judged): remembered as 0, cleared:new-patch.
apply_case 8138
fbh_append "$(fbh_file "$SLUG" 8138)" "$MC_FAILED_BATCH_NOW" "$H1" pid-old failed CHECKS_FAILED 900 ci
echo pid-new > "$(mc_patch_id_file "" "$SLUG" 8138 "$H4")"
mc_git_locked() { MC_PATCH_SAME_UNJUDGED=0; return 1; }
mc_fbh_apply; RC=$?
[ "$(tail -1 "$(fbh_file "$SLUG" 8138)" | cut -f4)" = cleared:new-patch ] && grep -qx "fbhsame $KEY $H4 $H1 0" "$MC_ATTEMPTS" \
  && pass "A4c: a judged different patch (rc 1) is cleared:new-patch and remembered" || fail "A4c: rc=$RC state=$STATE record=$(cat "$(fbh_file "$SLUG" 8138)")"
# A5 — the solo re-run reproduces: BLOCKED_HUMAN, the reason names its suites.
apply_case 8134
fbh_append "$(fbh_file "$SLUG" 8134)" "$MC_FAILED_BATCH_NOW" "$H1" pid-old failed CHECKS_FAILED 900 ci
echo pid-old > "$(mc_patch_id_file "" "$SLUG" 8134 "$H4")"
bs_batch() { BS_SUITES=tests/a-test.sh; printf '8134 %s reproduces\n' "$H4"; }
mc_fbh_apply; RC=$?
[ "$RC" = 0 ] && [ "$STATE" = BLOCKED_HUMAN ] && case "$WHY" in "prequeue-red: tests/a-test.sh (failed in batch #900"*) true ;; *) false ;; esac \
  && pass "A5: a reproduced failure parks prequeue-red with the solo suites" || fail "A5: rc=$RC state=$STATE why=$WHY"
unset -f bs_batch
# A6 — a record that cannot be written: one UNRECORDED line, the caller goes on.
mc_rest_var() { printf -v "$1" '%s' "$(arr "$(cmt 7 2026-10-23T05:10:00Z 2026-10-23T05:10:00Z dequeued CHECKS_FAILED "$H1" 900 ci)")"; }
: > "$LOG"; mkdir -p "$(fbh_file "$SLUG" 8135).tmp.$$"
mc_fbh_record "$SLUG" proj "$SLUG#8135" u "$H1"; RC=$?
[ "$RC" = 0 ] && grep -q "FAILED_BATCH_UNRECORDED $SLUG#8135 $H1" "$LOG" && pass "A6: an unwritable record logs FAILED_BATCH_UNRECORDED and returns 0" || fail "A6: rc=$RC log=$(cat "$LOG")"

echo "mc-failed-batch.bh-8186: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
