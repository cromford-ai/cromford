#!/bin/bash
# tests/size-gate-test.sh — how big is this change, who says so, and what
# happens when the answer is "too big"?
#
# WHY (the operator, 2026-09-12). Across 381 merged harness PRs the MEDIAN diff is 1,268
# lines changed. Large orgs land 100-300 line diffs, because review cost,
# conflict probability and re-review cost all grow superlinearly with size: a
# 1,200-line PR is not four times the work of a 300-line one to review, it is
# the one nobody reviews properly. The pipeline already had a decomposer
# (bin/run-decompose.sh, SCALE-PLAN wave 2) and it fired on exactly one input —
# a planner voluntarily writing `SIZE: XL` on the last line of its own plan.
# Self-reported, all-or-nothing, and unmeasured: an L plan that turns into 1,400
# lines was indistinguishable from an L plan that turns into 200.
#
# So: the plan DECLARES its size in a `## Size` section, in PRODUCT lines (the
# exclusion list lives in bin/size-scope.sh and nowhere else), and over the
# threshold the ticket is SPLIT instead of built. The FILE axis is that
# declaration and nothing else (BH-612): planned-files.txt is every path the
# plan MENTIONS, which serializes builds and never gates size, and an
# under-declaration is caught after execute against the real diff
# (tests/size-gate-mentions-test.sh and tests/evidence-block-test.sh).
#
# WHAT IS UNDER TEST, and why it is driven rather than grepped. `grep -q
# size-gate bin/run-build.sh` passes on a gate wired to the wrong default, on a
# threshold nobody can override, on an exclusion list that counts a lockfile as
# product code, and on a decompose call that runs AFTER the executor already
# built the thing. So: the three helpers against real inputs, and the shipped
# run-build blocks extracted VERBATIM by their markers and driven with the
# model call, the decomposer, the beat and the ledger stubbed.
#
# No network, no model call, no secrets. Run from anywhere:
#   tests/size-gate-test.sh          (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/h/bin" "$T/h/state" "$T/h/logs" "$T/h/flags" "$T/h/catalog"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

SCOPE="$DIR/bin/size-scope.sh"
THRESH="$DIR/bin/size-threshold.sh"
GATE="$DIR/bin/size-gate.sh"
for S in "$SCOPE" "$THRESH" "$GATE"; do
  [ -x "$S" ] && ok || bad "$(basename "$S") is missing or not executable"
done
for S in "$SCOPE" "$THRESH" "$GATE" "$DIR/bin/planned-files.sh"; do
  [ -f "$S" ] && cp "$S" "$T/h/bin/" 2>/dev/null
done

# ============================================================================
# 1. bin/size-scope.sh — ONE definition of "product code"
# ============================================================================
# The threshold is 300 lines of PRODUCT code, not 300 lines of diff. A wave that
# ships 250 lines of source with 400 lines of tests and a regenerated lockfile
# is a well-tested small change, and a gate that counts those is a gate that
# punishes writing tests. The list has to live in exactly one place or the plan
# side and the post-hoc side will disagree about what they measured.
prod()    { printf '%s\n' "$1" | "$SCOPE" --filter; }
isprod()  { [ "$(prod "$1")" = "$1" ]; }
for P in src/lib/foo.ts app/page.tsx bin/run-build.sh prisma/schema.prisma \
         scripts/migrations/0001_add_col.sql components/Table.tsx worker/index.js; do
  isprod "$P" || bad "size-scope must count $P as product code"
done
ok
for P in tests/size-gate-test.sh test/helper.rb src/lib/foo.test.ts \
         src/lib/foo.spec.tsx src/__tests__/foo.ts src/__mocks__/db.ts \
         e2e/checkout.spec.ts bin/foo_test.sh \
         README.md docs/RUN-BUILD-GRAPH.md tasks/plan/wave-1.md plan.md \
         .harness/specs/feature.md \
         package-lock.json yarn.lock pnpm-lock.yaml Cargo.lock go.sum \
         prisma/migrations/20260912_init/migration.sql \
         src/generated/client.ts src/api.generated.ts \
         src/__snapshots__/a.snap dist/bundle.js .next/static/x.js \
         public/app.min.js src/app.js.map; do
  ! isprod "$P" || bad "size-scope must EXCLUDE $P from the product-line count"
done
ok
# The list is readable, from the same place, so a doc or a reviewer never has to
# re-derive it from a case statement.
"$SCOPE" --rules 2>/dev/null | grep -q 'package-lock.json' \
  && ok || bad "--rules must print the exclusion list (it is the documentation)"
"$SCOPE" --rules 2>/dev/null | grep -q '\*.test\.' \
  && ok || bad "--rules must name the test-file exclusion"

# --filter is a filter: order preserved, nothing invented, empty in = empty out.
[ -z "$(printf '' | "$SCOPE" --filter)" ] && ok || bad "empty input must produce empty output"
OUTF=$(printf 'src/a.ts\nsrc/a.test.ts\nsrc/b.ts\n' | "$SCOPE" --filter | tr '\n' ' ')
[ "$OUTF" = "src/a.ts src/b.ts " ] && ok || bad "--filter dropped or reordered paths: '$OUTF'"

# --diff counts a REAL git diff, product only. The numbers a post-hoc guard
# demotes on cannot come from a parser nobody ran against git's actual output.
R="$T/repo"; mkdir -p "$R"
( cd "$R" && git init -q -b main . && git config user.email t@t && git config user.name t \
  && mkdir -p src tests && echo base > src/keep.ts && git add -A && git commit -qm base ) >/dev/null 2>&1
( cd "$R" && git checkout -qb feat \
  && { for i in $(seq 1 40); do echo "line $i"; done > src/feature.ts; } \
  && { for i in $(seq 1 90); do echo "test $i"; done > tests/feature.test.ts; } \
  && { for i in $(seq 1 500); do echo "lock $i"; done > package-lock.json; } \
  && echo doc > NOTES.md \
  && git add -A && git commit -qm feat ) >/dev/null 2>&1
D=$( cd "$R" && "$SCOPE" --diff main 2>&1 )
[ "$(sed -n 's/^SIZE_PRODUCT_LINES:[[:space:]]*//p' <<<"$D")" = 40 ] \
  && ok || bad "--diff must count ONLY the 40 product lines (got: $D)"
[ "$(sed -n 's/^SIZE_PRODUCT_FILES:[[:space:]]*//p' <<<"$D")" = 1 ] \
  && ok || bad "--diff must count ONLY the 1 product file (got: $D)"
# The excluded volume is REPORTED, never silently dropped: a reviewer reading
# "40 product lines" on a 630-line diff has to be able to see where the rest went.
grep -q '^SIZE_EXCLUDED_LINES: 591$' <<<"$D" \
  && ok || bad "--diff must report how many lines it excluded (got: $D)"
# A base that does not resolve is not "zero lines" — zero would read as a tiny,
# safe diff and quietly un-demote a 2,000-line PR.
( cd "$R" && "$SCOPE" --diff no-such-base >/dev/null 2>&1 ) \
  && bad "an unresolvable base must not exit 0" || ok
grep -q 'SIZE_PRODUCT_LINES: *0' <<<"$(cd "$R" && "$SCOPE" --diff no-such-base 2>&1)" \
  && bad "an unresolvable base must NOT report 0 product lines" || ok

