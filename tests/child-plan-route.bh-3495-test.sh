#!/bin/bash
# tests/child-plan-route.bh-3495-test.sh — which model plans a split child, and
# the build plan's warm start (BH-3478.3, AC2; the ticket body calls this suite
# child-plan-route.bh-3478-test.sh, it is named for its own key).
#
# a-f, R: the REAL bin/lib/child-plan.sh over the REAL bin/lib/model-route.sh and
#         jobs client, with a fake curl (tests/lib/model-route-stub.sh) answering
#         model_routes the way tests/model-route-lib.bh-1510-test.sh does.
# P:      the `# >>> context pack (BH-3478)` and `# >>> plan prompt` blocks,
#         extracted VERBATIM from the flattened pipeline (tests/lib/rb-all.sh)
#         and run with a stub cp_fetch and a recording CC.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/child-plan-route.bh-3495-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
LIB="$DIR/bin/lib/child-plan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: expected [$3] got [$2]"; }

[ -r "$LIB" ] && ok || bad "bin/lib/child-plan.sh does not exist"
mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/model-route.sh" "$T/bin/lib/"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
mrs_install "$T/fakebin"

fresh() { rm -rf "$T/routes" "$T/logs" "$T/flags" "$T/state" "$T/sink"; mkdir -p "$T/routes" "$T/logs"; }
cpm() { # cpm [args...] -> child_plan_model's stdout; its rc in $T/crc (read by crc)
  local out
  out=$( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
                MRS_ROUTES="$T/routes" MRS_SINK="$T/sink"
         [ -n "${CPM_ENV:-}" ] && export "${CPM_ENV?}" || unset PLAN_MODEL_CHILD
         . "$LIB" 2>/dev/null
         child_plan_model "$@" ); echo "$?" > "$T/crc"
  printf '%s' "$out"
}
crc() { cat "$T/crc"; }
alerts() { grep -c . "$T/logs/ALERTS.log" 2>/dev/null || echo 0; }

# (a) a seeded child route on the plan route's runner
fresh; mrs_route "$T/routes" plan model-plan-a:claude; mrs_route "$T/routes" stage.plan.child model-child-a:claude
eq a.model "$(cpm proj)" model-child-a; eq a.rc "$(crc)" 0
# a project-scoped child route wins over the hub one
mrs_route "$T/routes" stage.plan.child proj model-child-p:claude
eq a2.project-route "$(cpm proj)" model-child-p
rm -f "$T/routes/stage.plan.child@proj.json"

# (b) the child role answers source:none -> the plan route
fresh; mrs_route "$T/routes" plan model-plan-a:claude
eq b.model "$(cpm proj)" model-plan-a; eq b.rc "$(crc)" 0
# (e) ...and that writes no ALERTS line
eq e.alerts "$(alerts)" 0

# (c) PLAN_MODEL_CHILD wins, and nothing is asked
fresh; mrs_route "$T/routes" plan model-plan-a:claude; mrs_route "$T/routes" stage.plan.child model-child-a:claude
eq c.model "$(CPM_ENV=PLAN_MODEL_CHILD=model-env-z cpm proj)" model-env-z
[ -s "$T/sink" ] && bad "c: a model-routes request was made: $(cat "$T/sink")" || ok

# (d) runner mismatch -> the plan model, one ALERTS line per day
fresh; mrs_route "$T/routes" plan model-plan-a:claude; mrs_route "$T/routes" stage.plan.child model-child-a:codex
eq d.model "$(cpm proj)" model-plan-a
eq d.alerts "$(alerts)" 1
grep -qF "stage.plan.child runner codex differs from the plan route's runner claude — child plans stay on the plan route" "$T/logs/ALERTS.log" \
  && ok || bad "d: ALERTS line wrong: $(cat "$T/logs/ALERTS.log" 2>/dev/null)"
eq d.second-model "$(cpm proj)" model-plan-a
eq d.second-alerts "$(alerts)" 1

# (e) unseeded child role, and no plan route either: still no ALERTS line
fresh
cpm proj fb-model >/dev/null
eq e2.alerts "$(alerts)" 0

# (f) a PUT of a new child model is read on the next call
fresh; mrs_route "$T/routes" plan model-plan-a:claude; mrs_route "$T/routes" stage.plan.child model-child-a:claude
eq f.before "$(cpm proj)" model-child-a
mrs_route "$T/routes" stage.plan.child model-child-b:claude
eq f.after "$(cpm proj)" model-child-b

# R5: nothing routed at all
fresh
OUT=$(cpm proj); eq R5.rc "$(crc)" 75; eq R5.out "$OUT" ""
eq R5.fallback "$(cpm proj fb-model)" fb-model; eq R5.fallback-rc "$(crc)" 0
# a bad project token is a caller bug: no route is asked, the fallback answers
eq R6.bad-token "$(cpm 'bad proj' fb-model)" fb-model

