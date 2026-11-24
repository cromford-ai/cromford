#!/bin/bash
# tests/stuckqueue-gate.bh-9863-test.sh — BH-9863: the pipeline-health
# stuckqueue alert names the gate that holds the ticket (bin/lib/stuckqueue-gate.sh),
# and bin/stuckqueue-why.sh prints the same gate for an operator.
#
# project-3, 2026-11-20: 6 ready tickets queued for up to 13 h, and every alert
# said only "fly-dispatch/pool not picking it up".
#
#   K1      the REAL `stuck queue` block (extracted between its markers, alert()
#           stubbed): an OVERLAP_DEFER record gives "held by overlap-defer:"
#   K2-K16  the classifier table, with near misses (TK-7670 vs TK-767, a
#           foreign .held why, the newest of two pool lines wins)
#   K17     the infra.sh capture regex still reads p, key and min
#   K18     the alert key is unchanged (the 7200 s dedupe keys on it)
#   K19     no lib: the old exact tail; unknown gate: old tail + (gate unknown: ...)
#   K20     the STUCKQUEUE_GATE_LOG_TAIL_KB knob: unset 2048, x 2048, 32 -> 64
#   K21     the escalate message ends " Gate: <gate>: <detail>."
#   C1-C3   bin/stuckqueue-why.sh prints the same gate as sqg_gate, 3 keys
#   V1      0 network: no gh, curl or fly is called
# Run: HARNESS_TEST_SANDBOX=1 bash tests/stuckqueue-gate.bh-9863-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
mkdir -p "$T/rbin"
for v in gh curl fly flyctl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/vendor"\nexit 1\n' "$v" "$T" > "$T/rbin/$v"
done
chmod +x "$T/rbin/"*
export PATH="$T/rbin:$PATH"
unset STUCKQUEUE_GATE_LOG_TAIL_KB STUCKQUEUE_ESCALATE_AFTER

P=project-3
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/state/build-queue/$P" "$H/state/pool/$P" "$H/state/triage-repeat/$P" "$H/builds"
LIBS_OK=1
for L in bin/lib/stuckqueue-gate.sh bin/lib/wait-sig.sh bin/lib/stuckqueue-escalate.sh bin/stuckqueue-why.sh; do
  [ -f "$DIR/$L" ] || { bad "$L is missing"; LIBS_OK=0; continue; }
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || { bad "install $L"; LIBS_OK=0; }
done
NOW=$(date -u +%s)
OLD=$((NOW - 3 * 3600))
qfile() { : > "$H/state/build-queue/$P/$1.json"; touch -d "@$OLD" "$H/state/build-queue/$P/$1.json"; }
rec() { # rec <KEY> <stamp> <age-s> <line>
  local d="$H/builds/pool-$P-$1-$2"; mkdir -p "$d"; printf '%s\n' "$4" > "$d/RESULT"; touch -d "@$((NOW - $3))" "$d/RESULT"
}
clean() {
  local x
  for x in "$H/state/pool/$P" "$H/state/triage-repeat/$P" "$H/builds" "$H/locks" "$H/state/build-queue/$P"; do
    scratch_rm "$x"; mkdir -p "$x"
  done
  : > "$H/logs/fly-pool.log"; : > "$H/logs/fly-dispatch.log"
}
gate() { ( unset -f sqg_gate; . "$H/bin/lib/stuckqueue-gate.sh" 2>/dev/null; command -v sqg_gate >/dev/null || exit 0; sqg_gate "$H" "$P" "$1" ) 2>/dev/null; }
gname() { gate "$1" | cut -f1; }
kcase() { # kcase <id> <KEY> <want gate> [<detail substring>]
  local g; g=$(gate "$2")
  [ "${g%%$'\t'*}" = "$3" ] && ok || bad "$1: $2 wants gate '$3', got '$g'"
  if [ -n "${4:-}" ]; then case "$g" in *"$4"*) ok ;; *) bad "$1: $2 detail wants '$4', got '$g'" ;; esac; fi
}

