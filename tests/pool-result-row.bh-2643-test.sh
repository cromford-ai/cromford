#!/bin/bash
# tests/pool-result-row.bh-2643-test.sh — BH-2643: the pool-result row both
# sides share (bin/lib/pool-result-row.sh). The writer is driven through a stub
# bin/jobs-client.sh that records its argv; the reader through a fixture
# job_ledger_row. Then the runner's own wrapper, lifted out of
# fly/builder-runner.sh, proves a pool job writes the row after it finishes.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$T/run"
cp "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
cp "$DIR/bin/lib/pool-result-row.sh" "$H/bin/lib/"
# The jobs client, as a recorder: argv to $T/argv, rc from $T/put-rc.
cat > "$H/bin/jobs-client.sh" <<JC
#!/bin/bash
printf '%s\n' "\$@" > "$T/argv"
exit "\$(cat "$T/put-rc" 2>/dev/null || echo 0)"
JC
chmod +x "$H/bin/jobs-client.sh" "$H/bin/result-prefix-ok.sh"
export HARNESS="$H"
# shellcheck source=bin/lib/pool-result-row.sh
. "$DIR/bin/lib/pool-result-row.sh" || { echo "cannot source bin/lib/pool-result-row.sh"; exit 1; }

# ── key ────────────────────────────────────────────────────────────────────
[ "$(pool_result_row_key cromford BH-1)" = "cromford/BH-1" ] && ok || bad "key shape: $(pool_result_row_key cromford BH-1)"
pool_result_row_key "" BH-1 >/dev/null && bad "an empty project made a key" || ok

# ── writer ─────────────────────────────────────────────────────────────────
echo "BUILD_DEFERRED REFUSED pause :: x" > "$T/RESULT"; echo "TIER: 2" >> "$T/RESULT"
: > "$T/argv"
pool_result_row_put cromford BH-1 m1 "$T/RESULT"; RC=$?
[ "$RC" = 0 ] && ok || bad "put rc=$RC"
mapfile -t A < "$T/argv"
[ "${A[0]:-}" = ledger-put ] && [ "${A[1]:-}" = pool-result ] && [ "${A[2]:-}" = cromford/BH-1 ] && [ "${A[3]:-}" = result ] \
  && ok || bad "put argv: $(tr '\n' ' ' < "$T/argv")"
DET="${A[4]:-}"
[ "$(printf '%s' "$DET" | jq -r .rline)" = "BUILD_DEFERRED REFUSED pause :: x" ] && ok || bad "rline in detail: $DET"
[ "$(printf '%s' "$DET" | jq -r .machine)" = m1 ] && ok || bad "machine in detail: $DET"
AT=$(printf '%s' "$DET" | jq -r .at)
[ "$AT" -ge "$NOW" ] 2>/dev/null && ok || bad "at in detail: $DET"

: > "$T/argv"
pool_result_row_put cromford BH-1 "" "$T/RESULT" && bad "put with no machine id answered 0" || ok
pool_result_row_put cromford BH-1 m1 "$T/nope" && bad "put with no RESULT answered 0" || ok
[ -s "$T/argv" ] && bad "a put with a missing input still called the client" || ok
echo 1 > "$T/put-rc"
pool_result_row_put cromford BH-1 m1 "$T/RESULT" && bad "a failed client write answered 0" || ok
rm -f "$T/put-rc"

