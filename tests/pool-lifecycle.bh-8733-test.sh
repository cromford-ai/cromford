#!/bin/bash
# tests/pool-lifecycle.bh-8733-test.sh — BH-8733 (lifecycle 3/6): the pool
# writes a ticket's phase through the BH-8731 lifecycle verb, and a
# PLAN_BLOCKED reap stores its question in the build_queue row.
#
# Driven, not grepped. The REAL bin/lib/pool-lifecycle.sh, bin/lib/jobs/
# lifecycle.sh (lifecycle_transition), bin/lib/plan-blocked.sh (pb_excerpt),
# bin/lib/execute-empty.sh (_ee_defang) and bin/transcript-scrub.sh run against
# tests/lib/fake-lifecycle.bh-8733.sh, a local fake of the jobs worker seam
# (_jobs_req) that judges every move with the REAL lifecycleCheck of
# worker/jobs/src/lib/lifecycle.js. `gh`, `curl` and `flyctl` on PATH log and
# fail if anything reaches them (0 network).
#   R1-R2   the reproduction: a PLAN_BLOCKED reap stores plan_blocked and the
#           question, also for a rebuild over pr_open (the #8765 BLOCK).
#   W1-W13  pool_phase_set / pool_phase_reap / pool_phase_get, and the 409 table.
#   W9-W9g  the BLOCK of verdict 5198: a plan_blocked refused on a key in
#           merged/closed places ONE needs-human hold (a scratch stub of
#           bin/needs-human-hold.sh); other refusals get one ALERTS line.
#   E1-E6   the blocks cut from the REAL bin/fly-pool.sh: the reap, the spawn
#           gate, push_preplan, the spawned and reused writes. Each is also run
#           with its call removed (the call is what writes).
#   E7      the REAL pool_spawn_decision refuses a merged key at the HOLD arm
#           after its PLAN_BLOCKED reap, and spawns it with the hold call cut.
# Needs node (the fake runs the real lifecycleCheck). With no node the suite
# fails, unless HARNESS_ALLOW_SKIP=1 is set: then it says SKIP and passes.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pool-lifecycle.bh-8733-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/fake-lifecycle.bh-8733.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
if ! command -v node >/dev/null 2>&1; then
  [ "${HARNESS_ALLOW_SKIP:-0}" = 1 ] && { echo "SKIP: pool-lifecycle.bh-8733: no node for the fake's lifecycleCheck"; exit 0; }
  echo "FAIL: node is required (the fake runs the real lifecycleCheck); set HARNESS_ALLOW_SKIP=1 to skip"; exit 1
fi

LIB="$SRC/bin/lib/pool-lifecycle.sh"
POOL="$SRC/bin/fly-pool.sh"
[ -f "$LIB" ] && ok || bad "missing bin/lib/pool-lifecycle.sh"

H="$T/h"; mkdir -p "$H/bin" "$H/builds" "$T/fakebin" "$T/q"
scratch_install_closure bin/transcript-scrub.sh "$H" >/dev/null || { echo "FAIL: cannot install bin/transcript-scrub.sh"; exit 1; }
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTLOG"
exit 0
SH
chmod +x "$H/bin/alert-line.sh"
# needs-human-hold.sh posts on GitHub, so it is a scratch stub (the seam): one
# tab-joined argv line per call in $NHLOG; on rc 0 (NHH_RC, default 0) the
# marker $NHMARK/<issue> stands for the nh-fp comment the HOLD gate reads.
cat > "$H/bin/needs-human-hold.sh" <<'SH'
#!/bin/bash
( IFS=$'\t'; printf '%s\n' "$*" ) >> "$NHLOG"
rc="${NHH_RC:-0}"
[ "$rc" = 0 ] && mkdir -p "$NHMARK" && : > "$NHMARK/$2"
exit "$rc"
SH
chmod +x "$H/bin/needs-human-hold.sh"
for v in gh curl flyctl; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "%s/vendor.log"\nexit 1\n' "$v" "$T" > "$T/fakebin/$v"
  chmod +x "$T/fakebin/$v"
done

N=0
# fresh: a new store, say log and alert log per case, so no case reads another's state.
fresh() { N=$((N+1)); lf_init "$T/lf$N"; SAY="$T/say$N.log"; ALERTLOG="$T/alert$N.log"; : > "$SAY"; : > "$ALERTLOG"
  NHLOG="$T/nh$N.log"; NHMARK="$T/nhmark$N"; : > "$NHLOG"; }
