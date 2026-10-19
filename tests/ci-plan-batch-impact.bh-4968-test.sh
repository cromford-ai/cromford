#!/bin/bash
# tests/ci-plan-batch-impact.bh-4968-test.sh — a Mergify merge-queue batch runs
# the IMPACT SET of its combined diff, not the whole corpus (BH-4968, C0 of
# BH-4964), and escalates to the corpus with a stated reason when the impact
# cannot be trusted.
#
# WHY. Every batch draft ran all ~1700 suites whatever it carried, so a batch of
# two console-ui fixes paid the same as one that rewrote bin/lib. The batch is
# the last proof before a tree lands, so the failure to fear is the opposite one:
# a batch that touched the harness's own plumbing (the runner libs, the
# workflow, the selector, the tier file) selecting a small set and landing
# green. Those paths are data in catalog/ci-batch-escalate.tsv, read by
# bin/lib/ci-batch-escalate.sh, and every one of them is pinned below as NEVER
# batch-selected. BH-6059 narrowed bin/lib/ and catalog/ to the files the
# selection reads (tests/ci-batch-escalate-narrow.bh-6059-test.sh); a bin/lib/
# path the map cannot resolve escalates as `unmapped path <p>`.
#
# The real bin/ci-plan.sh and the real bin/test-impact.sh drive every case but
# 8-11; the map is built once and handed to test-impact through a two-line
# wrapper, so the selection logic is the production one and the run is seconds.
#
#   E1-E4  cbe_reason: every escalate row answers, an infra row (BH-7287)
#          answers cbe_infra instead, other paths do not, an
#          `allow` row overrides, an unknown kind is skipped, no TSV fails closed
#   1      a console-ui screen: batch-selected, small, always set included
#   2      a bin/ script: batch-selected, its mapped suite included
#   3      a .github/ action: full, `selection input: <path>`; a runner lib:
#          mode=infra (BH-7287)
#          (a top-level workflow file selects its readers since BH-6876:
#          tests/ci-plan-workflow-narrow.bh-6876-test.sh)
#   4      a path the map does not know: full, `unmapped: <path>`
#   4b     a brand-new bin/ script: batch-selected (whole-bin scanners reach it)
#   5      selection of a union == union of selections
#   6      the `full` label and an empty TI_BASE escalate
#   7      no adversarial negative is batch-selected: the rules file and
#          .mergify.yml escalate, the selection inputs plan mode=infra
#          (BH-7287); docs alone still runs the always set
#   8      a failed or reasonless select is rc 2, never a plan
#   9      the run-page notice and the step summary
#   10     a select of every suite is full
#   11     an ordinary PR is untouched: no notice, no select, escalation=-
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
LIB="$DIR/bin/lib/ci-batch-escalate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
TAB=$'\t'

# ── E1-E4. cbe_reason, the rules lib on its own.
cbe() { ( . "$LIB" || exit 9; cbe_reason "$1" ); }
cbi() { ( . "$LIB" || exit 9; command -v cbe_infra > /dev/null || exit 9; cbe_infra "$1" ); }
for p in .github/actions/x/action.yml .mergify.yml catalog/ci-batch-escalate.tsv; do
  r=$(cbe "$p"); rc=$?
  { [ "$rc" = 0 ] && [ "$r" = "selection input: $p" ]; } && ok || bad "E1: $p must escalate as 'selection input: $p' (rc=$rc, got '$r')"
done
# BH-7287: the selection inputs are infra rows, not escalate rows.
for p in bin/lib/suite-runner.sh bin/ci-plan.sh bin/test-impact.sh bin/test-impact-gate.sh bin/test-tiers.sh \
         tests/lib/scratch.sh catalog/test-tiers.tsv; do
  r=$(cbe "$p"); rc=$?
  { [ "$rc" = 1 ] && [ -z "$r" ] && cbi "$p"; } && ok || bad "E1: $p must be an infra row, not an escalate row (rc=$rc, got '$r')"
done
for p in bin/merge-sweep.sh docs/x.md console-ui/src/screens/Jobs.js; do
  r=$(cbe "$p"); rc=$?
  { [ "$rc" = 1 ] && [ -z "$r" ]; } && ok || bad "E2: $p must not escalate (rc=$rc, got '$r')"
