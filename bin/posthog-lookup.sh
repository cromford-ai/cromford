#!/bin/bash
# bin/posthog-lookup.sh <project> "<hogql>"
# bin/posthog-lookup.sh <project> --report api-failures|web-vitals
#
# BH-9799: deterministic PostHog read for the alert-triage and medic lanes, the
# sibling of bin/sentry-lookup.sh. It runs ONE HogQL query with the project's
# PostHog key and prints the rows as tab-separated text.
#
# Source: the `posthog` block of catalog/signal-sources.d/<project>.json
# (bin/lib/signal-source.sh): host, project id, the env NAME of the key, and an
# optional filter added to the canned reports. The key comes from the
# environment, else it is parsed from env/<project>.env.
#
# Same contract as sentry-lookup.sh: a missing source, a missing key, a refused
# query and any API failure print ONE line and exit 0. Bad usage exits 2.
#   (posthog lookup unavailable — no PostHog source for <project>)
#   (posthog lookup unavailable — bad signal source row for <project>)
#   (posthog lookup unavailable — <KEY_ENV> unset for <project>)
#   (posthog lookup refused: the query reads person fields)
#   (posthog lookup failed: timeout) | (posthog lookup failed: curl error <rc>)
#   (posthog lookup failed: HTTP <code>)   (the vendor body is not printed)
#   (posthog lookup: unparseable response)
#
# PRIVACY. A query that names person, persons, email, name or $ip (any case,
# as a whole word) is refused before any call. Every output line has its
# email-shaped strings replaced with <redacted:email>, then goes through
# token_redact. The output holds counts, routes and ids.
#
# The key rides in a curl config on a file descriptor (watchdog_curl,
# bin/lib/watchdog-url.sh), never in an argv or a URL.
#
# Output: one header line of the column names, then at most
# POSTHOG_LOOKUP_MAX_ROWS rows, each cell as text (tabs and line breaks made
# spaces). No rows: `(posthog: no rows)`. More rows than the cap: a last line
# `(posthog: <n> more rows not shown)`.
#
# Reports (the filter is added as `AND <filter>` when the row has one):
#   api-failures  event POSTHOG_REPORT_API_FAILURE_EVENT, last
#                 POSTHOG_REPORT_API_FAILURES_H hours, count by endpoint and status
#   web-vitals    event $web_vitals, last POSTHOG_REPORT_WEB_VITALS_D days,
#                 p75 LCP, CLS and INP by route ($pathname)
#
# Knobs: catalog/lanes.d/_lib.posthog-lookup.json (settings rows
# lib.posthog-lookup.<env lowercased>), applied with lib_env_apply posthog-lookup.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
USAGE='usage: posthog-lookup.sh <project> "<hogql>" | posthog-lookup.sh <project> --report api-failures|web-vitals'

P="${1:-}"; Q=""; R=""
if [ "${2:-}" = --report ]; then
  R="${3:-}"
  case "$R" in api-failures|web-vitals) ;; *) echo "$USAGE" >&2; exit 2 ;; esac
  [ $# -eq 3 ] || { echo "$USAGE" >&2; exit 2; }
else
  Q="${2:-}"
  [ $# -eq 2 ] && [ -n "$Q" ] || { echo "$USAGE" >&2; exit 2; }
fi
[ -n "$P" ] || { echo "$USAGE" >&2; exit 2; }

# shellcheck source=bin/lib/token-redact.sh
. "$SELF/lib/token-redact.sh" || { echo "(posthog lookup unavailable — bin/lib/token-redact.sh missing)"; exit 0; }
# shellcheck source=bin/lib/signal-source.sh
. "$SELF/lib/signal-source.sh" || { echo "(posthog lookup unavailable — bin/lib/signal-source.sh missing)"; exit 0; }
# shellcheck source=bin/lib/watchdog-url.sh
. "$SELF/lib/watchdog-url.sh" || { echo "(posthog lookup unavailable — bin/lib/watchdog-url.sh missing)"; exit 0; }
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
{ command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply posthog-lookup; } >/dev/null 2>&1 || true

# _pl_int <value> <default> <min> <max>: out of range is the default, never a clamp.
_pl_int() {
  if [[ $1 =~ ^[0-9]+$ ]] && [ "$((10#$1))" -ge "$3" ] && [ "$((10#$1))" -le "$4" ]; then printf '%s' "$((10#$1))"
  else printf '%s' "$2"; fi
}
# Fallbacks, each the default of its settings row lib.posthog-lookup.<env lowercased>.
TIMEOUT=$(_pl_int "${POSTHOG_LOOKUP_TIMEOUT_S:-25}" 25 1 120)         # lib.posthog-lookup.posthog_lookup_timeout_s
MAXROWS=$(_pl_int "${POSTHOG_LOOKUP_MAX_ROWS:-50}" 50 1 1000)         # lib.posthog-lookup.posthog_lookup_max_rows
FAIL_H=$(_pl_int "${POSTHOG_REPORT_API_FAILURES_H:-24}" 24 1 336)     # lib.posthog-lookup.posthog_report_api_failures_h
VITALS_D=$(_pl_int "${POSTHOG_REPORT_WEB_VITALS_D:-7}" 7 1 90)        # lib.posthog-lookup.posthog_report_web_vitals_d
FAIL_EV="${POSTHOG_REPORT_API_FAILURE_EVENT:-api_error}"              # lib.posthog-lookup.posthog_report_api_failure_event
EV_RE='^[A-Za-z0-9_$]+$'
[[ $FAIL_EV =~ $EV_RE ]] || FAIL_EV=api_error

# Privacy: refuse before any call.
if [ -n "$Q" ] && grep -Eiq '(^|[^A-Za-z0-9_$])(person|persons|email|name|\$ip)([^A-Za-z0-9_]|$)' <<<"$Q"; then
  echo "(posthog lookup refused: the query reads person fields)"; exit 0
fi

src=0; ss_posthog "$P" || src=$?
case "$src" in
  0) ;;
  1) echo "(posthog lookup unavailable — bad signal source row for $P)"; exit 0 ;;
  *) echo "(posthog lookup unavailable — no PostHog source for $P)"; exit 0 ;;
