#!/bin/bash
# shellcheck shell=bash
# bin/lib/console-alert-resolve.sh — close the open console row(s) with ONE exact akey (BH-9114).
#
# WHY: a warn digest (bin/alert-digest.sh --warn-batch) is a delivery record,
# not an alert: every warn in it is a console row of its own. Its row stayed
# open for 48h and counted each warn twice. The digest closes its own row right
# after the console took the beat. The console worker lives in another repo, so
# "resolved at insert" is this: one read, one resolve.
#
# console_alert_resolve_akey <akey> <reason>
#   One GET /api/alerts/open (newest first, so a row just inserted is in it),
#   the ids whose .akey EQUALS <akey> (never a prefix, never the line text),
#   then one POST /api/alerts/resolve {ids, reason}.
#   stdout: one word for the caller's log: resolved | not-found | not-configured | failed
#   rc 0 resolved (n >= 1), 1 no open row with that akey, 2 no console configured,
#   3 the read or the POST failed. No ALERTS line: a missed close is not a page,
#   and the alerts-groom backstop (bin/alerts-supersede.py) closes the row.
#
# ALERT_DIGEST_RESOLVE_TIMEOUT_S (row lane.alert-warn-flush.alert_digest_resolve_timeout_s,
# fallback 20, 1..120) is the curl --max-time of the GET and of the POST.
#
# CONSOLE_URL and HARNESS_SECRET are read from env/global.env in a SUBSHELL: the
# secret never enters the caller's environment. Root: ${HARNESS:-${H:-}} only (D43).
[ -n "${_CONSOLE_ALERT_RESOLVE_LIB:-}" ] && return 0
_CONSOLE_ALERT_RESOLVE_LIB=1
_CAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

console_alert_resolve_akey() {
  local akey="${1:-}" reason="${2:-}" root tmo
  # Row lane.alert-warn-flush.alert_digest_resolve_timeout_s; 20 is its documented fallback.
  tmo="${ALERT_DIGEST_RESOLVE_TIMEOUT_S:-20}"
  [[ "$tmo" =~ ^[0-9]+$ ]] && [ "$((10#$tmo))" -ge 1 ] && [ "$((10#$tmo))" -le 120 ] && tmo=$((10#$tmo)) || tmo=20
  root="${HARNESS:-${H:-}}"
  [ -n "$akey" ] && [ -n "$reason" ] && [ -n "$root" ] || { printf 'not-configured\n'; return 2; }
  ( # shellcheck source=bin/lib/env-path.sh
    command -v harness_env_dir >/dev/null 2>&1 || . "$_CAR_DIR/env-path.sh" 2>/dev/null || exit 2
    unset CONSOLE_URL HARNESS_SECRET
    set -a; . "$(harness_env_dir "$root")/global.env" 2>/dev/null; set +a
    [ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || { printf 'not-configured\n'; exit 2; }
    command -v jq >/dev/null 2>&1 || { printf 'failed\n'; exit 3; }
    open=$(curl -s --max-time "$tmo" -H "Authorization: Bearer $HARNESS_SECRET" "$CONSOLE_URL/api/alerts/open" 2>/dev/null) \
      || { printf 'failed\n'; exit 3; }
    ids=$(jq -c --arg k "$akey" '[.alerts[]? | select((.akey // "") == $k) | .id]' <<<"$open" 2>/dev/null) \
      || { printf 'failed\n'; exit 3; }
    [ "$(jq 'length' <<<"$ids")" -gt 0 ] || { printf 'not-found\n'; exit 1; }
    code=$(curl -s --max-time "$tmo" -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer $HARNESS_SECRET" -H 'Content-Type: application/json' \
      -d "$(jq -nc --argjson ids "$ids" --arg r "$reason" '{ids:$ids, reason:$r}')" \
      "$CONSOLE_URL/api/alerts/resolve" 2>/dev/null) || code=000
    case "$code" in 2??) printf 'resolved\n'; exit 0 ;; *) printf 'failed\n'; exit 3 ;; esac
  )
}
