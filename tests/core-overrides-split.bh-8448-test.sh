#!/bin/bash
# tests/core-overrides-split.bh-8448-test.sh — the last 19 tables of
# CREATED_TABLE_OVERRIDES live in core.d/0000-<table>.js, the core.js literal is
# gone, and catalog/list-files.tsv lists core.js, so bin/list-file-lint.sh
# refuses a PR that grows core.js without a new file under worker/jobs/src/lib/.
#   E1  the 19 fragments and the node suite exist
#   L1  core.js +3 with no new lib file is red, and so is core.js +10/-2 with
#       only a new test file; the output names core.js and the fix
#   L2  core.js +3 plus a new core.d/bh-9001-x.js is green; core.js +3 plus a
#       new src/lib/foo.js is green
#   L3  an in-place edit of core.js (+1/-1) is green; a shrink is green
#   L4  growth of core-registries.js (unlisted) is green; an edit of a
#       core.d/0000-* baseline is green
#   M1  branch x edits the risk_tiers CREATE TABLE, branch y appends a statement
#       to dequeue_events: both merge with no conflict, and the node loader
#       shows both edits
#   N1  the node suites core-overrides.bh-8448 and bh-8447 pass
# Fixture repos only, fixed commit dates, no network. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/core-overrides-split.bh-8448-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node is not on PATH"; exit 1; }

# ── E1 the fragments exist ────────────────────────────────────────────────────
FILES=(
  "$DIR/worker/jobs/src/lib/core.d/0000-risk-tiers.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-jev-risk-calls.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-queue-risk-scores.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-route-rules.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-route-rule-changes.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-route-shadow.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-triage-state.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-alert-family-scripts.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-dequeue-events.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-dequeue-actions.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-projects.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-pool-spawns.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-pool-terminals.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-pool-holds.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-conflict-hotspots.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-conflict-hotspot-runs.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-participant-machines.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-suite-results.js"
  "$DIR/worker/jobs/src/lib/core.d/0000-suite-reuse-runs.js"
  "$DIR/worker/jobs/test/core-overrides.bh-8448.test.js"
)
for f in "${FILES[@]}"; do
  [ -f "$f" ] && ok || bad "E1 missing ${f#"$DIR"/}"
done

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
LINT="$DIR/bin/list-file-lint.sh"
CAT="$DIR/catalog/list-files.tsv"

# ── L1-L4 the catalog row, against the real catalog ───────────────────────────
L="$T/lint"; LJ="$L/worker/jobs/src/lib"
mkdir -p "$LJ/core.d" "$L/worker/jobs/test"
printf 'export const A = 1;\nexport const B = 2;\nexport const C = 3;\nexport const D = 4;\n' >"$LJ/core.js"
printf 'export const R = 1;\n' >"$LJ/core-registries.js"
printf 'export const CREATED_TABLE_OVERRIDES = {\n  risk_tiers: [\n    "x",\n  ],\n};\n' >"$LJ/core.d/0000-risk-tiers.js"
git init -q -b base "$L"; git -C "$L" add -A; git -C "$L" commit -qm base

# case <name> <setup> — run <setup> on a new branch off base, commit, lint.
# Sets RC and OUT.
case_run() {
  local name=$1 setup=$2
  git -C "$L" checkout -q -f base
  git -C "$L" checkout -q -b "$name"
  ( cd "$L" && eval "$setup" )
  git -C "$L" add -A; git -C "$L" commit -qm "$name"
  OUT=$(cd "$L" && "$LINT" --base base --catalog "$CAT" 2>&1); RC=$?
}
grow() { printf 'export const G%s = %s;\n' "$2" "$2" >>"$1"; }

case_run l1a 'for n in 1 2 3; do grow worker/jobs/src/lib/core.js $n; done'
[ "$RC" = 1 ] && ok || bad "L1 core.js +3 with no lib file: rc $RC, want 1: $OUT"
case "$OUT" in *"worker/jobs/src/lib/core.js"*) ok ;; *) bad "L1 output does not name core.js: $OUT" ;; esac
case "$OUT" in *"Fix: put the new entry in its own file under worker/jobs/src/lib/"*) ok ;; *) bad "L1 output does not name the fix: $OUT" ;; esac

case_run l1b 'sed -i "1,2d" worker/jobs/src/lib/core.js; for n in 1 2 3 4 5 6 7 8 9 10; do grow worker/jobs/src/lib/core.js $n; done; echo "x" >worker/jobs/test/x.test.js'
[ "$RC" = 1 ] && ok || bad "L1 core.js +10/-2 with only a test file: rc $RC, want 1: $OUT"

case_run l2a 'for n in 1 2 3; do grow worker/jobs/src/lib/core.js $n; done; echo "export const CREATED_TABLE_OVERRIDES = {};" >worker/jobs/src/lib/core.d/bh-9001-x.js'
[ "$RC" = 0 ] && ok || bad "L2 core.js +3 with a new core.d/ fragment: rc $RC, want 0: $OUT"

case_run l2b 'for n in 1 2 3; do grow worker/jobs/src/lib/core.js $n; done; echo "export const F = 1;" >worker/jobs/src/lib/foo.js'
[ "$RC" = 0 ] && ok || bad "L2b core.js +3 with a new src/lib/foo.js: rc $RC, want 0: $OUT"

