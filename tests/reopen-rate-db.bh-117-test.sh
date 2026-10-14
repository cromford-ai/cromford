#!/bin/bash
# reads-run-build: raw — the D1 one-copy pin asserts the driver's own text carries no `reopen trust signal` block (it lives once, in bin/lib/rb/gates.sh, since the BH-572 cut); the flatten puts the module's copy back in the driver's place, so only a raw read can see a second copy pasted into the driver.
# tests/reopen-rate-db.bh-117-test.sh — BH-117: the reopen rate is a D1 row.
#
# The demoter used to read state/reopen-rate.json, a file only the hub has, so
# on every watcher box the trust signal was inert. Now bin/reopen-metrics.sh
# writes one `ledgers` row per project (kind=reopen_rate) after the file, and
# the build's `reopen trust signal` block reads the row through jobs-client
# first and falls back to the file only when there is no usable row.
#
#   A  the two jobs-client verbs, against a curl stub
#   B  the real bin/reopen-metrics.sh end to end: one PUT per project, detail
#      equal to the file, a failed PUT named once in ALERTS and never counted
#   C  the signal + demoter blocks, extracted VERBATIM from the flattened
#      driver, with the REAL bin/jobs-client.sh sourced and only curl stubbed
#   D  one copy: since the BH-572 cut the block lives only in bin/lib/rb/gates.sh,
#      never again inline in bin/run-build.sh
#   E  the rescope's negative: state/ is NOT synced, harness-sync is untouched
#
# No network: every request lands on the curl stub, HARNESS_SECRET is a test
# value and JOBS_URL points at http://jobs.test. No LLM.
# Run from anywhere: tests/reopen-rate-db.bh-117-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- stubs: curl records and answers from $T/rules; gh answers [] -----
# A rule is `<substring of "METHOD URL BODY">\t<http code>\t<response body>`;
# the first match wins, and no match answers 200 {}.
mkdir -p "$T/stub"
cat > "$T/stub/curl" <<'EOF'
#!/bin/bash
TD=__T__
m=GET; url=""; body=""
while [ $# -gt 0 ]; do case "$1" in
  -X) m="$2"; shift 2 ;;
  --data-binary) body="$2"; shift 2 ;;
  -m|--connect-timeout|-w|-H) shift 2 ;;
  http*) url="$1"; shift ;;
  *) shift ;;
esac; done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
printf '%s\t%s\t%s\n' "$m" "$url" "$body" >> "$TD/curl.log"
line="$m $url $body"; code=200; resp='{}'
if [ -r "$TD/rules" ]; then
  while IFS=$'\t' read -r pat c r; do
    [ -n "$pat" ] || continue
    case "$line" in *"$pat"*) code="$c"; resp="$r"; break ;; esac
  done < "$TD/rules"
fi
printf '%s\n%s' "$resp" "$code"
EOF
sed -i "s|__T__|$T|" "$T/stub/curl"
printf '#!/bin/bash\necho "[]"\n' > "$T/stub/gh"
chmod +x "$T/stub/curl" "$T/stub/gh"
export PATH="$T/stub:$PATH"

row() { # row <detail-json-string> -> a GET /api/ledger 200 body
  jq -nc --arg d "$1" '{ledger:{kind:"reopen_rate",key:"x",status:"measured",detail:$d,updated_at:"2026-09-23T04:15:02Z"}}'
}
rules() { printf '%s\n' "$@" > "$T/rules"; }

# ============================================================================
# A. the jobs-client verbs
# ============================================================================
A="$T/a"; mkdir -p "$A/env" "$A/logs" "$A/bin"; cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$A/bin/"
# $0 is NOT the client's path: jobs-client.sh runs its CLI dispatch when
# BASH_SOURCE[0] equals $0, which would answer for the verb instead of the verb.
jc() { # jc <verb> [args] -> stdout, rc of the verb, the REAL client sourced
  HARNESS="$A" HARNESS_ENV_DIR="$A/env" HARNESS_SECRET=test JOBS_URL=http://jobs.test JOBS_RETRIES=0 \
    bash -c '. "$1" >/dev/null 2>&1 || exit 99; shift; "$@"' jc "$DIR/bin/jobs-client.sh" "$@" 2>/dev/null
}

