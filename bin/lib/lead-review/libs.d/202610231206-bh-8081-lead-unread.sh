#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/202610231206-bh-8081-lead-unread.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-8081, optional: a round with no readable verdict gets one more paid call
# on ~unread, and a head guard-blocked with no verdict alerts once
# (bin/lib/lead-unread.sh). Missing = the BH-7792 release as before, no alert.
. "$H/bin/lib/lead-unread.sh" 2>/dev/null || log "bin/lib/lead-unread.sh missing; no extra paid call on an unreadable lead verdict"
