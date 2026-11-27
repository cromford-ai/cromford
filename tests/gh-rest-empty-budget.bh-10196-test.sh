#!/bin/bash
# tests/gh-rest-empty-budget.bh-10196-test.sh — a timed lane sends no GET when
# the persisted reading of its bucket says remaining 0 with a reset in the
# future. gh_rest answers rc 75 (quota-reserve) before the request, writes no
# ledger row, and logs ONE [gh-empty-budget] line per lane, process and reset.
# Writes, wake-started runs, shells outside a lane and unknown readings are not
# refused. The settings row lane.<id>.gh_rest_empty_budget_gate turns it off.
#
# No network: `gh` is a PATH stub that logs every call. The clock is pinned
# with GH_REST_EMPTY_NOW. The token is a fixture value.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/gh-rest-empty-budget.bh-10196-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

scratch_install_closure bin/lib/gh-rest.sh "$T/repo" >/dev/null || { echo "closure install failed"; exit 1; }
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/tmp" "$T/bin"
export TMPDIR="$T/tmp" PATH="$T/bin:$PATH" GH_STUB_DIR="$T" GH_ETAG=0
export GH_REST_EMPTY_NOW=1790000000
export GH_TOKEN=tok-fixture-1
unset WAKE_LAUNCH GH_REST_OPTIONAL GH_REST_EMPTY_BUDGET_GATE GH_QUOTA_RESERVE LANE_GATE_RUN GITHUB_TOKEN GH_USE_PAT

# The stub answers 200 with no X-RateLimit headers, so a sent call never
# rewrites the reading under test. $T/stub-once (when present) is the answer
# for the next call only.
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_STUB_DIR/gh-calls.log"
if [ -f "$GH_STUB_DIR/stub-once" ]; then cat "$GH_STUB_DIR/stub-once"; rm -f "$GH_STUB_DIR/stub-once"; exit 1; fi
printf 'HTTP/2.0 200 OK\r\n\r\n{"ok":true}'
exit 0
STUB
chmod +x "$T/bin/gh"

. "$T/repo/bin/lib/gh-rest.sh" || { echo "could not source gh-rest.sh"; exit 1; }

