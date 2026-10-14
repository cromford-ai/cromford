#!/bin/bash
# tests/coord-writes-fragments.bh-6487-test.sh — the coord proxy's write table
# grows by fragment (BH-6487, item 3 of #4987).
#
# Every console write route was one row appended before the `];` of WRITES in
# console-ui/functions/api/coord/[[path]].js, so two branches that each added
# a route conflicted on the same hunk. A new row is now a file,
# console-ui/functions/_lib/coord-writes.d/<NNNN>-<slug>.js. Node composes the
# directory through console-ui/tests/lib/coord-writes.node.js; the Pages bundle
# imports console-ui/functions/_lib/coord-writes.gen.js, which
# console-ui/scripts/coord-writes-build.mjs renders and git ignores.
#
#   S0  the old shape: two branches that each append a WRITES row conflict
#   S2  two branches that each add a fragment merge clean; the loader lists
#       steer, fixture-a, fixture-b in that order
#   S3  the generator: the GENERATED line, one import per fragment; a second
#       run with the same bytes leaves the mtime alone
#   S4  the hand-edit guard: the gen file is ignored and untracked; a stray
#       fragment name is exit 1, one coord-writes-build: line, no file, no tmp
#   S5  the round trip: the rendered module gives the loader's (method, path)
#   S6  the ratchet: the in-file WRITES literal does not grow past 37 rows
#   D1  cpv_coord_writes on a sha with no generator: rc 0, tree unchanged
#   D2  the real bin/console-postmerge-qa.sh deploys a tree that carries the
#       rendered table and package.json
#   D3  the same with a stray fragment: NOT_COVERED, no upload
#   D4  cpv_coord_writes when the sha has no console-ui/package.json: rc 1
#   D5  cpv_coord_writes with a duplicate (method, path) fragment: rc 1
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/coord-writes-fragments.bh-6487-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in git node jq flock timeout; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

PROXY="$DIR/console-ui/functions/api/coord/[[path]].js"
GEN="$DIR/console-ui/scripts/coord-writes-build.mjs"
LIB="$DIR/console-ui/functions/_lib/coord-writes.js"
COMPOSE="$DIR/console-ui/functions/_lib/coord-writes-compose.js"
FRAGS="$DIR/console-ui/functions/_lib/coord-writes.d"
STEER="$DIR/console-ui/functions/_lib/coord-writes.d/5839-steer.js"
LOADER="$DIR/console-ui/tests/lib/coord-writes.node.js"
CPV="$DIR/bin/lib/console-preview.sh"
for f in "$PROXY" "$GEN" "$LIB" "$COMPOSE" "$STEER" "$LOADER" "$CPV"; do
  [ -f "$f" ] && ok || bad "missing: ${f#"$DIR"/}"
done

# cu_copy <dest> — a scratch console-ui with the files the table needs.
cu_copy() {
  mkdir -p "$1/functions" "$1/tests" || return 1
  cp "$DIR/console-ui/package.json" "$1/" && cp -R "$DIR/console-ui/scripts" "$1/" \
    && cp -R "$DIR/console-ui/functions/_lib" "$1/functions/" && cp -R "$DIR/console-ui/tests/lib" "$1/tests/" \
    && rm -f "$1/functions/_lib/coord-writes.gen.js"
}
# paths_of <module> <export> — one "<METHOD> <path>" line per row.
paths_of() {
  node --input-type=module -e "
const m = await import(process.argv[1]);
for (const w of m[process.argv[2]]) console.log(w.method + ' ' + (typeof w.path === 'function' ? 'fn' : w.path));
" "$1" "$2"
}
frag() { printf "export default [\n  { method: '%s', path: '%s', body: ['a'] }\n];\n" "$2" "$3" > "$1"; }

# ── S0: the old shape conflicts ──────────────────────────────────────────────
R="$T/s0"; git init -q -b main "$R"; mkdir -p "$R/c"
cp "$PROXY" "$R/c/p.js"; git -C "$R" add -A; git -C "$R" commit -qm base
grep -q '^const WRITES = \[' "$R/c/p.js" || bad "S0 the proxy has no 'const WRITES = [' line"
append_row() { # append_row <file> <path> — one row before the `];` that closes WRITES
  awk -v p="$2" '/^const WRITES = \[/{w=1} w && /^\];/{print "  { method: '\''POST'\'', path: '\''" p "'\'', body: [] },"; w=0} {print}' "$1" > "$1.n" && mv "$1.n" "$1"
}
git -C "$R" checkout -q -b a; append_row "$R/c/p.js" fixture-a; git -C "$R" commit -qam a
git -C "$R" checkout -q main; git -C "$R" checkout -q -b b; append_row "$R/c/p.js" fixture-b; git -C "$R" commit -qam b
git -C "$R" merge -q a -m m >/dev/null 2>&1; mrc=$?
[ "$mrc" != 0 ] && [ "$(git -C "$R" diff --name-only --diff-filter=U)" = c/p.js ] \
  && ok || bad "S0 appending to WRITES on two branches must conflict on c/p.js (merge rc=$mrc)"

