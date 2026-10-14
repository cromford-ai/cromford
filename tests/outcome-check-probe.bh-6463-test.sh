#!/bin/bash
# tests/outcome-check-probe.bh-6463-test.sh — `bin/outcome-check.sh --dry-run`
# as a hub live probe (BH-6463, the rest of BH-6382).
#
# The hub runs only rows of catalog/live-probes.tsv (bin/lib/live-probes.sh),
# with a 60 s timeout. So the dry run must be a catalog row, must not sleep in
# the lane gate's start offset, and must print a line, not nothing, when the
# lane is paused or a tick holds the lock.
#
# Real: the catalog file, bin/lib/live-probes.sh (lp_catalog, lp_resolve,
# lp_run_one), the lane script, its classifier and REST layer. Faked, in the
# shape tests/outcome-check.bh-6372-test.sh uses: the lane gate, the jobs
# client, the GitHub budget, alert-line.sh, the mq-full-share measurer, and gh.
#
# CASES: P1 P2 P3 G1 G2 G3 E1 L1 L2.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/outcome-check-probe.bh-6463-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$(dirname "$0")/lib/gh-rest-fx.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/bh-6372"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -r "$FX/issue-5354.json" ] || { echo "FAIL: fixture missing: tests/fixtures/bh-6372/issue-5354.json"; exit 1; }

NOW=$(date -u -d '2026-10-13T12:00:00Z' +%s)
HR=3600
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
R=example-org/cromford
U() { echo "https://github.com/$R/pull/$1"; }
PERF='Closes #5354

Target metric: mq-full-share from 0.92 to 0.30'
ghfx_init
mkdir -p "$T/tmp"

# The lane gate stub: records each call; FAKE_GATE_SLEEP makes it sleep the
# way lane_start_offset does at :00/:30; FAKE_PAUSED_WHY makes lane_paused
# answer "paused" with that reason. `nopaused` writes a stub with no
# lane_paused at all (the 6372 suite's shape).
gate_stub() {
  if [ "${1:-}" = nopaused ]; then
    cat > "$HH/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() { echo "GATE $*" >> "$HARNESS/gate-calls.txt"; }
lane_env_apply() { :; }
SH
    return 0
  fi
  cat > "$HH/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() {
  echo "GATE $*" >> "$HARNESS/gate-calls.txt"
  [ -z "${FAKE_GATE_SLEEP:-}" ] || sleep "$FAKE_GATE_SLEEP"
}
lane_env_apply() { :; }
lane_paused() {
  echo "PAUSED? $*" >> "$HARNESS/gate-calls.txt"
  LANE_PAUSED_WHY="${FAKE_PAUSED_WHY:-}"
  [ -n "$LANE_PAUSED_WHY" ]
}
SH
}

HH="$T/h"
mkdir -p "$HH/bin/lib/outcome-metrics.d" "$HH/logs" "$HH/catalog" "$HH/locks"
gate_stub
cat > "$HH/bin/lib/gh-budget.sh" <<'SH'
gh_budget_low() { return 1; }
SH
cat > "$HH/bin/alert-line.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/logs/ALERTS.log"
SH
chmod +x "$HH/bin/alert-line.sh"
cat > "$HH/bin/jobs-client.sh" <<'SH'
jobs_configured() { [ -n "${JOBS_URL:-}" ]; }
JOBS_HTTP=""
job_ledger_list() {
  echo "LIST $1" >> "$HARNESS/jobs-calls.txt"
  case "$1" in merge) [ -f "$HARNESS/merge.tsv" ] && cat "$HARNESS/merge.tsv" ;; esac
  return 0
}
job_ledger_put() { echo "PUT $1 $2 $3 | ${4:-}" >> "$HARNESS/jobs-calls.txt"; return 0; }
_jobs_req() { echo "REQ $1 $2" >> "$HARNESS/jobs-calls.txt"; return 1; }
SH
cat > "$HH/bin/lib/outcome-metrics.d/mq-full-share.sh" <<'SH'
om_mq_full_share() { echo "${FAKE_M:-0.92 10}"; }
SH
scratch_install_closure bin/outcome-check.sh "$HH" >/dev/null || bad "cannot install the bin/outcome-check.sh closure into $HH"
cp "$SRC/catalog/perf-ticket.tsv" "$HH/catalog/perf-ticket.tsv"

