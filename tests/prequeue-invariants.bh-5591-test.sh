#!/bin/bash
# tests/prequeue-invariants.bh-5591-test.sh — BH-5591: the pre-queue gate runs
# bin/render-doc-sections.sh --check and the three jobs-worker schema tests.
#
# Merge batch #5584 (2026-10-08) went red on two whole-tree checks that were not
# in catalog/prequeue-invariants.tsv: a stale docs/PR-OWNERSHIP.d/ against a
# changed docs/PR-OWNERSHIP.md (#5297), and two PRs that each added to
# worker/jobs/schema.sql (#4744 + #5287). Each head passed the gate alone.
#
#   I1      the catalog carries render-doc-sections (cmd, --check)
#   I2      the catalog carries worker-jobs-schema with the three test files
#   I3      a 10-line source-doc drift: the real row is red, fail text starts DRIFT
#   I3g     the same fixture, unmodified: green
#   I3b     a changed fragment, doc untouched: red, DRIFT
#   I3d     a fragment with no trailing newline: red, the fail text names it
#   I3f     the runner's fail text: FAIL lines win over DRIFT; neither = last 8
#   W1-W9   bin/prequeue-worker-schema.sh with stub node/npm: verdicts, argv,
#           refusals, early exits, nothing left in the tree
#   I5/I5b  real node, the real row, on a scratch worker: green; red on 'drop'
#   I6      both real rows on a scratch copy of this tree: green
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-invariants.bh-5591-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

CATALOG="$DIR/catalog/prequeue-invariants.tsv"
WRAP_REL=bin/prequeue-worker-schema.sh
TESTS3="worker/jobs/test/machines-schema.bh-1054.test.js worker/jobs/test/model-routes.bh-1510.test.js worker/jobs/test/schema-deploy-queue.bh-1026.test.js"
has() { [[ "$1" == *"$2"* ]]; }
rc() { cat "$T/$1.rc" 2>/dev/null; }

# Real node with node:sqlite, for I5/I6. On CI its absence is a failure, never a skip.
NODE_OK=""
if command -v node >/dev/null && node -e "require('node:sqlite')" >/dev/null 2>&1; then NODE_OK=1
elif [ -n "${CI:-}" ]; then bad "setup: CI has no node with node:sqlite"
else echo "note: no node with node:sqlite — I5/I6 skipped"; fi

# ============================================================================
# I1/I2. The real catalog, as the runner resolves it.
# ============================================================================
LIST=$(bash "$DIR/bin/prequeue-invariants.sh" --list --catalog "$CATALOG" 2>&1); LRC=$?
[ "$LRC" = 0 ] && ok || bad "I1/I2: --list on the real catalog exits 0 (rc $LRC: $LIST)"
[ "$(awk -F'\t' '$1 == "render-doc-sections" { print $2 "|" $3 }' <<<"$LIST")" = "cmd|bin/render-doc-sections.sh --check" ] && ok \
  || bad "I1: the catalog runs render-doc-sections as cmd bin/render-doc-sections.sh --check"
[ -f "$DIR/bin/render-doc-sections.sh" ] && ok || bad "I1: bin/render-doc-sections.sh exists"
WROW=$(awk -F'\t' '$1 == "worker-jobs-schema" { print $2 "|" $3 }' <<<"$LIST")
WARGV="${WROW#*|}"
[ "${WROW%%|*}" = cmd ] && [ "${WARGV%% *}" = "$WRAP_REL" ] && ok \
  || bad "I2: worker-jobs-schema is a cmd row whose argv[0] is $WRAP_REL (got '$WROW')"
for f in $TESTS3; do
  [[ " $WARGV " == *" $f "* ]] && ok || bad "I2: the worker-jobs-schema argv names $f"
  [ -f "$DIR/$f" ] && ok || bad "I2: $f exists"
done
[ -f "$DIR/bin/prequeue-worker-schema.sh" ] && ok || bad "I2: $WRAP_REL exists"

