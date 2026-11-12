# shellcheck shell=bash
# gh-identity: app-token
# bin/merge-conductor.d/bh-9368-ledger-gate-rerun.sh - THE GATE IS RE-RUN ONCE
# WHEN PRODUCTION HOLDS THE SQL (BH-9368, comment 6776463970 Fix 2). Sourced by
# bin/merge-conductor.sh (the BH-7453 fragment block).
#
# A migration-ledger gate (project-6 `gate`) goes red on a PR that adds a SQL
# file production does not hold, and it stays red after the apply until the
# job runs again. mc_ledger_gate_rerun is that run. The WAIT_MIGRATION arm
# (mc_miggate_arm, bh-9368-migration-gate.sh) calls it with pr_worker's P,
# SLUG, NUM, KEY, HEAD, ACTIONS and KILL in scope, and with this head's
# MC_CI_MIGRATION_GATE and MC_CI_RED_RUN_IDS (the runs whose failed required
# jobs are only the gate checks). It sends `gh run rerun <id> --failed` for
# each of those runs ONCE per (PR, head), and only when the migration hold says
# `applied`: production's ledger holds every SQL file of the PR at the head
# checksum (bin/lib/migration-hold.sh). The `ledgergaterun <key> <head>` mark
# is written BEFORE the send, so a crash costs at most one re-run per head.
# Observe mode or the kill switch: one WOULD line, no mark, nothing sent.
# rc 0 = a re-run was sent this tick; rc 1 on every other path.
# shellcheck source=bin/lib/migration-hold.sh
[ -r "$H/bin/lib/migration-hold.sh" ] && ! command -v mmh_decide >/dev/null 2>&1 && . "$H/bin/lib/migration-hold.sh"

mc_ledger_gate_rerun() {
  local id n=0 h8="${HEAD:0:8}"
  [ -n "${MC_CI_MIGRATION_GATE:-}" ] && [ -n "${MC_CI_RED_RUN_IDS:-}" ] || return 1
  [ -n "${P:-}" ] && [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] && [ -n "${SLUG:-}" ] && [ -n "${NUM:-}" ] || return 1
  command -v mmh_decide >/dev/null 2>&1 || return 1
  mc_attempt_has "ledgergaterun $KEY $HEAD" 2>/dev/null && return 1
  mmh_decide "$P" "$SLUG" "$NUM" "$KEY" "$HEAD"
  [ "$MMH_VERDICT" = applied ] || return 1
  if [ "${ACTIONS:-0}" != 1 ] || [ "${KILL:-0}" = 1 ]; then
    mc_log "$KEY WOULD re-run the gate (${MC_CI_MIGRATION_GATE//,/, }; run(s) $MC_CI_RED_RUN_IDS) on $h8: production holds $MMH_NAMES at the head checksum (observe mode: nothing sent)"
    return 1
  fi
  # BH-3804: never re-run a run of a head the PR has left.
  if command -v mc_head_still >/dev/null 2>&1; then mc_head_still "$SLUG" "$KEY" "$HEAD" "gate re-run" || return 1; fi
  mc_attempt_put "ledgergaterun $KEY $HEAD"
  mc_use_token "$SLUG"  # the re-run goes out on the App token of this repo, like every conductor write
  for id in $MC_CI_RED_RUN_IDS; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    gh run rerun "$id" --failed -R "$SLUG" >/dev/null 2>&1 && n=$((n + 1))  # gh-guard-allow: CI rerun write verb, not a decision read (BH-784)
  done
  if [ "$n" -eq 0 ]; then
    mc_log "$KEY gate re-run on $h8: gh refused every run ($MC_CI_RED_RUN_IDS); not retried on this head"
    return 1
  fi
  mc_log "$KEY LEDGER_GATE_RERUN on $h8: production holds $MMH_NAMES at the head checksum, so the gate (${MC_CI_MIGRATION_GATE//,/, }) was re-run once ($n run(s): $MC_CI_RED_RUN_IDS)"
  return 0
}
