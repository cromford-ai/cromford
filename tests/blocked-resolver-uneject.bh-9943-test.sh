#!/bin/bash
# tests/blocked-resolver-uneject.bh-9943-test.sh — BH-9943: a resolver re-plan
# of a ticket in lifecycle phase `ejected` moves the phase to `pr_open` in the
# same step, so the pool's spawn gate (bin/lib/plan-blocked-stop.sh,
# pbs_stop_check) lets the fresh build start.
#
# WHAT HAPPENED (hub, 2026-11-23). The stale-replan rung said `stale park
# RE-PLANNED — BH-9453 enqueued fresh` and every pool pass then said `skipping
# BH-9453: phase ejected ... — not spawned`. Four queue rows waited 6 to 12
# days until a person moved the phase by hand.
#
#   U1-U14  br_phase_uneject (bin/blocked-resolver.d/bh-9943-phase-uneject.sh) sourced alone: the
#           decision table (move or not, rc, PU_WHY, POST count)
#   S1-S3   the REAL bin/blocked-resolver.sh, the stale-replan rung, on the
#           shared fixture against a stub jobs worker whose transition rules
#           are the worker's own (worker/jobs/src/lib/lifecycle.js lifecycleCheck)
#   R1      the rebuild-fresh rung, the same enqueue
#   G1-G8   sqg_gate (bin/lib/stuckqueue-gate.sh) names `phase-ejected`, and the
#           REAL pipeline-health stuck-queue block prints it
# Run: HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-uneject.bh-9943-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq   >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v node >/dev/null || { echo "node missing — skipping"; exit 0; }
command -v git  >/dev/null || { echo "git missing — skipping"; exit 0; }
LCJS="$DIR/worker/jobs/src/lib/lifecycle.js"
[ -r "$LCJS" ] || { echo "FAIL: worker/jobs/src/lib/lifecycle.js missing"; exit 1; }

# ============================================================================
# THE STUB JOBS WORKER. One file, sourced by the test shell AND by the stub
# bin/jobs-client.sh the resolver sources, so both see one state:
#   $J/phase       the ticket's phase (absent = no build_queue row, `-` = NULL)
#   $J/calls.txt   every _jobs_req call, one line: METHOD PATH BODY
#   $J/queue.txt   every queue row queue_put took
#   $J/qput        queue_put's answer (default queued)
#   $J/get-rc      forces the queue read's rc
#   $J/trans-rc + $J/trans-body  force the transition answer
# A transition is judged by lifecycleCheck from worker/jobs/src/lib/lifecycle.js
# (node), so the stub cannot drift from the worker's rules.
# ============================================================================
J="$T/jobs"; mkdir -p "$J"
cat > "$T/jobs-stub.sh" <<EOF
queue_put() {
  local a; a=\$(cat "$J/qput" 2>/dev/null || echo queued)
  [ "\$a" = queued ] && printf '%s\n' "\$*" >> "$J/queue.txt"
  echo "\$a"
}
queue_done() { return 0; }
queue_list() { return 1; }
_jobs_req() {
  printf '%s %s %s\n' "\$1" "\$2" "\${3:-}" >> "$J/calls.txt"
  local from to actor key cur chk
  case "\$1 \$2" in
    "GET /api/queue?"*)
      [ -s "$J/get-rc" ] && return "\$(cat "$J/get-rc")"
      if [ ! -e "$J/phase" ]; then printf '{"queue":[]}'; return 0; fi
      key=\$(printf '%s' "\$2" | sed -nE 's/.*[?&]key=([^&]*).*/\1/p')
      cur=\$(cat "$J/phase")
      jq -nc --arg k "\$key" --arg ph "\$cur" \
        '{queue:[{project:"tproj",ticket_key:\$k,status:"queued",phase:(if \$ph == "-" then null else \$ph end),phase_at:"2026-11-12T18:58:23Z",question:null}]}'
      return 0 ;;
    "POST /api/lifecycle/transition")
      if [ -s "$J/trans-rc" ]; then cat "$J/trans-body" 2>/dev/null; return "\$(cat "$J/trans-rc")"; fi
      [ -e "$J/phase" ] || { printf '{"error":"not_found"}'; return 2; }
      cur=\$(cat "$J/phase"); from="\$cur"; [ "\$from" = - ] && from=""
      to=\$(jq -r .to_phase <<<"\${3:-}"); actor=\$(jq -r .actor <<<"\${3:-}")
      chk=\$(node --input-type=module -e 'const {lifecycleCheck}=await import(process.argv[1]); console.log(JSON.stringify(lifecycleCheck(process.argv[2],process.argv[3],process.argv[4])))' \
        "file://$LCJS" "\$from" "\$to" "\$actor")
      if [ "\$(jq -r .ok <<<"\$chk")" = true ]; then
        printf '%s' "\$to" > "$J/phase"
        jq -nc --arg f "\$from" --arg t "\$to" '{ok:true,from:\$f,to:\$t}'; return 0
      fi
      jq -nc --arg e "\$(jq -r .error <<<"\$chk")" --arg c "\$cur" --arg t "\$to" '{error:\$e,current:\$c,to:\$t}'
      return 9 ;;
  esac
  return 1
}
EOF
JRESET() { rm -f "$J/phase" "$J/get-rc" "$J/trans-rc" "$J/trans-body" "$J/qput"; : > "$J/calls.txt"; : > "$J/queue.txt"; }
POSTS() { grep -c '^POST /api/lifecycle/transition' "$J/calls.txt" 2>/dev/null || true; }
PHASE() { cat "$J/phase" 2>/dev/null || echo none; }

