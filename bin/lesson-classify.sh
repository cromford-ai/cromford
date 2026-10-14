#!/bin/bash
# bin/lesson-classify.sh — BH-5806 (BH-5794.1): classify every BLOCK. A hub
# lane, hourly at minute 23 (cron/lanes/727-lesson-classify.cron).
#
# WHY. the operator (2026-10-09): "after each Block we learn to see if we need to change
# something in the plan or build process to avoid that block in the future".
# The first step is to know why each BLOCK happened. This lane reads each BLOCK
# verdict once, splits it into its findings, and one cheap model call names
# each finding's category from the block_categories rows. Wave 2 (#5807) reads
# block_findings to propose fixes; wave 3 (#5808) measures them.
#
# ONE TICK:
#   1. lane_gate_or_exit / lane_env_apply lesson-classify; LESSON_CLASSIFY_ENABLED=0
#      stops before any request. flock -n locks/lesson-classify.lock.
#   2. GET /api/block-classify/pending?limit=LESSON_CLASSIFY_MAX_PER_TICK: the
#      BLOCK verdicts in the window (settings lesson_classify.since_days) with
#      no ok/empty run and attempts under lesson_classify.max_attempts. None:
#      exit, no log line.
#   3. The model (model_routes role lesson.classify, through lane_role_model)
#      and the categories (GET /api/block-categories), ONCE. Either missing:
#      one log line, nothing claimed, nothing called.
#   4. Per verdict: POST /api/block-classify/claim BEFORE anything is paid.
#      That is the dedup (#5794): the worker refuses a verdict whose run is ok
#      or empty, or at the attempt cap (409, skipped here).
#   5. The text: a `lead-job:<job>` token in the verdict note -> that job's
#      lead_review_report artifact; otherwise the note itself (a builder or
#      human BLOCK), less its `key:value` tokens. The findings are the
#      `- [BLOCK]` items of a report (a NOTE is not one), or the whole note.
#      The files of each finding are read off its text here, never by the
#      model. No text at all: settle `empty` with no call. A report the worker
#      cut at its 4000-unit artifact cap (`truncated: true`) is read whole from
#      the hub's copy, the job's newest `lead_report` transcript (lc_full_report).
#      No usable copy: parked. A copy that cannot be read now: failed with a
#      refund, not parked, so the next tick retries.
#   6. ONE bin/agent-call.sh call, stage lesson-classify, role lesson.classify,
#      fingerprint lesson-classify:<verdict id>. rc 74-79 = the call was
#      refused before the vendor (nothing billed): settle failed with refund.
#      Any other non-zero rc: failed (the attempt counts).
#   7. The answer is one JSON line {"findings":[{n, category, confidence, cause,
#      infra_false}]}. A blank answer or an empty list: settle `empty`
#      (terminal, never retried). Unparseable: failed. Otherwise settle `ok`
#      with every finding; a finding the answer left out is `other`.
#   8. One line in logs/lesson-classify.log for a tick that had work:
#      <ts> verdicts=<n> classified=<n> empty=<n> failed=<n> skipped=<n> calls=<n>
#
# ONE-SHOT: `bin/lesson-classify.sh --requeue-truncated` re-opens the verdicts
# parked for the artifact cap (requeue_truncated). Cron passes no argument.
#
# OFF: LESSON_CLASSIFY_ENABLED=0, flags/lane-off-lesson-classify, or
# bin/harness-ctl.sh off lesson-classify. Registry: catalog/lanes.d/lesson-classify.json.
# Note: docs/notes/2026-10-10-BH-5806-classify-blocks.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/lane-model.sh" 2>/dev/null || true
  . "$SELF/lib/untrusted-input.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/ticket-branch.sh" 2>/dev/null || true
}
command -v _jobs_req >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0

