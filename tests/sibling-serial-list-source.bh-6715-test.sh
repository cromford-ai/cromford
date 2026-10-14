#!/bin/bash
# tests/sibling-serial-list-source.bh-6715-test.sh — where bin/sibling-serial.sh
# got each part's file list, and why a part had none (BH-6715).
#
# THE DEFECT. A part with no list waits for every sibling in flight. 50% of
# cromford parts and 65% of project-5 parts waited that way, and nothing
# said why: an unreachable pre-plan index read exactly like "no list".
#
#   S1-S3   preplan_planned_files: rc 2 = could not ask, rc 1 = asked, no row
#   S4-S7   files_of through replay --project: build-planned, build-touch,
#           index-unreachable, no-plan (REPLAY_SOURCES and REPLAY_CAUSE)
#   S8      check prints ONE `list sources:` note line
#   S9      a build record with plan.md and no list = empty-list
#   S10     the cause counts sum to nolist_waits; a part that waits on a
#           listless sibling counts the SIBLING's cause
#   S11     pure replay with no causes file: every no-list wait is unknown
#   S12     replay with no arguments is still rc 2
#
# No network, no gh. Run: HARNESS_TEST_SANDBOX=1 bash tests/sibling-serial-list-source.bh-6715-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
TAB=$'\t'
P=proj

H="$T/h"
mkdir -p "$H/bin" "$H/env" "$H/flags" "$H/logs" "$H/plans" "$H/builds" "$H/locks" \
         "$H/state/fly-pool/$P" "$H/state/build-queue/$P"
: > "$H/env/global.env"
scratch_install_closure bin/sibling-serial.sh "$H" >/dev/null || { echo "closure install of bin/sibling-serial.sh failed"; exit 1; }
printf '%s  example-org/proj   -  -  0 local -\n' "$P" > "$H/fleet.conf"
SS="$H/bin/sibling-serial.sh"
[ ! -e "$H/bin/jobs-client.sh" ] || { echo "the closure installed bin/jobs-client.sh; the index-down cases need it absent"; exit 1; }

# index_up [row]: a stub client whose preplan_index answers (with the row, if any)
index_up() {
  { echo 'preplan_get() { return 1; }'
    printf 'preplan_index() { printf %%s %q; return 0; }\n' "${1:-}"; } > "$H/bin/jobs-client.sh"
}
index_err() { printf 'preplan_get() { return 1; }\npreplan_index() { return 1; }\n' > "$H/bin/jobs-client.sh"; }
index_down() { rm -f "$H/bin/jobs-client.sh"; }
ppf() { bash -c '. "$1/bin/lib/preplan-lib.sh" || exit 9; preplan_planned_files "$1" "$2" "$3"' _ "$H" "$P" "$1"; }

# ── S1-S3: preplan_planned_files ─────────────────────────────────────────────
index_down
OUT=$(ppf TK-11); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "S1: no jobs client is rc 2, got rc $RC out '$OUT'"
index_err
OUT=$(ppf TK-11); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "S2: an index that does not answer is rc 2, got rc $RC out '$OUT'"
index_up ""
OUT=$(ppf TK-11); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "S3: an index with no row is rc 1, got rc $RC out '$OUT'"
index_up "TK-11${TAB}-${TAB}-${TAB}src/x.ts|src/y.ts"
OUT=$(ppf TK-11); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = $'src/x.ts\nsrc/y.ts' ] && ok || bad "S3: a row is rc 0 with the list, got rc $RC out '$OUT'"
index_down

# ── the parent and its parts ─────────────────────────────────────────────────
#   TK-10 n0 contract (replay skips it)
#   TK-11 n1 no record anywhere
#   TK-12 n2 build record, planned-files.txt only            -> build-planned
#   TK-13 n3 pool build record, touch-source=declared        -> build-touch
#   TK-14 n4 build record with plan.md and no list           -> empty-list
mkdir -p "$H/builds/pool-$P-TK-1-20261014000000"
printf 'DECOMPOSED TK-10,TK-11,TK-12,TK-13,TK-14\n' > "$H/builds/pool-$P-TK-1-20261014000000/RESULT"
mkdir -p "$H/builds/$P-TK-12-20261014000000"
printf 'src/a.ts\n' > "$H/builds/$P-TK-12-20261014000000/planned-files.txt"
mkdir -p "$H/builds/pool-$P-TK-13-20261014000000"
printf 'declared\n' > "$H/builds/pool-$P-TK-13-20261014000000/touch-source"
printf 'src/b.ts\n' > "$H/builds/pool-$P-TK-13-20261014000000/touch-files.txt"
printf 'src/a.ts\n' > "$H/builds/pool-$P-TK-13-20261014000000/planned-files.txt"
mkdir -p "$H/builds/$P-TK-14-20261014000000"
printf '# plan\nno paths here\n' > "$H/builds/$P-TK-14-20261014000000/plan.md"

rep() { HARNESS="$H" "$SS" replay --project "$P" 2>/dev/null; }
line() { grep -E "^$1( |\$)" <<<"$2"; }
has() { grep -qxF "$2" <<<"$3" && ok || bad "$1: expected line '$2', got: $3"; }