nhn() { local c; c=$(grep -c . "$NHLOG" 2>/dev/null); echo "${c:-0}"; }
# rec <key> <result line 1> [plan.md lines...] -> prints the record dir
rec() {
  local k="$1" l1="$2" d; shift 2
  d="$H/builds/pool-bh-$k-202611011700$N"; mkdir -p "$d"
  printf '%s\nBUILD_DIR: /root/harness/builds/cromford-%s-x\n' "$l1" "$k" > "$d/RESULT"
  [ $# -gt 0 ] && printf '%s\n' "$@" > "$d/plan.md"
  printf '%s' "$d"
}
# libs: the libs the pool loads, in a subshell that already set HARNESS/PATH/say.
libs() {
  # shellcheck disable=SC1090,SC1091
  . "$SRC/bin/lib/plan-blocked.sh" || exit 9
  # shellcheck disable=SC1090,SC1091
  . "$SRC/bin/lib/execute-empty.sh" || exit 9
  # shellcheck disable=SC1090,SC1091
  . "$SRC/bin/lib/jobs/lifecycle.sh" || exit 9
  # shellcheck disable=SC1090
  . "$LIB" || exit 9
}
# RUN <cmd...> — the command with the libs loaded and say logged.
RUN() {
  ( export HARNESS="$H" PATH="$T/fakebin:$PATH" ALERTLOG NHLOG NHMARK
    say() { printf '%s\n' "$*" >> "$SAY"; }
    libs
    "$@" )
}
posts() { lf_calls 'POST /api/lifecycle/transition'; }
ev() { local c; c=$(grep -c . "$LF_DIR/events.log" 2>/dev/null); echo "${c:-0}"; }
cnt() { local c; c=$(grep -c -- "${2:-.}" "$1" 2>/dev/null); echo "${c:-0}"; }
clean() { [ ! -s "$LF_DIR/unimpl.log" ] && [ ! -s "$LF_DIR/400.log" ]; }

# ═════ R: the reproduction ══════════════════════════════════════════════════
# R1 PLAN_BLOCKED from building: plan_blocked, and the question is the excerpt.
fresh; lf_row bh BH-9101 building
D=$(rec BH-9101 "PLAN_BLOCKED /root/harness/builds/cromford-BH-9101-x/plan.md" \
  "BLOCKED: needs the Fly org name" "The plan cannot pick the org for the test host." "" "## Context" "not this")
RUN pool_phase_reap bh BH-9101 "$D"; R=$?
WANT=$( ( export HARNESS="$H"; libs; pb_excerpt "$D/plan.md" | _ee_defang ) )
[ "$R" = 0 ] && [ "$(lf_get bh BH-9101 phase)" = plan_blocked ] && [ -n "$WANT" ] && [ "$(lf_get bh BH-9101 question)" = "$WANT" ] \
  && ok || bad "R1 want phase plan_blocked with the question '$WANT' (rc $R, phase $(lf_get bh BH-9101 phase), q '$(lf_get bh BH-9101 question)')"
grep -q '^bh BH-9101 building plan_blocked pool - PLAN_BLOCKED at pool-bh-BH-9101-' "$LF_DIR/events.log" && [ "$(ev)" = 1 ] \
  && ok || bad "R1 want one building->plan_blocked event by pool: $(lf_events)"
clean && ok || bad "R1 an unimplemented request or a 400: $(cat "$LF_DIR/unimpl.log" "$LF_DIR/400.log")"

# R2 a rebuild over pr_open: the spawn moves it to building, the reap to plan_blocked.
fresh; lf_row bh BH-9102 pr_open
D=$(rec BH-9102 "PLAN_BLOCKED" "BLOCKED: which repo owns the cert?")
RUN pool_phase_set bh BH-9102 building "machine m-r2 spawned"
RUN pool_phase_reap bh BH-9102 "$D"
[ "$(lf_get bh BH-9102 phase)" = plan_blocked ] && case "$(lf_get bh BH-9102 question)" in *"which repo owns the cert"*) true ;; *) false ;; esac \
  && [ "$(lf_events | awk '{print $3">"$4}' | tr '\n' ' ')" = "pr_open>building building>plan_blocked " ] \
  && ok || bad "R2 a key in pr_open must reach plan_blocked with the question (phase $(lf_get bh BH-9102 phase); events: $(lf_events | tr '\n' ';'); say: $(tr '\n' ';' < "$SAY"))"

# ═════ W: the writer, the reader and the 409 table ══════════════════════════
# W1 building from NULL: 200 and the line.
fresh; lf_row bh BH-9201
RUN pool_phase_set bh BH-9201 building "machine m1 spawned"; R=$?
[ "$R" = 0 ] && [ "$(lf_get bh BH-9201 phase)" = building ] && [ "$(lf_get bh BH-9201 phase_actor)" = pool ] \
  && grep -qx 'BH-9201: phase -> building' "$SAY" && ok || bad "W1 want building by pool and the line (rc $R; say $(cat "$SAY"))"
# W2 building again: a 409 current == to is silent.
RUN pool_phase_set bh BH-9201 building "machine m2 spawned"; R=$?
[ "$R" = 0 ] && [ "$(posts)" = 2 ] && [ "$(ev)" = 1 ] && [ "$(cnt "$SAY")" = 1 ] \
  && ok || bad "W2 a repeat is one POST, no event, no line (rc $R; posts $(posts); say $(cat "$SAY"))"
# W3 PR_CREATED .../pull/0042: pr_open, pr 42.
fresh; lf_row bh BH-9203 building
D=$(rec BH-9203 "PR_CREATED https://github.com/o/r/pull/0042")
RUN pool_phase_reap bh BH-9203 "$D"
[ "$(lf_events | awk '{print $4, $6}')" = "pr_open 42" ] && [ "$(lf_get bh BH-9203 question)" = null ] \
  && grep -qx 'BH-9203: phase -> pr_open' "$SAY" && ok || bad "W3 want pr_open pr 42 ($(lf_events); $(cat "$SAY"))"
# W4 RESULT_UNVERIFIED and the other non-writing words: 0 calls.
for w in "RESULT_UNVERIFIED PR_CREATED https://github.com/o/r/pull/9" "RESULT_MALFORMED PR_CREATED" "BUILD_DEFERRED slots" \
         "EXECUTE_EMPTY" "PR_CREATE_FAILED x" "XPLAN_BLOCKED /x/plan.md" "PR_CREATED https://github.com/o/r/issues/5"; do
  fresh; lf_row bh BH-9204 building
  D=$(rec BH-9204 "$w" "BLOCKED: q")
  RUN pool_phase_reap bh BH-9204 "$D"
  [ "$(lf_calls)" = 0 ] && [ "$(lf_get bh BH-9204 phase)" = building ] && ok || bad "W4 '$w' must write nothing ($(lf_calls) calls)"
done
# W4b line 2 says PLAN_BLOCKED, line 1 does not: nothing.
fresh; lf_row bh BH-9205 building
D=$(rec BH-9205 "BUILD_DEFERRED slots"); printf 'PLAN_BLOCKED\n' >> "$D/RESULT"
RUN pool_phase_reap bh BH-9205 "$D"
[ "$(lf_calls)" = 0 ] && ok || bad "W4b only RESULT line 1 decides"

