#!/bin/bash
# tests/pool-cap-set.bh-5750-test.sh — the write mode of bin/pool-cap.sh
# (BH-5750 C6): `pool-cap.sh --set <project> <n> [--apply]`.
#
# Runs the REAL bin/pool-cap.sh in a scratch harness root. The flag file
# flags/fly-pool-<p> is the pool's enable switch, so a cap set re-numbers an
# EXISTING file and never creates one.
#   F1  no --apply: prints PLAN cap pa 3->5, rc 0, the file is unchanged
#   F2  --apply on an existing flag file: writes 5; the print path then says 5
#   F3  no flag file: rc 2 "not on the pool", dry run and --apply, no file made
#   F4  n 0, -1, abc, empty, 05: rc 2, the file is unchanged
#   F4b a bad project name or extra args: rc 2, nothing written
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

[ -f "$DIR/bin/pool-cap.sh" ] || { echo "FAIL: missing $DIR/bin/pool-cap.sh"; exit 1; }
H="$T/h"
mkdir -p "$H/flags" "$H/env" "$H/fly"
scratch_install_closure bin/pool-cap.sh "$H" >/dev/null || { echo "FAIL: closure install bin/pool-cap.sh"; exit 1; }
: > "$H/env/global.env"
export HARNESS="$H"
unset POOL_AUTOSCALE POOL_CAP_MAX
PC="$H/bin/pool-cap.sh"
run() { OUT=$(bash "$PC" "$@" 2>&1); RC=$?; }
nflags() { find "$H/flags" -type f | wc -l; }

# ── F1 dry run ───────────────────────────────────────────────────────────
printf '3\n' > "$H/flags/fly-pool-pa"
run --set pa 5
[ "$RC" = 0 ] && ok || bad "F1 rc=$RC ($OUT)"
[ "$OUT" = "PLAN cap pa 3->5" ] && ok || bad "F1 out: $OUT"
[ "$(cat "$H/flags/fly-pool-pa")" = 3 ] && ok || bad "F1 the flag file changed: $(cat "$H/flags/fly-pool-pa")"

# ── F2 --apply ───────────────────────────────────────────────────────────
run --set pa 5 --apply
[ "$RC" = 0 ] && ok || bad "F2 rc=$RC ($OUT)"
[ "$OUT" = "SET cap pa 3->5" ] && ok || bad "F2 out: $OUT"
[ "$(cat "$H/flags/fly-pool-pa")" = 5 ] && ok || bad "F2 the flag file is not 5: $(cat "$H/flags/fly-pool-pa")"
[ "$(bash "$PC" pa)" = 5 ] && ok || bad "F2 the print path says $(bash "$PC" pa)"
grep -q 'tmp' <<<"$(ls "$H/flags")" && bad "F2 a temp file is left: $(ls "$H/flags")" || ok
# an empty flag file (pool on, no override) takes a number too
: > "$H/flags/fly-pool-pb"
run --set pb 2 --apply
[ "$RC" = 0 ] && [ "$(cat "$H/flags/fly-pool-pb")" = 2 ] && ok || bad "F2 empty flag: rc=$RC $OUT $(cat "$H/flags/fly-pool-pb")"
[ "$OUT" = "SET cap pb 0->2" ] && ok || bad "F2 empty flag out: $OUT"

# ── F3 a project not on the pool ─────────────────────────────────────────
N0=$(nflags)
for a in "" --apply; do
  # shellcheck disable=SC2086
  run --set pc 4 $a
  [ "$RC" = 2 ] && ok || bad "F3 '$a' rc=$RC ($OUT)"
  grep -qF 'not on the pool' <<<"$OUT" && ok || bad "F3 '$a' out: $OUT"
  [ ! -e "$H/flags/fly-pool-pc" ] && ok || bad "F3 '$a' created flags/fly-pool-pc"
done
[ "$(nflags)" = "$N0" ] && ok || bad "F3 the flags dir changed: $(ls "$H/flags")"

# ── F4 a bad number ──────────────────────────────────────────────────────
for n in 0 -1 abc '' 05 '5 '; do
  for a in "" --apply; do
    # shellcheck disable=SC2086
    run --set pa "$n" $a
    [ "$RC" = 2 ] && ok || bad "F4 '$n' '$a' rc=$RC ($OUT)"
    [ "$(cat "$H/flags/fly-pool-pa")" = 5 ] && ok || bad "F4 '$n' '$a' the flag file changed: $(cat "$H/flags/fly-pool-pa")"
  done
done

# ── F4b a bad project or extra args ──────────────────────────────────────
N0=$(nflags)
for p in '../pa' 'pa/x' '' 'pa;id'; do
  run --set "$p" 4 --apply
  [ "$RC" = 2 ] && ok || bad "F4b '$p' rc=$RC ($OUT)"
done
run --set pa 4 --apply extra
[ "$RC" = 2 ] && ok || bad "F4b extra arg rc=$RC ($OUT)"
run --set pa 4 --force
[ "$RC" = 2 ] && ok || bad "F4b --force rc=$RC ($OUT)"
run --set pa
[ "$RC" = 2 ] && ok || bad "F4b no n rc=$RC ($OUT)"
[ "$(cat "$H/flags/fly-pool-pa")" = 5 ] && [ "$(nflags)" = "$N0" ] && ok || bad "F4b something was written: $(ls "$H/flags")"

echo "pool-cap-set.bh-5750: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