# ============================================================================
# 2. bin/size-threshold.sh — DB-driven, per project, with a code fallback
# ============================================================================
# Per axis, first hit wins (BH-4985): settings rows size_gate.<axis>.<project>
# then size_gate.<axis>, then a box-local flag, then the repo-tracked conf, then
# the documented 700/20 fallback. The rows have their own suite
# (tests/size-threshold-settings.bh-4985-test.sh); every call here points
# HARNESS at the scratch tree, so a row on the live box can never move a pin.
[ "$(HARNESS="$T/h" JOBS_URL= "$THRESH" anything lines)" = 700 ] && ok || bad "the default line threshold must be 700"
[ "$(HARNESS="$T/h" JOBS_URL= "$THRESH" anything files)" = 20 ]  && ok || bad "the default file threshold must be 20"
[ "$(HARNESS="$T/h" JOBS_URL= "$THRESH" anything)" = "700 20" ]  && ok || bad "no field asked = '<lines> <files>'"

printf '# comment\nwidget-os 900 30\nother-os 120 5\n' > "$T/h/catalog/size-thresholds.conf"
[ "$(HARNESS="$T/h" "$THRESH" widget-os lines)" = 900 ] \
  && ok || bad "a catalog row must override the default"
[ "$(HARNESS="$T/h" "$THRESH" widget-os files)" = 30 ] \
  && ok || bad "a catalog row must carry the file limit too"
[ "$(HARNESS="$T/h" "$THRESH" unlisted-os lines)" = 700 ] \
  && ok || bad "a project with no row must get the default"
echo '150 4' > "$T/h/flags/size-gate-widget-os"
[ "$(HARNESS="$T/h" "$THRESH" widget-os lines)" = 150 ] \
  && ok || bad "a box-local flag must outrank the catalog row"
[ "$(HARNESS="$T/h" "$THRESH" widget-os files)" = 4 ] \
  && ok || bad "the flag's file limit must win too"
# A flag with only the line number keeps the catalog's file limit rather than
# silently resetting it to the default — half an override is not an override.
echo '150' > "$T/h/flags/size-gate-widget-os"
[ "$(HARNESS="$T/h" "$THRESH" widget-os files)" = 30 ] \
  && ok || bad "a lines-only flag must not reset the file limit to the default"
# Junk never becomes a threshold. A 0 or a word would disable the gate silently.
printf 'widget-os banana zero\n' > "$T/h/catalog/size-thresholds.conf"
rm -f "$T/h/flags/size-gate-widget-os"
[ "$(HARNESS="$T/h" "$THRESH" widget-os lines)" = 700 ] \
  && ok || bad "a non-numeric conf value must fall back to the default"

# ============================================================================
# 3. bin/size-gate.sh — the plan declares its size, and the plan is checked
# ============================================================================
plan() { # plan <size-section-or-empty> [file-list-lines...]
  { echo '# Plan'; echo; echo '### Task 1 — do it'
    echo '- VALIDATE: npm test'; echo '- SATISFIES: criterion 1'; echo
    [ -n "$1" ] && printf '%s\n' "$1"
    echo; echo 'KIND: feature'; echo 'SIZE: M'; } > "$T/plan.md"
}
SIZED='## Size
FILES: 6
LINES: 240'
plan "$SIZED"; G=$("$GATE" "$T/plan.md" 300 12 2>&1); GRC=$?
[ "$GRC" = 0 ] && ok || bad "a plan under both limits must exit 0 (rc=$GRC: $G)"
grep -q '^SIZE_VERDICT: within$' <<<"$G" && ok || bad "verdict must be 'within': $G"
grep -q '^SIZE_LINES: 240$'     <<<"$G" && ok || bad "the declared line count must be reported: $G"
grep -q '^SIZE_FILES: 6$'       <<<"$G" && ok || bad "the declared file count must be reported: $G"
grep -q '^SIZE_LIMITS: lines=300 files=12$' <<<"$G" \
  && ok || bad "the limits it judged against must be on the record: $G"

# Over on lines.
plan '## Size
FILES: 6
LINES: 900'
G=$("$GATE" "$T/plan.md" 300 12 2>&1); GRC=$?
[ "$GRC" = 2 ] && ok || bad "an over-threshold plan must exit 2 (rc=$GRC: $G)"
grep -q '^SIZE_VERDICT: over$' <<<"$G" && ok || bad "verdict must be 'over': $G"
grep -q 'lines=900>300' <<<"$G"        && ok || bad "SIZE_OVER must name the axis and the numbers: $G"

# TOLERANCE BAND (the operator, 2026-09-16): 310 against 300 is not a split. Up to 15%
# over either nominal limit builds whole, named on the record; above the band
# it is over, and the SIZE_OVER line still quotes the NOMINAL limit so the
# ledger reads the same as before.
plan '## Size
FILES: 13
LINES: 310'
G=$("$GATE" "$T/plan.md" 300 12 2>&1); GRC=$?
[ "$GRC" = 0 ] && ok || bad "310/300 and 13/12 must build whole inside the tolerance band (rc=$GRC: $G)"
grep -q '^SIZE_VERDICT: within$' <<<"$G" && ok || bad "a tolerated plan is 'within': $G"
grep -q '^SIZE_TOLERATED: lines=310>300; files=13>12' <<<"$G" \
  && ok || bad "the overshoot must be named on the record: $G"
grep -q '^SIZE_TOLERANCE: 15% (lines<=345 files<=13 build whole)$' <<<"$G" \
  && ok || bad "the band itself must be on the record: $G"
plan '## Size
FILES: 6
LINES: 345'
[ "$("$GATE" "$T/plan.md" 300 12 2>&1 | sed -n 's/^SIZE_VERDICT: //p')" = within ] \
  && ok || bad "345 is the top of the 15% band on 300 and must build whole"
plan '## Size
FILES: 6
LINES: 346'
G=$("$GATE" "$T/plan.md" 300 12 2>&1); GRC=$?
[ "$GRC" = 2 ] && ok || bad "346 is past the band and must be over (rc=$GRC: $G)"
grep -q 'lines=346>300' <<<"$G" && ok || bad "SIZE_OVER quotes the nominal limit: $G"
plan '## Size
FILES: 6
LINES: 310'
G=$(SIZE_GATE_TOLERANCE_PCT=0 "$GATE" "$T/plan.md" 300 12 2>&1); GRC=$?
[ "$GRC" = 2 ] && ok || bad "SIZE_GATE_TOLERANCE_PCT=0 must restore the hard line (rc=$GRC: $G)"
G=$(SIZE_GATE_TOLERANCE_PCT=junk "$GATE" "$T/plan.md" 300 12 2>&1); GRC=$?
[ "$GRC" = 0 ] && ok || bad "a garbage tolerance falls back to the 15% default (rc=$GRC: $G)"

# Over on files, under on lines: either axis is enough.
plan '## Size
FILES: 20
LINES: 100'
G=$("$GATE" "$T/plan.md" 300 12 2>&1); GRC=$?
[ "$GRC" = 2 ] && ok || bad "too many files must trip the gate on its own (rc=$GRC: $G)"
grep -q 'files=20>12' <<<"$G" && ok || bad "SIZE_OVER must name the file axis: $G"

