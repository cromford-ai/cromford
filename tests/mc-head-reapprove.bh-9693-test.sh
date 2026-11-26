#!/bin/bash
# tests/mc-head-reapprove.bh-9693-test.sh — BH-9693 (BH-9427.1, scope 2
# `head-not-reapproved`): a BLOCK from another review lane on a moved head
# buys the conductor's own head-bound read before a park, capped per PR by
# MC_HNR_REREVIEW_MAX (bin/lib/hnr-rereview.sh). The cap ends in BLOCKED_HUMAN
# `head-not-reapproved`, and the park names the cap.
#
#   D1-D12  mc_hnr_decide: buy / wait / park for each source, CI word, merge
#           state, knob value and budget count; the `hnrbuy` line round-trips
#           through the real mc_attempt_put / mc_attempt_has / mc_attempt_count
#   C1-C12  headbound_review (bin/lib/mc/classify.sh) with the spawn and its
#           neighbours stubbed: the autopilot and bound-verdict BLOCK arms
#   R1-R4   bin/blocked-resolver.sh's `# >>> br rereview post` block with the
#           lib sourced
#   N1      no test called gh or curl
#
# No test calls GitHub or a model: mc_rereview and mc_rereview_spawn are stubs
# in every case, and gh and curl on PATH are fakes that log a call.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-head-reapprove.bh-9693-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/locks"
for L in bin/lib/merge-conductor-lib.sh bin/lib/hnr-rereview.sh bin/lib/block-gate.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
[ -f "$H/bin/lib/hnr-rereview.sh" ] || bad "setup: bin/lib/hnr-rereview.sh is not in the tree"
: > "$H/env/global.env"
mkdir -p "$T/fakebin"
for V in gh curl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/vendor.log"\nexit 1\n' "$V" "$T" > "$T/fakebin/$V"; chmod +x "$T/fakebin/$V"
done
: > "$T/vendor.log"
export PATH="$T/fakebin:$PATH"
export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret
unset JOBS_URL GH_TOKEN GITHUB_TOKEN MC_HNR_REREVIEW_MAX 2>/dev/null || true
MCLOG="$H/logs/merge-conductor.log"
SLUG=example-org/demo-os; P=demo-os
HA=aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111
HB=bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222
REV=cccc3333cccc3333cccc3333cccc3333cccc3333

# lib — the conductor lib and the new lib, in this shell's subshell.
LIBS=". '$H/bin/lib/merge-conductor-lib.sh' >/dev/null 2>&1; mc_init >/dev/null 2>&1; lib_env_apply() { return 0; }; . '$H/bin/lib/hnr-rereview.sh'"
# dec <key> <head> <source> <ci> <mstate> [env...] — mc_hnr_decide's line, tab as '|'.
dec() {
  local k="$1" h="$2" s="$3" c="$4" m="$5"; shift 5
  env "$@" bash -c "$LIBS; mc_hnr_decide '$k' '$h' '$s' '$c' '$m'" 2>/dev/null | tr '\t' '|'
}
cnt() { bash -c "$LIBS; mc_attempt_count hnrbuy '$1'"; }
ATT=$(bash -c "$LIBS; printf '%s' \"\$MC_ATTEMPTS\"")
[ -n "$ATT" ] && [ -f "$ATT" ] || bad "setup: no attempts file ($ATT)"
lines() { grep -c "^hnrbuy $1 " "$ATT"; }

# ============================================================================
echo "D: mc_hnr_decide"
K=example-org/demo-os#9301
R=$(dec "$K" "$HA" autopilot green CLEAN)
case "$R" in "buy|unit 1 of 1") ok "D1 autopilot, green, CLEAN, 0 of 1: buy (unit 1 of 1)" ;; *) bad "D1: $R" ;; esac
[ "$(lines "$K")" = 1 ] && ok "D1 one hnrbuy line" || bad "D1 lines: $(lines "$K")"

