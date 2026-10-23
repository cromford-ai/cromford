#!/bin/bash
# tests/runner-codex.bh-7937-test.sh — bin/lib/runner-codex.sh runs one stage
# prompt file on the codex lane of bin/agent-call.sh, and the codex CLI gets the
# same prompt bytes on stdin that the claude CLI gets for the same file
# (BH-7967, parent BH-7937 AT5).
#
# Driven through the real wrapper and the real bin/agent-call.sh with fake
# `codex` and `claude` CLIs on PATH that record their stdin. The model comes
# from the codex.default route in the resolver's box cache (mrs_fixture), never
# from a literal here. curl, wget and openssl are fakes that log any call, so a
# network attempt is a failure (0 vendor calls).
#   C1  codex stdin == claude stdin == prompt file (no rules render); no argv
#   C2  with a rules render: codex stdin == rules + "\n\n" + claude stdin
#   C3  a file with trailing newlines: codex and claude get the same bytes
#   C4  a 5-byte prompt still goes on stdin (transport does not depend on size)
#   C5  codex -m is the codex.default route model, and agent-call is passed it
#       (no model/runner mismatch); CODEX_MODEL still overrides
#   C6  no args, a missing or extra arg, a missing file: rc 2; no codex.default route rc 75; no CLI ran
#   C7  0 network calls
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
WRAP="$DIR/bin/lib/runner-codex.sh"
PROJ="rc7937-$$"
mrs_fixture "$T" "$PROJ"
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
echo "codex $*" >> "$VENDOR_LOG"
out=""; prev=""
for a in "$@"; do
  case "$prev" in --output-last-message) out="$a" ;; -m) printf '%s' "$a" > "$CODEX_SINK.model" ;; esac
  prev="$a"
done
if [ "${!#}" = "-" ]; then cat > "$CODEX_SINK"; else printf '%s' "${!#}" > "$CODEX_SINK.argv"; fi
[ -n "$out" ] && echo "codex answered" > "$out"
exit 0
EOF
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --resume <sessionId>\n'; exit 0 ;; esac
echo "claude $*" >> "$VENDOR_LOG"
cat > "$CLAUDE_SINK"
printf '{"result":"claude answered","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
for n in curl wget openssl; do
  printf '#!/bin/bash\necho "%s $*" >> "$NET_LOG"\nexit 1\n' "$n" > "$T/fakebin/$n"
done
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
cp "$DIR/bin/account-pick.sh" "$T/bin/account-pick.sh"
rules() { # rules on|off — the machine rules render the codex lane puts in front
  if [ "$1" = on ]; then printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
  else printf '#!/bin/bash\nexit 0\n' > "$T/bin/sync-agent-rules.sh"; fi
  chmod +x "$T/bin/sync-agent-rules.sh"
}
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
: > "$T/net.log"

RC=0
# run <cmd...> — one call with the fixture env; the sinks are cleared first.
run() {
  rm -f "$T/codex.in" "$T/codex.in.argv" "$T/codex.in.model" "$T/claude.in"
  : > "$T/vendor.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" \
           CODEX_SINK="$T/codex.in" CLAUDE_SINK="$T/claude.in" VENDOR_LOG="$T/vendor.log" NET_LOG="$T/net.log" \
           CODEX_API_KEY=fixture-not-a-key LADDER_BACKOFF_SECS=0 CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    env -u CODEX_MODEL -u CODEX_DEFAULT_MODEL -u RUNNER_EXECUTE -u RUNNER_EXECUTE_FALLBACK -u AGENT_CALL_RUNNERS \
      -u AGENT_ARGV_MAX -u ACCOUNT_ROUTING -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u HARNESS_SECRET \
      "$@" >"$T/run.out" 2>&1 ); RC=$?
}
vendor_lines() { wc -l < "$T/vendor.log" | tr -d ' '; }
# The claude path: the same prompt file, as @<path>, on the claude runner.
CLAUDE_MODEL=$(HARNESS="$T" HARNESS_SECRET='' bash -c '. "$1"; model_for build.execute "$2"' _ "$DIR/bin/lib/model-route.sh" "$PROJ")
CODEX_ROUTE=$(HARNESS="$T" HARNESS_SECRET='' bash -c '. "$1"; model_for codex.default "$2"' _ "$DIR/bin/lib/model-route.sh" "$PROJ")
[ -n "$CLAUDE_MODEL" ] && [ -n "$CODEX_ROUTE" ] && ok || bad "fixture: no build.execute or codex.default route in the box cache"
run_codex()  { run env bash "$WRAP" "$1" execute "$PROJ" 60 "$T/out.codex"; }
run_claude() { run env RUNNER_EXECUTE=claude bash "$DIR/bin/agent-call.sh" execute "$PROJ" "$CLAUDE_MODEL" 60 "$T/out.claude" "@$1"; }

