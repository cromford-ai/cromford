#!/bin/bash
# bin/lib/pool-ticket-lock.sh — THE POOL ASKS THE TICKET LOCK BEFORE IT SPENDS A
# MACHINE (BH-10141). Sourced by bin/fly-pool.sh; defines functions only.
#
# A machine booted for a key whose cross-harness ticket lock another harness
# holds runs bin/lib/rb/gates.sh's "ticket lock acquire" block and stops with
# BUILD_DEFERRED. The pool then offered the key again next tick: one slot, one
# spawn and one warm seed per tick (project-3 TK-903, held by operator-mac, 2026-11-25
# 21:27:31Z). pool_spawn_decision now takes the SAME lock (tl_acquire,
# bin/lib/ticket-lock.sh) as its last gate, so the pool and the builder give one
# answer. The builder's gate stays as the second check.
#
# pool_ticket_lock_gate <key> — rc 0 spawn, rc 1 skip.
#   tl_acquire rc 0   spawn, no line. The lease is ours (free, or our own fleet
#                     holder has it: the worker upserts for the same holder).
#                     It is NOT released: the machine acquires it again as the
#                     same holder, and TL_TTL_S ends it if no machine runs.
#   tl_acquire rc 3   skip this tick, one line `SKIP <key> ticket lock held by
#                     <holder>`. The row stays queued; no QROW write, no cap
#                     count.
#   tl_acquire rc 2   spawn, no line, no request: a board no other harness
#                     builds, or no LOCKS_URL / LOCKS_TOKEN.
#   any other rc      spawn with one line. An outage or an unknown answer is
#                     never a skip: a lock-service blip must not stop the pool.
#   an RB-*/RR-*/LR-*/CP-*/FXR-* key, or no tl_acquire to load: spawn.
#
# pool_bundle_token_fp <global.env> — the first 8 hex of the sha256 of the
# value of the LAST CLAUDE_CODE_OAUTH_TOKEN line (the builder sources the file,
# so the last line wins), or `none`. The same hash as the 12-hex fp in
# bin/lib/pool-account.sh, cut shorter. The value lives only in a local and the
# pipe; it is never printed.
#
# The caller is fly-pool.sh: P and say are its names. Root: ${HARNESS:-${H:-}}.
# shellcheck shell=bash

pool_ticket_lock_gate() {
  local key="${1:-}" r st holder rc=0
  [ -n "$key" ] || return 0
  case "$key" in RB-*|RR-*|LR-*|CP-*|FXR-*-*) return 0 ;; esac
  r="${HARNESS:-${H:-}}"
  if ! command -v tl_acquire >/dev/null 2>&1 && [ -n "$r" ] && [ -r "$r/bin/lib/ticket-lock.sh" ]; then
    # shellcheck source=bin/lib/ticket-lock.sh
    . "$r/bin/lib/ticket-lock.sh" 2>/dev/null || true
  fi
  if ! command -v tl_acquire >/dev/null 2>&1; then
    say "ticket lock not checked for $key: bin/lib/ticket-lock.sh not loadable — spawning; the builder's gate decides"
    return 0
  fi
  # Not applicable: no request and no temp file (tl_acquire's own rc 2 rule).
  tl_ns "${P:-}" >/dev/null 2>&1 || return 0
  [ -n "${LOCKS_URL:-}" ] && [ -n "${LOCKS_TOKEN:-}" ] || return 0
  st=$(mktemp "${TMPDIR:-/tmp}/pool-tl.XXXXXX" 2>/dev/null) || {
    say "$key: ticket lock not checked (no temp file) — spawning; the builder's gate decides"; return 0; }
  holder=$(tl_acquire "${P:-}" "$key" "$st") || rc=$?
  rm -f "$st" "$st.tmp"
  case "$rc" in
    0|2) return 0 ;;
    3)
      # The holder name comes from the lock service: one printable line, short.
      holder=$(head -n 1 <<<"$holder" | tr -cd '[:alnum:]._@:/ -' | cut -c1-80)
      say "SKIP $key ticket lock held by ${holder:-another harness}"
      return 1 ;;
    *)
      say "$key: ticket lock read failed (rc $rc) — spawning; the builder's gate decides"
      return 0 ;;
  esac
}

pool_bundle_token_fp() {
  local line
  line=$(grep '^CLAUDE_CODE_OAUTH_TOKEN=' "${1:-/dev/null}" 2>/dev/null | tail -n 1)
  if [ -z "$line" ]; then printf 'none\n'; return 0; fi
  printf '%s' "${line#CLAUDE_CODE_OAUTH_TOKEN=}" | sha256sum | cut -c1-8
}
