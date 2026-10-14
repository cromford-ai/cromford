#!/bin/bash
# tests/hub-lease-renew-pause.bh-2750-test.sh — `hub-lease.sh renew` honors
# flags/hub-lease-renew-paused (BH-2750, parent #402).
#
# THE CONTRACT (bin/lib/failover-drill-common.sh, FD_RENEW_PAUSE_FLAG). The file
# holds an integer epoch deadline. While now < deadline, renew logs one line and
# exits 1 WITHOUT a worker call, so the failover drill can let the lease age out.
# A deadline at or before now, an empty file, or a non-integer one is removed
# and renew runs exactly as it does without the file, so a SIGKILLed drill can
# never leave the hub unrenewed past its own deadline. `check` ignores the file.
#
# Driven, not grepped: the REAL bin/hub-lease.sh runs against a fake curl that
# records its full argv. One pinned clock (HUB_LEASE_NOW), no wall clock.
# Run from anywhere: tests/hub-lease-renew-pause.bh-2750-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
mkdir -p "$T/bin/lib/jobs" "$T/logs" "$T/state" "$T/flags" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/box-name.sh" "$T/bin/box-name.sh"
cp "$DIR/bin/lib/hub-box.sh" "$T/bin/lib/hub-box.sh"
printf 'box-hub\n' > "$T/state/box-name"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PINNED_NOW=1000000000   # 2001-09-09T01:46:40Z
PF="$T/flags/hub-lease-renew-paused"
LOG="$T/logs/hub-lease.log"
CURL_LOG="$T/curl.log"
CACHE="$T/state/hub-lease.json"
SCRIPT="$DIR/bin/hub-lease.sh"

# Every call appends its full argv, one element per line, then a separator, so
# the POST body (--data-binary) is part of what N4 compares byte for byte.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
{ for a in "$@"; do printf '%s\n' "$a"; done; echo '--'; } >> "$CURL_LOG"
printf '{"lease":{"holder":"box-hub","epoch":4,"expired":false,"expires_at":"2001-09-09T02:46:40Z","updated_at":"2001-09-09T01:46:10Z"}}\n200'
exit 0
CURL
chmod +x "$T/fakebin/curl"

run() { # run <script> <renew|check>
  env PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
      JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 CURL_LOG="$CURL_LOG" \
      HUB_LEASE_HOLDER=box-hub HUB_LEASE_NOW="$PINNED_NOW" \
      bash "$1" "$2" >/dev/null 2>&1
  echo $?
}
setup() {
  rm -f "$PF" "$LOG" "$CURL_LOG" "$CACHE" "$T/logs/jobs-client.log"
  mkdir -p "$T/flags"; touch "$T/flags/alerted-jobs-client-$(date -u +%Y%m%d)"
}
curl_calls() { if [ -f "$CURL_LOG" ]; then grep -c '^--$' "$CURL_LOG"; else echo 0; fi; }
paused_line='renew: paused by flags/hub-lease-renew-paused until 2001-09-09T01:56:40Z'
removed_line='renew: pause flag expired/invalid, removed'

# N1 predicate, reused by the mutation guard M1: rc 1, the pause line, no curl,
# flag kept, no cache written.
n1_holds() { # n1_holds <script>
  setup; printf '%s\n' $((PINNED_NOW + 600)) > "$PF"
  local rc; rc=$(run "$1" renew)
  [ "$rc" = 1 ] && grep -qF "$paused_line" "$LOG" 2>/dev/null \
    && [ "$(curl_calls)" = 0 ] && [ -f "$PF" ] && [ ! -e "$CACHE" ]
}

# ── N1 — future deadline pauses renew ────────────────────────────────────────
setup; printf '%s\n' $((PINNED_NOW + 600)) > "$PF"
RC=$(run "$SCRIPT" renew)
[ "$RC" = 1 ] && ok || bad "N1: renew with a future deadline must exit 1 (got $RC)"
grep -qF "$paused_line" "$LOG" 2>/dev/null && ok || bad "N1: log must carry '$paused_line' (got: $(cat "$LOG" 2>/dev/null))"
[ "$(curl_calls)" = 0 ] && ok || bad "N1: no worker call while paused (curl calls: $(curl_calls))"
[ -f "$PF" ] && ok || bad "N1: a live pause flag must stay in place"
[ ! -e "$CACHE" ] && ok || bad "N1: a paused renew must not write the cache"

