#!/bin/bash
# gh-identity: raw-by-design — sourced by bin/merge-conductor.sh, which has ALREADY armed the identity that can see this project's repo; a second mint here would override that choice (same shape as lib/mc-stale-dequeue.sh).
# bin/lib/mc-stack-fast.sh — A STACKED CHILD OF A QUEUED PARENT JOINS THE
# PARENT'S BATCH (BH-5520). Sourced by bin/merge-conductor.sh, never executed.
#
# THE CASE. A split ticket files its children stacked on the parent's branch,
# and each child waits STACKED_WAIT until the parent MERGES. Split parents with
# two or more merged children took a median 25.2 h from first PR to last merge
# (unsplit: 2.7 h). Mergify batches 4 PRs over 3 min, so a child that is
# approved and green while its parent is already in the queue can ride in the
# parent's batch instead of waiting for the merge.
#
# THE RULE. msf_eligible says yes only when the parent row is QUEUED on its
# reviewed head, the parent's tip is in the child, the child is APPROVE on its
# own head, CI green and clean, and the repo merges with `merge_method=merge`
# (a squash parent would leave the child's copy of the parent commits behind).
# msf_retarget then PATCHes the child's base to the project base and writes a
# mark. The conductor resets its stack state, so the child classifies READY and
# is enqueued in the same tick, behind the parent.
#
# THE GUARD IS MERGIFY'S, NOT THE TICK'S (lead BLOCK on f6f879ef). If the
# parent leaves the queue unmerged (a REQUEST_CHANGES review makes Mergify
# dequeue it with no conductor action), the child would carry the parent's
# commits into main under the child's own approval. A conductor tick runs every
# 5 minutes, so a revoke alone leaves a window. msf_retarget therefore writes
# `Depends-On: #<parent>` into the child's body BEFORE the base PATCH: Mergify
# then holds the child at the merge step until the parent has merged, whatever
# the conductor does or when. The child still queues and is tested behind the
# parent; it can only merge after it. A body that cannot be read or written
# means no retarget.
#
# THE REVOKE. msf_check_revoke reads every marked child's parent each tick:
# merged drops the mark, still QUEUED keeps it, and anything else dequeues the
# child and PATCHes its base back onto the parent's branch, where it waits
# STACKED_WAIT as before. It is the cleanup, not the guard: with the
# Depends-On line the child cannot merge in the meantime.
#
# A CLOSED PARENT WHOSE BRANCH IS GONE (lead BLOCK on 95d38af8). The PATCH back
# onto a deleted branch fails on every tick, and the conductor's parent-closed
# arms never see the child, because its base is already the project base. So
# when the parent is closed unmerged and the PATCH back is refused, the revoke
# parks the child on the resolver-owned reason `orphaned-child` (MSF_ORPHAN;
# the conductor sets MC_STACK=parent-closed-orphan from it) and drops the mark.
# The child then holds the closed parent's commits on a BLOCKED_HUMAN row that
# bin/blocked-resolver.sh drains (fix round, then a fresh rebuild); it never
# reaches READY on the project base.
#
# THE DEPENDS-ON LINE COMES OFF AGAIN (lead BLOCK on 95d38af8). A line naming a
# parent that will never merge would hold the child in Mergify for ever. Every
# revoke, and a retarget whose base PATCH failed after it wrote the line, owes
# its removal: the owed parent sits in <mark>.depoff, msf_depends_settle tries
# the removal at once and again on every tick until it lands, and a new
# retarget of the same child cancels it.
#
# The mark: $MC_STATE_DIR/stack-fast/<slug with / -> __>#<num>, one line
#   <baseref>\t<parent-num>\t<parent-head>\t<epoch>
# written only after the retarget PATCH answered rc 0, and deleted only after
# the revoke's PATCH back answered rc 0 (or the parent merged, or the TTL).
#
# Kill knob: MC_STACK_FAST=0 (catalog/lanes.d/_lib.mc-stack-fast.json).

