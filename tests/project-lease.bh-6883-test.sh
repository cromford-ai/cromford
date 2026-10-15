#!/bin/bash
# tests/project-lease.bh-6883-test.sh — BH-6883 (BH-6881.1): the project lease
# with a fence token. POST /api/project-leases/{acquire,renew,release} and
# bin/lib/project-lease.sh, driven over real curl against the REAL jobs worker
# (tests/lib/project-lease.bh-6883.mjs) on node:sqlite with the composed schema.
#
#   1   A acquires: 200 fence 1; B: 409 held, the body names no holder
#   2   after expiry B acquires: fence 2, holder B
#   3   A renews with its old fence: 409 lost, row unchanged
#   4   B releases with a wrong fence: 409, row unchanged; with fence 2: 200,
#       lease_until == as_of; A acquires at once: fence 3
#   5   EXPLAIN QUERY PLAN on 5,000 rows: renew and release SEARCH the primary
#       key, no plan SCANs project_leases, index_list has the pk index
#   6   pjl_acquire prints 1 rc 0; a second holder rc 3 and prints nothing
#   D1  A re-acquires its live lease: same fence, later lease_until
#   D2  A renews after its own expiry: 409 lost
#   D3  three acquire/release cycles: one row, fence 3
#   D4  B releases with A's fence: 409, row unchanged; A's release twice: 200
#   D5  project_lease.ttl_s=30 -> 30 s; =abc -> 180 s; ttl_s 5 or 901 -> 400
#   A1  no bearer: 401          A2  bad lane, no holder, fence 0: 400
#   S1  pjl_renew prints lease_until rc 0; pjl_release rc 0
#   S2  port closed: rc 1; table dropped (503): rc 1, never 3
#   S3  pjl_renew with an old fence: rc 3; a missing argument: rc 1, no request
#   S4  sourcing the lib makes no request and prints nothing
#   S5  a 409 that is not held/lost is rc 1; a 200 with no integer fence or
#       no lease_until is rc 1
#
# A lease expires through the fixture's /__expire hook, never by waiting.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/project-lease.bh-6883-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/project-lease.bh-6883.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env"
for L in bin/jobs-client.sh bin/lib/project-lease.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
export HARNESS="$H"
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0

: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
trap 'kill "$SPID" 2>/dev/null' EXIT

# post <op> <json> — the status code; the body lands in $T/out.json.
post() { curl -sS -o "$T/out.json" -w '%{http_code}' -X POST -H "authorization: Bearer $HARNESS_SECRET" \
  -H 'content-type: application/json' -d "$2" "$JOBS_URL/api/project-leases/$1"; }
