#!/bin/bash
# tests/fly-pool-tick-alloc.bh-7877-test.sh — the fleet slot allocator through
# the REAL bin/fly-pool-tick.sh (BH-7877), in a scratch hub root with a
# recorder in place of bin/fly-pool.sh and of ptb_split. No network: no
# JOBS_URL, so the settings cache is read as it is on disk.
#   T1  no fleet_slots row: no grant file, a stale file is removed, no
#       [pool-alloc] line, every project tick still starts
#   T2  row 30, a w3 q50 / b w1 q50 / c w1 q0: grants 23/7/0, exactly one
#       [pool-alloc] line, no ALERTS line
#   T3  each project tick sees its grant file when it starts
#   T4  ptb_split runs after the grant files are written
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-tick-alloc.bh-7877-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
unset POOL_AUTOSCALE POOL_CAP_MAX HUB_BOX_NAME BOX_NAME JOBS_URL HARNESS_SECRET POOL_TICK_MAX_PARALLEL ROUTING_ROWS

tree() { # tree <dir> — a scratch hub root in S
  S="$1"
  mkdir -p "$S/flags" "$S/logs" "$S/locks" "$S/env" "$S/fly" "$S/state/fly" "$S/state/fly-pool" "$S/state/build-queue"
  scratch_install_closure bin/fly-pool-tick.sh "$S" >/dev/null || { bad "closure install failed"; exit 1; }
  scratch_install_closure bin/pool-cap.sh "$S" >/dev/null || { bad "pool-cap install failed"; exit 1; }
  cp "$DIR/bin/alert-line.sh" "$S/bin/"
  for s in fly-lock-guard fly-pool-rows-parity pool-budget fly-onboard; do printf '#!/bin/bash\nexit 0\n' > "$S/bin/$s.sh"; done
  # The recorder: the project and the grant line it found at its start.
  cat > "$S/bin/fly-pool.sh" <<'EOF'
#!/bin/bash
g=$(cat "$HARNESS/state/fly-pool-alloc/$1" 2>/dev/null)
echo "$1 grant=[$g]" >> "$HARNESS/ticked.txt"
exit 0
EOF
  # ptb_split: every project stays on the hub; it records the grant files it saw.
  cat > "$S/bin/lib/pool-tick-batch.sh" <<'EOF'
ptb_split() { PTB_HUB=("$@"); ls "$HARNESS/state/fly-pool-alloc" 2>/dev/null | tr '\n' ' ' > "$HARNESS/ptb-saw.txt"; echo >> "$HARNESS/ptb-saw.txt"; }
EOF
  chmod +x "$S/bin"/*.sh
  : > "$S/env/global.env"
}
proj() { # proj <p> <queued>
  local i
  : > "$S/flags/fly-pool-$1"
  mkdir -p "$S/state/build-queue/$1" "$S/state/fly-pool/$1"
  for ((i = 1; i <= $2; i++)); do echo '{}' > "$S/state/build-queue/$1/K-$i.json"; done
}
cache() { printf '{"fetched_at":1764000000,"values":%s,"seeded":{}}\n' "$1" > "$S/state/settings-cache.json"; }
# POOL_TICK_MAX_PARALLEL=0 (no cap): unset, the cap is nproc, and on a 2-core
# host the third project waits for the next start (BH-7509), so T1 saw only a
# and b. This suite is about the allocator, not the tick cap.
tick() { ( export HARNESS="$S" BOX_NAME=box-fixture-2 POOL_TICK_MAX_PARALLEL=0; bash "$DIR/bin/fly-pool-tick.sh" >> "$S/wrapper.out" 2>&1 ); }
grant() { awk '{print $5}' "$S/state/fly-pool-alloc/$1" 2>/dev/null; }
alloc_lines() { local n; n=$(grep -c '\[pool-alloc\]' "$S/logs/fly-pool.log" 2>/dev/null); echo "${n:-0}"; }

# ══ T1: no row ═══════════════════════════════════════════════════════════════
tree "$T/t1"
proj a 50; proj b 50; proj c 0
cache '{"lane.fly-pool.a.weight":"3"}'
mkdir -p "$S/state/fly-pool-alloc"; echo "fleet-alloc v1 1 1 1 1 1 0 30" > "$S/state/fly-pool-alloc/a"
tick
[ -z "$(ls -A "$S/state/fly-pool-alloc" 2>/dev/null)" ] && ok || bad "T1: grant files left: $(ls -A "$S/state/fly-pool-alloc")"
[ "$(alloc_lines)" = 0 ] && ok || bad "T1: no [pool-alloc] line, got $(alloc_lines)"
[ "$(grep -c 'grant=\[\]' "$S/ticked.txt" 2>/dev/null)" = 3 ] && ok \
  || bad "T1: a, b and c must each tick with no grant: $(cat "$S/ticked.txt" 2>/dev/null) / $(cat "$S/wrapper.out")"

# ══ T2-T4: row 30 ════════════════════════════════════════════════════════════
tree "$T/t2"
proj a 50; proj b 50; proj c 0
cache '{"lane.fly-pool.fleet_slots":"30","lane.fly-pool.a.weight":"3"}'
tick
[ "$(grant a)/$(grant b)/$(grant c)" = 23/7/0 ] && ok || bad "T2: grants $(grant a)/$(grant b)/$(grant c) / $(cat "$S/wrapper.out")"
[ "$(alloc_lines)" = 1 ] && ok || bad "T2: exactly one [pool-alloc] line, got $(alloc_lines)"
grep -q '\[pool-alloc\] fleet=30 live=0 free=30 a:w=3,q=50,g=23' "$S/logs/fly-pool.log" && ok || bad "T2 line: $(cat "$S/logs/fly-pool.log")"
[ ! -s "$S/logs/ALERTS.log" ] && ok || bad "T2: no ALERTS line: $(cat "$S/logs/ALERTS.log")"
grep -q '^a grant=\[fleet-alloc v1 [0-9]* 23 23 3 50 0 30\]$' "$S/ticked.txt" && ok || bad "T3 a: $(cat "$S/ticked.txt")"
grep -q '^b grant=\[fleet-alloc v1 [0-9]* 7 7 1 50 0 30\]$' "$S/ticked.txt" && ok || bad "T3 b: $(cat "$S/ticked.txt")"
[ "$(cat "$S/ptb-saw.txt" 2>/dev/null)" = "a b c " ] && ok || bad "T4: ptb_split must run after the grants: saw '$(cat "$S/ptb-saw.txt" 2>/dev/null)'"
# A second tick rewrites, it does not add.
tick
[ "$(alloc_lines)" = 2 ] && [ "$(grant a)" = 23 ] && ok || bad "T2: the second tick must rewrite a's grant (23) and log one more line"

echo "fly-pool-tick-alloc.bh-7877: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
