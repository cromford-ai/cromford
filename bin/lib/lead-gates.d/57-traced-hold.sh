#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/57-traced-hold.sh — gate 10a of bin/lead-review-enqueue.sh,
# the traced hold (BH-5795, header `traced`), ported to the worklist: a head
# whose traced test shards have not run is held, one traced run is dispatched,
# and the hold is bounded. LEAD_REVIEW_TRACED_WAIT=0 turns it off; the job
# name, workflow and bound are LEAD_REVIEW_TRACED_JOB, _WORKFLOW and
# _MAX_WAIT_MIN (the enqueue lane's knobs, lgk_load).
#   The number is 57: after 55-snapshot.sh (the PR body) and BEFORE
#   60-risk.sh, the enqueue's order (`>>> traced hold` runs before `>>> risk
#   tier`). After 60, a low-tier head under enforce would get a risk-tier
#   MERGE sign-off with no test run on it (tests/lead-gates-traced-hold T10).
#   A DIRTY head while LEAD_REVIEW_REBASE_HOLD=1: rc 0 (85-rebase-hold.sh owns it).
#   A base that is the default branch (.base.repo.default_branch, else main): rc 0.
#   Otherwise the head's check runs (lr_ci_fetch, the dispatcher's one read a
#   head) decide: a completed, non-skipped run of the traced job = rc 0. None,
#   all skipped, one still queued or running, or unreadable runs = held.
# Held: the enqueue's marker state/lead-review-enqueue/traced-<slug_>-<n>-<h12>
# (first line = first-sight epoch) gets ONE `POST actions/workflows/<wf>/
# dispatches` (scope=impact) per head, with the enqueue's refusals: no head
# ref, a fork's head, or an unfinished pull_request run of the workflow on the
# head (that run is the test). Then one `[skip traced]` line, rc 11.
# Past the bound, or with a marker it cannot use: rc 0, and the note
# `tests did not run: <why> (...)` goes to
# state/lead-review-gates/traced-note-<slug_>-<n>-<h12>, written once;
# lg_field_traced_note prints it (job meta key traced_note). A PR body that
# cannot be read is rc 11. Sourced by bin/lib/lead-gates.sh, never run.

# shellcheck source=bin/lib/lead-gates-knobs.sh
command -v lgk_load >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lead-gates-knobs.sh" 2>/dev/null || true

declare -g _LGTR_PRUNED=""

# _lgtr_note_file <slug> <n> <head> — the per-head note path; rc 1 with no root.
_lgtr_note_file() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  printf '%s/state/lead-review-gates/traced-note-%s-%s-%s\n' "$root" \
    "$(printf '%s' "${1//\//_}" | tr -cd 'A-Za-z0-9._-')" "$2" "${3:0:12}"
}

# _lgtr_note <slug> <n> <head> <text> — write the note once.
_lgtr_note() {
  local f
  f=$(_lgtr_note_file "$1" "$2" "$3") || return 0
  [ -e "$f" ] && return 0
  mkdir -p "${f%/*}" 2>/dev/null
  printf '%s' "$4" > "$f" 2>/dev/null || _lgt_log "$1#$2 @${3:0:12}: traced note not written to $f; the job carries none"
}

lg_tick_traced_hold() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$_LGTR_PRUNED" ] && return 0
  _LGTR_PRUNED=1
  [ -n "$root" ] && [ -d "$root/state/lead-review-gates" ] \
    && find "$root/state/lead-review-gates" -maxdepth 1 -type f -name 'traced-note-*' -mtime +14 -delete 2>/dev/null
  return 0
}

