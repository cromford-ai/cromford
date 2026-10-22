#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0200-lead-diff-parts.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# Optional: a full-review diff over DIFF_MAX is read in parts (plan files, tests,
# rest), or answered "split required". Without it an oversize diff is answered
# "split required" with no model call: no reviewer reads a cut diff.
. "$H/bin/lib/lead-diff-parts.sh" 2>/dev/null || log "bin/lib/lead-diff-parts.sh missing; an oversize diff is answered split required this tick"