K=example-org/demo-os#9302
R=$(dec "$K" "$HA" lead green CLEAN)
case "$R" in park\|*) ok "D2 lead: park" ;; *) bad "D2: $R" ;; esac
for S in human mc-rereview "" autopilotx; do
  R=$(dec "$K" "$HA" "$S" green CLEAN)
  case "$R" in park\|*) ok "D3 source '${S}': park" ;; *) bad "D3 '$S': $R" ;; esac
done
[ "$(lines "$K")" = 0 ] && ok "D2-D3 no hnrbuy line" || bad "D2-D3 lines: $(lines "$K")"

K=example-org/demo-os#9304
for C in red failure; do
  R=$(dec "$K" "$HA" autopilot "$C" CLEAN)
  case "$R" in "park|CI $C on ${HA:0:8}: the fix round owns a red head") ok "D4 ci $C: park, why names CI" ;; *) bad "D4 $C: $R" ;; esac
done
for C in pending none; do
  R=$(dec "$K" "$HA" autopilot "$C" CLEAN)
  case "$R" in wait\|*) ok "D5 ci $C: wait" ;; *) bad "D5 $C: $R" ;; esac
done
[ "$(lines "$K")" = 0 ] && ok "D4-D5 no hnrbuy line" || bad "D4-D5 lines: $(lines "$K")"
R=$(dec "$K" "$HA" autopilot none CLEAN MC_FLAKE=x MC_FLAKE_RUNG=2)
case "$R" in "buy|unit 1 of 1") ok "D5 ci none on a spent flake ladder (rung 2): buy, the unit is taken" ;; *) bad "D5 rung 2: $R" ;; esac

K=example-org/demo-os#9306
R=$(dec "$K" "$HA" autopilot green DIRTY)
case "$R" in park\|*DIRTY*) ok "D6 DIRTY: park" ;; *) bad "D6: $R" ;; esac

K=example-org/demo-os#9307
R=$(dec "$K" "$HA" autopilot green CLEAN MC_HNR_REREVIEW_MAX=0)
case "$R" in "park|off (MC_HNR_REREVIEW_MAX=0)") ok "D7 knob 0: park off" ;; *) bad "D7: $R" ;; esac
[ "$(lines "$K")" = 0 ] && ok "D7 knob 0 writes no line" || bad "D7 lines: $(lines "$K")"
M=$(bash -c "$LIBS; mc_hnr_max"); [ "$M" = 1 ] && ok "D8 knob unset: max 1" || bad "D8 unset: $M"
M=$(MC_HNR_REREVIEW_MAX=abc bash -c "$LIBS; mc_hnr_max"); [ "$M" = 1 ] && ok "D8 knob abc: max 1" || bad "D8 abc: $M"
M=$(MC_HNR_REREVIEW_MAX=3 bash -c "$LIBS; mc_hnr_max"); [ "$M" = 3 ] && ok "D8 knob 3: max 3" || bad "D8 3: $M"

K=example-org/demo-os#9309
dec "$K" "$HA" autopilot green CLEAN >/dev/null
R=$(dec "$K" "$HB" autopilot green CLEAN)
case "$R" in "park|re-review budget used (1 of 1)") ok "D9 head B after head A's unit: park, budget used (1 of 1)" ;; *) bad "D9: $R" ;; esac
R=$(dec "$K" "$HB" autopilot pending CLEAN)
case "$R" in "park|re-review budget used (1 of 1)") ok "D9 a pending head past the cap parks too (no wait for a read that is not bought)" ;; *) bad "D9 pending: $R" ;; esac
R=$(dec "$K" "$HB" review-prs green CLEAN MC_HNR_REREVIEW_MAX=2)
case "$R" in "buy|unit 2 of 2") ok "D9 max 2: head B buys unit 2 of 2" ;; *) bad "D9 max 2: $R" ;; esac
R=$(dec "$K" "$HA" autopilot green CLEAN)
case "$R" in "buy|") ok "D10 head A again: buy, no new unit" ;; *) bad "D10: $R" ;; esac
[ "$(cnt "$K")" = 2 ] && [ "$(lines "$K")" = 2 ] && ok "D10 count stays 2 (A and B), real mc_attempt_count" || bad "D10 count $(cnt "$K") lines $(lines "$K")"

