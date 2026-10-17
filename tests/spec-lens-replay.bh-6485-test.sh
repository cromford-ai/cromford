#!/bin/bash
# tests/spec-lens-replay.bh-6485-test.sh — BH-6485: bin/spec-lens-replay.sh
# replays the spec-trace review lens over merged PRs, checks its ledger before
# every paid call, and counts the rows, the BLOCKs and the cut exemptions.
#
# Driven: bin/spec-lens-replay.sh as installed by scratch_install_closure, with
# a stub bin/agent-call.sh beside it, against a fixture clone with three merges.
#   Y1 without --run: zero agent calls, the prompt sizes are printed
#   Y2 --run: one call per mapped row up to --max, a ledger row each
#   Y3 a re-run: zero new calls (the ledger hit); agent rc 74: no row, skipped
#   Y4 the summary counts missing/contradicts/BLOCK/cut-exempt
#   Y5 an output with no rows: ledger `empty`, terminal, never re-called
#   Y6 the prompt carries the spec section from <merge-sha>^1 and the diff
#   Y7 the shipped manifest catalog/fixtures/spec-lens-replay/ reads, no call
# No network, no model call. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/spec-lens-replay.bh-6485-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
unset PROJECT KEY BUILD
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export VERDICT_WINDOW_LINES=12 REVIEW_MODEL=stub-model-fixture
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

