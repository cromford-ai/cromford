#!/bin/bash
# bin/ticket-status-comment.sh — BH-9503 (C1 of #8973): ONE status comment per
# ticket, edited in place at each state change (claimed, spawned, hold
# released, reaped with its outcome code, resumed, PR opened, merged).
#
# The worker decides WHAT is due: GET /api/ticket-status-comments/due renders
# each ticket's status body from the hub's live rows (C0's ticket state) and
# answers only the tickets whose body changed since the last recorded write
# (worker/jobs/src/routes/ticket-status-comment.js). This lane only WRITES:
#
#   ticket-status-comment.sh --dispatch   the cron line. Starts one detached
#       `ticket-status-comment.sh <project>` per fleet project through
#       bin/lib/project-lanes.sh pl_dispatch, each at a stable offset inside
#       TICKET_STATUS_COMMENT_SPREAD_S (default 240). Reads nothing.
#   ticket-status-comment.sh <project>    one project's run.
#
# One run, per due ticket (the body rides in a FILE, never on argv):
#   1. comment_id known (the worker's row): PATCH
#      repos/<slug>/issues/comments/<id>. No read first (BH-10216). rc 44 (the
#      comment was deleted): DELETE /api/ticket-status-comments (compare-and-
#      delete on that id), then POST one new comment (step 3). No list read on
#      this path. A failed DELETE counts failed and posts nothing. Any other
#      failed PATCH counts failed and moves to the next ticket: no adopt, no
#      POST, nothing recorded, so the old hash stays and the next tick PATCHes
#      again.
#   2. no comment_id: adopt. Read the issue's comments once
#      (TICKET_STATUS_COMMENT_ADOPT_PAGES pages of 100 at most, default 3,
#      GH_REST_OPTIONAL=1). The newest comment whose first non-blank line is
#      exactly the marker and whose author is one of our Apps (hs_ours,
#      bin/lib/harness-self.sh) is ours. Its id is recorded FIRST with
#      fingerprint null (BH-10216), then PATCHed. A failed PATCH leaves that
#      row, so the next tick PATCHes the id and lists nothing.
#   3. none: POST one new comment.
#   4. POST /api/ticket-status-comments records the comment id and the
#      fingerprint. Write first, record after: a lost record is healed next
#      tick by the stored id or by adopt, never by a second POST.
# rc 75 on any GitHub call (rate limit, quota reserve, 5xx, auth) stops the
# project's tick: nothing more is written, nothing is recorded for that ticket.
# An unreadable thread never leads to a POST.
#
# Quiet exits (exit 0, one log line, no worker request, no GitHub call): the
# lane is off (flags/lane-off-ticket-status-comment) or disabled
# (TICKET_STATUS_COMMENT_ENABLED=0); the project is not watched
# (TICKET_STATUS_COMMENT_PROJECTS: `self` = cromford, `all`, or a comma
# list); the project is not a GitHub-issues board (fleet.conf board_prefix is
# not `-`); GH_TOKEN is not an App installation token (`ghs_`): a comment by a
# PAT counts as a person to the plan-thread gate and would reap the build.
# A worker answer that is not 200: one log line, exit 0, no GitHub call.
#
# Summary, one line per run in logs/ticket-status-comment.log:
#   <ts> project=<p> due=N patched=N adopted=N posted=N failed=N truncated=0|1
#     [stopped=rc75-<patch|thread|adopt|post>:<key>]
#
# Test seam, honoured only under HARNESS_TEST_SANDBOX=1:
# TICKET_STATUS_COMMENT_FIXTURE, a file sourced after the libs (the fakes).
# Registry: catalog/lanes.d/ticket-status-comment.json.
# Cron: cron/lanes/781-ticket-status-comment.cron.
# Doc: docs/notes/2026-11-11-BH-9503-ticket-status-comment.md.
#
# gh-identity: app-token
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
LANE=ticket-status-comment
MARKER='<!-- harness-status: ticket-status -->'
HOME_P=cromford
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/lib/lane-switch.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/harness-self.sh" 2>/dev/null || true
}
# Every issue read and write goes through the tracker seam (BH-7919): this lane
# answers on GitHub issues only, so it loads that adapter.
# shellcheck source=bin/lib/tracker.sh
. "$SELF/lib/tracker.sh" 2>/dev/null || true
# shellcheck source=bin/lib/tracker/github-issues.sh
. "$SELF/lib/tracker/github-issues.sh" 2>/dev/null || true
TRK_ADAPTER=github-issues; TRK_DRY=0; TRK_LOG=""
# shellcheck source=bin/lib/project-lanes.sh
[ -r "$H/bin/lib/project-lanes.sh" ] && . "$H/bin/lib/project-lanes.sh"
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${TICKET_STATUS_COMMENT_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$TICKET_STATUS_COMMENT_FIXTURE"
fi

usage() { echo "usage: ticket-status-comment.sh [--dispatch | <project>]" >&2; exit 2; }
MODE=run; PROJECT=""
case "$#" in
  1) case "$1" in --dispatch) MODE=dispatch ;; -*|'') usage ;; *) PROJECT=$1 ;; esac ;;
  *) usage ;;
