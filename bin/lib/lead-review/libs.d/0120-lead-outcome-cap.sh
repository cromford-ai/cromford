#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0120-lead-outcome-cap.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-6372.3, optional: the outcome cap (an INCONCLUSIVE claim row on a perf/cost
# PR caps the verdict at BLOCK). Without it every verdict stands as the agent gave it.
# shellcheck source=bin/lib/lead-outcome-cap.sh
. "$H/bin/lib/lead-outcome-cap.sh" 2>/dev/null || log "bin/lib/lead-outcome-cap.sh missing; no outcome cap this tick"
