#!/bin/bash
# bin/client-approval-close.sh <project> <owner/repo> <pr> <merged|closed>
#
# BH-9901 (BH-9887 slice C2). The PR merged or closed: close the approval
# request the product board holds for it, from the C0 marker's request id
# (state/client-approval/<project>/<pr>-<head>.json), and mark the hub ledger
# row closed. The conductor fragment
# bin/merge-conductor.d/bh-9901-client-approval-close.sh spawns it detached,
# once a tick, while the PR has an open request.
#
# Steps, all under flock -n locks/client-approval-<project>-<pr>.lock (the
# request script's lock: a request and a close of one PR never run at once;
# held = exit 0, nothing changed):
#   1. The switch client_approval_board.<owner>.<name>. Off: exit 0, no call.
#   2. The PR's markers with a request id (status sent|done). The newest by
#      .checked_at (tie: the later file name) is the one to close. Every older
#      one with no close gets close=superseded and no call: the board voids an
#      older request when a new head is sent. A sent|done marker with no
#      request id gets close=no-id and no call.
#   3. No board base or token: a failed attempt (close_last_http=config).
#   4. POST <board>/tickets/<id>/approval-requests/<rid>/close with
#      Idempotency-Key client-approval-close:<project>:<pr>:<rid>, body
#      {reason, prNumber, headSha}.
#        2xx, 409: close=closed (409 = the board already closed it)
#        404: close=gone, one log line, no ALERTS line
#        else: close_attempts+1; at retry_max: close=cap-spent + ONE ALERTS line
#   5. closed|gone: the hub ledger row status closed (ca_hub_put). Failed:
#      hub=pending, hub_attempts+1; at retry_max hub=cap-spent + a log line.
#      The marker is saved BEFORE the hub write, so a crash repeats at most
#      the PUT, never a second POST.
#   6. ca_prune: markers older than marker_keep_d days.
# Log: logs/client-approval.log. `closed` only after a 2xx/409. Exit 0 on every
# path but bad arguments (2).
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
H="$HARNESS"
LIB="$(cd "$(dirname "$0")" && pwd)/lib"
[ -r "$LIB/client-approval.sh" ] || LIB="$HARNESS/bin/lib"
LOG="$HARNESS/logs/client-approval.log"
ca_log() { mkdir -p "${LOG%/*}" 2>/dev/null; printf '%s client-approval: %s\n' "$(date -u '+%F %TZ')" "$*" >> "$LOG" 2>/dev/null; }

PROJ="${1:-}"; SLUG="${2:-}"; PR="${3:-}"; STATE="${4:-}"
bad_args() { ca_log "close: bad arguments ($1): nothing done"; echo "usage: $0 <project> <owner/repo> <pr> <merged|closed>" >&2; exit 2; }
[[ "$PROJ" =~ ^[A-Za-z0-9_.-]+$ ]] || bad_args project
[[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || bad_args slug
[[ "$PR" =~ ^[0-9]{1,9}$ ]] || bad_args pr
case "$STATE" in merged|closed) ;; *) bad_args state ;; esac
FCS="$HARNESS/bin/fleet-conf.sh"; [ -x "$FCS" ] || FCS="$LIB/../fleet-conf.sh"
FREPO=$("$FCS" "$PROJ" repo 2>/dev/null) || FREPO=""
[ -n "$FREPO" ] || bad_args "project not in fleet.conf"
[ "$(printf '%s' "$FREPO" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$SLUG" | tr 'A-Z' 'a-z')" ] || bad_args "repo is not the project's"

# shellcheck source=bin/lib/client-approval.sh
. "$LIB/client-approval.sh" || { ca_log "close: no lib: nothing done"; exit 0; }
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1
set +e
KEY="$SLUG#$PR"

mkdir -p "$HARNESS/locks" 2>/dev/null
exec 7>"$HARNESS/locks/client-approval-$PROJ-$PR.lock" || { ca_log "$KEY close: lock file not writable: nothing done"; exit 0; }
flock -n 7 || exit 0

