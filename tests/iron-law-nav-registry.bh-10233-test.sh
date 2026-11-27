#!/bin/bash
# tests/iron-law-nav-registry.bh-10233-test.sh — BH-10233: the Navigation
# Registry iron law reaches PLAN, EXECUTE and REVIEW through the BH-6557
# law-set fragment and the fleet rules render, and the lead checklist flags a
# new hard-coded page address, a page move by search-and-replace and a menu
# label that differs from its page heading.
#
#   N1  sil_text decision table: plan execute review lead-review carry the
#       title, the key sentence and the REVIEW line; preplan fix triage prd
#       mockup preplan-files pre qa "" carry none (preplan and fix are left
#       out to keep tests/stage-iron-laws.bh-6557-test.sh A7 under its 5%
#       token budget). Fragment line 1 is the stages line; no tab or CR
#   N2  driven bin/agent-call.sh with a fake claude: plan and lead-review get
#       the key sentence in --append-system-prompt; triage does not
#   N3  rules/topics/20-navigation-registry.md heading + body == fragment
#       body; rules/CLAUDE.md carries the key sentence and a Contents line;
#       render-rules --check clean
#   N4  lead checklist: version >= 12, item 18 names the three flags, a
#       BH-10233 Changes line
#   N5  _cv_checklist inlines the items (item 18), not the CHECKLIST: line
#   N6  mutation: cut the key sentence in a copy of the fragment, N1 names
#       exactly "lacks <key>" for every member; cut item 18 in a copy of the
#       checklist, N4 fails
# Run: HARNESS_TEST_SANDBOX=1 bash tests/iron-law-nav-registry.bh-10233-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/bin/lib/stage-iron-laws.sh" || { echo "FAIL: bin/lib/stage-iron-laws.sh missing"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LAWS_DIR="$DIR/prompts/iron-laws.d"
FRAG="$LAWS_DIR/20261126-navigation-registry.md"
TOPIC="$DIR/rules/topics/20-navigation-registry.md"
CHECKLIST="$DIR/prompts/lead-review-checklist.md"
TITLE='NAVIGATION REGISTRY (iron law, BH-10233'
KEY="Each page is listed once in the project's page registry: id, route, label (= page heading), section, parent, access roles, old routes."
REVL='REVIEW, each a `[NOTE]`: a new hard-coded page address in the diff; a page move done by search-and-replace across files instead of one registry row; a menu label that differs from its page heading; a second navigation list.'
MEMBERS="plan execute review lead-review"

# n1_check <laws-dir> — prints one line per stage that is wrong.
n1_check() {
  local d="$1" st got c
  for st in $MEMBERS; do
    got=$(sil_text "$st" "$d")
    for c in "$TITLE" "$KEY" "$REVL"; do
      grep -qF -- "$c" <<<"$got" || { echo "$st lacks '$c'"; break; }
    done
  done
  for st in preplan fix triage prd mockup preplan-files pre qa ""; do
    got=$(sil_text "$st" "$d")
    grep -qF -- "$TITLE" <<<"$got" && echo "non-member '$st' carries the law"
  done
  return 0
}

# n4_check <checklist> — prints one line per missing checklist part.
n4_check() {
  local f="$1" v items
  v=$(head -1 "$f" | sed -n 's/^Checklist-Version: \([0-9][0-9]*\)$/\1/p')
  { [ -n "$v" ] && [ "$v" -ge 12 ]; } || echo "version must be >= 12: '$(head -1 "$f")'"
  items=$(awk '/^## Changes/{exit} /^1\. /{f=1} f' "$f")
  item18=$(awk '/^18\. Navigation registry \(BH-10233\)/{f=1; print; next} f && /^[0-9]+\. |^$/{exit} f' <<<"$items")
  if [ -z "$item18" ]; then
    echo "no item '18. Navigation registry (BH-10233)'"
  else
    for c in 'hard-coded page address' 'search-and-replace' 'page heading'; do
      tr '\n' ' ' <<<"$item18" | tr -s ' ' | grep -qF -- "$c" || echo "item 18 lacks '$c'"
    done
  fi
  sed -n '/^## Changes/,$p' "$f" | grep -q 'BH-10233' || echo "## Changes has no BH-10233 line"
  return 0
}

