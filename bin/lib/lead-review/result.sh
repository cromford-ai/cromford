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

# lr_push_report_checked <job> <sha> <report> <key> — BH-8945: on a pool machine
#   the disk report dies with the machine, so the whole body of a cut report must
#   reach the hub before RESULT (the reaper destroys only after RESULT).
#   transcript-push.sh always exits 0, so the proof is a read-back that is byte
#   equal to the scrubbed body. Up to LEAD_REVIEW_REPORT_PUSH_ATTEMPTS tries,
#   LEAD_REVIEW_REPORT_PUSH_BACKOFF_S apart, one log line per failed try, and one
#   alert at the cap. The review stays done: the prefix artifact is stored and a
#   second model call would pay again.
lr_push_report_checked() {
  local job="$1" sha="$2" rep="$3" key="$4" n b k=0 tmp clean got pr
  # Knob rows: catalog/lanes.d/lead-review.knobs.d/LEAD_REVIEW_REPORT_PUSH_ATTEMPTS.json
  # (fallback 3) and LEAD_REVIEW_REPORT_PUSH_BACKOFF_S.json (fallback 5).
  n="${LEAD_REVIEW_REPORT_PUSH_ATTEMPTS:-3}"; [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le 10 ] || n=3
  b="${LEAD_REVIEW_REPORT_PUSH_BACKOFF_S:-5}"; [[ "$b" =~ ^[0-9]+$ ]] && [ "$b" -le 60 ] || b=5
  pr="https://github.com/${LR_RING_REPO:-?}/pull/${LR_RING_PR:-?}"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lr-push.XXXXXX") || tmp=""
  clean="$tmp/clean"; got="$tmp/got"
  if [ -z "$tmp" ] || ! bash "$H/bin/transcript-scrub.sh" < "$rep" > "$clean" 2>/dev/null || [ ! -s "$clean" ]; then
    log "full report for $key (PR $pr head ${sha:0:12}) not on the hub: the scrub refused it, no retry"
  else
    while [ "$k" -lt "$n" ]; do
      k=$((k + 1))
      HARNESS="$H" JOB_ID="$job" JOB_PHASE_ID= TRANSCRIPT_SOURCE=lead_report \
        bash "$H/bin/transcript-push.sh" lead-review pipeline "" "$rep" >/dev/null 2>&1 || true
      if job_transcript_get_source "$job" lead_report > "$got" 2>/dev/null && cmp -s "$got" "$clean"; then
        log "full report for $key stored on the hub as lead_report (job $job, attempt $k/$n)"
        rm -rf "$tmp"; return 0
      fi
      log "full report for $key (PR $pr head ${sha:0:12}) not on the hub after attempt $k/$n"
      [ "$k" -lt "$n" ] && [ "$b" -gt 0 ] && sleep "$b"
    done
  fi
  [ -n "$tmp" ] && rm -rf "$tmp"
  HARNESS="$H" "$H/bin/alert-line.sh" --id "lead-report-push-$job" \
    "LEAD REPORT NOT ON HUB: the full lead review report for $pr head ${sha:0:12} (job $job) was not stored after $k attempt(s); only the 4000-unit prefix artifact survives the pool machine; disk copy $rep" \
    >/dev/null 2>&1 || true
  return 1
}

# finish_done <id> <job> <sha> <verdict> <report> <model> <suite_line> <key> [stored] —
# artifact (ref = the report path, detail = its body, lr_detail) -> result
# done -> job done, each only when the one before it succeeded. The fresh
# review and the BH-2202 replays all end here, so none can stamp a job done
# without a delivered result. stored=1 is the artifact replay: the row it read
# IS the artifact, and re-encoding a truncated body would drop its flag.
finish_done() {
  local detail ref="$5"
  # BH-8945: a pool machine (LEAD_REVIEW_EPHEMERAL=1, set only by
  # fly/builder-runner.sh run_leadreview_job) is destroyed after its RESULT,
  # so its report_ref names the hub copy, which bin/lead-review-report.sh reads.
  [ "${LEAD_REVIEW_EPHEMERAL:-}" = 1 ] && ref="artifact:$2/lead_review_report"
  if [ "${9:-}" != 1 ]; then
    detail=$(lr_detail "$5" "$5" "$4") || { log "artifact detail for $8 could not be built; job left open for the watchdog"; return; }
    # A cut detail is a prefix (BH-5915): the whole report also goes to the
    # job's transcript ledger as lead_report, fail-open, so the hub can read it.
    if jq -e '.truncated == true' <<<"$detail" >/dev/null 2>&1; then
      if [ "${LEAD_REVIEW_EPHEMERAL:-}" = 1 ]; then
        lr_push_report_checked "$2" "$3" "$5" "$8"
      else
        HARNESS="$H" JOB_ID="$2" JOB_PHASE_ID= TRANSCRIPT_SOURCE=lead_report \
          bash "$H/bin/transcript-push.sh" lead-review pipeline "" "$5" >/dev/null 2>&1 || true
        log "full report for $8 handed to transcript-push.sh as lead_report (job $2)"
      fi
    fi
    job_artifact_put lead_review_report "$5" "$detail" "$2" \
      || { log "artifact put for $8 failed; job left open for the watchdog"; lr_fail_counted "$1" "$2" "$3" "artifact put failed" open; return; }
  fi
  # LR_DONE_DETAIL (BH-7123 wave B): a short note the caller sets for this one
  # result (`golive:N`, bin/lead-review.sh), carried on the row's detail so the
  # land lane needs no artifact read to know a MERGE noted a go-live step.
  post_result "$1" "$(jq -nc --arg j "$2" --arg s "$3" --arg v "$4" --arg p "$ref" --arg m "$6" --arg d "${LR_DONE_DETAIL:-}" \
    '{job_id:$j,head_sha:$s,outcome:"done",verdict:$v,report_ref:$p,reviewer_model:$m} + (if $d == "" then {} else {detail:$d} end)')" \
    || { log "$8 reviewed ($4) but the result post failed; job left open for the watchdog"; lr_fail_counted "$1" "$2" "$3" "result post failed" open; return; }
  LR_RING=1; LR_RING_REPORT="$5"
  lr_ticket_verdict_put "$1" "$3" "$4" "$5" "$6" "$8"
  job_update "$2" status=done; log "done $8: VERDICT $4 ($7)"; R="done"
}

