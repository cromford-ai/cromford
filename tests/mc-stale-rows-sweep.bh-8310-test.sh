#!/bin/bash
# tests/mc-stale-rows-sweep.bh-8310-test.sh — the one-time sweep
# bin/mc-stale-rows-sweep.sh moves READY/WAIT_CI rows of PRs memo'd merged or
# closed to MERGED/CLOSED, dry-run first, one audit line per row (BH-8310).
#   W1  a run with no --apply prints one `(dry-run)` line per movable row and
#       leaves the rows file byte-identical
#   W2  the negatives are not moved and not printed as moves: QUEUED and
#       BLOCKED_HUMAN with a merged memo, an `open` memo, an `open 0` memo, a
#       `gone` memo (printed as skipped), a `closed` memo older than the
#       row's `since` (a reopened PR, printed as skipped), no memo, the same number in another
#       repo, a repo whose name starts with this repo's name
#   W3  --apply moves them, one `(applied)` line each, and the totals line counts them
#   W4  a second --apply moves nothing
#   W5  a rows file that cannot be read is rc 1
#   W6  the sweep makes 0 gh and 0 curl calls
# Run from anywhere: tests/mc-stale-rows-sweep.bh-8310-test.sh
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
fx_conductor_tick "$DIR" "$T" || exit 1   # bin/jobs-client.sh and its modules (the pr_state ledger mirror)
cp "$DIR/bin/mc-stale-rows-sweep.sh" "$T/h/bin/" || exit 1
chmod +x "$T/h/bin/"*.sh || exit 1
: > "$T/h/env/global.env"
for b in gh curl; do printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/%s-calls.txt"\nexit 1\n' "$T" "$b" > "$T/fakebin/$b"; chmod +x "$T/fakebin/$b"; done
: > "$T/gh-calls.txt"; : > "$T/curl-calls.txt"