esac
if [ "$MODE" = run ]; then
  case "$PROJECT" in .*|*[!A-Za-z0-9._-]*) echo "ticket-status-comment: bad project name '$PROJECT'" >&2; usage ;; esac
fi

mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/$LANE.log"
summary() { printf '%s project=%s %s\n' "$(date -u +%FT%TZ)" "${PROJECT:--}" "$1" >> "$LOG"; }

command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply "$LANE"

# tsc_watched <project> — rc 0 when TICKET_STATUS_COMMENT_PROJECTS watches it.
tsc_watched() {
  local p="$1" list="${TICKET_STATUS_COMMENT_PROJECTS:-self}"
  case "$list" in
    all) return 0 ;;
    self) ;;
    *[!A-Za-z0-9._,-]*|,*|*,|*,,*)
      echo "ticket-status-comment: TICKET_STATUS_COMMENT_PROJECTS='$list' is not self, all or a comma list; read as self" >&2 ;;
    *) case ",$list," in *",$p,"*) return 0 ;; esac
       return 1 ;;
  esac
  [ "$p" = "$HOME_P" ]
}

command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }
if lane_switch "lane-off-$LANE" file; then summary off; exit 0; fi
[ "${TICKET_STATUS_COMMENT_ENABLED:-1}" = 0 ] && { summary disabled; exit 0; }

if [ "$MODE" = dispatch ]; then
  command -v pl_dispatch >/dev/null 2>&1 || { echo "$(date -u +%FT%TZ) $LANE dispatch: bin/lib/project-lanes.sh is not loaded — no project run started"; exit 1; }
  SPREAD="${TICKET_STATUS_COMMENT_SPREAD_S:-240}"
  case "$SPREAD" in
    ''|*[!0-9]*) echo "$(date -u +%FT%TZ) $LANE dispatch: TICKET_STATUS_COMMENT_SPREAD_S='$SPREAD' is not a number of seconds; using 240"
                 SPREAD=240 ;;
  esac
  rc=0; line=$(pl_dispatch "$LANE" "$SPREAD" "$H/bin/ticket-status-comment.sh") || rc=$?
  echo "$(date -u +%FT%TZ) $line"
  exit "$rc"
fi

tsc_watched "$PROJECT" || { summary "not watched (TICKET_STATUS_COMMENT_PROJECTS)"; exit 0; }
if [ "$(tracker_board_prefix "$PROJECT" 2>/dev/null)" != "-" ]; then
  summary "not a GitHub-issues board (fleet.conf column 4 is not -)"; exit 0