# ── S2: two fragments merge clean ────────────────────────────────────────────
R="$T/s2"; git init -q -b main "$R"; cu_copy "$R/console-ui" || bad "S2 copy"
git -C "$R" add -A; git -C "$R" commit -qm base
git -C "$R" checkout -q -b a; frag "$R/console-ui/functions/_lib/coord-writes.d/9001-fixture-a.js" POST fixture-a
git -C "$R" add -A; git -C "$R" commit -qm a
git -C "$R" checkout -q main; git -C "$R" checkout -q -b b; frag "$R/console-ui/functions/_lib/coord-writes.d/9002-fixture-b.js" POST fixture-b
git -C "$R" add -A; git -C "$R" commit -qm b
git -C "$R" merge -q a -m m >/dev/null 2>&1; mrc=$?
[ "$mrc" = 0 ] && [ -z "$(git -C "$R" diff --name-only --diff-filter=U)" ] && ok || bad "S2 two fragments must merge clean (rc=$mrc)"
got=$(paths_of "$R/console-ui/tests/lib/coord-writes.node.js" FRAGMENT_WRITES 2>&1 | tr '\n' ' ')
[ "$got" = "POST steer POST fixture-a POST fixture-b " ] && ok || bad "S2 loader order: '$got'"

# ── S3: the generator ────────────────────────────────────────────────────────
S="$T/s3"; cu_copy "$S" || bad "S3 copy"
OUTG="$S/functions/_lib/coord-writes.gen.js"
( cd "$S" && node scripts/coord-writes-build.mjs ) > "$T/s3.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/s3.out" ] && [ -f "$OUTG" ] && ok || bad "S3 first render rc=$rc $(cat "$T/s3.out")"
head -n 1 "$OUTG" | grep -qx '// GENERATED from functions/_lib/coord-writes.d/ by scripts/coord-writes-build.mjs. Do not edit; add a fragment.' \
  && ok || bad "S3 GENERATED line: $(head -n 1 "$OUTG")"
nf=$(find "$S/functions/_lib/coord-writes.d" -maxdepth 1 -name '*.js' | wc -l)
ni=$(grep -c "^import f[0-9]* from './coord-writes.d/" "$OUTG")
[ "$nf" -ge 1 ] && [ "$ni" = "$nf" ] && ok || bad "S3 $ni imports for $nf fragments"
grep -qx "import f0 from './coord-writes.d/5839-steer.js';" "$OUTG" && ok || bad "S3 the steer import"
touch -d '2001-01-01 00:00:00' "$OUTG"
( cd "$S" && node scripts/coord-writes-build.mjs ) >/dev/null 2>&1
[ "$(date -u -r "$OUTG" +%Y)" = 2001 ] && ok || bad "S3 a same-bytes render rewrote the file"
node "$S/scripts/coord-writes-build.mjs" --print > "$T/s3.print" 2>&1 && cmp -s "$T/s3.print" "$OUTG" && ok || bad "S3 --print differs from the file"

# ── S4: the hand-edit guard ──────────────────────────────────────────────────
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$DIR" ls-files --error-unmatch console-ui/functions/_lib/coord-writes.gen.js >/dev/null 2>&1 \
    && bad "S4 coord-writes.gen.js is tracked: it is generated (BH-1175), add a fragment instead" || ok
  git -C "$DIR" check-ignore -q console-ui/functions/_lib/coord-writes.gen.js && ok || bad "S4 .gitignore must ignore console-ui/functions/_lib/coord-writes.gen.js"
else
  echo "coord-writes-fragments: S4 git checks SKIPPED — not a git checkout"
