#!/bin/bash
# tests/pool-alloc.bh-7877-test.sh — the fleet slot allocator (BH-7877):
# bin/lib/pool-alloc.sh (pa_allocate, pa_inputs, pa_tick, pa_clamp) and the
# clamp fragment config/fly-pool.d/3550-fleet-alloc-clamp.sh.
#
#   A1-A4   the ticket's acceptance cases (weights, pool_cap, ceiling, no row)
#   E1-E10  edges: no free slot, live over the fleet, one project, no demand,
#           fractional ties, bad weights, a prefix-sharing weight row, cap 0,
#           live over cap, an unreadable spend read
#   W1-W4   the grant file pa_tick writes, and what it removes
#   C1-C6   the clamp fragment, sourced with the variables bin/fly-pool.sh has
#   S1      the project-6-os weight seed
# Each case runs in its own scratch tree with the REAL bin/pool-cap.sh (a cap
# is a number in flags/fly-pool-<p>). No network: no jobs client is installed.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pool-alloc.bh-7877-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
unset POOL_AUTOSCALE POOL_CAP_MAX JOBS_URL HARNESS_SECRET ROUTING_ROWS PA_PARALLEL FLEET_SLOTS WEIGHT
LIB=bin/lib/pool-alloc.sh
FRAG=config/fly-pool.d/3550-fleet-alloc-clamp.sh
NOW=1764000000   # PA_NOW: a fixed epoch, no clock read

# tree <name> — a scratch harness root in S
tree() {
  S="$T/$1"
  mkdir -p "$S/flags" "$S/logs" "$S/state/fly-pool" "$S/state/build-queue" "$S/env"
  scratch_install_closure "$LIB" "$S" >/dev/null || { bad "$1: closure install"; return 1; }
  scratch_install_closure bin/pool-cap.sh "$S" >/dev/null || { bad "$1: pool-cap install"; return 1; }
  : > "$S/env/global.env"
}
# cache <values-json> [seeded-json] — state/settings-cache.json as lane-gate writes it
cache() {
  printf '{"fetched_at":%s,"values":%s,"seeded":%s}\n' "$NOW" "$1" "${2:-{\}}" > "$S/state/settings-cache.json"
}
# proj <p> <queued> <live> [cap] — the pool flag, queue files and live machines
proj() {
  local i
  if [ -n "${4:-}" ]; then echo "$4" > "$S/flags/fly-pool-$1"; else : > "$S/flags/fly-pool-$1"; fi
  mkdir -p "$S/state/build-queue/$1" "$S/state/fly-pool/$1"
  for ((i = 1; i <= $2; i++)); do echo '{}' > "$S/state/build-queue/$1/K-$i.json"; done
  echo '{}' > "$S/state/build-queue/$1/K-parked.failed.json"
  for ((i = 1; i <= $3; i++)); do echo '{}' > "$S/state/fly-pool/$1/m-fixture-$i.json"; done
}
# lib <cmd...> — run in a subshell with the lib sourced against S
lib() { ( export HARNESS="$S" PA_NOW="$NOW"; . "$S/$LIB" || exit 99; "$@" ); }
grant() { awk '{print $5}' "$S/state/fly-pool-alloc/$1" 2>/dev/null; }
line()  { cat "$S/state/fly-pool-alloc/$1" 2>/dev/null; }
alloc_lines() { local n; n=$(grep -c '\[pool-alloc\]' "$S/logs/fly-pool.log" 2>/dev/null); echo "${n:-0}"; }

# ══ A1: fleet 30, A w3 q50, B w1 q50, C w1 q0 ═══════════════════════════════
tree pure || exit 1
OUT=$(printf 'a 3 50\nb 1 50\nc 1 0\n' | lib pa_allocate 30)
[ "$OUT" = $'a 23\nb 7\nc 0' ] && ok || bad "A1 pa_allocate: want a 23/b 7/c 0, got '$(tr '\n' ' ' <<<"$OUT")'"
A=$(awk '$1=="a"{print $2}' <<<"$OUT"); B=$(awk '$1=="b"{print $2}' <<<"$OUT")
SUM=$(awk '{s+=$2} END{print s+0}' <<<"$OUT")
[ "${A:-0}" -ge 22 ] && [ "${A:-0}" -le 23 ] && [ "${B:-0}" -ge 7 ] && [ "${B:-0}" -le 8 ] && [ "$SUM" -le 30 ] \
  && ok || bad "A1 ranges: a=$A b=$B sum=$SUM"
