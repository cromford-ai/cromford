#!/bin/bash
# tests/plan-stale-replan.bh-9672-test.sh — BH-9672: end the PLAN_STALE loop on
# a resumed ticket.
#
# THE DEFECT. A build on a branch that already carries commits adopted the DB
# pre-plan. The plan thread gate refused it for an uncited newer comment and
# the run ended PLAN_STALE (exit 3). The DB row stayed, so the next build
# adopted the same row and ended the same way: BH-8841 four times, BH-9513 two
# times, and no plan stage ran in any of them.
#
# What this suite pins:
#   P1  a DB pre-plan older than an uncited comment is not adopted
#       (PREPLAN_STALE); the plan stage runs with the branch note; the new plan
#       that cites the comment passes the gate.
#   P2  a refused pre-plan's DB row is retired (adopt time and gate time).
#   P3  a pre-plan newer than every comment is adopted as today.
#   P4  a second refusal for the same ids alerts once and plans fresh.
#   P5  EXECUTE runs on a branch with commits when the plan was written again;
#       P5b call site B still stops a plan that does not cite the comment.
#   A*  the adopt check's classifier cases, L* the repeat matcher, B* the
#   branch note gate, E* the execute note parser, R* the retire, S* the RESULT
#   text, K* the knobs.
# The pipeline blocks are EXTRACTED VERBATIM from the flattened pipeline
# (tests/lib/rb-all.sh). gh_rest and the jobs client are stubs: no network.
# Each case runs in its own build dir.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/plan-stale-replan.bh-9672-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
. "$SRC/tests/lib/rb-all.sh" || exit 1
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
RB_ALL=$(rb_all "$SRC" "$T/run-build.all.sh")
xb() { # xb <marker> <out> — one marked block, verbatim
  awk -v n="$1" 'index($0, "# >>> " n)==1 {f=1;next} index($0, "# <<< " n)==1 {exit} f' "$RB_ALL" > "$2"
}

H="$T/h"; mkdir -p "$H/bin/lib" "$H/plans" "$H/builds" "$H/env" "$H/flags" "$H/logs" "$H/state" "$H/store"
scratch_install_closure bin/lib/preplan-lib.sh "$H" >/dev/null || bad "cannot install the closure of bin/lib/preplan-lib.sh"
scratch_install_closure bin/lib/plan-thread.sh "$H" >/dev/null || bad "cannot install the closure of bin/lib/plan-thread.sh"
if [ -r "$SRC/bin/lib/plan-stale-replan.sh" ]; then
  scratch_install_closure bin/lib/plan-stale-replan.sh "$H" >/dev/null || bad "cannot install the closure of bin/lib/plan-stale-replan.sh"
fi
: > "$H/env/global.env"
cat > "$H/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$2" in
  board_prefix) echo - ;;
  repo) echo example-org/cromford ;;
  *) echo - ;;
esac
EOF
chmod +x "$H/bin/fleet-conf.sh"
LIB="$H/bin/lib/plan-stale-replan.sh"
ALERTS_F="$H/logs/ALERTS.log"

# gh_rest stub: $H/page<N>.json for page N; an absent page is [].
GH_STUB='gh_rest() {
  local p; p=$(sed -nE "s/.*[?&]page=([0-9]+).*/\1/p" <<<"$2")
  printf "%s %s\n" "$1" "$2" >> "$HARNESS/gh.log"
  if [ -s "$HARNESS/page$p.json" ]; then cat "$HARNESS/page$p.json"; else echo "[]"; fi
}'
eval "$GH_STUB"

# The jobs client stub: an in-file store. $H/store/preplan.json is the one
# preplans row, $H/store/jobs.json the GET /api/jobs answer, $H/store/calls the
# log of every call. $H/store/retire.rc forces the retire answer's rc (1 =
# unreachable). preplan_get answers the way bin/lib/jobs/queue.sh does.
cat > "$H/bin/jobs-client.sh" <<'EOF'
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" s="$HARNESS/store"
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$s/calls"
  case "$m $p" in
    "GET /api/preplans?"*)
      [ -s "$s/preplan.json" ] || { JOBS_HTTP=404; return 2; }
      JOBS_HTTP=200; jq -c '{preplan: .}' "$s/preplan.json" ;;
    "POST /api/preplans/retire")
      if [ -s "$s/retire.rc" ]; then JOBS_HTTP=""; return "$(cat "$s/retire.rc")"; fi
      JOBS_HTTP=200
      if [ -s "$s/preplan.json" ] && jq -e --argjson b "$b" '.thread_at == null or .thread_at <= $b.thread_at_max' "$s/preplan.json" >/dev/null; then
        rm -f "$s/preplan.json"; echo '{"retired":1}'
      else echo '{"retired":0}'; fi ;;
    "GET /api/jobs?"*)
      [ -s "$s/jobs.json" ] || { JOBS_HTTP=""; return 1; }
      JOBS_HTTP=200; cat "$s/jobs.json" ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
}
preplan_get() {
  local resp rc
  resp=$(_jobs_req GET "/api/preplans?project=$1&key=$2"); rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 2 ] && return 2; return 1; }
  printf '%s' "$resp" | jq -c '.preplan // empty'
}
EOF

# cm <id> <login> <type> <created> [updated] [body] — one REST comment
cm() {
  jq -nc --argjson id "$1" --arg l "$2" --arg t "$3" --arg c "$4" --arg u "${5:-$4}" --arg b "${6:-a comment}" \
    '{id:$id, node_id:("IC_kwDOfixture" + ($id|tostring)), user:{login:$l,type:$t}, created_at:$c, updated_at:$u, body:$b}'
}
arr() { jq -sc '.' ; }
CID=6780108925
ROW_AT='2026-11-10T21:00:00Z'
C_P1=$(cm "$CID" operator User 2026-11-10T21:46:34Z | arr)

