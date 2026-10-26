#!/bin/bash
# tests/triage-starve.bh-8475-test.sh — BH-8475: the triage starvation guard
# (bin/lib/triage-starve.sh, hooked in bin/lib/triage-state.sh ts_tick).
# project-6-os TK-2601 was listed "to the model" on every enforce pass for 27 h
# and no shard ran for it.
#
#   T1-T3      the fastpath trigger fires (passes >= N AND age >= window, no run)
#   N1-N7      near misses: no fastpath call (N3b: an out file from an earlier
#              episode is not a run, so it DOES trigger)
#   B F1       acceptance (b): one fastpath call, the decline logged with its reason
#   A1-A3      the alert: none on a first pass, one line for six keys; the per-pass cap
#   E1-E7 I1   exit paths: knob off, corrupt ledger, lock busy, no fastpath,
#              builds pause, lane-alert fails, fastpath times out; in-app board
#   R1         ledger round-trip through every writer and reader
#   K2         the env knob moves the trigger
#   O1-O6      tsv_order_scope: hotfix first, oldest first, ties keep the scope
#              order, other lines after, no ledger = input, same multiset
#   S1 S2      acceptance (a): ts_tick + the real, unedited rt_shards with a cap
#              of 2 dispatch the oldest key; a hotfix key still goes first
#   P1-P3 K1   the ts_tick hook: enforce writes, unreadable rows and shadow do
#              not, a $0-end tick still counts the pass
#   V          acceptance (c): 0 model and 0 GitHub calls
#
# Run from anywhere: tests/triage-starve.bh-8475-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

LIB="$DIR/bin/lib/triage-starve.sh"
[ -r "$LIB" ] && ok || bad "bin/lib/triage-starve.sh must exist"
export HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1
unset TRIAGE_STARVE_PASSES TRIAGE_STARVE_WINDOW_S TRIAGE_STARVE_FASTPATH_MAX TRIAGE_STARVE_FASTPATH_TIMEOUT_S \
      TRIAGE_STARVE_LOCK_WAIT_S STUB_DECLINE STUB_ALERT_RC STUB_RC

# ── vendor recorders: any call is a failure (V); timeout records its bound ───
mkdir -p "$T/rbin" "$T/calls"
for v in gh claude curl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls/vendor"\nexit 1\n' "$v" "$T" > "$T/rbin/$v"
done
REAL_TIMEOUT=$(command -v timeout)
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/calls/timeout"\nexec %s "$@"\n' "$T" "$REAL_TIMEOUT" > "$T/rbin/timeout"
chmod +x "$T/rbin/"*
export PATH="$T/rbin:$PATH"

# ── the scratch harness: stub fastpath, lane-alert, triage-gate, triage-shard ─
H="$T/h"
mkdir -p "$H/bin/lib/rt" "$H/logs" "$H/state" "$H/locks"
cat > "$H/bin/launch-fastpath.sh" <<STUB
#!/bin/bash
p="\$1"; shift
printf '%s\n' "\$p \$*" >> "$T/calls/fastpath-\$p"
for k in "\$@"; do
  case " \${STUB_DECLINE:-} " in
    *" \$k "*) printf '%s [%s] FASTPATH-DECLINED %s :: stub: open PR #99\n' now "\$p" "\$k" >> "\$HARNESS/logs/\$p.log"
               printf '%s\n' "\$k"; rc=1 ;;
  esac
done
exit \${STUB_RC:-\${rc:-0}}
STUB
cat > "$H/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/alert"
exit \${STUB_ALERT_RC:-0}
STUB
cat > "$H/bin/alert-line.sh" <<'STUB'
#!/bin/bash
while [ "${1#--}" != "$1" ]; do shift 2; done
printf 'now %s\n' "$*" >> "$HARNESS/logs/ALERTS.log"
STUB
cat > "$H/bin/triage-gate.sh" <<'STUB'
#!/bin/bash
[ "${2:-}" = --buildable ] && { echo OK; exit 0; }
exit 0
STUB
cat > "$H/bin/triage-shard.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$2" >> "$T/calls/shard-\$1"
STUB
chmod +x "$H/bin/"*.sh
# The lib under test, where ts_tick's hook looks for it ($HARNESS/bin/lib), and
# triage_shard_key, which ts_tick and tsv_order_scope load from there too.
scratch_install_closure bin/lib/triage-starve.sh "$H" >/dev/null || bad "install bin/lib/triage-starve.sh"
scratch_install_closure bin/lib/triage-shards-lib.sh "$H" >/dev/null || bad "install bin/lib/triage-shards-lib.sh"
export HARNESS="$H"

