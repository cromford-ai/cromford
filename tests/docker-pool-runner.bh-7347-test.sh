#!/bin/bash
# tests/docker-pool-runner.bh-7347-test.sh — BH-7347 (slice C1 of #7300): the
# docker-pool host runner bin/docker-pool-runner.sh and its lib
# bin/lib/docker-pool-host.sh, driven through the entry point against the REAL
# jobs worker (tests/lib/docker-pool-worker.bh-7300.mjs, node:sqlite) with a
# stub docker CLI (tests/lib/fake-docker.bh-7347.sh) first on PATH.
#
#   R1  max 0: rc 9, `off`, no docker run, the row stays queued, no lease
#   R2  two boxes race for one key: one docker run, one rc 9, one lease
#   R3  smoke: SMOKE_OK on stdout, the docker run flags, job.json key SMOKE,
#       docker rm, the env dir gone, no claim request
#   R4  run to a RESULT: stop -t 60, the C2 reap stub gets <work>/reap with
#       RESULT job.json cost.csv, lease done, the finish line, >= 2 beats,
#       env and data gone, the token never in docker argv
#   R5  TERM mid-build: rc 143, docker stop, row queued, lease released
#   R6  docker_pool.kill mid-build: rc 9, container stopped, no ALERTS line
#   R7  the worker answers 500 mid-build: fenced, one ALERTS line
#   R8  the container exits with no RESULT: rc 1, row queued
#   R9  hold gate: held / label-absent / unreadable refuse; clear and a board
#       ticket id build
#   R10 bad keys: rc 1 and no request; a key not queued: rc 2 and no claim
#   R11 reap-orphans: stops stale and lease-less labeled containers only
#   R12 the done-line string in fly/builder-runner.sh; dph_knob reads a
#       settings row; the registry default with no row
#   R13 RESULT without the done line: no stop for 2 beats; C2 rotate args
#   R14 the lease expires and is swept: rc 9 lost, one ALERTS line, no release
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/docker-pool-runner.bh-7347-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
SRV="$DIR/tests/lib/docker-pool-worker.bh-7300.mjs"
RUNNER="$DIR/bin/docker-pool-runner.sh"
HOSTLIB="$DIR/bin/lib/docker-pool-host.sh"
FAKE="$DIR/tests/lib/fake-docker.bh-7347.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }
[ -f "$RUNNER" ] || bad "setup: $RUNNER missing"
[ -f "$HOSTLIB" ] || bad "setup: $HOSTLIB missing"

# --- the scratch harness: stubs first (the closure install never clobbers) ---
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/env" "$H/locks" "$T/fbin"
: > "$H/env/global.env"
echo 'GH_APP_ID=fixture-app' > "$H/env/github-app.env"
cat > "$H/bin/fly-envbundle.sh" <<'EOF'
#!/bin/bash
# stub: a fixture bundle, no real secret
umask 077
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok-fixture-claude\nGH_TOKEN=ghp-fixture-pat-token\n' > "$2/global.env"
printf 'REPO_SLUG=example-org/%s-repo\n' "$1" > "$2/$1.env"
EOF
cat > "$H/bin/gh-token.sh" <<'EOF'
#!/bin/bash
# stub: a fixture App token
printf '%s\n' "$*" >> "$FIXTURE_T/ghtok.log"
case " $* " in
  *" --expires-at "*) echo 2099-01-01T00:00:00Z ;;
  *" --installation-id "*) echo 4242 ;;
  *) echo ghs-fixture-app-token ;;
