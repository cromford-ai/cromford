#!/bin/bash
# tests/model-literal-alias.bh-2535-test.sh — tests/model-literal-lint.sh also
# catches a bare model ALIAS (haiku/sonnet/opus/fable) in model-argument
# position, with a path exemption file for a line another ticket owns (BH-2535).
#
#   L1  `--model haiku`, `SMOKE_MODEL=sonnet`, `model: 'opus'`, `${M:-fable}`
#       planted in bin/: rc 1, each file:line named;
#   L2  the same line in an allowlisted path: rc 0, reported `exempt:`;
#   L3  an allowlisted path with no hit: rc 0, `stale alias exemption` note;
#   L4  negatives (case label, regex vocabulary, prose, a variable, an alias as a
#       word prefix, a full id, anything under tests/): rc 0, 0 bare-alias lines;
#   L5  the real repo: rc 0, `0 bare-alias line(s) found (` and
#       `0 model-id literal line(s)`. The exempt count is deliberately not
#       pinned: when #2561 removes the exempted line the count drops to 0 and
#       this must stay green (L2 pins exempt counting on a scratch tree);
#   L6  --warn on the L1 tree: rc 0, hits still listed.
# Run from anywhere: tests/model-literal-alias.bh-2535-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/tests/model-literal-lint.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mktree() { # mktree <dir> — a git tree the lint can scan, with no literal in it
  scratch_rm "$1" || return 1; mkdir -p "$1/catalog" "$1/bin" "$1/tests"
  cp "$DIR/catalog/model-prices.json" "$DIR/catalog/model-slugs.json" "$1/catalog/"
  printf '#!/bin/bash\necho clean\n' > "$1/bin/clean.sh"
  git -C "$1" init -q 2>/dev/null
}
commit_tree() { git -C "$1" add -A >/dev/null 2>&1; }

# ── L1 ──────────────────────────────────────────────────────────────────────
T1="$T/tree1"; mktree "$T1"
cat > "$T1/bin/x.sh" <<'SH'
#!/bin/bash
claude -p --model haiku "hi"
SMOKE_MODEL=sonnet
M="${M:-fable}"
SH
printf "const cfg = {\n  model: 'opus',\n};\n" > "$T1/bin/y.js"
commit_tree "$T1"
OUT=$(bash "$LINT" "$T1" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "L1 planted aliases must fail the lint (rc 1), got $RC: $OUT"
for w in bin/x.sh:2: bin/x.sh:3: bin/x.sh:4: bin/y.js:2:; do
  grep -q "$w" <<<"$OUT" && ok || bad "L1 the failure must name $w: $OUT"
done
grep -q '4 bare-alias line(s) found (0 exempt)' <<<"$OUT" && ok \
  || bad "L1 summary must count 4 bare-alias lines: $OUT"

# ── L6 ──────────────────────────────────────────────────────────────────────
OUT=$(bash "$LINT" --warn "$T1" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "L6 --warn must exit 0, got $RC"
grep -q 'bin/x.sh:2:' <<<"$OUT" && ok || bad "L6 --warn must still list the hits: $OUT"

# ── L2 ──────────────────────────────────────────────────────────────────────
T2="$T/tree2"; mktree "$T2"
printf '#!/bin/bash\nclaude -p --model haiku "hi"\n' > "$T2/bin/owned.sh"
printf 'bin/owned.sh\towned by another ticket\n' > "$T2/tests/model-literal-alias-allowlist.txt"
commit_tree "$T2"
OUT=$(bash "$LINT" "$T2" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "L2 an allowlisted hit must not fail the lint, got $RC: $OUT"
grep -q 'exempt: bin/owned.sh:2:' <<<"$OUT" && ok || bad "L2 the hit must be reported exempt: $OUT"
grep -q '0 bare-alias line(s) found (1 exempt)' <<<"$OUT" && ok || bad "L2 summary: $OUT"
# the same allowlist does not cover a different path
printf '#!/bin/bash\nclaude --model=opus\n' > "$T2/bin/other.sh"; commit_tree "$T2"
OUT=$(bash "$LINT" "$T2" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "L2 a hit outside the allowlisted path must still fail, got $RC: $OUT"

# ── L3 ──────────────────────────────────────────────────────────────────────
T3="$T/tree3"; mktree "$T3"
printf 'bin/gone.sh\tremoved upstream\n' > "$T3/tests/model-literal-alias-allowlist.txt"
commit_tree "$T3"
OUT=$(bash "$LINT" "$T3" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "L3 a stale exemption must not fail the lint, got $RC: $OUT"
grep -q 'stale alias exemption bin/gone.sh' <<<"$OUT" && ok || bad "L3 stale note missing: $OUT"

# ── L4 ──────────────────────────────────────────────────────────────────────
T4="$T/tree4"; mktree "$T4"
cat > "$T4/bin/neg.sh" <<'SH'
#!/bin/bash
case "$m" in
  opus|sonnet|haiku|fable) printf 'alias\n' ;;
esac
grep -E "claude-(fable|opus|sonnet|haiku)" x
echo "the Codex-vs-Opus verdict"
claude -p --model "$SMOKE_M" "Reply exactly: OK"
claude -p --model sonnet-routed-xyz "x"
SH
printf 'claude -p --model haiku "hi"\nX_MODEL=sonnet\n' > "$T4/tests/fixture.sh"
commit_tree "$T4"
OUT=$(bash "$LINT" "$T4" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "L4 negatives must not fail the lint, got $RC: $OUT"
grep -q '0 bare-alias line(s) found (0 exempt)' <<<"$OUT" && ok || bad "L4 must count 0 alias lines: $OUT"

# A full id is the vocabulary scan's line, never counted twice by the alias scan.
T4B="$T/tree4b"; mktree "$T4B"
ID=$(jq -r '.per_token|keys[]' "$DIR/catalog/model-prices.json" | grep -m1 -E '^claude-sonnet-')
printf "const c = { model: '%s' };\n" "$ID" > "$T4B/bin/full.js"
commit_tree "$T4B"
OUT=$(bash "$LINT" "$T4B" 2>&1); RC=$?
[ -n "$ID" ] && ok || bad "L4 no claude-sonnet-* id in catalog/model-prices.json to plant"
[ "$RC" = 1 ] && ok || bad "L4 a full id must still fail the vocabulary scan, got $RC: $OUT"
grep -q '0 bare-alias line(s) found (0 exempt)' <<<"$OUT" && ok || bad "L4 a full id must not count as a bare alias: $OUT"

# ── L5 ──────────────────────────────────────────────────────────────────────
OUT=$(bash "$LINT" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "L5 the real repo must pass the lint, got $RC: $OUT"
grep -qE '0 bare-alias line\(s\) found \([0-9]+ exempt\)' <<<"$OUT" && ok || bad "L5 alias summary: $OUT"
grep -q '0 model-id literal line(s)' <<<"$OUT" && ok || bad "L5 vocabulary summary: $OUT"

echo "model-literal-alias.bh-2535: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
