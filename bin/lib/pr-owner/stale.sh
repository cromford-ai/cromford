#!/bin/bash
# bin/lib/pr-owner/stale.sh — BH-3935 (BH-3929.3): the age-ladder hook of
# bin/pr-owner-sweep.sh. Sourced, never executed; nothing runs at source time.
#
# po_stale — called once per open PR, after po_enroll. Takes no args; reads the
#   sweep's per-PR context (PO_PROJECT PO_SLUG PO_NUM PO_HEAD PO_AUTHOR
#   PO_CLASS PO_KEY PO_CREATED PO_DRAFT PO_MERGEABLE PO_OWNED) and the knobs
#   PO_STALE_REBASE_H PO_STALE_REPLAN_D PO_STALE_CLOSE_D. rc 0 = acted, rc 2 =
#   declined.
#
# THE LADDER. A PR with no head movement and no verdict change for
#   rebase_hours  -> rung 1: mc_rebase (the conductor's own merge-main + gate)
#   replan_days   -> rung 2: the conductor row parks BLOCKED_HUMAN
#                    `stale-replan: …`, which hands it to bin/blocked-resolver.sh
#                    (bin/lib/br/opt/stale.sh re-plans it on the CI-park path)
#   close_days    -> rung 3: one plain comment, the PR closed, the ticket back
#                    to todo
# The highest rung that is due and switched on is the one taken; a knob of 0
# turns its rung off. Every rung is one `STALE_RUNG <rung> …` log line with its
# reason, and so is every skip.
#
# ELIGIBLE: a known head, class OWNED or EXTERNAL (never ORPHAN or PARKED), and
#   a merge-conductor row that is not READY/QUEUED/MERGING or terminal. No row
#   means the PR is not ours to age. Drafts get rung 3 only.
# THE CLOCK: max(head commit date, newest verdict, PR created_at). Any side that
#   cannot be read is no rung this tick: a failed read must never make a PR look
#   older than it is. A head the LADDER pushed is not movement: rung 1's
#   mc_rebase merges main and pushes a fresh merge commit (and rebinds the
#   verdict artifact), which would reset the clock every day on an active repo
#   so rungs 2 and 3 never fire. So rung 1 writes a `stale-carry` row whose sha
#   is "<head> <clock>" for the head it pushed (rc 0/5: mc_rebase's stdout) or,
#   on the pool path (rc 6, pushed later), for the head it read. When the current
#   head has one, or is a merge commit whose first parent has one, the carried
#   clock replaces the head-commit and verdict-artifact sides; a newer review in
#   /api/verdicts still restarts it, and so does any push that is not a merge.
#   A carried head takes no second rung 1: one rebase per idle stretch.
# ONCE PER HEAD: a pr_attempts row `stale-<rung>` on (repo, pr, head), written
#   BEFORE the side effect. A new head misses every row. Rung 3's row means
#   "commented", so a tick that finds it and the PR still open retries the close
#   only. PR_OWNER_DRY_RUN logs `DRY-RUN would:` and writes no row.
# THE CAP: this hook counts its own writes, at most $MAX_ACTIONS per repo per run;
#   a PR over it is logged `STALE_RUNG held … cap` and offered again next tick.
# Rules: docs/PR-OWNERSHIP.md §10. Tests: tests/pr-stale-ladder.bh-3929-test.sh.

_PO_STALE_LIB="${BASH_SOURCE[0]%/*}/.."

_po_stale_say() { if command -v say >/dev/null 2>&1; then say "$*"; else printf '%s\n' "$*" >&2; fi; }
_po_stale_dry() { [ "${DRY:-${PR_OWNER_DRY_RUN:-0}}" = 1 ]; }
_po_stale_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_po_epoch() { # _po_epoch <iso8601> -> epoch seconds, rc 1 when unparseable
  local e
  [ -n "${1:-}" ] || return 1
  case "$1" in -|null) return 1 ;; esac
  e=$(date -u -d "$1" +%s 2>/dev/null) || return 1
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$e"
}

