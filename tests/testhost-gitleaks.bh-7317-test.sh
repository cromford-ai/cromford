#!/bin/bash
# tests/testhost-gitleaks.bh-7317-test.sh — BH-7317: the test host image
# (fly/testhost/Dockerfile, app bh-testhost-example-org) installs the pinned
# gitleaks, so a remote gate with GITLEAKS_REQUIRED=1 is not red there.
#
# The Dockerfile:
#   D1  it has a `# >>> testhost-gitleaks` / `# <<< testhost-gitleaks` block
#   D2  ARG GITLEAKS_VERSION and ARG GITLEAKS_SHA256 are bare (no default)
#   D3  inside the block, `sha256sum -c` comes before `tar`
#   D4  the block runs `gitleaks version`
#   D5  only one line starts with `RUN test -n ` (the BH-1617 guard stays one)
#   X   the block's RUN, executed under sh with a fakebin curl and a fixture
#       tarball: X1 match, X2 v-prefix, X3 near miss, X4 prefix match, X5 silent,
#       X6 bad sha, X7 empty GITLEAKS_VERSION, X8 empty GITLEAKS_SHA256, X9 URL
# The deploy block in docs/REMOTE-GATE.md:
#   R1  sources bin/lib/gitleaks-pin.sh
#   R2  passes both ARGs from GITLEAKS_PIN_VERSION / GITLEAKS_PIN_SHA256
#   R3  executed: its source line yields the pin read from the pin file
#   R4  carries no copy of the pin (no 64-hex literal, no GITLEAKS_VERSION=<digit>)
#
# TESTHOST_DF / TESTHOST_DOC override the two files, for the red-on-main proof.
# Run from anywhere: tests/testhost-gitleaks.bh-7317-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
DF="${TESTHOST_DF:-$DIR/fly/testhost/Dockerfile}"
DOC="${TESTHOST_DOC:-$DIR/docs/REMOTE-GATE.md}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
PIN_V=$(sed -n 's/^GITLEAKS_PIN_VERSION=//p' "$DIR/bin/lib/gitleaks-pin.sh")
PIN_S=$(sed -n 's/^GITLEAKS_PIN_SHA256=//p' "$DIR/bin/lib/gitleaks-pin.sh")
[ -n "$PIN_V" ] && [ -n "$PIN_S" ] && ok || bad "setup: no pin in bin/lib/gitleaks-pin.sh"

# D — the Dockerfile's shape
BLK=$(awk '/^# >>> testhost-gitleaks/{f=1} f{print} /^# <<< testhost-gitleaks/{exit}' "$DF")
[ -n "$BLK" ] && ok || bad "D1: fly/testhost/Dockerfile has no testhost-gitleaks block"
grep -qx 'ARG GITLEAKS_VERSION' "$DF" && ok || bad "D2: no bare 'ARG GITLEAKS_VERSION' in the Dockerfile"
grep -qx 'ARG GITLEAKS_SHA256' "$DF" && ok || bad "D2: no bare 'ARG GITLEAKS_SHA256' in the Dockerfile"
grep -qE '^ARG GITLEAKS_[A-Z0-9]*=' "$DF" && bad "D2: a GITLEAKS ARG carries a default" || ok
shaln=$(grep -n 'sha256sum -c' <<<"$BLK" | head -1 | cut -d: -f1)
tarln=$(grep -n 'tar ' <<<"$BLK" | head -1 | cut -d: -f1)
if [ -n "$shaln" ] && [ -n "$tarln" ]; then
  [ "$shaln" -lt "$tarln" ] && ok || bad "D3: sha256sum -c (line $shaln) is not before tar (line $tarln)"
else
  bad "D3: the block has no sha256sum -c (${shaln:-missing}) or no tar (${tarln:-missing})"
fi
grep -q 'gitleaks version' <<<"$BLK" && ok || bad "D4: the block does not run 'gitleaks version'"
[ "$(grep -c '^RUN test -n ' "$DF")" -eq 1 ] && ok || bad "D5: the Dockerfile must have exactly one 'RUN test -n ' guard line"

