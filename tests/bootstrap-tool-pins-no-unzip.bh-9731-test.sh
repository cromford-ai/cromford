#!/bin/bash
# tests/bootstrap-tool-pins-no-unzip.bh-9731-test.sh — the BH-9266 suite runs
# on a runner that has no unzip and no zip.
#
# WHY (BH-9731). The selection gate quarantined
# tests/bootstrap-tool-pins.bh-9266-test.sh: red on main 3bca4337. The gate runs
# suites on the Fly test host, and its image (fly/testhost/Dockerfile) installs
# no unzip. The suite had a hard `unzip` precondition, so it exited rc 1 there
# before any case ran. It now writes a python3 zipfile shim for
# `unzip -q <zip> -d <dir>` (the one form bin/lib/bootstrap-tool-pins.sh uses)
# when the runner has no unzip.
#
#   (a) no unzip/zip on PATH: rc 0
#   (b) the summary line says 70 passed, 0 failed
#   (c) the shim line is printed
#   (d) no unzip and no python3: rc 1 and the FAIL line
#   (e) real unzip on PATH: no shim line, 70 passed
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/bootstrap-tool-pins-no-unzip.bh-9731-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUITE="$DIR/tests/bootstrap-tool-pins.bh-9266-test.sh"
SHIM_LINE='unzip: absent; the cases use a python3 zipfile shim'
NOPY_LINE='FAIL: unzip missing and no python3'
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# farm <dir> <excluded names...> -> a PATH dir of symlinks to /usr/local/bin,
# /usr/bin and /bin, without the excluded names.
farm() {
  local s="$1" d f b; shift
  mkdir -p "$s"
  for d in /usr/local/bin /usr/bin /bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b=${f##*/}
      case " $* " in *" $b "*) continue ;; esac
      [ -e "$s/$b" ] || ln -s "$f" "$s/$b"
    done
  done
}

# (a)-(c): no unzip, no zip.
farm "$T/nounzip" unzip zip
PATH="$T/nounzip" HARNESS_TEST_SANDBOX=1 bash "$SUITE" > "$T/out-a" 2>&1; RC=$?
if [ "$RC" = 0 ]; then ok; else bad "(a) no unzip: rc $RC, want 0"; tail -20 "$T/out-a"; fi
if grep -Eq '^bootstrap-tool-pins\.bh-9266: 70 passed, 0 failed$' "$T/out-a"; then ok
else bad "(b) summary: $(tail -1 "$T/out-a")"; fi
if grep -Fxq "$SHIM_LINE" "$T/out-a"; then ok; else bad "(c) shim line not printed"; fi

# (d): no unzip and no python3 -> the suite fails, it does not skip.
farm "$T/nopy" unzip zip python3
PATH="$T/nopy" HARNESS_TEST_SANDBOX=1 bash "$SUITE" > "$T/out-d" 2>&1; RC=$?
if [ "$RC" = 1 ]; then ok; else bad "(d) no unzip, no python3: rc $RC, want 1"; fi
if grep -Fxq "$NOPY_LINE" "$T/out-d"; then ok; else bad "(d) FAIL line: $(head -3 "$T/out-d")"; fi

# (e): the box's own PATH. Where it has a real unzip, no shim is written.
if command -v unzip >/dev/null; then
  HARNESS_TEST_SANDBOX=1 bash "$SUITE" > "$T/out-e" 2>&1; RC=$?
  if [ "$RC" = 0 ]; then ok; else bad "(e) real unzip: rc $RC, want 0"; fi
  if grep -Fxq "$SHIM_LINE" "$T/out-e"; then bad "(e) shim line printed with a real unzip"; else ok; fi
  if grep -Eq '^bootstrap-tool-pins\.bh-9266: 70 passed, 0 failed$' "$T/out-e"; then ok
  else bad "(e) summary: $(tail -1 "$T/out-e")"; fi
else
  echo "(e) not checked: this runner has no unzip"
fi

echo "bootstrap-tool-pins-no-unzip.bh-9731: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
