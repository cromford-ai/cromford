#!/bin/bash
# tests/slice-remainder.bh-5961-test.sh — BH-5961: when a `SLICE: C<k> of #N`
# merge finds no open child, the close-out files the remaining slices the plan
# names (C<k+1>..C<m>) as child issues, or pages once when it cannot.
#
# WHAT THIS PINS, on the children.json the parser writes, the `gh issue create`
# argv and body files that reached the stub `gh`, the REST argv log, the comment
# bodies posted, the word each close-out prints and the lane-alert stub's log:
#   P1-P9  slice_remainder_parse: the remainder forms plans use, and the
#          negatives that must never file (acceptance ids, ranges, prose,
#          fences, quotes, earlier slices, gaps, another issue's SLICE line)
#   F1     the `slice` kind's child title and footer text
#   S1-S9  issue_close_shipped and mc_close_shipped end to end: filed once,
#          paged once, resumed after a crash, deduped by the lock and ledger,
#          switched off, dry run, and bin/hotfix-after-deploy.sh's deferral text
#
#   HARNESS_TEST_SANDBOX=1 bash tests/slice-remainder.bh-5961-test.sh   exit 0 = pass
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
SRLIB="$DIR/bin/lib/slice-remainder.sh"
[ -r "$SRLIB" ] && ok || bad "setup: $SRLIB is missing"

mkdir -p "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/flags" "$T/h/builds" "$T/tmp"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || { echo "FAIL: closure install failed"; exit 1; }
# The conductor's own closure must carry the new lib and the filer: that is the
# wiring a live box gets, not a list this suite chose.
for f in slice-remainder.sh file-children.sh fc-issues.sh tracker/github-issues.sh; do
  [ -r "$T/h/bin/lib/$f" ] && ok || bad "setup: the merge conductor's closure does not reach bin/lib/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/h/logs/ALERTS.log"\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
: > "$T/h/env/global.env"
ghfx_init
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH"
unset FILE_CHILDREN_DRY_RUN DECOMPOSE_DRY_RUN SLICE_REMAINDER_FILE SLICE_REMAINDER_MAX GH_ISSUES_REPO
# The stub: comment bodies to posted.txt; `gh issue create` answers issue
# 4600+n, records its argv and body, and fails on call number create-fail-at.
ghfx_extra <<'SH'
case "$A" in
  *"-X POST"*"/comments"*)
    for a in "$@"; do case "$a" in body=@*) { cat "${a#body=@}"; printf '\n----\n'; } >> "$GHFX/posted.txt" ;; esac; done ;;
  "issue create"*)
    n=$(( $(cat "$GHFX/create.n" 2>/dev/null || echo 0) + 1 ))
    if [ -e "$GHFX/create-fail-at" ] && [ "$n" = "$(cat "$GHFX/create-fail-at")" ]; then
      echo "HTTP 502: fixture create failure"; exit 1
    fi
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

# ════════════════════════════════════════════════════════════════════════════
# P. slice_remainder_parse
# ════════════════════════════════════════════════════════════════════════════
P="$T/p"; mkdir -p "$P"
PRURL=https://github.com/example-org/proj/pull/4500
parse() { # parse <plan-file> [parent] -> "<word> rc=<rc>"; JSON in $P/out.json
  local w rc
  rm -f "$P/out.json"
  w=$(slice_remainder_parse "$1" "${2:-4477}" "$P/out.json" "$PRURL" 2>"$P/parse.err"); rc=$?
  printf '%s rc=%s' "$w" "$rc"
}
jt() { jq -r "$1" "$P/out.json" 2>/dev/null; }

cat > "$P/p1.md" <<'EOF'
# BH-4477 plan

SLICE: C0 of #4477

## Scope

This build is C0.

### Later slices
- C1: Add the export route. It reads the rows and writes CSV.
  It streams the rows, it never buffers them.
- **C2**: Wire the console button (after C1).

