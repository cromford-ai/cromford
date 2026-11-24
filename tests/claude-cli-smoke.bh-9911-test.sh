#!/bin/bash
# tests/claude-cli-smoke.bh-9911-test.sh — BH-9911: the canary smoke,
# bin/claude-cli-smoke.sh, run as shipped against a fake CLI and a fake worker.
#
# The fake `claude` on PATH is the 2.1.317 replay: it waits FAKE_STDIN_WAIT
# seconds for the first byte of stdin and exits 1 when none came. A stand-in
# agent-call (seam CCP_AGENT_CALL, read only under HARNESS_TEST_SANDBOX=1) pipes
# the prompt into the PATH `claude` the way bin/agent-call.sh does, so the late
# stdin wrapper the smoke puts on PATH is the real one.
#
#   S1  2.1.317 replay (3 s stdin wait): stdin ok=1, late_stdin ok=0, rows carry
#       the version, ONE ALERTS line naming the version and late_stdin; then
#       bin/claude-cli-pin.sh promote on those rows leaves the pin unchanged
#   S2  a CLI that waits: six rows, all ok, the version on each, 0 alerts;
#       the tool step really ran the command (the digest is in the answer)
#   S3  not the canary -> 0 rows, 0 calls        S4  C not installed -> 0 calls
#   S5  a red row for C -> 0 calls, no 2nd alert  S6  a recent run -> 0 calls
#   S7  the row read fails -> 0 calls             S8  POST fails -> pending file
#       kept; the next run resends it first and spends nothing
#   S9  a new RUNNER_* class after the install -> fail_classes ok=0, no alert
#   S10 pin off -> 0 calls                        S11 no model route -> 0 calls
#   S12 the outer step timeout reads claude_cli.smoke_step_grace_s and
#       claude_cli.smoke_step_kill_after_s (fallbacks 30 and 10)
#   S13 the canary version is not newer than the pin -> 0 calls
#   S14 a row's detail is cut to the row claude_cli.smoke_detail_max (the
#       worker refuses a longer one), and the step excerpt to the row
#       claude_cli.smoke_excerpt_max
#   S15 a pending file the worker answers 4xx goes to dead-<run_id>.json with
#       ONE ALERTS line, so it no longer stops every later run; a 4xx on a
#       fresh run's POST does the same
#   S16 a dead-letter file of C younger than claude_cli.smoke_interval_h counts
#       as "C already ran" (0 calls, one log line); an older one, or one of
#       another version, does not
# Zero real vendor calls: the stand-ins count every call (budget: S3-S7, S10,
# S11 assert 0).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/claude-cli-smoke.bh-9911-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/claude-cli-pin-fakes.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
NOWE=1795000000
isoh() { date -u -d "@$((NOWE - $1 * 3600))" '+%Y-%m-%dT%H:%M:%SZ'; }
stamph() { date -u -d "@$((NOWE - $1 * 3600))" '+%Y-%m-%d %H:%M:%SZ'; }

