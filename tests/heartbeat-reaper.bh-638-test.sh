#!/bin/bash
# tests/heartbeat-reaper.bh-638-test.sh — the lane-liveness heartbeat (BH-638):
# bin/lib/heartbeat.sh writes one file PER WRITER (state/heartbeat/<lane>.<pid>.json),
# bin/heartbeat-reaper.sh reads them every 5 minutes and pages ONCE for a lane
# instance that went quiet.
#
# WHY THIS IS THE TEST THAT MATTERS. A detached merge-gate loop on the hub died
# and stayed dark for the best part of an hour because a dead lane and a lane
# with nothing to do look identical — both produce no output. So the assertions
# that carry the weight are the NEGATIVES: a fresh lane, a lane exactly at the
# boundary, a lane that already paged, a lane that exited cleanly, a lane whose
# clock ran backwards and a forever-loop with no expected-by must all stay
# silent, while an unreadable heartbeat must still page. A liveness check that
# can go quiet is the failure it was built to end.
#
# Everything here drives the REAL scripts against a scratch $HARNESS: the
# fixtures are files hb_start/hb_tick themselves wrote (never hand-typed JSON,
# except the one deliberately corrupt file), and the assertions are on
# logs/ALERTS.log, the beats a stubbed beat.sh recorded, state/heartbeat/*.json
# and state/heartbeat/restarts.log — never on the source text of the scripts.
# Section 9 runs bin/wake-loop.sh, bin/blocked-resolver.sh and
# bin/merge-conductor.sh themselves, so deleting a production hb_ call site
# fails this file.
#
# Run from anywhere: tests/heartbeat-reaper.bh-638-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
JQ_REAL=$(command -v jq)

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every age
# below is an offset from it, so this suite cannot pick its own red day.
NOW=$(date +%s)
BOOT=$((NOW - 86400))

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/heartbeat" "$H/flags" "$H/locks" "$H/env" \
         "$T/fakebin" "$T/stub" "$T/obs"
cp "$DIR/bin/heartbeat-reaper.sh" "$DIR/bin/lane-alert.sh" "$H/bin/" 2>/dev/null
cp "$DIR/bin/alert_family.py" "$H/bin/" 2>/dev/null
cp "$DIR/bin/lib/heartbeat.sh" "$DIR/bin/lib/alert-state.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/" 2>/dev/null
chmod +x "$H/bin/"*.sh 2>/dev/null
: > "$H/env/global.env"
# beat.sh is a recorder: "did this arrive through lane-alert.sh" is a fact about
# the beat, not a reading of the reaper's source.
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"
# setsid execs in place so a relaunch is observable in the fixture; the real one
# detaches, which is the only difference.
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"
# The restart stub records its argv, so "was it launched, once, with its
# arguments" is a line count in a file.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/launched.txt"\n' "$T" > "$T/stub/relaunch.sh"
chmod +x "$T/stub/relaunch.sh"
# A second restart stub that dumps the environment it was handed: "what does a
# relaunched lane inherit" is a fact about that file, not a reading of the
# reaper's source.
printf '#!/bin/bash\nenv > "%s/stub.env"\n' "$T" > "$T/stub/dumpenv.sh"
chmod +x "$T/stub/dumpenv.sh"

export HARNESS="$H"
# shellcheck source=bin/lib/heartbeat.sh
. "$DIR/bin/lib/heartbeat.sh" 2>/dev/null || true
command -v hb_start >/dev/null 2>&1 || bad "bin/lib/heartbeat.sh is missing or does not define hb_start"

HBD="$H/state/heartbeat"
ALERTS="$H/logs/ALERTS.log"
# The suppressed repeats land HERE, not in ALERTS.log: an alive lane that keeps
# re-firing an already-open id is invisible in the alert record and perfectly
# visible in this one (bin/lib/alert-state.sh's as_log).
ASLOG="$H/logs/alerts-state.log"
# The writer's key is (lane, pid), so every assertion names both.
hbf() { printf '%s/%s.%s.json' "$HBD" "$1" "$2"; }

# A live pid and a dead one, both real. The backgrounded sleep is a process to
# point at, never a delay this suite waits on. `trap - EXIT` first: bash runs an
# inherited EXIT trap when the child exits, and scratch.sh's would delete the
# whole scratch tree out from under this file the moment the dead one dies.
( trap - EXIT; exec sleep 300 ) & LIVE=$!
# The dead one exits on its OWN. Killing a background job is a race with the
# line above it: a SIGTERM that lands before `trap - EXIT` has run leaves bash
# executing the inherited trap, and scratch.sh's EXIT trap deletes $T.
( trap - EXIT; exec /bin/true ) & DEAD=$!
wait "$DEAD" 2>/dev/null
# Owner-guarded, like scratch.sh's own: a plain `trap ... EXIT` here would fire
# in every forked subshell below and delete the tree mid-run.
# It replaces tests/lib/rendered.sh's trap, so it reads rendered_verdict
# itself, before scratch_cleanup deletes the marker (BH-2263).
__hb_exit() { local rc=$?
              [ "${__scratch_owner_pid:-}" = "${BASHPID:-$$}" ] || return 0
              kill "$LIVE" 2>/dev/null
              rendered_verdict || { [ "$rc" -eq 0 ] && rc=1; }
              scratch_cleanup; exit "$rc"; }
trap __hb_exit EXIT

