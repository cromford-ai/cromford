#!/bin/bash
# tests/triage-shard-runner-fault.bh-10274-test.sh — BH-10274: a triage shard
# whose runner fails before the model answers (rc 1/126/127, fast, no DECISION
# or tickets= text) is retried ONCE on the other runner in the same shard, the
# fault is one `TRIAGE RUNNER FAULT:` ALERTS line (its own alert family), and
# the shard summary keeps the first error line, not the last stack frame.
#
#   F1-F12  rf_start_fault decision table (bin/lib/runner-fault.sh)
#   D1-D10  rf_first_error picks the first error line
#   O1-O4   rf_other_runner
#   A1      codex rc 1 + Node trace, claude answers: retried, launches, 1 alert
#   R1      rc 126 primary: retried
#   R2      the retry also faults (ENOSPC): 2 calls only, 1 combined alert
#   R3      TRIAGE_SHARD_FAULT_RETRY=0: no retry, 1 combined alert
#   R4      the retry is refused (call-guard rc 74): RC1 kept, no park
#   R5      agent-call already failed over to the other runner: no retry
#   R6      the retry fails and the re-arm fails: one combined line
#   N1-N3   no fault (model answered / timeout) and lib absent: today's lines
#   S1-S3   the summary: first error line on a failure, tail -3 on rc 0
#   RT1     one alert family for every fault line, not the generic line's
#   V1      0 vendor calls
#
# Drives the REAL bin/triage-shard.sh with agent-call stubbed (the BH-9863 rig).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/triage-shard-runner-fault.bh-10274-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
export HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1
unset TSH_QUEUE TRIAGE_SHARD_FAULT_RETRY TRIAGE_SHARD_FAULT_S TRIAGE_SHARD_RETRY_RUNNER TRIAGE_SHARD_ERR_LINE_MAX AGENT_CALL_RUNNERS

mkdir -p "$T/rbin" "$T/calls"
for v in gh claude codex curl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls/vendor"\nexit 1\n' "$v" "$T" > "$T/rbin/$v"
done
printf '#!/bin/bash\nexec "$@"\n' > "$T/rbin/setsid"
chmod +x "$T/rbin/"*
export PATH="$T/rbin:$PATH"

# ── the lib, sourced on its own (F, D, O, RT) ─────────────────────────────
LIB_OK=0
# shellcheck source=bin/lib/runner-fault.sh
. "$REPO/bin/lib/runner-fault.sh" 2>/dev/null && command -v rf_start_fault >/dev/null 2>&1 && LIB_OK=1
[ "$LIB_OK" = 1 ] && ok || bad "lib: bin/lib/runner-fault.sh sources and defines rf_start_fault"

L="$T/lib"; mkdir -p "$L"
TRACE="$L/trace"
cat > "$TRACE" <<'TR'
file:///usr/lib/node_modules/@openai/codex/bin/codex.js:12
    throw err;
    ^

Error: Cannot find module 'x'
    at Module._resolveFilename (node:internal/modules/cjs/loader:1145:15)
    at Module._load (node:internal/modules/cjs/loader:986:27)
    at Object.<anonymous> (/usr/lib/node_modules/@openai/codex/bin/codex.js:12:1)
    at node:internal/main/run_main_module:28:49
