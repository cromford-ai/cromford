#!/bin/bash
# tests/claude-cli-pin.bh-9911-test.sh — BH-9911: the pinned Claude Code CLI
# version, the canary decision and the hub lane bin/claude-cli-pin.sh.
#
#   P1-P6  bin/lib/claude-cli-pin.sh: the pin row, its fallback (equal to the
#          schema seed), a "latest" row, the canary decision table, the hub is
#          never the canary, and the knob-outage answer (rc 2 only when the
#          last known state was on)
#   M1-M8  promote: soak green -> the pinned row is set; a red row, a run
#          younger than the soak, a new failure class, a canary not newer than
#          the pin, a failed read, rows of another box or an ok of "1 " ->
#          no write; pin off -> no read
#   W1-W6  watch: a newer release becomes the canary; equal, older, npm error
#          text, "latest" or empty -> no write; the pin row is never written
#   D1-D9  drift: one warn per box or image off the pin, none for the canary on
#          its version or a stale row, no repeat on the next run, a console
#          with no beat path -> ALERTS, pin off -> no read, a failed read ->
#          "drift: not measured"; D10 an answer with no boxes array -> not measured
#   W7     watch's npm view kill timeout is the row claude_cli.watch_kill_after_s
#
# The real bin/claude-cli-pin.sh runs against a file-backed fake worker
# (tests/lib/claude-cli-pin-fakes.sh): zero network, zero vendor calls.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/claude-cli-pin.bh-9911-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/claude-cli-pin-fakes.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
SEED="$DIR/worker/jobs/schema.d/202611241159-bh-9911-claude-cli-smoke.sql"
SEED2="$DIR/worker/jobs/schema.d/202611241200-bh-9911-claude-cli-smoke-caps.sql"
NOWE=1795000000   # fixed clock (2026-11-18), passed as CCP_NOW
isoh() { date -u -d "@$((NOWE - $1 * 3600))" '+%Y-%m-%dT%H:%M:%SZ'; }

# new_case <id> -> H: a scratch harness with the lane's closure, a fake worker
# under $H/f, a stub beat.sh (rc from $H/beat-rc) and a stub alert-line.sh.
new_case() {
  H="$T/$1"; mkdir -p "$H/logs" "$H/state/fly" "$H/env"
  scratch_install_closure bin/claude-cli-pin.sh "$H" >/dev/null || bad "$1: closure install"
  ccpf_new "$H/f"
  printf '#!/bin/bash\necho "$*" >> "$HARNESS/beats.log"\nexit "$(cat "$HARNESS/beat-rc" 2>/dev/null || echo 0)"\n' > "$H/bin/beat.sh"
  printf '#!/bin/bash\necho "$*" >> "$HARNESS/logs/ALERTS.log"\n' > "$H/bin/alert-line.sh"
  chmod +x "$H/bin/beat.sh" "$H/bin/alert-line.sh"
}
ENVV() {
  echo PATH="$H/f/fakebin:/usr/bin:/bin" HOME="$H" HARNESS="$H" JOBS_URL=https://jobs.test \
       HARNESS_SECRET=tok-fixture-bh9911 HARNESS_TEST_SANDBOX=1 CCPF_W="$H/f/w" JOBS_RETRY_SLEEP=0 \
       JOBS_SETTINGS_CACHE_S=0 JOBS_OVERLOAD_RETRIES=0 CCP_NOW="$NOWE"
}
# run_pin <verb> [VAR=value...] -> OUT, RC. The script is the repo's own.
run_pin() {
  local verb="$1"; shift
  # shellcheck disable=SC2046
  OUT=$(env -i $(ENVV) "$@" bash "$DIR/bin/claude-cli-pin.sh" "$verb" 2>&1); RC=$?
}
# lib <bash code> -> OUT, ERR, RC with the jobs client and the lib loaded.
lib() {
  # shellcheck disable=SC2046
  OUT=$(env -i $(ENVV) bash -c '. "$1/bin/jobs-client.sh" 2>/dev/null; . "$1/bin/lib/claude-cli-pin.sh"; eval "$2"' _ "$DIR" "$1" 2>"$H/err"); RC=$?
  ERR=$(cat "$H/err")
}
on() { ccpf_set "$H/f" claude_cli.pin.enabled 1; ccpf_set "$H/f" claude_cli.pinned_version 2.1.330; }
# run_rows <run_id> <hours_ago> <stdin> <late_stdin> <tool_call> <haiku> <lane_tick> <fail_classes> [box] [version]
run_rows() {
  local r="$1" at; at=$(isoh "$2"); shift 2
  local s i=0 steps=(stdin late_stdin tool_call haiku lane_tick fail_classes) oks=("$1" "$2" "$3" "$4" "$5" "$6")
  for s in "${steps[@]}"; do
    [ "${oks[$i]}" = - ] || ccpf_row "$H/f" "${7:-small}" "${8:-2.1.331}" "$r" "$s" "${oks[$i]}" "$at"
    i=$((i + 1))
  done
}
pinned() { ccpf_get "$H/f" claude_cli.pinned_version; }
puts() { cat "$H/f/w/settings-put.log" 2>/dev/null; }