# Knobs: row > cached row > env > registry default, in a SUBSHELL like
# bin/lib/mc-ci-timeout.sh. The code literal after it is the documented
# fallback when there is no registry, and it also replaces a non-integer value.
_MSF_KV=$(
  exec 3>&1
  _MSF_R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_MSF_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_MSF_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_MSF_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'for _MSF_K in MC_STACK_FAST MC_STACK_FAST_MARK_TTL_S; do printf "%s\t%s\n" "$_MSF_K" "${!_MSF_K:-}" >&3; done' EXIT
  lib_env_apply mc-stack-fast >/dev/null 2>&1)
while IFS=$'\t' read -r _MSF_K _MSF_V; do
  if [ -n "$_MSF_K" ] && [ -n "$_MSF_V" ]; then printf -v "$_MSF_K" '%s' "$_MSF_V"; fi
done <<<"$_MSF_KV"
unset _MSF_KV _MSF_K _MSF_V
case "${MC_STACK_FAST:-}" in 0|1) ;; *) MC_STACK_FAST=1 ;; esac
case "${MC_STACK_FAST_MARK_TTL_S:-}" in ''|*[!0-9]*) MC_STACK_FAST_MARK_TTL_S=604800 ;; esac

MSF_WHY=""; MSF_BASE=""; MSF_PARENT_STATE=""; MSF_ORPHAN=""; MSF_DEP_WROTE=0

# msf_dir -> the mark directory; rc 1 (nothing printed) with no state root.
msf_dir() {
  [ -n "${MC_STATE_DIR:-}" ] || return 1
  printf '%s/stack-fast' "$MC_STATE_DIR"
}
# msf_mark <slug> <num> -> the mark path; rc 1 with no state root.
msf_mark() {
  local d; d=$(msf_dir) || return 1
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  printf '%s/%s#%s' "$d" "${1//\//__}" "$2"
}

# msf_merge_method <slug> <project> -> the merge_method= of the repo's mergify
# conf (config/mergify/repos/<project>.conf, else <repo name>.conf); empty for
# no conf, no root, or a conf that names another slug.
msf_merge_method() {
  local slug="${1:-}" proj="${2:-}" root c conf="" s
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] && [ -n "$slug" ] || return 0
  for c in ${proj:+"$root/config/mergify/repos/$proj.conf"} "$root/config/mergify/repos/${slug#*/}.conf"; do
    [ -r "$c" ] && { conf="$c"; break; }
  done
  [ -n "$conf" ] || return 0
  s=$(sed -n 's/^slug=//p' "$conf" 2>/dev/null | head -n 1)
  [ -z "$s" ] || [ "$s" = "$slug" ] || return 0
  sed -n 's/^merge_method=//p' "$conf" 2>/dev/null | head -n 1 | tr -d '[:space:]'
}