# ============================================================================
# U. br_phase_uneject, sourced alone on a scratch tree
# ============================================================================
UH="$T/uh"; mkdir -p "$UH"
HAVE_LIB=0
if [ -f "$DIR/bin/blocked-resolver.d/bh-9943-phase-uneject.sh" ]; then
  ( cd "$DIR" && scratch_install_closure bin/blocked-resolver.d/bh-9943-phase-uneject.sh "$UH" ) >/dev/null && HAVE_LIB=1
fi
[ "$HAVE_LIB" = 1 ] && ok || bad "U0 bin/blocked-resolver.d/bh-9943-phase-uneject.sh is missing or its closure did not install"
# UJ <key> [nojobs] — prints `rc=<rc>|why=<PU_WHY>`; the say lines go to $T/usay.txt.
UJ() { (
  say() { printf '%s\n' "$*" >> "$T/usay.txt"; }
  # shellcheck source=/dev/null
  . "$T/jobs-stub.sh"
  [ "${2:-}" = nojobs ] && unset -f _jobs_req
  # shellcheck source=bin/blocked-resolver.d/bh-9943-phase-uneject.sh
  . "$UH/bin/blocked-resolver.d/bh-9943-phase-uneject.sh" 2>/dev/null || { echo "rc=nolib|why="; exit 0; }
  br_phase_uneject tproj "$1" "stale-replan: no head or verdict change for 5d"; rc=$?
  echo "rc=$rc|why=${PU_WHY:-}"
) }
UCASE() { : > "$T/usay.txt"; JRESET; }
SAYN() { grep -c -- "$1" "$T/usay.txt" 2>/dev/null || true; }

# U1 a lane job key: no read, no move
UCASE; echo ejected > "$J/phase"; R=$(UJ RB-5)
[ "$R" = "rc=0|why=" ] && [ ! -s "$J/calls.txt" ] && ok || bad "U1 a lane key RB-5 reads nothing ($R; calls: $(cat "$J/calls.txt"))"
# U2 an empty key
UCASE; echo ejected > "$J/phase"; R=$(UJ "")
[ "$R" = "rc=0|why=" ] && [ ! -s "$J/calls.txt" ] && ok || bad "U2 an empty key reads nothing ($R)"
# U3 no jobs client on this box: no read, no line
UCASE; echo ejected > "$J/phase"; R=$(UJ TK-9 nojobs)
[ "$R" = "rc=0|why=" ] && [ ! -s "$J/calls.txt" ] && [ ! -s "$T/usay.txt" ] && ok \
  || bad "U3 no _jobs_req: rc 0, no read, no line ($R; say: $(cat "$T/usay.txt"))"
