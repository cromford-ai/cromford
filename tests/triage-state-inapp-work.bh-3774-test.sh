#!/bin/bash
# tests/triage-state-inapp-work.bh-3774-test.sh — BH-3774: on an in-app board,
# a ticket with a queue line or a finished build in this tick is the session's
# to work (close-out comment, status, launch, defer), exactly as on a GitHub
# board. The pre-check decides it ONCE (decisions.tsv column 9), and both the
# enforce directive (ts_tick) and the shadow scorecard (ts_after_session ->
# bin/triage-state.py record) read that one decision.
#
# Everything real except the worker: bin/lib/triage-state.sh,
# bin/lib/triage-shards-lib.sh, bin/triage-state.py and bin/triage-signal.py
# from this checkout, against an in-app board fingerprint. triage_state_list
# serves a rows file; triage_state_put records nothing. Threads are seeded as
# the .raw / .entry cache the pre-check reads (no fetch: TRIAGE_STATE_MAX_FETCH=0).
#
#   W1 decisions.tsv column 9 is 1 for a key with a queue line or a result dir,
#      matched by the board label, exact token only (TK-218 is not TK-2182)
#   W2 enforce: the do-not-touch list carries no in-app work key
#   W3 GitHub shape: key 13 / label TK-13 with work stays off the list
#   W4 shadow: close-out comment, close-out status, queue launch, queue defer on
#      work tickets are work-on-skip, never would-have-missed
#   W5 the same four actions on tickets with no work (a substring key, a
#      foreign project's result dir) are still would-have-missed, same format
#   W6 a miss snapshots what the pre-check hashed; misses/ keeps the newest 50
#   W7 the input hash is byte-identical to origin/main's formula
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-state-inapp-work.bh-3774-test.sh
# BH-6578: triaged_at is one hour before the run, never a fixed date. A
# client-turn verdict comes back after triaged_at + the nudge (14 days), so a
# fixed date made this fixture go red on the day the nudge ran out.
TRIAGED_AT=$(date -u -d "@$(( $(date -u +%s) - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -r "$(( $(date -u +%s) - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ')
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1

# ── the scratch harness: the production files, linked ───────────────────────
H="$T/h"; P=project-4
mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$H/builds" "$H/flags"
for s in triage-state.py triage-signal.py; do ln -s "$DIR/bin/$s" "$H/bin/$s"; done
for s in triage-state.sh triage-shards-lib.sh; do ln -s "$DIR/bin/lib/$s" "$H/bin/lib/$s"; done
D="$H/state/triage-state/$P"; mkdir -p "$D"
ROWS="$T/rows.json"; echo '[]' > "$ROWS"
triage_state_list() { cat "$ROWS"; }
triage_state_put() { :; }
# shellcheck source=/dev/null
. "$H/bin/lib/triage-state.sh"

tick_env() { # tick_env <mode> [gate-reason]
  export HARNESS="$H" TRIAGE_STATE_MODE="$1" TRIAGE_STATE_MAX_FETCH=0
  PROJECT=$P; STAMP="2026-10-01 10:00:00Z"; LOG="$H/logs/$P.log"
  GATE_REASON="${2:-results-sweep}"; SCOPE_N=full
  TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; JOB_ID=""
  PROMPT_TEXT="SOP PROMPT"
}
LANE_TICK() { :; }
rt_gate_consume() { :; }

# The in-app board: id -> label. TK-2180/2181 have finished builds (close-outs),
# TK-2155/2118 have queue lines, TK-2182 has a finished build; TK-218 sits
# beside it as a substring; TK-2015 has a result dir from ANOTHER project;
# TK-9 and TK-77 have nothing.
IDS="c1a c2b c3c c4d c5e c6f c7g c8h c9i"
label_of() { case "$1" in c1a) echo TK-2182 ;; c2b) echo TK-218 ;; c3c) echo TK-2155 ;; c4d) echo TK-2180 ;;
  c5e) echo TK-2181 ;; c6f) echo TK-2118 ;; c7g) echo TK-2015 ;; c8h) echo TK-9 ;; c9i) echo TK-77 ;; esac; }
# stored verdicts: a close-out comment / status moves needs_clarification, a
# launch and a defer move triaged (bin/triage-state.py has_effect)
stored_of() { case "$1" in c1a|c2b|c4d|c5e|c7g) echo needs_clarification ;; *) echo triaged ;; esac; }
{ printf '{"b1":['; sep=""
  for i in $IDS; do printf '%s{"id":"%s","key":"%s","title":"t %s","status":"open","commentCount":1,"lastActivityAt":"2026-09-30T00:00:00Z"}' "$sep" "$i" "$(label_of "$i")" "$i"; sep=,; done
  printf ']}\n'; } > "$H/state/$P.gate.pending"
