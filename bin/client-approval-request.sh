#!/bin/bash
# bin/client-approval-request.sh <project> <owner/repo> <pr> <head40> <record-dir|-> [<paths>]
#
# BH-9887 slice C0. Ask the project's product board for the client's approval
# of ONE PR head that client mode withholds (la_decide rc 1), then post ONE
# client-safe comment on the ticket. The conductor fragment
# bin/merge-conductor.d/bh-9887-client-approval.sh spawns it detached, once a
# tick, until the head's marker settles. <paths> is la_decide's
# LA_PROTECTED_PATHS (", " joined, maybe ending ", +N more").
#
# Steps, all under flock -n locks/client-approval-<project>-<pr>.lock (held =
# another run is on it: exit 0, nothing changed):
#   1. The switch client_approval_board.<owner>.<name> (bin/lib/client-approval.sh
#      ca_enabled). Off: exit 0, no call, no marker.
#   2. The marker state/client-approval/<project>/<pr>-<head>.json. Settled:
#      exit 0.
#   3. The ticket id from <record>/job.json .ticket_id. None: marker no-ticket.
#   4. The tracker kind. Not `board`: marker not-board. No base or token: a
#      failed attempt (last_http=config).
#   5. POST <board>/tickets/<id>/approval-requests with Idempotency-Key
#      client-approval:<project>:<pr>:<head>.
#        2xx object or 409: sent (request_id, approvers kept)
#        404: absent-route, one log line per head, no ALERTS line
#        else: failed, attempts+1; at retry_max: cap-spent + ONE ALERTS line
#   6. Marker sent, comment not posted: tracker_comment. rc 0: comment posted,
#      status done. Else comment_attempts+1; at retry_max: comment cap-spent,
#      status done, ONE ALERTS line.
#   7. ca_prune: markers older than marker_keep_d days.
# Log: logs/client-approval.log. `requested` only after a 2xx/409, `commented`
# only after tracker_comment rc 0. Exit 0 on every path but bad arguments (2).
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
H="$HARNESS"
LIB="$(cd "$(dirname "$0")" && pwd)/lib"
[ -r "$LIB/client-approval.sh" ] || LIB="$HARNESS/bin/lib"
LOG="$HARNESS/logs/client-approval.log"
ca_log() { mkdir -p "${LOG%/*}" 2>/dev/null; printf '%s client-approval: %s\n' "$(date -u '+%F %TZ')" "$*" >> "$LOG" 2>/dev/null; }

