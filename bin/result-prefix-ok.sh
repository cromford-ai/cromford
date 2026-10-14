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
RESULT_PREFIX_RE='^(PR_|PLAN_|REVIEW_|BUILD_|QUEUED_|EXECUTE_|DECOMPOSE|ROLLOUT_|RESULT_|SECURITY_|REFUTE_|QA_|TAMPER_|SMOKE|REBASED|CONFLICT|GATE_RED|REBASE_)'
head -1 <<<"${1:-}" | grep -qE "$RESULT_PREFIX_RE"
