#!/bin/bash
# tests/conductor-mode.bh-1201-test.sh — BH-1201.0 shell contract, driven for real.
#
# Block 1: the four client verbs of bin/lib/jobs/conductor.sh, through the REAL
# bin/jobs-client.sh dispatch (so the JC_MODULES line and the four case arms are
# part of what is proved) against a fake curl that records every request.
# Block 2: bin/lib/conductor-mode.sh's two readers — conductor_mode() answers
# only from the settings row (never from a flag file, which is why the
# flags/automerge-disabled case is here), and conductor_hold_active holds on
# kill-switch|observe|unknown unless the lane's knob is explicitly 0.
#
# Run from anywhere: tests/conductor-mode.bh-1201-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=$(date -u '+%s')

mkdir -p "$T/h/bin/lib/jobs" "$T/h/env" "$T/h/logs" "$T/h/flags" "$T/h/state" "$T/fakebin"

# BOTH SUBJECTS ARE NAMED HERE BY LITERAL PATH, ON A NON-COMMENT LINE, ON PURPOSE.
# bin/test-impact.sh's ORPHAN ratchet asks "does any suite mention this script?"
# over a map built with TI_ORPHAN_STRICT=1, which skips `#`-led lines and does
# NOT expand a glob. So `cp "$DIR"/bin/lib/jobs/*.sh` reaches conductor.sh at
# run time and is invisible to the map -- which is exactly how the first build of
# this ticket (#1473) turned CI red three times on tests/test-impact-test.sh G2
# with bin/lib/jobs/conductor.sh as a NEW orphan. These two guards are the fix,
# and they are real assertions rather than a comment: a missing subject aborts
# the suite here instead of failing eleven cases below for no stated reason.
[ -r "$DIR/bin/lib/jobs/conductor.sh" ] || { echo "FAIL: missing bin/lib/jobs/conductor.sh"; exit 1; }
[ -r "$DIR/bin/lib/conductor-mode.sh" ] || { echo "FAIL: missing bin/lib/conductor-mode.sh"; exit 1; }
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/lane-gate.sh"
cp "$DIR/bin/lib/conductor-mode.sh" "$T/h/bin/lib/conductor-mode.sh"
echo 'HARNESS_SECRET=test-secret' > "$T/h/env/global.env"

# A fake curl that records "METHOD URL BODY" and answers body\n<status>.
# MODE_ROW is the value of the merge-conductor.mode settings row the stub serves
# (empty = no row at all), so block 2 can move the worker's answer per case.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    -H) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)    exit 7 ;;
  garbage) printf 'not json at all\n200\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "PUT "*/api/settings)  printf '{"ok":true}\n200\n' ;;
  "GET "*/api/settings/merge-conductor.mode)
      if [ -n "${MODE_ROW:-}" ]; then printf '{"setting":{"key":"merge-conductor.mode","value":"%s"}}\n200\n' "$MODE_ROW"
      else printf '{"error":"not found"}\n404\n'; fi ;;
  "GET "*/api/settings)
      ROWS="[]"
      [ -n "${MODE_ROW:-}" ] && ROWS=$(printf '[{"key":"merge-conductor.mode","value":"%s"}]' "$MODE_ROW")
      [ -n "${KNOB_ROW:-}" ] && ROWS=$(printf '%s' "$ROWS" | jq -c --arg v "$KNOB_ROW" '. + [{key:"lane.alert-triage.triage_conductor_hold",value:$v}]')
      printf '{"settings":%s}\n200\n' "$ROWS" ;;
  "PUT "*/api/conductor/held)          printf '{"ok":true}\n200\n' ;;
  "POST "*/api/conductor/held/release) printf '{"released":1}\n200\n' ;;
  "GET "*/api/conductor/held*)
      printf '{"rows":[{"repo":"o/r","number":11,"state":"WAIT_CI","head":"deadbeef","kind":"STUCK","text":"first\\tline\\nwrapped","mark":"m1","mode":"merge","first_held_at":"2026-09-01T00:00:00Z","last_seen_at":"2026-09-02T00:00:00Z"},{"repo":"o/r","number":12,"state":"READY","head":"cafe","kind":"BUDGET","text":"second","mark":null,"mode":"observe","first_held_at":"2026-09-03T00:00:00Z","last_seen_at":"2026-09-04T00:00:00Z"}],"n_total":2}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# The PRODUCTION entry point: bin/jobs-client.sh <verb>, exactly as a lane runs it.
