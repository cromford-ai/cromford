#!/bin/bash
# tests/triage-state-paid-unchanged.bh-3926-test.sh — BH-3926 (BH-3921.3): the
# paid_unchanged account of the TRIAGE-STATE tick, its cost-row notes, its
# 3-tick streak alert, and the Mission Control read behind /costs.
#
#   P1 enforce + board-changed, a full tick, one changed key: the enforce line
#      ends `paid_unchanged=0]` and TS_ROW_NOTE is exactly
#      ts:new=0:chg=1:due=0:cap=0:unr=0:pu=0
#   P2 shadow, 40 unchanged + 1 changed: `paid_unchanged=40]`, no streak file,
#      no alert
#   P3 enforce + forced (observe only): one alert after 3 positive ticks, none
#      on the 4th/5th, a zero tick resets the streak, the next 3 alert again.
#      P3b positive, positive, zero, positive, positive: no alert
#   P4 ts_row_note_of: changed / unchanged / new / work, nothing for an unknown key
#   P5 the note rides the agent-call: (a) the two env-prefix lines sit inside
#      their splices; (b) rt_launch with TS_ROW_NOTE=ts:pu=3 hands agent-call.sh
#      AGENT_CALL_ROW_NOTE=ts:pu=3; (c) bin/triage-shard.sh hands it TSH_TS_NOTE;
#      (d) without one it reads the class from its dispatch snapshot
#   P6 rows unreadable: enforce writes no waste; shadow reads `paid_unchanged=?`
#      (never 0), the streak is untouched, no alert. Work keys and out-of-scope
#      keys are never counted
#   P7 the worker route and the console section: named here by path, and their
#      node suites run when the runtime is there
#
# Everything real except the worker: bin/lib/triage-state.sh, its modules,
# bin/triage-state.py, bin/triage-signal.py and bin/lib/triage-shards-lib.sh from
# this checkout. triage_state_list serves a rows file (or fails); bin/lane-alert.sh
# is a stub that appends its argv to $T/alerts.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-state-paid-unchanged.bh-3926-test.sh
# BH-6578: triaged_at is one hour before the run, never a fixed date. A
# client-turn verdict comes back after triaged_at + the nudge (14 days), so a
# fixed date made this fixture go red on the day the nudge ran out.
TRIAGED_AT=$(date -u -d "@$(( $(date -u +%s) - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -r "$(( $(date -u +%s) - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ')
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
WASTE="$DIR/bin/lib/triage-state-waste.sh"
ROUTE="$DIR/worker/jobs/src/routes/triage-waste.js"
SCREEN="$DIR/console-ui/src/screens/TriageWaste.js"

# ── a scratch harness: the production files, linked ─────────────────────────
H="$T/h"; P=project-4
mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$H/builds" "$H/flags"
for s in triage-state.py triage-signal.py; do ln -s "$DIR/bin/$s" "$H/bin/$s"; done
for s in triage-state.sh triage-state-unreadable.sh triage-state-waste.sh triage-shards-lib.sh; do
  ln -s "$DIR/bin/lib/$s" "$H/bin/lib/$s"
done
cat > "$H/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts"
STUB
chmod +x "$H/bin/lane-alert.sh"; : > "$T/alerts"
ROWS="$T/rows.json"; echo '[]' > "$ROWS"; LIST_FAILS=0
triage_state_list() { [ "$LIST_FAILS" = 0 ] || return 1; cat "$ROWS"; }
triage_state_put() { :; }
LANE_TICK() { :; }
rt_gate_consume() { :; }
# shellcheck source=/dev/null
. "$H/bin/lib/triage-state.sh"
D="$H/state/triage-state/$P"; LOGF="$H/logs/$P.log"; STREAK="$D/paid-unchanged.streak"

tick_env() { # tick_env <mode> [gate-reason]
  export HARNESS="$H" TRIAGE_STATE_MODE="$1" TRIAGE_STATE_MAX_FETCH=0
  PROJECT=$P; STAMP="2026-10-01 10:00:00Z"; LOG="$LOGF"
  GATE_REASON="${2:-board-changed}"; SCOPE_N=full
  TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; JOB_ID=""
  PROMPT_TEXT="SOP PROMPT"
  unset TS_PAID_UNCHANGED TS_ROW_NOTE TS_WASTE_LABELS
}
# board <id...> — the in-app fingerprint (label TK-<id>) and the thread cache it hashes
board() {
  local i sep=""
  mkdir -p "$D"
  { printf '{"b1":['
    for i in "$@"; do printf '%s{"id":"%s","key":"TK-%s","title":"t %s","status":"open","commentCount":1,"lastActivityAt":"2026-09-30T00:00:00Z"}' "$sep" "$i" "$i" "$i"; sep=,; done
    printf ']}\n'; } > "$H/state/$P.gate.pending"
  for i in "$@"; do
    jq -n --arg i "$i" '{kind:"inapp",doc:{id:$i,key:("TK-" + $i),title:("t " + $i),status:"open",description:"d",
      comments:[{id:("m-" + $i),authorName:"Client",body:"please",createdAt:"2026-09-30T00:00:00Z"}]}}' > "$D/$i.raw"
  done
  python3 "$DIR/bin/triage-state.py" entries --world "$H/state/$P.gate.pending" > "$T/entries.tsv"
  while IFS=$'\t' read -r k _ esha _; do printf '%s' "$esha" > "$D/$k.entry"; done < "$T/entries.tsv"
}
# seed <changed id...> — stored rows for the current board: every key triaged
# against the hash it has now (unchanged, recheck far off), except the named
# keys, whose verdict was made against another hash (changed)
seed() {
  local chg=" $* " k h vh
  echo '[]' > "$ROWS"; tick_env shadow; ( ts_precheck ) >/dev/null 2>&1
  while IFS=$'\t' read -r k h; do
    vh="$h"; case "$chg" in *" $k "*) vh=$(printf '0%.0s' $(seq 64)) ;; esac
    jq -n --arg ta "$TRIAGED_AT" --arg k "$k" --arg h "$vh" '{ticket_key:$k, verdict:"triaged", waiting_on:"none", verdict_hash:$h, input_hash:$h,
      triaged_at:$ta, next_recheck_at:"2099-01-01T00:00:00Z", reason:"x"}'
  done < <(awk -F'\t' '{print $1"\t"$5}' "$D/decisions.tsv") | jq -s . > "$ROWS"
  : > "$LOGF"
}
U40=$(seq 101 140 | tr '\n' ' ')
# tick <mode> <gate> — one ts_tick in a subshell; prints the exported note
tick() {
  tick_env "$1" "$2"
  ( ts_tick >/dev/null 2>&1; bash -c 'printf %s "${TS_ROW_NOTE-unset}"' ) 2>/dev/null
}
# zero_tick — an empty board, board-changed: the `exit 0` path
zero_tick() { board; tick enforce board-changed >/dev/null; board $U40 201; }
streak() { cat "$STREAK" 2>/dev/null || echo absent; }
nalerts() { grep -c . "$T/alerts" | tr -d ' '; }