# L: the loader refuses an empty root instead of guessing a path
OUT=$( cd "$T" && env -u HARNESS -u H PLAN_MODEL_CHILD= bash -c '. "$1"; child_plan_model proj fb; echo "rc=$?"' _ "$LIB" 2>&1 )
eq L.empty-root "$OUT" $'fb\nrc=0'

# =============================================================================
# P. the plan.sh blocks
# =============================================================================
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all"; exit 1; }
awk '$0=="# >>> context pack (BH-3478)" {f=1} f {print} $0=="# <<< context pack" {exit}' "$RB" > "$T/cp-block.sh"
awk 'index($0, "# >>> plan prompt")==1 {f=1} f {print} $0=="# <<< plan prompt" {exit}' "$RB" > "$T/prompt-block.sh"
grep -qx '# <<< context pack' "$T/cp-block.sh" && ok || bad "P0: could not extract the context pack block"
grep -qx '# <<< plan prompt' "$T/prompt-block.sh" && ok || bad "P0: could not extract the plan prompt block"
# P3 structure: the block runs on the adopted/resumed path too, so it sits
# after the call-fp reuse and BEFORE the checkpoint if, not inside its else arm.
L_CP=$(grep -n -x '# >>> context pack (BH-3478)' "$RB" | head -1 | cut -d: -f1)
L_FP=$(grep -n -x '# <<< call fp reuse' "$RB" | head -1 | cut -d: -f1)
L_IF=$(grep -n -F 'if [ -s "$BUILD/plan.md" ] && ! PLAN_IS_BLOCKED "$BUILD/plan.md"; then' "$RB" | head -1 | cut -d: -f1)
L_LA=$(grep -n -x '# >>> plan launch' "$RB" | head -1 | cut -d: -f1)
[ -n "$L_CP" ] && [ -n "$L_FP" ] && [ -n "$L_IF" ] && [ -n "$L_LA" ] \
  && [ "$L_FP" -lt "$L_CP" ] && [ "$L_CP" -lt "$L_IF" ] && [ "$L_IF" -lt "$L_LA" ] && ok \
  || bad "P3: order call-fp-reuse($L_FP) < context-pack(${L_CP:-none}) < checkpoint-if($L_IF) < plan-launch($L_LA) does not hold"

H="$T/h"; B="$T/b"
mkdir -p "$H/bin/lib" "$H/state/model-routes"
cp "$DIR/bin/lib/model-route.sh" "$H/bin/lib/"
cp "$LIB" "$H/bin/lib/child-plan.sh" 2>/dev/null
# The real context-pack lib (cp_preamble), with cp_fetch replaced by a stub:
# STUB_CP 0 writes a pack whose parent is BH-9000, 2 is no row, anything else 1.
{ cat "$DIR/bin/lib/context-pack.sh"; cat <<'EOF'
cp_fetch() {
  echo "$*" >> "$T/cp-calls"
  case "${STUB_CP:-2}" in
    0) printf '## parent map\nbin/x.sh does the thing\n' > "$3"; echo BH-9000 > "$3.parent"; return 0 ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}
EOF
} > "$H/bin/lib/context-pack.sh"
# Box cache only (no client beside the resolver): what an outage box serves.
printf '0\tmodel-plan-a\tclaude\n' > "$H/state/model-routes/plan@cromford.tsv"
printf '0\tmodel-child-a\tclaude\n' > "$H/state/model-routes/stage.plan.child@cromford.tsv"

cat > "$T/drive.sh" <<'EOF'
set -uo pipefail
STAMP() { echo TS; }
CC() { printf '%s' "$2" > "$T/cc.model"; printf '%s' "$5" > "$T/cc.prompt"; env | grep '^CONTEXT_KILL_TOKENS=' > "$T/cc.env"; return 0; }
PROJECT=cromford KEY=BH-3495 TICKET=3495 BUILD="$T/b"
PLAN_AMBIGUITY_RULE=AMBIG KIND_HINT_LINE= CARRIED_NOTE_LINE=
# TEST-CHANGE (BH-7970): the plan prompt block calls sp_render; its source line sits just above the block, so the driver loads the lib.
. "$SPLIB" || exit 9
for f in "$@"; do . "$f"; done
printf '%s' "$PLAN_MODEL" > "$T/final.model"
printf '%s' "${CP_PARENT:-}" > "$T/final.parent"
EOF
prun() { # prun <block files...> ; env via PENV array
  scratch_rm "$B"; rm -rf "$T/cc."* "$T/final."* "$T/cp-calls"; mkdir -p "$B"; : > "$B/pipeline.log"
  [ -n "${SEED_RESUME:-}" ] && { echo '# plan' > "$B/plan.md"; printf 'resumed map\n' > "$B/context-pack.md"; echo BH-7000 > "$B/context-pack.md.parent"; }
  env -u CP_PARENT -u CP_PREAMBLE -u PLAN_MODEL_CHILD -u HARNESS_SECRET -u CONTEXT_KILL_TOKENS \
    HARNESS="$H" T="$T" SPLIB="$DIR/bin/lib/stage-prompt.sh" PLAN_MODEL=model-plan-a JOBS_URL= ${PENV[@]+"${PENV[@]}"} bash "$T/drive.sh" "$@" > "$T/drive.out" 2>&1
}
plog() { cat "$B/pipeline.log"; }

