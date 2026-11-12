#!/bin/bash
# tests/triage-queue-closed.bh-9286-test.sh — BH-9286: the triage queue kept
# lines for closed issues and re-offered them forever. project-6-os, 2026-11-08: the
# lines for #38, #421, #854, #1371 and #3384 (all closed) were re-offered by the
# unchanged-shard gate every <= 240 min, the call-guard refused each one with
# rc 74, and nothing dropped a line or paged.
#
#   C1-C9  the REAL rt_shards (bin/lib/rt/shards.sh) on a scratch harness: the
#          closed-issue drop before a shard is offered (bin/lib/queue-closed.sh
#          qc_drop_closed). gh-rest is a stub that reads $T/issue-<n> and counts
#          its calls; bin/queue-line-drop.sh is the REAL script.
#   R1-R8  the REAL bin/triage-shard.sh with agent-call stubbed to refuse
#          (rc 74 `call-guard repeat`): the repeat-refusal counter
#          (qc_refusal_note), the drop and the one alert.
#   K1-K4  the knob clamp in _qc_knobs (catalog min/max): a low KEEP no longer
#          prunes the counter before the 3rd refusal; DROP_AFTER caps at 50.
#   V      0 vendor calls
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-queue-closed.bh-9286-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
export HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1
unset QUEUE_CLOSED_DROP QUEUE_REFUSED_DROP_AFTER QUEUE_REFUSED_KEEP_S TSH_QUEUE

mkdir -p "$T/rbin" "$T/calls"
for v in gh claude curl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls/vendor"\nexit 1\n' "$v" "$T" > "$T/rbin/$v"
done
printf '#!/bin/bash\nexec "$@"\n' > "$T/rbin/setsid"
chmod +x "$T/rbin/"*
export PATH="$T/rbin:$PATH"

# ── the scratch harness for the dispatcher ──────────────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks"
cat > "$H/bin/triage-shard.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$2" >> "$T/calls/shard-\$1"
printf '%s\n' "\${TSH_QUEUE:-}" > "$T/calls/tshq-\$1-\$2"
STUB
cat > "$H/bin/fleet-conf.sh" <<'STUB'
#!/bin/bash
case "${1:-}" in
  --projects-on-box) echo onlyone ;;
  *) [ "${2:-}" = repo ] && echo example-org/test-repo ;;
esac
exit 0
STUB
# The issue-state reader: $T/issue-<n> holds `open`, `closed`, `rc=<n>` or
# nothing (empty answer). Every call is counted.
cat > "$H/bin/lib/gh-rest.sh" <<STUB
gh_rest_issue_state() {
  printf '%s\n' "\$2" >> "$T/calls/rest"
  local v; v=\$(cat "$T/issue-\$2" 2>/dev/null)
  case "\$v" in rc=*) return "\${v#rc=}" ;; esac
  printf '%s\n' "\$v"
}
gh_rest_issue_state_var() {
  local __n="\$1" __o __rc=0; shift
  __o=\$(gh_rest_issue_state "\$@") || __rc=\$?
  GH_REST_STATUS=200; [ "\$__rc" = 0 ] || GH_REST_STATUS=503
  printf -v "\$__n" '%s' "\$__o"
  return "\$__rc"
}
STUB
# The D1 ready-row half of queue-line-drop.sh: record what it was asked.
cat > "$H/bin/lib/ready-queue.sh" <<STUB
rq_drop() { shift 2; printf '%s\n' "\$*" >> "$T/calls/rqdrop"; }
STUB
scratch_install_closure bin/queue-line-drop.sh "$H" >/dev/null 2>&1 || bad "install bin/queue-line-drop.sh"
scratch_install_closure bin/lib/queue-closed.sh "$H" >/dev/null 2>&1 || bad "install bin/lib/queue-closed.sh"
chmod +x "$H/bin/"*.sh
QF="$H/logs/READY-QUEUE.log"
export HARNESS="$H"