# U4 no build_queue row
UCASE; R=$(UJ TK-9)
[ "$R" = "rc=0|why=" ] && [ "$(POSTS)" = 0 ] && [ "$(grep -c '^GET' "$J/calls.txt")" = 1 ] && ok \
  || bad "U4 no row: one read, no move ($R; calls: $(cat "$J/calls.txt"))"
# U5 the phase cannot be read: fail open, one line
UCASE; echo ejected > "$J/phase"; echo 1 > "$J/get-rc"; R=$(UJ TK-9)
[ "$R" = "rc=0|why=" ] && [ "$(POSTS)" = 0 ] && [ "$(SAYN 'TK-9: phase unreadable')" = 1 ] && ok \
  || bad "U5 an unreadable phase: rc 0, no move, one line ($R; say: $(cat "$T/usay.txt"))"
# U6-U9 every phase that is not ejected: no move (plan_blocked and abandoned
# are the ticket's negative cases: who may leave them does not widen)
for ph in building pr_open in_queue plan_blocked abandoned merged closed planned -; do
  UCASE; echo "$ph" > "$J/phase"; R=$(UJ TK-9)
  [ "$R" = "rc=0|why=" ] && [ "$(POSTS)" = 0 ] && [ "$(PHASE)" = "$ph" ] && [ ! -s "$T/usay.txt" ] && ok \
    || bad "U6 phase '$ph': no move, no line ($R; calls: $(cat "$J/calls.txt"); say: $(cat "$T/usay.txt"))"
done
# U10 phase ejected: one POST, actor lifecycle, the rung as the reason
UCASE; echo ejected > "$J/phase"; R=$(UJ TK-9)
[ "$R" = "rc=0|why=" ] && [ "$(POSTS)" = 1 ] && [ "$(PHASE)" = pr_open ] && ok \
  || bad "U10 ejected: moved to pr_open with one POST ($R; phase $(PHASE); calls: $(cat "$J/calls.txt"))"
BODY=$(grep '^POST /api/lifecycle/transition' "$J/calls.txt" | head -1 | cut -d' ' -f3-)
[ "$(jq -r .actor <<<"$BODY")" = lifecycle ] && [ "$(jq -r .to_phase <<<"$BODY")" = pr_open ] \
  && [ "$(jq -r .ticket_key <<<"$BODY")" = TK-9 ] && [ "$(jq -r .project <<<"$BODY")" = tproj ] \
  && [ "$(jq -r .reason <<<"$BODY")" = "blocked-resolver: stale-replan: no head or verdict change for 5d" ] \
  && [ "$(jq -r 'has("pr")' <<<"$BODY")" = false ] && ok \
  || bad "U10 the POST body is {tproj, TK-9, pr_open, lifecycle, blocked-resolver: <rung>} with no pr ($BODY)"
[ "$(SAYN 'TK-9: phase ejected -> pr_open (actor lifecycle, stale-replan')" = 1 ] && ok \
  || bad "U10 one line names the move (say: $(cat "$T/usay.txt"))"