## Tasks
- T1 do the C0 work.
EOF
R=$(parse "$P/p1.md")
[ "$R" = "ok:2 rc=0" ] && ok || bad "P1: two remainder items must parse ok:2 rc 0 (got $R; $(head -c 300 "$P/parse.err"))"
[ "$(jt '.[0].title')" = "Add the export route" ] && ok || bad "P1: title 1 ($(jt '.[0].title'))"
[ "$(jt '.[1].title')" = "Wire the console button (after C1)" ] && ok || bad "P1: title 2 ($(jt '.[1].title'))"
[ "$(jt '[.[].ordinal] | join(",")')" = "1,2" ] && ok || bad "P1: ordinals ($(jt '[.[].ordinal] | join(",")'))"
grep -qF 'It streams the rows, it never buffers them.' <<<"$(jt '.[0].body')" && ok || bad "P1: the continuation line belongs to C1's body"
grep -qF "Remaining slice C1 of #4477, as the plan of the merged pull request $PRURL wrote it:" <<<"$(jt '.[0].body')" && ok \
  || bad "P1: C1's body preamble ($(jt '.[0].body' | head -2))"
grep -qF 'None were named for this slice. Its own plan writes them.' <<<"$(jt '.[1].body')" && ok || bad "P1: no tagged test reads as none"
[ "$(jt '.[] | .body' | grep -c '—')" = 0 ] && ok || bad "P1: no em dash in the fixed body text"

cp "$P/p1.md" "$P/p2.md"
cat >> "$P/p2.md" <<'EOF'

## Acceptance tests
- (C1) GET /export returns 200
- [C2] button posts once
- an untagged test for this build
EOF
R=$(parse "$P/p2.md")
[ "$R" = "ok:2 rc=0" ] && ok || bad "P2: ok:2 rc 0 (got $R)"
grep -qF '(C1) GET /export returns 200' <<<"$(jt '.[0].body')" && ok || bad "P2: C1 carries its tagged test"
grep -qE 'button posts once|untagged' <<<"$(jt '.[0].body')" && bad "P2: C1 must carry only its own test" || ok
grep -qF '[C2] button posts once' <<<"$(jt '.[1].body')" && ok || bad "P2: C2 carries its tagged test"
grep -qE 'GET /export|untagged' <<<"$(jt '.[1].body')" && bad "P2: C2 must carry only its own test" || ok
[ "$(jt '.[1].after | map(tostring) | join(",")')" = "1" ] && [ "$(jt '.[0].after | length')" = 0 ] && ok \
  || bad "P2: C2 after=[1], C1 after=[] (got $(jt '[.[].after]' | tr -d ' \n'))"
# A sub-heading naming one slice tags every item under it.
cat > "$P/p2b.md" <<'EOF'
SLICE: C0 of #4477
## Later slices
- C1: Add the export route.
- C2: Wire the console button.
## Acceptance tests
### C2 checks
- the button is disabled while a post runs
EOF
R=$(parse "$P/p2b.md")
[ "$R" = "ok:2 rc=0" ] && grep -qF 'the button is disabled while a post runs' <<<"$(jt '.[1].body')" \
  && ! grep -qF 'the button is disabled' <<<"$(jt '.[0].body')" && ok || bad "P2b: a '### C2' sub-heading tags its items for C2 only ($R)"

cat > "$P/p3.md" <<'EOF'
# BH-4477
**SLICE:** C2 of #4477

## Remaining slices
- C3: Add the importer.
- C4: Wire the import page, depends on C3.
EOF
R=$(parse "$P/p3.md")
[ "$R" = "ok:2 rc=0" ] && [ "$(jt '[.[].ordinal] | join(",")')" = "3,4" ] && ok || bad "P3: SLICE C2 gives ordinals 3,4 ($R, $(jt '[.[].ordinal]' | tr -d ' \n'))"
[ "$(jt '.[1].after | map(tostring) | join(",")')" = "1" ] && [ "$(jt '.[0].after | length')" = 0 ] && ok \
  || bad "P3: C4 depends on C3 is after position 1 ($(jt '[.[].after]' | tr -d ' \n'))"

printf 'SLICE: C2 of #4477\n\n## Later\n- C1: old work, already merged.\n- C3: new work.\n' > "$P/p4.md"
R=$(parse "$P/p4.md")
[ "$R" = "ok:1 rc=0" ] && [ "$(jt '.[0].ordinal')" = 3 ] && [ "$(jt '.[0].title')" = "new work" ] && ok \
  || bad "P4: an item at or below k is skipped ($R, $(jt '.[0].title'))"
