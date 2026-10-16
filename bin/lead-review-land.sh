#!/bin/bash
# bin/lead-review-land.sh — BH-1951 (BH-1525.3): the hub half of the lead
# review job. Every 15 minutes (cron/lanes/715-lead-review-land.cron; a
# backstop: lead-review rings it through the wakes doorbell, bin/wake-loop.sh's
# lead-land arm) it turns each finished lead review request into the verdict
# row the merge lanes read, and says out loud when a request is stuck. NO agent
# call, NO SSH.
#
#   list     lr_get ?status=done,failed,requested,running&promoted=0 — ONE call
#            (bin/lib/lead-reviews.sh). rc 75 (the route is not deployed) or any
#            other failure = one log line, exit 0, next tick asks again. A
#            `truncated:true` answer = one ALERTS line per UTC day: the list is
#            capped at 100 and something past the cap is not being looked at.
#   promote  each `done` row with a verdict in LR_VERDICT_WORDS and no
#            promoted_verdict_at (re-checked here, so an older worker that
#            ignores promoted=0 is still safe):
#              1. GET /api/verdicts?repo=&pr=&head= — a `source=lead` row on
#                 THAT head whose note carries the token `lead-review:<id>` and
#                 this job's `lead-job:<job>` (see RE-LANDING) means an earlier
#                 tick posted it and lost the stamp: skip the post.
#                 A failed read skips this request this tick (never post blind).
#              1b. BH-5023: a row whose requested_by starts `inbuild:` was filed
#                 by a build for its own head with the bearer alone. It is
#                 promoted only when job_verdict <pr url> is APPROVE with
#                 reviewed_sha == <head>, or job_verdict_headbound is
#                 reapproved@<head>; the note then also carries
#                 `inbuild:<box>`. No such approval = no post, no stamp, ONE
#                 critical lane-alert (lead-inbuild-noapprove-<id>), and the
#                 next tick checks again. An unreadable ledger = next tick.
#              2. bin/lead-verdict.sh post … --source lead --reviewer box:<box>
#                 --note "lead-review:<id>[ lead-job:<job>][ supersedes:<rowid>][ report:<ref>]"
#                 [--model <reviewer_model>]
#                 [--report-url <report_ref when https://>]. Non-zero = no stamp.
#                 BH-5773: a post that answered 503 is retried in this tick after
#                 2 s, 5 s and 10 s (LEAD_REVIEW_LAND_POST_RETRIES, 0..3, default
#                 3), each after a re-read of the row: a row found is the rc 4
#                 arm, an unreadable re-read stops. One request that uses every
#                 retry makes the rest of the tick post once.
#              3. POST /api/lead-reviews/<id>/promoted (lr_post_lead). A failure
#                 is logged; next tick finds the row from step 1 and only stamps.
#              2b. BLOCK only, once the row is recorded (post rc 0/4, or an
#                 earlier tick's row found in step 1): the lead report goes to
#                 the PR as a REQUEST_CHANGES review bound to <head>, under the
#                 hub's default gh identity (bin/lib/gh-rest.sh; the App, so
#                 cromford[bot]/NONE), which the resolver's br_lead_pick
#                 briefs a fix round from since BH-3780 (lrl_findings). Its body
#                 opens with `<!-- lead-review:<id> -->`, then one framing line,
#                 then the lead_review_report artifact's body when its header
#                 names this repo#pr at <head> (plus a pointer to the whole
#                 report when it is truncated), else a `Full report: <ref> on
#                 box <box>` line. Deduped by state/lead-review-land/findings-<id>
#                 and by that marker in the PR's reviews, read before any POST.
#                 A 422 is re-posted ONCE as a COMMENT plus one warn
#                 (lead-block-nobrief-<id>): a COMMENT briefs no fix round.
#                 An unread reviews list, an unreadable jobs worker or a failed
#                 POST = no stamp, next tick retries.
#                 BH-3780, before that POST (lrl_block_route): the ticket is
#                 the project whose fleet.conf repo is <repo>, on an issues
#                 board, and the issue in the PR branch ticket/<KEY>-<n>.
#                 A `- [BLOCK needs-human]` line places the BH-3443 hold
#                 (bin/needs-human-hold.sh ... lead-review) and the review is
#                 posted, which briefs no round (br_lead_pick refuses it); with
#                 no ticket to hold, ONE warn alert-line (lead-nh-<id>) says no
#                 round will run. Otherwise the sorted `- [BLOCK]` lines are
#                 fingerprinted (nh_fingerprint) and counted per head in the
#                 review_block_fp ledger (nh_trip_note, id
#                 lead:<repo>#<pr>@<head>); at the needs-human trip count the
#                 hold is placed FIRST, its one ask carrying the finding, then
#                 the review is posted. A placer that cannot read the thread
#                 (rc 75) = nothing posted, nothing stamped, next tick retries.
#                 BH-6090, before the route and the POST: when the body is this
#                 head's whole report (not truncated, not the `Full report:`
#                 pointer) and has no line starting `- [BLOCK`, no review is
#                 posted. One ALERTS line (emptyblock-<id>, once per reset) says
#                 so, and the request is stamped; an ALERTS append that fails
#                 is no stamp.
#              2a-flip. BH-6391: when the request's scope_notes carry a
#                 `lead-prev:` group (bin/lib/lead-prev.sh) with own-commits:0
#                 and the verdict class (BLOCK vs MERGE/MERGE-WITH-NOTES)
#                 differs from its word: ONE log line `flip <repo>#<pr> <G12>
#                 <W> -> <H12> <V> own-commits:0 request:<id>`, deduped by
#                 state/lead-review-land/flip-<id>. A measurement only: it
#                 gates no post, no stamp and no counter.
#              2c. MERGE / MERGE-WITH-NOTES recorded on THIS tick (post rc 0/4)
#                 and LEAD_REVIEW_SPOTCHECK_PCT (0..100, 0 = off; anything else
#                 is logged and off) above cksum("<repo>#<pr>@<head>") % 100:
#                 one warn lane-alert beat, lead-spotcheck-<id> (lrl_spotcheck).
#                 The same heads are sampled on every rerun; it gates nothing.
#              2d. MERGE / MERGE-WITH-NOTES recorded (now or on an earlier tick)
#                 and a lead BLOCK row on another head of the PR: every standing
#                 CHANGES_REQUESTED review whose body carries a
#                 `<!-- lead-review:` marker, whose author is this lane's bot
#                 (BH-5213, bin/lib/lead-stale-review.sh) and whose commit_id is
#                 not <head> is dismissed (PUT .../reviews/<id>/dismissals, same
#                 identity, the message naming both heads and the verdict row), so
#                 Mergify's #changes-requested-reviews-by=0 lets the fixed PR back
#                 into the queue (lrl_dismiss). A person's review is never
#                 touched. A failed read or dismissal = no stamp, next tick
#                 retries; a PR that has left <head> dismisses nothing.
#              In 2b and 2d the PR's live head is read first: once the PR has
#              left <head> (a stamp-only retry after a push), nothing is posted
#              or dismissed, and the request is stamped, as post rc 3 is.
#            Row first, findings second, stamp last: "stamped without a row"
#            and "a BLOCK stamped without its findings on the PR" cannot happen.
#            The row is bound to the head the review READ, whatever the PR's
#            live head is now, so it can never stand on a newer push.
#            BH-3683: post exit 5 = the row is recorded as advice and the
#            lead-verdict status is WITHHELD (a protected path, a revoked lane
#            authority, or an undecidable one; bin/lib/lead-authority.sh). It is
#            a promotion: steps 2b/2d and the stamp run as for rc 0, 2c does not
#            (a human reads that head anyway), and one warn beat per head asks
#            for the human verdict that publishes it (la_human_needed). A beat
#            that could not be sent leaves the request unstamped, and the next
#            tick's stamp-only pass (step 1 found the `authority:human-required`
#            row) asks again. This lane never posts a human row itself.
#   ring     BH-4057: a MERGE / MERGE-WITH-NOTES recorded (post rc 0/4, or the
#            row found in step 1 and not withheld) rings the merge conductor
#            for that PR right before the stamp: kw_conductor
#            (bin/lib/keyed-wake.sh), the keyed tick, deduped per PR by its
#            MC_KEYED_WAKE_MIN_S stamp. BLOCK, rc 3 and a withheld row (rc 5 or
#            authority:human-required) never ring. `conductor rung` per launch,
#            `rung=` in the summary. MC_KEYED_WAKE=0 turns it off; the
#            conductor's cron tick stays the backstop.
#   rerun    a tick refused by the tick lock leaves state/lead-review-land/
#            rerun-owed, and the tick holding the lock reruns this script once,
#            detached, after its summary line (lcw_rerun,
#            bin/lib/lead-chain-wake.sh), bounded by LEAD_REVIEW_LAND_RERUN_MAX
#            (unset or 0 = off, marker kept for a later tick).
#   alert    ONE ALERTS line per request that is `failed`, or still `requested`
#            / `running` LEAD_REVIEW_OVERDUE_MIN minutes after reset_at (else
#            created_at), deduped by state/lead-review-land/alerted-<id>, which
#            holds r<reset_count> (written only after the append succeeded; an
#            empty legacy flag is r0), so a reset request alerts once again.
#
# RE-LANDING (BH-5400). A request can be reset and reviewed again, by a new job
# (bin/lead-review.sh mints one per run). "Already landed" is therefore keyed on
# (request id, job id), never on the id alone: the row note carries
# `lead-job:<job>`, the findings review carries `<!-- lead-job:<job> -->` on its
# line 2, and the findings / dismissed / superseded / nh / trip flags hold the
# job. A landing with no job token (made before BH-5400) or an empty flag counts
# as this result only while reset_count is 0. A newer result is landed in full:
# its row (note `supersedes:<rowid>` of the earlier landing; the newest lead row
# stands) and its lead-verdict status; on MERGE the earlier landing's
# CHANGES_REQUESTED on the same head is dismissed with the older-commit ones; on
# BLOCK the new findings are posted FIRST and only then are the earlier
# landing's reviews of this request dismissed (state/.../superseded-<id>), so a
# BLOCK head always has a standing review. The stamp sends {"job_id":<job>}; a
# 409 (the request was reset and claimed again meanwhile) is logged and not
# counted, and the next tick lands the newer result.
#
# The lead token (LEAD_VERDICT_TOKEN_FILE, the file bin/lead-verdict.sh reads)
# is required: without it no lead row can be written, so the tick writes ONE
# ALERTS line per UTC day naming the file and does nothing else.
# Hub only (the mirror of bin/lead-review.sh's guard). Kill switch:
# flags/lane-off-lead-review-land. Log: logs/lead-review-land.log.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165). Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off lead-review-land.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lead-review-land
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lead-review-land

