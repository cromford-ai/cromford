#!/bin/bash
# tests/ci-plan-prompt-markers-spa.bh-8193-test.sh — a batch that changes
# catalog/prompt-markers.json runs the console-ui job (BH-8193).
#
# WHY. #8154 (BH-7973) made console-ui/src/ui/PromptEditor.js import
# catalog/prompt-markers.json, a path outside console-ui/. The catalog had a
# worker row for it and no spa row, so a batch that changed only the marker
# list wrote spa=0 and skipped the console-ui build and tests.
#
#   A1  the real bin/ci-plan.sh on a batch of that path writes spa=1 worker=1
#   A2  cbe_affects spa answers yes under the real catalog
#   A3  the worker row still answers yes
#   N1  a near-miss path (.bak) is not spa: the row is exact, not a prefix
#   N2  the real catalog minus the spa row answers no: the row turns it on
#
# CI_BATCH_ESCALATE_TSV, when set, replaces the real catalog for A1-A3 (so a
# run against an older catalog shows A1/A2 red).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
LIB="$DIR/bin/lib/ci-batch-escalate.sh"
P=catalog/prompt-markers.json
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A copy of the composed rules (the fragments in catalog/ci-batch-escalate.d/,
# BH-8649), so a process substitution can be read more than once.
( . "$LIB" && unset CI_BATCH_ESCALATE_TSV && cbe_rules "$DIR" ) > "$T/real.tsv" \
  || { echo "FAIL: cannot read the catalog"; exit 1; }
unset CI_BATCH_ESCALATE_TSV
aff() { ( . "$LIB" || exit 9; cbe_affects "$@" ); }

# ── A1. the real planner, a fake selector, a batch that changes only $P.
cat > "$T/fake.sh" <<'FAKE'
#!/bin/bash
OUT=""; CMD=""
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; --changed) shift ;; *) CMD="${CMD:-$1}" ;; esac; shift; done
case "$CMD" in
  select)    printf 'tests/s0001-test.sh\n' > "$OUT"; echo "impact: 1 of 2 suites (selected)" >&2 ;;
  ci-select) printf 'tests/s0001-test.sh\ntests/s0002-test.sh\n' > "$OUT"; echo "impact: 2 of 2 suites (full: fake)" >&2 ;;
esac
FAKE
chmod +x "$T/fake.sh"
: > "$T/notiers.tsv"
printf '%s\n' "$P" > "$T/changed"
OUT=$(env -u GITHUB_ACTIONS -u CI_PR_BODY -u TI_PR_TITLE -u CI_REPO -u GITHUB_STEP_SUMMARY \
        CI_PLAN_IMPACT="$T/fake.sh" CI_PLAN_TIER_FILE="$T/notiers.tsv" CI_QUARANTINE= TI_PR_LABELS= \
        GITHUB_OUTPUT="$T/go" CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t \
        TI_BASE="$(git -C "$DIR" rev-parse HEAD)" CI_PLAN_ESCALATION=- CI_PLAN_CHANGED_FILE="$T/changed" \
        CI_BATCH_ESCALATE_TSV="$T/real.tsv" "$PLAN" --out "$T/list" 2>&1); RC=$?
out() { sed -n "s/^$1=//p" "$T/go" 2>/dev/null | tail -1; }
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && [ "$(out spa)" = 1 ] && [ "$(out worker)" = 1 ]; } && ok \
  || bad "A1: want mode=batch-selected spa=1 worker=1, got rc=$RC mode=$(out mode) spa=$(out spa) worker=$(out worker) [$OUT]"

# ── A2, A3, N1 under the real catalog.
CI_BATCH_ESCALATE_TSV="$T/real.tsv" aff spa "$P" && ok || bad "A2: $P is spa under the real catalog"
CI_BATCH_ESCALATE_TSV="$T/real.tsv" aff worker "$P" && ok || bad "A3: $P is still worker"
CI_BATCH_ESCALATE_TSV="$T/real.tsv" aff spa "$P.bak" && bad "N1: $P.bak is not spa" || ok

# ── N2. the real catalog minus the spa row for $P.
grep -vP "^\Q$P\E\tspa\t" "$T/real.tsv" > "$T/minus.tsv"
[ "$(grep -c . "$T/minus.tsv")" -gt 100 ] && ok || bad "N2: the stripped catalog is not the real one"
CI_BATCH_ESCALATE_TSV="$T/minus.tsv" aff spa "$P" && bad "N2: $P is spa without its row" || ok

echo "ci-plan-prompt-markers-spa.bh-8193-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
