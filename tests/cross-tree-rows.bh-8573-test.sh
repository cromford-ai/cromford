#!/bin/bash
# tests/cross-tree-rows.bh-8573-test.sh — every quoted ../ path that console-ui/
# (spa) or worker/jobs/ (worker) JS/TS source reads OUTSIDE its own tree has a
# row of that kind in catalog/ci-batch-escalate.tsv, checked fast enough for PR
# lint (BH-8573).
#
# WHY. tests/ci-plan-spa-worker.bh-4969-test.sh X1/X2 makes this check, but it
# takes 11-15 s and runs only in the merge-queue batch. Four batches went red on
# it in one night, each one ejecting members that did nothing wrong. This suite
# makes the same decision in one pass (one git ls-files, one grep, awk for the
# path, cbe_affects in-process), so it is well under a second. It reads the
# whole checkout with `git -C "$DIR" ls-files`, so bin/test-impact.sh puts it
# in the always set: bin/fast-lints.sh runs it in the PR lint job, the builder
# gate runs it on every diff, and the batch still runs it.
#
# A miss prints a FAIL line and then the exact row to add, tab-separated:
#   <pattern>\t<spa|worker>\t<reader> reads <target> (<TICKET>)
# <pattern> is <target> for a file, <target>/ for a directory (or a literal
# that ends in /) and <target>* for a literal cut at a ${ template.
#
#   C1-C10  the decision on a scratch tree, each case with its near miss
#   R1-R2   the round trip (paste the printed rows -> 0 misses) and a mutation
#           (delete a needed row -> its miss comes back)
#   X1-X2   the real tree under the real catalog: 0 misses, floors met
#
# The always-set membership (bin/test-impact.sh always-why) takes about 10 s,
# so it is checked in the build's verify step and in CI, not here.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/bin/lib/ci-batch-escalate.sh" || { echo "FAIL: cannot source bin/lib/ci-batch-escalate.sh"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ctr_scan <root> <kind> <tree> <tsv> — the file list (git ls-files of <root>)
# on stdin. Prints one FAIL line and one row line per uncovered target, one row
# per pattern. Sets CTR_N (cross-tree reads found) and CTR_MISS (misses).
ctr_scan() {
  local root="$1" kind="$2" tree="$3" tsv="$4" f tgt slash cut probe pat
  local -A seen=()
  CTR_N=0; CTR_MISS=0
  LC_ALL=C awk -v t="$tree/" 'index($0, t) == 1 && /\.(m?js|cjs|jsx|ts|tsx)$/' > "$T/ctr-files"
  [ -s "$T/ctr-files" ] || { echo "FAIL: no $tree/ JS/TS file in the list"; CTR_MISS=1; return 1; }
  ( cd "$root" && xargs -r -d '\n' grep -oHE "['\"\`](\.\./)+[^'\"\`]*['\"\`]" -- < "$T/ctr-files" ) \
    | LC_ALL=C awk -v tree="$tree" '
      {
        i = index($0, ":"); f = substr($0, 1, i - 1); m = substr($0, i + 2)
        m = substr(m, 1, length(m) - 1)
        cut = 0; j = index(m, "${"); if (j > 0) { m = substr(m, 1, j - 1); cut = 1 }
        slash = (m ~ /\/$/) ? 1 : 0
        d = f; sub(/\/[^\/]*$/, "", d)
        n = split(d "/" m, a, "/"); k = 0
        for (x = 1; x <= n; x++) {
          if (a[x] == "" || a[x] == ".") continue
          if (a[x] == ".." && k > 0 && s[k] != "..") { k--; continue }
          s[++k] = a[x]
        }
        tgt = ""; for (x = 1; x <= k; x++) tgt = tgt (x > 1 ? "/" : "") s[x]
        if (tgt == "") tgt = "."
        if (tgt == "." || tgt == tree || index(tgt, tree "/") == 1) next
        print f "\t" tgt "\t" slash "\t" cut
      }' > "$T/ctr-hits"
  while IFS=$'\t' read -r f tgt slash cut; do
    CTR_N=$((CTR_N + 1))
    probe="$tgt"; pat="$tgt"
    if [ -d "$root/$tgt" ] || [ "$slash" = 1 ]; then probe="$tgt/x"; pat="$tgt/"
    elif [ "$cut" = 1 ]; then pat="$tgt*"; fi
    CI_BATCH_ESCALATE_TSV="$tsv" cbe_affects "$kind" "$probe" && continue
    CTR_MISS=$((CTR_MISS + 1))
    [ -z "${seen[$pat]:-}" ] || continue
    seen[$pat]=1
    echo "FAIL: X$([ "$kind" = spa ] && echo 1 || echo 2): $f reads $tgt with no $kind row; add to catalog/ci-batch-escalate.tsv (replace <TICKET> with the ticket key):"
    printf '%s\t%s\t%s reads %s (<TICKET>)\n' "$pat" "$kind" "$f" "$tgt"
  done < "$T/ctr-hits"
  [ "$CTR_MISS" -eq 0 ]
}