esac
EOF
cat > "$H/bin/lib/docker-pool-reap.sh" <<'EOF'
# stub of the C2 lib (#7348): records its calls
docker_pool_cost_box() { printf 'pool-%s-%s\n' "$1" "$2"; }
docker_pool_reap() { printf '%s\n' "$*" >> "$FIXTURE_T/reap.log"; ls "$3" > "$FIXTURE_T/reap.ls.$2"; return 0; }
EOF
cat > "$H/bin/lib/docker-pool-token.sh" <<'EOF'
# stub of the C2 lib (#7348): records its calls
docker_pool_token_rotate() { printf '%s\n' "$*" >> "$FIXTURE_T/rotate.log"; return 0; }
EOF
cat > "$T/hold-stub.sh" <<'EOF'
# stub hold lib: the verdict comes from $FIXTURE_T/hold.verdict
hold_check() {
  printf '%s %s token=%s\n' "$1" "$2" "${GH_TOKEN:+set}" >> "$FIXTURE_T/hold.log"
  local v; v=$(cat "$FIXTURE_T/hold.verdict" 2>/dev/null)
  printf '%s\n' "$v"
  case "$v" in clear*) return 0 ;; held*) return 1 ;; *) return 2 ;; esac
}
EOF
chmod +x "$H/bin/fly-envbundle.sh" "$H/bin/gh-token.sh"
for L in bin/docker-pool-runner.sh bin/jobs-client.sh bin/lib/docker-pool.sh bin/alert-line.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$FAKE" "$T/fbin/docker" && chmod +x "$T/fbin/docker"
# A small harness checkout to tar (the runner ships its bin prompts rules
# catalog fleet.conf fly).
CK="$T/ck"
mkdir -p "$CK/bin" "$CK/prompts" "$CK/rules" "$CK/catalog" "$CK/fly"
echo 'echo fixture' > "$CK/bin/x.sh"; : > "$CK/fleet.conf"
printf '#!/bin/bash\necho fixture runner\n' > "$CK/fly/builder-runner.sh"; chmod +x "$CK/fly/builder-runner.sh"
git -C "$CK" init -q && git -C "$CK" add -A && git -C "$CK" -c user.email=f@example.invalid -c user.name=fixture commit -qm fixture \
  || bad "setup: fixture checkout"
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "setup: registry did not compose"

export HARNESS="$H" HARNESS_ENV_DIR="$H/env" FIXTURE_T="$T"
export HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10 LANE_GATE_CACHE_S=0
export LANE_REGISTRY="$REG"
export PATH="$T/fbin:$PATH" FAKE_DOCKER_DIR="$T/fd" FAKE_DOCKER_LOG="$T/docker.log"
export DOCKER_POOL_IMAGE=registry.example.invalid/fixture-builder:deploy-fixture
export DOCKER_POOL_CHECKOUT="$CK" DOCKER_POOL_ROOT="$T/dp" DOCKER_POOL_BEAT_S=1
export DOCKER_POOL_HOLD_LIB="$T/hold-stub.sh"
# Every build here ends in seconds; the wall cap turns a runner that would beat
# forever (a mutation, a regression) into a red case instead of a hung suite.
export DOCKER_POOL_MAX_BUILD_S=30
: > "$T/docker.log"; : > "$T/reap.log"; : > "$T/rotate.log"; : > "$T/hold.log"

: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
# The fake containers are background sleepers: stop them with the worker.
trap 'kill "$SPID" 2>/dev/null; for p in "$T"/fd/c/*/pid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done' EXIT

