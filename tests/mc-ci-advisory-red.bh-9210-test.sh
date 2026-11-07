#!/bin/bash
# tests/mc-ci-advisory-red.bh-9210-test.sh — BH-9210: the conductor's red rule
# counts only the checks Mergify requires.
#
# Incident (2026-11-07): every project-6 PR sat RED_TWICE. The report-only
# workflows `unit-clock` and `unit-shuffle` failed on every head, and
# mc_ci_state answered `red` for any failed latest workflow run. Mergify
# required only `ci` and `e2e-ratchet`, and both were green.
#
# Part A drives the REAL mc_ci_state (bin/lib/merge-conductor-lib.sh) with
# gh_rest, mc_queue_provider and mc_mergify_required_checks stubbed:
#   A1-A6  a failed run with no failed required job is advisory (green side)
#   N1-N13, P1, K1  the red side and the near misses
#   R1, R3, R4, R5  the red ladder re-runs only the runs with a failed required job
#   C1, C2 the RED_TWICE reason names the failing required checks
#   L1-L4  the head ledger round-trip (mca_note, mca_count_24h)
# Part B drives the WHOLE bin/merge-conductor.sh on an advisory-only head:
#   R2  READY, 0 reruns, no red strike, no RED_TWICE, 0 model calls
# 0 network: gh_rest is stubbed in part A; a fake gh and curl are first on PATH.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-ci-advisory-red.bh-9210-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-ci-advisory-red: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN MC_CI_ADVISORY_RED MC_CI_JOBS_PAGES_MAX MC_CI_ADVISORY_KEEP_D MC_CI_REQUIRED_ONLY
ADV="$DIR/bin/lib/mc-ci-advisory.sh"

H1=$(printf 'a%.0s' $(seq 40))
SLUG=example-org/mkey-os
CLK=1794070000            # 2026-11-07T16:46:40Z

