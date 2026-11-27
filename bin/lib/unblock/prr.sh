# shellcheck shell=bash
# bin/lib/unblock/prr.sh — the unblock lane's reads on the PR record
# (BH-10158, BH-9926 wave 5, slice C2 of #9937). Sourced by
# bin/lib/unblock/ticket-pr.sh and each bin/lib/unblock/collectors/*.sh.
# Defines functions only: no set -e, no exit.
#
# THE STEP is prr_step unblock (bin/lib/prr-shadow.sh): the knob GH_SOURCE,
# settings row lane.unblock.gh_source, default shadow. bin/unblock.sh reads it
# ONCE per tick and exports GH_SOURCE, so each collector subshell sees the
# same value. With no prr-shadow.sh the step is off.
#
#   ubp_step
#       Prints the step: prr_step unblock, or off when prr-shadow.sh did not load.
#
#   ubp_read <key> <out> <record-fn> <github-fn> <norm-fn> [args...]
#       prr_read unblock <key> ... when prr_read and the seam
#       bin/lib/prr-shadow.d/unblock.sh loaded: off reads GitHub, shadow reads
#       both and acts on GitHub (one PRR_SHADOW line on a difference), record
#       reads the record (a miss reads GitHub, one PRR_MISS line). Else
#       <github-fn> <out> [args...], today's read. Returns the rc of the
#       source whose answer is in <out>. Call it as a plain command, never in
#       $( ): the github-fn's GH_REST_STATUS stays in the caller's shell.
#
#   ubp_cached <owner/repo> <n|-> <head|-> <kind> <out> <cmd...>
#       THE WAKE GATE for a read the record cannot answer (reviews, comments,
#       the closed list). <cmd...> is the read; it writes <out>.
#         step off or shadow: run <cmd...>, return its rc. No cache file.
#         step record: the base is
#           <root>/state/unblock-prr/<owner>_<repo>/<n or "repo">-<kind>.
#           When wb_cache_get <base> <repo> pr <n or -> <back> <head or -> is
#           rc 0 (the meta's head is <head> byte for byte, and wb_due says no
#           `pr` wake for <n> since the read started and the backstop has not
#           run out), <base>.json is copied to <out>: rc 0, no GitHub call.
#           Else <start> = the gate clock (_wb_now: WAKE_BACKSTOP_NOW under
#           HARNESS_TEST_SANDBOX=1), then <cmd...>. When it is rc 0 AND <out>
#           is valid JSON, wb_cache_put <base> "<head or ->\t<start>" < <out>.
#           A failed read writes no cache file. Returns the cmd's rc.
#       UBP_FRESH=<mark> (BH-10197): the change gate
#       (bin/lib/unblock/change-gate.sh ubg_fresh) sets it for a PR it let
#       through on a change. The key is <head>@<mark>, and a cache file is
#       served only when its read started in this tick (at or after _UBP_T0),
#       so a stale file is never stored under a newer change mark. The review
#       collector still reuses the reviews the queue collector read in the
#       same tick under the same mark. A mark that is not digits is 0.
#       <n> `-` is the repo-wide key: any `pr` wake of the repo makes it due.
#       <back> is the knob UNBLOCK_PRR_BACKSTOP_S (int, default 1800, 0 =
#       always read; catalog/lanes.d/unblock.knobs.d/UNBLOCK_PRR_BACKSTOP_S.json).
#
#   ubp_prepare
#       In step record, loads the wake-backstop lib once in the caller's
#       shell, so parallel reads (`&`) do not each load it. rc 0 always.
#
#   ubp_gc
#       wb_gc <root>/state/unblock-prr: deletes cache files older than 3
#       days. The retention rule of the cache: bin/unblock.sh calls it once
#       per tick. No directory, no work.
#
# The root is ${HARNESS:-${H:-}} and nothing else: with no root, ubp_cached
# only runs the cmd.
[ -n "${_UBP_LOADED:-}" ] && return 0
_UBP_LOADED=1
_UBP_DIR="${BASH_SOURCE[0]%/*}"
_UBP_T0=""
# fallback only: the knob is UNBLOCK_PRR_BACKSTOP_S in catalog/lanes.d/unblock.knobs.d/UNBLOCK_PRR_BACKSTOP_S.json
_UBP_DEFAULT_BACKSTOP_S=1800

if ! command -v prr_read >/dev/null 2>&1; then
  # shellcheck source=bin/lib/prr-shadow.sh
  . "$_UBP_DIR/../prr-shadow.sh" 2>/dev/null