cli() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid REQ_SINK="$T/req.log" JOBS_BOX=test-box \
           JOBS_RETRIES=0 ${EXTRA_ENV:-}
    bash "$T/h/bin/jobs-client.sh" "$@" 2>/dev/null )
}
body_of() { grep -m1 "$1" "$T/req.log" 2>/dev/null | sed 's/^[^ ]* [^ ]* //'; }
nth_body() { sed -n "${2}p" "$T/req.log" 2>/dev/null | grep "$1" | sed 's/^[^ ]* [^ ]* //'; }

echo "== block 1: client verbs =="

# --- 1. conductor-mode-publish writes the two settings rows ------------------
rm -f "$T/req.log"
cli conductor-mode-publish kill-switch "3 STUCK=2 BUDGET=1"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "1 conductor-mode-publish rc=$RC, wanted 0"
NPUT=$(grep -c 'PUT .*api/settings' "$T/req.log" 2>/dev/null) || true
[ "$NPUT" -eq 2 ] && ok || bad "1b conductor-mode-publish sent $NPUT PUT /api/settings, wanted 2"
B1=$(nth_body 'PUT .*api/settings' 1); B2=$(nth_body 'PUT .*api/settings' 2)
[ "$(printf '%s' "$B1" | jq -r '.key')" = "merge-conductor.mode" ] \
  && [ "$(printf '%s' "$B1" | jq -r '.value')" = "kill-switch" ] \
  && ok || bad "1c first settings body wrong: $B1"
[ "$(printf '%s' "$B2" | jq -r '.key')" = "merge-conductor.held_pages" ] \
  && [ "$(printf '%s' "$B2" | jq -r '.value')" = "3 STUCK=2 BUDGET=1" ] \
  && ok || bad "1d second settings body wrong: $B2"

# --- 2. an empty summary is the word 0, never an empty row -------------------
# setting_set refuses an empty value (rc 1), so a conductor with nothing held
# would publish a mode row and no count row at all.
rm -f "$T/req.log"
cli conductor-mode-publish observe ""; RC=$?
B2=$(nth_body 'PUT .*api/settings' 2)
[ "$RC" -eq 0 ] && [ "$(printf '%s' "$B2" | jq -r '.value')" = "0" ] \
  && ok || bad "2 empty summary rc=$RC body=$B2, wanted rc 0 and value 0"

# --- 3. the summary is truncated to the settings 256-char limit --------------
# A 2000-char summary is refused by the worker's value validation, which would
# drop the mode row's companion count on exactly the busiest tick.
rm -f "$T/req.log"
LONG=$(printf 'x%.0s' $(seq 1 300))
cli conductor-mode-publish merge "$LONG" >/dev/null
B2=$(nth_body 'PUT .*api/settings' 2)
VLEN=$(printf '%s' "$B2" | jq -r '.value | length')
[ "$VLEN" = "256" ] && ok || bad "3 held_pages value was $VLEN chars, wanted 256"

