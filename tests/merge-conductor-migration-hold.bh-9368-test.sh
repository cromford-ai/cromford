#!/bin/bash
# tests/merge-conductor-migration-hold.bh-9368-test.sh — BH-9368 (comment
# 6776463970): the migration hold reads the production ledger also when an
# apply lane is set, and it matches a file by name AND by the sha256 of the
# PR's head file.
#
# Incident (project-6 #3726, alert 61683): the project had
# mc_migration_hold.apply_lane set, so the conductor held the PR
# `HELD_MIGRATION ... left to the mac-batch lane` with no probe at all, while
# production's schema_migration already held the file at the head checksum.
#
# Part A (unit) sources bin/lib/migration-hold.sh and the BH-7785 fragment with
# their seams stubbed (the 7785 suite's fixture): setting_get from files,
# gh_rest from fixture files (pulls/<n>/files and contents/<path>?ref=<sha>),
# curl on PATH as a fake that answers migrations/status.
#   LG1  lane set, ledger row at the head checksum: applied, READY
#   LG2  lane set, ledger row at another checksum: lane, held, the detail
#   LG3  no lane: another checksum is missing (changed); no checksum is a name match
#   LG4  the head file cannot be read: lane (lane set) / unreadable (no lane)
#   LG4b lane set, the name is not in the ledger: lane, no contents read
#   S1   mmh_head_sums: name<TAB>sha256 per file; rc 1 on a failed read
# Part B (whole tick, tests/lib/mc-gate-tick.sh) on a head whose only red
# required check is `gate`, knob mc.migration_gate_checks.mkey = gate, lane set:
#   LG5  the ledger holds the file at the head checksum: 1 gate re-run over 3 ticks
#   LG6  another checksum: 0 gate re-runs
#   LG7  observe mode: 0 re-runs, one WOULD line
#   V1   every curl went to a .test host
# Run: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-migration-hold.bh-9368-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: merge-conductor-migration-hold.bh-9368: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/migration-hold.sh"
FRAG="$DIR/bin/merge-conductor.d/bh-7785-migration-hold.sh"

H1=$(printf 'a%.0s' $(seq 40))
SLUG=example-org/mgfy-os
MP=prisma/migrations/0423_x/migration.sql

# ============================================================================
# Part A — the lib and the fragment, sourced, seams stubbed.
# ============================================================================
(
  F=0; no() { F=$((F+1)); echo "FAIL: merge-conductor-migration-hold.bh-9368: $1"; }
  A="$T/a"; FXD="$A/fx"; mkdir -p "$A/h/env" "$A/h/state/merge-conductor" "$A/fakebin"
  export PATH="$A/fakebin:$PATH" HARNESS="$A/h" HENV="$A/h/env" MC_STATE_DIR="$A/h/state/merge-conductor"
  printf 'DATA_LANE_APP_BASE=http://app.test\nMIGRATION_TOKEN=tok-fixture-1\n' > "$A/h/env/mgfy.env"
  cat > "$A/fakebin/curl" <<EOF
#!/bin/bash
out=""; w=""; URL=""
while [ \$# -gt 0 ]; do case "\$1" in
  -o) out="\$2"; shift 2 ;; -w) w="\$2"; shift 2 ;; -m|-H|-X) shift 2 ;; -*) shift ;; *) URL="\$1"; shift ;;
esac; done
echo "\$URL" >> "$A/curl-all.log"
case "\$URL" in
  */api/internal/migrations/status) echo "\$URL" >> "$FXD/status.log"
    cat "$FXD/st-body" 2>/dev/null > "\$out" || echo '{"applied":[]}' > "\$out"; printf 200 ;;
  *) printf 404 ;;
