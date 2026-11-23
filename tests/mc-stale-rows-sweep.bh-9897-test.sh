#!/bin/bash
# tests/mc-stale-rows-sweep.bh-9897-test.sh — the hand-run sweep
# bin/mc-stale-rows-sweep.sh uses the off-list settle's state list, so it moves
# a merged PR's row from every live state but QUEUED (BH-9897).
#   W1  one row per live state (12, QUEUED excluded) memo'd merged: a dry run
#       prints one `(dry-run)` line per state word, the rows file stays
#       byte-identical and the conductor log stays empty
#   W2  QUEUED with a merged memo is not printed as a move
#   W3  --apply moves the 12, one `(applied)` line each and one STALE-ROW line
#       each in merge-conductor.log
#   W4  0 gh and 0 curl calls over W1-W3 and W5
#   W5  a fixture built from the ticket's hub table (937 merged memos, 25
#       closed memos newer than the row, 145 open, 15 gone, 11 no memo): one
#       --apply leaves 0 live rows with a merged memo (mc_merged_live_count)
#       and leaves the open, gone and no-memo rows as they were
# Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_mc_harness "$DIR" "$T" || exit 1
fx_conductor_tick "$DIR" "$T" || exit 1
cp "$DIR/bin/mc-stale-rows-sweep.sh" "$T/h/bin/" || exit 1
chmod +x "$T/h/bin/"*.sh || exit 1
: > "$T/h/env/global.env"
for b in gh curl; do printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/%s-calls.txt"\nexit 1\n' "$T" "$b" > "$T/fakebin/$b"; chmod +x "$T/fakebin/$b"; done
: > "$T/gh-calls.txt"; : > "$T/curl-calls.txt"

