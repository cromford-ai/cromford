#!/bin/bash
# tests/builder-self-check-prepush.bh-6393-test.sh — BH-6393: the builder runs
# the full bin/pr-self-check.sh on its final head and body BEFORE it opens or
# updates the PR, so the hub's lead-review enqueue is not the first to see a
# plan-files refusal (130 refusals on 44 PRs came from that gap).
#
#   S1  a pr-out head with 7 unplanned files: one reason line per file under
#       `## Files outside the plan` (no model turn), above the footer; the
#       second check passes
#   S2  the S1 body passes the full-rule CLI exactly as self_check_hold calls
#       it, and self_check_hold runs every rule (no PR_SELF_CHECK_ONLY)
#   S3  an unfixable closes-not-met: the span returns (the PR opens) after 2
#       checks with `## Pre-open check: refusals left` in the body
#   S4  that findings section (as S3 wrote it) is not read as an acceptance
#       section: no closes-not-met refusal, and body-acceptance still refuses
#   S5  the edit phase: the open-time fix section is restored, reasons cover a
#       file a QA round added, no model turn; result.sh's settle edit sends the
#       self-checked body to `gh pr edit`
#   S6  the base does not resolve: the body is byte-identical, could-not-run
#   R1  plan-files off in the catalog: no reason section; psc_plan_missing
#       lists exactly the unplanned files, rc 2 with no plan
#   P1-P4  the `# >>> self-check post-open count` block of bin/pipeline-health.sh
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/builder-self-check-prepush.bh-6393-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
H="$T/h"; mkdir -p "$H/catalog"
scratch_install_closure bin/pr-self-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/pr-self-check.sh"; exit 1; }
cp "$DIR/catalog/pr-self-check.tsv" "$H/catalog/pr-self-check.tsv"
export PR_SELF_CHECK_CATALOG="$H/catalog/pr-self-check.tsv"

# ── the fixture repo ────────────────────────────────────────────────────────
# Names long enough that 7 of them overflow the rule's 300-character message:
# the reason lines must come from psc_plan_missing, not from the REFUSE text.
OUTF() { echo "bin/out-$1-with-a-name-long-enough-to-pass-the-cut.sh"; }
R="$T/repo"; mkdir -p "$R/bin"
git -C "$R" init -q -b main
echo a > "$R/bin/a.sh"; git -C "$R" add -A; git -C "$R" commit -qm M0
git -C "$R" checkout -qb pr-plain; echo b > "$R/bin/a.sh"; git -C "$R" commit -qam "plain change"
git -C "$R" checkout -q main; git -C "$R" checkout -qb pr-out
mkdir -p "$R/.harness/specs/BH-1"
printf '# BH-1\n\n## Files to touch\n\n- `bin/a.sh` — the change\n\n## Acceptance tests\n\nx\n' > "$R/.harness/specs/BH-1/plan.md"
echo b > "$R/bin/a.sh"; git -C "$R" add -A; git -C "$R" commit -qm "plan and a"
for i in 1 2 3 4 5 6 7; do echo "o$i" > "$R/$(OUTF "$i")"; git -C "$R" add -A; git -C "$R" commit -qm "fix out-$i"; done
git -C "$R" branch -q pr-qa pr-out

WHY=$'## Why\nThe merge queue drops this PR shape every batch today.\n'
ACC=$'## Acceptance tests\n| case | result |\n|---|---|\n| S1 | pass |\n'
FOOT=$'---\nPlan: harness build x.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
GOOD="Refs #5

## What
x

$WHY
$ACC
$FOOT"
printf '## Done when\n- the suite passes\n' > "$T/ticket.md"

SPAN="$T/span.sh"
awk '/^# >>> pr body fix round/{f=1} f{print} /^# <<< pr body fix round/{exit}' "$DIR/bin/lib/rb/pr.sh" > "$SPAN"
[ -s "$SPAN" ] && ok || bad "no '# >>> pr body fix round' span in bin/lib/rb/pr.sh"

