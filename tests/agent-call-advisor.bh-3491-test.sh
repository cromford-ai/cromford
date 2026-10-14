#!/bin/bash
# tests/agent-call-advisor.bh-3491-test.sh — BH-3491: the claude runner of
# bin/agent-call.sh passes `--advisor <m>` on the execute and fix stages when a
# settings row asks for it, never anywhere else, retries once without it when
# the CLI refuses the flag at launch, and writes the advisor's tokens as their
# own `<stage>-advisor` cost row.
#
#   AT-1  advisor.<project> / advisor.default rows -> --advisor on execute + fix,
#         with the consult line in --append-system-prompt
#   AT-2  review/plan/triage/preplan never get the flag or the line
#   AT-3  a codex runner and a NO_TOOLS=1 claude call never get it
#   AT-4  off / no rows / junk value / Fable main + opus advisor -> no flag
#   AT-5  a launch refusal retries once without the flag, one warn alert
#         (bin/alert-line.sh, kind:alert, severity warn), a day
#         flag that keeps later calls off; a failure AFTER a turn is not retried
#   AT-6  env AGENT_ADVISOR_MODEL is read only when the box has no settings
#         answer; a stale cached row beats env; the stage-list row narrows
#   AT-8  one --append-system-prompt carrying both AGENT_SYSTEM_APPEND and the line
#   AT-9  the advisor iterations become a `<stage>-advisor` row, priced at the
#         advisor model, beside the unchanged executor row
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh runs for real against a scratch HARNESS
# with fake CLIs; what the CLI was handed and what the ledger got are read back.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 170 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" project-3
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env" "$T/wt" "$T/builds/b1"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
NOW=$(date -u +%s); DAY=$(date -u +%Y%m%d)
CONSULT='Consult the advisor before committing to an approach that deviates from plan.md, when the same error repeats twice, and before you write the final summary.'
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "setup: lanes-build.sh could not compose the registry"

# ---------- fakes -----------------------------------------------------------
# claude: one line of %q argv per invocation in $SINK, the --append-system-prompt
# value(s) in $SINK.append.<n>, then the answer CLAUDE_MODE asks for. With
# FAKE_TRANSCRIPT=adv|plain it also writes the session transcript where the CLI
# would (HOME/.claude/projects/<cwd slug>/<session>.jsonl).
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --session-id <uuid>\n'; exit 0 ;; esac
n=$(( $(wc -l < "$SINK" 2>/dev/null || echo 0) + 1 ))
printf '%q ' "$@" >> "$SINK"; printf '\n' >> "$SINK"
adv=""; sid=""; prev=""; : > "$SINK.append.$n"
for a in "$@"; do
  case "$prev" in
    --advisor) adv="$a" ;;
    --session-id|--resume) sid="$a" ;;
    --append-system-prompt) printf '%s\n<<END>>\n' "$a" >> "$SINK.append.$n" ;;
  esac
  prev="$a"
done
if [ -n "$sid" ] && [ -n "${FAKE_TRANSCRIPT:-}" ]; then
  d="$HOME/.claude/projects/$(pwd | tr / -)"; mkdir -p "$d"
  {
    # response m1 written twice (two content blocks), m2 once
    printf '{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
    printf '{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
    if [ "$FAKE_TRANSCRIPT" = adv ]; then
      printf '{"type":"assistant","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":200,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"iterations":[{"type":"message","input_tokens":200,"output_tokens":20},{"type":"advisor_message","model":"claude-fable-5-1","input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}]}}}\n'
    else
      printf '{"type":"assistant","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":200,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
    fi
  } > "$d/$sid.jsonl"
fi
case "${CLAUDE_MODE:-ok}" in
  advisor-refuse)
    if [ -n "$adv" ]; then
      echo "Error: --advisor $adv requires usage-credits consent; run /model fable" >&2; exit 1
    fi ;;
  turn-fail)
    printf '{"type":"result","is_error":true,"num_turns":3,"result":"I asked the advisor and still failed","usage":{"input_tokens":50,"output_tokens":9},"total_cost_usd":0.02}\n'
    exit 1 ;;
