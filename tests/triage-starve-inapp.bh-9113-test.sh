#!/bin/bash
# tests/triage-starve-inapp.bh-9113-test.sh — BH-9113 cause 1: the starvation
# guard (bin/lib/triage-starve.sh tsv_pass) took no action on an in-app board.
# project-3, 2026-11-05: `TRIAGE-STARVE TK-624 listed 15 passes over 2.8h with no
# triage run — n/a: in-app board`, 15 ready team-turn tickets unbuilt for 6 h.
# Now each eligible in-app key gets ONE guarded launch attempt through the
# triage-state launch guard (_ts_owned) and bin/run-build.sh.
#
#   A1        acceptance 1: a ready, team-turn ticket listed past the window is
#             launched once through run-build.sh; the ledger says `launched`
#   A2a-A2n   acceptance 2: every guard declines with its reason, no launch
#   A3        acceptance 3: a live builds pause withholds the attempt and logs it
#   A4        once per listing episode
#   A5        the per-pass cap (TRIAGE_STARVE_FASTPATH_MAX), oldest first
#   A6        the launch guard not loaded: fail closed
#   A7        a spawn that cannot run: declined, the marker removed
#   A8        acceptance 5: a GitHub board still calls launch-fastpath.sh only
#   K         TRIAGE_STARVE_INAPP_LAUNCH=0: the pre-BH-9113 record
#   R1        the ledger keeps 8 columns and the outcome over later passes
#   V         0 vendor calls
#
# Run from anywhere: tests/triage-starve-inapp.bh-9113-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

LIB="$DIR/bin/lib/triage-starve.sh"
export HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1
unset TRIAGE_STARVE_PASSES TRIAGE_STARVE_WINDOW_S TRIAGE_STARVE_FASTPATH_MAX TRIAGE_STARVE_FASTPATH_TIMEOUT_S \
      TRIAGE_STARVE_LOCK_WAIT_S TRIAGE_STARVE_INAPP_LAUNCH STUB_GATE TRIAGE_GH_SLUG

# ── vendor recorders: any call is a failure (V); setsid runs in place ────────
mkdir -p "$T/rbin" "$T/calls"
for v in gh claude curl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls/vendor"\nexit 1\n' "$v" "$T" > "$T/rbin/$v"
done
printf '#!/bin/bash\nexec "$@"\n' > "$T/rbin/setsid"
chmod +x "$T/rbin/"*
export PATH="$T/rbin:$PATH"

# ── the scratch harness: stub run-build, triage-gate, fastpath, alerts ──────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/builds"
cat > "$H/bin/run-build.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/runbuild-\$1"
STUB
cat > "$H/bin/triage-gate.sh" <<'STUB'
#!/bin/bash
[ "${2:-}" = --buildable-strict ] && { echo "${STUB_GATE:-OK}"; exit 0; }
exit 0
STUB
cat > "$H/bin/launch-fastpath.sh" <<STUB
#!/bin/bash
p="\$1"; shift
printf '%s\n' "\$p \$*" >> "$T/calls/fastpath-\$p"
exit 0
STUB
cat > "$H/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/alert"
exit 0
STUB
cat > "$H/bin/alert-line.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$H/bin/"*.sh
export HARNESS="$H"