new_case() { # new_case <id> [box-id]
  H="$T/$1"; mkdir -p "$H/logs" "$H/state" "$H/env" "$H/sbin"
  scratch_install_closure bin/claude-cli-smoke.sh "$H" >/dev/null || bad "$1: closure install"
  ccpf_new "$H/f"
  echo "${2:-small}" > "$H/state/box-id"
  printf '#!/bin/bash\necho "$*" >> "$HARNESS/logs/ALERTS.log"\n' > "$H/bin/alert-line.sh"; chmod +x "$H/bin/alert-line.sh"
  # The fake CLI.
  cat > "$H/sbin/claude" <<'FAKE'
#!/bin/bash
[ "$1" = --version ] && { echo "$(cat "$FAKE_DIR/version") (Claude Code)"; exit 0; }
if ! IFS= read -r -t "${FAKE_STDIN_WAIT:-3}" -n 1 first; then echo "Error: Input must be provided through stdin within 3s" >&2; exit 1; fi
prompt="$first$(cat)"
cmd=$(sed -n 's/.*`\([^`]*\)`.*/\1/p' <<<"$prompt")
if [ -n "$cmd" ]; then bash -c "$cmd"; else echo OK; fi
FAKE
  echo 2.1.331 > "$H/sbin/version"
  # The agent-call stand-in: the same argv, the prompt piped into PATH's claude.
  cat > "$H/sbin/agent-call" <<'AC'
#!/bin/bash
echo "$1 $2 $3 $4 tools=${AGENT_CALL_TOOLS:-} notools=${AGENT_CALL_NO_TOOLS:-0} runners=${AGENT_CALL_RUNNERS:-} lane=${AGENT_CALL_LANE:-}" >> "$FAKE_DIR/ac.calls"
printf '%s' "$6" | timeout "$4" claude -p > "$5"
AC
  printf '#!/bin/bash\necho "lane-probe $*" >> "$FAKE_DIR/lp.calls"\necho ok\n' > "$H/sbin/lane-probe"
  chmod +x "$H/sbin/claude" "$H/sbin/agent-call" "$H/sbin/lane-probe"
  ccpf_set "$H/f" claude_cli.pin.enabled 1
  ccpf_set "$H/f" claude_cli.pinned_version 2.1.330
  ccpf_set "$H/f" claude_cli.canary_version 2.1.331
  ccpf_set "$H/f" claude_cli.smoke_late_stdin_s 4
  ccpf_set "$H/f" claude_cli.smoke_step_timeout_s 20
  echo fake-model-fixture > "$H/f/w/routes/claude-cli.smoke"
}
run_smoke() { # run_smoke [VAR=value...] -> OUT, RC
  OUT=$(env -i PATH="$H/sbin:$H/f/fakebin:/usr/bin:/bin" HOME="$H" HARNESS="$H" JOBS_URL=https://jobs.test \
        HARNESS_SECRET=tok-fixture-bh9911 HARNESS_TEST_SANDBOX=1 CCPF_W="$H/f/w" JOBS_RETRY_SLEEP=0 \
        JOBS_SETTINGS_CACHE_S=0 JOBS_OVERLOAD_RETRIES=0 CCP_NOW="$NOWE" FAKE_DIR="$H/sbin" \
        CCP_AGENT_CALL="$H/sbin/agent-call" CCP_LANE_PROBE="$H/sbin/lane-probe" "$@" \
        bash "$DIR/bin/claude-cli-smoke.sh" 2>&1); RC=$?
}
calls() { cat "$H/sbin/ac.calls" "$H/sbin/lp.calls" 2>/dev/null | grep -c . ; true; }
rowv() { # rowv <step> <field>
  jq -r --arg s "$1" --arg f "$2" 'select(.step == $s) | .[$f] | tostring' "$H/f/w/smoke.jsonl" | head -1
}
alerts() { cat "$H/logs/ALERTS.log" 2>/dev/null | grep -c 'CLAUDE CLI CANARY RED'; true; }

# ---- S1: the 2.1.317 replay -------------------------------------------------
new_case s1
run_smoke FAKE_STDIN_WAIT=3
[ "$RC" = 0 ] && ok || bad "S1 rc $RC: $OUT"
[ "$(rowv stdin ok)" = 1 ] && ok || bad "S1 stdin ok=$(rowv stdin ok)"
[ "$(rowv late_stdin ok)" = 0 ] && ok || bad "S1 late_stdin ok=$(rowv late_stdin ok) (the replay must fail it)"
[ "$(jq -r '.version' "$H/f/w/smoke.jsonl" | sort -u)" = 2.1.331 ] && ok || bad "S1 rows do not carry 2.1.331"
[ "$(jq -s 'length' "$H/f/w/smoke.jsonl")" = 6 ] && ok || bad "S1 want 6 rows, got $(jq -s 'length' "$H/f/w/smoke.jsonl")"
[ "$(alerts)" = 1 ] && ok || bad "S1 want one RED line, got $(alerts): $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep 'CLAUDE CLI CANARY RED' "$H/logs/ALERTS.log" 2>/dev/null | grep -q '2.1.331 on small failed late_stdin' && ok || bad "S1 RED line fields: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'runners=claude lane=claude-cli-smoke' "$H/sbin/ac.calls" && grep -q '^claude-cli-smoke fleet fake-model-fixture 20 ' "$H/sbin/ac.calls" \
  && ok || bad "S1 agent-call argv/env: $(cat "$H/sbin/ac.calls")"