# The repo: main, and a checkpoint branch with one commit over it.
GW="$T/repo"; mkdir -p "$GW/src"
gitw() { git -C "$GW" -c user.email=t@t -c user.name=t "$@"; }
gitw init -q -b main . && echo a > "$GW/src/a.sh" && gitw add -A && gitw commit -qm base \
  && gitw checkout -q -b ticket/bh-9672 && echo b > "$GW/src/b.sh" && gitw add -A && gitw commit -qm 'feat: first execute' \
  || bad "fixture repo"
BASE0=$(gitw rev-parse main)
WORK1=$(gitw rev-parse HEAD)
PLAN_OLD='# Plan
## Spec changes from comments
none
## Tasks
SIZE: S
'
seed_row() { # seed_row <thread_at|null> — the DB preplans row for BH-9672
  jq -n --arg sha "$BASE0" --arg plan "$PLAN_OLD" --arg ta "$1" \
    '{project:"cromford", ticket_key:"BH-9672", base_sha:$sha, plan_md:$plan,
      planned_files:"src/a.sh\n", thread_at:(if $ta == "null" then null else $ta end)}' > "$H/store/preplan.json"
}

ADOPT="$T/blk-adopt.sh"; GATE_A="$T/blk-gate-a.sh"; REPLAN="$T/blk-replan.sh"; GATE_B="$T/blk-gate-b.sh"
xb 'preplan adopt' "$ADOPT"; xb 'plan thread gate (BH-5799)' "$GATE_A"
xb 'replan on branch (BH-9672)' "$REPLAN"; xb 'plan thread pre-review (BH-5799)' "$GATE_B"
[ -s "$ADOPT" ] && [ -s "$GATE_A" ] && [ -s "$GATE_B" ] && ok || bad "could not extract the adopt and gate blocks"

N=0
# flow <name> [VAR=VAL ...] — a new build dir $BLD under $H/builds, then the
# pipeline order: adopt, plan thread gate, (no plan: replan block, a stub
# planner that cites $CID, call site B). rc in $RF. The stub planner writes
# FLOW_PLAN when set.
flow() {
  N=$((N+1)); BLD="$H/builds/${FLOW_DIR:-f}-$N"; mkdir -p "$BLD"
  [ -n "${SEED_PLAN:-}" ] && { printf '%s' "$SEED_PLAN" > "$BLD/plan.md"; printf '%s\n' "${SEED_AT:-$ROW_AT}" > "$BLD/plan-thread-at"; }
  ( cd "$GW" || exit 9
    HARNESS="$H"; PROJECT=cromford; KEY=BH-9672; BUILD="$BLD"; WT="$GW"; BASE=main; FP_BEFORE=""
    ALERTS="$ALERTS_F"; REPLAN_LINE=""; export PREPLAN_RELAY_DIR="$T/relay-none"
    shift; [ $# -gt 0 ] && export "$@"
    eval "$GH_STUB"
    STAMP() { printf '2026-11-15 08:00:00Z'; }
    PLAN_IS_BLOCKED() { head -1 "$1" | grep -q '^BLOCKED'; }
    BB() { printf 'BB %s %s\n' "$1" "${6:-}" >> "$BUILD/bb.log"; }
    RESULT() { printf '%s\n' "$1" > "$BUILD/RESULT"; }
    # shellcheck source=/dev/null
    . "$ADOPT"
    # shellcheck source=/dev/null
    . "$GATE_A"
    if [ ! -s "$BUILD/plan.md" ]; then
      echo fresh > "$BUILD/fresh-plan"
      # shellcheck source=/dev/null
      [ -s "$REPLAN" ] && . "$REPLAN"
      printf '%s' "$REPLAN_LINE" > "$BUILD/replan-line"
      printf '%s\n' "$ROW_AT" > "$BUILD/plan-thread-at"
      printf '%s' "${FLOW_PLAN:-# Plan
## Spec changes from comments
- $CID operator: applied, task 1
## Existing branch commits
- ${WORK1:0:12} keep: still true
SIZE: S
}" > "$BUILD/plan.md"
    fi
    # shellcheck source=/dev/null
    . "$GATE_B"
    echo through > "$BUILD/through" ) >/dev/null 2>&1; RF=$?
}
calls() { cat "$H/store/calls" 2>/dev/null; }
reset_store() { rm -f "$H/store/"*; : > "$H/store/calls"; }

echo "--- P1 a resumed branch, a DB pre-plan older than an uncited comment"
reset_store; seed_row "$ROW_AT"; echo "$C_P1" > "$H/page1.json"
flow P1 CKPT_START_POINT=origin/ticket/bh-9672
case "$(head -1 "$BLD/preplan-outcome" 2>/dev/null)" in
  "STALE uncited comment(s) newer than the pre-plan: $CID") ok ;;
  *) bad "P1 preplan-outcome must be the adopt-time STALE naming $CID (got: $(cat "$BLD/preplan-outcome" 2>/dev/null))" ;;
esac
[ "$(grep -c 'PREPLAN_' "$BLD/pipeline.log" 2>/dev/null)" = 1 ] && grep -q 'PREPLAN_STALE' "$BLD/pipeline.log" && ok \
  || bad "P1 exactly one PREPLAN_ line and it is PREPLAN_STALE (log: $(cat "$BLD/pipeline.log" 2>/dev/null))"
grep -q 'PLAN_THREAD_REFUSED' "$BLD/pipeline.log" 2>/dev/null && bad "P1 the gate must not run (no adopted plan)" || ok
[ -e "$BLD/fresh-plan" ] && ok || bad "P1 the plan stage must run in this build"
{ grep -q "${WORK1:0:12}" "$BLD/replan-line" 2>/dev/null && grep -q "$CID" "$BLD/replan-line"; } && ok \
  || bad "P1 REPLAN_LINE must carry the branch commit and $CID (got: $(cat "$BLD/replan-line" 2>/dev/null))"
