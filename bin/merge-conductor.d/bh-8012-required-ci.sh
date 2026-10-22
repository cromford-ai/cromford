# shellcheck shell=bash
# bin/merge-conductor.d/bh-8012-required-ci.sh - A NON-REQUIRED CHECK DOES NOT
# HOLD A PR (BH-8012). Sourced by bin/merge-conductor.sh (the BH-7453 fragment
# block).
#
# mc_cireq_apply — pr_worker calls it at the ci-read step, right after the
# memo block, with pr_worker's CI, SLUG, KEY, HEAD and PROVIDER in scope. When
# mcr_ci_override (bin/lib/mc-required-ci.sh) proves every required check of
# .mergify.yml green on this head, CI becomes `green`, MC_CI_REQUIRED_GREEN
# becomes 1 and one CI_REQUIRED_GREEN line is logged per (PR, head). It runs
# before the red-strike and red-ladder block, so a red non-required workflow
# buys no strike and no rerun. The memo keeps the raw word. No lib: no-op.
# shellcheck source=bin/lib/mc-required-ci.sh
[ -r "$H/bin/lib/mc-required-ci.sh" ] && . "$H/bin/lib/mc-required-ci.sh"

mc_cireq_apply() {
  MC_CI_REQUIRED_GREEN=0
  case "${CI:-}" in pending|red) ;; *) return 0 ;; esac
  command -v mcr_ci_override >/dev/null 2>&1 || return 0
  mcr_ci_override "$SLUG" "$HEAD" "$CI" "${PROVIDER:-}" >/dev/null || return 0
  CI=green; MC_CI_REQUIRED_GREEN=1
  if ! mc_attempt_has "cireqgreen $KEY $HEAD" 2>/dev/null; then
    mc_attempt_put "cireqgreen $KEY $HEAD"
    mc_log "$KEY CI_REQUIRED_GREEN on ${HEAD:0:8}: $MCR_WHY — not held on non-required checks"
  fi
  return 0
}