# shards — one tick through the real rt_shards. QLINES is the queue file as it
# is NOW (scope.sh's rq_lines), TICK_SCOPE is $TS (board lines), GH the board
# kind (default 1, a GitHub-issue board).
shards() {
  ( set +u
    PROJECT=$P; STAMP="t"; LOG="$H/logs/$P.log"; ALERTS="$H/logs/ALERTS.log"
    GATE_DECISION="RUN queue"; GATE_REASON=queue; SCOPE_N=queue
    TICK_SCOPE="${TS:-}"; BOARD_SEC=""; QLINES="$(cat "$QF" 2>/dev/null)"; QDIRS="${QD:-}"; RDIRS=""
    JOB_ID=""; PROMPT_TEXT="SOP"; TRIAGE_MODEL=m; SHARD_SOP="SOP"; EFFECTIVE_GROK_EFFORT=""
    LANE_TICK() { :; }; rt_gate_consume() { :; }
    . "$DIR/bin/lib/triage-shards-lib.sh"
    triage_shards_on() { echo 1; }; triage_shard_gh() { echo "${GH:-1}"; }; triage_shard_fp_ttl() { echo 3600; }
    triage_shards_max() { echo 0; }; triage_caps_on() { echo 0; }
    triage_prstates_ingest() { :; }; triage_prstates_refresh() { :; }; triage_prstates_prune() { :; }
    triage_shard_fp() { echo "fp-$3"; }; triage_shard_fp_fresh() { return 1; }
    triage_shard_fp_put() { :; }; triage_shard_rearm() { :; }; triage_throttle_record() { :; }
    lock_spawn_unheld() { "$@"; }
    . "$DIR/bin/lib/rt/shards.sh"
    rt_shards ) >/dev/null 2>&1
}
newc() { # newc <case> — a fresh project, queue file and call ledger
  P="qc-$1-$$"; TS=""; QD=""; GH=1
  rm -f "$T"/issue-* "$T/calls/rest" "$T/calls/rqdrop"
  : > "$QF"
}
dispatched() { tr '\n' ' ' < "$T/calls/shard-$P" 2>/dev/null; }
summary() { grep "dispatched .* shards:" "$H/logs/$P.log" 2>/dev/null | tail -1; }
nrest() { local n; n=$(grep -c . "$T/calls/rest" 2>/dev/null); echo "${n:-0}"; }

# ═══ C: the closed-issue drop ═══════════════════════════════════════════════
# C1: a closed issue's line gives no shard and is gone after the tick
newc c1
printf 'BH-38 waiting on review of PR #12\nBH-384 waiting on review\n' > "$QF"
echo closed > "$T/issue-38"; echo open > "$T/issue-384"
shards
case " $(dispatched)" in *" 38 "*) bad "(C1) a closed issue got a shard: [$(dispatched)]" ;; *) ok ;; esac
grep -q '^BH-38 ' "$QF" && bad "(C1) the closed issue's line is still in READY-QUEUE.log" || ok
grep -q '^BH-384 ' "$QF" && ok || bad "(C1) BH-384 (open, shares the 38 prefix) lost its line"
[ "$(dispatched)" = "384 " ] && ok || bad "(C1) only the open key is dispatched: [$(dispatched)]"
case "$(summary)" in *" — closed: 38"*) ok ;; *) bad "(C1) the summary names the closed key: [$(summary)]" ;; esac
grep -q "queue-closed: dropped closed issue(s): 38" "$H/logs/$P.log" && ok || bad "(C1) one drop log line names 38"
# C2: the D1 ready-row drop was asked for BH-38 too
grep -qx 'BH-38' "$T/calls/rqdrop" 2>/dev/null && ok || bad "(C2) the ready-row drop was not asked for BH-38: [$(cat "$T/calls/rqdrop" 2>/dev/null)]"
# C1 second tick: the line is gone, so no read and no shard for 38
rm -f "$T/calls/rest" "$T/calls/shard-$P"
shards
grep -qx 38 "$T/calls/rest" 2>/dev/null && bad "(C1) the second tick read 38 again" || ok
case " $(dispatched)" in *" 38 "*) bad "(C1) the second tick offered 38" ;; *) ok ;; esac

