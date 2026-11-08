#!/bin/bash
# bin/archie-merge.sh — BH-9212: the ONE way Archie merges. It checks every gate
# on the exact head sha, asks Mergify to queue the PR, and writes one audit row.
# Archie's soul (prompts/archie-soul.d/10-authority.md) names this script as its
# only merge path; the gates live here, not in the prompt.
#
#   archie-merge.sh <project> <owner/repo>#<n> <head40> --reason <text>
#   archie-merge.sh reverted <owner/repo>#<n> --why <text>
#
# MERGE. The first gate that refuses ends the run with one line
#   ARCHIE-MERGE HOLD <slug>#<n> <head12> gate=<word> <detail>        rc 3
#   ARCHIE-MERGE UNREADABLE <slug>#<n> <head12> gate=<word> <detail>  rc 75
# Gates, in order:
#   usage       head is 40 hex, the slug is the project's repo, --reason given (rc 2)
#   authority   settings archie.merge.authority is exactly `merge`. No row, any
#               other value, or an unproven row (409) = ask-first (HOLD).
#               Only the operator's human token sets `merge` (the worker refuses a
#               bearer PUT of any value but `ask_first`, BH-9212).
#   kill-switch flags merge-conductor-merge/-actions down, automerge-disabled,
#               automerge-disabled-<p>, paused-<p>, merge-conductor-observe,
#               or a fleet/project merges pause (afq_merges_on)
#   no-mergify  the repo has no Mergify queue
#   lock        the conductor holds this PR's lock (-n, never waits)
#   state, head-moved, mergeable  one uncached pulls read: open, not a draft,
#               head == <head40>, project base, mergeable_state exactly clean
#   queued      Mergify already witnesses the head, or the tier-2 ledger asked
#               on it: ARCHIE-MERGE ALREADY, rc 0, nothing written
#   hold        a hold label, the conductor's READY gates (afq_conductor_gates),
#               a HOLD on the PR thread (_ae_pr_hold)
#   main-red    main_red_hold
#   verdict     a standing head-bound MERGE / MERGE-WITH-NOTES (afq_approved)
#   checks      each required check's newest run completed and green
#   iron-law    the added-lines scan is clean, or ila_accepted for this head
#   cap         the archie.cap.queue-enqueue day cap has room
# Then write -> send -> confirm: an archie_actions row (playbook queue-enqueue,
# key archie-merge:<slug>#<n>:<head40>, evidence {source: "archie-merge", repo,
# pr, head, verdict_id, check_run_ids, reason}) is claimed BEFORE the send (a
# claim that fails sends nothing: gate=audit, rc 75; a row that already exists
# for this head: ARCHIE-MERGE ALREADY gate=audit, rc 0, nothing sent). Then
# mc_enqueue_mergify; rc 0/2 closes the row done and prints ARCHIE-MERGE
# QUEUED (rc 0; Mergify lands it, so the rung is "queued for merge");
# anything else closes it failed and exits 1.
#
# REVERTED sets the settings row archie.merge.authority to ask_first
# (setting_set, note "<iso> reverted <slug>#<n> <why>"). Every merge then
# answers HOLD gate=authority. No verb of this script writes `merge`: the operator
# gives the authority back with his own token (bin/protected-setting.sh
# archie.merge.authority merge). A settings write that fails prints
# ARCHIE-MERGE UNREADABLE and exits 75; the row is then unchanged.
#
# Every run writes one line to logs/archie-merge.log. Exit codes: 0 QUEUED,
# ALREADY or reverted; 1 a lib is missing or the send failed; 2 usage;
# 3 HOLD; 75 UNREADABLE (a read or the settings write failed).
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
SELF="$(cd "$(dirname "$0")" && pwd)"
AM_LOG="$H/logs/archie-merge.log"
mkdir -p "$H/logs" 2>/dev/null