# _po_stale_load — the libs the ladder needs, sourced on first use (never at
# source time), each skipped when its entry function is already defined.
_po_stale_load() {
  [ "${_PO_STALE_LOADED:-}" = 1 ] && return 0
  [ "${_PO_STALE_LOADED:-}" = 0 ] && return 1
  # shellcheck source=bin/lib/gh-rest.sh
  command -v gh_rest_close >/dev/null 2>&1 || . "$_PO_STALE_LIB/gh-rest.sh" 2>/dev/null
  # shellcheck source=bin/lib/hold.sh
  command -v hold_check >/dev/null 2>&1 || . "$_PO_STALE_LIB/hold.sh" 2>/dev/null
  if ! command -v mc_rebase >/dev/null 2>&1; then
    # shellcheck source=bin/lib/merge-conductor-lib.sh
    . "$_PO_STALE_LIB/merge-conductor-lib.sh" 2>/dev/null && MC_REHYDRATE=0 mc_init 2>/dev/null
  fi
  local f miss=""
  for f in gh_rest gh_rest_comment gh_rest_close hold_check mc_row_get mc_handoff_owns mc_transition mc_rebase \
           pr_attempt_has pr_attempt_put pr_attempt_del pr_attempt_list _jobs_req; do
    command -v "$f" >/dev/null 2>&1 || miss="$miss $f"
  done
  if [ -n "$miss" ]; then
    _PO_STALE_LOADED=0
    _po_stale_say "STALE_RUNG off this run: the ladder's helpers are not loaded (missing:$miss) — no PR aged"
    return 1
  fi
  _PO_STALE_LOADED=1
}

# _po_stale_pull — the PR object into _PO_STALE_PULL (one REST read per PR per
#   run). Called directly, never inside $( ), or the cache dies with the subshell.
#   The read goes through a FILE, never a $( ), so GH_REST_STATUS survives.
_po_stale_pull() {
  local f
  if [ "${_PO_STALE_PULL_KEY:-}" != "$PO_SLUG#$PO_NUM" ]; then
    _PO_STALE_PULL=""; _PO_STALE_PULL_KEY=""
    f=$(mktemp "${TMPDIR:-/tmp}/po-stale.XXXXXX") || return 1
    if ! gh_rest GET "repos/$PO_SLUG/pulls/$PO_NUM" > "$f"; then rm -f "$f"; return 1; fi
    _PO_STALE_PULL=$(cat "$f"); rm -f "$f"
    _PO_STALE_PULL_KEY="$PO_SLUG#$PO_NUM"
  fi
  [ -n "$_PO_STALE_PULL" ]
}

# _po_stale_since — the newest of the head commit, the newest verdict and the
#   PR's own creation, in epoch seconds, into _PO_STALE_SINCE. rc 1 when any
#   side cannot be read. Called as a plain command (GH_REST_STATUS survives).
_po_stale_since() {
  local best c rc=0 out t q url f
  _PO_STALE_SINCE=""
  best=$(_po_epoch "$PO_CREATED") || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/po-stale.XXXXXX") || return 1
  gh_rest GET "repos/$PO_SLUG/commits/$PO_HEAD" > "$f" || rc=$?
  out=$(cat "$f"); rm -f "$f"
  local p1="" carry="" crc=0 rows
  _PO_STALE_CARRIED=0
  case "$rc" in
    0)  c=$(printf '%s' "$out" | jq -r '.commit.committer.date // empty' 2>/dev/null)
        p1=$(printf '%s' "$out" | jq -r 'if ((.parents // []) | length) > 1 then .parents[0].sha // empty else empty end' 2>/dev/null) ;;
    44) # the commit is gone (force-push, gc): the PR's own last update stands in
        _po_stale_pull || return 1
        c=$(printf '%s' "$_PO_STALE_PULL" | jq -r '.updated_at // empty' 2>/dev/null) ;;
    *)  return 1 ;;
  esac
  # A clock the ladder carried over its own push (see THE CLOCK above).
  rows=$(pr_attempt_list "$PO_SLUG" "$PO_NUM" stale-carry) || crc=$?
  case "$crc" in 0|2) ;; *) return 1 ;; esac
  carry=$(printf '%s\n' "$rows" | awk -v h="$PO_HEAD" '$1 == h && $2 ~ /^[0-9]+$/ {print $2; exit}')
  [ -z "$carry" ] && [ -n "$p1" ] && carry=$(printf '%s\n' "$rows" | awk -v h="$p1" '$1 == h && $2 ~ /^[0-9]+$/ {print $2; exit}')
  if [ -n "$carry" ]; then t=$carry; _PO_STALE_CARRIED=1
  else t=$(_po_epoch "$c") || return 1; fi
  [ "$t" -gt "$best" ] && best=$t
  url="https://github.com/$PO_SLUG/pull/$PO_NUM"
  q=$(jq -nr --arg r "$PO_SLUG" --arg n "$PO_NUM" '"repo="+($r|@uri)+"&pr="+($n|@uri)') || return 1
  out=$(_jobs_req GET "/api/verdicts?$q") || return 1
  c=$(printf '%s' "$out" | jq -r 'if (.rows|type) == "array" then ((.rows[0].created_at) // "-") else error end' 2>/dev/null) || return 1
  if [ "$c" != "-" ]; then t=$(_po_epoch "$c") || return 1; [ "$t" -gt "$best" ] && best=$t; fi
  q=$(jq -nr --arg v "$url" '"pr="+($v|@uri)') || return 1
  out=$(_jobs_req GET "/api/verdict?$q"); rc=$?
  # Under a carry the artifact side is skipped: mc_rebase's approval rebind
  # rewrites it, so its updated_at is the ladder's own push, not a review.
  [ -n "$carry" ] && rc=2
  case "$rc" in
    0) for c in $(printf '%s' "$out" | jq -r '.artifacts[]? | select(.artifact_kind == "verdict") | .updated_at // empty' 2>/dev/null); do
         t=$(_po_epoch "$c") || return 1; [ "$t" -gt "$best" ] && best=$t
       done ;;
    2) ;;          # no job recorded this PR: a real "no verdict there"
    *) return 1 ;;
  esac
  _PO_STALE_SINCE="$best"
}

