#!/bin/bash
# bin/lib/pr-owner/enroll.sh — BH-3933 (BH-3929.1): the enroll hook of
# bin/pr-owner-sweep.sh, and the ownerless clock. Sourced, never executed.
#
# po_enroll — called once per open PR, after po_superseded declined. Takes no
#   args; reads the sweep's per-PR context (PO_PROJECT PO_SLUG PO_NUM PO_HEAD
#   PO_AUTHOR PO_CLASS PO_KEY PO_CREATED PO_DRAFT PO_MERGEABLE PO_OWNED PO_URL
#   PO_BRANCH), the knob PO_ENROLL_EXTERNAL, this PR's conductor row
#   (PO_MC_STATE PO_MC_REASON PO_MC_HEAD PO_MC_SINCE, `-` when there is none),
#   PO_GRACE_S, PH_NOW and the run's PO_ENROLL_LIVE PO_DRY PO_MAX_ACTIONS
#   PO_ENROLL_N. rc 0 = it wrote a conductor row, rc 2 = declined.
#   Sets PO_OWNED=1 on a write, appends a READY key to PO_ENROLLED_KEYS (the
#   sweep's one keyed conductor spawn), bumps PO_ENROLL_N, and sets
#   PO_REPO_UNREAD=1 when GitHub could not be read for this repo.
#
#   Eligible: an ORPHAN nobody owns; an EXTERNAL nobody owns when
#   PO_ENROLL_EXTERNAL=1; and THE RE-CHECK SET — a READY or WAIT_CI row that this
#   hook wrote (enrolled-by-owner-sweep, enroll-withdrawn), or one stranded on a
#   head that is no longer the PR's, past the grace window, on a PR the
#   conductor's unkeyed tick does not drive by itself (an EXTERNAL one, or a
#   branch that is not ticket/* or main-red-revert/*). A row in any other state
#   is a hand-off (resolver, human, rebase) and is never touched. A target equal
#   to the row (state AND head) writes nothing.
#   READY only when the head (the PR record's row when it is fresh, else read
#   over REST; bin/lib/pr-owner/prr.sh, BH-8270) is APPROVEd, CI green, mergeable
#   state clean and not a draft — and then the `enrolled` attempt row is written
#   FIRST: no attempt row, no READY. Anything else is WAIT_CI, with no attempt
#   row and no spawn. Both writes are mc_transition under the conductor's own
#   per-PR lock, taken `flock -n`: a held lock defers to the next tick.
#   Only a fleet-wide run enrolls (the conductor and its rows live on the hub);
#   a --repo run records only.
#   WITHDRAW: with PO_ENROLL_EXTERNAL not 1, an EXTERNAL row in the re-check set
#   that is READY or ours goes to WAIT_CI enroll-withdrawn, reviewed `-`, so the
#   backstop stops picking it. Not capped: a kill switch is not rationed.
#
# ph_streak <id> <active 0|1> <hours> — rc 0 exactly once when <active> has held
#   for <hours>, measured on $PH_NOW (the caller's one clock read). The state is
#   ONE settings row, streak.<id>: `0` | `<since>` | `<since>:fired`. active=0
#   ends the streak; a fired one is resolved with `lane-alert.sh --resolve --id
#   <id>` and the row is cleared only after that send succeeded. hours=0, no
#   PH_NOW or a settings outage: rc 1, nothing written.
# ph_streak_fired <id> — stamps `:fired`. Call it only after the alert was sent.
#
# Rules: docs/PR-OWNERSHIP.md.

_po_log() { if declare -F say >/dev/null 2>&1; then say "$*"; else printf '%s\n' "$*" >&2; fi; }