fi
rm -f "$OUTG"; frag "$S/functions/_lib/coord-writes.d/steer.js" POST stray
( cd "$S" && node scripts/coord-writes-build.mjs ) > "$T/s4.out" 2> "$T/s4.err"; rc=$?
[ "$rc" = 1 ] && ok || bad "S4 a stray fragment name must be exit 1, got $rc"
[ "$(wc -l < "$T/s4.err")" = 1 ] && grep -qx 'coord-writes-build: coord-writes.d/steer.js is not a fragment name (NNNN-<slug>.js)' "$T/s4.err" \
  && ok || bad "S4 stderr: $(cat "$T/s4.err")"
[ ! -e "$OUTG" ] && ok || bad "S4 a failed render left $OUTG"
ls "$S/functions/_lib/"*.tmp >/dev/null 2>&1 && bad "S4 a failed render left a .tmp" || ok
rm -f "$S/functions/_lib/coord-writes.d/steer.js"

# ── S5: the round trip ───────────────────────────────────────────────────────
frag "$S/functions/_lib/coord-writes.d/9001-fixture-a.js" PUT fixture-a
( cd "$S" && node scripts/coord-writes-build.mjs ) >/dev/null 2>&1 || bad "S5 render"
g=$(paths_of "$OUTG" FRAGMENT_WRITES 2>&1); l=$(paths_of "$S/tests/lib/coord-writes.node.js" FRAGMENT_WRITES 2>&1)
[ "$g" = "$l" ] && [ "$(printf '%s\n' "$g" | tr '\n' ' ')" = "POST steer PUT fixture-a " ] && ok || bad "S5 gen '$g' vs loader '$l'"

# ── S6: the in-file table does not grow ──────────────────────────────────────
rows=$(awk '/^const WRITES = \[/{w=1; s=1; next} w && /^\];/{w=0} w && /^[[:space:]]*\{ method:/{n++} END{if (!s) print "none"; else print n+0}' "$PROXY")
if [ "$rows" = none ]; then bad "S6 no 'const WRITES = [' in the proxy"
elif [ "$rows" -le 37 ]; then ok
else bad "S6 WRITES has $rows rows (max 37): add a new write route as console-ui/functions/_lib/coord-writes.d/<NNNN>-<slug>.js"
fi

# ── D: cpv_coord_writes and the post-merge deploy tree ───────────────────────
CK="$T/ck"; git init -q -b main "$CK"
mkdir -p "$CK/console-ui/src" "$CK/console-ui/functions/api" "$CK/worker/jobs"
echo '{"name":"console-ui"}' > "$CK/console-ui/package.json"
echo 'export const who = "legacy";' > "$CK/console-ui/functions/api/f.js"
echo 'export const a = 1;' > "$CK/console-ui/src/app.js"
echo '{ "account_id": "acct-fixture" }' > "$CK/worker/jobs/wrangler.jsonc"
git -C "$CK" add -A; git -C "$CK" commit -qm legacy; SL=$(git -C "$CK" rev-parse HEAD)
rm -f "$CK/console-ui/package.json"; cp -R "$DIR/console-ui/scripts" "$CK/console-ui/"
cp -R "$DIR/console-ui/functions/_lib" "$CK/console-ui/functions/"; rm -f "$CK/console-ui/functions/_lib/coord-writes.gen.js"
git -C "$CK" add -A; git -C "$CK" commit -qm nopkg; SN=$(git -C "$CK" rev-parse HEAD)
cp "$DIR/console-ui/package.json" "$CK/console-ui/"
git -C "$CK" add -A; git -C "$CK" commit -qm good; SG=$(git -C "$CK" rev-parse HEAD)
frag "$CK/console-ui/functions/_lib/coord-writes.d/9001-dup.js" POST steer
git -C "$CK" add -A; git -C "$CK" commit -qm dup; SD=$(git -C "$CK" rev-parse HEAD)
git -C "$CK" rm -q console-ui/functions/_lib/coord-writes.d/9001-dup.js
frag "$CK/console-ui/functions/_lib/coord-writes.d/steer.js" POST stray
git -C "$CK" add -A; git -C "$CK" commit -qm stray; SS=$(git -C "$CK" rev-parse HEAD)
git -C "$CK" reset -q --hard "$SG"