# W5 the question round trip: 2500 bytes with tabs in, at most 2000 out, cut on
# a line end, defanged; pool_phase_get prints it with no tab and no newline.
fresh; lf_row bh BH-9206 building
LONG=$(for i in $(seq -w 1 30); do printf 'line %s\tof the blocked question; resume it later, this one is long, padded to eighty-odd bytes....\n' "$i"; done)
D=$(rec BH-9206 "PLAN_BLOCKED" "BLOCKED: start" "$LONG")
[ "$(printf '%s\n%s' "BLOCKED: start" "$LONG" | LC_ALL=C wc -c)" -ge 2500 ] && ok || bad "W5 setup: the plan text must be at least 2500 bytes"
RUN pool_phase_reap bh BH-9206 "$D"
Q=$(lf_get bh BH-9206 question)
QB=$(printf '%s' "$Q" | LC_ALL=C wc -c)
[ "$QB" -le 2000 ] && [ "$QB" -gt 1900 ] && case "$Q" in *"bytes....") true ;; *) false ;; esac \
  && case "$Q" in *[Rr]esume*) false ;; *) true ;; esac && case "$Q" in *"r_esume"*) true ;; *) false ;; esac \
  && clean && ok || bad "W5 stored: want 1900 < bytes <= 2000, a line end, defanged (got $QB bytes; 400s: $(cat "$LF_DIR/400.log"))"
G=$(RUN pool_phase_get bh BH-9206); R=$?
F1=$(cut -f1 <<<"$G"); F3=$(cut -f3- <<<"$G")
[ "$R" = 0 ] && [ "$F1" = plan_blocked ] && [ "$(printf '%s' "$G" | awk -F'\t' '{print NF}')" = 3 ] \
  && [ "$(printf '%s' "$G" | grep -c .)" = 1 ] && [ "$F3" = "$(printf '%s' "$Q" | tr '\t\n' '  ')" ] \
  && ok || bad "W5 read back: want 3 tab fields on one line, the question flattened (rc $R; '${G:0:120}')"
# W5b the knob cuts shorter; a value outside 1..2000 is the default.
fresh; lf_row bh BH-9207 building
D=$(rec BH-9207 "PLAN_BLOCKED" "BLOCKED: start" "$LONG")
( export POOL_LIFECYCLE_QUESTION_MAX=200; RUN pool_phase_reap bh BH-9207 "$D" )
Q=$(lf_get bh BH-9207 question); QB=$(printf '%s' "$Q" | LC_ALL=C wc -c)
[ "$QB" -le 200 ] && [ "$QB" -gt 50 ] && ok || bad "W5b POOL_LIFECYCLE_QUESTION_MAX=200 gives at most 200 bytes (got $QB)"
fresh; lf_row bh BH-9208 building
D=$(rec BH-9208 "PLAN_BLOCKED" "BLOCKED: start" "$LONG")
( export POOL_LIFECYCLE_QUESTION_MAX=99999; RUN pool_phase_reap bh BH-9208 "$D" )
QB=$(printf '%s' "$(lf_get bh BH-9208 question)" | LC_ALL=C wc -c)
[ "$QB" -le 2000 ] && [ "$QB" -gt 1900 ] && clean && ok || bad "W5b a knob over 2000 falls back to 2000 (got $QB)"
# W5c no plan.md: the question names the record, never empty.
fresh; lf_row bh BH-9209 building
D=$(rec BH-9209 "PLAN_BLOCKED")
RUN pool_phase_reap bh BH-9209 "$D"
case "$(lf_get bh BH-9209 question)" in *"pool-bh-BH-9209-"*) ok ;; *) bad "W5c no plan.md: the question names the record (got '$(lf_get bh BH-9209 question)')" ;; esac

# rep <n> <start phase|""> <to> <result line 1> <want final phase> <want posts>
rep() {
  local n="$1" st="$2" l1="$4" want="$5" wp="$6" k="BH-93$N" D
  fresh; lf_row bh "$k" "$st"
  D=$(rec "$k" "$l1" "BLOCKED: q of $k")
  RUN pool_phase_reap bh "$k" "$D"
  [ "$(lf_get bh "$k" phase)" = "$want" ] && [ "$(posts)" = "$wp" ] && clean \
    && ok || bad "$n from '${st:-NULL}': want $want after $wp POSTs (phase $(lf_get bh "$k" phase), posts $(posts); $(lf_events | tr '\n' ';'))"
}
# W6 plan_blocked from planned is legal at once (lifecycle.js): 1 POST, no repair.
rep W6 planned plan_blocked PLAN_BLOCKED plan_blocked 1
# W7 plan_blocked from NULL (a machine spawned before this writer): building
# (repair), then plan_blocked: 3 POSTs.
rep W7 "" plan_blocked PLAN_BLOCKED plan_blocked 3
grep -q '^bh BH-93[0-9]* null building pool - repair: PLAN_BLOCKED at ' "$LF_DIR/events.log" && grep -q ': phase -> building (repair)$' "$SAY" \
  && ok || bad "W7 the repair move says repair: $(lf_events)"
# W7b plan_blocked from triaged is legal at once: 1 POST.
rep W7b triaged plan_blocked PLAN_BLOCKED plan_blocked 1
# W8 pr_open from planned repairs.
rep W8 planned pr_open "PR_CREATED https://github.com/o/r/pull/77" pr_open 3
# W9 (BLOCK 5198) plan_blocked from merged on an issues ticket: refused, and
# ONE needs-human hold carries the question. 2 reaps of one record: 1 hold
# call, 0 ALERTS lines.
fresh; lf_row bh BH-9401 merged
D=$(rec BH-9401 "PLAN_BLOCKED" "BLOCKED: which Fly org owns q9?")
RUN pool_phase_reap bh BH-9401 "$D" 8733; RUN pool_phase_reap bh BH-9401 "$D" 8733
FP9=$(printf '%s' "bh:BH-9401:plan_blocked-refused" | sha1sum | cut -c1-16)
[ "$(lf_get bh BH-9401 phase)" = merged ] && [ "$(posts)" = 2 ] && [ "$(nhn)" = 1 ] && [ "$(cnt "$ALERTLOG")" = 0 ] \
  && [ "$(sed -n 1p "$NHLOG" | cut -f1-3)" = "$(printf 'bh\t8733\t%s' "$FP9")" ] \
  && [ "$(sed -n 1p "$NHLOG" | cut -f5)" = plan-blocked ] && [ "$(sed -n 1p "$NHLOG" | awk -F'\t' '{print NF}')" = 5 ] \
  && [ -e "$D/lifecycle-refused.held" ] && [ "$(cnt "$SAY" 'hold placed on #8733')" = 1 ] \
  && [ "$(cnt "$SAY" 'phase -> plan_blocked refused (illegal_transition; current merged)')" = 2 ] \
  && ok || bad "W9 merged: want 1 hold call (bh 8733 $FP9 ... plan-blocked), .held, 0 ALERTS (posts $(posts); holds $(cat "$NHLOG" 2>/dev/null); alerts $(cat "$ALERTLOG"); say $(cat "$SAY"))"
