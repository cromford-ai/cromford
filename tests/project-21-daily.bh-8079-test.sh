#!/bin/bash
# tests/project-21-daily.bh-8079-test.sh — bin/project-21-daily.sh, the daily alert when
# the project-21 check failed on more than half of the day's builds. The pipeline.log
# lines are written by project-21_log_line (bin/lib/project-21.example), the writer the
# build lane's pr.sh block uses; bin/lane-alert.sh is a stub that logs its argv.
#   D1 3 of 4 failed: one open, --id project-21-check-failing --severity warn, "3 of 4"
#   D2 2 of 4 failed (exactly half): no open, one --resolve
#   D3 1 of 1 failed: one open        D4 a second run: the same --id again
#   D5 only off lines: no call, 0 counted
#   D6 a failed line older than the window is not counted
#   D7 the LAST line of a build decides (failed, then clean = clean)
#   D8 no builds dir: rc 0, one log line, no call
#   D9 PROJECT_21_DAILY_FAIL_PCT is the threshold (3 of 4 under 80 = no open)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/project-21-daily.bh-8079-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset PROJECT_21_DAILY_FAIL_PCT PROJECT_21_DAILY_WINDOW_H PROJECT_21_DAILY_NOW

H="$T/h"; mkdir -p "$H/bin"
scratch_install_closure bin/project-21-daily.sh "$H" >/dev/null || { echo "FAIL: closure of bin/project-21-daily.sh"; exit 1; }
scratch_install_closure bin/project-21-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/project-21-check.sh"; exit 1; }
[ -x "$H/bin/project-21-daily.sh" ] || { echo "FAIL: $SRC/bin/project-21-daily.sh is missing"; exit 1; }
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\n' "$T/alerts.log" > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
# shellcheck source=bin/lib/project-21.example
. "$H/bin/lib/project-21.example" || { echo "FAIL: bin/lib/project-21.example does not source"; exit 1; }

NOW=$(date -u -d '2026-10-23 12:00:00Z' +%s)
reset() { scratch_rm "$H/builds"; scratch_rm "$H/logs"; mkdir -p "$H/builds"; : > "$T/alerts.log"; }
build() { # build <name> <stamp> <state>... : one project-21 line per state, in order
  local n="$1" st="$2" s; shift 2
  mkdir -p "$H/builds/$n"
  for s in "$@"; do
    jq -n --arg s "$s" '{state:$s,reason:"",head:"",files:[],local_skipped:[],checked:2,affected:[],skipped:[]}' > "$T/res.json"
    project-21_log_line "$st [cromford/$n]" "$T/res.json" >> "$H/builds/$n/pipeline.log"
  done
}
lane() { lane_env; }
lane_env() { # lane_env [VAR=value]...
  out=$(env HARNESS="$H" LANE_GATE_DISABLE=1 PROJECT_21_DAILY_NOW="$NOW" "$@" "$H/bin/project-21-daily.sh" 2>&1); rc=$?; }
opens()    { grep -c -- '--severity warn' "$T/alerts.log" 2>/dev/null || true; }
resolves() { grep -c -- '--resolve' "$T/alerts.log" 2>/dev/null || true; }
T1='2026-10-23 06:00:00Z'

# D1 3 of 4 failed
reset; build b1 "$T1" failed; build b2 "$T1" failed; build b3 "$T1" failed; build b4 "$T1" clean
lane
{ [ "$rc" = 0 ] && [ "$(opens)" = 1 ] && [ "$(resolves)" = 0 ] \
  && grep -q -- '--id project-21-check-failing --severity warn project-21-daily project-21: the dependency check failed on 3 of 4 builds in the last 24h' "$T/alerts.log" \
  && grep -q 'failed=3 counted=4' "$H/logs/project-21-daily.log"; } && ok || bad "D1 3 of 4: rc=$rc alerts=$(cat "$T/alerts.log") out=$out log=$(cat "$H/logs/project-21-daily.log" 2>&1)"

# D2 exactly half
reset; build b1 "$T1" failed; build b2 "$T1" failed; build b3 "$T1" clean; build b4 "$T1" affected
lane
{ [ "$rc" = 0 ] && [ "$(opens)" = 0 ] && [ "$(resolves)" = 1 ] && grep -q -- '--resolve --id project-21-check-failing' "$T/alerts.log"; } \
  && ok || bad "D2 half: alerts=$(cat "$T/alerts.log")"

# D3 1 of 1, D4 a second run names the same id
reset; build b1 "$T1" failed
lane
[ "$(opens)" = 1 ] && ok || bad "D3 1 of 1: alerts=$(cat "$T/alerts.log")"
lane
{ [ "$(opens)" = 2 ] && [ "$(grep -c -- '--id project-21-check-failing' "$T/alerts.log")" = 2 ]; } && ok || bad "D4 rerun: alerts=$(cat "$T/alerts.log")"

# D5 only off lines
reset; build b1 "$T1" off; build b2 "$T1" off
lane
{ [ "$rc" = 0 ] && [ ! -s "$T/alerts.log" ] && grep -q 'failed=0 counted=0' "$H/logs/project-21-daily.log"; } \
  && ok || bad "D5 off only: alerts=$(cat "$T/alerts.log") log=$(cat "$H/logs/project-21-daily.log" 2>&1)"

# D6 a failed line 25 h before NOW is out of the window
reset; build old '2026-10-22 11:00:00Z' failed; build b1 "$T1" clean
lane
{ [ "$(opens)" = 0 ] && grep -q 'failed=0 counted=1' "$H/logs/project-21-daily.log"; } && ok || bad "D6 window: log=$(cat "$H/logs/project-21-daily.log")"

# D7 the last line decides
reset; build b1 "$T1" failed clean
lane
{ [ "$(opens)" = 0 ] && [ "$(resolves)" = 1 ] && grep -q 'failed=0 counted=1' "$H/logs/project-21-daily.log"; } && ok || bad "D7 last line: log=$(cat "$H/logs/project-21-daily.log")"

# D8 no builds dir
reset; scratch_rm "$H/builds"
lane
{ [ "$rc" = 0 ] && [ ! -s "$T/alerts.log" ] && [ "$(wc -l < "$H/logs/project-21-daily.log")" = 1 ]; } \
  && ok || bad "D8 no builds dir: rc=$rc log=$(cat "$H/logs/project-21-daily.log" 2>&1)"

# D9 the threshold knob
reset; build b1 "$T1" failed; build b2 "$T1" failed; build b3 "$T1" failed; build b4 "$T1" clean
lane_env PROJECT_21_DAILY_FAIL_PCT=80
{ [ "$(opens)" = 0 ] && [ "$(resolves)" = 1 ]; } && ok || bad "D9 threshold 80: alerts=$(cat "$T/alerts.log")"

echo "project-21-daily.bh-8079: PASS $PASS FAIL $FAIL"
[ "$FAIL" = 0 ]
