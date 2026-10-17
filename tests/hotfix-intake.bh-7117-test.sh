#!/bin/bash
# tests/hotfix-intake.bh-7117-test.sh — BH-7117: every triage pass offers the
# project's open `ai-build` + `hotfix` issues to bin/launch-fastpath.sh FIRST,
# before the orphan reconciler, the announcer and the cost gate, and before any
# SKIP or hold can end the tick.
#
# THE INCIDENT. #7066 (ai-build + hotfix, main red) was filed at 06:38Z and had
# no build row at 07:36Z, also not after a run_triage. fly-pool's hotfix_first
# only orders jobs that already exist; nothing took the hotfix into a job first.
#
# Driven: the REAL bin/lib/rt/gate.sh rt_gate (the production call site), the
# REAL bin/lib/triage-hotfix-lib.sh and its closure (hotfix-lib, gh-rest,
# lane-switch), against a scratch $HARNESS. The neighbours are recorders that
# write one line to $T/order.log, so the ORDER of the pass is the artifact:
#   bin/launch-fastpath.sh  -> "fastpath <argv>"
#   bin/orphan-reconcile.sh -> "reconcile"
#   bin/hotfix-seen.sh      -> "seen"
#   bin/triage-gate.sh      -> "gate" (answers $GATE_ANS)
# The gh shim answers the one REST read (`issues?labels=ai-build,hotfix`) from
# $T/hot-numbers and records every call.
#
#   I1  10 queued normal tickets + 1 hotfix: the hotfix is offered first, alone
#   I2  a hotfix filed after a pass is taken on the next pass
#   I3  a gate SKIP tick still offered the hotfix (and exited 0)
#   I4  a builds pause withholds the offer (one line); a declined key is logged
#   I5  lane off / hotfix-intake-off / in-app board: no offer
#   I6  a fastpath crash does not stop the tick
#   I7  two hotfixes are offered oldest first
#   I8  one hotfix read per pass, shared with the scope marking
#   I9  the full-sweep prompt sentence (function and the real rt_scope)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/hotfix-intake.bh-7117-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; P=cromford
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/fakebin"
scratch_install_closure bin/lib/triage-hotfix-lib.sh "$H" >/dev/null || { echo "closure install of bin/lib/triage-hotfix-lib.sh failed"; exit 1; }
scratch_install_closure bin/lib/triage-shards-lib.sh "$H" >/dev/null || { echo "closure install of bin/lib/triage-shards-lib.sh failed"; exit 1; }
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
cat > "$H/fleet.conf" <<'CONF'
cromford example-org/cromford https://bh.example - 9 box-bh 192.0.2.9
project-3 example-org/project-3 https://project-3.example /api/feature-board 3 box-project-3 192.0.2.8
CONF
: > "$H/env/global.env"

cat > "$H/bin/launch-fastpath.sh" <<SH
#!/bin/bash
echo "fastpath \$*" >> "$T/order.log"
[ -f "$T/fp-out" ] && cat "$T/fp-out"
exit "\$(cat "$T/fp-rc" 2>/dev/null || echo 0)"
SH
chmod +x "$H/bin/launch-fastpath.sh"
printf '#!/bin/bash\necho reconcile >> "%s/order.log"\n' "$T" > "$H/bin/orphan-reconcile.sh"
printf '#!/bin/bash\necho seen >> "%s/order.log"\n' "$T" > "$H/bin/hotfix-seen.sh"
cat > "$H/bin/triage-gate.sh" <<SH
#!/bin/bash
echo gate >> "$T/order.log"
echo "\${GATE_ANS:-RUN board-changed}"
SH
chmod +x "$H/bin/orphan-reconcile.sh" "$H/bin/hotfix-seen.sh" "$H/bin/triage-gate.sh"

cat > "$T/fakebin/gh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls"
case "\$*" in
  *"api -i -X GET repos/"*"/issues?labels="*)
    printf 'HTTP/1.1 200 OK\r\n\r\n'
    jq -R -s -c 'split("\n") | map(select(length>0)) | map({number:(.|tonumber), pull_request:null})' \
      "$T/hot-numbers" 2>/dev/null || printf '[]' ;;
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":4900,"limit":5000,"reset":0},"graphql":{"remaining":4900,"limit":5000,"reset":0}}}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"