# ===========================================================================
# P — the library
# ===========================================================================
new_case p1; ccpf_set "$H/f" claude_cli.pinned_version 2.1.340
lib ccp_pinned_version
[ "$OUT" = 2.1.340 ] && ok || bad "P1 row 2.1.340 read as '$OUT' ($ERR)"

new_case p2
lib ccp_pinned_version
[ "$OUT" = 2.1.330 ] && ok || bad "P2 no row: want the fallback 2.1.330, got '$OUT'"
grep -q 'WARN' <<<"$ERR" && ok || bad "P2 no row gave no WARN"
# Every lib fallback equals the seeded row in the schema fragment.
[ -f "$SEED" ] && ok || bad "P2 schema fragment $SEED missing"
for pair in claude_cli.pinned_version:CCP_PINNED_FALLBACK claude_cli.canary_box:CCP_CANARY_BOX_FALLBACK \
            claude_cli.canary_soak_h:CCP_SOAK_H_FALLBACK claude_cli.smoke_interval_h:CCP_SMOKE_INTERVAL_H_FALLBACK \
            claude_cli.smoke_late_stdin_s:CCP_LATE_STDIN_S_FALLBACK claude_cli.smoke_step_timeout_s:CCP_STEP_TIMEOUT_S_FALLBACK \
            claude_cli.fail_class_window_h:CCP_FAIL_CLASS_WINDOW_H_FALLBACK claude_cli.watch_timeout_s:CCP_WATCH_TIMEOUT_S_FALLBACK \
            claude_cli.drift_max_age_h:CCP_DRIFT_MAX_AGE_H_FALLBACK claude_cli.smoke_list_limit:CCP_SMOKE_LIST_LIMIT_FALLBACK; do
  key="${pair%%:*}"; var="${pair#*:}"
  lib "printf '%s' \"\$$var\""; fb="$OUT"
  seed=$(grep -oE "\('$key','[^']*'" "$SEED" 2>/dev/null | head -1 | sed -E "s/.*,'([^']*)'$/\1/")
  [ -n "$fb" ] && [ "$fb" = "$seed" ] && ok || bad "P2 $key: lib fallback '$fb' != seeded '$seed'"
done
grep -q "('claude_cli.pin.enabled','0'" "$SEED" 2>/dev/null && ok || bad "P2 claude_cli.pin.enabled is not seeded 0"
# The step grace knobs (lead review of a14a874bd8c2) are seeded in a later fragment.
for pair in claude_cli.smoke_step_grace_s:CCP_STEP_GRACE_S_FALLBACK claude_cli.smoke_step_kill_after_s:CCP_STEP_KILL_AFTER_S_FALLBACK \
            claude_cli.watch_kill_after_s:CCP_WATCH_KILL_AFTER_S_FALLBACK claude_cli.smoke_detail_max:CCP_SMOKE_DETAIL_MAX_FALLBACK \
            claude_cli.smoke_excerpt_max:CCP_SMOKE_EXCERPT_MAX_FALLBACK; do
  key="${pair%%:*}"; var="${pair#*:}"
  lib "printf '%s' \"\$$var\""; fb="$OUT"
  seed=$(grep -oE "\('$key','[^']*'" "$SEED2" 2>/dev/null | head -1 | sed -E "s/.*,'([^']*)'$/\1/")
  [ -n "$fb" ] && [ "$fb" = "$seed" ] && ok || bad "P2 $key: lib fallback '$fb' != seeded '$seed' ($SEED2)"
done

new_case p3; ccpf_set "$H/f" claude_cli.pinned_version latest
lib ccp_pinned_version
[ "$OUT" = 2.1.330 ] && grep -q 'not a version' <<<"$ERR" && ok || bad "P3 'latest' row: got '$OUT' / '$ERR'"

