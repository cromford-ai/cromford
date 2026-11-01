#!/bin/bash
# tests/log-freshness.bh-8417-test.sh — BH-8417 (Scope E, T8): the dead-log lane.
#
# bin/log-freshness.sh reads catalog/log-freshness.d/*.tsv (one row per log:
# path, expected cadence in s, owning lane, reader), judges each log by the
# leading timestamp of its newest stamped line (file mtime when no line has
# one), and writes ONE ALERTS.log line per (log, stale-since day) through
# bin/alert-line.sh when the age is past LOG_FRESHNESS_MULT x cadence.
#
# Driven through the SHIPPED entry point in a scratch harness: the lane, its
# closure and bin/alert-line.sh (closure installed). bin/beat.sh is a stub that
# fails, so alert-line.sh appends to the scratch logs/ALERTS.log and calls no
# network. The real bin/lib/lane-gate.sh resolves the knob from a settings
# cache file (state/settings-cache.json) and a one-lane registry built from the
# committed catalog/lanes.d/log-freshness.json. The clock is LOG_FRESHNESS_NOW.
#
# Cases: F1 stale, F2 once per day, F3 fresh / fresh by 1 s / at the limit,
# F4 absent, F5 knob row MULT=10, F6 default 3 with no row, F7 committed
# fragments parse, F8 old markers pruned, F9 timestamp forms and mtime fallback,
# F10 unreadable fragment dir, F11 lane-off flag, F12 bad knob value.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/log-freshness.bh-8417-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "log-freshness: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# The product paths this ticket ships (D41).
SHIPS=("$DIR/bin/log-freshness.sh" "$DIR/catalog/lanes.d/log-freshness.json"
  "$DIR/catalog/log-freshness.d/archie-fm-watch.tsv" "$DIR/catalog/log-freshness.d/archie.tsv"
  "$DIR/catalog/log-freshness.d/alerts.tsv" "$DIR/cron/lanes/775-log-freshness.cron")
for f in "${SHIPS[@]}"; do
  if [ -f "$f" ]; then ok; else bad "missing ${f#"$DIR"/}"; fi
done
if [ ! -f "$DIR/bin/log-freshness.sh" ] || [ ! -f "$DIR/catalog/lanes.d/log-freshness.json" ]; then
  # ── F13: archie's quiet tick writes a line, so its log stays fresh ──────────
# bin/archie.sh used to exit without a line when no initiative was due, and
# the archie.tsv row would then read a healthy lane as a dead log.
AH="$T/ah"; mkdir -p "$AH/catalog" "$AH/env" "$AH/logs" "$AH/fakebin"
cp -rs "$DIR/bin" "$AH/bin"; cp -r "$DIR/catalog/lanes.d" "$AH/catalog/"; : > "$AH/env/global.env"
for c in curl gh; do printf '#!/bin/bash\nexit 7\n' > "$AH/fakebin/$c"; chmod +x "$AH/fakebin/$c"; done
cat > "$AH/fx.sh" <<'SH'
_jobs_req() {
  JOBS_HTTP=200; JOBS_BODY=""
  case "$1 ${2%%\?*}" in
    "GET /api/initiatives") printf '{"initiatives":[],"truncated":false}' ;;
    "GET /api/settings") printf '{"settings":[]}' ;;
    *) printf '{}' ;;
  esac
  return 0
}
SH
env PATH="$AH/fakebin:$PATH" HARNESS="$AH" HARNESS_TEST_SANDBOX=1 ARCHIE_FIXTURE="$AH/fx.sh" LANE_GATE_DISABLE=1 TMPDIR="$T" \
  bash "$AH/bin/archie.sh" tick > "$T/archie.out" 2>&1
check "F13 archie with no due initiative logs one tick line" 'grep -q " tick due=0: no active initiative is due" "$AH/logs/archie.log"'

echo "log-freshness: $PASS passed, $FAIL failed"; exit 1
fi

