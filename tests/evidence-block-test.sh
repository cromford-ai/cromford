#!/bin/bash
# tests/evidence-block-test.sh — SDLC item 2: the PR says what actually ran.
#
# The hole this closes: the PR body's entire verification section was
# "validate.txt (4812B), red.txt (212B)". the operator merges tier-2 PRs from that page,
# so the harness was asking a human to take its word for checks it never showed
# — the claim-discipline rule it enforces on every agent it runs, broken by the
# thing enforcing it.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q evidence-summary bin/run-build.sh` passes
# just as happily on a renderer that reports a PASS it never saw, on a block
# that never reaches the body, and on a settle pass that leaves the body
# claiming tier 1 while the evidence says tier 2. What is under test is what the
# block SAYS for a given set of build files, and that the two render points
# (PR-open, tier-settled) actually put it where a human and the ledger read it.
#
# The run-build.sh blocks are extracted VERBATIM by their markers, so a
# regression in the shipped lines fails here rather than in a paraphrase.
# No network, no model call, no secrets.
# Run from anywhere: tests/evidence-block-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin" "$T/logs" "$T/flags" "$T/fakebin" "$T/build"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

EV="$DIR/bin/evidence-summary.sh"
[ -x "$EV" ] && ok || bad "bin/evidence-summary.sh is missing or not executable"

# ============================================================================
# 1. the renderer: what it says about a build that went WELL
# ============================================================================
B="$T/rec-ok"
mkdir -p "$B/qa-shots"
printf 'suite output\nHARNESS_EXIT: 0\n' > "$B/harness-suite.txt"
printf '{"tamper":0,"repro":0,"intent":0,"e2e":"pass","migration":"none"}\n' > "$B/gates.json"
printf 'INTENT DECLARED:\n  [agree] INTENT: src/lib/pay.ts:42 :: agree\nINTENT_VERDICT: declared\n' > "$B/intent-gate.txt"
printf 'drove it\nMAP ENTRIES: none\nQA COVERAGE: screens=2 flows=3 shots=4\nQA: PASS\n' > "$B/qa.md"
touch "$B/qa-shots/a.png" "$B/qa-shots/b.png" "$B/qa-shots/c.png" "$B/qa-shots/d.png"
printf 'FAIL: expected 3, got 0\n' > "$B/red.txt"
printf 'task one\nnpm test -- a.test.ts\nexit 0\n' > "$B/validate.txt"
printf 'src/lib/pay.ts\nsrc/components/pay\n' > "$B/planned-files.txt"
printf 'SIZE_DECLARED: files=2 lines=45\nSIZE_LIMITS: lines=300 files=12\nSIZE_TOLERANCE: 15%% (lines<=345 files<=13 build whole)\nSIZE_VERDICT: within\n' > "$B/size-gate.txt"
printf 'src/lib/pay.ts\nsrc/components/pay/Row.tsx\n.harness/specs/K/plan.md\n' > "$B/changed-files.txt"

OUT=$("$EV" "$B" 1 "")
grep -q '^## Evidence' <<<"$OUT" && ok || bad "no Evidence heading in the block"
grep -q 'HARNESS_EXIT: 0' <<<"$OUT" && ok || bad "the suite's own exit code is not in the block"
grep -q '| test-tamper gate | clean |' <<<"$OUT" && ok || bad "tamper rc 0 must read clean: $OUT"
grep -q '| reproduction gate | proven |' <<<"$OUT" && ok || bad "repro rc 0 must read proven"
grep -q 'INTENT: src/lib/pay.ts:42 :: agree' <<<"$OUT" \
  && ok || bad "the declared INTENT line is not in the block"
grep -q 'PASS — screens=2 flows=3 claimed, 4 screenshot(s) on disk' <<<"$OUT" \
  && ok || bad "QA coverage + the shot count on disk are not both reported: $OUT"
grep -q 'red-before-green proof | present' <<<"$OUT" && ok || bad "red proof not reported"
grep -q 'settled tier | 1 — no demotion recorded' <<<"$OUT" \
  && ok || bad "a clean tier-1 build must say so: $OUT"
# The spec artifact is the PIPELINE's own commit, never the builder's scope creep.
grep -q '| files | 3 changed, 2 planned, 0 unplanned |' <<<"$OUT" \
  && ok || bad "planned-vs-actual is wrong (dir scope or spec artifact miscounted): $OUT"
grep -q 'Digest: `suite=0 tamper=clean repro=proven intent=declared e2e=pass' <<<"$OUT" \
  && ok || bad "the one-line digest is missing or reordered: $OUT"
# A model call would show up as one of these; there must be none.
grep -qE 'claude|codex|anthropic|http' "$EV" \
  && bad "the renderer references a model or the network — it must be deterministic" || ok

# A plan whose task list names no paths (copy, docs, an S-size plan) leaves an
# EMPTY planned-files.txt, and bin/planned-files.sh writes one. Loaded as the
# first file of a two-file awk, that made the plan set swallow the changed list
# and the row read "0 planned, 0 unplanned" beside a real diff — a false row,
# and the one item 4's scope gate is meant to be built on.
B1B="$T/rec-noplan"; mkdir -p "$B1B"
: > "$B1B/planned-files.txt"
printf 'a.ts\nb.ts\n' > "$B1B/changed-files.txt"
OUT=$("$EV" "$B1B" 2 "")
grep -q '| files | 2 changed, 0 planned, 2 unplanned: `a.ts b.ts` |' <<<"$OUT" \
  && ok || bad "an empty planned-files.txt scored every changed file as planned: $(grep '| files |' <<<"$OUT")"
# The same with NO planned-files.txt at all (records older than the plan step).
rm -f "$B1B/planned-files.txt"
OUT=$("$EV" "$B1B" 2 "")
grep -q '| files | 2 changed, 0 planned, 2 unplanned: `a.ts b.ts` |' <<<"$OUT" \
  && ok || bad "an absent planned-files.txt scored every changed file as planned: $(grep '| files |' <<<"$OUT")"
# ...and the spec artifact is still the pipeline's own commit, not scope creep.
printf 'a.ts\n.harness/specs/K/plan.md\n' > "$B1B/changed-files.txt"
OUT=$("$EV" "$B1B" 2 "")
grep -q '| files | 2 changed, 0 planned, 1 unplanned: `a.ts` |' <<<"$OUT" \
  && ok || bad "the spec artifact counted as unplanned with no plan file: $(grep '| files |' <<<"$OUT")"

# ============================================================================
# 1b. the size declaration vs the diff that actually shipped
# ============================================================================
# WHY (BH-612, 2026-09-16). The size gate used to "corroborate" a plan's declared
# FILE count against planned-files.txt — which bin/planned-files.sh builds as a
# deliberate over-listing of every path the plan MENTIONS, so it decomposed
# 45-line fixes whose prose named eighteen callers (project-5 #1906, #1907). The
# file axis now reads the DECLARATION only, and the check against reality moved
# here, where reality exists: the declaration is compared with the product files
# the build actually changed. It WARNS and never blocks — by render time the code
# is written, and refusing the PR here strands it on a branch nobody merges.
# Absence is never "within": a record with no declaration gets no row at all, and
# a declaration with no file list reads `not recorded`.
SDECL='SIZE_DECLARED: files=2 lines=45
SIZE_FILES: 2
SIZE_LINES: 45
SIZE_LIMITS: lines=300 files=12
SIZE_TOLERANCE: 15% (lines<=345 files<=13 build whole)
SIZE_VERDICT: within'

BSD="$T/rec-sizedecl"; mkdir -p "$BSD"
printf '%s\n' "$SDECL" > "$BSD/size-gate.txt"
{ for i in $(seq 1 16); do echo "src/f$i.ts"; done
  for i in $(seq 1 5); do echo "src/f$i.test.ts"; done
  echo '.harness/specs/K/plan.md'; } > "$BSD/changed-files.txt"
