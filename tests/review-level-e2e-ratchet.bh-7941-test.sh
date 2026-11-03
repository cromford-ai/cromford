#!/bin/bash
# tests/review-level-e2e-ratchet.bh-7941-test.sh — BH-7941: in the lead review,
# E2E is a ratchet. bin/lib/review-level.sh's rl_cap (lens lead) rewrites an
# E2E finding that says the test is red on main too, or that asks for "N full
# runs" / a per-spec table, to a NOTE before the ALWAYS-BLOCK floor. The
# phrases live in catalog/review-e2e-ratchet.tsv.
#
#   C1-C5   demote: pre-existing (1-3, carry `follow-up`), evidence form (4, 5);
#           the verdict BLOCK -> MERGE-WITH-NOTES, summary demoted=1 standing=0
#   C5a-C5b demote: a main-run result, a pre-existing failure on origin/main
#   R1-R5   stand: regressions in ordinary phrasing (anchored phrases)
#   C6-C12, C15-C19  stand: regression, negation, no E2E word, a unit test,
#           another ALWAYS-BLOCK class, a deletion, a mixed line, "no E2E run",
#           a failure that names no main or nightly, main-v2
#   C13     lens inbuild and lens prs: C1's line stands
#   C14     REVIEW_LEVEL_E2E_RATCHET=0: stands; unset: demotes, for project-6
#           and other-os
#   MX      a pre-existing E2E line plus a tenant leak: the E2E line demotes,
#           the verdict stays BLOCK
#   ID      a second rl_cap leaves the file byte-identical, same summary
#   D1-D4   the measured list decides, not the sentence: no --e2e file, a
#           COULD NOT READ body, a spec not in pre-existing, no spec named
#   D5      an evidence ask that reports no failure demotes with no --e2e file
#   D6-D8b  an evidence ask on a red head stands (a failing run, "both red",
#           a core-flow-broken sign-in), with or without a measured list
#   D9-D17  an evidence ask stands when it reports a red head in other words
#           (timed out, errored, crashes, did not pass, hung) or names a spec
#           file or a run id; a bare "run 3 full runs" ask still demotes
#   X1-X9   the refute review's lines stand: a regression worded without a
#           keep phrase, a red main run on another spec, a weakened test of a
#           red-on-main spec, a dead sign-in button, money, an evidence ask
#           that names a regression spec
#   W1-W9   an evidence ask on top of a weakened test stands (|| true, fixme,
#           retries, continue-on-error, comment out); W8 the bare ask still
#           demotes; W9 mutation: no weakened-test check -> W1 demotes
#   M1      mutation: the catalog emptied in a scratch root -> C1 stands
#   M2      no e2e-soft-class row: the rule is off; C1 and a tenant leak stand
# Run: HARNESS_TEST_SANDBOX=1 bash tests/review-level-e2e-ratchet.bh-7941-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for f in bin/lib/review-level.sh catalog/review-always-block.tsv catalog/review-e2e-ratchet.tsv; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done

# A scratch root of its own: M1 empties a catalog in it, never in the repo.
R="$T/h"; mkdir -p "$R/bin/lib" "$R/catalog"
scratch_install_closure bin/lib/review-level.sh "$R" >/dev/null || bad "closure of bin/lib/review-level.sh"
cp "$SRC"/catalog/review-*.tsv "$R/catalog/"
export HARNESS="$R" JOBS_URL=
unset REVIEW_LEVEL_MODE REVIEW_LEVEL_E2E_RATCHET REVIEW_LEVEL_GOLIVE_GATES_MERGE

# The `## Main E2E` bodies emb_section writes (bin/lib/e2e-main-baseline.sh).
# E2E_DEF: the specs the demote cases name are red on main and head.
# E2E_REG: a.spec.ts and checkout.spec.ts are regressions; b and login are not.
E2E_DEF="$T/e2e-def.txt"; E2E_REG="$T/e2e-reg.txt"; E2E_CNR="$T/e2e-cnr.txt"
printf '%s\n' 'main: E2E run 4411 (schedule, aaaaaaaa, 2026-10-21T03:00:00Z) failure; 5 failing spec(s)' \
  'head: E2E run 4500 (pull_request, bbbbbbbb, 2026-10-22T01:00:00Z) failure; 6 failing spec(s)' \
  'pre-existing (red on main and head):' '  - e2e/checkout.spec.ts › Checkout › pays' '  - e2e/login.spec.ts › Login › signs in' \
  '  - settings.spec.ts › Settings › saves' '  - e2e/a.spec.ts › A › works' '  - e2e/cart.spec.ts › Cart › adds' \
  'regression (red on head, not on main):' '  - e2e/pay.spec.ts › Pay › pays' > "$E2E_DEF"
