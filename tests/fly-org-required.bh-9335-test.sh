#!/bin/bash
# tests/fly-org-required.bh-9335-test.sh — BH-9335 (slice C0, Fix 5): no Fly
# script falls back to the `personal` org when FLY_ORG is not set.
#
# Each case runs the real script through its entry point, in a scratch HARNESS
# built with scratch_install_closure, with a stub `curl` on PATH that logs every
# call it sees.
#   I1  bin/fly-idle-check.sh, FLY_API_TOKEN set, no FLY_ORG: rc != 0, stderr
#       and exactly one ALERTS line name FLY_ORG, zero curl calls
#   I2  FLY_ORG= (blank) behaves the same as unset
#   I3  FLY_ORG=acme: the apps read asks for org_slug=acme
#   I4  no FLY_API_TOKEN: rc 0, `not configured`, no alert (unchanged)
#   S1  bin/vendor-spend-pull.sh --vendor fly --dry-run, no FLY_ORG: one fly row,
#       status `error`, note names FLY_ORG, zero curl calls
#   S2  the same with FLY_ORG=acme reads org_slug=acme
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fly-org-required.bh-9335-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/env" "$H/logs" "$H/flags" "$H/state" "$H/locks" "$H/catalog" "$T/fake" "$T/tmp"
scratch_install_closure bin/fly-idle-check.sh "$H" >/dev/null || { echo "FAIL: cannot install fly-idle-check closure"; exit 1; }
scratch_install_closure bin/vendor-spend-pull.sh "$H" >/dev/null || { echo "FAIL: cannot install vendor-spend-pull closure"; exit 1; }
# fly-idle-check runs alert-line.sh (not sources it), so the closure does not carry it.
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || { echo "FAIL: cannot install alert-line closure"; exit 1; }
cp "$(cd "$(dirname "$0")/.." && pwd)/catalog/fly-prices.json" "$H/catalog/"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env" TMPDIR="$T/tmp" CURL_LOG="$T/curl.log"
export ENDPOINT_FLY_MACHINES=http://stub ENDPOINT_OPENROUTER=http://stub-or ENDPOINT_OPENAI=http://stub-oa
export PATH="$T/fake:$PATH"
unset FLY_ORG FLY_API_TOKEN HARNESS_SECRET JOBS_URL

# The stub: logs the URL, answers an empty app list with HTTP 200.
cat > "$T/fake/curl" <<'SH'
#!/bin/bash
URL=""; OUT=""; W=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -w) W="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-X|-d) shift 2 ;;
    http*) URL="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$URL" >> "$CURL_LOG"
body='{"apps":[]}'
if [ -n "$OUT" ]; then printf '%s' "$body" > "$OUT"; else printf '%s' "$body"; fi
[ -n "$W" ] && printf '200'
exit 0
SH
chmod +x "$T/fake/curl"

reset() { rm -f "$H/logs/ALERTS.log" "$H/logs/fly-idle-check.log" "$CURL_LOG"; : > "$CURL_LOG"; scratch_rm "$H/state/fly-idle-check"; scratch_rm "$H/state/vendor-spend"; }
genv() { printf '%s\n' "$@" > "$H/env/global.env"; }
idle() { bash "$H/bin/fly-idle-check.sh" >"$T/out" 2>"$T/err"; RC=$?; }
ncalls() { local n; n=$(grep -c . "$CURL_LOG" 2>/dev/null); echo "${n:-0}"; }
nalerts() { local n; n=$(grep -c . "$H/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }

# ── I1/I2: fly-idle-check without an org ─────────────────────────────────────
for label in unset blank; do
  reset
  if [ "$label" = unset ]; then genv 'FLY_API_TOKEN=tok-fixture-1'; else genv 'FLY_API_TOKEN=tok-fixture-1' 'FLY_ORG='; fi
  idle
  [ "$RC" != 0 ] && ok || bad "I $label: rc=$RC, want nonzero"
  grep -q 'FLY_ORG' "$T/err" && ok || bad "I $label: stderr does not name FLY_ORG: $(cat "$T/err")"
  [ "$(nalerts)" = 1 ] && ok || bad "I $label: want exactly 1 ALERTS line, have $(nalerts)"
  grep -q 'FLY_ORG' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "I $label: the ALERTS line does not name FLY_ORG"
  [ "$(ncalls)" = 0 ] && ok || bad "I $label: curl was called: $(cat "$CURL_LOG")"
  if grep -q 'personal' "$CURL_LOG"; then bad "I $label: asked for the personal org"; else ok; fi
done

# ── I3: a set org is the org asked for ───────────────────────────────────────
reset; genv 'FLY_API_TOKEN=tok-fixture-1' 'FLY_ORG=acme'
idle
grep -q 'org_slug=acme' "$CURL_LOG" && ok || bad "I3 FLY_ORG=acme: no org_slug=acme call (calls: $(cat "$CURL_LOG"); err: $(head -c 300 "$T/err"))"
if grep -q 'FLY_ORG is not set' "$T/err"; then bad "I3 FLY_ORG=acme still refused"; else ok; fi

# ── I4: no token is unchanged ────────────────────────────────────────────────
reset; genv 'FLY_ORG='
idle
[ "$RC" = 0 ] && ok || bad "I4 no token: rc=$RC want 0"
[ "$(nalerts)" = 0 ] && ok || bad "I4 no token: an alert was written"
grep -q 'not configured' "$H/logs/fly-idle-check.log" 2>/dev/null && ok || bad "I4 no token: no 'not configured' log line"

# ── S1: vendor-spend-pull fly without an org ─────────────────────────────────
reset; genv 'FLY_API_TOKEN=tok-fixture-1'
bash "$H/bin/vendor-spend-pull.sh" --vendor fly --dry-run >"$T/out" 2>"$T/err"; RC=$?
ROW=$(awk -F, '$2=="fly"' "$T/out")
[ "$(grep -c . <<< "$ROW")" = 1 ] && ok || bad "S1 want one fly row, have: $(cat "$T/out") (err: $(head -c 300 "$T/err"))"
[ "$(cut -d, -f7 <<< "$ROW")" = error ] && ok || bad "S1 fly row status is not error: $ROW"
grep -q 'FLY_ORG' <<< "$ROW" && ok || bad "S1 fly row note does not name FLY_ORG: $ROW"
[ "$(ncalls)" = 0 ] && ok || bad "S1 curl was called: $(cat "$CURL_LOG")"

# ── S2: a set org is the org asked for ───────────────────────────────────────
reset; genv 'FLY_API_TOKEN=tok-fixture-1' 'FLY_ORG=acme'
bash "$H/bin/vendor-spend-pull.sh" --vendor fly --dry-run >"$T/out" 2>"$T/err"
grep -qxF 'http://stub/v1/apps?org_slug=acme' "$CURL_LOG" && ok || bad "S2 FLY_ORG=acme: calls were $(cat "$CURL_LOG")"

echo "fly-org-required.bh-9335: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
