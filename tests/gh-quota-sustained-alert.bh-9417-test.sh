#!/bin/bash
# tests/gh-quota-sustained-alert.bh-9417-test.sh — BH-9455 (BH-9417.4):
# bin/gh-quota-sustained-alert.sh writes ONE logs/ALERTS.log line per UTC day
# when a GitHub App bucket's counted requests stay at or above
# GH_QUOTA_ALERT_PCT of its limit for GH_QUOTA_ALERT_HOURS complete hours.
#
# WHY. On BH-9417's measured days the App installation bucket ran near its
# hourly limit for hours, and nothing said so until builds stopped on 403s. The
# lane is the early word: it reads the fleet gh_ledger the hub already holds
# and costs 0 GitHub calls.
#
# The harness-jobs worker is a `curl` stub on PATH. It answers
# GET /api/metrics/gh-ledger?since=<H>&until=<H> from $T/hours/<H>.json (and
# with the HTTP code in $T/hours/<H>.code when that file exists). A `gh` stub
# records any call. GH_QUOTA_ALERT_NOW pins the clock to 2026-10-20T10:30Z, so
# the three complete hours are 07, 08 and 09.
#
#   1. 3 h at 61% (4301/7050 on app-1, summed over two boxes) => one line that
#      names each hour and 4301; the day marker exists;
#   2. a second run the same UTC day => no new line, log says deduped;
#   3. 2 h at 61% + 1 h at 59% => no line, no marker;
#   4. exactly 60.0% (4230/7050) => one line;
#   5. pat-*, graphql-app-*, resource=search rows, two App buckets at 35% each
#      => no line;
#   6. the worker answers 500 for one hour => no line, no marker, one log line
#      with `unreadable`;
#   7. ledger limit_max 10000 => 43%, no line; limit_max 7100 with 4300 => line;
#   8. an alert-line.sh that writes nothing => no marker; next run => one line;
#   9. markers older than GH_QUOTA_ALERT_MARKER_DAYS are pruned, newer and
#      non-date files stay;
#  10. GH_QUOTA_ALERT=0 => no ledger read, no line, no log line;
#  11. 0 `gh` calls in every case;
#  12. each GH_QUOTA_ALERT* default names its catalog row;
#  13. truncated answer: over stays over; under is unreadable;
#  14. the current (incomplete) hour is never read.
#
# Run from anywhere: bash tests/gh-quota-sustained-alert.bh-9417-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: case 9c reads the real UTC day, and so does the lane; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 120 || exit 1
TODAY=$(date -u +%F)
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

unset GH_TOKEN GITHUB_TOKEN
for v in $(compgen -e | grep '^GH_QUOTA_ALERT'); do unset "$v"; done
export HARNESS="$T/h"
mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/flags" "$T/h/env" "$T/fake" "$T/req" "$T/tmp" "$T/hours"
# bin/ as a directory of links, so one case can swap alert-line.sh for a stub.
for f in "$DIR"/bin/*; do ln -s "$f" "$T/h/bin/${f##*/}"; done
LANE="$T/h/bin/gh-quota-sustained-alert.sh"
export TMPDIR="$T/tmp" HARNESS_ENV_DIR="$T/h/env"
export HARNESS_SECRET=test-secret JOBS_URL=http://jobs.test JOBS_RETRIES=0 BOX_ID=hub
export PATH="$T/fake:$PATH"
export GH_QUOTA_ALERT_NOW
GH_QUOTA_ALERT_NOW=$(date -u -d '2026-10-20T10:30:00Z' +%s)   # determinism: ok pinned
DAY=2026-10-20
H1=2026-10-20T07; H2=2026-10-20T08; H3=2026-10-20T09; HCUR=2026-10-20T10
ALERTS="$T/h/logs/ALERTS.log"
LOG="$T/h/logs/gh-quota-sustained-alert.log"
MDIR="$T/h/state/gh-quota-alert"
export STUB_DIR="$T"

cat > "$T/fake/curl" <<'SH'
#!/bin/bash
D="$STUB_DIR"; M=GET; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w|-o|-D|--data-binary|-d|--data) shift 2 ;;
    http*) URL="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$M" "$URL" >> "$D/req/all.lines"
