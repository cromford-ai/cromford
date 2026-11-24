#!/bin/bash
# tests/hook-exit-audit.bh-9912-test.sh — the hook exit-code audit, pinned (BH-9912).
#
# Claude Code reads exit 2 from a PreToolUse hook as BLOCK. Any other nonzero
# is a non-blocking hook error, and the tool call RUNS. So a guard whose deny
# path ends on exit 1 guards nothing. The audit (docs/notes/2026-11-23-BH-9912-
# deny-guardrails.md) found every block path at exit 2. This suite pins that:
#   (1) the hook set in rules/settings.json is exactly the audited set, so a new
#       hook fails here until it gets an audit row;
#   (2) bin/secret-read-guard.py denies with rc 2;
#   (3) bin/iron-law-guard.sh denies with rc 2, and a guard killed mid-run
#       (SIGTERM before a verdict) also ends rc 2;
#   (4) bin/lane-shims/_fence.sh --classify denies with rc 2;
#   (5) an allowed call is rc 0 on each, so no deny path hides behind rc 1.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- (1) the rendered hook set is the audited set ---------------------------
GOT=$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$DIR/rules/settings.json" 2>/dev/null | sort)
WANT=$(printf '%s\n' "/root/harness/bin/secret-read-guard.py" "/usr/local/bin/rtk hook claude" "codegraph prompt-hook" | sort)
[ "$GOT" = "$WANT" ] && ok || bad "(1) rules/settings.json hooks changed — add an audit row (docs/notes/2026-11-23-BH-9912-deny-guardrails.md) and update this pin. Got: $(tr '\n' '|' <<<"$GOT")"
# The one blocking hook there is wired on PreToolUse (where exit 2 blocks).
jq -e '.hooks.PreToolUse[] | select(.hooks[].command == "/root/harness/bin/secret-read-guard.py")' "$DIR/rules/settings.json" >/dev/null 2>&1 \
  && ok || bad "(1) secret-read-guard.py is not a PreToolUse hook in rules/settings.json"

# --- (2) secret-read-guard.py ------------------------------------------------
H="$T/h"; mkdir -p "$H/bin" "$H/logs" "$H/env" "$T/home" "$T/work"
echo 'X=FIXTURE' > "$H/env/x.env"; echo 'readme' > "$T/work/readme.md"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/alert-line.sh"; chmod +x "$H/bin/alert-line.sh"
sguard() { # sguard <file_path> -> rc
  jq -nc --arg f "$1" --arg d "$T/work" '{hook_event_name:"PreToolUse",cwd:$d,tool_name:"Read",tool_input:{file_path:$f}}' \
    | timeout 15 env HARNESS="$H" HOME="$T/home" HARNESS_LANE=execute "$DIR/bin/secret-read-guard.py" >/dev/null 2>&1
  echo $?
}
[ "$(sguard "$H/env/x.env")" = 2 ] && ok || bad "(2) secret-read-guard.py did not deny a Read of env/x.env with rc 2"
[ "$(sguard "$T/work/readme.md")" = 0 ] && ok || bad "(5) secret-read-guard.py did not allow a plain Read with rc 0"

# --- (3) iron-law-guard.sh ---------------------------------------------------
mkdir -p "$T/logs" "$T/bin" "$T/stub"
ipayload() { jq -nc --arg c "$1" --arg d "$T" '{session_id:"s",hook_event_name:"PreToolUse",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}'; }
iguard() { # iguard <guard-path> <command> [PATH] -> rc
  ipayload "$2" | timeout 30 env PATH="${3:-$PATH}" HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj \
    bash "$1" >/dev/null 2>&1
  echo $?
}
[ "$(iguard "$DIR/bin/iron-law-guard.sh" 'gh pr merge 1')" = 2 ] && ok || bad "(3) iron-law-guard.sh did not deny gh pr merge with rc 2"
[ "$(iguard "$DIR/bin/iron-law-guard.sh" 'git status')" = 0 ] && ok || bad "(5) iron-law-guard.sh did not allow git status with rc 0"
# A guard killed BEFORE its verdict. Timing-free: the guard runs from a
# copy with a unique path, and a `tr` stub on PATH (the guard's first tr is in
# the normalisation, before classify) sends SIGTERM to that copy, then runs the
# real tr. The trap must turn the kill into a block.
CP="$T/bin/ilg-audit-$$-hook-exit-audit.sh"; cp "$DIR/bin/iron-law-guard.sh" "$CP"
REAL_TR=$(command -v tr)
cat > "$T/stub/tr" <<EOF
#!/bin/bash
pkill -TERM -of "bash $CP" 2>/dev/null
exec "$REAL_TR" "\$@"
EOF
chmod +x "$T/stub/tr"
: > "$T/logs/ALERTS.log"
[ "$(iguard "$CP" 'gh pr merge 1' "$T/stub:$PATH")" = 2 ] && ok || bad "(3) a SIGTERM'd iron-law-guard.sh did not end rc 2"
grep -q 'guard crashed: SIGTERM' "$T/logs/ALERTS.log" && ok || bad "(3) the SIGTERM case did not reach the crash trap (vacuous kill?): $(cat "$T/logs/ALERTS.log")"

# --- (4) the codex-lane fence -----------------------------------------------
fence() { env HARNESS="$T" IRON_LAW_GUARD="$DIR/bin/iron-law-guard.sh" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj \
          timeout 30 bash "$DIR/bin/lane-shims/_fence.sh" --classify x "$1" "$T" >/dev/null 2>&1; echo $?; }
[ "$(fence 'gh pr merge 1')" = 2 ] && ok || bad "(4) _fence.sh --classify did not deny gh pr merge with rc 2"
[ "$(fence 'git status')" = 0 ] && ok || bad "(5) _fence.sh --classify did not allow git status with rc 0"

echo "hook-exit-audit: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
