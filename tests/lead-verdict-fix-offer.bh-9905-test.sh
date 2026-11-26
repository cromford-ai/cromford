#!/bin/bash
# tests/lead-verdict-fix-offer.bh-9905-test.sh — BH-9905: after a BLOCK row is
# recorded with --source human|lead, bin/lead-verdict.sh post prints ONE line
# that says whether the blocked-resolver will offer a fix round, or why not
# (bin/lib/fix-round-offer.sh fro_offer_line). Driven through the REAL
# bin/lead-verdict.sh post against a stub GitHub (gh) and a stub jobs worker
# (curl). No real GitHub or worker call is made.
#   L1  no switch, no resolver state on this box -> "will be offered on the next
#       blocked-resolver tick (the cap is checked on the hub; ...)"; exit 0;
#       stdout is the row line only
#   L1b the same with a resolver state dir -> "will be offered on the next
#       blocked-resolver tick", no hub remark
#   L2  flags/blocked-resolver-disabled -> "not offered: blocked-resolver-disabled is on"
#   L3  flags/automerge-disabled -> the automerge reason; L3b the lane off for
#       the project; L3c BR_VERDICT_BLOCK=0
#   L4  the record holds the head in review_fix_heads -> "already ran"
#   L5  fixrounds at the cap -> "the fix-round cap is spent (2 of 2)"
#   L6  the switch reader cannot load -> "unknown", never "will be offered"
#   L7  MERGE, and BLOCK --source box, print no "fix round:" line
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-fix-offer.bh-9905-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/fix-round-offer.sh" ] || { echo "FAIL: bin/lib/fix-round-offer.sh is missing (BH-9905)"; FAIL=$((FAIL+1)); }

HD=$(printf 'c%.0s' {1..40})
SLUG=example-org/demo-os
URL="https://github.com/$SLUG/pull/7"
H="$T/h"; mkdir -p "$H/bin" "$H/catalog" "$H/state" "$H/flags" "$T/fakebin" "$T/log" "$T/tmp" "$T/w"
for s in bin/lead-verdict.sh bin/jobs-client.sh bin/lib/fix-round-offer.sh; do
  [ -r "$DIR/$s" ] || continue
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$H/bin/" || exit 1
printf 'demo-os %s - - 2 box-demo 192.0.2.7\n' "$SLUG" > "$H/fleet.conf"
cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$H/catalog/"
lpp_set "$T/lpp.json" "$SLUG"
lpp_install "$T/fakebin" "$T/lpp.json" "$T/lpp-down"

# The stub worker: POST /api/verdicts answers 201 with the posted row as #41;
# every other request is a 404 the jobs client reads as "none".
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET; url=""; prev=""; d=""
for a in "$@"; do
  [ "$prev" = -X ] && m="$a"
  [ "$prev" = --data-binary ] && d="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
printf '%s %s\n' "$m" "${url#https://jobs.test}" >> "@T@/log/worker"
case "$m ${url#https://jobs.test}" in
  *"/api/lead-protected-paths"*) "$(dirname "$0")/lpp-answer" "$m" "$url"; exit 0 ;;
  "POST /api/verdicts"*)
    printf '%s\n' "$d" >> "@T@/log/posted"
    printf '%s\n%s' "$(jq -c '{verdict:(. + {id:41,created_at:"2026-11-25T00:00:00Z"}), human_verified:(.source == "human"), human_final:null}' <<<"$d")" 201 ;;
  *) printf '%s\n%s' '{"error":"not found"}' 404 ;;
