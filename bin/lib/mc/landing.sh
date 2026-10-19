#!/bin/bash
# shellcheck shell=bash
# bin/lib/mc/landing.sh — BH-6744 (wave 1 of #6541): the landing contract and
# its shadow decisions. Sourced by bin/merge-conductor.sh, never run. Not a
# `# module:` file: an optional lib, like external-enqueue.sh.
#
# Modes `queue` and `shadow` DECIDE NOTHING. The conductor merges or enqueues
# exactly as before. With mode `queue` (the default) landing_shadow returns
# before any read. In `shadow` it writes one LANDING line and one
# landing_decisions row per (PR, head, mode).
# Mode `optimistic` (BH-6745, wave 2) CHANGES THE MERGE PATH on a Mergify repo:
# the READY arm calls landing_direct before the enqueue, and an eligible PR is
# merged directly (mc_merge, bound to the head) with no queue label.
#
# landing_mode <project>
#   queue | shadow | optimistic, always rc 0. Knob MC_LANDING_MODE through
#   lane_knob (per-project row, global row, env, registry default `queue`);
#   without lane_knob, ${MC_LANDING_MODE:-queue}. Trimmed and lowercased. Any
#   other value reads as queue, with one LANDING_MODE_BAD line per project per
#   UTC day.
# landing_pq_age_min <project>
#   Knob MC_LANDING_PQ_AGE_MIN, the same way. Not an integer, or under 1: 60.
# landing_eligible <repo> <pr> <head> [project] [labels-csv]
#   rc 0 and prints `ok` when every condition holds; else rc 1 and prints ONE
#   reason token. Sets LANDING_REASON. Cheapest check first; the first refusal
#   wins and no later read is made. An unreadable input is a refusal, never ok.
#     1 main-red     a main-red freeze flag for the project or slug
#                    (unreadable-freeze: no main_red_flag on this box)
#     2 solo         label queue-solo
#     3 fix-main-red label ${MC_MAIN_RED_LABEL:-fix-main-red}
#     4 prequeue-missing  no pre-queue verdict green|no-selection for this head
#     5 prequeue-stale    the newest such verdict was dispatched more than
#                         landing_pq_age_min minutes ago (the bound is ok)
#     6 tier-high | tier-unknown | unreadable-tier   the risk_tiers row for
#                    THIS head (GET /api/risk-tiers) must be low or medium
#     7 lead-verdict | unreadable-status   the lead-verdict commit status on
#                    the head must be success
#     8 fast-checks | unreadable-checks   every .mergify.yml admission check
#                    that is a check run (qsc_list's status contexts removed)
#                    is completed/success on the head, latest run per name
#     9 protected-path | unreadable-paths   no PR file (or a rename's old name)
#                    matches a lead-protected glob (la_globs, _la_files)
# landing_shadow <project> <repo> <pr> <head> <key> <labels-csv>
#   Always rc 0. Mode queue: returns at once. Else it marks the conductor
#   step `landing-shadow` (mc_step) and, once per (key, head, mode)
#   on the attempts ledger (`landing <key> <head> <mode>`, written BEFORE the
#   POST, so a dead worker costs one lost row, never a retry each tick): one
#   `<key> LANDING would=<direct|queue> reason=<token> mode=<mode> head=<sha12>`
#   line, then POST /api/landing-decisions. A failed POST is one
#   `<key> LANDING_ROW_FAILED http=<code>` line and is not retried.
# landing_direct_on <project> <provider>
#   rc 0 when the READY arm must try landing_direct: mode optimistic, provider
#   mergify, and not a lane-run machine (MC_ON_MACHINE=1). Else rc 1. No read.
# landing_direct_budget <project>
#   Knob MC_DIRECT_MERGE_BUDGET, the direct merges per project per tick. Not an
#   integer: 6. 0 = direct merging off (every PR enqueues as before).
# landing_direct <project> <repo> <pr> <head> <key> <labels-csv> <url>
#   BH-6745. Prints one outcome token (line 1) and returns:
#     rc 1 queue   do not merge directly; the caller enqueues as before. A
#                  lane-run machine; a `landingfail <key> <head>` from an earlier
#                  tick (one `<key> LANDING_DIRECT fallback=queue` line, no
#                  read); budget 0; the ${MC_MERGIFY_LABEL:-merge-queue} label;
#                  or landing_eligible refused.
#     rc 2 budget  eligible, but this tick's direct budget is spent.
#     rc 3 lock    mc_merge_locked answered 99; the direct unit goes back.
#     rc 0 merged  mc_merge returned 0; line 2 is the merge sha (may be empty).
#     rc 4 <code>  mc_merge refused: 405 | 409 | 422 | error (from its
#                  `HTTP refusal (rc 3|4|5)` prefix). `landingfail <key> <head>
#                  <code>` goes on the attempts ledger, so the next tick enqueues.
#   The decision is recorded first (the same line, row and mark as
#   landing_shadow, so a landing_shadow call after a fall-through adds nothing).
#   `landingdirect <key> <head>` is written under the merge lock, just before
#   the merge PUT. Every rc but 1 PUTs the token as the row's outcome
#   (PUT /api/landing-decisions/outcome) and logs one
#   `<key> LANDING_DIRECT outcome=<token> head=<sha12>` line.
#   The caller runs it in `$( )` and marks the step itself: mc_step can `exit`
#   (BH-6346, a 401), and in a subshell that exit would read as rc 0.
# landing_direct_path <key> <head>
#   rc 0 when `landingdirect <key> <head>` is on the attempts ledger and no
#   `landingfail <key> <head>` is: the head was landed directly. mc_settle_merged
#   writes the ledger merge detail `merge-conductor path=direct` on rc 0.
# landing_path_publish <slug> <merge-sha> <url> <key>
#   BH-6746. Mirrors that ledger mark onto GitHub, because a CI runner cannot
#   read the jobs ledger: the commit status `landing-path=success`, description
#   `path=direct`, on the merge sha (vs_publish with LEAD_VERDICT_CONTEXT
#   overridden). bin/ci-plan.sh (bin/lib/ci-push-direct.sh cpd_landed) reads it
#   and plans the push as push-direct. Always rc 0: a status that is not posted
#   costs one `<key> LANDING_PATH_OWED <why>` line, and CI runs the full corpus.
#
# LANDING_NOW (epoch seconds) is the clock seam for the tests.
# gh-rest: no-graphql

