#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0050-verdicts.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# The standing-verdict reader (BH-5022), fail-open: without it no request is
# superseded by a risk-tier sign-off and every one is reviewed as before.
. "$H/bin/lib/verdicts.sh" 2>/dev/null || true
