#!/bin/bash
# tests/ci-plan-testlib-select.bh-6371-test.sh — a merge-queue batch that
# changes a tests/lib/ helper, or only ADDS rows to catalog/ci-batch-escalate.tsv,
# runs its impact set instead of the whole corpus (BH-6371).
#
# WHY. catalog/ci-batch-escalate.tsv had a blanket `tests/lib/` escalate row,
# and bin/test-impact.sh had ^tests/lib/ in the infra list a batch reads. Every
# batch that touched any helper, or added one spa/worker row to the rules file,
# ran 2048 of 2147 suites on 8 shards. A helper now selects every suite that
# reaches it (directly, or through another helper that names it), only
# tests/lib/scratch.sh stays global, and an add-only rules diff selects.
#
# The real bin/ci-plan.sh and the real bin/test-impact.sh drive T1-T2c; the map
# is built once and handed to test-impact through a wrapper. T3* run the real
# planner in a scratch git repo, so cbe_add_only reads a real `git diff -U0`.
#
#   T1   tests/lib/gh-shim-stub.sh: batch-selected, exactly its consumers + always
#   T1b  tests/lib/rb-all.sh: carries fixture-harness.sh's consumers (closure)
#   T1c  tests/lib/ci-durations-worker.bh-5653.mjs: its importers are selected
#   T2   a helper no suite reaches: full, `unmapped path <p>`
#   T2b  tests/lib/scratch.sh: full, `selection input: tests/lib/scratch.sh`
#   T2c  tests/lib/README.md: not full
#   N-PR the same helper outside a batch: still `infra change (<p>)`
#   U1-U8 cbe_add_only over real diffs
#   T3   an added spa row: batch-selected, spa=1, the reason says so
#   T3b-f a removed row, an added allow row, an empty diff, a bad base: full;
#        an added worker row: worker=1
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
LIB="$DIR/bin/lib/ci-batch-escalate.sh"
TSV="$DIR/catalog/ci-batch-escalate.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# ── The real selector, with the map built once.
"$DIR/bin/test-impact.sh" map --out "$T/map" || { echo "FAIL: the map could not be built"; exit 1; }
cat > "$T/impact.sh" <<EOF
#!/bin/bash
exec "$DIR/bin/test-impact.sh" "\$@" --map "$T/map"
EOF
chmod +x "$T/impact.sh"
"$DIR/bin/test-impact.sh" always --map "$T/map" > "$T/always" || { echo "FAIL: always set unreadable"; exit 1; }
[ -s "$T/always" ] || { echo "FAIL: the always set is empty"; exit 1; }
: > "$T/notiers.tsv"
HEADSHA=$(git -C "$DIR" rev-parse HEAD)

