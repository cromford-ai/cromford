#!/bin/bash
# tests/lead-verdict-same-head.bh-6548-test.sh — BH-6548: a MERGE verdict posted
# through bin/lead-verdict.sh by source human or lead dismissed the lane's own
# bot BLOCK reviews on OLDER heads only. A bot BLOCK on the SAME head stayed
# CHANGES_REQUESTED, so Mergify (#changes-requested-reviews-by=0) never queued
# the PR (#6134 review 5507427606, #6321 review 5507897822).
# Driven through the REAL bin/lead-verdict.sh post against a stub GitHub (gh)
# and a stub jobs worker (curl). No real GitHub call is made.
#   S1   human MERGE-WITH-NOTES on HD dismisses the bot BLOCK on HD and on G;
#        the HD message names the verdict row, the verdict, the head, BH-6548
#   S1b  human MERGE does the same
#   S2   a person's review, a User-type account named like the bot, a bot
#        review without the marker, a COMMENTED and an APPROVED bot review on
#        HD are never dismissed; the bot BLOCK on HD is
#   S3   a refused dismissal (HTTP 500) is one stderr line naming the review
#        and the status, never the exit; the next post retries it
#   S3b  an unreadable reviews list (HTTP 502) is one stderr line, no PUT
#   S3c  a lib that does not load is one stderr line, never the exit
#   S4   a lead MERGE that publishes dismisses both
#   S5   a risk-tier MERGE keeps the old rule: older head only
#   S6   a human BLOCK reads no reviews and dismisses nothing
#   S7   a second human MERGE on the same head reads again (no clean flag)
#        and dismisses a bot BLOCK posted on that head after the first
#   S7b  a clean flag a risk-tier pass wrote on the head does not stop it
#   S8   lsr_stale output for the 2-argument, merge and verdict forms
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-same-head.bh-6548-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

G=$(printf 'a%.0s' {1..40})   # an older, BLOCKed head
HD=$(printf 'b%.0s' {1..40})  # the head the MERGE verdict is about
SLUG=example-org/demo-os
H="$T/h"; mkdir -p "$H/bin" "$H/catalog" "$H/state" "$T/fakebin" "$T/log" "$T/tmp" "$T/gh"
install_tree() {
  local s
  for s in bin/lead-verdict.sh bin/jobs-client.sh; do
    scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
  done
}
install_tree
[ -r "$H/bin/lib/lead-stale-review.sh" ] || bad "the closure of bin/lead-verdict.sh does not carry bin/lib/lead-stale-review.sh"
# BH-4148: the lead reads its protected paths from the jobs worker route (rows),
# with catalog/lead-protected-paths.seed.tsv as the floor. demo-os has no rows,
# so it is not governed, as it was under the old catalog file.
cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$H/catalog/"
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$T/lpp.json" example-org/demo-os
lpp_install "$T/fakebin" "$T/lpp.json" "$T/lpp-down"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET; url=""; prev=""
for a in "$@"; do
  [ "$prev" = -X ] && m="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$m ${url#https://jobs.test}" in
  *"/api/lead-protected-paths"*) "$(dirname "$0")/lpp-answer" "$m" "$url"; exit 0 ;;
  "POST /api/verdicts"*) printf '%s\n%s' '{"verdict":{"id":42,"repo":"example-org/demo-os","pr":7,"head_sha":"x","verdict":"MERGE","source":"human","created_at":"2026-10-13T00:00:00Z"},"human_verified":true}' 201 ;;
  *) printf '%s\n%s' '{"value":null}' 200 ;;