# --- 4. held-page-put sends the eight fields; mark omitted when empty --------
rm -f "$T/req.log"
cli held-page-put o/r 12 WAIT_CI deadbeef STUCK "stuck 3h" mark-1 merge; RC=$?
BODY=$(body_of 'PUT .*api/conductor/held')
if [ "$RC" -eq 0 ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.repo')" = "o/r" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.number')" = "12" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.number|type')" = "number" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.state')" = "WAIT_CI" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.head')" = "deadbeef" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.kind')" = "STUCK" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.text')" = "stuck 3h" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.mark')" = "mark-1" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.mode')" = "merge" ]; then ok
else bad "4 held-page-put rc=$RC body=$BODY"; fi
rm -f "$T/req.log"
cli held-page-put o/r 12 WAIT_CI deadbeef STUCK "stuck 3h" "" merge >/dev/null
BODY=$(body_of 'PUT .*api/conductor/held')
[ "$(printf '%s' "$BODY" | jq -r 'has("mark")')" = "false" ] \
  && ok || bad "4b empty mark was sent as a field: $BODY"

# --- 5. held-pages-list renders TSV, oldest first, text escaped --------------
rm -f "$T/req.log"
OUT=$(cli held-pages-list); RC=$?
[ "$RC" -eq 0 ] && ok || bad "5 held-pages-list rc=$RC, wanted 0"
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 2 ] && ok || bad "5b held-pages-list printed $(printf '%s\n' "$OUT" | wc -l) lines, wanted 2"
L1=$(printf '%s\n' "$OUT" | sed -n 1p); L2=$(printf '%s\n' "$OUT" | sed -n 2p)
[ "$(printf '%s' "$L1" | cut -f2)" = "11" ] && [ "$(printf '%s' "$L2" | cut -f2)" = "12" ] \
  && ok || bad "5c rows not oldest first: '$L1' / '$L2'"
[ "$(printf '%s' "$L1" | awk -F'\t' '{print NF}')" = "10" ] \
  && ok || bad "5d row 1 has $(printf '%s' "$L1" | awk -F'\t' '{print NF}') columns, wanted 10"
# A tab or newline inside text must not shift the columns a reader parses.
grep -qF 'first\tline\nwrapped' <<<"$L1" \
  && ok || bad "5e text was not tab/newline escaped: '$L1'"
[ "$(printf '%s' "$L2" | cut -f7)" = "" ] && ok || bad "5f null mark did not render empty: '$L2'"
# The limit reaches the URL.
rm -f "$T/req.log"; cli held-pages-list 7 >/dev/null
grep -q 'api/conductor/held?limit=7' "$T/req.log" && ok || bad "5g limit not in URL: $(cat "$T/req.log")"
rm -f "$T/req.log"; cli held-pages-list >/dev/null
grep -q 'api/conductor/held?limit=100' "$T/req.log" && ok || bad "5h default limit not 100: $(cat "$T/req.log")"

# --- 6. held-page-release prints the released count --------------------------
rm -f "$T/req.log"
OUT=$(cli held-page-release o/r 12 WAIT_CI deadbeef STUCK "landed"); RC=$?
BODY=$(body_of 'POST .*api/conductor/held/release')
if [ "$RC" -eq 0 ] && [ "$OUT" = "1" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.repo')" = "o/r" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.number')" = "12" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.kind')" = "STUCK" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.why')" = "landed" ]; then ok
else bad "6 held-page-release rc=$RC out='$OUT' body=$BODY"; fi

# --- 6b. a release with no reason is refused HERE, before the request -------
# The worker requires `why` (1..2000). The client refuses an empty one itself so
# the caller gets rc 1 rather than a 400 the fail-open contract would flatten
# into "the worker is down" -- two very different things for a lane deciding
# whether a hold is still held.
rm -f "$T/req.log"
OUT=$(cli held-page-release o/r 12 WAIT_CI deadbeef STUCK ""); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "6b an empty why gave rc=$RC out='$OUT', wanted 1 and empty"
[ ! -s "$T/req.log" ] && ok || bad "6c an empty why still sent a request: $(cat "$T/req.log")"

