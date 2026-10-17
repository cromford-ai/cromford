#!/bin/bash
# tests/test-impact-pr-catalog.bh-7027-test.sh — a PR select (no
# TI_BATCH_SELECT) narrows a catalog/ path through its reader rows, the way the
# merge-queue batch has since BH-6059 (BH-7027).
#
# WHY. ti_infra_re carried `^catalog/` for every select that was not a batch,
# so a PR that touched one lane fragment ran the whole corpus (2390 suites) in
# PR CI and in the builder gate. The map already had the rows that name the
# path. Only the selector's own catalogs, a catalog path no suite names, and the
# true infra (tests/lib/, .github/workflows/, the runners) still go full.
#
# The real bin/test-impact.sh select drives every case, on a map built once
# from this tree.
#
#   P1  catalog/lanes.d/repair-on-push.json: selected, holds bh-3687, < 300
#   P2  the #6988 paths: selected, holds bh-6750 and bh-4607, < 300
#   P3  catalog/components.tsv + a route-table.d txt, map + one row: selected
#   P4  P1's set does not hold a suite with no row for the path
#   P5  P1 and P2 give the same set as the batch select
#   N1  the selector's own catalogs: full: infra change (<p>)
#   N2  tests/lib/ and .github/workflows/ stay infra
#   N3  a catalog path with no row: full: infra change, no `unmapped path`;
#       catalog/components.tsv, named by its BH-6971 reader: selected
#   N4  an unreadable rules file or a missing rules lib: full
#   N5  a catalog/ *.md, named by a row or not: not full
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
IMPACT="$DIR/bin/test-impact.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

"$IMPACT" map --root "$DIR" --out "$T/map" || { echo "FAIL: the map could not be built"; exit 1; }
[ -s "$T/map" ] || { echo "FAIL: the map is empty"; exit 1; }

# sel <name> <map> <root> <path>... — a plain select. Sets $T/<name>.why (rows),
# $T/<name>.set (sorted suites) and $T/<name>.reason (the impact: line).
sel() {
  local name="$1" map="$2" root="$3"; shift 3
  printf '%s\n' "$@" > "$T/$name.changed"
  env -u TI_BATCH_SELECT bash "$root/bin/test-impact.sh" --root "$root" select --why \
    --map "$map" --changed "$T/$name.changed" > "$T/$name.why" 2> "$T/$name.err"
  echo "$?" > "$T/$name.rc"
  cut -f1 "$T/$name.why" | LC_ALL=C sort -u > "$T/$name.set"
  grep '^impact:' "$T/$name.err" | tail -1 > "$T/$name.reason"
}
reason() { cat "$T/$1.reason"; }
count()  { grep -c . < "$T/$1.set"; }
holds()  { grep -qxF "$2" "$T/$1.set"; }
narrow() { # <case> <name>: rc 0, a selected: reason, a non-empty set under 300
  local r; r=$(reason "$2")
  [ "$(cat "$T/$2.rc")" = 0 ] || { bad "$1: select exited $(cat "$T/$2.rc")"; return; }
  case "$r" in
    *"(full:"*|"") bad "$1: the select went full or said nothing: '$r'" ;;
    *"(selected:"*) ok ;;
    *) bad "$1: the reason is not selected: '$r'" ;;
  esac
  local n; n=$(count "$2")
  { [ "$n" -gt 0 ] && [ "$n" -lt 300 ]; } && ok || bad "$1: the set has $n suites, want 1..299"
}
full_infra() { # <case> <name> <path>
  local r; r=$(reason "$2")
  case "$r" in *"(full: infra change ($3))"*) ok ;; *) bad "$1: $3 must be 'full: infra change ($3)', got '$r'" ;; esac
  case "$r" in *"unmapped path"*) bad "$1: a plain select must not say unmapped path: '$r'" ;; *) ok ;; esac
}

# ── P1 (red on main). the #7007 path.
sel p1 "$T/map" "$DIR" catalog/lanes.d/repair-on-push.json
narrow P1 p1
holds p1 tests/factory-stop-merge-deploy-tags.bh-3687-test.sh && ok \
  || bad "P1: the set must hold tests/factory-stop-merge-deploy-tags.bh-3687-test.sh"

# ── P2. the #6988 paths.
P2_PATHS=(catalog/lanes.d/merge-conductor.knobs.d/MC_LANDING_MODE.json
          worker/jobs/src/routes/retention.js
          worker/jobs/test/route-table.d/bh-6971-alert-components.txt)
# The route-table.d file is #6988's own; the map's directory row reaches it.
for p in "${P2_PATHS[@]:0:2}"; do
  [ -e "$DIR/$p" ] || bad "P2: fixture path $p is not in this tree"
done
sel p2 "$T/map" "$DIR" "${P2_PATHS[@]}"
narrow P2 p2
for s in tests/d1-retention.bh-6750-test.sh tests/worker-routes-render.bh-4607-test.sh; do
  holds p2 "$s" && ok || bad "P2: the set must hold $s"
done

