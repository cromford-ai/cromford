#!/bin/bash
# reads-run-build: raw — it pins the DRIVER's own shape (its structure and its bare call lines), which the flatten erases by design; its flatten checks read $RB_ALL's output like every other suite.
# tests/rb-split-layout.bh-572-test.sh — the shape of bin/run-build.sh after the
# BH-478 cut (BH-572): the driver is its kept head, dedupe block, env load and
# EXIT trap plus ONE bare call per stage, and the seven stage modules under
# bin/lib/rb/ carry every body.
#
# WHAT THIS PINS AND WHAT IT LEAVES TO THE FLATTEN. The byte identity of the
# pipeline (the flatten of the cut driver equals the pre-cut driver) is the PR's
# headline and is checked against the merge-base, which a suite cannot name. This
# suite pins the parts of that shape a later edit can quietly break:
#   1. the seven module paths are non-empty files
#   2. `bash -n` is 0 on each
#   3. the driver carries no stage body (tests/lib/driver-shape.sh): it defines
#      no stage function, reopens no module's marker block, and repeats no run
#      of the modules' code lines. A slice pasted back inline fails here; a
#      driver that grew by dispatch lines does not. (Until BH-5228 this was a
#      400-line ceiling, which failed honest growth and passed a short paste.)
#   4. sourcing all seven under `env -i … bash -uo pipefail` exits 0, prints
#      nothing, and defines all eleven entry functions — a module that RAN
#      something at source time would run it on every build of every box
#   5. exactly one bare call line per entry, in the pipeline's runtime order.
#      A bare call is the flatten's grammar: `rb_x` alone on its line. A comment,
#      an indented call, `rb_x || true` or `rb_x arg` is not one, and the
#      counter below is itself driven over a fixture carrying all four
#   6. the flatten still carries the marker blocks the reader suites extract
#      (floors measured on the merge-base, main @ 1af7170: 125 and 125)
#   7. the flatten's length is exactly the driver minus its eleven call lines
#      plus the eleven bodies: nothing dropped, nothing doubled
#
# Run from anywhere: tests/rb-split-layout.bh-572-test.sh   (exit 0 = all pass)
# No network, no clock, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
# shellcheck source=tests/lib/driver-shape.sh
. "$DIR/tests/lib/driver-shape.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

DRV="$DIR/bin/run-build.sh"
MODS="gates plan execute spec review pr result"
# runtime order, the ticket's scope item 2
ENTRIES="rb_gate_prelude rb_gate_claim_and_workspace rb_plan rb_gate_overlap rb_execute rb_spec_artifact rb_execute_gates rb_review rb_pr rb_settle rb_close_out"
OPEN_FLOOR=125
CLOSE_FLOOR=125

calls() { # calls <file> <entry>  -> the line numbers of bare call lines, one per line
  grep -nx -- "$2" "$1" | cut -d: -f1
}

# check 1 + 2
for m in $MODS; do
  f="$DIR/bin/lib/rb/$m.sh"
  [ -s "$f" ] && ok || bad "bin/lib/rb/$m.sh is missing or empty"
  bash -n "$f" 2>/dev/null && ok || bad "bash -n bin/lib/rb/$m.sh is not 0"
done

# check 3 — the driver is a driver: no stage body inline (BH-5228). The check
# is driven over two fixtures first, so a green on the real driver is not
# vacuous: one grown by 300 dispatch-only lines must pass, one with rb_plan's
# body pasted in above its call must fail, and one with a fresh unprefixed
# function must fail S1, since the driver's helpers are an exact allowlist.
DL=$(wc -l < "$DRV")
RB_DRIVER_FNS="STAMP RESULT PLAN_IS_BLOCKED"
export DRIVER_SHAPE_ALLOW_FNS="$RB_DRIVER_FNS"
RB_MODS=(); for m in $MODS; do RB_MODS+=("$DIR/bin/lib/rb/$m.sh"); done
{ cat "$DRV"; i=0; while [ "$i" -lt 150 ]; do
    printf '# dispatch %s\n[ -r "$HARNESS/bin/lib/rb/extra-%s.sh" ] && . "$HARNESS/bin/lib/rb/extra-%s.sh"\n' "$i" "$i" "$i"
    i=$((i+1)); done; } > "$T/grown.sh"
driver_shape "$T/grown.sh" rb_ "${RB_MODS[@]}" >/dev/null && ok \
  || bad "check 3 refuses a driver grown by dispatch lines only: $(driver_shape "$T/grown.sh" rb_ "${RB_MODS[@]}" | head -2)"
awk -v mod="$DIR/bin/lib/rb/plan.sh" '$0=="rb_plan"{ while ((getline l < mod) > 0) {
    if (l=="rb_plan() {") f=1; else if (l=="} # end rb_plan") f=0; else if (f) print l } } {print}' "$DRV" > "$T/pasted.sh"
