#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0130-ci-local-verify.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
# BH-6897, optional: CI's lint job steps on the reviewed head (bin/ci-local.sh).
# shellcheck source=bin/lib/ci-local-verify.sh
. "$H/bin/lib/ci-local-verify.sh" 2>/dev/null || log "bin/lib/ci-local-verify.sh missing; no ci-local run this tick"
