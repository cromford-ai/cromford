#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0080-pr-snapshot.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-5151, optional: the open-PR list (hotfix order + the dead-row sweep) and the
# hotfix label's name. Without them the tick still runs, ordered by priority.
. "$H/bin/lib/pr-snapshot.sh" 2>/dev/null || log "bin/lib/pr-snapshot.sh missing; no hotfix order and no dead-row sweep this tick"
. "$H/bin/lib/hotfix-lib.sh" 2>/dev/null || log "bin/lib/hotfix-lib.sh missing; no hotfix order this tick"
