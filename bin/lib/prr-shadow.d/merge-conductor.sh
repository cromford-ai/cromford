#!/bin/bash
# bin/lib/prr-shadow.d/merge-conductor.sh — the prr-shadow seam of lane merge-conductor (BH-9926).
# Sourced by prr_seam_load merge-conductor (bin/lib/prr-shadow.sh), never executed.
#
# The knob GH_SOURCE (settings row lane.merge-conductor.gh_source, default
# shadow) is registered in catalog/lanes.d/merge-conductor.knobs.d/.
#
# The CI word (BH-9926 wave 4). mc_ci_state <slug> <sha> <n> (bin/lib/mc/classify.sh)
# calls prr_read merge-conductor "<slug>#<n>@<sha12>" <file> mc_ci_record mc_ci_github mc_ci_norm <slug> <sha> <n>:
#   mc_ci_record <file> <slug> <sha> <n>
#       prr_ci_state (bin/lib/prr-ci-state.sh). green or pending: the word in
#       <file>, rc 0. red prints ci:red, unknown prints ci:unknown, rc 1: the
#       record never serves red, because the red arms need the run ids and the
#       advisory split (BH-9210) that only the actions/runs read fills. In step
#       shadow it runs with PRR_CI_GUARD=0, so shadow makes no guard read.
#   mc_ci_github <file> <slug> <sha> <n>
#       _mc_ci_state_github <slug> <sha> > <file>, a plain command, so its
#       globals (MC_CI_READ_HELD, MC_CI_RUNS, ...) reach the caller. rc 0.
#   mc_ci_norm <file>
#       [{"n":"ci","v":"<word>"}] for green, pending or red; nothing for none
#       and unavailable, so those are never compared.
#
# Wave 6 adds the lane's other GitHub reads here, under other names
# (mc_record / mc_github / mc_norm).
if ! command -v prr_ci_state >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../prr-ci-state.sh" ]; then
  # shellcheck source=bin/lib/prr-ci-state.sh
  . "${BASH_SOURCE[0]%/*}/../prr-ci-state.sh"
fi

mc_ci_record() {
  local f="${1:-}" slug="${2:-}" sha="${3:-}" n="${4:-}" w g="${PRR_CI_GUARD:-1}"
  [ -n "$f" ] || return 2
  command -v prr_ci_state >/dev/null 2>&1 || { echo ci:unknown; return 1; }
  command -v prr_step >/dev/null 2>&1 && [ "$(prr_step merge-conductor)" = shadow ] && g=0
  w=$(PRR_CI_GUARD="$g" prr_ci_state "$slug" "$n" "$sha")
  case "$w" in
    green|pending) printf '%s\n' "$w" > "$f"; return 0 ;;
    red) echo ci:red; return 1 ;;
    *) echo ci:unknown; return 1 ;;
  esac
}

mc_ci_github() {
  local f="${1:-}"
  [ -n "$f" ] || return 2
  _mc_ci_state_github "${2:-}" "${3:-}" > "$f"
  return 0
}

mc_ci_norm() {
  local w
  w=$(head -1 "${1:-}" 2>/dev/null)
  case "$w" in green|pending|red) printf '[{"n":"ci","v":"%s"}]\n' "$w" ;; esac
}
