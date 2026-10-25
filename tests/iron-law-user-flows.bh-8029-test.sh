#!/bin/bash
# tests/iron-law-user-flows.bh-8029-test.sh — BH-8029: the User Flows iron law
# reaches PLAN, EXECUTE and REVIEW through the BH-6557 law-set fragment, the
# fleet rules render, the ALWAYS-BLOCK catalog and the lead checklist, so a
# user-facing feature a user cannot reach from an existing entry point stands
# as [BLOCK user-flows] under REVIEW LEVELS.
#
#   U1  sil_text decision table: preplan plan execute fix review qa prodqa
#       lead-review carry the title, the PLAN line and the REVIEW line;
#       triage prd mockup preplan-files pre and "" carry none. Driven
#       bin/agent-call.sh with a fake claude: plan and lead-review get the
#       law in --append-system-prompt; triage does not
#   U2  rules/topics/15-user-flows.md body == the fragment body; the render
#       carries the title, the PLAN line and the REVIEW line; render-rules
#       --check clean
#   U3  rl_line_blocks stands / demotes table for the new class
#   U4  rl_cap in levels mode keeps the user-flows line, demotes a 2 px line,
#       VERDICT: BLOCK; user-flows is in the five ALWAYS-BLOCK class lists
#   U5  lead checklist: version >= 10, the [BLOCK user-flows] item, the
#       `## Entry points` pointer, a BH-8029 Changes line; prompts/lead-review.md
#       names user-flows
#   U6  mutation: cut the PLAN line and the catalog row in a copy; U1 names
#       exactly the fragment and U3's first STAND line no longer stands
# Run: HARNESS_TEST_SANDBOX=1 bash tests/iron-law-user-flows.bh-8029-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/bin/lib/stage-iron-laws.sh" || { echo "FAIL: bin/lib/stage-iron-laws.sh missing"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LAWS_DIR="$DIR/prompts/iron-laws.d"
FRAG="$LAWS_DIR/20261022-user-flows.md"
TOPIC="$DIR/rules/topics/15-user-flows.md"
CHECKLIST="$DIR/prompts/lead-review-checklist.md"
TITLE='USER FLOWS (iron law, BH-8029'
PLANL='PLAN must carry a `## Entry points` section: one line per entry point (touched, or "no change, because ..."), or the single line "no user-facing entry point".'
REVL='REVIEW checks the plan'"'"'s entry points against the diff. A user-facing feature that a user cannot reach from an existing entry point is `[BLOCK user-flows]`.'
MEMBERS="preplan plan execute fix review qa prodqa lead-review"

# u1_check <laws-dir> — prints one line per stage that is wrong.
u1_check() {
  local d="$1" st got c
  for st in $MEMBERS; do
    got=$(sil_text "$st" "$d")
    for c in "$TITLE" "$PLANL" "$REVL"; do
      grep -qF -- "$c" <<<"$got" || { echo "$st lacks '$c'"; break; }
    done
  done
  for st in triage prd mockup preplan-files pre ""; do
    got=$(sil_text "$st" "$d")
    grep -qF -- "$TITLE" <<<"$got" && echo "non-member '$st' carries the law"
  done
  return 0
}

# ── U1 ─────────────────────────────────────────────────────────────────────
echo "--- U1"
[ -f "$FRAG" ] && ok || bad "U1 $FRAG missing"
[ "$(head -1 "$FRAG" 2>/dev/null)" = "stages: $MEMBERS" ] && ok || bad "U1 stages line: '$(head -1 "$FRAG" 2>/dev/null)'"
grep -q $'[\t\r]' "$FRAG" 2>/dev/null && bad "U1 the fragment has a tab or CR" || ok
out=$(u1_check "$LAWS_DIR")
[ -z "$out" ] && ok || bad "U1 decision table: $out"

# Driven: the production entry point, bin/agent-call.sh, with a fake claude.
# Same scratch harness and fakes as tests/iron-law-scalable-tests.bh-7563-test.sh.
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
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "U1 setup: lanes-build.sh could not compose the registry"
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
append_has() { grep -qF -- "$1" "$T/sink.append.1" 2>/dev/null; }

