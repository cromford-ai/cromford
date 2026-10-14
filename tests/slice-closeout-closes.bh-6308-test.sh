#!/bin/bash
# tests/slice-closeout-closes.bh-6308-test.sh — BH-6308: a slice close-out that
# finds no open child never leaves the parent open with no child. When the
# merged plan's `## Requirements coverage` matrix maps every row to merged work,
# the parent closes with the merged slice PR links; when a row is not covered,
# or the check cannot decide, ONE child carries the rest and the parent closes.
#
# WHAT THIS PINS, on the word each close-out prints, the REST argv log (POST,
# PATCH, DELETE), the comment bodies posted, the `gh issue create` argv and body
# files, the ledger files under <record>/slice-closeout and the alert stub's log:
#   P1-P3  slice_merged_prs: merged PRs only, newest first; a failed or capped
#          timeline is ERR, never an empty answer
#   V1-V15 sco_coverage on the real BH-5240 and BH-5653 plans and on the shapes that must
#          not read as covered
#   C1-C10 issue_close_shipped and mc_close_shipped end to end
#   C11    a partial build (BH-5798) files its not-met items, never covered
#   C12    a foreign title key never decides this issue's close
#   H1     bin/hotfix-after-deploy.sh logs the closed-slice word, no deferral
#
#   HARNESS_TEST_SANDBOX=1 bash tests/slice-closeout-closes.bh-6308-test.sh   exit 0 = pass
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
for f in "$DIR/bin/lib/slice-closeout.sh" "$DIR/bin/lib/slice-prs.sh"; do
  [ -r "$f" ] && ok || bad "setup: $f is missing"
done

mkdir -p "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/flags" "$T/h/builds" "$T/tmp"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || { echo "FAIL: closure install failed"; exit 1; }
# The conductor's closure must reach the new libs: that is the wiring a live box
# gets, not a list this suite chose.
for f in slice-closeout.sh slice-prs.sh slice-remainder.sh file-children.sh fc-issues.sh; do
  [ -r "$T/h/bin/lib/$f" ] && ok || bad "setup: the merge conductor's closure does not reach bin/lib/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/h/logs/ALERTS.log"\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
: > "$T/h/env/global.env"
ghfx_init
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH"
unset FILE_CHILDREN_DRY_RUN DECOMPOSE_DRY_RUN SLICE_REMAINDER_FILE SLICE_CLOSEOUT_SETTLE GH_ISSUES_REPO ISSUE_CLOSE_GUARD_PAGES
# The stub: comment bodies to posted.txt; a PATCH of the parent that is not set
# to fail marks it closed (the guarded route below then reads it closed, which
# is what gh_rest_close re-reads); `gh issue create` answers issue 4600+n.
ghfx_extra <<'SH'
case "$A" in
  *"-X POST"*"/comments"*)
    for a in "$@"; do case "$a" in body=@*) { cat "${a#body=@}"; printf '\n----\n'; } >> "$GHFX/posted.txt" ;; esac; done ;;
  *"-X PATCH repos/example-org/proj/issues/4477"*)
    [ -e "$GHFX/close-fail" ] || touch "$GHFX/parent-closed" ;;
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

S=example-org/proj
PRURL=https://github.com/example-org/proj/pull/4500
PRURL0=https://github.com/example-org/proj/pull/4490
MSHA=0123456789abcdef0123456789abcdef01234567

# xref <num> <merged_at|-> <body> [state] [title] — one timeline cross-reference to a PR
xref() {
  jq -nc --argjson n "$1" --arg m "$2" --arg b "$3" --arg st "${4:-closed}" --arg t "${5:-}" \
    '{event:"cross-referenced",source:{type:"issue",issue:{number:$n,state:$st,title:(if $t == "" then "BH-4477: slice " + ($n|tostring) else $t end),body:$b,
      html_url:("https://github.com/example-org/proj/pull/" + ($n|tostring)),
      repository:{full_name:"example-org/proj"},
      pull_request:{html_url:("https://github.com/example-org/proj/pull/" + ($n|tostring)),merged_at:(if $m == "-" then null else $m end)}}}}'
}
TIMELINE="[$(xref 4490 2026-10-11T09:00:00Z 'Part of #4477'),$(xref 4500 2026-10-12T09:07:00Z $'SLICE: C1 of #4477\nPart of #4477'),$(xref 4510 - 'Part of #4477' open),$(xref 4505 - 'Part of #4477')]"

# ════════════════════════════════════════════════════════════════════════════
# P. slice_merged_prs
# ════════════════════════════════════════════════════════════════════════════
ghfx_routes_reset
ghfx_route GET "repos/$S/issues/4477/timeline*" 200 "$TIMELINE"
R=$(slice_merged_prs "$S" 4477 "$T/h" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$R" | cut -f3 | paste -sd, -)" = "4500,4490" ] && ok \
  || bad "P1: two merged PRs, newest first; the open and the unmerged one are not slices (rc=$RC: $R)"
