#!/bin/bash
# tests/queue-sweep-dead-tickets.bh-9818-test.sh — BH-9818: the queue units of
# dead tickets (lifecycle phase plan_blocked, abandoned or closed, or a
# SUPERSEDED newest build dir) leave triage shard scope, with 1 log line per
# removal; a live ticket's line stays.
#
#   Q1-Q10, Q12  qds_sweep (bin/lib/queue-dead-sweep.sh) on a scratch harness;
#                the jobs worker is a fake _jobs_req that answers from $FX and
#                counts its reads; bin/queue-line-drop.sh is the REAL script.
#   Q11          the REAL rt_shards (bin/lib/rt/shards.sh): 1 dead and 1 live
#                key, only the live key's shard is launched.
#   V            0 vendor calls
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/queue-sweep-dead-tickets.bh-9818-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
export HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1
unset QUEUE_DEAD_SWEEP QUEUE_DEAD_SWEEP_MAX_READS TRIAGE_REPEAT_PARK QUEUE_CLOSED_DROP

mkdir -p "$T/rbin" "$T/calls"
for v in gh claude curl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls/vendor"\nexit 1\n' "$v" "$T" > "$T/rbin/$v"
done
printf '#!/bin/bash\nexec "$@"\n' > "$T/rbin/setsid"
chmod +x "$T/rbin/"*
export PATH="$T/rbin:$PATH"

H="$T/h"; FX="$T/fx"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/builds" "$FX"
scratch_install_closure bin/queue-line-drop.sh "$H" >/dev/null 2>&1 || bad "install bin/queue-line-drop.sh"
scratch_install_closure bin/lib/queue-dead-sweep.sh "$H" >/dev/null 2>&1 || bad "install bin/lib/queue-dead-sweep.sh"
printf 'rq_drop() { shift 2; printf "%%s\\n" "$*" >> "%s/rqdrop"; }\n' "$FX" > "$H/bin/lib/ready-queue.sh"
# The jobs worker: the list read answers $FX/list.json (rc from $FX/list.rc),
# a PK read answers $FX/key-<label>.json (no file = no row). Every read counted.
cat > "$H/bin/jobs-client.sh" <<STUB
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$FX/reads"
  case "\$2" in
    *status=queued*) [ "\$(cat "$FX/list.rc" 2>/dev/null || echo 0)" = 0 ] || return 1; cat "$FX/list.json" 2>/dev/null ;;
    *key=*) local k=\${2#*key=}; k=\${k%%&*}; cat "$FX/key-\$k.json" 2>/dev/null || echo '{"queue":[]}' ;;
  esac
}
queue_done() { printf '%s\n' "\$*" >> "$FX/qdone"; }
STUB
cat > "$H/bin/fleet-conf.sh" <<'STUB'
#!/bin/bash
[ "${1:-}" = --projects-on-box ] && echo onlyone
exit 0
STUB
cat > "$H/bin/triage-shard.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$2" >> "$FX/shard-\$1"
STUB
chmod +x "$H/bin/"*.sh
QF="$H/logs/READY-QUEUE.log"
export HARNESS="$H" FX
P=project-6-os

# row <key> <phase|null> — one build_queue row
row() { if [ "$2" = null ]; then jq -nc --arg k "$1" '{ticket_key:$k,status:"queued",phase:null}'
        else jq -nc --arg k "$1" --arg ph "$2" '{ticket_key:$k,status:"queued",phase:$ph}'; fi; }
list() { { for r in "$@"; do row "${r%%:*}" "${r#*:}"; done; } | jq -sc '{queue:.}' > "$FX/list.json"; }
newc() {
  scratch_rm "$FX"; mkdir -p "$FX"; scratch_rm "$H/builds"; mkdir -p "$H/builds"
  rm -f "$H/logs/$P.log"; : > "$QF"; U="$T/units"; : > "$U"
}
unit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$U"; }   # unit <key> <class> <text>
sweep() { OUT=$( . "$H/bin/jobs-client.sh"; . "$H/bin/lib/queue-dead-sweep.sh"; qds_sweep "$H" "$P" "$U" 1 ); }
has() { awk -F'\t' -v k="$1" -v c="$2" '$1==k && $2==c {f=1} END{exit !f}' "$U"; }
nlog() { local n; n=$(grep -c "queue-dead-sweep: removed $1 " "$H/logs/$P.log" 2>/dev/null); echo "${n:-0}"; }

