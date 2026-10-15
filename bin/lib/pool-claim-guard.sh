#!/bin/bash
# shellcheck shell=bash
# bin/lib/pool-claim-guard.sh — may fly-dispatch claim this queued key?
# Sourced by bin/fly-dispatch.sh, never run: no `set`, no `exit`, nothing runs
# at source time.
#
# A push-rejected terminal (state/pool/<p>/<KEY>.terminal, written by the pool
# reap) means the last build could not push and the branch has not moved since.
# fly-pool's terminal gate owns its re-arm (a moved head or a RETRY comment).
# A claim taken around that gate is a row `claimed` with nothing building it:
# BH-5566 sat so for 3.5 h.
#
#   pool_claim_guard <project> <key>
#     rc 0  clear: no terminal file, or no harness root to read one from
#     rc 3  refused: one reason line on stdout
#
# The root is ${HARNESS:-${H:-}} only. With none there is nothing to read, and
# the claim goes on exactly as it did before this guard existed.

pool_claim_guard() {
  local p="${1:-}" k="${2:-}" root="${HARNESS:-${H:-}}"
  [ -n "$root" ] && [ -n "$p" ] && [ -n "$k" ] || return 0
  # READ ONLY. The terminal file is fly-pool's (it has no jobs-client row
  # yet), and this guard only reads it. No variable holds the path and no
  # assignment names it: bin/state-paths-guard.sh counts both as a new writer
  # of state/pool, a `rows` path (BH-5005).
  [ -f "$root/state/pool/$p/$k.terminal" ] || return 0
  jq -er --arg p "$p" --arg k "$k" \
     'def v(f): (f // "" | tostring | if . == "" then "?" else . end);
      "push-rejected terminal (state/pool/\($p)/\($k).terminal, head \(v(.head_sha)), since \(v(.created_at)))"' \
     "$root/state/pool/$p/$k.terminal" 2>/dev/null \
    || printf 'push-rejected terminal (state/pool/%s/%s.terminal, head ?, since ?)\n' "$p" "$k"
  return 3
}
