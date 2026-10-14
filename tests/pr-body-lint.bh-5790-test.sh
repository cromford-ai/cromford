#!/bin/bash
# tests/pr-body-lint.bh-5790-test.sh — BH-5790: the PR-body section lint. Lead
# reviews BLOCKed PRs for missing body sections, and each BLOCK cost a full Opus
# round (#5087: no D1 kill-switch callout, no gate table, no mutation evidence,
# no live hub probe, no Why). The required sections are rows of
# catalog/pr-self-check.tsv (`body-*`), checked by bin/pr-self-check.sh before a
# review is bought, by the build's fix-body round, and (report only) in CI.
#
#   B1  no `## Why`: refused, naming body-why (acceptance test 1)
#   B2  a complete body: passes
#   B3  the diff touches bin/pr-owner-sweep.sh and the body has no D1 callout:
#       a NOTE naming body-d1 (acceptance test 2, as decided 2026-10-10: d1 and
#       mutation are `note`, carried to the lead, never a hold); with the
#       callout, nothing
#   B4  the diff adds a settings knob ("env" in catalog/lanes.d) and no callout:
#       a NOTE; a diff that only edits a note line there: not fired
#   B5  the diff adds a test suite and the body has no mutation evidence:
#       a NOTE; with it, nothing; a diff that only edits a suite: not fired
#   M   the catalog modes: why, acceptance, live-probe refuse; mutation, d1 note
#   B6  the ticket's Done when names a probe and the body shows none: refused;
#       with the probe output, passes
#   B7  no ticket text: the probe rule is a NOTE, never a refusal
#   B8  a body row set to `off`: not checked
#   B9  --only '^body-' runs the body rules and nothing else
#   F1  bin/lib/rb/pr.sh's fix-body round: a body with no Why buys one fix
#       turn; the sections it writes are appended, the re-run is clean, and the
#       log says fixed
#   F1b the sections land before the `---` / "Plan: harness build" footer,
#       and the attribution line stays last
#   F2  a complete body: no fix turn
#   F3  the fix turn writes nothing: the original body lines stay, the
#       findings section names what is still missing (BH-6393), the log names
#       it, and the PR still opens (the span returns)
#   F4  PR_SELF_CHECK=0: no fix turn, one log line (lead review lr-5846)
#   C1  CI runs the body rules on the event's PR body, report only
# A real git fixture: main, then one branch per diff shape.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-body-lint.bh-5790-test.sh
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
R="$T/repo"; mkdir -p "$R/bin" "$R/tests" "$R/catalog/lanes.d"
git -C "$R" init -q -b main
echo a > "$R/bin/a.sh"; echo o > "$R/bin/pr-owner-sweep.sh"; echo t > "$R/tests/old-test.sh"
printf '{\n  "knobs": [\n    {\n      "env": "OLD_KNOB",\n      "note": "old"\n    }\n  ]\n}\n' > "$R/catalog/lanes.d/x.json"
git -C "$R" add -A; git -C "$R" commit -qm M0
branch() { # branch <name> <change-fn>
  git -C "$R" checkout -q main; git -C "$R" checkout -qb "$1"; ( cd "$R" && "$2" ); git -C "$R" add -A; git -C "$R" commit -qm "$1"
}
ch_plain()  { echo b > bin/a.sh; }
ch_own()    { echo o2 > bin/pr-owner-sweep.sh; }
ch_knob()   { printf '{\n  "knobs": [\n    {\n      "env": "OLD_KNOB",\n      "note": "old"\n    },\n    {\n      "env": "NEW_KNOB",\n      "note": "new"\n    }\n  ]\n}\n' > catalog/lanes.d/x.json; }
ch_note()   { sed -i.bak 's/"old"/"older"/' catalog/lanes.d/x.json && mv catalog/lanes.d/x.json.bak "$T/x.bak"; }
ch_test()   { echo n > tests/new-thing-test.sh; }
ch_edtest() { echo t2 > tests/old-test.sh; }
for b in plain own knob note test edtest; do branch "pr-$b" "ch_$b"; done