mkdir -p "$T/h"
scratch_install_closure bin/spec-lens-replay.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
# The stub: logs the call and its prompt, answers per PR from $STUBS/<pr>.
cat > "$T/h/bin/agent-call.sh" <<'EOS'
#!/bin/bash
pr=$(basename "$5" .md)
printf '%s %s %s %s\n' "$1" "$2" "$3" "$pr" >> "$CALLS"
printf '%s' "$6" > "$PROMPTS/$pr.txt"
printf '%s %s\n' "$pr" "${AGENT_CALL_NO_TOOLS:-unset}" >> "$CALLS.notools"
rc=$(cat "$STUBS/$pr.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] && cp "$STUBS/$pr" "$5"
exit "$rc"
EOS
chmod +x "$T/h/bin/agent-call.sh"
mkdir -p "$T/stubs" "$T/prompts"
export CALLS="$T/calls.log" STUBS="$T/stubs" PROMPTS="$T/prompts"

C="$T/clone"; git init -q "$C"; mkdir -p "$C/docs" "$C/src"
printf '# PRD fixture\n\n## J01 First run\n\n- ACC-1 welcome card\n- ACC-2 tour button\n\n## J02 Settings\n\n- SET-4 the plan list\n' > "$C/docs/prd.md"
git -C "$C" add -A && git -C "$C" commit -qm base
m() { printf '%s\n' "$2" > "$C/src/$1.ts"; git -C "$C" add -A; git -C "$C" commit -qm "$1"; git -C "$C" rev-parse HEAD; }
S1=$(m p101 'export const welcome = 1'); S2=$(m p102 'export const tour = 1'); S3=$(m p103 'export const plans = 1'); S4=$(m p104 'x')
printf 'pr\tmerge-sha\tspec-values\tcut-values\tnote\n' > "$T/manifest.tsv"
printf '101\t%s\tdocs/prd.md#J01\t-\tfixture welcome\n' "$S1" >> "$T/manifest.tsv"
printf '102\t%s\tdocs/prd.md#J01\tACC-2\tfixture tour cut\n' "$S2" >> "$T/manifest.tsv"
printf '103\t%s\tdocs/prd.md#J02\t-\tfixture plans\n' "$S3" >> "$T/manifest.tsv"
printf '104\t%s\t-\t-\tfixture unmapped\n' "$S4" >> "$T/manifest.tsv"
printf 'SPEC-TRACE: J01 | ACC-1 | delivered | src/p101.ts:1\nSPEC-TRACE: J01 | ACC-2 | missing | -\nVERDICT: APPROVE\n' > "$T/stubs/101"
printf 'SPEC-TRACE: J01 | ACC-1 | delivered | src/p102.ts:1\nSPEC-TRACE: J01 | ACC-2 | missing | -\nVERDICT: APPROVE\n' > "$T/stubs/102"
printf 'The diff looks fine.\nVERDICT: APPROVE\n' > "$T/stubs/103"
RP="$T/h/bin/spec-lens-replay.sh"
calls() { grep -c . "$CALLS" 2>/dev/null || true; }

# Y1
: > "$CALLS"
OUT=$("$RP" "$T/manifest.tsv" "$C" "$T/out" 2>&1)
[ "$(calls)" = 0 ] && ok || bad "Y1 no --run must make zero calls, got $(calls)"
[ "$(grep -c '^would call #' <<<"$OUT")" = 3 ] && grep -q 'rows=4 unmapped=1 ledger-hits=0 calls=0' <<<"$OUT" && ok || bad "Y1 three prompts sized, one unmapped: $OUT"

# Y2 (and Y3's rc 74 on 103)
echo 74 > "$T/stubs/103.rc"
OUT=$("$RP" "$T/manifest.tsv" "$C" "$T/out" --run --max 2 2>&1)
[ "$(calls)" = 2 ] && ok || bad "Y2 --max 2 makes two calls, got $(calls): $(cat "$CALLS")"
grep -q '^review project-6-os stub-model-fixture 101$' "$CALLS" && ok || bad "Y2 the call shape and the resolved model: $(cat "$CALLS")"
[ "$(grep -vc '^#' "$T/out/ledger.tsv")" = 2 ] && ok || bad "Y2 a ledger row per call: $(cat "$T/out/ledger.tsv")"
: > "$CALLS"
OUT=$("$RP" "$T/manifest.tsv" "$C" "$T/out" --run --max 10 2>&1)
[ "$(calls)" = 1 ] && grep -q '103$' "$CALLS" && ok || bad "Y3 a re-run calls only the row with no ledger row, got: $(cat "$CALLS")"
grep -q 'ledger-hits=2' <<<"$OUT" && grep -q 'skipped: #103(rc 74)' <<<"$OUT" && ok || bad "Y3 two ledger hits and 103 skipped: $OUT"
grep -q '	103	' "$T/out/ledger.tsv" && bad "Y3 rc 74 writes no ledger row" || ok

# Y5
rm -f "$T/stubs/103.rc"; : > "$CALLS"
"$RP" "$T/manifest.tsv" "$C" "$T/out" --run >/dev/null 2>&1
[ "$(awk -F'\t' '$2 == 103 {print $3}' "$T/out/ledger.tsv")" = empty ] && ok || bad "Y5 an output with no rows is empty: $(cat "$T/out/ledger.tsv")"
: > "$CALLS"
"$RP" "$T/manifest.tsv" "$C" "$T/out" --run >/dev/null 2>&1
[ "$(calls)" = 0 ] && ok || bad "Y5 an empty row is terminal: $(cat "$CALLS")"

# Y8 (BH-7276): the prompt carries a merged PR's diff, which is untrusted
# text, so every review call runs with AGENT_CALL_NO_TOOLS=1.
[ -s "$CALLS.notools" ] && ! grep -qv ' 1$' "$CALLS.notools" && ok \
  || bad "Y8 every call runs with AGENT_CALL_NO_TOOLS=1: $(cat "$CALLS.notools" 2>/dev/null)"

# Y4
SUM=$("$RP" summary "$T/out")
grep -qx -- '- replayed: 3' <<<"$SUM" && grep -qx -- '- empty: 1' <<<"$SUM" && ok || bad "Y4 replayed/empty: $SUM"
grep -qx -- '- rows: delivered=2 partial=0 missing=2 contradicts=0 cut=0' <<<"$SUM" && ok || bad "Y4 rows by status: $SUM"
grep -qx -- '- blocked: 2' <<<"$SUM" && ok || bad "Y4 101 (ACC-2 missing) and 103 (J02 not traced) block, 102 is cut: $SUM"
grep -qx -- '- cut-exempt: 1 (in 1 PRs)' <<<"$SUM" && ok || bad "Y4 the cut exemption fires once: $SUM"

# Y6
grep -q '^- ACC-2 tour button$' "$T/prompts/101.txt" && grep -q '^+export const welcome = 1$' "$T/prompts/101.txt" && ok \
  || bad "Y6 the prompt carries the J01 section and the diff: $(head -c 600 "$T/prompts/101.txt")"
grep -q 'Cut tokens (the ticket names these as cut): ACC-2' "$T/prompts/102.txt" && ok || bad "Y6 the cut tokens reach the prompt"

# Y7: the shipped manifest is in the format the script reads (header and
# comments skipped), and a dry run of it spends nothing.
SHIPPED="$(cd "$(dirname "$0")/.." && pwd)/catalog/fixtures/spec-lens-replay/project-6-os-2026-10-12.tsv"
: > "$CALLS"
OUT=$("$RP" "$SHIPPED" "$C" "$T/out-shipped" 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q '^spec-lens-replay: rows=[0-9]* unmapped=[0-9]* ledger-hits=0 calls=0 ' <<<"$OUT" && [ "$(calls)" = 0 ] && ok \
  || bad "Y7 the shipped manifest reads with no call (rc $RC): $OUT"
awk -F'\t' '!/^#/ && $1 != "pr" && NF > 0 && NF != 5 {bad = 1} END {exit bad}' "$SHIPPED" && ok || bad "Y7 every manifest row has 5 columns"

echo "spec-lens-replay.bh-6485: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