code=200
case "$URL" in
  */api/metrics/gh-ledger\?*)
    h=${URL#*since=}; h=${h%%&*}
    [ -f "$D/hours/$h.code" ] && code=$(cat "$D/hours/$h.code")
    if [ -f "$D/hours/$h.json" ]; then cat "$D/hours/$h.json"; else printf '{"rows":[],"truncated":false}'; fi ;;
  *) code=404; printf '{"error":"unknown endpoint"}' ;;
esac
printf '\n%s' "$code"
SH
cat > "$T/fake/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$STUB_DIR/req/gh.calls"
exit 1
SH
chmod +x "$T/fake/curl" "$T/fake/gh"

# row <box> <meter> <resource> <counted> [limit_max] — one D1 aggregate row
row() { jq -nc --arg b "$1" --arg m "$2" --arg r "$3" --argjson k "$4" --argjson l "${5:-0}" \
  '{box:$b,lane:"merge-conductor",meter:$m,resource:$r,path_class:"repos/o/r/pulls/N",calls:$k,counted:$k,remaining_min:100,used_max:0,limit_max:$l}'; }
# hour <H> [truncated] — the rows on stdin become that hour's answer
hour() { jq -sc --arg h "$1" --argjson t "${2:-false}" '{rows: ., truncated: $t, since: $h, until: $h}' > "$T/hours/$1.json"; }
app_hour() { { row hub app-1 core "$2" "${3:-0}"; } | hour "$1"; }
reset() {
  scratch_rm "$MDIR"; rm -rf "$T/req/"* "$T/hours/"*; : > "$ALERTS"; : > "$LOG"; rm -f "$T/h/flags/"*
  rm -f "$T/h/bin/alert-line.sh"; ln -s "$DIR/bin/alert-line.sh" "$T/h/bin/alert-line.sh"
}
run() { "$@" bash "$LANE" hub > "$T/out" 2>&1; echo $? > "$T/rc"; }
nalerts() { grep -c '\[gh-quota-sustained-alert\]' "$ALERTS" 2>/dev/null | tr -dc 0-9; }
ledger_reads() { [ -f "$T/req/all.lines" ] || { echo 0; return; }; grep -c '/api/metrics/gh-ledger' "$T/req/all.lines" 2>/dev/null | tr -dc 0-9; }

[ -x "$DIR/bin/gh-quota-sustained-alert.sh" ] && ok || bad "0: bin/gh-quota-sustained-alert.sh must exist and be executable"

# ══ 1. 3 h at 61% ══════════════════════════════════════════════════════════════
reset
for h in $H1 $H2 $H3; do
  { row hub app-1 core 4000; row small app-1 - 301; row hub pat-default core 50; } | hour "$h"
done
run env
[ "$(cat "$T/rc")" = 0 ] && ok || bad "1: rc 0, got $(cat "$T/rc"): $(cat "$T/out")"
[ "$(nalerts)" = 1 ] && ok || bad "1: exactly one ALERTS line, got: $(cat "$ALERTS")"
L=$(grep '\[gh-quota-sustained-alert\]' "$ALERTS")
for h in $H1 $H2 $H3; do
  case "$L" in *"$h 4301/7050 (61%)"*) ok ;; *) bad "1: the line names hour $h with 4301/7050 (61%), got: $L" ;; esac
done
case "$L" in *"$H1"*"$H2"*"$H3"*) ok ;; *) bad "1: hours oldest first, got: $L" ;; esac
case "$L" in *"App bucket app-1"*">= 60%"*"3 full hours"*) ok ;; *) bad "1: bucket, pct and hours in words, got: $L" ;; esac
case "$L" in *"bin/gh-ledger-report.sh --last 24h --top 30 --per-merged-pr"*) ok ;; *) bad "1: the line names the report to read, got: $L" ;; esac
[ -e "$MDIR/$DAY" ] && ok || bad "1: day marker $MDIR/$DAY exists"
[ "$(grep -c . "$LOG")" = 1 ] && ok || bad "1: one lane-log line, got: $(cat "$LOG")"
grep -q "hours=$H1,$H2,$H3 pct=60 limit_src=knob buckets=app-1:.* alerted=1 deduped=0" "$LOG" && ok || bad "1: lane-log line shape, got: $(cat "$LOG")"
[ "$(ledger_reads)" = 3 ] && ok || bad "1: one ledger read per hour (3), got: $(cat "$T/req/all.lines")"
for h in $H1 $H2 $H3; do
  grep -q "since=$h&until=$h" "$T/req/all.lines" && ok || bad "1: the read for $h is bounded to that hour"