[ "$(head -1 <<<"$R" | cut -f2)" = "$PRURL" ] && [ "$(head -1 <<<"$R" | cut -f1)" = "$(date -u -d 2026-10-12T09:07:00Z +%s)" ] && ok \
  || bad "P1: row 1 is the epoch and url of #4500 ($(head -1 <<<"$R"))"
# A PR that does not name #4477 is not a slice of it.
ghfx_routes_reset
ghfx_route GET "repos/$S/issues/4477/timeline*" 200 "[$(xref 4490 2026-10-11T09:00:00Z 'Mentions #4477 in passing' closed 'Tidy the docs')]"
R=$(slice_merged_prs "$S" 4477 "$T/h" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ -z "$R" ] && ok || bad "P1: a merged PR that only mentions #4477 in prose, with no key in its title, is not a slice ($R)"
# P2: page 2 answers 502
FULL=$(jq -nc --argjson x "$(xref 4490 2026-10-11T09:00:00Z 'Part of #4477')" '[range(100)] | map($x)')
ghfx_routes_reset
ghfx_route GET "repos/$S/issues/4477/timeline?per_page=100&page=1" 200 "$FULL"
ghfx_route GET "repos/$S/issues/4477/timeline?per_page=100&page=2" 502 '{"message":"bad gateway"}'
R=$(slice_merged_prs "$S" 4477 "$T/h" 2>/dev/null); RC=$?
[ "$RC" = 1 ] && [ "$R" = ERR:timeline-read ] && ok || bad "P2: a 502 on page 2 is ERR:timeline-read rc 1 (rc=$RC: $R)"
# P3: five full pages, still full at the cap
ghfx_routes_reset
ghfx_route GET "repos/$S/issues/4477/timeline*" 200 "$FULL"
R=$(slice_merged_prs "$S" 4477 "$T/h" 2>/dev/null); RC=$?
[ "$RC" = 1 ] && [ "$R" = ERR:timeline-capped ] && ok || bad "P3: a full page 5 is ERR:timeline-capped rc 1 (rc=$RC: $R)"

# ════════════════════════════════════════════════════════════════════════════
# V. sco_coverage
# ════════════════════════════════════════════════════════════════════════════
V="$T/v"; mkdir -p "$V"
cov() { sco_coverage "$1" "$2" 2>/dev/null; printf '\nrc=%s' "$?"; }
R=$(cov "$DIR/.harness/specs/BH-5240/plan.md" 1)
[ "$(head -1 <<<"$R")" = covered ] && grep -q '^rc=0$' <<<"$R" && ok || bad "V1: the real BH-5240 C1 plan is covered rc 0 ($R)"
mkm() { # mkm <file> <task cell...> — a plan whose matrix has one row per cell
  local f="$1" i=0; shift
  { printf '# BH-4477 plan\n\nSLICE: C1 of #4477\n\n## Requirements coverage\n\n| Requirement | Task | Test |\n|---|---|---|\n'
    for c in "$@"; do i=$((i+1)); printf '| requirement %s | %s | X%s |\n' "$i" "$c" "$i"; done
    printf '\n## Acceptance tests\n- A1\n'; } > "$f"
}
mkm "$V/v2.md" T1 C2 'done on main'
R=$(cov "$V/v2.md" 1)
[ "$(head -1 <<<"$R" | cut -f1)" = uncovered ] && grep -q '^rc=2$' <<<"$R" && grep -qx 'requirement 2' <<<"$R" \
  && ! grep -qx 'requirement 1' <<<"$R" && ok || bad "V2: a C2 row with k=1 is uncovered, naming only that row ($R)"
mkm "$V/v3.md" T1 'deferred to a follow-up'
R=$(cov "$V/v3.md" 1)
[ "$(head -1 <<<"$R" | cut -f1)" = uncovered ] && grep -qx 'requirement 2' <<<"$R" && ok || bad "V3: a deferred row is uncovered ($R)"
printf '# BH-4477\n\nSLICE: C1 of #4477\n\n## Tasks\n- T1\n' > "$V/v4.md"
R=$(cov "$V/v4.md" 1)
[ "$(head -1 <<<"$R")" = "$(printf 'undecided\tno-matrix')" ] && grep -q '^rc=3$' <<<"$R" && ok || bad "V4: no matrix is undecided no-matrix rc 3 ($R)"
mkm "$V/v5.md" T1 'see notes'
R=$(cov "$V/v5.md" 1)
[ "$(head -1 <<<"$R" | cut -f1)" = undecided ] && grep -q '^rc=3$' <<<"$R" && grep -qx 'requirement 2' <<<"$R" && ok || bad "V5: an unknown cell is undecided ($R)"
{ printf '# BH-4477\n\nSLICE: C1 of #4477\n\n```markdown\n## Requirements coverage\n| Requirement | Task | Test |\n|---|---|---|\n| r | T1 | x |\n```\n'; } > "$V/v6.md"
R=$(cov "$V/v6.md" 1)
[ "$(head -1 <<<"$R")" = "$(printf 'undecided\tno-matrix')" ] && ok || bad "V6: a fenced look-alike is undecided no-matrix ($R)"
mkm "$V/v7.md" 'C1' 'C0, T2'
R=$(cov "$V/v7.md" 1)
[ "$(head -1 <<<"$R")" = covered ] && ok || bad "V7: C<j> with j <= k is covered ($R)"
# V8-V12 (lead review lr-6333 of d5fa4decc): a negation and a later slice in
# the Test cell. The real BH-5653 plan (SLICE: C1) has the row "NOT in C1 (A2)
# | child slice C2": it must never read covered at k=1, or the close-out would
# close #5653 with its ci-merge-reuse scope unbuilt.
R=$(cov "$DIR/.harness/specs/BH-5653/plan.md" 1)
[ "$(head -1 <<<"$R" | cut -f1)" = uncovered ] && grep -q '^rc=2$' <<<"$R" && grep -q 'ci-merge-reuse' <<<"$R" \
  && ok || bad "V8: the real BH-5653 C1 plan is uncovered rc 2, naming the ci-merge-reuse row ($R)"
