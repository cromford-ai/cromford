#!/bin/bash
# shellcheck shell=bash
# bin/lib/fix-round-offer.sh — BH-9905: what happens next after a BLOCK verdict
# row. Sourced by bin/lead-verdict.sh (post, BLOCK, --source human|lead),
# never run.
#
# A standing human or lead BLOCK row on a PR's live head is a fix-round
# candidate of bin/blocked-resolver.sh (bin/blocked-resolver.d/
# bh-9905-verdict-block.sh). fro_offer_line tells the person who posted it
# whether that round will be offered, or the first reason it will not:
#   1. lane_switch blocked-resolver-disabled (the lane's kill switch)
#   2. automerge-disabled (the fleet kill switch; the lane only observes),
#      read with flag_active only (no flag_active: unknown)
#   3. lane_paused blocked-resolver <project> (all-off, lane-off-blocked-resolver[-<project>])
#   4. the knob BR_VERDICT_BLOCK = 0 (lane_env_apply reads its settings row)
#   5. on a box that holds the resolver's records ($HARNESS/state/
#      blocked-resolver/<project>/, the hub): a record that names this PR url
#      already ran a round on this head (review_fix_heads), or its fix-round
#      count is at the review cap (review.fix_rounds_max, else
#      BR_REVIEW_FIX_ROUNDS, else 2 — br_review_fix_cap's order), or it is
#      ABANDONED
# Else: "will be offered on the next blocked-resolver tick". Where step 5
# cannot run (no records on this box, a Mac), the line says the cap is checked
# on the hub. A switch that cannot be read prints "unknown (...)", never
# "will be offered". The root is ${HARNESS:-${H:-}} only; with none, unknown.

# fro_offer_line <owner/repo> <pr> <head-sha> — prints one line, no newline.
fro_offer_line() {
  local repo="${1:-}" pr="${2:-}" head root rc p sdir url f st n cap oc
  head=$(printf '%s' "${3:-}" | tr 'A-F' 'a-f')
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || { printf 'fix round: unknown (no harness root to read the switches from)'; return 0; }
  if ! command -v lane_switch >/dev/null 2>&1 && [ -r "$root/bin/lib/lane-switch.sh" ]; then
    # shellcheck source=bin/lib/lane-switch.sh
    . "$root/bin/lib/lane-switch.sh" 2>/dev/null
  fi
  command -v lane_switch >/dev/null 2>&1 || { printf 'fix round: unknown (could not read blocked-resolver-disabled)'; return 0; }
  if lane_switch blocked-resolver-disabled; then
    printf 'fix round: not offered: blocked-resolver-disabled is on'; return 0
  fi
  # The lane reads this switch with flag_active (bin/blocked-resolver.sh
  # flag_on). The caller loads it through bin/jobs-client.sh; without it the
  # switch is not read here, so the answer is unknown (rc 2), never a guess.
  rc=2
  command -v flag_active >/dev/null 2>&1 && { flag_active automerge-disabled; rc=$?; }
  case "$rc" in
    0) printf 'fix round: not offered: the automerge kill switch (automerge-disabled) is on'; return 0 ;;
    1) ;;
    *) printf 'fix round: unknown (could not read automerge-disabled)'; return 0 ;;
  esac
  p=$("$root/bin/project-of.sh" --repo "$repo" 2>/dev/null) || p=""
  if command -v lane_paused >/dev/null 2>&1 && lane_paused blocked-resolver "$p"; then
    printf 'fix round: not offered: the blocked-resolver lane is off%s' "${p:+ for $p}"; return 0
  fi
  # The knob as the lane reads it: its settings row through lane_env_apply.
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply blocked-resolver "$p" >/dev/null 2>&1
  case "${BR_VERDICT_BLOCK:-1}" in
    0) printf 'fix round: not offered: BR_VERDICT_BLOCK is 0'; return 0 ;;
  esac
  sdir="$root/state/blocked-resolver/$p"
  if [ -z "$p" ] || [ ! -d "$sdir" ]; then
    printf 'fix round: will be offered on the next blocked-resolver tick (the cap is checked on the hub; this box holds no resolver state)'
    return 0
  fi
  cap="${BR_REVIEW_FIX_ROUNDS:-2}"
  if ! command -v rl_knob >/dev/null 2>&1 && [ -r "$root/bin/lib/review-level.sh" ]; then
    # shellcheck source=bin/lib/review-level.sh
    . "$root/bin/lib/review-level.sh" 2>/dev/null
  fi
  command -v rl_knob >/dev/null 2>&1 && cap=$(rl_knob review.fix_rounds_max "$p" "$cap" '^[0-9]{1,2}$' 2>/dev/null)
  case "$cap" in ''|*[!0-9]*) cap=2 ;; esac
  url="https://github.com/$repo/pull/$pr"
  for f in "$sdir"/*.json; do
    [ -f "$f" ] || continue
    st=$(jq -c --arg u "$url" 'select([.. | strings] | index($u) != null)' "$f" 2>/dev/null)
    [ -n "$st" ] || continue
    if jq -e --arg h "$head" '(.review_fix_heads // []) | index($h) != null' <<<"$st" >/dev/null 2>&1; then
      printf 'fix round: not offered: a fix round already ran on %s' "${head:0:12}"; return 0
    fi
    n=$(jq -r '.fixrounds // 0' <<<"$st" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
    oc=$(jq -r '.outcome // ""' <<<"$st" 2>/dev/null)
    if [ "$oc" = ABANDONED ] || [ "$n" -ge "$cap" ]; then
      printf 'fix round: not offered: the fix-round cap is spent (%s of %s)' "$n" "$cap"; return 0
    fi
  done
  printf 'fix round: will be offered on the next blocked-resolver tick'
}
