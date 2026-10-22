# shellcheck shell=bash
# bin/lib/mc-required-ci.sh — BH-8012: the conductor's READY gate decides on
# the repo's REQUIRED checks, not on every workflow. Sourced, never run.
#
# Incident: project-6 #2296 at 09:26Z on 2026-10-22 sat `WAIT_CI merge=UNSTABLE
# reason=checks pending` while only the non-required `E2E n/4` jobs ran. Its
# .mergify.yml required `check-success=ci` alone, and `ci` was green.
# mc_ci_state reduces EVERY workflow on the head, so one pending workflow made
# the word `pending`. Autoenqueue G5 also refused `mergeable_state` `unstable`,
# which GitHub reports while any non-required check runs or is red.
#
# THE RULE. On a Mergify repo (not project-4), when mc_ci_state says `pending` or
# `red` and EVERY `check-success` name of .mergify.yml's queue_rules is
# completed/success (latest run of that exact name) on one complete
# check-runs page of THIS head, the conductor's CI word is `green`. The
# override only releases: it never turns a word into pending or red, and it
# never touches `none` or `unavailable`. An unread list, an unread page, a
# page that does not hold every run, or a required name not green leaves the
# raw word. Mergify still enforces its queue conditions.
#
# MC_CI_REQUIRED_ONLY (default 1; 0 = the behavior before BH-8012).
# Readers: bin/merge-conductor.d/bh-8012-required-ci.sh (the ci-read step),
# bin/lib/autoenqueue.sh (G5).
[ -n "${MC_REQUIRED_CI_LIB:-}" ] && return 0
MC_REQUIRED_CI_LIB=1
# shellcheck source=bin/lib/mc/check-run-state.sh
[ -n "${CRS_JQ_DEFS:-}" ] || . "${BASH_SOURCE[0]%/*}/mc/check-run-state.sh" 2>/dev/null || true

# mcr_enabled — rc 0 unless MC_CI_REQUIRED_ONLY is 0.
mcr_enabled() { [ "${MC_CI_REQUIRED_ONLY:-1}" != 0 ]; }

# mcr_ci_override <slug> <sha> <raw-ci> <provider> — prints `green`, rc 0, when
#   the override applies; prints nothing, rc 1, otherwise. Sets MCR_WHY (one
#   line) in the caller's shell, so call it as a plain command, not in $( ).
mcr_ci_override() {
  local slug="$1" sha="$2" raw="$3" provider="${4:-}" req t rc name cw GH_REST_TIMEOUT_S
  MCR_WHY=""
  mcr_enabled || return 1
  case "$raw" in pending|red) ;; *) return 1 ;; esac
  case "$slug" in */project-4) return 1 ;; esac
  [ "$provider" = mergify ] || return 1
  command -v crs_word >/dev/null 2>&1 && command -v gh_rest >/dev/null 2>&1 \
    && command -v mc_mergify_required_checks >/dev/null 2>&1 || { MCR_WHY=no-reader; return 1; }
  req=$(mc_mergify_required_checks "$slug") || { MCR_WHY=required-unread; return 1; }
  req=$(grep -v '^[[:space:]]*$' <<<"$req")
  [ -n "$req" ] || { MCR_WHY=required-none; return 1; }
  GH_REST_TIMEOUT_S=30
  command -v mc_ci_read_timeout_s >/dev/null 2>&1 && GH_REST_TIMEOUT_S=$(mc_ci_read_timeout_s)
  [ "${GH_REST_TIMEOUT_S:-0}" -gt 0 ] 2>/dev/null || GH_REST_TIMEOUT_S=
  t=$(mktemp "${TMPDIR:-/tmp}/mcr.XXXXXX") || return 1
  rc=0; gh_rest GET "repos/$slug/commits/$sha/check-runs?per_page=100" > "$t" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$t"; MCR_WHY="check-runs read failed (HTTP ${GH_REST_STATUS:-000})"; return 1; fi
  # A page that does not hold every run, or does not parse, is unread, never green.
  if ! jq -e '((.total_count // 0) <= ((.check_runs // []) | length))' "$t" >/dev/null 2>&1; then
    rm -f "$t"; MCR_WHY="check-runs page incomplete or unreadable"; return 1
  fi
  while IFS= read -r name; do
    cw=$(crs_word "$t" "$name" 2>/dev/null)
    [ "$cw" = completed/success ] || { rm -f "$t"; MCR_WHY="required '$name' is ${cw:-unreadable}"; return 1; }
  done <<<"$req"
  rm -f "$t"
  MCR_WHY="required $(paste -sd' ' <<<"$req") green; $raw is non-required"
  printf 'green\n'
}

# mcr_ae_unstable_ok <slug> — rc 0 when autoenqueue G5 may pass a
#   `mergeable_state` of `unstable`: a harness row (AE_EXTERNAL != 1), the knob
#   on, MC_AUTOENQUEUE_CHECK unset, and every G4 name (AE_CHECKS, already
#   proved completed/success on this head) read from the repo's .mergify.yml,
#   not the legacy fallback list. Every other case: rc 1 (clean only).
mcr_ae_unstable_ok() {
  local names c
  mcr_enabled || return 1
  [ "${AE_EXTERNAL:-0}" != 1 ] || return 1
  [ -z "${MC_AUTOENQUEUE_CHECK:-}" ] || return 1
  [ -n "$(tr -d '[:space:]' <<<"${AE_CHECKS:-}")" ] || return 1
  command -v ae_mergify_admit_checks >/dev/null 2>&1 || return 1
  names=$(ae_mergify_admit_checks "$1") || return 1
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    grep -qxF -- "$c" <<<"$names" || return 1
  done <<<"$AE_CHECKS"
  return 0
}