new_case p4
chk_canary() { # <box> <canary-box> <want 0|1>
  lib "ccp_is_canary '$1' '$2'"
  [ "$RC" = "$3" ] && ok || bad "P4 ccp_is_canary '$1' '$2': rc $RC, want $3"
}
chk_canary small box-small 0
chk_canary box-small box-small 0
chk_canary small small 0
chk_canary small-2 box-small 1
chk_canary box-small-2 box-small 1
chk_canary SMALL box-small 1
chk_canary "" box-small 1
chk_canary small box- 1
# With no argument the row decides; with no row the default is box-small.
lib "ccp_is_canary small"; [ "$RC" = 0 ] && ok || bad "P4 default canary box is not small (rc $RC)"
ccpf_set "$H/f" claude_cli.canary_box box-project-4-1
lib "ccp_is_canary small"; [ "$RC" = 1 ] && ok || bad "P4 row box-project-4-1 still matched small"
lib "ccp_is_canary project-4"; [ "$RC" = 0 ] && ok || bad "P4 row box-project-4-1 did not match project-4"
# The prefix stripped is HARNESS_BOX_PREFIX, not a literal (lead review of a14a874bd8c2).
lib "HARNESS_BOX_PREFIX=fleet-; ccp_is_canary fleet-small small"; [ "$RC" = 0 ] && ok || bad "P4 prefix fleet-: fleet-small did not match small (rc $RC)"
lib "HARNESS_BOX_PREFIX=fleet-; ccp_is_canary small fleet-small"; [ "$RC" = 0 ] && ok || bad "P4 prefix fleet-: small did not match row fleet-small (rc $RC)"
lib "HARNESS_BOX_PREFIX=fleet-; ccp_is_canary fleet-small fleet-project-4"; [ "$RC" = 1 ] && ok || bad "P4 prefix fleet-: fleet-small matched fleet-project-4"
# ccp_target_version: the canary box gets the canary version, every other box the pin.
on; ccpf_set "$H/f" claude_cli.canary_box box-small; ccpf_set "$H/f" claude_cli.canary_version 2.1.331
lib "ccp_target_version small; ccp_target_version project-4; ccp_target_version hub"
[ "$OUT" = "$(printf '2.1.331\n2.1.330\n2.1.330')" ] && ok || bad "P4 targets small/project-4/hub: $(tr '\n' ' ' <<<"$OUT")"

new_case p5
chk_canary hub hub 1
chk_canary box-hub box-hub 1
chk_canary hub box-hub 1
ccpf_set "$H/f" claude_cli.canary_box hub
lib "ccp_is_canary hub"; [ "$RC" = 1 ] && ok || bad "P5 row 'hub' made the hub the canary"

new_case p6
lib ccp_enabled; [ "$RC" = 1 ] && ok || bad "P6 no row: want rc 1 (off), got $RC"
ccpf_set "$H/f" claude_cli.pin.enabled 1
lib ccp_enabled; [ "$RC" = 0 ] && ok || bad "P6 row 1: want rc 0, got $RC"
[ "$(cat "$H/state/claude-cli-pin/pin-enabled" 2>/dev/null)" = 1 ] && ok || bad "P6 the on state was not cached"
: > "$H/f/w/down"
lib ccp_enabled; [ "$RC" = 2 ] && ok || bad "P6 outage after an on read: want rc 2 (unknown), got $RC"
rm -f "$H/f/w/down"; ccpf_set "$H/f" claude_cli.pin.enabled 0
lib ccp_enabled; [ "$RC" = 1 ] && ok || bad "P6 row 0: want rc 1, got $RC"
: > "$H/f/w/down"
lib ccp_enabled; [ "$RC" = 1 ] && ok || bad "P6 outage after an off read: want rc 1 (today's behaviour), got $RC"
new_case p6b; : > "$H/f/w/down"
lib ccp_enabled; [ "$RC" = 1 ] && ok || bad "P6b outage with no cache: want rc 1, got $RC"
echo "P done"

# ===========================================================================
# M — promote
# ===========================================================================
m_case() { new_case "$1"; on; ccpf_set "$H/f" claude_cli.canary_version 2.1.331; }

