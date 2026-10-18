#!/bin/bash
# tests/ci-plan-spa-worker.bh-4969-test.sh — a merge-queue batch that stays
# batch-selected switches the console-ui and worker-jobs jobs off when none of
# its paths can change what they test (BH-4969, C1 of BH-4964), and nothing
# else ever does.
#
# WHY. BH-4968 shrank a batch's tests-shard run to its impact set, but the SPA
# build and the worker's 300 node tests still ran on every batch, a docs-only
# one included. bin/ci-plan.sh now writes spa= and worker=; a 0 makes the job
# run only its "not affected by this batch" step. The failure to fear is a 0
# that hid a real change, so every path that feeds a job is pinned as 1 below.
#
#   L1-L3  cbe_affects on its own: floors, rows, unknown kind, unreadable TSV
#   B1-B9  the real bin/ci-plan.sh on a batch, per changed path
#   P1-P4  every path that is not batch-selected writes 1/1
#   X1-X3  every path console-ui/ and worker/jobs/ read outside their own tree,
#          and every script the two jobs' workflow steps run, is affected under
#          the real catalog (a new cross-tree import with no row fails here)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
LIB="$DIR/bin/lib/ci-batch-escalate.sh"
REAL_TSV="$DIR/catalog/ci-batch-escalate.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The scratch rules: the real file's spa/worker rows, and one escalate row that
# matches none of the paths below, so cbe_reason passes them to the selection.
grep -P '\t(spa|worker)\t' "$REAL_TSV" > "$T/rules.tsv"
[ "$(grep -c . "$T/rules.tsv")" -ge 9 ] || { echo "FAIL: the real catalog carries fewer than 9 spa/worker rows"; exit 1; }
printf 'zz-never/\tescalate\tmatches nothing here\n' >> "$T/rules.tsv"

# ── L. the lib on its own.
aff() { ( . "$LIB" || exit 9; cbe_affects "$@" ); }
aff spa console-ui/src/x.js && ok || bad "L1: console-ui/ is spa without any row"
CI_BATCH_ESCALATE_TSV="$T/rules.tsv" aff spa console-ui/src/x.js && ok || bad "L1: console-ui/ is spa"
printf 'zz-never/\tescalate\tx\n' > "$T/floor-only.tsv"
CI_BATCH_ESCALATE_TSV="$T/floor-only.tsv" aff worker worker/jobs/x.js && ok || bad "L1: worker/ is worker with its row deleted"
CI_BATCH_ESCALATE_TSV="$T/floor-only.tsv" aff spa console-ui/x.js && ok || bad "L1: console-ui/ is spa with its row deleted"
CI_BATCH_ESCALATE_TSV="$T/rules.tsv" aff spa bin/x.sh && bad "L2: bin/x.sh is not spa" || ok
CI_BATCH_ESCALATE_TSV="$T/rules.tsv" aff worker bin/lib/jobs/cost.sh && ok || bad "L2: bin/lib/jobs/ is worker"
CI_BATCH_ESCALATE_TSV="$T/rules.tsv" aff spa bin/lib/jobs/cost.sh && bad "L2: bin/lib/jobs/ is not spa" || ok
CI_BATCH_ESCALATE_TSV="$T/rules.tsv" aff nope docs/x.md && ok || bad "L3: an unknown kind fails closed"
CI_BATCH_ESCALATE_TSV="$T/no-such.tsv" aff spa docs/x.md && ok || bad "L3: an unreadable TSV fails closed (spa)"
CI_BATCH_ESCALATE_TSV="$T/no-such.tsv" aff worker docs/x.md && ok || bad "L3: an unreadable TSV fails closed (worker)"

# ── The real planner with a fake selector.
mklist() { local i; : > "$1"; for ((i = 1; i <= $2; i++)); do printf 'tests/s%04d-test.sh\n' "$i" >> "$1"; done; }
mklist "$T/all.txt" 10; mklist "$T/sel.txt" 3
cat > "$T/fake.sh" <<'FAKE'
#!/bin/bash
OUT=""; CMD=""
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; --changed) shift ;; *) CMD="${CMD:-$1}" ;; esac; shift; done
case "$CMD" in
  select)    cat "$FAKE_SELECT" > "$OUT"; echo "impact: 3 of 10 suites (selected)" >&2 ;;
  ci-select) cat "$FAKE_ALL" > "$OUT"; echo "impact: 10 of 10 suites (full: fake)" >&2 ;;
