#!/bin/bash
# bin/lib/gh-shim/actions.sh — `gh run view|rerun|list` as single REST calls
# (#769 chunk 3). Sourced by bin/gh-rest-shim step 6; never executed.
#
# Same contract as the write siblings: no arguments, read the parsed globals,
# call only the contract's gshim_* helpers, never gh / $GH_REAL / gh api. The
# argv walker (gshim_prw_parse) ships in pr-write.sh, in this slice, and step 6
# sources every handler file before step 7 dispatches.
#
# THE LOG OUTPUT IS OURS, NOT gh's (plan A6). `--log`/`--log-failed` print one
# `=== <job name> ===` header per job and then that job's raw log bytes. gh's
# `job\tstep\tline` framing is NOT reproduced: the three fleet callers
# (bin/pre-arm-guards.sh, bin/blocked-resolver.sh, bin/lib/flaky.sh) grep
# patterns and tail bytes out of the stream and read neither the job nor the
# step column.

# gshim_act_map — the jq expression that renames the REST run object to gh's
# --json field names. Applied to an object or to every element of an array.
# Only these names are mappable; gshim_fields_ok sends anything else to the real
# binary rather than inventing a value we never fetched.
GSHIM_ACT_FIELDS="databaseId,status,conclusion,headSha,headBranch,name,displayTitle,url,createdAt,updatedAt,event,number,attempt,workflowDatabaseId"
gshim_act_map() {
  printf '%s' "$1" | jq -c '
    def m: {
      databaseId: .id, status: .status, conclusion: .conclusion,
      headSha: .head_sha, headBranch: .head_branch, name: .name,
      displayTitle: .display_title, url: .html_url,
      createdAt: .created_at, updatedAt: .updated_at, event: .event,
      number: .run_number, attempt: .run_attempt,
      workflowDatabaseId: .workflow_id
    };
    if type == "array" then map(m) else m end'
}

# ── run view ─────────────────────────────────────────────────────────────────
gshim_cmd_run_view() {
  gshim_prw_parse "--log:b:log --log-failed:b:logfailed"
  local id="${GSHIM_PRW[pos]:-}"
  # No --json and no log flag means gh renders a human summary this shim does
  # not reproduce, so the real binary takes the call.
  if [ -z "$GSHIM_FIELDS" ] && [ -z "${GSHIM_PRW[log]:-}" ] && [ -z "${GSHIM_PRW[logfailed]:-}" ]; then
    gshim_passthru untranslated
  fi
  case "$id" in ''|*[!0-9]*) gshim_passthru untranslated ;; esac
  gshim_slug ""
  local jobs run mapped jid jname
  if [ -n "${GSHIM_PRW[log]:-}" ] || [ -n "${GSHIM_PRW[logfailed]:-}" ]; then
    jobs=$(gshim_api "repos/$GSHIM_SLUG/actions/runs/$id/jobs?per_page=100") || exit $?
    local filter='.jobs[]'
    [ -n "${GSHIM_PRW[logfailed]:-}" ] && filter='.jobs[] | select(.conclusion == "failure")'
    while IFS=$'\t' read -r jid jname; do
      [ -n "$jid" ] || continue
      printf '=== %s ===\n' "$jname"
      gshim_api "repos/$GSHIM_SLUG/actions/jobs/$jid/logs" --allow-escape-sequences || exit $?
    done < <(printf '%s' "$jobs" | jq -r "$filter | [(.id|tostring), .name] | @tsv")
    exit 0
  fi
  gshim_fields_ok "$GSHIM_ACT_FIELDS"
  run=$(gshim_api "repos/$GSHIM_SLUG/actions/runs/$id") || exit $?
  mapped=$(gshim_act_map "$run")
  gshim_emit "$mapped"
  exit 0
}

# ── run rerun ────────────────────────────────────────────────────────────────
gshim_cmd_run_rerun() {
  gshim_prw_parse "--failed:b:failed"
  local id="${GSHIM_PRW[pos]:-}" ep=rerun
  case "$id" in ''|*[!0-9]*) gshim_passthru untranslated ;; esac
  gshim_slug ""
  [ -n "${GSHIM_PRW[failed]:-}" ] && ep=rerun-failed-jobs
  gshim_api -X POST "repos/$GSHIM_SLUG/actions/runs/$id/$ep" >/dev/null || exit $?
  exit 0
}

# ── run list ─────────────────────────────────────────────────────────────────
gshim_cmd_run_list() {
  gshim_prw_parse "--workflow:v:workflow -w:v:workflow --event:v:event -e:v:event \
--branch:v:branch -b:v:branch --status:v:status -s:v:status --user:v:user -u:v:user"
  gshim_slug ""
  gshim_fields_ok "$GSHIM_ACT_FIELDS"
  local ep q="" runs mapped k
  if [ -n "${GSHIM_PRW[workflow]:-}" ]; then
    ep="repos/$GSHIM_SLUG/actions/workflows/${GSHIM_PRW[workflow]}/runs"
  else
    ep="repos/$GSHIM_SLUG/actions/runs"
  fi
  for k in event branch status; do
    [ -n "${GSHIM_PRW[$k]:-}" ] || continue
    q="${q:+$q&}$k=${GSHIM_PRW[$k]}"
  done
  [ -n "${GSHIM_PRW[user]:-}" ] && q="${q:+$q&}actor=${GSHIM_PRW[user]}"
  [ -n "$q" ] && ep="$ep?$q"
  runs=$(gshim_paginate "$ep" "$GSHIM_LIMIT" .workflow_runs) || exit $?
  mapped=$(gshim_act_map "$runs")
  gshim_emit "$mapped"
  exit 0
}
