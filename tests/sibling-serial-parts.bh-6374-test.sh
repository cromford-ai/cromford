#!/bin/bash
# tests/sibling-serial-parts.bh-6374-test.sh — sibling parts are known by their
# BOARD key (TK-184), not only by a dotted key (TK-145.1) (BH-6374, C1).
#
# THE DEFECT. A split child never has a dotted key: bin/run-decompose.sh writes
# `TK-145.1: ...` as the title LABEL and the board hands back the real key
# (TK-184). C0's rule knew a part only by `<PARENT>.<n>`, so `check` exited 0 at
# its key regex for every real project-6 part and the pool spawned them side by
# side. The children are recorded, in land order, on line 1 of the parent's
# build RESULT: `DECOMPOSED TK-183,TK-184,TK-185,TK-186`.
#
#   S1-S4   bin/sibling-serial.sh parts <project>: the map from the records
#   D13-D18 decide with a parts map (4th argument), and without one
#   C1-C5   the real check verb and the real bin/overlap-schedule.sh
#   R1-R5   the replay verb over the project-6 sets from the ticket
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
TAB=$'\t'
P=project-6-os
NOTE=src/lib/meeting-notes/report.ts

H="$T/h"
mkdir -p "$H/bin" "$H/env" "$H/flags" "$H/logs" "$H/plans" "$H/builds" "$H/locks" \
         "$H/state/claims/$P" "$H/state/preplan-candidates" "$H/state/overlap-guard" \
         "$H/state/fly-pool/$P" "$H/state/build-queue/$P"
: > "$H/env/global.env"
scratch_install_closure bin/overlap-schedule.sh "$H" >/dev/null || { echo "closure install of bin/overlap-schedule.sh failed"; exit 1; }
scratch_install_closure bin/sibling-serial.sh "$H" >/dev/null || { echo "closure install of bin/sibling-serial.sh failed"; exit 1; }
printf '%s  example-org/project-6   -  -  0 local -\n' "$P" > "$H/fleet.conf"
SS="$H/bin/sibling-serial.sh"

record() { # record <dir-name> <line-1> [touch-date]
  mkdir -p "$H/builds/$1"
  printf '%s\n' "$2" > "$H/builds/$1/RESULT"
  [ -z "${3:-}" ] || touch -d "$3" "$H/builds/$1/RESULT"
}
parts() { HARNESS="$H" "$SS" parts "$P" 2>/dev/null; }

# ── S: the parts map ─────────────────────────────────────────────────────────
record "pool-$P-TK-145-202610130100" "DECOMPOSED TK-183,TK-184,TK-185,TK-186" "2 hours ago"
OUT=$(parts)
grep -qxF "TK-184${TAB}TK-145${TAB}1" <<<"$OUT" && ok || bad "S1: expected TK-184<TAB>TK-145<TAB>1, got: $OUT"
grep -qxF "TK-186${TAB}TK-145${TAB}3" <<<"$OUT" && ok || bad "S1: expected TK-186<TAB>TK-145<TAB>3, got: $OUT"
grep -qxF "TK-183${TAB}TK-145${TAB}0" <<<"$OUT" && ok || bad "S1: the contract is n 0, got: $OUT"

# S2: a record older than 14 days and a PR_CREATED line 1 are not read
record "pool-$P-TK-90-202609280100" "DECOMPOSED TK-91,TK-92" "15 days ago"
record "$P-TK-95-202610130100" "PR_CREATED https://github.com/x/y/pull/1"
printf 'DECOMPOSED TK-96,TK-97\n' >> "$H/builds/$P-TK-95-202610130100/RESULT"
OUT=$(parts)
grep -q '^TK-9[1267]' <<<"$OUT" && bad "S2: an old record or a non-DECOMPOSED line 1 was read: $OUT" || ok
OUT=$(HARNESS="$H" SIBLING_PARTS_LOOKBACK_D=20 "$SS" parts "$P" 2>/dev/null)
grep -qxF "TK-92${TAB}TK-90${TAB}1" <<<"$OUT" && ok || bad "S2: SIBLING_PARTS_LOOKBACK_D=20 must read the 15-day record, got: $OUT"
scratch_rm "$H/builds/pool-$P-TK-90-202609280100"; scratch_rm "$H/builds/$P-TK-95-202610130100"