# ── the real block ───────────────────────────────────────────────────────
PH="$DIR/bin/pipeline-health.sh"
awk '/^# >>> stuck queue/{f=1;next} /^# <<< stuck queue/{exit} f' "$PH" > "$T/block.sh"
grep -q 'stuckqueue:' "$T/block.sh" && ok || bad "the extracted block is not the stuck-queue check"
drive() { # drive [nolib]
  : > "$T/alerts.txt"
  ( alert() { printf '%s\t%s\n' "$2" "$3" >> "$T/alerts.txt"; }
    PROJECTS=$P
    [ "${1:-}" = nolib ] || . "$H/bin/lib/stuckqueue-gate.sh" 2>/dev/null
    # shellcheck disable=SC1090
    . "$T/block.sh" ) 2>/dev/null
}
aline() { grep "^stuckqueue:$P:$1.json	" "$T/alerts.txt" | cut -f2; }

# ── K1: the alert names overlap-defer ────────────────────────────────────
clean; qfile TK-774
rec TK-774 s1 600 "BUILD_DEFERRED OVERLAP_DEFER TK-774 vs TK-758 files=[app/x.ts]"
drive
case "$(aline TK-774)" in
  "$P TK-774 queued 180m with no spawn — held by overlap-defer: pool-$P-TK-774-s1: OVERLAP_DEFER TK-774 vs TK-758 files=[app/x.ts]") ok ;;
  *) bad "K1: the alert names the gate: [$(aline TK-774)]" ;;
esac

# ── K2-K16: the classifier ───────────────────────────────────────────────
clean
mkdir -p "$H/state/pool/$P"
printf '{"key":"TK-1","why":"defer-after: waits on TK-2 PR open (after)"}\n' > "$H/state/pool/$P/TK-1.held"
kcase K2 TK-1 defer-after "waits on TK-2"
printf '{"key":"TK-3","why":"hold: client review"}\n' > "$H/state/pool/$P/TK-3.held"
kcase K2b TK-3 hold "client review"
printf '{"key":"TK-4","why":"terminal: push rejected"}\n' > "$H/state/pool/$P/TK-4.held"
kcase K2c TK-4 pool-held "terminal: push rejected"
printf 'TK-2\tafter\t%s\t1\t%s\t\n' "$NOW" "$((NOW + 600))" > "$H/state/pool/$P/TK-5.dfs-wait"
kcase K3 TK-5 defer-after "waits on TK-2 since"
rec TK-6 s1 60 "BUILD_DEFERRED OVERLAP_DEFER TK-6 vs TK-2 files=[a]"
kcase K4 TK-6 overlap-defer "TK-6 vs TK-2"
printf '421\tfp\t%s\t0\ttriage-repeat-refused: AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2\n' "$NOW" > "$H/state/triage-repeat/$P/TK-773.park"
kcase K5 TK-773 call-guard-repeat-park "paid=2/2"
printf '421\tfp\t%s\t0\ttriage-repeat-refused: x\n' "$NOW" > "$H/state/triage-repeat/$P/767.park"
kcase K5b TK-767 call-guard-repeat-park "triage-repeat-refused: x"
: > "$H/locks/build-key-$P-TK-8.lock"
( exec 9>"$H/locks/build-key-$P-TK-8.lock"; flock 9; sleep 5 ) & LPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ( exec 9>"$H/locks/build-key-$P-TK-8.lock"; flock -n 9 ) 2>/dev/null || break
  sleep 0.1
