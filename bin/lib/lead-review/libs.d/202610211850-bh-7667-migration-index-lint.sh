#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/202610211850-bh-7667-migration-index-lint.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-7667, optional: the migration index lint (a plain CREATE INDEX on a table
# in review.large_tables.<project> is a BLOCK with no model call).
. "$H/bin/lib/migration-index-lint.sh" 2>/dev/null || log "bin/lib/migration-index-lint.sh missing; no migration lint this tick"