# The same through pa_tick: the weights come from the settings cache.
tree a1 && {
  proj a 50 0; proj b 50 0; proj c 0 0
  cache '{"lane.fly-pool.fleet_slots":"30","lane.fly-pool.a.weight":"3"}'
  lib pa_tick a b c
  [ "$(grant a)/$(grant b)/$(grant c)" = 23/7/0 ] && ok || bad "A1 pa_tick: grants $(grant a)/$(grant b)/$(grant c)"
  [ "$(alloc_lines)" = 1 ] && ok || bad "A1: one [pool-alloc] line, got $(alloc_lines)"
  grep -q '\[pool-alloc\] fleet=30 live=0 free=30 a:w=3,q=50,g=23.* b:w=1,q=50,g=7.* idle=1' "$S/logs/fly-pool.log" \
    && ok || bad "A1 line: $(cat "$S/logs/fly-pool.log" 2>/dev/null)"
}

# ══ A2: a pool_cap of 10 caps a at 10, the rest goes to b ═══════════════════
tree a2 && {
  proj a 50 0 10; proj b 50 0
  cache '{"lane.fly-pool.fleet_slots":"30","lane.fly-pool.a.weight":"3"}'
  lib pa_tick a b
  [ "$(grant a)/$(grant b)" = 10/20 ] && ok || bad "A2: want 10/20, got $(grant a)/$(grant b)"
  IN=$(lib pa_inputs a b)
  grep -qx 'a 3 50 0 10' <<<"$IN" && ok || bad "A2 pa_inputs: want 'a 3 50 0 10', got '$IN'"
}

# ══ A3: a over its daily ceiling gets 0, b gets the fleet ═══════════════════
tree a3 && {
  proj a 50 0; proj b 50 0
  cache '{"lane.fly-pool.fleet_slots":"30","lane.fly-pool.a.weight":"3"}'
  ( export HARNESS="$S" PA_NOW="$NOW"; . "$S/$LIB" || exit 99
    pc_eval() { PC_STATE=under; [ "$1" = a ] && PC_STATE=over; return 0; }
    pa_tick a b )
  [ "$(grant a)/$(grant b)" = 0/30 ] && ok || bad "A3: want 0/30, got $(grant a)/$(grant b)"
}

# ══ A4: no fleet_slots row: no file, an old file removed, no line ═══════════
tree a4 && {
  proj a 50 0; proj b 50 0
  cache '{"lane.fly-pool.a.weight":"3"}'
  mkdir -p "$S/state/fly-pool-alloc"; echo "fleet-alloc v1 1 1 1 1 1 0 1" > "$S/state/fly-pool-alloc/a"
  lib pa_tick a b; RC=$?
  [ "$RC" = 0 ] && ok || bad "A4: rc $RC"
  [ -z "$(ls -A "$S/state/fly-pool-alloc" 2>/dev/null)" ] && ok || bad "A4: files left: $(ls -A "$S/state/fly-pool-alloc")"
  [ "$(alloc_lines)" = 0 ] && ok || bad "A4: no [pool-alloc] line, got $(alloc_lines)"
  # fleet_slots 0 is the same off switch
  cache '{"lane.fly-pool.fleet_slots":"0"}'
  echo "fleet-alloc v1 1 1 1 1 1 0 1" > "$S/state/fly-pool-alloc/b"
  lib pa_tick a b
  [ ! -e "$S/state/fly-pool-alloc/b" ] && [ "$(alloc_lines)" = 0 ] && ok || bad "A4: row 0 must remove b and log nothing"
  # no cache at all
  rm -f "$S/state/settings-cache.json"
  lib pa_tick a b
  [ -z "$(ls -A "$S/state/fly-pool-alloc" 2>/dev/null)" ] && ok || bad "A4: no cache must write no file"
}