NOW=1790000000
HR=3600
# newp <case> — a fresh in-app project for the case, with no open PR
newp() {
  P="inapp-$1-$$"
  mkdir -p "$H/state/triage-state/$P"
  echo '[]' > "$H/state/triage-state/$P/prs.json"
  world todo ready team
}
# world <status> <verdict> <waitingOn> [id key]... — the board snapshot
# (state/triage-state/<p>/world.json); `-` leaves the field out. With no
# id/key pairs, one ticket: t624 / TK-624.
world() {
  local st="$1" v="$2" w="$3"; shift 3
  [ $# -gt 0 ] || set -- t624 TK-624
  local rows="" id key
  while [ $# -ge 2 ]; do
    id="$1"; key="$2"; shift 2
    rows="$rows$(jq -nc --arg id "$id" --arg key "$key" --arg st "$st" --arg v "$v" --arg w "$w" \
      '{id:$id, key:$key} + (if $st=="-" then {} else {status:$st} end)
       + (if $v=="-" then {} else {triageVerdict:$v} end) + (if $w=="-" then {} else {waitingOn:$w} end)'),"
  done
  printf '{"b1":[%s],"meta":{}}\n' "${rows%,}" > "$H/state/triage-state/$P/world.json"
}
# listed <id:key>... — this pass's decisions.tsv, each key `llm new` (the
# ts_precheck columns: key label decision reason hash seed in-scope base work)
listed() {
  local f="$H/state/triage-state/$P/decisions.tsv" a
  : > "$f"
  [ $# -gt 0 ] || set -- t624:TK-624
  for a in "$@"; do printf '%s\t%s\tllm\tnew\th-%s\t-\t1\t-\t0\n' "${a%%:*}" "${a#*:}" "${a%%:*}" >> "$f"; done
}
# pass <offset-s> [lib-only] — one tsv_pass at NOW+offset in a fresh process,
# with the triage-state libs loaded as ts_tick has them (lib-only: not loaded).
pass() {
  local off="$1"
  ( export TSV_NOW=$((NOW + off)); LOG="$H/logs/$P.log"; STAMP="t+$off"; TS_MODE=enforce
    if [ "${2:-}" != lib-only ]; then
      # shellcheck source=/dev/null
      . "$DIR/bin/lib/triage-state.sh" && . "$DIR/bin/lib/triage-state-pr.sh" || exit 0
    fi
    # shellcheck source=/dev/null
    . "$LIB" || exit 0
    tsv_pass "$H" "$P"
    exit 0 ) 2>/dev/null
}
three() { pass 0; pass $HR; pass $((2*HR)); }
rbcalls() { local n; n=$(grep -c . "$T/calls/runbuild-$P" 2>/dev/null); printf '%s' "${n:-0}"; }
col()     { awk -F'\t' -v k="$1" -v c="$2" '$1==k {print $c}' "$H/state/triage-state/$P/starve.tsv" 2>/dev/null; }
led()     { cat "$H/state/triage-state/$P/starve.tsv" 2>/dev/null; }
lastlog() { grep "TRIAGE-STARVE" "$H/logs/$P.log" 2>/dev/null | tail -1; }
alerts()  { local n; n=$(grep -c -- "--id triage-starve-$P " "$T/calls/alert" 2>/dev/null); printf '%s' "${n:-0}"; }
unhold()  { pkill -P "$1" 2>/dev/null; kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

# ═══ A1: acceptance 1 — one launch, recorded `launched` ═════════════════════
newp a1; listed; three
[ "$(rbcalls)" = 1 ] && ok || bad "(A1) a ready team-turn in-app ticket listed past the window: one run-build.sh call [$(rbcalls)]"
[ "$(cat "$T/calls/runbuild-$P" 2>/dev/null)" = "$P t624 TK-624" ] && ok || bad "(A1) run-build.sh argv is <project> <id> <label>: [$(cat "$T/calls/runbuild-$P" 2>/dev/null)]"
[ "$(col t624 7)" = launched ] && ok || bad "(A1) the ledger records launched: [$(col t624 7)]"
[ "$(col t624 7)" != "n/a: in-app board" ] && ok || bad "(A1) the ledger does not say n/a: in-app board"
[ "$(cat "$H/state/triage-state/$P/t624.enqueued" 2>/dev/null)" = h-t624 ] && ok || bad "(A1) the .enqueued marker holds the verdict hash"
case "$(lastlog)" in *"TRIAGE-STARVE TK-624 listed 3 passes over 2.0h with no triage run — inapp launched") ok ;;
  *) bad "(A1) the lane line ends 'inapp launched': [$(lastlog)]" ;; esac
[ "$(alerts)" = 1 ] && grep -- "--id triage-starve-$P " "$T/calls/alert" | grep -q "TK-624=launched" \
  && ok || bad "(A1) one alert names TK-624=launched [$(grep -- "triage-starve-$P " "$T/calls/alert" 2>/dev/null)]"
[ -e "$H/logs/$P.TK-624-triage-starve.out" ] && ok || bad "(A1) the spawn writes logs/<p>.<label>-triage-starve.out"
# A4: a fourth pass in the same episode: still one launch
pass $((3*HR))
[ "$(rbcalls)" = 1 ] && ok || bad "(A4) pass 4 of the same episode: still one launch [$(rbcalls)]"

# ═══ A2: acceptance 2 — each guard declines, with its reason ════════════════
# decl <case> <expected outcome> — three passes, 0 launches, column 7 exact
decl() {
  three
  [ "$(rbcalls)" = 0 ] && ok || bad "($1) no run-build.sh call [$(rbcalls)]"
  [ "$(col t624 7)" = "$2" ] && ok || bad "($1) the ledger says '$2': [$(col t624 7)]"
}
newp a2a; world todo ready requester; listed; decl A2a "declined: waitingOn=requester"
case "$(lastlog)" in *"— inapp declined: waitingOn=requester") ok ;; *) bad "(A2a) the lane line names the decline: [$(lastlog)]" ;; esac
newp a2b; world todo ready client; listed; decl A2b "declined: waitingOn=client"
newp a2c; world todo needs_clarification team; listed; decl A2c "declined: triageVerdict=needs_clarification"
newp a2d; world todo - team; listed; decl A2d "declined: triageVerdict=none"
newp a2e; world paused ready team; listed; decl A2e "declined: status=paused"
newp a2f; world PAUSED ready team; listed; decl A2f "declined: status=PAUSED"
newp a2g; echo '[{"number":412,"head":{"ref":"ticket/TK-624"},"title":"TK-624: fix"}]' > "$H/state/triage-state/$P/prs.json"
listed; decl A2g "declined: owned:pr-412"
newp a2h; listed; export STUB_GATE="BLOCKED dependencies TK-12"; decl A2h "declined: held:dependencies TK-12"; unset STUB_GATE
newp a2i; listed
flock "$H/locks/build-key-$P-TK-624.lock" sleep 30 &
HOLDER=$!
for _ in $(seq 1 50); do flock -n "$H/locks/build-key-$P-TK-624.lock" true 2>/dev/null || break; sleep 0.1; done
decl A2i "declined: owned:building"
unhold "$HOLDER"
newp a2j; world todo ready team t999 TK-999; listed; decl A2j "declined: not on the board snapshot"
newp a2k; listed; printf 'h-t624\n' > "$H/state/triage-state/$P/t624.enqueued"; decl A2k "declined: owned:enqueued"
# A2l near miss, pinned not changed: _ts_owned matches a PR head with `contains`
newp a2l; echo '[{"number":413,"head":{"ref":"ticket/TK-6240"},"title":"TK-6240: other"}]' > "$H/state/triage-state/$P/prs.json"
listed; decl A2l "declined: owned:pr-413"
newp a2m; world review ready team; listed; decl A2m "declined: status=review"
newp a2n; listed; pass 0; pass $HR; echo 'not json' > "$H/state/triage-state/$P/world.json"; pass $((2*HR))
[ "$(rbcalls)" = 0 ] && [ "$(col t624 7)" = "declined: snapshot unreadable" ] && ok || bad "(A2n) an unreadable snapshot declines: [$(col t624 7)]"
newp a2o; world todo ready - ; listed; decl A2o "declined: waitingOn=none"
# A2p: the PR list could not be read — the guard fails closed
newp a2p; echo unreadable > "$H/state/triage-state/$P/prs.json"; listed; decl A2p "declined: owned:pr-unreadable"