OUT=$("$EV" "$BSD" 1 ""); RC=$?
[ "$RC" = 0 ] && ok || bad "an exceeded size declaration must not change the renderer's rc (rc=$RC)"
grep -qF '| size declaration | SIZE_DECLARATION_EXCEEDED — declared files=2, shipped 16 product file(s), tolerated limit 13 (warn, not a block) |' <<<"$OUT" \
  && ok || bad "a 2-file declaration against a 16-file diff must be reported: $(grep 'size declaration' <<<"$OUT")"
# Tests and the pipeline's own spec commit are not product files — the same
# bin/size-scope.sh list the gate measured the plan with.
grep -q 'shipped 21 product file(s)' <<<"$OUT" \
  && bad "the shipped count includes test files or the spec artifact: $OUT" || ok
BAD_ROWS=$(grep -c '^|.*|.*|.*|' <<<"$OUT")
[ "$BAD_ROWS" = 0 ] && ok || bad "the new row splits the markdown table ($BAD_ROWS bad row(s))"
JSD=$("$EV" --json "$BSD" 1 "")
[ "$(printf '%s' "$JSD" | jq -r '.size_declaration.verdict')" = exceeded ] \
  && ok || bad "the ledger row lost the exceeded verdict: $JSD"
[ "$(printf '%s' "$JSD" | jq -r '.size_declaration.declared_files')" = 2 ] \
  && [ "$(printf '%s' "$JSD" | jq -r '.size_declaration.shipped_files')" = 16 ] \
  && [ "$(printf '%s' "$JSD" | jq -r '.size_declaration.limit_files')" = 13 ] \
  && ok || bad "the ledger row lost one of the three numbers: $JSD"
# The digest is the artifact ref and its shape is pinned elsewhere; this row must
# not have been smuggled into it.
grep -q 'Digest: `suite=' <<<"$OUT" && ok || bad "the digest changed shape: $OUT"
grep -q 'size_decl' <<<"$(grep 'Digest:' <<<"$OUT")" \
  && bad "the new row leaked into the digest string" || ok

# An honest small diff under the same declaration: within, with the numbers.
printf 'src/a.ts\nsrc/b.ts\nsrc/c.ts\n' > "$BSD/changed-files.txt"
OUT=$("$EV" "$BSD" 1 "")
grep -qF '| size declaration | within — declared files=2, shipped 3 product file(s), tolerated limit 13 |' <<<"$OUT" \
  && ok || bad "a 3-file diff under a 2-file declaration must read within: $(grep 'size declaration' <<<"$OUT")"
[ "$(printf '%s' "$("$EV" --json "$BSD" 1 "")" | jq -r '.size_declaration.verdict')" = within ] \
  && ok || bad "the within verdict did not reach the ledger row"

# AN HONEST OVER-DECLARATION IS NOT A FINDING. This row catches UNDER-declaring
# only: a plan that said 17 files and shipped 17 was already split or tolerated by
# the gate, and flagging it here would report the planner's honesty as a defect.
BSD2="$T/rec-sizedecl-honest"; mkdir -p "$BSD2"
printf 'SIZE_DECLARED: files=17 lines=780\nSIZE_LIMITS: lines=300 files=12\nSIZE_TOLERANCE: 15%% (lines<=345 files<=13 build whole)\nSIZE_VERDICT: over\n' \
  > "$BSD2/size-gate.txt"
for i in $(seq 1 17); do echo "src/h$i.ts"; done > "$BSD2/changed-files.txt"
OUT=$("$EV" "$BSD2" 2 "")
grep -q 'SIZE_DECLARATION_EXCEEDED' <<<"$OUT" \
  && bad "an honest 17-file declaration shipping 17 files was flagged: $(grep 'size declaration' <<<"$OUT")" || ok
grep -qF '| size declaration | within — declared files=17, shipped 17 product file(s), tolerated limit 13 |' <<<"$OUT" \
  && ok || bad "the honest over-band row must still render its numbers: $(grep 'size declaration' <<<"$OUT")"

# A DECLARATION WITH NO FILE LIST IS NOT "WITHIN". Every record before the
# renderer wrote changed-files.txt lands here, and scoring it as a pass would
# make the row mean both "honest" and "old box".
BSD3="$T/rec-sizedecl-nofiles"; mkdir -p "$BSD3"
printf '%s\n' "$SDECL" > "$BSD3/size-gate.txt"
OUT=$("$EV" "$BSD3" 1 "")
grep -qF '| size declaration | not recorded (declared files=2) |' <<<"$OUT" \
  && ok || bad "a declaration with no changed-files.txt must read not recorded: $(grep 'size declaration' <<<"$OUT")"
[ "$(printf '%s' "$("$EV" --json "$BSD3" 1 "")" | jq -r '.size_declaration.verdict')" = not-recorded ] \
  && ok || bad "the not-recorded verdict did not reach the ledger row"
[ "$(printf '%s' "$("$EV" --json "$BSD3" 1 "")" | jq -r '.size_declaration.shipped_files')" = null ] \
  && ok || bad "a shipped count was invented for a diff that was never listed"

# NO size-gate.txt at all — every record written before the gate existed, and
# every box whose harness sync lags it: no row, no JSON field, and the rest of
# the block byte-identical to what it rendered before this change.
BSDN="$T/rec-sizedecl-none"; mkdir -p "$BSDN"
printf 'src/a.ts\nsrc/b.ts\n' > "$BSDN/changed-files.txt"
OUT=$("$EV" "$BSDN" 1 "")
grep -q 'size declaration' <<<"$OUT" \
  && bad "a record with no size-gate.txt grew a size declaration row: $OUT" || ok
grep -q '| files | 2 changed, 0 planned, 2 unplanned' <<<"$OUT" \
  && ok || bad "the rest of the block moved when the new row was absent: $OUT"
[ "$(printf '%s' "$("$EV" --json "$BSDN" 1 "")" | jq -r 'has("size_declaration")')" = false ] \
  && ok || bad "the ledger row carries a size_declaration field for a record with no declaration"
# ...and a gate that could not read the plan declared nothing either.
BSD4="$T/rec-sizedecl-unavailable"; mkdir -p "$BSD4"
printf "SIZE_GATE_UNAVAILABLE the plan carries no '## Size' section with both FILES: and LINES:\nSIZE_LIMITS: lines=300 files=12\nSIZE_VERDICT: undeclared\n" \
  > "$BSD4/size-gate.txt"
for i in $(seq 1 30); do echo "src/u$i.ts"; done > "$BSD4/changed-files.txt"
OUT=$("$EV" "$BSD4" 2 "")
grep -q 'size declaration' <<<"$OUT" \
  && bad "an undeclared record was given a size declaration verdict: $(grep 'size declaration' <<<"$OUT")" || ok

# The tolerated limit is READ from the gate's own record, never recomputed here,
# so the two sides cannot disagree about one number. With no SIZE_TOLERANCE line
# (tolerance switched off) it falls back to the nominal SIZE_LIMITS figure.
BSD5="$T/rec-sizedecl-notol"; mkdir -p "$BSD5"
printf 'SIZE_DECLARED: files=2 lines=45\nSIZE_LIMITS: lines=300 files=12\nSIZE_VERDICT: within\n' \
  > "$BSD5/size-gate.txt"
for i in $(seq 1 13); do echo "src/n$i.ts"; done > "$BSD5/changed-files.txt"
OUT=$("$EV" "$BSD5" 1 "")
grep -qF 'declared files=2, shipped 13 product file(s), tolerated limit 12' <<<"$OUT" \
  && ok || bad "with no tolerance line the row must judge against the nominal limit: $(grep 'size declaration' <<<"$OUT")"
