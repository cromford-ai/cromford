#!/bin/bash
# tests/daily-digest-approve-block.bh-9501-test.sh — BH-9501 (BH-9441.4): the
# "Lead review after in-build APPROVE" line of the daily digest.
#
# The lane cases (L1-L6) run the SHIPPED bin/daily-digest.sh from a scratch
# harness the way tests/daily-digest-outcome-gap.bh-3987-test.sh does:
# bin/beat.sh, bin/lane-alert.sh and bin/archie-tg-send.sh are shims, a fake
# `curl` first in PATH is the jobs worker, and the REAL dd_render renders. The
# fake worker answers
#   /api/metrics/daily-digest          the fixture day in $T/route.json;
#   /api/metrics/approve-then-block    $T/atb.json (or the raw $T/atb.body)
#                                      with the status in $T/atb.code;
#   /api/settings  $T/settings.json; /api/ledger keeps $T/ledger.json;
#   any other GET  404 (outcome-gap, archie actions, scheduler: left out).
# The render cases (R1-R4) source the renderer and call dd_render directly.
#
#   L1  a cohort of 4, 2 blocked: the sent line, the state json key
#   L2  route 500 / html / ok:false / array / off-contract / transport: n/a,
#       still sent, no alert
#   L3  route 404: no key, no line, one note, no alert
#   L4  the request carries days=14 by default and the settings row's 7
#   L5  DAILY_DIGEST_APPROVE_BLOCK_DAYS=99: one warn and days=14
#   L6  an otherwise empty day with a cohort stays empty
#   R1-R4 the render shapes: 6 repos (5 shown), cohort 0, ok:false, no key
#   M1  mutation: the lane's merge removed makes L1 red
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/daily-digest-approve-block.bh-9501-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "daily-digest-approve-block: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# The product paths this slice ships (D41).
for f in "$DIR/bin/daily-digest.sh" "$DIR/bin/lib/daily-digest-render.sh" "$DIR/catalog/lanes.d/daily-digest.knobs.d/DAILY_DIGEST_APPROVE_BLOCK_DAYS.json" \
         "$DIR/worker/jobs/src/routes/approve-then-block.js" "$DIR/worker/jobs/src/lib/approve-then-block.js" \
         "$DIR/worker/jobs/test/route-table.d/bh-9501-approve-then-block.txt" \
         "$DIR/docs/notes/2026-11-11-BH-9501-approve-then-block.md"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

FIX="$DIR/tests/fixtures/daily-digest/fixture-day.json"
EMPTYFIX="$DIR/tests/fixtures/daily-digest/empty-day.json"
RENDER="$DIR/bin/lib/daily-digest-render.sh"

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
printf '%s\n' "$1" >> "$FXT/beats"
exit 0
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
case "$url" in "$JOBS_URL"*) ;; *) exit 7 ;; esac
path="${url#"$JOBS_URL"}"
case "$path" in /api/metrics/approve-then-block*) [ -f "$FXT/atb.down" ] && exit 7 ;; esac
case "$path" in
  /api/settings*|/api/flags*|/api/lanes*) ;;
  *) printf '%s %s %s\n' "$m" "$path" "$body" >> "$REQLOG" ;;
esac
code=200; out='{"ok":true}'
case "$m $path" in
  "GET /api/settings"*)
    out=$(jq -c '{settings: .}' "$FXT/settings.json" 2>/dev/null || echo '{"settings":[]}') ;;
  *" /api/ledger"*)
    if [ "$m" = GET ]; then
      k=$(printf '%s' "$path" | sed -n 's/.*[?&]kind=\([^&]*\).*/\1/p')
      v=$(printf '%s' "$path" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')
      row=$(jq -c --arg i "$k/$v" '.[$i] // empty' "$FXT/ledger.json")
      if [ -n "$row" ]; then out=$(jq -nc --argjson r "$row" '{ledger: $r}'); else code=404; out='{"error":"not found"}'; fi
    else
      jq --argjson b "$body" '.[$b.kind + "/" + $b.key] = {status: $b.status, detail: ($b.detail // "")}' \
        "$FXT/ledger.json" > "$FXT/ledger.tmp" && mv "$FXT/ledger.tmp" "$FXT/ledger.json"
    fi ;;
  "GET /api/metrics/daily-digest"*) out=$(cat "$FXT/route.json") ;;
  "GET /api/metrics/approve-then-block"*)
    code=$(cat "$FXT/atb.code" 2>/dev/null || echo 200)
    if [ -f "$FXT/atb.body" ]; then out=$(cat "$FXT/atb.body"); else out=$(cat "$FXT/atb.json"); fi ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"

