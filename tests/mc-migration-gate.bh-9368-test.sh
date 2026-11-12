#!/bin/bash
# tests/mc-migration-gate.bh-9368-test.sh — BH-9368: a PR whose only failing
# REQUIRED check is a migration-ledger gate is WAIT_MIGRATION, not RED_TWICE.
#
# Incident (project-6 #3728, bh-hub-2, 2026-11-09): `gate` (migration-ledger.yml)
# was the only red required check, because the PR adds a before-merge
# prisma/sql/*.sql that production did not hold yet. The conductor re-ran it,
# struck it, parked it RED_TWICE, and bin/blocked-resolver.sh spent its ladder
# on a red no branch change can turn green.
#
# Part A (unit):
#   MG3b-k  mc_miggate_apply's decision table, seams stubbed
#   MG9     MC_STATES, SW_CONDUCTOR_STATES and conductor-held.js agree; mc_ttl
#   MG10    br_from_conductor (bin/blocked-resolver.sh) offers RED_TWICE, never WAIT_MIGRATION
# Part B drives the WHOLE bin/merge-conductor.sh (tests/lib/mc-gate-tick.sh):
#   MG1  gate red only, knob gate: WAIT_MIGRATION, 0 reruns, no strike, no hand-off
#   MG2  knob empty: RED_TWICE, as before
#   MG3  gate and ci red, knob gate: RED_TWICE (a real red is not hidden)
#   MG4  3 ticks on one head: 1 alert naming the SQL and the apply command; observe: 0 alerts, a WOULD line
#   MG5  workflow knob: 1 dispatch per (PR, SQL fingerprint); a new head, same SQL: none; changed SQL: 1 more
#   MG6  the dispatch answers 422: logged once, not retried
#   MG7  the ledger holds the SQL at the head checksum: 1 gate re-run per (PR, head)
#   MG8  gate turns green: the row leaves WAIT_MIGRATION and is READY/QUEUED
#   MG8b inside the park recheck window the memo's red stands (no release)
#   V1   every curl went to a .test host
# 0 network: fake gh and curl first on PATH.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-migration-gate.bh-9368-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-migration-gate.bh-9368: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
GATE_FRAG="$DIR/bin/merge-conductor.d/bh-9368-migration-gate.sh"
H1=$(printf 'a%.0s' $(seq 40)); HX=$(printf 'f%.0s' $(seq 40))