# ============================================================================
# I3. The real render-doc-sections row, through the real runner, on a scratch
# git tree that carries a sectioned docs/PR-OWNERSHIP.md.
# ============================================================================
RD="$T/rd"; mkdir -p "$RD/docs/PR-OWNERSHIP.d"
for s in bin/prequeue-invariants.sh bin/test-suite-run.sh bin/render-doc-sections.sh; do
  scratch_install_closure "$s" "$RD" >/dev/null || bad "I3 setup: could not install $s"
done
printf '# PR ownership\n\nIntro line.\n\n' > "$RD/docs/PR-OWNERSHIP.d/00-intro.md"
for i in 1 2 3 4 5 6; do printf '| row %s | owner %s |\n' "$i" "$i"; done > "$RD/docs/PR-OWNERSHIP.d/01-rows.md"
# Two stub cmd rows for I3f: one prints DRIFT and FAIL, one prints neither.
printf '#!/bin/bash\necho "DRIFT docs/x.md"\necho "- a diff line"\necho "FAIL: both one"\nexit 1\n' > "$RD/bin/pq-both.sh"
printf '#!/bin/bash\nfor i in $(seq 1 12); do echo "n$i"; done\nexit 1\n' > "$RD/bin/pq-neither.sh"
( cd "$RD" && bash bin/render-doc-sections.sh --write ) || bad "I3 setup: the fixture doc does not render"
rg() { git -C "$RD" -c user.email=t@example.com -c user.name=t "$@"; }
rg init -q; rg add -A; rg commit -qm base --no-verify
grep -P '^render-doc-sections\t' "$CATALOG" > "$T/rd.tsv"
# rdrun <case> [catalog] — the scratch runner on the scratch tree, then reset it.
rdrun() {
  ( cd "$T" && env -u PQ_MAIN -u RATCHET_BASE bash "$RD/bin/prequeue-invariants.sh" --run --catalog "${2:-$T/rd.tsv}" --out "$T/$1.d" ) > "$T/$1.out" 2> "$T/$1.err"
  echo $? > "$T/$1.rc"
  rg checkout -q -- .; rg clean -qfd
}
rdfail() { cat "$T/$1.d/fail/render-doc-sections.txt" 2>/dev/null; }

# I3g. Unmodified: green.
rdrun i3g
[ "$(rc i3g)" = 0 ] && [ -f "$T/i3g.d/failed.txt" ] && [ ! -s "$T/i3g.d/failed.txt" ] && ok \
  || bad "I3g: the clean fixture is green (rc $(rc i3g): $(cat "$T/i3g.out" "$T/i3g.err"))"

# I3. The source doc changed by 10 lines, the fragments did not (the #5297 shape).
for i in $(seq 1 10); do echo "| hand row $i | nobody |"; done >> "$RD/docs/PR-OWNERSHIP.md"
rdrun i3
[ "$(rc i3)" = 1 ] && ok || bad "I3: a drifted doc makes the gate red (rc $(rc i3): $(cat "$T/i3.err"))"
[ "$(cat "$T/i3.d/failed.txt" 2>/dev/null)" = render-doc-sections ] && ok \
  || bad "I3: failed.txt names render-doc-sections (got '$(cat "$T/i3.d/failed.txt" 2>/dev/null)')"
grep -q '^prequeue-invariant: render-doc-sections rc=1 ' "$T/i3.out" && ok \
  || bad "I3: the summary line names render-doc-sections rc=1 (got $(cat "$T/i3.out"))"
[ "$(rdfail i3 | head -n1)" = "DRIFT docs/PR-OWNERSHIP.md" ] && ok \
  || bad "I3: fail/render-doc-sections.txt starts with DRIFT docs/PR-OWNERSHIP.md (got: $(rdfail i3 | head -n3))"
[ "$(rdfail i3 | wc -l)" -le 8 ] && rdfail i3 | grep -q 'hand row 1 ' && ok \
  || bad "I3: the fail text is at most 8 lines and carries the first diff lines (got: $(rdfail i3))"