case_run l3a 'sed -i "s/B = 2/B = 22/" worker/jobs/src/lib/core.js'
[ "$RC" = 0 ] && ok || bad "L3 in-place edit of core.js: rc $RC, want 0: $OUT"

case_run l3b 'sed -i "3,4d" worker/jobs/src/lib/core.js'
[ "$RC" = 0 ] && ok || bad "L3 shrink of core.js: rc $RC, want 0: $OUT"

case_run l4a 'for n in 1 2 3; do grow worker/jobs/src/lib/core-registries.js $n; done'
[ "$RC" = 0 ] && ok || bad "L4 growth of core-registries.js: rc $RC, want 0: $OUT"

case_run l4b 'sed -i "s/    \"x\",/    \"x\",\n    \"y\",/" worker/jobs/src/lib/core.d/0000-risk-tiers.js'
[ "$RC" = 0 ] && ok || bad "L4 edit of a 0000-* baseline: rc $RC, want 0: $OUT"
[ "$(git -C "$L" diff --numstat base l4b | awk '{print $1}')" = 1 ] && ok || bad "L4 the 0000-risk-tiers.js edit must add one line"

# ── M1 two moved tables, two branches, no conflict ────────────────────────────
R="$T/repo"; J="$R/worker/jobs"
mkdir -p "$J/src/lib"
cp "$DIR/worker/jobs/src/lib/core-registries.js" "$DIR/worker/jobs/src/lib/core-registries.node.js" "$J/src/lib/"
cp -R "$DIR/worker/jobs/src/lib/core.d" "$J/src/lib/core.d"
cp "$DIR/worker/jobs/package.json" "$J/package.json"
git init -q -b main "$R"; git -C "$R" add -A; git -C "$R" commit -qm base

RFRAG="$J/src/lib/core.d/0000-risk-tiers.js"; DFRAG="$J/src/lib/core.d/0000-dequeue-events.js"
if [ -f "$RFRAG" ] && [ -f "$DFRAG" ]; then
  git -C "$R" checkout -q -b x main
  # In place: the first column line of the risk_tiers CREATE TABLE gains x_col.
  awk '!done && /CREATE TABLE IF NOT EXISTS risk_tiers \(/ { print; print "       x_col TEXT,"; done=1; next } { print }' "$RFRAG" >"$T/r.js" && mv "$T/r.js" "$RFRAG"
  git -C "$R" commit -qam "x: risk_tiers x_col"
  git -C "$R" checkout -q -b y main
  # Append: one more dequeue_events statement after the last one.
  awk '/^  \],$/ && !done { print "    \"CREATE INDEX IF NOT EXISTS idx_dequeue_events_y ON dequeue_events(project)\","; done=1 } { print }' "$DFRAG" >"$T/d.js" && mv "$T/d.js" "$DFRAG"
  git -C "$R" commit -qam "y: dequeue_events idx"
  git -C "$R" checkout -q main

  X=$(git -C "$R" diff --name-only main x); Y=$(git -C "$R" diff --name-only main y)
  [ "$X" = "worker/jobs/src/lib/core.d/0000-risk-tiers.js" ] && ok || bad "M1 branch x must change only 0000-risk-tiers.js: [$X]"
  [ "$Y" = "worker/jobs/src/lib/core.d/0000-dequeue-events.js" ] && ok || bad "M1 branch y must change only 0000-dequeue-events.js: [$Y]"
  git -C "$R" merge -q --no-edit x >"$T/mx.out" 2>&1 && ok || bad "M1 merge x: $(cat "$T/mx.out")"
  git -C "$R" merge -q --no-edit y >"$T/my.out" 2>&1 && ok || bad "M1 merge y conflicted: $(cat "$T/my.out")"
  [ -z "$(git -C "$R" diff --name-only --diff-filter=U)" ] && ok || bad "M1 unmerged paths after the merge"
  ( cd "$J" && node --input-type=module -e '
    const m = await import("./src/lib/core-registries.node.js");
    const o = m.CREATED_TABLE_OVERRIDES;
    if (!/x_col TEXT/.test(o.risk_tiers[0])) { console.log("risk_tiers[0] has no x_col"); process.exit(1); }
    const d = o.dequeue_events;
    if (d[d.length - 1] !== "CREATE INDEX IF NOT EXISTS idx_dequeue_events_y ON dequeue_events(project)") { console.log("dequeue_events ends " + d[d.length - 1]); process.exit(1); }' ) >"$T/m1.out" 2>&1 \
    && ok || bad "M1 merged composition: $(cat "$T/m1.out")"
else
  bad "M1 needs core.d/0000-risk-tiers.js and core.d/0000-dequeue-events.js"
fi

# ── N1 the node suites ────────────────────────────────────────────────────────
# node --test needs no install here: the worker's one dependency is lazy (package.json).
( cd "$DIR/worker/jobs" && node --test test/core-overrides.bh-8448.test.js test/core-overrides.bh-8447.test.js ) >"$T/n1.out" 2>&1 \
  && ok || bad "N1 node --test core-overrides.bh-8448 + bh-8447: $(grep -E '^not ok|error:' "$T/n1.out" | head -10)"

echo "core-overrides-split.bh-8448: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
