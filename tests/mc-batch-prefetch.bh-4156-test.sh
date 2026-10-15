#!/bin/bash
# tests/mc-batch-prefetch.bh-4156-test.sh — BH-4156: the merge conductor reads
# the attempt rows of every PR of a repo in ONE request per tick
# (GET /api/conductor-state through pr_attempt_batch), and answers
# mc_attempt_has / mc_attempt_rows for the PRs that answer covers from that
# tick memo instead of one GET per PR per line.
#
# The sources under test: "$DIR/bin/lib/jobs/conductor.sh" (pr_attempt_batch),
# "$DIR/bin/lib/mc/locks.sh" (mc_tick_prefetch and the memo reads) and
# "$DIR/bin/merge-conductor.sh" (the one call in tick_project). The fake
# worker is "$DIR/tests/lib/fake-jobs-attempts.bh-4156.sh", a curl on PATH, so
# the real _jobs_req runs.
#
#   B1-B5  pr_attempt_batch: rows + covered list; 404 = rc 2; a 200 with no
#          arrays = rc 1; 250 numbers = 2 requests; a sha with a tab is not
#          covered
#   P1     a full tick of the real conductor over 3 PRs: 1 batch GET and 0
#          per-PR attempt GETs
#   P2-P13 the memo decision table (hit, miss + file hit, miss + file miss,
#          round-trip, 404, clear, flag down, put append, no tick, truncated,
#          a clear from another tick, a clear before the snapshot)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-batch-prefetch.bh-4156-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/fake-jobs-attempts.bh-4156.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
TAB=$'\t'

# ============================================================================
# The unit harness: the conductor's closure, the fake worker, one subshell per
# case that sources the real client and the real conductor lib.
# ============================================================================
U="$T/u"
mkdir -p "$U/h/logs" "$U/h/state" "$U/h/flags" "$U/h/env"
for s in bin/merge-conductor.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$U/h" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
: > "$U/h/env/global.env"
fja_install "$U/w" || exit 1
reset() { rm -f "$U/w/route404" "$U/w/routebad" "$U/w/drop" "$U/w/tabsha" "$U/w/down"
  : > "$U/w/db.tsv"; : > "$U/w/req.log"; scratch_rm "$U/h/state/merge-conductor"; : > "$U/h/logs/merge-conductor.log"
  touch "$U/h/flags/pr-state-rows"; }
row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$U/w/db.tsv"; }
nreq() { grep -c "$1" "$U/w/req.log" 2>/dev/null || true; }
# u <script> — one fresh shell: the real client and conductor lib, tick t1.
u() { ( unset -f curl; export PATH="$U/w/bin:$PATH" HARNESS="$U/h" HARNESS_ENV_DIR="$U/h/env"
  export JOBS_URL=https://jobs.invalid HARNESS_SECRET=secret-fixture-4156 JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_BOX=test-box
  export MC_TICK_ID="${TICK-t1}"
  . "$U/h/bin/jobs-client.sh" >/dev/null 2>&1 || { echo "client load failed"; exit 1; }
  . "$U/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || { echo "conductor lib load failed"; exit 1; }
  mkdir -p "$MC_STATE_DIR" "$MC_TICK_DIR"; touch "$MC_ATTEMPTS"
  eval "$1" ) 2>&1; }
MEMO="$U/h/state/merge-conductor/tick/t1.batch-o_r"

echo "== B1: rows in route order and every asked number covered =="
reset
row o/r 1 rebase s1; row o/r 1 rereview s2; row o/r 3 headlag "tip fact 1"; row o/x 1 rebase other
O=$(u 'pr_attempt_batch o/r "$U/b1.tsv" "$U/b1.cov" 3 1 2; echo "rc=$?"')
grep -qx 'rc=0' <<<"$O" && ok || bad "B1 rc ($O)"
[ "$(cat "$U/b1.tsv")" = "1${TAB}rereview${TAB}s2"$'\n'"1${TAB}rebase${TAB}s1"$'\n'"3${TAB}headlag${TAB}tip fact 1" ] && ok || bad "B1 rows ($(cat "$U/b1.tsv"))"
[ "$(tr '\n' ' ' < "$U/b1.cov")" = "1 2 3 " ] && ok || bad "B1 covered ($(cat "$U/b1.cov"))"
[ "$(nreq '^GET /api/conductor-state')" = 1 ] && ok || bad "B1 one request ($(cat "$U/w/req.log"))"