# A plan with NO size declaration is ESTIMATED — never "within", never declared.
# TEST-CHANGE BH-5292: this was "exit 3, undeclared" (a malformed plan). the operator
# changed the rule (2026-10-07): a missing `## Size` is a warning and the size is
# estimated from the plan's file list. What this block guards is unchanged: an
# unmeasured size never reads as a DECLARED or a `within` verdict, and it says
# out loud that it is an estimate.
plan ''
G=$("$GATE" "$T/plan.md" 300 12 2>&1); GRC=$?
[ "$GRC" = 0 ] && ok || bad "a plan with no ## Size section proceeds, rc 0 (rc=$GRC: $G)"
grep -q '^SIZE_VERDICT: estimated$' <<<"$G" && ok || bad "verdict must be 'estimated': $G"
grep -q '^SIZE_GATE_WARNING: ' <<<"$G" && ok || bad "the missing section must be a WARNING line: $G"
grep -q '^SIZE_DECLARED:' <<<"$G" && bad "an estimate must never print a declaration: $G" || ok
grep -qi 'within' <<<"$(sed -n 's/^SIZE_VERDICT: //p' <<<"$G")" \
  && bad "an undeclared size must never read as within" || ok

# Half a declaration is still not a declaration.
plan '## Size
LINES: 100'
G=$("$GATE" "$T/plan.md" 300 12 2>&1); GRC=$?
grep -q '^SIZE_VERDICT: estimated$' <<<"$G" && ok || bad "a ## Size section missing FILES must be estimated, not declared (rc=$GRC: $G)"

# Written by a model, so parsed forgivingly — the shapes plans on this box
# actually use: bullets, bold, a tilde, thousands separators, lower case.
plan '## Size
- **files**: 6
- **lines**: ~1,200'
G=$("$GATE" "$T/plan.md" 300 12 2>&1); GRC=$?
[ "$GRC" = 2 ] && ok || bad "bulleted/bold/approximate numbers must still parse (rc=$GRC: $G)"
grep -q '^SIZE_LINES: 1200$' <<<"$G" && ok || bad "a thousands separator must not become 1: $G"
plan '## Size estimate
FILES: 2
LINES: 30'
[ "$("$GATE" "$T/plan.md" 300 12 2>&1 | sed -n 's/^SIZE_VERDICT: //p')" = within ] \
  && ok || bad "'## Size estimate' must be recognised as the size section"

# A FILES: line in a FENCED BLOCK is a sample, not a declaration — the same rule
# bin/plan-gate.sh applies to VALIDATE:.
plan '## Notes
```
FILES: 3
LINES: 10
```'
# TEST-CHANGE BH-5292: undeclared -> estimated (see above); the guard is the same.
[ "$("$GATE" "$T/plan.md" 300 12 2>&1 | sed -n 's/^SIZE_VERDICT: //p')" = estimated ] \
  && ok || bad "a fenced sample must not count as the size declaration"

# THE FILE AXIS IS THE DECLARATION (BH-612, 2026-09-16 — this block used to
# assert the opposite). The idea was that the line count cannot be checked at
# plan time but the FILE count can, against planned-files.txt. It cannot: that
# file is built by bin/planned-files.sh, whose own header calls itself a
# deliberate over-listing for conflict serialization — it scrapes every path the
# plan MENTIONS, callers and out-of-scope lists included. So the "corroboration"
# was a count of prose. project-5 #1906 declared files=2 lines=45 and was
# decomposed into two children on 18 mentions; #1907 the same on 16.
# Now: the DECLARED count gates, the superset stays on the record as
# SIZE_FILES_PLANNED and is named SIZE_FILES_MENTIONED when it is over the
# tolerated limit, and an UNDER-declaration is caught after execute against the
# real diff (bin/evidence-summary.sh's SIZE_DECLARATION_EXCEEDED row).
# tests/size-gate-mentions-test.sh drives the whole split; this block pins that
# the old behaviour is gone.
plan '## Size
FILES: 3
LINES: 100'
{ for i in $(seq 1 20); do echo "src/mod$i.ts"; done
  for i in $(seq 1 30); do echo "src/mod$i.test.ts"; done; } > "$T/planned.txt"
G=$("$GATE" "$T/plan.md" 300 12 "$T/planned.txt" 2>&1); GRC=$?
[ "$GRC" = 0 ] && ok || bad "the mention superset must NOT trip the gate on its own (rc=$GRC: $G)"
grep -q '^SIZE_VERDICT: within$' <<<"$G" \
  && ok || bad "a plan declaring 3 files and 100 lines is within, whatever it mentions: $G"
grep -q 'plan file list' <<<"$G" \
  && bad "the superset still produced a SIZE_OVER/SIZE_TOLERATED line: $G" || ok
grep -q '^SIZE_FILES_PLANNED: 20$' <<<"$G" \
  && ok || bad "the mechanical product-file count must still be on the record: $G"
grep -q '^SIZE_FILES_MENTIONED: 20 (not gating)$' <<<"$G" \
  && ok || bad "a superset over the tolerated file limit must say it is not gating: $G"
# ...and an honest small plan is not tripped by its own tests.
plan '## Size
FILES: 3
LINES: 100'
{ echo src/a.ts; echo src/b.ts; echo src/c.ts
  for i in $(seq 1 30); do echo "src/mod$i.test.ts"; done; } > "$T/planned.txt"
[ "$("$GATE" "$T/plan.md" 300 12 "$T/planned.txt" 2>&1 | sed -n 's/^SIZE_VERDICT: //p')" = within ] \
  && ok || bad "30 test files must not push a 3-file plan over the file limit"
# A missing file list is not evidence of anything.
[ "$("$GATE" "$T/plan.md" 300 12 "$T/nope.txt" 2>&1 | sed -n 's/^SIZE_VERDICT: //p')" = within ] \
  && ok || bad "an absent planned-files.txt must not change the verdict"
# No plan at all: unavailable, exit 3, never a pass.
[ "$("$GATE" "$T/no-plan.md" 300 12 2>&1 | sed -n 's/^SIZE_VERDICT: //p')" = undeclared ] \
  && ok || bad "a missing plan must not read as within-threshold"

# ============================================================================
# 4. bin/run-build.sh — the size gate block, driven
# ============================================================================
awk '/^# >>> plan gate/{f=1;next} /^# <<< plan gate/{exit} f' \
  "$RB_ALL" > "$T/planblock.sh"
awk '/^# >>> size gate/{f=1;next} /^# <<< size gate/{exit} f' \
  "$RB_ALL" > "$T/sizeblock.sh"
[ -s "$T/sizeblock.sh" ] && ok || bad "could not extract the size-gate block — markers missing?"
# ONE switch, ONE implementation (2026-09-14). Both halves of this gate — the
# plan-time split and the post-hoc demotion at PR-open — resolve "is it armed?"
# through the same marked function, or a build splits at plan time and then says
# enforcement is off in its own PR body. Lifting it by its markers is also the
# check that it HAS markers, the same shape as the shared PLAN_MALFORMED
# terminal below.
awk '/^# >>> size enforce switch/{f=1;next} /^# <<< size enforce switch/{exit} f' \
  "$RB_ALL" > "$T/switch.sh"