K2=example-org/x#2; K20=example-org/x#20
dec "$K2" "$HA" autopilot green CLEAN >/dev/null
R=$(dec "$K20" "$HA" autopilot green CLEAN)
case "$R" in "buy|unit 1 of 1") ok "D11 example-org/x#2's line does not count for example-org/x#20" ;; *) bad "D11: $R" ;; esac
[ "$(cnt "$K20")" = 1 ] && [ "$(cnt "$K2")" = 1 ] && ok "D11 one line each" || bad "D11 counts $(cnt "$K2") $(cnt "$K20")"

K=example-org/demo-os#9312
R=$(dec "$K" "$HA" box any -)
case "$R" in "buy|unit 1 of 1") ok "D12 resolver word any, box, 0 of 1: buy" ;; *) bad "D12: $R" ;; esac

# ============================================================================
echo "C: headbound_review"
# hb <case> <num> <head> <ci> [mstate] — one `headbound_review <MODE>` of PR
# <num>; env: APV (autopilot word), RBC/RBS (bound-verdict class/source),
# NOLIB=1 (the tree without bin/lib/hnr-rereview.sh), MODE (default moved).
hb() {
  local c="$1" num="$2" head="$3" ci="$4" ms="${5:-CLEAN}"
  ( . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
    lib_env_apply() { return 0; }
    [ "${NOLIB:-}" = 1 ] || . "$H/bin/lib/hnr-rereview.sh"
    CAPFILE="$T/cap.txt"; REREVIEW_CAP=0; REREVIEW_BUDGET=50; MC_TICK_ID="t-$c-${TICK:-1}"
    mc_job_running() { return 1; }
    mc_lane_next_review_account() { echo fixture-acct; }
    mc_lane_down_for_account() { return 1; }
    mc_rereview_spawn() { echo "$2 $6" >> "$T/$c.spawns"; return 0; }
    mc_ap_consumed() { return 1; }
    mc_autopilot_verdict() { printf '%s' "${APV:-}"; }
    vd_block_line() { return 1; }
    mc_patch_id_remember() { return 0; }
    job_verdict_rebind() { return 0; }
    mc_transition() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$T/$c.tr"; }
    hb_post() { { [ -n "${6:-}" ] && [ -r "$6" ] && cat "$6"; printf '%s\n' "$5"; } >> "$T/$c.comments"; }
    if [ -n "${RBC:-}" ]; then
      mc_rb_load() { return 0; }
      review_dedupe_on() { return 0; }
      review_bought() { RB_CLASS="$RBC"; RB_SOURCE="$RBS"; RB_WORD="${RBW:-BLOCK}"; RB_SERVED=claude; printf '%s\t%s\n' "$RBS" "$RB_WORD"; return 0; }
      review_bought_prov() { echo claude; }
      review_skip_log() { return 0; }
    else
      mc_rb_load() { return 1; }
    fi
    headbound_review "${MODE:-moved}" "$SLUG#$num" "$SLUG" "$num" "$P" "https://github.com/$SLUG/pull/$num" - "$head" "$REV" BLOCK "$ms" "$ci"
    echo "rc=$?" >> "$T/$c.rc" ) 2>> "$T/$c.err"
}
n() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
klog() { grep -F " $1 " "$MCLOG" 2>/dev/null; }
park() { if [ -f "$T/$1.tr" ]; then grep -c '|BLOCKED_HUMAN|head-not-reapproved$' "$T/$1.tr"; else echo 0; fi; }