# A prompt that is not shell-safe: multi-line UTF-8, $ ` \ quotes, no final newline.
P1="$T/prompt1.md"
printf '# Stage: execute\nRun `make test` and read $HOME, ${X:-y} and $(id).\nBackslash: \\ \\n "quotes" '"'"'single'"'"'\nUTF-8: caf\xc3\xa9 \xe2\x9c\x93 \xe6\x97\xa5\xe6\x9c\xac\n\tTab line; end without newline' > "$P1"

# C1 — no rules render: codex stdin == claude stdin == the prompt file
rules off
run_codex "$P1"
[ "$RC" = 0 ] && ok || bad "C1: wrapper rc $RC, expected 0: $(tail -5 "$T/run.out")"
[ -f "$T/codex.in" ] && cmp -s "$T/codex.in" "$P1" && ok || bad "C1: codex stdin is not the prompt file bytes"
[ ! -e "$T/codex.in.argv" ] && ok || bad "C1: codex got the prompt as argv, not on stdin"
[ ! -e "$T/claude.in" ] && ok || bad "C1: the wrapper run called claude"
cp "$T/codex.in" "$T/c1.codex" 2>/dev/null
run_claude "$P1"
[ "$RC" = 0 ] && ok || bad "C1: claude path rc $RC: $(tail -5 "$T/run.out")"
[ -f "$T/claude.in" ] && cmp -s "$T/claude.in" "$P1" && ok || bad "C1: claude stdin is not the prompt file bytes"
cmp -s "$T/c1.codex" "$T/claude.in" && ok || bad "C1: codex and claude got different bytes"
[ ! -e "$T/codex.in" ] && ok || bad "C1: the claude path called codex"

# C2 — rules render on: codex stdin == "test rules" + "\n\n" + claude stdin
rules on
run_codex "$P1"
[ "$RC" = 0 ] && ok || bad "C2: wrapper rc $RC"
printf 'test rules\n\n' > "$T/c2.want"; cat "$P1" >> "$T/c2.want"
cmp -s "$T/codex.in" "$T/c2.want" && ok || bad "C2: codex stdin is not rules + blank line + the stage prompt"
tail -c +"$(( $(printf 'test rules\n\n' | wc -c) + 1 ))" "$T/codex.in" > "$T/c2.tail" 2>/dev/null
cp "$T/codex.in" "$T/c2.codex" 2>/dev/null
run_claude "$P1"
cmp -s "$T/c2.tail" "$T/claude.in" && ok || bad "C2: the stage text after the rules block differs from the claude bytes"
rules off

# C3 — trailing newlines: both runners get the same bytes
P3="$T/prompt3.md"; printf 'line one\nline two\n\n' > "$P3"
run_codex "$P3"; cp "$T/codex.in" "$T/c3.codex" 2>/dev/null
[ -s "$T/c3.codex" ] && ok || bad "C3: codex got nothing on stdin"
run_claude "$P3"
cmp -s "$T/c3.codex" "$T/claude.in" && ok || bad "C3: codex and claude got different bytes for a trailing-newline file"