# An H1 title that says "verification" is the document title, not a section.
printf '# BH-4477 Post-merge live verification contract (slice C0)\n\nSLICE: C0 of #4477\n\n### Child tickets\n- C1: the worker route.\n' > "$P/p4c.md"
R=$(parse "$P/p4c.md")
[ "$R" = "ok:1 rc=0" ] && [ "$(jt '.[0].title')" = "the worker route" ] && ok || bad "P4c: an H1 title never excludes the plan ($R)"
# A title cut at 80 characters never ends inside an open parenthesis.
printf 'SLICE: C0 of #4477\n## Later\n- **C1**: onboarding state store (jobs-worker D1 table + route + `bin/lib/onboard-state.sh`) + console chip.\n' > "$P/p4d.md"
R=$(parse "$P/p4d.md")
[ "$R" = "ok:1 rc=0" ] && [ "$(jt '.[0].title')" = "onboarding state store" ] && ok || bad "P4d: a cut title drops an open parenthesis ($R: $(jt '.[0].title'))"
# The older sentence form sets k too.
printf '# Plan\n\nThe build for THIS ticket is C1.\n\n## Later\n- C2: the rest.\n' > "$P/p4b.md"
R=$(parse "$P/p4b.md")
[ "$R" = "ok:1 rc=0" ] && [ "$(jt '.[0].ordinal')" = 2 ] && ok || bad "P4b: 'The build for THIS ticket is C1' sets k=1 ($R)"

{ printf 'SLICE: C0 of #4477\n\n## Scope of this slice\n'
  printf -- '- C1 Cloudflare apply: D1 create and the schema apply, all of it ledgered.\n'
  printf -- '- C2 hub apply (Fly app via the existing provision path).\n\n'
  printf '## Acceptance tests\n'
  for i in 1 2 3 4 5 6 7 8; do printf -- '- **C%s** the catalog parses case %s.\n' "$i" "$i"; done
} > "$P/p5.md"
R=$(parse "$P/p5.md")
[ "$R" = "ok:2 rc=0" ] && ok || bad "P5: the BH-4081 shape must give ok:2 (got $R)"
[ "$(jt '.[0].title')" = "Cloudflare apply" ] && [ "$(jt '.[1].title')" = "hub apply (Fly app via the existing provision path)" ] && ok \
  || bad "P5: titles ($(jt '.[0].title') | $(jt '.[1].title'))"
grep -q 'the catalog parses' <<<"$(jt '.[].body')" && bad "P5: an acceptance id '**C1**' is not a tag" || ok

cat > "$P/p6.md" <<'EOF'
SLICE: C0 of #4477

## Scope
C0 covers the two catalogs and the parser.
C3 project Rules editing in the console; C4 e2e drive of the whole flow.
- C1–C4 and D1–D3 as in T3/T4.
- C1/C2 shared work on the parser.
- C1, C2 and C3 later.
- C1 and C2 together.
EOF
R=$(parse "$P/p6.md")
[ "$R" = "none rc=2" ] && ok || bad "P6: ranges, lists and prose must give none rc 2 (got $R)"

{ printf 'SLICE: C0 of #4477\n\n## Scope\n```text\n- C1: inside a fence\n```\n> - C1: quoted\n'
  printf '````\n```\n- C2: inside a longer fence\n```\n````\n'
} > "$P/p7.md"
R=$(parse "$P/p7.md")
[ "$R" = "none rc=2" ] && ok || bad "P7: fenced and quoted items must give none (got $R)"
printf 'SLICE: C0 of #4477\n\n~~~~\n- C1: after an unterminated fence\n- C2: still hidden\n' > "$P/p7b.md"
R=$(parse "$P/p7b.md")
[ "$R" = "none rc=2" ] && ok || bad "P7: an unterminated fence hides the rest (got $R)"