done

# ══ 14. the current hour is never read ═════════════════════════════════════════
grep -q "since=$HCUR" "$T/req/all.lines" && bad "14: the incomplete current hour $HCUR was read" || ok

# ══ 2. second run, same day ════════════════════════════════════════════════════
run env
[ "$(nalerts)" = 1 ] && ok || bad "2: no second line the same UTC day, got $(nalerts)"
grep -q 'deduped=1' <<<"$(tail -1 "$LOG")" && ok || bad "2: log says deduped, got: $(tail -1 "$LOG")"

# ══ 3. 2 h over, 1 h under ═════════════════════════════════════════════════════
reset
app_hour $H1 4301; app_hour $H2 4159; app_hour $H3 4301
run env
[ "$(nalerts)" = 0 ] && ok || bad "3: 59% in one hour => no line, got: $(cat "$ALERTS")"
[ -e "$MDIR/$DAY" ] && bad "3: no marker without an alert" || ok
grep -q 'alerted=0' "$LOG" && ok || bad "3: log alerted=0, got: $(cat "$LOG")"

# ══ 4. exactly 60.0% ═══════════════════════════════════════════════════════════
reset
for h in $H1 $H2 $H3; do app_hour "$h" 4230; done
run env
[ "$(nalerts)" = 1 ] && ok || bad "4: exactly 60.0% (4230/7050) is over, got: $(cat "$ALERTS")"
reset
for h in $H1 $H2 $H3; do app_hour "$h" 4229; done
run env
[ "$(nalerts)" = 0 ] && ok || bad "4b: 4229/7050 is under, got: $(cat "$ALERTS")"

# ══ 5. buckets that do not count ═══════════════════════════════════════════════
reset
for h in $H1 $H2 $H3; do
  { row hub pat-default core 4301; row hub pat-abc123 core 4301; row hub graphql-app-1 graphql 4301
    row hub app-1 search 4301; row hub app-1 graphql 4301; row hub graphql-pat-default core 4301
    row hub graphql-app-1 core 4301; row hub pat-app-1 core 4301; } | hour "$h"
done
run env
[ "$(nalerts)" = 0 ] && ok || bad "5a: pat-*, graphql-*, search rows never count, got: $(cat "$ALERTS")"
reset
for h in $H1 $H2 $H3; do { row hub app-1 core 2468; row hub app-163957841 core 2468; } | hour "$h"; done
run env
[ "$(nalerts)" = 0 ] && ok || bad "5b: two App buckets at 35% each never add up, got: $(cat "$ALERTS")"
reset
for h in $H1 $H2 $H3; do { row hub app-1 core 1000; row hub app-163957841 core 4301; } | hour "$h"; done
run env
[ "$(nalerts)" = 1 ] && ok || bad "5c: the one App bucket over alerts, got: $(cat "$ALERTS")"
L=$(grep '\[gh-quota-sustained-alert\]' "$ALERTS")
case "$L" in *"app-163957841"*) ok ;; *) bad "5c: the line names app-163957841, got: $L" ;; esac
case "$L" in *"bucket app-1 "*|*"bucket app-1:"*) bad "5c: app-1 (14%) is not named, got: $L" ;; *) ok ;; esac

