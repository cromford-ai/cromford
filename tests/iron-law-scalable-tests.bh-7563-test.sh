#!/bin/bash
# tests/iron-law-scalable-tests.bh-7563-test.sh — BH-7563: the Scalable Tests
# iron law reaches PLAN, EXECUTE and REVIEW through the BH-6557 law-set
# fragment, the fleet rules render, and the ALWAYS-BLOCK catalog, so a REVIEW
# finding of one of its five conditions stands as a BLOCK under REVIEW LEVELS.
#
#   S1  sil_text decision table: preplan plan execute fix review qa prodqa
#       lead-review carry the title, the PLAN line and the five review
#       conditions; triage prd mockup preplan-files pre and "" carry none
#   S2  driven bin/agent-call.sh with a fake claude: plan and preplan get the
#       PLAN line; review and lead-review get the five conditions and the
#       [BLOCK scalable-tests] tag; triage gets no SCALABLE TESTS text
#   S3  rules/topics/14-scalable-tests.md body == the fragment body; the
#       render carries the PLAN and REVIEW lines; render-rules --check clean
#   S4  rl_line_blocks stands / demotes table for the new class; rl_cap in
#       levels mode, class grammar in use, keeps it and VERDICT: BLOCK and
#       demotes a 2 px finding
#   S5  every catalog class is named in the five ALWAYS-BLOCK class lists;
#       topic 13 body == the 20261016 fragment body
#   S6  root CLAUDE.md carries the rule; its first fenced block is still the
#       verification contract
#   S7  mutation: cut the PLAN line and the catalog row in a copy; S1 names
#       exactly the fragment and S4's first line no longer stands
# Run: HARNESS_TEST_SANDBOX=1 bash tests/iron-law-scalable-tests.bh-7563-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/bin/lib/stage-iron-laws.sh" || { echo "FAIL: bin/lib/stage-iron-laws.sh missing"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LAWS_DIR="$DIR/prompts/iron-laws.d"
FRAG="$LAWS_DIR/20261019-scalable-tests.md"
TOPIC="$DIR/rules/topics/14-scalable-tests.md"
TITLE='SCALABLE TESTS (iron law, BH-7563'
PLANL='PLAN must list, per vendor the code touches: the seam, the fake and the contract test.'
REVL='REVIEW tags each of these, when this diff adds it, `[BLOCK scalable-tests]`'
C1='a new PR-path test that calls a real vendor'
C2='a vendor client imported outside its seam'
C3='a test sign-in through the real provider outside the contract suite'
C4='a test-only route without the production-404 test'
C5='tests that share data or depend on order'
# The whole REVIEW line: C1-C5 alone also match the review-levels class list.
REVFULL="$REVL: $C1; $C2; $C3; $C4; $C5."
MEMBERS="preplan plan execute fix review qa prodqa lead-review"

# s1_check <laws-dir> — prints one line per stage that is wrong.
s1_check() {
  local d="$1" st got c
  for st in $MEMBERS; do
    got=$(sil_text "$st" "$d")
    for c in "$TITLE" "$PLANL" "$REVFULL"; do
      grep -qF -- "$c" <<<"$got" || { echo "$st lacks '$c'"; break; }
    done
  done
  for st in triage prd mockup preplan-files pre ""; do
    got=$(sil_text "$st" "$d")
    grep -qF -- "$TITLE" <<<"$got" && echo "non-member '$st' carries the law"
  done
  return 0
}

# ── S1 ─────────────────────────────────────────────────────────────────────
echo "--- S1"
[ -f "$FRAG" ] && ok || bad "S1 $FRAG missing"
[ "$(head -1 "$FRAG" 2>/dev/null)" = "stages: $MEMBERS" ] && ok || bad "S1 stages line: '$(head -1 "$FRAG" 2>/dev/null)'"
grep -q $'[\t\r]' "$FRAG" 2>/dev/null && bad "S1 the fragment has a tab or CR" || ok
out=$(s1_check "$LAWS_DIR")
[ -z "$out" ] && ok || bad "S1 decision table: $out"

# ── S2 driven agent-call.sh ────────────────────────────────────────────────
echo "--- S2"
# The scratch harness and fakes of tests/stage-iron-laws.bh-6557-test.sh.
mrs_fixture "$T" sample-project
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env" "$T/wt" "$T/builds/b1"
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
printf '{"type":"result","result":"ok","num_turns":1,"usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'
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
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "S2 setup: lanes-build.sh could not compose the registry"
mkdir -p "$T/prompts"; cp -R "$LAWS_DIR" "$T/prompts/"