A9=$(sed -n 1p "$NHLOG" 2>/dev/null | cut -f4)
case "$A9" in *"which Fly org owns q9?"*"") true ;; *) false ;; esac && case "$A9" in *"BH-9401"*"merged"*) true ;; *) false ;; esac \
  && ! grep -qiwE 'HOLD|RESUME|lift|unhold' <<<"$A9" && ok || bad "W9 the action holds the key, the phase and the question, and no hold/lift word: '$A9'"
# W9b the same from closed.
fresh; lf_row bh BH-9402 closed
D=$(rec BH-9402 "PLAN_BLOCKED" "BLOCKED: q9b")
RUN pool_phase_reap bh BH-9402 "$D" 0042; RUN pool_phase_reap bh BH-9402 "$D" 0042
[ "$(lf_get bh BH-9402 phase)" = closed ] && [ "$(nhn)" = 1 ] && [ "$(cnt "$ALERTLOG")" = 0 ] && [ -e "$D/lifecycle-refused.held" ] \
  && [ "$(sed -n 1p "$NHLOG" | cut -f2)" = 0042 ] && case "$(sed -n 1p "$NHLOG" | cut -f4)" in *q9b*closed*|*closed*q9b*) true ;; *) false ;; esac \
  && ok || bad "W9b closed: want 1 hold call and .held (holds $(cat "$NHLOG" 2>/dev/null); alerts $(cat "$ALERTLOG"))"
# W9c the hold fails (rc 1, then rc 75): no .held, 1 ALERTS line, a second reap adds nothing.
for hrc in 1 75; do
  fresh; lf_row bh BH-9403 merged
  D=$(rec BH-9403 "PLAN_BLOCKED" "BLOCKED: q9c")
  ( export NHH_RC=$hrc; RUN pool_phase_reap bh BH-9403 "$D" 8733; RUN pool_phase_reap bh BH-9403 "$D" 8733 )
  [ ! -e "$D/lifecycle-refused.held" ] && [ "$(cnt "$ALERTLOG")" = 1 ] && [ "$(cnt "$ALERTLOG" "hold not placed (rc $hrc)")" = 1 ] \
    && grep -qF -- '--project bh' "$ALERTLOG" && grep -qF '[pool/bh] BH-9403: PLAN_BLOCKED not stored (current merged)' "$ALERTLOG" \
    && [ "$(cnt "$SAY" 'hold placed')" = 0 ] \
    && ok || bad "W9c hold rc $hrc: want no .held, 1 ALERTS line 'hold not placed (rc $hrc)' (holds $(nhn); alerts $(cat "$ALERTLOG"); say $(cat "$SAY"))"
done
# W9d merged on a board ticket (no issue): 0 hold calls, 1 ALERTS line naming it.
fresh; lf_row bh BH-9404 merged
D=$(rec BH-9404 "PLAN_BLOCKED" "BLOCKED: q9d")
RUN pool_phase_reap bh BH-9404 "$D" cmabc123; RUN pool_phase_reap bh BH-9404 "$D" cmabc123
[ "$(nhn)" = 0 ] && [ "$(cnt "$ALERTLOG")" = 1 ] && [ "$(cnt "$ALERTLOG" 'board ticket')" = 1 ] && [ ! -e "$D/lifecycle-refused.held" ] \
  && ok || bad "W9d board ticket: want 0 hold calls, 1 ALERTS line naming the board ticket (holds $(nhn); alerts $(cat "$ALERTLOG"))"
# W9e a non-terminal refusal (the gate refuses those keys): 0 hold calls, 1 plain ALERTS line.
for st in abandoned in_queue ejected; do
  fresh; lf_row bh BH-9405 "$st"; D=$(rec BH-9405 "PLAN_BLOCKED" "BLOCKED: q")
  RUN pool_phase_reap bh BH-9405 "$D" 8733; RUN pool_phase_reap bh BH-9405 "$D" 8733
  [ "$(posts)" = 2 ] && [ "$(lf_get bh BH-9405 phase)" = "$st" ] && [ "$(nhn)" = 0 ] && [ "$(cnt "$ALERTLOG")" = 1 ] \
    && grep -qF "BH-9405: PLAN_BLOCKED not stored (current $st)" "$ALERTLOG" \
    && ! grep -qiE 'board ticket|hold' "$ALERTLOG" \
    && ok || bad "W9e from $st: no repair, 0 hold calls, 1 plain ALERTS line (posts $(posts); holds $(nhn); alerts $(cat "$ALERTLOG"))"
done
# W9f a pr_open refused from in_queue or merged: one line, no ALERTS line, no hold.
for st in in_queue merged; do
  fresh; lf_row bh BH-9406 "$st"; D=$(rec BH-9406 "PR_CREATED https://github.com/o/r/pull/5")
  RUN pool_phase_reap bh BH-9406 "$D" 8733
  [ "$(posts)" = 1 ] && [ "$(cnt "$ALERTLOG")" = 0 ] && [ "$(nhn)" = 0 ] && [ "$(cnt "$SAY" 'phase -> pr_open refused')" = 1 ] \
    && ok || bad "W9f pr_open refused from $st: one line, no alert, no hold (say $(cat "$SAY"))"