# ══ 6. one hour unreadable ═════════════════════════════════════════════════════
reset
for h in $H1 $H2 $H3; do app_hour "$h" 4301; done
echo 500 > "$T/hours/$H2.code"
run env
[ "$(cat "$T/rc")" = 0 ] && ok || bad "6: rc 0, got $(cat "$T/rc")"
[ "$(nalerts)" = 0 ] && ok || bad "6: an unreadable hour => no line, got: $(cat "$ALERTS")"
[ -e "$MDIR/$DAY" ] && bad "6: no marker on unreadable" || ok
[ "$(grep -c . "$LOG")" = 1 ] && ok || bad "6: exactly one log line, got: $(cat "$LOG")"
grep -q "hour=$H2 unreadable why=" "$LOG" && ok || bad "6: the log line names the hour and says unreadable, got: $(cat "$LOG")"
reset
for h in $H1 $H2 $H3; do app_hour "$h" 4301; done
run env -u HARNESS_SECRET
[ "$(nalerts)" = 0 ] && ok || bad "6b: no HARNESS_SECRET => no line"
grep -q 'unreadable why="no HARNESS_SECRET"' "$LOG" && ok || bad "6b: unreadable why=no HARNESS_SECRET, got: $(cat "$LOG")"
reset
for h in $H1 $H2 $H3; do app_hour "$h" 4301; done
printf '{"error":"x"}' > "$T/hours/$H1.json"
run env
[ "$(nalerts)" = 0 ] && ok || bad "6c: no .rows array => no line"
grep -q "hour=$H1 unreadable" "$LOG" && ok || bad "6c: unreadable logged, got: $(cat "$LOG")"

# ══ 7. the limit comes from the ledger ═════════════════════════════════════════
reset
for h in $H1 $H2 $H3; do app_hour "$h" 4301 10000; done
run env
[ "$(nalerts)" = 0 ] && ok || bad "7a: limit_max 10000 makes 4301 43%, no line, got: $(cat "$ALERTS")"
grep -q 'limit_src=ledger' "$LOG" && ok || bad "7a: limit_src=ledger, got: $(cat "$LOG")"
reset
for h in $H1 $H2 $H3; do app_hour "$h" 4300 7100; done
run env
[ "$(nalerts)" = 1 ] && ok || bad "7b: 4300/7100 (60.56%) is over, got: $(cat "$ALERTS")"
grep -q "4300/7100" "$ALERTS" && ok || bad "7b: the line names the ledger limit 7100, got: $(cat "$ALERTS")"
reset
for h in $H1 $H2 $H3; do app_hour "$h" 3001; done
run env GH_QUOTA_ALERT_LIMIT=5000
[ "$(nalerts)" = 1 ] && ok || bad "7c: GH_QUOTA_ALERT_LIMIT is the fallback (3001/5000), got: $(cat "$ALERTS")"
reset
for h in $H1 $H2 $H3; do app_hour "$h" 3600; done
run env GH_QUOTA_ALERT_PCT=50 GH_QUOTA_ALERT_HOURS=2
[ "$(nalerts)" = 1 ] && ok || bad "7d: PCT and HOURS knobs are read, got: $(cat "$ALERTS")"
[ "$(ledger_reads)" = 2 ] && ok || bad "7d: HOURS=2 reads 2 hours, got $(ledger_reads)"

# ══ 8. a failed append leaves no marker ════════════════════════════════════════
reset
for h in $H1 $H2 $H3; do app_hour "$h" 4301; done
rm -f "$T/h/bin/alert-line.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/alert-line.sh"; chmod +x "$T/h/bin/alert-line.sh"
run env
[ "$(nalerts)" = 0 ] && ok || bad "8: stub writer wrote nothing"
[ -e "$MDIR/$DAY" ] && bad "8: a failed append must leave no marker" || ok
rm -f "$T/h/bin/alert-line.sh"; ln -s "$DIR/bin/alert-line.sh" "$T/h/bin/alert-line.sh"
run env
[ "$(nalerts)" = 1 ] && ok || bad "8: the next run with the real writer alerts, got: $(cat "$ALERTS")"
[ -e "$MDIR/$DAY" ] && ok || bad "8: marker after a real append"