ROWS="$T/h/state/merge-conductor/pr-state.tsv"; CW="$T/h/state/merge-conductor/closed-watch"
mkdir -p "$(dirname "$ROWS")" "$CW/example-org_demo" "$CW/example-org_other" || exit 1
HD=$(printf 'e%.0s' $(seq 40))
row()  { printf '%s#%s\t%s\t%s\t%s\t%s\t-\tclean\thttps://github.com/%s/pull/%s\n' "$1" "$2" "$3" "${4:-100}" "$HD" "$HD" "$1" "$2" >> "$ROWS"; }
memo() { printf '%s\t%s\thttps://github.com/example-org/%s/pull/%s\tticket/x-%s\n' "$3" "$4" "$1" "$2" "$2" > "$CW/example-org_$1/$2"; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ROWS"; }
sweep() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" JOBS_URL= bash "$T/h/bin/mc-stale-rows-sweep.sh" "$@" ) > "$T/out" 2>"$T/err"; echo $? > "$T/rc"; }

# Movable.
row example-org/demo 901 READY;   memo demo 901 merged 1700000000
row example-org/demo 902 WAIT_CI; memo demo 902 merged 1700000000
row example-org/demo 903 READY;   memo demo 903 closed 1700000000
row example-org/demo 904 WAIT_CI; memo demo 904 closed 1700000000
# Not movable.
row example-org/demo 910 QUEUED;        memo demo 910 merged 1700000000
row example-org/demo 911 BLOCKED_HUMAN; memo demo 911 merged 1700000000
row example-org/demo 912 READY;         memo demo 912 open 1700000000
row example-org/demo 913 READY;         memo demo 913 open 0
row example-org/demo 914 READY;         memo demo 914 gone 1700000000
row example-org/demo 915 READY
row example-org/demo 916 READY 1800000000; memo demo 916 closed 1700000000   # reopened after the close probe
row example-org/other 901 READY                     # demo's #901 is merged; other's #901 has no memo
row example-org/demox 902 READY                     # a slug that starts with "example-org/demo"
MOVE="example-org/demo#901 example-org/demo#902 example-org/demo#903 example-org/demo#904"
KEEP="example-org/demo#910=QUEUED example-org/demo#911=BLOCKED_HUMAN example-org/demo#912=READY example-org/demo#913=READY example-org/demo#914=READY example-org/demo#915=READY example-org/demo#916=READY example-org/other#901=READY example-org/demox#902=READY"
cp "$ROWS" "$T/rows.before"

# ============================================================================
# W1. Dry run.
# ============================================================================
sweep
[ "$(cat "$T/rc")" = 0 ] && ok || bad "W1 a dry run is rc 0 (rc $(cat "$T/rc"); err: $(cat "$T/err"))"
cmp -s "$T/rows.before" "$ROWS" && ok || bad "W1 a dry run must leave the rows file byte-identical"
[ -s "$T/h/logs/merge-conductor.log" ] && bad "W1 a dry run must write nothing to the conductor log: $(head -2 "$T/h/logs/merge-conductor.log")" || ok
[ "$(grep -c '(dry-run)$' "$T/out")" = 4 ] && ok || bad "W1 one dry-run line per movable row (got: $(cat "$T/out"))"
for e in 'example-org/demo#901 READY -> MERGED memo=merged' 'example-org/demo#902 WAIT_CI -> MERGED memo=merged' \
         'example-org/demo#903 READY -> CLOSED memo=closed' 'example-org/demo#904 WAIT_CI -> CLOSED memo=closed'; do
  grep -qxF "STALE-ROW $e (dry-run)" "$T/out" && ok || bad "W1 missing line: STALE-ROW $e (dry-run) (out: $(cat "$T/out"))"
done
grep -qxF 'stale-rows-sweep: 4 rows, 2 merged, 2 closed (dry)' "$T/out" && ok || bad "W1 totals line: $(tail -1 "$T/out")"

# ============================================================================
# W2. Negatives: not printed as moves, not changed.
# ============================================================================
for kv in $KEEP; do
  k=${kv%%=*}
  grep -E "^STALE-ROW $k .* -> (MERGED|CLOSED)" "$T/out" >/dev/null && bad "W2 $k must not be offered as a move: $(grep "$k " "$T/out")" || ok
done
grep -qxF 'STALE-ROW example-org/demo#914 READY -> - memo=gone (skipped: 404 is not proof of a close)' "$T/out" && ok \
  || bad "W2 a gone memo is named as skipped (out: $(grep '#914' "$T/out"))"
grep -qxF 'STALE-ROW example-org/demo#916 READY -> - memo=closed (skipped: memo older than the row, PR may be reopened)' "$T/out" && ok \
  || bad "W2 a closed memo older than the row is named as skipped (out: $(grep '#916' "$T/out"))"

# ============================================================================
# W3. --apply.
# ============================================================================
sweep --apply
[ "$(cat "$T/rc")" = 0 ] && ok || bad "W3 --apply is rc 0 (rc $(cat "$T/rc"); err: $(cat "$T/err"))"
for k in example-org/demo#901 example-org/demo#902; do [ "$(state_of "$k")" = MERGED ] && ok || bad "W3 $k must be MERGED (row: $(state_of "$k"))"; done
for k in example-org/demo#903 example-org/demo#904; do [ "$(state_of "$k")" = CLOSED ] && ok || bad "W3 $k must be CLOSED (row: $(state_of "$k"))"; done
for kv in $KEEP; do
  [ "$(state_of "${kv%%=*}")" = "${kv#*=}" ] && ok || bad "W3 ${kv%%=*} must stay ${kv#*=} (row: $(state_of "${kv%%=*}"))"
done
[ "$(grep -c '(applied)$' "$T/out")" = 4 ] && ok || bad "W3 one applied line per moved row (got: $(cat "$T/out"))"
grep -qxF 'stale-rows-sweep: 4 rows, 2 merged, 2 closed (apply)' "$T/out" && ok || bad "W3 totals line: $(tail -1 "$T/out")"
[ "$(grep -c 'STALE-ROW .*(applied)' "$T/h/logs/merge-conductor.log")" = 4 ] && ok || bad "W3 each applied row is logged once in merge-conductor.log"
grep -q 'example-org/demo#901 READY -> MERGED .*reason=merged outside the conductor (closed-watch)' "$T/h/logs/merge-conductor.log" && ok \
  || bad "W3 the transition carries its reason: $(grep '#901' "$T/h/logs/merge-conductor.log")"
[ "$(awk -F'\t' '$1=="example-org/demo#901" {print $4}' "$ROWS")" = "$HD" ] && ok || bad "W3 the moved row keeps its head"

# ============================================================================
# W4. Idempotent.
# ============================================================================
cp "$ROWS" "$T/rows.after3"
sweep --apply
cmp -s "$T/rows.after3" "$ROWS" && ok || bad "W4 a second --apply must change nothing"
grep -qxF 'stale-rows-sweep: 0 rows, 0 merged, 0 closed (apply)' "$T/out" && ok || bad "W4 totals line: $(tail -1 "$T/out")"

# ============================================================================
# W6. 0 gh and 0 curl calls over W1-W4.
# ============================================================================
[ -s "$T/gh-calls.txt" ] && bad "W6 the sweep called gh: $(head -2 "$T/gh-calls.txt")" || ok
[ -s "$T/curl-calls.txt" ] && bad "W6 the sweep called curl: $(head -2 "$T/curl-calls.txt")" || ok

# ============================================================================
# W5. An unreadable rows file is rc 1.
# ============================================================================
mv "$ROWS" "$T/rows.saved"; mkdir "$ROWS"
sweep
[ "$(cat "$T/rc")" = 1 ] && ok || bad "W5 a rows path that is not a readable file must be rc 1 (rc $(cat "$T/rc"))"
rmdir "$ROWS"
sweep --apply
[ "$(cat "$T/rc")" = 1 ] && ok || bad "W5 a missing rows file must be rc 1 (rc $(cat "$T/rc"))"
[ -e "$ROWS" ] && bad "W5 the sweep must not create a rows file" || ok
sweep --bogus
[ "$(cat "$T/rc")" = 2 ] && ok || bad "W5 an unknown flag is a usage error, rc 2 (rc $(cat "$T/rc"))"

echo "mc-stale-rows-sweep.bh-8310-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