printf '%s\n' 'main: E2E run 9 (push, aaaaaaaa, 2026-10-21T03:00:00Z) failure; 2 failing spec(s)' \
  'head: E2E run 10 (pull_request, bbbbbbbb, 2026-10-22T01:00:00Z) failure; 4 failing spec(s)' \
  'pre-existing (red on main and head):' '  - e2e/b.spec.ts › B › works' '  - e2e/login.spec.ts › Login › signs in' \
  'regression (red on head, not on main):' '  - e2e/a.spec.ts › A › works' '  - e2e/checkout.spec.ts › Checkout › pays' > "$E2E_REG"
printf '%s\n' 'main: COULD NOT READ (HTTP 502)' 'comparison: not possible; judge an E2E failure from the PR body and thread (checklist item 17)' > "$E2E_CNR"
E2EF="$E2E_DEF"

# cap <id> <line> [lens] [project] — runs rl_cap in a fresh shell on a
# lead-shaped review, with --e2e "$E2EF" when E2EF is set; sets OUT (summary)
# and F (the file).
cap() {
  local id="$1" line="$2" lens="${3:-lead}" p="${4:-project-6}" aw=MERGE-WITH-NOTES bw=BLOCK
  local -a ex=(); [ -n "${E2EF:-}" ] && ex=(--e2e "$E2EF")
  F="$T/$id.md"
  case "$lens" in
    inbuild) aw=APPROVE; bw=BLOCK ;;
    prs) aw=APPROVE; bw=REQUEST_CHANGES ;;
  esac
  printf 'Findings\n%s\n\nVERDICT: %s\n' "$line" "$bw" > "$F"
  OUT=$(REVIEW_LEVEL_MODE=levels bash -c '. "$HARNESS/bin/lib/review-level.sh" || exit 9; rl_cap "$@"' _ \
    "$F" "$p" --approve "$aw" --block "$bw" --lens "$lens" "${ex[@]}" 2>"$T/$id.err")
}
demotes() { # demotes <id> <line> <want-text>
  cap "$1" "$2"
  local want="$3" got
  got=$(sed -n 2p "$F")
  grep -q '^- \[NOTE demoted from [A-Z]*[^]]*, e2e ratchet (BH-7941): ' <<<"$got" && ok || bad "$1 not demoted: $got ($OUT)"
  grep -qF -- "$want" <<<"$got" && ok || bad "$1 lacks '$want': $got"
  [ "$(tail -1 "$F")" = 'VERDICT: MERGE-WITH-NOTES' ] && ok || bad "$1 verdict: $(tail -1 "$F")"
  grep -q 'demoted=1 standing=0 verdict=MERGE-WITH-NOTES' <<<"$OUT" && ok || bad "$1 summary: $OUT"
}
stands() { # stands <id> <line> [lens] [project]
  cap "$1" "$2" "${3:-lead}" "${4:-project-6}"
  [ "$(sed -n 2p "$F")" = "$2" ] && ok || bad "$1 line changed: $(sed -n 2p "$F")"
  grep -qE '^VERDICT: (BLOCK|REQUEST_CHANGES)$' "$F" && ok || bad "$1 verdict flipped: $(tail -1 "$F")"
  grep -q 'e2e ratchet' "$F" && bad "$1 carries an e2e ratchet rewrite: $(cat "$F")" || ok
}

L1='- [BLOCK red-build] e2e/checkout.spec.ts:40: the Playwright test fails on the head; it also fails on main (nightly run 4411).'
# ── C1-C5 demote ──
demotes C1 "$L1" 'pre-existing on main; follow-up]'
grep -qF 'e2e/checkout.spec.ts:40: the Playwright test fails on the head; it also fails on main (nightly run 4411).' "$T/C1.md" \
  && ok || bad "C1 the finding text was not kept: $(sed -n 2p "$T/C1.md")"
demotes C2 '- [HIGH] playwright: e2e/login.spec.ts already fails on main' 'follow-up'
demotes C3 '- [BLOCK core-flow-broken] e2e/settings.spec.ts is red on main too' 'follow-up'
demotes C4 '- [BLOCK weakened-test] the PR body shows one full E2E run, not 3 full runs' 'one full E2E run is enough evidence]'
demotes C5 '- [BLOCK red-build] no per-spec table for the E2E suite' 'one full E2E run is enough evidence]'
demotes C5a "- [BLOCK red-build] e2e/a.spec.ts: main's nightly run is red on this spec too" 'follow-up'
demotes C5b '- [BLOCK red-build] e2e/a.spec.ts fails on the head; a pre-existing failure, red on origin/main.' 'follow-up'