# S3: the first token only, split on commas
record "$P-TK-60-202610120100" "DECOMPOSED TK-170,TK-171 | CLOSED-OUT: x" "3 hours ago"
OUT=$(parts)
grep -qxF "TK-171${TAB}TK-60${TAB}1" <<<"$OUT" && ok || bad "S3: expected TK-171 n 1 of TK-60, got: $OUT"
grep -q '|' <<<"$OUT" && bad "S3: a | token leaked: $OUT" || ok

# S4: a key in two records takes the newer record's parent
record "$P-TK-61-202610130200" "DECOMPOSED TK-169,TK-171" "1 hour ago"
OUT=$(parts)
grep -qxF "TK-171${TAB}TK-61${TAB}1" <<<"$OUT" && ok || bad "S4: the newer record must win for TK-171, got: $OUT"
[ "$(grep -c "^TK-171${TAB}" <<<"$OUT")" = 1 ] && ok || bad "S4: TK-171 printed more than once: $OUT"
scratch_rm "$H/builds/$P-TK-60-202610120100"; scratch_rm "$H/builds/$P-TK-61-202610130200"

# S5: a bad project name is no output, rc 0
HARNESS="$H" "$SS" parts '../x' >"$T/out" 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok || bad "S5: a bad project is rc 0 and silent (rc $RC)"

# ── D: decide with a parts map ───────────────────────────────────────────────
printf 'TK-183\tMK-145\t0\nMK-184\tMK-145\t1\nMK-185\tMK-145\t2\nMK-186\tMK-145\t3\nMK-201\tMK-199\t1\n' > "$T/parts"
dec() { # dec <rows> <inflight> <prs> [parts-file]
  printf '%b' "$1" > "$T/rows"; printf '%b' "$2" > "$T/inflight"; printf '%b' "$3" > "$T/prs"
  IGNORE='package.json package-lock.json *.md' RM="" STACK_ON="${STACK_ON:-1}" \
    "$SS" decide "$T/rows" "$T/inflight" "$T/prs" ${4:+"$4"} 2>/dev/null
}
has()  { grep -qxF "$2" <<<"$3" && ok || bad "$1: expected line '$2', got: $3"; }

OUT=$(dec "TK-184\tqueued\t$NOTE\nMK-185\tqueued\t$NOTE\n" "" "" "$T/parts")
has D13 "SIBLING_SERIAL TK-185 waits for TK-184 on $NOTE" "$OUT"
grep -q '^SIBLING_SERIAL TK-184 ' <<<"$OUT" && bad "D13: the lower part TK-184 must not wait: $OUT" || ok

OUT=$(dec "TK-186\tqueued\t$NOTE\n" "" "210\tticket/TK-184\t$NOTE\n" "$T/parts")
has D14 "SIBLING_SERIAL TK-186 waits for TK-184 on $NOTE stackable base=ticket/TK-184" "$OUT"

for br in ticket/TK-184-r2 agent/TK-184; do
  OUT=$(dec "TK-186\tqueued\t$NOTE\n" "" "210\t$br\t$NOTE\n" "$T/parts")
  has "D15 $br" "SIBLING_SERIAL TK-186 waits for TK-184 on $NOTE stackable base=$br" "$OUT"
done
for br in ticket/TK-1845 ticket/TK-18 ticket/TK-186; do
  OUT=$(dec "TK-186\tqueued\t$NOTE\n" "" "210\t$br\t$NOTE\n" "$T/parts")
  [ -z "$OUT" ] && ok || bad "D16: branch $br is not a sibling of TK-186, got: $OUT"
done

OUT=$(dec "TK-186\tqueued\t$NOTE\n" "" "210\tticket/TK-184\t$NOTE\n211\tticket/TK-185\t$NOTE\n" "$T/parts")
has D17 "SIBLING_SERIAL TK-186 waits for TK-184 on $NOTE" "$OUT"