[ "$(head -1 "$BLD/replan-on-branch" 2>/dev/null)" = "ids $CID" ] && grep -q "^$WORK1"$'\t' "$BLD/replan-on-branch" && ok \
  || bad "P1 the marker must be written (got: $(cat "$BLD/replan-on-branch" 2>/dev/null))"
{ [ "$RF" = 0 ] && [ ! -e "$BLD/RESULT" ] && [ -e "$BLD/through" ] && grep -q 'plan-thread: ok.*(pre-review)' "$BLD/pipeline.log"; } && ok \
  || bad "P1 the new plan cites $CID and passes; no RESULT (rc=$RF RESULT=$(cat "$BLD/RESULT" 2>/dev/null))"

echo "--- P2 the refused row is retired"
[ ! -e "$H/store/preplan.json" ] && ok || bad "P2 the DB row must be gone after the adopt-time refusal"
grep -q "^POST /api/preplans/retire .*\"thread_at_max\":\"$ROW_AT\"" "$H/store/calls" && ok \
  || bad "P2 the retire call must carry thread_at_max=$ROW_AT (calls: $(calls))"
grep -q 'preplan-retire: db row retired' "$BLD/pipeline.log" && ok || bad "P2 one preplan-retire line"
flow P2b CKPT_START_POINT=origin/ticket/bh-9672
case "$(head -1 "$BLD/preplan-outcome")" in *"coordination DB has no row"*) ok ;; *) bad "P2 a second build gets no row (got: $(cat "$BLD/preplan-outcome"))" ;; esac
grep -q 'PREPLAN_MISS' "$BLD/pipeline.log" && ok || bad "P2 the second build logs PREPLAN_MISS"
# The gate-time refusal (call site A) retires too: the adopt check is off, so
# the row is adopted (HIT) and the gate refuses it.
reset_store; seed_row "$ROW_AT"
flow P2c CKPT_START_POINT=origin/ticket/bh-9672 PSR_ADOPT_THREAD_CHECK=0
grep -q 'PREPLAN_HIT' "$BLD/pipeline.log" && ok || bad "P2c with the adopt check off the row is adopted"
grep -q 'PLAN_THREAD_REFUSED (reused plan' "$BLD/pipeline.log" && ok || bad "P2c the gate refuses the adopted plan"
{ [ ! -e "$H/store/preplan.json" ] && grep -q "^POST /api/preplans/retire .*\"thread_at_max\":\"$ROW_AT\"" "$H/store/calls"; } && ok \
  || bad "P2c the gate refusal must retire the DB row (calls: $(calls))"
case "$(cat "$BLD/RESULT" 2>/dev/null)" in *"refused plan retired (db row retired)"*) ok ;; *) bad "P2c/S1 the RESULT names the retire outcome (got: $(cat "$BLD/RESULT" 2>/dev/null))" ;; esac

echo "--- P3 a pre-plan newer than every comment is adopted"
reset_store; seed_row '2026-11-10T22:00:00Z'
flow P3 CKPT_START_POINT=origin/ticket/bh-9672
case "$(head -1 "$BLD/preplan-outcome")" in HIT*) ok ;; *) bad "P3 must be HIT (got: $(cat "$BLD/preplan-outcome"))" ;; esac
[ "$(cat "$BLD/plan.md")" = "$(jq -r .plan_md "$H/store/preplan.json" 2>/dev/null)" ] && ok || bad "P3 plan.md equals the row's plan"
grep -q 'preplans/retire' "$H/store/calls" && bad "P3 no retire call" || ok

echo "--- P4 the same ids twice: one alert, plan fresh"
reset_store; : > "$ALERTS_F"; echo "$(cm 9002 operator User 2026-11-10T21:30:00Z | arr)" > "$H/page1.json"
SEED_PLAN="$PLAN_OLD" FLOW_DIR=p4 flow P4-1 RESUME_BUILD=/x/build JOB_ID=job-1
R1=$(cat "$BLD/RESULT" 2>/dev/null)
[ "$RF" = 3 ] && ok || bad "P4 run 1 must end exit 3 (rc=$RF)"
case "$R1" in "PLAN_STALE uncited comment(s) newer than the plan: 9002 — refused plan retired"*) ok ;; *) bad "P4 run 1 RESULT (got: $R1)" ;; esac
case "$R1" in *"— re-plan"*) bad "S1 the RESULT must not say re-plan (got: $R1)" ;; *) ok ;; esac
jq -n --arg r "$R1" '{jobs:[{id:"job-1",ticket_id:"BH-9672",project:"cromford",kind:"build",status:"parked",meta:$r}]}' > "$H/store/jobs.json"
P4_PLAN='# Plan
## Spec changes from comments
- 9002 operator: applied
SIZE: S
'
FLOW_PLAN="$P4_PLAN" SEED_PLAN="$PLAN_OLD" FLOW_DIR=p4 flow P4-2 RESUME_BUILD=/x/build JOB_ID=job-2
{ [ "$RF" = 0 ] && [ ! -e "$BLD/RESULT" ] && [ -e "$BLD/fresh-plan" ]; } && ok || bad "P4 run 2 must plan fresh (rc=$RF RESULT=$(cat "$BLD/RESULT" 2>/dev/null))"
[ "$(grep -c 'PLAN_STALE_REPEAT \[cromford/BH-9672\] ids=9002:' "$ALERTS_F")" = 1 ] && ok || bad "P4 exactly one ALERTS line (got: $(cat "$ALERTS_F"))"
grep -q 'resumed branch, repeat' "$BLD/pipeline.log" && ok || bad "P4 run 2 logs the repeat arm"
[ -s "$BLD/replan-on-branch" ] && ok || bad "P4 run 2 writes the branch marker"
FLOW_PLAN="$P4_PLAN" SEED_PLAN="$PLAN_OLD" FLOW_DIR=p4 flow P4-3 RESUME_BUILD=/x/build JOB_ID=job-3
[ "$(grep -c 'PLAN_STALE_REPEAT' "$ALERTS_F")" = 1 ] && ok || bad "P4 run 3 leaves ALERTS at 1 line"
SEED_PLAN="$PLAN_OLD" FLOW_DIR=p4 flow P4-k RESUME_BUILD=/x/build JOB_ID=job-4 PSR_REPEAT_FRESH=0
{ [ "$RF" = 3 ] && grep -q '^PLAN_STALE' "$BLD/RESULT"; } && ok || bad "K1 PSR_REPEAT_FRESH=0 ends PLAN_STALE (rc=$RF)"