done
# W9h no bin/needs-human-hold.sh on this box: rc 127, no .held, 1 ALERTS line.
fresh; lf_row bh BH-9408 merged; D=$(rec BH-9408 "PLAN_BLOCKED" "BLOCKED: q9h")
mv "$H/bin/needs-human-hold.sh" "$T/nhh.off"
RUN pool_phase_reap bh BH-9408 "$D" 8733
mv "$T/nhh.off" "$H/bin/needs-human-hold.sh"
[ ! -e "$D/lifecycle-refused.held" ] && [ "$(cnt "$ALERTLOG" 'hold not placed (rc 127)')" = 1 ] \
  && ok || bad "W9h no hold script: want 1 ALERTS line 'hold not placed (rc 127)' (alerts $(cat "$ALERTLOG"))"
# W9g plan_blocked already stored (current == to): silent, no hold, no ALERTS line.
fresh; lf_row bh BH-9407 plan_blocked "q"; D=$(rec BH-9407 "PLAN_BLOCKED" "BLOCKED: q")
RUN pool_phase_reap bh BH-9407 "$D" 8733
[ "$(nhn)" = 0 ] && [ "$(cnt "$ALERTLOG")" = 0 ] && ok || bad "W9g current plan_blocked: no hold, no alert"
# W10 the repair's building is refused (a worker without pr_open -> building):
# the writer stops after 1 extra call.
sed 's/pr_open:      \["building", /pr_open:      [/' "$SRC/worker/jobs/src/lib/lifecycle.js" > "$T/lifecycle-old.js"
grep -q 'pr_open:      \["in_queue"' "$T/lifecycle-old.js" && ok || bad "W10 setup: could not drop the pr_open -> building edge"
fresh; lf_row bh BH-9404 pr_open; D=$(rec BH-9404 "PLAN_BLOCKED" "BLOCKED: q10")
( LF_LIFECYCLE_JS="$T/lifecycle-old.js"; RUN pool_phase_reap bh BH-9404 "$D" )
[ "$(posts)" = 2 ] && [ "$(lf_get bh BH-9404 phase)" = pr_open ] && [ "$(cnt "$ALERTLOG")" = 1 ] \
  && ok || bad "W10 want 2 POSTs, phase still pr_open, 1 ALERTS line (posts $(posts); $(cat "$SAY"))"
# W11 a lane key sends 0 calls.
for k in RB-1-abc RR-77-abc12345 LR-BH-1 FXR-BH-1-2 CP-BH-1; do
  fresh; lf_row bh "$k" building; D=$(rec "$k" "PLAN_BLOCKED" "BLOCKED: q")
  RUN pool_phase_reap bh "$k" "$D"; RUN pool_phase_set bh "$k" building "machine m spawned"
  [ "$(lf_calls)" = 0 ] && ok || bad "W11 $k must send 0 calls ($(lf_calls))"
done
# W12 an outage: one 'not written' line per call and rc 0, under set -u.
fresh; lf_row bh BH-9405 building; echo 1 > "$LF_DIR/rc"
OUT=$( ( set -u; RUN pool_phase_set bh BH-9405 building "machine m1 spawned" ); echo "rc=$?")
[ "$OUT" = "rc=0" ] && [ "$(cnt "$SAY" 'not written: the lifecycle DB is unreadable')" = 1 ] && [ "$(posts)" = 1 ] \
  && ok || bad "W12 outage: rc 0, one line, no retry (got $OUT; posts $(posts); $(cat "$SAY"))"
fresh; lf_row bh BH-9405 building; echo 1 > "$LF_DIR/rc"
G=$(RUN pool_phase_get bh BH-9405); R=$?
[ "$R" = 1 ] && [ -z "$G" ] && ok || bad "W12 pool_phase_get on an outage is rc 1 (got $R '$G')"
fresh
G=$(RUN pool_phase_get bh BH-9406); R=$?
[ "$R" = 2 ] && [ -z "$G" ] && ok || bad "W12 pool_phase_get with no row is rc 2 (got $R '$G')"
fresh; lf_row bh BH-9407
[ "$(RUN pool_phase_get bh BH-9407)" = "$(printf -- '-\t-\t-')" ] && ok || bad "W12 a NULL phase reads '-<TAB>-<TAB>-'"
# W13 no verb on this host: 0 requests, one line per process.
mkdir -p "$T/noverb"; cp "$LIB" "$T/noverb/pool-lifecycle.sh"
fresh; lf_row bh BH-9408 building
( export HARNESS="$H"; say() { printf '%s\n' "$*" >> "$SAY"; }
  # shellcheck disable=SC1090
  . "$T/noverb/pool-lifecycle.sh" || exit 9
  pool_phase_set bh BH-9408 building "machine m1 spawned"; pool_phase_set bh BH-9408 building "machine m2 spawned"; echo "rc=$?" > "$T/w13.rc" )
[ "$(cat "$T/w13.rc")" = "rc=0" ] && [ "$(lf_calls)" = 0 ] && [ "$(cnt "$SAY" 'no verb')" = 1 ] \
  && ok || bad "W13 no verb: rc 0, 0 calls, one line ($(cat "$SAY"))"