out() { jq -r "$1" "$T/out.json" 2>/dev/null; }
body() { jq -nc --arg l "$1" --arg p "$2" --arg h "$3" '{lane:$l,project:$p,holder:$h}'; }
fbody() { jq -nc --arg l "$1" --arg p "$2" --arg h "$3" --argjson f "$4" '{lane:$l,project:$p,holder:$h,fence:$f}'; }
row() { curl -sS "$JOBS_URL/__row?lane=$1&project=$2"; }
count() { curl -sS "$JOBS_URL/__count?lane=$1&project=$2" | jq -r .n; }
expire() { curl -sS -X POST -d "{\"lane\":\"$1\",\"project\":\"$2\"}" "$JOBS_URL/__expire" > /dev/null; }
setting() { curl -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$JOBS_URL/__setting" > /dev/null; }
secs() { jq -r '((.lease_until|fromdate) - (.as_of|fromdate))' "$T/out.json" 2>/dev/null; }
LIBS=". '$H/bin/jobs-client.sh' && . '$H/bin/lib/project-lease.sh'"
MC=merge-conductor

# ============================================================================
echo "1: A acquires; B is held out and the 409 names no holder"
C=$(post acquire "$(body $MC p1 holder-a)")
[ "$C" = 200 ] && [ "$(out .fence)" = 1 ] && ok "1 A acquires: 200 fence 1" || bad "1 A acquire: $C $(cat "$T/out.json")"
C=$(post acquire "$(body $MC p1 holder-b)")
[ "$C" = 409 ] && [ "$(out .error)" = held ] && ok "1 B acquires: 409 held" || bad "1 B acquire: $C $(cat "$T/out.json")"
grep -q 'holder-' "$T/out.json" && bad "1 the 409 names a holder: $(cat "$T/out.json")" || ok "1 the 409 names no holder"
[ "$(row $MC p1 | jq -r .holder)" = holder-a ] && ok "1 the row stays with A" || bad "1 row: $(row $MC p1)"

# ============================================================================
echo "2: after expiry B takes the lease with fence 2"
expire $MC p1
C=$(post acquire "$(body $MC p1 holder-b)")
[ "$C" = 200 ] && [ "$(out .fence)" = 2 ] && ok "2 B acquires: 200 fence 2" || bad "2 B acquire: $C $(cat "$T/out.json")"
R=$(row $MC p1)
[ "$(jq -r .holder <<<"$R")" = holder-b ] && [ "$(jq -r .fence <<<"$R")" = 2 ] && ok "2 the row holds B at fence 2" || bad "2 row: $R"

# ============================================================================
echo "3: A renews with its old fence"
BEFORE=$(row $MC p1)
C=$(post renew "$(fbody $MC p1 holder-a 1)")
[ "$C" = 409 ] && [ "$(out .error)" = lost ] && ok "3 A renew: 409 lost" || bad "3 A renew: $C $(cat "$T/out.json")"
[ "$(row $MC p1)" = "$BEFORE" ] && ok "3 the row is unchanged" || bad "3 row changed: $BEFORE -> $(row $MC p1)"

# ============================================================================
echo "4: release"
BEFORE=$(row $MC p1)
C=$(post release "$(fbody $MC p1 holder-b 1)")
[ "$C" = 409 ] && [ "$(out .error)" = lost ] && ok "4 B release with fence 1: 409 lost" || bad "4 wrong-fence release: $C $(cat "$T/out.json")"
[ "$(row $MC p1)" = "$BEFORE" ] && ok "4 the row is unchanged" || bad "4 row changed: $(row $MC p1)"
C=$(post release "$(fbody $MC p1 holder-b 2)")
[ "$C" = 200 ] && [ "$(out .released)" = true ] && ok "4 B release with fence 2: 200" || bad "4 release: $C $(cat "$T/out.json")"
[ "$(row $MC p1 | jq -r .lease_until)" = "$(out .as_of)" ] && ok "4 lease_until == as_of" || bad "4 lease_until $(row $MC p1) as_of $(out .as_of)"
C=$(post acquire "$(body $MC p1 holder-a)")
[ "$C" = 200 ] && [ "$(out .fence)" = 3 ] && ok "4 A acquires at once: fence 3" || bad "4 A re-acquire: $C $(cat "$T/out.json")"

# ============================================================================
echo "D1: A re-acquires its live lease"
setting project_lease.ttl_s 30
post acquire "$(body $MC d1 holder-a)" > /dev/null; F1=$(out .fence); U1=$(out .lease_until)
setting project_lease.ttl_s 300
C=$(post acquire "$(body $MC d1 holder-a)")
[ "$C" = 200 ] && [ "$(out .fence)" = "$F1" ] && [ "$F1" = 1 ] && ok "D1 same fence 1" || bad "D1: $C $(cat "$T/out.json")"
[[ "$(out .lease_until)" > "$U1" ]] && ok "D1 lease_until moved later" || bad "D1 lease_until $U1 -> $(out .lease_until)"
setting project_lease.ttl_s 180

# ============================================================================
echo "D2: A renews after its own expiry"
post acquire "$(body $MC d2 holder-a)" > /dev/null
C=$(post renew "$(fbody $MC d2 holder-a 1)")
[ "$C" = 200 ] && [ "$(out .fence)" = 1 ] && ok "D2 a live renew: 200" || bad "D2 live renew: $C $(cat "$T/out.json")"
expire $MC d2
C=$(post renew "$(fbody $MC d2 holder-a 1)")
[ "$C" = 409 ] && [ "$(out .error)" = lost ] && ok "D2 renew after expiry: 409 lost" || bad "D2 expired renew: $C $(cat "$T/out.json")"
[ "$(row $MC d2 | jq -r .lease_until)" = 2000-01-01T00:00:00Z ] && ok "D2 nothing written" || bad "D2 row: $(row $MC d2)"

# ============================================================================
echo "D3: three acquire/release cycles"
for i in 1 2 3; do
  post acquire "$(body $MC d3 holder-c)" > /dev/null; F=$(out .fence)
  post release "$(fbody $MC d3 holder-c "${F:-0}")" > /dev/null
done
[ "$(count $MC d3)" = 1 ] && [ "$(row $MC d3 | jq -r .fence)" = 3 ] && ok "D3 one row, fence 3" || bad "D3 count $(count $MC d3) row $(row $MC d3)"

# ============================================================================
echo "D4: release needs holder AND fence; a retried release answers 200"
post acquire "$(body $MC d4 holder-a)" > /dev/null; FA=$(out .fence)
BEFORE=$(row $MC d4)
C=$(post release "$(fbody $MC d4 holder-b "${FA:-0}")")
[ "$C" = 409 ] && [ "$(row $MC d4)" = "$BEFORE" ] && ok "D4 B with A's fence: 409, row unchanged" || bad "D4 B release: $C $(row $MC d4)"
C1=$(post release "$(fbody $MC d4 holder-a "${FA:-0}")"); U1=$(row $MC d4 | jq -r .lease_until)
C2=$(post release "$(fbody $MC d4 holder-a "${FA:-0}")")
[ "$C1" = 200 ] && [ "$C2" = 200 ] && ok "D4 A's release twice: 200 200" || bad "D4 A release: $C1 $C2"
[ "$(row $MC d4 | jq -r .lease_until)" = "$U1" ] && ok "D4 the retry does not move lease_until" || bad "D4 retry moved lease_until"

# ============================================================================
echo "D5: ttl_s from the settings row, and its bounds"
setting project_lease.ttl_s 30
C=$(post acquire "$(body $MC d5a holder-a)")
[ "$C" = 200 ] && [ "$(secs)" = 30 ] && ok "D5 setting 30: lease_until = as_of + 30 s" || bad "D5 30: $C $(cat "$T/out.json")"
setting project_lease.ttl_s abc
C=$(post acquire "$(body $MC d5b holder-a)")
[ "$C" = 200 ] && [ "$(secs)" = 180 ] && ok "D5 setting abc: the 180 s fallback" || bad "D5 abc: $C $(cat "$T/out.json")"
setting project_lease.ttl_s 180
C=$(post acquire "$(jq -nc '{lane:"merge-conductor",project:"d5c",holder:"holder-a",ttl_s:60}')")
[ "$C" = 200 ] && [ "$(secs)" = 60 ] && ok "D5 body ttl_s 60: 60 s" || bad "D5 body 60: $C $(cat "$T/out.json")"
for v in 5 901 1.5 '"x"'; do
  C=$(post acquire "{\"lane\":\"$MC\",\"project\":\"d5d\",\"holder\":\"holder-a\",\"ttl_s\":$v}")
  [ "$C" = 400 ] && ok "D5 ttl_s $v: 400" || bad "D5 ttl_s $v: $C $(cat "$T/out.json")"
done
[ "$(row $MC d5d)" = null ] && ok "D5 no row written for a bad ttl_s" || bad "D5 row: $(row $MC d5d)"
C=$(post renew "{\"lane\":\"$MC\",\"project\":\"d5a\",\"holder\":\"holder-a\",\"fence\":1,\"ttl_s\":901}")
[ "$C" = 400 ] && ok "D5 renew ttl_s 901: 400" || bad "D5 renew 901: $C"

# ============================================================================
echo "A1/A2: bearer and validation"
C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d "$(body $MC a1 holder-a)" "$JOBS_URL/api/project-leases/acquire")
[ "$C" = 401 ] && ok "A1 acquire without a bearer: 401" || bad "A1: $C"
for op in renew release; do
  C=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d "$(fbody $MC a1 holder-a 1)" "$JOBS_URL/api/project-leases/$op")
  [ "$C" = 401 ] && ok "A1 $op without a bearer: 401" || bad "A1 $op: $C"
