#!/bin/bash
# tests/slice-closeout-exclusions.bh-8329-test.sh — BH-8329: the slice
# close-out never files a "Rest of" ticket from an exclusion section.
#
# WHAT HAPPENED. The close-out of example-org/project-6#2593 read the merged
# plan's coverage row `Out of scope: the 17 "Still failing" tests | none (not
# touched)` as undecided work and filed #2605 "Rest of TK-2593: Out of scope".
#
# WHAT THIS PINS:
#   K1-K3  slr_exclude_headings: the default list, `none`, a custom list
#   E1-E6  sco_coverage drops exclusion rows (cells and `###` sub-headings);
#          the near misses keep their old class
#   F1-F3  _sco_scope_items: the parent-scope fallback leaves out exclusions
#   R1-R2  slice_remainder_parse: a C<j> under `## Out of scope` is no slice
#   X1-X4  issue_close_shipped and mc_close_shipped end to end
#   B1     0 real GitHub calls: every gh call is the fixture stub
#
#   HARNESS_TEST_SANDBOX=1 bash tests/slice-closeout-exclusions.bh-8329-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "flock missing — skipping"; exit 0; }

mkdir -p "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/flags" "$T/h/builds" "$T/tmp"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || { echo "FAIL: closure install failed"; exit 1; }
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/h/logs/ALERTS.log"\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
: > "$T/h/env/global.env"
ghfx_init
TOK="tok-fixture-bh-8329-$$"
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" GH_TOKEN="$TOK"
unset FILE_CHILDREN_DRY_RUN DECOMPOSE_DRY_RUN SLICE_REMAINDER_FILE SLICE_CLOSEOUT_SETTLE GH_ISSUES_REPO ISSUE_CLOSE_GUARD_PAGES SLICE_CLOSEOUT_EXCLUDE_HEADINGS
# The stub: the token every call saw to tokens.log; comment bodies to
# posted.txt; a PATCH of the parent marks it closed; `gh issue create` answers
# issue 4600+n with its title and body kept under created/.
ghfx_extra <<'SH'
printf '%s\n' "${GH_TOKEN:-}" >> "$GHFX/tokens.log"
case "$A" in
  *"-X POST"*"/comments"*)
    for a in "$@"; do case "$a" in body=@*) { cat "${a#body=@}"; printf '\n----\n'; } >> "$GHFX/posted.txt" ;; esac; done ;;
  *"-X PATCH repos/example-org/proj/issues/4477"*) touch "$GHFX/parent-closed" ;;
  "issue create"*)
    n=$(( $(cat "$GHFX/create.n" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$GHFX/create.n"
    num=$((4600 + n)); mkdir -p "$GHFX/created"
    t=""; bf=""; prev=""
    for a in "$@"; do
      case "$prev" in --title) t="$a" ;; --body-file) bf="$a" ;; esac
      prev="$a"
    done
    printf '%s\n' "$t" > "$GHFX/created/$num.title"
    cp "$bf" "$GHFX/created/$num.md" 2>/dev/null
    printf '%s\n' "$A" > "$GHFX/created/$num.argv"
    echo "https://github.com/example-org/proj/issues/$num"; exit 0 ;;
esac
SH
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: cannot source the lib"; exit 1; }
mc_init

DEF="out of scope|non-goals|non-goal|not in scope|excluded|won't do"
V="$T/v"; mkdir -p "$V"
cov() { sco_coverage "$1" "$2" 2>/dev/null; printf '\nrc=%s' "$?"; }
# mkr <file> <requirement|task> ... — a whole-ticket plan (no SLICE line)
# whose matrix has one row per argument
mkr() {
  local f="$1" a; shift
  { printf '# BH-4477 plan\n\n## Requirements coverage\n\n| Requirement | Task | Test |\n|---|---|---|\n'
    for a in "$@"; do printf '| %s | %s | X |\n' "${a%%|*}" "${a#*|}"; done
    printf '\n## Acceptance tests\n- A1\n'; } > "$f"
}

# ════════════════════════════════════════════════════════════════════════════
# K. the knob
# ════════════════════════════════════════════════════════════════════════════
R=$(slr_exclude_headings)
[ "$R" = "$DEF" ] && ok || bad "K1: unset is the default list ($R)"
R=$(SLICE_CLOSEOUT_EXCLUDE_HEADINGS=none slr_exclude_headings)
[ -z "$R" ] && ok || bad "K2: none is an empty list ($R)"
mkr "$V/k2.md" 'fix the drawer wait|T1' 'Out of scope: the 17 "Still failing" tests|none (not touched)'
R=$(SLICE_CLOSEOUT_EXCLUDE_HEADINGS=none cov "$V/k2.md" -1)
[ "$(head -1 <<<"$R")" = "$(printf 'undecided\trows:1')" ] && ok || bad "K2: with none the MK row is undecided again ($R)"
R=$(SLICE_CLOSEOUT_EXCLUDE_HEADINGS=' NONE ' slr_exclude_headings)
[ -z "$R" ] && ok || bad "K2: None in any case is off ($R)"
mkr "$V/k3.md" 'alpha|T1' 'Deferred by design: x|none' 'Out of scope: y|none'
R=$(SLICE_CLOSEOUT_EXCLUDE_HEADINGS='deferred by design' cov "$V/k3.md" -1)
[ "$(head -1 <<<"$R")" = "$(printf 'undecided\trows:1')" ] && grep -qx 'Out of scope: y' <<<"$R" && ! grep -q 'Deferred' <<<"$R" && ok \
  || bad "K3: a custom list replaces the default ($R)"

# ════════════════════════════════════════════════════════════════════════════
# E. sco_coverage
# ════════════════════════════════════════════════════════════════════════════
# E1: the TK-2593 matrix. The fifth row is verbatim from
# example-org/project-6:.harness/specs/TK-2593/plan.md (quoted in the BH-8329
# plan); the four T1/T3 rows stand in for the rows that map to T1 and T3.
mkr "$V/e1.md" 'fix the drawer wait|T1' 'the console reads the new state|T1' 'the retry path keeps its cap|T3' \
  'the log names the run|T3' 'Out of scope: the 17 "Still failing" tests|none (not touched)'
R=$(cov "$V/e1.md" -1)
[ "$(head -1 <<<"$R")" = covered ] && grep -q '^rc=0$' <<<"$R" && ok || bad "E1: the TK-2593 matrix is covered rc 0 ($R)"
# E2: each excluded variant leaves no row behind
for x in 'Out of scope: the 17 "Still failing" tests' 'Out of scope' '**Non-goal**: x' 'Out-of-scope — y' 'Out of scope - y' \
         'Won’t do: z' "Won't do: z" 'NOT IN SCOPE (v1)' 'Excluded (by design): w' '`Non-goals`' 'Not in scope – v2'; do
  mkr "$V/e2.md" 'alpha|T1' "$x|none"
  R=$(cov "$V/e2.md" -1)
  [ "$(head -1 <<<"$R")" = covered ] && ok || bad "E2: '$x' is an exclusion ($R)"
done
# E3: near misses keep their old class
for x in 'Excluded tenants see nothing' 'Keep the export out of scope of the API' 'Scope: out of scope items are listed' \
         'Not out of scope: z' 'Non-goals are documented' 'Out of scoped work'; do
  mkr "$V/e3.md" 'alpha|T1' "$x|none"
  R=$(cov "$V/e3.md" -1)
  [ "$(head -1 <<<"$R")" = "$(printf 'undecided\trows:1')" ] && grep -qxF "$x" <<<"$R" && ok || bad "E3: '$x' stays undecided ($R)"
done
# E3: a covered row whose Test cell says out of scope stays covered, and an
# `out of scope` Task cell keeps its deferral meaning (uncovered).
printf '# p\n\n## Requirements coverage\n\n| Requirement | Task | Test |\n|---|---|---|\n| alpha | T1 | out of scope note |\n| beta | out of scope | - |\n' > "$V/e3b.md"
R=$(cov "$V/e3b.md" -1)
[ "$(head -1 <<<"$R")" = "$(printf 'uncovered\t2')" ] && grep -qx alpha <<<"$R" && grep -qx beta <<<"$R" && ok \
  || bad "E3: the Task and Test cells keep their deferral meaning ($R)"
# E4: a `### Out of scope` sub-heading hides its rows up to the next `###`
printf '# p\n\n## Requirements coverage\n\n| Requirement | Task | Test |\n|---|---|---|\n| alpha | T1 | x |\n\n### Out of scope\n\n| Requirement | Task | Test |\n|---|---|---|\n| beta import | none | - |\n| gamma | none | - |\n\n### Later\n\n| Requirement | Task | Test |\n|---|---|---|\n| delta must ship | none | - |\n\n## Acceptance tests\n- A1\n' > "$V/e4.md"
R=$(cov "$V/e4.md" -1)
[ "$(head -1 <<<"$R")" = "$(printf 'undecided\trows:1')" ] && grep -qx 'delta must ship' <<<"$R" \
  && ! grep -q 'beta\|gamma\|Requirement' <<<"$R" && ok || bad "E4: the sub-heading hides beta and gamma, not delta ($R)"
# E5: only exclusion rows -> covered, not undecided no-rows
mkr "$V/e5.md" 'Out of scope: a|none' 'Non-goals: b|-'
R=$(cov "$V/e5.md" -1)
[ "$(head -1 <<<"$R")" = covered ] && grep -q '^rc=0$' <<<"$R" && ok || bad "E5: an all-exclusion matrix is covered rc 0 ($R)"
# E6: the excluded class never leaves sco_coverage
R=$( for f in "$V"/e*.md "$V"/k*.md; do sco_coverage "$f" -1; done 2>/dev/null )
grep -q excluded <<<"$R" && bad "E6: an excluded line reached sco_coverage output" || ok
_sco_rows "$V/e1.md" -1 | grep -q '^excluded	Out of scope' && ok || bad "E6: _sco_rows classes the MK row excluded"

# ════════════════════════════════════════════════════════════════════════════
# F. _sco_scope_items
# ════════════════════════════════════════════════════════════════════════════
printf 'Intro.\n\n## Scope\n1. alpha must export\n\n## Out of scope\n- beta import\n' > "$V/f1.md"
R=$(_sco_scope_items "$V/f1.md" "$DEF")
grep -qF 'alpha must export' <<<"$R" && ! grep -qF 'beta import' <<<"$R" && ok || bad "F1: Scope only ($R)"
printf '## Scope\n1. alpha must export\n\n### Non-goals\n- beta import\n\n### Notes\n- gamma note\n\n## Acceptance\n- A1\n' > "$V/f2.md"
R=$(_sco_scope_items "$V/f2.md" "$DEF")
grep -qF 'alpha must export' <<<"$R" && grep -qF 'gamma note' <<<"$R" && ! grep -qF 'beta import' <<<"$R" && ! grep -q A1 <<<"$R" && ok \
  || bad "F2: the Non-goals sub-section is dropped, Notes stays ($R)"
printf 'Intro line.\n\n## Out of scope\n- beta import\n\n## Notes\n- gamma\n' > "$V/f3.md"
R=$(_sco_scope_items "$V/f3.md" "$DEF")
grep -qF 'Intro line.' <<<"$R" && grep -qF gamma <<<"$R" && ! grep -qF 'beta import' <<<"$R" && ok || bad "F3: no Scope: the body minus Out of scope ($R)"
R=$(_sco_scope_items "$V/f3.md" "")
grep -qF 'beta import' <<<"$R" && ok || bad "F3: an empty list keeps today's head of the body ($R)"

# ════════════════════════════════════════════════════════════════════════════
# R. slice_remainder_parse
# ════════════════════════════════════════════════════════════════════════════
printf '# BH-4477\n\nSLICE: C1 of #4477\n\n## Later slices\n- C2: x\n\n## Out of scope\n- C3: y\n' > "$V/r1.md"
R=$(slice_remainder_parse "$V/r1.md" 4477 "$V/r1.json" 2>/dev/null)
[ "$R" = ok:1 ] && [ "$(jq -r '.[0].ordinal' "$V/r1.json")" = 2 ] && ! grep -q '"y"\|: y' "$V/r1.json" && ok \
  || bad "R1: only C2 is a remainder ($R $(cat "$V/r1.json" 2>/dev/null))"
printf '# BH-4477\n\nSLICE: C1 of #4477\n\n## Later slices (not in scope here)\n- C2: x\n' > "$V/r2.md"
R=$(slice_remainder_parse "$V/r2.md" 4477 "$V/r2.json" 2>/dev/null)
[ "$R" = ok:1 ] && ok || bad "R2: a heading that does not START with a label keeps its slices ($R)"
R=$(SLICE_CLOSEOUT_EXCLUDE_HEADINGS=none slice_remainder_parse "$V/r1.md" 4477 "$V/r1n.json" 2>/dev/null)
[ "$R" = ok:2 ] && ok || bad "R1: with none C3 is a remainder again ($R)"

# ════════════════════════════════════════════════════════════════════════════
# X. the close-out, end to end
# ════════════════════════════════════════════════════════════════════════════
S=example-org/proj
PRURL=https://github.com/example-org/proj/pull/4500
MSHA=0123456789abcdef0123456789abcdef01234567
REC="$T/h/builds/proj-BH-4477-remote20261012080305"
D="$REC/slice-closeout"
PR_BODY=$'## Summary\nPart of #4477\n\nharness build'
xref() {
  jq -nc --argjson n "$1" --arg m "$2" --arg b "$3" \
    '{event:"cross-referenced",source:{type:"issue",issue:{number:$n,state:"closed",title:("BH-4477: slice " + ($n|tostring)),body:$b,
      html_url:("https://github.com/example-org/proj/pull/" + ($n|tostring)),repository:{full_name:"example-org/proj"},
      pull_request:{html_url:("https://github.com/example-org/proj/pull/" + ($n|tostring)),merged_at:$m}}}}'
}
TIMELINE="[$(xref 4490 2026-10-11T09:00:00Z 'Part of #4477'),$(xref 4500 2026-10-12T09:07:00Z 'Part of #4477')]"
PARENT_BODY=$'The master ticket.\n\n## Scope\n1. alpha must export\n\n## Out of scope\n- beta import\n\n## Acceptance tests\n- A1'
MIX_PLAN=$(mkr "$V/x1.md" 'the drawer waits|T1' 'alpha must export|C2' 'Out of scope: beta import|none (not touched)'; cat "$V/x1.md")
NOMATRIX_PLAN=$'# BH-4477 plan\n\n## Tasks\n- T1\n'
EXCL_PLAN=$(mkr "$V/x3.md" 'the drawer waits|T1' 'Out of scope: beta import|none (not touched)'; cat "$V/x3.md")
reset() {
  cat "$T/gh-argv.log" >> "$T/all-argv.log"
  ghfx_routes_reset; ghfx_log_reset; : > "$T/posted.txt"
  scratch_rm "$REC"; mkdir -p "$REC"; echo APPROVE > "$REC/RESULT"
  scratch_rm "$T/h/state/slice-closeout"
  rm -rf "$T/created"; rm -f "$T/create.n" "$T/parent-closed"
}
routes() { # routes <spec-text>
  local b64; b64=$(printf '%s' "$1" | base64 | tr -d '\n')
  ghfx_route GET    "repos/$S/pulls/4500" 200 "$(jq -nc --arg b "$PR_BODY" --arg sha "$MSHA" \
                       '{number:4500,state:"closed",title:"BH-4477: slice of the master",body:$b,merged_at:"2026-10-12T09:07:00Z",merge_commit_sha:$sha}')"
  ghfx_route GET    "repos/$S/issues/4477/timeline*" 200 "$TIMELINE"
  ghfx_route GET    "repos/$S/contents/.harness/specs/BH-4477/plan.md*" 200 "$(jq -nc --arg c "$b64" '{encoding:"base64",content:$c}')"
  ghfx_route POST   "repos/$S/issues/4477/comments" 201 '{"id":1}'
  ghfx_route PATCH  "repos/$S/issues/4477" 200 '{"state":"closed"}'
  ghfx_route DELETE "repos/$S/issues/4477/labels/ai-build" 200 '[]'
  ghfx_route GET    "repos/$S/issues/4477" 200 "$(jq -nc --arg b "$PARENT_BODY" '{number:4477,state:"closed",title:"BH-4477: master",body:$b,labels:[{name:"ai-build"}]}')" "$T/parent-closed"
  ghfx_route GET    "repos/$S/issues/4477" 200 "$(jq -nc --arg b "$PARENT_BODY" '{number:4477,state:"open",title:"BH-4477: master",body:$b,labels:[{name:"ai-build"}]}')"
  ghfx_route GET    "repos/$S/issues" 200 '[]'
  ghfx_route GET    "repos/$S/issues/4601" 200 '{"number":4601,"state":"open","title":"BH-4477.2: x"}'
}
n_create() { find "$T/created" -name '*.argv' 2>/dev/null | grep -c .; }
n_patch()  { grep -c -- "-X PATCH repos/$S/issues/4477" "$T/gh-argv.log"; }
ics() { issue_close_shipped "$S" 4477 "Merged in $PRURL. Closing this issue." "$T/h" "$PRURL" "$REC" 2>/dev/null; }
mcs() { mc_close_shipped "$S" 4477 "Merged in $PRURL (merge conductor). Closing this issue." "$REC" "$PRURL" 2>/dev/null; }
: > "$T/all-argv.log"; : > "$T/tokens.log"