usage() {
  echo "usage: archie-merge.sh <project> <owner/repo>#<n> <head40> --reason <text>" >&2
  echo "       archie-merge.sh reverted <owner/repo>#<n> --why <text>" >&2
  exit 2
}
am_line() { printf '%s\n' "$*"; printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$AM_LOG" 2>/dev/null; return 0; }

# ── argument parse: nothing is read before the arguments are good ────────
VERB=merge
if [ "${1:-}" = reverted ]; then
  VERB=reverted; PRK="${2:-}"; WHY=""
  [ $# -eq 4 ] && [ "${3:-}" = --why ] && WHY="${4:-}"
  [[ $PRK =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]] && [ -n "$(tr -d '[:space:]' <<<"$WHY")" ] || usage
  WHY=$(printf '%s' "$WHY" | tr '\t\n' '  ')
else
  [ $# -eq 5 ] && [ "$4" = --reason ] || usage
  P="$1"; PRK="$2"; HEAD="$3"; REASON="$5"
  [[ $PRK =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] || usage
  SLUG="${BASH_REMATCH[1]}"; N="${BASH_REMATCH[2]}"
  [[ $HEAD =~ ^[0-9a-f]{40}$ ]] || { echo "archie-merge: the head must be a full 40-hex sha, got '$HEAD'" >&2; exit 2; }
  [ -n "$(tr -d '[:space:]' <<<"$REASON")" ] || usage
  PSLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null)
  [ "$PSLUG" = "$SLUG" ] || { echo "archie-merge: $P's repo is '${PSLUG:-unknown}', not $SLUG" >&2; exit 2; }
  URL="https://github.com/$SLUG/pull/$N"
fi

. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# The libs, in the order bin/archie-fm-queue.sh sources them. A lib that does
# not source is a missing lib: one line, rc 1.
am_nolib() { am_line "ARCHIE-MERGE ERROR $PRK: $1 did not source (a lib is missing)"; exit 1; }
# shellcheck disable=SC1091
{
  . "$SELF/jobs-client.sh" || am_nolib jobs-client.sh
  . "$SELF/lib/jobs/settings.sh" || am_nolib lib/jobs/settings.sh
  . "$SELF/lib/gh-rest.sh" || am_nolib lib/gh-rest.sh
  . "$SELF/lib/merge-conductor-lib.sh" || am_nolib lib/merge-conductor-lib.sh
  . "$SELF/lib/ticket-ownership.sh" || am_nolib lib/ticket-ownership.sh
  . "$SELF/lib/pause.sh" || am_nolib lib/pause.sh
  . "$SELF/lib/autoenqueue.sh" || am_nolib lib/autoenqueue.sh
  . "$SELF/lib/hold.sh" || am_nolib lib/hold.sh
  . "$SELF/lib/ironlaw-carry.sh" || am_nolib lib/ironlaw-carry.sh
  . "$SELF/lib/main-red-gate.sh" || am_nolib lib/main-red-gate.sh
  . "$SELF/lib/archie-fm.sh" || am_nolib lib/archie-fm.sh
  . "$SELF/lib/archie-fm-queue/common.sh" || am_nolib lib/archie-fm-queue/common.sh
  . "$SELF/lib/archie-fm-queue/enqueue.sh" || am_nolib lib/archie-fm-queue/enqueue.sh
  . "$SELF/lib/archie-merge.sh" || am_nolib lib/archie-merge.sh
}
# The suite's seam. Sandbox only.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_MERGE_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_MERGE_FIXTURE"
fi

# ── reverted: the authority row goes back to ask_first ───────────────────────
if [ "$VERB" = reverted ]; then
  command -v setting_set >/dev/null 2>&1 || { am_line "ARCHIE-MERGE ERROR reverted $PRK: setting_set is not defined (a lib is missing)"; exit 1; }
  rc=0; setting_set archie.merge.authority ask_first "$(date -u +%FT%TZ) reverted $PRK $WHY" || rc=$?
  if [ "$rc" != 0 ]; then
    am_line "ARCHIE-MERGE UNREADABLE reverted $PRK: the settings row archie.merge.authority was not written (rc $rc); it is unchanged; tell the operator ($WHY)"
    exit 75
  fi
  am_line "ARCHIE-MERGE reverted $PRK: archie.merge.authority=ask_first; merges are ask-first until the operator sets it to merge with his token ($WHY)"
  exit 0
fi

for f in setting_get _jobs_req gh_rest gh_rest_var mc_init mc_pr_lock mc_project_base mc_queue_provider \
         mc_mergify_witness mc_enqueue_mergify mc_pr_diff mc_iron_law_scan vd_standing ila_accepted main_red_hold \
         to_lane_hold pdg_hold to_lane_lead_fence bg_scan hold_check_thread _ae_pr_hold _ae_required_checks \
         afm_close afq_claim afq_close afq_cap_ok afq_merges_on afq_flag afq_provider afq_pr_fresh afq_pr_lock \
         afq_pr_unlock afq_approved afq_conductor_gates am_gates am_authority am_checks am_iron_law am_audit_claim; do
  command -v "$f" >/dev/null 2>&1 || { am_line "ARCHIE-MERGE ERROR $PRK ${HEAD:0:12}: $f is not defined (a lib is missing)"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { am_line "ARCHIE-MERGE ERROR $PRK ${HEAD:0:12}: jq missing"; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_MERGE_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$ARCHIE_MERGE_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
DAY=$(date -u -d "@$NOW" +%F)
# The queue doctor's globals that afq_claim / afq_cap_ok read. The row's actor
# stays archie-fm-queue (AFQ_ACTOR) so its started-row sweep closes a row a
# dead run left.
AFM_LOG="$AM_LOG"; AFM_ROW=""; AFM_ROUTE_ABSENT=0
# The stale-row age is the queue doctor's knob ARCHIE_FMQ_RETRY_S
# (catalog/lanes.d/archie-fm-queue.json); 1800 is that knob's documented
# fallback, and a value outside 60..86400 is the fallback, as there.
AFQ_RETRY_S=${ARCHIE_FMQ_RETRY_S:-1800}
if ! [[ $AFQ_RETRY_S =~ ^[0-9]+$ ]] || [ "$((10#$AFQ_RETRY_S))" -lt 60 ] || [ "$((10#$AFQ_RETRY_S))" -gt 86400 ]; then
  am_line "ARCHIE-MERGE WARN ARCHIE_FMQ_RETRY_S=$AFQ_RETRY_S is outside 60..86400; using the fallback 1800"
  AFQ_RETRY_S=1800
fi
export NOW DAY

hold()  { am_line "ARCHIE-MERGE HOLD $PRK ${HEAD:0:12} gate=$1${2:+ $2}"; exit 3; }
unread() { am_line "ARCHIE-MERGE UNREADABLE $PRK ${HEAD:0:12} gate=$1${2:+ $2}"; exit 75; }

# authority: the one row the operator signs. Read first, so an ask-first box reads nothing else.
rc=0; am_authority || rc=$?
case "$rc" in 0) ;; 75) unread authority "$AM_DETAIL" ;; *) hold authority "$AM_DETAIL" ;; esac
afq_merges_on "$P" || hold kill-switch "merges are off, observed or paused (flags or a merges pause)"
afq_flag "automerge-disabled-$P" && hold kill-switch "flags/automerge-disabled-$P"
afq_flag "paused-$P" && hold kill-switch "flags/paused-$P"
PROV=$(afq_provider "$SLUG")
[ "$PROV" = mergify ] || hold no-mergify "the queue provider of $SLUG is '${PROV:-none}'; ask the operator"

mc_init
afq_pr_lock "$P" "$N" || hold lock "the merge conductor holds this PR's lock"
trap 'afq_pr_unlock' EXIT

rc=0; am_gates "$P" "$SLUG" "$N" "$HEAD" || rc=$?
case "$rc" in
  0) ;;
  4) am_line "ARCHIE-MERGE ALREADY $PRK ${HEAD:0:12} gate=$AM_GATE $AM_DETAIL"; exit 0 ;;
  75) unread "$AM_GATE" "$AM_DETAIL" ;;
  *) hold "$AM_GATE" "$AM_DETAIL" ;;
