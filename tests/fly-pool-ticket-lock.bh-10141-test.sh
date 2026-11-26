#!/bin/bash
# tests/fly-pool-ticket-lock.bh-10141-test.sh — the pool asks the cross-harness
# ticket lock before it spawns a machine, and its default-token line names the
# fingerprint of the token it ships (BH-10141).
#
# THE INCIDENT (2026-11-25 21:27:31Z). project-3 TK-903 was queued while another
# harness (operator-mac) held project-3:TK-903. The pool spawned a machine anyway; the
# machine's own gate (bin/lib/rb/gates.sh) answered BUILD_DEFERRED, and the pool
# offered the key again next tick: a slot, a spawn and a warm seed per tick. The
# same pool logged "ships the default project-6 token" for every project,
# whatever token its bundle carried.
#
# ROWS:
#   T1  201 → spawn, no line, one acquire with key project-3:TK-2
#   T2  201 for a key our own holder already has → spawn
#   T3  409 → skip, one `SKIP <key> ticket lock held by <holder>` line;
#       no holder field → `held by another harness`
#   T4  500 → spawn, one read-failed line
#   T5  an unshared project, or no LOCKS_URL → spawn, 0 requests
#   T6  a dead transport (curl exit 7) → spawn, one read-failed line
#   T7  RB-/RR-/LR-/CP-/FXR- keys → spawn, 0 requests; no temp file left
#   Q1  the real pool_spawn_decision over [TK-1 locked, TK-2 free] spawns TK-2
#       only, writes one SKIP line, and TK-1's queue file stays
#   Q2  the same with the GitHub gates inactive → TK-1 still skipped
#   Q3  the lock service answers 500 → both spawn
#   Q4  the machine's gate (gates.sh) still takes the lock: the second check
#   F1  pool_bundle_token_fp = sha256[:8] of the token; the line and log carry
#       no token text
#   F2  no token line → none; two token lines → the fp of the last
#   F3  the real fly-envbundle.sh --hub-global writes <dir>/bundle-source
#       `hub env/global.env`, mode 600, no token text; the line reads it
#   F4  "ships the default project-6 token" is gone from the render and the
#       fragment; the new line is in both
#   Z1  tests/lib/scratch.sh empties LOCKS_URL and LOCKS_TOKEN
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-ticket-lock.bh-10141-test.sh
set -uo pipefail
# Z1 setup: a shell that exports the live lock service must not reach it.
export LOCKS_URL="https://locks.live.example" LOCKS_TOKEN="ambient-fixture-token"
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# --- Z1 ----------------------------------------------------------------------
[ -z "${LOCKS_URL:-}" ] && [ -z "${LOCKS_TOKEN:-}" ] && ok \
  || bad "Z1 scratch.sh must empty LOCKS_URL/LOCKS_TOKEN (got '${LOCKS_URL:-}')"

FB="$T/fakebin"; mkdir -p "$FB" "$T/tmp"
# Fake curl (tests/ticket-lock.cross-harness-test.sh): records the URL and body,
# answers acquire from LK_ACQ_CODE / LK_ACQ_BODY, per key from LK_HELD_KEY.
cat > "$FB/curl" <<'EOF'
#!/bin/bash
out=""; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -w|-m|-X|--connect-timeout) shift 2 ;;
    -H) [ "$2" = "@-" ] && cat >/dev/null; shift 2 ;;
    -s) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "URL $url" >> "$CURL_LOG"; echo "DATA $data" >> "$CURL_LOG"
code="${LK_ACQ_CODE:-201}"; body="${LK_ACQ_BODY:-}"
[ -n "$body" ] || body='{"lease_id":"L-1","expires_at":"x"}'
# A per-key answer: the key named in LK_HELD_KEY gets 409 from LK_HELD_HOLDER.
if [ -n "${LK_HELD_KEY:-}" ] && [[ "$data" == *"\"$LK_HELD_KEY\""* ]]; then
  code=409; body="{\"holder\":\"${LK_HELD_HOLDER:-x}\"}"
fi
[ "$code" = dead ] && exit 7
printf '%s' "$body" > "$out"
printf '%s' "$code"
EOF
chmod +x "$FB/curl"
export PATH="$FB:$PATH" CURL_LOG="$T/curl.log" TMPDIR="$T/tmp"
SAY_LOG="$T/say.log"
say() { printf '%s\n' "$*" >> "$SAY_LOG"; }

LIB="$DIR/bin/lib/pool-ticket-lock.sh"
if [ -r "$LIB" ]; then . "$LIB" || bad "pool-ticket-lock.sh does not source"
else bad "bin/lib/pool-ticket-lock.sh is missing"; fi

