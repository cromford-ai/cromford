#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/request.sh — BH-3451 (BH-3434.4): the request path. Reads
# `HUB_PROBE: <probe> <args>` lines out of a build's own output and files each
# one through the contract's hp_request. Sourced, never run.
#
# hp_parse_request_lines <file>
#   Pure: no network, nothing written but stderr. Prints one `probe<TAB>args`
#   line per valid request, de-duplicated in first-seen order. rc 2 on a
#   missing argument or an unreadable file, rc 0 otherwise (nothing matched
#   included). A line is a request only when the WHOLE line matches
#   `^HUB_PROBE: ([a-z0-9-]+)( [^ ]+)*$` (case-sensitive, column 0, single spaces;
#   the ticket's [a-z-]+ is widened by the digit so d1-count can match)
#   and the probe is one of HP_PROBES and hp_validate accepts it and its args.
#   Skipped: lines inside a
#   ``` or ~~~ fence (quotes), any line carrying `lead-verdict`, any line with
#   a control character after one trailing \r is stripped (tab included). A
#   skipped or invalid line that starts with `HUB_PROBE:` is logged on stderr as
#   `hub-probe: dropped invalid request line: <first 120 chars>`; prose is not.
# hp_file_requests <project> <ticket_key> <file> <requested_by>
#   Calls hp_request once per parsed line, with args as a JSON array of strings
#   built by jq (`[]` for none), and prints one `hub-probe: filed …` or
#   `hub-probe: NOT filed …` line each. rc 0 when every line filed or there were
#   none, rc 1 on a bad argument count, when hp_request is not loaded, or when
#   any line failed to file. The server's natural key makes a re-file a no-op
#   (`created=false`).
[ -n "${_HP_REQUEST_LOADED:-}" ] && return 0
# shellcheck source=bin/lib/hub-probes/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh" 2>/dev/null || return 1
_HP_REQUEST_LOADED=1

hp_parse_request_lines() {
  [ $# -eq 1 ] && [ -f "$1" ] && [ -r "$1" ] || return 2
  local line probe fence=0 re='^HUB_PROBE: ([a-z0-9-]+)(( [^ ]+)*)$' seen=$'\n' row
  local -a args
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [[ "$line" =~ ^[[:space:]]*(\`\`\`|~~~) ]]; then
      fence=$((1 - fence)); continue
    fi
    [ "$fence" = 0 ] || continue
    if [[ "$line" == *lead-verdict* || "$line" == *[[:cntrl:]]* ]] || ! [[ "$line" =~ $re ]]; then
      [[ "$line" == HUB_PROBE:* ]] && printf 'hub-probe: dropped invalid request line: %.120s\n' "$line" >&2
      continue
    fi
    probe=${BASH_REMATCH[1]}
    IFS=' ' read -ra args <<< "${BASH_REMATCH[2]}"
    # HP_SCREEN_PROBES validate too, but only the console files them (BH-7997).
    if ! _hp_in "$probe" "$HP_PROBES" || ! hp_validate "$probe" "${args[@]}"; then
      printf 'hub-probe: dropped invalid request line: %.120s\n' "$line" >&2
      continue
    fi
    row=$(printf '%s\t%s' "$probe" "${args[*]}")
    case "$seen" in *$'\n'"$row"$'\n'*) continue ;; esac
    seen+="$row"$'\n'
    printf '%s\n' "$row"
  done < "$1"
  return 0
}

hp_file_requests() {
  [ $# -eq 4 ] || return 1
  local rows probe rest args_json out rc=0
  local -a args
  rows=$(hp_parse_request_lines "$3") || return 1
  [ -n "$rows" ] || return 0
  if ! declare -F hp_request >/dev/null; then
    echo "hub-probe: client not loaded, $(printf '%s\n' "$rows" | grep -c .) request(s) not filed"
    return 1
  fi
  while IFS=$'\t' read -r probe rest; do
    IFS=' ' read -ra args <<< "$rest"
    args_json=$(jq -nc '$ARGS.positional' --args "${args[@]}") || { rc=1; continue; }
    if out=$(hp_request "$1" "$2" "$probe" "$args_json" "$4"); then
      echo "hub-probe: filed $probe${rest:+ $rest} (created=$(printf '%s' "$out" | jq -r '.created'))"
    else
      echo "hub-probe: NOT filed $probe${rest:+ $rest} (jobs API refused or unreachable)"
      rc=1
    fi
  done <<< "$rows"
  return "$rc"
}
