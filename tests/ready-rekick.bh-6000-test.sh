#!/bin/bash
# tests/ready-rekick.bh-6000-test.sh — BH-6000 part 3: a READY row past its
# TTL is re-kicked ONCE per (PR, head) with a keyed conductor run, unless the
# conductor has recorded a hold for that head.
#
# THE INCIDENT (2026-10-11): #5982 logged "stuck in READY past its TTL — no
# deterministic re-kick for this state" on every tick. The STUCK page went out
# once (mc_stuck_check) and nothing moved the PR.
#
# stuck_rekick and mc_ready_rekick are extracted VERBATIM from
# bin/lib/mc/classify.sh and driven with the conductor's edges stubbed: the
# attempt ledger is a file, kw_conductor records its launches.
#   RK1 no hold: one keyed run launched, the attempt stamped, the log says so
#   RK2 the same head again: no second launch
#   RK3 a new head: launched again (once for that head)
#   RK4 a recorded hold for the head: no launch, the hold is named; RK4b/c a
#       hold this tick already knows (a red main, an unread diff) before the
#       READY arm has written its note
#   RK5 observe mode: no launch and no stamp
#   RK6 the keyed wake refuses: logged, the stamp stays (never repeated)
#   RK7 other states keep their arms (QUEUED is still the republish arm)
#   RK8 the re-kick launches its keyed run with KW_PR_LOCK_WAIT_S = this
#       worker's deadline, because the launcher still holds the PR lock
#       (lead review lr-6015)
#   RK9 mc_pr_lock_take (bin/lib/mc/locks.sh): with MC_PR_LOCK_WAIT_S it waits
#       for a lock another process drops; without it, flock -n as before
#   RK10 kw_conductor (bin/lib/keyed-wake.sh) hands KW_PR_LOCK_WAIT_S to the
#       launched conductor as MC_PR_LOCK_WAIT_S, and nothing when it is unset
#   RK11 only a HOLD note stops the re-kick (Fable review of 9fc9454d1, F1):
#       with the REAL mc_ready_why_last and mc_ready_why_kind, a
#       prequeue-pending or a worker-locked note on the head gets one re-kick;
#       a main-red note does not; with no note, a MERGE_HELD log line still
#       stops it
#   RK12 mc_worker_bounded (bin/lib/fanin.sh) adds MC_PR_LOCK_WAIT_S to the
#       worker deadline, also over the backstop cap, so the lock wait never
#       eats the work's own time (Fable review of 9fc9454d1, F2)
# Run from anywhere: tests/ready-rekick.bh-6000-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

CL="$DIR/bin/lib/mc/classify.sh"
fn() { awk -v n="$1" '!f && $0 ~ "^"n"\\(\\)[[:space:]]*\\{" {f=1; print; next} f {print} f && /^}/ {exit}' "$CL"; }
for f in stuck_rekick mc_ready_rekick; do
  fn "$f" >> "$T/fns.sh"
  grep -qE "^$f\(\)[[:space:]]*\{" "$T/fns.sh" && ok || bad "could not extract $f from bin/lib/mc/classify.sh"
done
H1=1111111111111111111111111111111111111111; H2=2222222222222222222222222222222222222222
KEY="example-org/demo-os#41"; URL="https://github.com/example-org/demo-os/pull/41"