esac
EOF
# The stub GitHub. pulls/<n> -> head HD; pulls/<n>/reviews -> @T@/gh/reviews-<n>.json
# (status from @T@/gh/revget-status); a dismissal PUT logs its message and marks
# the review DISMISSED (status from @T@/gh/dismiss-status).
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
m=GET; path=""; prev=""; msg=""
for a in "$@"; do
  [ "$prev" = -X ] && m="$a"
  case "$prev" in -f|-F) case "$a" in message=*) msg="${a#message=}" ;; esac ;; esac
  case "$a" in repos/*) path="$a" ;; esac
  prev="$a"
done
printf '%s %s\n' "$m" "$path" >> "@T@/log/gh"
reply() { printf 'HTTP/1.1 %s X\r\n\r\n%s\n' "$1" "$2"; exit 0; }
n=$(printf '%s' "$path" | sed -nE 's#^repos/[^/]+/[^/]+/pulls/([0-9]+).*#\1#p')
rf="@T@/gh/reviews-$n.json"
case "$m $path" in
  "PUT repos/"*"/dismissals")
    rid=$(printf '%s' "$path" | sed -nE 's#.*/reviews/([0-9]+)/dismissals$#\1#p')
    st=200; [ -f "@T@/gh/dismiss-status" ] && st=$(cat "@T@/gh/dismiss-status")
    case "$st" in 2*) ;; *) reply "$st" '{"message":"boom"}' ;; esac
    printf '%s %s\n' "$rid" "$msg" >> "@T@/log/dismissed-$n"
    jq -c --argjson i "$rid" 'map(if .id == $i then .state = "DISMISSED" else . end)' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    reply 200 '{"state":"DISMISSED"}' ;;
  "GET repos/"*"/pulls/"*"/reviews"*)
    [ -f "@T@/gh/revget-status" ] && reply "$(cat "@T@/gh/revget-status")" '{"message":"bad gateway"}'
    case "$path" in *"page=1"|*"page=1&"*) ;; *) reply 200 '[]' ;; esac
    if [ -f "$rf" ]; then reply 200 "$(cat "$rf")"; else reply 200 '[]'; fi ;;
  "GET repos/"*"/pulls/"*) reply 200 "{\"head\":{\"sha\":\"@HD@\"}}" ;;
  "GET repos/"*"/commits/"*"/status") reply 200 '{"state":"pending","statuses":[]}' ;;
  "POST repos/"*"/statuses/"*) reply 201 '{"id":1}' ;;
esac
reply 404 '{"message":"Not Found"}'
EOF
sed -i.bak "s#@T@#$T#g; s#@HD@#$HD#g" "$T/fakebin/curl" "$T/fakebin/gh" && rm -f "$T/fakebin"/*.bak
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
printf 'lead-fixture-token\n' > "$T/tok"; chmod 600 "$T/tok"
printf 'fixture-human-token\n' > "$T/htok"; chmod 600 "$T/htok"
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BOX=testbox TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok" \
  HUMAN_VERDICT_TOKEN_FILE="$T/htok" GH_ETAG=0
unset LV_DISMISS_STALE LEAD_REVIEW_BOT_LOGINS

MARK='<!-- lead-review:lr-1 -->'
BOT='{"login":"cromford[bot]","type":"Bot"}'
PERSON='{"login":"operator","type":"User"}'
FAKEBOT='{"login":"cromford[bot]","type":"User"}'
# rv <id> <user-json> <commit> <state> <body> -> one review object
rv() { jq -nc --argjson i "$1" --argjson u "$2" --arg c "$3" --arg s "$4" --arg b "$5" \
  '{id:$i, user:$u, commit_id:$c, state:$s, body:$b}'; }
s1_reviews() { # the S1 pair: the bot BLOCK on HD (id 1) and on G (id 2)
  rv 1 "$BOT" "$HD" CHANGES_REQUESTED "$MARK
- [BLOCK] a lead BLOCK on the very head"
  rv 2 "$BOT" "$G" CHANGES_REQUESTED "$MARK
- [BLOCK] a lead BLOCK on an older head"
}
s1() { s1_reviews | jq -sc . > "$T/gh/reviews-7.json"; }
s2_reviews() {
  rv 21 "$PERSON" "$HD" CHANGES_REQUESTED "$MARK quoted by a person on the head"
  rv 22 "$PERSON" "$G" CHANGES_REQUESTED "a person's review on an older head"
  rv 23 "$FAKEBOT" "$HD" CHANGES_REQUESTED "$MARK from a User account named like the bot"
  rv 24 "$BOT" "$HD" CHANGES_REQUESTED "a bot review with no lead marker"
  rv 25 "$BOT" "$HD" COMMENTED "$MARK
a comment, not a block"
  rv 26 "$BOT" "$HD" APPROVED "$MARK
an approval"
  rv 27 "$BOT" "$HD" CHANGES_REQUESTED "$MARK
- [BLOCK] the control"
}
reset() { rm -rf "$T/log" "$T/gh"; scratch_rm "$H/state/lead-stale-review"; mkdir -p "$T/log" "$T/gh"; : > "$T/log/gh"; }
lv() { bash "$H/bin/lead-verdict.sh" "$@" > "$T/out" 2> "$T/err"; RC=$?; }
puts()    { grep -c '^PUT ' "$T/log/gh"; }
revgets() { grep -c '^GET repos/[^ ]*/pulls/[0-9]*/reviews' "$T/log/gh"; }
state()   { jq -r --argjson i "$2" '.[] | select(.id == $i) | .state' "$T/gh/reviews-$1.json"; }

