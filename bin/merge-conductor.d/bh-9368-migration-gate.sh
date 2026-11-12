# shellcheck shell=bash
# bin/merge-conductor.d/bh-9368-migration-gate.sh - A MIGRATION-GATE RED IS
# WAIT_MIGRATION, NOT RED_TWICE (BH-9368). Sourced by bin/merge-conductor.sh
# (the BH-7453 fragment block).
#
# Incident (project-6 #3728, 2026-11-09): the only red REQUIRED check was
# `gate` (migration-ledger.yml), red because the PR adds a before-merge
# prisma/sql/*.sql that production did not hold. No branch change turns that
# green, but the conductor re-ran it, struck it and parked it RED_TWICE, and
# bin/blocked-resolver.sh spent its whole ladder on it. Five approved PRs sat
# like that until a person applied the SQL.
#
# mc_miggate_apply — pr_worker calls it right after mc_cireq_apply, with CI,
#   P, SLUG, NUM, KEY and HEAD in scope. It sets MC_CI_MIGRATION_GATE (the
#   failing gate names, comma list) and MC_CI_MIGRATION_SQL (the SQL names the
#   PR adds) ONLY when CI is red, the settings row
#   mc.migration_gate_checks.<project> names checks (space separated), the
#   required-set rule ran on this head (MC_CI_REQ_SHA = HEAD and
#   MC_CI_REQ_APPLIED = 1; one mc_ci_state call on a memo hit), and EVERY
#   failing required check (MC_CI_RED_CHECKS) is in that row, by exact name.
#   Anything else leaves both empty and the red takes its ladder as before.
#   The driver skips the red ladder (no rerun, no strike) while the gate is
#   set, and mc_classify answers WAIT_MIGRATION.
#
# mc_miggate_arm — the driver's WAIT_MIGRATION arm. Three things:
#   1. One alert per (PR, head) naming the SQL files and the apply command
#      (`miggate <key> <head>`, the mark before the send).
#   2. When the settings row mc.migration_apply_workflow.<project> names a
#      workflow file, one dispatch of it per SQL file, once per (PR, SQL
#      fingerprint): sha256 over the sorted `name<TAB>sha256` lines of the head
#      files (`migdispatch <key> <fp12>`, the mark before the send). A new head
#      with the same SQL bytes sends nothing. `migdispatchhead <key> <head>`
#      keeps the contents reads to one set per head.
#   3. mc_ledger_gate_rerun (bh-9368-ledger-gate-rerun.sh): when the ledger
#      holds every SQL file at the head checksum, the gate is re-run once.
#   Observe mode or the kill switch: WOULD lines, no mark, nothing sent.
#   WAIT_MIGRATION is re-derived every tick; the tick after the gate is green
#   takes the normal path (and bh-9368-park-ci-recheck.sh releases a stale
#   memo of the red).
#
# Settings rows (DB-driven; no row = the behaviour before BH-9368):
#   mc.migration_gate_checks.<project>     seed: project-6-os = gate
#   mc.migration_apply_workflow.<project>  ^[A-Za-z0-9._-]+\.ya?ml$; no seed row
#                                          (an automatic prod apply is opt-in)
# shellcheck source=bin/lib/migration-hold.sh
[ -r "$H/bin/lib/migration-hold.sh" ] && ! command -v mmh_decide >/dev/null 2>&1 && . "$H/bin/lib/migration-hold.sh"

# _mc_miggate_row <key> — a settings row, trimmed to single spaces. rc 1 = no
#   row, an empty row, or no reader.
_mc_miggate_row() {
  local v
  if ! command -v setting_get >/dev/null 2>&1; then
    command -v _mmh_ensure_client >/dev/null 2>&1 && _mmh_ensure_client || return 1
  fi
  v=$(setting_get "$1" 2>/dev/null) || return 1
  v=$(printf '%s' "$v" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

mc_miggate_apply() {
  local knob c sql
  local -a reds
  MC_CI_MIGRATION_GATE=""; MC_CI_MIGRATION_SQL=""
  [ "${CI:-}" = red ] || return 0
  [ -n "${P:-}" ] && [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] && [ -n "${SLUG:-}" ] || return 0
  knob=$(_mc_miggate_row "mc.migration_gate_checks.$P") || return 0
  # A memo hit: the globals are another head's. One read sets them for this one.
  if [ "${MC_CI_REQ_SHA:-}" != "$HEAD" ] && command -v mc_ci_state >/dev/null 2>&1; then
    mc_ci_state "$SLUG" "$HEAD" >/dev/null 2>&1
  fi
  # An unread required set never hides a red.
  [ "${MC_CI_REQ_SHA:-}" = "$HEAD" ] && [ "${MC_CI_REQ_APPLIED:-0}" = 1 ] && [ -n "${MC_CI_RED_CHECKS:-}" ] || return 0
  IFS=, read -r -a reds <<<"$MC_CI_RED_CHECKS"
  for c in "${reds[@]}"; do
    [ -n "$c" ] || continue
    case " $knob " in *" $c "*) ;; *) return 0 ;; esac
  done
  sql=""
  if command -v mmh_decide >/dev/null 2>&1; then
    mmh_decide "$P" "$SLUG" "${NUM:-}" "$KEY" "$HEAD"
    case "${MMH_VERDICT:-}" in off|none|'') ;; *) sql="$MMH_NAMES" ;; esac
  fi
  MC_CI_MIGRATION_GATE="$MC_CI_RED_CHECKS"
  MC_CI_MIGRATION_SQL="${sql:--}"
  return 0
}