# ── C. the decision on a scratch tree.
S="$T/repo"
mkdir -p "$S/catalog" "$S/worker/jobs/test" "$S/worker/jobs/src/lib" "$S/console-ui/tests" \
         "$S/tests/fixtures/dir.bh-0001" "$S/worker/jobs/src/routes"
git -C "$S" init -q
printf 'zz-never/\tescalate\tmatches nothing here\n' > "$S/catalog/base.tsv"
put() { printf '%s\n' "$2" > "$S/$1"; }
put worker/jobs/test/a.test.js "const p = path.join(__dirname, '../../../tests/fixtures/x.bh-0001.json');"
put tests/fixtures/x.bh-0001.json '{}'
put console-ui/tests/b.test.js 'import r from "../../worker/jobs/src/routes/r.js";'
put worker/jobs/src/routes/r.js 'export default 1;'
put worker/jobs/test/c.test.js 'const f = `../../../tests/fixtures/dir.bh-0001/${name}.json`;'
put worker/jobs/test/d.test.js "const g = '../../../tests/fixtures/pre-\${x}.json';"
put worker/jobs/src/lib/e.js "import y from '../lib/y.js';"
put worker/jobs/x.js "import z from '../watchdog/z.js';"
put console-ui/README.md "see '../../x.bh-0001.txt'"
put console-ui/tests/f.test.ts "import q from '../../tests/fixtures/ts.bh-0001.json';"
put worker/jobs/test/g.test.mjs "import w from '../../../tests/fixtures/mjs.bh-0001.json';"
git -C "$S" add -A
git -C "$S" ls-files > "$T/sfiles"

# scan <tag> <kind> <tree> <tsv> — sets OUT RC N M
scan() { OUT=$(ctr_scan "$S" "$2" "$3" "$4" < "$T/sfiles"; r=$?; echo "N=$CTR_N M=$CTR_MISS"; exit "$r"); RC=$?
         N=$(sed -n 's/^N=\([0-9]*\) M=.*/\1/p' <<<"$OUT"); M=$(sed -n 's/^N=[0-9]* M=//p' <<<"$OUT"); }
has()  { grep -qxF "$1" <<<"$OUT"; }
TAB=$'\t'

scan base worker worker/jobs "$S/catalog/base.tsv"
ROW1="tests/fixtures/x.bh-0001.json${TAB}worker${TAB}worker/jobs/test/a.test.js reads tests/fixtures/x.bh-0001.json (<TICKET>)"
has "$ROW1" && ok || bad "C1: the exact row line for a.test.js is missing: [$OUT]"
grep -q "^FAIL: X2: worker/jobs/test/a.test.js reads tests/fixtures/x.bh-0001.json with no worker row; add to catalog/ci-batch-escalate.tsv" <<<"$OUT" \
  && ok || bad "C1: the FAIL line must name catalog/ci-batch-escalate.tsv: [$OUT]"
has "tests/fixtures/dir.bh-0001/${TAB}worker${TAB}worker/jobs/test/c.test.js reads tests/fixtures/dir.bh-0001 (<TICKET>)" \
  && ok || bad "C5: a cut tail that ends in / suggests tests/fixtures/dir.bh-0001/: [$OUT]"
has "tests/fixtures/pre-*${TAB}worker${TAB}worker/jobs/test/d.test.js reads tests/fixtures/pre- (<TICKET>)" \
  && ok || bad "C6: a cut tail suggests tests/fixtures/pre-*: [$OUT]"
