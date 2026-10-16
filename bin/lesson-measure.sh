#!/bin/bash
# bin/lesson-measure.sh — BH-5808 (BH-5794.3): measure and retire lessons.
# A hub lane, daily at 07:23 (cron/lanes/734-lesson-measure.cron).
#
# WHY. Wave 2 (bin/lesson-propose.sh, #5807) opens a lesson PR or issue for a
# repeat BLOCK cause, and keeps ONE ledger row per category that the next
# proposal overwrites. This lane keeps a durable row per merged lesson
# (`lessons`, worker/jobs/src/routes/lessons.js), judges it, escalates the
# lessons that do not work, removes the plan lessons a check supersedes, and
# sends a weekly digest.
#
# ONE TICK:
#   1. lane_gate_or_exit / lane_env_apply lesson-measure; LESSON_MEASURE_ENABLED=0
#      stops before any request. flock -n locks/lesson-measure.lock.
#   2. SWEEP. GET /api/ledger?kind=lesson_proposal: a `merged` row is recorded
#      (POST /api/lessons, merged_at = its detail.at); an `open` row is read
#      live, and a merged PR or an issue closed as completed is recorded with
#      the live time. Unreadable: one log line, the tick stops. This lane never
#      writes lesson_proposal rows. Then GET /api/lessons/pending, and each
#      escalation issue in `escalated_open` is read live the same way.
#   3. WEEKLY (step 6) runs here, then GET /api/lessons/pending again.
#   4. ESCALATE. Each not-working row with a stronger stage (lessons.stage_order)
#      gets ONE `ai-build` issue, titled `Lesson escalation: <category> needs a
#      <stage> [lesson:<category>]`; the title tag makes wave 2 skip the category
#      while it is open. The open issues are searched for the body marker first
#      (a hit heals a lost mark). escalation_stage is marked BEFORE the POST;
#      only a 201 with a number marks escalation_number. The strongest stage
#      (harness-bug) gets one log line and no issue.
#   5. RETIRE. Each plan-lesson row with a LATER check or harness-bug row in the
#      same category: the §10 bullets of prompts/plan-contract.md that end with
#      `(lesson-propose: <category>)` are removed by ONE REST PR (never a
#      hand-written bullet). No such bullet: marked `removed`, removal_note
#      absent, no PR. Held (no PR this tick) while an open PR is a wave 2
#      plan-contract lesson or another lesson-retire PR. A 201 with an https
#      html_url records the PR as the row's removal_number; the row is NOT
#      superseded yet. The branch carries main's sha, so a retry after a
#      close starts from the current main.
#      Before that, each row in `removing` (a removal PR recorded) is read
#      live: merged marks it `superseded`, closed without a merge clears the
#      PR (the next tick opens a new one), open waits.
#      Steps 4 and 5 share LESSON_MEASURE_MAX_PER_TICK GitHub writes.
#   6. WEEKLY, once per ISO week: job_ledger_claim lesson_measure <YYYY-Www>.
#      POST /api/lessons/measure (truncated: the claim is released as failed),
#      POST /api/lessons/retention (a count only; lessons rows are kept),
#      GET /api/lessons/digest, then bin/archie-tg-send.sh
#      lesson-digest:<YYYY-Www> <text>. rc 0: done. rc 2 (not configured): done,
#      sent=false. Else: failed, the next tick retries (archie-tg-send's own
#      ledger stops a double send).
#   7. One line in logs/lesson-measure.log for a tick that did work:
#      <ts> recorded=<n> escalated=<n> removal_prs=<n> retired=<n> reopened=<n> held=<n> judged=<n> working=<n> not_working=<n> digest=sent|skipped|failed|none
#      removal_prs = removal PRs opened; retired = removal PRs read merged;
#      reopened = removal PRs read closed without a merge.
#
# OFF: LESSON_MEASURE_ENABLED=0, flags/lane-off-lesson-measure, or
# bin/harness-ctl.sh off lesson-measure. Registry: catalog/lanes.d/lesson-measure.json.
# Note: docs/notes/2026-10-16-BH-5808-lesson-measure.md.
#
# gh-rest: no-graphql
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
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest-var.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest-list.sh" 2>/dev/null || true
  . "$SELF/lib/pr-trailers.sh" 2>/dev/null || true
}
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" 2>/dev/null || exit 0
command -v _jobs_req >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0

LOG="$H/logs/lesson-measure.log"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
# knob <name> <value> <default> <lo> <hi>: an integer in range, else one warn line and the default.
knob() {
  if [[ $2 =~ ^[0-9]+$ ]] && [ "$2" -ge "$4" ] && [ "$2" -le "$5" ]; then printf '%s' "$2"; return; fi
  log "warn: $1=$2 is not an integer in $4..$5; using the default $3"
  printf '%s' "$3"
}
dash() { sed 's/—/-/g'; }
# rest <out-file> <method> <path> [args...]: one gh_rest call into a file (never
# a $( ), so GH_REST_STATUS survives); RC is its rc.
rest() { RC=0; gh_rest "$2" "$3" "${@:4}" > "$1" 2>/dev/null || RC=$?; }
why() { echo "http ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}"; }