# C3: an open issue keeps its line and the shard gets its queue text
newc c3
printf 'BH-50 waiting on review\n' > "$QF"; echo open > "$T/issue-50"
shards
grep -q '^BH-50 ' "$QF" && ok || bad "(C3) an open issue lost its line"
[ "$(dispatched)" = "50 " ] && ok || bad "(C3) the open key is dispatched: [$(dispatched)]"
[ "$(cat "$T/calls/tshq-$P-50" 2>/dev/null)" = "BH-50 waiting on review" ] && ok \
  || bad "(C3/S1) the shard gets TSH_QUEUE from rt_shards: [$(cat "$T/calls/tshq-$P-50" 2>/dev/null)]"
case "$(summary)" in *closed:*) bad "(C3) no closed item: [$(summary)]" ;; "") bad "(C3) no summary line" ;; *) ok ;; esac

# C4, C4b, C4c: an unreadable state keeps the line
for c in "c4:rc=75" "c4b:rc=44" "c4c:"; do
  newc "${c%%:*}"
  printf 'BH-60 waiting on review\n' > "$QF"; printf '%s\n' "${c#*:}" > "$T/issue-60"
  shards
  grep -q '^BH-60 ' "$QF" && ok || bad "(${c%%:*}) an unknown state dropped the line"
  [ "$(dispatched)" = "60 " ] && ok || bad "(${c%%:*}) the key is still dispatched: [$(dispatched)]"
  [ "$(grep -c "queue-closed: kept 60 .*state unknown" "$H/logs/$P.log" 2>/dev/null)" = 1 ] && ok \
    || bad "(${c%%:*}) one 'kept … unknown' line: [$(grep queue-closed "$H/logs/$P.log" 2>/dev/null)]"
done

# C5: two lines for 38 plus a board unit: one read, both lines gone, the
# board unit still gets its shard
newc c5
printf 'BH-38 waiting on review\nBH-38 UNBLOCKED by BH-12\nBH-70 waiting\n' > "$QF"
echo closed > "$T/issue-38"; echo open > "$T/issue-70"
TS='board changed: NEW 38 "ticket 38"'
shards
[ "$(grep -cx 38 "$T/calls/rest" 2>/dev/null)" = 1 ] && ok || bad "(C5) one read for 38, got $(grep -cx 38 "$T/calls/rest" 2>/dev/null)"
grep -q '^BH-38 ' "$QF" && bad "(C5) a BH-38 line survived: [$(cat "$QF")]" || ok
[ "$(dispatched)" = "38 70 " ] && ok || bad "(C5) the board unit for 38 is still dispatched: [$(dispatched)]"
[ -z "$(cat "$T/calls/tshq-$P-38" 2>/dev/null)" ] && ok || bad "(C5) the 38 shard got no queue text: [$(cat "$T/calls/tshq-$P-38" 2>/dev/null)]"

# C6: queue-line-drop.sh fails: the unit stays, no closed item
newc c6
cp "$H/bin/queue-line-drop.sh" "$T/qld.real"
printf '#!/bin/bash\necho "could not lock" >&2\nexit 1\n' > "$H/bin/queue-line-drop.sh"
printf 'BH-38 waiting on review\n' > "$QF"; echo closed > "$T/issue-38"
shards
cp "$T/qld.real" "$H/bin/queue-line-drop.sh"
[ "$(dispatched)" = "38 " ] && ok || bad "(C6) a failed drop keeps the unit: [$(dispatched)]"
case "$(summary)" in *closed:*) bad "(C6) no closed item on a failed drop: [$(summary)]" ;; "") bad "(C6) no summary" ;; *) ok ;; esac
grep -q "queue-closed: drop failed for 38" "$H/logs/$P.log" && ok || bad "(C6) the failed drop is logged"

# C7: an in-app board (SHARD_GH=0): no read at all
newc c7; GH=0
printf 'TK-38 waiting on review\n' > "$QF"; echo closed > "$T/issue-38"
shards
[ "$(nrest)" = 0 ] && ok || bad "(C7) an in-app board made $(nrest) REST reads"
grep -q '^TK-38 ' "$QF" && ok || bad "(C7) an in-app board line was dropped"
[ "$(dispatched)" = "TK-38 " ] && ok || bad "(C7) dispatched as before: [$(dispatched)]"