LOG="$H/logs/lesson-classify.log"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
# knob <name> <value> <default> <lo> <hi>: an integer in range, else one warn line and the default.
knob() {
  if [[ $2 =~ ^[0-9]+$ ]] && [ "$2" -ge "$4" ] && [ "$2" -le "$5" ]; then printf '%s' "$2"; return; fi
  log "warn: $1=$2 is not an integer in $4..$5; using the default $3"
  printf '%s' "$3"
}

# lc_findings <text-file> <out-dir>: one file per finding, <out-dir>/<n>.txt.
# Prints the count. A report's findings are its `- [BLOCK]` items (with their
# indented continuation lines); a text with none is one finding when it is not
# a report at all (no `- [` item and no heading).
lc_findings() {
  local src="$1" dir="$2"
  awk -v d="$dir" '
    function flush() { if (cur != "") { n++; f = d "/" n ".txt"; printf "%s\n", cur > f; close(f) }; cur = "" }
    /^- \[BLOCK[^]]*\]/ { flush(); cur = $0; next }
    cur != "" && /^[ \t]+[^ \t]/ { sub(/^[ \t]+/, ""); cur = cur " " $0; next }
    { flush() }
    END { flush(); print n + 0 }' "$src"
}
# lc_rmdir <dir>: removes one verdict's scratch dir, and only a dir under
# state/lesson-classify/ (the prefix guard on every recursive rm).
lc_rmdir() {
  case "$1" in "$H/state/lesson-classify/"?*) rm -rf "$1" ;; esac
}
# lc_files <finding-file>: the repo paths the finding names, in order, JSON.
lc_files() {
  grep -oE '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+\.[A-Za-z0-9]+' "$1" 2>/dev/null | awk '!seen[$0]++' | head -20 \
    | jq -R . | jq -sc .
}

# lc_ticket <repo> <pr>: the ticket a BLOCK is about, from its PR: the ticket
# branch (ticket/bh-123 -> BH-123, bin/lib/ticket-branch.sh), else the first
# ABC-123 token at the start of the PR title. Nothing when neither names one or
# the PR cannot be read. The report heading is lr-<pr>-<sha12> and names no
# ticket (lead review of fd7dde5e).
lc_ticket() {
  local repo="$1" pr="$2" j k
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$pr" =~ ^[0-9]+$ ]] || return 0
  # gh_rest_var, never $(gh_rest …): the status survives in this shell
  # (bin/lib/gh-rest-var.sh, tests/gh-rest-no-subshell-lint.sh).
  command -v gh_rest_var >/dev/null 2>&1 || return 0
  gh_rest_var j GET "repos/$repo/pulls/$pr" 2>/dev/null || return 0
  if command -v ticket_branch_key >/dev/null 2>&1 && k=$(ticket_branch_key "$(jq -r '.head.ref // ""' <<<"$j" 2>/dev/null)"); then
    printf '%s' "$k"; return 0
  fi
  jq -r '.title // ""' <<<"$j" 2>/dev/null | grep -oE '^[A-Z][A-Z0-9]{1,9}-[0-9]{1,7}\b' | head -1
}

