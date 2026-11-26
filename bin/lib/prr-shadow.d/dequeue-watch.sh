#!/bin/bash
# bin/lib/prr-shadow.d/dequeue-watch.sh — the prr-shadow seam of lane dequeue-watch (BH-9926).
# Sourced by prr_seam_load dequeue-watch (bin/lib/prr-shadow.sh), never executed.
#
# The knob GH_SOURCE (settings row lane.dequeue-watch.gh_source, default
# shadow) is registered in catalog/lanes.d/dequeue-watch.knobs.d/.
# bin/lib/dequeue-watch/gather.sh calls prr_read dequeue-watch with these
# three reads (BH-9938, wave 6). Each record fn makes jobs reads only and, on a
# miss, prints one word and returns 1; each github fn is today's read, moved.
#
# The label lists, key "<slug>#labels":
#   dqw_labels_record <file> <slug>
#       pr_record_label_list <slug> merge-queue and <slug> dequeued (open). The
#       union, as the issue-list shape [{number, pull_request: {}, labels:
#       [{name}]}], so dqw_gather_dequeued's filter reads it unchanged. A miss
#       of either list is that list's word (pr_record_list's words).
#   dqw_labels_github <file> <slug>
#       The 2 label-list reads (dqw_gh_label_list in gather.sh), one array
#       each, one after the other in <file>. rc 1 when either read fails or is
#       not an array. A list of 100 writes one log line: the rest is unread.
#   dqw_labels_norm <file>
#       [{n}] of the PR numbers the gather filter keeps, sorted.
#
# The Mergify payload, key "<slug>#<n>:payload". <file> gets one TSV line,
# `state epoch cid draft run left checks`; `-` is "none":
#   dqw_payload_record <file> <slug> <n>
#       pr_record_mergify. epoch = .at; draft, run, left, checks only for a
#       dequeued state (left only as 40 hex, as the GitHub parse takes it).
#       Misses: the reader's word (unreadable, unknown, none); malformed
#       (no string state, an unparsable at or a bad comment id); field:run_id
#       (a dequeued payload of a row written before BH-9938, which has no
#       run_id key: the event row is keyed on the run).
#   dqw_payload_github <file> <slug> <n>
#       sdq_payload_last, then for a dequeued state the comment read
#       (dqw_gh_comment in gather.sh) and dqw_parse_payload_md. rc 1 no payload; rc 2 the payload read
#       failed; rc 3 the comment read failed; rc 4 the comment does not parse
#       as dequeued. epoch is the comment's updated_at. Sets DQW_PAYLOAD_CID
#       to the comment id it read, for the caller's skip line.
#   dqw_payload_norm <file>
#       [{n:"payload", state, cid}] plus draft, run, left and checks for a
#       dequeued state. The epoch is not compared: GitHub gives updated_at,
#       the record created_at, and the lane uses it only for the watchdog age.
#
# The combined status of a head, key "<slug>#<n>@<sha12>:status":
#   dqw_status_record <file> <slug> <n> <head>
#       pr_record_statuses <slug> <n> <head>, as {"statuses": [{context,
#       state, updated_at}]}. A miss is the reader's word (unreadable,
#       unknown, no-head, none).
#   dqw_status_github <file> <slug> <n> <head>
#       repos/<slug>/commits/<head>/status.
#   dqw_status_norm <file>
#       [{n: <context>, v: <state>}] of the vs_context context (default
#       lead-verdict) only.
if ! command -v pr_record_mergify >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi

