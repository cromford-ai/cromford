#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/202610230549-bh-7941-e2e-main-baseline.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-7941: emb_prompt_file, the review's `## Main E2E` section (main's latest
# full E2E run against this head's, checklist item 17). Missing, the section says so.
# shellcheck source=bin/lib/e2e-main-baseline.sh
. "$H/bin/lib/e2e-main-baseline.sh" 2>/dev/null || log "bin/lib/e2e-main-baseline.sh missing; the review prompt carries no main E2E baseline this tick"