NOW=1790000000
HR=3600
# newp <case> [inapp] — a fresh project id for the case; GitHub board by default
newp() {
  P="starve-$1-$$"
  mkdir -p "$H/state/triage-state/$P"
  if [ "${2:-}" = inapp ]; then echo '{"meta":{}}' > "$H/state/triage-state/$P/world.json"
  else echo '{"issues":[],"meta":{}}' > "$H/state/triage-state/$P/world.json"; fi
}
# listed <key...> — this pass's decisions.tsv: each key `llm new`, label ST-<key>
# (the ts_precheck format: key label decision reason hash seed in-scope base
# work). A key written `k:skip` is `skip deferred:cap`, `k:enq` is `enqueue`.
listed() {
  local f="$H/state/triage-state/$P/decisions.tsv" k
  : > "$f"
  for k in "$@"; do
    case "$k" in
      *:skip) printf '%s\tST-%s\tskip\tdeferred:cap\th\t-\t1\t-\t0\n' "${k%:skip}" "${k%:skip}" >> "$f" ;;
      *:enq) printf '%s\tST-%s\tenqueue\tbuildable\th\t-\t1\t-\t0\n' "${k%:enq}" "${k%:enq}" >> "$f" ;;
      *) printf '%s\tST-%s\tllm\tnew\th\t-\t1\t-\t0\n' "$k" "$k" >> "$f" ;;
    esac
  done
}
# pass <offset-s> — one tsv_pass at NOW+offset in a fresh process (one tick)
pass() {
  local off="$1"
  ( export TSV_NOW=$((NOW + off)); LOG="$H/logs/$P.log"; STAMP="t+$off"
    # shellcheck source=/dev/null
    . "$LIB" || exit 0
    tsv_pass "$H" "$P"
    exit 0 ) 2>/dev/null
}
# ran <key> <offset-s> — a shard ran for <key> at NOW+offset: its out file
# (bin/triage-shard.sh writes logs/<p>.triage-<KEY>.out at launch)
ran() { touch -d "@$((NOW + $2))" "$H/logs/$P.triage-$1.out"; }
fpcalls() { local n; n=$(grep -c . "$T/calls/fastpath-$P" 2>/dev/null); printf '%s' "${n:-0}"; }
alerts()  { local n; n=$(grep -c -- "--id triage-starve-$P " "$T/calls/alert" 2>/dev/null); printf '%s' "${n:-0}"; }
led()     { cat "$H/state/triage-state/$P/starve.tsv" 2>/dev/null; }
col()     { awk -F'\t' -v k="$1" -v c="$2" '$1==k {print $c}' "$H/state/triage-state/$P/starve.tsv" 2>/dev/null; }
# unhold <pid> — release a `flock <file> sleep` holder: the sleep child holds the lock too
unhold() { pkill -P "$1" 2>/dev/null; kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
lastlog() { grep "TRIAGE-STARVE" "$H/logs/$P.log" 2>/dev/null | tail -1; }

# ═══ T: the trigger fires ════════════════════════════════════════════════════
# T1 / acceptance (b): 3 passes at t0, +1h, +2h, no run, the stub declines.
newp b; listed 13
export STUB_DECLINE=ST-13
pass 0; pass $HR
[ "$(fpcalls)" = 0 ] && ok || bad "(B) no fastpath call before pass 3 [$(fpcalls)]"
pass $((2*HR))
[ "$(fpcalls)" = 1 ] && ok || bad "(T1/B) pass 3 over 2h with no run: fastpath called once [$(fpcalls)]"
[ "$(cat "$T/calls/fastpath-$P" 2>/dev/null)" = "$P ST-13" ] && ok || bad "(B) fastpath argv is <project> <label>: [$(cat "$T/calls/fastpath-$P" 2>/dev/null)]"
case "$(lastlog)" in *"TRIAGE-STARVE ST-13 listed 3 passes over 2.0h with no triage run — fastpath declined: stub: open PR #99") ok ;;
  *) bad "(B) the decline is logged with fastpath's own reason: [$(lastlog)]" ;; esac
[ "$(alerts)" = 1 ] && ok || bad "(B) one alert [$(alerts)]"
grep -- "--id triage-starve-$P " "$T/calls/alert" | grep -q -- "--severity warn" && ok || bad "(B) the alert is warn severity"
grep -- "--id triage-starve-$P " "$T/calls/alert" | grep -q "1 ticket(s) listed to the model past 2h with no triage run: ST-13=declined: stub: open PR #99" \
  && ok || bad "(B) the alert names the key and its outcome: [$(grep -- "triage-starve-$P " "$T/calls/alert")]"
[ "$(col 13 6)" = $((NOW + 2*HR)) ] && [ "$(col 13 7)" = "declined: stub: open PR #99" ] && [ "$(col 13 8)" = 1 ] \
  && ok || bad "(B) the ledger records the attempt, the outcome and the alert: [$(led)]"