dqw_labels_record() {
  local f="${1:-}" slug="${2:-}" l tmp why rc out="[]"
  [ -n "$f" ] || return 2
  command -v pr_record_label_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/dqw-labels.XXXXXX") || { echo unreadable; return 1; }
  for l in merge-queue dequeued; do
    why=$(pr_record_label_list "$slug" "$l" "$tmp" open); rc=$?
    if [ "$rc" != 0 ]; then
      rm -f "$tmp" "$tmp.sync"
      echo "${why:-unreadable}"; return 1
    fi
    if ! out=$(jq -c --argjson acc "$out" '$acc + [ .[] | {number, pull_request: {},
                   labels: [ (.labels // [])[] | strings | {name: .} ]} ]' "$tmp" 2>/dev/null); then
      rm -f "$tmp" "$tmp.sync"
      echo malformed; return 1
    fi
  done
  rm -f "$tmp" "$tmp.sync"
  printf '%s\n' "$out" > "$f"
}

dqw_labels_github() {
  local f="${1:-}" slug="${2:-}" l part
  [ -n "$f" ] || return 2
  : > "$f"
  part=$(mktemp "${TMPDIR:-/tmp}/dqw-labels.XXXXXX") || return 1
  for l in merge-queue dequeued; do
    # dqw_gh_label_list (bin/lib/dequeue-watch/gather.sh), as `> file`.
    dqw_gh_label_list "$slug" "$l" > "$part" || { rm -f "$part"; return 1; }
    jq -e 'type == "array"' "$part" >/dev/null 2>&1 || { rm -f "$part"; return 1; }
    [ "$(jq length "$part")" -lt 100 ] || _dqw_g_log "$slug label $l answered 100 issues, the rest are not read this tick"
    cat "$part" >> "$f"
  done
  rm -f "$part"
  return 0
}

dqw_labels_norm() {
  jq -sc 'add | map(select(.pull_request != null)
                    | select([.labels[]?.name] | (index("queued") or index("checking")) | not))
          | unique_by(.number) | map({n: .number})' "${1:-}" 2>/dev/null
}

dqw_payload_record() {
  local f="${1:-}" slug="${2:-}" n="${3:-}" tmp rc line
  [ -n "$f" ] || return 2
  command -v pr_record_mergify >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/dqw-payload.XXXXXX") || { echo unreadable; return 1; }
  PRR_MISS_WHY=""
  pr_record_mergify "$slug" "$n" > "$tmp"; rc=$?
  if [ "$rc" != 0 ]; then rm -f "$tmp"; echo "${PRR_MISS_WHY:-unreadable}"; return 1; fi
  line=$(jq -r '
    if (.state | type) != "string" or (.state | test("^[a-z_]+$") | not)
       or ((.comment_id | type) != "number") or .comment_id < 1
       or ((.at | type) != "string") or ((.at | fromdateiso8601?) == null) then "malformed"
    elif .state == "dequeued" and (has("run_id") | not) then "field:run_id"
    elif .state != "dequeued" then [.state, (.at | fromdateiso8601 | tostring), (.comment_id | tostring), "-", "-", "-", "-"] | @tsv
    else [.state, (.at | fromdateiso8601 | tostring), (.comment_id | tostring),
          (.draft_pr // "-" | tostring),
          (.run_id // "-" | tostring),
          (.left_sha // "" | if test("^[0-9a-f]{40}$") then . else "-" end),
          ((.failing_checks // []) | map(strings) | if length > 0 then join(",") else "-" end)] | @tsv
    end' "$tmp" 2>/dev/null) || line=malformed
  rm -f "$tmp"
  case "$line" in
    ''|malformed) echo malformed; return 1 ;;
    field:*) echo "$line"; return 1 ;;
  esac
  printf '%s\n' "$line" > "$f"
}

dqw_payload_github() {
  local f="${1:-}" slug="${2:-}" n="${3:-}" line state epoch cid body tsv c
  [ -n "$f" ] || return 2
  : > "$f"
  line=$(sdq_payload_last "$slug" "$n"); case $? in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  IFS=$'\t' read -r state epoch cid <<<"$line"
  DQW_PAYLOAD_CID=$cid
  if [ "$state" != dequeued ]; then
    printf '%s\t%s\t%s\t-\t-\t-\t-\n' "$state" "$epoch" "$cid" > "$f"
    return 0
  fi
  c="${DQW_TMP:-${TMPDIR:-/tmp}}/comment-${slug//\//_}-$n.json"
  # dqw_gh_comment (bin/lib/dequeue-watch/gather.sh), as `> file`.
  dqw_gh_comment "$slug" "$cid" > "$c" 2>/dev/null \
    && body=$(jq -er '.body | strings' "$c" 2>/dev/null) || return 3
  tsv=$(dqw_parse_payload_md "$body") || return 4
  printf '%s\t%s\t%s\t%s\n' "$state" "$epoch" "$cid" "$tsv" > "$f"
}

dqw_payload_norm() {
  local state epoch cid draft run left checks
  IFS=$'\t' read -r state epoch cid draft run left checks < "${1:-/dev/null}" || return 0
  [ -n "$state" ] || return 0
  if [ "$state" = dequeued ]; then
    jq -nc --arg s "$state" --arg c "$cid" --arg d "$draft" --arg r "$run" --arg l "$left" --arg k "$checks" \
      '[{n: "payload", state: $s, cid: $c, draft: $d, run: $r, left: $l, checks: $k}]'
  else
    jq -nc --arg s "$state" --arg c "$cid" '[{n: "payload", state: $s, cid: $c}]'
  fi
}

dqw_status_record() {
  local f="${1:-}" slug="${2:-}" n="${3:-}" head="${4:-}" tmp rc
  [ -n "$f" ] || return 2
  command -v pr_record_statuses >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/dqw-status.XXXXXX") || { echo unreadable; return 1; }
  PRR_MISS_WHY=""
  pr_record_statuses "$slug" "$n" "$head" > "$tmp"; rc=$?
  if [ "$rc" != 0 ]; then rm -f "$tmp"; echo "${PRR_MISS_WHY:-unreadable}"; return 1; fi
  if ! jq -c '{statuses: [to_entries[] | {context: .key, state: .value.state, updated_at: .value.at}]}' "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp"; : > "$f"; echo malformed; return 1
  fi
  rm -f "$tmp"
}

dqw_status_github() {
  local f="${1:-}" slug="${2:-}" head="${4:-}"
  [ -n "$f" ] || return 2
  gh_rest GET "repos/$slug/commits/$head/status" > "$f"
}

dqw_status_norm() {
  jq -c --arg c "$(vs_context 2>/dev/null || echo lead-verdict)" \
    '[.statuses[]? | select(.context == $c) | {n: .context, v: .state}] | unique_by(.n)' "${1:-}" 2>/dev/null
}
