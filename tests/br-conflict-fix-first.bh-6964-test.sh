#!/bin/bash
# tests/br-conflict-fix-first.bh-6964-test.sh — BH-6964 (BH-6542.2): a
# conflicted merge gets agent fix rounds on its own branch before any rebuild,
# with a brief that can actually resolve it, and every round says how it went.
#
#   K1-K5  br_fix_cap (pure): BR_CONFLICT_FIX_ROUNDS sets the SMALL shape's cap
#          (default 2), wins over BR_MAX_FIXROUNDS_SMALL, and never reaches an
#          unmeasured, 0-line or >300-line conflict, a review park or a dequeue
#   K6     through the real script: BR_CONFLICT_FIX_ROUNDS=1 makes the first
#          failed round of a small conflict the terminal (rebuild-fresh)
#   F1     small conflict, round 1 resolves it: pushed, no rebuild, the ledger
#          row says fix-round-conflict ok lines=<n>
#   F2     small conflict, rounds 1 and 2 fail: two `failed` rows, then the
#          terminal (rebuild-fresh for a conflict park), origin untouched
#   F3     large conflict (500 lines), round 1 fails: rebuild after ONE round
#   F4     the prompt carries the rule, the markers, main's diff of the file
#          since the merge base, and the branch's .harness/specs/<KEY>/plan.md
#   F4b    no spec in the branch: the build record's plan.md; neither: "not found"
#   F4c    prompts/fix-round.d/conflict.md missing: the round still runs with
#          the fallback rule line, and the log names the missing file
#   F5     a ci-red park whose merge did not conflict: no fix-round-conflict text
#
# Drives the REAL script through `--fix-here`, the way bin/fix-round-claim.sh
# runs it, over the fx_br_ladder_git origin. On a box --fix-here stubs
# br_fix_terminal to `FIX_RESULT terminal`, and the hub's br_fix_terminal is
# br_rebuild_fresh for every conflict reason, so a conflict park's terminal is
# the rebuild; the ladder's own pure rung is checked on the returned record too.
# Run from anywhere: tests/br-conflict-fix-first.bh-6964-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ── K: the cap, pure ─────────────────────────────────────────────────────────
cap() { ( unset MAX_FIXROUNDS_SMALL MAX_FIXROUNDS BR_CONFLICT_FIX_ROUNDS BR_MAX_FIXROUNDS_SMALL BR_MAX_FIXROUNDS BR_REVIEW_FIX_ROUNDS SMALL_CONFLICT_LINES
          while [ "$#" -gt 2 ]; do export "$1"; shift; done
          . "$DIR/bin/lib/br/record.sh" || exit 9
          br_fix_cap "$1" "$2" ); }
[ "$(cap '{"conflict_lines":120}' '')" = 2 ] && ok || bad "K1: a 120-line conflict gets 2 rounds with no knob (got $(cap '{"conflict_lines":120}' ''))"
[ "$(cap '{"conflict_lines":300}' '')" = 2 ] && ok || bad "K1: 300 lines is still small (2 rounds)"
[ "$(cap BR_CONFLICT_FIX_ROUNDS=3 '{"conflict_lines":120}' '')" = 3 ] && ok || bad "K2: BR_CONFLICT_FIX_ROUNDS=3 must give 3 (got $(cap BR_CONFLICT_FIX_ROUNDS=3 '{"conflict_lines":120}' ''))"
[ "$(cap BR_CONFLICT_FIX_ROUNDS=1 BR_MAX_FIXROUNDS_SMALL=3 '{"conflict_lines":120}' '')" = 1 ] && ok || bad "K2: BR_CONFLICT_FIX_ROUNDS wins over BR_MAX_FIXROUNDS_SMALL"
[ "$(cap BR_MAX_FIXROUNDS_SMALL=3 '{"conflict_lines":120}' '')" = 3 ] && ok || bad "K2: BR_MAX_FIXROUNDS_SMALL alone is still the fallback"
[ "$(cap BR_CONFLICT_FIX_ROUNDS=5 '{"conflict_lines":301}' '')" = 1 ] && ok || bad "K3: a 301-line conflict stays on the large ladder (1)"
[ "$(cap BR_CONFLICT_FIX_ROUNDS=5 '{}' '')" = 1 ] && ok || bad "K3: an unmeasured conflict stays large (1)"
[ "$(cap BR_CONFLICT_FIX_ROUNDS=5 '{"conflict_lines":0}' '')" = 1 ] && ok || bad "K3: a measured 0 (delete/modify) stays large (1)"
[ "$(cap BR_CONFLICT_FIX_ROUNDS=5 '{"conflict_lines":120}' review-changes-requested)" = 2 ] && ok || bad "K4: a review park keeps BR_REVIEW_FIX_ROUNDS (2)"
[ "$(cap BR_CONFLICT_FIX_ROUNDS=5 '{"conflict_lines":120}' queue-dequeued)" = 1 ] && ok || bad "K4: a dequeue park keeps 1"
[ "$(cap '{"conflict_lines":120,"fixround_bonus":1}' '')" = 3 ] && ok || bad "K5: the contested bonus rides on top (3)"

