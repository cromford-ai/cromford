#!/bin/bash
# tests/plan-failure-modes.bh-5800-test.sh — BH-5800: a plan that changes bin/
# or worker/ answers the failure-mode checklist, and the plan validator
# (bin/plan-gate.sh) refuses it without one. 47 of the 66 logic-bug BLOCK
# findings in the 2026-10 review-block analysis fell into the six patterns the
# checklist asks about. The checklist is data: catalog/plan-failure-modes.tsv.
#
#   F1  a traced plan naming bin/lib/x.sh with no `## Failure modes`: rc 2,
#       PLAN_FAILURE_MODES: missing, an UNTRACED line, PLAN_TRACE: untraced
#   F2  the same plan with all six answered, each naming its test: rc 0, ok
#   F3  an answer with no test named and no n/a: refused, that label named
#   F4  `n/a` alone is refused; `n/a — <reason>` passes
#   F5  a plan naming only docs/, tests/ and src/ paths: n/a, rc 0
#   F6  a bin/ path only under `## Sibling claims (not touched)`: not required;
#       a worker/ path in a code fence: required
#   F7  the catalog is data: without the `status` row, that label is not asked
#   F8  a section written from pfm_plan_rule's own labels passes (the writer
#       and the reader agree)
#   F9  an unreadable catalog: PLAN_FAILURE_MODES: unread, the trace verdict
#       alone decides
#   F10 the repair pass in bin/lib/rb/plan.sh tells the planner what is missing
#   F14 nested sub-bullets under every heading, carrying case words that
#       start other headings ("status", "default", "exit path", "alert"),
#       are part of that answer and never take a heading's slot (lead review
#       lr-5841-f1d23c19b02a)
#   F15 a rooted path (/root/harness/bin/..., $HARNESS/bin/...) needs the
#       section; a path under another tree's bin/ (src/bin/) still does not
#   P1  the plan prompt in bin/lib/rb/plan.sh and the pre-plan prompt in
#       bin/run-preplan.sh carry pfm_plan_rule
#   P2  prompts/plan-contract.md §13 names the six headings
#   L1  prompts/lead-review-checklist.md checks the answers against the diff
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/plan-failure-modes.bh-5800-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

GATE="$DIR/bin/plan-gate.sh"
LIB="$DIR/bin/lib/plan-failure-modes.sh"
CAT="$DIR/catalog/plan-failure-modes.tsv"
[ -r "$LIB" ] && bash -n "$LIB" && ok || bad "bin/lib/plan-failure-modes.sh is missing or does not parse"
[ -r "$CAT" ] && ok || bad "catalog/plan-failure-modes.tsv is missing"
unset PLAN_FAILURE_MODES_CATALOG PLAN_GATE_HOTSPOTS

# plan <file> <path-line> [section-file] — a traced one-task plan naming a path
plan() {
  { printf '# Plan\n\n## Tasks\n\n### T1. Change it\nTouch %s.\nVALIDATE: `bash tests/x-test.sh`\nSATISFIES: the ticket\n\n' "$2"
    [ -n "${3:-}" ] && cat "$3"
    printf '\n## Acceptance tests\n- tests/x-test.sh\n\nSIZE: S\n'; } > "$1"
}
FULL="$T/full.md"
cat > "$FULL" <<'EOF'
## Failure modes
- Decision rule: case table. Matches: a, b. Does not match: c, d. Edge: "". Test: tests/x-test.sh C1-C5.
- Exit paths: rc 0 writes the row; rc 2 leaves no row and spends no budget. Test: tests/x-test.sh E1.
- Writer/reader round-trip: the writer is x_put, the reader is x_get; the test writes then reads it back. Test: tests/x-test.sh R1.
- Alert or freeze blast radius: at most one page per tick, scoped to one repo. Test: tests/x-test.sh A1.
- Defaults in prod: the knob is 1 in prod, because the old path is wrong. Test: tests/x-test.sh K1.
- Status evidence: "done" only after the row reads back. Test: tests/x-test.sh S1.
EOF
gate() { "$GATE" "$1" > "$T/out" 2>&1; echo $?; }
fm() { sed -n 's/^PLAN_FAILURE_MODES:[[:space:]]*//p' "$T/out" | tail -1; }