LOG="$H/logs/lead-review-land.log"
ALERTS="$H/logs/ALERTS.log"
STATE="$H/state/lead-review-land"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) $*" >> "$LOG"; }

# shellcheck source=bin/lib/hub-box.sh
. "$H/bin/lib/hub-box.sh" 2>/dev/null || { log "missing bin/lib/hub-box.sh; lead-review-land tick skipped"; exit 0; }
BOX=$(local_box_name)
if ! is_hub_box "$BOX"; then log "not the hub (${BOX:-unnamed}); lead-review-land runs on the hub only"; exit 0; fi

# jobs-client.sh exits its caller on a missing module, so every piece is checked first.
for f in bin/jobs-client.sh bin/lib/jobs/req.sh bin/lib/lead-reviews.sh bin/lib/verdicts.sh bin/lib/gh-rest.sh bin/lead-verdict.sh bin/lib/lead-authority.sh; do
  [ -r "$H/$f" ] || { log "missing $f; lead-review-land tick skipped"; exit 0; }
done
# shellcheck source=/dev/null
{ . "$H/bin/jobs-client.sh"; . "$H/bin/lib/lead-reviews.sh"; . "$H/bin/lib/verdicts.sh"; . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/lead-authority.sh"; }
# BH-6391, fail-open: without it no flip line is logged; nothing else changes.
# shellcheck source=/dev/null
[ -r "$H/bin/lib/lead-prev.sh" ] && . "$H/bin/lib/lead-prev.sh" 2>/dev/null
# BH-3780, fail-open: without it a lead BLOCK is posted with no hold route (lrl_block_route).
# shellcheck source=/dev/null
[ -r "$H/bin/lib/needs-human.sh" ] && . "$H/bin/lib/needs-human.sh" 2>/dev/null
# BH-4057, fail-open: without them the conductor is not rung and no rerun is owed; the crons cover both.
# shellcheck source=/dev/null
[ -r "$H/bin/lib/keyed-wake.sh" ] && . "$H/bin/lib/keyed-wake.sh" 2>/dev/null
# shellcheck source=/dev/null
[ -r "$H/bin/lib/lead-chain-wake.sh" ] && . "$H/bin/lib/lead-chain-wake.sh" 2>/dev/null
# BH-5213: step 2d's own-review rule. Without it lrl_dismiss stamps nothing and retries.
# shellcheck source=/dev/null
[ -r "$H/bin/lib/lead-stale-review.sh" ] && . "$H/bin/lib/lead-stale-review.sh" 2>/dev/null

mkdir -p "$STATE" 2>/dev/null
# A tick dedupe, never a queue: a second tick while one runs skips and leaves rerun-owed for the holder.
exec 9>"$STATE/tick.lock"; flock -n 9 || { : > "$STATE/rerun-owed"; log "another tick holds $STATE/tick.lock; skipped (rerun owed)"; exit 0; }

# alert_once <flag> <line> [<generation>] — append the line to ALERTS.log, then
#   write the flag (holding <generation>, BH-5400: r<reset_count>).
#   rc 0 = alerted now; rc 1 = the flag was already there for this generation
#   (an empty flag is r0); rc 2 = the append failed (no flag written, so the
#   next tick tries again).
alert_once() {
  local gen="${3:-}" have
  if [ -e "$1" ]; then
    [ -z "$gen" ] && return 1
    have=$(cat "$1" 2>/dev/null)
    [ "$have" = "$gen" ] && return 1
    [ -z "$have" ] && [ "$gen" = r0 ] && return 1
  fi
  echo "$(STAMP) $2" >> "$ALERTS" 2>/dev/null || { log "could not append to $ALERTS: $2"; return 2; }
  printf '%s' "$gen" > "$1" 2>/dev/null || log "alerted but could not write $1; this may alert again"
  return 0
}

# lrl_flag_done <flag> — BH-5400: rc 0 when <flag> records THIS result (SJOB,
#   RESETS: the request being landed). It holds the job it was written for; an
#   empty flag (written before BH-5400) counts only while the request was never
#   reset, and a request with no job id keeps the old any-flag rule.
lrl_flag_done() {
  local have
  [ -e "$1" ] || return 1
  [ -n "$SJOB" ] || return 0
  have=$(cat "$1" 2>/dev/null)
  [ "$have" = "$SJOB" ] && return 0
  [ -z "$have" ] && [ "$RESETS" = 0 ]
}
# lrl_flag_set <flag> — write it for this result.
lrl_flag_set() { printf '%s' "$SJOB" > "$1" 2>/dev/null || log "could not write $1"; }

# lrl_pr_head <repo> <pr> — the PR's live head into LRL_HEAD, its branch into
# LRL_BRANCH. rc 1 = unread (GH_REST_STATUS says why). A plain command into a
# file, never $( ).
lrl_pr_head() {
  local f grc=0
  LRL_HEAD=""; LRL_BRANCH=""
  f=$(mktemp "${TMPDIR:-/tmp}/lead-review-land-p.XXXXXX") || return 1
  gh_rest GET "repos/$1/pulls/$2" > "$f" 2>/dev/null || grc=$?
  [ "$grc" = 0 ] && LRL_HEAD=$(jq -r '.head.sha // ""' "$f" 2>/dev/null) && LRL_BRANCH=$(jq -r '.head.ref // ""' "$f" 2>/dev/null)
  rm -f "$f"
  [ -n "$LRL_HEAD" ]
}

# lrl_reviews <repo> <pr> <out> <at> <consequence> — every page of the PR's
# reviews, as ONE array in <out>. rc 1 = not a complete read (a failed page, or a
# 10th full page), logged with <consequence>: an unread list is never "none".
lrl_reviews() {
  local repo="$1" pr="$2" out="$3" at="$4" what="$5" f page grc len
  f=$(mktemp "${TMPDIR:-/tmp}/lead-review-land-r.XXXXXX") || { log "$at: mktemp failed; $what"; return 1; }
  echo '[]' > "$out"
  for page in 1 2 3 4 5 6 7 8 9 10; do
    grc=0; gh_rest GET "repos/$repo/pulls/$pr/reviews?per_page=100&page=$page" > "$f" 2>/dev/null || grc=$?
    if [ "$grc" != 0 ] || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
      rm -f "$f"; log "$at: PR reviews read failed (rc $grc, HTTP $GH_REST_STATUS); $what"; return 1
    fi
    jq -s '.[0] + .[1]' "$out" "$f" > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" || { rm -f "$f" "$out.tmp"; log "$at: PR reviews unparseable; $what"; return 1; }
    len=$(jq 'length' "$f" 2>/dev/null)
    [ "${len:-0}" -lt 100 ] && { rm -f "$f"; return 0; }
    if [ "$page" = 10 ]; then
      rm -f "$f"; log "$at: 1000+ PR reviews, so the list cannot be read whole; $what"; return 1
    fi
  done
}

# lrl_block_route <id> <safe_id> <repo> <pr> <head> <body-file> — BH-3780,
# step 2b before the POST. Decides what a lead BLOCK does besides brief a round.
#   rc 0 = post the review.  rc 1 = do not post or stamp; the next tick retries.
# The ticket: the fleet.conf project whose repo is <repo>, on an issues board
# (board_prefix "-"), and the issue in the PR branch ticket/<KEY>-<n>
# (LRL_BRANCH, read by lrl_findings' head check just before this).
#   needs-human: a `- [BLOCK needs-human]` line. With a ticket, the BH-3443
#     hold is placed (bin/needs-human-hold.sh, source lead-review); without one,
#     ONE warn alert-line says no round will run. Flag state/.../nh-<id>.
#     br_lead_pick never briefs such a review, whatever happened here.
#   tripwire: the sorted `- [BLOCK]` lines through nh_fingerprint (digits and
#     shas dropped, so moved line numbers keep the print), counted once per head
#     in the review_block_fp ledger. At the trip count the hold is placed first,
#     and its one ask (the placer's step 8) carries the first finding.
lrl_block_route() {
  local id="$1" sid="$2" repo="$3" pr="$4" head="$5" bf="$6" at="$3#$4 @${5:0:12} lead review $1"
  local p="" issue="" why="" q bp fp action nhl prc rc first
  if ! declare -F nh_fingerprint >/dev/null 2>&1; then
    log "$at: needs-human lib missing; findings posted with no hold route"; return 0
  fi
  while read -r q; do
    [ -n "$q" ] || continue
    [ "$("$H/bin/fleet-conf.sh" "$q" repo 2>/dev/null)" = "$repo" ] && { p="$q"; break; }
  done < <("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
  if [ -z "$p" ]; then why="no fleet.conf project has repo $repo"
  else
    bp=$("$H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)
    if [ "$bp" != - ]; then why="$p is not an issues board"
    elif [[ "${LRL_BRANCH:-}" =~ ^ticket/[A-Za-z]+-([0-9]+)(-r[0-9]+)?$ ]]; then issue="${BASH_REMATCH[1]}"
    else why="branch '${LRL_BRANCH:-}' names no ticket"
    fi
  fi
  nhl=$(grep -m1 -E '^- \[BLOCK needs-human\]' "$bf")
  if [ -n "$nhl" ]; then
    lrl_flag_done "$STATE/nh-$sid" && return 0
    action=$(printf '%s' "$nhl" | sed -E 's/^- \[BLOCK needs-human\][[:space:]]*//' | tr -s '\t\r ' ' ')
    action=${action:0:160}
    if [ -z "$issue" ]; then
      "$H/bin/alert-line.sh" --severity warn --id "lead-nh-$sid" --project "${p:--}" \
        "[lead-review-land] $repo#$pr @${head:0:12}: a lead BLOCK is marked needs-human but no hold can be placed ($why); no fix round will run — a person must read https://github.com/$repo/pull/$pr" >/dev/null 2>&1 \
        || log "$at: the needs-human alert-line could not be sent"
      lrl_flag_set "$STATE/nh-$sid"
      log "$at: needs-human finding, no hold possible ($why); warned"; return 0
    fi
    fp=$(nh_fingerprint "$action") || fp=$(printf 'lead%s' "$sid" | sha1sum | cut -c1-12)
    prc=0; HARNESS="$H" "$H/bin/needs-human-hold.sh" "$p" "$issue" "$fp" \
      "lead review of $repo#$pr @${head:0:12}: $action" lead-review >/dev/null 2>&1 || prc=$?
    case "$prc" in
      0) log "$at: needs-human hold placed on $p#$issue fp $fp (placer rc 0: placed, already held, or needs-human-hold-off on)" ;;
      75) log "$at: needs-human hold on $p#$issue: the thread is unreadable (placer rc 75); findings not posted, not stamped, next tick retries"; return 1 ;;
      *) log "$at: needs-human hold on $p#$issue NOT placed (placer rc $prc, it alerted); findings posted, no round is briefed from them" ;;
    esac
    lrl_flag_set "$STATE/nh-$sid"
    return 0
  fi
  if [ -z "$issue" ]; then log "$at: tripwire not counted ($why); the fix-round cap bounds it"; return 0; fi
  first=$(grep -m1 -E '^- \[BLOCK\]' "$bf" | sed -E 's/^- \[BLOCK\][[:space:]]*//')
  if [ -z "$first" ] || ! fp=$(grep -E '^- \[BLOCK\]' "$bf" | sed -E 's/^- \[BLOCK\][[:space:]]*//' | LC_ALL=C sort | nh_fingerprint "$(cat)"); then
    log "$at: fp:none; tripwire not counted"; return 0
  fi
  rc=0; nh_trip_note "$p" "$issue" "$fp" "lead:$repo#$pr@$head" || rc=$?
  case "$rc" in
    0) ;;
    1) log "$at: tripwire fp $fp count $_NH_TRIP_N/$_NH_TRIP_AT on $p#$issue, no trip"; return 0 ;;
    *) log "$at: tripwire ledger unreadable; not counted, not tripped"; return 0 ;;
  esac
  lrl_flag_done "$STATE/trip-$sid" && return 0
  prc=0; HARNESS="$H" "$H/bin/needs-human-hold.sh" "$p" "$issue" "$fp" \
    "pause-and-diagnose: the same lead finding blocked $_NH_TRIP_N heads of $repo#$pr: ${first:0:120}" lead-review >/dev/null 2>&1 || prc=$?
  case "$prc" in
    75) log "$at: tripwire TRIPPED fp $fp ($_NH_TRIP_N heads) but the thread of $p#$issue is unreadable (placer rc 75); findings not posted, not stamped, next tick retries"; return 1 ;;
    *) log "$at: tripwire TRIPPED fp $fp ($_NH_TRIP_N heads) on $p#$issue, placer rc $prc" ;;
  esac
  lrl_flag_set "$STATE/trip-$sid"
  return 0
}