jq -e . "$H/state/$P.gate.pending" >/dev/null || bad "fixture: the in-app world is JSON"
# the key<->id map bin/triage-gate.sh rebuilds every fetch: a DECISION names the label
jq -S '[.b1[] | {(.id): .key, (.key): .id}] | add' "$H/state/$P.gate.pending" > "$H/state/$P.keymap.json"
# the thread cache the pre-check hashes (what bin/triage-gate.sh --thread wrote)
for i in $IDS; do
  jq -n --arg i "$i" --arg k "$(label_of "$i")" '{kind:"inapp",doc:{id:$i,key:$k,title:("t " + $i),status:"open",description:"d",
    comments:[{id:("m-" + $i),authorName:"Client",body:"please",createdAt:"2026-09-30T00:00:00Z"}]}}' > "$D/$i.raw"
done
python3 "$DIR/bin/triage-state.py" entries --world "$H/state/$P.gate.pending" > "$T/entries.tsv"
while IFS=$'\t' read -r k _ esha _; do printf '%s' "$esha" > "$D/$k.entry"; done < "$T/entries.tsv"

# Pass 1 (no rows): the hashes. Then rows stamped with them: every ticket is
# `skip unchanged:<stored>` from here on.
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
[ "$(awk -F'\t' '$5!="-"' "$D/decisions.tsv" | wc -l | tr -d ' ')" = 9 ] && ok \
  || bad "fixture: every ticket hashed: $(cat "$D/decisions.tsv" 2>/dev/null)"
awk -F'\t' '{print $1"\t"$5}' "$D/decisions.tsv" | while IFS=$'\t' read -r k h; do
  jq -n --arg ta "$TRIAGED_AT" --arg k "$k" --arg h "$h" --arg v "$(stored_of "$k")" \
    '{ticket_key:$k, verdict:$v, waiting_on:(if $v=="needs_clarification" then "client" else "none" end),
      verdict_hash:$h, input_hash:$h, triaged_at:$ta, next_recheck_at:"2099-01-01T00:00:00Z", reason:"x"}'
done | jq -s . > "$ROWS"

work_env() {
  QLINES="TK-2155 ready to launch
TK-2118 waiting on the gate"
  RDIRS="$H/builds/$P-TK-2182-20261001 :: RESULT: BUILT
$H/builds/$P-TK-2180-20261001 :: RESULT: PR_CREATED
$H/builds/pool-$P-TK-2181-20261001 :: RESULT: PR_CREATED
$H/builds/project-3-TK-2015-20261001 :: RESULT: PR_CREATED"
}
col() { awk -F'\t' -v k="$1" -v c="$2" '$1==k{print $c}' "$D/decisions.tsv"; }

# ═══ W1 — column 9: the work flag, by label, exact token ═════════════════════
tick_env shadow; work_env; ( ts_precheck ) >/dev/null 2>&1
[ "$(for i in $IDS; do printf '%s ' "$(col "$i" 3)"; done)" = "skip skip skip skip skip skip skip skip skip " ] && ok \
  || bad "(W1) precondition: every ticket is skip unchanged: $(cut -f1-4 "$D/decisions.tsv" | tr '\n' '|')"
W1=$(for i in $IDS; do printf '%s=%s ' "$(label_of "$i")" "$(col "$i" 9)"; done)
[ "$W1" = "TK-2182=1 TK-218=0 TK-2155=1 TK-2180=1 TK-2181=1 TK-2118=1 TK-2015=0 TK-9=0 TK-77=0 " ] && ok \
  || bad "(W1) decisions.tsv column 9 marks exactly the queue / result-dir keys: [$W1]"
# a scoped tick: its work tickets are in scope (column 7), matched by label too
tick_env shadow queue-pending; SCOPE_N=queue; work_env; ( ts_precheck ) >/dev/null 2>&1
W1S=$(for i in $IDS; do printf '%s=%s ' "$(label_of "$i")" "$(col "$i" 7)"; done)
[ "$W1S" = "TK-2182=1 TK-218=0 TK-2155=1 TK-2180=1 TK-2181=1 TK-2118=1 TK-2015=0 TK-9=0 TK-77=0 " ] && ok \
  || bad "(W1) a scoped tick puts its in-app work keys in scope (column 7): [$W1S]"

# ═══ W2 — enforce: no in-app work key on the do-not-touch list ═══════════════
tick_env enforce results-sweep; work_env
OUT2=$( ts_tick; echo "CONTINUED [$PROMPT_TEXT]" ) 2>/dev/null
case "$OUT2" in *CONTINUED*"must NOT be re-triaged"*) ok ;; *) bad "(W2) precondition: the tick continues with the directive: [$OUT2]" ;; esac
UNCH=$(printf '%s' "$OUT2" | sed -n 's/.*status: \(.*\)\. Queue lines.*/\1/p')
for l in TK-2182 TK-2155 TK-2180 TK-2181 TK-2118; do
  case " $UNCH " in *" $l "*) bad "(W2) $l has queue / close-out work and must not be listed do-not-touch: [$UNCH]" ;; *) ok ;; esac