# _po_stale_take — spend one of this repo's writes, or log the PR held.
_po_stale_take() {
  if [ "${_PO_STALE_N:-0}" -ge "${MAX_ACTIONS:-5}" ]; then
    _po_stale_say "STALE_RUNG held $PO_SLUG#$PO_NUM cap (PR_OWNER_MAX_ACTIONS=${MAX_ACTIONS:-5} reached this run; next tick)"
    return 1
  fi
  _PO_STALE_N=$(( ${_PO_STALE_N:-0} + 1 ))
}

# _po_stale_replan_noted <project> <key> — rc 0 when the ticket already carries
#   a `KIND: ci-replan` note (the CI park re-plans it; this ladder does not).
_po_stale_replan_noted() {
  local root f; root=$(_po_stale_root)
  [ -n "$root" ] || return 1
  for f in "$root/state/build-notes/$1/$2.md" "$root/state/build-notes/$1/$2.md".*; do
    [ -f "$f" ] || continue
    [ "$(head -1 "$f" 2>/dev/null)" = "KIND: ci-replan" ] && return 0
  done
  return 1
}

po_stale() {
  local rh="${PO_STALE_REBASE_H:-0}" rd="${PO_STALE_REPLAN_D:-0}" cd="${PO_STALE_CLOSE_D:-0}"
  case "$rh" in ''|*[!0-9]*) rh=0 ;; esac
  case "$rd" in ''|*[!0-9]*) rd=0 ;; esac
  case "$cd" in ''|*[!0-9]*) cd=0 ;; esac
  rh=$((10#$rh)); rd=$((10#$rd)); cd=$((10#$cd))
  [ $((rh + rd + cd)) -gt 0 ] || return 2
  [ -n "${PO_HEAD:-}" ] && [ "$PO_HEAD" != - ] || return 2
  case "${PO_CLASS:-}" in OWNED|EXTERNAL) ;; *) return 2 ;; esac
  # The cap is per repo: a new slug starts a new count.
  if [ "${_PO_STALE_REPO:-}" != "$PO_SLUG" ]; then _PO_STALE_REPO="$PO_SLUG"; _PO_STALE_N=0; fi
  : "${PO_STALE_NOW:=$(date -u +%s)}"
  local now="$PO_STALE_NOW" created min=0 draft=0 s
  [ "${PO_DRAFT:-0}" = 1 ] && draft=1
  # THE CHEAP EARLY-OUT: younger than every enabled threshold by its own
  # creation date alone means younger by the max() too. No read is made.
  created=$(_po_epoch "${PO_CREATED:-}") || return 2
  for s in $([ "$cd" -gt 0 ] && echo $((cd * 86400))) \
           $([ "$draft" = 0 ] && [ "$rd" -gt 0 ] && echo $((rd * 86400))) \
           $([ "$draft" = 0 ] && [ "$rh" -gt 0 ] && echo $((rh * 3600))); do
    { [ "$min" = 0 ] || [ "$s" -lt "$min" ]; } && min=$s
  done
  [ "$min" -gt 0 ] || return 2
  [ $((now - created)) -ge "$min" ] || return 2
  _po_stale_load || return 2
  local row rstate rwhy url since age rung="" pr="$PO_SLUG#$PO_NUM" sha12="${PO_HEAD:0:12}"
  row=$(mc_row_get "$pr")
  [ -n "$row" ] || return 2
  rstate=$(printf '%s' "$row" | cut -f2); rwhy=$(printf '%s' "$row" | cut -f7)
  url=$(printf '%s' "$row" | cut -f8); case "$url" in https://github.com/*) ;; *) url="https://github.com/$PO_SLUG/pull/$PO_NUM" ;; esac
  case "$rstate" in READY|QUEUED|MERGING|MERGED|CLOSED|ABANDONED|'') return 2 ;; esac
  if ! _po_stale_since; then
    _po_stale_say "STALE_RUNG skip $pr $sha12 reason=the clock could not be read (head commit, verdicts or created_at; last GitHub HTTP ${GH_REST_STATUS:-?}${GH_REST_REASON:+ $GH_REST_REASON}) — no rung this tick"
    return 2
  fi
  since="$_PO_STALE_SINCE"
  age=$((now - since))
  if [ "$cd" -gt 0 ] && [ "$age" -ge $((cd * 86400)) ]; then rung=close
  elif [ "$draft" = 1 ]; then return 2
  elif [ "$rd" -gt 0 ] && [ "$age" -ge $((rd * 86400)) ]; then rung=replan
  elif [ "$rh" -gt 0 ] && [ "$age" -ge $((rh * 3600)) ]; then rung=rebase
  else return 2; fi
  # Rung 1 runs once per idle stretch: a carried clock means it already did.
  if [ "$rung" = rebase ] && [ "${_PO_STALE_CARRIED:-0}" = 1 ]; then
    _po_stale_say "STALE_RUNG skip $pr $sha12 rung=rebase reason=this head is the ladder's own rebase (clock carried); next rung at replan_days=$rd"
    return 2
  fi
  local why="no head/verdict change" done=0 arc
  pr_attempt_has "$PO_SLUG" "$PO_NUM" "stale-$rung" "$PO_HEAD"; arc=$?
  case "$arc" in
    0) [ "$rung" = close ] || return 2; done=1 ;;
    2) ;;
    *) _po_stale_say "STALE_RUNG skip $pr $sha12 rung=$rung reason=the pr_attempts ledger could not be read — nothing done this tick"
       return 2 ;;
  esac
  case "$rung" in
    rebase) _po_stale_rebase "$age" "$rwhy" "$url" "$rh" "$since" ;;
    replan) _po_stale_replan "$age" "$rwhy" "$url" "$row" ;;
    close)  _po_stale_close "$age" "$url" "$done" ;;
  esac
}

