#!/bin/bash
# tests/fly-pool-vm-size.bh-8318-test.sh — BH-8318 (MKF-3): the pool VM size
# and memory per project are settings rows, not the literal
# `--vm-size performance-8x --vm-memory 16384` on `fly machine run`.
#
# PINNED:
#   K1      the composed registry carries fly-pool knobs VM_SIZE (string,
#           default performance-8x) and VM_MEMORY_MB (int, default 16384,
#           min 2048, max 131072); the row keys are vm_size / vm_memory_mb.
#   U1-U17  pool_vm_resolve (the REAL lib, in an env -i shell) on every case
#           of the plan's decision rule: PVM_SIZE, PVM_MEM, rc, PVM_WHY.
#   D1-D6   DRIVEN (`bash bin/fly-pool.sh project-5` against a scratch
#           $HARNESS): no row -> today's argv; a row -> its argv; a bad row ->
#           the fallback and one log line; push and pull both read it; no lib
#           -> today's argv; the env rung of lane_env_apply.
#   S1      every fly call went to the stub.
# Run from anywhere: bash tests/fly-pool-vm-size.bh-8318-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/pool-vm-size.sh"

# ══ K1: the registry carries both knobs ═════════════════════════════════════
mkdir -p "$T/reg/catalog"
cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/"
bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 || bad "K1: lanes-build.sh --write failed on a scratch copy"
REG="$T/reg/catalog/lanes.json"
kf() { jq -r --arg e "$1" --arg f "$2" '.lanes[]? | select(.id=="fly-pool") | .knobs[]? | select(.env==$e) | .[$f] | tostring' "$REG" 2>/dev/null; }
[ "$(kf VM_SIZE type)" = string ] && [ "$(kf VM_SIZE default)" = performance-8x ] && ok \
  || bad "K1: VM_SIZE must be a string knob, default performance-8x, got '$(kf VM_SIZE type)' '$(kf VM_SIZE default)'"
[ "$(kf VM_MEMORY_MB type)" = int ] && [ "$(kf VM_MEMORY_MB default)" = 16384 ] \
  && [ "$(kf VM_MEMORY_MB min)" = 2048 ] && [ "$(kf VM_MEMORY_MB max)" = 131072 ] && ok \
  || bad "K1: VM_MEMORY_MB must be int 16384 [2048,131072], got '$(kf VM_MEMORY_MB type)' '$(kf VM_MEMORY_MB default)' '$(kf VM_MEMORY_MB min)' '$(kf VM_MEMORY_MB max)'"
SK=$(env -i PATH="$PATH" bash -c '. "$1/bin/lib/lane-gate.sh" 2>/dev/null; echo "$(_lg_setting_key fly-pool VM_SIZE project-6-os) $(_lg_setting_key fly-pool VM_MEMORY_MB project-6-os)"' _ "$DIR")
[ "$SK" = "lane.fly-pool.project-6-os.vm_size lane.fly-pool.project-6-os.vm_memory_mb" ] && ok \
  || bad "K1: the settings keys must be lane.fly-pool.<p>.vm_size / .vm_memory_mb, got '$SK'"