# ── S1: human MERGE-WITH-NOTES on HD dismisses the bot BLOCK on HD and on G ──
reset; s1
lv post "$SLUG" 7 "$HD" MERGE-WITH-NOTES --source human --reviewer operator
[ "$RC" = 0 ] && ok || bad "S1 post rc=$RC: $(cat "$T/out" "$T/err")"
[ "$(state 7 1)" = DISMISSED ] && ok || bad "S1 the bot BLOCK on the verdict head was not dismissed: $(state 7 1)"
[ "$(state 7 2)" = DISMISSED ] && ok || bad "S1 the bot BLOCK on the older head was not dismissed: $(state 7 2)"
[ "$(puts)" = 2 ] && ok || bad "S1 want 2 dismissals, got $(puts): $(grep '^PUT' "$T/log/gh")"
MSG=$(sed -n 's/^1 //p' "$T/log/dismissed-7" 2>/dev/null)
for w in "#42" MERGE-WITH-NOTES "${HD:0:12}" BH-6548; do
  case "$MSG" in *"$w"*) ok ;; *) bad "S1 the same-head message does not name '$w': $MSG" ;; esac
done
grep -q 'dismissed 2 ' "$T/err" && ok || bad "S1 the 2 dismissals are not reported: $(cat "$T/err")"

# ── S1b: human MERGE does the same ──
reset; s1
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && [ "$(state 7 1)" = DISMISSED ] && [ "$(state 7 2)" = DISMISSED ] && [ "$(puts)" = 2 ] \
  && ok || bad "S1b human MERGE rc=$RC puts=$(puts) id1=$(state 7 1) id2=$(state 7 2)"

# ── S2: only the bot's own marked BLOCK on HD is dismissed ──
reset; s2_reviews | jq -sc . > "$T/gh/reviews-8.json"
lv post "$SLUG" 8 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && ok || bad "S2 post rc=$RC: $(cat "$T/err")"
[ "$(state 8 27)" = DISMISSED ] && ok || bad "S2 the control (bot BLOCK on HD) was not dismissed: $(state 8 27)"
for p in 21:CHANGES_REQUESTED 22:CHANGES_REQUESTED 23:CHANGES_REQUESTED 24:CHANGES_REQUESTED 25:COMMENTED 26:APPROVED; do
  [ "$(state 8 "${p%:*}")" = "${p#*:}" ] && ok || bad "S2 review ${p%:*} changed to $(state 8 "${p%:*}") (want ${p#*:})"
done
[ "$(puts)" = 1 ] && ok || bad "S2 want 1 dismissal, got $(puts): $(grep '^PUT' "$T/log/gh")"

# ── S3: a refused PUT is one stderr line, never the exit; the next post retries ──
reset; s1; echo 500 > "$T/gh/dismiss-status"
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && ok || bad "S3 a refused dismissal changed the exit to $RC"
grep -q 'not all dismissed' "$T/err" && grep -q 'HTTP 500' "$T/err" && ok || bad "S3 the refusal is not reported with its status: $(cat "$T/err")"
grep -q 'failed 1 ' "$T/err" && ok || bad "S3 the failure line does not name review 1: $(cat "$T/err")"
[ "$(state 7 1)" = CHANGES_REQUESTED ] && ok || bad "S3 the review reads dismissed after a 500"
rm -f "$T/gh/dismiss-status"
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && [ "$(state 7 1)" = DISMISSED ] && ok || bad "S3 the next post did not retry: rc=$RC id1=$(state 7 1)"

# ── S3b: an unreadable reviews list is one stderr line, no PUT ──
reset; s1; echo 502 > "$T/gh/revget-status"
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && [ "$(puts)" = 0 ] && ok || bad "S3b rc=$RC puts=$(puts)"
grep -q 'not all dismissed' "$T/err" && grep -q 'HTTP 502' "$T/err" && ok || bad "S3b the unreadable list is not reported: $(cat "$T/err")"

# ── S3c: a lib that does not load is one stderr line ──
reset; s1; rm -f "$H/bin/lib/lead-stale-review.sh"
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && ok || bad "S3c a missing lib changed the exit to $RC"
grep -q 'lead-stale-review.sh did not load' "$T/err" && ok || bad "S3c a missing lib is silent: $(cat "$T/err")"
install_tree

