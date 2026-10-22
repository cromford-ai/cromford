#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0100-live-probes.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-5801: lp_evidence, the review's `## Live probes` section (the harness App's
# own comment for the head, never the PR body). Missing, the section says so.
# shellcheck source=bin/lib/live-probes.sh
. "$H/bin/lib/live-probes.sh" 2>/dev/null || log "bin/lib/live-probes.sh missing; reviews carry no live-probe evidence this tick"
