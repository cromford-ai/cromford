#!/bin/bash
# tests/fly-pool-vm-class.bh-9065-test.sh — BH-9065: two pool machine classes,
# chosen per job kind by a settings row. A model-session job (plan, lead
# review, re-review) runs on shared-cpu-2x; execute stays on performance-8x.
# With no row the fallback map `plan=model leadreview=model rereview=model`
# applies; a row replaces it.
#
# PINNED:
#   K1      the registry carries VM_CLASS (string, default the fallback map), VM_SIZE_MODEL
#           (string, default shared-cpu-2x), VM_MEMORY_MB_MODEL (int, 4096).
#   R1-R8   pool_vm_resolve accepts the shared-cpu class with its own memory
#           rule (the REPRO of this ticket is R1).
#   C1-C10  pool_vm_kind_for_key / pool_vm_class_for / pool_vm_resolve_for on
#           every case of the plan's decision rule (1).
#   D1-D4   DRIVEN (`bash bin/fly-pool.sh project-5`, fake fly): an LR- job's
#           `machine run` argv has --vm-size shared-cpu-2x, a build job's has
#           performance-8x; no row = the fallback map (D3, D5, D6); a refused model
#           row = performance-8x and one refusal line; the machine json and the
#           `vm class` log line name the class.
#   N1-N2   next_job_or_destroy hands a reaped machine only a job of its class.
#   S1      every fly call went to the stub.
# Run from anywhere: bash tests/fly-pool-vm-class.bh-9065-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/pool-vm-size.sh"

# ══ K1: the registry carries the three knobs ════════════════════════════════
mkdir -p "$T/reg/catalog"
cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/"
bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 || bad "K1: lanes-build.sh --write failed on a scratch copy"
REG="$T/reg/catalog/lanes.json"
kf() { jq -r --arg e "$1" --arg f "$2" '.lanes[]? | select(.id=="fly-pool") | .knobs[]? | select(.env==$e) | .[$f] | tostring' "$REG" 2>/dev/null; }
FBMAP="plan=model leadreview=model rereview=model"
[ "$(kf VM_CLASS type)" = string ] && [ "$(kf VM_CLASS default)" = "$FBMAP" ] && ok \
  || bad "K1: VM_CLASS must be a string knob, default '$FBMAP', got '$(kf VM_CLASS type)' '$(kf VM_CLASS default)'"
# The registry default and the code fallback are one string.
LIBFB=$(env -i PATH="$PATH" bash -c '. "$1"; printf "%s" "$POOL_VM_CLASS_FALLBACK"' _ "$LIB")
[ "$LIBFB" = "$FBMAP" ] && ok || bad "K1: POOL_VM_CLASS_FALLBACK must be '$FBMAP', got '$LIBFB'"
[ "$(kf VM_SIZE_MODEL type)" = string ] && [ "$(kf VM_SIZE_MODEL default)" = shared-cpu-2x ] && ok \
  || bad "K1: VM_SIZE_MODEL must be string shared-cpu-2x, got '$(kf VM_SIZE_MODEL type)' '$(kf VM_SIZE_MODEL default)'"
[ "$(kf VM_MEMORY_MB_MODEL type)" = int ] && [ "$(kf VM_MEMORY_MB_MODEL default)" = 4096 ] && ok \
  || bad "K1: VM_MEMORY_MB_MODEL must be int 4096, got '$(kf VM_MEMORY_MB_MODEL type)' '$(kf VM_MEMORY_MB_MODEL default)'"
SK=$(env -i PATH="$PATH" bash -c '. "$1/bin/lib/lane-gate.sh" 2>/dev/null; echo "$(_lg_setting_key fly-pool VM_CLASS p) $(_lg_setting_key fly-pool VM_SIZE_MODEL p) $(_lg_setting_key fly-pool VM_MEMORY_MB_MODEL p)"' _ "$DIR")
[ "$SK" = "lane.fly-pool.p.vm_class lane.fly-pool.p.vm_size_model lane.fly-pool.p.vm_memory_mb_model" ] && ok \
  || bad "K1: settings keys, got '$SK'"