# ═════ E: the blocks of the REAL bin/fly-pool.sh ════════════════════════════
blk() { awk -v s="$1" -v e="$2" 'index($0, s){f=1} f; f && index($0, e){exit}' "$POOL"; }
nocall() { grep -v 'pool_phase_' "$1"; }
# E1 the reap block: the row is closed `done`, THEN the phase is written.
blk '# >>> reap row close (BH-614)' '# <<< lifecycle phase' > "$T/reap.sh"
grep -qF 'pool_phase_reap "$P" "$KEY" "$LOCAL" "$TICKET"' "$T/reap.sh" && grep -q 'QROW done' "$T/reap.sh" && ok || bad "E1 setup: the reap row close and the lifecycle block must be adjacent in bin/fly-pool.sh"
nocall "$T/reap.sh" > "$T/reap-nocall.sh"
REAP() { # REAP <block> <key> <dir>
  ( export HARNESS="$H" PATH="$T/fakebin:$PATH" ALERTLOG NHLOG NHMARK
    say() { printf '%s\n' "$*" >> "$SAY"; }
    libs
    QROW() { printf 'QROW %s %s\n' "$1" "$2" >> "$LF_DIR/req.log"; }
    # shellcheck disable=SC2034 # read by the cut block
    P=bh; KEY="$2"; LOCAL="$3"; TICKET="${2#BH-}"; MID="m-e1"
    # shellcheck disable=SC1090
    . "$1" )
}
fresh; lf_row bh BH-9501 building
D=$(rec BH-9501 "PLAN_BLOCKED" "BLOCKED: the e1 question")
REAP "$T/reap.sh" BH-9501 "$D"
[ "$(awk '{print $1, $2}' "$LF_DIR/req.log" | tr '\n' ';')" = "QROW done;POST /api/lifecycle/transition;" ] \
  && [ "$(lf_get bh BH-9501 phase)" = plan_blocked ] && case "$(lf_get bh BH-9501 question)" in *"the e1 question"*) true ;; *) false ;; esac \
  && ok || bad "E1 want QROW done, then the plan_blocked write: $(tr '\n' ';' < "$LF_DIR/req.log")"
fresh; lf_row bh BH-9501 building
REAP "$T/reap-nocall.sh" BH-9501 "$D"
[ "$(posts)" = 0 ] && [ "$(lf_get bh BH-9501 phase)" = building ] && ok || bad "E1 mutation: the reap block without the call writes no phase"
fresh; lf_row bh BH-9502 building
D=$(rec BH-9502 "PR_CREATED https://github.com/o/r/pull/314")
REAP "$T/reap.sh" BH-9502 "$D"
[ "$(lf_events | awk '{print $4, $6}')" = "pr_open 314" ] && ok || bad "E1 the reap block writes pr_open 314 ($(lf_events))"
# E1b the order in the real file: PR_CREATED verify < row close < lifecycle phase.
ln_of() { grep -nF -- "$1" "$POOL" | head -1 | cut -d: -f1; }
A=$(ln_of '# <<< PR_CREATED verify'); B=$(ln_of '# <<< reap row close'); C=$(ln_of '# >>> lifecycle phase (BH-8733)')
[ -n "$A" ] && [ -n "$B" ] && [ -n "$C" ] && [ "$A" -lt "$B" ] && [ "$B" -lt "$C" ] \
  && ok || bad "E1b order: PR_CREATED verify ($A) < row close ($B) < lifecycle phase ($C)"
grep -qE '^\. "\$HARNESS/bin/lib/pool-lifecycle.sh"' "$POOL" && ok || bad "E1b bin/fly-pool.sh must source bin/lib/pool-lifecycle.sh"

# E3 a writer outage still closes the row done; one line; no abort.
fresh; lf_row bh BH-9503 building; echo 1 > "$LF_DIR/rc"
D=$(rec BH-9503 "PLAN_BLOCKED" "BLOCKED: q")
OUT=$( (REAP "$T/reap.sh" BH-9503 "$D"); echo "rc=$?")
[ "$OUT" = "rc=0" ] && grep -q '^QROW done BH-9503$' "$LF_DIR/req.log" && [ "$(cnt "$SAY" 'not written')" = 1 ] \
  && ok || bad "E3 outage: the row closes done, one line (got $OUT; $(tr '\n' ';' < "$LF_DIR/req.log"))"

# E2 the REAL pool_spawn_decision refuses a plan_blocked key before
# pool_gates_applicable is consulted, and the row stays queued.
awk '/^pool_spawn_decision\(\) \{/{f=1} f; f && /^}/{exit}' "$POOL" > "$T/psd.sh"
awk '/# >>> plan-blocked stop/{s=1} !s; /# <<< plan-blocked stop/{s=0}' "$T/psd.sh" > "$T/psd-nogate.sh"
[ -s "$T/psd.sh" ] && ! cmp -s "$T/psd.sh" "$T/psd-nogate.sh" && ok || bad "E2 setup: pool_spawn_decision with a plan-blocked stop block"
PSD() { # PSD <psd-file> <key> -> "rc=<rc>"; the gates after it log to $T/psd.log
  local k="$2"; echo '{}' > "$T/q/$k.json"
  ( export HARNESS="$H" PATH="$T/fakebin:$PATH" ALERTLOG NHLOG NHMARK
    # shellcheck disable=SC2034 # read by the cut function
    P=bh; QDIR="$T/q"; LOG="$T/pool.err"; POOL_SLUG=""
    say() { printf '%s\n' "$*" >> "$SAY"; }
    libs
    # shellcheck disable=SC1090,SC1091
    . "$SRC/bin/lib/plan-blocked-stop.sh" || exit 9
    QROW() { printf 'QROW %s\n' "$*" >> "$T/psd.log"; }
    pool_tick_budget_spent() { return 1; }
    pool_gates_applicable() { printf 'gates\n' >> "$T/psd.log"; return 1; }
    # shellcheck disable=SC1090
    . "$1"
    pool_spawn_decision "$T/q/$k.json" "$k" "${k#BH-}"; echo "rc=$?" )
}
fresh; rm -f "$T/psd.log"; lf_row bh BH-9504 plan_blocked "Which Fly org owns the test host?"
OUT=$(PSD "$T/psd.sh" BH-9504)
[ "$OUT" = "rc=1" ] && [ -e "$T/q/BH-9504.json" ] && [ ! -s "$T/psd.log" ] \
  && grep -q 'skipping BH-9504: phase plan_blocked since 2026-11-01T16:00:00Z.*Which Fly org owns the test host' "$SAY" \
  && ok || bad "E2 want rc 1, the queue file kept, no gates/QROW call, the line (got $OUT; log $(cat "$T/psd.log" 2>/dev/null); say $(cat "$SAY"))"
