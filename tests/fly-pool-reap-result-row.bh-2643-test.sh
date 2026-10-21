#!/bin/bash
# tests/fly-pool-reap-result-row.bh-2643-test.sh — BH-2643: a reused pool
# machine that answered BUILD_DEFERRED and then autostopped was reaped as a
# DEATH. The reap read the result only over ssh (/run/harness/RESULT is tmpfs),
# a stopped machine cannot be reached, so RES came back empty and the liveness
# path counted `dead (state=stopped)`; the second one parked the ticket.
#
# The machine now also writes its result to a `pool-result` ledger row keyed
# <project>/<KEY> (bin/lib/pool-result-row.sh), and the reap reads that row
# before it decides a not-started machine is dead. This suite runs the real
# bin/fly-pool.sh with a fly stub that lists m1 as `stopped` and answers no ssh,
# and a fixture job_ledger_row (export -f) standing in for the worker.
#
# The file anchors wall-clock time in $NOW; every fixture timestamp is derived
# from that one value so the suite does not flake on calendar drift.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin" "$T/ledger"
printf 'FLY_API_TOKEN_project-5=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
mkdir -p "$H/bin/lib" && cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/hold.sh"
# The hub's synced copy of the shared key rule — the one both sides source.
cp "$DIR/bin/lib/pool-result-row.sh" "$H/bin/lib/pool-result-row.sh" 2>/dev/null || true
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
exit 0
GH
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" "$T/fakebin"/*

# Fly: m1 is listed STOPPED; ssh reaches nothing (a stopped machine); every
# destroy is recorded.
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
case "\$*" in
  *"machines list"*) echo '[{"id":"m1","state":"stopped"}]' ;;
  *"machine status"*) echo "State: stopped" ;;
  *"machine destroy"*) echo "\$*" >> "$T/destroyed" ;;
  *"ssh console"*) : ;;
esac
exit 0
FLY
chmod +x "$T/fakebin/fly"