done
[ "$(row $MC a1)" = null ] && ok "A1 no row" || bad "A1 row: $(row $MC a1)"
C=$(post acquire '{"lane":"a b","project":"a2","holder":"holder-a"}'); [ "$C" = 400 ] && ok "A2 lane 'a b': 400" || bad "A2 lane: $C"
C=$(post acquire "{\"lane\":\"$MC\",\"project\":\"a2\"}"); [ "$C" = 400 ] && ok "A2 no holder: 400" || bad "A2 holder: $C"
C=$(post acquire "{\"lane\":\"$MC\",\"holder\":\"holder-a\"}"); [ "$C" = 400 ] && ok "A2 no project: 400" || bad "A2 project: $C"
[ "$(row $MC a2)" = null ] && ok "A2 no row written" || bad "A2 row: $(row $MC a2)"
post acquire "$(body $MC a2b holder-a)" > /dev/null
for f in 0 -1 1.5 '"x"' null; do
  C=$(post renew "{\"lane\":\"$MC\",\"project\":\"a2b\",\"holder\":\"holder-a\",\"fence\":$f}")
  C2=$(post release "{\"lane\":\"$MC\",\"project\":\"a2b\",\"holder\":\"holder-a\",\"fence\":$f}")
  [ "$C" = 400 ] && [ "$C2" = 400 ] && ok "A2 fence $f: renew 400, release 400" || bad "A2 fence $f: $C $C2"
