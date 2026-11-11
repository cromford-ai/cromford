#!/bin/bash
# tests/heartbeat-reaper-lane-key.bh-9114-test.sh — the reaper's file pass pages a
# lane, not a pid (BH-9114).
#
# Before this, every finished run of a lane that wrote a plain (non-cron)
# heartbeat left state/heartbeat/<lane>.<pid>.json behind, the pid exited, and
# the reaper paged "<lane> dead" under hb-<lane>-<pid>-<start>: a NEW id, so a
# new console row, every run (about 96 open rows of pr-owner-sweep on
# 2026-11-05). What this suite pins:
#   R1  a cron-kind file plus its completion stamp: no page
#   R2  a dead file whose lane completed after it started: no page
#   R3  a dead file with a LATER run of the same lane: no page
#   R4  a real dead lane: exactly one page, id hb-<lane>
#   R5  two dead pids of one lane in one pass: one page, one beat
#   R6  the lane dead again under a new pid while hb-l1 is open: no new line
#   R7  near misses that must still page: another lane's newer file, an older
#       file, an equal started_at, a stamp older than the start
#   R8  after a dead page, a fresh run of the lane resolves hb-<lane>
#   R9  an alive silent lane pages hb-<lane> and its recovery resolves it
#   R10 a marker past HB_STALE_GC_S is removed with no resolve
# Every case drives the REAL bin/heartbeat-reaper.sh and bin/lane-alert.sh
# against a scratch $HARNESS. Fixtures are written by bin/lib/heartbeat.sh.
#
# Run from anywhere: tests/heartbeat-reaper-lane-key.bh-9114-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date +%s)
BOOT=$((NOW - 86400))

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/heartbeat" "$H/flags" "$H/locks" "$H/env" "$H/catalog/lanes.d" "$T/fakebin"
for s in bin/heartbeat-reaper.sh bin/lane-alert.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: scratch_install_closure $s"; exit 1; }
done
cp "$DIR/bin/alert_family.py" "$H/bin/" 2>/dev/null
chmod +x "$H/bin/"*.sh 2>/dev/null
: > "$H/env/global.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beats.txt"\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"

export HARNESS="$H"
# shellcheck source=bin/lib/heartbeat.sh
. "$DIR/bin/lib/heartbeat.sh" 2>/dev/null || true
command -v hb_start >/dev/null 2>&1 || bad "bin/lib/heartbeat.sh is missing or does not define hb_start"

HBD="$H/state/heartbeat"
DONE="$H/state/heartbeat-done"
ALERTS="$H/logs/ALERTS.log"
RLOG="$H/logs/heartbeat-reaper.log"

# One live pid and three that already exited, all real.
( trap - EXIT; exec sleep 300 ) & LIVE=$!
( trap - EXIT; exit 0 ) & G1=$!; wait "$G1" 2>/dev/null
( trap - EXIT; exit 0 ) & G2=$!; wait "$G2" 2>/dev/null
( trap - EXIT; exit 0 ) & G3=$!; wait "$G3" 2>/dev/null
__lk_exit() { local rc=$?
              [ "${__scratch_owner_pid:-}" = "${BASHPID:-$$}" ] || return 0
              kill "$LIVE" 2>/dev/null
              scratch_cleanup; exit "$rc"; }
trap __lk_exit EXIT

