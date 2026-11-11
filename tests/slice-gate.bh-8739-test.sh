#!/bin/bash
# tests/slice-gate.bh-8739-test.sh — BH-8739: a parent is sliced only for file
# overlap, the context ceiling or ordering, and each child says why.
#
# Drives the real bin/lib/slice-gate.sh (installed with its source closure into
# a scratch harness, knobs through the real lane registry and a settings cache):
#   C1-C12  the sr_coalesce decision table (plan "Failure modes")
#   X1      sr_expected reads what a real bin/size-gate.sh run wrote
#   K1-K3   sr_ceiling_tokens: the manifest, its fragments, the knob fallback
#   P1-P9   sr_proposal_body -> sr_proposal_state round trip, with the real
#           hold_classify, plus the adversarial negatives
# No network. Run: HARNESS_TEST_SANDBOX=1 bash tests/slice-gate.bh-8739-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "slice-gate.bh-8739: jq is required"; exit 1; }

FIX="$DIR/tests/fixtures/slice-gate.bh-8739"
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$T/tmp"
if ! scratch_install_closure bin/lib/slice-gate.sh "$H" >/dev/null; then
  echo "FAIL: cannot install the closure of bin/lib/slice-gate.sh"; echo "slice-gate.bh-8739: 0 passed, 1 failed"; exit 1
fi
REG=$(rendered_registry)
export HARNESS="$H" TMPDIR="$T/tmp" LANE_REGISTRY="$REG" LANE_GATE_NOW=2000000000
unset SLICE_GATE SLICE_TOKENS_PER_LINE SLICE_CONFIRM_OVER SLICE_CEILING_TOKENS CONTEXT_BUDGETS LANE_GATE_DISABLE
settings() { # settings <json-object of rows>
  scratch_rm "$H/state/lane-gate"
  jq -nc --argjson v "$1" '{fetched_at:2000000000, values:$v, seeded:{}}' > "$H/state/settings-cache.json"
}
settings '{}'
# shellcheck source=bin/lib/slice-gate.sh
. "$H/bin/lib/slice-gate.sh" || { echo "FAIL: cannot source the lib"; exit 1; }

CEIL=500000; TPL=400
co() { # co <spec-json-or-file> — coalesce into $T/out.json; sets RC
  if [ -f "$1" ]; then cp "$1" "$T/in.json"; else printf '%s\n' "$1" > "$T/in.json"; fi
  rm -f "$T/out.json"
  sr_coalesce "$T/in.json" "$T/out.json" "$CEIL" "$TPL"; RC=$?
}
n_out() { jq 'length' "$T/out.json" 2>/dev/null || echo -1; }
field() { jq -r "$1" "$T/out.json" 2>/dev/null; }
sl() { # sl <title> <est> <owns-csv> [after-json] — one slice object
  jq -nc --arg t "$1" --argjson e "$2" --arg o "$3" --argjson a "${4:-[]}" \
    '{title:$t, est_lines:$e, owns:($o | split(",")), after:$a, body:("Do " + $t + ".\n\n## Observable outcome\n" + $t + " works.")}'
}

# --- C1: twelve screens in one area, nothing shared -> 1 child -----------------
co "$FIX/twelve-screens.json"
[ "$RC" = 0 ] && ok || bad "C1: rc=$RC"
[ "$(n_out)" = 1 ] && ok || bad "C1: 12 disjoint small slices must be 1 child, got $(n_out)"
[ "$(field '.[0].reason')" = "none: one child" ] && ok || bad "C1: reason: $(field '.[0].reason')"
[ "$(field '.[0].body | split("\n")[0]')" = "Slice reason: none: one child" ] && ok || bad "C1: the body must open with the reason line"
[ "$(field '.[0].owns | length')" = 12 ] && ok || bad "C1: the child owns every path, got $(field '.[0].owns | length')"
[ "$(field '.[0].est_lines')" = 480 ] && ok || bad "C1: est_lines is the sum, got $(field '.[0].est_lines')"
[ "$(field '.[0].title')" = "finance screen 1 (+11 more)" ] && ok || bad "C1: title: $(field '.[0].title')"
[ "$(field '.[0].body' | grep -c '^### finance screen ')" = 12 ] && ok || bad "C1: every member body is under its own heading"
[ "$(field '.[0].contract')" = "$(jq -r '.[0].contract' "$FIX/twelve-screens.json")" ] && ok || bad "C1: child 1 keeps the contract"

