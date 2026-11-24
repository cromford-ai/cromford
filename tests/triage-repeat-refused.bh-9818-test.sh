#!/bin/bash
# tests/triage-repeat-refused.bh-9818-test.sh — BH-9818: a triage shard that
# the call guard refuses as a repeat is parked, its queue line goes, the board
# gets 1 comment, and the dispatcher does not start it again until the ticket's
# board entry changes.
#
# project-6-os, 2026-11-18: shards 3788, 3797, 3814, 3819 ... ended rc 74
# `AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2` on 7 of 10 runs.
# The BH-3949 park fired for 3788 and the shard still ran, because a park only
# stops a board-only key (bin/lib/triage-state.sh ts_unit_skip).
#
#   A1-A11 the REAL bin/triage-shard.sh with agent-call stubbed (rc 74 etc.):
#          the park file, the queue-line release, the 1 comment through the
#          tracker seam (a fake bin/lib/tracker.sh), the negatives, the knob.
#   D1-D8  the REAL rt_shards (bin/lib/rt/shards.sh) on the same scratch
#          harness, which launches the REAL triage-shard.sh: tick 1 parks,
#          tick 2 starts 0 shards and posts 0 comments, a board change
#          unparks and the next tick starts the shard 1 time.
#   V1-V2  0 vendor calls; no edit to the call-guard limit (call-guard.sh,
#          and the call-guard lines of agent-call.sh).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-repeat-refused.bh-9818-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1
unset TRIAGE_REPEAT_PARK TRIAGE_REPEAT_PARK_KEEP_S QUEUE_DEAD_SWEEP QUEUE_DEAD_SWEEP_MAX_READS TSH_QUEUE
unset QUEUE_CLOSED_DROP QUEUE_REFUSED_DROP_AFTER QUEUE_REFUSED_KEEP_S TRIAGE_REFUSED_PARK_AFTER

mkdir -p "$T/rbin" "$T/calls"
for v in gh claude curl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls/vendor"\nexit 1\n' "$v" "$T" > "$T/rbin/$v"
done
printf '#!/bin/bash\nexec "$@"\n' > "$T/rbin/setsid"
chmod +x "$T/rbin/"*
export PATH="$T/rbin:$PATH"