done

# ============================================================================
echo "5: EXPLAIN QUERY PLAN on 5,000 seeded rows"
curl -sS "$JOBS_URL/__eqp" > "$T/eqp.json"
SEARCH='SEARCH project_leases USING INDEX sqlite_autoindex_project_leases_1 (lane=? AND project=?)'
for op in renew release; do
  jq -e --arg s "$SEARCH" --arg op "$op" '.[$op] | index($s) != null' "$T/eqp.json" > /dev/null \
    && ok "5 $op SEARCHes the primary key" || bad "5 $op plan: $(jq -c --arg op "$op" '.[$op]' "$T/eqp.json" 2>/dev/null || cat "$T/eqp.json")"
done
for op in acquire renew release; do
  jq -e --arg op "$op" '(.[$op] | type) == "array" and ([.[$op][] | select(test("SCAN project_leases"))] | length) == 0' "$T/eqp.json" > /dev/null \
    && ok "5 $op has no SCAN project_leases" || bad "5 $op plan: $(jq -c --arg op "$op" '.[$op]' "$T/eqp.json" 2>/dev/null || cat "$T/eqp.json")"
done
jq -e '[.index_list[] | select(.origin == "pk" and .unique == 1)] | length == 1' "$T/eqp.json" > /dev/null \
  && ok "5 index_list has the pk index" || bad "5 index_list: $(jq -c .index_list "$T/eqp.json" 2>/dev/null)"

# ============================================================================
echo "6/S1/S3: the shell lib against the worker"
( eval "$LIBS"
  f=$(pjl_acquire $MC p2 holder-a); echo "a-rc=$? a-out=[$f]"
  g=$(pjl_acquire $MC p2 holder-b); echo "b-rc=$? b-out=[$g]"
  u=$(pjl_renew $MC p2 holder-a "$f"); echo "r-rc=$? r-out=[$u]"
  s=$(pjl_renew $MC p2 holder-a 99); echo "s-rc=$? s-out=[$s]"
  pjl_release $MC p2 holder-a "$f" > /dev/null; echo "l-rc=$?"
  pjl_release $MC p2 holder-b "$f" > /dev/null; echo "m-rc=$?"
) > "$T/s.out" 2> "$T/s.err"
grep -qx 'a-rc=0 a-out=\[1\]' "$T/s.out" && ok "6 pjl_acquire A prints 1, rc 0" || bad "6 A: $(cat "$T/s.out" "$T/s.err")"
grep -qx 'b-rc=3 b-out=\[\]' "$T/s.out" && ok "6 pjl_acquire B rc 3, prints nothing" || bad "6 B: $(cat "$T/s.out")"
U=$(row $MC p2 | jq -r .lease_until)
grep -q '^r-rc=0 r-out=\[20[0-9-]*T[0-9:]*Z\]$' "$T/s.out" && ok "S1 pjl_renew rc 0 prints lease_until" || bad "S1 renew: $(cat "$T/s.out")"
grep -qx 's-rc=3 s-out=\[\]' "$T/s.out" && ok "S3 pjl_renew with a wrong fence rc 3" || bad "S3 renew: $(cat "$T/s.out")"
grep -qx 'l-rc=0' "$T/s.out" && ok "S1 pjl_release rc 0" || bad "S1 release: $(cat "$T/s.out")"
grep -qx 'm-rc=3' "$T/s.out" && ok "S3 pjl_release by a non-holder rc 3" || bad "S3 release: $(cat "$T/s.out")"
[ "$(row $MC p2 | jq -r .holder)" = holder-a ] && [ -n "$U" ] && ok "S1 the row is A's, released" || bad "S1 row: $(row $MC p2)"

echo "S3: a missing argument sends nothing"
N0=$(wc -l < "$T/srv.log")
( eval "$LIBS"
  pjl_acquire $MC p3; echo "a=$?"; pjl_acquire $MC '' holder-a; echo "a2=$?"
  pjl_renew $MC p3 holder-a; echo "r=$?"; pjl_release $MC p3 holder-a; echo "l=$?" ) > "$T/m.out" 2>/dev/null