# ══ E1-E5: pure allocator edges ══════════════════════════════════════════════
S="$T/pure"
OUT=$(printf 'a 3 50\nb 1 50\n' | lib pa_allocate 0)
[ "$OUT" = $'a 0\nb 0' ] && ok || bad "E1 free 0: '$(tr '\n' ' ' <<<"$OUT")'"
OUT=$(printf 'a 1 4\n' | lib pa_allocate 30)
[ "$OUT" = 'a 4' ] && ok || bad "E3 one project demand 4: '$OUT'"
OUT=$(printf 'a 1 0\nb 2 0\n' | lib pa_allocate 30)
[ "$OUT" = $'a 0\nb 0' ] && ok || bad "E4 no demand: '$(tr '\n' ' ' <<<"$OUT")'"
# E5: equal fractions: larger weight first, then the name (LC_ALL=C).
OUT=$(printf 'a 1 10\nb 3 10\n' | lib pa_allocate 2)
[ "$OUT" = $'a 0\nb 2' ] && ok || bad "E5 weight tie-break: '$(tr '\n' ' ' <<<"$OUT")'"
OUT=$(printf 'y 1 10\nx 1 10\n' | lib pa_allocate 3)
[ "$OUT" = $'y 1\nx 2' ] && ok || bad "E5 name tie-break: '$(tr '\n' ' ' <<<"$OUT")'"
# Water-fill: a small demand leaves, its unused share is shared again.
OUT=$(printf 'a 1 2\nb 1 50\nc 1 50\n' | lib pa_allocate 30)
[ "$OUT" = $'a 2\nb 14\nc 14' ] && ok || bad "water-fill: '$(tr '\n' ' ' <<<"$OUT")'"
# Never more than free, never more than demand, on a wide fleet.
OUT=$(for i in $(seq 1 40); do echo "p$i $(( i % 7 + 1 )) $(( i % 5 ))"; done | lib pa_allocate 37)
SUM=$(awk '{s+=$2} END{print s+0}' <<<"$OUT")
[ "$SUM" -le 37 ] && [ "$SUM" -eq 37 ] && ok || bad "wide fleet: sum $SUM, want 37"
OVER=$(paste <(for i in $(seq 1 40); do echo $(( i % 5 )); done) <(awk '{print $2}' <<<"$OUT") | awk '$2 > $1' | wc -l)
[ "$OVER" = 0 ] && ok || bad "wide fleet: $OVER grants over their demand"

# ══ E2: fleet below the live total: free 0, grant 0, target = live ══════════
tree e2 && {
  proj a 5 4; proj b 5 3
  cache '{"lane.fly-pool.fleet_slots":"5"}'
  lib pa_tick a b
  [ "$(grant a)/$(grant b)" = 0/0 ] && ok || bad "E2 grants: $(grant a)/$(grant b)"
  [ "$(awk '{print $4}' "$S/state/fly-pool-alloc/a")" = 4 ] && ok || bad "E2 target of a = live 4: $(line a)"
  grep -q 'fleet=5 live=7 free=0' "$S/logs/fly-pool.log" && ok || bad "E2 line: $(cat "$S/logs/fly-pool.log")"
}

# ══ E6, E7: weight rows ══════════════════════════════════════════════════════
tree e6 && {
  for p in pa pb pc pd pe pf pg ph; do proj "$p" 1 0; done
  cache '{"lane.fly-pool.fleet_slots":"30","lane.fly-pool.pa.weight":"abc","lane.fly-pool.pb.weight":"0","lane.fly-pool.pc.weight":"-2","lane.fly-pool.pd.weight":"1.5","lane.fly-pool.pe.weight":" 7 ","lane.fly-pool.pf.weight":"101","lane.fly-pool.pg.weight":"500","lane.fly-pool.ph.weight":"100"}'
  IN=$(lib pa_inputs pa pb pc pd pe pf pg ph)
  # 101 and 500 are past WEIGHT.json max (100): they read as 1; 100 is kept.
  [ "$(awk '{printf "%s ", $2}' <<<"$IN")" = "1 1 1 1 7 1 1 100 " ] && ok || bad "E6 weights: '$(tr '\n' '|' <<<"$IN")'"
}
tree e7 && {
  proj project-6-os 1 0; proj project-6-os-staging 1 0
  cache '{"lane.fly-pool.fleet_slots":"30","lane.fly-pool.project-6-os-staging.weight":"5"}'
  IN=$(lib pa_inputs project-6-os project-6-os-staging)
  grep -qx 'project-6-os 1 1 0 1' <<<"$IN" && ok || bad "E7 prefix row leaked into project-6-os: '$IN'"
  grep -qx 'project-6-os-staging 5 1 0 1' <<<"$IN" && ok || bad "E7 the row key is lowercased: '$IN'"
}