[ -z "$(ls "$H/state/claude-cli-smoke/" 2>/dev/null)" ] && ok || bad "S1 a pending file was left after a good POST"
# ...and promote on those rows (one red run, any age) leaves the pin alone.
run_promote() {
  scratch_install_closure bin/claude-cli-pin.sh "$H" >/dev/null
  # shellcheck disable=SC2034
  POUT=$(env -i PATH="$H/f/fakebin:/usr/bin:/bin" HOME="$H" HARNESS="$H" JOBS_URL=https://jobs.test HARNESS_SECRET=tok-fixture-bh9911 \
         HARNESS_TEST_SANDBOX=1 CCPF_W="$H/f/w" JOBS_RETRY_SLEEP=0 JOBS_SETTINGS_CACHE_S=0 CCP_NOW="$1" \
         bash "$DIR/bin/claude-cli-pin.sh" promote 2>&1)
}
run_promote $((NOWE + 48 * 3600))
[ "$(ccpf_get "$H/f" claude_cli.pinned_version)" = 2.1.330 ] && grep -q 'red smoke step (late_stdin' <<<"$POUT" && ok \
  || bad "S1 promote on the red rows: pin $(ccpf_get "$H/f" claude_cli.pinned_version): $POUT"
echo "S1 done"

# ---- S2: all green ------------------------------------------------------------
new_case s2
run_smoke FAKE_STDIN_WAIT=15
for s in stdin late_stdin tool_call haiku lane_tick fail_classes; do
  [ "$(rowv "$s" ok)" = 1 ] && [ "$(rowv "$s" version)" = 2.1.331 ] && [ "$(rowv "$s" box)" = small ] && ok \
    || bad "S2 step $s: ok=$(rowv "$s" ok) version=$(rowv "$s" version)"
done
[ "$(alerts)" = 0 ] && ok || bad "S2 a green run alerted"
grep -q 'tools=Bash' "$H/sbin/ac.calls" && grep -q 'notools=1' "$H/sbin/ac.calls" && ok || bad "S2 step shapes: $(cat "$H/sbin/ac.calls")"
[ "$(grep -c . "$H/sbin/ac.calls")" = 4 ] && [ "$(grep -c . "$H/sbin/lp.calls")" = 1 ] && ok || bad "S2 want 4 agent-calls and 1 lane tick: $(calls)"
# S2 + promote: one green run 25h old and the soak passes.
run_promote $((NOWE + 25 * 3600))
[ "$(ccpf_get "$H/f" claude_cli.pinned_version)" = 2.1.331 ] && ok || bad "S2 promote after the soak: $POUT"
echo "S2 done"

# ---- S3..S7, S10, S11: no spend ---------------------------------------------------
new_case s3 project-4; run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 0 ] && [ ! -s "$H/f/w/smoke.jsonl" ] && ok || bad "S3 a non-canary box spent: $(calls)"
new_case s3b hub; ccpf_set "$H/f" claude_cli.canary_box hub; run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 0 ] && ok || bad "S3b the hub ran the smoke"
new_case s4; echo 2.1.330 > "$H/sbin/version"; run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 0 ] && grep -q 'no smoke until cli-update installs it' "$H/logs/claude-cli-smoke.log" && ok || bad "S4 C not installed spent: $(calls)"
new_case s5
ccpf_row "$H/f" small 2.1.331 old late_stdin 0 "$(isoh 30)"
run_smoke FAKE_STDIN_WAIT=3
[ "$(calls)" = 0 ] && [ "$(alerts)" = 0 ] && ok || bad "S5 a red version ran again: $(calls) calls, $(alerts) alerts"
OUT_FORCE=$(env -i PATH="$H/sbin:$H/f/fakebin:/usr/bin:/bin" HOME="$H" HARNESS="$H" JOBS_URL=https://jobs.test \
        HARNESS_SECRET=tok-fixture-bh9911 HARNESS_TEST_SANDBOX=1 CCPF_W="$H/f/w" JOBS_RETRY_SLEEP=0 JOBS_SETTINGS_CACHE_S=0 \
        CCP_NOW="$NOWE" FAKE_DIR="$H/sbin" FAKE_STDIN_WAIT=15 CCP_AGENT_CALL="$H/sbin/agent-call" CCP_LANE_PROBE="$H/sbin/lane-probe" \
        bash "$DIR/bin/claude-cli-smoke.sh" --force 2>&1)