done
printf '# a scratch rules file\nbin/lib/\tescalate\tplumbing\nbin/lib/x.sh\tallow\tknown safe\nbin/merge-sweep.sh\tspa\ta sibling kind\n' > "$T/rules.tsv"
r=$(CI_BATCH_ESCALATE_TSV="$T/rules.tsv" cbe bin/lib/x.sh); rc=$?
{ [ "$rc" = 1 ] && [ -z "$r" ]; } && ok || bad "E3: an allow row overrides its escalate prefix (rc=$rc, got '$r')"
r=$(CI_BATCH_ESCALATE_TSV="$T/rules.tsv" cbe bin/lib/y.sh); rc=$?
[ "$r" = "selection input: bin/lib/y.sh" ] && ok || bad "E3: the allow row covers only its own path (rc=$rc, got '$r')"
r=$(CI_BATCH_ESCALATE_TSV="$T/rules.tsv" cbe bin/merge-sweep.sh); rc=$?
{ [ "$rc" = 1 ] && [ -z "$r" ]; } && ok || bad "E3: a row of another kind (spa) is skipped (rc=$rc, got '$r')"
r=$(CI_BATCH_ESCALATE_TSV="$T/no-such.tsv" cbe docs/x.md); rc=$?
{ [ "$rc" = 0 ] && has "unreadable" "$r"; } && ok || bad "E4: a missing rules file fails closed (rc=$rc, got '$r')"
printf '# only comments\nbin/x\tallow\tno escalate rows\n' > "$T/rules-empty.tsv"
r=$(CI_BATCH_ESCALATE_TSV="$T/rules-empty.tsv" cbe docs/x.md); rc=$?
{ [ "$rc" = 0 ] && has "unreadable" "$r"; } && ok || bad "E4: a rules file with no escalate row fails closed (rc=$rc, got '$r')"

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
  if [ "${#paths[@]}" -gt 0 ]; then printf '%s\n' "${paths[@]}" > "$T/changed"; else : > "$T/changed"; fi
  rm -f "$T/go" "$T/list" "$T/sum"
  OUT=$(env -u GITHUB_ACTIONS CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" \
          CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$T/impact.sh" CI_PLAN_CHANGED_FILE="$T/changed" \
          CI_PLAN_TIER_FILE="$T/notiers.tsv" GITHUB_OUTPUT="$T/go" GITHUB_STEP_SUMMARY="$T/sum" \
          ${vars[@]+"${vars[@]}"} "$PLAN" --out "$T/list" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null); SUM=$(cat "$T/sum" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
superset_always() { [ -z "$(LC_ALL=C comm -23 <(LC_ALL=C sort -u "$T/always") <(LC_ALL=C sort -u "$T/list" 2>/dev/null))" ]; }
infra() { # infra <tag> <paths...> — mode=infra (BH-7287), escalation=-, under the corpus, always set carried
  local tag="$1"; shift
  bplan "$@"
  { [ "$RC" = 0 ] && [ "$(out mode)" = infra ] && [ "$(out escalation)" = - ] && [ "$(out count)" -lt "$(out total)" ] \
      && superset_always; } && ok \
    || bad "$tag: $* must be mode=infra (rc=$RC mode=$(out mode) escalation='$(out escalation)' count=$(out count) total=$(out total)) [$OUT]"
}
escalates() { # escalates <tag> <expected escalation> <paths...>
  local tag="$1" want="$2"; shift 2
  bplan "$@"
  { [ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "$want" ]; } && ok \
    || bad "$tag: $* must be mode=full with escalation '$want' (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$OUT]"
}

# ── 1. a console-ui screen: the impact set, not the corpus.
bplan console-ui/src/screens/Jobs.js
C1=$(out count); T1=$(out total)
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && [ "$(out escalation)" = - ]; } && ok \
  || bad "1: Jobs.js must be batch-selected, escalation=- (rc=$RC mode=$(out mode) escalation=$(out escalation)) [$OUT]"
{ [ -n "$C1" ] && [ -n "$T1" ] && [ "$C1" -lt "$T1" ]; } && ok || bad "1: count ($C1) must be under total ($T1)"
[ "$(out n)" = $(( (${C1:-0} + 119) / 120 )) ] && ok || bad "1: n must be ceil($C1/120), got '$(out n)'"
superset_always && ok || bad "1: the batch list must carry the always set"
grep -qxF tests/ci-plan-test.sh "$T/list" && bad "1: an unrelated suite (tests/ci-plan-test.sh) ran" || ok
has "impact: $C1 of $T1 suites" "$(out summary)" && ok || bad "1: the summary must read 'impact: $C1 of $T1 suites': '$(out summary)'"