# U11 a 409 whose current is pr_open: the move already landed (a race), success
UCASE; echo ejected > "$J/phase"; echo 9 > "$J/trans-rc"; echo '{"error":"illegal_transition","current":"pr_open","to":"pr_open"}' > "$J/trans-body"
R=$(UJ TK-9)
[ "$R" = "rc=0|why=" ] && ok || bad "U11 409 with current pr_open is already done ($R)"
# U12 a 409 wrong_owner: rc 1, PU_WHY names the error and the current phase
UCASE; echo ejected > "$J/phase"; echo 9 > "$J/trans-rc"; echo '{"error":"wrong_owner","current":"ejected","to":"pr_open"}' > "$J/trans-body"
R=$(UJ TK-9)
case "$R" in "rc=1|why=the phase move ejected -> pr_open was refused (wrong_owner; current ejected)") ok ;;
  *) bad "U12 409 wrong_owner: rc 1 with the error in PU_WHY ($R)" ;; esac
# U12b a 409 whose current is in_queue (the Tackler moved it first): failure
UCASE; echo ejected > "$J/phase"; echo 9 > "$J/trans-rc"; echo '{"error":"stale","current":"in_queue","to":"pr_open"}' > "$J/trans-body"
R=$(UJ TK-9)
case "$R" in "rc=1|why="*"stale; current in_queue"*) ok ;; *) bad "U12b 409 stale, current in_queue: rc 1 ($R)" ;; esac
# U13 404: no build_queue row behind the move
UCASE; echo ejected > "$J/phase"; echo 2 > "$J/trans-rc"; R=$(UJ TK-9)
case "$R" in "rc=1|why=the phase move ejected -> pr_open found no build_queue row") ok ;; *) bad "U13 404: rc 1 ($R)" ;; esac
# U14 an outage on the write
UCASE; echo ejected > "$J/phase"; echo 1 > "$J/trans-rc"; R=$(UJ TK-9)
case "$R" in "rc=1|why=the phase move ejected -> pr_open did not land (lifecycle DB unreadable)") ok ;; *) bad "U14 an outage: rc 1 ($R)" ;; esac

# ============================================================================
# S. THE REAL bin/blocked-resolver.sh, the stale-replan rung
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
( cd "$DIR" && scratch_install_closure bin/lib/br/opt/cirepair.sh "$H" && scratch_install_closure bin/lib/br/opt/stale.sh "$H" \
  && scratch_install_closure bin/lib/plan-blocked-stop.sh "$H" && scratch_install_closure bin/lib/jobs/lifecycle.sh "$H" ) >/dev/null || exit 1
[ -f "$DIR/bin/blocked-resolver.d/bh-9943-phase-uneject.sh" ] && { ( cd "$DIR" && scratch_install_closure bin/blocked-resolver.d/bh-9943-phase-uneject.sh "$H" ) >/dev/null || exit 1; }
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
( cd "$DIR" && scratch_install_closure bin/lib/ticket-ownership.sh "$H" ) >/dev/null || exit 1
cat > "$H/bin/lib/hold.sh" <<'EOF'
hold_check() { printf 'clear\tno hold on this ticket\n'; return 0; }
hold_check_thread() { printf 'clear\tno-hold\n'; return 0; }
hold_is_pause()   { return 1; }
hold_is_abandon() { return 1; }
EOF
# the verdicts reader: nothing stands on any head (the rebuild rung asks it)
cat > "$H/bin/lib/verdicts.sh" <<'EOF'
vd_standing() { return 1; }
vd_clear_word() { return 1; }
EOF
printf '. "%s"\n' "$T/jobs-stub.sh" > "$H/bin/jobs-client.sh"
touch "$H/flags/fly-pool-tproj"
LOGF="$H/logs/blocked-resolver.log"
URL="https://github.com/o/tproj/pull/9"
STALEWHY="stale-replan: no head or verdict change for 5d"
BRENV=(BR_SUPERSEDE_SETTLE_SECS=0 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600 BR_REGEN_RUNG=0)
BFRESH() {
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/state/build-notes"
  : > "$T/closed.txt"; : > "$T/comment-bodies.txt"; : > "$LOGF"
  scratch_rm "$H/state/merge-conductor/handoff"; scratch_rm "$H/state/merge-conductor/handoff-released"
  printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"; echo OPEN > "$T/prstate"
  JRESET
  ROW "o/tproj#9" "$STALEWHY" "$URL"
}
REC() { STATEJSON tproj-TK-9; }
NQ() { grep -c '^tproj TK-9 ' "$J/queue.txt" 2>/dev/null || true; }
# pbs_stop_check, the pool's own spawn gate, over the same stub state
GATE() { (
  say() { :; }
  # shellcheck source=/dev/null
  . "$T/jobs-stub.sh"
  # shellcheck source=bin/lib/plan-blocked-stop.sh
  . "$H/bin/lib/plan-blocked-stop.sh"
  HARNESS="$H" pbs_stop_check tproj TK-9 9
) }