# I3b. A fragment changed, the doc did not.
sed -i 's/| row 3 |/| row three |/' "$RD/docs/PR-OWNERSHIP.d/01-rows.md"
rdrun i3b
[ "$(rc i3b)" = 1 ] && [ "$(rdfail i3b | head -n1)" = "DRIFT docs/PR-OWNERSHIP.md" ] && ok \
  || bad "I3b: a changed fragment is red and names DRIFT docs/PR-OWNERSHIP.md (rc $(rc i3b): $(rdfail i3b))"

# I3d. A bad fragment: no trailing newline (render-doc-sections rc 3).
printf '| no newline |' > "$RD/docs/PR-OWNERSHIP.d/02-bad.md"
rdrun i3d
[ "$(rc i3d)" = 1 ] && rdfail i3d | grep -q 'docs/PR-OWNERSHIP.d/02-bad.md' && ok \
  || bad "I3d: a fragment with no newline is red and the fail text names it (rc $(rc i3d): $(rdfail i3d))"

# I3f. The fail-text rule: FAIL lines win over DRIFT; a row with neither gives its last 8.
printf 'both\tcmd\tbin/pq-both.sh\t5\tstub\nneither\tcmd\tbin/pq-neither.sh\t5\tstub\n' > "$T/i3f.tsv"
rdrun i3f "$T/i3f.tsv"
[ "$(rc i3f)" = 1 ] && [ "$(cat "$T/i3f.d/fail/both.txt" 2>/dev/null)" = "FAIL: both one" ] && ok \
  || bad "I3f: a row with FAIL and DRIFT reports the FAIL line only (got: $(cat "$T/i3f.d/fail/both.txt" 2>/dev/null))"
[ "$(cat "$T/i3f.d/fail/neither.txt" 2>/dev/null | tr '\n' ' ')" = "n5 n6 n7 n8 n9 n10 n11 n12 " ] && ok \
  || bad "I3f: a row with neither reports its last 8 lines (got: $(cat "$T/i3f.d/fail/neither.txt" 2>/dev/null | tr '\n' ' '))"

# ============================================================================
# W1-W9. The wrapper with stub node and npm on PATH.
# ============================================================================
W="$T/w"; mkdir -p "$W/worker/jobs/test" "$T/stub"
if [ -f "$DIR/$WRAP_REL" ]; then
  scratch_install_closure "$WRAP_REL" "$W" >/dev/null || bad "W setup: could not install $WRAP_REL"
else
  bad "W setup: $WRAP_REL is missing"
fi
for f in $TESTS3; do : > "$W/$f"; done
printf 'node_modules/\ncatalog/lanes.json\n' > "$W/.gitignore"
wg() { git -C "$W" -c user.email=t@example.com -c user.name=t "$@"; }
wg init -q; wg add -A; wg commit -qm base --no-verify
# The stubs record argv and cwd. npm makes a node_modules/ like a real install.
cat > "$T/stub/npm" <<EOF
#!/bin/bash
printf '%s\t%s\n' "\$PWD" "\$*" >> "$T/calls.npm"
mkdir -p node_modules && : > node_modules/.stub
exit "\${STUB_NPM_RC:-0}"
EOF
cat > "$T/stub/node" <<EOF
#!/bin/bash
printf '%s\t%s\n' "\$PWD" "\$*" >> "$T/calls.node"
[ -n "\${STUB_NODE_OUT:-}" ] && cat "\$STUB_NODE_OUT"
exit "\${STUB_NODE_RC:-0}"
EOF
chmod +x "$T/stub/npm" "$T/stub/node"
# I5/I6 run real node: their PATH gets the npm stub alone.
mkdir -p "$T/npmonly" && cp "$T/stub/npm" "$T/npmonly/npm"
# wrap <case> [args...] — the wrapper in $W with the stubs; $T/<case>.{out,rc}.
wrap() {
  local c="$1"; shift
  rm -f "$T/calls.npm" "$T/calls.node"
  ( cd "$W" && PATH="$T/stub:$PATH" bash "$WRAP_REL" "$@" ) > "$T/$c.out" 2>&1
  echo $? > "$T/$c.rc"
  [ -f "$T/calls.npm" ] && cp "$T/calls.npm" "$T/$c.npm"
  [ -f "$T/calls.node" ] && cp "$T/calls.node" "$T/$c.node"
}
tap() { # tap <file> <pass> <skipped> [extra lines...]
  local f="$1" p="$2" s="$3"; shift 3
  { echo "TAP version 13"; printf '%s\n' "$@"
    [ "$p" = none ] || printf '# tests %s\n# pass %s\n# fail 0\n# skipped %s\n# todo 0\n' "$p" "$p" "$s"; } > "$f"
}
nfail() { grep -c '^FAIL' "$T/$1.out"; }
# shellcheck disable=SC2086
set -- $TESTS3

