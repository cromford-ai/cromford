#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/202611131555-bh-7695-suite-preflight.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-7695, optional: the host-suite preflight (sp_lead_suite). A box that cannot
# run the repo suite records `host suite: could-not-run: <item>` and the review
# goes on. Missing lib = today's host suite.
. "$H/bin/lib/suite-preflight.sh" 2>/dev/null || log "bin/lib/suite-preflight.sh missing; no host-suite preflight this tick"
