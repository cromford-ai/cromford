#!/bin/bash
# tests/determinism-lint-bin-batch1.bh-6652-test.sh — BH-6652 (C1 of #6109):
# the 17 bin/ files of batch 1 hold no race-sigpipe-echo hit, and the rewritten
# lib checks still read a true match as a match when the input is bigger than
# one pipe buffer. bin/ is not in the rule's scope until C6, so this suite
# builds that scope line into a temp conf and lints these files only.
. "$(dirname "$0")/lib/scratch.sh" || exit 1
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

FILES="bin/cost-caps-seed.sh bin/cost-rows-acct-backfill.sh bin/disk-clean.sh
bin/env-diff.sh bin/file-health-ticket.sh bin/fix-round-claim.sh
bin/fleet-status-push.sh bin/fly-dispatch.sh bin/fly-pool.sh
bin/fly-results-ingest.sh bin/guardrail-promote.sh bin/harness-ctl.sh
bin/lead-review-land.sh bin/lead-review.sh bin/lib/alert-state.sh
bin/lib/archie.sh bin/lib/budget-stop.sh"

echo "1. lint with the bin/ scope line: rc 0, no race-sigpipe-echo finding"
cp catalog/determinism-lint.conf "$T/scope.conf"
printf 'scope race-sigpipe-echo (^|/)bin/.*\\.sh$\n' >> "$T/scope.conf"
# shellcheck disable=SC2086
DETERMINISM_LINT_CONF="$T/scope.conf" bin/test-determinism-lint.sh $FILES > "$T/lint.out" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "lint rc 0" || no "lint rc $rc: $(grep -m3 ": race-sigpipe-echo:" "$T/lint.out" | cut -d: -f1,2 | tr '\n' ' ')"
grep -q ': race-sigpipe-echo:' "$T/lint.out" && no "race-sigpipe-echo finding left" || ok "no race-sigpipe-echo finding"

echo "2. bash -n on each file"
bad=""
for f in $FILES; do bash -n "$f" 2>/dev/null || bad="$bad $f"; done
[ -z "$bad" ] && ok "bash -n clean" || no "bash -n failed:$bad"

echo "3. a match on line 1 of a 1 MB input is a match under pipefail"
BIG=$(awk 'BEGIN { for (i = 0; i < 20000; i++) printf "%050d\n", i }')
(
  set -o pipefail
  . bin/lib/archie.sh
  archie_sensitive "deploy" "$BIG" ""
) && ok "archie_sensitive true match" || no "archie_sensitive read a true match as a miss"
(
  set -o pipefail
  . bin/lib/archie.sh
  archie_sensitive "nothing here" "$BIG" ""
) && no "archie_sensitive matched clean input" || ok "archie_sensitive clean input is a miss"
(
  set -o pipefail
  . bin/lib/alert-state.sh
  _as_names_word "gonebox down
$BIG" gonebox
) && ok "_as_names_word true match" || no "_as_names_word read a true match as a miss"
(
  set -o pipefail
  . bin/lib/alert-state.sh
  _as_names_word "gonebox-staging down
$BIG" gonebox
) && no "_as_names_word matched a longer word" || ok "_as_names_word keeps whole-word reading"

echo
echo "determinism-lint-bin-batch1.bh-6652: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
