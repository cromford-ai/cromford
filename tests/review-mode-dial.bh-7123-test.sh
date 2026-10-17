#!/bin/bash
# tests/review-mode-dial.bh-7123-test.sh — BH-7123 wave B: the review-mode
# dial, its expiry lane, the judged-mode reader and the false-BLOCK counter.
#
#   D1-D8  bin/review-mode.sh writes review.mode[.<p>] + review.mode_until[.<p>]
#          through setting_set, defaults --for 6h for cowboy/off and no expiry
#          for levels/strict/shadow, prints what it wrote, posts ONE operator
#          line, refuses an unknown mode/project/--for, and `show` lists rows.
#   E1-E6  bin/review-mode-expire.sh flips a past non-levels row to levels and
#          clears its until row, leaves a future one alone, is idempotent,
#          does nothing when the settings read fails, skips junk.
#   R1-R2  the lane is registered (catalog/lanes.d + cron/lanes fragment).
#   J1-J3  rl_judged_mode reads the mode from a report's marker; strict without.
#   F1-F3  rfb_count: demoted / (demoted + standing) over the lead reports.
#
# Everything is driven through the SHIPPED scripts against a scratch harness
# whose bin/jobs-client.sh is a fake (setting_set / setting_get / _jobs_req
# over a JSON map in $T) and whose bin/alert-line.sh records its argv.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/review-mode-dial.bh-7123-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has()   { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must NOT contain [$3]" ;; *) ok ;; esac; }
command -v jq >/dev/null || { echo "review-mode-dial: jq is required"; exit 1; }

H="$T/h"; mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$T/fakebin" "$T/tmp"
: > "$H/env/global.env"
cp "$DIR/fleet.conf" "$H/fleet.conf"
for s in bin/review-mode.sh bin/review-mode-expire.sh bin/fleet-conf.sh; do
  [ -f "$DIR/$s" ] || { bad "missing $s"; continue; }
  ( cd "$DIR" && scratch_install_closure "$s" "$H" ) >/dev/null || bad "scratch_install_closure $s"
