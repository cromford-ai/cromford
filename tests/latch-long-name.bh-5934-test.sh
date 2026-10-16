#!/bin/bash
# tests/latch-long-name.bh-5934-test.sh — BH-5934 item 2: a dated latch of 150
# characters or more keeps its -YYYYMMDD tail and is still purged by
# bin/alerts-groom.sh (groom_alert_flags) after ALERT_FLAG_RETENTION_DAYS.
# The name is built with the exact expression bin/agent-call.sh uses for
# flags/alerted-model-runner-mismatch-*, so a writer change that drops or
# truncates the date tail fails L1 here.
#
# Runs the REAL script with HARNESS=$T, an empty $T/env and CONSOLE_URL unset,
# the same shape as tests/alerts-groom-box-flags.bh-5934-test.sh.
# Run from anywhere: tests/latch-long-name.bh-5934-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamps below are read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/env" "$T/logs" "$T/locks" "$T/flags"
F="$T/flags"
GLOG="$T/logs/alerts-groom.log"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
day() { date -u -d "$1 days" +%Y%m%d 2>/dev/null || date -u -v"$1"d +%Y%m%d; }
TODAY=$(date -u +%Y%m%d)

groom() {
  : > "$GLOG"
  env -u ALERT_FLAG_RETENTION_DAYS -u CONSOLE_URL -u HARNESS_SECRET -u HARNESS_ENV_DIR \
    HARNESS="$T" bash "$REPO/bin/alerts-groom.sh" >/dev/null 2>&1
}
kept() { [ -e "$F/$1" ] && ok || bad "$2: ${1:0:40}… must be kept"; }
gone() { [ -e "$F/$1" ] && bad "$2: ${1:0:40}… must be removed" || ok; }
clean() { scratch_rm "$T/flags"; mkdir -p "$T/flags"; }

# The writer's expression, verbatim from bin/agent-call.sh (the alerted-model-
# runner-mismatch latch). The model id is padded so the name passes 150 chars.
SU=execute PROJECT=project-3 RUNNER=codex
MODEL="claude-fable-5-1-fixture-$(printf 'x%.0s' $(seq 1 64))"
latch() {  # latch <YYYYMMDD>
  printf '%s' "alerted-model-runner-mismatch-$(printf '%s-%s-%s-%s' "$SU" "$PROJECT" "$RUNNER" "$MODEL" | tr -c 'A-Za-z0-9._-' '_')-$1"
}

# L3. the suite builds the name the way the writer does: pin that the writer
# still has this expression and still ends the name in -$_ACDAY.
W=$(grep -F 'flags/alerted-model-runner-mismatch-' "$REPO/bin/agent-call.sh" | head -1)
[ -n "$W" ] || bad "L3: bin/agent-call.sh must still write flags/alerted-model-runner-mismatch-*"
case "$W" in
  *"\$(printf '%s-%s-%s-%s' \"\$SU\" \"\$PROJECT\" \"\$RUNNER\" \"\$MODEL\" | tr -c 'A-Za-z0-9._-' '_')-\$_ACDAY\""*) ok ;;
  *) bad "L3: the agent-call latch name must end in -\$_ACDAY, built as this suite builds it: $W" ;;
esac
grep -qE '^_ACDAY=\$\(date -u \+%Y%m%d\)' "$REPO/bin/agent-call.sh" && ok \
  || bad "L3: _ACDAY in bin/agent-call.sh must be the UTC day as YYYYMMDD"

OLD=$(latch "$(day -8)")
[ "${#OLD}" -ge 150 ] && ok || bad "L1: the fixture latch must be >= 150 chars (is ${#OLD})"

# ---------- L1. the 150-char latch past the window (default 7 days) is removed ----------
clean
: > "$F/$OLD"
groom; RC=$?
[ "$RC" = 0 ] && ok || bad "L1: the groom run must exit 0 (rc=$RC)"
gone "$OLD" "L1: dated day -8"
grep -q "flag groom: removed 1 alerted-\* flag(s) dated before $(day -7) (retention 7d)" "$GLOG" && ok \
  || bad "L1: the log line must count 1 removal: $(cat "$GLOG")"

# ---------- L2. the cutoff day and today are kept ----------
clean
K1=$(latch "$(day -7)"); K2=$(latch "$TODAY")
: > "$F/$K1"; : > "$F/$K2"
groom
kept "$K1" "L2: the cutoff day"
kept "$K2" "L2: today"
grep -q 'flag groom: removed 0 alerted-\* flag(s)' "$GLOG" && ok || bad "L2: nothing to remove: $(cat "$GLOG")"

# ---------- L4. a 150-char latch with no date tail is kept (no guess) ----------
clean
NODATE="alerted-$(printf 'y%.0s' $(seq 1 142))"
[ "${#NODATE}" -ge 150 ] && ok || bad "L4: the no-date fixture must be >= 150 chars (is ${#NODATE})"
# A shortened name that kept a numeric tail but not an 8-digit day (an md5
# cut to digits, a 7-digit stamp) is not a date either.
SHORT=$(latch 2026101); SHORT9=$(latch 202610011)
: > "$F/$NODATE"; : > "$F/$SHORT"; : > "$F/$SHORT9"
groom
kept "$NODATE" "L4: no -YYYYMMDD tail"
kept "$SHORT" "L4: a 7-digit tail"
kept "$SHORT9" "L4: a 9-digit tail"

echo "latch-long-name.bh-5934-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
