# shellcheck shell=bash
# bin/lib/docker-pool.sh — the shell client of the docker-pool claim lease
# (POST /api/docker-pool/{claim,heartbeat,release,sweep}, BH-7300). Contract
# and knobs: docs/notes/2026-10-17-BH-7300-docker-pool-lease.md.
#
#   docker_pool_claim     <project> <key>
#       rc 0 prints one TSV line: key ticket_id attempt lease_until
#   docker_pool_heartbeat <project> <key>
#       rc 0 prints lease_until
#   docker_pool_release   <project> <key> <done|queued> [reason]
#       rc 0 prints the number of rows requeued (0 for done)
#   docker_pool_sweep
#       rc 0 prints `<expired> <requeued> <backlog 0|1>` (TSV), then one TSV
#       line per expired lease: project key box requeued(1|0)
#
# rc 9 = the worker refused: off, killed, full, lost, not_pool, or a heartbeat
# or release that lost its lease. The reason goes to stderr. rc 2 = nothing
# queued for that key (404). rc 1 = anything else: a missing argument (no
# request is sent), no jobs client, no JOBS_BOX, a transport failure, a 4xx/5xx,
# or a 200 without its fields. rc 1 never prints a TSV line.
#
# The box is $JOBS_BOX (bin/lib/jobs/req.sh resolves it). Needs _jobs_req
# (bin/jobs-client.sh) from the caller. Defines functions only. Nothing runs
# on source.

# _dp_call <op> <json> — POST the op. rc 0 prints the payload; rc 9 prints the
# refusal reason to stderr; rc 2 and rc 1 print nothing.
_dp_call() {
  local op="$1" body="$2" out rc why
  declare -F _jobs_req >/dev/null || return 1
  out=$(_jobs_req POST "/api/docker-pool/$op" "$body"); rc=$?
  case "$rc" in
    0) printf '%s' "$out" ;;
    9) why=$(jq -r '.reason // empty' <<<"$out" 2>/dev/null)
       [ -n "$why" ] || return 1
       printf 'docker-pool %s refused: %s\n' "$op" "$why" >&2
       return 9 ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}

# _dp_body <project> <key> — the {project, key, box} body, or rc 1.
_dp_body() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${JOBS_BOX:-}" ] || return 1
  jq -nc --arg p "$1" --arg k "$2" --arg b "$JOBS_BOX" '{project:$p,key:$k,box:$b}'
}

docker_pool_claim() {
  local body out line
  body=$(_dp_body "${1:-}" "${2:-}") || return 1
  out=$(_dp_call claim "$body") || return $?
  line=$(jq -r 'select(.claimed == true and (.queued.ticket_key // "") != "" and (.lease_until // "") != "")
    | [.queued.ticket_key, (.queued.ticket_id // "-"), (.queued.attempt // 0), .lease_until] | @tsv' <<<"$out" 2>/dev/null)
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

docker_pool_heartbeat() {
  local body out v
  body=$(_dp_body "${1:-}" "${2:-}") || return 1
  out=$(_dp_call heartbeat "$body") || return $?
  v=$(jq -r '.lease_until // empty' <<<"$out" 2>/dev/null)
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

docker_pool_release() {
  local body out v
  case "${3:-}" in done|queued) ;; *) return 1 ;; esac
  body=$(_dp_body "${1:-}" "${2:-}") || return 1
  body=$(jq -c --arg s "$3" --arg r "${4:-}" '. + {status:$s} + (if $r == "" then {} else {reason:$r} end)' <<<"$body") || return 1
  out=$(_dp_call release "$body") || return $?
  v=$(jq -r 'select(.released == true) | .requeued // empty' <<<"$out" 2>/dev/null)
  [[ $v =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}

docker_pool_sweep() {
  local out rc
  out=$(_dp_call sweep '{}'); rc=$?
  # A sweep has no 404 answer: anything but a 200 is the worker being unusable.
  [ "$rc" = 0 ] || return 1
  jq -e '(.expired | type) == "array" and (.requeued | type) == "number"' <<<"$out" >/dev/null 2>&1 || return 1
  jq -r '([(.expired | length), .requeued, (if .backlog then 1 else 0 end)] | @tsv),
         (.expired[] | [.project, .key, .box, (if .requeued then 1 else 0 end)] | @tsv)' <<<"$out"
}