# --- C2: slices 4 and 9 share a file -> 2 children ------------------------------
co "$FIX/twelve-screens-shared.json"
[ "$(n_out)" = 2 ] && ok || bad "C2: a shared file must give 2 children, got $(n_out)"
[ "$(field '.[1].title')" = "finance screen 9 (+3 more)" ] && ok || bad "C2: child 2 holds slices 9-12: $(field '.[1].title')"
case "$(field '.[1].reason')" in 'file-overlap: src/finance/shared.ts is also edited by "finance screen 4"') ok ;;
  *) bad "C2: child 2 reason: $(field '.[1].reason')" ;; esac
[ "$(field '.[0].reason')" = "first slice: lands first; the rest split off for file-overlap" ] && ok || bad "C2: child 1 reason: $(field '.[0].reason')"
[ "$(field '.[1].after | length')" = 0 ] && ok || bad "C2: an overlap with child 1 needs no after (the filer blocks on child 1)"
[ "$(field '.[1] | has("imports_contract")')" = false ] && ok || bad "C2: an overlap with child 1 must keep the child blocked on it"
[ "$(field '.[1].body | split("\n")[0]')" = "Slice reason: $(field '.[1].reason')" ] && ok || bad "C2: child 2 body opens with its reason"

# --- C3: near miss, similar paths are not the same path -------------------------
co "[$(sl a 10 src/a.ts),$(sl b 10 src/a.tsx),$(sl c 10 src/finance/),$(sl d 10 src/finance/x.ts)]"
[ "$(n_out)" = 1 ] && ok || bad "C3: a.ts/a.tsx and a dir/file are no overlap, got $(n_out)"
# --- C4: ./ prefix is the same path -------------------------------------------
co "[$(sl a 10 ./src/x.ts),$(sl b 10 src/x.ts)]"
[ "$(n_out)" = 2 ] && ok || bad "C4: ./src/x.ts and src/x.ts overlap, got $(n_out)"

# --- C5: the context ceiling ---------------------------------------------------
co "[$(sl a 700 src/a.ts),$(sl b 700 src/b.ts),$(sl c 700 src/c.ts)]"
[ "$(n_out)" = 3 ] && ok || bad "C5: 3 x 280K must be 3 children, got $(n_out)"
[ "$(field '.[1].reason')" = "context-ceiling: 560000 tokens would pass the build-execute ceiling of 500000" ] \
  && ok || bad "C5: reason: $(field '.[1].reason')"
# --- C6: exactly at the ceiling joins ------------------------------------------
co "[$(sl a 625 src/a.ts),$(sl b 625 src/b.ts)]"
[ "$(n_out)" = 1 ] && ok || bad "C6: a sum equal to the ceiling joins, got $(n_out)"

# --- C7: ordering ---------------------------------------------------------------
co "[$(sl tracer 20 src/t.ts),$(sl 'scan list' 30 src/l.ts),$(sl 'scan export' 30 src/e.ts '["2: listScans()"]')]"
[ "$(n_out)" = 2 ] && ok || bad "C7: an after on slice 2 must give 2 children, got $(n_out)"
[ "$(field '.[1].reason')" = 'ordering: must merge after "scan list" (listScans())' ] && ok || bad "C7: reason: $(field '.[1].reason')"
# ordering on a slice that is in child 2 keeps a filer-readable after
co "[$(sl a 700 src/a.ts),$(sl b 700 src/b.ts),$(sl c 10 src/c.ts '["2: makeB()"]')]"
[ "$(n_out)" = 3 ] && ok || bad "C7b: 3 children, got $(n_out)"
[ "$(field '.[2].after | join(",")')" = "2: makeB()" ] && ok || bad "C7b: after must name child 2: $(field '.[2].after')"
# --- C8: an after naming the contract is not a reason ---------------------------
co "[$(sl a 10 src/a.ts),$(sl b 10 src/b.ts),$(sl c 10 src/c.ts '["1: x"]')]"
[ "$(n_out)" = 1 ] && ok || bad "C8: after 1 is not a reason, got $(n_out)"

# --- C9: legacy spec, no est_lines anywhere -------------------------------------
printf '%s\n' '[{"title":"a","body":"x"},{"title":"b","body":"y"}]' > "$T/legacy.json"
cp "$T/legacy.json" "$T/legacy.orig"
sr_coalesce "$T/legacy.json" "$T/legacy.json" "$CEIL" "$TPL"; RC=$?
[ "$RC" = 2 ] && ok || bad "C9: legacy rc must be 2, got $RC"
cmp -s "$T/legacy.json" "$T/legacy.orig" && ok || bad "C9: a legacy spec is left byte for byte"
# --- C10: partial est_lines -----------------------------------------------------
co '[{"title":"a","body":"x","est_lines":10},{"title":"b","body":"y"}]'
[ "$RC" = 1 ] && ok || bad "C10: some est_lines but not all must be rc 1, got $RC"
co '[{"title":"a","body":"x","est_lines":10},{"title":"b","body":"y","est_lines":"lots"}]'
[ "$RC" = 1 ] && ok || bad "C10b: a non-numeric est_lines must be rc 1, got $RC"
# --- C11: idempotent ------------------------------------------------------------
for f in twelve-screens.json twelve-screens-shared.json; do
  co "$FIX/$f"; cp "$T/out.json" "$T/once.json"
  sr_coalesce "$T/once.json" "$T/twice.json" "$CEIL" "$TPL"
  cmp -s "$T/once.json" "$T/twice.json" && ok || bad "C11: coalesce(coalesce($f)) must equal coalesce($f)"