# ── the real script ─────────────────────────────────────────────────────────
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin" "$H/prompts/fix-round.d"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
for lib in bin/lib/hub-box.sh bin/lib/heartbeat.sh bin/lib/lane-gate.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || { echo "FAIL: closure of $lib"; exit 1; }
done
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
SECTION="$DIR/prompts/fix-round.d/conflict.md"
[ -f "$SECTION" ] && cp "$SECTION" "$H/prompts/fix-round.d/conflict.md"
fx_br_ladder_git "$DIR" "$T" || exit 1

# F4's spec: the pipeline commits the plan on the branch (.harness/specs/<KEY>/).
S="$T/seed"
git -C "$S" checkout -q ticket/TK-88
mkdir -p "$S/.harness/specs/TK-88"
printf '# Plan: TK-88\nKEEP-BRANCH-LINE: the branch appends its own line to a.txt\n' > "$S/.harness/specs/TK-88/plan.md"
git -C "$S" add -A; git -C "$S" commit -qm "spec(TK-88)"; git -C "$S" push -q origin ticket/TK-88
git -C "$T/repos/tproj" fetch -q origin

# The agent: RESOLVE writes a clean a.txt and commits the merge; FAIL leaves
# the markers and exits 0. Either way the prompt it got is kept.
cat > "$H/bin/agent-call.sh" <<AGENT
#!/bin/bash
printf '%s' "\$6" > "$T/prompt.txt"
if [ "\$(cat "$T/mode" 2>/dev/null)" = RESOLVE ]; then
  printf 'line one\nmain changed this line\nthe branch changed this line\n' > a.txt
  git add -A >/dev/null 2>&1
  git commit -q -m "fix round: resolved the merge" >/dev/null 2>&1
fi
exit 0
AGENT
chmod +x "$H/bin/agent-call.sh"

PR91="https://github.com/o/tproj/pull/91"
LOGF="$H/logs/blocked-resolver.log"
BRENV=()
FIXHERE() { # FIXHERE <reason> <rec> <tkey> — one round; stdout to $T/out.txt, the record back to $T/rec-in.json
  ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
    env ${BRENV[@]+"${BRENV[@]}"} bash "$H/bin/blocked-resolver.sh" --fix-here tproj cff-1 "$1" "$PR91" "$2" "$3" < "$T/rec-in.json" ) >"$T/out.txt" 2>>"$T/run.log"
  local r; r=$(sed -n 's/^FIX_RECORD //p' "$T/out.txt" | base64 -d 2>/dev/null)
  [ -n "$r" ] && printf '%s' "$r" > "$T/rec-in.json"
}
RESET() { # RESET <branch> <mode> [<seed record json>]
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/tmp/brfix"
  : > "$LOGF"; rm -f "$T/prompt.txt" "$T/out.txt"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do git -C "$T/repos/tproj" branch -D "$b" >/dev/null 2>&1; done
  printf '%s\n' "$1" > "$T/prbranch"; osha "$1" | tr -d '\n' > "$T/prhead"; printf 'main\n' > "$T/prbase"
  printf 'conductor: conflict-unresolvable\n' > "$T/findings"
  printf '%s\n' "$2" > "$T/mode"
  local seed="${3:-}"; [ -n "$seed" ] || seed='{}'
  printf '%s' "$seed" | jq -c '{project:"tproj",rkey:"cff-1",fixrounds:0,rebuilds:0,mechanicals:1,outcome:"",attempts:[]} + .' > "$T/rec-in.json"
}
details() { jq -r '.attempts[] | select(.action == "fix-round" or .action == "fix-round-noop") | .detail' "$T/rec-in.json" 2>/dev/null; }
count() { details | grep -cE "$1"; }
result() { sed -n 's/^FIX_RESULT //p' "$T/out.txt" | tail -1; }
rung() { # the ladder's own next rung for the returned record
  ( . "$DIR/bin/lib/br/record.sh"; . "$DIR/bin/lib/br/ladder.sh"
    st=$(cat "$T/rec-in.json")
    br_ladder_rung rebase-conflict "$(jq -r '.mechanicals' <<<"$st")" "$(jq -r '.fixrounds' <<<"$st")" "$(br_fix_cap "$st" conflict-unresolvable)" ); }