# msf_eligible <slug> <project> <parent-url> <child-head> <reviewed> <verdict>
#              <ci> <mstate> <baseref> <child-branch> <mgable> <key>
#   rc 0 only when every condition holds; rc 1 otherwise, and MSF_WHY names the
#   first one that failed. MSF_PARENT_STATE is the parent row's state ("" when
#   there is no row). The git read (mc_stack_parent_moved) runs last, so it is
#   spent only on a child that passed every cheap check.
msf_eligible() {
  local slug="${1:-}" proj="${2:-}" purl="${3:-}" head="${4:-}" reviewed="${5:-}" verdict="${6:-}"
  local ci="${7:-}" mstate="${8:-}" baseref="${9:-}" cbr="${10:-}" mgable="${11:-}" key="${12:-}"
  local pnum prow pst phead prev mm out rc
  MSF_WHY=""; MSF_PARENT_STATE=""
  if [ "${MC_STACK_FAST:-}" = 0 ]; then MSF_WHY="MC_STACK_FAST=0"; return 1; fi
  pnum=$(mc_num_of_url "$purl" 2>/dev/null)
  if [ -z "$pnum" ]; then MSF_WHY="no parent PR number"; return 1; fi
  prow=$(mc_row_get "$slug#$pnum")
  IFS=$'\t' read -r _ pst _ phead prev _ <<<"$prow"
  MSF_PARENT_STATE="${pst:-}"
  if [ "${pst:-}" != QUEUED ]; then MSF_WHY="parent #$pnum is ${pst:-unknown}, not QUEUED"; return 1; fi
  if [ -z "${phead:-}" ] || [ "$phead" != "${prev:-}" ]; then
    MSF_WHY="parent #$pnum head ${phead:0:8} is not its reviewed head ${prev:0:8}"; return 1
  fi
  mm=$(msf_merge_method "$slug" "$proj")
  if [ "$mm" != merge ]; then MSF_WHY="merge_method ${mm:-unset} (only merge keeps the parent's commits)"; return 1; fi
  if [ "$verdict" != APPROVE ] || [ -z "$head" ] || [ "$reviewed" != "$head" ]; then
    MSF_WHY="the child is not APPROVE on its head (verdict ${verdict:-none} on ${reviewed:0:8})"; return 1
  fi
  case "$ci" in green|SUCCESS) ;; *) MSF_WHY="the child CI is ${ci:-unknown}"; return 1 ;; esac
  if [ "$mstate" = DIRTY ] || [ "$mgable" = CONFLICTING ]; then MSF_WHY="the child is DIRTY"; return 1; fi
  if [ -n "$key" ] && mc_attempt_has "stackfast-revoke $key $head" 2>/dev/null; then
    MSF_WHY="this head was revoked once already"; return 1
  fi
  rc=0; out=$(mc_stack_parent_moved "$slug" "$proj" "$cbr" "$head" "$baseref") || rc=$?
  case "$rc" in
    1) ;;
    0) MSF_WHY="the parent tip ${out:0:8} is not in the child"; return 1 ;;
    *) MSF_WHY="the parent tip is unreadable (${out:-no answer})"; return 1 ;;
  esac
  if [ -n "$out" ] && [ "$out" != "$phead" ]; then
    MSF_WHY="the parent branch tip ${out:0:8} is not the queued head ${phead:0:8}"; return 1
  fi
  return 0
}

# msf_depends_on <slug> <num> <parent-num> — rc 0 when the child's body holds a
#   `Depends-On: #<parent-num>` line: it already did, or this call appended it
#   with one REST PATCH (the body travels through a file). rc 1 when the body
#   could not be read or the PATCH failed; nothing else is changed.
msf_depends_on() {
  local slug="${1:-}" num="${2:-}" pn="${3:-}" body f rc
  MSF_DEP_WROTE=0
  [ -n "$slug" ] && [ -n "$num" ] && [ -n "$pn" ] || return 1
  body=$(gh api "repos/$slug/pulls/$num" --jq '.body // ""' 2>/dev/null) || return 1
  grep -qiE "^Depends-On: *#${pn}[[:space:]]*\$" <<<"$body" && return 0
  f=$(mktemp "${TMPDIR:-/tmp}/msf-body.XXXXXX" 2>/dev/null) || return 1
  { [ -n "$body" ] && printf '%s\n\n' "$body"; printf 'Depends-On: #%s\n' "$pn"; } > "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  rc=0; gh api -X PATCH "repos/$slug/pulls/$num" -F "body=@$f" >/dev/null 2>&1 || rc=1
  rm -f "$f"
  [ "$rc" = 0 ] && MSF_DEP_WROTE=1
  return "$rc"
}