printf 'SLICE: C0 of #4477\n## Later\n- C1: one.\n- C1: again.\n' > "$P/p8a.md"
R=$(parse "$P/p8a.md"); [ "$R" = "bad:duplicate:C1 rc=2" ] && ok || bad "P8: duplicate (got $R)"
printf 'SLICE: C0 of #4477\n## Later\n- C1: one.\n- C3: three.\n' > "$P/p8b.md"
R=$(parse "$P/p8b.md"); [ "$R" = "bad:gap:C3 rc=2" ] && ok || bad "P8: gap (got $R)"
printf 'SLICE: C1 of #4477\n## Later\n- C10: ten.\n' > "$P/p8c.md"
R=$(parse "$P/p8c.md"); [ "$R" = "bad:gap:C10 rc=2" ] && ok || bad "P8: C10 after k=1 is a gap (got $R)"
{ printf 'SLICE: C0 of #4477\n## Later\n'; for i in 1 2 3 4 5 6 7; do printf -- '- C%s: part %s.\n' "$i" "$i"; done; } > "$P/p8d.md"
R=$(parse "$P/p8d.md"); [ "$R" = "bad:too-many:7 rc=2" ] && ok || bad "P8: 7 items over the default max 6 (got $R)"
R=$(SLICE_REMAINDER_MAX=2 parse "$P/p2.md"); [ "$R" = "ok:2 rc=0" ] && ok || bad "P8: max 2 allows 2 (got $R)"
printf 'SLICE_REMAINDER_MAX=1\n' > "$T/h/env/global.env"
R=$(parse "$P/p2.md"); [ "$R" = "bad:too-many:2 rc=2" ] && ok || bad "P8: SLICE_REMAINDER_MAX=1 from env/global.env (got $R)"
: > "$T/h/env/global.env"
printf 'SLICE: C0 of #44770\n## Later\n- C1: one.\n' > "$P/p8e.md"
R=$(parse "$P/p8e.md"); [ "$R" = "bad:no-slice-line rc=2" ] && ok || bad "P8: another issue's SLICE line (got $R)"
printf 'SLICE: C0 of #4477\n## Later\n- C1:\n- C2: two.\n' > "$P/p8f.md"
R=$(parse "$P/p8f.md"); [ "$R" = "bad:empty:C1 rc=2" ] && ok || bad "P8: an empty item (got $R)"

# P9 the same plan through mawk forced as awk gives the same JSON.
if command -v mawk >/dev/null 2>&1; then
  mkdir -p "$T/mawkbin"; ln -sf "$(command -v mawk)" "$T/mawkbin/awk"
  parse "$P/p2.md" >/dev/null; cp "$P/out.json" "$P/default.json" 2>/dev/null
  R=$(PATH="$T/mawkbin:$PATH" parse "$P/p2.md")
  [ "$R" = "ok:2 rc=0" ] && cmp -s "$P/out.json" "$P/default.json" && ok || bad "P9: mawk gives a different answer ($R)"
else
  echo "P9: mawk not on PATH — skipped"
fi

# ════════════════════════════════════════════════════════════════════════════
# F1. the slice kind's title and footer
# ════════════════════════════════════════════════════════════════════════════
FT=$( . "$T/h/bin/lib/file-children.sh"
      FC_SLICE_BASE=0 fc_child_title slice BH-4477 0 "Add the export route"
      FC_SLICE_BASE=2 fc_child_title slice BH-4477 1 "Wire the import page" )
[ "$FT" = $'BH-4477.1: Add the export route\nBH-4477.4: Wire the import page' ] && ok || bad "F1: titles ($FT)"
FF=$( . "$T/h/bin/lib/file-children.sh"; FC_SLICE_BASE=0 fc_child_footer slice 4477 2 2 "#4601 (hard)" )
EXP=$'---\nPart of #4477\nOrder: 2 of 2\nBlocked-by: #4601 (hard)\nRemaining slice C2 of #4477, filed from the plan of the merged slice. The PLAN stage plans it from scratch.'
[ "$FF" = "$EXP" ] && ok || bad "F1: footer ($FF)"
FF=$( . "$T/h/bin/lib/file-children.sh"; FC_SLICE_BASE=2 fc_child_footer slice 4477 1 2 "" )
grep -qx 'Remaining slice C3 of #4477, filed from the plan of the merged slice. The PLAN stage plans it from scratch.' <<<"$FF" \
  && ! grep -qE 'Blocked-by|Size budget|CONTRACT' <<<"$FF" && ok || bad "F1: k=2 footer, no blocker/budget/contract ($FF)"