_landing_now() { if [ -n "${LANDING_NOW:-}" ]; then printf '%s' "$LANDING_NOW"; else printf '%(%s)T' -1; fi; }
_landing_log() { command -v mc_log >/dev/null 2>&1 && mc_log "$*"; return 0; }

# _landing_knob <ENV> <project> — the raw knob value.
_landing_knob() {
  if command -v lane_knob >/dev/null 2>&1; then lane_knob merge-conductor "$1" "${2:-}" 2>/dev/null
  else printf '%s' "${!1:-}"; fi
}

landing_mode() {
  local p="${1:-}" v day mark
  v=$(_landing_knob MC_LANDING_MODE "$p" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
  case "$v" in
    queue|shadow|optimistic) printf '%s\n' "$v"; return 0 ;;
    '') printf 'queue\n'; return 0 ;;
  esac
  day=$(TZ=UTC printf '%(%F)T' "$(_landing_now)")
  mark="${MC_STATE_DIR:-}/landing/badmode-${p:-global}-$day"
  if [ -n "${MC_STATE_DIR:-}" ] && mkdir -p "${mark%/*}" 2>/dev/null; then
    ( set -o noclobber; : > "$mark" ) 2>/dev/null \
      && _landing_log "LANDING_MODE_BAD ${p:-global}: MC_LANDING_MODE reads '$v', not queue|shadow|optimistic — read as queue"
  fi
  printf 'queue\n'
}

landing_pq_age_min() {
  local v
  v=$(_landing_knob MC_LANDING_PQ_AGE_MIN "${1:-}" | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) v=60 ;; esac
  [ "$v" -ge 1 ] 2>/dev/null || v=60
  printf '%s\n' "$((10#$v))"
}

_landing_refuse() { LANDING_REASON="$1"; printf '%s\n' "$1"; return 1; }

