#!/bin/bash
# tests/retention-split.bh-8398-test.sh — a new retention rule is a new file in
# worker/jobs/src/routes/retention.d/, so two builds that each add one merge
# with no conflict (BH-8398.0, ticket BH-8406).
#
#   S1 SIBLINGS MERGE CLEAN: branch A adds retention.d/bh-90001-fixture-a.js,
#      branch B adds bh-90002-fixture-b.js; the merge has no conflict,
#      retention.js is byte-identical to base on A, B and the merge, and the
#      composed RULES holds both fixture rules and every real rule
#   S2 OLD SHAPE CONFLICTS: the same two rules appended in retention.js before
#      the literal's closing `];` on two branches conflict
#   S3 SAME RULES: the branch RULES, filtered to the names RULES had at $PIN,
#      equal $PIN's RULES (names, order, each entry; a function compared by
#      name and source). The baseline is `git show $PIN:...retention.js`; if
#      $PIN is not in this checkout, the committed fixture (which this suite
#      wrote with --write-fixture, and which S3 checks against git show when
#      $PIN is present)
#   S5 WIRING: build.command runs retention-build.mjs, package.json maps
#      #retention-rules for workerd and default, the gen file is ignored and untracked
#   S6 WORKERD ROUND TRIP: the render, imported under node, equals the Node
#      loader in the same order; an equal re-render keeps the mtime; --print
#      has one retention.d/ import per fragment in fragmentNames order
#   S7 REFUSALS: stray names, a non-array default, a duplicate rule and a rule
#      with no del give rc 1, one `retention-build:` line, no gen and no tmp
#      file; the Node loader throws the same message. Near misses render rc 0
#   S8 ORDER: fragmentNames sorts by the numeric ticket key, then the name
#   S9 MUTATION: with the bh-7598 fragment deleted, S3's comparison is red and
#      names web_task_human_step.age
#
# Scratch trees only, fixed git identity and dates, no network.
#   HARNESS_TEST_SANDBOX=1 bash tests/retention-split.bh-8398-test.sh
#   HARNESS_TEST_SANDBOX=1 bash tests/retention-split.bh-8398-test.sh --write-fixture
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 || { echo "SKIPPED: node is not on PATH"; exit 0; }

PIN=006f70508c7e04d279ba89a79b992e44a9dd739c
JOBS="$DIR/worker/jobs"
FIXTURE="$JOBS/test/fixtures/retention-rules-pre-split.bh-8406.json"
COMPOSER="$JOBS/src/lib/retention-rules.js"
LOADER="$JOBS/src/lib/retention-rules.node.js"
BUILD="$JOBS/scripts/retention-build.mjs"
FRAG="$JOBS/src/routes/retention.d/bh-7598-web-task-human-step.js"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# normalize <worker dir> <module path under it> — that module's RULES as JSON.
# A function value becomes {"$fn": name, "src": String(fn)}.
normalize() {
  ( cd "$1" && node --input-type=module -e '
    const m = await import(process.argv[1]);
    const norm = (v) => typeof v === "function" ? { $fn: v.name, src: String(v) }
      : Array.isArray(v) ? v.map(norm)
      : v && typeof v === "object" ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, norm(x)]))
      : v;
    process.stdout.write(JSON.stringify(norm(m.RULES), null, 1) + "\n");' "$2" )
}

# compare <baseline.json> <branch.json> — rc 0 when the branch RULES, filtered to
# the baseline names, equal the baseline in order. Names every difference.
compare() {
  node -e '
    const fs = require("fs");
    const base = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const got = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const names = new Set(base.map((r) => r.rule));
    const kept = got.filter((r) => names.has(r.rule));
    const have = new Set(kept.map((r) => r.rule));
    let bad = 0;
    for (const r of base) if (!have.has(r.rule)) { console.log("missing rule: " + r.rule); bad++; }
    if (!bad) base.forEach((r, i) => {
      if (kept[i].rule !== r.rule) { console.log(`order: #${i} is ${kept[i].rule}, want ${r.rule}`); bad++; }
      else if (JSON.stringify(kept[i]) !== JSON.stringify(r)) { console.log("differs: " + r.rule); bad++; }
    });
    process.exit(bad ? 1 : 0);' "$1" "$2"
}

