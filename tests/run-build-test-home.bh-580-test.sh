#!/bin/bash
# tests/run-build-test-home.bh-580-test.sh — the CONSUMER side of the per-ticket
# test-file contract (#580.2 / BH-585), driven out of bin/run-build.sh itself.
#
# The contract lives in bin/lib/test-home-lib.sh and is tested next door
# (tests/test-home-lib.bh-580-test.sh). What is tested HERE is the wiring, which
# is where the damage would be: a reroute that never reaches the executor is a
# claim list that lies about which file the session will write, and a backstop
# that answers "clean" off a GitHub read that failed tells a reviewer something
# false. Every block below is extracted VERBATIM from bin/run-build.sh by its
# markers and evaluated in a scratch harness — nothing here asserts on the
# script's source text.
#
# Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/run-build-test-home.bh-580-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
RB="$RB_ALL"
LIB="$DIR/bin/lib/test-home-lib.sh"
NOW=$(date +%s)          # read ONCE: every fixture age below is derived from it
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The block extractor: the marker is matched at position 1, so the trailing
# "(tests/... drives this block)" text is free to change without breaking this.
xb() { # xb <marker name> <outfile>
  awk -v n="$1" 'index($0, "# >>> " n)==1 {f=1;next} index($0, "# <<< " n)==1 {exit} f' \
    "$RB" > "$2"
}

# The lib is sourced HERE too, so the fixtures are records th_record_add itself
# writes rather than strings this suite invented (D4).
TEST_REROUTE_RELAY_DIR="$T/relay"
# shellcheck source=../bin/lib/test-home-lib.sh
. "$LIB" || { echo "FAIL: could not source $LIB"; exit 1; }

VIOL="$T/violations"     # every stubbed RESULT/flock/sleep/CC lands here
FVIOL="$T/viol-f.txt"    # the rows section F judges
: > "$FVIOL"

setup() { # fresh harness ($H), build dir ($B) and checkout ($W) per row
  rm -rf "$T/h" "$T/b" "$T/w" "$T/relay"
  mkdir -p "$T/h/state/preplan-files" "$T/h/state/overlap-guard" "$T/h/flags" \
           "$T/h/bin/lib" "$T/b" "$T/w/tests" "$T/relay" "$T/stub"
  cp "$LIB" "$T/h/bin/lib/test-home-lib.sh"
  cp "$DIR/bin/lib/scheduler-conf.sh" "$T/h/bin/lib/scheduler-conf.sh"
  # bin/lib/gh-pr-list.sh is deliberately NOT copied: a row that wants a PR list
  # hands one over as a file or installs its own stub, so this suite can never
  # reach the network.
  H="$T/h"; B="$T/b"; W="$T/w"
  printf '#!/bin/bash\nexit 1\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"
  : > "$VIOL"
}
viol_none() { # viol_none <label> <what>   — the stub recorded nothing of <what>
  grep -q "$2" "$VIOL" 2>/dev/null \
    && bad "$1: the block must never call $2" || ok
}

# ============================================================================
# A. the PLAN prompt carries the planner's naming rule
# ============================================================================
xb 'plan prompt' "$T/plan-prompt.sh"
[ -s "$T/plan-prompt.sh" ] && ok || bad "A0: could not extract the 'plan prompt' block — markers missing?"