# _mc_miggate_files — the SQL files' base names (from MMH_PATHS), space list.
_mc_miggate_files() {
  local n p out=""
  while IFS=$'\t' read -r n p; do
    [ -n "$p" ] && out="${out:+$out }${p##*/}"
  done <<<"${MMH_PATHS:-}"
  printf '%s' "$out"
}

# _mc_miggate_dispatch <workflow> — step 2 of mc_miggate_arm.
_mc_miggate_dispatch() {
  local wf="$1" h8="${HEAD:0:8}" t fp p base rc ok=0 bad=0 ref="${PBASE:-main}"
  mc_attempt_has "migdispatchhead $KEY $HEAD" 2>/dev/null && return 0
  command -v mmh_paths >/dev/null 2>&1 && command -v mmh_head_sums >/dev/null 2>&1 || return 0
  if [ -z "${MMH_PATHS:-}" ] && ! mmh_paths "$P" "$SLUG" "$NUM"; then
    mc_log "$KEY migration apply dispatch on $h8: the PR's files could not be read; the next tick asks again"; return 0
  fi
  [ -n "${MMH_PATHS:-}" ] || { mc_log "$KEY migration apply dispatch on $h8: no SQL file matches the globs; nothing to dispatch"; return 0; }
  t=$(mktemp "${TMPDIR:-/tmp}/mc-miggate.XXXXXX") || return 0
  # shellcheck disable=SC2046 # one path per line, no spaces (mmh_glob_ok)
  if ! mmh_head_sums "$SLUG" "$HEAD" $(cut -f2 <<<"$MMH_PATHS") > "$t"; then
    rm -f "$t"; mc_log "$KEY migration apply dispatch on $h8: the SQL fingerprint is unreadable (${MMH_SUMS_WHY:-no sum}); no dispatch this tick"; return 0
  fi
  fp=$(LC_ALL=C sort "$t" | sha256sum | cut -c1-12); rm -f "$t"
  if [ "${ACTIONS:-0}" != 1 ] || [ "${KILL:-0}" = 1 ]; then
    mc_log "$KEY WOULD dispatch $wf for $(_mc_miggate_files) on $h8 (SQL fingerprint $fp; observe mode: nothing sent)"; return 0
  fi
  mc_attempt_put "migdispatchhead $KEY $HEAD"
  mc_attempt_has "migdispatch $KEY $fp" 2>/dev/null && return 0
  # The mark before the send: a crash or a refusal costs one dispatch per SQL
  # fingerprint, never a storm. A changed SQL is a new fingerprint.
  mc_attempt_put "migdispatch $KEY $fp"
  while IFS=$'\t' read -r _ p; do
    [ -n "$p" ] || continue
    base="${p##*/}"; rc=0
    gh_rest POST "repos/$SLUG/actions/workflows/$wf/dispatches" -f "ref=$ref" -f "inputs[file]=$base" -f "inputs[ref]=${BR:-}" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then ok=$((ok + 1))
    else bad=$((bad + 1)); mc_log "$KEY migration apply dispatch of $wf for $base on $h8 failed (HTTP ${GH_REST_STATUS:-000}); not retried for this SQL (fingerprint $fp)"; fi
  done <<<"$MMH_PATHS"
  [ "$ok" -gt 0 ] && mc_log "$KEY MIGRATION_DISPATCHED $wf for $ok file(s) on $h8 (ref $ref, branch ${BR:-?}, SQL fingerprint $fp)"
  return 0
}

mc_miggate_arm() {
  local h8="${HEAD:0:8}" sql="${MC_CI_MIGRATION_SQL:--}" gate="${MC_CI_MIGRATION_GATE//,/, }" wf="" files cmd
  [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] || return 0
  wf=$(_mc_miggate_row "mc.migration_apply_workflow.${P:-}") || wf=""
  if [ -n "$wf" ] && ! [[ $wf =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]]; then
    mc_log "$KEY mc.migration_apply_workflow.${P:-} '$wf' is not a workflow file name; alert only"; wf=""
  fi
  # The paths come with this tick's mmh_decide (empty on a cache hit).
  files=$(_mc_miggate_files); [ -n "$files" ] || files="$sql"
  if [ -n "$wf" ]; then
    cmd="apply step: gh workflow run $wf --ref ${PBASE:-main} -f file=<file> -f ref=${BR:-<branch>} for $files (the conductor dispatches it once per SQL fingerprint)"
  else
    cmd="apply step: apply them to production (bin/data-lane-apply.sh or the app's /api/internal/migrations/apply); the conductor re-runs the gate once the ledger holds them"
  fi
  # 1. One alert per (PR, head).
  if [ "${ACTIONS:-0}" != 1 ] || [ "${KILL:-0}" = 1 ]; then
    mc_log "$KEY WOULD alert WAIT_MIGRATION on $h8: $gate red; PR adds $sql (observe mode: nothing sent)"
  elif ! mc_attempt_has "miggate $KEY $HEAD" 2>/dev/null; then
    mc_attempt_put "miggate $KEY $HEAD"
    mc_log "$KEY WAIT_MIGRATION on $h8: $gate red only because production does not hold $sql yet — no rerun, no strike, no resolver park; $cmd: ${URL:-}"
    mc_alert "$KEY" WAIT_MIGRATION "$gate red on $h8 because the PR adds $sql, which production has not applied; $cmd"
  fi
  # 2. The apply workflow, once per (PR, SQL fingerprint).
  [ -n "$wf" ] && _mc_miggate_dispatch "$wf"
  # 3. The gate re-run, once per (PR, head), when the ledger holds the SQL.
  command -v mc_ledger_gate_rerun >/dev/null 2>&1 && mc_ledger_gate_rerun
  return 0
}