# ═══ Q1-Q5: the four dead kinds ═════════════════════════════════════════════
newc
list TK-3819:plan_blocked TK-3720:abandoned TK-3815:closed TK-3814:in_queue TK-3799:in_queue
printf 'TK-3819 waiting on plan\nMK-3814 waiting on PR #3811\nMK-3799 waiting on PR #3800\n' > "$QF"
unit 3819 queue 'TK-3819 (target fly, attempt 2, queued 2026-11-12T00:00:00Z)'
unit 3819 queue 'TK-3819 waiting on plan'
unit 3720 queue 'TK-3720 (target fly, attempt 1, queued 2026-11-10T00:00:00Z)'
unit 3815 queue 'TK-3815 (target fly, attempt 1, queued 2026-11-11T00:00:00Z)'
unit 3814 queue 'TK-3814 (target fly, attempt 3, queued 2026-11-18T00:00:00Z)'
unit 3814 queue 'TK-3814 waiting on PR #3811'
unit 3799 queue 'TK-3799 (target fly, attempt 1, queued 2026-11-18T00:00:00Z)'
unit 3799 queue 'TK-3799 waiting on PR #3800'
mkdir -p "$H/builds/$P-TK-3814-202611170900" "$H/builds/$P-TK-3814-202611180900"
: > "$H/builds/$P-TK-3814-202611180900/SUPERSEDED"
sweep
# Q1 plan_blocked: units gone, READY line dropped
has 3819 queue && bad "(Q1) a plan_blocked key kept its queue units" || ok
grep -q '^TK-3819 ' "$QF" && bad "(Q1) the plan_blocked READY line stayed" || ok
grep -qx 'TK-3819' "$FX/rqdrop" 2>/dev/null && ok || bad "(Q1) the ready-row drop was not asked for TK-3819"
# Q2 abandoned
has 3720 queue && bad "(Q2) an abandoned key kept its units" || ok
# Q3 closed: removed, and the row set failed
has 3815 queue && bad "(Q3) a closed key kept its units" || ok
grep -qx "$P TK-3815 failed queue-dead-sweep: ticket closed" "$FX/qdone" 2>/dev/null && ok \
  || bad "(Q3) queue_done failed for the closed row: [$(cat "$FX/qdone" 2>/dev/null)]"
[ "$(grep -c . "$FX/qdone" 2>/dev/null)" = 1 ] && ok || bad "(Q3) queue_done only for the closed phase: [$(cat "$FX/qdone" 2>/dev/null)]"
# Q4 superseded (the newest build dir)
has 3814 queue && bad "(Q4) a superseded key kept its units" || ok
grep -q '^TK-3814 ' "$QF" && bad "(Q4) the superseded READY line stayed" || ok
# Q7 (live): TK-3799 in_queue stays, its line too
has 3799 queue && ok || bad "(Q7) a live in_queue key lost its units"
grep -q '^TK-3799 ' "$QF" && ok || bad "(Q7) a live ticket's READY line was dropped"
# Q5 one log line per removed label
for l in TK-3819 TK-3720 TK-3815 TK-3814; do
  [ "$(nlog "$l")" = 1 ] && ok || bad "(Q5) want 1 'removed $l' line, got $(nlog "$l")"
done
[ "$(grep -c 'queue-dead-sweep: removed ' "$H/logs/$P.log")" = 4 ] && ok || bad "(Q5) 4 removal lines in all: [$(grep queue-dead-sweep "$H/logs/$P.log")]"
grep -q 'queue-dead-sweep: removed TK-3819 (plan_blocked)' "$H/logs/$P.log" && ok || bad "(Q5) the line names the phase"
grep -q 'queue-dead-sweep: removed TK-3814 (superseded)' "$H/logs/$P.log" && ok || bad "(Q5) the line says superseded"
[ "$OUT" = " TK-3819 TK-3720 TK-3815 TK-3814" ] && ok || bad "(Q1-Q4) the printed labels: [$OUT]"
# bounded: 1 list read, 0 PK reads (every label was in the list)
[ "$(grep -c 'status=queued' "$FX/reads")" = 1 ] && ok || bad "(reads) one list read: [$(cat "$FX/reads")]"
grep -q 'key=' "$FX/reads" && bad "(reads) a PK read for a listed label: [$(cat "$FX/reads")]" || ok