# run_span <case> <branch> <body> [post-file] — sources the span in the fixture
# repo (the open phase runs on source), then sources post-file if given.
run_span() {
  local B="$T/$1"; mkdir -p "$B"; printf '%s\n' "$3" > "$B/pr-body.md"
  echo '{"body":"## Done when\n- the suite passes"}' > "$B/ticket-meta.json"
  git -C "$R" checkout -q "$2"
  ( cd "$R" && HARNESS="$H" BUILD="$B" BASE="${SBASE:-main}" FIX_MODEL=fix-x PROJECT=cromford KEY=BH-1 POST="${4:-}" bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      CC() { printf "%s\n" "$*" >> "$BUILD/cc.log"; [ -s "$BUILD/fix.txt" ] && cp "$BUILD/fix.txt" "$BUILD/pr-body-fix.md"; return 0; }
      . "$0"; echo SPAN_DONE
      if [ -n "$POST" ]; then . "$POST"; fi' "$SPAN" ) > "$B/out" 2>&1
}
outside() { _psc_sec "$1" 'files outside the plan'; }
_psc_sec() { awk -v re="$2" '/^#+[[:space:]]/ { on = (tolower($0) ~ re); next } on' "$1"; }

# ── S1: reason lines, no model turn, pass on try 2 ──────────────────────────
run_span s1 pr-out "$GOOD"
B="$T/s1"
grep -q SPAN_DONE "$B/out" && ok || bad "S1 the span did not return: $(cat "$B/out")"
n=0
for i in 1 2 3 4 5 6 7; do
  c=$(outside "$B/pr-body.md" | grep -cF -- "- \`$(OUTF "$i")\`: changed in this build by \"fix out-$i\"")
  [ "$c" = 1 ] && n=$((n+1))
done
[ "$n" = 7 ] && ok || bad "S1 $n of 7 unplanned files have exactly one reason line: $(cat "$B/pr-body.md")"
grep -qF '`bin/a.sh`' <<<"$(outside "$B/pr-body.md")" && bad "S1 a planned file got a reason line" || ok
OL=$(grep -n '^## Files outside the plan' "$B/pr-body.md" | cut -d: -f1); PL=$(grep -n '^Plan: harness build' "$B/pr-body.md" | cut -d: -f1)
[ -n "$OL" ] && [ -n "$PL" ] && [ "$OL" -lt "$PL" ] && tail -1 "$B/pr-body.md" | grep -q 'Generated with' && ok \
  || bad "S1 the reason section is not above the footer, or the attribution is not last: $(cat "$B/pr-body.md")"
[ ! -s "$B/cc.log" ] && ok || bad "S1 a plan-files refusal bought a model turn: $(cat "$B/cc.log")"
grep -q '^open tries=2 verdict=pass rules=-$' "$B/self-check-prepush.txt" 2>/dev/null && ok \
  || bad "S1 self-check-prepush.txt is not 'open tries=2 verdict=pass': $(cat "$B/self-check-prepush.txt" 2>/dev/null)"
grep -q 'pr self-check: wrote 7 reason line(s) under Files outside the plan' "$B/pipeline.log" 2>/dev/null \
  && grep -q 'pr self-check: pass on try 2 (open)' "$B/pipeline.log" && ok \
  || bad "S1 the log does not say 7 reason lines and pass on try 2: $(cat "$B/pipeline.log" 2>/dev/null)"

# ── S2: the hub's own call passes on the S1 body ────────────────────────────
OUT=$("$H/bin/pr-self-check.sh" check --repo "$R" --base main --head pr-out --body "$T/s1/pr-body.md" --ticket "$T/ticket.md" --key BH-1 2>&1); RC=$?
[ "$RC" = 0 ] && ! grep -q '^REFUSE' <<<"$OUT" && ok || bad "S2 the full-rule check refuses the S1 body (rc $RC): $OUT"
SCH=$(awk '/^self_check_hold\(\) *\{/{f=1} f{print} f && /^}/{exit}' "$DIR/bin/lead-review-enqueue.sh")
grep -q 'psc_check' <<<"$SCH" && ! grep -q 'PR_SELF_CHECK_ONLY' <<<"$SCH" && ok \
  || bad "S2 self_check_hold is missing, calls no psc_check, or narrows the rules: $(head -3 <<<"$SCH")"

# ── S3: unfixable → 2 checks, findings in the body, the PR still opens ──────
run_span s3 pr-plain "Closes #5

$WHY
## Acceptance tests
- [ ] the probe passes

$FOOT"
B="$T/s3"
grep -q SPAN_DONE "$B/out" && ok || bad "S3 the span did not return: $(cat "$B/out")"
n=$(grep -c '^fix ' "$B/cc.log" 2>/dev/null); [ "${n:-0}" -le 1 ] && ok || bad "S3 more than one model turn: $(cat "$B/cc.log")"
grep -q '^## Pre-open check: refusals left$' "$B/pr-body.md" && _psc_sec "$B/pr-body.md" 'pre-open check' | grep -q '^- closes-not-met:' && ok \
  || bad "S3 no findings section naming closes-not-met: $(cat "$B/pr-body.md")"
grep -q '^open tries=2 verdict=refused rules=closes-not-met$' "$B/self-check-prepush.txt" 2>/dev/null && ok \
  || bad "S3 self-check-prepush.txt: $(cat "$B/self-check-prepush.txt" 2>/dev/null)"
grep -q 'pr self-check: still refused after 2 tries (open) — closes-not-met' "$B/pipeline.log" 2>/dev/null && ok \
  || bad "S3 the log does not say still refused after 2 tries: $(cat "$B/pipeline.log" 2>/dev/null)"

# ── S4: the findings section S3 wrote (its own file) is not an acceptance section
{ printf 'Closes #5\n\n'; cat "$T/s3/pr-body-findings.md" 2>/dev/null; } > "$T/s4-body.md"
grep -q 'not met' "$T/s4-body.md" && ok || bad "S4 the S3 findings do not carry the 'not met' text: $(cat "$T/s4-body.md")"
OUT=$("$H/bin/pr-self-check.sh" check --repo "$R" --base main --head pr-plain --body "$T/s4-body.md" --only '^(closes-not-met|body-acceptance)$' 2>&1)
! grep -q '^REFUSE closes-not-met' <<<"$OUT" && grep -q '^REFUSE body-acceptance' <<<"$OUT" && ok \
  || bad "S4 the findings section is read as an acceptance section: $OUT"

# ── S5: the edit phase (settle) ─────────────────────────────────────────────
THIN="Refs #5

## Why
x

$ACC
$FOOT"
printf '%s\n' "$WHY" > "$T/s5-fix.md"
cat > "$T/s5-post.sh" <<'EOF'
echo q > bin/qa-new.sh; git add -A; git commit -qm "fix qa"
printf '%s\n' "$THIN" > "$BUILD/pr-body-edit.md"
cp "$S5FIX" "$BUILD/pr-body-fix.md"
_pr_self_check_prepush "$BUILD/pr-body-edit.md" edit; echo EDIT_DONE
EOF
THIN="$THIN" S5FIX="$T/s5-fix.md" run_span s5 pr-qa "$GOOD" "$T/s5-post.sh"
B="$T/s5"
grep -q EDIT_DONE "$B/out" && ok || bad "S5 the edit phase did not return: $(cat "$B/out")"
n=0
for p in $(for i in 1 2 3 4 5 6 7; do OUTF "$i"; done) bin/qa-new.sh; do
  outside "$B/pr-body-edit.md" | grep -qF -- "- \`$p\`: changed in this build" && n=$((n+1))
done
[ "$n" = 8 ] && ok || bad "S5 $n of 8 files have a reason line on the edited body: $(cat "$B/pr-body-edit.md" 2>/dev/null)"
[ "$(grep -c 'The merge queue drops this PR shape' "$B/pr-body-edit.md" 2>/dev/null)" = 1 ] && ok \
  || bad "S5 the open-time fix section is not in the edited body exactly once: $(cat "$B/pr-body-edit.md" 2>/dev/null)"
[ ! -s "$B/cc.log" ] && ok || bad "S5 the edit phase bought a model turn: $(cat "$B/cc.log")"
grep -q '^edit tries=2 verdict=pass' "$B/self-check-prepush.txt" 2>/dev/null && ok || bad "S5 no edit pass line: $(cat "$B/self-check-prepush.txt" 2>/dev/null)"
OUT=$("$H/bin/pr-self-check.sh" check --repo "$R" --base main --head pr-qa --body "$B/pr-body-edit.md" --ticket "$T/ticket.md" --key BH-1 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "S5 the edited body is refused by the full-rule check (rc $RC): $OUT"

# S5 through result.sh: the settle edit arm, run as written, sends the
# self-checked body (the reason lines included) to `gh pr edit`.
awk 'index($0, "# <<< pr-body hold gate") {f=1; next} f {print} f && /^    fi$/ {exit}' "$DIR/bin/lib/rb/result.sh" > "$T/settle-edit.sh"
grep -q 'gh pr edit' "$T/settle-edit.sh" && ok || bad "S5 no gh pr edit arm after the pr-body hold gate in bin/lib/rb/result.sh"
B="$T/s5r"; mkdir -p "$B"; echo '{"body":"## Done when\n- the suite passes"}' > "$B/ticket-meta.json"
git -C "$R" checkout -q pr-out
( cd "$R" && HARNESS="$H" BUILD="$B" BASE=main FIX_MODEL=fix-x PROJECT=cromford KEY=BH-1 GOOD="$GOOD" bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    CC() { printf "%s\n" "$*" >> "$BUILD/cc.log"; return 0; }
    gh() { local a; while [ $# -gt 0 ]; do a="$1"; shift; [ "$a" = --body ] && printf "%s" "$1" > "$BUILD/gh-body.txt"; done; return 0; }
    PR_BODY_FOR() { printf "%s\n" "$GOOD"; }
    . "$0"
    PR_URL=https://github.invalid/o/r/pull/7; PR_URL_EDIT="$PR_URL"; EVIDENCE_SECTION=""
    . "$1"; echo SETTLE_DONE' "$SPAN" "$T/settle-edit.sh" ) > "$B/out" 2>&1
grep -q SETTLE_DONE "$B/out" && [ "$(outside "$B/gh-body.txt" 2>/dev/null | grep -c 'changed in this build by')" = 7 ] && ok \
  || bad "S5 the settle gh pr edit body carries no reason lines: $(cat "$B/out") $(cat "$B/gh-body.txt" 2>/dev/null)"

# ── S6: could not run ───────────────────────────────────────────────────────
SBASE=nope run_span s6 pr-out "$GOOD"
B="$T/s6"
cmp -s <(printf '%s\n' "$GOOD") "$B/pr-body.md" && grep -q SPAN_DONE "$B/out" && grep -q 'verdict=could-not-run' "$B/self-check-prepush.txt" 2>/dev/null && ok \
  || bad "S6 an unresolvable base changed the body, stopped the span or recorded no could-not-run: $(cat "$B/out") $(cat "$B/self-check-prepush.txt" 2>/dev/null)"

# ── R1: the catalog decides; psc_plan_missing lists what the rule refuses ────
awk -F'\t' -v OFS='\t' '$1 == "plan-files" {$2 = "off"} {print}' "$H/catalog/pr-self-check.tsv" > "$T/cat-pf-off.tsv"
PR_SELF_CHECK_CATALOG="$T/cat-pf-off.tsv" run_span r1 pr-out "$GOOD"
B="$T/r1"
! grep -q '^## Files outside the plan' "$B/pr-body.md" && grep -q 'pr self-check: pass on try 1 (open)' "$B/pipeline.log" 2>/dev/null && ok \
  || bad "R1 plan-files off still wrote reasons or did not pass on try 1: $(cat "$B/pipeline.log" 2>/dev/null)"
PM=$(bash -c '. "$1/bin/lib/pr-self-check.sh" && psc_plan_missing "$2" main pr-out "$3" ""' _ "$H" "$R" "$T/r1/pr-body.md"); PRC=$?
[ "$PRC" = 0 ] && [ "$PM" = "$(for i in 1 2 3 4 5 6 7; do OUTF "$i"; done)" ] && ok \
  || bad "R1 psc_plan_missing on pr-out (rc $PRC) is not the 7 unplanned files: $PM"
bash -c '. "$1/bin/lib/pr-self-check.sh" && psc_plan_missing "$2" main pr-plain "$3" ""' _ "$H" "$R" "$T/r1/pr-body.md" >/dev/null; PRC=$?
[ "$PRC" = 2 ] && ok || bad "R1 psc_plan_missing with no plan must return 2, got $PRC"

# ── P1-P4: the pipeline-health count ────────────────────────────────────────
awk '/^# >>> self-check post-open count/{f=1;next} /^# <<< self-check post-open count/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/blk.sh"
[ -s "$T/blk.sh" ] && ok || bad "no '# >>> self-check post-open count' block in bin/pipeline-health.sh"
PNOW=1760000000
PH="$T/ph"; mkdir -p "$PH/logs" "$PH/state"
drive_ph() {
  ( export PH T PNOW
    bash -c '
      set -uo pipefail
      H="$PH"; NOW="$PNOW"
      STAMP() { echo TS; }
      alert() { printf "%s|%s\n" "$1" "$2" >> "$T/alerts.txt"; }
      . "$0"' "$T/blk.sh" 2>"$T/ph-err.txt" )
}
SD="$PH/state/lead-review-enqueue"; mkdir -p "$SD"
echo $((PNOW - 100)) > "$SD/selfcheck-o_r-12-aaaaaaaaaaaa"
echo $((PNOW - 200)) > "$SD/selfcheck-o_r-12-bbbbbbbbbbbb"
printf '%s\ncommented 123\n' $((PNOW - 86400 - 100)) > "$SD/selfcheck-o_r-13-cccccccccccc"
echo "$PNOW" > "$SD/selfcheck-notes-o_r-14-dddddddddddd"
echo junk > "$SD/selfcheck-o_r-15-eeeeeeeeeeee"
D0=2025-10-09; D1=2025-10-08   # the UTC days of PNOW and PNOW-86400
drive_ph
L=$(grep 'self-check refusals after PR open' "$PH/logs/pipeline-health.log" 2>/dev/null)
grep -q "by UTC day (heads/PRs): $D0 2/1 $D1 1/1 " <<<"$L" && ok || bad "P1 the line is not '$D0 2/1 $D1 1/1 ...': '$L' $(cat "$T/ph-err.txt")"
[ "$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]+/[0-9]+' <<<"$L" | wc -l)" = 7 ] && ok || bad "P1 the line does not carry 7 day fields: '$L'"
# P3: a measurement, never a page
[ ! -s "$T/alerts.txt" ] && [ ! -e "$PH/logs/ALERTS.log" ] && ok || bad "P3 the block paged: $(cat "$T/alerts.txt" 2>/dev/null)"
# P4: hourly — a fresh stamp writes no second line
drive_ph
[ "$(grep -c 'self-check refusals after PR open' "$PH/logs/pipeline-health.log")" = 1 ] && ok || bad "P4 a second run inside the hour wrote another line"
# P2: not the hub — not counted, never 0/0
scratch_rm "$SD"; scratch_rm "$PH/state/psc-postopen.stamp"; : > "$PH/logs/pipeline-health.log"
drive_ph
L=$(cat "$PH/logs/pipeline-health.log")
grep -q 'self-check refusals after PR open: not counted' <<<"$L" && ! grep -q '0/0' <<<"$L" && ok || bad "P2 a box with no enqueue state is not 'not counted': '$L'"

echo "builder-self-check-prepush.bh-6393: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