# ════════════════════════════════════════════════════════════════════════════
# S. the close-out, end to end
# ════════════════════════════════════════════════════════════════════════════
S=example-org/proj
REC="$T/h/builds/proj-BH-4477-202610101500"
CLOSES_BODY=$'## Summary\nCloses #4477\n\nharness build'
NOKID_LINE='Slice delivered: #4500. No child issue carries the rest yet, so this issue stays open and keeps ai-build.'
: > "$T/all-argv.log"
reset() { # a fresh record and stub state; the argv log is kept cumulatively for S9
  cat "$T/gh-argv.log" >> "$T/all-argv.log" 2>/dev/null
  ghfx_routes_reset; ghfx_log_reset
  : > "$T/posted.txt"; : > "$T/h/logs/ALERTS.log"
  scratch_rm "$REC"; mkdir -p "$REC"
  rm -rf "$T/created"; rm -f "$T/create.n" "$T/create-fail-at" "$T/h/flags/slice-remainder-off"
  jq -n '{title:"BH-4477: master",labels:[{name:"ai-build"},{name:"enhancement"}]}' > "$REC/ticket-meta.json"
}
routes() { # routes [parent-state]
  ghfx_route GET    "repos/$S/pulls/4500" 200 "$(jq -nc --arg b "$CLOSES_BODY" '{number:4500,state:"closed",body:$b}')"
  ghfx_route GET    "repos/$S/issues/4477/timeline*" 200 '[]'
  ghfx_route POST   "repos/$S/issues/4477/comments" 201 '{"id":1}'
  ghfx_route PATCH  "repos/$S/issues/4477" 200 '{"state":"closed"}'
  ghfx_route DELETE "repos/$S/issues/4477/labels/ai-build" 200 '[]'
  ghfx_route GET    "repos/$S/issues/4477" 200 "$(jq -nc --arg s "${1:-open}" '{state:$s,body:"master ticket",labels:[{name:"ai-build"}]}')"
  ghfx_route GET    "repos/$S/issues/4601" 200 '{"number":4601,"state":"open","title":"BH-4477.1: Add the export route"}'
  ghfx_route GET    "repos/$S/issues/4602" 200 '{"number":4602,"state":"open","title":"BH-4477.2: Wire the console button (after C1)"}'
}
n_create() { find "$T/created" -name '*.argv' 2>/dev/null | grep -c .; }
n_post()   { grep -c -- "-X POST repos/$S/issues/4477/comments" "$T/gh-argv.log"; }
n_delete() { grep -c -- "-X DELETE repos/$S/issues/4477/labels/ai-build" "$T/gh-argv.log"; }
n_alert()  { grep -c . "$T/h/logs/ALERTS.log"; }
ics() { issue_close_shipped "$S" 4477 "Merged in $PRURL. Closing this issue." "$T/h" "$PRURL" "$REC" 2>/dev/null; }
mcs() { mc_close_shipped "$S" 4477 "Merged in $PRURL (merge conductor). Closing this issue." "$REC" "$PRURL" 2>/dev/null; }
rerun() { cat "$T/gh-argv.log" >> "$T/all-argv.log"; ghfx_log_reset; : > "$T/posted.txt"; rm -rf "$T/created"; }

