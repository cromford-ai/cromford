#!/bin/bash
# tests/fly-pool-hotfix-first-slot.bh-7382-test.sh — with a hotfix and a normal
# ticket queued and ONE free slot, the hotfix starts (BH-7382, acceptance 3).
#
# This holds on main since #368/#418 (hotfix_first in bin/fly-pool.sh). On
# 2026-10-18 the project-6-os hotfixes did not start because every build on
# the box was refused at the context gate (the harness sync, fixed in
# bin/harness-sync.sh by the same ticket), not because of the order. This
# suite pins the ticket's own criterion through the real bin/fly-pool.sh.
#   c1  cap 2, one live build, NORM-1 (older) and HF-1 (hotfix) queued:
#       the one machine spawned is HF-1's, and NORM-1 stays queued.
#   c2  the same with HOTFIX_LANE=0: the older NORM-1 is spawned, which proves
#       c1 is the hotfix rule and not the mtime order.
#
# Run from anywhere: tests/fly-pool-hotfix-first-slot.bh-7382-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX HOTFIX HOTFIX_LANE FLY_API_TOKEN FLY_ACCESS_TOKEN

H="$T/h"
QD="$H/state/build-queue/tproj"; MD="$H/state/fly-pool/tproj"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$MD" "$QD" "$H/builds" "$T/fakebin"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
printf 'HARNESS_SECRET=fixture-secret\n' > "$H/env/global.env"
: > "$H/env/fly.env"
printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf 'registry.fly.io/builder-tproj:deployment-01\n' > "$H/state/fly/tproj.image"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/alert-line.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# flyctl: the live machine m0 is mid-build (started, fresh heartbeat, no
# RESULT), so the reap leaves it alone; `machine run` gets one fixed id per call.
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
case "\$*" in
  *"machines list"*)  echo '[]' ;;
  *"machine status"*) echo "State: started" ;;
  *stat*heartbeat*)   echo 5 ;;
  *RESULT*)           : ;;
  *"machine run"*) n=\$(( \$(cat "$T/runs" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/runs"
                   printf 'Machine ID: 4100000000000%s\n' "\$n" ;;
  *) : ;;
esac
exit 0
FLY
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

setup() {
  local p
  for p in "$QD"/* "$MD"/* "$T/runs"; do [ -e "$p" ] && scratch_rm "$p"; done
  : > "$H/logs/fly-pool.log"
  printf '2\n' > "$H/flags/fly-pool-tproj"
  jq -nc '{machine:"m0",key:"LV-0",ticket_id:"10",attempt:0,deferrals:0,deaths:0}' > "$MD/m0.json"
  jq -nc '{ticket_id:"11",key:"NORM-1",attempt:0,deferrals:0,deaths:0}' > "$QD/NORM-1.json"
  jq -nc '{ticket_id:"12",key:"HF-1",attempt:0,deferrals:0,deaths:0,hotfix:true}' > "$QD/HF-1.json"
  # The plain job is the OLDER one, with an absolute stamp: mtime order alone
  # hands the slot to NORM-1, so HF-1 winning is the hotfix rule.
  touch -d '2020-01-01' "$QD/NORM-1.json"
}
tick() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" FLY_API_TOKEN_TPROJ=tok-fixture-proj "$@"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
}
spawned() { local f; for f in "$MD"/*.json; do [ "$(basename "$f")" = m0.json ] || jq -r '.key' "$f" 2>/dev/null; done | sort | tr '\n' ' '; }

# c1 one free slot: the hotfix takes it.
setup
tick
[ "$(spawned)" = "HF-1 " ] && ok || bad "c1: the one free slot must start the hotfix (spawned: '$(spawned)')"
[ -f "$QD/NORM-1.json" ] && ok || bad "c1: the normal ticket must still be queued"
[ -f "$QD/HF-1.json" ] && bad "c1: the hotfix's queue file must be gone once it is spawned" || ok
grep -q 'pool tproj: queued=2 running=1 spawning=1 cap=2 hotfix=1' "$H/logs/fly-pool.log" && ok \
  || bad "c1: the tick line must show one slot for two queued: $(grep -o 'pool tproj: .*' "$H/logs/fly-pool.log")"

# c2 near miss: without the hotfix lane the older normal ticket takes the slot.
setup
tick HOTFIX_LANE=0
[ "$(spawned)" = "NORM-1 " ] && ok || bad "c2: HOTFIX_LANE=0 must spawn the older NORM-1 (spawned: '$(spawned)')"
[ -f "$QD/HF-1.json" ] && ok || bad "c2: the hotfix stays queued without the lane"

echo "fly-pool-hotfix-first-slot: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