RETRY_MAX=$(ca_knob retry_max "$CA_RETRY_MAX_DEFAULT")
TIMEOUT_S=$(ca_knob timeout_s "$CA_TIMEOUT_S_DEFAULT")
KEEP_D=$(ca_knob marker_keep_d "$CA_MARKER_KEEP_D_DEFAULT")
PRUNE_MAX=$(ca_knob prune_max "$CA_PRUNE_MAX_DEFAULT")

finish() {
  local n
  n=$(ca_prune "$PROJ" "$KEEP_D" "$PRUNE_MAX")
  [ "${n:-0}" -gt 0 ] 2>/dev/null && ca_log "pruned $n marker(s) of $PROJ older than $KEEP_D days"
  exit 0
}

if ! ca_enabled "$SLUG"; then
  [ "$CA_SWITCH" = unreadable ] && ca_log "close: switch unreadable for $SLUG, off this run"
  finish
fi

ROOT=$(_ca_root)
MDIR="$ROOT/state/client-approval/$PROJ"
[ -n "$ROOT" ] && [ -d "$MDIR" ] || finish

# ── 2. the PR's markers ──────────────────────────────────────────────────────
# One line per v1 marker of this PR: checked_at TAB file TAB request_id|- TAB
# status TAB close|-. Sorted so the last line with a request id is the newest.
LIST=$(find "$MDIR" -maxdepth 1 -type f -name "$PR-*.json" 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
  jq -r --arg f "$f" --argjson pr "$PR" 'select(type == "object" and .v == 1 and .pr == $pr and (.status | type) == "string")
    | [((.checked_at // 0) | tostring), $f, (if (.request_id | type) == "string" then .request_id else "-" end), .status, (.close // "-")] | @tsv' "$f" 2>/dev/null
done | sort -t$'\t' -k1,1n -k2,2)
TARGET=""
while IFS=$'\t' read -r _c f rid st cl; do
  [ -n "$f" ] || continue
  case "$st" in sent|done) ;; *) continue ;; esac
  [ "$rid" != - ] && TARGET="$f"
done <<<"$LIST"

while IFS=$'\t' read -r _c f rid st cl; do
  [ -n "$f" ] || continue
  case "$st" in sent|done) ;; *) continue ;; esac
  [ "$cl" = - ] || continue
  if [ "$rid" = - ]; then
    m=$(ca_mark_read "$f") && ca_mark_write "$f" "$(printf '%s' "$m" | jq -c '.close = "no-id"')"
    ca_log "$KEY close: no request id on ${f##*/} (the board answered without one): nothing to close"
  elif [ "$f" != "$TARGET" ]; then
    m=$(ca_mark_read "$f") && ca_mark_write "$f" "$(printf '%s' "$m" | jq -c '.close = "superseded"')"
    ca_log "$KEY close: request $rid of an older head is superseded by the newer head's request: no call"
  fi
done <<<"$LIST"

[ -n "$TARGET" ] || finish
MARK="$TARGET"
M=$(ca_mark_read "$MARK") || finish
mget() { printf '%s' "$M" | jq -r "$1 // empty"; }
mset() { M=$(printf '%s' "$M" | jq -c "$@") || return 1; }
save() { ca_mark_write "$MARK" "$M" || ca_log "$KEY close: marker write failed ($MARK)"; }
RID=$(mget .request_id)
TID=$(mget .ticket_id)
HEAD=$(mget .head)

# hub_closed — the hub row `closed` for a closed|gone marker.
hub_closed() {
  local rc=0 n
  ca_hub_put "$PROJ" "$SLUG" "$PR" closed "$M" || rc=$?
  case "$rc" in
    0) mset '.hub = "written" | .hub_attempts = 0'; save ;;
    3) ;;
    *) n=$(( $(mget .hub_attempts | tr -cd '0-9' | sed 's/^$/0/') + 1 ))
       if [ "$n" -ge "$RETRY_MAX" ]; then
         mset --argjson n "$n" '.hub = "cap-spent" | .hub_attempts = $n'; save
         ca_log "$KEY close: hub ledger write failed $n time(s): cap spent, the console may still show the wait"
       else
         mset --argjson n "$n" '.hub = "pending" | .hub_attempts = $n'; save
         ca_log "$KEY close: hub ledger write failed, attempt $n of $RETRY_MAX"
       fi ;;
  esac
}