# ============================================================================
# Part A — unit.
# ============================================================================
# MG3b-k: mc_miggate_apply, with setting_get, mmh_decide and mc_ci_state stubbed.
(
  F=0; no() { F=$((F+1)); echo "FAIL: mc-migration-gate.bh-9368: $1"; }
  [ -r "$GATE_FRAG" ] || { no "MG3b the fragment $GATE_FRAG is missing"; exit 1; }
  FXD="$T/ua"; mkdir -p "$FXD/set"
  H="$DIR"
  mc_log() { printf '%s\n' "$*" >> "$FXD/log"; }
  # shellcheck source=bin/merge-conductor.d/bh-9368-migration-gate.sh
  . "$GATE_FRAG" || exit 90
  setting_get() { [ -e "$FXD/set/.down" ] && return 1; [ -f "$FXD/set/$1" ] || return 2; cat "$FXD/set/$1"; }
  mmh_decide() { MMH_VERDICT=missing; MMH_NAMES="0001_a"; MMH_DETAIL=x; MMH_SRC=probed; }
  mc_ci_state() { echo x >> "$FXD/cistate"; MC_CI_REQ_SHA="$2"; MC_CI_REQ_APPLIED=1; MC_CI_RED_CHECKS=gate; echo red; }
  ap() { # ap <label> <want set|empty> <knob or -> <red checks> [ci] [applied] [sha]
    rm -f "$FXD/set/mc.migration_gate_checks.p1"
    [ "$3" = - ] || printf '%s' "$3" > "$FXD/set/mc.migration_gate_checks.p1"
    CI="${5:-red}"; P=p1; SLUG=O/r; NUM=1; KEY="O/r#1"; HEAD="$H1"
    MC_CI_RED_CHECKS="$4"; MC_CI_REQ_APPLIED="${6:-1}"; MC_CI_REQ_SHA="${7:-$H1}"
    MC_CI_MIGRATION_GATE=stale; MC_CI_MIGRATION_SQL=stale
    mc_miggate_apply
    if [ "$2" = set ]; then
      [ -n "$MC_CI_MIGRATION_GATE" ] && [ "$MC_CI_MIGRATION_GATE" != stale ] || no "$1: want the gate set (got '$MC_CI_MIGRATION_GATE')"
    else
      [ -z "$MC_CI_MIGRATION_GATE" ] && [ -z "$MC_CI_MIGRATION_SQL" ] || no "$1: want no gate (got '$MC_CI_MIGRATION_GATE' / '$MC_CI_MIGRATION_SQL')"
    fi
  }
  ap "MG3b {gate}, knob gate" set gate gate
  [ "$MC_CI_MIGRATION_GATE" = gate ] && [ "$MC_CI_MIGRATION_SQL" = 0001_a ] || no "MG3b the gate names and the SQL names ($MC_CI_MIGRATION_GATE / $MC_CI_MIGRATION_SQL)"
  ap "MG3c {gate}, knob 'gate other'" set 'gate other' gate
  ap "MG3d {gate, ci}, knob gate" empty gate gate,ci
  ap "MG3e {ci}, knob gate" empty gate ci
  ap "MG3f {gate}, no knob row" empty - gate
  ap "MG3f2 {gate}, an empty knob row" empty '  ' gate
  ap "MG3g {gate}, the required set unread" empty gate gate red 0
  ap "MG3h {gate}, knob gate2" empty gate2 gate
  ap "MG3h2 {gate}, knob Gate" empty Gate gate
  ap "MG3i CI pending" empty gate gate pending
  ap "MG3i2 CI none" empty gate gate none
  ap "MG3j no red required check named" empty gate ''
  : > "$FXD/set/.down"; ap "MG3k the knob row unreadable" empty gate gate; rm -f "$FXD/set/.down"
  rm -f "$FXD/cistate"
  ap "MG3l a memo hit (globals for another head): one mc_ci_state, then set" set gate '' red 0 "$HX"
  [ "$(grep -c . "$FXD/cistate" 2>/dev/null)" = 1 ] || no "MG3l exactly one mc_ci_state call on a memo hit"
  echo "part A1: $F failed"; exit "$F"
)
FAIL=$((FAIL + $?))

# MG9 — the state lists agree, and mc_ttl knows the state.
grep -qw WAIT_MIGRATION <<<"$(sed -n 's/^MC_STATES="\(.*\)"/\1/p' "$DIR/bin/lib/mc/log.sh")" && ok || bad "MG9 WAIT_MIGRATION must be in MC_STATES"
grep -q ' WAIT_MIGRATION ' <<<"$(grep '^SW_CONDUCTOR_STATES=' "$DIR/bin/lib/stuck-work/classify.sh")" && ok || bad "MG9 WAIT_MIGRATION must be in SW_CONDUCTOR_STATES"
grep -q '"WAIT_MIGRATION"' "$DIR/worker/jobs/src/routes/conductor-held.js" && ok || bad "MG9 WAIT_MIGRATION must be in conductor-held.js CONDUCTOR_STATES"
TTL=$(bash -c '. "$1/bin/lib/mc/classify.sh" >/dev/null 2>&1; mc_ttl WAIT_MIGRATION' _ "$DIR" 2>/dev/null)
[ "$TTL" = 86400 ] && ok || bad "MG9 mc_ttl WAIT_MIGRATION = 86400 (got '$TTL')"
for k in MC_TTL_WAIT_MIGRATION MC_BUDGET_WAIT_MIGRATION; do
  [ -r "$DIR/catalog/lanes.d/merge-conductor.knobs.d/$k.json" ] && ok || bad "MG9 the knob file $k.json"