REPO="$HARNESS_REPO"
BASE=main
PLAN_FILE=prompts/plan-contract.md

# lm_live <kind> <number>: the live state of a lesson PR or issue (the
# lp_live rule of bin/lesson-propose.sh). Sets LIVE_STATE (open|merged|closed),
# LIVE_AT and LIVE_TITLE. rc 1 when it cannot be read. A PR merged, or an issue
# closed as completed, is `merged`.
lm_live() {
  local f="$TMPD/live.json"
  LIVE_STATE=""; LIVE_AT=""; LIVE_TITLE=""
  [[ "$2" =~ ^[0-9]+$ ]] || return 1
  if [ "$1" = pr ]; then rest "$f" GET "repos/$REPO/pulls/$2"; else rest "$f" GET "repos/$REPO/issues/$2"; fi
  if [ "$RC" = 44 ]; then LIVE_STATE=closed; return 0; fi
  [ "$RC" = 0 ] || return 1
  LIVE_STATE=$(jq -r --arg k "$1" '
    if .state == "open" then "open"
    elif $k == "pr" and .merged_at != null then "merged"
    elif $k == "issue" and .state_reason == "completed" then "merged"
    elif .state == "closed" then "closed" else "" end' "$f" 2>/dev/null)
  LIVE_AT=$(jq -r 'if .merged_at != null then .merged_at else (.closed_at // empty) end' "$f" 2>/dev/null)
  LIVE_TITLE=$(jq -r '.title // ""' "$f" 2>/dev/null)
  [ -n "$LIVE_STATE" ] || return 1
  [ -n "$LIVE_AT" ] || LIVE_AT="$NOW_ISO"
}

# lm_record <category> <change_type> <kind> <number> <url> <title> <merged_at> <source>:
# POST /api/lessons. RECORDED counts only a 201.
lm_record() {
  local body resp rc
  case "$2" in plan-lesson|builder-rule|check|harness-bug) ;; *) log "$1: #$4 has no known change type ($2); not recorded"; return 1 ;; esac
  body=$(jq -nc --arg c "$1" --arg ct "$2" --arg k "$3" --arg r "$REPO" --argjson n "$4" --arg u "$5" --arg t "$6" --arg m "$7" --arg s "$8" \
    '{category:$c, change_type:$ct, kind:$k, repo:$r, number:$n, merged_at:$m, source:$s}
     + (if ($u | startswith("https://")) then {url:$u} else {} end)
     + (if $t != "" then {title:$t[0:300]} else {} end)') || return 1
  resp=$(_jobs_req POST /api/lessons "$body"); rc=$?
  if [ "$rc" != 0 ]; then log "$1: #$4 could not be recorded (http ${JOBS_HTTP:-none})"; return 1; fi
  if [ "$(jq -r '.created' <<<"$resp" 2>/dev/null)" = true ]; then
    RECORDED=$((RECORDED + 1)); log "$1: recorded the merged $2 #$4 as lesson $(jq -r '.id' <<<"$resp")"
  fi
}

# lm_sweep: record every merged lesson of the lesson_proposal ledger. rc 1
# when the ledger cannot be read (the tick stops).
lm_sweep() {
  local resp rc cat st det kind num at
  resp=$(_jobs_req GET "/api/ledger?kind=lesson_proposal&limit=1000"); rc=$?
  if [ "$rc" != 0 ] || ! jq -e '(.ledgers | type) == "array"' <<<"$resp" >/dev/null 2>&1; then
    log "the lesson_proposal ledger could not be read (rc=$rc http ${JOBS_HTTP:-none}); the tick stops, nothing recorded"
    return 1
  fi
  while IFS=$'\t' read -r cat st det; do
    [ -n "$cat" ] || continue
    num=$(jq -r '.number // "" | tostring' <<<"$det")
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    kind=$(jq -r '.kind // "pr"' <<<"$det")
    case "$st" in
      merged) at=$(jq -r '.at // ""' <<<"$det") ;;
      open)
        if ! lm_live "$kind" "$num"; then log "$cat: the open lesson #$num could not be read ($(why)); not recorded this tick"; continue; fi
        [ "$LIVE_STATE" = merged ] || continue
        at="$LIVE_AT" ;;
      *) continue ;;
    esac
    lm_record "$cat" "$(jq -r '.target // ""' <<<"$det")" "$kind" "$num" "$(jq -r '.url // ""' <<<"$det")" \
      "$(jq -r '.draft.title // ""' <<<"$det")" "$at" proposal
  done < <(jq -r '.ledgers[] | [.key, .status, ((.detail // "") | fromjson? // {} | tojson)] | @tsv' <<<"$resp" 2>/dev/null)
  return 0
}

