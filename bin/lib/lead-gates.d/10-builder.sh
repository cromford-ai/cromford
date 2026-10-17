#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/10-builder.sh — gate 1 of bin/lead-review-enqueue.sh,
# ported to the worklist (BH-3545, BH-5630, BH-6696; BH-5878): the builder's verdict on the PR
# (job_verdict, GET /api/verdict?pr=) decides.
#   REQUEST_CHANGES or BLOCK bound to
#     this head, a confirmed non-lead
#     author, and a person's answer         rc 0: lsd_check (bin/lib/lead-step-done.sh)
#                                           finds a HUMAN-STEP-DONE: or RESUME
#                                           comment after the NEEDS-HUMAN: step and
#                                           after the verdict. LGB_STEPDONE=1, the
#                                           reqfor and stepdone_note fields are set;
#                                           gate 50 replays nothing, gate 60 signs
#                                           nothing off (BH-6696).
#   BLOCK bound to this head (or to no
#     full sha), not answered              rc 10 [skip builder-block]: the fix round owns it.
#   any other non-APPROVE word on this
#     head, not answered                   rc 10 [skip no-approve].
#     A check lsd_check could not run (rc 2) ends either skip text with
#     `; human-step check: <why>`.
#   a non-APPROVE word bound to an
#     EARLIER full sha                     unapproved (a fix round pushed since;
#                                           BH-6696, second case), as below.
#   APPROVE bound to this head             rc 0, approved.
#   APPROVE on an earlier head, and the
#     head-bound gate says reapproved@head rc 0, approved and rebound.
#   APPROVE on an earlier head A, and
#     bc_carry proves this head carries
#     A's patch (BH-7043)                 rc 0, approved and carried (LGB_CARRIED=1),
#                                         one `builder APPROVE carried from <A12>
#                                         (how:<how>)` line. bin/lib/builder-carry.sh,
#                                         the enqueue's builder-carry.tsv cache; the
#                                         clone is fleet.conf's (gate 50's rule).
#                                         LGB_REQFOR names the carry, as the
#                                         enqueue's REQFOR does. Gate 50 takes
#                                         the carry back on an unread history
#                                         or a lead BLOCK; gate 60 signs a
#                                         carried head off only as a lead
#                                         rules-text low (no reviewer approved it).
#   no builder row (rc 2), or APPROVE on
#     an earlier head                     unapproved: with
#       LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1, rc 10 [skip no-approve]; else rc 0
#       when CI is green on this head (lr_ci_green, the base branch's
#       .mergify.yml; reqfor `CI green`), else rc 11.
#   ledger unreadable (rc 1)              rc 11.
# The enqueue skipped an unreadable ledger; here it is a hold (a failed read is
# a hold). Under REQB=1 the enqueue still tried its replay on an unapproved
# head before it skipped it; here the skip comes first, so no review starts.
# The CI base is the repo's default branch (GET repos/<slug>, one read per repo
# per process): a worklist item carries no PR base. The knob is the lead-review
# lane's registry row, read once per process (lane_env_apply in a subshell).
# The author comes from the PR body gate 55 reads once (lgs_pr_body) and the
# lead_pr_authors row (to_is_lead): unreadable = not confirmed, so no answer
# counts. Gate 50 reads LGB_KEY (<slug>#<n>@<head>), LGB_APPROVED, LGB_REBOUND,
# LGB_RSHA, LGB_STEPDONE and LGB_CARRIED; gate 60 reads LGB_REQFOR.
# Sourced by bin/lib/lead-gates.sh, never run.

# shellcheck source=bin/lib/lead-step-done.sh
command -v lsd_check >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lead-step-done.sh" 2>/dev/null || true
# shellcheck source=bin/lib/ticket-ownership.sh
command -v to_is_lead >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../ticket-ownership.sh" 2>/dev/null || true

declare -g _LGB_REQB=""
declare -gA _lgb_base=() _lgb_base_rc=()
declare -g LGB_APPROVED=0 LGB_REBOUND=0 LGB_RSHA="" LGB_CARRIED=0
declare -g LGB_KEY="" LGB_STEPDONE=0 LGB_SDNOTE="" LGB_REQFOR=""
declare -g _LGB_DIR="${BASH_SOURCE[0]%/*}"

# _lgb_carry <slug> <n> <approved-sha> <head> — rc 0 when bc_carry
#   (bin/lib/builder-carry.sh, BH-7043) carries the APPROVE to <head>.
_lgb_carry() {
  local slug="$1" n="$2" a="$3" head="$4" root="${HARNESS:-${H:-}}" fc project rc=0
  [ -n "$root" ] || return 1
  command -v patch_same >/dev/null 2>&1 || { [ -r "$_LGB_DIR/../patch-same.sh" ] && . "$_LGB_DIR/../patch-same.sh"; }
  command -v bc_carry >/dev/null 2>&1 || { [ -r "$_LGB_DIR/../builder-carry.sh" ] && . "$_LGB_DIR/../builder-carry.sh"; }
  command -v bc_carry >/dev/null 2>&1 || return 1
  fc="${FLEET_CONF:-$root/fleet.conf}"
  project=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "$fc" 2>/dev/null)
  [ -n "$project" ] || return 1
  bc_carry "${REPOS_ROOT:-/root/repos}/$project" "$slug" "$n" "$a" "$head" "$root/state/lead-review-enqueue" || rc=$?
  [ "$rc" = 2 ] && _lgt_log "$slug#$n @${head:0:12}: builder APPROVE on ${a:0:12} not carried: $BC_WHY"
  return "$rc"
}