# lrl_findings <id> <safe_id> <repo> <pr> <head> <model> <ref> <row-json> — step 2b.
#   rc 0 = the findings review OF THIS RESULT is on the PR (posted now, or found
#   by flag or by the marker pair `<!-- lead-review:<id> -->` +
#   `<!-- lead-job:<job> -->`; a review with no job marker is this result only
#   while the request was never reset), or the PR has left <head> so there is
#   nothing to brief: stamp.
#   rc 1 = it is not, and nothing says it is: do not stamp.
#   rc 2 = this head's whole report has no `- [BLOCK` line (BH-6090): no review
#   is posted, one ALERTS line is written: stamp, and dismiss nothing.
lrl_findings() {
  local id="$1" sid="$2" repo="$3" pr="$4" head="$5" model="$6" ref="$7" row="$8"
  local flag="$STATE/findings-$2" mark="<!-- lead-review:$1 -->" jmark="<!-- lead-job:$SJOB -->" f bf af grc jid rbox arc body trunc=0
  local at="$3#$4 @${5:0:12} lead review $1"
  lrl_flag_done "$flag" && return 0
  f=$(mktemp "${TMPDIR:-/tmp}/lead-review-land-r.XXXXXX") || { log "$at: mktemp failed; findings not posted, not stamped"; return 1; }
  # Every page is read before any POST: an unread list is never "no marker".
  lrl_reviews "$repo" "$pr" "$f" "$at" "findings not posted, not stamped, next tick retries" || { rm -f "$f"; return 1; }
  if jq -e --arg m "$mark" --arg jm "$jmark" --arg sj "$SJOB" --argjson resets "$RESETS" \
      'any(.[]; (.body // "") as $b | ($b | contains($m))
         and ($sj == "" or ($b | contains($jm)) or ((($b | contains("<!-- lead-job:")) | not) and $resets == 0)))' "$f" >/dev/null 2>&1; then
    rm -f "$f"; lrl_flag_set "$flag"
    log "$at: its findings review is already on the PR; flagged"; return 0
  fi
  # A stamp-only retry can run after the PR moved on (the POST kept failing,
  # then a push). A REQUEST_CHANGES on a dead head is a standing review nobody
  # will fix, so it is not posted: stamped, as post rc 3 is.
  if ! lrl_pr_head "$repo" "$pr"; then
    rm -f "$f"; log "$at: PR head read failed (HTTP $GH_REST_STATUS); findings not posted, not stamped, next tick retries"; return 1
  fi
  if [ "$LRL_HEAD" != "$head" ]; then
    rm -f "$f"; log "$at: the PR head moved to ${LRL_HEAD:0:12}; findings not posted (a BLOCK on a dead head briefs nothing), stamped"; return 0
  fi
  bf=$(mktemp "${TMPDIR:-/tmp}/lead-review-land-b.XXXXXX") || { rm -f "$f"; log "$at: mktemp failed; not stamped"; return 1; }
  jid=$(jq -r '.job_id // ""' <<<"$row" 2>/dev/null); rbox=$(jq -r '.box // ""' <<<"$row" 2>/dev/null)
  printf '%s\n' "$mark" > "$bf"
  [ -z "$SJOB" ] || printf '%s\n' "$jmark" >> "$bf"
  printf 'Lead review (automated lead-review lane, %s) of %s\n\n' "$model" "${head:0:12}" >> "$bf"
  arc=3
  if [ -n "$jid" ]; then
    af=$(mktemp "${TMPDIR:-/tmp}/lead-review-land-a.XXXXXX") || { rm -f "$f" "$bf"; log "$at: mktemp failed; not stamped"; return 1; }
    arc=0; JOBS_ALERT=0 job_artifact_detail lead_review_report "$jid" > "$af" 2>/dev/null || arc=$?
    if [ "$arc" != 0 ] && [ "$arc" != 3 ]; then
      rm -f "$f" "$bf" "$af"; log "$at: the report artifact of job $jid could not be read (HTTP ${JOBS_HTTP:-none}); findings not posted, not stamped, next tick retries"; return 1
    fi
    if [ "$arc" = 0 ]; then
      # Only a report of THIS repo#pr at THIS head is posted (bin/lead-review.sh's replay guard).
      body=$(jq -r 'if (.body | type) == "string" then .body else empty end' "$af" 2>/dev/null)
      case "$(printf '%s\n' "$body" | lr_report_title)" in
        "# Lead review "*" ($repo#$pr at $head)")
          printf '%s\n' "$body" >> "$bf"
          if [ "$(jq -r '.truncated // false' "$af" 2>/dev/null)" = true ]; then
            trunc=1
            printf '\nReport truncated here; the full report is on box %s at %s\n' "$rbox" "$(jq -r '.path // ""' "$af" 2>/dev/null)" >> "$bf"
          fi ;;
        *) arc=3 ;;
      esac
    fi
    rm -f "$af"
  fi
  [ "$arc" = 3 ] && printf 'Full report: %s on box %s\n' "$ref" "$rbox" >> "$bf"
  # BH-6090: a BLOCK report with no `- [BLOCK` line briefs nothing a round or a
  # person can answer (a postscript was stored as the report). Never post it.
  if [ "$arc" = 0 ] && [ "$trunc" = 0 ] && ! grep -q '^- \[BLOCK' <<<"$body"; then
    rm -f "$f" "$bf"
    alert_once "$STATE/emptyblock-$sid" "[lead-review-land] $repo#$pr @${head:0:12} lead review $id: its BLOCK report has no '- [BLOCK' finding line, so no REQUEST_CHANGES review was posted and no fix round is briefed. The BLOCK verdict row stands. Read $ref on box $rbox (and the session transcript), then request a new review with bin/lead-verdict.sh request $repo $pr $head or record one with bin/lead-verdict.sh post" "r$RESETS"
    case $? in 2) log "$at: empty BLOCK withheld but the alert was not written; not stamped, next tick retries"; return 1 ;; esac
    log "$at: BLOCK report has no finding line; review withheld, alerted"; return 2
  fi
  # BH-3780: the hold (when one is due) goes on the ticket BEFORE the review, so
  # no resolver tick ever sees this review without it.
  lrl_block_route "$id" "$sid" "$repo" "$pr" "$head" "$bf" || { rm -f "$f" "$bf"; return 1; }
  # Plain commands into a file, never $( ): GH_REST_STATUS must survive to be read.
  grc=0; gh_rest POST "repos/$repo/pulls/$pr/reviews" -f commit_id="$head" -f event=REQUEST_CHANGES -F body=@"$bf" > "$f" 2>/dev/null || grc=$?
  if [ "$grc" != 0 ] && [ "$GH_REST_STATUS" = 422 ]; then
    grc=0; gh_rest POST "repos/$repo/pulls/$pr/reviews" -f commit_id="$head" -f event=COMMENT -F body=@"$bf" > "$f" 2>/dev/null || grc=$?
    if [ "$grc" = 0 ]; then
      "$H/bin/lane-alert.sh" --severity warn --id "lead-block-nobrief-$sid" lead-review-land \
        "$repo#$pr @${head:0:12}: lead BLOCK posted as a COMMENT (REQUEST_CHANGES refused 422), so no fix round is briefed from it: https://github.com/$repo/pull/$pr" >/dev/null 2>&1 || true
      log "$at: REQUEST_CHANGES refused 422; findings posted as a COMMENT"
    fi
  fi
  rm -f "$f" "$bf"
  if [ "$grc" != 0 ]; then
    log "$at: findings review NOT posted (HTTP $GH_REST_STATUS${GH_REST_REASON:+ $GH_REST_REASON}); not stamped, next tick retries"; return 1
  fi
  printf '%s' "$SJOB" > "$flag" 2>/dev/null || log "$at: findings posted but $flag could not be written; the marker read dedupes the next tick"
  log "$at: findings posted to the PR as a review on ${head:0:12}"
  return 0
}