m_case m1
run_rows r1 30 1 1 1 1 1 1; run_rows r2 2 1 1 1 1 1 1
run_pin promote
[ "$RC" = 0 ] && [ "$(pinned)" = 2.1.331 ] && ok || bad "M1 soak green: pinned is '$(pinned)' rc $RC: $OUT"
grep -q 'PROMOTED 2.1.330 -> 2.1.331' <<<"$OUT" && ok || bad "M1 no PROMOTED line: $OUT"
grep -q 'GET /api/claude-cli/smoke?box=small&version=2.1.331' "$H/f/w/req.log" && ok || bad "M1 rows not read by canary box id: $(cat "$H/f/w/req.log")"

m_case m2
run_rows r1 30 1 1 1 1 1 1; run_rows r2 2 1 0 1 1 1 1
run_pin promote
[ "$(pinned)" = 2.1.330 ] && [ -z "$(puts)" ] && ok || bad "M2 red late_stdin promoted: $(puts)"
grep -q 'red smoke step (late_stdin' <<<"$OUT" && ok || bad "M2 reason not named: $OUT"

m_case m3
run_rows r1 10 1 1 1 1 1 1
run_pin promote
[ -z "$(puts)" ] && grep -q 'no complete green run older than 24h' <<<"$OUT" && ok || bad "M3 a run younger than the soak promoted: $OUT"
# An incomplete old run (lane_tick missing) is not a green run either.
m_case m3b
run_rows r1 30 1 1 1 1 - 1; run_rows r2 2 1 1 1 1 1 1
run_pin promote
[ -z "$(puts)" ] && ok || bad "M3b an incomplete old run counted as green: $OUT"

m_case m4
run_rows r1 30 1 1 1 1 1 1; run_rows r2 2 1 1 1 1 1 0
run_pin promote
[ -z "$(puts)" ] && grep -q 'new agent-call failure class' <<<"$OUT" && ok || bad "M4 a new failure class promoted: $OUT"
m_case m4b
run_rows r1 30 1 1 1 1 1 -
run_pin promote
[ -z "$(puts)" ] && grep -q 'no fail_classes check' <<<"$OUT" && ok || bad "M4b no fail_classes row promoted: $OUT"

m_case m5; ccpf_set "$H/f" claude_cli.canary_version 2.1.330
run_rows r1 30 1 1 1 1 1 1 small 2.1.330
run_pin promote
[ -z "$(puts)" ] && grep -q 'not newer than the pin' <<<"$OUT" && ok || bad "M5 canary == pin promoted: $OUT"
ccpf_set "$H/f" claude_cli.canary_version 2.1.329
run_pin promote
[ -z "$(puts)" ] && ok || bad "M5 an older canary promoted: $OUT"

m_case m6
run_rows r1 30 1 1 1 1 1 1; : > "$H/f/w/fail-smoke-get"
run_pin promote
[ -z "$(puts)" ] && grep -q 'not readable' <<<"$OUT" && ok || bad "M6 a failed read promoted: $OUT"

m_case m7; ccpf_set "$H/f" claude_cli.pin.enabled 0
run_rows r1 30 1 1 1 1 1 1
run_pin promote
[ -z "$(puts)" ] && ! grep -q 'claude-cli/smoke' "$H/f/w/req.log" && grep -q 'pin off' <<<"$OUT" && ok \
  || bad "M7 pin off still read or wrote: $(cat "$H/f/w/req.log")"

# M8 adversarial: green rows only from another box; an ok stored as "1 ".
m_case m8
run_rows r1 30 1 1 1 1 1 1 project-4; run_rows r2 2 1 1 1 1 1 1 project-4
run_pin promote
[ -z "$(puts)" ] && ok || bad "M8 another box's rows promoted: $OUT"
m_case m8b
run_rows r1 30 1 1 1 1 1 1
jq -nc --arg at "$(isoh 2)" '{box:"small",version:"2.1.331",run_id:"r2",step:"stdin",ok:"1 ",rc:0,ms:1,detail:"",at:$at,_k:"x"}' >> "$H/f/w/smoke.jsonl"
run_pin promote
[ -z "$(puts)" ] && ok || bad "M8b an ok of \"1 \" counted as green: $OUT"
echo "M done"

# ===========================================================================
# W — watch
# ===========================================================================
w_case() { new_case "$1"; on; }
w_case w1
run_pin watch CCP_NPM_VIEW=2.1.331
[ "$(ccpf_get "$H/f" claude_cli.canary_version)" = 2.1.331 ] && grep -q 'NEW CANARY 2.1.331' <<<"$OUT" && ok \
  || bad "W1 newer release not set as canary: $OUT"