TR
sf() { # sf <name> <want 0|1> <rc> <secs> <file-content>
  local f="$L/sf.$1"; printf '%s' "$5" > "$f"
  rf_start_fault "$3" "$4" "$f" 2>/dev/null; local got=$?
  [ "$got" = "$2" ] && ok || bad "$1: rf_start_fault rc=$3 ${4}s -> $got, want $2"
}
if [ "$LIB_OK" = 1 ]; then
  sf F1  0 1   3   "$(cat "$TRACE")"
  sf F2  0 126 1   'bash: codex: Permission denied'
  sf F3  0 127 0   ''
  sf F4  0 1   120 "$(cat "$TRACE")"
  sf F5  1 1   121 "$(cat "$TRACE")"
  sf F6  1 1   3   $'working\nDECISION: TK-1 :: hold :: x\n'
  sf F7  1 1   3   $'tickets=1 new=0\n'
  sf F8  1 74  1   $'AGENT_CALL_REFUSED call-guard repeat triage-shard TK-1\n'
  sf F9  1 2   1   $'AGENT_CALL_REFUSED runners-restricted claude\n'
  sf F10 1 1   1   $'AGENT_CALL_REFUSED runner-lock x\n'
  sf F11 1 124 3   ''
  sf F12 1 75  3   ''
  sf F13 1 0   3   ''
  ( export TRIAGE_SHARD_FAULT_S=10; rf_start_fault 1 11 "$L/sf.F3" ) && bad "F14: TRIAGE_SHARD_FAULT_S=10 makes 11s not a fault" || ok
  ( export TRIAGE_SHARD_FAULT_S=bogus; rf_start_fault 1 120 "$L/sf.F3" ) && ok || bad "F15: a bogus TRIAGE_SHARD_FAULT_S reads as 120"
  rf_start_fault 1 3 "$L/does-not-exist" && ok || bad "F16: no output file at all is a start fault"

  fe() { # fe <name> <want> <file-content>...
    local n="$1" want="$2" i=0 fs=(); shift 2
    for c in "$@"; do i=$((i+1)); printf '%s' "$c" > "$L/fe.$n.$i"; fs+=("$L/fe.$n.$i"); done
    local got; got=$(rf_first_error "${fs[@]}")
    [ "$got" = "$want" ] && ok || bad "$n: rf_first_error -> [$got], want [$want]"
  }
  fe D1  "Error: Cannot find module 'x'" "$(cat "$TRACE")"
  fe D2  'TypeError: fetch failed' $'    at a (/x.js:1:1)\n    at b (/y.js:2:2)\nTypeError: fetch failed\n    at c (/z.js:3:3)\n'
  fe D3  'ERROR: stream error: exceeded retry limit' $'starting\nERROR: stream error: exceeded retry limit\n'
  fe D4  "error: unexpected argument '--foo' found" $'Usage: codex\nerror: unexpected argument \'--foo\' found\n'
  fe D5  'npm ERR! code ENOSPC' $'no errors found\nstderr: ok\nErrorBoundary rendered\n    at Object.<anonymous> (/x.js:1:1)\nnpm ERR! code ENOSPC\n'
  fe D6  'at Object.<anonymous> (/x.js:1:1)' $'    at Object.<anonymous> (/x.js:1:1)\n    at b (/y.js:2:2)\n'
  fe D7  '' ''
  fe D8  'Error: boom in out' '' $'thinking\nError: boom in out\n'
  LONG="Error: $(printf 'x%.0s' $(seq 1 500))"
  fe D9  "${LONG:0:300}" "$LONG"
  fe D10 'Error: crlf line' $'\r\nError: crlf line\r\n'
  fe D11 'warming up' $'file:///x/codex.js:12\n    ^\nwarming up\n'
  ( export TRIAGE_SHARD_ERR_LINE_MAX=50; g=$(rf_first_error "$L/fe.D9.1"); [ "${#g}" = 50 ] ) && ok || bad "D12: TRIAGE_SHARD_ERR_LINE_MAX=50 cuts to 50"

  [ "$(rf_other_runner codex)" = claude ] && ok || bad "O1: codex -> claude"
  [ "$(rf_other_runner claude)" = codex ] && ok || bad "O2: claude -> codex"
  [ "$(TRIAGE_SHARD_RETRY_RUNNER=grok rf_other_runner codex)" = grok ] && ok || bad "O3: knob grok -> grok"
  [ "$(TRIAGE_SHARD_RETRY_RUNNER=codex rf_other_runner codex)" = claude ] && ok || bad "O4: knob equal to the failed runner -> default"
  [ "$(TRIAGE_SHARD_RETRY_RUNNER='x y' rf_other_runner codex)" = claude ] && ok || bad "O5: an invalid knob -> default"

  # RT1: the fault lines share one family, and it is not the generic line's.
  L1="2026-11-26 11:28:01Z $(rf_fault_line project-3 TK-12 codex 1 3 "Error: Cannot find module 'x'" 'retried on claude: rc=0')"
  L2="2026-11-26 11:29:44Z $(rf_fault_line project-3 TK-345 codex 126 14 "Error: Cannot find module 'x'" 'retried on claude: rc=0')"
  LG="2026-11-26 11:28:01Z [project-3/TK-12] triage shard exited rc=1 (see /x/project-3.triage-TK-12.out) — ticket put back in scope for the next tick"
  case "$L1" in *"[project-3/TK-12] TRIAGE RUNNER FAULT: codex rc=1 before the model answered (3s): Error: Cannot find module 'x' — retried on claude: rc=0") ok ;;
    *) bad "RT1: rf_fault_line format: [$L1]" ;; esac
  case "$(rf_fault_line p K codex 1 2 '' 'x')" in *"(2s): (no error text) — x") ok ;; *) bad "RT1: empty error -> (no error text)" ;; esac
  F1=$(python3 "$REPO/bin/alert_family.py" family "$L1"); F2=$(python3 "$REPO/bin/alert_family.py" family "$L2")
  FG=$(python3 "$REPO/bin/alert_family.py" family "$LG")
  [ -n "$F1" ] && [ "$F1" = "$F2" ] && ok || bad "RT1: two fault lines share one family ($F1 / $F2)"
  [ "$F1" != "$FG" ] && ok || bad "RT1: the fault family differs from the generic shard line ($F1)"