WHY=$'## Why\nThe merge queue drops this PR shape every batch today, and nothing says so.\n'
ACC=$'## Acceptance tests\n| case | result |\n|---|---|\n| B1 | pass |\n'
D1=$'**D1 kill knob:** `pr_owner.enroll_external=0` turns it off with no deploy.\n'
MUT=$'Mutation evidence: with the guard removed, 3 cases fail (red), and pass with it.\n'
PROBE=$'## Live probe\n```\n$ bin/hub-lease.sh check; echo rc=$?\nrc=0\n```\n'
FULL="Refs #5

## What
x

$WHY
$ACC"
check() { # check <body> <branch> [ticket-file] [--only re] — sets RC and OUT
  printf '%s\n' "$1" > "$T/body.md"
  local tk=(); [ -n "${3:-}" ] && tk=(--ticket "$3")
  OUT=$("$H/bin/pr-self-check.sh" check --repo "$R" --base main --head "$2" --body "$T/body.md" "${tk[@]}" ${4:+--only "$4"} 2>&1); RC=$?
}
refused() { grep -q "^REFUSE $1:" <<<"$OUT"; }
noted()   { grep -q "^NOTE $1: the body is missing" <<<"$OUT"; }

# ── B1/B2 ───────────────────────────────────────────────────────────────────
check "Refs #5

## What
x

$ACC" pr-plain
[ "$RC" = 1 ] && refused body-why && ok || bad "B1 a body with no Why passed (rc $RC): $OUT"
check "$FULL" pr-plain
[ "$RC" = 0 ] && ! grep -q '^REFUSE body-' <<<"$OUT" && ok || bad "B2 a complete body was refused (rc $RC): $OUT"
check "Refs #5

$WHY" pr-plain
refused body-acceptance && ok || bad "B2 a body with no acceptance section or table passed: $OUT"

# ── B3/B4: the D1 callout ───────────────────────────────────────────────────
check "$FULL" pr-own
[ "$RC" = 0 ] && noted body-d1 && ! refused body-d1 && ok || bad "B3 a merge-ownership diff with no D1 callout is not a NOTE (rc $RC): $OUT"
check "$FULL
$D1" pr-own
! noted body-d1 && ok || bad "B3 the D1 callout was not seen: $OUT"
check "$FULL" pr-knob
noted body-d1 && ok || bad "B4 an added knob with no callout is not a NOTE: $OUT"
check "$FULL" pr-note
! noted body-d1 && ok || bad "B4 an edited note line in catalog/lanes.d fired body-d1: $OUT"

# ── B5: mutation evidence for a new suite ───────────────────────────────────
check "$FULL" pr-test
[ "$RC" = 0 ] && noted body-mutation && ok || bad "B5 a new suite with no mutation evidence is not a NOTE (rc $RC): $OUT"
check "$FULL
$MUT" pr-test
! noted body-mutation && ok || bad "B5 the mutation evidence was not seen: $OUT"
check "$FULL" pr-edtest
! noted body-mutation && ok || bad "B5 an edited suite fired body-mutation: $OUT"

# ── M: the modes the lead decided (2026-10-10): mutation and d1 note, the rest refuse
for r in body-why:refuse body-acceptance:refuse body-live-probe:refuse body-mutation:note body-d1:note; do
  awk -F'\t' -v id="${r%%:*}" -v m="${r##*:}" '$1 == id && $2 == m {f = 1} END {exit !f}' "$DIR/catalog/pr-self-check.tsv" \
    && ok || bad "M ${r%%:*} is not ${r##*:} in catalog/pr-self-check.tsv"
done

