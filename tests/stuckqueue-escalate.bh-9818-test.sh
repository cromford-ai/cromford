#!/bin/bash
# tests/stuckqueue-escalate.bh-9818-test.sh — BH-9818: the pipeline-health
# stuck-queue alert (check 1) goes to the operator channel ONE time on the 5th
# firing with no state change, and firings 6 to 10 send nothing.
#
# project-6-os, 2026-11-18: `ph-stuckqueue_project-6-os_MK-3788` fired 19
# times on an unchanged queue file and nobody acted.
#
#   E1-E10  sqe_note / sqe_prune (bin/lib/stuckqueue-escalate.sh) with
#           bin/lane-alert.sh a counting stub, and E3 the stuck-queue block of
#           bin/pipeline-health.sh extracted VERBATIM between its markers and
#           run with alert() stubbed (the tests/pipeline-health-stuck-queue-
#           test.sh pattern), with the lib loaded.
#   V       0 vendor calls
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/stuckqueue-escalate.bh-9818-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset STUCKQUEUE_ESCALATE_AFTER

mkdir -p "$T/rbin" "$T/calls"
for v in gh claude curl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls/vendor"\nexit 1\n' "$v" "$T" > "$T/rbin/$v"
done
chmod +x "$T/rbin/"*
export PATH="$T/rbin:$PATH"

H="$T/h"; FX="$T/fx"; P=project-6-os
mkdir -p "$H/bin/lib" "$H/state/build-queue/$P" "$FX"
scratch_install_closure bin/lib/stuckqueue-escalate.sh "$H" >/dev/null 2>&1 || bad "install bin/lib/stuckqueue-escalate.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/lanealert"\nexit "$(cat %s/la.rc 2>/dev/null || echo 0)"\n' "$FX" "$FX" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
Q="$H/state/build-queue/$P/TK-3788.json"
T0=1789000000

fresh() {
  scratch_rm "$H/state/stuckqueue-escalate"; scratch_rm "$H/state/triage-repeat"; scratch_rm "$FX"; mkdir -p "$FX"
  echo '{"key":"TK-3788"}' > "$Q"; touch -d "@$((T0 - 3 * 3600))" "$Q"
}
# fire <i> — firing number i (the clock moves 7200 s each time); prints the word
fire() { ( export NOW=$((T0 + ($1 - 1) * 7200)); . "$H/bin/lib/stuckqueue-escalate.sh"; sqe_note "$H" "$P" "$Q" 7200 ); }
nmsg() { local n; n=$(grep -c -- "--severity critical --id ph-stuckqueue-escalate-$P-TK-3788 " "$FX/lanealert" 2>/dev/null); echo "${n:-0}"; }

# E1: 5 firings on an unchanged file: exactly 1 critical message, at the 5th
fresh
W=""; for i in 1 2 3 4 5; do W="$W $(fire $i)"; [ "$i" = 4 ] && N4=$(nmsg); done
[ "${N4:-x}" = 0 ] && ok || bad "(E1) a message before the 5th firing (${N4:-?})"
[ "$(nmsg)" = 1 ] && ok || bad "(E1) want 1 message after 5 firings, got $(nmsg)"
[ "$W" = " emit emit emit emit escalate" ] && ok || bad "(E1) the words: [$W]"
grep -q "\[pipeline-health\] project-6-os TK-3788 queued .*m with no spawn: fired 5 times with no change. Cause: no triage-repeat park record. The repeat alert stops" "$FX/lanealert" && ok \
  || bad "(E1) the message text: [$(cat "$FX/lanealert" 2>/dev/null)]"
# E2: firings 6 to 10 send 0 and say quiet
W=""; for i in 6 7 8 9 10; do W="$W $(fire $i)"; done
[ "$(nmsg)" = 1 ] && ok || bad "(E2) firings 6-10 sent more: $(nmsg)"
[ "$W" = " quiet quiet quiet quiet quiet" ] && ok || bad "(E2) the words: [$W]"

# E3: the verbatim pipeline-health block, firings 1-10: alert() runs 5 times
# (1-5), 0 times on 6-10, and the key is in FIRED on every firing
PH="$DIR/bin/pipeline-health.sh"
awk '/^# >>> stuck queue/{f=1;next} /^# <<< stuck queue/{exit} f' "$PH" > "$T/block.sh"
grep -q 'sqe_note' "$T/block.sh" && ok || bad "(E3) the stuck-queue block does not call sqe_note"
fresh
: > "$T/alerts.txt"
for i in 1 2 3 4 5 6 7 8 9 10; do
  : > "$T/fired.txt"
  ( NOW=$((T0 + (i - 1) * 7200)); FIRED="$T/fired.txt"; PROJECTS=$P
    . "$H/bin/lib/stuckqueue-escalate.sh"
    alert() { echo "$2" >> "$FIRED"; printf '%s\t%s\n' "$2" "$3" >> "$T/alerts.txt"; }
    # shellcheck disable=SC1090
    . "$T/block.sh" )
  grep -qx "stuckqueue:$P:TK-3788.json" "$T/fired.txt" && ok || bad "(E3) firing $i: the key is not in FIRED"
  [ "$i" = 5 ] && N5=$(grep -c . "$T/alerts.txt")
done
[ "${N5:-x}" = 5 ] && ok || bad "(E3) alert() on firings 1-5: want 5, got ${N5:-?}"
[ "$(grep -c . "$T/alerts.txt")" = 5 ] && ok || bad "(E3) alert() on firings 6-10: want 0 more, got $(( $(grep -c . "$T/alerts.txt") - 5 ))"
[ "$(nmsg)" = 1 ] && ok || bad "(E3) the block sent $(nmsg) operator messages"