# S1 phase ejected: the rung re-plans AND moves the phase; the pool may spawn
BFRESH; echo ejected > "$J/phase"
GATE && bad "S1 precondition: pbs_stop_check refuses an ejected key" || ok
RUN
[ "$(PHASE)" = pr_open ] && ok || bad "S1 the phase moved ejected -> pr_open (phase $(PHASE); calls: $(cat "$J/calls.txt"); log: $(tail -5 "$LOGF"))"
[ "$(NQ)" = 1 ] && ok || bad "S1 exactly one queue row (queue: $(cat "$J/queue.txt"))"
BODY=$(grep '^POST /api/lifecycle/transition' "$J/calls.txt" | head -1 | cut -d' ' -f3-)
[ "$(POSTS)" = 1 ] && [ "$(jq -r .actor <<<"$BODY" 2>/dev/null)" = lifecycle ] && [ "$(jq -r .to_phase <<<"$BODY" 2>/dev/null)" = pr_open ] \
  && case "$(jq -r .reason <<<"$BODY" 2>/dev/null)" in "blocked-resolver: stale-replan"*) true ;; *) false ;; esac && ok \
  || bad "S1 one POST, actor lifecycle, to pr_open, reason blocked-resolver: stale-replan... (calls: $(cat "$J/calls.txt"))"
[ "$(REC | jq -r '.ci_replans // ""')" = 1 ] && ok || bad "S1 the re-plan is counted (record: $(REC))"
grep -q 'TK-9: phase ejected -> pr_open (actor lifecycle' "$LOGF" && ok || bad "S1 the move is logged (log: $(tail -5 "$LOGF"))"
GATE && ok || bad "S1 pbs_stop_check returns 0 after the rung"
RUN; RUN
[ "$(NQ)" = 1 ] && [ "$(POSTS)" = 1 ] && ok || bad "S1 later ticks enqueue and move nothing more (queue: $(cat "$J/queue.txt"); calls: $(cat "$J/calls.txt"))"

# S2 the move is refused: the rung is not counted, one line names the error
BFRESH; echo ejected > "$J/phase"; echo 9 > "$J/trans-rc"
echo '{"error":"wrong_owner","current":"ejected","to":"pr_open","owners":["lifecycle"]}' > "$J/trans-body"
RUN
[ "$(PHASE)" = ejected ] && ok || bad "S2 the phase stays ejected (phase $(PHASE))"
[ -z "$(REC | jq -r '.ci_replans // ""')" ] && ok || bad "S2 no re-plan is counted (record: $(REC))"
printf "%s" "$(REC)" | jq -s -e '[.[0].attempts[]? | select(.action == "stale-replan" or .action == "stale-replan-skipped")] | length == 0' >/dev/null 2>&1 && ok \
  || bad "S2 no stale-replan record (record: $(REC))"
[ "$(grep -c 'wrong_owner' "$LOGF")" = 1 ] && ok || bad "S2 one log line names the error (log: $(grep wrong_owner "$LOGF"))"
grep -q 'RE-PLANNED' "$LOGF" && bad "S2 no RE-PLANNED line (log: $(grep RE-PLANNED "$LOGF"))" || ok
# ...and the next tick, with the worker fixed, finds the row already queued
rm -f "$J/trans-rc" "$J/trans-body"; echo duplicate > "$J/qput"
RUN
[ "$(PHASE)" = pr_open ] && [ "$(REC | jq -r '.ci_replans // ""')" = 1 ] && [ "$(NQ)" = 1 ] && ok \
  || bad "S2 the retry tick moves the phase on the duplicate answer and counts once (phase $(PHASE); queue $(NQ); record: $(REC); log: $(tail -4 "$LOGF"))"