done
[ "$(jq -r .default "$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_TTL_WAIT_MIGRATION.json" 2>/dev/null)" = 86400 ] && ok || bad "MG9 MC_TTL_WAIT_MIGRATION default 86400"

# MG10 — resolver discovery: br_from_conductor, extracted from bin/blocked-resolver.sh,
# over a pr-state file with one WAIT_MIGRATION and one RED_TWICE row. A row that
# passes the state filter reaches br_key_in_only, which records the key.
awk '/^br_from_conductor\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$DIR/bin/blocked-resolver.sh" > "$T/bfc.sh"
OFFERED=$(
  MC_ROWS="$T/rows.tsv"
  printf 'O/r#1\tWAIT_MIGRATION\t1700000000\t%s\t%s\tAPPROVE\tmigration-gate: gate red; PR adds 0001_a\thttps://github.com/O/r/pull/1\n' "$H1" "$H1" > "$MC_ROWS"
  printf 'O/r#2\tRED_TWICE\t1700000000\t%s\t%s\tAPPROVE\tred-twice: still red\thttps://github.com/O/r/pull/2\n' "$H1" "$H1" >> "$MC_ROWS"
  mc_ttl() { echo 7200; }
  br_key_in_only() { echo "$1" >> "$T/offered"; return 1; }
  # shellcheck source=/dev/null
  . "$T/bfc.sh"
  br_from_conductor >/dev/null 2>&1
  sort -u "$T/offered" 2>/dev/null | paste -sd' '
)
[ -s "$T/bfc.sh" ] && [ "$OFFERED" = "O/r#2" ] && ok || bad "MG10 the resolver offers only the RED_TWICE row (offered: '$OFFERED')"

# ============================================================================
# Part B — the whole tick.
# ============================================================================
# shellcheck source=tests/lib/mc-gate-tick.sh
. "$(dirname "$0")/lib/mc-gate-tick.sh" || exit 1
mgt_setup bin/merge-conductor.d/bh-7785-migration-hold.sh bin/merge-conductor.d/bh-9368-migration-gate.sh \
  bin/merge-conductor.d/bh-9368-ledger-gate-rerun.sh bin/merge-conductor.d/bh-9368-park-ci-recheck.sh || exit 1
K="$MGT_SLUG#31"
st() { mgt_row | cut -d'|' -f1; }
knob() { echo "${1:-gate}" > "$BX/set/mc.migration_gate_checks.mkey"; }
REASON="migration-gate: gate red; PR adds $MGT_SQLN"

# MG1 — gate red only, knob gate.
mgt_fresh; mgt_sql; mgt_gate_red; knob; mgt_tick
[ "$(mgt_row)" = "WAIT_MIGRATION|$REASON" ] && ok || bad "MG1 WAIT_MIGRATION with the reason (row '$(mgt_row)'; log: $(mgt_log))"
[ "$(mgt_n "$BX/reruns.txt")" = 0 ] && ok || bad "MG1 0 rerun calls ($(cat "$BX/reruns.txt" 2>/dev/null))"
! grep -q "^red $K " "$ATT" 2>/dev/null && ! grep -q "^cirerun $K " "$ATT" 2>/dev/null && ok || bad "MG1 no strike, no rerun mark ($(grep -E '^(red|cirerun) ' "$ATT"))"
[ ! -e "$CH/state/merge-conductor/handoff/example-org_mkey-os_31" ] && ! grep -q 'handed to bin/blocked-resolver.sh' "$CLOG" && ok \
  || bad "MG1 no hand-off to the resolver ($(mgt_log 3))"