mkm "$V/v9.md" T1 'NOT in C1 (A2)' 'not on main yet' 'Not in this slice (C0 only)'
R=$(cov "$V/v9.md" 1)
[ "$(head -1 <<<"$R")" = "$(printf 'uncovered\t3')" ] && grep -qx 'requirement 2' <<<"$R" && grep -qx 'requirement 3' <<<"$R" \
  && grep -qx 'requirement 4' <<<"$R" && ! grep -qx 'requirement 1' <<<"$R" && ok || bad "V9: each negated cell is uncovered, T1 is not ($R)"
mkt() { # mkt <file> <task> <test> — one row with its own Test cell
  printf '# BH-4477\n\nSLICE: C1 of #4477\n\n## Requirements coverage\n\n| Requirement | Task | Test |\n|---|---|---|\n| requirement 1 | %s | %s |\n' "$2" "$3" > "$1"
}
mkt "$V/v10.md" T1 'child slice C2'
R=$(cov "$V/v10.md" 1)
[ "$(head -1 <<<"$R" | cut -f1)" = uncovered ] && ok || bad "V10: a later slice named in the Test cell is uncovered ($R)"
mkt "$V/v11.md" T1 'not built in this slice'
R=$(cov "$V/v11.md" 1)
[ "$(head -1 <<<"$R" | cut -f1)" = uncovered ] && ok || bad "V11: a Test cell that says not built is uncovered ($R)"
mkm "$V/v12.md" 'T2 (the children reader)' 'T3, child-issue reader' 'T4 (no new route)'
R=$(cov "$V/v12.md" 1)
[ "$(head -1 <<<"$R")" = covered ] && ok || bad "V12: children, child-issue and a negation with no slice or main named stay covered ($R)"
# V16 (lead review lr-6333 of 5db9a1f05): a local record whose name does not
# carry -<KEY>-<n>- never decides the close (the remote branch already refused).
mkdir -p "$V/rec-nokey"; mkm "$V/rec-nokey/plan.md" T1
R="$(sco_plan_fetch o/r 4477 https://github.com/o/r/pull/4500 "$V/rec-nokey" "$V/v16" 2>/dev/null) rc=$?"
[ "$R" = "none:key-mismatch rc=2" ] && ok || bad "V16: a record name with no -<KEY>-4477- is none:key-mismatch rc 2 ($R)"
mkdir -p "$V/proj-BH-4477-remote20261013"; mkm "$V/proj-BH-4477-remote20261013/plan.md" T1
R="$(sco_plan_fetch o/r 4477 https://github.com/o/r/pull/4500 "$V/proj-BH-4477-remote20261013" "$V/v16b" 2>/dev/null) rc=$?"
[ "$R" = "ok:BH-4477 rc=0" ] && ok || bad "V16: a record named -BH-4477- still reads ok ($R)"
# V13-V15 (lead review lr-6333 of 65b1c1765): a test case ID in the Test cell
# (`C1`, `C4–C7`, `C2/C9`) is not a slice. Only `slice` next to a C<j> there is.
R=$(cov "$DIR/.harness/specs/BH-4008/plan.md" 0)
[ "$(head -1 <<<"$R")" = covered ] && grep -q '^rc=0$' <<<"$R" && ok || bad "V13: the real BH-4008 C0 plan (Test cells route-suite C1-C7) is covered rc 0 ($R)"
mkt "$V/v14.md" T1 'C5 (done via the discovered id), C2/C9'
R=$(cov "$V/v14.md" 1)
[ "$(head -1 <<<"$R")" = covered ] && ok || bad "V14: test case IDs in the Test cell keep a T1 row covered ($R)"
mkt "$V/v15.md" T1 'slice C2 builds the route'
R=$(cov "$V/v15.md" 1)
[ "$(head -1 <<<"$R" | cut -f1)" = uncovered ] && ok || bad "V15: 'slice C2' in the Test cell is a later slice ($R)"