fi

# ── the shard rig (A, R, N, S) ───────────────────────────────────────────
S="$T/s"; FX="$T/fx"
mkdir -p "$S/bin/lib" "$S/logs" "$S/locks" "$S/env" "$S/state" "$FX"
scratch_install_closure bin/triage-shard.sh "$S" >/dev/null 2>&1 || bad "install bin/triage-shard.sh"
rm -f "$S/bin/lib/triage-state.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$S/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/decision-log.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s/beats"\nexit 0\n' "$FX" > "$S/bin/beat.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/lane-alert.sh"
# bin/alert-line.sh is the REAL one: the fault line goes through it.
scratch_install_closure bin/alert-line.sh "$S" >/dev/null 2>&1 || bad "install bin/alert-line.sh"
printf '#!/bin/bash\n[ "${1:-}" = --projects-on-box ] && echo onlyone\nexit 0\n' > "$S/bin/fleet-conf.sh"
cat > "$S/bin/jobs-client.sh" <<'STUB'
job_open() { return 1; }
call_guard_list() { return 1; }
_jobs_req() { echo '{"queue":[]}'; }
STUB
# Park libs: record any call (R4 asserts none).
printf 'triage_park_on_refusal() { echo "park $*" >> "$FX/park"; }\ntriage_park_note() { :; }\n' > "$S/bin/lib/triage-park.sh"
printf 'trp_on_repeat() { echo "trp $*" >> "$FX/park"; }\n' > "$S/bin/lib/triage-repeat-park.sh"
# The stub agent-call: per RUNNER_TRIAGE, $FX/<runner>.{rc,out,err,runner}.
cat > "$S/bin/agent-call.sh" <<'STUB'
#!/bin/bash
r="${RUNNER_TRIAGE:-}"
printf 'RUNNER_TRIAGE=%s AGENT_CALL_RUNNERS=%s\n' "$r" "${AGENT_CALL_RUNNERS:-}" >> "$FX/calls"
cat "$FX/$r.out" > "$5" 2>/dev/null || : > "$5"
cat "$FX/$r.err" > "$5.err" 2>/dev/null || : > "$5.err"
if [ -f "$FX/$r.runner" ]; then cat "$FX/$r.runner" > "$5.runner"; else echo "$r" > "$5.runner"; fi
exit "$(cat "$FX/$r.rc" 2>/dev/null || echo 0)"
STUB
chmod +x "$S/bin/"*.sh
export FX

