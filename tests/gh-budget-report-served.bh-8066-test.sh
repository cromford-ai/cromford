#!/bin/bash
# tests/gh-budget-report-served.bh-8066-test.sh — BH-8066: bin/gh-budget-report.sh
# counts requests, not cache replays, and prints how each REST call was served.
#
# The gh shim's cache (bin/lib/gh-cache.sh) writes a ledger row with status
# `cache` and counted 0 for a call it answered from disk. That row is not a
# request: it must not raise rest_calls or calls per merged PR, which is the
# number the ticket measures. It shows only in the SERVED line and the `served`
# JSON block (ledger column 15: cache | 304 | 200 | -).
#
#   V1  --local over rows written by the REAL gh_ledger_append: 3 cache, 1 304,
#       2 200 (+1 graphql): rest_calls 3, served {cache 3, 304 1, 200 2}, the
#       SERVED line with each share, the TOP and repo tables without cache rows
#   V2  a line written before column 15 (14 columns): served from column 6
#   V3  the fleet read against a worker with no group=served (400): served null,
#       `SERVED n/a (worker has no served group)`, the rest stays fleet
#   V4  the fleet read against a worker that has the group: the shares print
#   V5  bin/gh-ledger-report.sh and bin/gh-quota-report.sh --local skip them too
#
# 0 network: the worker is a fixture jobs-client.sh that defines `_jobs_req`.
# Run from anywhere: bash tests/gh-budget-report-served.bh-8066-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$T/tmp"
export HARNESS="$H" TMPDIR="$T/tmp" GH_BUDGET_KEEP_DAYS=90 FIX="$T"
export GH_BUDGET_NOW=1792699200   # determinism: ok pinned (2026-10-22T20:00Z); hour files are named by the wall clock, which is later
unset HARNESS_LANE HARNESS_LANE_PROJECT PROJECT GH_TOKEN HARNESS_SECRET JOBS_URL
LED="$H/state/gh-rest-ledger"

# ── V1: rows from the real writer ───────────────────────────────────────────
(
  # shellcheck source=bin/lib/gh-rest-ledger.sh
  . "$REPO/bin/lib/gh-rest-ledger.sh"
  export HARNESS_LANE=fixture-lane
  for _ in 1 2 3; do gh_ledger_append gh GET repos/o/r/pulls/12 cache 0; done
  gh_ledger_append rest GET repos/o/r/pulls/12 304 0
  gh_ledger_append gh GET repos/o/r/pulls/12 200 1
  gh_ledger_append rest GET repos/o/r/issues/5 200 1
  GH_REST_QUOTA_RESOURCE=graphql gh_ledger_append gh POST graphql 200 1
)
[ "$(cat "$LED"/*.tsv | awk -F'\t' '{print NF}' | sort -u)" = 15 ] && ok || bad "V1-0: the real writer writes 15 columns"
bash "$REPO/bin/gh-budget-report.sh" --local --json --merged 1 > "$T/j" 2> "$T/e"; rc=$?
[ "$rc" = 0 ] && ok || bad "V1a: rc 0, got $rc: $(cat "$T/e")"
[ "$(jq -r '.totals.rest_calls' "$T/j")" = 3 ] && ok || bad "V1b: rest_calls counts requests only (304 + 2x200 = 3), got $(jq -c .totals "$T/j")"
[ "$(jq -r '.totals.rest_counted' "$T/j")" = 2 ] && ok || bad "V1c: rest_counted = 2, got $(jq -c .totals "$T/j")"
[ "$(jq -r '.per_merged_pr.calls' "$T/j")" = 3 ] && ok || bad "V1d: calls per merged PR excludes cache rows, got $(jq -c .per_merged_pr "$T/j")"
[ "$(jq -r '[.served.cache, .served["304"], .served["200"], .served["-"]] | join(" ")' "$T/j")" = "3 1 2 0" ] && ok \
  || bad "V1e: served = cache 3, 304 1, 200 2, - 0, got $(jq -c .served "$T/j")"
[ "$(jq -r '.totals.graphql_calls' "$T/j")" = 1 ] && ok || bad "V1f: graphql stays on its own line, got $(jq -c .totals "$T/j")"
[ "$(jq -r '[.top[] | select(.path_class == "repos/o/r/pulls/N") | .calls] | add' "$T/j")" = 2 ] && ok \
  || bad "V1g: the TOP table holds no cache row (pulls/N = 304 + 200 = 2 calls), got $(jq -c .top "$T/j")"
[ "$(jq -r '.repos[] | select(.repo == "o/r") | .calls' "$T/j")" = 3 ] && ok || bad "V1h: the repo table holds no cache row, got $(jq -c .repos "$T/j")"
bash "$REPO/bin/gh-budget-report.sh" --local --merged 1 > "$T/txt" 2>&1
grep -Eq '^SERVED cache=3 \(50(\.0)?%\) 304=1 \(16\.7%\) 200=2 \(33\.3%\)$' "$T/txt" && ok \
  || bad "V1i: the SERVED line, got: $(grep SERVED "$T/txt")"
grep -q '^TOTAL rest calls=3 counted=2' "$T/txt" && ok || bad "V1j: TOTAL counts requests, got: $(grep TOTAL "$T/txt")"