BKT=$(gh_quota_bucket)
LED="$T/h/state/gh-rest-ledger"
LOG="$T/h/logs/gh-rate.log"
calls() { [ -f "$T/gh-calls.log" ] && wc -l < "$T/gh-calls.log" | tr -d ' ' || echo 0; }
rows()  { cat "$LED"/*.tsv 2>/dev/null | wc -l | tr -d ' '; }
said()  { [ -f "$LOG" ] && grep -c "\[gh-empty-budget\] lane=$1 " "$LOG" || echo 0; }
# reading <remaining> <reset> [bucket] — the line _gh_quota_persist writes.
reading() { mkdir -p "$LED"; printf '%s 7100 %s 1789999000\n' "$1" "$2" > "$LED/.quota-${3:-$BKT}"; }
fresh() { # a clean ledger, log, call log, switch memo and settings cache
  rm -rf "$T/h/state/gh-rest-ledger"; mkdir -p "$LED"
  rm -f "$LOG" "$T/gh-calls.log" "$T/stub-once" "$T/h/state/settings-cache.json"
  unset _GH_EMPTY_SW_LANE _GH_EMPTY_SW_VAL
}
# gets <n> — n GETs in this shell; echoes how many answered rc 75 quota-reserve.
gets() {
  local i n=0 rc
  for i in $(seq 1 "$1"); do
    rc=0; gh_rest GET "repos/o/r/issues/$i" > "$T/out" || rc=$?
    [ "$rc" = 75 ] && [ "${GH_REST_REASON:-}" = quota-reserve ] && n=$((n + 1))
  done
  echo "$n"
}
settings() { printf '%s\n' "$1" > "$T/h/state/settings-cache.json"; }

# ══ G1/G2: a timed lane, empty bucket: 50 GETs, 0 requests, 1 line ════════
fresh; reading 0 1790000600
export LANE_GATE_RUN=pr-owner-sweep/-
n=$(gets 50)
[ "$n" = 50 ] && ok || bad "G1a: 50 GETs must each answer rc 75 quota-reserve, got $n"
[ "$(calls)" = 0 ] && ok || bad "G1b: no request may reach gh, got $(calls)"
[ "$(said pr-owner-sweep)" = 1 ] && ok || bad "G2a: exactly 1 [gh-empty-budget] line, got $(said pr-owner-sweep)"
[ "$(rows)" = 0 ] && ok || bad "G2b: a refused GET writes no ledger row, got $(rows)"
grep -q "bucket=$BKT core remaining 0 until 2026-09-21T14:23:20Z" "$LOG" && ok \
  || bad "G2c: the line names the bucket and the reset: $(cat "$LOG")"
for i in $(seq 1 25); do x=$(gh_rest GET "repos/o/r/pulls/$i"); : "$x"; done
[ "$(said pr-owner-sweep)" = 1 ] && ok || bad "G2d: 25 GETs inside \$( ) add no line, got $(said pr-owner-sweep)"
[ "$(calls)" = 0 ] && [ "$(rows)" = 0 ] && ok || bad "G2e: subshell GETs send nothing and ledger nothing"

# ══ G3: another lane says its own line; a new reset says one more ═════════
export LANE_GATE_RUN=unblock/-
gets 3 >/dev/null
[ "$(said unblock)" = 1 ] && ok || bad "G3a: the second lane gets its own line, got $(said unblock)"
reading 0 1790000900
gets 3 >/dev/null
[ "$(said unblock)" = 2 ] && ok || bad "G3b: a new reset window says one more line, got $(said unblock)"
[ "$(calls)" = 0 ] && ok || bad "G3c: no request, got $(calls)"

# ══ G4: a wake-started run and a shell outside a lane send every GET ══════
fresh; reading 0 1790000600
export LANE_GATE_RUN=pr-owner-sweep/- WAKE_LAUNCH=1
gets 50 >/dev/null
[ "$(calls)" = 50 ] && ok || bad "G4a: WAKE_LAUNCH=1 sends 50 GETs, got $(calls)"
unset WAKE_LAUNCH LANE_GATE_RUN
fresh; reading 0 1790000600
gets 50 >/dev/null
[ "$(calls)" = 50 ] && ok || bad "G4b: no LANE_GATE_RUN sends 50 GETs, got $(calls)"
[ "$(said pr-owner-sweep)" = 0 ] && ok || bad "G4c: no line when nothing was refused"

# ══ G5: writes are never refused ══════════════════════════════════════════
fresh; reading 0 1790000600
export LANE_GATE_RUN=pr-owner-sweep/-
for m in POST PUT PATCH DELETE; do
  rc=0; gh_rest "$m" repos/o/r/issues/1/labels -f x=1 > "$T/out" || rc=$?
  [ "$rc" = 0 ] && ok || bad "G5: $m must be sent and answer 0, got rc $rc"
done
[ "$(calls)" = 4 ] && ok || bad "G5b: 4 writes = 4 requests, got $(calls)"
[ "$(rows)" = 4 ] && ok || bad "G5c: 4 writes = 4 ledger rows, got $(rows)"

# ══ G6: near misses — each GET is sent ═════════════════════════════════════
nearmiss() { # nearmiss <label> — reading prepared by the caller
  local before rc=0
  before=$(calls)
  gh_rest GET repos/o/r/issues/1 > "$T/out" || rc=$?
  [ "$rc" = 0 ] && [ "$(calls)" = $((before + 1)) ] && ok || bad "G6 $1: the GET must be sent (rc $rc)"
}
fresh; reading 1 1790000600;           nearmiss "remaining 1"
fresh; reading 0 1790000000;           nearmiss "reset = now (stale)"
fresh; reading 0 1789990000;           nearmiss "reset in the past"
fresh; reading 0 -;                    nearmiss "no reset"
fresh;                                 nearmiss "no reading file"
fresh; printf 'abc 7100 1790000600 1\n' > "$LED/.quota-$BKT"; nearmiss "torn file"
fresh; reading 7000 1790000600; reading 0 1790000600 "graphql-$BKT"; nearmiss "graphql bucket at 0, core 7000"
fresh; reading 0 1790000600 pat-000000000000; nearmiss "another PAT's bucket at 0"
fresh; printf '0 30 1790000600 1\n' > "$LED/.quota-$BKT"; nearmiss "search limit (30) at 0"
fresh; printf '0 - 1790000600 1\n' > "$LED/.quota-$BKT"; nearmiss "no limit in the reading"
[ "$(said pr-owner-sweep)" = 0 ] && ok || bad "G6: no near miss says a line"

# ══ G7: round trip — a live 403 with remaining 0 makes the next GET refused
fresh
printf 'HTTP/2.0 403 Forbidden\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Limit: 7100\r\nX-RateLimit-Reset: 1790000600\r\n\r\n{"message":"API rate limit exceeded"}' > "$T/stub-once"
rc=0; gh_rest GET repos/o/r/issues/1 > "$T/out" || rc=$?
[ "$rc" = 75 ] && [ "$(calls)" = 1 ] && ok || bad "G7a: the live 403 is sent and answers 75 (rc $rc, calls $(calls))"
n=$(gets 5)
[ "$n" = 5 ] && [ "$(calls)" = 1 ] && ok || bad "G7b: after the 403 the next 5 GETs are refused without a request ($n refused, $(calls) calls)"

# ══ S1-S5: the per-lane switch ═════════════════════════════════════════════
export LANE_GATE_RUN=pr-owner-sweep/-
fresh; reading 0 1790000600
settings '{"values":{"lane.pr-owner-sweep.gh_rest_empty_budget_gate":"0"}}'
gets 50 >/dev/null
[ "$(calls)" = 50 ] && ok || bad "S1: row 0 for the lane sends 50 GETs, got $(calls)"
for w in off FALSE no; do
  fresh; reading 0 1790000600
  settings "{\"values\":{\"lane.pr-owner-sweep.gh_rest_empty_budget_gate\":\"$w\"}}"
  gets 2 >/dev/null
  [ "$(calls)" = 2 ] && ok || bad "S1 $w: row '$w' turns the rule off, got $(calls) calls"
done
fresh; reading 0 1790000600
settings '{"values":{"lane.pr-owner-sweep.gh_rest_empty_budget_gate":false}}'
gets 2 >/dev/null
[ "$(calls)" = 2 ] && ok || bad "S1 json false: a boolean false row turns the rule off, got $(calls) calls"
fresh; reading 0 1790000600
settings '{"values":{"lane.unblock.gh_rest_empty_budget_gate":"0"}}'
n=$(gets 5)
[ "$n" = 5 ] && [ "$(calls)" = 0 ] && ok || bad "S2: a row for ANOTHER lane leaves this lane on ($n refused, $(calls) calls)"
fresh; reading 0 1790000600
n=$(gets 5)
[ "$n" = 5 ] && [ "$(calls)" = 0 ] && ok || bad "S3: no row = on ($n refused, $(calls) calls)"
fresh; reading 0 1790000600
GH_REST_EMPTY_BUDGET_GATE=0 gets 5 >/dev/null
[ "$(calls)" = 5 ] && ok || bad "S4: env GH_REST_EMPTY_BUDGET_GATE=0 sends, got $(calls)"
fresh; reading 0 1790000600
settings '{"values":{"lane.pr-owner-sweep.gh_rest_empty_budget_gate":"1"}}'
n=$(gets 5)
[ "$n" = 5 ] && [ "$(calls)" = 0 ] && ok || bad "S5: row 1 = on ($n refused, $(calls) calls)"
fresh; reading 0 1790000600
settings '{"values":{"lane.pr-owner-sweep.gh_rest_empty_budget_gate":"0"}}'
GH_REST_EMPTY_BUDGET_GATE=1 gets 5 >/dev/null
[ "$(calls)" = 0 ] && ok || bad "S6: env 1 wins over a row 0, got $(calls) calls"

# ══ O1: the old reserve rule is unchanged ══════════════════════════════════
# The reserve rule reads the box clock (not the seam), so its reset is far in the future.
fresh; reading 300 4000000000
rc=0; GH_REST_OPTIONAL=1 GH_QUOTA_RESERVE=600 gh_rest GET repos/o/r/issues/1 > "$T/out" || rc=$?
[ "$rc" = 75 ] && [ "$(calls)" = 0 ] && ok || bad "O1a: an optional read below the reserve is still refused (rc $rc)"
[ "$(said pr-owner-sweep)" = 0 ] && ok || bad "O1b: the reserve rule writes no [gh-empty-budget] line"
fresh; reading 0 1790000600
rc=0; GH_REST_OPTIONAL=1 GH_QUOTA_RESERVE=600 gh_rest GET repos/o/r/issues/1 > "$T/out" || rc=$?
[ "$rc" = 75 ] && [ "$(said pr-owner-sweep)" = 1 ] && ok || bad "O1c: an optional read on an empty bucket is refused by the new rule"

# ══ B1: gh_rest_budget_empty — the lanes' stop check ═══════════════════════
fresh; reading 0 1790000600
gh_rest_budget_empty repos/o/r && ok || bad "B1a: empty bucket, timed lane = empty"
reading 1 1790000600
gh_rest_budget_empty repos/o/r && bad "B1b: remaining 1 is not empty" || ok
reading 0 1790000600
WAKE_LAUNCH=1 gh_rest_budget_empty repos/o/r && bad "B1c: a wake run is never stopped" || ok
[ "$(calls)" = 0 ] && [ "$(said pr-owner-sweep)" = 0 ] && ok || bad "B1d: the check sends nothing and says nothing"

# ══ R1: marker retention (GH_LEDGER_TTL_H) ═════════════════════════════════
fresh; reading 0 1790000600
touch -d '2026-01-01 00:00:00' "$LED/.empty-said.old-lane.1" "$LED/.quota-zz"
gets 1 >/dev/null
[ -e "$LED/.empty-said.old-lane.1" ] && bad "R1a: a marker older than GH_LEDGER_TTL_H is removed" || ok
[ -e "$LED/.quota-zz" ] && ok || bad "R1b: only .empty-said markers are swept"

echo "gh-rest-empty-budget.bh-10196: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
