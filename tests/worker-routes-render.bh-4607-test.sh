#!/bin/bash
# tests/worker-routes-render.bh-4607-test.sh — BH-4607: a jobs-worker route
# family is registered by its test/route-table.d fragment, never by
# worker/jobs/src/index.js.
#
# index.js imports ROUTES from "#routes". worker/jobs/package.json maps that
# specifier to src/routes.gen.js under `workerd` (wrangler's bundler; the file is
# git-ignored and wrangler.jsonc's build.command renders it with
# scripts/routes-build.mjs) and to test/lib/routes.node.js under `default`
# (node, which reads the fragments at load time). Both use the one pure composer
# src/lib/route-families.js.
#
# Cases:
#   S1 routes-build.mjs --print exits 0 with one import per gated fragment
#   S2 --out twice gives the same bytes, and the second run does not write
#   S3 a stray fragment or a fragment with no module: rc 1, one stderr line, no file
#   S4 wrangler.jsonc build.command runs the generator; package.json maps #routes
#   S5 src/routes.gen.js is git-ignored
#   S6 the node suite test/route-registry.bh-4607.test.js passes
#   S7 MUTATION: index.js gains back a gated import, and the node guardrail goes red
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/worker-routes-render.bh-4607-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

GEN="$DIR/worker/jobs/scripts/routes-build.mjs"
COMPOSER="$DIR/worker/jobs/src/lib/route-families.js"
LOADER="$DIR/worker/jobs/test/lib/routes.node.js"
FRAGS="$DIR/worker/jobs/test/route-table.d"
for f in "$GEN" "$COMPOSER" "$LOADER"; do
  [ -f "$f" ] && ok "present: ${f#"$DIR"/}" || bad "missing ${f#"$DIR"/}"
done

if ! command -v node >/dev/null 2>&1; then
  echo "worker-routes-render: node is not installed on this box"
  echo "worker-routes-render: $PASS passed, $FAIL failed (node cases not run)"
  exit 1
fi

# The number of gated fragments: every fragment minus the 4 open families.
# A fragment is <NNN>-<family>.txt or, since BH-5788, <ticket-key>-<family>.txt.
nfrag=$(ls "$FRAGS" | grep -cE '^([0-9]{3}-[a-z0-9-]+|[a-z]+-[0-9]+([.-][0-9]+)?-[a-z][a-z0-9-]*)\.txt$')
want=$((nfrag - 4))

echo "S1: --print"
out=$(node "$GEN" --print); rc=$?
[ "$rc" = 0 ] && ok "S1 rc 0" || bad "S1 rc $rc"
got=$(printf '%s\n' "$out" | grep -cE '^import \{ routes as f([0-9]{3}|_[a-z0-9_]+) \} from "\./routes/')
[ "$got" = "$want" ] && ok "S1 $got imports = $nfrag fragments - 4 open" || bad "S1 $got imports, want $want"
# A numbered fragment spreads as f<NNN>; a keyed one as f_<key>_<family>, after every numbered one.
spreads=$(printf '%s\n' "$out" | sed -n 's/^  \.\.\.f\([0-9]\{3\}\|_[a-z0-9_]*\),$/\1/p' | paste -sd,)
nums=$(ls "$FRAGS" | sed -E 's/^([0-9]{3})-.*/\1/; t; s/\.txt$//; s/[.-]/_/g; s/^/_/' \
  | grep -vxE '000|001|002|005' | paste -sd,)
[ -n "$spreads" ] && [ "$spreads" = "$nums" ] && ok "S1 spreads follow fragment order" || bad "S1 spread order: $spreads vs $nums"

echo "S2: --out twice"
node "$GEN" --out "$T/a.js"; rc1=$?
m1=$(stat -c %Y.%y "$T/a.js" 2>/dev/null)
sleep 1
node "$GEN" --out "$T/a.js"; rc2=$?
m2=$(stat -c %Y.%y "$T/a.js" 2>/dev/null)
[ "$rc1$rc2" = 00 ] && ok "S2 rc 0 twice" || bad "S2 rc $rc1/$rc2"
[ "$(cat "$T/a.js")" = "$out" ] && ok "S2 --out bytes equal --print" || bad "S2 --out bytes differ from --print"
[ -n "$m1" ] && [ "$m1" = "$m2" ] && ok "S2 the second run did not write" || bad "S2 the second run rewrote the file ($m1 / $m2)"
ls "$T"/a.js.*.tmp >/dev/null 2>&1 && bad "S2 left a .tmp file" || ok "S2 no .tmp file left"

echo "S3: refusals"
# A scratch worker/jobs with the generator, the composer and the fragments.
S="$T/s3/worker/jobs"
mkdir -p "$S/src/lib" "$S/scripts" "$S/test"
cp -R "$DIR/worker/jobs/src/routes" "$S/src/routes"
cp "$COMPOSER" "$S/src/lib/route-families.js"
cp "$GEN" "$S/scripts/routes-build.mjs"
cp -R "$FRAGS" "$S/test/route-table.d"
node "$S/scripts/routes-build.mjs" >/dev/null 2>&1 && [ -f "$S/src/routes.gen.js" ] \
  && ok "S3 the clean copy renders" || bad "S3 the clean copy did not render"
