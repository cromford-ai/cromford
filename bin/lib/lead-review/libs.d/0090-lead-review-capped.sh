#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0090-lead-review-capped.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-6041, optional: one warn when /tmp or memory holds concurrency below the
# configured value. Without it the cap is a log line only, as before.
# shellcheck source=bin/lib/lead-review-capped.sh
. "$H/bin/lib/lead-review-capped.sh" 2>/dev/null || log "bin/lib/lead-review-capped.sh missing; no capped-concurrency alert this tick"
