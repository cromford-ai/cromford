#!/bin/bash
# tests/fly-pool-warmup.bh-7215-test.sh — BH-7215: pool machines exit before
# the hub pushes the job.
#
# The cause (#7174, machine 806d29f69d1038): the builder waited a fixed 600 s
# for job.json, and spawn_one ran `fly machine run` FIRST and its slow setup
# (App token, account lease, OpenRouter check, overlay) AFTER it. On
# project-6-os that setup took about 12 minutes, so the machine had already
# exited when the first push came.
#
# PINNED:
#   R1-R3  fly/builder-runner.sh's warmup wait reads WARMUP_WAIT_S (the REAL
#          block, lifted by its markers), default 1800.
#   K1-K5  the knob reaches the machine env: `-e WARMUP_WAIT_S=<n>` on the
#          recorded `machine run`; the registry carries both new knobs.
#   O1-O4  DRIVEN (`bash bin/fly-pool.sh project-5` against a scratch $HARNESS):
#          a 700 s setup against a machine that stops 600 s after start fails
#          the push on the old order and lands on the new one; setup runs
#          before `machine run`; the no-credential exit spawns nothing; a
#          launch with no id releases the pre-launch lease.
#   A1-A5  pool_account_rebind (the REAL function) moves the lease.
#   L1-L4  DRIVEN: rebind after launch, release on a sync failure, the moved
#          gh-token-read push, no secret dir left.
#   W1-W9  pool_warmup_note (the REAL block): the log line every spawn, one
#          alert per project per day over POOL_WARMUP_ALERT_PCT.
# Run from anywhere: bash tests/fly-pool-warmup.bh-7215-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ══ R: the runner's warmup wait ═════════════════════════════════════════════
RUN="$DIR/fly/builder-runner.sh"
RBLOCK=$(sed -n '/^# >>> warmup wait (BH-7215)/,/^# <<< warmup wait/p' "$RUN")
RASSIGN=$(grep -E '^WARMUP_WAIT=|^case "\$WARMUP_WAIT"' "$RUN")
[ -n "$RBLOCK" ] && ok || bad "R0: the '# >>> warmup wait (BH-7215)' block is not in fly/builder-runner.sh"
grep -q 'WARMUP_WAIT_S' <<<"$RASSIGN" && ok || bad "R0: WARMUP_WAIT is not read from WARMUP_WAIT_S: $RASSIGN"
cat > "$T/rwait.sh" <<EOF
log() { echo "runner: \$*" >> "$T/runner.log"; }
JOB="\$1" ENVDIR="$T/renv" POLL=1
$RASSIGN
$RBLOCK
echo REACHED
EOF
mkdir -p "$T/renv"
# R1: no job within WARMUP_WAIT_S=5 -> exit 0 after about 5 s. `timeout 20`: a
# runner that ignores WARMUP_WAIT_S fails here in 20 s, not after its own wait.
: > "$T/runner.log"; rm -f "$T/job.json"
S0=$(date +%s)
ROUT=$(timeout 20 env -i PATH="$PATH" WARMUP_WAIT_S=5 bash "$T/rwait.sh" "$T/job.json"); RRC=$?
EL=$(( $(date +%s) - S0 ))
[ "$RRC" = 0 ] && ok || bad "R1: rc must be 0, got $RRC"
[ "$ROUT" != REACHED ] && ok || bad "R1: with no job the runner must exit, not go on"
[ "$EL" -ge 4 ] && [ "$EL" -le 8 ] && ok || bad "R1: the wait must last about 5 s, got ${EL}s"
grep -q 'no job pushed within 5s' "$T/runner.log" && ok || bad "R1: the log must say 'no job pushed within 5s': $(cat "$T/runner.log")"
# R2: the job arrives after 2 s -> the loop ends early and goes on.
: > "$T/runner.log"; rm -f "$T/job.json"
( /bin/sleep 2; echo '{}' > "$T/job.json" ) &
S0=$(date +%s)
ROUT=$(timeout 20 env -i PATH="$PATH" WARMUP_WAIT_S=30 bash "$T/rwait.sh" "$T/job.json")
EL=$(( $(date +%s) - S0 )); wait
[ "$ROUT" = REACHED ] && ok || bad "R2: a pushed job must end the wait, got '$ROUT'"
[ "$EL" -lt 5 ] && ok || bad "R2: the wait must end in under 5 s, took ${EL}s"
# R3: a bad, zero or unset value is 1800.
for V in abc 0 UNSET 5; do
  if [ "$V" = UNSET ]; then
    GOT=$(env -i PATH="$PATH" bash -c "$RASSIGN"$'\n''echo "$WARMUP_WAIT"')
  else
    GOT=$(env -i PATH="$PATH" WARMUP_WAIT_S="$V" bash -c "$RASSIGN"$'\n''echo "$WARMUP_WAIT"')
  fi
  WANT=1800; [ "$V" = 5 ] && WANT=5
  [ "$GOT" = "$WANT" ] && ok || bad "R3: WARMUP_WAIT_S=$V must give WARMUP_WAIT=$WANT, got '$GOT'"