grep -q 'SIZE_DECLARATION_EXCEEDED' <<<"$OUT" \
  && ok || bad "13 shipped against a limit of 12 is an under-declaration: $(grep 'size declaration' <<<"$OUT")"
# Nothing out of size-gate.txt is executed or interpolated: it is a file a gate
# wrote, but the gate reads a plan a model wrote.
BSD6="$T/rec-sizedecl-hostile"; mkdir -p "$BSD6"
printf 'SIZE_DECLARED: files=$(touch %s/PWNED3) lines=`id`\nSIZE_LIMITS: lines=300 files=12\n' \
  "$T" > "$BSD6/size-gate.txt"
printf 'src/a.ts\n' > "$BSD6/changed-files.txt"
OUT=$("$EV" "$BSD6" 1 "")
[ -e "$T/PWNED3" ] && bad "size-gate.txt text was EXECUTED by the renderer" || ok
grep -q 'size declaration' <<<"$OUT" \
  && bad "a non-numeric declared count was rendered as a verdict: $(grep 'size declaration' <<<"$OUT")" || ok

# ============================================================================
# 2. the renderer: absence is never a pass
# ============================================================================
B2="$T/rec-empty"; mkdir -p "$B2"
OUT=$("$EV" "$B2")
RC=$?
[ "$RC" = 0 ] && ok || bad "an empty build dir must still render (rc=$RC)"
grep -q 'HARNESS_EXIT: not-recorded' <<<"$OUT" \
  && ok || bad "a missing suite file must read not-recorded, never 0: $OUT"
for W in 'test-tamper gate | not-recorded' 'reproduction gate | not-recorded' \
         'intent gate | not-recorded' 'e2e smoke | not-recorded'; do
  grep -q "$W" <<<"$OUT" && ok || bad "missing gate must read not-recorded ($W): $OUT"
done
grep -q 'red-before-green proof | absent' <<<"$OUT" && ok || bad "no red.txt must read absent"
grep -qE '\| preview QA \| (PASS|proven)' <<<"$OUT" \
  && bad "an absent QA file read as a pass: $OUT" || ok
grep -q 'settled tier | unsettled' <<<"$OUT" && ok || bad "no tier must read unsettled"
# A build dir with no changed-files.txt (every record older than this renderer,
# and any box whose harness sync lags it) has an UNKNOWN diff, not an empty one.
grep -q '| files | not recorded (0 planned) |' <<<"$OUT" \
  && ok || bad "an absent changed-files.txt was scored as 0 changed / 0 unplanned: $OUT"
grep -q 'files=not-recorded/0 unplanned=not-recorded' <<<"$OUT" \
  && ok || bad "the digest claims a file count from a file that does not exist: $OUT"
J0=$("$EV" --json "$B2")
[ "$(printf '%s' "$J0" | jq -r '.files.changed')" = null ] \
  && [ "$(printf '%s' "$J0" | jq -r '.files.unplanned')" = null ] \
  && ok || bad "JSON reported 0 for a file list that was never recorded: $J0"
"$EV" "$T/does-not-exist" >/dev/null 2>&1
[ "$?" = 2 ] && ok || bad "a missing build dir must exit 2, not render an empty block"

# ============================================================================
# 3. the renderer: the counts a QA session cannot assert its way past
# ============================================================================
B3="$T/rec-emptypass"; mkdir -p "$B3"
printf 'QA COVERAGE: screens=9 flows=9 shots=9\nQA: PASS\n' > "$B3/qa.md"
OUT=$("$EV" "$B3" 2 "QA: EMPTY PASS — demoted to tier-2")
grep -q 'PASS — screens=9 flows=9 claimed, 0 screenshot(s) on disk' <<<"$OUT" \
  && ok || bad "the shot count must come from disk, not from the claim: $OUT"
grep -q 'settled tier | 2 — QA: EMPTY PASS — demoted to tier-2' <<<"$OUT" \
  && ok || bad "the settled tier must carry WHY it settled there: $OUT"
# The demoters build their notes as " | QA: …" so several concatenate; the row
# must not open on that separator (clean() turns the pipe into a slash).
OUT=$("$EV" "$B3" 2 " | QA: EMPTY PASS — demoted to tier-2")
grep -q 'settled tier | 2 — QA: EMPTY PASS' <<<"$OUT" \
  && ok || bad "the demoter's leading separator is rendered into the tier row: $OUT"

# The pipeline WRITES INTO qa.md AFTER the verdict, on exactly the builds this
# block exists for. A renderer reading tail -1 called both of them `skipped`:
# the fix-round build below FAILED twice with three screens loaded, and the
# empty-pass build below contradicted its own tier row on the same page.
B3C="$T/rec-qafail-note"; mkdir -p "$B3C"
printf 'drove it\nQA COVERAGE: screens=3 flows=2 shots=0\nQA: FAIL\nQA still failing after fix round — demoted to tier 2.\n' > "$B3C/qa.md"
OUT=$("$EV" "$B3C" 2 "QA: SKIPPED — demoted to tier-2")
grep -q '| preview QA | FAIL — screens=3 flows=2 claimed, 0 screenshot(s) on disk' <<<"$OUT" \
  && ok || bad "a QA FAIL with the pipeline's demotion note after it rendered as skipped: $OUT"
grep -q 'pipeline note appended after the verdict' <<<"$OUT" \
  && ok || bad "the row does not say the pipeline wrote after the verdict: $OUT"
grep -q 'qa=FAIL' <<<"$OUT" && ok || bad "the digest lost the FAIL verdict: $OUT"
J3C=$("$EV" --json "$B3C")
[ "$(printf '%s' "$J3C" | jq -r '.qa.verdict')" = FAIL ] \
  && ok || bad "the ledger row reported a failed QA as something else: $J3C"
# The note is a flag of its own, never part of the verdict word: the outcome
# metrics group on qa.verdict, and "FAIL (note)" is not a verdict anything counts.
[ "$(printf '%s' "$J3C" | jq -r '.qa.note_appended')" = true ] \
  && ok || bad "the appended note is not recorded as its own field: $J3C"

B3D="$T/rec-emptypass-note"; mkdir -p "$B3D"
printf 'QA COVERAGE: screens=3 flows=2 shots=3\nQA: PASS\n\nGATE: PASS claimed with screens=3 and 0 screenshots on disk — not merge-worthy evidence.\n' > "$B3D/qa.md"
OUT=$("$EV" "$B3D" 2 "QA: EMPTY PASS — demoted to tier-2")
grep -q '| preview QA | PASS — screens=3 flows=2 claimed, 0 screenshot(s) on disk' <<<"$OUT" \
  && ok || bad "an empty PASS plus the gate's own note rendered as skipped: $OUT"
grep -q 'settled tier | 2 — QA: EMPTY PASS' <<<"$OUT" \
  && ok || bad "the empty-pass tier row went missing: $OUT"

# ...and the fail-open file, which carries no verdict at all, still reads skipped.
B3E="$T/rec-qaskip"; mkdir -p "$B3E"
printf 'preview unavailable — QA skipped (fail-open)\n' > "$B3E/qa.md"
OUT=$("$EV" "$B3E" 2 "")
grep -q '| preview QA | skipped —' <<<"$OUT" \
  && ok || bad "a fail-open QA skip must still read skipped: $OUT"
grep -q 'pipeline note appended' <<<"$OUT" \
  && bad "a file with no verdict line claimed a note was appended to one: $OUT" || ok
