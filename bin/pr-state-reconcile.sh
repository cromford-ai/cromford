#!/bin/bash
# bin/pr-state-reconcile.sh tick — BH-4954 (BH-4950.1): the sweep that keeps the
# PR gate facts (`state='gate'` rows in pr_state_events, worker/jobs/src/lib/
# pr-gate.js) true when a webhook, an artifact hook or a verdict hook was lost.
# Every 15 minutes (cron/lanes/716-pr-state-reconcile.cron), for each repo in
# LEAD_REVIEW_AUTO_REPOS (lead-review-land's knob, read through its
# lane_env_apply; empty = not configured, nothing is written):
#   budget   gh_budget_low rc 0 = the repo is skipped this pass, no read at all.
#   db       pr_gate_facts <slug>: the folded facts. Unreadable = no corrections.
#   list     harness_pr_list open. Unreadable = next repo.
#   per open PR, the live head (prs_pr_get .head.sha) first; unreadable skips the
#   PR, because every other fact is judged against it. Then, in this order, one
#   correcting event per field whose db value differs from the live one:
#     head                  the live head
#     draft                 isDraft as 0/1 (db null reads as 0)
#     closed=0              only when the db says closed=1 (it is open again)
#     builder_approved_sha  job_verdict APPROVE with reviewed_sha == head, or
#                           job_verdict_headbound == reapproved@<head>; rc 1 = skipped
#     lead_verdict_*        vd_standing on the head; rc 2 = skipped
#     held                  hold_check_thread rc 1 = 1, rc 0 = 0; rc 2 = skipped
#     ci_green_sha=<head>   frp_ci state green; unreadable = skipped. Last, and
#                           only when the db is not already green on the head:
#                           it costs two GitHub reads.
#   closed   when the open list is complete (< 100 rows), every db PR that is not
#            closed and not in the list is read (gh_rest pulls/<n>); state closed
#            = closed=1. Unreadable = skipped. A full list skips this step.
# A sha fact is never corrected backwards (NULL is "no news"): it is always
# compared with `head`, so a new head already invalidates it.
# Each event: pr_gate_event_put <slug> <n> reconcile@<head12>@<field>@<sweep
# epoch> reconcile <field=value>... The epoch keeps a second correction of the
# same field on the same head from colliding with the first on the dedupe key.
# PR_STATE_RECONCILE_MAX_PER_SWEEP caps the corrections a sweep writes; the
# rest are deferred, and the next sweep sees the same difference.
# Then two hub jobs that bin/lead-review-enqueue.sh ran before BH-7235 (nothing
# starts the enqueue now), each fail-open (its rc is ignored; a missing lib is
# one log line a sweep), on the facts this sweep judged for the live head. The
# cap does not apply to them:
#   live probes   (BH-5801) not draft, not held, builder APPROVE and CI green on
#                 the head, no lead verdict on it: lp_run_for_head
#                 (bin/lib/live-probes.sh), once per head by its own marker.
#   console qa    (BH-5909) a lead verdict on the head, in fleet.conf's
#                 cromford repo: cqg_clear_block (bin/lib/console-qa-gate.sh)
#                 resets a console-qa-gate BLOCK once a QA: PASS names the head.
#                 Its marker stays in state/lead-review-enqueue/, so a head
#                 the enqueue reset is not reset again.
# Marker retention, once in 24 h (stamp state/pr-state-reconcile/marker-sweep.stamp):
# state/pr-state-reconcile/alerted-*, state/live-probes/* and
# state/lead-review-enqueue/qa-reset-* older than PR_STATE_RECONCILE_MARKER_KEEP_DAYS
# (a required registry knob, default 14; 0 = off) are deleted. The first sweep
# on a box (no stamp) is a dry run that only counts them. One `marker-sweep:`
# line a run. A value that is not a whole number deletes nothing.
# Unreadable is never written as a fact. A failed write is failed, not corrected.
# Hub only. Kill switch: flags/lane-off-pr-state-reconcile.
# Log: logs/pr-state-reconcile.log, one line per correction, one per reset, and one
# `checked= corrected= skipped= deferred= failed= repos=` summary a sweep.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

case "${1:-tick}" in tick) ;; *) echo "usage: bin/pr-state-reconcile.sh tick" >&2; exit 2 ;; esac

