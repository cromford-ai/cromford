#!/bin/bash
# tests/fly-pool-rootfs.bh-8640-test.sh — BH-8640 (rest of BH-8499, Fix 3):
# the rootfs size of a pool machine is a settings row
# (lane.fly-pool.<project>.rootfs_gb), passed as `--rootfs-size <GB>` on
# `fly machine run`, and seeded for project-6-os.
#
# PINNED:
#   K1      the composed registry carries fly-pool knob ROOTFS_GB (int, default
#           0, min 0, max 100); the row key is lane.fly-pool.<p>.rootfs_gb;
#           and POOL_ROOTFS_PROBE_TIMEOUT_S (int, default 20, min 1, max 120).
#   K2      the composed jobs schema seeds project-6-os at 20, and an
#           operator value survives a re-apply.
#   U1-U16  pool_rootfs_resolve (the REAL lib, in an env -i shell) on every
#           case of the plan's decision rule: PRFS_GB, PRFS_ARGS, rc, PRFS_WHY,
#           and the flyctl help probe (only for a valid row, once per process,
#           cut after knob POOL_ROOTFS_PROBE_TIMEOUT_S).
#   D1-D6   DRIVEN (`bash bin/fly-pool.sh project-5` against a scratch
#           $HARNESS): no row -> today's argv and no help probe; a row -> the
#           flag; no flag in flyctl -> no flag and one log line; a bad row ->
#           no flag, one line, no probe; push and pull both carry it; no lib
#           -> today's argv.
#   S1      every fly call went to the stub.
# Run from anywhere: bash tests/fly-pool-rootfs.bh-8640-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/pool-rootfs.sh"
SEED="$DIR/worker/jobs/schema.d/202611011704-bh-8640-pool-rootfs-seed.sql"

# ══ K1: the registry carries the knob ═══════════════════════════════════════
mkdir -p "$T/reg/catalog"
cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/"
bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 || bad "K1: lanes-build.sh --write failed on a scratch copy"
REG="$T/reg/catalog/lanes.json"
kf() { jq -r --arg e "$1" --arg f "$2" '.lanes[]? | select(.id=="fly-pool") | .knobs[]? | select(.env==$e) | .[$f] | tostring' "$REG" 2>/dev/null; }
K="$(kf ROOTFS_GB env) $(kf ROOTFS_GB type) $(kf ROOTFS_GB default) $(kf ROOTFS_GB min) $(kf ROOTFS_GB max)"
[ "$K" = "ROOTFS_GB int 0 0 100" ] && ok \
  || bad "K1: ROOTFS_GB must be int, default 0, [0,100], got '$K'"
SK=$(env -i PATH="$PATH" bash -c '. "$1/bin/lib/lane-gate.sh" 2>/dev/null; _lg_setting_key fly-pool ROOTFS_GB project-6-os' _ "$DIR")
[ "$SK" = "lane.fly-pool.project-6-os.rootfs_gb" ] && ok \
  || bad "K1: the settings key must be lane.fly-pool.project-6-os.rootfs_gb, got '$SK'"

# ══ K2: the seed row ════════════════════════════════════════════════════════
if [ ! -s "$SEED" ]; then
  bad "K2: the seed fragment $SEED is missing"
elif ! python3 -I -c 'import sqlite3' 2>/dev/null; then
  echo "K2 skipped: python3 sqlite3 missing"