# ══ R: pool_vm_resolve, shared-cpu class ════════════════════════════════════
# rc <case> <want-size> <want-mem> <want-rc> [VAR=...]
rc_case() {
  local c="$1" ws="$2" wm="$3" wr="$4"; shift 4
  local out s m r w
  out=$(env -i PATH="$PATH" "$@" bash -c '. "$1" 2>/dev/null || exit 9
    pool_vm_resolve; rc=$?
    printf "%s|%s|%s|%s\n" "$PVM_SIZE" "$PVM_MEM" "$rc" "$PVM_WHY"' _ "$LIB")
  IFS='|' read -r s m r w <<<"$out"
  [ "$s" = "$ws" ] && [ "$m" = "$wm" ] && [ "$r" = "$wr" ] && ok || bad "$c: want $ws/$wm rc=$wr, got '$out' ($*)"
}
rc_case R1 shared-cpu-2x 4096  0 VM_SIZE=shared-cpu-2x VM_MEMORY_MB=4096
rc_case R2 shared-cpu-1x 256   0 VM_SIZE=shared-cpu-1x VM_MEMORY_MB=256
rc_case R3 shared-cpu-8x 16384 0 VM_SIZE=shared-cpu-8x VM_MEMORY_MB=16384
rc_case R4 shared-cpu-4x 1280  0 VM_SIZE=shared-cpu-4x VM_MEMORY_MB=1280
rc_case R5 performance-8x 16384 1 VM_SIZE=shared-cpu-2x VM_MEMORY_MB=8192
rc_case R6 performance-8x 16384 1 VM_SIZE=shared-cpu-2x VM_MEMORY_MB=1000
rc_case R7 performance-8x 16384 1 VM_SIZE=shared-cpu-3x VM_MEMORY_MB=1024
rc_case R8 performance-8x 16384 1 VM_SIZE=shared-cpu-16x VM_MEMORY_MB=4096

# ══ C: kind and class (decision rule 1) ═════════════════════════════════════
# cc <case> <key> <want-class> <want-size> <want-mem> [VAR=...]
cc() {
  local c="$1" k="$2" wc="$3" ws="$4" wm="$5"; shift 5
  local out
  out=$(env -i PATH="$PATH" "$@" bash -c '. "$1" 2>/dev/null || exit 9
    pool_vm_resolve_for "$(pool_vm_kind_for_key "$2")"
    printf "%s|%s|%s\n" "$PVM_CLASS" "$PVM_SIZE" "$PVM_MEM"' _ "$LIB" "$k")
  [ "$out" = "$wc|$ws|$wm" ] && ok || bad "$c: key $k want $wc|$ws|$wm, got '$out' ($*)"
}
ROW='VM_CLASS=leadreview=model rereview=model'
cc C1  LR-12-abcdef12  model   shared-cpu-2x  4096  "$ROW"
cc C2  RR-12-abcdef12  model   shared-cpu-2x  4096  "$ROW"
cc C3  BH-1            compute performance-8x 16384 "$ROW"
cc C4  FXR-9-abcdef12  compute performance-8x 16384 "$ROW"
cc C5  LR-12-abcdef12  model   shared-cpu-2x  4096
cc C6  LR-12-abcdef12  compute performance-8x 16384 "VM_CLASS=LEADREVIEW=model"
cc C7  LR-12-abcdef12  compute performance-8x 16384 "VM_CLASS=lead=model"
cc C8  LR-12-abcdef12  compute performance-8x 16384 "$ROW" VM_SIZE_MODEL=shared-cpu-3x
cc C9  LR-12-abcdef12  model   performance-8x 16384 "$ROW" VM_SIZE_MODEL=performance-8x VM_MEMORY_MB_MODEL=16384
cc C10 LR-12-abcdef12  model   shared-cpu-4x  2048  "VM_CLASS=leadreview=model,rereview=model" VM_SIZE_MODEL=shared-cpu-4x VM_MEMORY_MB_MODEL=2048
cc C11 LR-12-abcdef12  compute performance-8x 16384 "VM_CLASS=leadreview=gpu"
cc C12 LR-12-abcdef12  compute performance-8x 16384 "VM_CLASS=*"
# C13: under `set -u` with no knob in the env (the pool's own shell), every
# function still answers: an unset VM_CLASS is the fallback map, not an abort.
U13=$(env -i PATH="$PATH" bash -c 'set -u; . "$1"; printf "%s|%s|%s|" "$(pool_vm_class_for build)" "$(pool_vm_class_for plan)" "$(pool_vm_class_for execute)"; pool_vm_resolve_for leadreview; printf "%s|%s\n" "$PVM_CLASS" "$PVM_SIZE"' _ "$LIB" 2>&1)
[ "$U13" = "compute|model|compute|model|shared-cpu-2x" ] && ok || bad "C13: set -u with VM_CLASS unset must answer the fallback map: '$U13'"
# ck <case> <kind> <want-class> [VAR=...] — the class of a kind (decision rule 1a).
ck() {
  local c="$1" k="$2" wc="$3"; shift 3
  local out
  out=$(env -i PATH="$PATH" "$@" bash -c '. "$1" 2>/dev/null || exit 9; pool_vm_class_for "$2"' _ "$LIB" "$k")
  [ "$out" = "$wc" ] && ok || bad "$c: kind $k want $wc, got '$out' ($*)"
}
# The fallback map (no row), every kind of the plan's table.
for k in plan leadreview rereview; do ck "C14 $k" "$k" model; done
for k in execute build fixround rebase preview gate test plan-replan PLAN ""; do ck "C15 '$k'" "$k" compute; done
# An empty row is the fallback map; a row replaces the map.
ck C16 plan model VM_CLASS=
ck C17 plan compute VM_CLASS=build=compute
ck C18 plan compute "VM_CLASS=leadreview=model"
ck C19 leadreview compute VM_CLASS=build=compute
ck C20 execute compute "VM_CLASS=execute=model plan=model execute=compute"
# The plan stage of a build key resolves to the model pair, execute to compute.
pk() { # pk <case> <want> <stage-or-none> [VAR=...]
  local c="$1" w="$2" st="$3"; shift 3
  local jf="$T/pk-$c.json" out
  if [ "$st" = none ]; then echo '{"key":"BH-1"}' > "$jf"; else jq -nc --arg s "$st" '{key:"BH-1",stage:$s}' > "$jf"; fi
  out=$(env -i PATH="$PATH" "$@" bash -c '. "$1" 2>/dev/null || exit 9
    k=$(pool_vm_job_kind BH-1 "$2"); pool_vm_resolve_for "$k"
    printf "%s|%s|%s|%s\n" "$k" "$PVM_CLASS" "$PVM_SIZE" "$PVM_MEM"' _ "$LIB" "$jf")
  [ "$out" = "$w" ] && ok || bad "$c: want $w, got '$out' ($*)"
}
pk C21 "plan|model|shared-cpu-2x|4096" none
pk C22 "execute|compute|performance-8x|16384" execute
pk C23 "build|compute|performance-8x|16384" none VM_CLASS=build=compute
pk C24 "execute|compute|performance-8x|16384" execute VM_CLASS=build=compute
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
# This suite's own rows and queue file (a key per case).
rows() { # rows <vm_class> [vm_size_model] [vm_memory_mb_model]
  jq -n --argjson fa "$(date -u +%s)" --arg c "$1" --arg s "${2:-}" --arg m "${3:-}" \
    '{fetched_at:$fa,values:({"lane.fly-pool.project-5.vm_class":$c,"lane.fly-pool.project-5.vm_size_model":$s,"lane.fly-pool.project-5.vm_memory_mb_model":$m}|with_entries(select(.value!=""))),seeded:{}}' \
    > "$H/state/settings-cache.json"
}
queue() { # queue <key> — a build row, or a lead-review row for an LR- key
  local k="$1"
  scratch_rm "$QD/BH-1.json" 2>/dev/null
  case "$k" in
    LR-*) jq -nc --arg k "$k" '{ticket_id:"0",key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-28T00:00:00Z",
            leadreview:{kind:"leadreview",slug:"example-org/project-5",url:"https://github.com/example-org/project-5/pull/12",pr:12,head:"abcdef1234567890abcdef1234567890abcdef12",request:"r1",mode:"lead",item:"i1",by:"t"}}' > "$QD/$k.json" ;;
    *) jq -nc --arg k "$k" '{ticket_id:"1",key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-28T00:00:00Z"}' > "$QD/$k.json" ;;
  esac
}
mjson() { cat "$POOLD"/1234567890abcd.json 2>/dev/null; }
LRK=LR-12-abcdef12