[ "$(calls)" = 5 ] && ok || bad "S5 --force did not run the smoke on a red version: $(calls) $OUT_FORCE"
new_case s6
ccpf_row "$H/f" small 2.1.331 recent stdin 1 "$(isoh 1)"
run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 0 ] && ok || bad "S6 a run younger than the interval spent: $(calls)"
new_case s7; : > "$H/f/w/fail-smoke-get"; run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 0 ] && ok || bad "S7 a failed read spent: $(calls)"
new_case s10; ccpf_set "$H/f" claude_cli.pin.enabled 0; run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 0 ] && ok || bad "S10 pin off spent: $(calls)"
new_case s11; rm -f "$H/f/w/routes/claude-cli.smoke"; run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 0 ] && ok || bad "S11 no model route spent: $(calls)"
echo "S3-S11 done"

# ---- S8: POST fails -> pending kept, resent first next run, no spend ---------------
new_case s8; : > "$H/f/w/fail-smoke-post"
run_smoke FAKE_STDIN_WAIT=15
P8=$(ls "$H/state/claude-cli-smoke/" 2>/dev/null)
grep -q '^pending-.*\.json$' <<<"$P8" && ok || bad "S8 no pending file after a failed POST: '$P8'"
[ "$(jq '.rows | length' "$H/state/claude-cli-smoke/"pending-*.json 2>/dev/null)" = 6 ] && ok || bad "S8 pending file does not hold 6 rows"
: > "$H/sbin/ac.calls"; : > "$H/sbin/lp.calls"
run_smoke FAKE_STDIN_WAIT=15   # still failing: kept, nothing spent
[ "$(calls)" = 0 ] && [ -n "$(ls "$H/state/claude-cli-smoke/" 2>/dev/null)" ] && ok || bad "S8 a second run with unsent rows spent: $(calls)"
rm -f "$H/f/w/fail-smoke-post"
run_smoke FAKE_STDIN_WAIT=15
[ "$(jq -s 'length' "$H/f/w/smoke.jsonl")" = 6 ] && [ -z "$(ls "$H/state/claude-cli-smoke/" 2>/dev/null)" ] && ok \
  || bad "S8 the resend did not land the 6 rows / remove the file"
[ "$(calls)" = 0 ] && ok || bad "S8 the resend run spent again inside the interval: $(calls)"
echo "S8 done"

# ---- S9: a new failure class -> fail_classes ok=0, no alert -----------------------
new_case s9
printf '%s,small,claude,2.1.330,2.1.331,npm,1,/usr/bin/claude,\n' "$(isoh 10 )" > "$H/logs/cli-versions.csv"
{ echo "$(stamph 15) [p] review claude: RUNNER_RATE_LIMITED retry"
  echo "$(stamph 5) [p] review claude: RUNNER_RATE_LIMITED retry"
  echo "$(stamph 4) [p] review claude: RUNNER_EXHAUSTED cool down"
  echo "$(stamph 3) [p] plan ok RUNNER_OK LLM_RUNNER_ALLOWED" ; } > "$H/logs/failovers.log"
run_smoke FAKE_STDIN_WAIT=15
[ "$(rowv fail_classes ok)" = 0 ] && grep -q 'RUNNER_EXHAUSTED' <<<"$(rowv fail_classes detail)" && ok \
  || bad "S9 fail_classes: ok=$(rowv fail_classes ok) detail=$(rowv fail_classes detail)"
