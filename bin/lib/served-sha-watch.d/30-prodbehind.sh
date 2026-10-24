#!/bin/bash
# gh-identity: app-token
# bin/lib/served-sha-watch.d/30-prodbehind.sh - the "prod behind main" page of
# the served-sha watch. Sourced by bin/served-sha-watch.sh's hook loop, never
# executed.
#
# WHY. project-3 production served an old build for 27h while main moved three
# times and each new production deployment failed. 10-alert.sh pages one id
# per head sha (served-behind:<p>:<head12>), so every new merge was a new,
# separate page and nothing said how long prod had been behind.
#
# WHAT. ssw_hook_prodbehind reads the driver's verdict:
#   wait|alert  keep a project-level clock .prodbehind.since in the state file
#               (kept across head changes; seeded from HEAD's age on the first
#               behind tick). When prod has been behind for
#               SERVED_SHA_PRODBEHIND_MIN minutes or more AND the newest
#               production deployment of the project is ERROR, record
#               .prodbehind.open FIRST, then page ONE id prodbehind:<p> through
#               bin/lane-alert.sh --critical, with ALERT_REMINDER_S set to
#               SERVED_SHA_PRODBEHIND_REPEAT_H hours for that one call. The
#               lane-alert state machine suppresses repeats and sends one
#               "still firing" reminder per that window.
#   in-sync     one --resolve of prodbehind:<p> when .prodbehind.open is set.
#               The driver deletes the state file after the hooks.
#   anything else (unreadable) does nothing: "cannot tell" is never a page.
# A newest deployment that is BUILDING, QUEUED, INITIALIZING, READY, CANCELED
# or unreadable is no page. A failed field read prints `?`, never 0. A failed
# state write still pages and returns 1 (the driver logs it).
#
# Knobs (catalog/lanes.d/served-sha-watch.knobs.d/): SERVED_SHA_PRODBEHIND_MIN
# (minutes, 0 = off), SERVED_SHA_PRODBEHIND_REPEAT_H (hours).

_ssw_pb_log() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$H/logs/served-sha-watch.log" 2>/dev/null; }