RP=""
shard() { # shard <section> [VAR=value ...] — primary runner codex
  local sec="$1"; shift
  RP="project-3-t10274-$sec"
  : > "$FX/beats"; : > "$FX/calls"; : > "$FX/park"; : > "$S/logs/ALERTS.log"
  # The board fingerprint the dispatcher consumed: a re-arm drops TK-1 from it.
  rm -f "$S/state/$RP.gate.json"
  case " $* " in *" TSH_NO_GATE=1 "*) ;; *) printf '{"tickets":[{"id":"TK-1"}]}' > "$S/state/$RP.gate.json" ;; esac
  ( export HARNESS="$S" TSH_MODEL=m TSH_RUNNER=codex TSH_GH=0
    for kv in "$@"; do export "${kv?}"; done
    printf 'TICK SCOPE (triage shard)\n\nWhat moved for TK-1:\nboard: TK-1 changed\n' > "$S/prompt-$sec.txt"
    bash "$S/bin/triage-shard.sh" "$RP" TK-1 "$S/prompt-$sec.txt" >/dev/null 2>&1 )
}
fx() { # fx <runner> <rc> <out> [<err>] [<runner-record>]
  rm -f "$FX/$1".*
  echo "$2" > "$FX/$1.rc"; printf '%s' "$3" > "$FX/$1.out"; printf '%s' "${4:-}" > "$FX/$1.err"
  [ -n "${5:-}" ] && echo "$5" > "$FX/$1.runner"; return 0
}
ncalls()  { grep -c . "$FX/calls" 2>/dev/null || true; }
nalerts() { grep -c . "$S/logs/ALERTS.log" 2>/dev/null || true; }
rearmed() { ! grep -q '"TK-1"' "$S/state/$RP.gate.json" 2>/dev/null; }
alerts()  { cat "$S/logs/ALERTS.log" 2>/dev/null; }
logline() { grep " shard TK-1 rc=" "$S/logs/$RP.log" 2>/dev/null | tail -1; }
beatsum() { jq -r 'select(.kind=="run") | .summary' "$FX/beats" 2>/dev/null | tail -1; }
TR="$(cat "$TRACE")"
DEC='DECISION: TK-1 :: launch :: ready'

# ── A1: the ticket's acceptance ──────────────────────────────────────────
fx codex 1 "$TR" "$TR"; fx claude 0 "$DEC"
shard A1
[ "$(ncalls)" = 2 ] && ok || bad "A1: 2 agent-calls: [$(cat "$FX/calls")]"
[ "$(sed -n 2p "$FX/calls")" = "RUNNER_TRIAGE=claude AGENT_CALL_RUNNERS=claude" ] && ok || bad "A1: 2nd call pinned to claude: [$(sed -n 2p "$FX/calls")]"
[ "$(sed -n 1p "$FX/calls")" = "RUNNER_TRIAGE=codex AGENT_CALL_RUNNERS=" ] && ok || bad "A1: 1st call unchanged: [$(sed -n 1p "$FX/calls")]"
case "$(logline)" in *" shard TK-1 rc=0 :: $DEC ["*" runner=claude "*) ok ;; *) bad "A1: shard log line rc=0 + DECISION + runner=claude: [$(logline)]" ;; esac
[ "$(nalerts)" = 1 ] && ok || bad "A1: exactly 1 ALERTS line: [$(alerts)]"
case "$(alerts)" in *"[$RP/TK-1] TRIAGE RUNNER FAULT: codex rc=1 before the model answered ("*"s): Error: Cannot find module 'x' — retried on claude: rc=0") ok ;;
  *) bad "A1: the fault line names codex, the error and the retry: [$(alerts)]" ;; esac
grep -q 'triage shard exited rc=' "$S/logs/ALERTS.log" && bad "A1: no generic 'triage shard exited' line" || ok
rearmed && bad "A1: the launched ticket is not re-armed" || ok

# ── R1: rc 126 ───────────────────────────────────────────────────────────
fx codex 126 'bash: /usr/bin/codex: Permission denied' 'bash: /usr/bin/codex: Permission denied'; fx claude 0 "$DEC"
shard R1
[ "$(ncalls)" = 2 ] && ok || bad "R1: rc 126 retried: [$(cat "$FX/calls")]"
case "$(alerts)" in *"TRIAGE RUNNER FAULT: codex rc=126 "*"(no error text)"*|*"TRIAGE RUNNER FAULT: codex rc=126 "*"Permission denied — retried on claude: rc=0") ok ;; *) bad "R1: fault line: [$(alerts)]" ;; esac
case "$(logline)" in *" rc=0 :: $DEC ["*) ok ;; *) bad "R1: launched: [$(logline)]" ;; esac