reset() {
  scratch_rm "$HBD" >/dev/null 2>&1; scratch_rm "$DONE" >/dev/null 2>&1
  scratch_rm "$H/state/alerts" >/dev/null 2>&1
  mkdir -p "$HBD"
  : > "$ALERTS"; : > "$T/beats.txt"; : > "$RLOG"
}
# mk <lane> <pid> <started-ago> <tick-ago> [kind] — a file the lib wrote, at a pinned clock.
mk() {
  HB_PID="$2" HB_NOW=$((NOW - $3)) hb_start "$1" 300 3600 "the $1 work" "" "${5:-}"
  HB_PID="$2" HB_NOW=$((NOW - $4)) hb_tick "$1" "tick"
}
# stamp <lane> <ago> — the completion stamp hb_done leaves (<epoch>\t<interval>).
stamp() { mkdir -p "$DONE"; printf '%s\t300\n' "$((NOW - $2))" > "$DONE/$1"; }
reap() {
  ( unset HB_SILENT_FLOOR_S HB_STALE_MULT HB_STALE_GC_S
    export HARNESS="$H" HB_NOW="$NOW" HB_BOOT_AT="$BOOT" PATH="$T/fakebin:$PATH"
    while [ $# -gt 0 ]; do export "${1?}"; shift; done
    timeout 20 "$H/bin/heartbeat-reaper.sh"; echo "rc=$?" )
}
lines() { local n; n=$(grep -c 'orchestrator/heartbeat-reaper' "$ALERTS" 2>/dev/null); printf '%s' "${n:-0}"; }
beats() { local n; n=$(grep -c . "$T/beats.txt" 2>/dev/null); printf '%s' "${n:-0}"; }
# opens <id> — fleet_alert beats that OPEN exactly this id (resolves excluded).
opens() { local n; n=$(jq -c --arg i "$1" 'select(.kind=="fleet_alert" and .alertid==$i and (.resolved|not))' "$T/beats.txt" 2>/dev/null | grep -c .); printf '%s' "${n:-0}"; }

# ── R1 a cron lane that completed: no page ─────────────────────────────────
reset
mk pr-owner-sweep "$G1" 600 590 cron
stamp pr-owner-sweep 580
reap >/dev/null
[ "$(lines)" = 0 ] && [ "$(beats)" = 0 ] && ok \
  || bad "R1 a cron-kind file plus a completion stamp must not page: $(cat "$ALERTS") :: $(cat "$T/beats.txt")"

# ── R2 a plain lane whose completion stamp is newer than the dead start ─────
reset
mk l1 "$G1" 600 590
stamp l1 100
reap >/dev/null
[ "$(lines)" = 0 ] && [ "$(beats)" = 0 ] && ok \
  || bad "R2 a dead file older than the lane's last completion must not page: $(cat "$ALERTS")"
[ ! -e "$HBD/l1.$G1.json" ] && grep -q "l1: pid $G1 ended; .*completion stamp.* — not a page" "$RLOG" && ok \
  || bad "R2 the spent file goes and the log names the stamp: $(ls "$HBD") :: $(cat "$RLOG")"

# ── R3 a later run of the same lane started: no page ────────────────────────
reset
mk l1 "$G1" 600 590
mk l1 "$LIVE" 60 5
reap >/dev/null
[ "$(lines)" = 0 ] && [ "$(beats)" = 0 ] && ok \
  || bad "R3 a dead file with a later run of its lane must not page: $(cat "$ALERTS")"
[ ! -e "$HBD/l1.$G1.json" ] && [ -s "$HBD/l1.$LIVE.json" ] \
  && grep -q "l1: pid $G1 ended; later run pid $LIVE started" "$RLOG" && ok \
  || bad "R3 the spent file goes, the later run's file stays, the log names the later pid: $(ls "$HBD") :: $(cat "$RLOG")"

# ── R4 a real dead lane: one page, a stable per-lane id ─────────────────────
reset
mk l1 "$G1" 600 590
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q "l1 dead for" "$ALERTS" && ok \
  || bad "R4 a dead lane with no later run and no completion must page once: $(cat "$ALERTS")"
[ "$(opens hb-l1)" = 1 ] && ! grep -q "\"alertid\":\"hb-l1-" "$T/beats.txt" && ok \
  || bad "R4 the page id must be hb-l1, never per pid: $(cat "$T/beats.txt")"

# ── R6 dead again under a new pid while hb-l1 is open: suppressed ───────────
# (Runs on R4's state on purpose: the open hb-l1 condition is the premise.)
BEFORE=$(lines)
mk l1 "$G2" 300 290
reap >/dev/null
[ "$(lines)" = "$BEFORE" ] && [ "$(opens hb-l1)" = 1 ] && ok \
  || bad "R6 the same lane dead under a new pid while hb-l1 is open must add no line: $(cat "$ALERTS")"

# ── R5 two dead pids of one lane in one pass: one page ──────────────────────
reset
mk l1 "$G1" 600 590
mk l1 "$G2" 600 590
reap >/dev/null
[ "$(lines)" = 1 ] && [ "$(opens hb-l1)" = 1 ] && ok \
  || bad "R5 two dead pids of one lane must page once under hb-l1: $(cat "$ALERTS") :: $(cat "$T/beats.txt")"
# R5b three dead pids of ONE lane are one finding, so they never read as a wave of three lanes.
reset
mk l1 "$G1" 600 590; mk l1 "$G2" 600 590; mk l1 "$G3" 600 590
reap HB_MASS_STALE_N=3 >/dev/null
[ "$(lines)" = 1 ] && ! grep -q "lanes stale at once" "$ALERTS" && [ "$(opens hb-l1)" = 1 ] && ok \
  || bad "R5b three dead pids of one lane must not collapse as three lanes: $(cat "$ALERTS")"

# ── R7 near misses: each still pages ────────────────────────────────────────
reset; mk l1 "$G1" 600 590; mk l1x "$LIVE" 60 5
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q "l1 dead for" "$ALERTS" && ok \
  || bad "R7 a newer file of ANOTHER lane (l1x) must not excuse l1: $(cat "$ALERTS")"
reset; mk l1 "$G1" 600 590; mk l1 "$LIVE" 900 5
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q "l1 dead for" "$ALERTS" && ok \
  || bad "R7 an OLDER run of l1 must not excuse the dead one: $(cat "$ALERTS")"
reset; mk l1 "$G1" 600 590; mk l1 "$LIVE" 600 5
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q "l1 dead for" "$ALERTS" && ok \
  || bad "R7 an EQUAL started_at is not a later run: $(cat "$ALERTS")"
reset; mk l1 "$G1" 600 590; stamp l1 700
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q "l1 dead for" "$ALERTS" && ok \
  || bad "R7 a completion stamp OLDER than the start must not excuse it: $(cat "$ALERTS")"
reset; mk l1 "$G1" 600 590; mkdir -p "$DONE"; printf 'garbage\t300\n' > "$DONE/l1"
reap >/dev/null
[ "$(grep -c "l1 dead for" "$ALERTS")" = 1 ] && ok \
  || bad "R7 an unreadable completion stamp must not excuse it: $(cat "$ALERTS")"

# ── R8 a fresh run after a dead page resolves hb-<lane> ─────────────────────
reset
mk l1 "$G1" 600 590
reap >/dev/null
[ -s "$HBD/l1.hbpaged" ] && ok || bad "R8 a dead page must leave the lane marker: $(ls "$HBD")"
mk l1 "$LIVE" 30 5
reap >/dev/null
grep -q "RESOLVED: .*a later run of l1" "$ALERTS" \
  && [ "$(jq -c 'select(.alertid=="hb-l1" and .resolved==true)' "$T/beats.txt" | grep -c .)" -ge 1 ] && ok \
  || bad "R8 a fresh run of l1 must resolve hb-l1: $(cat "$ALERTS") :: $(cat "$T/beats.txt")"
[ ! -e "$HBD/l1.hbpaged" ] && ok || bad "R8 the marker must be gone after the resolve: $(ls "$HBD")"
BEFORE=$(lines); BEATS=$(beats)
reap >/dev/null
[ "$(lines)" = "$BEFORE" ] && [ "$(beats)" = "$BEATS" ] && ok \
  || bad "R8 a second pass must not resolve again: $(cat "$ALERTS")"
# and a completed run resolves it the same way
reset
mk l1 "$G1" 600 590
reap >/dev/null
stamp l1 -30
reap "HB_NOW=$((NOW + 60))" >/dev/null
grep -q "RESOLVED: .*a later run of l1 completed" "$ALERTS" && [ ! -e "$HBD/l1.hbpaged" ] && ok \
  || bad "R8 a completion stamp newer than the page must resolve hb-l1: $(cat "$ALERTS")"

# ── R9 an alive silent lane: hb-<lane> pages and recovers ───────────────────
reset
HB_PID="$LIVE" HB_NOW=$((NOW - 200)) hb_start l1 60 600 "x"
HB_PID="$LIVE" HB_NOW=$((NOW - 181)) hb_tick l1 "tick"
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q "l1 silent for" "$ALERTS" && [ "$(opens hb-l1)" = 1 ] && ok \
  || bad "R9 an alive silent lane must page hb-l1: $(cat "$ALERTS") :: $(cat "$T/beats.txt")"
[ ! -e "$HBD/l1.hbpaged" ] && ok || bad "R9 a silent page is not a dead page: no marker"
HB_PID="$LIVE" HB_NOW=$((NOW + 7)) hb_tick l1 "back"
reap "HB_NOW=$((NOW + 10))" >/dev/null
grep -qE "RESOLVED: .*l1 resumed ticking" "$ALERTS" \
  && [ "$(jq -c 'select(.alertid=="hb-l1" and .resolved==true)' "$T/beats.txt" | grep -c .)" -ge 1 ] && ok \
  || bad "R9 the recovery must resolve hb-l1: $(cat "$ALERTS") :: $(cat "$T/beats.txt")"

# ── R10 an old marker is removed, with no resolve ──────────────────────────
reset
printf '%s\tl1\n' "$((NOW - 90000))" > "$HBD/l1.hbpaged"
mk l1 "$LIVE" 30 5
reap >/dev/null
[ ! -e "$HBD/l1.hbpaged" ] && [ "$(beats)" = 0 ] && grep -q "gc: removed l1.hbpaged" "$RLOG" && ok \
  || bad "R10 a marker past HB_STALE_GC_S goes with a log line and no resolve: $(ls "$HBD") :: $(cat "$RLOG")"

echo "heartbeat-reaper-lane-key.bh-9114: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
