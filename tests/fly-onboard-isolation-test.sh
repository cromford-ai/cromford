#!/bin/bash
# tests/fly-onboard-isolation-test.sh — onboarding ONE project touches exactly
# one project (BH-662).
#
# WHY. bin/fly-pool-rollout.sh loops over "$@" and defaults to a THREE-project
# list when given none. `bin/fly-onboard.sh <p>` passing one positional is the
# entire isolation mechanism, so it is worth an assertion that a wrong
# invocation would break: after onboarding alpha there must be no beta flag, no
# beta state file, no flyctl call naming beta, and env/fly.env must be byte
# identical (the rollout appends a minted token there, and a token minted for
# the wrong project is a credential nobody expected to exist).
#
# MUTATION NOTE (D1): let a second project reach the rollout invocation in
# bin/fly-onboard.sh and §1 goes red on the beta assertions.
#
# Run from anywhere: tests/fly-onboard-isolation-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || SCRATCH_FALLBACK=1
# BRIDGE until BH-459/#609 lands tests/lib/scratch.sh on main.
if [ "${SCRATCH_FALLBACK:-}" = 1 ]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/bh662.XXXXXX"); trap 'rm -rf "$T"' EXIT
fi
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset HARNESS_TICKET HUB_BUILD_OK HUB_NO_BUILD_LANES HUB_BOX_NAME BOX_NAME
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
. "$(dirname "$0")/lib/fly-onboard-fixture.sh" || exit 1

S="$T/iso"; fly_onboard_fixture "$S"
cp "$S/env/fly.env" "$T/fly.env.before"

# ══ 1. ONBOARD ALPHA — beta must be untouched in every store ════════════════
OUT=$(BOX_NAME=box-hub bash "$S/bin/fly-onboard.sh" alpha 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "alpha must onboard (got $RC): $OUT"
[ "$(ls "$S/flags" | grep -c beta)" = 0 ] \
  && ok || bad "no beta flag may exist after onboarding alpha (got: $(ls "$S/flags" | grep beta))"
[ "$(ls "$S/state/fly" | grep -c beta)" = 0 ] \
  && ok || bad "no beta state file may exist after onboarding alpha"
[ "$(grep -c beta "$S/logs/flyctl-calls.log")" = 0 ] \
  && ok || bad "no flyctl call may name beta (got: $(grep beta "$S/logs/flyctl-calls.log"))"
cmp -s "$S/env/fly.env" "$T/fly.env.before" \
  && ok || bad "env/fly.env must be byte-identical — no token was minted here"
[ ! -e "$S/locks/fly-onboard-beta.lock" ] \
  && ok || bad "no lock may be taken for a project that was not asked for"
[ "$(sort -u "$S/logs/ssh.log" | wc -l)" = 1 ] \
  && ok || bad "exactly one box was told about exactly one flag (got: $(cat "$S/logs/ssh.log"))"
grep -q 'builder-fly-alpha' "$S/logs/ssh.log" \
  && ok || bad "the ssh must carry alpha's flag, not another project's"

# ══ 2. NOW ONBOARD BETA — alpha's routing must not move ═════════════════════
for F in fly-pool-alpha builder-fly-alpha fly-pool-app-alpha; do
  cp "$S/flags/$F" "$T/$F.before"
done
OUT=$(BOX_NAME=box-hub bash "$S/bin/fly-onboard.sh" beta 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "beta must onboard (got $RC): $OUT"
for F in fly-pool-alpha builder-fly-alpha fly-pool-app-alpha; do
  cmp -s "$S/flags/$F" "$T/$F.before" \
    && ok || bad "flags/$F must be untouched by beta's onboarding"
done
[ -f "$S/flags/fly-pool-beta" ] && [ -f "$S/flags/builder-fly-beta" ] \
  && ok || bad "beta must end up routed on its own"
grep -q '^FLY_ONBOARD beta OK:' <<<"$OUT" \
  && ok || bad "beta's verdict must be about beta: $OUT"

echo "fly-onboard-isolation: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