# D18: no parts file -> C0's output for dotted keys, and board keys are not parts
OUT=$(dec "TK-142.1\tqueued\tsrc/x.ts\nMK-142.2\tqueued\tsrc/x.ts\n" "" "")
[ "$OUT" = "SIBLING_SERIAL TK-142.2 waits for TK-142.1 on src/x.ts" ] && ok || bad "D18: the 3-argument call changed, got: $OUT"
OUT=$(dec "TK-184\tqueued\t$NOTE\nMK-185\tqueued\t$NOTE\n" "" "")
[ -z "$OUT" ] && ok || bad "D18: with no parts map board keys are not parts, got: $OUT"
# … and a map does not stop the dotted fallback
OUT=$(dec "TK-142.1\tqueued\tsrc/x.ts\nMK-142.2\tqueued\tsrc/x.ts\n" "" "" "$T/parts")
[ "$OUT" = "SIBLING_SERIAL TK-142.2 waits for TK-142.1 on src/x.ts" ] && ok || bad "D18: the dotted fallback with a map, got: $OUT"

# ── C: the real check verb ───────────────────────────────────────────────────
record "pool-$P-TK-145-202610130100" "DECOMPOSED TK-183,TK-184,TK-185,TK-186" "2 hours ago"
record "pool-$P-TK-199-202610130100" "DECOMPOSED TK-200,TK-201" "2 hours ago"
MD="$H/state/fly-pool/$P"; QD="$H/state/build-queue/$P"
reset() {
  local p
  for p in "$H/plans" "$MD" "$QD" "$H/state/sibling-serial"; do scratch_rm "$p"; done
  mkdir -p "$H/plans" "$MD" "$QD"
  rm -f "$H/state/overlap-guard/$P-prs.json"
}
plan_files() { # plan_files <KEY> <path>...
  local k="$1"; shift
  mkdir -p "$H/plans/$P-$k"
  printf '%s\n' "$@" > "$H/plans/$P-$k/planned-files.txt"
}
machine() { jq -nc --arg k "$1" '{machine:"m",key:$k,ticket_id:"1",attempt:1}' > "$MD/m-$1.json"; }
queue() { jq -nc --arg k "$1" '{ticket_id:"1",key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-13T02:30:00Z"}' > "$QD/$1.json"; }
chk() { HARNESS="$H" SIBLING_SERIAL_NOW=1791860000 "$@" 2>/dev/null; }

# C1: TK-185 queued, TK-184 on a pool machine, same file -> rc 3
reset
plan_files TK-184 "$NOTE" src/lib/a.ts
plan_files TK-185 "$NOTE" src/lib/meeting-notes/draft.ts
machine TK-184; queue TK-185
OUT=$(chk "$SS" check "$P" TK-185); RC=$?
[ "$RC" = 3 ] && [ "$OUT" = "SIBLING_SERIAL TK-185 waits for TK-184 on $NOTE" ] && ok \
  || bad "C1: TK-185 must wait for TK-184 on a board key (rc $RC, out '$OUT')"

# C2: TK-186 with no list while TK-185 is in flight
reset
plan_files TK-185 src/lib/meeting-notes/draft.ts
machine TK-185; queue TK-186
OUT=$(chk "$SS" check "$P" TK-186); RC=$?
[ "$RC" = 3 ] && [ "$OUT" = "SIBLING_SERIAL TK-186 waits for TK-185 on (no pre-plan list)" ] && ok \
  || bad "C2: a no-list part waits for a sibling in flight (rc $RC, out '$OUT')"

# C3: TK-201 of another parent shares the path -> go
reset
plan_files TK-184 "$NOTE"
plan_files TK-201 "$NOTE"
machine TK-184; queue TK-201
OUT=$(chk "$SS" check "$P" TK-201); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C3: a part of another parent is not held (rc $RC, out '$OUT')"
# … and a key in no record is never judged
plan_files TK-300 "$NOTE"; queue TK-300
OUT=$(chk "$SS" check "$P" TK-300); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C3: a key in no record is not a part (rc $RC, out '$OUT')"

# C4: the row's own stack base PR does not hold it
reset
plan_files TK-186 "$NOTE"
queue TK-186
jq -nc --arg f "$NOTE" '[{number:210, headRefName:"ticket/TK-184", isDraft:false, files:[{path:$f}]}]' \
  > "$H/state/overlap-guard/$P-prs.json"
