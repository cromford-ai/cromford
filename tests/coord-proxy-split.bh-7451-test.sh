#!/bin/bash
# tests/coord-proxy-split.bh-7451-test.sh — BH-7451: the coord proxy
# console-ui/functions/api/coord/[[path]].js is a list file in
# catalog/list-files.tsv, so bin/list-file-lint.sh refuses a PR that appends a
# WRITES row to it. A new write route is a fragment file under
# console-ui/functions/_lib/coord-writes.d/ (BH-6487).
#
#   C1  the real catalog has exactly one row whose glob matches the literal
#       proxy path under the readers' rule; its input is coord-writes.d/
#   C2  a WRITES append with no new fragment -> real lint rc 1; names the
#       file, the growth, the catalog row line and the Fix
#   C3  a fragment-only PR -> rc 0; a +1/-1 value edit in WRITES -> rc 0
#   C4  near misses: a decoy coord/p].js, coord/[[path]].ts and
#       api/[[path]].js grow -> rc 0; the raw (unescaped) glob WOULD match
#       the decoy, which is why the row is escaped
#   C5  two sibling branches that each add a fragment merge clean, the proxy
#       stays byte-identical, lint rc 0 on the merge, ROUTES ends with both;
#       two siblings that each append a WRITES row conflict and each alone
#       is lint rc 1
#   C6  the render: coord-writes.gen.js from the fragments gives the loader's
#       FRAGMENT_WRITES; the proxy loaded through the render (workerd
#       condition) has the same ROUTES as through the Node loader; ROUTES is
#       the in-file rows then every fragment row once; the render is
#       untracked and ignored
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/coord-proxy-split.bh-7451-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LINT="$REPO/bin/list-file-lint.sh"
CAT="$REPO/catalog/list-files.tsv"
CU="$REPO/console-ui"
P='console-ui/functions/api/coord/[[path]].js'
FD='console-ui/functions/_lib/coord-writes.d/'
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
for c in git node; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-19T18:00:00Z' GIT_COMMITTER_DATE='2026-10-19T18:00:00Z'

lines() { local i; for i in $(seq 1 "$1"); do echo "$2 line $i"; done; }
run() { OUT=$("$LINT" "$@" 2>&1); RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
# append_row <file> <path> — one WRITES row before the `];` that closes WRITES.
append_row() {
  awk -v p="$2" '/^const WRITES = \[/{w=1} w && /^\];/{print "  { method: '\''POST'\'', path: '\''" p "'\'', body: ['\''a'\''] },"; w=0} {print}' \
    "$1" > "$1.n" && mv "$1.n" "$1"
}
frag() { printf "export default [\n  { method: '%s', path: '%s', body: ['a'] }\n];\n" "$2" "$3" > "$1"; }
# cu_copy <dest> — a console-ui with what the proxy and the table import.
cu_copy() {
  mkdir -p "$1/functions/api" "$1/tests" "$1/src" || return 1
  cp "$CU/package.json" "$1/" && cp -R "$CU/scripts" "$1/" \
    && cp -R "$CU/functions/_lib" "$1/functions/" && cp -R "$CU/functions/api/coord" "$1/functions/api/" \
    && cp -R "$CU/tests/lib" "$1/tests/" && cp -R "$CU/src/theme" "$1/src/" \
    && rm -f "$1/functions/_lib/coord-writes.gen.js"
}
# mk <case> — a repo at $T/<case>: the real catalog and console-ui, branch `base`.
mk() {
  local R="$T/$1"
  mkdir -p "$R/catalog" && cd "$R" || return 1
  git init -q -b main .
  cp "$CAT" catalog/list-files.tsv
  printf 'console-ui/functions/_lib/coord-writes.gen.js\n' > .gitignore
  cu_copy console-ui || return 1
  git add -A && git commit -q -m base && git branch base
}
pr() { git add -A && git commit -q -m pr; }
# routes <proxy> [node flags] — one "<METHOD> <path>" line per ROUTES row.
routes() {
  local f=$1; shift
  node "$@" --input-type=module -e "
const m = await import(process.argv[1]);
for (const w of m.ROUTES) console.log(w.method + ' ' + (typeof w.path === 'function' ? 'fn:' + w.path.toString().length : w.path) + ' ' + JSON.stringify(w.body));
" "$f"
}