# ── S4-S6, S9, S10: index unreachable ────────────────────────────────────────
OUT=$(rep); RC=$?
[ "$RC" = 0 ] && ok || bad "S4: replay --project exits 0 (rc $RC)"
# TK-13's list is its touch list (src/b.ts), not planned-files.txt (src/a.ts):
# with src/a.ts it would collide with TK-12 and take its own wave.
has S5 "REPLAY TK-1 parts=4 waves=3 order=TK-11 > TK-12,TK-13 > TK-14 nolist=3 added_cycles=2" "$OUT"
has S4 "REPLAY_SOURCES plans-dir=0 preplan-index=0 build-touch=1 build-planned=1 none=2" "$OUT"
has S6 "REPLAY_CAUSE index-unreachable waits=2 pct=50" "$OUT"
has S9 "REPLAY_CAUSE empty-list waits=1 pct=25" "$OUT"
has S10 "REPLAY_CAUSE no-plan waits=0 pct=0" "$OUT"
has S10 "REPLAY_CAUSE unknown waits=0 pct=0" "$OUT"
has S10 "REPLAY_TOTAL parents=1 parts=4 nolist_waits=3 fallback_pct=75" "$OUT"
# fixed order, right after REPLAY_TOTAL
ORD=$(grep -E '^REPLAY_(TOTAL|CAUSE|SOURCES)' <<<"$OUT" | awk '{print $1 ($1 == "REPLAY_CAUSE" ? " " $2 : "")}' | tr '\n' '|')
[ "$ORD" = "REPLAY_TOTAL|REPLAY_CAUSE no-plan|REPLAY_CAUSE index-unreachable|REPLAY_CAUSE empty-list|REPLAY_CAUSE unknown|REPLAY_SOURCES|" ] \
  && ok || bad "S10: line order, got $ORD"
SUM=$(grep '^REPLAY_CAUSE ' <<<"$OUT" | sed -E 's/.* waits=([0-9]+).*/\1/' | awk '{s += $1} END {print s + 0}')
NW=$(sed -nE 's/^REPLAY_TOTAL .* nolist_waits=([0-9]+).*/\1/p' <<<"$OUT")
[ -n "$NW" ] && [ "$SUM" = "$NW" ] && ok || bad "S10: cause waits ($SUM) must sum to nolist_waits ($NW)"

# ── S7: index reachable, no row ──────────────────────────────────────────────
index_up ""
OUT=$(rep)
has S7 "REPLAY_CAUSE no-plan waits=2 pct=50" "$OUT"
has S7 "REPLAY_CAUSE index-unreachable waits=0 pct=0" "$OUT"
has S7 "REPLAY_CAUSE empty-list waits=1 pct=25" "$OUT"

# … and an index row for TK-11 is its list: nobody waits on (no pre-plan list)
index_up "TK-11${TAB}-${TAB}-${TAB}src/c.ts"
OUT=$(rep)
has "S7 index row" "REPLAY_SOURCES plans-dir=0 preplan-index=1 build-touch=1 build-planned=1 none=1" "$OUT"
has "S7 index row" "REPLAY_CAUSE empty-list waits=1 pct=25" "$OUT"
has "S7 index row" "REPLAY_TOTAL parents=1 parts=4 nolist_waits=1 fallback_pct=25" "$OUT"
# the plans dir outranks the index
mkdir -p "$H/plans/$P-TK-11"; printf 'src/d.ts\n' > "$H/plans/$P-TK-11/planned-files.txt"
OUT=$(rep)
has "S7 plans dir" "REPLAY_SOURCES plans-dir=1 preplan-index=0 build-touch=1 build-planned=1 none=1" "$OUT"
scratch_rm "$H/plans/$P-TK-11"
index_down

# ── S8: check prints one list-sources line ───────────────────────────────────
jq -nc '{machine:"m",key:"TK-12",ticket_id:"1",attempt:1}' > "$H/state/fly-pool/$P/m-TK-12.json"
HARNESS="$H" SIBLING_SERIAL_NOW=1791860000 "$SS" check "$P" TK-13 >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "S8: TK-13 (src/b.ts) and TK-12 (src/a.ts) do not collide, rc $RC out $(cat "$T/out")"
N=$(grep -c 'list sources:' "$T/err")
[ "$N" = 1 ] && ok || bad "S8: exactly one list sources line, got $N: $(cat "$T/err")"
grep 'list sources:' "$T/err" | grep -qE 'list sources: TK-13=build-touch( |$)' && ok || bad "S8: KEY first with its source, got: $(grep 'list sources:' "$T/err")"
grep 'list sources:' "$T/err" | grep -qE ' TK-12=build-planned( |$)' && ok || bad "S8: the sibling's source, got: $(grep 'list sources:' "$T/err")"
# a listless key's cause is named too
HARNESS="$H" SIBLING_SERIAL_NOW=1791860000 "$SS" check "$P" TK-14 >"$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 3 ] && ok || bad "S8: TK-14 has no list and waits, rc $RC"
grep 'list sources:' "$T/err" | grep -qE 'list sources: TK-14=empty-list TK-12=build-planned$' && ok \
  || bad "S8: the cause is named, got: $(grep 'list sources:' "$T/err")"
rm -f "$H/state/fly-pool/$P/m-TK-12.json" "$H/state/sibling-serial/$P/TK-14.sibling-since"

# ── S11: pure replay, no causes file ─────────────────────────────────────────
printf 'TK-20\tMK-2\t0\nMK-21\tMK-2\t1\nMK-22\tMK-2\t2\n' > "$T/parts"
printf 'TK-21\tqueued\tsrc/a.ts\nMK-22\tqueued\t\n' > "$T/rows"
OUT=$(env -u CAUSES "$SS" replay "$T/rows" "$T/parts" 2>/dev/null)
has S11 "REPLAY_CAUSE unknown waits=1 pct=50" "$OUT"
has S11 "REPLAY_CAUSE no-plan waits=0 pct=0" "$OUT"
grep -q '^REPLAY_SOURCES' <<<"$OUT" && bad "S11: REPLAY_SOURCES is --project only: $OUT" || ok

# ── S12: usage ───────────────────────────────────────────────────────────────
HARNESS="$H" "$SS" replay >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "S12: replay with no arguments is rc 2 (rc $RC)"

echo "sibling-serial-list-source: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
