#!/bin/bash
# gh-identity: raw-pat (BH-2006) — its three rate_limit reads MEASURE whichever identity is active, so arming it changes what the budget reports. That is a decision for the slice that converts it. The parent #425 closed without making it, so BH-2006 owns it now.
# bin/lib/gh-budget.sh — one shared GitHub API rate-limit budget per token.
#
# Consumers ask this library whether non-essential GitHub reads should skip
# this tick, and whether a failed list is really a rate-limit exhaustion.
#
#   gh_budget_refresh                -> ensure a fresh-or-cached rate_limit
#                                       read is available; rc 0 on success,
#                                       1 on API failure
#   gh_budget_threshold              -> print the numeric threshold
#   gh_budget_low <lane>             -> rc 0 low, 1 healthy, 2 unknown
#   gh_budget_exhausted              -> rc 0 only when a fresh read says a
#                                       bucket remaining == 0; otherwise non-zero
#   gh_budget_ratelimit_alert <lane> <what> -> one ALERTS.log line + fleet_alert
#                                       beat per exhausted bucket, deduped by
#                                       reset epoch.
#
# Threshold resolves: setting_get gh_budget_min_remaining -> GH_BUDGET_MIN_REMAINING -> 800.
# Cache lives at state/gh-budget/<token-fingerprint>.json, TTL GH_BUDGET_TTL_S
# (registry default 60; lib gh-budget, catalog/lanes.d/_lib.gh-budget.json).
# Token values never reach a filename, a log, or the cache.
set -uo pipefail

# BH-1939: GH_BUDGET_TTL_S and GH_BUDGET_DB_TIMEOUT_S have no literal in this
# file. They resolve through lib_env_apply gh-budget
# (catalog/lanes.d/_lib.gh-budget.json): row > cached row > env > registry
# default > fail closed. It runs in a SUBSHELL, so bin/lib/lane-gate.sh never
# replaces a function the caller defined and its fail-closed `exit 75` never
# stops the lane that sourced this; the EXIT trap hands back (on fd 3, which
# the redirect of lib_env_apply's own output does not touch) every knob that
# did resolve. The registry is $HARNESS's, else this checkout's own (a fixture
# HARNESS has none). A resolved 0 is assigned; an empty answer leaves the
# variable as it was, and each read below takes the branch that does less.
_GHB_KV=$(
  exec 3>&1
  _GHB_R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_GHB_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_GHB_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_GHB_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'for _GHB_K in GH_BUDGET_TTL_S GH_BUDGET_DB_TIMEOUT_S GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S; do printf "%s\t%s\n" "$_GHB_K" "${!_GHB_K:-}" >&3; done' EXIT
  lib_env_apply gh-budget >/dev/null 2>&1)
while IFS=$'\t' read -r _GHB_K _GHB_V; do
  if [ -n "$_GHB_V" ]; then printf -v "$_GHB_K" '%s' "$_GHB_V"; fi
done <<<"$_GHB_KV"
unset _GHB_KV _GHB_K _GHB_V
_GHB_H="${HARNESS:-/root/harness}"
# Not a number = no cache is trusted (the FAIL-OPEN read below), and the shared
# row is off.
_GHB_TTL="${GH_BUDGET_TTL_S:-}"
_GHB_DIR="$_GHB_H/state/gh-budget"
_GHB_LOG_DIR="$_GHB_H/logs"
_GHB_FLAG_DIR="$_GHB_H/flags"
_GHB_DEFAULT_THRESHOLD=800

_ghb_now() { date -u +%s; }

