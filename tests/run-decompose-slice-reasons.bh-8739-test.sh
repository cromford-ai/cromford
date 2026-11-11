#!/bin/bash
# tests/run-decompose-slice-reasons.bh-8739-test.sh — BH-8739 through the real
# bin/run-decompose.sh (the production entry point the size gate calls).
#
#   D1  12 small screens, nothing shared -> rc 4 DECOMPOSE_NOT_NEEDED, 0 issues
#   D2  two screens share a file -> 2 children, each body opens `Slice reason:`
#   D3  the size gate expects 6 slices, empty thread -> 1 proposal comment,
#       1 needs-human hold, 0 children, rc 3 DECOMPOSE_HELD: awaiting a reply
#   D4  the proposal and its hold are on the thread -> rc 3, 0 comments, 0 children
#   D5  a person's HUMAN-STEP-DONE over the marker -> rc 0, the children file
#   D6  SLICE_GATE=0 -> the spec files as written (no coalesce, no reason line)
#   D7  expected 5 and 5 children -> no proposal (the rule is "above 5")
#   D8  the thread cannot be read -> rc 3, nothing filed, nothing posted
#   D9  a proposal with no hold on the thread -> the hold is placed again, no
#       second comment
#   D10 some slices with est_lines and some without -> DECOMPOSE_FAILED
#   D11 board lane, waiting -> rc 3, no hold (holds are an issues-lane marker)
#   D12 not a dry run: the proposal is POSTed through gh, the hold script runs
#
# DECOMPOSE_DRY_RUN=1 prints every write; DECOMPOSE_THREAD_FILE is the thread
# seam. agent-call.sh and needs-human-hold.sh are stubs. No network, no model.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/run-decompose-slice-reasons.bh-8739-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-rest-fx.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "run-decompose-slice-reasons.bh-8739: jq is required"; exit 1; }

DEC="$DIR/bin/run-decompose.sh"
FIX="$DIR/tests/fixtures/slice-gate.bh-8739"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env" "$T/h/prompts" "$T/tmp"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" scoutish widget-os || exit 1
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish      example-org/scoutish   https://scoutish.example  -           9 box-1 192.0.2.9
widget-os     example-org/widget-os  https://widget.example    /api/board  2 box-1 192.0.2.2
CONF
cat > "$T/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENT CALL: $*" >> "$AGENT_LOG"
exit 0
SH
cat > "$T/h/bin/needs-human-hold.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$NH_LOG"
exit 0
SH
chmod +x "$T/h/bin/agent-call.sh" "$T/h/bin/needs-human-hold.sh"
export TMPDIR="$T/tmp"
unset SLICE_GATE SLICE_TOKENS_PER_LINE SLICE_CONFIRM_OVER SLICE_CEILING_TOKENS CONTEXT_BUDGETS

ISSUE='{"number":552,"state":"open","title":"parent","body":"the ask","labels":[{"name":"ai-build"}]}'
c() { # c <login> <type> <at> <body> — one REST comment
  jq -nc --arg l "$1" --arg t "$2" --arg a "$3" --arg b "$4" '{user:{login:$l, type:$t}, created_at:$a, body:$b}'
}
thread() { # thread <comment-json>... -> $T/thread.json (issues lane)
  jq -nc --argjson i "$ISSUE" --argjson c "$(printf '%s\n' "$@" | jq -s -c .)" '{issue:$i, comments:$c}' > "$T/thread.json"
}
drive() { # drive <spec-file> <expected-or-empty> [env...] — sets OUT RC
  local spec="$1" exp="$2"; shift 2
  rm -rf "$T/b"; mkdir -p "$T/b"
  cp "$spec" "$T/b/children.json"
  printf 'SIZE_DECLARED: files=30 lines=2000\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
  [ -n "$exp" ] && printf 'SIZE_SLICES_EXPECTED: %s\n' "$exp" >> "$T/b/size-gate.txt"
  : > "$T/agent.log"; : > "$T/nh.log"
  OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" NH_LOG="$T/nh.log" \
        DECOMPOSE_DRY_RUN=1 DECOMPOSE_THREAD_FILE="$T/thread.json" "$@" \
        "$DEC" "${PROJ:-scoutish}" "${TID:-552}" "${KEY:-TK-552}" "$T/b" 700 20 2>&1 ); RC=$?
}
creates() { grep -c '^DRYRUN gh issue create ' <<<"$OUT"; }
proposals() { grep -c 'decompose-proposal' <<<"$OUT"; }
nholds() { grep -c . "$T/nh.log" 2>/dev/null || echo 0; }
dryholds() { grep -c '^DRYRUN needs-human-hold.sh ' <<<"$OUT"; }