# lm_pending: GET /api/lessons/pending into $TMPD/pending.json. rc 1 unreadable.
lm_pending() {
  local resp rc
  resp=$(_jobs_req GET /api/lessons/pending); rc=$?
  if [ "$rc" != 0 ] || ! jq -e '(.escalate | type) == "array" and (.retire | type) == "array" and (.removing | type) == "array" and (.escalated_open | type) == "array"' <<<"$resp" >/dev/null 2>&1; then
    log "GET /api/lessons/pending could not be read (rc=$rc http ${JOBS_HTTP:-none}); no escalation or removal this tick"
    return 1
  fi
  printf '%s' "$resp" > "$TMPD/pending.json"
}

# lm_sweep_escalations: an escalation issue closed as completed is a lesson.
lm_sweep_escalations() {
  local id cat st num url
  while IFS=$'\t' read -r id cat st num url; do
    if ! lm_live issue "$num"; then log "$cat: the escalation issue #$num of lesson $id could not be read ($(why))"; continue; fi
    [ "$LIVE_STATE" = merged ] || continue
    lm_record "$cat" "$st" issue "$num" "$url" "$LIVE_TITLE" "$LIVE_AT" escalation
  done < <(jq -r '.escalated_open[] | [.id, .category, .escalation_stage, .escalation_number, (.escalation_url // "")] | map(tostring) | @tsv' "$TMPD/pending.json")
}

# lm_mark <json>: POST /api/lessons/mark. rc of the request.
lm_mark() { _jobs_req POST /api/lessons/mark "$1" >/dev/null; }

# The open issues and PRs of REPO, each read once a tick. rc 1 when the list
# cannot be read or hit the 1000-row cap (an incomplete list is never "no hit").
ISSUES_STATE=""; PRS_STATE=""
lm_open_issues() {
  case "$ISSUES_STATE" in ok) return 0 ;; bad) return 1 ;; esac
  ISSUES_STATE=bad
  gh_rest_issue_list "$REPO" open "" 1000 > "$TMPD/open-issues.json" 2>/dev/null || { log "the open issues of $REPO could not be read ($(why)); no escalation this tick"; return 1; }
  [ "$(jq 'length' "$TMPD/open-issues.json")" -lt 1000 ] || { log "the open issues of $REPO hit the 1000-row cap; no escalation this tick"; return 1; }
  ISSUES_STATE=ok
}
lm_open_prs() {
  case "$PRS_STATE" in ok) return 0 ;; bad) return 1 ;; esac
  PRS_STATE=bad
  gh_rest_pr_list_all "$REPO" open 1000 > "$TMPD/open-prs.json" 2>/dev/null || { log "the open PRs of $REPO could not be read ($(why)); no removal this tick"; return 1; }
  [ "$(jq 'length' "$TMPD/open-prs.json")" -lt 1000 ] || { log "the open PRs of $REPO hit the 1000-row cap; no removal this tick"; return 1; }
  PRS_STATE=ok
}
# lm_marker <file> <marker-prefix>: {number, url} of the lowest-numbered open
# issue or PR whose body carries the marker.
lm_marker() {
  jq -c --arg m "$2" '[.[] | select((.body // "") | contains($m)) | {number, url: .html_url}] | sort_by(.number) | first // empty' "$1" 2>/dev/null
}

# lm_rate <blocks> <reviewed>: per 100, one decimal, or n/a.
lm_rate() { if [ "${2:-0}" -gt 0 ] 2>/dev/null; then awk -v b="$1" -v r="$2" 'BEGIN { printf "%.1f", b * 100 / r }'; else printf 'n/a'; fi; }