# mk <lane> <interval> <expect> <started-ago> <tick-ago> <pid> [blocks] [restart]
# The fixture is written by the LIB, at a pinned clock — a file shape the
# production path can never produce would prove nothing about the reaper.
mk() {
  HB_PID="$6" HB_NOW=$((NOW - $4)) hb_start "$1" "$2" "$3" "${7:-}" "${8:-}"
  HB_PID="$6" HB_NOW=$((NOW - $5)) hb_tick "$1" "tick"
}
reset() {
  scratch_rm "$HBD" >/dev/null 2>&1
  scratch_rm "$H/state/alerts" >/dev/null 2>&1
  mkdir -p "$HBD"
  : > "$ALERTS"; : > "$T/beats.txt"; : > "$T/launched.txt"; : > "$H/logs/heartbeat-reaper.log"
  : > "$ASLOG"
}
# reap [VAR=VAL ...] — one pass of the real reaper, with the clock pinned. The
# timeout is an assertion, not a safety net: this lane may never wait behind
# anything, so a pass that blocks is a failure, not a slow test.
reap() {
  ( export HARNESS="$H" HB_NOW="$NOW" HB_BOOT_AT="$BOOT" PATH="$T/fakebin:$PATH"
    while [ $# -gt 0 ]; do export "${1?}"; shift; done
    timeout 20 "$H/bin/heartbeat-reaper.sh"; echo "rc=$?" )
}
lines() { local n; n=$(grep -c 'orchestrator/heartbeat-reaper' "$ALERTS" 2>/dev/null); printf '%s' "${n:-0}"; }
beats() { local n; n=$(grep -c . "$T/beats.txt" 2>/dev/null); printf '%s' "${n:-0}"; }
still() { local n; n=$(grep -c 'still firing' "$ASLOG" 2>/dev/null); printf '%s' "${n:-0}"; }
# wait_file <path> — the restart branch detaches its child (nohup ... &), so the
# child's own output is the one thing in this suite the reaper's exit does not
# already order. Bounded and fast on success; a timeout is a failed assertion,
# never a slow pass.
wait_file() { local i=0
  while [ "$i" -lt 100 ]; do [ -s "${1:-}" ] && return 0; sleep 0.05; i=$((i + 1)); done
  return 1; }

# ── 1. the lib writes what the lanes promise ────────────────────────────────
reset
HB_PID=4242 HB_NOW=$NOW hb_start l1 300 1800 "x"
F=$(hbf l1 4242)
[ -s "$F" ] \
  && [ "$(jq -r .lane "$F")" = l1 ] && [ "$(jq -r .pid "$F")" = 4242 ] \
  && [ "$(jq -r .interval "$F")" = 300 ] && [ "$(jq -r .started_at "$F")" = "$NOW" ] \
  && [ "$(jq -r .last_tick "$F")" = "$NOW" ] && [ "$(jq -r .deadline "$F")" = "$((NOW + 1800))" ] \
  && [ "$(jq -r .blocks "$F")" = x ] && [ "$(jq -r .stale "$F")" = false ] && ok \
  || bad "S1 hb_start must write lane/pid/interval/started_at/deadline/blocks: $(cat "$F" 2>/dev/null)"
HB_PID=4242 HB_NOW=$((NOW + 7)) hb_tick l1 "n"
[ "$(jq -r .last_tick "$F")" = "$((NOW + 7))" ] && [ "$(jq -r .note "$F")" = n ] \
  && [ "$(jq -r .deadline "$F")" = "$((NOW + 1800))" ] && [ "$(jq -r .started_at "$F")" = "$NOW" ] \
  && [ "$(jq -r .interval "$F")" = 300 ] && ok \
  || bad "S1 hb_tick must move last_tick and note and keep the launch's declaration: $(cat "$F" 2>/dev/null)"
# The one-line adoption: hb_tick alone, with no hb_start, still leaves a file a
# reaper can read — that is what makes "one line per loop" true.
HB_PID=4242 HB_NOW=$NOW hb_tick l2
[ "$(jq -r .interval "$(hbf l2 4242)")" = 300 ] \
  && [ "$(jq -r .deadline "$(hbf l2 4242)")" = "$((NOW + 3600))" ] \
  && [ "$(jq -r .lane "$(hbf l2 4242)")" = l2 ] && ok \
  || bad "S1 hb_tick with no prior hb_start must create the file with the defaults: $(cat "$(hbf l2 4242)" 2>/dev/null)"
# A forever loop says so with expect 0, and that is not "expected by now".
HB_PID=4242 HB_NOW=$NOW hb_start l3 300 0
[ "$(jq -r .deadline "$(hbf l3 4242)")" = 0 ] && ok \
  || bad "S1 hb_start with expect 0 must write deadline 0 (no expected-by): $(cat "$(hbf l3 4242)" 2>/dev/null)"
# A lane name is a file name: a traversal in it must never become a path.
HB_PID=4242 HB_NOW=$NOW hb_tick "../escape"
[ -s "$(hbf .._escape 4242)" ] && [ ! -e "$HBD/../escape.4242.json" ] && ok \
  || bad "S1 a lane name must be slugged into one file name, not a path: $(ls "$HBD")"

# ── 2. a clean exit removes its OWN file, and only its own ──────────────────
HB_PID=4242 hb_done l1
[ ! -e "$F" ] && ok || bad "S2 hb_done must remove the caller's own file"
# 2b. THE #818 FINDING. merge-conductor (*/5) and blocked-resolver (*/10, fix
# rounds up to 90 minutes) overlap as their NORMAL state, so two instances of
# one lane are routine: each keeps its own file, and the one that finishes first
# must not take the survivor's heartbeat with it.
HB_PID=555 HB_NOW=$((NOW - 100)) hb_start ov 300 1800 "a"
HB_PID=666 HB_NOW=$NOW            hb_start ov 300 1800 "a"
[ -s "$(hbf ov 555)" ] && [ -s "$(hbf ov 666)" ] \
  && [ "$(jq -r .started_at "$(hbf ov 555)")" = "$((NOW - 100))" ] && ok \
  || bad "S2b two instances of one lane must keep two files with their own started_at: $(ls "$HBD")"
HB_PID=666 hb_done ov
[ ! -e "$(hbf ov 666)" ] && [ -s "$(hbf ov 555)" ] && ok \
  || bad "S2b the instance that exits first must not delete the wedged sibling's heartbeat: $(ls "$HBD")"

# ── 3. silent: alive, but past interval x 3 ─────────────────────────────────
reset
mk l1 60 600 200 181 "$LIVE" "x"
OUT=$(reap)
[ "$(lines)" = 1 ] && grep -qE "\[orchestrator/heartbeat-reaper\] l1 silent for 3m .* blocks: x" "$ALERTS" && ok \
  || bad "S3 one line naming the lane, the silence and what it blocks: $OUT :: $(cat "$ALERTS")"
# TEST-CHANGE (BH-9114): the file-pass id is per lane (hb-<lane>), no longer per pid and start.
grep -q '"alertid":"hb-l1"' "$T/beats.txt" && grep -q '"kind":"fleet_alert"' "$T/beats.txt" && ok \
  || bad "S3 the line must arrive through lane-alert.sh (beat, id per lane): $(cat "$T/beats.txt")"
# the boundary is >, not >=
reset
mk l1 60 600 200 180 "$LIVE" "x"
reap >/dev/null
[ "$(lines)" = 0 ] && ok || bad "S3 exactly interval x 3 is not yet silent: $(cat "$ALERTS")"
# a lane that declared interval 0 (WAKE_LOOP_INTERVAL_S=0 is a real setting)
# must not page the second it is between ticks
reset
mk l1 0 600 200 2 "$LIVE" "x"
reap >/dev/null
[ "$(lines)" = 0 ] && ok || bad "S3 interval 0 must not make every gap a silence: $(cat "$ALERTS")"
reset
mk l1 0 600 200 4 "$LIVE" "x"
# TEST-CHANGE (BH-4717): HB_SILENT_FLOOR_S=0 is the floor's off value, so this still proves the 1s clamp.
reap HB_SILENT_FLOOR_S=0 >/dev/null
[ "$(lines)" = 1 ] && ok || bad "S3 interval 0 still reasons as one second, so 4s of silence pages: $(cat "$ALERTS")"
# a heartbeat from the FUTURE (clock skew) is fresh, never a wrapped negative age
reset
HB_PID="$LIVE" HB_NOW=$((NOW - 200)) hb_start skew 60 600 "x"
HB_PID="$LIVE" HB_NOW=$((NOW + 600)) hb_tick skew "ahead"
reap >/dev/null
[ "$(lines)" = 0 ] && ok || bad "S3 a last_tick in the future must read fresh: $(cat "$ALERTS")"
# mutation: the multiplier is READ, not assumed
reset
mk l1 60 600 200 181 "$LIVE" "x"
reap HB_STALE_MULT=10 >/dev/null
[ "$(lines)" = 0 ] && ok || bad "S3 HB_STALE_MULT must be read: $(cat "$ALERTS")"
# 3c. an unreadable heartbeat pages; it is evidence, so it is never rewritten
reset
printf '{nope' > "$HBD/bad.7.json"
BYTES=$(wc -c < "$HBD/bad.7.json")
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q "unreadable heartbeat" "$ALERTS" && ok \
  || bad "S3c a corrupt heartbeat must page, not be skipped: $(cat "$ALERTS")"
[ -s "$HBD/bad.7.json" ] && [ "$(wc -c < "$HBD/bad.7.json")" = "$BYTES" ] && ok \
  || bad "S3c a corrupt heartbeat is evidence: it is never rewritten or deleted"
BEFORE=$(lines)
reap >/dev/null
[ "$(lines)" = "$BEFORE" ] && ok || bad "S3c and it must not repeat every five minutes: $(cat "$ALERTS")"
# a forever loop (deadline 0) a day into its run is not overdue
reset
HB_PID="$LIVE" HB_NOW=$NOW hb_start fv 300 0 "event wakes"
HB_PID="$LIVE" HB_NOW=$((NOW + 86400)) hb_tick fv "cycle n"
reap "HB_NOW=$((NOW + 86400))" >/dev/null
[ "$(lines)" = 0 ] && ok || bad "S3 a deadline-0 loop 24h in must not page: $(cat "$ALERTS")"
# and the same fixture WITH an expected-by does page, so that negative is not vacuous
reset
HB_PID="$LIVE" HB_NOW=$NOW hb_start fv 300 3600 "event wakes"
HB_PID="$LIVE" HB_NOW=$((NOW + 86400)) hb_tick fv "cycle n"
reap "HB_NOW=$((NOW + 86400))" >/dev/null
[ "$(lines)" = 1 ] && grep -q "fv overdue" "$ALERTS" && ok \
  || bad "S3 the same lane with an expected-by must go overdue: $(cat "$ALERTS")"

# ── 4. alert once: the mark is the READER's watermark, and recovery ends it ─
reset
mk l1 60 600 200 181 "$LIVE" "x"
FL=$(hbf l1 "$LIVE")
[ "$(jq -r .stale "$FL")" = false ] || bad "S4 fixture: the file must start unmarked"
reap >/dev/null
[ "$(jq -r .stale "$FL")" = true ] && [ "$(jq -r .stale_at "$FL")" = "$NOW" ] && ok \
  || bad "S4 the file must be marked stale: $(cat "$FL" 2>/dev/null)"
BEFORE=$(lines); BEATS=$(beats)
reap >/dev/null
[ "$(lines)" = "$BEFORE" ] && [ "$(beats)" = "$BEATS" ] && ok \
  || bad "S4 a second pass must add no line and no beat: $(cat "$ALERTS")"
# A TICK MUST NOT CLEAR THE MARK. `stale`/`stale_at` belong to the reaper, not to
# the lane: a writer that cleared them would unmark an alive-but-overdue lane on
# every tick, and the next pass would find it unmarked, mark it and fire the same
# id again — five minutes apart, for as long as the lane runs.
HB_PID="$LIVE" HB_NOW=$((NOW + 7)) hb_tick l1 "back"
[ "$(jq -r .stale "$FL")" = true ] && [ "$(jq -r .last_tick "$FL")" = "$((NOW + 7))" ] \
  && [ "$(jq -r .stale_at "$FL")" = "$NOW" ] && ok \
  || bad "S4 hb_tick must move last_tick and leave the reaper's mark alone: $(cat "$FL" 2>/dev/null)"
# The reader clears it, once, and closes the condition it opened.
reap "HB_NOW=$((NOW + 10))" >/dev/null
[ "$(jq -r .stale "$FL")" = false ] && [ "$(lines)" = "$((BEFORE + 1))" ] \
  && grep -qE "RESOLVED: .*l1 resumed ticking" "$ALERTS" && ok \
  || bad "S4 a lane that resumes ticking must be unmarked and resolved once: $(cat "$ALERTS")"
# TEST-CHANGE (BH-4054): lane-alert.sh --resolve sends the orclane:<id> resolve
# AND its console twin alert:<id>, so the recovery is two beats, one of each.
grep -q '"alertstate":"resolve"' "$T/beats.txt" && [ "$(beats)" = "$((BEATS + 2))" ] \
  && [ "$(grep -c '"kind":"alert","project":"fleet","akey":"alert:hb-l1"' "$T/beats.txt")" = 1 ] && ok \
  || bad "S4 the recovery must go out through lane-alert.sh --resolve: $(cat "$T/beats.txt")"
BEFORE=$(lines); BEATS=$(beats)
reap "HB_NOW=$((NOW + 11))" >/dev/null
[ "$(lines)" = "$BEFORE" ] && [ "$(beats)" = "$BEATS" ] && ok \
  || bad "S4 a recovered lane must not page again, and must not resolve twice: $(cat "$ALERTS")"
# 4b. AN ALIVE LANE PAST ITS EXPECTED-BY. It keeps ticking, so it never recovers
# into `fresh` — and it must not be re-found and re-fired every pass either. The
# repeat is invisible in ALERTS.log (lane-alert suppresses the open id) and fully
# visible in logs/alerts-state.log, which is where it was costing a "still
# firing" row every five minutes and a reminder page every ALERT_REMINDER_S.
reset
HB_PID="$LIVE" HB_NOW=$((NOW - 120)) hb_start ovl 300 60 "the drain of parked PRs"
HB_PID="$LIVE" HB_NOW=$((NOW - 5))   hb_tick  ovl "working"
FO=$(hbf ovl "$LIVE")
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q "ovl overdue" "$ALERTS" && [ "$(jq -r .stale "$FO")" = true ] && ok \
  || bad "S4b an alive lane past its expected-by must page once: $(cat "$ALERTS")"
BEFORE=$(lines); BEATS=$(beats); STILL=$(still); STEP=0
while [ "$STEP" -lt 3 ]; do
  STEP=$((STEP + 1))
  HB_PID="$LIVE" HB_NOW=$((NOW + STEP * 300 - 1)) hb_tick ovl "working"
  reap "HB_NOW=$((NOW + STEP * 300))" >/dev/null
done
[ "$(lines)" = "$BEFORE" ] && [ "$(beats)" = "$BEATS" ] && [ "$(still)" = "$STILL" ] \
  && [ "$(jq -r .stale "$FO")" = true ] && ok \
  || bad "S4b three more passes over a ticking overdue lane must add nothing: $(cat "$ASLOG")"

# ── 5. the pid is gone before its deadline ─────────────────────────────────
reset
mk l1 60 3600 100 10 "$DEAD" "PR merges fleet-wide"
reap >/dev/null
# TEST-CHANGE (BH-4717): the age now renders through hb_age_text, so a 10s age reads "10s", not "0m".
[ "$(lines)" = 1 ] && grep -q "l1 dead for 10s (pid $DEAD gone" "$ALERTS" \
  && grep -q "blocks: PR merges fleet-wide" "$ALERTS" && ok \
  || bad "S5 a pid gone before the deadline is dead, and says so: $(cat "$ALERTS")"
[ -s "$(hbf l1 "$DEAD")" ] && [ "$(jq -r .stale "$(hbf l1 "$DEAD")")" = true ] && ok \
  || bad "S5 a dead lane leaves its file behind, marked stale — that file IS the signal"
# A lane that died between hb_start and its FIRST tick has an empty note, and an
# empty field may not shift the ones after it out of the line: `blocks` is the
# whole point of the alert ("what is not happening while this lane is down"), and
# a tab-separated read collapses the run of delimiters and loses it.
reset
HB_PID="$DEAD" HB_NOW=$((NOW - 100)) hb_start l9 60 3600 "the drain of parked PRs"
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q "note: -" "$ALERTS" && grep -q "blocks: the drain of parked PRs" "$ALERTS" && ok \
  || bad "S5 a lane that never ticked must still name what it blocks: $(cat "$ALERTS")"

# ── 6. a reboot kills every lane at once: ONE line, not five ───────────────
reset
for n in m1 m2 m3 m4 m5; do mk "$n" 60 7200 7200 1800 "$LIVE" "the $n lane"; done
reap "HB_BOOT_AT=$((NOW - 600))" >/dev/null
GOT=$(lines)
[ "$GOT" = 1 ] && ok || bad "S6 five stale lanes must collapse to one line, got $GOT: $(cat "$ALERTS")"
MISS=""
for n in m1 m2 m3 m4 m5; do grep -q "$n" "$ALERTS" || MISS="$MISS $n"; done
[ -z "$MISS" ] && grep -q "5 lanes stale at once" "$ALERTS" && grep -q "rebooted" "$ALERTS" \
  && grep -q '"alertid":"hb-mass-' "$T/beats.txt" && ok \
  || bad "S6 the collapsed line must name every lane and the reboot (missing:$MISS): $(cat "$ALERTS")"
STILL=""
for n in m1 m2 m3 m4 m5; do [ "$(jq -r .stale "$(hbf "$n" "$LIVE")" 2>/dev/null)" = true ] || STILL="$STILL $n"; done
[ -z "$STILL" ] && ok || bad "S6 every collapsed lane must still be marked stale (not marked:$STILL)"
# the threshold is READ: above it, five findings are five lines
reset
for n in m1 m2 m3 m4 m5; do mk "$n" 60 7200 7200 1800 "$LIVE" "the $n lane"; done
reap "HB_BOOT_AT=$((NOW - 600))" HB_MASS_STALE_N=9 >/dev/null
[ "$(lines)" = 5 ] && ok || bad "S6 HB_MASS_STALE_N must be read (expected 5 lines): $(cat "$ALERTS")"

# ── 7. restart, only when the lane declared one, capped per hour ───────────
reset
mk r1 60 600 100 10 "$DEAD" "the drain" "$T/stub/relaunch.sh --x"
reap >/dev/null
[ "$(wc -l < "$T/launched.txt")" = 1 ] && grep -q -- "--x" "$T/launched.txt" && ok \
  || bad "S7 a declared restart must be launched once with its argv: $(cat "$T/launched.txt")"
[ "$(grep -c . "$HBD/restarts.log" 2>/dev/null)" = 1 ] && grep -q "	r1	" "$HBD/restarts.log" && ok \
  || bad "S7 the relaunch must be ledgered: $(cat "$HBD/restarts.log" 2>/dev/null)"
[ ! -e "$(hbf r1 "$DEAD")" ] && grep -q "relaunched (1 of 3" "$ALERTS" && ok \
  || bad "S7 the spent file goes after a relaunch, and the line says so: $(cat "$ALERTS")"
# a lane that is SILENT (not dead) is never relaunched, whatever it declared
reset
mk r1s 60 600 200 181 "$LIVE" "the drain" "$T/stub/relaunch.sh --z"
reap >/dev/null
[ ! -s "$T/launched.txt" ] && grep -q "not relaunched (it is silent" "$ALERTS" && ok \
  || bad "S7 only a DEAD lane is relaunched: $(cat "$ALERTS") :: $(cat "$T/launched.txt")"
# the cap refuses the fourth in an hour
reset
printf '%s\tr2\t/x\n%s\tr2\t/x\n%s\tr2\t/x\n' "$((NOW - 100))" "$((NOW - 200))" "$((NOW - 300))" > "$HBD/restarts.log"
mk r2 60 600 100 10 "$DEAD" "the drain" "$T/stub/relaunch.sh --y"
reap >/dev/null
[ ! -s "$T/launched.txt" ] && grep -q "cap reached" "$ALERTS" && [ "$(grep -c . "$HBD/restarts.log")" = 3 ] && ok \
  || bad "S7 cap: nothing launched, nothing ledgered, the line says cap: $(cat "$ALERTS") :: $(cat "$T/launched.txt")"
# a restart value that is a shell string is refused, never executed
reset
mk r3 60 600 100 10 "$DEAD" "the drain" "bash -c 'touch /tmp/never-bh638'"
reap >/dev/null
[ ! -s "$T/launched.txt" ] && [ ! -e "$HBD/restarts.log" ] && grep -q "refused" "$ALERTS" && ok \
  || bad "S7 a shell string must be refused, not run: $(cat "$ALERTS")"
# a relative path is refused too — the reaper's cwd is not the lane's
reset
mk r4 60 600 100 10 "$DEAD" "the drain" "relaunch.sh --w"
reap >/dev/null
[ ! -s "$T/launched.txt" ] && grep -q "not an absolute path" "$ALERTS" && ok \
  || bad "S7 a relative restart path must be refused: $(cat "$ALERTS")"
# a lane that declared nothing is never relaunched
reset
mk n1 60 600 100 10 "$DEAD" "nothing"
reap >/dev/null
[ ! -s "$T/launched.txt" ] && [ ! -e "$HBD/restarts.log" ] && grep -q "not restartable" "$ALERTS" && ok \
  || bad "S7 no restart declared: nothing launched, and the line says so: $(cat "$ALERTS")"

# ── 8. no lock, no queue, and no signal ───────────────────────────────────
reset
mk o1 60 3600 7200 10 "$LIVE" "nothing"
# A lane holding its own lock must not put the reaper in a queue behind it: the
# pass runs while wake-loop's flock is held, and reap()'s own `timeout 20` is
# the assertion — a reaper that waited would come back rc=124.
exec 8>"$H/locks/wake-loop.lock"
flock -n 8 || bad "S8 fixture: could not take the lane lock"
LOCKS_BEFORE=$(ls "$H/locks" 2>/dev/null | sort)
OUT=$(reap)
exec 8>&-
[ "$OUT" = "rc=0" ] && ok || bad "S8 the reaper must finish while a lane holds its lock (no queueing): $OUT"
[ "$(ls "$H/locks" 2>/dev/null | sort)" = "$LOCKS_BEFORE" ] && ok \
  || bad "S8 the reaper must take no lock: $(ls "$H/locks")"
[ "$(lines)" = 1 ] && grep -q "o1 overdue" "$ALERTS" && [ ! -s "$T/launched.txt" ] && ok \
  || bad "S8 a lane alive past its deadline is paged once and never relaunched: $(cat "$ALERTS")"
# KILL BY PID, NEVER pkill -f. A live process whose argv reads `merge-conductor`
# must survive a pass that is paging a DEAD merge-conductor heartbeat.
reset
cp /bin/sleep "$T/stub/merge-conductor"
( trap - EXIT; exec "$T/stub/merge-conductor" 300 ) & DECOY=$!
mk merge-conductor 300 1800 7200 7200 "$DEAD" "PR merges fleet-wide"
reap >/dev/null
[ "$(lines)" = 1 ] && kill -0 "$DECOY" 2>/dev/null && ok \
  || bad "S8 a live process named like the dead lane must survive the pass: $(cat "$ALERTS")"
kill "$DECOY" 2>/dev/null; wait "$DECOY" 2>/dev/null

# ── 9. the production entry points ────────────────────────────────────────
# wl_identity <tree> — BH-2637: bin/wake-loop.sh now resolves WHO it is and
# WHAT it owns before any request, and exits 0 with one log line ("owns no fleet
# repo") when it cannot. The same identity tests/lib/wake-claim-stub.sh's
# wcs_identity ships: the REAL box-name.sh / box-for.sh / lib/hub-box.sh, a
# fleet-conf.sh placing one project on the box the loop runs as (BOX_NAME), and
# LANE_REGISTRY rendered from the real catalog. Without it the loop never reaches
# its drain, so the curl observation point below would never fire.
wl_identity() {
  cp "$DIR/bin/box-name.sh" "$DIR/bin/box-for.sh" "$1/bin/"
  cp "$DIR/bin/lib/hub-box.sh" "$1/bin/lib/"
  cat > "$1/bin/fleet-conf.sh" <<'FC'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\n'; exit 0; }
case "$1/$2" in
  project-3/repo) echo example-org/project-3 ;;
  project-3/box)  echo box-project-3-1 ;;
  *) exit 1 ;;