# ═══ A3: acceptance 3 — a live builds pause withholds the attempt ═══════════
newp a3; listed
pause_active() { [ "$1" = "$P" ] && [ "$2" = builds ]; }
export -f pause_active; export P
three
[ "$(rbcalls)" = 0 ] && [ "$(alerts)" = 0 ] && ok || bad "(A3) a builds pause: no launch, no alert [$(rbcalls)/$(alerts)]"
grep -q "TRIAGE-STARVE withheld TK-624: builds pause" "$H/logs/$P.log" && ok || bad "(A3) the withhold is logged"
[ "$(col t624 6)" = 0 ] && [ "$(col t624 7)" = - ] && ok || bad "(A3) a withheld key is not marked tried: [$(led)]"
unset -f pause_active
pass $((2*HR + 600))
[ "$(rbcalls)" = 1 ] && [ "$(col t624 7)" = launched ] && ok || bad "(A3) the pause lifted: the next pass launches once [$(rbcalls) $(col t624 7)]"

# ═══ A5: the per-pass cap, oldest first ═════════════════════════════════════
newp a5
ids=""; for i in $(seq 1 12); do ids="$ids t$i TK-$i"; done
# shellcheck disable=SC2086
world todo ready team $ids
old=""; for i in $(seq 3 12); do old="$old t$i:TK-$i"; done
# shellcheck disable=SC2086
listed $old; pass 0
# keys 1 and 2 arrive 10 minutes later, FIRST in decisions.tsv order
# shellcheck disable=SC2086
listed t1:TK-1 t2:TK-2 $old; pass 600; pass $HR
export TRIAGE_STARVE_FASTPATH_MAX=10
pass $((2*HR + 600))
[ "$(rbcalls)" = 10 ] && ok || bad "(A5) 12 eligible, cap 10: 10 launches this pass [$(rbcalls)]"
[ "$(awk '{print $3}' "$T/calls/runbuild-$P" 2>/dev/null | sort -t- -k2n | tr '\n' ' ')" = "TK-3 TK-4 TK-5 TK-6 TK-7 TK-8 TK-9 TK-10 TK-11 TK-12 " ] \
  && ok || bad "(A5) the 10 oldest first_listed are launched: [$(awk '{print $3}' "$T/calls/runbuild-$P" | tr '\n' ' ')]"
