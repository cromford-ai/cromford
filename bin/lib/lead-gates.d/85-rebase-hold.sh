#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/85-rebase-hold.sh — gate 10 of bin/lead-review-enqueue.sh,
# the rebase hold (BH-5796, header `rebase`), ported to the worklist: a head
# that conflicts with its base is not started. LEAD_REVIEW_REBASE_HOLD=0 (the
# enqueue lane's knob, lgk_load) turns it off. In order, any one holds:
#   1. the merge conductor's row (state/merge-conductor/pr-state.tsv) on THIS
#      head: NEEDS_REBASE, REBASING, or BLOCKED_HUMAN:conflict-unresolvable;
#   2. GitHub's mergeable_state "dirty" in the PR body (lgs_pr_body, 55-snapshot.sh);
#   3. `git merge-tree --write-tree` of origin/<base> and the head in the
#      repo's clone, on the objects it already has (no fetch): rc 1 = conflicts.
# A hold is one `[skip rebase]` line per head (lgs_skip_once), then rc 11.
# A PR body that cannot be read is rc 11. A merge-tree that cannot run, or a
# head or base the clone does not have, is rc 0, as in the enqueue.
# A clean head that dup_main_pr (bin/lib/dup-main.sh, BH-5802) flags is NOT
# held: `possible duplicate of <sha> (<path>)` goes to
# state/lead-review-gates/dup-<slug_>-<n>-<h12>, written once, and
# lg_field_dup_note prints it (job meta key dup_note). lg_tick_rebase_hold
# deletes those files after 14 days, once a process.
# Sourced by bin/lib/lead-gates.sh, never run.

# shellcheck source=bin/lib/lead-gates-knobs.sh
command -v lgk_load >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lead-gates-knobs.sh" 2>/dev/null || true
# shellcheck source=bin/lib/dup-main.sh
command -v dup_main_pr >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../dup-main.sh" 2>/dev/null || true

declare -g _LGRB_PRUNED=""

# _lgrb_dup_file <slug> <n> <head> — the per-head dup note path; rc 1 with no root.
_lgrb_dup_file() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  printf '%s/state/lead-review-gates/dup-%s-%s-%s\n' "$root" \
    "$(printf '%s' "${1//\//_}" | tr -cd 'A-Za-z0-9._-')" "$2" "${3:0:12}"
}

lg_tick_rebase_hold() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$_LGRB_PRUNED" ] && return 0
  _LGRB_PRUNED=1
  [ -n "$root" ] && [ -d "$root/state/lead-review-gates" ] \
    && find "$root/state/lead-review-gates" -maxdepth 1 -type f -name 'dup-*' -mtime +14 -delete 2>/dev/null
  return 0
}

lg_gate_rebase_hold() {
  local slug="$1" n="$2" head h12="${3:0:12}" root="${HARNESS:-${H:-}}" st rh rr why="" rc=0 bf base project repo out mrc dup f
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  if command -v lgk_load >/dev/null 2>&1; then lgk_load; [ "$LGK_RBHOLD" = 0 ] && return 0; fi
  if [ -n "$root" ]; then
    IFS=$'\t' read -r st rh rr < <(awk -F'\t' -v k="$slug#$n" '$1 == k {print $2 "\t" tolower($4) "\t" $7; exit}' \
      "$root/state/merge-conductor/pr-state.tsv" 2>/dev/null)
    if [ "${rh:-}" = "$head" ]; then
      case "$st:$rr" in
        NEEDS_REBASE:*|REBASING:*) why="NEEDS_REBASE: the conductor has this head $st (${rr:-no reason})" ;;
        BLOCKED_HUMAN:conflict-unresolvable*) why="NEEDS_REBASE: the conductor parked this head ${rr%%:*} for a fix round" ;;
      esac
    fi
  fi
  if [ -z "$why" ]; then
    command -v lgs_pr_body >/dev/null 2>&1 || { _lgt_log "$slug#$n @$h12: no PR body reader (55-snapshot.sh); rebase hold"; return 11; }
    lgs_pr_body "$slug" "$n" || rc=$?
    bf="${LGS_BODY_FILE:-}"
    if [ "$rc" != 0 ] || [ ! -s "$bf" ]; then
      _lgt_log "$slug#$n @$h12: PR body unreadable (rc $rc) for the rebase hold; held"; return 11
    fi
    base=$(jq -r '.base.ref // empty' "$bf" 2>/dev/null)
    if [ "$(jq -r '.mergeable_state // empty' "$bf" 2>/dev/null)" = dirty ]; then
      why="NEEDS_REBASE: GitHub lists this head DIRTY against ${base:-its base}"
    fi
  fi
  if [ -z "$why" ]; then
    [ -n "$base" ] && [ -n "$root" ] || return 0
    project=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-$root/fleet.conf}" 2>/dev/null)
    [ -n "$project" ] || return 0
    repo="${REPOS_ROOT:-/root/repos}/$project"
    [ -d "$repo/.git" ] || return 0
    git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null || return 0
    git -C "$repo" rev-parse -q --verify "origin/$base^{commit}" >/dev/null 2>&1 || return 0
    out=$(git -C "$repo" merge-tree --write-tree --name-only --no-messages "origin/$base" "$head" 2>/dev/null); mrc=$?
    if [ "$mrc" = 1 ]; then
      why="NEEDS_REBASE: conflicts with origin/$base in $(printf '%s\n' "$out" | sed 1d | grep . | head -5 | paste -sd' ' -)"
    else
      # BH-5802: never held (the conductor rebases only DIRTY or CONFLICTING
      # heads, so a CLEAN head held here would wait forever). The lead reads it.
      if command -v dup_main_pr >/dev/null 2>&1 && dup=$(dup_main_pr "$repo" "origin/$base" "$head") \
         && f=$(_lgrb_dup_file "$slug" "$n" "$head") && [ ! -e "$f" ]; then
        mkdir -p "${f%/*}" 2>/dev/null
        printf 'possible duplicate of %s (%s)' "${dup%% *}" "${dup#* }" > "$f" 2>/dev/null \
          && _lgt_log "$slug#$n @$h12: started with a note: possible duplicate of ${dup%% *} (${dup#* })"
      fi
      return 0
    fi
  fi
  lgs_skip_once "$slug" "$n" "$head" rebase "not requested: $why"
  return 11
}

lg_field_dup_note() {
  local f
  f=$(_lgrb_dup_file "$1" "$2" "$(printf '%s' "$3" | tr 'A-F' 'a-f')") || return 0
  [ -s "$f" ] && cat "$f"
  return 0
}
