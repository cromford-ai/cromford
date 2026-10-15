#!/bin/bash
# tests/test-tiers-test.sh — bin/test-tiers.sh and catalog/test-tiers.tsv: WHICH
# TIER A SUITE RUNS IN (2026-09-28, the nightly tier).
#
# The failure to fear is a suite that silently stops running: tiered out of the
# batch by a typo, a missing file or a guard whose paths match nothing. So every
# unknown is asserted to land in the BATCH, every unknown about a guard to RUN
# it, and the shipped file is checked for the same things a reviewer would ask.
#
#   T1  a nightly row leaves the batch and is the nightly run
#   T2  a suite with no row is batch, never nightly
#   T3  no tier file at all: everything is batch, nothing is nightly
#   T4  an unknown tier, or a guard with no paths, is batch
#   T5  a guard runs in the batch only when the diff touches what it guards
#       (dir/, exact file, glob), and ALWAYS when the guard itself, the tier
#       file or bin/test-tiers.sh changes, or the diff is unknown / empty
#   T6  `check` refuses a bad row and passes the shipped file
#   T8  a suite test-impact runs on every diff (`always`) is never nightly
#   T9  a join/write that loses rows hands back the whole list (batch) or
#       fails the plan (nightly)
#   T7  the shipped file: the three guards are guards, every guard path names
#       something in this tree, and the ratchet family owned elsewhere is not
#       in the nightly tier
# Run from anywhere: tests/test-tiers-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TT="$DIR/bin/test-tiers.sh"
SHIPPED="$DIR/catalog/test-tiers.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

TAB=$'\t'
cat > "$T/tiers.tsv" <<EOF
# a comment, then rows
tests/slow-test.sh${TAB}nightly${TAB}120${TAB}-${TAB}slow, never failed
tests/fast-test.sh${TAB}batch${TAB}1${TAB}-${TAB}said out loud
tests/leak-guard-test.sh${TAB}guard${TAB}90${TAB}bin/share/ vercel.conf prompts/product-*${TAB}leak guard
tests/odd-test.sh${TAB}weekly${TAB}30${TAB}-${TAB}a tier nobody knows
tests/bare-guard-test.sh${TAB}guard${TAB}30${TAB}-${TAB}a guard with no paths
EOF
printf '%s\n' tests/fast-test.sh tests/slow-test.sh tests/new-test.sh tests/leak-guard-test.sh \
  tests/odd-test.sh tests/bare-guard-test.sh > "$T/list"