done
kcase K6 TK-8 build-key-lock "build-key-$P-TK-8.lock"
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
kcase K6b TK-8 unknown
rec TK-9 s1 60 "BUILD_DEFERRED After: TK-2 PR #12 open — overlaps"
kcase K7 TK-9 after-wait "After: TK-2"
rec TK-10 s1 60 "BUILD_DEFERRED stack-wait: parent branch ticket/TK-2 is still open"
kcase K8 TK-10 stack-wait
rec TK-11 s1 60 "BUILD_DEFERRED REFUSED claim held by another box"
kcase K9 TK-11 claim-refused
rec TK-12 s1 60 "BUILD_DEFERRED hold unreadable at pr-open"
kcase K10 TK-12 deferred
rec TK-13 s1 60 "PR_CREATED https://github.com/o/r/pull/1"
kcase K10b TK-13 unknown
printf '2026-11-20 03:00:00Z [pool/%s] SIBLING_SERIAL TK-14 waits on its sibling TK-15\n' "$P" >> "$H/logs/fly-pool.log"
kcase K11 TK-14 sibling-serial "SIBLING_SERIAL TK-14"
printf '2026-11-20 03:01:00Z [pool/%s] POOL_SPAWN_CAP_WAIT TK-16 12/24h\n' "$P" >> "$H/logs/fly-pool.log"
kcase K12 TK-16 spawn-cap
printf '2026-11-20 03:02:00Z [pool/%s] refused claim of TK-17: claimed on pool-x\n' "$P" >> "$H/logs/fly-pool.log"
kcase K13 TK-17 pool-claim
# the newest of two lines on one key wins
printf '2026-11-20 03:03:00Z [pool/%s] SCHED TK-18 outside the window\n2026-11-20 03:04:00Z [pool/%s] TK-18 tick budget spent\n' "$P" "$P" >> "$H/logs/fly-pool.log"
kcase K14 TK-18 tick-budget
# TK-7670's line never classifies TK-767
clean
printf '2026-11-20 03:05:00Z [pool/%s] SCHED TK-7670 outside the window\n' "$P" >> "$H/logs/fly-pool.log"
kcase K15 TK-767 unknown
rec TK-7670 s1 60 "BUILD_DEFERRED OVERLAP_DEFER TK-7670 vs TK-2 files=[a]"
kcase K15b TK-767 unknown
printf '2026-11-20 03:06:00Z [fly-dispatch] overlap guard: TK-19 overlaps TK-2 on app/x.ts\n' >> "$H/logs/fly-dispatch.log"
kcase K16 TK-19 overlap-guard
printf '2026-11-20 03:07:00Z [%s] wip of 1 reached (FLY_DISPATCH_WIP=1)\n' "$P" >> "$H/logs/fly-dispatch.log"
kcase K16b TK-20 dispatcher-wip "wip of 1"

# ── K17: the infra.sh capture still parses the new line ─────────────────
clean; qfile TK-774
rec TK-774 s1 600 "BUILD_DEFERRED OVERLAP_DEFER TK-774 vs TK-758 files=[app/x.ts]"
drive
K17=$(printf '2026-11-20 04:00:00Z %s\n' "$(aline TK-774)" | jq -Rrc '
  capture("^(?<at>[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})Z (?<p>[A-Za-z0-9._-]+) (?<key>[A-Za-z0-9.-]+) queued (?<min>[0-9]+)m with no spawn") | "\(.p) \(.key) \(.min)"' 2>/dev/null)
[ "$K17" = "$P TK-774 180" ] && ok || bad "K17: the infra.sh capture wants '$P TK-774 180', got '$K17'"
REGEX_LINE=$(grep -c 'queued (?<min>\[0-9\]+)m with no spawn' "$DIR/bin/lib/unblock/collectors/infra.sh")
[ "$REGEX_LINE" -ge 1 ] && ok || bad "K17: the infra.sh capture regex moved; update this test"
# ── K18: the alert key ───────────────────────────────────────────────────
[ "$(cut -f1 "$T/alerts.txt")" = "stuckqueue:$P:TK-774.json" ] && ok || bad "K18: the alert key is unchanged: [$(cut -f1 "$T/alerts.txt")]"

# ── K19: no lib, and an unknown gate ─────────────────────────────────────
clean; qfile TK-30
drive nolib
[ "$(aline TK-30)" = "$P TK-30 queued 180m with no spawn — fly-dispatch/pool not picking it up" ] && ok \
  || bad "K19: no lib gives the old exact tail: [$(aline TK-30)]"
drive
[ "$(aline TK-30)" = "$P TK-30 queued 180m with no spawn — fly-dispatch/pool not picking it up (gate unknown: no hold marker, park, lock, deferral record or pool/dispatch line names TK-30)" ] && ok \
  || bad "K19: an unknown gate keeps the old tail: [$(aline TK-30)]"

# ── K20: the knob ────────────────────────────────────────────────────────
kb() { ( [ -n "${1+x}" ] && export STUCKQUEUE_GATE_LOG_TAIL_KB="$1"; . "$H/bin/lib/stuckqueue-gate.sh" 2>/dev/null; _sqg_kb ) 2>/dev/null; }
[ "$(kb)" = 2048 ] && [ "$(kb x)" = 2048 ] && [ "$(kb 32)" = 64 ] && [ "$(kb 99999)" = 16384 ] && [ "$(kb 512)" = 512 ] && ok \
  || bad "K20: knob reads: unset=$(kb) x=$(kb x) 32=$(kb 32) 99999=$(kb 99999) 512=$(kb 512)"
jq -e '.env=="STUCKQUEUE_GATE_LOG_TAIL_KB" and .default==2048 and .min==64 and .max==16384' \
  "$DIR/catalog/lanes.d/pipeline-health.knobs.d/STUCKQUEUE_GATE_LOG_TAIL_KB.json" >/dev/null 2>&1 && ok \
  || bad "K20: the knob row catalog/lanes.d/pipeline-health.knobs.d/STUCKQUEUE_GATE_LOG_TAIL_KB.json"
# The tail is bounded: a line older than the tail is not read.
clean
printf '2026-11-20 03:00:00Z [pool/%s] SCHED TK-31 outside the window\n' "$P" > "$H/logs/fly-pool.log"
head -c $((70 * 1024)) /dev/zero | tr '\0' 'x' | fold -w 100 >> "$H/logs/fly-pool.log"
[ "$( ( export STUCKQUEUE_GATE_LOG_TAIL_KB=64; . "$H/bin/lib/stuckqueue-gate.sh"; sqg_gate "$H" "$P" TK-31 | cut -f1 ) 2>/dev/null)" = unknown ] && ok \
  || bad "K20: a 64 KB tail does not read a line 70 KB back"

# ── K21: the escalate message carries the gate ──────────────────────────
clean; qfile TK-773
printf '421\tfp\t%s\t0\ttriage-repeat-refused: paid=2/2\n' "$NOW" > "$H/state/triage-repeat/$P/TK-773.park"
printf '#!/bin/bash\nprintf "%%s\\n" "${@: -1}" >> "%s/escalate.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
: > "$T/escalate.txt"
( export STUCKQUEUE_ESCALATE_AFTER=2
  . "$H/bin/lib/stuckqueue-escalate.sh"; . "$H/bin/lib/stuckqueue-gate.sh"
  NOW=$((OLD + 10)) sqe_note "$H" "$P" "$H/state/build-queue/$P/TK-773.json" 7200 >/dev/null
  NOW=$((OLD + 10 + 7300)) sqe_note "$H" "$P" "$H/state/build-queue/$P/TK-773.json" 7200 >/dev/null ) 2>/dev/null
case "$(cat "$T/escalate.txt")" in
  *"The repeat alert stops until the queue file changes. Gate: call-guard-repeat-park: triage-repeat-refused: paid=2/2; lifts on a board or queue-state change.") ok ;;
  *) bad "K21: the escalate message ends with the gate: [$(cat "$T/escalate.txt")]" ;;