# _ghb_rl_read — BH-8334: one `gh api rate_limit` body into _GHB_RL_OUT, rc 0;
# rc 1 and _GHB_RL_OUT empty when the read failed or has no .resources. One
# process reuses its last good body for GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S
# seconds (knob catalog/lanes.d/_lib.gh-budget.knobs.d/; 0 = every call reads).
# gh_repo_list_failed calls gh_budget_exhausted and then
# gh_budget_ratelimit_alert on every failed repo list, so on a drained bucket
# one conductor made two rate_limit calls per failed list. A failed read is
# never kept. Shell variables, not a file (the memo is per process): it sets
# them in the caller's shell, so never call it inside $( ).
# An optional <cap> lowers the interval for one call: gh_budget_refresh passes
# GH_BUDGET_TTL_S (0 when it is not a number: no cache is trusted), so TTL 0
# ("no cache: every refresh reads") still reads.
_GHB_RL_RAW=""; _GHB_RL_AT=""; _GHB_RL_OUT=""
_ghb_rl_read() {
  local iv="${GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S:-}" cap="${1:-}" now raw
  # Fallback only: the knob is GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S.
  _ghb_num "$iv" || iv=60
  if _ghb_num "$cap" && [ "$cap" -lt "$iv" ]; then iv="$cap"; fi
  now=$(_ghb_now)
  _GHB_RL_OUT=""
  if [ "$iv" -gt 0 ] && [ -n "$_GHB_RL_RAW" ] && _ghb_num "$_GHB_RL_AT" && _ghb_num "$now" \
     && [ $((now - _GHB_RL_AT)) -lt "$iv" ] && [ "$now" -ge "$_GHB_RL_AT" ]; then
    _GHB_RL_OUT="$_GHB_RL_RAW"
    return 0
  fi
  raw=$(gh api rate_limit 2>/dev/null) || raw=""
  if [ -z "$raw" ] || ! printf '%s' "$raw" | jq -e '.resources' >/dev/null 2>&1; then
    return 1
  fi
  _GHB_RL_RAW="$raw"; _GHB_RL_AT="$now"; _GHB_RL_OUT="$raw"
  return 0
}
_ghb_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# _ghb_token — print the active token in a safe way. Never logged.
_ghb_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"
  else
    gh auth token 2>/dev/null || true
  fi
}

# _ghb_fingerprint — 12 hex chars of the token sha256. Never the token itself.
_ghb_fingerprint() {
  local tok
  tok=$(_ghb_token)
  if [ -n "$tok" ]; then
    printf '%s' "$tok" | sha256sum | awk '{print $1}' | cut -c1-12
  else
    printf 'notoken\n'
  fi
}

_ghb_cache_path() { printf '%s/%s.json\n' "$_GHB_DIR" "$(_ghb_fingerprint)"; }

# ── ONE BUDGET PER TOKEN, NOT PER BOX (BH-1043, audit §2.4) ──────────────────
# The cache above is per box; the bucket it describes belongs to the TOKEN, and
# the fleet shares one App/PAT identity. Nine boxes each read "4,800 remaining"
# and each decided it had 4,800 to spend, so the threshold that exists to stop
# non-essential reads before exhaustion was effectively multiplied by the number
# of boxes — and each box burned one rate_limit call per TTL to learn the same
# number.
#
# So the reading is a ROW in the jobs worker, keyed on the token fingerprint.
# A refresh asks the row first: a row younger than the TTL IS the answer and no
# `gh api rate_limit` call is made at all. Only a box that finds nothing fresh
# reads the API, and it publishes what it read. That makes the fleet spend one
# rate_limit call per TTL instead of one per box per TTL, and makes "remaining"
# a single countdown every lane reads the same way.
#
# FAIL-OPEN EVERYWHERE. An unreachable worker, a missing client, jq absent, a
# malformed row: every one of them falls through to the local read this file has
# always done. GH_BUDGET_DB=0 turns the shared half off.
#
# The fingerprint is 12 hex of the token's sha256 and is the only thing that
# crosses the wire — the token itself never reaches a row, a log or a URL.
if ! command -v gh_budget_row_get >/dev/null 2>&1; then
  _GHB_BIN=$( cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd )
  # shellcheck source=bin/jobs-client.sh
  [ -r "$_GHB_BIN/jobs-client.sh" ] && . "$_GHB_BIN/jobs-client.sh"
  unset _GHB_BIN
fi

_ghb_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }

_ghb_db_off() {
  [ "${GH_BUDGET_DB:-1}" = 0 ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  return 1
}

# _ghb_shared_pull <cache-path> <threshold> — write the fleet's reading into the
# local cache and rc 0, or rc 1 and touch nothing. A row older than the TTL is
# NOT an answer: handing a stale figure out as current is worse than no figure,
# because the caller skips its own read to take it.
_ghb_shared_pull() {
  local cache="$1" threshold="$2" fp row
  # Same reason as bin/lib/pool-account.sh: bash's dynamic scoping makes these
  # visible inside _jobs_req, so an unreachable worker delays a cron lane by a
  # few seconds rather than by the client's default timeout plus a retry. The
  # local `rate_limit` read below is the answer either way.
  local JOBS_RETRIES=0 JOBS_TIMEOUT="${GH_BUDGET_DB_TIMEOUT_S:-}"
  _ghb_db_off && return 1
  _ghb_num "$_GHB_TTL" && _ghb_num "$JOBS_TIMEOUT" || return 1
  command -v gh_budget_row_get >/dev/null 2>&1 || return 1
  fp=$(_ghb_fingerprint); [ -n "$fp" ] && [ "$fp" != notoken ] || return 1
  row=$(gh_budget_row_get "$fp" "$_GHB_TTL" 2>/dev/null) || return 1
  printf '%s' "$row" | jq -e '.core.remaining' >/dev/null 2>&1 || return 1
  printf '%s' "$row" | jq --argjson t "$threshold" \
    '{fetched_at: .fetched_at, _threshold: $t, core: .core, graphql: .graphql, _shared: true}' \
    > "$cache.tmp" 2>/dev/null || { rm -f "$cache.tmp"; return 1; }
  [ -s "$cache.tmp" ] || { rm -f "$cache.tmp"; return 1; }
  mv -f "$cache.tmp" "$cache" 2>/dev/null || { rm -f "$cache.tmp"; return 1; }
  return 0
}

# _ghb_shared_push <cache-json> — publish what this box just read, so the next
# box on this token does not pay for the same call. Never fails the caller.
_ghb_shared_push() {
  local fp body
  local JOBS_RETRIES=0 JOBS_TIMEOUT="${GH_BUDGET_DB_TIMEOUT_S:-}"
  _ghb_db_off && return 0
  _ghb_num "$_GHB_TTL" && _ghb_num "$JOBS_TIMEOUT" || return 0
  command -v gh_budget_row_put >/dev/null 2>&1 || return 0
  fp=$(_ghb_fingerprint); [ -n "$fp" ] && [ "$fp" != notoken ] || return 0
  body=$(printf '%s' "$1" | jq -c --arg f "$fp" --arg b "${JOBS_BOX:-}" \
    '{fingerprint:$f, box:$b, fetched_at:.fetched_at, core:.core, graphql:.graphql}' 2>/dev/null) || return 0
  [ -n "$body" ] || return 0
  gh_budget_row_put "$body" >/dev/null 2>&1 || true
  return 0
}

_ghb_warn_cache_once() {
  [ -n "${_GHB_CACHE_WARNED:-}" ] && return 0
  _GHB_CACHE_WARNED=1
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [gh-budget] warning: cache directory $_GHB_DIR is not writable" >> "$_GHB_LOG_DIR/gh-budget.log"
}

# _ghb_cache_valid <path> — rc 0 when the cache exists and is within TTL.
_ghb_cache_valid() {
  local f="$1" now age
  [ -f "$f" ] || return 1
  _ghb_num "$_GHB_TTL" || return 1
  now=$(_ghb_now)
  age=$(( now - $(jq -r '.fetched_at // 0' "$f" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$_GHB_TTL" ]
}

# _ghb_resolve_threshold — print the threshold. Non-numeric setting values fall
# through with a log line.
_ghb_resolve_threshold() {
  local val
  if command -v setting_get >/dev/null 2>&1; then
    val=$(setting_get gh_budget_min_remaining 2>/dev/null) || true
    case "${val:-}" in
      ''|*[!0-9]*)
        [ -n "$val" ] && echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [gh-budget] unusable setting gh_budget_min_remaining='$val' — falling back" >> "$_GHB_LOG_DIR/gh-budget.log"
        ;;
      *) printf '%s\n' "$val"; return 0 ;;
    esac
  fi
  case "${GH_BUDGET_MIN_REMAINING:-}" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$GH_BUDGET_MIN_REMAINING"; return 0 ;;
  esac
  printf '%s\n' "$_GHB_DEFAULT_THRESHOLD"
}

# gh_budget_refresh — ensure the cache holds a valid rate_limit read.
# Returns 0 and populates the cache on success, 1 on API failure.
gh_budget_refresh() {
  local cache threshold now raw fetched rc
  cache=$(_ghb_cache_path)
  mkdir -p "$_GHB_DIR" "$_GHB_LOG_DIR" 2>/dev/null || _ghb_warn_cache_once
  if _ghb_cache_valid "$cache"; then
    # If the cache lacks a threshold (older format), add one without re-fetching.
    if ! jq -e '._threshold' "$cache" >/dev/null 2>&1; then
      threshold=$(_ghb_resolve_threshold)
      jq --argjson t "$threshold" '. + {_threshold:$t}' "$cache" > "$cache.tmp" && mv -f "$cache.tmp" "$cache"
    fi
    return 0
  fi
  threshold=$(_ghb_resolve_threshold)
  # The fleet's reading before our own: one rate_limit call per TTL for the
  # whole fleet, and every box judging the same remaining figure.
  _ghb_shared_pull "$cache" "$threshold" && return 0
  if _ghb_num "$_GHB_TTL"; then _ghb_rl_read "$_GHB_TTL" || true; else _ghb_rl_read 0 || true; fi
  raw="$_GHB_RL_OUT"
  if [ -z "$raw" ]; then
    [ -f "$cache" ] || { : > "$cache"; }
    return 1
  fi
  # The reading's own time: a memo hit is up to the interval old.
  now="$_GHB_RL_AT"
  _ghb_num "$now" || now=$(_ghb_now)
  fetched=$(printf '%s' "$raw" | jq -nc --argjson n "$now" --argjson t "$threshold" 'input | {
    fetched_at: $n,
    _threshold: $t,
    core: {remaining: .resources.core.remaining, limit: .resources.core.limit, reset: .resources.core.reset},
    graphql: {remaining: .resources.graphql.remaining, limit: .resources.graphql.limit, reset: .resources.graphql.reset}
  }')
  if [ -z "$fetched" ]; then return 1; fi
  printf '%s\n' "$fetched" > "$cache.tmp" && mv -f "$cache.tmp" "$cache"
  _ghb_shared_push "$fetched"
  return 0
}

# gh_budget_threshold — print the current threshold.
gh_budget_threshold() {
  local cache
  cache=$(_ghb_cache_path)
  if _ghb_cache_valid "$cache" && jq -e '._threshold' "$cache" >/dev/null 2>&1; then
    jq -r '._threshold' "$cache"
    return 0
  fi
  _ghb_resolve_threshold
}

# _ghb_field <bucket> <field> — read one numeric field from the cache.
_ghb_field() {
  local cache="$1" bucket="$2" field="$3"
  jq -r ".${bucket}.${field} // empty" "$cache" 2>/dev/null || true
}

# gh_budget_low <lane> — rc 0 low, 1 healthy, 2 unknown.
# Writes exactly one log line per (lane, fetched_at).
gh_budget_low() {
  local lane="${1:-unknown}"
  local cache threshold core_rem graph_rem fetched_at marker logline
  cache=$(_ghb_cache_path)
  if ! gh_budget_refresh; then
    logline="[$lane] GitHub API rate-limit unknown — proceeding as healthy"
    marker="$_GHB_DIR/logged-${lane}-unknown-$(date -u +%Y%m%d%H%M)"
    if [ ! -f "$marker" ]; then
      mkdir -p "$_GHB_DIR" 2>/dev/null || true
      : > "$marker"
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $logline" >> "$_GHB_LOG_DIR/$lane.log"
    fi
    return 2
  fi
  threshold=$(gh_budget_threshold)
  case "$threshold" in ''|*[!0-9]*) threshold="$_GHB_DEFAULT_THRESHOLD" ;; esac
  core_rem=$(_ghb_field "$cache" core remaining)
  graph_rem=$(_ghb_field "$cache" graphql remaining)
  fetched_at=$(jq -r '.fetched_at // 0' "$cache" 2>/dev/null || echo 0)
  if [ "${core_rem:-0}" -lt "$threshold" ] || [ "${graph_rem:-0}" -lt "$threshold" ]; then
    marker="$_GHB_DIR/logged-${lane}-${fetched_at}"
    if [ ! -f "$marker" ]; then
      mkdir -p "$_GHB_DIR" 2>/dev/null || true
      : > "$marker"
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$lane] GitHub API budget low: core ${core_rem:-?}/$(_ghb_field "$cache" core limit), graphql ${graph_rem:-?}/$(_ghb_field "$cache" graphql limit) (threshold $threshold) — non-essential reads skipped this tick" >> "$_GHB_LOG_DIR/$lane.log"
    fi
    return 0
  fi
  return 1
}