# ── F1 ──────────────────────────────────────────────────────────────────────
plan "$T/f1.md" '`bin/lib/x.sh`'
rc=$(gate "$T/f1.md")
[ "$rc" = 2 ] && [ "$(fm)" = missing ] && grep -q '^PLAN_TRACE: untraced' "$T/out" && ok \
  || bad "F1 a bin/ plan with no failure modes was not refused (rc $rc): $(cat "$T/out")"
grep -q '^  UNTRACED: failure modes' "$T/out" && ok || bad "F1 no UNTRACED failure-modes line: $(cat "$T/out")"

# ── F2 ──────────────────────────────────────────────────────────────────────
plan "$T/f2.md" '`bin/lib/x.sh`' "$FULL"
rc=$(gate "$T/f2.md")
[ "$rc" = 0 ] && [ "$(fm)" = ok ] && ok || bad "F2 a full section was refused (rc $rc): $(cat "$T/out")"

# ── F3: an answer that names no test ────────────────────────────────────────
sed 's/^- Exit paths: .*/- Exit paths: rc 0 writes the row./' "$FULL" > "$T/f3s.md"
plan "$T/f3.md" '`bin/lib/x.sh`' "$T/f3s.md"
rc=$(gate "$T/f3.md")
[ "$rc" = 2 ] && grep -q 'UNTRACED: failure modes — exit paths' "$T/out" && ok \
  || bad "F3 an answer with no test passed (rc $rc): $(cat "$T/out")"

# ── F4: n/a needs a reason ──────────────────────────────────────────────────
sed 's/^- Writer\/reader round-trip: .*/- Writer\/reader round-trip: n\/a/' "$FULL" > "$T/f4s.md"
plan "$T/f4.md" '`bin/lib/x.sh`' "$T/f4s.md"
rc=$(gate "$T/f4.md")
[ "$rc" = 2 ] && grep -q 'UNTRACED: failure modes — writer/reader round-trip' "$T/out" && ok \
  || bad "F4 a bare n/a passed (rc $rc): $(cat "$T/out")"
sed 's/^- Writer\/reader round-trip: .*/- Writer\/reader round-trip: n\/a — this change adds no format and no file./' "$FULL" > "$T/f4b.md"
plan "$T/f4c.md" '`bin/lib/x.sh`' "$T/f4b.md"
rc=$(gate "$T/f4c.md")
[ "$rc" = 0 ] && ok || bad "F4 n/a with a reason was refused (rc $rc): $(cat "$T/out")"

# ── F4b: a heading left out ─────────────────────────────────────────────────
grep -v '^- Defaults in prod' "$FULL" > "$T/f4d.md"
plan "$T/f4e.md" '`bin/lib/x.sh`' "$T/f4d.md"
rc=$(gate "$T/f4e.md")
[ "$rc" = 2 ] && grep -q 'UNTRACED: failure modes — defaults in prod' "$T/out" && ok \
  || bad "F4 a missing heading passed (rc $rc): $(cat "$T/out")"

# ── F5: no bin/ or worker/ path ─────────────────────────────────────────────
plan "$T/f5.md" '`docs/x.md`, `tests/x-test.sh` and `src/app/page.tsx`'
rc=$(gate "$T/f5.md")
[ "$rc" = 0 ] && [ "$(fm)" = n/a ] && ok || bad "F5 a docs-only plan was asked for failure modes (rc $rc): $(cat "$T/out")"
plan "$T/f5b.md" 'the bin/ directory in prose'
rc=$(gate "$T/f5b.md")
[ "$rc" = 0 ] && ok || bad "F5 a bare 'bin/' word made the section required (rc $rc): $(cat "$T/out")"

