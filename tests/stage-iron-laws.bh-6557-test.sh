#!/bin/bash
# tests/stage-iron-laws.bh-6557-test.sh — BH-6557: the iron-law fragments in
# prompts/iron-laws.d/ reach the system prompt of every build stage they list,
# through bin/agent-call.sh, and nothing else changes.
#
#   A1  sil_text on the real fragment returns the ticket block byte for byte
#   A2  sil_text decision table: whole-word stage match, CRLF / extra spaces,
#       no-header file skipped, name order, missing dir
#   A3  driven: preplan plan execute fix review qa prodqa carry all three law
#       titles in ONE --append-system-prompt; triage carries none; lead-review
#       carries only REVIEW LEVELS (BH-7123 lists it, the 2026-10-13 laws do not)
#       and SCALABLE TESTS (BH-7563 lists it); all members carry SCALABLE TESTS
#   A4  driven: a codex runner gets the laws in front of its prompt text
#   A5  driven: a caller's AGENT_SYSTEM_APPEND comes first; the laws are not
#       exported to the child; no prompts dir = today's behavior
#   A6  driven: the prompt text itself (and so PROMPT_SHA) is unchanged
#   A7  the law text is under 5% of the smallest member-stage token target
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh runs for real against a scratch HARNESS
# with fake CLIs; what the CLI was handed is read back.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/bin/lib/stage-iron-laws.sh" || { echo "FAIL: bin/lib/stage-iron-laws.sh missing"; exit 1; }
mrs_fixture "$T" sample-project
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env" "$T/wt" "$T/builds/b1"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
LAWS_DIR="$DIR/prompts/iron-laws.d"
# sha256 of the ticket's law block. Four quoted 16-hex pieces: the share leak
# check reads a bare 64-hex run as a token (tests/jobs-client-usage.bh-5235-test.sh).
# BH-7123 re-pinned it: the 2026-10-13 fragment's review lines are notes, and
# the plan stage also carries prompts/iron-laws.d/20261016-review-levels.md.
# BH-7563 re-pinned it: the plan stage also carries
# prompts/iron-laws.d/20261019-scalable-tests.md, and the review-levels class
# list gained `scalable-tests`.
TICKET_SHA="19c718c591bae292""6990d652be732d80""36c35e66497e5128""66ade9d42e872f8b"
T1='PERFORMANCE BY DEFAULT'
T2="BUILDING FROM A DESIGNER'S PROTOTYPE"
T3='REVIEW LEVELS (iron law, BH-7123'
T4='SCALABLE TESTS (iron law, BH-7563'
MEMBERS="preplan plan execute fix review qa prodqa"

# ── A1 ─────────────────────────────────────────────────────────────────────
echo "--- A1"
got=$(sil_text plan "$LAWS_DIR"; printf x); got="${got%x}"
[ "$(printf '%s' "$got" | sha256sum | cut -d' ' -f1)" = "$TICKET_SHA" ] && ok \
  || bad "A1 sil_text plan is not the ticket block (sha $(printf '%s' "$got" | sha256sum | cut -c1-12))"
case "$got" in *"PERFORMANCE BY DEFAULT (iron law, 2026-10-13)"*) ok ;; *) bad "A1 performance title missing" ;; esac
case "$got" in *"BUILDING FROM A DESIGNER'S PROTOTYPE (iron law, 2026-10-13)"*) ok ;; *) bad "A1 prototype title missing" ;; esac
case "$got" in *"$T3"*) ok ;; *) bad "A1 review-levels title missing" ;; esac
case "$got" in *"$T4"*) ok ;; *) bad "A1 scalable-tests title missing" ;; esac
case "$got" in *"each one a BLOCK"*|*"REVIEW blocks on"*|*"a visual check gates the merge"*) bad "A1 the plan block still carries a BLOCK-level review line (BH-7123)" ;; *) ok ;; esac

# ── A2 ─────────────────────────────────────────────────────────────────────
echo "--- A2"
FX="$T/fx"; mkdir -p "$FX"
printf 'stages: preplan plan review prodqa\n\nBODY-A line 1\nBODY-A line 2\n' > "$FX/10-a.md"
for st in preplan plan review prodqa; do
  [ "$(sil_text "$st" "$FX")" = $'BODY-A line 1\nBODY-A line 2' ] && ok || bad "A2 '$st' must match: '$(sil_text "$st" "$FX")'"
done
for st in preplan-files lead-review triage pre view ""; do
  out=$(sil_text "$st" "$FX"); rc=$?
  [ -z "$out" ] && [ "$rc" = 0 ] && ok || bad "A2 '$st' must give empty rc 0, got rc=$rc '$out'"
done
FX2="$T/fx2"; mkdir -p "$FX2"
printf 'stages:  execute   plan \r\n\r\nBODY-CRLF\n' > "$FX2/10-crlf.md"
printf '# README\n\nnot a law set, plan\n' > "$FX2/00-readme.md"
printf 'stages: plan\n\nBODY-Z\n' > "$FX2/90-z.md"
[ "$(sil_text plan "$FX2")" = $'BODY-CRLF\n\nBODY-Z' ] && ok \
  || bad "A2 CRLF header must match, README skipped, name order, one empty line: '$(sil_text plan "$FX2")'"
