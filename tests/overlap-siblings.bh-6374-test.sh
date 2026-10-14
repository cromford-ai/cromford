#!/bin/bash
# tests/overlap-siblings.bh-6374-test.sh — sibling parts of one split slice
# (TK-142.1, TK-142.2, ...) that share a planned file run one at a time, in n
# order, and a part with no pre-plan list waits for its sibling in flight
# (BH-6374).
#
#   D1-D12  bin/sibling-serial.sh decide on hand-written ROWS / INFLIGHT / PRS
#           files, in the shapes bin/overlap-schedule.sh writes them
#   A1-A5   the real bin/overlap-schedule.sh: HELD, WAVE, STACK and UNPLANNED
#   A7      the project-6 TK-138 replay from the ticket
#
# No network, no gh. Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SS="$DIR/bin/sibling-serial.sh"
TAB=$'\t'

# ── decide: the rule on its three input files ────────────────────────────────
# dec <rows> <inflight> <prs> — each arg is file content (\n-separated lines).
dec() {
  printf '%b' "$1" > "$T/rows"; printf '%b' "$2" > "$T/inflight"; printf '%b' "$3" > "$T/prs"
  IGNORE='package.json package-lock.json *.md' RM="" STACK_ON="${STACK_ON:-1}" \
    "$SS" decide "$T/rows" "$T/inflight" "$T/prs" 2>/dev/null
}
has()  { grep -qxF "$2" <<<"$3" && ok || bad "$1: expected line '$2', got: $3"; }
nokey() { grep -q "^SIBLING_SERIAL $2 " <<<"$3" && bad "$1: $2 must not wait, got: $3" || ok; }

# D1: both queued, same file -> .2 waits for .1
OUT=$(dec "TK-142.1\tqueued\tsrc/x/board.tsx\nMK-142.2\tqueued\tsrc/x/board.tsx\n" "" "")
has D1 "SIBLING_SERIAL TK-142.2 waits for TK-142.1 on src/x/board.tsx" "$OUT"
nokey D1 TK-142.1 "$OUT"

# D2: .2 in flight with a list, .3 queued with no list -> .3 waits
OUT=$(dec "TK-142.2\tinflight\tsrc/a.ts\nMK-142.3\tqueued\t\n" "TK-142.2\n" "")
has D2 "SIBLING_SERIAL TK-142.3 waits for TK-142.2 on (no pre-plan list)" "$OUT"

# D3: .1 in flight with no list, .2 queued with a list -> .2 waits
OUT=$(dec "TK-142.2\tqueued\tsrc/a.ts\n" "TK-142.1\n" "")
has D3 "SIBLING_SERIAL TK-142.2 waits for TK-142.1 on (no pre-plan list)" "$OUT"

# D4: .1 has open PR #11 changing the file, .2 lists it -> waits, stackable
OUT=$(dec "TK-142.2\tqueued\tsrc/x/board.tsx\n" "" "11\tticket/TK-142.1\tsrc/x/board.tsx\n")
has D4 "SIBLING_SERIAL TK-142.2 waits for TK-142.1 on src/x/board.tsx stackable base=ticket/TK-142.1" "$OUT"
OUT=$(STACK_ON=0 dec "TK-142.2\tqueued\tsrc/x/board.tsx\n" "" "11\tticket/TK-142.1\tsrc/x/board.tsx\n")
has D4b "SIBLING_SERIAL TK-142.2 waits for TK-142.1 on src/x/board.tsx" "$OUT"

# D5: prefix: .1 lists src/x, .2 lists src/x/board.tsx -> waits
OUT=$(dec "TK-142.1\tqueued\tsrc/x\nMK-142.2\tqueued\tsrc/x/board.tsx\n" "" "")
has D5 "SIBLING_SERIAL TK-142.2 waits for TK-142.1 on src/x/board.tsx" "$OUT"

# D6: disjoint -> both go
OUT=$(dec "TK-142.1\tqueued\tsrc/a.ts\nMK-142.2\tqueued\tsrc/b.ts\n" "" "")
[ -z "$OUT" ] && ok || bad "D6: disjoint siblings must not wait, got: $OUT"

# D7: non-part keys share a path -> no sibling verdict
OUT=$(dec "AB-1\tqueued\tcode/shared.ts\nAB-2\tqueued\tcode/shared.ts\n" "AB-3\n" "")
[ -z "$OUT" ] && ok || bad "D7: non-part keys are never judged, got: $OUT"