# lr_ticket_verdict_put <id> <sha> <verdict> <report> <model> <key> — BH-9154
#   (Fix 3 of #9066): after the worker accepted a done result, store the word
#   under (repo, ticket key, patch fp) in lead_ticket_verdicts, for gate 52
#   (bin/lib/lead-gates.d/52-ticket-replay.sh) to replay onto another PR of the
#   same ticket. A MERGE or MERGE-WITH-NOTES is stored only from a model (not a
#   lead-replay or a none:* answer); every BLOCK is stored, so a later BLOCK on
#   the same patch stops a replay of an earlier MERGE. The ticket key comes
#   from the PR's head ref and title (review_one's pr_json), the fp from the
#   clone at REPO_DIR (patch_review_fp, bin/lib/patch-fp.sh). Fail-open: a
#   failed step logs one line and loses only a future saving. Off when
#   LEAD_TICKET_REPLAY is not 1 (catalog/lanes.d/_lib.lead-ticket-replay.json).
lr_ticket_verdict_put() {
  local sha="$2" w="$3" model="$5" tkey fp mode body pj="${pr_json:-}"
  case "$w" in
    MERGE|MERGE-WITH-NOTES) case "$model" in ""|lead-replay|none:*) return 0 ;; esac ;;
    BLOCK) ;;
    *) return 0 ;;
  esac
  ( command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply lead-ticket-replay >/dev/null 2>&1
    [ "${LEAD_TICKET_REPLAY:-1}" = 1 ] ) || return 0
  command -v patch_review_fp >/dev/null 2>&1 || . "$H/bin/lib/patch-fp.sh" 2>/dev/null \
    || { log "$6: bin/lib/patch-fp.sh not loaded; no ticket verdict stored"; return 0; }
  tkey=$(patch_ticket_key "$(jq -r '.head.ref // ""' <<<"$pj" 2>/dev/null)" "$(jq -r '.title // ""' <<<"$pj" 2>/dev/null)") || return 0
  fp=$(patch_review_fp "${REPO_DIR:-}" origin/main "$sha" 2>/dev/null) \
    || { log "$6: no patch fingerprint for ${sha:0:12}; no ticket verdict stored for $tkey"; return 0; }
  mode=full; grep -q '^- review mode: intent' "$4" 2>/dev/null && mode=intent
  body=$(jq -nc --arg r "${LR_RING_REPO:-}" --arg k "$tkey" --arg f "$fp" --arg p "${LR_RING_PR:-}" --arg s "$sha" --arg v "$w" \
    --arg m "$mode" --arg ref "$4" --arg i "$1" \
    '{repo:$r, ticket_key:$k, patch_fp:$f, pr:($p|tonumber), head_sha:$s, verdict:$v, review_mode:$m, report_ref:$ref, request_id:$i}' 2>/dev/null) \
    || { log "$6: ticket verdict body could not be built; none stored"; return 0; }
  if JOBS_ALERT=0 _jobs_req POST /api/lead-ticket-verdicts "$body" >/dev/null 2>&1; then
    log "$6: ticket verdict $w stored for $tkey (fp ${fp:3:12})"
  else
    log "$6: ticket verdict $w for $tkey not stored (POST /api/lead-ticket-verdicts failed)"
  fi
  return 0
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