# ── F1: small conflict, round 1 resolves it ─────────────────────────────────
RESET ticket/TK-88 RESOLVE
C0=$(osha ticket/TK-88)
FIXHERE conflict-unresolvable - TK-88
[ -s "$T/prompt.txt" ] && ok || bad "F1: the round never reached the agent (log: $(tail -4 "$LOGF"))"
[ "$(osha ticket/TK-88)" != "$C0" ] && ok || bad "F1: the resolved round must push (log: $(tail -4 "$LOGF"))"
[ "$(jq -r '.fixrounds' "$T/rec-in.json")" = 1 ] && ok || bad "F1: fixrounds must be 1 (got $(jq -r '.fixrounds' "$T/rec-in.json"))"
[ "$(jq -r '.rebuilds' "$T/rec-in.json")" = 0 ] && ok || bad "F1: no rebuild"
[ "$(jq '[.attempts[] | select(.action == "rebuild-fresh")] | length' "$T/rec-in.json")" = 0 ] && ok || bad "F1: no rebuild-fresh attempt"
[ "$(result)" = done ] && ok || bad "F1: the round must end done, not '$(result)'"
[ "$(count 'fix-round-conflict ok lines=[0-9]+$')" = 1 ] && ok || bad "F1: exactly one 'fix-round-conflict ok lines=<n>' row (details: $(details | tr '\n' '|'))"
[ "$(count 'fix-round-conflict failed')" = 0 ] && ok || bad "F1: no failed row"

# ── F4: the prompt of that round ────────────────────────────────────────────
P="$T/prompt.txt"
grep -qF 'Resolve the conflict only. Make no other change.' "$P" 2>/dev/null && ok || bad "F4: the rule line is missing from the prompt"
grep -qF 'THE MERGE OF origin/main IS IN PROGRESS' "$P" 2>/dev/null && ok || bad "F4: the merge paragraph must stay"
grep -q '<<<<<<<' "$P" 2>/dev/null && ok || bad "F4: the conflict markers must stay"
sed -n "/MERGED-IN SIDE'S DIFF/,\$p" "$P" 2>/dev/null | grep -qx '+main changed this line' && ok \
  || bad "F4: main's '+main changed this line' must sit under the MERGED-IN SIDE'S DIFF heading"
grep -qF 'THE PLAN THIS PR WAS BUILT FROM: .harness/specs/TK-88/plan.md' "$P" 2>/dev/null && ok || bad "F4: the plan path must be named"
grep -qF 'KEEP-BRANCH-LINE: the branch appends its own line' "$P" 2>/dev/null && ok || bad "F4: the plan excerpt must be in the prompt"