# ═══ P1 — enforce, full tick, one changed key: pu=0 and the note ═════════════
board 101 102 103 201; seed 201
NOTE=$(tick enforce board-changed)
L1=$(grep 'triage-state enforce: ' "$LOGF")
case "$L1" in *' paid_unchanged=0]') ok ;; *) bad "(P1) the enforce line ends 'paid_unchanged=0]': [$L1]" ;; esac
[[ "$NOTE" =~ ^ts:new=0:chg=1:due=0:cap=0:unr=0:pu=0$ ]] && ok || bad "(P1) TS_ROW_NOTE is exported, exactly ts:new=0:chg=1:due=0:cap=0:unr=0:pu=0: [$NOTE]"
[ "$(streak)" = 0 ] && ok || bad "(P1) an enforce tick with 0 resets/writes the streak to 0: [$(streak)]"
[ "$(nalerts)" = 0 ] && ok || bad "(P1) no alert: $(cat "$T/alerts")"
# a new key is counted as new, never as paid
board 101 102 103 201 301
tick enforce board-changed >/dev/null
L1b=$(grep 'triage-state enforce: ' "$LOGF" | tail -1)
case "$L1b" in *' paid_unchanged=0]') ok ;; *) bad "(P1) a never-triaged key is not paid-unchanged: [$L1b]" ;; esac