# lc_park <verdict-id>: never claim this verdict again (state/lesson-classify/
# parked-<id>). For a run that would fail the same way every time: the worker
# refused its rows, or it has more findings than the worker takes.
lc_park() { : > "$H/state/lesson-classify/parked-$1"; }
# lc_full_report <job> <want-title> <out-file>: the full lead report of a job
# whose artifact the worker cut, from the hub's copy (the job's newest
# `lead_report` transcript, bin/lead-review.sh finish_done). The body is read in
# THIS shell, never in $(…), so JOBS_TRANSCRIPT_TRUNCATED survives.
#   rc 0 -> the full report is in <out-file>
#   rc 3 -> no usable copy: LC_FULL_WHY absent, tail-only or title-mismatch
#   rc 1 -> a copy could not be read now: LC_FULL_WHY unreadable
lc_full_report() {
  local job="$1" want="$2" out="$3" idx rc slot p a got
  LC_FULL_WHY=unreadable
  idx=$(JOBS_ALERT=0 _jobs_req GET "/api/jobs/$job/transcripts"); rc=$?
  case "$rc" in
    0) ;;
    2) LC_FULL_WHY=absent; return 3 ;;
    *) return 1 ;;
  esac
  # The index is phase ASC, attempt ASC: the last lead_report row is the newest.
  slot=$(jq -r '[.transcripts[]? | select(.source == "lead_report")] | last // empty | "\(.phase_id) \(.attempt)"' <<<"$idx" 2>/dev/null) || return 1
  [ -n "$slot" ] || { LC_FULL_WHY=absent; return 3; }
  read -r p a <<<"$slot"
  JOBS_ALERT=0 job_transcript_get "$job" "$p" "$a" > "$out" || return 1
  [ -s "$out" ] || return 1
  [ "${JOBS_TRANSCRIPT_TRUNCATED:-0}" = 1 ] && { LC_FULL_WHY=tail-only; return 3; }
  got=$(grep -m1 '^# Lead review ' "$out")
  [ -n "$got" ] && [ "$got" = "$want" ] || { LC_FULL_WHY=title-mismatch; return 3; }
  return 0
}

# The worker's per-verdict cap (block-findings.js MAX_FINDINGS). A report with
# more findings is refused after the call, so it is parked before it.
LC_MAX_FINDINGS=50

