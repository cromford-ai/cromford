#!/bin/bash
# bin/lib/mr-red.sh — BH-9532 (C0, #9539): the shared box side of Mr Red, the
# staff agent that owns red minutes. Sourced by bin/staff/mr-red.sh and by the
# lever and collector fragments of the sibling slices. It defines functions
# only, runs nothing on source and builds no path from an empty root.
# The callers load bin/jobs-client.sh (setting_get, flag_active, _jobs_req),
# bin/lib/staff-contract.sh and bin/lib/lane-placement.sh first; jq is needed.
#
#   mrr_killed                  prints the first kill switch that is set and
#                               returns 0: STAFF_ENABLED=0, then the flags
#                               staff-off-all, staff-kill-all,
#                               staff-off-mr-red, staff-kill-mr-red. rc 1 =
#                               none is set.
#   mrr_setting <key> <fallback>
#                               the settings row staff.mr-red.<key>, trimmed;
#                               the fallback on an empty row or an outage.
#                               A number knob uses staff_knob mr-red instead.
#   mrr_action_post <json>      POST /api/mr-red/actions
#   mrr_action_patch <key> <json>
#                               PATCH /api/mr-red/actions/<key>
#   mrr_actions_get <query>     GET /api/mr-red/actions?<query>
#                               each prints the answer and passes the
#                               _jobs_req rc through (0 2xx, 9 409, 2 404,
#                               1 other); JOBS_HTTP holds the status.
#   mrr_dispatch <lever> <payload-json>
#                               one lane-run row of lane mr-red for the
#                               payload's project: `bin/staff/mr-red.sh work
#                               <payload>` on the pool. The payload must carry
#                               lever (= <lever>), action_key and project. rc 0
#                               enqueued, 3 already live, 1 failed or a bad
#                               payload.
#   mrr_fingerprint <class> <repo> <target> <checks> <head>
#                               prints sha256("class|repo|target|checks|head").
#                               <checks> is a newline or comma list; it is
#                               sorted (LC_ALL=C), deduped and comma-joined.
#                               rc 1, nothing printed, unless <head> is 40
#                               lower-case hex.
# Note: docs/notes/2026-11-11-BH-9532-mr-red.md.

mrr_killed() {
  if [ "${STAFF_ENABLED:-1}" = 0 ]; then printf 'STAFF_ENABLED=0\n'; return 0; fi
  if flag_active staff-off-all; then printf 'staff-off-all\n'; return 0; fi
  if flag_active staff-kill-all; then printf 'staff-kill-all\n'; return 0; fi
  if flag_active staff-off-mr-red; then printf 'staff-off-mr-red\n'; return 0; fi
  if flag_active staff-kill-mr-red; then printf 'staff-kill-mr-red\n'; return 0; fi
  return 1
}

mrr_setting() {
  local v
  v=$(JOBS_ALERT=0 setting_get "staff.mr-red.${1:-}" 2>/dev/null) || v=""
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "${2:-}"; fi
}

mrr_action_post() { _jobs_req POST /api/mr-red/actions "${1:-}"; }
mrr_action_patch() {
  [[ ${1:-} =~ ^[0-9a-f]{64}$ ]] || return 1
  _jobs_req PATCH "/api/mr-red/actions/$1" "${2:-}"
}
mrr_actions_get() { _jobs_req GET "/api/mr-red/actions${1:+?$1}"; }

mrr_dispatch() {
  local lever="${1:-}" pay="${2:-}" root p
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] && [ -n "$lever" ] || return 1
  jq -e --arg l "$lever" '.lever == $l and (.action_key | type) == "string" and (.project | type) == "string"' \
    <<<"$pay" >/dev/null 2>&1 || return 1
  p=$(jq -r .project <<<"$pay")
  lp_enqueue mr-red "$p" "$root/bin/staff/mr-red.sh" work "$(jq -c . <<<"$pay")"
}

mrr_fingerprint() {
  local class="${1:-}" repo="${2:-}" target="${3:-}" checks="${4:-}" head="${5:-}" list
  [[ $head =~ ^[0-9a-f]{40}$ ]] || return 1
  list=$(printf '%s\n' "${checks//,/$'\n'}" | grep -v '^$' | LC_ALL=C sort -u | paste -sd, -)
  printf '%s' "$class|$repo|$target|$list|$head" | sha256sum | cut -d' ' -f1
}