# ── one scratch harness: the real shard, the real dispatcher libs ───────────
S="$T/s"; FX="$T/fx"
mkdir -p "$S/bin/lib" "$S/logs" "$S/locks" "$S/env" "$S/state" "$FX"
scratch_install_closure bin/triage-shard.sh "$S" >/dev/null 2>&1 || bad "install bin/triage-shard.sh"
scratch_install_closure bin/queue-line-drop.sh "$S" >/dev/null 2>&1 || bad "install bin/queue-line-drop.sh"
scratch_install_closure bin/lib/triage-shards-lib.sh "$S" >/dev/null 2>&1 || bad "install bin/lib/triage-shards-lib.sh"
scratch_install_closure bin/lib/queue-closed.sh "$S" >/dev/null 2>&1 || :
scratch_install_closure bin/lib/triage-repeat-park.sh "$S" >/dev/null 2>&1 || :
scratch_install_closure bin/lib/jobs/lifecycle.sh "$S" >/dev/null 2>&1 || bad "install bin/lib/jobs/lifecycle.sh"
# The per-ticket verdict store is not under test here (it gates board-only
# keys); both sides read it only when it is readable.
rm -f "$S/bin/lib/triage-state.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$S/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/decision-log.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/beat.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/lanealert"\nexit 0\n' "$FX" > "$S/bin/lane-alert.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/alertline"\nexit 0\n' "$FX" > "$S/bin/alert-line.sh"
cat > "$S/bin/fleet-conf.sh" <<'STUB'
#!/bin/bash
[ "${1:-}" = --projects-on-box ] && echo onlyone
exit 0
STUB
# The jobs worker: every request is logged; the REAL bin/lib/jobs/lifecycle.sh
# (lifecycle_note) is installed with the lib and posts through this.
cat > "$S/bin/jobs-client.sh" <<STUB
job_open() { return 1; }
call_guard_list() { return 1; }
_jobs_req() { printf '%s %s %s\n' "\$1" "\$2" "\${3:-}" >> "$FX/jobsreq"; echo '{"queue":[]}'; }
STUB
printf 'rq_drop() { shift 2; printf "%%s\\n" "$*" >> "%s/rqdrop"; }\n' "$FX" > "$S/bin/lib/ready-queue.sh"
# GitHub issue state for the closed-issue drop: every issue is open.
printf 'gh_rest_issue_state_var() { printf -v "$1" %%s open; GH_REST_STATUS=200; return 0; }\n' > "$S/bin/lib/gh-rest.sh"
# THE TRACKER SEAM, faked: every comment is a file, rc from $FX/cm.rc.
cat > "$S/bin/lib/tracker.sh" <<STUB
tracker_context() { printf '%s\n' "\$*" >> "$FX/ctx"; return "\$(cat "$FX/ctx.rc" 2>/dev/null || echo 0)"; }
tracker_comment() {
  local n; n=\$(( \$(cat "$FX/comments" 2>/dev/null | wc -l) + 1 ))
  cp "\$2" "$FX/comment.\$n"; printf '%s\n' "\$1" >> "$FX/comments"
  return "\$(cat "$FX/cm.rc" 2>/dev/null || echo 0)"
}
STUB
cat > "$S/bin/agent-call.sh" <<'STUB'
#!/bin/bash
echo "${AGENT_CALL_TICKET:-?}" >> "$FX/agent-calls"
case "${SHARD_AC:-repeat}" in
  repeat)     printf 'AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2 fp=%s\n' "${AGENT_CALL_FP:-}" > "$5"; exit 74 ;;
  repeat3)    printf 'AGENT_CALL_REFUSED call-guard repeat triage-shard paid=3/2 fp=%s\n' "${AGENT_CALL_FP:-}" > "$5"; exit 74 ;;
  unreadable) printf 'AGENT_CALL_REFUSED call-guard counter-unreadable metered claude\n' > "$5"; exit 74 ;;
  ctxkill)    printf 'AGENT_CALL_REFUSED context-kill repeat triage-shard kills=3/3 fp=x\n' > "$5"; exit 74 ;;
  budget)     printf 'AGENT_CALL_REFUSED budget-stop daily cap\n' > "$5"; exit 74 ;;
  lead)       printf ' AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2 fp=x\n' > "$5"; exit 74 ;;
  okbody)     printf 'AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2 fp=x\ntickets=1 done\n' > "$5"; exit 0 ;;
  rc1)        printf 'AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2 fp=x\n' > "$5"; exit 1 ;;
esac
echo "tickets=1 done" > "$5"
STUB
chmod +x "$S/bin/"*.sh
export FX
RP=project-6-os-t9818
SQ="$S/logs/READY-QUEUE.log"
RD="$S/state/triage-repeat/$RP"
PARK="$RD/421.park"
printf 'TICK SCOPE (triage shard)\n\nWhat moved for 421:\nOn the board:\nboard: 421 changed\n' > "$S/prompt.txt"

# gate <updatedAt> <comments> [title] — the live board fingerprint (pending copy)
gate() {
  jq -nc --arg u "$1" --argjson c "$2" --arg t "${3:-ticket 421}" \
    '{issues:[{number:421,state:"OPEN",title:$t,comments:$c,updatedAt:$u},
              {number:4210,state:"OPEN",title:"ticket 4210",comments:1,updatedAt:"2026-11-01T00:00:00Z"}]}' \
    > "$S/state/$RP.gate.pending"
}
# bid_of <number> — the expected board identity: sha256 of this ticket's
# canonical entry, computed here without the lib (python's sort_keys + compact
# separators is jq -cS for these fixtures).
bid_of() {
  local e
  e=$(jq -cS --argjson n "$1" '.issues[] | select(.number == $n)' "$S/state/$RP.gate.pending")
  printf 'pend issues %s' "$e" | sha256sum | cut -c1-16
}
fresh() {
  scratch_rm "$FX"; mkdir -p "$FX"
  scratch_rm "$S/state/triage-repeat"; scratch_rm "$S/state/queue-refused"; scratch_rm "$S/state/triage-shards"
  rm -f "$S/logs/$RP.log" "$S/logs/ALERTS.log"
  printf 'BH-421 waiting on PR #900\nBH-4210 waiting on PR #901\n' > "$SQ"
  gate 2026-11-18T10:00:00Z 3
}
shard() { # shard <mode> [queue text]
  ( export HARNESS="$S" SHARD_AC="$1" TSH_MODEL=m TSH_RUNNER=claude TSH_GH=1 TSH_QUEUE="${2-BH-421 waiting on PR #900}"
    bash "$S/bin/triage-shard.sh" "$RP" 421 "$S/prompt.txt" >/dev/null 2>&1 )
}
ncm() { local n; n=$(grep -cx "${1:-421}" "$FX/comments" 2>/dev/null); echo "${n:-0}"; }
ncalls() { local n; n=$(grep -cx "${1:-421}" "$FX/agent-calls" 2>/dev/null); echo "${n:-0}"; }