# lrl_dismiss <id> <safe_id> <repo> <pr> <head> <verdict> <job> <merge|block> [row-ref] — step 2d.
#   A lead REQUEST_CHANGES stands across pushes until it is dismissed, and
#   .mergify.yml keeps a PR out of the queue on #changes-requested-reviews-by=0
#   (BH-2275). The rule is lsr_dismiss_stale (bin/lib/lead-stale-review.sh):
#   only this lane's OWN review is ever dismissed (BH-5213: a bot author from
#   lsr_bots_json AND the `<!-- lead-review:` marker), and of those, mode merge
#   (a lead MERGE on the PR's live head) dismisses one on an OLDER commit; both
#   modes also dismiss an earlier landing of THIS request (BH-5400: its
#   `<!-- lead-review:<id> -->` marker without this <job>'s
#   `<!-- lead-job:<job> -->`), whatever its commit; mode block (a re-landed
#   BLOCK, called after the new findings are posted) dismisses only those. The
#   message names the old head, the new head and the verdict row <row-ref>, and
#   says "re-landed" for an earlier landing. A person's review is never
#   touched. Flag dismissed-<id> (merge) or superseded-<id> (block), holding the job.
#   rc 0 = none stands (dismissed now, flagged, or the PR has left <head>, so
#   this verdict speaks for nothing): stamp. rc 1 = one may still stand: no stamp.
lrl_dismiss() {
  local id="$1" repo="$3" pr="$4" head="$5" verdict="$6" sjob="$7" mode="$8" ref="${9:-}" f line rid hs flag
  local at="$3#$4 @${5:0:12} lead review $1"
  [ -n "$ref" ] || ref="lead review $id"
  flag="$STATE/dismissed-$2"; [ "$mode" = block ] && flag="$STATE/superseded-$2"
  lrl_flag_done "$flag" && return 0
  if ! declare -F lsr_dismiss_stale >/dev/null 2>&1; then
    log "$at: bin/lib/lead-stale-review.sh missing; older lead BLOCK reviews not dismissed, not stamped"; return 1
  fi
  if ! lrl_pr_head "$repo" "$pr"; then
    log "$at: PR head read failed (HTTP $GH_REST_STATUS); older lead BLOCK reviews not dismissed, not stamped, next tick retries"; return 1
  fi
  if [ "$LRL_HEAD" != "$head" ]; then
    log "$at: the PR head moved to ${LRL_HEAD:0:12}; a $verdict on a dead head dismisses nothing, stamped"; return 0
  fi
  f=$(mktemp "${TMPDIR:-/tmp}/lead-review-land-d.XXXXXX") || { log "$at: mktemp failed; not stamped"; return 1; }
  if ! lsr_dismiss_stale "$repo" "$pr" "$head" "$verdict" "$ref" "$sjob" "$mode" "$id" > "$f"; then
    if [ -s "$f" ]; then
      while read -r line rid _ _ hs; do
        [ "$line" = failed ] && log "$at: dismissing lead review $rid FAILED (HTTP $hs); not stamped, next tick retries"
      done < "$f"
    else
      log "$at: PR reviews read failed (HTTP $GH_REST_STATUS); older lead BLOCK reviews not dismissed, not stamped, next tick retries"
    fi
    rm -f "$f"; return 1
  fi
  rm -f "$f"
  lrl_flag_set "$flag"
  [ "$LSR_DISMISSED" = 0 ] || log "$at: $verdict dismissed $LSR_DISMISSED older lead BLOCK review(s), so the merge queue is not parked on them"
  [ "$LSR_RELANDED" = 0 ] || log "$at: dismissed $LSR_RELANDED earlier landing review(s) of lead review $id"
  return 0
}