# msf_depends_off <slug> <num> <parent-num> — rc 0 when the child's body holds
#   no `Depends-On: #<parent-num>` line: it never did, or this call removed it
#   (and the blank lines it leaves at the end) with one REST PATCH. rc 1 when
#   the body could not be read or the PATCH failed.
msf_depends_off() {
  local slug="${1:-}" num="${2:-}" pn="${3:-}" body f rc
  [ -n "$slug" ] && [ -n "$num" ] && [ -n "$pn" ] || return 1
  body=$(gh api "repos/$slug/pulls/$num" --jq '.body // ""' 2>/dev/null) || return 1
  grep -qiE "^Depends-On: *#${pn}[[:space:]]*\$" <<<"$body" || return 0
  f=$(mktemp "${TMPDIR:-/tmp}/msf-body.XXXXXX" 2>/dev/null) || return 1
  awk -v pn="$pn" 'tolower($0) ~ ("^depends-on: *#" pn "[[:space:]]*$") { next }
    { line[++n] = $0 }
    END { while (n > 0 && line[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print line[i] }' <<<"$body" > "$f" 2>/dev/null \
    || { rm -f "$f"; return 1; }
  rc=0; gh api -X PATCH "repos/$slug/pulls/$num" -F "body=@$f" >/dev/null 2>&1 || rc=1
  rm -f "$f"
  return "$rc"
}

# msf_depends_owe <slug> <key> <num> <parent-num> — record that the child owes
#   the removal of its `Depends-On: #<parent-num>` line (<mark>.depoff, one
#   line `depoff\t<parent-num>\t-\t<epoch>`, so msf_sweep ages it out like a
#   mark), then try the removal once at once (msf_depends_settle).
msf_depends_owe() {
  local slug="${1:-}" key="${2:-}" num="${3:-}" pn="${4:-}" mark
  mark=$(msf_mark "$slug" "$num") || return 1
  [ -n "$pn" ] || return 1
  mkdir -p "${mark%/*}" 2>/dev/null || return 1
  printf 'depoff\t%s\t-\t%s\n' "$pn" "$(mc_now)" > "$mark.depoff" 2>/dev/null || return 1
  msf_depends_settle "$slug" "$key" "$num" 1
}

# msf_depends_settle <slug> <key> <num> <actions> — the conductor's per-tick
#   call: when the child owes a Depends-On removal, try it. rc 0 = nothing owed
#   or removed now; rc 1 = still owed (observe mode, or the read or PATCH
#   failed; retried next tick).
msf_depends_settle() {
  local slug="${1:-}" key="${2:-}" num="${3:-}" actions="${4:-0}" mark tag pn
  mark=$(msf_mark "$slug" "$num") || return 0
  [ -s "$mark.depoff" ] || return 0
  IFS=$'\t' read -r tag pn _ < "$mark.depoff"
  if [ "$tag" != depoff ] || ! [[ "$pn" =~ ^[0-9]+$ ]]; then
    rm -f "$mark.depoff"; mc_log "$key STACK_FAST owed Depends-On removal is unreadable — dropped"; return 0
  fi
  [ "$actions" = 1 ] || return 1
  if msf_depends_off "$slug" "$num" "$pn"; then
    rm -f "$mark.depoff"
    mc_log "$key STACK_FAST Depends-On: #$pn is off the body (the parent left the queue unmerged)"
    return 0
  fi
  mc_log "$key STACK_FAST Depends-On: #$pn could not be removed from the body — retried next tick"
  return 1
}

# msf_retarget <slug> <key> <num> <pbase> <baseref> <parent-num> <parent-head>
#   Write `Depends-On: #<parent-num>` into the child's body (msf_depends_on),
#   then PATCH the base to <pbase>; on rc 0 the mark appears and STACK_FAST is
#   logged. No Depends-On line, no base PATCH. The mark is staged BEFORE the
#   PATCH and moved into place after it, so a mark can never exist without its
#   retarget, and a retarget never goes out when the mark could not be written.
#   rc 1 = the base did not change.
msf_retarget() {
  local slug="${1:-}" key="${2:-}" num="${3:-}" pbase="${4:-}" baseref="${5:-}" pn="${6:-}" ph="${7:-}" mark tmp
  mark=$(msf_mark "$slug" "$num") || return 1
  [ -n "$pbase" ] && [ -n "$baseref" ] || return 1
  mkdir -p "${mark%/*}" 2>/dev/null || return 1
  tmp="$mark.tmp.$$"
  printf '%s\t%s\t%s\t%s\n' "$baseref" "$pn" "$ph" "$(mc_now)" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  # This retarget wants the line: an older owed removal must not take it off.
  rm -f "$mark.depoff"
  if ! msf_depends_on "$slug" "$num" "$pn"; then
    rm -f "$tmp"
    mc_log "$key STACK_FAST not taken: the Depends-On: #$pn line could not be written into the body — it stays STACKED_WAIT and is retried next tick"
    return 1
  fi
  if ! mc_retarget_base "$slug" "$num" "$pbase"; then
    rm -f "$tmp"
    mc_log "$key STACK_FAST retarget $baseref -> $pbase refused (PATCH failed) — it stays STACKED_WAIT and is retried next tick"
    # The line this call wrote must not outlive a retarget that did not happen.
    [ "$MSF_DEP_WROTE" = 1 ] && msf_depends_owe "$slug" "$key" "$num" "$pn"
    return 1
  fi
  mv -f "$tmp" "$mark" 2>/dev/null || { rm -f "$tmp"; mc_log "$key STACK_FAST retargeted to $pbase but the mark could not be written — no revoke is possible for this child"; return 0; }
  mc_log "STACK_FAST $key retargeted $baseref -> $pbase behind QUEUED parent #$pn (${ph:0:8}); it enqueues behind the parent"
  return 0
}

# msf_try <slug> <project> <key> <num> <parent-url> <head> <reviewed> <verdict>
#         <ci> <mstate> <mgable> <baseref> <child-branch> <pbase> <actions>
#   The conductor's one call from the OPEN* arm. rc 0 = retargeted: the caller
#   resets its stack state and sets BASEREF to <pbase>. rc 1 = nothing changed.
#   A refusal is logged only when the parent is QUEUED (the case it was meant
#   for); every other stacked child stays as quiet as before.
msf_try() {
  local slug="${1:-}" proj="${2:-}" key="${3:-}" num="${4:-}" purl="${5:-}" head="${6:-}" reviewed="${7:-}"
  local verdict="${8:-}" ci="${9:-}" mstate="${10:-}" mgable="${11:-}" baseref="${12:-}" cbr="${13:-}"
  local pbase="${14:-}" actions="${15:-0}" pn prow phead
  if ! msf_eligible "$slug" "$proj" "$purl" "$head" "$reviewed" "$verdict" "$ci" "$mstate" "$baseref" "$cbr" "$mgable" "$key"; then
    [ "$MSF_PARENT_STATE" = QUEUED ] && mc_log "$key STACK_FAST not taken: MSF_WHY=$MSF_WHY"
    return 1
  fi
  pn=$(mc_num_of_url "$purl")
  prow=$(mc_row_get "$slug#$pn"); IFS=$'\t' read -r _ _ _ phead _ <<<"$prow"
  if [ "$actions" != 1 ]; then
    mc_log "WOULD STACK_FAST $key: retarget $baseref -> $pbase behind QUEUED parent #$pn (${phead:0:8}) — observe mode, nothing written"
    return 1
  fi
  msf_retarget "$slug" "$key" "$num" "$pbase" "$baseref" "$pn" "$phead"
}

# msf_check_revoke <slug> <key> <num> <url> <head> <actions>
#   Runs only when the child has a mark. rc 0 = REVOKED this tick: MSF_BASE is
#   the restored base, and the caller sets BASEREF to it. rc 1 = no change to
#   the base (kept, dropped on a merge, unreadable, observe mode, or a PATCH
#   back that failed and keeps the mark for the next tick). rc 2 = the parent
#   is closed and the PATCH back was refused: MSF_ORPHAN is the orphan reason,
#   and the caller parks the row on it (MC_STACK=parent-closed-orphan).
#   Every revoke owes the removal of the child's Depends-On line.
msf_check_revoke() {
  local slug="${1:-}" key="${2:-}" num="${3:-}" url="${4:-}" head="${5:-}" actions="${6:-0}"
  local mark base pn ph _ep st rc pst why
  MSF_BASE=""; MSF_ORPHAN=""
  mark=$(msf_mark "$slug" "$num") || return 1
  [ -s "$mark" ] || return 1
  IFS=$'\t' read -r base pn ph _ep < "$mark"
  if [ -z "$base" ] || [ -z "$pn" ]; then
    mc_log "$key STACK_FAST mark is unreadable ($mark) — left for msf_sweep"
    return 1
  fi
  # The _var form, not $(…): it runs in this shell, so GH_REST_REASON and the
  # quota bookkeeping survive (gh-rest-no-subshell-lint). Its file loads with
  # gh-rest.sh; a box without it reads as unreadable below and keeps the mark.
  if ! command -v gh_rest_pr_state_var >/dev/null 2>&1; then
    # shellcheck source=bin/lib/gh-rest-var.sh
    [ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest-var.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-var.sh" 2>/dev/null
  fi
  rc=0; st=""; gh_rest_pr_state_var st "$slug" "$pn" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || [ -z "$st" ]; then
    mc_log "$key STACK_FAST parent #$pn state unreadable (rc $rc) — mark kept, nothing changed this tick"
    return 1
  fi
  pst=$(mc_row_field "$slug#$pn" 2 2>/dev/null)
  case "$st" in
    merged) rm -f "$mark"; mc_log "$key STACK_FAST parent #$pn merged — mark dropped"; return 1 ;;
    open)   [ "$pst" = QUEUED ] && return 1
            why="open, row ${pst:-none}" ;;
    *)      why="$st" ;;
  esac
  if [ "$actions" != 1 ]; then
    mc_log "$key WOULD revoke STACK_FAST: parent #$pn left the queue unmerged ($why) — observe mode, nothing written"
    return 1
  fi
  if ! mc_attempt_has "stackfast-revoke $key $head" 2>/dev/null; then
    mc_attempt_put "stackfast-revoke $key $head"
    gh api -X DELETE "repos/$slug/issues/$num/labels/$MC_MERGIFY_LABEL" >/dev/null 2>&1 || true
    # The tag marks the dequeue as the conductor's own (mc_cr_dequeue's rule):
    # mc_eject_culprit_mark must not read it as a human dequeue. The command
    # stays alone on the first line, where Mergify reads it.
    gh api -X POST "repos/$slug/issues/$num/comments" -f body="@mergifyio dequeue

$MC_CRDEQUEUE_TAG" >/dev/null 2>&1 \
      || mc_log "$key STACK_FAST revoke: the @mergifyio dequeue comment could not be posted — the label is off"
  fi
  if ! mc_retarget_base "$slug" "$num" "$base"; then
    if [ "$st" = closed ]; then
      # The parent is closed and its branch will not take the child back: the
      # child holds the closed parent's commits on the project base. Park it on
      # the resolver-owned orphan reason; never leave it to the READY path.
      MSF_ORPHAN="$base (parent https://github.com/$slug/pull/$pn closed without merging; this PR was fast-tracked onto the project base and the PATCH back onto $base was refused)"
      rm -f "$mark"
      msf_depends_owe "$slug" "$key" "$num" "$pn"
      mc_attempt_has "orphan $key $head" 2>/dev/null || { mc_attempt_put "orphan $key $head"
        mc_log "$key BLOCKED_AGENT orphaned-child: STACK_FAST parent #$pn closed without merging and the PATCH back onto $base was refused — this PR still carries the parent's commits on the project base; handed to bin/blocked-resolver.sh: ${url:-}"; }
      return 2
    fi
    mc_log "$key STACK_FAST revoke: the PATCH back onto $base was refused — mark kept, retried next tick (${url:-})"
    return 1
  fi
  rm -f "$mark"
  MSF_BASE="$base"
  msf_depends_owe "$slug" "$key" "$num" "$pn"
  mc_log "STACK_FAST_REVOKED $key parent #$pn left the queue unmerged ($why) — dequeued and moved back onto $base"
  return 0
}

# msf_sweep [<slug>] — drop marks older than MC_STACK_FAST_MARK_TTL_S (only the
#   slug's own marks when one is given). A mark whose epoch does not parse is
#   judged on its mtime.
msf_sweep() {
  local slug="${1:-}" d f ep now ttl="${MC_STACK_FAST_MARK_TTL_S:-}"
  [[ "$ttl" =~ ^[0-9]+$ ]] || return 0
  d=$(msf_dir) || return 0
  [ -d "$d" ] || return 0
  now=$(mc_now)
  for f in "$d"/${slug:+"${slug//\//__}#"}*; do
    [ -f "$f" ] || continue
    ep=$(awk -F'\t' 'NR==1 {print $4}' "$f" 2>/dev/null)
    [[ "$ep" =~ ^[0-9]+$ ]] || ep=$(mc_mtime "$f")
    [ $(( now - ep )) -ge "$ttl" ] && rm -f "$f"
  done
  return 0
}
