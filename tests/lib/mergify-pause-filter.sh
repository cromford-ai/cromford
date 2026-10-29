# shellcheck shell=bash
# tests/lib/mergify-pause-filter.sh — the BH-8706 transition filter for the
# "renders byte-identical to main" checks of the Mergify suites. Sourced.
#
# BH-8706 adds the main-red breaker's pause exclusion (`-label=merge-queue-paused`
# and its one comment line) to every non-hotfix queue rule and pull_request_rule
# of every render. tests/mergify-template-paused.bh-8706-test.sh owns those
# lines. A suite that compares a render with the render of main's renderer sees
# them as a diff only while main does not have them yet.
#
# SCOPED TO THE BASE. mergify_pause_filter does nothing when the base render
# already carries the label: once BH-8706 is on main, every byte check is full
# again, and a later diff that drops the exclusion from one rule fails there.
#
# mergify_pause_filter <base-render> <head-render> — rewrites both files in place.
# Always rc 0.
mergify_pause_filter() {
  grep -q 'merge-queue-paused' "$1" 2>/dev/null && return 0
  local re='^[[:space:]]*(- -label ?= ?merge-queue-paused|# .*main-red breaker.*\(BH-8706\)\.)$' f
  for f in "$1" "$2"; do
    grep -vE "$re" "$f" > "$f.mpf" 2>/dev/null; mv "$f.mpf" "$f"
  done
  return 0
}
