#!/bin/bash
# tests/box-host.bh-8545-test.sh — bin/box-host.sh <box> PRINTS THE SSH HOST
# FOR A FLEET BOX (BH-8545).
#
# The snapshot push ssh'd `root@box-project-1-1`, and that tailnet name
# pointed at a device that had been offline for 58 days. The registry's answer
# for "where is this box" is fleet.conf column 7 (the tailnet IP). box-host.sh
# prints that IP, and falls back to the box name only when the registry has no
# IP for the box.
#
# Driven: the REAL bin/box-host.sh over the REAL bin/fleet-conf.sh, on a fixture
# fleet.conf (FLEET_CONF, REGISTRY_SOURCE=file). Decision table:
#   (a) row with box + IP          -> the IP
#   (b) `# @box <box> <ip>` only   -> the IP
#   (c) two rows, one box, one IP  -> that IP, once
#   (d) row with no column 7       -> the box name
#   (e) column 7 is `-`            -> the box name
#   (f) unknown box                -> the box name
#   (g) `local`                    -> `local`
#   (h) no / empty argument        -> rc 2, no stdout
#   (i) a prefix of another box    -> its own answer, never the other box's IP
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/box-host.bh-8545-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

H="$T/h"
mkdir -p "$H"
if [ -f "$DIR/bin/box-host.sh" ]; then
  scratch_install_closure bin/box-host.sh "$H" >/dev/null || bad "setup: cannot install bin/box-host.sh"
fi
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || bad "setup: cannot install bin/fleet-conf.sh"

cat > "$T/fleet.conf" <<'EOF'
# fixture fleet.conf (BH-8545)
proj-fixture-a  example-org/proj-fixture-a  https://a.example.test  /api/board  2 box-fixture-dead 192.0.2.10
proj-fixture-b  example-org/proj-fixture-b  https://b.example.test  /api/board  3 box-fixture-two  198.51.100.30
proj-fixture-c  example-org/proj-fixture-c  https://c.example.test  /api/board  4 box-fixture-two  198.51.100.30
proj-fixture-d  example-org/proj-fixture-d  https://d.example.test  /api/board  5 box-fixture-noip
proj-fixture-e  example-org/proj-fixture-e  https://e.example.test  /api/board  6 box-fixture-dash -
# @box box-fixture-new 198.51.100.20
EOF

# bh <args...> — run the real resolver; sets OUT and RC.
bh() {
  OUT=$(env FLEET_CONF="$T/fleet.conf" REGISTRY_SOURCE=file HARNESS="$H" bash "$H/bin/box-host.sh" "$@" 2>"$T/err"); RC=$?
}
want() { # want <case> <expected stdout> <args...>
  local c="$1" w="$2"; shift 2
  bh "$@"
  [ "$RC" -eq 0 ] && [ "$OUT" = "$w" ] && ok || bad "$c: box-host.sh $* -> want '$w' rc 0, got '$OUT' rc $RC (err $(head -2 "$T/err"))"
}

want "(a) row with IP"            192.0.2.10                  box-fixture-dead
want "(b) @box directive"         198.51.100.20               box-fixture-new
want "(c) shared box, one IP"     198.51.100.30               box-fixture-two
want "(d) no column 7"            box-fixture-noip  box-fixture-noip
want "(e) column 7 is -"          box-fixture-dash  box-fixture-dash
want "(f) unknown box"            box-fixture-gone  box-fixture-gone
want "(g) local"                  local                       local
want "(i) prefix of another box"  box-fixture       box-fixture

bh
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && ok || bad "(h) no argument -> want rc 2 and no stdout, got rc $RC out '$OUT'"
bh ""
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && ok || bad "(h) empty argument -> want rc 2 and no stdout, got rc $RC out '$OUT'"

echo "box-host.bh-8545: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