# runs <id|name|status|conclusion|started[|attempt]>... — an actions/runs page on H1.
runs() { local x; for x in "$@"; do printf '%s\n' "$x"; done | jq -Rnc --arg h "$H1" '[inputs | split("|")
  | {id: (.[0]|tonumber), name: .[1], path: (".github/workflows/" + .[1] + ".yml"), status: .[2],
     conclusion: (if .[3] == "" then null else .[3] end), run_started_at: .[4], created_at: .[4],
     run_attempt: ((.[5] // "1")|tonumber), head_sha: $h}]
  | {total_count: length, workflow_runs: .}'; }
# jobs <total> <name|conclusion>... — one jobs page of a run.
jobs() { local tot="$1" x; shift; for x in "$@"; do printf '%s\n' "$x"; done | jq -Rnc --argjson t "$tot" '[inputs | select(length > 0) | split("|")
  | {name: .[0], status: "completed", conclusion: (if .[1] == "" then null else .[1] end)}]
  | {total_count: $t, jobs: .}'; }
CI_OK='101|ci|completed|success|2026-11-07T15:00:00Z'
CI_RED='101|ci|completed|failure|2026-11-07T15:00:00Z'
UC_RED='102|unit-clock|completed|failure|2026-11-07T15:01:00Z'
UC_JOBS=('lane|success' 'build|success' 'Unit control 1/8|success' 'report|failure')

# ============================================================================
# Part A — the real mc_ci_state, seams stubbed.
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
A="$T/a"; mkdir -p "$A"
fx_mc_harness "$DIR" "$A" || exit 1
export HARNESS="$A/h"
( cd "$DIR" && scratch_install_closure bin/lib/flaky.sh "$HARNESS" >/dev/null ) || exit 1
# The lib under test. Before BH-9210 it does not exist and mc_ci_state runs as on main.
if [ -r "$ADV" ]; then ( cd "$DIR" && scratch_install_closure bin/lib/mc-ci-advisory.sh "$HARNESS" >/dev/null ) || exit 1; fi
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh"
mc_init
export TMPDIR="$A"
FX="$A/fx"; mkdir -p "$FX"
LEDGER="$MC_STATE_DIR/ci-advisory-red.tsv"
mc_now() { printf '%s\n' "$CLK"; }
mc_ci_read_timeout_s() { echo 30; }
mc_queue_provider() { cat "$FX/provider" 2>/dev/null || echo none; }
mc_mergify_required_checks() { printf '%s\n' "$1" >> "$FX/req.log"; [ -e "$FX/req-fail" ] && return 75; cat "$FX/req" 2>/dev/null; return 0; }
gh_rest() {
  local id pg
  printf '%s %s\n' "$1" "$2" >> "$FX/rest.log"
  case "$1 $2" in
    "GET "*"/actions/runs?head_sha="*) GH_REST_STATUS=200; cat "$FX/runs.json" ;;
    "GET "*"/actions/runs/"*"/jobs?"*)
      id=${2#*/actions/runs/}; id=${id%%/*}; pg=${2##*page=}
      [ -e "$FX/jobs-$id.fail" ] && { GH_REST_STATUS=502; return 75; }
      [ -r "$FX/jobs-$id-$pg.json" ] || { GH_REST_STATUS=404; return 75; }
      GH_REST_STATUS=200; cat "$FX/jobs-$id-$pg.json" ;;
    "GET "*"/pulls/"*) GH_REST_STATUS=200; printf '{"head":{"sha":"%s"}}\n' "$H1" ;;
    *) GH_REST_STATUS=404; return 75 ;;
  esac
}
# The fake gh: flaky_failed_runs' `gh api ... -q <expr>` and the rerun write.
mkdir -p "$A/fakebin"
cat > "$A/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"run rerun"*) printf '%s\n' "\$*" >> "$FX/reruns.txt"; exit 0 ;;
  "api repos/"*"/actions/runs?head_sha="*)
    q=""; while [ \$# -gt 0 ]; do [ "\$1" = -q ] && { q="\$2"; break; }; shift; done
    jq -r "\$q" "$FX/runs.json"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$A/fakebin/gh"
PATH="$A/fakebin:$PATH"

reset() {
  scratch_rm "$FX"; mkdir -p "$FX"; printf 'ci\ne2e-ratchet\n' > "$FX/req"; echo mergify > "$FX/provider"
  : > "$MC_LOG"; rm -f "$LEDGER"; : > "$MC_ATTEMPTS"
  unset MC_CI_ADVISORY_RED MC_CI_JOBS_PAGES_MAX MC_CI_ADVISORY_KEEP_D
}
WORD=""
# st [slug] — one mc_ci_state call as a plain command (its globals stay here).
st() { mc_ci_state "${1:-$SLUG}" "$H1" > "$FX/word" 2>/dev/null; WORD=$(cat "$FX/word"); }
want() { st "${3:-}"; [ "$WORD" = "$2" ] && ok || bad "$1: want $2, got '$WORD' (log: $(tail -2 "$MC_LOG" | tr '\n' ' '))"; }
advn() { grep -c "advisory-red: ${1:-}" "$MC_LOG" 2>/dev/null || true; }
uc_jobs() { jobs 4 "${UC_JOBS[@]}" > "$FX/jobs-102-1.json"; }

# A1 — the repro: ci success, unit-clock failed in its report job only.
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"; uc_jobs
want "A1 ci success + unit-clock failure (report only)" green
[ "$(advn unit-clock)" = 1 ] && ok || bad "A1 exactly one advisory-red: unit-clock line (got $(advn unit-clock); log: $(cat "$MC_LOG"))"
grep -q "advisory-red: unit-clock on $SLUG ${H1:0:8}: its failed run holds no failed required check (ci, e2e-ratchet); not red" "$MC_LOG" && ok \
  || bad "A1 the line names the workflow, the head and the required set ($(grep advisory-red "$MC_LOG"))"
grep -q "actions/runs/102/jobs?filter=latest&per_page=100&page=1" "$FX/rest.log" && ok || bad "A1 one latest-attempt jobs read of the failed run ($(cat "$FX/rest.log"))"
! grep -q "actions/runs/101/jobs" "$FX/rest.log" && ok || bad "A1 no jobs read of a green run"
[ "${MC_CI_ADVISORY:-}" = unit-clock ] && [ "${MC_CI_REQ_APPLIED:-}" = 1 ] && [ "${MC_CI_REQ_SHA:-}" = "$H1" ] && ok \
  || bad "A1 globals: MC_CI_ADVISORY=${MC_CI_ADVISORY:-} applied=${MC_CI_REQ_APPLIED:-} sha=${MC_CI_REQ_SHA:-}"
want "A1 second call on the same head" green
[ "$(advn unit-clock)" = 1 ] && ok || bad "A1 a second call on the same head adds no line (got $(advn unit-clock))"
[ "$(grep -c . "$LEDGER" 2>/dev/null)" = 1 ] && ok || bad "A1/L2 one ledger line per head ($(cat "$LEDGER" 2>/dev/null))"

# A2 — the same page with ci failed (its ci job failed): red, names ci.
reset; runs "$CI_RED" "$UC_RED" > "$FX/runs.json"; uc_jobs
jobs 2 'ci|failure' 'perf-budgets (report only)|success' > "$FX/jobs-101-1.json"
want "A2 ci failure + unit-clock failure" red
[ "${MC_CI_RED_CHECKS:-}" = ci ] && [ "${MC_CI_RED_RUN_IDS:-}" = 101 ] && ok \
  || bad "A2 red checks 'ci' and run 101 (checks '${MC_CI_RED_CHECKS:-}', runs '${MC_CI_RED_RUN_IDS:-}')"
[ "$(advn unit-clock)" = 1 ] && ok || bad "A2 the unit-clock run is still logged advisory ($(advn unit-clock))"

# A3 — no queue rules (.mergify.yml unread): the old rule, red.
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"; uc_jobs; : > "$FX/req-fail"
want "A3 .mergify.yml unread" red
[ "${MC_CI_REQ_APPLIED:-}" = 0 ] && ! grep -q '/jobs' "$FX/rest.log" && [ "$(advn)" = 0 ] && ok \
  || bad "A3 the rule did not run: no jobs read, no advisory line (applied=${MC_CI_REQ_APPLIED:-})"

# A4 — unit-shuffle the same way.
reset; runs "$CI_OK" '103|unit-shuffle|completed|failure|2026-11-07T15:02:00Z' > "$FX/runs.json"
jobs 3 'lane|success' 'Unit shuffle 2/8|success' 'report|failure' > "$FX/jobs-103-1.json"
want "A4 unit-shuffle failure" green
[ "$(advn unit-shuffle)" = 1 ] && ok || bad "A4 one advisory-red: unit-shuffle line"
# A5 — workflow ci failed in a report-only job; job ci succeeded.
reset; runs "$CI_RED" > "$FX/runs.json"; jobs 2 'ci|success' 'perf-budgets (report only)|failure' > "$FX/jobs-101-1.json"
want "A5 workflow ci failed, job ci success" none
[ "$(advn ci)" = 1 ] && ok || bad "A5 one advisory-red: ci line"
reset; runs "$CI_RED" '104|e2e|completed|success|2026-11-07T15:00:00Z' > "$FX/runs.json"; jobs 2 'ci|success' 'perf-budgets (report only)|failure' > "$FX/jobs-101-1.json"
want "A5b the same beside a green e2e" green
# A6 — workflow e2e failed in a shard; e2e-ratchet succeeded.
reset; runs "$CI_OK" '104|e2e|completed|failure|2026-11-07T15:03:00Z' > "$FX/runs.json"
jobs 3 'E2E 1/4|success' 'E2E 2/4|failure' 'e2e-ratchet|success' > "$FX/jobs-104-1.json"
want "A6 e2e shard failed, e2e-ratchet success" green

# The red side.
redjob() { reset; runs "$CI_RED" > "$FX/runs.json"; jobs 2 "ci|$1" 'lint|failure' > "$FX/jobs-101-1.json"; }
redjob skipped;   want "N1 required job skipped in a failed run" red
redjob cancelled; want "N2 required job cancelled in a failed run" red
redjob timed_out; want "N2b required job timed_out in a failed run" red
redjob '';        want "N2c required job with no conclusion" red
[ "$(advn)" = 0 ] && ok || bad "N1/N2 no advisory line on the red side"
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"; : > "$FX/jobs-102.fail"
want "N3 jobs read HTTP 502" red
[ "$(advn)" = 0 ] && [ "${MC_CI_RED_RUN_IDS:-}" = 102 ] && ok || bad "N3 no advisory line; the run stays a rerun candidate (${MC_CI_RED_RUN_IDS:-})"
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"; echo 'not json' > "$FX/jobs-102-1.json"
want "N4 jobs page does not parse" red
[ "$(advn)" = 0 ] && ok || bad "N4 no advisory line on an unparseable page"
# P1 — 150 jobs: page 1 holds 100 green ones, page 2 the failed ci job.
p1() { reset; runs "$CI_RED" > "$FX/runs.json"
  local i l=(); for i in $(seq 1 100); do l+=("Unit $i/100|success"); done
  jobs 150 "${l[@]}" > "$FX/jobs-101-1.json"
  l=(); for i in $(seq 1 49); do l+=("E2E $i/49|success"); done
  jobs 150 "${l[@]}" "ci|$1" > "$FX/jobs-101-2.json"; }
p1 failure; want "P1 the failed ci job is on page 2" red
grep -q 'actions/runs/101/jobs?filter=latest&per_page=100&page=2' "$FX/rest.log" && ok || bad "P1 page 2 was read"
p1 success; want "P1b every job read over two pages, ci success" none
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"; jobs 0 > "$FX/jobs-102-1.json"
want "N13 a failed run that lists no job" red
# N5 — total past the page cap: unread, red.
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"
for pg in 1 2 3 4; do jobs 400 "j$pg|success" > "$FX/jobs-102-$pg.json"; done
want "N5 total_count 400 past 3 pages" red
! grep -q 'page=4' "$FX/rest.log" && ok || bad "N5 no read past MC_CI_JOBS_PAGES_MAX pages"
[ "$(advn)" = 0 ] && ok || bad "N5 no advisory line on a partial read"
MC_CI_JOBS_PAGES_MAX=4 want "N5b MC_CI_JOBS_PAGES_MAX=4 reads all 4 pages" red
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"
for pg in 1 2 3 4; do jobs 4 "j$pg|success" > "$FX/jobs-102-$pg.json"; done
want "N5c 4 jobs over 4 pages, default cap 3: partial" red
MC_CI_JOBS_PAGES_MAX=4 want "N5d knob 4: the 4 pages hold the total, advisory" green
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"; uc_jobs; : > "$FX/req"
want "N6 no check-success name" red
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"; uc_jobs; echo github > "$FX/provider"
want "N7 provider github" red
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"; uc_jobs
want "N8 project-4" red example-org/project-4
[ ! -s "$FX/req.log" ] && ok || bad "N8 project-4 reads no .mergify.yml"
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"; uc_jobs; MC_CI_ADVISORY_RED=0
want "K1 MC_CI_ADVISORY_RED=0" red
[ "$(advn)" = 0 ] && ok || bad "K1 no advisory line with the knob off"
unset MC_CI_ADVISORY_RED
# N9 — attempt 2 of the ci run failed (attempt 1 passed): filter=latest is attempt 2.
reset; runs '101|ci|completed|failure|2026-11-07T15:00:00Z|2' > "$FX/runs.json"; jobs 1 'ci|failure' > "$FX/jobs-101-1.json"
want "N9 attempt 2 failed" red
# N10 — an advisory failure beside an in-progress ci: pending, not green.
reset; runs '101|ci|in_progress||2026-11-07T15:00:00Z' "$UC_RED" > "$FX/runs.json"; uc_jobs
want "N10 advisory failure + ci in progress" pending
# N11 — the only latest run is advisory: none, not green.
reset; runs "$UC_RED" > "$FX/runs.json"; uc_jobs
want "N11 only an advisory run" none
# N12 — near-miss name: ci-extra failed and there is no ci job in the run.
reset; runs "$CI_OK" '105|lint|completed|failure|2026-11-07T15:00:00Z' > "$FX/runs.json"; jobs 1 'ci-extra|failure' > "$FX/jobs-105-1.json"
want "N12 ci-extra failed, no job named ci" green
reset; runs "$CI_OK" '105|lint|completed|failure|2026-11-07T15:00:00Z' > "$FX/runs.json"; jobs 2 'CI|failure' 'ci|cancelled' > "$FX/jobs-105-1.json"
want "N12b CI failed and ci cancelled in one run" red
[ "${MC_CI_RED_CHECKS:-}" = ci ] && ok || bad "N12b names ci, not CI (${MC_CI_RED_CHECKS:-})"
# The unchanged words.
reset; runs "$CI_OK" '106|lint|completed|cancelled|2026-11-07T15:00:00Z' > "$FX/runs.json"; want "W1 green + cancelled" green
reset; runs '106|lint|completed|cancelled|2026-11-07T15:00:00Z' > "$FX/runs.json"; want "W2 all cancelled" none
! grep -q '/jobs' "$FX/rest.log" && ok || bad "W2 no jobs read without a failed run"

# R — the red ladder. mc_red_rerun reads flaky_failed_runs through the fake gh.
P=mkey; KEY="$SLUG#31"
reruns() { if [ -f "$FX/reruns.txt" ]; then grep -c . "$FX/reruns.txt"; else echo 0; fi; }
# R1 — mixed red: one rerun, for the run with the failed ci job.
reset; runs "$CI_RED" "$UC_RED" > "$FX/runs.json"; uc_jobs; jobs 1 'ci|failure' > "$FX/jobs-101-1.json"
st; mc_red_rerun "$SLUG" "$KEY" "$H1"; rc=$?
[ "$rc" = 0 ] && [ "$(reruns)" = 1 ] && grep -q "run rerun 101 --failed" "$FX/reruns.txt" && ok \
  || bad "R1 one rerun, of run 101 (rc $rc; reruns: $(cat "$FX/reruns.txt" 2>/dev/null))"
grep -q "$KEY run 102 (unit-clock) holds no failed required check — not re-run" "$MC_LOG" && ok || bad "R1 the dropped run is logged ($(tail -3 "$MC_LOG"))"
# R1b — the filter reads mc_ci_state itself when the globals are for another head (a memo hit).
reset; runs "$CI_RED" "$UC_RED" > "$FX/runs.json"; uc_jobs; jobs 1 'ci|failure' > "$FX/jobs-101-1.json"
MC_CI_REQ_SHA=""; MC_CI_REQ_APPLIED=""; MC_CI_RED_RUN_IDS=""
mc_red_rerun "$SLUG" "$KEY" "$H1"
[ "$(reruns)" = 1 ] && grep -q "run rerun 101 --failed" "$FX/reruns.txt" && ok || bad "R1b memo hit: one rerun, of run 101 ($(cat "$FX/reruns.txt" 2>/dev/null))"
# R3 — no queue rules: every failed run is re-run, as before.
reset; runs "$CI_RED" "$UC_RED" > "$FX/runs.json"; : > "$FX/req-fail"
st; mc_red_rerun "$SLUG" "$KEY" "$H1"
[ "$(reruns)" = 2 ] && ok || bad "R3 no queue rules: both failed runs re-run ($(cat "$FX/reruns.txt" 2>/dev/null))"
# R4 — a stale `red` for an advisory-only head: no rerun, and no rung spent.
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"; uc_jobs
MC_CI_REQ_SHA=""; mc_red_rerun "$SLUG" "$KEY" "$H1"; rc=$?
[ "$rc" = 1 ] && [ "$(reruns)" = 0 ] && ! grep -q "^cirerun " "$MC_ATTEMPTS" && ok \
  || bad "R4 advisory-only: rc 1, 0 reruns, no cirerun mark (rc $rc; reruns $(reruns); $(grep cirerun "$MC_ATTEMPTS"))"
grep -q "$KEY no failed run on ${H1:0:8} holds a failed required check — no rerun, no rung spent" "$MC_LOG" && ok || bad "R4 the log says why ($(tail -2 "$MC_LOG"))"
# R5 — the flake rerun path filters the same way.
flaky_all_known() { return 0; }
flaky_run_tests() { echo "job:x$2"; }
reset; runs "$CI_RED" "$UC_RED" > "$FX/runs.json"; uc_jobs; jobs 1 'ci|failure' > "$FX/jobs-101-1.json"
st; mc_flake_rerun "$SLUG" "$KEY" "$H1"
[ "$(reruns)" = 1 ] && grep -q "run rerun 101 --failed" "$FX/reruns.txt" && ok || bad "R5 flake rerun: one rerun, of run 101 ($(cat "$FX/reruns.txt" 2>/dev/null))"
reset; runs "$CI_OK" "$UC_RED" > "$FX/runs.json"; uc_jobs; st
mc_flake_rerun "$SLUG" "$KEY" "$H1"; rc=$?
[ "$rc" = 1 ] && [ "$(reruns)" = 0 ] && ok || bad "R5b flake rerun on an advisory-only head: rc 1, 0 reruns (rc $rc)"
unset -f flaky_all_known flaky_run_tests

# C — the RED_TWICE reason.
cls() { mc_classify OPEN UNSTABLE MERGEABLE "$H1" "$H1" APPROVE claude red 0 0 0 0 WAIT_CI - ; }
reset; runs "$CI_RED" "$UC_RED" > "$FX/runs.json"; uc_jobs; jobs 1 'ci|failure' > "$FX/jobs-101-1.json"; st
OUT=$(MC_RED_RUNG=2 MC_RED_CONSEC= cls)
[[ $OUT == RED_TWICE$'\t'*"; failing required checks: ci" ]] && [[ $OUT != *unit-clock* ]] && ok || bad "C1 rung 2 names ci and not unit-clock ($OUT)"
OUT=$(MC_RED_RUNG=0 MC_RED_CONSEC="bbbbbbbb ${H1:0:8}|report, ci" cls)
[[ $OUT == *"red on consecutive heads bbbbbbbb and ${H1:0:8}; failing required checks: ci" ]] && ok || bad "C1b consecutive heads name the required check ($OUT)"
MC_CI_REQ_SHA=""; MC_CI_RED_CHECKS=""
OUT=$(MC_RED_RUNG=2 MC_RED_CONSEC= cls)
[ "$OUT" = "RED_TWICE	red-twice: still red on ${H1:0:8} after its failed jobs were re-run once" ] && ok || bad "C2 no globals (memo hit): the old text ($OUT)"
OUT=$(MC_RED_RUNG=0 MC_RED_CONSEC="bbbbbbbb ${H1:0:8}|report, ci" cls)
[[ $OUT == *"; failing checks: report, ci" ]] && ok || bad "C2b consecutive heads, no globals: the old list ($OUT)"

# L — the head ledger round-trip.
if command -v mca_note >/dev/null 2>&1 && command -v mca_count_24h >/dev/null 2>&1; then
  reset
  mca_note Org/a "$(printf '1%.0s' $(seq 40))" unit-clock
  mca_note Org/a "$(printf '2%.0s' $(seq 40))" unit-clock,unit-shuffle
  mca_note Org/b "$(printf '3%.0s' $(seq 40))" unit-clock
  OUT=$(mca_count_24h "$LEDGER" "$CLK")
  [ "$OUT" = '[{"repo":"Org/a","heads":2},{"repo":"Org/b","heads":1}]' ] && ok || bad "L1 two heads of Org/a, one of Org/b ($OUT)"
  mca_note Org/b "$(printf '3%.0s' $(seq 40))" unit-clock
  [ "$(grep -c . "$LEDGER")" = 3 ] && [ "$(advn)" = 4 ] && ok || bad "L2 the same head twice: one line ($(grep -c . "$LEDGER") lines, $(advn) log lines)"
  # L3 — prune: a line older than the keep window goes, a new one stays.
  printf '%s\tOrg/c\t%s\tunit-clock\n' $((CLK - 8*86400)) "$(printf '4%.0s' $(seq 40))" >> "$LEDGER"
  printf '%s\tOrg/c\t%s\tunit-clock\n' $((CLK - 2*86400)) "$(printf '5%.0s' $(seq 40))" >> "$LEDGER"
  mca_note Org/d "$(printf '6%.0s' $(seq 40))" unit-clock
  ! grep -q "$(printf '4%.0s' $(seq 40))" "$LEDGER" && grep -q "$(printf '5%.0s' $(seq 40))" "$LEDGER" && ok || bad "L3 prune by MC_CI_ADVISORY_KEEP_D ($(cat "$LEDGER"))"
  OUT=$(mca_count_24h "$LEDGER" "$CLK")
  [ "$(jq -r '[.[] | select(.repo == "Org/c")] | length' <<<"$OUT")" = 0 ] && ok || bad "L3 a line older than 24 h is not counted ($OUT)"
  # L4 — junk lines are dropped; a missing file is [].
  printf 'junk\nabc\tOrg/e\t%s\tx\n' "$(printf '7%.0s' $(seq 40))" >> "$LEDGER"
  OUT=$(mca_count_24h "$LEDGER" "$CLK")
  [ "$(jq -r '[.[] | select(.repo == "Org/e")] | length' <<<"$OUT")" = 0 ] && [ "$(jq -r '.[0].repo' <<<"$OUT")" = Org/a ] && ok || bad "L4 junk dropped ($OUT)"
  [ "$(mca_count_24h "$A/nope.tsv" "$CLK")" = '[]' ] && ok || bad "L4 a missing file is []"
else
  bad "L0 mca_note / mca_count_24h are not defined (bin/lib/mc-ci-advisory.sh missing)"
fi

# ============================================================================
# Part B — R2: the WHOLE bin/merge-conductor.sh on an advisory-only head. The
# check-runs page holds more runs than one page (project-6's shape), so the
# BH-8012 override cannot fire; only this rule can make the head green.
# ============================================================================
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
vpf_export || exit 1
C="$T/w"; CH="$C/h"; BX="$C/fx"
fx_mc_harness "$DIR" "$C" || exit 1
fx_conductor_tick "$DIR" "$C" || exit 1
( cd "$DIR" && for s in bin/lib/autoenqueue.sh bin/lib/mc-hold-comment.sh bin/lib/gh-repo-token.sh bin/lib/flaky.sh bin/merge-conductor.d/bh-8012-required-ci.sh; do scratch_install_closure "$s" "$CH" >/dev/null || exit 1; done ) || exit 1
if [ -r "$ADV" ]; then ( cd "$DIR" && scratch_install_closure bin/lib/mc-ci-advisory.sh "$CH" >/dev/null ) || exit 1; fi
cat > "$CH/bin/lib/ticket-ownership.sh" <<'EOF2'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
EOF2
printf 'pdg_hold() { return 1; }\n' > "$CH/bin/lib/pr-dep-gate.sh"
printf 'mkey %s - - 2 box-m\n' "$SLUG" > "$CH/fleet.conf"
: > "$CH/env/global.env"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$CH/bin/$s.sh"; chmod +x "$CH/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s/model-calls.txt\nexit 0\n' "$BX" > "$CH/bin/agent-call.sh"; chmod +x "$CH/bin/agent-call.sh"
REC="$CH/builds/pool-mkey-TK-31-202611070001"; mkdir -p "$REC"
U="https://github.com/$SLUG/pull"
YML=$(printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success=ci\n      - check-success=e2e-ratchet\n    merge_method: squash\n' | base64 | tr -d '\n')
mkdir -p "$C/fakebin"
cat > "$C/fakebin/curl" <<EOF
#!/bin/bash
out=""; w=""; M=GET; URL=""
while [ \$# -gt 0 ]; do case "\$1" in
  -o) out="\$2"; shift 2 ;; -w) w="\$2"; shift 2 ;; -X) M="\$2"; shift 2 ;;
  -m|-H|--connect-timeout|--data-binary|-d|--max-time) shift 2 ;;
  -*) shift ;; *) URL="\$1"; shift ;;
