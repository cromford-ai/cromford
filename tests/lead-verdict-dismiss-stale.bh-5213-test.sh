#!/bin/bash
# tests/lead-verdict-dismiss-stale.bh-5213-test.sh — BH-5213: a lead BLOCK
# review left standing after a later lead MERGE kept PRs out of the Mergify
# queue (#changes-requested-reviews-by=0) for ever (#4952, #4070, #4679).
# Driven through the REAL bin/lead-verdict.sh post, bin/lead-stale-review-sweep.sh
# and bin/pipeline-health.sh section 13d, against a stub GitHub (gh) and a stub
# jobs worker (curl). No real GitHub call is made.
#   D1  MERGE on H dismisses the lane's own CHANGES_REQUESTED on G != H, and the
#       message names the old head, the new head and the verdict row
#   D2  a person's CHANGES_REQUESTED is never dismissed (even one quoting the
#       marker), nor a bot review without the marker; the lane's own AT H is
#       (BH-6548: a lead MERGE on H supersedes it)
#   D3  BLOCK on H dismisses nothing and reads no reviews
#   D4  a second lead MERGE on H reads the reviews again (BH-6548: mode verdict
#       keeps no clean flag) and finds nothing left to dismiss
#   D5  a refused dismissal never changes post's exit, says so, and the next
#       MERGE post retries it; LV_DISMISS_STALE=0 reads nothing
#   D6  the sweep dismisses exactly the eligible fixtures; --dry-run writes nothing
#   D7  pipeline-health 13d names a PR blocked only by a stale bot review
#       `stale-review`, and keeps the generic page otherwise
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-dismiss-stale.bh-5213-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

G=$(printf 'a%.0s' {1..40})   # the BLOCKed head
HD=$(printf 'b%.0s' {1..40})  # the fixed head the MERGE is about
SLUG=example-org/demo-os
H="$T/h"; mkdir -p "$H/bin" "$H/catalog" "$H/state" "$T/fakebin" "$T/log" "$T/tmp" "$T/gh"
for s in bin/lead-verdict.sh bin/lead-stale-review-sweep.sh bin/jobs-client.sh bin/lib/lead-reviews.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
[ -r "$H/bin/lib/lead-stale-review.sh" ] || bad "the closure of bin/lead-verdict.sh does not carry bin/lib/lead-stale-review.sh"
cp "$DIR/catalog/lead-protected-paths.tsv" "$H/catalog/"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET; url=""; prev=""
for a in "$@"; do
  [ "$prev" = -X ] && m="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$m ${url#https://jobs.test}" in
  "POST /api/verdicts") printf '%s\n%s' '{"verdict":{"id":42,"repo":"example-org/demo-os","pr":7,"head_sha":"x","verdict":"MERGE","source":"lead","created_at":"2026-10-07T00:00:00Z"}}' 201 ;;
  *) printf '%s\n%s' '{"value":null}' 200 ;;
esac
EOF
# The stub GitHub. pulls/<n> -> head @T@/gh/head-<n> (default the fixed head);
# pulls/<n>/reviews -> @T@/gh/reviews-<n>.json; a dismissal PUT logs its message
# and marks the review DISMISSED (status from @T@/gh/dismiss-status); the open
# PR list -> @T@/gh/prs.json; commits/<sha>/status -> @T@/gh/status-<sha>.json.
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
    case "$path" in *"page=1"|*"page=1&"*) ;; *) reply 200 '[]' ;; esac
    if [ -f "$rf" ]; then reply 200 "$(cat "$rf")"; else reply 200 '[]'; fi ;;
  "GET repos/"*"/pulls?"*) reply 200 "$(cat "@T@/gh/prs.json")" ;;
  "GET repos/"*"/pulls/"*)
    h="@HD@"; [ -f "@T@/gh/head-$n" ] && h=$(cat "@T@/gh/head-$n")
    reply 200 "{\"head\":{\"sha\":\"$h\"}}" ;;
  "GET repos/"*"/commits/"*"/status")
    s=$(printf '%s' "$path" | sed -nE 's#.*/commits/([0-9a-f]+)/status$#\1#p')
    [ -f "@T@/gh/status-$s.json" ] && reply 200 "$(cat "@T@/gh/status-$s.json")"
    reply 200 '{"state":"pending","statuses":[]}' ;;
  "POST repos/"*"/statuses/"*) reply 201 '{"id":1}' ;;
