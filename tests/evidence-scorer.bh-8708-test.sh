#!/bin/bash
# tests/evidence-scorer.bh-8708-test.sh — three false REFUTED verdicts of the
# evidence scorer (bin/lib/evidence.sh), BH-8708. A false REFUTED files a
# "Rest of BH-N" remainder ticket (bin/lib/slice-closeout.sh), so each one is
# real work for nobody.
#
#   §1 a directory claim (`tests/x.d/`) has an empty basename. The name regex
#      was `($epath|)`, so any line with a fail marker refuted it.
#   §2 a driver split into a list-files fragment dir (catalog/list-files.tsv)
#      read as "assertions dropped" when they only moved.
#   §3 a drop the plan declares under `## Tests that must change` is
#      INCONCLUSIVE `planned removal: N->M`, never REFUTED.
#
# Every case drives the real `evidence_score` (the entry point both callers,
# bin/lib/rb/review.sh and bin/lib/rb/result.sh, use) against its own scratch
# git repo and build dir.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/evidence-scorer.bh-8708-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }

# shellcheck source=../bin/lib/evidence.sh
. "$DIR/bin/lib/evidence.sh" || { echo "bh-8708: cannot source bin/lib/evidence.sh"; exit 1; }

G="-c user.name=t -c user.email=t@example.com"
# shellcheck disable=SC2086
gc() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" $G commit -q -m "$2" >/dev/null 2>&1; }
asserts() { # asserts <file> <n> — a test file with exactly n assertion lines
  local i
  mkdir -p "$(dirname "$1")"
  { printf '#!/bin/bash\n'; for ((i = 1; i <= $2; i++)); do printf 'ok "case %s"\n' "$i"; done; } > "$1"
}
newrepo() { # newrepo <dir> — an empty main with one commit
  mkdir -p "$1"
  git -C "$1" init -q -b main >/dev/null 2>&1
  printf 'x\n' > "$1/README"
  gc "$1" base
}
branch() { git -C "$1" checkout -q -b feature >/dev/null 2>&1; }
plan1() { # plan1 <build> <test> [extra plan text] — a one-claim plan naming <test>
  mkdir -p "$1"
  printf '## Acceptance tests\n- the split works, proven by `%s`\n%s' "$2" "${3:-}" > "$1/plan.md"
}
score() { SOUT=$(evidence_score "$1" "$1/plan.md" "${2:-}" "${3:-}" 2>&1); SRC=$?; }
j() { jq -r "$2" "$1/evidence.json" 2>/dev/null; }
lt() { printf '# list files\n\n%s\t%s\t%s\n' "$2" "$3" "note" > "$1/catalog/list-files.tsv"; }

# ── §1 a directory claim is matched by its path only ─────────────────────────
R="$T/r1"; newrepo "$R"
B="$T/b1a"; plan1 "$B" tests/x.d/
printf 'route-fragments: not ok 3\n' > "$B/harness-suite.txt"
score "$B" main "$R"
eq "§1 the scorer returns 0" "$SRC" "0"
eq "§1 an unrelated not-ok line does not refute tests/x.d/" "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"
has "§1 and says the test was never located" "$(j "$B" '.claims[0].note')" "never appears"
eq "§1 refuted count is 0" "$(j "$B" '.refuted')" "0"
eq "§1 evidence_locate prints none" "$(evidence_locate "$B" tests/x.d/ | cut -f1)" "none"

B="$T/b1b"; plan1 "$B" tests/x.d/
printf 'tests/x.d/ not ok\n' > "$B/harness-suite.txt"
score "$B" main "$R"
eq "§1 a not-ok line naming tests/x.d/ still refutes it" "$(j "$B" '.claims[0].verdict')" "REFUTED"
eq "§1 the artifact is that line" "$(j "$B" '.claims[0].artifact')" "harness-suite.txt:1"

B="$T/b1c"; plan1 "$B" tests/x.d/
printf 'tests/x.d/01-case.sh not ok\n' > "$B/harness-suite.txt"
score "$B" main "$R"
eq "§1 a file under the dir is a near miss, not the claim" "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"

B="$T/b1d"; plan1 "$B" tests/x.d
printf 'tests/x.d.bak not ok\n' > "$B/harness-suite.txt"
score "$B" main "$R"
eq "§1 tests/x.d without a slash does not match tests/x.d.bak" "$(j "$B" '.claims[0].verdict')" "INCONCLUSIVE"

B="$T/b1e"; plan1 "$B" tests/a-test.sh
printf '✓ a-test.sh\n' > "$B/harness-suite.txt"
score "$B" main "$R"
eq "§1 a file claim still matches by its basename" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