# >>> lane gate (BH-1165). Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off pr-state-reconcile.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit pr-state-reconcile
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    pr-state-reconcile
# LEAD_REVIEW_AUTO_REPOS is lead-review-land's knob (BH-3479.0 contract).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lead-review-land

LOG="$H/logs/pr-state-reconcile.log"
STATE="$H/state/pr-state-reconcile"
log() { mkdir -p "$H/logs" 2>/dev/null; echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$LOG"; }

# shellcheck source=bin/lib/hub-box.sh
. "$H/bin/lib/hub-box.sh" 2>/dev/null || { log "missing bin/lib/hub-box.sh; pr-state-reconcile tick skipped"; exit 0; }
BOX=$(local_box_name)
if ! is_hub_box "$BOX"; then log "not the hub (${BOX:-unnamed}); pr-state-reconcile runs on the hub only"; exit 0; fi

# jobs-client.sh exits its caller on a missing module, so every piece is checked first.
for f in bin/jobs-client.sh bin/lib/jobs/req.sh bin/lib/verdicts.sh bin/lib/hold.sh bin/lib/gh-rest.sh \
         bin/lib/gh-pr-list.sh bin/lib/gh-budget.sh bin/lib/pr-snapshot.sh bin/lib/fixround-preflight.sh; do
  [ -r "$H/$f" ] || { log "missing $f; pr-state-reconcile tick skipped"; exit 0; }
done
# shellcheck source=/dev/null
{ . "$H/bin/jobs-client.sh"; . "$H/bin/lib/verdicts.sh"; . "$H/bin/lib/hold.sh"
  . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/gh-pr-list.sh"; . "$H/bin/lib/gh-budget.sh"
  . "$H/bin/lib/pr-snapshot.sh"; . "$H/bin/lib/fixround-preflight.sh"; }
# The two hub jobs (header). Missing = that block is skipped, one log line a
# sweep (below).
# shellcheck source=bin/lib/live-probes.sh
LP=0; . "$H/bin/lib/live-probes.sh" 2>/dev/null && LP=1
# shellcheck source=bin/lib/console-qa-gate.sh
CQG=0; . "$H/bin/lib/lead-reviews.sh" 2>/dev/null && . "$H/bin/lib/console-qa-gate.sh" 2>/dev/null && CQG=1
CQG_HREPO=$(awk '$1 == "cromford" {print $2; exit}' "${FLEET_CONF:-$H/fleet.conf}" 2>/dev/null)

# A required registry knob: no literal here. Empty or not a positive integer
# means the registry was not read, and that is never "go".
MAX="${PR_STATE_RECONCILE_MAX_PER_SWEEP:-}"
case "$MAX" in ''|*[!0-9]*|0*) log "PR_STATE_RECONCILE_MAX_PER_SWEEP='$MAX' is not a positive integer; nothing written"; exit 0 ;; esac
# Owned by lead-review-land and exported by its lane_env_apply above. Empty =
# not configured, never "all repos".
AUTO_REPOS=""; [ -n "${LEAD_REVIEW_AUTO_REPOS+x}" ] && AUTO_REPOS=$LEAD_REVIEW_AUTO_REPOS
[ -n "${AUTO_REPOS// /}" ] || { log "LEAD_REVIEW_AUTO_REPOS is empty; nothing written"; exit 0; }

mkdir -p "$STATE" 2>/dev/null
# A sweep dedupe, never a queue: a second tick while one runs skips.
exec 9>"$STATE/tick.lock"; flock -n 9 || { log "another sweep holds $STATE/tick.lock; skipped"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pr-state-reconcile.XXXXXX") || { log "mktemp failed; sweep skipped"; exit 0; }
trap 'rm -rf "$WORK"' EXIT
command -v prs_gc >/dev/null 2>&1 && prs_gc

STAMP=$(date -u +%s)
[ "$LP" = 1 ] || log "bin/lib/live-probes.sh missing; no live probes this sweep"
[ "$CQG" = 1 ] || log "bin/lib/console-qa-gate.sh or bin/lib/lead-reviews.sh missing; no console QA reset this sweep"
REPOS=0; CHECKED=0; CORRECTED=0; SKIPPED=0; DEFERRED=0; FAILED=0
s12() { case "$1" in ????????????*) printf '%s' "${1:0:12}" ;; '') printf 'null' ;; *) printf '%s' "$1" ;; esac; }

