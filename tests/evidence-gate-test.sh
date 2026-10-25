#!/bin/bash
# tests/evidence-gate-test.sh — the run-build.sh WIRING for the acceptance-claim
# evidence contract (#547, parent #527).
#
# The contract itself (bin/lib/evidence.sh: the evidence.json schema, the three
# verdict words, evidence_score / evidence_counts) is tested next door in
# tests/evidence-contract-test.sh. What is tested HERE is the two places
# bin/run-build.sh calls it and what those calls are wired to:
#
#   # >>> evidence verdicts   inside the review lenses, after HARNESS-VERIFY —
#                             the rows have to reach REVIEW_PROMPT, and the
#                             block must never exit, never write a RESULT.
#   # >>> evidence demoter    after head-bound approval, before evidence settle
#                             — the warn-first tier demoter behind
#                             EVIDENCE_GATE_ENFORCE.
#
# WHY DRIVEN, NOT GREPPED: `grep -q evidence_score bin/run-build.sh` passes just
# as happily on a version that scores the build and then drops the rows on the
# floor, or on one that demotes with the knob switched off. Both blocks are
# extracted VERBATIM by their markers and run, and §B drives the WHOLE
# review-lens block so the assertion is on the prompt string a reviewer would
# actually have received. The two exceptions are labelled SOURCE PIN: a prompt
# line that is never handed to a stub (the execute prompt) and the marker
# ORDER in the file, both guarded so an absent string fails rather than passes.
#
# The real scorer is another child's job, so this suite ships its own stub lib
# at $T/bin/lib/evidence.sh (selected by EV_CASE) implementing the contract's
# signatures — mixed = 1 CONFIRMED / 1 REFUTED / 1 INCONCLUSIVE, allok = 2
# CONFIRMED, zero = no claims, fail = a scorer that could not run.
#
# Run from anywhere: bash tests/evidence-gate-test.sh   (exit 0 = all pass)
# RUN_BUILD=<path> drives a different copy of the (flattened) script (used to prove red).
set -uo pipefail
if [ -f "$(dirname "$0")/lib/scratch.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/scratch.sh" || exit 1
else
  # tests/lib/scratch.sh is BH-459's file and is not on this branch yet; until it
  # lands, the same scratch dir + trap the lib hands out, inline.
  T=$(mktemp -d "${TMPDIR:-/tmp}/scratch.XXXXXX") || exit 1
  trap 'rm -rf "$T"' EXIT
fi
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# The pipeline as ONE text (tests/lib/rb-all.sh): since the BH-572 cut every
# block this suite extracts lives in a stage module under bin/lib/rb/, and the
# flatten puts each body back where the driver calls it.
if [ -z "${RUN_BUILD:-}" ]; then
  . "$DIR/tests/lib/rb-all.sh" || exit 1
  RUN_BUILD=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten bin/run-build.sh"; exit 1; }
fi
SCRIPT="$RUN_BUILD"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# jq is the scorer's whole output format, so a box without it cannot run this
# suite. Said out loud: a skip here would read as a pass for the gate.
command -v jq >/dev/null 2>&1 || { echo "evidence-gate: jq is required to run this suite"; exit 1; }
[ -s "$SCRIPT" ] || { echo "evidence-gate: no run-build.sh at $SCRIPT"; exit 1; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/nolib/bin"
ALERTS_LOG="$T/logs/ALERTS.log"
: > "$ALERTS_LOG"

# findings-log.sh is called once per lens in §B and must never fail a build.
printf '#!/bin/bash\nexit 0\n' > "$T/bin/findings-log.sh"; chmod +x "$T/bin/findings-log.sh"

# ── the stub contract lib ───────────────────────────────────────────────────
# Same signatures as bin/lib/evidence.sh, canned verdicts chosen by EV_CASE.
cat > "$T/bin/lib/evidence.sh" <<'STUBLIB'
evidence_score() { # evidence_score <build> <plan> <base> <repo-dir>
  local build="${1:-}" tmp
  if [ "${EV_CASE:-mixed}" = fail ]; then
    printf 'EVIDENCE VERDICTS: could not run (jq missing)\n'; return 1
  fi
  tmp="$build/evidence.json.stub"
  case "${EV_CASE:-mixed}" in
    allok) jq -n '{total:2,confirmed:2,refuted:0,inconclusive:0,claims:[
             {n:1,claim:"the gate demotes",verdict:"CONFIRMED",artifact:"validate.txt:12",note:"suite ran green"},
             {n:2,claim:"the note is written",verdict:"CONFIRMED",artifact:"validate.txt:30",note:"suite ran green"}]}' > "$tmp" || return 1 ;;
    zero)  jq -n '{total:0,confirmed:0,refuted:0,inconclusive:0,claims:[]}' > "$tmp" || return 1 ;;
    *)     jq -n '{total:3,confirmed:1,refuted:1,inconclusive:1,claims:[
             {n:1,claim:"the rows reach the prompt",verdict:"CONFIRMED",artifact:"validate.txt:12",note:"suite ran green"},
             {n:2,claim:"the demoter demotes",verdict:"REFUTED",artifact:"",note:"no test drives it"},
             {n:3,claim:"the doc matches",verdict:"INCONCLUSIVE",artifact:"validate.txt:44",note:"command not recorded"}]}' > "$tmp" || return 1 ;;
  esac
  mv -f "$tmp" "$build/evidence.json" || return 1
  jq -r '.claims[]? | "CLAIM \(.n): \(.verdict) :: \(.artifact) :: \(.note)"' "$build/evidence.json"
  return 0
}
evidence_counts() { # evidence_counts <build>
  local build="${1:-}" out
  out=$(jq -r '"confirmed=\(.confirmed) refuted=\(.refuted) inconclusive=\(.inconclusive) total=\(.total)"' \
        "$build/evidence.json" 2>/dev/null)
  [ -n "$out" ] || { printf 'not-recorded\n'; return 0; }
  printf '%s\n' "$out"
  return 0
}
STUBLIB