[ "$(sil_text execute "$FX2")" = 'BODY-CRLF' ] && ok || bad "A2 double-space stages line must match execute"
out=$(sil_text plan "$T/no-such-dir"); rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok || bad "A2 missing dir must give empty rc 0, got rc=$rc"

# ---------- fakes for the driven cases ---------------------------------------
# claude: argv line in $SINK, each --append-system-prompt value in
# $SINK.append.<n>, stdin (the prompt) in $SINK.stdin.<n>, and its own env's
# AGENT_SYSTEM_APPEND in $SINK.env.<n>.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --session-id <uuid>\n'; exit 0 ;; esac
n=$(( $(wc -l < "$SINK" 2>/dev/null || echo 0) + 1 ))
printf '%q ' "$@" >> "$SINK"; printf '\n' >> "$SINK"
: > "$SINK.append.$n"; prev=""
for a in "$@"; do
  [ "$prev" = --append-system-prompt ] && printf '%s\n<<END>>\n' "$a" >> "$SINK.append.$n"
  prev="$a"
done
cat > "$SINK.stdin.$n"
printf '%s' "${AGENT_SYSTEM_APPEND-UNSET}" > "$SINK.env.$n"
printf '{"type":"result","result":"ok","num_turns":1,"usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'
exit 0
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
out=""; prev=""; last=""
for a in "$@"; do [ "$prev" = --output-last-message ] && out="$a"; prev="$a"; last="$a"; done
if [ "$last" = - ]; then cat > "$SINK.codex"; else printf '%s' "$last" > "$SINK.codex"; fi
[ -n "$out" ] && echo "codex answered" > "$out"
exit 0
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/alert-line.sh"
printf '#!/bin/bash\necho "fixture machine rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/iron-law-guard.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
echo '{}' > "$T/catalog.json"
mkdir -p "$T/.codex"; echo '{}' > "$T/.codex/auth.json"
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "setup: lanes-build.sh could not compose the registry"
# The law fragments, where a deployed harness has them.
with_laws() { rm -rf "$T/prompts"; mkdir -p "$T/prompts"; cp -R "$LAWS_DIR" "$T/prompts/"; }
no_laws()   { rm -rf "$T/prompts"; }

# run_call <stage> [ENV=...] — drives bin/agent-call.sh for real.
OUTF="$T/builds/b1/out.txt"
run_call() {
  local st="$1"; shift
  : > "$T/sink"; rm -f "$T/sink".*; rm -f "$OUTF"*; rm -rf "$T/state/lane-gate"
  rm -f "$T/state/model-cooldown-"*
  ( cd "$T/wt" || exit 1
    export SINK="$T/sink" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" LANE_REGISTRY="$REG" \
           LADDER_BACKOFF_SECS=0 HUB_BUILD_OK=1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" AUTH_ACCOUNTS_CATALOG="$T/catalog.json" \
           JOBS_URL=''
    for s in PREPLAN PLAN EXECUTE FIX REVIEW QA PRODQA TRIAGE LEAD_REVIEW; do export "RUNNER_$s=claude"; done
    env -u ACCOUNT_ROUTING -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
        -u ANTHROPIC_API_KEY -u AGENT_ADVISOR_MODEL -u AGENT_ADVISOR_STAGES -u AGENT_SYSTEM_APPEND \
        -u LANE_GATE_DISABLE -u CLAUDE_CONFIG_DIR -u AGENT_CALL_NO_TOOLS \
        "$@" bash "$DIR/bin/agent-call.sh" "$st" sample-project claude-opus-5-5 600 "$OUTF" "hello" >/dev/null 2>&1 )
  echo $?
}
appends()    { local n; n=$(grep -c '^<<END>>$' "$T/sink.append.1" 2>/dev/null) || true; echo "${n:-0}"; }
append_has() { grep -qF -- "$1" "$T/sink.append.1" 2>/dev/null; }

# ── A3 ─────────────────────────────────────────────────────────────────────
echo "--- A3"
with_laws
for st in $MEMBERS; do
  RC=$(run_call "$st")
  [ -s "$T/sink" ] || { bad "A3 $st: claude never ran (rc=$RC)"; continue; }
  append_has "$T1" && ok || bad "A3 $st: '$T1' missing from --append-system-prompt"
  append_has "$T2" && ok || bad "A3 $st: '$T2' missing from --append-system-prompt"
  append_has "$T3" && ok || bad "A3 $st: '$T3' missing from --append-system-prompt"
  append_has "$T4" && ok || bad "A3 $st: '$T4' missing from --append-system-prompt"
  [ "$(appends)" = 1 ] && ok || bad "A3 $st: want exactly one --append-system-prompt, got $(appends)"
