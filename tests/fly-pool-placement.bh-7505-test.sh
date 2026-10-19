#!/bin/bash
# tests/fly-pool-placement.bh-7505-test.sh — BH-7505: the pool tick of one
# project (project-6-os) runs on a lane-run machine, with a hub fallback, one
# run at a time across hub and Fly, idempotent write-backs and a rollback by
# the row.
#
# Driven over real curl against the REAL jobs worker on node:sqlite
# (tests/lib/mc-budget.bh-6887.mjs: lane_runs, project_leases, lane snapshots
# and settings routes, plus the /__setting and /__lease hooks), through the
# real bin/fly-pool.sh gate on a hub root and the real bin/lane-run-worker.sh,
# bin/project-lane-run.sh and bin/fly-pool-project.sh on a SEPARATE machine
# root. `fly` is a stub that records every call; the machine root runs a stub
# tick (bin/fly-pool.sh there) so the test owns what the tick writes.
#
#   H0  control: no placement row, and placement hub: the hub tick runs as today
#   H1  placement fly: the hub tick enqueues ONE lane_runs row (lane fly-pool,
#       args [bin/fly-pool-project.sh, project-6-os]), publishes the inputs and
#       makes no Fly call and no row work
#   H2  a second hub tick while that row is live: no new row, still no work
#   M1  the machine: worker --once claims the row, fetches the snapshot, the
#       entry takes the lease, runs the tick with the fence, posts a write-back
#       after the run and reports PROF state=TICKED; the lease is released
#   M2  write-backs apply exactly once: the hub's next tick applies them, a
#       second apply adds nothing, the log bytes are in the hub log once; a
#       build artifact rides back, and never rides out in the snapshot
#   S1  a second start while a Fly run holds the lease exits with no work, a
#       hub tick under placement hub does no work, and a hub tick under
#       placement fly keeps the row live
#   R1  rollback by the row: placement hub with an unclaimed row withdraws it,
#       the hub runs the tick, and the project lease is held while it runs
#   F1  fallback: an unclaimed row past the window is withdrawn and the hub
#       runs the tick (fallback=no-capacity); with the fallback row off the hub
#       runs nothing and one alert goes out
#   F2  a machine that lacks what a spawn needs defers (state=DEFERRED); the
#       hub takes the tick back (fallback=machine-deferred) and holds off a new
#       row for the backoff
#   X1  pp_fence_ok: no fence, a live fence, a lost fence, an unanswered renew
#   X2  bin/fly-pool.sh fences its spawn and its destroy and checkpoints after
#       the spawn record
#   U1  pp_none_fly: the fresh-cache fast path
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-placement.bh-7505-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
SRV="$DIR/tests/lib/mc-budget.bh-6887.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v flock >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or flock missing"; exit 0; }
REALCURL=$(command -v curl)
P=project-6-os; LANE=fly-pool

KT="$T/k"; HUB="$KT/hub"; MAC="$KT/mac"; FB="$KT/fakebin"; MFB="$KT/machine-fly"; SRCD="$KT/harness-src"
mkdir -p "$HUB" "$MAC" "$FB" "$MFB" "$SRCD"
for d in bin prompts rules catalog fly; do mkdir -p "$SRCD/$d"; done
: > "$SRCD/fleet.conf"

# ---- the roots ---------------------------------------------------------------
mkroot() { # mkroot <root>
  mkdir -p "$1/bin/lib" "$1/logs" "$1/state/fly/" "$1/flags" "$1/locks" "$1/builds" "$1/env" "$1/tmp" "$1/catalog"
  printf '%s example-org/project-6 - - 1 local local\n' "$P" > "$1/fleet.conf"
  : > "$1/env/global.env"
  cp -r "$DIR/catalog/lane-run-inputs.d" "$1/catalog/"
  cp "$DIR/bin/fleet-conf.sh" "$1/bin/fleet-conf.sh"
}
mkroot "$HUB"; mkroot "$MAC"
for L in bin/fly-pool.sh bin/lib/pool-placement.sh bin/lib/lane-placement.sh bin/lib/project-lease.sh bin/lib/lane-run-inputs.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$HUB" ) >/dev/null 2>&1 || bad "setup: closure of $L on the hub failed"
done
for L in bin/lane-run-worker.sh bin/project-lane-run.sh bin/fly-pool-project.sh bin/lib/pool-placement.sh bin/lib/project-lease.sh \
         bin/lib/lane-run-inputs.sh bin/lane-alert.sh bin/lib/alert-line-remote.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$MAC" ) >/dev/null 2>&1 || bad "setup: closure of $L on the machine failed"