# lrl_spotcheck <safe_id> <repo> <pr> <head> <verdict> <model> <ref> — step 2c.
# Deterministic: the same heads are sampled on every rerun. It never gates the stamp.
lrl_spotcheck() {
  local b
  [ "$SPOTCHECK_PCT" -gt 0 ] || return 0
  b=$(( $(printf '%s' "$2#$3@$4" | cksum | awk '{print $1}') % 100 ))
  [ "$b" -lt "$SPOTCHECK_PCT" ] || return 0
  "$H/bin/lane-alert.sh" --severity warn --id "lead-spotcheck-$1" lead-review-land \
    "spot-check: $2#$3 @${4:0:12} lead $5 by $6: https://github.com/$2/pull/$3 report $7" >/dev/null 2>&1 || true
  log "$2#$3 @${4:0:12} lead $5 sampled for a spot-check (bucket $b < $SPOTCHECK_PCT)"
}

# lrl_ask_human <reason> — BH-3683: the withheld status's one warn beat per head
# (la_human_needed, deduped by its marker). rc 1 = not sent: the caller skips
# the stamp, so the next tick's stamp-only pass asks again.
lrl_ask_human() {
  la_human_needed "$REPO" "$PR" "$HEAD" "$1" lead-review-land && return 0
  log "$REPO#$PR @${HEAD:0:12} lead review $ID: the human-needed beat could not be sent; not stamped, next tick asks again"
  return 1
}

# lrl_have <file> — step 1's read of a GET /api/verdicts answer, for request
# $ID on $HEAD (job $SJOB, $RESETS resets): HAVE ADVICE SUPERSEDES OLDBLOCK as
# one TSV line, nothing when the file does not parse. BH-5773: the 503 retry in
# step 2 re-reads through it too.
lrl_have() {
  jq -r --arg h "$HEAD" --arg tok "lead-review:$ID" \
    --arg job "$SJOB" --argjson resets "$RESETS" '
    def toks: (.note // "") | split(" ");
    def lr: .source == "lead" and (toks | index($tok) != null);
    def mine: lr and .head_sha == $h and ($job == "" or (toks | index("lead-job:" + $job) != null)
        or ((toks | any(startswith("lead-job:")) | not) and $resets == 0));
    [.rows[]?] as $r
    | [ ([$r[] | select(mine)] | length),
        ([$r[] | select(mine and (toks | index("authority:human-required") != null))] | length),
        ([$r[] | select(lr and (mine | not)) | .id] | max // "-"),
        (if (.truncated // false) or any($r[]; .source == "lead" and .verdict == "BLOCK" and .head_sha != $h)
            or any($r[]; lr and (mine | not) and .verdict == "BLOCK") then "yes" else "no" end) ] | @tsv' "$1" 2>/dev/null
}

# lrl_inbuild_ok <repo> <pr> <head> — BH-5023, step 1b. rc 0 = a builder
# APPROVE is bound to <head>; 1 = there is none (no row, another sha, not
# APPROVE); 2 = the ledger could not be read.
lrl_inbuild_ok() {
  local url="https://github.com/$1/pull/$2" jv rc=0 v rsha hb
  jv=$(job_verdict "$url" 2>/dev/null) || rc=$?
  [ "$rc" = 1 ] && return 2
  if [ "$rc" = 0 ]; then
    IFS=$'\t' read -r v _ _ _ _ rsha <<<"$jv"
    [ "$v" = APPROVE ] || return 1
    [ "$(printf '%s' "$rsha" | tr 'A-F' 'a-f')" = "$3" ] && return 0
    hb=$(job_verdict_headbound "$url" 2>/dev/null | tr 'A-F' 'a-f')
    [ "$hb" = "reapproved@$3" ] && return 0
  fi
  return 1
}

DAY=$(date -u +%Y%m%d)
TOKF="${LEAD_VERDICT_TOKEN_FILE:-$HOME/.config/cromford/lead-verdict-token}"
export LEAD_VERDICT_TOKEN_FILE="$TOKF"
if [ ! -r "$TOKF" ]; then
  alert_once "$STATE/no-token-$DAY" "[lead-review-land] no lead verdict token on the hub: LEAD_VERDICT_TOKEN_FILE ($TOKF) is not readable, so no finished lead review can be promoted into a verdict row — install the token file (mode 600) on the hub" || true
  log "LEAD_VERDICT_TOKEN_FILE $TOKF not readable; nothing promoted"
  exit 0
fi

OVERDUE="${LEAD_REVIEW_OVERDUE_MIN:-120}"
case "$OVERDUE" in ''|*[!0-9]*|0*) log "LEAD_REVIEW_OVERDUE_MIN='$OVERDUE' is not a positive integer; using 120"; OVERDUE=120 ;; esac
# BH-5773: retries of a POST /api/verdicts that answered 503, in this tick, after 2 s, 5 s and 10 s.
POST_RETRIES="${LEAD_REVIEW_LAND_POST_RETRIES:-3}"
case "$POST_RETRIES" in [0-3]) ;; *) log "LEAD_REVIEW_LAND_POST_RETRIES='$POST_RETRIES' is not 0..3; using 3"; POST_RETRIES=3 ;; esac
POST_RETRY_S=(2 5 10)
POST_503_SPENT=0   # one request used every retry and still got 503: the rest of this tick posts once
# BH-5793: how many times an ENVIRONMENT failure is requeued before a person
# is told. 0 = never requeue (every failure alerts, as before BH-5793).
ENV_RETRY_MAX="${LEAD_REVIEW_ENV_RETRY_MAX:-3}"
case "$ENV_RETRY_MAX" in ''|*[!0-9]*) log "LEAD_REVIEW_ENV_RETRY_MAX='$ENV_RETRY_MAX' is not an integer; using 3"; ENV_RETRY_MAX=3 ;; esac
# lrl_env_failure <detail> — rc 0 when a failed request failed on its
# environment, not on the code: no clone or checkout on the box, a model that
# answered no verdict (detail `empty`, set by bin/lead-review.sh), or a rules
# pack that failed on its own setup (`review-failed: env: …`). No verdict was
# recorded for any of them, so a re-review is the only honest next step.
lrl_env_failure() {
  case "${1:-}" in
    checkout|no-checkout|empty|"review-failed: env:"*) return 0 ;;
  esac
  return 1
}
# BH-3479.0 contract seam: registered in catalog/lanes.d/lead-review-land.json, acted on by BH-3479.1/.3/.4.
AUTO_REPOS="${LEAD_REVIEW_AUTO_REPOS:-}"
SPOTCHECK_PCT="${LEAD_REVIEW_SPOTCHECK_PCT:-}"
# Rejected, never clamped: a knob that is not 0..100 turns the spot-check off.
case "$SPOTCHECK_PCT" in
  [0-9]|[1-9][0-9]|100) ;;
  *) log "LEAD_REVIEW_SPOTCHECK_PCT='$SPOTCHECK_PCT' is not 0..100; spot-check off this tick"
     SPOTCHECK_PCT=0 ;;
