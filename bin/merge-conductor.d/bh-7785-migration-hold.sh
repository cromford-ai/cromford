# shellcheck shell=bash
# bin/merge-conductor.d/bh-7785-migration-hold.sh - A MIGRATION NOT IN
# PRODUCTION IS NOT READY (BH-7785). Sourced by bin/merge-conductor.sh (the
# BH-7453 fragment block).
#
# mc_mig_hold — pr_worker calls it right after mc_classify, with pr_worker's
# STATE, WHY, P, SLUG, NUM, KEY and HEAD in scope, above every arm that labels,
# asks Mergify or merges. On a READY row of a project with a
# mc_migration_hold.globs.<project> row, it asks bin/lib/migration-hold.sh
# whether the PR adds a migration that production has not applied. If so, or
# if production cannot be read, the row becomes WAIT_CI with the reason
# `HELD_MIGRATION <names>: <detail>`, one hold comment goes to the PR (kind
# migration) and one alert per (PR, head). The row is re-derived every tick, so
# the tick after the apply takes the ordinary READY path. A project whose
# mc_migration_hold.apply_lane.<project> row names a lane: the row is held for
# that lane, with no probe, no comment and no alert. No lib: no-op.
# shellcheck source=bin/lib/migration-hold.sh
[ -r "$H/bin/lib/migration-hold.sh" ] && . "$H/bin/lib/migration-hold.sh"

mc_mig_hold() {
  [ "${STATE:-}" = READY ] || return 0
  [ -n "${P:-}" ] && [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] && [ -n "${SLUG:-}" ] && [ -n "${NUM:-}" ] || return 0
  command -v mmh_decide >/dev/null 2>&1 || return 0
  command -v mc_step >/dev/null 2>&1 && mc_step migration-hold
  mmh_decide "$P" "$SLUG" "$NUM" "$KEY" "$HEAD"
  local h8="${HEAD:0:8}" apply="apply them to production ahead of the merge (bin/data-lane-apply.sh or the app's /api/internal/migrations/apply)"
  case "$MMH_VERDICT" in
    off) return 0 ;;
    none) mc_log "$KEY migration hold: no new migration file on $h8 ($MMH_SRC)"; return 0 ;;
    applied) mc_log "$KEY migration hold: $MMH_NAMES applied in production on $h8 ($MMH_SRC)"; return 0 ;;
  esac
  STATE=WAIT_CI
  WHY=$(printf 'HELD_MIGRATION %s: %s' "$MMH_NAMES" "$MMH_DETAIL" | tr '\t\r\n' '   ')
  mc_log "$KEY HELD_MIGRATION $MMH_NAMES on $h8: $MMH_DETAIL ($MMH_SRC)"
  [ "$MMH_VERDICT" = lane ] && return 0
  command -v mc_hold_comment >/dev/null 2>&1 && \
    mc_hold_comment "$KEY" "$HEAD" migration "$MMH_NAMES not applied in production ($MMH_DETAIL). Apply step: $apply"
  if [ "${ACTIONS:-0}" != 1 ] || [ "${KILL:-0}" = 1 ]; then
    mc_log "$KEY WOULD alert HELD_MIGRATION $MMH_NAMES on $h8 (observe mode: nothing sent)"
  elif ! mc_attempt_has "mighold $KEY $HEAD" 2>/dev/null; then
    # The mark before the send: a crash costs one alert, never a storm.
    mc_attempt_put "mighold $KEY $HEAD"
    mc_alert "$KEY" HELD_MIGRATION "$MMH_NAMES not applied in production on $h8 ($MMH_DETAIL); $apply"
  fi
  return 0
}
