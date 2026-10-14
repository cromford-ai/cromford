#!/bin/bash
# tests/lane-switch.bh-2407-test.sh — the BH-2407 contract (BH-2431):
# lane_switch's fail-closed hatch and `file|flag` mode, the a-f switch registry,
# and the ratchet's per-child drop files.
#
# What is proved here:
#   L1 LANE_GATE_DISABLE=1 with the file present and a row saying 0: rc 0,
#      src=legacy-file, and no /api/settings request (the hatch never un-kills);
#   L2 `file` mode reads only the file (zero /api/flags requests, no
#      flag_active) while `flag` mode in the same state reads the pause_flags
#      row once (GET /api/flags/<name>, read-only since BH-2412, never through
#      flag_active, which writes flags/);
#   L3 LANE_GATE_DISABLE=1, no file, row 1: rc 1, src=legacy-file;
#   L4 a cached row outlives a worker outage in `file` mode too;
#   L5 an unknown mode is logged once and answers what `flag` answers; an
#      empty mode is `flag` and logs nothing;
#   L6 a bad name under the hatch is refused before any path is built;
#   M1/M2 (D1) the suite re-runs its L cases against two mutants of the
#      library: the old `return 1` hatch must turn L1 red, and a library with
#      no `file)` branch must turn L2 red;
#   RT1-RT3 the ratchet's strict-mode .drop floor, run as shipped over a
#      HERMETIC tree at its floor (tests/lib/switch-ratchet-tree.sh; whether
#      the live tree passes is switch-ratchet's own job, never re-run here): the
#      tree passes; a drop of 1 plus one bare read removed passes, the drop alone does
#      not; a drop of `abc`, `-1`, `1.5` or nothing fails with an R0 line;
#   G1/G2 the 25 registry files: shape, name = filename, every reader exists
#      and names the switch on a code line; fly-disabled names its writer;
#   S9 the real bin/switch-migrate.sh --dry-run lists every registry name:
#      main's 40, plus any a later conversion registered (BH-2444 added six,
#      BH-2443 seven).
# Run from anywhere: tests/lane-switch.bh-2407-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
. "$(dirname "$0")/lib/switch-ratchet-tree.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

LS="${LS_UNDER_TEST:-$DIR/bin/lib/lane-switch.sh}"
NOW=1758300000
mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
cp "$LS" "$T/h/bin/lib/lane-switch.sh"
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"

# The stub worker, as in the bh-2320 suite. STUB_FLAG_ACTIVE=1 loads
# _flag_epoch, which with _jobs_req is what lane_switch's read-only pause_flags
# step needs before it issues GET /api/flags/<name> (BH-2412), so
# "zero /api/flags requests" is counted in $CALLS, not assumed. flag_active is
# loaded too, so a library that went back to calling it is counted.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  case "$2" in
    /api/settings) printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    *) return 1 ;;
  esac
}
if [ "${STUB_FLAG_ACTIVE:-}" = 1 ]; then
  flag_active() { echo "FLAG_ACTIVE $1" >> "$CALLS"; _jobs_req GET "/api/flags/$1" >/dev/null; [ -f "$HARNESS/flags/$1" ]; }
  _flag_epoch() { date -u -d "$1" +%s 2>/dev/null; }
fi
SH