esac

LIST=$(mktemp "${TMPDIR:-/tmp}/lead-review-land.XXXXXX") || { log "mktemp failed; tick skipped"; exit 0; }
trap 'rm -f "$LIST"' EXIT
lr_get '?status=done,failed,requested,running&promoted=0' > "$LIST" 2>/dev/null; RC=$?
if [ "$RC" = 75 ]; then log "GET /api/lead-reviews is not deployed on $JOBS_URL; nothing to promote"; exit 0; fi
if [ "$RC" != 0 ]; then log "GET /api/lead-reviews failed (HTTP ${JOBS_HTTP:-none}); next tick retries"; exit 0; fi
jq -e '.requests | type == "array"' "$LIST" >/dev/null 2>&1 || { log "unparseable /api/lead-reviews answer; next tick retries"; exit 0; }
if [ "$(jq -r '.truncated // false' "$LIST")" = true ]; then
  alert_once "$STATE/truncated-$DAY" "[lead-review-land] the lead review list came back truncated (100 rows per call): requests past the cap are not promoted or alerted on this tick — check GET /api/lead-reviews?promoted=0 for a pile of failed or stuck rows" || true
fi

NOW=$(date +%s)
SEEN=0; PROMOTED=0; STAMPED=0; ALERTED=0; RUNG=0
while IFS= read -r ROW; do
  [ -n "$ROW" ] || continue
  SEEN=$((SEEN + 1))
  # Every column before DETAIL has a non-empty default: a tab IFS collapses empties.
  IFS=$'\t' read -r ID REPO PR HEAD STATUS VERDICT PROMOTED_AT CREATED MODEL REF JOB RESETS RESET_AT DETAIL < <(jq -r \
    'def v(f): (f // "") | tostring | if . == "" then "-" else gsub("[\t\n]"; " ") end;
     [.id, .repo, (.pr|tostring), .head_sha, .status, (.verdict // "-"), (.promoted_verdict_at // "-"),
      (.created_at // "-"), (.reviewer_model // "-"), (.report_ref // "-"),
      v(.job_id), ((.reset_count // 0) | tostring), v(.reset_at), ((.detail // "-") | gsub("[\t\n]"; " "))] | @tsv' <<<"$ROW")
  SAFE_ID=$(printf '%s' "$ID" | tr -cd 'A-Za-z0-9._-')
  # BH-5400: the job that produced this result keys its landing (empty = a
  # request with no job id: the id-only rule), and reset_count says whether a
  # landing with no job token can still be this result.
  SJOB=""; [ "$JOB" = - ] || SJOB=$(printf '%s' "$JOB" | tr -cd 'A-Za-z0-9._-')
  case "$RESETS" in ''|*[!0-9]*) RESETS=0 ;; esac
  [ -n "$SAFE_ID" ] || { log "a request with an unusable id ('$ID'); skipped"; continue; }
  case "$STATUS" in
    done)
      [ "$PROMOTED_AT" = - ] || continue
      case " $LR_VERDICT_WORDS " in
        *" $VERDICT "*) ;;
        *) log "$REPO#$PR @${HEAD:0:12} lead review $ID is done with verdict '$VERDICT', which is not one of $LR_VERDICT_WORDS; not promoted"; continue ;;
      esac
      # 1b. An in-build request needs a builder APPROVE on its head (BH-5023).
      INB=""; BY=$(jq -r '.requested_by // ""' <<<"$ROW" 2>/dev/null | sed 's/^[[:space:]]*//')
      if [[ "$BY" == inbuild:* ]]; then
        IRC=0; lrl_inbuild_ok "$REPO" "$PR" "$HEAD" || IRC=$?
        if [ "$IRC" = 2 ]; then
          log "$REPO#$PR @${HEAD:0:12} lead review $ID (in-build): builder verdict unreadable (HTTP ${JOBS_HTTP:-none}); next tick retries"; continue
        fi
        if [ "$IRC" != 0 ]; then
          log "$REPO#$PR @${HEAD:0:12} lead review $ID (in-build, $BY): no builder APPROVE bound to this head; not promoted"
          if [ ! -e "$STATE/alerted-inbuild-noapprove-$SAFE_ID" ]; then
            if "$H/bin/lane-alert.sh" --critical --severity critical --id "lead-inbuild-noapprove-$SAFE_ID" lead-review-land \
                 "$REPO#$PR @${HEAD:0:12}: in-build lead review $ID ($BY) says $VERDICT, but no builder APPROVE is bound to that head, so it was NOT promoted into a lead verdict. A box filed a request for a head its build did not approve; read logs/lead-review-land.log and the box's pipeline.log." >/dev/null 2>&1; then
              : > "$STATE/alerted-inbuild-noapprove-$SAFE_ID" 2>/dev/null || log "could not write the alerted flag for $ID; this may alert again"
              ALERTED=$((ALERTED + 1))
            else
              log "lane-alert.sh failed for lead-inbuild-noapprove-$SAFE_ID; next tick retries"
            fi
          fi
          continue
        fi
        INB=" inbuild:$(printf '%s' "$BY" | cut -d: -f2)"
      fi
      # 1. Is the row already there (an earlier tick posted it and lost the stamp)?
      VT=$(mktemp "${TMPDIR:-/tmp}/lead-review-land-v.XXXXXX") || { log "mktemp failed; $ID skipped"; continue; }
      if ! JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$REPO&pr=$PR&head=$HEAD" > "$VT"; then
        rm -f "$VT"; log "$REPO#$PR @${HEAD:0:12} lead review $ID: verdicts read failed (HTTP ${JOBS_HTTP:-none}); not posting blind, next tick retries"; continue
      fi
      # HAVE: lead rows on THAT head that land THIS result (BH-5400: the job's
      # token, or no job token on a request never reset). ADVICE: those of them
      # recorded as advice. SUPERSEDES: the newest row that landed an earlier
      # result of this request ("-" when none). 2d needs GitHub only when a lead
      # BLOCK was recorded on another head of this PR or by an earlier landing
      # of this request (a findings review is only ever posted after its row),
      # or when the row history came back truncated and cannot rule one out.
      HAVE=""; ADVICE=""; SUPERSEDES=""; OLDBLOCK=""
      IFS=$'\t' read -r HAVE ADVICE SUPERSEDES OLDBLOCK < <(lrl_have "$VT")
      # BH-5213: the verdict row 2d's dismissal message names (the row that lands
      # THIS result, by the same rule as HAVE; or post's answer below).
      ROWREF=$(jq -r --arg h "$HEAD" --arg tok "lead-review:$ID" --arg job "$SJOB" --argjson resets "$RESETS" '
        def toks: (.note // "") | split(" ");
        def mine: .source == "lead" and (toks | index($tok) != null) and .head_sha == $h
          and ($job == "" or (toks | index("lead-job:" + $job) != null)
            or ((toks | any(startswith("lead-job:")) | not) and $resets == 0));
        [.rows[]? | select(mine)] | max_by(.id) | if . == null then "" else "#\(.id)" end' "$VT" 2>/dev/null)
      rm -f "$VT"
      case "$HAVE" in ''|*[!0-9]*) log "$REPO#$PR @${HEAD:0:12} lead review $ID: unparseable verdicts answer; next tick retries"; continue ;; esac
      if [ "$HAVE" = 0 ]; then
        # 2. Post the lead row.
        NOTE="lead-review:$ID$INB"
        [ -z "$SJOB" ] || NOTE="$NOTE lead-job:$SJOB"
        if [ "$SUPERSEDES" != - ]; then
          NOTE="$NOTE supersedes:$SUPERSEDES"
          log "$REPO#$PR @${HEAD:0:12} lead review $ID: re-landing: newer result job ${SJOB:-?} replaces lead row #$SUPERSEDES"
        fi
        ARGS=(--source lead --reviewer "box:$BOX")
        [ "$MODEL" = - ] || ARGS+=(--model "$MODEL")
        # BH-6967: the tier and mode tokens bin/lead-review-enqueue.sh put in the
        # request's scope_notes ride onto the row. They count only as the LAST
        # group of the notes (the enqueue rewrites the same words anywhere else),
        # so earlier note text never sets them. None = no flag (today's row).
        RVSN=$(jq -r '.scope_notes // ""' <<<"$ROW" 2>/dev/null)
        RVRE='(^|; )review-tier:(low|medium|high) review-mode:(full|intent)$'
        [[ "$RVSN" =~ $RVRE ]] && ARGS+=(--review-tier "${BASH_REMATCH[2]}" --review-mode "${BASH_REMATCH[3]}")
        case "$REF" in
          -) ;;
          https://*) ARGS+=(--report-url "$REF") ;;
          *) NOTE="$NOTE report:$REF" ;;
        esac
        ARGS+=(--note "$NOTE")
        # BH-3348: post exits 3 when the PR head moved off the reviewed sha
        # (nothing written) and 4 when the row is recorded but the lead-verdict
        # status is not. A verdict on a dead head gates nothing, so rc 3 is
        # stamped rather than retried every tick for ever; rc 4 IS a promotion.
        # LV_DISMISS_STALE=0: step 2d below dismisses, with its retry and stamp rules.
        PRC=0; OUT=$(LV_DISMISS_STALE=0 "$H/bin/lead-verdict.sh" post "$REPO" "$PR" "$HEAD" "$VERDICT" "${ARGS[@]}" 2>&1) || PRC=$?
        # BH-5773: a 503 is the worker's D1 having a slow moment, not a refusal.
        # Retry it in this tick. Before each retry, re-read the row: a 503 can
        # come after the INSERT, and a second row for one landing is not
        # exactly-once. Found = the rc 4 arm (row recorded, status not confirmed).
        # Unreadable = stop; the next tick's step 1 decides (never post blind).
        n=0
        while [ "$PRC" = 1 ] && [ "$n" -lt "$POST_RETRIES" ] && [ "$POST_503_SPENT" = 0 ] \
              && [[ "$OUT" == *'worker refused (http 503)'* ]]; do
          sleep "${POST_RETRY_S[$n]}"; n=$((n + 1))
          VT=$(mktemp "${TMPDIR:-/tmp}/lead-review-land-v.XXXXXX") || break
          if ! JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$REPO&pr=$PR&head=$HEAD" > "$VT"; then
            rm -f "$VT"; log "$REPO#$PR @${HEAD:0:12} lead review $ID: post answered 503 and the re-read failed (HTTP ${JOBS_HTTP:-none}); not retrying blind"; break
          fi
          RH=""; IFS=$'\t' read -r RH _ _ _ < <(lrl_have "$VT")
          rm -f "$VT"
          case "$RH" in ''|*[!0-9]*) log "$REPO#$PR @${HEAD:0:12} lead review $ID: post answered 503 and the re-read did not parse; not retrying blind"; break ;; esac
          if [ "$RH" != 0 ]; then
            PRC=4; OUT="recorded by attempt $n despite its 503; lead-verdict status not confirmed"; break
          fi
          log "$REPO#$PR @${HEAD:0:12} lead review $ID: POST /api/verdicts answered 503; retry $n of $POST_RETRIES after ${POST_RETRY_S[$((n - 1))]}s"
          PRC=0; OUT=$(LV_DISMISS_STALE=0 "$H/bin/lead-verdict.sh" post "$REPO" "$PR" "$HEAD" "$VERDICT" "${ARGS[@]}" 2>&1) || PRC=$?
        done
        [ "$PRC" = 1 ] && [ "$n" -ge "$POST_RETRIES" ] && [ "$POST_RETRIES" -gt 0 ] && [[ "$OUT" == *'worker refused (http 503)'* ]] && POST_503_SPENT=1
        RID=$(printf '%s' "$OUT" | sed -nE 's/^recorded verdict #([0-9]+):.*/\1/p' | head -1)
        [ -z "$RID" ] || ROWREF="#$RID"
        case "$PRC" in
          0) PROMOTED=$((PROMOTED + 1))
             log "$REPO#$PR @${HEAD:0:12} lead review $ID: $VERDICT posted as a source=lead row ($(head -1 <<<"$OUT"))"
             [ "$VERDICT" = BLOCK ] || lrl_spotcheck "$SAFE_ID" "$REPO" "$PR" "$HEAD" "$VERDICT" "$MODEL" "$REF" ;;
          3) log "$REPO#$PR @${HEAD:0:12} lead review $ID: reviewed @${HEAD:0:12} but the PR head moved; not posted, stamped promoted (a verdict on a dead head gates nothing): $(printf '%s' "$OUT" | tr '\n' ' ' | head -c 200)" ;;
          4) PROMOTED=$((PROMOTED + 1))
             log "$REPO#$PR @${HEAD:0:12} lead review $ID: $VERDICT posted as a source=lead row, but the lead-verdict status was NOT published ($(printf '%s' "$OUT" | tr '\n' ' ' | head -c 300))"
             [ "$VERDICT" = BLOCK ] || lrl_spotcheck "$SAFE_ID" "$REPO" "$PR" "$HEAD" "$VERDICT" "$MODEL" "$REF" ;;
          5) PROMOTED=$((PROMOTED + 1))
             WH=$(grep -m1 'status withheld' <<<"$OUT" | sed 's/^lead-verdict: //')
             log "$REPO#$PR @${HEAD:0:12} lead review $ID: $VERDICT recorded as advice; lead-verdict status withheld (${WH:-$(head -1 <<<"$OUT")})"
             WR=${WH#status withheld on * }; WR=${WR%; a *}
             lrl_ask_human "${WR:-see logs/lead-review-land.log}" || continue ;;
          *) log "$REPO#$PR @${HEAD:0:12} lead review $ID: verdict row NOT posted ($(printf '%s' "$OUT" | tr '\n' ' ' | head -c 200)); not stamped, next tick retries"
             continue ;;
        esac
      else
        log "$REPO#$PR @${HEAD:0:12} lead review $ID: its lead row is already recorded; stamping only"
        PRC=0
        # A withheld row whose beat was never sent (it failed, so no stamp) asks now.
        if [ "$ADVICE" != 0 ]; then lrl_ask_human "recorded as advice on an earlier tick" || continue; fi
      fi
      # 2a-flip. BH-6391, a measurement: a verdict whose class differs from the
      # earlier lead word on a head with no own commit since it. One line per
      # request (the flip-<id> marker); no post, stamp or counter depends on it.
      if [ "$PRC" != 3 ] && command -v lpv_flip >/dev/null 2>&1 && [ ! -e "$STATE/flip-$SAFE_ID" ] \
         && FL=$(lpv_flip "$(jq -r '.scope_notes // ""' <<<"$ROW" 2>/dev/null)" "$VERDICT"); then
        log "flip $REPO#$PR ${FL%% own-commits:*} -> ${HEAD:0:12} $VERDICT own-commits:0 request:$ID"
        : > "$STATE/flip-$SAFE_ID" 2>/dev/null || log "could not write the flip marker for $ID; a rerun may log it again"
      fi
      # 2b. A recorded BLOCK puts its findings on the PR before the stamp.
      if [ "$VERDICT" = BLOCK ] && [ "$PRC" != 3 ]; then
        FRC=0; lrl_findings "$ID" "$SAFE_ID" "$REPO" "$PR" "$HEAD" "$MODEL" "$REF" "$ROW" || FRC=$?
        [ "$FRC" = 1 ] && continue
        # BH-5400: a re-landed BLOCK retires the earlier landing's review only
        # now, after its own findings are on the PR (never for a withheld one).
        if [ "$FRC" = 0 ] && [ "$SUPERSEDES" != - ] && [ -n "$SJOB" ]; then
          lrl_dismiss "$ID" "$SAFE_ID" "$REPO" "$PR" "$HEAD" "$VERDICT" "$SJOB" block "$ROWREF" || continue
        fi
      fi
      # 2d. A recorded MERGE dismisses the older lead BLOCK reviews still standing.
      if [ "$VERDICT" != BLOCK ] && [ "$PRC" != 3 ] && [ "$OLDBLOCK" != no ]; then
        lrl_dismiss "$ID" "$SAFE_ID" "$REPO" "$PR" "$HEAD" "$VERDICT" "$SJOB" merge "$ROWREF" || continue
      fi
      # 2e. BH-4057: a recorded MERGE / MERGE-WITH-NOTES rings the merge conductor for this PR now
      # (keyed tick, kw_conductor's own MC_KEYED_WAKE_MIN_S stamp dedupes). BLOCK belongs to the
      # resolver, rc 3 is a dead head, rc 5 / advice waits on a human: none of those ring.
      if [ "$VERDICT" != BLOCK ] && { [ "$PRC" = 0 ] || [ "$PRC" = 4 ]; } && [ "$ADVICE" = 0 ] \
         && command -v kw_conductor >/dev/null 2>&1 \
         && kw_conductor "$REPO" "$PR" "lead $VERDICT on ${HEAD:0:12}"; then
        RUNG=$((RUNG + 1)); log "$REPO#$PR @${HEAD:0:12} lead review $ID: conductor rung"
      fi
      # 3. Stamp it promoted, bound to the job (BH-5400).
      SBODY='{}'; [ -z "$SJOB" ] || SBODY=$(jq -nc --arg j "$JOB" '{job_id:$j}')
      if SOUT=$(lr_post_lead "/$ID/promoted" "$SBODY" 2>&1); then
        STAMPED=$((STAMPED + 1))
      elif grep -q 'the request now holds job' <<<"$SOUT"; then
        log "$REPO#$PR @${HEAD:0:12} lead review $ID: promoted stamp for job ${SJOB} refused, a newer result on the request; next tick lands it ($(printf '%s' "$SOUT" | tr '\n' ' ' | head -c 200))"
      else
        log "$REPO#$PR @${HEAD:0:12} lead review $ID: promoted stamp failed ($(printf '%s' "$SOUT" | tr '\n' ' ' | head -c 200)); the row stands, next tick stamps only"
      fi ;;
    failed)
      # BH-5793: an environment failure goes back to `requested` (the worker
      # records reset_count), up to ENV_RETRY_MAX resets; a person is told only
      # past that, or when the requeue itself is refused.
      if lrl_env_failure "$DETAIL" && [ "$RESETS" -lt "$ENV_RETRY_MAX" ]; then
        if ROUT=$(lr_post_lead "/$ID/reset" '{}' 2>&1); then
          log "$REPO#$PR @${HEAD:0:12} lead review $ID failed on its environment (${DETAIL}); requeued for a re-review (reset $((RESETS + 1)) of $ENV_RETRY_MAX)"
          continue
        fi
        log "$REPO#$PR @${HEAD:0:12} lead review $ID failed on its environment (${DETAIL}); requeue refused ($(printf '%s' "$ROUT" | tr '\n' ' ' | head -c 200)), so a person is told"
      fi
      alert_once "$STATE/alerted-$SAFE_ID" "[lead-review-land] $REPO#$PR @${HEAD:0:12} lead review $ID failed: ${DETAIL} — read the owning box's logs/lead-review.log, then review by hand and record it with bin/lead-verdict.sh post $REPO $PR $HEAD <VERDICT>" "r$RESETS"
      [ "$?" = 0 ] && ALERTED=$((ALERTED + 1)) ;;
    requested|running)
      # BH-5400: a reset request is judged from its reset, not its creation.
      SINCE="$CREATED"; SINCE_COL=created_at
      [ "$RESET_AT" = - ] || { SINCE="$RESET_AT"; SINCE_COL=reset_at; }
      if [ -z "$SINCE" ] || ! CT=$(date -u -d "$SINCE" +%s 2>/dev/null); then
        log "$REPO#$PR @${HEAD:0:12} lead review $ID: $SINCE_COL '$SINCE' does not parse; not judged overdue"; continue
      fi
      AGE=$(( (NOW - CT) / 60 ))
      [ "$AGE" -ge "$OVERDUE" ] || continue
      alert_once "$STATE/alerted-$SAFE_ID" "[lead-review-land] $REPO#$PR @${HEAD:0:12} lead review $ID $STATUS: $STATUS for $AGE min (over LEAD_REVIEW_OVERDUE_MIN=$OVERDUE) — check that the box owning $REPO runs the lead-review lane (its logs/lead-review.log, flags/lane-off-lead-review) and has a lead.review model route" "r$RESETS"
      [ "$?" = 0 ] && ALERTED=$((ALERTED + 1)) ;;
    *) ;;
  esac
done < <(jq -c '.requests[]' "$LIST")

log "seen=$SEEN promoted=$PROMOTED stamped=$STAMPED alerted=$ALERTED rung=$RUNG"
# BH-4057: a tick refused by the lock left rerun-owed; this one reruns once for it. The lock is
# released and fd 9 closed in THIS shell first: lcw_rerun runs in $( ), where its own close
# reaches only the subshell's copy, and the work this lock guards is done.
if command -v lcw_rerun >/dev/null 2>&1; then
  flock -u 9 2>/dev/null; exec 9>&-
  RR=$(lcw_rerun "$H/bin/lead-review-land.sh" "$STATE" "${LEAD_REVIEW_LAND_RERUN_MAX:-}"); [ -n "$RR" ] && log "$RR"
fi
exit 0