# W1. All green: rc 0, no FAIL line, the summary line; the npm and node argv.
tap "$T/w1.tap" 3 0 "ok 1 - a" "ok 2 - b" "ok 3 - c"
STUB_NODE_OUT="$T/w1.tap" STUB_NODE_RC=0 wrap w1 "$@"
[ "$(rc w1)" = 0 ] && [ "$(nfail w1)" = 0 ] && ok || bad "W1: a green run is rc 0 with no FAIL line (rc $(rc w1): $(cat "$T/w1.out"))"
[ "$(tail -n1 "$T/w1.out")" = "worker-schema: rc=0 pass=3 skipped=0" ] && ok \
  || bad "W1: the last line is the summary (got '$(tail -n1 "$T/w1.out")')"
[ "$(cut -f2 "$T/w1.npm" 2>/dev/null)" = "ci --no-audit --no-fund" ] && [[ "$(cut -f1 "$T/w1.npm" 2>/dev/null)" == */worker/jobs ]] && ok \
  || bad "W1: npm ran 'ci --no-audit --no-fund' in worker/jobs (got '$(cat "$T/w1.npm" 2>/dev/null)')"
[ "$(cut -f2 "$T/w1.node" 2>/dev/null)" = "--test --test-reporter=tap ${TESTS3//worker\/jobs\//}" ] && [[ "$(cut -f1 "$T/w1.node" 2>/dev/null)" == */worker/jobs ]] && ok \
  || bad "W1: node ran --test --test-reporter=tap and the three files in order, in worker/jobs (got '$(cat "$T/w1.node" 2>/dev/null)')"
# W9. Nothing left in the tree but ignored paths.
[ -f "$W/worker/jobs/node_modules/.stub" ] && [ -z "$(wg status --porcelain)" ] && ok \
  || bad "W9: the run leaves only ignored paths (status: $(wg status --porcelain | tr '\n' ' '))"

# W2. One top-level failure plus an indented subtest failure: one FAIL line.
tap "$T/w2.tap" none 0 "# Subtest: a test" "    not ok 1 - sub" "not ok 2 - a test" "ok 3 - fine"
printf '# tests 3\n# pass 1\n# fail 2\n# skipped 0\n' >> "$T/w2.tap"
STUB_NODE_OUT="$T/w2.tap" STUB_NODE_RC=1 wrap w2 "$@"
[ "$(rc w2)" = 1 ] && [ "$(grep '^FAIL' "$T/w2.out")" = "FAIL: worker-schema: a test" ] && ok \
  || bad "W2: a red run is rc 1 with exactly 'FAIL: worker-schema: a test' (rc $(rc w2): $(grep '^FAIL' "$T/w2.out"))"

# W3. Green but one skip: red, and the FAIL line says skipped.
tap "$T/w3.tap" 2 1 "ok 1 - a" "ok 2 - b # SKIP"
STUB_NODE_OUT="$T/w3.tap" STUB_NODE_RC=0 wrap w3 "$@"
[ "$(rc w3)" = 1 ] && grep '^FAIL' "$T/w3.out" | grep -q skipped && ok \
  || bad "W3: a skip is never green (rc $(rc w3): $(cat "$T/w3.out"))"

