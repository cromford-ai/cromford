#!/bin/bash
# tests/pool-autoscale-test.sh — the pool spawns ONE MACHINE PER QUEUED BUILD
# (the operator, 2026-09-14: "we can launch unlimited builders with fly.io").
#
# WHAT THIS PINS. bin/fly-pool.sh's budget used to be `cap - live`, and the cap
# was ours: nothing configured meant 3, so nine projects were a 27-builder fleet
# ceiling nobody had chosen. The budget is now the DEPTH of the project's queue,
# and a configured number is a cost-safety ceiling that still binds. Three things
# can silently regress and all three are driven here against a real
# bin/fly-pool.sh with a stubbed flyctl and a stubbed ledger directory:
#   1. queue depth, not a constant, decides how many machines a tick spawns
#   2. an explicit cap (flag, conf, POOL_CAP_MAX) still caps
#   3. POOL_AUTOSCALE=0 gives back the old budget AND the old silence
# The per-tick line is an assertion too: throughput nobody can grep is a claim.
# Run from anywhere: tests/pool-autoscale-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" "$H/state/build-queue/project-5" \
         "$H/builds" "$T/fakebin"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
printf 'HARNESS_SECRET=test-secret\n' > "$H/env/global.env"
: > "$H/env/fly.env"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/builder-project-5:deployment-01\n' > "$H/state/fly/project-5.image"
# No bin/jobs-client.sh in this tree on purpose: the pool fails open without a
# ledger client, which is the shape every assertion below wants — the QUEUE
# DIRECTORY is the stub, and it is exactly what bin/fly-dispatch.sh materialises
# from `build_queue` rows (one file per queued row, claimed as it is written).
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
# The 20s post-boot wait is real time this suite must not spend.
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# flyctl: every `machine run` hands back a fresh 14-hex id, so the count of
# machine jsons under state/fly-pool/<p> is the count of spawns this tick made.
# The id comes from urandom, not a counter file: forty spawns run CONCURRENTLY
# and a read-increment-write counter loses one to a race, which would show up
# here as a phantom product bug.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
case "$*" in
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: %s\n' "$(head -c 7 /dev/urandom | od -An -tx1 | tr -d ' \n')" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

