#!/bin/bash
# tests/pr-body-requires.bh-7378-test.sh — BH-7378: a plan lists what the PR
# body must carry in a fenced ```pr-body-requires block, and the check reports
# each item the live body lacks as a NOTE. It never refuses and never changes
# the verdict. The parts: bin/lib/pr-body-requires.sh (pbr_items, pbr_missing,
# psc_requires_check, pbr_plan_rule), the CLI bin/pr-body-requires.sh, and the
# self-check rule body-plan-requires (catalog/pr-self-check.d/
# bh-7378-plan-body-requires.tsv, the arm in bin/lib/pr-self-check.sh).
#
#   P1-P7  pbr_items: fence forms, the last ` <- ` split, blanks, duplicates
#   M1-M5  pbr_missing: CRLF, regex characters, case, substring, empty body
#   A1-A5  the ticket's acceptance cases, through bin/pr-body-requires.sh
#   C1-C3  --pr read success and failure, a usage error
#   S1-S7  the self-check rule through bin/pr-self-check.sh (the entry point
#          bin/lead-review-enqueue.sh's self_check_hold uses)
#   R1-R3  the planner sentence, its two seams, its round trip
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-body-requires.bh-7378-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PR_SELF_CHECK_CATALOG PR_SELF_CHECK_ONLY PSC_TICKET_FILE PSC_PR_KEY

H="$T/h"; mkdir -p "$H" "$T/tmp" "$T/b" "$T/p"
[ -r "$SRC/bin/lib/pr-body-requires.sh" ] && [ -r "$SRC/bin/pr-body-requires.sh" ] \
  && [ -r "$SRC/catalog/pr-self-check.d/bh-7378-plan-body-requires.tsv" ] \
  || { echo "FAIL: bin/lib/pr-body-requires.sh, bin/pr-body-requires.sh or the catalog row is missing"; exit 1; }
scratch_install_closure bin/pr-self-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/pr-self-check.sh"; exit 1; }
scratch_install_closure bin/pr-body-requires.sh "$H" >/dev/null || { echo "FAIL: closure of bin/pr-body-requires.sh"; exit 1; }
CAT="$SRC/catalog/pr-self-check.tsv"   # the real main file and its real .d/
export TMPDIR="$T/tmp"
RULE='body-plan-requires'

has()  { grep -qF -- "$2" <<<"$1"; }
cnt()  { local c; c=$(grep -cF -- "$2" <<<"$1"); printf '%s' "$c"; }
body() { printf '%s' "$2" > "$T/b/$1"; printf '%s' "$T/b/$1"; }
plan() { printf '%s' "$2" > "$T/p/$1"; printf '%s' "$T/p/$1"; }
items()   { ITEMS=$(bash -c '. "$1/bin/lib/pr-body-requires.sh"; pbr_items "$2"' _ "$H" "$1" 2>&1); IRC=$?; }
missing() { MISS=$(bash -c '. "$1/bin/lib/pr-body-requires.sh"; pbr_missing "$2" "$3"' _ "$H" "$1" "$2" 2>&1); MRC=$?; }
cli() { OUT=$(bash "$H/bin/pr-body-requires.sh" "$@" 2>"$T/cli.err"); RC=$?; }
TAB=$'\t'

