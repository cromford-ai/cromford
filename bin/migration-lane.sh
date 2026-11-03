#!/bin/bash
# gh-identity: app-token
# bin/migration-lane.sh [<project>] — the hub migration lane (BH-8704).
#
# Lands migration PRs in batches: for each project whose settings row
# mc_migration_hold.apply_lane.<project> is `migration` (the same row that
# makes the merge conductor hold those PRs for this lane) and whose
# mc_migration_hold.globs.<project> row is valid, one tick takes the project
# lease, picks up to BATCH_MAX ready migration PRs, builds ONE batch branch
# from main plus each PR, runs ONE CI on a draft batch PR, applies the
# migrations through the project's own ledger CLI from a main tree, proves each
# file through the app's migrations/status, and merges each proved member at
# its staged head. The logic is bin/lib/migration-lane.sh; the contract is
# docs/notes/2026-10-28-BH-8704-migration-lane.md.
#
# No argument: pl_dispatch (bin/lib/project-lanes.sh) starts one detached
# `bin/migration-lane.sh <project>` per fleet project, all at once. One
# argument: that project only, and only when it is enabled. Cron:
# cron/lanes/414-migration-lane.cron. Off: flags/lane-off-migration (and
# flags/lane-off-migration-lane for the dispatcher), the flag
# automerge-disabled (fleet), or automerge-disabled-<project> / paused-<project>
# (one project), each read through flag_active (the pause_flags row, then the file).
# Log: logs/migration-lane.log.
set -uo pipefail
H="${HARNESS:-/root/harness}"
HARNESS="$H"; export HARNESS
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
mkdir -p "$H/logs" "$H/locks" "$H/state/migration-lane"

# >>> lane gate (BH-1165). Two registry rows, the fly-pool-tick / fly-pool
# shape: the no-argument dispatcher is lane migration-lane
# (catalog/lanes.d/migration-lane.json, flags/lane-off-migration-lane), and
# each project run is lane migration (catalog/lanes.d/migration.json,
# flags/lane-off-migration, the knobs). The dispatcher also stops when the
# runs are off, so a switched-off lane forks nothing.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && [ "$#" -eq 0 ] && lane_gate_or_exit migration-lane
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit migration
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 1
# ml_flag_on <name> — the pause_flags row reconciled with flags/<name>
# (flag_active), or the file alone without a jobs client: the read
# bin/batch-resolve.sh gives the same kill switches.
ml_flag_on() { if command -v flag_active >/dev/null 2>&1; then flag_active "$1"; else [ -e "$H/flags/$1" ]; fi; }
# The fleet kill switch is read again here: an unreadable registry fails the
# gate open, and this lane merges.
ml_flag_on automerge-disabled && exit 0
# shellcheck source=bin/lib/project-lanes.sh
. "$H/bin/lib/project-lanes.sh" || exit 1
# No argument: one detached run per fleet project through the per-project
# runner (BH-5913), each with locks/migration-<project>.lock held. A project
# that is not enabled exits at once.
if [ "$#" -eq 0 ]; then
  pl_dispatch migration 0 "$H/bin/migration-lane.sh"
  exit 0
fi