_po_stale_rebase() { # <age> <row-reason> <url> <rebase_hours> <clock-epoch>
  local age="$1" rwhy="$2" url="$3" rh="$4" since="$5" pr="$PO_SLUG#$PO_NUM" br rc out new carried=""
  local tag="$pr ${PO_HEAD:0:12} age=$(($1 / 3600))h"
  if mc_handoff_owns "$rwhy"; then
    _po_stale_say "STALE_RUNG skip $tag rung=rebase reason=bin/blocked-resolver.sh owns this park ($rwhy)"
    return 2
  fi
  br=""; _po_stale_pull && br=$(printf '%s' "$_PO_STALE_PULL" | jq -r '.head.ref // empty' 2>/dev/null)
  if [ -z "$br" ]; then
    _po_stale_say "STALE_RUNG skip $tag rung=rebase reason=the PR's branch could not be read — no rung this tick"
    return 2
  fi
  _po_stale_take || return 2
  if _po_stale_dry; then
    _po_stale_say "DRY-RUN would: STALE_RUNG rebase $tag reason=no head/verdict change (mc_rebase $PO_SLUG ${PO_PROJECT:--} $br)"
    return 0
  fi
  if ! pr_attempt_put "$PO_SLUG" "$PO_NUM" stale-rebase "$PO_HEAD"; then
    _po_stale_say "STALE_RUNG skip $tag rung=rebase reason=the attempt row could not be written — nothing done this tick"
    return 2
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/po-stale.XXXXXX") || out=/dev/null
  rc=0; mc_rebase "$PO_SLUG" "$PO_PROJECT" "$br" "$PO_HEAD" "$url" >"$out" 2>/dev/null </dev/null || rc=$?
  new=$(grep -oE '^[0-9a-f]{40}$' "$out" 2>/dev/null | tail -1); [ "$out" = /dev/null ] || rm -f "$out"
  # rc 3 is a hold or a lost lease: nothing was pushed, so the next tick asks again.
  [ "$rc" = 3 ] && pr_attempt_del "$PO_SLUG" "$PO_NUM" stale-rebase "$PO_HEAD"
  # The push is the ladder's, not movement: carry the clock onto the head it
  # made (rc 0/5), or onto the head it read when the pool pushes later (rc 6).
  case "$rc" in 0|5) ;; 6) new="$PO_HEAD" ;; *) new="" ;; esac
  if [ -n "$new" ]; then
    if pr_attempt_put "$PO_SLUG" "$PO_NUM" stale-carry "$new $since"; then carried=" clock carried to ${new:0:12}"
    else carried=" (the clock could NOT be carried to ${new:0:12}; the next rung waits on a fresh age)"; fi
  fi
  _po_stale_say "STALE_RUNG rebase $tag reason=no head/verdict change for $((age / 3600))h (rebase_hours=$rh) rc=$rc$([ "$rc" = 3 ] && echo ' (held or lease lost; retried next tick)')$carried"
  return 0
}