# ── C6-C12, C15 stand ──
stands C6 '- [BLOCK red-build] e2e/checkout.spec.ts passes on main and fails on the head'
stands C7 '- [BLOCK red-build] e2e/a.spec.ts does not fail on main; it fails here'
stands C8 '- [BLOCK red-build] typecheck fails; main is red too'
stands C9 '- [BLOCK red-build] lib/x.test.ts already fails on main'
stands C10 "- [BLOCK tenant-leak] e2e/tenant.spec.ts already fails on main because the API returns another company's rows"
stands C11 '- [BLOCK weakened-test] the diff deletes 3 specs from the per-spec table'
stands C12 '- [BLOCK red-build] the head adds a regression in e2e/checkout.spec.ts; e2e/login.spec.ts already fails on main'
stands C15 '- [BLOCK red-build] the PR shows no E2E run on the head'
stands C16 '- [BLOCK red-build] e2e/a.spec.ts fails on the head; this is not a pre-existing failure'
# C17-C19: a failure that does not name main or the nightly is no proof it is
# red on main (the #7963 review's NOTE), and main-v2 is not main.
stands C17 "- [BLOCK red-build] e2e/login.spec.ts: the head's E2E job is already failing at sign-in"
stands C18 "- [BLOCK red-build] e2e: a pre-existing failure in the head's new spec"
stands C19 '- [BLOCK red-build] e2e/a.spec.ts fails on main-v2 branch'
# R1-R5: true regressions in ordinary phrasing stand (the BH-7941 review's
# cases a-e): a main-run span that reached the head's failure, a "no
# failures" main run, a "does not appear", a bare pre-existing, main-merge.
stands R1 "- [BLOCK red-build] e2e/checkout.spec.ts: main's latest run passed; the head fails this spec."
stands R2 "- [BLOCK red-build] the E2E job fails on this head; main's nightly run had no failures."
stands R3 "- [BLOCK red-build] e2e/a.spec.ts: the head fails, and it does not appear in main's last run failures."
stands R4 '- [BLOCK core-flow-broken] e2e: the diff breaks the pre-existing login flow; the spec now fails.'
stands R5 '- [BLOCK red-build] e2e/a.spec.ts fails on main-merge of this head.'

# ── C13 other lenses ──
stands C13a "$L1" inbuild
stands C13b "$L1" prs

# ── C14 knob ──
REVIEW_LEVEL_E2E_RATCHET=0 stands C14a "$L1"
REVIEW_LEVEL_E2E_RATCHET=0 stands C14b "$L1" lead other-os
demotes C14c "$L1" 'follow-up'
cap C14d "$L1" lead other-os
grep -q 'e2e ratchet (BH-7941)' "$F" && [ "$(tail -1 "$F")" = 'VERDICT: MERGE-WITH-NOTES' ] && ok || bad "C14d other-os default did not demote: $(cat "$F")"

# ── MX mixed: a tenant leak keeps the verdict ──
F="$T/mx.md"
printf 'Findings\n%s\n%s\n\nVERDICT: BLOCK\n' "$L1" '- [BLOCK tenant-leak] app/api/rows/route.ts:12: reads rows of every company' > "$F"
OUT=$(REVIEW_LEVEL_MODE=levels bash -c '. "$HARNESS/bin/lib/review-level.sh"; rl_cap "$1" project-6 --approve MERGE-WITH-NOTES --block BLOCK --lens lead --e2e "$2"' _ "$F" "$E2EF")
grep -q 'demoted=1 standing=1 verdict=BLOCK' <<<"$OUT" && ok || bad "MX summary: $OUT"
grep -q '^- \[NOTE demoted from BLOCK red-build, e2e ratchet' "$F" && ok || bad "MX e2e line: $(cat "$F")"
grep -qx '\- \[BLOCK tenant-leak\] app/api/rows/route.ts:12: reads rows of every company' "$F" && ok || bad "MX leak line changed"
[ "$(tail -1 "$F")" = 'VERDICT: BLOCK' ] && ok || bad "MX verdict: $(tail -1 "$F")"