echo "--- P5 EXECUTE runs under the new plan"
SKIP_LINE=$(grep -m1 '^if \[ -z "\${CKPT_START_POINT:-}" \] && ! git diff --quiet' "$RB_ALL")
[ -n "$SKIP_LINE" ] && ok || bad "P5 could not find the execute checkpoint skip line"
skip_pred() { # skip_pred <build> -> SKIP or RUN, from the shipped line
  ( cd "$GW" && BUILD="$1" BASE=main; unset CKPT_START_POINT
    CKPT_NONWIP_COUNT() { echo 1; }
    eval "$SKIP_LINE echo SKIP; else echo RUN; fi" ) 2>/dev/null
}
B5="$T/b5"; mkdir -p "$B5"
[ "$(skip_pred "$B5")" = SKIP ] && ok || bad "P5 without the marker the branch with commits skips EXECUTE (today)"
: > "$B5/replan-on-branch"
[ "$(skip_pred "$B5")" = RUN ] && ok || bad "P5 with the marker EXECUTE runs"
mv "$B5/replan-on-branch" "$B5/replan-on-branch.done"
[ "$(skip_pred "$B5")" = SKIP ] && ok || bad "P5 a .done marker skips again (no second execute)"
grep -q 'mv -f "\$BUILD/replan-on-branch" "\$BUILD/replan-on-branch.done"' "$SRC/bin/lib/rb/execute.sh" && ok \
  || bad "P5 execute.sh renames the marker after a good execute"
grep -q 'psr_exec_note "\$BUILD/plan.md" "\$BUILD/replan-on-branch"' "$SRC/bin/lib/rb/execute.sh" && ok \
  || bad "P5 execute.sh adds the execute note"

echo "--- P5b / S2 call site B: a plan that does not cite the comment stops"
run_b() { # run_b <name> [VAR=VAL ...]
  N=$((N+1)); BLD="$H/builds/b-$N"; mkdir -p "$BLD"
  printf '%s' "$PLAN_OLD" > "$BLD/plan.md"; printf '%s\n' "$ROW_AT" > "$BLD/plan-thread-at"
  [ -n "${B_OUTCOME:-}" ] && printf '%s\n' "$B_OUTCOME" > "$BLD/preplan-outcome"
  ( HARNESS="$H"; PROJECT=cromford; KEY=BH-9672; BUILD="$BLD"; ALERTS="$ALERTS_F"
    shift; [ $# -gt 0 ] && export "$@"
    eval "$GH_STUB"
    STAMP() { printf '2026-11-15 08:00:00Z'; }
    BB() { printf 'BB %s %s\n' "$1" "${6:-}" >> "$BUILD/bb.log"; }
    RESULT() { printf '%s\n' "$1" > "$BUILD/RESULT"; }
    [ -r "$LIB" ] && . "$LIB"
    [ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
    # shellcheck source=/dev/null
    . "$GATE_B"; : > "$BUILD/through" ) >/dev/null 2>&1; RB=$?
}
reset_store; : > "$ALERTS_F"; seed_row "$ROW_AT"
B_OUTCOME="HIT adopted" run_b P5b JOB_ID=job-b1
{ [ "$RB" = 3 ] && [ ! -e "$BLD/plan.md" ] && [ -s "$BLD/plan.md.thread-refused" ] && [ ! -e "$BLD/through" ]; } && ok \
  || bad "P5b a non-citing plan ends exit 3 with plan.md moved aside (rc=$RB)"
RB1=$(cat "$BLD/RESULT" 2>/dev/null)
case "$RB1" in "PLAN_STALE uncited comment(s) newer than the plan: 9002 — refused plan retired (db row retired)"*) ok ;; *) bad "S2 call site B RESULT (got: $RB1)" ;; esac
case "$RB1" in *"— re-plan"*) bad "S2 must not say re-plan" ;; *) ok ;; esac
[ ! -e "$H/store/preplan.json" ] && ok || bad "P5b call site B retires an adopted pre-plan's row"
jq -n --arg r "$RB1" '{jobs:[{id:"job-b1",ticket_id:"BH-9672",project:"cromford",kind:"build",status:"parked",meta:$r}]}' > "$H/store/jobs.json"
B_OUTCOME="" run_b P5b2 JOB_ID=job-b2
{ [ "$RB" = 3 ] && [ "$(grep -c 'PLAN_STALE_REPEAT \[cromford/BH-9672\] ids=9002: at review' "$ALERTS_F")" = 1 ]; } && ok \
  || bad "P5b a repeat at review alerts once and still ends PLAN_STALE (rc=$RB alerts: $(cat "$ALERTS_F"))"

if [ ! -r "$LIB" ]; then
  echo "plan-stale-replan: $PASS passed, $FAIL failed (bin/lib/plan-stale-replan.sh is missing: unit cases not run)"
  [ "$FAIL" -eq 0 ] && bad "the lib is missing"
  exit 1
fi