# --- 7. CURL_MODE=down: every verb rc 1 and one log line --------------------
rm -f "$T/h/logs/jobs-client.log"
for V in "conductor-mode-publish merge 0" "held-page-put o/r 12 WAIT_CI h STUCK t m merge" \
         "held-pages-list" "held-page-release o/r 12 WAIT_CI h STUCK why"; do
  # shellcheck disable=SC2086
  OUT=$(EXTRA_ENV="CURL_MODE=down" cli $V); RC=$?
  [ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "7 '$V' with the worker down gave rc=$RC out='$OUT', wanted 1 and empty"
done
[ -s "$T/h/logs/jobs-client.log" ] && ok || bad "7b the outage left no logs/jobs-client.log line"

# --- 8. a 200 that is not JSON is an outage, never an empty held list -------
OUT=$(EXTRA_ENV="CURL_MODE=garbage" cli held-pages-list); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] && ok || bad "8 non-JSON 200 gave rc=$RC out='$OUT', wanted 1 and empty"

echo "== block 2: conductor_mode / conductor_hold_active =="

# Each case runs in a child shell with a COLD cache, sourcing lane-gate.sh (so
# the 60s settings cache path is the one exercised) and then the helper.
ask() { # ask <fn> [args...] — prints stdout, returns the helper's rc
  rm -f "$T/h/state/settings-cache.json"; rm -rf "$T/h/state/lane-gate"
  env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
      JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 LANE_GATE_NOW="$NOW" \
      MODE_ROW="${MODE_ROW:-}" KNOB_ROW="${KNOB_ROW:-}" CURL_MODE="${CURL_MODE:-ok}" \
      bash -c '
        set -uo pipefail
        . "$HARNESS/bin/lib/lane-gate.sh"
        . "$HARNESS/bin/lib/conductor-mode.sh"
        "$@"' _ "$@" 2>/dev/null
}

# --- 9. the five words --------------------------------------------------------
for M in merge actions observe kill-switch; do
  OUT=$(MODE_ROW="$M" ask conductor_mode); RC=$?
  [ "$RC" -eq 0 ] && [ "$OUT" = "$M" ] && ok || bad "9 conductor_mode on row '$M' gave rc=$RC out='$OUT'"
done
OUT=$(MODE_ROW="garbage" ask conductor_mode); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "unknown" ] && ok || bad "9b a garbage row gave '$OUT', wanted unknown"
# Cold start: no row at all (the documented state until the conductor ships).
OUT=$(MODE_ROW="" ask conductor_mode); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "unknown" ] && ok || bad "9c no row gave '$OUT', wanted unknown"
# Worker down and nothing cached.
OUT=$(CURL_MODE=down MODE_ROW="kill-switch" ask conductor_mode); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "unknown" ] && ok || bad "9d worker down gave rc=$RC '$OUT', wanted 0 unknown"

# --- 10. conductor_hold_active: the mode decides, and it prints the word -----
OUT=$(MODE_ROW="kill-switch" ask conductor_hold_active alert-triage TRIAGE_CONDUCTOR_HOLD); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "kill-switch" ] && ok || bad "10a kill-switch gave rc=$RC out='$OUT', wanted 0 'kill-switch'"
OUT=$(MODE_ROW="observe" ask conductor_hold_active alert-triage TRIAGE_CONDUCTOR_HOLD); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "observe" ] && ok || bad "10b observe gave rc=$RC out='$OUT', wanted 0 'observe'"
OUT=$(MODE_ROW="actions" ask conductor_hold_active alert-triage TRIAGE_CONDUCTOR_HOLD); RC=$?
[ "$RC" -eq 1 ] && [ "$OUT" = "actions" ] && ok || bad "10c actions gave rc=$RC out='$OUT', wanted 1 'actions'"
OUT=$(MODE_ROW="merge" ask conductor_hold_active alert-triage TRIAGE_CONDUCTOR_HOLD); RC=$?
[ "$RC" -eq 1 ] && [ "$OUT" = "merge" ] && ok || bad "10d merge gave rc=$RC out='$OUT', wanted 1 'merge'"
# unknown FAILS CLOSED on spend: a hold is re-offered next tick, not dropped.
OUT=$(CURL_MODE=down ask conductor_hold_active alert-triage TRIAGE_CONDUCTOR_HOLD); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "unknown" ] && ok || bad "10e unknown gave rc=$RC out='$OUT', wanted 0 'unknown'"

