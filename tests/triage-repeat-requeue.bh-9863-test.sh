#!/bin/bash
# tests/triage-repeat-requeue.bh-9863-test.sh — BH-9863: a key the call guard
# parked as a repeat (bin/lib/triage-repeat-park.sh) is unparked when its
# queue state changes (the blocker's build ends, its PR merges), not only when
# its board entry changes; and the per-ticket triage fingerprint of a deferred
# key sees its blocker (bin/lib/triage-shards-lib.sh).
#
# project-3, 2026-11-20: TK-773 and TK-767 ended `AGENT_CALL_REFUSED call-guard
# repeat triage-shard paid=2/2`. The park lifts only on a board-entry change,
# so the ticket stayed queued after its blocker merged, with no launch.
#
#   Q1     tick 1 is refused as a repeat: the park has column 6 = 16 hex, and
#          trp_reason reads the same reason as before
#   Q2     tick 2 unchanged: 0 calls. The blocker gets PR_MERGED: tick 3
#          unparks (log line, .park gone, .commented kept) and the shard runs
#          1 time and launches. 0 new comments.
#   Q3-Q6  a queue-line reword, a queue-row rewrite, another key's record and
#          a BH-4200 record (prefix of the blocker BH-420) each give 0 calls
#   Q7     a 5-column park (before BH-9863) stays parked with 0 calls
#   F1     triage_shard_fp moves for a deferred key when its blocker changes,
#          and is byte-identical to origin/main for a key with no deferral
#   P1     the blocker PR number reaches the triage_prstates_refresh want list
#   V1     0 vendor calls
#
# The tests/triage-repeat-refused.bh-9818 D-rig: the REAL rt_shards
# (bin/lib/rt/shards.sh) launches the REAL bin/triage-shard.sh, agent-call is
# stubbed with a call counter.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/triage-repeat-requeue.bh-9863-test.sh
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
  launch)     printf 'tickets=1 new=0 changed=1 built=1\nDECISION: 421 :: launch :: blocker BH-420 merged\n' > "$5"
              echo "${AGENT_CALL_TICKET:-?}" >> "$FX/launches"; exit 0 ;;
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
RP=project-6-os-t9863
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


# ═══ the D-rig tick (tests/triage-repeat-refused.bh-9818) ═══════════════════
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
nlaunch() { local n; n=$(grep -cx "${1:-421}" "$FX/launches" 2>/dev/null); echo "${n:-0}"; }
TS='board changed: CHANGED 421 "ticket 421" (comments: 2 -> 3)'
QD='BH-421 (target fly, attempt 2, queued 2026-11-18T09:00:00Z)'
BREC="$S/builds/$RP-BH-421-s1"
ARECD="$S/builds/$RP-BH-420-s1"
deferred() { # 421's newest record waits on BH-420; BH-420 has an open PR
  mkdir -p "$BREC" "$ARECD"
  printf 'BUILD_DEFERRED OVERLAP_DEFER BH-421 vs BH-420 files=[app/x.ts]\n' > "$BREC/RESULT"
  printf 'PR_CREATED https://github.com/o/r/pull/900\n' > "$ARECD/RESULT"
  touch -d '1 hour ago' "$BREC/RESULT" "$ARECD/RESULT"
}
cleanb() { scratch_rm "$S/builds"; mkdir -p "$S/builds"; rm -f "$S/state/merge-sweep-done.txt"; }

# ── Q1: the park carries the queue-state signature ───────────────────────
fresh; cleanb; deferred
tick
[ "$(ncalls)" = 1 ] && [ -f "$PARK" ] && ok || bad "(Q1) tick 1 runs 1 shard and parks ($(ncalls) calls, park: $([ -f "$PARK" ] && echo y || echo n))"
Q6COL=$(cut -f6 "$PARK" 2>/dev/null)
[[ "$Q6COL" =~ ^[0-9a-f]{16}$ ]] && ok || bad "(Q1) park column 6 is a 16-hex qsig: [$(tr '\t' '|' < "$PARK" 2>/dev/null)]"
R5=$( ( . "$S/bin/lib/triage-repeat-park.sh"; trp_reason "$S" "$RP" 421 ) 2>/dev/null)
case "$R5" in "triage-repeat-refused: AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2"*) ok ;;
  *) bad "(Q1) trp_reason still reads column 5: [$R5]" ;; esac
