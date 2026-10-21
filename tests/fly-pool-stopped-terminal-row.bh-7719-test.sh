#!/bin/bash
# tests/fly-pool-stopped-terminal-row.bh-7719-test.sh — BH-7719: a pool machine
# that finished its job, idled out and stopped before the reap wrote its result
# to the pool-result row. The reap took that row as the result only for
# BUILD_DEFERRED / ROLLOUT_*, so a PLAN_BLOCKED or PR_CREATED row was requeued:
# 193 machines on 2026-10-20, 98 of them pure repeats, and 11 close-out
# comments on one ticket.
#
# This suite runs the REAL bin/fly-pool.sh (installed with its closure) with a
# fly stub that lists m1 `stopped` and answers no ssh, a fixture job_ledger_row
# for the row, and queue_done / queue_put sinks (export -f), as the BH-2643 and
# BH-7429 suites do. Every stamp comes from $NOW; every case has its own key.
#   R1 PLAN_BLOCKED row: closed done, held, not requeued, nothing on tick 2
#   R2 PR_CREATED row: closed done, remote-results written, not requeued
#   R3-R5 REVIEW_BLOCKED, BUILD_REFUSED, EXECUTE_EMPTY, PLAN_MALFORMED: done
#   R6 no row: a death, requeued deaths=1 (unchanged)
#   R7 a stale PLAN_BLOCKED row (older than spawned_at): a death (unchanged)
#   C1 the row path writes one Fly cost row     C2 the dead path writes one
#   C3 a stopped machine is billed to its stop time
#   C4 a second reap of the same job writes no second row
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
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin" "$T/ledger" "$T/tmp"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "FAIL: cannot install the fly-pool closure"; exit 1; }
printf 'FLY_API_TOKEN_project-5=tok-fixture\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# gh: the PR verify gate's REST read answers the PR open.
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
case "$*" in
  *"/pulls/"*) printf 'HTTP/2.0 200 OK\r\n\r\n{"state":"open","merged_at":null}\n' ;;
  *) printf 'HTTP/2.0 200 OK\r\n\r\n{}\n' ;;
esac
exit 0
GH
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

# Fly: the listing is $T/listing; ssh reaches nothing (the machine is
# stopped); every call is one line in $T/fly.calls.
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly.calls"
case "\$*" in
  *"machines list"*) cat "$T/listing" ;;
  *"machine status"*) echo "State: stopped" ;;
  *"machine destroy"*) echo "\$*" >> "$T/destroyed" ;;
  *"ssh console"*) exit 1 ;;
esac
exit 0
FLY
chmod +x "$T/fakebin/fly"

# The worker, as fixtures: the pool-result row ($LEDGER_FIX/rc, /row) and the
# queue writes, one line each in $QSINK ("<status> <key> <reason>").
job_ledger_row() {
  local rc; rc=$(cat "$LEDGER_FIX/rc" 2>/dev/null || echo 2)
  [ "$rc" = 0 ] && cat "$LEDGER_FIX/row"
  return "$rc"
}
queue_done() { printf '%s %s %s\n' "$3" "$2" "${4:-}" >> "$QSINK"; return 0; }
queue_put()  { printf 'put %s attempt=%s\n' "$2" "${5:-}" >> "$QSINK"; return 0; }
export -f job_ledger_row queue_done queue_put

SPAWN_EPOCH=$((NOW-900))
SPAWNED_AT=$(date -u -d "@$SPAWN_EPOCH" '+%Y-%m-%d %H:%M:%SZ')
STOP_ISO=$(date -u -d "@$((SPAWN_EPOCH+300))" '+%Y-%m-%dT%H:%M:%SZ')
LOG="$H/logs/fly-pool.log"