# cw <sha> — the functions archive, then cpv_coord_writes; sets CW_RC, CW_TREE.
cw() {
  CW_TREE=$(mktemp -d "$T/cw.XXXXXX")
  git -C "$CK" archive "$1" console-ui/functions console-ui/src | tar -x -C "$CW_TREE"
  ( HARNESS="$DIR"; . "$CPV" || exit 9; cpv_coord_writes "$CK" "$1" "$CW_TREE" ) > "$T/cw.out" 2>&1; CW_RC=$?
}
cw "$SL"
[ "$CW_RC" = 0 ] && [ ! -e "$CW_TREE/console-ui/scripts" ] && [ ! -e "$CW_TREE/console-ui/package.json" ] \
  && [ ! -s "$T/cw.out" ] && ok || bad "D1 legacy sha: rc=$CW_RC $(ls -A "$CW_TREE/console-ui") $(cat "$T/cw.out")"
cw "$SG"
[ "$CW_RC" = 0 ] && [ -f "$CW_TREE/console-ui/functions/_lib/coord-writes.gen.js" ] && [ -f "$CW_TREE/console-ui/package.json" ] \
  && ok || bad "D1 a sha with the generator: rc=$CW_RC $(cat "$T/cw.out")"
cw "$SN"
[ "$CW_RC" = 1 ] && [ -s "$T/cw.out" ] && ok || bad "D4 no package.json at the sha must be rc 1, got $CW_RC $(cat "$T/cw.out")"
cw "$SD"
[ "$CW_RC" = 1 ] && grep -q 'POST steer is a write row twice' "$T/cw.out" && [ ! -e "$CW_TREE/console-ui/functions/_lib/coord-writes.gen.js" ] \
  && ok || bad "D5 a duplicate row must be rc 1, got $CW_RC $(cat "$T/cw.out")"

HB="$T/h"; QD="$HB/state/console-postmerge-qa"
mkdir -p "$HB/env" "$HB/logs" "$HB/state" "$HB/locks" "$T/sbin"
scratch_install_closure bin/console-postmerge-qa.sh "$HB" >/dev/null || bad "closure of bin/console-postmerge-qa.sh"
[ -f "$HB/bin/lib/console-preview.sh" ] && ok || bad "the closure does not carry bin/lib/console-preview.sh"
printf 'CLOUDFLARE_API_TOKEN=tok-fixture-6487\n' > "$HB/env/cloudflare.env"
printf '#!/bin/bash\nprintf "alert %%s\\n" "$*" >> "%s/calls.log"\n' "$T" > "$HB/bin/lane-alert.sh"
printf '#!/bin/bash\nexit 1\n' > "$HB/bin/jobs-client.sh"
# npx (wrangler): records the deploy tree, then fails the upload so the run
# stops before the QA drive.
cat > "$T/sbin/npx" <<EOF
#!/bin/bash
printf 'npx %s\n' "\$*" >> "$T/calls.log"
printf 'npxtree pkg=%s gen=%s steer=%s\n' "\$([ -f package.json ] && echo y || echo n)" \
  "\$([ -f functions/_lib/coord-writes.gen.js ] && echo y || echo n)" \
  "\$(grep -c "coord-writes.d/5839-steer.js" functions/_lib/coord-writes.gen.js 2>/dev/null)" >> "$T/calls.log"
echo "✘ [ERROR] stub upload"; exit 1
EOF
chmod +x "$T/sbin/npx" "$HB/bin/lane-alert.sh" "$HB/bin/jobs-client.sh"
runq() { # runq <sha>
  rm -f "$T/calls.log"; touch "$T/calls.log"; scratch_rm "$QD"; mkdir -p "$QD/dist-$1"; echo '<html/>' > "$QD/dist-$1/index.html"
  ( cd "$T" && env -u CLOUDFLARE_API_TOKEN -u HARNESS_REPO HARNESS="$HB" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$HB/env" \
      PATH="$T/sbin:$PATH" TMPDIR="$T" CONSOLE_PAGES_URL=https://pages-fixture.example.invalid CONSOLE_POSTMERGE_QA=1 \
      bash "$HB/bin/console-postmerge-qa.sh" "$1" "$QD/dist-$1" ) > "$T/out" 2>&1
}
runq "$SG"
grep -qx 'npxtree pkg=y gen=y steer=1' "$T/calls.log" && ok || bad "D2 the deploy tree: $(grep npxtree "$T/calls.log") $(cat "$T/out")"
runq "$SS"
grep -q 'NOT_COVERED deploy tree failed (coord write table: ' "$QD/$SS/verdict" 2>/dev/null \
  && ok || bad "D3 verdict: '$(cat "$QD/$SS/verdict" 2>/dev/null)' $(cat "$T/out")"
grep -q '^npx' "$T/calls.log" && bad "D3 a failed render still uploaded" || ok

echo "coord-writes-fragments: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