[ "$(cut -f5 "$PARK" | cut -c1-21)" = triage-repeat-refused ] && ok || bad "(Q1) column 5 is the reason"

# ── Q2: unchanged stays parked; the blocker merges: unpark and launch ────
tick
[ "$(ncalls)" = 1 ] && ok || bad "(Q2) tick 2, unchanged: 0 new calls ($(ncalls) total)"
grep -q "triage-repeat: 421 unparked" "$S/logs/$RP.log" && bad "(Q2) an unchanged world unparked" || ok
printf 'PR_MERGED https://github.com/o/r/pull/900\n' > "$ARECD/RESULT"
echo "https://github.com/o/r/pull/900" >> "$S/state/merge-sweep-done.txt"
AC=launch tick
[ "$(ncalls)" = 2 ] && ok || bad "(Q2) THE BUG: the blocker merged: tick 3 must run the shard 1 time ($(ncalls) total)"
[ "$(nlaunch)" = 1 ] && ok || bad "(Q2) tick 3 launches 421 1 time ($(nlaunch))"
grep -q "triage-repeat: 421 unparked: queue state changed (blocker or build record moved)" "$S/logs/$RP.log" && ok \
  || bad "(Q2) the unpark line: [$(grep triage-repeat "$S/logs/$RP.log" | tail -2)]"
[ ! -e "$PARK" ] && ok || bad "(Q2) the unpark line is written only with the .park gone"
[ -e "$RD/421.commented" ] && ok || bad "(Q2) .commented stays, so the same board state gets no second comment"
[ "$(ncm)" = 1 ] && ok || bad "(Q2) 0 new comments after the park ($(ncm) total)"

# ── Q3-Q6: no paid call for an unchanged input ───────────────────────────
q_case() { # q_case <id> <what> <command>
  fresh; cleanb; deferred
  tick
  [ -f "$PARK" ] || { bad "$1: setup: no park"; return; }
  eval "$3"
  tick
  [ "$(ncalls)" = 1 ] && [ -f "$PARK" ] && ok || bad "$1: $2 must not unpark ($(ncalls) calls)"
}
q_case Q3 "a reworded queue line" 'printf "BH-421 still waiting on PR #900 (reworded)\n" >> "$SQ"'
q_case Q4 "a rewritten queue row" 'QD="BH-421 (target fly, attempt 3, queued 2026-11-18T10:00:00Z)"'
q_case Q5 "another key's record" 'mkdir -p "$S/builds/$RP-BH-4210-s1"; echo "PR_MERGED https://github.com/o/r/pull/901" > "$S/builds/$RP-BH-4210-s1/RESULT"'
q_case Q6 "a BH-4200 record (BH-420 is its prefix)" 'mkdir -p "$S/builds/$RP-BH-4200-s1"; echo "PR_MERGED https://github.com/o/r/pull/900" > "$S/builds/$RP-BH-4200-s1/RESULT"'

# ── Q7: a park from before BH-9863 (5 columns) ───────────────────────────
fresh; cleanb; deferred
mkdir -p "$RD"; printf '%s\tx\t%s\t0\ttriage-repeat-refused: x\n' "$(bid_of 421)" "$(date +%s)" > "$PARK"
printf 'PR_MERGED https://github.com/o/r/pull/900\n' > "$ARECD/RESULT"
AC=ok tick
[ "$(ncalls)" = 0 ] && [ -f "$PARK" ] && ok || bad "(Q7) a 5-column park stays parked ($(ncalls) calls)"

