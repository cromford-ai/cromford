#!/bin/bash
# tests/mc-backstop-unchanged-skip.bh-8310-test.sh — the */5 backstop skips a
# candidate whose last MC_BACKSTOP_UNCHANGED_SKIP (default 3) keyed runs left
# its pr-state.tsv row unchanged, so one stuck row cannot hold the only slot
# (BH-8310).
#
# The REAL bin/merge-conductor-backstop.sh is driven against a recorder
# conductor that records its key and, by REC_MODE, leaves the row alone, edits
# it, or exits 124 (what `timeout` returns when it kills a run). Each case
# builds its own scratch harness.
#   U1  fires 1-3 run A and log no skip line; fire 4 logs exactly one skip line
#       for A and starts no run for A
#   U2  MAXR=1, A stuck and B fresh: fire 4 starts B
#   U3  a new head on A's row: the next fire runs A again, the counter resets
#   U4  knob unset = 3; MC_BACKSTOP_UNCHANGED_SKIP=0 never skips; =2 skips on fire 3
#   U5  a run that ends 124 (timeout) still counts
#   U6  a counter of a key that is no longer a candidate is removed by the next fire
#   U7  a run that changes its row removes the counter
# Run from anywhere: tests/mc-backstop-unchanged-skip.bh-8310-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v setsid >/dev/null && command -v flock >/dev/null || { echo "FAIL: setsid/flock missing"; exit 1; }
[ -f "$DIR/bin/merge-conductor-backstop.sh" ] || exit 1   # impact: this suite drives the backstop
HA=$(printf 'a%.0s' $(seq 40)); HB=$(printf 'b%.0s' $(seq 40)); HC=$(printf 'c%.0s' $(seq 40))

mk() { # mk <case>: scratch harness $T/<case>/r with the recorder conductor
  local C="$T/$1" R="$T/$1/r"
  mkdir -p "$R/bin/lib" "$R/logs" "$R/locks" "$R/state/merge-conductor" "$R/flags" "$R/env" "$C/rbin" "$C/rec" || return 1
  ( cd "$DIR" && scratch_install_closure bin/merge-conductor-backstop.sh "$R" ) >/dev/null || return 1
  : > "$R/env/global.env"
  cat > "$R/bin/merge-conductor.sh" <<EOF
#!/bin/bash
printf 'key=%s\n' "\${MC_ONLY_PR:-unset}" >> "$C/rec/runs"
case "\${REC_MODE:-}" in
  edit) awk -F'\t' -v OFS='\t' -v k="\$MC_ONLY_PR" '\$1 == k { \$7 = "edited-" \$7 } { print }' "$R/state/merge-conductor/pr-state.tsv" > "$C/rows.tmp" \
          && mv "$C/rows.tmp" "$R/state/merge-conductor/pr-state.tsv" ;;
  124)  exit 124 ;;
esac
exit 0
EOF
  chmod +x "$R/bin/merge-conductor.sh"
  printf '#!/bin/bash\nexit 1\n' > "$C/rbin/gh"; chmod +x "$C/rbin/gh"
  : > "$R/state/merge-conductor/pr-state.tsv"; : > "$C/bs.out"; : > "$C/rec/runs"
}
row() { # row <case> <num> <since> <head>
  printf 'example-org/demo#%s\tREADY\t%s\t%s\t%s\t-\tclean\thttps://github.com/example-org/demo/pull/%s\n' "$2" "$3" "$4" "$4" "$2" \
    >> "$T/$1/r/state/merge-conductor/pr-state.tsv"
}
# fire <case> [VAR=val...]: one fire. Its output and its runs' end lines go to
# fire.out and are appended to bs.out. Every detached run inherits the pipe to
# tee, so the pipeline returns only when the last run of this fire has ended.
fire() {
  local C="$T/$1"; shift
  ( cd "$C" && env PATH="$C/rbin:$PATH" HARNESS="$C/r" "$@" bash "$C/r/bin/merge-conductor-backstop.sh" 2>&1 | tee -a "$C/bs.out" > "$C/fire.out" )
}
runs()    { grep -c "^key=example-org/demo#$2\$" "$T/$1/rec/runs" || true; }
skips()   { grep -c "example-org/demo#$2: its last [0-9]* keyed runs left its row unchanged" "$T/$1/fire.out" || true; }
counter() { cut -f3 "$T/$1/r/state/merge-conductor/backstop-unchanged/example-org_demo_$2" 2>/dev/null; }
UD() { printf '%s/r/state/merge-conductor/backstop-unchanged' "$T/$1"; }

