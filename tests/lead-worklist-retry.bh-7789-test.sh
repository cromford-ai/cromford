#!/bin/bash
# tests/lead-worklist-retry.bh-7789-test.sh — BH-7789: lw_items (bin/lib/lead-worklist.sh)
# reads the needs-review worklist, retries ONE failed read after a bounded
# wait, logs the HTTP status and the worker's error body, and records every
# read in state/lead-review/worklist-reads.tsv, which lw_pr_day_prune keeps
# for LW_READS_KEEP_DAYS days.
#
# Tick cases drive bin/lead-review.sh tick WHOLE on the BH-4956 fixture. A curl
# wrapper answers GET /api/pr-state/needs-review with 500 `error code: 1101`
# (or $FX/needs.<o_r>.code.<n> / .body.<n>) while $FX/needs.<o_r>.failn is
# above 0, and passes every other call to the fixture's curl.
#   R1  one 500 1101, then PR 101: two reads, /start 101, one retry line, TSV ok 2 http=200.
#   R2  two 500 1101: two reads, no /start, ONE line with http=500 and 1101,
#       the caller's `unreadable (rc=1)` line, TSV fail 2 http=500.
#   R2b two different bodies: both in the one line.  R2c a body with a newline: one line.
#   R3  no failure: one read, no retry line, TSV ok 1.  R4 rows: []: one read, no line, TSV none 1.
#   R7  404 (an old worker): two reads, the line names http=404.
# Unit cases source the lib with a stub pr_needs_review that writes a scripted
# status and body to $JOBS_STATUS_FILE / $JOBS_BODY_FILE and returns a scripted rc.
#   U1 503 overloaded, U2 curl_rc=28, U3 http=200 unparsable: two reads each.
#   U4 no-secret, U5 no-url: one read (a retry cannot change a config answer).
#   U6 rc 0 then the row jq fails: one read, rc 1, TSV status parse.
#   U7 rc 1 then rc 2: rc 2 and a retry line.  U8 the wait: unset = 2 s, abc and 11 read as 2,
#   0 and 10 are kept.  U9 an empty slug: rc 1, no read, no TSV line.
#   P1-P3 the prune: 7 days kept by default, LW_READS_KEEP_DAYS=abc reads 7, =1 drops
#   the 6-day line, no file is rc 0; started.tsv is still pruned.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-worklist-retry.bh-7789-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
SRC="$LWF_SRC"

mv "$T/fakebin/curl" "$T/fakebin/curl.fx"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
p="\${url#https://jobs.test}"
case "\$p" in
  /api/pr-state/needs-review*)
    k=\$(printf '%s' "\$p" | sed -n 's/.*[?&]repo=\([^&]*\).*/\1/p' | sed 's/%2[Ff]/_/g')
    f="$FX/needs.\$k"
    n=\$(cat "\$f.failn" 2>/dev/null || echo 0)
    if [ "\$n" -gt 0 ]; then
      echo "\$((n - 1))" > "\$f.failn"
      ( flock 9; printf 'GET %s \n' "\$p" >> "$T/log/worker" ) 9>"$T/worker.lock"
      if [ -r "\$f.body.\$n" ]; then out=\$(cat "\$f.body.\$n"); else out='error code: 1101'; fi
      code=\$(cat "\$f.code.\$n" 2>/dev/null || echo 500)
      printf '%s\n%s' "\$out" "\$code"
      exit 0
    fi ;;
esac
exec "$T/fakebin/curl.fx" "\$@"
EOF
chmod +x "$T/fakebin/curl"
export LW_ITEMS_RETRY_SLEEP_S=0 LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"