# S3 phase building: no move, the rung counts as today
BFRESH; echo building > "$J/phase"
RUN
[ "$(POSTS)" = 0 ] && [ "$(PHASE)" = building ] && [ "$(NQ)" = 1 ] && [ "$(REC | jq -r '.ci_replans // ""')" = 1 ] && ok \
  || bad "S3 a building phase is not moved and the re-plan counts (calls: $(cat "$J/calls.txt"); record: $(REC))"

# ============================================================================
# R. the rebuild-fresh rung, the same enqueue
# ============================================================================
RFRESH() {
  BFRESH
  SPENT tproj-TK-9
  ROWST "o/tproj#9" RED_TWICE "red-twice: still red on aaaaaaaa after its failed jobs were re-run once" "$URL"
}
RFRESH; echo ejected > "$J/phase"
RUN
[ "$(PHASE)" = pr_open ] && [ "$(NQ)" = 1 ] && [ "$(REC | jq -r .rebuilds)" = 1 ] && ok \
  || bad "R1 rebuild-fresh moves ejected -> pr_open and counts the rebuild (phase $(PHASE); queue $(NQ); record: $(REC); log: $(tail -5 "$LOGF"))"
RFRESH; echo ejected > "$J/phase"; echo 9 > "$J/trans-rc"
echo '{"error":"wrong_owner","current":"ejected","to":"pr_open"}' > "$J/trans-body"
RUN
[ "$(PHASE)" = ejected ] && [ "$(REC | jq -r .rebuilds)" = 0 ] && ok \
  || bad "R1b a refused move spends no rebuild (phase $(PHASE); record: $(REC))"
REC | jq -e '[.attempts[]? | select(.action == "rebuild-fresh-failed")] | length == 1' >/dev/null 2>&1 && ok \
  || bad "R1b one rebuild-fresh-failed attempt (record: $(REC))"
[ "$(grep -c 'wrong_owner' "$LOGF")" = 1 ] && ok || bad "R1b the error is in one log line (log: $(grep wrong_owner "$LOGF"))"

# ============================================================================
# G. the stuck-queue gate names the phase
# ============================================================================
GH="$T/g"; P=tproj
mkdir -p "$GH/logs" "$GH/locks" "$GH/builds" "$GH/state/build-queue/$P" "$GH/state/pool/$P" "$GH/state/triage-repeat/$P"
( cd "$DIR" && scratch_install_closure bin/lib/stuckqueue-gate.sh "$GH" ) >/dev/null || bad "G0 install bin/lib/stuckqueue-gate.sh"
EJ='2026-11-23 10:00:00Z [tproj] skipping TK-9: phase ejected since 2026-11-12T18:58:23Z — not spawned; re-entry is the lifecycle owner'"'"'s move'
RP='2026-11-23 09:00:00Z tproj/o/tproj#9 [stale-replan: no head or verdict change for 5d]: stale park RE-PLANNED — TK-9 enqueued fresh (re-plan 1 of 1)'
gate() { ( . "$GH/bin/lib/stuckqueue-gate.sh" 2>/dev/null; sqg_gate "$GH" "$P" "$1" ) 2>/dev/null; }
glogs() { printf '%s\n' "$1" > "$GH/logs/fly-pool.log"; printf '%s\n' "$2" > "$GH/logs/blocked-resolver.log"; }
# G1 the live ejected line plus the resolver's re-plan line
glogs "$EJ" "$RP"; G=$(gate TK-9)
case "$G" in "phase-ejected	phase ejected, re-planned: fly-pool.log: skipping TK-9: phase ejected since"*) ok ;;
  *) bad "G1 an ejected key that was re-planned: phase-ejected, re-planned ($G)" ;; esac