# ── ID idempotent ──
cap ID "$L1"; cp "$F" "$T/id.once"; o1="$OUT"
OUT=$(REVIEW_LEVEL_MODE=levels bash -c '. "$HARNESS/bin/lib/review-level.sh"; rl_cap "$1" project-6 --approve MERGE-WITH-NOTES --block BLOCK --lens lead --e2e "$2"' _ "$F" "$E2EF")
cmp -s "$F" "$T/id.once" && ok || bad "ID second pass changed the file"
[ "$OUT" = "$o1" ] && ok || bad "ID summary '$OUT' != '$o1'"

# ── D1-D4: the measured list decides, not the sentence ──
E2EF="" stands D1 "$L1"
E2EF="$E2E_CNR" stands D2 "$L1"
stands D3 '- [BLOCK red-build] e2e/other.spec.ts fails on the head; it also fails on main (nightly run 4411).'
stands D4 '- [BLOCK red-build] the Playwright job fails on the head; it also fails on main (nightly run 4411).'
# The evidence ask needs no measured list.
E2EF="" demotes D5 '- [BLOCK red-build] no per-spec table for the E2E suite' 'one full E2E run is enough evidence]'
# D6-D8: an evidence ask on top of a head that is red stands, with or without
# a measured list (lead review of #8142, acceptance 2).
E2EF="" stands D6 '- [BLOCK red-build] e2e/new.spec.ts fails on the head (run 5001 red); rerun 3 full runs to rule out a flake'
E2EF="" stands D7 '- [BLOCK red-build] the head E2E run 5001 is red on e2e/new.spec.ts; the PR shows 2 runs, both red'
E2EF="" stands D8 '- [BLOCK core-flow-broken] Playwright: e2e/login.spec.ts sign-in fails on this head; give a per-spec table'
stands D6b '- [BLOCK red-build] e2e/new.spec.ts fails on the head (run 5001 red); rerun 3 full runs to rule out a flake'
stands D8b '- [BLOCK core-flow-broken] Playwright: e2e/login.spec.ts sign-in fails on this head; give a per-spec table'
# D9-D12: the second lead review of #8142. A red head reported in other words
# (timed out, errored, crashes, did not pass) stands, with or without a
# measured list: an evidence ask that names a spec file or a run id is about
# one concrete result, not a demotable evidence nit.
E2EF="" stands D9 '- [BLOCK red-build] e2e/new.spec.ts timed out on the head run 5001; rerun 3 full runs to rule out a flake'
E2EF="" stands D10 '- [BLOCK red-build] the head E2E run 5001 errored on e2e/new.spec.ts; need 2 runs'
E2EF="" stands D11 '- [BLOCK red-build] e2e/new.spec.ts crashes on this head; give a per-spec table'
E2EF="" stands D12 '- [BLOCK red-build] e2e/new.spec.ts did not pass on this head; give 3 full runs'
stands D9b '- [BLOCK red-build] e2e/new.spec.ts timed out on the head run 5001; rerun 3 full runs to rule out a flake'
stands D12b '- [BLOCK red-build] e2e/new.spec.ts did not pass on this head; give 3 full runs'
# D13-D15: the structural guard alone. No failure word, but a spec file or a
# run id is named: the line stands. D16: a bare ask with "run 3" (an ask,
# not a run id) still demotes. D17: a red head in new words and no spec or
# run named stands on the widened e2e-head-red row.
E2EF="" stands D13 '- [BLOCK red-build] e2e/new.spec.ts: give 3 full runs before this merges'
E2EF="" stands D14 '- [BLOCK red-build] the E2E run 5001 on the head: give a per-spec table'
E2EF="" stands D15 '- [BLOCK red-build] https://github.com/o/r/actions/runs/123456789 for the E2E job: need 2 runs'
E2EF="" demotes D16 '- [BLOCK red-build] please run 3 full runs of the E2E suite' 'one full E2E run is enough evidence]'
E2EF="" stands D17 '- [BLOCK red-build] the E2E job hung on the head; give 3 full runs'

