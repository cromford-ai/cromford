#!/bin/bash
# tests/cmd-run-script.bh-6737-test.sh — BH-6737: the console's run_script
# command and the reviewed list it runs from.
#
# bin/cmd-run-script.sh <project> <payload-json> <command_id> runs bin/<script>
# only when <script> is an exact entry of catalog/run-script-allowlist.json.
# Args reach it as argv elements and nothing else: no eval, no sh -c. The run
# is bounded (300 s), its stdout+stderr go to logs/run-script.log between an
# id header and an rc footer, and bin/fetch-log.sh serves that log as
# which=run_script. The script's own exit code is reported, never hidden.
#
# The suite uses its own allowlist in the scratch harness (stub scripts), and
# R6 checks the SHIPPED allowlist separately.
# Run from anywhere: tests/cmd-run-script.bh-6737-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/catalog" "$H/logs" "$H/bin"
for s in bin/cmd-run-script.sh bin/fetch-log.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "install $s"
done
cat > "$H/fleet.conf" <<'EOF'
# fixture
pa example-org/fixture-pa - - 1 hub
EOF
jq -n '{about:"fixture allowlist",scripts:["stub-ok.sh","stub-sleep.sh","listed-missing.sh"]}' > "$H/catalog/run-script-allowlist.json"
cat > "$H/bin/stub-ok.sh" <<'EOF'
#!/bin/bash
printf 'call\n' >> "$STUB_LOG"
printf '%s\0' "$#" "$@" > "$STUB_ARGS"
echo hello
echo to-stderr >&2
exit "${STUB_EXIT:-4}"
EOF
cat > "$H/bin/stub-sleep.sh" <<'EOF'
#!/bin/bash
printf 'call\n' >> "$STUB_LOG"
exec tail -f /dev/null
EOF
printf '#!/bin/bash\nprintf "x\\n" >> "$STUB_LOG"\n' > "$H/bin/x.sh"
chmod 755 "$H/bin/stub-ok.sh" "$H/bin/stub-sleep.sh" "$H/bin/x.sh"

# rs <project> <payload> [id] -> OUT RC
rs() {
  OUT=$(env HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUB_LOG="$T/stub.log" STUB_ARGS="$T/args" \
    bash "$H/bin/cmd-run-script.sh" "$1" "$2" "${3:-71}" 2>"$T/err"); RC=$?
}
jf() { jq -r "$1" <<<"$OUT" 2>/dev/null; }

echo "--- R1: a listed script runs, its rc and output are kept"
: > "$T/stub.log"
rs hub '{"script":"stub-ok.sh"}' 71
[ "$RC" = 0 ] && ok || bad "R1 rc $RC (out=$OUT err=$(cat "$T/err"))"
[ "$(jf .result)" = ok ] && ok || bad "R1 .result (out=$OUT)"
[ "$(jf .rc)" = 4 ] && ok || bad "R1 .rc (out=$OUT)"
[ "$(jf .script)" = stub-ok.sh ] && [ "$(jf .which)" = run_script ] && [ "$(jf .log)" = logs/run-script.log ] \
  && ok || bad "R1 .script/.which/.log (out=$OUT)"