# D8: different parent or a boundary -> not siblings
OUT=$(dec "TK-142.1\tqueued\tsrc/x.ts\nMK-1421.2\tqueued\tsrc/x.ts\n" "" "")
[ -z "$OUT" ] && ok || bad "D8: TK-142.1 and TK-1421.2 are not siblings, got: $OUT"
# a PR on ticket/TK-1421.1 is another parent; one on ticket/TK-142.10 is
# sibling .10, never read as .1
OUT=$(dec "TK-142.2\tqueued\tsrc/x.ts\n" "" "13\tticket/TK-1421.1\tsrc/x.ts\n")
[ -z "$OUT" ] && ok || bad "D8b: ticket/TK-1421.1 is not TK-142.2's sibling, got: $OUT"
OUT=$(dec "TK-142.2\tqueued\tsrc/x.ts\n" "" "12\tticket/TK-142.10\tsrc/x.ts\n")
has D8b "SIBLING_SERIAL TK-142.2 waits for TK-142.10 on src/x.ts stackable base=ticket/TK-142.10" "$OUT"
# the candidate's own PR branch is its own repair round, not a sibling
OUT=$(dec "TK-142.10\tqueued\tsrc/x.ts\n" "" "12\tticket/TK-142.10\tsrc/x.ts\n")
[ -z "$OUT" ] && ok || bad "D8b: TK-142.10's own PR does not hold it, got: $OUT"
OUT=$(dec "TK-142.10\tqueued\tsrc/x.ts\n" "" "12\tticket/TK-142.1\tsrc/x.ts\n")
has D8c "SIBLING_SERIAL TK-142.10 waits for TK-142.1 on src/x.ts stackable base=ticket/TK-142.1" "$OUT"

# D9: only OVERLAP_IGNORE / read-mostly paths in common -> go
OUT=$(dec "TK-142.1\tqueued\tdocs/x.md\nMK-142.1\tqueued\tpackage.json\nMK-142.1\tqueued\tsrc/r.ts\nMK-142.2\tqueued\tdocs/x.md\nMK-142.2\tqueued\tpackage.json\nMK-142.2\tqueued\tsrc/r.ts\n" "" "")
[ -n "$OUT" ] || bad "D9 control: src/r.ts is shared, so without RM .2 must wait"
printf 'TK-142.1\tqueued\tdocs/x.md\nMK-142.1\tqueued\tpackage.json\nMK-142.1\tqueued\tsrc/r.ts\nMK-142.2\tqueued\tdocs/x.md\nMK-142.2\tqueued\tpackage.json\nMK-142.2\tqueued\tsrc/r.ts\n' > "$T/rows"
: > "$T/inflight"; : > "$T/prs"
OUT=$(IGNORE='package.json package-lock.json *.md' RM="src/r.ts" STACK_ON=1 "$SS" decide "$T/rows" "$T/inflight" "$T/prs" 2>/dev/null)
[ -z "$OUT" ] && ok || bad "D9: ignored and read-mostly paths are never a sibling collision, got: $OUT"

# D10: .3 queued and .2 queued, colliding -> .2 does not wait for .3
OUT=$(dec "TK-142.3\tqueued\tsrc/x.ts\nMK-142.2\tqueued\tsrc/x.ts\n" "" "")
nokey D10 TK-142.2 "$OUT"
has D10 "SIBLING_SERIAL TK-142.3 waits for TK-142.2 on src/x.ts" "$OUT"

# D11: .1 queued with no list, .2 queued with a list -> go
OUT=$(dec "TK-142.1\tqueued\t\nMK-142.2\tqueued\tsrc/x.ts\n" "" "")
[ -z "$OUT" ] && ok || bad "D11: a queued no-list sibling does not hold anyone, got: $OUT"

# D12: .2 has no list, .1 has only an open PR -> go
OUT=$(dec "TK-142.2\tqueued\t\n" "" "11\tticket/TK-142.1\tsrc/x.ts\n")
[ -z "$OUT" ] && ok || bad "D12: a no-list part does not wait on a sibling PR, got: $OUT"