# C1 knob 0: today's park, byte for byte.
MC_HNR_REREVIEW_MAX=0 APV=BLOCK hb c1 9401 "$HA" green
[ "$(park c1)" = 1 ] && ok "C1 knob 0: BLOCKED_HUMAN head-not-reapproved" || bad "C1 tr: $(cat "$T/c1.tr" 2>/dev/null)"
klog "$SLUG#9401" | grep -q 'AUTOPILOT_VERDICT consumed: BLOCK' && ok "C1 the AUTOPILOT_VERDICT consumed line" || bad "C1 log: $(klog "$SLUG#9401")"
grep -qF 'Parked as head-not-reapproved and handed to bin/blocked-resolver.sh, which runs a fix round against the findings above. No second review was bought._' "$T/c1.comments" 2>/dev/null \
  && ok "C1 today's comment text" || bad "C1 comment: $(cat "$T/c1.comments" 2>/dev/null)"
[ "$(n "$T/c1.spawns")" = 0 ] && ok "C1 no spawn" || bad "C1 spawns: $(n "$T/c1.spawns")"
NOLIB=1 APV=BLOCK hb c1n 9411 "$HA" green
[ "$(park c1n)" = 1 ] && [ "$(n "$T/c1n.spawns")" = 0 ] && ok "C1 a tree without the lib: today's park, no spawn" || bad "C1 nolib: tr $(cat "$T/c1n.tr" 2>/dev/null) spawns $(n "$T/c1n.spawns")"