grep -q 'RUNNER_RATE_LIMITED\|RUNNER_OK\|RUNNER_ALLOWED' <<<"$(rowv fail_classes detail)" && bad "S9 an old or non-failure token counted as new" || ok
[ "$(alerts)" = 0 ] && ok || bad "S9 a new failure class sent a RED alert"
new_case s9b
printf '%s,small,claude,2.1.330,2.1.331,npm,1,/usr/bin/claude,\n' "$(isoh 10)" > "$H/logs/cli-versions.csv"
{ echo "$(stamph 15) [p] RUNNER_EXHAUSTED"; echo "$(stamph 2) [p] RUNNER_EXHAUSTED"; } > "$H/logs/failovers.log"
run_smoke FAKE_STDIN_WAIT=15
[ "$(rowv fail_classes ok)" = 1 ] && ok || bad "S9b a class seen before the install counted as new: $(rowv fail_classes detail)"
echo "S9 done"

# ---- S12: the outer step timeout is knob-driven (lead review of a14a874bd8c2) ----
# A `timeout` first on PATH records its argv and runs the real one.
to_stub() { printf '#!/bin/bash\necho "$*" >> "$FAKE_DIR/to.calls"\nexec /usr/bin/timeout "$@"\n' > "$H/sbin/timeout"; chmod +x "$H/sbin/timeout"; }
new_case s12; to_stub
run_smoke FAKE_STDIN_WAIT=15
[ "$(grep -c -- '^--kill-after=10 50 ' "$H/sbin/to.calls")" = 5 ] && ok \
  || bad "S12 no rows: want 5 outer timeouts '--kill-after=10 50' (step 20 + grace 30): $(cat "$H/sbin/to.calls" 2>/dev/null)"
new_case s12b; to_stub
ccpf_set "$H/f" claude_cli.smoke_step_grace_s 7
ccpf_set "$H/f" claude_cli.smoke_step_kill_after_s 3
run_smoke FAKE_STDIN_WAIT=15
[ "$(grep -c -- '^--kill-after=3 27 ' "$H/sbin/to.calls")" = 5 ] && ok \
  || bad "S12b rows 7/3: want 5 outer timeouts '--kill-after=3 27': $(cat "$H/sbin/to.calls" 2>/dev/null)"
[ "$(rowv stdin ok)" = 1 ] && ok || bad "S12b the knob run did not complete the stdin step"
echo "S12 done"

# ---- S13: the canary is not newer than the pin -> no spend (lead review) ----------
new_case s13; ccpf_set "$H/f" claude_cli.pinned_version 2.1.331
run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 0 ] && [ ! -s "$H/f/w/smoke.jsonl" ] && grep -q 'is not newer than the pin' "$H/logs/claude-cli-smoke.log" && ok \
  || bad "S13 C = pin spent: $(calls) calls: $(cat "$H/logs/claude-cli-smoke.log" 2>/dev/null)"
new_case s13b; ccpf_set "$H/f" claude_cli.pinned_version 2.1.340
run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 0 ] && ok || bad "S13b C older than the pin spent: $(calls)"
echo "S13 done"

# ---- S14: the detail and excerpt cuts are rows (lead review of cc25d98bdfc2) -----
maxdetail() { jq -r '.detail | length' "$H/f/w/smoke.jsonl" | sort -n | tail -1; }
new_case s14; ccpf_set "$H/f" claude_cli.smoke_detail_max 30
run_smoke FAKE_STDIN_WAIT=15
[ "$(jq -s 'length' "$H/f/w/smoke.jsonl")" = 6 ] && [ "$(maxdetail)" -le 30 ] && ok \
  || bad "S14 row 30: longest detail $(maxdetail) chars: $(jq -c '.detail' "$H/f/w/smoke.jsonl" 2>/dev/null | head -3)"
new_case s14b; ccpf_set "$H/f" claude_cli.smoke_excerpt_max 9
run_smoke FAKE_STDIN_WAIT=15
[ "$(rowv tool_call detail | wc -c)" -le 10 ] && [ -n "$(rowv tool_call detail)" ] && ok \
  || bad "S14b excerpt row 9: tool_call detail '$(rowv tool_call detail)'"
echo "S14 done"