# ════════════════════════════════════════════════════════════════════════════
# C. the close-out, end to end
# ════════════════════════════════════════════════════════════════════════════
REC="$T/h/builds/proj-BH-4477-remote20261012080305"
PR_BODY=$'## Summary\nPart of #4477\n\nharness build'
NOKID_LINE='Slice delivered: #4500. No child issue carries the rest yet, so this issue stays open and keeps ai-build.'
COVERED_PLAN=$(mkm "$V/c1.md" T1 'T2, T3' 'done on main, b124c169'; cat "$V/c1.md")
CHILD_PLAN=$(mkm "$V/c2.md" T1 'C2 (the export route)' 'done on main'; cat "$V/c2.md")
REMAINDER_PLAN=$'# BH-4477\n\nSLICE: C1 of #4477\n\n## Later slices\n- C2: Add the export route.\n- C3: Wire the console button.\n'
PARENT_BODY=$'The master ticket.\n\n## Scope\n1. alpha must export\n2. beta must import\n\n## Acceptance tests\n- A1'
: > "$T/all-argv.log"
reset() { # a fresh record and stub state
  cat "$T/gh-argv.log" >> "$T/all-argv.log" 2>/dev/null
  ghfx_routes_reset; ghfx_log_reset
  : > "$T/posted.txt"; : > "$T/h/logs/ALERTS.log"
  scratch_rm "$REC"; mkdir -p "$REC"; echo APPROVE > "$REC/RESULT"
  scratch_rm "$T/h/state/slice-closeout"
  rm -rf "$T/created"; rm -f "$T/create.n" "$T/close-fail" "$T/parent-closed"
}
# routes <spec-status> <spec-text> [parent-state]
routes() {
  local b64; b64=$(printf '%s' "$2" | base64 | tr -d '\n')
  ghfx_route GET    "repos/$S/pulls/4500" 200 "$(jq -nc --arg b "$PR_BODY" --arg sha "$MSHA" \
                       '{number:4500,state:"closed",title:"BH-4477: slice C1 of the master",body:$b,merged_at:"2026-10-12T09:07:00Z",merge_commit_sha:$sha}')"
  ghfx_route GET    "repos/$S/issues/4477/timeline*" 200 "$TIMELINE"
  ghfx_route GET    "repos/$S/contents/.harness/specs/BH-4477/plan.md*" "$1" "$(jq -nc --arg c "$b64" '{encoding:"base64",content:$c}')"
  ghfx_route POST   "repos/$S/issues/4477/comments" 201 '{"id":1}'
  if [ -e "$T/close-fail" ]; then ghfx_route PATCH "repos/$S/issues/4477" 500 '{"message":"fixture"}'
  else ghfx_route PATCH "repos/$S/issues/4477" 200 '{"state":"closed"}'; fi
  ghfx_route DELETE "repos/$S/issues/4477/labels/ai-build" 200 '[]'
  ghfx_route GET    "repos/$S/issues/4477" 200 "$(jq -nc --arg b "$PARENT_BODY" '{number:4477,state:"closed",title:"BH-4477: master",body:$b,labels:[{name:"ai-build"}]}')" "$T/parent-closed"
  ghfx_route GET    "repos/$S/issues/4477" 200 "$(jq -nc --arg s "${3:-open}" --arg b "$PARENT_BODY" '{number:4477,state:$s,title:"BH-4477: master",body:$b,labels:[{name:"ai-build"},{name:"hotfix"}]}')"
  ghfx_route GET    "repos/$S/issues" 200 '[{"number":4478,"state":"open","title":"BH-4478: dependent","body":"Blocked-by: #4477 (hard)","labels":[{"name":"ai-build"}]},{"number":4479,"state":"open","title":"BH-4479","body":"unrelated","labels":[{"name":"ai-build"}]}]'
  ghfx_route GET    "repos/$S/issues/4601" 200 '{"number":4601,"state":"open","title":"BH-4477.2: x"}'
  ghfx_route GET    "repos/$S/issues/4602" 200 '{"number":4602,"state":"open","title":"BH-4477.3: y"}'
}
n_create() { find "$T/created" -name '*.argv' 2>/dev/null | grep -c .; }
n_post()   { grep -c -- "-X POST repos/$S/issues/4477/comments" "$T/gh-argv.log"; }
n_patch()  { grep -c -- "-X PATCH repos/$S/issues/4477" "$T/gh-argv.log"; }
n_delete() { grep -c -- "-X DELETE repos/$S/issues/4477/labels/ai-build" "$T/gh-argv.log"; }
ics() { issue_close_shipped "$S" 4477 "Merged in $PRURL. Closing this issue." "$T/h" "$PRURL" "$REC" 2>/dev/null; }
mcs() { mc_close_shipped "$S" 4477 "Merged in $PRURL (merge conductor). Closing this issue." "$REC" "$PRURL" 2>/dev/null; }
rerun() { cat "$T/gh-argv.log" >> "$T/all-argv.log"; ghfx_log_reset; : > "$T/posted.txt"; }
D="$REC/slice-closeout"