case "$(mget .close)" in
  closed|gone)
    [ "$(mget .hub)" = pending ] && hub_closed
    finish ;;
  '') ;;
  *) finish ;;
esac
[[ "$TID" =~ ^[A-Za-z0-9_.:-]+$ ]] || { ca_log "$KEY close: the marker has no ticket id: nothing to close"; finish; }

# ── 3. the board context ─────────────────────────────────────────────────────
TRK_LIB="$LIB/tracker.sh"; [ -r "$TRK_LIB" ] || TRK_LIB="$HARNESS/bin/lib/tracker.sh"
# shellcheck source=bin/lib/tracker.sh
. "$TRK_LIB" 2>/dev/null || { ca_log "$KEY close: tracker lib missing: nothing done"; finish; }
CTX_OK=0
tracker_context "$PROJ" client-approval 2>/dev/null && CTX_OK=1

# fail <http> <what> — one failed close; the cap turns it into ONE ALERTS line.
fail() {
  local n
  n=$(( $(mget .close_attempts | tr -cd '0-9' | sed 's/^$/0/') + 1 ))
  mset --arg h "$1" --argjson n "$n" '.close_attempts = $n | .close_last_http = $h'
  if [ "$n" -ge "$RETRY_MAX" ]; then
    mset '.close = "cap-spent"'; save
    ca_log "$KEY close of request $RID failed $n time(s), last $1 ($2): cap spent, alerted"
    "$HARNESS/bin/alert-line.sh" --id "client-approval-close-$PROJ-$PR-${RID:0:12}" --project "$PROJ" \
      "client-approval: the $PROJ board did not close the approval request $RID of ticket $TID after PR https://github.com/$SLUG/pull/$PR was $STATE ($n tries, last $1: $2). The ticket may still ask the client to approve a change that is no longer open. Close the request on ticket $TID by hand." \
      >/dev/null 2>&1
  else
    save
    ca_log "$KEY close of request $RID failed ($1: $2), attempt $n of $RETRY_MAX"
  fi
  finish
}

[ "$CTX_OK" = 1 ] || fail config "no board base or token for $PROJ (${TRK_CTX_MISSING:-kind})"
if [ "${TRK_DRY:-0}" = 1 ]; then ca_log "$KEY close: dry run: no close sent"; finish; fi

# ── 4. the close ─────────────────────────────────────────────────────────────
BODY=$(mktemp "${TMPDIR:-/tmp}/ca-close-body.XXXXXX") || fail local "mktemp failed"
ANS=$(mktemp "${TMPDIR:-/tmp}/ca-close-answer.XXXXXX") || { rm -f "$BODY"; fail local "mktemp failed"; }
trap 'rm -f "$BODY" "$ANS"' EXIT
jq -nc --arg r "$STATE" --argjson pr "$PR" --arg h "$HEAD" '{reason: $r, prNumber: $pr, headSha: $h}' > "$BODY" || fail local "the close body could not be built"
CODE=$(ca_board_close "$TRK_BOARD_BASE/tickets/$TID/approval-requests/$RID/close" "$BODY" "client-approval-close:$PROJ:$PR:$RID" "$TIMEOUT_S" "$ANS")
case "$CODE" in
  2[0-9][0-9]|409)
    mset --arg h "$CODE" --arg r "$STATE" --argjson c "$(date -u +%s)" '.close = "closed" | .close_last_http = $h | .close_reason = $r | .closed_at = $c'
    save
    ca_log "closed $KEY request=$RID ($STATE, HTTP $CODE)"
    ;;
  404)
    mset --argjson c "$(date -u +%s)" '.close = "gone" | .close_last_http = "404" | .close_reason = "gone" | .closed_at = $c'
    save
    ca_log "$KEY close: the board holds no open request $RID (404): nothing owed"
    ;;
  *)
    fail "$CODE" "the board answered HTTP $CODE" ;;
esac

# ── 5. the hub row ───────────────────────────────────────────────────────────
hub_closed
finish