claim_and_classify() { # claim_and_classify <pending-row-json>
  local row="$1" vid note job text_f dir nf ticket prompt run rc ans body i resp
  vid=$(jq -r '.verdict_id' <<<"$row")
  note=$(jq -r '.note // ""' <<<"$row")
  # A parked verdict (lc_park) is never claimed or paid for again; tick drops
  # them from the pending list before it counts the tick's slots.
  if [ -e "$H/state/lesson-classify/parked-$vid" ]; then SKIPPED=$((SKIPPED + 1)); return 0; fi
  resp=$(_jobs_req POST /api/block-classify/claim "$(jq -nc --argjson v "$vid" '{verdict_id: $v}')"); rc=$?
  if [ "$rc" != 0 ]; then
    # rc 9 is the worker's 409: the run is ok, empty or at the attempt cap.
    SKIPPED=$((SKIPPED + 1))
    [ "$rc" = 9 ] || log "verdict $vid: claim failed (rc=$rc); not classified"
    return 0
  fi

  dir=$(mktemp -d "$H/state/lesson-classify/v$vid.XXXXXX") || { settle "$vid" failed '' "mktemp failed" true; return 0; }
  text_f="$dir/text"
  : > "$text_f"
  job=$(grep -oE '(^| )lead-job:[^ ]+' <<<"$note" | head -1 | sed 's/.*lead-job://')
  if [ -n "$job" ]; then
    local art arc=0
    art=$(JOBS_ALERT=0 job_artifact_detail lead_review_report "$job" 2>/dev/null) || arc=$?
    if [ "$arc" != 0 ] && [ "$arc" != 3 ]; then
      settle "$vid" failed '' "the lead report of job $job could not be read (rc=$arc)" true
      lc_rmdir "$dir"; return 0
    fi
    # No report artifact (rc 3) is not "billed and empty": the lead lane wrote
    # nothing this lane can read. Failed with a refund, parked, logged (lead
    # review of 5d9dd371); never the terminal `empty`.
    if [ "$arc" = 3 ]; then
      log "verdict $vid: job $job has no lead_review_report artifact; parked, not classified"
      lc_park "$vid"
      settle "$vid" failed '' "job $job has no lead_review_report artifact; nothing to classify" true
      FAILED=$((FAILED + 1)); lc_rmdir "$dir"; return 0
    fi
    jq -r 'if (.body | type) == "string" then .body else empty end' <<<"$art" > "$text_f" 2>/dev/null
    # Only a report of THIS repo#pr at THIS head is this verdict's, the rule
    # bin/lead-review-land.sh holds before it posts one. Anything else is
    # treated as missing.
    local want_t got_t
    want_t="($(jq -r '.repo // ""' <<<"$row")#$(jq -r '.pr // ""' <<<"$row") at $(jq -r '.head_sha // ""' <<<"$row"))"
    got_t=$(grep -m1 '^# Lead review ' "$text_f")
    if [[ "$got_t" != "# Lead review "*" $want_t" ]]; then
      log "verdict $vid: the report of job $job is not for $want_t (its title: ${got_t:-none}); parked, not classified"
      lc_park "$vid"
      settle "$vid" failed '' "the lead report of job $job is not for $want_t; not classified" true
      FAILED=$((FAILED + 1)); lc_rmdir "$dir"; return 0
    fi
    # A report over the worker's 4000-unit artifact cap arrives cut
    # (`truncated: true`, lr_detail): findings past the cut are gone and the
    # last one kept may stop mid-sentence. bin/lead-review.sh pushes the full
    # report to the job's transcripts as `lead_report`, and that copy, when it
    # is whole and has this report's title, is what gets classified. With no
    # usable copy the run is settled failed with a refund (no model call was
    # made), the verdict is parked so it is never claimed again, and the box,
    # path and request id are logged; `--requeue-truncated` re-opens it after a
    # backfill. A copy that cannot be read now is failed with a refund and not
    # parked. Never an ok from a partial report.
    if jq -e '.truncated == true' <<<"$art" >/dev/null 2>&1; then
      local frc=0 rid fp box
      lc_full_report "$job" "$got_t" "$dir/full" || frc=$?
      case "$frc" in
        0)
          cp "$dir/full" "$text_f"
          log "verdict $vid: the artifact is cut; classified from the full report on the hub (job $job, source lead_report, $(wc -c < "$text_f" | tr -d ' ')B)" ;;
        3)
          rid=$(grep -oE '(^| )lead-review:[^ ]+' <<<"$note" | head -1 | sed 's/.*lead-review://')
          fp=$(jq -r '.path // "no path"' <<<"$art" 2>/dev/null)
          box=$(JOBS_ALERT=0 _jobs_req GET "/api/jobs/$job" 2>/dev/null | jq -r '(.job // .) | (.beat_box // .machine // empty)' 2>/dev/null)
          log "verdict $vid: the lead report is truncated at the artifact cap (request ${rid:-unknown}, job $job, box ${box:-unknown}, path $fp); parked, not classified; no full copy on the hub ($LC_FULL_WHY)"
          lc_park "$vid"
          settle "$vid" failed '' "the lead report (request ${rid:-unknown}) is truncated at the worker's 4000-unit artifact cap; the full report is only on box ${box:-unknown} at $fp; not classified from a partial report; no full copy on the hub ($LC_FULL_WHY)" true
          FAILED=$((FAILED + 1)); lc_rmdir "$dir"; return 0 ;;
        *)
          log "verdict $vid: the full report of job $job could not be read ($LC_FULL_WHY); not parked, the next tick retries"
          settle "$vid" failed '' "the full report of job $job could not be read ($LC_FULL_WHY); not classified" true
          FAILED=$((FAILED + 1)); lc_rmdir "$dir"; return 0 ;;
      esac
    fi
  else
    sed -E 's/(^| )[a-z-]+:[^ ]+//g; s/^ +//; s/ +$//' <<<"$note" | grep -v '^$' > "$text_f"
  fi
  if grep -qE '^- \[BLOCK' "$text_f"; then
    nf=$(lc_findings "$text_f" "$dir")
  elif [ -s "$text_f" ] && ! grep -qE '^(#|- \[)' "$text_f"; then
    { tr '\n' ' ' < "$text_f" | sed -E 's/ +$//'; echo; } > "$dir/1.txt"; nf=1
  else
    nf=0
  fi
  if [ "$nf" = 0 ]; then
    settle "$vid" empty '' "no findings text"; EMPTY=$((EMPTY + 1))
    lc_rmdir "$dir"; return 0
  fi
  if [ "$nf" -gt "$LC_MAX_FINDINGS" ]; then
    log "verdict $vid: $nf findings, over the worker's $LC_MAX_FINDINGS; parked, no model call"
    lc_park "$vid"
    settle "$vid" failed '' "$nf findings is over the worker's cap of $LC_MAX_FINDINGS; not classified" true
    FAILED=$((FAILED + 1)); lc_rmdir "$dir"; return 0
  fi

  prompt="$dir/prompt.md"
  {
    cat <<'EOF'
You classify the findings of ONE code-review BLOCK. For each numbered finding, pick the ONE category below that names its cause. Use `other` only when no category fits.

Answer with exactly one line of JSON and nothing else:
{"findings":[{"n":1,"category":"<category id>","confidence":0.0,"cause":"<the cause in one short sentence>","infra_false":false}]}

One entry per finding, with its number. confidence is 0 to 1. infra_false is true when the BLOCK is not the PR's fault: the review tooling, CI or the environment failed, or the finding is wrong. If there is nothing to classify, answer {"findings":[]}.

CATEGORIES (id: name. description):
EOF
    printf '%s\n' "$CATS"
    echo
    echo "FINDINGS:"
    { for ((i = 1; i <= nf; i++)); do printf '%d. %s\n' "$i" "$(head -c 2000 "$dir/$i.txt" | tr -d "\n")"; done; } \
      | if command -v ui_wrap >/dev/null 2>&1; then ui_wrap fetched-page; else cat; fi
  } > "$prompt"

  run="$dir/run.txt"
  rc=0
  CALLS=$((CALLS + 1))
  AGENT_CALL_LANE=lesson-classify AGENT_CALL_ROLE=lesson.classify AGENT_CALL_FP="lesson-classify:$vid" AGENT_CALL_NO_TOOLS=1 \
    "$H/bin/agent-call.sh" lesson-classify fleet "$MODEL" "$TIMEOUT" "$run" "@$prompt" >/dev/null 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then
      settle "$vid" failed '' "agent-call refused rc=$rc (nothing billed)" true
    else
      settle "$vid" failed '' "agent-call rc=$rc"
    fi
    FAILED=$((FAILED + 1)); lc_rmdir "$dir"; return 0
  fi
  if [ -z "$(tr -d '[:space:]' < "$run" 2>/dev/null)" ]; then
    settle "$vid" empty '' "blank answer"; EMPTY=$((EMPTY + 1)); lc_rmdir "$dir"; return 0
  fi
  ans=$(grep -E '^[[:space:]]*\{' "$run" | tail -1)
  if ! jq -e '.findings | type == "array"' <<<"$ans" >/dev/null 2>&1; then
    settle "$vid" failed '' "unparseable answer"; FAILED=$((FAILED + 1)); lc_rmdir "$dir"; return 0
  fi
  if [ "$(jq '.findings | length' <<<"$ans")" = 0 ]; then
    settle "$vid" empty '' "empty findings list"; EMPTY=$((EMPTY + 1)); lc_rmdir "$dir"; return 0
  fi
  ticket=$(lc_ticket "$(jq -r '.repo // ""' <<<"$row")" "$(jq -r '.pr // ""' <<<"$row")")
  # Our findings, joined with the answer by number. The text and the files are ours.
  body=$(
    for ((i = 1; i <= nf; i++)); do
      jq -nc --argjson n "$i" --rawfile t "$dir/$i.txt" --argjson files "$(lc_files "$dir/$i.txt")" --argjson a "$ans" '
        ([$a.findings[]? | select((.n | tostring) == ($n | tostring))] | first) as $x
        | {n: $n, text: ($t | rtrimstr("\n")), files: $files,
           category: (($x.category // "other") | tostring),
           confidence: (if ($x.confidence | type) == "number" and $x.confidence >= 0 and $x.confidence <= 1 then $x.confidence else null end),
           cause: (if ($x.cause | type) == "string" then $x.cause[0:300] else null end),
           infra_false: ($x.infra_false == true)}'
    done | jq -sc --argjson v "$vid" --arg m "$MODEL" --arg tk "$ticket" \
      '{verdict_id: $v, status: "ok", model: $m, findings: .} + (if $tk == "" then {} else {ticket: $tk} end)'
  )
  if _jobs_req POST /api/block-classify/settle "$body" >/dev/null; then
    CLASSIFIED=$((CLASSIFIED + 1))
  elif [ "${JOBS_HTTP:-}" = 400 ]; then
    # The worker refused the rows themselves (over its per-verdict cap, a bad
    # field): the same answer would be refused again, so the run is failed now
    # instead of paying for the same call on the next ticks.
    log "verdict $vid: the worker refused the ok settle (http 400); settled failed and not claimed again"
    lc_park "$vid"
    settle "$vid" failed "$MODEL" "the worker refused the classified rows (http 400)"
    FAILED=$((FAILED + 1))
  else
    log "verdict $vid: settle ok failed (http ${JOBS_HTTP:-none}); the claim stays and the next tick retries"
  fi
  lc_rmdir "$dir"
}

settle() { # settle <verdict-id> <status> <model> <error> [refund]
  local b
  b=$(jq -nc --argjson v "$1" --arg s "$2" --arg m "$3" --arg e "$4" --arg r "${5:-}" \
    '{verdict_id: $v, status: $s} + (if $m == "" then {} else {model: $m} end)
     + (if $e == "" then {} else {error: $e} end) + (if $r == "true" then {refund: true} else {} end)')
  _jobs_req POST /api/block-classify/settle "$b" >/dev/null \
    || log "verdict $1: settle $2 failed (http ${JOBS_HTTP:-none}); the claim stays and the next tick retries"
}

tick() {
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lesson-classify
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lesson-classify
  case "${LESSON_CLASSIFY_ENABLED:-1}" in
    0) exit 0 ;;
    1) ;;
    *) log "warn: LESSON_CLASSIFY_ENABLED=${LESSON_CLASSIFY_ENABLED} is not 0 or 1; using the default 1" ;;
  esac
  exec 9>"$H/locks/lesson-classify.lock" || exit 0
  flock -n 9 || exit 0
  mkdir -p "$H/state/lesson-classify" 2>/dev/null

  local max resp rc n row
  max=$(knob LESSON_CLASSIFY_MAX_PER_TICK "${LESSON_CLASSIFY_MAX_PER_TICK:-5}" 5 1 50)
  TIMEOUT=$(knob LESSON_CLASSIFY_TIMEOUT_S "${LESSON_CLASSIFY_TIMEOUT_S:-120}" 120 30 600)
  CLASSIFIED=0; EMPTY=0; FAILED=0; SKIPPED=0; CALLS=0

  # The worker's widest page, then this box's parked verdicts dropped, then the
  # tick's cap: a parked verdict never takes one of the tick's slots.
  resp=$(_jobs_req GET "/api/block-classify/pending?limit=50"); rc=$?
  if [ "$rc" != 0 ] || ! jq -e '.verdicts | type == "array"' <<<"$resp" >/dev/null 2>&1; then
    log "could not read the pending BLOCK verdicts (rc=$rc); nothing classified"
    exit 0
  fi
  local parked
  parked=$(find "$H/state/lesson-classify" -maxdepth 1 -name 'parked-*' 2>/dev/null | sed 's#.*/parked-##' | jq -R 'tonumber? // empty' | jq -sc . 2>/dev/null)
  resp=$(jq -c --argjson p "${parked:-[]}" --argjson m "$max" '.verdicts |= ([.[] | select(.verdict_id as $v | $p | index($v) | not)] | .[0:$m])' <<<"$resp")
  n=$(jq '.verdicts | length' <<<"$resp")
  [ "$n" -gt 0 ] || exit 0

  if ! command -v lane_role_model >/dev/null 2>&1 || ! MODEL=$(lane_role_model lesson.classify) || [ -z "$MODEL" ]; then
    log "verdicts=$n: no lesson.classify model route; nothing claimed, no model call"
    exit 0
  fi
  local cats
  cats=$(_jobs_req GET /api/block-categories); rc=$?
  CATS=$(jq -r '.categories[]? | "\(.id): \(.name). \(.description // "")"' <<<"$cats" 2>/dev/null)
  if [ "$rc" != 0 ] || [ -z "$CATS" ]; then
    log "verdicts=$n: could not read block_categories (rc=$rc); nothing claimed, no model call"
    exit 0
  fi

  while IFS= read -r row; do
    claim_and_classify "$row"
  done < <(jq -c '.verdicts[]' <<<"$resp")
  log "verdicts=$n classified=$CLASSIFIED empty=$EMPTY failed=$FAILED skipped=$SKIPPED calls=$CALLS"
}