# ═══ Q6: queue-line-drop.sh fails ═══════════════════════════════════════════
newc
list TK-3819:plan_blocked
unit 3819 queue 'TK-3819 waiting on plan'
cp "$H/bin/queue-line-drop.sh" "$T/qld.real"
printf '#!/bin/bash\necho "could not lock" >&2\nexit 1\n' > "$H/bin/queue-line-drop.sh"
sweep
cp "$T/qld.real" "$H/bin/queue-line-drop.sh"
has 3819 queue && ok || bad "(Q6) a failed drop removed the unit"
grep -q 'queue-dead-sweep: drop failed for TK-3819' "$H/logs/$P.log" && ok || bad "(Q6) the log says drop failed"
[ "$(nlog TK-3819)" = 0 ] && ok || bad "(Q6) the log claims a removal"
[ -z "$OUT" ] && ok || bad "(Q6) printed [$OUT]"

# ═══ Q7: live phases and near misses all stay ═══════════════════════════════
newc
list TK-1:ejected TK-2:in_queue TK-3:building TK-4:planned TK-5:null TK-7:triaged TK-3814:in_queue
for k in 1 2 3 4 5 7; do unit "$k" queue "TK-$k (target fly, attempt 1, queued 2026-11-18T00:00:00Z)"; done
unit 6 queue 'TK-6 waiting on review'                 # no row at all
echo '{"queue":[]}' > "$FX/key-TK-6.json"
unit 3814 queue 'TK-3814 waiting on PR #3811'         # SUPERSEDED only in an OLDER dir
mkdir -p "$H/builds/$P-TK-3814-202611170900" "$H/builds/$P-TK-3814-202611180900"
: > "$H/builds/$P-TK-3814-202611170900/SUPERSEDED"
unit 38 queue 'TK-38 waiting on review'               # TK-38 beside TK-3814
jq -nc '{queue:[{ticket_key:"TK-38",status:"ready",phase:"building",reason:"was plan_blocked"}]}' > "$FX/key-TK-38.json"
cp "$U" "$T/units.before"
sweep
cmp -s "$U" "$T/units.before" && ok || bad "(Q7) a live or near-miss unit was removed: [$(diff "$T/units.before" "$U")]"
grep -q 'queue-dead-sweep: removed' "$H/logs/$P.log" 2>/dev/null && bad "(Q7) a removal was logged: [$(grep queue-dead-sweep "$H/logs/$P.log")]" || ok
[ -z "$OUT" ] && ok || bad "(Q7) printed [$OUT]"
[ ! -s "$FX/qdone" ] && ok || bad "(Q7) queue_done was called"

# ═══ Q8: the list read fails: every unit kept, 1 log line ═══════════════════
newc
echo 1 > "$FX/list.rc"
unit 3819 queue 'TK-3819 waiting on plan'
mkdir -p "$H/builds/$P-TK-3819-202611180900"; : > "$H/builds/$P-TK-3819-202611180900/SUPERSEDED"
cp "$U" "$T/units.before"
sweep
cmp -s "$U" "$T/units.before" && ok || bad "(Q8) an outage removed a unit"
[ "$(grep -c 'queue-dead-sweep: the queue list read failed' "$H/logs/$P.log")" = 1 ] && ok || bad "(Q8) one outage log line"
# Q8b: a non-JSON answer is an outage too
newc
printf 'Bad Gateway' > "$FX/list.json"
unit 3819 queue 'TK-3819 waiting on plan'
cp "$U" "$T/units.before"
sweep
cmp -s "$U" "$T/units.before" && ok || bad "(Q8b) a non-JSON list removed a unit"

# ═══ Q9: board and result rows of a dead key stay ═══════════════════════════
newc
list TK-3819:plan_blocked
unit 3819 board 'board changed: CHANGED 3819 "x" (comments: 4 -> 5)'
unit 3819 queue 'TK-3819 (target fly, attempt 2, queued 2026-11-12T00:00:00Z)'
unit 3819 result 'pool-project-6-os-TK-3819-1 RESULT: PLAN_BLOCKED'
sweep
has 3819 queue && bad "(Q9) the queue unit stayed" || ok
has 3819 board && ok || bad "(Q9) the board unit of a dead key was removed"
has 3819 result && ok || bad "(Q9) the result unit of a dead key was removed"

# ═══ Q10: PK reads past QUEUE_DEAD_SWEEP_MAX_READS are kept and counted ═════
newc
list
for k in 11 12 13 14; do
  unit "$k" queue "TK-$k waiting on review"
  jq -nc --arg k "TK-$k" '{queue:[{ticket_key:$k,status:"ready",phase:"plan_blocked"}]}' > "$FX/key-TK-$k.json"