[ "$(tail -1 "$T/calls/timeout" 2>/dev/null)" = 300 ] && ok || bad "(B) the call runs under timeout 300 (TRIAGE_STARVE_FASTPATH_TIMEOUT_S fallback): [$(tail -1 "$T/calls/timeout" 2>/dev/null)]"
# N4: passes 4 and 5 of the same episode: still one call, still one alert
pass $((3*HR)); pass $((4*HR))
[ "$(fpcalls)" = 1 ] && ok || bad "(N4/B) passes 4 and 5: still one fastpath call [$(fpcalls)]"
[ "$(alerts)" = 1 ] && ok || bad "(N4/B) passes 4 and 5: still one alert [$(alerts)]"
[ "$(col 13 4)" = 5 ] && ok || bad "(B) the pass counter keeps counting: [$(col 13 4)]"
unset STUB_DECLINE

# F1: the stub declines ST-13 and launches ST-14 — the log says exactly that
newp f1; listed 13 14
export STUB_DECLINE=ST-13
pass 0; pass $HR; pass $((2*HR))
[ "$(cat "$T/calls/fastpath-$P" 2>/dev/null)" = "$P ST-13 ST-14" ] && ok || bad "(F1) one call with both labels: [$(cat "$T/calls/fastpath-$P" 2>/dev/null)]"
grep -q "TRIAGE-STARVE ST-13 .* — fastpath declined: stub: open PR #99$" "$H/logs/$P.log" && ok || bad "(F1) ST-13 logged declined with its reason"
grep -q "TRIAGE-STARVE ST-14 .* — fastpath launched$" "$H/logs/$P.log" && ok || bad "(F1) ST-14 logged launched"
[ "$(col 14 7)" = launched ] && ok || bad "(F1) the ledger says 14 launched: [$(col 14 7)]"
unset STUB_DECLINE

# T2: 5 passes over 3h (45 min apart): the window is met at pass 4 (2h15m)
newp t2; listed 7
pass 0; pass 2700; pass 5400
[ "$(fpcalls)" = 0 ] && ok || bad "(T2) 3 passes over 1.5h: no call yet [$(fpcalls)]"
pass 8100; pass 10800
[ "$(fpcalls)" = 1 ] && ok || bad "(T2) 5 passes over 3h: one call [$(fpcalls)]"

# T3: listed, dropped, relisted: the new episode's 3 passes over 2h trigger
newp t3; listed 8
pass 0
listed; pass $HR
[ -z "$(col 8 1)" ] && ok || bad "(T3) a key that leaves the model set is dropped from the ledger: [$(led)]"
listed 8; pass $((2*HR)); pass $((3*HR)); pass $((4*HR))
[ "$(fpcalls)" = 1 ] && ok || bad "(T3) a relisted key's new episode triggers [$(fpcalls)]"
[ "$(col 8 3)" = $((NOW + 2*HR)) ] && ok || bad "(T3) first_listed is the relisting: [$(col 8 3)]"

