#!/bin/bash
# tests/bootstrap-cli-pin.bh-9911-test.sh — BH-9911: bin/bootstrap-machine.sh puts
# claude on the pinned version when claude_cli.pin.enabled=1. The
# `# >>> claude cli pin (BH-9911)` block runs as shipped, under the bootstrap's
# own set -euo pipefail, with the real jobs client and the real
# bin/lib/claude-cli-pin.sh against a fake worker, and a stub cli-update.sh
# that records its environment.
#
#   B1 pin on: cli-update runs once with CLI_UPDATE_CLIS=claude and no system
#      tools; the line after the block runs
#   B2 pin off: cli-update does not run and the block prints nothing
#   B3 cli-update rc 1: FATAL line, the bootstrap stops (rc 1)
#   B4 the block sits after the tool pins block
# Run: HARNESS_TEST_SANDBOX=1 bash tests/bootstrap-cli-pin.bh-9911-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/claude-cli-pin-fakes.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BM="$DIR/bin/bootstrap-machine.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

blk=$(sed -n '/^# >>> claude cli pin (BH-9911)/,/^# <<< claude cli pin/p' "$BM")
[ -n "$blk" ] && ok || bad "B0 no '# >>> claude cli pin (BH-9911)' block in bootstrap-machine.sh"

new_case() {
  C="$T/$1"; mkdir -p "$C/logs" "$C/state" "$C/env"
  scratch_install_closure bin/lib/claude-cli-pin.sh "$C" >/dev/null || bad "$1: closure"
  scratch_install_closure bin/jobs-client.sh "$C" >/dev/null || bad "$1: closure"
  ccpf_new "$C/f"
  printf '#!/bin/bash\necho "clis=${CLI_UPDATE_CLIS:-} sys=[${CLI_UPDATE_SYS_TOOLS-unset}] args=$*" >> "%s/cu.calls"\nexit "${CU_RC:-0}"\n' "$C" > "$C/bin/cli-update.sh"
  chmod +x "$C/bin/cli-update.sh"
  printf '%s\necho AFTER\n' "$blk" > "$C/block.sh"
}
run_block() { # run_block [VAR=value...] -> OUT, RC
  OUT=$(env -i PATH="$C/f/fakebin:/usr/bin:/bin" HOME="$C" HARNESS="$C" HERE="$C/bin" JOBS_URL=https://jobs.test \
        HARNESS_SECRET=tok-fixture-bh9911 CCPF_W="$C/f/w" JOBS_RETRY_SLEEP=0 JOBS_SETTINGS_CACHE_S=0 "$@" \
        bash -c 'set -euo pipefail; . "$1"' _ "$C/block.sh" 2>&1); RC=$?
}

new_case b1; ccpf_set "$C/f" claude_cli.pin.enabled 1
run_block
[ "$RC" = 0 ] && grep -q '^AFTER$' <<<"$OUT" && ok || bad "B1 rc $RC: $OUT"
[ "$(cat "$C/cu.calls" 2>/dev/null)" = "clis=claude sys=[] args=" ] && ok || bad "B1 cli-update call: $(cat "$C/cu.calls" 2>/dev/null)"

new_case b2; ccpf_set "$C/f" claude_cli.pin.enabled 0
run_block
[ "$RC" = 0 ] && [ "$OUT" = AFTER ] && [ ! -e "$C/cu.calls" ] && ok || bad "B2 pin off: rc $RC, out '$OUT', calls $(cat "$C/cu.calls" 2>/dev/null)"
new_case b2b   # no row at all
run_block
[ "$RC" = 0 ] && [ "$OUT" = AFTER ] && [ ! -e "$C/cu.calls" ] && ok || bad "B2b no row: rc $RC, out '$OUT'"

new_case b3; ccpf_set "$C/f" claude_cli.pin.enabled 1
run_block CU_RC=1
[ "$RC" = 1 ] && grep -q '^FATAL: claude CLI not on the pin' <<<"$OUT" && ! grep -q '^AFTER$' <<<"$OUT" && ok || bad "B3 rc $RC: $OUT"

tl=$(grep -n '^# <<< tool pins' "$BM" | head -1 | cut -d: -f1)
pl=$(grep -n '^# >>> claude cli pin (BH-9911)' "$BM" | head -1 | cut -d: -f1)
[ -n "$tl" ] && [ -n "$pl" ] && [ "$pl" -gt "$tl" ] && ok || bad "B4 the pin block (line $pl) is not after the tool pins (line $tl)"

echo "bootstrap-cli-pin.bh-9911-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
