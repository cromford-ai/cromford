#!/bin/bash
# tests/daily-digest-read-cap.bh-6727-test.sh — BH-6727: the per-day cap on
# digest READS in bin/daily-digest.sh, driven through the SHIPPED lane.
#
# The defect: the lane capped only failed SENDS (attempts-<D>). A failed read of
# GET /api/metrics/daily-digest (or a failed render, a lost claim) counted
# nothing, so on a bad day the lane read the route on every 15-minute tick from
# the send hour to midnight: 68 ticks, each up to 4 requests with the
# _jobs_req retries. The fix counts each read in state/daily-digest/reads-<D>
# and stops at DAILY_DIGEST_READ_MAX (default 8) with one warn a day.
#
# The scratch harness, the fake curl and the render seam are the same as
# tests/daily-digest.bh-3706-test.sh (read its header for what is stubbed).
# JOBS_RETRIES=0 and JOBS_OVERLOAD_RETRIES=0, so one tick is one route request.
#
# Cases: R1-R9, and the mutation M1 (a sed copy of the lane with the cap check
# removed).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/daily-digest-read-cap.bh-6727-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "daily-digest: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# The product paths this ticket touches (D41).
for f in "$DIR/bin/daily-digest.sh" "$DIR/catalog/lanes.d/daily-digest.json" \
         "$DIR/docs/notes/2026-10-14-BH-6727-digest-read-cap.md"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
[ -f "$DIR/bin/daily-digest.sh" ] || { echo "daily-digest-read-cap: $PASS passed, $FAIL failed"; exit 1; }

H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$DIR/catalog/switches.d" "$H/catalog/"
: > "$H/env/global.env"
rm -f "$H/bin/lane-alert.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh"
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
exit 0
SH
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
printf 'BEAT_STRICT=%s %s\n' "${BEAT_STRICT:-}" "$1" >> "$FXT/beats"
exit "$(cat "$FXT/beat.rc" 2>/dev/null || echo 0)"
SH
# BH-4779: Archie's Telegram transport, captured where the beats were.
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
jq -nc --arg a "$1" --arg l "$2" '{akey: $a, line: $l}' >> "$FXT/beats"
exit "$(cat "$FXT/beat.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$H/bin/lane-alert.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh"
LANE="$H/bin/daily-digest.sh"

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; body=""; prev=""; wfmt=0
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    --data-binary|-d) body="$a" ;;
    -w) wfmt=1 ;;
  esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
url="${!#}"
printf '%s\n' "$url" >> "$FXT/urls"
case "$url" in "$JOBS_URL"*) ;; *) exit 7 ;; esac
path="${url#"$JOBS_URL"}"
case "$path" in
  /api/settings*|/api/flags*|/api/lanes*) printf '%s %s %s\n' "$m" "$path" "$body" >> "$GATELOG" ;;
  *) printf '%s %s %s\n' "$m" "$path" "$body" >> "$REQLOG" ;;
esac
code=200; out='{"ok":true}'
case "$m $path" in
  "GET /api/settings"*)
    out=$(jq -c '{settings: .}' "$FXT/settings.json" 2>/dev/null || echo '{"settings":[]}') ;;
  *" /api/ledger"*)
    if [ -f "$FXT/ledger.code" ]; then code=$(cat "$FXT/ledger.code"); out='{"error":"down"}'
    elif [ "$m" = GET ]; then
      k=$(printf '%s' "$path" | sed -n 's/.*[?&]kind=\([^&]*\).*/\1/p')
      v=$(printf '%s' "$path" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')
      row=$(jq -c --arg i "$k/$v" '.[$i] // empty' "$FXT/ledger.json")
      if [ -n "$row" ]; then out=$(jq -nc --argjson r "$row" '{ledger: $r}'); else code=404; out='{"error":"not found"}'; fi
    else
      jq --argjson b "$body" '.[$b.kind + "/" + $b.key] = {status: $b.status, detail: ($b.detail // "")}' \
        "$FXT/ledger.json" > "$FXT/ledger.tmp" && mv "$FXT/ledger.tmp" "$FXT/ledger.json"
    fi ;;
  "GET /api/metrics/daily-digest"*)
    code=$(cat "$FXT/route.code" 2>/dev/null || echo 200)
    if [ -f "$FXT/route.body" ]; then out=$(cat "$FXT/route.body"); else out=$(cat "$FXT/route.json"); fi ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"