# requeue_truncated: the one-shot. For each state/lesson-classify/parked-<id>,
# POST /api/block-classify/reset; the worker resets only a run parked for the
# 4000-unit artifact cap (200) and refuses any other (409). The marker is
# removed only after a 200. No model call, no claim. The next tick re-offers
# the reset verdicts, and the truncated branch reads their full reports.
# Exit 0 when no reset failed, else 1. Operator step:
# docs/notes/2026-10-13-BH-5915-reclassify-truncated.md.
requeue_truncated() {
  local m vid parked=0 requeued=0 kept=0 errors=0 line
  exec 9>"$H/locks/lesson-classify.lock" || { echo "requeue-truncated: cannot open locks/lesson-classify.lock"; return 1; }
  if ! flock -n 9; then
    echo "requeue-truncated: a lesson-classify tick holds the lock; run it again"; return 1
  fi
  # The probe: a deployed route answers 400 to verdict_id 0.
  JOBS_ALERT=0 _jobs_req POST /api/block-classify/reset '{"verdict_id":0}' >/dev/null
  if [ "${JOBS_HTTP:-}" != 400 ]; then
    line="requeue-truncated: POST /api/block-classify/reset is not answering (http ${JOBS_HTTP:-none}); nothing removed"
    echo "$line"; log "$line"; return 1
  fi
  for m in "$H/state/lesson-classify"/parked-*; do
    [ -e "$m" ] || continue
    vid=${m##*/parked-}
    [[ "$vid" =~ ^[0-9]+$ ]] || continue
    parked=$((parked + 1))
    if JOBS_ALERT=0 _jobs_req POST /api/block-classify/reset "{\"verdict_id\":$vid}" >/dev/null; then
      rm -f -- "$H/state/lesson-classify/parked-$vid"; requeued=$((requeued + 1))
    else
      case "${JOBS_HTTP:-}" in
        409|404) kept=$((kept + 1)) ;;
        *) errors=$((errors + 1)); log "verdict $vid: requeue reset failed (http ${JOBS_HTTP:-none}); parked-$vid kept" ;;
      esac
    fi
  done
  line="requeue-truncated: parked=$parked requeued=$requeued kept=$kept errors=$errors"
  echo "$line"; log "$line"
  [ "$errors" = 0 ]
}

case "${1:-}" in
  --requeue-truncated) requeue_truncated; exit $? ;;
  '') tick ;;
  *) echo "usage: lesson-classify.sh [--requeue-truncated]" >&2; exit 2 ;;
esac
exit 0