# ── 2. a bin/ script (not bin/lib): its mapped suites run, not the corpus.
B2=bin/merge-sweep.sh
S2=$(awk -F'\t' -v p="$B2" '$2 == p { print $1; exit }' "$T/map")
bplan "$B2"
{ [ "$(out mode)" = batch-selected ] && [ -n "$S2" ] && grep -qxF "$S2" "$T/list" && [ "$(out count)" -lt "$(out total)" ]; } && ok \
  || bad "2: $B2 must be batch-selected and carry its mapped suite '$S2' (mode=$(out mode) count=$(out count) total=$(out total)) [$OUT]"

# ── 3. the harness's own plumbing escalates, and says which path did it.
escalates 3a "selection input: .github/actions/x/action.yml" .github/actions/x/action.yml
has "escalation: selection input: .github/actions/x/action.yml" "$SUM" && ok || bad "3a: the step summary must name the escalation: [$SUM]"
[ "$(out count)" = "$(out total)" ] && ok || bad "3a: an escalated batch runs the corpus (count=$(out count) total=$(out total))"
# BH-7287: a runner lib is an infra path: its own suites and the canaries, not the corpus.
infra 3b bin/lib/docker-host.sh

# ── 4. a path the map does not know is unmapped.
# With the member union off (BH-7290): tests/ci-member-reach-union.bh-7290-test.sh pins it on.
escalates 4 "unmapped: zz-unmapped-bh4964/x.sh" zz-unmapped-bh4964/x.sh -- CI_PLAN_MEMBER_UNION=0

# ── 4b. a brand-new bin/ script in a real tree: the whole-bin scanners reach it.
S4="$T/s4"; mkdir -p "$S4"
git -C "$DIR" archive HEAD | tar -x -C "$S4"
# the working tree's ci-plan closure and rules, so this case tests THIS change
rm -f "$S4/bin/ci-plan.sh" "$S4/bin/lib/ci-batch-escalate.sh"; mkdir -p "$S4/catalog"
scratch_install_closure bin/ci-plan.sh "$S4" > /dev/null || bad "4b: cannot install ci-plan's closure"
cp "$DIR/catalog/ci-batch-escalate.tsv" "$S4/catalog/" 2>/dev/null
printf '#!/bin/bash\necho new\n' > "$S4/bin/zz-unmapped-bh4964.sh"
"$S4/bin/test-impact.sh" map --out "$T/map4" || bad "4b: the scratch map could not be built"
printf '#!/bin/bash\nexec "%s/bin/test-impact.sh" "$@" --map "%s"\n' "$S4" "$T/map4" > "$T/impact4.sh"; chmod +x "$T/impact4.sh"
printf 'bin/zz-unmapped-bh4964.sh\n' > "$T/changed4"
rm -f "$T/go"
OUT=$(env -u GITHUB_ACTIONS CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" TI_PR_LABELS= \
        CI_PLAN_ESCALATION=- CI_PLAN_IMPACT="$T/impact4.sh" CI_PLAN_CHANGED_FILE="$T/changed4" CI_PLAN_TIER_FILE="$T/notiers.tsv" \
        GITHUB_OUTPUT="$T/go" GITHUB_STEP_SUMMARY="$T/sum4" "$S4/bin/ci-plan.sh" --out "$T/list" 2>&1); RC=$?
GO=$(cat "$T/go" 2>/dev/null)
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && superset_always; } && ok \
  || bad "4b: a new bin/ script is batch-selected with the always set (rc=$RC mode=$(out mode) escalation=$(out escalation)) [$OUT]"

# ── 5. the selection of a union is the union of the selections.
: > "$T/u"
for p in console-ui/src/screens/Jobs.js "$B2" docs/x.md; do bplan "$p"; cat "$T/list" >> "$T/u"; done
LC_ALL=C sort -u "$T/u" > "$T/u.sorted"
bplan console-ui/src/screens/Jobs.js "$B2" docs/x.md
{ [ "$(out mode)" = batch-selected ] && cmp -s "$T/u.sorted" <(LC_ALL=C sort -u "$T/list"); } && ok \
  || bad "5: sel(A u B u C) must equal sel A u sel B u sel C (mode=$(out mode), $(grep -c . "$T/list") vs $(grep -c . "$T/u.sorted"))"

# ── 6. the `full` label and an empty base escalate before any selection.
escalates 6a "the 'full' label" console-ui/src/screens/Jobs.js -- "TI_PR_LABELS=docs, full"
escalates 6b "no batch base" console-ui/src/screens/Jobs.js -- TI_BASE=

# ── 7. adversarial negatives: none of these may come back batch-selected.
for p in catalog/ci-batch-escalate.tsv .mergify.yml; do
  escalates "7 $p" "selection input: $p" "$p"