OUT=$(chk "$SS" check "$P" TK-186); RC=$?
[ "$RC" = 3 ] && [ "$OUT" = "SIBLING_SERIAL TK-186 waits for TK-184 on $NOTE stackable base=ticket/TK-184" ] && ok \
  || bad "C4 control: the open PR of TK-184 holds TK-186, stackable (rc $RC, out '$OUT')"
OUT=$(chk env SIBLING_STACK_BASE=ticket/TK-184 "$SS" check "$P" TK-186); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C4: the PR the row stacks on must not hold it (rc $RC, out '$OUT')"
OUT=$(chk env SIBLING_STACK=0 "$SS" check "$P" TK-186); RC=$?
[ "$RC" = 3 ] && [ "$OUT" = "SIBLING_SERIAL TK-186 waits for TK-184 on $NOTE" ] && ok \
  || bad "C4: SIBLING_STACK=0 is a plain wait, no stackable suffix (rc $RC, out '$OUT')"

# C5: the real bin/overlap-schedule.sh over TK-184 and TK-185
reset
plan_files TK-184 "$NOTE" src/lib/a.ts
plan_files TK-185 "$NOTE" src/lib/meeting-notes/draft.ts
printf 'TK-184\t184\tahead\nMK-185\t185\tahead\n' > "$H/state/preplan-candidates/$P.tsv"
OUT=$(HARNESS="$H" "$H/bin/overlap-schedule.sh" "$P" 2>/dev/null)
has C5 "HELD: TK-185 waits for sibling TK-184 on $NOTE (SIBLING_SERIAL)" "$OUT"
grep -qxF 'WAVE 1: TK-184' <<<"$OUT" && ok || bad "C5: WAVE 1 must be TK-184 alone, got: $OUT"

# ── R: the replay ────────────────────────────────────────────────────────────
# The project-6 sets from the ticket, as the first PR of each child changed them.
AW=src/components/agent-workspace
WF=src/app/os/workflows/[id]
cat > "$T/rparts" <<EOF
TK-169	TK-142	0
TK-170	TK-142	1
TK-171	TK-142	2
TK-172	TK-142	3
TK-173	TK-142	4
TK-163	TK-138	0
TK-164	TK-138	1
TK-165	TK-138	2
TK-166	TK-138	3
TK-167	TK-138	4
TK-183	TK-145	0
TK-184	TK-145	1
TK-185	TK-145	2
TK-186	TK-145	3
TK-152	TK-60	0
TK-153	TK-60	1
TK-154	TK-60	2
TK-155	TK-60	3
TK-156	TK-60	4
EOF
row() { local k="$1" f; shift; for f in "$@"; do printf '%s\tqueued\t%s\n' "$k" "$f"; done; }
{
  row TK-170 src/app/os/page.tsx prisma/schema/gmail-connector.prisma
  row TK-171 src/app/os/page.tsx src/components/home/business-overview.css
  row TK-172 src/app/os/page.tsx src/components/home/range-pill.css
  row TK-173 src/app/os/page.tsx src/components/home/kpi-deep-dive.css package.json
  row TK-164 $AW/review-edit.tsx $AW/review-feedback.tsx $AW/board.tsx $AW/review-autonomy.tsx "src/app/api/os/work/review/[itemId]/route.ts"
  row TK-165 $AW/review-edit.tsx prisma/schema/task-edit.prisma
  row TK-166 $AW/review-feedback.tsx prisma/schema/task-revision.prisma
  row TK-167 $AW/board.tsx $AW/review-autonomy.tsx "src/app/api/os/agents/[id]/route.ts"
  row TK-184 "$NOTE" tests/unit/meeting-notes.TK-145.test.ts scripts/checks/company-query.mjs
  row TK-185 src/lib/meeting-notes/draft.ts tests/unit/company-query-companytx.TK-185.test.ts
  row TK-186 "$NOTE" src/lib/meeting-notes/draft.ts tests/unit/meeting-notes.TK-145.test.ts prisma/schema/gmail-connector.prisma
  row TK-153 "src/app/api/os/workflows/[id]/try/route.ts"
  row TK-154 "$WF/live-slot.tsx" "$WF/edit-slot.tsx" "src/app/api/os/workflows/[id]/route.ts"
  row TK-155 "$WF/live-slot.tsx" prisma/schema/workflow-schedule.prisma
  row TK-156 "$WF/live-slot.tsx" "$WF/edit-slot.tsx" "src/app/api/os/workflows/tasks/[taskId]/done/route.ts"
} > "$T/rrows"
rep() { IGNORE='package.json package-lock.json *.md' "$SS" replay "$@" 2>/dev/null; }
OUT=$(rep "$T/rrows" "$T/rparts"); RC=$?
[ "$RC" = 0 ] && ok || bad "R: replay must exit 0 (rc $RC)"
has R1 "REPLAY TK-142 parts=4 waves=4 order=TK-170 > TK-171 > TK-172 > TK-173 nolist=0 added_cycles=3" "$OUT"
has R2 "REPLAY TK-138 parts=4 waves=2 order=TK-164 > TK-165,TK-166,TK-167 nolist=0 added_cycles=1" "$OUT"
has R3 "REPLAY TK-145 parts=3 waves=2 order=TK-184,TK-185 > TK-186 nolist=0 added_cycles=1" "$OUT"
has R3 "REPLAY TK-60 parts=4 waves=3 order=TK-153,TK-154 > TK-155 > TK-156 nolist=0 added_cycles=2" "$OUT"
has R3 "REPLAY_TOTAL parents=4 parts=15 nolist_waits=0 fallback_pct=0" "$OUT"
# No two keys in one wave share a path: the "no add/add" half of the replay.
python3 - "$T/rrows" "$OUT" <<'PYEOF' && ok || bad "R3: two keys in one wave share a path"
import sys, collections
files = collections.defaultdict(set)
for l in open(sys.argv[1]):
    k, _, p = l.rstrip("\n").split("\t")
    if p != "package.json":
        files[k].add(p)