# ══ D1: a row maps leadreview to model -> shared-cpu-2x on the LR job ═══════
reset_case; queue "$LRK"; rows "leadreview=model rereview=model"
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-size shared-cpu-2x --vm-memory 4096 ' && ok \
  || bad "D1: an LR job under the row must launch shared-cpu-2x/4096: $(runline) / $(log)"
grep -q "vm class model shared-cpu-2x/4096 for $LRK (leadreview)" "$H/logs/fly-pool.log" && ok \
  || bad "D1: the log must say 'vm class model shared-cpu-2x/4096 for $LRK (leadreview)': $(log)"
[ "$(mjson | jq -r '[.vm_class,.vm_size,.vm_mem]|join(" ")')" = "model shared-cpu-2x 4096" ] && ok \
  || bad "D1: the machine json must carry vm_class/vm_size/vm_mem: $(mjson)"

# ══ D2: the same row, a build job -> performance-8x ═════════════════════════
reset_case; rows "leadreview=model rereview=model"
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-size performance-8x --vm-memory 16384 ' && ok \
  || bad "D2: a build job must launch performance-8x/16384: $(runline) / $(log)"
grep -q "vm class compute performance-8x/16384 for BH-1 (build)" "$H/logs/fly-pool.log" && ok \
  || bad "D2: the log must name class compute for BH-1: $(log)"

