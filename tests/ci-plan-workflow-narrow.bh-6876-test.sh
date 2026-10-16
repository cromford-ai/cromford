#!/bin/bash
# tests/ci-plan-workflow-narrow.bh-6876-test.sh — in a merge-queue batch, an
# edit to a workflow file runs the suites that read that file plus the always
# set, not the whole corpus (BH-6876).
#
# WHY. Every .github/workflows/* diff escalated a batch to the full corpus
# (the `.github/` escalate row and ti_infra_core_re), and BH-6688 only exempted
# harness-ci.yml edits in non-test jobs. The BH-6838 replay showed 5 of 20
# drafts going full on `selection input: .github/workflows/harness-ci.yml`.
# Now an `allow` row in catalog/ci-batch-escalate.tsv lets a top-level
# .github/workflows/*.yml|*.yaml through, and bin/test-impact.sh (batch
# select only) selects it through its map rows. The nightly corpus is the
# backstop for a runner change a narrow batch misses.
#
#   N1  .github/workflows/prequeue-gate.yml alone: batch-selected, the list
#       holds every suite that reads it and the always set, count < total, no
#       `full:` (acceptance test 2)
#   N2  .github/workflows/harness-ci.yml (a tests-shard edit: no git range, so
#       no BH-6688 job classifier): batch-selected, its readers run; the
#       console-ui and worker-jobs jobs stay on (spa=1 worker=1)
#   N3  a new .github/workflows/new.yaml no suite names: the always set and
#       the suites that scan the whole .github/workflows/ directory, nothing else
#   N4  .github/actions/x/action.yml, .github/CODEOWNERS and the nested
#       .github/workflows/sub/x.yml still escalate
#   N5  a workflow and bin/ci-plan.sh: full, `selection input: bin/ci-plan.sh`
#   N6  the ordinary PR select (no TI_BATCH_SELECT) on a workflow path is still
#       `full: infra change (<path>)`
#   N7  CI_FULL_TRIGGERS='+.github/workflows/' adds an escalate row, and the
#       allow row still wins (allow beats escalate, the rules grammar)
#
# The real bin/ci-plan.sh, bin/test-impact.sh and rules drive every case; the
# map is built once and handed to test-impact through a two-line wrapper.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

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
  OUT=$(env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u CI_FULL_TRIGGERS -u CI_PLAN_DURATIONS_FILE \
          CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" \
          CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$T/impact.sh" CI_PLAN_CHANGED_FILE="$T/changed" \
          CI_PLAN_TIER_FILE="$T/notiers.tsv" GITHUB_OUTPUT="$T/go" \
          ${vars[@]+"${vars[@]}"} "$PLAN" --out "$T/list" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
# readers <path> — the suites the map says read it: a row naming the file, or a
# directory row above it (a suite that scans .github/workflows/ reads them all)
readers() { awk -F'\t' -v p="$1" '$2 == p || ($2 ~ /\/$/ && index(p, $2) == 1) { print $1 }' "$T/map" | LC_ALL=C sort -u; }
missing() { LC_ALL=C comm -23 <(LC_ALL=C sort -u "$1") <(LC_ALL=C sort -u "$T/list" 2>/dev/null); }

# selects <tag> <path> — batch-selected, its readers and the always set, no full
selects() {
  local tag="$1" p="$2"
  bplan "$p"
  { [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && [ "$(out escalation)" = - ]; } && ok \
    || bad "$tag: $p must be batch-selected, escalation=- (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$OUT]"
  ! has "full:" "$(out summary)" && ok || bad "$tag: no full: in the summary: '$(out summary)'"
  { [ -n "$(out count)" ] && [ "$(out count)" -lt "$(out total)" ]; } && ok || bad "$tag: count ($(out count)) must be under total ($(out total))"
  [ -z "$(missing "$T/always")" ] && ok || bad "$tag: the always set must run: missing $(missing "$T/always" | head -3 | paste -sd' ')"
  has "workflow: $p selects its readers (BH-6876)" "$(out summary)" && ok || bad "$tag: the reason must say the workflow selects its readers: '$(out summary)'"
}

# ── N1. acceptance test 2: one workflow file selects its readers.
WF1=.github/workflows/prequeue-gate.yml
readers "$WF1" > "$T/r1"
[ "$(grep -c . "$T/r1")" -ge 2 ] || bad "N1 fixture: the map must name at least 2 readers of $WF1 (got $(grep -c . "$T/r1"))"
selects N1 "$WF1"
[ -z "$(missing "$T/r1")" ] && ok || bad "N1: every reader of $WF1 must run: missing $(missing "$T/r1" | head -3 | paste -sd' ')"
EXTRA=$(LC_ALL=C comm -13 <(LC_ALL=C sort -u "$T/r1" "$T/always") <(LC_ALL=C sort -u "$T/list"))
[ -z "$EXTRA" ] && ok || bad "N1: the list is the readers plus the always set, nothing else: $(head -3 <<<"$EXTRA" | paste -sd' ')"

# ── N2. harness-ci.yml, a test-job edit, no git range.
WF2=.github/workflows/harness-ci.yml
readers "$WF2" > "$T/r2"
[ "$(grep -c . "$T/r2")" -ge 2 ] || bad "N2 fixture: the map must name readers of $WF2"
selects N2 "$WF2"
[ -z "$(missing "$T/r2")" ] && ok || bad "N2: every reader of $WF2 must run: missing $(missing "$T/r2" | head -3 | paste -sd' ')"
[ "$(out spa)" = 1 ] && [ "$(out worker)" = 1 ] && ok || bad "N2: the workflow defines the console-ui and worker-jobs jobs, so both stay on (spa=$(out spa) worker=$(out worker))"

# ── N3. a workflow file nothing reads: the always set only.
WF3=.github/workflows/new.yaml
[ -z "$(awk -F'\t' -v p="$WF3" '$2 == p' "$T/map")" ] || bad "N3 fixture: no map row may name $WF3"
bplan "$WF3"
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ]; } && ok || bad "N3: new.yaml must be batch-selected (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$OUT]"
[ "$(LC_ALL=C sort -u "$T/list" 2>/dev/null)" = "$(readers "$WF3" | LC_ALL=C sort -u - "$T/always")" ] && ok \
  || bad "N3: the list must be the always set plus the directory readers ($(grep -c . "$T/list" 2>/dev/null) vs $(grep -c . "$T/always") + $(readers "$WF3" | grep -c .))"