# alert_once <id> <severity> <text> — one lane-alert per id, deduped by
#   state/pr-state-reconcile/alerted-<id>, written only after the call returned
#   0. bin/lib/live-probes.sh calls it when a head runs out of post tries.
alert_once() {
  local id="$1" sev="$2" text="$3" mark
  mark="$STATE/alerted-$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_')"
  [ -e "$mark" ] && return 0
  "$H/bin/lane-alert.sh" --severity "$sev" --id "$id" pr-state-reconcile "$text" >/dev/null 2>&1 || return 1
  : > "$mark"
}

# marker_sweep — the marker retention of the header. Always rc 0.
marker_sweep() {
  local keep="${PR_STATE_RECONCILE_MARKER_KEEP_DAYS:-}" stamp="$STATE/marker-sweep.stamp" mode=deleted n=0 f
  case "$keep" in ''|*[!0-9]*) log "PR_STATE_RECONCILE_MARKER_KEEP_DAYS='$keep' is not a whole number; no marker sweep"; return 0 ;; esac
  [ "$keep" = 0 ] && return 0
  if [ ! -e "$stamp" ]; then mode=dry-run
  elif [ -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ]; then return 0; fi
  while IFS= read -r -d '' f; do
    if [ "$mode" = dry-run ]; then n=$((n + 1)); else rm -f -- "$f" 2>/dev/null && n=$((n + 1)); fi
  done < <(find "$STATE" -maxdepth 1 -type f -name 'alerted-*' -mmin +$((keep * 1440)) -print0 2>/dev/null
           find "$H/state/live-probes" -maxdepth 1 -type f -mmin +$((keep * 1440)) -print0 2>/dev/null
           find "$H/state/lead-review-enqueue" -maxdepth 1 -type f -name 'qa-reset-*' -mmin +$((keep * 1440)) -print0 2>/dev/null)
  : > "$stamp"
  log "marker-sweep: $mode files=$n keep=${keep}d"
}
marker_sweep

# fix <field> <db> <live> <field=value>... — one correcting event, under the cap.
# Uses SLUG, N and HEAD from the loop.
fix() {
  local field="$1" db="$2" live="$3"; shift 3
  if [ "$CORRECTED" -ge "$MAX" ]; then DEFERRED=$((DEFERRED + 1)); return 0; fi
  if pr_gate_event_put "$SLUG" "$N" "reconcile@${HEAD:0:12}@$field@$STAMP" reconcile "$@" 2>/dev/null; then
    CORRECTED=$((CORRECTED + 1))
    log "$SLUG $N $field db=$(s12 "$db") live=$(s12 "$live")"
  else
    FAILED=$((FAILED + 1))
    log "$SLUG $N $field db=$(s12 "$db") live=$(s12 "$live"): the correcting event was not written; next sweep retries"
  fi
}