done
# The hub's lane-alert records one line per call. The machine keeps the real one.
printf '#!/bin/bash\nprintf "%%s %%s\\n" "$(date -u +%%FT%%TZ)" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$HUB" > "$HUB/bin/lane-alert.sh"
for s in beat alert-line pool-cap; do printf '#!/bin/bash\nexit 0\n' > "$HUB/bin/$s.sh"; done
for s in beat alert-line; do printf '#!/bin/bash\nexit 0\n' > "$MAC/bin/$s.sh"; done
chmod +x "$HUB/bin/"*.sh "$MAC/bin/"*.sh 2>/dev/null
# The machine's tick is a stub: it records its environment and writes what a
# real tick writes. $STUB_HOLD (a file) makes it wait until the file is gone.
cat > "$MAC/bin/fly-pool.sh" <<EOF
#!/bin/bash
H="\${HARNESS:?}"; PRJ="\${1:?}"
echo "tick \$PRJ on-machine=\${POOL_ON_MACHINE:-} fence=\${POOL_LEASE_FENCE:-} stop=\${POOL_STOP_FILE:+set}" >> "$KT/ticks.txt"
mkdir -p "\$H/state/fly-pool/\$PRJ" "\$H/state/build-queue/\$PRJ" "\$H/builds/pool-\$PRJ-TK-2-202610190001" "\$H/logs"
echo '{"machine":"abcdef01234567","key":"TK-1"}' > "\$H/state/fly-pool/\$PRJ/abcdef01234567.json"
rm -f "\$H/state/build-queue/\$PRJ/TK-1.json"
echo "PR_CREATED https://github.com/x/y/pull/1" > "\$H/builds/pool-\$PRJ-TK-2-202610190001/RESULT"
echo "the pipeline log" > "\$H/builds/pool-\$PRJ-TK-2-202610190001/pipeline.log"
echo "\$(date -u '+%F %TZ') [pool/\$PRJ] spawned abcdef01234567 for TK-1 (live=1/unlimited, budget 3 this tick)" >> "\$H/logs/fly-pool.log"
# The spawn's own checkpoint (bin/fly-pool.sh calls pp_checkpoint after the record).
. "\$H/bin/lib/pool-placement.sh"; say() { :; }
pp_checkpoint "\$PRJ" abcdef01234567
i=0; while [ -e "\${STUB_HOLD:-/nonexistent}" ] && [ "\$i" -lt 300 ]; do sleep 0.1; i=\$((i+1)); done
exit "\${STUB_RC:-0}"
EOF
chmod +x "$MAC/bin/fly-pool.sh"
# The hub's catalog and a pre-existing build record: the snapshot carries its
# marker, and never its artifact (M2).
OLD="$HUB/builds/pool-$P-TK-0-202610180001"; mkdir -p "$OLD"
echo "PR_CREATED https://github.com/x/y/pull/0" > "$OLD/RESULT"; echo "old artifact" > "$OLD/pipeline.log"
mkdir -p "$HUB/state/build-queue/$P"; echo '{"key":"TK-1"}' > "$HUB/state/build-queue/$P/TK-1.json"
printf '3\n' > "$HUB/flags/fly-pool-$P"; printf 'pool-%s\n' "$P" > "$HUB/flags/fly-pool-app-$P"
printf '{"app":"pool-%s"}\n' "$P" > "$HUB/state/fly/$P.json"
printf 'FLY_API_TOKEN_project-6_OS=tok\n' > "$HUB/env/fly.env"

# The hub's fly: every call is a line in $KT/fly.txt. `agent start` also
# records the project lease row of this instant (L1).
cat > "$FB/fly" <<EOF
#!/bin/bash
echo "fly \$*" >> "$KT/fly.txt"
case "\$*" in
  *"agent start"*) "$REALCURL" -sS "\${JOBS_URL:-http://127.0.0.1:1}/__lease?lane=$LANE&project=$P" > "$KT/lease-at-start.json" 2>/dev/null; echo >> "$KT/lease-at-start.json" ;;
  *"machines list"*) echo '[]' ;;
esac
while [ -e "$KT/fly-hold" ]; do sleep 0.1; done
exit 0
EOF
# The curl wrapper: the body of every lane_runs enqueue is a line in rows.txt.
cat > "$FB/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in
  */api/lane-runs)
    prev=""; for a in "\$@"; do [ "\$prev" = --data-binary ] && printf '%s\n' "\$a" >> "$KT/rows.txt"; prev="\$a"; done ;;
esac
exec "$REALCURL" "\$@"
EOF
printf '#!/bin/bash\nshift; exec "$@"\n' > "$FB/timeout"
printf '#!/bin/bash\nexit 0\n' > "$FB/gh"
cp "$FB/fly" "$MFB/fly"
chmod +x "$FB/"* "$MFB/fly"
# The scripts' #!/bin/bash is bash 3.2 on a Mac; the harness needs bash 4+.
# env bash is the same bash on a Linux box.
for f in "$HUB/bin/"*.sh "$MAC/bin/"*.sh; do sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$f"; done

