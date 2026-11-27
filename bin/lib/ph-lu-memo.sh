# shellcheck shell=bash
# bin/lib/ph-lu-memo.sh — BH-10349: the wake-gated answer cache of
# pipeline-health's lead-merge-unqueued block (section 13d). Sourced by
# bin/pipeline-health.sh, never run.
#
# WHY. The hub ledger (2026-11-27, hours 05 and 06) counted about 150
# `pulls/<n>/reviews` and 60 `commits/<sha>/status` reads an hour from this
# block. It reads the same PRs every 10-minute fleet run, and most answers did
# not change between two runs.
#
# THE GATE is bin/lib/wake-backstop.sh (wb_cache_get / wb_cache_put), the one
# the unblock lane uses (BH-10158). An answer is served instead of a read only
# when ALL of these are true:
#   - it is for the same head sha (the meta's first field);
#   - the wake mirror (bin/lib/pr-snapshot-wakes.sh prs_wake_seen) can tell,
#     and has no wake for this object since the stored read STARTED:
#       status   kind `checks`, key <head sha>. GitHub's `status` event for a
#                success, failure or error (the lead-verdict and
#                harness-verdict posts) is a `checks` wake (wakeOf, core.js).
#       reviews  kind `pr`, key <n>. A review submitted, dismissed or edited
#                is a `pr` wake.
#   - the read is younger than PH_LU_MEMO_BACKSTOP_S.
# A feed that cannot tell (no mirror, not fresh, a gap) means "read now". So a
# changed answer is read on the first run after its wake, the same run that
# reads it today: no alert is lost or delayed by this cache.
#
#   phlu_on                     rc 0 when the cache may be used in this run
#   phlu_get <slug> <status|reviews> <n> <head> <out>
#                               rc 0 = <out> holds the stored answer (no read)
#   phlu_t0                     the read-start clock (prints epoch seconds)
#   phlu_put <slug> <status|reviews> <n> <head> <start>  < answer
#                               stores the answer; a failed write costs one read
#   phlu_gc                     deletes cache files older than 3 days (wb_gc)
#
# THE PATH: <root>/state/ph-lu-memo/<owner>_<repo>/<n>-<kind>.{json,meta}
# (catalog/state-paths.d/10349-ph-lu-memo.json, class cache).
#
# KNOB: PH_LU_MEMO_BACKSTOP_S (catalog/lanes.d/pipeline-health.knobs.d/),
# resolved by lane_env_apply pipeline-health before this file is used. 0 =
# off: every call reads GitHub. Not a number = the fallback below.
# The root is ${HARNESS:-${H:-}}. No `set -e`, no `exit`.
[ -n "${_PHLU_LOADED:-}" ] && return 0
_PHLU_LOADED=1
_PHLU_DIR="${BASH_SOURCE[0]%/*}"
# fallback only: the knob is PH_LU_MEMO_BACKSTOP_S in catalog/lanes.d/pipeline-health.knobs.d/PH_LU_MEMO_BACKSTOP_S.json
_PHLU_DEFAULT_BACKSTOP_S=1800

_phlu_back() {
  local v="${PH_LU_MEMO_BACKSTOP_S:-}"
  [[ "$v" =~ ^[0-9]{1,9}$ ]] || v="$_PHLU_DEFAULT_BACKSTOP_S"
  printf '%s' "$((10#$v))"
}

_phlu_root() {
  local r="${HARNESS:-${H:-}}"
  [ -n "$r" ] || return 1
  printf '%s/state/ph-lu-memo' "$r"
}

_phlu_base() { # <slug> <kind> <n>
  local root slug="${1:-}"
  case "$slug" in */*) ;; *) return 1 ;; esac
  case "${3:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${2:-}" in status|reviews) ;; *) return 1 ;; esac
  root=$(_phlu_root) || return 1
  printf '%s/%s/%s-%s' "$root" "$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')" "$3" "$2"
}

phlu_on() {
  [ "$(_phlu_back)" -gt 0 ] || return 1
  _phlu_root >/dev/null || return 1
  if [ "$(type -t wb_cache_get)" != function ]; then
    # shellcheck source=bin/lib/wake-backstop.sh
    . "$_PHLU_DIR/wake-backstop.sh" 2>/dev/null
  fi
  [ "$(type -t wb_cache_get)" = function ] && [ "$(type -t wb_cache_put)" = function ]
}

phlu_get() {
  local slug="${1:-}" kind="${2:-}" n="${3:-}" head="${4:-}" out="${5:-}" base wk key
  [ -n "$head" ] && [ -n "$out" ] || return 1
  base=$(_phlu_base "$slug" "$kind" "$n") || return 1
  if [ "$kind" = status ]; then wk=checks; key=$(printf '%s' "$head" | tr 'A-F' 'a-f'); else wk=pr; key="$n"; fi
  wb_cache_get "$base" "$slug" "$wk" "$key" "$(_phlu_back)" "$head" || return 1
  cat "$base.json" > "$out" 2>/dev/null
}

phlu_t0() {
  if [ "$(type -t _wb_now)" = function ]; then _wb_now; else date +%s; fi
}

phlu_put() {
  local slug="${1:-}" kind="${2:-}" n="${3:-}" head="${4:-}" start="${5:-}" base
  [ -n "$head" ] && [[ "$start" =~ ^[0-9]+$ ]] || { cat >/dev/null; return 1; }
  base=$(_phlu_base "$slug" "$kind" "$n") || { cat >/dev/null; return 1; }
  wb_cache_put "$base" "$head"$'\t'"$start"
}

phlu_gc() {
  local root
  root=$(_phlu_root) || return 0
  [ "$(type -t wb_gc)" = function ] || return 0
  wb_gc "$root"
}