esac
printf '{"type":"result","result":"ok","session_id":"%s","num_turns":2,"usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n' "$sid"
exit 0
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
printf 'codex %q\n' "$*" >> "$SINK.codex"
out=""; prev=""; for a in "$@"; do [ "$prev" = --output-last-message ] && out="$a"; prev="$a"; done
[ -n "$out" ] && echo "codex answered" > "$out"
exit 0
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo "grok" >> "$SINK.grok"; echo "grok answered"; exit 0
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
# beat.sh keeps every payload, so the alert's severity and id are readable.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/beats.log"\nexit 0\n' > "$T/bin/beat.sh"
# The real alert writer, run against this scratch HARNESS.
printf '#!/bin/bash\nexec bash "%s/bin/alert-line.sh" "$@"\n' "$DIR" > "$T/bin/alert-line.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/iron-law-guard.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
echo '{}' > "$T/catalog.json"
mkdir -p "$T/.codex"; echo '{}' > "$T/.codex/auth.json"
# A fixture price for the advisor model, so the row's USD is checkable by hand:
# fable 1e-5 prompt / 1e-4 completion; opus 1e-6 / 1e-5.
cat > "$T/prices.json" <<'EOF'
{"per_token":{"claude-fable-5-1":{"prompt":0.00001,"completion":0.0001,"cache_read":0.000001,"cache_write":0.0000125},
 "claude-opus-5-5":{"prompt":0.000001,"completion":0.00001,"cache_read":0.0000001,"cache_write":0.00000125}}}
EOF

