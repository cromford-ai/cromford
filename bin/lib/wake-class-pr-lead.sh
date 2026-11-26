#!/bin/bash
# bin/lib/wake-class-pr-lead.sh — BH-1034 wake class `pr-lead` (BH-9582, part C
# of BH-9559): the lead review is asked for on the PR event, not on the */15
# cron.
#
# ON BY DEFAULT. wc_pr_lead_default_on answers 0, so bin/wake-loop.sh arms this
# class with no `wake-lanes-pr-lead` flag. flags/wake-lanes-off still beats it.
# The two kill switches are read at dispatch, on a drain that holds a PR event:
#   settings row lead_review.event_wake.enabled = 0 (seeded 1)
#   lead-chain-wake-off (lane_switch file mode: a settings row, else
#   flags/lead-chain-wake-off), the same switch lcw_ring obeys.
#
# WHAT IT DOES. A `pr` wake whose event is pull_request.opened, .reopened,
# .ready_for_review or .synchronize (the head moved) names a PR that has a new
# head to review. The wake row carries the PR number and the event, but not the
# head or the draft flag, so the dispatch reads the PR once on GitHub. An open,
# non-draft PR in a LEAD_REVIEW_AUTO_REPOS repo gets
# `lcw_ring lead-review <slug> <n> <head>` (bin/lib/lead-chain-wake.sh): one
# lane row, dedupe lead-review:<n>@<head12>. The next drain on this box claims
# that row and launches bin/lead-review.sh tick. Whether a review runs is still
# that lane's decision (lr_start per head, spend and concurrency caps,
# LEAD_REVIEW_RERUN_MAX). Every other event is ignored here.
#
# WHO RINGS. Only the box that owns the repo. The hub claims every repo's pr
# rows for the merge conductor and runs no lead review (bin/wake-loop.sh drops
# its lead-review rows), so on the hub this class does nothing.
#
# BOUNDED. At most lead_review.event_wake.reads_max GitHub reads per drain
# (settings row, whole number 1..200, code fallback 20). The PRs over the cap
# get one say line. Every miss (a read that fails, a ring the worker refuses,
# no repo list) is one say line; the */15 cron is the backstop.
#
# THE PR RECORD (BH-9938, BH-9926 wave 6). The PR read goes through
# prr_read wake-loop (bin/lib/prr-shadow.sh) and the seam
# bin/lib/prr-shadow.d/wake-loop.sh (wl_pr_record, wl_pr_github, wl_pr_norm),
# step row lane.wake-loop.gh_source (env GH_SOURCE): off = GitHub only, shadow
# = both and act on GitHub, record = the record, GitHub on a miss. The cap
# counts GitHub reads only: a read the record served (PRR_SOURCE=record) does
# not spend it. Over the cap, step record still asks the record (no PRR_MISS
# line on a miss there) and only a record miss counts as over the cap. With no
# prr-shadow lib or no seam, the read is the inline GitHub read as before.
#
# SOURCE-TIME RULE. wake-loop.sh sources this file BEFORE it defines say(), so
# nothing here runs at source time except the accumulator below.
# shellcheck shell=bash

# "<lowercased owner/repo>#<n>" entries, space separated, deduped per drain.
WC_PR_LEAD_PRS=""

# wc_pr_lead_default_on — rc 0: arm this class with no class flag (BH-9582).
wc_pr_lead_default_on() { return 0; }

# _wc_pr_lead_say <text> — say() when the loop defined it, else nothing.
_wc_pr_lead_say() { declare -F say >/dev/null 2>&1 && say "$1"; return 0; }

# wc_pr_lead_row <project> <kind> <key> <event> <repo> <id>
wc_pr_lead_row() {
  local p="${1:-}" kind="${2:-}" key="${3:-}" event="${4:-}" repo="${5:-}" e
  [ "$kind" = pr ] && [ -n "$p" ] || return 0
  case "$event" in
    pull_request.opened|pull_request.reopened|pull_request.ready_for_review|pull_request.synchronize) ;;
    *) return 0 ;;
  esac
  [[ $key =~ ^[1-9][0-9]{0,8}$ ]] && [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 0
  # The hub reviews nothing; off the hub the loop already dropped foreign rows,
  # and this is the second guard.
  [ "${IS_HUB:-0}" = 1 ] && return 0
  declare -F owns >/dev/null 2>&1 && owns "$p" || return 0
  e="$(printf '%s' "$repo" | tr 'A-Z' 'a-z')#$key"
  case " $WC_PR_LEAD_PRS " in
    *" $e "*) ;;
    *) WC_PR_LEAD_PRS="${WC_PR_LEAD_PRS:+$WC_PR_LEAD_PRS }$e" ;;
  esac
  return 0
}