for FN in ics mcs; do
  # C1: every row covered -> the parent closes with both merged PR links
  reset; routes 200 "$COVERED_PLAN"
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "closed-slice:closed:covered:#4500,#4490" ] && ok || bad "C1[$FN]: word (rc=$RC w=$W)"
  [ "$(n_post)" = 1 ] && grep -qF "$PRURL" "$T/posted.txt" && grep -qF "$PRURL0" "$T/posted.txt" && ok \
    || bad "C1[$FN]: one comment naming both merged PRs (post=$(n_post): $(head -c 400 "$T/posted.txt"))"
  grep -q 'No child issue carries the rest' "$T/posted.txt" && bad "C1[$FN]: the no-children comment must not post" || ok
  [ "$(grep -c '—' "$T/posted.txt")" = 0 ] && ok || bad "C1[$FN]: no em dash in the close comment"
  [ "$(n_patch)" = 1 ] && [ "$(n_delete)" = 1 ] && [ "$(n_create)" = 0 ] && ok \
    || bad "C1[$FN]: one close PATCH, one ai-build DELETE, no create (patch=$(n_patch) delete=$(n_delete) create=$(n_create))"
  [ "$(cat "$D/closed" 2>/dev/null)" = "covered:#4500,#4490" ] && [ -f "$D/close-commented" ] && ok \
    || bad "C1[$FN]: the closed ledger and close-commented ($(cat "$D/closed" 2>/dev/null))"
  grep -q 'slice-no-children' "$T/h/logs/ALERTS.log" && bad "C1[$FN]: no warn alert on a close" || ok

  # C4: a second close-out on the same record writes nothing and says the same
  rerun
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "closed-slice:closed:covered:#4500,#4490" ] && ok || bad "C4[$FN]: same word on the second event (rc=$RC w=$W)"
  [ "$(n_post)" = 0 ] && [ "$(n_patch)" = 0 ] && [ "$(n_delete)" = 0 ] && ok \
    || bad "C4[$FN]: the second event writes nothing (post=$(n_post) patch=$(n_patch) delete=$(n_delete))"

  # C2: one row is a later slice -> one child with that row, then the close
  reset; routes 200 "$CHILD_PLAN"
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "closed-slice:closed:child:#4601:#4500,#4490" ] && ok || bad "C2[$FN]: word (rc=$RC w=$W; $(cat "$D/fc-out.txt" 2>/dev/null | tail -3))"
  [ "$(n_create)" = 1 ] && ok || bad "C2[$FN]: exactly one issue create ($(n_create))"
  B="$T/created/4601.md"
  grep -qF 'requirement 2' "$B" 2>/dev/null && grep -qx 'Part of #4477' "$B" && ok \
    || bad "C2[$FN]: the child body has the uncovered row and Part of #4477 ($(head -c 600 "$B" 2>/dev/null))"
  grep -qF 'requirement 1' "$B" 2>/dev/null && bad "C2[$FN]: a covered row is not in the child" || ok
  grep -q 'Rest of BH-4477' "$T/created/4601.title" 2>/dev/null && ok || bad "C2[$FN]: child title ($(cat "$T/created/4601.title" 2>/dev/null))"
  grep -qF '#4478' "$B" 2>/dev/null && ! grep -qF '#4479' "$B" && ok || bad "C2[$FN]: the child names the open dependent #4478 only"
  grep -q -- '--label hotfix' "$T/created/4601.argv" 2>/dev/null && ok || bad "C2[$FN]: the child inherits the parent's hotfix label"
  [ "$(n_post)" = 1 ] && grep -q '#4601' "$T/posted.txt" && grep -qF "$PRURL" "$T/posted.txt" && ok \
    || bad "C2[$FN]: one parent comment naming #4601 and the PR (post=$(n_post): $(head -c 400 "$T/posted.txt"))"
  grep -q 'stays open' "$T/posted.txt" && bad "C2[$FN]: no comment may say the parent stays open" || ok
  [ "$(n_patch)" = 1 ] && [ "$(n_delete)" = 1 ] && ok || bad "C2[$FN]: one close, one strip (patch=$(n_patch) delete=$(n_delete))"
  CR=$(grep -n -- '-X POST repos/example-org/proj/issues/4477/comments\|issue create\|-X PATCH repos/example-org/proj/issues/4477' "$T/gh-argv.log" | cut -d: -f2- | cut -c1-12 | paste -sd'|' -)
  [ "$CR" = "issue create|api -i -X PO|api -i -X PA" ] && ok || bad "C2[$FN]: order is create, comment, close ($CR)"
  [ "$(cat "$D/child" 2>/dev/null)" = "#4601" ] && ok || bad "C2[$FN]: D/child ledger"

  # C3: the spec read answers 503 -> defer, write nothing
  reset; routes 503 "$COVERED_PLAN"
  W=$($FN); RC=$?
  [ "$RC" = 1 ] && [ "$W" = close-deferred:slice-closeout ] && ok || bad "C3[$FN]: a 503 on the spec defers (rc=$RC w=$W)"
  [ "$(n_post)" = 0 ] && [ "$(n_patch)" = 0 ] && [ "$(n_delete)" = 0 ] && [ "$(n_create)" = 0 ] && ok \
    || bad "C3[$FN]: nothing written (post=$(n_post) patch=$(n_patch) delete=$(n_delete) create=$(n_create))"

  # C5 / C6: the close fails after the child is filed; the next run resumes
  reset; touch "$T/close-fail"; routes 200 "$CHILD_PLAN"
  W=$($FN); RC=$?
  [ "$RC" = 1 ] && [ "$W" = close-deferred:slice-closeout ] && [ ! -e "$D/closed" ] && ok \
    || bad "C5[$FN]: a failed close defers and writes no closed ledger (rc=$RC w=$W)"
  [ "$(n_delete)" = 0 ] && ok || bad "C6[$FN]: no label DELETE after a failed close ($(n_delete))"
  [ "$(n_create)" = 1 ] && [ "$(n_post)" = 1 ] && ok || bad "C5[$FN]: run 1 filed one child and posted once (create=$(n_create) post=$(n_post))"
  rm -f "$T/close-fail"; ghfx_routes_reset; routes 200 "$CHILD_PLAN"; rerun
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "closed-slice:closed:child:#4601:#4500,#4490" ] && ok || bad "C5[$FN]: run 2 closes (rc=$RC w=$W)"
  [ "$(n_create)" = 1 ] && [ "$(n_post)" = 0 ] && [ "$(n_patch)" = 1 ] && [ "$(n_delete)" = 1 ] && ok \
    || bad "C5[$FN]: run 2 files nothing more, posts nothing more, closes once (create=$(n_create) post=$(n_post) patch=$(n_patch))"

  # C7: a remote record whose spec names C2 and C3 -> both filed, parent open
  reset; routes 200 "$REMAINDER_PLAN"
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "kept-slice:filed:remainder-filed:#4601,#4602" ] && ok || bad "C7[$FN]: word (rc=$RC w=$W)"
  [ "$(cat "$T/created/4601.title" 2>/dev/null)" = "BH-4477.2: Add the export route" ] \
    && [ "$(cat "$T/created/4602.title" 2>/dev/null)" = "BH-4477.3: Wire the console button" ] && ok \
    || bad "C7[$FN]: titles .2 and .3 ($(cat "$T/created/"*.title 2>/dev/null | tr '\n' '|'))"
  [ "$(n_patch)" = 0 ] && ok || bad "C7[$FN]: the parent is not closed"

  # C8: the parent was closed by hand -> today's path
  reset; routes 200 "$COVERED_PLAN" closed
  W=$($FN); RC=$?
  [ "$W" = kept-slice:no-children+label-kept ] && [ "$(n_create)" = 0 ] && [ "$(n_patch)" = 0 ] && ok \
    || bad "C8[$FN]: a closed parent takes today's path (w=$W create=$(n_create) patch=$(n_patch))"

  # C9: no spec at the merge commit -> one child quoting the parent's Scope
  reset; routes 404 "$COVERED_PLAN"
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "closed-slice:closed:child:#4601:#4500,#4490" ] && ok || bad "C9[$FN]: word (rc=$RC w=$W)"
  grep -q 'Rest of BH-4477' "$T/created/4601.title" 2>/dev/null && grep -qF 'alpha must export' "$T/created/4601.md" 2>/dev/null \
    && grep -qF 'beta must import' "$T/created/4601.md" && ok || bad "C9[$FN]: the child quotes the parent's Scope ($(head -c 500 "$T/created/4601.md" 2>/dev/null))"
  [ "$(n_patch)" = 1 ] && ok || bad "C9[$FN]: the parent closes"

  # C10: switched off, and a dry run -> today's word and writes
  reset; routes 200 "$COVERED_PLAN"
  W=$(SLICE_CLOSEOUT_SETTLE=0 $FN); RC=$?
  [ "$W" = kept-slice:no-children+label-kept ] && [ "$(n_patch)" = 0 ] && [ "$(n_post)" = 1 ] && [ "$(head -1 "$T/posted.txt")" = "$NOKID_LINE" ] && ok \
    || bad "C10[$FN]: SLICE_CLOSEOUT_SETTLE=0 is today's path (w=$W patch=$(n_patch) post=$(n_post))"
  reset; routes 200 "$CHILD_PLAN"
  W=$(FILE_CHILDREN_DRY_RUN=1 $FN); RC=$?
  [ "$W" = kept-slice:no-children+label-kept ] && [ "$(n_create)" = 0 ] && [ "$(n_patch)" = 0 ] && ok \
    || bad "C10[$FN]: a dry run is today's path (w=$W create=$(n_create) patch=$(n_patch))"