tiers() { # tiers <mode> [args...] — sets OUT (the list) and ERR (the reason channel)
  local mode="$1"; shift
  OUT=$(bash "$TT" "$mode" "$@" < "$T/list" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
in_out()  { grep -qxF "$1" <<<"$OUT"; }
changed() { printf '%s\n' "$@" > "$T/changed"; }

# ── T1/T2. nightly out of the batch, into the nightly; a row-less suite stays.
changed docs/README.md
tiers batch --tiers "$T/tiers.tsv" --changed "$T/changed"
[ "$RC" = 0 ] && ok || bad "T1: batch must exit 0 (rc=$RC): $ERR"
in_out tests/slow-test.sh && bad "T1: a nightly suite must leave the batch: $OUT" || ok
in_out tests/fast-test.sh && ok || bad "T1: a batch row must stay in the batch: $OUT"
in_out tests/new-test.sh && ok || bad "T2: a suite with no row must be batch: $OUT"
has "left to the nightly run" "$ERR" && ok || bad "T1: the reason channel must say what left the batch: $ERR"
tiers nightly --tiers "$T/tiers.tsv"
in_out tests/slow-test.sh && ok || bad "T1: the nightly run must carry the nightly suite: $OUT"
in_out tests/leak-guard-test.sh && ok || bad "T1: the nightly run must carry the guard too: $OUT"
in_out tests/new-test.sh && bad "T2: a suite with no row must never be nightly: $OUT" || ok
in_out tests/fast-test.sh && bad "T1: a batch suite is not the nightly run: $OUT" || ok
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 2 ] && ok || bad "T1: nightly = exactly the nightly and guard rows, got: $OUT"

# ── T3. no tier file: everything is batch.
tiers batch --tiers "$T/no-such.tsv" --changed "$T/changed"
{ [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" = 6 ]; } && ok \
  || bad "T3: a missing tier file must leave every suite in the batch (rc=$RC): $OUT"
has "no tier file" "$ERR" && ok || bad "T3: a missing tier file must be said: $ERR"
tiers nightly --tiers "$T/no-such.tsv"
[ -z "$OUT" ] && ok || bad "T3: a missing tier file moves nothing to the nightly run: $OUT"

# ── T4. an unknown tier and a guard with no paths are batch.
tiers batch --tiers "$T/tiers.tsv" --changed "$T/changed"
in_out tests/odd-test.sh && ok || bad "T4: an unknown tier must be batch: $OUT"
has "unknown tier 'weekly'" "$ERR" && ok || bad "T4: an unknown tier must be named: $ERR"
in_out tests/bare-guard-test.sh && ok || bad "T4: a guard with no paths must be batch: $OUT"

# ── T5. guards: path-gated in the batch, fail-safe everywhere else.
guard_runs() { tiers batch --tiers "$T/tiers.tsv" "$@"; in_out tests/leak-guard-test.sh; }
changed docs/README.md bin/other.sh
guard_runs --changed "$T/changed" && bad "T5: a diff that touches nothing the guard guards must skip it: $ERR" || ok
has "guard tests/leak-guard-test.sh skipped" "$ERR" && ok || bad "T5: a skipped guard must be said: $ERR"
changed docs/README.md bin/share/sanitize.py
guard_runs --changed "$T/changed" && ok || bad "T5: a change under a guarded dir/ must run the guard: $ERR"
has "bin/share/sanitize.py changed" "$ERR" && ok || bad "T5: the guard's reason must name the path: $ERR"
changed vercel.conf
guard_runs --changed "$T/changed" && ok || bad "T5: a change to a guarded file must run the guard"
changed prompts/product-acme.md
guard_runs --changed "$T/changed" && ok || bad "T5: a change matching a guarded glob must run the guard"
changed vercel.conf.bak bin/sharemore.sh
guard_runs --changed "$T/changed" && bad "T5: prefixes that are not the guarded file/dir must not run it: $ERR" || ok
changed tests/leak-guard-test.sh
guard_runs --changed "$T/changed" && ok || bad "T5: a change to the guard ITSELF must run it"
changed catalog/test-tiers.tsv
guard_runs --changed "$T/changed" && ok || bad "T5: a change to the tier file (its paths) must run every guard"
changed bin/test-tiers.sh
guard_runs --changed "$T/changed" && ok || bad "T5: a change to the tier gate must run every guard"
guard_runs && ok || bad "T5: no --changed list means the diff is unknown — the guard runs"
: > "$T/changed"
guard_runs --changed "$T/changed" && ok || bad "T5: an empty diff is an unknown diff — the guard runs"
guard_runs --changed "$T/no-such-changed" && ok || bad "T5: an unreadable diff is an unknown diff — the guard runs"
changed docs/README.md
tiers nightly --tiers "$T/tiers.tsv" --changed "$T/changed"
in_out tests/leak-guard-test.sh && ok || bad "T5: the nightly run always carries every guard"

# ── T6. check.
bash "$TT" check --tiers "$SHIPPED" --root "$DIR" > "$T/check" 2>&1 && ok \
  || bad "T6: the shipped catalog/test-tiers.tsv must pass check: $(cat "$T/check")"
printf 'tests/test-tiers-test.sh\tnightly\tslow\t-\twhy\ntests/test-tiers-test.sh\tguard\t3\t-\t\ntests/nope-test.sh\tbatch\t1\t-\twhy\n' > "$T/badtiers.tsv"
OUTC=$(bash "$TT" check --tiers "$T/badtiers.tsv" --root "$DIR" 2>&1); RCC=$?
[ "$RCC" = 1 ] && ok || bad "T6: a bad file must fail check (rc=$RCC): $OUTC"
for want in "is not whole seconds" "a guard needs the paths" "no reason" "no such suite" "listed twice"; do
  has "$want" "$OUTC" && ok || bad "T6: check must say '$want': $OUTC"
done

# ── T7. the shipped file.
row_tier() { awk -F'\t' -v s="$1" '$1 == s { print $2 }' "$SHIPPED"; }
for g in tests/share-publish-clean.bh-795-test.sh \
         tests/share-mirror-clean-test.sh tests/registry-no-commit-test.sh; do
  [ "$(row_tier "$g")" = guard ] && ok || bad "T7: $g is a safety/leak guard, never plain nightly (tier '$(row_tier "$g")')"
done
# Every guard path must name something in this tree: a typo'd path guards
# nothing, and the guard would quietly stop running in every batch.
while IFS=$'\t' read -r s t _ p _; do
  [ "$t" = guard ] || continue
  for spec in $p; do
    [ "$spec" = '*' ] && continue
    { [ -e "$DIR/$spec" ] || compgen -G "$DIR/$spec" >/dev/null; } && ok \
      || bad "T7: $s guards '$spec', which names nothing in this tree"
  done
done < <(grep -Ev '^[[:space:]]*(#|$)' "$SHIPPED")
# The ratchet family another change is rewriting stays in the batch.
OWNED=$(awk -F'\t' '$2 == "nightly" { print $1 }' "$SHIPPED" \
  | grep -E '^tests/(alert-|switch-|lane-switch|hub-cron-gated|gh-graphql-reads-lint|rt-split-layout|prompt-ceiling|pool-cap|gh-rest-lib|test-determinism-lint\.bh-1901)' || true)
[ -z "$OWNED" ] && ok || bad "T7: ratchet-family suites must not be tiered here: $OWNED"
NN=$(awk -F'\t' '$2 == "nightly"' "$SHIPPED" | grep -c .)
# 99 after the #3262 review moved 20 always/ratchet/safety suites back; a
# collapse to a handful means the file was truncated, not curated.
[ "$NN" -ge 80 ] && ok || bad "T7: the nightly tier should carry the ~100 slow never-failed suites, has $NN"

# ── T8. a suite the test-impact map runs on EVERY diff is never nightly. Such a
# suite reads the whole tree (a ratchet, a registry audit, the map's own
# tests), so no single PR "reaches" it and no builder gate would run it early:
# tiered nightly, it would reach main untested every time.
ALWAYS=$(bash "$DIR/bin/test-impact.sh" always 2>/dev/null)
[ -n "$ALWAYS" ] && ok || bad "T8: bin/test-impact.sh always printed nothing — the guardrail below would check nothing"
# BH-6838 (the operator, 2026-10-15): the test-hygiene suites move to the nightly run
# on purpose. A row whose reason starts `BH-6838: test hygiene` is the one
# exception, and the exception set is pinned to exactly the day-boundary guard
# (the fixture-hygiene suite stays in the batch: its rules are leak checks).
BOTH=$(awk -F'\t' '$2 == "nightly" && $5 !~ /^BH-6838: test hygiene/ { print $1 }' "$SHIPPED" | grep -xF -f <(printf '%s\n' "$ALWAYS") || true)
[ -z "$BOTH" ] && ok || bad "T8: always-selected suites must stay in the batch, not nightly: $(tr '\n' ' ' <<<"$BOTH")"
HYG=$(awk -F'\t' '$2 == "nightly" && $5 ~ /^BH-6838: test hygiene/ { print $1 }' "$SHIPPED" | LC_ALL=C sort | paste -sd' ' -)
[ "$HYG" = "tests/day-boundary-guard.bh-6052-test.sh" ] && ok \
  || bad "T8: the BH-6838 hygiene exception must name exactly the day-boundary guard: '$HYG'"

# ── T9. a broken join or write never shrinks the batch: the output must be the
# input minus the nightly rows it dropped, or the WHOLE list comes back.
cat > "$T/awk-truncates" <<'EOF'
#!/bin/bash
awk "$@" | head -2
EOF
cat > "$T/awk-fails" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$T/awk-truncates" "$T/awk-fails"
changed docs/README.md
for fake in awk-truncates awk-fails; do
  OUT=$(TEST_TIERS_AWK="$T/$fake" bash "$TT" batch --tiers "$T/tiers.tsv" --changed "$T/changed" < "$T/list" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
  { [ "$RC" = 0 ] && [ "$(grep -c . <<<"$OUT")" = 6 ]; } && ok \
    || bad "T9 ($fake): a broken join must hand back the whole list (rc=$RC, $(grep -c . <<<"$OUT") of 6): $OUT"
  has "FAIL-SAFE" "$ERR" && ok || bad "T9 ($fake): the fail-safe must be said: $ERR"
  OUT=$(TEST_TIERS_AWK="$T/$fake" bash "$TT" nightly --tiers "$T/tiers.tsv" < "$T/list" 2>"$T/err"); RC=$?
  [ "$RC" = 2 ] && ok || bad "T9 ($fake): a broken nightly plan must be rc 2, never a partial night (rc=$RC): $OUT"
done

echo "test-tiers-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
