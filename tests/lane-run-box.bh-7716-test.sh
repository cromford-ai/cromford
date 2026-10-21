#!/bin/bash
# tests/lane-run-box.bh-7716-test.sh — bin/lane-run-box.sh, the gated box entry
# of the lane-run queue (BH-7716). It runs the real script and the real
# bin/lib/lane-gate.sh in a scratch tree, with a stub bin/lane-run-worker.sh that
# records its arguments. 0 network calls: no jobs client is present, so the gate
# reads only the flags/ files.
#   B1  no switch set: the worker runs once, with the arguments unchanged
#   B2  flags/lane-off-lane-run-box: rc 0, the worker does not run
#   B3  flags/all-off: rc 0, the worker does not run
#   B4  flags/lane-off-lane-run-box.box.<box>: rc 0, the worker does not run
#   B5  the worker's own exit code passes through (exec)
# Run from anywhere: tests/lane-run-box.bh-7716-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog"
( cd "$DIR" && scratch_install_closure bin/lane-run-box.sh "$T/h" ) >/dev/null || { echo "setup: closure of bin/lane-run-box.sh"; exit 1; }
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"
printf 'project-6-os\n' > "$T/h/state/box-name"
cat > "$T/h/bin/lane-run-worker.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
exit "${WORKER_RC:-0}"
SH
chmod +x "$T/h/bin/lane-run-worker.sh" "$T/h/bin/lane-run-box.sh"
export CALLS="$T/calls"

run() { : > "$CALLS"; HARNESS="$T/h" LANE_REGISTRY="$T/h/catalog/lanes.json" JOBS_BOX=project-6-os bash "$T/h/bin/lane-run-box.sh" --once --box b1 >/dev/null 2>&1; echo $? > "$T/rc"; }

scratch_rm "$T/h/flags"; mkdir -p "$T/h/flags"
run
[ "$(cat "$T/rc")" = 0 ] && [ "$(cat "$CALLS")" = "--once --box b1" ] && ok || bad "B1: no switch: the worker runs with the same args (rc $(cat "$T/rc"), calls [$(cat "$CALLS")])"

touch "$T/h/flags/lane-off-lane-run-box"; run
[ "$(cat "$T/rc")" = 0 ] && [ ! -s "$CALLS" ] && ok || bad "B2: lane-off-lane-run-box: rc 0 and no worker run (rc $(cat "$T/rc"), calls [$(cat "$CALLS")])"
rm -f "$T/h/flags/lane-off-lane-run-box"

touch "$T/h/flags/all-off"; run
[ "$(cat "$T/rc")" = 0 ] && [ ! -s "$CALLS" ] && ok || bad "B3: all-off: rc 0 and no worker run (rc $(cat "$T/rc"), calls [$(cat "$CALLS")])"
rm -f "$T/h/flags/all-off"

touch "$T/h/flags/lane-off-lane-run-box.box.project-6-os"; run
[ "$(cat "$T/rc")" = 0 ] && [ ! -s "$CALLS" ] && ok || bad "B4: the box switch: rc 0 and no worker run (rc $(cat "$T/rc"), calls [$(cat "$CALLS")])"
rm -f "$T/h/flags/lane-off-lane-run-box.box.project-6-os"

: > "$CALLS"; HARNESS="$T/h" LANE_REGISTRY="$T/h/catalog/lanes.json" JOBS_BOX=project-6-os WORKER_RC=7 bash "$T/h/bin/lane-run-box.sh" --once >/dev/null 2>&1; rc=$?
[ "$rc" = 7 ] && ok || bad "B5: the worker's rc passes through (got $rc)"

echo "lane-run-box.bh-7716: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