OUTF="$T/builds/b1/out.txt"
run_call() {
  local st="$1"
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
        bash "$DIR/bin/agent-call.sh" "$st" sample-project claude-opus-5-5 600 "$OUTF" "hello" >/dev/null 2>&1 )
  echo $?
}
appends()    { local n; n=$(grep -c '^<<END>>$' "$T/sink.append.1" 2>/dev/null) || true; echo "${n:-0}"; }
append_has() { grep -qF -- "$1" "$T/sink.append.1" 2>/dev/null; }

for st in plan preplan; do
  RC=$(run_call "$st")
  [ -s "$T/sink" ] || { bad "S2 $st: claude never ran (rc=$RC)"; continue; }
  [ "$(appends)" = 1 ] && ok || bad "S2 $st: want one --append-system-prompt, got $(appends)"
  append_has "$TITLE" && ok || bad "S2 $st: the SCALABLE TESTS title is not in --append-system-prompt"
  append_has "$PLANL" && ok || bad "S2 $st: the PLAN line is not in --append-system-prompt"
done
for st in review lead-review; do
  RC=$(run_call "$st")
  [ -s "$T/sink" ] || { bad "S2 $st: claude never ran (rc=$RC)"; continue; }
  [ "$(appends)" = 1 ] && ok || bad "S2 $st: want one --append-system-prompt, got $(appends)"
  for c in "$C1" "$C2" "$C3" "$C4" "$C5" "$REVFULL"; do
    append_has "$c" && ok || bad "S2 $st: '$c' is not in --append-system-prompt"
  done
done
RC=$(run_call triage)
[ -s "$T/sink" ] || bad "S2 triage: claude never ran (rc=$RC)"
append_has 'SCALABLE TESTS' && bad "S2 triage: a non-member stage got the law" || ok

# ── S3 fleet rules ─────────────────────────────────────────────────────────
echo "--- S3"
if [ -f "$TOPIC" ]; then
  [ "$(head -1 "$TOPIC")" = '## Scalable tests (BH-7563)' ] && [ -z "$(sed -n 2p "$TOPIC")" ] && ok \
    || bad "S3 topic heading: '$(head -1 "$TOPIC")'"
  cmp -s <(tail -n +3 "$TOPIC") <(tail -n +3 "$FRAG" 2>/dev/null) && ok || bad "S3 topic body differs from the fragment body"
else
  bad "S3 $TOPIC missing"
fi
grep -qF -- "$PLANL" "$DIR/rules/CLAUDE.md" && ok || bad "S3 rules/CLAUDE.md lacks the PLAN line"
grep -qF -- "$REVFULL" "$DIR/rules/CLAUDE.md" && ok || bad "S3 rules/CLAUDE.md lacks the REVIEW line"
out=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-rules.sh" --root "$DIR" --check 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "S3 render-rules --check rc $rc: $(head -3 <<<"$out")"

# ── S4 the class stands ────────────────────────────────────────────────────
echo "--- S4"
L1='- [BLOCK scalable-tests] e2e/login.spec.ts:4: signs in through Clerk'
L2='1. **[BLOCK: scalable-tests]** a PR-path test calls a real vendor'
L3='- [HIGH] vendor client imported outside its seam in src/x.ts'
N1='- [BLOCK scalable-test] e2e/login.spec.ts:4: signs in through Clerk'
N2='- [BLOCK] the contract suite calls a real vendor on main'
N3='- [BLOCK] the seam file has 2 px padding'
# s4_stands <harness-root> <line> — rc of rl_line_blocks in a fresh shell.
s4_stands() {
  HARNESS="$1" bash -c 'unset REVIEW_LEVEL_MODE; . "$0/bin/lib/review-level.sh" || exit 9; rl_line_blocks "$1"' "$1" "$2"
}
for l in "$L1" "$L2" "$L3"; do
  s4_stands "$DIR" "$l"; rc=$?
  [ "$rc" = 0 ] && ok || bad "S4 must stand (rc $rc): $l"
done
for l in "$N1" "$N2" "$N3"; do
  s4_stands "$DIR" "$l"; rc=$?
  [ "$rc" = 1 ] && ok || bad "S4 must not stand (rc $rc): $l"
