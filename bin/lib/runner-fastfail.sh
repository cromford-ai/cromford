#!/bin/bash
# bin/lib/runner-fastfail.sh — the FAST-FAIL COOLDOWN (BH-3224). Sourced by
# bin/agent-call.sh; functions only, nothing runs on source.
#
# WHY. runner_ready only asks whether a runner is installed. A runner that is
# installed but fails at once on every call (grok on the hub, 2026-09-26..28:
# about 220 triage calls at rc 1 in 1-3 s with no usage) was bought again on
# every call, as the primary and as the tier-2 rung of every stage: each dead
# attempt added latency and an unpriced $0 cost row, and only then did the
# ladder descend.
#
# WHAT. A listed runner that fails FAST (elapsed <= RUNNER_FASTFAIL_S) with NO
# usage (both token counts empty or 0) is marked for RUNNER_FASTFAIL_COOLDOWN_S
# in $HARNESS/state/runner-fastfail/<runner>, and runner_ready answers no for it
# while the mark is live. It is a half-open breaker: once the window ends the
# next real call is the reprobe. Success removes the mark; another instant
# failure writes a new window and keeps the first `since`. A slow failure, one
# with usage, or rc 74..79 (nothing was called) neither marks nor clears.
#
# PER BOX, on purpose: grok's credential is per box (~/.grok), so one box's dead
# CLI says nothing about another's. Losing the file costs one more instant
# failure, which re-arms it. Written tmp+mv, so concurrent calls race to a
# valid last-writer-wins record.
#
# KNOBS (catalog/lanes.d/_lib.runner-fastfail.json, settings keys
# lib.runner-fastfail.<env lowercased>, applied by agent-call's
# lib_env_apply runner-fastfail):
#   RUNNER_FASTFAIL_RUNNERS     comma or space list, default grok
#   RUNNER_FASTFAIL_S           an instant failure is at most this many s, default 5
#   RUNNER_FASTFAIL_COOLDOWN_S  the window, default 1800; 0 = off
# A value that is not a number falls back to its default, never to 0.

_rff_int() { # _rff_int <value> <default> — the value when it is a whole number
  case "${1:-}" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac
}
_rff_cooldown() { _rff_int "${RUNNER_FASTFAIL_COOLDOWN_S:-}" 1800; }
_rff_fast_s()   { local s; s=$(_rff_int "${RUNNER_FASTFAIL_S:-}" 5); [ "$s" -gt 0 ] || s=5; echo "$s"; }
_rff_name_ok()  { grep -Eq '^[a-z0-9_-]+$' <<<"${1:-}"; }
_rff_file()     { printf '%s/state/runner-fastfail/%s' "$1" "$2"; }
_rff_field() { # _rff_field <file> <name> — one key=value field of the marker
  [ -r "$1" ] || return 0
  tr ' ' '\n' < "$1" | sed -n "s/^$2=//p" | head -1
}

# rff_enabled <runner> — rc 0 when the cooldown is on and lists this runner.
rff_enabled() {
  local r="${1:-}" c
  _rff_name_ok "$r" || return 1
  c=$(_rff_cooldown); [ "$c" -gt 0 ] || return 1
  printf '%s\n' "${RUNNER_FASTFAIL_RUNNERS-grok}" | tr ', ' '\n\n' | grep -qxF -- "$r"
}

# rff_note <harness> <runner> <rc> <elapsed_s> <in_toks> <out_toks> — record one
# attempt's outcome. Always rc 0: a failed write must never fail a call.
rff_note() {
  local h="${1:-}" r="${2:-}" rc="${3:-}" el="${4:-}" in="${5:-}" out="${6:-}" f now since tmp
  [ -n "$h" ] && rff_enabled "$r" || return 0
  f=$(_rff_file "$h" "$r")
  case "$rc" in
    0) rm -f "$f" 2>/dev/null; return 0 ;;
    74|75|76|77|78|79|''|*[!0-9]*) return 0 ;;
  esac
  case "$el" in ''|*[!0-9]*) return 0 ;; esac
  [ "$el" -le "$(_rff_fast_s)" ] || return 0
  # Usage means the vendor answered: not "instant" evidence.
  case "${in:-0}"  in 0) : ;; *) return 0 ;; esac
  case "${out:-0}" in 0) : ;; *) return 0 ;; esac
  now=$(date +%s)
  since=$(_rff_field "$f" since); case "$since" in ''|*[!0-9]*) since=$now ;; esac
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || return 0
  printf 'until=%s since=%s rc=%s elapsed=%s\n' "$((now + $(_rff_cooldown)))" "$since" "$rc" "$el" > "$tmp" \
    && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# rff_live <harness> <runner> — rc 0 while the runner's mark is in its window.
# An expired or unparseable mark is not live, and is left for the next note.
rff_live() {
  local f u
  _rff_name_ok "${2:-}" && [ -n "${1:-}" ] || return 1
  f=$(_rff_file "$1" "$2")
  [ -f "$f" ] || return 1
  u=$(_rff_field "$f" until)
  case "$u" in ''|*[!0-9]*) return 1 ;; esac
  [ "$u" -gt "$(date +%s)" ]
}

# rff_until <harness> <runner> — the mark's end as HH:MMZ, for a log line.
rff_until() {
  local u
  _rff_name_ok "${2:-}" || return 0
  u=$(_rff_field "$(_rff_file "$1" "$2")" until)
  case "$u" in ''|*[!0-9]*) return 0 ;; esac
  date -u -d "@$u" +%H:%MZ 2>/dev/null
}

# rff_detail <harness> <runner> — "rc=<rc>, <n>s" off the mark, for a log line.
rff_detail() {
  local f
  _rff_name_ok "${2:-}" || return 0
  f=$(_rff_file "$1" "$2")
  printf 'rc=%s, %ss' "$(_rff_field "$f" rc)" "$(_rff_field "$f" elapsed)"
}