# The conductor lib brings gh-rest.sh, gh-app-auth.sh, gh-pr-merge.sh,
# block-gate.sh, verdicts.sh, mc_ci_state and mc_git_auth.
# shellcheck source=bin/lib/merge-conductor-lib.sh
. "$H/bin/lib/merge-conductor-lib.sh" || exit 1
# shellcheck source=bin/lib/gh-app-auth.sh
command -v gh_auth_for >/dev/null 2>&1 || { [ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"; }
# shellcheck source=bin/lib/gh-rest-list.sh
. "$H/bin/lib/gh-rest-list.sh" || exit 1
# shellcheck source=bin/lib/migration-hold.sh
. "$H/bin/lib/migration-hold.sh" || exit 1
# shellcheck source=bin/lib/project-lease.sh
. "$H/bin/lib/project-lease.sh" || exit 1
# shellcheck source=bin/lib/hold-push.sh
. "$H/bin/lib/hold-push.sh" || exit 1
# shellcheck source=bin/lib/migration-lane.sh
. "$H/bin/lib/migration-lane.sh" || exit 1
MC_REPOS="${MC_REPOS:-/root/repos}"

# ml_env_val <file> <NAME> — the last NAME= value in an env file, outer quotes
# stripped. Read, never sourced: the file holds other lanes' settings.
ml_env_val() {
  local v
  v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1)
  case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
  printf '%s' "$v"
}

# ml_enabled <project> — rc 0 when the apply_lane row is `migration` and the
# globs row is valid.
ml_enabled() {
  local v
  v=$(setting_get "mc_migration_hold.apply_lane.$1" 2>/dev/null) || return 1
  [ "$(printf '%s' "$v" | tr -d '[:space:]')" = migration ] || return 1
  mmh_globs "$1" >/dev/null 2>&1
}

run_project() {
  P="$1"
  local f missing="" envf rc=0 v
  for f in "automerge-disabled-$P" "paused-$P"; do
    ml_flag_on "$f" && { ml_log "skipped: flags/$f"; return 0; }
  done
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply migration "$P"
  envf="$HENV/$P.env"
  for v in MIGRATION_LANE_APPLY_CMD MIGRATION_LANE_SETUP_CMD MIGRATION_LANE_DATABASE_URL DATA_LANE_APP_BASE MIGRATION_TOKEN; do
    printf -v "$v" '%s' "$(ml_env_val "$envf" "$v")"
  done
  for v in MIGRATION_LANE_APPLY_CMD MIGRATION_LANE_DATABASE_URL DATA_LANE_APP_BASE MIGRATION_TOKEN; do
    [ -n "${!v}" ] || missing="${missing:+$missing }$v"
  done
  if [ -n "$missing" ]; then
    ml_log "not configured: env/$P.env has no $missing; skipped"
    mlx_alert warn "migration-lane-$P-config" "$P is switched to the migration lane but env/$P.env has no $missing; the lane skips it"
    return 0
  fi
  SLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null) || SLUG=""
  [ -n "$SLUG" ] || { ml_log "no repo slug in fleet.conf; skipped"; return 0; }
  [ -d "$MC_REPOS/$P/.git" ] || { ml_log "no checkout at $MC_REPOS/$P; skipped"; return 0; }
  # The runner already holds locks/migration-<project>.lock; a run by hand takes it.
  if [ "${PL_LANE:-}" != migration ] || [ "${PL_PROJECT:-}" != "$P" ] || [ -z "${PL_LOCK_FD:-}" ]; then
    pl_lock_take migration "$P" 9 || { ml_log "a tick is already running on this box; skipped"; return 0; }
  fi
  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$SLUG" >/dev/null 2>&1 || true; }
  ML_REMOTE=""
  mlx_git_remote "$SLUG" || { ml_log "no token can read $SLUG; skipped"; return 0; }
  # The lane works in its OWN bare clone, never in the shared checkout
  # $MC_REPOS/<p> that other lanes use: its origin URL, worktrees and fetched
  # refs stay under state/migration-lane/<p>/repo. The first tick clones it
  # locally from the shared checkout (hard links, no network).
  REPO="$H/state/migration-lane/$P/repo"
  if [ ! -d "$REPO/objects" ]; then
    mkdir -p "$H/state/migration-lane/$P"
    git clone -q --bare "$MC_REPOS/$P" "$REPO" >/dev/null 2>&1 || { ml_log "the lane clone could not be made from $MC_REPOS/$P; skipped"; return 0; }
  fi
  git -C "$REPO" remote set-url origin "$ML_REMOTE" >/dev/null 2>&1 || { ml_log "the lane clone has no origin; skipped"; return 0; }
  ML_HOLDER="$(hostname 2>/dev/null | tr -c "A-Za-z0-9._\n-" _ | cut -c1-40)-$BASHPID"
  ML_FENCE=$(PJL_TTL_S="${LEASE_TTL_S:-900}" pjl_acquire migration "$P" "$ML_HOLDER") || rc=$?
  case "$rc" in
    0) ;;
    3) ml_log "lease held by another tick — skipped"; return 0 ;;
    *) ml_log "lease unreadable — skipped (fail closed)"; return 0 ;;
  esac
  trap 'pjl_release migration "$P" "$ML_HOLDER" "$ML_FENCE" >/dev/null 2>&1 || ml_log "lease release not answered; it expires at its TTL"' EXIT
  ml_tick
}

pl_name_ok "$1" || { echo "migration-lane: bad project name '$1'" >&2; exit 2; }
ml_enabled "$1" || exit 0
run_project "$1"
exit 0