# The two appended sentences are the SHIPPED ones — if run-build.sh stops writing
# them, or writes different ones, this fixture is fiction.
for L in 'QA still failing after fix round — demoted to tier 2.' \
         'GATE: PASS claimed with screens=%s and %s screenshots on disk'; do
  grep -qF "$L" "$RB_ALL" \
    && ok || bad "the pipeline no longer appends '$L' — the QA fixtures are stale"
done

# The block and the QA demoter read the SAME qa.md; a coverage line the demoter
# accepts must not render as screens=0, or the tier and the evidence disagree on
# the page where the tier is being justified.
B3B="$T/rec-cov"; mkdir -p "$B3B"
printf 'QA COVERAGE: screens=3\nQA: PASS\n' > "$B3B/qa.md"
OUT=$("$EV" "$B3B" 2 "")
grep -q 'PASS — screens=3 flows=0 claimed, 0 screenshot(s) on disk' <<<"$OUT" \
  && ok || bad "a coverage line without flows/shots rendered screens=0: $OUT"
# ...and it is the demoter's own line, lifted out of run-build.sh, that says so.
QA_DEMOTER=$(grep -m1 '^QA_SCREENS=' "$RB_ALL")
[ -n "$QA_DEMOTER" ] && ok || bad "could not find the QA demoter's screens expression in run-build.sh"
RB=$(BUILD="$B3B" bash -c "$QA_DEMOTER"'; echo "${QA_SCREENS:-0}"' 2>/dev/null)
[ "$RB" = 3 ] && ok || bad "the demoter reads screens=$RB where the block reads 3 — the two disagree"

# The listing is bounded, and the bound must not eat the separator: with the
# count glued to the last path the row read `src/x8.ts+1 more`, which names a
# file that does not exist.
B3F="$T/rec-manyunplanned"; mkdir -p "$B3F"
: > "$B3F/planned-files.txt"
for i in 1 2 3 4 5 6 7 8 9; do echo "src/x$i.ts" >> "$B3F/changed-files.txt"; done
OUT=$("$EV" "$B3F" 2 "")
grep -q 'src/x8.ts +1 more' <<<"$OUT" \
  && ok || bad "the +N more count is glued to the last unplanned path: $OUT"
grep -q '9 changed, 0 planned, 9 unplanned' <<<"$OUT" \
  && ok || bad "truncating the listing must never truncate the counts: $OUT"

# ============================================================================
# 4. the renderer never executes, splits or leaks agent text
# ============================================================================
B4="$T/rec-hostile"; mkdir -p "$B4"
printf '  [agree] INTENT: $(touch %s/PWNED) `id` | broken | table :: agree\nINTENT_VERDICT: declared\n' \
  "$T" > "$B4/intent-gate.txt"
printf 'QA COVERAGE: screens=1 flows=1 shots=1\nQA: PASS\n' > "$B4/qa.md"
printf '{"tamper":"9; touch %s/PWNED2","repro":0,"intent":0,"e2e":"pass","migration":"none"}\n' \
  "$T" > "$B4/gates.json"
OUT=$("$EV" "$B4" 1 "note")
[ -e "$T/PWNED" ] || [ -e "$T/PWNED2" ] \
  && bad "agent/gate text was EXECUTED by the renderer" || ok
# One row per check: a pipe smuggled in from agent text would split a row and
# silently invent a column.
BAD_ROWS=$(grep -c '^|.*|.*|.*|' <<<"$OUT")
[ "$BAD_ROWS" = 0 ] && ok || bad "$BAD_ROWS table row(s) carry an unescaped pipe from agent text"
grep -q 'could-not-run' <<<"$OUT" && ok || bad "an unrecognised gate value must read could-not-run: $OUT"
# A backtick from agent text closes the markdown code span the row opened, so
# the rest of the cell renders as prose and the next backtick reopens it.
IROW=$(grep '| intent gate |' <<<"$OUT")
[ "$(tr -cd '`' <<<"$IROW" | wc -c)" = 2 ] \
  && ok || bad "a backtick from agent text broke the intent row's code span: $IROW"

# The gate lists EVERY candidate and its verdict is a precedence over them, so
# the row must show the line the verdict is ABOUT, not whichever came first.
B4B="$T/rec-conflict"; mkdir -p "$B4B"
printf 'CONFLICT DECLARED:\n  [agree] INTENT: src/a.ts:1 :: agree\n  [conflict] INTENT: src/b.ts:9 :: CONFLICT: spec says X, the code says Y — trusting the spec\nINTENT_VERDICT: conflict\n' \
  > "$B4B/intent-gate.txt"
OUT=$("$EV" "$B4B" 2 "")
grep -q 'intent gate | conflict — `INTENT: src/b.ts:9 :: CONFLICT' <<<"$OUT" \
  && ok || bad "the conflict row shows an unrelated agreeing candidate: $OUT"

# JSON mode is the ledger's copy of the same facts, and must stay parseable and
# under the worker's 4000-char detail cap.
J=$("$EV" --json "$B" 2 "QA: SKIPPED — demoted to tier-2")
printf '%s' "$J" | jq -e . >/dev/null 2>&1 && ok || bad "--json did not emit valid JSON"
[ "$(printf '%s' "$J" | wc -c)" -lt 4000 ] \
  && ok || bad "the JSON detail is over the worker's 4000-char cap"
[ "$(printf '%s' "$J" | jq -r '.qa.shots')" = 4 ] \
  && ok || bad "JSON shot count is not the on-disk count"
[ "$(printf '%s' "$J" | jq -r '.tier')" = 2 ] && ok || bad "JSON tier is not the settled tier"
[ -n "$(printf '%s' "$J" | jq -r '.digest')" ] && ok || bad "JSON carries no digest for the artifact ref"
JH=$("$EV" --json "$B4" 1 "n")
printf '%s' "$JH" | jq -e . >/dev/null 2>&1 \
  && ok || bad "hostile agent text broke the JSON render"

# ============================================================================
# 4b. rc=1 out of a gate: a crash is not a block
# ============================================================================
# Both gates exit 1 for "blocked" AND for "I fell over before judging", and
# run-build.sh does NOT block on the second one — it logs scan_failed and opens
# the PR anyway. So an rc=1 that reaches a PR page is the crash, and rendering
# it as `blocked` prints a verdict on a PR nobody blocked, citing a gate that
# never reached one.
B5="$T/rec-crash"; mkdir -p "$B5"
printf '{"tamper":1,"repro":1,"intent":0,"e2e":"pass","migration":"none"}\n' > "$B5/gates.json"
printf 'scanning...\nBLOCKING_COUNT: 0\n./bin/test-tamper-scan.sh: line 90: X: unbound variable\n' \
  > "$B5/test-tamper.txt"
printf 'repro-gate: comparing base\nbash: git: command not found\n' > "$B5/repro-gate.txt"
OUT=$("$EV" "$B5" 2 "")
grep -q '| test-tamper gate | blocked |' <<<"$OUT" \
  && bad "a crashed tamper scan rendered as blocked: $(grep 'tamper gate' <<<"$OUT")" || ok
grep -q '| reproduction gate | blocked |' <<<"$OUT" \
  && bad "a crashed repro gate rendered as blocked: $(grep 'reproduction gate' <<<"$OUT")" || ok
grep -qE '\| test-tamper gate \| scan-failed\(rc=1' <<<"$OUT" \
  && ok || bad "a crashed tamper scan must say it did not judge: $(grep 'tamper gate' <<<"$OUT")"
grep -qE '\| reproduction gate \| could-not-run\(rc=1' <<<"$OUT" \
  && ok || bad "a crashed repro gate must say it did not judge: $(grep 'reproduction gate' <<<"$OUT")"

