#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/202610221925-bh-8027-lead-pool.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-8027, optional: lane_placement.lead-review.<project> = fly puts that
# project's reviews on the Fly pool (bin/lib/lead-pool.sh). Missing = every
# review runs on this box, as before.
. "$H/bin/lib/lane-placement.sh" 2>/dev/null || log "bin/lib/lane-placement.sh missing; every lead review runs on this box"
. "$H/bin/lib/lead-pool.sh" 2>/dev/null || log "bin/lib/lead-pool.sh missing; every lead review runs on this box"
