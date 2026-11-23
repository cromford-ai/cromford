#!/bin/bash
# tests/mc/settle-offlist-all-states.bh-9897-test.sh — the off-list settle
# (mc_settle_offlist_rows, bin/lib/mc/settle.sh) moves the row of a PR memo'd
# `merged` to MERGED from every live state but QUEUED (BH-9897).
#
# THE INCIDENT (2026-11-22). 962 of 1,133 live conductor rows belonged to PRs
# that were merged or closed. The settle read only READY and WAIT_CI rows, so a
# PR that merged while its row was HEAD_MOVED, BLOCKED_HUMAN,
# NEEDS_HUMAN_VERDICT, ... kept that state for good.
#
#   A1  one row per MC_STATES word, each memo'd merged, off the open list, one
#       apply pass: every live state but QUEUED ends MERGED; QUEUED stays
#       QUEUED; MERGED/CLOSED/ABANDONED lines are byte-identical; a state word
#       not in MC_STATES (FOO) is not moved
#   A2  the moves are row-only: reason `merged outside the conductor
#       (closed-watch)`, no deployreq attempt line, 0 gh and 0 curl calls
#   A3  HEAD_MOVED and BLOCKED_HUMAN with a `closed` memo: epoch = since and
#       epoch > since move to CLOSED; epoch < since is skipped
#   A4  HEAD_MOVED with a `gone` memo is not moved, the skip line names it
#   A5  a merged memo on a row whose number is on the open list is not moved;
#       the same number in another repo and the prefix slug `demox` are not
#   C1  mc_classify OPEN UNKNOWN, prev NEEDS_HUMAN_VERDICT keeps the prior state
#   C2  mc_classify with a pstate that is not OPEN and UNKNOWN never keeps it
#   C3  end to end through the conductor fragment mc_offlist_settle_tick: a
#       NEEDS_HUMAN_VERDICT row "mergeState unknown, keeping prior state",
#       off-list, memo'd merged, ends MERGED
# Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_mc_harness "$DIR" "$T" || exit 1
mkdir -p "$T/h/bin/merge-conductor.d" || exit 1
cp "$DIR/bin/merge-conductor.d/bh-8310-stale-row-settle.sh" "$T/h/bin/merge-conductor.d/" || exit 1
for b in gh curl; do printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/%s-calls.txt"\nexit 1\n' "$T" "$b" > "$T/fakebin/$b"; chmod +x "$T/fakebin/$b"; done
: > "$T/gh-calls.txt"; : > "$T/curl-calls.txt"
export PATH="$T/fakebin:$PATH" HARNESS="$T/h" JOBS_URL=
# shellcheck source=bin/lib/merge-conductor-lib.sh
. "$T/h/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: cannot load the conductor lib"; exit 1; }
# shellcheck source=bin/merge-conductor.d/bh-8310-stale-row-settle.sh
. "$T/h/bin/merge-conductor.d/bh-8310-stale-row-settle.sh" || exit 1
MC_CLOSED_WATCH_DIR="$MC_STATE_DIR/closed-watch"; MC_ONLY_KEYS=; P=
mkdir -p "$(dirname "$MC_ROWS")" "$MC_H/logs" || exit 1
CW="$MC_CLOSED_WATCH_DIR"
HD=$(printf 'e%.0s' $(seq 40))
reset() { : > "$MC_ROWS"; scratch_rm "$CW"; mkdir -p "$CW/example-org_demo" "$CW/example-org_other" "$CW/example-org_demox"; : > "$MC_H/logs/merge-conductor.log"; : > "$MC_ATTEMPTS" 2>/dev/null || true; }
row()  { printf '%s#%s\t%s\t%s\t%s\t%s\t-\t%s\thttps://github.com/%s/pull/%s\n' "$1" "$2" "$3" "${4:-100}" "$HD" "$HD" "${5:-clean}" "$1" "$2" >> "$MC_ROWS"; }
memo() { printf '%s\t%s\thttps://github.com/example-org/%s/pull/%s\tticket/x-%s\n' "$3" "$4" "$1" "$2" "$2" > "$CW/example-org_$1/$2"; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$MC_ROWS"; }
line_of()  { awk -F'\t' -v k="$1" '$1==k' "$MC_ROWS"; }
settle()   { mc_settle_offlist_rows example-org/demo "${1:-}" apply > "$T/out" 2>"$T/err"; }

# ============================================================================
# A1. One row per MC_STATES word, each memo'd merged.
# ============================================================================
reset
i=0; declare -A NUM=()
for s in $MC_STATES FOO; do
  i=$((i + 1)); NUM[$s]=$((500 + i))
  row example-org/demo "${NUM[$s]}" "$s"; memo demo "${NUM[$s]}" merged 200
done
for s in MERGED CLOSED ABANDONED; do line_of "example-org/demo#${NUM[$s]}" > "$T/before.$s"; done
settle
for s in $MC_STATES FOO; do
  k="example-org/demo#${NUM[$s]}"; got=$(state_of "$k")
  case "$s" in
    QUEUED|FOO) [ "$got" = "$s" ] && ok || bad "A1 $s + merged memo must stay $s (row: $got)" ;;
    MERGED|CLOSED|ABANDONED)
      [ "$(line_of "$k")" = "$(cat "$T/before.$s")" ] && ok || bad "A1 terminal $s line must be byte-identical (row: $(line_of "$k"))" ;;
    *)  [ "$got" = MERGED ] && ok || bad "A1 $s + merged memo must end MERGED (row: $got; out: $(grep "$k " "$T/out"))"
        grep -qxF "STALE-ROW $k $s -> MERGED memo=merged (applied)" "$T/out" && ok || bad "A1 $s: one applied line (out: $(grep "$k " "$T/out"))" ;;
  esac
