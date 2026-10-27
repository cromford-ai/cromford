#!/bin/bash
# bin/lib/trk-lane.sh — the lane seam over the tracker contract (BH-8451, slice
# C3 of #7920). A lane that used to read "which tracker" from fleet.conf column
# 4 asks trk_lane_kind instead. For jira and linear it reads through
# trk_lane_list (tracker_context + tracker_list); any other answer keeps the
# lane's own GitHub or board code path.
#
# Sourced, never executed: no `set -e`, no `exit`, no output at source time,
# safe under the caller's `set -u`. Sourcing it twice is inert.
#
# THE TRIGGER (the same rule as bin/triage-gate.sh, C0). tracker_kind is asked
# only when the project env file (<env dir>/<project>.env) has a JIRA_BASE= or
# LINEAR_API_KEY= line with a value. Every other project pays 0 settings calls.
#
#   trk_lane_creds <harness> <project>   rc 0 when that line exists. Never
#                                        prints, never reads a value.
#   trk_lane_kind <harness> <project>    sets TRK_LANE_KIND in THIS shell: ""
#                                        without the trigger, else tracker_kind's
#                                        answer ("" on rc 1). Always rc 0.
#   trk_lane_list <harness> <project> <lane> [tracker_list flags…]
#                                        in a subshell: tracker_context, then
#                                        tracker_list. With no --label flag it
#                                        adds the adapter's build label (the
#                                        label its server query already asks
#                                        for), so the contract's own check drops
#                                        an unlabelled row too. A --label flag
#                                        (hotfix) is an AND with the build
#                                        label, never a swap: the server query
#                                        asks for the flag's label and every row
#                                        without the build label is dropped
#                                        here, as GitHub's `labels=ai-build,X`
#                                        does. The JSON array on
#                                        stdout, rc 0. On failure: nothing on
#                                        stdout, rc 1, one stderr line
#                                        `trk-lane: <lane> <project>: …`. Never a
#                                        token.

_trk_lane_dir() { dirname "${BASH_SOURCE[0]}"; }

# _trk_lane_env <harness> — source env-path.sh, the copy beside this file
# first, then <harness>/bin/lib. Nothing else: a project without the trigger
# loads no tracker code at all.
_trk_lane_env() {
  local h="${1:-}" d
  declare -F harness_env_dir >/dev/null 2>&1 && return 0
  d=$(_trk_lane_dir)
  # shellcheck source=bin/lib/env-path.sh
  . "$d/env-path.sh" 2>/dev/null || { [ -n "$h" ] && . "$h/bin/lib/env-path.sh" 2>/dev/null; } || true
}

# _trk_lane_src <harness> — source tracker.sh the same way. rc 1 when it is
# missing.
_trk_lane_src() {
  local h="${1:-}" d
  d=$(_trk_lane_dir)
  if ! declare -F tracker_kind >/dev/null 2>&1; then
    # shellcheck source=bin/lib/tracker.sh
    . "$d/tracker.sh" 2>/dev/null || { [ -n "$h" ] && . "$h/bin/lib/tracker.sh" 2>/dev/null; } || return 1
  fi
  declare -F tracker_kind >/dev/null 2>&1
}

trk_lane_creds() {
  local h="${1:-}" p="${2:-}" envd=""
  [ -n "$h" ] && [ -n "$p" ] || return 1
  _trk_lane_env "$h"
  declare -F harness_env_dir >/dev/null 2>&1 && envd=$(harness_env_dir "$h" 2>/dev/null)
  [ -n "$envd" ] || envd="$h/env"
  [ -r "$envd/$p.env" ] || return 1
  grep -qE "^(export )?(JIRA_BASE|LINEAR_API_KEY)=(\"[^\"]|'[^']|[^\"'[:space:]#])" "$envd/$p.env" 2>/dev/null
}

trk_lane_kind() {
  local h="${1:-}" p="${2:-}"
  TRK_LANE_KIND=""
  trk_lane_creds "$h" "$p" || return 0
  _trk_lane_src "$h" || return 0
  # In THIS shell, so tracker.sh's per-process cache is warm for a later call
  # inside $( … ); the second call reads that cache and asks no one.
  HARNESS="$h" tracker_kind "$p" >/dev/null 2>&1 || return 0
  TRK_LANE_KIND=$(HARNESS="$h" tracker_kind "$p" 2>/dev/null) || TRK_LANE_KIND=""
  return 0
}

trk_lane_list() {
  local h="${1:-}" p="${2:-}" lane="${3:-trk-lane}" a lbl=0
  shift 3 2>/dev/null || { printf 'trk-lane: usage: trk_lane_list <harness> <project> <lane> [flags]\n' >&2; return 1; }
  [ -n "$h" ] && [ -n "$p" ] || { printf 'trk-lane: %s: no harness or project\n' "$lane" >&2; return 1; }
  for a in "$@"; do [ "$a" = --label ] && lbl=1; done
  (
    _trk_lane_src "$h" || { printf 'trk-lane: %s %s: no tracker lib\n' "$lane" "$p" >&2; exit 1; }
    export HARNESS="$h"
    TRK_ERR="${TRK_ERR:-/dev/null}"
    tracker_context "$p" "$lane" 2>/dev/null \
      || { printf 'trk-lane: %s %s: context %s\n' "$lane" "$p" "${TRK_CTX_MISSING:-unknown}" >&2; exit 1; }
    bl=""
    case "${TRK_ADAPTER:-}" in
      linear) bl="${TRK_LINEAR_LABEL:-ai-build}" ;;
      jira)   bl="${TRK_JIRA_LABEL:-ai-build}" ;;
    esac
    [ "$lbl" = 0 ] && [ -n "$bl" ] && set -- "$@" --label "$bl"
    out=$(tracker_list "$@" 2>/dev/null); rc=$?
    [ "$rc" = 0 ] || { printf 'trk-lane: %s %s: list rc %s\n' "$lane" "$p" "$rc" >&2; exit 1; }
    # BH-8451 (BLOCK row 4515): the AND. A hotfix ticket without the build
    # label is outside the build queue, so no lane sees it.
    if [ -n "$bl" ]; then
      out=$(printf '%s' "$out" | jq -ce --arg b "$bl" \
        '[.[] | select(any((.labels // [])[]?; (tostring | ascii_downcase) == ($b | ascii_downcase)))]' 2>/dev/null) \
        || { printf 'trk-lane: %s %s: list is not an array\n' "$lane" "$p" >&2; exit 1; }
    fi
    printf '%s\n' "$out"
  )
}