for FN in ics mcs; do
  # S1 / S7: two remainder slices, both filed, one parent comment, one DELETE
  reset; routes; cp "$P/p2.md" "$REC/plan.md"
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "kept-slice:remainder-filed:#4601,#4602" ] && ok || bad "S1[$FN]: word (rc=$RC w=$W; $(tail -3 "$REC/slice-remainder/pipeline.log" 2>/dev/null))"
  [ "$(n_create)" = 2 ] && ok || bad "S1[$FN]: exactly 2 issue create calls ($(n_create))"
  [ "$(cat "$T/created/4601.title" 2>/dev/null)" = "BH-4477.1: Add the export route" ] && ok || bad "S1[$FN]: title 1 ($(cat "$T/created/4601.title" 2>/dev/null))"
  [ "$(cat "$T/created/4602.title" 2>/dev/null)" = "BH-4477.2: Wire the console button (after C1)" ] && ok || bad "S1[$FN]: title 2 ($(cat "$T/created/4602.title" 2>/dev/null))"
  grep -q -- '--label ai-build' "$T/created/4601.argv" 2>/dev/null && grep -q -- '--label ai-build' "$T/created/4602.argv" 2>/dev/null && ok \
    || bad "S1[$FN]: each child is labelled ai-build"
  B1="$T/created/4601.md"; B2="$T/created/4602.md"
  grep -qF 'Add the export route.' "$B1" 2>/dev/null && grep -qF '(C1) GET /export returns 200' "$B1" && grep -qx 'Part of #4477' "$B1" && ok \
    || bad "S1[$FN]: child 1 body has its text, its test and Part of #4477 ($(head -c 400 "$B1" 2>/dev/null))"
  grep -qF '[C2] button posts once' "$B2" 2>/dev/null && grep -qx 'Part of #4477' "$B2" && grep -qx 'Blocked-by: #4601 (hard)' "$B2" && ok \
    || bad "S1[$FN]: child 2 body has its test, Part of and Blocked-by: #4601 (hard)"
  grep -q 'Blocked-by' "$B1" 2>/dev/null && bad "S1[$FN]: child 1 has no blocker" || ok
  [ "$(n_post)" = 1 ] && ok || bad "S1[$FN]: exactly one parent comment ($(n_post))"
  grep -q '^Slice delivered: #4500\.' <<<"$(head -1 "$T/posted.txt")" && grep -q '#4601' "$T/posted.txt" && grep -q '#4602' "$T/posted.txt" && ok \
    || bad "S1[$FN]: the parent comment names the PR and both children ($(head -3 "$T/posted.txt"))"
  grep -q 'No child issue carries the rest' "$T/posted.txt" && bad "S1[$FN]: the no-children comment must not post" || ok
  [ "$(grep -c '—' "$T/posted.txt")" = 0 ] && ok || bad "S1[$FN]: no em dash in the parent comment"
  [ "$(n_delete)" = 1 ] && [ "$(n_alert)" = 0 ] && ok || bad "S1[$FN]: one DELETE, no alert (delete=$(n_delete) alerts=$(cat "$T/h/logs/ALERTS.log"))"
  [ "$(cat "$REC/slice-remainder/filed" 2>/dev/null)" = "#4601,#4602" ] && [ -f "$REC/issue-commented" ] && ok \
    || bad "S1[$FN]: the filed ledger and issue-commented ($(cat "$REC/slice-remainder/filed" 2>/dev/null))"

  # S3: a second merge event on the same record, timeline still empty
  rerun
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = "kept-slice:remainder-filed:#4601,#4602" ] && ok || bad "S3[$FN]: same word on the second event (rc=$RC w=$W)"
  [ "$(n_create)" = 0 ] && [ "$(n_post)" = 0 ] && [ "$(n_delete)" = 0 ] && [ "$(n_alert)" = 0 ] && ok \
    || bad "S3[$FN]: the second event writes nothing (create=$(n_create) post=$(n_post) delete=$(n_delete) alerts=$(n_alert))"
  # S3b: the plan is edited after the first filing; the frozen spec and ledger win
  rerun; printf -- '- C3: extra.\n' >> "$REC/plan.md"; rm -f "$REC/slice-remainder/filed"
  W=$($FN); RC=$?
  [ "$(n_create)" = 0 ] && [ "$(jq length "$REC/slice-remainder/children.json")" = 2 ] && ok \
    || bad "S3b[$FN]: an edited plan files nothing new (create=$(n_create) w=$W)"

  # S3u: a SLICE plan with no remainder pages once, critical, and never warns
  reset; routes; printf '# BH-4477\n\nSLICE: C0 of #4477\n\n## Tasks\n' > "$REC/plan.md"
  # BH-6308: the legacy path, behind its switch; the default is pinned in tests/slice-closeout-closes.bh-6308-test.sh
  W=$(SLICE_CLOSEOUT_SETTLE=0 $FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = kept-slice:no-children+label-kept ] && ok || bad "S3u[$FN]: word (rc=$RC w=$W)"
  [ "$(n_post)" = 1 ] && [ "$(head -1 "$T/posted.txt")" = "$NOKID_LINE" ] && ok || bad "S3u[$FN]: today's no-children comment ($(head -1 "$T/posted.txt"))"
  [ "$(n_alert)" = 1 ] && grep -q -- '--severity critical' "$T/h/logs/ALERTS.log" && grep -q 'SLICE_REMAINDER_UNKNOWN' "$T/h/logs/ALERTS.log" \
    && grep -q '#4477' "$T/h/logs/ALERTS.log" && grep -qF "$PRURL" "$T/h/logs/ALERTS.log" && ok \
    || bad "S3u[$FN]: one critical SLICE_REMAINDER_UNKNOWN page naming #4477 and the PR ($(cat "$T/h/logs/ALERTS.log"))"
  grep -q -- '--severity warn' "$T/h/logs/ALERTS.log" && bad "S3u[$FN]: the page replaces the warn alert" || ok
  [ "$(n_create)" = 0 ] && [ "$(n_delete)" = 0 ] && ok || bad "S3u[$FN]: nothing filed, label kept"
  rerun
  # BH-6308: the legacy path, behind its switch; the default is pinned in tests/slice-closeout-closes.bh-6308-test.sh
  W=$(SLICE_CLOSEOUT_SETTLE=0 $FN); RC=$?
  [ "$RC" = 0 ] && [ "$(n_post)" = 0 ] && [ "$(n_alert)" = 1 ] && [ -f "$REC/slice-remainder/unknown-paged" ] && ok \
    || bad "S3u[$FN]: a re-run posts and pages nothing more (rc=$RC post=$(n_post) alerts=$(n_alert))"