# A1
: > "$T/curl.log"; rules
jc reopen_rate_put p 3 20 >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "A1 reopen_rate_put on a 200 must return 0 (got $RC)"
L=$(grep -c . "$T/curl.log")
[ "$L" = 1 ] && ok || bad "A1 expected exactly one request (got $L)"
IFS=$'\t' read -r M U BODY < "$T/curl.log"
[ "$M $U" = "PUT http://jobs.test/api/ledger" ] && ok || bad "A1 must PUT /api/ledger (got '$M $U')"
[ "$(jq -r '[.kind,.key,.status]|join(",")' <<<"$BODY" 2>/dev/null)" = "reopen_rate,p,measured" ] && ok \
  || bad "A1 body must be kind=reopen_rate key=p status=measured (got $BODY)"
[ "$(jq -cS '.detail|fromjson' <<<"$BODY" 2>/dev/null)" = '{"builds_total":20,"reopens_14d":3}' ] && ok \
  || bad "A1 detail must parse to {reopens_14d:3,builds_total:20} (got $BODY)"

# A2 junk numbers never leave the box
: > "$T/curl.log"
for args in "p x 20" "p 3 -1" "p 3 ''" "'' 3 20" "p 1.5 20"; do
  eval "jc reopen_rate_put $args" >/dev/null; RC=$?
  [ "$RC" = 1 ] && ok || bad "A2 reopen_rate_put $args must return 1 (got $RC)"
done
[ ! -s "$T/curl.log" ] && ok || bad "A2 a refused put must send nothing (got $(cat "$T/curl.log"))"

# A3 the key is URI-encoded
: > "$T/curl.log"; rules
jc reopen_rate_get 'a b' >/dev/null
grep -q $'^GET\thttp://jobs.test/api/ledger?kind=reopen_rate&key=a%20b\t' "$T/curl.log" && ok \
  || bad "A3 GET must carry kind=reopen_rate&key=a%20b (got $(cat "$T/curl.log"))"

# A4 a good row
rules "key=p	200	$(row '{"reopens_14d":3,"builds_total":20}')"
OUT=$(jc reopen_rate_get p); RC=$?
[ "$RC" = 0 ] && ok || bad "A4 a good row must return 0 (got $RC)"
[ "$OUT" = $'3\t20\t2026-09-23T04:15:02Z' ] && ok || bad "A4 must print N<TAB>D<TAB>updated_at (got '$OUT')"

# A5 no row is a real answer, not an outage
rules "key=p	404	{\"error\":\"not found\"}"
OUT=$(jc reopen_rate_get p); RC=$?
[ "$RC" = 2 ] && ok || bad "A5 a 404 must return 2 (got $RC)"
[ -z "$OUT" ] && ok || bad "A5 a 404 must print nothing (got '$OUT')"

