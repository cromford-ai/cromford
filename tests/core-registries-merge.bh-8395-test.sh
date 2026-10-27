#!/bin/bash
# tests/core-registries-merge.bh-8395-test.sh — two builds that each add a
# column to the jobs worker merge with no conflict (BH-8395).
#
# ADDED_COLUMNS, ADDED_INDEXES and fragment additions to
# CREATED_TABLE_OVERRIDES compose from worker/jobs/src/lib/core.d/<NNNN|key>-<name>.js.
# A new entry is a new file keyed by the ticket, never a core.js edit.
#   M1  branch X adds a verdicts column under bh-1, branch Y an alerts column
#       under bh-2: both merge with no conflict, no shared file, core.js in
#       neither diff, and the node loader ends verdicts with x_col, alerts with y_col
#   M2  the worker-schema-ensure-columns guard still sees a fragment tuple
#   R1  core-registries-build.mjs --print lists the fragments sorted; a rerun is byte-identical
#   R2  the printed render, imported under node, equals the node loader's exports
#   R3  --check: rc 0 clean; rc 1 on a tracked gen file, a stale gen file, a bad fragment
#   R4  the write path keeps the gen file's mtime when the bytes are equal
#   P1  the real repo's 0000-* composition equals the pre-split fixture
#   G1  the real repo git-ignores the render, wrangler.jsonc runs both scripts,
#       package.json maps #core-registries for workerd and default
#   W1  (optional) wrangler deploy --dry-run bundles the scratch worker
# Fixture repos only, fixed commit dates, no network. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/core-registries-merge.bh-8395-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node is not on PATH"; exit 1; }

COMPOSER="$DIR/worker/jobs/src/lib/core-registries.js"
LOADER="$DIR/worker/jobs/src/lib/core-registries.node.js"
BUILD="$DIR/worker/jobs/scripts/core-registries-build.mjs"
BASE_COLS="$DIR/worker/jobs/src/lib/core.d/0000-added-columns.js"
BASE_IDX="$DIR/worker/jobs/src/lib/core.d/0000-added-indexes.js"
FIXTURE="$DIR/worker/jobs/test/fixtures/core-registries-pre-split.bh-8395.json"
CHECK="$DIR/checks/worker-schema-ensure-columns/check.sh"
for f in "$COMPOSER" "$LOADER" "$BUILD" "$BASE_COLS" "$BASE_IDX" "$FIXTURE"; do
  [ -f "$f" ] && ok || bad "missing ${f#"$DIR"/}"
done
if [ "$FAIL" -ne 0 ]; then echo "core-registries-merge.bh-8395: $PASS passed, $FAIL failed"; exit 1; fi

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# A scratch repo with the composer, the loader, the render script and the fragments.
R="$T/repo"; J="$R/worker/jobs"
mkdir -p "$J/src/lib" "$J/scripts" "$J/schema.d"
cp "$COMPOSER" "$LOADER" "$J/src/lib/"
cp -R "$DIR/worker/jobs/src/lib/core.d" "$J/src/lib/core.d"
cp "$BUILD" "$J/scripts/"
cp "$DIR/worker/jobs/package.json" "$J/package.json"
git init -q -b main "$R"; git -C "$R" add -A; git -C "$R" commit -qm base