[ "$(alerts)" = 1 ] && grep -- "--id triage-starve-$P " "$T/calls/alert" | grep -q "10 ticket(s) listed" && ok || bad "(A5) one alert names 10 tickets"
pass $((2*HR + 700))
[ "$(rbcalls)" = 12 ] && [ "$(tail -2 "$T/calls/runbuild-$P" | awk '{print $3}' | sort | tr '\n' ' ')" = "TK-1 TK-2 " ] \
  && ok || bad "(A5) the next pass launches the other 2: [$(rbcalls)]"
unset TRIAGE_STARVE_FASTPATH_MAX

# ═══ A6: the launch guard not loaded — fail closed ══════════════════════════
newp a6; listed
pass 0 lib-only; pass $HR lib-only; pass $((2*HR)) lib-only
[ "$(rbcalls)" = 0 ] && [ "$(col t624 7)" = "declined: launch guard unavailable" ] && ok || bad "(A6) no _ts_owned: declined, no launch [$(rbcalls) $(col t624 7)]"

# ═══ A7: the spawn cannot run ═══════════════════════════════════════════════
newp a7; listed
chmod -x "$H/bin/run-build.sh"
three
chmod +x "$H/bin/run-build.sh"
[ "$(rbcalls)" = 0 ] && [ "$(col t624 7)" = "declined: spawn failed" ] && ok || bad "(A7) run-build.sh not executable: declined: spawn failed [$(col t624 7)]"
[ ! -e "$H/state/triage-state/$P/t624.enqueued" ] && ok || bad "(A7) a failed spawn removes the .enqueued marker"

