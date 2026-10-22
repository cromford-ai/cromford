#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0190-hotspot-context.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-5271, optional: the project's conflict hotspots for checklist item 9.
# Without it the prompt says the list could not be read, and the review runs.
. "$H/bin/lib/hotspot-context.sh" 2>/dev/null || log "bin/lib/hotspot-context.sh missing; the review prompt carries no hotspot list this tick"
