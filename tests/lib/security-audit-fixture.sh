#!/bin/bash
# tests/lib/security-audit-fixture.sh — the shared fixture of the
# tests/security-audit-*.bh-7910-test.sh suites. Sourced after tests/lib/scratch.sh
# (it needs T), never executed.
#
#   sa_fixture_setup <project>
#     $T/target       a git repo on main: app.js, .claude/settings.json, CLAUDE.md,
#                     sub/CLAUDE.md, .mcp.json (what the runner must neutralize)
#     $T/skill-up     the "upstream" skill repo: skills/security-audit/SKILL.md and
#                     the two validators; SA_PIN is its HEAD
#     $T/sa.conf      the conf, pinned to SA_PIN, caps 60/240, poll_s 1
#     $T/fakebin      stubs: claude, npx, node, gh. Each counts its calls in
#                     $T/<name>-calls. 0 network calls.
#     $T/state/model-routes/stage.audit@<project>.tsv  the cached route
#   Stub controls (files in $T): claude-mode = fixture|sleep|cost|transcript|short|fail|nodone
#   (default fixture); claude-cost-usd (the matching ledger row of mode cost);
#   claude-transcript-model (the priced model of mode transcript, which writes
#   the dir it used to claude-tdir); npx-mode =
#   tamper; node-rc (default 0).
#   SA_ACCOUNT_ROUTING=1 sa_run ...  routes the call through agent-call's
#     ACCOUNT_ROUTING path ($T/bin/account-pick.sh, when a test writes one).
#   sa_run <args...>  runs the REAL bin/security-audit.sh through the real
#     bin/agent-call.sh; stdout+stderr in $T/run.out, and prints the rc.

SA_REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SA_FIX="$SA_REPO_DIR/tests/fixtures/security-audit.bh-7910"

sa_fixture_setup() {
  local project="$1"
  SA_PROJECT="$project"
  mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state/model-routes" "$T/bin" "$T/fakebin" "$T/.claude"
  git init -q -b main "$T/target"
  ( cd "$T/target" || exit 1
    git config user.email fixture@example.com; git config user.name fixture
    mkdir -p .claude sub
    echo 'console.log("fixture app")' > app.js
    echo '{"hooks":{"PreToolUse":[{"command":"touch /tmp/fixture-hook-ran"}]}}' > .claude/settings.json
    echo 'fixture instructions' > CLAUDE.md
    echo 'fixture sub instructions' > sub/CLAUDE.md
    echo '{"mcpServers":{"fixture":{"command":"false"}}}' > .mcp.json
    git add -A && git commit -qm "fixture target" ) || return 1
  SA_TARGET_SHA=$(git -C "$T/target" rev-parse HEAD)

  git init -q -b main "$T/skill-up"
  ( cd "$T/skill-up" || exit 1
    git config user.email fixture@example.com; git config user.name fixture
    mkdir -p skills/security-audit/scripts
    printf -- '---\nname: security-audit\ndescription: fixture skill for the BH-7910 tests\n---\nfixture body\n' > skills/security-audit/SKILL.md
    echo '// fixture validator' > skills/security-audit/scripts/validate-findings.cjs
    echo '// fixture validator' > skills/security-audit/scripts/validate-coverage-ledger.cjs
    git add -A && git commit -qm "fixture skill" ) || return 1
  SA_PIN=$(git -C "$T/skill-up" rev-parse HEAD)
  cat > "$T/sa.conf" <<EOF
skill_repo=$T/skill-up
skill_sha=$SA_PIN
skill_path=skills/security-audit
skill_name=security-audit
skills_cli_version=1.7.4
cap_usd=60
cap_minutes=240
sandbox_image=fixture-image
poll_s=1
EOF
  echo 'ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account' > "$T/logs/cost.csv"
  printf '0\tclaude-fixture-model\tclaude\n' > "$T/state/model-routes/stage.audit@$project.tsv"
  printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
  chmod +x "$T/bin/billing-mode.sh" "$T/bin/beat.sh"

  # claude: reads the prompt on stdin, finds the output directory in it.
  cat > "$T/fakebin/claude" <<'SH'
#!/bin/bash
echo x >> "$SA_T/claude-calls"
prompt=$(cat)
printf '%s' "$prompt" > "$SA_T/claude-prompt"
ls -A . > "$SA_T/claude-ls"
ls -A sub > "$SA_T/claude-ls-sub" 2>/dev/null
ls -A .claude/skills > "$SA_T/claude-ls-skills" 2>/dev/null
run=$(printf '%s\n' "$prompt" | sed -n 's/^Output directory: `\([^`]*\)`.*/\1/p' | head -1)
mode=$(cat "$SA_T/claude-mode" 2>/dev/null || echo fixture)
case "$mode" in
  fixture)
    cp "$SA_FIX/findings.json" "$SA_FIX/coverage-ledger.json" "$SA_FIX/REPORT.md" "$run/" ;;
  sleep)
    echo '[{"id":"P-1","verdict":"needs_validation"}]' > "$run/findings.json"
    sleep 60 ;;
  cost)
    echo '[{"id":"P-1","verdict":"confirmed"}]' > "$run/findings.json"
    echo "$(date -u +%FT%TZ),$(hostname),$SA_PROJECT,audit,claude,claude-fixture-model,0,1,1,1,0,0,$(cat "$SA_T/claude-cost-usd")" >> "$SA_T/logs/cost.csv"
    sleep 60 ;;
  transcript)
    # What the real CLI does while it runs: a priced transcript under its OWN
    # config root, in the dir named by its own slug rule for its real cwd
    # (every non-alphanumeric character becomes "-"). No cost.csv row: real
    # agent-call writes that only when the call ends.
    echo '[{"id":"P-1","verdict":"confirmed"}]' > "$run/findings.json"
    tdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(pwd -P | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$tdir"
    printf '{"type":"assistant","timestamp":"%s","message":{"id":"msg_fixture_live","model":"%s","usage":{"input_tokens":1000000,"output_tokens":1000000}}}\n' \
      "$(date -u +%FT%TZ)" "$(cat "$SA_T/claude-transcript-model")" > "$tdir/s-fixture-live.jsonl"
    echo "$tdir" > "$SA_T/claude-tdir"
    sleep 60 ;;
  short)
    echo '[]' > "$run/findings.json"
    sleep 3 ;;
  fail)
    echo '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s-fixture"}'
    exit 1 ;;
  nodone)
    cp "$SA_FIX/findings.json" "$run/"
    echo '{"type":"result","subtype":"success","is_error":false,"result":"stopped early","total_cost_usd":0.25,"session_id":"s-fixture","usage":{"input_tokens":10,"output_tokens":2}}'
    exit 0 ;;