esac
exit 0
EOF
  chmod +x "$A/fakebin/curl"
  setting_get() { [ -f "$FXD/set/$1" ] || return 2; cat "$FXD/set/$1"; }
  # gh_rest: the files list from FXD/files.json; contents/<path>?ref=<sha> from FXD/content.
  gh_rest() {
    local path="$2" page=1 a
    for a in "$@"; do case "$a" in page=*) page="${a#page=}" ;; esac; done
    case "$path" in
      */contents/*)
        echo "$path" >> "$FXD/contents.log"
        [ -f "$FXD/content" ] && [ ! -e "$FXD/content-404" ] || { GH_REST_STATUS=404; return 44; }
        GH_REST_STATUS=200; jq -nc --arg c "$(base64 < "$FXD/content" | tr -d '\n')" '{type:"file",encoding:"base64",content:$c}' ;;
      *) echo "$path page=$page" >> "$FXD/files.log"; GH_REST_STATUS=200
         jq -c --argjson p "$page" '.[(($p-1)*100):($p*100)]' "$FXD/files.json" ;;
    esac
  }
  mc_log() { printf '%s\n' "$*" >> "$FXD/log"; }
  mc_alert() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FXD/alerts"; }
  mc_attempt_has() { grep -qxF "$1" "$FXD/attempts" 2>/dev/null; }
  mc_attempt_put() { echo "$1" >> "$FXD/attempts"; }
  mc_hold_comment() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$FXD/trace"; }
  # shellcheck source=bin/lib/gh-rest-list.sh
  . "$DIR/bin/lib/gh-rest-list.sh" || exit 90
  H="$A/h"
  # shellcheck source=bin/lib/migration-hold.sh
  . "$LIB" || exit 91
  # shellcheck source=bin/merge-conductor.d/bh-7785-migration-hold.sh
  . "$FRAG" || exit 92
  n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
  reset() {
    scratch_rm "$FXD"; mkdir -p "$FXD/set"; scratch_rm "$MC_STATE_DIR/migration-hold"
    echo 'prisma/migrations/*/migration.sql' > "$FXD/set/mc_migration_hold.globs.mgfy"
    printf '[{"filename":"%s","status":"added"}]\n' "$MP" > "$FXD/files.json"
    printf 'CREATE TABLE x (id int);\n' > "$FXD/content"
  }
  sum() { sha256sum < "$FXD/content" | cut -c1-64; }
  ledger() { jq -nc --arg c "$1" '{applied:[{filename:"0423_x", checksum:$c}]}' > "$FXD/st-body"; }
  lane() { echo "${1:-migration}" > "$FXD/set/mc_migration_hold.apply_lane.mgfy"; }
  run() { STATE=READY; WHY="ready"; P=mgfy; NUM=31; KEY="$SLUG#31"; HEAD="$H1"; ACTIONS=1; KILL=0; mc_mig_hold; }
  OTHER=$(printf '0%.0s' $(seq 64))

  # ---- LG1 lane set, the ledger row at the head checksum ----
  reset; lane; ledger "$(sum)"; run
  [ "$MMH_VERDICT" = applied ] && [ "$STATE" = READY ] && [ "$(n "$FXD/status.log")" = 1 ] && [ "$(n "$FXD/contents.log")" = 1 ] \
    && grep -q '0423_x applied in production' "$FXD/log" && [ "$(n "$FXD/alerts")" = 0 ] && [ "$(n "$FXD/trace")" = 0 ] \
    || no "LG1 lane + head checksum in the ledger: applied, READY, 1 probe, 1 contents read (verdict $MMH_VERDICT, state $STATE, probes $(n "$FXD/status.log"), contents $(n "$FXD/contents.log"), why $WHY)"
  grep -q "contents/$MP?ref=$H1" "$FXD/contents.log" 2>/dev/null || no "LG1 the contents read names the file and the head ($(cat "$FXD/contents.log" 2>/dev/null))"

  # ---- LG2 lane set, another checksum ----
  reset; lane; ledger "$OTHER"; run
  [ "$MMH_VERDICT" = lane ] && [ "$STATE" = WAIT_CI ] \
    && [[ $WHY == "HELD_MIGRATION 0423_x: left to the migration lane, which applies migrations before it merges (ledger: "*"applied at checksum ${OTHER:0:12}, the PR's file is $(sum | cut -c1-12))" ]] \
    && [ "$(n "$FXD/alerts")" = 0 ] && [ "$(n "$FXD/trace")" = 0 ] \
    || no "LG2 lane + another checksum: lane, held with the ledger detail, no alert, no comment (verdict $MMH_VERDICT, why '$WHY')"

  # ---- LG3 no lane ----
  reset; ledger "$OTHER"; run
  [ "$MMH_VERDICT" = missing ] && [ "$STATE" = WAIT_CI ] && [[ $WHY == *"applied at checksum ${OTHER:0:12}, the PR's file is $(sum | cut -c1-12)"* ]] \
    && [ "$(n "$FXD/alerts")" = 1 ] || no "LG3 no lane + another checksum: missing (changed), held, alerted (verdict $MMH_VERDICT, why '$WHY')"
  reset; echo '{"applied":[{"filename":"0423_x"}]}' > "$FXD/st-body"; run
  [ "$MMH_VERDICT" = applied ] && [ "$STATE" = READY ] && [ "$(n "$FXD/contents.log")" = 0 ] \
    || no "LG3b no lane + a row with no checksum: a name match, applied, no contents read (verdict $MMH_VERDICT, contents $(n "$FXD/contents.log"))"
  reset; ledger "$(sum)"; run
  [ "$MMH_VERDICT" = applied ] && [ "$STATE" = READY ] || no "LG3c no lane + the head checksum: applied ($MMH_VERDICT)"
  # a near-miss name at the right checksum is not the file
  reset; jq -nc --arg c "$(sum)" '{applied:[{filename:"0423_xy", checksum:$c}]}' > "$FXD/st-body"; lane; run
  [ "$MMH_VERDICT" = lane ] || no "LG3d a near-miss name 0423_xy at the head checksum is not applied ($MMH_VERDICT)"

  # ---- LG4 the head file cannot be read ----
  reset; lane; ledger "$(sum)"; : > "$FXD/content-404"; run
  [ "$MMH_VERDICT" = lane ] && [ "$STATE" = WAIT_CI ] && [[ $WHY == *"left to the migration lane"*"(ledger: "* ]] && [ "$(n "$FXD/alerts")" = 0 ] \
    || no "LG4 lane + the head file unreadable: lane, no alert (verdict $MMH_VERDICT, why '$WHY')"
  reset; ledger "$(sum)"; : > "$FXD/content-404"; run
  [ "$MMH_VERDICT" = unreadable ] && [ "$STATE" = WAIT_CI ] && [[ $WHY == *unreadable* ]] \
    || no "LG4c no lane + a checksum row + the head file unreadable: unreadable, held (verdict $MMH_VERDICT, why '$WHY')"
  # ---- LG4b lane set, the name is not in the ledger: no contents read ----
  reset; lane; echo '{"applied":[]}' > "$FXD/st-body"; run
  [ "$MMH_VERDICT" = lane ] && [ "$(n "$FXD/status.log")" = 1 ] && [ "$(n "$FXD/contents.log")" = 0 ] \
    && [[ $WHY == *"(ledger: not in the production migration ledger)" ]] \
    || no "LG4b lane + no ledger row: lane, 1 probe, 0 contents reads (why '$WHY', contents $(n "$FXD/contents.log"))"

  # ---- S1 mmh_head_sums ----
  reset
  if command -v mmh_head_sums >/dev/null 2>&1; then
    OUT=$(mmh_head_sums "$SLUG" "$H1" "$MP"); rc=$?
    [ "$rc" = 0 ] && [ "$OUT" = "0423_x	$(sum)" ] || no "S1 one name<TAB>sha256 line (rc $rc, out '$OUT')"
    : > "$FXD/content-404"; OUT=$(mmh_head_sums "$SLUG" "$H1" "$MP"); rc=$?
    [ "$rc" = 1 ] || no "S1 a failed read is rc 1 (rc $rc, out '$OUT')"
  else
    no "S1 mmh_head_sums is not defined"
  fi

  echo "part A: $F failed"
  exit "$F"
)
PA=$?; FAIL=$((FAIL + PA))