done
# The red-build line puts the class grammar in use, so L1 stands only through
# its own class (without the row it is an unclassed BLOCK and demotes).
printf '## Review — TK-901\nFindings:\n%s\n- [BLOCK red-build] src/a.ts:3: typecheck fails on the new import.\n- [BLOCK] src/card.tsx:12: card padding is 14 px, the prototype has 16 px.\nTIER: 2\nVERDICT: BLOCK\n' "$L1" > "$T/s4.md"
out=$(HARNESS="$DIR" bash -c 'unset REVIEW_LEVEL_MODE; . "$0/bin/lib/review-level.sh" || exit 9; rl_cap "$1" project-6-os --approve APPROVE --block BLOCK --lens inbuild 2>/dev/null' "$DIR" "$T/s4.md"); rc=$?
[ "$rc" = 0 ] && ok || bad "S4 rl_cap rc $rc: $out"
grep -q 'mode=levels demoted=1 standing=2 verdict=BLOCK' <<<"$out" && ok || bad "S4 rl_cap summary: $out"
grep -qF -- "$L1" "$T/s4.md" && ok || bad "S4 the scalable-tests finding was rewritten"
grep -q 'NOTE demoted from BLOCK.*14 px' "$T/s4.md" && ok || bad "S4 the 2 px finding was not demoted"
[ "$(sed -n '$p' "$T/s4.md")" = 'VERDICT: BLOCK' ] && ok || bad "S4 last line: $(sed -n '$p' "$T/s4.md")"

# ── S5 class lists agree with the catalog ──────────────────────────────────
echo "--- S5"
classes=$(grep -v '^#' "$DIR/catalog/review-always-block.tsv" | awk -F'\t' 'NF{print $1}')
grep -qx 'scalable-tests' <<<"$classes" && ok || bad "S5 catalog has no scalable-tests row"
# TEST-CHANGE (BH-7970): the general review lens text (the class list) moved from bin/lib/rb/review.sh to prompts/stages/review.md.
for f in bin/review-prs.sh prompts/stages/review.md prompts/lead-review.md \
         rules/topics/13-review-levels.md prompts/iron-laws.d/20261016-review-levels.md; do
  for c in $classes; do
    grep -qE -- "(^|[^a-z-])\`?$c\`?([^a-z-]|$)" "$DIR/$f" && ok || bad "S5 $f does not name class '$c'"
  done
done
cmp -s <(tail -n +3 "$DIR/rules/topics/13-review-levels.md") <(tail -n +3 "$LAWS_DIR/20261016-review-levels.md") && ok \
  || bad "S5 topic 13 body differs from the 20261016 fragment body"

# ── S6 root CLAUDE.md ──────────────────────────────────────────────────────
echo "--- S6"
grep -qF -- "$TITLE" "$DIR/CLAUDE.md" && ok || bad "S6 root CLAUDE.md lacks the title"
grep -qF -- "$PLANL" "$DIR/CLAUDE.md" && ok || bad "S6 root CLAUDE.md lacks the PLAN line"
first=$(awk '/^```/{f++; next} f==1{print; exit}' "$DIR/CLAUDE.md")
case "$first" in "HARNESS_TEST_SANDBOX=1 bin/verification-map-build.sh --check"*) ok ;;
  *) bad "S6 the first fenced block is not the verification contract: '${first:0:60}'" ;; esac

# ── S7 mutation ────────────────────────────────────────────────────────────
echo "--- S7"
M="$T/mut"; mkdir -p "$M"
scratch_install_closure bin/lib/review-level.sh "$M" >/dev/null || bad "S7 closure install of bin/lib/review-level.sh"
cp -R "$DIR/prompts" "$DIR/catalog" "$M/"
if [ -f "$M/prompts/iron-laws.d/20261019-scalable-tests.md" ]; then
  grep -vF -- "$PLANL" "$FRAG" > "$M/prompts/iron-laws.d/20261019-scalable-tests.md"
  out=$(s1_check "$M/prompts/iron-laws.d")
  [ -n "$out" ] && ! grep -qv "lacks '$PLANL'" <<<"$out" && ok || bad "S7 the cut PLAN line must be the only S1 failure: '$out'"
else
  bad "S7 no fragment to mutate"
fi
grep -v '^scalable-tests	' "$DIR/catalog/review-always-block.tsv" > "$M/catalog/review-always-block.tsv"
s4_stands "$DIR" "$L1"; rc_real=$?
s4_stands "$M" "$L1"; rc_mut=$?
[ "$rc_real" = 0 ] && [ "$rc_mut" = 1 ] && ok || bad "S7 with the row cut, L1 must stop standing (real rc $rc_real, mutant rc $rc_mut)"

echo "iron-law-scalable-tests: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