# lm_escalation_body <row-json> <stage>
lm_escalation_body() {
  local l="$1" s="$2" W CUT
  W=$(jq -r '.settings.window_days' "$TMPD/pending.json"); CUT=$(jq -r '.settings.min_cut_pct' "$TMPD/pending.json")
  {
    printf 'A lesson did not cut the BLOCK rate of its category by %s%% or more. bin/lesson-measure.sh files this issue to try a stronger stage.\n\n' "$CUT"
    jq -r '"Category: `\(.category)`\nLesson: \(.url // ("#" + (.number | tostring))) (\(.change_type), merged \(.merged_at[0:10]))"' <<<"$l"
    printf 'Before the merge (%s days): %s BLOCKs in %s reviewed PRs, %s per 100.\n' "$W" \
      "$(jq -r '.before_blocks // 0' <<<"$l")" "$(jq -r '.before_reviewed // 0' <<<"$l")" "$(lm_rate "$(jq -r '.before_blocks // 0' <<<"$l")" "$(jq -r '.before_reviewed // 0' <<<"$l")")"
    printf 'After the merge (to %s): %s BLOCKs in %s reviewed PRs, %s per 100.\n' "$(jq -r '(.after_end // "")[0:10]' <<<"$l")" \
      "$(jq -r '.after_blocks // 0' <<<"$l")" "$(jq -r '.after_reviewed // 0' <<<"$l")" "$(lm_rate "$(jq -r '.after_blocks // 0' <<<"$l")" "$(jq -r '.after_reviewed // 0' <<<"$l")")"
    printf 'Cut: %s%%. Needed: %s%%.\n\n' "$(jq -r '.cut_pct // "n/a" | tostring' <<<"$l")" "$CUT"
    case "$s" in
      builder-rule) printf 'Stronger stage: builder-rule. Add one rule to prompts/build-discipline.md that stops this cause in the build.\n' ;;
      check) printf 'Stronger stage: check. Add a lint or a test the harness runs that stops this cause mechanically.\n' ;;
      harness-bug) printf 'Stronger stage: harness-bug. Fix the harness code that causes these BLOCKs.\n' ;;
      *) printf 'Stronger stage: %s.\n' "$s" ;;
    esac
    if [ "$s" = check ]; then
      printf '\n#### Acceptance tests\n\n'
      jq -r '"- A diff that repeats a BLOCK of category `\(.category)` is red in the new check.\n- A diff that does not repeat it passes the check."' <<<"$l"
    fi
    jq -r --arg s "$s" '"\n<!-- lesson-measure: escalate lesson=\(.id) category=\(.category) stage=\($s) -->"' <<<"$l"
  } | dash
}

