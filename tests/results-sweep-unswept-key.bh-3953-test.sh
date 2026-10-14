#!/bin/bash
# tests/results-sweep-unswept-key.bh-3953-test.sh — BH-3953: a staged pool
# result that the results sweep never closed out.
#
# THE BUG (BH-3859, box-small, 2026-10-03). The pool reaped BH-3859
# REVIEW_BLOCKED; staging pulled it as builds/cromford-BH-3859-remote<ts>/
# with no COMMENTED. Then three things kept it un-swept for hours:
#   A. bin/lib/rt/scope.sh built the sweep's reading list (RDIRS) from a glob,
#      which expands in NAME order, and cut it with `head -30`. With 30 or more
#      older un-commented dirs sorting before BH-3859, the newest result never
#      made the list, so no shard was bought for the key that fired the sweep.
#   C. bin/triage-gate.sh step 3 stamps state/<p>.sweepfp before printing
#      `RUN results-sweep`; the throttle in bin/lib/rt/gate.sh then held the
#      tick and exited with the stamp standing, so for 45 minutes the gate read
#      the same set as already swept although no session ran.
#   D. orphan-reconcile skipped the ticket as `awaiting-closeout` on every tick
#      and nothing said so.
#
# THE FIX, pinned here:
#   A. rt_unswept_dirs lists the newest RESULT first, still capped at 30;
#   B. a key whose dirs are all COMMENTED is never a result unit;
#   C. a held `RUN results-sweep` drops its sweepfp stamp, so the next tick
#      re-asks; any other held decision leaves sweepfp alone;
#   D. closeout_overdue_note (bin/lib/closeout-overdue.sh) raises one
#      pipeline-health warn per key once its oldest un-commented RESULT is
#      older than CLOSEOUT_OVERDUE_S (default 2700, floor 600). The call from
#      bin/orphan-reconcile.sh is pinned in tests/orphan-reconcile-test.sh §6.
# Run from anywhere: tests/results-sweep-unswept-key.bh-3953-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "results-sweep-unswept-key: SKIPPED — jq is not installed"; exit 0; }
NOW=$(date +%s)
age() { touch -d "@$((NOW - $2))" "$1"; }   # age <file> <seconds-old>

# ══ A/B — the real tick, sharded (fixture as in tests/rt-split-layout-test.sh) ══
H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mkdir -p "$H/bin/lib/rt" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" \
         "$H/prompts" "$H/builds" "$H/catalog" "$H/fixture" "$T/repos"
