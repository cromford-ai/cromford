# shellcheck shell=bash
# bin/merge-conductor.d/bh-9403-before-merge-proof.sh - the conductor reads the
# before-merge apply's proof for a NORMAL PR (BH-9403). Sourced by
# bin/merge-conductor.sh (the BH-7453 fragment block). Called by mc_mig_hold
# (fragment bh-7785-migration-hold.sh) on a READY row, with pr_worker's STATE,
# WHY, P, SLUG, NUM, KEY, RAWLBL and REC in scope.
#
# mc_bm_proof sets MC_BM_APPLIED=0, then acts only on a READY row of a project
# whose settings row hotfix_migrate.conf.<project> has "before_merge":1, and only
# for a PR that is NOT a hotfix (hotfix PRs keep the proof gate in
# bin/merge-conductor.sh). It asks mc_hotfix_proof with the label gate off:
#   ok    an applied proof for exactly this head's SQL -> MC_BM_APPLIED=1. It
#         is logged, and mc_mig_hold still asks the production ledger
#         (mmh_decide) when the project has a migration-hold row: the proof
#         never stands in for production.
#   hold  the stage held on a TERMINAL outcome (the workflow refused it, it is
#         inert, the run failed or could not be bound, a config gap such as more
#         files than max_files) -> STATE=BLOCKED_HUMAN, so the PR gets no
#         merge-queue label. The reason is not resolver-owned: a person reads
#         the proof comment. A needs-operator proof (BH-9817) is a hold too,
#         and mc_bm_held_alert (bh-9817-held-operator-alert.sh) alerts once it
#         is held longer than hotfix_migrate.held_alert_hours. Before it parks
#         a needs-operator proof, mc_bm_operator_applied asks the production
#         ledger (mmh_decide): `applied` (a person applied the file by hand)
#         releases the row, with no park and no alert.
#   n/a, missing, stale -> nothing. A `retry` proof (a stop before any dispatch:
#         checks not green yet, the quiet window, the dispatch lock, a moved
#         head) reads as stale, so it parks nothing and the PR takes the
#         ordinary path (mmh_decide / HELD_MIGRATION), with no human step. A PR with no stage run (a person's PR, a PR
#         older than this change) is never stuck by this fragment.
# No row (or before_merge 0): no read at all, 0 REST calls.
# shellcheck source=bin/lib/hotfix-migrate-knobs.sh
[ -r "$H/bin/lib/hotfix-migrate-knobs.sh" ] && . "$H/bin/lib/hotfix-migrate-knobs.sh"

mc_bm_proof() {
  local hp
  MC_BM_APPLIED=0
  [ "${STATE:-}" = READY ] || return 0
  [ -n "${P:-}" ] && [ -n "${SLUG:-}" ] && [ -n "${NUM:-}" ] || return 0
  command -v mc_hotfix_proof >/dev/null 2>&1 || return 0
  command -v hmk_before_merge >/dev/null 2>&1 || return 0
  hmk_before_merge "$P" || return 0
  # A hotfix PR keeps the proof gate in bin/merge-conductor.sh. The literal
  # label match is the fallback for a tree without bin/lib/hotfix-lib.sh, the
  # same fallback mc_hotfix_proof has.
  if command -v hotfix_pr_is >/dev/null 2>&1; then
    hotfix_pr_is "${RAWLBL:-}" "${REC:-}" && return 0
  else
    case ",${RAWLBL:-}," in *,hotfix,*) return 0 ;; esac
  fi
  hp=$(MC_HFP_ANY_LABEL=1 mc_hotfix_proof "$SLUG" "$NUM" "${RAWLBL:-}" "${REC:-}" "$P")
  case "$hp" in
    ok)   MC_BM_APPLIED=1 ;;
    hold) # A needs-operator hold ends when a person applies the file: the
          # production ledger then lists it, and the PR goes on (BH-9817).
          if command -v mc_bm_operator_applied >/dev/null 2>&1 && mc_bm_operator_applied; then
            command -v mc_log >/dev/null 2>&1 && mc_log "${KEY:-$SLUG#$NUM} before-merge migration proof: needs-operator, but production holds $MMH_NAMES; released"
            return 0
          fi
          STATE=BLOCKED_HUMAN
          WHY="before-merge-migration-hold: the apply workflow refused or held; a human reads the proof comment"
          command -v mc_log >/dev/null 2>&1 && mc_log "${KEY:-$SLUG#$NUM} before-merge migration proof: hold, parked BLOCKED_HUMAN"
          command -v mc_bm_held_alert >/dev/null 2>&1 && mc_bm_held_alert ;;
  esac
  return 0
}