# ── B6/B7: the live probe the ticket names ──────────────────────────────────
printf '## Problem\nx\n\n## Done when\n- the live hub probe `bin/hub-lease.sh check` answers rc=0 on the hub\n' > "$T/ticket.md"
printf '## Problem\nx\n\n## Done when\n- the suite passes\n' > "$T/ticket-np.md"
check "$FULL" pr-plain "$T/ticket.md"
refused body-live-probe && ok || bad "B6 a ticket probe with no probe output passed: $OUT"
check "$FULL
$PROBE" pr-plain "$T/ticket.md"
! refused body-live-probe && ok || bad "B6 the probe output was not seen: $OUT"
check "$FULL" pr-plain "$T/ticket-np.md"
! refused body-live-probe && ok || bad "B6 a ticket with no probe fired body-live-probe: $OUT"
check "$FULL" pr-plain
! refused body-live-probe && grep -q '^NOTE body-live-probe:' <<<"$OUT" && ok || bad "B7 no ticket text must be a note: $OUT"

# ── B8: a row set to off ────────────────────────────────────────────────────
awk -F'\t' -v OFS='\t' '$1 == "body-why" {$2 = "off"} {print}' "$H/catalog/pr-self-check.tsv" > "$T/cat-off.tsv"
OUT=$(PR_SELF_CHECK_CATALOG="$T/cat-off.tsv" "$H/bin/pr-self-check.sh" check --repo "$R" --base main --head pr-plain --body <(printf 'Refs #5\n\n%s\n' "$ACC") 2>&1)
! refused body-why && ok || bad "B8 an off row was checked: $OUT"

# ── B9: --only ──────────────────────────────────────────────────────────────
check "Refs #5

$WHY" pr-plain "" '^body-'
! grep -q 'closes-not-met\|evidence-head\|plan-files' <<<"$OUT" && refused body-acceptance && ok \
  || bad "B9 --only '^body-' ran another rule or skipped a body rule: $OUT"