landing_eligible() {
  local repo="${1:-}" pr="${2:-}" head="${3:-}" p="${4:-}" lbl="${5:-}"
  local f best=0 line st at max now t rc tier names cw c files g hit=0
  LANDING_REASON=""
  head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  # 1 — the freeze, a file read.
  command -v main_red_flag >/dev/null 2>&1 || { _landing_refuse unreadable-freeze; return 1; }
  main_red_flag "$p" "$repo" >/dev/null 2>&1 && { _landing_refuse main-red; return 1; }
  # 2, 3 — the labels, csv-exact.
  case ",$lbl," in *,queue-solo,*) _landing_refuse solo; return 1 ;; esac
  case ",$lbl," in *",${MC_MAIN_RED_LABEL:-fix-main-red},"*) _landing_refuse fix-main-red; return 1 ;; esac
  # 4, 5 — the pre-queue verdict for this head against any main. A sidecar
  # (<key>.why/.fail/.timing/.tmp.*) is not a verdict.
  for f in "${MC_STATE_DIR:-/nonexistent}/prequeue/${repo//\//_}_${pr}_${head}_"*; do
    case "${f##*/}" in *.*) continue ;; esac
    [ -f "$f" ] || continue
    if command -v pq_cache_get >/dev/null 2>&1; then line=$(pq_cache_get "$f"); else line=$(head -n1 "$f" 2>/dev/null); fi
    read -r st at _ <<<"$line"
    case "$st" in green|no-selection) ;; *) continue ;; esac
    case "$at" in ''|*[!0-9]*) continue ;; esac
    [ "$at" -gt "$best" ] && best="$at"
  done
  [ "$best" -gt 0 ] || { _landing_refuse prequeue-missing; return 1; }
  max=$(landing_pq_age_min "$p"); now=$(_landing_now)
  [ $((now - best)) -le $((max * 60)) ] || { _landing_refuse prequeue-stale; return 1; }
  # 6 — the risk tier recorded for THIS head.
  command -v _jobs_req >/dev/null 2>&1 || { _landing_refuse unreadable-tier; return 1; }
  t=$(JOBS_ALERT=0 _jobs_req GET "/api/risk-tiers?repo=${repo//\//%2F}&pr=$pr&limit=50" 2>/dev/null) || { _landing_refuse unreadable-tier; return 1; }
  tier=$(jq -er --arg h "$head" '(.rows | if type == "array" then . else error("rows") end)
         | map(select(.head_sha == $h)) | if length == 0 then "" else .[0].tier end' <<<"$t" 2>/dev/null) \
    || { _landing_refuse unreadable-tier; return 1; }
  case "$tier" in
    low|medium) ;;
    '') _landing_refuse tier-unknown; return 1 ;;
    *) _landing_refuse tier-high; return 1 ;;
  esac
  command -v gh_rest >/dev/null 2>&1 || { _landing_refuse unreadable-status; return 1; }
  t=$(mktemp "${TMPDIR:-/tmp}/landing.XXXXXX") || { _landing_refuse unreadable-status; return 1; }
  # 7 — the lead-verdict status on the head: ONE combined-status read.
  rc=0; gh_rest GET "repos/$repo/commits/$head/status" > "$t" 2>/dev/null || rc=$?
  c=$(command -v vs_context >/dev/null 2>&1 && vs_context || echo "${LEAD_VERDICT_CONTEXT:-lead-verdict}")
  if [ "$rc" != 0 ] || ! cw=$(jq -er --arg c "$c" '(.statuses | if type == "array" then . else error("statuses") end)
         | map(select(.context == $c)) | if length == 0 then "absent" else .[0].state end' "$t" 2>/dev/null); then
    rm -f "$t"; _landing_refuse unreadable-status; return 1
  fi
  [ "$cw" = success ] || { rm -f "$t"; _landing_refuse lead-verdict; return 1; }
  # 8 — the fast checks: ONE check-runs read; a short page is unreadable.
  names=""; rc=0
  if command -v ae_mergify_admit_checks >/dev/null 2>&1; then names=$(ae_mergify_admit_checks "$repo" 2>/dev/null) || rc=$?; else rc=2; fi
  [ "$rc" = 0 ] && command -v qsc_list >/dev/null 2>&1 && names=$(grep -vxF -f <(qsc_list) <<<"$names")
  if [ "$rc" != 0 ] || [ -z "$(tr -d '[:space:]' <<<"$names")" ]; then rm -f "$t"; _landing_refuse unreadable-checks; return 1; fi
  rc=0; gh_rest GET "repos/$repo/commits/$head/check-runs?per_page=100" > "$t" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || ! jq -e '(.check_runs | type == "array") and ((.total_count // 0) <= (.check_runs | length))' "$t" >/dev/null 2>&1; then
    rm -f "$t"; _landing_refuse unreadable-checks; return 1
  fi
  # BH-7121: crs_word reads completed_at too. Absent lib -> empty -> fast-checks.
  # shellcheck source=bin/lib/mc/check-run-state.sh
  command -v crs_word >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/check-run-state.sh" 2>/dev/null
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    cw=$(crs_word "$t" "$c" 2>/dev/null)
    [ "$cw" = completed/success ] || { rm -f "$t"; _landing_refuse fast-checks; return 1; }
  done <<<"$names"
  rm -f "$t"
  # 9 — the lead-protected paths. No globs = not governed = passes.
  command -v la_globs >/dev/null 2>&1 && command -v _la_files >/dev/null 2>&1 && command -v _la_match >/dev/null 2>&1 \
    || { _landing_refuse unreadable-paths; return 1; }
  g=$(la_globs "$repo") || { _landing_refuse unreadable-paths; return 1; }
  if [ -n "$(tr -d '[:space:]' <<<"$g")" ]; then
    files=$(_la_files "$repo" "$pr") || { _landing_refuse unreadable-paths; return 1; }
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      while IFS= read -r c; do
        [ -n "$c" ] && _la_match "$f" "$c" && { hit=1; break 2; }
      done <<<"$g"
    done <<<"$files"
    [ "$hit" = 0 ] || { _landing_refuse protected-path; return 1; }
  fi
  LANDING_REASON=ok
  printf 'ok\n'
  return 0
}

