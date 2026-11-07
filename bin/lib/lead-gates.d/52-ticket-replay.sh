#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/52-ticket-replay.sh — the ticket replay (BH-9154, Fix 3
# and AT3 of #9066): one lead review per ticket per real diff in 24 h.
#   Gate 50 replays the lead's word across heads of ONE PR. A ticket that is
#   rebuilt (ticket/<key>-r2) or re-planned opens a NEW PR, often with the
#   reviewed patch on a newer main, and that PR used to buy a full lead review
#   again. bin/lib/lead-review/result.sh stores each done model lead verdict
#   under (repo, ticket key, patch fp) in the harness-jobs lead_ticket_verdicts
#   table; this gate reads it for the head of another PR.
#   The rule, in order (any step that fails = rc 0, a full review, with one
#   log line unless noted):
#     LEAD_TICKET_REPLAY is not 1                rc 0, no read, no line.
#     gate 10 passed the head on a person's HUMAN-STEP-DONE answer
#                                                rc 0, no line (gate 50's rule).
#     LEAD_TICKET_REPLAY_WINDOW_S outside 60..604800, no lead token on this box
#       (bin/lead-verdict.sh cannot post), the PR body unreadable
#       (lgs_pr_body, 55-snapshot.sh, one read per process), no ticket key in
#       its head ref or title (patch_ticket_key, bin/lib/patch-fp.sh; no line),
#       no clone, a failed fetch, no fingerprint (patch_review_fp).
#     GET /api/lead-ticket-verdicts?repo=&ticket_key=&patch_fp=&window_s=
#       unreadable                               `ticket verdict read failed`.
#       row null                                 `no stored lead word ...`.
#       the row is this PR's own                 rc 0 (gate 50 owns it).
#       a BLOCK                                  `stored BLOCK ... is not replayed`.
#     a MERGE or MERGE-WITH-NOTES: on the harness repo with console-ui/src/
#       changed and no QA: PASS naming it, cqg_replay_hold holds the replay
#       (gate 50's BH-5909 rule) and the head is reviewed. Else
#       bin/lead-verdict.sh post <word> --source lead --note
#       "lead-replay:<src12> how:ticket-replay rebound: ticket-replay
#       <src-pr>@<src12> ticket:<KEY>" --review-mode <the row's mode>. The
#       `lead-replay:` note keeps the row out of gate 50's and lw_replay's
#       sources. Exit 0, 4 or 5 (recorded): one review_saving_event
#       (REUSED, how=ticket-replay), the `rebound: ticket-replay` line, rc 12.
#       Any other exit: `not recorded`, rc 0. The post comes BEFORE the saving
#       event, so a failed post never counts a saving.
#   Attempts are not read or written here: a hit is decided, a miss is the
#   normal review with the normal attempt cap (3 a head).
# Knobs: catalog/lanes.d/_lib.lead-ticket-replay.json (lib_env_apply
# lead-ticket-replay, once per process). Sourced by bin/lib/lead-gates.sh, never run.

# shellcheck source=bin/lib/patch-fp.sh
command -v patch_review_fp >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../patch-fp.sh" 2>/dev/null || true
# shellcheck source=bin/lib/review-saving.sh
command -v review_saving_event >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../review-saving.sh" 2>/dev/null || true
# shellcheck source=bin/lib/console-qa-gate.sh
command -v cqg_replay_hold >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../console-qa-gate.sh" 2>/dev/null || true

declare -g _LGTR_KNOBS=""