# --- D1 --------------------------------------------------------------------------
thread; drive "$FIX/twelve-screens.json" ""
[ "$RC" = 4 ] && ok || bad "D1: 12 small disjoint screens must be rc 4, got $RC: $OUT"
grep -q '^DECOMPOSE_NOT_NEEDED: no slice has a reason to stand alone (12 slices fit one build)' "$T/b/decompose-run.txt" \
  && ok || bad "D1: decompose-run.txt: $(cat "$T/b/decompose-run.txt" 2>/dev/null)"
[ "$(creates)" = 0 ] && ok || bad "D1: no issue may be created, got $(creates)"
[ -s "$T/b/children.txt" ] && bad "D1: children.txt must not exist" || ok
grep -q 'SLICE_GATE: 12 slices -> 1 children' "$T/b/pipeline.log" && ok || bad "D1: the gate line: $(cat "$T/b/pipeline.log")"
[ -s "$T/b/children.proposed.json" ] && [ "$(jq length "$T/b/children.proposed.json")" = 12 ] && ok || bad "D1: the model's spec is kept as children.proposed.json"

# --- D2 --------------------------------------------------------------------------
thread; drive "$FIX/twelve-screens-shared.json" ""
[ "$RC" = 0 ] && ok || bad "D2: a shared file must split, rc=$RC: $OUT"
[ "$(creates)" = 2 ] && ok || bad "D2: exactly 2 children, got $(creates)"
for n in 1 2; do
  [ "$(head -1 "$T/b/children/child-$n.md" 2>/dev/null)" = "$(jq -r ".[$((n - 1))].body | split(\"\n\")[0]" "$T/b/children.json")" ] \
    && grep -q '^Slice reason: ' "$T/b/children/child-$n.md" && ok || bad "D2: child $n body must open with its Slice reason: $(head -3 "$T/b/children/child-$n.md" 2>/dev/null)"
done
grep -q '^Slice reason: file-overlap: src/finance/shared.ts' "$T/b/children/child-2.md" && ok || bad "D2: child 2 names the shared file"
[ "$(proposals)" = 0 ] && ok || bad "D2: 2 children need no proposal"

# --- D3 --------------------------------------------------------------------------
thread; drive "$FIX/twelve-screens-shared.json" 6
[ "$RC" = 3 ] && ok || bad "D3: an estimate of 6 must hold, rc=$RC: $OUT"
[ "$(creates)" = 0 ] && ok || bad "D3: nothing filed, got $(creates)"
grep -q '^DRYRUN gh api -X POST repos/example-org/scoutish/issues/552/comments -F body=@' <<<"$OUT" && ok || bad "D3: one proposal POST printed: $OUT"
[ "$(head -1 "$T/b/decompose-proposal.md" 2>/dev/null)" = "<!-- decompose-proposal: TK-552 -->" ] && ok || bad "D3: the proposal body carries the marker"
[ "$(dryholds)" = 1 ] && ok || bad "D3: one hold printed, got $(dryholds)"
grep -q '^DECOMPOSE_HELD: awaiting a reply to the proposed split into 6 children' "$T/b/decompose-run.txt" && ok \
  || bad "D3: decompose-run.txt: $(cat "$T/b/decompose-run.txt" 2>/dev/null)"
PROPOSAL=$(cat "$T/b/decompose-proposal.md" 2>/dev/null)

# --- D4 --------------------------------------------------------------------------
NH=$(c harness-app[bot] Bot 2026-10-28T10:00:05Z "NEEDS-HUMAN: confirm the proposed split of TK-552 into 6 tickets (see the proposal comment)
<!-- nh-fp:0123456789ab -->")
thread "$(c harness-app[bot] Bot 2026-10-28T10:00:00Z "$PROPOSAL")" "$NH"
drive "$FIX/twelve-screens-shared.json" 6
[ "$RC" = 3 ] && ok || bad "D4: waiting must be rc 3, got $RC"
[ "$(creates)" = 0 ] && ok || bad "D4: nothing filed while waiting"
grep -q 'issues/552/comments' <<<"$OUT" && bad "D4: no second comment while waiting: $OUT" || ok
[ "$(dryholds)" = 0 ] && ok || bad "D4: no second hold while one is on the thread"

# --- D5 --------------------------------------------------------------------------
thread "$(c harness-app[bot] Bot 2026-10-28T10:00:00Z "$PROPOSAL")" "$NH" "$(c operator User 2026-10-28T11:00:00Z 'HUMAN-STEP-DONE: split it like that')"
drive "$FIX/twelve-screens-shared.json" 6
[ "$RC" = 0 ] && ok || bad "D5: a confirmed split must file, rc=$RC: $OUT"
[ "$(creates)" = 2 ] && ok || bad "D5: the 2 merged children file, got $(creates)"
grep -q 'SLICE_GATE: the proposed split' "$T/b/pipeline.log" && ok || bad "D5: the log says it was confirmed"

# --- D6 --------------------------------------------------------------------------
thread; drive "$FIX/twelve-screens-shared.json" "" SLICE_GATE=0
# 12 children is past the old 2-5 contract: refused as before, nothing coalesced.
[ "$RC" = 1 ] && ok || bad "D6: SLICE_GATE=0 keeps the old 2-5 refusal, rc=$RC"
grep -q 'a split is 2-5 children, the spec has 12' "$T/b/decompose-run.txt" && ok || bad "D6: $(cat "$T/b/decompose-run.txt")"
[ -e "$T/b/children.proposed.json" ] && bad "D6: no proposed copy when the gate is off" || ok
jq -e 'length == 12' "$T/b/children.json" >/dev/null && ok || bad "D6: children.json is left as written"

# --- D7 --------------------------------------------------------------------------
jq -n '[range(1;6) as $i | {title:"part \($i)", owns:["src/p\($i).ts"], after:[], est_lines:700,
  body:"Part \($i).\n\n## Observable outcome\nPart \($i) works."} | if .title == "part 1" then . + {contract:"src/p1.ts: P1"} else . end]' > "$T/five.json"
