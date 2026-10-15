#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/settings.sh — BH-1194: the operator knobs — the review gate (tighten flag, thresholds, rows) and the settings table read by setting_get / setting_set. Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# --- SDLC item 2: the review gate (2026-08-29) -------------------------------
# Two things live here and they are deliberately NOT the same thing:
#
#   the SWITCH      a pause_flags row named review-tighten-<repo>, set and read
#                   through flag_set / flag_active. It rides the existing flag
#                   rail on purpose: that rail already write-throughs to a file,
#                   so a repo stays parked through a worker outage, and
#                   bin/merge-sweep.sh already reads flags exactly this way.
#   the MEASUREMENT a review_gate row: the rate, the thresholds it was judged
#                   against and the verdict. Read by the console, never by a
#                   merge decision.
#
# One switch with one reader is the whole point. A second "is this repo
# tightened" derived from the rate at read time would be a second copy of the
# rule, and the two would disagree the first run after a threshold edit.

# review_tighten_flag_name <repo-slug> — the ONE place the flag name is derived.
# The slug carries a '/', which the flag rail's own name charset refuses, so
# every caller has to sanitise it the same way or merge-sweep would test a flag
# nobody sets. Prints nothing and returns 1 for an empty repo.
review_tighten_flag_name() {
  local repo="${1:-}" n
  [ -n "$repo" ] || return 1
  # A repo slug is ALWAYS owner/name, and requiring the slash is what keeps this
  # namespace from colliding with the lane's own kill switch: a bare "disabled"
  # would sanitise to review-tighten-disabled and silently turn the detector off
  # for the whole fleet. Every caller passes a slug parsed out of a PR url.
  case "$repo" in */*) ;; *) return 1 ;; esac
  n=$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '-')
  [ -n "$n" ] || return 1
  printf 'review-tighten-%s' "$n"
}

# review_tighten_active <repo-slug> — rc 0 when this repo's harness PRs must
# PARK instead of auto-merging. Reconciles from the DB and then answers from the
# file, exactly like every other flag: an unreachable worker leaves the box
# deciding on what it already knows rather than guessing in either direction.
review_tighten_active() {
  local name
  name=$(review_tighten_flag_name "${1:-}") || return 1
  flag_active "$name"
}

# review_tighten_set <repo-slug> on|off [reason]
review_tighten_set() {
  local name
  name=$(review_tighten_flag_name "${1:-}") || return 1
  flag_set "$name" "${2:-}" "${3:-}"
}

# review_gate_thresholds <repo-slug> — the thresholds that WOULD apply, resolved
# repo-first then the '*' fleet default. Prints TSV
# (scope, window_days, min_merges, tighten_rate, clear_rate).
#   rc 2 -> the table has no row for either scope (a REAL answer: use the
#           documented code fallback in bin/review-tighten.sh)
#   rc 1 -> outage
review_gate_thresholds() {
  local repo="${1:-}" resp row
  resp=$(_jobs_req GET /api/review-gate) || return $?
  row=$(printf '%s' "$resp" | jq -r --arg r "$repo" '
    ( [ .thresholds[]? | select(.scope == $r) ] + [ .thresholds[]? | select(.scope == "*") ] )
    | .[0] // empty
    | [ .scope, .window_days, .min_merges, .tighten_rate, .clear_rate ] | @tsv' 2>/dev/null)
  [ -n "$row" ] || return 2
  printf '%s' "$row"
}

# review_gate_threshold_set <scope> <window_days> <min_merges> <tighten_rate> <clear_rate> [note]
#   The worker VALIDATES these (see its handler): an inverted or out-of-range
#   pair is refused there rather than clamped here, so there is one definition
#   of a legal threshold and it is the one the database enforces.
review_gate_threshold_set() {
  local scope="${1:-}" win="${2:-}" minm="${3:-}" tr="${4:-}" cr="${5:-}" note="${6:-}" body
  [ -n "$scope" ] && [ -n "$win" ] && [ -n "$minm" ] && [ -n "$tr" ] && [ -n "$cr" ] || return 1
  body=$(jq -nc --arg s "$scope" --argjson w "$win" --argjson m "$minm" \
    --argjson t "$tr" --argjson c "$cr" --arg n "$note" \
    '{scope:$s,window_days:$w,min_merges:$m,tighten_rate:$t,clear_rate:$c}
     + (if $n == "" then {} else {note:$n} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/review-gate/thresholds "$body" >/dev/null
}

# review_gate_put <repo> <tightened 0|1> <rate> <bad> <merges> <window_days>
#                 <tighten_rate> <clear_rate> <min_merges> <threshold_scope>
#                 <decision> <evidence>
#   Written on EVERY measurement, including the ones that change nothing — a
#   gate that only records the days it fired cannot answer "was this repo
#   measured at all", which is the first question asked of a detector that
#   stayed quiet.
review_gate_put() {
  local repo="${1:-}" tightened="${2:-}" body
  [ -n "$repo" ] && [ -n "$tightened" ] || return 1
  body=$(jq -nc --arg repo "$repo" --arg tg "$tightened" --arg rate "${3:-}" \
    --arg bad "${4:-}" --arg merges "${5:-}" --arg win "${6:-}" --arg tr "${7:-}" \
    --arg cr "${8:-}" --arg mm "${9:-}" --arg scope "${10:-}" --arg dec "${11:-}" \
    --arg ev "${12:-}" --arg actor "$JOBS_BOX" \
    '{repo:$repo,tightened:$tg,rate:$rate,bad:$bad,merges:$merges,window_days:$win,
      tighten_rate:$tr,clear_rate:$cr,min_merges:$mm,threshold_scope:$scope,
      decision:$dec,evidence:$ev,actor:$actor}' 2>/dev/null) || return 1
  _jobs_req PUT /api/review-gate "$body" >/dev/null
}

# review_gate_list — TSV of repo, tightened, rate, bad, merges, decision, updated_at.
review_gate_list() {
  local resp
  resp=$(_jobs_req GET /api/review-gate) || return $?
  printf '%s' "$resp" | jq -r '.gates[]? |
    [ .repo, .tightened, (.rate // "-"), (.bad // "-"), (.merges // "-"),
      (.decision // "-"), (.updated_at // "-") ] | @tsv' 2>/dev/null
}

# --- Reopen rate row (BH-117) -------------------------------------------------
# The other trust signal, and the one that DEMOTES a build: bin/reopen-metrics.sh
# measures each project's 14-day reopen rate on the hub, and the build's
# `reopen trust signal` block reads it. It used to travel only as the hub's
# state/reopen-rate.json, so every watcher box read no signal at all. Now it is
# one `ledgers` row per project (kind=reopen_rate, key=<project>, detail =
# {"reopens_14d":N,"builds_total":D}), and the file is the fallback.

# reopen_rate_put <project> <reopens_14d> <builds_total>
#   rc 1 without a request for an empty project or a count that is not a
#   non-negative integer: a junk row would be read on every box. Otherwise the
#   job_ledger_put rc (0 written, 1 outage/5xx/no secret).
reopen_rate_put() {
  local p="${1:-}" n="${2:-}" d="${3:-}" detail
  [ -n "$p" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$d" in ''|*[!0-9]*) return 1 ;; esac
  detail=$(jq -nc --argjson n "$n" --argjson d "$d" '{reopens_14d:$n,builds_total:$d}' 2>/dev/null) || return 1
  job_ledger_put reopen_rate "$p" measured "$detail"
}

# reopen_rate_get <project> — prints N<TAB>D<TAB>updated_at.
#   rc 2 -> no row for this project (a real answer)
#   rc 1 -> outage, no secret, or a row whose detail is not two non-negative
#           integers. A malformed row is unusable, never read as 0/0.
reopen_rate_get() {
  local p="${1:-}" q resp rc out
  [ -n "$p" ] || return 1
  q=$(jq -nr --arg v "$p" '"kind=reopen_rate&key="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/ledger?$q"); rc=$?
  case "$rc" in 0) ;; 2) return 2 ;; *) return 1 ;; esac
  out=$(printf '%s' "$resp" | jq -r '
    .ledger as $l | ($l.detail | fromjson?) as $d
    | select(($d | type) == "object")
    | [$d.reopens_14d, $d.builds_total] as $v
    | select(all($v[]; type == "number" and . >= 0 and . == floor))
    | [($v[0] | tostring), ($v[1] | tostring), ($l.updated_at // "")] | @tsv' 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}


# --- Operator settings (BH-283/371) ------------------------------------------
# One row per number an operator may need to change without a deploy, read by
# consumers that tick every minute. The three rcs are the whole contract: a
# caller must be able to tell "the operator set it to this" from "nobody has
# set it, use your documented fallback" from "the worker did not answer, use
# your fallback too". A blip that read as a lowered threshold would change
# fleet behaviour with nobody deciding it.

# _setting_key_ok <key> — the same charset the worker enforces, asked here FIRST.
# A key becomes part of a URL, so an illegal one must never be sent: `a/b` is a
# different route entirely, and `bad key` comes back as an http=400 that lands in
# logs/jobs-client.log reading exactly like the worker misbehaving. It is a
# caller bug, it answers rc 1, and it costs no request.
_setting_key_ok() { # _setting_key_ok <key>
  local key="${1:-}"
  case "$key" in ''|*[!a-z0-9_.-]*) return 1 ;; esac
  [ "${#key}" -le 64 ] || return 1
}

# The box cache (BH-5781). lane-gate fills state/settings-cache.json with the
# whole settings list once a tick (_lg_settings_refresh). A FRESH copy answers
# setting_get with no request: closeout_aged_table, archie.cap.<playbook> and
# routing_rows were read once per call, often inside a `$( )` that loses the
# per-process memo, and they topped the D1 overload log on 2026-10-09.
# JOBS_SETTINGS_CACHE_S (default LANE_GATE_CACHE_S, 60) is the freshness
# window; 0 switches the cache path off. setting_get never refreshes the file:
# a refresh is the heavier list read.
#
# _SETTING_SIGNED_KEYS: keys the worker signs, whose single-key answer can
# differ from the list row (worker/jobs/src/routes/verdicts.js
# PROTECTED_HUMAN_KEYS and PROTECTED_PREFIXES, plus the v1 `<key>.sig` rows).
# They always go to the worker.
_SETTING_SIGNED_KEYS="human_verdict_mode human_verdict_sig_mode *.sig lead_authority.* risk_tier.*"
_setting_cache_file() { [ -n "${JOBS_HARNESS:-}" ] && printf '%s' "$JOBS_HARNESS/state/settings-cache.json"; }

# _setting_cached <key> — rc 0 + value, or rc 2 (no row), from a fresh cache.
#   rc 1 -> no answer here (no file, stale, future-dated, not JSON, signed key,
#   cache off): the caller asks the worker.
_setting_cached() {
  local key="$1" f ttl fetched now age pat val
  ttl="${JOBS_SETTINGS_CACHE_S:-${LANE_GATE_CACHE_S:-60}}"
  case "$ttl" in ''|*[!0-9]*|0) return 1 ;; esac
  for pat in $_SETTING_SIGNED_KEYS; do
    # shellcheck disable=SC2254 # $pat is a glob on purpose
    case "$key" in $pat) return 1 ;; esac
  done
  f=$(_setting_cache_file) && [ -r "$f" ] || return 1
  fetched=$(jq -r '.fetched_at' "$f" 2>/dev/null) || return 1
  case "$fetched" in ''|*[!0-9]*) return 1 ;; esac
  now="${LANE_GATE_NOW:-$(date -u +%s)}"
  age=$(( now - fetched ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ] || return 1
  val=$(jq -r --arg k "$key" '.values[$k] // .seeded[$k] // empty' "$f" 2>/dev/null) || return 1
  [ -n "$val" ] || return 2
  printf '%s' "$val"
}

# setting_get <key> — prints the value of one operator knob (settings.value).
#   rc 0 -> found (stdout = value)
#   rc 2 -> no row (a REAL answer: the caller uses its documented fallback).
#           Also what a worker that predates /api/settings answers (404).
#   rc 1 -> outage, bad key, or HARNESS_SECRET unset
setting_get() {
  local key="${1:-}" resp val rc
  _setting_key_ok "$key" || return 1
  val=$(_setting_cached "$key"); rc=$?
  [ "$rc" -eq 0 ] && { printf '%s' "$val"; return 0; }
  [ "$rc" -eq 2 ] && return 2
  resp=$(_jobs_req GET "/api/settings/$key") || return $?
  val=$(printf '%s' "$resp" | jq -r '.setting.value // empty' 2>/dev/null)
  [ -n "$val" ] || return 2
  printf '%s' "$val"
}

# setting_set <key> <value> [note] — writes the knob, with this box as the actor.
#   The key is checked here only for the charset that makes it a legal URL; the
#   worker VALIDATES the VALUE (see its handler): an empty or oversized value is
#   refused there rather than fixed up here, so there is one definition of a
#   legal knob value and it is the one the database enforces.
setting_set() {
  local key="${1:-}" value="${2:-}" note="${3:-}" body
  _setting_key_ok "$key" || return 1
  [ -n "$value" ] || return 1
  body=$(jq -nc --arg k "$key" --arg v "$value" --arg n "$note" --arg a "$JOBS_BOX" \
    '{key:$k,value:$v,actor:$a} + (if $n == "" then {} else {note:$n} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/settings "$body" >/dev/null || return $?
  _setting_cache_stale
}

# _setting_cache_stale — after a write, the next setting_get on this box asks
# the worker: fetched_at goes to 0. The file stays, because lane-gate reads a
# stale copy as its outage fallback. Always rc 0.
_setting_cache_stale() {
  local f tmp
  f=$(_setting_cache_file) && [ -r "$f" ] || return 0
  tmp=$(mktemp "$(dirname "$f")/.settings-cache.XXXXXX" 2>/dev/null) || return 0
  jq -c '.fetched_at = 0' "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}


