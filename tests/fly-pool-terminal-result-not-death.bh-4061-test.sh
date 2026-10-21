#!/bin/bash
# tests/fly-pool-terminal-result-not-death.bh-4061-test.sh — BH-4061 pool half.
#
# A rollout master's builder answers `ROLLOUT_FAILED <reason>` about 20 s in,
# idles 600 s and autostops with exit 0. bin/result-prefix-ok.sh had no
# ROLLOUT_ prefix, so the live reap threw the line away as a "mexec miss" and,
# after autostop, the pool-result row was rejected by the same gate: the
# machine was `dead (state=stopped)`, twice, and blocked-resolver rebuilt the
# ticket fresh as `pool-died-twice` (#3966, #3979: ~12 rebuilds on 2026-10-03).
#
# Runs the real bin/fly-pool.sh against the tests/fly-pool-reap-result-row.bh-2643-test.sh
# fixture (fly stub, job_ledger_row fixture, $NOW-anchored stamps), plus a
# queue_done sink so the row's closing status is observable.
#
#   P1  started machine, ssh reads ROLLOUT_FAILED → reaped, QROW done, no mexec miss
#   P2  stopped machine, row says ROLLOUT_FAILED / ROLLOUT_FILED → finished, no requeue
#   P3  deaths=1 already + ROLLOUT_FAILED row → no `died 2 times`, no pool-fail beat
#   P4  stopped, no row → still a death (unchanged)
#   P5  stopped, PR_CREATED / DECOMPOSE_FAILED row → the result, closed done, no requeue (BH-7719)
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

cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
mkdir -p "$H/bin/lib" && cp "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/pool-result-row.sh" "$H/bin/lib/"
# Every beat is recorded: a pool-fail beat is the park's page.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/beats" > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
# The queue row's close, observable: QROW calls queue_done when it is defined.
cat > "$H/bin/jobs-client.sh" <<'JC'
#!/bin/bash
queue_done() { echo "done $*" >> "$QSINK"; }
queue_put()  { echo "put $*" >> "$QSINK"; }
if [ "${1:-}" = setting-get ]; then exit 1; fi
JC
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

# Fly: m1 is listed in $T/mstate. ssh answers the RESULT read with $T/ssh-result
# (only while the machine is started) and nothing else; destroys are recorded.
# mexec hands the command over printf %q, so its spaces arrive escaped.
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
ST=\$(cat "$T/mstate")
case "\$*" in
  *"machines list"*) echo "[{\"id\":\"m1\",\"state\":\"\$ST\"}]" ;;
  *"machine status"*) echo "State: \$ST" ;;
  *"machine destroy"*) echo "\$*" >> "$T/destroyed" ;;
  *"ssh console"*)
    [ "\$ST" = started ] || exit 0
    case "\$*" in
      *base64*) : ;;
      *head*/run/harness/RESULT*) cat "$T/ssh-result" 2>/dev/null ;;
    esac ;;
esac
exit 0
FLY
chmod +x "$T/fakebin/fly"

job_ledger_row() {
  echo "$1 $2" >> "$LEDGER_FIX/reads"
  local rc; rc=$(cat "$LEDGER_FIX/rc" 2>/dev/null || echo 2)
  [ "$rc" = 0 ] && cat "$LEDGER_FIX/row"
  return "$rc"
}
export -f job_ledger_row

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"; : > "$T/destroyed"; : > "$T/ledger/reads"
  : > "$T/qsink"; : > "$T/beats"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok FLY_BIN_DIR="$T/fakebin" LEDGER_FIX="$T/ledger" \
           QSINK="$T/qsink" POOL_SPAWN=0
    bash "$DIR/bin/fly-pool.sh" project-5 >"$T/pool.out" 2>&1 )
}

reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/* "$H/state/fly-pool/project-5"/* \
           "$H/state/pool/project-5"/* "$H/builds"/* "$T/ledger"/* "$T/ssh-result"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}

SPAWN_EPOCH=$((NOW-900))
SPAWNED_AT=$(date -u -d "@$SPAWN_EPOCH" '+%Y-%m-%d %H:%M:%SZ')
machine_json() { # machine_json <key> <deaths>
  jq -nc --arg k "$1" --argjson x "$2" --arg ts "$SPAWNED_AT" \
    '{machine:"m1",key:$k,ticket_id:"3979",attempt:1,deferrals:0,deaths:$x,spawned_at:$ts}' \
    > "$H/state/fly-pool/project-5/m1.json"
}
ledger_row() { # ledger_row <rline> <machine> <at-epoch>
  jq -nc --arg r "$1" --arg m "$2" --argjson a "$3" \
    '{status:"result",detail:({rline:$r,machine:$m,at:$a}|tojson)}' > "$T/ledger/row"
  echo 0 > "$T/ledger/rc"
}

LOG="$H/logs/fly-pool.log"
QD="$H/state/build-queue/project-5"
Q="$QD/BH-3979.json"
REFUSAL='ROLLOUT_FAILED unknown dependency "x" (known: "a")'

# finished <case> <rline> — the assertions every terminal-rollout case shares.
finished() {
  grep -q 'dead (state=' "$LOG" && bad "$1: logged as a death: $(cat "$LOG")" || ok
  grep -q 'after job done' "$LOG" && bad "$1: took the BH-2643 requeue arm" || ok
  grep -q 'died [0-9]* times' "$LOG" "$H/logs/ALERTS.log" && bad "$1: parked as died N times" || ok
  [ -e "$Q" ] && bad "$1: requeued: $(cat "$Q")" || ok
  [ -e "$QD/BH-3979.failed.json" ] && bad "$1: failed.json written" || ok
  grep -q 'pool-fail' "$T/beats" && bad "$1: a pool-fail beat was sent" || ok
  grep -q '^put ' "$T/qsink" && bad "$1: a queue_put (requeue) ran: $(cat "$T/qsink")" || ok
  grep -qF "done project-5 BH-3979 done ${2:0:20}" "$T/qsink" && ok || bad "$1: row not closed done: $(cat "$T/qsink")"
  grep -q 'reaped BH-3979 from m1' "$LOG" && ok || bad "$1: no reaped line: $(cat "$LOG")"
  BDIR=$(ls -d "$H/builds/pool-project-5-BH-3979-"* 2>/dev/null | head -1)
  [ -n "$BDIR" ] && [ "$(head -1 "$BDIR/RESULT" 2>/dev/null)" = "$2" ] && ok \
    || bad "$1: build dir RESULT wrong: $(cat "$BDIR/RESULT" 2>/dev/null)"
  grep -q 'machine destroy m1' "$T/destroyed" && ok || bad "$1: m1 not destroyed"
}

# ── P1: started machine, the RESULT read over ssh is ROLLOUT_FAILED ───────
reset_state
echo started > "$T/mstate"
machine_json BH-3979 0
echo 2 > "$T/ledger/rc"
printf 'ROLLOUT_FAILED x\n' > "$T/ssh-result"
run_pool
grep -q 'mexec miss' "$LOG" "$T/pool.out" && bad "P1: ROLLOUT_FAILED read as a mexec miss" || ok
finished P1 "ROLLOUT_FAILED x"

# ── P2: stopped machine, the row says ROLLOUT_FAILED / ROLLOUT_FILED ──────
echo stopped > "$T/mstate"
for RL in "$REFUSAL" "ROLLOUT_FILED 3"; do
  reset_state
  machine_json BH-3979 0
  ledger_row "$RL" m1 $((SPAWN_EPOCH+31))
  run_pool
  finished "P2 ($RL)" "$RL"
  BDIR=$(ls -d "$H/builds/pool-project-5-BH-3979-"* 2>/dev/null | head -1)
  grep -q 'pool-result row' "$BDIR/result-source" 2>/dev/null && ok || bad "P2 ($RL): result-source not the row"
done

# ── P3: a second autostop after one real death must not park the ticket ──
reset_state
machine_json BH-3979 1
ledger_row "$REFUSAL" m1 $((SPAWN_EPOCH+31))
run_pool
finished P3 "$REFUSAL"

# ── P4: stopped with NO row — still a death ───────────────────────────────
reset_state
machine_json BH-3979 0
echo 2 > "$T/ledger/rc"
run_pool
grep -q 'machine m1 for BH-3979 dead (state=stopped)' "$LOG" && ok || bad "P4: no dead line: $(cat "$LOG")"
[ "$(jq -r '.deaths' "$Q" 2>/dev/null)" = 1 ] && ok || bad "P4: want requeue deaths=1: $(cat "$Q" 2>/dev/null)"

# ── P4b: a ROLLOUT row from ANOTHER machine is not this machine's result ──
reset_state
machine_json BH-3979 0
ledger_row "$REFUSAL" m2 $((SPAWN_EPOCH+31))
run_pool
grep -q 'machine m1 for BH-3979 dead (state=stopped)' "$LOG" && ok || bad "P4b: foreign row must stay a death: $(cat "$LOG")"

# ── P5: a non-rollout row is the result too (BH-7719): closed done, no requeue
for RL in "PR_CREATED https://github.com/o/r/pull/9" "DECOMPOSE_FAILED x"; do
  reset_state
  machine_json BH-3979 0
  ledger_row "$RL" m1 $((SPAWN_EPOCH+300))
  run_pool
  grep -q 'result for BH-3979 taken from the pool-result row' "$LOG" && ok \
    || bad "P5 ($RL): the row is not taken as the result: $(cat "$LOG")"
  grep -q "^done project-5 BH-3979 done ${RL%% *}" "$T/qsink" && ok || bad "P5 ($RL): want the row closed done: $(cat "$T/qsink")"
  [ -e "$Q" ] && bad "P5 ($RL): a finished job was requeued: $(cat "$Q")" || ok
  grep -q 'dead (state=\|after job done' "$LOG" && bad "P5 ($RL): a death or requeue line: $(cat "$LOG")" || ok
done

echo "fly-pool-terminal-result-not-death: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