# ============================================================================
# U1. Three runs, then one skip line and no run.
# ============================================================================
mk u1 || { echo "FAIL: cannot build u1"; exit 1; }
row u1 1 1 "$HA"
for i in 1 2 3; do
  fire u1
  [ "$(runs u1 1)" = "$i" ] && ok || bad "U1 fire $i must run A (runs: $(runs u1 1); out: $(tail -2 "$T/u1/fire.out"))"
  [ "$(skips u1 1)" = 0 ] && ok || bad "U1 fire $i must log no skip line (count $(counter u1 1) < 3)"
  [ "$(counter u1 1)" = "$i" ] && ok || bad "U1 after fire $i the counter must read $i (got: $(counter u1 1))"
done
fire u1
[ "$(runs u1 1)" = 3 ] && ok || bad "U1 fire 4 must start no run for A (runs: $(runs u1 1))"
[ "$(skips u1 1)" = 1 ] && ok || bad "U1 fire 4 must log exactly one skip line for A (got $(skips u1 1): $(cat "$T/u1/fire.out"))"
grep -q "example-org/demo#1: its last 3 keyed runs left its row unchanged on head ${HA:0:8} — skipped until the row changes (MC_BACKSTOP_UNCHANGED_SKIP=3)" "$T/u1/fire.out" \
  && ok || bad "U1 the skip line names the count, the head and the knob: $(grep 'unchanged' "$T/u1/fire.out")"
grep -q '1 candidate(s): 0 detached keyed conductor run(s) started.*, 1 skipped as unchanged' "$T/u1/fire.out" && ok \
  || bad "U1 the summary counts the skip: $(grep 'candidate(s)' "$T/u1/fire.out")"
fire u1
[ "$(runs u1 1)" = 3 ] && [ "$(skips u1 1)" = 1 ] && ok || bad "U1 fire 5 skips again with one line (runs $(runs u1 1), lines $(skips u1 1))"

# ============================================================================
# U3. A new head on A's row lifts the skip and resets the counter.
# ============================================================================
sed -i "s/$HA/$HC/g" "$T/u1/r/state/merge-conductor/pr-state.tsv"
fire u1
[ "$(runs u1 1)" = 4 ] && ok || bad "U3 a changed row must be run again (runs: $(runs u1 1))"
[ "$(skips u1 1)" = 0 ] && ok || bad "U3 a changed row must log no skip line"
[ "$(counter u1 1)" = 1 ] && ok || bad "U3 the counter resets to 1 on the new row (got: $(counter u1 1))"

# ============================================================================
# U2. MAXR=1: A stuck, B fresh. Fire 4 starts B.
# ============================================================================
mk u2 || { echo "FAIL: cannot build u2"; exit 1; }
row u2 1 1 "$HA"; row u2 2 50 "$HB"
for i in 1 2 3; do fire u2 MC_BACKSTOP_MAX_RUNNING=1; done
[ "$(runs u2 1)" = 3 ] && [ "$(runs u2 2)" = 0 ] && ok || bad "U2 fixture: fires 1-3 run only A, the oldest (A $(runs u2 1), B $(runs u2 2))"
fire u2 MC_BACKSTOP_MAX_RUNNING=1
[ "$(runs u2 2)" = 1 ] && ok || bad "U2 fire 4 must start B once A is skipped (B runs: $(runs u2 2); out: $(cat "$T/u2/fire.out"))"
[ "$(runs u2 1)" = 3 ] && ok || bad "U2 fire 4 must not run A (A runs: $(runs u2 1))"
grep -q 'MC_BACKSTOP_MAX_RUNNING=1 reached' "$T/u2/fire.out" && bad "U2 a skipped key must not use the slot: $(cat "$T/u2/fire.out")" || ok