esac
FC
  chmod +x "$1/bin/box-name.sh" "$1/bin/box-for.sh" "$1/bin/fleet-conf.sh"
}
WL_REG=$(rendered_registry) || { echo "rendered_registry failed"; exit 1; }

# 9a. bin/wake-loop.sh, CYCLES=1: the loop declares CYCLES x INTERVAL + 600.
WL="$T/wl"
mkdir -p "$WL/bin/lib" "$WL/env" "$WL/logs" "$WL/locks" "$WL/state" "$WL/flags" "$T/wlbin"
cp "$DIR/bin/wake-loop.sh" "$DIR/bin/jobs-client.sh" "$WL/bin/" 2>/dev/null
mkdir -p "$WL/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$WL/bin/lib/jobs/"
cp "$DIR/bin/lib/heartbeat.sh" "$DIR/bin/lib/revdep-lib.sh" "$DIR/bin/lib/env-path.sh" "$WL/bin/lib/" 2>/dev/null
chmod +x "$WL/bin/"*.sh 2>/dev/null
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$WL/env/global.env"
# TEST-CHANGE BH-2637: the tree gets the loop's identity, or it exits before any request.
wl_identity "$WL"
# curl is the OBSERVATION POINT as well as the stub: the loop reads wakes from
# inside its own body, after hb_tick, so a copy taken here is the heartbeat as
# it existed mid-run. No polling, no sleep, no race.
cat > "$T/wlbin/curl" <<SH
#!/bin/bash
for f in "\$HARNESS"/state/heartbeat/*.json; do [ -f "\$f" ] && cp "\$f" "$T/obs/\$(basename "\$f")"; done
# TEST-CHANGE BH-2637: the first request is now the cursor GET, then the claim;
# one answer is usable JSON for both (no cursor row, nothing claimed).
printf '{"wakes":[],"cursor":null,"scanned_top":0}\n200'
SH
chmod +x "$T/wlbin/curl"
( trap - EXIT; export HARNESS="$WL" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=15 PATH="$T/wlbin:$PATH" \
    BOX_NAME=box-project-3-1 LANE_REGISTRY="$WL_REG"
  exec "$WL/bin/wake-loop.sh" ) &
WLPID=$!
wait "$WLPID"; WLRC=$?
WLSNAP="$T/obs/wake-loop.$WLPID.json"
[ "$WLRC" = 0 ] && ok || bad "S9a bin/wake-loop.sh must still exit 0 (rc=$WLRC)"
[ -s "$WLSNAP" ] \
  && [ "$(jq -r .lane "$WLSNAP")" = wake-loop ] && [ "$(jq -r .pid "$WLSNAP")" = "$WLPID" ] \
  && [ "$(jq -r .interval "$WLSNAP")" = 15 ] \
  && [ "$(jq -r '.deadline - .started_at' "$WLSNAP")" = 615 ] \
  && [ -n "$(jq -r .blocks "$WLSNAP")" ] \
  && [ "$(jq -r .note "$WLSNAP")" = "cycle 1" ] && ok \
  || bad "S9a the wake loop must carry a live heartbeat with its expected-by, blocks and cycle note: $(cat "$WLSNAP" 2>/dev/null)"
[ -z "$(ls "$WL/state/heartbeat" 2>/dev/null)" ] && ok \
  || bad "S9a a clean exit must take the heartbeat with it: $(ls "$WL/state/heartbeat")"

# 9b. bin/wake-loop.sh, CYCLES=0 (supervisord / @reboot): a loop that runs for
# ever declares NO expected-by. The stub kills the lane by the pid IN THE FILE
# NAME, so nothing here waits on a clock.
WL0="$T/wl0"
mkdir -p "$WL0/bin/lib" "$WL0/env" "$WL0/logs" "$WL0/locks" "$WL0/state" "$WL0/flags" "$T/wl0bin"
cp "$DIR/bin/wake-loop.sh" "$DIR/bin/jobs-client.sh" "$WL0/bin/" 2>/dev/null
mkdir -p "$WL0/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$WL0/bin/lib/jobs/"
cp "$DIR/bin/lib/heartbeat.sh" "$DIR/bin/lib/revdep-lib.sh" "$DIR/bin/lib/env-path.sh" "$WL0/bin/lib/" 2>/dev/null
chmod +x "$WL0/bin/"*.sh 2>/dev/null
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$WL0/env/global.env"
# TEST-CHANGE BH-2637: the tree gets the loop's identity, or it exits before any request.
wl_identity "$WL0"
cat > "$T/wl0bin/curl" <<SH
#!/bin/bash
for f in "\$HARNESS"/state/heartbeat/wake-loop.*.json; do
  [ -f "\$f" ] || continue
  cp "\$f" "$T/obs/forever.json"
  P=\$(basename "\$f" .json); P=\${P##*.}
  kill "\$P" 2>/dev/null
done
# TEST-CHANGE BH-2637: usable for the cursor GET (first) and the claim alike.
printf '{"wakes":[],"cursor":null,"scanned_top":0}\n200'
SH
chmod +x "$T/wl0bin/curl"
# `timeout` is the safety net, never the synchronisation: with the heartbeat in
# place the stub kills the loop on its first drain, so this returns at once. A
# build that dropped the hb_start would otherwise hang the suite for ever.
( trap - EXIT; export HARNESS="$WL0" WAKE_LOOP_CYCLES=0 WAKE_LOOP_INTERVAL_S=15 PATH="$T/wl0bin:$PATH" \
    BOX_NAME=box-project-3-1 LANE_REGISTRY="$WL_REG"
  exec timeout 60 "$WL0/bin/wake-loop.sh" ) &
WL0PID=$!
wait "$WL0PID" 2>/dev/null
[ -s "$T/obs/forever.json" ] && [ "$(jq -r .deadline "$T/obs/forever.json")" = 0 ] && ok \
  || bad "S9b a forever loop (WAKE_LOOP_CYCLES=0) must declare no expected-by: $(cat "$T/obs/forever.json" 2>/dev/null)"
# and a killed lane leaves its heartbeat behind — that file is what the reaper reads
[ -n "$(ls "$WL0/state/heartbeat" 2>/dev/null)" ] && ok \
  || bad "S9b a lane killed mid-run must leave its heartbeat file behind"

# 9c. bin/blocked-resolver.sh — the rhythm is DERIVED from BR_FIX_LANE_TIMEOUT.
BR="$T/br"
mkdir -p "$BR/bin/lib" "$BR/env" "$BR/logs" "$BR/locks" "$BR/flags" "$BR/builds" \
         "$BR/state/merge-conductor" "$BR/state/build-queue/tproj" "$T/brbin"
cp "$DIR/bin/blocked-resolver.sh" "$BR/bin/" 2>/dev/null
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$BR" || exit 1
cp "$DIR/bin/lib/heartbeat.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/rebuild-ledger.sh" "$BR/bin/lib/" 2>/dev/null
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$BR/bin/lib/"
mkdir -p "$BR/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$BR/bin/lib/mc/"
chmod +x "$BR/bin/"*.sh 2>/dev/null
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$BR/fleet.conf"
: > "$BR/env/global.env"
# One queue file with no key: inert as a candidate, but it makes the resolver
# call jq — which is this run's observation point, mid-flight and synchronous.
echo '{}' > "$BR/state/build-queue/tproj/x.failed.json"
cat > "$T/brbin/jq" <<SH
#!/bin/bash
for f in "\$HARNESS"/state/heartbeat/blocked-resolver.*.json; do
  [ -f "\$f" ] && [ ! -s "$T/obs/blocked-resolver.json" ] && cp "\$f" "$T/obs/blocked-resolver.json"
done
exec "$JQ_REAL" "\$@"
SH
printf '#!/bin/bash\nexit 0\n' > "$T/brbin/gh"
chmod +x "$T/brbin/jq" "$T/brbin/gh"
( trap - EXIT; export HARNESS="$BR" BR_FIX_LANE_TIMEOUT=900 PATH="$T/brbin:$PATH"
  exec "$BR/bin/blocked-resolver.sh" ) &
BRPID=$!
wait "$BRPID"; BRRC=$?
[ "$BRRC" = 0 ] && ok || bad "S9c bin/blocked-resolver.sh must still exit 0 (rc=$BRRC): $(tail -5 "$BR/logs/blocked-resolver.log" 2>/dev/null)"
[ -s "$T/obs/blocked-resolver.json" ] \
  && [ "$(jq -r .lane "$T/obs/blocked-resolver.json")" = blocked-resolver ] \
  && [ "$(jq -r .pid "$T/obs/blocked-resolver.json")" = "$BRPID" ] \
  && [ "$(jq -r .interval "$T/obs/blocked-resolver.json")" = 300 ] \
  && [ "$(jq -r '.deadline - .started_at' "$T/obs/blocked-resolver.json")" = 900 ] \
  && [ -n "$(jq -r .blocks "$T/obs/blocked-resolver.json")" ] && ok \
  || bad "S9c the resolver's rhythm must be BR_FIX_LANE_TIMEOUT/3 and its expected-by the timeout itself: $(cat "$T/obs/blocked-resolver.json" 2>/dev/null)"
[ -z "$(ls "$BR/state/heartbeat" 2>/dev/null)" ] && ok \
  || bad "S9c a clean exit must take the heartbeat with it: $(ls "$BR/state/heartbeat" 2>/dev/null)"
# THE RHYTHM MUST COVER THE SYNCHRONOUS WORK. A fix round blocks inside the
# per-key subshell with no chance to tick, so the silence threshold (interval x
# HB_STALE_MULT) may not fall before the expected-by the lane declared — driven
# through the real reaper, not arithmetic.
BR_IV=$(jq -r '(.interval//0)' "$T/obs/blocked-resolver.json" 2>/dev/null)
BR_EX=$(jq -r '((.deadline//0) - (.started_at//0))' "$T/obs/blocked-resolver.json" 2>/dev/null)
case "$BR_IV" in ''|*[!0-9]*) BR_IV=0 ;; esac
case "$BR_EX" in ''|*[!0-9]*) BR_EX=0 ;; esac
reset
mk blocked-resolver "$BR_IV" "$BR_EX" "$((BR_EX - 1))" "$((BR_EX - 1))" "$LIVE" "the drain of parked PRs"
reap >/dev/null
[ "$(lines)" = 0 ] && ok \
  || bad "S9c a fix round one second short of its expected-by must not page: $(cat "$ALERTS")"
reset
mk blocked-resolver "$BR_IV" "$BR_EX" "$((BR_EX + 60))" 10 "$LIVE" "the drain of parked PRs"
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q "blocked-resolver overdue" "$ALERTS" && ok \
  || bad "S9c past its expected-by the resolver must still page, as overdue: $(cat "$ALERTS")"

# 9d. bin/merge-conductor.sh — the per-project tick.
MC="$T/mc"
mkdir -p "$MC/bin/lib" "$MC/env" "$MC/logs" "$MC/locks" "$MC/flags" "$MC/builds" \
         "$MC/state/merge-conductor" "$T/mcbin"
cp "$DIR/bin/fleet-conf.sh" "$MC/bin/" 2>/dev/null
# The closure carries bin/lib/mc/*, deployment.sh (BH-4080) and the REST contract (#783) the stub gh answers.
scratch_install_closure bin/merge-conductor.sh "$MC" >/dev/null || { echo "FAIL: scratch_install_closure bin/merge-conductor.sh"; exit 1; }
chmod +x "$MC/bin/"*.sh 2>/dev/null
printf 'tproj example-org/tproj - - 2 box-tproj 100.0.0.9\n' > "$MC/fleet.conf"
: > "$MC/env/global.env"
# gh is the observation point: the conductor reads PR lists from inside
# tick_project, after the hb_tick at the top of it. Every list is empty, so the
# tick does nothing but prove it is alive.
cat > "$T/mcbin/gh" <<SH
#!/bin/bash
for f in "\$HARNESS"/state/heartbeat/merge-conductor.*.json; do
  [ -f "\$f" ] && [ ! -s "$T/obs/merge-conductor.json" ] && cp "\$f" "$T/obs/merge-conductor.json"
done
case "\$*" in *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;; *) echo '[]' ;; esac
exit 0
SH
chmod +x "$T/mcbin/gh"
( trap - EXIT; export HARNESS="$MC" FLEET_CONF="$MC/fleet.conf" MC_MAIN_RED_DETECT=0 PATH="$T/mcbin:$PATH"
  exec "$MC/bin/merge-conductor.sh" ) &
MCPID=$!
wait "$MCPID"; MCRC=$?
[ "$MCRC" = 0 ] && ok || bad "S9d bin/merge-conductor.sh must still exit 0 (rc=$MCRC)"
[ -s "$T/obs/merge-conductor.json" ] \
  && [ "$(jq -r .lane "$T/obs/merge-conductor.json")" = merge-conductor ] \
  && [ "$(jq -r .pid "$T/obs/merge-conductor.json")" = "$MCPID" ] \
  && [ "$(jq -r .interval "$T/obs/merge-conductor.json")" = 300 ] \
  && [ "$(jq -r '.deadline - .started_at' "$T/obs/merge-conductor.json")" = 1800 ] \
  && [ "$(jq -r .note "$T/obs/merge-conductor.json")" = "tick tproj" ] && ok \
  || bad "S9d the conductor must tick its heartbeat per project, from the launch's declaration: $(cat "$T/obs/merge-conductor.json" 2>/dev/null)"
[ -z "$(ls "$MC/state/heartbeat" 2>/dev/null)" ] && ok \
  || bad "S9d a clean exit must take the heartbeat with it: $(ls "$MC/state/heartbeat" 2>/dev/null)"

# ── 10. the cron line is in the file the box actually renders ──────────────
"$DIR/bin/render-crontab.sh" hub > "$T/rendered.cron" 2>"$T/render.err"
# BH-1247: cron/hub.cron is GENERATED and not committed, so "the committed file
# IS the render" has no committed side left to compare. What remains provable —
# and is what that assertion was standing in for — is that the fragments render
# to the SAME BYTES twice, so the crontab a box installs is not a function of
# which machine rendered it.
diff -q "$T/rendered.cron" "$(rendered_cron hub)" >/dev/null 2>&1 && ok \
  || bad "S10 cron/hub.cron does not render to the same bytes twice: $(diff "$T/rendered.cron" "$(rendered_cron hub)" | head -5)"
grep -q '^\*/5 \* \* \* \* /root/harness/bin/heartbeat-reaper.sh' "$(rendered_cron hub)" && ok \
  || bad "S10 the reaper must be on the hub cron every 5 minutes"