reset() { # reset <hotfix numbers, one per line>
  rm -f "$T/order.log" "$T/gh-calls" "$T/fp-out" "$T/fp-rc" "$H/flags"/*
  : > "$H/logs/$P.log"; : > "$H/logs/ALERTS.log"
  printf '%s\n' "${1:-}" | grep -v '^$' > "$T/hot-numbers" || : > "$T/hot-numbers"
  : > "$H/logs/READY-QUEUE.log"
  local i; for i in $(seq 7001 7010); do
    echo "BH-$i tid-$i — ready to build project=$P" >> "$H/logs/READY-QUEUE.log"
  done
}
# pass [VAR=VAL ...] — one gate stage of a triage tick, in a fresh shell, the
# way bin/run-triage.sh runs it: the libs sourced, then rt_gate.
pass() {
  PASS_RC=0
  env PATH="$T/fakebin:$PATH" HARNESS="$H" PROJECT="${PROJ:-$P}" FLEET_CONF="$H/fleet.conf" \
      LANE_GATE_DISABLE=1 LOG="$H/logs/${PROJ:-$P}.log" ALERTS="$H/logs/ALERTS.log" \
      STAMP="2026-10-16 07:00:00Z" TRIAGE_GH_SLUG=example-org/cromford GH_TOKEN=ghs_fixture "$@" \
      bash -c '
        . "$HARNESS/bin/lib/triage-shards-lib.sh"
        . "$HARNESS/bin/lib/triage-hotfix-lib.sh"
        . "'"$DIR"'/bin/lib/rt/gate.sh"
        LANE_TICK() { :; }
        pause_active() { [ "${PAUSE_BUILDS:-0}" = 1 ] && [ "$2" = builds ]; }
        pause_why() { echo "until 2026-10-17 (fixture)"; }
        rt_gate
        echo "PASSED_GATE" >> "'"$T"'/order.log"' >/dev/null 2>&1 || PASS_RC=$?
}
line() { sed -n "${1}p" "$T/order.log" 2>/dev/null; }
nfp() { local n; n=$(grep -c '^fastpath' "$T/order.log" 2>/dev/null); echo "${n:-0}"; }
intake_lines() { grep 'HOTFIX-INTAKE' "$H/logs/$P.log" 2>/dev/null; }
hot_calls() { local n; n=$(grep -c 'issues?labels=' "$T/gh-calls" 2>/dev/null); echo "${n:-0}"; }

# ── I1: 10 normal tickets queued, 1 hotfix: the hotfix is offered first ──────
reset 7066
pass
[ "$(line 1)" = "fastpath $P 7066" ] && ok || bad "I1 the first thing the pass does is offer #7066 to fastpath (order: $(tr '\n' '|' < "$T/order.log" 2>/dev/null))"
[ "$(line 2)" = reconcile ] && ok || bad "I1 orphan-reconcile runs after the intake (line 2: '$(line 2)')"
grep -n '^gate$' "$T/order.log" >/dev/null && ok || bad "I1 the cost gate still runs"
[ "$(grep -n '^reconcile$' "$T/order.log" | cut -d: -f1)" -lt "$(grep -n '^gate$' "$T/order.log" | cut -d: -f1)" ] 2>/dev/null && ok || bad "I1 reconcile before gate"
grep -qE '^fastpath .*70(0[1-9]|10)' "$T/order.log" && bad "I1 a normal queued key reached fastpath: $(grep '^fastpath' "$T/order.log")" || ok
[ "$(nfp)" = 1 ] && ok || bad "I1 exactly one fastpath call per pass (got $(nfp))"
[ "$(intake_lines)" = "2026-10-16 07:00:00Z [$P] HOTFIX-INTAKE offered #7066; declined none" ] && ok \
  || bad "I1 the project log line (got: '$(intake_lines)')"
[ "$PASS_RC" = 0 ] && ok || bad "I1 the pass exits 0 (got $PASS_RC)"

# ── I2: a hotfix filed after a pass starts is taken on the next pass ─────────
reset ""
pass
[ "$(nfp)" = 0 ] && ok || bad "I2 pass A with no hotfix open makes no fastpath call"
[ -z "$(intake_lines)" ] && ok || bad "I2 pass A writes no HOTFIX-INTAKE line (a quiet tick stays quiet): $(intake_lines)"
[ "$(line 1)" = reconcile ] && ok || bad "I2 pass A starts with reconcile as today (line 1: '$(line 1)')"
printf '7066\n' > "$T/hot-numbers"; rm -f "$T/order.log"
pass
[ "$(line 1)" = "fastpath $P 7066" ] && ok || bad "I2 pass B offers the new hotfix first (line 1: '$(line 1)')"

# ── I3: a gate SKIP tick still took the hotfix ───────────────────────────────
reset 7066
pass GATE_ANS="SKIP no-change"
[ "$(line 1)" = "fastpath $P 7066" ] && ok || bad "I3 a SKIP tick still offered the hotfix first (order: $(tr '\n' '|' < "$T/order.log" 2>/dev/null))"
grep -q '^PASSED_GATE$' "$T/order.log" && bad "I3 fixture: SKIP must end the tick inside rt_gate" || ok
[ "$PASS_RC" = 0 ] && ok || bad "I3 a SKIP tick exits 0 (got $PASS_RC)"

# ── I4: a builds pause withholds the offer; a declined key is logged ─────────
reset 7066
pass PAUSE_BUILDS=1
[ "$(nfp)" = 0 ] && ok || bad "I4 a live builds pause: no fastpath call"
[ "$(intake_lines | grep -c 'withheld #7066: builds pause')" = 1 ] && ok \
  || bad "I4 one line names the held hotfix and the pause (got: '$(intake_lines)')"
grep -q '^gate$' "$T/order.log" && ok || bad "I4 the tick goes on to the gate"
reset 7066
printf 'BH-7066\n' > "$T/fp-out"; echo 1 > "$T/fp-rc"
pass
[ "$(intake_lines)" = "2026-10-16 07:00:00Z [$P] HOTFIX-INTAKE offered #7066; declined BH-7066" ] && ok \
  || bad "I4 a declined key is named (got: '$(intake_lines)')"

# ── I5: no offer when the lane is off, the switch is on, or the board is in-app
reset 7066
pass HOTFIX_LANE=0
[ "$(nfp)" = 0 ] && ok || bad "I5 HOTFIX_LANE=0: no call"
[ "$(hot_calls)" = 0 ] && ok || bad "I5 HOTFIX_LANE=0: no hotfix read (got $(hot_calls))"
reset 7066
: > "$H/flags/hotfix-lane-off"
pass
[ "$(nfp)" = 0 ] && ok || bad "I5 flags/hotfix-lane-off: no call"
reset 7066
: > "$H/flags/hotfix-intake-off"
pass
[ "$(nfp)" = 0 ] && ok || bad "I5 flags/hotfix-intake-off: no call"
[ "$(line 1)" = reconcile ] && ok || bad "I5 hotfix-intake-off: the pass is today's pass (line 1: '$(line 1)')"
[ -z "$(intake_lines)" ] && ok || bad "I5 hotfix-intake-off: no intake line"
reset 7066
PROJ=project-3 pass TRIAGE_GH_SLUG=""
[ "$(nfp)" = 0 ] && ok || bad "I5 in-app board: no call"
[ "$(hot_calls)" = 0 ] && ok || bad "I5 in-app board: no hotfix read (got $(hot_calls))"

# ── I6: a fastpath crash does not stop the tick ──────────────────────────────
reset 7066
printf 'Traceback (junk)\n\x01garbage\n' > "$T/fp-out"; echo 1 > "$T/fp-rc"
pass
grep -q '^gate$' "$T/order.log" && ok || bad "I6 the tick reached the gate after a fastpath failure"
grep -q '^PASSED_GATE$' "$T/order.log" && ok || bad "I6 rt_gate returned"
[ "$PASS_RC" = 0 ] && ok || bad "I6 rc 0 (got $PASS_RC)"
[ "$(intake_lines | grep -c 'HOTFIX-INTAKE offered #7066; declined')" = 1 ] && ok || bad "I6 one summary line (got: '$(intake_lines)')"

# ── I7: two hotfixes, offered oldest first ───────────────────────────────────
reset "7070
7066"
pass
[ "$(line 1)" = "fastpath $P 7066 7070" ] && ok || bad "I7 argv order is ascending (line 1: '$(line 1)')"
[ "$(intake_lines)" = "2026-10-16 07:00:00Z [$P] HOTFIX-INTAKE offered #7066,#7070; declined none" ] && ok \
  || bad "I7 the line lists both (got: '$(intake_lines)')"

# ── I8: one hotfix read per pass, and the scope marking reuses it ────────────
reset 7066
OUT8=$(env PATH="$T/fakebin:$PATH" HARNESS="$H" PROJECT="$P" FLEET_CONF="$H/fleet.conf" \
    LANE_GATE_DISABLE=1 LOG="$H/logs/$P.log" ALERTS="$H/logs/ALERTS.log" STAMP=x \
    TRIAGE_GH_SLUG=example-org/cromford bash -c '
      . "$HARNESS/bin/lib/triage-shards-lib.sh"
      . "$HARNESS/bin/lib/triage-hotfix-lib.sh"
      triage_hot_intake
      printf "BH-7001 a\nBH-7066 b\n" | triage_hot_mark queue' 2>/dev/null)
[ "$(hot_calls)" = 1 ] && ok || bad "I8 the intake and the marking share ONE hotfix read (got $(hot_calls))"
[ "${OUT8%%$'\n'*}" = "[HOTFIX] BH-7066 b" ] && ok || bad "I8 the memo the intake set still marks the queue (got: $(printf '%s' "$OUT8" | tr '\n' '|'))"
rm -f "$T/gh-calls"
pass
[ "$(hot_calls)" = 1 ] && ok || bad "I8 a second pass reads again, once (got $(hot_calls))"

# ── I9: the full-sweep prompt sentence ───────────────────────────────────────
I9=$(HARNESS="$H" bash -c '. "$HARNESS/bin/lib/triage-hotfix-lib.sh"; TRIAGE_HOT=" 7070 7066 "; triage_hot_full_note')
case "$I9" in
  "HOTFIX FIRST: open hotfix issues #7066 #7070."*) ok ;;
  *) bad "I9 the note starts with the hotfix numbers, ascending (got: '$I9')" ;;
esac
I9E=$(HARNESS="$H" bash -c '. "$HARNESS/bin/lib/triage-hotfix-lib.sh"; TRIAGE_HOT=""; triage_hot_full_note')
[ -z "$I9E" ] && ok || bad "I9 no hotfix: no sentence (got: '$I9E')"
# the real rt_scope: a full tick with a hotfix leads with the sentence; a full
# tick without one, and a queue tick, keep PROMPT_TEXT byte for byte.
scope_run() { # scope_run <SCOPE_N> -> the PROMPT_TEXT rt_scope leaves
  env PATH="$T/fakebin:$PATH" HARNESS="$H" PROJECT="$P" FLEET_CONF="$H/fleet.conf" \
      LANE_GATE_DISABLE=1 LOG="$H/logs/$P.log" ALERTS="$H/logs/ALERTS.log" STAMP=x \
      TRIAGE_GH_SLUG=example-org/cromford SN="$1" bash -c '
        . "$HARNESS/bin/lib/triage-shards-lib.sh"
        . "$HARNESS/bin/lib/triage-hotfix-lib.sh"
        . "'"$DIR"'/bin/lib/rt/scope.sh"
        GATE_REASON=daily-sweep SCOPE_N="$SN" PROMPT_TEXT="BASE PROMPT"
        rt_scope >/dev/null 2>&1
        printf "%s" "$PROMPT_TEXT"' 2>/dev/null
}
reset 7066
S1=$(scope_run full)
case "$S1" in
  "HOTFIX FIRST: open hotfix issues #7066."*"

BASE PROMPT") ok ;;
  *) bad "I9 rt_scope on a full tick leads with the sentence (got: '$S1')" ;;
esac
reset ""
[ "$(scope_run full)" = "BASE PROMPT" ] && ok || bad "I9 rt_scope with no hotfix leaves the prompt byte-identical (got: '$(scope_run full)')"
reset 7066
[ "$(scope_run queue)" = "BASE PROMPT" ] && ok || bad "I9 a non-full tick gets no sentence (got: '$(scope_run queue)')"

echo "hotfix-intake.bh-7117: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