# ══ D3: no row -> the fallback map puts the LR job on shared-cpu-2x ════════
reset_case; queue "$LRK"
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-size shared-cpu-2x --vm-memory 4096 ' && ok \
  || bad "D3: with no vm_class row an LR job must launch shared-cpu-2x/4096: $(runline) / $(log)"

# ══ D5: no row, a fresh build key -> its plan stage on shared-cpu-2x ════════
reset_case
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-size shared-cpu-2x --vm-memory 4096 ' && ok \
  || bad "D5: with no row a build key's plan job must launch shared-cpu-2x/4096: $(runline) / $(log)"
grep -q "vm class model shared-cpu-2x/4096 for BH-1 (plan)" "$H/logs/fly-pool.log" && ok \
  || bad "D5: the log must say 'vm class model shared-cpu-2x/4096 for BH-1 (plan)': $(log)"

# ══ D6: no row, the re-offer after the plan (stage execute) -> performance-8x
reset_case
jq -nc '{ticket_id:"1",key:"BH-1",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-28T00:00:00Z",stage:"execute"}' > "$QD/BH-1.json"
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-size performance-8x --vm-memory 16384 ' && ok \
  || bad "D6: with no row an execute job must launch performance-8x/16384: $(runline) / $(log)"
grep -q "vm class compute performance-8x/16384 for BH-1 (execute)" "$H/logs/fly-pool.log" && ok \
  || bad "D6: the log must name class compute for BH-1 (execute): $(log)"

# ══ D7: row build=compute -> every kind back on performance-8x ═════════════
reset_case; rows "build=compute"
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-size performance-8x --vm-memory 16384 ' && ok \
  || bad "D7: row build=compute must launch a build key on performance-8x: $(runline) / $(log)"

# ══ D4: a refused model row -> performance-8x and one refusal line ══════════
reset_case; queue "$LRK"; rows "leadreview=model" shared-cpu-2x 8192
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-size performance-8x --vm-memory 16384 ' && ok \
  || bad "D4: a refused model pair must launch performance-8x/16384: $(runline)"
[ "$(grep -c 'VM size row refused' "$H/logs/fly-pool.log")" = 1 ] && ok || bad "D4: one refusal line: $(log)"
grep -q "vm class compute performance-8x/16384 for $LRK" "$H/logs/fly-pool.log" && ok || bad "D4: the refused pair is class compute: $(log)"

