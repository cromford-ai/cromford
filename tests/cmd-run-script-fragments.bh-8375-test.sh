#!/bin/bash
# tests/cmd-run-script-fragments.bh-8375-test.sh — BH-8375: the run_script
# allowlist of bin/cmd-run-script.sh is catalog/run-script-allowlist.json plus
# every catalog/run-script-allowlist.d/*.json fragment, so a ticket that adds a
# script adds its own file instead of an entry to the shared list.
#
#   R1  a name listed only in a fragment runs (rc and output reported)
#   R2  every near-miss name is refused rc 3 and runs nothing
#   R3  one unparseable or wrong-shape fragment refuses everything (fail closed)
#   R4  no .d dir: a main-file name runs, an unlisted name is refused
#   R5  the refusal reason lists the union
#   R6  over the SHIPPED catalog: security-audit-launch.sh passes the list
#       check, and the main file still has exactly its 5 entries
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/cmd-run-script-fragments.bh-8375-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/catalog/run-script-allowlist.d" "$H/logs" "$H/bin"
for s in bin/cmd-run-script.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "install $s"
done
printf '# fixture\npa example-org/fixture-pa - - 1 hub\n' > "$H/fleet.conf"
jq -n '{about:"fixture main list",scripts:["stub-ok.sh","both.sh"]}' > "$H/catalog/run-script-allowlist.json"
jq -n '{about:"fixture fragment a",scripts:["frag-ok.sh","both.sh","frag-missing.sh"]}' > "$H/catalog/run-script-allowlist.d/a.json"
jq -n '{about:"fixture fragment b",scripts:["late.sh"]}' > "$H/catalog/run-script-allowlist.d/b.json"
jq -n '{about:"not a .json name",scripts:["disabled.sh"]}' > "$H/catalog/run-script-allowlist.d/x.json.disabled"
for s in stub-ok.sh frag-ok.sh both.sh late.sh disabled.sh xfrag-ok.sh frag-ok.sh.bak frag.sh; do
  printf '#!/bin/bash\nprintf "%s\\n" >> "$STUB_LOG"\necho "ran %s"\nexit 6\n' "$s" "$s" > "$H/bin/$s"
  chmod 755 "$H/bin/$s"
done

rs() { # rs <payload> -> OUT RC
  OUT=$(env HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUB_LOG="$T/stub.log" \
    bash "$H/bin/cmd-run-script.sh" hub "$1" 81 2>"$T/err"); RC=$?
}
jf() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
runs() { # runs <label> <script>: the script ran, rc 6 reported
  : > "$T/stub.log"
  rs "$(jq -nc --arg s "$2" '{script:$s}')"
  { [ "$RC" = 0 ] && [ "$(jf .result)" = ok ] && [ "$(jf .rc)" = 6 ]; } && ok || bad "$1 '$2' rc $RC (out=$OUT)"
  grep -qx "$2" "$T/stub.log" && ok || bad "$1 '$2' did not run"
  jf .tail | grep -qxF "ran $2" && ok || bad "$1 '$2' tail (out=$OUT)"
}
refused() { # refused <label> <script>: rc 3, nothing ran
  : > "$T/stub.log"
  rs "$(jq -nc --arg s "$2" '{script:$s}')"
  { [ "$RC" = 3 ] && [ "$(jf .result)" = refused ]; } && ok || bad "$1 '$2' rc $RC, want 3 (out=$OUT)"
  [ ! -s "$T/stub.log" ] && ok || bad "$1 '$2' ran: $(cat "$T/stub.log")"
}

echo "--- R1: a fragment-only name runs"
runs R1 frag-ok.sh
runs R1 late.sh
runs R1 both.sh
runs R1 stub-ok.sh

echo "--- R2: near-miss names are refused"
for s in frag-ok frag-ok.sh.bak xfrag-ok.sh frag.sh disabled.sh FRAG-OK.SH 'frag-ok.sh late.sh'; do
  refused R2 "$s"
done
refused R2 frag-missing.sh
jf .reason | grep -q 'not an executable file' && ok || bad "R2 frag-missing.sh reason (out=$OUT)"

echo "--- R3: one bad fragment refuses everything"
for body in '{bad json' '{"scripts":"frag-ok.sh"}' '{"scripts":[1]}' '[]'; do
  printf '%s\n' "$body" > "$H/catalog/run-script-allowlist.d/c-bad.json"
  refused "R3 ($body)" stub-ok.sh
  refused "R3 ($body)" frag-ok.sh
  jf .reason | grep -q 'c-bad.json' && ok || bad "R3 ($body) reason does not name the fragment (out=$OUT)"
done
rm -f "$H/catalog/run-script-allowlist.d/c-bad.json"
runs "R3 restored" frag-ok.sh

echo "--- R4: no .d dir is the main list alone"
mv "$H/catalog/run-script-allowlist.d" "$T/frag-aside"
runs R4 stub-ok.sh
refused R4 frag-ok.sh
mkdir "$H/catalog/run-script-allowlist.d"
runs "R4 empty .d" stub-ok.sh
refused "R4 empty .d" frag-ok.sh
rmdir "$H/catalog/run-script-allowlist.d"; mv "$T/frag-aside" "$H/catalog/run-script-allowlist.d"

echo "--- R5: the refusal lists the union"
refused R5 nope.sh
for s in stub-ok.sh frag-ok.sh late.sh; do
  jf .reason | grep -qF "$s" && ok || bad "R5 reason does not list $s (out=$OUT)"
done
grep -qF disabled.sh <<<"$(jf .reason)" && bad "R5 reason lists a .disabled fragment's name (out=$OUT)" || ok

echo "--- R6: the shipped catalog"
S="$T/s"
mkdir -p "$S/logs" "$S/bin"
cp -r "$REPO_DIR/catalog" "$S/catalog"
for s in bin/cmd-run-script.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$S" >/dev/null || bad "R6 install $s"
done
# The shipped list check, not the real launcher: a stub prints a marker.
printf '#!/bin/bash\necho shipped-list-ok\n' > "$S/bin/security-audit-launch.sh"
chmod 755 "$S/bin/security-audit-launch.sh"
OUT=$(env HARNESS="$S" FLEET_CONF="$H/fleet.conf" bash "$S/bin/cmd-run-script.sh" hub \
  '{"script":"security-audit-launch.sh"}' 82 2>"$T/err"); RC=$?
{ [ "$RC" = 0 ] && [ "$(jf .result)" = ok ] && jf .tail | grep -qx shipped-list-ok; } && ok \
  || bad "R6 the shipped catalog refuses security-audit-launch.sh (rc $RC out=$OUT err=$(cat "$T/err"))"
[ "$(jq -r '.scripts | length' "$REPO_DIR/catalog/run-script-allowlist.json")" = 5 ] && ok \
  || bad "R6 the main allowlist does not have exactly 5 entries"
jq -e '.scripts | index("security-audit-launch.sh") == null' "$REPO_DIR/catalog/run-script-allowlist.json" >/dev/null \
  && ok || bad "R6 security-audit-launch.sh is in the shared main list, not a fragment"

echo "cmd-run-script-fragments.bh-8375: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