# ══ U: pool_vm_resolve, the real lib ════════════════════════════════════════
[ -f "$LIB" ] && ok || bad "U0: bin/lib/pool-vm-size.sh is missing"
# uc <case> <want-size> <want-mem> <want-rc> [VM_SIZE=...] [VM_MEMORY_MB=...]
uc() {
  local c="$1" ws="$2" wm="$3" wr="$4"; shift 4
  local out
  out=$(env -i PATH="$PATH" "$@" bash -c '. "$1" 2>/dev/null || exit 9
    pool_vm_resolve; rc=$?
    printf "%s|%s|%s|%s\n" "$PVM_SIZE" "$PVM_MEM" "$rc" "$PVM_WHY"' _ "$LIB")
  local s m r w; IFS='|' read -r s m r w <<<"$out"
  if [ "$s" = "$ws" ] && [ "$m" = "$wm" ] && [ "$r" = "$wr" ] \
     && { { [ "$wr" = 0 ] && [ -z "$w" ]; } || { [ "$wr" = 1 ] && [ -n "$w" ]; }; }; then ok
  else bad "$c: want $ws/$wm rc=$wr, got '$out' ($*)"; fi
}
NL=$'\n'
uc U1  performance-8x  16384 0
uc U2  performance-16x 32768 0 VM_SIZE=performance-16x VM_MEMORY_MB=32768
uc U3  performance-8x  65536 0 VM_SIZE=performance-8x VM_MEMORY_MB=65536
uc U4  performance-4x  8192  0 VM_SIZE=performance-4x VM_MEMORY_MB=8192
uc U5  performance-16x 32768 0 "VM_SIZE= performance-16x " "VM_MEMORY_MB=32768$NL"
uc U6  performance-8x  16384 0 VM_SIZE=performance-8x
uc U7  performance-8x  32768 0 VM_MEMORY_MB=32768
uc U8  performance-8x  16384 1 VM_SIZE=performance-32x VM_MEMORY_MB=65536
uc U9  performance-8x  16384 1 VM_SIZE=Performance-16x VM_MEMORY_MB=32768
uc U10 performance-8x  16384 1 VM_SIZE=performance-16x VM_MEMORY_MB=16384
uc U11 performance-8x  16384 1 VM_SIZE=performance-8x VM_MEMORY_MB=65537
uc U12 performance-8x  16384 1 VM_SIZE=performance-8x VM_MEMORY_MB=70000
uc U13 performance-8x  16384 1 VM_SIZE=shared-cpu-8x VM_MEMORY_MB=16384
uc U14 performance-8x  16384 1 VM_SIZE=performance-16x VM_MEMORY_MB=32g
uc U15 performance-8x  16384 1 "VM_SIZE=performance-8x; rm -rf /" VM_MEMORY_MB=16384
uc U16 performance-8x  16384 1 VM_SIZE=performance-8x VM_MEMORY_MB=-16384
uc U17 performance-8x  16384 1 VM_SIZE=performance-16x VM_MEMORY_MB=2048
uc U18 performance-1x  2048  0 VM_SIZE=performance-1x VM_MEMORY_MB=2048
uc U19 performance-8x  16384 1 VM_SIZE=performance-1x VM_MEMORY_MB=16384
uc U20 performance-8x  16384 1 VM_SIZE=performance-1x
# The reason names the refused value.
W=$(env -i PATH="$PATH" VM_SIZE=performance-32x bash -c '. "$1"; pool_vm_resolve; echo "$PVM_WHY"' _ "$LIB")
grep -q 'performance-32x' <<<"$W" && ok || bad "U21: PVM_WHY must name the refused size, got '$W'"

# ══ the driven pool (scaffold of tests/fly-pool-machine-pull.bh-7430) ═══════
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/state/build-notes/project-5" \
         "$H/state/vercel-deploys" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=tok-fixture-fly\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 boxa 192.0.2.9\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
cat > "$H/bin/lib/pool-account.sh" <<'PA'
#!/bin/bash
pool_account_lease() { echo "name=default reason=unarmed"; }
pool_account_rebind() { return 0; }
pool_account_release() { return 0; }
pool_account_others_ok() { return 1; }
pool_account_prune() { :; }
pool_account_armed() { return 1; }
pool_account_cooldown() { :; }
pool_account_unpin() { :; }
PA
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" \
   "$DIR/bin/alert-line.sh" "$DIR/bin/fly-envbundle.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/fakebin/ssh" <<'SSH'
#!/bin/bash
printf '===GLOBAL===\n'
printf 'CLAUDE_CODE_OAUTH_TOKEN=fixture-claude-base\nHARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.invalid\n'
printf 'OPENROUTER_API_KEY=fixture-or\nGH_TOKEN=fixture-pat\n'
printf '===PROJECT===\n'
printf 'BOARD_TOKEN=fixture-board\n'
exit 0
SSH
cat > "$T/fakebin/fly" <<'FLY'
#!/bin/bash
echo "fly $*" >> "${FLY_SINK:-/dev/null}"
case "$*" in
  *"secrets list"*) echo '[{"Name":"HBUNDLE_G_HARNESS_SECRET","Digest":"d1"},{"Name":"HBUNDLE_SYNCED_AT","Digest":"d2"}]' ;;
  *"secrets import"*) cat > /dev/null ;;
  *"machine status"*) echo "State: started" ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\n' ;;
