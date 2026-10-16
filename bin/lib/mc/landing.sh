#!/bin/bash
# shellcheck shell=bash
# bin/lib/mc/landing.sh — BH-6744 (wave 1 of #6541): the landing contract and
# its shadow decisions. Sourced by bin/merge-conductor.sh, never run. Not a
# `# module:` file: an optional lib, like external-enqueue.sh.
#
# Wave 1 DECIDES NOTHING. The conductor merges or enqueues exactly as before.
# With mode `queue` (the default) landing_shadow returns before any read. In
# `shadow` (and in `optimistic`, which wave 1 records the same way) it writes
# one LANDING line and one landing_decisions row per (PR, head, mode).
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
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    cw=$(jq -r --arg c "$c" '[.check_runs[] | select(.name == $c)] | sort_by(.started_at // "") | last
          | if . == null then "absent" else (.status + "/" + (.conclusion // "none")) end' "$t" 2>/dev/null)
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

landing_shadow() {
  local p="${1:-}" repo="${2:-}" pr="${3:-}" head="${4:-}" key="${5:-}" lbl="${6:-}" mode mark would body
  mode=$(landing_mode "$p")
  [ "$mode" = queue ] && return 0
  command -v mc_step >/dev/null 2>&1 && mc_step landing-shadow
  mark="landing $key $head $mode"
  if command -v mc_attempt_has >/dev/null 2>&1; then
    mc_attempt_has "$mark" && return 0
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
    _landing_log "$key LANDING_ROW_FAILED http=none"; return 0
  fi
  JOBS_HTTP=""
  JOBS_ALERT=0 _jobs_req POST /api/landing-decisions "$body" >/dev/null 2>&1 \
    || _landing_log "$key LANDING_ROW_FAILED http=${JOBS_HTTP:-none}"
  return 0
}