enqueue() { curl -sS -X POST -d "$(jq -nc --arg p "$1" --arg k "$2" --arg g "${3:-fly}" '{project:$p,key:$k,target:$g}')" "$JOBS_URL/__enqueue" > /dev/null; }
row() { curl -sS "$JOBS_URL/__row?project=$1&key=$2"; }
leases() { curl -sS "$JOBS_URL/__leases?project=$1&key=$2"; }
expire() { curl -sS -X POST -d "{\"project\":\"$1\",\"key\":\"$2\"}" "$JOBS_URL/__expire" > /dev/null; }
setting() { curl -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$JOBS_URL/__setting" > /dev/null; }
answer() { curl -sS -X PUT -d "$1" "$JOBS_URL/__answer" > /dev/null; }
LIBS=". '$H/bin/jobs-client.sh' && . '$H/bin/lib/docker-pool.sh'"
lib() { JOBS_BOX="$1" bash -c "$LIBS && $2" > "$T/out" 2> "$T/err"; }
# runr <box> <args...> — the entry point, foreground; stdout $T/out, stderr $T/err
runr() { local b="$1"; shift; JOBS_BOX="$b" bash "$H/bin/docker-pool-runner.sh" "$@" > "$T/out" 2> "$T/err"; }
# srv_n <pattern> — srv.log lines matching, from line $OFF on
srv_n() { tail -n +"$((OFF + 1))" "$T/srv.log" | grep -c -- "$1"; }
dk_n() { tail -n +"$((DOFF + 1))" "$T/docker.log" | grep -c -- "$1"; }
mark() { OFF=$(wc -l < "$T/srv.log"); DOFF=$(wc -l < "$T/docker.log"); }
wait_for() { local i; for i in $(seq 1 "${2:-100}"); do eval "$1" && return 0; sleep 0.2; done; return 1; }
# bwait <pid> — wait for a background runner, at most 60 s; past that it is
# killed and the rc is 124.
bwait() {
  local i
  for i in $(seq 1 300); do kill -0 "$1" 2>/dev/null || { wait "$1"; return $?; }; sleep 0.2; done
  kill -KILL "$1" 2>/dev/null; wait "$1" 2>/dev/null; return 124
}
fence_n() { grep -c 'DOCKER POOL FENCE' "$H/logs/ALERTS.log" 2>/dev/null; }
work_of() { ls -d "$T/dp/$1/$2"-dk-* 2>/dev/null | head -1; }
cid_of() { tail -n +"$((DOFF + 1))" "$T/docker.log" | grep -m1 '^stop ' | awk '{print $NF}'; }
runlog() { cat "$H/logs/docker-pool-runner.log" 2>/dev/null; }

# ============================================================================
echo "R1: max 0 claims nothing (AT4)"
setting docker_pool.max_concurrent 0
enqueue p1 D-1; mark
runr mac-a run p1 D-1; RC=$?
[ "$RC" = 9 ] && grep -q 'off' "$T/err" && ok "R1 rc 9, off on stderr" || bad "R1 rc=$RC err=$(cat "$T/err")"
[ "$(dk_n '^run ')" = 0 ] && ok "R1 no docker run" || bad "R1 docker: $(tail -n +"$((DOFF + 1))" "$T/docker.log")"
[ "$(row p1 D-1 | jq -r .status)" = queued ] && [ "$(leases p1 D-1 | jq length)" = 0 ] && ok "R1 row queued, 0 leases" || bad "R1 state: $(row p1 D-1) $(leases p1 D-1)"

# ============================================================================
echo "R2: two runners race for one key (AT1)"
setting docker_pool.max_concurrent 2
enqueue p1 D-2; mark
FAKE_DOCKER_SCRIPT=forever JOBS_BOX=mac-a bash "$H/bin/docker-pool-runner.sh" run p1 D-2 > "$T/a.out" 2> "$T/a.err" & PA=$!
FAKE_DOCKER_SCRIPT=forever JOBS_BOX=mac-b bash "$H/bin/docker-pool-runner.sh" run p1 D-2 > "$T/b.out" 2> "$T/b.err" & PB=$!
wait_for '[ "$(dk_n "^run ")" -ge 1 ]' 100 || bad "R2 no docker run at all"
wait_for '! kill -0 $PA 2>/dev/null || ! kill -0 $PB 2>/dev/null' 100
sleep 1
[ "$(dk_n '^run ')" = 1 ] && ok "R2 exactly one docker run" || bad "R2 runs: $(dk_n '^run ')"
[ "$(leases p1 D-2 | jq '[.[] | select(.status=="active")] | length')" = 1 ] && ok "R2 one active lease" || bad "R2 leases: $(leases p1 D-2)"
if kill -0 "$PA" 2>/dev/null; then WIN=$PA; LOSE=$PB; LERR="$T/b.err"; else WIN=$PB; LOSE=$PA; LERR="$T/a.err"; fi
bwait "$LOSE"; LRC=$?
{ [ "$LRC" = 9 ] && grep -q lost "$LERR"; } || [ "$LRC" = 2 ] && ok "R2 the loser: rc $LRC" || bad "R2 loser rc=$LRC err=$(cat "$LERR")"
kill -TERM "$WIN"; bwait "$WIN"; WRC=$?
[ "$WRC" = 143 ] && ok "R2 the winner hands off on TERM: rc 143" || bad "R2 winner rc=$WRC"

# ============================================================================
echo "R3: smoke through the entry point (AT5)"
mark
FAKE_DOCKER_SCRIPT=smoke runr mac-a smoke p1; RC=$?
RUNL=$(tail -n +"$((DOFF + 1))" "$T/docker.log" | grep -m1 '^run ')
[ "$RC" = 0 ] && [[ $(head -1 "$T/out") == "SMOKE_OK claude credential alive host=builder-p1" ]] && ok "R3 rc 0, stdout line 1 SMOKE_OK" || bad "R3 rc=$RC out=$(cat "$T/out") err=$(tail -5 "$T/err")"
miss=""
for w in '--platform linux/amd64' "$DOCKER_POOL_IMAGE" '-e POOL_MODE=1' '-e PROJECT=p1' '-e FLY_MACHINE_ID=dk-' '--hostname pool-p1-dk-' \
         ':/run/harness-env ' ':/run/harness ' ':/data ' '--label harness.docker-pool=1'; do
  [[ $RUNL == *"$w"* ]] || miss="$miss [$w]"
done
[ -z "$miss" ] && ok "R3 the docker run line carries platform, image, env, hostname, mounts, label" || bad "R3 run line misses$miss: $RUNL"
CID=$(ls -t "$T/fd/c" | head -1)
grep -q '^job {"key":"SMOKE","ticket_id":"0","attempt":0}' "$T/fd/c/$CID/seen" && ok "R3 job.json key SMOKE" || bad "R3 seen: $(cat "$T/fd/c/$CID/seen")"
[ "$(dk_n "^rm -f $CID")" = 1 ] && ok "R3 docker rm called" || bad "R3 no rm of $CID"
SW=$(ls -d "$T/dp/p1/SMOKE-dk-"* | head -1)
[ -n "$SW" ] && [ ! -e "$SW/env" ] && ok "R3 the env dir is gone" || bad "R3 env: $SW"
[ "$(srv_n '/api/docker-pool/')" = 0 ] && ok "R3 no docker-pool request" || bad "R3 srv: $(tail -n +"$((OFF + 1))" "$T/srv.log")"

# ============================================================================
echo "R4: a run to a RESULT, reaped and released done"
enqueue p1 D-4; mark
FAKE_DOCKER_SCRIPT=result FAKE_DOCKER_DELAY=3 runr mac-a run p1 D-4; RC=$?
W=$(work_of p1 D-4); CID=$(cid_of)
[ "$RC" = 0 ] && ok "R4 rc 0" || bad "R4 rc=$RC err=$(tail -8 "$T/err")"
[ -n "$CID" ] && [ "$(dk_n "^stop -t 60 $CID")" = 1 ] && ok "R4 docker stop -t 60" || bad "R4 stop: $(tail -n +"$((DOFF + 1))" "$T/docker.log")"
grep -q "^p1 D-4 $W/reap pool-p1-dk-" "$T/reap.log" && ok "R4 the C2 reap got <work>/reap and the cost box" || bad "R4 reap.log: $(cat "$T/reap.log") W=$W"
[ "$(tr '\n' ' ' < "$T/reap.ls.D-4" 2>/dev/null)" = "RESULT cost.csv job.json " ] && ok "R4 reap dir holds RESULT cost.csv job.json" || bad "R4 reap ls: $(cat "$T/reap.ls.D-4" 2>/dev/null)"
[ "$(leases p1 D-4 | jq -r '.[0].status')" = done ] && ok "R4 lease ended done" || bad "R4 lease: $(leases p1 D-4)"
runlog | grep -q 'docker-pool-runner: p1 D-4 done result=PR_CREATED reap=0 release=done:0' && ok "R4 finish log line" || bad "R4 log: $(runlog | tail -3)"
[ "$(srv_n 'heartbeat 200')" -ge 2 ] && ok "R4 >= 2 heartbeats" || bad "R4 heartbeats: $(srv_n 'heartbeat 200')"
CU=$(runlog | sed -n 's/.*p1 D-4 claimed .*lease_until=\([^ ]*\).*/\1/p' | tail -1)
LU=$(leases p1 D-4 | jq -r '.[0].lease_until')
[ -n "$CU" ] && [[ $LU > $CU ]] && ok "R4 the beats moved lease_until ($CU -> $LU)" || bad "R4 lease_until claim=$CU now=$LU"
[ -n "$W" ] && [ ! -e "$W/env" ] && [ ! -e "$W/data" ] && ok "R4 env and data dirs gone" || bad "R4 work: $(ls "$W" 2>&1)"
S="$T/fd/c/$CID/seen"
grep -qx builder-runner "$S" && grep -qx 'env global.env' "$S" && grep -qx 'env p1.env' "$S" && grep -qx 'env gh-token' "$S" && grep -qx harness-commit "$S" \
  && ok "R4 the container saw builder-runner, global.env, p1.env, gh-token, HARNESS_COMMIT" || bad "R4 seen: $(cat "$S" 2>/dev/null)"
! grep -q 'ghs-fixture-app-token\|ghp-fixture-pat-token\|tok-fixture-claude' "$T/docker.log" "$H/logs/docker-pool-runner.log" "$T/err" \
  && ok "R4 no token in docker argv, the runner log or stderr" || bad "R4 a token leaked"
grep -q '^expires_at=2099-01-01T00:00:00Z$' "$W/gh-token.state" && ok "R4 gh-token.state holds expires_at" || bad "R4 state: $(cat "$W/gh-token.state" 2>&1)"

# ============================================================================
echo "R5: TERM mid-build hands the row back (AT2)"
enqueue p1 D-5; mark
FAKE_DOCKER_SCRIPT=forever JOBS_BOX=mac-a bash "$H/bin/docker-pool-runner.sh" run p1 D-5 > "$T/out" 2> "$T/err" & PR=$!
wait_for '[ "$(srv_n "heartbeat 200")" -ge 2 ]' 100 || bad "R5 no 2 beats"
kill -TERM "$PR"; bwait "$PR"; RC=$?
[ "$RC" = 143 ] && ok "R5 rc 143" || bad "R5 rc=$RC err=$(tail -5 "$T/err")"
[ "$(dk_n '^stop ')" = 1 ] && ok "R5 docker stop called" || bad "R5 stops: $(dk_n '^stop ')"
[ "$(row p1 D-5 | jq -r .status)" = queued ] && [ "$(leases p1 D-5 | jq -r '.[0].status')" = released ] && ok "R5 row queued, lease released" || bad "R5 $(row p1 D-5) $(leases p1 D-5)"
W=$(work_of p1 D-5)
[ -n "$W" ] && [ ! -e "$W/env" ] && ok "R5 env gone" || bad "R5 env: $W"

# ============================================================================
echo "R6: the kill knob mid-build"
enqueue p1 D-6; mark; F0=$(fence_n)
FAKE_DOCKER_SCRIPT=forever JOBS_BOX=mac-a bash "$H/bin/docker-pool-runner.sh" run p1 D-6 > "$T/out" 2> "$T/err" & PR=$!
wait_for '[ "$(srv_n "heartbeat 200")" -ge 1 ]' 100 || bad "R6 no beat"
setting docker_pool.kill 1
bwait "$PR"; RC=$?
setting docker_pool.kill 0
[ "$RC" = 9 ] && ok "R6 rc 9" || bad "R6 rc=$RC err=$(tail -5 "$T/err")"
[ "$(dk_n '^stop ')" = 1 ] && ok "R6 the container is stopped" || bad "R6 stops: $(dk_n '^stop ')"
[ "$(fence_n)" = "$F0" ] && ok "R6 no ALERTS line" || bad "R6 alerts: $(fence_n)"
[ "$(row p1 D-6 | jq -r .status)" = queued ] && ok "R6 the worker put the row back" || bad "R6 row: $(row p1 D-6)"
runlog | grep -q 'p1 D-6 killed' && ok "R6 log says killed" || bad "R6 log: $(runlog | tail -3)"

# ============================================================================
echo "R7: the worker stops answering: the fence stops the container"
setting docker_pool.lease_s 60
enqueue p1 D-7; mark; F0=$(fence_n)
FAKE_DOCKER_SCRIPT=forever DOCKER_POOL_FENCE_S=57 JOBS_BOX=mac-a bash "$H/bin/docker-pool-runner.sh" run p1 D-7 > "$T/out" 2> "$T/err" & PR=$!
wait_for '[ "$(srv_n "heartbeat 200")" -ge 1 ]' 100 || bad "R7 no beat"
answer '{"status":500,"body":"{\"error\":\"fixture outage\"}"}'
bwait "$PR"; RC=$?
answer '{}'
setting docker_pool.lease_s 300
[ "$RC" = 9 ] && ok "R7 rc 9" || bad "R7 rc=$RC err=$(tail -5 "$T/err")"
[ "$(dk_n '^stop ')" = 1 ] && ok "R7 the container is stopped" || bad "R7 stops: $(dk_n '^stop ')"
runlog | grep -q 'p1 D-7 fenced' && ok "R7 outcome fenced" || bad "R7 log: $(runlog | tail -3)"
[ "$(fence_n)" = $((F0 + 1)) ] && grep -q 'DOCKER POOL FENCE p1 D-7' "$H/logs/ALERTS.log" && ok "R7 exactly one DOCKER POOL FENCE line" || bad "R7 alerts: $(fence_n) vs $F0"

# ============================================================================
echo "R8: the container exits with no RESULT"
enqueue p1 D-8; mark
FAKE_DOCKER_SCRIPT=noresult FAKE_DOCKER_DELAY=2 runr mac-a run p1 D-8; RC=$?
[ "$RC" = 1 ] && ok "R8 rc 1" || bad "R8 rc=$RC err=$(tail -5 "$T/err")"
[ "$(row p1 D-8 | jq -r .status)" = queued ] && [ "$(leases p1 D-8 | jq -r '.[0].status')" = released ] && ok "R8 released queued, row queued" || bad "R8 $(row p1 D-8) $(leases p1 D-8)"
runlog | grep -q 'p1 D-8 exited result=- reap=absent release=queued:0' && ok "R8 finish line" || bad "R8 log: $(runlog | tail -3)"

# ============================================================================
echo "R9: the hold gate"
n=0
for v in $'held\thold:comment HOLD' $'held\tlabel-absent' $'unreadable\tAPI rate limit exceeded'; do
  n=$((n + 1)); K="H-$n"
  lib mac-a "queue_put p1 $K 0123 fly >/dev/null"
  printf '%s\n' "$v" > "$T/hold.verdict"; mark
  FAKE_DOCKER_SCRIPT=result runr mac-a run p1 "$K"; RC=$?
  [ "$RC" = 9 ] && [ "$(dk_n '^run ')" = 0 ] && ok "R9 ${v%%$'\t'*} ${v#*$'\t'}: rc 9, no docker run" || bad "R9 $v rc=$RC runs=$(dk_n '^run ') err=$(tail -3 "$T/err")"
  [ "$(row p1 "$K" | jq -r .status)" = queued ] && [ "$(leases p1 "$K" | jq -r '.[0].status')" = released ] && ok "R9 $K row queued, lease released" || bad "R9 $K $(row p1 "$K") $(leases p1 "$K")"
done
grep -q '^example-org/p1-repo 0123 token=set$' "$T/hold.log" && ok "R9 hold_check got the slug, the numeric ticket and the minted token" || bad "R9 hold.log: $(cat "$T/hold.log")"
printf 'clear\tno-hold\n' > "$T/hold.verdict"
lib mac-a "queue_put p1 H-4 0124 fly >/dev/null"; mark
FAKE_DOCKER_SCRIPT=result runr mac-a run p1 H-4; RC=$?
[ "$RC" = 0 ] && [ "$(dk_n '^run ')" = 1 ] && ok "R9 clear no-hold: one container, rc 0" || bad "R9 clear rc=$RC runs=$(dk_n '^run ') err=$(tail -3 "$T/err")"
printf 'unreadable\tmust not be read\n' > "$T/hold.verdict"; HL=$(wc -l < "$T/hold.log")
lib mac-a "queue_put p1 H-5 cmabc123 fly >/dev/null"; mark
FAKE_DOCKER_SCRIPT=result runr mac-a run p1 H-5; RC=$?
[ "$RC" = 0 ] && [ "$(dk_n '^run ')" = 1 ] && [ "$(wc -l < "$T/hold.log")" = "$HL" ] && ok "R9 a board ticket id: no hold read, one container" || bad "R9 board rc=$RC runs=$(dk_n '^run ')"

# ============================================================================
echo "R10: key acceptance"
mark
for k in RB-7300-abcdef12 SMOKE 'BH-1;rm' ''; do
  runr mac-a run p1 "$k"; RC=$?
  [ "$RC" = 1 ] && ok "R10 key '$k': rc 1" || bad "R10 key '$k' rc=$RC"
done
[ "$(srv_n ' ')" = 0 ] && [ "$(dk_n '^run ')" = 0 ] && ok "R10 no request and no docker run for a refused key" || bad "R10 srv: $(tail -n +"$((OFF + 1))" "$T/srv.log")"
enqueue p1 L-1 local; mark
runr mac-a run p1 NOPE-1; R1C=$?
runr mac-a run p1 L-1; R2C=$?
[ "$R1C$R2C" = 22 ] && [ "$(srv_n '/api/docker-pool/claim')" = 0 ] && ok "R10 unqueued and local-target keys: rc 2, no claim" || bad "R10 rc=$R1C/$R2C claims=$(srv_n claim)"

# ============================================================================
echo "R11: reap-orphans stops only labeled containers past their lease"
FW=$(work_of p1 D-4)
mkc() { mkdir -p "$T/fd/c/$1"; echo running > "$T/fd/c/$1/state"; printf '%s' "$2" > "$T/fd/c/$1/labels"; }
printf '%s\n' 1000 > "$T/stale.lease"
# the fresh one is a lease file a real beat wrote, pushed ahead
printf '%s\n' "$(( $(cat "$FW/lease") + 86400 ))" > "$FW/lease"
mkc fdaaaaaaaaa1 $'harness.docker-pool=1\nharness.docker-pool.lease='"$T/stale.lease"$'\n'
mkc fdaaaaaaaaa2 $'harness.docker-pool=1\nharness.docker-pool.lease='"$FW/lease"$'\n'
mkc fdaaaaaaaaa3 $'harness.docker-pool=1\nharness.docker-pool.lease='"$T/no-such.lease"$'\n'
mkc fdaaaaaaaaa4 $'com.example.other=1\n'
mark
runr mac-a reap-orphans; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "2 1" ] && ok "R11 prints '2 1'" || bad "R11 rc=$RC out=$(cat "$T/out") err=$(tail -3 "$T/err")"
[ "$(dk_n 'stop .*fdaaaaaaaaa1')" = 1 ] && [ "$(dk_n 'stop .*fdaaaaaaaaa3')" = 1 ] && [ "$(dk_n 'fdaaaaaaaaa2')" = 0 ] && [ "$(dk_n 'fdaaaaaaaaa4')" = 0 ] \
  && ok "R11 stopped the stale and lease-less ones, kept the fresh and the unlabeled" || bad "R11 docker: $(tail -n +"$((DOFF + 1))" "$T/docker.log")"