# ── F2: small conflict, two failed rounds, then the terminal ────────────────
RESET ticket/TK-89 FAIL
C0=$(osha ticket/TK-89)
FIXHERE conflict-unresolvable - -
[ "$(result)" = done ] && ok || bad "F2: round 1 of 2 failed, round 2 is owed (got '$(result)')"
[ "$(rung)" = fix-round ] && ok || bad "F2: after one failed round the ladder still offers a fix round (got $(rung))"
FIXHERE conflict-unresolvable - -
[ "$(count 'fix-round-conflict failed lines=[0-9]+$')" = 2 ] && ok || bad "F2: two 'fix-round-conflict failed lines=<n>' rows (details: $(details | tr '\n' '|'))"
[ "$(count 'fix-round-conflict ok')" = 0 ] && ok || bad "F2: no ok row"
[ "$(result)" = terminal ] && ok || bad "F2: the second failed round is the terminal (rebuild-fresh on the hub), got '$(result)'"
[ "$(rung)" = rebuild-fresh ] && ok || bad "F2: the third offer is rebuild-fresh (got $(rung))"
[ "$(osha ticket/TK-89)" = "$C0" ] && ok || bad "F2: a failed round must not move origin's head"

# ── F3: large conflict, one failed round, then the terminal ─────────────────
RESET ticket/TK-94 FAIL '{"conflict_lines":500}'
FIXHERE conflict-unresolvable - -
[ "$(count 'fix-round-conflict failed lines=500$')" = 1 ] && ok || bad "F3: one 'failed lines=500' row (details: $(details | tr '\n' '|'))"
[ "$(result)" = terminal ] && ok || bad "F3: a large conflict's failed round is the terminal (got '$(result)')"
[ "$(jq -r '.fixrounds' "$T/rec-in.json")" = 1 ] && [ "$(rung)" = rebuild-fresh ] && ok || bad "F3: fixrounds 1, next rung rebuild-fresh"

# ── K6: BR_CONFLICT_FIX_ROUNDS=1 through the real script ────────────────────
RESET ticket/TK-102 FAIL
BRENV=(BR_CONFLICT_FIX_ROUNDS=1)
FIXHERE conflict-unresolvable - -
BRENV=()
[ "$(result)" = terminal ] && ok || bad "K6: with BR_CONFLICT_FIX_ROUNDS=1 the first failed round is the terminal (got '$(result)'; log: $(grep -m1 'did not land\|did not produce' "$LOGF"))"

# ── F4b: the plan from the build record, then not found ─────────────────────
RESET ticket/TK-95 FAIL
mkdir -p "$T/rec-95"; printf 'RECORD-PLAN-LINE: from the build record\n' > "$T/rec-95/plan.md"
FIXHERE conflict-unresolvable "$T/rec-95" TK-95
grep -qF "THE PLAN THIS PR WAS BUILT FROM: $T/rec-95/plan.md" "$P" 2>/dev/null && ok || bad "F4b: the record's plan.md must be named"
grep -qF 'RECORD-PLAN-LINE: from the build record' "$P" 2>/dev/null && ok || bad "F4b: the record plan's excerpt must be in the prompt"
RESET ticket/TK-98 FAIL
FIXHERE conflict-unresolvable - TK-98
grep -qF 'THE PLAN THIS PR WAS BUILT FROM: not found' "$P" 2>/dev/null && ok || bad "F4b: no plan anywhere says 'not found'"

# ── F4c: the section file is missing ────────────────────────────────────────
rm -f "$H/prompts/fix-round.d/conflict.md"
RESET ticket/TK-101 FAIL
FIXHERE conflict-unresolvable - -
[ -s "$P" ] && ok || bad "F4c: the round must still run without the section file"
grep -qF 'Resolve the conflict only. Make no other change.' "$P" 2>/dev/null && ok || bad "F4c: the fallback rule line"
grep -qF 'prompts/fix-round.d/conflict.md' "$LOGF" 2>/dev/null && ok || bad "F4c: the log must name the missing file"
[ -f "$SECTION" ] && cp "$SECTION" "$H/prompts/fix-round.d/conflict.md"

# ── F5: a ci-red park whose merge did not conflict ──────────────────────────
RESET ticket/TK-90 FAIL
printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
FIXHERE red-twice - -
[ "$(count '.')" -ge 1 ] && ok || bad "F5: the round must record a fix-round row (log: $(tail -3 "$LOGF"))"
[ "$(count 'fix-round-conflict')" = 0 ] && ok || bad "F5: no conflict, no fix-round-conflict text (details: $(details | tr '\n' '|'))"

echo "br-conflict-fix-first.bh-6964: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