echo "== B2: a 404 (route not deployed) is rc 2 and writes nothing =="
reset; touch "$U/w/route404"; echo stale > "$U/b2.tsv"; echo 9 > "$U/b2.cov"
O=$(u 'pr_attempt_batch o/r "$U/b2.tsv" "$U/b2.cov" 1 2; echo "rc=$?"')
grep -qx 'rc=2' <<<"$O" && [ ! -s "$U/b2.tsv" ] && [ ! -s "$U/b2.cov" ] && ok || bad "B2 ($O / $(cat "$U/b2.cov"))"

echo "== B3: a 200 with no arrays is an outage (rc 1), never a measured none =="
reset; touch "$U/w/routebad"
O=$(u 'pr_attempt_batch o/r "$U/b3.tsv" "$U/b3.cov" 1; echo "rc=$?"')
grep -qx 'rc=1' <<<"$O" && [ ! -s "$U/b3.cov" ] && ok || bad "B3 ($O / $(cat "$U/b3.cov" 2>/dev/null))"
reset; touch "$U/w/down"
O=$(u 'pr_attempt_batch o/r "$U/b3.tsv" "$U/b3.cov" 1; echo "rc=$?"')
grep -qx 'rc=1' <<<"$O" && [ ! -s "$U/b3.cov" ] && ok || bad "B3 transport failure ($O)"

echo "== B4: 250 numbers are two requests (200 + 50), all covered =="
reset
O=$(u 'pr_attempt_batch o/r "$U/b4.tsv" "$U/b4.cov" $(seq 1 250); echo "rc=$?"')
grep -qx 'rc=0' <<<"$O" && [ "$(nreq '^GET /api/conductor-state')" = 2 ] && [ "$(wc -l < "$U/b4.cov")" = 250 ] && ok \
  || bad "B4 ($O / $(nreq '^GET /api/conductor-state') requests / $(wc -l < "$U/b4.cov") covered)"
F1=$(sed -n 1p "$U/w/req.log" | grep -o 'numbers=[^&]*' | sed 's/%2C/\n/g' | wc -l)
[ "$F1" = 200 ] && ok || bad "B4 the first chunk is 200 numbers ($F1)"

echo "== B5: a sha holding a tab is dropped and its PR is not covered =="
reset; touch "$U/w/tabsha"; row o/r 4 rereview fine
O=$(u 'pr_attempt_batch o/r "$U/b5.tsv" "$U/b5.cov" 3 4; echo "rc=$?"')
grep -qx 'rc=0' <<<"$O" && [ "$(tr '\n' ' ' < "$U/b5.cov")" = "3 " ] && ! grep -q "^4" "$U/b5.tsv" && ok \
  || bad "B5 ($O / cov $(cat "$U/b5.cov") / rows $(cat "$U/b5.tsv"))"