REQLOG="$T/reqlog"
export HARNESS="$H" FXT="$T" REQLOG \
  JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=test JOBS_BOX=hub \
  CONSOLE_PAGES_URL=https://console.invalid/ PATH="$T/fakebin:$PATH"
unset DAILY_DIGEST_ENABLED DAILY_DIGEST_SEND_HOUR_UTC DAILY_DIGEST_MAX_ITEMS DAILY_DIGEST_TEXT_MAX_CHARS \
  DAILY_DIGEST_REBUILD_LOOP_MIN DAILY_DIGEST_HUMAN_ACTORS DAILY_DIGEST_LLM_SUMMARY DAILY_DIGEST_LLM_MAX_USD \
  DAILY_DIGEST_GAP_MIN_USD DAILY_DIGEST_GAP_DAYS DAILY_DIGEST_GAP_LOOKBACK_DAYS DAILY_DIGEST_GAP_STAGES \
  DAILY_DIGEST_APPROVE_BLOCK_DAYS DAILY_DIGEST_NOW DAILY_DIGEST_FIXTURE NEEDS_HUMAN_TRIP_COUNT \
  LEAD_REVIEW_SPOTCHECK_PCT LANE_GATE_DISABLE BEAT_STRICT DD_TIMED 2>/dev/null || true

D=2026-09-29
NOW=1790751900          # 2026-09-30T07:05:00Z, so D is 2026-09-29
SD="$H/state/daily-digest"
C=https://console.invalid
CT=https://console.test

