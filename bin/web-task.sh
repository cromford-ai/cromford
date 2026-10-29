#!/bin/bash
# bin/web-task.sh <ticket> <KEY> [job-id] <project> — the web-task lane
# (BH-7594, slice S1): do a READ-ONLY task in a website that has no API, for a
# GitHub-issue ticket labelled web-task, and answer with ONE comment.
#
# HOW IT IS STARTED. Never by cron. The build pipeline's web-task hook
# (bin/lib/web-task/route.sh) enqueues one lane_runs row per ticket; a Fly
# lane-run machine (fly/lane-run.Dockerfile, which bakes chromium and the
# playwright module) runs it as `bin/project-lane-run.sh web-task <project> 0
# bin/web-task.sh <ticket> <KEY> <job-id>`, which appends <project>, holds
# locks/web-task-<project>.lock and exports PL_SLUG, PL_STATE_DIR and the
# project's GitHub token. Registry: catalog/lanes.d/web-task.json.
#
# THE ORDER, and every exit before the spend spends nothing:
#   1. lane gate (lane-off-web-task, factory stop) and the lane's knobs
#   2. args: a positive ticket number, a KEY like AB-7, a path-safe project
#      (rc 2); WEB_TASK_MAX_STEPS 1..200, WEB_TASK_MAX_S 30..3600 (rc 2)
#   3. the project must be a GitHub-issue project (rc 1, one alert); the slug
#      comes from fleet.conf, else PL_SLUG (rc 1 when there is none)
#   4. read the issue and its comments (rc 75 on any read failure, and rc 75
#      when the thread is longer than WEB_TASK_THREAD_MAX_PAGES pages of 100:
#      the dedup read below must see every comment, so it fails closed)
#   5. DEDUP: a comment carrying <!-- web-task-result:<KEY> --> is the answer
#      already given: WEBTASK_SKIP, rc 0, no browser and no model. Only a
#      `done` run writes that marker.
#   6. the allow-list, settings row lane.web-task.<project>.allowed_domains
#      (a comma list of hosts; each also allows its subdomains). An outage is
#      rc 75. No row, an empty row or no valid host: ONE comment that says how
#      to set it up (marker <!-- web-task-refused:<KEY> -->, posted once), rc 0.
#      That marker never blocks a later run once the row exists.
#   7. the model: the model_routes role `web-task` (model_env_or_route). No
#      route is one lane alert and rc 1, with no call.
#   8. bin/web-task-agent.mjs with bin/lib/web-task/decide.sh as its decide
#      command: every model call goes through bin/agent-call.sh (llm-gate:
#      LLM_LANE_ENABLED, LLM_RUNNER_ALLOWED, LLM_USD_CAP_DAY; one priced cost
#      row per call), under WEB_TASK_MAX_STEPS and WEB_TASK_MAX_S
#   9. the screenshots (the last 5) go to the branch harness-shots/<key>-web-task
#      (bin/lib/web-task/shots.sh); each URL and the result are job_artifacts
#      rows of <job-id> (GET /api/artifacts lists them)
#  10. ONE comment: what was done, the answer or why it stopped, the refusals,
#      the screenshots, the spend. Its last line is the result marker for a
#      `done` run, and for any other status (step-cap, time-cap, refused-spend,
#      error) an attempt marker <!-- web-task-attempt:<KEY>:<stamp> --> that
#      never blocks a later run. A post
#      that fails is retried twice, re-reading the thread first; a post still
#      failing is one alert and rc 0, because the spend is done and a lane-run
#      retry would spend again.
# Prints `WEBTASK_DONE status=<s> steps=<n> calls=<c> shots=<k> comment=<url|none>`
# and ends with one `PROF web-task ...` line.
#
# TEST SEAMS, read only under HARNESS_TEST_SANDBOX=1: WEB_TASK_TEST_LIB (a file
# sourced after the real libs: stubs for gh_rest, setting_get,
# model_env_or_route, job_artifact_put), WEB_TASK_DECIDE_CMD and
# WEB_TASK_PW_ROOT (read by the agent). tests/web-task-lane.bh-7594-test.sh.
#
# THE LABEL. An open issue labelled ai-build is re-offered every tick, and each
# re-offer is one pool build up to the web-task hook plus one lane-run machine.
# So the lane takes ai-build off the issue at each terminal point: already
# answered (5), told it is not set up (6), no model route (7), and right after
# the agent run, before the post (8), so a post that keeps failing cannot start
# a second model run.
# A failed unlabel is logged and never fatal. Re-add the label to run it again:
# a run that did not finish carries only an attempt marker, so the next run
# goes ahead. A `done` answer is final: its result marker stops every later run.
#
# THE CAPS are knobs of catalog/lanes.d/web-task.json (the agent's text chunk,
# element list, decide timeout and grace, kept shots, redirect hops, browser
# timeouts, backstop pad, prompt history, npm-root and close timeouts, settle
# and scroll waits and the scroll step; the thread read's page cap; the
# comment's action, refusal, answer and reason caps; the post retry sleeps;
# the agent process timeout pad and kill grace). Each literal
# below is only the fallback of the knob of the same name.
set -uo pipefail
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS="$H"
TICKET="${1:-}"; KEY="${2:-}"; JOB=""; P=""
case "$#" in
  3) P="$3" ;;
  4) JOB="$3"; P="$4" ;;