# _lgtr_why <slug> <head> <base> <default> <checks-file> — rc 0 and LGTR_WHY
#   when the head must wait for a real test run; rc 1 = go. The enqueue's
#   traced_hold, from its check-run read on.
_lgtr_why() {
  local slug="$1" head="$2" where="$3" f="$4" counts total done run
  LGTR_WHY=""
  if command -v lr_ci_fetch >/dev/null 2>&1; then
    [ -s "$f" ] || LR_CI_SHA=""
    lr_ci_fetch "$slug" "$head" "$f" || { LGTR_WHY="$where and the check runs are unreadable ($LR_CI_WHY)"; return 0; }
  elif ! gh_rest GET "repos/$slug/commits/$head/check-runs?per_page=100&filter=latest" > "$f" 2>/dev/null; then
    LGTR_WHY="$where and the check runs are unreadable (HTTP ${GH_REST_STATUS:-000})"; return 0
  fi
  counts=$(jq -r --arg s "$head" --arg j "$LGK_TJOB" '
    if type != "object" or (.check_runs | type) != "array" or (.total_count // 0) > (.check_runs | length) then empty
    else [.check_runs[] | select(.head_sha == $s and ((.name // "") | startswith($j)))]
      | "\(length) \([.[] | select(.status == "completed" and .conclusion != "skipped")] | length) \([.[] | select(.status != "completed")] | length)" end' "$f" 2>/dev/null)
  read -r total done run <<<"$counts"
  if ! [[ "$total" =~ ^[0-9]+$ && "$done" =~ ^[0-9]+$ && "$run" =~ ^[0-9]+$ ]]; then
    LGTR_WHY="$where and the check runs are unreadable (malformed, or more than one page)"; return 0
  fi
  if [ "$run" -gt 0 ]; then
    LGTR_WHY="$where and $run '$LGK_TJOB' job(s) on this head are still queued or running; waiting for the result"; return 0
  fi
  [ "$done" -gt 0 ] && return 1
  if [ "$total" = 0 ]; then
    LGTR_WHY="$where and no '$LGK_TJOB' job ran on this head; waiting for a CI run that tests it"; return 0
  fi
  LGTR_WHY="$where and every '$LGK_TJOB' job on this head is skipped ($total); waiting for a CI run that tests it"; return 0
}

lg_gate_traced_hold() {
  local slug="$1" n="$2" head h12="${3:0:12}" root="${HARNESS:-${H:-}}" rc=0 bf d ms base dflt where safe tf t0 tref trepo tprn age
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  command -v lgk_load >/dev/null 2>&1 || return 0
  lgk_load
  [ "$LGK_TWAIT" = 1 ] || return 0
  command -v lgs_pr_body >/dev/null 2>&1 || { _lgt_log "$slug#$n @$h12: no PR body reader (55-snapshot.sh); traced hold"; return 11; }
  lgs_pr_body "$slug" "$n" || rc=$?
  bf="${LGS_BODY_FILE:-}"
  if [ "$rc" != 0 ] || [ ! -s "$bf" ]; then
    _lgt_log "$slug#$n @$h12: PR body unreadable (rc $rc) for the traced hold; held"; return 11
  fi
  ms=$(jq -r '.mergeable_state // empty' "$bf" 2>/dev/null)
  base=$(jq -r '.base.ref // empty' "$bf" 2>/dev/null)
  dflt=$(jq -r '.base.repo.default_branch // empty' "$bf" 2>/dev/null); dflt="${dflt:-main}"
  if [ "$ms" = dirty ] && [ "$LGK_RBHOLD" = 1 ]; then return 0
  elif [ "$ms" = dirty ]; then where="DIRTY against $base (GitHub runs no pull_request CI on a conflicting head)"
  elif [ -n "$base" ] && [ "$base" != "$dflt" ]; then where="base $base is not $dflt"
  else return 0; fi
  d=$(lgs_dir 2>/dev/null) || { _lgt_log "$slug#$n @$h12: no scratch dir for the traced hold; held"; return 11; }
  _lgtr_why "$slug" "$head" "$where" "$d/checks-$n" || return 0
  [ -n "$root" ] || { _lgt_log "$slug#$n @$h12: no harness root; traced hold"; return 11; }
  safe=$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')
  tf="$root/state/lead-review-enqueue/traced-$safe-$n-$h12"
  mkdir -p "${tf%/*}" 2>/dev/null
  [ -e "$tf" ] || date +%s > "$tf" 2>/dev/null
  t0=$(head -1 "$tf" 2>/dev/null)
  if ! [[ "$t0" =~ ^[0-9]+$ ]]; then
    _lgtr_note "$slug" "$n" "$head" "tests did not run: $LGTR_WHY (hold marker unusable)"
    _lgt_log "$slug#$n @$h12: hold marker $tf unusable; starting now: $LGTR_WHY"
    return 0
  fi
  if [ "$LGK_TMAX" -gt 0 ] && ! grep -q '^dispatch ' "$tf" 2>/dev/null; then
    tref=$(jq -r '.head.ref // empty' "$bf" 2>/dev/null)
    trepo=$(jq -r '.head.repo.full_name // empty' "$bf" 2>/dev/null)
    tprn=""
    if gh_rest GET "repos/$slug/actions/runs?head_sha=$head&event=pull_request&per_page=20" > "$d/runs-$n" 2>/dev/null; then
      tprn=$(jq -r --arg w "$LGK_TWF" '[.workflow_runs[]? | select((.path // "") | endswith($w)) | select((.status // "") != "completed")] | length' "$d/runs-$n" 2>/dev/null)
    fi
    if [ -z "$tref" ]; then echo "dispatch none: no head branch" >> "$tf"
    elif [ -n "$trepo" ] && [ "$trepo" != "$slug" ]; then echo "dispatch none: the head lives in $trepo" >> "$tf"
    elif [[ "$tprn" =~ ^[0-9]+$ ]] && [ "$tprn" -gt 0 ]; then
      echo "dispatch none: an unfinished pull_request run of $LGK_TWF is on this head" >> "$tf"
      _lgt_log "$slug#$n @$h12: not dispatched: a pull_request run of $LGK_TWF is still running on this head; waiting for its traced jobs"
    elif gh_rest POST "repos/$slug/actions/workflows/$LGK_TWF/dispatches" -f "ref=$tref" -f "inputs[scope]=impact" >/dev/null 2>&1; then
      echo "dispatch ok $LGK_TWF $tref" >> "$tf"
      _lgt_log "$slug#$n @$h12: dispatched $LGK_TWF scope=impact on $tref"
    else
      echo "dispatch failed http=${GH_REST_STATUS:-000}" >> "$tf"
      _lgt_log "$slug#$n @$h12: dispatch of $LGK_TWF scope=impact on $tref failed (HTTP ${GH_REST_STATUS:-000}); the ${LGK_TMAX}m bound still applies"
    fi
  fi
  age=$(( $(date +%s) - t0 ))
  if [ "$age" -lt $((LGK_TMAX * 60)) ]; then
    lgs_skip_once "$slug" "$n" "$head" traced "not requested: $LGTR_WHY (held ${age}s of ${LGK_TMAX}m)"
    return 11
  fi
  _lgtr_note "$slug" "$n" "$head" "tests did not run: $LGTR_WHY (held ${age}s, LEAD_REVIEW_TRACED_MAX_WAIT_MIN=$LGK_TMAX)"
  _lgt_log "$slug#$n @$h12: hold bound reached (${age}s >= ${LGK_TMAX}m); starting anyway: tests did not run"
  return 0
}

lg_field_traced_note() {
  local f
  f=$(_lgtr_note_file "$1" "$2" "$(printf '%s' "$3" | tr 'A-F' 'a-f')") || return 0
  [ -s "$f" ] && cat "$f"
  return 0
}