# MG4 — 3 ticks on one head: one alert.
mgt_tick; mgt_tick
[ "$(st)" = WAIT_MIGRATION ] && [ "$(mgt_alerts WAIT_MIGRATION)" = 1 ] && ok || bad "MG4 3 ticks: still WAIT_MIGRATION, 1 alert (state $(st), alerts $(mgt_alerts WAIT_MIGRATION): $(cat "$CH/logs/ALERTS.log"))"
grep 'WAIT_MIGRATION' "$CH/logs/ALERTS.log" | grep -q "$MGT_SQLN" && grep 'WAIT_MIGRATION' "$CH/logs/ALERTS.log" | grep -q 'migrations/apply' && ok \
  || bad "MG4 the alert names the SQL file and the apply command ($(grep WAIT_MIGRATION "$CH/logs/ALERTS.log"))"
[ "$(mgt_n "$BX/reruns.txt")" = 0 ] && [ "$(mgt_n "$BX/model-calls.txt")" = 0 ] && ok || bad "MG4 3 ticks: 0 reruns, 0 model calls"
# MG4b — observe mode: 0 alerts, a WOULD line, no mark.
mgt_fresh; mgt_sql; mgt_gate_red; knob; rm -f "$CH/flags/merge-conductor-actions"; mgt_tick
[ "$(st)" = WAIT_MIGRATION ] && [ "$(mgt_alerts WAIT_MIGRATION)" = 0 ] && grep -q "$K WOULD alert WAIT_MIGRATION" "$CLOG" && ! grep -q "^miggate " "$ATT" 2>/dev/null && ok \
  || bad "MG4b observe: WAIT_MIGRATION, 0 alerts, a WOULD line, no mark (state $(st); log: $(mgt_log 3))"
touch "$CH/flags/merge-conductor-actions"

# MG2 — the same fixture, knob empty: RED_TWICE as before.
mgt_fresh; mgt_sql; mgt_gate_red; mgt_tick
[ "$(st)" = RED_TWICE ] && [ "$(mgt_n "$BX/reruns.txt")" = 1 ] && ok || bad "MG2 no knob: RED_TWICE after the rerun rung (row '$(mgt_row)', reruns $(mgt_n "$BX/reruns.txt"))"
# MG3 — gate and ci red, knob gate: RED_TWICE.
mgt_fresh; mgt_sql; mgt_gate_ci_red; knob; mgt_tick
[ "$(st)" = RED_TWICE ] && [ "$(mgt_alerts WAIT_MIGRATION)" = 0 ] && ok || bad "MG3 gate + ci red: RED_TWICE, no WAIT_MIGRATION alert (row '$(mgt_row)')"

# MG5 — the workflow knob: one dispatch per (PR, SQL fingerprint).
mgt_fresh; mgt_sql; mgt_gate_red; knob; echo migrate-branch.yml > "$BX/set/mc.migration_apply_workflow.mkey"
mgt_tick; mgt_tick; mgt_tick
[ "$(mgt_n "$BX/dispatches.txt")" = 1 ] && ok || bad "MG5 3 ticks: 1 dispatch ($(cat "$BX/dispatches.txt" 2>/dev/null); log: $(mgt_log))"
D=$(cat "$BX/dispatches.txt" 2>/dev/null)
[[ $D == *"actions/workflows/migrate-branch.yml/dispatches"* ]] && [[ $D == *"ref=main"* ]] && [[ $D == *"inputs[file]=$MGT_SQLN.sql"* ]] && [[ $D == *"inputs[ref]=ticket/TK-31"* ]] && ok \
  || bad "MG5 the dispatch names the workflow, ref main, the file and the PR branch ($D)"
grep 'WAIT_MIGRATION' "$CH/logs/ALERTS.log" | grep -q 'gh workflow run migrate-branch.yml' && ok || bad "MG5 the alert names the workflow command ($(grep WAIT_MIGRATION "$CH/logs/ALERTS.log"))"
mgt_head "$MGT_H2"; mgt_gate_red; mgt_tick; mgt_tick
[ "$(mgt_n "$BX/dispatches.txt")" = 1 ] && [ "$(st)" = WAIT_MIGRATION ] && [ "$(mgt_alerts WAIT_MIGRATION)" = 2 ] && ok \
  || bad "MG5b a new head with the same SQL: no new dispatch, one new alert (dispatches $(mgt_n "$BX/dispatches.txt"), state $(st), alerts $(mgt_alerts WAIT_MIGRATION))"