esac
reply 404 '{"message":"Not Found"}'
EOF
sed -i.bak "s#@T@#$T#g; s#@HD@#$HD#g" "$T/fakebin/curl" "$T/fakebin/gh" && rm -f "$T/fakebin"/*.bak
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
printf 'lead-test-token\n' > "$T/tok"; chmod 600 "$T/tok"
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BOX=testbox TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok" GH_ETAG=0
unset LV_DISMISS_STALE LEAD_REVIEW_BOT_LOGINS

MARK='<!-- lead-review:lr-1 -->'
BOT='{"login":"cromford[bot]","type":"Bot"}'
PERSON='{"login":"operator","type":"User"}'
# rv <id> <user-json> <commit> <state> <body> -> one review object
rv() { jq -nc --argjson i "$1" --argjson u "$2" --arg c "$3" --arg s "$4" --arg b "$5" \
  '{id:$i, user:$u, commit_id:$c, state:$s, body:$b}'; }
fixtures() { # fixtures <pr> -> the D1/D2 reviews on that PR
  jq -sc . > "$T/gh/reviews-$1.json" <<EOF
$(rv 1 "$BOT" "$G" CHANGES_REQUESTED "$MARK
Lead review of ${G:0:12}
- [BLOCK] the retry loop never stops")
$(rv 2 "$PERSON" "$G" CHANGES_REQUESTED "$MARK quoted by a person: please rename this")
$(rv 3 "$BOT" "$G" CHANGES_REQUESTED "a bot review with no lead marker")
$(rv 4 "$BOT" "$HD" CHANGES_REQUESTED "$MARK
a lead BLOCK on the very head")
$(rv 5 "$BOT" "$G" COMMENTED "$MARK
a comment, not a block")
EOF
}
reset() { rm -rf "$T/log" "$T/gh"; scratch_rm "$H/state/lead-stale-review"; mkdir -p "$T/log" "$T/gh"; : > "$T/log/gh"; }
lv() { bash "$H/bin/lead-verdict.sh" "$@" > "$T/out" 2> "$T/err"; RC=$?; }
puts()    { grep -c '^PUT ' "$T/log/gh"; }
revgets() { grep -c '^GET repos/[^ ]*/pulls/[0-9]*/reviews' "$T/log/gh"; }
state()   { jq -r --argjson i "$2" '.[] | select(.id == $i) | .state' "$T/gh/reviews-$1.json"; }

# ── D1 + D2: MERGE on HD dismisses review 1 (own, marker, on G) and nothing else ──
reset; fixtures 7
lv post "$SLUG" 7 "$HD" MERGE --source lead --reviewer box:hub
[ "$RC" = 0 ] && ok || bad "D1 post rc=$RC: $(cat "$T/out" "$T/err")"
[ "$(state 7 1)" = DISMISSED ] && ok || bad "D1 the lane's own BLOCK review on G was not dismissed: $(cat "$T/log/gh")"
# TEST-CHANGE BH-6548: a lead MERGE on HD now also dismisses review 4 (own BLOCK AT HD)
[ "$(puts)" = 2 ] && ok || bad "D1/D2 want exactly two dismissals, got $(puts): $(grep '^PUT' "$T/log/gh")"
MSG=$(sed -n 's/^1 //p' "$T/log/dismissed-7" 2>/dev/null)
case "$MSG" in *"${G:0:12}"*) ok ;; *) bad "D1 the message does not name the old head ${G:0:12}: $MSG" ;; esac
case "$MSG" in *"${HD:0:12}"*) ok ;; *) bad "D1 the message does not name the new head ${HD:0:12}: $MSG" ;; esac
case "$MSG" in *"#42"*) ok ;; *) bad "D1 the message does not name the verdict row #42: $MSG" ;; esac
case "$MSG" in *MERGE*) ok ;; *) bad "D1 the message does not name the verdict: $MSG" ;; esac
# TEST-CHANGE BH-6548: two dismissals (reviews 1 and 4)
grep -q 'dismissed 2 stale lead BLOCK review' "$T/err" && ok || bad "D1 the dismissal is not reported: $(cat "$T/err")"
[ "$(state 7 2)" = CHANGES_REQUESTED ] && ok || bad "D2 a person's review was dismissed"
[ "$(state 7 3)" = CHANGES_REQUESTED ] && ok || bad "D2 a bot review with no lead marker was dismissed"
# TEST-CHANGE BH-6548: the lane's own BLOCK AT the merged head is now dismissed
[ "$(state 7 4)" = DISMISSED ] && ok || bad "D2 a lead MERGE on HD did not dismiss the lane's own review AT HD (BH-6548)"
[ "$(state 7 5)" = COMMENTED ] && ok || bad "D2 a COMMENT review was touched"
# MERGE-WITH-NOTES does the same
reset; fixtures 7
lv post "$SLUG" 7 "$HD" MERGE-WITH-NOTES --source lead --reviewer box:hub
# TEST-CHANGE BH-6548: two dismissals (reviews 1 and 4)
[ "$RC" = 0 ] && [ "$(state 7 1)" = DISMISSED ] && [ "$(puts)" = 2 ] && ok || bad "D1 MERGE-WITH-NOTES rc=$RC puts=$(puts)"
# a human-run MERGE on a PR with ONLY a person's review dismisses nothing
reset; jq -sc . > "$T/gh/reviews-7.json" <<EOF
$(rv 2 "$PERSON" "$G" CHANGES_REQUESTED "$MARK please rename this")
EOF
lv post "$SLUG" 7 "$HD" MERGE --source lead --reviewer box:hub
[ "$RC" = 0 ] && [ "$(puts)" = 0 ] && [ "$(state 7 2)" = CHANGES_REQUESTED ] && ok || bad "D2 a person-only PR: rc=$RC puts=$(puts)"