echo "--- A adopt-time classifier"
adopt_case() { # adopt_case <comments-json> [stamp|-] [own-file] -> rc in $AR, PP_OUTCOME in $AO
  N=$((N+1)); local d="$T/pp-$N"; BLD="$H/builds/ac-$N"; mkdir -p "$d" "$BLD"
  printf '%s' "$PLAN_OLD${APLAN_EXTRA:-}" > "$d/plan.md"
  [ "${2:-$ROW_AT}" != - ] && printf '%s\n' "${2:-$ROW_AT}" > "$d/plan-thread-at"
  [ -n "${3:-}" ] && cp "$3" "$BLD/own-comments.sha256"
  printf '%s' "$1" > "$H/page1.json"
  AO=$( HARNESS="$H"; PROJECT=cromford; KEY=BH-9672; BUILD="$BLD"; PP_OUTCOME=""; export HARNESS_SELF_APPS=cromford-board
        eval "$GH_STUB"; . "$LIB"; . "$H/bin/jobs-client.sh"
        psr_adopt_check "$d" "$BLD"; r=$?; printf '%s\t%s' "$r" "$PP_OUTCOME" ) 2>/dev/null
  AR=${AO%%$'\t'*}; AO=${AO#*$'\t'}
}
reset_store
adopt_case "$(cm 9101 operator User 2026-11-10T21:10:00Z | arr)"
{ [ "$AR" = 1 ] && [ "$AO" = "STALE uncited comment(s) newer than the pre-plan: 9101" ]; } && ok || bad "A1 a newer person comment refuses (rc=$AR $AO)"
[ "$(cat "$BLD/plan-stale-ids" 2>/dev/null)" = 9101 ] && ok || bad "A1 plan-stale-ids holds the id"
adopt_case "$(cm 9102 'cromford-board[bot]' Bot 2026-11-10T21:10:00Z | arr)"
[ "$AR" = 1 ] && ok || bad "A2 our App's newer uncited comment refuses (rc=$AR)"
adopt_case "$(cm 9103 operator User 2026-11-09T10:00:00Z 2026-11-10T21:10:00Z | arr)"
[ "$AR" = 1 ] && ok || bad "A3 an old comment edited after the stamp refuses (rc=$AR)"
adopt_case "$(cm 9104 operator User 2026-11-01T10:00:00Z | arr)" -
[ "$AR" = 1 ] && ok || bad "A4 a stamp-less pre-plan counts every comment (rc=$AR)"
{ for i in $(seq 1 100); do cm "$((7000+i))" operator User 2026-11-09T09:00:00Z; done; } | arr > "$T/p1.json"
cm 9105 operator User 2026-11-10T21:10:00Z | arr > "$H/page2.json"
adopt_case "$(cat "$T/p1.json")"; rm -f "$H/page2.json"
{ [ "$AR" = 1 ] && grep -q 9105 <<<"$AO"; } && ok || bad "A5 an uncited comment on page 2 refuses (rc=$AR $AO)"
APLAN_EXTRA="see #issuecomment-9106
" adopt_case "$(cm 9106 operator User 2026-11-10T21:10:00Z | arr)"
[ "$AR" = 0 ] && ok || bad "A6 a cited comment adopts (rc=$AR)"
printf 'BUILD BLOCKED notice\n' > "$T/own.md"; ( . "$LIB"; ptg_own_post "$T" "$T/own.md" ) 2>/dev/null
adopt_case "$(cm 9107 'cromford-board[bot]' Bot 2026-11-10T21:10:00Z '' 'BUILD BLOCKED notice' | arr)" "$ROW_AT" "$T/own-comments.sha256"
[ "$AR" = 0 ] && ok || bad "A7 our own post adopts (rc=$AR)"
adopt_case "$( { cm 9108 operator User 2026-11-09T10:00:00Z; cm 9109 'coderabbitai[bot]' Bot 2026-11-10T21:10:00Z; } | arr)"
[ "$AR" = 0 ] && ok || bad "A8 an older comment and a third-party bot adopt (rc=$AR)"
APLAN_EXTRA="see 191107 and 91107
" adopt_case "$(cm 9110 operator User 2026-11-10T21:10:00Z | arr)"
[ "$AR" = 1 ] && ok || bad "A1b the id only inside a longer number is not cited (rc=$AR)"
grep -q 'preplans/retire' "$H/store/calls" && ok || bad "A the refusals call the retire route"
# An unreadable thread fails open with one line.
N=$((N+1)); d="$T/pp-$N"; BLD="$H/builds/ac-$N"; mkdir -p "$d" "$BLD"; printf '%s' "$PLAN_OLD" > "$d/plan.md"
AR=$( HARNESS="$H"; PROJECT=cromford; KEY=BH-9672; BUILD="$BLD"; STAMP() { echo s; }
      gh_rest() { return 75; }; . "$LIB"; psr_adopt_check "$d" "$BLD"; echo $? ) 2>/dev/null
{ [ "$AR" = 0 ] && grep -q 'plan-thread: adopt check fails open' "$BLD/pipeline.log"; } && ok || bad "A9 an unreadable thread adopts with one line (rc=$AR)"
AR=$( HARNESS="$H"; PROJECT=cromford; KEY=BH-9672; BUILD="$BLD"; export PSR_ADOPT_THREAD_CHECK=0
      eval "$GH_STUB"; . "$LIB"; printf '%s' "$(cm 9111 operator User 2026-11-10T21:10:00Z | arr)" > "$H/page1.json"
      psr_adopt_check "$d" "$BLD"; echo $? ) 2>/dev/null
[ "$AR" = 0 ] && ok || bad "K1 PSR_ADOPT_THREAD_CHECK=0 adopts (rc=$AR)"

echo "--- L repeat matcher"
prior() { # prior <ids> [job] -> rc in $LR
  [ -n "${NO_CLIENT:-}" ] && mv "$H/bin/jobs-client.sh" "$H/bin/jobs-client.off"
  LO=$( HARNESS="$H"; PROJECT=cromford; KEY=BH-9672; . "$LIB"
        psr_prior_stale cromford BH-9672 "$1" "${2:-job-self}" "${PBUILD:-$T/none}" ); LR=$?
  [ -n "${NO_CLIENT:-}" ] && mv "$H/bin/jobs-client.off" "$H/bin/jobs-client.sh"
  return 0
}
ledger() { # ledger <meta-json-values...> — newest first
  printf '%s\n' "$@" | jq -s '{jobs: [ to_entries[] | {id: ("job-" + (.key|tostring)), ticket_id: "BH-9672", project: "cromford", kind: "build", status: "parked", meta: .value} ]}' > "$H/store/jobs.json"
}
OLD='"PLAN_STALE uncited comment(s) newer than the plan: 9002 9003 — re-plan"'
NEW='"PLAN_STALE uncited comment(s) newer than the plan: 9003 9002 — refused plan retired (db row retired); the next build of BH-9672 plans fresh with this branch'"'"'s commits in its prompt"'
reset_store
ledger "$OLD"; prior "9002 9003"; [ "$LR" = 0 ] && ok || bad "L1 the old suffix, same ids (rc=$LR)"
ledger "$NEW"; prior "9002 9003"; [ "$LR" = 0 ] && ok || bad "L2 the new suffix, other order (rc=$LR)"
ledger '{"result":"PLAN_STALE uncited comment(s) newer than the plan: 9002 9003 — re-plan","sha":"x"}'
prior "9003 9002"; [ "$LR" = 0 ] && ok || bad "L3 meta.result object form (rc=$LR)"
ledger "$(jq -n '{result:"PLAN_STALE uncited comment(s) newer than the plan: 9002 9003 — re-plan"} | tojson')"
prior "9003 9002"; [ "$LR" = 0 ] && ok || bad "L3 meta.result JSON-string form (rc=$LR)"
ledger "$OLD"; prior "9002"; [ "$LR" = 1 ] && ok || bad "L4 a superset does not match (rc=$LR)"
ledger "$OLD"; prior "9002 9003 9004"; [ "$LR" = 1 ] && ok || bad "L4 a subset does not match (rc=$LR)"
ledger '"PLAN_STALE thread moved since the reused plan was written — re-run"'; prior "9002"; [ "$LR" = 1 ] && ok || bad "L5 thread moved does not match (rc=$LR)"
ledger "$OLD"; prior "9002 9003" job-0; [ "$LR" = 1 ] && ok || bad "L6 this build's own row does not match (rc=$LR)"
jq -n '{jobs:[{id:"j9",ticket_id:"BH-96",project:"cromford",kind:"build",meta:"PLAN_STALE uncited comment(s) newer than the plan: 9002 — re-plan"}]}' > "$H/store/jobs.json"
prior "9002"; [ "$LR" = 1 ] && ok || bad "L6b another KEY's row does not match (rc=$LR)"
NO_CLIENT=1 prior "9002"; [ "$LR" = 2 ] && ok || bad "L7 no client and no dirs is unknown (rc=$LR $LO)"
rm -f "$H/store/jobs.json"; prior "9002"; [ "$LR" = 2 ] && ok || bad "L7 a ledger that does not answer and no dirs is unknown (rc=$LR)"
ledger '"x"' '"x"' '"x"' '"x"' '"x"' '"PLAN_STALE uncited comment(s) newer than the plan: 9002 — re-plan"'
prior "9002"; [ "$LR" = 1 ] && ok || bad "L8 a match at position 6 with PSR_LOOKBACK=5 is not seen (rc=$LR)"
LO=$( HARNESS="$H"; export PSR_LOOKBACK=6; . "$LIB"; . "$H/bin/jobs-client.sh"; psr_prior_stale cromford BH-9672 9002 job-self "$T/none" ); LR=$?
[ "$LR" = 0 ] && ok || bad "K1 PSR_LOOKBACK=6 sees position 6 (rc=$LR)"
# The local dirs: no client, an earlier dir of this ticket carries the RESULT.
mkdir -p "$H/builds/cromford-BH-9672-202611140101" "$H/builds/cromford-BH-96720-202611140101" "$H/builds/cromford-BH-9672-202611150101"
echo 'PLAN_STALE uncited comment(s) newer than the plan: 9002 — re-plan' > "$H/builds/cromford-BH-96720-202611140101/RESULT"
NO_CLIENT=1 prior "9002"; [ "$LR" = 1 ] && ok || bad "L9 another key's dir (BH-96720) does not match (rc=$LR $LO)"
echo 'PLAN_STALE uncited comment(s) newer than the plan: 9002 — re-plan' > "$H/builds/cromford-BH-9672-202611140101/RESULT"
NO_CLIENT=1 prior "9002"; [ "$LR" = 0 ] && ok || bad "L9 a local dir RESULT is seen (rc=$LR $LO)"
NO_CLIENT=1 PBUILD="$H/builds/cromford-BH-9672-202611140101" prior "9002"; [ "$LR" = 1 ] && ok || bad "L9 this build's own dir is skipped (rc=$LR)"
for d in "$H/builds/cromford-BH-9672-"* "$H/builds/cromford-BH-96720-"*; do scratch_rm "$d"; done

echo "--- B branch note gate"
replan() { # replan <cwd> [VAR=VAL ...] -> $BLD/replan-line, rc
  N=$((N+1)); BLD="$H/builds/rb-$N"; mkdir -p "$BLD"; [ -n "${B_IDS:-}" ] && echo "$B_IDS" > "$BLD/plan-stale-ids"
  local c="$1"; shift
  ( cd "$c" || exit 9; HARNESS="$H"; PROJECT=cromford; KEY=BH-9672; BUILD="$BLD"; BASE=main; REPLAN_LINE=" pre."
    [ $# -gt 0 ] && export "$@"
    STAMP() { echo s; }; . "$LIB"
    # shellcheck source=/dev/null
    . "$REPLAN"; printf '%s' "$REPLAN_LINE" > "$BUILD/replan-line" ) >/dev/null 2>&1
}
gitw commit -q --allow-empty -m 'fix: second'; WORK2=$(gitw rev-parse HEAD)
B_IDS=9002 replan "$GW" CKPT_START_POINT=x
{ grep -q "${WORK1:0:12}" "$BLD/replan-line" && grep -q "${WORK2:0:12}" "$BLD/replan-line" && grep -q 9002 "$BLD/replan-line" \
  && grep -q '^ pre\.' "$BLD/replan-line" && grep -q '## Existing branch commits' "$BLD/replan-line"; } && ok \
  || bad "B1 two commits and the ids in the note, after the earlier REPLAN_LINE (got: $(cat "$BLD/replan-line"))"
[ "$(tail -n +2 "$BLD/replan-on-branch" | wc -l | tr -d ' ')" = 2 ] && grep -q 'replan-on-branch: 2 commit(s), ids 9002' "$BLD/pipeline.log" && ok \
  || bad "B1 the marker has 2 commit lines and one log line (log: $(cat "$BLD/pipeline.log" 2>/dev/null))"
gitw checkout -q main
replan "$GW" CKPT_START_POINT=x
{ [ "$(cat "$BLD/replan-line")" = " pre." ] && [ ! -e "$BLD/replan-on-branch" ]; } && ok || bad "B2 an empty branch: no note, no marker"
gitw checkout -q -b ticket/bh-9672-many main
for i in $(seq 1 40); do echo "$i" > "$GW/src/c.sh"; gitw add -A; gitw commit -q -m "c$i"; done
replan "$GW" RESUME_BUILD=/x
{ [ "$(tail -n +2 "$BLD/replan-on-branch" | wc -l | tr -d ' ')" = 30 ] && grep -q '(+10 more)' "$BLD/replan-line"; } && ok \
  || bad "B3 40 commits cap at 30 plus (+10 more)"
replan "$GW" RESUME_BUILD=/x PSR_COMMITS_MAX=5
[ "$(tail -n +2 "$BLD/replan-on-branch" | wc -l | tr -d ' ')" = 5 ] && ok || bad "K1 PSR_COMMITS_MAX=5 caps at 5"
gitw checkout -q ticket/bh-9672
replan "$GW" TARGET_BRANCH=ticket/bh-9672
{ [ "$(cat "$BLD/replan-line")" = " pre." ] && [ ! -e "$BLD/replan-on-branch" ]; } && ok || bad "B4 a TARGET_BRANCH-only build: no marker"
replan "$GW"
[ ! -e "$BLD/replan-on-branch" ] && ok || bad "B5 a diff but no trigger: no marker"
N=$((N+1)); BLD="$H/builds/rb-$N"; mkdir -p "$BLD"; : > "$BLD/plan.md.thread-refused"
( cd "$GW"; HARNESS="$H"; PROJECT=cromford; KEY=BH-9672; BUILD="$BLD"; BASE=main; REPLAN_LINE=""; STAMP() { echo s; }; . "$LIB"; . "$REPLAN" ) >/dev/null 2>&1
[ -s "$BLD/replan-on-branch" ] && [ "$(head -1 "$BLD/replan-on-branch")" = "ids -" ] && ok || bad "B6 a refused plan in the dir triggers the note (ids -)"

echo "--- E execute note"
EB="$T/e"; mkdir -p "$EB"
S1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1; S2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2; S3=ccccccccccccccccccccccccccccccccccccccc3
printf 'ids 9002\n%s\tone\n%s\ttwo\n%s\tthree\n' "$S1" "$S2" "$S3" > "$EB/marker"
printf '# Plan\nWe keep the old work where it is still true.\n- %s keep: in prose before the section\n## Existing branch commits\n- %s keep: still true\n- %s DROP: superseded by 9002\n- dddddddd keep: not on the branch\n## Tasks\n- %s keep: outside the section\n' \
  "${S3:0:8}" "${S1:0:7}" "${S2:0:10}" "${S3:0:8}" > "$EB/plan.md"
EN=$( . "$LIB"; psr_exec_note "$EB/plan.md" "$EB/marker" )
grep -q "Keep these commits: ${S1:0:12}\." <<<"$EN" && ok || bad "E1 keep parsed (got: $EN)"
grep -q "it: ${S2:0:12}\." <<<"$EN" && ok || bad "E2 DROP parsed case-insensitive (got: $EN)"
grep -q "no keep or drop for: ${S3:0:12}\." <<<"$EN" && ok || bad "E3/E4 keep outside the section does not count; S3 is undecided (got: $EN)"
grep -q dddddddd <<<"$EN" && bad "E5 a sha not on the branch is ignored" || ok
printf '# Plan\n## Tasks\nnone\n' > "$EB/plan2.md"
EN=$( . "$LIB"; psr_exec_note "$EB/plan2.md" "$EB/marker" )
grep -q "no keep or drop for: ${S1:0:12} ${S2:0:12} ${S3:0:12}\." <<<"$EN" && ok || bad "E4 no section: every commit undecided (got: $EN)"
# E6: the round trip — the stub planner's section of P1 against P1's marker.
P1B=$(ls -d "$H/builds/f-1" 2>/dev/null)
EN=$( . "$LIB"; psr_exec_note "$P1B/plan.md" "$P1B/replan-on-branch" )
grep -q "Keep these commits: ${WORK1:0:12}\." <<<"$EN" && ok || bad "E6 the planner's section round-trips (got: $EN)"

echo "--- R retire"
reset_store; seed_row "$ROW_AT"
RO=$( HARNESS="$H"; PROJECT=cromford; KEY=BH-9672; . "$LIB"; . "$H/bin/jobs-client.sh"
      mkdir -p "$H/plans/cromford-BH-9672"; echo x > "$H/plans/cromford-BH-9672/plan.md"
      psr_retire "$H" cromford BH-9672 "$H/plans/cromford-BH-9672" "$ROW_AT"; echo "rc=$?" )
{ grep -q '^hub dir removed, db row retired$' <<<"$RO" && grep -q 'rc=0' <<<"$RO" && [ ! -e "$H/plans/cromford-BH-9672" ]; } && ok || bad "R1 hub dir and row (got: $RO)"
grep -q "\"thread_at_max\":\"$ROW_AT\"" "$H/store/calls" && ok || bad "R1 the body carries the refused stamp"
RO=$( HARNESS="$H"; . "$LIB"; . "$H/bin/jobs-client.sh"; psr_retire "$H" cromford BH-9672 "$T/relay" "$ROW_AT"; echo "rc=$?" )
grep -q '^db row already gone$' <<<"$RO" && ok || bad "R1 a second retire says already gone (got: $RO)"
echo 1 > "$H/store/retire.rc"
N=$((N+1)); BLD="$H/builds/r-$N"; mkdir -p "$BLD"
RO=$( HARNESS="$H"; PROJECT=cromford; KEY=BH-9672; BUILD="$BLD"; STAMP() { echo s; }; . "$LIB"; . "$H/bin/jobs-client.sh"
      psr_retire "$H" cromford BH-9672 "$BLD/preplan-db" "$ROW_AT"; echo "rc=$?" )
{ grep -q '^db retire failed (unreachable)$' <<<"$RO" && grep -q 'rc=2' <<<"$RO" && grep -q 'preplan-retire: db retire failed' "$BLD/pipeline.log"; } && ok \
  || bad "R2 an unreachable worker is rc 2 and says so (got: $RO)"
rm -f "$H/store/retire.rc"; : > "$H/store/calls"
( HARNESS="$H"; . "$LIB"; . "$H/bin/jobs-client.sh"; psr_retire "$H" cromford BH-9672 "" "" ) >/dev/null
grep -q '"thread_at_max":"1970-01-01T00:00:00Z"' "$H/store/calls" && ok || bad "R3 a stamp-less plan sends the epoch (calls: $(calls))"
# R2 through the gate: an unreachable worker names the failure in the RESULT.
reset_store; seed_row "$ROW_AT"; echo 1 > "$H/store/retire.rc"; echo "$C_P1" > "$H/page1.json"
flow R2g CKPT_START_POINT=origin/ticket/bh-9672 PSR_ADOPT_THREAD_CHECK=0 JOB_ID=job-r
case "$(cat "$BLD/RESULT" 2>/dev/null)" in *"refused plan retired (db retire failed (unreachable))"*) ok ;; *) bad "R2 the RESULT says the retire failed (got: $(cat "$BLD/RESULT" 2>/dev/null))" ;; esac
rm -f "$H/store/retire.rc"

