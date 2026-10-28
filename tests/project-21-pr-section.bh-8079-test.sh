#!/bin/bash
# tests/project-21-pr-section.bh-8079-test.sh — the "Dependency advisories (project-21)"
# PR body section, and the build lane's project-21 block in bin/lib/rb/pr.sh.
#   P1-P5  project-21_pr_section on result files the real CLI wrote: affected,
#          clean, failed, nothing, partial (never "None known")
#   P6-P8  off and a missing file render nothing; a `|` in a field becomes `/`;
#          an unknown state renders as failed
#   P9-P11 the pr.sh `project-21 check (BH-8079)` block and the evidence block,
#          extracted by their markers and run in a scratch repo against the
#          fake API: the body carries the section (affected, clean, HTTP 500)
#   P12    budget: 1 POST per head, whatever the number of body renders
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/project-21-pr-section.bh-8079-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PROJECT_21_ENABLED PROJECT_21_TIMEOUT_S PROJECT_21_SECTION

H="$T/h"; mkdir -p "$H"
scratch_install_closure bin/project-21-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/project-21-check.sh"; exit 1; }
[ -r "$H/bin/lib/project-21.example" ] || { echo "FAIL: bin/lib/project-21.example is not in the closure of bin/project-21-check.sh"; exit 1; }
# shellcheck source=bin/lib/project-21.example
. "$H/bin/lib/project-21.example" || { echo "FAIL: $SRC/bin/lib/project-21.example does not source"; exit 1; }
. "$SRC/tests/lib/project-21-fake.bh-8079.sh" "$SRC" || exit 1
tf_start || exit 1

R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q -b main
printf '{"lockfileVersion":3}\n' > "$R/package-lock.json"
git -C "$R" add -A && git -C "$R" commit -qm "BH-8079: the subject"
HEAD1=$(git -C "$R" rev-parse HEAD)
HEAD="project-21 found 2 advisory(ies) at head ${HEAD1:0:12}."

result() { # result <mode> <out-file> [repo]
  tf_mode "$1"; "$H/bin/project-21-check.sh" "${3:-$R}" --out "$2" --head "$HEAD1" >/dev/null 2>&1
}
has() { grep -qF -- "$2" <<<"$1"; }

# P1 affected
result affected "$T/aff.json"; s=$(project-21_pr_section "$T/aff.json")
{ [ "$(head -1 <<<"$s")" = '## Dependency advisories (project-21)' ] && has "$s" "$HEAD" \
  && has "$s" '| dependency | version | severity | fixed in | upgrade | advisory |' \
  && has "$s" '| lodash (npm) | 4.17.15 | high | 4.17.21 | Upgrade lodash to 4.17.21 or later. | GHSA-p6mc-m468-83gw https://osv.dev/vulnerability/GHSA-p6mc-m468-83gw |' \
  && [ "$(grep -c '^| lodash (npm) |' <<<"$s")" = 2 ] && ! has "$s" 'None known'; } && ok || bad "P1 affected: $s"

# P2 clean
result clean "$T/clean.json"; s=$(project-21_pr_section "$T/clean.json")
{ has "$s" '## Dependency advisories (project-21)' && has "$s" 'None known: 2 dependencies checked in `package-lock.json`.' \
  && ! has "$s" '| dependency |'; } && ok || bad "P2 clean: $s"

# P3 failed
result 500 "$T/fail.json"; s=$(project-21_pr_section "$T/fail.json")
{ has "$s" '## Dependency advisories (project-21)' && has "$s" 'Check failed (HTTP 500). This is not a clean result.' \
  && ! has "$s" 'None known'; } && ok || bad "P3 failed: $s"

# P4 nothing
mkdir -p "$T/empty" && git -C "$T/empty" init -q -b main && printf x > "$T/empty/a" && git -C "$T/empty" add -A && git -C "$T/empty" commit -qm e
result clean "$T/none.json" "$T/empty"; s=$(project-21_pr_section "$T/none.json")
{ has "$s" '## Dependency advisories (project-21)' && has "$s" 'Nothing to check: no lockfile in this tree.'; } && ok || bad "P4 nothing: $s"