# ── D3: BLOCK on HD dismisses nothing and reads no reviews ──
reset; fixtures 7
lv post "$SLUG" 7 "$HD" BLOCK --source lead --reviewer box:hub
[ "$RC" = 0 ] && ok || bad "D3 post rc=$RC: $(cat "$T/out" "$T/err")"
[ "$(puts)" = 0 ] && [ "$(revgets)" = 0 ] && ok || bad "D3 a BLOCK dismissed ($(puts)) or read reviews ($(revgets))"
[ "$(state 7 1)" = CHANGES_REQUESTED ] && ok || bad "D3 the BLOCK review is gone"

# ── D4: a second MERGE on the same head reads again and dismisses nothing ──
reset; fixtures 7
lv post "$SLUG" 7 "$HD" MERGE --source lead --reviewer box:hub
: > "$T/log/gh"
lv post "$SLUG" 7 "$HD" MERGE --source lead --reviewer box:hub
[ "$RC" = 0 ] && ok || bad "D4 second post rc=$RC"
# TEST-CHANGE BH-6548: mode verdict keeps no clean flag, so the second lead MERGE reads
[ "$(puts)" = 0 ] && [ "$(revgets)" -ge 1 ] && ok || bad "D4 the second MERGE dismissed or did not read: $(cat "$T/log/gh")"
# ...and with the clean flag gone it reads, finds nothing left, dismisses nothing
scratch_rm "$H/state/lead-stale-review"; : > "$T/log/gh"
lv post "$SLUG" 7 "$HD" MERGE --source lead --reviewer box:hub
[ "$RC" = 0 ] && [ "$(puts)" = 0 ] && [ "$(revgets)" -ge 1 ] && ok || bad "D4 rerun puts=$(puts) reads=$(revgets)"
grep -q 'dismissed' "$T/err" && bad "D4 a rerun reported a dismissal: $(cat "$T/err")" || ok

# ── D5: a refused dismissal is one stderr line, never the exit; the next post heals ──
reset; fixtures 7; echo 500 > "$T/gh/dismiss-status"
lv post "$SLUG" 7 "$HD" MERGE --source lead --reviewer box:hub
[ "$RC" = 0 ] && ok || bad "D5 a refused dismissal changed the exit to $RC"
grep -q 'not all dismissed' "$T/err" && ok || bad "D5 the refusal is silent: $(cat "$T/err")"
[ "$(state 7 1)" = CHANGES_REQUESTED ] && ok || bad "D5 the review reads dismissed after a 500"
FLAGS=0; for fl in "$H"/state/lead-stale-review/clean-*; do [ -e "$fl" ] && FLAGS=$((FLAGS + 1)); done
[ "$FLAGS" = 0 ] && ok || bad "D5 a failed pass was flagged clean"
rm -f "$T/gh/dismiss-status"
lv post "$SLUG" 7 "$HD" MERGE --source lead --reviewer box:hub
[ "$RC" = 0 ] && [ "$(state 7 1)" = DISMISSED ] && ok || bad "D5 the next MERGE post did not retry the dismissal"
reset; fixtures 7
LV_DISMISS_STALE=0 lv post "$SLUG" 7 "$HD" MERGE --source lead --reviewer box:hub
[ "$RC" = 0 ] && [ "$(puts)" = 0 ] && [ "$(revgets)" = 0 ] && ok || bad "D5 LV_DISMISS_STALE=0 still read ($(revgets)) or dismissed ($(puts))"