[ "$(tr '\n' ' ' < "$T/m.out")" = "a=1 a2=1 r=1 l=1 " ] && ok "S3 every missing argument rc 1" || bad "S3 rcs: $(cat "$T/m.out")"
[ "$(wc -l < "$T/srv.log")" = "$N0" ] && ok "S3 no request sent" || bad "S3 requests: $(tail -n +"$((N0+1))" "$T/srv.log")"

echo "S4: sourcing runs nothing"
N0=$(wc -l < "$T/srv.log")
SO=$(bash -c ". '$H/bin/lib/project-lease.sh'" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$SO" ] && ok "S4 sourcing rc 0, prints nothing" || bad "S4 rc $RC out [$SO]"
[ "$(wc -l < "$T/srv.log")" = "$N0" ] && ok "S4 no request" || bad "S4 requests"
NJ=$(bash -c ". '$H/bin/lib/project-lease.sh'; pjl_acquire $MC p4 holder-a; echo \$?" 2>/dev/null)
[ "$NJ" = 1 ] && ok "S4 without the jobs client: rc 1" || bad "S4 no client: [$NJ]"

# ============================================================================
echo "S5: an answer the lib does not know is rc 1"
answer() { curl -sS -X PUT -d "$1" "$JOBS_URL/__answer" > /dev/null; }
s5() { # s5 <name> <answer json> <call...>
  local name="$1" a="$2"; shift 2
  answer "$a"
  ( eval "$LIBS"; o=$("$@"); echo "rc=$? out=[$o]" ) > "$T/s5.out" 2>/dev/null
  grep -qx 'rc=1 out=\[\]' "$T/s5.out" && ok "S5 $name: rc 1, prints nothing" || bad "S5 $name: $(cat "$T/s5.out")"
}
s5 "acquire 409 lost" '{"status":409,"body":"{\"error\":\"lost\"}"}' pjl_acquire $MC p6 holder-a
s5 "renew 409 held" '{"status":409,"body":"{\"error\":\"held\"}"}' pjl_renew $MC p6 holder-a 1
s5 "release 409 conflict" '{"status":409,"body":"{\"error\":\"conflict\"}"}' pjl_release $MC p6 holder-a 1
s5 "acquire 200 no fence" '{"status":200,"body":"{\"lease_until\":\"2026-10-15T00:00:00Z\"}"}' pjl_acquire $MC p6 holder-a
s5 "acquire 200 fence 1.5" '{"status":200,"body":"{\"fence\":1.5}"}' pjl_acquire $MC p6 holder-a
s5 "acquire 200 not json" '{"status":200,"body":"ok"}' pjl_acquire $MC p6 holder-a
s5 "renew 200 no lease_until" '{"status":200,"body":"{\"fence\":1}"}' pjl_renew $MC p6 holder-a 1
s5 "acquire 500" '{"status":500,"body":"{\"error\":\"held\"}"}' pjl_acquire $MC p6 holder-a
answer '{}'

# ============================================================================
echo "S2: an outage is rc 1, never 3"
( eval "$LIBS"; JOBS_URL=http://127.0.0.1:9; pjl_acquire $MC p5 holder-a; echo "rc=$?" ) > "$T/s2a.out" 2>/dev/null
grep -qx 'rc=1' "$T/s2a.out" && ok "S2 port closed: rc 1" || bad "S2 closed: $(cat "$T/s2a.out")"
( eval "$LIBS"; pjl_acquire $MC p5 holder-a > /dev/null; echo "pre=$?" ) > "$T/s2p.out" 2>/dev/null
curl -sS -X POST "$JOBS_URL/__drop" > /dev/null
C=$(post acquire "$(body $MC p5 holder-a)")
[ "$C" = 503 ] && [ "$(out .error)" = "project_leases schema not applied" ] && ok "S2 the dropped table answers 503" || bad "S2 503: $C $(cat "$T/out.json")"
( eval "$LIBS"
  pjl_acquire $MC p5 holder-b; echo "a=$?"; pjl_renew $MC p5 holder-a 1; echo "r=$?"
  pjl_release $MC p5 holder-a 1; echo "l=$?" ) > "$T/s2b.out" 2>/dev/null
[ "$(tr '\n' ' ' < "$T/s2b.out")" = "a=1 r=1 l=1 " ] && ok "S2 503: acquire, renew, release rc 1" || bad "S2 503 rcs: $(cat "$T/s2b.out")"

echo "project-lease.bh-6883: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
