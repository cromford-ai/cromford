#!/bin/bash
# result-prefix-ok.sh — is this line a canonical harness RESULT line?
#
# mexec stdout is NOT trustworthy. flyctl 1.26.1 ssh-console can panic
# (selectContainer nil-deref) and print "Oops, something went wrong" plus a
# goroutine dump on STDOUT. Callers that treated ANY non-empty mexec stdout as
# a real RESULT reaped and force-destroyed pool machines mid-build
# (MEDIC 4467, 2026-08-30; same class since 2026-08-15: TK-186/206/210,
# TK-93/103/143, TK-95/72, TK-1274). A RESULT is a RESULT only when its first
# line starts with a canonical prefix; anything else is a mexec MISS, not a
# finished build.
#
# usage: result-prefix-ok.sh "<line>"   -> rc 0 = real RESULT, rc 1 = miss
#
# The last four are the pool-rebase RESULT words (BH-486, bin/lib/rebase-job.sh):
# REBASED, CONFLICT and GATE_RED are bare words, REBASE_ covers
# REBASE_LEASE_REJECTED and REBASE_SETUP_FAILED. A flyctl panic never starts
# with any of them, and a leading space is still a miss.
# ROLLOUT_ covers ROLLOUT_FILED and ROLLOUT_FAILED, the rollout lane's two
# answers (bin/run-rollout.sh). Without it a refused rollout was a mexec miss
# while the machine idled and a dead machine after it stopped (BH-4061).
# REREVIEWED and REREVIEW_ are the words of a pool re-review (BH-7635,
# bin/lib/rereview-job.sh); a bare REREVIEW prefix would pass REREVIEWX too.
# REVIEW_ stays anchored, so the two never match each other's words.
# LEAD_REVIEWED and LEAD_REVIEW_ are the words of a pool lead review (BH-8027,
# fly/builder-runner.sh run_leadreview_job).
# CPV_ covers CPV_DEPLOYED, CPV_HEAD_FAILED and CPV_BOX_FAILED, the words of a
# pool console preview row (BH-8030, bin/lib/console-preview-job.sh).
RESULT_PREFIX_RE='^(PR_|PLAN_|REVIEW_|BUILD_|QUEUED_|EXECUTE_|DECOMPOSE|ROLLOUT_|RESULT_|SECURITY_|REFUTE_|QA_|TAMPER_|SMOKE|REBASED|CONFLICT|GATE_RED|REBASE_|REREVIEWED|REREVIEW_|LEAD_REVIEWED|LEAD_REVIEW_|CPV_)'
head -1 <<<"${1:-}" | grep -qE "$RESULT_PREFIX_RE"