# bplan <path>... [-- VAR=val ...] — one batch plan; sets RC OUT GO, list in $T/list
bplan() {
  local paths=() vars=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do paths+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift; vars=("$@")
  printf '%s\n' "${paths[@]}" > "$T/changed"
  rm -f "$T/go" "$T/list"
  OUT=$(env -u GITHUB_ACTIONS CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" \
          CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$T/impact.sh" CI_PLAN_CHANGED_FILE="$T/changed" \
          CI_PLAN_TIER_FILE="$T/notiers.tsv" GITHUB_OUTPUT="$T/go" \
          ${vars[@]+"${vars[@]}"} "$PLAN" --out "$T/list" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
missing() { LC_ALL=C comm -23 <(LC_ALL=C sort -u "$1") <(LC_ALL=C sort -u "$T/list" 2>/dev/null); }
selected() { # selected <tag> <path> — batch-selected, escalation=-, under the corpus, always set carried
  bplan "$2"
  { [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && [ "$(out escalation)" = - ] \
      && [ -n "$(out count)" ] && [ "$(out count)" -lt "$(out total)" ]; } && ok \
    || bad "$1: $2 must be batch-selected (rc=$RC mode=$(out mode) escalation='$(out escalation)' count=$(out count) total=$(out total)) [$OUT]"
  [ -z "$(missing "$T/always")" ] && ok || bad "$1: the batch list must carry the always set"
}
escalates() { # escalates <tag> <expected escalation> <paths...>
  local tag="$1" want="$2"; shift 2
  bplan "$@"
  { [ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "$want" ] && [ "$(out count)" = "$(out total)" ]; } && ok \
    || bad "$tag: $* must be mode=full with escalation '$want' (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$OUT]"
}
# exact <path> — suites whose map row names the path itself
exact() { awk -F'\t' -v p="$1" '$2 == p { print $1 }' "$T/map" | LC_ALL=C sort -u; }
# covering <path> — suites whose map row names the path or a directory above it
covering() { awk -F'\t' -v p="$1" '$2 == p || ($2 ~ /\/$/ && index(p, $2) == 1) { print $1 }' "$T/map" | LC_ALL=C sort -u; }

# ── T1. a helper with 12 direct consumers selects exactly them (+ always).
H=tests/lib/gh-shim-stub.sh
exact "$H" > "$T/t1.exact"
[ "$(grep -c . "$T/t1.exact")" -ge 1 ] && ok || bad "T1: the map has no consumer of $H"
selected T1 "$H"
[ -z "$(missing "$T/t1.exact")" ] && ok || bad "T1: consumers of $H are missing: $(missing "$T/t1.exact" | head -3)"
{ cat "$T/always"; covering "$H"; } | LC_ALL=C sort -u > "$T/t1.want"
LC_ALL=C sort -u "$T/list" > "$T/t1.got"
cmp -s "$T/t1.want" "$T/t1.got" && ok \
  || bad "T1: the list must be the consumers plus the always set: extra $(LC_ALL=C comm -13 "$T/t1.want" "$T/t1.got" | head -3 | tr '\n' ' ') missing $(LC_ALL=C comm -23 "$T/t1.want" "$T/t1.got" | head -3 | tr '\n' ' ')"
has "selected: 1 changed path(s)" "$(out summary)" && ok || bad "T1: the reason must count the diff, not the closure: '$(out summary)'"

# ── T1b. a helper reached through another helper (fixture-harness.sh sources rb-all.sh).
exact tests/lib/fixture-harness.sh > "$T/t1b.fh"
exact tests/lib/rb-all.sh > "$T/t1b.rb"
LC_ALL=C comm -23 "$T/t1b.fh" "$T/t1b.rb" > "$T/t1b.only"
[ -s "$T/t1b.only" ] && ok || bad "T1b: no suite reaches rb-all.sh only through fixture-harness.sh; the case proves nothing"
selected T1b tests/lib/rb-all.sh
[ -z "$(missing "$T/t1b.only")" ] && ok \
  || bad "T1b: $(missing "$T/t1b.only" | grep -c .) suite(s) that reach rb-all.sh through fixture-harness.sh are missing: $(missing "$T/t1b.only" | head -3)"

# ── T1c. a node helper selects the suites that import it.
H=tests/lib/ci-durations-worker.bh-5653.mjs
exact "$H" > "$T/t1c.exact"
[ -s "$T/t1c.exact" ] && ok || bad "T1c: the map has no importer of $H"
selected T1c "$H"
[ -z "$(missing "$T/t1c.exact")" ] && ok || bad "T1c: importers of $H are missing: $(missing "$T/t1c.exact" | head -3)"

# ── T2. a helper no suite reaches fails closed, with its reason.
escalates T2 "unmapped path tests/lib/zz-bh6371-orphan.sh" tests/lib/zz-bh6371-orphan.sh
has "full: unmapped path tests/lib/zz-bh6371-orphan.sh" "$(out summary)" && ok || bad "T2: the summary must carry the reason: '$(out summary)'"
escalates "T2 order" "unmapped path tests/lib/zz-bh6371-orphan.sh" tests/lib/gh-shim-stub.sh tests/lib/zz-bh6371-orphan.sh

# ── T2b. the global helper escalates through its catalog row.
escalates T2b "selection input: tests/lib/scratch.sh" tests/lib/scratch.sh
grep -qx $'tests/lib/scratch.sh\tescalate\t.*' "$TSV" && ok || bad "T2b: the tsv must carry the tests/lib/scratch.sh escalate row"
grep -qx $'tests/lib/\tescalate\t.*' "$TSV" && bad "T2b: the tsv still has the blanket tests/lib/ escalate row" || ok

# ── T2c. a doc under tests/lib/ never goes full.
selected T2c tests/lib/README.md

# ── N-PR. outside a batch (PR CI's ci-select and the builder gate both reach
# ti_select_from without TI_BATCH_SELECT) a helper is still infra.
printf 'tests/lib/gh-shim-stub.sh\n' > "$T/npr"
R=$(env -u TI_BATCH_SELECT "$T/impact.sh" select --changed "$T/npr" --out /dev/null 2>&1)
has "full: infra change (tests/lib/gh-shim-stub.sh)" "$R" && ok || bad "N-PR: plain select must keep tests/lib/ as infra: $R"
R=$(env -u TI_BATCH_SELECT "$T/impact.sh" select --map-only --changed "$T/npr" --out /dev/null 2>&1)
has "map-only: CI runs the corpus, full: infra change (tests/lib/gh-shim-stub.sh)" "$R" && ok \
  || bad "N-PR: the builder gate's --map-only select must still say CI runs the corpus: $R"

# ── A scratch repo with the planner, its lib and the real rules file.
G="$T/repo"; mkdir -p "$G/catalog"
scratch_install_closure bin/ci-plan.sh "$G" > /dev/null || { echo "FAIL: cannot install bin/ci-plan.sh's closure"; exit 1; }
[ -f "$G/bin/lib/ci-batch-escalate.sh" ] || { echo "FAIL: the closure has no bin/lib/ci-batch-escalate.sh"; exit 1; }
cp "$TSV" "$G/catalog/ci-batch-escalate.tsv"
# The stub selector records what it was asked and answers with two suites.
cat > "$G/impact.sh" <<'EOF'
#!/bin/bash
cmd="$1"; shift; changed=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in --changed) changed="$2"; shift ;; --out) out="$2"; shift ;; esac; shift
done
printf '%s\n' "$cmd" > "$STUB_SEEN.cmd"
[ -z "$changed" ] || cp "$changed" "$STUB_SEEN.changed"
if [ "$cmd" = select ]; then
  printf 'tests/a-test.sh\ntests/b-test.sh\n' > "$out"
  echo "impact: 2 of 10 suites (selected: 1 changed path(s))" >&2
else
  for i in 0 1 2 3 4 5 6 7 8 9; do echo "tests/s$i-test.sh"; done > "$out"
  echo "impact: 10 of 10 suites (full: corpus)" >&2
fi
EOF
printf '#!/bin/bash\ncat\n' > "$G/tiers.sh"
chmod +x "$G/impact.sh" "$G/tiers.sh"
git -C "$G" init -q && git -C "$G" add -A && git -C "$G" -c user.email=t@example.invalid -c user.name=t commit -qm base \
  || { echo "FAIL: cannot commit the scratch base"; exit 1; }
BASE=$(git -C "$G" rev-parse HEAD)

# edit <tag> <sed-or-append-cmd> — reset the rules file to the base, change it, commit
edit() {
  git -C "$G" checkout -q "$BASE" -- catalog/ci-batch-escalate.tsv
  ( cd "$G" && eval "$2" ) || { bad "$1: the edit failed"; return 1; }
  git -C "$G" -c user.email=t@example.invalid -c user.name=t commit -qam "$1" --allow-empty
}
# gplan [VAR=val ...] — the real planner in the scratch repo, TI_BASE=$BASE
gplan() {
  rm -f "$G/go" "$G/seen".*
  OUT=$(cd "$G" && env -u GITHUB_ACTIONS CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$BASE" \
          CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$G/impact.sh" CI_PLAN_TIERS="$G/tiers.sh" \
          STUB_SEEN="$G/seen" GITHUB_OUTPUT="$G/go" "$@" bin/ci-plan.sh --out "$G/list" 2>&1); RC=$?
  GO=$(cat "$G/go" 2>/dev/null)
}
# diffof — the rules file's -U0 diff, base to head, as the planner reads it
diffof() { git -C "$G" diff --no-renames -U0 "$BASE" HEAD -- catalog/ci-batch-escalate.tsv > "$T/u.diff"; }
cbe_add() { ( . "$G/bin/lib/ci-batch-escalate.sh" || exit 9; cbe_add_only "$@" ); }
# addonly <tag> <want-rc> [want-out] — cbe_add_only over the current diff
addonly() {
  local r rc; diffof; r=$(cbe_add "$T/u.diff"); rc=$?
  { [ "$rc" = "$2" ] && [ "$r" = "${3:-}" ]; } && ok || bad "$1: cbe_add_only must be rc $2 '${3:-}' (rc=$rc, got '$r') [$(cat "$T/u.diff")]"
}
ROW_SPA=$'zz-bh6371-spa/\tspa\ta path the SPA reads (fixture)'
ROW_ESC=$'zz-bh6371-esc.sh\tescalate\ta selection input (fixture)'
ROW_WRK=$'zz-bh6371-wrk/\tworker\ta path the worker reads (fixture)'
ROW_ALW=$'zz-bh6371-doc.md\tallow\ta doc (fixture)'

# ── U1-U8. cbe_add_only over real `git diff -U0` output.
edit U1 "printf '%s\n' \"\$ROW_SPA\" >> catalog/ci-batch-escalate.tsv"; addonly "U1 added spa" 0 spa
edit U2 "printf '%s\n' \"\$ROW_ESC\" >> catalog/ci-batch-escalate.tsv"; addonly "U2 added escalate" 0 escalate
edit U2b "printf '%s\n%s\n%s\n' \"\$ROW_WRK\" \"\$ROW_SPA\" \"\$ROW_WRK\" >> catalog/ci-batch-escalate.tsv"; addonly "U2b kinds sorted, unique" 0 $'spa\nworker'
edit U3 "printf '%s\n' \"\$ROW_ALW\" >> catalog/ci-batch-escalate.tsv"; addonly "U3 added allow" 1
edit U4 "sed -i '/^bin\/test-tiers.sh\t/d' catalog/ci-batch-escalate.tsv"; addonly "U4 removed row" 1
edit U5 "sed -i 's/^\(bin\/ci-plan.sh\tescalate\t\).*/\1the planner (changed)/' catalog/ci-batch-escalate.tsv"; addonly "U5 changed row" 1
edit U6 "printf '# a new comment\n' >> catalog/ci-batch-escalate.tsv"; addonly "U6 comment only" 1
edit U7 "printf 'zz-bh6371-two\tspa\n' >> catalog/ci-batch-escalate.tsv"; addonly "U7 two columns" 1
edit U7b "printf 'zz-bh6371-case/\tSpa\tx\n' >> catalog/ci-batch-escalate.tsv"; addonly "U7b kind case" 1
edit U7c "printf '\tspa\tno pattern\n' >> catalog/ci-batch-escalate.tsv"; addonly "U7c empty pattern" 1
edit U7d "printf '%s\n# why\n\n' \"\$ROW_SPA\" >> catalog/ci-batch-escalate.tsv"; addonly "U7d row plus comment and blank" 0 spa
: > "$T/empty.diff"
r=$(cbe_add "$T/empty.diff"); [ "$?" = 1 ] && [ -z "$r" ] && ok || bad "U8: an empty diff must be rc 1 (got '$r')"
r=$(cbe_add "$T/no-such.diff"); [ "$?" = 1 ] && [ -z "$r" ] && ok || bad "U8: a missing diff must be rc 1 (got '$r')"
r=$(cbe_add); [ "$?" = 1 ] && ok || bad "U8: no argument must be rc 1"
( . "$G/bin/lib/ci-batch-escalate.sh" ) > "$T/src.out" 2>&1 && [ ! -s "$T/src.out" ] && ok || bad "U8: sourcing the lib must print nothing"

# ── T3. an added spa row: the real planner, the real diff.
edit T3 "printf '%s\n' \"\$ROW_SPA\" >> catalog/ci-batch-escalate.tsv"
gplan
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && [ "$(out escalation)" = - ]; } && ok \
  || bad "T3: an add-only spa row must be batch-selected (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$OUT]"