# ── C1: the catalog row ──────────────────────────────────────────────────────
slashes() { local x=${1//[^\/]/}; echo "${#x}"; }
c1_match() { # c1_match <catalog> <path> — "<line>\t<input>" per matching row
  ( set -f; n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      case "$line" in '#'*|'') continue ;; esac
      IFS=$'\t' read -r g in _ <<< "$line"
      [ "$(slashes "$g")" = "$(slashes "$2")" ] || continue
      # shellcheck disable=SC2254 # the readers match the glob unquoted
      case "$2" in $g) printf '%s\t%s\n' "$n" "$in" ;; esac
    done < "$1" )
}
m=$(c1_match "$CAT" "$P")
ROWLN=${m%%$'\t'*}
if [ "$(printf '%s\n' "$m" | grep -c .)" = 1 ] && [ "${m#*$'\t'}" = "$FD" ]; then
  ok "C1 one catalog row (line $ROWLN) matches $P, input $FD"
else bad "C1 rows matching $P: '$m'"; fi

# ── C2: a WRITES append with no fragment is refused ──────────────────────────
mk c2; append_row "$P" fixture-x; pr
[ "$(git diff --numstat base -- "$P" | cut -f1)" = 1 ] || bad "C2 the fixture did not add one line to WRITES"
run --base base
if [ "$RC" = 1 ] && has "$P grew by 1 line(s)" && has "catalog/list-files.tsv:${ROWLN:-none}" \
   && has "Fix: put the new entry in its own file under $FD"; then
  ok "C2 a WRITES append with no fragment is rc 1 and names the file, row and fix"
else bad "C2 rc=$RC out: $OUT"; fi

# ── C3: the fragment path passes ─────────────────────────────────────────────
mk c3a; frag "${FD}999451-fixture-a.js" POST fixture-a; pr
run --base base
[ "$RC" = 0 ] && ! has "$P" && ok "C3 a fragment-only PR is rc 0" || bad "C3 fragment rc=$RC out: $OUT"
mk c3b
awk '/^const WRITES = \[/{w=1} w && !d && /^[[:space:]]*\{ method:/{sub(/ \}/, "  }"); d=1} {print}' "$P" > p.n && mv p.n "$P"; pr
[ "$(git diff --numstat base -- "$P" | cut -f1-2)" = "1	1" ] || bad "C3 the value edit is not +1/-1: $(git diff --numstat base -- "$P")"
run --base base
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "C3 a +1/-1 value edit in WRITES is rc 0" || bad "C3 value edit rc=$RC out: $OUT"

# ── C4: near misses ──────────────────────────────────────────────────────────
mk c4
D1='console-ui/functions/api/coord/p].js'; D2='console-ui/functions/api/coord/[[path]].ts'; D3='console-ui/functions/api/[[path]].js'
for d in "$D1" "$D2" "$D3"; do lines 3 base > "$d"; done
git add -A && git commit -q -m decoys && git branch -f base
for d in "$D1" "$D2" "$D3"; do lines 2 extra >> "$d"; done; pr
run --base base
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "C4 growth of coord/p].js, coord/[[path]].ts and api/[[path]].js is rc 0" \
  || bad "C4 rc=$RC out: $OUT"
printf '%s\t%s\t%s\n' 'console-ui/functions/api/coord/[[path]].js' "$FD" raw > "$T/raw.tsv"
run --base base --catalog "$T/raw.tsv"
[ "$RC" = 1 ] && has "$D1 grew by 2" && ok "C4 the raw glob would match the decoy p].js (why the row is escaped)" \
  || bad "C4 raw glob rc=$RC out: $OUT"

# ── C5: sibling branches ─────────────────────────────────────────────────────
mk c5; git branch -m base main 2>/dev/null; git checkout -q main 2>/dev/null
git checkout -q -b a; frag "${FD}999451-fixture-a.js" POST fixture-a; pr
git checkout -q main; git checkout -q -b b; frag "${FD}999452-fixture-b.js" POST fixture-b; pr
git merge -q a -m m >/dev/null 2>&1; mrc=$?
[ "$mrc" = 0 ] && [ -z "$(git diff --name-only --diff-filter=U)" ] \
  && ok "C5 two fragment siblings merge clean" || bad "C5 fragment merge rc=$mrc"