# ── N4. other .github/ paths still escalate.
for p in .github/actions/x/action.yml .github/CODEOWNERS .github/workflows/sub/x.yml; do
  bplan "$p"
  { [ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: $p" ]; } && ok \
    || bad "N4: $p must escalate as 'selection input: $p' (rc=$RC mode=$(out mode) escalation='$(out escalation)')"
done

# ── N5. a workflow beside a self row: the self row escalates.
bplan "$WF1" bin/ci-plan.sh
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: bin/ci-plan.sh" ]; } && ok \
  || bad "N5: a workflow and bin/ci-plan.sh must be full on bin/ci-plan.sh (mode=$(out mode) escalation='$(out escalation)')"

# ── N6. the ordinary PR select keeps the infra answer.
printf '%s\n' "$WF1" > "$T/changed"
SOUT=$(env -u TI_BATCH_SELECT "$T/impact.sh" select --changed "$T/changed" 2>&1 >/dev/null)
has "full: infra change ($WF1)" "$SOUT" && ok || bad "N6: a PR select on a workflow must stay 'full: infra change': [$SOUT]"
SOUT=$(TI_BATCH_SELECT=1 "$T/impact.sh" select --changed "$T/changed" 2>&1 >/dev/null)
! has "full:" "$SOUT" && ok || bad "N6 control: the batch select must not be full: [$SOUT]"

# ── N7. the allow row beats a +pattern escalate row.
bplan "$WF1" -- CI_FULL_TRIGGERS='+.github/workflows/'
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && [ "$(out full_triggers)" = "+.github/workflows/" ]; } && ok \
  || bad "N7: the allow row must win over CI_FULL_TRIGGERS=+.github/workflows/ (mode=$(out mode) escalation='$(out escalation)' full_triggers='$(out full_triggers)')"

echo "ci-plan-workflow-narrow.bh-6876: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