done
# --- C12: imports_contract ------------------------------------------------------
co "[$(sl a 700 src/a.ts),$(jq -c '. + {imports_contract:false}' <<<"$(sl b 700 src/b.ts)")]"
[ "$(field '.[1].imports_contract')" = false ] && ok || bad "C12: a child of independent slices keeps imports_contract false"

# --- C13: the seam pattern: siblings fill seam files child 1 created ------------
co "[$(sl tracer 20 src/seam-a.ts,src/seam-b.ts),$(sl 'part a' 30 src/seam-a.ts),$(jq -c '. + {imports_contract:false}' <<<"$(sl 'part b' 30 src/seam-b.ts)")]"
[ "$(n_out)" = 2 ] && ok || bad "C13: part a overlaps the open child 1 (new child); part b only overlaps closed child 1 and joins, got $(n_out)"
[ "$(field '.[1].title')" = "part a (+1 more)" ] && ok || bad "C13: child 2 holds parts a and b: $(field '.[1].title')"
[ "$(field '.[1] | has("imports_contract")')" = false ] && ok || bad "C13: a child that edits a child-1 path stays blocked on child 1"
# --- C14: an overlap with a closed child 2 still splits, ordered after it ----------
co "[$(sl a 700 src/a.ts),$(sl b 700 src/b.ts),$(sl c 700 src/c.ts),$(sl d 10 src/b.ts)]"
[ "$(n_out)" = 4 ] && ok || bad "C14: d shares src/b.ts with closed child 2, got $(n_out)"
[ "$(field '.[3].after | join(",")')" = "2: same file src/b.ts" ] && ok || bad "C14: d must be ordered after child 2: $(field '.[3].after')"

# --- X1: sr_expected reads a real size-gate.txt ---------------------------------
mkdir -p "$T/b1"; printf '# P\n\n## Size\n\nFILES: 10\nLINES: 4000\n' > "$T/b1/plan.md"
"$DIR/bin/size-gate.sh" "$T/b1/plan.md" 700 20 > "$T/b1/size-gate.txt" 2>&1
[ "$(sr_expected "$T/b1")" = 6 ] && ok || bad "X1: sr_expected of a 4000-line plan must be 6, got $(sr_expected "$T/b1")"
[ "$(sr_expected "$T/no-such-dir")" = 0 ] && ok || bad "X1: no size-gate.txt is 0"

# --- K1-K3: the ceiling ---------------------------------------------------------
[ "$(sr_ceiling_tokens demo)" = 500000 ] && ok || bad "K1: no manifest and no row -> the knob default 500000, got $(sr_ceiling_tokens demo)"
settings '{"lib.slice-gate.demo.slice_ceiling_tokens":"654321"}'
[ "$(sr_ceiling_tokens demo)" = 654321 ] && ok || bad "K1b: the settings row wins the fallback, got $(sr_ceiling_tokens demo)"
settings '{}'
mkdir -p "$H/catalog/context-budgets.d"
printf '[\n{"lane":"build-execute","ceiling_tokens":300000}\n]\n' > "$H/catalog/context-budgets.d/0000-base.json"
[ "$(sr_ceiling_tokens demo)" = 300000 ] && ok || bad "K2: the fragments answer, got $(sr_ceiling_tokens demo)"
printf '{"lanes":[{"lane":"build-execute","ceiling_tokens":123456}]}\n' > "$H/catalog/context-budgets.json"
[ "$(sr_ceiling_tokens demo)" = 123456 ] && ok || bad "K3: the composed manifest wins, got $(sr_ceiling_tokens demo)"