# ── 11. the zero-row state, and the garbage collector ─────────────────────
reset
OUT=$(reap)
[ "$OUT" = "rc=0" ] && [ "$(lines)" = 0 ] && [ ! -s "$H/logs/heartbeat-reaper.log" ] && ok \
  || bad "S11 an empty state/heartbeat is a quiet rc 0: $OUT :: $(cat "$H/logs/heartbeat-reaper.log" 2>/dev/null)"
scratch_rm "$HBD" >/dev/null 2>&1
OUT=$(reap)
[ "$OUT" = "rc=0" ] && ok || bad "S11 no state/heartbeat directory at all is also a quiet rc 0: $OUT"
mkdir -p "$HBD"
reset
mk g1 60 600 200 181 "$LIVE" "x"
reap >/dev/null
reap "HB_NOW=$((NOW + 90000))" >/dev/null
[ ! -e "$(hbf g1 "$LIVE")" ] && grep -q "gc:" "$H/logs/heartbeat-reaper.log" && ok \
  || bad "S11 a marked file older than HB_STALE_GC_S must be collected"
reset
mk g2 60 600 200 181 "$LIVE" "x"
reap >/dev/null
reap "HB_NOW=$((NOW + 100))" >/dev/null
[ -s "$(hbf g2 "$LIVE")" ] && ok || bad "S11 a freshly marked file must be kept, not collected"