[ "$(pinned)" = 2.1.330 ] && ok || bad "W5 watch moved the pin to $(pinned)"
# The production path: npm view through PATH (the fake npm).
w_case w1b; echo 2.1.332 > "$H/f/w/npm-view"
run_pin watch
[ "$(ccpf_get "$H/f" claude_cli.canary_version)" = 2.1.332 ] && grep -q 'view @anthropic-ai/claude-code version' "$H/f/w/npm.log" && ok \
  || bad "W1b npm view path: canary '$(ccpf_get "$H/f" claude_cli.canary_version)': $OUT"
w_case w2
run_pin watch CCP_NPM_VIEW=2.1.330
[ -z "$(puts)" ] && ok || bad "W2 a release equal to the pin was written: $(puts)"
w_case w3; ccpf_set "$H/f" claude_cli.canary_version 2.1.332
run_pin watch CCP_NPM_VIEW=2.1.331
[ -z "$(puts)" ] && ok || bad "W3 an older release replaced the canary: $(puts)"
run_pin watch CCP_NPM_VIEW=2.1.332
[ -z "$(puts)" ] && ok || bad "W3 the same release was written again: $(puts)"
w_case w4
for bad_view in "npm error code E404" "latest" "" "2.1" "2.1.329"; do
  run_pin watch CCP_NPM_VIEW="$bad_view"
  [ -z "$(puts)" ] && ok || bad "W4 '$bad_view' was written: $(puts)"
done
w_case w6; ccpf_set "$H/f" claude_cli.pin.enabled 0
run_pin watch CCP_NPM_VIEW=2.1.331
[ -z "$(puts)" ] && ok || bad "W6 pin off still set a canary"
# W7: the npm view kill timeout is the row claude_cli.watch_kill_after_s
# (fallback 10), not a literal (lead review of cc25d98bdfc2). A `timeout` first
# on PATH records its argv and runs the real one.
w_to_stub() { mkdir -p "$H/tbin"; printf '#!/bin/bash\necho "$*" >> "$HARNESS/to.calls"\nexec /usr/bin/timeout "$@"\n' > "$H/tbin/timeout"; chmod +x "$H/tbin/timeout"; }
w_case w7; w_to_stub; echo 2.1.332 > "$H/f/w/npm-view"
run_pin watch PATH="$H/tbin:$H/f/fakebin:/usr/bin:/bin"
grep -q -- '^--kill-after=10 60 npm view' "$H/to.calls" 2>/dev/null && ok || bad "W7 no row: want '--kill-after=10 60 npm view': $(cat "$H/to.calls" 2>/dev/null)"
w_case w7b; w_to_stub; echo 2.1.332 > "$H/f/w/npm-view"; ccpf_set "$H/f" claude_cli.watch_kill_after_s 7
run_pin watch PATH="$H/tbin:$H/f/fakebin:/usr/bin:/bin"
grep -q -- '^--kill-after=7 60 npm view' "$H/to.calls" 2>/dev/null && ok || bad "W7b row 7: want '--kill-after=7 60 npm view': $(cat "$H/to.calls" 2>/dev/null)"
echo "W done"

# ===========================================================================
# D — drift
# ===========================================================================
d_case() {
  new_case "$1"; on; ccpf_set "$H/f" claude_cli.canary_version 2.1.331
  jq -n --arg f "$(isoh 3)" --arg s "$(isoh 72)" '{boxes: [
    {box:"hub",   cli_version:"2.1.330", cli_checked_at:$f},
    {box:"small", cli_version:"2.1.331", cli_checked_at:$f},
    {box:"project-4",  cli_version:"2.1.317", cli_checked_at:$f},
    {box:"project-3",  cli_version:"2.1.300", cli_checked_at:$s}]}' > "$H/f/w/boxes.json"
}
beats() { cat "$H/beats.log" 2>/dev/null | grep -c "claude-cli-drift" || true; }
d_case d1
run_pin drift
[ "$(beats)" = 1 ] && ok || bad "D1 want one warn, got $(beats): $(cat "$H/beats.log" 2>/dev/null)"
line=$(grep 'claude-cli-drift' "$H/beats.log" 2>/dev/null | head -1)
jq -e '.akey == "claude-cli-drift:project-4:2.1.317:2.1.330" and .severity == "warn" and (.line | test("project-4") and test("2.1.317") and test("2.1.330"))' <<<"$line" >/dev/null 2>&1 \
  && ok || bad "D1 warn fields: $line"
