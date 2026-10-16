#!/bin/bash
# shellcheck shell=bash
# module: result
# bin/lib/lead-review/result.sh — the request's claim, result and outcome
# writes: the report detail, the result post, the claim, done, failed and
# superseded. Sourced by bin/lead-review.sh through bin/lib/lead-review/load.sh,
# never run. Defines functions only. Reads the host's H and JOBS_BOX; sets
# LR_RING, LR_RING_REPORT and R.

# lr_detail <body-file> <path> <verdict> — the lead_review_report detail JSON,
#   {body,path,verdict}. The worker keeps the first 4000 UTF-16 units of a detail
#   (worker/jobs/src/routes/job-artifacts.js `.slice(0, 4000)`), and a cut there
#   is invalid JSON, so the cap is applied here on the ENCODED length in those
#   units: past it the body is the longest prefix that fits and the object says
#   truncated:true (the disk report stays the whole one).
lr_detail() {
  jq -Rsc --arg p "$2" --arg v "$3" --argjson cap 4000 '
    def u16: explode | map(if . > 65535 then 2 else 1 end) | add // 0;
    def cut($n): {body: (explode[0:$n] | implode), path: $p, verdict: $v, truncated: true};
    . as $b
    | if ({body: $b, path: $p, verdict: $v} | tojson | u16) <= $cap then {body: $b, path: $p, verdict: $v}
      else [0, ($b | explode | length)]
        | until(.[0] >= .[1]; ((.[0] + .[1] + 1) / 2 | floor) as $m
            | if ($b | cut($m) | tojson | u16) <= $cap then [$m, .[1]] else [.[0], $m - 1] end)
        | .[0] as $n | $b | cut($n)
      end' "$1"
}

post_result() { # post_result <id> <json> — rc 0 only on a 2xx
  local res
  res=$(lr_post "/$1/result" "$2" 2>&1) && return 0
  log "result post for $1 failed: $res"; return 1
}
# fail_terminal <id> <job> <sha> <detail> [model] — outcome=failed, then the job failed.
# A delivered outcome=failed is terminal, so it rings lead-land (BH-5317).
fail_terminal() {
  post_result "$1" "$(jq -nc --arg j "$2" --arg s "$3" --arg d "$4" --arg m "${5:-}" \
    '{job_id:$j,head_sha:$s,outcome:"failed",detail:$d} + (if $m == "" then {} else {reviewer_model:$m} end)')" \
    || return
  LR_RING=1
  job_update "$2" status=failed
}

# claim_req <id> <job> <key> — rc 0 claimed; rc 1 refused (logged, job failed);
#   rc 2 the worker answered 503 (BH-5151: d1Guarded's storage fault): one line,
#   the job failed once, and the caller ends the tick.
claim_req() {
  local res
  res=$(lr_post "/$1/claim" "$(jq -nc --arg j "$2" --arg b "$JOBS_BOX" '{job_id:$j,box:$b}')" 2>&1) && return 0
  case "$res" in
    *"HTTP 503")
      log "claim of $1 for $3 answered 503 ($(head -c 200 <<<"${res%HTTP 503}")); tick ended"
      job_update "$2" status=failed; return 2 ;;
  esac
  log "claim of $1 for $3 refused: $res"; job_update "$2" status=failed 'meta={"reason":"claim refused"}'; return 1
}

# finish_done <id> <job> <sha> <verdict> <report> <model> <suite_line> <key> [stored] —
# artifact (ref = the report path, detail = its body, lr_detail) -> result
# done -> job done, each only when the one before it succeeded. The fresh
# review and the BH-2202 replays all end here, so none can stamp a job done
# without a delivered result. stored=1 is the artifact replay: the row it read
# IS the artifact, and re-encoding a truncated body would drop its flag.
finish_done() {
  local detail
  if [ "${9:-}" != 1 ]; then
    detail=$(lr_detail "$5" "$5" "$4") || { log "artifact detail for $8 could not be built; job left open for the watchdog"; return; }
    # A cut detail is a prefix (BH-5915): the whole report also goes to the
    # job's transcript ledger as lead_report, fail-open, so the hub can read it.
    if jq -e '.truncated == true' <<<"$detail" >/dev/null 2>&1; then
      HARNESS="$H" JOB_ID="$2" JOB_PHASE_ID= TRANSCRIPT_SOURCE=lead_report \
        bash "$H/bin/transcript-push.sh" lead-review pipeline "" "$5" >/dev/null 2>&1 || true
      log "full report for $8 handed to transcript-push.sh as lead_report (job $2)"
    fi
    job_artifact_put lead_review_report "$5" "$detail" "$2" \
      || { log "artifact put for $8 failed; job left open for the watchdog"; lr_fail_counted "$1" "$2" "$3" "artifact put failed" open; return; }
  fi
  # LR_DONE_DETAIL (BH-7123 wave B): a short note the caller sets for this one
  # result (`golive:N`, bin/lead-review.sh), carried on the row's detail so the
  # land lane needs no artifact read to know a MERGE noted a go-live step.
  post_result "$1" "$(jq -nc --arg j "$2" --arg s "$3" --arg v "$4" --arg p "$5" --arg m "$6" --arg d "${LR_DONE_DETAIL:-}" \
    '{job_id:$j,head_sha:$s,outcome:"done",verdict:$v,report_ref:$p,reviewer_model:$m} + (if $d == "" then {} else {detail:$d} end)')" \
    || { log "$8 reviewed ($4) but the result post failed; job left open for the watchdog"; lr_fail_counted "$1" "$2" "$3" "result post failed" open; return; }
  LR_RING=1; LR_RING_REPORT="$5"
  job_update "$2" status=done; log "done $8: VERDICT $4 ($7)"; R="done"
}

# supersede_dead <request-json> <project> <why> — job, claim, outcome=superseded,
#   job done. No model call.
supersede_dead() {
  local r="$1" id pr sha key job rc
  id=$(jq -r '.id' <<<"$r"); pr=$(jq -r '.pr' <<<"$r"); sha=$(jq -r '.head_sha' <<<"$r"); key="lr-$pr-${sha:0:12}"
  R=skipped
  job=$(job_open "$2" "$key" lead_review review lead-review); rc=$?
  [ "$rc" -eq 9 ] && { log "skip $key: $job"; return; }
  [ "$rc" -eq 0 ] || { log "job_open for $key failed (worker unusable); tick ended"; R=stop; return; }
  claim_req "$id" "$job" "$key"; rc=$?
  [ "$rc" -eq 2 ] && { R=stop; return; }
  [ "$rc" -eq 0 ] || return
  post_result "$id" "$(jq -nc --arg j "$job" --arg s "$sha" --arg d "$3" '{job_id:$j,head_sha:$s,outcome:"superseded",detail:$d}')" \
    || { log "superseded $key not recorded; job left open for the watchdog"; R=failed; return; }
  job_update "$job" status=done; log "superseded $key: $3"; R=superseded
}