# ═══ P2 — shadow: counted, logged, never the streak ═════════════════════════
board $U40 201; seed 201; rm -f "$STREAK"; : > "$T/alerts"; : > "$LOGF"
NOTE=$(tick shadow board-changed)
L2=$(grep 'triage-state shadow: ' "$LOGF")
case "$L2" in *' paid_unchanged=40]') ok ;; *) bad "(P2) the shadow line ends 'paid_unchanged=40]': [$L2]" ;; esac
[ "$NOTE" = "ts:new=0:chg=1:due=0:cap=0:unr=0:pu=40" ] && ok || bad "(P2) the shadow note: [$NOTE]"
[ ! -e "$STREAK" ] && ok || bad "(P2) shadow never writes the streak file: [$(streak)]"
echo 2 > "$STREAK"; tick shadow board-changed >/dev/null
[ "$(streak)" = 2 ] && ok || bad "(P2) shadow never changes the streak file: [$(streak)]"
[ "$(nalerts)" = 0 ] && ok || bad "(P2) shadow never alerts: $(cat "$T/alerts")"

# ═══ P3 — enforce + forced: the streak and its one alert ═════════════════════
rm -f "$STREAK"; : > "$T/alerts"; : > "$LOGF"
tick enforce forced >/dev/null
L3=$(grep 'observe only' "$LOGF")
case "$L3" in *'paid_unchanged=40] — observe only on a '"'forced'"' tick') ok ;; *) bad "(P3) the observe-only line carries paid_unchanged=40: [$L3]" ;; esac
[ "$(streak)" = 1 ] && ok || bad "(P3) tick 1: streak 1, got [$(streak)]"
tick enforce forced >/dev/null
[ "$(nalerts)" = 0 ] && ok || bad "(P3) no alert after 2 ticks: $(cat "$T/alerts")"
tick enforce forced >/dev/null
[ "$(nalerts)" = 1 ] && ok || bad "(P3) exactly one alert after 3 ticks: [$(cat "$T/alerts")]"
A=$(head -1 "$T/alerts")
case "$A" in "--id triage-paid-unchanged:$P --severity warn triage $P: 3 triage ticks in a row paid the model for tickets whose inputs had not changed (last: 40: TK-1"*"). Read logs/$P.log and state/triage-state/$P/decisions.tsv.") ok ;;
  *) bad "(P3) the alert's id, severity, family and text: [$A]" ;; esac
tick enforce forced >/dev/null; tick enforce forced >/dev/null
[ "$(nalerts)" = 1 ] && ok || bad "(P3) ticks 4 and 5 stay silent: [$(cat "$T/alerts")]"
[ "$(streak)" = 5 ] && ok || bad "(P3) streak 5 after 5 positive ticks: [$(streak)]"
zero_tick
[ "$(streak)" = 0 ] && ok || bad "(P3) a zero tick resets the streak to 0: [$(streak)]"
grep -q 'no model call \[gate=board-changed paid_unchanged=0\]' "$LOGF" && ok || bad "(P3) the zero line carries paid_unchanged=0: $(grep rc=skip "$LOGF")"
for _ in 1 2 3; do tick enforce forced >/dev/null; done
[ "$(nalerts)" = 2 ] && ok || bad "(P3) a new streak of 3 alerts once more (2 in total): [$(cat "$T/alerts")]"
# P3b — interrupted streaks never alert
rm -f "$STREAK"; : > "$T/alerts"
tick enforce forced >/dev/null; tick enforce forced >/dev/null; zero_tick
tick enforce forced >/dev/null; tick enforce forced >/dev/null
[ "$(nalerts)" = 0 ] && ok || bad "(P3b) positive, positive, zero, positive, positive: no alert: [$(cat "$T/alerts")]"
[ "$(streak)" = 2 ] && ok || bad "(P3b) streak 2: [$(streak)]"
# a corrupt streak file reads as 0
echo 'x9' > "$STREAK"; tick enforce forced >/dev/null
[ "$(streak)" = 1 ] && ok || bad "(P3) a corrupt streak file reads as 0: [$(streak)]"

