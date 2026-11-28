#!/bin/bash
# tests/triage-ready-now.bh-10236-test.sh — BH-10236 (ticket rows): a READY
# ticket on an in-app board is owed a build on THIS pass, not after a wait.
#
# project-3, 2026-11-26: about 25 tickets were todo + triageVerdict ready +
# waitingOn team, with free locks and no build, while the pool ran 1 build.
# Each one sat in the triage-state model set and waited for a model shard to
# say `launch` (about 3 minutes a shard, one at a time). The starvation guard
# (BH-9113) launches such a ticket only after 3 passes and 2 hours.
# tsv_ready_pass (bin/lib/triage-starve.sh) launches it on the first pass,
# through the same guarded attempt (_tsv_inapp_try: the triage-state launch
# guard _ts_owned, then bin/run-build.sh), with no model call.
#
#   R1  5 ready, unchanged tickets, cap 3: 3 launch on pass 1 (oldest in the
#       decisions order first), 2 on pass 2; no key waits for a third pass
#   R2  the capped keys are written to deferred.keys, so the gate runs the
#       next tick (step 1d) and no re-read timer applies
#   R3  one launch per (ticket, input hash): 3 more passes add 0 launches
#   R4  a ticket that is not ready is not owed: needs_clarification, waiting on
#       the client, paused, in_progress
#   R5  each guard still declines, and the line says why: an open PR, a hold
#       from triage-gate.sh --buildable-strict
#   R6  ONE line per pass: `READY-NOW owed N, launched M ...; waited: ...`
#   R7  a launched key joins the tick's skip set (TSV_READY_KEYS): no model
#       shard is bought for it
#   R8  a live builds pause: 0 launches, one line
#   R9  a GitHub board: nothing (bin/launch-fastpath.sh and U13-STARVE own it)
#   K1  TRIAGE_READY_NOW=0: nothing. K2 TRIAGE_STARVE_INAPP_LAUNCH=0: nothing.
#   K3  the 2 knobs are registered
#   V   0 vendor calls
#
# MUTATIONS this suite must catch (each makes at least one case red):
#   M1 ignore the cap                                   -> R1
#   M2 launch a ticket whose verdict is not ready       -> R4
#   M3 skip the launch guard                            -> R5
#   M4 launch again on the same input hash              -> R3
#   M5 do not carry the capped keys to the next tick    -> R2
#   M6 ignore TRIAGE_READY_NOW=0                        -> K1
# The clock is TSV_NOW. Each case has its own project dir.
# Run from anywhere: tests/triage-ready-now.bh-10236-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # the launch is detached: wait for its record, never read it at once
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

LIB="$DIR/bin/lib/triage-starve.sh"
export HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1
unset TRIAGE_STARVE_PASSES TRIAGE_STARVE_WINDOW_S TRIAGE_STARVE_FASTPATH_MAX TRIAGE_STARVE_INAPP_LAUNCH \
      TRIAGE_READY_NOW TRIAGE_READY_NOW_MAX STUB_GATE TRIAGE_GH_SLUG

mkdir -p "$T/rbin" "$T/calls"
for v in gh claude curl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls/vendor"\nexit 1\n' "$v" "$T" > "$T/rbin/$v"
done
printf '#!/bin/bash\nexec "$@"\n' > "$T/rbin/setsid"
chmod +x "$T/rbin/"*
export PATH="$T/rbin:$PATH"

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
for s in launch-fastpath lane-alert alert-line; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$s.sh"; done
chmod +x "$H/bin/"*.sh
export HARNESS="$H"
NOW=1790000000