# The render seam: a fixed text built from the json's own .day, and the argv
# dd_render was handed, so D1 can check what the lane passed it.
cat > "$T/fx.sh" <<'SH'
dd_render() {
  printf '%s\n' "$@" > "$FXT/render.args"
  if [ "$6" != - ]; then cat "$6" > "$FXT/render.summary"; fi
  local d; d=$(jq -r .day "$1")
  case "$(cat "$FXT/render.mode" 2>/dev/null)" in
    blank) printf '   \n'; return 0 ;;
    fail) return 3 ;;
    long)
      printf 'Daily digest %s\n' "$d"
      local i; for i in $(seq 1 30); do printf 'item %02d → a line of forty-odd characters\n' "$i"; done
      return 0 ;;
  esac
  printf 'Daily digest %s\nline two → ok\nline three\n' "$d"
}
if [ -f "$FXT/summary.on" ]; then
  dd_summary() { printf 'A quiet day.\n' > "$2"; return 0; }
fi
SH

REQLOG="$T/reqlog"; GATELOG="$T/gatelog"
export HARNESS="$H" FXT="$T" REQLOG GATELOG \
  JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 HARNESS_SECRET=test JOBS_BOX=hub \
  CONSOLE_PAGES_URL=https://console.invalid/ PATH="$T/fakebin:$PATH"
unset DAILY_DIGEST_ENABLED DAILY_DIGEST_SEND_HOUR_UTC DAILY_DIGEST_MAX_ITEMS DAILY_DIGEST_TEXT_MAX_CHARS \
  DAILY_DIGEST_REBUILD_LOOP_MIN DAILY_DIGEST_HUMAN_ACTORS DAILY_DIGEST_LLM_SUMMARY DAILY_DIGEST_LLM_MAX_USD \
  DAILY_DIGEST_NOW DAILY_DIGEST_FIXTURE DAILY_DIGEST_READ_MAX NEEDS_HUMAN_TRIP_COUNT LEAD_REVIEW_SPOTCHECK_PCT \
  LANE_GATE_DISABLE BEAT_STRICT DD_TIMED 2>/dev/null || true

D=2026-09-29
NOW=1790751900          # 2026-09-30T07:05:00Z, so D is 2026-09-29
SD="$H/state/daily-digest"
render_want() { printf 'Daily digest %s\nline two → ok\nline three' "$1"; }