# ── N2 / N2b / N3 / N3b — expired, equal-to-now, non-integer, empty ──────────
expired_case() { # expired_case <label> <flag content, may be empty>
  local label="$1"; setup; printf '%s' "$2" > "$PF"
  local rc; rc=$(run "$SCRIPT" renew)
  [ "$rc" = 0 ] && ok || bad "$label: renew must proceed and exit 0 on 200 held (got $rc)"
  [ ! -e "$PF" ] && ok || bad "$label: the flag must be removed"
  grep -qF "$removed_line" "$LOG" 2>/dev/null && ok || bad "$label: log must carry '$removed_line' (got: $(cat "$LOG" 2>/dev/null))"
  grep -qF 'paused by' "$LOG" 2>/dev/null && bad "$label: must not log a pause" || ok
  { grep -qx 'POST' "$CURL_LOG" && grep -q '/api/hub-lease$' "$CURL_LOG"; } 2>/dev/null \
    && ok || bad "$label: renew must POST /api/hub-lease (curl log: $(cat "$CURL_LOG" 2>/dev/null))"
  [ "$(jq -r '.held' "$CACHE" 2>/dev/null)" = 1 ] && ok || bad "$label: cache must record held=1"
}
expired_case N2  "$((PINNED_NOW - 1))"$'\n'
expired_case N2b "$PINNED_NOW"
expired_case N3  "abc"
expired_case N3b ""

# ── N4 — no flag: the request is the one renew sent before this change ──────
# The golden is the first request's argv from `-X` on (method, headers, body,
# URL), captured from origin/main's script. When git can see origin/main (not in
# the gate's isolated snapshot) the whole capture is also compared byte for byte.
setup; RC_N=$(run "$SCRIPT" renew); cp "$CURL_LOG" "$T/curl.new" 2>/dev/null || : > "$T/curl.new"
[ "$RC_N" = 0 ] && ok || bad "N4: renew with no flag must exit 0 on 200 held (got $RC_N)"
printf '%s\n' -X POST -H 'authorization: Bearer test-secret' -H 'content-type: application/json' \
  --data-binary '{"holder":"box-hub","epoch":0}' 'https://jobs.invalid/api/hub-lease' > "$T/golden"
awk '/^--$/{exit} f||/^-X$/{f=1; print}' "$T/curl.new" > "$T/first"
cmp -s "$T/golden" "$T/first" && ok || bad "N4: renew request must match the golden ($(diff "$T/golden" "$T/first" 2>&1 | head -5))"
grep -qE 'paused by|pause flag' "$LOG" 2>/dev/null && bad "N4: no pause line without a flag" || ok
ORIG="$T/bin/hub-lease.orig.sh"
if git -C "$DIR" show origin/main:bin/hub-lease.sh > "$ORIG" 2>/dev/null && [ -s "$ORIG" ]; then
  setup; RC_O=$(run "$ORIG" renew)
  [ "$RC_O" = "$RC_N" ] && ok || bad "N4: rc must match origin/main (orig $RC_O, new $RC_N)"
  [ -s "$CURL_LOG" ] && cmp -s "$CURL_LOG" "$T/curl.new" \
    && ok || bad "N4: curl argv/body must be byte-identical to origin/main's ($(diff "$CURL_LOG" "$T/curl.new" 2>&1 | head -5))"
fi

# ── N5 — check ignores the flag ───────────────────────────────────────────────
setup; printf '%s\n' $((PINNED_NOW + 600)) > "$PF"
jq -nc --argjson fa "$PINNED_NOW" '{holder:"box-hub", epoch:4, expired:false,
  expires_at:"2001-09-09T02:46:40Z", updated_at:"2001-09-09T01:46:10Z",
  as_of:"2001-09-09T01:46:40Z", held:1, fetched_at:$fa}' > "$CACHE"
cp "$PF" "$T/pf.before"
RC=$(run "$SCRIPT" check)
[ "$RC" = 0 ] && ok || bad "N5: check with a fresh held cache must exit 0 (got $RC)"
cmp -s "$T/pf.before" "$PF" && ok || bad "N5: check must leave the pause flag untouched"
grep -qE 'paused by|pause flag' "$LOG" 2>/dev/null && bad "N5: check must not log a pause" || ok

# ── M1 — mutation guard: without the pause block's exit 1, N1 must fail ──────
n1_holds "$SCRIPT" && ok || bad "M1: N1 predicate must hold on the real script"
MUT="$T/bin/hub-lease.mut.sh"
sed '/paused by flags\/hub-lease-renew-paused/{n;/exit 1/d}' "$SCRIPT" > "$MUT"
if cmp -s "$SCRIPT" "$MUT"; then
  bad "M1: the mutation did not change the script (pause block not found)"
elif n1_holds "$MUT"; then
  bad "M1: N1 still holds with the pause exit removed — the test is vacuous"
else
  ok
fi

echo "hub-lease-renew-pause.bh-2750: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