TSV="$H/state/lead-review/worklist-reads.tsv"
reads() { lwf_cnt '^GET /api/pr-state/needs-review?repo=example-org%2Fdemo-os' "$T/log/worker"; }
started() { grep '^POST /api/lead-reviews/start ' "$T/log/worker" 2>/dev/null | sed 's/^POST \/api\/lead-reviews\/start //' | jq -r 'select(.repo == "example-org/demo-os") | .pr' | paste -sd' ' -; }
last_tsv() { grep -P '\texample-org/demo-os\t' "$TSV" 2>/dev/null | tail -1; }
# tsv_is <line> <outcome> <reads> <status>: six fields, a UTC stamp, the slug, integer ms
tsv_is() {
  local l="$1" ts slug ms o n st
  IFS=$'\t' read -r ts slug ms o n st <<<"$l"
  [ "$(awk -F'\t' '{print NF}' <<<"$l")" = 6 ] && [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    && [[ "$ms" =~ ^[0-9]+$ ]] && [ "$o" = "$2" ] && [ "$n" = "$3" ] && [ "$st" = "$4" ]
}

# ── R1: the live 500 1101 once, then the answer ──
lwf_reset
lwf_needs example-org/demo-os 101
echo 1 > "$FX/needs.example-org_demo-os.failn"
lwf_tick
[ "$(reads)" = 2 ] && ok || bad "R1 needs-review reads=$(reads) (want 2)"
[ "$(started)" = 101 ] && ok || bad "R1 /start='$(started)' (want 101): $(cat "$L" 2>/dev/null)"
[ "$(grep -c 'first read failed (http=500' "$L" 2>/dev/null)" = 1 ] && ok || bad "R1 retry line count: $(cat "$L" 2>/dev/null)"
grep 'first read failed (http=500' "$L" 2>/dev/null | grep -q '1101' && ok || bad "R1 the retry line has no 1101: $(grep 'first read' "$L")"
grep -q 'example-org/demo-os unreadable' "$L" 2>/dev/null && bad "R1 the caller logged unreadable" || ok
tsv_is "$(last_tsv)" ok 2 http=200 && ok || bad "R1 TSV line '$(last_tsv)' (want ok 2 http=200)"

# ── R2: two failures ──
lwf_reset
lwf_needs example-org/demo-os 101
echo 2 > "$FX/needs.example-org_demo-os.failn"
lwf_tick
[ "$(reads)" = 2 ] && ok || bad "R2 needs-review reads=$(reads) (want 2)"
[ -z "$(started)" ] && ok || bad "R2 /start='$(started)' after two failed reads"
[ "$(grep -c 'http=500.*1101' "$L" 2>/dev/null)" = 1 ] && ok || bad "R2 lines with http=500 and 1101: $(cat "$L" 2>/dev/null)"
grep -q 'needs-review for example-org/demo-os failed after 2 read(s)' "$L" && ok || bad "R2 no failure line: $(cat "$L")"
grep -q 'needs-review for example-org/demo-os unreadable (rc=1)' "$L" && ok || bad "R2 the caller line is gone: $(cat "$L")"
tsv_is "$(last_tsv)" fail 2 http=500 && ok || bad "R2 TSV line '$(last_tsv)' (want fail 2 http=500)"
[ -z "$(find "$T/tmp" -name '*.st' -o -name '*.bd' 2>/dev/null)" ] && ok || bad "R2 status/body files left: $(find "$T/tmp" -name '*.st' -o -name '*.bd')"

# ── R2b: two different bodies, both in the one line ──
lwf_reset
lwf_needs example-org/demo-os 101
echo 2 > "$FX/needs.example-org_demo-os.failn"
echo '{"error":"D1_ERROR: first body"}' > "$FX/needs.example-org_demo-os.body.2"
echo 'error code: 1101' > "$FX/needs.example-org_demo-os.body.1"; echo 502 > "$FX/needs.example-org_demo-os.code.1"
lwf_tick
LN=$(grep 'failed after 2 read(s)' "$L" 2>/dev/null)
[ "$(grep -c . <<<"$LN")" = 1 ] && [[ "$LN" == *"http=500"*"first body"*"http=502"*"1101"* ]] && ok || bad "R2b one line with both reads: '$LN'"
tsv_is "$(last_tsv)" fail 2 http=502 && ok || bad "R2b TSV '$(last_tsv)' (want fail 2 http=502, the last read)"

# ── R2c: a body with a newline is logged on one line ──
lwf_reset
lwf_needs example-org/demo-os 101
echo 2 > "$FX/needs.example-org_demo-os.failn"
printf 'line one\nline two' > "$FX/needs.example-org_demo-os.body.2"
lwf_tick
LN=$(grep 'failed after 2 read(s)' "$L" 2>/dev/null)
[[ "$LN" == *"line one"*"line two"* ]] && ok || bad "R2c body split or missing: '$LN'"
grep -q '^line two' "$L" && bad "R2c the body broke the log line: $(cat "$L")" || ok

# ── R3: no failure ──
lwf_reset
lwf_needs example-org/demo-os 101
lwf_tick
[ "$(reads)" = 1 ] && ok || bad "R3 reads=$(reads) (want 1)"
[ "$(started)" = 101 ] && ok || bad "R3 /start='$(started)'"
grep -q 'first read failed\|failed after' "$L" && bad "R3 a retry/failure line on a clean read: $(cat "$L")" || ok
tsv_is "$(last_tsv)" ok 1 http=200 && ok || bad "R3 TSV '$(last_tsv)' (want ok 1 http=200)"

# ── R4: a measured none is not retried and not a failure ──
lwf_reset
echo '[]' > "$FX/needs.example-org_demo-os.json"
lwf_tick
[ "$(reads)" = 1 ] && ok || bad "R4 reads=$(reads) (want 1)"
grep -q 'first read failed\|failed after' "$L" && bad "R4 a line on rows: []: $(cat "$L")" || ok
tsv_is "$(last_tsv)" none 1 http=200 && ok || bad "R4 TSV '$(last_tsv)' (want none 1 http=200)"

# ── R7: an old worker's 404 is retried and named ──
lwf_reset
lwf_needs example-org/demo-os 101
echo 2 > "$FX/needs.example-org_demo-os.failn"
echo 404 > "$FX/needs.example-org_demo-os.code.2"; echo 404 > "$FX/needs.example-org_demo-os.code.1"
echo '{"error":"not found"}' > "$FX/needs.example-org_demo-os.body.2"; echo '{"error":"not found"}' > "$FX/needs.example-org_demo-os.body.1"
lwf_tick
[ "$(reads)" = 2 ] && ok || bad "R7 reads=$(reads) (want 2)"
grep 'failed after 2 read(s)' "$L" 2>/dev/null | grep -q 'http=404' && ok || bad "R7 no http=404 in the line: $(cat "$L")"
[ -z "$(started)" ] && ok || bad "R7 /start after 404s"

# ── Unit cases: the lib alone, a scripted pr_needs_review ──
UN=0
# us <case dir> <call n> <rc> <status> [body] [tsv out]
us() { printf '%s' "$3" > "$1/rc.$2"; printf '%s\n' "$4" > "$1/st.$2"; printf '%s' "${5:-}" > "$1/bd.$2"; printf '%s' "${6:-}" > "$1/out.$2"; }
unew() { UN=$((UN + 1)); U="$T/u/$UN"; mkdir -p "$U/h"; }
# urun [env assignments...] -- run lw_items example-org/u-<n> in a subshell; sets URC, UCALLS, ULOG, UTSV
urun() {
  ( unset JOBS_STATUS_FILE JOBS_BODY_FILE
    export HARNESS="$U/h"; [ -n "${UJQFAIL:-}" ] && UJQ=1
    for a in "$@"; do export "${a?}"; done
    # shellcheck source=/dev/null
    . "$SRC/bin/lib/lead-worklist.sh" || exit 99
    ulog() { printf '%s\n' "$*" >> "$U/log"; }; LW_LOGFN=ulog
    [ -n "${USLEEP_STUB:-}" ] && sleep() { printf '%s\n' "$1" >> "$U/slept"; }
    [ -n "${UJQ:-}" ] && jq() { return 5; }
    pr_needs_review() {
      local i; i=$(( $(cat "$U/calls" 2>/dev/null || echo 0) + 1 )); echo "$i" > "$U/calls"
      [ -z "${JOBS_STATUS_FILE:-}" ] || cat "$U/st.$i" > "$JOBS_STATUS_FILE"
      [ -z "${JOBS_BODY_FILE:-}" ] || cat "$U/bd.$i" > "$JOBS_BODY_FILE"
      cat "$U/out.$i"
      return "$(cat "$U/rc.$i")"
    }
    lw_items "example-org/u-$UN" "$U/out"; echo "$?" > "$U/rc" )
  URC=$(cat "$U/rc"); UCALLS=$(cat "$U/calls" 2>/dev/null || echo 0)
  ULOG=$(cat "$U/log" 2>/dev/null); UTSV=$(tail -1 "$U/h/state/lead-review/worklist-reads.tsv" 2>/dev/null)
}
uclean() { [ ! -e "$U/out.st" ] && [ ! -e "$U/out.bd" ]; }
ROW=$(printf '101\t%s\thttps://github.com/example-org/u/pull/101\t0\t0\t2026-10-10T03:00:00Z' "$SHA")

unew; us "$U" 1 1 http=503 '{"error":"D1_ERROR: overloaded"}'; us "$U" 2 1 http=503 '{"error":"D1_ERROR: overloaded"}'; urun
[ "$URC" = 1 ] && [ "$UCALLS" = 2 ] && ok || bad "U1 503: rc=$URC calls=$UCALLS (want 1, 2)"
[ "$(grep -c . <<<"$ULOG")" = 1 ] && [[ "$ULOG" == *"first http=503"*overloaded*"last http=503"* ]] && ok || bad "U1 log: '$ULOG'"
tsv_is "$UTSV" fail 2 http=503 && ok || bad "U1 TSV '$UTSV'"
[ ! -s "$U/out" ] && uclean && ok || bad "U1 out not empty or .st/.bd left"

unew; us "$U" 1 1 curl_rc=28; us "$U" 2 1 curl_rc=28; urun
[ "$URC" = 1 ] && [ "$UCALLS" = 2 ] && [[ "$ULOG" == *curl_rc=28* ]] && ok || bad "U2 timeout: rc=$URC calls=$UCALLS log='$ULOG'"
tsv_is "$UTSV" fail 2 curl_rc=28 && ok || bad "U2 TSV '$UTSV'"

unew; us "$U" 1 1 http=200 '<html>oops'; us "$U" 2 1 http=200 '<html>oops'; urun
[ "$URC" = 1 ] && [ "$UCALLS" = 2 ] && [[ "$ULOG" == *"http=200"*"<html>oops"* ]] && ok || bad "U3 unparsable 200: rc=$URC calls=$UCALLS log='$ULOG'"

unew; us "$U" 1 1 no-secret; urun
[ "$URC" = 1 ] && [ "$UCALLS" = 1 ] && [[ "$ULOG" == *"failed after 1 read(s)"*no-secret* ]] && ok || bad "U4 no-secret: rc=$URC calls=$UCALLS log='$ULOG'"
tsv_is "$UTSV" fail 1 no-secret && ok || bad "U4 TSV '$UTSV'"
[ ! -s "$U/out" ] && uclean && ok || bad "U4 out not empty or .st/.bd left"

unew; us "$U" 1 1 no-url; urun
[ "$URC" = 1 ] && [ "$UCALLS" = 1 ] && ok || bad "U5 no-url: rc=$URC calls=$UCALLS"
tsv_is "$UTSV" fail 1 no-url && ok || bad "U5 TSV '$UTSV'"

unew; us "$U" 1 0 http=200 '' "$ROW"; UJQFAIL=1 urun
[ "$URC" = 1 ] && [ "$UCALLS" = 1 ] && [ ! -s "$U/out" ] && ok || bad "U6 parse: rc=$URC calls=$UCALLS out=$(cat "$U/out")"
tsv_is "$UTSV" fail 1 parse && ok || bad "U6 TSV '$UTSV'"

unew; us "$U" 1 1 http=500 'error code: 1101'; us "$U" 2 2 http=200 '{"rows":[]}'; urun
[ "$URC" = 2 ] && [ "$UCALLS" = 2 ] && ok || bad "U7 retry measured none: rc=$URC calls=$UCALLS"
[[ "$ULOG" == *"first read failed (http=500"*1101*"the retry answered"* ]] && ok || bad "U7 log '$ULOG'"
tsv_is "$UTSV" none 2 http=200 && ok || bad "U7 TSV '$UTSV'"

unew; us "$U" 1 1 http=500 'error code: 1101'; us "$U" 2 0 http=200 '' "$ROW"; urun
[ "$URC" = 0 ] && [ "$(jq -r .pr "$U/out")" = 101 ] && uclean && ok || bad "U7b retry rows: rc=$URC out=$(cat "$U/out")"

# U8: the wait. Unset = a real 2 s; the rest through a sleep stub.
unew; us "$U" 1 1 http=500 x; us "$U" 2 1 http=500 x
t0=$(date +%s%N); ( unset LW_ITEMS_RETRY_SLEEP_S; urun ); t1=$(date +%s%N)
[ $(( (t1 - t0) / 1000000 )) -ge 2000 ] && ok || bad "U8 unset wait took $(( (t1 - t0) / 1000000 )) ms (want >= 2000)"
for v in abc 11 -1 0 10 2; do
  case "$v" in abc|11|-1) want=2 ;; *) want=$v ;; esac
  unew; us "$U" 1 1 http=500 x; us "$U" 2 1 http=500 x
  USLEEP_STUB=1 urun "LW_ITEMS_RETRY_SLEEP_S=$v"
  [ "$(cat "$U/slept" 2>/dev/null)" = "$want" ] && [[ "$ULOG" == *"(waited $want s)"* ]] && ok \
    || bad "U8 LW_ITEMS_RETRY_SLEEP_S=$v slept '$(cat "$U/slept" 2>/dev/null)' log '$ULOG' (want $want)"