esac

# ── C1-C3: the operator CLI ──────────────────────────────────────────────
clean; qfile TK-774; qfile TK-773
rec TK-774 s1 600 "BUILD_DEFERRED OVERLAP_DEFER TK-774 vs TK-758 files=[app/x.ts]"
printf '421\tfp\t%s\t0\ttriage-repeat-refused: paid=2/2\n' "$NOW" > "$H/state/triage-repeat/$P/TK-773.park"
OUT=$(HARNESS="$H" bash "$H/bin/stuckqueue-why.sh" "$P" TK-774 TK-773 TK-782 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "C1: rc 0, got $RC"
for k in TK-774 TK-773 TK-782; do
  want="$k	$(gate "$k")"
  grep -qxF -- "$want	$( [ -f "$H/state/build-queue/$P/$k.json" ] && echo "queued 180m" || echo "no queue file")" <<<"$OUT" && ok \
    || bad "C2: the CLI line for $k is '$want<TAB>age': [$(printf '%s\n' "$OUT" | grep "^$k	")]"
done
case "$(printf '%s\n' "$OUT" | grep '^TK-774	' | cut -f2)" in overlap-defer) ok ;; *) bad "C2: TK-774 is overlap-defer in the CLI" ;; esac
drive
[ "$(aline TK-774 | sed -nE 's/.*held by ([a-z-]+):.*/\1/p')" = "$(printf '%s\n' "$OUT" | grep '^TK-774	' | cut -f2)" ] && ok \
  || bad "C1: the CLI and the alert name the same gate"
HARNESS="$H" bash "$H/bin/stuckqueue-why.sh" "$P" >/dev/null 2>&1; [ $? = 2 ] && ok || bad "C3: one argument is rc 2"
HARNESS="$H" bash "$H/bin/stuckqueue-why.sh" 'bad/p' TK-1 >/dev/null 2>&1; [ $? = 2 ] && ok || bad "C3: a bad project is rc 2"

[ ! -s "$T/vendor" ] && ok || bad "V1: 0 network: [$(cat "$T/vendor")]"
echo "stuckqueue-gate.bh-9863: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