newp() { P="ready-$1-$$"; mkdir -p "$H/state/triage-state/$P"; echo '[]' > "$H/state/triage-state/$P/prs.json"; : > "$H/state/triage-state/$P/rows.jsonl"; }
# tk <id> <key> <status> <verdict> <waitingOn> — one board ticket; flush writes the snapshot
tk() { jq -nc --arg id "$1" --arg key "$2" --arg st "$3" --arg v "$4" --arg w "$5" '{id:$id, key:$key, status:$st, triageVerdict:$v, waitingOn:$w}' >> "$H/state/triage-state/$P/rows.jsonl"; }
flush() { jq -sc '{b1: ., meta: {}}' "$H/state/triage-state/$P/rows.jsonl" > "$H/state/triage-state/$P/world.json"; }
listed() { # listed <id:key>... — this pass's decisions.tsv, each key `llm changed`
  local f="$H/state/triage-state/$P/decisions.tsv" a; : > "$f"
  for a in "$@"; do printf '%s\t%s\tllm\tchanged\th-%s\t-\t1\t-\t0\n' "${a%%:*}" "${a#*:}" "${a%%:*}" >> "$f"; done
}
five() {
  local i
  for i in 1 2 3 4 5; do tk "t90$i" "TK-90$i" todo ready team; done; flush
  listed t901:TK-901 t902:TK-902 t903:TK-903 t904:TK-904 t905:TK-905
}
# pass <offset-s> [env...] — one tsv_ready_pass at NOW+offset in a fresh
# process, the triage-state libs loaded as ts_tick has them. Prints TSV_READY_KEYS.
pass() {
  local off="$1" out k; shift
  out=$(_pass_once "$off" "$@")
  # run-build.sh is started detached (_ts_spawn_build). On a loaded or traced CI
  # shard its record lands after this function returns: the merge queue saw
  # "R4 ... expected 'TK-5', got ''" 2 times. Wait for the record of each
  # launched key before any assertion reads it.
  for k in $out; do
    [ "$k" = NO-FUNCTION ] && continue
    wait_for 20 grep -qw -- "$k" "$T/calls/runbuild-$P"
  done
  printf '%s' "$out"
}
_pass_once() {
  local off="$1"; shift
  ( for a in "$@"; do export "${a?}"; done
    export TSV_NOW=$((NOW + off)); LOG="$H/logs/$P.log"; STAMP="t+$off"; TS_MODE=enforce
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/triage-state.sh" && . "$DIR/bin/lib/triage-state-pr.sh" || exit 0
    # shellcheck source=/dev/null
    . "$LIB" || exit 0
    declare -F tsv_ready_pass >/dev/null || { echo "NO-FUNCTION"; exit 0; }
    tsv_ready_pass "$H" "$P"
    printf '%s' "${TSV_READY_KEYS:-}"
    exit 0 ) 2>/dev/null
}
rbcalls() { local n; n=$(grep -c . "$T/calls/runbuild-$P" 2>/dev/null); printf '%s' "${n:-0}"; }
built() { awk '{print $3}' "$T/calls/runbuild-$P" 2>/dev/null | sort | paste -sd, -; }  # detached starts: the file order is not the launch order
lines() { local n; n=$(grep -c 'READY-NOW' "$H/logs/$P.log" 2>/dev/null); printf '%s' "${n:-0}"; }
lastlog() { grep 'READY-NOW' "$H/logs/$P.log" 2>/dev/null | tail -1; }
dk() { sort "$H/state/triage-state/$P/deferred.keys" 2>/dev/null | paste -sd, -; }

# ═══ R1, R2, R6, R7: 5 ready tickets, cap 3 ═════════════════════════════════
newp r1; five
K=$(pass 0)
eq "R1 pass 1 launches 3 of 5" "$(rbcalls)" 3
eq "R1 the first 3 in the decisions order" "$(built)" "TK-901,TK-902,TK-903"
eq "R1 run-build.sh argv is <project> <id> <label>" "$(grep -cx -- "$P t901 TK-901" "$T/calls/runbuild-$P")" 1
eq "R7 the launched keys join the skip set" "$K" "t901 t902 t903 "
eq "R2 the 2 capped keys are owed to the next tick" "$(dk)" "t904,t905"
case "$(lastlog)" in *"READY-NOW owed 5, launched 3: TK-901 TK-902 TK-903; waited: TK-904=cap TK-905=cap"*) ok ;; *) bad "R6 the pass line: [$(lastlog)]" ;; esac
eq "R6 one line per pass" "$(lines)" 1
: > "$H/state/triage-state/$P/deferred.keys"   # the next pre-check rewrites it
pass 600 >/dev/null
eq "R1 pass 2 launches the other 2" "$(built)" "TK-901,TK-902,TK-903,TK-904,TK-905"
eq "R2 nothing is owed after pass 2" "$(dk)" ""
case "$(lastlog)" in *"READY-NOW owed 2, launched 2: TK-904 TK-905"*) ok ;; *) bad "R6 the pass 2 line: [$(lastlog)]" ;; esac
# R3
pass 1200 >/dev/null; pass 1800 >/dev/null; pass 2400 >/dev/null
eq "R3 3 more passes on the same input hashes: still 5 launches" "$(rbcalls)" 5
eq "R3 a pass with nothing owed writes no line" "$(lines)" 2