lg_gate_ticket_replay() {
  local slug="$1" n="$2" head h12="${3:0:12}" root="${HARNESS:-${H:-}}" win tok bf ref title tkey project repo fp q d out
  local w spr ssha smode s12 prc box hrepo cqh
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  if [ -z "$_LGTR_KNOBS" ]; then
    _LGTR_KNOBS=1
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply lead-ticket-replay >/dev/null 2>&1
  fi
  [ "${LEAD_TICKET_REPLAY:-1}" = 1 ] || return 0
  [ "${LGB_KEY:-}" = "$slug#$n@$head" ] && [ "${LGB_STEPDONE:-0}" = 1 ] && return 0
  win="${LEAD_TICKET_REPLAY_WINDOW_S:-86400}"
  if ! [[ "$win" =~ ^[0-9]+$ ]] || [ "$win" -lt 60 ] || [ "$win" -gt 604800 ]; then
    _lgt_log "$slug#$n @$h12: LEAD_TICKET_REPLAY_WINDOW_S='$win' is not 60..604800; no ticket replay"; return 0
  fi
  tok="${LEAD_VERDICT_TOKEN_FILE:-${HOME:-}/.config/cromford/lead-verdict-token}"
  [ -r "$tok" ] || { _lgt_log "$slug#$n @$h12: no lead token on this box; no ticket replay"; return 0; }
  if ! command -v lgs_pr_body >/dev/null 2>&1 || ! lgs_pr_body "$slug" "$n" || ! bf="${LGS_BODY_FILE:-}" || [ ! -s "$bf" ]; then
    _lgt_log "$slug#$n @$h12: PR body unreadable; no ticket replay"; return 0
  fi
  ref=$(jq -r '.head.ref // ""' "$bf" 2>/dev/null); title=$(jq -r '.title // ""' "$bf" 2>/dev/null)
  tkey=$(patch_ticket_key "$ref" "$title" 2>/dev/null) || return 0
  project=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-$root/fleet.conf}" 2>/dev/null)
  repo="${REPOS_ROOT:-/root/repos}/$project"
  if [ -z "$project" ] || [ ! -d "$repo/.git" ]; then _lgt_log "$slug#$n @$h12: no checkout at $repo; no ticket replay"; return 0; fi
  if ! command -v patch_same_fetch >/dev/null 2>&1 || ! patch_same_fetch "$repo" "$head" "$head" "$n"; then
    _lgt_log "$slug#$n @$h12: fetch failed (${PS_FETCH_ERR:-patch-same not loaded}); no ticket replay"; return 0
  fi
  fp=$(patch_review_fp "$repo" origin/main "$head" 2>/dev/null) \
    || { _lgt_log "$slug#$n @$h12: no patch fingerprint; no ticket replay"; return 0; }
  q=$(jq -rn --arg r "$slug" --arg k "$tkey" --arg f "$fp" --arg w "$win" \
    '"repo=\($r|@uri)&ticket_key=\($k|@uri)&patch_fp=\($f|@uri)&window_s=\($w)"')
  d=$(lgs_dir 2>/dev/null) || { _lgt_log "$slug#$n @$h12: no scratch dir; no ticket replay"; return 0; }
  out="$d/ltv-$n"
  if ! JOBS_ALERT=0 _jobs_req GET "/api/lead-ticket-verdicts?$q" > "$out" 2>/dev/null \
     || ! jq -e 'has("row") and ((.row == null) or (.row | type) == "object")' "$out" >/dev/null 2>&1; then
    _lgt_log "$slug#$n @$h12: ticket verdict read failed; full review"; return 0
  fi
  IFS=$'\t' read -r w spr ssha smode < <(jq -r '.row // empty | [(.verdict // ""), (.pr // "" | tostring), ((.head_sha // "") | ascii_downcase), (.review_mode // "")] | @tsv' "$out" 2>/dev/null)
  if [ -z "${w:-}" ]; then
    _lgt_log "$slug#$n @$h12: no stored lead word for ticket $tkey at this fp inside $win s; full review"; return 0
  fi
  [[ "$ssha" =~ ^[0-9a-f]{40}$ ]] && [[ "$spr" =~ ^[0-9]+$ ]] || { _lgt_log "$slug#$n @$h12: the stored ticket verdict is malformed; full review"; return 0; }
  [ "$spr" = "$n" ] && return 0
  s12=${ssha:0:12}
  case "$w" in
    MERGE|MERGE-WITH-NOTES) ;;
    *) _lgt_log "$slug#$n @$h12: stored $w from $spr@$s12 (ticket $tkey) is not replayed; full review"; return 0 ;;
  esac
  # BH-5909: a replayed MERGE would skip the console QA gate.
  hrepo=$(awk '$1 == "cromford" {print $2; exit}' "${FLEET_CONF:-$root/fleet.conf}" 2>/dev/null)
  if [ -n "$hrepo" ] && command -v cqg_replay_hold >/dev/null 2>&1 && command -v _lgd_cqg_on >/dev/null 2>&1 && _lgd_cqg_on \
     && cqh=$(cqg_replay_hold "$slug" "$n" "$head" "$repo" origin/main "$hrepo"); then
    _lgt_log "$slug#$n @$h12: no ticket replay of $w from $spr@$s12 ($cqh); full review"; return 0
  fi
  case "$smode" in full|intent) ;; *) smode=full ;; esac
  box="${JOBS_BOX:-}"; [ -n "$box" ] || box=$(local_box_name 2>/dev/null)
  prc=0; out=$("$root/bin/lead-verdict.sh" post "$slug" "$n" "$head" "$w" --source lead --reviewer "box:${box:-unknown}" \
    --note "lead-replay:$s12 how:ticket-replay rebound: ticket-replay $spr@$s12 ticket:$tkey" --review-mode "$smode" 2>&1) || prc=$?
  case "$prc" in
    0|4|5)
      command -v review_saving_event >/dev/null 2>&1 \
        && review_saving_event "$project" lead-review "$slug" "$n" "$head" REUSED "how=ticket-replay from=$spr@$s12 ticket=$tkey"
      _lgt_log "$slug#$n @$h12: lead $w from $spr@$s12 (ticket $tkey); rebound: ticket-replay $spr@$s12; no review (post rc $prc)"
      return 12 ;;
  esac
  _lgt_log "$slug#$n @$h12: lead $w from $spr@$s12 not recorded (post rc $prc: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)); full review"
  return 0
}
