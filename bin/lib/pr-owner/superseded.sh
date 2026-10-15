#!/bin/bash
# bin/lib/pr-owner/superseded.sh — BH-3936 (BH-3929 ask 4): the superseded hook
# of bin/pr-owner-sweep.sh. Sourced, never executed. Rules: docs/PR-OWNERSHIP.md.
#
# po_superseded — called once per open PR, FIRST and before the class gate.
#   Takes no args; reads the sweep's per-PR context (PO_PROJECT PO_SLUG PO_NUM
#   PO_HEAD PO_AUTHOR PO_CLASS PO_KEY PO_EKEY PO_MERGED_DUP PO_KEEPER
#   PO_MC_STATE PO_STACKED) and its run state (PO_MC_OK N_ACT MAX_ACTIONS HELD CLOSED DRY
#   TD, say).
#   rc 0 = the PR was closed, and the sweep skips every later hook and arm for
#   it; rc 2 = declined. First match wins, whatever the class:
#     1 merged     PO_EKEY already merged in another PR (PO_MERGED_DUP). The
#                  sweep sets it only for a merge AFTER this PR was opened and
#                  only while no build job for the key is live: a PR opened
#                  after its key merged is a rebuild of a reopened ticket, not
#                  a leftover. An ORPHAN keyed by branch/title is left to the
#                  sweep's own close-duplicate arm, which does that exact
#                  close. The only rule that closes a PARKED PR, and the only
#                  one tried when the conductor's rows are unread
#                  (PO_MC_OK != 1) or the PR is UNREAD.
#     2 ticket     ph_ticket_status says done or rejected. Unreadable or
#                  unknown stops here for this tick: rule 3 is not tried. On a
#                  PRODUCT board the fleet marks a ticket done when its PR
#                  opens, before the merge, so there rule 2 skips an OWNED PR
#                  and any PR with a conductor row and goes on to rule 3.
#     3 duplicate  another open PR for the same key is the keeper (PO_KEEPER).
#                  Never a PR the blocked resolver owns (conductor row
#                  BLOCKED_HUMAN or RED_TWICE): its rebuild rung closes that
#                  one itself, after its own settle window. Never a PR that
#                  another open PR is stacked on (PO_STACKED: their base is
#                  this PR's head branch), held as `#n:stacked` (BH-6814):
#                  the close would strand them on a branch that never merges.
#   Each close is one comment then one close over REST, counted against
#   MAX_ACTIONS, held as `#n:cap` past it, logged only under DRY=1. A PR this
#   hook closed before (pr_superseded row `closed`) that is open again was
#   reopened by a human, and is never closed again. A PR or ticket under a HOLD
#   (to_merge_hold, the answer every merge lane gives) is never closed either,
#   and a hold that cannot be read holds. On an issues board the ticket's own
#   HOLD binds a lead's PR too (BH-6814): to_merge_hold exempts the lead from
#   the ticket hold for a merge, but a close is not a merge.
#
# ph_ticket_status <project> <KEY> — prints open|done|rejected|unknown, rc 0.
#   rc 1 (nothing printed) = the board could not be read. Cached per run in $TD.

_po_ss_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_po_ss_say() { if command -v say >/dev/null 2>&1; then say "$*"; else echo "$*" >&2; fi; }

# The REST helpers, loaded on first use from next to this lib. Never the CLI.
_po_ss_rest() {
  command -v gh_rest_comment >/dev/null 2>&1 && return 0
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "${BASH_SOURCE[0]%/*}/../gh-rest.sh" ] && . "${BASH_SOURCE[0]%/*}/../gh-rest.sh"
  command -v gh_rest_comment >/dev/null 2>&1
}

