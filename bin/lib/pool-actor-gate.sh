#!/bin/bash
# bin/lib/pool-actor-gate.sh — THE POOL ASKS WHO ADDED THE LABEL BEFORE IT
# SPENDS A MACHINE (BH-6957). Sourced by bin/fly-pool.sh; defines functions only.
#
# A Fly machine booted for a ticket whose newest `ai-build` label came from an
# actor the trigger-actor gate ignores runs bin/lib/rb/gates.sh's ta_gate and
# stops with BUILD_REFUSED SKIP_ACTOR. BH-6853 spent 8 machines that way in one
# day. pool_spawn_decision now runs the SAME ta_gate (bin/lib/trigger-actor.sh)
# first, so the pool and the builder give one answer, re-arm included.
#
# pool_actor_gate <job-file> <key> <ticket> — rc 0 spawn, rc 1 skip.
#   ta_gate rc 0      spawn.
#   ta_gate rc 1      ignored: the queue row closes `failed` with SKIP_ACTOR in
#                     the reason, the queue file and the hold marker go, one
#                     line in fly-pool.log and in logs/<p>.log. No ALERTS line:
#                     ta_gate already commented once on the ticket.
#   ta_gate rc 2      unverifiable: spawn (fail-open) with one line. The
#                     builder's own gate still defers, which is the old cost;
#                     a pool that refused every unreadable read could stop all
#                     builds of a project.
#   an RB-*/RR-*/LR-*/CP-*/  spawn, as before this gate.
#   FXR-* key, or no
#   ta_gate to load
# The caller is fly-pool.sh: P, POOL_SLUG, POOL_SLUG_TOK, say, QROW and
# pool_hold_clear are its names. Root: ${HARNESS:-${H:-}} only (BH-2613).
# shellcheck shell=bash

pool_actor_gate() {
  local jf="${1:-}" key="${2:-}" ticket="${3:-}" r dir rc=0 line
  case "$key" in RB-*|RR-*|LR-*|CP-*|FXR-*-*) return 0 ;; esac
  r="${HARNESS:-${H:-}}"
  if ! command -v ta_gate >/dev/null 2>&1 && [ -n "$r" ] && [ -r "$r/bin/lib/trigger-actor.sh" ]; then
    # shellcheck source=bin/lib/trigger-actor.sh
    . "$r/bin/lib/trigger-actor.sh" 2>/dev/null || true
  fi
  if ! command -v ta_gate >/dev/null 2>&1; then
    say "actor check for $key not loadable (bin/lib/trigger-actor.sh) — spawning; the builder's gate decides"
    return 0
  fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/pool-actor.XXXXXX") || {
    say "actor check for $key: no temp dir — spawning; the builder's gate decides"; return 0; }
  # The repo and the token the pool's other gates read this project with. No
  # slug token: the ambient identity, as those gates do (never an empty GH_TOKEN).
  if [ -n "${POOL_SLUG_TOK:-}" ]; then
    GH_ISSUES_REPO="${POOL_SLUG:-${GH_ISSUES_REPO:-}}" GH_TOKEN="$POOL_SLUG_TOK" ta_gate "$P" "$key" "$ticket" "$dir" || rc=$?
  else
    GH_ISSUES_REPO="${POOL_SLUG:-${GH_ISSUES_REPO:-}}" ta_gate "$P" "$key" "$ticket" "$dir" || rc=$?
  fi
  rm -rf "$dir"
  case "$rc" in
    0) return 0 ;;
    1)
      line="SKIP_ACTOR $key — $PROJECT_2_LINE"
      say "skipping $key: SKIP_ACTOR — $PROJECT_2_LINE (no machine spawned)"
      QROW failed "$key" "$line — pool pre-spawn check, no machine spawned; re-arm: a listed actor re-labels ai-build, or a person comments RETRY"
      rm -f "$jf"
      pool_hold_clear "$key" || true
      [ -n "$r" ] && { mkdir -p "$r/logs" 2>/dev/null; echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$P/$key] $line (pool pre-spawn check, no machine spawned)" >> "$r/logs/$P.log" 2>/dev/null; }
      return 1 ;;
  esac
  say "actor check unverifiable for $key ($PROJECT_2_LINE) — spawning; the builder's gate decides"
  return 0
}