# ── V5: the two local readers skip cache rows too (same rows as V1) ─────────
# 7 rows: 3 cache, 304, 2x200, graphql = 4 requests. Both reports read the
# hour files the writer just named, so they run on the wall clock (no seam
# reaches gh_ledger_append's own timestamp).
bash "$REPO/bin/gh-ledger-report.sh" --last 2h > "$T/lr" 2>&1
grep -q '^TOTAL  calls=4  counted=3 ' "$T/lr" && ok || bad "V5a: gh-ledger-report counts 4 requests, got: $(grep TOTAL "$T/lr")"
bash "$REPO/bin/gh-quota-report.sh" --local hour > "$T/qr" 2>&1
grep -q '^TOTAL  calls=4  counted=3$' "$T/qr" && ok || bad "V5b: gh-quota-report --local counts 4 requests, got: $(grep TOTAL "$T/qr")"

# ── V2: a 14-column line from before column 15 ──────────────────────────────
HOUR=$(ls "$LED" | head -n 1)
printf '2026-10-22T20:00:00Z\told-lane\t-\tGET\trepos/o/r/pulls/N\t000\t0\t-\t-\tapp\t-\tgh\t-\t-\n' >> "$LED/$HOUR"
bash "$REPO/bin/gh-budget-report.sh" --local --json > "$T/j2" 2>/dev/null
[ "$(jq -r '.served["-"]' "$T/j2")" = 1 ] && [ "$(jq -r '.totals.rest_calls' "$T/j2")" = 4 ] && ok \
  || bad "V2: a 14-column 000 line is served '-' and still a call, got $(jq -c '[.served, .totals]' "$T/j2")"
bash "$REPO/bin/gh-budget-report.sh" --local > "$T/txt2" 2>&1
grep -Eq '^SERVED cache=3 .* -=1 \(' "$T/txt2" && ok || bad "V2b: the '-' term prints when it is > 0, got: $(grep SERVED "$T/txt2")"

# ── V3/V4: the fleet read, through a fixture worker ─────────────────────────
cat > "$H/bin/jobs-client.sh" <<'JC'
#!/bin/bash
_jobs_req() {
  JOBS_HTTP=200
  printf '%s\n' "$2" >> "$FIX/jobs-calls.txt"
  case "$2" in
    *group=served*)
      [ -e "$FIX/has-served" ] || { JOBS_HTTP=400; return 1; }
      printf '{"group":"served","rows":[{"served":"cache","calls":30,"counted":0},{"served":"304","calls":10,"counted":0},{"served":"200","calls":60,"counted":60}],"truncated":false,"totals":{}}' ;;
    *group=lane-hour*) printf '{"group":"lane-hour","rows":[{"hour":"2026-10-22T19","lane":"a","calls":70,"counted":60}],"truncated":false,"totals":{"rest_calls":70,"rest_counted":60,"graphql_calls":0,"graphql_counted":0}}' ;;
    *group=lane-class*) printf '{"group":"lane-class","rows":[{"lane":"a","path_class":"repos/o/r/pulls/N","calls":70,"counted":60}],"truncated":false,"totals":{"rest_calls":70,"rest_counted":60,"graphql_calls":0,"graphql_counted":0}}' ;;
    *group=repo*) printf '{"group":"repo","rows":[{"repo":"o/r","calls":70,"counted":60}],"truncated":false,"totals":{"rest_calls":70,"rest_counted":60,"graphql_calls":0,"graphql_counted":0}}' ;;
    *) JOBS_HTTP=404; return 1 ;;
  esac
  return 0
}
JC
: > "$H/bin/lib/jobs/req.sh"
export HARNESS_SECRET=fixture-secret-bh8066
bash "$REPO/bin/gh-budget-report.sh" --json --merged 1 > "$T/j3" 2> "$T/e3"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r .source "$T/j3")" = fleet ] && ok || bad "V3a: a worker without the group stays a fleet report, rc $rc, source $(jq -r .source "$T/j3" 2>/dev/null)"
[ "$(jq -r '.served' "$T/j3")" = null ] && [ "$(jq -r '.served_why' "$T/j3")" = "worker has no served group" ] && ok \
  || bad "V3b: served is null with its reason, got $(jq -c '[.served, .served_why]' "$T/j3")"
bash "$REPO/bin/gh-budget-report.sh" --merged 1 > "$T/txt3" 2>&1
grep -q '^SERVED n/a (worker has no served group)$' "$T/txt3" && ok || bad "V3c: the n/a line, got: $(grep SERVED "$T/txt3")"
grep -q 'group=served' "$T/jobs-calls.txt" && ok || bad "V3d: the report asked for group=served"
: > "$T/has-served"
bash "$REPO/bin/gh-budget-report.sh" --merged 1 > "$T/txt4" 2>&1
grep -Eq '^SERVED cache=30 \(30(\.0)?%\) 304=10 \(10(\.0)?%\) 200=60 \(60(\.0)?%\)$' "$T/txt4" && ok \
  || bad "V4: the fleet shares, got: $(grep SERVED "$T/txt4")"

echo "gh-budget-report-served.bh-8066: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