[ "$(wc -l < "$T/pasted.sh")" -gt "$((DL + 20))" ] && ok || bad "check 3 fixture: rb_plan's body did not paste"
driver_shape "$T/pasted.sh" rb_ "${RB_MODS[@]}" >/dev/null \
  && bad "check 3 accepts a driver with rb_plan's body pasted inline" || ok
{ cat "$DRV"; printf '%s\n' 'build_new_stage() {' '  local stage_out="$BUILD_DIR/new-stage.txt"' '  printf "new stage for %s\n" "$KEY" > "$stage_out"' '}'; } > "$T/newfn.sh"
WHY=$(driver_shape "$T/newfn.sh" rb_ "${RB_MODS[@]}") \
  && bad "check 3 accepts a driver with a new unprefixed function build_new_stage()" || ok
grep -q '^S1: .*build_new_stage' <<<"$WHY" && ok \
  || bad "check 3 refuses build_new_stage() but not by S1: $(head -2 <<<"$WHY")"
WHY=$(driver_shape "$DRV" rb_ "${RB_MODS[@]}") && ok || bad "bin/run-build.sh carries a stage body: $WHY"

# check 4
SRC=""
for m in $MODS; do SRC="$SRC . \"$DIR/bin/lib/rb/$m.sh\" || exit 9;"; done
# --noprofile --norc and stdin from /dev/null: this box's /etc/bash.bashrc is
# pulled in whenever stdin is a socket, and its noise would read as module output.
OUT=$(env -i PATH="$PATH" bash --noprofile --norc -uo pipefail -c "$SRC echo __SOURCED__; declare -F" 2>&1 </dev/null)
RC=$?
[ "$RC" -eq 0 ] && ok || bad "sourcing the seven modules under -uo pipefail exits $RC"
PRE=$(printf '%s\n' "$OUT" | sed '/^__SOURCED__$/,$d')
[ -z "$PRE" ] && ok || bad "sourcing the modules printed something: $(head -3 <<<"$PRE")"
FNS=$(printf '%s\n' "$OUT" | sed -n '/^__SOURCED__$/,$p')
for e in $ENTRIES; do
  grep -qx "declare -f $e" <<<"$FNS" && ok || bad "no module defines $e"
done

# check 5, the counter first: over a fixture with every near-miss shape
printf '%s\n' '# rb_plan' '  rb_plan' 'rb_plan || true' 'rb_plan arg' 'rb_plan' 'rb_planx' 'xrb_plan' > "$T/fx.sh"
[ "$(calls "$T/fx.sh" rb_plan | wc -l)" -eq 1 ] && [ "$(calls "$T/fx.sh" rb_plan)" = 5 ] \
  && ok || bad "the call counter counts a near-miss as a call: [$(calls "$T/fx.sh" rb_plan | tr '\n' ' ')]"
in_order() { # in_order <file>  -> 0 when every entry has exactly one bare call, ascending
  local prev=0 e n c
  for e in $ENTRIES; do
    c=$(calls "$1" "$e" | wc -l)
    [ "$c" -eq 1 ] || { echo "$e has $c bare call lines"; return 1; }
    n=$(calls "$1" "$e")
    [ "$n" -gt "$prev" ] || { echo "$e (line $n) is not after line $prev"; return 1; }
    prev=$n
  done
}
# the order check refuses a swapped fixture, so a green below is not vacuous
printf '%s\n' $ENTRIES | sed '3{h;d};4{G}' > "$T/swapped.sh"
in_order "$T/swapped.sh" >/dev/null && bad "the order check accepts rb_plan after rb_gate_overlap" || ok
printf '%s\n' $ENTRIES > "$T/ordered.sh"
in_order "$T/ordered.sh" >/dev/null && ok || bad "the order check refuses the ordered fixture"
WHY=$(in_order "$DRV") && ok || bad "driver call lines: $WHY"

# check 6 + 7, on the flatten
if FL=$(rb_all "$DIR" "$T/rb.all"); then
  ok
  NO=$(grep -cE '^[[:space:]]*# >>> ' "$FL")
  NC=$(grep -cE '^[[:space:]]*# <<< ' "$FL")
  [ "$NO" -ge "$OPEN_FLOOR" ] && ok || bad "flatten carries $NO '# >>> ' markers, floor $OPEN_FLOOR"
  [ "$NC" -ge "$CLOSE_FLOOR" ] && ok || bad "flatten carries $NC '# <<< ' markers, floor $CLOSE_FLOOR"
  BODIES=0
  for m in $MODS; do
    for e in $ENTRIES; do
      grep -qx "$e() {" "$DIR/bin/lib/rb/$m.sh" || continue
      n=$(awk -v n="$e" '$0==n"() {"{f=1;next} $0=="} # end "n{exit} f' "$DIR/bin/lib/rb/$m.sh" | wc -l)
      BODIES=$((BODIES+n))
    done
  done
  WANT=$((DL - 11 + BODIES))
  GOT=$(wc -l < "$FL")
  [ "$GOT" -eq "$WANT" ] && ok || bad "flatten is $GOT lines; driver $DL - 11 calls + $BODIES body lines = $WANT"
else
  bad "rb_all could not flatten the pipeline"
fi

echo "rb-split-layout.bh-572-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