thread; drive "$T/five.json" 5
[ "$RC" = 0 ] && ok || bad "D7: 5 and 5 is not above 5, rc=$RC: $OUT"
[ "$(creates)" = 5 ] && ok || bad "D7: 5 children, got $(creates)"
[ "$(proposals)" = 0 ] && ok || bad "D7: no proposal at exactly 5"

# --- D8 --------------------------------------------------------------------------
printf 'not json' > "$T/thread.json"; drive "$FIX/twelve-screens-shared.json" 6
[ "$RC" = 3 ] && ok || bad "D8: an unreadable thread must hold, rc=$RC"
grep -q '^DECOMPOSE_HELD: .*thread unreadable' "$T/b/decompose-run.txt" && ok || bad "D8: $(cat "$T/b/decompose-run.txt")"
[ "$(creates)" = 0 ] && [ "$(proposals)" = 0 ] && ok || bad "D8: nothing filed or posted blind"

# --- D9 --------------------------------------------------------------------------
thread "$(c harness-app[bot] Bot 2026-10-28T10:00:00Z "$PROPOSAL")"
drive "$FIX/twelve-screens-shared.json" 6
[ "$RC" = 3 ] && ok || bad "D9: rc=$RC"
[ "$(dryholds)" = 1 ] && ok || bad "D9: the missing hold is placed again, got $(dryholds)"
grep -q 'issues/552/comments' <<<"$OUT" && bad "D9: no second proposal comment" || ok