[ "$(lf_get bh BH-9504 status)" = queued ] && [ "$(posts)" = 0 ] && ok || bad "E2 the row stays queued and no phase is written"
fresh; rm -f "$T/psd.log"; lf_row bh BH-9504 plan_blocked "q"
OUT=$(PSD "$T/psd-nogate.sh" BH-9504)
[ "$OUT" = "rc=0" ] && grep -qx gates "$T/psd.log" && ok || bad "E2 mutation: without the block the key reaches pool_gates_applicable (got $OUT)"
fresh; rm -f "$T/psd.log"; lf_row bh BH-9505 pr_open
OUT=$(PSD "$T/psd.sh" BH-9505)
[ "$OUT" = "rc=0" ] && grep -qx gates "$T/psd.log" && ok || bad "E2 a pr_open key (a rebuild) passes the gate (got $OUT)"
# E2b the line order in the real function: execute-empty < plan-blocked < gates.
ln_psd() { grep -n -- "$1" "$T/psd.sh" | head -1 | cut -d: -f1; }
EE=$(ln_psd '# <<< execute-empty stop'); PB=$(ln_psd 'pbs_stop_check "\$P"'); GA=$(ln_psd 'if ! pool_gates_applicable'); AG=$(ln_psd 'pool_after_gate "\$JF"')
[ -n "$EE" ] && [ -n "$PB" ] && [ -n "$GA" ] && [ -n "$AG" ] && [ "$EE" -lt "$PB" ] && [ "$PB" -lt "$GA" ] && [ "$GA" -lt "$AG" ] \
  && ok || bad "E2b order execute-empty < pbs < gates < after: $EE $PB $GA $AG"

# E7 (BLOCK 5198) the key in merged does not loop: after the W9 reap, the REAL
# pool_spawn_decision refuses it at the HOLD arm (rc 1, no spawn). The hold read
# answers held iff the stub's marker for that issue exists. With the marker gone
# (a person lifted it) the decision passes the HOLD arm. With the T3 hold call
# cut out of pool-lifecycle.sh, the same reap leaves the key spawnable (rc 0):
# the call is what stops the loop.
PSD7() { # PSD7 <lib file> <key> <ticket> -> "rc=<rc>"; the gates after the HOLD arm log to $T/psd7.log
  local k="$2" tk="$3"; echo '{}' > "$T/q/$k.json"
  ( export HARNESS="$H" PATH="$T/fakebin:$PATH" ALERTLOG NHLOG NHMARK
    # shellcheck disable=SC2034 # read by the cut function
    P=bh; QDIR="$T/q"; LOG="$T/pool.err"; POOL_SLUG="o/r"; _PHC_READ_S=0
    say() { printf '%s\n' "$*" >> "$SAY"; }
    libs
    # shellcheck disable=SC1090
    . "$1" || exit 9
    # shellcheck disable=SC1090,SC1091
    . "$SRC/bin/lib/plan-blocked-stop.sh" || exit 9
    QROW() { printf 'QROW %s\n' "$*" >> "$T/psd7.log"; }
    pool_tick_budget_spent() { return 1; }
    pool_gates_applicable() { return 0; }
    pool_after_gate() { return 0; }
    pool_hold_check() { if [ -e "$NHMARK/$1" ]; then printf 'held\thold:waiting-on-human\n'; else printf 'clear\topen\n'; fi; }
    pool_hold_read() { _PHR_V=$(pool_hold_check "$1"); }
    pool_hold_marked() { printf 'held-marked %s\n' "$1" >> "$T/psd7.log"; }
    pool_hold_clear() { return 0; }
    pool_terminal_path() { printf '%s/%s.terminal' "$T" "$1"; }
    pr_exists_for_key_rest() { printf 'pr-check %s\n' "$1" >> "$T/psd7.log"; return 1; }
    pool_terminal_check() { return 0; }
    job_is_hot() { return 1; }
    pool_spawn_cap_check() { printf 'cap %s\n' "$1" >> "$T/psd7.log"; return 0; }
    # shellcheck disable=SC1090
    . "$T/psd.sh"
    pool_spawn_decision "$T/q/$k.json" "$k" "$tk"; echo "rc=$?" )
}
fresh; rm -f "$T/psd7.log"; lf_row bh BH-9601 merged
D=$(rec BH-9601 "PLAN_BLOCKED" "BLOCKED: e7 which host?")
RUN pool_phase_reap bh BH-9601 "$D" 9601
OUT=$(PSD7 "$LIB" BH-9601 9601)
[ "$OUT" = "rc=1" ] && grep -q 'skipping BH-9601: HOLD (held' "$SAY" && grep -qx 'held-marked BH-9601' "$T/psd7.log" \
  && ! grep -q '^cap ' "$T/psd7.log" && [ -e "$T/q/BH-9601.json" ] \
  && ok || bad "E7 a merged key after a PLAN_BLOCKED reap is refused at the HOLD arm (got $OUT; log $(cat "$T/psd7.log" 2>/dev/null); say $(tr '\n' ';' < "$SAY"))"
rm -f "$NHMARK/9601"; rm -f "$T/psd7.log"
OUT=$(PSD7 "$LIB" BH-9601 9601)
[ "$OUT" = "rc=0" ] && grep -qx 'cap BH-9601' "$T/psd7.log" \
  && ok || bad "E7 with the hold lifted the decision passes the HOLD arm (got $OUT; log $(cat "$T/psd7.log" 2>/dev/null))"
