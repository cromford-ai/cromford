#!/bin/bash
# tests/plan-blocked-stop.bh-8309-test.sh — BH-8309: the pool stops relaunching
# a PLAN_BLOCKED key.
#
# THE INCIDENT (cromford, 2026-10-25). 12 tickets looped plan -> PLAN_BLOCKED
# -> re-queued -> plan again until the per-key spawn cap (12 in 24 h). BH-7405,
# BH-7864 and BH-7865 stopped 20 times each in 2 days: 100 Fly runs in one day.
#
# Since BH-8733 the gate decides from the ticket's build_queue phase, not from
# the hub build records (the A-G record cases of this suite went with them).
# That behavior is pinned in tests/plan-blocked-stop.bh-8733-test.sh. Kept here:
#   C3 bin/fly-pool.sh sources bin/lib/plan-blocked-stop.sh.
#   F  the switch POOL_PLAN_BLOCKED_STOP is a fly-pool lane knob, default 1.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/plan-blocked-stop.bh-8309-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

LIB="$DIR/bin/lib/plan-blocked-stop.sh"
[ -f "$LIB" ] && ok || bad "missing bin/lib/plan-blocked-stop.sh"

# ═════ C: the wiring ════════════════════════════════════════════════════════
grep -qE '^\. "\$HARNESS/bin/lib/plan-blocked-stop.sh"' "$DIR/bin/fly-pool.sh" && ok || bad "C3 bin/fly-pool.sh must source bin/lib/plan-blocked-stop.sh"

# ═════ F: the knob ══════════════════════════════════════════════════════════
for kv in POOL_PLAN_BLOCKED_STOP=1; do
  k="${kv%=*}"; v="${kv#*=}"; f="$DIR/catalog/lanes.d/fly-pool.knobs.d/$k.json"
  [ "$(jq -r '.default' "$f" 2>/dev/null)" = "$v" ] && [ "$(jq -r '.read_in' "$f" 2>/dev/null)" = bin/lib/plan-blocked-stop.sh ] \
    && ok || bad "F $k: want a knob fragment with default $v read in bin/lib/plan-blocked-stop.sh"
  grep -q "\${$k:-$v}" "$LIB" 2>/dev/null && ok || bad "F $k: the code fallback must be \${$k:-$v}"
done

echo "plan-blocked-stop.bh-8309: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