_po_stale_replan() { # <age> <row-reason> <url> <row>
  local age="$1" rwhy="$2" url="$3" row="$4" pr="$PO_SLUG#$PO_NUM" d skip=""
  d=$(($1 / 86400))
  local tag="$pr ${PO_HEAD:0:12} age=${d}d"
  if mc_handoff_owns "$rwhy"; then skip="bin/blocked-resolver.sh already owns this park ($rwhy)"
  elif [ -z "${PO_KEY:-}" ] || [ "$PO_KEY" = - ]; then skip="no ticket key, so there is nothing to re-plan"
  elif _po_stale_replan_noted "${PO_PROJECT:--}" "$PO_KEY"; then skip="$PO_KEY already carries a KIND: ci-replan note (the CI park re-plans it)"
  fi
  if [ -n "$skip" ]; then
    _po_stale_say "STALE_RUNG skip $tag rung=replan reason=$skip"
    return 2
  fi
  _po_stale_take || return 2
  local reason="stale-replan: no head or verdict change for ${d}d"
  if _po_stale_dry; then
    _po_stale_say "DRY-RUN would: STALE_RUNG replan $tag reason=$reason (BLOCKED_HUMAN, handed to bin/blocked-resolver.sh)"
    return 0
  fi
  if ! pr_attempt_put "$PO_SLUG" "$PO_NUM" stale-replan "$PO_HEAD"; then
    _po_stale_say "STALE_RUNG skip $tag rung=replan reason=the attempt row could not be written — nothing done this tick"
    return 2
  fi
  mc_transition "$pr" BLOCKED_HUMAN "$reason" "$PO_HEAD" "$(printf '%s' "$row" | cut -f5)" "$url" - - - >/dev/null 2>&1 </dev/null
  _po_stale_say "STALE_RUNG replan $tag reason=$reason — parked BLOCKED_HUMAN for bin/blocked-resolver.sh's re-plan"
  return 0
}

