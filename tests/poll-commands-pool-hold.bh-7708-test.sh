#!/bin/bash
# tests/poll-commands-pool-hold.bh-7708-test.sh — BH-7708: the hub poller runs
# the console's pool_hold command.
#
# bin/poll-commands.sh runs pool_hold in its fleet control arm, on the hub, and
# never forwards it: the Fly pool exists only on the hub. The arm calls
# bin/cmd-pool-hold.sh <project> <payload> <id>; rc 0 is OK=true, rc 3 is
# OUTCOME=refused, anything else is a retryable failure. The block is the
# SHIPPED one, extracted by its marker; the command script is a stub.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/poll-commands-pool-hold.bh-7708-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PC="$DIR/bin/poll-commands.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin"
{ echo 'case "$TYPE" in'
  awk '/^    # >>> fleet control handler/{f=1;next} /^    # <<< fleet control handler/{exit} f{print}' "$PC"
  echo '  *) RESULT="unknown command type $TYPE" ;;'
  echo 'esac'
} > "$T/fc.body"
[ "$(wc -l < "$T/fc.body")" -gt 4 ] && ok || bad "could not extract '# >>> fleet control handler' from bin/poll-commands.sh"

for c in cmd-pool-hold.sh cmd-pool-cap.sh; do
  cat > "$H/bin/$c" <<'EOF'
#!/bin/bash
printf '%s|%s|%s|%s\n' "$(basename "$0")" "$1" "$2" "$3" >> "$CMD_LOG"
if [ -n "${STUB_OUT+x}" ]; then out=$STUB_OUT; else out='{"result":"ok"}'; fi
[ -z "$out" ] || printf '%s\n' "$out"
exit "${STUB_RC:-0}"
EOF
  chmod 755 "$H/bin/$c"
done

# arm <type> <project> -> "OK=.. OUTCOME=.. RESULT=.."; CMD log + FWD log
arm() {
  : > "$T/cmd.log"; : > "$T/fwd.log"
  HARNESS="$H" CMD_LOG="$T/cmd.log" FWD_LOG="$T/fwd.log" TYPE="$1" PROJECT="$2" bash -c '
    set -uo pipefail
    box_ccmd_forward() { printf "%s\n" "$*" >> "$FWD_LOG"; return 0; }
    [ -n "${PAYLOAD:-}" ] || PAYLOAD="{}"; ID=81 OK=false RESULT="" OUTCOME=""
    . "$0"; printf "OK=%s OUTCOME=%s RESULT=%s\n" "$OK" "$OUTCOME" "$RESULT"' "$T/fc.body"
}

echo "--- P1: pool_hold runs cmd-pool-hold.sh with project, payload and id"
GOT=$(STUB_OUT='{"result":"ok","held":true}' PAYLOAD='{"hold":true,"reason":"r"}' arm pool_hold pa)
[ "$GOT" = 'OK=true OUTCOME= RESULT={"result":"ok","held":true}' ] && ok || bad "P1 rc 0: $GOT"
[ "$(cat "$T/cmd.log")" = 'cmd-pool-hold.sh|pa|{"hold":true,"reason":"r"}|81' ] && ok || bad "P1 argv: $(cat "$T/cmd.log")"

echo "--- P2: rc 3 is a refusal, rc 1 a failure, no output a failure line"
GOT=$(STUB_RC=3 STUB_OUT='{"result":"refused","reason":"no"}' arm pool_hold pa)
[ "$GOT" = 'OK=false OUTCOME=refused RESULT={"result":"refused","reason":"no"}' ] && ok || bad "P2 rc 3: $GOT"
GOT=$(STUB_RC=1 STUB_OUT='{"result":"failed","reason":"x"}' arm pool_hold pa)
[ "$GOT" = 'OK=false OUTCOME= RESULT={"result":"failed","reason":"x"}' ] && ok || bad "P2 rc 1: $GOT"
GOT=$(STUB_RC=1 STUB_OUT='' arm pool_hold pa)
R=${GOT#*RESULT=}
{ [ "$(jq -r .result <<<"$R")" = failed ] && jq -r .reason <<<"$R" | grep -q 'cmd-pool-hold.sh gave no result (rc 1)'; } \
  && ok || bad "P2 empty result: $GOT"

echo "--- P3: pool_hold is never forwarded, and pool_cap still runs its own script"
arm pool_hold pa >/dev/null
{ [ ! -s "$T/fwd.log" ] && [ -s "$T/cmd.log" ]; } && ok || bad "P3 forwarded: $(cat "$T/fwd.log")"
arm pool_cap pa >/dev/null
[ "$(cut -d'|' -f1 "$T/cmd.log")" = cmd-pool-cap.sh ] && ok || bad "P3 pool_cap ran $(cat "$T/cmd.log")"

echo "--- P4: the console queues the same kind the hub arm runs"
# The writer of the row (the Pages fallback) and this arm must agree on the name.
PAGES_LIB="$DIR/console-ui/functions/_lib/pool-hold-command.js"
grep -q "^export const POOL_HOLD_TYPES = new Set(\['pool_hold'\]);" "$PAGES_LIB" && ok || bad "P4 $PAGES_LIB does not queue pool_hold"

echo "poll-commands-pool-hold.bh-7708-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