# W4. pass 0: red.
tap "$T/w4.tap" 0 0
STUB_NODE_OUT="$T/w4.tap" STUB_NODE_RC=0 wrap w4 "$@"
[ "$(rc w4)" = 1 ] && [ "$(nfail w4)" -ge 1 ] && ok || bad "W4: pass 0 is red (rc $(rc w4): $(cat "$T/w4.out"))"

# W5. No summary: red.
tap "$T/w5.tap" none 0 "ok 1 - a"
STUB_NODE_OUT="$T/w5.tap" STUB_NODE_RC=0 wrap w5 "$@"
[ "$(rc w5)" = 1 ] && [ "$(nfail w5)" -ge 1 ] && ok || bad "W5: no tap summary is red (rc $(rc w5): $(cat "$T/w5.out"))"

# W6. npm ci fails: red, and node never runs.
STUB_NPM_RC=1 STUB_NODE_OUT="$T/w1.tap" wrap w6 "$@"
[ "$(rc w6)" = 1 ] && grep -qx 'FAIL: worker-schema: npm ci in worker/jobs failed' "$T/w6.out" && ok \
  || bad "W6: a failed npm ci is rc 1 with its FAIL line (rc $(rc w6): $(cat "$T/w6.out"))"
[ ! -f "$T/w6.node" ] && ok || bad "W6: node never runs after a failed npm ci"

# W7. A missing test file: red, names it, npm never runs.
STUB_NODE_OUT="$T/w1.tap" wrap w7 "$1" worker/jobs/test/gone.bh-0.test.js
[ "$(rc w7)" = 1 ] && grep '^FAIL' "$T/w7.out" | grep -q 'worker/jobs/test/gone.bh-0.test.js' && ok \
  || bad "W7: a missing file is rc 1 and named (rc $(rc w7): $(cat "$T/w7.out"))"
[ ! -f "$T/w7.npm" ] && [ ! -f "$T/w7.node" ] && ok || bad "W7: neither npm nor node runs for a missing file"

# W8. Refusals: rc 2, nothing runs.
wrap w8a
wrap w8b tests/x.test.js
wrap w8c worker/jobs/test/../x.test.js
for c in w8a w8b w8c; do
  [ "$(rc $c)" = 2 ] && [ ! -f "$T/$c.npm" ] && [ ! -f "$T/$c.node" ] && ok \
    || bad "$c: a refused argument list is rc 2 and runs nothing (rc $(rc $c): $(cat "$T/$c.out"))"
done
grep -qx 'FAIL: worker-schema: no test file named' "$T/w8a.out" && ok || bad "W8: no argument says so (got $(cat "$T/w8a.out"))"
set --

