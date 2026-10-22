#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0140-review-level.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-7123: the review level cap. A [BLOCK] that names no ALWAYS-BLOCK class
# (catalog/review-always-block.tsv) is a NOTE; a report with no BLOCK left is
# MERGE-WITH-NOTES. Missing lib = the model's verdict stands, as before.
. "$H/bin/lib/review-level.sh" 2>/dev/null || log "bin/lib/review-level.sh missing; no review level cap this tick"