queue() { # queue <n> — n queued rows, materialised the way fly-dispatch.sh does
  rm -f "$H/state/build-queue/project-5"/*.json "$H/state/fly-pool/project-5"/*.json
  local i
  for i in $(seq 1 "$1"); do
    jq -nc --arg k "TK-$i" --arg t "$i" \
      '{ticket_id:$t,key:$k,attempt:0,deferrals:0,deaths:0}' \
      > "$H/state/build-queue/project-5/TK-$i.json"
  done
}
tick() { # tick [VAR=VAL ...] — one bin/fly-pool.sh pass, prints machines spawned
  : > "$H/logs/fly-pool.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_project-5=tok "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
  ls "$H/state/fly-pool/project-5"/*.json 2>/dev/null | wc -l | tr -d ' '
}
line() { grep -o 'pool project-5: .*' "$H/logs/fly-pool.log" | tail -1; }

# ══ 1. NO CEILING: the queue decides ════════════════════════════════════════
: > "$H/flags/fly-pool-project-5"     # enable switch alone = unlimited
queue 7
N=$(tick)
[ "$N" = 7 ] && ok || bad "7 queued builds must spawn 7 machines in ONE tick (got $N)"
[ "$(line)" = "pool project-5: queued=7 running=0 spawning=7 cap=unlimited" ] \
  && ok || bad "the per-tick line must state the depth it is answering (got '$(line)')"
queue 40
N=$(tick)
[ "$N" = 40 ] && ok || bad "40 queued builds must spawn 40 machines — no ceiling is ours to keep (got $N)"

# ══ 2. AN EXPLICIT NUMBER IS STILL A HARD CEILING ═══════════════════════════
echo 2 > "$H/flags/fly-pool-project-5"
queue 7
N=$(tick)
[ "$N" = 2 ] && ok || bad "a flag NUMBER still caps the tick at 2 (got $N)"
[ "$(line)" = "pool project-5: queued=7 running=0 spawning=2 cap=2" ] \
  && ok || bad "the line must name the cap that bound (got '$(line)')"
: > "$H/flags/fly-pool-project-5"; printf 'project-5 3\n' > "$H/fly/pool-caps.conf"
N=$(tick)
[ "$N" = 3 ] && ok || bad "a reviewed fly/pool-caps.conf line caps the tick at 3 (got $N)"
: > "$H/fly/pool-caps.conf"
N=$(tick POOL_CAP_MAX=4)
[ "$N" = 4 ] && ok || bad "POOL_CAP_MAX is the fleet-wide brake and it binds here too (got $N)"
[ "$(line)" = "pool project-5: queued=7 running=0 spawning=4 cap=4" ] \
  && ok || bad "POOL_CAP_MAX must show as the cap, not as unlimited (got '$(line)')"

# ══ 3. THE BUDGET IS DEPTH, NOT A TARGET ════════════════════════════════════
# Fewer queued than the cap allows: the tick spawns what is waiting and says so.
queue 2
N=$(tick POOL_CAP_MAX=10)
[ "$N" = 2 ] && ok || bad "2 queued under a cap of 10 must spawn 2, never 10 (got $N)"
[ "$(line)" = "pool project-5: queued=2 running=0 spawning=2 cap=10" ] \
  && ok || bad "the line must report the depth, not the cap (got '$(line)')"
# A parked row is not queued work, and a second file for one key is not two
# builds — both would inflate the count that now DRIVES the machine total.
queue 2
cp "$H/state/build-queue/project-5/TK-1.json" "$H/state/build-queue/project-5/TK-9.failed.json"
N=$(tick)
[ "$N" = 2 ] && ok || bad "a *.failed.json park must not buy a machine (got $N)"
case "$(line)" in *"queued=2 "*) ok ;; *) bad "a parked row must not be counted as queued (got '$(line)')" ;; esac
queue 2
jq -nc '{ticket_id:"1",key:"TK-1",attempt:1}' > "$H/state/build-queue/project-5/TK-1.retry.json"
N=$(tick)
[ "$N" = 2 ] && ok || bad "two files for one key must still spawn ONE machine for it (got $N)"
# Empty queue: no spawns, and the tick still says so.
queue 0
N=$(tick)
[ "$N" = 0 ] && ok || bad "an empty queue spawns nothing (got $N)"
[ "$(line)" = "pool project-5: queued=0 running=0 spawning=0 cap=unlimited" ] \
  && ok || bad "an idle pool must log its idleness — that is how a starved lane is seen (got '$(line)')"

# ══ 4. KILL FLAG: POOL_AUTOSCALE=0 is today's behaviour, silence included ═══
queue 7
N=$(tick POOL_AUTOSCALE=0)
[ "$N" = 3 ] && ok || bad "POOL_AUTOSCALE=0 must restore the default cap of 3 (got $N)"
[ -z "$(line)" ] && ok || bad "POOL_AUTOSCALE=0 must not add a log line either (got '$(line)')"
grep -q '/3, budget 3 this tick' "$H/logs/fly-pool.log" \
  && ok || bad "POOL_AUTOSCALE=0: the spawn line must read live=n/3 exactly as before"
echo 5 > "$H/flags/fly-pool-project-5"
N=$(tick POOL_AUTOSCALE=0)
[ "$N" = 5 ] && ok || bad "POOL_AUTOSCALE=0: a flag number is still the cap (got $N)"
N=$(tick POOL_AUTOSCALE=0 POOL_CAP_MAX=1)
[ "$N" = 5 ] && ok || bad "POOL_AUTOSCALE=0 must ignore POOL_CAP_MAX — it did not exist (got $N)"

# ══ 5. THE SWEEP: no project waits on a sibling, and a flag number stays a cap
# bin/fly-pool-tick.sh is DRIVEN here against its own scratch tree: fly-pool.sh
# is replaced by a recorder, so this section is about the sweep alone.
# BH-7433 removed the 2026-09-14 one-shot that emptied the number in the flag:
# a number there now is an operator's POOL_CAP (bin/fly-pool-rollout.sh) and stays.
S="$T/sweep"; mkdir -p "$S/bin" "$S/flags" "$S/logs" "$S/state/fly-pool"
cp "$DIR/bin/pool-cap.sh" "$S/bin/"
printf '#!/bin/bash\nexit 0\n' > "$S/bin/fly-lock-guard.sh"
printf '#!/bin/bash\nsleep 1; echo "$1" >> "%s/ticked.txt"\n' "$S" > "$S/bin/fly-pool.sh"
chmod +x "$S/bin"/*.sh
mkdir -p "$S/env"; : > "$S/env/global.env"
for p in alpha beta gamma; do echo 10 > "$S/flags/fly-pool-$p"; done
printf 'pool-alpha\n' > "$S/flags/fly-pool-app-alpha"
sweep() { : > "$S/ticked.txt"; ( export HARNESS="$S" "$@"; bash "$DIR/bin/fly-pool-tick.sh" ) ; }

START=$(date +%s); sweep; EL=$(( $(date +%s) - START ))
[ "$(sort "$S/ticked.txt" | tr '\n' ' ')" = "alpha beta gamma " ] \
  && ok || bad "every flagged project must be ticked (got '$(tr '\n' ' ' < "$S/ticked.txt")')"
[ "$EL" -lt 3 ] \
  && ok || bad "three 1s ticks must run CONCURRENTLY — a sibling project is not a queue (took ${EL}s)"
# The number inside the flag stays, and so does the flag itself.
[ "$(cat "$S/flags/fly-pool-alpha")" = 10 ] \
  && ok || bad "the sweep must leave the flag number 10 as it is (got '$(cat "$S/flags/fly-pool-alpha")')"
[ ! -e "$S/state/fly-pool/legacy-caps.alpha" ] \
  && ok || bad "the sweep must write no legacy-caps record: $(cat "$S/state/fly-pool/legacy-caps.alpha")"
! grep -q 'legacy flag cap' "$S/logs/fly-pool.log" 2>/dev/null \
  && ok || bad "the sweep must not report a retired cap in the pool log"
[ "$(HARNESS="$S" "$DIR/bin/pool-cap.sh" alpha)" = 10 ] \
  && ok || bad "after the sweep the flag number is still the cap (got $(HARNESS="$S" "$DIR/bin/pool-cap.sh" alpha))"
# A second sweep changes nothing either.
echo 4 > "$S/flags/fly-pool-alpha"; sweep
[ "$(cat "$S/flags/fly-pool-alpha")" = 4 ] \
  && ok || bad "a cap set between sweeps must stand"
# The kill flag gives back the sequential sweep and keeps the cap too.
echo 10 > "$S/flags/fly-pool-beta"
START=$(date +%s); sweep POOL_AUTOSCALE=0; EL=$(( $(date +%s) - START ))
[ "$(cat "$S/flags/fly-pool-beta")" = 10 ] \
  && ok || bad "POOL_AUTOSCALE=0 must leave the legacy flag cap alone"
[ "$EL" -ge 3 ] \
  && ok || bad "POOL_AUTOSCALE=0 must sweep the projects one after another (took ${EL}s)"

echo "pool-autoscale: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