else
  HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/schema-build.sh" --root "$DIR" --worker jobs --to "$T/schema.sql" >/dev/null 2>&1 \
    || bad "K2: bin/schema-build.sh --to failed"
  GOT=$(python3 -I - "$T/schema.sql" "$SEED" <<'PY' 2>&1
import sqlite3, sys
db = sqlite3.connect(":memory:")
db.executescript(open(sys.argv[1]).read())
q = "SELECT value FROM settings WHERE key='lane.fly-pool.project-6-os.rootfs_gb'"
a = ",".join(r[0] for r in db.execute(q))
db.execute("UPDATE settings SET value='30' WHERE key='lane.fly-pool.project-6-os.rootfs_gb'")
db.executescript(open(sys.argv[2]).read())
b = ",".join(r[0] for r in db.execute(q))
print(a + "|" + b)
PY
)
  [ "$GOT" = "20|30" ] && ok || bad "K2: the seed must be 20 and an operator 30 must survive a re-apply, got '$GOT'"
  grep -qiE '^[[:space:]]*(drop|alter|delete|update|create)[[:space:]]' "$SEED" \
    && bad "K2: the seed fragment holds DDL or a destructive statement" || ok
fi

# ══ U: pool_rootfs_resolve, the real lib ════════════════════════════════════
[ -f "$LIB" ] && ok || bad "U0: bin/lib/pool-rootfs.sh is missing"
# A flyctl stub for the probe: $UF/mode is flag | noflag | empty.
UF="$T/ufly"; mkdir -p "$UF"
cat > "$UF/fly" <<'UFLY'
#!/bin/bash
echo "fly $*" >> "$(dirname "$0")/calls"
case "$(cat "$(dirname "$0")/mode" 2>/dev/null)" in
  flag)   printf 'Usage:\n  flyctl machine run <image> [flags]\n      --rootfs-size int   Root filesystem size in GB\n      --vm-size string\n' ;;
  noflag) printf 'Usage:\n  flyctl machine run <image> [flags]\n      --vm-size string\n' ;;