done
# BH-7287: the selection inputs plan mode=infra, never batch-selected and never the corpus.
for p in bin/lib/suite-runner.sh bin/ci-plan.sh bin/test-impact-gate.sh bin/test-impact.sh bin/test-tiers.sh \
         tests/lib/scratch.sh catalog/test-tiers.tsv; do
  infra "7 $p" "$p"
done
# the old path of a rename is unknown to the map, so it is unmapped (BH-6059)
escalates "7 rename" "unmapped path bin/lib/zz-moved.sh" bin/lib/zz-moved.sh bin/zz-moved.sh -- CI_PLAN_MEMBER_UNION=0
escalates "7 empty list" "the batch diff is empty"
escalates "7 missing rules" "selection input: catalog/ci-batch-escalate.tsv unreadable" console-ui/src/screens/Jobs.js -- CI_BATCH_ESCALATE_TSV="$T/no-such.tsv"
bplan console-ui/src/screens/Jobs.js -- TI_BASE=0000000000000000000000000000000000000000 CI_PLAN_CHANGED_FILE=
{ [ "$(out mode)" = full ] && has "cannot diff the batch base 00000000" "$(out escalation)"; } && ok \
  || bad "7 bad base: an unresolvable base must escalate (mode=$(out mode) escalation='$(out escalation)') [$OUT]"
bplan docs/x.md
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && superset_always; } && ok \
  || bad "7 docs: docs alone still runs the always set, never nothing (rc=$RC mode=$(out mode)) [$OUT]"

# 7 rename, through ci-plan's own git diff in a real repo: --no-renames lists
# the OLD path, so moving an escalating file away still escalates. The moved
# file is one with its own escalate row: .github/actions/zz/action.yml (since
# BH-7287 a bin/lib/ selection input is an infra row, not an escalate row).
RR="$T/rr"; mkdir -p "$RR/bin/lib" "$RR/catalog" "$RR/.github/actions/zz"
scratch_install_closure bin/ci-plan.sh "$RR" > /dev/null || bad "7 rename: cannot install ci-plan's closure"
cp "$DIR/catalog/ci-batch-escalate.tsv" "$RR/catalog/" 2>/dev/null
printf 'name: zz\n' > "$RR/.github/actions/zz/action.yml"
cat > "$T/fake-rr.sh" <<'FAKE'
#!/bin/bash
OUT=""; CMD=""
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; --changed) shift ;; *) CMD="${CMD:-$1}" ;; esac; shift; done
case "$CMD" in
  select)    printf 'tests/a-test.sh\n' > "$OUT"; echo "impact: 1 of 2 suites (selected: 1 changed path(s))" >&2 ;;
  ci-select) printf 'tests/a-test.sh\ntests/b-test.sh\n' > "$OUT"; echo "impact: 2 of 2 suites (full: event '$TI_EVENT' is not a pull request)" >&2 ;;
esac
FAKE
chmod +x "$T/fake-rr.sh"
rgit() { git -C "$RR" -c user.email=t@example.com -c user.name=t "$@"; }
rgit init -q; rgit add -A; rgit commit -qm base
RBASE=$(git -C "$RR" rev-parse HEAD)
rgit mv .github/actions/zz/action.yml bin/zz-moved.yml; rgit commit -qm rename
rm -f "$T/go"
OUT=$(cd "$RR" && env -u GITHUB_ACTIONS -u CI_PLAN_CHANGED_FILE CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/rn \
        TI_BASE="$RBASE" TI_PR_LABELS= CI_PLAN_ESCALATION=- CI_PLAN_IMPACT="$T/fake-rr.sh" GITHUB_OUTPUT="$T/go" GITHUB_STEP_SUMMARY="$T/sum-rr" \
        bin/ci-plan.sh --out "$T/rr-list" 2>&1); RC=$?
GO=$(cat "$T/go" 2>/dev/null)
{ [ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: .github/actions/zz/action.yml" ]; } && ok \
  || bad "7 rename (git): moving an escalating file away must escalate on its old path (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$OUT]"

# ── 8-11. a fake selector, for the shapes the real one does not produce on demand.
mklist() { local i; : > "$1"; for ((i = 1; i <= $2; i++)); do printf 'tests/s%04d-test.sh\n' "$i" >> "$1"; done; }
mklist "$T/all.txt" 300; mklist "$T/sel30.txt" 30
cat > "$T/fake.sh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_SINK"
[ -z "${FAKE_RC:-}" ] || exit "$FAKE_RC"
OUT=""; CMD=""
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; --changed) shift ;; *) CMD="${CMD:-$1}" ;; esac; shift; done
case "$CMD" in
  select)    cat "$FAKE_SELECT" > "$OUT"
             [ -n "${FAKE_NOREASON:-}" ] || echo "impact: $(grep -c . "$FAKE_SELECT") of 300 suites (selected: 1 changed path(s))" >&2 ;;
  ci-select) cat "${FAKE_CI:-$FAKE_ALL}" > "$OUT"
             echo "impact: $(grep -c . "${FAKE_CI:-$FAKE_ALL}") of 300 suites (${FAKE_REASON:-selected: 1 changed path(s)})" >&2 ;;