for SLUG in $AUTO_REPOS; do
  REPOS=$((REPOS + 1))
  case "$SLUG" in */*) ;; *) log "'$SLUG' in LEAD_REVIEW_AUTO_REPOS is not owner/repo; skipped"; continue ;; esac
  if gh_budget_low pr-state-reconcile; then log "budget low; $SLUG skipped this pass"; SKIPPED=$((SKIPPED + 1)); continue; fi
  if ! pr_gate_facts "$SLUG" > "$WORK/facts" 2>/dev/null || ! jq -e '.rows | type == "array"' "$WORK/facts" >/dev/null 2>&1; then
    log "$SLUG: the gate facts are unreadable; no corrections this pass"; SKIPPED=$((SKIPPED + 1)); continue
  fi
  harness_pr_list "$SLUG" open number,url,isDraft,baseRefName,headRefOid,updatedAt > "$WORK/list" 2>/dev/null; RC=$?
  if [ "$RC" != 0 ] || ! jq -e 'type == "array"' "$WORK/list" >/dev/null 2>&1; then
    log "$SLUG: the open PR list is unreadable (rc $RC); next sweep retries"; SKIPPED=$((SKIPPED + 1)); continue
  fi
  while IFS=$'\t' read -r N URL DRAFT BASE LHEAD LUPD; do
    case "$N" in ''|*[!0-9]*) continue ;; esac
    CHECKED=$((CHECKED + 1))
    HEAD=""
    prs_pr_get "$SLUG" "$N" "$LHEAD" "$LUPD" "$BASE" "$WORK/pr" 2>/dev/null && HEAD=$(jq -r '.head.sha // empty' "$WORK/pr" 2>/dev/null | tr 'A-F' 'a-f')
    [[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || { log "$SLUG $N: live head unreadable; PR skipped"; SKIPPED=$((SKIPPED + 1)); continue; }
    # The db's facts for this PR, '' for null (no row = every field null). A
    # null rides as '-' because read collapses adjacent tabs.
    IFS=$'\t' read -r D_HEAD D_DRAFT D_CLOSED D_CI D_APP D_LEAD D_HELD < <(jq -r --argjson n "$N" '
      ([.rows[] | select(.number == $n)] | first // {}) as $r
      | [$r.head, $r.draft, $r.closed, $r.ci_green_sha, $r.builder_approved_sha, $r.lead_verdict_sha, $r.held]
      | map(if . == null or . == "" then "-" else tostring end) | @tsv' "$WORK/facts")
    for v in D_HEAD D_DRAFT D_CLOSED D_CI D_APP D_LEAD D_HELD; do [ "${!v:--}" = - ] && printf -v "$v" '%s' ""; done
    [ "$HEAD" != "${D_HEAD:-}" ] && fix head "${D_HEAD:-}" "$HEAD" "head=$HEAD"
    LDRAFT=0; [ "$DRAFT" = true ] && LDRAFT=1
    [ "$LDRAFT" != "${D_DRAFT:-0}" ] && fix draft "${D_DRAFT:-}" "$LDRAFT" "draft=$LDRAFT"
    [ "${D_CLOSED:-0}" = 1 ] && fix closed 1 0 closed=0
    # The facts this sweep judged for the live head, for the two jobs after
    # CI: 1 = true on HEAD, 0 = not, or not judged. Held starts at 1, so an
    # unread thread never runs a probe.
    E_APP=0; E_LEAD=0; E_CI=0; E_HELD=1
    [ "${D_APP:-}" = "$HEAD" ] && E_APP=1
    [ "${D_LEAD:-}" = "$HEAD" ] && E_LEAD=1
    [ "${D_CI:-}" = "$HEAD" ] && E_CI=1
    # A builder APPROVE bound to the head (the builder gate's rule,
    # bin/lib/lead-gates.d/10-builder.sh).
    if [ "${D_APP:-}" != "$HEAD" ]; then
      JRC=0; JV=$(job_verdict "$URL" 2>/dev/null) || JRC=$?
      case "$JRC" in
        0)
          IFS=$'\t' read -r V _ _ _ _ RSHA <<<"$JV"
          RSHA=$(printf '%s' "$RSHA" | tr 'A-F' 'a-f')
          if [ "$V" = APPROVE ]; then
            if [ "$RSHA" = "$HEAD" ]; then E_APP=1; fix builder_approved_sha "${D_APP:-}" "$HEAD" "builder_approved_sha=$HEAD"
            elif HB=$(job_verdict_headbound "$URL" 2>/dev/null); then
              [ "$(printf '%s' "$HB" | tr 'A-F' 'a-f')" = "reapproved@$HEAD" ] && { E_APP=1; fix builder_approved_sha "${D_APP:-}" "$HEAD" "builder_approved_sha=$HEAD"; }
            else
              log "$SLUG $N: the builder verdict's headbound is unreadable; builder_approved_sha not judged"; SKIPPED=$((SKIPPED + 1))
            fi
          fi ;;
        2) ;;
        *) log "$SLUG $N: the builder verdict is unreadable; builder_approved_sha not judged"; SKIPPED=$((SKIPPED + 1)) ;;
      esac
    fi
    if [ "${D_LEAD:-}" != "$HEAD" ]; then
      VRC=0; VL=$(vd_standing "$SLUG" "$N" "$HEAD" 2>/dev/null) || VRC=$?
      case "$VRC" in
        0) E_LEAD=1; fix lead_verdict "${D_LEAD:-}" "$HEAD" "lead_verdict_sha=$HEAD" "lead_verdict_word=$(cut -f1 <<<"$VL")" ;;
        1) ;;
        *) log "$SLUG $N: the standing verdict is unreadable; lead_verdict not judged"; SKIPPED=$((SKIPPED + 1)) ;;
      esac
    fi
    HRC=0; hold_check_thread "$SLUG" "$N" >/dev/null 2>&1 || HRC=$?
    case "$HRC" in
      0|1) LHELD=$((HRC == 1 ? 1 : 0)); E_HELD=$LHELD; [ "$LHELD" != "${D_HELD:-0}" ] && fix held "${D_HELD:-}" "$LHELD" "held=$LHELD" ;;
      *) log "$SLUG $N: the PR thread is unreadable; held not judged"; SKIPPED=$((SKIPPED + 1)) ;;
    esac
    # CI last: two GETs, and only when the db is not already green on the head.
    if [ "${D_CI:-}" != "$HEAD" ]; then
      CI=$(frp_ci "$SLUG" "$HEAD" | jq -r '.state // "unreadable"' 2>/dev/null)
      case "$CI" in
        green) E_CI=1; fix ci_green_sha "${D_CI:-}" "$HEAD" "ci_green_sha=$HEAD" ;;
        pending|red|none) ;;
        *) log "$SLUG $N: CI on $(s12 "$HEAD") is unreadable; ci_green_sha not judged"; SKIPPED=$((SKIPPED + 1)) ;;
      esac
    fi
    # >>> live probes (BH-5801): the PR's declared catalog probes, run once per
    # head and posted to the PR. This sweep is not ordered against the box's
    # lead review: the worklist gate bin/lib/lead-gates.d/72-probe-hold.sh
    # holds the review of a head that declares a catalog probe until this
    # comment is on the PR (bounded by LEAD_REVIEW_PROBE_WAIT_MAX_MIN). Fail-open.
    if [ "$LP" = 1 ] && [ "$LDRAFT" = 0 ] && [ "$E_HELD" = 0 ] && [ "$E_APP" = 1 ] && [ "$E_CI" = 1 ] && [ "$E_LEAD" = 0 ]; then
      lp_run_for_head "$SLUG" "$N" "$HEAD" "$WORK/pr" || true
    fi
    # <<< live probes
    # >>> console qa clear (BH-5909): a console-qa-gate BLOCK on this head is
    # reviewed again, with no push, once a QA: PASS comment names the head.
    if [ "$CQG" = 1 ] && [ "$E_LEAD" = 1 ] && [ -n "$CQG_HREPO" ] && [ "${SLUG,,}" = "${CQG_HREPO,,}" ]; then
      mkdir -p "$H/state/lead-review-enqueue" 2>/dev/null
      CQL=$(cqg_clear_block "$SLUG" "$N" "$HEAD" "$H/state/lead-review-enqueue") || true
      [ -n "$CQL" ] && log "$SLUG $N @$(s12 "$HEAD"): $CQL"
    fi
    # <<< console qa clear
  done < <(jq -r '.[] | [(.number|tostring), (.url // ""), (.isDraft|tostring), (.baseRefName // "main"),
      ((.headRefOid // "") | if . == "" then "-" else . end), ((.updatedAt // "") | if . == "" then "-" else . end)] | @tsv' "$WORK/list")

  # Closed on GitHub, open in the db. Only a complete list can say "not open".
  if [ "$(jq 'length' "$WORK/list")" -ge 100 ]; then
    log "$SLUG: list may be truncated; closed sweep skipped"
    continue
  fi
  while IFS=$'\t' read -r N HEAD; do
    case "$N" in ''|*[!0-9]*) continue ;; esac
    [ "$HEAD" = - ] && HEAD=""
    CRC=0; gh_rest GET "repos/$SLUG/pulls/$N" > "$WORK/one" 2>/dev/null || CRC=$?
    ST=$(jq -r '.state // empty' "$WORK/one" 2>/dev/null)
    if [ "$CRC" != 0 ] || [ -z "$ST" ]; then
      log "$SLUG $N: the PR is not in the open list and its state is unreadable; closed not judged"; SKIPPED=$((SKIPPED + 1)); continue
    fi
    [ "$ST" = closed ] && fix closed 0 1 closed=1
  done < <(jq -r --slurpfile open "$WORK/list" '($open[0] | map(.number)) as $o
      | .rows[] | select(.closed != 1) | select(.number as $n | $o | index($n) | not)
      | [(.number|tostring), (.head // "-")] | @tsv' "$WORK/facts")
done

log "checked=$CHECKED corrected=$CORRECTED skipped=$SKIPPED deferred=$DEFERRED failed=$FAILED repos=$REPOS"
exit 0