reset() {
  : > "$CURL_LOG"; : > "$SAY_LOG"
  unset LK_ACQ_CODE LK_ACQ_BODY LK_HELD_KEY LK_HELD_HOLDER
  export LOCKS_URL="https://locks.example" LOCKS_TOKEN="fixture-token-ours"
  HARNESS="$DIR"; P=project-3
}
reqs()  { grep -c '^URL ' "$CURL_LOG"; }
lines() { grep -c . "$SAY_LOG"; }
notmp() { [ -z "$(ls -A "$T/tmp" 2>/dev/null)" ] && ok || bad "$1 left a temp file: $(ls -A "$T/tmp")"; }
gate()  { if command -v pool_ticket_lock_gate >/dev/null 2>&1; then pool_ticket_lock_gate "$@"; else return 99; fi; }

# --- T1 ----------------------------------------------------------------------
reset; export LK_ACQ_CODE=201
gate TK-2; rc=$?
[ "$rc" = 0 ] && ok || bad "T1 201 must spawn (rc 0), got $rc"
[ "$(lines)" = 0 ] && ok || bad "T1 201 writes no line: $(cat "$SAY_LOG")"
[ "$(reqs)" = 1 ] && ok || bad "T1 one acquire request, got $(reqs)"
grep -q '^URL https://locks.example/v1/acquire$' "$CURL_LOG" && grep -q '"key":"project-3:TK-2"' "$CURL_LOG" \
  && ok || bad "T1 the acquire must name project-3:TK-2: $(cat "$CURL_LOG")"
notmp T1

# --- T2 ----------------------------------------------------------------------
reset; export LK_ACQ_CODE=201 LK_ACQ_BODY='{"lease_id":"L-rotated","expires_at":"y"}'
gate TK-3; rc=$?
[ "$rc" = 0 ] && [ "$(lines)" = 0 ] && ok || bad "T2 our own holder (201) must spawn quietly, rc $rc: $(cat "$SAY_LOG")"
notmp T2

# --- T3 ----------------------------------------------------------------------
reset; export LK_ACQ_CODE=409 LK_ACQ_BODY='{"holder":"operator-mac"}'
gate TK-1; rc=$?
[ "$rc" = 1 ] && ok || bad "T3 409 must skip (rc 1), got $rc"
[ "$(cat "$SAY_LOG")" = "SKIP TK-1 ticket lock held by operator-mac" ] && ok \
  || bad "T3 exactly one SKIP line naming the holder: $(cat "$SAY_LOG")"
notmp T3
reset; export LK_ACQ_CODE=409 LK_ACQ_BODY='{}'
gate TK-4; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$SAY_LOG")" = "SKIP TK-4 ticket lock held by another harness" ] && ok \
  || bad "T3b 409 with no holder: rc $rc, $(cat "$SAY_LOG")"

# --- T4 ----------------------------------------------------------------------
reset; export LK_ACQ_CODE=500 LK_ACQ_BODY='{"error":"x"}'
gate TK-5; rc=$?
[ "$rc" = 0 ] && ok || bad "T4 500 must spawn (rc 0), got $rc"
[ "$(lines)" = 1 ] && grep -q 'TK-5: ticket lock read failed' "$SAY_LOG" && ok \
  || bad "T4 one read-failed line: $(cat "$SAY_LOG")"
notmp T4
# 201 with no lease id is an unknown answer: never a skip.
reset; export LK_ACQ_CODE=201 LK_ACQ_BODY='{"ok":true}'
gate TK-6; rc=$?
[ "$rc" = 0 ] && [ "$(lines)" = 1 ] && ok || bad "T4b 201 without lease id must spawn with one line, rc $rc: $(cat "$SAY_LOG")"

# --- T5 ----------------------------------------------------------------------
reset; P=cromford
gate BH-7; rc=$?
[ "$rc" = 0 ] && [ "$(reqs)" = 0 ] && [ "$(lines)" = 0 ] && ok \
  || bad "T5 an unshared project spawns with 0 requests: rc $rc, reqs $(reqs), $(cat "$SAY_LOG")"
reset; unset LOCKS_URL
gate TK-8; rc=$?
[ "$rc" = 0 ] && [ "$(reqs)" = 0 ] && [ "$(lines)" = 0 ] && ok \
  || bad "T5b no LOCKS_URL spawns with 0 requests: rc $rc, reqs $(reqs)"
reset; LOCKS_TOKEN=""
gate TK-9; rc=$?
[ "$rc" = 0 ] && [ "$(reqs)" = 0 ] && ok || bad "T5c an empty LOCKS_TOKEN spawns with 0 requests"
notmp T5