ssw_hook_prodbehind() {
  local p="${1:-}" verdict="${2:-}" head="${3:-}" served="${4:-}" age_s="${6:-}" sf="${7:-}"
  local min st since js rc=0 behind nd state uid dsha rep k
  [ -n "$p" ] && [ -n "$sf" ] && [ -n "${H:-}" ] || return 0

  if [ "$verdict" = in-sync ]; then
    st=$(ssw_state_read "$sf") || return 0
    [ "$(jq -r '.prodbehind.open // false' <<< "$st" 2>/dev/null)" = true ] || return 0
    "$H/bin/lane-alert.sh" --resolve --id "prodbehind:$p" served-sha-watch \
      "$p: prod serves ${served:0:8}, main is ${head:0:8}, back in sync" >/dev/null 2>&1 < /dev/null
    return 0
  fi
  case "$verdict" in wait|alert) ;; *) return 0 ;; esac

  # Fallback 45: the knob row is catalog/lanes.d/served-sha-watch.knobs.d/SERVED_SHA_PRODBEHIND_MIN.json.
  min="${SERVED_SHA_PRODBEHIND_MIN:-45}"
  case "$min" in ''|*[!0-9]*) _ssw_pb_log "SERVED_SHA_PRODBEHIND_MIN='${min:0:16}' is not a whole number - using 45"; min=45 ;; esac
  min=$((10#$min))
  [ "$min" = 0 ] && return 0

  st=$(ssw_state_read "$sf") || st='{}'
  since=$(jq -r '.prodbehind.since // empty' <<< "$st" 2>/dev/null)
  if ! [[ $since =~ ^[0-9]+$ ]]; then
    if [[ $age_s =~ ^[0-9]+$ ]]; then since=$((SSW_NOW - age_s)); else since=$SSW_NOW; fi
  fi
  js=$(jq -c --argjson s "$since" \
        '.prodbehind = (((.prodbehind // {}) | if type == "object" then . else {} end) + {since:$s})' <<< "$st" 2>/dev/null) \
    && ssw_state_write "$sf" "$js" || rc=1

  behind=$((SSW_NOW - since))
  [ "$behind" -ge $((min * 60)) ] || return "$rc"

  nd=$(_ssw_pb_newest "${SSW_TEAM:-}" "${SSW_PID:-}") || return "$rc"
  read -r state uid dsha <<< "$nd"
  [ "$state" = ERROR ] || return "$rc"

  st=$(ssw_state_read "$sf") || st='{}'
  js=$(jq -c '.prodbehind = (((.prodbehind // {}) | if type == "object" then . else {} end) + {open:true})' <<< "$st" 2>/dev/null) \
    && ssw_state_write "$sf" "$js" || rc=1

  # Fallback 4: the knob row is catalog/lanes.d/served-sha-watch.knobs.d/SERVED_SHA_PRODBEHIND_REPEAT_H.json.
  rep="${SERVED_SHA_PRODBEHIND_REPEAT_H:-4}"
  case "$rep" in ''|*[!0-9]*) _ssw_pb_log "SERVED_SHA_PRODBEHIND_REPEAT_H='${rep:0:16}' is not a whole number - using 4"; rep=4 ;; esac
  rep=$((10#$rep))
  [ "$rep" = 0 ] && { _ssw_pb_log "SERVED_SHA_PRODBEHIND_REPEAT_H=0 is not allowed - using 4"; rep=4; }

  k=$(_ssw_pb_ahead "$served" "$head")
  ALERT_REMINDER_S=$((rep * 3600)) "$H/bin/lane-alert.sh" --critical --id "prodbehind:$p" served-sha-watch \
    "PROD BEHIND MAIN: $p prod serves ${served:0:8}, main is ${head:0:8}, $k commits behind for $((behind / 3600))h$(printf '%02d' $(((behind % 3600) / 60)))m. Newest production deployment $uid (${dsha:0:8}) failed (ERROR). Logs: vercel inspect $uid --logs --scope ${SSW_TEAM:-?}" \
    >/dev/null 2>&1 < /dev/null
  return "$rc"
}

# _ssw_pb_newest <team> <pid> - `<STATE> <uid> <sha|?>` of the newest production
# deployment (largest .created, never index 0 blindly); rc 1 = cannot tell.
_ssw_pb_newest() {
  local team="${1:-}" pid="${2:-}" r
  [ -n "$team" ] && [ -n "$pid" ] || return 1
  r=$(ssw_vapi GET "/v6/deployments?projectId=$pid&teamId=$team&target=production&limit=20") || return 1
  _ssw_body "$r" | jq -er '
    if (.deployments | type) != "array" or (.deployments | length) == 0 then error("no list") else . end
    | .deployments | max_by(.created // 0)
    | ((.state // .readyState // "") | ascii_upcase) as $s
    | if $s == "" then error("no state") else . end
    | "\($s) \(.uid // .id // "?") \(((.meta.githubCommitSha // .gitSource.sha // "") | if . == "" then "?" else . end))"' 2>/dev/null
}

# _ssw_pb_ahead <served> <head> - GitHub's ahead_by, or ? when unreadable.
_ssw_pb_ahead() {
  local served="$1" head="$2" tmp k=""
  if [ -n "${SSW_SLUG:-}" ] && command -v gh_rest >/dev/null 2>&1; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/ssw-pb.XXXXXX") || { echo '?'; return 0; }
    gh_rest GET "repos/$SSW_SLUG/compare/$served...$head" > "$tmp" 2>/dev/null \
      && k=$(jq -r '.ahead_by | numbers' "$tmp" 2>/dev/null)
    rm -f "$tmp"
  fi
  [[ $k =~ ^[0-9]+$ ]] && echo "$k" || echo '?'
}
