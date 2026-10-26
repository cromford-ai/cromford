#!/bin/bash
# bin/lib/web-task/approval.sh — BH-8386 (fills the BH-7594 S1 stub of PR #7650):
# a person approves one write step of a web-task run before it runs.
# Sourced, never run; functions only. On source it sets __wta_dir and nothing
# else; bin/lib/web-human.sh is sourced on the first request, not here, so a
# box without web-vault.sh can still load this file.
# Note: docs/notes/2026-10-26-BH-8386-web-task-approval.md.
# Test: tests/web-task-approval.bh-8386-test.sh.
#
#   wt_approval_request <project> <KEY> <action-json>
#     action-json: {"site": "...", "action": "...", "issue": "<owner/repo#n>"?, "shot": "<png>"?}
#     Asks through `wh_request_human <project> <site> approve <prompt>` (the
#     same kind the BH-7599 JS write gate uses), with the prompt
#     `Approve write on <site> for <KEY>: <action>` (control characters become
#     spaces). It blocks for the worker's wait, then writes one record and
#     prints its request id `<LANE_RUN_ID>-<n>`.
#     rc 0: the id on stdout. The record says approved (web-human rc 0 and
#           stdout exactly `done`), denied (rc 3) or pending <step> (rc 4).
#     rc 1: any other web-human outcome, or the record write failed. No id,
#           no record: the write is not approved.
#     rc 2: usage, or no LANE_RUN_ID; nothing is asked.
#     rc 69: `not available` on stdout: bin/lib/web-human.sh did not load.
#
#   wt_approval_status <request-id>
#     Reads the record; no network. rc 0: `approved`, `denied` or `pending`
#     on stdout (pending also prints `wt-approval: step <id>` on stderr, the
#     step a resume run takes over with wh_resume_human). rc 1: `unknown` on
#     stderr, no record. rc 2: an id that is not one.
#
# Records: one file per id in ${WT_APPROVAL_DIR:-${TMPDIR:-/tmp}/web-task-approval-<LANE_RUN_ID>}
# (mode 700), one line: `approved`, `denied` or `pending [<step>]`. No secret.

__wta_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

wt_approval_request() {
  local usage='wt-approval: usage: wt_approval_request <project> <KEY> <action-json>'
  [ $# -eq 3 ] || { echo "$usage" >&2; return 2; }
  local project=$1 key=$2 json=$3 run=${LANE_RUN_ID:-}
  [[ $project =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "$usage (bad project)" >&2; return 2; }
  [[ $key =~ ^[A-Z]+-[0-9]+$ ]] || { echo "$usage (bad KEY)" >&2; return 2; }
  [[ $run =~ ^[1-9][0-9]{0,15}$ ]] || { echo "wt-approval: no LANE_RUN_ID (wt_approval_request runs inside a lane run)" >&2; return 2; }
  jq -e 'type == "object"
      and (.site | type == "string" and length > 0)
      and (.action | type == "string" and length > 0)
      and ((has("issue") | not) or (.issue | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*$")))
      and ((has("shot") | not) or (.shot | type == "string" and length > 0))' <<<"$json" >/dev/null 2>&1 \
    || { echo "$usage (bad action-json)" >&2; return 2; }

  if ! declare -F wh_request_human >/dev/null; then
    # shellcheck source=bin/lib/web-human.sh
    { [ -f "$__wta_dir/../web-human.sh" ] && . "$__wta_dir/../web-human.sh" && declare -F wh_request_human >/dev/null; } \
      || { echo "not available"; return 69; }
  fi

  local site action issue shot prompt
  site=$(jq -r .site <<<"$json")
  action=$(jq -r '.action | gsub("[\u0000-\u001f\u007f]"; " ")' <<<"$json")
  issue=$(jq -r '.issue // empty' <<<"$json")
  shot=$(jq -r '.shot // empty' <<<"$json")
  prompt="Approve write on $site for $key: $action"
  local -a args=("$project" "$site" approve "$prompt")
  [ -n "$shot" ] && args+=(--shot "$shot")
  [ -n "$issue" ] && args+=(--issue "$issue")

  local errf out rc=0 outcome step
  errf=$(mktemp) || { echo "wt-approval: mktemp failed" >&2; return 1; }
  # The x keeps a trailing newline: `done` followed by one is not the exact answer.
  out=$(wh_request_human "${args[@]}" 2>"$errf"; r=$?; printf x; exit "$r") || rc=$?
  out=${out%x}
  cat "$errf" >&2
  step=$(sed -n 's/^web-human: waiting on human (step \([0-9][0-9]*\))$/\1/p' "$errf" | tail -n 1)
  rm -f "$errf"
  if [ "$rc" = 0 ] && [ "$out" = done ]; then outcome=approved
  elif [ "$rc" = 3 ]; then outcome=denied
  elif [ "$rc" = 4 ]; then outcome="pending${step:+ $step}"
  else echo "wt-approval: request failed (web-human rc $rc)" >&2; return 1
  fi

  local dir=${WT_APPROVAL_DIR:-${TMPDIR:-/tmp}/web-task-approval-$run} n=1 id tmp
  { mkdir -p -m 700 "$dir" && [ -d "$dir" ] && [ -w "$dir" ]; } 2>/dev/null \
    || { echo "wt-approval: record dir $dir not writable" >&2; return 1; }
  while :; do
    id="$run-$n"
    ( set -C; : > "$dir/$id" ) 2>/dev/null && break
    [ -e "$dir/$id" ] || { echo "wt-approval: cannot write record $id" >&2; return 1; }
    n=$((n + 1))
  done
  tmp="$dir/.$id.$$"
  { printf '%s\n' "$outcome" > "$tmp" && mv -f "$tmp" "$dir/$id"; } 2>/dev/null \
    || { rm -f "$tmp" "$dir/$id"; echo "wt-approval: cannot write record $id" >&2; return 1; }
  printf '%s\n' "$id"
}

wt_approval_status() {
  [ $# -eq 1 ] && [[ $1 =~ ^([1-9][0-9]{0,15})-[1-9][0-9]{0,15}$ ]] \
    || { echo "wt-approval: usage: wt_approval_status <request-id>" >&2; return 2; }
  local id=$1 run=${BASH_REMATCH[1]} rec
  local dir=${WT_APPROVAL_DIR:-${TMPDIR:-/tmp}/web-task-approval-$run}
  [ -f "$dir/$id" ] && rec=$(head -n 1 "$dir/$id" 2>/dev/null) && [ -n "$rec" ] \
    || { echo "wt-approval: unknown request $id" >&2; return 1; }
  case $rec in
    approved|denied) echo "$rec" ;;
    pending) echo pending ;;
    "pending "*) echo pending; echo "wt-approval: step ${rec#pending }" >&2 ;;
    *) echo "wt-approval: unknown request $id (bad record)" >&2; return 1 ;;
  esac
}