PROJ="${1:-}"; SLUG="${2:-}"; PR="${3:-}"; HEAD=$(printf '%s' "${4:-}" | tr 'A-F' 'a-f'); REC="${5:--}"; PATHS="${6:-}"
bad_args() { ca_log "bad arguments ($1): nothing done"; echo "usage: $0 <project> <owner/repo> <pr> <head40> <record-dir|-> [<paths>]" >&2; exit 2; }
[[ "$PROJ" =~ ^[A-Za-z0-9_.-]+$ ]] || bad_args project
[[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || bad_args slug
[[ "$PR" =~ ^[0-9]{1,9}$ ]] || bad_args pr
[[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || bad_args head
FCS="$HARNESS/bin/fleet-conf.sh"; [ -x "$FCS" ] || FCS="$LIB/../fleet-conf.sh"
FREPO=$("$FCS" "$PROJ" repo 2>/dev/null) || FREPO=""
[ -n "$FREPO" ] || bad_args "project not in fleet.conf"
[ "$(printf '%s' "$FREPO" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$SLUG" | tr 'A-Z' 'a-z')" ] || bad_args "repo is not the project's"

# shellcheck source=bin/lib/client-approval.sh
. "$LIB/client-approval.sh" || { ca_log "no lib: nothing done"; exit 0; }
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1
set +e
KEY="$SLUG#$PR@${HEAD:0:8}"
H12="${HEAD:0:12}"

mkdir -p "$HARNESS/locks" 2>/dev/null
exec 7>"$HARNESS/locks/client-approval-$PROJ-$PR.lock" || { ca_log "$KEY lock file not writable: nothing done"; exit 0; }
flock -n 7 || exit 0

RETRY_MAX=$(ca_knob retry_max "$CA_RETRY_MAX_DEFAULT")
TIMEOUT_S=$(ca_knob timeout_s "$CA_TIMEOUT_S_DEFAULT")
RECHECK_S=$(ca_knob absent_recheck_s "$CA_ABSENT_RECHECK_S_DEFAULT")
KEEP_D=$(ca_knob marker_keep_d "$CA_MARKER_KEEP_D_DEFAULT")
PRUNE_MAX=$(ca_knob prune_max "$CA_PRUNE_MAX_DEFAULT")
SUMMARY_MAX=$(ca_knob summary_max_chars "$CA_SUMMARY_MAX_CHARS_DEFAULT")
NAME_MAX=$(ca_knob approver_name_max "$CA_APPROVER_NAME_MAX_DEFAULT")
APPROVERS_MAX=$(ca_knob approvers_max "$CA_APPROVERS_MAX_DEFAULT")

finish() {
  local n
  n=$(ca_prune "$PROJ" "$KEEP_D" "$PRUNE_MAX")
  [ "${n:-0}" -gt 0 ] 2>/dev/null && ca_log "pruned $n marker(s) of $PROJ older than $KEEP_D days"
  exit 0
}

if ! ca_enabled "$SLUG"; then
  [ "$CA_SWITCH" = unreadable ] && ca_log "switch unreadable for $SLUG, off this run"
  finish
fi

MARK=$(ca_mark_file "$PROJ" "$PR" "$HEAD") || { ca_log "$KEY no harness root: no marker path, nothing done"; exit 0; }
ca_mark_settled "$MARK" "$RECHECK_S" && finish
M=$(ca_mark_read "$MARK") || M=""
if [ -z "$M" ]; then
  M=$(jq -nc --arg p "$PROJ" --arg r "$SLUG" --argjson pr "$PR" --arg h "$HEAD" \
    '{v:1, project:$p, repo:$r, pr:$pr, head:$h, ticket_id:null, status:"new", attempts:0, last_http:null,
      checked_at:null, request_id:null, approvers:[], comment:"pending", comment_attempts:0}')
fi
mget() { printf '%s' "$M" | jq -r "$1 // empty"; }
mset() { M=$(printf '%s' "$M" | jq -c "$@") || return 1; }
save() { ca_mark_write "$MARK" "$M" || ca_log "$KEY marker write failed ($MARK)"; }
STATUS=$(mget .status)
PREV_STATUS="$STATUS"

# ── 3. the ticket ────────────────────────────────────────────────────────────
TID=$(mget .ticket_id)
if [ -z "$TID" ] && [ "$REC" != - ] && [ -r "$REC/job.json" ]; then
  TID=$(jq -r '.ticket_id // empty | tostring' "$REC/job.json" 2>/dev/null)
fi
if ! [[ "$TID" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
  mset '.status = "no-ticket"'; save
  ca_log "$KEY no board ticket id in the build record (${REC}): no request"
  finish
fi
mset --arg t "$TID" '.ticket_id = $t'

# ── 4. the board context ─────────────────────────────────────────────────────
TRK_LIB="$LIB/tracker.sh"; [ -r "$TRK_LIB" ] || TRK_LIB="$HARNESS/bin/lib/tracker.sh"
# shellcheck source=bin/lib/tracker.sh
. "$TRK_LIB" 2>/dev/null || { ca_log "$KEY tracker lib missing: nothing done"; finish; }
KIND=$(tracker_kind "$PROJ" 2>/dev/null) || KIND=""
if [ -n "$KIND" ] && [ "$KIND" != board ]; then
  mset '.status = "not-board"'; save
  ca_log "$KEY $PROJ tracks on $KIND, not an in-app board: no request"
  finish
fi
CTX_OK=0
[ -n "$KIND" ] && tracker_context "$PROJ" client-approval 2>/dev/null && CTX_OK=1

# fail <http> <what> — one failed attempt; the cap turns it into ONE ALERTS line.
fail() {
  local n
  n=$(( $(mget .attempts | tr -cd '0-9' | sed 's/^$/0/') + 1 ))
  mset --arg h "$1" --argjson n "$n" --argjson c "$(date -u +%s)" '.attempts = $n | .last_http = $h | .checked_at = $c | .status = "failed"'
  if [ "$n" -ge "$RETRY_MAX" ]; then
    mset '.status = "cap-spent"'; save
    ca_log "$KEY approval request failed $n time(s), last $1 ($2): cap spent, alerted"
    "$HARNESS/bin/alert-line.sh" --id "client-approval-$PROJ-$PR-$H12" --project "$PROJ" \
      "client-approval: the $PROJ board did not take the approval request for ticket $TID, PR https://github.com/$SLUG/pull/$PR head $H12 after $n tries (last $1: $2). The client is not told that this PR waits for approval. Check the board route POST /tickets/$TID/approval-requests, then remove $MARK to ask again." \
      >/dev/null 2>&1
  else
    save
    ca_log "$KEY approval request failed ($1: $2), attempt $n of $RETRY_MAX"
  fi
  finish
}

PR_URL="https://github.com/$SLUG/pull/$PR"
SUMMARY=""; [ "$REC" != - ] && SUMMARY=$(ca_summary "$REC" "$SUMMARY_MAX")
PREVIEW=""
if [ -r "$LIB/release-model.sh" ]; then
  # shellcheck source=bin/lib/release-model.sh
  . "$LIB/release-model.sh" 2>/dev/null && PREVIEW=$(release_staging_base "$PROJ" 2>/dev/null | head -1)
fi
case "$PREVIEW" in https://?*) ;; *) PREVIEW="" ;; esac

# ── 5. the request ───────────────────────────────────────────────────────────
if [ "$STATUS" != sent ]; then
  [ "$CTX_OK" = 1 ] || fail config "no board base or token for $PROJ (${TRK_CTX_MISSING:-kind})"
  if [ "${TRK_DRY:-0}" = 1 ]; then ca_log "$KEY dry run: no request sent"; finish; fi
  PJSON=$(ca_paths_json "$PATHS") || PJSON='[]'
  BODY=$(mktemp "${TMPDIR:-/tmp}/ca-body.XXXXXX") || fail local "mktemp failed"
  ANS=$(mktemp "${TMPDIR:-/tmp}/ca-answer.XXXXXX") || { rm -f "$BODY"; fail local "mktemp failed"; }
  trap 'rm -f "$BODY" "$ANS"' EXIT
  ca_request_body "$SLUG" "$PR" "$HEAD" "$PJSON" "$SUMMARY" "$PREVIEW" > "$BODY" || fail local "the request body could not be built"
  CODE=$(ca_board_post "$TRK_BOARD_BASE/tickets/$TID/approval-requests" "$BODY" "client-approval:$PROJ:$PR:$HEAD" "$TIMEOUT_S" "$ANS")
  case "$CODE" in
    2[0-9][0-9]|409)
      if [ "$CODE" != 409 ] && ! jq -e 'type == "object"' "$ANS" >/dev/null 2>&1; then
        fail "$CODE" "a $CODE answer that is not a JSON object"
      fi
      RID=$(ca_request_id "$ANS")
      APPR=$(ca_approvers "$ANS" "$NAME_MAX" "$APPROVERS_MAX")
      [ -n "$RID" ] || ca_log "$KEY the board answer has no usable request id"
      mset --arg h "$CODE" --arg id "$RID" --argjson a "${APPR:-[]}" --argjson c "$(date -u +%s)" \
        '.status = "sent" | .last_http = $h | .checked_at = $c | .request_id = (if $id == "" then null else $id end) | .approvers = $a'
      save
      ca_log "requested $KEY request=${RID:-none} approvers=$(printf '%s' "${APPR:-[]}" | jq 'length') (HTTP $CODE)"
      ;;
    404)
      mset --argjson c "$(date -u +%s)" '.status = "absent-route" | .last_http = "404" | .checked_at = $c'
      save
      [ "$PREV_STATUS" = absent-route ] || ca_log "$KEY board has no approval-requests route (404); today's behaviour kept"
      finish ;;
    *)
      fail "$CODE" "the board answered HTTP $CODE" ;;
  esac
fi

# ── 6. the comment ───────────────────────────────────────────────────────────
[ "$(mget .comment)" = posted ] && { mset '.status = "done"'; save; finish; }
[ "$CTX_OK" = 1 ] || { ca_log "$KEY comment not posted: no board base or token for $PROJ"; finish; }
if [ "${TRK_DRY:-0}" = 1 ]; then ca_log "$KEY dry run: no comment posted"; finish; fi
CF=$(mktemp "${TMPDIR:-/tmp}/ca-comment.XXXXXX") || finish
ca_comment_body "$PR_URL" "$PR" "$SUMMARY" "$PREVIEW" "$(printf '%s' "$M" | jq -c '.approvers // []')" > "$CF"
if tracker_comment "$TID" "$CF" >/dev/null 2>&1; then
  rm -f "$CF"
  mset '.comment = "posted" | .status = "done"'; save
  ca_log "commented $KEY on ticket $TID"
  finish
fi
rm -f "$CF"
CN=$(( $(mget .comment_attempts | tr -cd '0-9' | sed 's/^$/0/') + 1 ))
mset --argjson n "$CN" '.comment_attempts = $n'
if [ "$CN" -ge "$RETRY_MAX" ]; then
  mset '.comment = "cap-spent" | .status = "done"'; save
  ca_log "$KEY comment failed $CN time(s): cap spent, alerted"
  "$HARNESS/bin/alert-line.sh" --id "client-approval-comment-$PROJ-$PR-$H12" --project "$PROJ" \
    "client-approval: the $PROJ board took the approval request for ticket $TID (PR https://github.com/$SLUG/pull/$PR head $H12), but the ticket comment failed $CN times. The client does not see who can approve. Post the approval note on ticket $TID by hand." \
    >/dev/null 2>&1
else
  save
  ca_log "$KEY comment failed, attempt $CN of $RETRY_MAX"
fi
finish
