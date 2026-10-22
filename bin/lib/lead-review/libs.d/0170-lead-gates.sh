#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0170-lead-gates.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-5873: the worklist's gate loader (header, THE GATES). Without it no
# worklist item starts; request rows still run.
LG_OK=0; . "$H/bin/lib/lead-gates.sh" 2>/dev/null && LG_OK=1