grep -q 'lib/y.js' <<<"$OUT" && bad "C7: a read inside worker/jobs/ is not a miss: [$OUT]" || ok
grep -q 'watchdog' <<<"$OUT" && bad "C8: worker/watchdog/ is under the worker/ floor: [$OUT]" || ok
has "tests/fixtures/mjs.bh-0001.json${TAB}worker${TAB}worker/jobs/test/g.test.mjs reads tests/fixtures/mjs.bh-0001.json (<TICKET>)" \
  && ok || bad "C10: a .mjs reader is scanned: [$OUT]"
{ [ "$RC" = 1 ] && [ "$N" = 5 ] && [ "$M" = 4 ]; } && ok || bad "C8: worker reads 5 (watchdog counted), misses 4, rc 1; got N=$N M=$M rc=$RC"

{ cat "$S/catalog/base.tsv"; printf 'tests/fixtures/x.bh-0001.json\tworker\tC2\n'; } > "$T/c2.tsv"
scan c2 worker worker/jobs "$T/c2.tsv"
grep -q 'a.test.js' <<<"$OUT" && bad "C2: a file row covers a.test.js: [$OUT]" || ok
[ "$M" = 3 ] && ok || bad "C2: 3 misses left, got $M"

scan spa spa console-ui "$S/catalog/base.tsv"
has "worker/jobs/src/routes/r.js${TAB}spa${TAB}console-ui/tests/b.test.js reads worker/jobs/src/routes/r.js (<TICKET>)" \
  && ok || bad "C3: a console test reading the worker is a spa miss: [$OUT]"
has "tests/fixtures/ts.bh-0001.json${TAB}spa${TAB}console-ui/tests/f.test.ts reads tests/fixtures/ts.bh-0001.json (<TICKET>)" \
  && ok || bad "C10: a .ts reader is scanned: [$OUT]"
grep -q 'README' <<<"$OUT" && bad "C9: console-ui/README.md is not a JS/TS file: [$OUT]" || ok
[ "$N" = 2 ] && ok || bad "C9: spa reads 2 (README ignored), got $N"
{ cat "$S/catalog/base.tsv"; printf 'worker/jobs/src/routes/r.js\tworker\tC4\n'; } > "$T/c4.tsv"
scan c4 spa console-ui "$T/c4.tsv"
grep -q "^worker/jobs/src/routes/r.js${TAB}spa${TAB}" <<<"$OUT" && ok || bad "C4: a worker row does not cover a spa read: [$OUT]"

# ── R. the round trip: paste every printed row, re-scan, 0 misses.
cp "$S/catalog/base.tsv" "$T/rt.tsv"
for k in "worker worker/jobs" "spa console-ui"; do
  set -- $k
  ctr_scan "$S" "$1" "$2" "$S/catalog/base.tsv" < "$T/sfiles" | grep -v '^FAIL: ' >> "$T/rt.tsv"
done
[ "$(grep -c "(<TICKET>)$" "$T/rt.tsv")" = 6 ] && ok || bad "R1: 6 rows printed, got: $(cat "$T/rt.tsv")"
for k in "worker worker/jobs" "spa console-ui"; do
  set -- $k
  scan rt "$1" "$2" "$T/rt.tsv"
  { [ "$RC" = 0 ] && [ "$M" = 0 ] && [ "$N" -gt 0 ]; } && ok || bad "R1: the pasted rows cover every $1 read: M=$M [$OUT]"
done
grep -vF "tests/fixtures/x.bh-0001.json${TAB}" "$T/rt.tsv" > "$T/mut.tsv"
scan mut worker worker/jobs "$T/mut.tsv"
{ [ "$M" = 1 ] && has "$ROW1"; } && ok || bad "R2: deleting C1's row brings C1 back: M=$M [$OUT]"

# ── X. the real tree under the real catalog.
REAL_TSV="$DIR/catalog/ci-batch-escalate.tsv"
git -C "$DIR" ls-files > "$T/files"
ctr_scan "$DIR" spa console-ui "$REAL_TSV" < "$T/files" && ok || bad "X1: console-ui/ reads outside its tree with no spa row (rows above)"
xs=$CTR_N
ctr_scan "$DIR" worker worker/jobs "$REAL_TSV" < "$T/files" && ok || bad "X2: worker/jobs/ reads outside its tree with no worker row (rows above)"
xw=$CTR_N
# Not vacuous: the scan found the cross-tree reads that exist today.
{ [ "$xs" -ge 5 ] && [ "$xw" -ge 15 ]; } && ok || bad "X: the scan found too few cross-tree reads (spa=$xs worker=$xw) — the pattern stopped matching"

echo "cross-tree-rows.bh-8573-test.sh: $PASS passed, $FAIL failed (spa=$xs worker=$xw cross-tree reads)"
[ "$FAIL" -eq 0 ] || exit 1
