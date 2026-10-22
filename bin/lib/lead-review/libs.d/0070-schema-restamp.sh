#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0070-schema-restamp.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-6842: a rules-pack line whose only fault is the schema stamp order is a
# NOTE (the merge conductor restamps before it queues). Missing = a finding.
# shellcheck source=bin/lib/schema-restamp.sh
. "$H/bin/lib/schema-restamp.sh" 2>/dev/null || log "bin/lib/schema-restamp.sh missing; a schema stamp-order line counts as a finding this tick"