# _po_stale_close <age> <url> <commented: 0|1>
_po_stale_close() {
  local age="$1" url="$2" done="$3" pr="$PO_SLUG#$PO_NUM" d labels hrc tail key="${PO_KEY:--}" prefix="" root
  d=$((age / 86400))
  local tag="$pr ${PO_HEAD:0:12} age=${d}d"
  root=$(_po_stale_root)
  # THE GUARDS, all read before anything is written. Held or unreadable is no
  # close this tick and no row.
  if ! _po_stale_pull || ! labels=$(printf '%s' "$_PO_STALE_PULL" | jq -er '[.labels[]? | (.name // "") | ascii_downcase] | join(" ")' 2>/dev/null); then
    _po_stale_say "STALE_RUNG skip $tag rung=close reason=the PR's labels could not be read"
    return 2
  fi
  case " $labels " in *" hold "*|*" parked "*)
    _po_stale_say "STALE_RUNG skip $tag rung=close reason=labelled hold/parked"
    return 2 ;;
  esac
  hold_check "$PO_SLUG" "$PO_NUM" >/dev/null 2>&1 </dev/null; hrc=$?
  if [ "$hrc" != 0 ]; then
    _po_stale_say "STALE_RUNG skip $tag rung=close reason=$([ "$hrc" = 1 ] && echo 'the PR is held' || echo 'its hold could not be read')"
    return 2
  fi
  if [ "$key" != - ] && [ "${PO_PROJECT:--}" != - ] && [ -n "$root" ]; then
    prefix=$("$root/bin/fleet-conf.sh" "$PO_PROJECT" board_prefix 2>/dev/null </dev/null)
    if [ "$prefix" = - ]; then
      tail="${key##*-}"
      case "$tail" in ''|*[!0-9]*) hrc=2 ;; *) hold_check "$PO_SLUG" "$tail" >/dev/null 2>&1 </dev/null; hrc=$? ;; esac
      if [ "$hrc" != 0 ]; then
        _po_stale_say "STALE_RUNG skip $tag rung=close reason=ticket $key is $([ "$hrc" = 1 ] && echo held || echo 'unreadable for a hold')"
        return 2
      fi
    fi
  fi
  _po_stale_take || return 2
  local body
  body="Closing this. Nothing has moved on it for $d days: no new commits and no new review."
  [ "$key" != - ] && body="$body The ticket goes back to todo so it gets picked up fresh."
  [ "${PO_CLASS:-}" = EXTERNAL ] && body="@${PO_AUTHOR:-} $body"
  if _po_stale_dry; then
    _po_stale_say "DRY-RUN would: STALE_RUNG close $tag reason=no head/verdict change (comment, close$([ "$key" != - ] && echo ", $key to todo"))"
    return 0
  fi
  if [ "$done" = 0 ]; then
    local bf crc=0
    if ! pr_attempt_put "$PO_SLUG" "$PO_NUM" stale-close "$PO_HEAD"; then
      _po_stale_say "STALE_RUNG skip $tag rung=close reason=the attempt row could not be written — nothing done this tick"
      return 2
    fi
    bf=$(mktemp "${TMPDIR:-/tmp}/po-stale.XXXXXX") || { pr_attempt_del "$PO_SLUG" "$PO_NUM" stale-close "$PO_HEAD"; return 2; }
    printf '%s\n' "$body" > "$bf"
    gh_rest_comment "$PO_SLUG" "$PO_NUM" "$bf" </dev/null || crc=$?
    rm -f "$bf"
    if [ "$crc" != 0 ]; then
      pr_attempt_del "$PO_SLUG" "$PO_NUM" stale-close "$PO_HEAD"
      _po_stale_say "STALE_RUNG close $tag reason=no head/verdict change — the comment was refused (rc $crc), nothing posted or closed; retried next tick"
      return 0
    fi
  fi
  if ! gh_rest_close "$PO_SLUG" "$PO_NUM" pulls </dev/null; then
    _po_stale_say "STALE_RUNG close $tag reason=no head/verdict change — commented, but the close was refused; the next tick retries the close only"
    return 0
  fi
  local moved="no ticket key, no board move"
  if [ "$key" != - ]; then
    if ph_ticket_to_todo "${PO_PROJECT:--}" "$key"; then moved="$key moved to todo"
    else
      moved="$key NOT moved to todo"
      [ -n "$root" ] && [ -x "$root/bin/lane-alert.sh" ] && "$root/bin/lane-alert.sh" pr-owner-sweep/stale \
        "$pr was closed after $d days with no movement, but ticket ${PO_PROJECT:--}/$key could not be moved back to todo. Needed: move $key to todo on its board (or clear its blocked row) so it gets picked up again." \
        >/dev/null 2>&1 </dev/null
    fi
  fi
  mc_transition "$pr" CLOSED stale-close "$PO_HEAD" - "$url" - - - >/dev/null 2>&1 </dev/null
  _po_stale_say "STALE_RUNG close $tag reason=no head/verdict change for ${d}d — commented and closed; $moved"
  return 0
}

