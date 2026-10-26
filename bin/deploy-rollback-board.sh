#!/bin/bash
# gh-rest: no-graphql
# bin/deploy-rollback-board.sh <project> <revert-pr-url> <reason> <members-file>
# — a deploy-train revert reopens the ticket it rolled back (BH-4915).
#
# bin/deploy-train.sh calls this once it has opened and enqueued an automatic
# rollback PR. At that moment production is known not to serve the batch, so
# every reverted merge that maps back to a ticket gets, in this order:
#   1. ONE comment on the ticket naming the revert PR, the merge PR (when the
#      build's RESULT has one) and the train's reason;
#   2. a status move out of done: `in_progress` on an in-app board, `open`
#      (reopen) on GitHub Issues;
#   3. one `deploy_rollback` ledger row, which the daily digest lists under
#      Tripwires. That row is the flag: nothing re-queues a build.
# Comment first, move second, never the reverse (bin/board-closeout.sh's rule):
# a ticket is never moved without the comment that says why.
#
# <members-file> is one `<merge sha>\t<build dir>` line per reverted merge.
# A build dir with no job.json (merge-queue, self-sourced) has no ticket: it
# gets a `flagged` row keyed "<project> <sha8>" and no tracker call.
#
# EXACTLY ONCE per (project, KEY, merge sha). The batch stays queued after a
# rollback, so the next departure can fail and roll back the same merges again.
# Two stores say "already handled": a local marker under
# state/deploy-rollback/<project>/, written the moment the comment is delivered,
# and the ledger row (fleet-visible; a worker outage leaves the marker alone to
# decide). A `comment-failed` row is the one status that is retried.
#
# Ledger statuses: reopened | commented-unmoved | comment-failed | flagged
# (no ticket) | flagged-unsupported (a tracker this does not write: jira,
# linear) | flagged-unconfigured (no board base or token).
#
# Always exits 0 once the arguments are there (2 without them): the train's own
# outcome never depends on this.
set -uo pipefail
PROJECT="${1:-}"; REVERT="${2:-}"; REASON="${3:-}"; MEMBERS="${4:-}"
if [ -z "$PROJECT" ] || [ -z "$REVERT" ] || [ -z "$REASON" ] || [ -z "$MEMBERS" ]; then
  echo "usage: deploy-rollback-board.sh <project> <revert-pr-url> <reason> <members-file>" >&2
  exit 2
fi
HARNESS="${HARNESS:-/root/harness}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "$(STAMP) [$PROJECT] deploy-rollback-board: $*"; }
MAX=20
MDIR="$HARNESS/state/deploy-rollback/$PROJECT"
PR_RE='https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+'

# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
set -uo pipefail
# shellcheck source=bin/lib/tracker.sh
. "$HARNESS/bin/lib/tracker.sh" 2>/dev/null || { say "bin/lib/tracker.sh is missing — nothing done"; exit 0; }
# shellcheck source=bin/lib/gh-token-live.sh
. "$HARNESS/bin/lib/gh-token-live.sh" 2>/dev/null || true

[ -r "$MEMBERS" ] || { say "members file $MEMBERS is unreadable — nothing done"; exit 0; }
TOTAL=$(grep -c . "$MEMBERS" 2>/dev/null); TOTAL="${TOTAL:-0}"
[ "$TOTAL" -le "$MAX" ] || say "$TOTAL reverted merges, only the first $MAX are handled; the rest get no comment and no row"

