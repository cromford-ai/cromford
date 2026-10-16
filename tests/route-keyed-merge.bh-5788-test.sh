#!/bin/bash
# tests/route-keyed-merge.bh-5788-test.sh — two builds that each add a jobs
# route family by ticket key merge with no conflict (BH-5788 B).
#
# A family is worker/jobs/src/routes/<family>.js plus
# worker/jobs/test/route-table.d/<ticket-key>-<family>.txt. The key is unique
# per ticket, so two branches never pick the same "next free" number and never
# touch a common file.
#   M1  branch X adds zz-a under bh-1, branch Y adds zz-b under bh-2: both merge
#       into main with no conflict, neither diff touches a file the other does,
#       src/index.js is untouched, and the real scripts/routes-build.mjs
#       --print lists zz-a then zz-b last in FAMILIES
# Fixture repos only, fixed commit dates. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/route-keyed-merge.bh-5788-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node is not on PATH"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# A scratch repo with the jobs worker's generator, composer, modules and fragments.
R="$T/repo"; J="$R/worker/jobs"
mkdir -p "$J/test"
cp -R "$DIR/worker/jobs/src" "$J/src"
cp -R "$DIR/worker/jobs/scripts" "$J/scripts"
cp -R "$DIR/worker/jobs/test/route-table.d" "$J/test/route-table.d"
cp "$DIR/worker/jobs/package.json" "$J/package.json"
rm -f "$J/src/routes.gen.js"
git init -q -b main "$R"; git -C "$R" add -A; git -C "$R" commit -qm base

# family <branch> <key> <family> — a branch off main that adds one family.
family() {
  git -C "$R" checkout -q -b "$1" main
  printf 'import { json } from "../lib/http.js";\nexport const routes = [["GET", "/api/%s", () => json(200, { ok: true })]];\n' "$3" \
    > "$J/src/routes/$3.js"
  printf 'GET /api/%s\n' "$3" > "$J/test/route-table.d/$2-$3.txt"
  git -C "$R" add -A; git -C "$R" commit -qm "$2"
}
family x bh-1 zz-a
family y bh-2 zz-b
git -C "$R" checkout -q main

# ── M1 no shared file, no conflict ────────────────────────────────────────────
X=$(git -C "$R" diff --name-only main x); Y=$(git -C "$R" diff --name-only main y)
[ -z "$(comm -12 <(sort <<<"$X") <(sort <<<"$Y"))" ] && ok || bad "M1 the two branches share a file: $(comm -12 <(sort <<<"$X") <(sort <<<"$Y"))"
grep -q 'src/index.js' <<<"$X$Y" && bad "M1 a branch edited src/index.js" || ok
git -C "$R" merge -q --no-edit x >"$T/mx.out" 2>&1 && ok || bad "M1 merge x: $(cat "$T/mx.out")"
git -C "$R" merge -q --no-edit y >"$T/my.out" 2>&1 && ok || bad "M1 merge y conflicted: $(cat "$T/my.out")"
[ -z "$(git -C "$R" diff --name-only --diff-filter=U)" ] && ok || bad "M1 unmerged paths after the merge"

( cd "$J" && node scripts/routes-build.mjs --print ) >"$T/gen.js" 2>"$T/gen.err"; RC=$?
[ "$RC" = 0 ] && ok || bad "M1 routes-build.mjs --print rc $RC: $(cat "$T/gen.err")"
FAM=$(sed -n 's/^export const FAMILIES = \[\(.*\)\];$/\1/p' "$T/gen.js")
# Key-named fragments sort after every numbered one and among themselves by
# file name, so the tail of FAMILIES is exactly the tree's key-named families.
KEYED=$(cd "$J/test/route-table.d" && ls | LC_ALL=C sort | grep -E '^[a-z]+-[0-9]+([.-][0-9]+)?-[a-z]' | sed -E 's/^[a-z]+-[0-9]+([.-][0-9]+)?-//; s/\.txt$//')
NK=$(grep -c . <<<"$KEYED")
TAIL=$(tr -d ' "' <<<"$FAM" | tr ',' '\n' | tail -n "$NK")
[ "$TAIL" = "$KEYED" ] && ok || bad "M1 the key-named families must close FAMILIES in file-name order ($(tr '\n' ' ' <<<"$KEYED")): [$FAM]"
[ "$(grep -A1 -x zz-a <<<"$TAIL" | tail -1)" = zz-b ] && ok || bad "M1 zz-a must come just before zz-b: [$FAM]"
grep -qx 'import { routes as f_bh_1_zz_a } from "./routes/zz-a.js";' "$T/gen.js" && ok \
  || bad "M1 the render must import zz-a as f_bh_1_zz_a"

echo "route-keyed-merge.bh-5788: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