# C8: QUEUE_CLOSED_DROP=0: no read
newc c8
printf 'BH-38 waiting on review\n' > "$QF"; echo closed > "$T/issue-38"
QUEUE_CLOSED_DROP=0 shards
[ "$(nrest)" = 0 ] && ok || bad "(C8) the knob off made $(nrest) REST reads"
grep -q '^BH-38 ' "$QF" && ok || bad "(C8) the knob off dropped the line"

# C9: a queued build dir (QDIRS) for a closed issue is not a READY-QUEUE line:
# no read, the unit stays in scope
newc c9
echo closed > "$T/issue-38"; QD="BH-38.json"
shards
[ "$(nrest)" = 0 ] && ok || bad "(C9) a QDIRS-only key was read ($(nrest))"
[ "$(dispatched)" = "38 " ] && ok || bad "(C9) the queued build dir stays in scope: [$(dispatched)]"

# ═══ R: the repeat-refusal counter in the real triage-shard.sh ══════════════
S="$T/s"; FX="$T/fx"
mkdir -p "$S/bin/lib" "$S/logs" "$S/locks" "$S/env" "$FX"
scratch_install_closure bin/triage-shard.sh "$S" >/dev/null 2>&1 || bad "install bin/triage-shard.sh"
scratch_install_closure bin/queue-line-drop.sh "$S" >/dev/null 2>&1 || :
scratch_install_closure bin/lib/queue-closed.sh "$S" >/dev/null 2>&1 || :
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$S/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/decision-log.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/beat.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit "${LA_RC:-0}"\n' "$FX" > "$S/bin/lane-alert.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/alertline"\nexit 0\n' "$FX" > "$S/bin/alert-line.sh"
printf 'job_open() { return 1; }\ncall_guard_list() { return 1; }\n' > "$S/bin/jobs-client.sh"
printf 'rq_drop() { :; }\n' > "$S/bin/lib/ready-queue.sh"
cat > "$S/bin/agent-call.sh" <<'STUB'
#!/bin/bash
case "${SHARD_AC:-repeat}" in
  repeat)     printf 'AGENT_CALL_REFUSED call-guard repeat triage-shard paid=2/2 fp=%s\n' "${AGENT_CALL_FP:-}" > "$5"; exit 74 ;;
  unreadable) printf 'AGENT_CALL_REFUSED call-guard counter-unreadable metered claude\n' > "$5"; exit 74 ;;
esac
echo "tickets=1 done" > "$5"
STUB
chmod +x "$S/bin/"*.sh
printf 'TICK SCOPE (triage shard)\n\nWhat moved for 421:\nOn the board:\nboard: 421 changed\n' > "$S/prompt.txt"
SQ="$S/logs/READY-QUEUE.log"
RP=project-6-os-test
CTR="$S/state/queue-refused/$RP/421.n"
fresh() {
  scratch_rm "$FX"; mkdir -p "$FX"; scratch_rm "$S/state/queue-refused"
  printf 'BH-421 waiting on PR #900\nBH-4210 waiting on PR #901\n' > "$SQ"
}
shard() { # shard <mode> [queue text]
  ( export HARNESS="$S" FX SHARD_AC="$1" TSH_MODEL=m TSH_RUNNER=claude TSH_GH=1 TSH_QUEUE="${2-BH-421 waiting on PR #900}"
    bash "$S/bin/triage-shard.sh" "$RP" 421 "$S/prompt.txt" >/dev/null 2>&1 )
}
nalerts() { local n; n=$(grep -c 'queue-refused' "$FX/alerts" 2>/dev/null); echo "${n:-0}"; }

# R1-R3: 1 and 2 repeats alert nothing; the 3rd alerts once and drops the line
fresh
shard repeat
[ "$(nalerts)" = 0 ] && ok || bad "(R1) one repeat alerted"
[ "$(cut -d' ' -f1 "$CTR" 2>/dev/null)" = 1 ] && ok || bad "(R1) counter = 1: [$(cat "$CTR" 2>/dev/null)]"
shard repeat
[ "$(nalerts)" = 0 ] && ok || bad "(R2) two repeats alerted"
grep -q '^BH-421 ' "$SQ" && ok || bad "(R2) the line went after 2 repeats"
shard repeat
[ "$(nalerts)" = 1 ] && ok || bad "(R3) the 3rd repeat must alert once, got $(nalerts)"
grep -q -- "--severity warn --id queue-refused-$RP-421 triage-queue .*421.*refused 3 times in a row.*dropped" "$FX/alerts" && ok \
  || bad "(R3) alert text: [$(cat "$FX/alerts" 2>/dev/null)]"