# ============================================================================
# Part B — the whole tick (tests/lib/mc-gate-tick.sh).
# ============================================================================
# shellcheck source=tests/lib/mc-gate-tick.sh
. "$(dirname "$0")/lib/mc-gate-tick.sh" || exit 1
mgt_setup bin/merge-conductor.d/bh-7785-migration-hold.sh bin/merge-conductor.d/bh-9368-migration-gate.sh \
  bin/merge-conductor.d/bh-9368-ledger-gate-rerun.sh bin/merge-conductor.d/bh-9368-park-ci-recheck.sh || exit 1
K="$MGT_SLUG#31"
setup_case() { # setup_case <ledger checksum or 'head'>
  mgt_fresh; mgt_sql; mgt_gate_red
  echo gate > "$BX/set/mc.migration_gate_checks.mkey"
  echo migration > "$BX/set/mc_migration_hold.apply_lane.mkey"
  if [ "$1" = head ]; then mgt_ledger "$(mgt_sum)"; else mgt_ledger "$1"; fi
}
gruns() { grep -c 'run rerun 103 --failed' "$BX/reruns.txt" 2>/dev/null || true; }

# LG5 — the ledger holds the file at the head checksum: one gate re-run over 3 ticks.
setup_case head; mgt_tick; mgt_tick; mgt_tick
[ "$(gruns)" = 1 ] && [ "$(mgt_n "$BX/reruns.txt")" = 1 ] && ok \
  || bad "LG5 applied at the head checksum: 1 re-run of the gate run over 3 ticks (reruns: $(cat "$BX/reruns.txt" 2>/dev/null); log: $(mgt_log))"