planprompt() { # planprompt <source-the-lib: 1|0> <capture file>
  # TEST-CHANGE (BH-7970): the block renders prompts/stages/plan.md through sp_render, so the driver always loads bin/lib/stage-prompt.sh; only the test-home lib toggles.
  rm -f "$2"
  ( env HARNESS="$H" BUILD="$B" KEY=AB-1 TICKET=1 PROJECT=widget-os PLAN_MODEL=m \
        PLAN_AMBIGUITY_RULE= KIND_HINT_LINE= CARRIED_NOTE_LINE= \
        SRC="$1" LIBP="$LIB" CAP="$2" SPLIB="$DIR/bin/lib/stage-prompt.sh" \
    bash -c 'set -uo pipefail
             CC() { printf "%s" "$5" > "$CAP"; }
             CC_ARTIFACT_KIND=; CC_ARTIFACT_FILE=
             if [ "$SRC" = 1 ]; then . "$LIBP"; fi
             . "$SPLIB"
             . "$0"' "$T/plan-prompt.sh" ) >"$T/plan-prompt.out" 2>&1
}

# A1. with the lib present the rule is a PREFIX on today's plan instructions.
setup
planprompt 1 "$T/p1.txt"
grep -qF 'tests/<tier>/<area>.ab-1.test.ts' "$T/p1.txt" \
  && ok || bad "A1: the plan prompt must name the per-ticket file for this key"
grep -qF 'never appended to an existing shared test file' "$T/p1.txt" \
  && ok || bad "A1: the plan prompt must carry the naming rule"
grep -qF 'PLAN ONLY - do not modify' "$T/p1.txt" \
  && ok || bad "A1: the rule must be a PREFIX — the plan instructions must survive it"
[ "$(head -c 21 "$T/p1.txt")" = 'TEST FILES ARE PER-TI' ] \
  && ok || bad "A1: the rule must come FIRST (got: $(head -c 40 "$T/p1.txt" 2>/dev/null))"

# A2. an old box with no lib gets byte-identically today's prompt: A1's capture
#     is A2's capture with exactly the rule sentence in front of it.
planprompt 0 "$T/p2.txt"
[ "$(head -c 25 "$T/p2.txt")" = 'PLAN ONLY - do not modify' ] \
  && ok || bad "A2: with no lib the prompt must still START with 'PLAN ONLY' (got: $(head -c 40 "$T/p2.txt" 2>/dev/null))"
# TEST-CHANGE (BH-5788): the lib also adds th_fragment_rule after th_plan_rule
# (it prints only in a checkout with worker/*/schema.d/, judged from the cwd
# like the block itself), so the prefix is both sentences.
{ printf '%s' "$(th_plan_rule AB-1)$(th_fragment_rule AB-1 .)"; cat "$T/p2.txt"; } > "$T/p2-plus-rule.txt"
cmp -s "$T/p1.txt" "$T/p2-plus-rule.txt" \
  && ok || bad "A2: the ONLY difference between the two prompts must be the rule prefix"

# ============================================================================
# B. the reroute block swaps the claim list and captures the executor note
# ============================================================================
xb 'test reroute' "$T/reroute.sh"
[ -s "$T/reroute.sh" ] && ok || bad "B0: could not extract the 'test reroute' block — markers missing?"
bash -n "$T/reroute.sh" 2>/dev/null && ok || bad "B0: the extracted reroute block does not parse on its own"

reroute() { # reroute <block-file> [VAR=val...] -> rc; note in $B/note.txt
  ( env HARNESS="$H" BUILD="$B" PROJECT=widget-os KEY=AB-1 KIND=feature WT="$W" \
        TEST_REROUTE_RELAY_DIR="$T/relay" LIBP="$LIB" VIOL="$VIOL" "${@:2}" \
    bash -c 'set -uo pipefail
             STAMP()  { echo TS; }
             RESULT() { echo "RESULT $*" >> "$VIOL"; }
             flock()  { echo FLOCK >> "$VIOL"; }
             sleep()  { echo SLEEP >> "$VIOL"; }
             CC()     { echo CCCALL >> "$VIOL"; }
             REROUTE_EXEC_NOTE=""
             . "$LIBP"
             . "$0"
             printf "%s" "$REROUTE_EXEC_NOTE" > "$BUILD/note.txt"' "$1" ) \
    >"$T/reroute.out" 2>&1
}

# B1. a hub record: the list carries the per-ticket path and not the shared one.
setup
th_record_add "$(th_record_path "$H" widget-os AB-1)" tests/shared-test.sh tests/shared.ab-1-test.sh
printf 'tests/shared-test.sh\nsrc/x.ts\n' > "$B/planned-files.txt"
printf '# plan\n' > "$B/plan.md"
reroute "$T/reroute.sh"; RC=$?
[ "$RC" = 0 ] && ok || bad "B1: the reroute block must exit 0 (got $RC; $(cat "$T/reroute.out"))"
grep -qxF 'tests/shared.ab-1-test.sh' "$B/planned-files.txt" \
  && ok || bad "B1: the per-ticket path must be in the claim list"
grep -qxF 'tests/shared-test.sh' "$B/planned-files.txt" \
  && bad "B1: the shared path must be GONE from the claim list" || ok
grep -qxF 'src/x.ts' "$B/planned-files.txt" \
  && ok || bad "B1: the non-test entries must survive the swap"
[ -s "$B/test-reroute.txt" ] && ok || bad "B1: the record must be copied to \$BUILD/test-reroute.txt"
grep -qF 'TEST_REROUTE: 1 path(s) forwarded to EXECUTE' "$B/pipeline.log" \
  && ok || bad "B1: pipeline.log must record the forward (got: $(cat "$B/pipeline.log" 2>/dev/null))"
grep -qF 'tests/shared.ab-1-test.sh' "$B/note.txt" && grep -qF 'tests/shared-test.sh' "$B/note.txt" \
  && ok || bad "B1: the executor note must name both the target and the shared file"
viol_none B1 RESULT
cat "$VIOL" >> "$FVIOL"

# B2. relay first, hub second — a pool machine reads its own copy.
setup
th_record_add "$(th_relay_path widget-os AB-1)" tests/shared-test.sh tests/shared.ab-1-test.sh
th_record_add "$(th_record_path "$H" widget-os AB-1)" tests/shared-test.sh tests/shared.zz-1-test.sh
printf 'tests/shared-test.sh\n' > "$B/planned-files.txt"
printf '# plan\n' > "$B/plan.md"
reroute "$T/reroute.sh"
grep -qxF 'tests/shared.ab-1-test.sh' "$B/planned-files.txt" \
  && ok || bad "B2: the RELAY record must win over the hub one"
grep -qF 'tests/shared.zz-1-test.sh' "$B/planned-files.txt" \
  && bad "B2: the hub record must not be applied when a relay record exists" || ok

# B3. no record at all: nothing moves, nothing is said.
setup
printf 'tests/shared-test.sh\nsrc/x.ts\n' > "$B/planned-files.txt"
cp "$B/planned-files.txt" "$T/before.txt"
printf '# plan\n' > "$B/plan.md"
reroute "$T/reroute.sh"; RC=$?
[ "$RC" = 0 ] && ok || bad "B3: no record must still exit 0 (got $RC)"
cmp -s "$T/before.txt" "$B/planned-files.txt" \
  && ok || bad "B3: with no record the claim list must be byte-identical"
[ ! -s "$B/note.txt" ] && ok || bad "B3: with no record the executor note must be empty"
[ ! -e "$B/test-reroute.txt" ] && ok || bad "B3: with no record no test-reroute.txt may be written"
grep -q 'TEST_REROUTE' "$B/pipeline.log" 2>/dev/null \
  && bad "B3: with no record nothing may be logged" || ok

# B4. the kill switch: a record exists and is ignored, both spellings.
setup
th_record_add "$(th_record_path "$H" widget-os AB-1)" tests/shared-test.sh tests/shared.ab-1-test.sh
printf 'tests/shared-test.sh\nsrc/x.ts\n' > "$B/planned-files.txt"
cp "$B/planned-files.txt" "$T/before.txt"
printf '# plan\n' > "$B/plan.md"
reroute "$T/reroute.sh" TEST_REROUTE=0
cmp -s "$T/before.txt" "$B/planned-files.txt" \
  && ok || bad "B4: TEST_REROUTE=0 must leave the claim list alone"
[ ! -s "$B/note.txt" ] && ok || bad "B4: TEST_REROUTE=0 must produce no executor note"
grep -q 'TEST_REROUTE:' "$B/pipeline.log" 2>/dev/null \
  && bad "B4: TEST_REROUTE=0 must log nothing" || ok
[ ! -e "$B/test-home.txt" ] && ok || bad "B4: TEST_REROUTE=0 must not run the plan-time finding either"

setup
th_record_add "$(th_record_path "$H" widget-os AB-1)" tests/shared-test.sh tests/shared.ab-1-test.sh
printf 'tests/shared-test.sh\nsrc/x.ts\n' > "$B/planned-files.txt"
cp "$B/planned-files.txt" "$T/before.txt"
printf '# plan\n' > "$B/plan.md"
: > "$H/flags/test-reroute-off"
reroute "$T/reroute.sh"
cmp -s "$T/before.txt" "$B/planned-files.txt" \
  && ok || bad "B4b: flags/test-reroute-off must leave the claim list alone"
[ ! -s "$B/note.txt" ] && ok || bad "B4b: flags/test-reroute-off must produce no executor note"

# B5. a resumed build whose list is already swapped: the swap is a no-op.
setup
th_record_add "$(th_record_path "$H" widget-os AB-1)" tests/shared-test.sh tests/shared.ab-1-test.sh
printf 'tests/shared.ab-1-test.sh\nsrc/x.ts\n' > "$B/planned-files.txt"
cp "$B/planned-files.txt" "$T/before.txt"
printf '# plan\n' > "$B/plan.md"
reroute "$T/reroute.sh"
cmp -s "$T/before.txt" "$B/planned-files.txt" \
  && ok || bad "B5: a resumed build's already-swapped list must stay byte-identical"
grep -qF 'tests/shared.ab-1-test.sh' "$B/note.txt" \
  && ok || bad "B5: a resumed EXECUTE still needs the note"

# B6. MUTATION (D1): drop the th_apply call and the B1 swap must go red.
sed '/th_apply /d' "$T/reroute.sh" > "$T/reroute.mut.sh"
cmp -s "$T/reroute.sh" "$T/reroute.mut.sh" \
  && bad "B6: the mutant is identical to the block — there is no th_apply call to remove" || ok
setup
th_record_add "$(th_record_path "$H" widget-os AB-1)" tests/shared-test.sh tests/shared.ab-1-test.sh
printf 'tests/shared-test.sh\nsrc/x.ts\n' > "$B/planned-files.txt"
printf '# plan\n' > "$B/plan.md"
reroute "$T/reroute.mut.sh"
grep -qxF 'tests/shared.ab-1-test.sh' "$B/planned-files.txt" \
  && bad "B6: MUTATION NOT CAUGHT — the list swapped without th_apply, so B1 proves nothing" || ok

# B7. PLACEMENT is the requirement: the swap has to happen before the claim is
# published, or the sibling that reads claims/<project>/<KEY> is told about a
# file this build will never write. Ordering is the one thing no artifact can
# show, so this row pins it on the script — and it fails LOUD when either anchor
# goes missing, rather than passing on two empty greps.
TH_END=$(grep -n '^# <<< test reroute' "$RB" | head -1 | cut -d: -f1)
TH_CP=$(grep -n '^cp "\$BUILD/planned-files.txt" "\$HARNESS/state/claims/\$PROJECT/\$KEY"' "$RB" | head -1 | cut -d: -f1)
if [ -n "$TH_END" ] && [ -n "$TH_CP" ]; then
  [ "$TH_END" -lt "$TH_CP" ] \
    && ok || bad "B7: the reroute block must sit BEFORE the claims copy (block ends $TH_END, cp at $TH_CP)"
else
  bad "B7: could not locate both anchors (reroute end='$TH_END', claims cp='$TH_CP')"
fi

# ============================================================================
# C. the plan-time finding: a shared test file named as a plain add target
# ============================================================================
# Every row drives the WHOLE reroute block with no record, so the finding runs
# exactly where production runs it.
cplan() { # cplan <plan.md body> <planned-files body> [VAR=val...]
  setup
  mkdir -p "$W/tests"
  printf 'a\n' > "$W/tests/shared-test.sh"
  printf 'a\n' > "$W/tests/shared.ab-1-test.sh"
  printf '%s\n' "$1" > "$B/plan.md"
  printf '%s\n' "$2" > "$B/planned-files.txt"
  reroute "$T/reroute.sh" "${@:3}"
}
shared_n() { grep -c '^SHARED: ' "$B/test-home.txt" 2>/dev/null || true; }

# C1. "add cases for X" is exactly the case this finding exists for.
cplan '- tests/shared-test.sh: add cases for X' 'tests/shared-test.sh'
[ "$(shared_n)" = 1 ] && ok || bad "C1: an added-to shared test file must produce one SHARED line (got $(shared_n))"
grep -qxF 'SHARED: tests/shared-test.sh -> tests/shared.ab-1-test.sh' "$B/test-home.txt" \
  && ok || bad "C1: the SHARED line must name the per-ticket path (got: $(cat "$B/test-home.txt" 2>/dev/null))"
grep -qxF 'TEST_HOME_PLAN: 1' "$B/test-home.txt" \
  && ok || bad "C1: the count line must be written"
[ "$(grep -c 'TEST_HOME_PLAN: 1 shared test file' "$B/pipeline.log" 2>/dev/null)" = 1 ] \
  && ok || bad "C1: pipeline.log must carry exactly one advisory line"
viol_none C1 RESULT
cat "$VIOL" >> "$FVIOL"

# C2. a ticket whose scope IS the existing test is not a finding.
cplan '- tests/shared-test.sh: change the existing assertion' 'tests/shared-test.sh'
[ "$(shared_n)" = 0 ] && ok || bad "C2: a change-word line must produce no finding (got: $(cat "$B/test-home.txt" 2>/dev/null))"
viol_none C2 RESULT

# C3. a bug reproduction belongs next to the case it fixes.
cplan '- tests/shared-test.sh: add cases for X' 'tests/shared-test.sh' KIND=bug
[ "$(shared_n)" = 0 ] && ok || bad "C3: KIND=bug must produce no finding"
viol_none C3 RESULT

# C4. naming a file as a regression risk is not planning to write it.
cplan 'regression risk: tests/shared-test.sh' 'tests/shared-test.sh'
[ "$(shared_n)" = 0 ] && ok || bad "C4: a regression-risk mention must produce no finding"
viol_none C4 RESULT

# C5. the per-ticket path is the thing we are asking for.
cplan '- tests/shared.ab-1-test.sh: add cases for X' 'tests/shared.ab-1-test.sh'
[ "$(shared_n)" = 0 ] && ok || bad "C5: a per-ticket path must never be a finding"
viol_none C5 RESULT

# C6. a NEW test file does not exist in the checkout and is nobody's shared file.
cplan '- tests/brand-new-test.sh: add cases for X' 'tests/brand-new-test.sh'
[ "$(shared_n)" = 0 ] && ok || bad "C6: a file absent from the checkout must produce no finding"
viol_none C6 RESULT

# C7. the pre-plan list header is a header, never a path.
cplan '- tests/shared-test.sh: add cases for X' 'SOURCE: level2
tests/shared-test.sh'
[ "$(shared_n)" = 1 ] && ok || bad "C7: a SOURCE: header must be ignored and the real path still found (got $(shared_n))"

# ============================================================================
# D. the executor actually receives it (the production wiring, D2/D27)
# ============================================================================
xb 'execute prompt' "$T/exec-prompt.sh"
[ -s "$T/exec-prompt.sh" ] && ok || bad "D0: could not extract the 'execute prompt' block — markers missing?"

chain() { # chain <capture file> [run the reroute block first: 1|0]
  # TEST-CHANGE (BH-7970): the execute block renders prompts/stages/execute.md through sp_render, so the driver loads bin/lib/stage-prompt.sh.
  rm -f "$1"
  ( env HARNESS="$H" BUILD="$B" PROJECT=widget-os KEY=AB-1 KIND=feature WT="$W" \
        TEST_REROUTE_RELAY_DIR="$T/relay" LIBP="$LIB" BRANCH=ticket/ab-1 \
        EXECUTE_MODEL=m CKPT_RESUME_NOTE= KIND_EXEC_NOTE= EXECUTE_TIMEOUT_SECS=1 \
        RR="$T/reroute.sh" CAP="$1" PRE="${2:-1}" VIOL="$VIOL" SPLIB="$DIR/bin/lib/stage-prompt.sh" \
    bash -c 'set -uo pipefail
             STAMP()  { echo TS; }
             RESULT() { echo "RESULT $*" >> "$VIOL"; }
             CC()     { printf "%s" "$5" > "$CAP"; }
             CKPT_START() { :; }
             REROUTE_EXEC_NOTE=""
             . "$LIBP"
             [ "$PRE" = 1 ] && . "$RR"
             . "$SPLIB"
             . "$0"' "$T/exec-prompt.sh" ) >"$T/chain.out" 2>&1
}

# D1. a REROUTE line in the record reaches the execute prompt.
setup
th_record_add "$(th_record_path "$H" widget-os AB-1)" tests/shared-test.sh tests/shared.ab-1-test.sh
printf 'tests/shared-test.sh\n' > "$B/planned-files.txt"
printf '# plan\n' > "$B/plan.md"
chain "$B/exec.txt"
grep -qF 'tests/shared.ab-1-test.sh' "$B/exec.txt" \
  && ok || bad "D1: the execute prompt must name the per-ticket path"
grep -qF 'tests/shared-test.sh' "$B/exec.txt" \
  && ok || bad "D1: the execute prompt must name the shared path it is steering away from"
grep -qF 'Execute the plan at' "$B/exec.txt" \
  && ok || bad "D1: the note must be a PREFIX — the execute instructions must survive it"

# D2. no record: the prompt is byte-identically the one today's pipeline sends.
setup
printf 'tests/shared-test.sh\n' > "$B/planned-files.txt"
printf '# plan\n' > "$B/plan.md"
chain "$B/exec-none.txt" 1
chain "$B/exec-bare.txt" 0
[ "$(head -c 19 "$B/exec-none.txt")" = 'Execute the plan at' ] \
  && ok || bad "D2: with no record the prompt must START with 'Execute the plan at' (got: $(head -c 40 "$B/exec-none.txt" 2>/dev/null))"
cmp -s "$B/exec-none.txt" "$B/exec-bare.txt" \
  && ok || bad "D2: with no record the prompt must be byte-identical to the empty-note prompt"

# ============================================================================
# E. the execute-time diff backstop — advisory, and never a block
# ============================================================================
xb 'test home diff' "$T/diff.sh"
[ -s "$T/diff.sh" ] && ok || bad "E0: could not extract the 'test home diff' block — markers missing?"
bash -n "$T/diff.sh" 2>/dev/null && ok || bad "E0: the extracted backstop does not parse on its own"

mkrepo() { # mkrepo <touch-shared|new-file|base-moved>
  rm -rf "$T/r"; mkdir -p "$T/r/tests" "$T/r/bin"
  ( cd "$T/r" \
    && git init -q -b main \
    && git config user.email t@example.invalid && git config user.name t \
    && printf 'base\n' > tests/shared-test.sh \
    && printf 'base\n' > tests/other-test.sh \
    && printf 'base\n' > tests/keep.ab-1-test.sh \
    && printf 'base\n' > bin/x.sh \
    && git add -A && git commit -qm base \
    && git checkout -q -b ticket/ab-1 ) >/dev/null 2>&1
  case "$1" in
    touch-shared) printf 'added\n' >> "$T/r/tests/shared-test.sh" ;;
    new-file)     printf 'new\n'    > "$T/r/tests/brand-new-test.sh" ;;
    base-moved)   printf 'branch\n' > "$T/r/tests/brand-new-test.sh" ;;
  esac
  ( cd "$T/r" && git add -A && git commit -qm change ) >/dev/null 2>&1
  # main moves AFTER the fork: the file now exists at the tip of $BASE but not at
  # the merge base, which is the only place the existence check may look.
  if [ "$1" = base-moved ]; then
    ( cd "$T/r" && git checkout -q main \
      && printf 'main\n' > tests/brand-new-test.sh \
      && git add -A && git commit -qm main-moved \
      && git checkout -q ticket/ab-1 ) >/dev/null 2>&1
  fi
}