NOW=1793001600                      # 2026-10-26T08:00:00Z
DAY=20261026
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
H="$T/h"
mkdir -p "$H/catalog/log-freshness.d" "$H/logs" "$H/env"
: > "$H/env/global.env"
# Stubs first: scratch_install_closure never clobbers a file already there.
mkdir -p "$H/bin"
printf '#!/bin/bash\nexit 1\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
scratch_install_closure bin/log-freshness.sh "$H" >/dev/null \
  || { echo "FAIL: cannot install the lane closure (bin/log-freshness.sh)"; echo "log-freshness: $PASS passed, 1 failed"; exit 1; }
scratch_install_closure bin/alert-line.sh "$H" >/dev/null \
  || { echo "FAIL: cannot install bin/alert-line.sh"; echo "log-freshness: $PASS passed, 1 failed"; exit 1; }
jq '{lanes: [.]}' "$DIR/catalog/lanes.d/log-freshness.json" > "$T/lanes.json"

export HARNESS="$H" LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW="$NOW" TMPDIR="$T"
unset JOBS_URL HARNESS_SECRET LOG_FRESHNESS_MULT LOG_FRESHNESS_KEEP_D LOG_FRESHNESS_NOW \
  LANE_GATE_DISABLE LANE_RUN_ID ALERT_LINE_STAMP 2>/dev/null || true