esac

# Lane gate: `bin/harness-ctl.sh off web-task <project>` stops it.
# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit web-task "$P"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    web-task "$P"

prof() { echo "PROF web-task $*"; }
if ! [[ "$TICKET" =~ ^[1-9][0-9]*$ ]] || ! [[ "$KEY" =~ ^[A-Z]+-[0-9]+$ ]] || ! [[ "$P" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "usage: bin/web-task.sh <ticket> <KEY> [job-id] <project>" >&2
  prof bad-args; exit 2
fi
WEB_TASK_MAX_STEPS="${WEB_TASK_MAX_STEPS:-40}"
WEB_TASK_MAX_S="${WEB_TASK_MAX_S:-600}"
if ! [[ "$WEB_TASK_MAX_STEPS" =~ ^[0-9]+$ ]] || [ "$WEB_TASK_MAX_STEPS" -lt 1 ] || [ "$WEB_TASK_MAX_STEPS" -gt 200 ] \
   || ! [[ "$WEB_TASK_MAX_S" =~ ^[0-9]+$ ]] || [ "$WEB_TASK_MAX_S" -lt 30 ] || [ "$WEB_TASK_MAX_S" -gt 3600 ]; then
  echo "web-task: WEB_TASK_MAX_STEPS must be 1..200 and WEB_TASK_MAX_S 30..3600 (got $WEB_TASK_MAX_STEPS, $WEB_TASK_MAX_S)" >&2
  prof bad-knob; exit 2
fi

# knob_int <ENV> <fallback> <min> <max> — the knob's value when it is an
# integer in range, else the fallback. Each fallback below is the default of
# the knob row of the same name in catalog/lanes.d/web-task.json.
knob_int() {
  local v="${!1:-}"
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; then echo "$v"; else echo "$2"; fi
}
WT_TEXT_CHUNK=$(knob_int WEB_TASK_TEXT_CHUNK 6000 500 50000)
WT_MAX_ELEMENTS=$(knob_int WEB_TASK_MAX_ELEMENTS 60 5 500)
WT_DECIDE_MAX_S=$(knob_int WEB_TASK_DECIDE_MAX_S 120 10 600)
WT_DECIDE_GRACE_S=$(knob_int WEB_TASK_DECIDE_GRACE_S 5 0 60)
WT_MAX_HOPS=$(knob_int WEB_TASK_MAX_HOPS 10 1 20)
WT_NAV_TIMEOUT_S=$(knob_int WEB_TASK_NAV_TIMEOUT_S 30 1 300)
WT_ACTION_TIMEOUT_S=$(knob_int WEB_TASK_ACTION_TIMEOUT_S 10 1 120)
WT_SHOT_TIMEOUT_S=$(knob_int WEB_TASK_SHOT_TIMEOUT_S 15 1 120)
WT_BACKSTOP_PAD_S=$(knob_int WEB_TASK_BACKSTOP_PAD_S 30 1 600)
WT_HISTORY_ACTIONS=$(knob_int WEB_TASK_HISTORY_ACTIONS 8 1 50)
WT_HISTORY_REFUSALS=$(knob_int WEB_TASK_HISTORY_REFUSALS 10 1 50)
WT_AGENT_PAD_S=$(knob_int WEB_TASK_AGENT_PAD_S 90 10 600)
WT_AGENT_KILL_S=$(knob_int WEB_TASK_AGENT_KILL_S 10 1 120)
WEB_TASK_MAX_SHOTS=$(knob_int WEB_TASK_MAX_SHOTS 5 1 5); export WEB_TASK_MAX_SHOTS
WT_NPM_ROOT_TIMEOUT_S=$(knob_int WEB_TASK_NPM_ROOT_TIMEOUT_S 15 1 120)
WT_CLOSE_TIMEOUT_S=$(knob_int WEB_TASK_CLOSE_TIMEOUT_S 5 1 60)
WT_SETTLE_MS=$(knob_int WEB_TASK_SETTLE_MS 300 0 5000)
WT_SCROLL_WAIT_MS=$(knob_int WEB_TASK_SCROLL_WAIT_MS 200 0 5000)
WT_SCROLL_PX=$(knob_int WEB_TASK_SCROLL_PX 700 100 5000)
WT_THREAD_MAX_PAGES=$(knob_int WEB_TASK_THREAD_MAX_PAGES 30 1 100)
WT_C_ACTIONS=$(knob_int WEB_TASK_COMMENT_MAX_ACTIONS 40 1 200)
WT_C_REFUSALS=$(knob_int WEB_TASK_COMMENT_MAX_REFUSALS 20 1 200)
WT_C_ANSWER=$(knob_int WEB_TASK_COMMENT_ANSWER_CHARS 3000 200 60000)
WT_C_REASON=$(knob_int WEB_TASK_COMMENT_REASON_CHARS 1000 100 10000)
# WEB_TASK_POST_SLEEPS: 1..5 words of 0..600 s, else the knob default '5 20'.
POST_SLEEPS="5 20"
if [[ "${WEB_TASK_POST_SLEEPS:-}" =~ ^[0-9]{1,3}(\ [0-9]{1,3}){0,4}$ ]]; then
  POST_SLEEPS="$WEB_TASK_POST_SLEEPS"
  for s in $POST_SLEEPS; do [ "$s" -le 600 ] || POST_SLEEPS="5 20"; done
fi

DECIDE_CMD="$H/bin/lib/web-task/decide.sh"
TEST_LIB=""
if [ "${HARNESS_TEST_SANDBOX:-0}" = 1 ]; then
  [ -n "${WEB_TASK_DECIDE_CMD:-}" ] && DECIDE_CMD="$WEB_TASK_DECIDE_CMD"
  TEST_LIB="${WEB_TASK_TEST_LIB:-}"
else
  unset WEB_TASK_PW_ROOT
fi

# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh" 2>/dev/null
# Every issue read and write goes through the tracker seam (BH-7919): this lane
# answers on GitHub issues only (wt_issue_project), so it loads that adapter.
# shellcheck source=bin/lib/tracker.sh
. "$H/bin/lib/tracker.sh"
# shellcheck source=bin/lib/tracker/github-issues.sh
. "$H/bin/lib/tracker/github-issues.sh"
TRK_ADAPTER=github-issues; TRK_DRY=0; TRK_LOG=""
command -v _lg_ensure_client >/dev/null 2>&1 && _lg_ensure_client >/dev/null 2>&1
if ! command -v setting_get >/dev/null 2>&1 && [ -r "$H/bin/jobs-client.sh" ]; then
  # shellcheck source=bin/jobs-client.sh
  . "$H/bin/jobs-client.sh" >/dev/null 2>&1
fi
# shellcheck source=bin/lib/model-route.sh
. "$H/bin/lib/model-route.sh" 2>/dev/null
# shellcheck source=bin/lib/web-task/route.sh
. "$H/bin/lib/web-task/route.sh"
# shellcheck source=bin/lib/web-task/shots.sh
. "$H/bin/lib/web-task/shots.sh"
# The seams later slices fill (sign-in, OTP, saved sessions, write approval).
# shellcheck source=bin/lib/web-task/vault.sh
. "$H/bin/lib/web-task/vault.sh"
# shellcheck source=bin/lib/web-task/otp.sh
. "$H/bin/lib/web-task/otp.sh"
# shellcheck source=bin/lib/web-task/session.sh
. "$H/bin/lib/web-task/session.sh"
# shellcheck source=bin/lib/web-task/approval.sh
. "$H/bin/lib/web-task/approval.sh"
# shellcheck source=/dev/null
[ -n "$TEST_LIB" ] && . "$TEST_LIB"

alert() { # alert <id> <text> — bin/lane-alert.sh, else bin/alert-line.sh
  if [ -x "$H/bin/lane-alert.sh" ]; then "$H/bin/lane-alert.sh" --id "$1" web-task "$2" >/dev/null 2>&1 && return 0; fi
  [ -x "$H/bin/alert-line.sh" ] && "$H/bin/alert-line.sh" "[web-task] $2" >/dev/null 2>&1
  return 0
}
log() { mkdir -p "$H/logs" 2>/dev/null; echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$P/$KEY] $*" >> "$H/logs/web-task.log" 2>/dev/null; }

# 3. Only a GitHub-issue project: its ticket number IS the issue number.
SLUG=""; IP_RC=0
SLUG=$(wt_issue_project "$P") || IP_RC=$?
if [ "$IP_RC" = 1 ]; then
  alert "web-task-not-issues-$P" "web-task $P/$KEY: $P is an in-app board project; web-task S1 answers on GitHub issues only. Nothing was run."
  prof not-issue-project; exit 1
fi
[ "$IP_RC" = 0 ] || SLUG="${PL_SLUG:-}"
[[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "web-task: no repo slug for $P" >&2; prof no-slug; exit 1; }
TRK_SLUG="$SLUG"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN="${PL_STATE_DIR:-$H/state/web-task/$P}/$KEY-$STAMP"
mkdir -p "$RUN" || { prof no-run-dir; exit 1; }

# 4. The ticket and its whole thread.
read_thread() { # -> $RUN/comments.json (all pages), rc 0 / the gh_rest rc
  # Reads until a short page. A thread past WEB_TASK_THREAD_MAX_PAGES full
  # pages is rc 75 (fail closed): this read is the dedup-before-spend check,
  # and a marker past the cap would be missed and paid for again.
  local pg=1 rc n
  echo '[]' > "$RUN/comments.json"
  while :; do
    rc=0; trk_gh_comments_page "$TICKET" "$pg" > "$RUN/page.json" || rc=$?
    [ "$rc" = 0 ] || return "$rc"
    n=$(jq -e 'length' "$RUN/page.json" 2>/dev/null) || return 75
    jq -s '.[0] + .[1]' "$RUN/comments.json" "$RUN/page.json" > "$RUN/c.tmp" && mv "$RUN/c.tmp" "$RUN/comments.json" || return 75
    [ "$n" -lt 100 ] && return 0
    if [ "$pg" -ge "$WT_THREAD_MAX_PAGES" ]; then
      log "the thread has more than $WT_THREAD_MAX_PAGES pages of 100 comments (WEB_TASK_THREAD_MAX_PAGES): not read to the end, so no run"
      return 75
    fi
    pg=$((pg + 1))
  done
}
marker_url() { # marker_url <marker> -> rc 0 and the comment's html_url when a comment carries it
  jq -er --arg m "$1" 'first(.[] | select((.body // "") | contains($m))) | (.html_url // "posted")' "$RUN/comments.json" 2>/dev/null
}
RC=0; trk_gh_issue_raw "$TICKET" > "$RUN/issue.json" || RC=$?
if [ "$RC" != 0 ] || ! jq -e '.number' "$RUN/issue.json" >/dev/null 2>&1; then
  log "ticket read failed (rc $RC): nothing spent, the lane-run retry reads it again"
  prof "ticket-read rc=$RC"; exit 75
fi
RC=0; read_thread || RC=$?
[ "$RC" = 0 ] || { log "comment read failed (rc $RC): nothing spent"; prof "thread-read rc=$RC"; exit 75; }

# unlabel <why> — take the handoff label ai-build off the issue (THE LABEL).
unlabel() {
  local rc=0
  tracker_label_remove "$TICKET" ai-build >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then log "unlabel ai-build: $1"
  else log "unlabel ai-build failed (rc $rc, ${GH_REST_STATUS:-?}): $1 — the next tick re-offers the ticket"
  fi
  return 0
}

# 5. Dedup before spend.
RESULT_MARK="<!-- web-task-result:$KEY -->"
# A run that does not finish ends its comment with this one. It is unique to
# the run (post_comment's re-read finds only this run's own post) and the
# dedup above never reads it, so a re-label runs the ticket again.
ATTEMPT_MARK="<!-- web-task-attempt:$KEY:$STAMP -->"
REFUSED_MARK="<!-- web-task-refused:$KEY -->"
if marker_url "$RESULT_MARK" >/dev/null; then
  echo "WEBTASK_SKIP already answered ($(marker_url "$RESULT_MARK"))"
  log "skip: already answered"
  unlabel "already answered"
  prof skip=answered; exit 0
fi

# post_comment <bodyfile> -> COMMENT_URL; rc 0 posted (or found posted), 1 not
COMMENT_URL=""
post_comment() {
  local body="$1" mark="$2" s rc url
  COMMENT_URL=""
  for s in "" $POST_SLEEPS; do
    if [ -n "$s" ]; then
      sleep "$s"
      # A failed answer can still have landed: never post the same marker twice.
      if read_thread && url=$(marker_url "$mark"); then COMMENT_URL="$url"; return 0; fi
    fi
    rc=0; trk_gh_comment_raw "$TICKET" "$body" > "$RUN/post.json" || rc=$?
    if [ "$rc" = 0 ]; then
      COMMENT_URL=$(jq -r '.html_url // empty' "$RUN/post.json" 2>/dev/null)
      [ -n "$COMMENT_URL" ] || COMMENT_URL="posted"
      return 0
    fi
    log "comment post failed (rc $rc)"
  done
  return 1
}

# 6. The allow-list. Empty is refuse, never all.
DRC=0; RAW=""
if command -v setting_get >/dev/null 2>&1; then RAW=$(setting_get "lane.web-task.$P.allowed_domains") || DRC=$?; else DRC=1; fi
case "$DRC" in
  0) ;;
  2) RAW="" ;;
  *) log "settings unreadable (rc $DRC): nothing spent"; prof settings-outage; exit 75 ;;