# --- D10 -------------------------------------------------------------------------
jq '.[1] |= del(.est_lines)' "$FIX/twelve-screens.json" > "$T/partial.json"
thread; drive "$T/partial.json" ""
[ "$RC" = 1 ] && ok || bad "D10: partial est_lines must fail, rc=$RC"
grep -q 'every slice needs est_lines, or none' "$T/b/decompose-run.txt" && ok || bad "D10: $(cat "$T/b/decompose-run.txt")"

# --- D11 -------------------------------------------------------------------------
jq -nc --arg b "$PROPOSAL" '{id:"t-77", comments:[{author:"Harness", body:$b, createdAt:"2026-10-28T10:00:00Z"}]}' > "$T/thread.json"
PROJ=widget-os TID=t-77 KEY=WG-77 drive "$FIX/twelve-screens-shared.json" 6
[ "$RC" = 3 ] && ok || bad "D11: board lane, waiting -> rc 3, got $RC: $OUT"
[ "$(dryholds)" = 0 ] && ok || bad "D11: no needs-human hold on a board"
# the proposal on the board names this KEY, so the proposal above (TK-552) is not it
grep -q 'DRYRUN board comment on t-77' <<<"$OUT" && ok || bad "D11: a board with no proposal for WG-77 gets one: $OUT"

# --- D12: not a dry run ------------------------------------------------------------
ghfx_init
ghfx_extra <<'SH'
if [ "${1:-}" = api ] && [ "${3:-}" = -X ] && [ "${4:-}" = POST ]; then
  printf '%s\n' "$5" >> "$GHFX/posts.log"
  printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1,"html_url":"https://github.com/fixture/issues/552#issuecomment-1"}'
  exit 0
fi
SH
thread
rm -rf "$T/b"; mkdir -p "$T/b"; cp "$FIX/twelve-screens-shared.json" "$T/b/children.json"
printf 'SIZE_VERDICT: over\nSIZE_SLICES_EXPECTED: 6\n' > "$T/b/size-gate.txt"; : > "$T/nh.log"
OUT=$( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_LOG="$T/agent.log" NH_LOG="$T/nh.log" PATH="$T/fakebin:$PATH" GH_ETAG=0 \
      DECOMPOSE_THREAD_FILE="$T/thread.json" "$DEC" scoutish 552 TK-552 "$T/b" 700 20 2>&1 ); RC=$?
[ "$RC" = 3 ] && ok || bad "D12: rc=$RC: $OUT"
grep -qx 'repos/example-org/scoutish/issues/552/comments' "$T/posts.log" 2>/dev/null && ok || bad "D12: the proposal is POSTed to the parent: $(cat "$T/posts.log" 2>/dev/null)"
[ "$(nholds)" = 1 ] && grep -q '^scoutish 552 [0-9a-f]* confirm the proposed split of TK-552 into 6 tickets' "$T/nh.log" && grep -q ' decompose$' "$T/nh.log" \
  && ok || bad "D12: one hold placed: $(cat "$T/nh.log")"

# --- D13: the prompt the model gets (the plan's R5) ---------------------------------
printf '#!/bin/bash\nprintf "%%s" "$6" > "$AGENT_PROMPT"\nexit 0\n' > "$T/h/bin/agent-call.sh"
rm -rf "$T/b"; mkdir -p "$T/b"
env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" AGENT_PROMPT="$T/prompt.txt" DECOMPOSE_DRY_RUN=1 \
  "$DEC" scoutish 552 TK-552 "$T/b" 700 20 >/dev/null 2>&1
P=$(cat "$T/prompt.txt" 2>/dev/null)
for w in 'ONE OBJECT PER UNIT OF WORK' 'file overlap' 'build-execute context ceiling' 'real merge order' \
         'est_lines — REQUIRED on every object' '"est_lines": 60' 'one object per slice'; do
  grep -qF -- "$w" <<<"$P" && ok || bad "D13: the decompose prompt lacks '$w'"
done
grep -qF '2 to 5 objects' <<<"$P" && bad "D13: the prompt still caps the spec at 2 to 5 objects" || ok

echo "run-decompose-slice-reasons.bh-8739: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
