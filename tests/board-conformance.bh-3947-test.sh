#!/bin/bash
# tests/board-conformance.bh-3947-test.sh — the board API conformance lane
# (BH-3947; this file's first cases are the BH-3958 skeleton).
#
# Drives the REAL bin/board-conformance.sh, copied into a scratch harness by
# tests/lib/board-conformance-fixture.sh, with a stub curl on PATH and a stub
# bin/lane-alert.sh. A case that needs a probe to say something swaps a test
# lib into the scratch copy of bin/lib/board-conformance/<f>.sh; the shipped
# libs are never edited. Fixed BC_NOW, no sleep, no network.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/board-conformance.bh-3947-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/board-conformance-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

ENTRY="$DIR/bin/board-conformance.sh"
LIBS=("$DIR/bin/lib/board-conformance/common.sh" "$DIR/bin/lib/board-conformance/board.sh"
      "$DIR/bin/lib/board-conformance/origin.sh" "$DIR/bin/lib/board-conformance/writes.sh"
      "$DIR/bin/lib/board-conformance/report.sh")
LIVE_BEFORE=$(ls -la /root/harness/state/board-conformance 2>/dev/null)

run() { OUT=$("$HARNESS/bin/board-conformance.sh" "$@" 2>"$T/err"); RC=$?; }
state() { printf '%s' "$HARNESS/state/board-conformance/$1.json"; }
# swap <lib> <body> — replace the scratch copy of one probe lib for this case.
# A swapped lib runs inside the entry, which does not see $T: it uses BCT.
export BCT="$T"
swap() { printf '# shellcheck shell=bash\n%s\n' "$2" > "$HARNESS/bin/lib/board-conformance/$1.sh"; }
# frame — a fixture whose probe libs record nothing, for the cases that pin the
# entry frame rather than a probe (the real probes have their own suites).
frame() { bc_fixture_setup && swap board 'bc_probe_board() { BC_PROBE_NOTE=""; return 0; }' \
  && swap origin 'bc_probe_origin() { :; }' && swap writes 'bc_write_routes() { :; }'; }

# --- Static ------------------------------------------------------------------
for f in "$ENTRY" "${LIBS[@]}"; do
  check "static bash -n $f" 'bash -n "$f"'
  if command -v shellcheck >/dev/null 2>&1; then
    check "static shellcheck $f" 'shellcheck -S error "$f" >/dev/null'
  fi
done

# --- C-run / C-log --------------------------------------------------------------
frame || bad "fixture setup"
run p1
check "C-run rc 0 (got $RC: $(cat "$T/err"))" '[ "$RC" -eq 0 ]'
check "C-run state shape" "jq -e '.project==\"p1\" and .probe==\"ok\" and .probe_note==\"\" and .items=={} and .gaps==[] and .probed_at==\"2026-10-03T07:35:00Z\"' \"$(state p1)\" >/dev/null"
check "C-run no alert call" '[ ! -s "$CALLS" ]'
check "C-run no tmp left" '[ -z "$(ls "$HARNESS/state/board-conformance" | grep -F .tmp.)" ]'
check "C-run summary line (got: $OUT)" '[ "$OUT" = "p1 ok=0 missing=0 malformed=0 unverified=0 gaps: " ]'
check "C-log one line" '[ "$(wc -l < "$HARNESS/logs/board-conformance.log")" -eq 1 ]'
check "C-log line names p1 and BC_NOW" 'grep -q "^2026-10-03T07:35:00Z p1 probe=ok ok=0 missing=0 malformed=0 unverified=0 gaps=-$" "$HARNESS/logs/board-conformance.log"'

# --- C-gh ----------------------------------------------------------------------
bc_fixture_setup || bad "fixture setup"
run gh1
check "C-gh rc 0" '[ "$RC" -eq 0 ]'
check "C-gh skip line (got: $OUT)" '[ "$OUT" = "skip gh1: GitHub-Issues lane" ]'
check "C-gh no state" '[ ! -e "$(state gh1)" ]'
check "C-gh no curl" '[ ! -s "$CURL_LOG" ]'

# --- C-all -----------------------------------------------------------------------
frame || bad "fixture setup"
run --all
check "C-all rc 0 (got $RC)" '[ "$RC" -eq 0 ]'
check "C-all p1 line" 'grep -qx "p1 ok=0 missing=0 malformed=0 unverified=0 gaps: " <<<"$OUT"'
check "C-all p2 line" 'grep -qx "p2 ok=0 missing=0 malformed=0 unverified=0 gaps: " <<<"$OUT"'
check "C-all no gh1 line" '! grep -q gh1 <<<"$OUT"'
check "C-all curl log has no gh1" '! grep -q gh1 "$CURL_LOG"'
check "C-all both states" '[ -s "$(state p1)" ] && [ -s "$(state p2)" ] && [ ! -e "$(state gh1)" ]'
check "C-all one log line per project" '[ "$(wc -l < "$HARNESS/logs/board-conformance.log")" -eq 2 ]'