esac
FAKE
chmod +x "$T/fake.sh"
FK=(CI_PLAN_IMPACT="$T/fake.sh" FAKE_SINK="$T/sink" FAKE_ALL="$T/all.txt" FAKE_SELECT="$T/sel30.txt")

# 8. a select that fails, or that gives no reason line, is never a plan.
: > "$T/sink"; bplan console-ui/src/screens/Jobs.js -- "${FK[@]}" FAKE_RC=1
{ [ "$RC" = 2 ] && [ -z "$(out n)" ]; } && ok || bad "8: a failed select must be rc 2 with no n= (rc=$RC n=$(out n)) [$OUT]"
bplan console-ui/src/screens/Jobs.js -- "${FK[@]}" FAKE_NOREASON=1
{ [ "$RC" = 2 ] && [ -z "$(out n)" ]; } && ok || bad "8b: a select with no impact line must be rc 2 (rc=$RC n=$(out n)) [$OUT]"

# 9. the run page and the step summary say what the batch ran.
: > "$T/sink"; bplan console-ui/src/screens/Jobs.js -- "${FK[@]}"
grep -q '^select ' "$T/sink" && ok || bad "9: a batch must ask test-impact select: $(cat "$T/sink")"
# the reason is the plan's whole REASON: the select's, then the tier step's note
grep -qx '::notice title=ci-plan::mode=batch-selected count=30 total=300 n=1 reason=selected: 1 changed path(s); tiers: .*' <<<"$OUT" && ok \
  || bad "9: the run page must carry the ci-plan notice [$OUT]"
{ has "impact: 30 of 300 suites (selected: 1 changed path(s); tiers: " "$SUM" && has " — 1 shard(s), mode=batch-selected" "$SUM" \
    && grep -qx 'escalation: -' <<<"$SUM"; } && ok \
  || bad "9: the step summary must carry the impact line and the escalation [$SUM]"

# 10. a select of every suite is a full run, whatever it called itself.
bplan console-ui/src/screens/Jobs.js -- "${FK[@]}" FAKE_SELECT="$T/all.txt"
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "the selection is every suite" ]; } && ok \
  || bad "10: a select of every suite must be mode=full (mode=$(out mode) escalation='$(out escalation)')"

# 11. an ordinary PR is exactly as before: ci-select, no notice, escalation=-.
: > "$T/sink"; rm -f "$T/go" "$T/sum"
OUT=$(env GITHUB_ACTIONS=true CI_EVENT=pull_request TI_PR_HEAD_REF=ticket/x TI_BASE="$HEADSHA" "${FK[@]}" FAKE_CI="$T/sel30.txt" \
        CI_PLAN_CHANGED_FILE="$T/changed" GITHUB_OUTPUT="$T/go" GITHUB_STEP_SUMMARY="$T/sum" "$PLAN" --out "$T/list" 2>&1); RC=$?
GO=$(cat "$T/go" 2>/dev/null)
{ [ "$RC" = 0 ] && [ "$(out mode)" = selected ] && [ "$(out escalation)" = - ]; } && ok \
  || bad "11: an ordinary PR stays mode=selected with escalation=- (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$OUT]"
has "::notice" "$OUT" && bad "11: an ordinary PR prints no ci-plan notice [$OUT]" || ok
[ ! -s "$T/sum" ] && ok || bad "11: an ordinary PR writes no step summary: $(cat "$T/sum")"
[ "$(cut -d' ' -f1 "$T/sink" | sort -u)" = ci-select ] && ok || bad "11: an ordinary PR only calls ci-select: $(cat "$T/sink")"
[ "$(printf '%s\n' "$GO" | sed 's/=.*//' | tr '\n' ' ')" = "mode count total n shards corpus summary quarantine escalation own_base spa worker push_class sizing shard_budget_s max_shards " ] && ok \
  || bad "11: an ordinary PR's outputs are the old keys plus escalation, own_base (BH-6490), spa and worker (BH-4969), push_class (BH-6746), sizing, shard_budget_s and max_shards (BH-6876): $(printf '%s\n' "$GO" | sed 's/=.*//' | tr '\n' ' ')"

echo "ci-plan-batch-impact.bh-4968-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