# ── S4: a lead MERGE that publishes dismisses both ──
reset; s1
lv post "$SLUG" 7 "$HD" MERGE --source lead --reviewer box:hub
[ "$RC" = 0 ] && [ "$(state 7 1)" = DISMISSED ] && [ "$(state 7 2)" = DISMISSED ] && [ "$(puts)" = 2 ] \
  && ok || bad "S4 lead MERGE rc=$RC puts=$(puts) id1=$(state 7 1) id2=$(state 7 2): $(cat "$T/err")"

# ── S5: a risk-tier MERGE dismisses the older head only ──
reset; s1
lv post "$SLUG" 7 "$HD" MERGE --source risk-tier --note "risk-tier low (fixture)"
[ "$RC" = 0 ] && ok || bad "S5 post rc=$RC: $(cat "$T/err")"
[ "$(state 7 2)" = DISMISSED ] && [ "$(state 7 1)" = CHANGES_REQUESTED ] && [ "$(puts)" = 1 ] \
  && ok || bad "S5 risk-tier puts=$(puts) id1=$(state 7 1) id2=$(state 7 2)"

# ── S6: a human BLOCK reads nothing and dismisses nothing ──
reset; s1
lv post "$SLUG" 7 "$HD" BLOCK --source human --reviewer operator
[ "$RC" = 0 ] && [ "$(puts)" = 0 ] && [ "$(revgets)" = 0 ] && ok || bad "S6 BLOCK rc=$RC puts=$(puts) reads=$(revgets)"
[ "$(state 7 1)" = CHANGES_REQUESTED ] && [ "$(state 7 2)" = CHANGES_REQUESTED ] && ok || bad "S6 a BLOCK dismissed a review"

# ── S7: a second MERGE on the same head reads again and dismisses a new BLOCK ──
reset; s1
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
jq -c --argjson r "$(rv 3 "$BOT" "$HD" CHANGES_REQUESTED "$MARK
- [BLOCK] a re-review on the same head")" '. + [$r]' "$T/gh/reviews-7.json" > "$T/gh/r.tmp" && mv "$T/gh/r.tmp" "$T/gh/reviews-7.json"
: > "$T/log/gh"
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && [ "$(revgets)" -ge 1 ] && ok || bad "S7 the second post did not read the reviews: rc=$RC reads=$(revgets)"
[ "$(state 7 3)" = DISMISSED ] && ok || bad "S7 the new same-head BLOCK was not dismissed: $(state 7 3)"

# ── S7b: a clean flag from a risk-tier pass on the head does not stop a human MERGE ──
reset; s1
lv post "$SLUG" 7 "$HD" MERGE --source risk-tier --note "risk-tier low (fixture)"
FLAGS=0; for fl in "$H"/state/lead-stale-review/clean-*; do [ -e "$fl" ] && FLAGS=$((FLAGS + 1)); done
[ "$FLAGS" = 1 ] && [ "$(state 7 1)" = CHANGES_REQUESTED ] && ok || bad "S7b the risk-tier pass did not flag the head clean ($FLAGS) or dismissed id 1"
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && [ "$(state 7 1)" = DISMISSED ] && ok || bad "S7b the clean flag stopped the human MERGE: rc=$RC id1=$(state 7 1)"

# ── S8: lsr_stale output for the three call forms ──
{ s1_reviews; s2_reviews; } | jq -sc . > "$T/s8.json"
( . "$H/bin/lib/lead-stale-review.sh" || exit 1
  lsr_stale "$T/s8.json" "$HD" > "$T/s8.two"
  lsr_stale "$T/s8.json" "$HD" "" "" merge > "$T/s8.merge"
  lsr_stale "$T/s8.json" "$HD" "" "" verdict > "$T/s8.verdict" ) || bad "S8 the lib did not load"
TAB=$'\t'
[ "$(cat "$T/s8.two")" = "2${TAB}$G" ] && ok || bad "S8 the 2-argument form changed: $(cat "$T/s8.two")"
[ "$(cat "$T/s8.merge")" = "2${TAB}$G${TAB}older" ] && ok || bad "S8 the merge form changed: $(cat "$T/s8.merge")"
[ "$(sort "$T/s8.verdict" | paste -sd'|' -)" = "1${TAB}$HD${TAB}same|2${TAB}$G${TAB}older|27${TAB}$HD${TAB}same" ] \
  && ok || bad "S8 the verdict form is wrong: $(cat "$T/s8.verdict")"

echo "lead-verdict-same-head.bh-6548: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