# --- C-dry -----------------------------------------------------------------------
frame || bad "fixture setup"
run p1 --dry-run
check "C-dry rc 0" '[ "$RC" -eq 0 ]'
check "C-dry no state" '[ ! -e "$(state p1)" ]'
check "C-dry no alert" '[ ! -s "$CALLS" ]'
check "C-dry prints the would-be state" 'grep -q "\"project\": *\"p1\"" <<<"$OUT"'

# --- C-usage -----------------------------------------------------------------------
bc_fixture_setup || bad "fixture setup"
run;                check "C-usage no args rc 2 (got $RC)" '[ "$RC" -eq 2 ]'
run --bogus;        check "C-usage --bogus rc 2" '[ "$RC" -eq 2 ]'
run --all p1;       check "C-usage --all p1 rc 2" '[ "$RC" -eq 2 ]'
run p1 p2;          check "C-usage two projects rc 2" '[ "$RC" -eq 2 ]'
run nosuchproject;  check "C-usage unknown project rc 2 (got $RC)" '[ "$RC" -eq 2 ]'
check "C-usage unknown project no state" '[ ! -e "$(state nosuchproject)" ]'
run --help;         check "C-usage --help rc 0" '[ "$RC" -eq 0 ] && grep -q "board-conformance.sh" <<<"$OUT"'

# --- C-file-ticket -------------------------------------------------------------------
bc_fixture_setup || bad "fixture setup"
echo "pre-existing line" > "$CURL_LOG"; cp "$CURL_LOG" "$T/curl.before"
run --file-ticket p1
check "C-file-ticket rc 2 (got $RC)" '[ "$RC" -eq 2 ]'
check "C-file-ticket no state says run the probe first" 'grep -q "run the probe first" "$T/err"'
check "C-file-ticket no network" 'cmp -s "$CURL_LOG" "$T/curl.before"'
check "C-file-ticket no state" '[ ! -e "$(state p1)" ]'

# --- C-lock ----------------------------------------------------------------------------
frame || bad "fixture setup"
exec 8>"$HARNESS/locks/board-conformance.lock"; flock -n 8
run p1
check "C-lock rc 0" '[ "$RC" -eq 0 ]'
check "C-lock no state" '[ ! -e "$(state p1)" ]'
exec 8>&-

# --- C-gate ----------------------------------------------------------------------------
bc_fixture_setup || bad "fixture setup"
: > "$HARNESS/flags/lane-off-board-conformance"
run --all
check "C-gate rc 0" '[ "$RC" -eq 0 ]'
check "C-gate no project lines" '! grep -qE "^p[12] " <<<"$OUT"'
check "C-gate no state" '[ ! -e "$(state p1)" ]'

# --- C-creds -----------------------------------------------------------------------------
bc_fixture_setup || bad "fixture setup"
printf 'P1_API_BASE=https://p1.example\nMIGRATION_TOKEN=mt-p1\n' > "$HARNESS/env/p1.env"
run p1
check "C-creds rc 3 (got $RC)" '[ "$RC" -eq 3 ]'
check "C-creds state failed" "jq -e '.probe==\"failed\" and (.probe_note|test(\"creds\")) and .items=={} and .gaps==[]' \"$(state p1)\" >/dev/null"
check "C-creds summary (got: $OUT)" '[ "$OUT" = "p1 probe failed: creds unresolved" ]'
check "C-creds no alert call" '[ ! -s "$CALLS" ]'
check "C-creds no curl" '[ ! -s "$CURL_LOG" ]'
check "C-creds board-creds alerted" 'grep -q "p1:.*defines no \*_INTERNAL_API_TOKEN" "$HARNESS/logs/ALERTS.log"'
# both names resolve but the token is empty: the lane names the variable
bc_fixture_setup || bad "fixture setup"
printf 'P1_API_BASE=https://p1.example\nP1_INTERNAL_API_TOKEN=\n' > "$HARNESS/env/p1.env"
run p1
check "C-creds empty value rc 3" '[ "$RC" -eq 3 ]'
check "C-creds empty value alert names the var" 'grep -q "p1: .*sets P1_INTERNAL_API_TOKEN to an empty value (board-conformance)" "$HARNESS/logs/ALERTS.log"'