# A gate that DID reach its verdict still reads blocked (an operator rendering an
# archived record of a build that was blocked before any PR existed).
B5B="$T/rec-blocked"; mkdir -p "$B5B"
printf '{"tamper":1,"repro":1,"intent":0,"e2e":"not-run","migration":"none"}\n' > "$B5B/gates.json"
printf 'DELETED: tests/a.test.ts\nBLOCKING_COUNT: 1\nJUSTIFICATION: NONE\n' > "$B5B/test-tamper.txt"
printf 'the added tests pass at the merge base\nGATE FAILED\n' > "$B5B/repro-gate.txt"
OUT=$("$EV" "$B5B" 2 "")
grep -q '| test-tamper gate | blocked |' <<<"$OUT" \
  && ok || bad "a tamper gate that reached its verdict must read blocked: $OUT"
grep -q '| reproduction gate | blocked |' <<<"$OUT" \
  && ok || bad "a repro gate that reached its verdict must read blocked: $OUT"
# A partial report the scanner never stood behind is not a block either: the
# count is asserted, exactly as run-build.sh asserts it.
printf 'BLOCKING_COUNT: 0\nJUSTIFICATION: NONE\n' > "$B5B/test-tamper.txt"
OUT=$("$EV" "$B5B" 2 "")
grep -q '| test-tamper gate | blocked |' <<<"$OUT" \
  && bad "BLOCKING_COUNT: 0 with a JUSTIFICATION line rendered as blocked: $OUT" || ok

# The renderer and run-build.sh must key the crash-vs-verdict question on the
# SAME strings, or the PR page and the pipeline can disagree about one gate.
for K in 'JUSTIFICATION: NONE' 'GATE FAILED'; do
  grep -qF "$K" "$RB_ALL" && grep -qF "$K" "$EV" \
    && ok || bad "the two files no longer key the gate verdict on '$K'"
done

# ============================================================================
# 4c. acceptance claims: the evidence contract's verdicts, in the same table
# ============================================================================
# The scorer (bin/lib/evidence.sh, #527) writes <build>/evidence.json. This block
# renders it INSIDE the existing table — never a second one — and the three
# states are not interchangeable (D11/D13): rows when claims were scored,
# `none named in the plan` when the plan named none, `not recorded` when the file
# is absent or unreadable. Absence is not zero. The claim text is model-written,
# so it runs the same hostile gauntlet as section 4: a command substitution, a
# backtick and a pipe.
BC="$T/rec-claims"; mkdir -p "$BC"
C1='$(touch '"$T"'/PWNED4) `id` a | pipe'
jq -n --arg c1 "$C1" '{total:3,confirmed:1,refuted:1,inconclusive:1,claims:[
  {n:1,claim:$c1,verdict:"CONFIRMED",artifact:"validate.txt:3",note:"exit 0",proposed:""},
  {n:2,claim:"x",verdict:"REFUTED",artifact:"validate.txt:9",note:"exit 1",proposed:""},
  {n:3,claim:"y",verdict:"INCONCLUSIVE",artifact:"",note:"not run",proposed:""}]}' \
  > "$BC/evidence.json"
OUT=$("$EV" "$BC" 2 "")
[ "$(grep -c '^## Evidence' <<<"$OUT")" = 1 ] \
  && ok || bad "the claim rows opened a second Evidence heading: $OUT"
[ "$(grep -c '^| claim [0-9]*: ' <<<"$OUT")" = 3 ] \
  && ok || bad "expected one row per scored claim: $(grep '| claim' <<<"$OUT")"
grep -qF '| claim 2: x | REFUTED — validate.txt:9 — exit 1 |' <<<"$OUT" \
  && ok || bad "the REFUTED row is not rendered as specified: $(grep '| claim 2' <<<"$OUT")"
grep -q '^| claim 1: .* | CONFIRMED — validate.txt:3 — exit 0 |$' <<<"$OUT" \
  && ok || bad "the CONFIRMED row lost a cell: $(grep '| claim 1' <<<"$OUT")"
grep -q '^| claim 3: y | INCONCLUSIVE — (none) — not run |$' <<<"$OUT" \
  && ok || bad "an empty artifact must read (none), never an empty cell: $(grep '| claim 3' <<<"$OUT")"
# Placement: inside the table, directly after the VALIDATE row and before files.
awk '/plan VALIDATE checks/{v=NR} /^\| claim 1:/{c=NR} /^\| files \|/{f=NR}
     END{exit !(v && c && f && v<c && c<f)}' <<<"$OUT" \
  && ok || bad "the claim rows are not between the VALIDATE row and the files row: $OUT"
# The same three safety properties section 4 pins for every other agent-written
# cell: nothing executes, nothing splits the row, nothing opens a code span.
[ -e "$T/PWNED4" ] && bad "claim text was EXECUTED by the renderer" || ok
BAD_ROWS=$(grep -c '^|.*|.*|.*|' <<<"$OUT")
[ "$BAD_ROWS" = 0 ] && ok || bad "$BAD_ROWS claim row(s) carry an unescaped pipe from claim text"
[ "$(grep '^| claim 1:' <<<"$OUT" | tr -cd '`' | wc -c)" = 0 ] \
  && ok || bad "a backtick from claim text survived into the row: $(grep '| claim 1' <<<"$OUT")"
# The digest is the ledger's artifact ref: same prefix, the counts appended last.
grep -q 'Digest: `suite=' <<<"$OUT" && ok || bad "the digest prefix changed shape: $OUT"
grep -q ' claims=1/1/1`$' <<<"$OUT" \
  && ok || bad "the digest does not end with the claim counts: $(grep 'Digest:' <<<"$OUT")"
grep -q '| acceptance claims |' <<<"$OUT" \
  && bad "a status row rendered beside real claim rows: $(grep 'acceptance claims' <<<"$OUT")" || ok
JC=$("$EV" --json "$BC" 2 "")
printf '%s' "$JC" | jq -e . >/dev/null 2>&1 && ok || bad "the claim counts broke the JSON render: $JC"
[ "$(printf '%s' "$JC" | jq -r '.claims.refuted')" = 1 ] \
  && [ "$(printf '%s' "$JC" | jq -r '.claims.total')" = 3 ] \
  && ok || bad "the ledger row lost the claim counts: $JC"
[ "$(printf '%s' "$JC" | jq -r '.claims | has("rows")')" = false ] \
  && ok || bad "the ledger row carries per-claim rows — a long plan would blow the cap: $JC"
[ "$(printf '%s' "$JC" | wc -c)" -lt 4000 ] \
  && ok || bad "the JSON detail is over the worker's 4000-char cap"
printf '%s' "$JC" | jq -r '.digest' | grep -q ' claims=1/1/1$' \
  && ok || bad "the JSON digest does not carry the claim counts: $JC"

# total=0 is a SCORED plan that named no claims — not an unscored one.
BC0="$T/rec-zero"; mkdir -p "$BC0"
printf '{"total":0,"confirmed":0,"refuted":0,"inconclusive":0,"claims":[]}\n' > "$BC0/evidence.json"
OUT0=$("$EV" "$BC0" 2 "")
grep -qF '| acceptance claims | none named in the plan |' <<<"$OUT0" \
  && ok || bad "a scored plan with no claims must say so: $(grep 'acceptance claims' <<<"$OUT0")"
grep -q '^| claim ' <<<"$OUT0" && bad "a plan that named no claims grew claim rows: $OUT0" || ok
grep -q 'not recorded' <<<"$(grep 'acceptance claims' <<<"$OUT0")" \
  && bad "a scored plan with zero claims read as not recorded" || ok
grep -q ' claims=0/0/0`$' <<<"$OUT0" \
  && ok || bad "the digest does not carry the zero counts: $(grep 'Digest:' <<<"$OUT0")"
[ "$(printf '%s' "$("$EV" --json "$BC0" 2 "")" | jq -r '.claims.total')" = 0 ] \
  && ok || bad "the ledger row lost the zero claim count"