# E7 mutation: pool-lifecycle.sh with the _plc_hold call replaced by `false`.
sed 's/_plc_hold "\$p" "\$t"[^;]*;/false;/' "$LIB" > "$T/lib-nohold.sh"
cmp -s "$LIB" "$T/lib-nohold.sh" && bad "E7 setup: no _plc_hold call to cut in bin/lib/pool-lifecycle.sh" || ok
fresh; rm -f "$T/psd7.log"; lf_row bh BH-9602 merged
D=$(rec BH-9602 "PLAN_BLOCKED" "BLOCKED: e7 mutation")
( export HARNESS="$H" PATH="$T/fakebin:$PATH" ALERTLOG NHLOG NHMARK
  say() { printf '%s\n' "$*" >> "$SAY"; }
  libs
  # shellcheck disable=SC1090
  . "$T/lib-nohold.sh" || exit 9
  pool_phase_reap bh BH-9602 "$D" 9602 )
OUT=$(PSD7 "$T/lib-nohold.sh" BH-9602 9602)
[ "$OUT" = "rc=0" ] && [ "$(nhn)" = 0 ] && ok || bad "E7 mutation: without the hold call the merged key spawns again (got $OUT; holds $(nhn))"

# E4 push_preplan relays a pre-plan -> planned.
awk '/^push_preplan\(\) \{/{f=1} f; f && /^}/{exit}' "$POOL" > "$T/pp.sh"
nocall "$T/pp.sh" > "$T/pp-nocall.sh"
[ -s "$T/pp.sh" ] && ok || bad "E4 setup: could not cut push_preplan"
PP() {
  mkdir -p "$H/plans/bh-$2"; echo "plan" > "$H/plans/bh-$2/plan.md"
  ( export HARNESS="$H" PATH="$T/fakebin:$PATH"; P=bh
    say() { printf '%s\n' "$*" >> "$SAY"; }
    libs
    preplan_speculative() { echo 1; }; mput() { return "${MPUT_RC:-0}"; }
    # shellcheck disable=SC1090
    . "$1"; push_preplan m-e4 "$2" )
}
fresh; lf_row bh BH-9506
PP "$T/pp.sh" BH-9506
[ "$(lf_events | awk '{print $3, $4, $5}')" = "null planned pool" ] && grep -q 'relayed pre-plan for BH-9506' "$SAY" \
  && ok || bad "E4 a relayed pre-plan writes planned ($(lf_events); $(cat "$SAY"))"
fresh; lf_row bh BH-9506; PP "$T/pp-nocall.sh" BH-9506
[ "$(posts)" = 0 ] && ok || bad "E4 mutation: push_preplan without the call writes nothing"
fresh; lf_row bh BH-9506; ( export MPUT_RC=1; PP "$T/pp.sh" BH-9506 )
[ "$(posts)" = 0 ] && ok || bad "E4 a failed relay writes no planned"

# E5/E6 the spawned and reused blocks write building.
WB() { # WB <block file> — run it with P KEY NKEY MID set
  ( export HARNESS="$H" PATH="$T/fakebin:$PATH"
    say() { printf '%s\n' "$*" >> "$SAY"; }
    libs
    # shellcheck disable=SC2034
    P=bh; KEY="${WKEY:-}"; NKEY="${WNKEY:-}"; MID="m-w"
    # shellcheck disable=SC1090
    . "$1" )
}
blk '# >>> lifecycle phase: spawned (BH-8733)' '# <<< lifecycle phase: spawned' > "$T/e5.sh"
blk '# >>> lifecycle phase: reused (BH-8733)' '# <<< lifecycle phase: reused' > "$T/e6.sh"
for f in e5 e6; do
  grep -q 'pool_phase_set' "$T/$f.sh" && ok || bad "$f setup: the marked block is not in bin/fly-pool.sh or has no call"
  nocall "$T/$f.sh" > "$T/$f-nocall.sh"
done
fresh; lf_row bh BH-9507 planned; WKEY=BH-9507 WB "$T/e5.sh"
[ "$(lf_events | awk '{print $3, $4, $5}')" = "planned building pool" ] && grep -q 'machine m-w spawned' "$LF_DIR/events.log" \
  && ok || bad "E5 a spawn writes building ($(lf_events))"
fresh; lf_row bh BH-9507 planned; WKEY=BH-9507 WB "$T/e5-nocall.sh"
[ "$(posts)" = 0 ] && ok || bad "E5 mutation: without the call, nothing is written"
fresh; lf_row bh BH-9508; WKEY=BH-9999 WNKEY=BH-9508 WB "$T/e6.sh"
[ "$(lf_events | awk '{print $2, $3, $4}')" = "BH-9508 null building" ] && grep -q 'machine m-w reused' "$LF_DIR/events.log" \
  && ok || bad "E6 a reuse writes building for NKEY ($(lf_events))"
fresh; lf_row bh BH-9508; WKEY=BH-9999 WNKEY=BH-9508 WB "$T/e6-nocall.sh"
[ "$(posts)" = 0 ] && ok || bad "E6 mutation: without the call, nothing is written"
ln_in() { grep -nF -- "$2" "$SRC/config/fly-pool.d/$1" | head -1 | cut -d: -f1; }
S1=$(ln_in 3800-spawn-one.sh 'say "spawned $MID'); S2=$(ln_in 3800-spawn-one.sh '# >>> lifecycle phase: spawned')
U1=$(ln_in 3300-next-job-or-destroy.sh 'say "reused $MID'); U2=$(ln_in 3300-next-job-or-destroy.sh '# >>> lifecycle phase: reused')
[ -n "$S1" ] && [ -n "$S2" ] && [ "$S1" -lt "$S2" ] && [ "$((S2 - S1))" -le 3 ] && [ -n "$U1" ] && [ -n "$U2" ] && [ "$U1" -lt "$U2" ] && [ "$((U2 - U1))" -le 3 ] \
  && ok || bad "E5/E6 the blocks sit just after the spawned ($S1 $S2) and reused ($U1 $U2) lines"

# ═════ B: no vendor ═════════════════════════════════════════════════════════
[ ! -s "$T/vendor.log" ] && ok || bad "B a vendor client was called: $(cat "$T/vendor.log")"

echo "pool-lifecycle.bh-8733: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
