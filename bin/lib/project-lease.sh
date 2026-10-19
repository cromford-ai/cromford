# shellcheck shell=bash
# bin/lib/project-lease.sh — the shell client of the project lease
# (POST /api/project-leases/{acquire,renew,release}, BH-6883). Contract:
# docs/notes/2026-10-15-BH-6883-project-lease.md.
#
#   pjl_acquire <lane> <project> <holder>          rc 0 prints the fence
#   pjl_renew   <lane> <project> <holder> <fence>  rc 0 prints lease_until
#   pjl_release <lane> <project> <holder> <fence>  rc 0
#
# rc 3 = the lease is not yours: acquire answered 409 `held`, or renew/release
# answered 409 `lost`. rc 1 = anything else: a missing argument (no request is
# sent), no jobs client, a transport failure, a 4xx/5xx, a 409 with another
# error, or a 200 without the field. An outage is never rc 3.
#
# PJL_TTL_S (10..900), when set, is sent as ttl_s on acquire and renew (BH-7505:
# a hub pool tick holds the lease for a long run); unset, the settings row decides.
# The holder must be unique per process (the machine id). Needs _jobs_req
# (bin/jobs-client.sh) from the caller. Defines functions only. Nothing runs
# on source.

# _pjl_call <op> <expect-409-error> <field> <json> — POST the op, print <field>
# of a 200 answer when it is set.
_pjl_call() {
  local op="$1" lost="$2" field="$3" body="$4" out rc v
  declare -F _jobs_req >/dev/null || return 1
  out=$(_jobs_req POST "/api/project-leases/$op" "$body"); rc=$?
  if [ "$rc" = 9 ]; then
    [ "$(jq -r '.error // empty' <<<"$out" 2>/dev/null)" = "$lost" ] && return 3
    return 1
  fi
  [ "$rc" = 0 ] || return 1
  [ -n "$field" ] || return 0
  v=$(jq -r --arg f "$field" '.[$f] // empty' <<<"$out" 2>/dev/null)
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# _pjl_ttl — the JSON object to add to a request body: {"ttl_s":<n>} when
# PJL_TTL_S is a whole number in 10..900 (the route's bounds; BH-7505: a hub
# tick that holds the lease for a long run asks for a longer one), else {} and
# the settings row decides.
_pjl_ttl() {
  local t="${PJL_TTL_S:-}"
  if [[ $t =~ ^[0-9]{2,3}$ ]] && [ "$((10#$t))" -ge 10 ] && [ "$((10#$t))" -le 900 ]; then
    printf '{"ttl_s":%s}' "$((10#$t))"
  else
    printf '{}'
  fi
}

pjl_acquire() {
  local fence
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  fence=$(_pjl_call acquire held fence "$(jq -nc --arg l "$1" --arg p "$2" --arg h "$3" --argjson x "$(_pjl_ttl)" '{lane:$l,project:$p,holder:$h} + $x')") || return $?
  [[ $fence =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$fence"
}

pjl_renew() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] && [[ ${4:-} =~ ^[1-9][0-9]*$ ]] || return 1
  _pjl_call renew lost lease_until \
    "$(jq -nc --arg l "$1" --arg p "$2" --arg h "$3" --argjson f "$4" --argjson x "$(_pjl_ttl)" '{lane:$l,project:$p,holder:$h,fence:$f} + $x')"
}

pjl_release() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] && [[ ${4:-} =~ ^[1-9][0-9]*$ ]] || return 1
  _pjl_call release lost "" \
    "$(jq -nc --arg l "$1" --arg p "$2" --arg h "$3" --argjson f "$4" '{lane:$l,project:$p,holder:$h,fence:$f}')"
}