# cache <age-seconds> <json values> — the lane-gate settings cache, fetched
# <age> seconds before NOW (0 = fresh; 3600 = stale, still a settings answer).
cache() { jq -n --argjson fa "$(( NOW - $1 ))" --argjson v "$2" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
nocache() { rm -f "$T/state/settings-cache.json"; rm -rf "$T/state/lane-gate"; }
clean_day() { rm -f "$T/flags/advisor-refused-"*; : > "$T/logs/ALERTS.log"; : > "$T/beats.log"; }

# run_call <stage> [model] [ENV=...] — drives bin/agent-call.sh for real.
OUTF="$T/builds/b1/out.txt"
run_call() {
  local st="$1" m="${2:-claude-opus-5-5}"; shift 2 2>/dev/null || shift $#
  : > "$T/sink"; rm -f "$T/sink".*; rm -f "$OUTF"*; rm -rf "$T/state/lane-gate"
  rm -f "$T/state/model-cooldown-"*
  ( cd "$T/wt" || exit 1
    export SINK="$T/sink" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" LANE_REGISTRY="$REG" \
           LADDER_BACKOFF_SECS=0 HUB_BUILD_OK=1 MODEL_PRICES="$T/prices.json" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" AUTH_ACCOUNTS_CATALOG="$T/catalog.json" \
           JOBS_URL='' RUNNER_EXECUTE="${RUNNER_EXECUTE:-claude}" RUNNER_FIX=claude RUNNER_REVIEW=claude \
           RUNNER_PLAN=claude RUNNER_TRIAGE=claude RUNNER_PREPLAN=claude
    env -u ACCOUNT_ROUTING -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
        -u ANTHROPIC_API_KEY -u AGENT_ADVISOR_MODEL -u AGENT_ADVISOR_STAGES -u AGENT_SYSTEM_APPEND \
        -u LANE_GATE_DISABLE -u CLAUDE_CONFIG_DIR -u AGENT_CALL_NO_TOOLS \
        "$@" bash "$DIR/bin/agent-call.sh" "$st" project-3 "$m" 600 "$OUTF" "hello" >/dev/null 2>&1 )
  echo $?
}
calls()   { grep -c . "$T/sink" 2>/dev/null || true; }
line()    { sed -n "${1}p" "$T/sink"; }
adv_of()  { line "$1" | grep -oE -- "--advisor [^ ]+" | head -1 | cut -d' ' -f2; }
has_adv() { line "${1:-1}" | grep -q -- '--advisor '; }
appends() { local n; n=$(grep -c '^<<END>>$' "$T/sink.append.${1:-1}" 2>/dev/null) || true; echo "${n:-0}"; }
append_has() { grep -qF -- "$2" "$T/sink.append.$1" 2>/dev/null; }

# ── AT-1 (a) ────────────────────────────────────────────────────────────────
echo "--- AT-1"
cache 0 '{"advisor.project-3":"fable"}'
for st in execute fix; do
  RC=$(run_call "$st")
  [ "$RC" = 0 ] && ok || bad "AT-1 $st rc=$RC"
  [ "$(adv_of 1)" = fable ] && ok || bad "AT-1 $st: want --advisor fable, argv: $(line 1)"
  append_has 1 "$CONSULT" && ok || bad "AT-1 $st: consult line missing from --append-system-prompt: $(cat "$T/sink.append.1" 2>/dev/null)"
done
cache 0 '{"advisor.default":"opus"}'
RC=$(run_call execute)
[ "$(adv_of 1)" = opus ] && ok || bad "AT-1 advisor.default=opus: want --advisor opus, argv: $(line 1)"
cache 0 '{"advisor.default":"opus","advisor.project-3":"fable"}'
RC=$(run_call execute)
[ "$(adv_of 1)" = fable ] && ok || bad "AT-1 the project row must beat advisor.default: $(line 1)"

# ── AT-2 (b) ────────────────────────────────────────────────────────────────
echo "--- AT-2"
cache 0 '{"advisor.project-3":"fable"}'
for st in review plan triage preplan; do
  RC=$(run_call "$st")
  [ "$(calls)" -ge 1 ] && ok || bad "AT-2 $st: claude never ran (rc=$RC)"
  has_adv 1 && bad "AT-2 $st carried --advisor: $(line 1)" || ok
  append_has 1 "Consult the advisor" && bad "AT-2 $st carried the consult line" || ok
done

# ── AT-3 (c) ────────────────────────────────────────────────────────────────
echo "--- AT-3"
RC=$(RUNNER_EXECUTE=codex run_call execute)
[ -s "$T/sink.codex" ] && ok || bad "AT-3 codex never ran (rc=$RC)"
grep -q -- '--advisor' "$T/sink.codex" 2>/dev/null && bad "AT-3 codex argv carried --advisor: $(cat "$T/sink.codex")" || ok
RC=$(run_call execute claude-opus-5-5 AGENT_CALL_NO_TOOLS=1)
[ "$(calls)" -ge 1 ] && ok || bad "AT-3 NO_TOOLS claude never ran (rc=$RC)"
has_adv 1 && bad "AT-3 a NO_TOOLS call carried --advisor: $(line 1)" || ok

# ── AT-4 (d) ────────────────────────────────────────────────────────────────
echo "--- AT-4"
cache 0 '{}'
RC=$(run_call execute)
has_adv 1 && bad "AT-4 no rows, no env: flag passed: $(line 1)" || ok
[ "$(appends 1)" = 0 ] && ok || bad "AT-4 advisor off must add no --append-system-prompt"
cache 0 '{"advisor.project-3":"off","advisor.default":"fable"}'
RC=$(run_call execute)
has_adv 1 && bad "AT-4 advisor.project-3=off must beat advisor.default: $(line 1)" || ok
cache 0 '{"advisor.project-3":"rm -rf"}'
RC=$(run_call execute)
[ "$RC" = 0 ] && ok || bad "AT-4 junk value: the call must still run rc 0, got $RC"
has_adv 1 && bad "AT-4 junk value passed as a flag: $(line 1)" || ok
cache 0 '{"advisor.project-3":"opus"}'
RC=$(run_call execute claude-fable-5-1)
[ "$(calls)" -ge 1 ] && ok || bad "AT-4 Fable main never ran"
has_adv 1 && bad "AT-4 Fable main + opus advisor must drop the flag: $(line 1)" || ok
cache 0 '{"advisor.project-3":"fable"}'
RC=$(run_call execute claude-fable-5-1)
[ "$(adv_of 1)" = fable ] && ok || bad "AT-4 Fable main + fable advisor keeps the flag: $(line 1)"

# The lib itself: `off` is the explicit unset, said without a refusal; a junk
# value is refused out loud (stderr, which agent-call routes to /dev/null).
lib_q() { ( export HARNESS="$T" JOBS_URL='' LANE_REGISTRY="$REG"; . "$DIR/bin/lib/advisor.sh"; advisor_for_project project-3 ) 2>"$T/lib.err"; }
cache 0 '{"advisor.project-3":"off","advisor.default":"fable"}'
[ "$(lib_q)" = "model= source=none" ] && ok || bad "AT-4 lib: off must answer model= source=none, got '$(lib_q)'"
[ -s "$T/lib.err" ] && bad "AT-4 lib: off is not a refused value: $(cat "$T/lib.err")" || ok
cache 0 '{"advisor.project-3":"rm -rf"}'
[ "$(lib_q)" = "model= source=none" ] && ok || bad "AT-4 lib: junk must answer model= source=none"
grep -q 'refused value for project-3' "$T/lib.err" && ok || bad "AT-4 lib: junk must be refused on stderr: $(cat "$T/lib.err")"

# ── AT-5 (e) ────────────────────────────────────────────────────────────────
echo "--- AT-5"
clean_day
cache 0 '{"advisor.project-3":"fable"}'
RC=$(run_call execute claude-opus-5-5 CLAUDE_MODE=advisor-refuse)
[ "$RC" = 0 ] && ok || bad "AT-5 a refused advisor must not fail the call, rc=$RC"
[ "$(calls)" = 2 ] && ok || bad "AT-5 want exactly 2 claude invocations, got $(calls): $(cat "$T/sink")"
has_adv 1 && ok || bad "AT-5 first attempt must carry --advisor: $(line 1)"
has_adv 2 && bad "AT-5 the retry must drop --advisor: $(line 2)" || ok
append_has 2 "Consult the advisor" && bad "AT-5 the retry must drop the consult line" || ok
[ "$(line 1 | grep -oE -- '--model [^ ]+')" = "$(line 2 | grep -oE -- '--model [^ ]+')" ] && ok \
  || bad "AT-5 the retry must re-run the same model: $(line 1) / $(line 2)"
[ -f "$T/flags/advisor-refused-default-fable-$DAY" ] && ok || bad "AT-5 day flag missing: $(ls "$T/flags")"
[ "$(grep -c 'refused --advisor fable' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "AT-5 want one ALERTS line: $(cat "$T/logs/ALERTS.log")"
ADV_BEAT=$(grep -h 'refused --advisor fable' "$T/beats.log" 2>/dev/null | grep -o '{.*}' | head -1)
[ "$(jq -r '.kind + "|" + (.severity // "") + "|" + (.alertid // "")' <<<"$ADV_BEAT" 2>/dev/null)" = "alert|warn|advisor-refused-default" ] && ok \
  || bad "AT-5 the alert must be a warn (digest) alert with id advisor-refused-default: $(cat "$T/beats.log" 2>/dev/null)"
grep -q 'refused --advisor fable at launch' "$T/logs/failovers.log" && ok || bad "AT-5 no failovers.log line"
RC=$(run_call execute claude-opus-5-5 CLAUDE_MODE=advisor-refuse)
[ "$RC" = 0 ] && ok || bad "AT-5 second call rc=$RC"
[ "$(calls)" = 1 ] && ok || bad "AT-5 the same day a second call must launch once, got $(calls)"
has_adv 1 && bad "AT-5 the day flag must keep the advisor off: $(line 1)" || ok
[ "$(grep -c 'refused --advisor fable' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "AT-5 a second warn line was written"
clean_day
RC=$(run_call execute claude-opus-5-5 CLAUDE_MODE=turn-fail LADDER_TIER2_GROK=0 RUNNER_EXECUTE_FALLBACK=none)
[ "$(calls)" = 1 ] && ok || bad "AT-5 a failure after turns must not be retried without the flag, got $(calls): $(cat "$T/sink")"
[ -f "$T/flags/advisor-refused-default-fable-$DAY" ] && bad "AT-5 a failure after turns set the day flag" || ok

# ── AT-6 (f) ────────────────────────────────────────────────────────────────
echo "--- AT-6"
clean_day
cache 0 '{}'
RC=$(run_call execute claude-opus-5-5 AGENT_ADVISOR_MODEL=opus)
has_adv 1 && bad "AT-6 env must be ignored when the settings API answered: $(line 1)" || ok
nocache
RC=$(run_call execute claude-opus-5-5 AGENT_ADVISOR_MODEL=opus)
[ "$(adv_of 1)" = opus ] && ok || bad "AT-6 no settings answer: env opus must apply: $(line 1)"
cache 3600 '{"advisor.project-3":"fable"}'
RC=$(run_call execute claude-opus-5-5 AGENT_ADVISOR_MODEL=opus)
[ "$(adv_of 1)" = fable ] && ok || bad "AT-6 a stale cached row must beat env: $(line 1)"
cache 0 '{"advisor.project-3":"fable","lib.advisor.agent_advisor_stages":"execute"}'
RC=$(run_call fix)
has_adv 1 && bad "AT-6 stages row 'execute' must keep fix off: $(line 1)" || ok
RC=$(run_call execute)
[ "$(adv_of 1)" = fable ] && ok || bad "AT-6 stages row 'execute' keeps execute on: $(line 1)"

# ── AT-8 ────────────────────────────────────────────────────────────────────
echo "--- AT-8"
cache 0 '{"advisor.project-3":"fable"}'
RC=$(run_call execute claude-opus-5-5 AGENT_SYSTEM_APPEND=X-APPEND)
[ "$(appends 1)" = 1 ] && ok || bad "AT-8 want ONE --append-system-prompt, got $(appends 1)"
append_has 1 X-APPEND && append_has 1 "$CONSULT" && ok || bad "AT-8 the one append must carry both: $(cat "$T/sink.append.1")"
cache 0 '{}'
RC=$(run_call execute claude-opus-5-5 AGENT_SYSTEM_APPEND=X-APPEND)
[ "$(appends 1)" = 1 ] && [ "$(sed -n 1p "$T/sink.append.1")" = X-APPEND ] && [ "$(sed -n 2p "$T/sink.append.1")" = '<<END>>' ] \
  && ok || bad "AT-8 advisor off: the append must be exactly X-APPEND: $(cat "$T/sink.append.1")"

# ── AT-9 (cost row) ─────────────────────────────────────────────────────────
echo "--- AT-9"
cache 0 '{"advisor.project-3":"fable"}'
: > "$T/logs/cost.csv"
RC=$(run_call execute claude-opus-5-5 FAKE_TRANSCRIPT=adv)
SID=$(line 1 | grep -oE -- '--session-id [^ ]+' | cut -d' ' -f2)
rows_for() { awk -F, -v s="$SID" '$17==s' "$1" 2>/dev/null; }
[ "$(rows_for "$T/logs/cost.csv" | grep -c .)" = 2 ] && ok || bad "AT-9 want 2 rows for session $SID: $(cat "$T/logs/cost.csv")"
EX=$(rows_for "$T/logs/cost.csv" | awk -F, '$4=="execute"')
AD=$(rows_for "$T/logs/cost.csv" | awk -F, '$4=="execute-advisor"')
[ "$(printf '%s' "$EX" | awk -F, '{print $6"|"$9"|"$10}')" = "claude-opus-5-5|300|30" ] && ok \
  || bad "AT-9 executor row must stay executor-only (300 in / 30 out): $EX"
[ "$(printf '%s' "$AD" | awk -F, '{print $5"|"$6"|"$9"|"$10"|"$11"|"$12}')" = "claude|claude-fable-5-1|1000|100|0|0" ] && ok \
  || bad "AT-9 advisor row tokens/model: $AD"
# 1000 * 1e-5 + 100 * 1e-4 = 0.02
awk -v u="$(printf '%s' "$AD" | awk -F, '{print $13}')" 'BEGIN{exit !(u+0 > 0.019999 && u+0 < 0.020001)}' && ok \
  || bad "AT-9 advisor USD must be 0.02: $AD"
[ "$(rows_for "$T/builds/b1/cost.csv" | grep -c .)" = 2 ] && ok || bad "AT-9 the build cost.csv tee must carry both rows: $(cat "$T/builds/b1/cost.csv" 2>/dev/null)"
: > "$T/logs/cost.csv"
RC=$(run_call execute claude-opus-5-5 FAKE_TRANSCRIPT=plain)
SID=$(line 1 | grep -oE -- '--session-id [^ ]+' | cut -d' ' -f2)
[ "$(rows_for "$T/logs/cost.csv" | grep -c .)" = 1 ] && ok || bad "AT-9 no advisor iterations: want 1 row: $(cat "$T/logs/cost.csv")"
cache 0 '{}'
: > "$T/logs/cost.csv"
RC=$(run_call execute claude-opus-5-5 FAKE_TRANSCRIPT=adv)
SID=$(line 1 | grep -oE -- '--session-id [^ ]+' | cut -d' ' -f2)
[ "$(rows_for "$T/logs/cost.csv" | grep -c .)" = 1 ] && ok || bad "AT-9 advisor off: want 1 row: $(cat "$T/logs/cost.csv")"

echo "agent-call-advisor.bh-3491: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
