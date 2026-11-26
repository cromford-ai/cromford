#!/bin/bash
# bin/lib/review-probe.sh — a ticket reaches `review` only after a live probe of
# its primary screen (BH-9987). Sourced, never run.
#
# THE RULE. `review` asks the client to check the work in production. So the
# ticket moves there only when production answers its main screen.
# bin/board-closeout.sh no longer moves a ticket to `review` at PR open
# (nothing is merged or deployed then). bin/merged-ticket-advance.sh moves it
# after the deploy audit, and when no signed-in QA pass covered it, only after
# rp_probe answers `served` or `signin`.
#
#   rp_required <project>        1 (the gate is on) or 0. Knob row
#                                lib.review-probe[.<project>].review_probe_require
#                                (catalog/lanes.d/_lib.review-probe.json);
#                                anything but 0 reads 1.
#   rp_primary_route <plan.md>   the first static route of the plan's
#                                `## QA screens` section, else `/`.
#   rp_probe <base> <route>      ONE unauthenticated GET of <base><route>.
#                                Prints `<outcome>\t<code>\t<final url>` and
#                                sets RP_OUTCOME, RP_CODE, RP_URL.
#   rp_passes <outcome>          rc 0 for served and signin, else rc 1.
#
# THE DECISION TABLE (rp_probe):
#   served     2xx, final host = base host, final path = route (query and
#              fragment dropped, one trailing slash dropped except on `/`)
#   signin     2xx, final path ^/(sign-in|signin|login|log-in)(/|$) on any host:
#              the app answered and the screen asks for sign-in
#   elsewhere  2xx at any other path or host (sent home, a near miss)
#   error      000, a 3xx left after the redirect cap, 4xx, 5xx, no answer,
#              an answer that does not parse, an empty base
#
# READ ONLY. No auth header, no body, no cookie jar, one GET with redirects
# followed (at most REVIEW_PROBE_MAX_REDIRS, row
# lib.review-probe.review_probe_max_redirs; 5 is its fallback). The timeout is
# the knob REVIEW_PROBE_TIMEOUT_S, row
# lib.review-probe.review_probe_timeout_s; 20 is its fallback.

_RP_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

rp_required() {
  # The knob rows are read in a subshell, so lane-gate.sh never loads into a
  # caller that did not load it (bin/board-closeout.sh). A caller that already
  # has lib_env_apply (bin/merged-ticket-advance.sh) gets the same answer.
  (
    if [ "${LANE_GATE_DISABLE:-0}" != 1 ] && ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$_RP_LIBDIR/lane-gate.sh" ] && . "$_RP_LIBDIR/lane-gate.sh" >/dev/null 2>&1
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply review-probe "${1:-}" >/dev/null 2>&1
    # Fallback 1 is the documented default of lib.review-probe.review_probe_require.
    if [ "${REVIEW_PROBE_REQUIRE:-1}" = 0 ]; then echo 0; else echo 1; fi
  )
}

rp_primary_route() {
  local r
  r=$(awk '/^##[[:space:]]*QA screens/{f=1;next} f&&/^##[[:space:]]/{exit} f' "${1:-}" 2>/dev/null \
    | grep -oE '(^|[^A-Za-z0-9._~:/?#@!$&()*+,;=-])/[]A-Za-z0-9._~/[-]*' \
    | sed -E 's#^[^/]*##; s#\.+$##' \
    | grep -vE '^/(root|tmp|usr|var|etc|home)(/|$)' | grep -vF '[' | head -1)
  printf '%s\n' "${r:-/}"
}

# _rp_norm_path <path> -> the path with query and fragment dropped, `/` when
# empty, one trailing slash dropped except on `/`.
_rp_norm_path() {
  local p="${1%%\?*}"; p="${p%%#*}"
  [ -n "$p" ] || p=/
  [ "$p" != / ] && p="${p%/}"
  printf '%s' "$p"
}

rp_probe() {
  local base="${1:-}" route="${2:-/}" t mr out code url bhost fhost fpath rest want
  RP_OUTCOME=error; RP_CODE=000; RP_URL=""
  t="${REVIEW_PROBE_TIMEOUT_S:-20}"
  case "$t" in ''|*[!0-9]*) t=20 ;; esac
  t=$((10#$t)); [ "$t" -lt 1 ] && t=1; [ "$t" -gt 120 ] && t=120
  # REVIEW_PROBE_MAX_REDIRS (row lib.review-probe.review_probe_max_redirs):
  # a longer chain is `error`. 5 is the documented fallback.
  mr="${REVIEW_PROBE_MAX_REDIRS:-5}"
  case "$mr" in ''|*[!0-9]*) mr=5 ;; esac
  mr=$((10#$mr))
  base="${base%/}"
  case "$route" in /*) ;; *) route="/$route" ;; esac
  case "$base" in http://?*|https://?*) ;; *) printf '%s\t%s\t%s\n' "$RP_OUTCOME" "$RP_CODE" "$RP_URL"; return 0 ;; esac
  out=$(curl -s -L --max-redirs "$mr" -o /dev/null --max-time "$t" -w '%{http_code} %{url_effective}' \
          -A 'cromford-review-probe' "$base$route" </dev/null 2>/dev/null) || true
  code="${out%% *}"; url=""
  [ "$code" != "$out" ] && url="${out#* }"
  case "$code" in [0-9][0-9][0-9]) RP_CODE="$code" ;; *) code=000 ;; esac
  RP_URL="$url"
  bhost="${base#*://}"; bhost="${bhost%%/*}"; bhost=$(printf '%s' "$bhost" | tr 'A-Z' 'a-z')
  case "$code:$url" in
    2[0-9][0-9]:http://?*|2[0-9][0-9]:https://?*)
      rest="${url#*://}"
      fhost="${rest%%[/?#]*}"; fhost=$(printf '%s' "$fhost" | tr 'A-Z' 'a-z')
      fpath="${rest#"${rest%%[/?#]*}"}"
      case "$fpath" in /*) ;; *) fpath="/$fpath" ;; esac
      fpath=$(_rp_norm_path "$fpath")
      want=$(_rp_norm_path "$route")
      if [ "$fhost" = "$bhost" ] && [ "$fpath" = "$want" ]; then RP_OUTCOME=served
      elif [[ "$fpath" =~ ^/(sign-in|signin|login|log-in)(/|$) ]]; then RP_OUTCOME=signin
      else RP_OUTCOME=elsewhere
      fi ;;
  esac
  printf '%s\t%s\t%s\n' "$RP_OUTCOME" "$RP_CODE" "$RP_URL"
  return 0
}

rp_passes() {
  case "${1:-}" in served|signin) return 0 ;; *) return 1 ;; esac
}