: > "$H/env/global.env"
P=cromford
echo "SOP for $P." > "$H/prompts/$P.md"
export FLEET_CONF="$DIR/fleet.conf"
sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/run-triage.sh" > "$H/bin/run-triage.sh"
chmod +x "$H/bin/run-triage.sh"
for s in "$DIR"/bin/lib/rt/*.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
done
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
printf '#!/bin/sh\necho box-small\n' > "$H/bin/box-name.sh"
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
[ "\${2:-}" = "--pending" ] && exit 0
echo "RUN results-sweep"
STUB
printf '#!/bin/bash\nexit 2\n' > "$H/bin/gate-diff.sh"   # board unchanged
for s in unblocked-children triage-shard overlap-guard beat; do printf '#!/bin/sh\nexit 0\n' > "$H/bin/$s.sh"; done
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"
printf '#!/bin/bash\necho "tickets=0" > "$5"\nexit 0\n' > "$H/bin/agent-call.sh"
chmod +x "$H/bin/"*.sh

res() { # res <dir-basename> <seconds-old> <RESULT line> [commented]
  local d="$H/builds/$1"
  mkdir -p "$d"; printf '%s\n' "$3" > "$d/RESULT"; age "$d/RESULT" "$2"
  [ -n "${4:-}" ] && : > "$d/COMMENTED"
  return 0
}
reset_tick() {
  scratch_rm "$H/state"; scratch_rm "$H/logs"; scratch_rm "$H/locks"; scratch_rm "$H/builds"
  mkdir -p "$H/state" "$H/logs" "$H/locks" "$H/builds"
  model_routes_fixture "$H" "$P" || exit 1
  : > "$H/logs/READY-QUEUE.log"
}
tick() { env TRIAGE_SHARDS=1 "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1; }
SD="$H/state/triage-shards/$P"

# A1 — 31 older un-commented dirs sort BEFORE the fresh -remote dir; the fresh
# one is the result the sweep fired for, and it must get a shard.
reset_tick
for n in $(seq 3001 3031); do res "$P-BH-$n-202610031200" 7200 "PR_CREATED https://github.com/example-org/cromford/pull/$n"; done
res "$P-BH-3859-remote20261003153308" 5 "REVIEW_BLOCKED tier 2 verdict BLOCK"
# B1 — a closed key whose dirs are all COMMENTED (BH-3495 at 16:03).
res "$P-BH-3495-202610020900" 90000 "PR_CREATED https://github.com/example-org/cromford/pull/3495" commented
res "pool-$P-BH-3495-202610021000" 86000 "MERGED" commented
tick
if [ -f "$SD/3859.prompt" ]; then ok
else bad "A1 THE BUG: no shard for BH-3859 — the newest un-commented RESULT fell off the sweep's head -30 (prompts: $(ls "$SD" 2>/dev/null | grep -c prompt))"; fi
grep -q 'remote20261003153308' "$SD/3859.prompt" 2>/dev/null && ok \
  || bad "A1 the BH-3859 shard prompt must carry its -remote dir"
grep -q 'REVIEW_BLOCKED tier 2 verdict BLOCK' "$SD/3859.prompt" 2>/dev/null && ok \
  || bad "A1 the BH-3859 shard prompt must carry its first RESULT line"
# B1
[ ! -f "$SD/3495.prompt" ] && ok || bad "B1 a key whose dirs are all COMMENTED was dispatched as a shard"
if [ -f "$SD/.units" ] && grep -q "^3495	result	" "$SD/.units"; then bad "B1 an all-COMMENTED key became a result unit"; else ok; fi
# the cap still holds: 32 un-commented dirs, 30 shards, and the two oldest-named
# of the same age are the ones left (glob order kept on mtime ties)
N=$(ls "$SD"/*.prompt 2>/dev/null | grep -c .)
[ "$N" = 30 ] && ok || bad "A1 the sweep list is still capped at 30 (got $N shard prompts)"

# A3 — under the cap every un-commented key is listed (the path that was
# already right, pinned so the reorder cannot lose it).
reset_tick
res "$P-BH-3700-202610031000" 600 "PR_CREATED https://github.com/example-org/cromford/pull/1"
res "pool-$P-BH-3701-202610031001" 300 "PLAN_BLOCKED questions"
res "$P-BH-3702-remote20261003110000" 60 "REVIEW_BLOCKED tier 2"
tick
for k in 3700 3701 3702; do [ -f "$SD/$k.prompt" ] && ok || bad "A3 key $k got no shard with only 3 un-commented dirs"; done

# A2 — rt_unswept_dirs itself: newest first, exact line shape, capped at 30.
reset_tick
for i in $(seq 1 34); do res "$P-BH-$((3100 + i))-202610030000" $((10000 - i * 100)) "R$i line one
second line"; done
res "pool-$P-BH-3900-202610030000" 10 "RELAYED newest"
LIST=$( HARNESS="$H" PROJECT="$P"; . "$H/bin/lib/rt/scope.sh"
  command -v rt_unswept_dirs >/dev/null 2>&1 || { echo "NO-FUNCTION"; exit 0; }
  rt_unswept_dirs )
if [ "$LIST" = NO-FUNCTION ]; then bad "A2 bin/lib/rt/scope.sh defines no rt_unswept_dirs"
else
  [ "$(printf '%s\n' "$LIST" | grep -c .)" = 30 ] && ok || bad "A2 expected 30 lines, got $(printf '%s\n' "$LIST" | grep -c .)"
  [ "$(head -1 <<<"$LIST")" = "$H/builds/pool-$P-BH-3900-202610030000 :: RELAYED newest" ] && ok \
    || bad "A2 the newest (pool- relay) dir must come first, exact shape '<dir> :: <first RESULT line>': $(head -1 <<<"$LIST")"
  [ "$(printf '%s\n' "$LIST" | sed -n 2p)" = "$H/builds/$P-BH-3134-202610030000 :: R34 line one" ] && ok \
    || bad "A2 second line must be the next newest: $(printf '%s\n' "$LIST" | sed -n 2p)"
  for i in 1 2 3 4 5; do
    grep -q "BH-$((3100 + i))-" <<<"$LIST" && bad "A2 old dir BH-$((3100 + i)) must be past the cap" || ok
  done
  grep -vqE "^$H/builds/[^ ]+ :: R?[A-Za-z0-9 ]+$" <<<"$LIST" && bad "A2 a line breaks the '<dir> :: <line>' shape" || ok
fi

# ══ C — a held sweep keeps no stamp ═════════════════════════════════════════
G="$T/g"; mkdir -p "$G/bin/lib/rt" "$G/state" "$G/flags" "$G/logs" "$G/env" "$G/builds/p-K-1" "$T/gfake"
cp "$DIR/bin/lib/rt/gate.sh" "$DIR/bin/lib/triage-throttle.sh" "$G/bin/lib/" 2>/dev/null
mv "$G/bin/lib/gate.sh" "$G/bin/lib/rt/gate.sh"
cat > "$G/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 ${2:-}" in "p board_prefix") echo "-" ;; "p repo") echo "o/r" ;; *) exit 1 ;; esac
SH
cat > "$T/gfake/gh" <<'SH'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift; P=""
while [ $# -gt 0 ]; do case "$1" in -i) shift ;; -X|-f|-F|-H) shift 2 ;; -*) shift ;; *) P="$1"; shift; break ;; esac; done
case "$P" in
  repos/o/r/issues*) BODY='[{"number":7,"state":"open","title":"t","comments":1,"updated_at":"x"}]' ;;
  repos/o/r/pulls*)  BODY='[]' ;;
  *) exit 1 ;;
esac
printf 'HTTP/2.0 200\r\n\r\n%s\n' "$BODY"
SH
# rt_gate calls $HARNESS/bin/triage-gate.sh: here that IS the real gate.
REAL_GATE="#!/bin/bash
export PATH=\"$T/gfake:\$PATH\"
exec \"$DIR/bin/triage-gate.sh\" \"\$@\""
printf '%s\n' "$REAL_GATE" > "$G/bin/triage-gate.sh"
for s in orphan-reconcile hotfix-seen decision-log lane-alert beat; do printf '#!/bin/bash\nexit 0\n' > "$G/bin/$s.sh"; done
chmod +x "$G/bin/"*.sh "$T/gfake/gh"
gate() { HARNESS="$G" "$G/bin/triage-gate.sh" p "$@" 2>/dev/null; }
held_tick() { # one rt_gate over $G, the throttle holding: last paid tick 3m ago
  ( export HARNESS="$G" TRIAGE_MIN_INTERVAL_S=3600
    PROJECT=p STAMP=now LOG="$G/logs/p.log" ALERTS="$G/logs/ALERTS.log" ORPHAN_RECONCILE=0
    LANE_TICK() { :; }
    . "$G/bin/lib/triage-throttle.sh"
    TRIAGE_THROTTLE_NOW=$((NOW - 180)) triage_throttle_record "$G" p
    . "$G/bin/lib/rt/gate.sh"
    rt_gate
    echo CONTINUED ) 2>/dev/null
}
echo "REVIEW_BLOCKED tier 2" > "$G/builds/p-K-1/RESULT"

# C1 — the gate stamps on RUN (the merge-base evidence for the ticket's question).
OUT=$(gate); [ "$OUT" = "RUN results-sweep" ] && ok || bad "C1 precondition: a new un-commented set buys one sweep, got '$OUT'"
[ -s "$G/state/p.sweepfp" ] && ok || bad "C1 the gate's RUN results-sweep writes state/p.sweepfp"
gate --seed >/dev/null      # board fingerprint + full-sweep clock fresh: only step 3 decides
rm -f "$G/state/p.sweepfp"

# C2 — the throttle holds the sweep; the stamp must not survive it.
OUT=$(held_tick)
case "$OUT" in *CONTINUED*) bad "C2 precondition: the throttle must hold this tick" ;; *) ok ;; esac
grep -q 'gate RUN results-sweep held — throttle cadence' "$G/logs/p.log" && ok \
  || bad "C2 the held tick logs the throttle hold: $(tail -1 "$G/logs/p.log" 2>/dev/null)"
[ ! -e "$G/state/p.sweepfp" ] && ok || bad "C2 THE BUG: a held results-sweep left state/p.sweepfp stamped"
OUT=$(gate); [ "$OUT" = "RUN results-sweep" ] && ok \
  || bad "C2 THE BUG: the tick after a held sweep must re-ask the sweep, got '$OUT'"

# C3 — only the sweep decision drops sweepfp: a held queue-pending leaves it.
printf 'KEEP\n%s\n' "$NOW" > "$G/state/p.sweepfp"
printf '#!/bin/bash\necho "RUN queue-pending"\n' > "$G/bin/triage-gate.sh"
OUT=$(held_tick)
case "$OUT" in *CONTINUED*) bad "C3 precondition: the throttle must hold this tick" ;; *) ok ;; esac
[ "$(head -1 "$G/state/p.sweepfp" 2>/dev/null)" = KEEP ] && ok || bad "C3 a held queue-pending must leave sweepfp alone"

# ══ D — closeout_overdue_note ═══════════════════════════════════════════════
A="$T/a"; mkdir -p "$A/bin" "$A/builds"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls"\n' "$A" > "$A/bin/lane-alert.sh"
chmod +x "$A/bin/lane-alert.sh"
if [ -r "$DIR/bin/lib/closeout-overdue.sh" ] && . "$DIR/bin/lib/closeout-overdue.sh" \
   && command -v closeout_overdue_note >/dev/null 2>&1; then ok
else bad "bin/lib/closeout-overdue.sh must define closeout_overdue_note"; closeout_overdue_note() { return 0; }; fi
dres() { local d="$A/builds/$1"; mkdir -p "$d"; printf '%s\n' "$3" > "$d/RESULT"; age "$d/RESULT" "$2"; [ -z "${4:-}" ] || : > "$d/COMMENTED"; }
dreset() { scratch_rm "$A/builds"; mkdir -p "$A/builds"; rm -f "$A/calls"; }
calls() { if [ -f "$A/calls" ]; then grep -c . "$A/calls"; else echo 0; fi; }

# D1 — 50 minutes un-commented: one warn, naming the key and the dir.
dreset
dres "p-BH-3859-remote20261003153308" 3000 "REVIEW_BLOCKED tier 2 verdict BLOCK"
dres "p-BH-3859-202610031400" 600 "QUEUED_FLY BH-3859"
closeout_overdue_note "$A" p BH-3859; RC=$?
[ "$RC" = 0 ] && ok || bad "D1 closeout_overdue_note must return 0 (got $RC)"
[ "$(calls)" = 1 ] && ok || bad "D1 expected exactly one lane-alert call, got $(calls)"
C=$(cat "$A/calls" 2>/dev/null)
case "$C" in "--id closeout-overdue:p:BH-3859 --severity warn pipeline-health "*) ok ;; *) bad "D1 wrong alert id/severity/lane: $C" ;; esac
case "$C" in *"p BH-3859 has waited 50m"*) ok ;; *) bad "D1 the alert must name the key and its age from the OLDEST un-commented RESULT: $C" ;; esac
case "$C" in *"p-BH-3859-remote20261003153308"*"REVIEW_BLOCKED tier 2 verdict BLOCK"*"2 un-commented dir(s)"*) ok ;; *) bad "D1 the alert must name the dir, its RESULT and the count: $C" ;; esac

# D2 — 44 minutes: not yet.
dreset; dres "p-BH-3859-remote1" 2640 "REVIEW_BLOCKED"
closeout_overdue_note "$A" p BH-3859
[ "$(calls)" = 0 ] && ok || bad "D2 a 44m-old result must not alert: $(cat "$A/calls" 2>/dev/null)"

# D3 — all COMMENTED: nothing; and BH-385's overdue dir is not BH-38's.
dreset; dres "p-BH-3859-remote1" 9000 "REVIEW_BLOCKED" commented
closeout_overdue_note "$A" p BH-3859
[ "$(calls)" = 0 ] && ok || bad "D3 an all-COMMENTED key must not alert: $(cat "$A/calls" 2>/dev/null)"
dres "p-BH-385-1" 9000 "PLAN_BLOCKED"; dres "pool-p-BH-385-2" 9000 "PLAN_BLOCKED"
closeout_overdue_note "$A" p BH-38
[ "$(calls)" = 0 ] && ok || bad "D3 BH-385's dirs must not alert for BH-38: $(cat "$A/calls" 2>/dev/null)"
closeout_overdue_note "$A" p BH-385
[ "$(calls)" = 1 ] && ok || bad "D3 BH-385 itself (local + pool- dirs) alerts once, got $(calls)"

# D4 — the knob: garbage falls back to 45m, and nothing goes under the 10m floor.
dreset; dres "p-BH-3859-remote1" 600 "REVIEW_BLOCKED"
CLOSEOUT_OVERDUE_S=abc closeout_overdue_note "$A" p BH-3859
[ "$(calls)" = 0 ] && ok || bad "D4 CLOSEOUT_OVERDUE_S=abc must mean 45m, not 0: $(cat "$A/calls" 2>/dev/null)"
dreset; dres "p-BH-3859-remote1" 300 "REVIEW_BLOCKED"
CLOSEOUT_OVERDUE_S=60 closeout_overdue_note "$A" p BH-3859
[ "$(calls)" = 0 ] && ok || bad "D4 CLOSEOUT_OVERDUE_S=60 is raised to the 600s floor: $(cat "$A/calls" 2>/dev/null)"
dreset; dres "p-BH-3859-remote1" 900 "REVIEW_BLOCKED"
CLOSEOUT_OVERDUE_S=600 closeout_overdue_note "$A" p BH-3859
[ "$(calls)" = 1 ] && ok || bad "D4 CLOSEOUT_OVERDUE_S=600 alerts a 15m-old result, got $(calls)"
# no lane-alert on the box: silent, rc 0
dreset; dres "p-BH-3859-remote1" 9000 "REVIEW_BLOCKED"; chmod -x "$A/bin/lane-alert.sh"
closeout_overdue_note "$A" p BH-3859; RC=$?
[ "$RC" = 0 ] && [ "$(calls)" = 0 ] && ok || bad "D4 a box with no lane-alert.sh returns 0 and sends nothing (rc $RC)"

echo "results-sweep-unswept-key: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