# ============================================================================
# A. # >>> evidence verdicts — the rows land in GATES_NOTE, and the block is
#    incapable of stopping a build
# ============================================================================
awk '/^# >>> evidence verdicts/{f=1;next} /^# <<< evidence verdicts/{exit} f' \
  "$SCRIPT" > "$T/verdicts.sh"
[ -s "$T/verdicts.sh" ] && ok \
  || bad "could not extract the '# >>> evidence verdicts' block from $SCRIPT — markers missing?"

verdicts_run() { # verdicts_run <harness> [env...] -> prints the block's exit code
  local h="$1"; shift
  rm -rf "$T/vbuild"; mkdir -p "$T/vbuild"
  ( env HARNESS="$h" BUILD="$T/vbuild" PROJECT=p KEY=K BASE=main \
        ALERTS="$ALERTS_LOG" GATES_NOTE="" "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "$*" > "$BUILD/RESULT"; }
             . "$0"
             printf "%s" "$GATES_NOTE" > "$BUILD/NOTE.txt"' "$T/verdicts.sh" >/dev/null 2>&1 )
  echo $?
}
vnote() { cat "$T/vbuild/NOTE.txt" 2>/dev/null; }

# A1. the lib is there: the verdict rows ride into GATES_NOTE, which is the one
#     variable REVIEW_PROMPT interpolates, and the scorer's stdout is teed to
#     the file the settle render and an operator read.
RC=$(verdicts_run "$T")
[ "$RC" = 0 ] && ok || bad "A1 the verdicts block must exit 0 (got $RC)"
grep -q 'CLAIM 2: REFUTED' <<<"$(vnote)" && ok \
  || bad "A1 GATES_NOTE must carry the scorer's CLAIM rows (got: [$(vnote)])"
grep -q 'EVIDENCE VERDICTS:' <<<"$(vnote)" && ok \
  || bad "A1 GATES_NOTE must label the rows EVIDENCE VERDICTS (got: [$(vnote)])"
grep -q 'CLAIM 2: REFUTED' "$T/vbuild/evidence-verdicts.txt" 2>/dev/null && ok \
  || bad "A1 the scorer's stdout must be teed to \$BUILD/evidence-verdicts.txt"
[ -f "$T/vbuild/evidence.json" ] && ok || bad "A1 the scorer must have written evidence.json"
[ ! -f "$T/vbuild/RESULT" ] && ok || bad "A1 the verdicts block must never write a RESULT"
grep -q 'EVIDENCE VERDICTS: scored' "$T/vbuild/pipeline.log" 2>/dev/null && ok \
  || bad "A1 pipeline.log must record that the scoring ran"

# A2. no lib (a box mid-sync): one honest line, no artifacts, no terminal.
RC=$(verdicts_run "$T/nolib")
[ "$RC" = 0 ] && ok || bad "A2 a missing contract lib must not fail the block (got $RC)"
grep -q 'could not run' <<<"$(vnote)" && ok \
  || bad "A2 GATES_NOTE must say the scoring could not run (got: [$(vnote)])"
[ ! -f "$T/vbuild/evidence.json" ] && ok \
  || bad "A2 no lib means no evidence.json — an un-scored build must not look scored"
[ ! -f "$T/vbuild/RESULT" ] && ok || bad "A2 a missing lib must never write a RESULT"
grep -q 'EVIDENCE VERDICTS: could not run (lib absent)' "$T/vbuild/pipeline.log" 2>/dev/null && ok \
  || bad "A2 pipeline.log must record the absent lib"

# A3. the scorer itself fails (no jq on the box): its one line still reaches the
#     reviewer, and nothing claims a score.
RC=$(verdicts_run "$T" EV_CASE=fail)
[ "$RC" = 0 ] && ok || bad "A3 a failing scorer must not fail the block (got $RC)"
grep -q 'could not run (jq missing)' <<<"$(vnote)" && ok \
  || bad "A3 the scorer's own failure line must reach GATES_NOTE (got: [$(vnote)])"
[ ! -f "$T/vbuild/evidence.json" ] && ok || bad "A3 a failed score must leave no evidence.json"
[ ! -f "$T/vbuild/RESULT" ] && ok || bad "A3 a failed score must never write a RESULT"

# ============================================================================
# B. Prompt carriage — the WHOLE review-lens block, with a stub reviewer that
#    dumps the prompt it was handed
# ============================================================================
awk '/^# >>> review lenses/{f=1;next} /^# <<< review lenses/{exit} f' \
  "$SCRIPT" > "$T/lenses.sh"
[ -s "$T/lenses.sh" ] && ok || bad "could not extract the review-lens block — markers missing?"

REPO="$T/repo"
setup_repo() { # setup_repo <file>...  — the file NAMES decide which lenses run
  rm -rf "$T/repo"; mkdir -p "$REPO"   # $T-owned, spelled out: checks/tests-scratch-only R2
  ( cd "$REPO" || exit 1
    git init -q -b main
    git config user.email t@example.com; git config user.name tester
    echo base > README.md
    git add -A; git -c commit.gpgsign=false commit -qm base
    git checkout -q -b feat
    for f in "$@"; do mkdir -p "$(dirname "$f")"; echo x >> "$f"; done
    git add -A; git -c commit.gpgsign=false commit -qm work ) >/dev/null 2>&1
}

lenses_run() { # lenses_run <harness> — drives the block; each lens's prompt is dumped
  rm -rf "$T/build"; mkdir -p "$T/build"
  rm -f "$T/p-review.txt" "$T/p-security.txt" "$T/p-refute.txt"
  # TEST-CHANGE (BH-7970): the block sources $HARNESS/bin/lib/stage-prompt.sh and renders prompts/stages/review.md; the scratch harness carries both, as a synced box does.
  mkdir -p "$1/bin/lib" "$1/prompts/stages"
  scratch_install_closure bin/lib/stage-prompt.sh "$1" >/dev/null || bad "B: could not install bin/lib/stage-prompt.sh into the scratch harness"; cp "$DIR"/prompts/stages/*.md "$1/prompts/stages/"
  ( cd "$REPO" || exit 1
    env HARNESS="$1" BUILD="$T/build" PROJECT=p KEY=K BASE=main BRANCH=feat \
        REVIEW_MODEL=rm FIX_MODEL=fm REOPEN_HOT=0 REOPEN_NOTE="" \
        KIND_SKIP_SECLENS=0 REOPEN_EXTRA_LENS=0 GATES_NOTE="" \
        SPEC_DIR=.harness/specs ALERTS="$ALERTS_LOG" PDIR="$T" \
      bash -c '
        set -uo pipefail
        STAMP() { echo TS; }
        RESULT() { echo "$*" > "$BUILD/RESULT"; }
        BB() { :; }
        PUSH_BRANCH() { :; }
        # The stubbed reviewer: it records the prompt it was given and writes
        # the artifact its lens would have written, APPROVEd, so the block runs
        # to the end without buying a fix round.
        CC() {
          local out="$4" prompt="$5"
          case "$(basename "$out")" in
            review-run.txt)
              printf "%s" "$prompt" > "$PDIR/p-review.txt"
              printf "no findings\nTIER: 1\nVERDICT: APPROVE\n" > "$BUILD/review.md" ;;
            security-review-run.txt)
              printf "%s" "$prompt" > "$PDIR/p-security.txt"
              printf "no findings\nVERDICT: APPROVE\n" > "$BUILD/security-review.md" ;;
            refute-review-run.txt)
              printf "%s" "$prompt" > "$PDIR/p-refute.txt"
              printf "could not refute\nVERDICT: APPROVE\n" > "$BUILD/refute-review.md" ;;
          esac
        }
        . "$0"' "$T/lenses.sh" >/dev/null 2>&1 )
  echo $?
}

# B1. a plain diff (one lens): the verdict rows reach the reviewer's prompt, and
#     so does the instruction telling it what to do with them.
setup_repo docs/NOTES.md
RC=$(lenses_run "$T")
[ "$RC" = 0 ] && ok || bad "B1 the lens block must run to the end on an APPROVEd diff (got $RC)"
[ -s "$T/p-review.txt" ] && ok || bad "B1 the general lens was never handed a prompt"
grep -q 'CLAIM 2: REFUTED' "$T/p-review.txt" 2>/dev/null && ok \
  || bad "B1 the review prompt must carry the scored CLAIM rows"
grep -q 'EVIDENCE VERDICTS: for every CONFIRMED row' "$T/p-review.txt" 2>/dev/null && ok \
  || bad "B1 the review prompt must carry the EVIDENCE VERDICTS instruction paragraph"
grep -q 'FRAUD: false-completion' "$T/p-review.txt" 2>/dev/null && ok \
  || bad "B1 the instruction must name the fraud class for a CONFIRMED whose artifact does not match"
grep -q 'a REFUTED row is a BLOCK unless the diff explains it' "$T/p-review.txt" 2>/dev/null && ok \
  || bad "B1 the instruction must say what a REFUTED row means"
grep -q 'INCONCLUSIVE' "$T/p-review.txt" 2>/dev/null && ok \
  || bad "B1 the instruction must say what to do with an INCONCLUSIVE row"

# B2. the other two lenses are UNCHANGED. They never receive GATES_NOTE (same as
#     the tamper, repro and intent gates), and this ticket did not change that:
#     a diff that earns all three must leave the security and refuter prompts
#     without a single evidence row in them.
setup_repo prisma/schema.prisma
RC=$(lenses_run "$T")
[ "$RC" = 0 ] && ok || bad "B2 the three-lens diff must run to the end (got $RC)"
{ [ -s "$T/p-security.txt" ] && [ -s "$T/p-refute.txt" ]; } && ok \
  || bad "B2 a schema diff must buy the security and refuter lenses — they were not called"
grep -q 'EVIDENCE VERDICTS' "$T/p-security.txt" 2>/dev/null \
  && bad "B2 SECURITY_PROMPT must not gain the evidence paragraph" || ok
grep -q 'CLAIM 2' "$T/p-security.txt" 2>/dev/null \
  && bad "B2 SECURITY_PROMPT must not carry the evidence rows" || ok
grep -q 'EVIDENCE VERDICTS' "$T/p-refute.txt" 2>/dev/null \
  && bad "B2 REFUTE_PROMPT must not gain the evidence paragraph" || ok
grep -q 'CLAIM 2' "$T/p-refute.txt" 2>/dev/null \
  && bad "B2 REFUTE_PROMPT must not carry the evidence rows" || ok
# ...and the review prompt on THIS diff still carries them.
grep -q 'CLAIM 2: REFUTED' "$T/p-review.txt" 2>/dev/null && ok \
  || bad "B2 the general lens lost its evidence rows on a three-lens diff"

# B3. no contract lib in $HARNESS (the shape tests/parallel-lenses-test.sh runs
#     in): the prompt says so and the block still completes.
setup_repo docs/NOTES.md
RC=$(lenses_run "$T/nolib")
[ "$RC" = 0 ] && ok || bad "B3 a lens block with no contract lib must still complete (got $RC)"
grep -q 'EVIDENCE VERDICTS: could not run (lib absent)' "$T/p-review.txt" 2>/dev/null && ok \
  || bad "B3 the reviewer must be told the evidence could not be scored"

# B4. SOURCE PIN (stated as such): the execute prompt is a string handed to a
#     real model and no stub in this repo ever receives it, so the only way to
#     pin it is to read the line. Guarded: an absent line fails every assertion
#     below rather than passing them vacuously.
EXEC_LINE=$(grep -a -m1 'CC execute "\$EXECUTE_MODEL"' "$SCRIPT")
[ -n "$EXEC_LINE" ] && ok \
  || bad "B4 could not find the 'CC execute' prompt line in $SCRIPT — the pin below proves nothing"
# TEST-CHANGE (BH-7970): the execute prompt text moved to prompts/stages/execute.md (the CC line now passes the rendered "$SP_PROMPT_EXECUTE"); the pins below read the template, guarded the same way.
grep -q 'SP_PROMPT_EXECUTE' <<<"$EXEC_LINE" && [ -s "$DIR/prompts/stages/execute.md" ] && ok \
  || bad "B4 the 'CC execute' line must send the rendered prompts/stages/execute.md — the pin below proves nothing"
EXEC_LINE=$(cat "$DIR/prompts/stages/execute.md" 2>/dev/null)
grep -q 'evidence-proposed.txt' <<<"$EXEC_LINE" && ok \
  || bad "B4 the execute prompt must ask the builder to write evidence-proposed.txt"
grep -q 'REFUTED by definition' <<<"$EXEC_LINE" && ok \
  || bad "B4 the execute prompt must say that asserting without running is REFUTED by definition"
grep -q 'CONFIRMED|REFUTED|INCONCLUSIVE' <<<"$EXEC_LINE" && ok \
  || bad "B4 the execute prompt must give the verdict vocabulary for a proposed line"

# ============================================================================
# C. # >>> evidence demoter — warn-first, and every way it must NOT demote
# ============================================================================
awk '/^# >>> evidence demoter/{f=1;next} /^# <<< evidence demoter/{exit} f' \
  "$SCRIPT" > "$T/demoter.sh"
[ -s "$T/demoter.sh" ] && ok \
  || bad "could not extract the '# >>> evidence demoter' block from $SCRIPT — markers missing?"

demote() { # demote <harness> <tier-in> [env...] -> "TIER=<n>|NOTE=<note>"
  local h="$1" tier="$2"; shift 2
  rm -rf "$T/dbuild"; mkdir -p "$T/dbuild"
  ( env HARNESS="$h" BUILD="$T/dbuild" PROJECT=p KEY=K BASE=main \
        TIER="$tier" QA_NOTE="" ALERTS="$ALERTS_LOG" "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             . "$0"
             printf "TIER=%s|NOTE=%s\n" "$TIER" "$QA_NOTE"' "$T/demoter.sh" 2>/dev/null )
}
dlog() { cat "$T/dbuild/pipeline.log" 2>/dev/null; }

# C1. warn-first is the SHIPPED default: the tier stands, the reason is still
#     written where RESULT, the PR body and the verdict row pick it up.
OUT=$(demote "$T" 1)
grep -q '^TIER=1' <<<"$OUT" && ok || bad "C1 the shipped default must not demote (got: $OUT)"
grep -q 'EVIDENCE_GATE_ENFORCE=0, warn only' <<<"$OUT" && ok \
  || bad "C1 a warn-only run must say so in the note (got: $OUT)"
grep -q 'EVIDENCE: 1 refuted, 1 inconclusive of 3 acceptance claims' <<<"$OUT" && ok \
  || bad "C1 the note must carry the counts (got: $OUT)"
grep -q 'EVIDENCE confirmed=1 refuted=1 inconclusive=1 total=3' <<<"$(dlog)" && ok \
  || bad "C1 every scored run must write the EVIDENCE counts line to pipeline.log (got: [$(dlog)])"
grep -q 'CLAIM 2: REFUTED' "$T/dbuild/evidence-verdicts.txt" 2>/dev/null && ok \
  || bad "C1 the demoter must re-score the settled head into evidence-verdicts.txt"

# C2. armed, the same build demotes and says why — on every spelling of ON.
for ON in 1 true YES on; do
  OUT=$(demote "$T" 1 EVIDENCE_GATE_ENFORCE="$ON")
  grep -q '^TIER=2' <<<"$OUT" || bad "C2 EVIDENCE_GATE_ENFORCE=$ON must arm the demotion (got: $OUT)"
  # TEST-CHANGE(BH-4581): wording only, tier logic unchanged
  grep -q 'recorded tier-2 (risk signal)' <<<"$OUT" || bad "C2 the demotion must say it demoted (got: $OUT)"
done
ok

# C3. armed on a build already at tier 2: the note still rides (it is the one
#     fact the merge sweep's reader needs) and says the tier was already there.
OUT=$(demote "$T" 2 EVIDENCE_GATE_ENFORCE=1)
grep -q '^TIER=2' <<<"$OUT" && ok || bad "C3 a tier-2 build must stay tier-2 (got: $OUT)"
grep -q 'already tier-2' <<<"$OUT" && ok \
  || bad "C3 the note must say the build was already tier-2 (got: $OUT)"
# TEST-CHANGE(BH-4581): wording only, tier logic unchanged
grep -q 'recorded tier-2 (risk signal)' <<<"$OUT" \
  && bad "C3 a build already at tier 2 must not claim a demotion (got: $OUT)" || ok

# C4. an unrecognised knob value is OFF and SAYS SO. A `banana` that silently
#     meant ON would arm a gate nobody armed; one that silently meant OFF is the
#     never-fires shape. Exactly one ALERTS line.
: > "$ALERTS_LOG"
OUT=$(demote "$T" 1 EVIDENCE_GATE_ENFORCE=banana)
grep -q '^TIER=1' <<<"$OUT" && ok || bad "C4 an unrecognised knob value must be OFF (got: $OUT)"
[ "$(grep -c 'EVIDENCE_GATE_ENFORCE' "$ALERTS_LOG" 2>/dev/null)" = 1 ] && ok \
  || bad "C4 an unrecognised knob value must write exactly one ALERTS line (got $(grep -c 'EVIDENCE_GATE_ENFORCE' "$ALERTS_LOG" 2>/dev/null))"
grep -q 'treating as OFF' "$ALERTS_LOG" 2>/dev/null && ok \
  || bad "C4 the ALERTS line must say the gate is being treated as OFF"
: > "$ALERTS_LOG"

# C5. NEGATIVE: every claim CONFIRMED must not annotate and must not demote,
#     armed or not. A gate that notes a clean build teaches nobody anything.
for ARM in 0 1; do
  OUT=$(demote "$T" 1 EV_CASE=allok EVIDENCE_GATE_ENFORCE="$ARM")
  grep -q '^TIER=1|NOTE=$' <<<"$OUT" \
    || bad "C5 an all-CONFIRMED build must not be annotated or demoted (ENFORCE=$ARM, got: $OUT)"
done
ok
grep -q 'EVIDENCE confirmed=2 refuted=0 inconclusive=0 total=2' <<<"$(dlog)" && ok \
  || bad "C5 a clean score still writes its counts line (got: [$(dlog)])"

# C6. NEGATIVE: total=0 (a plan with no acceptance claims, or a scorer that
#     found none) is not a failing build. No note, no demotion.
OUT=$(demote "$T" 1 EV_CASE=zero EVIDENCE_GATE_ENFORCE=1)
grep -q '^TIER=1|NOTE=$' <<<"$OUT" && ok \
  || bad "C6 total=0 must not be read as a refuted claim (got: $OUT)"

# C7. NEGATIVE: no contract lib. The tier is untouched, nothing is claimed, and
#     pipeline.log says which of the two it was.
OUT=$(demote "$T/nolib" 1 EVIDENCE_GATE_ENFORCE=1)
grep -q '^TIER=1|NOTE=$' <<<"$OUT" && ok \
  || bad "C7 a missing contract lib must never move the tier (got: $OUT)"
grep -q 'EVIDENCE: could not run (lib absent)' <<<"$(dlog)" && ok \
  || bad "C7 pipeline.log must record the absent lib (got: [$(dlog)])"
grep -q 'EVIDENCE confirmed=' <<<"$(dlog)" \
  && bad "C7 a build with no lib must not print a counts line (got: [$(dlog)])" || ok

# C8. NEGATIVE: the scorer ran and failed, so there are no counts. `not-recorded`
#     is not zero refutations — no note, no demotion, and the record says so.
OUT=$(demote "$T" 1 EV_CASE=fail EVIDENCE_GATE_ENFORCE=1)
grep -q '^TIER=1|NOTE=$' <<<"$OUT" && ok \
  || bad "C8 an unscored build must never be demoted on counts it does not have (got: $OUT)"
grep -q 'EVIDENCE not-recorded' <<<"$(dlog)" && ok \
  || bad "C8 pipeline.log must record that nothing was scored (got: [$(dlog)])"

# ============================================================================
# D. SOURCE PIN (stated as such): WHERE the two blocks sit. Both placements are
#    load-bearing and neither is visible in a driven run — the verdicts block
#    has to be inside the lens block to reach REVIEW_PROMPT, and the demoter has
#    to run after the head-bound gate (so it scores the head that merges) and
#    before the settle render (so the PR body carries the tier it left).
# ============================================================================
lineof() { grep -a -n -m1 "^$1" "$SCRIPT" | cut -d: -f1; }
L_LENS_OPEN=$(lineof '# >>> review lenses')
L_LENS_CLOSE=$(lineof '# <<< review lenses')
L_VERDICTS=$(lineof '# >>> evidence verdicts')
L_HB_CLOSE=$(lineof '# <<< head-bound approval')
L_DEMOTER=$(lineof '# >>> evidence demoter')
L_SETTLE=$(lineof '# >>> evidence settle')
numeric() { case "${2:-}" in ''|*[!0-9]*) bad "D marker '$1' is missing from $SCRIPT — this pin proves nothing without it"; return 1 ;; esac; }
numeric '# >>> review lenses'          "$L_LENS_OPEN"
numeric '# <<< review lenses'          "$L_LENS_CLOSE"
numeric '# >>> evidence verdicts'      "$L_VERDICTS"
numeric '# <<< head-bound approval'    "$L_HB_CLOSE"
numeric '# >>> evidence demoter'       "$L_DEMOTER"
numeric '# >>> evidence settle'        "$L_SETTLE"
{ [ "${L_VERDICTS:-0}" -gt "${L_LENS_OPEN:-0}" ] && [ "${L_VERDICTS:-0}" -lt "${L_LENS_CLOSE:-0}" ]; } && ok \
  || bad "D the evidence-verdicts block must sit INSIDE the review-lens block, or its rows never reach REVIEW_PROMPT"
{ [ "${L_DEMOTER:-0}" -gt "${L_HB_CLOSE:-0}" ] && [ "${L_DEMOTER:-0}" -lt "${L_SETTLE:-0}" ]; } && ok \
  || bad "D the evidence demoter must sit between '# <<< head-bound approval' and '# >>> evidence settle'"

echo "evidence-gate: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