# NO evidence.json (every record older than the contract), and one that cannot be
# read: both are `not recorded`, with NO digest field and NO JSON key, so those
# records render byte-identically to what they rendered before this existed.
for D in rec-noev rec-badev; do
  mkdir -p "$T/$D"
  printf 'QA COVERAGE: screens=1 flows=1 shots=0\nQA: PASS\n' > "$T/$D/qa.md"
done
printf 'not json\n' > "$T/rec-badev/evidence.json"
for D in rec-noev rec-badev; do
  OUTN=$("$EV" "$T/$D" 2 "")
  grep -qF '| acceptance claims | not recorded |' <<<"$OUTN" \
    && ok || bad "$D: an unscored record must read not recorded: $(grep 'acceptance claims' <<<"$OUTN")"
  grep -q '^| claim ' <<<"$OUTN" && bad "$D grew claim rows out of nothing: $OUTN" || ok
  grep -q 'none named' <<<"$OUTN" \
    && bad "$D was rendered as a scored plan with zero claims" || ok
  grep -q 'claims=' <<<"$(grep 'Digest:' <<<"$OUTN")" \
    && bad "$D: absence was rendered as a count in the digest" || ok
  [ "$(printf '%s' "$("$EV" --json "$T/$D" 2 "")" | jq -r 'has("claims")')" = false ] \
    && ok || bad "$D: the ledger row grew a claims key for a record nobody scored"
done

# From here on the GOOD build carries scored claims too, so the two production
# render points in section 5 — the PR-open body and the settle rewrite — are
# driven with them, and the kill switch is asserted against them.
printf '%s\n' '{"total":2,"confirmed":1,"refuted":1,"inconclusive":0,"claims":[{"n":1,"claim":"the rate comes from the DB","verdict":"CONFIRMED","artifact":"validate.txt:3","note":"exit 0","proposed":""},{"n":2,"claim":"the cron re-runs cleanly","verdict":"REFUTED","artifact":"validate.txt:9","note":"exit 1","proposed":""}]}' \
  > "$B/evidence.json"

# ============================================================================
# 5. bin/run-build.sh — the two render points, extracted verbatim
# ============================================================================
awk '/^# >>> merge note fn/{f=1;next} /^# <<< merge note fn/{exit} f' \
  "$RB_ALL" > "$T/mergenote.sh"
awk '/^# >>> evidence block/{f=1;next} /^# <<< evidence block/{exit} f' \
  "$RB_ALL" > "$T/block.sh"
awk '/^# >>> evidence settle/{f=1;next} /^# <<< evidence settle/{exit} f' \
  "$RB_ALL" > "$T/settle.sh"
[ -s "$T/mergenote.sh" ] && ok || bad "could not extract the merge-note fn — markers missing?"
[ -s "$T/block.sh" ] && ok || bad "could not extract the evidence block — markers missing?"
[ -s "$T/settle.sh" ] && ok || bad "could not extract the evidence settle block — markers missing?"
grep -q 'evidence-summary.sh' "$T/block.sh" && ok || bad "the PR-open block never renders evidence"
grep -q 'gh pr edit' "$T/settle.sh" && ok || bad "the settle block never rewrites the PR body"

cp "$DIR/bin/evidence-summary.sh" "$T/bin/evidence-summary.sh"
# The renderer resolves bin/size-scope.sh next to itself for the size-declaration
# row, exactly as it sits in $HARNESS/bin on a real box.
cp "$DIR/bin/size-scope.sh" "$T/bin/size-scope.sh"
REPO="$T/repo"; mkdir -p "$REPO"
( cd "$REPO" || exit 1
  git init -q -b main
  git config user.email t@example.com; git config user.name tester
  echo one > a.txt; git add -A; git -c commit.gpgsign=false commit -qm "K: the subject line" ) >/dev/null 2>&1

