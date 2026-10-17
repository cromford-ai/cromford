#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/15-lead-lane-commit.sh — BH-5873 (BH-5870.0): gate 12 of
# bin/lead-review-enqueue.sh, ported to the worklist. The lead lane never verdicts
# its own work: a head whose compare holds a non-merge commit with a line
# starting `Lead-Lane:` is skipped (rc 10), with one lane-alert warn per
# (PR, head), on the lead-review lane. The classifier is the enqueue's
# rt_compare jq; the alert id (lead-self-<slug_>-<n>-<sha12>), text and marker
# (state/lead-review-enqueue/alerted-<id>) are the enqueue's, so a head the
# enqueue alerted on is not alerted again.
# The compare base is the PR's own base (one GET repos/<slug>/pulls/<n> read for
# .base.ref), as gate 12 compares against baseRefName: a stacked PR's compare
# then lists only its own commits, not its parent branch's.
# Unreadable PR base, unreadable or truncated compare, or no harness root =
# hold (rc 11). Sourced by bin/lib/lead-gates.sh, never run.

lg_gate_lead_lane_commit() {
  local slug="$1" n="$2" head="$3" h12="${3:0:12}" root="${HARNESS:-${H:-}}" base f crc=0 hit safe id mark text
  if [ -z "$root" ]; then _lgt_log "no harness root; $slug#$n @$h12 held"; return 11; fi
  # The PR body through gate 16's one read per process (55-snapshot.sh), when
  # it is loaded, so the item costs one pulls/<n> read for both gates.
  if declare -F lgs_pr_body >/dev/null; then
    lgs_pr_body "$slug" "$n" || crc=$?
    f=$(cat "${LGS_BODY_FILE:-/dev/null}" 2>/dev/null)
  else
    gh_rest_var f GET "repos/$slug/pulls/$n" || crc=$?
  fi
  base=$(jq -r '.base.ref // empty' <<<"$f" 2>/dev/null)
  if [ "$crc" != 0 ] || [ -z "$base" ]; then
    _lgt_log "compare base of $slug#$n unreadable (rc $crc); @$h12 held"; return 11
  fi
  gh_rest_var f GET "repos/$slug/compare/$(jq -rn --arg b "$base" '$b|@uri')...$head" || crc=$?
  hit=$(jq -r 'if (.commits|type) != "array" or (.total_commits|type) != "number" then "unreadable"
    elif .total_commits > (.commits|length) then "truncated"
    else ([.commits[] | select((.parents|length) < 2) | .commit.message // "" | split("\n")[] | select(test("^Lead-Lane:"))] | length > 0) end' \
    <<<"$f" 2>/dev/null)
  [ "$crc" = 0 ] || hit=unreadable
  case "$hit" in
    false) return 0 ;;
    true) ;;
    *) _lgt_log "$slug#$n @$h12: compare $base...$h12 unreadable (rc $crc, ${hit:-unparseable}); held"; return 11 ;;
  esac
  safe=$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')
  id="lead-self-$safe-$n-$h12"; mark="$root/state/lead-review-enqueue/alerted-$id"
  [ -e "$mark" ] && return 10
  text="$slug#$n @$h12 carries a Lead-Lane: commit, so the lead lane will not verdict its own work. To ask anyway: bin/lead-verdict.sh request $slug $n $head --notes \"...\""
  if "$root/bin/lane-alert.sh" --severity warn --id "$id" lead-review "$text" >/dev/null 2>&1; then
    mkdir -p "${mark%/*}" 2>/dev/null; : > "$mark" 2>/dev/null || _lgt_log "alerted $id but could not write its marker; this may alert again"
    _lgt_log "[skip lead-lane] $slug#$n @$h12 carries a Lead-Lane: commit; not reviewed"
  else
    _lgt_log "lane-alert.sh failed for $id; next tick retries"
  fi
  return 10
}