# ── F6: sibling claims and code fences ──────────────────────────────────────
plan "$T/f6.md" '`docs/x.md`'
printf '\n## Sibling claims (not touched)\n- BH-1 edits `bin/lib/y.sh`.\n' >> "$T/f6.md"
rc=$(gate "$T/f6.md")
[ "$rc" = 0 ] && ok || bad "F6 a sibling's bin/ path made the section required (rc $rc): $(cat "$T/out")"
plan "$T/f6b.md" '`docs/x.md`'
printf '\n## Files\n```\nworker/jobs/src/routes/x.js\n```\n' >> "$T/f6b.md"
rc=$(gate "$T/f6b.md")
[ "$rc" = 2 ] && [ "$(fm)" = missing ] && ok || bad "F6 a worker/ path in a fence did not require the section (rc $rc): $(cat "$T/out")"

# ── F7: the catalog is data ─────────────────────────────────────────────────
grep -v $'^heading\tstatus\t' "$CAT" > "$T/cat7.tsv"
grep -v '^- Status evidence' "$FULL" > "$T/f7s.md"
plan "$T/f7.md" '`bin/lib/x.sh`' "$T/f7s.md"
rc=$(PLAN_FAILURE_MODES_CATALOG="$T/cat7.tsv" gate "$T/f7.md")
[ "$rc" = 0 ] && ok || bad "F7 a heading removed from the catalog is still asked (rc $rc): $(cat "$T/out")"
rc=$(gate "$T/f7.md")
[ "$rc" = 2 ] && ok || bad "F7 control: with the real catalog the missing status answer passed (rc $rc)"

# ── F8: the writer (the prompt rule) and the reader agree ───────────────────
RULE=$(bash -c '. "$1"; pfm_plan_rule "$2"' _ "$LIB" "$CAT")
[ -n "$RULE" ] && ok || bad "F8 pfm_plan_rule printed nothing"
{ echo '## Failure modes'
  bash -c '. "$1"; pfm_labels "$2"' _ "$LIB" "$CAT" | while IFS= read -r l; do printf -- '- %s: answered here. Test: tests/x-test.sh.\n' "$l"; done; } > "$T/f8s.md"
plan "$T/f8.md" '`bin/lib/x.sh`' "$T/f8s.md"
rc=$(gate "$T/f8.md")
[ "$rc" = 0 ] && [ "$(grep -c '^- ' "$T/f8s.md")" = 6 ] && ok || bad "F8 the rule's own labels do not pass (rc $rc): $(cat "$T/out") $(cat "$T/f8s.md")"
for w in "decision" "exit" "writer" "alert" "default" "status"; do grep -qi "$w" <<<"$RULE" && ok || bad "F8 the prompt rule does not name '$w'"; done

# ── F9: an unreadable catalog never refuses ─────────────────────────────────
rc=$(PLAN_FAILURE_MODES_CATALOG="$T/nope.tsv" gate "$T/f1.md")
[ "$rc" = 0 ] && [ "$(fm)" = unread ] && ok || bad "F9 an unreadable catalog: rc $rc fm '$(fm)'"

# ── F10, P1: bin/lib/rb/plan.sh ─────────────────────────────────────────────
PS="$DIR/bin/lib/rb/plan.sh"
awk '/^PG_RUN; PG_RC=\$\?/{f=1} f && /Repair the plan/ {print; exit}' "$PS" | grep -q 'pfm_repair_note' && ok \
  || bad "F10 the plan-gate repair prompt does not carry pfm_repair_note"
NOTE=$(bash -c '. "$1"; printf "  UNTRACED: failure modes — exit paths: no test named\n" > "$2/pg.txt"; pfm_repair_note "$2/pg.txt"' _ "$LIB" "$T")
case "$NOTE" in *"## Failure modes"*"exit paths"*) ok ;; *) bad "F10 pfm_repair_note does not name the section and the gap: '$NOTE'" ;; esac
[ -z "$(bash -c '. "$1"; printf "PLAN_TRACE: ok\n" > "$2/pg2.txt"; pfm_repair_note "$2/pg2.txt"' _ "$LIB" "$T")" ] && ok || bad "F10 a clean gate still gets a repair note"
# TEST-CHANGE (BH-7970): the call moved from the CC plan line to the SP_PLAN_PFM precompute, and the template carries its token.
grep -q '^SP_PLAN_PFM=.*pfm_plan_rule' "$PS" && grep -qF '${SP_PLAN_PFM}' "$DIR/prompts/stages/plan.md" && ok || bad "P1 the plan prompt does not carry pfm_plan_rule"
grep -q 'agent-call.sh" preplan .*' "$DIR/bin/run-preplan.sh" && awk '/^  "\$\{PP_PREAMBLE/ && /pfm_plan_rule/ {f = 1} END {exit !f}' "$DIR/bin/run-preplan.sh" \
  && ok || bad "P1 the pre-plan prompt does not carry pfm_plan_rule"