esac
echo '{"type":"result","subtype":"success","is_error":false,"result":"AUDIT DONE fixture","total_cost_usd":0.25,"session_id":"s-fixture","usage":{"input_tokens":10,"output_tokens":2}}'
SH
  cat > "$T/fakebin/npx" <<'SH'
#!/bin/bash
echo "$*" >> "$SA_T/npx-calls"
src="" name=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    add) src="$2"; shift 2 ;;
    --skill) name="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p ".claude/skills/$name" && cp -r "$src/skills/$name/." ".claude/skills/$name/" || exit 1
[ "$(cat "$SA_T/npx-mode" 2>/dev/null)" = tamper ] && echo "tampered" >> ".claude/skills/$name/SKILL.md"
exit 0
SH
  cat > "$T/fakebin/node" <<'SH'
#!/bin/bash
echo "$*" >> "$SA_T/node-calls"
exit "$(cat "$SA_T/node-rc" 2>/dev/null || echo 0)"
SH
  cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$SA_T/gh-calls"
exit 1
SH
  chmod +x "$T/fakebin/claude" "$T/fakebin/npx" "$T/fakebin/node" "$T/fakebin/gh"
}

sa_calls() { # sa_calls <stub> — how many times the stub ran
  if [ -f "$T/$1-calls" ]; then wc -l < "$T/$1-calls" | tr -d ' '; else echo 0; fi
}

sa_run() { # sa_run <args...> — prints the runner's rc
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" SA_T="$T" SA_FIX="$SA_FIX" \
           SA_PROJECT="$SA_PROJECT" SA_CONF="${SA_CONF_OVERRIDE:-$T/sa.conf}" \
           SA_REPO_URL="$T/target" SA_POLL_S="${SA_POLL_S:-1}" SA_KILL_GRACE_S="${SA_KILL_GRACE_S:-5}" \
           HARNESS_ENV_DIR="$T/env" ACCOUNT_ROUTING="${SA_ACCOUNT_ROUTING:-0}"
    unset AGENT_CALL_TICKET AGENT_CALL_FP COST_KEY HARNESS_TICKET CLAUDE_CONFIG_DIR ACCOUNTS_DIR ACCOUNT_OWN_PROJECTS
    [ -n "${SA_BUILD:-}" ] && export BUILD="$SA_BUILD" || unset BUILD
    bash "$SA_REPO_DIR/bin/security-audit.sh" "$@" > "$T/run.out" 2>&1 )
  echo $?
}
