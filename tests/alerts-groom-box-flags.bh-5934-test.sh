#!/bin/bash
# tests/alerts-groom-box-flags.bh-5934-test.sh — BH-5934: bin/alerts-groom.sh also
# grooms the three dated box flag families by the date in the NAME, on the same
# ALERT_FLAG_RETENTION_DAYS knob and cutoff as the BH-1954 alerted-* groom:
#   flags/degraded-<box>-YYYYMMDD                 (bin/claude-auth-check.sh)
#   flags/authprobe-inconclusive-<box>-YYYYMMDD   (bin/claude-auth-check.sh)
#   flags/lane-caps-degraded-<lane>-YYYYMMDD-<cksum>  (bin/lib/lane-caps.sh _lc_log;
#                                                  the date is the MIDDLE segment)
#
# Runs the REAL script with HARNESS=$T, an empty $T/env and CONSOLE_URL unset,
# the same shape as tests/alerts-groom-flags.bh-1954-test.sh.
# Run from anywhere: tests/alerts-groom-box-flags.bh-5934-test.sh   (exit 0 = all pass)
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
TODAY=$(date -u +%Y%m%d); YDAY=$(day -1)

# groom [retention] — unset means the variable is absent, not empty.
groom() {
  : > "$GLOG"
  if [ $# -eq 0 ]; then
    env -u ALERT_FLAG_RETENTION_DAYS -u CONSOLE_URL -u HARNESS_SECRET -u HARNESS_ENV_DIR \
      HARNESS="$T" bash "$REPO/bin/alerts-groom.sh" >/dev/null 2>&1
  else
    env -u CONSOLE_URL -u HARNESS_SECRET -u HARNESS_ENV_DIR ALERT_FLAG_RETENTION_DAYS="$1" \
      HARNESS="$T" bash "$REPO/bin/alerts-groom.sh" >/dev/null 2>&1
  fi
}
kept() { [ -e "$F/$1" ] || [ -L "$F/$1" ] && ok || bad "$1 must be kept ($2)"; }
gone() { [ -e "$F/$1" ] && bad "$1 must be removed ($2)" || ok; }
clean() { scratch_rm "$T/flags"; mkdir -p "$T/flags"; }

# The auth-check names use the exact format of bin/claude-auth-check.sh
# (degraded_note: degraded-$BOX-$(date -u +%Y%m%d); inconclusive_note:
# authprobe-inconclusive-$BOX-$(date -u +%Y%m%d)). That script needs ssh and a
# live probe, so the suite builds the names rather than running it.
OLD=(degraded-hub-"$(day -8)" authprobe-inconclusive-fly-1-"$(day -30)"
     lane-caps-degraded-alert-triage-"$(day -8)"-123456789 lane-caps-degraded-a_b-c-"$(day -8)"-0)

# ---------- B1. default retention (7): the old file of each family goes ----------
clean
for n in "${OLD[@]}"; do : > "$F/$n"; done
groom; RC=$?
[ "$RC" = 0 ] && ok || bad "B1: the groom run must exit 0 (rc=$RC)"
for n in "${OLD[@]}"; do gone "$n" "B1: older than 7 days"; done
grep -q "flag groom: removed 4 dated box flag(s) (degraded-, authprobe-inconclusive-, lane-caps-degraded-) dated before $(day -7) (retention 7d)" "$GLOG" && ok \
  || bad "B1: the box summary line must count 4 removals: $(cat "$GLOG")"

# ---------- B2. per family: the cutoff day, today, yesterday and a future date stay ----------
clean
KEEP=()
for d in "$(day -7)" "$TODAY" "$YDAY" "$(day 3)"; do
  KEEP+=(degraded-hub-"$d" authprobe-inconclusive-fly-1-"$d" lane-caps-degraded-alert-triage-"$d"-123456789)
done
KEEP+=(degraded-hub degraded-hub-2026090 authprobe-inconclusive-x-202609011)
for n in "${KEEP[@]}"; do : > "$F/$n"; done
groom
for n in "${KEEP[@]}"; do kept "$n" "B2: not before the cutoff, or no 8-digit date"; done
grep -q 'flag groom: removed 0 dated box flag(s)' "$GLOG" && ok || bad "B2: nothing to remove: $(cat "$GLOG")"

# ---------- B3. lane-caps-degraded: the date is the MIDDLE segment ----------
clean
B3=(lane-caps-degraded-x-"$(day -8)"           # no cksum: the segment before the date is "x"
    lane-caps-degraded-x-"$(day -8)"-12ab      # the cksum is not all digits
    lane-caps-degraded-x-"$TODAY"-20200101)    # an old-looking 8-digit cksum, a recent middle
for n in "${B3[@]}"; do : > "$F/$n"; done
groom
for n in "${B3[@]}"; do kept "$n" "B3: lane-caps middle-segment rule"; done

# ---------- B4. wrong prefix, a directory, a symlink, another flag ----------
clean
: > "$F/lane-off-y"
B4=(xdegraded-hub-"$(day -30)" stale-degraded-hub-"$(day -30)" lane-off-y)
for n in "${B4[@]}"; do : > "$F/$n"; done
mkdir -p "$F/degraded-dir-$(day -30)"
ln -s "$F/lane-off-y" "$F/degraded-link-$(day -30)"
ln -s "$F/lane-off-y" "$F/lane-caps-degraded-l-$(day -30)-1"
groom
for n in "${B4[@]}"; do kept "$n" "B4: not a box-family flag"; done
[ -d "$F/degraded-dir-$(day -30)" ] && ok || bad "B4: a directory named degraded-* must be kept"
[ -L "$F/degraded-link-$(day -30)" ] && ok || bad "B4: a symlink named degraded-* must be kept"
[ -L "$F/lane-caps-degraded-l-$(day -30)-1" ] && ok || bad "B4: a symlink named lane-caps-degraded-* must be kept"

# ---------- B5. a refused knob deletes nothing in the box families ----------
for v in 1 abc; do
  clean
  for n in "${OLD[@]}"; do : > "$F/$n"; done
  groom "$v"; RC=$?
  [ "$RC" = 0 ] && ok || bad "B5: ALERT_FLAG_RETENTION_DAYS='$v' must exit 0 (rc=$RC)"
  for n in "${OLD[@]}"; do kept "$n" "B5: ALERT_FLAG_RETENTION_DAYS='$v' must refuse"; done
  grep -q 'flag groom skipped:' "$GLOG" && ok || bad "B5: ALERT_FLAG_RETENTION_DAYS='$v' must log the skip"
done

# ---------- B6. round trip through the real writer bin/lib/lane-caps.sh _lc_log ----------
lc_write() {  # lc_write <day>: one degrade flag, written by the real _lc_log
  ( HARNESS="$T" LANE_CAPS_DAY="$1"; export HARNESS LANE_CAPS_DAY
    . "$REPO/bin/lib/lane-caps.sh" || exit 1
    _lc_log alert-triage "fixture degrade message" )
}
for d in "$(day -8)" "$TODAY"; do
  clean
  lc_write "$d"
  c=$(find "$F" -maxdepth 1 -name "lane-caps-degraded-alert-triage-$d-*" | wc -l)
  [ "$c" -eq 1 ] && ok || bad "B6: _lc_log must write one lane-caps-degraded flag for $d (found $c)"
  groom
  c=$(find "$F" -maxdepth 1 -name "lane-caps-degraded-alert-triage-$d-*" | wc -l)
  if [ "$d" = "$TODAY" ]; then
    [ "$c" -eq 1 ] && ok || bad "B6: today's _lc_log flag must be kept"
  else
    [ "$c" -eq 0 ] && ok || bad "B6: the day -8 _lc_log flag must be removed"
  fi
done

# ---------- B7. the alerted-* groom keeps its own line and its own count ----------
clean
: > "$F/alerted-x-$(day -30)"
for n in "${OLD[@]}"; do : > "$F/$n"; done
groom
gone "alerted-x-$(day -30)" "B7: the BH-1954 groom still runs"
grep -q 'flag groom: removed 1 alerted-\* flag(s) dated before' "$GLOG" && ok \
  || bad "B7: the alerted-* line must count 1: $(cat "$GLOG")"
grep -q 'flag groom: removed 4 dated box flag(s)' "$GLOG" && ok \
  || bad "B7: the box line must count 4: $(cat "$GLOG")"

echo "alerts-groom-box-flags.bh-5934-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
