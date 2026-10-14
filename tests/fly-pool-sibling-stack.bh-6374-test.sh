#!/bin/bash
# tests/fly-pool-sibling-stack.bh-6374-test.sh — a sibling part that waits on
# ONE open sibling PR is requeued stacked on that PR's branch, so the wait costs
# no build time (BH-6374 C1, scope item 3 on the pool).
#
#   K1  TK-186 lists a file the open PR of TK-184 (ticket/TK-184) changed. Tick
#       1: no machine, the row is requeued once with stack_base=ticket/TK-184
#       (attempt and counts kept), the queue file carries it, and fly-pool.log
#       says `SIBLING_SERIAL TK-186 stacks on ticket/TK-184`. Tick 2: TK-186
#       spawns, its machine json carries stack_base, and no wait line is logged.
#   K2  a non-part key in the same queue spawns on tick 1
#   K3  SIBLING_STACK=0: C0's wait line, no stack_base written, no requeue
#   K4  a row that already has a stack_base is not requeued a second time
#   K5  the ticket was abandoned by an operator (QROW requeue rc 1): the queue
#       file is not rewritten and the log says so
#
# HOW IT DRIVES: the real bin/fly-pool.sh as a subprocess against a scratch
# harness with fly stubs (the tests/fly-pool-sibling-serial.bh-6374-test.sh
# scaffold) and a jobs-client stub that records the QROW calls. The parts map
# comes from a real DECOMPOSED record in builds/.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
NOW=1791860000   # 2026-10-13, pinned
NOTE=src/lib/meeting-notes/report.ts

H="$T/h"
QD="$H/state/build-queue/project-5"; PD="$H/state/pool/project-5"; MD="$H/state/fly-pool/project-5"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" "$H/plans" \
         "$H/state/fly" "$MD" "$QD" "$H/state/remote-results/project-5" \
         "$PD" "$H/state/overlap-guard" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=tok-fixture-1\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 - - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