# pinned_json <worker dir> — $PIN's RULES, loaded from a copy of $PIN's
# retention.js next to the scratch tree's libs. rc 1 when $PIN is absent.
pinned_json() {
  git -C "$DIR" cat-file -e "$PIN^{commit}" 2>/dev/null || return 1
  git -C "$DIR" show "$PIN:worker/jobs/src/routes/retention.js" >"$1/src/routes/retention-pinned.js" || return 1
  normalize "$1" ./src/routes/retention-pinned.js
  local rc=$?
  rm -f "$1/src/routes/retention-pinned.js"
  return $rc
}

# scratch_worker <dir> — a copy of worker/jobs (src, scripts, package.json).
scratch_worker() {
  mkdir -p "$1"
  cp -R "$JOBS/src" "$JOBS/scripts" "$JOBS/package.json" "$1/"
  rm -f "$1/src/retention-rules.gen.js"
}

if [ "${1:-}" = "--write-fixture" ]; then
  scratch_worker "$T/wf"
  pinned_json "$T/wf" >"$FIXTURE" || { echo "cannot write the fixture: $PIN is not in this checkout"; exit 1; }
  echo "wrote ${FIXTURE#"$DIR"/}"; exit 0
fi

for f in "$COMPOSER" "$LOADER" "$BUILD" "$FRAG" "$FIXTURE"; do
  [ -f "$f" ] && ok "present ${f#"$DIR"/}" || bad "missing ${f#"$DIR"/}"
done

W="$T/w"; scratch_worker "$W"

# ── S3 same rules ─────────────────────────────────────────────────────────────
echo "S3: the same rules as $PIN"
BASE_JSON="$T/base.json"
if pinned_json "$W" >"$T/pinned.json" 2>"$T/pinned.err"; then
  cp "$T/pinned.json" "$BASE_JSON"
  cmp -s "$T/pinned.json" "$FIXTURE" && ok "S3 the fixture equals git show $PIN" \
    || bad "S3 the fixture differs from git show $PIN (rerun with --write-fixture only if $PIN moved)"
else
  echo "NOTE: $PIN not in this checkout (fetch-depth 0 restores it); using the fixture"
  cp "$FIXTURE" "$BASE_JSON" 2>/dev/null || : >"$BASE_JSON"
fi
normalize "$W" ./src/routes/retention.js >"$T/branch.json" 2>"$T/branch.err" \
  && ok "S3 the branch retention.js loads" || bad "S3 the branch retention.js does not load: $(head -3 "$T/branch.err")"
compare "$BASE_JSON" "$T/branch.json" >"$T/s3.out" 2>&1 && ok "S3 same names, order and entries" \
  || bad "S3 the branch RULES differ: $(head -5 "$T/s3.out")"