esac
EOF
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
m=GET; path=""; prev=""
for a in "$@"; do
  [ "$prev" = -X ] && m="$a"
  case "$a" in repos/*) path="$a" ;; esac
  prev="$a"
done
printf '%s %s %s\n' "$m" "$path" "$*" >> "@T@/log/gh"
reply() { printf 'HTTP/1.1 %s X\r\n\r\n%s\n' "$1" "$2"; exit 0; }
case "$m $path" in
  "GET repos/"*"/pulls/"*"/reviews"*) reply 200 '[]' ;;
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
export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BOX=testbox TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok" \
  HUMAN_VERDICT_TOKEN_FILE="$T/htok" GH_ETAG=0 GH_APP_TOKENS=0
unset LV_DISMISS_STALE LEAD_VERDICT_CONTEXT GH_TOKEN BR_VERDICT_BLOCK BR_REVIEW_FIX_ROUNDS

reset() {
  rm -rf "$T/log" "$T/w" "$H/state/blocked-resolver"; mkdir -p "$T/log" "$T/w"; : > "$T/log/gh"
  rm -f "$H/flags/"*
}
lv() { bash "$H/bin/lead-verdict.sh" "$@" > "$T/out" 2> "$T/err"; RC=$?; }
offer() { grep 'fix round:' "$T/err"; }
REC() { # REC <json> — one resolver record for this PR under the project's state dir
  mkdir -p "$H/state/blocked-resolver/demo-os"
  printf '%s\n' "$1" > "$H/state/blocked-resolver/demo-os/demo-os-DEMO-7.json"
}

# ── L1: no switch, no resolver state on this box ──
reset
lv post "$SLUG" 7 "$HD" BLOCK --source human --reviewer operator --note "rename the field"
[ "$RC" = 0 ] && ok || bad "L1 want exit 0 (as without the lib), got $RC: $(cat "$T/out" "$T/err")"
[ "$(offer | grep -c .)" = 1 ] && ok || bad "L1 want exactly one fix-round line: $(cat "$T/err")"
grep -qxF 'lead-verdict: fix round: will be offered on the next blocked-resolver tick (the cap is checked on the hub; this box holds no resolver state)' "$T/err" \
  && ok || bad "L1 the offer line: $(cat "$T/err")"
[ "$(grep -c . "$T/out")" = 1 ] && grep -q '^recorded verdict #41: BLOCK (human)' "$T/out" && ok || bad "L1 stdout is the row line only: $(cat "$T/out")"
# ── L1b: the same with the resolver's state dir on this box ──
reset; mkdir -p "$H/state/blocked-resolver/demo-os"
lv post "$SLUG" 7 "$HD" BLOCK --source lead --reviewer box:fixture
[ "$RC" = 0 ] && ok || bad "L1b want exit 0, got $RC: $(cat "$T/err")"
grep -qxF 'lead-verdict: fix round: will be offered on the next blocked-resolver tick' "$T/err" && ok || bad "L1b the offer line (lead): $(cat "$T/err")"
# ── L2: the lane's kill switch ──
reset; touch "$H/flags/blocked-resolver-disabled"
lv post "$SLUG" 7 "$HD" BLOCK --source human --reviewer operator
[ "$RC" = 0 ] && ok || bad "L2 want exit 0, got $RC"
grep -qxF 'lead-verdict: fix round: not offered: blocked-resolver-disabled is on' "$T/err" && ok || bad "L2 names the switch: $(cat "$T/err")"
# ── L3: the fleet automerge kill switch ──
reset; touch "$H/flags/automerge-disabled"
lv post "$SLUG" 7 "$HD" BLOCK --source human --reviewer operator
grep -qxF 'lead-verdict: fix round: not offered: the automerge kill switch (automerge-disabled) is on' "$T/err" && ok || bad "L3 names the automerge switch: $(cat "$T/err")"
# ── L3b: the lane is off for the project ──
reset; touch "$H/flags/lane-off-blocked-resolver-demo-os"
lv post "$SLUG" 7 "$HD" BLOCK --source human --reviewer operator
grep -qxF 'lead-verdict: fix round: not offered: the blocked-resolver lane is off for demo-os' "$T/err" && ok || bad "L3b names the lane switch: $(cat "$T/err")"
# ── L3c: the source knob ──
reset
BR_VERDICT_BLOCK=0 lv post "$SLUG" 7 "$HD" BLOCK --source human --reviewer operator
grep -qxF 'lead-verdict: fix round: not offered: BR_VERDICT_BLOCK is 0' "$T/err" && ok || bad "L3c names the knob: $(cat "$T/err")"
# ── L4: a round already ran on this head ──
reset
REC "$(jq -nc --arg u "$URL" --arg h "$HD" '{project:"demo-os",rkey:"demo-os-DEMO-7",fixrounds:1,outcome:"",review_fix_heads:[$h],attempts:[{action:"fix-round",url:$u}],rung_pr:$u}')"
lv post "$SLUG" 7 "$HD" BLOCK --source human --reviewer operator
grep -qxF "lead-verdict: fix round: not offered: a fix round already ran on ${HD:0:12}" "$T/err" && ok || bad "L4 already ran: $(cat "$T/err")"
# ── L5: the cap is spent ──
reset
REC "$(jq -nc --arg u "$URL" '{project:"demo-os",rkey:"demo-os-DEMO-7",fixrounds:2,outcome:"",review_fix_heads:["oldheadone","oldheadtwo"],rung_pr:$u}')"
lv post "$SLUG" 7 "$HD" BLOCK --source human --reviewer operator
grep -qxF 'lead-verdict: fix round: not offered: the fix-round cap is spent (2 of 2)' "$T/err" && ok || bad "L5 the cap: $(cat "$T/err")"
# A record for ANOTHER PR does not speak for this one.
reset
REC "$(jq -nc '{project:"demo-os",rkey:"demo-os-DEMO-7",fixrounds:2,outcome:"ABANDONED",rung_pr:"https://github.com/example-org/demo-os/pull/70"}')"
lv post "$SLUG" 7 "$HD" BLOCK --source human --reviewer operator
grep -qxF 'lead-verdict: fix round: will be offered on the next blocked-resolver tick' "$T/err" && ok || bad "L5b another PR's record is not this PR's cap: $(cat "$T/err")"
# ── L6: the switch reader cannot load ──
reset
mv "$H/bin/lib/lane-switch.sh" "$T/lane-switch.sh.away" 2>/dev/null
lv post "$SLUG" 7 "$HD" BLOCK --source human --reviewer operator
mv "$T/lane-switch.sh.away" "$H/bin/lib/lane-switch.sh" 2>/dev/null
[ "$RC" = 0 ] && ok || bad "L6 the exit code does not change, got $RC"
grep -qxF 'lead-verdict: fix round: unknown (could not read blocked-resolver-disabled)' "$T/err" && ok || bad "L6 unknown: $(cat "$T/err")"
grep -q 'will be offered' "$T/err" && bad "L6 never 'will be offered' on a read that failed: $(cat "$T/err")" || ok
# ── L7: only a lead/human BLOCK gets the line ──
reset
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && ok || bad "L7 MERGE exit 0, got $RC: $(cat "$T/err")"
grep -q 'fix round:' "$T/err" && bad "L7 a MERGE prints no fix-round line: $(cat "$T/err")" || ok
reset
lv post "$SLUG" 7 "$HD" BLOCK --source box --reviewer box:fixture
grep -q 'fix round:' "$T/err" && bad "L7 a box BLOCK prints no fix-round line: $(cat "$T/err")" || ok

echo "lead-verdict-fix-offer.bh-9905: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