# ── 12. the detector itself failing must be loud, never quiet ─────────────
# lane-alert.sh gone: the line still lands, because "the pager is missing" must
# not become "the lane is fine".
reset
mk l1 60 600 200 181 "$LIVE" "x"
mv "$H/bin/lane-alert.sh" "$T/lane-alert.parked"
reap >/dev/null
[ "$(lines)" = 1 ] && grep -q "l1 silent" "$ALERTS" && grep -q "lane-alert.sh missing" "$H/logs/heartbeat-reaper.log" && ok \
  || bad "S12 with no lane-alert.sh the reaper must write the line itself and say so: $(cat "$ALERTS")"
mv "$T/lane-alert.parked" "$H/bin/lane-alert.sh"
# the lib gone: rc 2 and one line saying nothing was checked
reset
mv "$H/bin/lib/heartbeat.sh" "$T/heartbeat.parked"
OUT=$(reap)
[ "$OUT" = "rc=2" ] && grep -q "NO lane liveness check ran" "$ALERTS" && ok \
  || bad "S12 with no bin/lib/heartbeat.sh the reaper must page and exit 2: $OUT :: $(cat "$ALERTS")"
mv "$T/heartbeat.parked" "$H/bin/lib/heartbeat.sh"

# ── 13. N ticks of ONE lane from ONE process must not erase the declaration ─
# The shape the hub actually runs: merge-conductor forks tick_project per project
# (11 today) and hb_tick is its first line, so every fork writes the SAME
# merge-conductor.<pid>.json at the same moment — $$ is what they share, which is
# exactly why the file is keyed on it. A temp name built from $$ would be shared
# too: one writer's `>` truncation lands inside another's read, that writer falls
# through to a whole file at the defaults, and `blocks` and the 30-minute
# expected-by the launch declared become "" and now+60m. The reaper would then
# page a dead conductor as "blocks: unknown" — the one thing the alert exists to
# say. Nothing is hand-written here: hb_start declares, the forks tick.
reset
LOST=""; ROUND=0
while [ "$ROUND" -lt 10 ]; do
  scratch_rm "$HBD" >/dev/null 2>&1; mkdir -p "$HBD"
  HB_PID="$LIVE" HB_NOW=$((NOW - 300)) hb_start conductor 300 1800 "PR merges fleet-wide"
  W=0; WPIDS=""
  while [ "$W" -lt 6 ]; do
    ( trap - EXIT; HB_PID="$LIVE" HB_NOW=$NOW hb_tick conductor "tick p$W" ) & WPIDS="$WPIDS $!"
    W=$((W + 1))
  done
  # Only these pids: a bare `wait` would sit on $LIVE's sleep for five minutes.
  for P in $WPIDS; do wait "$P" 2>/dev/null; done
  FJ=$(hbf conductor "$LIVE")
  B=$(jq -r '.blocks' "$FJ" 2>/dev/null); EX=$(jq -r '.deadline - .started_at' "$FJ" 2>/dev/null)
  IV=$(jq -r '.interval' "$FJ" 2>/dev/null); ST=$(jq -r '.started_at' "$FJ" 2>/dev/null)
  { [ "$B" = "PR merges fleet-wide" ] && [ "$EX" = 1800 ] && [ "$IV" = 300 ] && [ "$ST" = "$((NOW - 300))" ]; } \
    || LOST="$LOST [round $ROUND: blocks=$B expected-by=+$EX interval=$IV started_at=$ST]"
  ROUND=$((ROUND + 1))