done
( export QUEUE_DEAD_SWEEP_MAX_READS=2; sweep; printf '%s' "$OUT" > "$FX/out" )
[ "$(grep -c 'key=' "$FX/reads")" = 2 ] && ok || bad "(Q10) want 2 PK reads, got [$(cat "$FX/reads")]"
[ "$(cat "$FX/out")" = " TK-11 TK-12" ] && ok || bad "(Q10) the read labels go: [$(cat "$FX/out")]"
has 13 queue && has 14 queue && ok || bad "(Q10) labels past the cap were removed"
grep -q 'queue-dead-sweep: 2 label(s) past QUEUE_DEAD_SWEEP_MAX_READS=2 not read this tick' "$H/logs/$P.log" && ok \
  || bad "(Q10) the deferred count is logged: [$(grep queue-dead-sweep "$H/logs/$P.log")]"

# ═══ Q12: QUEUE_DEAD_SWEEP=0: no read, nothing removed ══════════════════════
newc
list TK-3819:plan_blocked
unit 3819 queue 'TK-3819 waiting on plan'
( export QUEUE_DEAD_SWEEP=0; sweep )
[ ! -s "$FX/reads" ] && ok || bad "(Q12) the knob off still read: [$(cat "$FX/reads")]"
has 3819 queue && ok || bad "(Q12) the knob off removed a unit"

# ═══ Q11: the real rt_shards — 1 dead, 1 live key ═══════════════════════════
newc
list TK-3819:plan_blocked TK-3799:in_queue
shards() {
  ( set +u
    PROJECT=$P; STAMP="t"; LOG="$H/logs/$P.log"; ALERTS="$H/logs/ALERTS.log"
    GATE_DECISION="RUN queue"; GATE_REASON=queue; SCOPE_N=queue
    TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; RDIRS=""
    QDIRS=$'TK-3819 (target fly, attempt 2, queued 2026-11-12T00:00:00Z)\nMK-3799 (target fly, attempt 1, queued 2026-11-18T00:00:00Z)'
    JOB_ID=""; PROMPT_TEXT="SOP"; TRIAGE_MODEL=m; SHARD_SOP="SOP"; EFFECTIVE_GROK_EFFORT=""
    LANE_TICK() { :; }; rt_gate_consume() { :; }
    . "$H/bin/jobs-client.sh"
    . "$DIR/bin/lib/triage-shards-lib.sh"
    triage_shards_on() { echo 1; }; triage_shard_gh() { echo 1; }; triage_shard_fp_ttl() { echo 3600; }
    triage_shards_max() { echo 0; }; triage_caps_on() { echo 0; }
    triage_prstates_ingest() { :; }; triage_prstates_refresh() { :; }; triage_prstates_prune() { :; }
    triage_shard_fp() { echo "fp-$3"; }; triage_shard_fp_fresh() { return 1; }
    triage_shard_fp_put() { :; }; triage_shard_rearm() { :; }; triage_throttle_record() { :; }
    lock_spawn_unheld() { "$@"; }
    . "$DIR/bin/lib/rt/shards.sh"
    rt_shards ) >/dev/null 2>&1
}
shards
[ "$(tr '\n' ' ' < "$FX/shard-$P" 2>/dev/null)" = "3799 " ] && ok \
  || bad "(Q11) only the live key gets a shard: [$(tr '\n' ' ' < "$FX/shard-$P" 2>/dev/null)]"
S11=$(grep "dispatched .* shards:" "$H/logs/$P.log" 2>/dev/null | tail -1)
case "$S11" in *" — dead: TK-3819"*) ok ;; *) bad "(Q11) the summary names the dead label: [$S11]" ;; esac
[ "$(nlog TK-3819)" = 1 ] && ok || bad "(Q11) one removal line through rt_shards"
# Q11b: the knob off through rt_shards: both keys get a shard
newc
list TK-3819:plan_blocked TK-3799:in_queue
( export QUEUE_DEAD_SWEEP=0; shards )
[ "$(tr '\n' ' ' < "$FX/shard-$P" 2>/dev/null)" = "3819 3799 " ] && ok \
  || bad "(Q11b) QUEUE_DEAD_SWEEP=0 dispatches both: [$(tr '\n' ' ' < "$FX/shard-$P" 2>/dev/null)]"

[ ! -s "$T/calls/vendor" ] && ok || bad "(V) 0 vendor calls: [$(cat "$T/calls/vendor")]"

echo "queue-sweep-dead-tickets.bh-9818: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