# X — run the block's RUN as the image build would
W="$T/work"; FB="$T/fakebin"; mkdir -p "$W" "$FB" "$T/fix"
RUNCMD=$(awk '/^RUN /{f=1} f{print} f&&!/\\$/{exit}' <<<"$BLK" | sed '1s/^RUN //' | sed 's/\\$//' | tr '\n' ' ')
[ -n "$RUNCMD" ] && ok || bad "X: no RUN in the testhost-gitleaks block"
cat > "$FB/curl" <<'STUB'
#!/bin/sh
echo "$*" >> "$CURL_LOG"
out=""
while [ $# -gt 0 ]; do
  [ "$1" = "-o" ] && { out="$2"; shift; }
  shift
done
[ -n "$out" ] && cp "$FIX_TGZ" "$out"
STUB
chmod +x "$FB/curl"
mkdir -p "$T/fix/src"
printf '#!/bin/sh\n[ -n "$FAKE_OUT" ] && printf "%%s\\n" "$FAKE_OUT"\nexit 0\n' > "$T/fix/src/gitleaks"
chmod +x "$T/fix/src/gitleaks"
tar -czf "$T/fix/gitleaks.tar.gz" -C "$T/fix/src" gitleaks
FIX_SUM=$(sha256sum "$T/fix/gitleaks.tar.gz" | awk '{print $1}')
NEAR="${PIN_V%.*}.$(( ${PIN_V##*.} + 1 ))"

# run_layer <case> <GITLEAKS_VERSION> <GITLEAKS_SHA256> <fake output>; sets RC, leaves $T/<case>/
run_layer() {
  local c="$1" d="$T/$1"
  mkdir -p "$d/bin" "$d/tmp"; : > "$d/curl.log"
  local cmd=${RUNCMD//\/usr\/local\/bin/@BIN@}
  cmd=${cmd//\/tmp/@TMP@}; cmd=${cmd//@BIN@/$d\/bin}; cmd=${cmd//@TMP@/$d\/tmp}
  PATH="$FB:$PATH" CURL_LOG="$d/curl.log" FIX_TGZ="$T/fix/gitleaks.tar.gz" FAKE_OUT="$4" \
    GITLEAKS_VERSION="$2" GITLEAKS_SHA256="$3" sh -c "$cmd" >"$d/out" 2>"$d/err"; RC=$?
  : "$c"
}
if [ -n "$RUNCMD" ]; then
  run_layer x1 "$PIN_V" "$FIX_SUM" "gitleaks version $PIN_V"
  [ "$RC" -eq 0 ] && ok || bad "X1: a matching gitleaks fails the layer (rc $RC: $(cat "$T/x1/err"))"
  [ -x "$T/x1/bin/gitleaks" ] && ok || bad "X1: gitleaks is not installed"
  run_layer x2 "$PIN_V" "$FIX_SUM" "v$PIN_V"
  [ "$RC" -eq 0 ] && ok || bad "X2: a v-prefixed matching version fails the layer (rc $RC)"
  run_layer x3 "$PIN_V" "$FIX_SUM" "gitleaks version $NEAR"
  [ "$RC" -ne 0 ] && ok || bad "X3: a near-miss version $NEAR passes the layer"
  grep -q 'FATAL: gitleaks reports' "$T/x3/err" && grep -qF "$NEAR" "$T/x3/err" && grep -qF "expected $PIN_V" "$T/x3/err" \
    && ok || bad "X3: the FATAL does not name both versions ($(cat "$T/x3/err"))"
  run_layer x4 "$PIN_V" "$FIX_SUM" "${PIN_V}0"
  [ "$RC" -ne 0 ] && ok || bad "X4: a prefix match ${PIN_V}0 passes the layer"
  run_layer x5 "$PIN_V" "$FIX_SUM" ""
  [ "$RC" -ne 0 ] && ok || bad "X5: a silent gitleaks passes the layer"
  grep -q 'reports nothing' "$T/x5/err" && ok || bad "X5: the FATAL does not say 'reports nothing' ($(cat "$T/x5/err"))"
  run_layer x6 "$PIN_V" "0000000000000000000000000000000000000000000000000000000000000000" "gitleaks version $PIN_V"
  [ "$RC" -ne 0 ] && ok || bad "X6: a bad sha256 passes the layer"
  [ ! -e "$T/x6/bin/gitleaks" ] && [ ! -e "$T/x6/tmp/gitleaks" ] && ok || bad "X6: tar ran after a bad sha256"
  run_layer x7 "" "$FIX_SUM" "gitleaks version $PIN_V"
  [ "$RC" -ne 0 ] && ok || bad "X7: an empty GITLEAKS_VERSION passes the layer"
  grep -q GITLEAKS_VERSION "$T/x7/err" && ok || bad "X7: the FATAL does not name GITLEAKS_VERSION"
  [ ! -s "$T/x7/curl.log" ] && ok || bad "X7: curl ran with an empty GITLEAKS_VERSION"
  run_layer x8 "$PIN_V" "" "gitleaks version $PIN_V"
  [ "$RC" -ne 0 ] && ok || bad "X8: an empty GITLEAKS_SHA256 passes the layer"
  grep -q GITLEAKS_SHA256 "$T/x8/err" && ok || bad "X8: the FATAL does not name GITLEAKS_SHA256"
  [ ! -s "$T/x8/curl.log" ] && ok || bad "X8: curl ran with an empty GITLEAKS_SHA256"
  grep -qF "https://github.com/gitleaks/gitleaks/releases/download/v${PIN_V}/gitleaks_${PIN_V}_linux_x64.tar.gz" "$T/x1/curl.log" \
    && ok || bad "X9: the layer does not fetch the pinned release asset ($(cat "$T/x1/curl.log"))"
fi

# R — the deploy block in docs/REMOTE-GATE.md
block=$(awk '/^## Deploying the test host image/{s=1} s&&/^```sh/{b=1;next} b&&/^```/{exit} b' "$DOC")
[ -n "$block" ] && ok || bad "R: no deploy block under '## Deploying the test host image'"
srcline=$(grep -E '^\. bin/lib/gitleaks-pin\.sh' <<<"$block" | head -1)
[ -n "$srcline" ] && ok || bad "R1: the deploy block does not source bin/lib/gitleaks-pin.sh"
grep -qF -- '--build-arg GITLEAKS_VERSION="$GITLEAKS_PIN_VERSION"' <<<"$block" && ok || bad "R2: no --build-arg GITLEAKS_VERSION=\"\$GITLEAKS_PIN_VERSION\""
grep -qF -- '--build-arg GITLEAKS_SHA256="$GITLEAKS_PIN_SHA256"' <<<"$block" && ok || bad "R2: no --build-arg GITLEAKS_SHA256=\"\$GITLEAKS_PIN_SHA256\""
if [ -n "$srcline" ]; then
  got=$(cd "$DIR" && env -u GITLEAKS_PIN_VERSION -u GITLEAKS_PIN_SHA256 bash -c "$srcline"$'\n''printf "%s %s" "$GITLEAKS_PIN_VERSION" "$GITLEAKS_PIN_SHA256"' 2>/dev/null)
  [ "$got" = "$PIN_V $PIN_S" ] && ok || bad "R3: the block's source line yields '$got', not the pin"
fi
grep -qE '[0-9a-f]{64}' <<<"$block" && bad "R4: the deploy block carries a 64-hex literal" || ok
grep -qE 'GITLEAKS_([A-Z]+_)?(VERSION|SHA256)=[0-9a-f]' <<<"$block" && bad "R4: the deploy block carries a literal gitleaks pin" || ok

echo "testhost-gitleaks (BH-7317): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
