#!/bin/bash
# tests/agent-cmd-limit.bh-9779-test.sh — BH-9779: every shell command of a
# build-stage agent call runs under a time limit from a config row
# (bin/agent-cmd-limit.sh, armed as CLAUDE_CODE_SHELL_PREFIX by
# bin/lib/agent-cmd-limit.sh from bin/agent-call.sh).
#
#   L1  a command past the limit ends at the limit: rc 124, the tail of its
#       output after the header, the limit line
#   L2  the next command runs (the session goes on); no child of L1 is alive
#   L3  rc, stdin and stderr pass through
#   L4  the normal path is byte-exact (no added newline)
#   L5  the multi-argument form
#   L6  the tail size knob
#   L7  limit 0 or unset: unwrapped; no args: rc 0, no output; no temp file left
#   L7b a background child that holds stdout is ended at the limit too
#   L8  bin/agent-call.sh (the production entry point) with a stub claude:
#       execute is armed; mutation: without the agent-call line, it is not
#   L9  plan, review and fix are armed; qa and triage are not
#   L10 a settings row changes the limit; a row at 0 does not arm, one log line
#   L11 a caller's own CLAUDE_CODE_SHELL_PREFIX is kept
#   K1  the registry defaults equal the lib fallbacks
# No network, no model call: claude is a stub on PATH. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/agent-cmd-limit.bh-9779-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
unset AGENT_CMD_LIMIT_S AGENT_CMD_TAIL_LINES AGENT_CMD_KILL_GRACE_S CLAUDE_CODE_SHELL_PREFIX
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
NOW=1794900000
W="$DIR/bin/agent-cmd-limit.sh"
[ -x "$W" ] && ok || { echo "FAIL: $W is not executable"; exit 1; }
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"
# alive <marker> — 0 when a sleep process whose argument is <marker> runs. The
# marker is built from two halves, so this shell's own command line never holds it.
alive() { ps -eo comm=,args= 2>/dev/null | awk -v m="$1" '$1 == "sleep" && $3 == m { f = 1 } END { exit !f }'; }

# ── L1 / L2 ──────────────────────────────────────────────────────────────────
M1="29.$((9000 + 71))"
t0=$SECONDS
O1=$(AGENT_CMD_LIMIT_S=2 AGENT_CMD_KILL_GRACE_S=2 "$W" "echo start-fixture; sleep $M1" 2>&1); R1=$?
E1=$((SECONDS - t0))   # determinism: ok — an upper bound (15 s) far over the 2 s limit, not a race
[ "$R1" = 124 ] && [ "$E1" -lt 15 ] && ok || bad "L1 rc 124 in under 15 s (rc $R1, ${E1}s): $O1"
grep -qx -- '--- agent-cmd-limit: last 40 lines of output ---' <<<"$O1" && ok || bad "L1 the tail header: $O1"
[ "$(sed -n '/^--- agent-cmd-limit: last/,$p' <<<"$O1" | sed -n 2p)" = start-fixture ] && ok || bad "L1 start-fixture comes after the header: $O1"
grep -q 'agent-cmd-limit: this command was stopped at the 2 s limit (row lib.agent-cmd-limit.agent_cmd_limit_s)' <<<"$O1" && ok || bad "L1 the limit line: $O1"
O2=$(AGENT_CMD_LIMIT_S=2 "$W" 'echo next-fixture'); R2=$?
[ "$R2" = 0 ] && [ "$O2" = next-fixture ] && ok || bad "L2 the next command runs (rc $R2): $O2"
alive "$M1" && bad "L2 the sleep of L1 is still alive" || ok

# ── L3 ───────────────────────────────────────────────────────────────────────
AGENT_CMD_LIMIT_S=5 "$W" 'exit 3' >/dev/null 2>&1; [ "$?" = 3 ] && ok || bad "L3 rc 3 passes through"
[ "$(printf x | AGENT_CMD_LIMIT_S=5 "$W" cat)" = x ] && ok || bad "L3 stdin passes through"
SO=$(AGENT_CMD_LIMIT_S=5 "$W" 'echo out-fixture; echo err-fixture >&2' 2>"$T/l3.err")
[ "$SO" = out-fixture ] && [ "$(cat "$T/l3.err")" = err-fixture ] && ok || bad "L3 stdout and stderr stay apart: '$SO' / '$(cat "$T/l3.err")'"

# ── L4 ───────────────────────────────────────────────────────────────────────
AGENT_CMD_LIMIT_S=5 "$W" "printf '{\"a\":1}'" > "$T/l4.out"
[ "$(wc -c < "$T/l4.out")" = 7 ] && [ "$(cat "$T/l4.out")" = '{"a":1}' ] && ok || bad "L4 exactly 7 bytes: $(od -c "$T/l4.out" | head -2)"