fi
# The seam, sourced by path (not prr_seam_load) so a closure install carries it.
if ! declare -F ub_open_record >/dev/null; then
  # shellcheck source=bin/lib/prr-shadow.d/unblock.sh
  . "$_UBP_DIR/../prr-shadow.d/unblock.sh" 2>/dev/null || true
fi

ubp_step() {
  if command -v prr_step >/dev/null 2>&1; then prr_step unblock; else printf 'off\n'; fi
}

_ubp_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _ubp_wb — rc 0 when the wake-backstop lib is loaded (sourced when not).
_ubp_wb() {
  if [ "$(type -t wb_cache_get)" != function ]; then
    # shellcheck source=bin/lib/wake-backstop.sh
    . "$_UBP_DIR/../wake-backstop.sh" >/dev/null 2>&1
  fi
  [ "$(type -t wb_cache_get)" = function ] && [ "$(type -t wb_cache_put)" = function ]
}

_ubp_back() {
  local v="${UNBLOCK_PRR_BACKSTOP_S:-}"
  if [[ $v =~ ^[0-9]{1,6}$ ]]; then printf '%s' "$((10#$v))"; else printf '%s' "$_UBP_DEFAULT_BACKSTOP_S"; fi
}

ubp_read() {
  local key="${1:-}" out="${2:-}" rfn="${3:-}" gfn="${4:-}" nfn="${5:-}"
  shift 5 2>/dev/null || return 2
  [ -n "$out" ] && [ -n "$gfn" ] || return 2
  if command -v prr_read >/dev/null 2>&1 && declare -F "$rfn" >/dev/null && declare -F "$nfn" >/dev/null; then
    prr_read unblock "$key" "$out" "$rfn" "$gfn" "$nfn" "$@"
    return $?
  fi
  "$gfn" "$out" "$@"
}

# _ubp_this_tick <base>: rc 0 when the cache meta's read start is at or after
# _UBP_T0 (the tick start on the gate clock). No T0: rc 1.
_ubp_this_tick() {
  local u e
  [ -n "$_UBP_T0" ] && IFS=$'\t' read -r u e < "$1.meta" 2>/dev/null && [[ $e =~ ^[0-9]+$ ]] && [ "$e" -ge "$_UBP_T0" ]
}

ubp_cached() {
  local repo="${1:-}" n="${2:-}" head="${3:-}" kind="${4:-}" out="${5:-}" root base start rc fresh="${UBP_FRESH:-}"
  shift 5 2>/dev/null || return 2
  [ "$#" -gt 0 ] || return 2
  root=$(_ubp_root)
  if [ "$(ubp_step)" != record ] || [ -z "$root" ] || [ -z "$out" ] \
     || ! [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ! [[ $n =~ ^(-|[1-9][0-9]{0,9})$ ]] \
     || ! [[ $kind =~ ^[a-z][a-z-]{0,31}$ ]] || [ -z "$head" ] || ! _ubp_wb; then
    "$@"; return $?
  fi
  base="$root/state/unblock-prr/${repo%%/*}_${repo#*/}/${n/#-/repo}-$kind"
  if [ -n "$fresh" ]; then [[ $fresh =~ ^[0-9]{1,15}$ ]] || fresh=0; head="$head@$fresh"; fi
  if wb_cache_get "$base" "$repo" pr "$n" "$(_ubp_back)" "$head" && { [ -z "$fresh" ] || _ubp_this_tick "$base"; } \
     && cp "$base.json" "$out" 2>/dev/null; then
    return 0
  fi
  start=$(_wb_now)
  "$@"; rc=$?
  if [ "$rc" = 0 ] && jq -e . "$out" >/dev/null 2>&1; then
    wb_cache_put "$base" "$head"$'\t'"$start" < "$out" || true
  fi
  return "$rc"
}

# The tick start, once, on the clock of _wb_now (bin/lib/wake-backstop.sh:
# WAKE_BACKSTOP_NOW under HARNESS_TEST_SANDBOX=1, else the box clock). The rule
# is copied, not loaded: loading that lib reads the lane settings. bin/unblock.sh
# sources this lib (through ticket-pr.sh) before the collectors, whose
# subshells inherit it. A collector that sources it first takes its own start.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${WAKE_BACKSTOP_NOW:-} =~ ^[0-9]+$ ]]; then
  _UBP_T0=$((10#$WAKE_BACKSTOP_NOW))
else
  _UBP_T0=$(date +%s)
fi

ubp_prepare() {
  [ "$(ubp_step)" = record ] && _ubp_wb
  return 0
}

ubp_gc() {
  local root d
  root=$(_ubp_root); [ -n "$root" ] || return 0
  d="$root/state/unblock-prr"
  [ -d "$d" ] || return 0
  _ubp_wb || return 0
  wb_gc "$d"
}