echo "--- K knobs"
scratch_install_closure bin/lanes-build.sh "$H" >/dev/null || bad "K cannot install bin/lanes-build.sh"
mkdir -p "$H/catalog"; cp -r "$SRC/catalog/lanes.d" "$H/catalog/"
V=$( cd "$H" && unset PSR_LOOKBACK LANE_REGISTRY; HARNESS="$H"
     . bin/lib/lane-gate.sh && . bin/lib/lanes-registry.sh \
       && LANE_REGISTRY=$(lanes_json_path "$H") && export LANE_REGISTRY \
       && lib_env_apply plan-stale-replan >/dev/null 2>&1; printf '%s' "${PSR_LOOKBACK:-unset}/${PSR_COMMITS_MAX:-unset}/${PSR_REPEAT_FRESH:-unset}/${PSR_ADOPT_THREAD_CHECK:-unset}" ) 2>/dev/null
[ "$V" = 5/30/1/1 ] && ok || bad "K2 lib_env_apply plan-stale-replan resolves the registry defaults (got: $V)"
for k in PSR_ADOPT_THREAD_CHECK:1:0:1 PSR_REPEAT_FRESH:1:0:1 PSR_LOOKBACK:5:1:50 PSR_COMMITS_MAX:30:1:200; do
  IFS=: read -r e d lo hi <<<"$k"
  jq -e --arg e "$e" --argjson d "$d" --argjson lo "$lo" --argjson hi "$hi" \
    '.libs[] | select(.id=="plan-stale-replan") | .knobs[] | select(.env==$e and .default==$d and .min==$lo and .max==$hi)' \
    "$SRC/catalog/lanes.d/_lib.plan-stale-replan.json" >/dev/null 2>&1 && ok || bad "K2 the fragment declares $e $lo..$hi default $d"