# P5 partial: the skip is listed, and the section never says None known
result partial "$T/part.json"; s=$(project-21_pr_section "$T/part.json")
{ has "$s" 'Partial coverage: 1 item(s) were not checked, so this is not a clean result.' \
  && has "$s" '- `{"file":"go.sum","reason":"partial_coverage"}`' && ! has "$s" 'None known'; } && ok || bad "P5 partial: $s"
result zero "$T/zero.json"; s=$(project-21_pr_section "$T/zero.json")
{ has "$s" 'Partial coverage: 0 dependencies checked, so this is not a clean result.' && ! has "$s" 'None known'; } \
  && ok || bad "P5 zero checked: $s"

# P6 off and P7 missing render nothing
tf_mode affected; PROJECT_21_ENABLED=0 "$H/bin/project-21-check.sh" "$R" --out "$T/off.json" >/dev/null 2>&1
s=$(project-21_pr_section "$T/off.json")
{ [ "$(jq -r .state "$T/off.json")" = off ] && [ -z "$s" ]; } && ok || bad "P6 off: '$s'"
s=$(project-21_pr_section "$T/nope.json")
[ -z "$s" ] && ok || bad "P7 missing file: '$s'"
printf '{"state":"weird"}\n' > "$T/weird.json"; s=$(project-21_pr_section "$T/weird.json")
has "$s" 'Check failed (unreadable result). This is not a clean result.' && ok || bad "P7 unknown state: $s"

# P8 a pipe in a field becomes a slash
jq '.affected[0].action = "Upgrade a | b now."' "$T/aff.json" > "$T/pipe.json"
s=$(project-21_pr_section "$T/pipe.json")
{ has "$s" '| Upgrade a / b now. |' && [ "$(grep -c '^| lodash (npm) |' <<<"$s")" = 2 ]; } && ok || bad "P8 pipe: $s"

# ── P9-P12: the pr.sh block, then PR_BODY_FOR ───────────────────────────────
PRSH="$SRC/bin/lib/rb/pr.sh"
awk '/^# >>> project-21 check \(BH-8079\)/{f=1;next} /^# <<< project-21 check \(BH-8079\)/{exit} f' "$PRSH" > "$T/project-21-block.sh"
awk '/^# >>> evidence block/{f=1;next} /^# <<< evidence block/{exit} f' "$PRSH" > "$T/block.sh"
awk '/^# >>> merge note fn/{f=1;next} /^# <<< merge note fn/{exit} f' "$PRSH" > "$T/mergenote.sh"
{ [ -s "$T/project-21-block.sh" ] && [ -s "$T/block.sh" ] && grep -q 'PROJECT_21_SECTION' "$T/block.sh"; } \
  && ok || bad "P9 setup: the project-21 block or PROJECT_21_SECTION in the evidence block is missing"
lp=$(grep -n '^# <<< pr push' "$PRSH" | cut -d: -f1); lt=$(grep -n '^# >>> project-21 check (BH-8079)' "$PRSH" | cut -d: -f1)
lb=$(grep -n '^PR_BODY_FOR() {' "$PRSH" | cut -d: -f1)
{ [ -n "$lp" ] && [ -n "$lt" ] && [ -n "$lb" ] && [ "$lp" -lt "$lt" ] && [ "$lt" -lt "$lb" ]; } \
  && ok || bad "P9 order: pr push end=$lp project-21=$lt PR_BODY_FOR=$lb"