done
[ -z "$LOST" ] && ok \
  || bad "S13 parallel hb_tick calls on one lane must each keep the launch declaration:$LOST"
# and the writers clean up after themselves: a leftover .tmp in the state dir is a
# second name the */5 reader would try to parse as a lane.
[ "$(ls "$HBD" 2>/dev/null)" = "conductor.$LIVE.json" ] && ok \
  || bad "S13 parallel ticks must leave one file and no temp behind: $(ls "$HBD" 2>/dev/null | tr '\n' ' ')"

# ── 14. the knobs are read from env/global.env, because cron passes none ───
# The hub cron line is `/root/harness/bin/heartbeat-reaper.sh` and nothing else.
# A knob that only the environment can deliver is a knob nobody on this box can
# turn — a hardcoded assumption with documentation attached.
reset
printf 'TELEGRAM_BOT_TOKEN=notasecret\nHB_STALE_MULT=10\n' > "$H/env/global.env"
mk k1 300 7200 1000 901 "$LIVE" "x"
reap >/dev/null
[ "$(lines)" = 0 ] && ok \
  || bad "S14 HB_STALE_MULT must be read out of env/global.env: $(cat "$ALERTS")"
# the environment still wins over the file — an operator override, and this
# suite's own seam, both arrive that way
reset
mk k1 300 7200 1000 901 "$LIVE" "x"
reap HB_STALE_MULT=2 >/dev/null
[ "$(lines)" = 1 ] && ok \
  || bad "S14 the environment must win over env/global.env: $(cat "$ALERTS")"