esac

# ── write -> send -> confirm ─────────────────────────────────────────────────
EV=$(jq -nc --arg repo "$SLUG" --argjson pr "$N" --arg h "$HEAD" --argjson v "$AM_VERDICT_ID" --arg vw "$AM_VERDICT" \
  --arg ids "$AM_RUN_IDS" --arg r "$REASON" --arg req "$AM_REQ" --arg il "$AM_IL" \
  '{source: "archie-merge", repo: $repo, pr: $pr, head: $h, verdict_id: $v, verdict: $vw,
    check_run_ids: ($ids | split(",") | map(select(length > 0) | tonumber)),
    required_checks: ($req | split("\n") | map(select(length > 0))), iron_law: $il, reason: $r}') \
  || unread audit "the evidence did not build"
KEY="archie-merge:$SLUG#$N:$HEAD"
rc=0; am_audit_claim "$KEY" "$P" "$SLUG" "$N" "$REASON" "$EV" || rc=$?
case "$rc" in
  0) ;;
  4) am_line "ARCHIE-MERGE ALREADY $PRK ${HEAD:0:12} gate=audit $AM_DETAIL"; exit 0 ;;
  *) unread audit "$AM_DETAIL" ;;
esac
erc=0; OUT=$(mc_enqueue_mergify "$SLUG" "$URL" "$HEAD" 2>&1) || erc=$?
OUT=$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-400)
case "$erc" in
  0|2)
    afq_close queue-enqueue "done" enqueue "archie-merge: asked Mergify to queue (mc_enqueue_mergify rc $erc)" \
      "$(jq -c --argjson rc "$erc" '. + {enqueue_rc: $rc}' <<<"$EV")" \
      || am_line "ARCHIE-MERGE WARN $PRK ${HEAD:0:12}: the row did not close done; the queue doctor's sweep closes it"
    am_line "ARCHIE-MERGE QUEUED $PRK ${HEAD:0:12} verdict=$AM_VERDICT#$AM_VERDICT_ID checks=$AM_RUN_IDS (queued for merge; Mergify lands it)"
    exit 0 ;;
  *)
    afq_close queue-enqueue failed "" "archie-merge: mc_enqueue_mergify rc $erc: ${OUT:-no reason given}" \
      "$(jq -c --argjson rc "$erc" --arg o "$OUT" '. + {enqueue_rc: $rc, answer: $o}' <<<"$EV")" || true
    am_line "ARCHIE-MERGE FAILED $PRK ${HEAD:0:12} mc_enqueue_mergify rc $erc: ${OUT:-no reason given}; not retried on this head"
    exit 1 ;;
esac