_ph_ts_cache_put() { [ -n "${TD:-}" ] && [ -d "$TD" ] && printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TD/po-ticket-status.tsv"; return 0; }

ph_ticket_status() {
  local p="${1:-}" k="${2:-}" root st prefix
  root=$(_po_ss_root)
  [ -n "$p" ] && [ "$p" != - ] && [ -n "$k" ] && [ "$k" != - ] && [ -n "$root" ] || return 1
  if [ -n "${TD:-}" ] && [ -r "$TD/po-ticket-status.tsv" ]; then
    st=$(awk -F'\t' -v p="$p" -v k="$k" '$1==p && $2==k {print $3; exit}' "$TD/po-ticket-status.tsv")
    [ -n "$st" ] && { printf '%s\n' "$st"; return 0; }
  fi
  prefix=$("$root/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || return 1
  [ -n "$prefix" ] || return 1
  if [ "$prefix" = - ]; then st=$(_ph_ts_issue "$root" "$p" "$k") || return 1
  else st=$(_ph_ts_board "$root" "$p" "$k" "$prefix") || return 1; fi
  _ph_ts_cache_put "$p" "$k" "$st"
  printf '%s\n' "$st"
}

# _ph_product_board <project> — rc 0 unless fleet.conf says it is an issues
# board (board_prefix `-`): an unreadable prefix is treated as a product board.
_ph_product_board() {
  local root; root=$(_po_ss_root)
  [ "$("$root/bin/fleet-conf.sh" "${1:-}" board_prefix 2>/dev/null)" != - ]
}

# Issues board: the key's digits are the issue number (mc_issue_of's rule).
_ph_ts_issue() { # <root> <project> <KEY>
  local slug n f rc=0 st
  slug=$("$1/bin/fleet-conf.sh" "$2" repo 2>/dev/null) || return 1
  n="${3##*-}"
  [[ "$n" =~ ^[0-9]+$ ]] || { echo unknown; return 0; }
  _po_ss_rest || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/po-issue.XXXXXX") || return 1
  gh_rest GET "repos/$slug/issues/$n" > "$f" || rc=$?
  case "$rc" in
    0)  ;;
    44) rm -f "$f"; echo unknown; return 0 ;;
    *)  rm -f "$f"; return 1 ;;
  esac
  st=$(jq -r 'if type != "object" then "!"
              elif has("pull_request") then "unknown"
              elif .state == "open" then "open"
              elif .state == "closed" and .state_reason == "completed" then "done"
              elif .state == "closed" and .state_reason == "not_planned" then "rejected"
              elif .state == "closed" then "unknown"
              else "!" end' "$f" 2>/dev/null) || st="!"
  rm -f "$f"
  [ "$st" = "!" ] && return 1
  printf '%s\n' "$st"
}

# Product board: every board's ticket list, once per project per run.
_ph_ts_board() { # <root> <project> <KEY> <prefix>
  local root="$1" p="$2" k="$3" prefix="$4" base tok cache out code ids id st
  base=$("$root/bin/fleet-conf.sh" "$p" prod 2>/dev/null) || return 1
  [ -n "$base" ] && [ "$base" != - ] || return 1
  tok=$("$root/bin/internal-token-for.sh" "$p" 2>/dev/null) || return 1
  [ -n "$tok" ] || return 1
  cache="${TD:-}/po-board-$p.json"
  if [ -z "${TD:-}" ] || [ ! -s "$cache" ]; then
    out=$(curl -s -m 20 -w '\n%{http_code}' -H "Authorization: Bearer $tok" -H "User-Agent: curl/8" "$base$prefix/boards" 2>/dev/null) || return 1
    code="${out##*$'\n'}"; [ "$code" = 200 ] || return 1
    ids=$(printf '%s' "${out%$'\n'*}" | jq -r '(if type=="array" then . else .boards end)[] | .id' 2>/dev/null) || return 1
    [ -n "$ids" ] || return 1
    local all='[]' one
    while IFS= read -r id; do
      out=$(curl -s -m 30 -w '\n%{http_code}' -H "Authorization: Bearer $tok" -H "User-Agent: curl/8" "$base$prefix/boards/$id/tickets" 2>/dev/null) || return 1
      code="${out##*$'\n'}"; [ "$code" = 200 ] || return 1
      one=$(printf '%s' "${out%$'\n'*}" | jq -c 'if type=="array" then . else .tickets end | if type=="array" then . else error("no list") end' 2>/dev/null) || return 1
      all=$(jq -nc --argjson a "$all" --argjson b "$one" '$a + $b') || return 1
    done <<<"$ids"
    if [ -n "${TD:-}" ] && [ -d "$TD" ]; then printf '%s' "$all" > "$cache"; else cache=$(mktemp) && printf '%s' "$all" > "$cache"; fi
  fi
  st=$(jq -r --arg k "$k" '[.[] | select((.key // "" | ascii_upcase) == $k)][0]
        | if . == null then "unknown" elif .status == "done" then "done"
          elif .status == "closed" then "rejected" else "open" end' "$cache" 2>/dev/null) || return 1
  [ -n "${TD:-}" ] || rm -f "$cache"
  printf '%s\n' "$st"
}

# _po_ss_held — rc 0 the PR or its ticket is held (one line already said why),
# rc 1 clear. bin/lib/ticket-ownership.sh's to_merge_hold, loaded in a subshell
# like the conductor lib; a box without it, or a hold it cannot read, holds.
_po_ss_held() {
  local lib="${BASH_SOURCE[0]%/*}/../ticket-ownership.sh" v rc=0
  # The redirections live INSIDE the subshell: on a bare assignment they cost
  # the substitution's exit status.
  # shellcheck source=bin/lib/ticket-ownership.sh
  # The ticket read after it (BH-6814) has no lead exemption: the key's digits
  # are the issue (_ph_ts_issue's rule), and a product board has no such ticket.
  v=$( exec </dev/null 2>/dev/null; [ -r "$lib" ] && . "$lib" || exit 3
       to_merge_hold "${PO_PROJECT:--}" "$PO_SLUG" "$PO_NUM" && exit 0
       s=$(to_issue_repo "${PO_PROJECT:--}") || exit 1
       n="${PO_EKEY:--}"; n="${n##*-}"; [[ "$n" =~ ^[0-9]+$ ]] || exit 1
       t=$(to_hold_verdict "$s" "$n"); r=$?
       case "$r" in
         0) printf 'ticket #%s is held (%s)\n' "$n" "${t#*	}"; exit 0 ;;
         2) printf 'the hold on ticket #%s could not be read (%s)\n' "$n" "${t#*	}"; exit 0 ;;
       esac
       exit 1 ) || rc=$?
  case "$rc" in
    1) return 1 ;;
    3) v="bin/lib/ticket-ownership.sh is not loadable, so a hold cannot be read" ;;
  esac
  _po_ss_say "$PO_SLUG#$PO_NUM: superseded but held — ${v:-the hold check printed nothing}"
  return 0
}