# ══ N: reuse only within a class (next_job_or_destroy, sourced alone) ═══════
# The real function from the rendered script, driven against stubs the way
# tests/pool-account-routing-test.sh section 13 drives it.
NR="$T/njd"; mkdir -p "$NR/bin"
sed -n '/^next_job_or_destroy() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$NR/fn.sh"
grep -q 'REUSED=0' "$NR/fn.sh" && ok || bad "N0: could not extract next_job_or_destroy from bin/fly-pool.sh"
printf '#!/bin/bash\necho "$*" >> "${FAKE_FLY_LOG:?}"\n' > "$NR/fly"; chmod +x "$NR/fly"
printf '#!/bin/bash\nexit 0\n' > "$NR/bin/beat.sh"; chmod +x "$NR/bin/beat.sh"
NCASE=0
njd() { # njd <machine-class|none> <next-key> [stage|-] [VM_CLASS|-unset] -> prints DESTROYED|REUSED; the case dir is $NR/c$NCASE
  NCASE=$((NCASE+1)); local c="$NR/c$NCASE"; mkdir -p "$c/q" "$c/pool"
  jq -nc --arg k "$2" --arg s "${3:--}" '{key:$k,ticket_id:"2",attempt:0} + (if $s == "-" then {} else {stage:$s} end)' > "$c/q/$2.json"
  if [ "$1" = none ]; then jq -nc '{machine:"m1",key:"BH-0"}' > "$c/pool/m1.json"
  else jq -nc --arg v "$1" '{machine:"m1",key:"BH-0",vm_class:$v,vm_size:"s-x",vm_mem:"1"}' > "$c/pool/m1.json"; fi
  (
    set +u
    HARNESS="$NR"; P=project-5; APP=app; FLY="$NR/fly"; export FAKE_FLY_LOG="$c/flylog"
    QDIR="$c/q"; POOL="$c/pool"; LOG="$c/log"
    MID=m1; MSTATE=started; KEY=BH-0; MF="$c/pool/m1.json"; MACCT=""
    VM_CLASS="${4:-leadreview=model rereview=model}"; [ "$VM_CLASS" = -unset ] && unset VM_CLASS
    STAMP() { echo now; }; say() { echo "$*" >> "$LOG"; }
    mexec() { return 0; }; mput() { return 0; }; push_preplan() { :; }
    push_reroute() { :; }; push_build_note() { :; }; push_bake_evidence() { :; }
    pool_account_release() { :; }; pool_account_armed() { return 1; }
    . "$LIB"; . "$NR/fn.sh"
    next_job_or_destroy
    if grep -q 'machine destroy m1' "$c/flylog" 2>/dev/null; then echo DESTROYED; else echo REUSED; fi
  )
}
nr() { njd "$@" > "$NR/out"; cat "$NR/out"; }   # njd in this shell, so NCASE counts
nr compute "$LRK" >/dev/null; [ "$(cat "$NR/out")" = DESTROYED ] && ok || bad "N1: a compute machine must not be handed an LR job (model class): $(cat "$NR/c$NCASE/log")"
nr model BH-7 >/dev/null;     [ "$(cat "$NR/out")" = DESTROYED ] && ok || bad "N1: a model machine must not be handed a build job: $(cat "$NR/c$NCASE/log")"
nr model RR-3-abcdef12 >/dev/null; [ "$(cat "$NR/out")" = REUSED ] && ok || bad "N2: a model machine must take an RR job (same class): $(cat "$NR/c$NCASE/log")"
nr compute BH-7 >/dev/null;   [ "$(cat "$NR/out")" = REUSED ] && ok || bad "N2: a compute machine must take a build job: $(cat "$NR/c$NCASE/log")"
nr none BH-7 >/dev/null;      [ "$(cat "$NR/out")" = REUSED ] && ok || bad "N2: a machine json with no vm_class is compute and takes a build job: $(cat "$NR/c$NCASE/log")"
nr model RR-4-abcdef12 >/dev/null
[ "$(jq -r '[.key,.vm_class,.vm_size,.vm_mem]|join(" ")' "$NR/c$NCASE/pool/m1.json" 2>/dev/null)" = "RR-4-abcdef12 model s-x 1" ] && ok \
  || bad "N3: the reused machine json must keep vm_class/vm_size/vm_mem: $(cat "$NR/c$NCASE/pool/m1.json" 2>/dev/null)"

# With no row (the fallback map): a model machine takes a fresh build key (its
# plan job); a compute machine takes only the execute re-offer.
nr model BH-7 - -unset >/dev/null;   [ "$(cat "$NR/out")" = REUSED ] && ok || bad "N4: no row: a model machine must take a plan job: $(cat "$NR/c$NCASE/log")"
nr compute BH-7 - -unset >/dev/null; [ "$(cat "$NR/out")" = DESTROYED ] && ok || bad "N4: no row: a compute machine must not be handed a plan job: $(cat "$NR/c$NCASE/log")"
nr compute BH-7 execute -unset >/dev/null; [ "$(cat "$NR/out")" = REUSED ] && ok || bad "N4: no row: a compute machine must take an execute job: $(cat "$NR/c$NCASE/log")"
nr model BH-7 execute -unset >/dev/null;   [ "$(cat "$NR/out")" = DESTROYED ] && ok || bad "N4: no row: a model machine must not be handed an execute job: $(cat "$NR/c$NCASE/log")"
# N5: a machine json with no vm_class was spawned before the classes: it keeps
# the old reuse rule and takes any job, so the deploy destroys no running machine.
nr none BH-7 - -unset >/dev/null;    [ "$(cat "$NR/out")" = REUSED ] && ok || bad "N5: an unclassed machine must take a plan job: $(cat "$NR/c$NCASE/log")"
nr none "$LRK" - -unset >/dev/null;  [ "$(cat "$NR/out")" = REUSED ] && ok || bad "N5: an unclassed machine must take an LR job: $(cat "$NR/c$NCASE/log")"

# ══ S1: every fly call went to the stub ═════════════════════════════════════
[ -s "$T/fly.txt" ] && ok || bad "S1: the fly stub recorded no call"

echo "fly-pool-vm-class (BH-9065): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
