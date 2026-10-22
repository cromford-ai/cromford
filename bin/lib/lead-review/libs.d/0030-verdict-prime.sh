#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-review/libs.d/0030-verdict-prime.sh — one optional lib of bin/lead-review.sh (docs/notes/2026-10-19-BH-7455-lead-review-libs.md). Sourced at top level, never run.
command -v verdict_prime >/dev/null 2>&1 && verdict_prime || true