# ── F1-F3: the fix-body round in bin/lib/rb/pr.sh ───────────────────────────
SPAN="$T/span.sh"
awk '/^# >>> pr body fix round/{f=1} f{print} /^# <<< pr body fix round/{exit}' "$DIR/bin/lib/rb/pr.sh" > "$SPAN"
[ -s "$SPAN" ] && ok || bad "F no '# >>> pr body fix round' span in bin/lib/rb/pr.sh"
fixrun() { # fixrun <case> <body> <fix-text or empty> — runs the span on pr-plain
  local B="$T/$1"; mkdir -p "$B"; printf '%s\n' "$2" > "$B/pr-body.md"; printf '%s' "$3" > "$B/fix.txt"
  echo '{"body":"## Done when\n- the suite passes"}' > "$B/ticket-meta.json"
  git -C "$R" checkout -q pr-plain
  ( cd "$R" && HARNESS="$H" BUILD="$B" BASE=main FIX_MODEL=fix-x PROJECT=cromford KEY=BH-1 bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      CC() { printf "%s\n" "$*" >> "$BUILD/cc.log"; [ -s "$BUILD/fix.txt" ] && cp "$BUILD/fix.txt" "$BUILD/pr-body-fix.md"; return 0; }
      . "$0"; echo SPAN_DONE' "$SPAN" ) > "$B/out" 2>&1
}
fixrun f1 "Refs #5

$ACC" $'## Why\nThe merge queue drops this PR shape every batch today.\n'
grep -q SPAN_DONE "$T/f1/out" && [ "$(grep -c '^fix ' "$T/f1/cc.log" 2>/dev/null)" = 1 ] && grep -q 'body-why' "$T/f1/cc.log" && ok \
  || bad "F1 no single fix turn naming body-why: $(cat "$T/f1/cc.log" "$T/f1/out" 2>/dev/null)"
grep -q '^## Why' "$T/f1/pr-body.md" && grep -q 'pr body: fixed' "$T/f1/pipeline.log" 2>/dev/null && ok \
  || bad "F1 the fix was not appended or not logged fixed: $(cat "$T/f1/pr-body.md") $(cat "$T/f1/pipeline.log" 2>/dev/null)"
# F1b: the added sections land before the footer, which stays last
fixrun f1b "Refs #5

$ACC
---
Plan: harness build x.

🤖 Generated with [Claude Code](https://claude.com/claude-code)" $'## Why\nThe merge queue drops this PR shape every batch today.\n'
WL=$(grep -n '^## Why' "$T/f1b/pr-body.md" | cut -d: -f1); PL=$(grep -n '^Plan: harness build' "$T/f1b/pr-body.md" | cut -d: -f1)
[ -n "$WL" ] && [ -n "$PL" ] && [ "$WL" -lt "$PL" ] && tail -1 "$T/f1b/pr-body.md" | grep -q 'Generated with' && ok \
  || bad "F1b the fix sections are not before the footer: $(cat "$T/f1b/pr-body.md")"
fixrun f2 "$FULL" ""
[ ! -s "$T/f2/cc.log" ] && grep -q SPAN_DONE "$T/f2/out" && ok || bad "F2 a complete body bought a fix turn: $(cat "$T/f2/cc.log" 2>/dev/null)"
fixrun f3 "Refs #5

$ACC" ""
# TEST-CHANGE (BH-6393): an unfixable body now gains the builder's
# `## Pre-open check: refusals left` section after its 2 checks, so the body is
# the original lines, in order, plus that section naming body-why.
F3B=$(awk '/^## Pre-open check: refusals left$/{exit} {print}' "$T/f3/pr-body.md")
[ "$(printf '%s\n' "$F3B" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')" = "$(printf 'Refs #5\n\n%s' "$ACC")" ] \
  && sed -n '/^## Pre-open check: refusals left$/,$p' "$T/f3/pr-body.md" | grep -q '^- body-why:' \
  && grep -q SPAN_DONE "$T/f3/out" && grep -q 'pr body: still missing.*body-why' "$T/f3/pipeline.log" 2>/dev/null && ok \
  || bad "F3 an empty fix lost the original body, wrote no findings naming body-why, stopped the span or logged nothing: $(cat "$T/f3/pr-body.md") $(cat "$T/f3/out") $(cat "$T/f3/pipeline.log" 2>/dev/null)"

# F4 (lead review lr-5846): PR_SELF_CHECK=0 buys no fix turn
B4="$T/f4"; mkdir -p "$B4"; printf 'Refs #5\n\n%s\n' "$ACC" > "$B4/pr-body.md"; printf '## Why\nx y z\n' > "$B4/fix.txt"
echo '{"body":""}' > "$B4/ticket-meta.json"; git -C "$R" checkout -q pr-plain
( cd "$R" && PR_SELF_CHECK=0 HARNESS="$H" BUILD="$B4" BASE=main FIX_MODEL=fix-x PROJECT=cromford KEY=BH-1 bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    CC() { printf "%s\n" "$*" >> "$BUILD/cc.log"; return 0; }
    . "$0"; echo SPAN_DONE' "$SPAN" ) > "$B4/out" 2>&1
[ ! -s "$B4/cc.log" ] && grep -q SPAN_DONE "$B4/out" && grep -q 'self-check is off' "$B4/pipeline.log" 2>/dev/null && ok \
  || bad "F4 PR_SELF_CHECK=0 still bought a fix turn or logged nothing: $(cat "$B4/cc.log" "$B4/pipeline.log" 2>/dev/null)"

# ── C1: CI, report only ─────────────────────────────────────────────────────
WF="$DIR/.github/workflows/harness-ci.yml"
STEP=$(awk '/- name: PR body sections \(BH-5790/{f=1; print; next} f && /^      - name: /{exit} f' "$WF")
grep -q "pr-self-check.sh check" <<<"$STEP" && grep -qF -- "--only '^body-'" <<<"$STEP" && ok || bad "C1 no CI step running the body rules: '$STEP'"
grep -q 'continue-on-error: true' <<<"$STEP" && grep -q 'GITHUB_STEP_SUMMARY' <<<"$STEP" && ok || bad "C1 the CI step is not report only: '$STEP'"

echo "pr-body-lint.bh-5790: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
