#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0210-break-it.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-6970: the break-it verifier (bi_review), after the model verdict. Off without it.
. "$H/bin/lib/break-it.sh" 2>/dev/null || log "bin/lib/break-it.sh missing; no break-it run this tick"
