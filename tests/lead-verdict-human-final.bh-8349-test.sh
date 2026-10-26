#!/bin/bash
# tests/lead-verdict-human-final.bh-8349-test.sh — BH-8349: a human verdict on
# a head is final for that head. The jobs worker answers a source=lead post on
# such a head with human_final:{id,verdict}; bin/lead-verdict.sh post then
# publishes NO lead-verdict status, prints one `status withheld` line and exits 5.
# Driven through the REAL bin/lead-verdict.sh post against a stub GitHub (gh)
# and a stub jobs worker (curl). No real GitHub or worker call is made.
#   V1  lead BLOCK answered with human_final -> exit 5, one `is final on this
#       head` line, 0 statuses POSTs, the row line still printed
#   V2  the same post answered with human_final:null -> exit 0, one statuses
#       POST with state=failure (today's path)
#   V3  a --source human post whose answer carries human_final -> the status
#       is published as today (the rule is lead-only)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-human-final.bh-8349-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

HD=$(printf 'c%.0s' {1..40})
SLUG=example-org/demo-os
H="$T/h"; mkdir -p "$H/bin" "$H/catalog" "$H/state" "$T/fakebin" "$T/log" "$T/tmp" "$T/w"
for s in bin/lead-verdict.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$H/catalog/"
lpp_set "$T/lpp.json" example-org/demo-os
lpp_install "$T/fakebin" "$T/lpp.json" "$T/lpp-down"

# The stub worker: POST /api/verdicts answers 201 with the posted row as #31
# plus the human_final value in @T@/w/human-final (JSON; default null).
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET; url=""; prev=""; d=""
for a in "$@"; do
  [ "$prev" = -X ] && m="$a"
  [ "$prev" = --data-binary ] && d="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$m ${url#https://jobs.test}" in
  *"/api/lead-protected-paths"*) "$(dirname "$0")/lpp-answer" "$m" "$url"; exit 0 ;;
  "POST /api/verdicts"*)
    printf '%s\n' "$d" >> "@T@/log/posted"
    hf=null; [ -f "@T@/w/human-final" ] && hf=$(cat "@T@/w/human-final")
    printf '%s\n%s' "$(jq -c --argjson hf "$hf" '{verdict:(. + {id:31,created_at:"2026-10-25T00:00:00Z"}), human_verified:(.source == "human"), human_final:$hf}' <<<"$d")" 201 ;;
  *) printf '%s\n%s' '{"value":null}' 200 ;;
esac
EOF
# The stub GitHub: pulls/<n> -> head HD, an empty reviews list, statuses 201.
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
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BOX=testbox TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok" \
  HUMAN_VERDICT_TOKEN_FILE="$T/htok" GH_ETAG=0 GH_APP_TOKENS=0
unset LV_DISMISS_STALE LEAD_VERDICT_CONTEXT GH_TOKEN

reset() { rm -rf "$T/log" "$T/w"; mkdir -p "$T/log" "$T/w"; : > "$T/log/gh"; }
lv() { bash "$H/bin/lead-verdict.sh" "$@" > "$T/out" 2> "$T/err"; RC=$?; }
statuses() { grep -c '^POST repos/[^ ]*/statuses/' "$T/log/gh"; }

# ── V1: a lead BLOCK answered with human_final -> exit 5, no status ──
reset; printf '{"id":7,"verdict":"MERGE"}' > "$T/w/human-final"
lv post "$SLUG" 7 "$HD" BLOCK --source lead --reviewer box:fixture
[ "$RC" = 5 ] && ok || bad "V1 want exit 5, got $RC: $(cat "$T/out" "$T/err")"
[ "$(statuses)" = 0 ] && ok || bad "V1 want 0 statuses POSTs, got $(statuses): $(cat "$T/log/gh")"
[ "$(grep -c 'is final on this head' "$T/err")" = 1 ] && ok || bad "V1 want one 'is final on this head' line: $(cat "$T/err")"
grep -q "status withheld on ${HD:0:12}: human verdict #7 (MERGE) is final on this head" "$T/err" \
  && ok || bad "V1 the withheld line must name the human row and word: $(cat "$T/err")"
grep -q '^recorded verdict #31: BLOCK (lead)' "$T/out" && ok || bad "V1 the row line must still print: $(cat "$T/out")"
[ "$(grep -c . "$T/log/posted")" = 1 ] && ok || bad "V1 want one verdict POST"

# ── V2: the same post, human_final null -> today's path, status failure ──
reset
lv post "$SLUG" 7 "$HD" BLOCK --source lead --reviewer box:fixture
[ "$RC" = 0 ] && ok || bad "V2 want exit 0, got $RC: $(cat "$T/out" "$T/err")"
[ "$(statuses)" = 1 ] && ok || bad "V2 want 1 statuses POST, got $(statuses)"
grep -q '^POST repos/[^ ]*/statuses/.*state=failure' "$T/log/gh" && ok || bad "V2 the status must be failure: $(cat "$T/log/gh")"
grep -q 'is final on this head' "$T/err" && bad "V2 no withheld line without human_final: $(cat "$T/err")" || ok

# ── V3: a --source human post is never withheld by human_final ──
reset; printf '{"id":7,"verdict":"BLOCK"}' > "$T/w/human-final"
lv post "$SLUG" 7 "$HD" MERGE --source human --reviewer operator
[ "$RC" = 0 ] && ok || bad "V3 want exit 0, got $RC: $(cat "$T/out" "$T/err")"
[ "$(statuses)" = 1 ] && ok || bad "V3 want 1 statuses POST, got $(statuses)"
grep -q 'is final on this head' "$T/err" && bad "V3 a human post is never withheld: $(cat "$T/err")" || ok

echo "lead-verdict-human-final.bh-8349: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
