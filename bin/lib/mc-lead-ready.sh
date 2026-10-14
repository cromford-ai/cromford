#!/bin/bash
# bin/lib/mc-lead-ready.sh — A STANDING LEAD MERGE ON THE LIVE HEAD IS AN
# APPROVAL BOUND TO THAT HEAD (BH-3778). Sourced by bin/merge-conductor.sh,
# never executed.
#
# THE CASE (2026-10-01). Ten cromford PRs carried a lead-lane
# MERGE-WITH-NOTES and a green `lead-verdict` status on their current head and
# none was in the merge queue. The conductor only reads a READY from the
# builder's own APPROVE (mc_verdict: jobs ledger, then the build record). A head
# the lead cleared but the builder's verdict does not cover sat in HEAD_MOVED,
# where the conductor buys another review, and never reached mc_enqueue_mergify.
#
# THE RULE. mc_lead_ready answers rc 0, "treat this tick as APPROVE on HEAD",
# only when every gate below passes, cheapest first:
#   1. MC_LEAD_READY is not 0 (the settings row; 0 is the pre-BH-3778 behavior);
#   2. the builder verdict is not BLOCK / CONTRADICTION and headbound is not
#      `blocked@<head>` — a lead MERGE never overrides a builder BLOCK here;
#   3. the builder verdict does not already cover the head (APPROVE on HEAD is
#      rc 1: nothing to do);
#   4. the repo is governed (la_scope rc 0: catalog/lead-protected-paths.tsv,
#      a file read, no network);
#   5. a lead/human MERGE or MERGE-WITH-NOTES stands on THIS head (vd_standing);
#   6. la_decide <slug> <pr> <head> conductor is rc 0 — no protected path and
#      the lane is the authority. rc 1 (a human verdict is required) and rc 2
#      (undecidable) are both "no rebind": the PR keeps today's path.
# Any unreadable answer is rc 1, never "go". Everything downstream is unchanged:
# the stacked-base park, the CI ladder, the block gate, the budget and
# mc_enqueue_mergify with its per-head ask ledger. One log line per (PR, head),
# deduped by the attempts line `leadready <key> <head>`.
#
# No root and no paths of its own: the two readers are sourced off this file's
# directory when the caller has not loaded them.

command -v vd_standing >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/verdicts.sh" ] && . "${BASH_SOURCE[0]%/*}/verdicts.sh"; }
command -v la_decide >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/lead-authority.sh" ] && . "${BASH_SOURCE[0]%/*}/lead-authority.sh"; }
command -v lead_carry >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/lead-carry.sh" ] && . "${BASH_SOURCE[0]%/*}/lead-carry.sh"; }

# mc_lead_ready <key> <owner/repo> <num> <head> <verdict> <reviewed> <headbound>
#   rc 0 -> a standing lead/human MERGE on <head> the lane may clear: the caller
#           sets VERDICT=APPROVE and REVIEWED=<head> for this tick.
#   rc 1 -> no rebind (every other answer, unreadable included).
mc_lead_ready() {
  local key="$1" slug="$2" num="$3" head="$4" v="${5:-}" rev="${6:-}" hb="${7:-}" line word src vrc
  [ "${MC_LEAD_READY:-1}" != 0 ] || return 1
  [ -n "$head" ] || return 1
  case "$v" in BLOCK|CONTRADICTION) return 1 ;; esac
  [ "$hb" = "blocked@$head" ] && return 1
  [ "$v" = APPROVE ] && [ "$rev" = "$head" ] && return 1
  command -v la_scope >/dev/null 2>&1 && command -v la_decide >/dev/null 2>&1 \
    && command -v vd_standing >/dev/null 2>&1 || return 1
  la_scope "$slug" || return 1
  line=$(vd_standing "$slug" "$num" "$head" 2>/dev/null); vrc=$?
  # Nothing stands on this head: a lead word on an older head with the same
  # patch is carried here first (bin/lib/lead-carry.sh, BH-6291).
  if [ "$vrc" = 1 ] && command -v lead_carry >/dev/null 2>&1 && lead_carry "$key" "$slug" "$num" "$head"; then
    line=$(vd_standing "$slug" "$num" "$head" 2>/dev/null) || return 1
  elif [ "$vrc" != 0 ]; then
    return 1
  fi
  word=$(cut -f1 <<<"$line"); src=$(cut -f2 <<<"$line")
  case "$word" in MERGE|MERGE-WITH-NOTES) ;; *) return 1 ;; esac
  la_decide "$slug" "$num" "$head" conductor || return 1
  if ! mc_attempt_has "leadready $key $head" 2>/dev/null; then
    mc_attempt_put "leadready $key $head"
    mc_log "$key LEAD_READY on ${head:0:8}: a $src $word stands on this head and the lane may clear it (${LA_REASON:-}) — treated as an approval bound to this head (builder verdict ${v:--} on ${rev:--})"
  fi
  return 0
}