done
KV=$( unset PSR_LOOKBACK; export LANE_REGISTRY="$T/nope.json"; . "$LIB"; psr_knob PSR_LOOKBACK )
[ "$KV" = 5 ] && ok || bad "K2 an unreadable registry gives the default (got: $KV)"
KV=$( export PSR_LOOKBACK=999; . "$LIB"; psr_knob PSR_LOOKBACK )
[ "$KV" = 5 ] && ok || bad "K2 an out-of-range value gives the default (got: $KV)"

echo "--- alert dedup"
: > "$ALERTS_F"
( . "$LIB"; psr_alert_once "$ALERTS_F" cromford BH-9672 "9003 9002" "planning fresh"; psr_alert_once "$ALERTS_F" cromford BH-9672 "9002 9003" "again" )
[ "$(grep -c 'PLAN_STALE_REPEAT \[cromford/BH-9672\] ids=9002 9003:' "$ALERTS_F")" = 1 ] && ok || bad "one ALERTS line per (ticket, id set) (got: $(cat "$ALERTS_F"))"
( . "$LIB"; psr_alert_once "$ALERTS_F" cromford BH-9672 "9002" "x" )
[ "$(wc -l < "$ALERTS_F" | tr -d ' ')" = 2 ] && ok || bad "another id set is another line"

echo "plan-stale-replan: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
