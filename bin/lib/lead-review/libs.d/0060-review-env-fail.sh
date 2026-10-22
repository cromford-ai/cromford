#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0060-review-env-fail.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-5793: which rules-pack finding lines are environment failures. Missing =
# every line is a finding, as before.
# shellcheck source=bin/lib/review-env-fail.sh
. "$H/bin/lib/review-env-fail.sh" 2>/dev/null || log "bin/lib/review-env-fail.sh missing; every rules-pack line counts as a finding this tick"