for FN in ics mcs; do
  # X1: matrix path, one real unfinished row and one exclusion row -> 1 child
  reset; routes "$MIX_PLAN"
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "closed-slice:closed:child:#4601:#4500,#4490" ] && ok || bad "X1[$FN]: word (rc=$RC w=$W)"
  [ "$(n_create)" = 1 ] && ok || bad "X1[$FN]: exactly one create ($(n_create))"
  [ "$(cat "$T/created/4601.title" 2>/dev/null)" = "BH-4477.1: Rest of BH-4477: alpha must export" ] && ok \
    || bad "X1[$FN]: the child is the scope item ($(cat "$T/created/4601.title" 2>/dev/null))"
  grep -qF 'alpha must export' "$T/created/4601.md" 2>/dev/null && ! grep -qF 'beta import' "$T/created/4601.md" && ok \
    || bad "X1[$FN]: the body has alpha, not beta ($(head -c 600 "$T/created/4601.md" 2>/dev/null))"

  # X2: fallback path, no matrix -> the parent Scope minus Out of scope
  reset; routes "$NOMATRIX_PLAN"
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "closed-slice:closed:child:#4601:#4500,#4490" ] && ok || bad "X2[$FN]: word (rc=$RC w=$W)"
  [ "$(n_create)" = 1 ] && grep -qF 'alpha must export' "$T/created/4601.md" 2>/dev/null \
    && ! grep -qF 'beta import' "$T/created/4601.md" && ! grep -qF 'beta import' "$T/created/4601.title" && ok \
    || bad "X2[$FN]: one child with alpha, not beta (create=$(n_create): $(head -c 600 "$T/created/4601.md" 2>/dev/null))"

  # X2b: fallback path, a parent with no Scope section -> the head of the body
  # minus its Out of scope section
  reset; PARENT_BODY=$'The master ticket: alpha must export.\n\n## Out of scope\n- beta import\n' routes "$NOMATRIX_PLAN"
  W=$($FN); RC=$?
  [ "$(n_create)" = 1 ] && grep -qF 'alpha must export' "$T/created/4601.md" 2>/dev/null \
    && ! grep -qF 'beta import' "$T/created/4601.md" && ok \
    || bad "X2b[$FN]: no Scope: one child with the intro, not beta (w=$W create=$(n_create): $(head -c 600 "$T/created/4601.md" 2>/dev/null))"

  # X3: only an exclusion row is left -> 0 children, the parent closes covered
  reset; routes "$EXCL_PLAN"
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "closed-slice:closed:covered:#4500,#4490" ] && ok || bad "X3[$FN]: word (rc=$RC w=$W)"
  [ "$(n_create)" = 0 ] && [ "$(n_patch)" = 1 ] && ok || bad "X3[$FN]: 0 creates, one close (create=$(n_create) patch=$(n_patch))"
  [ "$(cat "$D/verdict" 2>/dev/null)" = covered ] && ok || bad "X3[$FN]: the ledger verdict is covered ($(cat "$D/verdict" 2>/dev/null))"
  grep -qF 'beta import' "$T/posted.txt" && bad "X3[$FN]: the close comment names no excluded item" || ok

  # X4: the row is the switch: none restores today's child
  reset; routes "$EXCL_PLAN"
  W=$(SLICE_CLOSEOUT_EXCLUDE_HEADINGS=none $FN); RC=$?
  [ "$W" = "closed-slice:closed:child:#4601:#4500,#4490" ] && [ "$(n_create)" = 1 ] && ok \
    || bad "X4[$FN]: with none the exclusion row files a child (w=$W create=$(n_create))"
done

# ════════════════════════════════════════════════════════════════════════════
# B1. 0 real GitHub calls
# ════════════════════════════════════════════════════════════════════════════
cat "$T/gh-argv.log" >> "$T/all-argv.log"
[ "$(command -v gh)" = "$T/fakebin/gh" ] && ok || bad "B1: gh resolves to the fixture stub ($(command -v gh))"
[ -s "$T/all-argv.log" ] && ok || bad "B1: the stub logged the suite's calls"
R=$(grep -vE '^(api -i -X (GET|POST|PATCH|DELETE|PUT) repos/example-org/proj/|api repos/example-org/proj( |/)|issue create |auth token|api rate_limit)' "$T/all-argv.log" | head -3)
[ -z "$R" ] && ok || bad "B1: every gh call is a fixture call on example-org/proj ($R)"
R=$(grep -vxE "$TOK|faketoken" "$T/tokens.log" | sort -u | head -3)
[ -s "$T/tokens.log" ] && [ -z "$R" ] && ok || bad "B1: every call carried the fixture token or the stub's own (got: $R)"

echo "slice-closeout-exclusions (BH-8329): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