# ---- S15: a refused (4xx) pending file is dead-lettered, not retried forever ----
new_case s15; ccpf_set "$H/f" claude_cli.pin.enabled 0
mkdir -p "$H/state/claude-cli-smoke"
echo '{"rows":[{"box":"small","version":"2.1.331","run_id":"r15","step":"stdin","ok":1,"rc":0,"ms":1,"detail":"x","at":"2026-11-18T00:00:00Z"}]}' \
  > "$H/state/claude-cli-smoke/pending-r15.json"
: > "$H/f/w/refuse-smoke-post"
run_smoke FAKE_STDIN_WAIT=15
[ ! -e "$H/state/claude-cli-smoke/pending-r15.json" ] && [ -s "$H/state/claude-cli-smoke/dead-r15.json" ] && ok \
  || bad "S15 the refused pending file was not dead-lettered: $(ls "$H/state/claude-cli-smoke/" 2>/dev/null)"
[ "$(grep -c 'CLAUDE CLI SMOKE ROWS REFUSED' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && grep -q 'pending-r15.json' "$H/logs/ALERTS.log" && ok \
  || bad "S15 want ONE refused ALERTS line naming the file: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
run_smoke FAKE_STDIN_WAIT=15
[ "$(grep -c 'CLAUDE CLI SMOKE ROWS REFUSED' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "S15 a second run alerted again"
# A pending file the canary can no longer block on: the pin on, the next run smokes.
new_case s15b; mkdir -p "$H/state/claude-cli-smoke"
echo '{"rows":[]}' > "$H/state/claude-cli-smoke/pending-r15b.json"
: > "$H/f/w/refuse-smoke-post"
run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 5 ] && ok || bad "S15b a refused pending file still blocked the smoke: $(calls) calls"
[ -z "$(ls "$H/state/claude-cli-smoke/" | grep '^pending-')" ] && [ "$(ls "$H/state/claude-cli-smoke/" | grep -c '^dead-')" = 2 ] && ok \
  || bad "S15b want both refused files (the old one and this run's) dead-lettered: $(ls "$H/state/claude-cli-smoke/")"
[ "$(grep -c 'CLAUDE CLI SMOKE ROWS REFUSED' "$H/logs/ALERTS.log" 2>/dev/null)" = 2 ] && ok || bad "S15b want one refused line per file: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
echo "S15 done"

# ---- S16: a dead-lettered run is a run for the dedup (lead review of f0615e9ae0fa) ----
dead16() { # dead16 <name> <version> <hours ago>
  mkdir -p "$H/state/claude-cli-smoke"
  jq -nc --arg v "$2" --arg at "$(isoh "$3")" '{rows:[{box:"small",version:$v,run_id:"r16",step:"stdin",ok:1,rc:0,ms:1,detail:"x",at:$at}]}' \
    > "$H/state/claude-cli-smoke/dead-$1.json"
}
new_case s16; dead16 r16 2.1.331 1
run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 0 ] && [ ! -s "$H/f/w/smoke.jsonl" ] && ok || bad "S16 a 1h-old dead-letter run of C spent: $(calls) calls"
[ "$(grep -c 'dead-letter' "$H/logs/claude-cli-smoke.log" 2>/dev/null)" = 1 ] && grep -q 'dead-r16.json' "$H/logs/claude-cli-smoke.log" && ok \
  || bad "S16 want one log line naming the dead-letter file: $(cat "$H/logs/claude-cli-smoke.log" 2>/dev/null)"
new_case s16b; dead16 r16 2.1.331 7
run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 5 ] && ok || bad "S16b a dead-letter run older than 6h still blocked the smoke: $(calls) calls"
new_case s16c; dead16 r16 2.1.329 1
run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 5 ] && ok || bad "S16c a dead-letter run of another version blocked the smoke: $(calls) calls"
new_case s16d; ccpf_set "$H/f" claude_cli.smoke_interval_h 1; dead16 r16 2.1.331 2
run_smoke FAKE_STDIN_WAIT=15
[ "$(calls)" = 5 ] && ok || bad "S16d row smoke_interval_h=1: a 2h-old dead-letter run blocked the smoke: $(calls) calls"
echo "S16 done"

echo "claude-cli-smoke.bh-9911-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