# ============================================================================
echo "R13: RESULT before the done line"
enqueue p1 D-13; mark
FAKE_DOCKER_SCRIPT=late FAKE_DOCKER_LATE_S=4 runr mac-a run p1 D-13; RC=$?
W=$(work_of p1 D-13)
[ "$RC" = 0 ] && ok "R13 rc 0" || bad "R13 rc=$RC err=$(tail -5 "$T/err")"
[ "$(srv_n 'heartbeat 200')" -ge 2 ] && [ "$(dk_n '^stop ')" = 1 ] && ok "R13 >= 2 beats with RESULT before the stop" || bad "R13 beats=$(srv_n 'heartbeat 200') stops=$(dk_n '^stop ')"
grep -q "^example-org/p1-repo $W/env $W/gh-token.state$" "$T/rotate.log" && ok "R13 the C2 rotate got the slug, <work>/env and the state file" || bad "R13 rotate.log: $(tail -2 "$T/rotate.log")"
grep -q '^expires_at=' "$W/gh-token.state" && ok "R13 the state file holds expires_at=" || bad "R13 state file"

# ============================================================================
echo "R14: the lease expires and is swept mid-build"
enqueue p1 D-14; mark; F0=$(fence_n)
FAKE_DOCKER_SCRIPT=forever DOCKER_POOL_BEAT_S=2 JOBS_BOX=mac-a bash "$H/bin/docker-pool-runner.sh" run p1 D-14 > "$T/out" 2> "$T/err" & PR=$!
wait_for '[ "$(srv_n "heartbeat 200")" -ge 1 ]' 100 || bad "R14 no beat"
expire p1 D-14
lib hub-fixture 'docker_pool_sweep' || bad "R14 sweep rc"
bwait "$PR"; RC=$?
[ "$RC" = 9 ] && grep -q 'refused' "$T/err" && ok "R14 rc 9 on the lost heartbeat" || bad "R14 rc=$RC err=$(tail -5 "$T/err")"
[ "$(dk_n '^stop ')" = 1 ] && ok "R14 the container is stopped" || bad "R14 stops: $(dk_n '^stop ')"
[ "$(fence_n)" = $((F0 + 1)) ] && ok "R14 exactly one ALERTS line" || bad "R14 alerts: $(fence_n) vs $F0"
[ "$(srv_n '/api/docker-pool/release')" = 0 ] && ok "R14 no release request" || bad "R14 releases: $(srv_n release)"
runlog | grep -q 'p1 D-14 lost' && ok "R14 log says lost" || bad "R14 log: $(runlog | tail -3)"