done
RC=$(run_call triage)
[ -s "$T/sink" ] || bad "A3 triage: claude never ran (rc=$RC)"
[ "$(appends)" = 0 ] && ok || bad "A3 triage: a non-member stage got --append-system-prompt: $(cat "$T/sink.append.1")"
RC=$(run_call lead-review)
[ -s "$T/sink" ] || bad "A3 lead-review: claude never ran (rc=$RC)"
[ "$(appends)" = 1 ] && ok || bad "A3 lead-review: want exactly one --append-system-prompt (the review-levels and scalable-tests laws), got $(appends)"
append_has "$T3" && ok || bad "A3 lead-review: '$T3' missing from --append-system-prompt"
append_has "$T4" && ok || bad "A3 lead-review: '$T4' missing from --append-system-prompt"
append_has "$T1" && bad "A3 lead-review: '$T1' reached a stage its fragment does not list" || ok
append_has "$T2" && bad "A3 lead-review: '$T2' reached a stage its fragment does not list" || ok

# ── A4 ─────────────────────────────────────────────────────────────────────
echo "--- A4"
RC=$(run_call execute RUNNER_EXECUTE=codex)
if [ -s "$T/sink.codex" ]; then
  grep -qF -- "$T1" "$T/sink.codex" && ok || bad "A4 codex prompt text lacks '$T1'"
  grep -qF -- "$T2" "$T/sink.codex" && ok || bad "A4 codex prompt text lacks '$T2'"
  grep -qF -- 'fixture machine rules' "$T/sink.codex" && ok || bad "A4 codex lost the machine rules"
else
  bad "A4 codex never ran (rc=$RC)"
fi

# ── A5 ─────────────────────────────────────────────────────────────────────
echo "--- A5"
RC=$(run_call execute AGENT_SYSTEM_APPEND=X-APPEND)
l1=$(sed -n 1p "$T/sink.append.1" 2>/dev/null); l2=$(sed -n 2p "$T/sink.append.1" 2>/dev/null)
l3=$(sed -n 3p "$T/sink.append.1" 2>/dev/null)
[ "$l1" = X-APPEND ] && [ -z "$l2" ] && [ "${l3#"$T1"}" != "$l3" ] && ok || bad "A5 the caller value must come first, then one empty line: '$(head -c 40 "$T/sink.append.1")'"
append_has "$T1" && ok || bad "A5 execute with a caller value lost the laws"
[ "$(appends)" = 1 ] && ok || bad "A5 want exactly one --append-system-prompt, got $(appends)"
[ "$(cat "$T/sink.env.1" 2>/dev/null)" = UNSET ] && ok \
  || bad "A5 execute: the laws must not be exported to the child, child saw '$(head -c 40 "$T/sink.env.1")'"
RC=$(run_call triage AGENT_SYSTEM_APPEND=X-APPEND)
[ "$(cat "$T/sink.env.1" 2>/dev/null)" = X-APPEND ] && ok \
  || bad "A5 triage: the caller's export must be unchanged, child saw '$(head -c 40 "$T/sink.env.1")'"
[ "$(sed '/^<<END>>$/d' "$T/sink.append.1")" = X-APPEND ] && ok || bad "A5 triage append must be exactly X-APPEND"
no_laws
RC=$(run_call execute)
[ -s "$T/sink" ] || bad "A5 no-laws execute: claude never ran (rc=$RC)"
[ "$(appends)" = 0 ] && ok || bad "A5 no prompts dir: execute must get no --append-system-prompt"

# ── A6 ─────────────────────────────────────────────────────────────────────
echo "--- A6"
with_laws
RC=$(run_call plan)
[ "$(cat "$T/sink.stdin.1" 2>/dev/null)" = hello ] && ok || bad "A6 plan: the prompt text changed: '$(head -c 60 "$T/sink.stdin.1")'"
[ "$(cat "$OUTF.prompt" 2>/dev/null)" = hello ] && ok || bad "A6 plan: \$OUT.prompt (the PROMPT_SHA input) changed"

# ── A7 ─────────────────────────────────────────────────────────────────────
echo "--- A7"
bytes=$(for st in $MEMBERS; do sil_text "$st" "$LAWS_DIR"; done | wc -c)
bytes=$(( bytes / 7 ))
min=$(jq -s --arg m "$MEMBERS" '[.[] | arrays | .[] | select(.stage as $s | ($m | split(" ") | index($s))) | .target_tokens] | min' \
  "$DIR"/catalog/context-budgets.d/*.json 2>/dev/null)
if [ -n "$min" ] && [ "$min" != null ] && [ "$bytes" -gt 0 ]; then
  [ $(( bytes / 4 * 100 )) -lt $(( min * 5 )) ] && ok || bad "A7 laws ~$((bytes / 4)) tokens >= 5% of the smallest target $min"
else
  bad "A7 could not read the member-stage targets (min=$min bytes=$bytes)"
fi

echo "stage-iron-laws: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
