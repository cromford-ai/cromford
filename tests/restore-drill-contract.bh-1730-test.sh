#!/bin/bash
# tests/restore-drill-contract.bh-1730-test.sh — the contract slice of the
# weekly restore drill (BH-1730, parent #400): the stub lane, the Orgo seam in
# bin/lib/restore-drill-orgo.sh and the drill_on_box step interface in
# bin/lib/restore-drill-steps.sh.
#
# Runs the REAL bin/restore-drill.sh and the REAL library functions in a
# scratch harness root. Only curl is stubbed: it records its argv and stdin and
# answers with $STUB_BODY / $STUB_CODE / $STUB_RC. What the stub RECEIVES and
# what the functions RETURN are the assertions. There is no jobs-client.sh in
# the scratch root, so the lane gate never leaves the machine.
#
# Run from anywhere: tests/restore-drill-contract.bh-1730-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$T/fakebin"
for f in lane-gate env-path restore-drill-orgo restore-drill-steps; do
  cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/" || { echo "FAIL: missing bin/lib/$f.sh"; exit 1; }
done
cp "$DIR/bin/restore-drill.sh" "$H/bin/" || { echo "FAIL: missing bin/restore-drill.sh"; exit 1; }
: > "$H/env/global.env"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/curl.calls"
# Resolve any @file header (process substitution) so the key it carries is
# checkable, but keep it out of the argv record.
for a in "$@"; do
  case "$a" in @/dev/fd/*|@/proc/*) cat "${a#@}" >> "$STUB_DIR/curl.headers" 2>/dev/null ;; esac
done
if [ ! -t 0 ]; then cat > "$STUB_DIR/curl.stdin"; fi
[ "${STUB_RC:-0}" = 0 ] || exit "$STUB_RC"
printf '%s\n%s' "${STUB_BODY:-}" "${STUB_CODE:-200}"
EOF
chmod +x "$T/fakebin/curl"
export STUB_DIR="$T" PATH="$T/fakebin:$PATH"

reset_stub() { rm -f "$T/curl.calls" "$T/curl.stdin" "$T/curl.headers"; unset STUB_RC STUB_BODY STUB_CODE; }
ncalls() { [ -f "$T/curl.calls" ] && wc -l < "$T/curl.calls" || echo 0; }

# --- C-inert: sourcing each lib prints nothing, returns 0, under set -u --------
for f in restore-drill-orgo restore-drill-steps; do
  out=$(env -u H -u HARNESS bash -u -c ". '$H/bin/lib/$f.sh'" 2>&1); rc=$?
  if [ "$rc" = 0 ] && [ -z "$out" ]; then ok; else bad "C-inert $f: rc=$rc out=[$out]"; fi
done

# Source the libs into THIS shell so the globals are observable.
export H
export ORGO_API_KEY=K3YVALUE
# shellcheck source=bin/lib/restore-drill-orgo.sh
. "$H/bin/lib/restore-drill-orgo.sh" || exit 1
# shellcheck source=bin/lib/restore-drill-steps.sh
. "$H/bin/lib/restore-drill-steps.sh" || exit 1

# --- C-orgo-2xx ---------------------------------------------------------------
reset_stub; export STUB_CODE=200 STUB_BODY='{"id":"c1"}'
orgo GET /computers/c1; rc=$?
[ "$rc" = 0 ] && ok || bad "C-orgo-2xx rc=$rc"
[ "${ORGO_HTTP:-}" = 200 ] && ok || bad "C-orgo-2xx ORGO_HTTP=${ORGO_HTTP:-}"
[ "${ORGO_BODY:-}" = '{"id":"c1"}' ] && ok || bad "C-orgo-2xx ORGO_BODY=${ORGO_BODY:-}"
grep -qF 'https://www.orgo.ai/api/computers/c1' "$T/curl.calls" && ok || bad "C-orgo-2xx URL not in argv"
grep -qE '(^| )-m 300( |$)' "$T/curl.calls" && ok || bad "C-orgo-2xx -m 300 not in argv"
grep -qF 'Authorization: Bearer K3YVALUE' "$T/curl.headers" 2>/dev/null && ok || bad "C-orgo-2xx bearer header not sent"

# --- C-orgo-403 ---------------------------------------------------------------
reset_stub; export STUB_CODE=403 STUB_BODY='{"error":"no"}'
orgo GET /computers/c1; rc=$?
[ "$rc" != 0 ] && ok || bad "C-orgo-403 returned 0"
[ "${ORGO_HTTP:-}" = 403 ] && ok || bad "C-orgo-403 ORGO_HTTP=${ORGO_HTTP:-}"

# --- C-orgo-000 ---------------------------------------------------------------
reset_stub; export STUB_RC=7
orgo GET /computers/c1; rc=$?
[ "$rc" != 0 ] && ok || bad "C-orgo-000 returned 0"
[ "${ORGO_HTTP:-}" = 000 ] && ok || bad "C-orgo-000 ORGO_HTTP=${ORGO_HTTP:-}"
[ -z "${ORGO_BODY:-}" ] && ok || bad "C-orgo-000 ORGO_BODY not empty"

# --- C-remote-0 / C-remote-3 --------------------------------------------------
reset_stub; export STUB_CODE=200 STUB_BODY='{"output":"hello\n__RC=0\n"}'
remote c1 probe "echo hello"; rc=$?
[ "$rc" = 0 ] && ok || bad "C-remote-0 rc=$rc"
[ "${REMOTE_OUT:-}" = hello ] && ok || bad "C-remote-0 REMOTE_OUT=[${REMOTE_OUT:-}]"
grep -qF 'https://www.orgo.ai/api/computers/c1/bash' "$T/curl.calls" && ok || bad "C-remote-0 wrong endpoint"
cmd=$(jq -r '.command' "$T/curl.stdin" 2>/dev/null)
case "$cmd" in 'echo hello; echo __RC=$?') ok ;; *) bad "C-remote-0 body command=[$cmd]" ;; esac

reset_stub; export STUB_CODE=200 STUB_BODY='{"output":"x\n__RC=3"}'
remote c1 probe "false"; rc=$?
[ "$rc" = 3 ] && ok || bad "C-remote-3 rc=$rc"
[ "${REMOTE_OUT:-}" = x ] && ok || bad "C-remote-3 REMOTE_OUT=[${REMOTE_OUT:-}]"

# --- C-remote-glued: output with no trailing newline --------------------------
reset_stub; export STUB_CODE=200 STUB_BODY='{"output":"partial__RC=0"}'
remote c1 glued "printf partial"; rc=$?
[ "$rc" = 0 ] && ok || bad "C-remote-glued rc=$rc"
[ "${REMOTE_OUT:-}" = partial ] && ok || bad "C-remote-glued REMOTE_OUT=[${REMOTE_OUT:-}]"

# --- only the LAST non-empty line counts --------------------------------------
reset_stub; export STUB_CODE=200 STUB_BODY='{"output":"__RC=0\nmore\n__RC=4\n\n"}'
remote c1 last "x"; rc=$?
[ "$rc" = 4 ] && ok || bad "C-remote-last rc=$rc"

# --- C-remote-missing ---------------------------------------------------------
reset_stub; export STUB_CODE=200 STUB_BODY='{"output":"no rc here"}'
remote c1 missing "x"; rc=$?
[ "$rc" != 0 ] && ok || bad "C-remote-missing returned 0"

reset_stub; export STUB_CODE=200 STUB_BODY='not json __RC=0'
remote c1 notjson "x"; rc=$?
[ "$rc" != 0 ] && ok || bad "C-remote-notjson returned 0"

# --- C-remote-500 -------------------------------------------------------------
reset_stub; export STUB_CODE=500 STUB_BODY='{"output":"__RC=0"}'
remote c1 err "x"; rc=$?
[ "$rc" != 0 ] && ok || bad "C-remote-500 returned 0"

# --- transport failure --------------------------------------------------------
reset_stub; export STUB_RC=7
remote c1 down "x"; rc=$?
[ "$rc" = 255 ] && ok || bad "C-remote-transport rc=$rc"
[ "$(tail -n1 "$H/logs/restore-drill.log")" = "down rc=255" ] && ok || bad "C-remote-transport log line"

# --- C-log --------------------------------------------------------------------
reset_stub; export STUB_CODE=200 STUB_BODY='{"output":"S3CRETVALUE\n__RC=0\n"}'
remote c1 fence "echo S3CRETVALUE"; rc=$?
[ "$rc" = 0 ] && ok || bad "C-log rc=$rc"
last=$(tail -n1 "$H/logs/restore-drill.log")
[ "$last" = "fence rc=0" ] && ok || bad "C-log last log line=[$last]"
grep -q S3CRETVALUE "$H/logs/restore-drill.log" && bad "C-log command/output leaked to log" || ok
grep -q S3CRETVALUE "$T/curl.calls" && bad "C-log command leaked to argv" || ok
grep -q K3YVALUE "$T/curl.calls" && bad "C-log api key leaked to argv" || ok

# --- C-steps: the interface, against the real steps (BH-1732) -----------------
# An empty 200 has no __RC line, so remote returns 255 on the first (fence)
# call and the drill must stop there.
reset_stub
export RESTORE_DRILL_IDENTITY_FILE="" RESTORE_DRILL_HEALTH_PROJECT=x
export BACKUP_S3_ENDPOINT=e BACKUP_S3_ACCESS_KEY_ID=a BACKUP_S3_SECRET_ACCESS_KEY=s
DRILL_VERDICT=x DRILL_DETAIL=x DRILL_RPO_S=x
drill_on_box c1 hub; rc=$?
[ "$rc" = 1 ] && ok || bad "C-steps rc=$rc"
[ "$DRILL_VERDICT" = FAIL ] && ok || bad "C-steps DRILL_VERDICT=$DRILL_VERDICT"
case "$DRILL_DETAIL" in fence*) ok ;; *) bad "C-steps DRILL_DETAIL=$DRILL_DETAIL" ;; esac
[ -z "$DRILL_RPO_S" ] && ok || bad "C-steps DRILL_RPO_S=$DRILL_RPO_S"
[ "$(ncalls)" = 1 ] && ok || bad "C-steps made $(ncalls) curl calls, not 1"

# --- C-stub-lane: the production entry point ----------------------------------
# BH-1731 gave the lane its lifecycle. With an empty environment it is not
# configured: it SKIPs, calls nothing and writes only the marker.
reset_stub
out=$(env -u ORGO_API_KEY HARNESS="$H" bash "$H/bin/restore-drill.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "C-stub-lane rc=$rc out=[$out]"
[ "$(ncalls)" = 0 ] && ok || bad "C-stub-lane made curl calls"
[ ! -e "$H/state/restore-drill-inflight" ] && ok || bad "C-stub-lane wrote an inflight id"
[ "$(jq -r .verdict "$H/state/restore-drill-last.json" 2>/dev/null)" = SKIP ] && ok || bad "C-stub-lane marker is not SKIP"
rm -f "$H"/state/restore-drill-*
# The lane really sources its libs: remove one and it must fail, not exit 0.
mv "$H/bin/lib/restore-drill-steps.sh" "$T/steps.bak"
HARNESS="$H" bash "$H/bin/restore-drill.sh" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok || bad "C-stub-lane exits 0 without its steps lib"
mv "$T/steps.bak" "$H/bin/lib/restore-drill-steps.sh"

# --- C-gate: the off flag stops the lane before the libs ----------------------
reset_stub
: > "$H/flags/lane-off-restore-drill"
mv "$H/bin/lib/restore-drill-steps.sh" "$T/steps.bak"
HARNESS="$H" bash "$H/bin/restore-drill.sh" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "C-gate rc=$rc (the gate did not exit before the libs)"
[ "$(ncalls)" = 0 ] && ok || bad "C-gate made curl calls"
mv "$T/steps.bak" "$H/bin/lib/restore-drill-steps.sh"
rm -f "$H/flags/lane-off-restore-drill"

# --- C-noknobs: every ${X:-} the lane reads is registered, a secret, or a local
# (BH-1731 registered the lifecycle's knobs; this is section 7 of
# tests/lanes-registry-test.sh restated for this one lane.)
code=$(grep -v '^[[:space:]]*#' "$DIR/bin/restore-drill.sh")
known=$(jq -r '.knobs[].env' "$DIR/catalog/lanes.d/restore-drill.json" 2>/dev/null | tr '\n' ' ')
unreg=""
for n in $(printf '%s\n' "$code" | grep -oE '\$\{[A-Z][A-Z0-9_]{2,}:-' | sed 's/^\${//; s/:-$//' | sort -u); do
  case " HARNESS $known " in *" $n "*) continue ;; esac
  grep -qE '(^|_)(TOKEN|SECRET|PASSWORD|CREDENTIALS?|KEY)$' <<<"$n" && continue
  grep -qE "(^|[[:space:]]|;)$n=" <<<"$code" && continue
  unreg="$unreg $n"
done
[ -n "$known" ] && [ -z "$unreg" ] && ok || bad "C-noknobs lane reads unregistered knobs:${unreg:- (registry has none)}"

# --- C8: registry row and the rendered hub crontab ----------------------------
reg=$(HARNESS_TEST_SANDBOX=1 bash -c ". '$DIR/bin/lib/lanes-registry.sh' && lanes_json_path '$DIR'" 2>/dev/null)
if [ -n "$reg" ] && jq -e '.lanes[]|select(.id=="restore-drill")|.wired==true and .boxes==["hub"] and .cadence=="0 6 * * 0" and .scope=="hub" and .script=="bin/restore-drill.sh" and .stats.log=="logs/restore-drill.log"' "$reg" >/dev/null 2>&1; then
  ok
else
  bad "C8 registry row for restore-drill missing or wrong"
fi
cron=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" --root "$DIR" hub 2>/dev/null)
# A here-string, not `printf | grep -q`: grep -q exits at the match, the rest of
# the ~49 KB crontab hits a closed pipe, and under pipefail that EPIPE read as
# "no line" (CI run 37713378964, shard 2/8).
grep -qF '0 6 * * 0 /root/harness/bin/hub-lease.sh check && /root/harness/bin/restore-drill.sh' <<<"$cron" \
  && ok || bad "C8 hub crontab has no lease-gated restore-drill line"

echo "restore-drill-contract.bh-1730: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