# ── P3. catalog/components.tsv (#7012) with one reader row. On the #7012 tree
# tests/component-of.bh-6971-test.sh names it; that suite is not in this tree,
# and a map row must name a suite that exists, so an existing suite stands in.
READER=tests/ci-batch-escalate-narrow.bh-6059-test.sh
cp "$T/map" "$T/map.components"
printf '%s\tcatalog/components.tsv\n' "$READER" >> "$T/map.components"
sel p3 "$T/map.components" "$DIR" catalog/components.tsv worker/jobs/test/route-table.d/bh-6971-alert-components.txt
narrow P3 p3
grep -q 'awk:' "$T/p3.err" && bad "P3: the select printed an awk error: $(cat "$T/p3.err")" || ok
for s in "$READER" tests/worker-routes-render.bh-4607-test.sh tests/route-keyed-merge.bh-5788-test.sh; do
  holds p3 "$s" && ok || bad "P3: the set must hold $s"
done

# ── P4. a suite with no row for the path is not selected.
grep -qP '^tests/d1-retention\.bh-6750-test\.sh\tcatalog/lanes\.d/(repair-on-push\.json)?$' "$T/map" \
  && bad "P4: premise: d1-retention has a row for the P1 path" || ok
holds p1 tests/d1-retention.bh-6750-test.sh && bad "P4: P1's set must not hold tests/d1-retention.bh-6750-test.sh" || ok

# ── P5. parity with the batch select.
for c in p1 p2; do
  TI_BATCH_SELECT=1 bash "$IMPACT" --root "$DIR" select --map "$T/map" --changed "$T/$c.changed" \
    2> "$T/$c.batch.err" | LC_ALL=C sort -u > "$T/$c.batch.set"
  cmp -s "$T/$c.set" "$T/$c.batch.set" && ok \
    || bad "P5: $c: the plain set ($(count "$c")) differs from the batch set ($(grep -c . < "$T/$c.batch.set"))"
done

# ── N1. the selector's own catalogs stay full.
i=0
for p in catalog/test-tiers.tsv catalog/ci-batch-escalate.tsv catalog/test-impact-always.txt; do
  i=$((i+1)); sel "n1_$i" "$T/map" "$DIR" "$p"; full_infra N1 "n1_$i" "$p"
done

# ── N2. test helpers and workflows are true infra.
i=0
for p in tests/lib/scratch.sh tests/lib/repair-on-push-worker.bh-6963.mjs .github/workflows/harness-ci.yml; do
  i=$((i+1)); sel "n2_$i" "$T/map" "$DIR" "$p"; full_infra N2 "n2_$i" "$p"
done

# ── N3. a catalog path the map does not name.
# TEST-CHANGE: this case first used catalog/components.tsv, which was absent on
# the PR's base. Main b81445de6 (BH-6971, #7012) added the file and its reader
# tests/component-of.bh-6971-test.sh, so the map now names it and it narrows
# (the P3 behavior, with the real row). N3 now uses a catalog path no row names.
sel n3_1 "$T/map" "$DIR" catalog/zz-unmapped-bh7027.tsv
full_infra N3 n3_1 catalog/zz-unmapped-bh7027.tsv
if [ -e "$DIR/tests/component-of.bh-6971-test.sh" ]; then
  sel n3_3 "$T/map" "$DIR" catalog/components.tsv
  narrow N3 n3_3
  holds n3_3 tests/component-of.bh-6971-test.sh && ok \
    || bad "N3: catalog/components.tsv must select tests/component-of.bh-6971-test.sh"
fi
sel n3_2 "$T/map" "$DIR" catalog/zz-unmapped-bh7027.json
full_infra N3 n3_2 catalog/zz-unmapped-bh7027.json

# ── N4. fail closed when the rules cannot be read.
printf 'catalog/lanes.d/repair-on-push.json\n' > "$T/n4.changed"
R=$(CI_BATCH_ESCALATE_TSV="$T/none.tsv" env -u TI_BATCH_SELECT bash "$IMPACT" --root "$DIR" select \
  --map "$T/map" --changed "$T/n4.changed" 2>&1 >/dev/null | grep '^impact:')
case "$R" in *"(full: infra change (catalog/lanes.d/repair-on-push.json))"*) ok ;;
  *) bad "N4: an unreadable rules file must be full, got '$R'" ;; esac
NOLIB="$T/nolib"
mkdir -p "$NOLIB/bin/lib"
cp "$IMPACT" "$NOLIB/bin/test-impact.sh"
[ -e "$NOLIB/bin/lib/ci-batch-escalate.sh" ] && bad "N4: premise: the scratch root has the rules lib" || ok
sel n4_2 "$T/map" "$NOLIB" catalog/lanes.d/repair-on-push.json
full_infra N4 n4_2 catalog/lanes.d/repair-on-push.json

# ── N5. a catalog doc narrows.
sel n5 "$T/map" "$DIR" catalog/prequeue-learned-seed.d/README.md
case "$(reason n5)" in *"(full:"*|"") bad "N5: a catalog/ *.md must not go full: '$(reason n5)'" ;; *) ok ;; esac
# A doc no suite names narrows too: it selects only the always-run set.
grep -qP '\tcatalog/zz-doc-bh7027\.md$' "$T/map" && bad "N5: premise: the map names catalog/zz-doc-bh7027.md" || ok
sel n5_2 "$T/map" "$DIR" catalog/zz-doc-bh7027.md
narrow N5 n5_2

echo "test-impact-pr-catalog: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