# lm_escalate: one stronger-stage issue per not-working row.
lm_escalate() {
  local l id cat ns hit num url
  while IFS= read -r l; do
    id=$(jq -r .id <<<"$l"); cat=$(jq -r .category <<<"$l"); ns=$(jq -r '.next_stage // ""' <<<"$l")
    if [ -z "$ns" ]; then
      log "$cat: lesson $id ($(jq -r .change_type <<<"$l")) is not working and has no stronger stage; nothing filed"
      continue
    fi
    lm_open_issues || return
    hit=$(lm_marker "$TMPD/open-issues.json" "<!-- lesson-measure: escalate lesson=$id ")
    if [ -n "$hit" ]; then
      lm_mark "$(jq -nc --argjson i "$id" --arg s "$ns" --argjson h "$hit" '{id:$i, escalation_stage:$s, escalation_number:$h.number}
        + (if ($h.url // "" | startswith("https://")) then {escalation_url:$h.url} else {} end)')" \
        && log "$cat: lesson $id already has the open escalation #$(jq -r .number <<<"$hit"); marked" \
        || log "$cat: lesson $id has the open escalation #$(jq -r .number <<<"$hit") but the mark failed"
      continue
    fi
    if [ "$WRITES" -ge "$MAX" ]; then log "$cat: lesson $id waits for the next tick (LESSON_MEASURE_MAX_PER_TICK=$MAX)"; continue; fi
    if ! lm_mark "$(jq -nc --argjson i "$id" --arg s "$ns" '{id:$i, escalation_stage:$s}')"; then
      log "$cat: the escalation stage of lesson $id could not be marked (http ${JOBS_HTTP:-none}); no issue filed"; continue
    fi
    WRITES=$((WRITES + 1))
    lm_escalation_body "$l" "$ns" > "$TMPD/body.md"
    jq -nc --arg t "Lesson escalation: $cat needs a $ns [lesson:$cat]" --rawfile b "$TMPD/body.md" \
      '{title:$t, body:$b, labels:["ai-build"]}' > "$TMPD/issue.in"
    rest "$TMPD/issue.out" POST "repos/$REPO/issues" --input "$TMPD/issue.in"
    num=$(jq -e '.number | numbers' "$TMPD/issue.out" 2>/dev/null) || num=""
    if [ "$RC" = 0 ] && [ "${GH_REST_STATUS:-}" = 201 ] && [ -n "$num" ]; then
      ESCALATED=$((ESCALATED + 1))
      url=$(jq -r '.html_url // ""' "$TMPD/issue.out")
      lm_mark "$(jq -nc --argjson i "$id" --argjson n "$num" --arg u "$url" '{id:$i, escalation_number:$n} + (if ($u | startswith("https://")) then {escalation_url:$u} else {} end)')" \
        || log "$cat: filed #$num for lesson $id but the mark failed; the marker search heals it next tick"
      log "$cat: lesson $id is not working; filed #$num (needs a $ns)"
    else
      log "$cat: the escalation issue of lesson $id could not be filed ($(why)); retried next tick"
    fi
  done < <(jq -c '.escalate[]' "$TMPD/pending.json")
}

# lm_drop <category> <in> <out>: plan-contract without the §10 bullets that end
# with `(lesson-propose: <category>)`. rc 3 when there is none.
lm_drop() {
  LM_SUFFIX="(lesson-propose: $1)" awk '
    BEGIN { suf = ENVIRON["LM_SUFFIX"]; n = length(suf) }
    /^## 10\./ { s = 1; print; next }
    /^## / && s { s = 0 }
    {
      line = $0; sub(/[ \t\r]+$/, "", line)
      if (s && line ~ /^- / && length(line) >= n && substr(line, length(line) - n + 1) == suf) { dropped++; next }
      print
    }
    END { if (!dropped) exit 3 }' "$2" > "$3"
}

# lm_open_removal <row-json>: the REST-only PR that removes the bullets. Sets
# DELIVER_STEP on failure, DELIVER_NUM / DELIVER_URL on a 201.
lm_open_removal() {
  local l="$1" id cat br head bsha url rc
  id=$(jq -r .id <<<"$l"); cat=$(jq -r .category <<<"$l")
  rest "$TMPD/head.json" GET "repos/$REPO/git/ref/heads/$BASE"
  if [ "$RC" != 0 ] || ! head=$(jq -er '.object.sha' "$TMPD/head.json" 2>/dev/null); then DELIVER_STEP="head ($(why))"; return 1; fi
  # main's sha in the name: a retry after a close never reuses an old branch.
  br="harness/lesson-retire-$cat-$id-${head:0:8}"
  jq -nc --arg r "refs/heads/$br" --arg s "$head" '{ref:$r, sha:$s}' > "$TMPD/ref.in"
  rest "$TMPD/ref.out" POST "repos/$REPO/git/refs" --input "$TMPD/ref.in"
  if [ "$RC" != 0 ]; then
    # gh_rest drops non-2xx bodies, so "already exists" is proven by reading the ref back.
    rc="${GH_REST_STATUS:-000}"
    [ "$rc" = 422 ] && rest "$TMPD/ref2.json" GET "repos/$REPO/git/ref/heads/$br"
    if [ "$rc" != 422 ] || [ "$RC" != 0 ]; then DELIVER_STEP="ref (http $rc)"; return 1; fi
  fi
  rest "$TMPD/blob.json" GET "repos/$REPO/contents/$PLAN_FILE?ref=$br"
  if [ "$RC" != 0 ] || ! bsha=$(jq -er '.sha' "$TMPD/blob.json" 2>/dev/null); then DELIVER_STEP="contents-branch ($(why))"; return 1; fi
  jq -nc --arg m "lesson-measure: remove the $cat plan lesson (superseded)" --arg c "$(base64 -w0 < "$TMPD/new.md")" --arg s "$bsha" --arg b "$br" \
    '{message:$m, content:$c, sha:$s, branch:$b}' > "$TMPD/put.in"
  rest "$TMPD/put.out" PUT "repos/$REPO/contents/$PLAN_FILE" --input "$TMPD/put.in"
  if [ "$RC" != 0 ]; then DELIVER_STEP="contents ($(why))"; return 1; fi
  # >>> pr trailers (BH-3987)
  # The lane opened this PR, and no ticket owns its branch.
  {
    jq -r '"The plan-contract §10 lesson of category `\(.category)` is superseded by a later \(.superseded_by_type): \(.superseded_by_url // ("lesson " + (.superseded_by | tostring))). bin/lesson-measure.sh removes it, so the prompt does not grow forever.\n\nLesson: \(.url // ("#" + (.number | tostring))) (merged \(.merged_at[0:10]))\n\nRemoved lines:\n"' <<<"$l"
    diff "$TMPD/orig.md" "$TMPD/new.md" | sed -n 's/^< /- `/p' | sed 's/$/`/'
    jq -r '"\n<!-- lesson-measure: retire lesson=\(.id) category=\(.category) -->\n\nOpened by bin/lesson-measure.sh. It never merges."' <<<"$l"
  } | dash > "$TMPD/body.md"
  command -v pr_trailers_apply >/dev/null 2>&1 && { pr_trailers_apply "$TMPD/body.md" lane:lesson-measure none \
    || echo "lesson-measure: pr trailers: could not write $TMPD/body.md, PR opened without trailers" >&2; }
  jq -nc --arg t "Lesson retired: $cat superseded by a $(jq -r .superseded_by_type <<<"$l") [lesson-retire:$cat]" --arg h "$br" --arg b "$BASE" --rawfile body "$TMPD/body.md" \
    '{title:$t, head:$h, base:$b, body:$body}' > "$TMPD/pr.in"
  rest "$TMPD/pr.out" POST "repos/$REPO/pulls" --input "$TMPD/pr.in"
  # <<< pr trailers
  if [ "$RC" = 0 ] && [ "${GH_REST_STATUS:-}" = 201 ] \
     && url=$(jq -er '.html_url | select(type == "string" and startswith("https://"))' "$TMPD/pr.out" 2>/dev/null); then
    DELIVER_NUM=$(jq -r '.number // empty' "$TMPD/pr.out"); DELIVER_URL="$url"; return 0
  fi
  DELIVER_STEP="pulls ($(why)$( [ "$RC" = 0 ] && echo ' no html_url'))"; return 1
}

# lm_removing: read each recorded removal PR live. Merged: the row is
# `superseded` (the bullet left main). Closed without a merge: the PR is
# cleared, so the row is in `retire` again and the next tick opens a new PR.
# Open or unreadable: nothing changes.
lm_removing() {
  local id cat num
  while IFS=$'\t' read -r id cat num; do
    if ! lm_live pr "$num"; then log "$cat: the removal PR #$num of lesson $id could not be read ($(why)); read again next tick"; continue; fi
    case "$LIVE_STATE" in
      merged)
        if lm_mark "$(jq -nc --argjson i "$id" '{id:$i, status:"superseded"}')"; then
          RETIRED=$((RETIRED + 1)); log "$cat: the removal PR #$num of lesson $id merged; marked superseded"
        else log "$cat: the removal PR #$num of lesson $id merged but the superseded mark failed; read again next tick"; fi ;;
      closed)
        if lm_mark "$(jq -nc --argjson i "$id" '{id:$i, clear_removal:true}')"; then
          REOPENED=$((REOPENED + 1)); log "$cat: the removal PR #$num of lesson $id closed without a merge; cleared, a new PR is opened next tick"
        else log "$cat: the removal PR #$num of lesson $id closed without a merge but the clear failed; read again next tick"; fi ;;
    esac
  done < <(jq -r '.removing[] | [.id, .category, .removal_number] | map(tostring) | @tsv' "$TMPD/pending.json")
}