# --- T6 ----------------------------------------------------------------------
reset; export LK_ACQ_CODE=dead
gate TK-10; rc=$?
[ "$rc" = 0 ] && [ "$(lines)" = 1 ] && grep -q 'ticket lock read failed' "$SAY_LOG" && ok \
  || bad "T6 a dead transport must spawn with one line: rc $rc, $(cat "$SAY_LOG")"
notmp T6

# --- T7 ----------------------------------------------------------------------
reset; export LK_ACQ_CODE=409 LK_ACQ_BODY='{"holder":"operator-mac"}'
for k in RB-12-abcd1234 RR-12-abcd1234 LR-12 CP-12-abcd1234 FXR-1-1; do
  gate "$k"; rc=$?
  [ "$rc" = 0 ] && ok || bad "T7 $k must spawn, got $rc"
done
[ "$(reqs)" = 0 ] && [ "$(lines)" = 0 ] && ok || bad "T7 non-ticket keys send 0 requests, got $(reqs)"
notmp T7

# --- Q1-Q3: the real pool_spawn_decision, extracted from the render ----------
awk '/^pool_spawn_decision\(\) \{/,/^\}/' "$DIR/bin/fly-pool.sh" > "$T/psd.sh"
[ -s "$T/psd.sh" ] || bad "Q pool_spawn_decision not found in bin/fly-pool.sh"
QD="$T/q"; QH="$T/qh"; mkdir -p "$QD" "$QH/logs"
walk() { # walk <gates-applicable 0|1> — prints the keys pool_spawn_decision spawned
  ( HARNESS="$QH"; P=project-3; LOG="$T/pool.log"; QDIR="$QD"
    GA="$1"
    pool_gates_applicable() { [ "$GA" = 1 ]; }
    pool_after_gate() { return 0; }
    pool_hold_read() { _PHR_V=ok; }
    pool_terminal_path() { printf '%s/%s.terminal\n' "$QH" "$1"; }
    pool_hold_clear() { return 0; }
    pr_exists_for_key_rest() { return 1; }
    pool_terminal_check() { return 0; }
    pool_spawn_cap_check() { return 0; }
    pool_actor_gate() { return 0; }
    pool_tick_budget_spent() { return 1; }
    _PHC_READ_S=0; _POOL_ROWS_DECIDED=0
    . "$T/psd.sh"
    for k in TK-1 TK-2; do
      n="${k#TK-}"
      pool_spawn_decision "$QD/$k.json" "$k" "$n" && echo "$k" >> "$T/spawned"
    done )
}
qreset() {
  reset; rm -f "$T/spawned"; : > "$T/spawned"
  for k in TK-1 TK-2; do jq -nc --arg k "$k" '{key:$k,ticket_id:($k|ltrimstr("TK-")),attempt:0}' > "$QD/$k.json"; done
}
for GA in 1 0; do
  qreset; export LK_HELD_KEY="project-3:TK-1" LK_HELD_HOLDER="operator-mac"
  walk "$GA"
  tag=Q1; [ "$GA" = 0 ] && tag=Q2
  [ "$(tr '\n' ' ' < "$T/spawned")" = "TK-2 " ] && ok \
    || bad "$tag [locked TK-1, free TK-2] must spawn TK-2 only, spawned: $(tr '\n' ' ' < "$T/spawned")"
  [ "$(grep -c '^SKIP ' "$SAY_LOG")" = 1 ] && grep -qx 'SKIP TK-1 ticket lock held by operator-mac' "$SAY_LOG" && ok \
    || bad "$tag exactly one SKIP line for TK-1: $(cat "$SAY_LOG")"
  [ -f "$QD/TK-1.json" ] && ok || bad "$tag TK-1's queue file must stay (the row stays queued)"
done
qreset; export LK_ACQ_CODE=500 LK_ACQ_BODY='{}'
walk 1
[ "$(tr '\n' ' ' < "$T/spawned")" = "TK-1 TK-2 " ] && ok \
  || bad "Q3 a lock-service 500 spawns both, spawned: $(tr '\n' ' ' < "$T/spawned")"
[ "$(grep -c '^SKIP ' "$SAY_LOG")" = 0 ] && ok || bad "Q3 no SKIP line on an outage"

# --- Q4 ----------------------------------------------------------------------
grep -q 'tl_acquire "$PROJECT" "$KEY"' "$DIR/bin/lib/rb/gates.sh" \
  && grep -q 'BUILD_DEFERRED ticket lock' "$DIR/bin/lib/rb/gates.sh" && ok \
  || bad "Q4 the machine's gate must still take the ticket lock (bin/lib/rb/gates.sh)"