done

# ══ K4: the registry carries both knobs ═════════════════════════════════════
mkdir -p "$T/reg/catalog"
cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/"
bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 || bad "K4: lanes-build.sh --write failed on a scratch copy"
REG="$T/reg/catalog/lanes.json"
kdef() { jq -r --arg e "$1" '.lanes[]? | select(.id=="fly-pool") | .knobs[]? | select(.env==$e) | .default' "$REG" 2>/dev/null; }
[ "$(kdef WARMUP_WAIT_S)" = 1800 ] && ok || bad "K4: fly-pool knob WARMUP_WAIT_S default must be 1800, got '$(kdef WARMUP_WAIT_S)'"
[ "$(kdef POOL_WARMUP_ALERT_PCT)" = 80 ] && ok || bad "K4: fly-pool knob POOL_WARMUP_ALERT_PCT default must be 80, got '$(kdef POOL_WARMUP_ALERT_PCT)'"
SK=$(env -i PATH="$PATH" bash -c '. "$1/bin/lib/lane-gate.sh" 2>/dev/null; _lg_setting_key fly-pool WARMUP_WAIT_S project-6-os' _ "$DIR")
[ "$SK" = lane.fly-pool.project-6-os.warmup_wait_s ] && ok || bad "K4: the settings key must be lane.fly-pool.project-6-os.warmup_wait_s, got '$SK'"

# ══ the driven pool (scaffold of tests/fly-pool-bundle-before-spawn.bh-4859) ═
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

# The account lib stub, installed BEFORE the closure so the closure keeps it.
# The lease is the slow setup step: it advances the virtual clock by SETUP_COST.
cat > "$H/bin/lib/pool-account.sh" <<'PA'
#!/bin/bash
_clk() { cat "$CLOCK"; }
pool_account_lease() {
  echo "lease $4" >> "$ORDER"
  echo "$(( $(_clk) + ${SETUP_COST:-0} ))" > "$CLOCK"
  if [ -n "${PA_NAME:-}" ]; then echo "name=$PA_NAME reason=lease_rank leases=1 five_h=10"
  else echo "name=default reason=unarmed"; fi
}
pool_account_rebind() { echo "rebind $*" >> "$ORDER"; return 0; }
pool_account_release() { echo "release $*" >> "$ORDER"; return 0; }
pool_account_others_ok() { return 1; }
pool_account_prune() { :; }
pool_account_armed() { return 1; }
pool_account_cooldown() { :; }
pool_account_unpin() { :; }
PA
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$H/bin/fly-envbundle.sh" <<'EB'
#!/bin/bash
mkdir -p "$2"; : > "$2/global.env"; printf 'REPO_SLUG=example-org/project-5\n' > "$2/$1.env"
printf '%s\n' "${EB_MARK:-}" > "$2/.bh7215-marker"
[ "${EB_PAT:-1}" = 1 ] && printf 'GH_TOKEN=pat-fixture\n' >> "$2/global.env"
exit 0
EB
cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in -d|-D) DEC=1 ;; -w0|-w) W0=1 ;; 0|-*) ;; *) FILE="$a" ;; esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0); fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
# Fly stub on the virtual clock: `machine run` stamps the start; every
# ssh console / sftp after STOP_AFTER seconds of it fails, as on a stopped
# machine. FLY_SFTP_FAIL fails the harness sync, FLY_NOMID prints no id,
# READPUT_FAIL fails the gh-token-read push, ENVPUT_FAIL the global.env push.
cat > "$T/fakebin/fly" <<'FLY'
#!/bin/bash
echo "fly $*" >> "${FLY_SINK:-/dev/null}"
stopped() {
  [ -s "$T_START" ] || return 1
  [ $(( $(cat "$CLOCK") - $(cat "$T_START") )) -gt "${STOP_AFTER:-999999}" ]
}
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh sftp put"*) echo sftp >> "$ORDER"; stopped && exit 1; [ "${FLY_SFTP_FAIL:-0}" = 1 ] && exit 1 ;;
  *"ssh console"*)
    P=$(printf '%s' "$*" | grep -oE '/run/harness-env/[A-Za-z0-9._-]+|/run/harness/job\.json' | tail -1)
    [ -n "$P" ] && echo "put $P" >> "$ORDER"
    stopped && exit 1
    case "$P" in
      */gh-token-read) [ "${READPUT_FAIL:-0}" = 1 ] && exit 1 ;;
      */global.env) [ "${ENVPUT_FAIL:-0}" = 1 ] && exit 1 ;;
    esac ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*)
    echo run >> "$ORDER"; cat "$CLOCK" > "$T_START"
    [ "${FLY_NOMID:-0}" = 1 ] || printf 'Machine ID: 1234567890abcd\n' ;;