esac; done
printf '%s %s\n' "\$M" "\$URL" >> "$C/curl-all.log"
emit() {
  if [ -n "\$out" ]; then printf '%s' "\$2" > "\$out"; else printf '%s' "\$2"; fi
  case "\$w" in '') ;; \$'\n'*) printf '\n%s' "\$1" ;; *) printf '%s' "\$1" ;; esac
}
case "\$M \$URL" in
  "GET "*/api/verdicts\?*) emit 200 "\$(cat "$BX/standing" 2>/dev/null || echo '{"standing":null}')" ;;
  "PUT "*|"POST "*) emit 200 '{"ok":true}' ;;
  *) emit 404 '{"error":"not found"}' ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/curl"
for m in claude codex; do printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s/model-calls.txt\nexit 0\n' "$BX" > "$C/fakebin/$m"; chmod +x "$C/fakebin/$m"; done
cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$BX/calls.txt"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"run rerun"*|*"/rerun"*) printf '%s\n' "\$*" >> "$BX/reruns.txt" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$YML\"}" ;;
  *"actions/runs/102/jobs"*) restpr --raw 200 "\$(cat "$BX/jobs-102.json")" ;;
  *"actions/runs?head_sha="*" -q "*) q=""; while [ \$# -gt 0 ]; do [ "\$1" = -q ] && { q="\$2"; break; }; shift; done; jq -r "\$q" "$BX/runs.json" ;;
  *"actions/runs?head_sha="*) restpr --raw 200 "\$(cat "$BX/runs.json")" ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 "\$(cat "$BX/cr.json")" ;;
  *"api -i -X POST repos/$SLUG/issues/31/comments -f body=@mergifyio queue"*) printf '%s\n' "\$*" >> "$BX/queue-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"issues/31/labels"*) restpr --raw 200 '[]' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$BX/merges.txt"; exit 0 ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X POST "*|*"api -X POST "*) restpr --raw 201 '{}' ;;
  *"api -i -X GET repos/$SLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*) restpr OPEN "$H1" ticket/TK-31 main "" MERGEABLE unstable operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$C/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/gh"