# The worker's ledger, as a fixture: $LEDGER_FIX/rc is the answer's rc,
# $LEDGER_FIX/row the {status,detail} line job_ledger_row prints on rc 0.
# Every read is recorded so a case can assert the row was (not) consulted.
job_ledger_row() {
  echo "$1 $2" >> "$LEDGER_FIX/reads"
  local rc; rc=$(cat "$LEDGER_FIX/rc" 2>/dev/null || echo 2)
  [ "$rc" = 0 ] && cat "$LEDGER_FIX/row"
  return "$rc"
}
export -f job_ledger_row

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"; : > "$T/destroyed"; : > "$T/ledger/reads"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok FLY_BIN_DIR="$T/fakebin" LEDGER_FIX="$T/ledger" \
           POOL_SPAWN=0 "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/* "$H/state/fly-pool/project-5"/* \
           "$H/state/pool/project-5"/* "$H/builds"/* "$T/ledger"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}

# The production spawned_at shape: STAMP in bin/fly-pool.sh, '%Y-%m-%d %H:%M:%SZ'.
SPAWN_EPOCH=$((NOW-900))
SPAWNED_AT=$(date -u -d "@$SPAWN_EPOCH" '+%Y-%m-%d %H:%M:%SZ')

machine_json() { # machine_json <key> <deaths> [deferrals]
  jq -nc --arg k "$1" --argjson x "$2" --argjson d "${3:-0}" --arg ts "$SPAWNED_AT" \
    '{machine:"m1",key:$k,ticket_id:"2512",attempt:1,deferrals:$d,deaths:$x,spawned_at:$ts,reused_from:"BH-2400"}' \
    > "$H/state/fly-pool/project-5/m1.json"
}

ledger_row() { # ledger_row <rline> <machine> <at-epoch>
  jq -nc --arg r "$1" --arg m "$2" --argjson a "$3" \
    '{status:"result",detail:({rline:$r,machine:$m,at:$a}|tojson)}' > "$T/ledger/row"
  echo 0 > "$T/ledger/rc"
}

LOG="$H/logs/fly-pool.log"
Q="$H/state/build-queue/project-5/BH-2512.json"
DEFLINE="BUILD_DEFERRED REFUSED pause :: paused: pause_flags row paused-project-5 is active"

# a dead-path case: today's behaviour, pinned. $1 names the case.
expect_death() {
  grep -q 'machine m1 for BH-2512 dead (state=stopped)' "$LOG" \
    && ok "$1: logged dead (state=stopped)" || bad "$1: expected the dead line: $(cat "$LOG")"
  [ "$(jq -r '.deaths' "$Q" 2>/dev/null)" = 1 ] \
    && ok "$1: requeued with deaths=1" || bad "$1: expected deaths=1 on the requeue: $(cat "$Q" 2>/dev/null)"
  grep -q 'taken from the pool-result row\|after job done' "$LOG" && bad "$1: a result was taken from a row that must be ignored" || ok "$1: no row result taken"
}

# ── 1: reused machine, BUILD_DEFERRED only in the row, machine stopped ─────
{
  reset_state
  machine_json BH-2512 0
  ledger_row "$DEFLINE" m1 $((SPAWN_EPOCH+31))
  run_pool
  grep -q 'DEFERRED BH-2512' "$LOG" && ok "1: DEFERRED logged" || bad "1: no DEFERRED line: $(cat "$LOG")"
  grep -q 'result for BH-2512 taken from the pool-result row' "$LOG" && ok "1: the row is named as the source" || bad "1: row source not named"
  grep -q 'dead (state=' "$LOG" && bad "1: a deferral was logged as a death" || ok "1: no dead line"
  [ "$(jq -r '.deaths' "$Q" 2>/dev/null)" = 0 ] && ok "1: deaths unchanged (0)" || bad "1: deaths moved: $(cat "$Q" 2>/dev/null)"
  [ "$(jq -r '.deferrals' "$Q" 2>/dev/null)" = 1 ] && ok "1: deferrals=1" || bad "1: deferrals not advanced: $(cat "$Q" 2>/dev/null)"
  grep -q 'machine destroy m1' "$T/destroyed" && ok "1: stopped machine destroyed" || bad "1: m1 not destroyed"
  [ -e "$H/state/fly-pool/project-5/m1.json" ] && bad "1: machine json left behind" || ok "1: machine json removed"
  BDIR=$(ls -d "$H/builds/pool-project-5-BH-2512-"* 2>/dev/null | head -1)
  [ -n "$BDIR" ] && [ -f "$BDIR/DEFERRED" ] && ok "1: build dir stamped DEFERRED" || bad "1: no DEFERRED build dir"
  [ -n "$BDIR" ] && grep -q 'pool-result row' "$BDIR/result-source" 2>/dev/null \
    && ok "1: result-source recorded" || bad "1: result-source missing"
  [ -n "$BDIR" ] && [ "$(head -1 "$BDIR/RESULT" 2>/dev/null)" = "$DEFLINE" ] \
    && ok "1: RESULT is the row's line" || bad "1: RESULT wrong: $(cat "$BDIR/RESULT" 2>/dev/null)"
  grep -q '^pool-result project-5/BH-2512$' "$T/ledger/reads" && ok "1: row read under <project>/<KEY>" \
    || bad "1: unexpected ledger reads: $(cat "$T/ledger/reads")"
}

# ── 2: no row (rc 2) — today's death, unchanged ────────────────────────────
{
  reset_state
  machine_json BH-2512 0
  echo 2 > "$T/ledger/rc"
  run_pool
  expect_death 2
}

# ── 3: a row written by ANOTHER machine is not this machine's result ──────
{
  reset_state
  machine_json BH-2512 0
  ledger_row "$DEFLINE" m2 $((SPAWN_EPOCH+31))
  run_pool
  expect_death 3
}

# ── 4: non-deferral row on a stopped machine — the result, not a requeue
# (BH-7719: it was requeued, and the next machine re-ran the same job) ────
{
  reset_state
  machine_json BH-2512 0
  ledger_row "PR_CREATED https://github.com/o/r/pull/9" m1 $((SPAWN_EPOCH+300))
  # The queue row's close, observable for this case: QROW calls queue_done.
  queue_done() { echo "$3 $2 ${4:-}" >> "$QSINK"; }
  export -f queue_done; : > "$T/qsink"
  run_pool QSINK="$T/qsink"
  unset -f queue_done
  grep -q 'result for BH-2512 taken from the pool-result row' "$LOG" && ok "4: the row is the result" || bad "4: row source not named: $(cat "$LOG")"
  grep -q '^done BH-2512 PR_CREATED' "$T/qsink" && ok "4: the row closes done" || bad "4: not closed done: $(cat "$T/qsink")"
  grep -q 'dead (state=\|dead machine\|after job done' "$LOG" && bad "4: a finished job was logged as a death or requeue" || ok "4: no dead line"
  [ -e "$Q" ] && bad "4: a finished job was requeued: $(cat "$Q")" || ok "4: not requeued"
}

# ── 5: stale row, garbage row, unreadable ledger — all still deaths ───────
{
  reset_state
  machine_json BH-2512 0
  ledger_row "$DEFLINE" m1 $((SPAWN_EPOCH-600))
  run_pool
  expect_death 5a-stale
}
{
  reset_state
  machine_json BH-2512 0
  ledger_row "Oops goroutine 1 [running]:" m1 $((SPAWN_EPOCH+31))
  run_pool
  expect_death 5b-garbage
}
{
  reset_state
  machine_json BH-2512 0
  ledger_row "$DEFLINE" m1 $((SPAWN_EPOCH+31))
  echo 1 > "$T/ledger/rc"
  run_pool
  expect_death 5c-outage
  grep -q 'pool-result row .*unreadable' "$LOG" && ok "5c: the unreadable row is said" || bad "5c: no unreadable note"
}

# ── 6: a second autostop after a deferral must not park the ticket ────────
{
  reset_state
  machine_json BH-2512 1
  ledger_row "$DEFLINE" m1 $((SPAWN_EPOCH+31))
  run_pool
  grep -q 'died 2 times' "$LOG" "$H/logs/ALERTS.log" && bad "6: parked as died twice" || ok "6: not parked"
  [ -e "$H/state/build-queue/project-5/BH-2512.failed.json" ] && bad "6: failed.json written" || ok "6: no failed.json"
  [ "$(jq -r '.deaths' "$Q" 2>/dev/null)" = 1 ] && ok "6: requeued, deaths still 1" || bad "6: not requeued at deaths=1: $(cat "$Q" 2>/dev/null)"
}

# ── 7: a rebase key reads the row (BH-7656); a non-rebase word in it is a
# miss, so its dead path is unchanged ─────────────────────────────────────
{
  reset_state
  machine_json RB-21-abc 0
  ledger_row "$DEFLINE" m1 $((SPAWN_EPOCH+31))
  run_pool
  grep -q '^pool-result project-5/RB-21-abc$' "$T/ledger/reads" && ok "7: row read for RB-" \
    || bad "7: the row was not read for an RB- key: $(cat "$T/ledger/reads")"
  grep -q 'rebase machine m1 died (state=stopped)' "$H/logs/ALERTS.log" \
    && ok "7: rebase dead path unchanged" || bad "7: rebase dead ALERT missing: $(cat "$H/logs/ALERTS.log")"
  [ -e "$H/state/build-queue/project-5/RB-21-abc.json" ] && bad "7: rebase requeued" || ok "7: rebase not requeued"
}

echo "fly-pool-reap-result-row: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