# ═══ N: near misses ══════════════════════════════════════════════════════════
newp n1; listed 9
pass 0; pass 1800; pass $HR
[ "$(fpcalls)" = 0 ] && ok || bad "(N1) 3 passes over 1h: window not met, no call [$(fpcalls)]"
newp n2; listed 9
pass 0; pass $((3*HR))
[ "$(fpcalls)" = 0 ] && ok || bad "(N2) 2 passes over 3h: passes not met, no call [$(fpcalls)]"
# N3: a shard ran (its out file was written) after the key was first listed
newp n3; listed 9
pass 0; ran 9 1800; pass $HR; pass $((2*HR)); pass $((3*HR))
[ "$(fpcalls)" = 0 ] && ok || bad "(N3) a shard ran after first listed: no call [$(fpcalls)]"
[ "$(col 9 5)" = $((NOW + 1800)) ] && ok || bad "(N3) the out file's mtime is last_run: [$(col 9 5)]"
# N3b: the out file is from BEFORE this episode — not a run, it triggers
newp n3b; listed 9
ran 9 -600; pass 0; pass $HR; pass $((2*HR))
[ "$(fpcalls)" = 1 ] && ok || bad "(N3b) an out file older than first listed is not a run: one call [$(fpcalls)]"
[ "$(col 9 5)" = 0 ] && ok || bad "(N3b) last_run stays 0: [$(col 9 5)]"
# N3c: the shard lock is held right now — a run in flight
newp n3c; listed 9
pass 0; pass $HR
flock "$H/locks/triage-key-$P-9.lock" sleep 30 &
HOLDER=$!
for _ in $(seq 1 50); do flock -n "$H/locks/triage-key-$P-9.lock" true 2>/dev/null || break; sleep 0.1; done
pass $((2*HR))
unhold "$HOLDER"
[ "$(fpcalls)" = 0 ] && ok || bad "(N3c) a held shard lock counts as a run: no call [$(fpcalls)]"
[ "$(col 9 5)" = $((NOW + 2*HR)) ] && ok || bad "(N3c) the held lock stamps last_run now: [$(col 9 5)]"
newp n5; listed 10:skip 11:enq
pass 0; pass $HR; pass $((2*HR)); pass $((3*HR))
[ "$(fpcalls)" = 0 ] && ok || bad "(N5) skip deferred:cap and enqueue keys are never counted [$(fpcalls)]"
[ -z "$(led)" ] && ok || bad "(N5) a non-llm key has no ledger row: [$(led)]"
newp n6; listed 11
for i in 0 1 2 3 4; do pass $((i*HR)); done
[ "$(fpcalls)" = 1 ] && ok || bad "(N6) setup: the first episode triggered once [$(fpcalls)]"
listed; pass $((5*HR))
listed 11; pass $((6*HR)); pass $((9*HR))
[ "$(fpcalls)" = 1 ] && ok || bad "(N6) passes 1-2 of a new episode do not inherit the old one's 5 passes [$(fpcalls)]"
[ "$(col 11 4)" = 2 ] && [ "$(col 11 6)" = 0 ] && ok || bad "(N6) the new episode starts clean: [$(led)]"
# N7 / E1: the knob off — no write, no call
newp n7; listed 12
export TRIAGE_STARVE_PASSES=0
for i in 0 1 2 3; do pass $((i*HR)); done
[ "$(fpcalls)" = 0 ] && ok || bad "(N7) TRIAGE_STARVE_PASSES=0: no call [$(fpcalls)]"
[ ! -e "$H/state/triage-state/$P/starve.tsv" ] && ok || bad "(E1) TRIAGE_STARVE_PASSES=0: no ledger written"
unset TRIAGE_STARVE_PASSES

# K2: the env knob moves the trigger to pass 4
newp k2; listed 12
export TRIAGE_STARVE_PASSES=4
pass 0; pass 5400; pass $((3*HR))
[ "$(fpcalls)" = 0 ] && ok || bad "(K2) PASSES=4: 3 passes over 3h do not trigger [$(fpcalls)]"
pass $((4*HR))
[ "$(fpcalls)" = 1 ] && ok || bad "(K2) PASSES=4: pass 4 triggers [$(fpcalls)]"
unset TRIAGE_STARVE_PASSES

# ═══ A: the alert ════════════════════════════════════════════════════════════
newp a1; listed $(seq 101 140)
pass 0
[ "$(fpcalls)" = 0 ] && [ "$(alerts)" = 0 ] && ok || bad "(A1) a first pass with 40 listed keys: 0 calls, 0 alerts [$(fpcalls)/$(alerts)]"
[ "$(led | grep -c .)" = 40 ] && ok || bad "(A1) 40 rows, all at passes 1: [$(led | grep -c .)]"
newp a2; listed 21 22 23 24 25 26
pass 0; pass $HR; pass $((2*HR))
[ "$(alerts)" = 1 ] && ok || bad "(A2) six keys cross together: one alert line [$(alerts)]"
grep -- "--id triage-starve-$P " "$T/calls/alert" | grep -q "6 ticket(s) listed" && ok || bad "(A2) the alert names 6 tickets"
[ "$(fpcalls)" = 1 ] && [ "$(wc -w < "$T/calls/fastpath-$P")" = 7 ] && ok || bad "(A2) one fastpath call with 6 keys: [$(cat "$T/calls/fastpath-$P" 2>/dev/null)]"
# A3: FASTPATH_MAX bounds one pass's argv: oldest first, the rest next pass
newp a3; listed 31; pass 0; listed 31 32; pass 300; listed 31 32 33; pass 600; pass $HR
export TRIAGE_STARVE_FASTPATH_MAX=2
pass $((2*HR + 600)); pass $((2*HR + 700))
[ "$(sed -n 1p "$T/calls/fastpath-$P")" = "$P ST-31 ST-32" ] && [ "$(sed -n 2p "$T/calls/fastpath-$P")" = "$P ST-33" ] \
  && ok || bad "(A3) FASTPATH_MAX=2: oldest two first, the third next pass: [$(tr '\n' '|' < "$T/calls/fastpath-$P")]"
unset TRIAGE_STARVE_FASTPATH_MAX

