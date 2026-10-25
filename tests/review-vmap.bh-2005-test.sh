#!/bin/bash
# tests/review-vmap.bh-2005-test.sh — BH-2005.2 (built as BH-2036): the review
# stage hands the general lens the "What usually lies" bullets of the
# verification-map entries that cover this ticket's QA screens.
#
# The `# >>> vmap lies` block is extracted VERBATIM from the flattened pipeline
# ($RB_ALL, tests/lib/rb-all.sh) and run the way tests/evidence-gate-test.sh
# runs the evidence block: cwd is a scratch build worktree holding a fixture
# map, HARNESS is a scratch harness holding the REAL bin/lib/vmap-entry.sh (or
# not, for the lib-absent case). Assertions are on GATES_NOTE, pipeline.log,
# RESULT and REVIEW_TIER after the block ran.
#
#   A  match     -> `WHAT USUALLY LIES (verification map):` + the bullet
#   B  no match  -> `... no map entry for this ticket's screens (note only)`
#   C  empty map -> `WHAT USUALLY LIES: none in this repo`
#   D  no lib    -> `WHAT USUALLY LIES: could not run (lib absent)`
#   E  matched entries with no bullets say so, never an empty instruction
#   every case: rc 0, no RESULT, REVIEW_TIER still 2, one `VMAP LIES:` log line
#   SOURCE PINS (stated as pins): marker order, VMAP_NOTE in the header's
#   `# Reads:` / `# Writes:` lists of bin/lib/rb/review.sh, and the block in
#   bin/lib/rb/review.sh byte-identical to the live one. The review stage still
#   runs inline in bin/run-build.sh; review.sh is BH-478's dark twin of it, so
#   the block ships in both until the cutover and `cmp` holds them together.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-vmap.bh-2005-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "${RB_REPO:-$DIR}" "$T/run-build.all.sh") || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> vmap lies/{f=1;next} /^# <<< vmap lies/{exit} f' "$RB_ALL" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok || bad "could not extract '# >>> vmap lies' from the pipeline — markers missing?"

mkdir -p "$T/h/bin/lib" "$T/nolib/bin"
cp "$DIR/bin/lib/vmap-entry.sh" "$T/h/bin/lib/vmap-entry.sh"

wt() { # wt <name> -> a scratch build worktree with an empty map dir
  local w="$T/wt-$1"; mkdir -p "$w/docs/verification-map"; printf '%s' "$w"
}
LIES_ENTRY='# Clients

**Key routes/screens:**
- `/clients/[id]`

**What usually lies:**
- the balance column reads a stale cache after an edit
'

run_block() { # run_block <worktree> <harness> <qa-screen> -> prints rc
  local w="$1" h="$2" s="$3"
  rm -rf "$T/build"; mkdir -p "$T/build"
  [ -n "$s" ] && printf '# plan\n\n## QA screens\n- `%s`\n' "$s" > "$T/build/plan.md"
  ( cd "$w" && env HARNESS="$h" BUILD="$T/build" PROJECT=p KEY=K GATES_NOTE="PRIOR" REVIEW_TIER=2 \
      bash -c 'set -uo pipefail
               STAMP() { echo TS; }
               RESULT() { echo "$*" > "$BUILD/RESULT"; }
               . "$0"
               printf "%s" "$GATES_NOTE" > "$BUILD/NOTE.txt"
               printf "%s" "$REVIEW_TIER" > "$BUILD/TIER.txt"' "$T/block.sh" >/dev/null 2>&1 )
  echo $?
}
note() { cat "$T/build/NOTE.txt" 2>/dev/null; }
invariants() { # invariants <case> <rc>
  [ "$2" = 0 ] && ok || bad "$1: the block must exit 0 (got $2)"
  [ ! -e "$T/build/RESULT" ] && ok || bad "$1: the block must never write a RESULT ($(cat "$T/build/RESULT"))"
  [ "$(cat "$T/build/TIER.txt" 2>/dev/null)" = 2 ] && ok || bad "$1: REVIEW_TIER must stay 2 (got [$(cat "$T/build/TIER.txt" 2>/dev/null)])"
  [ "$(grep -c 'VMAP LIES:' "$T/build/pipeline.log" 2>/dev/null)" = 1 ] && ok \
    || bad "$1: exactly one VMAP LIES line in pipeline.log (got: $(cat "$T/build/pipeline.log" 2>/dev/null))"
  case "$(note)" in PRIOR$'\n'*) ok ;; *) bad "$1: GATES_NOTE must be appended to, not replaced (got [$(note)])" ;; esac
}

