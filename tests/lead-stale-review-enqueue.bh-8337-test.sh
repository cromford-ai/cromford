#!/bin/bash
# tests/lead-stale-review-enqueue.bh-8337-test.sh — BH-8337: the conductor's
# lead-verdict publish (mc_enqueue_mergify) cleared #8278 for the queue on
# 7afeb74 and left the lane's own CHANGES_REQUESTED review on 0470a06 standing,
# so Mergify's #changes-requested-reviews-by=0 held the PR until a person
# dismissed it by hand. Driven through the REAL mc_enqueue_mergify against a
# stub GitHub (gh) and a stub jobs worker (curl). No real GitHub call is made.
#   A1  a MERGE enqueue on S makes ONE dismissal PUT (r1), before the label POST
#   A2  its message names S (12 chars) and the verdict row job:<id>
#   A3  the PUT runs under the App token
#   A4  one `dismissed` conductor log line, for r1 only
#   A5  r2 (person quoting the marker), r3 (bot at S), r4 (no marker),
#       r5 (already DISMISSED), r6 (another bot) get no PUT
#   A6  a BLOCK ledger word reads no reviews and dismisses nothing
#   A7  a refused publish reads no reviews; the rc is the bh-3348 E2/E3 rc
#   A8  r1 on page 2 of the reviews is dismissed
#   A9  a refused PUT keeps the rc, logs one NOT dismissed line, writes no
#       flag, and the next enqueue PUTs again
#   A10 a clean pass writes the lead-verdict.sh clean flag; a flag (either
#       writer) skips every read
#   A11 the hook writes nothing to stdout or stderr; MC_DISMISS_STALE_LEAD=0
#       reads nothing
# Each case uses its own PR number and its own stub dir.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-stale-review-enqueue.bh-8337-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-os
A=aaaaaaaa11111111111111111111111111111111   # the BLOCKed head
S=bbbbbbbb22222222222222222222222222222222   # the head being queued
mkdir -p "$T/fakebin" "$T/tmp"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

# The stub gh. $GHD is the case's dir: calls (every call, with the token it ran
# under), reviews-<page>.json, status-code (default 201), put-code (default 200).
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s GH_TOKEN=%s\n' "$*" "${GH_TOKEN:-}" >> "$GHD/calls"
case "$*" in
  *"api -i -X GET repos/"*"/pulls/"[0-9]*"/reviews?"*)
    p=$(printf '%s' "$*" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p')
    if [ -f "$GHD/reviews-$p.json" ]; then restpr --raw 200 "$(cat "$GHD/reviews-$p.json")"; else restpr --raw 200 '[]'; fi ;;
  *"api -i -X PUT repos/"*"/dismissals"*)
    restpr --raw "$(cat "$GHD/put-code" 2>/dev/null || echo 200)" '{"id":1,"state":"DISMISSED"}' ;;
  *"api -i -X POST repos/"*"/statuses/"*)
    restpr --raw "$(cat "$GHD/status-code" 2>/dev/null || echo 201)" '{"id":1}' ;;
  *"api -X POST repos/"*"/labels"*) exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"unknown endpoint"}\n404\n'
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

# The conductor lib and its whole closure (gh-rest, gh-app-auth,
# verdict-status, the mc modules), so the guarded $MC_H sources resolve.
H="$T/h"; mkdir -p "$H/logs" "$H/state"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$H" >/dev/null || { echo "closure install of bin/lib/merge-conductor-lib.sh failed"; exit 1; }
for f in gh-rest verdict-status gh-app-auth; do
  [ -r "$H/bin/lib/$f.sh" ] || { echo "the closure of bin/lib/merge-conductor-lib.sh does not carry bin/lib/$f.sh"; exit 1; }
done
# The hook's lazy source must be one the closure scan follows, or a box sync
# that ships the conductor's closure would ship it without the dismissal.
[ -r "$H/bin/lib/lead-stale-review.sh" ] && ok || bad "A0 the closure of bin/lib/merge-conductor-lib.sh carries bin/lib/lead-stale-review.sh"
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  TMPDIR="$T/tmp" GH_APP_TOKENS=0 GH_ETAG=0
unset GH_TOKEN LEAD_VERDICT_CONTEXT MC_DISMISS_STALE_LEAD LEAD_REVIEW_BOT_LOGINS

