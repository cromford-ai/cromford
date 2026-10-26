#!/bin/bash
# tests/core-overrides-split.bh-8447-test.sh — the first 16 tables of
# CREATED_TABLE_OVERRIDES live in core.d/0000-<table>.js, one table per file,
# so two builds that each edit a different moved table merge with no conflict.
#   E1  the 16 fragments and the pre-split fixture exist
#   M1  branch X edits the verdicts CREATE TABLE in its own fragment, branch Y
#       appends a statement to the wakes fragment: both merge with no conflict,
#       no shared file, and the node loader shows both edits
#   N1  the node suite worker/jobs/test/core-overrides.bh-8447.test.js passes
# Fixture repos only, fixed commit dates, no network. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/core-overrides-split.bh-8447-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node is not on PATH"; exit 1; }

# ── E1 the fragments and the fixture exist ────────────────────────────────────
FILES=(
  "$DIR/worker/jobs/src/lib/core.d/0000-merge-trains.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-verdict-history.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-wakes.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-wake-claims.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-pr-state-events.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-pr-attempts.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-model-routes.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-routing-changes.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-cost-cap-changes.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-config-changes.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-harness-flags.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-model-route-changes.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-verdicts.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-lead-protected-paths.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-setting-sigs.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-lead-review-requests.js"
  "$DIR/worker/jobs/test/fixtures/core-overrides-pre-split.bh-8447.json"
)
for f in "${FILES[@]}"; do
  [ -f "$f" ] && ok || bad "E1 missing ${f#"$DIR"/}"
done
if [ "$FAIL" -ne 0 ]; then echo "core-overrides-split.bh-8447: $PASS passed, $FAIL failed"; exit 1; fi

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# ── M1 two moved tables, two branches, no conflict ────────────────────────────
R="$T/repo"; J="$R/worker/jobs"
mkdir -p "$J/src/lib"
cp "$DIR/worker/jobs/src/lib/core-registries.js" "$DIR/worker/jobs/src/lib/core-registries.node.js" "$J/src/lib/"
cp -R "$DIR/worker/jobs/src/lib/core.d" "$J/src/lib/core.d"
cp "$DIR/worker/jobs/package.json" "$J/package.json"
git init -q -b main "$R"; git -C "$R" add -A; git -C "$R" commit -qm base

VFRAG="$J/src/lib/core.d/0000-verdicts.js"; WFRAG="$J/src/lib/core.d/0000-wakes.js"
git -C "$R" checkout -q -b x main
# In place: the first column line of the verdicts CREATE TABLE gains x_col.
awk '!done && /CREATE TABLE IF NOT EXISTS verdicts \(/ { print; print "       x_col TEXT,"; done=1; next } { print }' "$VFRAG" >"$T/v.js" && mv "$T/v.js" "$VFRAG"
git -C "$R" commit -qam "x: verdicts x_col"
git -C "$R" checkout -q -b y main
# Append: one more wakes statement after the last one.
awk '/^  \],$/ && !done { print "    \"CREATE INDEX IF NOT EXISTS idx_wakes_y ON wakes(at)\","; done=1 } { print }' "$WFRAG" >"$T/w.js" && mv "$T/w.js" "$WFRAG"
git -C "$R" commit -qam "y: wakes idx"
git -C "$R" checkout -q main

X=$(git -C "$R" diff --name-only main x); Y=$(git -C "$R" diff --name-only main y)
[ "$X" = "worker/jobs/src/lib/core.d/0000-verdicts.js" ] && ok || bad "M1 branch x must change only 0000-verdicts.js: [$X]"
[ "$Y" = "worker/jobs/src/lib/core.d/0000-wakes.js" ] && ok || bad "M1 branch y must change only 0000-wakes.js: [$Y]"
git -C "$R" merge -q --no-edit x >"$T/mx.out" 2>&1 && ok || bad "M1 merge x: $(cat "$T/mx.out")"
git -C "$R" merge -q --no-edit y >"$T/my.out" 2>&1 && ok || bad "M1 merge y conflicted: $(cat "$T/my.out")"
[ -z "$(git -C "$R" diff --name-only --diff-filter=U)" ] && ok || bad "M1 unmerged paths after the merge"
( cd "$J" && node --input-type=module -e '
  const m = await import("./src/lib/core-registries.node.js");
  const o = m.CREATED_TABLE_OVERRIDES;
  if (!/x_col TEXT/.test(o.verdicts[0])) { console.log("verdicts[0] has no x_col"); process.exit(1); }
  if (o.wakes[o.wakes.length - 1] !== "CREATE INDEX IF NOT EXISTS idx_wakes_y ON wakes(at)") { console.log("wakes ends " + o.wakes[o.wakes.length - 1]); process.exit(1); }' ) >"$T/m1.out" 2>&1 \
  && ok || bad "M1 merged composition: $(cat "$T/m1.out")"

# ── N1 the node suite ─────────────────────────────────────────────────────────
# node --test needs no install here: the worker's one dependency is lazy (package.json).
( cd "$DIR/worker/jobs" && node --test test/core-overrides.bh-8447.test.js ) >"$T/n1.out" 2>&1 \
  && ok || bad "N1 node --test test/core-overrides.bh-8447.test.js: $(grep -E '^not ok|error:' "$T/n1.out" | head -10)"

echo "core-overrides-split.bh-8447: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