# C2 default: autopilot BLOCK, CI green -> the conductor's own read.
APV=BLOCK hb c2 9402 "$HA" green
[ "$(n "$T/c2.spawns")" = 1 ] && ok "C2 one spawn of the head-bound read" || bad "C2 spawns: $(n "$T/c2.spawns"); log: $(klog "$SLUG#9402" | tail -3)"
[ "$(park c2)" = 0 ] && ok "C2 no BLOCKED_HUMAN transition" || bad "C2 tr: $(cat "$T/c2.tr")"
[ ! -s "$T/c2.comments" ] && ok "C2 no comment" || bad "C2 comment: $(cat "$T/c2.comments")"
! grep -qxF "apverdict $SLUG#9402 $HA" "$ATT" && ok "C2 no apverdict line" || bad "C2 apverdict written"
[ "$(lines "$SLUG#9402")" = 1 ] && ok "C2 one hnrbuy line" || bad "C2 hnrbuy: $(lines "$SLUG#9402")"
[ "$(klog "$SLUG#9402" | grep -c "HNR_REREVIEW $SLUG#9402 ${HA:0:8}")" = 1 ] && ok "C2 one HNR_REREVIEW line" || bad "C2 log: $(klog "$SLUG#9402")"
klog "$SLUG#9402" | grep -q "HNR_REREVIEW .*autopilot BLOCK; the conductor buys its own head-bound read (unit 1 of 1); no park" && ok "C2 the line names the source and the unit" || bad "C2 line: $(klog "$SLUG#9402" | grep HNR_)"
grep -q '|HEAD_MOVED|REREVIEWING' "$T/c2.tr" && ok "C2 the row stays HEAD_MOVED (REREVIEWING)" || bad "C2 tr: $(cat "$T/c2.tr")"

# C3 tick 2 on the same head: the job is running (a job file with this pid).
JF=$(bash -c "$LIBS; mc_rr_write \"\$(mc_rr_file $SLUG 9402 $HA)\" running $$ \"\$(date +%s)\" 0 - $HA $REV -; mc_rr_file $SLUG 9402 $HA")
TICK=2 APV=BLOCK hb c2 9402 "$HA" green
[ "$(lines "$SLUG#9402")" = 1 ] && ok "C3 tick 2: no second hnrbuy line" || bad "C3 hnrbuy: $(lines "$SLUG#9402")"
[ "$(klog "$SLUG#9402" | grep -c HNR_REREVIEW)" = 1 ] && ok "C3 one HNR_REREVIEW line in total" || bad "C3 log: $(klog "$SLUG#9402" | grep HNR_)"
[ "$(park c2)" = 0 ] && [ "$(n "$T/c2.spawns")" = 1 ] && ok "C3 no park, no second spawn" || bad "C3 tr $(cat "$T/c2.tr") spawns $(n "$T/c2.spawns")"
rm -f "$JF"
# C3b the spawn was refused on tick 1 (no job file): the next tick on the same
# head buys again and takes no second unit.
TICK=3 APV=BLOCK hb c2 9402 "$HA" green
[ "$(lines "$SLUG#9402")" = 1 ] && [ "$(n "$T/c2.spawns")" = 2 ] && [ "$(park c2)" = 0 ] && ok "C3 no job file on the same head: spawned again, still one unit" \
  || bad "C3b hnrbuy $(lines "$SLUG#9402") spawns $(n "$T/c2.spawns") tr $(cat "$T/c2.tr")"

# C4 a second head after the unit is spent: the cap parks it and names it.
APV=BLOCK hb c4 9402 "$HB" green
[ "$(park c4)" = 1 ] && ok "C4 head B: BLOCKED_HUMAN head-not-reapproved" || bad "C4 tr: $(cat "$T/c4.tr" 2>/dev/null)"
klog "$SLUG#9402" | grep "BLOCKED_AGENT head-not-reapproved" | grep -q 're-review budget used (1 of 1)' && ok "C4 the park log line names the cap" || bad "C4 log: $(klog "$SLUG#9402" | tail -3)"
grep -q 're-review budget used (1 of 1)' "$T/c4.comments" 2>/dev/null && ok "C4 the comment names the cap" || bad "C4 comment: $(cat "$T/c4.comments" 2>/dev/null)"
[ "$(n "$T/c4.spawns")" = 0 ] && ok "C4 no spawn" || bad "C4 spawns: $(n "$T/c4.spawns")"
grep -qxF "apverdict $SLUG#9402 $HB" "$ATT" && ok "C4 the park writes today's apverdict line" || bad "C4 no apverdict line"

# C5 CI red: park on sight.
APV=BLOCK hb c5 9405 "$HA" red
[ "$(park c5)" = 1 ] && [ "$(lines "$SLUG#9405")" = 0 ] && [ "$(n "$T/c5.spawns")" = 0 ] && ok "C5 red CI: park, no hnrbuy line, no spawn" \
  || bad "C5 tr $(cat "$T/c5.tr" 2>/dev/null) hnrbuy $(lines "$SLUG#9405") spawns $(n "$T/c5.spawns")"
grep -q 'CI red on' "$T/c5.comments" 2>/dev/null && ok "C5 the comment says why (CI red)" || bad "C5 comment: $(cat "$T/c5.comments" 2>/dev/null)"
# C6 CI pending: no park, no unit, the ordinary deferral.
APV=BLOCK hb c6 9406 "$HA" pending
[ "$(park c6)" = 0 ] && [ "$(lines "$SLUG#9406")" = 0 ] && [ "$(n "$T/c6.spawns")" = 0 ] && ok "C6 pending: no park, no line, no spawn" \
  || bad "C6 tr $(cat "$T/c6.tr" 2>/dev/null) hnrbuy $(lines "$SLUG#9406") spawns $(n "$T/c6.spawns")"
klog "$SLUG#9406" | grep -q "re-review deferred — CI pending on ${HA:0:8}" && ok "C6 the deferred — CI pending line" || bad "C6 log: $(klog "$SLUG#9406")"

# C7 bound-verdict block from review-prs: the read is bought.
RBC=block RBS=review-prs hb c7 9407 "$HA" green
[ "$(n "$T/c7.spawns")" = 1 ] && [ "$(park c7)" = 0 ] && [ ! -s "$T/c7.comments" ] && ok "C7 review-prs block: spawn, no park, no comment" \
  || bad "C7 spawns $(n "$T/c7.spawns") tr $(cat "$T/c7.tr" 2>/dev/null) comments $(cat "$T/c7.comments" 2>/dev/null)"
klog "$SLUG#9407" | grep -q "HNR_REREVIEW .*review-prs BLOCK" && ok "C7 the HNR_REREVIEW line names review-prs" || bad "C7 log: $(klog "$SLUG#9407")"
# C8 from lead: today's park.
RBC=block RBS=lead hb c8 9408 "$HA" green
[ "$(park c8)" = 1 ] && [ "$(n "$T/c8.spawns")" = 0 ] && ok "C8 lead block: park, no spawn" || bad "C8 tr $(cat "$T/c8.tr" 2>/dev/null) spawns $(n "$T/c8.spawns")"
klog "$SLUG#9408" | grep -q 'BOUND_VERDICT consumed: lead verdicted BLOCK' && ok "C8 today's BOUND_VERDICT line" || bad "C8 log: $(klog "$SLUG#9408")"
# C7b the bound-verdict block after the cap names the cap.
RBC=block RBS=review-prs hb c7b 9407 "$HB" green
[ "$(park c7b)" = 1 ] && grep -q 're-review budget used (1 of 1)' "$T/c7b.comments" 2>/dev/null && ok "C7 review-prs block on a second head: park names the cap" \
  || bad "C7b tr $(cat "$T/c7b.tr" 2>/dev/null) comment $(cat "$T/c7b.comments" 2>/dev/null)"

# C9 the conductor's own read comes back BLOCK: one park; a second call on the
# same head (the hand-off released) posts nothing and parks nothing.
mkdir -p "$T/out"; printf 'Findings: one.\n\nVERDICT: BLOCK\n' > "$T/out/c9.md"
bash -c "$LIBS; mc_rr_write \"\$(mc_rr_file $SLUG 9402 $HA)\" done 0 1 2 BLOCK $HA $REV '$T/out/c9.md'"
APV=BLOCK hb c9 9402 "$HA" green
[ "$(park c9)" = 1 ] && [ "$(grep -c 'Push fixes; the conductor reviews the next head' "$T/c9.comments" 2>/dev/null)" = 1 ] && ok "C9 own BLOCK: one park, one comment" \
  || bad "C9 tr $(cat "$T/c9.tr" 2>/dev/null) comments $(cat "$T/c9.comments" 2>/dev/null)"
TICK=2 APV=BLOCK hb c9 9402 "$HA" green
[ "$(park c9)" = 1 ] && [ "$(grep -c 'Push fixes' "$T/c9.comments")" = 1 ] && ok "C9 second call on the same head: no second comment, no second transition" \
  || bad "C9 second: tr $(cat "$T/c9.tr") comments $(grep -c 'Push fixes' "$T/c9.comments")"

# C10 the conductor's own read comes back APPROVE: WAIT_REVIEW, and the comment
# clears a same-login machine BLOCK at the block gate.
printf 'No findings.\n\nVERDICT: APPROVE\n' > "$T/out/c10.md"
bash -c "$LIBS; mc_rr_write \"\$(mc_rr_file $SLUG 9410 $HA)\" done 0 1 2 APPROVE $HA $REV '$T/out/c10.md'"
APV=BLOCK hb c10 9410 "$HA" green
grep -q '|WAIT_REVIEW|' "$T/c10.tr" 2>/dev/null && [ "$(park c10)" = 0 ] && ok "C10 own APPROVE: WAIT_REVIEW, no park" || bad "C10 tr: $(cat "$T/c10.tr" 2>/dev/null)"
B10=$(cat "$T/c10.comments" 2>/dev/null)
( . "$H/bin/lib/block-gate.sh" >/dev/null 2>&1; bg_verdict_clears "$B10" "cromford[bot]" "$HA" ) && ok "C10 the posted body clears the same login's BLOCK (bg_verdict_clears)" || bad "C10 body: $B10"

# C11 the BH-9154 carry (rebind_patch_id) is asked before the HEAD_MOVED arm.
MCS="$DIR/bin/merge-conductor.sh"
L1=$(grep -n 'rebind_patch_id "\$KEY"' "$MCS" | head -1 | cut -d: -f1)
L2=$(grep -n 'headbound_review moved ' "$MCS" | head -1 | cut -d: -f1)
[ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ] && ok "C11 rebind_patch_id (line $L1) runs before headbound_review moved (line $L2)" || bad "C11 lines '$L1' '$L2'"

# C12 provenance mode: the arm is moved-only, no unit.
MODE=provenance APV=BLOCK hb c12 9412 "$HA" green
[ "$(lines "$SLUG#9412")" = 0 ] && ! grep -q HNR_REREVIEW <<<"$(klog "$SLUG#9412")" && ok "C12 provenance: no hnrbuy line, no HNR_REREVIEW" || bad "C12 hnrbuy $(lines "$SLUG#9412") log $(klog "$SLUG#9412")"

for f in "$T"/c*.err; do
  grep -q 'unbound variable\|syntax error\|command not found' "$f" && bad "stderr of ${f##*/}: $(grep -m2 'unbound\|syntax\|not found' "$f")"
done

# ============================================================================
echo "R: the resolver's re-review rung"
awk '/^ *# >>> br rereview post/{f=1;next} /^ *# <<< br rereview post/{exit} f' \
  "$DIR/bin/blocked-resolver.sh" > "$T/br-post.sh"
[ -s "$T/br-post.sh" ] || bad "R no '# >>> br rereview post' block to drive"
# br_drive <name> <num> <class> <source> — the block on PR <num>, one reused verdict.
br_drive() {
  local d="$1"
  ( set -uo pipefail
    . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1
    lib_env_apply() { return 0; }
    . "$H/bin/lib/hnr-rereview.sh"
    HEAD="$HA"
    review_dedupe_on() { return 0; }
    review_bought() { RB_CLASS="$RBC"; RB_SOURCE="$RBS"; RB_WORD="$RBW"; RB_SERVED=claude; return 0; }
    review_bought_prov() { echo claude; }
    mc_rereview() { echo called >> "$T/br-$d.rr"; printf 'x\nVERDICT: APPROVE\n' > "$8"; printf APPROVE; return 0; }
    mc_transition() { printf '%s\n' "$*" >> "$T/br-$d.tr"; }
    mc_slug_of_url() { printf '%s' "$SLUG"; }
    mc_num_of_url()  { printf '%s' "$NUM"; }
    mc_row_field()   { printf '%s' "$REV"; }
    br_pr_field()    { printf '%s' "$HEAD"; return 0; }
    br_record()      { printf '%s|' "$@" >> "$T/br-$d.rec"; echo >> "$T/br-$d.rec"; }
    say()            { printf '%s\n' "$*" >> "$T/br-$d.say"; }
    rp_post()        { printf '%s\n' "$5" >> "$T/br-$d.note"; }
    br_count()       { printf '%s\n' "$1" >> "$T/br-$d.count"; }
    p=demo-os; rkey=DO-1; url="https://github.com/$SLUG/pull/$NUM"; rec="$T/br-rec-$d"; mkdir -p "$rec"
    kind=no-verdict; n=0; tag=no-verdict ctr=rereviews lfctr=lanefails nth="read 1 of 5"
    bought='after the conductor got no verdict'
    . "$T/br-post.sh"
  ) 2> "$T/br-$d.err"
}
NUM=9501 RBC=block RBS=review-prs RBW=BLOCK br_drive r1
[ "$(n "$T/br-r1.rr")" = 1 ] && ok "R1 reused review-prs BLOCK, 0 of 1: mc_rereview called once" || bad "R1 rr $(n "$T/br-r1.rr"); say $(cat "$T/br-r1.say" 2>/dev/null)"
! grep -q 'head-not-reapproved' "$T/br-r1.tr" 2>/dev/null && ok "R1 no head-not-reapproved from the reuse" || bad "R1 tr: $(cat "$T/br-r1.tr")"
grep -q "review-prs's BLOCK on ${HA:0:8} is not reused — the re-review budget has room (unit 1 of 1); buying the read" "$T/br-r1.say" 2>/dev/null && ok "R1 the say line" || bad "R1 say: $(cat "$T/br-r1.say" 2>/dev/null)"
[ "$(lines "$SLUG#9501")" = 1 ] && ok "R1 one hnrbuy line, before the read" || bad "R1 hnrbuy $(lines "$SLUG#9501")"
NUM=9501 RBC=block RBS=review-prs RBW=BLOCK br_drive r1b
[ "$(lines "$SLUG#9501")" = 1 ] && [ "$(n "$T/br-r1b.rr")" = 1 ] && ok "R1 the same head again: one unit, the read is bought" || bad "R1b hnrbuy $(lines "$SLUG#9501") rr $(n "$T/br-r1b.rr")"
# R2 used 1 of 1 on another head: today's reuse and park.
bash -c "$LIBS; mc_attempt_put 'hnrbuy $SLUG#9502 $HB'"
NUM=9502 RBC=block RBS=review-prs RBW=BLOCK br_drive r2
[ "$(n "$T/br-r2.rr")" = 0 ] && grep -q 'BLOCKED_HUMAN head-not-reapproved' "$T/br-r2.tr" 2>/dev/null && ok "R2 budget used: today's reuse and park, no read" \
  || bad "R2 rr $(n "$T/br-r2.rr") tr $(cat "$T/br-r2.tr" 2>/dev/null)"
grep -q 'Re-review not bought: review-prs verdicted BLOCK on this exact head' "$T/br-r2.note" 2>/dev/null && ok "R2 today's reuse comment" || bad "R2 note: $(cat "$T/br-r2.note" 2>/dev/null)"
# R3 source lead: today's park.
NUM=9503 RBC=block RBS=lead RBW=BLOCK br_drive r3
[ "$(n "$T/br-r3.rr")" = 0 ] && grep -q 'BLOCKED_HUMAN head-not-reapproved' "$T/br-r3.tr" 2>/dev/null && [ "$(lines "$SLUG#9503")" = 0 ] && ok "R3 lead BLOCK: today's park, no read, no unit" \
  || bad "R3 rr $(n "$T/br-r3.rr") tr $(cat "$T/br-r3.tr" 2>/dev/null)"
# R4 reused APPROVE: today's rebind, no unit.
NUM=9504 RBC=approve RBS=review-prs RBW=MERGE br_drive r4
[ "$(n "$T/br-r4.rr")" = 0 ] && grep -q ' WAIT_REVIEW ' "$T/br-r4.tr" 2>/dev/null && [ "$(lines "$SLUG#9504")" = 0 ] && ok "R4 reused APPROVE: rebind, no read, no hnrbuy line" \
  || bad "R4 rr $(n "$T/br-r4.rr") tr $(cat "$T/br-r4.tr" 2>/dev/null) hnrbuy $(lines "$SLUG#9504")"
for f in "$T"/br-r*.err; do
  grep -q 'unbound variable\|syntax error\|command not found' "$f" && bad "stderr of ${f##*/}: $(grep -m2 'unbound\|syntax\|not found' "$f")"
done

# ============================================================================
echo "F: the two fragments load the lib"
for FR in "$DIR/bin/merge-conductor.d/bh-9693-hnr-rereview.sh" "$DIR/bin/blocked-resolver.d/bh-9693-hnr-rereview.sh"; do
  R=$(H="$H" bash -c '. "$1"; command -v mc_hnr_decide' _ "$FR" 2>&1)
  [ "$R" = mc_hnr_decide ] && ok "F ${FR#"$DIR"/} defines mc_hnr_decide" || bad "F ${FR#"$DIR"/}: $R"
  R=$(H="$T/no-such-root" bash -c '. "$1"; echo "rc=$?"' _ "$FR" 2>&1)
  [ "$R" = rc=0 ] && ok "F ${FR#"$DIR"/} with no lib: rc 0" || bad "F no lib: $R"
done

# ============================================================================
echo "N1: no vendor call"
[ ! -s "$T/vendor.log" ] && ok "N1 the fake gh/curl log is empty" || bad "N1 vendor calls: $(head -5 "$T/vendor.log")"

echo "mc-head-reapprove.bh-9693: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