# lm_retire: one removal PR per superseded plan lesson.
lm_retire() {
  local l id cat hit hold rc opened=0 todo="$TMPD/retire.todo"
  : > "$todo"
  [ "$(jq '.retire | length' "$TMPD/pending.json")" -gt 0 ] || return 0
  lm_open_prs || return
  # A removal PR already open for a row (a lost mark) is marked first.
  while IFS= read -r l; do
    id=$(jq -r .id <<<"$l"); cat=$(jq -r .category <<<"$l")
    hit=$(lm_marker "$TMPD/open-prs.json" "<!-- lesson-measure: retire lesson=$id ")
    if [ -n "$hit" ]; then
      lm_mark "$(jq -nc --argjson i "$id" --argjson h "$hit" --argjson s "$(jq .superseded_by <<<"$l")" '{id:$i, removal_number:$h.number, superseded_by:$s}
        + (if ($h.url // "" | startswith("https://")) then {removal_url:$h.url} else {} end)')" \
        && log "$cat: lesson $id already has the open removal PR #$(jq -r .number <<<"$hit"); marked" \
        || log "$cat: lesson $id has the open removal PR #$(jq -r .number <<<"$hit") but the mark failed"
      continue
    fi
    printf '%s\n' "$l" >> "$todo"
  done < <(jq -c '.retire[]' "$TMPD/pending.json")
  [ -s "$todo" ] || return 0
  # Two PRs on one prompt file conflict: hold while a wave 2 plan-contract
  # lesson PR or another removal PR is open.
  hold=$(jq -r --arg p "Prompt file: \`$PLAN_FILE\`" '[.[] | select(((.body // "") | contains($p)) or ((.title // "") | contains("[lesson-retire:")))] | sort_by(.number) | first | .number // empty' "$TMPD/open-prs.json")
  if [ -n "$hold" ]; then
    HELD=$((HELD + 1)); log "held: the open PR #$hold edits $PLAN_FILE; no removal PR this tick"; return 0
  fi
  rest "$TMPD/contents.json" GET "repos/$REPO/contents/$PLAN_FILE?ref=$BASE"
  if [ "$RC" != 0 ] || ! jq -er '.content' "$TMPD/contents.json" 2>/dev/null | base64 -d > "$TMPD/orig.md" 2>/dev/null || [ ! -s "$TMPD/orig.md" ]; then
    log "$PLAN_FILE could not be read from $BASE ($(why)); no removal this tick"; return 0
  fi
  while IFS= read -r l; do
    id=$(jq -r .id <<<"$l"); cat=$(jq -r .category <<<"$l")
    rc=0; lm_drop "$cat" "$TMPD/orig.md" "$TMPD/new.md" || rc=$?
    if [ "$rc" != 0 ] && [ "$rc" != 3 ]; then log "$cat: the §10 bullets of lesson $id could not be read (awk rc $rc); skipped"; continue; fi
    if [ "$rc" = 3 ]; then
      lm_mark "$(jq -nc --argjson i "$id" --argjson s "$(jq .superseded_by <<<"$l")" '{id:$i, status:"removed", removal_note:"absent", superseded_by:$s}')" \
        && log "$cat: lesson $id is superseded and §10 has no (lesson-propose: $cat) bullet; marked removed, no PR" \
        || log "$cat: lesson $id is superseded but the removed mark failed"
      continue
    fi
    if [ "$opened" = 1 ]; then HELD=$((HELD + 1)); log "$cat: lesson $id held; a removal PR was opened on $PLAN_FILE this tick"; continue; fi
    if [ "$WRITES" -ge "$MAX" ]; then log "$cat: lesson $id waits for the next tick (LESSON_MEASURE_MAX_PER_TICK=$MAX)"; continue; fi
    WRITES=$((WRITES + 1))
    DELIVER_STEP=""; DELIVER_NUM=""; DELIVER_URL=""
    if lm_open_removal "$l"; then
      opened=1; REMOVAL_PRS=$((REMOVAL_PRS + 1))
      # Not superseded yet: lm_removing marks that when this PR merges.
      lm_mark "$(jq -nc --argjson i "$id" --argjson n "${DELIVER_NUM:-0}" --arg u "$DELIVER_URL" --argjson s "$(jq .superseded_by <<<"$l")" \
        '{id:$i, removal_url:$u, superseded_by:$s} + (if $n > 0 then {removal_number:$n} else {} end)')" \
        || log "$cat: opened $DELIVER_URL for lesson $id but the mark failed; the marker search heals it next tick"
      log "$cat: lesson $id is superseded by a later stage; opened the removal PR $DELIVER_URL"
    else
      log "$cat: the removal PR of lesson $id could not be opened at $DELIVER_STEP; retried next tick"
    fi
  done < "$todo"
}

# lm_digest_text <digest-json> <week>: the operator text, STE, at most 3500 chars.
lm_digest_text() {
  jq -r --arg w "$2" '
    def r: if . == null then "n/a" else tostring end;
    ["Lesson digest \($w): \(.window.since[0:10]) to \(.as_of[0:10]) (\(.window.days) days).",
     "BLOCK rate: \(.overall.rate | r) per 100 reviewed PRs (\(.overall.blocks) BLOCKs in \(.overall.reviewed) PRs).",
     "Lessons: \(.lessons.added) added in the window. \(.lessons.measuring) measuring, \(.lessons.working) working, \(.lessons.not_working) not working, \(.lessons.inconclusive) inconclusive, \(.lessons.retired) retired, \(.lessons.removing // 0) with a removal PR open.",
     "",
     "Per category (BLOCKs, rate per 100 reviewed PRs):"]
    + (if (.categories | length) == 0 then ["- none"] else [.categories[] | "- \(.name) (\(.id)): \(.blocks), \(.rate | r)" + (if .lesson_status then ", lesson \(.lesson_status)" else "" end)] end)
    + ["", "Top uncovered causes (no lesson measuring or working):"]
    + (if (.uncovered | length) == 0 then ["- none"] else [.uncovered[] | "- \(.name) (\(.id)): \(.blocks) BLOCKs"] end)
    + ["", "Other: \(.other_blocks) BLOCKs with no category."]
    | join("\n")' <<<"$1" 2>/dev/null | dash | head -c 3500
}

# lm_weekly: the measurement, the retention audit and the digest, once per ISO week.
lm_weekly() {
  local W rc m ret dg text det judged working notw inconc trc
  [ -n "$NOW_ISO" ] || return 0
  W=$(date -u -d "$NOW_ISO" +%G-W%V) || return 0
  job_ledger_claim lesson_measure "$W" running 3600 done >/dev/null; rc=$?
  case "$rc" in
    0) ;;
    3) return 0 ;;
    *) log "the weekly claim lesson_measure/$W failed (rc=$rc); no measurement this tick"; return 0 ;;
  esac
  m=$(_jobs_req POST /api/lessons/measure '{}'); rc=$?
  if [ "$rc" != 0 ] || ! jq -e '(.judged | type) == "array"' <<<"$m" >/dev/null 2>&1; then
    log "POST /api/lessons/measure failed (http ${JOBS_HTTP:-none}); the week $W is retried next tick"
    job_ledger_put lesson_measure "$W" failed '{"error":"measure unreadable"}' >/dev/null || log "the failed status of $W could not be written"
    DIGEST=failed; return 0
  fi
  if [ "$(jq -r '.truncated' <<<"$m")" = true ]; then
    log "POST /api/lessons/measure read a truncated window; nothing judged, the week $W is retried next tick"
    job_ledger_put lesson_measure "$W" failed '{"error":"measure truncated"}' >/dev/null || log "the failed status of $W could not be written"
    DIGEST=failed; return 0
  fi
  judged=$(jq '.judged | length' <<<"$m"); working=$(jq '[.judged[] | select(.status == "working")] | length' <<<"$m")
  notw=$(jq '[.judged[] | select(.status == "not-working")] | length' <<<"$m"); inconc=$(jq '[.judged[] | select(.status == "inconclusive")] | length' <<<"$m")
  JUDGED=$judged; WORKING=$working; NOT_WORKING=$notw
  ret=$(_jobs_req POST /api/lessons/retention '{}') || ret='{"error":"retention unreadable"}'
  jq -e . <<<"$ret" >/dev/null 2>&1 || ret='{"error":"retention unreadable"}'
  dg=$(_jobs_req GET /api/lessons/digest); rc=$?
  if [ "$rc" != 0 ] || ! jq -e '(.categories | type) == "array" and (.overall | type) == "object"' <<<"$dg" >/dev/null 2>&1; then
    log "GET /api/lessons/digest failed (http ${JOBS_HTTP:-none}); the week $W is retried next tick"
    job_ledger_put lesson_measure "$W" failed '{"error":"digest unreadable"}' >/dev/null || log "the failed status of $W could not be written"
    DIGEST=failed; return 0
  fi
  text=$(lm_digest_text "$dg" "$W")
  trc=0
  "$H/bin/archie-tg-send.sh" "lesson-digest:$W" "$text" >/dev/null 2>&1 || trc=$?
  det=$(jq -nc --argjson j "$judged" --argjson w "$working" --argjson n "$notw" --argjson i "$inconc" --argjson r "$ret" --argjson rc "$trc" \
    '{judged:$j, working:$w, not_working:$n, inconclusive:$i,
      retention:(if $r.error then {error:$r.error} else {eligible:$r.eligible, cutoff:$r.cutoff} end),
      digest:{sent:($rc == 0), rc:$rc}}')
  case "$trc" in
    0) DIGEST=sent; job_ledger_put lesson_measure "$W" done "$det" >/dev/null || log "the digest of $W was sent but the done status could not be written" ;;
    2) DIGEST=skipped; log "the digest of $W was not sent: archie-tg-send.sh has no token or no target (rc 2)"
       job_ledger_put lesson_measure "$W" done "$det" >/dev/null || log "the done status of $W could not be written" ;;
    *) DIGEST=failed; log "the digest of $W could not be sent (archie-tg-send.sh rc $trc); retried next tick"
       job_ledger_put lesson_measure "$W" failed "$det" >/dev/null || log "the failed status of $W could not be written" ;;
  esac
}