BOT='{"login":"cromford[bot]","type":"Bot"}'
MARK='<!-- lead-review:req-1 --> lead BLOCK findings'
rv() { # rv <id> <user-json> <state> <body> <commit>
  jq -nc --arg id "$1" --argjson u "$2" --arg st "$3" --arg b "$4" --arg c "$5" \
    '{id:($id|tonumber), user:$u, state:$st, body:$b, commit_id:$c}'
}
fixture() { # the six reviews of the plan, as one page
  printf '[%s]' "$(IFS=,; echo "$(rv 9001 "$BOT" CHANGES_REQUESTED "$MARK" "$A"),$(rv 9002 '{"login":"operator","type":"User"}' CHANGES_REQUESTED "quoting: $MARK" "$A"),$(rv 9003 "$BOT" CHANGES_REQUESTED "$MARK" "$S"),$(rv 9004 "$BOT" CHANGES_REQUESTED 'plain words, no marker' "$A"),$(rv 9005 "$BOT" DISMISSED "$MARK" "$A"),$(rv 9006 '{"login":"mergify[bot]","type":"Bot"}' CHANGES_REQUESTED "$MARK" "$A")")"
}
newcase() { # newcase <name> -> sets GHD; fresh stub dir, witness on
  GHD="$T/case-$1"; export GHD; mkdir -p "$GHD"; : > "$GHD/calls"; touch "$GHD/witness"
}
flagof() { printf '%s/state/lead-stale-review/clean-%s-%s-%s' "$H" "$(printf '%s' "$SLUG" | tr 'A-Z/' 'a-z_')" "$1" "$2"; }

# enq <pr> [word]: the real mc_enqueue_mergify; the queue reads, the ledger and
# the lead authority (tests/lead-authority.bh-3683 pins it) are stubbed, the App
# token is `app-token-test`.
enq() { (
  . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  mc_mergify_command() { return 0; }
  mc_queue_state() { printf 'queued'; }
  mc_mergify_witness() { [ -f "$GHD/witness" ]; }
  gh_auth_for() { export GH_TOKEN=app-token-test; return 0; }
  la_decide() { return 0; }; mc_la_decide() { return 0; }
  job_verdict() { printf '%s\t1\tlead\t-\tjob-77\t%s' "$JV_WORD" "$S"; }
  JV_WORD="${2:-MERGE}" MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 \
    mc_enqueue_mergify "$SLUG" "https://github.com/$SLUG/pull/$1" "$S"
) 2>"$GHD/enq.err"; }
puts() { grep -c -- '-X PUT .*/dismissals' "$GHD/calls"; }
reads() { grep -c -- '-X GET .*/reviews?' "$GHD/calls"; }
log() { grep -- "$SLUG#$1 " "$H/logs/merge-conductor.log" 2>/dev/null; }

# ---- A1-A5: the fixture PR, MERGE on S ----
newcase a1; fixture > "$GHD/reviews-1.json"
enq 101 > "$GHD/out"; RC=$?
[ "$RC" = 0 ] && ok || bad "A1 a witnessed enqueue stays rc 0 (rc $RC, err $(cat "$GHD/enq.err"))"
[ "$(puts)" = 1 ] && grep -q -- "-X PUT repos/$SLUG/pulls/101/reviews/9001/dismissals" "$GHD/calls" && ok \
  || bad "A1 exactly one dismissal PUT, for r1 (9001): $(grep -- '-X PUT' "$GHD/calls")"
P=$(grep -n -- '/reviews/9001/dismissals' "$GHD/calls" | head -1 | cut -d: -f1)
LB=$(grep -n -- "-X POST repos/$SLUG/issues/101/labels" "$GHD/calls" | head -1 | cut -d: -f1)
[ -n "$P" ] && [ -n "$LB" ] && [ "$P" -lt "$LB" ] && ok || bad "A1 the dismissal PUT (line ${P:-none}) comes before the label POST (line ${LB:-none})"
L=$(grep -- '/reviews/9001/dismissals' "$GHD/calls")
grep -q -- "${S:0:12}" <<<"$L" && grep -q -- 'job:job-77' <<<"$L" && grep -q -- '-f event=DISMISS' <<<"$L" && ok \
  || bad "A2 the message names S and the verdict row job:job-77: $L"
grep -q 'GH_TOKEN=app-token-test$' <<<"$L" && ok || bad "A3 the PUT runs under the App token: $L"
[ "$(log 101 | grep -c 'dismissed 9001')" = 1 ] && [ "$(log 101 | grep -c 'dismissed')" = 1 ] && ok \
  || bad "A4 one conductor log line, for r1 only: $(log 101)"
for r in 9002 9003 9004 9005 9006; do
  grep -q -- "/reviews/$r/dismissals" "$GHD/calls" && bad "A5 review $r must not be dismissed" || ok
done
grep -qE '900[2-6]' <<<"$(log 101)" && bad "A4 no log line for r2-r6: $(log 101)" || ok

# ---- A6: the ledger word is BLOCK ----
newcase a6; fixture > "$GHD/reviews-1.json"
enq 106 BLOCK >/dev/null
[ "$(puts)" = 0 ] && [ "$(reads)" = 0 ] && ok || bad "A6 BLOCK reads no reviews (reads $(reads)) and PUTs nothing (puts $(puts))"

