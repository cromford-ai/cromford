#!/bin/bash
# tests/alerts-groom-flags.bh-1954-test.sh — BH-1954: bin/alerts-groom.sh grooms
# flags/alerted-*-YYYYMMDD by the date in the NAME, keeps ALERT_FLAG_RETENTION_DAYS
# days (code fallback 7), refuses a retention below 2 or not a whole number, and
# never touches today's or yesterday's flag.
#
# Runs the REAL script with HARNESS=$T. $T/env exists and is empty, so the env
# resolver stops there (no /etc/harness/env), and CONSOLE_URL is unset so the
# script's console half exits 0 right after the groom: the groom must not
# depend on the console being configured.
# Run from anywhere: tests/alerts-groom-flags.bh-1954-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/env" "$T/logs" "$T/locks" "$T/flags"
F="$T/flags"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
day() { date -u -d "$1 days" +%Y%m%d 2>/dev/null || date -u -v"$1"d +%Y%m%d; }
TODAY=$(date -u +%Y%m%d); YDAY=$(day -1)

# groom [retention] — unset means the variable is absent, not empty.
groom() {
  : > "$T/logs/alerts-groom.log"
  if [ $# -eq 0 ]; then
    env -u ALERT_FLAG_RETENTION_DAYS -u CONSOLE_URL -u HARNESS_SECRET -u HARNESS_ENV_DIR \
      HARNESS="$T" bash "$DIR/bin/alerts-groom.sh" >/dev/null 2>&1
  else
    env -u CONSOLE_URL -u HARNESS_SECRET -u HARNESS_ENV_DIR ALERT_FLAG_RETENTION_DAYS="$1" \
      HARNESS="$T" bash "$DIR/bin/alerts-groom.sh" >/dev/null 2>&1
  fi
}
kept() { [ -e "$F/$1" ] && ok || bad "$1 must be kept ($2)"; }
gone() { [ -e "$F/$1" ] && bad "$1 must be removed ($2)" || ok; }

# ---------- 1. default retention (7): only the dated, old, regular file goes ----------
for n in alerted-x-20260901 "alerted-x-$TODAY" "alerted-x-$YDAY" "alerted-x-$(day -7)" \
         alerted-nodate alerted-x-2026090 alerted-x-202609011 stale-alerted-foo-20260901 \
         lane-off-y "alerted-x-$(day 3)"; do : > "$F/$n"; done
mkdir -p "$F/alerted-dir-20260901"
ln -s "$F/lane-off-y" "$F/alerted-link-20260901"
groom; RC=$?
[ "$RC" = 0 ] && ok || bad "the groom run must exit 0 (rc=$RC)"
gone alerted-x-20260901 "older than 7 days"
kept "alerted-x-$TODAY" today; kept "alerted-x-$YDAY" yesterday
kept "alerted-x-$(day -7)" "the cutoff day itself is not before the cutoff"
kept alerted-nodate "no date"; kept alerted-x-2026090 "7 digits"; kept alerted-x-202609011 "9 digits"
kept stale-alerted-foo-20260901 "wrong prefix"; kept lane-off-y "not an alerted flag"
kept "alerted-x-$(day 3)" "future date"
[ -d "$F/alerted-dir-20260901" ] && ok || bad "a directory named alerted-* must be kept"
[ -L "$F/alerted-link-20260901" ] && ok || bad "a symlink named alerted-* must be kept"
grep -q 'flag groom: removed 1 alerted-\* flag(s) dated before' "$T/logs/alerts-groom.log" && ok \
  || bad "the summary line must count 1 removal: $(cat "$T/logs/alerts-groom.log")"

# ---------- 2. retention 2 from the knob ----------
for n in "alerted-z-$(day -3)" "alerted-z-$(day -2)" "alerted-z-$YDAY" "alerted-z-$TODAY"; do : > "$F/$n"; done
groom 2
gone "alerted-z-$(day -3)" "retention 2"
kept "alerted-z-$(day -2)" "retention 2, cutoff day"; kept "alerted-z-$YDAY" "retention 2"; kept "alerted-z-$TODAY" "retention 2"

# ---------- 3. a retention below 2, or not a whole number, deletes nothing ----------
for v in 1 0 abc -5 ""; do
  : > "$F/alerted-x-20260901"
  groom "$v"
  kept alerted-x-20260901 "ALERT_FLAG_RETENTION_DAYS='$v' must refuse"
  kept "alerted-x-$YDAY" "ALERT_FLAG_RETENTION_DAYS='$v'"
  grep -q 'flag groom skipped' "$T/logs/alerts-groom.log" && ok || bad "ALERT_FLAG_RETENTION_DAYS='$v' must log the skip"
done
rm -f "$F/alerted-x-20260901"

# ---------- 4. the name decides, never the mtime ----------
: > "$F/alerted-m-20260901"                              # fresh mtime, old name
: > "$F/alerted-m-$TODAY"; touch -d '30 days ago' "$F/alerted-m-$TODAY" 2>/dev/null \
  || touch -t "$(day -30)0000" "$F/alerted-m-$TODAY"     # old mtime, today's name
groom
gone alerted-m-20260901 "old name with a fresh mtime"
kept "alerted-m-$TODAY" "today's name with a 30-day-old mtime"

echo "alerts-groom-flags.bh-1954-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