# C4 — a 5-byte prompt still goes on stdin
P4="$T/prompt4.md"; printf 'hello' > "$P4"
run_codex "$P4"
[ "$RC" = 0 ] && ok || bad "C4: wrapper rc $RC"
cmp -s "$T/codex.in" "$P4" && ok || bad "C4: the 5-byte prompt is not on codex stdin"
[ ! -e "$T/codex.in.argv" ] && ok || bad "C4: a small prompt went as argv, not on stdin"

# C5 — the model is the codex.default route
[ "$(cat "$T/codex.in.model" 2>/dev/null)" = "$CODEX_ROUTE" ] && ok \
  || bad "C5: codex -m '$(cat "$T/codex.in.model" 2>/dev/null)', expected the codex.default route '$CODEX_ROUTE'"
# The wrapper passes agent-call that same model, so the model/runner check sees
# a codex-family model: under refuse a claude model here would be rc 74.
: > "$T/logs/failovers.log"
run env AGENT_CALL_MODEL_MISMATCH=refuse bash "$WRAP" "$P4" execute "$PROJ" 60 "$T/out.codex"
[ "$RC" = 0 ] && ok || bad "C5: under AGENT_CALL_MODEL_MISMATCH=refuse the wrapper got rc $RC: $(tail -3 "$T/run.out")"
! grep -q 'MISMATCH' "$T/logs/failovers.log" && ok || bad "C5: agent-call saw a model/runner mismatch: $(grep MISMATCH "$T/logs/failovers.log" | head -1)"
# An operator CODEX_MODEL still wins, as in agent-call's codex_model.
run env CODEX_MODEL=fixture-codex-model bash "$WRAP" "$P4" execute "$PROJ" 60 "$T/out.codex"
[ "$(cat "$T/codex.in.model" 2>/dev/null)" = fixture-codex-model ] && ok || bad "C5: CODEX_MODEL did not override the route"

# C6 — refusals: nothing is called
run env bash "$WRAP"
[ "$RC" = 2 ] && ok || bad "C6: no args gave rc $RC, expected 2"
[ "$(vendor_lines)" = 0 ] && ok || bad "C6: no args called a CLI"
run env bash "$WRAP" "$T/no-such-file.md" execute "$PROJ" 60 "$T/out.codex"
[ "$RC" = 2 ] && ok || bad "C6: missing prompt file gave rc $RC, expected 2"
[ "$(vendor_lines)" = 0 ] && ok || bad "C6: missing prompt file called a CLI"
run env bash "$WRAP" "$P4" execute "$PROJ" 60
[ "$RC" = 2 ] && ok || bad "C6: a missing outfile argument gave rc $RC, expected 2"
run env bash "$WRAP" "$P4" execute "$PROJ" 60 "$T/out.codex" extra
[ "$RC" = 2 ] && ok || bad "C6: an extra argument gave rc $RC, expected 2"
run env bash "$WRAP" "$P4" "" "$PROJ" 60 "$T/out.codex"
[ "$RC" = 2 ] && ok || bad "C6: an empty stage gave rc $RC, expected 2"
[ "$(vendor_lines)" = 0 ] && ok || bad "C6: a bad argument list called a CLI"
run env bash "$WRAP" "$P4" execute "rc7937-noroute-$$" 60 "$T/out.codex"
[ "$RC" = 75 ] && ok || bad "C6: no codex.default route gave rc $RC, expected 75: $(tail -3 "$T/run.out")"
[ "$(vendor_lines)" = 0 ] && ok || bad "C6: no route still called a CLI"
grep -q 'codex.default' "$T/run.out" && ok || bad "C6: the no-route refusal does not name the role"

# C7 — the budget: no network call in the whole suite
NET=$(wc -l < "$T/net.log" | tr -d ' ')
[ "$NET" = 0 ] && ok || bad "C7: $NET network call(s): $(head -3 "$T/net.log")"
echo "vendor calls: $NET"

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: runner-codex.bh-7937 ($PASS checks)"
else
  echo "runner-codex.bh-7937: $PASS passed, $FAIL failed"; exit 1
fi