printf '#!/bin/bash\necho "$*" >> "%s/alert-calls"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/sibling-serial.sh "$H" >/dev/null || bad "closure install of bin/sibling-serial.sh failed"
# The queue-row recorders QROW calls (sourced, never executed). The abandoned
# answer is on only while $T/abandoned exists (K5).
cat > "$H/bin/jobs-client.sh" <<JC
queue_done() { printf 'done\t%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$T/qrow.log"; return 0; }
queue_put()  { printf 'put\t%s\t%s\t%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\$4" "\${5:-}" "\${6:-}" >> "$T/qrow.log"; return 0; }
job_ticket_abandoned() { [ -e "$T/abandoned" ] && { echo job-77; return 0; }; return 1; }
JC
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" \
         "$H/bin/alert-line.sh" "$T/fakebin"/*

# The parent's record: TK-183 is the contract, TK-184..TK-186 the parts.
mkdir -p "$H/builds/pool-project-5-TK-145-202610130100"
printf 'DECOMPOSED TK-183,TK-184,TK-185,TK-186\n' > "$H/builds/pool-project-5-TK-145-202610130100/RESULT"

run_pool() {
  : > "$H/logs/fly-pool.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok-fixture-1 FLY_BIN_DIR="$T/fakebin" \
           SIBLING_SERIAL_NOW="$NOW" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
reset_state() {
  local p
  for p in "$QD"/* "$MD"/* "$PD"/* "$H/plans"/* "$H/state/sibling-serial" "$T/qrow.log" \
           "$T/fly-calls" "$T/abandoned"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  mkdir -p "$H/state/overlap-guard"
  # PR #210 of TK-184, fresh in the overlap-guard cache
  jq -nc --arg f "$NOTE" '[{number:210, headRefName:"ticket/TK-184", isDraft:false, files:[{path:$f}]}]' \
    > "$H/state/overlap-guard/project-5-prs.json"
  return 0
}
plan_files() { local k="$1"; shift; mkdir -p "$H/plans/project-5-$k"; printf '%s\n' "$@" > "$H/plans/project-5-$k/planned-files.txt"; }
queue() { # queue <KEY> <ticket-id> [extra-json]
  jq -nc --arg k "$1" --arg t "$2" --argjson x "${3:-{\}}" \
    '{ticket_id:$t,key:$k,attempt:2,deferrals:1,deaths:1,enqueued_at:"2026-10-13T02:30:00Z"} + $x' > "$QD/$1.json"
}
machine_json() { grep -ls "\"key\": *\"$1\"" "$MD"/*.json 2>/dev/null | head -1; }
puts() { grep -c "^put${2:+	}" "$T/qrow.log" 2>/dev/null || echo 0; }

# ── K1 ──────────────────────────────────────────────────────────────────────
reset_state
plan_files TK-186 "$NOTE" src/lib/meeting-notes/draft.ts
queue TK-186 186
run_pool
[ -z "$(machine_json TK-186)" ] && ok || bad "K1 tick 1: no machine is spawned on the stack conversion"
grep -q 'SIBLING_SERIAL TK-186 stacks on ticket/TK-184 (open PR of TK-184)' "$H/logs/fly-pool.log" && ok \
  || bad "K1 tick 1: no stack line: $(cat "$H/logs/fly-pool.log")"
[ "$(jq -r '.stack_base // ""' "$QD/TK-186.json" 2>/dev/null)" = ticket/TK-184 ] && ok \
  || bad "K1 tick 1: the queue file must carry stack_base: $(cat "$QD/TK-186.json" 2>/dev/null)"
[ "$(jq -c '[.attempt,.deferrals,.deaths,.ticket_id]' "$QD/TK-186.json" 2>/dev/null)" = '[2,1,1,"186"]' ] && ok \
  || bad "K1 tick 1: attempt, deferrals, deaths and the ticket id are kept: $(cat "$QD/TK-186.json")"
[ "$(grep -c '^put' "$T/qrow.log" 2>/dev/null)" = 1 ] && ok || bad "K1 tick 1: exactly one queue_put: $(cat "$T/qrow.log" 2>/dev/null)"
grep -q '^put	project-5	TK-186	186	fly	2	.*"stack_base":"ticket/TK-184"' "$T/qrow.log" && ok \
  || bad "K1 tick 1: the requeue carries attempt 2 and stack_base in its meta: $(cat "$T/qrow.log" 2>/dev/null)"
grep -q '^done	project-5	TK-186	failed	sibling stack on ticket/TK-184 (BH-6374)' "$T/qrow.log" && ok \
  || bad "K1 tick 1: the row is closed with the stack reason: $(cat "$T/qrow.log" 2>/dev/null)"
[ -s "$PD/TK-186.spawns" ] && bad "K1 tick 1: a stack conversion is not a spawn" || ok
# tick 2: the row stacks on ticket/TK-184, so that PR does not hold it
run_pool
MJ=$(machine_json TK-186)
[ -n "$MJ" ] && ok || bad "K1 tick 2: TK-186 must spawn: $(cat "$H/logs/fly-pool.log")"
[ -n "$MJ" ] && [ "$(jq -r '.stack_base // ""' "$MJ")" = ticket/TK-184 ] && ok \
  || bad "K1 tick 2: the machine json carries stack_base: $(cat "$MJ" 2>/dev/null)"
grep -q 'SIBLING_SERIAL TK-186' "$H/logs/fly-pool.log" && bad "K1 tick 2: no wait or stack line: $(grep SIBLING "$H/logs/fly-pool.log")" || ok
[ "$(grep -c '^put' "$T/qrow.log" 2>/dev/null)" = 1 ] && ok || bad "K1 tick 2: no second requeue"

# ── K2: a non-part key in the same queue spawns on tick 1 ───────────────────
reset_state
plan_files TK-186 "$NOTE"
plan_files BH-1016 "$NOTE"
queue TK-186 186
queue BH-1016 1016
run_pool
[ -n "$(machine_json BH-1016)" ] && ok || bad "K2: the non-part key must spawn: $(cat "$H/logs/fly-pool.log")"
[ -z "$(machine_json TK-186)" ] && ok || bad "K2: TK-186 is converted, not spawned, on tick 1"

# ── K3: SIBLING_STACK=0 waits as in C0 ─────────────────────────────────────
reset_state
plan_files TK-186 "$NOTE"
queue TK-186 186
run_pool SIBLING_STACK=0
grep -q 'SIBLING_SERIAL TK-186 waits for TK-184 on src/lib/meeting-notes/report.ts — no machine spawned' "$H/logs/fly-pool.log" && ok \
  || bad "K3: C0's wait line: $(cat "$H/logs/fly-pool.log")"
[ -z "$(jq -r '.stack_base // ""' "$QD/TK-186.json")" ] && ok || bad "K3: no stack_base written"
[ -s "$T/qrow.log" ] && bad "K3: no requeue: $(cat "$T/qrow.log")" || ok
[ -z "$(machine_json TK-186)" ] && ok || bad "K3: no machine"

# ── K4: a row that already stacks is not requeued again ───────────────────
# Its own base is not a blocker; a SECOND sibling PR (TK-185) is, and is
# stackable on its own, but the row already has a base: it waits.
reset_state
plan_files TK-186 "$NOTE"
queue TK-186 186 '{"stack_base":"ticket/TK-184"}'
jq -nc --arg f "$NOTE" '[{number:210, headRefName:"ticket/TK-184", isDraft:false, files:[{path:$f}]},
                        {number:211, headRefName:"ticket/TK-185", isDraft:false, files:[{path:$f}]}]' \
  > "$H/state/overlap-guard/project-5-prs.json"
run_pool
[ -s "$T/qrow.log" ] && bad "K4: a stacked row is not requeued a second time: $(cat "$T/qrow.log")" || ok
[ "$(jq -r '.stack_base' "$QD/TK-186.json")" = ticket/TK-184 ] && ok || bad "K4: the row's base is unchanged"
grep -q 'SIBLING_SERIAL TK-186 waits for TK-185 on src/lib/meeting-notes/report.ts stackable base=ticket/TK-185 — no machine spawned' "$H/logs/fly-pool.log" && ok \
  || bad "K4: the row waits for TK-185: $(cat "$H/logs/fly-pool.log")"

# ── K5: an abandoned ticket is not rewritten ──────────────────────────────
reset_state
plan_files TK-186 "$NOTE"
queue TK-186 186
touch "$T/abandoned"
run_pool
[ -z "$(jq -r '.stack_base // ""' "$QD/TK-186.json" 2>/dev/null)" ] && ok || bad "K5: the queue file must not be rewritten"
grep -q '^put' "$T/qrow.log" 2>/dev/null && bad "K5: an abandoned row is not enqueued: $(cat "$T/qrow.log")" || ok
grep -q 'SIBLING_SERIAL TK-186: not stacked on ticket/TK-184' "$H/logs/fly-pool.log" && ok \
  || bad "K5: the log must say it was not stacked: $(cat "$H/logs/fly-pool.log")"
grep -q 'stacks on' "$H/logs/fly-pool.log" && bad "K5: no stack claim on an abandoned row" || ok
[ -z "$(machine_json TK-186)" ] && ok || bad "K5: no machine"

echo "fly-pool-sibling-stack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