NB=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).length)' "$BASE_JSON" 2>/dev/null)
# The branch rules that carry a $PIN name, as compare() filters them: a later
# fragment adds a rule with a new name, and that is not a change to these.
NG=$(node -e 'const fs = require("fs"); const names = new Set(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).map((r) => r.rule));
console.log(JSON.parse(fs.readFileSync(process.argv[2], "utf8")).filter((r) => names.has(r.rule)).length)' "$BASE_JSON" "$T/branch.json" 2>/dev/null)
[ -n "$NB" ] && [ "$NB" = "$NG" ] && ok "S3 the same count ($NB)" || bad "S3 count: base ${NB:-?}, branch ${NG:-?}"

# ── S9 mutation: the moved rule is gone ───────────────────────────────────────
echo "S9: mutation"
M="$T/m"; scratch_worker "$M"
rm -f "$M/src/routes/retention.d/bh-7598-web-task-human-step.js"
if [ -f "$FRAG" ]; then
  normalize "$M" ./src/routes/retention.js >"$T/m.json" 2>/dev/null || : >"$T/m.json"
  [ -s "$T/m.json" ] || echo '[]' >"$T/m.json"
  compare "$BASE_JSON" "$T/m.json" >"$T/s9.out" 2>&1; RC=$?
  [ "$RC" != 0 ] && grep -q 'web_task_human_step.age' "$T/s9.out" && ok "S9 S3 goes red and names web_task_human_step.age" \
    || bad "S9 S3 must be red without the fragment: rc $RC $(cat "$T/s9.out")"
else
  bad "S9 no fragment to delete"
fi

# ── S8 order ──────────────────────────────────────────────────────────────────
echo "S8: order"
GOT=$( cd "$W" && node --input-type=module -e '
  const { fragmentNames } = await import("./src/lib/retention-rules.js");
  console.log(fragmentNames(["bh-10-a.js", "bh-9-b.js", "bh-9-a.js", "README.md"]).join(","));' 2>&1 )
[ "$GOT" = "bh-9-a.js,bh-9-b.js,bh-10-a.js" ] && ok "S8 numeric order, README.md ignored" || bad "S8 fragmentNames gave: $GOT"

# ── S5 wiring ─────────────────────────────────────────────────────────────────
echo "S5: wiring"
cmd=$(node -e '
  const t = require("fs").readFileSync(process.argv[1], "utf8").replace(/^\s*\/\/.*$/gm, "");
  process.stdout.write(String((JSON.parse(t).build || {}).command || ""));' "$JOBS/wrangler.jsonc" 2>&1)
case "$cmd" in
  *"node scripts/retention-build.mjs"*) ok "S5 build.command: $cmd" ;;
  *) bad "S5 build.command '$cmd' does not run node scripts/retention-build.mjs" ;;
esac
node -e '
  const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).imports["#retention-rules"] || {};
  process.exit(p.workerd === "./src/retention-rules.gen.js" && p.default === "./src/lib/retention-rules.node.js" ? 0 : 1);' \
  "$JOBS/package.json" && ok "S5 package.json maps #retention-rules" || bad "S5 package.json must map #retention-rules (workerd gen, default node loader)"
git -C "$DIR" check-ignore -q --no-index worker/jobs/src/retention-rules.gen.js && ok "S5 the gen file is git-ignored" \
  || bad "S5 worker/jobs/src/retention-rules.gen.js is not git-ignored"
[ -z "$(git -C "$DIR" ls-files worker/jobs/src/retention-rules.gen.js)" ] && ok "S5 the gen file is untracked" \
  || bad "S5 worker/jobs/src/retention-rules.gen.js is tracked"

# ── S6 workerd round trip ─────────────────────────────────────────────────────
echo "S6: render round trip"
GEN="$W/src/retention-rules.gen.js"
( cd "$W" && node scripts/retention-build.mjs --out "$GEN" ) >"$T/s6.out" 2>&1; RC=$?
[ "$RC" = 0 ] && [ -f "$GEN" ] && ok "S6 the render wrote the gen file" || bad "S6 render rc $RC: $(head -3 "$T/s6.out")"
loader_rules() { normalize "$1" ./src/lib/retention-rules.node.js; }
normalize "$W" ./src/retention-rules.gen.js >"$T/gen.json" 2>"$T/gen.err"
loader_rules "$W" >"$T/loader.json" 2>"$T/loader.err"
[ -s "$T/gen.json" ] && cmp -s "$T/gen.json" "$T/loader.json" && ok "S6 the render's RULES equal the Node loader's" \
  || bad "S6 render vs loader: $(head -3 "$T/gen.err" "$T/loader.err")"
