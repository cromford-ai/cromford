#!/bin/bash
# bin/lib/merge-conductor-lib.sh — the conductor's logic, split into bin/lib/mc/
# by BH-477; KEPT because 14 production scripts and 30 suites source it by name.
# Where the code lives: docs/MERGE-CONDUCTOR.md.
#
# A shim by grammar, not by length (BH-5228, tests/mc/lib-complete-test.sh
# check 1): one statement per line, only assignments and guarded sources. No
# loops, no functions, no logic. The modules load through ONE guarded source of
# mc/load.sh, which calls mm_load (bin/lib/module-map.sh, BH-5240): the order
# is mc/MODULES, generated from each module's "# module:" header, so a new
# module is a new file plus bin/module-map-build.sh --write and no edit here.
#
# SIBLING LIBS. One guarded source line each, never a loop over a list: the
# file names must stay literal on their own line, because
# tests/lib/scratch.sh scratch_closure_list reads them statically to install
# this lib's closure, and a name inside a heredoc list is invisible to it (the
# BH-5228 batch #5829 dequeue: the scratch copy got 3 of 13 siblings).
#   - The bin/lib/ siblings load BEFORE the modules. verdict-parse.sh (BH-1625)
#     is the one reader mc_verdict and mc_rereview take every verdict through;
#     queue-batch-only.sh keeps the corpus to the merge-queue batch (2026-09-24).
#   - The $MC_H siblings load AFTER the modules, so a real helper replaces
#     mc/log.sh's fail-open stub: review-model.sh (BH-998) because mc_rereview
#     reads the model off review_model and never a literal; gh-rest.sh (BH-784)
#     because the modules' decision reads go through gh_rest (no-graphql) and
#     mc/log.sh stubs nothing for them; verdict-status.sh (BH-3348) because
#     mc_enqueue_mergify publishes the lead-verdict status.
# mc/block-ci.sh (BH-3932) is the READY arm's CI-block hook, optional so a
# hand-built mc/ still loads. mc/spawn-remote.sh (BH-6888) is the machine's
# queued rebase, optional too: mc/rebase.sh checks `command -v mc_remote_on`.
# mc/snapshot-refs.sh (BH-4659) loads prs_branch_tip
# AFTER the $MC_H list, so its gh_rest never pre-empts gh-rest.sh; optional too.
# MC_H is restated in mc/log.sh because a stubbed
# module may not set it. tests/gh-app-ratchet-test.sh reads the mc/load.sh
# directory off the literal `MC_LIB_DIR="$(cd …)/mc"`, so keep that shape.
# The last line is `unset`, rc 0: a sourcing caller reads this file's status.
# gh-rest: no-graphql
MC_H="${HARNESS:-/root/harness}"
MC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mc"
command -v issue_close_shipped >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/issue-state-lib.sh" ] && . "${BASH_SOURCE[0]%/*}/issue-state-lib.sh"; }
command -v bg_scan >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/block-gate.sh" ] && . "${BASH_SOURCE[0]%/*}/block-gate.sh"; }
command -v pdg_hold >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/pr-dep-gate.sh" ] && . "${BASH_SOURCE[0]%/*}/pr-dep-gate.sh"; }
command -v main_red_hold >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/main-red-gate.sh" ] && . "${BASH_SOURCE[0]%/*}/main-red-gate.sh"; }
command -v verdict_parse >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/verdict-parse.sh" ] && . "${BASH_SOURCE[0]%/*}/verdict-parse.sh"; }
command -v mc_queue_batch_only >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/queue-batch-only.sh" ] && . "${BASH_SOURCE[0]%/*}/queue-batch-only.sh"; }
. "$MC_LIB_DIR/load.sh" || { echo "merge-conductor-lib: the mc modules did not load from $MC_LIB_DIR" >&2; exit 1; }
[ -r "$MC_LIB_DIR/block-ci.sh" ] && . "$MC_LIB_DIR/block-ci.sh"
[ -r "$MC_LIB_DIR/spawn-remote.sh" ] && . "$MC_LIB_DIR/spawn-remote.sh"
command -v gh_auth_for >/dev/null 2>&1 || { [ -r "$MC_H/bin/lib/gh-app-auth.sh" ] && . "$MC_H/bin/lib/gh-app-auth.sh"; }
[ -r "$MC_H/bin/lib/gh-pr-merge.sh" ] && . "$MC_H/bin/lib/gh-pr-merge.sh"
[ -r "$MC_H/bin/lib/review-model.sh" ] && . "$MC_H/bin/lib/review-model.sh"
command -v gh_rest >/dev/null 2>&1 || { [ -r "$MC_H/bin/lib/gh-rest.sh" ] && . "$MC_H/bin/lib/gh-rest.sh"; }
command -v vs_publish >/dev/null 2>&1 || { [ -r "$MC_H/bin/lib/verdict-status.sh" ] && . "$MC_H/bin/lib/verdict-status.sh"; }
[ -r "$MC_H/bin/lib/flaky.sh" ] && . "$MC_H/bin/lib/flaky.sh"
[ -r "$MC_H/bin/lib/review-provenance.sh" ] && . "$MC_H/bin/lib/review-provenance.sh"
[ -r "$MC_LIB_DIR/snapshot-refs.sh" ] && . "$MC_LIB_DIR/snapshot-refs.sh"
unset _mc_m