[ -s "$T/switch.sh" ] && ok || bad "the enforce switch must live in its own marked region"
grep -q 'SG_SWITCH_RESOLVE' "$T/sizeblock.sh" \
  && ok || bad "the size gate must resolve the switch through the shared function"
# The PLAN_MALFORMED terminal is ONE implementation shared by both gates: an
# unsized plan and an untraced plan are the same class of defect (a spec the
# pipeline cannot check), and two copies of "requeue once then hold a human"
# would drift.
grep -q 'PM_TERMINAL' "$T/planblock.sh" \
  && ok || bad "the plan-gate block must define the shared PLAN_MALFORMED terminal"
grep -q 'PM_TERMINAL' "$T/sizeblock.sh" \
  && ok || bad "the size gate must reuse that terminal, not invent a second one"

# A decomposer stub that records its call and files one child.
cat > "$T/h/bin/run-decompose.sh" <<'EOS'
#!/bin/bash
echo "$*" >> "$DECOMPOSE_LOG"
[ "${DECOMPOSE_FAILS:-0}" = 1 ] && exit 1
printf 'WD-9.1\nWD-9.2\n' > "$4/children.txt"
exit 0
EOS
chmod +x "$T/h/bin/run-decompose.sh"

drive() { # drive <plan-text> [env...]
  local body="$1"; shift
  rm -rf "$T/b"; mkdir -p "$T/b"
  printf '%s\n' "$body" > "$T/b/plan.md"
  : > "$T/decompose.log"
  ( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 TICKET=tkt-1 \
        ALERTS="$T/h/logs/ALERTS.log" JOB_ID=job-1 SINK=/dev/null \
        DECOMPOSE_LOG="$T/decompose.log" SWITCHBLOCK="$T/switch.sh" "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT=$*"; }
             BB() { echo "BB=$1"; }
             job_artifact_put() { printf "%s\t%s\n" "$1" "$3" >> "$SINK"; }
             . "$SWITCHBLOCK"
             . "$0"; echo "CONTINUED"' "$T/sizeblock.sh" 2>&1 )
}
BODY() { # BODY <size-section> [final-size-line]
  printf '# Plan\n\n### Task 1\n- VALIDATE: npm test\n- SATISFIES: c1\n\n%s\n\nKIND: feature\nSIZE: %s\n' \
    "$1" "${2:-M}"
}
decomposed() { [ -s "$T/decompose.log" ]; }
# The depth-1 guard reads the TICKET's own title (run-build.sh writes
# $BUILD/ticket-meta.json before PLAN on both lanes), so a drive that exercises
# it has to lay one down AFTER drive() has cleared the dir.
drive_meta() { # drive_meta <ticket-title> <plan-text> [env...]
  local title="$1" body="$2"; shift 2
  rm -rf "$T/b"; mkdir -p "$T/b"
  printf '%s\n' "$body" > "$T/b/plan.md"
  printf '{"title":%s,"labels":[]}' "$(jq -Rn --arg t "$title" '$t')" > "$T/b/ticket-meta.json"
  : > "$T/decompose.log"
  ( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 TICKET=tkt-1 \
        ALERTS="$T/h/logs/ALERTS.log" JOB_ID=job-1 SINK=/dev/null \
        DECOMPOSE_LOG="$T/decompose.log" SWITCHBLOCK="$T/switch.sh" "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT=$*"; }
             BB() { echo "BB=$1"; }
             job_artifact_put() { :; }
             . "$SWITCHBLOCK"
             . "$0"; echo "CONTINUED"' "$T/sizeblock.sh" 2>&1 )
}
rm -f "$T/h/catalog/size-thresholds.conf" "$T/h/flags/size-gate-widget-os"