# _po_ss_mc_closed <by> — the conductor's row, through its own writer and lock.
# A subshell keeps the conductor lib's modules out of the sweep's shell.
_po_ss_mc_closed() {
  local lib="${BASH_SOURCE[0]%/*}/../merge-conductor-lib.sh"
  if ( . "$lib" && mc_transition "$PO_SLUG#$PO_NUM" CLOSED "superseded:$1" "${PO_HEAD:--}" - \
         "https://github.com/$PO_SLUG/pull/$PO_NUM" - - "" ) >/dev/null 2>&1 </dev/null; then return 0; fi
  _po_ss_say "$PO_SLUG#$PO_NUM: conductor row not written (CLOSED superseded:$1) — the conductor's closed-watch settles it"
  return 0
}

# _po_ss_close <by> <text> — one comment (deduped on the ledger), then the close.
# A `closed` pr_superseded row for an OPEN PR means we closed it once and a
# human reopened it, which is exactly what the comment invites: hands off for
# good. A ledger it cannot read cannot tell a reopen from a first close, so it
# declines too (rc 1); only a clean miss (rc 2) or another status goes ahead.
_po_ss_close() {
  local by="$1" text="$2" key="$PO_SLUG#$PO_NUM" bodyf row="" rrc=0
  if ! command -v job_ledger_row >/dev/null 2>&1; then
    _po_ss_say "$key: superseded ($by) but the jobs client is not loaded — cannot tell a reopen, not closed"; return 2
  fi
  row=$(job_ledger_row pr_superseded "$key" 2>/dev/null) || rrc=$?
  case "$rrc" in
    0) if [ "$(jq -r '.status' <<<"$row" 2>/dev/null)" = closed ]; then
         _po_ss_say "$key: superseded ($by) but we closed it before and it was reopened — hands off"; return 2
       fi ;;
    2) row="" ;;
    *) _po_ss_say "$key: superseded ($by) but the pr_superseded ledger is unreadable — not closed, retried next tick"
       HELD="${HELD:+$HELD,}#$PO_NUM:ledger-unreadable"; return 2 ;;
  esac
  if [ "${N_ACT:-0}" -ge "${MAX_ACTIONS:-5}" ]; then
    HELD="${HELD:+$HELD,}#$PO_NUM:cap"; return 2
  fi
  if _po_ss_held; then
    HELD="${HELD:+$HELD,}#$PO_NUM:hold"; return 2
  fi
  if [ "${DRY:-0}" = 1 ]; then
    _po_ss_say "DRY-RUN would: superseded close #$PO_NUM ($by)"
    N_ACT=$(( ${N_ACT:-0} + 1 )); return 0
  fi
  if ! _po_ss_rest; then
    _po_ss_say "$key: superseded ($by) but bin/lib/gh-rest.sh is not loaded — not closed"; return 2
  fi
  [ "${PO_CLASS:-}" = EXTERNAL ] && [ -n "${PO_AUTHOR:-}" ] && [ "$PO_AUTHOR" != - ] && text="@$PO_AUTHOR $text"
  if [ -n "$row" ] && [ "$(jq -r '.status + " " + ((.detail | fromjson? // {}).by // "")' <<<"$row" 2>/dev/null)" = "commented $by" ]; then
    :  # told them already; only the close is owed
  else
    bodyf="${TD:-${TMPDIR:-/tmp}}/po-superseded-$PO_NUM.md"
    printf '%s\n\n_bin/pr-owner-sweep.sh_\n' "$text" > "$bodyf" || return 2
    if ! gh_rest_comment "$PO_SLUG" "$PO_NUM" "$bodyf"; then
      _po_ss_say "$key: superseded ($by) comment failed — not closed, retried next tick"
      HELD="${HELD:+$HELD,}#$PO_NUM:comment-failed"; return 2
    fi
    command -v job_ledger_put >/dev/null 2>&1 &&
      job_ledger_put pr_superseded "$key" commented "$(jq -nc --arg b "$by" '{by:$b}')" >/dev/null 2>&1
  fi
  if ! gh_rest_close "$PO_SLUG" "$PO_NUM" pulls; then
    _po_ss_say "$key: superseded ($by) close failed — the next tick retries the close"
    HELD="${HELD:+$HELD,}#$PO_NUM:close-failed"; return 2
  fi
  command -v job_ledger_put >/dev/null 2>&1 &&
    job_ledger_put pr_superseded "$key" closed "$(jq -nc --arg b "$by" '{by:$b}')" >/dev/null 2>&1
  N_ACT=$(( ${N_ACT:-0} + 1 ))
  CLOSED="${CLOSED:+$CLOSED,}#$PO_NUM(superseded:$by)"
  _po_ss_say "$key: ${PO_CLASS:-?} closed (superseded:$by)"
  [ "${PO_MC_STATE:--}" != - ] && _po_ss_mc_closed "$by"
  return 0
}