FR="$H/catalog/log-freshness.d"
SD="$H/state/log-freshness"
ALOG="$H/logs/ALERTS.log"
reset() {
  scratch_rm "$FR" || exit 1; scratch_rm "$H/state" || exit 1; scratch_rm "$H/flags" || exit 1
  scratch_rm "$H/logs" || exit 1
  mkdir -p "$FR" "$H/logs" "$H/state"
}
# frag <name> <log-rel> <cadence> <lane> [reader]
frag() { printf '# %s\n%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-archie turn rule}" > "$FR/$1.tsv"; }
# stamp_log <rel> <epoch> — a log whose newest line is stamped <epoch>, mtime NOW.
stamp_log() {
  mkdir -p "$(dirname "$H/$1")"
  printf '%s older line\n%s tick findings=0\n' "$(iso $(( $2 - 600 )))" "$(iso "$2")" > "$H/$1"
  touch -d "@$NOW" "$H/$1"
}
settings() { # settings <json-object of values>
  jq -n --argjson v "$1" --argjson fa "$NOW" '{fetched_at: $fa, values: $v, seeded: {}}' > "$H/state/settings-cache.json"
}
run() { # run [VAR=value ...] [-- args]
  local envs=() args=()
  while [ $# -gt 0 ]; do case "$1" in --) shift; args=("$@"); break ;; *) envs+=("$1"); shift ;; esac; done
  env HARNESS_TEST_SANDBOX=1 LOG_FRESHNESS_NOW="$NOW" ${envs[@]+"${envs[@]}"} \
    bash "$H/bin/log-freshness.sh" ${args[@]+"${args[@]}"} > "$T/out" 2>&1
  echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
nal() { local n; n=$(grep -c -- "${1:-.}" "$ALOG" 2>/dev/null); printf '%s' "${n:-0}"; }
summary() { tail -1 "$H/logs/log-freshness.log" 2>/dev/null; }

# ── F1: a stale log is one ALERTS line naming the lane and the newest line ────
reset; frag t-stale logs/t-stale.log 600 lane-stale
stamp_log logs/t-stale.log $(( NOW - 1801 ))
run
check "F1 rc 0 ($(rc): $(cat "$T/out"))" '[ "$(rc)" = 0 ]'
check "F1 one ALERTS line ($(nal))" '[ "$(nal)" = 1 ]'
check "F1 the line names the log and the lane ($(cat "$ALOG" 2>/dev/null))" \
  'grep -F "logs/t-stale.log" "$ALOG" | grep -F "lane-stale" >/dev/null'
check "F1 the line names the newest line time it read ($(iso $(( NOW - 1801 ))))" \
  'grep -qF "$(iso $(( NOW - 1801 )))" "$ALOG"'
check "F1 the line says stale, not absent" 'grep -q "stale" "$ALOG" && ! grep -q "absent" "$ALOG"'
check "F1 the marker is alerted-t-stale-<stale-since day>" '[ -f "$SD/alerted-t-stale-$DAY" ]'
check "F1 one summary line with stale=1 ($(summary))" \
  '[ "$(grep -c . "$H/logs/log-freshness.log")" = 1 ] && summary | grep "stale=1" >/dev/null && summary | grep "alerted=1" >/dev/null'

# ── F2: a second run the same day is still one line ─────────────────────────
run
check "F2 2nd run: still one ALERTS line ($(nal))" '[ "$(nal)" = 1 ] && [ "$(rc)" = 0 ]'
run LOG_FRESHNESS_NOW=$(( NOW + 3600 ))
check "F2 an hour later the same day: still one ($(nal))" '[ "$(nal)" = 1 ]'
check "F2 the summary says alerted=0 on the repeat ($(summary))" 'summary | grep "alerted=0" >/dev/null'

# ── F3: fresh, fresh by 1 s, and exactly at the limit ───────────────────────
reset; frag t-fresh logs/t-fresh.log 600 lane-fresh
stamp_log logs/t-fresh.log $(( NOW - 60 )); run
check "F3 a fresh log: 0 ALERTS lines" '[ "$(nal)" = 0 ] && summary | grep "fresh=1" >/dev/null'
stamp_log logs/t-fresh.log $(( NOW - 1799 )); run
check "F3 fresh by 1 s (1799 of 1800): 0 lines" '[ "$(nal)" = 0 ]'
stamp_log logs/t-fresh.log $(( NOW - 1800 )); run
check "F3 exactly at 3 x 600: not past it, 0 lines" '[ "$(nal)" = 0 ]'
stamp_log logs/t-fresh.log $(( NOW - 1801 )); run
check "F3 one second past: 1 line" '[ "$(nal)" = 1 ]'

# ── F4: a missing log is one `absent` line, once ─────────────────────────────
reset; frag t-gone logs/t-gone.log 900 lane-gone; run
check "F4 rc 0" '[ "$(rc)" = 0 ]'
check "F4 one absent line naming the lane ($(cat "$ALOG" 2>/dev/null))" \
  '[ "$(nal)" = 1 ] && grep -q "absent" "$ALOG" && grep -qF "lane-gone" "$ALOG" && grep -qF "logs/t-gone.log" "$ALOG"'
run
check "F4 2nd run: still one" '[ "$(nal)" = 1 ] && summary | grep "absent=1" >/dev/null'

# ── F5: the knob row LOG_FRESHNESS_MULT=10 makes the stale case fresh ────────
reset; frag t-knob logs/t-knob.log 600 lane-knob
settings '{"lane.log-freshness.log_freshness_mult": "10"}'
stamp_log logs/t-knob.log $(( NOW - 1801 )); run
check "F5 MULT=10 row: 1801 s of 6000 is fresh, 0 lines ($(cat "$ALOG" 2>/dev/null))" '[ "$(nal)" = 0 ]'
check "F5 the summary names mult=10 ($(summary))" 'summary | grep "mult=10" >/dev/null'
stamp_log logs/t-knob.log $(( NOW - 6001 )); run
check "F5 MULT=10 row: 6001 s is stale, 1 line" '[ "$(nal)" = 1 ]'

# ── F6: no row, no env: the default 3 ───────────────────────────────────────
reset; frag t-def logs/t-def.log 100 lane-def
stamp_log logs/t-def.log $(( NOW - 301 )); run
check "F6 no row: 301 s past 3 x 100 is stale" '[ "$(nal)" = 1 ] && summary | grep "mult=3" >/dev/null'
reset; frag t-def logs/t-def.log 100 lane-def
stamp_log logs/t-def.log $(( NOW - 299 )); run
check "F6 no row: 299 s is fresh" '[ "$(nal)" = 0 ]'

# ── F7: every committed fragment parses and names a registered lane ─────────
reset
cp "$DIR"/catalog/log-freshness.d/*.tsv "$FR/"
mkdir -p "$H/catalog/lanes.d"
cp "$DIR/catalog/lanes.d/archie-fm-watch.json" "$DIR/catalog/lanes.d/archie.json" \
   "$DIR/catalog/lanes.d/pipeline-health.json" "$H/catalog/lanes.d/"
run -- --check
check "F7 --check on the committed fragments: rc 0 ($(cat "$T/out"))" '[ "$(rc)" = 0 ]'
check "F7 three rows" '[ "$(grep -c "^row " "$T/out")" = 3 ]'
for w in "logs/archie-fm-watch.log 600 archie-fm-watch" "logs/archie.log 900 archie" "logs/ALERTS.log 3600 pipeline-health"; do
  check "F7 row [$w]" 'grep -qF "row $w" "$T/out"'
done
check "F7 --check writes nothing" '[ ! -e "$ALOG" ] && [ ! -e "$H/logs/log-freshness.log" ]'
rm -f "$H/catalog/lanes.d/archie.json"; run -- --check
check "F7 a fragment whose lane is not registered: rc 1" '[ "$(rc)" = 1 ] && grep -q "archie" "$T/out"'
reset; printf 'logs/x.log\tsoon\tlane-x\treader\n' > "$FR/bad.tsv"; run -- --check
check "F7 a cadence that is not a number: rc 1" '[ "$(rc)" = 1 ]'
reset; printf '/etc/passwd\t60\tlane-x\treader\n' > "$FR/bad.tsv"; run -- --check
check "F7 an absolute path: rc 1" '[ "$(rc)" = 1 ]'
reset; printf '../x.log\t60\tlane-x\treader\n' > "$FR/bad.tsv"; run
check "F7 a bad row on a tick: rc 0, counted, no alert ($(summary))" \
  '[ "$(rc)" = 0 ] && summary | grep "bad_rows=1" >/dev/null && [ "$(nal)" = 0 ]'

# ── F8: markers older than LOG_FRESHNESS_KEEP_D (7) days are deleted ─────────
reset; frag t-fresh logs/t-fresh.log 600 lane-fresh; stamp_log logs/t-fresh.log $(( NOW - 60 ))
mkdir -p "$SD"
: > "$SD/alerted-old-20261001"; touch -d "@$(( NOW - 8 * 86400 ))" "$SD/alerted-old-20261001"
: > "$SD/alerted-young-20261021"; touch -d "@$(( NOW - 6 * 86400 ))" "$SD/alerted-young-20261021"
run
check "F8 an 8-day marker is deleted" '[ ! -e "$SD/alerted-old-20261001" ]'
check "F8 a 6-day marker stays" '[ -e "$SD/alerted-young-20261021" ]'
check "F8 the summary counts pruned=1 ($(summary))" 'summary | grep "pruned=1" >/dev/null'
: > "$SD/alerted-young-20261021"; touch -d "@$(( NOW - 6 * 86400 ))" "$SD/alerted-young-20261021"
settings '{"lane.log-freshness.log_freshness_keep_d": "5"}'; run
check "F8 KEEP_D=5 row: the 6-day marker is deleted" '[ ! -e "$SD/alerted-young-20261021" ]'

# ── F9: the timestamp forms, and the mtime fallback ─────────────────────────
reset; frag t-sp logs/t-sp.log 600 lane-sp
printf '%s [x] alert-line form\n' "$(date -u -d "@$(( NOW - 1801 ))" '+%F %TZ')" > "$H/logs/t-sp.log"; touch -d "@$NOW" "$H/logs/t-sp.log"
run
check "F9 a '%F %TZ' stamp (alert-line.sh) is read, mtime ignored: stale" '[ "$(nal)" = 1 ]'
reset; frag t-sp logs/t-sp.log 600 lane-sp
printf '%s fresh\ntrailing line with no stamp\n' "$(iso $(( NOW - 30 )))" > "$H/logs/t-sp.log"; touch -d "@$(( NOW - 9999 ))" "$H/logs/t-sp.log"
run
check "F9 the newest STAMPED line wins over an unstamped tail and an old mtime: fresh" '[ "$(nal)" = 0 ]'
reset; frag t-ms logs/t-ms.log 600 lane-ms
printf 'no stamp here\n' > "$H/logs/t-ms.log"; touch -d "@$(( NOW - 1801 ))" "$H/logs/t-ms.log"
run
check "F9 no stamped line: mtime 1801 s old is stale, and the line says mtime" \
  '[ "$(nal)" = 1 ] && grep -q "mtime" "$ALOG"'
reset; frag t-ms logs/t-ms.log 600 lane-ms
printf 'no stamp here\n' > "$H/logs/t-ms.log"; touch -d "@$(( NOW - 100 ))" "$H/logs/t-ms.log"
run
check "F9 no stamped line: mtime 100 s old is fresh" '[ "$(nal)" = 0 ]'
reset; frag t-off logs/t-off.log 600 lane-off
printf '%s offset form\n' "$(date -u -d "@$(( NOW - 1801 ))" '+%Y-%m-%dT%H:%M:%S+00:00')" > "$H/logs/t-off.log"
run
check "F9 a +00:00 offset stamp is read: stale" '[ "$(nal)" = 1 ]'

# ── F10: an unreadable fragment dir is rc 1 ─────────────────────────────────
reset; scratch_rm "$FR" || exit 1; run
check "F10 no fragment dir: rc 1 ($(rc))" '[ "$(rc)" = 1 ]'
check "F10 the log says why" 'grep -q "unreadable" "$H/logs/log-freshness.log"'

# ── F11: the lane-off flag stops the tick before any read ───────────────────
reset; frag t-gone logs/t-gone.log 900 lane-gone
mkdir -p "$H/flags"; : > "$H/flags/lane-off-log-freshness"; run
check "F11 lane-off flag: rc 0, no alert, no summary" \
  '[ "$(rc)" = 0 ] && [ "$(nal)" = 0 ] && [ ! -s "$H/logs/log-freshness.log" ]'

# ── F12: a knob value outside its range is one warn line and the default ────
reset; frag t-def logs/t-def.log 100 lane-def; stamp_log logs/t-def.log $(( NOW - 301 ))
run LOG_FRESHNESS_MULT=0
check "F12 MULT=0 from env: warn line, default 3 used (stale)" \
  'grep -q "LOG_FRESHNESS_MULT=0" "$H/logs/log-freshness.log" && [ "$(nal)" = 1 ] && summary | grep "mult=3" >/dev/null'

# ── F13: archie's quiet tick writes a line, so its log stays fresh ──────────
# bin/archie.sh used to exit without a line when no initiative was due, and
# the archie.tsv row would then read a healthy lane as a dead log.
AH="$T/ah"; mkdir -p "$AH/catalog" "$AH/env" "$AH/logs" "$AH/fakebin"
cp -rs "$DIR/bin" "$AH/bin"; cp -r "$DIR/catalog/lanes.d" "$AH/catalog/"; : > "$AH/env/global.env"
for c in curl gh; do printf '#!/bin/bash\nexit 7\n' > "$AH/fakebin/$c"; chmod +x "$AH/fakebin/$c"; done
cat > "$AH/fx.sh" <<'SH'
_jobs_req() {
  JOBS_HTTP=200; JOBS_BODY=""
  case "$1 ${2%%\?*}" in
    "GET /api/initiatives") printf '{"initiatives":[],"truncated":false}' ;;
    "GET /api/settings") printf '{"settings":[]}' ;;
    *) printf '{}' ;;
  esac
  return 0
}
SH
env PATH="$AH/fakebin:$PATH" HARNESS="$AH" HARNESS_TEST_SANDBOX=1 ARCHIE_FIXTURE="$AH/fx.sh" LANE_GATE_DISABLE=1 TMPDIR="$T" \
  bash "$AH/bin/archie.sh" tick > "$T/archie.out" 2>&1
check "F13 archie with no due initiative logs one tick line" 'grep -q " tick due=0: no active initiative is due" "$AH/logs/archie.log"'

echo "log-freshness: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