# ── N1 ─────────────────────────────────────────────────────────────────────
echo "--- N1"
[ -f "$FRAG" ] && ok || bad "N1 $FRAG missing"
[ "$(head -1 "$FRAG" 2>/dev/null)" = "stages: $MEMBERS" ] && ok || bad "N1 stages line: '$(head -1 "$FRAG" 2>/dev/null)'"
[ -z "$(sed -n 2p "$FRAG" 2>/dev/null)" ] && ok || bad "N1 fragment line 2 is not empty"
grep -q $'[\t\r]' "$FRAG" 2>/dev/null && bad "N1 the fragment has a tab or CR" || ok
out=$(n1_check "$LAWS_DIR")
[ -z "$out" ] && ok || bad "N1 decision table: $out"

# ── N2 driven: bin/agent-call.sh with a fake claude (BH-8029 U1 fixture) ──
echo "--- N2"
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
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "N2 setup: lanes-build.sh could not compose the registry"
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
  [ -s "$T/sink" ] || { bad "N2 $st: claude never ran (rc=$RC)"; continue; }
  for c in "$TITLE" "$KEY"; do
    append_has "$c" && ok || bad "N2 $st: '$c' is not in --append-system-prompt"
  done
done
RC=$(run_call triage)
[ -s "$T/sink" ] || bad "N2 triage: claude never ran (rc=$RC)"
append_has 'NAVIGATION REGISTRY' && bad "N2 triage: a non-member stage got the law" || ok

# ── N3 fleet rules ─────────────────────────────────────────────────────────
echo "--- N3"
if [ -f "$TOPIC" ]; then
  [ "$(head -1 "$TOPIC")" = '## Navigation registry (BH-10233)' ] && [ -z "$(sed -n 2p "$TOPIC")" ] && ok \
    || bad "N3 topic heading: '$(head -1 "$TOPIC")'"
  cmp -s <(tail -n +3 "$TOPIC") <(tail -n +3 "$FRAG" 2>/dev/null) && ok || bad "N3 topic body differs from the fragment body"
else
  bad "N3 $TOPIC missing"
fi
for c in "$TITLE" "$KEY" "$REVL"; do
  grep -qF -- "$c" "$DIR/rules/CLAUDE.md" && ok || bad "N3 rules/CLAUDE.md lacks '$c'"
done
grep -qF -- '[Navigation registry (BH-10233)]' "$DIR/rules/CLAUDE.md" && ok || bad "N3 rules/CLAUDE.md Contents has no Navigation registry line"
out=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-rules.sh" --root "$DIR" --check 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "N3 render-rules --check rc $rc: $(head -3 <<<"$out")"

# ── N4 lead checklist ──────────────────────────────────────────────────────
echo "--- N4"
out=$(n4_check "$CHECKLIST")
[ -z "$out" ] && ok || bad "N4 checklist: $out"

# ── N5 the checklist is inlined in the coverage note ───────────────────────
echo "--- N5"
out=$(HARNESS="$DIR" bash -c '. "$0/bin/lib/coverage-review.sh" || exit 9; CV_CHECKLIST_MAX=$CV_DEFAULT_CHECKLIST_MAX_BYTES; _cv_checklist' "$DIR" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && ok || bad "N5 _cv_checklist rc $rc"
grep -q '^18\. Navigation registry' <<<"$out" && ok || bad "N5 item 18 is not inlined: $(head -3 <<<"$out")"
grep -q '^CHECKLIST: read' <<<"$out" && bad "N5 the items are over the inline cap" || ok

# ── N6 mutation ────────────────────────────────────────────────────────────
echo "--- N6"
M="$T/mut"; mkdir -p "$M"
cp -R "$LAWS_DIR" "$M/"
if [ -f "$FRAG" ]; then
  grep -vF -- "$KEY" "$FRAG" > "$M/iron-laws.d/20261126-navigation-registry.md"
  grep -qF -- "$KEY" "$M/iron-laws.d/20261126-navigation-registry.md" && bad "N6 the key sentence was not cut"
  out=$(n1_check "$M/iron-laws.d")
  n=$(grep -c . <<<"$out")
  [ "$n" = 4 ] && ! grep -qv "lacks '$KEY'" <<<"$out" && ok || bad "N6 the cut key sentence must be the only N1 failure, once per member: '$out'"
else
  bad "N6 no fragment to mutate"
fi
awk '/^18\. /{skip=1; next} skip && /^($|[0-9]+\. )/{skip=0} !skip' "$CHECKLIST" > "$M/checklist.md"
out=$(n4_check "$M/checklist.md")
grep -q "no item '18. Navigation registry" <<<"$out" && ok || bad "N6 with item 18 cut, N4 must fail: '$out'"

echo "iron-law-nav-registry: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