esac
exit 0
FLY
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" =~ issues/[0-9]+ ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'; exit 0
fi
if [[ "$*" == *"-i"* ]]; then
  if [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0
  fi
  if [[ "$*" =~ git/ref/heads/ticket/bh-[0-9]+ ]]; then printf 'HTTP/1.1 200 OK\n\n{}\n'; exit 0; fi
  if [[ "$*" == *"pulls?state=open"*"head="* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
exit 0
GH
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
printf '{}\n404\n'
STUB
printf 'GH_APP_ID=1\n' > "$H/env/github-app.env"
cat > "$H/bin/gh-token.sh" <<'GT'
#!/bin/bash
case " $* " in
  *" --installation-id "*) echo 4242 ;;
  *" --expires-at "*) echo 2026-10-28T05:00:00Z ;;
  *" --extra-read "*"cromford"*) echo tok-fixture-harness ;;
  *" --extra-read "*) echo tok-fixture-read ;;
  *) echo tok-fixture-app ;;
esac
exit 0
GT
chmod +x "$H/bin"/*.sh "$T/fakebin"/*
# The pinned harness checkout the pull path needs (${HARNESS}-checkout).
HCO="$H-checkout"
mkdir -p "$HCO/bin" "$HCO/prompts" "$HCO/rules" "$HCO/catalog" "$HCO/fly"
echo fixture > "$HCO/bin/x"; echo fixture > "$HCO/fleet.conf"
for d in prompts rules catalog fly; do echo fixture > "$HCO/$d/x"; done
git -C "$HCO" init -q && git -C "$HCO" -c user.email=t@t -c user.name=t add -A \
  && git -C "$HCO" -c user.email=t@t -c user.name=t commit -qm fixture

POOLD="$H/state/fly-pool/project-5"; QD="$H/state/build-queue/project-5"
run_pool() { # run_pool [VAR=val ...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid JOBS_BOX=hub \
           JOBS_RETRIES=0 JOBS_TIMEOUT=5 FLY_SINK="$T/fly.txt" \
           FLY_API_TOKEN_project-5=tok-fixture-fly FLY_BIN_DIR="$T/fakebin" "$@"
    bash "${POOL_SCRIPT:-$DIR/bin/fly-pool.sh}" project-5 >/dev/null 2>&1 )
}
reset_case() {
  local p
  for p in "$QD"/* "$QD"/.??* "$POOLD"/*.json "$POOLD"/.??* "$H/state/pool/project-5"/* \
           "$H/state/build-notes/project-5"/* "$H/state/vercel-deploys"/* "$H/state/settings-cache.json"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$T/fly.txt"; : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  jq -nc '{ticket_id:"1",key:"BH-1",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-28T00:00:00Z"}' > "$QD/BH-1.json"
  return 0
}
rows() { # rows <size> <mem> -> the settings cache lane_env_apply reads
  jq -n --argjson fa "$(date -u +%s)" --arg s "$1" --arg m "$2" \
    '{fetched_at:$fa,values:({"lane.fly-pool.project-5.vm_size":$s,"lane.fly-pool.project-5.vm_memory_mb":$m}|with_entries(select(.value!=""))),seeded:{}}' \
    > "$H/state/settings-cache.json"
}
log() { cat "$H/logs/fly-pool.log" 2>/dev/null; }
runline() { grep 'fly machine run' "$T/fly.txt" | head -1; }
refused() { grep -c 'VM size row refused' "$H/logs/fly-pool.log" 2>/dev/null | head -1; }

# ══ D1 (AT1): no row -> today's argv, byte for byte ═════════════════════════
reset_case
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--detach --vm-size performance-8x --vm-memory 16384 -e PROJECT=project-5' && ok \
  || bad "D1: no row must give '--vm-size performance-8x --vm-memory 16384': $(runline) / $(log)"
[ "$(refused)" = 0 ] && ok || bad "D1: no row must log no refusal: $(log)"

# ══ D2 (AT2): the rows reach machine run ════════════════════════════════════
reset_case
rows performance-16x 32768
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-size performance-16x --vm-memory 32768 ' && ok \
  || bad "D2: rows performance-16x/32768 must reach machine run: $(runline) / $(log)"
[ "$(refused)" = 0 ] && ok || bad "D2: a good row must log no refusal: $(log)"

# ══ D3 (AT3): a bad row -> the fallback and ONE line ════════════════════════
reset_case
rows performance-32x ""
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-size performance-8x --vm-memory 16384 ' && ok \
  || bad "D3: a bad size row must launch performance-8x/16384: $(runline)"
[ "$(refused)" = 1 ] && ok || bad "D3: one refusal line for one job, got $(refused): $(log)"
grep 'VM size row refused' "$H/logs/fly-pool.log" | grep -q 'BH-1.*performance-32x.*launching performance-8x/16384' && ok \
  || bad "D3: the line must name the key, the value and the fallback: $(log)"
grep -q 'spawned 1234567890abcd for BH-1' "$H/logs/fly-pool.log" && ok || bad "D3: the spawn must go ahead: $(log)"

# ══ D4 (AT4): the push path and the pull path both read the rows ════════════
for PM in 0 1; do
  reset_case
  rows performance-16x 32768
  run_pool LANE_REGISTRY="$REG" POOL_MACHINE_PULL=$PM
  L=$(runline)
  if [ "$PM" = 1 ]; then
    grep -q -- '-e HARNESS_SHA=' <<<"$L" && ok || bad "D4 precondition: POOL_MACHINE_PULL=1 must take the pull path: $L / $(log)"
  else
    grep -q -- '-e HARNESS_SHA=' <<<"$L" && bad "D4 precondition: POOL_MACHINE_PULL=0 must take the push path: $L" || ok
  fi
  grep -q -- '--vm-size performance-16x --vm-memory 32768 ' <<<"$L" && ok \
    || bad "D4: POOL_MACHINE_PULL=$PM must carry performance-16x/32768: $L / $(log)"
done

# ══ D5: no lib in the tree -> today's argv, the tick still spawns ══════════
# The scratch copy of the script runs, so neither source path finds the lib.
reset_case
[ -f "$H/bin/fly-pool.sh" ] && ok || bad "D5 precondition: the closure must install bin/fly-pool.sh"
rows performance-16x 32768
mv "$H/bin/lib/pool-vm-size.sh" "$T/pool-vm-size.sh.away" 2>/dev/null
POOL_SCRIPT="$H/bin/fly-pool.sh" run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-size performance-8x --vm-memory 16384 ' && ok \
  || bad "D5: with no lib the argv must be performance-8x/16384: $(runline) / $(log)"
grep -q 'spawned 1234567890abcd for BH-1' "$H/logs/fly-pool.log" && ok || bad "D5: the tick must still spawn: $(log)"
mv "$T/pool-vm-size.sh.away" "$H/bin/lib/pool-vm-size.sh" 2>/dev/null

# ══ D6: the env rung (no row) ═══════════════════════════════════════════════
reset_case
run_pool LANE_REGISTRY="$REG" VM_SIZE=performance-4x VM_MEMORY_MB=8192
runline | grep -q -- '--vm-size performance-4x --vm-memory 8192 ' && ok \
  || bad "D6: env VM_SIZE/VM_MEMORY_MB must reach machine run: $(runline) / $(log)"

# ══ S1: every fly call went to the stub ═════════════════════════════════════
[ -s "$T/fly.txt" ] && ok || bad "S1: the fly stub recorded no call"

echo "fly-pool-vm-size (BH-8318): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