# _ghb_iso <epoch> — UTC ISO-8601 timestamp.
_ghb_iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# gh_budget_exhausted — rc 0 only when a FRESH read says core or graphql
# remaining == 0 (fresh: this process read it at most
# GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S ago, _ghb_rl_read). Non-zero otherwise,
# including on read failure. The box cache file is never read here.
gh_budget_exhausted() {
  local raw core_rem graph_rem
  _ghb_rl_read || return 1
  raw="$_GHB_RL_OUT"
  core_rem=$(printf '%s' "$raw" | jq -r '.resources.core.remaining // empty')
  graph_rem=$(printf '%s' "$raw" | jq -r '.resources.graphql.remaining // empty')
  [ "$core_rem" = "0" ] || [ "$graph_rem" = "0" ]
}

# gh_budget_ratelimit_alert <lane> <what> — alert for the exhausted bucket(s).
# Deduped by reset epoch per bucket; wording avoids HTTP 429 / rate_limit_error.
gh_budget_ratelimit_alert() {
  local lane="$1" what="$2" raw core_rem core_lim core_reset graph_rem graph_lim graph_reset
  _ghb_rl_read || return 1
  raw="$_GHB_RL_OUT"
  mkdir -p "$_GHB_LOG_DIR" "$_GHB_FLAG_DIR" 2>/dev/null || true
  core_rem=$(printf '%s' "$raw" | jq -r '.resources.core.remaining // empty')
  core_lim=$(printf '%s' "$raw" | jq -r '.resources.core.limit // empty')
  core_reset=$(printf '%s' "$raw" | jq -r '.resources.core.reset // 0')
  graph_rem=$(printf '%s' "$raw" | jq -r '.resources.graphql.remaining // empty')
  graph_lim=$(printf '%s' "$raw" | jq -r '.resources.graphql.limit // empty')
  graph_reset=$(printf '%s' "$raw" | jq -r '.resources.graphql.reset // 0')
  now=$(_ghb_now)
  _ghb_alert_bucket() {
    local bucket="$1" remaining="$2" limit="$3" reset="$4"
    local flag line mins iso akey
    [ "$remaining" = "0" ] || return 0
    flag="$_GHB_FLAG_DIR/alerted-gh-ratelimit-$lane-$bucket-$reset"
    [ -f "$flag" ] && return 0
    if [ -z "$reset" ] || [ "$reset" = "0" ]; then
      iso="unknown"
    else
      iso=$(_ghb_iso "$reset")
    fi
    mins=$(( (reset - now + 59) / 60 )); [ "$mins" -lt 0 ] && mins=0
    line="[$lane] GitHub API rate-limited: $bucket 0/${limit:-?} resets at $iso (in ${mins}m) — $what"
    akey="ghratelimit:$lane:$bucket:$reset"
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $line" >> "$_GHB_LOG_DIR/ALERTS.log"
    if [ -x "$_GHB_H/bin/beat.sh" ]; then
      "$_GHB_H/bin/beat.sh" "$(jq -nc --arg akey "$akey" --arg l "$line" '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
    fi
    : > "$flag"
  }
  _ghb_alert_bucket core   "$core_rem"   "$core_lim"   "$core_reset"
  _ghb_alert_bucket graphql "$graph_rem" "$graph_lim" "$graph_reset"
}
