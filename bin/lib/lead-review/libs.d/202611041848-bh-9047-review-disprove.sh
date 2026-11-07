#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/202611041848-bh-9047-review-disprove.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-9047: the disprove pass (dp_review) on a model BLOCK, after the review level cap. Off without it.
. "$H/bin/lib/review-disprove.sh" 2>/dev/null || log "bin/lib/review-disprove.sh missing; no disprove pass this tick"