rows() {
  local out='[]' kv
  for kv in "$@"; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"api"}]')
  done
  printf '%s' "$out" > "$T/rows.json"
}
reset() {
  rm -rf "$T/h/state/lane-gate" "$T/h/logs/lane-gate.log"
  rm -f "$T/h/state/settings-cache.json" "$T/h/flags"/* "$T/rows.json"
  : > "$T/calls"; UNREACHABLE=""; AT="$NOW"; STUB_FLAG_ACTIVE=""; HATCH=""
}

# ask <name> [mode] — one read in a cold child shell; prints `rc=<n> src=<where>`.
# The mode is passed only when given, so a one-arg call is exactly today's call.
ask() {
  env HARNESS="$T/h" LANE_GATE_NOW="$AT" CALLS="$T/calls" ROWS_FILE="$T/rows.json" \
      UNREACHABLE="$UNREACHABLE" JOBS_BOX=hub-1 STUB_FLAG_ACTIVE="$STUB_FLAG_ACTIVE" \
      LANE_GATE_DISABLE="$HATCH" \
      bash -c '
        set -uo pipefail
        . "$HARNESS/bin/lib/lane-switch.sh" || exit 9
        lane_switch "$@"; rc=$?
        echo "rc=$rc src=${LANE_SWITCH_SRC:-unset}"' _ "$@" 2>/dev/null
}
calls() { grep -c -- "$1" "$T/calls"; }
loglines() { [ -f "$T/h/logs/lane-gate.log" ] && grep -c -- "$1" "$T/h/logs/lane-gate.log" || echo 0; }

# L1 — the hatch reads the file, never the row.
reset; rows switch.x-off=0; touch "$T/h/flags/x-off"; HATCH=1
eq "L1 hatch + file + row 0" "$(ask x-off)" "rc=0 src=legacy-file"
eq "L1 the hatch makes no /api/settings request" "$(calls '/api/settings')" "0"

# L2 — `file` mode is the file alone; `flag` mode is the pilot's path.
reset; rows; touch "$T/h/flags/x-off"; STUB_FLAG_ACTIVE=1
eq "L2 file mode, no row, file" "$(ask x-off file)" "rc=0 src=legacy-file"
eq "L2 file mode makes zero /api/flags requests" "$(calls '/api/flags')" "0"
eq "L2 file mode never asks flag_active" "$(calls '^FLAG_ACTIVE')" "0"
reset; rows; touch "$T/h/flags/x-off"; STUB_FLAG_ACTIVE=1
eq "L2 flag mode, no row, file" "$(ask x-off flag)" "rc=0 src=legacy-file"
eq "L2 flag mode makes one /api/flags request" "$(calls '/api/flags/')" "1"
reset; rows; STUB_FLAG_ACTIVE=1
eq "L2 file mode, no row, no file" "$(ask x-off file)" "rc=1 src=legacy-file"

# L3 — the hatch with no file is off, whatever the row says.
reset; rows switch.x-off=1; HATCH=1
eq "L3 hatch + no file + row 1" "$(ask x-off)" "rc=1 src=legacy-file"
reset; rows switch.x-off=1; HATCH=1; touch "$T/h/flags/x-off"
eq "L3 hatch + file mode + file" "$(ask x-off file)" "rc=0 src=legacy-file"

# L4 — a cached row answers in `file` mode through an outage.
reset; rows switch.x-off=1
ask x-off file >/dev/null
AT=$((NOW+3600)); UNREACHABLE=1; rm -f "$T/rows.json"
eq "L4 cached row, worker down, file mode" "$(ask x-off file)" "rc=0 src=fleet-row"
reset; rows switch.x-off=0; touch "$T/h/flags/x-off"
eq "L4 a row answers the same in file mode" "$(ask x-off file)" "rc=1 src=fleet-row"

# L5 — an unknown mode is `flag`, and is said once.
reset; rows; touch "$T/h/flags/x-off"; STUB_FLAG_ACTIVE=1
eq "L5 bogus mode + file" "$(ask x-off bogus)" "rc=0 src=legacy-file"
eq "L5 bogus mode reads the pause_flags row" "$(calls '^GET /api/flags/x-off$')" "1"
eq "L5 bogus mode is logged" "$(loglines "switch x-off: mode 'bogus' is not file|flag, read as flag")" "1"
rm -f "$T/h/flags/x-off"; AT=$((NOW+1))
eq "L5 bogus mode, no file" "$(ask x-off bogus)" "rc=1 src=legacy-file"
reset; rows; touch "$T/h/flags/x-off"; STUB_FLAG_ACTIVE=1
eq "L5 empty mode + file" "$(ask x-off "")" "rc=0 src=legacy-file"
eq "L5 empty mode is flag" "$(calls '^GET /api/flags/x-off$')" "1"
eq "L5 empty mode logs nothing" "$(loglines "mode ")" "0"

# L6 — a bad name is refused before the hatch builds a path.
reset; HATCH=1; mkdir -p "$T/h/x"
eq "L6 hatch + ../x" "$(ask ../x file)" "rc=1 src=none"
eq "L6 hatch + a dotted name" "$(ask x.off)" "rc=1 src=none"

# A mutant run stops here: its job is to show which L case goes red.
if [ -n "${LS_MUTANT:-}" ]; then
  echo "lane-switch.bh-2407 (mutant): $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

# M1/M2 — D1, every run. Each mutant must actually differ from the library,
# or the mutation proved nothing.
mutant() {  # mutant <label> <sed-expr> <must-fail-pattern>
  local m="$T/mutant-$1.sh" out
  sed "$2" "$LS" > "$m"
  if cmp -s "$m" "$LS"; then bad "$1 the mutation did not apply to $LS"; return; fi
  out=$(LS_UNDER_TEST="$m" LS_MUTANT=1 HARNESS_TEST_SANDBOX=1 bash "$0" 2>&1)
  if grep -q "^FAIL: $3" <<<"$out"; then ok; else bad "$1 the mutant left $3 green: $out"; fi
}
mutant M1 '/^  LANE_SWITCH_SRC=none; export LANE_SWITCH_SRC$/a\  [ "${LANE_GATE_DISABLE:-}" = 1 ] \&\& return 1' "L1"
mutant M2 '/^    file) \[ -f "\$3" \]; return \$? ;;$/d' "L2 file mode"

# RT1-RT3 — the ratchet's .drop floor, run as shipped (strict mode) over a
# hermetic tree that sits AT its floor. fixture.drop stacks on the tree's own.
R="$T/r"
srt_tree "$R" 3 || bad "RT0 srt_tree could not build the fixture tree"
ratchet() { srt_run "$R" > "$T/ratchet.out"; }

ratchet; RC=$?
eq "RT1 the tree at its floor passes ($(tail -1 "$T/ratchet.out"))" "$RC" "0"
printf ' 1 \n' > "$R/tests/switch-ratchet.d/fixture.drop"
ratchet; RC=$?
[ "$RC" -ne 0 ] && ok || bad "RT2 a drop of 1 with no read removed must fail (the tree must sit AT the effective floor)"
BARE_RE='\[ -[ef] [^]]*flags/[a-z0-9-]+-(off|disabled)[^]]*\]'
RF=$(grep -rlE "$BARE_RE" "$R/bin" | head -n 1)
[ -n "$RF" ] && ok || bad "RT2 no bare read in the fixture tree to remove"
sed -i -E "0,\#$BARE_RE#s##false#" "$RF"
ratchet; RC=$?
eq "RT2 drop 1 + one bare read removed passes ($(tail -3 "$T/ratchet.out" | tr '\n' ' '))" "$RC" "0"
for v in abc -1 1.5 ""; do
  printf '%s' "$v" > "$R/tests/switch-ratchet.d/fixture.drop"
  ratchet; RC=$?
  if [ "$RC" -ne 0 ] && grep -q '^FAIL: R0 .*fixture.drop' "$T/ratchet.out"; then ok
  else bad "RT3 a drop of '$v' must fail with an R0 line (rc=$RC): $(cat "$T/ratchet.out")"; fi
done

# G1/G2 — the a-f registry.
SWITCHES="agent-call-ledger-off alert-quarantine-disabled alert-state-off audit-off batch-resolve-off
bin-self-heal-off blocked-resolver-disabled builder-direct-off call-guard-off cliff-refuse-off
cliff-route-off clock-sync-off context-gate-disabled context-kill-off cost-autohalt-off
cost-reconcile-off cost-row-at-source-off cost-rows-from-db-off cost-rows-push-off dep-verify-off
extra-usage-track-off fastpath-off fixpr-suppress-off fleet-slo-off fly-disabled"
for n in $SWITCHES; do
  f="$DIR/catalog/switches.d/$n.json"
  [ -f "$f" ] || { bad "G1 catalog/switches.d/$n.json is missing"; continue; }
  eq "G1 $n is one line" "$(wc -l < "$f" | tr -d ' ')" "1"
  eq "G1 $n shape" "$(jq -c '[keys_unsorted, .name, .box_scoped, (.readers|type), (.what|type)]' "$f" 2>/dev/null)" \
    "[[\"name\",\"readers\",\"box_scoped\",\"what\"],\"$n\",true,\"array\",\"string\"]"
  RD=$(jq -r '.readers[]' "$f" 2>/dev/null)
  [ -n "$RD" ] && ok || bad "G1 $n has no readers"
  for r in $RD; do
    if [ -f "$DIR/$r" ] && grep -nE "$n([^a-z0-9_-]|$)" "$DIR/$r" | grep -qvE '^[0-9]+:[[:space:]]*#'; then ok
    else bad "G1 $n reader $r does not exist or names $n on no code line"; fi
  done
  case "$(jq -r '.what' "$f")" in "stops "*|"turns off "*) ok ;; *) bad "G1 $n what must start 'stops' or 'turns off'" ;; esac
done
jq -r '.what' "$DIR/catalog/switches.d/fly-disabled.json" 2>/dev/null | grep -qF 'bin/fly-trial-kill.sh' && ok \
  || bad "G2 fly-disabled's what must name bin/fly-trial-kill.sh as its writer"

# S9 — the real switch-migrate walks every registry file: the 40 (the 25, the
# dora-digest pilot, the nine BH-2436 registered and the five sourced-lib
# switches BH-2429 registered, whose own shape is pinned by
# lane-switch-registry.bh-2410) and whatever later slices of BH-2408 register.
C4="split-chain-off state-backup-off test-reroute-off triage-health-off triage-shards-off
triage-shard-caps-off triage-spool-age-off vendor-spend-off wake-lanes-off
pool-account-routing-off pr-create-rest-fallback-off pr-dep-gate-off pr-merge-rest-off resume-disabled"
S="$T/s"; mkdir -p "$S/bin" "$S/flags" "$S/state" "$S/logs" "$S/catalog"
cp -r "$DIR/catalog/switches.d" "$S/catalog/"
cat > "$S/bin/jobs-client.sh" <<'SH'
_jobs_req() { case "$1 $2" in "GET /api/settings") JOBS_HTTP=200; printf '{"settings":[]}' ;; *) return 1 ;; esac; }
SH
env HARNESS="$S" JOBS_BOX=hub-1 "$DIR/bin/switch-migrate.sh" --dry-run > "$T/s.out" 2>&1
eq "S9 dry-run exits 0" "$?" "0"
# Every registry file, not a count frozen at 26: a later slice registers more
# (BH-2444 added six), and each of main's 40 must still be among them.
ALL=$(for f in "$DIR"/catalog/switches.d/*.json; do basename "$f" .json; done | sort | tr '\n' ' ')
GOT=$(grep '^absent ' "$T/s.out" | awk '{print $2}' | sort | tr '\n' ' ')
eq "S9 dry-run names every switch absent" "$(grep -c '^absent ' "$T/s.out")" "$(printf '%s' "$ALL" | wc -w | tr -d ' ')"
eq "S9 the name set" "$GOT" "$ALL"
for n in $SWITCHES dora-digest-off $C4; do
  case " $GOT" in *" $n "*) ok ;; *) bad "S9 $n missing from the dry-run" ;; esac
done

echo "lane-switch.bh-2407: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