# ── R2: the retry also faults ────────────────────────────────────────────
fx codex 1 'npm ERR! code ENOSPC' 'npm ERR! code ENOSPC'
fx claude 1 'Error: ENOSPC: no space left on device, write' 'Error: ENOSPC: no space left on device, write'
shard R2
[ "$(ncalls)" = 2 ] && ok || bad "R2: exactly 2 calls: [$(cat "$FX/calls")]"
[ "$(nalerts)" = 1 ] && ok || bad "R2: exactly 1 ALERTS line: [$(alerts)]"
case "$(alerts)" in *"TRIAGE RUNNER FAULT: codex rc=1 "*"npm ERR! code ENOSPC — retried on claude: rc=1: Error: ENOSPC: no space left on device, write — ticket put back in scope") ok ;;
  *) bad "R2: one combined line: [$(alerts)]" ;; esac
rearmed && ok || bad "R2: the ticket is re-armed"
case "$(logline)" in *" shard TK-1 rc=1 :: error: "*ENOSPC*) ok ;; *) bad "R2: shard rc=1 and error summary: [$(logline)]" ;; esac

# ── R3: the switch off ───────────────────────────────────────────────────
fx codex 1 "$TR" "$TR"; fx claude 0 "$DEC"
shard R3 TRIAGE_SHARD_FAULT_RETRY=0
[ "$(ncalls)" = 1 ] && ok || bad "R3: no retry: [$(cat "$FX/calls")]"
[ "$(nalerts)" = 1 ] && ok || bad "R3: exactly 1 ALERTS line: [$(alerts)]"
case "$(alerts)" in *"TRIAGE RUNNER FAULT: codex rc=1 "*"— no retry: TRIAGE_SHARD_FAULT_RETRY=0 — ticket put back in scope") ok ;; *) bad "R3: [$(alerts)]" ;; esac

# ── R4: the retry is refused before the call ─────────────────────────────
fx codex 1 "$TR" "$TR"
fx claude 74 'AGENT_CALL_REFUSED call-guard repeat triage-shard TK-1 2/2 today'
shard R4
[ "$(ncalls)" = 2 ] && ok || bad "R4: 2 calls: [$(cat "$FX/calls")]"
case "$(logline)" in *" shard TK-1 rc=1 :: "*) ok ;; *) bad "R4: RC1 restored: [$(logline)]" ;; esac
[ "$(nalerts)" = 1 ] && ok || bad "R4: exactly 1 ALERTS line: [$(alerts)]"
case "$(alerts)" in *"— retry on claude refused before the call (AGENT_CALL_REFUSED call-guard repeat"*"— ticket put back in scope") ok ;; *) bad "R4: [$(alerts)]" ;; esac
[ ! -s "$FX/park" ] && ok || bad "R4: no park call: [$(cat "$FX/park")]"
case "$(logline)" in *" rc=1 :: error: Error: Cannot find module 'x' ["*) ok ;; *) bad "R4: the summary keeps the first call's error: [$(logline)]" ;; esac
# R4b (lead review 10326): the first call's output survives the retry as $OUT.first*.
FO="$S/logs/$RP.triage-TK-1.out"
grep -q "Cannot find module 'x'" "$FO.first" 2>/dev/null && ok || bad "R4b: the first call's output kept in .out.first"
grep -q "Cannot find module 'x'" "$FO.first.err" 2>/dev/null && ok || bad "R4b: the first call's stderr kept in .out.first.err"
[ "$(cat "$FO.first.runner" 2>/dev/null)" = codex ] && ok || bad "R4b: the first call's runner kept in .out.first.runner"

# ── R7: the refusal marker is cut by the knob row, not a literal ─────────
MARK7="AGENT_CALL_REFUSED call-guard repeat triage-shard TK-1 $(printf 'y%.0s' $(seq 1 300))"
fx codex 1 "$TR" "$TR"; fx claude 74 "$MARK7"
shard R7 TRIAGE_SHARD_ERR_LINE_MAX=60
case "$(alerts)" in *"refused before the call (${MARK7:0:60}) — ticket put back in scope") ok ;;
  *) bad "R7: TRIAGE_SHARD_ERR_LINE_MAX=60 cuts the refusal marker to 60: [$(alerts)]" ;; esac
shard R7d
case "$(alerts)" in *"refused before the call (${MARK7:0:300}) — ticket put back in scope") ok ;;
  *) bad "R7: the marker cut defaults to 300 (the knob row's default): [$(alerts)]" ;; esac

