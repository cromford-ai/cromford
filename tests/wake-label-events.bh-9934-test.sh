#!/bin/bash
# tests/wake-label-events.bh-9934-test.sh — BH-9934: the new pr wake events
# pull_request.<labeled|unlabeled>.<merge-queue|dequeued|merge-queue-paused>
# (worker/jobs/src/lib/core.js wakeOf) are not misread by the shell wake
# classes that read pr rows:
#   bin/lib/wake-class-pr-closed.sh  exact pull_request.labeled = "queued"
#   bin/lib/wake-class-pr-lead.sh    opened/reopened/ready_for_review/synchronize
#   bin/lib/wake-class-pr-ci.sh      the same four actions
# Control: bare pull_request.labeled (the `queued` label) still counts as queued.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-label-events.bh-9934-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# shellcheck source=bin/lib/wake-class-pr-closed.sh
. "$DIR/bin/lib/wake-class-pr-closed.sh" || exit 1
# shellcheck source=bin/lib/wake-class-pr-lead.sh
. "$DIR/bin/lib/wake-class-pr-lead.sh" || exit 1
# shellcheck source=bin/lib/wake-class-pr-ci.sh
. "$DIR/bin/lib/wake-class-pr-ci.sh" || exit 1
owns() { return 0; }
IS_HUB=0

NEW_EVENTS="pull_request.labeled.dequeued pull_request.unlabeled.merge-queue pull_request.labeled.merge-queue-paused
pull_request.labeled.merge-queue pull_request.unlabeled.dequeued pull_request.unlabeled.merge-queue-paused"
for EV in $NEW_EVENTS; do
  WC_PR_CLOSED=0; WC_PR_CLOSED_PRS=""; WC_PR_QUEUED_PRS=""; WC_PR_PH=0
  WC_PR_LEAD_PRS=""; WC_CI_PROJECTS=""
  wc_pr_closed_row proj pr 77 "$EV" o/repo 1
  wc_pr_lead_row proj pr 77 "$EV" o/repo 1
  wc_pr_ci_row proj pr 77 "$EV" o/repo 1
  [ -z "$WC_PR_QUEUED_PRS" ] && ok || bad "$EV: read as queued: '$WC_PR_QUEUED_PRS'"
  [ "$WC_PR_CLOSED" = 0 ] && [ -z "$WC_PR_CLOSED_PRS" ] && ok || bad "$EV: read as a closure"
  [ "$WC_PR_PH" = 0 ] && ok || bad "$EV: launched a pipeline-health re-judge"
  [ -z "$WC_PR_LEAD_PRS" ] && ok || bad "$EV: queued a lead review: '$WC_PR_LEAD_PRS'"
  [ -z "${WC_CI_PROJECTS// /}" ] && ok || bad "$EV: queued a review-prs run: '$WC_CI_PROJECTS'"
done

# Control: the `queued` label row of today is still a queued PR.
WC_PR_QUEUED_PRS=""; WC_PR_PH=0
wc_pr_closed_row proj pr 78 pull_request.labeled o/repo 2
[ "$WC_PR_QUEUED_PRS" = "o/repo#78" ] && ok || bad "control: pull_request.labeled must still be queued: '$WC_PR_QUEUED_PRS'"
[ "$WC_PR_PH" = 1 ] && ok || bad "control: pull_request.labeled must still re-judge"

echo "wake-label-events.bh-9934: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
