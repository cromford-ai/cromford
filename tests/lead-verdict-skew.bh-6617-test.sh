#!/bin/bash
# tests/lead-verdict-skew.bh-6617-test.sh — BH-6617: on #6472 a human MERGE on
# head 72584ef8b321 dismissed the bot BLOCK on the older head only. The bot
# BLOCK on the same head (review 5507704685) stayed CHANGES_REQUESTED until a
# person dismissed it by hand. main already dismisses it (BH-6548), so the post
# came from a checkout that predates BH-6548, and it failed silently.
# Driven through the REAL bin/lead-verdict.sh post against a stub GitHub (gh)
# and a stub jobs worker (curl). No real GitHub call is made.
#   K1   a human MERGE post sends x-lead-verdict-client: 4, so the worker row
#        lead_verdict_min_client 4 can refuse a pre-BH-6548 checkout
#   K2   sourcing bin/lib/lead-stale-review.sh sets LSR_MODES with verdict
#   K3   a lib with no LSR_MODES (pre-BH-6548): rc 0, one stderr line names the
#        skew and the head, the lib gets the 5-argument call, no clean flag
#   K3b  the same with LSR_MODES='merge block'
#   K4   the real lib: the bot BLOCK on the head and on an older head are
#        dismissed, a person's review on the head is not, no skew line
#   K5   a risk-tier MERGE with the old lib: no skew line, 5 arguments
#   K6   a human BLOCK reads no reviews and dismisses nothing
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-skew.bh-6617-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
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
# real_lib — put the real lib back over a stub (the closure install skips a file that exists)
real_lib() { rm -f "$H/bin/lib/lead-stale-review.sh"; install_tree; }
# TEST-CHANGE BH-4148: the lead reads protected paths from the jobs route; the demo
# repo has no rows, so it is not governed, as under the old catalog file.
cp "$REPO_DIR/catalog/lead-protected-paths.seed.tsv" "$H/catalog/"
. "$REPO_DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$T/lpp.json" "$SLUG"
lpp_install "$T/fakebin" "$T/lpp.json" "$T/lpp-down"

# The stub worker. A POST /api/verdicts copies the client-level line of its
# header file (-H @file) to @T@/log/client; the secrets in that file are never read.
cat > "$T/fakebin/curl" <<'EOF2'
#!/bin/bash
m=GET; url=""; prev=""
for a in "$@"; do
  [ "$prev" = -X ] && m="$a"
  [ "$prev" = -H ] && case "$a" in @*) grep '^x-lead-verdict-client:' "${a#@}" >> "@T@/log/client" ;; esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$m ${url#https://jobs.test}" in
  *"/api/lead-protected-paths"*) "$(dirname "$0")/lpp-answer" "$m" "$url"; exit 0 ;;
  "POST /api/verdicts"*) printf '%s\n%s' '{"verdict":{"id":42,"repo":"example-org/demo-os","pr":7,"head_sha":"x","verdict":"MERGE","source":"human","created_at":"2026-10-14T00:00:00Z"},"human_verified":true}' 201 ;;
  *) printf '%s\n%s' '{"value":null}' 200 ;;
esac
EOF2
# The stub GitHub, as in tests/lead-verdict-same-head.bh-6548-test.sh.
cat > "$T/fakebin/gh" <<'EOF2'
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
    printf '%s %s\n' "$rid" "$msg" >> "@T@/log/dismissed-$n"
    jq -c --argjson i "$rid" 'map(if .id == $i then .state = "DISMISSED" else . end)' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    reply 200 '{"state":"DISMISSED"}' ;;
  "GET repos/"*"/pulls/"*"/reviews"*)
    case "$path" in *"page=1"|*"page=1&"*) ;; *) reply 200 '[]' ;; esac
    if [ -f "$rf" ]; then reply 200 "$(cat "$rf")"; else reply 200 '[]'; fi ;;
  "GET repos/"*"/pulls/"*) reply 200 "{\"head\":{\"sha\":\"@HD@\"}}" ;;
  "GET repos/"*"/commits/"*"/status") reply 200 '{"state":"pending","statuses":[]}' ;;
  "POST repos/"*"/statuses/"*) reply 201 '{"id":1}' ;;