# _lgb_skip <slug> <n> <head> <class> <text> — lgs_skip_once (05-skip-ledger.sh);
#   without it the `[skip <class>]` line is logged on every tick.
_lgb_skip() {
  if command -v lgs_skip_once >/dev/null 2>&1; then lgs_skip_once "$@"
  else _lgt_log "[skip $4] $1#$2 @${3:0:12} $5"; fi
}

lg_tick_builder() {
  [ -n "$_LGB_REQB" ] && return 0
  _LGB_REQB=$(command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lead-review >/dev/null 2>&1
    printf '%s' "${LEAD_REVIEW_REQUIRE_BUILDER_APPROVE:-0}")
  [ "$_LGB_REQB" = 1 ] || _LGB_REQB=0
  return 0
}

# _lgb_ci_green <slug> <n> <head> — rc 0 when lr_ci_green says CI is green on
#   <head>; else rc 1 and _LGB_WHY says why.
_lgb_ci_green() {
  local slug="$1" n="$2" head="$3" d f base mf
  _LGB_WHY=""
  command -v lr_ci_green >/dev/null 2>&1 || { _LGB_WHY="no lead ci green block in bin/lead-review.sh"; return 1; }
  d=$(lgs_dir 2>/dev/null) || { _LGB_WHY="no scratch dir"; return 1; }
  if [ -z "${_lgb_base_rc[$slug]+x}" ]; then
    gh_rest_var f GET "repos/$slug" || _lgb_base_rc[$slug]=$?
    _lgb_base_rc[$slug]="${_lgb_base_rc[$slug]:-0}"
    _lgb_base[$slug]=$(jq -r '.default_branch // empty' <<<"$f" 2>/dev/null)
  fi
  base="${_lgb_base[$slug]}"
  if [ "${_lgb_base_rc[$slug]}" != 0 ] || [ -z "$base" ]; then
    _LGB_WHY="default branch of $slug unreadable (rc ${_lgb_base_rc[$slug]})"; return 1
  fi
  # One .mergify.yml read per (repo, base) per process, named by a hash as in the enqueue.
  mf="$d/mergify-$(printf '%s\n%s' "$slug" "$base" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-32)"
  if [ ! -e "$mf.read" ]; then
    : > "$mf"; : > "$mf.read"
    gh_rest GET "repos/$slug/contents/.mergify.yml?ref=$(jq -rn --arg b "$base" '$b|@uri')" > "$mf.json" 2>/dev/null \
      && jq -r '.content // empty' "$mf.json" 2>/dev/null | tr -d '\n' | base64 -d > "$mf" 2>/dev/null
  fi
  # shellcheck disable=SC2034  # read by lr_ci_fetch: one check-run read per head
  LR_CI_SHA=""
  lr_ci_green "$slug" "$head" "$mf" "$d/checks-$n" && return 0
  _LGB_WHY="${LR_CI_WHY:-unknown}"; return 1
}

# _lgb_stepdone <slug> <n> <head> <url> <word> — rc 0 when a person answered
#   the step the builder's <word> on this head raised (LSDNOTE, LSDLOG set);
#   rc 1 not answered; rc 2 with _LGB_SDWHY when the check could not run.
_lgb_stepdone() {
  local slug="$1" n="$2" head="$3" url="$4" word="$5" prf who rc=0
  _LGB_SDWHY=""
  command -v lsd_check >/dev/null 2>&1 || return 1
  command -v lgs_pr_body >/dev/null 2>&1 && lgs_pr_body "$slug" "$n" || rc=$?
  prf="${LGS_BODY_FILE:-}"
  if [ "$rc" != 0 ] || [ ! -s "$prf" ]; then _LGB_SDWHY="the PR body is unreadable"; return 2; fi
  who=$(jq -r '.user.login // empty' "$prf" 2>/dev/null)
  # Only a confirmed non-lead author: a lead PR is the lead's to request by hand.
  command -v to_is_lead >/dev/null 2>&1 && [ -n "$who" ] || return 1
  to__lead_load
  [ -n "${TO_LEAD_AUTHORS:-}" ] || return 1
  to_is_lead "$who" && return 1
  rc=0; lsd_check "$slug" "$prf" "$url" "$word" || rc=$?
  [ "$rc" = 2 ] && _LGB_SDWHY="$LSDWHY"
  return "$rc"
}