for l in sys.argv[2].splitlines():
    if not l.startswith("REPLAY "):
        continue
    order = l.split(" order=")[1].split(" nolist=")[0]
    for wave in order.split(" > "):
        ks = wave.split(",")
        for i, a in enumerate(ks):
            for b in ks[i + 1:]:
                if files[a] & files[b]:
                    sys.exit(1)
PYEOF

# R4: TK-186 with no list waits for the wave in flight, and is counted
grep -v '^TK-186' "$T/rrows" > "$T/rrows4"; printf 'TK-186\tqueued\t\n' >> "$T/rrows4"
OUT=$(rep "$T/rrows4" "$T/rparts")
has R4 "REPLAY TK-145 parts=3 waves=2 order=TK-184,TK-185 > TK-186 nolist=1 added_cycles=1" "$OUT"
has R4 "REPLAY_TOTAL parents=4 parts=15 nolist_waits=1 fallback_pct=6" "$OUT"

# R5: --project mode reads the records and plan lists on this box
reset
for k in TK-184 TK-185 TK-186; do
  awk -F'\t' -v k="$k" '$1 == k {print $3}' "$T/rrows" > "$T/l"
  mkdir -p "$H/plans/$P-$k"; cp "$T/l" "$H/plans/$P-$k/planned-files.txt"
done
OUT=$(HARNESS="$H" "$SS" replay --project "$P" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "R5: replay --project must exit 0 (rc $RC)"
has R5 "REPLAY TK-145 parts=3 waves=2 order=TK-184,TK-185 > TK-186 nolist=0 added_cycles=1" "$OUT"
# TK-201 (parent TK-199) has no list on this box: it is counted, not hidden
has R5 "REPLAY TK-199 parts=1 waves=1 order=TK-201 nolist=0 added_cycles=0" "$OUT"
grep -q '^REPLAY_TOTAL parents=2 parts=4 ' <<<"$OUT" && ok || bad "R5: total line, got: $OUT"
OUT=$(HARNESS="$H" "$SS" replay --project "$P" --last 1 2>/dev/null)
[ "$(grep -c '^REPLAY M' <<<"$OUT")" = 1 ] && ok || bad "R5: --last 1 replays one parent, got: $OUT"
HARNESS="$H" "$SS" replay >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "R5: replay with no arguments is a usage error (rc $RC)"

echo "sibling-serial-parts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