grep -qx "ledgergaterun $K $MGT_H1" "$ATT" 2>/dev/null && ok || bad "LG5 the ledgergaterun mark for (PR, head)"
! grep -q "^cirerun $K " "$ATT" 2>/dev/null && ! grep -q "^red $K " "$ATT" 2>/dev/null && ok \
  || bad "LG5 no red-ladder rerun mark and no strike ($(grep -E "^(cirerun|red) " "$ATT" 2>/dev/null))"
[ "$(mgt_n "$BX/status.log")" -ge 1 ] && ok || bad "LG5 the lane-set project asked migrations/status"

# LG6 — another checksum: no gate re-run.
setup_case "$(printf '0%.0s' $(seq 64))"; mgt_tick; mgt_tick; mgt_tick
[ "$(mgt_n "$BX/reruns.txt")" = 0 ] && ok || bad "LG6 another checksum: 0 re-runs (reruns: $(cat "$BX/reruns.txt" 2>/dev/null))"
[ "$(mgt_row | cut -d'|' -f1)" = WAIT_MIGRATION ] && ok || bad "LG6 the row waits on the migration (row $(mgt_row))"

# LG7 — observe mode: no re-run, one WOULD line.
setup_case head; rm -f "$CH/flags/merge-conductor-actions"; mgt_tick
[ "$(mgt_n "$BX/reruns.txt")" = 0 ] && grep -q "$K WOULD re-run the gate" "$CLOG" && ok \
  || bad "LG7 observe mode: 0 re-runs, one WOULD line (log: $(mgt_log))"
touch "$CH/flags/merge-conductor-actions"

# V1 — every curl went to a .test host.
[ -z "$(mgt_offhost)" ] && ok || bad "V1 a curl left the fixture hosts: $(mgt_offhost)"

echo "merge-conductor-migration-hold.bh-9368: part B $PASS passed; $FAIL failed in all (part A counted above)"
[ "$FAIL" -eq 0 ]