# ── §2 a driver split into its list-files fragment dir is one suite ─────────
split_repo() { # split_repo <dir> <driver n> <frag n|-> <row-input|-> — main state
  newrepo "$1"; mkdir -p "$1/catalog"
  asserts "$1/tests/drv-test.sh" "$2"
  [ "$3" = - ] || asserts "$1/tests/drv-test.d/00-old.sh" "$3"
  [ "$4" = - ] || lt "$1" tests/drv-test.sh "$4"
  gc "$1" main-state
  branch "$1"
}
validate_ok() { printf 'COMMAND: bash %s\nexit 0\n' "$2" > "$1/validate.txt"; }

R="$T/r2a"; split_repo "$R" 20 - tests/drv-test.d/
asserts "$R/tests/drv-test.sh" 11; asserts "$R/tests/drv-test.d/01-moved.sh" 13; gc "$R" split
eq "§2 driver 20->11 plus fragments +13 is not staged" "$(evidence_staged "$R" main tests/drv-test.sh)" "no"
B="$T/b2a"; plan1 "$B" tests/drv-test.sh; validate_ok "$B" tests/drv-test.sh
score "$B" main "$R"
eq "§2 and the claim is CONFIRMED, not REFUTED" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"

R="$T/r2b"; split_repo "$R" 20 - -
asserts "$R/tests/drv-test.sh" 11; asserts "$R/tests/drv-test.d/01-moved.sh" 13; gc "$R" split
eq "§2 with no list-files row the driver drop is staged" "$(evidence_staged "$R" main tests/drv-test.sh)" "staged 20 11"
B="$T/b2b"; plan1 "$B" tests/drv-test.sh; validate_ok "$B" tests/drv-test.sh
score "$B" main "$R"
eq "§2 and the claim is REFUTED" "$(j "$B" '.claims[0].verdict')" "REFUTED"

R="$T/r2c"; split_repo "$R" 20 - tests/drv-test.d/
asserts "$R/tests/drv-test.sh" 11; asserts "$R/tests/drv-test.d/01-moved.sh" 5; gc "$R" split
eq "§2 a split whose total dropped is staged" "$(evidence_staged "$R" main tests/drv-test.sh)" "staged 20 16"

R="$T/r2d"; split_repo "$R" 20 - "rendered tests/drv-test.d/"
asserts "$R/tests/drv-test.sh" 11; asserts "$R/tests/drv-test.d/01-moved.sh" 13; gc "$R" split
eq "§2 a rendered row is not a fragment dir" "$(evidence_staged "$R" main tests/drv-test.sh)" "staged 20 11"
eq "§2 _ev_fragment_dir prints nothing for a rendered row" "$(_ev_fragment_dir "$R" tests/drv-test.sh)" ""
lt "$R" tests/drv-test.sh "ignored tests/drv-test.d/"
eq "§2 _ev_fragment_dir prints nothing for an ignored row" "$(_ev_fragment_dir "$R" tests/drv-test.sh)" ""
lt "$R" 'tests/\[\[x\]\]-test.sh' tests/x.d/
eq "§2 column 1 escapes are removed before the literal compare" "$(_ev_fragment_dir "$R" 'tests/[[x]]-test.sh')" "tests/x.d/"
eq "§2 column 1 is a literal, not a glob" "$(_ev_fragment_dir "$R" 'tests/x-test.sh')" ""

R="$T/r2e"; split_repo "$R" 5 3 tests/drv-test.d/
asserts "$R/tests/drv-test.sh" 2; asserts "$R/tests/drv-test.d/00-old.sh" 6; gc "$R" split
eq "§2 driver 5->2 plus dir 3->6 is not staged" "$(evidence_staged "$R" main tests/drv-test.sh)" "no"

R="$T/r2f"; split_repo "$R" 20 - -
scratch_rm "$R/catalog"
asserts "$R/tests/drv-test.sh" 11; asserts "$R/tests/drv-test.d/01-moved.sh" 13; gc "$R" split
eq "§2 list-files.tsv absent gives the driver-only count" "$(evidence_staged "$R" main tests/drv-test.sh)" "staged 20 11"

R="$T/r2g"; split_repo "$R" 1 6 -
asserts "$R/tests/drv-test.d/00-old.sh" 3; asserts "$R/tests/drv-test.d/01-new.sh" 3; gc "$R" spread
eq "§2 a directory claim with the same total over more files is not staged" \
  "$(evidence_staged "$R" main tests/drv-test.d/)" "no"