ROWS='"1${TAB}u1" "2${TAB}u2" "3${TAB}u3"'
echo "== P2: a memo hit is rc 0 with no per-PR GET, and the file line is warmed once =="
reset; row o/r 1 rebase s1
O=$(u 'mc_tick_prefetch o/r '"$ROWS"'; : > "$U/w/req.log"
  mc_attempt_has "rebase o/r#1 s1"; echo "rc=$?"; mc_attempt_has "rebase o/r#1 s1"; echo "rc=$?"
  grep -cxF "rebase o/r#1 s1" "$MC_ATTEMPTS"')
[ "$(printf '%s' "$O" | tr '\n' ' ')" = "rc=0 rc=0 1" ] && ok || bad "P2 ($O)"
[ "$(nreq '^GET /api/pr-attempts')" = 0 ] && ok || bad "P2 per-PR GETs ($(cat "$U/w/req.log"))"

echo "== P3: a memo miss with a file hit is rc 0 and ONE back-fill PUT =="
reset
O=$(u 'echo "rebase o/r#1 s9" >> "$MC_ATTEMPTS"; mc_tick_prefetch o/r '"$ROWS"'; : > "$U/w/req.log"
  mc_attempt_has "rebase o/r#1 s9"; echo "rc=$?"; mc_attempt_has "rebase o/r#1 s9"; echo "rc=$?"')
[ "$(printf '%s' "$O" | tr '\n' ' ')" = "rc=0 rc=0" ] && ok || bad "P3 ($O)"
[ "$(nreq '^PUT /api/pr-attempts')" = 1 ] && [ "$(nreq '^GET /api/pr-attempts')" = 0 ] && ok || bad "P3 requests ($(cat "$U/w/req.log"))"
grep -qxF "o/r${TAB}1${TAB}rebase${TAB}s9" "$U/w/db.tsv" && ok || bad "P3 the row was back-filled"

echo "== P4: a memo miss and a file miss is rc 1 and no GET =="
reset; row o/r 1 rebase s1
O=$(u 'mc_tick_prefetch o/r '"$ROWS"'; : > "$U/w/req.log"; mc_attempt_has "rebase o/r#1 s2"; echo "rc=$?"; mc_attempt_has "rereview o/r#2 s1"; echo "rc=$?"')
[ "$(printf '%s' "$O" | tr '\n' ' ')" = "rc=1 rc=1" ] && [ ! -s "$U/w/req.log" ] && ok || bad "P4 ($O / $(cat "$U/w/req.log"))"

echo "== P5: a headlag sha with spaces and a #n counter row round-trip byte for byte =="
reset; row o/r 1 headlag "tipa fact 1"; row o/r 1 headlag "tipb fact 2"; row o/r 1 rereview "h1 #1"; row o/r 1 rereview "h1 #2"
O=$(u 'mc_attempt_rows headlag o/r#1 "$U/p5.per"; echo "per=$?"; mc_attempt_count rereview o/r#1 h1
  mc_attempt_rows "*" o/r#1 "$U/p5.perall"
  mc_tick_prefetch o/r '"$ROWS"'; : > "$U/w/req.log"
  mc_attempt_rows headlag o/r#1 "$U/p5.memo"; echo "memo=$?"; mc_attempt_count rereview o/r#1 h1
  mc_attempt_rows "*" o/r#1 "$U/p5.memoall"; mc_attempt_rows rebase o/r#1 "$U/p5.none"; echo "none=$?"')
[ "$(printf '%s' "$O" | tr '\n' ' ')" = "per=0 2 memo=0 2 none=2" ] && ok || bad "P5 ($O)"
cmp -s "$U/p5.per" "$U/p5.memo" && [ -s "$U/p5.memo" ] && ok || bad "P5 headlag rows differ: per-PR [$(cat "$U/p5.per")] memo [$(cat "$U/p5.memo")]"
cmp -s "$U/p5.perall" "$U/p5.memoall" && ok || bad "P5 every-kind rows differ: [$(cat "$U/p5.perall")] vs [$(cat "$U/p5.memoall")]"
[ "$(nreq '^GET /api/pr-attempts')" = 0 ] && ok || bad "P5 the memo reads made a GET ($(cat "$U/w/req.log"))"

echo "== P6: a 404 batch: per-PR GETs as today, one log line, no latch =="
reset; touch "$U/w/route404"; row o/r 1 rebase s1
O=$(u 'mc_tick_prefetch o/r '"$ROWS"'; mc_attempt_has "rebase o/r#1 s1"; echo "rc=$?"
  ls "$MC_TICK_DIR" | grep -c "pr-rows-down"; ls "$MC_TICK_DIR" | grep -c "batch-"')
[ "$(printf '%s' "$O" | tr '\n' ' ')" = "rc=0 0 0" ] && ok || bad "P6 ($O)"
[ "$(nreq '^GET /api/pr-attempts?.*number=1')" = 1 ] && ok || bad "P6 one per-PR GET ($(cat "$U/w/req.log"))"
[ "$(grep -c 'conductor-state' "$U/h/logs/merge-conductor.log")" = 1 ] && ok || bad "P6 one log line ($(cat "$U/h/logs/merge-conductor.log"))"

echo "== P7: mc_attempt_clear un-covers the PR: the next read is a per-PR GET =="
reset; row o/r 1 rebase s1
O=$(u 'mc_tick_prefetch o/r '"$ROWS"'; mc_attempt_clear rebase o/r#1 s1; : > "$U/w/req.log"; mc_attempt_has "rebase o/r#1 s1"; echo "rc=$?"
  mc_attempt_rows rebase o/r#1 "$U/p7"; echo "rows=$?"')
[ "$(printf '%s' "$O" | tr '\n' ' ')" = "rc=1 rows=2" ] && ok || bad "P7 ($O)"
[ "$(nreq '^GET /api/pr-attempts?.*number=1')" = 2 ] && ok || bad "P7 per-PR GETs after the clear ($(cat "$U/w/req.log"))"

echo "== P12: a clear in ANOTHER tick (t2) un-covers the PR in t1's memo: per-PR GET, rc 1, no warm-back =="
reset; row o/r 1 crdequeue H
O=$(u 'echo "crdequeue o/r#1 H" >> "$MC_ATTEMPTS"; mc_tick_prefetch o/r '"$ROWS")
O=$(TICK=t2 u 'mc_attempt_clear crdequeue o/r#1 H'; : > "$U/w/req.log")
O=$(u 'mc_attempt_has "crdequeue o/r#1 H"; echo "rc=$?"; grep -cxF "crdequeue o/r#1 H" "$MC_ATTEMPTS"')
[ "$(printf '%s' "$O" | tr '\n' ' ')" = "rc=1 0" ] && ok || bad "P12 ($O)"
[ "$(nreq '^GET /api/pr-attempts?.*number=1')" = 1 ] && ok || bad "P12 one per-PR GET after the other tick's clear ($(cat "$U/w/req.log"))"
O=$(u 'mc_attempt_rows crdequeue o/r#1 "$U/p12"; echo "rows=$?"')
[ "$O" = rows=2 ] && ok || bad "P12 mc_attempt_rows reads per PR after the clear ($O)"
echo "== P13: a clear BEFORE the prefetch does not un-cover the PR =="
reset; row o/r 1 rebase s1
O=$(TICK=t2 u 'mc_attempt_clear rebase o/r#9 zz')
O=$(TICK=t2 u 'mc_attempt_clear rebase o/r#1 old'); sleep 0.05
O=$(u 'mc_tick_prefetch o/r '"$ROWS"'; : > "$U/w/req.log"; mc_attempt_has "rebase o/r#1 s1"; echo "rc=$?"')
[ "$O" = rc=0 ] && [ "$(nreq '^GET /api/pr-attempts')" = 0 ] && ok || bad "P13 ($O / $(cat "$U/w/req.log"))"

echo "== P8: the flag down: no batch GET and no memo file =="
reset; rm -f "$U/h/flags/pr-state-rows"
O=$(u 'mc_tick_prefetch o/r '"$ROWS"'; ls "$MC_TICK_DIR" | grep -c "batch-"')
[ "$O" = 0 ] && [ "$(nreq '^GET /api/conductor-state')" = 0 ] && ok || bad "P8 ($O / $(cat "$U/w/req.log"))"

echo "== P9: a row put this tick is in the memo, newest first =="
reset; row o/r 2 rebase old
O=$(u 'mc_tick_prefetch o/r '"$ROWS"'; mc_attempt_put "rebase o/r#2 new1"; mc_attempt_put "rebase o/r#2 old"; mc_attempt_put "rebase o/r#2 new2"
  : > "$U/w/req.log"; mc_attempt_has "rebase o/r#2 new1"; echo "rc=$?"; mc_attempt_rows rebase o/r#2 "$U/p9"; echo "rows=$?"
  mc_attempt_rows rebase o/r#2 "$U/p9.memo"; rm -f "$MC_TICK_DIR"/t1.batch-*; mc_attempt_rows rebase o/r#2 "$U/p9.per"')
[ "$(printf '%s' "$O" | tr '\n' ' ')" = "rc=0 rows=0" ] && [ "$(grep -c . "$U/w/req.log")" = 1 ] && ok || bad "P9 ($O / $(cat "$U/w/req.log"))"
[ "$(tr '\n' ' ' < "$U/p9")" = "new2 new1 old " ] && ok || bad "P9 order: wanted 'new2 new1 old', got [$(cat "$U/p9")]"
cmp -s "$U/p9.memo" "$U/p9.per" && ok || bad "P9 the memo order is the per-PR order: [$(cat "$U/p9.memo")] vs [$(cat "$U/p9.per")]"

echo "== P10: no MC_TICK_ID: per-PR GET, no memo =="
reset; row o/r 1 rebase s1
O=$(TICK='' u 'mc_tick_prefetch o/r '"$ROWS"'; mc_attempt_has "rebase o/r#1 s1"; echo "rc=$?"')
[ "$O" = rc=0 ] && [ "$(nreq '^GET /api/conductor-state')" = 0 ] && [ "$(nreq '^GET /api/pr-attempts')" = 1 ] && ok || bad "P10 ($O / $(cat "$U/w/req.log"))"

echo "== P11: a PR the answer left out (truncated) reads per PR =="
reset; row o/r 2 rebase s2; echo 2 > "$U/w/drop"
O=$(u 'mc_tick_prefetch o/r '"$ROWS"'; : > "$U/w/req.log"; mc_attempt_has "rebase o/r#2 s2"; echo "rc=$?"; mc_attempt_has "rebase o/r#1 zz"; echo "rc=$?"')
[ "$(printf '%s' "$O" | tr '\n' ' ')" = "rc=0 rc=1" ] && [ "$(nreq '^GET /api/pr-attempts?.*number=2')" = 1 ] && [ "$(nreq '^GET /api/pr-attempts?.*number=1')" = 0 ] && ok \
  || bad "P11 ($O / $(cat "$U/w/req.log"))"
[ -f "$MEMO.covered" ] && ! grep -qx 2 "$MEMO.covered" && ok || bad "P11 the memo covers 2 ($(cat "$MEMO.covered" 2>/dev/null))"

# ============================================================================
# P1 — one full tick of the real conductor, 3 PRs, the flag up.
# ============================================================================
echo "== P1: a full tick reads attempts once per repo =="
SLUG=example-org/demo
GU="https://github.com/$SLUG/pull"
PRS="1 2 3"
NOW=1791990000
hd() { printf '%02d%038d' "$1" 0; }
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
F="$T/f"
mkdir -p "$F/h/logs" "$F/h/state/merge-conductor" "$F/h/flags" "$F/h/locks" "$F/h/builds" "$F/h/env" "$F/h/tmp" "$F/fakebin"
for s in bin/merge-conductor.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$F/h" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
scratch_rm "$F/h/bin/lib/gh-limit-logger.sh"
mkdir -p "$F/h/catalog" && cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$F/h/catalog/" || exit 1
printf 'demo %s - - 2 box-m\n' "$SLUG" > "$F/h/fleet.conf"
: > "$F/h/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$F/h/bin/$s.sh"; chmod +x "$F/h/bin/$s.sh"; done
printf '#!/bin/bash\nexit 0\n' > "$F/h/bin/lane-alert.sh"; chmod +x "$F/h/bin/lane-alert.sh"
for n in $PRS; do
  REC="$F/h/builds/pool-demo-BH-$n-202610130001"; mkdir -p "$REC"
  echo "PR_CREATED $GU/$n" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  hd "$n" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
done
cp "$DIR/tests/lib/rest-emit.sh" "$F/fakebin/restpr"; chmod +x "$F/fakebin/restpr"
for n in $PRS; do jq -nc --arg s "$SLUG" --argjson n "$n" --arg h "$(hd "$n")" '{number:$n, html_url:("https://github.com/"+$s+"/pull/"+($n|tostring)),
  title:"t", body:"", draft:false, state:"open", merged_at:null, labels:[], user:{login:"operator",type:"User"},
  updated_at:"2026-10-13T00:00:00Z", head:{ref:("ticket/bh-"+($n|tostring)), sha:$h, repo:{full_name:$s}},
  base:{ref:"main", repo:{full_name:$s}}, mergeable_state:"clean", mergeable:true}'; done | jq -sc . > "$F/open.json"
for n in $PRS; do printf '{"ref":"refs/heads/ticket/bh-%s","object":{"sha":"%s","type":"commit"}}\n' "$n" "$(hd "$n")"; done | jq -sc . > "$F/refs.json"
cat > "$F/fakebin/gh" <<EOF
#!/bin/bash
A="\$*"
N=\$(grep -oE '(pulls|issues)/[0-9]+' <<<"\$A" | head -1 | grep -oE '[0-9]+\$')
HEADN=\$(printf '%02d%038d' "\${N:-0}" 0)
case "\$A" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"git/matching-refs/heads/"*) restpr --raw 200 "\$(cat "$F/refs.json")" ;;
  *"api -i -X GET repos/$SLUG/branches/"*) restpr --raw 200 '{"name":"x","commit":{"sha":"'"\$HEADN"'"}}' ;;
  *"api -i -X GET repos/$SLUG/pulls -f state=open"*) restpr --raw 200 "\$(cat "$F/open.json")" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"-X POST"*|*"-X DELETE"*|*"-X PATCH"*|*"-X PUT"*|*"pr close"*|*"pr edit"*|*"issue close"*|*"pr merge"*) : ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*) echo '[]' ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api repos/$SLUG/issues/"*) printf '{"number":%s,"state":"open","labels":[],"body":""}\n' "\$N" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*) restpr OPEN "\$HEADN" "ticket/bh-\$N" main "" MERGEABLE CLEAN operator "" "" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
