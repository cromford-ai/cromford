#!/bin/bash
# tests/ci-plan-size-180.bh-8050-test.sh — BH-8050: bin/ci-plan.sh sizes a
# selection of 180 suites into at most 2 shards.
#
# The ticket's target is a merge-queue batch near 180 suites, and its cost is
# the shard count. This pins the sizing the ticket names; it changes no product
# code.
#
#   P1  no durations file (the count rule, CI_SUITES_PER_SHARD default 120):
#       n <= 2
#   P2  180 suites at 5 s (900 s) under `# source: cache`, budget 480: n = 2
#       and every shard of the split is <= 480 s
#   P3  the near miss: 180 suites at 6 s (1,080 s): n = 3, so P2 is a
#       measurement and not a cap
#
# bin/test-impact.sh is a recording fake (FAKE_SELECT, the seam of
# tests/ci-plan-time-sizing.bh-6876-test.sh); the planner under test is the
# real bin/ci-plan.sh with the real bin/lib/suite-runner.sh.
#
# Self-contained: no network, no secrets, no clock read.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fake-impact.sh" <<'FAKE'
#!/bin/bash
OUT=""
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; *) CMD="$1" ;; esac; shift; done
echo "impact: $(grep -c . "$FAKE_SELECT") of 2000 suites (selected: 1 changed path(s))" >&2
if [ -n "$OUT" ]; then cat "$FAKE_SELECT" > "$OUT"; else cat "$FAKE_SELECT"; fi
FAKE
chmod +x "$T/fake-impact.sh"

# mkdur <list> <durations> <source> <seconds> — 180 suites of one weight, in
# the format bin/ci-durations.sh writes.
mkdur() {
  local i
  : > "$1"; printf '# source: %s\n' "$3" > "$2"
  for ((i = 1; i <= 180; i++)); do
    printf 'tests/t%03d-test.sh\n' "$i" >> "$1"
    printf 'tests/t%03d-test.sh\t%.1f\t9001\t%.1f\n' "$i" "$4" "$4" >> "$2"
  done
}

# plan [VAR=value ...] — the real planner as an ordinary PR; sets RC OUT GO.
plan() {
  rm -f "$T/go" "$T/list"
  OUT=$(env -u CI_SUITES_PER_SHARD -u CI_MAX_SHARDS -u CI_SHARD_BUDGET_S -u CI_PLAN_DURATIONS_FILE \
          -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u CI_BASE_REF -u CI_DISPATCH_SCOPE \
          CI_EVENT=pull_request TI_PR_HEAD_REF=ticket/bh-8050-fixture TI_BASE=deadbeef \
          CI_PLAN_IMPACT="$T/fake-impact.sh" GITHUB_OUTPUT="$T/go" "$@" \
          "$PLAN" --out "$T/list" 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
sizing() { printf '%s\n' "$OUT" | sed -n 's/^ci-plan: sizing: //p' | tail -1; }
# loads <n> <list> <dur> — the per-shard load in ms of the split the shards run.
loads() {
  # shellcheck disable=SC2046 # one suite path per line, no spaces
  ( . "$DIR/bin/lib/suite-runner.sh" || exit 9
    SUITE_DURATIONS_FILE="$3" suite_shard_plan "$1" $(cat "$2") ) \
    | awk -F'\t' '{ s[$1] += $2 } END { for (k in s) print s[k] }' | sort -rn
}

# ── P1: the count rule.
mkdur "$T/p1.list" "$T/p1.dur" cache 5
plan FAKE_SELECT="$T/p1.list"
N=$(out n)
[ "$RC" = 0 ] && [ -n "$N" ] && [ "$N" -le 2 ] && ok || bad "P1: 180 suites with no durations must be <= 2 shards (rc=$RC n='$N') [$(sizing)]"
case "$(sizing)" in *count*) ok ;; *) bad "P1: the sizing line must say count: '$(sizing)'" ;; esac

# ── P2: by time, 900 s on a 480 s budget.
plan FAKE_SELECT="$T/p1.list" CI_PLAN_DURATIONS_FILE="$T/p1.dur" CI_SHARD_BUDGET_S=480 CI_MAX_SHARDS=16
[ "$RC" = 0 ] && [ "$(out n)" = 2 ] && ok || bad "P2: 180 suites of 5 s must be 2 shards (rc=$RC n='$(out n)') [$(sizing)]"
case "$(sizing)" in "time (cache), 2 shard(s)"*) ok ;; *) bad "P2: the sizing line must say time (cache), 2 shard(s): '$(sizing)'" ;; esac
over=$(loads 2 "$T/p1.list" "$T/p1.dur" | awk '$1 > 480000' | grep -c .)
[ "$over" = 0 ] && ok || bad "P2: $over shard(s) of the split are over 480 s: $(loads 2 "$T/p1.list" "$T/p1.dur" | paste -sd' ')"

# ── P3: the near miss, 1,080 s.
mkdur "$T/p3.list" "$T/p3.dur" cache 6
plan FAKE_SELECT="$T/p3.list" CI_PLAN_DURATIONS_FILE="$T/p3.dur" CI_SHARD_BUDGET_S=480 CI_MAX_SHARDS=16
[ "$RC" = 0 ] && [ "$(out n)" = 3 ] && ok || bad "P3: 180 suites of 6 s must be 3 shards (rc=$RC n='$(out n)') [$(sizing)]"

echo "ci-plan-size-180-8050: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