# ── P2, L1: the prompts ─────────────────────────────────────────────────────
PC=$(awk '/^## 13\. /{f=1; print; next} f && /^## /{exit} f' "$DIR/prompts/plan-contract.md")
[ -n "$PC" ] && ok || bad "P2 prompts/plan-contract.md has no §13"
for w in "decision rule" "exit path" "round-trip" "blast radius" "default" "status"; do grep -qi "$w" <<<"$PC" && ok || bad "P2 §13 does not name '$w'"; done
# P3 (PR #7069 lead review): §13 is the ONE definition of the decision-rule
# case table. It names the near misses, the assumed-source escape and the
# PLAN_BLOCKED rule; the catalog question the planner sees names them too;
# and §10 does not restate the near-miss list (a second copy drifts).
for w in "near misses" "negated text" "past the first page" "source: assumed" "PLAN_BLOCKED" "asserts every case"; do
  grep -qi "$w" <<<"$PC" && ok || bad "P3 §13 does not name '$w'"
done
DQ=$(awk -F '\t' '$1 == "heading" && $2 == "decision" {print $5}' "$DIR/catalog/plan-failure-modes.tsv")
for w in "near misses" "source: assumed" "asserts every case"; do grep -qi "$w" <<<"$DQ" && ok || bad "P3 the catalog decision question does not name '$w'"; done
S10=$(awk '/^## 10\. /{f=1; next} f && /^## /{exit} f' "$DIR/prompts/plan-contract.md")
[ -n "$S10" ] && ! grep -qi 'negated text' <<<"$S10" && ok || bad "P3 §10 restates the §13 near-miss list"
awk '/Failure modes/ && /diff/ {f = 1} END {exit !f}' "$DIR/prompts/lead-review-checklist.md" && ok \
  || bad "L1 the lead review checklist does not check the plan's Failure modes against the diff"

# ── F11-F13: lead review lr-5841-ab9afe22a013 ───────────────────────────────
# F11 a `# comment` inside a fenced block in an answer is not a heading: the
# section stays open and the compliant plan passes.
awk '{print} /^- Exit paths:/{print "```bash"; print "# run it"; print "bash tests/x-test.sh E1"; print "```"}' "$FULL" > "$T/f11s.md"
grep -qx '# run it' "$T/f11s.md" && ok || bad "F11 fixture: no fenced comment"
plan "$T/f11.md" '`bin/lib/x.sh`' "$T/f11s.md"
rc=$(gate "$T/f11.md")
[ "$rc" = 0 ] && [ "$(fm)" = ok ] && ok || bad "F11 a fenced '# run it' in an answer closed the section (rc $rc): $(cat "$T/out")"
sed 's/^```bash$/~~~/; s/^```$/~~~/' "$T/f11s.md" > "$T/f11t.md"
plan "$T/f11b.md" '`bin/lib/x.sh`' "$T/f11t.md"
rc=$(gate "$T/f11b.md")
[ "$rc" = 0 ] && [ "$(fm)" = ok ] && ok || bad "F11 a ~~~ fenced comment closed the section (rc $rc): $(cat "$T/out")"
# F12 a fenced sibling list under '## Sibling claims' that starts with a
# `# BH-1 files` line stays excluded: the sibling's bin/ path does not make
# the section required.
printf '## Sibling claims (not touched)\n```\n# BH-1 files\nbin/lib/y.sh\n```\n' > "$T/f12s.md"
plan "$T/f12.md" '`docs/x.md`' "$T/f12s.md"
rc=$(gate "$T/f12.md")
[ "$rc" = 0 ] && [ "$(fm)" = n/a ] && ok || bad "F12 a fenced sibling list made the section required (rc $rc): $(cat "$T/out")"
# F13 an answer that only contains the letters "test" inside another word names
# no acceptance test.
cat > "$T/f13s.md" <<'EOF2'
## Failure modes
- Decision rule: the latest numbers say so.
- Exit paths: contested by nobody.
- Writer/reader round-trip: attested elsewhere.
- Alert or freeze blast radius: the greatest of all.
- Defaults in prod: a protest at most.
- Status evidence: the fastest path.
EOF2
plan "$T/f13.md" '`bin/lib/x.sh`' "$T/f13s.md"
rc=$(gate "$T/f13.md")
[ "$rc" = 2 ] && [ "$(grep -c 'no acceptance test named' "$T/out")" = 6 ] && ok \
  || bad "F13 answers that name no test passed (rc $rc): $(cat "$T/out")"

