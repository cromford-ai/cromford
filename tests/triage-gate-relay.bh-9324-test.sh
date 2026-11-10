#!/bin/bash
# tests/triage-gate-relay.bh-9324-test.sh — A RELAY JSON THE BOX ALREADY
# CONSUMED BUYS NO TRIAGE RUN (BH-9324, the rest of BH-8364).
#
# bin/triage-gate.sh answered `RUN remote-results-pending` for ANY *.json in
# state/remote-results/<p>/. Staging runs before the gate on every tick and
# moves every json it reads, so a json at gate time is often a hub re-send of
# a json this box consumed already. The gate now asks the rr-consumed row of
# each json (bin/lib/triage-gate-relay.sh, tgr_relay_run, through rrr_consumed
# in bin/lib/rr-relay.sh). Only when EVERY json has a `staged` or `duplicate`
# row does the check give no run reason. Every other answer is today's RUN.
#
# Driven, not grepped: the REAL lib, the REAL gate, the REAL rr-relay.sh and
# rr-cursor.sh. The stub is bin/jobs-client.sh: job_ledger_row answers from
# $LEDGER/<kind>/<key with / as %2F> (rc 2 absent, rc 1 when $LEDGER/down),
# and counts each call in $LEDGER/.gets. Every case has its own project id and
# its own ledger dir, so no case depends on another.
#
#   L1-L9  the lib (see each case)
#   G1-G8  the gate (see each case)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-gate-relay.bh-9324-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset FULL_SWEEP_SECS JOBS_BOX TRIAGE_GATE_RR_ROWS_MAX
# uid runs inside $(...), so the counter lives in a file in this run's scratch
# dir: a shell variable would never advance in the parent.
uid() { local n; n=$(( $(cat "$T/.uid" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/.uid"; printf 'p%s0%s' "$$" "$n"; }

# ── the stub client ─────────────────────────────────────────────────────────
mkdir -p "$T/stub"
cat > "$T/stub/jobs-client.sh" <<'SH'
_led_path() { printf '%s/%s/%s' "$LEDGER" "$1" "${2//\//%2F}"; }
job_ledger_get() { return 2; }
job_ledger_row() {
  echo "$1 $2" >> "$LEDGER/.gets"
  [ -e "$LEDGER/down" ] && return 1
  local f; f=$(_led_path "$1" "$2")
  [ -f "$f" ] || return 2
  cat "$f"
}
job_ledger_put() { # <kind> <key> <status> [detail]
  mkdir -p "$LEDGER/$1"
  jq -cn --arg s "$3" --arg d "${4:-}" '{status:$s, detail:$d}' > "$(_led_path "$1" "$2")"
}
flag_active() { [ -f "${HARNESS:-/nonexistent}/flags/$1" ]; }
SH
# The same client with no row reader (an old box): G5.
cat > "$T/stub/jobs-client-norow.sh" <<'SH'
job_ledger_get() { return 2; }
job_ledger_put() { return 0; }
flag_active() { [ -f "${HARNESS:-/nonexistent}/flags/$1" ]; }
SH

# relay <dir> <KEY> <build-id> — one relay json, named as the relay names it.
relay() { mkdir -p "$1"; jq -cn --arg k "$2" --arg b "builds/x-$2-$3" '{key:$k, build_dir:$b, result:"PR_CREATED"}' > "$1/$2.json"; }
# seed <ledger> <project> <KEY> <build-id> <status|-> — one rr-consumed row.
seed() {
  mkdir -p "$1/rr-consumed"
  local k="$2/$3@x-$3-$4"
  if [ "$5" = - ]; then echo '{"detail":"no status"}' > "$1/rr-consumed/${k//\//%2F}"
  else jq -cn --arg s "$5" '{status:$s}' > "$1/rr-consumed/${k//\//%2F}"; fi
}
gets() { [ -f "$1/.gets" ] && wc -l < "$1/.gets" | tr -d ' ' || echo 0; }

# lib <ledger> <project> <dir> [knob] — rc of tgr_relay_run in a clean shell.
lib() {
  ( export LEDGER="$1" HARNESS="$T/libh"
    [ -n "${4+x}" ] && export TRIAGE_GATE_RR_ROWS_MAX="$4"
    . "$T/stub/jobs-client.sh"
    . "$DIR/bin/lib/triage-gate-relay.sh" || exit 9
    command -v tgr_relay_run >/dev/null 2>&1 || exit 8
    tgr_relay_run "$2" "$3" )
}
mkdir -p "$T/libh"

# ═════════════════════════════════════════════════════════════════════════════
# L1-L9 — the lib
# ═════════════════════════════════════════════════════════════════════════════
# L1 / L2: staged and duplicate settle the json.
for st in staged duplicate; do
  p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"
  relay "$D" BH-1 a; seed "$L" "$p" BH-1 a "$st"
  lib "$L" "$p" "$D"; rc=$?
  [ "$rc" = 1 ] && ok || bad "L1/L2: one json with a '$st' row must give rc 1 (no run), got $rc"
done
# L3: no row. L4: a row with no status.
p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"; relay "$D" BH-1 a
lib "$L" "$p" "$D"; rc=$?
[ "$rc" = 0 ] && ok || bad "L3: no rr-consumed row must give rc 0 (run), got $rc"
p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"; relay "$D" BH-1 a; seed "$L" "$p" BH-1 a -
lib "$L" "$p" "$D"; rc=$?
[ "$rc" = 0 ] && ok || bad "L4: a row with no status must give rc 0, got $rc"
# L5: the jobs worker is down.
p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"; relay "$D" BH-1 a; seed "$L" "$p" BH-1 a staged; : > "$L/down"
lib "$L" "$p" "$D"; rc=$?
[ "$rc" = 0 ] && ok || bad "L5: an outage must give rc 0 (run), got $rc"
# L6: empty / badjson do not settle it.
for st in empty badjson parked; do
  p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"; relay "$D" BH-1 a; seed "$L" "$p" BH-1 a "$st"
  lib "$L" "$p" "$D"; rc=$?
  [ "$rc" = 0 ] && ok || bad "L6: a '$st' row must give rc 0 (run), got $rc"
done
# L7: three jsons, the first has no row -> stop at the first read.
p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"
relay "$D" BH-1 a; relay "$D" BH-2 a; relay "$D" BH-3 a
seed "$L" "$p" BH-2 a staged; seed "$L" "$p" BH-3 a staged
lib "$L" "$p" "$D"; rc=$?
[ "$rc" = 0 ] && ok || bad "L7: the 1st of 3 jsons with no row must give rc 0, got $rc"
[ "$(gets "$L")" = 1 ] && ok || bad "L7: the read must stop at the first miss, gets=$(gets "$L")"
# ... and the 3rd has no row (data past the first).
p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"
relay "$D" BH-1 a; relay "$D" BH-2 a; relay "$D" BH-3 a
seed "$L" "$p" BH-1 a staged; seed "$L" "$p" BH-2 a duplicate
lib "$L" "$p" "$D"; rc=$?
[ "$rc" = 0 ] && ok || bad "L7: the 3rd of 3 jsons with no row must give rc 0, got $rc"
seed "$L" "$p" BH-3 a staged; rm -f "$L/.gets"
lib "$L" "$p" "$D"; rc=$?
[ "$rc" = 1 ] && ok || bad "L7: 3 jsons all consumed must give rc 1, got $rc"
[ "$(gets "$L")" = 3 ] && ok || bad "L7: 3 consumed jsons must make 3 reads, gets=$(gets "$L")"
# L8: knob 0 = today; knob abc = the fallback 20.
p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"; relay "$D" BH-1 a; seed "$L" "$p" BH-1 a staged
lib "$L" "$p" "$D" 0; rc=$?
[ "$rc" = 0 ] && ok || bad "L8: knob 0 must give rc 0 (run as before), got $rc"
[ "$(gets "$L")" = 0 ] && ok || bad "L8: knob 0 must read nothing, gets=$(gets "$L")"
p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"
for i in $(seq 1 21); do relay "$D" "BH-$i" a; seed "$L" "$p" "BH-$i" a staged; done
lib "$L" "$p" "$D" abc; rc=$?
[ "$rc" = 0 ] && ok || bad "L8: knob abc reads 20, so 21 jsons must give rc 0, got $rc"
[ "$(gets "$L")" = 0 ] && ok || bad "L8: over the cap must read nothing, gets=$(gets "$L")"
p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"
for i in 1 2 3; do relay "$D" "BH-$i" a; seed "$L" "$p" "BH-$i" a staged; done
lib "$L" "$p" "$D" abc; rc=$?
[ "$rc" = 1 ] && ok || bad "L8: knob abc, 3 consumed jsons must give rc 1, got $rc"
# 20 consumed jsons at the fallback cap (no knob set) -> rc 1.
p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"
for i in $(seq 1 20); do relay "$D" "BH-$i" a; seed "$L" "$p" "BH-$i" a staged; done
lib "$L" "$p" "$D"; rc=$?
[ "$rc" = 1 ] && ok || bad "L8: no knob, 20 consumed jsons (the fallback cap) must give rc 1, got $rc"
# L9: cap 3 — 3 consumed jsons settle, 4 run with no read.
p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"
for i in 1 2 3; do relay "$D" "BH-$i" a; seed "$L" "$p" "BH-$i" a staged; done
lib "$L" "$p" "$D" 3; rc=$?
[ "$rc" = 1 ] && ok || bad "L9: cap 3, 3 consumed jsons must give rc 1, got $rc"
relay "$D" BH-4 a; seed "$L" "$p" BH-4 a staged; rm -f "$L/.gets"
lib "$L" "$p" "$D" 3; rc=$?
[ "$rc" = 0 ] && ok || bad "L9: cap 3, 4 consumed jsons must give rc 0, got $rc"
[ "$(gets "$L")" = 0 ] && ok || bad "L9: one over the cap must read nothing, gets=$(gets "$L")"
# L9b: a lane_knob answer wins over the env.
p=$(uid); L="$T/led-$p"; D="$T/rr-$p"; mkdir -p "$L"; relay "$D" BH-1 a; seed "$L" "$p" BH-1 a staged
( export LEDGER="$L" HARNESS="$T/libh" TRIAGE_GATE_RR_ROWS_MAX=5
  lane_knob() { [ "$1 $2" = "run-triage TRIAGE_GATE_RR_ROWS_MAX" ] && printf 0; }
  . "$T/stub/jobs-client.sh"; . "$DIR/bin/lib/triage-gate-relay.sh" || exit 9
  tgr_relay_run "$p" "$D" ); rc=$?
[ "$rc" = 0 ] && ok || bad "L9b: lane_knob 0 must win over env 5 (run), got $rc"
# no json at all: the function is total (rc 1, no read).
p=$(uid); L="$T/led-$p"; mkdir -p "$L" "$T/rr-$p"
lib "$L" "$p" "$T/rr-$p"; rc=$?
[ "$rc" = 1 ] && ok || bad "L: an empty dir must give rc 1, got $rc"
# no row reader in scope -> run.
p=$(uid); D="$T/rr-$p"; relay "$D" BH-1 a
( export HARNESS="$T/libh"; . "$DIR/bin/lib/triage-gate-relay.sh" || exit 9
  unset -f job_ledger_row 2>/dev/null; tgr_relay_run "$p" "$D" ); rc=$?
[ "$rc" = 0 ] && ok || bad "L: no job_ledger_row must give rc 0 (run), got $rc"

# ═════════════════════════════════════════════════════════════════════════════
# G1-G8 — the real gate in a scratch harness, board seeded to SKIP
# ═════════════════════════════════════════════════════════════════════════════
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'SH'
[ "${1:-}" = api ] || exit 1
shift; P=""
while [ $# -gt 0 ]; do case "$1" in -i) shift ;; -X|-f|-F|-H) shift 2 ;; -*) shift ;; *) P="$1"; break ;; esac; done
case "$P" in
  repos/o/r/issues/*/comments*) BODY='[]' ;;
  repos/o/r/issues*) BODY='[{"number":7,"state":"open","title":"Add sort","comments":1,"updated_at":"2026-09-24T11:00:00Z","body":"b","labels":[{"name":"ai-build"}],"assignees":[],"milestone":null}]' ;;
  repos/o/r/pulls*)  BODY='[]' ;;
  *) exit 1 ;;
esac
printf 'HTTP/2.0 200\r\n\r\n%s\n' "$BODY"
SH
chmod +x "$T/fakebin/gh"

# newh — a fresh scratch harness: the real gate and bin/lib, the stub client.
newh() {
  local h="$1"
  mkdir -p "$h/bin" "$h/state" "$h/flags" "$h/logs" "$h/env" "$h/builds"
  cp "$T/stub/jobs-client.sh" "$h/bin/jobs-client.sh"
  scratch_install_closure bin/triage-gate.sh "$h" >/dev/null || { echo "FAIL: cannot install the gate closure"; exit 1; }
  cat > "$h/bin/fleet-conf.sh" <<'SH'
case "${2:-}" in board_prefix) echo "-" ;; repo) echo "o/r" ;; *) exit 1 ;; esac
SH
  printf '#!/bin/sh\nexit 0\n' > "$h/bin/lane-alert.sh"
  printf '#!/bin/sh\nexit 0\n' > "$h/bin/decision-log.sh"
  chmod +x "$h/bin/"*.sh
}
# gate <h> <ledger> <project> [mode args] — the real gate.
gate() {
  local h="$1" l="$2" p="$3"; shift 3
  ( export PATH="$T/fakebin:$PATH" HARNESS="$h" LEDGER="$l"
    "$h/bin/triage-gate.sh" "$p" "$@" 2>>"$T/err.txt" )
}
# gcase — a fresh harness + ledger + project, seeded so the board SKIPs.
gcase() {
  GP=$(uid); GH="$T/h-$GP"; GL="$T/gl-$GP"; mkdir -p "$GL"; newh "$GH"
  GD="$GH/state/remote-results/$GP"
  OUT=$(gate "$GH" "$GL" "$GP" --seed); grep -q '^SEEDED' <<<"$OUT" || bad "setup: seed '$OUT' err=$(tail -3 "$T/err.txt")"
  BASE=$(gate "$GH" "$GL" "$GP"); [ "${BASE%% *}" = SKIP ] || bad "setup: an idle board must SKIP, got '$BASE'"
  rm -f "$GL/.gets"
}

# G1: a json with no row -> RUN.
gcase; relay "$GD" BH-1 a
OUT=$(gate "$GH" "$GL" "$GP")
[ "$OUT" = "RUN remote-results-pending" ] && ok || bad "G1: a json with no row must RUN, got '$OUT'"
[ -f "$GD/BH-1.json" ] && ok || bad "G1: the gate must not move the json"
# G2: a json with a staged row -> the board's own SKIP.
gcase; relay "$GD" BH-1 a; seed "$GL" "$GP" BH-1 a staged
OUT=$(gate "$GH" "$GL" "$GP")
[ "$OUT" = "$BASE" ] && ok || bad "G2: a consumed json must fall through to '$BASE', got '$OUT'"
[ -f "$GD/BH-1.json" ] && ok || bad "G2: the gate must not move or delete the json"
grep -q "^rr-consumed $GP/BH-1@x-BH-1-a$" "$GL/.gets" 2>/dev/null && ok || bad "G2: the gate must read the rr-consumed row: $(cat "$GL/.gets" 2>/dev/null)"
# G3: no json -> SKIP and no rr-consumed read.
gcase
OUT=$(gate "$GH" "$GL" "$GP")
[ "$OUT" = "$BASE" ] && ok || bad "G3: no json must SKIP as before, got '$OUT'"
grep -q '^rr-consumed' "$GL/.gets" 2>/dev/null && bad "G3: no json must read no rr-consumed row: $(cat "$GL/.gets")" || ok
# G4: a consumed json, worker down -> RUN.
gcase; relay "$GD" BH-1 a; seed "$GL" "$GP" BH-1 a staged; : > "$GL/down"
OUT=$(gate "$GH" "$GL" "$GP")
[ "$OUT" = "RUN remote-results-pending" ] && ok || bad "G4: an outage must RUN, got '$OUT'"
# G5: a client without job_ledger_row -> RUN.
gcase; relay "$GD" BH-1 a; seed "$GL" "$GP" BH-1 a staged
cp "$T/stub/jobs-client-norow.sh" "$GH/bin/jobs-client.sh"
OUT=$(gate "$GH" "$GL" "$GP")
[ "$OUT" = "RUN remote-results-pending" ] && ok || bad "G5: no row reader must RUN, got '$OUT'"
# G6: a staged row under another project, and one for another build id -> RUN.
gcase; relay "$GD" BH-1 a; seed "$GL" "other$GP" BH-1 a staged; seed "$GL" "$GP" BH-1 b staged
OUT=$(gate "$GH" "$GL" "$GP")
[ "$OUT" = "RUN remote-results-pending" ] && ok || bad "G6: another project's / build id's row must RUN, got '$OUT'"
# G7: the row the REAL rrc_json_consume writes is the row the gate reads.
gcase; relay "$GD" BH-1 a; mkdir -p "$T/copy-$GP"; cp "$GD/BH-1.json" "$T/copy-$GP/BH-1.json"
( export LEDGER="$GL" HARNESS="$GH"; . "$T/stub/jobs-client.sh"; . "$DIR/bin/lib/rr-cursor.sh"
  rrc_json_consume "$GP" "$T/copy-$GP/BH-1.json" staged ) || bad "G7: rrc_json_consume failed"
OUT=$(gate "$GH" "$GL" "$GP")
[ "$OUT" = "$BASE" ] && ok || bad "G7: a json consumed by rrc_json_consume must SKIP, got '$OUT' (ledger: $(ls "$GL"/rr-consumed 2>/dev/null))"
# G8: --signal / --buildable-strict answer as with no json (mode set unchanged).
gcase
S0=$(gate "$GH" "$GL" "$GP" --signal 7; echo "rc=$?"); B0=$(gate "$GH" "$GL" "$GP" --buildable-strict 7; echo "rc=$?")
relay "$GD" BH-1 a
S1=$(gate "$GH" "$GL" "$GP" --signal 7; echo "rc=$?"); B1=$(gate "$GH" "$GL" "$GP" --buildable-strict 7; echo "rc=$?")
[ "$S0" = "$S1" ] && ok || bad "G8: --signal must not change with a json present: '$S0' vs '$S1'"
[ "$B0" = "$B1" ] && ok || bad "G8: --buildable-strict must not change with a json present: '$B0' vs '$B1'"
# G8: the lib removed from the tree -> RUN for a consumed json.
gcase; relay "$GD" BH-1 a; seed "$GL" "$GP" BH-1 a staged
rm -f "$GH/bin/lib/triage-gate-relay.sh"
OUT=$(HARNESS="$GH" gate "$GH" "$GL" "$GP")
[ "$OUT" = "RUN remote-results-pending" ] && ok || bad "G8: no lib must RUN, got '$OUT'"

echo "triage-gate-relay.bh-9324: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