run_pool() { # run_pool [env assignments...]
  : > "$LOG"; : > "$H/logs/ALERTS.log"; : > "$T/destroyed"; : > "$T/fly.calls"; : > "$T/qsink"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" TMPDIR="$T/tmp" \
           FLY_API_TOKEN_project-5=tok-fixture FLY_BIN_DIR="$T/fakebin" LEDGER_FIX="$T/ledger" \
           QSINK="$T/qsink" POOL_SPAWN=0 "$@"
    unset POOL_RECORD_READ
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/* "$H/state/fly-pool/project-5"/* \
           "$H/state/pool/project-5"/* "$H/state/remote-results/project-5"/* \
           "$H/builds"/* "$T/ledger"/* "$H/state/fly-cost"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}
machine_json() { # machine_json <key>
  jq -nc --arg k "$1" --arg ts "$SPAWNED_AT" \
    '{machine:"m1",key:$k,ticket_id:"2512",attempt:1,deferrals:0,deaths:0,spawned_at:$ts}' \
    > "$H/state/fly-pool/project-5/m1.json"
}
listing() { # listing [updated_at]
  jq -nc --arg u "${1:-$STOP_ISO}" '[{id:"m1",state:"stopped",updated_at:$u}]' > "$T/listing"
}
ledger_row() { # ledger_row <rline> <at-epoch>
  jq -nc --arg r "$1" --argjson a "$2" \
    '{status:"result",detail:({rline:$r,machine:"m1",at:$a}|tojson)}' > "$T/ledger/row"
  echo 0 > "$T/ledger/rc"
}
qfile() { echo "$H/state/build-queue/project-5/$1.json"; }
bdir() { ls -d "$H/builds/pool-project-5-$1-"* 2>/dev/null | head -1; }
col() { # col <csv> <name>: the named column of the last row
  awk -F, -v n="$2" 'NR==1{for(i=1;i<=NF;i++) if($i==n) c=i; next} {v=$c} END{print v}' "$1" 2>/dev/null
}
fly_rows() { local n; n=$(grep -c ',infra,fly,' "$1" 2>/dev/null); echo "${n:-0}"; }
ledger_lines() { # ledger_lines <key>
  local n; n=$(grep -c "^m1	$1	$SPAWNED_AT\$" "$H/state/fly-cost/ledger.tsv" 2>/dev/null); echo "${n:-0}"
}
# A row taken as the result: closed done, no queue file, no death or requeue line.
expect_result() { # expect_result <case> <key> <word>
  local c="$1" k="$2" w="$3"
  grep -q "^done $k $w" "$T/qsink" && ok || bad "$c: the queue row is not closed done with $w: $(cat "$T/qsink")"
  [ -e "$(qfile "$k")" ] && bad "$c: THE POINT: a finished job was requeued: $(cat "$(qfile "$k")")" || ok
  grep -q "^put $k" "$T/qsink" && bad "$c: a queue_put requeued the key: $(cat "$T/qsink")" || ok
  grep -q "result for $k taken from the pool-result row" "$LOG" && ok || bad "$c: the row is not named as the source: $(cat "$LOG")"
  grep -q 'dead (state=\|after job done' "$LOG" && bad "$c: a death or requeue line: $(grep 'dead (state=\|after job done' "$LOG")" || ok
  grep -q 'machine destroy m1' "$T/destroyed" && ok || bad "$c: m1 not destroyed"
}

# ── R1 PLAN_BLOCKED row ───────────────────────────────────────────────────
K=BH-77191
reset_state; machine_json "$K"; listing
ledger_row "PLAN_BLOCKED /data/harness/builds/project-5-$K-202610201400/plan.md" $((SPAWN_EPOCH+200))
run_pool
expect_result R1 "$K" PLAN_BLOCKED
[ "$(grep -c "held $K: PLAN_BLOCKED from the pool-result row" "$LOG")" = 1 ] && ok \
  || bad "R1: exactly one held line: $(grep held "$LOG")"
grep -q 'plan-blocked: ' "$LOG" && ok || bad "R1: pb_hub_copy was not reached: $(cat "$LOG")"
# C1: the row path's one Fly cost row and one ledger line.
B=$(bdir "$K")
[ -n "$B" ] && [ "$(fly_rows "$B/cost.csv")" = 1 ] && ok || bad "C1: one fly infra row in the hub build dir (dir '$B'): $(cat "$B/cost.csv" 2>/dev/null)"
[ "$(col "$B/cost.csv" ticket)" = "$K" ] && [ "$(col "$B/cost.csv" host)" = pool-project-5-m1 ] && ok \
  || bad "C1: the row names the key and pool-project-5-m1: $(tail -1 "$B/cost.csv" 2>/dev/null)"
[ "$(ledger_lines "$K")" = 1 ] && ok || bad "C1: one ledger.tsv line: $(cat "$H/state/fly-cost/ledger.tsv" 2>/dev/null)"
grep -q "fly cost row: written m1 $K" "$LOG" && ok || bad "C1: the written line: $(grep 'fly cost' "$LOG")"
# C3: billed to the stop time (spawn + 300 s), not to now (spawn + 900 s).
D=$(col "$B/cost.csv" duration_s)
[ "$D" -ge 295 ] 2>/dev/null && [ "$D" -le 305 ] && ok || bad "C3: duration_s is the stop time less the spawn (want 300, got '$D')"
# C4: the same job reaped twice (machine json restored): still one row.
machine_json "$K"; listing
run_pool
[ "$(ledger_lines "$K")" = 1 ] && ok || bad "C4: a second reap of one job adds a ledger line: $(cat "$H/state/fly-cost/ledger.tsv")"
grep -q "fly cost row: already m1 $K" "$LOG" && ok || bad "C4: the second reap says already: $(grep 'fly cost' "$LOG")"
# R1 tick 2: nothing left to spawn. Spawn is on for this tick.
reset_state; machine_json "$K"; listing
ledger_row "PLAN_BLOCKED /data/harness/builds/project-5-$K-202610201400/plan.md" $((SPAWN_EPOCH+200))
run_pool
echo '[]' > "$T/listing"
run_pool POOL_SPAWN=1
[ -e "$(qfile "$K")" ] && bad "R1 tick 2: a queue file appeared: $(cat "$(qfile "$K")")" || ok
grep -q 'machine run' "$T/fly.calls" && bad "R1 tick 2: a machine was spawned: $(grep 'machine run' "$T/fly.calls")" || ok

# ── R2 PR_CREATED row ─────────────────────────────────────────────────────
K=BH-77192
reset_state; machine_json "$K"; listing
ledger_row "PR_CREATED https://github.com/example-org/project-5/pull/9" $((SPAWN_EPOCH+200))
run_pool
expect_result R2 "$K" PR_CREATED
case "$(jq -r '.result' "$H/state/remote-results/project-5/$K.json" 2>/dev/null)" in
  "PR_CREATED https://github.com/example-org/project-5/pull/9"*) ok ;;
  *) bad "R2: state/remote-results carries the PR_CREATED result: $(cat "$H/state/remote-results/project-5/$K.json" 2>/dev/null)" ;;
esac
grep -q 'RESULT_UNVERIFIED' "$(bdir "$K")/RESULT" 2>/dev/null && bad "R2: the open PR was relabeled: $(head -1 "$(bdir "$K")/RESULT")" || ok

# ── R3-R5 the other terminal words ────────────────────────────────────────
N=3
for RL in "R3|REVIEW_BLOCKED /data/harness/builds/x/review.md" "R4|BUILD_REFUSED size cap" \
          "R5a|EXECUTE_EMPTY" "R5b|PLAN_MALFORMED /data/harness/builds/x/plan.md"; do
  C="${RL%%|*}"; RL="${RL#*|}"
  K="BH-7719$N"; W="${RL%% *}"
  reset_state; machine_json "$K"; listing
  ledger_row "$RL" $((SPAWN_EPOCH+200))
  run_pool
  expect_result "$C $W" "$K" "$W"
  grep -q "held $K" "$LOG" && bad "$C: only a PLAN_BLOCKED is held: $(grep held "$LOG")" || ok
  N=$((N+1))
done

# ── R6 no row: a death, as today (and C2: the dead path's cost row) ───────
K=BH-77198
reset_state; machine_json "$K"; listing
echo 2 > "$T/ledger/rc"
run_pool
grep -q "machine m1 for $K dead (state=stopped)" "$LOG" && ok || bad "R6: the dead line: $(cat "$LOG")"
[ "$(jq -r '.deaths' "$(qfile "$K")" 2>/dev/null)" = 1 ] && ok || bad "R6: requeued with deaths=1: $(cat "$(qfile "$K")" 2>/dev/null)"
grep -q 'taken from the pool-result row' "$LOG" && bad "R6: no row, no result" || ok
[ "$(ledger_lines "$K")" = 1 ] && ok || bad "C2: the dead path writes one ledger.tsv line: $(cat "$H/state/fly-cost/ledger.tsv" 2>/dev/null)"
ls -d "$T/tmp"/pool-dead-cost.* >/dev/null 2>&1 && bad "C2: the dead path's temp dir is left: $(ls "$T/tmp")" || ok

# ── R7 a stale PLAN_BLOCKED row (the previous job on a reused machine) ────
K=BH-77199
reset_state; machine_json "$K"; listing
ledger_row "PLAN_BLOCKED /data/harness/builds/x/plan.md" $((SPAWN_EPOCH-600))
run_pool
grep -q "machine m1 for $K dead (state=stopped)" "$LOG" && ok || bad "R7: a stale row is a death: $(cat "$LOG")"
[ "$(jq -r '.deaths' "$(qfile "$K")" 2>/dev/null)" = 1 ] && ok || bad "R7: requeued with deaths=1: $(cat "$(qfile "$K")" 2>/dev/null)"
grep -q "held $K" "$LOG" && bad "R7: a stale row is never held" || ok

# ── C3 near miss: a stop time before the spawn (a reused machine's earlier
# stop) is not used; the end is now ──────────────────────────────────────
K=BH-77200
reset_state; machine_json "$K"; listing "$(date -u -d "@$((SPAWN_EPOCH-60))" '+%Y-%m-%dT%H:%M:%SZ')"
ledger_row "EXECUTE_EMPTY" $((SPAWN_EPOCH+200))
run_pool
D=$(col "$(bdir "$K")/cost.csv" duration_s)
[ "$D" -ge 895 ] 2>/dev/null && [ "$D" -le 960 ] && ok || bad "C3: an updated_at before spawned_at is ignored (want ~900, got '$D')"

[ -n "${BH7719_DEBUG:-}" ] && cat "$LOG"
echo "fly-pool-stopped-terminal-row (BH-7719): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