# D13: the SOURCE: header and a same-list bare dir are not paths
OUT=$(dec "TK-142.1\tqueued\tSOURCE: cheap\nMK-142.1\tqueued\tsrc/a.ts\nMK-142.2\tqueued\tSOURCE: cheap\nMK-142.2\tqueued\tsrc/b.ts\n" "" "")
[ -z "$OUT" ] && ok || bad "D13: a shared SOURCE: header is not a collision, got: $OUT"

# D14: bad input is no output and rc 0
"$SS" decide "$T/nope-rows" "$T/nope-inflight" "$T/nope-prs" >"$T/out" 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok || bad "D14: missing files must be rc 0 and no output (rc $RC, $(cat "$T/out"))"

# D15: an in-flight sibling of ANY order holds on a collision (.3 runs, .2 waits)
OUT=$(dec "TK-142.3\tinflight\tsrc/x.ts\nMK-142.2\tqueued\tsrc/x.ts\n" "TK-142.3\n" "")
has D15 "SIBLING_SERIAL TK-142.2 waits for TK-142.3 on src/x.ts" "$OUT"

# ── the real bin/overlap-schedule.sh ─────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin" "$H/env" "$H/flags" "$H/logs" "$H/plans" "$H/builds" \
         "$H/locks" "$H/state/claims/proj" "$H/state/preplan-candidates" \
         "$H/state/overlap-guard"
scratch_install_closure bin/overlap-schedule.sh "$H" >/dev/null || { echo "closure install of bin/overlap-schedule.sh failed"; exit 1; }
scratch_install_closure bin/sibling-serial.sh "$H" >/dev/null || bad "closure install of bin/sibling-serial.sh failed"
printf 'proj  example-org/proj   -  -  0 local -\n' > "$H/fleet.conf"

plan_files() { # plan_files <KEY> <path>...
  local k="$1"; shift
  mkdir -p "$H/plans/proj-$k"
  printf '%s\n' "$@" > "$H/plans/proj-$k/planned-files.txt"
}
cands() { # cands <KEY>... — a FRESH candidate snapshot, rows in this order
  local k
  for k in "$@"; do printf '%s\t%s\tahead\n' "$k" "${k//[!0-9]/}"; done \
    > "$H/state/preplan-candidates/proj.tsv"
}
inflight() { # inflight <KEY> <path>... — a live claim on this box
  local k="$1"; shift
  printf '%s\n' "$@" > "$H/state/claims/proj/$k"
  touch "$H/locks/build-key-proj-$k.lock"
}
CACHE="$H/state/overlap-guard/proj-prs.json"
reset() {
  local p
  for p in "$H/state/claims/proj" "$H/plans" "$H/locks"; do scratch_rm "$p"; done
  mkdir -p "$H/state/claims/proj" "$H/plans" "$H/locks"
  rm -f "$H/flags/stacked-builds-off" "$CACHE"
}
run() { HARNESS="$H" "$H/bin/overlap-schedule.sh" "$@" 2>/dev/null; }

# A1: TK-142.1 and TK-142.2 queued, both list src/x/board.tsx
reset
plan_files TK-142.1 src/x/board.tsx src/x/a.ts
plan_files TK-142.2 src/x/board.tsx src/x/b.ts
cands TK-142.1 TK-142.2
OUT=$(run proj)
has A1 "HELD: TK-142.2 waits for sibling TK-142.1 on src/x/board.tsx (SIBLING_SERIAL)" "$OUT"
grep -q 'TK-142.2' <<<"$(grep '^WAVE' <<<"$OUT")" && bad "A1: TK-142.2 must be in no WAVE line, got: $OUT" || ok
grep -qxF 'WAVE 1: TK-142.1' <<<"$OUT" && ok || bad "A1: WAVE 1 must be TK-142.1 alone, got: $OUT"
OUT=$(run proj --key TK-142.2)
[ "$OUT" = "HELD: TK-142.2 waits for sibling TK-142.1 on src/x/board.tsx (SIBLING_SERIAL)" ] && ok \
  || bad "A1: --key TK-142.2 must print exactly the HELD line, got: $OUT"

# A2: disjoint lists -> both WAVE 1, no HELD
reset
plan_files TK-142.1 src/x/a.ts
plan_files TK-142.2 src/x/b.ts
cands TK-142.1 TK-142.2
OUT=$(run proj)
grep -qxF 'WAVE 1: TK-142.1 TK-142.2' <<<"$OUT" && ok || bad "A2: both parts in WAVE 1, got: $OUT"
grep -q '^HELD' <<<"$OUT" && bad "A2: no HELD for disjoint siblings, got: $OUT" || ok