done

unew; ( export HARNESS="$U/h"; . "$SRC/bin/lib/lead-worklist.sh"; pr_needs_review() { echo x >> "$U/calls"; return 1; }
  lw_items "" "$U/out"; echo "$?" > "$U/rc" )
[ "$(cat "$U/rc")" = 1 ] && [ ! -e "$U/calls" ] && [ ! -e "$U/h/state/lead-review/worklist-reads.tsv" ] && ok \
  || bad "U9 empty slug: rc=$(cat "$U/rc") calls=$(cat "$U/calls" 2>/dev/null) tsv=$(cat "$U/h/state/lead-review/worklist-reads.tsv" 2>/dev/null)"

# ── P1-P3: the prune ──
ago() { TZ=UTC0 date -d "-$1 days" +%FT%TZ; }
# prune <harness dir> [env...]
prune() { ( export HARNESS="$1"; shift; for a in "$@"; do export "${a?}"; done
  . "$SRC/bin/lib/lead-worklist.sh"; lw_pr_day_prune ); }
unew; us "$U" 1 0 http=200 '' "$ROW"; urun
R="$U/h/state/lead-review/worklist-reads.tsv"
printf '%s\texample-org/old\t10\tok\t1\thttp=200\n' "$(ago 8)" "$(ago 6)" >> "$R"
printf '%s\texample-org/x\t1\n' "$(TZ=UTC0 date -d '-5 days' +%F)" >> "$U/h/state/lead-review/started.tsv"
prune "$U/h"; P=$?
[ "$P" = 0 ] && ok || bad "P1 prune rc=$P"
grep -q "^$(ago 8 | cut -c1-10)" "$R" && bad "P1 the 8-day line stayed: $(cat "$R")" || ok
grep -q "^$(ago 6 | cut -c1-10)" "$R" && grep -q "example-org/u-$UN" "$R" && ok || bad "P1 lost today or the 6-day line: $(cat "$R")"
[ "$(awk -F'\t' 'NF != 6' "$R" | wc -l)" = 0 ] && [ "$(wc -l < "$R")" = 2 ] && ok || bad "P1 kept lines: $(cat "$R")"
[ -s "$U/h/state/lead-review/started.tsv" ] && bad "P1 started.tsv old line kept" || ok

unew; mkdir -p "$U/h/state/lead-review"; R="$U/h/state/lead-review/worklist-reads.tsv"
printf '%s\texample-org/old\t10\tok\t1\thttp=200\n' "$(ago 8)" "$(ago 6)" > "$R"
prune "$U/h" LW_READS_KEEP_DAYS=abc
[ "$(wc -l < "$R")" = 1 ] && grep -q "^$(ago 6 | cut -c1-10)" "$R" && ok || bad "P2 abc must read 7: $(cat "$R")"
printf '%s\texample-org/old\t10\tok\t1\thttp=200\n' "$(ago 6)" > "$R"
prune "$U/h" LW_READS_KEEP_DAYS=1
[ ! -s "$R" ] && ok || bad "P2 keep 1 day kept a 6-day line: $(cat "$R")"

unew; prune "$U/h"; P=$?
[ "$P" = 0 ] && [ ! -e "$U/h/state/lead-review/worklist-reads.tsv" ] && ok || bad "P3 no file: rc=$P"

echo "lead-worklist-retry.bh-7789: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