for st in plan lead-review; do
  RC=$(run_call "$st")
  [ -s "$T/sink" ] || { bad "U1 $st: claude never ran (rc=$RC)"; continue; }
  for c in "$TITLE" "$PLANL" "$REVL"; do
    append_has "$c" && ok || bad "U1 $st: '$c' is not in --append-system-prompt"
  done
done
RC=$(run_call triage)
[ -s "$T/sink" ] || bad "U1 triage: claude never ran (rc=$RC)"
append_has 'USER FLOWS' && bad "U1 triage: a non-member stage got the law" || ok

# ── U2 fleet rules ─────────────────────────────────────────────────────────
echo "--- U2"
if [ -f "$TOPIC" ]; then
  [ "$(head -1 "$TOPIC")" = '## User flows (BH-8029)' ] && [ -z "$(sed -n 2p "$TOPIC")" ] && ok \
    || bad "U2 topic heading: '$(head -1 "$TOPIC")'"
  cmp -s <(tail -n +3 "$TOPIC") <(tail -n +3 "$FRAG" 2>/dev/null) && ok || bad "U2 topic body differs from the fragment body"
else
  bad "U2 $TOPIC missing"
fi
for c in "$TITLE" "$PLANL" "$REVL"; do
  grep -qF -- "$c" "$DIR/rules/CLAUDE.md" && ok || bad "U2 rules/CLAUDE.md lacks '$c'"
done
out=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-rules.sh" --root "$DIR" --check 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "U2 render-rules --check rc $rc: $(head -3 <<<"$out")"

# ── U3 the class stands ────────────────────────────────────────────────────
echo "--- U3"
S1='[BLOCK user-flows] the new Reports screen has no nav item; a user cannot reach it from any existing screen'
S2='- [BLOCK] Workflow step "Send SMS" is only reachable through its new route /steps/sms'
S3='**[BLOCK user-flows]** console-ui/src/app.js: no picker entry for the new step'
S4='- [HIGH] users cannot reach the feature from an existing menu'
N1='- [BLOCK] no user-facing entry point; harness-only change'
N2="- [BLOCK] the plan's ## Entry points section lists nav and picker"
N3='- [BLOCK] user flow copy: the button label says Save'
N4='- [BLOCK] missing "no change, because" line for the assistant'
N5='- [BLOCK] the entry-point test is missing'
N6='- [BLOCK user-flow] the button label says Save'
# u3_stands <harness-root> <line> — rc of rl_line_blocks in a fresh shell.
u3_stands() {
  HARNESS="$1" bash -c 'unset REVIEW_LEVEL_MODE; . "$0/bin/lib/review-level.sh" || exit 9; rl_line_blocks "$1"' "$1" "$2"
}
for l in "$S1" "$S2" "$S3" "$S4"; do
  u3_stands "$DIR" "$l"; rc=$?
  [ "$rc" = 0 ] && ok || bad "U3 must stand (rc $rc): $l"
done
for l in "$N1" "$N2" "$N3" "$N4" "$N5" "$N6"; do
  u3_stands "$DIR" "$l"; rc=$?
  [ "$rc" = 1 ] && ok || bad "U3 must not stand (rc $rc): $l"
done

# ── U4 rl_cap and the class lists ──────────────────────────────────────────
echo "--- U4"
printf '## Review — BH-9001\nFindings:\n- %s\n- [BLOCK] src/card.tsx:12: card padding is 14 px, the prototype has 16 px.\nTIER: 2\nVERDICT: BLOCK\n' "$S1" > "$T/u4.md"
cp "$T/u4.md" "$T/u4.md.orig"
out=$(HARNESS="$DIR" bash -c 'unset REVIEW_LEVEL_MODE; . "$0/bin/lib/review-level.sh" || exit 9; rl_cap "$1" cromford --approve MERGE --block BLOCK --lens lead 2>/dev/null' "$DIR" "$T/u4.md"); rc=$?
[ "$rc" = 0 ] && ok || bad "U4 rl_cap rc $rc: $out"
# untagged=0: the line stands through its class. Without the row it stands
# only as an untagged BLOCK (no class grammar in use), untagged=1.
grep -q 'mode=levels demoted=1 standing=1 verdict=BLOCK untagged=0' <<<"$out" && ok || bad "U4 rl_cap summary: $out"
grep -qF -- "- $S1" "$T/u4.md" && ok || bad "U4 the user-flows finding was rewritten"
grep -q 'NOTE demoted from BLOCK.*14 px' "$T/u4.md" && ok || bad "U4 the 2 px finding was not demoted"
[ "$(sed -n '$p' "$T/u4.md")" = 'VERDICT: BLOCK' ] && ok || bad "U4 last line: $(sed -n '$p' "$T/u4.md")"
grep -qx 'user-flows' <(grep -v '^#' "$DIR/catalog/review-always-block.tsv" | awk -F'\t' 'NF{print $1}') && ok \
  || bad "U4 catalog has no user-flows row"