# --- C-probefail --------------------------------------------------------------------------
bc_fixture_setup || bad "fixture setup"
swap board 'bc_probe_board() { BC_PROBE_NOTE=boom; return 3; }'
swap origin 'bc_probe_origin() { : > "$BCT/origin.called"; }'
swap writes 'bc_write_routes() { : > "$BCT/writes.called"; }'
swap report 'bc_alert_on_change() { : > "$BCT/alert.called"; }
bc_file_ticket() { return 2; }'
run p1
check "C-probefail rc 3 (got $RC)" '[ "$RC" -eq 3 ]'
check "C-probefail state" "jq -e '.probe==\"failed\" and .probe_note==\"boom\" and .items=={} and .gaps==[]' \"$(state p1)\" >/dev/null"
check "C-probefail origin skipped" '[ ! -e "$T/origin.called" ]'
check "C-probefail writes skipped" '[ ! -e "$T/writes.called" ]'
check "C-probefail no alert" '[ ! -e "$T/alert.called" ]'
check "C-probefail summary (got: $OUT)" '[ "$OUT" = "p1 probe failed: boom" ]'
# the same swaps with an ok board probe DO reach the other probes and the alert,
# with the state file already in place
swap board 'bc_probe_board() { [ "$1" = /api/board ] && [ "$2" = https://p1.example ] && [ "$3" = tok-p1 ] || return 3; }'
swap origin 'bc_probe_origin() { printf "%s\n" "$*" > "$BCT/origin.called"; }'
swap report 'bc_alert_on_change() { [ -s "$2" ] && printf "%s\n" "$*" > "$BCT/alert.called"; }
bc_file_ticket() { return 2; }'
run p1
check "C-probefail ok path rc 0 (got $RC)" '[ "$RC" -eq 0 ]'
# TEST-CHANGE (BH-8918): the entry passes the board prefix (fleet.conf column 4)
# as bc_probe_origin's 5th arg; the lib skips the app internals only under
# /api/hosted-board/. The first four args are unchanged.
check "C-probefail ok path origin args" '[ "$(cat "$T/origin.called")" = "https://p1.example https://p1.example tok-p1 mt-p1 /api/board" ]'
check "C-probefail ok path writes called" '[ -e "$T/writes.called" ]'
check "C-probefail ok path alert after state" '[ "$(cat "$T/alert.called")" = "p1 $(state p1)" ]'

# --- C-unverified ---------------------------------------------------------------------------
frame || bad "fixture setup"
swap writes 'bc_write_routes() { bc_item route.x unverified n; bc_item route.y missing n; bc_item route.y missing again; bc_item route.z ok n; }'
run p1
check "C-unverified rc 1 (got $RC)" '[ "$RC" -eq 1 ]'
check "C-unverified items" "jq -e '(.items|keys)==[\"route.x\",\"route.y\",\"route.z\"] and .items[\"route.y\"].note==\"again\" and .gaps==[\"route.y\"]' \"$(state p1)\" >/dev/null"
check "C-unverified summary (got: $OUT)" '[ "$OUT" = "p1 ok=1 missing=1 malformed=0 unverified=1 gaps: route.y" ]'
check "C-unverified log" 'grep -q "p1 probe=ok ok=1 missing=1 malformed=0 unverified=1 gaps=route.y$" "$HARNESS/logs/board-conformance.log"'

# --- C-rc --------------------------------------------------------------------------------------
frame || bad "fixture setup"
swap board 'bc_probe_board() { if [ "$1" = /api/board ]; then BC_PROBE_NOTE=down; return 3; fi; }'
swap writes 'bc_write_routes() { bc_item "route.$1" malformed n; }'
run --all
check "C-rc worst wins (got $RC)" '[ "$RC" -eq 3 ]'
check "C-rc p1 failed line" 'grep -qx "p1 probe failed: down" <<<"$OUT"'
check "C-rc p2 gap line" 'grep -qx "p2 ok=0 missing=0 malformed=1 unverified=0 gaps: route.p2" <<<"$OUT"'
swap board 'bc_probe_board() { return 0; }'
run --all
check "C-rc gaps only = 1 (got $RC)" '[ "$RC" -eq 1 ]'
# an empty --all is not a quiet success
printf 'gh1 org/gh1 - - 0 hub\n' > "$HARNESS/fleet.conf"
run --all
check "C-rc empty --all rc 2 (got $RC)" '[ "$RC" -eq 2 ]'