lg_gate_builder() {
  local slug="$1" n="$2" head h12="${3:0:12}" url jv jrc=0 v="" rsha="" hb sdrc=1 sdwhy=""
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  url="https://github.com/$slug/pull/$n"
  [ -n "$_LGB_REQB" ] || lg_tick_builder "$slug"
  LGB_KEY=""; LGB_APPROVED=0; LGB_REBOUND=0; LGB_RSHA=""; LGB_CARRIED=0; LGB_STEPDONE=0; LGB_SDNOTE=""; LGB_REQFOR=""
  jv=$(job_verdict "$url" 2>/dev/null) || jrc=$?
  case "$jrc" in
    0) IFS=$'\t' read -r v _ _ _ _ rsha <<<"$jv"; rsha=$(printf '%s' "$rsha" | tr 'A-F' 'a-f') ;;
    2) ;;
    *) _lgt_log "$slug#$n @$h12: builder verdict unreadable (rc $jrc); held"; return 11 ;;
  esac
  LGB_KEY="$slug#$n@$head"; LGB_RSHA="$rsha"
  if [ "$jrc" = 0 ] && [ "$v" != APPROVE ] && [[ "$rsha" =~ ^[0-9a-f]{40}$ ]] && [ "$rsha" != "$head" ]; then
    # BH-6696, second case: a refusal of an EARLIER head does not stand here.
    if [ "$_LGB_REQB" = 1 ]; then
      _lgb_skip "$slug" "$n" "$head" no-approve \
        "the builder's $v is on ${rsha:0:12}, not this head, and LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1"
      return 10
    fi
    _lgt_log "$slug#$n @$h12: the builder's $v is on ${rsha:0:12}, an earlier head; it does not stand on this head"
  elif [ "$jrc" = 0 ] && [ "$v" != APPROVE ]; then
    if { [ "$v" = REQUEST_CHANGES ] || [ "$v" = BLOCK ]; } && [ "$rsha" = "$head" ]; then
      _lgb_stepdone "$slug" "$n" "$head" "$url" "$v"; sdrc=$?
      [ "$sdrc" = 2 ] && sdwhy="; human-step check: $_LGB_SDWHY"
    fi
    if [ "$sdrc" = 0 ]; then
      LGB_APPROVED=1; LGB_STEPDONE=1; LGB_SDNOTE="$LSDNOTE"; LGB_REQFOR="HUMAN-STEP-DONE after the builder's $v"
      _lgt_log "$slug#$n @$h12: the builder's $v is answered by $LSDLOG; starting a lead review on the same head"
      return 0
    fi
    if [ "$v" = BLOCK ]; then
      _lgb_skip "$slug" "$n" "$head" builder-block "builder BLOCK; the fix round owns it$sdwhy"; return 10
    fi
    _lgb_skip "$slug" "$n" "$head" no-approve "builder verdict '$v' is not APPROVE$sdwhy"; return 10
  elif [ "$jrc" = 0 ]; then
    if [ "$rsha" = "$head" ]; then LGB_APPROVED=1; return 0; fi
    hb=$(job_verdict_headbound "$url" 2>/dev/null | tr 'A-F' 'a-f')
    if [ "$hb" = "reapproved@$head" ]; then LGB_APPROVED=1; LGB_REBOUND=1; return 0; fi
    if [[ "$rsha" =~ ^[0-9a-f]{40}$ ]] && _lgb_carry "$slug" "$n" "$rsha" "$head"; then
      LGB_APPROVED=1; LGB_REBOUND=0; LGB_CARRIED=1
      LGB_REQFOR="builder APPROVE carried from ${rsha:0:12} (how:$BC_HOW)"
      _lgt_log "$slug#$n @$h12: builder APPROVE carried from ${rsha:0:12} (how:$BC_HOW)"
      return 0
    fi
  fi
  # Unapproved: no builder row, an APPROVE on an earlier head, or a refusal of one.
  if [ "$_LGB_REQB" = 1 ]; then
    _lgb_skip "$slug" "$n" "$head" no-approve \
      "no builder APPROVE on this head${rsha:+ (it is on ${rsha:0:12})}, and LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1"
    return 10
  fi
  if _lgb_ci_green "$slug" "$n" "$head"; then LGB_REQFOR="CI green"; return 0; fi
  _lgt_log "$slug#$n @$h12: no builder APPROVE on this head and CI not known green ($_LGB_WHY); held"
  return 11
}

# The fields of this head's job and scope notes (BH-5878).
lg_field_reqfor() {
  [ "$LGB_KEY" = "$1#$2@$(printf '%s' "$3" | tr 'A-F' 'a-f')" ] && printf '%s' "$LGB_REQFOR"
  return 0
}
lg_field_stepdone_note() {
  [ "$LGB_KEY" = "$1#$2@$(printf '%s' "$3" | tr 'A-F' 'a-f')" ] && [ "$LGB_STEPDONE" = 1 ] && printf '%s' "$LGB_SDNOTE"
  return 0
}
