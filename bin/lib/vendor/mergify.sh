# shellcheck shell=bash
# bin/lib/vendor/mergify.sh — the Mergify REST seam (BH-9695). Sourced only:
# no output, no `set` change and no trap on source.
#
# mergify_queue_leave_events reads Mergify's activity log for one PR, filtered
# to the `action.queue.leave` events (why the PR left the merge queue). The
# call takes the NAME of the env variable that holds the token, never the
# token, so the token is in no argv and no log: curl reads its Authorization
# header from stdin (`-K -`) through printf, a builtin. In fake mode
# (HARNESS_VENDOR_FAKE=1) the answer comes from
# tests/fixtures/vendor-fake/mergify.json (bin/lib/vendor/seam.sh) and no call
# is made. Contract suite: tests/contract/mergify.bh-9695.contract-test.sh.
# shellcheck source=seam.sh
. "${BASH_SOURCE[0]%/*}/seam.sh" || return 1

# _mg_int <value> <fallback> <min> <max> — the value when it is an integer in
#   min..max, else the fallback.
_mg_int() {
  local v="${1:-}"
  [[ $v =~ ^[0-9]{1,6}$ ]] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ] || v="$2"
  printf '%s' "$v"
}

# mergify_queue_leave_events <key_var_name> <owner/repo> <pr-number> — one GET
#   ${MERGIFY_API_URL:-https://api.mergify.com/v1}/repos/<slug>/logs
#     ?pull_request=<n>&event_type=action.queue.leave&per_page=<k>
#   Prints the JSON object Mergify answered (`.events` is the list).
#   rc 0 a 2xx answer that is a JSON object; rc 1 a curl error, a non-2xx code
#   or an answer that is not a JSON object (one stderr line with the HTTP code,
#   never the token); rc 2 a bad variable name, slug, number or vendor mode;
#   rc 3 the token is not set; rc 70 an unseeded fake.
mergify_queue_leave_events() {
  local name="${1:-}" slug="${2:-}" num="${3:-}" key mode tmo per base out code rc body
  [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "mergify: '$name' is not a variable name" >&2; return 2; }
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && [[ "/$slug/" != */./* && "/$slug/" != */../* ]] \
    || { echo "mergify: '${slug:0:100}' is not an owner/name slug" >&2; return 2; }
  [[ "$num" =~ ^[0-9]{1,9}$ ]] || { echo "mergify: '${num:0:20}' is not a PR number" >&2; return 2; }
  mode=$(vendor_mode) || return 2
  if [ "$mode" = fake ]; then
    vendor_fake mergify queue_leave_events "$num"
    return $?
  fi
  key="${!name:-}"
  [ -n "$key" ] || { echo "mergify: $name is not set" >&2; return 3; }
  vendor_call_log mergify queue_leave_events
  # knobs: catalog/lanes.d/_lib.vendor-mergify.knobs.d/MERGIFY_API_TIMEOUT_S.json
  # and MERGIFY_EVENTS_PER_PAGE.json (env only; the defaults are the fallbacks).
  tmo=$(_mg_int "${MERGIFY_API_TIMEOUT_S:-10}" 10 1 120)
  per=$(_mg_int "${MERGIFY_EVENTS_PER_PAGE:-10}" 10 1 100)
  base="${MERGIFY_API_URL:-https://api.mergify.com/v1}"
  out=$(mktemp "${TMPDIR:-/tmp}/mergify-seam.XXXXXX") || { echo "mergify: cannot make a temp file" >&2; return 1; }
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$key" \
    | curl -sS -K - --max-time "$tmo" -o "$out" -w '%{http_code}' \
        "$base/repos/$slug/logs?pull_request=$num&event_type=action.queue.leave&per_page=$per" 2>/dev/null)
  rc=$?
  body=$(cat "$out" 2>/dev/null); rm -f "$out"
  if [ "$rc" -ne 0 ] || ! [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    echo "mergify: logs read for $slug#$num failed (curl rc $rc, HTTP ${code:-000})" >&2
    return 1
  fi
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$body" \
    || { echo "mergify: logs read for $slug#$num answered HTTP $code with no JSON object" >&2; return 1; }
  printf '%s\n' "${body//"$key"/<token>}"
}