done
# The fake jobs client: a JSON map at $T/settings.json; every write is one
# TSV line in $T/settings.log. FAKE_SETTINGS_DOWN=1 makes every call fail.
cat > "$H/bin/jobs-client.sh" <<'SH'
JOBS_BOX=test-box
_fk_map() { [ -s "$FAKE_SETTINGS" ] || echo '{}' > "$FAKE_SETTINGS"; }
setting_get() {
  [ "${FAKE_SETTINGS_DOWN:-0}" = 1 ] && return 1
  _fk_map; local v; v=$(jq -r --arg k "$1" '.[$k] // empty' "$FAKE_SETTINGS")
  [ -n "$v" ] || return 2
  printf '%s' "$v"
}
setting_set() {
  [ "${FAKE_SETTINGS_DOWN:-0}" = 1 ] && return 1
  [ -n "${2:-}" ] || return 1
  _fk_map; jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}' "$FAKE_SETTINGS" > "$FAKE_SETTINGS.t" && mv "$FAKE_SETTINGS.t" "$FAKE_SETTINGS"
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$FAKE_SETTINGS_LOG"
}
_jobs_req() {
  [ "${FAKE_SETTINGS_DOWN:-0}" = 1 ] && return 1
  printf '%s %s\n' "$1" "$2" >> "$FAKE_SETTINGS_LOG.req"
  case "$1 $2" in
    "GET /api/settings") _fk_map; jq -c '{settings: [to_entries[] | {key: .key, value: .value, note: "n", actor: "a", updated_at: "2026-10-16T00:00:00Z"}]}' "$FAKE_SETTINGS" ;;
    *) return 2 ;;
  esac
}
SH
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/alerts.log" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/alert-line.sh"
# BSD boxes have no flock; the lane's `flock -n 9 || exit 0` must not skip the tick.
command -v flock >/dev/null 2>&1 || { printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

export HARNESS="$H" PATH="$T/fakebin:$PATH" TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 USER=tester
export FAKE_SETTINGS="$T/settings.json" FAKE_SETTINGS_LOG="$T/settings.log"
unset FAKE_SETTINGS_DOWN REVIEW_LEVEL_MODE JOBS_URL HARNESS_SECRET

NOW=$(date -u +%s)
epoch_of() { # epoch_of <iso>
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
reset() { rm -f "$T/settings.json" "$T/settings.log" "$T/settings.log.req" "$T/alerts.log" "$H/logs"/*.log; echo '{}' > "$T/settings.json"; }
run() { ( cd "$T" && bash "$H/bin/review-mode.sh" "$@" ) > "$T/out" 2> "$T/err"; RC=$?; OUT=$(cat "$T/out"); ERR=$(cat "$T/err"); }
wrote() { awk -F'\t' -v k="$1" '$1 == k {print $2}' "$T/settings.log" 2>/dev/null | tail -1; }
nwrites() { if [ -f "$T/settings.log" ]; then wc -l < "$T/settings.log" | tr -d ' '; else echo 0; fi; }
nalerts() { [ -f "$T/alerts.log" ] && wc -l < "$T/alerts.log" | tr -d ' ' || echo 0; }
within() { # within <iso> <expected-epoch> <slack-s>
  local e; e=$(epoch_of "$1") || return 1
  [ $(( e > $2 ? e - $2 : $2 - e )) -le "$3" ]
}

# ── D1: a project cowboy, default --for 6h, one alert, printed ───────────────
reset; run project-6-os cowboy --why "sprint on the dashboards"
[ "$RC" = 0 ] && ok || bad "D1 rc=$RC: $ERR"
[ "$(wrote review.mode.project-6-os)" = cowboy ] && ok || bad "D1 review.mode.project-6-os not written cowboy: $(cat "$T/settings.log" 2>/dev/null)"
U=$(wrote review.mode_until.project-6-os)
within "$U" $((NOW + 6 * 3600)) 180 && ok || bad "D1 until must be now+6h, got '$U'"
has "D1 prints the mode row" "$OUT" "review.mode.project-6-os"
has "D1 prints cowboy" "$OUT" "cowboy"
has "D1 prints the until" "$OUT" "$U"
[ "$(nalerts)" = 1 ] && ok || bad "D1 want one operator line, got $(nalerts)"
has "D1 alert names the project" "$(cat "$T/alerts.log")" "project-6-os"
has "D1 alert names the mode" "$(cat "$T/alerts.log")" "cowboy"
has "D1 alert carries the why" "$(cat "$T/alerts.log")" "sprint on the dashboards"
has "D1 note carries the why" "$(awk -F'\t' '$1=="review.mode.project-6-os"{print $3}' "$T/settings.log")" "sprint on the dashboards"

# ── D2: fleet off --for 2d ────────────────────────────────────────────────────
reset; run fleet off --for 2d
[ "$RC" = 0 ] && ok || bad "D2 rc=$RC: $ERR"
[ "$(wrote review.mode)" = off ] && ok || bad "D2 fleet row review.mode not off"
within "$(wrote review.mode_until)" $((NOW + 48 * 3600)) 180 && ok || bad "D2 until must be now+2d, got '$(wrote review.mode_until)'"
[ "$(nwrites)" = 2 ] && ok || bad "D2 exactly two rows written, got $(nwrites)"

# ── D3: levels has no expiry; strict --for forever neither; --for 90m works ──
reset; run project-5 levels
[ "$RC" = 0 ] && ok || bad "D3 rc=$RC: $ERR"
[ "$(wrote review.mode.project-5)" = levels ] && ok || bad "D3 mode not levels"
[ "$(wrote review.mode_until.project-5)" = never ] && ok || bad "D3 levels must clear the until row (never), got '$(wrote review.mode_until.project-5)'"
has "D3 prints no expiry" "$OUT" "no expiry"
run project-6-os strict --for forever
[ "$RC" = 0 ] && [ "$(wrote review.mode_until.project-6-os)" = never ] && ok || bad "D3 strict --for forever: rc=$RC until='$(wrote review.mode_until.project-6-os)'"
run project-6-os shadow --for 90m
[ "$RC" = 0 ] && within "$(wrote review.mode_until.project-6-os)" $((NOW + 90 * 60)) 180 && ok || bad "D3 --for 90m: rc=$RC until='$(wrote review.mode_until.project-6-os)'"

# ── D4: refusals write nothing and alert nothing ─────────────────────────────
reset
run project-6-os yolo;        [ "$RC" = 2 ] && [ "$(nwrites)" = 0 ] && ok || bad "D4 unknown mode: rc=$RC writes=$(nwrites)"
has "D4 unknown mode says so" "$ERR" "yolo"
run not-a-project cowboy;     [ "$RC" = 2 ] && [ "$(nwrites)" = 0 ] && ok || bad "D4 unknown project: rc=$RC writes=$(nwrites)"
has "D4 unknown project names it" "$ERR" "not-a-project"
run project-6-os cowboy --for 6x; [ "$RC" = 2 ] && [ "$(nwrites)" = 0 ] && ok || bad "D4 bad --for: rc=$RC writes=$(nwrites)"
run project-6-os;             [ "$RC" = 2 ] && ok || bad "D4 missing mode: rc=$RC"
run;                          [ "$RC" = 2 ] && ok || bad "D4 no args: rc=$RC"
has "D4 usage names the verbs" "$ERR" "show"
[ "$(nalerts)" = 0 ] && ok || bad "D4 a refusal must not alert"

# ── D5: a failed write is rc 1 and no alert ──────────────────────────────────
reset; FAKE_SETTINGS_DOWN=1 run project-6-os cowboy
[ "$RC" = 1 ] && ok || bad "D5 write failure must be rc 1, got $RC"
[ "$(nalerts)" = 0 ] && ok || bad "D5 a failed write must not announce"
has "D5 says what failed" "$ERR" "review.mode.project-6-os"

# ── D6: show ─────────────────────────────────────────────────────────────────
reset
run project-6-os cowboy; run project-5 levels; run fleet shadow --for 1d
run show
[ "$RC" = 0 ] && ok || bad "D6 show rc=$RC: $ERR"
has "D6 show lists the project row" "$OUT" "review.mode.project-6-os"
has "D6 show lists the fleet row" "$OUT" "review.mode"
has "D6 show pairs the expiry" "$OUT" "$(wrote review.mode_until.project-6-os)"
has "D6 show shows levels" "$OUT" "levels"
run show project-6-os
has "D6 show <p> keeps that project" "$OUT" "project-6-os"
hasnt "D6 show <p> drops the others" "$OUT" "project-5"
FAKE_SETTINGS_DOWN=1 run show
[ "$RC" = 1 ] && ok || bad "D6 show with settings down must be rc 1, got $RC"
# D6b (BH-7123 follow-up): a review.* row the capture does not list, and the
# wave B row review.golive_gates_merge, both render; the fallback used to run
# with `.` bound to the key string and die with `Cannot index string with "key"`
# the first time `show` met the real snapshot on the hub.
reset; jq -nc '{"review.mode": "levels", "review.golive_gates_merge": "0", "review.x_unknown": "1"}' > "$T/settings.json"
run show
[ "$RC" = 0 ] && ok || bad "D6b show rc=$RC with an unlisted review.* row: $ERR"
has "D6b show lists the go-live row" "$OUT" "review.golive_gates_merge"
has "D6b show lists the unlisted row" "$OUT" "review.x_unknown"
case "$ERR" in *jq*) bad "D6b jq complained: $ERR" ;; *) ok ;; esac

# ── E1: expiry flips past rows, leaves the future one, announces each ────────
PAST=$(iso_at $((NOW - 600))); FUTURE=$(iso_at $((NOW + 7200)))
reset
jq -nc --arg p "$PAST" --arg f "$FUTURE" '{
  "review.mode.project-6-os": "cowboy", "review.mode_until.project-6-os": $p,
  "review.mode.project-5": "off",       "review.mode_until.project-5": $f,
  "review.mode": "cowboy",              "review.mode_until": $p,
  "review.mode.project-3": "strict",      "review.mode_until.project-3": "never",
  "review.perf_block_ms": "300"}' > "$T/settings.json"
( cd "$T" && bash "$H/bin/review-mode-expire.sh" ) > "$T/eout" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "E1 rc=$RC: $(cat "$T/eout")"
[ "$(wrote review.mode.project-6-os)" = levels ] && ok || bad "E1 project-6-os must flip to levels: $(cat "$T/settings.log" 2>/dev/null)"
[ "$(wrote review.mode_until.project-6-os)" = never ] && ok || bad "E1 project-6-os until must be cleared"
[ "$(wrote review.mode)" = levels ] && ok || bad "E1 the fleet row must flip to levels"
[ "$(wrote review.mode_until)" = never ] && ok || bad "E1 the fleet until must be cleared"
[ -z "$(wrote review.mode.project-5)" ] && [ -z "$(wrote review.mode_until.project-5)" ] && ok || bad "E1 the future row must be left alone"
[ -z "$(wrote review.mode.project-3)" ] && ok || bad "E1 a never row must be left alone"
[ "$(nwrites)" = 4 ] && ok || bad "E1 exactly four writes, got $(nwrites): $(cat "$T/settings.log")"
[ "$(nalerts)" = 2 ] && ok || bad "E1 one operator line per flip, got $(nalerts): $(cat "$T/alerts.log" 2>/dev/null)"
has "E1 alert text (project)" "$(cat "$T/alerts.log")" "review.mode.project-6-os expired: cowboy -> levels"
has "E1 alert text (fleet)" "$(cat "$T/alerts.log")" "review.mode expired: cowboy -> levels"
has "E1 log line" "$(cat "$H/logs/review-mode-expire.log")" "project-6-os"

# ── E2: idempotent — the second tick writes nothing ─────────────────────────
: > "$T/settings.log"; rm -f "$T/alerts.log"
( cd "$T" && bash "$H/bin/review-mode-expire.sh" ) >/dev/null 2>&1
[ "$(nwrites)" = 0 ] && [ "$(nalerts)" = 0 ] && ok || bad "E2 second tick: writes=$(nwrites) alerts=$(nalerts)"

# ── E3: an unreadable settings read changes nothing ──────────────────────────
reset; jq -nc --arg p "$PAST" '{"review.mode.project-6-os": "cowboy", "review.mode_until.project-6-os": $p}' > "$T/settings.json"
( cd "$T" && FAKE_SETTINGS_DOWN=1 bash "$H/bin/review-mode-expire.sh" ) >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && [ "$(nwrites)" = 0 ] && [ "$(nalerts)" = 0 ] && ok || bad "E3 fail-open: rc=$RC writes=$(nwrites) alerts=$(nalerts)"
has "E3 log says unreadable" "$(cat "$H/logs/review-mode-expire.log" 2>/dev/null)" "unreadable"

# ── E4: a past until whose mode is already levels: clear it, no alert ────────
reset; jq -nc --arg p "$PAST" '{"review.mode.project-6-os": "levels", "review.mode_until.project-6-os": $p}' > "$T/settings.json"
( cd "$T" && bash "$H/bin/review-mode-expire.sh" ) >/dev/null 2>&1
[ "$(wrote review.mode_until.project-6-os)" = never ] && ok || bad "E4 the stale until must be cleared"
[ -z "$(wrote review.mode.project-6-os)" ] && ok || bad "E4 a levels row is not rewritten"
[ "$(nalerts)" = 0 ] && ok || bad "E4 nothing expired, nothing announced"

# ── E5: junk until is skipped and logged; a past until with no mode row only clears ──
reset; jq -nc --arg p "$PAST" '{"review.mode.project-6-os": "cowboy", "review.mode_until.project-6-os": "garbage", "review.mode_until.project-4": $p}' > "$T/settings.json"
( cd "$T" && bash "$H/bin/review-mode-expire.sh" ) >/dev/null 2>&1
[ -z "$(wrote review.mode.project-6-os)" ] && ok || bad "E5 junk until must not flip the mode"
has "E5 junk is logged" "$(cat "$H/logs/review-mode-expire.log" 2>/dev/null)" "garbage"
[ "$(wrote review.mode_until.project-4)" = never ] && ok || bad "E5 an orphan until is cleared"
[ "$(nalerts)" = 0 ] && ok || bad "E5 no alert for junk or an orphan"

# ── E6: --dry-run writes nothing, says what it would do ──────────────────────
reset; jq -nc --arg p "$PAST" '{"review.mode.project-6-os": "cowboy", "review.mode_until.project-6-os": $p}' > "$T/settings.json"
( cd "$T" && bash "$H/bin/review-mode-expire.sh" --dry-run ) > "$T/eout" 2>&1
[ "$(nwrites)" = 0 ] && [ "$(nalerts)" = 0 ] && ok || bad "E6 dry run wrote or alerted"
has "E6 dry run names the flip" "$(cat "$T/eout" "$H/logs/review-mode-expire.log" 2>/dev/null)" "project-6-os"

# ── R1-R2: the lane is registered ────────────────────────────────────────────
J="$DIR/catalog/lanes.d/review-mode-expire.json"
[ -f "$J" ] && [ "$(jq -r .id "$J" 2>/dev/null)" = review-mode-expire ] && [ "$(jq -r .script "$J" 2>/dev/null)" = bin/review-mode-expire.sh ] \
  && [ "$(jq -r .scope "$J" 2>/dev/null)" = hub ] && ok || bad "R1 catalog/lanes.d/review-mode-expire.json missing or wrong"
FRAG=$(ls "$DIR"/cron/lanes/*-review-mode-expire.cron 2>/dev/null | head -1)
[ -n "$FRAG" ] && grep -q '^# @hub-lanes' "$FRAG" && grep -qE '^[0-9*/,]+ [0-9*/,]+ \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/review-mode-expire.sh' "$FRAG" \
  && ok || bad "R2 cron/lanes fragment missing or not a gated hub line"
grep -q 'lane_gate_or_exit review-mode-expire' "$DIR/bin/review-mode-expire.sh" 2>/dev/null && ok || bad "R2 the lane does not gate"

# ── J1-J3: rl_judged_mode ────────────────────────────────────────────────────
if . "$DIR/bin/lib/review-level.sh" 2>/dev/null && command -v rl_judged_mode >/dev/null 2>&1; then
  printf '# Lead review x\n\n- verdict: MERGE-WITH-NOTES\n- review level (BH-7123): mode=cowboy demoted=3 standing=0 verdict=MERGE-WITH-NOTES\n\nbody\nReview level (BH-7123): mode cowboy, 3 finding(s) demoted to NOTE, 0 BLOCK stands; verdict MERGE-WITH-NOTES.\nVERDICT: MERGE-WITH-NOTES\n' > "$T/r1.md"
  [ "$(rl_judged_mode "$T/r1.md")" = cowboy ] && ok || bad "J1 marker mode: $(rl_judged_mode "$T/r1.md")"
  printf 'Findings\n- [BLOCK tenant-leak] x\nReview level (BH-7123): mode levels, 0 finding(s) demoted to NOTE, 1 BLOCK stands; verdict BLOCK.\nVERDICT: BLOCK\n' > "$T/r2.md"
  [ "$(rl_judged_mode "$T/r2.md")" = levels ] && ok || bad "J1 marker-only mode: $(rl_judged_mode "$T/r2.md")"
  printf 'Findings\n- [BLOCK] x\nVERDICT: BLOCK\n' > "$T/r3.md"
  [ "$(rl_judged_mode "$T/r3.md")" = strict ] && ok || bad "J2 no marker must read strict: $(rl_judged_mode "$T/r3.md")"
  out=$(rl_judged_mode "$T/does-not-exist.md"); rc=$?
  [ "$out" = strict ] && [ "$rc" != 0 ] && ok || bad "J3 unreadable: out='$out' rc=$rc"
else
  bad "J rl_judged_mode is not defined in bin/lib/review-level.sh"
fi

# ── F1-F3: the false-BLOCK counter ───────────────────────────────────────────
if [ -f "$DIR/bin/lib/review-false-block.sh" ] && . "$DIR/bin/lib/review-false-block.sh" 2>/dev/null && command -v rfb_count >/dev/null 2>&1; then
  R="$T/reports"; mkdir -p "$R"
  printf '# Lead review a (o/r#1 at x)\n\n- verdict: MERGE-WITH-NOTES\n- review level (BH-7123): mode=levels demoted=3 standing=0 verdict=MERGE-WITH-NOTES\n\nbody\n' > "$R/lr-1-aaaaaaaaaaaa.md"
  printf 'Findings\nReview level (BH-7123): mode levels, 1 finding(s) demoted to NOTE, 2 BLOCK stands; verdict BLOCK.\nVERDICT: BLOCK\n' > "$R/lr-2-bbbbbbbbbbbb.md"
  printf '# Lead review c\n\n- verdict: MERGE\n\nno marker here\n' > "$R/lr-3-cccccccccccc.md"
  out=$(rfb_count "$R" 30)
  [ "$(jq -r .reports <<<"$out")" = 2 ] && ok || bad "F1 reports: $out"
  [ "$(jq -r .demoted <<<"$out")" = 4 ] && [ "$(jq -r .standing <<<"$out")" = 2 ] && ok || bad "F1 sums: $out"
  [ "$(jq -r .rate <<<"$out")" = 0.667 ] && ok || bad "F1 rate 4/6: $out"
  out=$(rfb_count "$T/no-such-dir" 30)
  [ "$(jq -r .reports <<<"$out")" = 0 ] && [ "$(jq -r .rate <<<"$out")" = null ] && ok || bad "F2 empty dir: $out"
  touch -t 202001010000 "$R/lr-1-aaaaaaaaaaaa.md"
  out=$(rfb_count "$R" 30)
  [ "$(jq -r .reports <<<"$out")" = 1 ] && [ "$(jq -r .demoted <<<"$out")" = 1 ] && ok || bad "F3 the window drops an old report: $out"
  grep -q 'false_block\|rfb_count' "$DIR/bin/lead-review-precision.sh" 2>/dev/null && ok || bad "F3 lead-review-precision.sh does not print the false-BLOCK number"
else
  bad "F bin/lib/review-false-block.sh with rfb_count is missing"
fi

echo "review-mode-dial.bh-7123: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