# ══ E8-E10: demand ═══════════════════════════════════════════════════════════
tree e8 && {
  proj a 9 2 0
  cache '{"lane.fly-pool.fleet_slots":"30"}'
  [ "$(lib pa_inputs a)" = 'a 1 9 2 9' ] && ok || bad "E8 cap 0 = no cap: '$(lib pa_inputs a)'"
}
tree e9 && {
  proj a 9 6 5
  cache '{"lane.fly-pool.fleet_slots":"30"}'
  [ "$(lib pa_inputs a)" = 'a 1 9 6 0' ] && ok || bad "E9 live over cap = 0: '$(lib pa_inputs a)'"
}
tree e10 && {
  proj a 9 0
  cache '{"lane.fly-pool.fleet_slots":"30"}'
  OUT=$( export HARNESS="$S" PA_NOW="$NOW"; . "$S/$LIB" || exit 99
    pc_eval() { PC_STATE=""; PC_REASON=x; return 2; }
    pa_inputs a )
  [ "$OUT" = 'a 1 9 0 9' ] && ok || bad "E10 spend unreadable is not over: '$OUT'"
}

# ══ W1-W4: the grant file ════════════════════════════════════════════════════
tree w1 && {
  proj a 6 2; proj b 0 1
  cache '{"lane.fly-pool.fleet_slots":"30"}'
  mkdir -p "$S/state/fly-pool-alloc"; echo "fleet-alloc v1 1 9 9 1 9 0 30" > "$S/state/fly-pool-alloc/gone"
  lib pa_tick a b
  [ "$(line a)" = "fleet-alloc v1 $NOW 8 6 1 6 2 30" ] && ok || bad "W1 a: '$(line a)'"
  [ "$(line b)" = "fleet-alloc v1 $NOW 1 0 1 0 1 30" ] && ok || bad "W1 b (no queue, grant 0): '$(line b)'"
  [ ! -e "$S/state/fly-pool-alloc/gone" ] && ok || bad "W3: a project not in the tick keeps its file"
  [ -z "$(ls -A "$S/state/fly-pool-alloc" | grep '^\.')" ] && ok || bad "W1: a tmp file is left: $(ls -A "$S/state/fly-pool-alloc")"
}
tree w4 && {
  proj a 6 0
  cache '{}' '{"lane.fly-pool.fleet_slots":"30"}'
  lib pa_tick a
  [ ! -e "$S/state/fly-pool-alloc/a" ] && ok || bad "W4: a registry-seed fleet_slots row must not turn it on"
  cache '{"lane.fly-pool.fleet_slots":"30"}'
  mkdir -p "$S/state/fly-pool-alloc"; echo "fleet-alloc v1 1 9 9 1 9 0 30" > "$S/state/fly-pool-alloc/a"
  ( export POOL_AUTOSCALE=0; lib pa_tick a )
  [ ! -e "$S/state/fly-pool-alloc/a" ] && [ "$(alloc_lines)" = 0 ] && ok \
    || bad "W4: POOL_AUTOSCALE=0 must remove the file and log nothing ($(line a))"
}