# A3: TK-142.2 in flight with a list, TK-142.3 candidate with no list
reset
inflight TK-142.2 src/x/b.ts
cands TK-142.3
OUT=$(run proj)
has A3 "HELD: TK-142.3 waits for sibling TK-142.2 on (no pre-plan list) (SIBLING_SERIAL)" "$OUT"
grep -q 'TK-142.3' <<<"$(grep '^UNPLANNED' <<<"$OUT")" && bad "A3: a held key is not UNPLANNED, got: $OUT" || ok

# A4: TK-142.1 has open PR #11; TK-142.2 lists the file -> STACK; switch off -> HELD
reset
plan_files TK-142.2 src/x/board.tsx
cands TK-142.2
jq -nc '[{number:11, headRefName:"ticket/TK-142.1", isDraft:false, files:[{path:"src/x/board.tsx"}]}]' > "$CACHE"
OUT=$(run proj)
grep -q '^STACK: TK-142.2 base=ticket/TK-142.1 ' <<<"$OUT" && ok || bad "A4: expected STACK on .1's branch, got: $OUT"
grep -q '^HELD' <<<"$OUT" && bad "A4: a stackable sibling is not HELD while stacked builds are on, got: $OUT" || ok
touch "$H/flags/stacked-builds-off"
OUT=$(run proj)
has A4b "HELD: TK-142.2 waits for sibling TK-142.1 on src/x/board.tsx (SIBLING_SERIAL)" "$OUT"
grep -q '^STACK' <<<"$OUT" && bad "A4b: no STACK with the switch off, got: $OUT" || ok

# A5: two unrelated tickets keep today's rule
reset
plan_files AB-1 code/shared.ts code/a.ts
plan_files AB-2 code/shared.ts code/b.ts
cands AB-1 AB-2
OUT=$(run proj)
grep -qxF 'WAVE 1: AB-1' <<<"$OUT" && grep -qxF 'WAVE 2: AB-2' <<<"$OUT" && ok \
  || bad "A5: AB-1 WAVE 1 and AB-2 WAVE 2 as today, got: $OUT"
grep -q '^HELD' <<<"$OUT" && bad "A5: no HELD for non-part keys, got: $OUT" || ok

# A7: the project-6 replay — TK-138.1 in flight, TK-138.4 queued, same board file
reset
inflight TK-138.1 src/components/agent-workspace/board.tsx src/lib/agent.ts
plan_files TK-138.4 src/components/agent-workspace/board.tsx
cands TK-138.4
OUT=$(run proj)
grep -qE '^HELD: TK-138\.4 (waits for sibling|overlaps in-flight) TK-138\.1 on src/components/agent-workspace/board\.tsx' <<<"$OUT" \
  && ok || bad "A7: TK-138.4 must be HELD behind TK-138.1, got: $OUT"
# A7b: the in-flight sibling's list is unknown (a live build dir with only the
# SOURCE: header) -> TK-138.4 is still held, by the sibling rule.
reset
plan_files TK-138.4 src/components/agent-workspace/board.tsx
cands TK-138.4
BD="$H/builds/proj-TK-138.1-202610130000"
mkdir -p "$BD"
printf '{"key":"TK-138.1"}\n' > "$BD/ticket-meta.json"
printf 'SOURCE: cheap\n' > "$BD/planned-files.txt"
OUT=$(run proj)
has A7b "HELD: TK-138.4 waits for sibling TK-138.1 on (no pre-plan list) (SIBLING_SERIAL)" "$OUT"
scratch_rm "$BD"

# A8: no sibling-serial.sh installed -> today's output
reset
plan_files TK-142.1 src/x/board.tsx
plan_files TK-142.2 src/x/board.tsx
cands TK-142.1 TK-142.2
mv "$H/bin/sibling-serial.sh" "$T/ss.bak"
OUT=$(run proj)
mv "$T/ss.bak" "$H/bin/sibling-serial.sh"
[ "$OUT" = "$(printf 'WAVE 1: TK-142.1\nWAVE 2: TK-142.2')" ] && ok || bad "A8: with no sibling-serial.sh the output is today's, got: $OUT"

echo "overlap-siblings: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