# ── D6: the sweep dismisses exactly the eligible fixtures ──
reset
sha() { local s="$1$1$1$1"; s="$s$s"; s="$s$s$s$s$s"; printf '%s' "$s"; }
# pr <n> <head-char> [draft]
PRS=""
pr() { PRS="$PRS${PRS:+,}$(jq -nc --argjson n "$1" --arg h "$(sha "$2")" --argjson d "${3:-false}" '{number:$n, draft:$d, head:{sha:$h}}')"; }
lvst() { # lvst <head-char> <state> [description]
  jq -nc --arg s "$2" --arg d "${3:-MERGE-WITH-NOTES by box:hub (verdict #916)}" \
    '{state:$s, statuses:[{context:"ci/x", state:"success"}, {context:"lead-verdict", state:$s, description:$d}]}' > "$T/gh/status-$(sha "$1").json"
}
own_old() { rv "$2" "$BOT" "$(sha "$3")" CHANGES_REQUESTED "$MARK
- [BLOCK] stale"; }
# 10: green, own stale BLOCK -> dismissed
pr 10 c; lvst c success; jq -sc . > "$T/gh/reviews-10.json" <<EOF
$(own_old 10 101 0)
EOF
# 11: green, only a person's CHANGES_REQUESTED -> untouched
pr 11 d; lvst d success; jq -sc . > "$T/gh/reviews-11.json" <<EOF
$(rv 111 "$PERSON" "$(sha 0)" CHANGES_REQUESTED "$MARK please rename")
EOF
# 12: lead-verdict failure, own stale BLOCK -> untouched
pr 12 e; lvst e failure "BLOCK by box:hub (verdict #9)"; jq -sc . > "$T/gh/reviews-12.json" <<EOF
$(own_old 12 121 0)
EOF
# 13: no lead-verdict status at all -> untouched
pr 13 f; jq -sc . > "$T/gh/reviews-13.json" <<EOF
$(own_old 13 131 0)
EOF
# 14: a draft, green -> untouched
pr 14 1 true; lvst 1 success; jq -sc . > "$T/gh/reviews-14.json" <<EOF
$(own_old 14 141 0)
EOF
# 15: green, the lane's own BLOCK AT the head -> untouched
pr 15 2; lvst 2 success; jq -sc . > "$T/gh/reviews-15.json" <<EOF
$(own_old 15 151 2)
EOF
# 16: green from the conductor (no verdict row in the description), own stale -> dismissed
pr 16 3; lvst 3 success "harness verdict cleared 333333333333 for the queue"; jq -sc . > "$T/gh/reviews-16.json" <<EOF
$(own_old 16 161 0)
EOF
printf '[%s]' "$PRS" > "$T/gh/prs.json"
cp -r "$T/gh" "$T/gh.orig"
bash "$H/bin/lead-stale-review-sweep.sh" --dry-run "$SLUG" > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "D6 dry-run rc=$RC: $(cat "$T/err")"
[ "$(puts)" = 0 ] && ok || bad "D6 --dry-run dismissed: $(grep '^PUT' "$T/log/gh")"
[ "$(grep -c 'would dismiss' "$T/out")" = 2 ] && grep -q "^$SLUG#10 would dismiss review 101 " "$T/out" && grep -q "^$SLUG#16 would dismiss review 161 " "$T/out" \
  && ok || bad "D6 dry-run listed the wrong set: $(cat "$T/out")"
: > "$T/log/gh"
bash "$H/bin/lead-stale-review-sweep.sh" "$SLUG" > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "D6 sweep rc=$RC: $(cat "$T/err")"
DIS=$(grep '^PUT' "$T/log/gh" | sed -nE 's#.*/pulls/([0-9]+)/reviews/([0-9]+)/dismissals$#\1:\2#p' | sort | paste -sd' ')
[ "$DIS" = "10:101 16:161" ] && ok || bad "D6 the sweep dismissed '$DIS' (want '10:101 16:161')"
grep -q "^$SLUG#10 dismissed 101 000000000000 (head cccccccccccc, MERGE-WITH-NOTES, #916)" "$T/out" \
  && ok || bad "D6 the sweep's line for #10 does not name the review, both heads and the row: $(cat "$T/out")"
grep -q 'verdict row #916' "$T/log/dismissed-10" && ok || bad "D6 the dismissal message does not name verdict row #916: $(cat "$T/log/dismissed-10" 2>/dev/null)"
for p in 11:111 12:121 13:131 14:141 15:151; do
  [ "$(state "${p%:*}" "${p#*:}")" = CHANGES_REQUESTED ] && ok || bad "D6 #${p%:*} review ${p#*:} was dismissed"
done
grep -q 'GET repos/[^ ]*/commits/1111' "$T/log/gh" && bad "D6 a draft PR cost a status read" || ok
bash "$H/bin/lead-stale-review-sweep.sh" > /dev/null 2>&1; [ $? = 2 ] && ok || bad "D6 no repo is not usage (2)"

# ── D7: pipeline-health 13d names the stale-review reason ──
PH="$DIR/bin/pipeline-health.sh"
awk '/^# >>> lead merge unqueued \(BH-3778\)/{f=1;next} /^# <<< lead merge unqueued/{exit} f' "$PH" > "$T/block.sh"
[ -s "$T/block.sh" ] || bad "D7 no lead merge unqueued block in bin/pipeline-health.sh"
NOW=$(date -u +%s); OLD=$(date -u -d "@$((NOW - 3600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((NOW - 3600))" +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$T/ph"
jq -nc --arg c "$(sha c)" --arg d "$(sha d)" '[{number:21, draft:false, head:{sha:$c}, base:{ref:"main", repo:{default_branch:"main"}}, labels:[{name:"merge-queue"}]},
  {number:22, draft:false, head:{sha:$d}, base:{ref:"main", repo:{default_branch:"main"}}, labels:[{name:"merge-queue"}]}]' > "$T/ph/list.json"
jq -nc --arg u "$OLD" '{state:"success", statuses:[{context:"lead-verdict", state:"success", updated_at:$u}]}' > "$T/ph/status.json"
jq -sc . > "$T/ph/reviews-21.json" <<EOF
$(own_old 21 211 0)
EOF
jq -sc . > "$T/ph/reviews-22.json" <<EOF
$(rv 221 "$PERSON" "$(sha 0)" CHANGES_REQUESTED "please rename")
EOF
mkdir -p "$T/phbin"
cat > "$T/phbin/gh" <<EOF
#!/bin/bash
case "\$*" in
  "api repos/$SLUG/pulls?state=open&per_page=100") cat "$T/ph/list.json" ;;
  "api repos/$SLUG/commits/"*"/status") cat "$T/ph/status.json" ;;
  "api repos/$SLUG/pulls/21/reviews?per_page=100") cat "$T/ph/reviews-21.json" ;;
  "api repos/$SLUG/pulls/22/reviews?per_page=100") cat "$T/ph/reviews-22.json" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/phbin/gh"