# atb_fixture <days> <repo:cohort:blocked>...: the body the route answers.
atb_fixture() {
  local days=$1; shift
  printf '%s\n' "$@" | jq -Rn --arg d "$D" --argjson days "$days" '
    [inputs | select(. != "") | split(":") | {repo: .[0], cohort: (.[1] | tonumber), blocked: (.[2] | tonumber)}
     | .share = (if .cohort > 0 then .blocked / .cohort else null end)] as $r
    | ($r | map(.cohort) | add // 0) as $c | ($r | map(.blocked) | add // 0) as $b
    | {ok: true, day: $d, from: "x", to: "y", days: $days, cohort: $c, blocked: $b,
       share: (if $c > 0 then $b / $c else null end), repos: ($r | sort_by(.repo))}'
}

reset() {
  local p
  for p in "$T/beats" "$T/alerts.log" "$T/ledger.json" "$T/route.json" "$T/atb.json" "$T/atb.body" "$T/atb.code" \
    "$T/atb.down" "$T/settings.json" "$H/state" "$H/logs" "$H/locks" "$H/flags"; do
    scratch_rm "$p" || exit 1
  done
  : > "$REQLOG"
  echo '{}' > "$T/ledger.json"; echo '[]' > "$T/settings.json"
  jq --arg d "$D" '.day = $d' "$FIX" > "$T/route.json"
  atb_fixture 14 example-org/cromford:3:2 example-org/project-9:1:0 > "$T/atb.json"
}
run() {
  env HARNESS_TEST_SANDBOX=1 DAILY_DIGEST_NOW="$NOW" "$@" bash "$LANE" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n_beat() { local n; n=$(wc -l 2>/dev/null < "$T/beats"); printf '%s' "${n:-0}" | tr -d ' '; }
line() { sed -n "${1:-1}p" "$T/beats" | jq -r .line; }
summary() { tail -1 "$H/logs/daily-digest.log" 2>/dev/null; }
atbq() { grep '^GET /api/metrics/approve-then-block' "$REQLOG"; }
notes() { cat "$H/logs/daily-digest.notes.log" 2>/dev/null; }
has() { grep -qF -- "$2" <<<"$1"; }
NAME="Lead review after in-build APPROVE"

# ── L1: a cohort of 4, 2 blocked, end to end ────────────────────────────────
reset; run
L=$(line)
check "L1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "L1 one beat ($(n_beat))" '[ "$(n_beat)" = 1 ]'
check "L1 the line: $(grep -F "$NAME" <<<"$L")" \
  'grep -qxF "$NAME, 14d to $D: blocked 2 of 4 PRs (50.0%). example-org/cromford 2/3, example-org/project-9 0/1. $C/" <<<"$L"'
check "L1 state json .approve_then_block.ok is true" '[ "$(jq -r .approve_then_block.ok "$SD/$D.json")" = true ]'
check "L1 state json carries the answer verbatim" 'cmp -s <(jq -S .approve_then_block "$SD/$D.json") <(jq -S . "$T/atb.json")'
check "L1 the rest of the state json is the route body" \
  'cmp -s <(jq -S "del(.approve_then_block)" "$SD/$D.json") <(jq -S . "$T/route.json")'
check "L1 summary sent=1 ($(summary))" 'summary | grep -q " sent=1 empty=0 "'
check "L1 no alert" '[ ! -s "$T/alerts.log" ]'

# ── L2: a failed read is n/a, never 0 of 0, and never an alert ──────────────
for how in 500 html notok array offcontract transport; do
  reset
  case "$how" in
    500) echo 500 > "$T/atb.code"; echo '{"error":"boom"}' > "$T/atb.body" ;;
    html) printf '<html>oops</html>' > "$T/atb.body" ;;
    notok) echo '{"ok":false,"error":"x"}' > "$T/atb.body" ;;
    array) echo '[]' > "$T/atb.body" ;;
    offcontract) echo '{"ok":true,"cohort":"4","blocked":2,"days":14,"repos":[]}' > "$T/atb.body" ;;
    transport) touch "$T/atb.down" ;;
  esac
  run
  L=$(line)
  check "L2 $how: one beat ($(n_beat))" '[ "$(n_beat)" = 1 ]'
  check "L2 $how: n/a line ($(grep -F "$NAME" <<<"$L"))" 'has "$L" "$NAME: n/a (read failed"'
  check "L2 $how: no count" '! has "$L" "$NAME, "'
  check "L2 $how: no alert ($(cat "$T/alerts.log" 2>/dev/null))" '[ ! -s "$T/alerts.log" ]'
  check "L2 $how: summary sent=1 ($(summary))" 'summary | grep -q " sent=1 "'
  check "L2 $how: state json ok:false" '[ "$(jq -r .approve_then_block.ok "$SD/$D.json")" = false ]'
done
reset; echo 500 > "$T/atb.code"; echo '{"error":"boom"}' > "$T/atb.body"; run
check "L2 500: the error names the status" '[ "$(jq -r .approve_then_block.error "$SD/$D.json")" = "read failed (http=500)" ]'

# ── L3: a 404 leaves the key out ────────────────────────────────────────────
reset; echo 404 > "$T/atb.code"; echo '{"error":"unknown endpoint","worker":"harness-jobs"}' > "$T/atb.body"; run
check "L3 404: sent ($(summary))" '[ "$(n_beat)" = 1 ] && summary | grep -q " sent=1 "'
check "L3 404: no key in the state json" '[ "$(jq "has(\"approve_then_block\")" "$SD/$D.json")" = false ]'
check "L3 404: no line in the text" '! line | grep -qF "$NAME"'
check "L3 404: one note ($(notes))" '[ "$(notes | grep -c "approve-then-block")" = 1 ]'
check "L3 404: no alert" '[ ! -s "$T/alerts.log" ]'

# ── L4: the knob rides the request ──────────────────────────────────────────
reset; run
check "L4 default days=14 ($(atbq))" '[ "$(atbq)" = "GET /api/metrics/approve-then-block?day=$D&days=14 " ]'
reset
echo '[{"key":"lane.daily-digest.daily_digest_approve_block_days","value":"7","actor":"operator"}]' > "$T/settings.json"
run
check "L4 settings row 7 ($(atbq))" '[ "$(atbq)" = "GET /api/metrics/approve-then-block?day=$D&days=7 " ]'