# ═══ P4 — the shard note, one class per key ══════════════════════════════════
board 101 102 201; seed 201
board 101 102 201 301   # 301 has no row: new
tick_env shadow; QLINES="TK-102 ready to launch"; ( ts_precheck ) >/dev/null 2>&1
[ "$(ts_row_note_of 201)" = ts=changed ] && ok || bad "(P4) a changed key: [$(ts_row_note_of 201)]"
[ "$(ts_row_note_of 101)" = ts=unchanged ] && ok || bad "(P4) an unchanged key: [$(ts_row_note_of 101)]"
[ "$(ts_row_note_of 301)" = ts=new ] && ok || bad "(P4) a never-triaged key: [$(ts_row_note_of 301)]"
[ "$(ts_row_note_of 102)" = ts=work ] && ok || bad "(P4) a work key: [$(ts_row_note_of 102)]"
out=$(ts_row_note_of 999; echo x); [ "$out" = x ] && ok || bad "(P4) an unknown key prints nothing: [$out]"

# ═══ P5 — the note rides the agent-call ══════════════════════════════════════
# (a) each line inside its contiguous `\`-continued prefix block
inblock() { # inblock <file> <fixed line> <block end word>
  # Through ENVIRON, not -v: gawk applies escape processing to a -v value, so the
  # line's trailing `\` was eaten there and never matched (mawk keeps it).
  INBLOCK_WANT="$2" INBLOCK_END="$3" awk '
    BEGIN { want = ENVIRON["INBLOCK_WANT"]; end = ENVIRON["INBLOCK_END"] }
    { line=$0; sub(/^[ \t]+/, "", line) }
    line == want { seen=1 }
    seen && index(line, end) { found=1; exit }
    seen && line !~ /\\$/ { exit }
    END { exit !found }' "$1"
}
inblock "$DIR/bin/lib/rt/launch.sh" 'AGENT_CALL_ROW_NOTE="${TS_ROW_NOTE:-}" \' lock_run_unheld && ok \
  || bad "(P5a) launch.sh carries AGENT_CALL_ROW_NOTE inside the splice ending in lock_run_unheld"
inblock "$DIR/bin/triage-shard.sh" 'AGENT_CALL_ROW_NOTE="${TSH_TS_NOTE:-}" \' lock_run_unheld && ok \
  || bad "(P5a) triage-shard.sh carries AGENT_CALL_ROW_NOTE inside the splice ending in lock_run_unheld"