# _landing_record <project> <repo> <pr> <head> <key> <labels-csv> <mode>
#   rc 2 when this (key, head, mode) is already on the attempts ledger (no read,
#   no line, no row). Else it writes the mark, asks landing_eligible, logs the
#   LANDING line and POSTs the row: rc 0 would=direct, rc 1 would=queue.
_landing_record() {
  local p="${1:-}" repo="${2:-}" pr="${3:-}" head="${4:-}" key="${5:-}" lbl="${6:-}" mode="${7:-}" mark would body
  mark="landing $key $head $mode"
  if command -v mc_attempt_has >/dev/null 2>&1; then
    mc_attempt_has "$mark" && return 2
    mc_attempt_put "$mark"
  fi
  LANDING_REASON=""
  landing_eligible "$repo" "$pr" "$head" "$p" "$lbl" >/dev/null 2>&1
  [ -n "$LANDING_REASON" ] || LANDING_REASON=unreadable
  would=queue; [ "$LANDING_REASON" = ok ] && would=direct
  _landing_log "$key LANDING would=$would reason=$LANDING_REASON mode=$mode head=${head:0:12}"
  body=$(jq -nc --arg r "$repo" --argjson n "$pr" --arg h "$head" --arg m "$mode" --arg w "$would" --arg x "$LANDING_REASON" \
    '{repo:$r, number:$n, head:$h, mode:$m, would:$w, reason:$x}' 2>/dev/null)
  if [ -z "$body" ] || ! command -v _jobs_req >/dev/null 2>&1; then
    _landing_log "$key LANDING_ROW_FAILED http=none"
  else
    JOBS_HTTP=""
    JOBS_ALERT=0 _jobs_req POST /api/landing-decisions "$body" >/dev/null 2>&1 \
      || _landing_log "$key LANDING_ROW_FAILED http=${JOBS_HTTP:-none}"
  fi
  [ "$would" = direct ]
}

landing_shadow() {
  local p="${1:-}" mode
  mode=$(landing_mode "$p")
  [ "$mode" = queue ] && return 0
  command -v mc_step >/dev/null 2>&1 && mc_step landing-shadow
  _landing_record "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "$mode"
  return 0
}

landing_direct_on() {
  [ "${MC_ON_MACHINE:-}" = 1 ] && return 1
  [ "${2:-}" = mergify ] || return 1
  [ "$(landing_mode "${1:-}")" = optimistic ]
}

landing_direct_budget() {
  local v
  v=$(_landing_knob MC_DIRECT_MERGE_BUDGET "${1:-}" | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) v=6 ;; esac
  printf '%s\n' "$((10#$v))"
}

# _landing_count <kind> <key> <head> — the attempts lines of that kind for the head.
_landing_count() {
  if command -v mc_attempt_count >/dev/null 2>&1; then mc_attempt_count "$1" "$2" "$3"
  else awk -v k="$1" -v key="$2" -v h="$3" '$1==k && $2==key && $3==h {c++} END {print c+0}' "${MC_ATTEMPTS:-/nonexistent}" 2>/dev/null || echo 0; fi
}

landing_direct_path() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  [ "$(_landing_count landingdirect "$1" "$2")" -gt 0 ] 2>/dev/null || return 1
  [ "$(_landing_count landingfail "$1" "$2")" = 0 ]
}