B="$T/b2g"; plan1 "$B" tests/drv-test.d/
printf 'COMMAND: bash tests/drv-test.d/\nexit 0\n' > "$B/validate.txt"
score "$B" main "$R"
eq "§2 and the directory claim is CONFIRMED" "$(j "$B" '.claims[0].verdict')" "CONFIRMED"
asserts "$R/tests/drv-test.d/00-old.sh" 2; asserts "$R/tests/drv-test.d/01-new.sh" 2; gc "$R" drop
eq "§2 a directory whose total dropped is staged" "$(evidence_staged "$R" main tests/drv-test.d/)" "staged 6 4"

# ── §3 a drop the plan declares is INCONCLUSIVE, not REFUTED ────────────────
drop_repo() { # drop_repo <dir> — tests/feat-test.sh 88 -> 71 on the branch
  newrepo "$1"; asserts "$1/tests/feat-test.sh" 88; gc "$1" main-state
  branch "$1"; asserts "$1/tests/feat-test.sh" 71; gc "$1" drop
}
R="$T/r3"; drop_repo "$R"
planned() { # planned <build> <tail text> — case, verdict, then note check
  plan1 "$1" tests/feat-test.sh "$2"; validate_ok "$1" tests/feat-test.sh
  score "$1" main "$R"
}

planned "$T/b3a" $'\n## Tests that must change\n\n- `tests/feat-test.sh`: 17 cases moved to the new suite.\n'
eq "§3 a planned drop is INCONCLUSIVE" "$(j "$T/b3a" '.claims[0].verdict')" "INCONCLUSIVE"
eq "§3 note planned removal: 88->71" "$(j "$T/b3a" '.claims[0].note')" "planned removal: 88->71"
eq "§3 artifact is the test file" "$(j "$T/b3a" '.claims[0].artifact')" "tests/feat-test.sh"
eq "§3 refuted == 0 (no remainder ticket)" "$(j "$T/b3a" '.refuted')" "0"
eq "§3 the CLAIM line shows in stdout" \
  "$(grep -c '^CLAIM 1: INCONCLUSIVE :: tests/feat-test.sh :: planned removal: 88->71$' <<<"$SOUT")" "1"

planned "$T/b3b" $'\n## Plan\n\n### Tests that must change\n\n- tests/feat-test.sh — moved\n'
eq "§3 a level-3 section counts" "$(j "$T/b3b" '.claims[0].note')" "planned removal: 88->71"

plan1 "$T/b3c" tests/feat-test.sh $'\n## Tests that must change\n\n- `tests/feat-test.sh`: moved\n'
sed -i 's/$/\r/' "$T/b3c/plan.md"; validate_ok "$T/b3c" tests/feat-test.sh
score "$T/b3c" main "$R"
eq "§3 a CRLF plan counts" "$(j "$T/b3c" '.claims[0].note')" "planned removal: 88->71"

planned "$T/b3d" ''
eq "§3 no section stays REFUTED" "$(j "$T/b3d" '.claims[0].verdict')" "REFUTED"
has "§3 with the staged note" "$(j "$T/b3d" '.claims[0].note')" "staged: assertions 88->71"

planned "$T/b3e" $'\n## Files to touch\n\n- `tests/feat-test.sh`\n\n## Tests that must change\n\nNone\n'
eq "§3 Files to touch only, section None, stays REFUTED" "$(j "$T/b3e" '.claims[0].verdict')" "REFUTED"

planned "$T/b3f" $'\n## Tests that must change\n\n```\ntests/feat-test.sh\n```\n'
eq "§3 a path only inside a fenced block stays REFUTED" "$(j "$T/b3f" '.claims[0].verdict')" "REFUTED"

planned "$T/b3g" $'\n## Tests that must change\n\n- `tests/feat-test.sh.bak`\n'
eq "§3 a .bak near miss stays REFUTED" "$(j "$T/b3g" '.claims[0].verdict')" "REFUTED"

planned "$T/b3h" $'\n## Tests that must change\n\n- `tests/feat-test.sh`\n\n## Size\n\n- tests/other-test.sh\n'
eq "§3 the section ends at the next heading" "$(j "$T/b3h" '.claims[0].verdict')" "INCONCLUSIVE"

planned "$T/b3i" $'\n## Tests that must change\n\n- `tests/feat-test.sh`\n'
printf 'tests/feat-test.sh not ok 4\n' > "$T/b3i/harness-suite.txt"
score "$T/b3i" main "$R"
eq "§3 a fail line beats a planned drop" "$(j "$T/b3i" '.claims[0].verdict')" "REFUTED"

echo "evidence-scorer.bh-8708: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