# ═══ R4: not ready is not owed ═══════════════════════════════════════════════
newp r4
tk t1 TK-1 todo needs_clarification client; tk t2 TK-2 todo ready client; tk t3 TK-3 paused ready team
tk t4 TK-4 in_progress ready team; tk t5 TK-5 todo ready team; flush
listed t1:TK-1 t2:TK-2 t3:TK-3 t4:TK-4 t5:TK-5
pass 0 >/dev/null
eq "R4 only the ready team-turn todo ticket is launched" "$(built)" "TK-5"
case "$(lastlog)" in *"READY-NOW owed 1, launched 1: TK-5"*) ok ;; *) bad "R4 the line counts 1 owed: [$(lastlog)]" ;; esac

# ═══ R5: the guards decline, with the reason ════════════════════════════════
newp r5; tk t624 TK-624 todo ready team; tk t625 TK-625 todo ready team; flush
echo '[{"number":412,"head":{"ref":"ticket/TK-624"},"title":"TK-624: fix"}]' > "$H/state/triage-state/$P/prs.json"
listed t624:TK-624 t625:TK-625
pass 0 >/dev/null
eq "R5 an open PR owns TK-624: only TK-625 is launched" "$(built)" "TK-625"
case "$(lastlog)" in *"waited: TK-624=owned:pr-412"*) ok ;; *) bad "R5 the line names the owner: [$(lastlog)]" ;; esac
eq "R5 a declined key is not carried as a capped key" "$(dk)" ""
newp r5b; tk t7 TK-7 todo ready team; flush; listed t7:TK-7
pass 0 "STUB_GATE=HELD dependency TK-6 is open" >/dev/null
eq "R5 a hold from --buildable-strict: 0 launches" "$(rbcalls)" 0
case "$(lastlog)" in *"READY-NOW owed 1, launched 0; waited: TK-7="*) ok ;; *) bad "R5 the held line: [$(lastlog)]" ;; esac

# ═══ R8: builds pause ════════════════════════════════════════════════════════
newp r8; five
( pause_active() { [ "$2" = builds ]; }; export -f pause_active
  pass 0 >/dev/null )
eq "R8 a builds pause: 0 launches" "$(rbcalls)" 0
case "$(lastlog)" in *"READY-NOW withheld: builds pause"*) ok ;; *) bad "R8 the pause line: [$(lastlog)]" ;; esac

# ═══ R9: a GitHub board ══════════════════════════════════════════════════════
newp r9; five
jq -c '. + {issues: []}' "$H/state/triage-state/$P/world.json" > "$H/state/triage-state/$P/w.tmp" && mv "$H/state/triage-state/$P/w.tmp" "$H/state/triage-state/$P/world.json"
pass 0 >/dev/null
eq "R9 a GitHub board: 0 launches, 0 lines" "$(rbcalls) $(lines)" "0 0"

# ═══ K: knobs ════════════════════════════════════════════════════════════════
newp k1; five; pass 0 TRIAGE_READY_NOW=0 >/dev/null
eq "K1 TRIAGE_READY_NOW=0: 0 launches, 0 lines" "$(rbcalls) $(lines)" "0 0"
newp k2; five; pass 0 TRIAGE_STARVE_INAPP_LAUNCH=0 >/dev/null
eq "K2 TRIAGE_STARVE_INAPP_LAUNCH=0: 0 launches" "$(rbcalls)" 0
newp k2b; five; pass 0 TRIAGE_READY_NOW_MAX=5 >/dev/null
eq "K2 TRIAGE_READY_NOW_MAX=5: 5 launches on pass 1" "$(rbcalls)" 5
for k in TRIAGE_READY_NOW TRIAGE_READY_NOW_MAX; do
  eq "K3 knob $k is registered" "$(jq -r '.env' "$DIR/catalog/lanes.d/_lib.triage-starve.knobs.d/$k.json" 2>/dev/null)" "$k"
done
grep -q 'tsv_ready_pass "$(_ts_h)"' "$DIR/bin/lib/triage-state.sh" && ok || bad "K4 ts_tick calls tsv_ready_pass"

# ═══ V ═══════════════════════════════════════════════════════════════════════
[ ! -s "$T/calls/vendor" ] && ok || bad "V 0 vendor calls: $(head -3 "$T/calls/vendor" 2>/dev/null)"

echo "triage-ready-now.bh-10236: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