# baseline: the plan prompt block alone, as a non-child build runs it today
PENV=(); prun "$T/prompt-block.sh"
cp "$T/cc.prompt" "$T/baseline.prompt"
[ -s "$T/baseline.prompt" ] && ok || bad "P: baseline prompt not captured ($(cat "$T/drive.out"))"

# P1: a child
PENV=(STUB_CP=0); prun "$T/cp-block.sh" "$T/prompt-block.sh"
eq P1.model "$(cat "$T/cc.model" 2>/dev/null)" model-child-a
case "$(cat "$T/cc.prompt" 2>/dev/null)" in "WARM START: this ticket is a split child of BH-9000."*) ok ;; *) bad "P1: prompt does not open with the WARM START preamble: $(head -c 100 "$T/cc.prompt" 2>/dev/null)" ;; esac
grep -qF 'bin/x.sh does the thing' "$T/cc.prompt" && ok || bad "P1: prompt does not embed the pack"
grep -qF "$(cat "$T/baseline.prompt")" "$T/cc.prompt" && ok || bad "P1: the baseline prompt does not follow the preamble intact"
grep -qx 'TS \[cromford/BH-3495\] CHILD_PLAN parent=BH-9000 model=model-child-a' "$B/pipeline.log" && ok \
  || bad "P1: pipeline.log: $(plog)"
[ -s "$T/cc.env" ] && bad "P1: the build plan got a token cap: $(cat "$T/cc.env")" || ok
eq P1.cp-parent "$(cat "$T/final.parent")" BH-9000
eq P1.fetch "$(cat "$T/cp-calls" 2>/dev/null)" "cromford BH-3495 $B/context-pack.md"

# P2: not a child (no row)
PENV=(STUB_CP=2); prun "$T/cp-block.sh" "$T/prompt-block.sh"
eq P2.model "$(cat "$T/cc.model")" model-plan-a
cmp -s "$T/cc.prompt" "$T/baseline.prompt" && ok || bad "P2: prompt differs from the no-block baseline"
grep -qx 'TS \[cromford/BH-3495\] CHILD_PLAN none (no context pack)' "$B/pipeline.log" && ok || bad "P2: pipeline.log: $(plog)"
eq P2.cp-parent "$(cat "$T/final.parent")" ""
# P2b: an outage
PENV=(STUB_CP=1); prun "$T/cp-block.sh" "$T/prompt-block.sh"
eq P2b.model "$(cat "$T/cc.model")" model-plan-a
cmp -s "$T/cc.prompt" "$T/baseline.prompt" && ok || bad "P2b: prompt differs from the no-block baseline"
grep -qx 'TS \[cromford/BH-3495\] CHILD_PLAN none (context pack unreachable)' "$B/pipeline.log" && ok || bad "P2b: pipeline.log: $(plog)"
# P2c: a stale box with no context-pack lib
mv "$H/bin/lib/context-pack.sh" "$T/cp-parked.sh"
PENV=(); prun "$T/cp-block.sh" "$T/prompt-block.sh"
eq P2c.model "$(cat "$T/cc.model")" model-plan-a
cmp -s "$T/cc.prompt" "$T/baseline.prompt" && ok || bad "P2c: prompt differs with no lib"
grep -qx 'TS \[cromford/BH-3495\] CHILD_PLAN none (no context-pack lib)' "$B/pipeline.log" && ok || bad "P2c: pipeline.log: $(plog)"
mv "$T/cp-parked.sh" "$H/bin/lib/context-pack.sh"

# P3: an adopted / resumed plan: the cached pack is reused, never re-fetched
PENV=(STUB_CP=0); SEED_RESUME=1 prun "$T/cp-block.sh"
[ -e "$T/cp-calls" ] && bad "P3: cp_fetch called although the pack was already in \$BUILD" || ok
eq P3.model "$(cat "$T/final.model")" model-child-a
eq P3.parent "$(cat "$T/final.parent")" BH-7000
grep -qx 'TS \[cromford/BH-3495\] CHILD_PLAN parent=BH-7000 model=model-child-a' "$B/pipeline.log" && ok || bad "P3: pipeline.log: $(plog)"

# P4: a CP_PARENT leaking in from the environment does not make a child
PENV=(STUB_CP=2 CP_PARENT=BH-1 "CP_PREAMBLE=WARM START: stale"); prun "$T/cp-block.sh" "$T/prompt-block.sh"
cmp -s "$T/cc.prompt" "$T/baseline.prompt" && ok || bad "P4: an inherited CP_PREAMBLE reached the prompt"
eq P4.model "$(cat "$T/cc.model")" model-plan-a
eq P4.parent "$(cat "$T/final.parent")" ""
grep -qx 'TS \[cromford/BH-3495\] CHILD_PLAN none (no context pack)' "$B/pipeline.log" && ok || bad "P4: pipeline.log: $(plog)"

echo "child-plan-route.bh-3495: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
