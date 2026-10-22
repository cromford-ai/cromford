#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0110-builder-review.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-5355, optional: the builder review of the head (br_fetch). Without it
# every review is a full review.
# shellcheck source=bin/lib/builder-review.sh
. "$H/bin/lib/builder-review.sh" 2>/dev/null || log "bin/lib/builder-review.sh missing; every lead review is a full review this tick"