drive() { # drive <build-dir> <body-out> : the project-21 block, then two body renders
  mkdir -p "$1"; : >> "$1/pipeline.log"
  ( cd "$R" || exit 1
    env HARNESS="$H" BUILD="$1" KEY=BH-8079 bash -c '
      set -uo pipefail
      STAMP() { echo "2026-10-23 06:00:00Z"; }
      PROJECT=cromford; SLUG=o/r; BASE=main; TIER=1
      QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="package-lock.json"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0
      job_evidence_put() { return 0; }
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes; EVIDENCE_SECTION=""
      . "$0"; . "$1"; . "$2"
      PR_BODY_FOR "$EVIDENCE_SECTION" > /dev/null
      printf "%s" "$(PR_BODY_FOR "$EVIDENCE_SECTION")" > "$3"
    ' "$T/project-21-block.sh" "$T/mergenote.sh" "$T/block.sh" "$2" 2>"$T/err.txt" )
}

# P9 affected
tf_mode affected; tf_reset; drive "$T/b1" "$T/body1.md"
b=$(cat "$T/body1.md")
{ has "$b" '## Dependency advisories (project-21)' && has "$b" '| lodash (npm) | 4.17.15 | high | 4.17.21 |' \
  && has "$b" '## What' && grep -qx 'project-21 state=affected checked=2 affected=2 skipped=0' <<<"$(sed 's/^.*\] //' "$T/b1/pipeline.log")" \
  && [ "$(jq -r .head "$T/b1/project-21.json")" = "$HEAD1" ] && [ -s "$T/b1/project-21.txt" ]; } \
  && ok || bad "P9 affected body: $(head -c 1500 "$T/body1.md") log=$(cat "$T/b1/pipeline.log") err=$(cat "$T/err.txt")"

# P12 budget: one POST after the block and two body renders; a rerun at the same head adds 0
[ "$(tf_posts)" = 1 ] && ok || bad "P12 budget: want 1 POST for one build, got $(tf_posts)"
drive "$T/b1" "$T/body1b.md"
{ [ "$(tf_posts)" = 1 ] && has "$(cat "$T/body1b.md")" '| lodash (npm) |'; } && ok || bad "P12 rerun at the same head: posts=$(tf_posts)"

# P10 clean
tf_mode clean; drive "$T/b2" "$T/body2.md"
has "$(cat "$T/body2.md")" 'None known: 2 dependencies checked in `package-lock.json`.' && ok || bad "P10 clean body: $(cat "$T/body2.md")"

# P11 HTTP 500: the body still renders whole, with the failed section
tf_mode 500; drive "$T/b3" "$T/body3.md"
b=$(cat "$T/body3.md")
{ has "$b" 'Check failed (HTTP 500). This is not a clean result.' && has "$b" '## What' \
  && has "$b" 'Generated with [Claude Code]' && ! has "$b" 'None known' \
  && grep -q 'project-21 state=failed ' "$T/b3/pipeline.log"; } && ok || bad "P11 500 body: $b log=$(cat "$T/b3/pipeline.log")"

# P12 a new head is checked again, once
printf '{"lockfileVersion":3,"x":1}\n' > "$R/package-lock.json"; git -C "$R" commit -qam "BH-8079: a fix round"
tf_mode affected; tf_reset; drive "$T/b1" "$T/body1c.md"
{ [ "$(tf_posts)" = 1 ] && [ "$(jq -r .head "$T/b1/project-21.json")" = "$(git -C "$R" rev-parse HEAD)" ]; } \
  && ok || bad "P12 new head: posts=$(tf_posts)"

# The knob off: no section at all, the body byte-identical to a body with no block
tf_mode affected; tf_reset
( export PROJECT_21_ENABLED=0; drive "$T/b4" "$T/body4.md" )
{ ! has "$(cat "$T/body4.md")" 'Dependency advisories' && [ "$(tf_posts)" = 0 ] && grep -q 'project-21 state=off ' "$T/b4/pipeline.log"; } \
  && ok || bad "P13 off: posts=$(tf_posts) log=$(cat "$T/b4/pipeline.log")"

echo "project-21-pr-section.bh-8079: PASS $PASS FAIL $FAIL"
[ "$FAIL" = 0 ]