done
[ "$(grep -c '(applied)$' "$T/out")" = 12 ] && ok || bad "A1 12 live states moved (got $(grep -c '(applied)$' "$T/out"))"

# ============================================================================
# A2. Row-only: the reason, no deployreq, 0 vendor calls.
# ============================================================================
[ "$(grep -c 'reason=merged outside the conductor (closed-watch)' "$MC_H/logs/merge-conductor.log")" = 12 ] && ok \
  || bad "A2 each move carries the closed-watch reason: $(grep -c 'reason=merged outside' "$MC_H/logs/merge-conductor.log")"
grep -q '^deployreq ' "$MC_ATTEMPTS" 2>/dev/null && bad "A2 a row-only settle must write no deployreq: $(grep deployreq "$MC_ATTEMPTS")" || ok
grep -qi deploy <<<"$(ls "$MC_STATE_DIR")" && bad "A2 a row-only settle must write no deploy file: $(ls "$MC_STATE_DIR")" || ok
grep -q 'MERGED .* by conductor' "$MC_H/logs/merge-conductor.log" && bad "A2 conductor_settle must not run" || ok

# ============================================================================
# A3. The closed rule for parked states.
# ============================================================================
reset
row example-org/demo 601 HEAD_MOVED 100;    memo demo 601 closed 100   # epoch = since
row example-org/demo 602 HEAD_MOVED 100;    memo demo 602 closed 150   # epoch > since
row example-org/demo 603 HEAD_MOVED 100;    memo demo 603 closed 50    # epoch < since
row example-org/demo 611 BLOCKED_HUMAN 100; memo demo 611 closed 100
row example-org/demo 612 BLOCKED_HUMAN 100; memo demo 612 closed 150
row example-org/demo 613 BLOCKED_HUMAN 100; memo demo 613 closed 50
settle
for n in 601 602 611 612; do [ "$(state_of "example-org/demo#$n")" = CLOSED ] && ok || bad "A3 #$n closed memo at/after since must be CLOSED (row: $(state_of "example-org/demo#$n"))"; done
[ "$(state_of example-org/demo#603)" = HEAD_MOVED ] && ok || bad "A3 #603 closed memo older than since must stay"
[ "$(state_of example-org/demo#613)" = BLOCKED_HUMAN ] && ok || bad "A3 #613 closed memo older than since must stay"
for e in '#603 HEAD_MOVED' '#613 BLOCKED_HUMAN'; do
  grep -qxF "STALE-ROW example-org/demo$e -> - memo=closed (skipped: memo older than the row, PR may be reopened)" "$T/out" && ok || bad "A3 skip line for $e (out: $(cat "$T/out"))"
done

# ============================================================================
# A4. gone moves nothing.
# ============================================================================
reset
row example-org/demo 701 HEAD_MOVED; memo demo 701 gone 200
row example-org/demo 702 HEAD_MOVED; memo demo 702 open 200
row example-org/demo 703 HEAD_MOVED; memo demo 703 open 0
row example-org/demo 704 HEAD_MOVED
cp "$MC_ROWS" "$T/rows.a4"
settle
cmp -s "$T/rows.a4" "$MC_ROWS" && ok || bad "A4 gone/open/no memo must move nothing"
grep -qxF 'STALE-ROW example-org/demo#701 HEAD_MOVED -> - memo=gone (skipped: 404 is not proof of a close)' "$T/out" && ok || bad "A4 gone skip line (out: $(cat "$T/out"))"

# ============================================================================
# A5. On the open list, other repo, prefix slug.
# ============================================================================
reset
row example-org/demo 801 HEAD_MOVED;  memo demo 801 merged 200
row example-org/other 802 HEAD_MOVED                       # demo's 802 memo below
memo demo 802 merged 200
row example-org/demox 803 HEAD_MOVED; memo demox 803 merged 200
cp "$MC_ROWS" "$T/rows.a5"
settle "801 5"
cmp -s "$T/rows.a5" "$MC_ROWS" && ok || bad "A5 open-list / other repo / prefix slug must move nothing (rows: $(cut -f1,2 "$MC_ROWS" | tr '\n' ' '))"

# ============================================================================
# C1-C2. mc_classify UNKNOWN arm.
# ============================================================================
H1=$HD
c() { mc_classify "$@" | cut -f1; }
[ "$(c OPEN UNKNOWN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 NEEDS_HUMAN_VERDICT -)" = NEEDS_HUMAN_VERDICT ] && ok || bad "C1 OPEN + UNKNOWN keeps the prior state"
[ "$(c OPEN UNKNOWN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = WAIT_CI ] && ok || bad "C1 OPEN + UNKNOWN with no prior is WAIT_CI"
for ps in "" "-"; do
  out=$(mc_classify "$ps" UNKNOWN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 NEEDS_HUMAN_VERDICT -)
  [ "${out%%$'\t'*}" = WAIT_CI ] && ok || bad "C2 pstate '$ps' + UNKNOWN must not keep NEEDS_HUMAN_VERDICT (got: $out)"
  case "$out" in *"off-list settle owns this row"*) ok ;; *) bad "C2 pstate '$ps' reason names the settle (got: $out)" ;; esac
done
[ "$(c MERGED UNKNOWN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 BLOCKED_HUMAN -)" = MERGED ] && ok || bad "C2 MERGED stays terminal"

# ============================================================================
# C3. End to end through the conductor fragment.
# ============================================================================
reset
row example-org/demo 5 NEEDS_HUMAN_VERDICT 100 'mergeState unknown, keeping prior state'
memo demo 5 merged 200
mc_offlist_settle_tick example-org/demo "20 21"
[ "$(state_of example-org/demo#5)" = MERGED ] && ok || bad "C3 the NHV row of a merged off-list PR must end MERGED (row: $(state_of example-org/demo#5))"

# 0 vendor calls over the whole suite (A2).
[ -s "$T/gh-calls.txt" ] && bad "A2 the settle called gh: $(head -2 "$T/gh-calls.txt")" || ok
[ -s "$T/curl-calls.txt" ] && bad "A2 the settle called curl: $(head -2 "$T/curl-calls.txt")" || ok

echo "settle-offlist-all-states.bh-9897-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