# wc_pr_lead_dispatch — once per non-empty drain. Always rc 0, and the
# accumulator is empty on every return.
wc_pr_lead_dispatch() {
  local q="$WC_PR_LEAD_PRS" v repos cap e slug n body f state draft head rc read=0 left=0 prr=0 step=off tmpf=""
  WC_PR_LEAD_PRS=""
  [ -n "$q" ] || return 0
  # Kill row. Fallback 1 (on) when there is no row, an outage, or another value:
  # settings row lead_review.event_wake.enabled.
  v=""
  command -v setting_get >/dev/null 2>&1 && v=$(setting_get lead_review.event_wake.enabled 2>/dev/null)
  [ "$v" = 0 ] && { _wc_pr_lead_say "pr-lead: off (lead_review.event_wake.enabled=0)"; return 0; }
  # Kill flag, read here to save the GitHub reads; lcw_ring reads it again.
  if ! declare -F lcw_ring >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lead-chain-wake.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lead-chain-wake.sh" 2>/dev/null || true
  fi
  declare -F lcw_ring >/dev/null 2>&1 || { _wc_pr_lead_say "pr-lead: bin/lib/lead-chain-wake.sh missing; the */15 cron covers it"; return 0; }
  _lcw_off && { _wc_pr_lead_say "pr-lead: off (lead-chain-wake-off)"; return 0; }
  # The lead-review repos, read exactly as bin/lead-review.sh reads them: the
  # lead-review-land lane's knob, in a subshell so its other knobs stay there.
  repos=$( { command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lead-review-land >/dev/null 2>&1; } || true
           printf '%s' "${LEAD_REVIEW_AUTO_REPOS:-}" )
  repos=" $(printf '%s' "$repos" | tr 'A-Z,' 'a-z ' | tr -s ' \t\n' ' ') "
  [ -n "${repos// /}" ] || { _wc_pr_lead_say "pr-lead: no lead-review repos; the */15 cron covers it"; return 0; }
  # Read cap: settings row lead_review.event_wake.reads_max, 1..200, fallback 20.
  cap=""
  command -v setting_get >/dev/null 2>&1 && cap=$(setting_get lead_review.event_wake.reads_max 2>/dev/null)
  if [[ $cap =~ ^[0-9]{1,3}$ ]] && [ "$((10#$cap))" -ge 1 ] && [ "$((10#$cap))" -le 200 ]; then
    cap=$((10#$cap))
  else
    cap=20
  fi
  if ! declare -F gh_rest_var >/dev/null 2>&1; then
    # shellcheck source=bin/lib/gh-rest.sh
    . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" 2>/dev/null || true
  fi
  # The PR record (BH-9938): prr_read and the wake-loop seam, from this lib's
  # own dir. Either one absent = the inline read below, as before.
  if ! declare -F prr_read >/dev/null 2>&1 && [ -r "$(dirname "${BASH_SOURCE[0]}")/prr-shadow.sh" ]; then
    # shellcheck source=bin/lib/prr-shadow.sh
    . "$(dirname "${BASH_SOURCE[0]}")/prr-shadow.sh" 2>/dev/null || true
  fi
  if declare -F prr_read >/dev/null 2>&1 \
     && { declare -F wl_pr_record >/dev/null 2>&1 || prr_seam_load wake-loop 2>/dev/null; } \
     && declare -F wl_pr_record >/dev/null 2>&1 && declare -F wl_pr_github >/dev/null 2>&1 \
     && declare -F wl_pr_norm >/dev/null 2>&1 \
     && tmpf=$(mktemp "${TMPDIR:-/tmp}/wc-pr-lead.XXXXXX" 2>/dev/null); then
    prr=1; step=$(prr_step wake-loop)
  fi
  for e in $q; do
    slug="${e%#*}"; n="${e##*#}"
    case "$repos" in *" $slug "*) ;; *) continue ;; esac
    body=""
    if [ "$prr" = 1 ]; then
      if [ "$read" -ge "$cap" ]; then
        # Over the cap: no GitHub read. Step record still rings on a record hit.
        if [ "$step" = record ] && wl_pr_record "$tmpf" "$slug" "$n" >/dev/null 2>&1; then
          body=$(cat "$tmpf" 2>/dev/null)
        else
          left=$((left + 1)); continue
        fi
      else
        rc=0; PRR_SOURCE=github
        prr_read wake-loop "$slug#$n" "$tmpf" wl_pr_record wl_pr_github wl_pr_norm "$slug" "$n" || rc=$?
        [ "${PRR_SOURCE:-github}" = record ] || read=$((read + 1))
        [ "$rc" = 0 ] && body=$(cat "$tmpf" 2>/dev/null)
      fi
      if [ -n "$body" ]; then
        f=$(jq -r '[(.state // ""), ((.draft // false) | tostring), (.head.sha // "")] | join("|")' <<<"$body" 2>/dev/null) || f=""
      else
        f=""
      fi
    else
      if [ "$read" -ge "$cap" ]; then left=$((left + 1)); continue; fi
      read=$((read + 1))
      # gh_rest_var, never $(gh_rest ...): a command substitution drops the
      # GH_REST_STATUS the helper sets (gh-rest-no-subshell-lint).
      if declare -F gh_rest_var >/dev/null 2>&1 && gh_rest_var body GET "repos/$slug/pulls/$n"; then
        f=$(jq -r '[(.state // ""), ((.draft // false) | tostring), (.head.sha // "")] | join("|")' <<<"$body" 2>/dev/null) || f=""
      else
        f=""
      fi
    fi
    IFS='|' read -r state draft head <<<"$f"
    head=$(printf '%s' "${head:-}" | tr 'A-F' 'a-f')
    if ! [[ $head =~ ^[0-9a-f]{40}$ ]]; then
      _wc_pr_lead_say "pr-lead: $slug#$n: PR read failed; the */15 cron covers it"
      continue
    fi
    [ "$state" = open ] && [ "$draft" = false ] || continue
    rc=0
    ( lcw_ring lead-review "$slug" "$n" "$head" ) || rc=$?
    if [ "$rc" = 0 ]; then
      _wc_pr_lead_say "pr-lead: $slug#$n @${head:0:12}: lead-review doorbell rung"
    else
      _wc_pr_lead_say "pr-lead: $slug#$n @${head:0:12}: doorbell not rung (rc $rc); the */15 cron covers it"
    fi
  done
  [ -n "$tmpf" ] && rm -f "$tmpf"
  [ "$left" -gt 0 ] && _wc_pr_lead_say "pr-lead: $left PR(s) over the read cap of $cap; the */15 cron covers them"
  return 0
}