# G1b a fresh pool enqueue line counts as re-planned too
glogs "$EJ" "2026-11-23 09:00:00Z tproj/TK-9: fresh pool build enqueued (attempt 0, red-twice rebuild 1 of 2) -> queued (job x)"; G=$(gate TK-9)
case "$G" in "phase-ejected	phase ejected, re-planned:"*) ok ;; *) bad "G1b a fresh-enqueue line: re-planned ($G)" ;; esac
# G2 no resolver line
glogs "$EJ" ""; G=$(gate TK-9)
case "$G" in "phase-ejected	phase ejected: fly-pool.log: skipping TK-9"*) ok ;; *) bad "G2 no re-plan line: phase ejected, not re-planned ($G)" ;; esac
# G3 the other phases the spawn gate refuses stay pool-log
for ph in plan_blocked abandoned in_queue; do
  glogs "2026-11-23 10:00:00Z [tproj] skipping TK-9: phase $ph since 2026-11-12T18:58:23Z — not spawned" "$RP"; G=$(gate TK-9)
  [ "${G%%$'\t'*}" = pool-log ] && ok || bad "G3 phase $ph stays pool-log ($G)"
done
# G4 a re-plan line for another key with the same prefix does not count
glogs "$EJ" "${RP//TK-9 /TK-90 }"; G=$(gate TK-9)
case "$G" in "phase-ejected	phase ejected: "*) ok ;; *) bad "G4 a TK-90 re-plan line is not TK-9's ($G)" ;; esac
# G4b a fly-pool line for TK-90 is not TK-9's
glogs "${EJ//TK-9:/TK-90:}" "$RP"; G=$(gate TK-9)
[ "${G%%$'\t'*}" != phase-ejected ] && ok || bad "G4b a TK-90 pool line is not TK-9's ($G)"
# G5 the conductor's reason text is not the phase
glogs "2026-11-23 10:00:00Z [tproj] TK-9: queue-ejected-twice — the conductor parked it" "$RP"; G=$(gate TK-9)
[ "${G%%$'\t'*}" != phase-ejected ] && ok || bad "G5 queue-ejected-twice text is not phase-ejected ($G)"
# G6 the REAL pipeline-health stuck-queue block prints the gate
awk '/^# >>> stuck queue/{f=1;next} /^# <<< stuck queue/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/block.sh"
grep -q 'stuckqueue:' "$T/block.sh" && ok || bad "G6 the extracted block is not the stuck-queue check"
glogs "$EJ" "$RP"
: > "$GH/state/build-queue/$P/TK-9.json"; touch -d "@$(( $(date -u +%s) - 3 * 3600 ))" "$GH/state/build-queue/$P/TK-9.json"
: > "$T/alerts.txt"
( alert() { printf '%s\t%s\n' "$2" "$3" >> "$T/alerts.txt"; }
  H="$GH"; PROJECTS=$P; NOW=$(date -u +%s); FIRED=/dev/null
  . "$GH/bin/lib/stuckqueue-gate.sh" 2>/dev/null
  # shellcheck disable=SC1090
  . "$T/block.sh" ) 2>/dev/null
AL=$(grep "^stuckqueue:$P:TK-9.json	" "$T/alerts.txt" | cut -f2)
case "$AL" in "$P TK-9 queued "*"m with no spawn — held by phase-ejected: phase ejected, re-planned: fly-pool.log: skipping TK-9"*) ok ;;
  *) bad "G6 the alert names phase-ejected, re-planned ($AL)" ;; esac
case "$AL" in *"fly-dispatch/pool not picking it up"*) bad "G6 the alert does not say fly-dispatch/pool not picking it up ($AL)" ;; *) ok ;; esac

echo "blocked-resolver-uneject.bh-9943-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