esac
exit 0
UFLY
chmod +x "$UF/fly"
# uc <case> <help-mode> <want-gb> <want-args> <want-rc> [ROOTFS_GB=...]
uc() {
  local c="$1" hm="$2" wg="$3" wa="$4" wr="$5"; shift 5
  local out
  printf '%s\n' "$hm" > "$UF/mode"
  out=$(env -i PATH="$PATH" FLY="$UF/fly" "$@" bash -c '. "$1" 2>/dev/null || exit 9
    pool_rootfs_resolve; rc=$?
    printf "%s|%s|%s|%s\n" "$PRFS_GB" "${PRFS_ARGS[*]}" "$rc" "$PRFS_WHY"' _ "$LIB")
  local g a r w; IFS='|' read -r g a r w <<<"$out"
  if [ "$g" = "$wg" ] && [ "$a" = "$wa" ] && [ "$r" = "$wr" ] \
     && { { [ "$wr" = 0 ] && [ -z "$w" ]; } || { [ "$wr" = 1 ] && [ -n "$w" ]; }; }; then ok
  else bad "$c: want $wg/'$wa' rc=$wr, got '$out' ($*)"; fi
}
NL=$'\n'
uc U1  flag   0   ""                  0
uc U2  flag   0   ""                  0 ROOTFS_GB=
uc U3  flag   0   ""                  0 ROOTFS_GB=0
uc U3b flag   0   ""                  0 ROOTFS_GB=000
uc U4  flag   20  "--rootfs-size 20"  0 ROOTFS_GB=20
uc U5  flag   20  "--rootfs-size 20"  0 "ROOTFS_GB= 20$NL"
uc U6  flag   20  "--rootfs-size 20"  0 ROOTFS_GB=020
uc U7  flag   100 "--rootfs-size 100" 0 ROOTFS_GB=100
uc U7b flag   1   "--rootfs-size 1"   0 ROOTFS_GB=1
uc U7c flag   8   "--rootfs-size 8"   0 ROOTFS_GB=08
uc U8  flag   0   ""                  1 ROOTFS_GB=101
uc U8b flag   0   ""                  1 ROOTFS_GB=1000
uc U9  flag   0   ""                  1 ROOTFS_GB=abc
uc U9b flag   0   ""                  1 ROOTFS_GB=-5
uc U9c flag   0   ""                  1 ROOTFS_GB=2.5
uc U9d flag   0   ""                  1 ROOTFS_GB=20GB
uc U9e flag   0   ""                  1 ROOTFS_GB=1e3
uc U9f flag   0   ""                  1 "ROOTFS_GB=20; rm -rf /"
uc U10 noflag 0   ""                  1 ROOTFS_GB=20
uc U11 empty  0   ""                  1 ROOTFS_GB=20
# U12: the probe runs only for a valid, nonzero row.
: > "$UF/calls"
uc U12a flag 0 "" 0
uc U12b flag 0 "" 0 ROOTFS_GB=0
uc U12c flag 0 "" 1 ROOTFS_GB=abc
uc U12d flag 0 "" 1 ROOTFS_GB=101
[ ! -s "$UF/calls" ] && ok || bad "U12: no row, 0, abc and 101 must make no fly call, got: $(cat "$UF/calls")"
# U13: the probe answer is cached for the process: two resolves, one help call.
: > "$UF/calls"; printf 'flag\n' > "$UF/mode"
O=$(env -i PATH="$PATH" FLY="$UF/fly" ROOTFS_GB=20 bash -c '. "$1"; pool_rootfs_resolve; pool_rootfs_resolve; echo "$?:${PRFS_ARGS[*]}"' _ "$LIB")
[ "$O" = "0:--rootfs-size 20" ] && [ "$(grep -c -- 'machine run --help' "$UF/calls")" = 1 ] && ok \
  || bad "U13: two resolves must give the flag with one help call, got '$O' / $(cat "$UF/calls")"
# The reasons name the cause.
W=$(env -i PATH="$PATH" FLY="$UF/fly" ROOTFS_GB=abc bash -c '. "$1"; pool_rootfs_resolve; echo "$PRFS_WHY"' _ "$LIB")
grep -q "rootfs_gb 'abc'" <<<"$W" && ok || bad "U14: PRFS_WHY must name the refused value, got '$W'"
printf 'noflag\n' > "$UF/mode"
W=$(env -i PATH="$PATH" FLY="$UF/fly" ROOTFS_GB=20 bash -c '. "$1"; pool_rootfs_resolve; echo "$PRFS_WHY"' _ "$LIB")
[ "$W" = "flyctl has no --rootfs-size flag" ] && ok || bad "U15: PRFS_WHY must say the flag is missing, got '$W'"
# U16: the probe timeout is the knob POOL_ROOTFS_PROBE_TIMEOUT_S (fallback 20).
TB="$T/tbin"; mkdir -p "$TB"
printf '#!/bin/bash\necho "timeout $1" >> "%s/targs"\nshift; exec "$@"\n' "$TB" > "$TB/timeout"; chmod +x "$TB/timeout"
printf 'flag\n' > "$UF/mode"
for tc in "7:7" ":20" "abc:20" "0:20" "500:20" "120:120"; do
  : > "$TB/targs"
  env -i PATH="$TB:$PATH" FLY="$UF/fly" ROOTFS_GB=20 POOL_ROOTFS_PROBE_TIMEOUT_S="${tc%%:*}" \
    bash -c '. "$1"; pool_rootfs_resolve' _ "$LIB" >/dev/null 2>&1
  [ "$(cat "$TB/targs")" = "timeout ${tc#*:}" ] && ok \
    || bad "U16: POOL_ROOTFS_PROBE_TIMEOUT_S='${tc%%:*}' must run 'timeout ${tc#*:}', got '$(cat "$TB/targs")'"
done
K="$(kf POOL_ROOTFS_PROBE_TIMEOUT_S type) $(kf POOL_ROOTFS_PROBE_TIMEOUT_S default) $(kf POOL_ROOTFS_PROBE_TIMEOUT_S min) $(kf POOL_ROOTFS_PROBE_TIMEOUT_S max)"
[ "$K" = "int 20 1 120" ] && ok || bad "K1: POOL_ROOTFS_PROBE_TIMEOUT_S must be int 20 [1,120], got '$K'"

# ══ the driven pool (scaffold of tests/fly-pool-vm-size.bh-8318) ═══════════
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
  *"machine run --help"*)
    printf 'Usage:\n  flyctl machine run <image> [flags]\n'
    [ -e "${FLY_HELP_FLAG:-/nonexistent}" ] && printf '      --rootfs-size int   Root filesystem size in GB\n'
    printf '      --vm-size string\n' ;;
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
           JOBS_RETRIES=0 JOBS_TIMEOUT=5 FLY_SINK="$T/fly.txt" FLY_HELP_FLAG="$T/help-has-flag" \
           FLY_API_TOKEN_project-5=tok-fixture-fly FLY_BIN_DIR="$T/fakebin" "$@"
    bash "${POOL_SCRIPT:-$DIR/bin/fly-pool.sh}" project-5 >/dev/null 2>&1 )
}
reset_case() { # reset_case <key>: a fresh queue with one job of its own key
  local p
  for p in "$QD"/* "$QD"/.??* "$POOLD"/*.json "$POOLD"/.??* "$H/state/pool/project-5"/* \
           "$H/state/build-notes/project-5"/* "$H/state/vercel-deploys"/* "$H/state/settings-cache.json"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$T/fly.txt"; : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  touch "$T/help-has-flag"
  jq -nc --arg k "$1" --arg id "${1#BH-}" '{ticket_id:$id,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-28T00:00:00Z"}' > "$QD/$1.json"
  return 0
}
row() { # row <gb> -> the settings cache lane_env_apply reads
  jq -n --argjson fa "$(date -u +%s)" --arg g "$1" \
    '{fetched_at:$fa,values:{"lane.fly-pool.project-5.rootfs_gb":$g},seeded:{}}' \
    > "$H/state/settings-cache.json"
}
log() { cat "$H/logs/fly-pool.log" 2>/dev/null; }
runline() { grep 'fly machine run' "$T/fly.txt" | grep -v -- 'machine run --help' | head -1; }
launches() { grep 'fly machine run' "$T/fly.txt" | grep -vc -- 'machine run --help'; }
helps() { grep -c -- 'machine run --help' "$T/fly.txt"; }
notused() { grep -c 'rootfs row not used' "$H/logs/fly-pool.log" 2>/dev/null | head -1; }

# ══ D1: no row -> today's argv, byte for byte, and no help probe ════════════
reset_case BH-8641
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--detach --vm-size performance-8x --vm-memory 16384 -e PROJECT=project-5' && ok \
  || bad "D1: no row must give today's argv: $(runline) / $(log)"
grep -q -- '--rootfs-size' <<<"$(runline)" && bad "D1: no row must add no --rootfs-size: $(runline)" || ok
[ "$(helps)" = 0 ] && ok || bad "D1: no row must make no help call: $(cat "$T/fly.txt")"
[ "$(notused)" = 0 ] && ok || bad "D1: no row must log no 'rootfs row not used' line: $(log)"

# ══ D2: row 20, flag present -> the flag after --vm-memory ══════════════════
reset_case BH-8642
row 20
run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-size performance-8x --vm-memory 16384 --rootfs-size 20 -e PROJECT=project-5' && ok \
  || bad "D2: row 20 must reach machine run as --rootfs-size 20: $(runline) / $(log)"
[ "$(launches)" = 1 ] && ok || bad "D2: one machine run launch, got $(launches): $(cat "$T/fly.txt")"
[ "$(notused)" = 0 ] && ok || bad "D2: a used row must log no 'rootfs row not used' line: $(log)"

# ══ D3: row 20, flyctl lacks the flag -> no flag, one line, still spawns ════
reset_case BH-8643
row 20
scratch_rm "$T/help-has-flag"
run_pool LANE_REGISTRY="$REG"
grep -q -- '--rootfs-size' <<<"$(runline)" && bad "D3: no flag in flyctl must add no --rootfs-size: $(runline)" || ok
runline | grep -q -- '--vm-memory 16384 -e PROJECT=project-5' && ok || bad "D3: the argv must be today's: $(runline)"
[ "$(notused)" = 1 ] && ok || bad "D3: one 'rootfs row not used' line, got $(notused): $(log)"
grep 'rootfs row not used' "$H/logs/fly-pool.log" | grep -q 'BH-8643.*flyctl has no --rootfs-size flag.*Fly default rootfs' && ok \
  || bad "D3: the line must name the key, the cause and the default: $(log)"
grep -q 'spawned 1234567890abcd for BH-8643' "$H/logs/fly-pool.log" && ok || bad "D3: the spawn must go ahead: $(log)"

# ══ D4: row abc -> no flag, one line, no help probe ═════════════════════════
reset_case BH-8644
row abc
run_pool LANE_REGISTRY="$REG"
grep -q -- '--rootfs-size' <<<"$(runline)" && bad "D4: a bad row must add no --rootfs-size: $(runline)" || ok
[ "$(notused)" = 1 ] && ok || bad "D4: one 'rootfs row not used' line, got $(notused): $(log)"
[ "$(helps)" = 0 ] && ok || bad "D4: a bad row must make no help call: $(cat "$T/fly.txt")"
grep -q 'spawned 1234567890abcd for BH-8644' "$H/logs/fly-pool.log" && ok || bad "D4: the spawn must go ahead: $(log)"

# ══ D5: the push path and the pull path both carry the flag ═════════════════
for PM in 0 1; do
  reset_case "BH-865$PM"
  row 20
  run_pool LANE_REGISTRY="$REG" POOL_MACHINE_PULL=$PM
  L=$(runline)
  if [ "$PM" = 1 ]; then
    grep -q -- '-e HARNESS_SHA=' <<<"$L" && ok || bad "D5 precondition: POOL_MACHINE_PULL=1 must take the pull path: $L / $(log)"
  else
    grep -q -- '-e HARNESS_SHA=' <<<"$L" && bad "D5 precondition: POOL_MACHINE_PULL=0 must take the push path: $L" || ok
  fi
  grep -q -- '--rootfs-size 20 ' <<<"$L" && ok \
    || bad "D5: POOL_MACHINE_PULL=$PM must carry --rootfs-size 20: $L / $(log)"
done

# ══ D6: no lib in the tree -> today's argv, the tick still spawns ══════════
# The scratch copy of the script runs, so neither source path finds the lib.
reset_case BH-8646
[ -f "$H/bin/fly-pool.sh" ] && ok || bad "D6 precondition: the closure must install bin/fly-pool.sh"
[ -f "$H/bin/lib/pool-rootfs.sh" ] && ok || bad "D6 precondition: the closure must install bin/lib/pool-rootfs.sh"
row 20
mv "$H/bin/lib/pool-rootfs.sh" "$T/pool-rootfs.sh.away" 2>/dev/null
POOL_SCRIPT="$H/bin/fly-pool.sh" run_pool LANE_REGISTRY="$REG"
runline | grep -q -- '--vm-memory 16384 -e PROJECT=project-5' && ok \
  || bad "D6: with no lib the argv must be today's: $(runline) / $(log)"
grep -q 'spawned 1234567890abcd for BH-8646' "$H/logs/fly-pool.log" && ok || bad "D6: the tick must still spawn: $(log)"
mv "$T/pool-rootfs.sh.away" "$H/bin/lib/pool-rootfs.sh" 2>/dev/null

# ══ S1: every fly call went to the stub ═════════════════════════════════════
[ -s "$T/fly.txt" ] && ok || bad "S1: the fly stub recorded no call"

echo "fly-pool-rootfs (BH-8640): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