# --- C-secret / C-nowrite (over every curl call this suite made through bc_get) ------------
bc_fixture_setup || bad "fixture setup"
swap board 'bc_probe_board() { bc_get "$2/api/health" "$BCT/body" "$3" >/dev/null; }'
run --all
check "C-secret curl sends the bearer" 'grep -q "Authorization: Bearer tok-p1" "$CURL_LOG"'
check "C-secret not in stdout" '! grep -qE "tok-p|mt-p" <<<"$OUT$(cat "$T/err")"'
check "C-secret not in the log" '! grep -qE "tok-p|mt-p" "$HARNESS/logs/board-conformance.log"'
check "C-secret not in ALERTS" '! grep -qsE "tok-p|mt-p" "$HARNESS/logs/ALERTS.log"'
check "C-nowrite no -X/-d/--data" '! grep -qE "(^| )(-X|-d|--data[a-z-]*)( |$)" "$CURL_LOG"'

# --- C-get / C-class / C-item (the lib, sourced) ------------------------------------------------
bc_fixture_setup || bad "fixture setup"
: > "$CURL_LOG"
code=$( . "${LIBS[0]}"; bc_get https://p1.example/api/health "$T/o" )
check "C-get prints the fixture code (got $code)" '[ "$code" = 200 ]'
check "C-get body written" 'grep -q "\"ok\"" "$T/o"'
check "C-get argv" 'grep -qF -- "-s -m 20 -o $T/o -w %{http_code} -H User-Agent: curl/8 https://p1.example/api/health" "$CURL_LOG"'
check "C-get no auth without a token" '! grep -q Authorization "$CURL_LOG"'
: > "$CURL_LOG"
code=$( . "${LIBS[0]}"; BC_TIMEOUT_S=5 bc_get https://p1.example/api/nothing "$T/o" sekrit )
check "C-get 404 for a missing route (got $code)" '[ "$code" = 404 ]'
check "C-get timeout knob + bearer" 'grep -qF -- "-m 5 " "$CURL_LOG" && grep -qF "Authorization: Bearer sekrit" "$CURL_LOG"'
printf '#!/bin/bash\nexit 7\n' > "$T/stub/curl"
code=$( . "${LIBS[0]}"; bc_get https://p1.example/api/health "$T/o" )
check "C-get dead curl is 000 (got $code)" '[ "$code" = 000 ]'
cls=$( . "${LIBS[0]}"; for c in 200 204 404 000 "" 503 401 302; do bc_class "$c"; done | tr '\n' ' ')
check "C-class (got $cls)" '[ "$cls" = "2xx 2xx 404 000 000 5xx other other " ]'
(
  . "${LIBS[0]}"
  BC_ITEMS="$T/items"; : > "$BC_ITEMS"
  bc_item a.b ok "a note"; echo "rc=$?"
  bc_item a.c bogus n; echo "rc=$?"
  bc_item "" ok n; echo "rc=$?"
  BC_ITEMS="" bc_item a.d ok n; echo "rc=$?"
) > "$T/item.out"
check "C-item rcs (got $(tr '\n' ' ' < "$T/item.out"))" '[ "$(tr "\n" " " < "$T/item.out")" = "rc=0 rc=2 rc=2 rc=2 " ]'
check "C-item one valid JSON line" "[ \"\$(wc -l < \"$T/items\")\" -eq 1 ] && jq -e '.name==\"a.b\" and .status==\"ok\" and .note==\"a note\"' \"$T/items\" >/dev/null"

# --- C-registry / C-cron -------------------------------------------------------------------------
check "C-registry" "jq -e '.id==\"board-conformance\" and .scope==\"hub\" and .script==\"bin/board-conformance.sh\" and .cadence==\"35 7 * * *\" and .boxes==[\"hub\"] and .switch.name==\"lane-off-board-conformance\" and .wired and (.knobs|map(.env)|sort)==[\"BC_NOW\",\"BC_TIMEOUT_S\"] and (.knobs[]|select(.env==\"BC_NOW\")|.settable)==false and .stats.log==\"logs/board-conformance.log\"' \"$DIR/catalog/lanes.d/board-conformance.json\" >/dev/null"
. "$DIR/tests/lib/rendered.sh" || exit 1
CRONS=$(rendered_cron_dir) || exit 1
check "C-cron hub runs it behind the lease" 'grep -qF "35 7 * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/board-conformance.sh --all" "$CRONS/hub.cron"'
OTHER=$(grep -lF board-conformance.sh "$CRONS"/*.cron | grep -v '/hub\.cron$')
check "C-cron no other box (got: $OTHER)" '[ -z "$OTHER" ]'

# --- the live harness was never touched ------------------------------------------------------------
check "live /root/harness/state/board-conformance unchanged" '[ "$(ls -la /root/harness/state/board-conformance 2>/dev/null)" = "$LIVE_BEFORE" ]'

echo "board-conformance: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