# ═══ E: exit paths ═══════════════════════════════════════════════════════════
# E2: a corrupt ledger is rebuilt, a good row survives, one log line
newp e2; listed 41 42
pass 0
grep -v '^42	' "$H/state/triage-state/$P/starve.tsv" > "$T/e2.tsv"
printf 'garbage line\n42\tST-42\tnotanumber\t1\t0\t0\t-\t0\n' >> "$T/e2.tsv"
mv "$T/e2.tsv" "$H/state/triage-state/$P/starve.tsv"
pass 600
[ "$(col 41 4)" = 2 ] && [ "$(col 41 3)" = "$NOW" ] && ok || bad "(E2) the good row survives the bad ones: [$(led)]"
[ "$(col 42 4)" = 1 ] && ok || bad "(E2) a malformed row restarts at passes=1: [$(col 42 4)]"
grep -q "TRIAGE-STARVE: 2 malformed ledger row(s) in starve.tsv dropped" "$H/logs/$P.log" && ok || bad "(E2) one log line names the rebuild"
# E3: the lock is busy — the pass is skipped, the ledger unchanged
newp e3; listed 43
pass 0
flock "$H/state/triage-state/$P/starve.lock" sleep 6 &
HOLDER=$!
for _ in $(seq 1 50); do flock -n "$H/state/triage-state/$P/starve.lock" true 2>/dev/null || break; sleep 0.1; done
export TRIAGE_STARVE_LOCK_WAIT_S=1
pass 600
[ "$(col 43 4)" = 1 ] && ok || bad "(E3) a busy lock moves no counter: [$(col 43 4)]"
grep -q "TRIAGE-STARVE: ledger lock busy for 1s — this pass is not counted" "$H/logs/$P.log" && ok || bad "(E3) one log line names the busy lock"
unhold "$HOLDER"
unset TRIAGE_STARVE_LOCK_WAIT_S
# E4: no executable fastpath — recorded n/a, the alert still fires
H2="$T/h2"; mkdir -p "$H2/bin" "$H2/logs" "$H2/state/triage-state"
cp "$H/bin/lane-alert.sh" "$H2/bin/"
( H="$H2"; HARNESS="$H2"; newp e4; listed 44
  pass 0; pass $HR; pass $((2*HR))
  [ "$(col 44 7)" = "n/a: fastpath not executable" ] && echo OK7 || echo "BAD7 $(led)"
  case "$(lastlog)" in *"— n/a: fastpath not executable") echo OKL ;; *) echo "BADL $(lastlog)" ;; esac
  [ "$(alerts)" = 1 ] && echo OKA || echo "BADA $(alerts)" ) > "$T/e4.out"
