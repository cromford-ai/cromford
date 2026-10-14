#!/bin/bash
# shellcheck shell=bash
# module: terminal
# bin/lib/ms/terminal.sh — the sweep's terminal-skip cache helpers: the record
# fingerprint, the cache writer and the re-logged cause lines. Sourced by
# bin/merge-sweep.sh through bin/lib/ms/load.sh, never run. Sourcing it defines
# three functions and does nothing else. The cache STATE (TERM_CACHE, NOW, the
# _TERM map and its load loop) stays in the driver: mm_load sources at function
# scope, so a top-level `declare -A` here would be lost.
# ---------------------------------------------------------------------------
# The evidence every terminal cause is decided from, in one stat: name, mtime
# and size of each file. An absent file simply drops out, so a relay
# (bin/fly-results-ingest.sh, bin/fly-pool.sh) that adds, removes or rewrites
# any of them changes the key and the record is re-evaluated — which is the
# behaviour we want. Empty output = no fingerprint = no caching at all.
sweep_record_fp() { ( cd "$1" 2>/dev/null && stat -c '%n:%Y:%s' RESULT review.md pipeline.log e2e.md reviewed-sha 2>/dev/null | tr '\n' ',' ); }
sweep_terminal() { # sweep_terminal <cause> — this record's refusal is decided by the record itself
  local cause="${1// /_}"
  _ITER_CLASS=terminal-new
  [ -n "${FP:-}" ] || return 0
  _TERM["$PR|$FP"]="$NOW $cause"
  printf '%s %s %s %s\n' "$NOW" "$cause" "$PR" "$FP" >> "$TERM_CACHE"
}
# The two causes that say something in the log today. Re-emitted verbatim on the
# daily refresh so bin/pipeline-health.sh:344 keeps finding a reason line for a
# starved PR instead of reporting "the silent-skip shape". The other three
# causes are silent today and stay silent — a first-time line for each would
# print thousands of lines on the first tick after deploy, the opposite of what
# BH-710 asks for; the per-project counters carry their visibility.
sweep_relog_line() { # sweep_relog_line <cause>
  case "$1" in
    e2e-fail)            printf '%s skipped: E2E smoke FAILED on the build'"'"'s preview deployment (see %s/e2e.md)\n' "$PR" "$D" ;;
    ledger-provenance-*) printf '%s skipped: ledger provenance is %s, not the primary review lane\n' "$PR" "${1#ledger-provenance-}" ;;
  esac
}
