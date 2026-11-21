#!/bin/bash
# tests/tsc-heap-knob.bh-9435-test.sh — the tsc heap is a per-project settings row.
#
# What it asserts (BH-9435, plan T5):
#   K1  a row (lane_knob fly-pool TSC_HEAP_MB <project>) of 10240 gives "10240 row".
#   K2  no row, TSC_HEAP_MB=7000 gives "7000 env".
#   K3  no row, no env, a workflow with 6144 and 16 GB RAM gives "11468 ram", not 6144
#       (the TK-3772 exit 134: the workflow's 6144 won over a 16 GB machine).
#   K4  a workflow with 14000 and 16 GB RAM gives "12288 ram" (capped).
#   K4b a workflow with 6144 and 4 GB RAM gives "6144 workflow" (larger than the RAM rule).
#   K4c RAM unreadable and no workflow gives "6144 fallback".
#   K5  a row of "abc" or "0" is ignored.
#   K6  bin/rebase-train.sh hardcodes no max-old-space-size=6144, and calls the resolver.
#   K7  bin/schema-build.sh --check passes and a schema.d fragment seeds
#       lane.fly-pool.project-6-os.tsc_heap_mb; the knob fragment exists.
#   K9  the row is capped at the RAM ceiling (70% of MemTotal, at most 12288):
#       11264 on 16 GB = "11264 row"; 11264 on 4 GB = "2743 row-capped"; 20000 on
#       32 GB = "12288 row-capped"; 11264 with RAM unreadable = "11264 row"; a row
#       equal to the ceiling = "<ceiling> row".
#   K8  the rebase-verify block of bin/run-build.sh sources bin/lib/tsc-heap.sh and
#       passes $PROJECT; it defines no inline resolver.
# No network. Everything under $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset TSC_HEAP_MB TSC_HEAP_MEMINFO

LIB="$DIR/bin/lib/tsc-heap.sh"
[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; echo "tsc-heap-knob: 0 passed, 1 failed"; exit 1; }

mkdir -p "$T/repo/.github/workflows" "$T/norepo" "$T/h/bin/lib"
printf 'MemTotal:       16777216 kB\n' > "$T/mem16"
printf 'MemTotal:        4096000 kB\n' > "$T/mem4"
printf 'garbage\n' > "$T/memnone"
printf 'env:\n  NODE_OPTIONS: --max-old-space-size=6144\n' > "$T/repo/.github/workflows/ci.yml"
mkdir -p "$T/big/.github/workflows"
printf 'env:\n  NODE_OPTIONS: --max-old-space-size=14000\n' > "$T/big/.github/workflows/ci.yml"