# --- P: the proposal and its state ----------------------------------------------
co "$FIX/twelve-screens-shared.json"
sr_proposal_body BH-8739 "$T/out.json" 6 5 > "$T/proposal.md"
[ "$(head -1 "$T/proposal.md")" = "<!-- decompose-proposal: BH-8739 -->" ] && ok || bad "P1: the first line is the marker"
grep -q 'HUMAN-STEP-DONE:' "$T/proposal.md" && ok || bad "P1: the body says how to release it"
grep -q '^2\. \*\*finance screen 9 (+3 more)\*\*' "$T/proposal.md" && ok || bad "P1: the body lists each child: $(cat "$T/proposal.md")"
grep -q 'file-overlap' "$T/proposal.md" && ok || bad "P1: the body names each reason"
issue='{"number":8739,"state":"open","title":"parent","body":"the ask","labels":[{"name":"ai-build"}]}'
c() { # c <login> <type> <at> <body>
  jq -nc --arg l "$1" --arg t "$2" --arg a "$3" --arg b "$4" '{user:{login:$l, type:$t}, created_at:$a, body:$b}'
}
thread() { # thread <comment-json>... -> $T/thread.json
  jq -nc --argjson i "$issue" --argjson c "$(printf '%s\n' "$@" | jq -s -c .)" '{issue:$i, comments:$c}' > "$T/thread.json"
}
PROP=$(c harness-app[bot] Bot 2026-10-28T10:00:00Z "$(cat "$T/proposal.md")")
NH=$(c harness-app[bot] Bot 2026-10-28T10:00:05Z "NEEDS-HUMAN: confirm the proposed split of BH-8739 into 6 tickets
<!-- nh-fp:abc123def456 -->")
st() { sr_proposal_state BH-8739 "$T/thread.json" "${1:-issues}"; }
thread; [ "$(st)" = none ] && ok || bad "P2: no proposal -> none, got $(st)"
thread "$PROP" "$NH"; [ "$(st)" = waiting ] && ok || bad "P3: proposal + hold -> waiting, got $(st)"
thread "$PROP" "$NH" "$(c operator User 2026-10-28T11:00:00Z 'HUMAN-STEP-DONE: yes, file them')"
[ "$(st)" = confirmed ] && ok || bad "P4: a person's HUMAN-STEP-DONE -> confirmed, got $(st) (hold: $SR_HOLD)"
thread "$PROP" "$NH" "$(c harness-app[bot] Bot 2026-10-28T11:00:00Z 'HUMAN-STEP-DONE: quoted by a bot')"
[ "$(st)" = waiting ] && ok || bad "P5: an untagged bot HUMAN-STEP-DONE stays waiting, got $(st)"
thread "$(c harness-app[bot] Bot 2026-10-28T10:00:00Z "$(sed 's/BH-8739/BH-87390/' "$T/proposal.md")")"
[ "$(st)" = none ] && ok || bad "P6: a KEY0 marker is not this KEY's, got $(st)"
thread "$(c harness-app[bot] Bot 2026-10-28T10:00:00Z "$(sed 's/BH-8739 /BH-8739.1 /' "$T/proposal.md")")"
[ "$(st)" = none ] && ok || bad "P6b: a KEY.1 marker is not this KEY's, got $(st)"
thread "$(c harness-app[bot] Bot 2026-10-28T10:00:00Z "close-out
\`\`\`
<!-- decompose-proposal: BH-8739 -->
\`\`\`")"
[ "$(st)" = none ] && ok || bad "P7: a quoted marker inside a fence is not a proposal, got $(st)"
# A lift that came BEFORE the proposal does not confirm it.
thread "$(c operator User 2026-10-28T09:00:00Z 'NEEDS-HUMAN: old ask')" "$(c operator User 2026-10-28T09:30:00Z 'HUMAN-STEP-DONE: old')" "$PROP"
[ "$(st)" = waiting ] && ok || bad "P8: an older lift does not confirm a newer proposal, got $(st)"
# board lane
bt() { jq -nc --argjson c "$(printf '%s\n' "$@" | jq -s -c .)" '{id:"t1", comments:$c}' > "$T/thread.json"; }
bc() { jq -nc --arg a "$1" --arg b "$2" '{author:$a, body:$b, createdAt:"2026-10-28T10:00:00Z"}'; }
bt "$(bc Harness "$(cat "$T/proposal.md")")" "$(bc Harness 'build status note')"
[ "$(st board)" = waiting ] && ok || bad "P9: a newer board comment by the same author stays waiting, got $(st board)"
bt "$(bc Harness "$(cat "$T/proposal.md")")" "$(bc 'Dana Client' 'Yes, split it like that')"
[ "$(st board)" = confirmed ] && ok || bad "P9b: a reply by another author confirms, got $(st board)"
printf 'not json' > "$T/thread.json"
out=$(st); rc=$?
[ "$rc" = 2 ] && [ "$out" = unreadable ] && ok || bad "P10: an unreadable thread is rc 2 unreadable, got rc=$rc $out"

echo "slice-gate.bh-8739: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