done

# S2: SLICE C2 with remainder C3, C4
reset; routes; cp "$P/p3.md" "$REC/plan.md"
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/created/4601.title" 2>/dev/null)" = "BH-4477.3: Add the importer" ] \
  && [ "$(cat "$T/created/4602.title" 2>/dev/null)" = "BH-4477.4: Wire the import page, depends on C3" ] && ok \
  || bad "S2: titles .3 and .4 (rc=$RC w=$W; $(cat "$T/created/"*.title 2>/dev/null | tr '\n' '|'))"
grep -qx 'Remaining slice C3 of #4477, filed from the plan of the merged slice. The PLAN stage plans it from scratch.' "$T/created/4601.md" 2>/dev/null \
  && grep -qx 'Blocked-by: #4601 (hard)' "$T/created/4602.md" 2>/dev/null && ok || bad "S2: footer says C3, and .4 is blocked by #4601"
grep -q 'BH-4477.3 (#4601)' "$T/posted.txt" && grep -q 'BH-4477.4 (#4602)' "$T/posted.txt" && ok || bad "S2: the comment links say .3 and .4 ($(cat "$T/posted.txt"))"

# S4: the filer dies after child 1 of 2, then resumes
reset; routes; cp "$P/p2.md" "$REC/plan.md"; echo 2 > "$T/create-fail-at"
W=$(ics); RC=$?
[ "$RC" = 1 ] && [ "$W" = close-deferred:remainder ] && ok || bad "S4: a failed create defers (rc=$RC w=$W)"
[ "$(n_alert)" = 1 ] && grep -q -- '--severity critical' "$T/h/logs/ALERTS.log" && grep -q 'slice-remainder-failed' "$T/h/logs/ALERTS.log" && ok \
  || bad "S4: one critical slice-remainder-failed alert ($(cat "$T/h/logs/ALERTS.log"))"
[ "$(grep -c . "$REC/slice-remainder/children.txt" 2>/dev/null)" = 1 ] && [ ! -e "$REC/slice-remainder/filed" ] && [ "$(n_post)" = 0 ] && ok \
  || bad "S4: children.txt has 1 line, no filed ledger, no parent comment (post=$(n_post))"
[ -s "$REC/slice-remainder/fc-error.txt" ] && ok || bad "S4: fc-error.txt names the failure"
rm -f "$T/create-fail-at"; cat "$T/gh-argv.log" >> "$T/all-argv.log"; ghfx_log_reset; : > "$T/posted.txt"
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = "kept-slice:remainder-filed:#4601,#4602" ] && ok || bad "S4: the resume files the rest (rc=$RC w=$W)"
[ "$(n_create)" = 2 ] && [ -e "$T/created/4602.argv" ] && ok || bad "S4: exactly one more create, child 2 ($(n_create) creates in total)"
[ "$(cat "$REC/slice-remainder/filed" 2>/dev/null)" = "#4601,#4602" ] && [ "$(n_post)" = 1 ] && ok \
  || bad "S4: filed=#4601,#4602 and one parent comment in total (post=$(n_post))"

# S5: another lane holds the record lock
reset; routes; cp "$P/p2.md" "$REC/plan.md"; mkdir -p "$REC/slice-remainder"
( flock -x 9; : > "$T/locked"; sleep 5 ) 9>"$REC/slice-remainder/.lock" &
LP=$!
for _ in $(seq 1 50); do [ -e "$T/locked" ] && break; sleep 0.1; done
W=$(ics); RC=$?
[ "$RC" = 1 ] && [ "$W" = close-deferred:remainder ] && [ "$(n_create)" = 0 ] && [ "$(n_post)" = 0 ] && ok \
  || bad "S5: a held lock defers and writes nothing (rc=$RC w=$W create=$(n_create) post=$(n_post))"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null; rm -f "$T/locked"

# S6: the parent was closed by hand
reset; routes closed; cp "$P/p2.md" "$REC/plan.md"
W=$(ics); RC=$?
[ "$(n_create)" = 0 ] && [ "$W" = kept-slice:no-children+label-kept ] && grep -q -- '--severity warn' "$T/h/logs/ALERTS.log" && ok \
  || bad "S6: a closed parent files nothing and takes today's path (w=$W create=$(n_create) alerts=$(cat "$T/h/logs/ALERTS.log"))"