# ── reader ─────────────────────────────────────────────────────────────────
# The row the writer just produced, served back by a fixture ledger.
job_ledger_row() {
  local rc; rc=$(cat "$T/get-rc" 2>/dev/null || echo 0)
  [ "$rc" = 0 ] && jq -nc --arg d "$(cat "$T/detail")" '{status:"result",detail:$d}'
  return "$rc"
}
SPAT=$(date -u -d "@$((NOW-120))" '+%Y-%m-%d %H:%M:%SZ')
printf '%s' "$DET" > "$T/detail"
OUT=$(pool_result_row_get cromford BH-1 m1 "$SPAT"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "BUILD_DEFERRED REFUSED pause :: x" ] && ok || bad "round trip: rc=$RC out='$OUT'"
OUT=$(pool_result_row_get cromford BH-1 m1 "${SPAT/ /T}"); RC=$?
[ "$RC" = 0 ] && ok || bad "ISO spawned_at shape not read: rc=$RC"
pool_result_row_get cromford BH-1 m2 "$SPAT" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "another machine's row: rc=$RC (want 2)"
LATE=$(date -u -d "@$((NOW+600))" '+%Y-%m-%d %H:%M:%SZ')
pool_result_row_get cromford BH-1 m1 "$LATE" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "a row older than the spawn: rc=$RC (want 2)"
jq -nc --argjson a "$NOW" '{rline:"Oops goroutine 1",machine:"m1",at:$a}' > "$T/detail"
pool_result_row_get cromford BH-1 m1 "$SPAT" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "a non-RESULT rline: rc=$RC (want 2)"
printf 'not json' > "$T/detail"
pool_result_row_get cromford BH-1 m1 "$SPAT" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "unparseable detail: rc=$RC (want 1)"
printf '%s' "$DET" > "$T/detail"
pool_result_row_get cromford BH-1 m1 "" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "empty spawned_at: rc=$RC (want 1)"
pool_result_row_get cromford BH-1 m1 "yesterday" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "a spawned_at date(1) would guess at: rc=$RC (want 1)"
echo 1 > "$T/get-rc"
pool_result_row_get cromford BH-1 m1 "$SPAT" >/dev/null; RC=$?
[ "$RC" = 1 ] && ok || bad "ledger outage: rc=$RC (want 1)"
echo 2 > "$T/get-rc"
pool_result_row_get cromford BH-1 m1 "$SPAT" >/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "no row: rc=$RC (want 2)"
rm -f "$T/get-rc"

# ── runner wrapper: fly/builder-runner.sh run_job writes the row ──────────
# run_job and pool_result_row_write lifted verbatim; _run_job is a stub that
# writes the RESULT a pause refusal writes.
awk '/^run_job\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$T/run/runjob.sh"
awk '/^pool_result_row_write\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" >> "$T/run/runjob.sh"
grep -q 'pool_result_row_write' "$T/run/runjob.sh" && grep -q '^run_job()' "$T/run/runjob.sh" \
  && ok || bad "could not lift run_job / pool_result_row_write out of fly/builder-runner.sh"
drive_runner() { # drive_runner <key> <POOL_MODE>
  : > "$T/argv"
  ( HARNESS="$H"; PROJECT=cromford; JOB="$T/run/job.json"; RESULT_FILE="$T/run/RESULT"
    export POOL_MODE="$2" FLY_MACHINE_ID=m1
    jq -nc --arg k "$1" '{ticket_id:"1",key:$k}' > "$JOB"
    log() { echo "$*" >> "$T/run/log"; }
    cost_rows_flush() { :; }
    _run_job() { echo "BUILD_DEFERRED REFUSED pause :: x" > "$RESULT_FILE"; return 3; }
    unset -f pool_result_row_put pool_result_row_get pool_result_row_key
    . "$T/run/runjob.sh"
    run_job; echo "rc=$?" > "$T/run/rc" )
}
drive_runner BH-1 1
[ "$(cat "$T/run/rc")" = rc=3 ] && ok || bad "run_job changed the job's rc: $(cat "$T/run/rc")"
mapfile -t A < "$T/argv"
[ "${A[0]:-} ${A[1]:-} ${A[2]:-} ${A[3]:-}" = "ledger-put pool-result cromford/BH-1 result" ] \
  && ok || bad "runner did not write the row: $(tr '\n' ' ' < "$T/argv")"
printf '%s' "${A[4]:-}" | jq -e '.machine == "m1" and (.rline | startswith("BUILD_DEFERRED REFUSED pause"))' >/dev/null \
  && ok || bad "runner row detail: ${A[4]:-}"
# BH-7656: an RB- key writes its row too, with the whole RESULT in detail.result.
drive_runner RB-21-abc 1
mapfile -t A < "$T/argv"
[ "${A[0]:-} ${A[2]:-}" = "ledger-put cromford/RB-21-abc" ] \
  && printf '%s' "${A[4]:-}" | jq -e '.result | startswith("BUILD_DEFERRED REFUSED pause")' >/dev/null \
  && ok || bad "an RB- key wrote no row with detail.result: $(tr '\n' ' ' < "$T/argv")"
drive_runner BH-1 ""
[ -s "$T/argv" ] && bad "a non-pool builder wrote a row" || ok
echo 1 > "$T/put-rc"; : > "$T/run/log"
drive_runner BH-1 1
[ "$(cat "$T/run/rc")" = rc=3 ] && ok || bad "a failed row write changed the job's rc: $(cat "$T/run/rc")"
grep -q 'pool-result row for BH-1 not written' "$T/run/log" && ok || bad "a failed row write was silent"
rm -f "$T/put-rc"

echo "pool-result-row: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