esac
exit 0
EOF
chmod +x "$F/fakebin/gh"
# TEST-CHANGE BH-4148: the lead reads protected paths from the jobs route, not
# catalog/lead-protected-paths.tsv. The fake worker of BH-4156 has no such
# route, so a wrapper answers it through lpp-stub (no rows for the demo repo:
# not governed, as under the old catalog file) and hands every other request
# to the fake, so its req.log counts are unchanged.
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_wrap() {
  local d="$1"; lpp_set "$d/lpp.json" "$SLUG"; lpp_install "$d/bin" "$d/lpp.json" "$d/lpp-down"
  mv "$d/bin/curl" "$d/bin/curl.fja"
  cat > "$d/bin/curl" <<'LPPEOF'
#!/bin/bash
URL="${!#}"; M=GET; a=("$@")
for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" = -X ] && M="${a[i+1]}"; done
case "$URL" in *"/api/lead-protected-paths"*) "$(dirname "$0")/lpp-answer" "$M" "$URL"; exit 0 ;; esac
exec "$(dirname "$0")/curl.fja" "$@"
LPPEOF
  chmod +x "$d/bin/curl"
}
fja_install "$F/w" || exit 1
lpp_wrap "$F/w" || exit 1
touch "$F/h/flags/pr-state-rows"
for n in $PRS; do printf '%s\t%s\t%s\t%s\t%s\t-\t-\t%s/%s\n' "$SLUG#$n" READY $((NOW-600)) "$(hd "$n")" "$(hd "$n")" "$GU" "$n"; done > "$F/h/state/merge-conductor/pr-state.tsv"
row_f() { printf '%s\t%s\t%s\t%s\n' "$SLUG" "$1" "$2" "$3" >> "$F/w/db.tsv"; }
row_f 1 headlag "$(hd 1) seen 1"; row_f 2 rereview "$(hd 2)"
p1_tick() { ( unset -f gh curl; cd "$F" && env PATH="$F/w/bin:$F/fakebin:$PATH" HARNESS="$F/h" FLEET_CONF="$F/h/fleet.conf" HARNESS_ENV_DIR="$F/h/env" \
  HARNESS_SECRET=secret-fixture-4156 JOBS_URL=http://worker.test JOBS_RETRIES=0 JOBS_ALERT=0 \
  GH_TOKEN=pat-fixture-default HARNESS_PR_AUTHORS=operator \
  PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 MC_HEAD_LAG_MINS=10 MC_WORKER_DEADLINE_S=120 \
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_PREQUEUE_GATE=0 \
  bash "$F/h/bin/merge-conductor.sh" > "$F/mc.out" 2>&1 ); }
p1_tick
CLOG="$F/h/logs/merge-conductor.log"
NB=$(grep -c "^GET /api/conductor-state?repo=example-org%2Fdemo" "$F/w/req.log")
NP=$(grep -cE "^GET /api/pr-attempts\?repo=example-org%2Fdemo&number=[123](&|$)" "$F/w/req.log")
echo "P1: batch GETs $NB, per-PR attempt GETs $NP"
grep -qE "FANIN merge-conductor $SLUG: enumerated 3 accounted 3" "$CLOG" 2>/dev/null && ok || bad "P1 setup: the tick worked 3 PRs ($(grep FANIN "$CLOG" 2>/dev/null; tail -3 "$F/mc.out"))"
[ "$NB" = 1 ] && ok || bad "P1 exactly 1 batch GET (got $NB)"
[ "$NP" = 0 ] && ok || bad "P1 0 per-PR attempt GETs (got $NP: $(grep -E '^GET /api/pr-attempts' "$F/w/req.log" | head -5))"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "mc-batch-prefetch.bh-4156: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