mgt_head "$MGT_H3"; mgt_gate_red; printf 'CREATE TABLE own_google_send_config (id int, v text);\n' > "$BX/content-${MGT_H3:0:8}"; mgt_tick; mgt_tick
[ "$(mgt_n "$BX/dispatches.txt")" = 2 ] && ok || bad "MG5c a changed SQL dispatches again (dispatches $(mgt_n "$BX/dispatches.txt"))"

# MG6 — the dispatch answers 422: one failure line, no retry.
mgt_fresh; mgt_sql; mgt_gate_red; knob; echo migrate-branch.yml > "$BX/set/mc.migration_apply_workflow.mkey"; echo 422 > "$BX/dispatch-code"
mgt_tick; mgt_tick; mgt_tick
[ "$(mgt_n "$BX/dispatches.txt")" = 1 ] && [ "$(grep -c "$K migration apply dispatch .*failed (HTTP 422)" "$CLOG")" = 1 ] && ok \
  || bad "MG6 a 422 dispatch: sent once, one failure line (dispatches $(mgt_n "$BX/dispatches.txt"); log: $(mgt_log))"

# MG7 — the ledger holds the SQL at the head checksum: one gate re-run per (PR, head).
mgt_fresh; mgt_sql; mgt_gate_red; knob; mgt_ledger "$(mgt_sum)"
mgt_tick; mgt_tick; mgt_tick
[ "$(grep -c 'run rerun 103 --failed' "$BX/reruns.txt" 2>/dev/null)" = 1 ] && [ "$(mgt_n "$BX/reruns.txt")" = 1 ] && ok \
  || bad "MG7 applied at the head checksum: 1 gate re-run over 3 ticks ($(cat "$BX/reruns.txt" 2>/dev/null); log: $(mgt_log))"

# MG8 — the gate turns green: the next tick leaves WAIT_MIGRATION.
mgt_fresh; mgt_sql; mgt_gate_red; knob; mgt_tick; mgt_tick
# The gate is green because production now holds the SQL: the ledger has it,
# and the migration hold's 300 s answer cache has aged out.
S0=$(st); mgt_gate_green; mgt_ledger "$(mgt_sum)"; scratch_rm "$CH/state/merge-conductor/migration-hold"
# The park recheck is throttled per (PR, head): its mark holds the epoch of the
# last read. Move that epoch 20 minutes back, past the 600 s window.
for f in "$CH"/state/merge-conductor/park-ci-recheck/*; do [ -f "$f" ] && echo "$(( $(date -u +%s) - 1200 ))" > "$f"; done
mgt_tick
S1=$(st)
[ "$S0" = WAIT_MIGRATION ] && { [ "$S1" = READY ] || [ "$S1" = QUEUED ]; } && ok \
  || bad "MG8 gate green: WAIT_MIGRATION -> READY/QUEUED ($S0 -> $S1; log: $(mgt_log))"

# MG8b — the same, inside the recheck window: the memo still says red, so the
# row does not go READY this tick (the throttle is real).
mgt_fresh; mgt_sql; mgt_gate_red; knob; mgt_tick; mgt_tick; mgt_gate_green; mgt_tick
S1=$(st)
[ "$S1" != READY ] && [ "$S1" != QUEUED ] && ! grep -q PARK_RELEASED_CI_GREEN "$CLOG" && ok \
  || bad "MG8b inside the window: no release, not READY ($S1)"

# V1 — every curl went to a .test host.
[ -z "$(mgt_offhost)" ] && ok || bad "V1 a curl left the fixture hosts: $(mgt_offhost)"

echo "mc-migration-gate.bh-9368: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
