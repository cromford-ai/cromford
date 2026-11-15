#!/bin/bash
# bin/lib/meter-skip.sh — the subscription meters skip a project that pays for
# Claude with its own API key (BH-9719, C2 of BH-9676, from BH-9334 Fix 2).
# Sourced, never executed. Defines functions only.
#
#   . bin/lib/meter-skip.sh
#   meter_skip_api_key <project>             rc 0 = skip the meter for it
#   meter_skip_log_once <script> <key> <logfile> <line>
#                                            one log line per (script, key,
#                                            UTC day); rc 0, rc 1 on a bad
#                                            name or no harness root
#
# Readers: bin/account-capacity.sh (with a project argument, from
# bin/concurrency-apply.sh) and bin/extra-usage-track.sh (a fallback-login box
# whose projects are all api-key). An api-key project is billed per token: it
# has no subscription session meter to count or poll, and its brake is a spend
# cap (bin/lib/budget-stop.sh, budget.project.<p>.day_usd / cost_ceiling.<p>).
#
# meter_skip_api_key is rc 0 ONLY when claude_auth_mode prints `api-key` with
# rc 0. Everything else meters as before: no row (oauth), an `oauth` row, a
# junk row (rc 1), a bad project name (rc 1), no settings cache (oauth).
#
# meter_skip_log_once keeps the last UTC day in
# ${HARNESS:-${H:-}}/state/meter-skip/<script>-<key>.day (one file per script and key,
# overwritten, so the directory holds at most one file per project or box and
# needs no retention job). METER_SKIP_DAY pins the day in tests.
#
# This lib never calls a model or a vendor. The settings read goes through
# lane-gate's cache, which can refresh it from the jobs worker.

_MSK_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)

meter_skip_api_key() {
  local p="${1:-}" m
  [ -n "$p" ] || return 1
  if ! command -v claude_auth_mode >/dev/null 2>&1; then
    # shellcheck source=bin/lib/claude-auth.sh
    [ -r "$_MSK_LIB/claude-auth.sh" ] && { . "$_MSK_LIB/claude-auth.sh" >/dev/null 2>&1 || true; }
    command -v claude_auth_mode >/dev/null 2>&1 || return 1
  fi
  m=$(claude_auth_mode "$p" 2>/dev/null) || return 1
  [ "$m" = api-key ]
}

meter_skip_log_once() {
  local s="${1:-}" k="${2:-}" log="${3:-}" line="${4:-}" root day f
  case "$s" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$k" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -n "$log" ] || return 1
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  day="${METER_SKIP_DAY:-$(date -u +%Y%m%d)}"
  f="$root/state/meter-skip/$s-$k.day"
  [ "$(cat "$f" 2>/dev/null)" = "$day" ] && return 0
  mkdir -p "$root/state/meter-skip" "$(dirname "$log")" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$line" >> "$log" 2>/dev/null
  printf '%s\n' "$day" > "$f" 2>/dev/null
  return 0
}
