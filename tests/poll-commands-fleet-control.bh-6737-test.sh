#!/bin/bash
# tests/poll-commands-fleet-control.bh-6737-test.sh — BH-6737: the console
# command arms for dispatch_issue, machine_ctl, pool_cap and run_script.
#
# bin/poll-commands.sh (the hub poller) runs dispatch_issue, machine_ctl and
# pool_cap HERE and never forwards them: the Fly pool exists only on the hub.
# Each arm calls its bin/cmd-<x>.sh; rc 0 is OK=true, rc 3 is OUTCOME=refused
# (BH-932), anything else is a retryable failure. run_script runs on the hub
# for row project `hub` and on the owning box for a fleet project, through
# bcx_run (bin/lib/box-cmd-exec.sh) locally or box_ccmd_forward otherwise.
#
# The blocks are the SHIPPED ones, extracted by their markers. W5/W6 drive the
# real bcx_run; W5 also runs the real bin/cmd-run-script.sh behind it. W7 runs
# the shipped ack block, so the result JSON reaches the console verbatim.
# Run from anywhere: tests/poll-commands-fleet-control.bh-6737-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PC="$DIR/bin/poll-commands.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/catalog" "$H/logs"
for s in bin/lib/box-cmd-exec.sh bin/cmd-run-script.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "install $s"
done
cat > "$H/fleet.conf" <<'EOF'
# fixture
pa example-org/fixture-pa - - 1 hub
EOF
export FLEET_CONF="$H/fleet.conf"
cat > "$H/bin/box-for.sh" <<'EOF'
#!/bin/bash
[ -n "${BOXFOR:-}" ] || exit 1
printf '%s\n' "$BOXFOR"
EOF
chmod 755 "$H/bin/box-for.sh"

# block <marker> -> a case statement holding just that block
block() {
  { echo 'case "$TYPE" in'
    awk -v m="$1" '$0 ~ "^    # >>> " m {f=1;next} $0 ~ "^    # <<< " m {exit} f{print}' "$PC"
    echo '  *) RESULT="unknown command type $TYPE" ;;'
    echo 'esac'
  } > "$T/$2"
  [ "$(wc -l < "$T/$2")" -gt 4 ] && ok || bad "could not extract '# >>> $1' from bin/poll-commands.sh"
}
block 'fleet control handler' fc.body
block 'run_script handler' rs.body

# stub_cmd <name>: logs argv, prints STUB_OUT, exits STUB_RC
stub_cmd() {
  cat > "$H/bin/$1" <<'EOF'
#!/bin/bash
printf '%s|%s|%s|%s\n' "$(basename "$0")" "$1" "$2" "$3" >> "$CMD_LOG"
if [ -n "${STUB_OUT+x}" ]; then out=$STUB_OUT; else out='{"result":"ok"}'; fi
[ -z "$out" ] || printf '%s\n' "$out"
exit "${STUB_RC:-0}"
EOF
  chmod 755 "$H/bin/$1"
}
for c in cmd-dispatch-issue.sh cmd-machine-ctl.sh cmd-pool-cap.sh; do stub_cmd "$c"; done
cp "$H/bin/cmd-run-script.sh" "$T/cmd-run-script.real"

# arm <body> <type> <project> -> "OK=.. OUTCOME=.. RESULT=.."; FWD log + CMD log
arm() {
  : > "$T/cmd.log"; : > "$T/fwd.log"
  HARNESS="$H" CMD_LOG="$T/cmd.log" FWD_LOG="$T/fwd.log" TYPE="$2" PROJECT="$3" bash -c '
    set -uo pipefail
    . "$HARNESS/bin/lib/box-cmd-exec.sh"
    box_ccmd_forward() { printf "%s\n" "$*" >> "$FWD_LOG"; JOBS_HTTP="${FWD_HTTP:-}"; return "${FWD_RC:-0}"; }
    cron_box_id_for() { printf "%s\n" "$1"; }
    [ -n "${PAYLOAD:-}" ] || PAYLOAD="{}"; ID=81 OK=false RESULT="" OUTCOME=""
    . "$0"; printf "OK=%s OUTCOME=%s RESULT=%s\n" "$OK" "$OUTCOME" "$RESULT"' "$T/$1"
}