# ── F1 / P1: the fingerprint and the prstates want list ──────────────────
FH="$T/fh"; FP=project-6-os-f9863
mkdir -p "$FH/bin/lib" "$FH/builds" "$FH/state" "$FH/logs"
scratch_install_closure bin/lib/triage-shards-lib.sh "$FH" >/dev/null 2>&1 || bad "(F1) install triage-shards-lib.sh"
for L in bin/lib/wait-sig.sh bin/lib/defer-after-stop.sh bin/lib/deferral-after.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$FH" ) >/dev/null 2>&1 || bad "(F1) install $L"
done
printf '#!/bin/bash\ncase "$2" in repo) echo o/r ;; board_prefix) echo - ;; esac\nexit 0\n' > "$FH/bin/fleet-conf.sh"; chmod +x "$FH/bin/fleet-conf.sh"
printf 'BH-421\tqueue\tBH-421 waiting\nBH-77\tqueue\tBH-77 waiting\n' | sed 's/^BH-//' > "$FH/u.tsv"
fpof() { ( . "$FH/bin/lib/triage-shards-lib.sh"; triage_shard_fp "$FH" "$FP" "$1" 1 "$FH/u.tsv" ) 2>/dev/null; }
mkdir -p "$FH/builds/$FP-BH-421-s1" "$FH/builds/$FP-BH-420-s1" "$FH/builds/$FP-BH-77-s1"
printf 'BUILD_DEFERRED OVERLAP_DEFER BH-421 vs BH-420 files=[a]\n' > "$FH/builds/$FP-BH-421-s1/RESULT"
printf 'PR_CREATED https://github.com/o/r/pull/900\n' > "$FH/builds/$FP-BH-420-s1/RESULT"
printf 'BUILD_FAILED tests red\n' > "$FH/builds/$FP-BH-77-s1/RESULT"
F0=$(fpof 421); F77=$(fpof 77)
printf 'PR_MERGED https://github.com/o/r/pull/900\n' > "$FH/builds/$FP-BH-420-s1/RESULT"
F1=$(fpof 421)
[[ "$F0" =~ ^[0-9a-f]{16}$ ]] && [ "$F0" != "$F1" ] && ok || bad "(F1) the deferred key's fp moves when its blocker merges ('$F0' -> '$F1')"
[ "$(fpof 77)" = "$F77" ] && ok || bad "(F1) a key with no deferral: the blocker change does not move its fp"
if git -C "$DIR" cat-file -e origin/main:bin/lib/triage-shards-lib.sh 2>/dev/null; then
  git -C "$DIR" show origin/main:bin/lib/triage-shards-lib.sh > "$T/tsl-main.sh"
  FM=$( ( . "$T/tsl-main.sh"; triage_shard_fp "$FH" "$FP" 77 1 "$FH/u.tsv" ) 2>/dev/null)
  [ -n "$FM" ] && [ "$FM" = "$F77" ] && ok || bad "(F1) a key with no deferral keeps origin/main's fp byte for byte ('$FM' vs '$F77')"
else
  echo "note: (F1) origin/main compare skipped: no origin/main"
fi
P1=$( ( . "$FH/bin/lib/triage-shards-lib.sh"
        gh_rest_pr_state_var() { echo "$3" >> "$T/p1.nums"; printf -v "$1" %s open; return 0; }
        gh_auth_for() { return 1; }; _tsh_gh_budget_low() { return 1; }
        : > "$T/p1.nums"; printf 'PR_CREATED https://github.com/o/r/pull/900\n' > "$FH/builds/$FP-BH-420-s1/RESULT"
        triage_prstates_refresh "$FH" "$FP" "$FH/u.tsv"; tr '\n' ' ' < "$T/p1.nums" ) 2>/dev/null)
[ "$P1" = "900 " ] && ok || bad "(P1) the blocker PR 900 is refreshed once per tick, got [$P1]"

[ ! -s "$T/calls/vendor" ] && ok || bad "(V1) 0 vendor calls: [$(cat "$T/calls/vendor")]"
echo "triage-repeat-requeue.bh-9863: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
