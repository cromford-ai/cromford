#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0040-lead-chain-wake.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# The lead-land doorbell (BH-5317), fail-open: without it the */15 land cron
# promotes every result, as before.
. "$H/bin/lib/lead-chain-wake.sh" 2>/dev/null || log "bin/lib/lead-chain-wake.sh missing; no lead-land doorbell this tick"