# A. match
W=$(wt a); printf '%s' "$LIES_ENTRY" > "$W/docs/verification-map/clients.md"
RC=$(run_block "$W" "$T/h" /clients/42)
invariants A "$RC"
grep -qxF "WHAT USUALLY LIES (verification map): check each bullet against this PR's evidence (screenshots, qa report, tests); a bullet the evidence cannot rule out is a finding" <<<"$(note)" && ok || bad "A: instruction line must be the ticket's sentence verbatim (got [$(note)])"
grep -qF -- '- the balance column reads a stale cache after an edit' <<<"$(note)" && ok || bad "A: bullet missing (got [$(note)])"
grep -q 'VMAP LIES: .*(1 bullets)' "$T/build/pipeline.log" && ok || bad "A: log line must count 1 bullet ($(cat "$T/build/pipeline.log"))"

# B. no match
RC=$(run_block "$W" "$T/h" /billing)
invariants B "$RC"
grep -qxF "WHAT USUALLY LIES: no map entry for this ticket's screens (note only)" <<<"$(note)" && ok || bad "B: got [$(note)]"

# C. empty map
W=$(wt c)
RC=$(run_block "$W" "$T/h" /clients/42)
invariants C "$RC"
grep -qxF 'WHAT USUALLY LIES: none in this repo' <<<"$(note)" && ok || bad "C: got [$(note)]"

# D. no lib
W=$(wt d); printf '%s' "$LIES_ENTRY" > "$W/docs/verification-map/clients.md"
RC=$(run_block "$W" "$T/nolib" /clients/42)
invariants D "$RC"
grep -qxF 'WHAT USUALLY LIES: could not run (lib absent)' <<<"$(note)" && ok || bad "D: got [$(note)]"

# E. matched entry, no bullets
W=$(wt e); printf '**Key routes/screens:**\n- `/clients/[id]`\n' > "$W/docs/verification-map/clients.md"
RC=$(run_block "$W" "$T/h" /clients/42)
invariants E "$RC"
grep -qxF "WHAT USUALLY LIES: matched entries carry no 'What usually lies' bullets (note only)" <<<"$(note)" && ok || bad "E: got [$(note)]"

# SOURCE PIN: the block sits after the evidence verdicts and before REVIEW_PROMPT=,
# so GATES_NOTE carries it into the prompt. Absent markers fail, never pass.
lineof() { grep -a -n -m1 "^$1" "$RB_ALL" | cut -d: -f1; }
# TEST-CHANGE (BH-7970): REVIEW_PROMPT is rendered by sp_render inside the '# >>> review prompt' block, so that block is the order pin's anchor.
L_EV=$(lineof '# <<< evidence verdicts'); L_VM=$(lineof '# >>> vmap lies'); L_RP=$(lineof '# >>> review prompt')
if [ -n "$L_EV" ] && [ -n "$L_VM" ] && [ -n "$L_RP" ] && [ "$L_EV" -lt "$L_VM" ] && [ "$L_VM" -lt "$L_RP" ]; then ok
else bad "PIN: '# >>> vmap lies' ($L_VM) must sit after '# <<< evidence verdicts' ($L_EV) and before the '# >>> review prompt' block ($L_RP)"; fi

# SOURCE PIN: the header's variable lists name VMAP_NOTE.
REV="${RB_REPO:-$DIR}/bin/lib/rb/review.sh"
for H in Reads Writes; do
  awk -v h="# $H:" 'index($0,h)==1{on=1; print; next} on && /^#   /{print; next} {on=0}' "$REV" | grep -qw VMAP_NOTE \
    && ok || bad "PIN: the '# $H:' header list of bin/lib/rb/review.sh must name VMAP_NOTE"
done

# SOURCE PIN: the dark twin in bin/lib/rb/review.sh carries the same bytes.
awk '/^# >>> vmap lies/{f=1;next} /^# <<< vmap lies/{exit} f' "$REV" > "$T/twin.sh"
[ -s "$T/twin.sh" ] && cmp -s "$T/block.sh" "$T/twin.sh" && ok \
  || bad "PIN: the '# >>> vmap lies' block in bin/lib/rb/review.sh must be byte-identical to the one in the pipeline"

echo "review-vmap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