# ── L5 ───────────────────────────────────────────────────────────────────────
[ "$(AGENT_CMD_LIMIT_S=5 "$W" bash -c 'echo multi')" = multi ] && ok || bad "L5 the multi-argument form"

# ── L6 ───────────────────────────────────────────────────────────────────────
O6=$(AGENT_CMD_LIMIT_S=2 AGENT_CMD_TAIL_LINES=5 AGENT_CMD_KILL_GRACE_S=2 "$W" 'seq 1 100; sleep 30' 2>&1)
[ "$(sed -n '/^--- agent-cmd-limit: last 5 lines/,/^agent-cmd-limit: this command/p' <<<"$O6" | sed '1d;$d' | tr '\n' ' ')" = '96 97 98 99 100 ' ] && ok \
  || bad "L6 the last 5 lines after the header: $(tail -8 <<<"$O6")"

# ── L7 ───────────────────────────────────────────────────────────────────────
# Wrapped, the command's parent is `timeout`; unwrapped (exec), it is not.
[ "$(AGENT_CMD_LIMIT_S=5 "$W" 'ps -o comm= -p $PPID')" = timeout ] && ok || bad "L7 setup: a wrapped command runs under timeout"
for v in 0 '' x; do
  O7=$(AGENT_CMD_LIMIT_S="$v" "$W" 'ps -o comm= -p $PPID'); R7=$?
  [ "$R7" = 0 ] && [ -n "$O7" ] && [ "$O7" != timeout ] && ok || bad "L7 limit '$v': runs unwrapped (rc $R7): $O7"
done
O7=$(env -u AGENT_CMD_LIMIT_S "$W" 'ps -o comm= -p $PPID'); [ -n "$O7" ] && [ "$O7" != timeout ] && ok || bad "L7 unset: runs unwrapped: $O7"
O7=$(AGENT_CMD_LIMIT_S=5 "$W"); R7=$?
[ "$R7" = 0 ] && [ -z "$O7" ] && ok || bad "L7 no args: rc 0 and no output (rc $R7): $O7"
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "L7 no temp file is left: $(ls -A "$T/tmp")"

# ── L7b a background child holding stdout ───────────────────────────────────
M7="39.$((9000 + 72))"
t0=$SECONDS
O7b=$(AGENT_CMD_LIMIT_S=2 AGENT_CMD_KILL_GRACE_S=2 "$W" "sleep $M7 & echo bg-fixture" 2>&1); R7b=$?
[ "$R7b" = 124 ] && [ $((SECONDS - t0)) -lt 15 ] && grep -q 'stopped at the 2 s limit' <<<"$O7b" && ok \
  || bad "L7b a child holding stdout ends at the limit (rc $R7b): $O7b"
# The group kill is asynchronous: wait for it in a bounded loop.
for _i in $(seq 1 50); do alive "$M7" || break; sleep 0.1; done
alive "$M7" && bad "L7b the background child is still alive" || ok

# ── L8-L11: bin/agent-call.sh with a stub claude ────────────────────────────
H="$T/h"; mkdir -p "$H/logs" "$H/locks" "$H/flags" "$H/state" "$H/.claude" "$T/fakebin" "$T/wt"
for f in bin/lib/agent-cmd-limit.sh bin/agent-cmd-limit.sh; do
  scratch_install_closure "$f" "$H" >/dev/null || { echo "FAIL: setup: closure install of $f"; exit 1; }
done
[ -x "$H/bin/agent-cmd-limit.sh" ] && ok || bad "setup: the wrapper is installed and executable"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
env | grep -E '^(CLAUDE_CODE_SHELL_PREFIX|AGENT_CMD_LIMIT_S|AGENT_CMD_TAIL_LINES|AGENT_CMD_KILL_GRACE_S)=' | sort > "$ENV_SINK"
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"total_cost_usd":0.01}\n'
EOF
chmod +x "$T/fakebin/claude"
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"; chmod +x "$T/fakebin/billing-mode.sh"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2> "$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "setup: could not compose the lanes registry: $(head -3 "$T/lanes.err")"
settings() { printf '{"fetched_at":%s,"values":%s,"seeded":{}}\n' "$NOW" "$1" > "$H/state/settings-cache.json"; }
settings '{}'
sed '/PER-COMMAND TIME LIMIT (BH-9779)/,+1d' "$DIR/bin/agent-call.sh" > "$T/agent-call-mut.sh"
cmp -s "$DIR/bin/agent-call.sh" "$T/agent-call-mut.sh" && bad "setup: the mutation removed nothing" || ok
# call <stage> [script] [env...] — one agent call; the stub's env lands in $T/env.txt.
call() {
  local st="$1" sc="$2"; shift 2
  rm -f "$T/env.txt" "$T/call.err"
  ( cd "$T/wt" || exit 1
    export ENV_SINK="$T/env.txt" PATH="$T/fakebin:$PATH" HARNESS="$H" HOME="$H" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW="$NOW"
    unset CLAUDE_CONFIG_DIR SESSION_PROFILE_STAGES AGENT_CMD_LIMIT_S AGENT_CMD_TAIL_LINES AGENT_CMD_KILL_GRACE_S CLAUDE_CODE_SHELL_PREFIX
    env "$@" bash "$sc" "$st" testproj claude-opus-5-5 60 "$T/out.txt" "hello" >/dev/null 2>"$T/call.err" )
}
ev() { sed -n "s/^$1=//p" "$T/env.txt" 2>/dev/null; }
call execute "$DIR/bin/agent-call.sh"
[ -s "$T/env.txt" ] && ok || bad "L8 setup: the stub claude ran ($(head -5 "$T/call.err"))"
[ "$(ev CLAUDE_CODE_SHELL_PREFIX)" = "$H/bin/agent-cmd-limit.sh" ] && [ "$(ev AGENT_CMD_LIMIT_S)" = 1800 ] && [ "$(ev AGENT_CMD_TAIL_LINES)" = 40 ] && ok \
  || bad "L8 execute is armed with the defaults: $(cat "$T/env.txt" 2>/dev/null)"