# D3: the canary on its version is not drift; D5: the 72h-old project-3 row is skipped.
grep -q '"small' <<<"$(cat "$H/beats.log" 2>/dev/null)" && bad "D3 the canary on 2.1.331 warned" || ok
grep -q 'project-3' "$H/beats.log" 2>/dev/null && bad "D5 a stale row warned" || ok
grep -q 'drift: 1 of 3 boxes and 0 of 0 images off the pin' <<<"$OUT" && ok || bad "D1/D5 summary: $OUT"
# D4: the same state again -> no new warn.
run_pin drift
[ "$(beats)" = 1 ] && grep -q '(0 new warn' <<<"$OUT" && ok || bad "D4 repeat run warned again ($(beats)): $OUT"
# project-4 back on the pin -> its key is dropped, so a later drift warns again.
jq '(.boxes[] | select(.box=="project-4") | .cli_version) = "2.1.330"' "$H/f/w/boxes.json" > "$H/b.tmp" && mv "$H/b.tmp" "$H/f/w/boxes.json"
run_pin drift
grep -q 'project-4' "$H/state/claude-cli-pin/drift-sent.tsv" && bad "D4 a box back on the pin kept its sent key" || ok
grep -q 'drift: 0 of 3 boxes' <<<"$OUT" && ok || bad "D2 summary after the fix: $OUT"

d_case d2
jq '(.boxes[] | select(.box=="project-4") | .cli_version) = "2.1.330"' "$H/f/w/boxes.json" > "$H/b.tmp" && mv "$H/b.tmp" "$H/f/w/boxes.json"
run_pin drift
[ "$(beats)" = 0 ] && grep -q 'drift: 0 of 3 boxes and 0 of 0 images off the pin' <<<"$OUT" && ok || bad "D2 all on the pin: $(beats) warn(s): $OUT"

d_case d6
jq '(.boxes[] | select(.box=="project-4") | .cli_version) = "2.1.330"' "$H/f/w/boxes.json" > "$H/b.tmp" && mv "$H/b.tmp" "$H/f/w/boxes.json"
printf 'claude=2.1.300\ncodex=0.153.4\n' > "$H/state/fly/project-3.cli"
printf 'claude=2.1.330\ncodex=0.153.4\n' > "$H/state/fly/project-4.cli"
run_pin drift
[ "$(beats)" = 1 ] && grep -q 'claude-cli-drift:image:project-3:2.1.300:2.1.330' "$H/beats.log" && ok || bad "D6 image warn: $(cat "$H/beats.log" 2>/dev/null)"
grep -q 'and 1 of 2 images off the pin' <<<"$OUT" && ok || bad "D6 summary: $OUT"

d_case d7; ccpf_set "$H/f" claude_cli.pin.enabled 0
run_pin drift
! grep -q 'GET /api/boxes' "$H/f/w/req.log" && [ "$(beats)" = 0 ] && ok || bad "D7 pin off read the boxes"

d_case d8; : > "$H/f/w/fail-boxes"
run_pin drift
grep -q 'drift: not measured' <<<"$OUT" && [ "$(beats)" = 0 ] && ok || bad "D8 failed read: $OUT"
grep -q 'drift: 0 of' <<<"$OUT" && bad "D8 a failed read printed a count" || ok
# D10: an answer with no boxes array is not "0 boxes off the pin" (lead review
# of cc25d98bdfc2): it is not measured, and no count is printed.
d_case d10; echo '{"error":"shape"}' > "$H/f/w/boxes.json"
run_pin drift
grep -q 'drift: not measured' <<<"$OUT" && ok || bad "D10 no boxes array: want 'not measured': $OUT"
grep -q 'drift: 0 of' <<<"$OUT" && bad "D10 no boxes array printed a 0 count: $OUT" || ok

# D9: no console (beat rc 2) -> the warn goes to ALERTS and is recorded; a
# beat the console refused (rc 1) is not recorded, so the next run retries it.
d_case d9; echo 2 > "$H/beat-rc"
run_pin drift
grep -q 'CLAUDE CLI DRIFT: box project-4 runs claude 2.1.317' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "D9 rc 2 gave no ALERTS line"
d_case d9b; echo 1 > "$H/beat-rc"
run_pin drift
[ -s "$H/state/claude-cli-pin/drift-sent.tsv" ] && bad "D9b a refused beat was recorded as sent" || ok
echo 0 > "$H/beat-rc"; run_pin drift
[ "$(beats)" = 2 ] && ok || bad "D9b the refused warn was not retried ($(beats))"
echo "D done"

echo "claude-cli-pin.bh-9911-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