# ══ 9. marker prune ════════════════════════════════════════════════════════════
reset
mkdir -p "$MDIR"
: > "$MDIR/2026-09-01"; : > "$MDIR/2026-09-20"; : > "$MDIR/2026-10-19"; : > "$MDIR/notes.txt"
run env
[ -e "$MDIR/2026-09-01" ] && bad "9: a marker older than 30 days is pruned" || ok
[ -e "$MDIR/2026-09-20" ] && ok || bad "9: a marker exactly 30 days old stays"
[ -e "$MDIR/2026-10-19" ] && ok || bad "9: yesterday's marker stays"
[ -e "$MDIR/notes.txt" ] && ok || bad "9: a non-date file stays"
: > "$MDIR/2026-10-10"
run env GH_QUOTA_ALERT_MARKER_DAYS=5
[ -e "$MDIR/2026-10-10" ] && bad "9b: GH_QUOTA_ALERT_MARKER_DAYS=5 prunes 2026-10-10" || ok
[ -e "$MDIR/2026-10-19" ] && ok || bad "9b: 2026-10-19 stays with 5 days"
: > "$MDIR/$TODAY"
run env GH_QUOTA_ALERT_NOW=$((GH_QUOTA_ALERT_NOW + 400 * 86400)) GH_QUOTA_ALERT_MARKER_DAYS=5
[ -e "$MDIR/$TODAY" ] && ok || bad "9c: a future GH_QUOTA_ALERT_NOW never prunes the real day's marker"

# ══ 10. kill switch ════════════════════════════════════════════════════════════
reset
for h in $H1 $H2 $H3; do app_hour "$h" 4301; done
run env GH_QUOTA_ALERT=0
[ "$(cat "$T/rc")" = 0 ] && ok || bad "10: rc 0"
[ "$(ledger_reads)" = 0 ] && ok || bad "10: GH_QUOTA_ALERT=0 reads no ledger, got: $(cat "$T/req/all.lines")"
[ "$(nalerts)" = 0 ] && ok || bad "10: no line"
[ -s "$LOG" ] && bad "10: no log write, got: $(cat "$LOG")" || ok

# ══ 13. truncated answers ══════════════════════════════════════════════════════
reset
for h in $H1 $H2; do app_hour "$h" 4301; done
{ row hub app-1 core 4301; } | hour $H3 true
run env
[ "$(nalerts)" = 1 ] && ok || bad "13a: over on a truncated (lower-bound) answer is over, got: $(cat "$ALERTS")"
reset
for h in $H1 $H2; do app_hour "$h" 4301; done
{ row hub app-1 core 100; } | hour $H3 true
run env
[ "$(nalerts)" = 0 ] && ok || bad "13b: under on a truncated answer => no line"
grep -q "hour=$H3 unreadable why=.*truncated" "$LOG" && ok || bad "13b: under on a truncated answer is unreadable, got: $(cat "$LOG")"

# ══ 11. 0 GitHub calls ═════════════════════════════════════════════════════════
[ -s "$T/req/gh.calls" ] && bad "11: gh was called: $(cat "$T/req/gh.calls")" || ok
grep -q 'github.com' "$T/req/all.lines" 2>/dev/null && bad "11: a github.com URL was requested" || ok
grep -qE 'gh_rest|gh-budget\.sh|(^|[^_a-z-])gh (api|pr|issue)' "$DIR/bin/gh-quota-sustained-alert.sh" && bad "11: the lane names a GitHub client" || ok

# ══ 12. every default names its row ════════════════════════════════════════════
for k in GH_QUOTA_ALERT GH_QUOTA_ALERT_PCT GH_QUOTA_ALERT_HOURS GH_QUOTA_ALERT_LIMIT GH_QUOTA_ALERT_MARKER_DAYS GH_QUOTA_ALERT_NOW; do
  grep -qE "\\\$\\{$k:-.*catalog/lanes\\.d/gh-quota-sustained-alert\\.json" "$DIR/bin/gh-quota-sustained-alert.sh" \
    && ok || bad "12: the \${$k:-...} read names its row catalog/lanes.d/gh-quota-sustained-alert.json"
  jq -e --arg k "$k" '.knobs | map(.env) | index($k) != null' "$DIR/catalog/lanes.d/gh-quota-sustained-alert.json" >/dev/null 2>&1 \
    && ok || bad "12: $k has a knob row in catalog/lanes.d/gh-quota-sustained-alert.json"
done

echo "gh-quota-sustained-alert.bh-9417: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
