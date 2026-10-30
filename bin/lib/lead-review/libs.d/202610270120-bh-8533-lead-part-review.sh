#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/202610270120-bh-8533-lead-part-review.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-8533, optional: a full review over DIFF_MAX that leaves a file unread is
# read in N parts on the same head, one paid call each, one aggregate verdict
# (bin/lib/lead-part-review.sh). Missing = the split-required BLOCK as before.
. "$H/bin/lib/lead-part-review.sh" 2>/dev/null || log "bin/lib/lead-part-review.sh missing; an over-limit head with a file unread stays split required"