# ledger_put <key> <status> <detail json> — fail-open: a failed put is a log line.
ledger_put() {
  if ! command -v job_ledger_put >/dev/null 2>&1; then say "no jobs client — $1 $2 not recorded"; return 0; fi
  job_ledger_put deploy_rollback "$1" "$2" "$3" >/dev/null 2>&1 || say "ledger put failed for '$1' ($2)"
  return 0
}
# ledger_handled <key> — rc 0 when a row says this merge was already handled
# (any status but comment-failed). rc 1 for no row, a retryable row, or a
# worker that did not answer (logged; the marker decides then).
ledger_handled() {
  local s rc=0
  command -v job_ledger_get >/dev/null 2>&1 || return 1
  s=$(job_ledger_get deploy_rollback "$1" 2>/dev/null) || rc=$?
  case "$rc" in
    0) [ "$s" != comment-failed ] ;;
    2) return 1 ;;
    *) say "ledger read for '$1' did not answer (rc=$rc) — the local marker decides"; return 1 ;;
  esac
}
detail() { # detail <key> <ticket_id> <sha> <merge_pr> [<extra json>]
  local x="${5:-}"
  [ -n "$x" ] || x='{}'
  jq -nc --arg p "$PROJECT" --arg k "$1" --arg t "$2" --arg s "$3" --arg m "$4" \
    --arg r "$REVERT" --arg why "$REASON" --argjson x "$x" \
    '{project:$p, key:$k, ticket_id:$t, sha:$s, merge_pr:$m, revert_pr:$r, reason:$why} + $x' 2>/dev/null || echo '{}'
}
esc() { printf '%s' "${1:-}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
link() { printf '<a href="%s">%s</a>' "$(esc "$1")" "$(esc "$1")"; }

# write_body <adapter> <merge_pr> <file> — fixed copy, no LLM. The last line is
# INTENT ("We're moving…"), never a result: the move can still be refused, and
# the ledger records which one happened.
write_body() {
  local a="$1" m="$2" f="$3" p2 p4
  if [ "$a" = board ]; then
    if [ -n "$m" ]; then p2="The merge ($(link "$m")) went in, but production never started serving it: $(esc "$REASON")."
    else p2="The change was merged, but production never started serving it: $(esc "$REASON")."; fi
    p4="We're moving the ticket back to in progress and flagging it in the daily factory report so it gets picked up again."
    printf '<p>We had to roll this one back.</p><p>%s</p><p>The deploy train reverted it in %s, so this change is not live.</p><p>%s</p>' \
      "$p2" "$(link "$REVERT")" "$p4" > "$f"
  else
    if [ -n "$m" ]; then p2="The merge ($m) went in, but production never started serving it: $REASON."
    else p2="The change was merged, but production never started serving it: $REASON."; fi
    p4="We're reopening this issue and flagging it in the daily factory report so it gets picked up again."
    printf 'We had to roll this one back.\n\n%s\n\nThe deploy train reverted it in %s, so this change is not live.\n\n%s\n' \
      "$p2" "$REVERT" "$p4" > "$f"
  fi
}

ADAPTER=""; ADAPTER_OK=""; TARGET_STATUS=""
# _drb_context — resolve the tracker once, on the first mapped member.
# Prints nothing; sets ADAPTER_OK to yes, or to the flag status to record. The
# context itself (<app base><board prefix> and the internal token on a board,
# the repo slug on GitHub) is bin/lib/tracker.sh's tracker_context, the one
# every caller uses.
_drb_context() {
  [ -n "$ADAPTER_OK" ] && return 0
  ADAPTER=""
  tracker_kind "$PROJECT" >/dev/null 2>&1 && ADAPTER=$(tracker_kind "$PROJECT" 2>/dev/null)
  case "$ADAPTER" in
    board|github-issues) ;;
    *) ADAPTER_OK=flagged-unsupported; say "tracker '${ADAPTER:-unknown}' is not one this writes — flag only"; return 0 ;;
  esac
  TRK_LOG="$HARNESS/logs/deploy-rollback-board.log"; TRK_ERR="$TRK_LOG"
  if [ "$ADAPTER" = board ]; then TARGET_STATUS=in_progress; else TARGET_STATUS=open; fi
  if ! tracker_context "$PROJECT" deploy-rollback-board 2>/dev/null; then
    case "${TRK_CTX_MISSING:-}" in
      base|token) ADAPTER_OK=flagged-unconfigured; say "no board base or internal token for $PROJECT — flag only" ;;
      slug) ADAPTER_OK=flagged-unconfigured; say "no repo slug for $PROJECT — flag only" ;;
      *) ADAPTER_OK=flagged-unsupported; say "tracker adapter $ADAPTER did not load — flag only" ;;
    esac
    return 0
  fi
  if [ "$ADAPTER" = github-issues ] && [ -z "${GH_TOKEN:-}" ] && command -v gh_token_live >/dev/null 2>&1; then
    gh_token_live "$TRK_SLUG" || true
  fi
  ADAPTER_OK=yes
}