ROWS="$T/h/state/merge-conductor/pr-state.tsv"; CW="$T/h/state/merge-conductor/closed-watch"; LOG="$T/h/logs/merge-conductor.log"
mkdir -p "$(dirname "$ROWS")" "$CW/example-org_demo" "$CW/example-org_other" "$T/h/logs" || exit 1
HD=$(printf 'e%.0s' $(seq 40))
row()  { printf '%s#%s\t%s\t%s\t%s\t%s\t-\tclean\thttps://github.com/%s/pull/%s\n' "$1" "$2" "$3" "${4:-100}" "$HD" "$HD" "$1" "$2" >> "$ROWS"; }
memo() { printf '%s\t%s\thttps://github.com/example-org/%s/pull/%s\tticket/x-%s\n' "$3" "$4" "$1" "$2" "$2" > "$CW/example-org_$1/$2"; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ROWS"; }
sweep() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" JOBS_URL= bash "$T/h/bin/mc-stale-rows-sweep.sh" "$@" ) > "$T/out" 2>"$T/err"; echo $? > "$T/rc"; }
LIVE="WAIT_CI WAIT_REVIEW HEAD_MOVED NEEDS_REBASE REBASING BLOCKED_HUMAN NEEDS_HUMAN_VERDICT WAIT_LEAD WAIT_MIGRATION RED_TWICE READY STACKED_WAIT"

i=0
for s in $LIVE; do i=$((i + 1)); row example-org/demo $((100 + i)) "$s"; memo demo $((100 + i)) merged 200; done
row example-org/demo 199 QUEUED; memo demo 199 merged 200
cp "$ROWS" "$T/rows.before"

# W1. Dry run.
sweep
[ "$(cat "$T/rc")" = 0 ] && ok || bad "W1 dry run rc 0 (rc $(cat "$T/rc"); err: $(cat "$T/err"))"
cmp -s "$T/rows.before" "$ROWS" && ok || bad "W1 a dry run must leave the rows file byte-identical"
[ -s "$LOG" ] && bad "W1 a dry run must write nothing to the conductor log: $(head -2 "$LOG")" || ok
i=0
for s in $LIVE; do
  i=$((i + 1))
  grep -qxF "STALE-ROW example-org/demo#$((100 + i)) $s -> MERGED memo=merged (dry-run)" "$T/out" && ok || bad "W1 no dry-run line for $s (out: $(grep "#$((100 + i)) " "$T/out"))"
done
[ "$(grep -c '(dry-run)$' "$T/out")" = 12 ] && ok || bad "W1 12 dry-run lines (got $(grep -c '(dry-run)$' "$T/out"))"
grep -qxF 'stale-rows-sweep: 12 rows, 12 merged, 0 closed (dry)' "$T/out" && ok || bad "W1 totals: $(tail -1 "$T/out")"

# W2. QUEUED is the queue settle's.
grep -E '^STALE-ROW example-org/demo#199 .* -> MERGED' "$T/out" >/dev/null && bad "W2 QUEUED must not be offered: $(grep '#199' "$T/out")" || ok

# W3. --apply.
sweep --apply
[ "$(cat "$T/rc")" = 0 ] && ok || bad "W3 --apply rc 0 (rc $(cat "$T/rc"); err: $(cat "$T/err"))"
i=0
for s in $LIVE; do i=$((i + 1)); [ "$(state_of "example-org/demo#$((100 + i))")" = MERGED ] && ok || bad "W3 $s row must be MERGED"; done
[ "$(state_of example-org/demo#199)" = QUEUED ] && ok || bad "W3 QUEUED row must stay QUEUED"
[ "$(grep -c '(applied)$' "$T/out")" = 12 ] && ok || bad "W3 12 applied lines (got $(grep -c '(applied)$' "$T/out"))"
[ "$(grep -c 'STALE-ROW .*(applied)' "$LOG")" = 12 ] && ok || bad "W3 12 STALE-ROW audit lines in the conductor log (got $(grep -c 'STALE-ROW .*(applied)' "$LOG"))"

# W5. The hub table as a fixture.
: > "$ROWS"; scratch_rm "$CW"; mkdir -p "$CW/example-org_demo" "$CW/example-org_other"
n=1000
add() { # add <state> <count> <memo-word|-> <memo-epoch> [since]
  local k sl
  for k in $(seq 1 "$2"); do
    n=$((n + 1)); if [ $((n % 2)) = 0 ]; then sl=demo; else sl=other; fi
    row "example-org/$sl" "$n" "$1" "${5:-100}"
    [ "$3" = - ] || memo "$sl" "$n" "$3" "$4"
    printf '%s\t%s\n' "example-org/$sl#$n" "$1" >> "$T/w5.$3"
  done
}
add HEAD_MOVED 572 merged 200; add BLOCKED_HUMAN 149 merged 200; add WAIT_REVIEW 73 merged 200
add STACKED_WAIT 55 merged 200; add REBASING 44 merged 200; add NEEDS_REBASE 16 merged 200
add NEEDS_HUMAN_VERDICT 14 merged 200; add WAIT_LEAD 9 merged 200; add RED_TWICE 3 merged 200
add READY 1 merged 200; add WAIT_MIGRATION 1 merged 200
add HEAD_MOVED 1 closed 200; add BLOCKED_HUMAN 9 closed 200; add REBASING 1 closed 200
add RED_TWICE 5 closed 200; add WAIT_CI 9 closed 200
add HEAD_MOVED 100 open 200; add BLOCKED_HUMAN 45 open 0
add HEAD_MOVED 15 gone 200
add WAIT_REVIEW 11 - 0
[ "$(wc -l < "$ROWS")" = 1133 ] && ok || bad "W5 the fixture has 1,133 rows (got $(wc -l < "$ROWS"))"
# shellcheck source=bin/lib/mc-merged-live.sh
. "$DIR/bin/lib/mc-merged-live.sh" 2>/dev/null || bad "W5 bin/lib/mc-merged-live.sh must exist"
before=$(mc_merged_live_count "$ROWS" "$CW" 2>/dev/null | cut -f1)
[ "$before" = 937 ] && ok || bad "W5 937 live rows with a merged memo before the sweep (got '$before')"
sweep --apply
[ "$(cat "$T/rc")" = 0 ] && ok || bad "W5 --apply rc 0 (rc $(cat "$T/rc"); err: $(cat "$T/err"))"
grep -qxF 'stale-rows-sweep: 962 rows, 937 merged, 25 closed (apply)' "$T/out" && ok || bad "W5 totals: $(tail -1 "$T/out")"
after=$(mc_merged_live_count "$ROWS" "$CW" 2>/dev/null | cut -f1)
[ "$after" = 0 ] && ok || bad "W5 0 live rows with a merged memo after one --apply (got '$after')"
for w in merged closed open gone -; do
  case "$w" in merged) want=MERGED ;; closed) want=CLOSED ;; *) want= ;; esac
  wrong=0
  while IFS=$'\t' read -r k s; do
    got=$(state_of "$k"); [ "$got" = "${want:-$s}" ] || wrong=$((wrong + 1))
  done < "$T/w5.$w"
  [ "$wrong" = 0 ] && ok || bad "W5 memo '$w': $wrong row(s) not ${want:-unchanged}"
done

# W4. 0 vendor calls.
[ -s "$T/gh-calls.txt" ] && bad "W4 the sweep called gh: $(head -2 "$T/gh-calls.txt")" || ok
[ -s "$T/curl-calls.txt" ] && bad "W4 the sweep called curl: $(head -2 "$T/curl-calls.txt")" || ok

echo "mc-stale-rows-sweep.bh-9897-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