[ "$(out spa)" = 1 ] && ok || bad "T3: an added spa row must set spa=1 (spa=$(out spa))"
[ "$(out worker)" = 0 ] && ok || bad "T3: an added spa row must not set worker=1 (worker=$(out worker))"
has "escalation rows added only (spa)" "$(out summary)" && ok || bad "T3: the reason must say 'escalation rows added only (spa)': '$(out summary)'"
[ "$(cat "$G/seen.cmd" 2>/dev/null)" = select ] && grep -qx 'catalog/ci-batch-escalate.tsv' "$G/seen.changed" 2>/dev/null && ok \
  || bad "T3: the selector must get catalog/ci-batch-escalate.tsv in its changed list (cmd=$(cat "$G/seen.cmd" 2>/dev/null))"
# ...and the real map selects the selector's own suites for that path.
printf 'catalog/ci-batch-escalate.tsv\n' > "$T/t3.changed"
TI_BATCH_SELECT=1 "$T/impact.sh" select --changed "$T/t3.changed" --out "$T/t3.list" 2>"$T/t3.why"
for s in tests/ci-plan-spa-worker.bh-4969-test.sh tests/ci-plan-batch-impact.bh-4968-test.sh tests/ci-batch-escalate-narrow.bh-6059-test.sh; do
  grep -qxF "$s" "$T/t3.list" && ok || bad "T3: the real map must select $s for the rules file [$(cat "$T/t3.why")]"