# ═══ A: the repeat arm of the real triage-shard.sh ══════════════════════════
fresh
shard repeat
# A1: one rc-74 repeat parks the key
[ -f "$PARK" ] && ok || bad "(A1) no park file after a call-guard repeat: [$(ls -R "$S/state" 2>/dev/null | tr '\n' ' ')]"
# A2: the reason column starts triage-repeat-refused
[ "$(cut -f5 "$PARK" 2>/dev/null | cut -c1-21)" = "triage-repeat-refused" ] && ok \
  || bad "(A2) park reason: [$(cut -f5 "$PARK" 2>/dev/null)]"
# A3: the board identity is the sha of the ticket's own gate entry
[ "$(cut -f1 "$PARK" 2>/dev/null)" = "$(bid_of 421)" ] && ok \
  || bad "(A3) park bid [$(cut -f1 "$PARK" 2>/dev/null)] != sha of the gate entry [$(bid_of 421)]"
[ "$(grep -c . "$PARK" 2>/dev/null)" = 1 ] && ok || bad "(A3) the park file is one line: [$(cat "$PARK" 2>/dev/null)]"
# A4: the READY line goes, the neighbour 4210 stays, the D1 ready row drop was asked
grep -q '^BH-421 ' "$SQ" && bad "(A4) the BH-421 line is still queued after 1 repeat" || ok
grep -q '^BH-4210 ' "$SQ" && ok || bad "(A4) BH-4210 (shares the 421 prefix) lost its line"
grep -qx 'BH-421' "$FX/rqdrop" 2>/dev/null && ok || bad "(A4) the ready-row drop was not asked for BH-421: [$(cat "$FX/rqdrop" 2>/dev/null)]"
# A5: exactly 1 comment, on issue 421, with the fixed plain text
[ "$(ncm)" = 1 ] && ok || bad "(A5) want 1 comment, got $(ncm)"
[ "$(head -1 "$FX/comments" 2>/dev/null)" = 421 ] && ok || bad "(A5) comment target: [$(cat "$FX/comments" 2>/dev/null)]"
[ "$(head -1 "$FX/comment.1" 2>/dev/null)" = '<!-- harness-status: results-sweep -->' ] && ok \
  || bad "(A5) line 1 of the comment is the status marker: [$(head -1 "$FX/comment.1" 2>/dev/null)]"
for w in "No code was written" "add a comment" "edit the ticket body" "paused triage"; do
  grep -qF "$w" "$FX/comment.1" 2>/dev/null && ok || bad "(A5) the comment says '$w': [$(cat "$FX/comment.1" 2>/dev/null)]"
done
[ -f "$RD/421.commented" ] && [ "$(cat "$RD/421.commented")" = "$(bid_of 421)" ] && ok \
  || bad "(A5) .commented holds the bid: [$(cat "$RD/421.commented" 2>/dev/null)]"
grep -q "triage-repeat: 421 parked (triage-repeat-refused.*comment: posted" "$S/logs/$RP.log" && ok \
  || bad "(A5) the project log line: [$(grep triage-repeat "$S/logs/$RP.log" 2>/dev/null)]"
# A10: the D1 record of the park (lifecycle_note), on the queue label
L10=$(grep '^POST /api/lifecycle/note ' "$FX/jobsreq" 2>/dev/null | head -1 | cut -d' ' -f3-)
[ "$(printf '%s' "$L10" | jq -r '[.project, .ticket_key, .actor, (.reason | startswith("triage-repeat-refused: call-guard paid=2/2"))] | map(tostring) | join(" ")' 2>/dev/null)" = "$RP BH-421 triage true" ] && ok \
  || bad "(A10) lifecycle_note record: [$(cat "$FX/jobsreq" 2>/dev/null)]"
# A6: a second repeat on the same board entry posts 0 more comments
shard repeat3 ""
[ "$(ncm)" = 1 ] && ok || bad "(A6) a second repeat posted again: $(ncm) comments"
[ -f "$PARK" ] && ok || bad "(A6) the park file went on a second repeat"
grep -q "comment: skipped (already posted)" "$S/logs/$RP.log" && ok || bad "(A6) the second log line says skipped"