esac
exit 0
FLY
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" == *"issues/1"* ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'; exit 0
fi
if [[ "$*" == *"-i"* ]]; then
  if [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0
  fi
  if [[ "$*" == *"git/ref/heads/ticket/bh-1"* ]]; then printf 'HTTP/1.1 200 OK\n\n{}\n'; exit 0; fi
  if [[ "$*" == *"pulls?state=open"*"head="* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
exit 0
GH
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
printf '{}\n404\n'
STUB
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

CLOCK="$T/clock"; ORDER="$T/order.txt"; T_START="$T/mstart"
QF="$H/state/build-queue/project-5/BH-1.json"
POOLD="$H/state/fly-pool/project-5"
EB_MARK="bh7215-$$-$(date +%s)"
run_pool() { # run_pool [VAR=val ...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=hub \
           JOBS_RETRIES=0 JOBS_TIMEOUT=5 FLY_SINK="$T/fly.txt" EB_MARK="$EB_MARK" \
           CLOCK="$CLOCK" ORDER="$ORDER" T_START="$T_START" \
           FLY_API_TOKEN_project-5=tok FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
reset_case() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json "$POOLD"/*.json "$POOLD"/.??* "$H/state/pool/project-5"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  echo 100000 > "$CLOCK"; : > "$T_START"; : > "$ORDER"; : > "$T/fly.txt"
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  [ -e "$H/env/github-app.env" ] && scratch_rm "$H/env/github-app.env"
  [ -e "$H/bin/gh-token.sh" ] && scratch_rm "$H/bin/gh-token.sh"
  jq -nc '{ticket_id:"1",key:"BH-1",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-17T00:00:00Z"}' > "$QF"
  return 0
}
log() { cat "$H/logs/fly-pool.log" 2>/dev/null; }
runline() { grep 'machine run' "$T/fly.txt" | head -1; }
# lineno <regex> -> the first line of $ORDER that matches, or 0
lineno() { local n; n=$(grep -nE "$1" "$ORDER" | head -1 | cut -d: -f1); echo "${n:-0}"; }
leftover_bundles() {
  local d n=0
  for d in /dev/shm/pool.*; do
    [ -f "$d/.bh7215-marker" ] && grep -qx "$EB_MARK" "$d/.bh7215-marker" 2>/dev/null && n=$((n+1))
  done
  echo "$n"
}
# arm_app <mint-answer> — App tokens armed; the stub mint records its call.
arm_app() {
  printf 'GH_APP_ID=1\n' > "$H/env/github-app.env"
  cat > "$H/bin/gh-token.sh" <<EOF
#!/bin/bash
echo "mint \$*" >> "$ORDER"
case " \$* " in
  *" --installation-id "*) echo 4242 ;;
  *" --expires-at "*) [ -n "$1" ] && echo 2026-10-17T05:00:00Z ;;
  *" --extra-read "*) [ -n "$1" ] && echo tok-fixture-read ;;
  *) [ -n "$1" ] && echo "$1" ;;
esac
[ -n "$1" ]
EOF
  chmod +x "$H/bin/gh-token.sh"
}

# ══ O1: the incident: setup 700 s, the machine stops 600 s after start ══════
reset_case
run_pool SETUP_COST=700 STOP_AFTER=600
grep -q 'env/job push FAILED' "$H/logs/fly-pool.log" && bad "O1: a 700 s setup must not fail the push any more: $(log)" || ok
grep -q 'spawned 1234567890abcd for BH-1' "$H/logs/fly-pool.log" && ok || bad "O1: the spawn must land: $(log)"
[ -f "$POOLD/1234567890abcd.json" ] && ok || bad "O1: the machine json must be written"

# ══ O2: the order: lease and mint before the launch, pushes after ═══════════
reset_case
arm_app tok-fixture-app
run_pool
L=$(lineno '^lease '); M=$(lineno '^mint '); R=$(lineno '^run$'); S=$(lineno '^sftp$')
G=$(lineno 'put /run/harness-env/global.env'); J=$(lineno 'put /run/harness/job.json')
[ "$L" -gt 0 ] && [ "$L" -lt "$R" ] && ok || bad "O2: the lease must run before machine run: $(tr '\n' '|' < "$ORDER")"
[ "$M" -gt 0 ] && [ "$M" -lt "$R" ] && ok || bad "O2: the App mint must run before machine run: $(tr '\n' '|' < "$ORDER")"
[ "$R" -gt 0 ] && [ "$R" -lt "$S" ] && [ "$S" -lt "$G" ] && [ "$G" -lt "$J" ] && ok \
  || bad "O2: after the launch: sftp, then global.env, then job.json: $(tr '\n' '|' < "$ORDER")"
grep -q 'BH-1 gets a repo-scoped App token for example-org/project-5 from the' "$H/logs/fly-pool.log" && ok \
  || bad "O2: the swap line names the key (no machine yet): $(log)"
grep -q 'BH-1: setup before launch took [0-9]*s' "$H/logs/fly-pool.log" && ok || bad "O2: the setup time must be logged: $(log)"
grep -q 'put /run/harness-env/gh-token$' "$ORDER" && ok || bad "O2: the App token file must still be pushed"

# ══ O3: no credential: no machine at all ════════════════════════════════════
reset_case
arm_app ""
run_pool EB_PAT=0
grep -q 'machine run' "$T/fly.txt" && bad "O3: no credential must buy no machine: $(cat "$T/fly.txt")" || ok
grep -q 'machine destroy' "$T/fly.txt" && bad "O3: nothing to destroy" || ok
[ -f "$QF" ] && ok || bad "O3: the queue file must stay"
grep -q 'no machine spawned, job stays queued' "$H/logs/fly-pool.log" && ok || bad "O3: the log must say no machine spawned: $(log)"
[ "$(leftover_bundles)" = 0 ] && ok || bad "O3: the bundle dir (secrets) survived the no-credential exit"
[ ! -s "$H/state/pool/project-5/BH-1.spawns" ] && ok || bad "O3: the cap slot must be given back: $(cat "$H/state/pool/project-5/BH-1.spawns")"

# ══ O4: machine run gave no id: the pre-launch lease is released ════════════
reset_case
run_pool FLY_NOMID=1 PA_NAME=max3
grep -qE '^release pre-BH-1-[0-9]+-[0-9]+$' "$ORDER" && ok || bad "O4: the pre-launch lease id must be released: $(tr '\n' '|' < "$ORDER")"
grep -q '^release 1234567890abcd' "$ORDER" && bad "O4: there is no machine id to release" || ok
[ "$(leftover_bundles)" = 0 ] && ok || bad "O4: the bundle dir survived a machine-run failure"

# ══ K1-K3: the wait reaches the machine env ═════════════════════════════════
for KV in 2400:2400 UNSET:1800 abc:1800; do
  V="${KV%%:*}"; WANT="${KV##*:}"
  reset_case
  if [ "$V" = UNSET ]; then run_pool; else run_pool WARMUP_WAIT_S="$V"; fi
  runline | grep -q -- "-e WARMUP_WAIT_S=$WANT\( \|$\)" && ok || bad "K($V): machine run must carry -e WARMUP_WAIT_S=$WANT: $(runline)"
done
# K5: from the settings row, through lane_env_apply.
reset_case
jq -n --argjson fa "$(date -u +%s)" '{fetched_at:$fa,values:{"lane.fly-pool.project-5.warmup_wait_s":"2700"},seeded:{}}' > "$H/state/settings-cache.json"
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '-e WARMUP_WAIT_S=2700' && ok || bad "K5: the row lane.fly-pool.project-5.warmup_wait_s=2700 must reach machine run: $(runline) / $(log)"
scratch_rm "$H/state/settings-cache.json"

# ══ L1: the lease moves to the machine id after the launch ══════════════════
reset_case
run_pool PA_NAME=max3
grep -qE '^lease pre-BH-1-[0-9]+-[0-9]+$' "$ORDER" && ok || bad "L1: the lease must take a pre-launch id: $(tr '\n' '|' < "$ORDER")"
grep -qE '^rebind pre-BH-1-[0-9]+-[0-9]+ 1234567890abcd max3 project-5 BH-1$' "$ORDER" && ok \
  || bad "L1: pool_account_rebind must move the lease to the machine id: $(tr '\n' '|' < "$ORDER")"
[ "$(lineno '^run$')" -lt "$(lineno '^rebind ')" ] && ok || bad "L1: the rebind comes after machine run"
[ "$(jq -r '.auth_account // ""' "$POOLD/1234567890abcd.json" 2>/dev/null)" = max3 ] && ok || bad "L1: the machine json must carry auth_account max3"
# The unarmed lease (default) is never rebound.
reset_case
run_pool
grep -q '^rebind' "$ORDER" && bad "L1: no account leased, no rebind: $(tr '\n' '|' < "$ORDER")" || ok

# ══ L2: harness sync failed after the lease: the lease is released ══════════
reset_case
run_pool FLY_SFTP_FAIL=1 PA_NAME=max3
grep -q 'harness sync FAILED' "$H/logs/fly-pool.log" && ok || bad "L2 precondition: sync failure not reached: $(log)"
grep -q '^release 1234567890abcd$' "$ORDER" && ok || bad "L2: the lease must be released by machine id: $(tr '\n' '|' < "$ORDER")"
[ "$(leftover_bundles)" = 0 ] && ok || bad "L2: the bundle dir survived a sync failure"

# ══ L3: the read token is pushed in the push phase; a failure is said ═══════
reset_case
arm_app tok-fixture-app
run_pool EXTRA_READ_REPOS=example-org/OtherRepo READPUT_FAIL=1
grep -q 'gh-token-read push FAILED' "$H/logs/fly-pool.log" && ok || bad "L3: a failed read push must be said: $(log)"
grep -q 'spawned 1234567890abcd for BH-1' "$H/logs/fly-pool.log" && ok || bad "L3: the spawn must go ahead: $(log)"
RD=$(lineno 'put /run/harness-env/gh-token-read'); S=$(lineno '^sftp$'); G=$(lineno 'put /run/harness-env/global.env')
[ "$RD" -gt "$S" ] && [ "$RD" -lt "$G" ] && ok || bad "L3: the read push comes after the sftp and before global.env: $(tr '\n' '|' < "$ORDER")"
grep -q 'BH-1 gets a read-only token for the extra repos of example-org/project-5 (example-org/OtherRepo; left out: none)' "$H/logs/fly-pool.log" \
  && ok || bad "L3: the read token line must name the key and repos: $(log)"

# ══ L4: a normal spawn leaves no secret dir ═════════════════════════════════
reset_case
arm_app tok-fixture-app
run_pool PA_NAME=max3
[ "$(leftover_bundles)" = 0 ] && ok || bad "L4: the bundle dir (secrets) survived a good spawn"

# ══ W9: exactly one launch→first push line per spawn ════════════════════════
reset_case
run_pool
N=$(grep -cE '1234567890abcd: launch→first push [0-9]+s \(warmup wait 1800s\)' "$H/logs/fly-pool.log")
[ "$N" = 1 ] && ok || bad "W9: one launch→first push line per spawn, got $N: $(log)"
# On a failed push too (the incident shape on a slow machine).
reset_case
run_pool ENVPUT_FAIL=1
grep -q 'env/job push FAILED' "$H/logs/fly-pool.log" && ok || bad "W9 precondition: the push must fail: $(log)"
grep -qE '1234567890abcd: launch→first push [0-9]+s' "$H/logs/fly-pool.log" && ok || bad "W9: a failed push still logs the line: $(log)"

# ══ A1-A5: pool_account_rebind (the real function) ══════════════════════════
HA="$T/ha"; mkdir -p "$HA/state/quota/leases/max3" "$HA/bin/lib"
rb() { # rb [VAR=val ...] -- <args>; calls in $T/rb.calls; prints rc
  local envs=() a
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env -i PATH="$PATH" HARNESS="$HA" RBC="$T/rb.calls" ${envs[@]+"${envs[@]}"} bash -c '
    . "$1/bin/lib/pool-account.sh" 2>/dev/null; shift
    if [ "${STUB_DB:-}" != "" ]; then
      account_lease_claim() { echo "claim $*" >> "$RBC"; return "$STUB_DB"; }
      account_lease_release() { echo "release $*" >> "$RBC"; return 0; }
    fi
    pool_account_rebind "$@"; echo "rc=$?"
    [ -n "${COUNT:-}" ] && echo "count=$(pool_account_leases "$COUNT")"
    [ -n "${FREE:-}" ] && { pool_account_release "$FREE"; echo "after=$(pool_account_leases max3)"; }
    true' _ "$DIR" "$@"
}
# A1: files only.
: > "$T/rb.calls"; echo '{}' > "$HA/state/quota/leases/max3/pre-X"
OUT=$(rb POOL_ACCOUNT_DB_LEASES=0 COUNT=max3 FREE=m1 -- pre-X m1 max3 project-5 BH-1)
grep -q '^rc=0$' <<<"$OUT" && ok || bad "A1: rc 0, got: $OUT"
grep -q '^count=1$' <<<"$OUT" && ok || bad "A1: the account still counts one lease after the move, got: $OUT"
grep -q '^after=0$' <<<"$OUT" && ok || bad "A1: release by the machine id must free it, got: $OUT"
[ ! -e "$HA/state/quota/leases/max3/pre-X" ] && ok || bad "A1: the pre-launch file must be gone"
# A2: the shared row, claim answers 0.
: > "$T/rb.calls"; echo '{}' > "$HA/state/quota/leases/max3/pre-X"
OUT=$(rb STUB_DB=0 -- pre-X m1 max3 project-5 BH-1)
grep -q '^rc=0$' <<<"$OUT" && ok || bad "A2: rc 0, got: $OUT"
grep -qE '^claim max3 m1 project-5 BH-1 0 [0-9]+$' "$T/rb.calls" && ok || bad "A2: the claim must be for m1 with cap 0: $(cat "$T/rb.calls")"
grep -qx 'release pre-X max3' "$T/rb.calls" && ok || bad "A2: the old row must be released after the claim: $(cat "$T/rb.calls")"
[ "$(grep -n '^claim' "$T/rb.calls" | cut -d: -f1)" -lt "$(grep -n '^release' "$T/rb.calls" | cut -d: -f1)" ] && ok || bad "A2: claim before release"
[ -f "$HA/state/quota/leases/max3/m1" ] && ok || bad "A2: the lease file must move to m1"
# A3: the claim does not answer 0: the old row stays.
: > "$T/rb.calls"; rm -f "$HA/state/quota/leases/max3/"*; echo '{}' > "$HA/state/quota/leases/max3/pre-X"
OUT=$(rb STUB_DB=2 -- pre-X m1 max3 project-5 BH-1)
grep -q '^rc=1$' <<<"$OUT" && ok || bad "A3: rc 1 when the new claim failed, got: $OUT"
grep -q '^release' "$T/rb.calls" && bad "A3: the old row must not be released: $(cat "$T/rb.calls")" || ok
# A4: no account: nothing.
: > "$T/rb.calls"; rm -f "$HA/state/quota/leases/max3/"*; echo '{}' > "$HA/state/quota/leases/max3/pre-X"
OUT=$(rb STUB_DB=0 -- pre-X m1 "" project-5 BH-1)
grep -q '^rc=0$' <<<"$OUT" && ok || bad "A4: rc 0, got: $OUT"
[ ! -s "$T/rb.calls" ] && [ -f "$HA/state/quota/leases/max3/pre-X" ] && ok || bad "A4: no account, nothing moves: $(cat "$T/rb.calls")"
# A5: an id with a slash: nothing.
OUT=$(rb STUB_DB=0 -- pre-X ../m1 max3 project-5 BH-1)
grep -q '^rc=0$' <<<"$OUT" && ok || bad "A5: rc 0, got: $OUT"
[ ! -s "$T/rb.calls" ] && [ -f "$HA/state/quota/leases/max3/pre-X" ] && [ ! -e "$HA/state/quota/leases/m1" ] && ok \
  || bad "A5: a bad id moves nothing: $(cat "$T/rb.calls")"

# ══ W1-W8: pool_warmup_note (the real block) ════════════════════════════════
WBLOCK=$(sed -n '/^# >>> warmup note (BH-7215)/,/^# <<< warmup note/p' "$DIR/bin/fly-pool.sh")
[ -n "$WBLOCK" ] && ok || bad "W0: the '# >>> warmup note (BH-7215)' block is not in bin/fly-pool.sh"
HW="$T/hw"; mkdir -p "$HW/bin" "$HW/flags"
# The day flag goes through bin/lib/flags.sh, which loads bin/jobs-client.sh:
# give the scratch harness the real ones.
for c in bin/lib/flags.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$c" "$HW" ) >/dev/null || { echo "setup: closure $c"; exit 1; }
done
cat > "$HW/bin/alert-line.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/w.alerts"
EOF
chmod +x "$HW/bin/alert-line.sh"
cat > "$T/wnote.sh" <<EOF
HARNESS="$HW" P=project-5
say() { echo "\$*" >> "$T/w.log"; }
$WBLOCK
pool_warmup_note "\$@"
EOF
wn() { env -i PATH="$PATH" ${PCT:+POOL_WARMUP_ALERT_PCT=$PCT} bash "$T/wnote.sh" "$@"; }
for SA in 0:0 1439:0 1440:0 1441:1 1800:1 5000:1 5000off:0; do
  S="${SA%%:*}"; WA="${SA##*:}"; PCT=""
  case "$S" in *off) S="${S%off}"; PCT=0 ;; esac
  rm -f "$HW/flags"/alerted-pool-warmup-*; : > "$T/w.log"; : > "$T/w.alerts"
  wn m1 BH-1 1000 "$((1000 + S))" 1800
  grep -qx "m1: launch→first push ${S}s (warmup wait 1800s)" "$T/w.log" && ok || bad "W(S=$S): the log line, got: $(cat "$T/w.log")"
  [ "$(grep -c . "$T/w.alerts")" = "$WA" ] && ok || bad "W(S=$S PCT=${PCT:-80}): want $WA alert(s), got: $(cat "$T/w.alerts")"
done
rm -f "$HW/flags"/alerted-pool-warmup-*; : > "$T/w.log"; : > "$T/w.alerts"; PCT=""
wn m1 BH-1 1000 6000 1800; wn m2 BH-2 1000 6000 1800
[ "$(grep -c . "$T/w.alerts")" = 1 ] && ok || bad "W8: two slow spawns on one day page once, got: $(cat "$T/w.alerts")"
grep -q '\[pool/project-5\] BH-1: launch→first push 5000s on m1 is over 80% of the 1800s warmup wait' "$T/w.alerts" && ok \
  || bad "W8: the alert must name the key, machine and numbers: $(cat "$T/w.alerts")"
[ "$(ls "$HW/flags" | grep -cx 'alerted-pool-warmup-project-5-[0-9]\{8\}')" = 1 ] && ok || bad "W8: one day flag, got: $(ls "$HW/flags")"
# A negative span is 0.
: > "$T/w.log"; wn m1 BH-1 1000 900 1800
grep -qx 'm1: launch→first push 0s (warmup wait 1800s)' "$T/w.log" && ok || bad "W: a negative span logs 0s, got: $(cat "$T/w.log")"

echo "fly-pool-warmup (BH-7215): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