# ═══ A8: acceptance 5 — a GitHub board is unchanged ═════════════════════════
newp a8; echo '{"issues":[],"meta":{}}' > "$H/state/triage-state/$P/world.json"
f="$H/state/triage-state/$P/decisions.tsv"; printf '77\tGH-77\tllm\tnew\th\t-\t1\t-\t0\n' > "$f"
three
[ "$(cat "$T/calls/fastpath-$P" 2>/dev/null)" = "$P GH-77" ] && ok || bad "(A8) GitHub: launch-fastpath.sh called once with the label [$(cat "$T/calls/fastpath-$P" 2>/dev/null)]"
[ "$(rbcalls)" = 0 ] && ok || bad "(A8) GitHub: run-build.sh is not called by the guard [$(rbcalls)]"
[ "$(col 77 7)" = launched ] && grep -q "— fastpath launched$" "$H/logs/$P.log" && ok || bad "(A8) GitHub: outcome and line as before [$(col 77 7)]"

# ═══ K: the switch off — the pre-BH-9113 record ═════════════════════════════
newp k; listed
export TRIAGE_STARVE_INAPP_LAUNCH=0
three
unset TRIAGE_STARVE_INAPP_LAUNCH
[ "$(rbcalls)" = 0 ] && [ "$(col t624 7)" = "n/a: in-app board" ] && ok || bad "(K) TRIAGE_STARVE_INAPP_LAUNCH=0: n/a, no launch [$(rbcalls) $(col t624 7)]"
[ "$(alerts)" = 1 ] && ok || bad "(K) the alert still fires [$(alerts)]"
jq -e '.env == "TRIAGE_STARVE_INAPP_LAUNCH" and .default == 1' "$DIR/catalog/lanes.d/_lib.triage-starve.knobs.d/TRIAGE_STARVE_INAPP_LAUNCH.json" >/dev/null 2>&1 && ok || bad "(K) the knob has a row in catalog/lanes.d/_lib.triage-starve.knobs.d/TRIAGE_STARVE_INAPP_LAUNCH.json"

# ═══ M: a row stamped before the rescue existed ═════════════════════════════
newp m; listed
export TRIAGE_STARVE_INAPP_LAUNCH=0
three
unset TRIAGE_STARVE_INAPP_LAUNCH
[ "$(col t624 7)" = "n/a: in-app board" ] && [ "$(rbcalls)" = 0 ] || bad "(M) setup: the old row holds n/a and no launch [$(col t624 7)] [$(rbcalls)]"
pass $((3*HR))
[ "$(rbcalls)" = 1 ] && ok || bad "(M) an old n/a row gets one launch once the switch is on [$(rbcalls)]"
[ "$(col t624 7)" = launched ] && ok || bad "(M) the ledger records launched: [$(col t624 7)]"
newp m2; listed
export TRIAGE_STARVE_INAPP_LAUNCH=0
three; pass $((3*HR))
unset TRIAGE_STARVE_INAPP_LAUNCH
[ "$(rbcalls)" = 0 ] && ok || bad "(M2) with the switch off an old n/a row stays without a launch [$(rbcalls)]"

# ═══ R1: round-trip ═════════════════════════════════════════════════════════
newp r1; world todo ready requester; listed; three; pass $((3*HR)); pass $((4*HR))
[ "$(led | awk -F'\t' 'NF!=8' | wc -l)" = 0 ] && [ "$(led | grep -c .)" = 1 ] && ok || bad "(R1) one row of 8 columns: [$(led)]"
[ "$(col t624 4)|$(col t624 6)|$(col t624 7)|$(col t624 8)" = "5|$((NOW + 2*HR))|declined: waitingOn=requester|1" ] \
  && ok || bad "(R1) the outcome survives two more passes: [$(led)]"

# ═══ V ══════════════════════════════════════════════════════════════════════
[ ! -s "$T/calls/vendor" ] && ok || bad "(V) 0 vendor calls: [$(cat "$T/calls/vendor")]"

echo "triage-starve-inapp.bh-9113: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