fi
SLUG=""; [ "${PL_PROJECT:-}" = "$PROJECT" ] && SLUG="${PL_SLUG:-}"
[ -n "$SLUG" ] || SLUG=$("$H/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
case "$SLUG" in */*) ;; *) summary "fleet.conf has no repo"; exit 0 ;; esac
TRK_SLUG="$SLUG"

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit ticket-status-comment

mkdir -p "$H/locks" 2>/dev/null
if [ -n "${PL_LOCK_FD:-}" ] && [ "${PL_LANE:-}" = "$LANE" ] && [ "${PL_PROJECT:-}" = "$PROJECT" ]; then
  :  # the runner holds locks/ticket-status-comment-<project>.lock on PL_LOCK_FD
elif command -v pl_lock_take >/dev/null 2>&1; then
  pl_lock_take "$LANE" "$PROJECT" 9 || { summary busy; exit 0; }
else
  exec 9>"$H/locks/$LANE-$PROJECT.lock"
  flock -n 9 || { summary busy; exit 0; }
fi

# The App token: global.env may have set GH_TOKEN, so re-arm the project's own.
if command -v pl_token >/dev/null 2>&1; then PL_SLUG=$SLUG pl_token >/dev/null 2>&1 || true; fi
case "${GH_TOKEN:-}" in
  ghs_*) export GH_TOKEN ;;
  *) summary "no App token; not posting"; exit 0 ;;
esac
command -v gh_rest >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1 \
  || { summary "a lib did not load (gh_rest or _jobs_req)"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/$LANE.XXXXXX") || { summary "no tmp"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

rc=0; _jobs_req GET "/api/ticket-status-comments/due?project=$PROJECT" > "$TMP/due.json" || rc=$?
if [ "$rc" != 0 ] || ! jq -e '.due | type == "array"' "$TMP/due.json" >/dev/null 2>&1; then
  summary "the worker did not answer the due list (rc $rc, http ${JOBS_HTTP:-none}); nothing written"; exit 0
fi

# The adopt read's page cap (lane knob; 3 is its documented fallback). 100 per
# page is GitHub's own maximum, not a policy cap.
ADOPT_PAGES="${TICKET_STATUS_COMMENT_ADOPT_PAGES:-3}"
case "$ADOPT_PAGES" in
  [1-9]|10) ;;
  *) echo "ticket-status-comment: TICKET_STATUS_COMMENT_ADOPT_PAGES='$ADOPT_PAGES' is not 1..10; using 3" >&2; ADOPT_PAGES=3 ;;
esac
# Our Apps and the hs_ours jq def, both from bin/lib/harness-self.sh (it sets
# HARNESS_SELF_JQ_DEF when it loads). No lib: no comment counts as ours, so
# nothing is adopted.
if command -v harness_self_apps_json >/dev/null 2>&1; then
  APPS=$(harness_self_apps_json 2>/dev/null) || APPS='[]'
  [ -n "$APPS" ] || APPS='[]'
  HS_DEF="$HARNESS_SELF_JQ_DEF"
else
  APPS='[]'; HS_DEF='def hs_ours($a): false;'
fi
# tsc_adopt <issue> — print the id of our newest marked comment. rc 0 found,
# rc 1 none, rc 75 the thread could not be read.
tsc_adopt() {
  local n="$1" page grc best="" id
  for page in $(seq 1 "$ADOPT_PAGES"); do
    grc=0; GH_REST_OPTIONAL=1 trk_gh_comments_page "$n" "$page" > "$TMP/page.json" || grc=$?
    [ "$grc" = 0 ] || return 75
    jq -e 'type == "array"' "$TMP/page.json" >/dev/null 2>&1 || return 75
    id=$(jq -r --arg m "$MARKER" --argjson apps "$APPS" "$HS_DEF"'
      [.[] | select(type == "object" and .id != null)
       | select(((.body // "") | gsub("\r"; "") | split("\n") | map(select(test("\\S"))) | .[0] // "") == $m)
       | select(hs_ours($apps)) | .id] | max // empty' "$TMP/page.json" 2>/dev/null)
    if [ -n "$id" ] && { [ -z "$best" ] || [ "$id" -gt "$best" ]; }; then best=$id; fi
    [ "$(jq 'length' "$TMP/page.json")" -lt 100 ] && break
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

due=$(jq '.due | length' "$TMP/due.json")
truncated=$(jq -r 'if .truncated then 1 else 0 end' "$TMP/due.json")
patched=0 adopted=0 posted=0 failed=0 stop=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  key=$(jq -r '.key' <<<"$entry"); issue=$(jq -r '.issue' <<<"$entry"); cid=$(jq -r '.comment_id // empty' <<<"$entry")
  [[ "$issue" =~ ^[0-9]+$ ]] || { failed=$((failed + 1)); continue; }
  jq -r '.body' <<<"$entry" > "$TMP/body.md"
  # arc: the adopt answer (0 found, 1 none, 75 unreadable). A row whose
  # comment answered 404 skips adopt and POSTs (arc 1).
  how=""; grc=0; arc=1
  if [[ "$cid" =~ ^[0-9]+$ ]]; then
    trk_gh_comment_edit "$cid" "$TMP/body.md" > "$TMP/out.json" || grc=$?
    # Only rc 44 (the comment is gone) leads to a POST, and only after the row
    # that names the dead comment is gone. Any other failure is never a reason
    # to post a second comment.
    case "$grc" in
      0) how=patched ;;
      44) _jobs_req DELETE "/api/ticket-status-comments?project=$PROJECT&key=$key&comment_id=$cid" >/dev/null \
            || { failed=$((failed + 1)); continue; } ;;
      75) failed=$((failed + 1)); stop="rc75-patch:$key"; break ;;
      *) failed=$((failed + 1)); continue ;;
    esac
  else
    arc=0; aid=$(tsc_adopt "$issue") || arc=$?
    if [ "$arc" = 75 ]; then failed=$((failed + 1)); stop="rc75-thread:$key"; break; fi
  fi
  if [ -z "$how" ]; then
    if [ "$arc" = 0 ]; then
      # Store the found id before the PATCH (fingerprint null = hash unknown).
      pre=$(jq -c --arg p "$PROJECT" --argjson id "$aid" '{project: $p, ticket_key: .key, issue: .issue, comment_id: $id,
        fingerprint: null, state: .state, final: false}' <<<"$entry")
      _jobs_req POST /api/ticket-status-comments "$pre" >/dev/null || { failed=$((failed + 1)); continue; }
      grc=0; trk_gh_comment_edit "$aid" "$TMP/body.md" > "$TMP/out.json" || grc=$?
      case "$grc" in
        0) cid=$aid; how=adopted ;;
        75) failed=$((failed + 1)); stop="rc75-adopt:$key"; break ;;
        *) failed=$((failed + 1)); continue ;;
      esac
    else
      grc=0; trk_gh_comment_raw "$issue" "$TMP/body.md" > "$TMP/out.json" || grc=$?
      case "$grc" in
        0) cid=$(jq -r '.id // empty' "$TMP/out.json" 2>/dev/null); how=posted ;;
        75) failed=$((failed + 1)); stop="rc75-post:$key"; break ;;
        *) failed=$((failed + 1)); continue ;;
      esac
    fi
  fi
  case "$how" in patched) patched=$((patched + 1)) ;; adopted) adopted=$((adopted + 1)) ;; posted) posted=$((posted + 1)) ;; esac
  [[ "$cid" =~ ^[0-9]+$ ]] || { failed=$((failed + 1)); continue; }
  rec=$(jq -c --arg p "$PROJECT" --argjson id "$cid" '{project: $p, ticket_key: .key, issue: .issue, comment_id: $id,
    fingerprint: .fingerprint, state: .state, final: .final}' <<<"$entry")
  _jobs_req POST /api/ticket-status-comments "$rec" >/dev/null || failed=$((failed + 1))
done < <(jq -c '.due[]' "$TMP/due.json")

summary "due=$due patched=$patched adopted=$adopted posted=$posted failed=$failed truncated=$truncated${stop:+ stopped=$stop}"
exit 0