grep -q '^BH-421 ' "$SQ" && bad "(R3) the line is still in the queue" || ok
grep -q '^BH-4210 ' "$SQ" && ok || bad "(R3) BH-4210 lost its line"
[ -e "$CTR" ] && bad "(R3) the counter survived the drop" || ok
# R4: a 4th tick has no queue line: nothing written
shard repeat ""
[ "$(nalerts)" = 1 ] && ok || bad "(R4) a 4th tick alerted again ($(nalerts))"
[ -e "$CTR" ] && bad "(R4) a 4th tick wrote a counter" || ok

# R5: the drop fails: the alert says so
fresh
cp "$S/bin/queue-line-drop.sh" "$T/sqld.real"
printf '#!/bin/bash\necho "could not lock" >&2\nexit 1\n' > "$S/bin/queue-line-drop.sh"
shard repeat; shard repeat; shard repeat
cp "$T/sqld.real" "$S/bin/queue-line-drop.sh"
[ "$(nalerts)" = 1 ] && ok || bad "(R5) one alert on a failed drop, got $(nalerts)"
grep -q "drop failed" "$FX/alerts" && ok || bad "(R5) the alert says drop failed: [$(cat "$FX/alerts" 2>/dev/null)]"
grep -q "refused 3 times in a row.* dropped" "$FX/alerts" && bad "(R5) the alert claims a drop" || ok
grep -q '^BH-421 ' "$SQ" && ok || bad "(R5) the line is gone although the drop failed"

# R6: 2 repeats, then a paid run, then 1 repeat: no alert, counter = 1
fresh
shard repeat; shard repeat; shard ok; shard repeat
[ "$(nalerts)" = 0 ] && ok || bad "(R6) a broken run alerted ($(nalerts))"
[ "$(cut -d' ' -f1 "$CTR" 2>/dev/null)" = 1 ] && ok || bad "(R6) counter = 1 after the reset: [$(cat "$CTR" 2>/dev/null)]"
# a counter-unreadable refusal resets too
shard repeat; shard unreadable; shard repeat
[ "$(cut -d' ' -f1 "$CTR" 2>/dev/null)" = 1 ] && ok || bad "(R6) counter-unreadable resets: [$(cat "$CTR" 2>/dev/null)]"

# R7: changed queue text restarts the count
fresh
shard repeat; shard repeat
shard repeat "BH-421 UNBLOCKED by BH-12"
[ "$(nalerts)" = 0 ] && ok || bad "(R7) changed text still alerted"
[ "$(cut -d' ' -f1 "$CTR" 2>/dev/null)" = 1 ] && ok || bad "(R7) changed text restarts at 1: [$(cat "$CTR" 2>/dev/null)]"

# R8: lane-alert fails: the alert goes through bin/alert-line.sh, once
fresh
( export LA_RC=1; shard repeat; shard repeat; shard repeat )
[ "$(grep -c 'queue-refused' "$FX/alertline" 2>/dev/null)" = 1 ] && ok \
  || bad "(R8) one alert-line fallback when lane-alert fails: [$(cat "$FX/alertline" 2>/dev/null)]"
grep -q -- "--id queue-refused-$RP-421 --project $RP" "$FX/alertline" 2>/dev/null && ok || bad "(R8) the fallback keeps the alert id"
[ -s "$S/logs/ALERTS.log" ] && grep -q queue-refused "$S/logs/ALERTS.log" && bad "(R8) a raw ALERTS.log write" || ok