# ── L5: out of range is one warn and the default ────────────────────────────
reset; run DAILY_DIGEST_APPROVE_BLOCK_DAYS=99
check "L5 99: one warn ($(notes))" '[ "$(notes | grep -c "warn: DAILY_DIGEST_APPROVE_BLOCK_DAYS=99")" = 1 ]'
check "L5 99: days=14 asked ($(atbq))" '[ "$(atbq)" = "GET /api/metrics/approve-then-block?day=$D&days=14 " ]'

# ── L6: the line never makes a day not empty ────────────────────────────────
reset; jq --arg d "$D" '.day = $d' "$EMPTYFIX" > "$T/route.json"; run
check "L6 summary empty=1 ($(summary))" 'summary | grep -q " sent=1 empty=1 "'
check "L6 state json .empty is still true" '[ "$(jq -r .empty "$SD/$D.json")" = true ]'
check "L6 the line still renders" 'line | grep -qF "$NAME, 14d to $D: blocked 2 of 4 PRs"'

# ── R1-R4: the render ───────────────────────────────────────────────────────
render() { bash -c '. "$1" || exit 9; shift; dd_render "$@"' _ "$RENDER" "$1" "https://console.test/" - 0 "${2:-5}" -; }
variant() { jq --slurpfile a <(printf '%s' "$2") '.approve_then_block = $a[0]' "$FIX" > "$T/$1.json"; printf '%s' "$T/$1.json"; }
FD=$(jq -r .day "$FIX")
R1=$(render "$(variant r1 "$(atb_fixture 14 o/a:1:1 o/b:5:1 o/c:2:0 o/d:2:2 o/e:9:3 o/f:2:1)")" 5)
check "R1 six repos at max 5: by cohort desc then name, +1 more ($(grep -F "$NAME" <<<"$R1"))" \
  'grep -qxF "$NAME, 14d to $FD: blocked 8 of 21 PRs (38.1%). o/e 3/9, o/b 1/5, o/c 0/2, o/d 2/2, o/f 1/2, +1 more. $CT/" <<<"$R1"'
check "R1 the line is the last line" '[ "$(tail -1 <<<"$R1")" = "$(grep -F "$NAME" <<<"$R1")" ]'
R2=$(render "$(variant r2 "$(atb_fixture 7)")")
check "R2 cohort 0 ($(grep -F "$NAME" <<<"$R2"))" 'grep -qxF "$NAME: no in-build APPROVE in 7d to $FD. $CT/" <<<"$R2"'
R3=$(render "$(variant r3 '{"ok":false,"error":"read failed (http=500)"}')")
check "R3 ok:false is n/a" 'grep -qxF "$NAME: n/a (read failed: read failed (http=500)) $CT/" <<<"$R3"'
NOKEY=$(render "$FIX")
check "R4 no key: no line" '! grep -qF "$NAME" <<<"$NOKEY"'
check "R4 a render with the key, minus its line, is byte-identical to the no-key render" \
  '[ "$(grep -vF "$NAME" <<<"$R1")" = "$NOKEY" ]'
R4x=$(render "$(variant r4x "$(atb_fixture 14 'a<b>&c:3:1')")")
check "R4 <>& are stripped from a repo; 1 of 3 is 33.3%" 'has "$R4x" "blocked 1 of 3 PRs (33.3%). abc 1/3."'

# ── M1: the lane's merge removed makes L1 red (D1) ──────────────────────────
mutate() { rm -f "$1"; sed "$2" "$3" > "$1"; }
mutate "$LANE" 's/\.approve_then_block = \$a\[0\]/./' "$DIR/bin/daily-digest.sh"; chmod +x "$LANE"
check "M1 the mutation changed the lane" '! cmp -s "$LANE" "$DIR/bin/daily-digest.sh"'
reset; run
check "M1 no merge: L1's .approve_then_block.ok goes missing" '[ "$(jq -r .approve_then_block.ok "$SD/$D.json")" != true ]'
check "M1 no merge: L1's line goes missing" '! line | grep -qF "$NAME"'
rm -f "$LANE"; ln -s "$DIR/bin/daily-digest.sh" "$LANE"

echo "daily-digest-approve-block: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
