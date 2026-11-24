#!/bin/bash
# tests/shard-run-summary.bh-9863-test.sh — BH-9863: the triage shard run
# summary (bin/triage-shard.sh, the `shard <KEY> rc=<n> :: <summary>` log line
# and the console beat `summary`) keeps the whole newest DECISION line. It was
# cut to 160 chars, so the console showed "DECISION: TK-774 :: hold :: waits on"
# and never the reason.
#
#   S1  a 300-char DECISION reason survives whole in the log line and the beat
#   S2  tickets= plus a DECISION keeps `rc=0 :: tickets=` first (the no-op
#       streak detector in bin/pipeline-health.sh reads that order)
#   S3  no DECISION line: today's text
#   S4  a DECISION for another key is used only when this KEY has none
#   V1  0 vendor calls
#
# Drives the REAL bin/triage-shard.sh with agent-call stubbed (the
# tests/triage-repeat-refused.bh-9818 A-rig).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/shard-run-summary.bh-9863-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
export HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1
unset TSH_QUEUE

mkdir -p "$T/rbin" "$T/calls"
for v in gh claude curl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/calls/vendor"\nexit 1\n' "$v" "$T" > "$T/rbin/$v"
done
printf '#!/bin/bash\nexec "$@"\n' > "$T/rbin/setsid"
chmod +x "$T/rbin/"*
export PATH="$T/rbin:$PATH"

S="$T/s"; FX="$T/fx"
mkdir -p "$S/bin/lib" "$S/logs" "$S/locks" "$S/env" "$S/state" "$FX"
scratch_install_closure bin/triage-shard.sh "$S" >/dev/null 2>&1 || bad "install bin/triage-shard.sh"
rm -f "$S/bin/lib/triage-state.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$S/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/decision-log.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s/beats"\nexit 0\n' "$FX" > "$S/bin/beat.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/lane-alert.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/alert-line.sh"
printf '#!/bin/bash\n[ "${1:-}" = --projects-on-box ] && echo onlyone\nexit 0\n' > "$S/bin/fleet-conf.sh"
cat > "$S/bin/jobs-client.sh" <<'STUB'
job_open() { return 1; }
call_guard_list() { return 1; }
_jobs_req() { echo '{"queue":[]}'; }
STUB
# The stub session prints $FX/out as its whole output.
cat > "$S/bin/agent-call.sh" <<'STUB'
#!/bin/bash
cp "$FX/out" "$5"; exit 0
STUB
chmod +x "$S/bin/"*.sh
export FX
RP=project-3-t9863
printf 'TICK SCOPE (triage shard)\n\nWhat moved for TK-774:\nqueue: TK-774 waiting\n' > "$S/prompt.txt"

shard() { # shard <KEY>
  : > "$FX/beats"; rm -f "$S/logs/$RP.log"
  ( export HARNESS="$S" TSH_MODEL=m TSH_RUNNER=claude TSH_GH=0 TSH_QUEUE="$1 waiting on PR #12"
    bash "$S/bin/triage-shard.sh" "$RP" "$1" "$S/prompt.txt" >/dev/null 2>&1 )
}
logline() { grep " shard $1 rc=" "$S/logs/$RP.log" 2>/dev/null | tail -1; }
beatsum() { jq -r 'select(.kind=="run") | .summary' "$FX/beats" 2>/dev/null | tail -1; }

REASON="waits on TK-758 PR #12 open; the plans share app/x.ts and app/y.ts$(printf ' and more detail%.0s' $(seq 1 16)) END-OF-REASON"
DEC="DECISION: TK-774 :: hold :: $REASON"
[ "${#DEC}" -gt 300 ] || bad "setup: the DECISION line must pass 300 chars (${#DEC})"

# ── S1: the whole DECISION line survives ─────────────────────────────────
printf 'Working on TK-774.\n%s\n' "$DEC" > "$FX/out"
shard TK-774
case "$(logline TK-774)" in *"$DEC ["*) ok ;; *) bad "S1: the log line keeps the whole DECISION line: [$(logline TK-774)]" ;; esac
[ "$(beatsum)" = "shard TK-774: $DEC" ] && ok || bad "S1: the beat summary keeps the whole DECISION line: [$(beatsum)]"

# ── S2: tickets= first, then the DECISION ────────────────────────────────
printf 'tickets=1 new=0 changed=1 built=0\n%s\n' "$DEC" > "$FX/out"
shard TK-774
case "$(logline TK-774)" in *" shard TK-774 rc=0 :: tickets=1 new=0 changed=1 built=0 :: $DEC ["*) ok ;;
  *) bad "S2: 'rc=0 :: tickets=... :: DECISION ...': [$(logline TK-774)]" ;; esac

# ── S3: no DECISION line keeps today's text ─────────────────────────────
printf 'tickets=2 new=0 changed=0 built=0\nnothing to do\n' > "$FX/out"
shard TK-774
case "$(logline TK-774)" in *" rc=0 :: tickets=2 new=0 changed=0 built=0 ["*) ok ;;
  *) bad "S3: no DECISION: today's tickets= text only: [$(logline TK-774)]" ;; esac
printf 'line a\nline b\n' > "$FX/out"
shard TK-774
case "$(logline TK-774)" in *" rc=0 :: line a line b  ["*) ok ;;
  *) bad "S3: no DECISION and no tickets=: the last 3 lines as today: [$(logline TK-774)]" ;; esac

# ── S4: this KEY's DECISION wins over a later one for another key ────────
printf '%s\nDECISION: TK-7740 :: skip :: other ticket\n' "$DEC" > "$FX/out"
shard TK-774
case "$(logline TK-774)" in *":: $DEC ["*) ok ;; *) bad "S4: this key's DECISION line wins: [$(logline TK-774)]" ;; esac
printf 'DECISION: TK-7740 :: skip :: other ticket\n' > "$FX/out"
shard TK-774
case "$(logline TK-774)" in *":: DECISION: TK-7740 :: skip :: other ticket ["*) ok ;;
  *) bad "S4: with none for this key, the last DECISION line: [$(logline TK-774)]" ;; esac

[ ! -s "$T/calls/vendor" ] && ok || bad "V1: 0 vendor calls: [$(cat "$T/calls/vendor")]"
echo "shard-run-summary.bh-9863: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
