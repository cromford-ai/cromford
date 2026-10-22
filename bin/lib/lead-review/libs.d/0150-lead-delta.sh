#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0150-lead-delta.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-5294, optional: delta mode. Without it every request is a full review.
. "$H/bin/lib/lead-delta.sh" 2>/dev/null || true