# S8: switched off; S8b: dry run
reset; routes; cp "$P/p2.md" "$REC/plan.md"; touch "$T/h/flags/slice-remainder-off"
W=$(ics); RC=$?
[ "$(n_create)" = 0 ] && [ "$W" = kept-slice:no-children+label-kept ] && grep -q -- '--severity warn' "$T/h/logs/ALERTS.log" && ok \
  || bad "S8: flags/slice-remainder-off files nothing and warns as today (w=$W create=$(n_create))"
reset; routes; cp "$P/p2.md" "$REC/plan.md"
W=$(FILE_CHILDREN_DRY_RUN=1 ics); RC=$?
[ "$(n_create)" = 0 ] && [ ! -e "$REC/slice-remainder/filed" ] && [ "$W" = kept-slice:no-children+label-kept ] && ok \
  || bad "S8b: a dry run files nothing and takes today's path (w=$W create=$(n_create))"

# S8c: bin/hotfix-after-deploy.sh names the deferral truthfully
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
  "issue create"*) echo "HTTP 502: fixture create failure"; exit 1 ;;
  *"-X POST"*"/comments"*) ;;
  "api repos/"*"/comments"*) echo 4242; exit 0 ;;
  "api repos/"*"/issues/"*) echo open; exit 0 ;;
  "api repos/"*) echo 1; exit 0 ;;
esac
SH
HB="$H/builds/project-1-BH-378-202610051500"; mkdir -p "$HB"
jq -n '{fp:"deadfp",mode:"endpoint",decision:"applied",files:[{path:"scripts/migrations/a.sql",status:"applied"}],after_deploy:null}' \
  > "$HB/hotfix-migrate.json"
printf '# BH-378\n\nSLICE: C0 of #378\n\n## Later\n- C1: the rest of the hotfix.\n' > "$HB/plan.md"
ghfx_routes_reset; ghfx_log_reset
ghfx_route GET    "repos/o/p/pulls/9" 200 "$(jq -nc --arg b $'Hotfix.\nCloses #378' '{number:9,state:"closed",body:$b}')"
ghfx_route GET    "repos/o/p/issues/378/timeline*" 200 '[]'
ghfx_route POST   "repos/o/p/issues/378/comments" 201 '{"id":1}'
ghfx_route PATCH  "repos/o/p/issues/378" 200 '{"state":"closed"}'
ghfx_route DELETE "repos/o/p/issues/378/labels/ai-build" 200 '[]'
ghfx_route GET    "repos/o/p/issues/378" 200 '{"state":"open","body":"m","labels":[{"name":"ai-build"}]}'
( cd "$T" && env HARNESS="$H" FLEET_CONF="$H/fleet.conf" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" \
    SLUG=o/p PR_URL=https://github.com/o/p/pull/9 \
    bash "$H/bin/hotfix-after-deploy.sh" project-1 "$HB" abc1234def5678 > "$T/hf.out" 2> "$T/hf.err" ); RC=$?
[ "$RC" = 0 ] && ok || bad "S8c: the hotfix lane must exit 0 (rc=$RC; $(head -c 300 "$T/hf.err"))"
grep -q 'issue 378.*close-deferred:remainder.*remaining slices' "$H/logs/ALERTS.log" && ok \
  || bad "S8c: the ALERTS line names the remaining slices ($(cat "$H/logs/ALERTS.log"))"
grep -q 'child-issue read failed' "$H/logs/ALERTS.log" && bad "S8c: the remainder deferral is not a children-read failure" || ok
[ "$(grep -cE -- '-X (PATCH) repos/o/p/issues/378' "$T/gh-argv.log")" = 0 ] && ok || bad "S8c: the hotfix lane never closes issue 378"
cat "$T/gh-argv.log" >> "$T/all-argv.log"; ghfx_log_reset

# S9: across every case, the master was never closed, and the log is not empty
[ "$(grep -c -- "-X PATCH repos/$S/issues/4477" "$T/all-argv.log")" = 0 ] && ok \
  || bad "S9: a slice close-out PATCHed the master ($(grep -c -- '-X PATCH' "$T/all-argv.log"))"
grep -q -- "-X POST repos/$S/issues/4477/comments" "$T/all-argv.log" && ok || bad "S9: the cumulative log has no POST, so S9 proves nothing"

echo "slice-remainder (BH-5961): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
