#!/bin/bash
# shellcheck shell=bash
# bin/lib/mc/check-run-state.sh — BH-7121: the effective status of one GitHub
# check run. Sourced, never run. No network, no state.
#
# On PR #7099 GitHub reported the check run "Prompt replay evals (prompts/**
# only)" as status in_progress with conclusion success and completed_at set,
# while its workflow run was completed. The queue path built its word from
# .status alone, took only completed/success, and the PR waited 20+ minutes.
#
# THE RULE: a run with a non-empty completed_at and a conclusion in {success,
# neutral, skipped} has the effective status "completed", whatever .status
# says. Every other run keeps its raw .status. The rule promotes the status
# only; it never changes the conclusion. So each reader keeps its own set of
# green conclusions: a reader that accepts only success does not start to
# accept neutral (autoenqueue G4, landing step 8), and mc_mergify_batch_green,
# where neutral and skipped already count, reads those as green too.
#
# Readers: bin/lib/autoenqueue.sh (_ae_gates G4), bin/lib/mc/landing.sh
# (landing_eligible step 8), bin/lib/mc/queue.sh (mc_mergify_batch_green).
# It lives in mc/ (like mc/snapshot-refs.sh, not a "# module:" file) so a tree
# that copies the conductor modules carries it. autoenqueue.sh sources it at
# load; landing.sh and queue.sh source it at call time, so no mc module
# defines a new function at load.
[ -n "${CHECK_RUN_STATE_LIB:-}" ] && return 0
CHECK_RUN_STATE_LIB=1

# CRS_JQ_DEFS — prefix a jq program with it to get `crs_status` on a check run.
CRS_JQ_DEFS='def crs_status: if ((.completed_at // "") != "") and ((.conclusion // "") | IN("success","neutral","skipped")) then "completed" else (.status // "") end;'

# crs_word <check-runs json file> <name> — prints "absent", or
#   "<crs_status>/<conclusion|none>" for the latest run of that name by
#   started_at. jq's rc passes through; a caller reads empty output as not green.
crs_word() {
  jq -r --arg c "$2" "$CRS_JQ_DEFS"' [.check_runs[]? | select(.name == $c)] | sort_by(.started_at // "") | last
    | if . == null then "absent" else (crs_status + "/" + (.conclusion // "none")) end' "$1"
}