esac
FAKE
chmod +x "$T/fake.sh"
: > "$T/notiers.tsv"
HEADSHA=$(git -C "$DIR" rev-parse HEAD)

# run <VAR=val ...> — one plan; sets RC OUT GO
run() {
  rm -f "$T/go" "$T/list"
  OUT=$(env -u GITHUB_ACTIONS -u CI_PR_BODY -u TI_PR_TITLE -u CI_REPO -u GITHUB_STEP_SUMMARY \
          CI_PLAN_IMPACT="$T/fake.sh" FAKE_ALL="$T/all.txt" FAKE_SELECT="$T/sel.txt" \
          CI_PLAN_TIER_FILE="$T/notiers.tsv" CI_QUARANTINE= TI_PR_LABELS= GITHUB_OUTPUT="$T/go" \
          "$@" "$PLAN" --out "$T/list" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
# bplan <tsv> <path>... [-- VAR=val ...] — a batch plan over those paths
bplan() {
  local tsv="$1" paths=(); shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do paths+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  printf '%s\n' "${paths[@]}" > "$T/changed"
  run CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" CI_PLAN_ESCALATION=- \
      CI_PLAN_CHANGED_FILE="$T/changed" CI_BATCH_ESCALATE_TSV="$tsv" "$@"
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
want() { # want <tag> <mode> <spa> <worker>
  { [ "$RC" = 0 ] && [ "$(out mode)" = "$2" ] && [ "$(out spa)" = "$3" ] && [ "$(out worker)" = "$4" ]; } && ok \
    || bad "$1: want mode=$2 spa=$3 worker=$4, got rc=$RC mode=$(out mode) spa=$(out spa) worker=$(out worker) escalation='$(out escalation)' [$OUT]"
}

bplan "$T/rules.tsv" console-ui/src/screens/Jobs.js;       want "B1 console-ui" batch-selected 1 0
bplan "$T/rules.tsv" worker/jobs/src/index.js;             want "B2 worker" batch-selected 0 1
bplan "$T/rules.tsv" catalog/lanes.d/x.json;               want "B3 lanes.d" batch-selected 1 1
bplan "$T/rules.tsv" catalog/lanes.json;                   want "B3 lanes.json" batch-selected 1 1
bplan "$T/rules.tsv" worker/jobs/schema.sql;               want "B3 schema.sql" batch-selected 1 1
bplan "$T/rules.tsv" bin/lib/jobs/cost.sh;                 want "B4 bin/lib/jobs" batch-selected 0 1
bplan "$T/rules.tsv" bin/x.sh;                             want "B5 bin/x.sh" batch-selected 0 0
bplan "$T/rules.tsv" docs/x.md;                            want "B6 docs" batch-selected 0 0
[ "$(grep -c . "$T/list" 2>/dev/null)" = 3 ] && ok || bad "B6: docs alone still runs a non-empty list: $(cat "$T/list" 2>/dev/null)"
[ "$(out count)" = 3 ] && ok || bad "B6: count=3, got '$(out count)'"
bplan "$T/rules.tsv" docs/x.md console-ui/old.js bin/old.js; want "B6 rename out of console-ui (both paths)" batch-selected 1 0
bplan "$T/rules.tsv" docs/x.md worker/jobs/a.js console-ui/b.js; want "B6 both" batch-selected 1 1
# BH-7287: a selection input is an infra row; spa and worker stay on in infra mode.
printf 'tests/ci-plan-test.sh\n' > "$T/canary.txt"
bplan "$REAL_TSV" bin/lib/suite-runner.sh -- CI_INFRA_CANARY_FILE="$T/canary.txt"; want "B7 real TSV plans infra" infra 1 1
[ "$(out escalation)" = - ] && ok || bad "B7: escalation '$(out escalation)'"
grep -qxF tests/ci-plan-test.sh "$T/list" && ok || bad "B7: the infra list must carry the canary"
# BH-6059: bin/lib/ is no longer escalated whole, so an ordinary bin/lib/ path
# stays batch-selected and its worker row still gates the worker job.
bplan "$REAL_TSV" bin/lib/jobs/cost.sh;                    want "B7b real TSV bin/lib/jobs" batch-selected 0 1
bplan "$REAL_TSV" console-ui/src/screens/Jobs.js;          want "B7 real TSV console-ui" batch-selected 1 0
bplan "$REAL_TSV" worker/jobs/src/index.js;                want "B7 real TSV worker" batch-selected 0 1
bplan "$T/no-such.tsv" docs/x.md;                          want "B8 unreadable TSV" full 1 1
# B9: paths OUTSIDE the two trees that the jobs read (BH-4969 review). Each
# one stays batch-selected under the real catalog and still runs its job.
bplan "$REAL_TSV" worker/jobs/src/lib/config-changes.js;  want "B9 config-changes.js (console-ui parity tests import it)" batch-selected 1 1
bplan "$REAL_TSV" worker/watchdog/src/standby.js;         want "B9 watchdog standby.js (console-ui test imports it)" batch-selected 1 1
bplan "$REAL_TSV" bin/worker-schema-upgrade.sh;           want "B9 worker-schema-upgrade.sh (a worker-jobs step)" batch-selected 0 1
bplan "$REAL_TSV" bin/lanes-build.sh;                     want "B9 lanes-build.sh (a worker-jobs step)" batch-selected 0 1
bplan "$REAL_TSV" tests/fixtures/daily-digest/empty-day.json; want "B9 daily-digest fixtures" batch-selected 0 1
bplan "$REAL_TSV" bin/agent-call.sh;                      want "B9 agent-call.sh (egress-seed test reads it)" batch-selected 0 1
bplan "$REAL_TSV" fleet.conf;                             want "B9 fleet.conf (projects test reads it)" batch-selected 0 1
bplan "$REAL_TSV" docs/x.md worker/watchdog/src/standby.js; want "B9 docs + watchdog" batch-selected 1 1
# The ones that also escalate carry a row of their own, so cbe_affects answers
# yes even if the escalate row went away.
for p in bin/lib/d1-schema.sh bin/lib/hub-probes/common.sh bin/lib/mc/log.sh catalog/llm-sites.json \
         catalog/context-budgets.json catalog/model-prices.json catalog/readiness-levels.json; do
  CI_BATCH_ESCALATE_TSV="$REAL_TSV" aff worker "$p" && ok || bad "B9: $p is worker by its own row"
done

# ── P. every path that is not batch-selected writes 1/1.
bplan "$T/rules.tsv" docs/x.md -- TI_PR_LABELS=full;       want "P1 full label" full 1 1
run CI_EVENT=workflow_dispatch;                            want "P2 dispatch" full 1 1
printf '#!/bin/bash\nexit 1\n' > "$T/gh-fail"; chmod +x "$T/gh-fail"
run CI_EVENT=push CI_ACTOR='mergify[bot]' CI_REPO=o/r CI_PLAN_GH="$T/gh-fail" CI_PLAN_SETTLE_S=0 CI_PLAN_MAIN_HEAD_CMD="echo s0" CI_SHA=s0
want "P3 push the queue did not test" full 1 1
printf '#!/bin/bash\necho %s\n' "'{\"workflow_runs\":[]}'" > "$T/gh-empty"; chmod +x "$T/gh-empty"
run CI_EVENT=push CI_ACTOR='mergify[bot]' CI_REPO=o/r CI_PLAN_GH="$T/gh-empty" CI_PLAN_SETTLE_S=0 CI_PLAN_MAIN_HEAD_CMD="echo s9" CI_SHA=s0
{ [ "$(out corpus)" = 0 ] && [ "$(out spa)" = 1 ] && [ "$(out worker)" = 1 ]; } && ok \
  || bad "P4: queue-tested corpus=0 writes spa=1 worker=1 (corpus=$(out corpus) spa=$(out spa) worker=$(out worker)) [$OUT]"
run CI_EVENT=pull_request TI_PR_HEAD_REF=ticket/x TI_BASE="$HEADSHA" CI_PLAN_CHANGED_FILE="$T/changed"
{ [ "$(out mode)" != batch-selected ] && [ "$(out spa)" = 1 ] && [ "$(out worker)" = 1 ]; } && ok \
  || bad "P4: an ordinary PR writes spa=1 worker=1 (mode=$(out mode) spa=$(out spa) worker=$(out worker))"

# ── X. the cross-tree guard. Every quoted ../ path in console-ui/ (spa) and
# worker/jobs/ (worker) source that resolves OUTSIDE its own tree must be
# affected under the real catalog, and so must every bin/ script the two jobs'
# workflow steps run. A template tail (`${name}`) is cut, and a directory is
# probed as a file under it.
xchk() { # xchk <kind> <tree> — prints the uncovered targets, sets XN
  local kind="$1" tree="$2" f m tgt probe
  XN=0
  while IFS= read -r f; do
    while IFS= read -r m; do
      m=${m:1:${#m}-2}; m=${m%%\$\{*}
      tgt=$(realpath -m --relative-to="$DIR" "$DIR/$(dirname "$f")/$m")
      case "$tgt" in .|"$tree"|"$tree"/*) continue ;; esac
      XN=$((XN + 1))
      probe="$tgt"
      { [ -d "$DIR/$tgt" ] || [[ $m == */ ]]; } && probe="$tgt/x"
      CI_BATCH_ESCALATE_TSV="$REAL_TSV" aff "$kind" "$probe" || echo "$f -> $tgt"
    done < <(grep -oE "['\"\`](\.\./)+[^'\"\`]*['\"\`]" "$DIR/$f")
  done < <(git -C "$DIR" ls-files -- "$tree" | grep -E '\.(m?js|cjs|jsx|ts|tsx)$')
}
miss=$(xchk spa console-ui)
[ -z "$miss" ] && ok || bad "X1: console-ui/ reads these outside its tree with no spa row: $miss"
miss=$(xchk worker worker/jobs)
[ -z "$miss" ] && ok || bad "X2: worker/jobs/ reads these outside its tree with no worker row: $miss"
# Not vacuous: the scan found the cross-tree reads that exist today.
XN=0; xchk spa console-ui >/dev/null; xs=$XN; xchk worker worker/jobs >/dev/null; xw=$XN
{ [ "$xs" -ge 5 ] && [ "$xw" -ge 15 ]; } && ok || bad "X: the scan found too few cross-tree reads (spa=$xs worker=$xw) — the pattern stopped matching"
WF="$DIR/.github/workflows/harness-ci.yml"
for kind in spa worker; do
  case "$kind" in spa) job=console-ui ;; worker) job=worker-jobs ;; esac
  scripts=$(awk -v j="  $job:" '$0 == j {on = 1; next} on && /^  [a-z-]+:$/ {on = 0} on' "$WF" \
            | grep -v '^ *#' | grep -oE 'bin/[A-Za-z0-9_./-]+\.sh' | sort -u)
  for s in $scripts; do
    CI_BATCH_ESCALATE_TSV="$REAL_TSV" aff "$kind" "$s" && ok || bad "X3: the $job job runs $s, which has no $kind row"
  done
  [ "$kind" = spa ] || [ -n "$scripts" ] && ok || bad "X3: found no bin/ script in the $job job — the extraction broke"
done

# The step summary names both on a batch.
bplan "$T/rules.tsv" console-ui/src/screens/Jobs.js -- GITHUB_STEP_SUMMARY="$T/sum"
grep -qx 'spa: 1 worker: 0' "$T/sum" 2>/dev/null && ok || bad "S: the step summary must carry 'spa: 1 worker: 0': $(cat "$T/sum" 2>/dev/null)"

echo "ci-plan-spa-worker.bh-4969-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