# --- F1-F2 -------------------------------------------------------------------
TOK="sk-ant-oat01-FIXTURE-bh10141"
WANT=$(printf '%s' "$TOK" | sha256sum | cut -c1-8)
printf 'CONSOLE_URL=https://c.example\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK" > "$T/g1.env"
if command -v pool_bundle_token_fp >/dev/null 2>&1; then
  [ "$(pool_bundle_token_fp "$T/g1.env")" = "$WANT" ] && ok \
    || bad "F1 fp must be $WANT, got $(pool_bundle_token_fp "$T/g1.env")"
  printf 'CONSOLE_URL=x\n' > "$T/g2.env"
  [ "$(pool_bundle_token_fp "$T/g2.env")" = none ] && ok || bad "F2 no token line must print none"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=fixture-first\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK" > "$T/g3.env"
  [ "$(pool_bundle_token_fp "$T/g3.env")" = "$WANT" ] && ok || bad "F2 two token lines: the fp of the last"
  [ "$(pool_bundle_token_fp "$T/nope.env")" = none ] && ok || bad "F2 a missing file must print none"
else
  bad "F1 pool_bundle_token_fp is not defined"
fi

# --- F3: the real bundler writes its source; the spawn line reads it ---------
FH="$T/fh"; mkdir -p "$FH/bin/lib" "$FH/env" "$T/bundle"
cp "$DIR/bin/fly-envbundle.sh" "$FH/bin/"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nCONSOLE_URL=https://c.example\n' "$TOK" > "$FH/env/global.env"
HARNESS_ENV_DIR="$FH/env" HARNESS="$FH" bash "$FH/bin/fly-envbundle.sh" proj "$T/bundle" --hub-global >/dev/null 2>"$T/eb.err"; rc=$?
[ "$rc" = 0 ] && ok || bad "F3 fly-envbundle --hub-global rc $rc: $(cat "$T/eb.err")"
[ "$(cat "$T/bundle/bundle-source" 2>/dev/null)" = "hub env/global.env" ] && ok \
  || bad "F3 bundle-source must read 'hub env/global.env', got '$(cat "$T/bundle/bundle-source" 2>/dev/null)'"
[ "$(stat -c %a "$T/bundle/bundle-source" 2>/dev/null)" = 600 ] && ok || bad "F3 bundle-source must be mode 600"
grep -q FIXTURE "$T/bundle/bundle-source" 2>/dev/null && bad "F3 bundle-source holds token text" || ok
# The spawn fragment's default-token block, run as spawn_one runs it.
FRAG="$DIR/config/fly-pool.d/3800-spawn-one.sh"
BLOCK=$(awk '/>>> default-token line \(BH-10141\)/,/<<< default-token line/' "$FRAG")
[ -n "$BLOCK" ] || bad "F3 the default-token block is not marked in $FRAG"
fline() { # fline <TMP> <PULL> — the line the block says
  ( : > "$SAY_LOG"; TMP="$1"; PULL="$2"; KEY=TK-903; PAREASON=default_saturated
    eval "$BLOCK"; cat "$SAY_LOG" ) }
L=$(fline "$T/bundle" 0)
[ "$L" = "TK-903 ships the owning box's default claude token, fp $WANT from hub env/global.env (default_saturated)" ] && ok \
  || bad "F3 line: '$L'"
case "$L" in *FIXTURE*) bad "F1 the line holds token text" ;; *) ok ;; esac
rm -f "$T/bundle/bundle-source"
L=$(fline "$T/bundle" 0)
case "$L" in *"fp $WANT from unknown source (default_saturated)") ok ;; *) bad "F3 no sidecar must say unknown source: '$L'" ;; esac
L=$(fline "$T/bundle" 1)
case "$L" in *"fp $WANT from pull base ("*) ok ;; *) bad "F3 a pull spawn must say pull base: '$L'" ;; esac
grep -rq FIXTURE-bh10141 "$SAY_LOG" "$T/pool.log" 2>/dev/null && bad "F1 token text reached a log" || ok

# --- F4 ----------------------------------------------------------------------
for f in "$DIR/bin/fly-pool.sh" "$FRAG"; do
  [ "$(grep -c 'ships the default project-6 token' "$f")" = 0 ] && ok || bad "F4 $f still says project-6"
  grep -q "ships the owning box's default claude token, fp" "$f" && ok || bad "F4 $f lacks the new line"
done

echo "fly-pool-ticket-lock: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