# reset: a fresh world — no ledger rows, no switches, no settings rows, the
# fixture route body for day D, the console taking every beat.
reset() {
  local p
  for p in "$T/beats" "$T/alerts.log" "$T/urls" "$T/ledger.json" "$T/ledger.code" "$T/route.json" \
    "$T/route.body" "$T/route.code" "$T/beat.rc" "$T/settings.json" "$T/render.args" "$T/render.mode" \
    "$T/render.summary" "$T/summary.on" "$H/state" "$H/logs" "$H/locks" "$H/flags"; do
    scratch_rm "$p" || exit 1
  done
  : > "$REQLOG"; : > "$GATELOG"
  echo '{}' > "$T/ledger.json"; echo '[]' > "$T/settings.json"
  jq --arg d "$D" '.day = $d' "$DIR/tests/fixtures/daily-digest/fixture-day.json" > "$T/route.json"
}
# run [VAR=value ...]: one tick of the lane under the sandbox, NOW pinned.
run() {
  env HARNESS_TEST_SANDBOX=1 DAILY_DIGEST_NOW="$NOW" DAILY_DIGEST_FIXTURE="$T/fx.sh" "$@" bash "$LANE" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
n_beat() { local n; n=$(wc -l 2>/dev/null < "$T/beats"); printf '%s' "${n:-0}" | tr -d ' '; }
n_log() { local n; n=$(wc -l 2>/dev/null < "$H/logs/daily-digest.log"); printf '%s' "${n:-0}" | tr -d ' '; }
n_alert() { cnt "$1" "$T/alerts.log"; }
summary() { tail -1 "$H/logs/daily-digest.log" 2>/dev/null; }
payload() { sed -n "${1:-1}p" "$T/beats" | sed 's/^BEAT_STRICT=[^ ]* //'; }
ledger() { jq -r --arg i "daily_digest/$D" '.[$i].status // "none"' "$T/ledger.json"; }
reads() { cat "$SD/reads-$D" 2>/dev/null || echo none; }
n_route() { cnt "GET /api/metrics/daily-digest" "$REQLOG"; }
n_ralert() { cnt "--id daily-digest-reads:" "$T/alerts.log"; }

# ── R1: each failed read counts ──────────────────────────────────────────────
reset; echo 503 > "$T/route.code"
for i in 1 2 3; do
  run
  check "R1 tick $i: reads-$D is $i ($(reads))" '[ "$(reads)" = "$i" ]'
  check "R1 tick $i: $i route request(s) in all ($(n_route))" '[ "$(n_route)" = "$i" ]'
done
run
check "R1 tick 4 reads the counter and writes 4 ($(reads))" '[ "$(reads)" = 4 ] && [ "$(n_route)" = 4 ]'
check "R1 no reads alert under the cap" '[ "$(n_ralert)" = 0 ]'

# ── R2: at the default cap, no request ───────────────────────────────────────
reset; echo 503 > "$T/route.code"; mkdir -p "$SD"; echo 8 > "$SD/reads-$D"
run; L0=$(n_log)
check "R2 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "R2 counter 8, max 8: no route request ($(n_route))" '[ "$(n_route)" = 0 ]'
check "R2 no ledger PUT, no claim" '! grep -qE "^(PUT|POST) /api/ledger" "$REQLOG"'
check "R2 exactly one reads alert ($(cat "$T/alerts.log" 2>/dev/null))" \
  '[ "$(n_alert "--id daily-digest-reads:$D ")" = 1 ] && grep -q "^--severity warn " "$T/alerts.log"'
check "R2 the alert names D and the count" 'grep "daily-digest-reads:$D " "$T/alerts.log" | grep -qF "for $D 8 times"'
check "R2 no summary line" '[ "$L0" = 0 ]'
check "R2 the counter is left at 8 ($(reads))" '[ "$(reads)" = 8 ]'
check "R2 attempts-$D is not written" '[ ! -e "$SD/attempts-$D" ]'

# ── R3: later capped ticks stay quiet ────────────────────────────────────────
run; run
check "R3 two more capped ticks: still one reads alert ($(n_ralert))" '[ "$(n_ralert)" = 1 ]'
check "R3 still no route request, no log line" '[ "$(n_route)" = 0 ] && [ "$(n_log)" = 0 ]'
reset; echo 503 > "$T/route.code"; mkdir -p "$SD"; echo 9 > "$SD/reads-$D"; touch "$SD/alerted-reads-$D"; run
check "R3 counter 9 with the stamp: no request, no second alert" '[ "$(n_route)" = 0 ] && [ "$(n_ralert)" = 0 ]'

# ── R4: the knob ─────────────────────────────────────────────────────────────
for v in 0 97; do
  reset; echo 503 > "$T/route.code"; mkdir -p "$SD"; echo 8 > "$SD/reads-$D"
  run DAILY_DIGEST_READ_MAX=$v
  check "R4 READ_MAX=$v: one warn note naming the knob" \
    '[ "$(cnt "DAILY_DIGEST_READ_MAX=$v" "$H/logs/daily-digest.notes.log")" = 1 ]'
  check "R4 READ_MAX=$v: the default 8 caps (no request)" '[ "$(n_route)" = 0 ] && [ "$(n_ralert)" = 1 ]'
done
reset; echo 503 > "$T/route.code"; mkdir -p "$SD"; echo 7 > "$SD/reads-$D"; run DAILY_DIGEST_READ_MAX=97
check "R4 READ_MAX=97 with counter 7: the default 8 still reads" '[ "$(n_route)" = 1 ] && [ "$(reads)" = 8 ]'
reset; echo 503 > "$T/route.code"; mkdir -p "$SD"; echo 1 > "$SD/reads-$D"; run DAILY_DIGEST_READ_MAX=1
check "R4 READ_MAX=1, counter 1: no request" '[ "$(n_route)" = 0 ] && [ "$(n_ralert)" = 1 ]'
reset; echo 503 > "$T/route.code"; mkdir -p "$SD"; echo 1 > "$SD/reads-$D"
echo '[{"key":"lane.daily-digest.daily_digest_read_max","value":"1","actor":"operator"}]' > "$T/settings.json"; run
check "R4 the settings row READ_MAX=1 caps (DB-driven)" '[ "$(n_route)" = 0 ] && [ "$(n_ralert)" = 1 ]'
reset; echo 503 > "$T/route.code"; mkdir -p "$SD"; echo abc > "$SD/reads-$D"; run
check "R4 counter abc is read as 0 and becomes 1 ($(reads))" '[ "$(reads)" = 1 ] && [ "$(n_route)" = 1 ]'

# ── R5: the last read under the cap sends; the sent day stops before it ──────
reset; mkdir -p "$SD"; echo 7 > "$SD/reads-$D"; run
check "R5 counter 7, route healthy: one send, ledger sent" '[ "$(n_beat)" = 1 ] && [ "$(ledger)" = sent ]'
check "R5 the counter is 8 ($(reads))" '[ "$(reads)" = 8 ]'
: > "$REQLOG"; run
check "R5 next tick exits at the dedupe: counter 8, no alert, no request" \
  '[ "$(reads)" = 8 ] && [ "$(n_ralert)" = 0 ] && [ "$(n_route)" = 0 ] && [ "$(n_beat)" = 1 ]'

# ── R6: a failed render counts too ───────────────────────────────────────────
reset; echo fail > "$T/render.mode"
for i in 1 2 3 4 5 6 7 8 9 10; do run; done
check "R6 render fails: 8 route reads in 10 ticks ($(n_route))" '[ "$(n_route)" = 8 ] && [ "$(reads)" = 8 ]'
check "R6 one render alert and one reads alert" \
  '[ "$(n_alert "--id daily-digest-render:$D ")" = 1 ] && [ "$(n_ralert)" = 1 ]'
check "R6 8 render-failed summary lines, no more" '[ "$(cnt " render-failed$" "$H/logs/daily-digest.log")" = 8 ]'

# ── R7: a sent day never creates the counter ─────────────────────────────────
reset; jq -n --arg i "daily_digest/$D" '{($i): {status: "sent", detail: ""}}' > "$T/ledger.json"; run
check "R7 ledger sent: no reads-$D, no request" '[ ! -e "$SD/reads-$D" ] && [ "$(n_route)" = 0 ]'

# ── R8: the 30-day prune removes old counters ────────────────────────────────
reset; echo 503 > "$T/route.code"; mkdir -p "$SD"; echo 3 > "$SD/reads-2026-08-28"; run
check "R8 reads-2026-08-28 (over 30 days old) is pruned" '[ ! -e "$SD/reads-2026-08-28" ]'
check "R8 reads-$D is kept ($(reads))" '[ "$(reads)" = 1 ]'

# ── R9: a counter that cannot be written is one note, no bash error ─────────
# (lead review NOTE on bin/daily-digest.sh:216: the redirect error went to the
# lane's stderr before the 2>/dev/null applied.) reads-<D> is a directory here.
reset; mkdir -p "$SD/reads-$D"; run
check "R9 rc 0 and the read goes ahead ($(n_route))" '[ "$(cat "$T/rc")" = 0 ] && [ "$(n_route)" = 1 ]'
check "R9 one warn note names the counter file" \
  '[ "$(cnt "could not write state/daily-digest/reads-$D" "$H/logs/daily-digest.notes.log")" = 1 ]'
check "R9 no shell error on the lane's output ($(cat "$T/out"))" '! grep -qi "is a directory" "$T/out"'

# ── Mutation (D1): the cap check removed ────────────────────────────────────
rm -f "$LANE"; sed '/-ge "$READ_MAX"/,/^fi$/d' "$DIR/bin/daily-digest.sh" > "$LANE"; chmod +x "$LANE"
check "M1 the mutation changed the lane" '! cmp -s "$LANE" "$DIR/bin/daily-digest.sh"'
reset; echo 503 > "$T/route.code"; mkdir -p "$SD"; echo 8 > "$SD/reads-$D"; run
check "M1 no cap check: R2 sends a route request ($(n_route))" '[ "$(n_route)" = 1 ]'
rm -f "$LANE"; ln -s "$DIR/bin/daily-digest.sh" "$LANE"

echo "daily-digest-read-cap: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