done

# C1b: a LOCAL plan with no remainder (the BH-5961 S3u shape) now closes too,
# instead of paging SLICE_REMAINDER_UNKNOWN and staying open.
reset; routes 200 "$COVERED_PLAN"; cp "$V/c1.md" "$REC/plan.md"
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = "closed-slice:closed:covered:#4500,#4490" ] && ! grep -q SLICE_REMAINDER_UNKNOWN "$T/h/logs/ALERTS.log" && ok \
  || bad "C1b: a local no-remainder plan closes with no page (rc=$RC w=$W alerts=$(cat "$T/h/logs/ALERTS.log"))"
grep -q -- "contents/" "$T/gh-argv.log" && bad "C1b: a local plan needs no contents read" || ok

# C1c: no record dir at all -> the ledger lives under state/slice-closeout
reset; routes 200 "$COVERED_PLAN"
W=$(issue_close_shipped "$S" 4477 "x" "$T/h" "$PRURL" "" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ -s "$T/h/state/slice-closeout/example-org_proj-4477-pr4500/closed" ] && ok \
  || bad "C1c: with no record the ledger is state/slice-closeout/<owner>_<repo>-<n>-pr<prn> (rc=$RC w=$W)"

# C11: a PARTIAL build (BH-5798) whose plan matrix is all T<n> never closes as
# covered. Its not-met items become the one child, then the parent closes.
PARTIAL_BODY=$'## Summary\nRefs #4477\n\n## Acceptance self-check\n\nNot every acceptance item is met, so this PR says Refs, not Closes, and a merge leaves the issue open. Not met:\n- [ ] claim 2: the export route answers 200 (not met: REFUTED)\n'
for FN in ics mcs; do
  # C11a: the reviewer's probe. A local record, plan.md with T1/T2 and no
  # SLICE line, a `Refs` PR body with a Not-met list, no evidence.json.
  reset; PR_BODY="$PARTIAL_BODY" routes 200 "$COVERED_PLAN"
  printf '# BH-4477 plan\n\n## Requirements coverage\n\n| Requirement | Task | Test |\n|---|---|---|\n| requirement 1 | T1 | X1 |\n| requirement 2 | T2 | X2 |\n' > "$REC/plan.md"
  W=$($FN); RC=$?
  case "$W" in *covered*) bad "C11a[$FN]: a partial build must not close as covered (w=$W)" ;; *) ok ;; esac
  [ "$RC" = 0 ] && [ "$W" = "closed-slice:closed:child:#4601:#4500,#4490" ] && ok || bad "C11a[$FN]: word (rc=$RC w=$W)"
  grep -q 'Everything in this ticket is now on main' "$T/posted.txt" && bad "C11a[$FN]: no 'Everything ... on main' comment on a partial build" || ok
  grep -qF 'the export route answers 200' "$T/created/4601.md" 2>/dev/null && grep -q 'partial build' "$T/created/4601.md" && ok \
    || bad "C11a[$FN]: the child carries the not-met claim ($(head -c 600 "$T/created/4601.md" 2>/dev/null))"
  [ "$(n_create)" = 1 ] && grep -q '#4601' "$T/posted.txt" && grep -q 'did not meet' "$T/posted.txt" && ok \
    || bad "C11a[$FN]: one child, and the parent comment names it (create=$(n_create): $(head -c 400 "$T/posted.txt"))"
  # C11b: the record's evidence.json has a REFUTED claim, and the PR body has
  # no self-check section: the evidence alone makes it partial.
  reset; routes 200 "$COVERED_PLAN"
  jq -n '{claims:[{n:1,claim:"alpha exports",verdict:"PROVEN"},{n:3,claim:"beta imports",verdict:"REFUTED"}]}' > "$REC/evidence.json"
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "closed-slice:closed:child:#4601:#4500,#4490" ] && grep -qF 'claim 3: beta imports' "$T/created/4601.md" 2>/dev/null \
    && ! grep -qF 'alpha exports' "$T/created/4601.md" && ok || bad "C11b[$FN]: a REFUTED evidence claim is the rest (rc=$RC w=$W)"
  # C11c: the PR read for the partial check answers 502 -> defer, write nothing
  reset; routes 200 "$COVERED_PLAN"; cp "$V/c1.md" "$REC/plan.md"
  ghfx_routes_reset; ghfx_route GET "repos/$S/pulls/4500" 502 '{"message":"bad gateway"}'; routes 200 "$COVERED_PLAN"
  W=$($FN); RC=$?
  [ "$RC" = 1 ] && [ "$W" = close-deferred:slice-closeout ] && [ ! -s "$D/verdict" ] && ok || bad "C11c[$FN]: a failed PR read defers and freezes no verdict (rc=$RC w=$W)"
  [ "$(n_post)" = 0 ] && [ "$(n_patch)" = 0 ] && [ "$(n_create)" = 0 ] && ok || bad "C11c[$FN]: nothing written"
