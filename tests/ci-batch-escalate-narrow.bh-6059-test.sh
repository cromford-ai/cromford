#!/bin/bash
# tests/ci-batch-escalate-narrow.bh-6059-test.sh — a merge-queue batch that
# touches bin/lib/ or catalog/ runs its IMPACT SET, unless the path is one the
# selection itself runs on or one the impact map cannot resolve (BH-6059).
#
# WHY. catalog/ci-batch-escalate.tsv had two blanket prefix rows, `bin/lib/` and
# `catalog/`. Most PRs touch one of those trees, so 19 of 21 sampled batches on
# 2026-10-10/11 ran the whole corpus, a README under bin/lib/ included. The rows
# are now the files the selection reads (derived from what bin/ci-plan.sh,
# bin/test-impact.sh, bin/test-tiers.sh and the runners source and read), and a
# bin/lib/ or catalog/ path with no specific map row escalates as
# `unmapped path <p>`, so a file the map does not know still fails closed.
#
# The real bin/ci-plan.sh and the real bin/test-impact.sh drive every batch
# case; the map is built once and handed to test-impact through a wrapper.
#
#   N1  bin/lib/deferral-after.sh: batch-selected, carries its mapped suites
#   D1  bin/lib/br/opt/README.md: batch-selected, no suite through a root row
#   D2  a *.md under bin/lib/ or catalog/: the allow row beats an escalate row
#   N2  each derived selection input is an infra row (BH-7287): a batch plans
#       mode=infra; the rules file itself still escalates
#   N4  catalog/lanes.d/<x>.json: batch-selected, spa and worker still run
#   N3  a new bin/lib/ or catalog/ file: full, `unmapped path <p>`
#   N5  a new top-level bin/ script: not unmapped (the bin/ scanners reach it)
#   N6  select WITHOUT TI_BATCH_SELECT is unchanged (PR CI and the builder gate)
#   N6b an unreadable rules file still escalates every batch
#   N7  the real tsv has no bin/lib/ or catalog/ escalate row
#   G1  every literal path in test-impact's infra list has an escalate or
#       infra row
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
cbe() { ( . "$LIB" || exit 9; cbe_reason "$1" ); }
cbi() { ( . "$LIB" || exit 9; command -v cbe_infra > /dev/null || exit 9; cbe_infra "$1" ); }

# The derived selection inputs: what the planner, the selector, the tier step
# and the runners source or read when CI decides what a batch runs.
INPUTS=(bin/lib/suite-runner.sh bin/lib/docker-host.sh bin/lib/env-path.sh bin/lib/ci-batch-escalate.sh
        bin/lib/test-protected.sh bin/lib/train-shape.sh bin/lib/test-image-node.sh bin/test-suite-run.sh
        bin/test-trace-safety.sh bin/run-tests-in-docker.sh catalog/test-tiers.tsv
        catalog/test-quarantine-protected.txt catalog/test-impact-always.txt catalog/nightly-strict.txt)

# ── N7. the blanket rows are gone.
grep -qx $'bin/lib/\tescalate\t.*' "$TSV" && bad "N7: the tsv still has a bin/lib/ escalate row" || ok
grep -qx $'catalog/\tescalate\t.*' "$TSV" && bad "N7: the tsv still has a catalog/ escalate row" || ok

# ── G1. the selector's infra list and the escalate rows cannot drift apart.
INFRA=$(sed -n "s/^ti_infra_core_re='\(.*\)'$/\1/p" "$DIR/bin/test-impact.sh")
[ -n "$INFRA" ] && ok || bad "G1: bin/test-impact.sh has no ti_infra_core_re"
for alt in $(printf '%s' "$INFRA" | tr '|' '\n'); do
  p=$(printf '%s' "$alt" | sed 's/^\^//; s/\$$//; s/\\//g')
  case "$p" in */) p="${p}x" ;; esac
  # BH-7287: an escalate row or an infra row; either keeps the path out of a plain selection.
  r=$(cbe "$p"); { [ "$r" = "selection input: $p" ] || cbi "$p"; } && ok || bad "G1: infra path $p has no escalate or infra row (got '$r')"
done