prsjson() { # prsjson <branch> <isDraft> <files-json> -> path
  printf '[{"number":7,"headRefName":"%s","isDraft":%s,"files":%s}]\n' "$1" "$2" "$3" > "$T/prs.json"
  printf '%s' "$T/prs.json"
}

backstop() { # backstop [VAR=val...] -> rc; GATES_NOTE in $B/NOTE.txt
  rm -f "$B/NOTE.txt"
  ( cd "$T/r" && env HARNESS="$H" BUILD="$B" PROJECT=widget-os KEY=AB-1 BASE=main \
        GH_AUTH_SLUG=owner/repo PATH="$T/stub:$PATH" LIBP="$LIB" VIOL="$VIOL" \
        BLK="$T/diff.sh" "$@" \
    bash -c 'set -uo pipefail
             STAMP()  { echo TS; }
             RESULT() { echo "RESULT $*" >> "$VIOL"; }
             flock()  { echo FLOCK >> "$VIOL"; }
             sleep()  { echo SLEEP >> "$VIOL"; }
             CC()     { echo CCCALL >> "$VIOL"; }
             GATES_NOTE=""
             . "$LIBP"
             . "$BLK"
             printf "%s" "$GATES_NOTE" > "$BUILD/NOTE.txt"' ) >"$T/backstop.out" 2>&1
}
verdict() { grep '^TEST_HOME_VERDICT: ' "$B/test-home.txt" 2>/dev/null | tail -1; }
erow() { # erow <label> <expected verdict> <rc>
  [ "$(verdict)" = "TEST_HOME_VERDICT: $2" ] \
    && ok || bad "$1: expected verdict '$2' (got: '$(verdict)'; $(cat "$T/backstop.out" 2>/dev/null))"
  [ "$3" = 0 ] && ok || bad "$1: the backstop must exit 0 (got $3)"
  viol_none "$1" RESULT
  grep -qF 'advisory — not a block' "$B/NOTE.txt" \
    && ok || bad "$1: the gate note must say it is advisory (got: $(cat "$B/NOTE.txt" 2>/dev/null))"
}

# E1. the case the whole backstop exists for: a sibling PR holds the same file.
setup; mkrepo touch-shared
backstop TEST_HOME_PRS_FILE="$(prsjson ticket/ab-9 false '[{"path":"tests/shared-test.sh"}]')"; RC=$?
erow E1 shared "$RC"
grep -qxF 'SHARED: tests/shared-test.sh (PR#7) -> tests/shared.ab-1-test.sh' "$B/test-home.txt" \
  && ok || bad "E1: test-home.txt must carry the SHARED line (got: $(cat "$B/test-home.txt" 2>/dev/null))"
grep -qF 'TEST-HOME GATE: shared' "$B/NOTE.txt" && ok || bad "E1: the note must carry the verdict"
grep -qF 'PR#7' "$B/NOTE.txt" && ok || bad "E1: the note must name the sibling PR"
grep -qF 'tests/shared.ab-1-test.sh' "$B/NOTE.txt" \
  && ok || bad "E1: the note must name the per-ticket path the cases belong in"
cat "$VIOL" >> "$FVIOL"

# E2. same diff, the sibling holds a DIFFERENT test file.
setup; mkrepo touch-shared
backstop TEST_HOME_PRS_FILE="$(prsjson ticket/ab-9 false '[{"path":"tests/other-test.sh"}]')"; RC=$?
erow E2 clean "$RC"

# E3. a brand-new test file is nobody's shared file (it does not exist at base).
setup; mkrepo new-file
backstop TEST_HOME_PRS_FILE="$(prsjson ticket/ab-9 false '[{"path":"tests/brand-new-test.sh"}]')"; RC=$?
erow E3 clean "$RC"

# E4. our OWN branch is not a sibling — a repair round is the same work.
setup; mkrepo touch-shared
backstop TEST_HOME_PRS_FILE="$(prsjson ticket/ab-1 false '[{"path":"tests/shared-test.sh"}]')"; RC=$?
erow E4 clean "$RC"
setup; mkrepo touch-shared
backstop TEST_HOME_PRS_FILE="$(prsjson ticket/ab-1-r2 false '[{"path":"tests/shared-test.sh"}]')"; RC=$?
erow E4b clean "$RC"

# E5. a draft is not a merge that is coming.
setup; mkrepo touch-shared
backstop TEST_HOME_PRS_FILE="$(prsjson ticket/ab-9 true '[{"path":"tests/shared-test.sh"}]')"; RC=$?
erow E5 clean "$RC"

# E6. no file, no cache, no gh-pr-list lib -> NOT-JUDGED. Never 'clean'.
setup; mkrepo touch-shared
backstop; RC=$?
erow E6 not-judged "$RC"
grep -qF 'could not run' "$B/NOTE.txt" \
  && ok || bad "E6: the note must say the check could not run (got: $(cat "$B/NOTE.txt" 2>/dev/null))"
grep -qF 'TEST-HOME GATE: clean' "$B/NOTE.txt" \
  && bad "E6: a failed check must never read as clean" || ok

# E6-mutation (D1): a block that starts on 'clean' instead of 'not-judged'
# passes E6 silently — the assertion above must catch it.
sed 's/TH_VERDICT=not-judged/TH_VERDICT=clean/' "$T/diff.sh" > "$T/diff.mut.sh"
cmp -s "$T/diff.sh" "$T/diff.mut.sh" \
  && bad "E6m: the mutant is identical — the block never initialises TH_VERDICT=not-judged" || ok
setup; mkrepo touch-shared
cp "$T/diff.sh" "$T/diff.orig.sh"; cp "$T/diff.mut.sh" "$T/diff.sh"
backstop
cp "$T/diff.orig.sh" "$T/diff.sh"
[ "$(verdict)" = 'TEST_HOME_VERDICT: not-judged' ] \
  && bad "E6m: MUTATION NOT CAUGHT — the failure path did not come from TH_VERDICT=not-judged" || ok

# E7. the overlap-guard cache is the cheap source while it is fresh.
setup; mkrepo touch-shared
printf '[{"number":7,"headRefName":"ticket/ab-9","isDraft":false,"files":[{"filename":"tests/shared-test.sh"}]}]\n' \
  > "$H/state/overlap-guard/widget-os-prs.json"
touch -d "@$((NOW-30))" "$H/state/overlap-guard/widget-os-prs.json"
backstop; RC=$?
erow E7 shared "$RC"

# E8. ...and a stale cache is not a source at all.
setup; mkrepo touch-shared
printf '[{"number":7,"headRefName":"ticket/ab-9","isDraft":false,"files":[{"filename":"tests/shared-test.sh"}]}]\n' \
  > "$H/state/overlap-guard/widget-os-prs.json"
touch -d "@$((NOW-900))" "$H/state/overlap-guard/widget-os-prs.json"
backstop; RC=$?
erow E8 not-judged "$RC"

# E9. a plan-time finding from (c) rides into the same note, so the reviewer
#     sees it even when the diff itself came out clean.
setup; mkrepo touch-shared
printf 'SHARED: tests/shared-test.sh -> tests/shared.ab-1-test.sh\nTEST_HOME_PLAN: 1\n' > "$B/test-home.txt"
backstop TEST_HOME_PRS_FILE="$(prsjson ticket/ab-9 false '[{"path":"tests/other-test.sh"}]')"; RC=$?
erow E9 clean "$RC"
grep -qF 'SHARED: tests/shared-test.sh -> tests/shared.ab-1-test.sh' "$B/NOTE.txt" \
  && ok || bad "E9: the plan-time findings must reach GATES_NOTE too"

# E10. a NEAR-MISS key is a real sibling: ab-12 is not ab-1.
setup; mkrepo touch-shared
backstop TEST_HOME_PRS_FILE="$(prsjson ticket/ab-12 false '[{"path":"tests/shared-test.sh"}]')"; RC=$?
erow E10 shared "$RC"

# E11. the cache TTL is the operator's existing knob, not a constant.
setup; mkrepo touch-shared
printf '[{"number":7,"headRefName":"ticket/ab-9","isDraft":false,"files":[{"filename":"tests/shared-test.sh"}]}]\n' \
  > "$H/state/overlap-guard/widget-os-prs.json"
touch -d "@$((NOW-60))" "$H/state/overlap-guard/widget-os-prs.json"
printf 'OVERLAP_PR_CACHE_SECS=30\n' > "$H/flags/scheduler.conf"
backstop; RC=$?
erow E11 not-judged "$RC"
printf 'OVERLAP_PR_CACHE_SECS=600\n' > "$H/flags/scheduler.conf"
backstop; RC=$?
erow E11b shared "$RC"

# E12. a file that exists at the TIP of $BASE but not at the merge base is still
#      a brand-new file for this branch.
setup; mkrepo base-moved
backstop TEST_HOME_PRS_FILE="$(prsjson ticket/ab-9 false '[{"path":"tests/brand-new-test.sh"}]')"; RC=$?
erow E12 clean "$RC"

# E13. no file and no cache: ONE harness_pr_list call, and its output is used.
setup; mkrepo touch-shared
printf '[{"number":7,"headRefName":"ticket/ab-9","isDraft":false,"files":[{"path":"tests/shared-test.sh"}]}]\n' \
  > "$T/prs-live.json"
cat > "$H/bin/lib/gh-pr-list.sh" <<EOF
harness_pr_list() { echo "\$*" >> "$T/prcalls.txt"; cat "$T/prs-live.json"; }
EOF
: > "$T/prcalls.txt"
backstop; RC=$?
erow E13 shared "$RC"
[ -s "$B/test-home-prs.json" ] && ok || bad "E13: the fetched list must be written to \$BUILD/test-home-prs.json"
[ "$(wc -l < "$T/prcalls.txt")" = 1 ] \
  && ok || bad "E13: exactly ONE PR-list call per build (got $(wc -l < "$T/prcalls.txt"))"
grep -qF 'owner/repo open number,headRefName,isDraft,files' "$T/prcalls.txt" \
  && ok || bad "E13: the call must ask for the fields the projection reads (got: $(cat "$T/prcalls.txt"))"
cat "$VIOL" >> "$FVIOL"

# ============================================================================
# F. the new blocks add no lock, no wait and no model call
# ============================================================================
# The stubs above record any flock/sleep/CC call made by the production blocks
# in B1, C1, E1 and E13 — the rows that exercise every path that could add one.
[ "$(grep -Ec 'FLOCK|SLEEP|CCCALL' "$FVIOL")" = 0 ] \
  && ok || bad "F: the new blocks must add no lock, no sleep and no model call (got: $(cat "$FVIOL"))"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