# ---- the worker ----------------------------------------------------------------
: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
trap 'kill "$SPID" 2>/dev/null; rm -f "$KT/fly-hold" "$KT/hold"' EXIT
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
W="http://127.0.0.1:$PORT"
AUTH=(-H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json')
setting() { "$REALCURL" -sS -X PUT "$W/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
lease() { "$REALCURL" -sS "$W/__lease?lane=$LANE&project=$P"; }
rows() { "$REALCURL" -sS "${AUTH[@]}" "$W/api/lane-runs/by-prefix?lane=$LANE&project_prefix=$P&limit=50" | jq -c --arg p "$P" '[.rows[] | select(.project == $p)]'; }
flyn() { grep -c . "$KT/fly.txt" 2>/dev/null || true; }
WAITFOR() { local i; for i in $(seq 1 "${2:-100}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }
ENVS=(HARNESS_SECRET=fixture-harness-secret JOBS_URL="$W" GH_TOKEN=pat-fixture JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0
  JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box POOL_TICK_BUDGET_S=30)
# htick [VAR=val...] — one hub tick of the project (bin/fly-pool.sh).
htick() { ( cd "$KT" && env "${ENVS[@]}" HARNESS="$HUB" PATH="$FB:$PATH" FLY_BIN_DIR="$FB" FLEET_CONF="$HUB/fleet.conf" \
            FLY_API_TOKEN_project-6_OS=tok "$@" bash "$HUB/bin/fly-pool.sh" "$P" >/dev/null 2>"$KT/htick.err" ); }
# mrun [VAR=val...] — the machine's worker, one drain of the queue.
mrun() { ( cd "$KT" && env "${ENVS[@]}" HARNESS="$MAC" FLY_BIN_DIR="$MFB" FLEET_CONF="$MAC/fleet.conf" FLY_MACHINE_ID=m1 \
           FLY_API_TOKEN_project-6_OS=tok POOL_HARNESS_SRC="$SRCD" LANE_RUN=1 "$@" bash "$MAC/bin/lane-run-worker.sh" --once --machine m1 ) \
         > "$KT/mrun.out" 2> "$KT/mrun.err"; }
reset() {
  scratch_rm "$HUB/state/pool-fly"; scratch_rm "$MAC/state"; scratch_rm "$MAC/builds"; mkdir -p "$MAC/builds" "$MAC/state"
  scratch_rm "$HUB/locks"; mkdir -p "$HUB/locks"; scratch_rm "$MAC/locks"; mkdir -p "$MAC/locks"
  : > "$KT/fly.txt"; : > "$KT/ticks.txt"; : > "$HUB/logs/ALERTS.log"; : > "$HUB/logs/fly-pool.log"; : > "$MAC/logs/fly-pool.log"
  rm -f "$KT/fly-hold" "$KT/hold" "$KT/lease-at-start.json"
  printf '{"app":"pool-%s"}\n' "$P" > "$HUB/state/fly/$P.json"
}
HLOG="$HUB/logs/fly-pool.log"
hublog() { tail -6 "$HLOG" 2>/dev/null; }
nowork() { # nowork <case> — the hub made no Fly call
  [ "$(flyn)" = 0 ] && ok "$1 the hub tick made no Fly call" || bad "$1 Fly calls: $(cat "$KT/fly.txt")"
}
dowork() { [ "$(flyn)" -gt 0 ] && ok "$1 the hub tick ran (Fly calls made)" || bad "$1 no hub tick: $(hublog) $(tail -3 "$KT/htick.err")"; }
stale_lease() { "$REALCURL" -sS -X POST "$W/__lease" -d "{\"lane\":\"$LANE\",\"project\":\"$P\",\"holder\":\"$1\",\"fence\":${2:-99},\"lease_until\":\"${3:-2000-01-01T00:00:00Z}\"}" >/dev/null; }

# ============================================================================
echo "H0: control — no placement row, and placement hub: today's hub tick"
reset
htick
dowork H0
[ "$(rows | jq length)" = 0 ] && ok "H0 no lane_runs row" || bad "H0 rows: $(rows)"
[ ! -d "$HUB/state/pool-fly" ] && ok "H0 no placement state on the hub" || bad "H0 state: $(ls "$HUB/state/pool-fly")"
reset; setting lane_placement.$LANE.$P hub
htick
dowork "H0 (row hub)"
[ "$(rows | jq length)" = 0 ] && ok "H0 row hub: no lane_runs row" || bad "H0 row hub: rows $(rows)"

# ============================================================================
echo "H1: placement fly — one row, the inputs published, no hub work"
reset; setting lane_placement.$LANE.$P fly; setting lane_fallback.$LANE.$P hub
htick
R=$(rows)
[ "$(jq length <<<"$R")" = 1 ] && ok "H1 exactly one lane_runs row" || bad "H1 rows: $R; log: $(hublog)"
[ "$(jq -c '.[0] | [.lane, .project, .status]' <<<"$R")" = "[\"$LANE\",\"$P\",\"queued\"]" ] && ok "H1 lane fly-pool, project $P, queued" || bad "H1 row: $R"
RID=$(jq -r '.[0].id' <<<"$R")
A=$(jq -c 'select(.lane == "fly-pool") | .args' "$KT/rows.txt" 2>/dev/null | tail -1)
[ "$A" = '["bin/fly-pool-project.sh","project-6-os"]' ] && ok "H1 args name the project entry" || bad "H1 args: $A"
nowork H1
grep -q "PUT /api/lane-snapshots/$LANE/$P" "$T/srv.log" && ok "H1 the inputs were published (a snapshot PUT)" || bad "H1 no snapshot PUT: $(grep snapshots "$T/srv.log" | head -3)"
grep -q "\[pool/$P\] placed fly: enqueued $LANE $P" "$HLOG" && ok "H1 one enqueue line in logs/fly-pool.log" || bad "H1 log: $(hublog)"
[ -s "$HUB/state/pool-fly/$P.placed" ] && ok "H1 the placed mark is written" || bad "H1 no placed mark"

# ============================================================================
echo "H2: a second hub tick while the row is live"
htick
[ "$(rows | jq length)" = 1 ] && ok "H2 still one row" || bad "H2 rows: $(rows)"
nowork H2
grep -q "\[pool/$P\] placed fly: row $RID is queued" "$HLOG" && ok "H2 the log names the live row" || bad "H2 log: $(hublog)"

# ============================================================================
echo "M1: the machine claims the row, takes the lease, runs the tick, writes back"
mrun
[ "$(grep -c . "$KT/ticks.txt")" = 1 ] && ok "M1 the tick ran once on the machine" || bad "M1 ticks: $(cat "$KT/ticks.txt"); out: $(cat "$KT/mrun.out") $(tail -3 "$KT/mrun.err") $(tail -4 "$MAC/logs/lane-run-worker.log")"
F=$(sed -n 's/.*fence=\([0-9]*\) .*/\1/p' "$KT/ticks.txt" | head -1)
grep -q "on-machine=1 fence=[1-9][0-9]* stop=set" "$KT/ticks.txt" && ok "M1 the tick got POOL_ON_MACHINE, the fence and a stop file" || bad "M1 env: $(cat "$KT/ticks.txt")"
L=$(lease)
[ "$(jq -r .holder <<<"$L")" = m1 ] && [ "$(jq -r .fence <<<"$L")" = "$F" ] && ok "M1 the lease row is m1's fence $F" || bad "M1 lease: $L"
NOWISO=$(date -u +%FT%TZ)
[[ "$(jq -r .lease_until <<<"$L")" < "$NOWISO" || "$(jq -r .lease_until <<<"$L")" == "$NOWISO" ]] && ok "M1 the lease is released (lease_until <= now)" || bad "M1 lease: $L (now $NOWISO)"
R=$(rows | jq -c '.[0]')
[ "$(jq -r .status <<<"$R")" = done ] && [ "$(jq -r .rc <<<"$R")" = 0 ] && ok "M1 the row is done rc 0" || bad "M1 row: $R"
jq -r .prof_line <<<"$R" | grep -qE '^PROF fly-pool-project state=TICKED spawned=1 reaped=0 deferred=- fence=[0-9]+$' && ok "M1 PROF state=TICKED spawned=1" || bad "M1 prof: $(jq -r .prof_line <<<"$R")"
[ "$(grep -c "POST /api/lane-snapshots/$LANE/$P/writebacks 20" "$T/srv.log")" = 2 ] && ok "M1 two write-backs: the spawn's checkpoint and the final one" || bad "M1 write-backs: $(grep writebacks "$T/srv.log" | head)"
grep -q "\[pool/$P\] fly run start on m1" "$MAC/logs/fly-pool.log" && ok "M1 the machine log has a start marker" || bad "M1 machine log: $(tail -3 "$MAC/logs/fly-pool.log")"

# ============================================================================
echo "M2: the write-backs apply exactly once; a build artifact rides back, never out"
[ ! -e "$HUB/state/fly-pool/$P/abcdef01234567.json" ] && ok "M2 before the hub applies, the machine's spawn record is not on the hub" || bad "M2 pre-state"
htick
[ -s "$HUB/state/fly-pool/$P/abcdef01234567.json" ] && ok "M2 the hub's next tick applied the spawn record" || bad "M2 no spawn record on the hub: $(hublog)"
[ ! -e "$HUB/state/build-queue/$P/TK-1.json" ] && ok "M2 the queue change (a deletion) applied" || bad "M2 the queue file is still on the hub"
[ -s "$HUB/builds/pool-$P-TK-2-202610190001/RESULT" ] && ok "M2 the machine's RESULT marker arrived" || bad "M2 no RESULT: $(ls "$HUB/builds")"
[ -s "$HUB/builds/pool-$P-TK-2-202610190001/pipeline.log" ] && ok "M2 the build artifact (pipeline.log) arrived through the write-only list" || bad "M2 no artifact: $(ls "$HUB/builds/pool-$P-TK-2-202610190001" 2>&1)"
N1=$(grep -c "spawned abcdef01234567" "$HLOG")
[ "$N1" = 1 ] && ok "M2 the machine's log line is in the hub log once" || bad "M2 spawned lines: $N1"
OUT2=$( ( env "${ENVS[@]}" HARNESS="$HUB" bash -c '. "$HARNESS/bin/lib/lane-run-inputs.sh"; lri_apply_pending fly-pool project-6-os' ) 2>&1 )
[ "$OUT2" = "applied=0 conflicts=0 rejected=0" ] && ok "M2 a second apply adds nothing ($OUT2)" || bad "M2 second apply: $OUT2"
[ "$(grep -c "spawned abcdef01234567" "$HLOG")" = "$N1" ] && ok "M2 and the hub log is unchanged" || bad "M2 hub log grew"
SNAP=$("$REALCURL" -sS "${AUTH[@]}" "$W/api/lane-snapshots/$LANE/$P" | jq -r '.sha // empty')
[ -n "$SNAP" ] && ok "M2 the snapshot is served" || bad "M2 no snapshot answer"
( env "${ENVS[@]}" HARNESS="$HUB" bash -c '. "$HARNESS/bin/lib/lane-run-inputs.sh"; lri_publish fly-pool project-6-os' ) >/dev/null 2>&1
MEM=$( ( env "${ENVS[@]}" HARNESS="$HUB" bash -c '. "$HARNESS/bin/lib/lane-run-inputs.sh"; _lri_list project-6-os ro 0 | cut -f2' ) 2>/dev/null )
grep -qx "builds/pool-$P-TK-0-202610180001/RESULT" <<<"$MEM" && ok "M2 the snapshot list has the old record's marker" || bad "M2 ro list: $MEM"
! grep -qx "builds/pool-$P-TK-0-202610180001/pipeline.log" <<<"$MEM" && ok "M2 and not its artifact" || bad "M2 the artifact is in the snapshot list"

# ============================================================================
echo "S1: a second start while a Fly run holds the lease"
reset
setting lane_placement.$LANE.$P fly
htick   # a row (the previous one is done)
: > "$KT/hold"
( mrun STUB_HOLD="$KT/hold" ) &
MP=$!
WAITFOR '[ "$(lease | jq -r .holder 2>/dev/null)" = m1 ]' 100 || bad "S1 setup: the machine never took the lease: $(cat "$KT/mrun.out") $(tail -3 "$KT/mrun.err")"
WAITFOR '[ "$(grep -c . "$KT/ticks.txt")" = 1 ]' 100 || bad "S1 setup: the tick never started"
# a second entry start, as another machine would
( cd "$KT" && env "${ENVS[@]}" HARNESS="$MAC" FLY_BIN_DIR="$MFB" FLEET_CONF="$MAC/fleet.conf" FLY_MACHINE_ID=m2 \
    FLY_API_TOKEN_project-6_OS=tok POOL_HARNESS_SRC="$SRCD" bash "$MAC/bin/fly-pool-project.sh" "$P" ) > "$KT/s1.out" 2> "$KT/s1.err"; rc=$?
[ "$rc" = 0 ] && ok "S1 the second start exits 0" || bad "S1 rc=$rc $(cat "$KT/s1.err")"
grep -q "^PROF fly-pool-project state=LEASE_HELD " "$KT/s1.out" && ok "S1 PROF state=LEASE_HELD" || bad "S1 out: $(cat "$KT/s1.out")"
[ "$(grep -c . "$KT/ticks.txt")" = 1 ] && ok "S1 the second start ran no tick" || bad "S1 ticks: $(cat "$KT/ticks.txt")"
[ "$(lease | jq -r .holder)" = m1 ] && ok "S1 m1 keeps the lease" || bad "S1 lease: $(lease)"
: > "$KT/fly.txt"; setting lane_placement.$LANE.$P hub
htick
nowork "S1 hub under placement hub (rollback with a Fly run live)"
grep -q "\[pool/$P\] a Fly run holds the project lease" "$HLOG" && ok "S1 the hub log names the lease" || bad "S1 log: $(hublog)"
setting lane_placement.$LANE.$P fly
htick
nowork "S1 hub under placement fly"
rm -f "$KT/hold"; wait "$MP"
WAITFOR '[ "$(rows | jq -r "[.[] | select(.status == \"done\")] | length")" -ge 1 ]' 50 && ok "S1 the held run ends done" || bad "S1 rows: $(rows)"

# ============================================================================
echo "R1: rollback by the row — an unclaimed row is withdrawn, the hub runs, the lease is held while it runs"
reset
setting lane_placement.$LANE.$P fly
htick; RID=$(rows | jq -r '[.[] | select(.status == "queued")][0].id // empty')
[ -n "$RID" ] || bad "R1 setup: no queued row: $(rows)"
setting lane_placement.$LANE.$P hub
: > "$KT/fly-hold"
( htick ) &
HP=$!
WAITFOR '[ -s "$KT/lease-at-start.json" ]' 100 || bad "R1 setup: the hub tick never started: $(hublog) $(cat "$KT/htick.err")"
LS=$(head -1 "$KT/lease-at-start.json")
[[ "$(jq -r '.holder // empty' <<<"$LS")" == hub-* ]] && ok "R1 the lease is the hub's while the hub tick runs ($(jq -r .holder <<<"$LS"))" || bad "R1 lease at start: $LS"
rm -f "$KT/fly-hold"; wait "$HP"
Rw=$(rows | jq -c --argjson id "$RID" '.[] | select(.id == $id)')
[ "$(jq -r .status <<<"$Rw")" = died ] && jq -r .prof_line <<<"$Rw" | grep -q '^withdrawn by=hub-' && ok "R1 the queued row is withdrawn" || bad "R1 row: $Rw"
dowork R1
[ ! -e "$HUB/state/pool-fly/$P.placed" ] && ok "R1 the placed mark is gone" || bad "R1 mark left"
L=$(lease); NOWISO=$(date -u +%FT%TZ)
[[ "$(jq -r .lease_until <<<"$L")" < "$NOWISO" || "$(jq -r .lease_until <<<"$L")" == "$NOWISO" ]] && ok "R1 the hub released the lease at the end" || bad "R1 lease: $L"
: > "$KT/fly.txt"; htick
dowork "R1 (next tick, no mark)"

# ============================================================================
echo "F1: fallback — an unclaimed row past the window runs on the hub"
reset
setting lane_placement.$LANE.$P fly; setting lane_fallback.$LANE.$P hub
htick; RID=$(rows | jq -r '[.[] | select(.status == "queued")][0].id // empty')
: > "$KT/fly.txt"
htick POOL_FLY_QUEUE_STALE_S=0
grep -q "\[pool/$P\] placed fly: fallback=no-capacity (row $RID unclaimed" "$HLOG" && ok "F1 fallback=no-capacity is logged" || bad "F1 log: $(hublog)"
dowork F1
Rw=$(rows | jq -c --argjson id "$RID" '.[] | select(.id == $id)')
[ "$(jq -r .status <<<"$Rw")" = died ] && jq -r .prof_line <<<"$Rw" | grep -q '^withdrawn by=hub-' && ok "F1 the stale row is withdrawn before the hub works" || bad "F1 row: $Rw"
echo "F1 off: the fallback row off — nothing on the hub, one alert"
reset; setting lane_fallback.$LANE.$P off
htick; htick POOL_FLY_QUEUE_STALE_S=0; htick POOL_FLY_QUEUE_STALE_S=0
nowork "F1 off"
[ "$(grep -c "fly-pool-fly-$P" "$HUB/logs/ALERTS.log")" = 1 ] && ok "F1 off: exactly one ALERTS line over two stale ticks" || bad "F1 off ALERTS: $(cat "$HUB/logs/ALERTS.log")"

# ============================================================================
echo "F2: a machine that lacks what a spawn needs defers; the hub takes the tick back, then backs off"
reset; setting lane_fallback.$LANE.$P hub
htick; N0=$(rows | jq length)
mrun FLY_BIN_DIR="$KT/empty-bin" POOL_HARNESS_SRC="$KT/no-such-dir" FLY_API_TOKEN_project-6_OS=
[ "$(grep -c . "$KT/ticks.txt")" = 0 ] && ok "F2 the machine ran no tick" || bad "F2 ticks: $(cat "$KT/ticks.txt")"
R=$(rows | jq -c '.[0]')
jq -r .prof_line <<<"$R" | grep -qE '^PROF fly-pool-project state=DEFERRED spawned=0 reaped=0 deferred=([a-z-]+,)*fly-token,harness-src fence=[0-9]+$' && ok "F2 PROF state=DEFERRED names what is missing" || bad "F2 row: $R"
[ "$(lease | jq -r .holder)" = m1 ] && ok "F2 the lease was taken and released by m1" || bad "F2 lease: $(lease)"
: > "$KT/fly.txt"
htick
grep -q "\[pool/$P\] placed fly: fallback=machine-deferred (row [0-9]*: .*fly-token,harness-src" "$HLOG" && ok "F2 fallback=machine-deferred names the row and the words" || bad "F2 log: $(hublog)"
dowork F2
[ "$(rows | jq length)" = "$N0" ] && ok "F2 no new row on the take-back tick" || bad "F2 rows: $(rows)"
: > "$KT/fly.txt"
htick
[ "$(rows | jq length)" = "$N0" ] && ok "F2 inside the backoff no new row" || bad "F2 rows in backoff: $(rows)"
dowork "F2 backoff"
grep -q "\[pool/$P\] placed fly: backoff" "$HLOG" && ok "F2 the backoff is logged" || bad "F2 log: $(hublog)"
rm -f "$HUB/state/pool-fly/$P.takeback-at"
: > "$KT/fly.txt"
htick
[ "$(rows | jq length)" = $((N0 + 1)) ] && ok "F2 after the backoff the next tick enqueues a new row" || bad "F2 rows after backoff: $(rows)"
nowork "F2 after the backoff"

# ============================================================================
echo "G1: on a lane-run machine the placement gate stands aside"
reset; setting lane_placement.$LANE.$P fly
N0=$(rows | jq length)
htick POOL_ON_MACHINE=1
dowork G1
[ "$(rows | jq length)" = "$N0" ] && ok "G1 no row enqueued by a machine tick" || bad "G1 rows: $(rows)"
[ ! -d "$HUB/state/pool-fly" ] && ok "G1 and no placement state" || bad "G1 state: $(ls "$HUB/state/pool-fly")"

# ============================================================================
echo "PF1: bin/fly-pool-project.sh --preflight"
pf() { ( cd "$KT" && env "${ENVS[@]}" HARNESS="$MAC" FLY_BIN_DIR="$MFB" FLEET_CONF="$MAC/fleet.conf" POOL_HARNESS_SRC="$SRCD" "$@" \
         bash "$MAC/bin/fly-pool-project.sh" --preflight "$P" ) 2>&1; }
OUT=$(pf FLY_API_TOKEN_project-6_OS=tok); [ "$OUT" = "preflight $P: ok" ] && ok "PF1 nothing missing: ok" || bad "PF1 ok: $OUT"
OUT=$(pf FLY_API_TOKEN_project-6_OS= POOL_HARNESS_SRC="$KT/none")
[[ "$OUT" == "preflight $P: missing "*fly-token,harness-src ]] && ok "PF1 names the token and the tree: $OUT" || bad "PF1 missing: $OUT"
printf '%s example-org/project-6 - - 1 box-project-6-os-1 192.0.2.81\n' "$P" > "$MAC/fleet.conf"
OUT=$(pf FLY_API_TOKEN_project-6_OS=tok HOME="$KT/nohome")
[[ "$OUT" == "preflight $P: missing "*env-bundle* ]] && ok "PF1 an owning box over the tailnet, with no ssh key: env-bundle" || bad "PF1 env-bundle: $OUT"
printf '%s example-org/project-6 - - 1 local local\n' "$P" > "$MAC/fleet.conf"

# ============================================================================
echo "T1: TERM during a run — the lease and the row are released, the write-back is posted"
reset; setting lane_placement.$LANE.$P fly; setting lane_run.term_grace_s 20
htick
RID=$(rows | jq -r '[.[] | select(.status == "queued")][0].id // empty')
[ -n "$RID" ] || bad "T1 setup: no queued row: $(rows)"
: > "$KT/hold"
W0=$(grep -c "POST /api/lane-snapshots/$LANE/$P/writebacks 20" "$T/srv.log")
( cd "$KT" && exec env "${ENVS[@]}" HARNESS="$MAC" FLY_BIN_DIR="$MFB" FLEET_CONF="$MAC/fleet.conf" FLY_MACHINE_ID=m6 FLY_API_TOKEN_project-6_OS=tok \
    POOL_HARNESS_SRC="$SRCD" LANE_RUN=1 STUB_HOLD="$KT/hold" POOL_PROJECT_TERM_WAIT_S=1 bash "$MAC/bin/lane-run-worker.sh" --once --machine m6 ) > "$KT/t1.out" 2>&1 &
WP=$!
WAITFOR '[ "$(grep -c . "$KT/ticks.txt")" = 1 ]' 150 || bad "T1 setup: the tick never started: $(cat "$KT/t1.out") $(tail -3 "$MAC/logs/lane-run-worker.log" 2>/dev/null)"
[ "$(lease | jq -r .holder)" = m6 ] && ok "T1 the run holds the lease (m6)" || bad "T1 lease: $(lease)"
kill -TERM "$WP"; wait "$WP"; wrc=$?
[ "$wrc" = 0 ] && ok "T1 the worker exits 0" || bad "T1 worker rc=$wrc $(cat "$KT/t1.out")"
WAITFOR '! pgrep -f "$MAC/bin/fly-pool.sh" >/dev/null' 50 && ok "T1 no tick process outlives the run (the tree is reaped)" || bad "T1 survivors: $(pgrep -fl "$MAC/bin/fly-pool.sh" | head -3)"
L=$(lease); NOWISO=$(date -u +%FT%TZ)
[ "$(jq -r .holder <<<"$L")" = m6 ] && [[ "$(jq -r .lease_until <<<"$L")" < "$NOWISO" || "$(jq -r .lease_until <<<"$L")" == "$NOWISO" ]] && ok "T1 the lease is released" || bad "T1 lease: $L (now $NOWISO)"
Rw=$(rows | jq -c --argjson id "$RID" '.[] | select(.id == $id)')
[ "$(jq -r .status <<<"$Rw")" = queued ] && [ "$(jq -r .claimed_by <<<"$Rw")" = null ] && ok "T1 the row is queued again" || bad "T1 row: $Rw"
grep -q "fly run on m6: TERM" "$MAC/logs/fly-pool.log" && ok "T1 the entry logged the stop" || bad "T1 log: $(tail -4 "$MAC/logs/fly-pool.log")"
[ "$(grep -c "POST /api/lane-snapshots/$LANE/$P/writebacks 20" "$T/srv.log")" -gt "$W0" ] && ok "T1 the stopped run posted its write-back" || bad "T1 no write-back after the stop"
rm -f "$KT/hold"
htick POOL_FLY_QUEUE_STALE_S=0   # no machine comes back for the row: the hub takes the tick, write-backs first
grep -q "\[pool/$P\] machine abcdef01234567 for TK-1 " "$HLOG" && ok "T1 the hub's tick read the spawn record the stopped run made (it reaps the machine)" || bad "T1 no spawn record: $(hublog)"

# ============================================================================
echo "X1: pp_fence_ok"
fence() { ( env "${ENVS[@]}" HARNESS="$HUB" "$@" bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/project-lease.sh"; . "$HARNESS/bin/lib/pool-placement.sh"; say() { :; }; pp_fence_ok; echo $?' ) 2>/dev/null | tail -1; }
reset
[ "$(fence)" = 0 ] && ok "X1 no fence: rc 0, nothing checked" || bad "X1 no fence: $(fence)"
stale_lease holder-x 5 2099-01-01T00:00:00Z
[ "$(fence POOL_LEASE_FENCE=5 POOL_LEASE_PROJECT=$P POOL_LEASE_HOLDER=holder-x)" = 0 ] && ok "X1 a live fence: rc 0" || bad "X1 live: $(fence POOL_LEASE_FENCE=5 POOL_LEASE_PROJECT=$P POOL_LEASE_HOLDER=holder-x)"
stale_lease holder-y 6 2099-01-01T00:00:00Z
rm -f "$KT/stopf"
[ "$(fence POOL_LEASE_FENCE=5 POOL_LEASE_PROJECT=$P POOL_LEASE_HOLDER=holder-x POOL_STOP_FILE="$KT/stopf")" = 99 ] && ok "X1 a lost fence: rc 99" || bad "X1 lost: $(fence POOL_LEASE_FENCE=5 POOL_LEASE_PROJECT=$P POOL_LEASE_HOLDER=holder-x POOL_STOP_FILE="$KT/stopf")"
[ -e "$KT/stopf" ] && ok "X1 and the stop file is touched" || bad "X1 no stop file"
[ "$(fence POOL_LEASE_FENCE=6 POOL_LEASE_PROJECT=$P POOL_LEASE_HOLDER=holder-y POOL_STOP_FILE="$KT/stopf")" = 99 ] && ok "X1 a stop file stops every later write, with no request" || bad "X1 stop file"
"$REALCURL" -sS -X PUT "$W/__answer" -d '{"path_prefix":"/api/project-leases","status":503,"body":"{}"}' >/dev/null
rm -f "$KT/stopf"
[ "$(fence POOL_LEASE_FENCE=6 POOL_LEASE_PROJECT=$P POOL_LEASE_HOLDER=holder-y POOL_ON_MACHINE=1)" = 99 ] && ok "X1 an unanswered renew on a machine: rc 99" || bad "X1 machine outage"
[ "$(fence POOL_LEASE_FENCE=6 POOL_LEASE_PROJECT=$P POOL_LEASE_HOLDER=holder-y)" = 0 ] && ok "X1 an unanswered renew on the hub: rc 0 (the hub flock holds)" || bad "X1 hub outage"
"$REALCURL" -sS -X PUT "$W/__answer" -d '{}' >/dev/null

# ============================================================================
echo "X2: bin/fly-pool.sh fences its spawn and its destroy, and checkpoints after the spawn record"
FP="$DIR/bin/fly-pool.sh"
awk '/^spawn_one\(\)/{f=1} f&&/pp_fence_ok/{print "yes"; exit}' "$FP" | grep -qx yes && ok "X2 spawn_one calls pp_fence_ok" || bad "X2 spawn_one has no fence"
awk '/^destroy_machine\(\)/{f=1} f&&/pp_fence_ok/{print "yes"; exit} f&&/^}/{exit}' "$FP" | grep -qx yes && ok "X2 destroy_machine calls pp_fence_ok" || bad "X2 destroy_machine has no fence"
awk '/> "\$POOL\/\$MID.json"/{f=1} f&&/pp_checkpoint/{print "yes"; exit}' "$FP" | grep -qx yes && ok "X2 pp_checkpoint follows the machine record" || bad "X2 no checkpoint after the record"
grep -q 'pp_gate "\$P"' "$FP" && ok "X2 the hub gate is in bin/fly-pool.sh" || bad "X2 no gate"

# ============================================================================
echo "U1: pp_none_fly (the fresh-cache fast path)"
none() { ( env HARNESS="$HUB" JOBS_SETTINGS_CACHE_S=60 bash -c '. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1; . "$HARNESS/bin/lib/pool-placement.sh"; pp_none_fly; echo $?' ) 2>/dev/null | tail -1; }
mkcache() { printf '{"fetched_at":%s,"seeded":{"lane_placement.default":"hub"},"values":%s}\n' "$1" "$2" > "$HUB/state/settings-cache.json"; }
scratch_rm "$HUB/state/pool-fly"; NOW=$(date -u +%s)
mkcache "$NOW" '{}'; [ "$(none)" = 0 ] && ok "U1 fresh cache, no fly row: skip the gate" || bad "U1 none: $(none)"
mkcache "$NOW" "{\"lane_placement.fly-pool.$P\":\"fly\"}"; [ "$(none)" = 1 ] && ok "U1 a fly row: gate" || bad "U1 fly row"
mkcache "$((NOW - 3600))" '{}'; [ "$(none)" = 1 ] && ok "U1 a stale cache: gate" || bad "U1 stale"
mkcache "$NOW" '{}'; mkdir -p "$HUB/state/pool-fly"; echo fly > "$HUB/state/pool-fly/$P.placed"; [ "$(none)" = 1 ] && ok "U1 a placed mark: gate" || bad "U1 mark"
scratch_rm "$HUB/state/pool-fly"; scratch_rm "$HUB/state/settings-cache.json"

echo "fly-pool-placement.bh-7505: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
