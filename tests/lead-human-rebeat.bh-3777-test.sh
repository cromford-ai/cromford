#!/bin/bash
# tests/lead-human-rebeat.bh-3777-test.sh — la_human_needed beats again once a
# day per (PR, head) while the head still waits on a human verdict (BH-3777).
# The one beat #3753/#3758 got (2026-09-30 20:33Z) was buried among 270 open
# alerts and never repeated.
#
# WHAT IS DRIVEN. The real bin/lib/lead-authority.sh, sourced, with HARNESS
# pointing at a scratch tree whose bin/lane-alert.sh records its argv (and
# exits 1 while $T/alertfail exists).
#   R1  a fresh marker: no second beat
#   R2  a marker 25h old: exactly one more beat, an `-r<YYYYMMDD>` id, the
#       human command in the text, and the marker re-stamped
#   R3  that beat's send fails: the marker's mtime is unchanged, and the next
#       call (send working again) beats
# Run from anywhere: tests/lead-human-rebeat.bh-3777-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"; mkdir -p "$H/bin" "$H/state"
printf '#!/bin/bash\n[ -e "%s" ] && exit 1\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/alertfail" "$T/alerts" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# shellcheck source=bin/lib/lead-authority.sh
. "$DIR/bin/lib/lead-authority.sh" || { echo "cannot source bin/lib/lead-authority.sh"; exit 1; }
export HARNESS="$H"

SLUG=example-org/cromford; PR=3758
HEAD=0123456789abcdef0123456789abcdef01234567
MARK="$H/state/lead-authority/human-needed-example-org_cromford-$PR-${HEAD:0:12}"
nbeats() { grep -c -- '--id lead-human-needed-' "$T/alerts" 2>/dev/null; }
mt() { date -r "$MARK" +%s 2>/dev/null; }
ask() { la_human_needed "$SLUG" "$PR" "$HEAD" "touches protected paths: catalog/switches.d/x-off.json" merge-conductor; }

# The first beat, unchanged (BH-3683 C1 pins its id and text).
ask; rc=$?
[ "$rc" = 0 ] && [ "$(nbeats)" = 1 ] && [ -e "$MARK" ] && ok || bad "setup: the first ask beats once and stamps the marker (rc $rc, beats $(nbeats))"
grep -q -- "--id lead-human-needed-example-org_cromford-$PR-${HEAD:0:12} " "$T/alerts" && ok || bad "setup: the first beat's id is unsuffixed: $(cat "$T/alerts")"

# ── R1: a fresh marker means no second beat ─────────────────────────────────
ask
[ "$(nbeats)" = 1 ] && ok || bad "R1: a marker under a day old must not beat again (beats $(nbeats): $(cat "$T/alerts"))"

# ── R2: a 25h-old marker beats once more ────────────────────────────────────
touch -d '25 hours ago' "$MARK" 2>/dev/null || touch -t "$(date -u -d '25 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$MARK"
OLD=$(mt)
ask
[ "$(nbeats)" = 2 ] && ok || bad "R2: a day-old marker beats exactly once more (beats $(nbeats): $(cat "$T/alerts"))"
L=$(tail -1 "$T/alerts")
grep -q -- "--id lead-human-needed-example-org_cromford-$PR-${HEAD:0:12}-r$(date -u +%Y%m%d) " <<<"$L" && ok || bad "R2: the re-beat's id carries -r<YYYYMMDD> (got: $L)"
grep -qF -- "bin/lead-verdict.sh post $SLUG $PR $HEAD MERGE --source human" <<<"$L" && ok || bad "R2: the re-beat names the human command (got: $L)"
[ "$(mt)" -gt "$OLD" ] && ok || bad "R2: the marker is re-stamped after the send ($(mt) vs $OLD)"
ask
[ "$(nbeats)" = 2 ] && ok || bad "R2: and the re-stamped marker holds for another day (beats $(nbeats))"

# ── R3: a failed send leaves the marker alone ───────────────────────────────
touch -d '25 hours ago' "$MARK" 2>/dev/null || touch -t "$(date -u -d '25 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$MARK"
OLD=$(mt)
: > "$T/alertfail"
ask; rc=$?
[ "$rc" != 0 ] && ok || bad "R3: a failed send answers non-zero (rc $rc)"
[ "$(mt)" = "$OLD" ] && ok || bad "R3: a failed send must not re-stamp the marker ($(mt) vs $OLD)"
rm -f "$T/alertfail"
ask
[ "$(nbeats)" = 3 ] && ok || bad "R3: the next call, with the send working, beats (beats $(nbeats))"

echo "lead-human-rebeat.bh-3777-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