done

# C12: a PR whose title key is another ticket's never lets that ticket's plan
# close this one: no covered close, and no contents read of the foreign spec.
reset; routes 200 "$COVERED_PLAN"
ghfx_routes_reset
ghfx_route GET "repos/$S/pulls/4500" 200 "$(jq -nc --arg sha "$MSHA" '{number:4500,state:"closed",title:"BH-9999: another ticket",body:"Part of #4477",merged_at:"2026-10-12T09:07:00Z",merge_commit_sha:$sha}')"
routes 200 "$COVERED_PLAN"
W=$(ics); RC=$?
case "$W" in *covered*) bad "C12: a foreign key must not close as covered (w=$W)" ;; *) ok ;; esac
grep -q -- "contents/.harness/specs/BH-9999" "$T/gh-argv.log" && bad "C12: no read of the foreign spec" || ok
grep -q 'key-mismatch' "$D/verdict" 2>/dev/null && ok || bad "C12: the verdict names key-mismatch ($(cat "$D/verdict" 2>/dev/null))"

# ════════════════════════════════════════════════════════════════════════════
# H1. bin/hotfix-after-deploy.sh logs the closed-slice word
# ════════════════════════════════════════════════════════════════════════════
cat "$T/gh-argv.log" >> "$T/all-argv.log"
H="$T/hf"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/state" "$H/flags" "$H/builds"
cp "$DIR/bin/hotfix-after-deploy.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/prod-url.sh" "$H/bin/"
scratch_install_closure bin/hotfix-after-deploy.sh "$H" >/dev/null || { echo "FAIL: closure install failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/"*.sh
printf 'project-1 o/p https://tproj.example - 2 box-t 192.0.2.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"; : > "$H/env/project-1.env"
ghfx_extra <<'SH'
case "$A" in
  *"-X POST"*"/comments"*) ;;
  *"-X PATCH repos/o/p/issues/378"*) touch "$GHFX/hf-closed" ;;
  "api repos/"*"/comments"*) echo 4242; exit 0 ;;
  "api repos/"*"/issues/"*) echo open; exit 0 ;;
  "api repos/"*) echo 1; exit 0 ;;