# ═══ K: the knob clamp in _qc_knobs (catalog min/max) ═══════════════════════
# qn <key> <queue text> — one repeat note through the real lib, in a subshell.
qn() { ( . "$S/bin/lib/queue-closed.sh"; qc_refusal_note "$S" "$RP" "$1" repeat "$2" ) >/dev/null 2>&1; }
kal() { local n; n=$(grep -c -- "--id queue-refused-$RP-$1 " "$FX/alerts" 2>/dev/null); echo "${n:-0}"; }
# K1: KEEP=0 is clamped to 3600: the counter survives, the 3rd note drops + alerts once
fresh; printf 'BH-9301 waiting on PR #1\n' >> "$SQ"
for _ in 1 2 3; do QUEUE_REFUSED_KEEP_S=0 qn 9301 "BH-9301 waiting on PR #1"; done
[ "$(kal 9301)" = 1 ] && ok || bad "(K1) KEEP=0: one alert after 3 repeats, got $(kal 9301)"
grep -q '^BH-9301 ' "$SQ" && bad "(K1) KEEP=0: the line was not dropped" || ok
# K2: KEEP=60 (under the minimum) is clamped to 3600: a counter aged 2 minutes
# between the notes survives (unclamped, -mmin +1 would prune it), as K1
fresh; printf 'BH-9302 waiting on PR #2\n' >> "$SQ"
for _ in 1 2 3; do
  QUEUE_REFUSED_KEEP_S=60 qn 9302 "BH-9302 waiting on PR #2"
  [ -e "$S/state/queue-refused/$RP/9302.n" ] && touch -d '2 minutes ago' "$S/state/queue-refused/$RP/9302.n"
done
[ "$(kal 9302)" = 1 ] && ok || bad "(K2) KEEP=60: one alert after 3 repeats, got $(kal 9302)"
grep -q '^BH-9302 ' "$SQ" && bad "(K2) KEEP=60: the line was not dropped" || ok
# K3: KEEP=604800: an 8-day-old counter is pruned on the next call, a 1-day-old one stays
fresh; KD="$S/state/queue-refused/$RP"; mkdir -p "$KD"
echo "2 x" > "$KD/9303.n"; touch -d '8 days ago' "$KD/9303.n"
echo "2 x" > "$KD/9304.n"; touch -d '1 day ago' "$KD/9304.n"
QUEUE_REFUSED_KEEP_S=604800 qn 9305 "BH-9305 waiting"
[ -e "$KD/9303.n" ] && bad "(K3) the 8-day-old counter was not pruned" || ok
[ -e "$KD/9304.n" ] && ok || bad "(K3) the 1-day-old counter was pruned"
# K4: the clamp table, and DROP_AFTER=0 stays off
kv() { ( set +u; unset QUEUE_REFUSED_DROP_AFTER QUEUE_REFUSED_KEEP_S
  [ -n "$1" ] && export QUEUE_REFUSED_DROP_AFTER="$1"; [ -n "$2" ] && export QUEUE_REFUSED_KEEP_S="$2"
  . "$S/bin/lib/queue-closed.sh"; _qc_knobs "$RP"; echo "rc=$? $_QC_AFTER $_QC_KEEP" ) 2>/dev/null; }
while read -r a k want; do
  got=$(kv "${a#_}" "${k#_}")
  [ "$got" = "rc=0 ${want/_/ }" ] && ok || bad "(K4) AFTER=[${a#_}] KEEP=[${k#_}]: want [rc=0 ${want/_/ }], got [$got]"
done <<'TBL'
0 0 0_3600
3 60 3_3600
50 3599 50_3600
51 0800 50_3600
999 3600 50_3600
_ 604800 3_604800
08 2592000 8_2592000
abc 2592001 3_2592000
-5 99999999 3_2592000
_ abc 3_604800
_ -5 3_604800
TBL
fresh; printf 'BH-9306 waiting\n' >> "$SQ"
for _ in 1 2 3; do QUEUE_REFUSED_DROP_AFTER=0 qn 9306 "BH-9306 waiting"; done
[ "$(kal 9306)" = 0 ] && ok || bad "(K4) DROP_AFTER=0 alerted ($(kal 9306))"
grep -q '^BH-9306 ' "$SQ" && ok || bad "(K4) DROP_AFTER=0 dropped the line"

[ ! -s "$T/calls/vendor" ] && ok || bad "(V) 0 vendor calls: [$(cat "$T/calls/vendor")]"

echo "triage-queue-closed.bh-9286: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