# a typo is not a setting: only ^HB_<NAME>=<digits>$ is taken, and anything else
# leaves the documented code default standing
reset
printf 'HB_STALE_MULT=abc\n' > "$H/env/global.env"
mk k1 300 7200 1000 901 "$LIVE" "x"
reap >/dev/null
[ "$(lines)" = 1 ] && ok \
  || bad "S14 a non-numeric HB_ value must be ignored, leaving the default of 3: $(cat "$ALERTS")"
# WHY IT IS A SED EXTRACT AND NOT `set -a; . global.env`: this script nohups a
# lane's restart command, and a sourced global.env would hand that child every
# secret in the file.
reset
printf 'TELEGRAM_BOT_TOKEN=notasecret\nHARNESS_SECRET=alsonotasecret\n' > "$H/env/global.env"
scratch_rm "$T/stub.env" >/dev/null 2>&1
mk k2 60 600 100 10 "$DEAD" "the drain" "$T/stub/dumpenv.sh"
reap >/dev/null
wait_file "$T/stub.env"
[ -s "$T/stub.env" ] && ok \
  || bad "S14 fixture: the declared restart must have run and dumped its environment"
[ "$(grep -c 'notasecret' "$T/stub.env" 2>/dev/null)" = 0 ] && ok \
  || bad "S14 a relaunched lane must inherit no secret from global.env: $(grep -n 'notasecret' "$T/stub.env")"
