#!/bin/bash
# bin/lib/deploy-rollback-guard.sh — the gate in front of the deploy train's
# automatic rollback. Sourced by bin/deploy-train.sh, never executed.
#
# THE INCIDENT. On project-4 the train failed verify on one target every hour from
# 2026-10-13 14:03Z to 2026-10-14 18:03Z, and every run cut a new
# `rollback/<minute>` branch and opened a new PR: 110 PRs, each with a
# merge-queue marker, filled the conductor window and project-4 merged nothing for
# four days. This gate makes that one decision per target.
#
# ONE CALL, drg_gate, once per failed verify with DEPLOY_ROLLBACK=on:
#   1 LIST   the open PRs over REST. A HARNESS rollback PR has a `rollback/`
#            head AND the body marker below. A list that does not answer is
#            UNKNOWN, never "none" (#768).
#   2 SWEEP  a harness rollback PR older than max_age_min is commented on and
#            closed, its merge-queue marker removed, its target row `closed`.
#            At most DRG_SWEEP_MAX per run; the log line names what is left.
#   3 DEDUPE a `deploy_train_rollback` ledger row for <project>@<target> in ANY
#            status, or an open harness PR that names the target (full
#            `Rollback-Target:` line, else the legacy `failed to serve <t8>`)
#            or reverts the same sha set, is `dup`.
#   4 AGE    now minus the newest committer time of the batch > max_age_min is
#            `stale`; an unreadable time is `unknown`.
#   5 CAP    open harness rollback PRs left after the sweep >= max_open is `cap`.
#   else `open`: rc 0, and the caller opens the PR and calls drg_record.
# A non-open verdict writes its log line, its beat (cap, stale, unknown) and its
# row (cap, stale), and returns 1. `cap` and `stale` write a row so the next run
# on the same target is `dup`: one beat per target, not one per hour.
#
# Inputs are the caller's globals: PROJECT SLUG TARGET SHAS REPO_DIR LOG.
# Outputs: DRG_VERDICT, DRG_URL (the known PR of a `dup`, or empty), DRG_REASON.
# Clock seam: DEPLOY_ROLLBACK_NOW (epoch seconds).
#
# gh-rest: no-graphql
if [ -n "${DRG_LIB:-}" ]; then return 0 2>/dev/null; fi
DRG_LIB=1
# shellcheck source=bin/lib/gh-rest-list.sh
. "$(dirname "${BASH_SOURCE[0]}")/gh-rest-list.sh" 2>/dev/null

DRG_KIND=deploy_train_rollback
DRG_MARK='Automatic rollback (deploy train'
DRG_SWEEP_MAX=20
DRG_VERDICT=; DRG_URL=; DRG_REASON=; DRG_MAX_OPEN=1; DRG_MAX_AGE_MIN=120

_drg_now() {
  case "${DEPLOY_ROLLBACK_NOW:-}" in ''|*[!0-9]*) date -u +%s ;; *) printf '%s\n' "$DEPLOY_ROLLBACK_NOW" ;; esac
}
_drg_log() { [ -n "${LOG:-}" ] && echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [${PROJECT:-?}] $*" >> "$LOG"; return 0; }
_drg_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _drg_knob <setting key> <env value> <default> -> prints the value.
# setting row -> env -> default. A value that is not a whole number is the
# default plus one log line, never a clamp.
_drg_knob() {
  local key="$1" env="$2" def="$3" v="" rc=2
  if command -v setting_get >/dev/null 2>&1; then
    v=$(setting_get "$key" 2>/dev/null); rc=$?
  fi
  if [ "$rc" != 0 ]; then v="$env"; [ -n "$v" ] || { printf '%s' "$def"; return 0; }; fi
  case "$v" in
    ''|*[!0-9]*) _drg_log "rollback guard: bad value '$v' for $key — using $def"; printf '%s' "$def" ;;
    *) printf '%s' "$((10#$v))" ;;
  esac
}

drg_knobs() {
  DRG_MAX_OPEN=$(_drg_knob "deploy_train.rollback_max_open.$PROJECT" "${DEPLOY_ROLLBACK_MAX_OPEN:-}" 1)
  DRG_MAX_AGE_MIN=$(_drg_knob deploy_train.rollback_max_age_min "${DEPLOY_ROLLBACK_MAX_AGE_MIN:-}" 120)
  _drg_log "rollback guard: max_open=$DRG_MAX_OPEN max_age_min=$DRG_MAX_AGE_MIN"
}