# ph_ticket_to_todo <project> <key> — the ticket goes back to todo.
#   Product board: the id from /boards -> /boards/<bid>/tickets (.key), then
#   POST /tickets/<id>/move {"toStatus":"todo"}; it counts only when the answer
#   says todo. GitHub-Issues board (board_prefix "-"): no GitHub write at all —
#   the issue stays open and labelled. Both then clear the ticket's `blocked`
#   row, the same hand-back bin/pr-owner-sweep.sh's handback makes, so its box
#   re-claims it. rc 0 moved, rc 1 not moved (logged). A dry run only logs.
ph_ticket_to_todo() {
  local p="${1:-}" k="${2:-}" root prefix base token bid tid resp
  root=$(_po_stale_root)
  if [ -z "$p" ] || [ "$p" = - ]; then _po_stale_say "STALE_RUNG move $k: no fleet project (a PR_OWNER_EXTRA_REPOS repo) — not moved"; return 1; fi
  [ -n "$k" ] && [ "$k" != - ] && [ -n "$root" ] || return 1
  if _po_stale_dry; then _po_stale_say "DRY-RUN would: move $p/$k to todo"; return 0; fi
  prefix=$("$root/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null </dev/null)
  if [ -z "$prefix" ]; then _po_stale_say "STALE_RUNG move $p/$k: board_prefix unreadable — not moved"; return 1; fi
  if [ "$prefix" != - ]; then
    base=$("$root/bin/fleet-conf.sh" "$p" prod 2>/dev/null </dev/null); [ "$base" = - ] && base=""
    token=$("$root/bin/internal-token-for.sh" "$p" 2>/dev/null </dev/null) || token=""
    if [ -z "$base" ] || [ -z "$token" ]; then _po_stale_say "STALE_RUNG move $p/$k: no board url or token on this box — not moved"; return 1; fi
    bid=$(curl -s -m 20 -H "Authorization: Bearer $token" -H "User-Agent: curl/8" "$base$prefix/boards" 2>/dev/null </dev/null \
          | jq -r 'if type=="array" then (.[0].id // empty) else (.boards[0].id // empty) end' 2>/dev/null)
    [ -n "$bid" ] && tid=$(curl -s -m 30 -H "Authorization: Bearer $token" -H "User-Agent: curl/8" "$base$prefix/boards/$bid/tickets" 2>/dev/null </dev/null \
          | jq -r --arg k "$k" 'first((if type=="array" then . else (.tickets // []) end)[] | select((.key // "") == $k) | (.id // empty)) // empty' 2>/dev/null)
    if [ -z "${tid:-}" ]; then _po_stale_say "STALE_RUNG move $p/$k: the ticket's id could not be read from the board — not moved"; return 1; fi
    resp=$(curl -s -m 25 -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" -H "User-Agent: curl/8" \
           -d "$(jq -nc '{toStatus:"todo",sortOrder:999999}')" "$base$prefix/tickets/$tid/move" 2>/dev/null </dev/null)
    if ! grep -q todo <<<"$resp"; then
      _po_stale_say "STALE_RUNG move $p/$k: the board did not confirm todo — not moved ($(printf '%.120s' "$resp"))"
      return 1
    fi
  fi
  if ! command -v cm_clear >/dev/null 2>&1 \
     || ! cm_clear "blocked $p $k" "$root/state/blocked-commented-$p-$k-*" >/dev/null 2>&1 </dev/null; then
    _po_stale_say "STALE_RUNG move $p/$k: the blocked row could not be cleared (jobs DB) — its box will not re-claim it yet"
    return 1
  fi
  return 0
}