cat > "$C/list.json" <<J
[{"number":31,"url":"$U/31","headRefOid":"$H1","headRefName":"ticket/TK-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"UNSTABLE","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
printf '#!/bin/bash\nexit 0\n' > "$C/fakebin/flock"; chmod +x "$C/fakebin/flock"
touch "$CH/flags/merge-conductor-actions" "$CH/flags/merge-conductor-merge"
CLOG="$CH/logs/merge-conductor.log"; ATT="$CH/state/merge-conductor/attempts.txt"
scratch_rm "$CH/state"; mkdir -p "$CH/state" "$BX"; : > "$CLOG"; : > "$CH/logs/ALERTS.log"
runs "$CI_OK" '103|e2e|completed|success|2026-11-07T15:00:30Z' "$UC_RED" > "$BX/runs.json"
jobs 4 "${UC_JOBS[@]}" > "$BX/jobs-102.json"
# 150 check runs on the head: one page does not hold them (BH-8012 stands down).
jobs 150 'ci|success' 'e2e-ratchet|success' | jq -c '{total_count: 150, check_runs: [.jobs[] | . + {started_at: "2026-11-07T15:00:00Z", completed_at: "2026-11-07T15:10:00Z"}]}' > "$BX/cr.json"
jq -nc '{standing:{verdict:"MERGE-WITH-NOTES",source:"lead",id:5334,created_at:"2026-11-07T15:20:00Z",report_url:"-",reviewer:"lead"}}' > "$BX/standing"
echo "PR_CREATED $U/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
( cd "$C" && env PATH="$C/fakebin:$PATH" HARNESS="$CH" HARNESS_ENV_DIR= HARNESS_SECRET=fixture-secret JOBS_URL=http://worker.test JOBS_RETRIES=0 GH_TOKEN=pat-fixture \
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
  bash "$CH/bin/merge-conductor.sh" >/dev/null 2>"$C/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$C/tick.err"; }
ROW=$(awk -F'\t' -v k="$SLUG#31" '$1==k {print $2 "|" $7}' "$CH/state/merge-conductor/pr-state.tsv" 2>/dev/null)
nr() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
[ "${ROW%%|*}" = READY ] || [ "${ROW%%|*}" = QUEUED ] && ok || bad "R2 advisory-only head: READY or QUEUED (row: $ROW; log: $(grep '#31' "$CLOG" | tail -4))"
[ "$(nr "$BX/reruns.txt")" = 0 ] && ok || bad "R2 0 rerun calls ($(cat "$BX/reruns.txt" 2>/dev/null))"
! grep -q "^red $SLUG#31 " "$ATT" 2>/dev/null && ! grep -q RED_TWICE "$CLOG" && ok || bad "R2 no red strike, no RED_TWICE ($(grep -E '^red ' "$ATT" 2>/dev/null))"
[ "$(nr "$BX/model-calls.txt")" = 0 ] && ok || bad "R2 0 model calls ($(cat "$BX/model-calls.txt" 2>/dev/null))"
[ "$(grep -c "advisory-red: unit-clock on $SLUG ${H1:0:8}" "$CLOG")" = 1 ] && ok || bad "R2 one advisory-red: unit-clock line in the conductor log"
OUT=$(awk '{print $2}' "$C/curl-all.log" 2>/dev/null | grep -vE '^https?://[a-z0-9.-]+\.test(/|$)' || true)
[ -z "$OUT" ] && ok || bad "V1 a curl left the fixture hosts: $OUT"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "mc-ci-advisory-red.bh-9210: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