# A7: the comment fails: park kept, no .commented, 1 alert-line, no raw ALERTS line
fresh
echo 1 > "$FX/cm.rc"
shard repeat
[ -f "$PARK" ] && ok || bad "(A7) a failed comment lost the park"
[ -e "$RD/421.commented" ] && bad "(A7) .commented written although the comment failed" || ok
[ "$(grep -c -- "--id triage-repeat-comment-$RP-421 --project $RP" "$FX/alertline" 2>/dev/null)" = 1 ] && ok \
  || bad "(A7) one alert-line with the comment id: [$(cat "$FX/alertline" 2>/dev/null)]"
grep -q 'triage-repeat' "$S/logs/ALERTS.log" 2>/dev/null && bad "(A7) a raw ALERTS.log write" || ok
grep -q "triage-repeat" "$FX/lanealert" 2>/dev/null && bad "(A7) lane-alert was used" || ok
grep -q "comment: FAILED" "$S/logs/$RP.log" && ok || bad "(A7) the log says FAILED"
# A7b: the next repeat on the same board entry tries the comment again
rm -f "$FX/cm.rc"
shard repeat ""
[ "$(ncm)" = 2 ] && [ -f "$RD/421.commented" ] && ok || bad "(A7b) the retry after a failed comment: $(ncm) comments"

# A8: negatives — nothing parks, comments or drops
for m in unreadable ctxkill budget lead okbody rc1; do
  fresh
  shard "$m"
  [ -e "$PARK" ] && bad "(A8 $m) parked" || ok
  [ "$(ncm)" = 0 ] && ok || bad "(A8 $m) commented ($(ncm))"
  grep -q '^BH-421 ' "$SQ" && ok || bad "(A8 $m) the queue line was dropped"
done

# A9: TRIAGE_REPEAT_PARK=0: off
fresh
( export TRIAGE_REPEAT_PARK=0; shard repeat )
[ -e "$PARK" ] && bad "(A9) TRIAGE_REPEAT_PARK=0 still parked" || ok
[ "$(ncm)" = 0 ] && ok || bad "(A9) TRIAGE_REPEAT_PARK=0 commented"
grep -q '^BH-421 ' "$SQ" && ok || bad "(A9) TRIAGE_REPEAT_PARK=0 dropped the line"

# A11: an in-app board (TSH_GH=0): the tracker id comes from the keymap, and
# the first move of the board entry after our comment is absorbed (rebase=1)
fresh
jq -nc '{tickets:[{id:"TK-77",status:"todo",commentCount:2,updatedAt:"2026-11-18T10:00:00Z"}]}' > "$S/state/$RP.gate.pending"
echo '{"TK-77":"cuid-77"}' > "$S/state/$RP.keymap.json"
printf 'TK-77 waiting on review\n' >> "$SQ"
( export HARNESS="$S" SHARD_AC=repeat TSH_MODEL=m TSH_RUNNER=claude TSH_GH=0 TSH_QUEUE="TK-77 waiting on review"
  bash "$S/bin/triage-shard.sh" "$RP" TK-77 "$S/prompt.txt" >/dev/null 2>&1 )
[ "$(head -1 "$FX/comments" 2>/dev/null)" = cuid-77 ] && ok || bad "(A11) in-app comment target: [$(cat "$FX/comments" 2>/dev/null)]"
[ "$(cut -f4 "$RD/TK-77.park" 2>/dev/null)" = 1 ] && ok || bad "(A11) in-app park has rebase=1: [$(cat "$RD/TK-77.park" 2>/dev/null)]"
grep -q '^TK-77 ' "$SQ" && bad "(A11) the TK-77 line stayed" || ok
rm -f "$S/state/$RP.keymap.json"