# ---- A7: the publish is refused ----
newcase a7; fixture > "$GHD/reviews-1.json"; echo 422 > "$GHD/status-code"
OUT=$(enq 107); RC=$?
[ "$RC" = 0 ] && [ "$(puts)" = 0 ] && [ "$(reads)" = 0 ] && ok \
  || bad "A7 a refused publish, witnessed: rc 0, no reads, no PUT (rc $RC, reads $(reads), puts $(puts))"
newcase a7b; fixture > "$GHD/reviews-1.json"; echo 422 > "$GHD/status-code"; rm -f "$GHD/witness"
OUT=$(enq 117); RC=$?
[ "$RC" = 3 ] && grep -q 'lead-verdict status could not be published' <<<"$OUT" && [ "$(reads)" = 0 ] && ok \
  || bad "A7 a refused publish, no witness: rc 3 as in bh-3348 E2, no reads (rc $RC, out $OUT, reads $(reads))"

# ---- A8: r1 on page 2 ----
newcase a8
jq -nc '[range(0;100) | {id:(8000+.), user:{login:"cromford[bot]",type:"Bot"}, state:"APPROVED", body:"ok", commit_id:"x"}]' > "$GHD/reviews-1.json"
printf '[%s]' "$(rv 9001 "$BOT" CHANGES_REQUESTED "$MARK" "$A")" > "$GHD/reviews-2.json"
enq 108 >/dev/null
grep -q -- "/pulls/108/reviews/9001/dismissals" "$GHD/calls" && [ "$(puts)" = 1 ] && ok || bad "A8 r1 on page 2 is dismissed: $(grep -- '-X PUT' "$GHD/calls")"

# ---- A9: the PUT is refused ----
newcase a9; fixture > "$GHD/reviews-1.json"; echo 403 > "$GHD/put-code"
enq 109 >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "A9 a refused dismissal keeps rc 0 (rc $RC)"
[ "$(log 109 | grep -c 'NOT dismissed.*9001.*HTTP 403')" = 1 ] && ok || bad "A9 one NOT dismissed ... HTTP 403 log line: $(log 109)"
[ -e "$(flagof 109 "$S")" ] && bad "A9 a refused dismissal writes no clean flag" || ok
rm -f "$GHD/put-code"; enq 109 >/dev/null
[ "$(puts)" = 2 ] && ok || bad "A9 the next enqueue PUTs again (puts $(puts))"
[ -e "$(flagof 109 "$S")" ] && ok || bad "A9 the retry that succeeds writes the flag"

# ---- A10: the clean flag ----
newcase a10; fixture > "$GHD/reviews-1.json"
enq 110 >/dev/null
[ -e "$(flagof 110 "$S")" ] && ok || bad "A10 a clean pass writes the flag at $(flagof 110 "$S")"
: > "$GHD/calls"; enq 110 >/dev/null
[ "$(reads)" = 0 ] && [ "$(puts)" = 0 ] && ok || bad "A10 a flagged head reads nothing (reads $(reads))"
newcase a10b; fixture > "$GHD/reviews-1.json"
mkdir -p "$H/state/lead-stale-review"; : > "$(flagof 120 "$S")"   # the lead-verdict.sh writer
enq 120 >/dev/null
[ "$(reads)" = 0 ] && [ "$(puts)" = 0 ] && ok || bad "A10 a flag lead-verdict.sh wrote also skips (reads $(reads))"

# ---- A11: silence, and the switch ----
newcase a11e   # no reviews at all
enq 131 > "$GHD/out"; RC0=$?; cp "$GHD/enq.err" "$T/err0"; OUT0=$(sed 's/131/N/g' "$GHD/out")
newcase a11; fixture > "$GHD/reviews-1.json"
enq 132 > "$GHD/out"; RC1=$?; OUT1=$(sed 's/132/N/g' "$GHD/out")
[ "$(puts)" = 1 ] && [ "$RC0" = "$RC1" ] && [ "$OUT0" = "$OUT1" ] && ok \
  || bad "A11 the stdout and rc with a dismissal match the no-review run (rc $RC0/$RC1, out '$OUT0' vs '$OUT1')"
[ "$(cat "$GHD/enq.err")" = "$(cat "$T/err0")" ] && ok || bad "A11 the hook adds no stderr: $(cat "$GHD/enq.err")"
newcase a11s; fixture > "$GHD/reviews-1.json"
( export MC_DISMISS_STALE_LEAD=0; enq 133 >/dev/null )
[ "$(reads)" = 0 ] && [ "$(puts)" = 0 ] && ok || bad "A11 MC_DISMISS_STALE_LEAD=0 reads nothing (reads $(reads))"

echo "lead-stale-review-enqueue (BH-8337): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