# ── P1-P7: the parser ─────────────────────────────────────────────────────────
items "$(plan p1.md $'# plan\n\n```PR-BODY-REQUIRES\n## Flip evidence <- T3\n```\n')"
[ "$IRC" = 0 ] && [ "$ITEMS" = "## Flip evidence${TAB}T3" ] && ok || bad "P1 upper-case fence: want '## Flip evidence<TAB>T3', got rc $IRC: $ITEMS"
items "$(plan p2.md $'```pr-body-requires-x\n## A <- T1\n```\n```pr-body-requires extra\n## B\n```\n')"
[ "$IRC" = 0 ] && [ -z "$ITEMS" ] && ok || bad "P2 -x fence and an info string with more words: want no items, got: $ITEMS"
items "$(plan p3.md $'- step\n  ```pr-body-requires\n  ## Merge condition <- ticket line 4\n  ```\n')"
[ "$ITEMS" = "## Merge condition${TAB}ticket line 4" ] && ok || bad "P3 indented fence: got: $ITEMS"
items "$(plan p4.md $'```pr-body-requires\n## A <- T1\n```\ntext\n```bash\necho hi\n```\n```pr-body-requires\n## B <- T2\n```\n')"
[ "$ITEMS" = "## A${TAB}T1"$'\n'"## B${TAB}T2" ] && ok || bad "P4 two blocks merged, a bash fence between: got: $ITEMS"
items "$(plan p5.md $'```pr-body-requires\n## A <- T1\n## B <- T2\n')"
[ "$IRC" = 0 ] && [ -z "$ITEMS" ] && ok || bad "P5 unclosed fence: want no items, got rc $IRC: $ITEMS"
items "$(plan p6.md $'```pr-body-requires\nx <- y <- T6\nTEST-CHANGE:\n```\n')"
[ "$ITEMS" = "x <- y${TAB}T6"$'\n'"TEST-CHANGE:${TAB}the plan" ] && ok || bad "P6 last ' <- ' split, no source = 'the plan': got: $ITEMS"
LONG=$(printf 'L%.0s' $(seq 1 150))
items "$(plan p7.md $'```pr-body-requires\r\n\r\n   ## A <- T1   \r\n\n## A <- T9\n  <- T5\n'"$LONG"$' <- s\x01rc\n```\r\n')"
want="## A${TAB}T1"$'\n'"${LONG:0:120}${TAB}src"
[ "$ITEMS" = "$want" ] && ok || bad "P7 CRLF, blank, trimmed, duplicate (first source wins), empty item, 120-char cut, control char: got: $ITEMS"
items "$T/p/no-such-plan.md"
[ "$IRC" = 0 ] && [ -z "$ITEMS" ] && ok || bad "P8 unreadable plan: want rc 0 and no items, got rc $IRC: $ITEMS"

# ── M1-M5: the matcher ────────────────────────────────────────────────────────
MP=$(plan m.md $'```pr-body-requires\n## Flip evidence <- T3\nBEFORE/AFTER (counts)* <- T4\n## Merge condition <- T5\n```\n')
missing "$MP" "$(body m1.md $'## Flip evidence\r\nBEFORE/AFTER (counts)*\r\n## Merge condition\r\n')"
[ "$MRC" = 0 ] && [ -z "$MISS" ] && ok || bad "M1 CRLF body that has all items: want none missing, got rc $MRC: $MISS"
missing "$MP" "$(body m2.md $'## Flip evidence\nBEFORE/AFTER counts\n## Merge condition\n')"
[ "$MISS" = "BEFORE/AFTER (counts)*${TAB}T4" ] && ok || bad "M2 regex characters are literal: want only the BEFORE/AFTER item missing, got: $MISS"
missing "$MP" "$(body m3.md $'## Flip Evidence\nBEFORE/AFTER (counts)*\n## Merge condition\n')"
[ "$MISS" = "## Flip evidence${TAB}T3" ] && ok || bad "M3 case differs = missing: got: $MISS"
missing "$MP" "$(body m4.md $'see ## Flip evidence below\nBEFORE/AFTER (counts)*\n### Merge condition\n')"
[ "$MRC" = 0 ] && [ -z "$MISS" ] && ok || bad "M4 substring in a longer line / a deeper heading = present: got: $MISS"
missing "$MP" "$(body m5.md '')"
[ "$(wc -l <<<"$MISS" | tr -d ' ')" = 3 ] && ok || bad "M5 empty body = all 3 missing: got: $MISS"
missing "$MP" "$T/b/no-such-body.md"
[ "$MRC" = 2 ] && [ -z "$MISS" ] && ok || bad "M6 unreadable body: want rc 2 and no list, got rc $MRC: $MISS"

# ── A1-A5: the CLI as shipped ─────────────────────────────────────────────────
PA1=$(plan a1.md $'## T3\n```pr-body-requires\n## Flip evidence <- T3\n```\n')
cli check --plan "$PA1" --body "$(body a1.md $'## Summary\nDone.\n')"
[ "$RC" = 0 ] && [ "$OUT" = "[NOTE] PR body lacks ## Flip evidence (required by T3)" ] && ok || bad "A1 one missing item: want one exact NOTE line rc 0, got rc $RC: $OUT"
PA2=$(plan a2.md $'```pr-body-requires\n## Merge condition\n## After merge (operator)\n## Follow-ups\n```\n')
cli check --plan "$PA2" --body "$(body a2.md $'## Merge condition\nx\n## After merge (operator)\ny\n## Follow-ups\nnone\n')"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A2 all three present: want empty rc 0, got rc $RC: $OUT"
cli check --plan "$(plan a3.md $'# plan\nno block here\n```bash\necho\n```\n')" --body "$T/b/a1.md"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A3 no block: want empty rc 0, got rc $RC: $OUT"
PA4=$(plan a4.md $'```pr-body-requires\n## One <- T1\n## Two <- T2\n## Three <- T3\n## Four <- T4\n```\n')
cli check --plan "$PA4" --body "$(body a4.md $'## Two\n')"
{ [ "$RC" = 0 ] && [ "$(cnt "$OUT" '[NOTE] PR body lacks')" = 3 ] && has "$OUT" '[NOTE] PR body lacks ## Four (required by T4)' && ! has "$OUT" '## Two'; } \
  && ok || bad "A4 four items, one present: want 3 lacks lines rc 0, got rc $RC: $OUT"