# ═══ D: the real dispatcher (rt_shards) over the real shard ═════════════════
# tick — one tick through the real rt_shards on $S. QLINES is the queue file
# as it is now, TS the board lines.
tick() {
  ( set +u
    export HARNESS="$S" FX SHARD_AC="${AC:-repeat}" QUEUE_DEAD_SWEEP=0
    PROJECT=$RP; STAMP="t"; LOG="$S/logs/$RP.log"; ALERTS="$S/logs/ALERTS.log"
    GATE_DECISION="RUN queue"; GATE_REASON=queue; SCOPE_N=queue
    TICK_SCOPE="${TS:-}"; BOARD_SEC=""; QLINES="$(cat "$SQ" 2>/dev/null)"; QDIRS="${QD:-}"; RDIRS=""
    JOB_ID=""; PROMPT_TEXT="SOP"; TRIAGE_MODEL=m; SHARD_SOP="SOP"; EFFECTIVE_GROK_EFFORT=""
    LANE_TICK() { :; }; rt_gate_consume() { echo consumed >> "$FX/consume"; }
    . "$S/bin/lib/triage-shards-lib.sh"
    triage_shards_on() { echo 1; }; triage_shard_gh() { echo 1; }; triage_shard_fp_ttl() { echo 3600; }
    triage_shards_max() { echo 0; }; triage_caps_on() { echo 0; }
    triage_prstates_ingest() { :; }; triage_prstates_refresh() { :; }; triage_prstates_prune() { :; }
    triage_shard_fp() { echo "fp-$3"; }; triage_shard_fp_fresh() { return 1; }
    triage_shard_fp_put() { :; }; triage_shard_rearm() { :; }; triage_throttle_record() { :; }
    lock_spawn_unheld() { "$@"; }
    . "$DIR/bin/lib/rt/shards.sh"
    rt_shards ) >/dev/null 2>&1
}
summary() { grep "dispatched .* shards:" "$S/logs/$RP.log" 2>/dev/null | tail -1; }
TS='board changed: CHANGED 421 "ticket 421" (comments: 2 -> 3)'
# The live project-6 shape: a queued build_queue row (QDIRS) the pool never
# spawns, beside the board line. Neither goes away when the READY line does.
QD='BH-421 (target fly, attempt 2, queued 2026-11-18T09:00:00Z)'

# D1: tick 1 starts the shard 1 time; it is refused and parks the key
fresh
tick
[ "$(ncalls)" = 1 ] && ok || bad "(D1) tick 1 must start the shard 1 time, got $(ncalls)"
[ -f "$PARK" ] && ok || bad "(D1) tick 1 did not park 421"
[ "$(ncm)" = 1 ] && ok || bad "(D1) tick 1 must post 1 comment, got $(ncm)"
# D2: tick 2 starts 0 shards for the parked key, and says so in the summary
tick
[ "$(ncalls)" = 1 ] && ok || bad "(D2) tick 2 started the parked shard again ($(ncalls) calls)"
case "$(summary)" in *" — repeat-parked: 421"*) ok ;; *) bad "(D2) the summary names the parked key: [$(summary)]" ;; esac
grep -q "triage-repeat: 421 unparked" "$S/logs/$RP.log" && bad "(D2) an unchanged board unparked" || ok
# D3: tick 2 posts 0 comments
[ "$(ncm)" = 1 ] && ok || bad "(D3) tick 2 posted a comment ($(ncm))"
# D2b: a third tick with the line gone and a QDIRS-style queue unit is still parked
tick
[ "$(ncalls)" = 1 ] && ok || bad "(D2b) tick 3 started the shard ($(ncalls))"

# D5: rebase=0 and a moved board entry (a new comment): unpark, 1 launch
gate 2026-11-19T09:00:00Z 4
tick
[ "$(ncalls)" = 2 ] && ok || bad "(D5) a new comment must start the shard exactly 1 time, got $(( $(ncalls) - 1 ))"
grep -q "triage-repeat: 421 unparked: board entry changed" "$S/logs/$RP.log" && ok || bad "(D5) the unpark is logged"
# the shard was refused again on the new board entry: parked again with the
# new bid and 1 new comment for the new board state
[ "$(cut -f1 "$PARK" 2>/dev/null)" = "$(bid_of 421)" ] && ok || bad "(D5) re-parked on the new bid"
[ "$(ncm)" = 2 ] && ok || bad "(D5) one comment per board state: $(ncm)"
tick
[ "$(ncalls)" = 2 ] && ok || bad "(D5) the tick after the re-park started the shard"

# D6: an edited body (a new title/updatedAt, the same comment count): 1 launch
gate 2026-11-19T10:00:00Z 4 "ticket 421 (edited)"
tick
[ "$(ncalls)" = 3 ] && ok || bad "(D6) an edited body must start the shard 1 time ($(ncalls))"