# ── X1-X9: the refute review's lines stand ──
E2EF="$E2E_REG" stands X1 '- [BLOCK red-build] e2e/a.spec.ts: green on the main run 9, red here.'
E2EF="$E2E_REG" stands X2 "- [BLOCK red-build] e2e/a.spec.ts succeeds on main and fails here; main's latest run 9 failed on b.spec only."
E2EF="$E2E_REG" stands X3 "- [BLOCK red-build] e2e/checkout.spec.ts fails on this head. main's latest E2E run 4411 failed too, but only on login.spec."
E2EF="$E2E_REG" stands X4 "- [BLOCK red-build] Playwright: the head turns e2e/a.spec.ts red. main's last run was red at the setup step, so I cannot compare."
E2EF="$E2E_REG" stands X5 '- [BLOCK red-build] e2e: the head needs 3 full runs because the first run failed 4 specs that pass on main.'
stands X6 '- [BLOCK weakened-test] the PR changes the expect in e2e/cart.spec.ts to toBeTruthy so it can never fail; that spec already fails on main.'
stands X7 '- [BLOCK red-build] e2e/cart.spec.ts already fails on main; the PR appends || true to its run step.'
stands X8 '- [BLOCK core-flow-broken] e2e sign-in spec fails: the sign-in button is dead on this head. The nightly run also fails, on a different spec.'
stands X9 '- [BLOCK red-build] e2e/pay.spec.ts fails on the head; the head adds this spec and it charges the card twice. Also fails on main after rebase.'
stands X10 '- [BLOCK red-build] e2e/pay.spec.ts needs 3 full runs before this merges'
# The same X1 sentence on a spec that IS red on main demotes: the list decides.
demotes X11 '- [BLOCK red-build] e2e/login.spec.ts fails on the head; it also fails on main (nightly run 4411).' 'follow-up'

# ── W1-W9: an evidence ask on top of a weakened test stands (third lead
# review of #8142). Each runs with no --e2e file and with the measured list. ──
W1='- [BLOCK weakened-test] the E2E workflow step now ends in || true; the PR shows one run, need 3 full runs'
W2='- [BLOCK weakened-test] test.fixme on the checkout E2E test; give a per-spec table'
W3='- [BLOCK weakened-test] playwright.config sets retries to 10 so the suite goes green; show 3 full runs'
for ef in "" "$E2E_DEF"; do
  sfx=${ef:+m}
  E2EF="$ef" stands "W1$sfx" "$W1"
  E2EF="$ef" stands "W2$sfx" "$W2"
  E2EF="$ef" stands "W3$sfx" "$W3"
  grep -q 'demoted=0 standing=1 verdict=BLOCK' <<<"$OUT" && ok || bad "W3$sfx summary: $OUT"
  i=0
  for w in "$W1" "$W2" "$W3"; do
    i=$((i+1)); E2EF="$ef" stands "W4.$i$sfx" "${w/weakened-test/red-build}"
  done
  E2EF="$ef" stands "W5$sfx" '- [BLOCK red-build] the E2E job now has continue-on-error: true; give 3 full runs'
  E2EF="$ef" stands "W6$sfx" '- [BLOCK red-build] the PR comments out the checkout E2E test; no per-spec table'
  E2EF="$ef" demotes "W8a$sfx" '- [BLOCK weakened-test] the PR body shows one full E2E run, not 3 full runs' 'one full E2E run is enough evidence]'
  E2EF="$ef" demotes "W8b$sfx" '- [BLOCK red-build] the PR shows one full E2E run, not 3 full runs' 'one full E2E run is enough evidence]'
done
E2EF="$E2E_DEF" stands W7 '- [BLOCK red-build] e2e/a.spec.ts already fails on main; the PR marks it test.fixme'
# W9 mutation: the evidence branch's weakened-test check is what keeps W1.
mv "$R/bin/lib/review-level.sh" "$T/rl.orig"
grep -vF 'grep -qiE "$_RL_E2E_WEAK_RE" <<<"$stripped"' "$T/rl.orig" > "$R/bin/lib/review-level.sh"
cmp -s "$T/rl.orig" "$R/bin/lib/review-level.sh" && bad "W9 the weakened-test check line was not found" || ok
E2EF="" demotes W9 "$W1" 'one full E2E run is enough evidence]'
mv "$T/rl.orig" "$R/bin/lib/review-level.sh"
E2EF="$E2E_DEF"

# ── M1 mutation: the catalog is load-bearing ──
: > "$R/catalog/review-e2e-ratchet.tsv"
stands M1 "$L1"
cp "$SRC/catalog/review-e2e-ratchet.tsv" "$R/catalog/"
# M2: no e2e-soft-class row = the rule is off (fail closed), never a demoter
# with no guard for the other classes.
grep -v '^e2e-soft-class' "$SRC/catalog/review-e2e-ratchet.tsv" > "$R/catalog/review-e2e-ratchet.tsv"
stands M2a "$L1"
stands M2b "- [BLOCK tenant-leak] e2e/tenant.spec.ts already fails on main because the API returns another company's rows"
cp "$SRC/catalog/review-e2e-ratchet.tsv" "$R/catalog/"

echo "review-level-e2e-ratchet.bh-7941: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
