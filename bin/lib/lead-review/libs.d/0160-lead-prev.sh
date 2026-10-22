#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0160-lead-prev.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-6391, optional: the re-review section and the NOTE pass. Without it a
# re-review reads and answers as a first review.
. "$H/bin/lib/lead-prev.sh" 2>/dev/null || true