# TEST-CHANGE (BH-7970): the general review lens text (the class list) moved from bin/lib/rb/review.sh to prompts/stages/review.md.
for f in bin/review-prs.sh prompts/stages/review.md prompts/lead-review.md \
         rules/topics/13-review-levels.md prompts/iron-laws.d/20261016-review-levels.md; do
  grep -qE -- '(^|[^a-z-])`?user-flows`?([^a-z-]|$)' "$DIR/$f" && ok || bad "U4 $f does not name class 'user-flows'"
done

# ── U5 lead checklist ──────────────────────────────────────────────────────
echo "--- U5"
v=$(head -1 "$CHECKLIST" | sed -n 's/^Checklist-Version: \([0-9][0-9]*\)$/\1/p')
[ -n "$v" ] && [ "$v" -ge 10 ] && ok || bad "U5 checklist version must be >= 10: '$(head -1 "$CHECKLIST")'"
items=$(sed '/^## Changes/,$d' "$CHECKLIST")
grep -qF '[BLOCK user-flows]' <<<"$items" && ok || bad "U5 no [BLOCK user-flows] checklist item"
grep -qF '`## Entry points`' <<<"$items" && ok || bad "U5 the item does not point at the plan's ## Entry points"
grep -qF 'no user-facing entry point' <<<"$items" && ok || bad "U5 the item does not pass the harness-only exemption"
sed -n '/^## Changes/,$p' "$CHECKLIST" | grep -q 'BH-8029' && ok || bad "U5 ## Changes has no BH-8029 line"
grep -q 'user-flows' "$DIR/prompts/lead-review.md" && ok || bad "U5 prompts/lead-review.md does not name user-flows"

# ── U6 mutation ────────────────────────────────────────────────────────────
echo "--- U6"
M="$T/mut"; mkdir -p "$M"
scratch_install_closure bin/lib/review-level.sh "$M" >/dev/null || bad "U6 closure install of bin/lib/review-level.sh"
cp -R "$DIR/prompts" "$DIR/catalog" "$M/"
if [ -f "$M/prompts/iron-laws.d/20261022-user-flows.md" ]; then
  grep -vF -- "$PLANL" "$FRAG" > "$M/prompts/iron-laws.d/20261022-user-flows.md"
  out=$(u1_check "$M/prompts/iron-laws.d")
  [ -n "$out" ] && ! grep -qv "lacks '$PLANL'" <<<"$out" && ok || bad "U6 the cut PLAN line must be the only U1 failure: '$out'"
else
  bad "U6 no fragment to mutate"
fi
grep -v '^user-flows	' "$DIR/catalog/review-always-block.tsv" > "$M/catalog/review-always-block.tsv"
u3_stands "$DIR" "$S1"; rc_real=$?
u3_stands "$M" "$S1"; rc_mut=$?
[ "$rc_real" = 0 ] && [ "$rc_mut" = 1 ] && ok || bad "U6 with the row cut, S1 must stop standing (real rc $rc_real, mutant rc $rc_mut)"
cp "$T/u4.md.orig" "$T/u4m.md"
out=$(HARNESS="$M" bash -c 'unset REVIEW_LEVEL_MODE; . "$0/bin/lib/review-level.sh" || exit 9; rl_cap "$1" cromford --approve MERGE --block BLOCK --lens lead 2>/dev/null' "$M" "$T/u4m.md")
grep -q 'untagged=1' <<<"$out" && ok || bad "U6 with the row cut, U4's rl_cap must count S1 as untagged: $out"

echo "iron-law-user-flows: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