# ── D2. a doc never escalates on its own, even under an escalate prefix.
printf '# scratch\nbin/lib/\tescalate\tx\ncatalog/\tescalate\tx\n' > "$T/rules.tsv"
sed -n $'/\tallow\t/p' "$TSV" >> "$T/rules.tsv"
for p in bin/lib/x.md catalog/x.md bin/lib/br/opt/README.md; do
  r=$(CI_BATCH_ESCALATE_TSV="$T/rules.tsv" cbe "$p"); rc=$?
  { [ "$rc" = 1 ] && [ -z "$r" ]; } && ok || bad "D2: $p must not escalate under the real allow rows (rc=$rc, got '$r')"
done
r=$(CI_BATCH_ESCALATE_TSV="$T/rules.tsv" cbe bin/lib/x.sh)
[ "$r" = "selection input: bin/lib/x.sh" ] && ok || bad "D2: the allow rows exempt docs only (got '$r')"

# ── N2 (unit). every derived input is an infra row (BH-7287); the rules file
# itself escalates; ordinary bin/lib and catalog files are neither.
for p in "${INPUTS[@]}"; do
  cbi "$p"; rc=$?
  [ "$rc" = 0 ] && ok || bad "N2: $p must be an infra row (cbe_infra rc=$rc)"
done
r=$(cbe catalog/ci-batch-escalate.tsv); rc=$?
{ [ "$rc" = 0 ] && [ "$r" = "selection input: catalog/ci-batch-escalate.tsv" ]; } && ok \
  || bad "N2: catalog/ci-batch-escalate.tsv must escalate (rc=$rc, got '$r')"
for p in bin/lib/deferral-after.sh bin/lib/archie-fm-watch/common.sh catalog/lanes.d/lesson-classify.json bin/lib/br/opt/README.md; do
  r=$(cbe "$p"); rc=$?
  { [ "$rc" = 1 ] && [ -z "$r" ]; } && ok || bad "N2: $p must not escalate through the rules (rc=$rc, got '$r')"
  cbi "$p" && bad "N2: $p must not be an infra row" || ok
done

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