# ============================================================================
# U4. The knob: unset = 3 (U1); 0 = off; 2 = skip on fire 3.
# ============================================================================
mk u4a || { echo "FAIL: cannot build u4a"; exit 1; }
row u4a 1 1 "$HA"
for i in 1 2 3 4 5; do fire u4a MC_BACKSTOP_UNCHANGED_SKIP=0; done
[ "$(runs u4a 1)" = 5 ] && ok || bad "U4 MC_BACKSTOP_UNCHANGED_SKIP=0 must never skip (runs: $(runs u4a 1))"
grep -q 'left its row unchanged' "$T/u4a/bs.out" && bad "U4 knob 0 must log no skip line" || ok
mk u4b || { echo "FAIL: cannot build u4b"; exit 1; }
row u4b 1 1 "$HA"
fire u4b MC_BACKSTOP_UNCHANGED_SKIP=2; fire u4b MC_BACKSTOP_UNCHANGED_SKIP=2
[ "$(runs u4b 1)" = 2 ] && ok || bad "U4 knob 2: fires 1-2 run (runs: $(runs u4b 1))"
fire u4b MC_BACKSTOP_UNCHANGED_SKIP=2
[ "$(runs u4b 1)" = 2 ] && [ "$(skips u4b 1)" = 1 ] && ok || bad "U4 knob 2 must skip on fire 3 (runs $(runs u4b 1), lines $(skips u4b 1))"
fire u4b MC_BACKSTOP_UNCHANGED_SKIP=junk
[ "$(runs u4b 1)" = 3 ] && ok || bad "U4 a non-number knob falls back to 3: count 2 runs once more (runs: $(runs u4b 1))"

# ============================================================================
# U5. A run that ends 124 (the timeout's rc) still counts.
# ============================================================================
mk u5 || { echo "FAIL: cannot build u5"; exit 1; }
row u5 1 1 "$HA"
for i in 1 2 3; do fire u5 REC_MODE=124; done
[ "$(grep -c 'example-org/demo#1: keyed conductor run hit timeout' "$T/u5/bs.out" || true)" = 3 ] && ok \
  || bad "U5 fixture: each run must end as a timeout (bs.out: $(tail -3 "$T/u5/bs.out"))"
[ "$(counter u5 1)" = 3 ] && ok || bad "U5 a timed-out run must count (counter: $(counter u5 1))"
fire u5 REC_MODE=124
[ "$(runs u5 1)" = 3 ] && [ "$(skips u5 1)" = 1 ] && ok || bad "U5 after 3 timed-out runs the key is skipped (runs $(runs u5 1), lines $(skips u5 1))"

# ============================================================================
# U6. Retention: a counter of a key that is no longer a candidate goes.
# ============================================================================
mk u6 || { echo "FAIL: cannot build u6"; exit 1; }
row u6 1 1 "$HA"
mkdir -p "$(UD u6)"
printf 'example-org/demo#77\t123\t9\n' > "$(UD u6)/example-org_demo_77"
fire u6
[ -e "$(UD u6)/example-org_demo_77" ] && bad "U6 the counter of a key with no candidate row must be removed" || ok
[ "$(counter u6 1)" = 1 ] && ok || bad "U6 the live key's counter stays (got: $(counter u6 1))"
sed -i 's/\tREADY\t/\tMERGED\t/' "$T/u6/r/state/merge-conductor/pr-state.tsv"
fire u6
[ -e "$(UD u6)/example-org_demo_1" ] && bad "U6 a row that left READY/WAIT_CI drops its counter, even on a 0-candidate fire" || ok

# ============================================================================
# U7. A run that changes its row removes the counter.
# ============================================================================
mk u7 || { echo "FAIL: cannot build u7"; exit 1; }
row u7 1 1 "$HA"
fire u7; fire u7
[ "$(counter u7 1)" = 2 ] && ok || bad "U7 fixture: two unchanged runs count 2 (got: $(counter u7 1))"
fire u7 REC_MODE=edit
[ -e "$(UD u7)/example-org_demo_1" ] && bad "U7 a run that changed its row must remove the counter (got: $(counter u7 1))" || ok
for i in 1 2 3; do fire u7 REC_MODE=edit; done
[ "$(runs u7 1)" = 6 ] && [ "$(grep -c 'left its row unchanged' "$T/u7/bs.out" || true)" = 0 ] && ok \
  || bad "U7 a key whose runs keep changing its row is never skipped (runs $(runs u7 1))"

echo "mc-backstop-unchanged-skip.bh-8310-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