echo "--- W1: each pool kind runs its own script; rc 3 is a refusal"
for pair in dispatch_issue:cmd-dispatch-issue.sh machine_ctl:cmd-machine-ctl.sh pool_cap:cmd-pool-cap.sh; do
  t=${pair%%:*}; s=${pair#*:}
  GOT=$(STUB_RC=3 STUB_OUT='{"result":"refused","reason":"no"}' PAYLOAD='{"a":1}' arm fc.body "$t" pa)
  [ "$GOT" = 'OK=false OUTCOME=refused RESULT={"result":"refused","reason":"no"}' ] && ok || bad "W1 $t rc 3: $GOT"
  [ "$(cat "$T/cmd.log")" = "$s|pa|{\"a\":1}|81" ] && ok || bad "W1 $t argv: $(cat "$T/cmd.log")"
done

echo "--- W2: rc 0 is OK, rc 1 and 124 are failures"
GOT=$(STUB_RC=0 STUB_OUT='{"result":"ok","pool_cap":3}' arm fc.body pool_cap pa)
[ "$GOT" = 'OK=true OUTCOME= RESULT={"result":"ok","pool_cap":3}' ] && ok || bad "W2 rc 0: $GOT"
GOT=$(STUB_RC=1 STUB_OUT='{"result":"failed","reason":"x"}' arm fc.body machine_ctl pa)
[ "$GOT" = 'OK=false OUTCOME= RESULT={"result":"failed","reason":"x"}' ] && ok || bad "W2 rc 1: $GOT"
GOT=$(STUB_RC=124 STUB_OUT='' arm fc.body dispatch_issue pa)
R=${GOT#*RESULT=}
{ [[ "$GOT" == "OK=false OUTCOME= RESULT="* ]] && [ "$(jq -r .result <<<"$R")" = failed ] \
  && jq -r .reason <<<"$R" | grep -q 'timed out after 60s'; } && ok || bad "W2 rc 124: $GOT"
GOT=$(STUB_RC=1 STUB_OUT='' arm fc.body pool_cap pa)
R=${GOT#*RESULT=}
{ [ "$(jq -r .result <<<"$R")" = failed ] && jq -r .reason <<<"$R" | grep -q 'rc 1'; } && ok || bad "W2 empty result: $GOT"

echo "--- W3: the pool kinds are never forwarded, even for a far box"
for t in dispatch_issue machine_ctl pool_cap; do
  BOXFOR=box-far arm fc.body "$t" pa >/dev/null
  [ ! -s "$T/fwd.log" ] && ok || bad "W3 $t was forwarded: $(cat "$T/fwd.log")"
  [ -s "$T/cmd.log" ] && ok || bad "W3 $t did not run here"
done

echo "--- W4: run_script routing"
stub_cmd cmd-run-script.sh
GOT=$(STUB_OUT='{"result":"ok","rc":0}' arm rs.body run_script hub)
{ [ "$GOT" = 'OK=true OUTCOME= RESULT={"result":"ok","rc":0}' ] && [ "$(cut -d'|' -f1,2 "$T/cmd.log")" = "cmd-run-script.sh|hub" ] \
  && [ ! -s "$T/fwd.log" ]; } && ok || bad "W4 hub runs here: $GOT / $(cat "$T/cmd.log")"
GOT=$(BOXFOR=local STUB_OUT='{"result":"ok","rc":2}' arm rs.body run_script pa)
{ [ "$GOT" = 'OK=true OUTCOME= RESULT={"result":"ok","rc":2}' ] && [ ! -s "$T/fwd.log" ]; } && ok || bad "W4 local project: $GOT"
GOT=$(BOXFOR=box-far arm rs.body run_script pa)
{ [ "$(wc -l < "$T/fwd.log")" = 1 ] && [ "$(cut -d' ' -f1-4 "$T/fwd.log")" = "81 box-far run_script pa" ] \
  && [ ! -s "$T/cmd.log" ] && [[ "$GOT" == OK=true* ]]; } && ok || bad "W4 far box forward: $GOT / $(cat "$T/fwd.log")"
GOT=$(BOXFOR= arm rs.body run_script zz)
{ [[ "$GOT" == "OK=false OUTCOME= RESULT=unknown project zz" ]] && [ ! -s "$T/fwd.log" ] && [ ! -s "$T/cmd.log" ]; } \
  && ok || bad "W4 unknown project: $GOT"
GOT=$(STUB_RC=3 STUB_OUT='{"result":"refused","reason":"not on the allowlist"}' arm rs.body run_script hub)
[ "$GOT" = 'OK=false OUTCOME=refused RESULT={"result":"refused","reason":"not on the allowlist"}' ] && ok || bad "W4 refusal: $GOT"

echo "--- W5: the real bcx_run runs the real cmd-run-script.sh"
cp "$T/cmd-run-script.real" "$H/bin/cmd-run-script.sh"; chmod 755 "$H/bin/cmd-run-script.sh"
jq -n '{about:"fixture",scripts:["stub-ok.sh"]}' > "$H/catalog/run-script-allowlist.json"
printf '#!/bin/bash\necho "ran $#"\nexit 5\n' > "$H/bin/stub-ok.sh"; chmod 755 "$H/bin/stub-ok.sh"
bx() { HARNESS="$H" bash -c '. "$HARNESS/bin/lib/box-cmd-exec.sh"; bcx_run "$@"; printf "%s\n%s\n" "$BCX_OK" "$BCX_RESULT"' _ "$@"; }
mapfile -t W5 < <(bx run_script hub '{"script":"stub-ok.sh","args":["a"]}' 42)
{ [ "${W5[0]:-}" = 1 ] && [ "$(jq -r .rc <<<"${W5[1]:-}")" = 5 ] && [ "$(jq -r .result <<<"${W5[1]:-}")" = ok ]; } \
  && ok || bad "W5 hub: ${W5[*]:-}"
mapfile -t W5 < <(bx run_script pa '{"script":"stub-ok.sh"}' 43)
[ "${W5[0]:-}" = 1 ] && ok || bad "W5 fleet project: ${W5[*]:-}"
mapfile -t W5 < <(bx run_script hub '{"script":"nope.sh"}' 44)
{ [ "${W5[0]:-}" = 0 ] && [ "$(jq -r .result <<<"${W5[1]:-}")" = refused ]; } && ok || bad "W5 refused: ${W5[*]:-}"
mapfile -t W5 < <(bx fetch_artifact hub '{}' 45)
[[ "${W5[1]:-}" == "refused: 'hub' is not a fleet.conf project" ]] && ok || bad "W5 hub stays refused for other types: ${W5[*]:-}"

echo "--- W6: the pool kinds do not run on a box"
for t in pool_cap dispatch_issue machine_ctl; do
  mapfile -t W6 < <(bx "$t" pa '{}' 46)
  { [ "${W6[0]:-}" = 0 ] && [[ "${W6[1]:-}" == "refused: $t does not run on a box" ]]; } && ok || bad "W6 $t: ${W6[*]:-}"
done

echo "--- W7: the shipped ack carries the result JSON and the refusal"
awk '/^    # >>> command ack/{f=1;next} /^    # <<< command ack/{exit} f{print}' "$PC" > "$T/ack.body"
[ -s "$T/ack.body" ] && ok || bad "W7 could not extract the command ack block"
ACK_OUT="$T/ack.json" bash -c 'API() { while [ $# -gt 0 ]; do [ "$1" = -d ] && printf "%s\n" "$2" > "$ACK_OUT"; shift; done; }
  CONSOLE_URL=https://console.fixture.example ID=81 OK=false OUTCOME=refused
  RESULT="{\"result\":\"refused\",\"reason\":\"no flags/fly-pool-pa\"}"; . "$0"' "$T/ack.body"
ACK=$(cat "$T/ack.json" 2>/dev/null)
{ [ "$(jq -r .outcome <<<"$ACK")" = refused ] && [ "$(jq -r '.result | fromjson | .reason' <<<"$ACK")" = "no flags/fly-pool-pa" ]; } \
  && ok || bad "W7 ack body: $ACK"

echo "--- W8: an unknown type still reaches the default arm"
GOT=$(arm fc.body bogus_kind pa)
[ "$GOT" = 'OK=false OUTCOME= RESULT=unknown command type bogus_kind' ] && ok || bad "W8: $GOT"

echo "--- W9: a far-box run_script forward: success acks queued, a refused forward acks failed"
GOT=$(BOXFOR=box-far PAYLOAD='{"script":"healthcheck.sh"}' arm rs.body run_script pa)
{ [ "$GOT" = 'OK=true OUTCOME= RESULT=queued for box-far (box command 81)' ] \
  && [ "$(cat "$T/fwd.log")" = '81 box-far run_script pa {"script":"healthcheck.sh"}' ]; } \
  && ok || bad "W9 forward ok: $GOT / $(cat "$T/fwd.log")"
GOT=$(BOXFOR=box-far FWD_RC=1 FWD_HTTP=400 arm rs.body run_script pa)
{ [ "$GOT" = 'OK=false OUTCOME= RESULT=forward to box-far failed (jobs worker 400)' ] \
  && [ "$(wc -l < "$T/fwd.log")" = 1 ] && [ ! -s "$T/cmd.log" ]; } && ok || bad "W9 forward failed: $GOT"
GOT=$(BOXFOR=box-far FWD_RC=1 arm rs.body run_script pa)
[ "$GOT" = 'OK=false OUTCOME= RESULT=forward to box-far failed (jobs worker unreachable)' ] \
  && ok || bad "W9 forward unreachable: $GOT"

echo "poll-commands-fleet-control: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