# gh stub: records every invocation, and answers `pr edit` per GH_EDIT_RC.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "${1:-}" in
  pr) case "${2:-}" in
        edit) shift 3; while [ $# -gt 0 ]; do [ "$1" = "--body" ] && printf '%s' "$2" > "$GH_BODY"; shift; done
              exit "${GH_EDIT_RC:-0}" ;;
      esac ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

drive() { # drive <tier> <qa-note> [env assignments...]
  local tier="$1" note="$2"; shift 2
  : > "$T/gh-calls.txt"; : > "$T/gh-body.txt"; : > "$T/artifact.txt"
  rm -rf "$T/build"; cp -r "$B" "$T/build"
  # A real branch off main with a real commit, so the settle pass has a diff to
  # re-derive and FIXCOMMIT below can grow it the way a QA fix round does.
  ( cd "$REPO" || exit 1
    git checkout -q -B evb main
    mkdir -p src/lib && echo change > src/lib/pay.ts
    git add -A && git -c commit.gpgsign=false commit -qm "K: the change" ) >/dev/null 2>&1
  ( cd "$REPO" || exit 1
    env PATH="$T/fakebin:$PATH" HARNESS="$T" BUILD="$T/build" TIER="$tier" QA_NOTE="$note" \
        GH_SINK="$T/gh-calls.txt" GH_BODY="$T/gh-body.txt" ART_SINK="$T/artifact.txt" \
        JOB_ID=job-1 PR_URL="https://github.com/o/r/pull/7" "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      job_evidence_put() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$ART_SINK"; return "${PUT_RC:-0}"; }
      # TEST-CHANGE (BH-6091): the settle pass now asks the hold gate before its
      # gh pr edit and fails closed with no hold library. This drive is about the
      # body, so the ticket is not held (tests/pool-hold-yield.bh-6091 drives a
      # held one). BRANCH is what the gate reads.
      hold_push_verdict() { return 0; }; BRANCH=ticket/k
      PROJECT=p; KEY=K; BASE=main; CHANGED="src/lib/pay.ts
src/components/pay/Row.tsx"
      TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0; E2E_VERDICT=pass
      ADDED_SQL="${ADDED_SQL:-}"; MIG_NOTE="${MIG_NOTE:-}"
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because the ticket said so"
      VERIFY_LINE="Verification evidence: validate.txt (39B)"; SPEC_LINE="Spec: yes"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="AI cost: \$1"
      CTX_SIG=sig; CTX_COMMIT=abc123; CTX_SYNC=yes; CTX_FRESH=yes
      . "$0"          # merge-note fn
      . "$1"          # PR-open evidence block
      printf "%s" "$(PR_BODY_FOR "$EVIDENCE_SECTION")" > "$2"
      cp "$BUILD/changed-files.txt" "$2.changed"   # the list as PR-open wrote it
      # A QA fix round, between the two renders: it commits and pushes code the
      # PR-open file list has never seen.
      if [ -n "${FIXCOMMIT:-}" ]; then
        mkdir -p src/rogue && echo x > src/rogue/Extra.tsx && echo y > src/rogue/Two.tsx
        git add -A && git -c commit.gpgsign=false commit -qm "qa fix round" >/dev/null 2>&1
      fi
      . "$3"          # settle
    ' "$T/mergenote.sh" "$T/block.sh" "$T/open-body.txt" "$T/settle.sh" 2>"$T/drive-err.txt" )
}

# 5a. the PR-open body carries the block, above the attribution footer, and the
#     facts the pipeline holds in variables reach the renderer as files.
drive 1 ""
grep -q '## Evidence' "$T/open-body.txt" \
  && ok || bad "the PR body opened without an evidence block: $(head -5 "$T/drive-err.txt")"
awk '/## Evidence/{e=NR} /Generated with \[Claude Code\]/{f=NR} END{exit !(e>0 && f>e)}' "$T/open-body.txt" \
  && ok || bad "the evidence block is not between the build context and the footer"
grep -q "tier so far (not settled)" "$T/open-body.txt" \
  && ok || bad "the PR-open block must mark the tier as not settled"
# A blank line between the digest and the footer, or markdown renders them as
# one paragraph and the block ends in an attribution sentence.
grep -q '[^[:space:]]' <<<"$(grep -B1 'Generated with \[Claude Code\]' "$T/open-body.txt" | head -1)" \
  && bad "the attribution footer is glued to the last evidence line" || ok
[ -s "$T/build/gates.json" ] && ok || bad "gates.json was not written for the renderer"
[ "$(jq -r '.e2e' "$T/build/gates.json")" = pass ] \
  && [ "$(jq -r '.migration' "$T/build/gates.json")" = none ] \
  && [ "$(jq -r '.tamper' "$T/build/gates.json")" = 0 ] \
  && ok || bad "gates.json lost a gate verdict: $(cat "$T/build/gates.json")"
[ "$(grep -c . "$T/open-body.txt.changed")" = 2 ] \
  && ok || bad "changed-files.txt is not this diff's file list at PR-open time"
# The acceptance-claim rows through the PRODUCTION render point: a row only the
# renderer's own fixtures ever produce is a row no PR page carries.
grep -qF '| claim 2: the cron re-runs cleanly | REFUTED — validate.txt:9 — exit 1 |' "$T/open-body.txt" \
  && ok || bad "the PR-open body carries no acceptance-claim rows: $(grep '| claim' "$T/open-body.txt")"
grep -q ' claims=1/1/0`$' "$T/open-body.txt" \
  && ok || bad "the PR-open digest lost the claim counts: $(grep 'Digest:' "$T/open-body.txt")"

# 5b. the settle pass: evidence.md on disk, the PR body rewritten with the
#     SETTLED tier, and one ledger row.
drive 2 " | QA: SKIPPED — demoted to tier-2"
[ -s "$T/build/evidence.md" ] && ok || bad "evidence.md (the file fallback) was not written"
grep -q 'pr edit' "$T/gh-calls.txt" && ok || bad "the settled body was never pushed to the PR"
grep -q 'QA: SKIPPED — demoted to tier-2' "$T/gh-body.txt" \
  && ok || bad "the settled body does not carry the demotion reason: $(head -3 "$T/gh-body.txt")"
grep -q 'settled tier | 2' "$T/gh-body.txt" && ok || bad "the settled body does not name tier 2"
grep -q '^| claim 2: ' "$T/gh-body.txt" \
  && ok || bad "the settled body lost the acceptance-claim rows: $(grep '| claim' "$T/gh-body.txt")"
grep -q '^| claim 2: ' "$T/build/evidence.md" \
  && ok || bad "evidence.md disagrees with the PR body about the scored claims"
grep -q "tier so far (not settled)" "$T/gh-body.txt" \
  && bad "the settled body still carries the PR-open placeholder" || ok
# The body must not claim tier-1 auto-merge beside a tier-2 evidence row.
# TEST-CHANGE(BH-4581): wording only, tier logic unchanged
grep -q 'Tier 2 — risk class recorded' "$T/gh-body.txt" \
  && ok || bad "the rewritten body still claims the PR-open tier's merge path"
[ "$(grep -c . "$T/artifact.txt")" = 1 ] \
  && ok || bad "expected exactly one evidence ledger row, got: $(cat "$T/artifact.txt")"
grep -q '|2| | QA: SKIPPED' "$T/artifact.txt" \
  && ok || bad "the ledger row was not handed the settled tier and reason: $(cat "$T/artifact.txt")"
# The settled render re-derives the diff, so it reports the branch as it is now.
grep -q '| files | 1 changed, 2 planned, 0 unplanned |' "$T/gh-body.txt" \
  && ok || bad "the settled body did not re-derive the file list: $(grep '| files |' "$T/gh-body.txt")"

# 5b-2. THE ONE THAT MATTERS: a fix round commits between the two renders. The
#       PR-open list is two files and knows nothing about them; the settled row
#       has to count and name what the branch actually carries now, because a
#       build that was sent back is exactly the build this evidence is for.
drive 2 " | QA: SKIPPED — demoted to tier-2" FIXCOMMIT=1
grep -q '| files | 3 changed, 2 planned, 2 unplanned: `src/rogue/Extra.tsx src/rogue/Two.tsx`' "$T/gh-body.txt" \
  && ok || bad "the settled file list is the stale PR-open one: $(grep '| files |' "$T/gh-body.txt")"
grep -q '| files | 3 changed, 2 planned, 2 unplanned' "$T/build/evidence.md" \
  && ok || bad "evidence.md disagrees with the PR body about the diff: $(grep '| files |' "$T/build/evidence.md")"
[ "$(grep -c . "$T/build/changed-files.txt")" = 3 ] \
  && ok || bad "changed-files.txt was not refreshed at settle: $(cat "$T/build/changed-files.txt")"
[ -e "$T/build/changed-files.new" ] && bad "the settle refresh left its temp file behind" || ok

# 5b-3. THE SIZE DECLARATION ROW, THROUGH THE PRODUCTION RENDER POINTS (BH-612).
#       The gate no longer judges the file axis on the paths a plan merely
#       mentions, so the honest check is this one — and a row that only the
#       renderer's unit fixtures ever produce is a row no PR page carries. Both
#       renders are driven: PR-open reports the diff as it stood then, and the
#       settle render re-derives it, so a fix round that widened the diff past the
#       declaration is what the human reading the PR sees.
drive 1 ""
grep -qF '| size declaration | within — declared files=2, shipped 2 product file(s), tolerated limit 13 |' "$T/open-body.txt" \
  && ok || bad "the PR-open body carries no size declaration row: $(grep 'size declaration' "$T/open-body.txt")"
# Declared one file, tolerated one file, and the QA fix round pushes the diff to
# three: the settled body is where that has to show up.
printf 'SIZE_DECLARED: files=1 lines=20\nSIZE_LIMITS: lines=300 files=1\nSIZE_TOLERANCE: 15%% (lines<=345 files<=1 build whole)\nSIZE_VERDICT: within\n' \
  > "$B/size-gate.txt"
drive 2 " | QA: SKIPPED — demoted to tier-2" FIXCOMMIT=1
grep -qF 'SIZE_DECLARATION_EXCEEDED — declared files=1, shipped 3 product file(s), tolerated limit 1 (warn, not a block)' "$T/gh-body.txt" \
  && ok || bad "the settled PR body does not flag a diff that outgrew its declaration: $(grep 'size declaration' "$T/gh-body.txt")"
grep -qF 'SIZE_DECLARATION_EXCEEDED' "$T/build/evidence.md" \
  && ok || bad "evidence.md disagrees with the PR body about the size declaration"
# It is a WARNING: the tier it settled at is the QA demotion's, not this row's,
# and no terminal was written.
grep -q 'settled tier | 2 — QA: SKIPPED' "$T/gh-body.txt" \
  && ok || bad "the size declaration row moved the settled tier: $(grep 'settled tier' "$T/gh-body.txt")"
[ -e "$T/build/RESULT" ] && bad "the size declaration row wrote a RESULT" || ok
printf 'SIZE_DECLARED: files=2 lines=45\nSIZE_LIMITS: lines=300 files=12\nSIZE_TOLERANCE: 15%% (lines<=345 files<=13 build whole)\nSIZE_VERDICT: within\n' \
  > "$B/size-gate.txt"

# 5c. a failing `gh pr edit` costs the build nothing: the file and the row still
#     land, and the PR keeps its PR-open block.
drive 2 " | TESTS: no red proof — demoted to tier-2" GH_EDIT_RC=1
[ -s "$T/build/evidence.md" ] && ok || bad "a failed gh edit lost evidence.md"
[ "$(grep -c . "$T/artifact.txt")" = 1 ] \
  && ok || bad "a failed gh edit also lost the ledger row"
grep -q 'gh pr edit failed' "$T/build/pipeline.log" \
  && ok || bad "a failed gh edit was swallowed instead of logged"

# 5c-2. ...and a failed ledger put is logged too. Silence there is the one
#       failure mode nobody can diagnose from the record afterwards.
drive 2 "" PUT_RC=1
grep -q 'ledger row not written' "$T/build/pipeline.log" \
  && ok || bad "a failed evidence ledger put left nothing in the record"
[ -s "$T/build/evidence.md" ] && ok || bad "a failed ledger put also cost the PR its evidence file"

# 5c-3. a migration classifier that CRASHED never judged anything. MIG_NOTE is
#       set on any non-zero exit, so mapping it straight to `flagged` told the PR
#       page that statements sat outside the allowlist when nothing looked.
drive 1 "" ADDED_SQL="scripts/migrations/2026-09-06-x.sql" \
  MIG_NOTE=" | MIGRATION GATE: ? statement(s) outside the appliable allowlist — tier 2"
grep -q '| migration gate | gate-failed |' "$T/open-body.txt" \
  && ok || bad "a crashed migration classifier is reported as flagged SQL: $(grep -i migration "$T/open-body.txt")"
printf 'FLAGGED: DO $$ ... $$\n' > "$B/migration-gate.txt"
drive 1 "" ADDED_SQL="scripts/migrations/2026-09-06-x.sql" \
  MIG_NOTE=" | MIGRATION GATE: 1 statement(s) outside the appliable allowlist — tier 2"
grep -q '| migration gate | flagged |' "$T/open-body.txt" \
  && ok || bad "a real FLAGGED statement stopped reading flagged: $(grep -i migration "$T/open-body.txt")"
rm -f "$B/migration-gate.txt"

# 5c-4. the byte-count sentence this whole item was filed to delete is gone from
#       the body the block renders into — its numbers are rows now — and still
#       there when the block is switched off, where it is the only pointer left.
drive 1 ""
grep -q 'validate.txt (39B)' "$T/open-body.txt" \
  && bad "the byte-count verification sentence outlived its replacement" || ok
grep -q 'validate.txt .*B, .* recorded as NOT RUN' "$T/open-body.txt" \
  && ok || bad "the block does not carry the numbers the sentence used to: $(cat "$T/open-body.txt")"

# 5d. EVIDENCE_BLOCK=0 is the kill switch: no block, no file, no row, and the
#     rest of the PR body is untouched.
drive 1 "" EVIDENCE_BLOCK=0
grep -q '## Evidence' "$T/open-body.txt" \
  && bad "EVIDENCE_BLOCK=0 still put a block in the body" || ok
grep -q 'Generated with \[Claude Code\]' "$T/open-body.txt" \
  && ok || bad "the kill switch damaged the rest of the PR body"
[ -e "$T/build/evidence.md" ] && bad "EVIDENCE_BLOCK=0 still wrote evidence.md" || ok
[ -s "$T/artifact.txt" ] && bad "EVIDENCE_BLOCK=0 still wrote a ledger row" || ok
grep -q 'pr edit' "$T/gh-calls.txt" && bad "EVIDENCE_BLOCK=0 still edited the PR" || ok
grep -q 'validate.txt (39B)' "$T/open-body.txt" \
  && ok || bad "with the block off the body lost its only pointer to the evidence files"
# The claim rows render INSIDE the block, so the kill switch drops them with it.
grep -q '| claim ' "$T/open-body.txt" \
  && bad "EVIDENCE_BLOCK=0 still put acceptance-claim rows in the body" || ok

# ============================================================================
# 6. bin/jobs-client.sh — the row, through the real client
# ============================================================================
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
# Sourced from a driver file, never with `bash -c '. "$0"'`: jobs-client.sh runs
# its CLI dispatcher when BASH_SOURCE[0] equals $0, and that path would answer
# `usage` instead of calling the function under test.
cat > "$T/drive-jobs.sh" <<'EOF'
#!/bin/bash
. "$JC"
job_evidence_put "$1" "$2" "$3"
EOF
chmod +x "$T/drive-jobs.sh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""
while [ $# -gt 0 ]; do case "$1" in --data-binary) BODY="$2"; shift 2;; *) shift;; esac; done
printf '%s %s\n' "$URL" "$BODY" >> "$REQ_SINK"
printf '{"artifact":{"artifact_kind":"evidence"}}\n200\n'
EOF
chmod +x "$T/fakebin/curl"
: > "$T/req.txt"
( PATH="$T/fakebin:$PATH" HARNESS="$T" REQ_SINK="$T/req.txt" HARNESS_SECRET=test-secret \
  JOB_ID=job-1 JC="$T/bin/jobs-client.sh" bash "$T/drive-jobs.sh" "$B" 2 "QA: SKIPPED" ) >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "job_evidence_put failed against a healthy worker (rc=$RC)"
grep -q '/api/jobs/job-1/artifacts' "$T/req.txt" \
  && ok || bad "the evidence row did not go to the artifacts endpoint: $(cat "$T/req.txt")"
grep -q '"artifact_kind":"evidence"' "$T/req.txt" \
  && ok || bad "the row is not kind=evidence: $(cat "$T/req.txt")"
grep -q '"artifact_ref":"suite=0' "$T/req.txt" \
  && ok || bad "the artifact ref is not the digest: $(cat "$T/req.txt")"
# The ref column is capped at 1024 by the worker; a truncated ref is a truncated
# claim, so the renderer bounds it first.
REFLEN=$(jq -rn --arg s "$(sed -n '1p' "$T/req.txt")" '$s' | grep -oE '"artifact_ref":"[^"]*"' | wc -c)
[ "$REFLEN" -lt 1024 ] && ok || bad "the digest ref would be truncated by the worker ($REFLEN chars)"
# A build dir that does not exist is rc 1 and NO row: an evidence row nobody
# rendered would read as evidence.
: > "$T/req.txt"
( PATH="$T/fakebin:$PATH" HARNESS="$T" REQ_SINK="$T/req.txt" HARNESS_SECRET=test-secret \
  JOB_ID=job-1 JC="$T/bin/jobs-client.sh" bash "$T/drive-jobs.sh" "$T/nope" 2 "" ) >/dev/null 2>&1
[ "$?" = 1 ] && ok || bad "a missing build dir must return 1 from job_evidence_put"
[ -s "$T/req.txt" ] && bad "a missing build dir still wrote a row" || ok

# ============================================================================
# 7. the block is reachable where humans look
# ============================================================================
# A block only the build box can read is the byte count it replaced. The
# console's artifact fetch is a CLOSED set of literals, so evidence.md has to be
# in it on both sides or the FETCH button answers nothing.
[ "$("$DIR/bin/fetch-artifact.sh" --file evidence 2>/dev/null)" = evidence.md ] \
  && ok || bad "bin/fetch-artifact.sh cannot address evidence.md"
grep -q "'evidence'" "$DIR/console-ui/src/api.js" \
  && ok || bad "the console's ARTIFACT_KINDS has no evidence kind"

# ============================================================================
# 8. no secret reaches a log or the block
# ============================================================================
for F in "$T/logs/ALERTS.log" "$T/logs/jobs-client.log" "$T/build/pipeline.log" \
         "$T/build/evidence.md" "$T/gh-body.txt"; do
  [ -f "$F" ] || continue
  grep -q 'test-secret' "$F" && bad "HARNESS_SECRET reached $(basename "$F")" || ok
done

echo "evidence-block-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