# 4a. under the threshold: the build carries on, nothing is split, and the size
#     is on the record anyway — a row written only on failure would make "no
#     row" mean both "small" and "old box".
: > "$T/artifacts.tsv"
OUT=$(drive "$(BODY '## Size
FILES: 4
LINES: 120')" SINK="$T/artifacts.tsv")
grep -q CONTINUED <<<"$OUT" && ok || bad "an in-threshold plan must reach EXECUTE (got: $OUT)"
decomposed && bad "an in-threshold plan must not be decomposed" || ok
[ "$(cut -f1 "$T/artifacts.tsv" | head -1)" = size_gate ] \
  && ok || bad "every build must record its size_gate row: $(cat "$T/artifacts.tsv")"
[ "$(jq -r '.verdict' <<<"$(cut -f2 "$T/artifacts.tsv" | head -1)")" = within ] \
  && ok || bad "the row lost the verdict: $(cat "$T/artifacts.tsv")"

# 4a-i. A PROSE-HEAVY PLAN IS NOT A BIG PLAN (BH-612), through the REAL block:
#       the shipped run-build lines, the real bin/planned-files.sh run on the
#       plan, the real gate. Same declaration as 4a, but the body names 18
#       product paths as callers and out-of-scope — the shape that decomposed
#       project-5 #1906 (files=2 lines=45, gate counted 18) into TK-1921/TK-1922
#       and #1907 into TK-1919/TK-1920 on one night. It must reach EXECUTE,
#       split nothing, and carry the mention count as informational only.
: > "$T/artifacts.tsv"
MENTIONY=$( printf '# Plan\n\n## Callers I read\n'
            for i in $(seq 1 10); do printf -- '- src/api/route%s.ts calls it\n' "$i"; done
            printf '\n## Out of scope\n'
            for i in $(seq 1 8); do printf -- '- src/legacy/old%s.ts keeps its copy\n' "$i"; done
            printf '\n### Task 1\n- VALIDATE: npm test\n- SATISFIES: c1\n\n## Size\nFILES: 2\nLINES: 45\n\nKIND: bug\nSIZE: S\n' )
# Pinned at the 12-file limit those incidents ran under: the mention line only
# prints above the tolerated file limit, and 18 is under the 700/20 default's 23.
printf 'widget-os 300 12\n' > "$T/h/catalog/size-thresholds.conf"
OUT=$(drive "$MENTIONY" SINK="$T/artifacts.tsv" SIZE_GATE_ENFORCE=1)
rm -f "$T/h/catalog/size-thresholds.conf"
grep -q CONTINUED <<<"$OUT" \
  && ok || bad "a 45-line plan that MENTIONS 18 paths must reach EXECUTE (got: $OUT)"
decomposed && bad "a plan inside its declared limits must not be split on its prose" || ok
[ "$(grep -c . "$T/b/planned-files.txt")" = 18 ] \
  && ok || bad "the fixture is not exercising the superset: $(cat "$T/b/planned-files.txt")"
grep -q '^SIZE_FILES_MENTIONED: 18 (not gating)$' "$T/b/size-gate.txt" \
  && ok || bad "the record must name the mention count as not gating: $(cat "$T/b/size-gate.txt")"
grep -q '^SIZE_VERDICT: within$' "$T/b/size-gate.txt" \
  && ok || bad "the record's verdict must be within: $(cat "$T/b/size-gate.txt")"
[ "$(jq -r '.verdict' <<<"$(cut -f2 "$T/artifacts.tsv" | head -1)")" = within ] \
  && ok || bad "the ledger row must say within: $(cat "$T/artifacts.tsv")"
[ "$(jq -r '.over // ""' <<<"$(cut -f2 "$T/artifacts.tsv" | head -1)")" = "" ] \
  && ok || bad "the ledger row carries an over reason for a plan nothing was over: $(cat "$T/artifacts.tsv")"

# 4b. OVER the threshold with the gate ARMED: the plan is handed to the
#     decomposer and the build STOPS. This is the item — decomposition as the
#     default above a size, not an XL-only escape hatch.
OUT=$(drive "$(BODY '## Size
FILES: 6
LINES: 900')" SIZE_GATE_ENFORCE=1)
grep -q CONTINUED <<<"$OUT" && bad "an over-threshold plan must NOT reach EXECUTE (got: $OUT)" || ok
decomposed && ok || bad "an over-threshold plan must be handed to the decomposer"
grep -q 'widget-os tkt-1 WD-9' "$T/decompose.log" \
  && ok || bad "the decomposer must get project/ticket/key/build-dir: $(cat "$T/decompose.log")"
grep -q 'RESULT=DECOMPOSED WD-9.1,WD-9.2' <<<"$OUT" \
  && ok || bad "the terminal must be the EXISTING DECOMPOSED verb with the children (got: $OUT)"
# The decomposer must be TOLD the budget, or the children come back the same
# size as the parent and the split bought nothing.
grep -qE '(^| )700( |$)' "$T/decompose.log" \
  && ok || bad "the decomposer must be handed the per-child line budget: $(cat "$T/decompose.log")"

# 4c. a decomposer that cannot file children says so, and does not fall through
#     into building the oversized thing anyway.
OUT=$(drive "$(BODY '## Size
FILES: 6
LINES: 900')" SIZE_GATE_ENFORCE=1 DECOMPOSE_FAILS=1)
grep -q 'RESULT=DECOMPOSE_FAILED' <<<"$OUT" && ok || bad "a failed split must be its own terminal (got: $OUT)"
grep -q CONTINUED <<<"$OUT" && bad "a failed split must not build the oversized plan (got: $OUT)" || ok

# 4d. THE SHIPPED DEFAULT IS ARMED (the operator, 2026-09-14). With nothing set at all,
#     an oversized plan is SPLIT. Warn-only ran for two days and did exactly what
#     it promised: it measured TK-552 at 1,900 product lines across 18 files and
#     watched it build whole in one 33-minute execute.
rm -f "$T/h/flags/size-gate-enforce-off"
OUT=$(drive "$(BODY '## Size
FILES: 6
LINES: 900')")
grep -q CONTINUED <<<"$OUT" && bad "the shipped default must NOT build an oversized plan whole (got: $OUT)" || ok
decomposed && ok || bad "with nothing set, an over-threshold plan must be split"
grep -q 'RESULT=DECOMPOSED' <<<"$OUT" && ok || bad "the default path must reach the DECOMPOSED terminal (got: $OUT)"
grep -q 'enforcement ON, from the shipped default' "$T/b/pipeline.log" \
  && ok || bad "the log must name which lever armed it: $(cat "$T/b/pipeline.log" 2>/dev/null)"

# 4d-i. THE FLEET KILL FLAG. flags/size-gate-enforce-off restores exactly what
#       the fleet did before the default flipped: the oversized plan is named in
#       the log and built whole. No deploy, no env edit, one file.
: > "$T/h/flags/size-gate-enforce-off"
OUT=$(drive "$(BODY '## Size
FILES: 6
LINES: 900')")
grep -q CONTINUED <<<"$OUT" && ok || bad "the kill flag must let an oversized plan build (got: $OUT)"
decomposed && bad "the kill flag must not split anything" || ok
grep -q 'decomposable, but size enforcement is OFF' "$T/b/pipeline.log" \
  && ok || bad "a warn-only run must say so in the pipeline log: $(cat "$T/b/pipeline.log" 2>/dev/null)"
grep -q 'flags/size-gate-enforce-off' "$T/b/pipeline.log" \
  && ok || bad "the log must name the lever that disarmed it: $(cat "$T/b/pipeline.log" 2>/dev/null)"
grep -q '900' "$T/b/pipeline.log" \
  && ok || bad "the warning must carry the number that would have tripped it"
# ...and it outranks an env var that says otherwise. The flag is the lever a box
# has when nobody can push, so nothing may override it.
OUT=$(drive "$(BODY '## Size
FILES: 6
LINES: 900')" SIZE_GATE_ENFORCE=1)
grep -q CONTINUED <<<"$OUT" && ok || bad "the kill flag must outrank SIZE_GATE_ENFORCE=1 (got: $OUT)"
rm -f "$T/h/flags/size-gate-enforce-off"

# 4d-ii. THE PER-PROJECT OVERRIDE. A repo whose changes are honestly wide opts
#        out on its own, in env/<project>.env, without disarming the fleet — the
#        same per-project shape the THRESHOLD already has.
OUT=$(drive "$(BODY '## Size
FILES: 6
LINES: 900')" SIZE_GATE_ENFORCE_WIDGET_OS=0)
grep -q CONTINUED <<<"$OUT" && ok || bad "SIZE_GATE_ENFORCE_<project>=0 must disarm this project (got: $OUT)"
decomposed && bad "a project that opted out must not be split" || ok
grep -q 'SIZE_GATE_ENFORCE_WIDGET_OS' "$T/b/pipeline.log" \
  && ok || bad "the log must name the override that disarmed it: $(cat "$T/b/pipeline.log" 2>/dev/null)"
# ...and it outranks the global switch, which is the point of having it.
OUT=$(drive "$(BODY '## Size
FILES: 6
LINES: 900')" SIZE_GATE_ENFORCE_WIDGET_OS=0 SIZE_GATE_ENFORCE=1)
grep -q CONTINUED <<<"$OUT" && ok || bad "the project override must beat the global switch (got: $OUT)"
# A project whose name IS a shell identifier is read verbatim too — env files are
# written by hand, and `SIZE_GATE_ENFORCE_project-5=0` is what a person types.
OUT=$( rm -rf "$T/b"; mkdir -p "$T/b"; : > "$T/decompose.log"
       printf '%s\n' "$(BODY '## Size
FILES: 6
LINES: 900')" > "$T/b/plan.md"
       env HARNESS="$T/h" BUILD="$T/b" PROJECT=project-5 KEY=TK-9 TICKET=9 \
           ALERTS="$T/h/logs/ALERTS.log" SINK=/dev/null DECOMPOSE_LOG="$T/decompose.log" \
           SWITCHBLOCK="$T/switch.sh" SIZE_GATE_ENFORCE_project-5=0 \
       bash -c 'set -uo pipefail
                STAMP() { echo TS; }
                RESULT() { echo "RESULT=$*"; }
                BB() { echo "BB=$1"; }
                job_artifact_put() { :; }
                . "$SWITCHBLOCK"
                . "$0"; echo CONTINUED' "$T/sizeblock.sh" 2>&1 )
grep -q CONTINUED <<<"$OUT" && ok || bad "the lower-case project override must be read too (got: $OUT)"

# 4e. an unrecognised switch value is NOT a switch value: it is ignored, the next
#     source is read, and it raises an ALERTS line. That reasoning inverted with
#     the default — while the gate was off a typo must not ARM something that
#     withholds a build, and now that it is on a typo must not silently DISARM
#     the fleet's only defence against a 1,900-line PR. It is the same rule
#     bin/size-threshold.sh applies to a junk threshold.
: > "$T/h/logs/ALERTS.log"
OUT=$(drive "$(BODY '## Size
FILES: 6
LINES: 900')" SIZE_GATE_ENFORCE=maybe)
grep -q CONTINUED <<<"$OUT" && bad "a junk switch value must not disarm the gate (got: $OUT)" || ok
decomposed && ok || bad "a junk switch value must fall through to the armed default"
grep -q "SIZE_GATE_ENFORCE='maybe' is not a recognized" "$T/h/logs/ALERTS.log" \
  && ok || bad "a junk switch value must raise an ALERTS line"
grep -q 'size-gate-enforce-off' "$T/h/logs/ALERTS.log" \
  && ok || bad "the ALERTS line must say how to actually turn it off"
# A junk PROJECT override still lets the global switch be read — falling through
# is the whole behaviour, not a special case of the global name.
OUT=$(drive "$(BODY '## Size
FILES: 6
LINES: 900')" SIZE_GATE_ENFORCE_WIDGET_OS=nope SIZE_GATE_ENFORCE=0)
grep -q CONTINUED <<<"$OUT" && ok || bad "a junk override must fall through to the next source (got: $OUT)"

# 4e-i. DEPTH 1, AND ONLY DEPTH 1. bin/run-decompose.sh titles every child
#       '<PARENT KEY>.<n>: ...', so a child that itself sizes over the threshold
#       is built whole with a note rather than split again. Without this, one bad
#       estimate files tickets forever.
OVERSIZED=$(BODY '## Size
FILES: 6
LINES: 900')
OUT=$(drive_meta "WD-9.1: the first slice" "$OVERSIZED")
grep -q CONTINUED <<<"$OUT" && ok || bad "an oversized CHILD must be built whole (got: $OUT)"
decomposed && bad "a split child must never be split again" || ok
grep -qi 'already a split child' "$T/b/pipeline.log" \
  && ok || bad "building a child whole must leave a one-line note: $(cat "$T/b/pipeline.log" 2>/dev/null)"
# An ordinary ticket whose title merely carries a version number is not a child.
OUT=$(drive_meta "Upgrade to Next 15.2 across the app" "$OVERSIZED")
decomposed && ok || bad "a version number in a title must not read as a split child"
# ...and the guard is armed-only, so the kill flag leaves the XL path exactly as
# it was: a child that declares itself XL still splits under the flag.
: > "$T/h/flags/size-gate-enforce-off"
OUT=$(drive_meta "WD-9.1: the first slice" "$(BODY '## Size
FILES: 2
LINES: 40' XL)")
decomposed && ok || bad "with the kill flag set, SIZE: XL must split exactly as it did before"
rm -f "$T/h/flags/size-gate-enforce-off"

# 4f. MEASURED BEATS SELF-REPORTED (the operator, 2026-09-16). Armed, a plan the gate
#     measured `within` builds whole even when its planner wrote SIZE: XL —
#     BH-597 declared 210 lines and was split on its T-shirt line alone.
OUT=$(drive "$(BODY '## Size
FILES: 2
LINES: 40' XL)")
decomposed && bad "armed, SIZE: XL on a plan measured within must NOT split (got: $OUT)" || ok
grep -q CONTINUED <<<"$OUT" && ok || bad "the overridden XL path must continue the build (got: $OUT)"
grep -qi 'measured beats self-reported' "$T/b/pipeline.log" \
  && ok || bad "overriding XL must leave a one-line note: $(cat "$T/b/pipeline.log" 2>/dev/null)"
#     Armed and OVER, XL and the gate agree: it splits.
OUT=$(drive "$(BODY '## Size
FILES: 2
LINES: 900' XL)")
decomposed && ok || bad "armed and over, SIZE: XL must still decompose"
#     Disarmed, XL keeps its old power: the self-reported marker was the only
#     trigger this pipeline had since 2026-07-28, and the kill flag promises
#     byte-for-byte the old behaviour.
: > "$T/h/flags/size-gate-enforce-off"
OUT=$(drive "$(BODY '## Size
FILES: 2
LINES: 40' XL)")
decomposed && ok || bad "disarmed, SIZE: XL must still decompose regardless of the measured size"
grep -q 'RESULT=DECOMPOSED' <<<"$OUT" && ok || bad "the disarmed XL path must keep its terminal (got: $OUT)"
rm -f "$T/h/flags/size-gate-enforce-off"

# 4g. NO ## Size section. TEST-CHANGE BH-5292: armed, this was PLAN_MALFORMED
#     (requeued once, then a human). the operator changed the rule (2026-10-07): it is a
#     WARNING, the size is estimated from the plan's file list and the build
#     continues, armed or not. What still ends at PLAN_MALFORMED is a plan the
#     gate cannot read at all, pinned below with an empty plan.md.
cat > "$T/drive-pm.sh" <<'EOS'
set -uo pipefail
STAMP() { echo TS; }
RESULT() { echo "RESULT=$*"; }
BB() { echo "BB=$1"; }
# The size block buys no model call since BH-5292; the stub records one if it
# ever does, so a regression to a repair pass shows up in the output.
CC() { echo "CC-CALLED"; }
job_artifact_put() { :; }
. "$PLANBLOCK_FNS"
. "$SWITCHBLOCK"
. "$SIZEBLOCK"
echo CONTINUED
EOS
# Only the shared terminal is needed from the plan-gate block, and sourcing the
# whole block would run the trace gate too — so the function is lifted out by
# its own markers, which is also a check that it HAS its own markers.
awk '/^# >>> plan malformed terminal/{f=1;next} /^# <<< plan malformed terminal/{exit} f' \
  "$RB_ALL" > "$T/pmfn.sh"
[ -s "$T/pmfn.sh" ] && ok || bad "the shared PLAN_MALFORMED terminal must have its own markers"

drive_pm() { # drive_pm [env...]   (PM_EMPTY=1: an empty plan.md)
  rm -rf "$T/b"; mkdir -p "$T/b"
  if [ "${PM_EMPTY:-0}" = 1 ]; then : > "$T/b/plan.md"; else printf '%s\n' "$(BODY '')" > "$T/b/plan.md"; fi
  : > "$T/decompose.log"
  ( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 TICKET=tkt-1 \
        ALERTS="$T/h/logs/ALERTS.log" JOB_ID=job-1 DECOMPOSE_LOG="$T/decompose.log" \
        PLAN_MODEL=stub-model \
        PLANBLOCK_FNS="$T/pmfn.sh" SIZEBLOCK="$T/sizeblock.sh" SWITCHBLOCK="$T/switch.sh" "$@" \
    bash "$T/drive-pm.sh" 2>&1 )
}
rm -f "$T/h/state/plan-malformed.txt"
OUT=$(drive_pm SIZE_GATE_ENFORCE=1)
grep -q CONTINUED <<<"$OUT" && ok || bad "armed, an unsized plan must reach EXECUTE with a warning (got: $OUT)"
grep -q 'RESULT=' <<<"$OUT" && bad "armed, an unsized plan must write no terminal (got: $OUT)" || ok
grep -q CC-CALLED <<<"$OUT" && bad "an unsized plan must buy no model session (got: $OUT)" || ok
grep -q "SIZE WARNING: the plan declares no '## Size' section" "$T/b/pipeline.log" \
  && ok || bad "the warning must be in the log: $(cat "$T/b/pipeline.log" 2>/dev/null)"
[ ! -s "$T/h/state/plan-malformed.txt" ] && ok || bad "an unsized plan must leave no malformed row: $(cat "$T/h/state/plan-malformed.txt")"
OUT=$(drive_pm SIZE_GATE_ENFORCE=0)
grep -q CONTINUED <<<"$OUT" && ok || bad "disarmed, an unsized plan must still build (got: $OUT)"
grep -q 'RESULT=' <<<"$OUT" && bad "disarmed, nothing may be terminated (got: $OUT)" || ok
grep -qi 'no .*Size' "$T/b/pipeline.log" \
  && ok || bad "an unsized plan must be visible in the log: $(cat "$T/b/pipeline.log" 2>/dev/null)"
# ...and with NOTHING set, the shipped default, the same.
OUT=$(drive_pm)
grep -q CONTINUED <<<"$OUT" && ok || bad "by default an unsized plan builds with a warning (got: $OUT)"
# A plan the gate cannot read at all is still malformed, requeued once then held.
rm -f "$T/h/state/plan-malformed.txt"
OUT=$(PM_EMPTY=1 drive_pm SIZE_GATE_ENFORCE=1)
grep -q CONTINUED <<<"$OUT" && bad "an empty plan.md must not reach EXECUTE when armed (got: $OUT)" || ok
grep -q 'RESULT=PLAN_MALFORMED' <<<"$OUT" && ok || bad "an empty plan.md is a malformed plan (got: $OUT)"
grep -q 'requeued once' <<<"$OUT" && ok || bad "the first empty plan must requeue (got: $OUT)"
OUT=$(PM_EMPTY=1 drive_pm SIZE_GATE_ENFORCE=1)
grep -q 'held here, handed to the blocked-resolver' <<<"$OUT" \
  && ok || bad "the second empty plan on the same ticket must hold (got: $OUT)"
rm -f "$T/h/state/plan-malformed.txt"

# 4h. the per-project override reaches the gate. The whole point of not
#     hardcoding 300 is that a project whose changes are legitimately larger can
#     say so in a reviewed commit — and a gate that reads the registry but not
#     the row would be a hardcode with extra steps.
printf 'widget-os 1500 40\n' > "$T/h/catalog/size-thresholds.conf"
OUT=$(drive "$(BODY '## Size
FILES: 6
LINES: 900')" SIZE_GATE_ENFORCE=1)
grep -q CONTINUED <<<"$OUT" && ok || bad "a per-project override must let 900 lines through (got: $OUT)"
decomposed && bad "900 < the project's own 1500 must not be split" || ok
grep -q 'lines=1500' "$T/b/pipeline.log" \
  && ok || bad "the log must name the limits it judged against: $(cat "$T/b/pipeline.log" 2>/dev/null)"
rm -f "$T/h/catalog/size-thresholds.conf"

# 4i. a size gate that could NOT run is never read as a pass, and never splits.
cat > "$T/h/bin/size-gate.sh" <<'EOS'
#!/bin/bash
echo "bash: line 9: SG: unbound variable"; exit 127
EOS
chmod +x "$T/h/bin/size-gate.sh"
OUT=$(drive "$(BODY '## Size
FILES: 6
LINES: 900')" SIZE_GATE_ENFORCE=1)
grep -q CONTINUED <<<"$OUT" && ok || bad "a broken size gate must not stop the build (got: $OUT)"
decomposed && bad "a broken size gate must not trigger a split" || ok
grep -qi 'could not run\|not-recorded' "$T/b/pipeline.log" \
  && ok || bad "a broken gate must say so: $(cat "$T/b/pipeline.log" 2>/dev/null)"
cp "$GATE" "$T/h/bin/size-gate.sh"

# ============================================================================
# 5. the post-hoc guard — measured at PR-open, never a block
# ============================================================================
# The plan-time estimate is an estimate. What actually shipped is a fact, and by
# the time it is a fact the code is written — so this one demotes and annotates,
# it never blocks. 2x the threshold is the line: at that width the estimate was
# not slightly optimistic, it was wrong about what the ticket was.
awk '/^# >>> size posthoc/{f=1;next} /^# <<< size posthoc/{exit} f' \
  "$RB_ALL" > "$T/posthoc.sh"
# The numbers below (1400 > 2x300, the '600' bound, 450 < 600) test the 2x
# guard, not the default, so they pin a 300-line project explicitly (BH-4985
# moved the default to 700; removed at the end of this section).
printf 'widget-os 300 12\n' > "$T/h/catalog/size-thresholds.conf"
[ -s "$T/posthoc.sh" ] && ok || bad "could not extract the post-hoc block — markers missing?"

posthoc() { # posthoc <product-lines> <product-files> <tier-in> [env...]
  local pl="$1" pf="$2" tier="$3"; shift 3
  printf '#!/bin/bash\nprintf "SIZE_PRODUCT_FILES: %%s\\nSIZE_PRODUCT_LINES: %%s\\n" "%s" "%s"\n' \
    "$pf" "$pl" > "$T/h/bin/size-scope.sh"
  chmod +x "$T/h/bin/size-scope.sh"
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 BASE=main TIER="$tier" \
        ALERTS="$T/h/logs/ALERTS.log" SWITCHBLOCK="$T/switch.sh" "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             . "$SWITCHBLOCK"
             . "$0"
             echo "TIER=$TIER"
             echo "NOTE=${SIZE_NOTE:-}"' "$T/posthoc.sh" 2>&1 )
}
# 5a. armed and over 2x: tier 2, with a note that names the number.
OUT=$(posthoc 1400 9 1 SIZE_GATE_ENFORCE=1)
grep -q 'TIER=2' <<<"$OUT" && ok || bad "a 1400-line PR must demote to tier 2 (got: $OUT)"
grep -q 'NOTE=.*SIZE' <<<"$OUT" && ok || bad "the demotion must carry a SIZE note (got: $OUT)"
grep -q '1400' <<<"$OUT" && ok || bad "the note must name the measured size (got: $OUT)"
grep -q '600' <<<"$OUT" && ok || bad "the note must name the bound it crossed (got: $OUT)"

# 5b. THE NOTE IS NOT GUARDED BY THE FLAG, only the demotion is — the same rule
#     the scope gate follows. A reviewer reading a 1,400-line PR has to be told
#     it is a 1,400-line PR whether or not the fleet is enforcing anything.
OUT=$(posthoc 1400 9 1 SIZE_GATE_ENFORCE=0)
grep -q 'TIER=1' <<<"$OUT" && ok || bad "disarmed, the post-hoc guard must not demote (got: $OUT)"
grep -q 'NOTE=.*SIZE' <<<"$OUT" && ok || bad "disarmed, the note must still be written (got: $OUT)"
grep -q 'warn only' <<<"$OUT" && ok || bad "the disarmed note must say it is a warning (got: $OUT)"
grep -q 'SIZE_GATE_ENFORCE' <<<"$OUT" \
  && ok || bad "the disarmed note must name the lever that disarmed it (got: $OUT)"

# 5b-i. BOTH HALVES READ ONE SWITCH (2026-09-14). With nothing set the post-hoc
#       guard demotes, because the plan-time gate splits — a build that splits at
#       plan time and then prints "enforcement off" in its own PR body is two
#       switches wearing one name. The fleet kill flag turns off both.
OUT=$(posthoc 1400 9 1)
grep -q 'TIER=2' <<<"$OUT" && ok || bad "by default the post-hoc guard must demote (got: $OUT)"
: > "$T/h/flags/size-gate-enforce-off"
OUT=$(posthoc 1400 9 1)
grep -q 'TIER=1' <<<"$OUT" && ok || bad "the fleet kill flag must reach the post-hoc half too (got: $OUT)"
grep -q 'size-gate-enforce-off' <<<"$OUT" \
  && ok || bad "the note must name the flag that disarmed it (got: $OUT)"
rm -f "$T/h/flags/size-gate-enforce-off"

# 5c. under 2x: silence. A note on every PR is a note nobody reads.
OUT=$(posthoc 450 9 1 SIZE_GATE_ENFORCE=1)
grep -q 'TIER=1' <<<"$OUT" && ok || bad "450 lines is under 2x300 — no demotion (got: $OUT)"
grep -q 'NOTE=$' <<<"$OUT" && ok || bad "an in-bounds PR must get no note (got: $OUT)"

# 5d. already tier 2 for another reason: the note still lands, and says so
#     rather than claiming a demotion it did not cause.
OUT=$(posthoc 1400 9 2 SIZE_GATE_ENFORCE=1)
grep -q 'TIER=2' <<<"$OUT" && ok || bad "a tier-2 build stays tier 2 (got: $OUT)"
grep -q 'already tier-2' <<<"$OUT" && ok || bad "the note must not claim a demotion it did not make (got: $OUT)"

# 5e. it NEVER blocks. Whatever the measurement says, the block exits 0 and
#     writes no RESULT — the code is already written and refusing the PR here
#     would strand it on a branch nobody merges.
OUT=$(posthoc 99999 400 1 SIZE_GATE_ENFORCE=1)
grep -q 'RESULT=' <<<"$OUT" && bad "the post-hoc guard must never terminate a build (got: $OUT)" || ok
grep -q 'TIER=2' <<<"$OUT" && ok || bad "an enormous PR must still reach a reviewer (got: $OUT)"

# 5f. a measurement that could not be taken demotes NOTHING. An unreadable diff
#     is not a small diff, and it is not a large one either.
printf '#!/bin/bash\nexit 1\n' > "$T/h/bin/size-scope.sh"; chmod +x "$T/h/bin/size-scope.sh"
rm -rf "$T/b"; mkdir -p "$T/b"
OUT=$( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 BASE=main TIER=1 \
         ALERTS="$T/h/logs/ALERTS.log" SIZE_GATE_ENFORCE=1 SWITCHBLOCK="$T/switch.sh" \
       bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$SWITCHBLOCK"; . "$0"; echo "TIER=$TIER"; echo "NOTE=${SIZE_NOTE:-}"' \
         "$T/posthoc.sh" 2>&1 )
grep -q 'TIER=1' <<<"$OUT" && ok || bad "an unmeasurable diff must not demote (got: $OUT)"
grep -q 'NOTE=$' <<<"$OUT" && ok || bad "an unmeasurable diff must not be annotated as large (got: $OUT)"
rm -f "$T/h/catalog/size-thresholds.conf"

# ============================================================================
# 6. the wiring the blocks cannot prove about themselves
# ============================================================================
# The planner has to be ASKED for the section, or every plan is undeclared and
# the gate is a very expensive no-op.
grep -q '## Size' "$RB_ALL" \
  && ok || bad "the plan prompt must require a '## Size' section"
grep -qi 'product' "$RB_ALL" \
  && ok || bad "the prompt must say the count is PRODUCT lines, not diff lines"
# The gate runs BEFORE the executor. A size check after EXECUTE is a receipt.
SGL=$(grep -n '^# >>> size gate' "$RB_ALL" | cut -d: -f1)
EXL=$(grep -n 'echo "$(STAMP) \[$PROJECT/$KEY\] EXECUTE' "$RB_ALL" | head -1 | cut -d: -f1)  # determinism: ok race-sigpipe-echo the echo is grep's pattern; the producer is grep reading one file
[ -n "$SGL" ] && [ -n "$EXL" ] && [ "$SGL" -lt "$EXL" ] \
  && ok || bad "the size gate must run before EXECUTE (gate@${SGL:-?} execute@${EXL:-?})"
# The registry is tracked in the repo, so a threshold change is a reviewed
# commit that reaches every box on harness-sync.
[ -f "$DIR/catalog/size-thresholds.conf" ] \
  && ok || bad "catalog/size-thresholds.conf must exist (the DB-driven side of the threshold)"
grep -q '^#' "$DIR/catalog/size-thresholds.conf" \
  && ok || bad "the registry must document its own format"
# Shipped ARMED since 2026-09-14, with a kill flag. If either half of that ever
# flips by accident, these rows are what catch it.
grep -q 'SIZE_GATE_ENFORCE:-0' "$RB_ALL" \
  && bad "nothing may still read the switch with a warn-only default" || ok
grep -q 'flags/size-gate-enforce-off' "$RB_ALL" \
  && ok || bad "the fleet kill flag must be read by the shipped script"
[ "$(grep -c 'SG_SWITCH_RESOLVE' "$RB_ALL")" -ge 3 ] \
  && ok || bad "the plan-time gate and the post-hoc guard must both call the one resolver"
# The decomposer has to be able to file children on a GitHub-Issues board, or an
# armed gate on project-5 is a build that stops and a split that never happens.
# BH-982 moved the filing loop itself into bin/lib/fc-issues.sh, reached from
# bin/run-decompose.sh through file_children, so these two read the file that
# now carries the commands. What they assert is unchanged.
grep -q 'file_children "' "$DIR/bin/run-decompose.sh" \
  && ok || bad "bin/run-decompose.sh must still reach the child filer"
grep -q 'gh issue create' "$DIR/bin/lib/fc-issues.sh" \
  && ok || bad "the issues lane must file children as issues on a GitHub-Issues lane"
grep -q 'labels/ai-build' "$DIR/bin/lib/fc-issues.sh" \
  && ok || bad "the issues lane must park the parent by removing the handoff label"
# No new stage beat name: an unrecognised stage is how a live build stops
# looking live on the console kanban.
grep -q 'BB size' "$RB_ALL" \
  && bad "the size gate must not introduce a new stage beat name" || ok
# And the transition table has to know about the new exits, or the sweep SOP
# and the watchdog's resume pass are reading a map that no longer matches the road.
grep -q 'size' "$DIR/docs/RUN-BUILD-GRAPH.md" \
  && ok || bad "docs/RUN-BUILD-GRAPH.md must document the size gate's exits"

echo "size-gate-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