# drg_open_list <outfile> — the open harness rollback PRs, reduced to
# {number,url,created_s,target,legacy8,reverted[]}. rc 0 only on a full list.
drg_open_list() {
  local out="$1" raw rc=0 GH_REST_TIMEOUT_S=30
  command -v gh_rest_pr_list_all >/dev/null 2>&1 || { DRG_REASON="REST list helper not loaded"; return 75; }
  raw=$(mktemp "${TMPDIR:-/tmp}/drg.XXXXXX") || { DRG_REASON="no temp file"; return 75; }
  gh_rest_pr_list_all "$SLUG" open 1000 > "$raw" || rc=$?
  if [ "$rc" != 0 ]; then
    DRG_REASON="open-PR list rc $rc (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON})"
    rm -f "$raw"; return "$rc"
  fi
  jq -c --arg mark "$DRG_MARK" '
    [ .[] | select(((.head.ref // "") | startswith("rollback/")) and ((.body // "") | contains($mark)))
      | (.body // "" | split("\n") | map(sub("\r$"; ""))) as $l
      | { number, url: (.html_url // ""),
          created_s: (try (.created_at | fromdateiso8601) catch null),
          target: ([$l[] | select(startswith("Rollback-Target:")) | ltrimstr("Rollback-Target:") | gsub(" "; "")] | .[0] // null),
          legacy8: ([.body // "" | match("failed to serve ([0-9a-f]{8})"; "g") | .captures[0].string] | .[0] // null),
          reverted: ([$l[] | select(startswith("Reverted:")) | ltrimstr("Reverted:") | split(" ")[] | select(length > 0)] | unique) } ]' \
    "$raw" > "$out" 2>/dev/null || rc=75
  rm -f "$raw"
  [ "$rc" = 0 ] || { DRG_REASON="open-PR list did not parse"; return 75; }
  return 0
}

_drg_detail() { # _drg_detail <pr or ""> <url or ""> <time key> -> the row detail JSON
  jq -nc --arg pr "$1" --arg url "$2" --arg k "$3" --arg at "$(date -u -d "@$(_drg_now)" '+%Y-%m-%dT%H:%M:%SZ')" --arg shas "${SHAS:-}" \
    '{pr: (if $pr == "" then null else ($pr|tonumber) end), url: (if $url == "" then null else $url end),
      reverted: ($shas | split("\n") | map(select(length > 0)) | .[0:20])} + {($k): $at}'
}
_drg_put() { # _drg_put <target> <status> <detail>
  command -v job_ledger_put >/dev/null 2>&1 || return 1
  job_ledger_put "$DRG_KIND" "$PROJECT@$1" "$2" "$3" >/dev/null 2>&1
}

# drg_sweep <listfile> — closes the stale harness rollback PRs and rewrites
# the list to the PRs still open. DRG_SWEPT names the closed PRs; the caller,
# which queued them, dequeues them (state/merge-queue is a merge_queue row path).
drg_sweep() {
  # shellcheck disable=SC2034 # GH_REST_TIMEOUT_S is read by gh_rest through dynamic scope
  local list="$1" now max_s n url tgt created age stale left swept=0 body keep GH_REST_TIMEOUT_S=30
  now=$(_drg_now); max_s=$(( DRG_MAX_AGE_MIN * 60 ))
  stale=$(jq -r --argjson now "$now" --argjson m "$max_s" \
    '.[] | select(.created_s != null and ($now - .created_s) > $m) | [.number, .url, (.target // "-"), .created_s] | @tsv' "$list" 2>/dev/null)
  [ -n "$stale" ] || return 0
  body=$(mktemp "${TMPDIR:-/tmp}/drg.XXXXXX") || return 0
  printf 'The deploy train closed this automatic rollback. It is older than %s minutes, so production has moved on or the target is stale. The train opens a new rollback only for a new failed target.\n' "$DRG_MAX_AGE_MIN" > "$body"
  keep=""
  while IFS=$'\t' read -r n url tgt created; do
    [ -n "$n" ] || continue
    [ "$swept" -lt "$DRG_SWEEP_MAX" ] || break
    swept=$((swept+1))
    age=$(( (now - created) / 60 ))
    gh_rest_comment "$SLUG" "$n" "$body" >/dev/null || _drg_log "rollback sweep: comment on PR #$n failed (HTTP ${GH_REST_STATUS:-000}) — closing anyway"
    if gh_rest_close "$SLUG" "$n" pulls >/dev/null; then
      DRG_SWEPT="$DRG_SWEPT $n"
      [ "$tgt" = - ] || _drg_put "$tgt" closed "$(_drg_detail "$n" "$url" closed_at)" \
        || _drg_log "rollback sweep: PR #$n closed but its ledger row could not be set closed"
      keep="$keep $n"
      _drg_log "rollback swept PR #$n (age ${age}m > ${DRG_MAX_AGE_MIN}m)"
    else
      _drg_log "rollback sweep: close of PR #$n failed (HTTP ${GH_REST_STATUS:-000}) — left open, retried next run"
    fi
  done <<<"$stale"
  rm -f "$body"
  left=$(( $(grep -c . <<<"$stale") - swept ))
  [ "$left" -gt 0 ] && _drg_log "rollback sweep: closed at most $DRG_SWEEP_MAX this run, $left left for the next run"
  if [ -n "$keep" ]; then
    jq -c --arg c "$keep" '($c | split(" ") | map(select(length > 0) | tonumber)) as $gone | map(select(.number as $x | $gone | index($x) | not))' \
      "$list" > "$list.n" 2>/dev/null && mv "$list.n" "$list"
  fi
  return 0
}

# drg_decide <listfile or ""> — sets DRG_VERDICT / DRG_URL / DRG_REASON.
# An empty listfile is "the list did not answer".
drg_decide() {
  local list="${1:-}" row rc=1 st m sha ct newest="" now open
  DRG_URL=
  if command -v job_ledger_row >/dev/null 2>&1; then
    row=$(job_ledger_row "$DRG_KIND" "$PROJECT@$TARGET" 2>/dev/null); rc=$?
    if [ "$rc" = 0 ]; then
      st=$(jq -r '.status // empty' <<<"$row" 2>/dev/null)
      DRG_URL=$(jq -r '(.detail // "") | (if type == "string" then (try fromjson catch {}) else . end) | .url // empty' <<<"$row" 2>/dev/null)
    fi
  elif command -v job_ledger_get >/dev/null 2>&1; then
    st=$(job_ledger_get "$DRG_KIND" "$PROJECT@$TARGET" 2>/dev/null); rc=$?
  fi
  if [ "$rc" = 0 ]; then
    m=$(grep -oE '[0-9]+$' <<<"$DRG_URL")
    DRG_VERDICT=dup; DRG_REASON="ledger row $PROJECT@${TARGET:0:8} ${st:-?}${m:+ PR #$m}"; return 0
  fi
  if [ -z "$list" ]; then DRG_VERDICT=unknown; return 0; fi
  m=$(jq -r --arg t "$TARGET" --arg s "${SHAS:-}" '
      ($s | split("\n") | map(select(length > 0)) | unique) as $set
      | [ (.[] | select(.target == $t or (.target == null and .legacy8 == ($t[0:8]))) | "names target\t\(.number)\t\(.url)"),
          (.[] | select(($set | length) > 0 and .reverted == $set) | "reverts the same shas\t\(.number)\t\(.url)") ]
      | .[0] // empty' "$list" 2>/dev/null)
  if [ -n "$m" ]; then
    DRG_URL=$(cut -f3 <<<"$m")
    DRG_VERDICT=dup; DRG_REASON="open PR #$(cut -f2 <<<"$m") $(cut -f1 <<<"$m")"
    [ "$(cut -f1 <<<"$m")" = "names target" ] && DRG_REASON="$DRG_REASON ${TARGET:0:8}"
    return 0
  fi
  now=$(_drg_now)
  while read -r sha; do
    [ -n "$sha" ] || continue
    ct=$(git -C "$REPO_DIR" show -s --format=%ct "$sha" 2>/dev/null)
    case "$ct" in ''|*[!0-9]*) DRG_VERDICT=unknown; DRG_REASON="commit time of ${sha:0:8} unreadable"; return 0 ;; esac
    [ -z "$newest" ] || [ "$ct" -gt "$newest" ] && newest=$ct
  done <<<"${SHAS:-}"
  [ -n "$newest" ] || { DRG_VERDICT=unknown; DRG_REASON="no batch commit time"; return 0; }
  if [ $(( now - newest )) -gt $(( DRG_MAX_AGE_MIN * 60 )) ]; then
    DRG_VERDICT=stale; DRG_REASON="batch age $(( (now - newest) / 60 ))m > ${DRG_MAX_AGE_MIN}m"; return 0
  fi
  open=$(jq 'length' "$list" 2>/dev/null)
  case "$open" in ''|*[!0-9]*) DRG_VERDICT=unknown; DRG_REASON="open-PR list unreadable"; return 0 ;; esac
  if [ "$open" -ge "$DRG_MAX_OPEN" ]; then
    DRG_VERDICT=cap; DRG_REASON="$open open >= max $DRG_MAX_OPEN"; return 0
  fi
  DRG_VERDICT=open; DRG_REASON="$open open < max $DRG_MAX_OPEN"
}

_drg_beat() { # _drg_beat <akey prefix> <line> [severity]
  local root; root=$(_drg_root); [ -n "$root" ] || return 0
  "$root/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "$1:$PROJECT:${TARGET:0:8}" --arg l "$2" --arg sev "${3:-}" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l} + (if $sev == "" then {} else {severity:$sev} end)')" >/dev/null 2>&1
  return 0
}

# drg_gate — rc 0 = open a rollback PR; rc 1 = do not (DRG_VERDICT says why).
drg_gate() {
  local list lrc=0
  DRG_VERDICT=; DRG_URL=; DRG_REASON=; DRG_SWEPT=
  drg_knobs
  list=$(mktemp "${TMPDIR:-/tmp}/drg.XXXXXX") || list=""
  if [ -n "$list" ]; then
    drg_open_list "$list" || lrc=$?
    if [ "$lrc" = 0 ]; then drg_sweep "$list"; else rm -f "$list"; list=""; fi
  else
    DRG_REASON="no temp file"
  fi
  drg_decide "$list"
  [ -z "$list" ] || rm -f "$list"
  case "$DRG_VERDICT" in
    open) return 0 ;;
    dup) _drg_log "rollback skipped (dup): $DRG_REASON" ;;
    cap)
      _drg_log "rollback skipped (cap): $DRG_REASON"
      _drg_beat rollback-cap "DEPLOY TRAIN: $PROJECT failed to serve ${TARGET:0:8} and $DRG_REASON automatic rollback PR(s) — no new rollback opened. Land or close the open rollback first." critical
      _drg_put "$TARGET" capped "$(_drg_detail "" "" capped_at)" || _drg_log "rollback guard: capped row for ${TARGET:0:8} not written — the next run beats again" ;;
    stale)
      _drg_log "rollback skipped (stale): $DRG_REASON"
      _drg_beat rollback-stale "DEPLOY TRAIN: $PROJECT failed to serve ${TARGET:0:8}, but the $DRG_REASON — no revert opened. Production is likely on a newer sha, or the target is stale; check the deploy."
      _drg_put "$TARGET" stale "$(_drg_detail "" "" stale_at)" || _drg_log "rollback guard: stale row for ${TARGET:0:8} not written — the next run beats again" ;;
    *)
      DRG_VERDICT=unknown
      _drg_log "rollback skipped (unknown): ${DRG_REASON:-no reason}"
      _drg_beat rollback-unknown "DEPLOY TRAIN: $PROJECT failed to serve ${TARGET:0:8} and the rollback gate could not decide (${DRG_REASON:-no reason}) — no revert opened; the next run retries." ;;
  esac
  return 1
}

# drg_record <pr number> <pr url> — the `opened` row, after gh pr create.
drg_record() {
  _drg_put "$TARGET" opened "$(_drg_detail "$1" "$2" opened_at)" \
    || _drg_log "rollback guard: opened row for ${TARGET:0:8} (PR #$1) not written — the body's Rollback-Target line still dedupes"
}