esac
if [ -z "$SS_KEY" ]; then
  echo "(posthog lookup unavailable — $SS_KEY_ENV unset for $P)"; exit 0
fi

F=""; [ -n "$SS_FILTER" ] && F=" AND $SS_FILTER"
case "$R" in
  api-failures)
    Q="SELECT properties.endpoint AS endpoint, properties.status AS status, count() AS failures FROM events WHERE event = '$FAIL_EV' AND timestamp > now() - INTERVAL $FAIL_H HOUR$F GROUP BY endpoint, status ORDER BY failures DESC LIMIT $MAXROWS" ;;
  web-vitals)
    Q="SELECT properties.\$pathname AS route, quantile(0.75)(properties.\$web_vitals_LCP_value) AS p75_lcp_ms, quantile(0.75)(properties.\$web_vitals_CLS_value) AS p75_cls, quantile(0.75)(properties.\$web_vitals_INP_value) AS p75_inp_ms, count() AS samples FROM events WHERE event = '\$web_vitals' AND timestamp > now() - INTERVAL $VITALS_D DAY$F GROUP BY route ORDER BY samples DESC LIMIT $MAXROWS" ;;
esac

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/posthog-lookup.XXXXXX") || { echo "(posthog lookup failed: no temp dir)"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT
jq -nc --arg q "$Q" '{query: {kind: "HogQLQuery", query: $q}, name: "posthog-lookup"}' > "$TMPD/body.json" \
  || { echo "(posthog lookup failed: the request could not be built)"; exit 0; }

crc=0
code=$(watchdog_curl "$SS_KEY" -sS -m "$TIMEOUT" --max-redirs 0 -o "$TMPD/out.json" -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' --data-binary "@$TMPD/body.json" \
  "$SS_HOST/api/projects/$SS_PID/query/" 2>/dev/null) || crc=$?
if [ "$crc" = 28 ]; then echo "(posthog lookup failed: timeout)"; exit 0; fi
if [ "$crc" != 0 ]; then echo "(posthog lookup failed: curl error $crc)"; exit 0; fi
[[ $code =~ ^[0-9]{3}$ ]] || code=000
if [[ $code != 2?? ]]; then echo "(posthog lookup failed: HTTP $code)"; exit 0; fi
if ! jq -e '(.results | type) == "array"' "$TMPD/out.json" >/dev/null 2>&1; then
  echo "(posthog lookup: unparseable response)"; exit 0
fi

jq -r --argjson max "$MAXROWS" '
  def cell: (if type == "string" then . else tojson end) | gsub("[\t\r\n]"; " ");
  def row: (if type == "array" then . else [.] end) | map(cell) | join("\t");
  (.results | length) as $n
  | if $n == 0 then "(posthog: no rows)"
    else ((.columns // []) | map(tostring | cell) | join("\t")),
         (.results[0:$max][] | row),
         (if $n > $max then "(posthog: \($n - $max) more rows not shown)" else empty end)
    end' "$TMPD/out.json" 2>/dev/null \
  | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<redacted:email>/g' \
  | token_redact
exit 0