tick() {
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lesson-measure
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lesson-measure
  case "${LESSON_MEASURE_ENABLED:-1}" in
    0) exit 0 ;;
    1) ;;
    *) log "warn: LESSON_MEASURE_ENABLED=${LESSON_MEASURE_ENABLED} is not 0 or 1; using the default 1" ;;
  esac
  exec 9>"$H/locks/lesson-measure.lock" || exit 0
  flock -n 9 || exit 0
  mkdir -p "$H/state/lesson-measure" 2>/dev/null
  TMPD=$(mktemp -d "$H/state/lesson-measure/tick.XXXXXX") || exit 0
  # shellcheck disable=SC2064
  trap "case '$TMPD' in '$H/state/lesson-measure/'?*) rm -rf '$TMPD' ;; esac" EXIT

  MAX=$(knob LESSON_MEASURE_MAX_PER_TICK "${LESSON_MEASURE_MAX_PER_TICK:-3}" 3 1 20)
  NOW_ISO="${LESSON_MEASURE_NOW:-}"
  if [ -n "$NOW_ISO" ] && ! date -u -d "$NOW_ISO" +%s >/dev/null 2>&1; then
    log "warn: LESSON_MEASURE_NOW=$NOW_ISO is not a time; using the clock"; NOW_ISO=""
  fi
  [ -n "$NOW_ISO" ] || NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  RECORDED=0; ESCALATED=0; REMOVAL_PRS=0; RETIRED=0; REOPENED=0; HELD=0; WRITES=0; JUDGED=0; WORKING=0; NOT_WORKING=0; DIGEST=none

  lm_sweep || exit 0
  lm_pending && lm_sweep_escalations
  # The weekly judgement runs before the escalations, so a lesson judged not
  # working this tick gets its stronger stage this tick too.
  lm_weekly
  if lm_pending; then
    lm_escalate
    lm_removing
    lm_retire
  fi
  if [ "$RECORDED$ESCALATED$REMOVAL_PRS$RETIRED$REOPENED$HELD$JUDGED" != 0000000 ] || [ "$DIGEST" != none ]; then
    log "recorded=$RECORDED escalated=$ESCALATED removal_prs=$REMOVAL_PRS retired=$RETIRED reopened=$REOPENED held=$HELD judged=$JUDGED working=$WORKING not_working=$NOT_WORKING digest=$DIGEST"
  fi
}

case "${1:-}" in
  '') tick ;;
  *) echo "usage: lesson-measure.sh" >&2; exit 2 ;;
esac
exit 0