touch -d '@1600000000' "$GEN" 2>/dev/null
( cd "$W" && node scripts/retention-build.mjs --out "$GEN" ) >/dev/null 2>&1
[ "$(stat -c %Y "$GEN" 2>/dev/null)" = 1600000000 ] && ok "S6 an equal re-render keeps the mtime" || bad "S6 an equal re-render touched the gen file"
( cd "$W" && node scripts/retention-build.mjs --print ) >"$T/print.js" 2>/dev/null
GOT=$(sed -n 's|^import \* as f[0-9]* from "\./routes/retention\.d/\(.*\)";$|\1|p' "$T/print.js")
WANT=$( cd "$W" && node --input-type=module -e '
  import { readdirSync } from "node:fs";
  const { fragmentNames } = await import("./src/lib/retention-rules.js");
  console.log(fragmentNames(readdirSync("src/routes/retention.d")).join("\n"));' 2>/dev/null )
[ -n "$GOT" ] && [ "$GOT" = "$WANT" ] && grep -q 'retention.d/bh-7598-web-task-human-step.js' "$T/print.js" \
  && ok "S6 --print imports each fragment once, in fragmentNames order" || bad "S6 --print imports: want [$WANT] got [$GOT]"
cmp -s "$T/print.js" "$GEN" && ok "S6 --print equals the written render" || bad "S6 --print differs from the written render"
rm -f "$GEN"

# ── S7 refusals ───────────────────────────────────────────────────────────────
echo "S7: refusals"
RD="$W/src/routes/retention.d"
rule() { printf 'export default [\n  { rule: "%s", table: "t", key: "retention.t.days", def: 1,\n    ids: "SELECT id FROM t", %s },\n];\n' "$1" "$2"; }
# refuse <label> — the render and the Node loader both refuse the current dir.
refuse() {
  ( cd "$W" && node scripts/retention-build.mjs ) >"$T/s7.out" 2>"$T/s7.err"; local rc=$?
  local line; line=$(cat "$T/s7.err")
  [ "$rc" = 1 ] && [ "$(wc -l <"$T/s7.err")" = 1 ] && grep -q '^retention-build: ' "$T/s7.err" \
    && ok "S7 $1: rc 1, one line ($line)" || bad "S7 $1: rc $rc, stderr [$line]"
  [ ! -e "$GEN" ] && ok "S7 $1: no gen file" || { bad "S7 $1: a gen file was written"; rm -f "$GEN"; }
  grep -q '\.tmp$' <<<"$(ls "$W/src")" && bad "S7 $1: a tmp file was left" || ok "S7 $1: no tmp file"
  local msg; msg=$( cd "$W" && node --input-type=module -e '
    try { await import("./src/lib/retention-rules.node.js"); console.log("loaded"); }
    catch (e) { console.log(String(e.message).split("\n")[0]); }' 2>&1 )
  [ -n "$line" ] && [ "retention-build: $msg" = "$line" ] && ok "S7 $1: the Node loader throws the same message" \
    || bad "S7 $1: the loader said [$msg], the render said [$line]"
}
for stray in oops.js bh-x-a.js bh-1-.js BH-1-a.js bh-1-a.mjs; do
  rule "stray.age" 'del: "DELETE FROM t"' >"$RD/$stray"; refuse "stray name $stray"; rm -f "$RD/$stray"
done
printf 'export default {};\n' >"$RD/bh-90003-object.js"; refuse "a non-array default"; rm -f "$RD/bh-90003-object.js"
rule "web_task_human_step.age" 'del: "DELETE FROM t"' >"$RD/bh-90004-dup.js"; refuse "a duplicate rule"; rm -f "$RD/bh-90004-dup.js"
grep -q 'duplicate rule: web_task_human_step.age' "$T/s7.err" && ok "S7 the duplicate message names the rule" \
  || bad "S7 the duplicate message must name web_task_human_step.age: $(cat "$T/s7.err")"
rule "no_del.age" 'pre: []' >"$RD/bh-90005-no-del.js"; refuse "a rule with no del"; rm -f "$RD/bh-90005-no-del.js"
rule "near_a.age" 'del: "DELETE FROM t"' >"$RD/bh-7243.0-roadmap.js"
rule "near_b.age" 'del: "DELETE FROM t"' >"$RD/bh-1-a-b-c.js"
( cd "$W" && node scripts/retention-build.mjs ) >"$T/s7n.out" 2>&1; RC=$?
[ "$RC" = 0 ] && grep -q 'retention.d/bh-7243.0-roadmap.js' "$GEN" && grep -q 'retention.d/bh-1-a-b-c.js' "$GEN" \
  && ok "S7 the near misses render rc 0" || bad "S7 near misses: rc $RC $(cat "$T/s7n.out")"
rm -f "$RD/bh-7243.0-roadmap.js" "$RD/bh-1-a-b-c.js" "$GEN"

# ── S1 siblings merge clean / S2 the old shape conflicts ──────────────────────
echo "S1/S2: merges"
R="$T/repo"; J="$R/worker/jobs"; scratch_worker "$J"
git init -q -b main "$R"; git -C "$R" add -A; git -C "$R" commit -qm base
RJ=worker/jobs/src/routes/retention.js
BASE_SHA=$(git -C "$R" rev-parse "main:$RJ")
git -C "$R" checkout -q -b a main
rule fixture_a.age 'del: "DELETE FROM t"' >"$J/src/routes/retention.d/bh-90001-fixture-a.js"
git -C "$R" add -A; git -C "$R" commit -qm a
git -C "$R" checkout -q -b b main
rule fixture_b.age 'del: "DELETE FROM t"' >"$J/src/routes/retention.d/bh-90002-fixture-b.js"
git -C "$R" add -A; git -C "$R" commit -qm b
git -C "$R" merge -q --no-edit a >"$T/s1.out" 2>&1 && ok "S1 merge rc 0" || bad "S1 the merge conflicted: $(head -3 "$T/s1.out")"
grep -rl '^<<<<<<<' "$J/src" >/dev/null 2>&1 && bad "S1 conflict markers after the merge" || ok "S1 no conflict markers"
for ref in a b HEAD; do
  [ "$(git -C "$R" rev-parse "$ref:$RJ")" = "$BASE_SHA" ] && ok "S1 retention.js unchanged on $ref" || bad "S1 retention.js changed on $ref"
done
normalize "$J" ./src/routes/retention.js >"$T/s1.json" 2>"$T/s1.err"
node -e '
  const fs = require("fs");
  const got = new Set(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).map((r) => r.rule));
  const want = ["fixture_a.age", "fixture_b.age", ...JSON.parse(fs.readFileSync(process.argv[2], "utf8")).map((r) => r.rule)];
  const miss = want.filter((n) => !got.has(n));
  if (miss.length) { console.log("missing: " + miss.join(", ")); process.exit(1); }' "$T/s1.json" "$BASE_JSON" >"$T/s1c.out" 2>&1 \
  && ok "S1 the merged RULES hold both fixtures and every real rule" || bad "S1 merged RULES: $(cat "$T/s1c.out" "$T/s1.err" | head -3)"

# append_inline <rule> — add a rule in retention.js before the literal's `];`.
append_inline() {
  awk -v r="$1" '
    /^(export const RULES|const INLINE_RULES) = \[$/ { inlit = 1 }
    inlit && /^\];$/ { printf "  {\n    rule: \"%s\", table: \"t\", key: \"retention.t.days\", def: 1,\n    ids: \"SELECT id FROM t\", del: \"DELETE FROM t\",\n  },\n", r; inlit = 0 }
    { print }' "$J/src/routes/retention.js" >"$T/ret.js" && mv "$T/ret.js" "$J/src/routes/retention.js"
}
git -C "$R" checkout -q -b c main; append_inline fixture_a.age; git -C "$R" commit -qam c
git -C "$R" checkout -q -b d main; append_inline fixture_b.age; git -C "$R" commit -qam d
git -C "$R" merge -q --no-edit c >"$T/s2.out" 2>&1; RC=$?
[ "$RC" != 0 ] && grep -qx "$RJ" <<<"$(git -C "$R" diff --name-only --diff-filter=U)" \
  && ok "S2 the in-file shape conflicts in retention.js" || bad "S2 the in-file appends merged clean (rc $RC)"
git -C "$R" merge --abort 2>/dev/null

echo "retention-split.bh-8398: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