# kick <state> <head> [VAR=val...] — one stuck_rekick call for $KEY.
kick() {
  local st="$1" head="$2"; shift 2
  : > "$T/log"
  ( cd "$T" && env T="$T" "$@" bash -c '
      set -uo pipefail
      MC_H="$T"
      mc_log() { printf "%s\n" "$*" >> "$T/log"; }
      mc_attempt_has() { grep -qxF "$1" "$T/attempts" 2>/dev/null; }
      mc_attempt_put() { printf "%s\n" "$1" >> "$T/attempts"; }
      mc_ready_why_last() { [ -s "$T/held.$2" ] && cat "$T/held.$2"; return 0; }
      mc_ready_why_kind() { return 0; }   # no note kind: RK4 reads the held.<head> stub above (RK11 runs the real readers)
      kw_conductor() { printf "%s %s %s\n" "$1" "$2" "$3" >> "$T/kw"; printf "%s\n" "${KW_PR_LOCK_WAIT_S-unset}" >> "$T/kwwait"; return "$(cat "$T/kw.rc" 2>/dev/null || echo 0)"; }
      mc_vs_ttl_republish() { printf "republish %s\n" "$1" >> "$T/log"; }
      . "$T/fns.sh"
      stuck_rekick "$1" "$2" "-" example-org/demo-os 41 "$3" "$4" CLEAN MERGEABLE main main success APPROVE "$4" mergify
    ' _ "$KEY" "$st" "$URL" "$head" )
}
: > "$T/attempts"; : > "$T/kw"; rm -f "$T"/held.* "$T/kw.rc"

# RK1. no hold: one keyed run
kick READY "$H1" ACTIONS=1
[ "$(grep -c . "$T/kw")" = 1 ] && grep -q "^example-org/demo-os 41 READY past its TTL on ${H1:0:8}" "$T/kw" && ok || bad "RK1 one keyed run for the PR (kw: $(cat "$T/kw"))"
grep -qxF "readykick $KEY $H1" "$T/attempts" && ok || bad "RK1 the re-kick is stamped for this head: $(cat "$T/attempts")"
grep -q 're-kicked once: a keyed conductor run' "$T/log" && ok || bad "RK1 the log says so: $(cat "$T/log")"

# RK2. the same head again: no second launch
kick READY "$H1" ACTIONS=1
[ "$(grep -c . "$T/kw")" = 1 ] && ok || bad "RK2 one re-kick per head (kw: $(cat "$T/kw"))"
grep -q 'has already had its one re-kick' "$T/log" && ok || bad "RK2 the log says the head had its re-kick: $(cat "$T/log")"

# RK3. a new head: launched once for it
kick READY "$H2" ACTIONS=1
[ "$(grep -c . "$T/kw")" = 2 ] && grep -q "${H2:0:8}" "$T/kw" && ok || bad "RK3 a new head gets its own re-kick (kw: $(cat "$T/kw"))"

# RK4. a recorded hold for the head: no launch
: > "$T/attempts"; : > "$T/kw"
printf 'not merged this tick: main is red (flags/main-red-example-org-demo-os)' > "$T/held.$H1"
kick READY "$H1" ACTIONS=1
[ ! -s "$T/kw" ] && ok || bad "RK4 a head the conductor holds must not be re-kicked (kw: $(cat "$T/kw"))"
grep -q 'holds it on purpose (not merged this tick: main is red' "$T/log" && ok || bad "RK4 the hold is named: $(cat "$T/log")"
[ ! -s "$T/attempts" ] && ok || bad "RK4 no stamp for a held head"
rm -f "$T/held.$H1"

# RK4b. a hold this tick already knows, before any note exists: a red main
kick READY "$H1" ACTIONS=1 MAIN_RED=main-red-example-org-demo-os
[ ! -s "$T/kw" ] && [ ! -s "$T/attempts" ] && ok || bad "RK4b a red main must not be re-kicked (kw: $(cat "$T/kw"))"
grep -q 'holds it on purpose (main is red' "$T/log" && ok || bad "RK4b the red main is named: $(cat "$T/log")"
# RK4c. ...and an unread diff
kick READY "$H1" ACTIONS=1 DIFF_UNREAD=1 DIFF_WHY="iron-law: 1 file(s) not scanned"
[ ! -s "$T/kw" ] && ok || bad "RK4c an unread diff must not be re-kicked (kw: $(cat "$T/kw"))"
grep -q 'holds it on purpose (iron-law: 1 file(s) not scanned)' "$T/log" && ok || bad "RK4c the unread diff is named: $(cat "$T/log")"

# RK5. observe mode: no launch, no stamp
kick READY "$H1" ACTIONS=0
[ ! -s "$T/kw" ] && [ ! -s "$T/attempts" ] && ok || bad "RK5 observe mode writes nothing (kw: $(cat "$T/kw"), attempts: $(cat "$T/attempts"))"
grep -q 'would re-kick' "$T/log" && ok || bad "RK5 a WOULD line: $(cat "$T/log")"

# RK6. the keyed wake refuses: stamp kept, logged
echo 1 > "$T/kw.rc"
kick READY "$H1" ACTIONS=1
grep -qxF "readykick $KEY $H1" "$T/attempts" && ok || bad "RK6 the stamp stays when the launch is refused"
grep -q 'could not launch a keyed run' "$T/log" && ok || bad "RK6 the refusal is logged: $(cat "$T/log")"
rm -f "$T/kw.rc"

# RK7. other states keep their arms
: > "$T/kw"; kick QUEUED "$H1" ACTIONS=1
grep -q "^republish $KEY" "$T/log" && [ ! -s "$T/kw" ] && ok || bad "RK7 QUEUED still goes to its republish arm: $(cat "$T/log")"
kick STACKED_WAIT "$H1" ACTIONS=1
grep -q 'no deterministic re-kick for this state' "$T/log" && [ ! -s "$T/kw" ] && ok || bad "RK7 STACKED_WAIT keeps no re-kick: $(cat "$T/log")"

# RK8. the launch carries the lock wait (lead review lr-6015)
: > "$T/attempts"; : > "$T/kw"; : > "$T/kwwait"; rm -f "$T"/held.* "$T/kw.rc"
kick READY "$H1" ACTIONS=1 MC_WORKER_DEADLINE_S=600
[ "$(cat "$T/kwwait")" = 600 ] && ok || bad "RK8 the keyed run waits up to the worker deadline for the launcher's lock (got: $(cat "$T/kwwait"))"
: > "$T/attempts"; : > "$T/kwwait"
kick READY "$H1" ACTIONS=1
[ "$(cat "$T/kwwait")" = 180 ] && ok || bad "RK8 with no deadline set, the default 180 s (got: $(cat "$T/kwwait"))"

# RK9. mc_pr_lock_take
awk '!f && /^mc_pr_lock_take\(\)[[:space:]]*\{/ {f=1; print; next} f {print} f && /^}/ {exit}' "$DIR/bin/lib/mc/locks.sh" > "$T/lock.sh"
grep -q '^mc_pr_lock_take() {' "$T/lock.sh" && ok || bad "could not extract mc_pr_lock_take"
LK="$T/pr.lock"
( exec 8>"$LK"; flock 8; exec sleep 2 ) & HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$LK" true && sleep 0.1 || break; done
( . "$T/lock.sh"; exec 9>"$LK"; unset MC_PR_LOCK_WAIT_S; mc_pr_lock_take ) && bad "RK9 with no wait, a held lock is refused at once" || ok
( . "$T/lock.sh"; exec 9>"$LK"; MC_PR_LOCK_WAIT_S=10 mc_pr_lock_take ) && ok || bad "RK9 with MC_PR_LOCK_WAIT_S the run takes the lock once the holder drops it"
wait "$HOLDER" 2>/dev/null

# RK10. kw_conductor hands the wait to the launched run
KWH="$T/kwh"; mkdir -p "$KWH/bin"
printf '#!/bin/bash\nprintf "%%s|%%s\\n" "${MC_ONLY_PR:-}" "${MC_PR_LOCK_WAIT_S-unset}" >> "%s/launched"\n' "$T" > "$KWH/bin/merge-conductor.sh"
chmod +x "$KWH/bin/merge-conductor.sh"
kwl() { # kwl [VAR=val...] — one kw_conductor launch, waited for
  : > "$T/launched"
  ( env MC_H="$KWH" MC_KEYED_WAKE_MIN_S=0 "$@" bash -c '. "'"$DIR"'/bin/lib/keyed-wake.sh"; kw_conductor example-org/demo-os 41 test' )
  local n=0; while [ ! -s "$T/launched" ] && [ "$n" -lt 40 ]; do sleep 0.1; n=$((n + 1)); done
}
kwl KW_PR_LOCK_WAIT_S=600
[ "$(cat "$T/launched")" = "example-org/demo-os#41|600" ] && ok || bad "RK10 the launched run gets MC_PR_LOCK_WAIT_S=600 (got: $(cat "$T/launched"))"
scratch_rm "$KWH/state"; kwl
[ "$(cat "$T/launched")" = "example-org/demo-os#41|" ] && ok || bad "RK10 with no caller wait, the launched run gets an empty MC_PR_LOCK_WAIT_S, which is flock -n (got: $(cat "$T/launched"))"

# RK11. only a hold note stops the re-kick (the REAL note readers)
CL_NOTES=$(fn mc_ready_why_last; fn mc_ready_why_kind)
grep -q '^mc_ready_why_kind() {' <<<"$CL_NOTES" && grep -q '^mc_ready_why_last() {' <<<"$CL_NOTES" \
  && ok || bad "RK11 could not extract mc_ready_why_last and mc_ready_why_kind"
printf '%s\n' "$CL_NOTES" > "$T/notes.sh"; cat "$T/fns.sh" >> "$T/notes.sh"
NOTE="$T/st/ready-why/example-org_demo-os_41"
# kick11 [VAR=val...] — one READY stuck_rekick on $H1 with the real readers.
kick11() {
  : > "$T/log"
  ( cd "$T" && env T="$T" "$@" bash -c '
      set -uo pipefail
      MC_H="$T"; MC_STATE_DIR="$T/st"; MC_LOG="$T/mclog"
      mc_handoff_id() { printf "%s" "${1//[^A-Za-z0-9-]/_}"; }
      mc_log() { printf "%s\n" "$*" >> "$T/log"; }
      mc_attempt_has() { grep -qxF "$1" "$T/attempts" 2>/dev/null; }
      mc_attempt_put() { printf "%s\n" "$1" >> "$T/attempts"; }
      kw_conductor() { printf "%s %s %s\n" "$1" "$2" "$3" >> "$T/kw"; return 0; }
      . "$T/notes.sh"
      stuck_rekick "$1" READY "-" example-org/demo-os 41 "$2" "$3" CLEAN MERGEABLE main main success APPROVE "$3" mergify
    ' _ "$KEY" "$URL" "$H1" )
}
note() { mkdir -p "${NOTE%/*}"; printf '1791800000\t%s\t%s\t%s\n' "$1" "$2" "$3" > "$NOTE"; }
for k in prequeue-pending worker-locked queue-held merge-lock; do
  : > "$T/attempts"; : > "$T/kw"; : > "$T/mclog"
  note "$H1" "$k" "a $k note: what one tick did"
  kick11 ACTIONS=1
  [ "$(grep -c . "$T/kw")" = 1 ] && ok || bad "RK11 a $k note is not a hold: one re-kick (kw: $(cat "$T/kw"); log: $(cat "$T/log"))"
done
: > "$T/attempts"; : > "$T/kw"
note "$H1" main-red "HELD by the main-red freeze: main is red"
kick11 ACTIONS=1
[ ! -s "$T/kw" ] && grep -q 'holds it on purpose (HELD by the main-red freeze' "$T/log" \
  && ok || bad "RK11 a main-red note is a hold: no re-kick, named (kw: $(cat "$T/kw"); log: $(cat "$T/log"))"
: > "$T/attempts"; : > "$T/kw"
note "$H2" main-red "a hold on an older head"
kick11 ACTIONS=1
[ "$(grep -c . "$T/kw")" = 1 ] && ok || bad "RK11 a hold note on another head does not hold this head (kw: $(cat "$T/kw"))"
: > "$T/attempts"; : > "$T/kw"; scratch_rm "$T/st"
printf '%s MERGE_HELD on %s: queue busy\n' "$KEY" "${H1:0:8}" > "$T/mclog"
kick11 ACTIONS=1
[ ! -s "$T/kw" ] && grep -q 'holds it on purpose' "$T/log" && ok || bad "RK11 with no note, a MERGE_HELD log line for the head still holds it (kw: $(cat "$T/kw"); log: $(cat "$T/log"))"

# RK12. the lock wait is added to the worker deadline
FAN="$DIR/bin/lib/fanin.sh"
awk '!f && /^mc_worker_bounded\(\)[[:space:]]*\{/ {f=1; print; next} f {print} f && /^}/ {exit}' "$FAN" > "$T/wb.sh"
grep -q '^mc_worker_bounded() {' "$T/wb.sh" && ok || bad "could not extract mc_worker_bounded"
# wb [VAR=val...] -> the deadline the watchdog armed, or "none". BH-6351: the
# watchdog polls the step trail, so the deadline is read off
# MC_WORKER_DEADLINE_AT (the epoch of the kill) against a fixed clock; pr_worker
# records it and returns, so nothing waits on a clock.
wb() {
  : > "$T/slept"
  ( env T="$T" "$@" bash -c '
      _mc_deadline_mark() { printf "%s/mark/x" "$T"; }
      _mc_kill_tree() { kill -"$1" "$2" 2>/dev/null; return 0; }
      date() { echo 1000; }
      sleep() { command sleep 0.05; }
      mc_step_read() { :; }; mc_step_close() { :; }
      pr_worker() { [ -n "${MC_WORKER_DEADLINE_AT:-}" ] && printf "%s\n" "$((MC_WORKER_DEADLINE_AT - 1000))" >> "$T/slept"; return 0; }
      . "$T/wb.sh"
      mc_worker_bounded "7	row"
    ' )
  if [ -s "$T/slept" ]; then head -1 "$T/slept"; else echo none; fi
}
[ "$(wb MC_WORKER_DEADLINE_S=40)" = 40 ] && ok || bad "RK12 with no lock wait the deadline is unchanged (got: $(wb MC_WORKER_DEADLINE_S=40))"
[ "$(wb MC_WORKER_DEADLINE_S=40 MC_PR_LOCK_WAIT_S=180)" = 220 ] && ok || bad "RK12 the lock wait is added to the deadline (got: $(wb MC_WORKER_DEADLINE_S=40 MC_PR_LOCK_WAIT_S=180))"
[ "$(wb MC_WORKER_DEADLINE_S=0 MC_WORKER_DEADLINE_CAP_S=75 MC_PR_LOCK_WAIT_S=180)" = 255 ] && ok || bad "RK12 the wait is added over the backstop cap too (got: $(wb MC_WORKER_DEADLINE_S=0 MC_WORKER_DEADLINE_CAP_S=75 MC_PR_LOCK_WAIT_S=180))"
[ "$(wb NOWD=1 MC_WORKER_DEADLINE_S=0 MC_PR_LOCK_WAIT_S=180)" = none ] && ok || bad "RK12 no deadline stays no deadline (got: $(wb NOWD=1 MC_WORKER_DEADLINE_S=0 MC_PR_LOCK_WAIT_S=180))"

echo "ready-rekick.bh-6000: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
