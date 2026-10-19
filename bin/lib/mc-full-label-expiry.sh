#!/bin/bash
# bin/lib/mc-full-label-expiry.sh — THE `full` LABEL RUNS ONE BATCH (BH-7290,
# BH-7033.4). Sourced by bin/merge-conductor.sh, never executed.
#
#   fle_tick <slug> <merges>   for each closed batch draft bres_drafts lists whose
#                              CI completed (a run on its head ended success or
#                              failure), take the `full` label off each OPEN member
#                              that still carries it, with one comment first.
#
# WHY. The `full` label makes a batch run the whole corpus (bin/ci-plan.sh). It is
# a human override for one batch, but a label left on a PR made every later batch
# with that PR full too. After one completed batch the label has done its job.
#
# WRITES only with <merges> = 1 (merge mode, like the enqueue label). Any other
# mode logs `FULL_LABEL_EXPIRY would-remove pr=<n> draft=<d>` and writes nothing.
# Order per member: the comment (once: the sub-mark `fle-c <slug>#<n> <draft>`),
# then the label DELETE. A DELETE that fails logs `remove-failed` and leaves the
# draft unmarked, so the next tick retries it with no second comment. The draft
# mark `fle <slug>#<draft> <sha12>` is written only when every member is done,
# and is checked before any read. A draft whose runs are only cancelled or
# skipped is marked with no change (`skip=no-completed-run`); a run still in
# progress, or no run yet, holds the mark back.
#
# RETURNS the read rc when bres_drafts or a runs read fails (75 = rate limited
# stays 75) and writes nothing after it; 0 otherwise.
#
# Knob (settings row; the code default is the fallback):
#   full_label_expiry.max_drafts  unmarked drafts read per tick (10)
[ -n "${_FLE_LOADED:-}" ] && return 0
_FLE_LOADED=1
command -v bres_drafts >/dev/null 2>&1 \
  || { [ -r "${BASH_SOURCE[0]%/*}/mc-batch-reset.sh" ] && . "${BASH_SOURCE[0]%/*}/mc-batch-reset.sh"; }

_fle_knob() { # _fle_knob <name> <default> — a positive integer
  local v=""
  command -v setting_get >/dev/null 2>&1 && v=$(setting_get "$1" 2>/dev/null)
  case "$v" in ''|*[!0-9]*|0) v="$2" ;; esac
  printf '%s' "$v"
}

fle_tick() {
  local slug="${1:-}" merges="${2:-0}" rc=0 tmp max done_n=0 draft sha members key runs st concl
  local n j state has url ckey all_ok would body
  [ -n "$slug" ] && command -v bres_drafts >/dev/null 2>&1 || return 0
  # Opted in the same way as bres_tick (BH-5372): only a repo whose mergify conf
  # carries a queue_mode= line reads its closed batch drafts. Without this the
  # tick read the closed list on every repo (queue-batch-reset §3 "not opted in").
  local root conf
  root="${HARNESS:-${H:-}}"
  conf="$root/config/mergify/repos/${slug#*/}.conf"
  [ -n "$root" ] && [ -r "$conf" ] && grep -qx "slug=$slug" "$conf" 2>/dev/null && grep -q '^queue_mode=' "$conf" || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fle-drafts.XXXXXX") || return 75
  bres_drafts "$slug" > "$tmp" || rc=$?
  [ "$rc" = 0 ] || { rm -f "$tmp"; return "$rc"; }
  max=$(_fle_knob full_label_expiry.max_drafts 10)
  while IFS=$'\t' read -r draft _ sha _ _ members; do
    [ -n "$draft" ] && [ -n "$sha" ] || continue
    key="fle $slug#$draft ${sha:0:12}"
    mc_attempt_has "$key" && continue
    if [ "$done_n" -ge "$max" ]; then mc_log "$slug FULL_LABEL_EXPIRY deferred draft=$draft — over full_label_expiry.max_drafts=$max this tick"; continue; fi
    done_n=$((done_n+1))
    rc=0; mc_rest_var runs gh_rest GET "repos/$slug/actions/runs" -f "head_sha=$sha" -F per_page=100 </dev/null || rc=$?
    [ "$rc" = 0 ] || { rm -f "$tmp"; return "$rc"; }
    st=$(jq -er 'if (.workflow_runs | type) != "array" then error("no runs")
        elif (.workflow_runs | length) == 0 then "none"
        elif any(.workflow_runs[]; .status != "completed") then "pending"
        elif any(.workflow_runs[]; .conclusion == "failure") then "failure"
        elif any(.workflow_runs[]; .conclusion == "success") then "success"
        else "no-completed-run" end' <<<"$runs" 2>/dev/null) || continue
    case "$st" in
      none|pending) continue ;;
      no-completed-run) mc_log "$slug FULL_LABEL_EXPIRY draft=$draft skip=no-completed-run"; mc_attempt_put "$key"; continue ;;
    esac
    concl=$st; all_ok=1; would=0
    for n in ${members//,/ }; do
      case "$n" in ''|*[!0-9]*) continue ;; esac
      rc=0; mc_rest_var j gh_rest GET "repos/$slug/issues/$n" </dev/null || rc=$?
      [ "$rc" = 0 ] || { mc_log "$slug FULL_LABEL_EXPIRY unread pr=$n draft=$draft rc=$rc"; all_ok=0; continue; }
      state=$(jq -r '.state // ""' <<<"$j" 2>/dev/null)
      has=$(jq -r 'if (.labels | type) == "array" then ([.labels[] | (.name // "") | gsub("^\\s+|\\s+$"; "")] | index("full") != null) else "unread" end' <<<"$j" 2>/dev/null)
      case "$has" in true|false) ;; *) mc_log "$slug FULL_LABEL_EXPIRY unread pr=$n draft=$draft rc=parse"; all_ok=0; continue ;; esac
      [ "$state" = open ] && [ "$has" = true ] || continue
      if [ "$merges" != 1 ]; then
        mc_log "$slug FULL_LABEL_EXPIRY would-remove pr=$n draft=$draft"
        would=1; continue
      fi
      url="https://github.com/$slug/pull/$n"
      ckey="fle-c $slug#$n $draft"
      if ! mc_attempt_has "$ckey"; then
        body="The \`full\` label ran one complete merge-queue batch (#$draft, CI $concl). I took it off, so the next batch runs this PR's impact set. Add \`full\` again to run the whole corpus once more."
        if mc_pr_comment "$url" "$body" </dev/null; then
          mc_attempt_put "$ckey"
          mc_log "$slug FULL_LABEL_EXPIRY commented pr=$n draft=$draft"
        else
          mc_log "$slug FULL_LABEL_EXPIRY comment-failed pr=$n draft=$draft"
          all_ok=0; continue
        fi
      fi
      if mc_label_remove "$url" full </dev/null; then
        mc_log "$slug FULL_LABEL_EXPIRY removed pr=$n draft=$draft"
      else
        mc_log "$slug FULL_LABEL_EXPIRY remove-failed pr=$n draft=$draft"
        all_ok=0
      fi
    done
    # A would-remove draft is not marked: merge mode turned on later still
    # takes the label off.
    [ "$all_ok" = 1 ] && [ "$would" = 0 ] && mc_attempt_put "$key"
  done < "$tmp"
  rm -f "$tmp"
  return 0
}