esac
reply 404 '{"message":"Not Found"}'
EOF2
sed -i.bak "s#@T@#$T#g; s#@HD@#$HD#g" "$T/fakebin/curl" "$T/fakebin/gh" && rm -f "$T/fakebin"/*.bak
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
printf 'lead-fixture-token\n' > "$T/tok"; chmod 600 "$T/tok"
printf 'fixture-human-token\n' > "$T/htok"; chmod 600 "$T/htok"
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BOX=testbox TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok" \
  HUMAN_VERDICT_TOKEN_FILE="$T/htok" GH_ETAG=0
unset LV_DISMISS_STALE LEAD_REVIEW_BOT_LOGINS LSR_MODES

MARK='<!-- lead-review:lr-1 -->'
BOT='{"login":"cromford[bot]","type":"Bot"}'
PERSON='{"login":"operator","type":"User"}'
rv() { jq -nc --argjson i "$1" --argjson u "$2" --arg c "$3" --arg s "$4" --arg b "$5" \
  '{id:$i, user:$u, commit_id:$c, state:$s, body:$b}'; }
reviews() { # bot BLOCK on HD (1), bot BLOCK on G (2), a person's CHANGES_REQUESTED on HD (3)
  { rv 1 "$BOT" "$HD" CHANGES_REQUESTED "$MARK
- [BLOCK] a lead BLOCK on the very head"
    rv 2 "$BOT" "$G" CHANGES_REQUESTED "$MARK
- [BLOCK] a lead BLOCK on an older head"
    rv 3 "$PERSON" "$HD" CHANGES_REQUESTED "a person's review on the head"; } | jq -sc . > "$T/gh/reviews-7.json"
}
# old_lib [<LSR_MODES line>] — a lead-stale-review.sh as a checkout before
# BH-6548 had it, reduced to what lv_dismiss_stale reads: it records its argc.
old_lib() {
  { [ -n "${1:-}" ] && printf '%s\n' "$1"
    cat <<EOF2
lsr_dismiss_stale() {
  echo "\$#" > "$T/log/argc"
  LSR_DISMISSED=1; LSR_FAILED=0
  echo "dismissed 2 ${G:0:12}"
  return 0
}
EOF2
  } > "$H/bin/lib/lead-stale-review.sh"
}
reset() { rm -rf "$T/log" "$T/gh"; scratch_rm "$H/state/lead-stale-review"; mkdir -p "$T/log" "$T/gh"; : > "$T/log/gh"; }
lv() { bash "$H/bin/lead-verdict.sh" "$@" > "$T/out" 2> "$T/err"; RC=$?; }
puts()    { grep -c '^PUT ' "$T/log/gh"; }
revgets() { grep -c '^GET repos/[^ ]*/pulls/[0-9]*/reviews' "$T/log/gh"; }
state()   { jq -r --argjson i "$2" '.[] | select(.id == $i) | .state' "$T/gh/reviews-$1.json"; }
flags()   { local n=0 fl; for fl in "$H"/state/lead-stale-review/clean-*; do [ -e "$fl" ] && n=$((n + 1)); done; echo "$n"; }

# ── K1: a human MERGE post sends client level 4 ──
reset; reviews
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && ok || bad "K1 post rc=$RC: $(cat "$T/out" "$T/err")"
[ "$(cat "$T/log/client" 2>/dev/null)" = 'x-lead-verdict-client: 4' ] && ok \
  || bad "K1 the human post sends '$(cat "$T/log/client" 2>/dev/null)', want 'x-lead-verdict-client: 4'"

# ── K2: the lib declares the modes it honours ──
( unset LSR_MODES; . "$H/bin/lib/lead-stale-review.sh" || exit 1
  case " ${LSR_MODES:-} " in *" verdict "*) exit 0 ;; esac; exit 1 ) && ok \
  || bad "K2 sourcing bin/lib/lead-stale-review.sh does not set LSR_MODES with verdict"

# ── K3: a lib with no LSR_MODES: one skew line, 5-argument call, no flag ──
k3() {
  reset; reviews; old_lib "${1:-}"
  lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
  [ "$RC" = 0 ] && ok || bad "$2 post rc=$RC: $(cat "$T/err")"
  [ "$(grep -c 'predates BH-6548' "$T/err")" = 1 ] && ok || bad "$2 no single skew line: $(cat "$T/err")"
  L=$(grep 'predates BH-6548' "$T/err")
  for w in "${HD:0:12}" "$SLUG#7" "git pull" lead-stale-review.sh; do
    case "$L" in *"$w"*) ok ;; *) bad "$2 the skew line does not name '$w': $L" ;; esac
  done
  [ "$(cat "$T/log/argc" 2>/dev/null)" = 5 ] && ok || bad "$2 the lib got $(cat "$T/log/argc" 2>/dev/null) arguments, want 5"
  grep -q 'dismissed 1 stale lead BLOCK' "$T/err" && ok || bad "$2 the older-head dismissal is not reported: $(cat "$T/err")"
  [ "$(flags)" = 0 ] && ok || bad "$2 a clean flag was written on the skew path"
  real_lib
}
k3 "" K3
k3 "LSR_MODES='merge block'" K3b

# ── K4: the real lib dismisses both bot BLOCKs, keeps the person's, no skew line ──
reset; reviews
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && ok || bad "K4 post rc=$RC: $(cat "$T/err")"
[ "$(state 7 1)" = DISMISSED ] && [ "$(state 7 2)" = DISMISSED ] && ok \
  || bad "K4 id1=$(state 7 1) id2=$(state 7 2), want both DISMISSED"
[ "$(state 7 3)" = CHANGES_REQUESTED ] && ok || bad "K4 the person's review changed to $(state 7 3)"
grep -q 'predates' "$T/err" && bad "K4 the current lib reads as old: $(cat "$T/err")" || ok

# ── K5: a risk-tier MERGE with the old lib: mode merge as before, no skew line ──
reset; reviews; old_lib ""
lv post "$SLUG" 7 "$HD" MERGE --source risk-tier --note "risk-tier low (fixture)"
[ "$RC" = 0 ] && ok || bad "K5 post rc=$RC: $(cat "$T/err")"
grep -q 'predates' "$T/err" && bad "K5 a risk-tier post warned about the skew: $(cat "$T/err")" || ok
[ "$(cat "$T/log/argc" 2>/dev/null)" = 5 ] && ok || bad "K5 the lib got $(cat "$T/log/argc" 2>/dev/null) arguments, want 5"
real_lib

# ── K6: a human BLOCK reads nothing and dismisses nothing ──
reset; reviews
lv post "$SLUG" 7 "$HD" BLOCK --source human --reviewer operator
[ "$RC" = 0 ] && [ "$(puts)" = 0 ] && [ "$(revgets)" = 0 ] && ok || bad "K6 BLOCK rc=$RC puts=$(puts) reads=$(revgets)"

echo "lead-verdict-skew.bh-6617: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