esac
DOMAINS=$(printf '%s' "$RAW" | tr '[:upper:]' '[:lower:]' | tr ', \t' '\n\n\n' | sed -E 's/\.+$//' \
  | grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' | sort -u | paste -sd, -)
if [ -z "$DOMAINS" ]; then
  if marker_url "$REFUSED_MARK" >/dev/null; then
    echo "WEBTASK_SKIP not set up for $P (the ticket was told already)"
    unlabel "told it is not set up"
    prof skip=refused-told; exit 0
  fi
  {
    echo "I can't run this web task yet: no website is allowed for this project."
    echo
    echo "The web-task lane only opens hosts on an allow-list, and the list for \`$P\` is empty. To allow a site, an operator sets the settings row:"
    echo
    echo "    bin/jobs-client.sh setting-set lane.web-task.$P.allowed_domains <host>[,<host>...]"
    echo
    echo "Each host also allows its subdomains (for example \`playwright.dev\` allows \`www.playwright.dev\`). After that, label the issue \`ai-build\` again and I will run it."
    echo
    echo "$REFUSED_MARK"
  } > "$RUN/comment.md"
  if post_comment "$RUN/comment.md" "$REFUSED_MARK"; then
    echo "WEBTASK_REFUSED no allowed domain for $P (comment=$COMMENT_URL)"
  else
    alert "web-task-post-failed-$P-$KEY" "web-task $P/$KEY: could not post the not-set-up comment (run dir $RUN)."
    echo "WEBTASK_REFUSED no allowed domain for $P (comment=none)"
  fi
  unlabel "told it is not set up"
  prof refused=no-domains; exit 0
fi

# 7. The model, from model_routes role web-task. No route is no call.
WEB_TASK_MODEL="${WEB_TASK_MODEL:-}"
MRC=0
if command -v model_env_or_route >/dev/null 2>&1; then model_env_or_route WEB_TASK_MODEL web-task "$P" || MRC=$?; else MRC=75; fi
if [ "$MRC" != 0 ] || [ -z "$WEB_TASK_MODEL" ]; then
  # Take ai-build off: with the label on, every tick boots one pool build and
  # one lane-run machine only to reach this exit again. The settings read in
  # step 6 already reached the jobs worker, so this is a missing route, not an
  # outage. Re-adding the label after the route is seeded runs it, the same
  # rule as the not-set-up path.
  alert web-task-no-route "web-task $P/$KEY: no model_routes row for role web-task (rc $MRC). Nothing was run. Seed it with PUT /api/model-routes or the BH-7594 schema fragment, then label the issue ai-build again."
  unlabel "no model route"
  prof no-model-route; exit 1
fi

# 8. The browser loop.
jq -r '"# " + (.title // "") + "\n\n" + (.body // "")' "$RUN/issue.json" > "$RUN/task.md"
export WEB_TASK_PROJECT="$P" WEB_TASK_MODEL WEB_TASK_DOMAINS="$DOMAINS"
log "start: domains=$DOMAINS steps<=$WEB_TASK_MAX_STEPS wall<=${WEB_TASK_MAX_S}s run=$RUN"
ARC=0
timeout -k "$WT_AGENT_KILL_S" $((WEB_TASK_MAX_S + WT_AGENT_PAD_S)) node "$H/bin/web-task-agent.mjs" --task "$RUN/task.md" --out "$RUN" \
  --domains "$DOMAINS" --max-steps "$WEB_TASK_MAX_STEPS" --max-s "$WEB_TASK_MAX_S" --decide "$DECIDE_CMD" \
  --text-chunk "$WT_TEXT_CHUNK" --max-elements "$WT_MAX_ELEMENTS" --decide-max-s "$WT_DECIDE_MAX_S" \
  --decide-grace-s "$WT_DECIDE_GRACE_S" --keep-shots "$WEB_TASK_MAX_SHOTS" --max-hops "$WT_MAX_HOPS" \
  --nav-timeout-s "$WT_NAV_TIMEOUT_S" --action-timeout-s "$WT_ACTION_TIMEOUT_S" --shot-timeout-s "$WT_SHOT_TIMEOUT_S" \
  --backstop-pad-s "$WT_BACKSTOP_PAD_S" --history-actions "$WT_HISTORY_ACTIONS" --history-refusals "$WT_HISTORY_REFUSALS" \
  --npm-root-timeout-s "$WT_NPM_ROOT_TIMEOUT_S" --close-timeout-s "$WT_CLOSE_TIMEOUT_S" --settle-ms "$WT_SETTLE_MS" \
  --scroll-wait-ms "$WT_SCROLL_WAIT_MS" --scroll-px "$WT_SCROLL_PX" \
  > "$RUN/agent.out" 2> "$RUN/agent.err" || ARC=$?
R="$RUN/result.json"
S=$(jq -r '.status // empty' "$R" 2>/dev/null)
STEPS=$(jq -r '.steps // 0' "$R" 2>/dev/null); STEPS="${STEPS:-0}"
CALLS=$(jq -r '.calls // 0' "$R" 2>/dev/null); CALLS="${CALLS:-0}"
ANSWER=$(jq -r '.answer // ""' "$R" 2>/dev/null)
REASON=$(jq -r '.reason // ""' "$R" 2>/dev/null)
if [ -z "$S" ]; then
  S=error; REASON="the agent wrote no result (rc $ARC): $(head -c 200 "$RUN/agent.err" 2>/dev/null | tr '\n' ' ')"
fi
if [ "$S" = done ] && [ -z "$(printf '%s' "$ANSWER" | tr -d '[:space:]')" ]; then S=error; REASON="the agent ended done with an empty answer"; fi
log "agent: status=$S steps=$STEPS calls=$CALLS rc=$ARC"
# The spend is done: no re-offer may start another run, whatever the post does.
unlabel "the run is spent (status $S)"

# 9. Screenshots and artifacts.
SHOTS=(); URLS=(); SHOT_NOTE=""
while IFS= read -r f; do [ -s "$f" ] && SHOTS+=("$f"); done < <(jq -r '.screenshots[]? // empty' "$R" 2>/dev/null)
if [ "${#SHOTS[@]}" -gt 0 ]; then
  if SOUT=$(wt_shots_publish "$SLUG" "$KEY" "${SHOTS[@]}" 2>/dev/null); then
    while IFS= read -r u; do [ -n "$u" ] && URLS+=("$u"); done <<<"$SOUT"
  else
    SHOT_NOTE="${SOUT:-could not publish: unknown error}"
  fi
else
  SHOT_NOTE="could not publish: the run took no screenshot"
fi
if [ -n "$JOB" ] && command -v job_artifact_put >/dev/null 2>&1; then
  i=0
  for u in "${URLS[@]}"; do
    i=$((i + 1))
    job_artifact_put "web-task-shot-$i" "$u" "" "$JOB" >/dev/null 2>&1 || log "artifact web-task-shot-$i not recorded"
  done
  job_artifact_put web-task-result "$S" "$(jq -c '{steps, calls, refusals: (.refusals | length), final_url}' "$R" 2>/dev/null)" "$JOB" >/dev/null 2>&1 \
    || log "artifact web-task-result not recorded"
fi

# 10. The one comment. Page text and model text are data: no HTML comment can
# forge a marker, and backticks cannot break the code spans.
clean() { sed -e 's/<!--/< !--/g' -e 's/-->/-- >/g' -e 's/`/'"'"'/g'; }
{
  case "$S" in
    done) echo "I ran this web task in a read-only browser. Here is what I found." ;;
    *)    echo "I ran this web task in a read-only browser, but it did not finish." ;;
  esac
  echo
  case "$S" in
    done)          echo "**Status:** done." ;;
    step-cap)      echo "**Status:** step-cap. The run stopped after $STEPS steps (WEB_TASK_MAX_STEPS). The answer is incomplete." ;;
    time-cap)      echo "**Status:** time-cap. The run stopped at the wall-time cap of ${WEB_TASK_MAX_S}s (WEB_TASK_MAX_S). The answer is incomplete." ;;
    refused-spend) echo "**Status:** refused-spend. The spend gate refused the model call, so nothing was billed. The answer is incomplete." ;;
    *)             echo "**Status:** error. The answer is incomplete." ;;
  esac
  echo
  echo "### What I did"
  NA=$(jq '.actions | length' "$R" 2>/dev/null || echo 0)
  if [ "${NA:-0}" -gt 0 ]; then
    jq -r --arg q "'" --argjson n "$WT_C_ACTIONS" '.actions[:$n] | to_entries[] | .value as $a
      | "\(.key + 1). \($a.action)\(if $a.url then " `" + $a.url + "`" else "" end)\(if $a.label then " " + $q + $a.label + $q else "" end)\(if $a.dir then " " + $a.dir else "" end) — \($a.outcome)"' "$R" 2>/dev/null | clean
    [ "$NA" -gt "$WT_C_ACTIONS" ] && echo "… and $((NA - WT_C_ACTIONS)) more steps."
  else
    echo "No action ran."
  fi
  echo
  if [ "$S" = done ]; then
    echo "### Answer"
    printf '%s\n' "${ANSWER:0:$WT_C_ANSWER}" | clean | sed 's/^/> /'
  else
    echo "### Why it stopped"
    R1="${REASON:-no reason recorded}"; printf '%s\n' "${R1:0:$WT_C_REASON}" | clean
  fi
  NR=$(jq '.refusals | length' "$R" 2>/dev/null || echo 0)
  if [ "${NR:-0}" -gt 0 ]; then
    echo
    echo "### What the read-only guard refused"
    jq -r --arg q "'" --argjson n "$WT_C_REFUSALS" '.refusals[:$n][] | "- step \(.step): " + (
      if .kind == "host" then "a page on a host that is not on the allow-list: `\(.url)`"
      elif .kind == "redirect" then "a redirect off the allow-list: `\(.from)` to `\(.to)`"
      elif .kind == "control" then "a click on \($q)\(.label)\($q), which reads as a submit or write control"
      elif .kind == "method" then "a \(.method) request (read-only run): `\(.url)`"
      else .kind end)' "$R" 2>/dev/null | clean
  fi
  echo
  echo "### Screenshots"
  if [ "${#URLS[@]}" -gt 0 ]; then
    i=0; NS=${#SHOTS[@]}
    for u in "${URLS[@]}"; do
      i=$((i + 1))
      n=$(basename "${SHOTS[$((i - 1))]}" | sed -E 's/^shot-0*([0-9]+)\..*/\1/')
      echo "![step $n]($u)"
    done
    [ "$NS" -gt "${#URLS[@]}" ] && echo "(the last ${#URLS[@]} of $NS)"
  else
    echo "$SHOT_NOTE" | clean
  fi
  echo
  echo "Spend: steps: $STEPS, model calls: $CALLS."
  echo
  if [ "$S" = done ]; then
    echo "This answer is final: adding the label again does not run this issue again. For another task on that site, open a new issue with the same labels."
    echo
    echo "$RESULT_MARK"
  else
    echo "To run this task again, add the \`ai-build\` label to this issue again."
    echo
    echo "$ATTEMPT_MARK"
  fi
} > "$RUN/comment.md"
MARK="$ATTEMPT_MARK"; [ "$S" = done ] && MARK="$RESULT_MARK"
if ! post_comment "$RUN/comment.md" "$MARK"; then
  alert "web-task-post-failed-$P-$KEY" "web-task $P/$KEY: could not post the result comment after $((1 + $(wc -w <<<"$POST_SLEEPS"))) tries. The run is spent; the body is in $RUN/comment.md."
  COMMENT_URL=""
fi
log "done: status=$S steps=$STEPS calls=$CALLS shots=${#URLS[@]} comment=${COMMENT_URL:-none}"
echo "WEBTASK_DONE status=$S steps=$STEPS calls=$CALLS shots=${#URLS[@]} comment=${COMMENT_URL:-none}"
prof "status=$S steps=$STEPS"
exit 0