done
for l in TK-218 TK-2015 TK-9 TK-77; do
  case " $UNCH " in *" $l "*) ok ;; *) bad "(W2) $l has no work and stays on the do-not-touch list: [$UNCH]" ;; esac
done

# ═══ W4 — shadow: the four work shapes are work-on-skip, not misses ══════════
tick_env shadow; work_env; ( ts_precheck ) >/dev/null 2>&1
cat > "$T/o-work.txt" <<'OUT'
tickets=4
DECISION: TK-2180 :: comment :: PR is up
DECISION: TK-2181 :: status :: moved to review
DECISION: TK-2155 :: launch :: queue gate open
DECISION: TK-2118 :: defer :: blocked on TK-2015
OUT
: > "$LOG"; ts_after_session "$H" "$P" 0 "$T/o-work.txt" >/dev/null 2>&1
grep -q "triage-state shadow: work-on-skip 4: TK-2155 (launch), TK-2180 (comment), TK-2181 (status), TK-2118 (defer)\$" "$LOG" && ok \
  || bad "(W4) close-out / queue work on a work ticket is logged as work-on-skip: $(grep triage-state "$LOG")"
! grep -q would-have-missed "$LOG" && ok || bad "(W4) work is never a miss: $(grep would-have "$LOG")"
[ ! -d "$D/misses" ] && ok || bad "(W4) no miss, no snapshot: $(ls "$D/misses")"

# ═══ W5 — the same actions with no work are still misses ════════════════════
cat > "$T/o-miss.txt" <<'OUT'
tickets=4
DECISION: TK-218 :: comment :: PR is up
DECISION: TK-2015 :: status :: moved to review
DECISION: TK-9 :: launch :: building it
DECISION: TK-77 :: defer :: blocked on TK-2015
OUT
: > "$LOG"; ts_after_session "$H" "$P" 0 "$T/o-miss.txt" >/dev/null 2>&1
grep -q "triage-state shadow: would-have-missed 4: TK-218 (comment), TK-2015 (status), TK-9 (launch), TK-77 (defer)\$" "$LOG" && ok \
  || bad "(W5) a substring key, a foreign project's result dir and no work at all are still misses: $(grep triage-state "$LOG")"
! grep -q work-on-skip "$LOG" && ok || bad "(W5) none of them is work: $(grep work-on-skip "$LOG")"

# ═══ W6 — a miss carries the inputs the pre-check hashed ════════════════════
scratch_rm "$D/misses"; mkdir -p "$D/misses"
for n in $(seq 10 64); do mkdir -p "$D/misses/20200101T0000${n}Z-OLD"; done
tick_env shadow; ( ts_precheck ) >/dev/null 2>&1   # no queue line: TK-2155 is not work now
[ "$(col c3c 9)" = 0 ] && ok || bad "(W6) precondition: TK-2155 has no work this tick: [$(col c3c 9)]"
printf 'tickets=1\nDECISION: TK-2155 :: launch :: building it\n' > "$T/o-one.txt"
: > "$LOG"; ts_after_session "$H" "$P" 0 "$T/o-one.txt" >/dev/null 2>&1
grep -q "triage-state shadow: miss-detail: TK-2155=unchanged:triaged\$" "$LOG" && ok \
  || bad "(W6) the miss names its gate reason: $(grep triage-state "$LOG")"