# ══ C1-C6: the clamp fragment ════════════════════════════════════════════════
# clamp <budget> <live> <hotfix> — sources the fragment as bin/fly-pool.sh
# reaches it; prints AFTER <budget> <hotfix>, or nothing when it exits.
clamp() {
  ( HARNESS="$S"; P=alpha; BUDGET="$1"; LIVE="$2"; HOTFIX_EXTRA="$3"
    say() { echo "SAY $*"; }
    # shellcheck disable=SC1090
    . "$REPO/$FRAG"
    echo "AFTER $BUDGET $HOTFIX_EXTRA" )
}
tree c && {
  mkdir -p "$S/state/fly-pool-alloc"; G="$S/state/fly-pool-alloc/alpha"
  echo "fleet-alloc v1 $NOW 12 7 1 20 5 30" > "$G"
  OUT=$(clamp 20 5 0)
  grep -qx 'AFTER 7 0' <<<"$OUT" && ok || bad "C1 want BUDGET 7: '$OUT'"
  grep -qx 'SAY fleet-alloc: spawning 20->7 (target 12, live 5, grant 7)' <<<"$OUT" && ok || bad "C1 say line: '$OUT'"
  rm -f "$G"
  [ "$(clamp 20 5 0)" = 'AFTER 20 0' ] && ok || bad "C2 no file: '$(clamp 20 5 0)'"
  echo "fleet-alloc v1 $NOW 3 0 1 20 5 30" > "$G"
  OUT=$(clamp 20 5 0)
  [ "$OUT" = 'SAY fleet-alloc: spawning 20->0 (target 3, live 5, grant 0)' ] && ok || bad "C3 target < live must exit with BUDGET 0: '$OUT'"
  OUT=$(clamp 20 5 1)
  grep -qx 'AFTER 0 1' <<<"$OUT" && ok || bad "C4 a hotfix still spawns: '$OUT'"
  for bad_line in "fleet-alloc v2 $NOW 3 0 1 20 5 30" "fleet-alloc v1 $NOW 3 0" "fleet-alloc v1 $NOW x 0 1 20 5 30" ""; do
    printf '%s\n' "$bad_line" > "$G"
    [ "$(clamp 20 5 0)" = 'AFTER 20 0' ] && ok || bad "C5 '$bad_line' must not clamp: '$(clamp 20 5 0)'"
  done
  echo "fleet-alloc v1 $NOW 3 0 1 20 5 30" > "$S/state/fly-pool-alloc/beta"
  rm -f "$G"
  [ "$(clamp 20 5 0)" = 'AFTER 20 0' ] && ok || bad "C5 another project's file must not clamp"
  echo "fleet-alloc v1 $NOW 40 35 1 20 5 30" > "$G"
  [ "$(clamp 20 5 0)" = 'AFTER 20 0' ] && ok || bad "C6 grant over BUDGET: no change, no say: '$(clamp 20 5 0)'"
}
# W2: pa_tick writes, the fragment reads (one writer, one reader).
tree w2 && {
  proj alpha 20 5; proj beta 20 0
  cache '{"lane.fly-pool.fleet_slots":"17"}'
  lib pa_tick alpha beta
  OUT=$(clamp 20 5 0)
  grep -qx 'AFTER 6 0' <<<"$OUT" && ok || bad "W2 round trip: free 12, 6 each, want BUDGET 6: '$OUT' ($(line alpha))"
}
# The render carries the fragment.
grep -qF 'pa_clamp "$P"' "$REPO/bin/fly-pool.sh" && ok || bad "bin/fly-pool.sh does not carry the clamp (run bin/fly-pool-build.sh --write)"

# ══ S1: the seed ═════════════════════════════════════════════════════════════
SEED=$(ls "$REPO"/worker/jobs/schema.d/*-bh-7877-pool-weight-seed.sql 2>/dev/null | head -1)
if [ -n "$SEED" ]; then
  grep -q "INSERT OR IGNORE INTO settings" "$SEED" && grep -q "'lane.fly-pool.project-6-os.weight','3'" "$SEED" \
    && ok || bad "S1: the seed must INSERT OR IGNORE lane.fly-pool.project-6-os.weight = 3"
  ! grep -q "fleet_slots'" "$SEED" && ok || bad "S1: the seed must hold no fleet_slots row"
  ! grep -q "'registry-seed'" "$SEED" && ok || bad "S1: a registry-seed row is not in .values, so the weight would not apply"
else
  bad "S1: no worker/jobs/schema.d/*-bh-7877-pool-weight-seed.sql"
fi

echo "pool-alloc.bh-7877: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