call execute "$T/agent-call-mut.sh"
[ -s "$T/env.txt" ] || [ -e "$T/env.txt" ] && [ -z "$(ev CLAUDE_CODE_SHELL_PREFIX)" ] && ok || bad "L8 mutation: without the agent-call line nothing is armed: $(cat "$T/env.txt" 2>/dev/null)"
for st in plan review fix; do
  call "$st" "$DIR/bin/agent-call.sh"
  [ "$(ev CLAUDE_CODE_SHELL_PREFIX)" = "$H/bin/agent-cmd-limit.sh" ] && ok || bad "L9 $st is armed: $(cat "$T/env.txt" 2>/dev/null)"
done
for st in qa triage; do
  call "$st" "$DIR/bin/agent-call.sh"
  [ -e "$T/env.txt" ] && [ -z "$(ev CLAUDE_CODE_SHELL_PREFIX)" ] && ok || bad "L9 $st is not armed: $(cat "$T/env.txt" 2>/dev/null)"
done
settings '{"lib.agent-cmd-limit.agent_cmd_limit_s":"120","lib.agent-cmd-limit.agent_cmd_tail_lines":"7"}'
call execute "$DIR/bin/agent-call.sh"
[ "$(ev AGENT_CMD_LIMIT_S)" = 120 ] && [ "$(ev AGENT_CMD_TAIL_LINES)" = 7 ] && ok || bad "L10 the rows set 120 and 7: $(cat "$T/env.txt" 2>/dev/null)"
settings '{"lib.agent-cmd-limit.agent_cmd_limit_s":"0"}'
call execute "$DIR/bin/agent-call.sh"
[ -e "$T/env.txt" ] && [ -z "$(ev CLAUDE_CODE_SHELL_PREFIX)" ] && [ "$(grep -c 'agent-cmd-limit: not armed for execute: AGENT_CMD_LIMIT_S is 0' "$T/call.err")" = 1 ] && ok \
  || bad "L10 a row at 0: not armed, one log line: $(cat "$T/env.txt" 2>/dev/null) / $(grep agent-cmd-limit "$T/call.err")"
settings '{}'
call execute "$DIR/bin/agent-call.sh" CLAUDE_CODE_SHELL_PREFIX=/opt/fixture/own-prefix
[ "$(ev CLAUDE_CODE_SHELL_PREFIX)" = /opt/fixture/own-prefix ] && [ -z "$(ev AGENT_CMD_LIMIT_S)" ] && grep -q 'the caller set CLAUDE_CODE_SHELL_PREFIX, which is kept' "$T/call.err" && ok \
  || bad "L11 the caller's prefix is kept: $(cat "$T/env.txt" 2>/dev/null)"

# ── K1 ───────────────────────────────────────────────────────────────────────
REG="$DIR/catalog/lanes.d/_lib.agent-cmd-limit.json"
for kv in AGENT_CMD_LIMIT_S=1800 AGENT_CMD_TAIL_LINES=40 AGENT_CMD_KILL_GRACE_S=10; do
  k=${kv%%=*}; d=${kv#*=}
  [ "$(jq -r --arg e "$k" '.libs[0].knobs[] | select(.env == $e) | .default' "$REG")" = "$d" ] \
    && grep -q "_acl_knob $k $d " "$DIR/bin/lib/agent-cmd-limit.sh" && ok || bad "K1 $k: registry default and lib fallback are $d"
done

echo "agent-cmd-limit.bh-9779: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