# bplan <path>... [-- VAR=val ...] — one batch plan; sets RC OUT GO SUM, list in $T/list
bplan() {
  local paths=() vars=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do paths+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift; vars=("$@")
  printf '%s\n' "${paths[@]}" > "$T/changed"
  rm -f "$T/go" "$T/list" "$T/sum"
  OUT=$(env -u GITHUB_ACTIONS CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" \
          CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$T/impact.sh" CI_PLAN_CHANGED_FILE="$T/changed" \
          CI_PLAN_TIER_FILE="$T/notiers.tsv" GITHUB_OUTPUT="$T/go" GITHUB_STEP_SUMMARY="$T/sum" \
          ${vars[@]+"${vars[@]}"} "$PLAN" --out "$T/list" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null); SUM=$(cat "$T/sum" 2>/dev/null)
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
# specific <path> — suites with a map row for the path that is not a whole-tree root row
specific() {
  awk -F'\t' -v p="$1" '$2 == "*" || $2 == "bin/" || $2 == "bin/lib/" || $2 == "catalog/" { next }
    $2 == p || ($2 ~ /\/$/ && index(p, $2) == 1) { print $1 }' "$T/map" | LC_ALL=C sort -u
}

# ── N1. an ordinary bin/lib/ script runs its impact set, every suite that names it.
selected N1 bin/lib/deferral-after.sh
awk -F'\t' '$2 == "bin/lib/deferral-after.sh" { print $1 }' "$T/map" > "$T/n1.exact"
[ -s "$T/n1.exact" ] && ok || bad "N1: the map has no row for bin/lib/deferral-after.sh"
[ -z "$(missing "$T/n1.exact")" ] && ok || bad "N1: suites that name bin/lib/deferral-after.sh are missing: $(missing "$T/n1.exact" | head -3)"
selected "N1 nested" bin/lib/archie-fm-watch/common.sh

# ── D1. a README under bin/lib/ selects only what names it or its own directory.
selected D1 bin/lib/br/opt/README.md
{ cat "$T/always"; specific bin/lib/br/opt/README.md; } | LC_ALL=C sort -u > "$T/d1.allowed"
EXTRA=$(LC_ALL=C comm -13 "$T/d1.allowed" <(LC_ALL=C sort -u "$T/list"))
[ -z "$EXTRA" ] && ok || bad "D1: suites selected only through a root row: $(head -3 <<<"$EXTRA") ($(printf '%s\n' "$EXTRA" | grep -c .) total)"
grep -qxF tests/blocked-resolver-opt-hooks.bh-1468-test.sh "$T/list" && ok \
  || bad "D1: the suite that reads the README by name must still run"

# ── N4. a lane source under catalog/ is batch-selected; its spa/worker rows still gate.
selected N4 catalog/lanes.d/lesson-classify.json
{ [ "$(out spa)" = 1 ] && [ "$(out worker)" = 1 ]; } && ok || bad "N4: spa and worker must run (spa=$(out spa) worker=$(out worker))"

# ── N2 (batch). the selection inputs plan mode=infra end to end (BH-7287).
for p in bin/lib/suite-runner.sh bin/lib/test-protected.sh catalog/test-tiers.tsv catalog/test-impact-always.txt; do
  bplan "$p"
  { [ "$RC" = 0 ] && [ "$(out mode)" = infra ] && [ "$(out escalation)" = - ] && [ "$(out count)" -lt "$(out total)" ]; } && ok \
    || bad "N2 $p: must be mode=infra (rc=$RC mode=$(out mode) escalation='$(out escalation)' count=$(out count) total=$(out total)) [$OUT]"
done

# ── N3. a bin/lib/ or catalog/ path the map cannot resolve fails closed, with its reason.
# With the member union off (BH-7290): tests/ci-member-reach-union.bh-7290-test.sh pins it on.
escalates N3 "unmapped path bin/lib/new-thing.sh" bin/lib/new-thing.sh -- CI_PLAN_MEMBER_UNION=0
has "full: unmapped path bin/lib/new-thing.sh" "$(out summary)" && ok || bad "N3: the summary must carry the reason: '$(out summary)'"
has "escalation: unmapped path bin/lib/new-thing.sh" "$SUM" && ok || bad "N3: the step summary must carry the escalation [$SUM]"
escalates "N3 catalog" "unmapped path catalog/zz-new-bh6059.json" catalog/zz-new-bh6059.json -- CI_PLAN_MEMBER_UNION=0
escalates "N3 order" "unmapped path bin/lib/new-thing.sh" bin/lib/deferral-after.sh bin/lib/new-thing.sh -- CI_PLAN_MEMBER_UNION=0
# a new doc never escalates, even with no row at all
selected "N3 doc" bin/lib/zz-new-bh6059.md

# ── N5. a new top-level bin/ script keeps 4968 case 4b's answer.
bplan bin/zz-new-bh6059.sh
{ [ "$RC" = 0 ] && ! has "unmapped" "$(out escalation)"; } && ok \
  || bad "N5: a new top-level bin/ script must not be unmapped (rc=$RC mode=$(out mode) escalation='$(out escalation)')"

# ── N6. without TI_BATCH_SELECT, select answers exactly as before.
for p in bin/lib/new-thing.sh catalog/zz-new-bh6059.json; do
  printf '%s\n' "$p" > "$T/c6"
  R=$(env -u TI_BATCH_SELECT "$T/impact.sh" select --changed "$T/c6" --out /dev/null 2>&1)
  has "unmapped path" "$R" && bad "N6: plain select on $p must not say unmapped path: $R" || ok
  R=$(TI_BATCH_SELECT=1 "$T/impact.sh" select --changed "$T/c6" --out /dev/null 2>&1)
  has "full: unmapped path ($p)" "$R" && ok || bad "N6: batch select on $p must say 'full: unmapped path ($p)': $R"
done
printf 'catalog/zz-new-bh6059.json\n' > "$T/c6"
R=$("$T/impact.sh" select --changed "$T/c6" --out /dev/null 2>&1)
has "full: infra change (catalog/zz-new-bh6059.json)" "$R" && ok || bad "N6: plain select keeps catalog/ as infra: $R"

# ── N6b. an unreadable rules file still escalates every batch.
escalates N6b "selection input: catalog/ci-batch-escalate.tsv unreadable" bin/lib/deferral-after.sh -- CI_BATCH_ESCALATE_TSV="$T/no-such.tsv"

echo "ci-batch-escalate-narrow.bh-6059-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
