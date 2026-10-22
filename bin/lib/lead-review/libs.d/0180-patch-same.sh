#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0180-patch-same.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-4956, optional: the patch-same test for lw_replay. Without it no head is
# replayed, and each is reviewed.
. "$H/bin/lib/patch-same.sh" 2>/dev/null || true