# ============================================================================
# I5/I5b. Real node, stub npm, the real worker-jobs-schema row, the real runner.
# ============================================================================
if [ -n "$NODE_OK" ]; then
  V="$T/v"; mkdir -p "$V/worker/jobs" "$V/catalog"
  for s in bin/prequeue-invariants.sh "$WRAP_REL" bin/lanes-build.sh bin/lib/lanes-registry.sh bin/llm-sites-build.sh; do
    [ -f "$DIR/$s" ] || { bad "I5 setup: $s is missing"; continue; }
    scratch_install_closure "$s" "$V" >/dev/null || bad "I5 setup: could not install $s"
  done
  cp -r "$DIR/catalog/lanes.d" "$DIR/catalog/llm-sites.d" "$V/catalog/"
  # What worker/jobs/src imports from outside worker/jobs, catalog/lanes.json
  # and catalog/llm-sites.json (composed from llm-sites.d/, BH-4987) aside.
  cp -r "$DIR/agent-core" "$V/"
  cp "$DIR/catalog/context-budgets.json" "$V/catalog/"
  # TEST-CHANGE (BH-6005.1): the node tests compose the schema from schema.d/
  # (worker/jobs/test/lib/jobs-schema.js), so the fixture copies the fragments.
  # schema.sql is a render the fixture does not need.
  for p in package.json schema.d src test; do cp -r "$DIR/worker/jobs/$p" "$V/worker/jobs/"; done
  # The wrapper on its own renders catalog/lanes.json and composes
  # catalog/llm-sites.json, which the worker imports.
  wrap_v() { ( cd "$V" && PATH="$T/npmonly:$PATH" bash "$WRAP_REL" "$@" ) > "$T/i5a.out" 2>&1; echo $? > "$T/i5a.rc"; }
  # shellcheck disable=SC2086
  wrap_v $TESTS3
  [ "$(rc i5a)" = 0 ] && [ -s "$V/catalog/lanes.json" ] && [ -s "$V/catalog/llm-sites.json" ] && grep -qE '^worker-schema: rc=0 pass=[1-9][0-9]* skipped=0$' "$T/i5a.out" && ok \
    || bad "I5: the wrapper alone, no lanes.json or llm-sites.json first: rc 0, it renders both, real passes (rc $(rc i5a): $(tail -n5 "$T/i5a.out"))"
  grep -P '^worker-jobs-schema\t' "$CATALOG" > "$T/v.tsv"
  vrun() {
    ( cd "$T" && PATH="$T/npmonly:$PATH" env -u PQ_MAIN -u RATCHET_BASE bash "$V/bin/prequeue-invariants.sh" --run --catalog "$T/v.tsv" --out "$T/$1.d" ) > "$T/$1.out" 2> "$T/$1.err"
    echo $? > "$T/$1.rc"
  }
  vrun i5
  [ "$(rc i5)" = 0 ] && grep -q '^prequeue-invariant: worker-jobs-schema rc=0 ' "$T/i5.out" && ok \
    || bad "I5: the real row is green on a clean worker (rc $(rc i5): $(cat "$T/i5.out" "$T/i5.err"; cat "$T/i5.d/fail/worker-jobs-schema.txt" 2>/dev/null))"
  # I5b. The #4744 shape: 'drop' in a DEFAULT.
  # The probe goes in a fragment: that is what the composed schema is made of.
  echo "CREATE TABLE IF NOT EXISTS pq_probe (note TEXT DEFAULT 'drop me');" > "$V/worker/jobs/schema.d/9999-pq-probe.sql"
  vrun i5b
  [ "$(rc i5b)" = 1 ] && [ "$(cat "$T/i5b.d/failed.txt" 2>/dev/null)" = worker-jobs-schema ] && ok \
    || bad "I5b: 'drop' in a schema fragment makes the real row red (rc $(rc i5b): $(cat "$T/i5b.out"))"
  grep -qxF 'FAIL: worker-schema: schema.sql re-applies clean, and carries no ALTER or DROP' "$T/i5b.d/fail/worker-jobs-schema.txt" 2>/dev/null && ok \
    || bad "I5b: fail/worker-jobs-schema.txt names the failing test (got: $(cat "$T/i5b.d/fail/worker-jobs-schema.txt" 2>/dev/null))"

  # ==========================================================================
  # I6. Both real rows on a scratch copy of this tree: main is green on both.
  # ==========================================================================
  C="$T/copy"; mkdir -p "$C"
  git -C "$DIR" ls-files -z --cached --others --exclude-standard | tar -C "$DIR" --null -T - -cf - 2>/dev/null | tar -C "$C" -xf -
  grep -P '^(render-doc-sections|worker-jobs-schema)\t' "$CATALOG" > "$T/i6.tsv"
  ( cd "$T" && PATH="$T/npmonly:$PATH" env -u PQ_MAIN -u RATCHET_BASE bash "$C/bin/prequeue-invariants.sh" --run --catalog "$T/i6.tsv" --out "$T/i6.d" ) > "$T/i6.out" 2>&1
  I6RC=$?
  [ "$I6RC" = 0 ] && grep -q '(2 run, 0 red)' "$T/i6.out" && ok \
    || bad "I6: both real rows are green on a copy of this tree (rc $I6RC: $(cat "$T/i6.out"))"
fi

echo "prequeue-invariants.bh-5591: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