# ── R5: agent-call already failed over to claude ─────────────────────────
fx codex 1 "$TR" "$TR" claude; fx claude 0 "$DEC"
shard R5
[ "$(ncalls)" = 1 ] && ok || bad "R5: no retry: [$(cat "$FX/calls")]"
case "$(alerts)" in *"TRIAGE RUNNER FAULT: claude rc=1 "*"— no retry: codex already tried in this call — ticket put back in scope") ok ;; *) bad "R5: [$(alerts)]" ;; esac

# ── R6: the retry fails and the re-arm fails: still one combined line ──
fx codex 1 "$TR" "$TR"; fx claude 1 'Error: second crash' 'Error: second crash'
shard R6 TSH_NO_GATE=1
[ "$(nalerts)" = 1 ] && ok || bad "R6: exactly 1 ALERTS line: [$(alerts)]"
case "$(alerts)" in *"TRIAGE RUNNER FAULT: codex rc=1 "*"retried on claude: rc=1: Error: second crash — board fingerprint could NOT be re-armed; check state/$RP.gate.json") ok ;;
  *) bad "R6: the combined line says the re-arm failed: [$(alerts)]" ;; esac

# ── N1-N3: no fault, or no lib ───────────────────────────────────────────
fx codex 1 $'DECISION: TK-1 :: hold :: x\nError: later\n' ''; fx claude 0 "$DEC"
shard N1
[ "$(ncalls)" = 1 ] && ok || bad "N1: the model answered, no retry: [$(cat "$FX/calls")]"
grep -q 'TRIAGE RUNNER FAULT' "$S/logs/ALERTS.log" && bad "N1: no fault line" || ok
case "$(alerts)" in *"[$RP/TK-1] triage shard exited rc=1 (see "*") — ticket put back in scope for the next tick") ok ;; *) bad "N1: today's generic line: [$(alerts)]" ;; esac

fx codex 124 '' ''; fx claude 0 "$DEC"
shard N2
[ "$(ncalls)" = 1 ] && [ "$(nalerts)" = 1 ] && grep -q 'triage shard exited rc=124' "$S/logs/ALERTS.log" && ok || bad "N2: rc 124 is not a runner fault: [$(cat "$FX/calls")] [$(alerts)]"

mv "$S/bin/lib/runner-fault.sh" "$T/runner-fault.sh.away" 2>/dev/null
fx codex 1 "$TR" "$TR"; fx claude 0 "$DEC"
shard N3
[ "$(ncalls)" = 1 ] && ok || bad "N3: no lib, no retry: [$(cat "$FX/calls")]"
case "$(alerts)" in *"triage shard exited rc=1 (see "*") — ticket put back in scope for the next tick") ok ;; *) bad "N3: today's line: [$(alerts)]" ;; esac
case "$(logline)" in *" rc=1 :: "*"    at Object.<anonymous> (/usr/lib/"*) ok ;; *) bad "N3: today's tail -3 summary: [$(logline)]" ;; esac
mv "$T/runner-fault.sh.away" "$S/bin/lib/runner-fault.sh" 2>/dev/null

# ── S1-S3: the summary ───────────────────────────────────────────────────
fx codex 1 "$TR" "$TR"
shard S1 TRIAGE_SHARD_FAULT_RETRY=0
[ "$(beatsum)" = "shard TK-1: error: Error: Cannot find module 'x'" ] && ok || bad "S1: beat summary keeps the first error line: [$(beatsum)]"
case "$(logline)" in *" shard TK-1 rc=1 :: error: Error: Cannot find module 'x' ["*) ok ;; *) bad "S2: log line keeps the first error line: [$(logline)]" ;; esac
fx codex 0 $'line a\nline b\n'
shard S3
case "$(logline)" in *" rc=0 :: line a line b  ["*) ok ;; *) bad "S3: rc 0 keeps tail -3: [$(logline)]" ;; esac
[ "$(ncalls)" = 1 ] && [ "$(nalerts)" = 0 ] && ok || bad "S3: rc 0: 1 call, no alert: [$(cat "$FX/calls")] [$(alerts)]"

[ ! -s "$T/calls/vendor" ] && ok || bad "V1: 0 vendor calls: [$(cat "$T/calls/vendor")]"
echo "triage-shard-runner-fault.bh-10274: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