# The conductor's lib, loaded once per process and only when a PR is eligible:
# mc_transition, mc_pr_lock, mc_rest_var and mc_ci_state are its, never copied.
_PO_MC_READY=""
_po_mc_ready() {
  local root="${HARNESS:-${H:-}}" m
  [ -n "$_PO_MC_READY" ] && { [ "$_PO_MC_READY" = 1 ]; return; }
  _PO_MC_READY=0
  [ -n "$root" ] && [ -r "$root/bin/lib/merge-conductor-lib.sh" ] || return 1
  for m in log locks classify queue rebase settle; do [ -r "$root/bin/lib/mc/$m.sh" ] || return 1; done
  # shellcheck source=bin/lib/merge-conductor-lib.sh
  . "$root/bin/lib/merge-conductor-lib.sh" </dev/null >/dev/null 2>&1 || return 1
  command -v mc_transition >/dev/null 2>&1 && command -v mc_pr_lock >/dev/null 2>&1 || return 1
  mc_init </dev/null >/dev/null 2>&1 || return 1
  _PO_MC_READY=1
}

po_enroll() {
  local key="${PO_SLUG:-}#${PO_NUM:-}" recheck=0 pj rc row head ms draft url ci approved=0 new lp lockf
  [ -n "${PO_SLUG:-}" ] && [[ "${PO_NUM:-}" =~ ^[0-9]+$ ]] || return 2
  case "${PO_MC_STATE:-}" in
    READY|WAIT_CI)
      case "${PO_MC_REASON:-}" in
        enrolled-by-owner-sweep|enroll-withdrawn) recheck=1 ;;
        *) # THE STRANDED ROW (review F1): the head moved, the row did not.
          if [[ "${PO_MC_HEAD:-}" =~ ^[0-9a-f]{40}$ ]] && [ "$PO_MC_HEAD" != "${PO_HEAD:-}" ] \
             && [[ "${PO_MC_SINCE:-}" =~ ^[0-9]+$ ]] && [[ "${PH_NOW:-}" =~ ^[0-9]+$ ]] \
             && [ $(( PH_NOW - PO_MC_SINCE )) -ge "${PO_GRACE_S:-1800}" ]; then
            # A harness ticket branch is the unkeyed tick's own: never rewritten here.
            case "${PO_CLASS:-}:${PO_BRANCH:-}" in
              EXTERNAL:*) recheck=1 ;;
              *:ticket/*|*:main-red-revert/*) ;;
              *) recheck=1 ;;
            esac
          fi ;;
      esac ;;
  esac
  case "${PO_CLASS:-}" in
    ORPHAN) [ "${PO_OWNED:-0}" = 1 ] && [ "$recheck" = 0 ] && return 2 ;;
    EXTERNAL)
      if [ "${PO_ENROLL_EXTERNAL:-}" != 1 ]; then
        if [ "$recheck" = 1 ] && { [ "$PO_MC_STATE" = READY ] || [ "$PO_MC_REASON" = enrolled-by-owner-sweep ]; }; then
          _po_withdraw "$key"; return 2
        fi
        _po_log "enroll-recorded-only $key (pr_owner.enroll_external=${PO_ENROLL_EXTERNAL:-unset})"; return 2
      fi
      [ "${PO_OWNED:-0}" = 1 ] && [ "$recheck" = 0 ] && return 2 ;;
    PARKED) return 2 ;; # a human's, with a date
    *) [ "$recheck" = 1 ] || return 2 ;;
  esac
  if [ "${PO_ENROLL_LIVE:-0}" != 1 ]; then _po_log "enroll-skipped $key repo-scoped run"; return 2; fi
  if [ "${PO_ENROLL_N:-0}" -ge "${PO_MAX_ACTIONS:-0}" ]; then
    _po_log "enroll-deferred $key cap=${PO_MAX_ACTIONS:-0}"; return 2
  fi
  _po_mc_ready || { _po_log "enroll-skipped no-mc-lib $key"; return 2; }

  # THE RECORD FIRST (BH-8270, bin/lib/pr-owner/prr.sh): a fresh pr_records
  # row answers the pulls/N read in the shape the code below parses. A record
  # `merged` is not `open`, the same outcome as GitHub's `closed`. On a miss
  # the GitHub read runs as before and its answer is written back.
  pj=""
  if command -v po_prr_read >/dev/null 2>&1 \
     && row=$(po_prr_read "$PO_SLUG" "$PO_NUM" state head_sha draft mergeable_state); then
    pj=$(jq -c --arg u "https://github.com/$PO_SLUG/pull/$PO_NUM" \
      '{state: (if .state == "open" then "open" else "closed" end), head: {sha: .head_sha},
        mergeable_state, draft, html_url: $u}' <<<"$row" 2>/dev/null) || pj=""
  fi
  if [ -z "$pj" ]; then
    rc=0; mc_rest_var pj gh_rest GET "repos/$PO_SLUG/pulls/$PO_NUM" || rc=$?
    if [ "$rc" != 0 ]; then
      case "${GH_REST_STATUS:-000}:$rc" in 000:*|401:*|403:*|404:*|429:*|*:75) PO_REPO_UNREAD=1 ;; esac
      _po_log "enroll-skipped $key pull unreadable (HTTP ${GH_REST_STATUS:-000}, rc $rc)"; return 2
    fi
    command -v po_prr_writeback >/dev/null 2>&1 && po_prr_writeback "$PO_SLUG" "$PO_NUM" "$pj"
  fi
  [ "$(jq -r '.state // empty' <<<"$pj" 2>/dev/null)" = open ] || return 2
  head=$(jq -r '.head.sha // empty' <<<"$pj" 2>/dev/null)
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { _po_log "enroll-skipped $key head unreadable"; return 2; }
  ms=$(jq -r '.mergeable_state // "unknown"' <<<"$pj" 2>/dev/null)
  draft=$(jq -r 'if .draft == false then "false" else "true" end' <<<"$pj" 2>/dev/null)
  url=$(jq -r '.html_url // empty' <<<"$pj" 2>/dev/null)

  rc=0; ph_review_covered "$PO_SLUG" "$PO_NUM" "$head" APPROVE || rc=$?
  case "$rc" in
    0) approved=1 ;;
    2) ;;
    *) _po_log "enroll-skipped verdict-unreadable $key"; return 2 ;;
  esac
  ci=$(mc_ci_state "$PO_SLUG" "$head")
  if [ "$ci" = unavailable ]; then
    PO_REPO_UNREAD=1; _po_log "enroll-skipped $key CI unreadable"; return 2
  fi
  new=WAIT_CI
  [ "$approved" = 1 ] && [ "$ci" = green ] && [ "$ms" = clean ] && [ "$draft" = false ] && new=READY
  # The row already says this, on this head: nothing to write, and a READY one is
  # the backstop's (head = reviewed), so no respawn either.
  if [ "$new" = "${PO_MC_STATE:-}" ] && [ "$head" = "${PO_MC_HEAD:-}" ]; then PO_OWNED=1; return 2; fi
  if [ "${PO_DRY:-0}" = 1 ]; then _po_log "DRY-RUN would: enroll $key $new"; return 2; fi

  # THE ATTEMPT ROW FIRST (D9): the keyed conductor accepts this PR only on it,
  # so a READY row without one is a PR nothing would ever evaluate.
  if [ "$new" = READY ] && ! pr_attempt_put "$PO_SLUG" "$PO_NUM" enrolled "$head" >/dev/null 2>&1; then
    _po_log "enroll-failed attempt-row $key"; return 2
  fi
  lp="${PO_PROJECT:-}"; [ -n "$lp" ] && [ "$lp" != - ] || lp="${PO_SLUG//\//_}"
  lockf=$(mc_pr_lock "$lp" "$PO_NUM")
  # A held lock is a conductor worker on this PR right now: dedupe, never a wait.
  if [ "$new" = READY ]; then
    ( flock -n 9 || exit 3
      mc_transition "$key" READY enrolled-by-owner-sweep "$head" "$head" "$url" APPROVE CLEAN - >/dev/null ) 9>"$lockf" </dev/null
  else
    ( flock -n 9 || exit 3
      mc_transition "$key" WAIT_CI enrolled-by-owner-sweep "$head" - "$url" - "${ms^^}" - >/dev/null ) 9>"$lockf" </dev/null
  fi
  rc=$?
  if [ "$rc" != 0 ]; then _po_log "enroll-deferred $key conductor-holds-lock"; return 2; fi
  PO_ENROLL_N=$(( ${PO_ENROLL_N:-0} + 1 )); PO_OWNED=1
  [ "$new" = READY ] && PO_ENROLLED_KEYS="${PO_ENROLLED_KEYS:+$PO_ENROLLED_KEYS,}$key"
  _po_log "enrolled $key $new head=${head:0:8} (approved=$approved ci=$ci merge=$ms draft=$draft)"
  return 0
}

# _po_withdraw <key> — the kill switch reached a row this hook (or the conductor)
#   left READY on an EXTERNAL PR: WAIT_CI enroll-withdrawn, reviewed `-`, so the
#   backstop stops picking it and nothing spawns. No attempt row, no REST read.
_po_withdraw() {
  local key="$1" lp lockf rc
  if [ "${PO_ENROLL_LIVE:-0}" != 1 ]; then _po_log "enroll-skipped $key repo-scoped run (withdraw)"; return 2; fi
  if [ "${PO_DRY:-0}" = 1 ]; then _po_log "DRY-RUN would: withdraw $key"; return 2; fi
  _po_mc_ready || { _po_log "enroll-skipped no-mc-lib $key (withdraw)"; return 2; }
  lp="${PO_PROJECT:-}"; [ -n "$lp" ] && [ "$lp" != - ] || lp="${PO_SLUG//\//_}"
  lockf=$(mc_pr_lock "$lp" "$PO_NUM")
  ( flock -n 9 || exit 3
    mc_transition "$key" WAIT_CI enroll-withdrawn "${PO_HEAD:--}" - "${PO_URL:--}" - "${PO_MERGEABLE:--}" - >/dev/null ) 9>"$lockf" </dev/null
  rc=$?
  if [ "$rc" != 0 ]; then _po_log "enroll-deferred $key conductor-holds-lock (withdraw)"; return 2; fi
  PO_OWNED=0
  _po_log "enroll-withdrawn $key (pr_owner.enroll_external=${PO_ENROLL_EXTERNAL:-unset})"
  return 0
}

# streak.<id lowercased, [^a-z0-9_.-] -> .>, hashed down to the 64-char key limit.
_ph_streak_key() {
  local id="${1,,}" k
  k="streak.$(printf '%s' "$id" | tr -c 'a-z0-9_.-' '.')"
  [ "${#k}" -le 64 ] || k="${k:0:47}.$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  printf '%s' "$k"
}

ph_streak() {
  local id="${1:-}" active="${2:-}" hours="${3:-}" key v rc root="${HARNESS:-${H:-}}"
  [ -n "$id" ] && [[ "$hours" =~ ^[0-9]+$ ]] && [ "$hours" -gt 0 ] || return 1
  [[ "${PH_NOW:-}" =~ ^[0-9]+$ ]] || return 1
  command -v setting_get >/dev/null 2>&1 && command -v setting_set >/dev/null 2>&1 || return 1
  key=$(_ph_streak_key "$id")
  rc=0; v=$(setting_get "$key" 2>/dev/null) || rc=$?
  case "$rc" in 0) ;; 2) v="" ;; *) return 1 ;; esac
  [ "$v" = 0 ] && v=""
  if [ "$active" = 1 ]; then
    case "$v" in
      *:fired) return 1 ;;
      ''|*[!0-9]*) setting_set "$key" "$PH_NOW" "ph_streak: $id active since this tick" >/dev/null 2>&1; return 1 ;;
    esac
    [ $(( PH_NOW - v )) -ge $(( hours * 3600 )) ] && return 0
    return 1
  fi
  case "$v" in
    '') ;;
    *:fired)
      [ -n "$root" ] && "$root/bin/lane-alert.sh" --resolve --id "$id" "${PH_STREAK_LANE:-pr-owner-sweep}" "$id cleared" \
          </dev/null >/dev/null 2>&1 \
        && setting_set "$key" 0 "ph_streak: $id cleared" >/dev/null 2>&1 ;;
    *) setting_set "$key" 0 "ph_streak: $id cleared" >/dev/null 2>&1 ;;
  esac
  return 1
}

ph_streak_fired() {
  local id="${1:-}" key v
  [ -n "$id" ] && command -v setting_get >/dev/null 2>&1 || return 1
  key=$(_ph_streak_key "$id")
  v=$(setting_get "$key" 2>/dev/null) || return 1
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  setting_set "$key" "$v:fired" "ph_streak: $id alert sent" >/dev/null 2>&1
}