BODY=$(mktemp "${TMPDIR:-/tmp}/deploy-rollback-board.XXXXXX") || { say "cannot make a temp file — nothing done"; exit 0; }
trap 'rm -f "$BODY"' EXIT
N=0
while IFS=$'\t' read -r SHA BD || [ -n "${SHA:-}" ]; do
  [ -n "$SHA" ] || continue
  N=$((N+1)); [ "$N" -le "$MAX" ] || break
  S8="${SHA:0:8}"
  TID=""; KEY=""
  if [ -n "$BD" ] && [ "$BD" != "-" ] && [ -r "$BD/job.json" ]; then
    TID=$(jq -r '.ticket_id // "" | tostring' "$BD/job.json" 2>/dev/null) || TID=""
    KEY=$(jq -r '.key // "" | tostring' "$BD/job.json" 2>/dev/null) || KEY=""
  fi
  if ! [[ "$TID" =~ ^[A-Za-z0-9_.:-]+$ ]] || ! [[ "$KEY" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    LKEY="$PROJECT $S8"
    if ledger_handled "$LKEY"; then say "$S8 (no ticket) already flagged"; continue; fi
    ledger_put "$LKEY" flagged "$(detail "" "" "$SHA" "" "$(jq -nc --arg b "${BD:-}" '{build_dir:$b}')")"
    say "$S8 was reverted in $REVERT but maps to no ticket (build dir '${BD:-}') — flagged for the daily report"
    continue
  fi
  LKEY="$PROJECT $KEY@$S8"; MARK="$MDIR/$KEY-${SHA:0:12}"
  if [ -e "$MARK" ]; then say "$KEY ($S8) already handled (marker)"; continue; fi
  if ledger_handled "$LKEY"; then say "$KEY ($S8) already handled (ledger)"; continue; fi
  MERGE_PR=$(grep -ohE "$PR_RE" "$BD/RESULT" 2>/dev/null | head -1)
  _drb_context
  if [ "$ADAPTER_OK" != yes ]; then
    ledger_put "$LKEY" "$ADAPTER_OK" "$(detail "$KEY" "$TID" "$SHA" "$MERGE_PR")"
    continue
  fi
  write_body "$ADAPTER" "$MERGE_PR" "$BODY"
  CRC=0; tracker_comment "$TID" "$BODY" >/dev/null 2>&1 || CRC=$?
  if [ "$CRC" != 0 ]; then
    ledger_put "$LKEY" comment-failed "$(detail "$KEY" "$TID" "$SHA" "$MERGE_PR" "$(jq -nc --argjson rc "$CRC" '{rc:$rc}')")"
    say "$KEY: the comment was refused (rc=$CRC) — not moved, retried on the next rollback of $S8"
    "$HARNESS/bin/alert-line.sh" --id "deploy-rollback-$PROJECT-$KEY" --project "$PROJECT" \
      "[$PROJECT] DEPLOY ROLLBACK: $KEY was reverted in $REVERT but the comment on the ticket failed (rc=$CRC) — the ticket still reads done; comment and move it by hand, or the next failing departure retries" >/dev/null 2>&1 || true
    continue
  fi
  mkdir -p "$MDIR" && printf '%s %s\n' "$(STAMP)" "$REVERT" > "$MARK" \
    || say "$KEY: commented, but the marker $MARK could not be written"
  STATUS=reopened
  tracker_transition "$TID" "$TARGET_STATUS" >/dev/null 2>&1 || STATUS=commented-unmoved
  ledger_put "$LKEY" "$STATUS" "$(detail "$KEY" "$TID" "$SHA" "$MERGE_PR")"
  if [ "$STATUS" = reopened ]; then say "$KEY: commented and moved to $TARGET_STATUS (revert $REVERT)"
  else say "$KEY: commented, but the move to $TARGET_STATUS did not take — left where it is"; fi
done < "$MEMBERS"
exit 0
