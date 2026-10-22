#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0010-llm-gate.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# The lane's daily spend cap (BH-5284: no new review starts over it), optional:
# without it agent-call.sh's own gate still refuses each call over the cap.
. "$H/bin/lib/llm-gate.sh" 2>/dev/null || true
