# shellcheck shell=bash
# bin/merge-conductor.d/bh-8457-pr-record-serve.sh - THE OPEN LIST'S MERGE-STATE
# READS, ANSWERED FROM THE PR RECORD FIRST (BH-8457). Sourced by
# bin/merge-conductor.sh (the BH-7453 fragment block), before the first tick.
#
# bin/lib/gh-pr-list.sh asks bin/lib/pr-record-serve.sh (prr_serve_state,
# PR_RECORD_SERVE_MAX_AGE_S) for each row's merge state when HPL_PR_RECORD=1;
# a miss reads the snapshot or GitHub as before. The decision reads
# (mc_pr_view, mc_rest_pr_json, mc_pr_live_head) stay live. No lib: no-op.
# shellcheck source=bin/lib/pr-record-serve.sh
. "$H/bin/lib/pr-record-serve.sh" 2>/dev/null || true
if command -v prr_serve_state >/dev/null 2>&1; then export HPL_PR_RECORD=1; fi