done

# ── T3b. a removed row escalates.
edit T3b "sed -i '/^bin\/test-tiers.sh\t/d' catalog/ci-batch-escalate.tsv"
gplan
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: catalog/ci-batch-escalate.tsv" ]; } && ok \
  || bad "T3b: a removed row must escalate (mode=$(out mode) escalation='$(out escalation)') [$OUT]"

# ── T3c. an added allow row escalates.
edit T3c "printf '%s\n' \"\$ROW_ALW\" >> catalog/ci-batch-escalate.tsv"
gplan
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: catalog/ci-batch-escalate.tsv" ]; } && ok \
  || bad "T3c: an added allow row must escalate (mode=$(out mode) escalation='$(out escalation)') [$OUT]"

# ── T3d. the rules file listed, but no diff (TI_BASE = HEAD): escalates.
edit T3d "printf '%s\n' \"\$ROW_SPA\" >> catalog/ci-batch-escalate.tsv"
printf 'catalog/ci-batch-escalate.tsv\n' > "$T/t3d.changed"
gplan TI_BASE="$(git -C "$G" rev-parse HEAD)" CI_PLAN_CHANGED_FILE="$T/t3d.changed"
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: catalog/ci-batch-escalate.tsv" ]; } && ok \
  || bad "T3d: an empty rules diff must escalate (mode=$(out mode) escalation='$(out escalation)') [$OUT]"

# ── T3e. a base the diff cannot resolve: escalates.
gplan TI_BASE=0000000000000000000000000000000000000bad CI_PLAN_CHANGED_FILE="$T/t3d.changed"
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: catalog/ci-batch-escalate.tsv" ]; } && ok \
  || bad "T3e: an unresolvable base must escalate (mode=$(out mode) escalation='$(out escalation)') [$OUT]"

# ── T3f. an added worker row turns the worker job on.
edit T3f "printf '%s\n' \"\$ROW_WRK\" >> catalog/ci-batch-escalate.tsv"
gplan
{ [ "$(out mode)" = batch-selected ] && [ "$(out worker)" = 1 ] && [ "$(out spa)" = 0 ]; } && ok \
  || bad "T3f: an added worker row must be batch-selected with worker=1 spa=0 (mode=$(out mode) spa=$(out spa) worker=$(out worker)) [$OUT]"

echo "ci-plan-testlib-select.bh-6371-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