# ============================================================================
echo "R12: the done-line string and the knob reads (last: a settings row wins over env)"
grep -q 'job cycle complete' "$DIR/fly/builder-runner.sh" && grep -q 'job cycle complete' "$FAKE" && grep -q 'job cycle complete' "$HOSTLIB" \
  && ok "R12 'job cycle complete' is in the writer, the stub and the reader" || bad "R12 the done-line string drifted"
KN=". '$H/bin/jobs-client.sh' && . '$H/bin/lib/docker-pool-host.sh' && dph_knob DOCKER_POOL_BEAT_S"
V=$(env -u DOCKER_POOL_BEAT_S JOBS_BOX=mac-a bash -c "$KN" 2>/dev/null)
[ "$V" = 60 ] && ok "R12 the registry default is 60 with no row" || bad "R12 default: '$V'"
setting lib.docker-pool-host.docker_pool_beat_s 45
V=$(JOBS_BOX=mac-a bash -c "$KN" 2>/dev/null)
[ "$V" = 45 ] && ok "R12 a settings row wins: 45" || bad "R12 settings: '$V'"
V=$(env -u DOCKER_POOL_BEAT_S DOCKER_POOL_STOP_S=abc JOBS_BOX=mac-a bash -c ". '$H/bin/jobs-client.sh' && . '$H/bin/lib/docker-pool-host.sh' && dph_knob DOCKER_POOL_STOP_S" 2>/dev/null)
[ "$V" = 60 ] && ok "R12 an invalid value is its default" || bad "R12 invalid: '$V'"

echo "pass=$PASS fail=$FAIL"
echo "FAIL $FAIL"
[ "$FAIL" = 0 ]