# One due perf PR: merged 7 h ago, measured 0.92 against 0.92 -> 0.30.
ghfx_route GET "repos/$R/issues/5354" 200 "$(cat "$FX/issue-5354.json")"
ghfx_route GET "search/issues" 200 '{"total_count":0,"items":[]}'
ghfx_route POST "repos/$R/issues" 201 '{"number":7001,"html_url":"https://github.com/example-org/cromford/issues/7001"}'
ghfx_route GET "repos/$R/pulls/102" 200 "$(jq -nc --arg m "$(iso $(( 7 * HR )))" --arg b "$PERF" \
  '{number: 102, title: "Faster CI", body: $b, state: "closed", labels: [], merged_at: $m,
    html_url: "https://github.com/example-org/cromford/pull/102"}')"
printf '%s\tmerged\t-\t%s\n' "$(U 102)" "$(iso $(( 7 * HR )))" > "$HH/merge.tsv"

lane_env() { # the env one tick sees; never the box's own
  export HARNESS="$HH" NOW PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret \
    GH_ETAG=0 TMPDIR="$T/tmp" HARNESS_REPO="$R"
  unset GH_TOKEN GH_LIMIT_IDENTITY GH_TOKEN_INSTALLATION_ID PERF_TICKET_CATALOG OUTCOME_CHECK_DELAY_H \
    OUTCOME_CHECK_LOOKBACK_H OUTCOME_CHECK_MIN_SAMPLES OUTCOME_CHECK_MAX_WAIT_H OUTCOME_CHECK_MAX_PRS OUTCOME_CHECK_DEADLINE_S
}
clear_calls() { rm -f "$HH/jobs-calls.txt" "$HH/gate-calls.txt" "$HH/logs/"*; ghfx_log_reset; }
drive() { # drive [args...] — one run of the shipped script, under a 20 s cap
  clear_calls
  ( lane_env; timeout 20 bash "$HH/bin/outcome-check.sh" "$@" ) > "$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
lines() { if [ -f "$1" ]; then grep -c -- "${2:-.}" "$1"; else echo 0; fi; }
ghn() { lines "$T/gh-argv.log"; }
SUMMARY_RE='(dry run, nothing written)$'   # BRE: the parentheses are literal

# ── P1: the real catalog carries the row, and lp_catalog accepts it
# shellcheck source=bin/lib/live-probes.sh
. "$SRC/bin/lib/live-probes.sh" || { echo "FAIL: bin/lib/live-probes.sh did not load"; exit 1; }
ROWS=$(lp_catalog "$SRC/catalog/live-probes.tsv" 2>"$T/cat-err.txt")
grep -qxF "outcome-check-dry-run	cmd	bin/outcome-check.sh --dry-run" <<<"$ROWS" && ok \
  || bad "P1: catalog/live-probes.tsv has the row outcome-check-dry-run cmd 'bin/outcome-check.sh --dry-run': $ROWS"
grep -q 'outcome-check-dry-run' "$T/cat-err.txt" && bad "P1: lp_catalog refused the row: $(cat "$T/cat-err.txt")" || ok

# ── P2: a PR's declared line resolves to the row; a different command does not
OUT=$(lp_resolve "$ROWS" outcome-check-dry-run "bin/outcome-check.sh --dry-run"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "cmd	bin/outcome-check.sh --dry-run" ] && ok \
  || bad "P2: lp_resolve of the declared dry run -> rc 0 and the row (rc=$RC): $OUT"
OUT=$(lp_resolve "$ROWS" outcome-check-dry-run "bin/outcome-check.sh"); RC=$?
[ "$RC" = 1 ] && [[ "$OUT" == "refused: the declared command is not the allow-listed one"* ]] && ok \
  || bad "P2: a declared live tick (no --dry-run) is refused (rc=$RC): $OUT"

# ── P3: the probe runner itself runs the row on a scratch harness
clear_calls
( lane_env; lp_run_one cmd "bin/outcome-check.sh --dry-run" "$T/probe-out.txt" ); RC=$?
[ "$RC" = 0 ] && ok || bad "P3: lp_run_one rc 0 (rc=$RC): $(cat "$T/probe-out.txt")"
grep -qF "outcome-check: $R#102 mq-full-share from 0.92 to 0.30 measured 0.92 (n=10) -> filed (dry run)" "$T/probe-out.txt" && ok \
  || bad "P3: the probe output has the would-be '-> filed (dry run)' line: $(cat "$T/probe-out.txt")"
grep -q "$SUMMARY_RE" "$T/probe-out.txt" && ok || bad "P3: the probe output has the dry-run summary line: $(cat "$T/probe-out.txt")"
[ "$(lines "$HH/jobs-calls.txt" '^PUT ')" = 0 ] && [ "$(lines "$T/gh-argv.log" ' -X POST ')" = 0 ] && ok \
  || bad "P3: no ledger put and no POST (puts=$(lines "$HH/jobs-calls.txt" '^PUT ') posts=$(lines "$T/gh-argv.log" ' -X POST '))"

# ── G1: dry run of a paused lane -> one line, nothing read
( export FAKE_PAUSED_WHY=lane-off-outcome-check; drive --dry-run; echo "$RC" > "$T/rc" )
RC=$(cat "$T/rc")
[ "$RC" = 0 ] && [ "$(cat "$T/out.txt")" = "paused: lane-off-outcome-check — nothing read (dry run)" ] && ok \
  || bad "G1: paused dry run -> rc 0 and the paused line (rc=$RC): $(cat "$T/out.txt")"
[ "$(lines "$HH/jobs-calls.txt")" = 0 ] && [ "$(ghn)" = 0 ] && ok \
  || bad "G1: a paused dry run reads nothing (jobs=$(lines "$HH/jobs-calls.txt") gh=$(ghn))"
[ "$(lines "$HH/gate-calls.txt" '^GATE ')" = 0 ] && ok || bad "G1: the dry run never calls lane_gate_or_exit"

# ── G2: dry run with a gate that would sleep 999 s -> no gate call, finishes
( export FAKE_GATE_SLEEP=999; drive --dry-run; echo "$RC" > "$T/rc" )
RC=$(cat "$T/rc")
[ "$RC" = 0 ] && ok || bad "G2: the dry run finishes inside 20 s with rc 0 (rc=$RC; 124 = it slept in the gate): $(cat "$T/out.txt")"
[ "$(lines "$HH/gate-calls.txt" '^GATE ')" = 0 ] && ok || bad "G2: no lane_gate_or_exit call (no start offset, no liveness row): $(cat "$HH/gate-calls.txt")"
[ "$(lines "$HH/gate-calls.txt" '^PAUSED? outcome-check$')" = 1 ] && ok || bad "G2: the dry run asks lane_paused once: $(cat "$HH/gate-calls.txt" 2>/dev/null)"
grep -q "$SUMMARY_RE" "$T/out.txt" && ok || bad "G2: the summary ends '(dry run, nothing written)': $(cat "$T/out.txt")"

# ── G3: a live tick still runs the whole gate, once
drive
[ "$RC" = 0 ] && [ "$(lines "$HH/gate-calls.txt" '^GATE outcome-check$')" = 1 ] && ok \
  || bad "G3: a live tick calls lane_gate_or_exit outcome-check once (rc=$RC): $(cat "$HH/gate-calls.txt" 2>/dev/null)"
[ "$(lines "$HH/gate-calls.txt" '^PAUSED?')" = 0 ] && ok || bad "G3: a live tick does not call lane_paused itself"

# ── E1: a lane-gate.sh with no lane_paused -> the dry run still runs
gate_stub nopaused
drive --dry-run
[ "$RC" = 0 ] && grep -q "$SUMMARY_RE" "$T/out.txt" && ok \
  || bad "E1: no lane_paused -> the dry run runs and prints the summary (rc=$RC): $(cat "$T/out.txt") $(cat "$T/err.txt")"
gate_stub

# ── L1 / L2: a tick holds the lock
exec 8>"$HH/locks/outcome-check.lock"
flock -n 8 || bad "L: the test could not take the lock itself"
drive --dry-run
[ "$RC" = 0 ] && [ "$(cat "$T/out.txt")" = "skipped: a tick holds locks/outcome-check.lock — nothing read (dry run)" ] && ok \
  || bad "L1: dry run under a held lock -> rc 0 and the skipped line (rc=$RC): $(cat "$T/out.txt")"
[ "$(lines "$HH/jobs-calls.txt")" = 0 ] && [ "$(ghn)" = 0 ] && ok \
  || bad "L1: a dry run under a held lock reads nothing (jobs=$(lines "$HH/jobs-calls.txt") gh=$(ghn))"
drive
[ "$RC" = 0 ] && [ ! -s "$T/out.txt" ] && ok || bad "L2: a live tick under a held lock stays silent, rc 0 (rc=$RC): $(cat "$T/out.txt")"
[ "$(lines "$HH/jobs-calls.txt")" = 0 ] && ok || bad "L2: a live tick under a held lock reads nothing"
exec 8>&-

echo "outcome-check-probe (BH-6463): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