SN=$(ls -1d "$D"/misses/*-TK-2155 2>/dev/null | head -1)
[ -n "$SN" ] && ok || bad "(W6) a snapshot dir for the miss: $(ls "$D/misses" | tail -3)"
[ "$(jq -r '.id' "$SN/world-row.json" 2>/dev/null)" = c3c ] && [ "$(jq -r '.key' "$SN/world-row.json" 2>/dev/null)" = TK-2155 ] && ok \
  || bad "(W6) world-row.json is the key's row of the hashed world: $(cat "$SN/world-row.json" 2>/dev/null)"
cmp -s "$SN/thread.raw" "$D/c3c.raw" && ok || bad "(W6) thread.raw is the hashed thread"
[ "$(cut -f1 "$SN/decision.tsv" 2>/dev/null)" = c3c ] && [ "$(cut -f4 "$SN/decision.tsv")" = unchanged:triaged ] && ok \
  || bad "(W6) decision.tsv is the key's decisions line: $(cat "$SN/decision.tsv" 2>/dev/null)"
[ "$(ls -1d "$D"/misses/*/ | wc -l | tr -d ' ')" = 50 ] && ok || bad "(W6) misses/ keeps the newest 50: $(ls -1d "$D"/misses/*/ | wc -l)"
[ ! -d "$D/misses/20200101T000010Z-OLD" ] && [ -d "$D/misses/20200101T000064Z-OLD" ] && ok || bad "(W6) the oldest go first"
# outside shadow: no snapshot, no detail line
scratch_rm "$D/misses"; tick_env enforce; ( ts_precheck ) >/dev/null 2>&1
: > "$LOG"; ts_after_session "$H" "$P" 0 "$T/o-one.txt" >/dev/null 2>&1
[ ! -d "$D/misses" ] && ! grep -q miss-detail "$LOG" && ok || bad "(W6) enforce snapshots nothing: $(ls "$D/misses" 2>/dev/null)"

# ═══ W3 — the GitHub shape is unchanged (mirrors precheck R5) ══════════════
G="$T/g"; mkdir -p "$G/bin/lib" "$G/state/triage-state/project-5" "$G/logs"
for s in triage-state.py triage-signal.py; do ln -s "$DIR/bin/$s" "$G/bin/$s"; done
for s in triage-state.sh triage-shards-lib.sh; do ln -s "$DIR/bin/lib/$s" "$G/bin/lib/$s"; done
echo '{"issues":[{"number":11,"state":"OPEN"},{"number":13,"state":"OPEN"}]}' > "$G/state/triage-state/project-5/world.json"
OUT3=$( H="$G"; ts_precheck() {   # the pre-check's output for this tick, as written
          printf '11\tTS-11\tskip\tunchanged:triaged\t%s\t-\t1\t-\t0\n13\tTS-13\tskip\tunchanged:triaged\t%s\t-\t1\t-\t1\n' \
            "$(printf 'a%.0s' $(seq 16))" "$(printf 'b%.0s' $(seq 16))" > "$G/state/triage-state/project-5/decisions.tsv"
          TS_MODE=enforce; TS_READY=1; TS_LLM=""; TS_LLM_KEYS=""; TS_SKIPSET=" 11 13 "; TS_ENQ=""; TS_SUMMARY=x; }
        tick_env enforce queue-pending; export HARNESS="$G"; PROJECT=project-5; LOG="$G/logs/project-5.log"
        SCOPE_N=queue; QLINES="TK-13 waiting on PR #30"
        ts_tick; echo "CONTINUED [$PROMPT_TEXT]" ) 2>/dev/null
UNCH3=$(printf '%s' "$OUT3" | sed -n 's/.*status: \(.*\)\. Queue lines.*/\1/p')
case " $UNCH3 " in *" TK-13 "*) bad "(W3) GitHub: TK-13 has a queue line and is not do-not-touch: [$UNCH3]" ;; *" TK-11 "*) ok ;;
  *) bad "(W3) GitHub: TK-11 stays listed: [$OUT3]" ;; esac

# ═══ W7 — no hash drift against origin/main ═════════════════════════════════
if git -C "$DIR" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  M="$T/main-bin"; mkdir -p "$M"
  git -C "$DIR" show origin/main:bin/triage-state.py > "$M/triage-state.py" && git -C "$DIR" show origin/main:bin/triage-signal.py > "$M/triage-signal.py"
  echo '{"issues":[{"number":13,"title":"t","state":"OPEN","labels":[]}],"meta":{}}' > "$T/gw.json"
  jq -n '{kind:"gh",doc:{issue:{number:13,title:"t",body:"Blocked-by: #30",state:"open",labels:[{name:"ai-build"}],updated_at:"2026-09-30T00:00:00Z"},
          comments:[{id:1,user:{login:"carl"},body:"status?",created_at:"2026-09-30T00:00:00Z"}]}}' > "$T/gwrap.json"
  for kind in gh inapp; do
    if [ "$kind" = gh ]; then wf="$T/gw.json"; wr="$T/gwrap.json"; k=13; else wf="$H/state/$P.gate.pending"; wr="$D/c3c.raw"; k=c3c; fi
    a=$(python3 "$DIR/bin/triage-state.py" hash --world "$wf" --key "$k" --prefix TS < "$wr" | jq -r .input_hash)
    b=$(python3 "$M/triage-state.py" hash --world "$wf" --key "$k" --prefix TS < "$wr" | jq -r .input_hash)
    [ -n "$a" ] && [ "$a" != null ] && [ "$a" = "$b" ] && ok || bad "(W7) $kind input_hash drifted from origin/main: [$a] vs [$b]"
  done
else
  echo "triage-state-inapp-work: W7 skipped, no origin/main in this checkout"
fi

echo "triage-state-inapp-work: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