# E4: a state change (touch) at firing 3 restarts the count: the message goes
# at the 5th firing after the change (firing 7), not before
fresh
for i in 1 2; do fire $i >/dev/null; done
touch -d "@$((T0 + 2 * 7200 - 60))" "$Q"
W=""; for i in 3 4 5 6; do W="$W $(fire $i)"; done
[ "$(nmsg)" = 0 ] && ok || bad "(E4) a message before the 5th firing after the change ($(nmsg))"
[ "$(fire 7)" = escalate ] && ok || bad "(E4) firing 7 (the 5th after the change) did not escalate"
[ "$(nmsg)" = 1 ] && ok || bad "(E4) want 1 message, got $(nmsg)"

# E5: lane-alert fails at firing 5: not escalated, firing 6 sends 1 message
fresh
for i in 1 2 3 4; do fire $i >/dev/null; done
echo 1 > "$FX/la.rc"
[ "$(fire 5)" = emit ] && ok || bad "(E5) a failed send must print emit"
rm -f "$FX/la.rc"
[ "$(cut -d' ' -f4 "$H/state/stuckqueue-escalate/$P/TK-3788.n")" = 0 ] && ok || bad "(E5) escalated set although the send failed"
[ "$(fire 6)" = escalate ] && ok || bad "(E5) firing 6 did not retry"
[ "$(grep -c -- '--id ph-stuckqueue-escalate' "$FX/lanealert")" = 2 ] && ok || bad "(E5) want 2 send attempts (1 failed + 1 ok)"
[ "$(fire 7)" = quiet ] && ok || bad "(E5) firing 7 must be quiet"

# E6: an unwritable state dir: emit, and no message on any firing
fresh
mkdir -p "$H/state"; : > "$H/state/stuckqueue-escalate"   # a FILE where the dir goes
W=""; for i in 1 2 3 4 5 6; do W="$W $(fire $i)"; done
[ "$W" = " emit emit emit emit emit emit" ] && ok || bad "(E6) unwritable counter: [$W]"
[ "$(nmsg)" = 0 ] && ok || bad "(E6) an unwritable counter sent $(nmsg) messages"
scratch_rm "$H/state/stuckqueue-escalate"

# E7: the T1 park record is the cause (a GitHub board parks under the digits)
fresh
mkdir -p "$H/state/triage-repeat/$P"
printf 'abcdef0123456789\tfp\t1\t0\ttriage-repeat-refused: AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2 fp=3788:44dff62f1e5e3a28\n' \
  > "$H/state/triage-repeat/$P/3788.park"
for i in 1 2 3 4 5; do fire $i >/dev/null; done
grep -q "Cause: triage-repeat-refused: AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2 fp=3788:44dff62f1e5e3a28\. The repeat" "$FX/lanealert" && ok \
  || bad "(E7) the message carries the park reason: [$(cat "$FX/lanealert" 2>/dev/null)]"

# E8: calls inside the 7200 s window are not firings
fresh
for i in 1 2 3 4; do
  fire $i >/dev/null
  ( export NOW=$((T0 + (i - 1) * 7200 + 600)); . "$H/bin/lib/stuckqueue-escalate.sh"; sqe_note "$H" "$P" "$Q" 7200 ) >/dev/null
  ( export NOW=$((T0 + (i - 1) * 7200 + 1200)); . "$H/bin/lib/stuckqueue-escalate.sh"; sqe_note "$H" "$P" "$Q" 7200 ) >/dev/null
done
[ "$(nmsg)" = 0 ] && ok || bad "(E8) calls inside the window counted ($(nmsg) messages after 4 firings)"
[ "$(cut -d' ' -f1 "$H/state/stuckqueue-escalate/$P/TK-3788.n")" = 4 ] && ok || bad "(E8) count after 4 firings + 8 in-window calls: [$(cat "$H/state/stuckqueue-escalate/$P/TK-3788.n")]"

# E9: STUCKQUEUE_ESCALATE_AFTER=0: always emit, 0 messages
fresh
W=""; for i in 1 2 3 4 5 6 7; do W="$W $(STUCKQUEUE_ESCALATE_AFTER=0 fire $i)"; done
[ "$W" = " emit emit emit emit emit emit emit" ] && ok || bad "(E9) AFTER=0: [$W]"
[ "$(nmsg)" = 0 ] && ok || bad "(E9) AFTER=0 sent $(nmsg)"
# E9b: AFTER=2 escalates at the 2nd firing (the knob is read)
fresh
W=""; for i in 1 2 3; do W="$W $(STUCKQUEUE_ESCALATE_AFTER=2 fire $i)"; done
[ "$W" = " emit escalate quiet" ] && ok || bad "(E9b) AFTER=2: [$W]"

# E10: sqe_prune deletes the counter of a queue file that is gone
fresh
fire 1 >/dev/null
echo '{}' > "$H/state/build-queue/$P/TK-1.json"; ( NOW=$T0; . "$H/bin/lib/stuckqueue-escalate.sh"; sqe_note "$H" "$P" "$H/state/build-queue/$P/TK-1.json" 7200 ) >/dev/null
rm -f "$Q"
( . "$H/bin/lib/stuckqueue-escalate.sh"; sqe_prune "$H" "$P" )
[ -e "$H/state/stuckqueue-escalate/$P/TK-3788.n" ] && bad "(E10) the counter of a gone queue file stayed" || ok
[ -e "$H/state/stuckqueue-escalate/$P/TK-1.json.n" ] || [ -e "$H/state/stuckqueue-escalate/$P/TK-1.n" ] && ok || bad "(E10) a live counter was pruned"

[ ! -s "$T/calls/vendor" ] && ok || bad "(V) 0 vendor calls: [$(cat "$T/calls/vendor")]"

echo "stuckqueue-escalate.bh-9818: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
