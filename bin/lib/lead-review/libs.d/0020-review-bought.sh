#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0020-review-bought.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# The per-head guard fp (BH-3930). Optional: without it the calls carry no fp,
# exactly as before, and the tick lock below still holds.
. "$H/bin/lib/review-bought.sh" 2>/dev/null || log "bin/lib/review-bought.sh missing; lead calls carry no per-head fp this tick"