# heap_row <cwd> <row> [env assignments...] — the resolver's line. lane_knob is a
# stub that answers <row> for the project-6-os TSC_HEAP_MB key. HARNESS points at an
# empty scratch tree, so no real lane-gate.sh is read.
heap_row() {
  local cwd="$1" row="$2"; shift 2
  ( cd "$cwd" || exit 1
    env -u TSC_HEAP_MB HARNESS="$T/h" PROJECT=project-6-os ROWV="$row" "$@" bash -c '
      lane_knob() { if [ "$1 $2 $3" = "fly-pool TSC_HEAP_MB project-6-os" ]; then echo "$ROWV"; else echo 0; fi; }
      . "$1" || exit 1
      rebase_tsc_heap project-6-os
    ' _ "$LIB" )
}

out=$(heap_row "$T/repo" 10240 TSC_HEAP_MEMINFO="$T/mem16")
[ "$out" = "10240 row" ] && ok || bad "K1: a row of 10240 must give '10240 row' (got '$out')"

out=$(heap_row "$T/repo" 0 TSC_HEAP_MEMINFO="$T/mem16" TSC_HEAP_MB=7000)
[ "$out" = "7000 env" ] && ok || bad "K2: no row and TSC_HEAP_MB=7000 must give '7000 env' (got '$out')"

out=$(heap_row "$T/repo" 0 TSC_HEAP_MEMINFO="$T/mem16")
[ "$out" = "11468 ram" ] && ok || bad "K3: workflow 6144 on 16 GB must give '11468 ram', not 6144 (got '$out')"

out=$(heap_row "$T/big" 0 TSC_HEAP_MEMINFO="$T/mem16")
[ "$out" = "12288 ram" ] && ok || bad "K4: workflow 14000 on 16 GB must give '12288 ram' (got '$out')"

out=$(heap_row "$T/repo" 0 TSC_HEAP_MEMINFO="$T/mem4")
[ "$out" = "6144 workflow" ] && ok || bad "K4b: workflow 6144 on 4 GB must give '6144 workflow' (got '$out')"

out=$(heap_row "$T/norepo" 0 TSC_HEAP_MEMINFO="$T/memnone")
[ "$out" = "6144 fallback" ] && ok || bad "K4c: RAM unreadable and no workflow must give '6144 fallback' (got '$out')"

for r in abc 0 ''; do
  out=$(heap_row "$T/repo" "$r" TSC_HEAP_MEMINFO="$T/mem16")
  [ "$out" = "11468 ram" ] && ok || bad "K5: a row of '$r' must be ignored (got '$out')"
done

# The env never reaches the row read: lane_knob falls back to the env by itself,
# and the source word must still say env.
out=$( cd "$T/repo" && env HARNESS="$T/h" TSC_HEAP_MB=7000 TSC_HEAP_MEMINFO="$T/mem16" bash -c '
  lane_knob() { if [ -n "${TSC_HEAP_MB:-}" ]; then echo "$TSC_HEAP_MB"; else echo 0; fi; }
  . "$1" || exit 1; rebase_tsc_heap project-6-os' _ "$LIB")
[ "$out" = "7000 env" ] && ok || bad "K5b: lane_knob's env fallback must not read as a row (got '$out')"

# K9 the row is capped at the RAM ceiling.
printf 'MemTotal:        4013492 kB\n' > "$T/mem4b"
printf 'MemTotal:       33554432 kB\n' > "$T/mem32"
out=$(heap_row "$T/repo" 11264 TSC_HEAP_MEMINFO="$T/mem16")
[ "$out" = "11264 row" ] && ok || bad "K9: row 11264 on 16 GB must give '11264 row' (got '$out')"
out=$(heap_row "$T/repo" 11264 TSC_HEAP_MEMINFO="$T/mem4b")
[ "$out" = "2743 row-capped" ] && ok || bad "K9: row 11264 on 4 GB must give '2743 row-capped' (got '$out')"
out=$(heap_row "$T/repo" 20000 TSC_HEAP_MEMINFO="$T/mem32")
[ "$out" = "12288 row-capped" ] && ok || bad "K9: row 20000 on 32 GB must give '12288 row-capped' (got '$out')"
out=$(heap_row "$T/repo" 11264 TSC_HEAP_MEMINFO="$T/memnone")
[ "$out" = "11264 row" ] && ok || bad "K9: row 11264 with RAM unreadable must give '11264 row' (got '$out')"
out=$(heap_row "$T/repo" 11468 TSC_HEAP_MEMINFO="$T/mem16")
[ "$out" = "11468 row" ] && ok || bad "K9: a row equal to the ceiling must give '11468 row' (got '$out')"

# K6 the train.
grep -n 'max-old-space-size=6144' "$DIR/bin/rebase-train.sh" >/dev/null \
  && bad "K6: bin/rebase-train.sh still hardcodes max-old-space-size=6144" || ok
grep -q 'tsc-heap.sh' "$DIR/bin/rebase-train.sh" && grep -q 'rebase_tsc_heap' "$DIR/bin/rebase-train.sh" \
  && ok || bad "K6: bin/rebase-train.sh must source bin/lib/tsc-heap.sh and call rebase_tsc_heap"

# K7 the seed row and the knob.
if ( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/schema-build.sh --check ) > "$T/schema.out" 2>&1; then ok
else bad "K7: bin/schema-build.sh --check failed: $(tail -3 "$T/schema.out")"; fi
grep -l "lane.fly-pool.project-6-os.tsc_heap_mb" "$DIR"/worker/jobs/schema.d/*.sql >/dev/null 2>&1 \
  && ok || bad "K7: no schema.d fragment seeds lane.fly-pool.project-6-os.tsc_heap_mb"
KF="$DIR/catalog/lanes.d/fly-pool.knobs.d/TSC_HEAP_MB.json"
if [ -r "$KF" ] && jq -e '.env == "TSC_HEAP_MB" and .settable == true and .read_in == "bin/lib/tsc-heap.sh"' "$KF" >/dev/null 2>&1; then ok
else bad "K7: $KF must register TSC_HEAP_MB as settable, read in bin/lib/tsc-heap.sh"; fi

# K8 the rebase verify reads the shared resolver.
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> rebase verify/{f=1;next} /^# <<< rebase verify/{exit} f' "$RB" > "$T/stage.sh"
grep -q 'bin/lib/tsc-heap.sh' "$T/stage.sh" && ok || bad "K8: the rebase-verify block must source bin/lib/tsc-heap.sh"
grep -q 'rebase_tsc_heap "\$PROJECT"' "$T/stage.sh" && ok || bad "K8: the rebase-verify block must pass \$PROJECT to rebase_tsc_heap"
grep -q '^rebase_tsc_heap() {' "$T/stage.sh" && bad "K8: the rebase-verify block still defines an inline rebase_tsc_heap" || ok

echo "tsc-heap-knob: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