# (b) rt_launch, driven, with a stub agent-call that records its note
L="$T/l"; mkdir -p "$L/bin" "$L/logs"
cat > "$L/bin/agent-call.sh" <<STUB
#!/bin/bash
printf '%s' "\${AGENT_CALL_ROW_NOTE-unset}" > "$T/note.launch"
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$L/bin/decision-log.sh"; chmod +x "$L/bin/agent-call.sh" "$L/bin/decision-log.sh"
(
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/rt/launch.sh"
  lock_run_unheld() { ( "$@" ); }
  LANE_TICK() { :; }; rt_gate_consume() { :; }; rt_gate_fail_consume() { :; }; _rt_tgl() { return 1; }
  unset -f ts_after_session triage_throttle_record
  HARNESS="$L" PROJECT=$P PROMPT_TEXT=p OVERLAP_SEC="" EFFECTIVE_GROK_EFFORT="" TRIAGE_APPEND="" TRIAGE_MODEL=m
  OUT="$L/out" ALERTS="$L/logs/ALERTS.log" GATE_DECISION="RUN x" SCOPE_N=full JOB_ID=""
  TS_ROW_NOTE=ts:pu=3 rt_launch
) >/dev/null 2>&1
[ "$(cat "$T/note.launch" 2>/dev/null)" = ts:pu=3 ] && ok || bad "(P5b) rt_launch hands agent-call.sh AGENT_CALL_ROW_NOTE=ts:pu=3: [$(cat "$T/note.launch" 2>/dev/null)]"
# (c) bin/triage-shard.sh, driven, with the same stub
S="$T/s"; mkdir -p "$S/bin" "$S/logs" "$S/locks" "$S/env"
sed "s|$T/note.launch|$T/note.shard|" "$L/bin/agent-call.sh" > "$S/bin/agent-call.sh"
printf '#!/bin/sh\necho CONTRACT\n' > "$S/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/beat.sh"; cp "$S/bin/beat.sh" "$S/bin/decision-log.sh"
chmod +x "$S/bin/agent-call.sh" "$S/bin/triage-contract.sh" "$S/bin/beat.sh" "$S/bin/decision-log.sh"
echo "prompt" > "$T/shard-prompt"
HARNESS="$S" TSH_MODEL=m TSH_RUNNER=claude TSH_TS_NOTE=ts=unchanged timeout 60 bash "$DIR/bin/triage-shard.sh" "$P" TK-101 "$T/shard-prompt" >/dev/null 2>&1
[ "$(cat "$T/note.shard" 2>/dev/null)" = ts=unchanged ] && ok || bad "(P5c) triage-shard.sh hands agent-call.sh AGENT_CALL_ROW_NOTE=ts=unchanged: [$(cat "$T/note.shard" 2>/dev/null)]"
# (d) no TSH_TS_NOTE: the shard reads its class from the dispatch snapshot
# itself (bin/lib/rt/shards.sh is frozen by the BH-3418 contract)
mkdir -p "$S/bin/lib" "$S/state/triage-state/$P/snap/TK-101.h1.n1"
scratch_install_closure bin/lib/triage-state.sh "$S" >/dev/null || bad "(P5d) bin/lib/triage-state.sh could not be installed into the scratch harness"
printf 'TK-101\tAR-101\tllm\tnew\th1\t-\t1\t-\t0\n' > "$S/state/triage-state/$P/snap/TK-101.h1.n1/decisions.tsv"
echo '[]' > "$S/state/triage-state/$P/snap/TK-101.h1.n1/rows.json"
rm -f "$T/note.shard"
HARNESS="$S" TSH_MODEL=m TSH_RUNNER=claude TSH_TS_HASH=h1.n1 timeout 60 bash "$DIR/bin/triage-shard.sh" "$P" TK-101 "$T/shard-prompt" >/dev/null 2>&1
[ "$(cat "$T/note.shard" 2>/dev/null)" = ts=new ] && ok || bad "(P5d) triage-shard.sh reads ts=new from its dispatch snapshot: [$(cat "$T/note.shard" 2>/dev/null)]"
rm -f "$T/note.shard"
HARNESS="$S" TSH_MODEL=m TSH_RUNNER=claude TSH_TS_HASH=h9.n9 timeout 60 bash "$DIR/bin/triage-shard.sh" "$P" TK-101 "$T/shard-prompt" >/dev/null 2>&1
[ "$(cat "$T/note.shard" 2>/dev/null)" = "" ] && ok || bad "(P5d) no snapshot is no note: [$(cat "$T/note.shard" 2>/dev/null)]"