rm -f "$S/src/routes.gen.js"
: > "$S/test/route-table.d/oops.txt"
node "$S/scripts/routes-build.mjs" >"$T/s3.out" 2>"$T/s3.err"; rc=$?
[ "$rc" = 1 ] && ok "S3 stray oops.txt: rc 1" || bad "S3 stray oops.txt: rc $rc"
# TEST-CHANGE (BH-5788): the refusal names both accepted fragment forms.
[ "$(wc -l < "$T/s3.err")" = 1 ] && grep -q '^routes-build: not a <NNN>-<family>.txt or <ticket-key>-<family>.txt fragment: oops.txt$' "$T/s3.err" \
  && ok "S3 one routes-build: stderr line" || bad "S3 stderr: $(cat "$T/s3.err")"
[ -s "$T/s3.out" ] && bad "S3 wrote to stdout" || ok "S3 stdout empty"
[ -e "$S/src/routes.gen.js" ] && bad "S3 wrote src/routes.gen.js" || ok "S3 no output file"
ls "$S"/src/routes.gen.js.*.tmp >/dev/null 2>&1 && bad "S3 left a .tmp file" || ok "S3 no .tmp file"
rm -f "$S/test/route-table.d/oops.txt"
printf 'GET /api/zz-none\n' > "$S/test/route-table.d/998-zz-none.txt"
node "$S/scripts/routes-build.mjs" >/dev/null 2>"$T/s3b.err"; rc=$?
[ "$rc" = 1 ] && grep -qx 'routes-build: fragment 998-zz-none.txt names no src/routes/zz-none.js' "$T/s3b.err" \
  && ok "S3 fragment with no module: rc 1, named" || bad "S3 fragment with no module: rc $rc $(cat "$T/s3b.err")"
[ -e "$S/src/routes.gen.js" ] && bad "S3 a refused run wrote src/routes.gen.js" || ok "S3 still no output file"

echo "S4: wrangler build.command and the #routes import map"
cmd=$(node -e '
  const fs = require("fs");
  const t = fs.readFileSync(process.argv[1], "utf8").replace(/^\s*\/\/.*$/gm, "");
  const w = JSON.parse(t);
  process.stdout.write(String(w.build && w.build.command || ""));' "$DIR/worker/jobs/wrangler.jsonc" 2>&1)
case "$cmd" in
  *"node scripts/routes-build.mjs"*) ok "S4 build.command: $cmd" ;;
  *) bad "S4 wrangler.jsonc build.command is '$cmd', want it to run scripts/routes-build.mjs" ;;
esac
node -e '
  const p = require(process.argv[1]);
  const r = p.imports && p.imports["#routes"];
  process.exit(r && r.workerd === "./src/routes.gen.js" && r.default === "./test/lib/routes.node.js" ? 0 : 1);' \
  "$DIR/worker/jobs/package.json" && ok "S4 package.json maps #routes" || bad "S4 package.json has no #routes workerd/default map"

echo "S5: git-ignored"
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$DIR" check-ignore -q --no-index worker/jobs/src/routes.gen.js && ok "S5 routes.gen.js is ignored" \
    || bad "S5 worker/jobs/src/routes.gen.js is not in .gitignore"
  [ -z "$(git -C "$DIR" ls-files worker/jobs/src/routes.gen.js)" ] && ok "S5 routes.gen.js is not tracked" \
    || bad "S5 worker/jobs/src/routes.gen.js is tracked"
else
  ok "S5 not a git checkout: nothing to check"
fi

echo "S6: the node suite"
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 || bad "S6 catalog/lanes.json could not be composed"
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
if OUT=$(cd "$DIR/worker/jobs" && node --test test/route-registry.bh-4607.test.js 2>&1); then
  ok "S6 node --test test/route-registry.bh-4607.test.js"
else
  bad "S6 node --test test/route-registry.bh-4607.test.js failed:"
  printf '%s\n' "$OUT" | grep -E '^not ok|Error|assert' | head -20
fi

echo "S7: mutation — a hand registration comes back"
M="$T/s7"
mkdir -p "$M/worker" "$M/catalog"
cp -R "$DIR/worker/jobs" "$M/worker/jobs"
scratch_rm "$M/worker/jobs/node_modules"; scratch_rm "$M/worker/jobs/src/routes.gen.js"
cp -R "$DIR/agent-core" "$M/agent-core"
cp "$DIR"/catalog/lanes.json "$DIR"/catalog/llm-sites.json "$DIR"/catalog/context-budgets.json "$DIR"/catalog/prompt-markers.json "$M/catalog/"
sed -i '0,/^import { routes as webhooks }/s//import { routes as capFlags } from ".\/routes\/cap-flags.js";\n&/' \
  "$M/worker/jobs/src/index.js"
grep -q '^import { routes as capFlags } from "./routes/cap-flags.js";$' "$M/worker/jobs/src/index.js" \
  && ok "S7 the mutation is in place" || bad "S7 the sed did not add the import"
OUT=$(cd "$M/worker/jobs" && node --test --test-name-pattern='^N4 ' test/route-registry.bh-4607.test.js 2>&1); rc=$?
[ "$rc" != 0 ] && grep -q '^not ok .* N4 GUARDRAIL' <<<"$OUT" \
  && ok "S7 N4 goes red on a gated import in index.js" || bad "S7 N4 stayed green (rc $rc)"

echo "worker-routes-render: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