# loader_json — the node loader's three exports as JSON, from the scratch tree.
loader_json() {
  ( cd "$J" && node --input-type=module -e '
    const m = await import("./src/lib/core-registries.node.js");
    process.stdout.write(JSON.stringify({ c: m.ADDED_COLUMNS, i: m.ADDED_INDEXES, o: m.CREATED_TABLE_OVERRIDES, f: m.FRAGMENTS }));' )
}

# fragment <branch> <file> <table> <col> — a branch off main that adds one column.
fragment() {
  git -C "$R" checkout -q -b "$1" main
  printf '// %s: a test column.\nexport const ADDED_COLUMNS = {\n  %s: [["%s", "TEXT"]],\n};\n' "$2" "$3" "$4" > "$J/src/lib/core.d/$2"
  git -C "$R" add -A; git -C "$R" commit -qm "$2"
}
fragment x bh-1-verdicts-x.js verdicts x_col
fragment y bh-2-alerts-y.js alerts y_col
git -C "$R" checkout -q main

# ── M1 no shared file, no conflict ────────────────────────────────────────────
X=$(git -C "$R" diff --name-only main x); Y=$(git -C "$R" diff --name-only main y)
[ -z "$(comm -12 <(sort <<<"$X") <(sort <<<"$Y"))" ] && ok || bad "M1 the two branches share a file"
grep -q 'src/lib/core.js' <<<"$X$Y" && bad "M1 a branch edited core.js" || ok
git -C "$R" merge -q --no-edit x >"$T/mx.out" 2>&1 && ok || bad "M1 merge x: $(cat "$T/mx.out")"
git -C "$R" merge -q --no-edit y >"$T/my.out" 2>&1 && ok || bad "M1 merge y conflicted: $(cat "$T/my.out")"
[ -z "$(git -C "$R" diff --name-only --diff-filter=U)" ] && ok || bad "M1 unmerged paths after the merge"
loader_json >"$T/merged.json" 2>"$T/merged.err" && ok || bad "M1 the node loader failed: $(cat "$T/merged.err")"
node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const last = (t) => JSON.stringify(j.c[t][j.c[t].length - 1]);
  if (last("verdicts") !== "[\"x_col\",\"TEXT\"]") { console.log("verdicts ends " + last("verdicts")); process.exit(1); }
  if (last("alerts") !== "[\"y_col\",\"TEXT\"]") { console.log("alerts ends " + last("alerts")); process.exit(1); }
  if (JSON.stringify(j.c.verdicts[0]) !== "[\"auth\",\"TEXT\"]") { console.log("the baseline must stay first"); process.exit(1); }' "$T/merged.json" >"$T/m1.out" 2>&1 \
  && ok || bad "M1 merged composition: $(cat "$T/m1.out")"

# ── M2 the ensure-columns guard sees a column added in a fragment ─────────────
{
  git -C "$R" diff -U0 x~1 x -- worker/jobs/src | awk '/^\+\+\+ b\//{p=substr($0,7); next} /^\+[^+]/{n++; printf "%s\t%d\t%s\n", p, n, substr($0,2)}'
  printf 'worker/jobs/schema.d/bh-1-x.sql\t1\tCREATE INDEX IF NOT EXISTS idx_v_x ON verdicts(x_col)\n'
} >"$T/m2.in"
bash "$CHECK" <"$T/m2.in" >"$T/m2.out" 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q 'verdicts(x_col)' "$T/m2.out" && ok || bad "M2 the guard must flag the index on a fragment column (rc $RC): $(cat "$T/m2.out")"

# ── R1 --print: sorted, deterministic ─────────────────────────────────────────
( cd "$J" && node scripts/core-registries-build.mjs --print ) >"$T/gen1.js" 2>"$T/gen1.err"; RC=$?
[ "$RC" = 0 ] && ok || bad "R1 --print rc $RC: $(cat "$T/gen1.err")"
( cd "$J" && node scripts/core-registries-build.mjs --print ) >"$T/gen2.js" 2>/dev/null
cmp -s "$T/gen1.js" "$T/gen2.js" && ok || bad "R1 two renders differ"
GOT=$(sed -n 's|^import \* as f[0-9]* from "./core.d/\(.*\)";$|\1|p' "$T/gen1.js")
WANT=$(cd "$J/src/lib/core.d" && LC_ALL=C ls -1 | LC_ALL=C sort)
[ -n "$GOT" ] && [ "$GOT" = "$WANT" ] && ok || bad "R1 render import order: want [$WANT] got [$GOT]"

# ── R2 the render equals the node loader ──────────────────────────────────────
cp "$T/gen1.js" "$J/src/lib/core-registries.r2.js"
( cd "$J" && node --input-type=module -e '
  const m = await import("./src/lib/core-registries.r2.js");
  process.stdout.write(JSON.stringify({ c: m.ADDED_COLUMNS, i: m.ADDED_INDEXES, o: m.CREATED_TABLE_OVERRIDES, f: m.FRAGMENTS }));' ) >"$T/r2.json" 2>"$T/r2.err"
rm -f "$J/src/lib/core-registries.r2.js"
[ -s "$T/r2.json" ] && cmp -s "$T/r2.json" "$T/merged.json" && ok || bad "R2 render != node loader: $(cat "$T/r2.err")"

# ── R3 --check ────────────────────────────────────────────────────────────────
GEN="$J/src/lib/core-registries.gen.js"
( cd "$J" && node scripts/core-registries-build.mjs --check ) >"$T/r3a.out" 2>&1; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/r3a.out" ] && ok || bad "R3 --check on a clean tree: rc $RC $(cat "$T/r3a.out")"
( cd "$J" && node scripts/core-registries-build.mjs ) && [ -f "$GEN" ] && ok || bad "R3 the write path made no gen file"
( cd "$J" && node scripts/core-registries-build.mjs --check ) >"$T/r3b.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "R3 --check with a fresh gen file on disk: rc $RC $(cat "$T/r3b.out")"
git -C "$R" add -f "$GEN"
( cd "$J" && node scripts/core-registries-build.mjs --check ) >"$T/r3c.out" 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q '^core-registries-build: .*tracked' "$T/r3c.out" && ok || bad "R3 --check must refuse a tracked gen file: rc $RC $(cat "$T/r3c.out")"
git -C "$R" rm -q --cached "$GEN"
printf '// a hand edit\n' >>"$GEN"
( cd "$J" && node scripts/core-registries-build.mjs --check ) >"$T/r3d.out" 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q '^core-registries-build: .*stale' "$T/r3d.out" && ok || bad "R3 --check must refuse a stale gen file: rc $RC $(cat "$T/r3d.out")"
rm -f "$GEN"
printf 'export const ADDED_COLUMNS = { t: [["a", "TEXT"]] };\n' >"$J/src/lib/core.d/bad.js"
for mode in --check ""; do
  # shellcheck disable=SC2086 # $mode is empty for the write path
  ( cd "$J" && node scripts/core-registries-build.mjs $mode ) >"$T/r3e.out" 2>&1; RC=$?
  [ "$RC" = 1 ] && [ "$(wc -l <"$T/r3e.out")" = 1 ] && grep -q '^core-registries-build: .*bad\.js' "$T/r3e.out" \
    && ok || bad "R3 a bad fragment (${mode:-write}) must give rc 1 and one line: rc $RC $(cat "$T/r3e.out")"
  [ ! -e "$GEN" ] && ok || bad "R3 a bad fragment (${mode:-write}) must write no gen file"
done
grep -q '\.tmp$' <<<"$(ls "$J/src/lib/")" && bad "R3 a tmp file was left behind" || ok
rm -f "$J/src/lib/core.d/bad.js"

# ── R4 equal bytes: no write ──────────────────────────────────────────────────
( cd "$J" && node scripts/core-registries-build.mjs ) || bad "R4 the write path failed"
touch -d '@1600000000' "$GEN"
( cd "$J" && node scripts/core-registries-build.mjs ) || bad "R4 the rerun failed"
[ "$(stat -c %Y "$GEN")" = 1600000000 ] && ok || bad "R4 a rerun with equal bytes touched the gen file"
( cd "$J" && node scripts/core-registries-build.mjs --out "$T/out.js" ) && cmp -s "$T/out.js" "$GEN" && ok || bad "R4 --out must write the same render"

# ── P1 the real baselines equal the pre-split fixture ─────────────────────────
( cd "$DIR/worker/jobs" && node --input-type=module -e '
  import { readFileSync } from "node:fs";
  import { composeCoreRegistries } from "./src/lib/core-registries.js";
  const cols = await import("./src/lib/core.d/0000-added-columns.js");
  const idx = await import("./src/lib/core.d/0000-added-indexes.js");
  const c = composeCoreRegistries([["0000-added-columns.js", cols], ["0000-added-indexes.js", idx]]);
  const fx = JSON.parse(readFileSync(process.argv[1], "utf8"));
  if (JSON.stringify(c.ADDED_COLUMNS) !== JSON.stringify(fx.ADDED_COLUMNS)) { console.log("ADDED_COLUMNS differs"); process.exit(1); }
  if (JSON.stringify(c.ADDED_INDEXES) !== JSON.stringify(fx.ADDED_INDEXES)) { console.log("ADDED_INDEXES differs"); process.exit(1); }' "$FIXTURE" ) >"$T/p1.out" 2>&1 \
  && ok || bad "P1 baselines vs fixture: $(cat "$T/p1.out")"

# ── G1 the real repo's wiring ─────────────────────────────────────────────────
git -C "$DIR" check-ignore -q worker/jobs/src/lib/core-registries.gen.js && ok || bad "G1 core-registries.gen.js is not git-ignored"
[ -z "$(git -C "$DIR" ls-files worker/jobs/src/lib/core-registries.gen.js)" ] && ok || bad "G1 core-registries.gen.js is tracked"
# TEST-CHANGE (BH-8406): build.command now chains a third render
# (retention-build.mjs), so G1 parses the command and asserts both scripts run,
# routes first, instead of pinning the whole string.
node -e '
  const t = require("fs").readFileSync(process.argv[1], "utf8").replace(/^\s*\/\/.*$/gm, "");
  const steps = String((JSON.parse(t).build || {}).command || "").split("&&").map((s) => s.trim());
  const r = steps.indexOf("node scripts/routes-build.mjs"), c = steps.indexOf("node scripts/core-registries-build.mjs");
  process.exit(r >= 0 && c > r ? 0 : 1);' "$DIR/worker/jobs/wrangler.jsonc" \
  && ok || bad "G1 wrangler.jsonc build.command must run both render scripts"
node -e '
  const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).imports["#core-registries"] || {};
  if (p.workerd !== "./src/lib/core-registries.gen.js" || p.default !== "./src/lib/core-registries.node.js") process.exit(1);' \
  "$DIR/worker/jobs/package.json" && ok || bad "G1 package.json must map #core-registries (workerd gen, default node loader)"

# ── W1 optional: wrangler bundles the worker with the render ─────────────────
if ( cd "$DIR/worker/jobs" && npx --no-install wrangler --version ) >/dev/null 2>&1; then
  WC="$T/w1"; mkdir -p "$WC/worker"
  cp -R "$DIR/worker/jobs" "$WC/worker/jobs"; cp -R "$DIR/catalog" "$WC/catalog"; cp -R "$DIR/agent-core" "$WC/agent-core"
  ( cd "$WC/worker/jobs" && npx --no-install wrangler deploy --dry-run --outdir "$T/w1-out" ) >"$T/w1.out" 2>&1 \
    && ok || bad "W1 wrangler deploy --dry-run: $(tail -5 "$T/w1.out")"
else
  echo "NOTE: W1 skipped — wrangler not installed"
fi

echo "core-registries-merge.bh-8395: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