# ═══ P6 — rows unreadable, work keys, out-of-scope keys ══════════════════════
board $U40 201; seed 201; rm -f "$STREAK"; : > "$T/alerts"; : > "$LOGF"
LIST_FAILS=1
tick enforce board-changed >/dev/null
# TEST-CHANGE (merge with main's BH-3925): under enforce a rows-unreadable tick
# is now SKIPPED by bin/lib/triage-state-unreadable.sh, whose one log line
# carries the bracket as `paid_unchanged=?`. What P6 pins is that no waste
# COUNT is written: never a number, and the `?` is the only form allowed.
grep -qE 'paid_unchanged=[0-9]' "$LOGF" && bad "(P6) enforce with rows unreadable (TS_READY=0) logs no waste: $(cat "$LOGF")" || ok
awk '/paid_unchanged/ && !/paid_unchanged=\?\]/ {f = 1} END {exit !f}' "$LOGF" && bad "(P6) enforce with rows unreadable logs paid_unchanged other than ?: $(cat "$LOGF")" || ok
[ ! -e "$STREAK" ] && ok || bad "(P6) enforce with rows unreadable writes no streak: [$(streak)]"
NOTE=$(tick shadow board-changed)
L6=$(grep 'triage-state shadow: ' "$LOGF")
case "$L6" in *' paid_unchanged=?]') ok ;; *) bad "(P6) rows unreadable reads paid_unchanged=?, never 0: [$L6]" ;; esac
case "$NOTE" in ts:new=0:chg=0:due=0:cap=0:unr=41:pu=na) ok ;; *) bad "(P6) the unreadable note carries pu=na: [$NOTE]" ;; esac
# the account itself, under enforce: the unreadable path and TS_ROWS_OK=0 on
# any path read `?`, and neither moves the streak nor alerts
echo 2 > "$STREAK"
for path in unreadable restricted unrestricted; do
  got=$( TS_MODE=enforce TS_ROWS_OK=0; [ "$path" = unreadable ] && TS_ROWS_OK=1
         ts_waste_account "$path"; printf '%s|%s' "${TS_PAID_UNCHANGED-unset}" "${TS_ROW_NOTE-unset}" )
  case "$got" in '?|ts:'*':pu=na') ok ;; *) bad "(P6) ts_waste_account $path with rows unreadable reads ? and pu=na: [$got]" ;; esac
done
[ "$(streak)" = 2 ] && ok || bad "(P6) an unreadable enforce account leaves the streak alone: [$(streak)]"
[ "$(nalerts)" = 0 ] && ok || bad "(P6) no alert on unreadable rows: $(cat "$T/alerts")"
LIST_FAILS=0
# work and out-of-scope keys are never counted; the same board unscoped is
work6() { tick_env enforce forced; SCOPE_N=queue; QLINES="TK-101 ready to launch"; ( ts_tick >/dev/null 2>&1 ); }
: > "$LOGF"; work6
L6b=$(grep 'observe only' "$LOGF")
case "$L6b" in *'paid_unchanged=0]'*) ok ;; *) bad "(P6) a work key and out-of-scope keys count 0: [$L6b]" ;; esac
: > "$LOGF"; tick enforce forced >/dev/null
case "$(grep 'observe only' "$LOGF")" in *'paid_unchanged=40]'*) ok ;; *) bad "(P6) control: the same board unscoped counts 40: [$(grep 'observe only' "$LOGF")]" ;; esac

# ═══ P7 — the route and the screen ═══════════════════════════════════════════
for f in "$WASTE" "$ROUTE" "$SCREEN"; do [ -f "$f" ] && ok || bad "(P7) missing $f"; done
if ! command -v node >/dev/null 2>&1; then
  echo "triage-state-paid-unchanged: node suites SKIPPED — node is not installed on this box"
else
  if NOUT=$(cd "$DIR/worker/jobs" && node --test test/triage-waste.bh-3926.test.js 2>&1); then ok
  else bad "(P7) worker suite failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
  if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
    echo "triage-state-paid-unchanged: console suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
  elif NOUT=$(cd "$DIR/console-ui" && node --test tests/triage-waste.bh-3926.test.js 2>&1); then ok
  else bad "(P7) console suite failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "triage-state-paid-unchanged.bh-3926: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