jf .tail | grep -q hello && ok || bad "R1 .tail (out=$OUT)"
grep -q '^=== run_script id=71 box=.* script=stub-ok.sh argc=0 at=' "$H/logs/run-script.log" && ok || bad "R1 header: $(head -3 "$H/logs/run-script.log")"
grep -qx hello "$H/logs/run-script.log" && grep -qx to-stderr "$H/logs/run-script.log" && ok || bad "R1 output not in the log"
grep -qx '=== end id=71 rc=4' "$H/logs/run-script.log" && ok || bad "R1 footer"
[ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && ok || bad "R1 more than one stdout line"
STUB_EXIT=0 rs pa '{"script":"stub-ok.sh"}' 72
{ [ "$RC" = 0 ] && [ "$(jf .rc)" = 0 ] && [ "$(jf .result)" = ok ]; } && ok || bad "R1 rc 0, fleet project (rc $RC out=$OUT)"

echo "--- R2: a name that is not an exact list entry runs nothing"
for s in '../bin/x.sh' 'x.sh' 'bin/stub-ok.sh' 'stub-ok' '' ' stub-ok.sh' 'stub-ok.sh;id' 'STUB-OK.SH' '/bin/sh' 'listed-missing.sh'; do
  : > "$T/stub.log"
  rs hub "$(jq -nc --arg s "$s" '{script:$s}')"
  { [ "$RC" = 3 ] && [ "$(jf .result)" = refused ]; } && ok || bad "R2 '$s' rc $RC (out=$OUT)"
  [ ! -s "$T/stub.log" ] && ok || bad "R2 '$s' ran something: $(cat "$T/stub.log")"
done
rs hub '{"script":"x.sh"}'
jf .reason | grep -q 'stub-ok.sh' && jf .reason | grep -q 'allowlist' && ok || bad "R2 reason lists the allowlist (out=$OUT)"
rs hub '{"script":7}'
[ "$RC" = 3 ] && ok || bad "R2 a number as script rc $RC"

echo "--- R3: args are argv, never shell"
: > "$T/stub.log"; rm -f "$T/zz-should-not-exist"
rs hub "$(jq -nc --arg p "$T/zz-should-not-exist" '{script:"stub-ok.sh",args:["a","; touch \($p)","$(touch \($p))","`id`","two words","line1\nline2"]}')"
[ "$RC" = 0 ] && ok || bad "R3 rc $RC (out=$OUT)"
mapfile -d '' GOT < "$T/args"
[ "${GOT[0]:-}" = 6 ] && ok || bad "R3 argc '${GOT[0]:-}'"
[ "${GOT[2]:-}" = "; touch $T/zz-should-not-exist" ] && ok || bad "R3 arg 2 '${GOT[2]:-}'"
[ "${GOT[3]:-}" = "\$(touch $T/zz-should-not-exist)" ] && ok || bad "R3 arg 3 '${GOT[3]:-}'"
[ "${GOT[5]:-}" = "two words" ] && [ "${GOT[6]:-}" = $'line1\nline2' ] && ok || bad "R3 args 5/6"
[ ! -e "$T/zz-should-not-exist" ] && ok || bad "R3 an arg was run as shell"
grep -q 'argc=6' "$H/logs/run-script.log" && ok || bad "R3 header argc"
grep -qF 'zz-should-not-exist' "$H/logs/run-script.log" && bad "R3 arg values reached the log" || ok

echo "--- R4: bad args run nothing"
LONG=$(head -c 513 /dev/zero | tr '\0' a)
for a in '[1]' '[{"a":1}]' '[null]' '{"a":1}' '"one"' "$(jq -nc '[range(17)|tostring]')" "$(jq -nc --arg l "$LONG" '[$l]')"; do
  : > "$T/stub.log"
  rs hub "{\"script\":\"stub-ok.sh\",\"args\":$a}"
  { [ "$RC" = 3 ] && [ "$(jf .result)" = refused ] && [ ! -s "$T/stub.log" ]; } && ok || bad "R4 args $(head -c 40 <<<"$a") rc $RC (out=$OUT)"
done
: > "$T/stub.log"
rs hub "$(jq -nc '{script:"stub-ok.sh",args:[range(16)|tostring]}')"
[ "$RC" = 0 ] && ok || bad "R4 16 args are allowed (rc $RC out=$OUT)"

echo "--- R5: the run is bounded"
: > "$T/stub.log"
OUT=$(env HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUB_LOG="$T/stub.log" CMD_RUN_SCRIPT_TIMEOUT_S=1 \
  bash "$H/bin/cmd-run-script.sh" hub '{"script":"stub-sleep.sh"}' 75 2>/dev/null); RC=$?
{ [ "$(jf .result)" = failed ] && jf .reason | grep -q 'timed out'; } && ok || bad "R5 (rc $RC out=$OUT)"
[ "$(jf .rc)" = 124 ] && ok || bad "R5 .rc (out=$OUT)"
grep -qx '=== end id=75 rc=124' "$H/logs/run-script.log" && ok || bad "R5 footer"
grep -q 'CMD_RUN_SCRIPT_TIMEOUT_S:-300' "$DIR/bin/cmd-run-script.sh" && ok || bad "R5 the default bound is 300 s"

echo "--- R6: the shipped allowlist is the five reviewed seeds"
AL="$DIR/catalog/run-script-allowlist.json"
GOTL=$(jq -r '.scripts | sort | join(" ")' "$AL" 2>/dev/null)
[ "$GOTL" = "box-self-report.sh fly-idle-check.sh fly-machine-state.sh healthcheck.sh pool-cap.sh" ] && ok || bad "R6 list '$GOTL'"
for s in $(jq -r '.scripts[]' "$AL" 2>/dev/null); do
  [ -x "$DIR/bin/$s" ] && ok || bad "R6 bin/$s is not an executable file"
done

echo "--- R7: bin/fetch-log.sh serves the run_script log"
FL=$(env HARNESS="$H" FLEET_CONF="$H/fleet.conf" bash "$H/bin/fetch-log.sh" hub run_script 71 2>/dev/null)
jq -r .content <<<"$FL" 2>/dev/null | grep -q '^=== run_script id=71 ' && ok || bad "R7 log_tail content (got $(head -c 200 <<<"$FL"))"
[ "$(jq -r .which <<<"$FL" 2>/dev/null)" = run_script ] && ok || bad "R7 .which"
[ "$(env HARNESS="$H" bash "$H/bin/fetch-log.sh" --path run_script hub)" = "$H/logs/run-script.log" ] && ok || bad "R7 --path"

echo "--- R8: the log is trimmed past 1 MB"
head -c 1200000 /dev/zero | tr '\0' 'z' > "$H/logs/run-script.log"
STUB_EXIT=0 rs hub '{"script":"stub-ok.sh"}' 78
SZ=$(wc -c < "$H/logs/run-script.log")
{ [ "$SZ" -le 270000 ] && grep -qx '=== end id=78 rc=0' "$H/logs/run-script.log"; } && ok || bad "R8 size $SZ"

echo "--- R9: no allowlist fails closed"
mv "$H/catalog/run-script-allowlist.json" "$T/al.bak"
: > "$T/stub.log"
rs hub '{"script":"stub-ok.sh"}'
{ [ "$RC" = 3 ] && jf .reason | grep -q 'allowlist unreadable' && [ ! -s "$T/stub.log" ]; } && ok || bad "R9 rc $RC (out=$OUT)"
printf 'garbage' > "$H/catalog/run-script-allowlist.json"
rs hub '{"script":"stub-ok.sh"}'
{ [ "$RC" = 3 ] && [ ! -s "$T/stub.log" ]; } && ok || bad "R9 garbage rc $RC"
mv "$T/al.bak" "$H/catalog/run-script-allowlist.json"
rs zz '{"script":"stub-ok.sh"}'
[ "$RC" = 3 ] && ok || bad "R9 unknown project rc $RC"
rs hub 'not json'
[ "$RC" = 3 ] && ok || bad "R9 bad payload rc $RC"

echo "cmd-run-script: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