esac
SH
HB="$H/builds/project-1-BH-378-remote20261012080305"; mkdir -p "$HB"
jq -n '{fp:"deadfp",mode:"endpoint",decision:"applied",files:[{path:"scripts/migrations/a.sql",status:"applied"}],after_deploy:null}' \
  > "$HB/hotfix-migrate.json"
HSPEC=$(printf '# BH-378\n\nSLICE: C1 of #378\n\n## Requirements coverage\n| Requirement | Task | Test |\n|---|---|---|\n| the fix | T1 | A1 |\n' | base64 | tr -d '\n')
ghfx_routes_reset; ghfx_log_reset; rm -f "$T/hf-closed"
ghfx_route GET    "repos/o/p/pulls/9" 200 "$(jq -nc --arg sha "$MSHA" '{number:9,state:"closed",title:"BH-378: hotfix slice",body:"Hotfix.\nPart of #378",merged_at:"2026-10-12T09:07:00Z",merge_commit_sha:$sha}')"
ghfx_route GET    "repos/o/p/issues/378/timeline*" 200 "[$(xref 9 2026-10-12T09:07:00Z 'Part of #378' | sed 's#example-org/proj#o/p#g')]"
ghfx_route GET    "repos/o/p/contents/.harness/specs/BH-378/plan.md*" 200 "$(jq -nc --arg c "$HSPEC" '{encoding:"base64",content:$c}')"
ghfx_route POST   "repos/o/p/issues/378/comments" 201 '{"id":1}'
ghfx_route PATCH  "repos/o/p/issues/378" 200 '{"state":"closed"}'
ghfx_route DELETE "repos/o/p/issues/378/labels/ai-build" 200 '[]'
ghfx_route GET    "repos/o/p/issues/378" 200 '{"state":"closed","body":"m","labels":[{"name":"ai-build"}]}' "$T/hf-closed"
ghfx_route GET    "repos/o/p/issues/378" 200 '{"state":"open","body":"m","labels":[{"name":"ai-build"}]}'
ghfx_route GET    "repos/o/p/issues" 200 '[]'
( cd "$T" && env HARNESS="$H" FLEET_CONF="$H/fleet.conf" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" \
    SLUG=o/p PR_URL=https://github.com/o/p/pull/9 \
    bash "$H/bin/hotfix-after-deploy.sh" project-1 "$HB" abc1234def5678 > "$T/hf.out" 2> "$T/hf.err" ); RC=$?
[ "$RC" = 0 ] && ok || bad "H1: the hotfix lane must exit 0 (rc=$RC; $(head -c 300 "$T/hf.err"))"
grep -q 'closed-slice:closed:covered:#9' "$T/hf.err" && ok || bad "H1: the lane logs the closed-slice word ($(grep -i slice "$T/hf.err" | head -3))"
grep -q 'left issue 378 open' "$T/hf.err" && bad "H1: a closed slice is not 'left open'" || ok
grep -qE 'issue 378.*(deferred|by hand)' "$H/logs/ALERTS.log" 2>/dev/null && bad "H1: no deferral alert ($(cat "$H/logs/ALERTS.log"))" || ok
[ "$(grep -c -- '-X PATCH repos/o/p/issues/378' "$T/gh-argv.log")" = 1 ] && ok || bad "H1: the hotfix lane closes issue 378 once"

echo "slice-closeout-closes (BH-6308): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