po_superseded() {
  local ek="${PO_EKEY:--}" cls="${PO_CLASS:-}" dup="${PO_MERGED_DUP:--}" keep="${PO_KEEPER:--}" st rc
  [ "$ek" != - ] && [ -n "${PO_SLUG:-}" ] && [ -n "${PO_NUM:-}" ] || return 2
  # 1. The key already merged in another PR.
  if [ "$dup" != - ] && [ "$dup" != "$PO_NUM" ]; then
    [ "$cls" = ORPHAN ] && [ "${PO_KEY:--}" != - ] && return 2   # the close-duplicate arm's
    _po_ss_close "merged-#$dup" "Closing this one: $ek already shipped in #$dup, so this branch is a leftover. If something here didn't make it in, reopen it and say so."
    return
  fi
  # PARKED is closed by rule 1 only.
  [ "$cls" = PARKED ] && return 2
  # Rules 2 and 3 read the conductor's rows (the product-board skip, the
  # keeper, the resolver guard): unread rows would fail all three open, and an
  # UNREAD PR's owner is unknown, not absent (docs/PR-OWNERSHIP.md §10).
  if [ "${PO_MC_OK:-0}" != 1 ] || [ "$cls" = UNREAD ]; then
    _po_ss_say "${PO_SLUG}#$PO_NUM: conductor rows unread — rules 2 and 3 not tried for $ek this tick"
    return 2
  fi
  # 2. The ticket itself is finished.
  st=$(ph_ticket_status "${PO_PROJECT:--}" "$ek"); rc=$?
  if [ "$rc" != 0 ] || [ "$st" = unknown ] || [ -z "$st" ]; then
    _po_ss_say "${PO_SLUG}#$PO_NUM: superseded-unknown — $ek status ${st:-unreadable}, no superseded action this tick"
    return 2
  fi
  case "$st" in
    done|rejected)
      if { [ "$cls" = OWNED ] || [ "${PO_MC_STATE:--}" != - ]; } && _ph_product_board "${PO_PROJECT:--}"; then
        _po_ss_say "${PO_SLUG}#$PO_NUM: $ek is $st on a product board, but the PR is ${cls:-?}/${PO_MC_STATE:--} and the fleet marks done before the merge — rule 2 skipped"
      else
        _po_ss_close "ticket-$st" "Closing this one: $ek is marked $st on the board, so nothing here is waiting to ship. If that's wrong, reopen the ticket and this PR and say so."
        return
      fi ;;
  esac
  # 3. An older duplicate of the PR that stays.
  if [ "$keep" != - ] && [ "$keep" != "$PO_NUM" ]; then
    case "${PO_MC_STATE:--}" in
      BLOCKED_HUMAN|RED_TWICE)
        _po_ss_say "${PO_SLUG}#$PO_NUM: older duplicate of #$keep, but the blocked resolver owns it (${PO_MC_STATE}) — its rebuild rung closes it"
        return 2 ;;
    esac
    if [ "${PO_STACKED:--}" != - ]; then
      _po_ss_say "${PO_SLUG}#$PO_NUM: older duplicate of #$keep, but #${PO_STACKED//,/, #} is stacked on its branch — closing it would strand that PR, kept"
      HELD="${HELD:+$HELD,}#$PO_NUM:stacked"; return 2
    fi
    local by="newer-#$keep"
    [ "$keep" -lt "$PO_NUM" ] 2>/dev/null && by="ready-#$keep"
    _po_ss_close "$by" "Closing this one: #$keep is the PR for $ek that we're landing, so this one is a duplicate. If it has something #$keep doesn't, reopen it and say so."
    return
  fi
  return 2
}