# D4: rebase=1 and a moved bid (our own comment): still parked, rebase=0, 0 launches
fresh; B0=$(bid_of 421)
mkdir -p "$RD"; printf '%s\t%s\t%s\t1\ttriage-repeat-refused: x\n' "$B0" cgfp "$(date +%s)" > "$PARK"
gate 2026-11-18T11:00:00Z 4
tick
[ "$(ncalls)" = 0 ] && ok || bad "(D4) our own comment unparked the key ($(ncalls) launches)"
[ "$(cut -f4 "$PARK" 2>/dev/null)" = 0 ] && ok || bad "(D4) rebase not cleared: [$(cat "$PARK" 2>/dev/null)]"
[ "$(cut -f1 "$PARK" 2>/dev/null)" = "$(bid_of 421)" ] && ok || bad "(D4) the bid was not moved to the new entry"
# ... and the next move after that is a human one: unpark
gate 2026-11-18T12:00:00Z 5
tick
[ "$(ncalls)" = 1 ] && ok || bad "(D4) the move after the rebase must unpark ($(ncalls))"

# D7: near misses — a park for 4210 does not park 421; a corrupt park dispatches;
# no gate file dispatches
fresh
mkdir -p "$RD"; printf '%s\tx\t%s\t0\ttriage-repeat-refused: x\n' "$(bid_of 4210)" "$(date +%s)" > "$RD/4210.park"
AC=ok tick
[ "$(ncalls)" = 1 ] && ok || bad "(D7) a park of 4210 stopped 421 ($(ncalls))"
fresh
mkdir -p "$RD"; printf 'not-a-bid\tx\n' > "$PARK"
AC=ok tick
[ "$(ncalls)" = 1 ] && ok || bad "(D7) a corrupt park file must dispatch ($(ncalls))"
fresh
mkdir -p "$RD"; printf '%s\tx\t%s\t0\ttriage-repeat-refused: x\n' "$(bid_of 421)" "$(date +%s)" > "$PARK"
rm -f "$S/state/$RP.gate.pending" "$S/state/$RP.gate.json"
AC=ok tick
[ "$(ncalls)" = 1 ] && ok || bad "(D7) no gate file must dispatch ($(ncalls))"

# D8: a park older than TRIAGE_REPEAT_PARK_KEEP_S is pruned: dispatch
fresh
mkdir -p "$RD"; printf '%s\tx\t%s\t0\ttriage-repeat-refused: x\n' "$(bid_of 421)" "$(date +%s)" > "$PARK"
touch -d '3 days ago' "$PARK"
( export TRIAGE_REPEAT_PARK_KEEP_S=86400; AC=ok tick )
[ "$(ncalls)" = 1 ] && ok || bad "(D8) a park past the keep window must dispatch ($(ncalls))"
[ -e "$PARK" ] && bad "(D8) the old park file was not pruned" || ok
# D8b: inside the window it holds
fresh
mkdir -p "$RD"; printf '%s\tx\t%s\t0\ttriage-repeat-refused: x\n' "$(bid_of 421)" "$(date +%s)" > "$PARK"
touch -d '3 days ago' "$PARK"
AC=ok tick
[ "$(ncalls)" = 0 ] && ok || bad "(D8b) a 3-day park inside the 30-day window dispatched ($(ncalls))"
# D9: TRIAGE_REPEAT_PARK=0: the dispatcher ignores a park file
( export TRIAGE_REPEAT_PARK=0; AC=ok tick )
[ "$(ncalls)" = 1 ] && ok || bad "(D9) TRIAGE_REPEAT_PARK=0 must dispatch ($(ncalls))"

# ═══ V ═══════════════════════════════════════════════════════════════════════
[ ! -s "$T/calls/vendor" ] && ok || bad "(V1) 0 vendor calls: [$(cat "$T/calls/vendor")]"
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  # The limit lives in bin/lib/call-guard.sh; bin/agent-call.sh only sources
  # it and applies its knob rows. So call-guard.sh must not differ at all, and
  # agent-call.sh must not change a line that names the call guard. Other
  # agent-call.sh edits (later tickets) are not this suite's subject.
  [ -z "$(git -C "$DIR" diff origin/main -- bin/lib/call-guard.sh 2>/dev/null)" ] \
    && [ -z "$(git -C "$DIR" diff -U0 origin/main -- bin/agent-call.sh 2>/dev/null \
                | grep -E '^[-+][^-+]' | grep -iE 'call[-_ ]?guard|CG_[A-Z]' )" ] && ok \
    || bad "(V2) the call-guard limit changed (bin/lib/call-guard.sh, or a call-guard line of bin/agent-call.sh, differs from origin/main)"
else
  echo "note: (V2) skipped: no origin/main"
fi

echo "triage-repeat-refused.bh-9818: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