: > "$H/env/global.env"
# …AND NOT FROM THIS SCRIPT'S OWN ENVIRONMENT EITHER (BH-1165 review). Wiring
# this lane to the control plane put a `. bin/lib/lane-gate.sh` header at the
# top, and the gate reaches the pause_flags row through bin/jobs-client.sh,
# which EXPORTS HARNESS_SECRET. So the secret the sed extract above is careful
# never to source arrives anyway — in the reaper's own environment — and a bare
# `nohup` hands it straight to the relaunched child. The restart strips it; the
# lane reads its own, the way cron's copy of it does.
reset
scratch_rm "$T/stub.env" >/dev/null 2>&1
mk k3 60 600 100 10 "$DEAD" "the drain" "$T/stub/dumpenv.sh"
reap HARNESS_SECRET=alsonotasecret >/dev/null
wait_file "$T/stub.env"
[ -s "$T/stub.env" ] && ok \
  || bad "S14 fixture: the declared restart must have run and dumped its environment"
[ "$(grep -c 'alsonotasecret' "$T/stub.env" 2>/dev/null)" = 0 ] && ok \
  || bad "S14 a relaunched lane inherited the fleet bearer the lane header exported: $(grep -n 'alsonotasecret' "$T/stub.env")"

# ── 15. a collapse must not be followed by per-lane pages one tick later ───
# The lanes inside a mass line are MARKED, so they drop out of the next pass. An
# unreadable heartbeat is never marked (it is evidence, and it is never
# rewritten), so it is re-found alone on the next pass, below the threshold, and
# paged under its own id — a second line about an incident that was already
# collapsed into one. Registering every member id as an open condition is what
# makes "one line" true five minutes later as well.
reset
mk s1 60 3600 100 10 "$DEAD" "the drain"
mk s2 60 3600 100 10 "$DEAD" "the drain"
printf '{nope' > "$HBD/bad.9.json"
reap HB_MASS_STALE_N=3 >/dev/null
[ "$(lines)" = 1 ] && grep -q "3 lanes stale at once" "$ALERTS" && ok \
  || bad "S15 two dead lanes and one corrupt file must collapse to one line: $(cat "$ALERTS")"
[ -s "$H/state/alerts/hb-bad.9-unreadable.json" ] && ok \
  || bad "S15 every id inside the collapse must be opened as a condition: $(ls "$H/state/alerts" 2>/dev/null | tr '\n' ' ')"
BEFORE=$(lines); BEATS=$(beats)
reap HB_MASS_STALE_N=3 >/dev/null
[ "$(lines)" = "$BEFORE" ] && [ "$(beats)" = "$BEATS" ] && ok \
  || bad "S15 the pass after a collapse must add no line and no beat: $(cat "$ALERTS")"
# the control: below the threshold the same three findings are three lines, so
# the assertion above is about the collapse and not about a reaper gone quiet
reset
mk s1 60 3600 100 10 "$DEAD" "the drain"
mk s2 60 3600 100 10 "$DEAD" "the drain"
printf '{nope' > "$HBD/bad.9.json"
reap HB_MASS_STALE_N=9 >/dev/null
[ "$(lines)" = 3 ] && ok \
  || bad "S15 with the threshold above the count, three findings are three lines: $(cat "$ALERTS")"

echo "heartbeat-reaper (BH-638): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