landing_path_publish() {
  local slug="${1:-}" msha="${2:-}" url="${3:-}" key="${4:-}" err
  if ! command -v vs_publish >/dev/null 2>&1; then
    _landing_log "$key LANDING_PATH_OWED no-writer (vs_publish is not loaded) — CI runs the full corpus on ${msha:0:8}"
    return 0
  fi
  if err=$(LEAD_VERDICT_CONTEXT=landing-path vs_publish "$slug" "$msha" success "path=direct" "$url" 2>&1 >/dev/null); then
    _landing_log "$key LANDING_PATH_PUBLISHED landing-path=success path=direct on ${msha:0:8}"
  else
    _landing_log "$key LANDING_PATH_OWED $(head -1 <<<"${err:-vs_publish failed}") — CI runs the full corpus on ${msha:0:8}"
  fi
  return 0
}

# _landing_outcome_put <repo> <pr> <head> <mode> <outcome> <key> — the row's
# outcome. A record: a failure is one LANDING_ROW_FAILED line, rc 0 always.
_landing_outcome_put() {
  local body
  body=$(jq -nc --arg r "$1" --argjson n "$2" --arg h "$3" --arg m "$4" --arg o "$5" \
    '{repo:$r, number:$n, head:$h, mode:$m, outcome:$o}' 2>/dev/null)
  if [ -z "$body" ] || ! command -v _jobs_req >/dev/null 2>&1; then
    _landing_log "$6 LANDING_ROW_FAILED http=none"; return 0
  fi
  JOBS_HTTP=""
  JOBS_ALERT=0 _jobs_req PUT /api/landing-decisions/outcome "$body" >/dev/null 2>&1 \
    || _landing_log "$6 LANDING_ROW_FAILED http=${JOBS_HTTP:-none}"
  return 0
}

# _landing_merge <key> <url> <head> — run under mc_merge_locked: the intent
# mark, then the merge PUT. The mark is written only once the lock is held, so
# a lock refusal leaves no `landingdirect` line behind.
_landing_merge() {
  if command -v mc_attempt_has >/dev/null 2>&1; then
    mc_attempt_has "landingdirect $1 $3" || mc_attempt_put "landingdirect $1 $3"
  fi
  mc_merge "$2" "$3"
}

landing_direct() {
  local p="${1:-}" repo="${2:-}" pr="${3:-}" head="${4:-}" key="${5:-}" lbl="${6:-}" url="${7:-}"
  local mode=optimistic budget out rc tok
  [ "${MC_ON_MACHINE:-}" = 1 ] && { printf 'queue\n'; return 1; }
  if [ "$(_landing_count landingfail "$key" "$head")" != 0 ]; then
    _landing_log "$key LANDING_DIRECT fallback=queue head=${head:0:12}"
    printf 'queue\n'; return 1
  fi
  budget=$(landing_direct_budget "$p")
  [ "$budget" -gt 0 ] || { printf 'queue\n'; return 1; }
  case ",$lbl," in *",${MC_MERGIFY_LABEL:-merge-queue},"*) printf 'queue\n'; return 1 ;; esac
  rc=0; _landing_record "$p" "$repo" "$pr" "$head" "$key" "$lbl" "$mode" || rc=$?
  if [ "$rc" = 2 ]; then
    rc=0; LANDING_REASON=""; landing_eligible "$repo" "$pr" "$head" "$p" "$lbl" >/dev/null 2>&1 || rc=1
  fi
  [ "$rc" = 0 ] || { printf 'queue\n'; return 1; }
  if ! mc_tick_budget_take "$p" direct "$budget"; then
    tok=budget; rc=2
  else
    rc=0; out=$(mc_merge_locked "$p" _landing_merge "$key" "$url" "$head") || rc=$?
    case "$rc" in
      0)  tok=merged ;;
      99) mc_tick_budget_give "$p" direct; tok=lock; rc=3 ;;
      *)  case "$out" in
            "HTTP refusal (rc 3)"*) tok=405 ;;
            "HTTP refusal (rc 4)"*) tok=409 ;;
            "HTTP refusal (rc 5)"*) tok=422 ;;
            *) tok=error ;;
          esac
          mc_attempt_put_n landingfail "$key" "$head" "$tok"; rc=4 ;;
    esac
  fi
  _landing_outcome_put "$repo" "$pr" "$head" "$mode" "$tok" "$key"
  _landing_log "$key LANDING_DIRECT outcome=$tok head=${head:0:12}"
  printf '%s\n' "$tok"
  [ "$rc" = 0 ] && printf '%s\n' "$out"
  return "$rc"
}