( export PATH="$T/phbin:$PATH" LEAD_REVIEW_AUTO_REPOS="$SLUG"
  . "$H/bin/lib/lead-stale-review.sh"
  NOW="$NOW"; FIRED="$T/ph/fired"; ACTIVE="$T/ph/active"; : > "$FIRED"; : > "$ACTIVE"
  gh_budget_low() { return 1; }
  alert() { printf '%s|%s\n' "$2" "$3" >> "$T/ph/alerts"; }
  # shellcheck disable=SC1090,SC1091
  . "$T/block.sh" ) > "$T/ph/out" 2>&1
grep -q "^leadunqueued:$SLUG#21:cccccccccccc:stale-review|$SLUG #21 reason=stale-review: .*211@000000000000" "$T/ph/alerts" 2>/dev/null \
  && ok || bad "D7 #21 must page reason=stale-review naming review 211: $(cat "$T/ph/alerts" "$T/ph/out" 2>/dev/null)"
grep -q "^leadunqueued:$SLUG#22:dddddddddddd|$SLUG #22 has lead-verdict success" "$T/ph/alerts" 2>/dev/null \
  && ok || bad "D7 #22 (a person's review only) must keep the generic page: $(cat "$T/ph/alerts" 2>/dev/null)"
grep -q "#22.*stale-review" "$T/ph/alerts" 2>/dev/null && bad "D7 a person's review was called a stale bot review" || ok

echo "lead-verdict-dismiss-stale.bh-5213: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