grep -qx OK7 "$T/e4.out" && ok || bad "(E4) no fastpath: outcome n/a: [$(grep BAD7 "$T/e4.out")]"
grep -qx OKL "$T/e4.out" && ok || bad "(E4) no fastpath: logged n/a: [$(grep BADL "$T/e4.out")]"
grep -qx OKA "$T/e4.out" && ok || bad "(E4) no fastpath: the alert still fires: [$(grep BADA "$T/e4.out")]"
# E5: a live builds pause withholds the attempt, marks nothing, alerts nothing
newp e5; listed 45
pause_active() { [ "$1" = "$P" ] && [ "$2" = builds ]; }
export -f pause_active
pass 0; pass $HR; pass $((2*HR))
[ "$(fpcalls)" = 0 ] && [ "$(alerts)" = 0 ] && ok || bad "(E5) a builds pause: no call, no alert [$(fpcalls)/$(alerts)]"
[ "$(col 45 6)" = 0 ] && ok || bad "(E5) a withheld key is not marked tried: [$(col 45 6)]"
grep -q "TRIAGE-STARVE withheld ST-45: builds pause" "$H/logs/$P.log" && ok || bad "(E5) one withheld log line"
unset -f pause_active
pass $((2*HR + 600))
[ "$(fpcalls)" = 1 ] && [ "$(alerts)" = 1 ] && ok || bad "(E5) the pause lifted: the next pass tries once [$(fpcalls)/$(alerts)]"
# E6: lane-alert fails — one ALERTS.log line, alerted=1, no retry next pass
newp e6; listed 46
export STUB_ALERT_RC=1
pass 0; pass $HR; pass $((2*HR)); pass $((3*HR))
[ "$(grep -c "\[$P\] triage starvation: bin/lane-alert.sh did not run" "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "(E6) a failed lane-alert writes one ALERTS.log line"
[ "$(col 46 8)" = 1 ] && [ "$(alerts)" = 1 ] && ok || bad "(E6) alerted=1, no retry loop [$(col 46 8)/$(alerts)]"
unset STUB_ALERT_RC
# E7: fastpath times out (rc 124) — one attempt spent, recorded as the exit code
newp e7; listed 47
export STUB_RC=124 TRIAGE_STARVE_FASTPATH_TIMEOUT_S=45
pass 0; pass $HR; pass $((2*HR)); pass $((3*HR))
[ "$(fpcalls)" = 1 ] && ok || bad "(E7) a timed-out call is not retried [$(fpcalls)]"
[ "$(col 47 7)" = "declined: fastpath exit 124" ] && ok || bad "(E7) outcome names the exit code: [$(col 47 7)]"
[ "$(tail -1 "$T/calls/timeout" 2>/dev/null)" = 45 ] && ok || bad "(E7) the timeout knob is the bound: [$(tail -1 "$T/calls/timeout" 2>/dev/null)]"
unset STUB_RC TRIAGE_STARVE_FASTPATH_TIMEOUT_S
# I1: an in-app board gets the alert and no fastpath call
newp i1 inapp; listed 48
pass 0; pass $HR; pass $((2*HR))
[ "$(fpcalls)" = 0 ] && [ "$(alerts)" = 1 ] && ok || bad "(I1) in-app: no fastpath, one alert [$(fpcalls)/$(alerts)]"
[ "$(col 48 7)" = "n/a: in-app board" ] && ok || bad "(I1) in-app: outcome n/a: [$(col 48 7)]"

# ═══ R1: round-trip ══════════════════════════════════════════════════════════
newp r1; listed 51 52
pass 0; ran 51 10
pass 20
[ "$(led | awk -F'\t' 'NF!=8' | wc -l)" = 0 ] && [ "$(led | grep -c .)" = 2 ] && ok || bad "(R1) 2 rows of 8 columns: [$(led)]"
[ "$(col 51 2)|$(col 51 3)|$(col 51 4)|$(col 51 5)|$(col 51 6)|$(col 51 7)|$(col 51 8)" = "ST-51|$NOW|2|$((NOW + 10))|0|-|0" ] \
  && ok || bad "(R1) every column survives a run and a second pass: [$(led | grep '^51')]"
[ "$(col 52 5)" = 0 ] && ok || bad "(R1) the out file marked only its key"
# tsv_ran_all (a full tick's single session) marks every row
( export TSV_NOW=$((NOW + 40)); . "$LIB"; tsv_pass "$H" "$P"; tsv_ran_all "$H" "$P" ) 2>/dev/null
[ "$(col 52 5)" = $((NOW + 40)) ] && [ "$(col 51 5)" = $((NOW + 40)) ] && ok || bad "(R1) tsv_ran_all marks every row: [$(led)]"
pass 60
[ "$(col 52 5)" = $((NOW + 40)) ] && [ "$(col 52 4)" = 4 ] && ok || bad "(R1) a later pass keeps tsv_ran_all's mark: [$(led)]"

# ═══ O: tsv_order_scope ══════════════════════════════════════════════════════
bline() { local k; for k in "$@"; do printf 'board changed: NEW ST-%s "ticket %s"\n' "$k" "$k"; done; }
# order <scope text> — tsv_order_scope over <scope text>; lines joined by |
order() {
  ( export TSV_NOW=$((NOW + 5*HR + 1)); LOG="$H/logs/$P.log"
    . "$LIB" || exit 0
    printf '%s\n' "$1" | tsv_order_scope "$H" "$P" | tr '\n' '|' ) 2>/dev/null
}
sdec() { # sdec <n...> — decisions.tsv for in-app keys ST-<n>
  local f="$H/state/triage-state/$P/decisions.tsv" k; : > "$f"
  for k in "$@"; do printf 'ST-%s\tST-%s\tllm\tnew\th\t-\t1\t-\t0\n' "$k" "$k" >> "$f"; done
}
newp o inapp; sdec 1; pass 0
sdec 1 2 3 4; pass $((5*HR))
O=$(order "$(bline 2)
[HOTFIX] $(bline 3)
$(bline 1)")
[ "$O" = "[HOTFIX] $(bline 3)|$(bline 1)|$(bline 2)|" ] && ok || bad "(O1) a young hotfix line goes before an older plain line: [$O]"
O=$(order "$(bline 2 1)")
[ "$O" = "$(bline 1)|$(bline 2)|" ] && ok || bad "(O2) the oldest listed key goes first: [$O]"
O=$(order "$(bline 3 2 4)")
[ "$O" = "$(bline 3)|$(bline 2)|$(bline 4)|" ] && ok || bad "(O3) equal ages keep the scope order: [$O]"
O4IN="board prs: NEW 77 \"pr\"
$(bline 9)
$(bline 2)
board gate: REOFFER ST-8 \"x\"
board changed: UNBLOCKED ST-7 \"y\"
$(bline 1)"
O=$(order "$O4IN")
[ "$O" = "$(bline 1)|$(bline 2)|board prs: NEW 77 \"pr\"|$(bline 9)|board gate: REOFFER ST-8 \"x\"|board changed: UNBLOCKED ST-7 \"y\"|" ] \
  && ok || bad "(O4) aged keys first; prs/REOFFER/UNBLOCKED and unknown keys after, in order, none dropped: [$O]"
[ "$(printf '%s' "$O" | tr '|' '\n' | sort)" = "$(printf '%s\n' "$O4IN" | sort)" ] && ok || bad "(O6) the same multiset of lines in and out"
newp o5 inapp
O=$( ( . "$LIB"; printf '%s\n' "$(bline 2 1)" | tsv_order_scope "$H" "$P" | tr '\n' '|' ) 2>/dev/null )
[ "$O" = "$(bline 2)|$(bline 1)|" ] && ok || bad "(O5) no ledger: the input order exactly [$O]"
O=$( ( export TRIAGE_STARVE_PASSES=0; . "$LIB"; printf '%s\n' "$(bline 2 1)" | tsv_order_scope "$H" "o" | tr '\n' '|' ) 2>/dev/null )
[ "$O" = "$(bline 2)|$(bline 1)|" ] && ok || bad "(O5) knob off: the input order exactly [$O]"

# ═══ S: ts_tick + the real shard loop (acceptance a) ═════════════════════════
# The scratch tree's bin/lib/triage-state.sh is the real lib with ts_precheck
# stubbed to the state it leaves (enforce, rows readable, the model set read
# from decisions.tsv). rt_shards sources it and calls ts_tick exactly as in
# production, so the BH-8475 hook in ts_tick runs from the real file.
cat > "$H/bin/lib/triage-state.sh" <<EOF
. "$DIR/bin/lib/triage-state.sh"
ts_precheck() {
  local f="\$HARNESS/state/triage-state/\$PROJECT/decisions.tsv"
  TS_MODE=enforce; TS_READY=1; TS_ROWS_OK=1; TS_SKIPSET=" "; TS_ENQ=""; TS_SUMMARY="[stub]"
  TS_LLM=\$(awk -F'\t' '\$3=="llm"{printf " %s", \$2}' "\$f"); TS_LLM_KEYS=\$(awk -F'\t' '\$3=="llm"{printf " %s", \$1}' "\$f")
}
ts_pr_precheck() { :; }; ts_rows_unreadable_tick() { return 1; }; ts_enqueue() { TS_LAUNCHED=""; }
ts_waste_account() { :; }; ts_waste_bracket() { :; }; ts_shard_hash() { :; }
EOF
# shards <offset> <max> <scope lines> — one tick through the real rt_shards
# with a cap of <max>. The keys the stub shard runner got land in calls/shard-<P>.
shards() {
  local off="$1" max="$2" scope="$3"
  ( set +u
    export TSV_NOW=$((NOW + off))
    PROJECT=$P; STAMP="t+$off"; LOG="$H/logs/$P.log"; ALERTS="$H/logs/ALERTS.log"
    GATE_DECISION="RUN board-changed"; GATE_REASON=board-changed; SCOPE_N=1
    TICK_SCOPE="$scope"; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; JOB_ID=""; PROMPT_TEXT="SOP"
    TRIAGE_MODEL=m; SHARD_SOP="SOP"; EFFECTIVE_GROK_EFFORT=""
    LANE_TICK() { :; }; rt_gate_consume() { :; }
    . "$DIR/bin/lib/triage-shards-lib.sh"
    triage_shards_on() { echo 1; }; triage_shard_gh() { echo 0; }; triage_shard_fp_ttl() { echo 0; }
    triage_shards_max() { echo "$max"; }; triage_caps_on() { echo 0; }
    triage_shard_rearm() { :; }; triage_throttle_record() { :; }
    lock_spawn_unheld() { "$@"; }
    . "$DIR/bin/lib/rt/shards.sh"
    rt_shards ) >/dev/null 2>&1
}
dispatched() { tr '\n' ' ' < "$T/calls/shard-$P" 2>/dev/null; }
# s1 — ST-1 first listed 5 h ago, then three ticks; each tick the two newest
# keys arrive at the FRONT of the scope and the keys a shard took leave the
# model set.
s1() {
  sdec 1; pass $((-5*HR))
  local cur="6 5 4 3 2 1" next=7 i k got
  for i in 1 2 3; do
    # shellcheck disable=SC2086
    sdec $cur
    # shellcheck disable=SC2086
    shards $((i*600)) 2 "$(bline $cur)"
    got=$(sed -n "$((2*i-1)),$((2*i))p" "$T/calls/shard-$P" 2>/dev/null | tr '\n' ' ')
    printf 'pass%s: %s\n' "$i" "$got"
    for k in $got; do cur=$(printf '%s\n' $cur | grep -vx "${k#ST-}" | tr '\n' ' '); done
    cur="$((next+1)) $next $cur"; next=$((next+2))
  done
}
newp s1 inapp; S1=$(s1)
grep -q "ST-1 " <<<"$(dispatched)" && ok || bad "(S1) cap 2, 6 listed: the oldest key ST-1 is dispatched within 3 passes [$S1]"
[ "$(grep -c . "$T/calls/shard-$P" 2>/dev/null)" = 6 ] && ok || bad "(S1) the cap still holds: 2 shards per pass, 6 in 3 passes [$(dispatched)]"
[ "$(head -1 "$T/calls/shard-$P" 2>/dev/null)" = ST-1 ] && ok || bad "(S1) the oldest key is the first one dispatched [$S1]"
[ "$(led | grep -c .)" = 6 ] && ok || bad "(S1) ts_tick wrote the ledger: one row per listed key [$(led)]"
# S1 control: the guard off — the scope order never reaches ST-1 in 3 passes
newp s1c inapp; S1C=$(export TRIAGE_STARVE_PASSES=0; s1)
grep -q "ST-1 " <<<"$(dispatched)" && bad "(S1 control) with the guard off the scope order must not reach ST-1 in 3 passes [$S1C]" || ok
[ "$(grep -c . "$T/calls/shard-$P" 2>/dev/null)" = 6 ] && ok || bad "(S1 control) the control dispatched 2 per pass [$(dispatched)]"
# S2: a young hotfix key still goes before the old key
newp s2 inapp
sdec 1; pass $((-5*HR))
sdec 1 2 9
shards 600 2 "[HOTFIX] $(bline 9)
$(bline 2 1)"
[ "$(dispatched)" = "ST-9 ST-1 " ] && ok || bad "(S2) hotfix first, then the oldest: [$(dispatched)]"

# ═══ P/K: the ts_tick hook ═══════════════════════════════════════════════════
# tick <mode> <rows-ok> <scope-n> [gate] [scope] — the real ts_tick with
# ts_precheck stubbed to the state it leaves (decisions.tsv seeded by `listed`).
tick() {
  local m="$1" r="$2"
  ( set +u
    export TSV_NOW=$((NOW + 60))
    PROJECT=$P; STAMP=t; LOG="$H/logs/$P.log"; ALERTS="$H/logs/ALERTS.log"
    GATE_REASON="${4:-daily-sweep}"; SCOPE_N="$3"; TICK_SCOPE="${5:-}"; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; PROMPT_TEXT="SOP"
    LANE_TICK() { :; }; rt_gate_consume() { :; }
    . "$DIR/bin/lib/triage-state.sh"
    ts_precheck() { TS_MODE="$m"; TS_READY=1; TS_ROWS_OK="$r"; TS_LLM=" ST-61"; TS_LLM_KEYS=" 61"; TS_SKIPSET=" "; }
    ts_pr_precheck() { :; }; ts_rows_unreadable_tick() { return 1; }; ts_enqueue() { TS_LAUNCHED=""; }
    ts_waste_account() { :; }; ts_waste_bracket() { :; }
    ts_tick; echo "ts_tick returned" ) 2>/dev/null
}
newp p1; listed 61
tick enforce 1 full >/dev/null
[ "$(col 61 4)" = 1 ] && [ "$(col 61 3)" = $((NOW + 60)) ] && ok || bad "(P1) ts_tick under enforce writes starve.tsv with the llm keys: [$(led)]"
[ "$(col 61 5)" = $((NOW + 60)) ] && ok || bad "(P1) a full tick's single session marks every listed key run: [$(col 61 5)]"
newp p1s; listed 61
tick enforce 1 1 board-changed "$(bline 61)" >/dev/null
[ "$(col 61 4)" = 1 ] && [ "$(col 61 5)" = 0 ] && ok || bad "(P1) a scoped tick counts the pass and marks no run: [$(led)]"
newp k1; listed 61
tick shadow 1 full >/dev/null
[ ! -e "$H/state/triage-state/$P/starve.tsv" ] && ok || bad "(K1) a shadow tick writes no ledger"
newp p2; listed 61
tick enforce 0 full >/dev/null
[ ! -e "$H/state/triage-state/$P/starve.tsv" ] && ok || bad "(P2) unreadable rows: no ledger written"
# P3: a scoped tick whose scope names no listed key ends at $0 — after the pass is counted
newp p3; listed 61
P3=$(tick enforce 1 1 board-changed "$(bline 99)")
case "$P3" in *"ts_tick returned"*) bad "(P3) setup: the tick must take the \$0-end exit" ;; *) ok ;; esac
[ "$(col 61 4)" = 1 ] && ok || bad "(P3) a \$0-end tick still counts the pass: [$(led)]"

# ═══ V: acceptance (c) ═══════════════════════════════════════════════════════
[ ! -s "$T/calls/vendor" ] && ok || bad "(V) 0 model and 0 GitHub calls: [$(cat "$T/calls/vendor")]"

echo "triage-starve.bh-8475: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