git diff --quiet main HEAD -- "$P" && cmp -s "$P" "$REPO/$P" \
  && ok "C5 the proxy is byte-identical after the merge" || bad "C5 the proxy changed"
run --base main
[ "$RC" = 0 ] && ok "C5 lint on the merge is rc 0" || bad "C5 merge lint rc=$RC out: $OUT"
got=$(routes "$T/c5/$P" 2>&1 | tail -n 2 | cut -d' ' -f1-2 | tr '\n' ' ')
[ "$got" = "POST fixture-a POST fixture-b " ] && ok "C5 ROUTES from the merged proxy ends with fixture-a, fixture-b" \
  || bad "C5 ROUTES tail: '$got'"
git checkout -q main; git checkout -q -b wa; append_row "$P" fixture-a; pr
run --base main; rca=$RC
git checkout -q main; git checkout -q -b wb; append_row "$P" fixture-b; pr
run --base main; rcb=$RC
git merge -q wa -m m >/dev/null 2>&1; mrc=$?
[ "$mrc" != 0 ] && [ "$(git diff --name-only --diff-filter=U)" = "$P" ] \
  && ok "C5 two WRITES-append siblings conflict on the proxy" || bad "C5 append merge rc=$mrc"
[ "$rca" = 1 ] && [ "$rcb" = 1 ] && ok "C5 each WRITES-append sibling alone is lint rc 1" || bad "C5 append lint rc a=$rca b=$rcb"
git merge --abort 2>/dev/null

# ── C6: the render equals the table in use ───────────────────────────────────
S="$T/c6"; cu_copy "$S" || bad "C6 copy"
( cd "$S" && node scripts/coord-writes-build.mjs ) > "$T/c6.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$S/functions/_lib/coord-writes.gen.js" ] || bad "C6 render rc=$rc $(cat "$T/c6.out")"
fw() { node --input-type=module -e "
const m = await import(process.argv[1]);
for (const w of m.FRAGMENT_WRITES) console.log(w.method + ' ' + w.path + ' ' + JSON.stringify(w.body));
" "$1"; }
g=$(fw "$S/functions/_lib/coord-writes.gen.js" 2>&1); l=$(fw "$S/tests/lib/coord-writes.node.js" 2>&1)
[ -n "$g" ] && [ "$g" = "$l" ] && ok "C6 the rendered FRAGMENT_WRITES equals the loader's ($(printf '%s\n' "$g" | wc -l) rows)" \
  || bad "C6 render '$g' vs loader '$l'"
rn=$(routes "$S/functions/api/coord/[[path]].js" 2>&1); rw=$(routes "$S/functions/api/coord/[[path]].js" --conditions=workerd 2>&1)
[ -n "$rn" ] && [ "$rn" = "$rw" ] && ok "C6 the proxy through the render (workerd) has the Node loader's ROUTES" \
  || bad "C6 ROUTES node vs workerd differ: $(diff <(echo "$rn") <(echo "$rw") | head -n 5)"
nfrag=$(printf '%s\n' "$l" | grep -c .); nall=$(printf '%s\n' "$rn" | grep -c .)
nwrites=$(awk '/^const WRITES = \[/{w=1; next} w && /^\];/{w=0} w && /^[[:space:]]*\{ method:/{n++} END{print n+0}' "$REPO/$P")
[ "$(printf '%s\n' "$rn" | tail -n "$nfrag")" = "$l" ] && [ "$nall" = $((nwrites + nfrag)) ] \
  && ok "C6 ROUTES is $nwrites in-file rows then the $nfrag fragment rows, in order" \
  || bad "C6 ROUTES $nall rows, WRITES $nwrites, fragments $nfrag"
dup=$(printf '%s\n' "$rn" | grep -v ' fn:' | cut -d' ' -f1-2 | sort | uniq -d)
[ -z "$dup" ] && ok "C6 every route is present once" || bad "C6 duplicate routes: $dup"
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  [ -z "$(git -C "$REPO" ls-files console-ui/functions/_lib/coord-writes.gen.js)" ] \
    && git -C "$REPO" check-ignore -q console-ui/functions/_lib/coord-writes.gen.js \
    && ok "C6 the render is untracked and git-ignored" || bad "C6 coord-writes.gen.js is tracked or not ignored"
else echo "  skip C6 git checks: not a git checkout"; fi

echo
echo "coord-proxy-split.bh-7451: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