# --- 11. the lane's knob at 0 overrides the hold -----------------------------
# An operator who set lane.alert-triage.triage_conductor_hold=0 has opted this
# lane out; the kill-switch must not hold it anyway.
OUT=$(MODE_ROW="kill-switch" KNOB_ROW=0 ask conductor_hold_active alert-triage TRIAGE_CONDUCTOR_HOLD); RC=$?
[ "$RC" -eq 1 ] && ok || bad "11a knob=0 under kill-switch gave rc=$RC, wanted 1 (no hold)"
OUT=$(MODE_ROW="kill-switch" KNOB_ROW=1 ask conductor_hold_active alert-triage TRIAGE_CONDUCTOR_HOLD); RC=$?
[ "$RC" -eq 0 ] && ok || bad "11b knob=1 under kill-switch gave rc=$RC, wanted 0 (hold)"
# Unset/unregistered reads as on: a knob nobody wrote must not disable the hold.
OUT=$(MODE_ROW="observe" KNOB_ROW="" ask conductor_hold_active alert-triage TRIAGE_CONDUCTOR_HOLD); RC=$?
[ "$RC" -eq 0 ] && ok || bad "11c an unset knob disabled the hold (rc=$RC)"

# --- 12. NEGATIVE: the helper never reads a flag file ------------------------
# The source of truth is the D1 settings row. A box-local flags/* file must not
# move the answer in either direction, or two boxes would disagree about whether
# the conductor is holding and nothing would say so.
touch "$T/h/flags/automerge-disabled" "$T/h/flags/lane-off-alert-triage" "$T/h/flags/all-off"
OUT=$(MODE_ROW="merge" ask conductor_mode); RC=$?
[ "$OUT" = "merge" ] && ok || bad "12a a flag file changed conductor_mode: '$OUT'"
OUT=$(MODE_ROW="merge" ask conductor_hold_active alert-triage TRIAGE_CONDUCTOR_HOLD); RC=$?
[ "$RC" -eq 1 ] && [ "$OUT" = "merge" ] && ok \
  || bad "12b flags/automerge-disabled with the worker answering 'merge' gave rc=$RC out='$OUT', wanted 1 'merge'"
rm -f "$T/h/flags/automerge-disabled" "$T/h/flags/lane-off-alert-triage" "$T/h/flags/all-off"

# --- 13. no client at all: still one of the five words, still fail-closed ----
OUT=$(env HARNESS="$T/h" bash -c '
        set -uo pipefail
        . "$HARNESS/bin/lib/conductor-mode.sh"
        conductor_mode' 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "unknown" ] && ok || bad "13 with no client sourced: rc=$RC out='$OUT', wanted 0 unknown"

# --- 14. the flag-file negative as a STATIC belt, guarded ------------------
# Case 12 proves the BEHAVIOUR (a flag on disk does not move the answer). This
# is the belt: the reader must not reach for flags/ at all, so a future edit
# that adds a "quick" file check is refused here even if it happens to agree
# with the settings row on the day it lands. Guarded against the absent-file
# trap (D3): the grep only means something if the file is really there, so a
# typo'd path fails the case instead of passing it on zero matches.
if [ -r "$DIR/bin/lib/conductor-mode.sh" ]; then
  if grep -nE 'flags/|/flags|_flag_' "$DIR/bin/lib/conductor-mode.sh" >/dev/null 2>&1; then
    bad "14 bin/lib/conductor-mode.sh reaches for a flag file: $(grep -nE 'flags/|/flags|_flag_' "$DIR/bin/lib/conductor-mode.sh" | tr '\n' ' ')"
  else
    ok
  fi
else
  bad "14 could not read bin/lib/conductor-mode.sh to check it"
fi

echo "conductor-mode-bh-1201: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