# gh_rest stub: exported so the CLI child sees it and does not source the real lib.
export STUB_LOG="$T/gh.calls"
gh_rest() { printf '%s %s\n' "$1" "$2" >> "$STUB_LOG"; [ -n "${STUB_JSON:-}" ] && printf '%s' "$STUB_JSON"; return "${STUB_RC:-0}"; }
export -f gh_rest
: > "$T/gh.calls"
OUT=$(STUB_RC=75 bash "$H/bin/pr-body-requires.sh" check --plan "$PA4" --pr o/r#1 2>/dev/null); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = "[NOTE] not verified here: PR body read rate-limited" ] && grep -qx 'GET repos/o/r/pulls/1' "$T/gh.calls"; } \
  && ok || bad "A5 rc 75: want exactly the rate-limited NOTE, no lacks line, rc 0, one GET; got rc $RC: $OUT / $(cat "$T/gh.calls")"

# ── C1-C3 ─────────────────────────────────────────────────────────────────────
OUT=$(STUB_RC=0 STUB_JSON='{"body":"## Flip evidence\n"}' bash "$H/bin/pr-body-requires.sh" check --plan "$PA1" --pr o/r#2 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C1 live body has the item: want no output rc 0, got rc $RC: $OUT"
OUT=$(STUB_RC=0 STUB_JSON='{"body":null}' bash "$H/bin/pr-body-requires.sh" check --plan "$PA1" --pr o/r#2 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "[NOTE] PR body lacks ## Flip evidence (required by T3)" ] && ok || bad "C1b null live body: want the lacks line, got rc $RC: $OUT"
OUT=$(STUB_RC=1 bash "$H/bin/pr-body-requires.sh" check --plan "$PA1" --pr o/r#3 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "[NOTE] not verified here: PR body read failed (rc 1)" ] && ok || bad "C2 rc 1: want one read-failed NOTE, got rc $RC: $OUT"
OUT=$(STUB_RC=0 STUB_JSON='not json' bash "$H/bin/pr-body-requires.sh" check --plan "$PA1" --pr o/r#3 2>/dev/null); RC=$?
{ [ "$RC" = 0 ] && has "$OUT" "[NOTE] not verified here: PR body read failed (rc " && ! has "$OUT" lacks; } && ok || bad "C2b a jq failure: want one read-failed NOTE, got rc $RC: $OUT"
: > "$T/gh.calls"
OUT=$(STUB_RC=0 bash "$H/bin/pr-body-requires.sh" check --plan "$T/p/a3.md" --pr o/r#4 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -s "$T/gh.calls" ] && ok || bad "C2c no block: want no output and no GET, got rc $RC: $OUT / $(cat "$T/gh.calls")"
cli check --plan "$PA1" --bogus x
[ "$RC" = 2 ] && ok || bad "C3 unknown flag: want rc 2, got rc $RC"
cli
[ "$RC" = 2 ] && ok || bad "C3b no subcommand: want rc 2, got rc $RC"
cli check --plan "$PA1" --pr not-a-slug
[ "$RC" = 2 ] && ok || bad "C3c bad --pr: want rc 2, got rc $RC"
cli check --plan "$T/p/none.md" --body "$T/b/a1.md"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C3d no plan file: want silent rc 0, got rc $RC: $OUT"
A11=$(plan a11.md "$(printf '```pr-body-requires\n'; for i in $(seq 1 12); do printf '## S%s <- T%s\n' "$i" "$i"; done; printf '```\n')")
cli check --plan "$A11" --body "$T/b/a1.md"
{ [ "$RC" = 0 ] && [ "$(cnt "$OUT" '[NOTE] PR body lacks ## S')" = 10 ] && has "$OUT" "[NOTE] PR body lacks 2 more required items (see the plan's pr-body-requires block)"; } \
  && ok || bad "C4 cap: want 10 lines and an 'and 2 more' line, got: $OUT"
unset -f gh_rest

# ── S1-S7: the self-check rule through bin/pr-self-check.sh ───────────────────
R="$T/repo"; mkdir -p "$R/docs"
git -C "$R" init -q -b main
printf 'x\n' > "$R/docs/a.md"
mkdir -p "$R/.harness/specs/BH-0"
printf '```pr-body-requires\n## From main <- T1\n```\n' > "$R/.harness/specs/BH-0/plan.md"
git -C "$R" add -A; git -C "$R" commit -qm M0
br() { git -C "$R" checkout -q main && git -C "$R" checkout -qB "$1"; }
cm() { git -C "$R" add -A && git -C "$R" commit -qm "$1"; }
run() { # run <branch> <body> [catalog] [only]
  OUT=$(PR_SELF_CHECK_CATALOG="${3:-$CAT}" bash "$H/bin/pr-self-check.sh" check \
        --repo "$R" --base main --head "$1" --body "$2" ${4:+--only "$4"} 2>/dev/null); RC=$?
}
br s1; mkdir -p "$R/.harness/specs/BH-1"
printf '# plan\n```pr-body-requires\n## Flip evidence <- T3\n## Merge condition <- ticket\n```\n' > "$R/.harness/specs/BH-1/plan.md"
cm s1
BS1=$(body s1.md $'## Merge condition\nafter #1\n')
run s1 "$BS1" "$CAT" "^$RULE\$"
{ [ "$RC" = 0 ] && [ "$OUT" = "NOTE $RULE: the body is missing ## Flip evidence (required by T3)" ]; } \
  && ok || bad "S1 shipped row, one item missing: want one NOTE line rc 0, got rc $RC: $OUT"
S1_OUT="$OUT"
br s2; mkdir -p "$R/.harness/specs/BH-2"; printf '# plan\nno block\n' > "$R/.harness/specs/BH-2/plan.md"; cm s2
run s2 "$BS1" "$CAT" "^$RULE\$"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S2 plan without a block: want no line, got rc $RC: $OUT"
br s2b; printf 'y\n' > "$R/docs/a.md"; cm s2b
run s2b "$BS1" "$CAT" "^$RULE\$"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S2b plan only on main (not in the diff): want no line, got rc $RC: $OUT"
mkdir -p "$T/c3/pr-self-check.d"; printf '# empty main file\n' > "$T/c3/pr-self-check.tsv"
sed "s/^$RULE\tnote\t/$RULE\trefuse\t/" "$SRC/catalog/pr-self-check.d/bh-7378-plan-body-requires.tsv" > "$T/c3/pr-self-check.d/x.tsv"
grep -q "^$RULE${TAB}refuse${TAB}" "$T/c3/pr-self-check.d/x.tsv" || bad "S3 setup: the row did not turn to refuse"
run s1 "$BS1" "$T/c3/pr-self-check.tsv"
{ [ "$RC" = 0 ] && has "$OUT" "NOTE $RULE: the body is missing ## Flip evidence" && ! has "$OUT" REFUSE; } \
  && ok || bad "S3 row in refuse mode: want still NOTE, no REFUSE, rc 0; got rc $RC: $OUT"
# S4: the full catalog with and without the fragment, on a body that a refuse rule fails.
mkdir -p "$T/c4a/pr-self-check.d" "$T/c4b/pr-self-check.d"
cp "$CAT" "$T/c4a/pr-self-check.tsv"; cp "$CAT" "$T/c4b/pr-self-check.tsv"
cp "$SRC"/catalog/pr-self-check.d/*.tsv "$T/c4a/pr-self-check.d/"
cp "$SRC"/catalog/pr-self-check.d/*.tsv "$T/c4b/pr-self-check.d/"; rm -f "$T/c4b/pr-self-check.d/bh-7378-plan-body-requires.tsv"
BS4=$(body s4.md $'Closes #1\n\n## Acceptance\n- [ ] the thing is not done\n')
run s1 "$BS4" "$T/c4a/pr-self-check.tsv"; RCA=$RC; OA="$OUT"
run s1 "$BS4" "$T/c4b/pr-self-check.tsv"; RCB=$RC; OB="$OUT"
{ [ "$RCA" = "$RCB" ] && [ "$(grep '^REFUSE' <<<"$OA")" = "$(grep '^REFUSE' <<<"$OB")" ] && grep -q '^REFUSE' <<<"$OA" \
  && has "$OA" "NOTE $RULE: the body is missing" && ! has "$OB" "$RULE"; } \
  && ok || bad "S4 verdict unchanged by the rule: rc $RCA vs $RCB; with: $OA ;; without: $OB"
rm -rf "$T/tmp"/*
run s1 "$(body s5.md $'## Merge condition\nafter #1\n## Flip evidence\nred then green\n')" "$CAT" "^$RULE\$"
left=$(find "$T/tmp" -name 'pbr-*' | wc -l | tr -d ' ')
{ [ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$left" = 0 ]; } && ok || bad "S5 same head, body edited: want no line and no pbr-* temp files, got rc $RC, $left left: $OUT"
# S6: the two forwarders on main keep the line (sed copied verbatim).
f1=$(printf '%s\n' "$S1_OUT" | sed -n 's/^NOTE \(body-[a-z0-9-]*: the body is missing .*\)/\1/p')
printf '%s\n' "$S1_OUT" > "$T/lgsc.out"
f2=$(sed -n 's/^NOTE \(body-[a-z0-9-]*: the body is missing .*\)/\1/p' "$T/lgsc.out")
{ [ "$f1" = "$RULE: the body is missing ## Flip evidence (required by T3)" ] && [ "$f2" = "$f1" ] \
  && grep -qF "sed -n 's/^NOTE \\(body-[a-z0-9-]*: the body is missing .*\\)/\\1/p'" "$SRC/bin/lead-review-enqueue.sh" \
  && grep -qF "sed -n 's/^NOTE \\(body-[a-z0-9-]*: the body is missing .*\\)/\\1/p'" "$SRC/bin/lib/lead-gates-selfcheck.sh"; } \
  && ok || bad "S6 the forwarders keep the line: got '$f1' / '$f2'"
br s7; git -C "$R" rm -q .harness/specs/BH-0/plan.md; cm s7
run s7 "$BS1" "$CAT" "^$RULE\$"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S7 a plan the PR deletes: want no line, got rc $RC: $OUT"

# ── R1-R3: the planner sentence ───────────────────────────────────────────────
RULE_TXT=$(bash -c '. "$1/bin/lib/pr-body-requires.sh"; pbr_plan_rule' _ "$H")
{ has "$RULE_TXT" 'pr-body-requires' && has "$RULE_TXT" ' <- ' && has "$RULE_TXT" 'PR body'; } && ok || bad "R1 the sentence: got: $RULE_TXT"
r2=0
for f in bin/lib/rb/plan.sh bin/run-preplan.sh; do
  [ "$(grep -c 'pbr_plan_rule' "$SRC/$f")" = 1 ] || { r2=1; echo "  R2 $f: pbr_plan_rule count is not 1"; }
  inblk=$(awk '/^# >>> pr-body-requires note \(BH-7378\)/{b=1} b && /pbr_plan_rule/{print "in"} /^# <<< pr-body-requires note \(BH-7378\)/{b=0}' "$SRC/$f")
  [ "$inblk" = in ] || { r2=1; echo "  R2 $f: the call is not inside the marked block"; }
  bash -n "$SRC/$f" || { r2=1; echo "  R2 $f: bash -n failed"; }
done
[ "$r2" = 0 ] && ok || bad "R2 the two seams"
ex=$(sed -n "s/.*for example '\([^']*\)'.*/\1/p" <<<"$RULE_TXT")
items "$(plan r3.md "$(printf '```pr-body-requires\n%s\n```\n' "$ex")")"
{ [ -n "$ex" ] && [ "$ITEMS" = "## Flip evidence${TAB}T3" ]; } && ok || bad "R3 the sentence's example round-trips through pbr_items: ex='$ex' got: $ITEMS"
# R4: the seam really appends the sentence (run the marked block on its own).
r4=$(HARNESS="$H" bash -c 'UI_PLAN_NOTE="x "; eval "$(awk "/^# >>> pr-body-requires note \\(BH-7378\\)/{b=1} b{print} /^# <<< pr-body-requires note \\(BH-7378\\)/{b=0}" "$1")"; printf "%s" "$UI_PLAN_NOTE"' _ "$SRC/bin/lib/rb/plan.sh")
{ [ "${r4:0:2}" = "x " ] && has "$r4" "$RULE_TXT"; } && ok || bad "R4 plan.sh block appends the sentence to UI_PLAN_NOTE: got: $r4"
r5=$(HARNESS="$H" bash -c 'PP_PREAMBLE="y "; eval "$(awk "/^# >>> pr-body-requires note \\(BH-7378\\)/{b=1} b{print} /^# <<< pr-body-requires note \\(BH-7378\\)/{b=0}" "$1")"; printf "%s" "$PP_PREAMBLE"' _ "$SRC/bin/run-preplan.sh")
{ [ "${r5:0:2}" = "y " ] && has "$r5" "$RULE_TXT"; } && ok || bad "R5 run-preplan.sh block appends the sentence to PP_PREAMBLE: got: $r5"

echo "pr-body-requires (BH-7378): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