# A6 malformed or unreachable: unusable, never read as 0/0
for D in 'not json' '{"reopens_14d":-1,"builds_total":20}' '{"reopens_14d":1.5,"builds_total":20}' \
         '{"reopens_14d":"lots","builds_total":20}' '{"reopens_14d":3}'; do
  rules "key=p	200	$(row "$D")"
  OUT=$(jc reopen_rate_get p); RC=$?
  [ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "A6 detail '$D' must return 1 and print nothing (got rc=$RC out='$OUT')"
done
rules "key=p	500	{\"error\":\"boom\"}"
jc reopen_rate_get p >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "A6 a 500 must return 1 (got $RC)"

# ============================================================================
# B. the real bin/reopen-metrics.sh writes the rows
# ============================================================================
B="$T/b"; mkdir -p "$B/env" "$B/logs" "$B/state" "$B/builds" "$B/bin"; cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$B/bin/"
cat > "$B/fleet.conf" <<'EOF'
p-one    Acme/p-one    -  -  1 box-small
p-two    Acme/p-two    -  -  2 box-small
p-three  Acme/p-three  -  -  3 box-small
EOF
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do mkdir -p "$B/builds/p-one-A-$i"; echo "PR_MERGED x" > "$B/builds/p-one-A-$i/RESULT"; done
for i in 1 2 3; do mkdir -p "$B/builds/p-two-B-$i"; echo "PR_MERGED x" > "$B/builds/p-two-B-$i/RESULT"; done
TODAY=$(date -u +%Y%m%d)
printf 'date,project,key,from,to\n%s,p-one,#1,done,open\n%s,p-one,#2,done,open\n' "$TODAY" "$TODAY" > "$B/logs/reopens.csv"
RJ="$B/state/reopen-rate.json"

# TEST-CHANGE(BH-6159): REOPEN_REASON=0 scopes section B to the reopen_rate rows.
# The lane now also saves a reopen_reason row for each in-window CSV row (the
# #1/#2 fixture rows), which tests/reopen-reason.bh-6159-test.sh pins.
brun() { # brun <HARNESS_SECRET> -> rc of the real lane
  : > "$T/curl.log"; : > "$B/logs/ALERTS.log"; rm -f "$RJ"
  HARNESS="$B" HARNESS_ENV_DIR="$B/env" FLEET_CONF="$B/fleet.conf" HARNESS_SECRET="$1" REOPEN_REASON=0 \
    JOBS_URL=http://jobs.test JOBS_RETRIES=0 bash "$DIR/bin/reopen-metrics.sh" > "$T/b.out" 2>&1
  echo $?
}
rowlines() { grep -c 'reopen-metrics.*reopen_rate rows' "$B/logs/ALERTS.log"; }

# B1 one PUT per fleet.conf project
rules
RC=$(brun test)
[ "$RC" = 0 ] && ok || bad "B1 the lane must exit 0 (got $RC: $(cat "$T/b.out"))"
PUTS=$(grep -c $'^PUT\thttp://jobs.test/api/ledger\t' "$T/curl.log")
[ "$PUTS" = 3 ] && ok || bad "B1 expected 3 PUT /api/ledger, got $PUTS: $(cat "$T/curl.log")"
KEYS=$(awk -F'\t' '$1=="PUT"{print $3}' "$T/curl.log" | jq -r 'select(.kind=="reopen_rate" and .status=="measured") | .key' 2>/dev/null | sort | paste -sd' ' -)
[ "$KEYS" = "p-one p-three p-two" ] && ok || bad "B1 the row keys must be the fleet.conf projects (got '$KEYS')"
grep -q 'reopen_rate rows: 3 written, 0 failed' "$T/b.out" && ok || bad "B1 the lane log must count what was written (got $(cat "$T/b.out"))"
[ "$(rowlines)" = 0 ] && ok || bad "B1 a clean run must not alert (got $(cat "$B/logs/ALERTS.log"))"

# B2 each row's detail is the file's entry, and the file keeps its shape
jq -e 'to_entries | length == 3 and all(.value | (keys == ["builds_total","reopens_14d"]))' "$RJ" >/dev/null 2>&1 && ok \
  || bad "B2 the file must still be written with {reopens_14d,builds_total} (got $(cat "$RJ" 2>/dev/null))"
[ "$(jq -c '."p-one"' "$RJ" 2>/dev/null)" = '{"reopens_14d":2,"builds_total":12}' ] && ok \
  || bad "B2 fixture sanity: p-one should measure 2/12 (got $(jq -c '."p-one"' "$RJ" 2>/dev/null))"
for P in p-one p-two p-three; do
  WANT=$(jq -cS --arg p "$P" '.[$p]' "$RJ" 2>/dev/null)
  GOT=$(awk -F'\t' '$1=="PUT"{print $3}' "$T/curl.log" | jq -cS --arg p "$P" 'select(.key==$p) | .detail | fromjson' 2>/dev/null)
  [ -n "$WANT" ] && [ "$GOT" = "$WANT" ] && ok || bad "B2 $P row detail must equal the file entry (want '$WANT' got '$GOT')"
done

# B3 one PUT fails: named once, never counted, the others still sent
rules '"key":"p-two"	500	{"error":"boom"}'
RC=$(brun test)
[ "$RC" = 0 ] && ok || bad "B3 a failed PUT must not fail the lane (got $RC)"
[ "$(rowlines)" = 1 ] && ok || bad "B3 expected ONE reopen_rate ALERTS line (got: $(cat "$B/logs/ALERTS.log"))"
AL=$(grep 'reopen-metrics.*reopen_rate rows' "$B/logs/ALERTS.log")
grep -q 'p-two' <<<"$AL" && grep -qi 'not written' <<<"$AL" && ok || bad "B3 the line must name p-two and say not written (got '$AL')"
grep -qE 'p-one|p-three' <<<"$AL" && bad "B3 the line must not name projects that were written (got '$AL')" || ok
[ "$(grep -c $'^PUT\t' "$T/curl.log")" = 3 ] && ok || bad "B3 the other projects must still be sent"
grep -q 'reopen_rate rows: 2 written, 1 failed' "$T/b.out" && ok || bad "B3 a failed PUT must not be counted as written (got $(cat "$T/b.out"))"

# B4 no secret: the file is still written, one line says the rows were not, rc 0
rules
RC=$(brun "")
[ "$RC" = 0 ] && ok || bad "B4 no secret must still exit 0 (got $RC)"
[ -s "$RJ" ] && ok || bad "B4 the file must still be written"
[ "$(rowlines)" = 1 ] && ok || bad "B4 expected ONE reopen_rate ALERTS line (got: $(cat "$B/logs/ALERTS.log"))"
[ ! -s "$T/curl.log" ] && ok || bad "B4 no request may leave without a secret (got $(cat "$T/curl.log"))"

# ============================================================================
# C. the build's signal + demoter, verbatim, over the REAL jobs-client
# ============================================================================
awk '/^# >>> reopen trust signal/{f=1;next}  /^# <<< reopen trust signal/{exit}  f' "$RB_ALL" > "$T/signal.sh"
awk '/^# >>> reopen trust demoter/{f=1;next} /^# <<< reopen trust demoter/{exit} f' "$RB_ALL" > "$T/demoter.sh"
[ -s "$T/signal.sh" ] && [ -s "$T/demoter.sh" ] && ok || bad "C could not extract the signal/demoter blocks"

file() { if [ -n "${1:-}" ]; then printf '%s' "$1" > "$T/crate.json"; else rm -f "$T/crate.json"; fi; }
HH="$T/ch"
gate() { # gate <project> <tier> -> "<TIER>|<QA_NOTE>"
  scratch_rm "$HH"; mkdir -p "$HH/state" "$HH/build" "$HH/env" "$HH/logs"
  [ -s "$T/crate.json" ] && cp "$T/crate.json" "$HH/state/reopen-rate.json"
  : > "$T/curl.log"
  HARNESS="$HH" HARNESS_ENV_DIR="$HH/env" HARNESS_SECRET=test JOBS_URL=http://jobs.test JOBS_RETRIES=0 \
  BUILD="$HH/build" PROJECT="$1" KEY=K TIER="$2" \
  bash -c 'set -uo pipefail; . "$2" >/dev/null 2>&1; STAMP(){ echo TS; }; QA_NOTE=""; . "$0"; . "$1"; printf "%s|%s" "$TIER" "$QA_NOTE"' \
    "$T/signal.sh" "$T/demoter.sh" "$DIR/bin/jobs-client.sh" 2>/dev/null
}
plog() { cat "$HH/build/pipeline.log" 2>/dev/null; }

# C1 worker down, no file -> nothing changes
rules "key=hot-os	500	{}"; file
[ "$(gate hot-os 1)" = "1|" ] && ok || bad "C1 a worker 500 with no file must not demote (got '$(gate hot-os 1)')"

# C2 a hot row alone demotes
rules "key=hot-os	200	$(row '{"reopens_14d":5,"builds_total":20}')"; file
G=$(gate hot-os 1)
[ "${G%%|*}" = 2 ] && ok || bad "C2 a 5/20 row must force tier-2 (got '$G')"
# TEST-CHANGE(BH-4581): wording only, tier logic unchanged
grep -q 'TRUST: reopen rate 0.25 (5/20, 14d) over 0.15 — recorded tier-2 (risk signal)' <<<"$G" && ok \
  || bad "C2 QA_NOTE must carry the row's rate (got '$G')"
grep -q $'^GET\thttp://jobs.test/api/ledger?kind=reopen_rate&key=hot-os\t' "$T/curl.log" && ok \
  || bad "C2 the block must read the row by its exact key (got $(cat "$T/curl.log"))"

# C3 the watcher-box case: there is no file at all
[ ! -e "$HH/state/reopen-rate.json" ] && ok || bad "C3 fixture: no rate file may exist"
[ "${G%%|*}" = 2 ] && ok || bad "C3 a box with no file must demote off the row alone"

# C7 the read is logged with its source
grep -q 'TRUST: reopen signal from db row 2026-09-23T04:15:02Z: 5/20 — reopen rate 0.25' <<<"$(plog)" && ok \
  || bad "C7 pipeline.log must name the db row and the numbers (got '$(plog)')"
[ "$(grep -c 'TRUST: reopen signal from' <<<"$(plog)")" = 1 ] && ok || bad "C7 exactly one signal line per build"

# C4 the row wins over the file
rules "key=hot-os	200	$(row '{"reopens_14d":1,"builds_total":20}')"; file '{"hot-os":{"reopens_14d":5,"builds_total":20}}'
[ "$(gate hot-os 1)" = "1|" ] && ok || bad "C4 a cold row must win over a hot file (got '$(gate hot-os 1)')"
grep -q 'TRUST: reopen signal from db row .*: 1/20 — no demotion' <<<"$(plog)" && ok || bad "C4 log must say db row, no demotion (got '$(plog)')"

# C5 no row -> the file
rules "key=hot-os	404	{}"; file '{"hot-os":{"reopens_14d":5,"builds_total":20}}'
[ "$(gate hot-os 1 | cut -d'|' -f1)" = 2 ] && ok || bad "C5 a 404 must fall back to a hot file"
grep -q "TRUST: reopen signal from file $HH/state/reopen-rate.json: 5/20" <<<"$(plog)" && ok || bad "C5 log must name the file (got '$(plog)')"
# ...and a row for ANOTHER project is still a 404 for this one
rules "key=other-os	200	$(row '{"reopens_14d":9,"builds_total":10}')" "key=hot-os	404	{}"; file
[ "$(gate hot-os 1)" = "1|" ] && ok || bad "C5 another project's row must not demote this one"

# C6 malformed rows never demote
for D in 'not json' '{"reopens_14d":"lots","builds_total":20}' '{"reopens_14d":-1,"builds_total":20}' '{"reopens_14d":1.5,"builds_total":20}'; do
  rules "key=hot-os	200	$(row "$D")"; file
  [ "$(gate hot-os 1)" = "1|" ] && ok || bad "C6 detail '$D' must not demote (got '$(gate hot-os 1)')"
done
# a small denominator from the row is still below the sample floor
rules "key=hot-os	200	$(row '{"reopens_14d":1,"builds_total":3}')"; file
[ "$(gate hot-os 1)" = "1|" ] && ok || bad "C6 a row under REOPEN_MIN_SAMPLE must not demote"

# C8 nothing anywhere: logged honestly
rules "key=hot-os	404	{}"; file
[ "$(gate hot-os 1)" = "1|" ] && ok || bad "C8 no row, no file must not demote"
grep -q 'TRUST: reopen signal from none: ?/? — no demotion' <<<"$(plog)" && ok || bad "C8 log must say none (got '$(plog)')"

# C9 demotion only: a spotless row never promotes
rules "key=hot-os	200	$(row '{"reopens_14d":0,"builds_total":500}')"; file
[ "$(gate hot-os 2 | cut -d'|' -f1)" = 2 ] && ok || bad "C9 a spotless row must NOT promote tier-2"

# ============================================================================
# D1. the one-copy pin: the block lives in the stage module, once
# ============================================================================
# Until the BH-572 cut this block lived twice (inline in the driver and in
# bin/lib/rb/gates.sh) and D1 pinned the two byte-identical. After the cut there
# is one copy, so the drift is impossible and the pin says so: absent from the
# raw driver, exactly once in gates.sh, exactly once in the pipeline that runs.
blk() { awk '/^# >>> reopen trust signal/,/^# <<< reopen trust signal/' "$1"; }
blk "$DIR/bin/run-build.sh"    > "$T/sig.driver"
blk "$DIR/bin/lib/rb/gates.sh" > "$T/sig.gates"
[ ! -s "$T/sig.driver" ] && ok \
  || bad "D1 bin/run-build.sh carries its own reopen trust signal block again — a second copy is the drift the cut removed"
[ "$(grep -c '^# >>> reopen trust signal' "$DIR/bin/lib/rb/gates.sh")" = 1 ] && ok \
  || bad "D1 bin/lib/rb/gates.sh must hold the reopen trust signal block exactly once"
[ "$(grep -c '^# >>> reopen trust signal' "$RB_ALL")" = 1 ] && ok \
  || bad "D1 the pipeline (flatten) must run the reopen trust signal block exactly once"
grep -q 'reopen_rate_get' "$T/sig.gates" && ok || bad "D1 the live block must read through reopen_rate_get"

# ============================================================================
# E1. rescope negative: harness-sync is unchanged, state/ is not distributed
# ============================================================================
# A CONTENT assertion, not a diff check (lead review): a diff-vs-merge-base arm
# would red every later PR and merge-queue batch that edits harness-sync.sh for
# its own reasons. What the rescope forbids is SHIPPING the file, so assert that.
if ! grep -q 'reopen-rate' "$DIR/bin/harness-sync.sh"; then ok
else bad "E1 bin/harness-sync.sh must not distribute state/reopen-rate.json: the rescope says the rate lives in D1"; fi

echo "reopen-rate-db.bh-117-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