# ── F14: nested sub-bullets never take a heading's slot ─────────────────────
# The lead review's input: a decision table nested under "Decision rule", whose
# rows start with words that open other headings. Each heading also carries a
# nested sub-bullet. The real "Defaults in prod" answer names its test.
cat > "$T/f14s.md" <<'EOF2'
## Failure modes
- Decision rule: case table. Test: tests/x-test.sh C1-C5.
  - status row present: match
  - default row: no match
  - exit path rc 0: match
  - alert row only: no match
- Exit paths: rc 0 writes the row. Test: tests/x-test.sh E1.
  - status of the row after rc 2: absent
- Writer/reader round-trip: x_put then x_get. Test: tests/x-test.sh R1.
  - defaults: the reader fills none
- Alert or freeze blast radius: one page per tick. Test: tests/x-test.sh A1.
  - decision rule for the page: one per repo
- Defaults in prod: the knob is 1 in prod. Test: tests/x-test.sh K1.
  - exit paths: unchanged
- Status evidence: "done" only after the row reads back. Test: tests/x-test.sh S1.
  - alert or freeze: none
EOF2
plan "$T/f14.md" '`bin/lib/x.sh`' "$T/f14s.md"
rc=$(gate "$T/f14.md")
[ "$rc" = 0 ] && [ "$(fm)" = ok ] && ok || bad "F14 nested case rows took a heading's slot (rc $rc): $(cat "$T/out")"
# A nested bullet alone cannot answer a heading: with the top-level
# "Defaults in prod" bullet removed, only the nested "- defaults:" row is left.
grep -v '^- Defaults in prod:' "$T/f14s.md" > "$T/f14b.md"
plan "$T/f14c.md" '`bin/lib/x.sh`' "$T/f14b.md"
rc=$(gate "$T/f14c.md")
[ "$rc" = 2 ] && grep -q 'UNTRACED: failure modes — defaults in prod: not answered' "$T/out" && ok \
  || bad "F14 a nested bullet answered a heading (rc $rc): $(cat "$T/out")"

# ── F15: rooted bin/ and worker/ paths need the section ─────────────────────
for p in '`/root/harness/bin/lib/x.sh`' '`$HARNESS/bin/run-build.sh`' '`/root/harness/worker/jobs/src/x.js`'; do
  plan "$T/f15.md" "$p"
  rc=$(gate "$T/f15.md")
  [ "$rc" = 2 ] && [ "$(fm)" = missing ] && ok || bad "F15 $p did not require the section (rc $rc): $(cat "$T/out")"
done
plan "$T/f15b.md" '`src/bin/x.sh`'
rc=$(gate "$T/f15b.md")
[ "$rc" = 0 ] && [ "$(fm)" = n/a ] && ok || bad "F15 src/bin/x.sh required the section (rc $rc): $(cat "$T/out")"

echo "plan-failure-modes.bh-5800: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
