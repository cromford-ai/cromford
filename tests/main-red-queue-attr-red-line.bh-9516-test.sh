#!/bin/bash
# tests/main-red-queue-attr-red-line.bh-9516-test.sh — BH-9516: a `RED: <path> …`
# line is a failure line for merge-queue batch attribution
# (bin/lib/main-red-queue-attr.sh, MRQA_FAIL_RE).
#
# On 2026-11-11 three independent batches failed the DELTA check of
# tests/no-state-files.bh-4159-test.sh, each on a file its own PR changes. The
# check names the file only on a `RED: bin/<file> has N raw state/ write(s)`
# line. MRQA_FAIL_RE did not match that line, so mrqa_attr answered `untouched`
# for all three, they counted as a red main, and the queue froze on a green main.
# Fixtures: tests/fixtures/bh-9516/ (see its README for provenance).
#
#   R1  run 42986242197, #9508            -> own #9508, bin/harness-sync.sh, cached
#   R2  run 42983086513, #9509            -> own #9509, bin/fly-pool.sh
#   R3  run 42977073139, #8761 + #9487    -> own #9487, bin/lib/gh-cache.sh
#   R4  run 42977073139, #8761 alone      -> untouched (the RED path is not its file)
#   N1-N6 near misses on one line print no path
#   P1-P2 anchored positives print the path
#   M1  the lib without the BH-9516 alternative turns R1 `untouched`
#
# No network: a `gh` shell function serves the fixtures; the ledger is stubbed.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/main-red-queue-attr-red-line.bh-9516-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
FX="$DIR/tests/fixtures/bh-9516"
LIB="$DIR/bin/lib/main-red-queue-attr.sh"
SLUG=example-org/cromford
[ -s "$FX/log-42986242197.txt" ] && [ -s "$LIB" ] || { echo "FAIL: the bh-9516 fixtures or the lib are missing"; exit 1; }

# attr <lib> <run-id> <pr...> — prints "verdict|pr|why" from a subshell that
# sources <lib> with a fixture-serving gh and a stub ledger (no row; every put
# appended to $T/puts).
attr() {
  local lib="$1"; shift
  (
    gh() {
      if [ "$1 $2" = "run view" ]; then
        cat "$FX/log-$3.txt" 2>/dev/null; return $?
      elif [ "$1" = api ]; then
        local n; n=$(sed -E 's#.*/pulls/([0-9]+)/files.*#\1#' <<<"$2")
        cat "$FX/files-$n.txt" 2>/dev/null; return $?
      fi
      return 99
    }
    job_ledger_get() { return 2; }
    job_ledger_put() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$T/puts"; return 0; }
    # shellcheck disable=SC1090
    . "$lib"
    mrqa_attr "$SLUG" "$@"
    printf '%s|%s|%s\n' "$MRQA_VERDICT" "$MRQA_PR" "$MRQA_WHY"
  )
}
# paths <lib> <line> — the path column _mrqa_paths prints for one gh log line.
paths() {
  ( # shellcheck disable=SC1090
    . "$1"; printf 'Tests\tSTEP\t2026-11-11T08:36:41.5511071Z %s\n' "$2" | _mrqa_paths | cut -f1 )
}

# R1 — the incident batch of the ticket.
: > "$T/puts"
out=$(attr "$LIB" 42986242197 9508)
IFS='|' read -r v pr why <<<"$out"
[ "$v" = own ] && [ "$pr" = 9508 ] && ok || bad "R1: run 42986242197 with #9508 must be own #9508, got '$out'"
[[ "$why" == "RED: bin/harness-sync.sh has 22 raw state/ write(s), 19 at base 89f2fc154d60"* ]] && ok \
  || bad "R1: MRQA_WHY must start with the RED line, got '$why'"
[[ "$why" == *"(#9508 changes bin/harness-sync.sh)" ]] && ok || bad "R1: MRQA_WHY must end '(#9508 changes bin/harness-sync.sh)', got '$why'"
put=$(cat "$T/puts")
[ "$put" = "main_red_qattr	$SLUG#42986242197	own pr=9508 path=bin/harness-sync.sh" ] && ok \
  || bad "R1: one ledger put of 'own pr=9508 path=bin/harness-sync.sh' expected, got '$put'"
# The written value must parse back through mrqa_attr's own cache reader.
val=${put##*$'\t'}
[[ "$val" =~ ^own\ pr=([0-9]+)\ path=(.+)$ ]] && [ "${BASH_REMATCH[1]}" = 9508 ] && [ "${BASH_REMATCH[2]}" = bin/harness-sync.sh ] && ok \
  || bad "R1: cached value '$val' does not round-trip through the cache reader"

# R2 — #9509 broke bin/fly-pool.sh. The excerpt is the RED line cut to 160 by
# awk substr, which counts BYTES in mawk/BWK awk and in a C locale, and
# CHARACTERS in gawk under UTF-8; `cut -c` has the same split across coreutils
# versions. The line has one 3-byte dash before the cut, so the excerpt is 160
# or 162 bytes. The check reads the excerpt against the fixture line itself and
# bounds its byte length, so it holds on every box and in both locales.
out=$(attr "$LIB" 42983086513 9509)
IFS='|' read -r v pr why <<<"$out"
full=$(grep -a -m1 -o 'RED: bin/fly-pool\.sh .*' "$FX/log-42983086513.txt")
ex=${why% (#9509 changes bin/fly-pool.sh)}
exb=$(printf '%s' "$ex" | LC_ALL=C wc -c | tr -d ' ')
[ "$v" = own ] && [ "$pr" = 9509 ] && ok || bad "R2: run 42983086513 with #9509 must be own #9509, got '$out'"
[[ "$why" == *" (#9509 changes bin/fly-pool.sh)" ]] && ok || bad "R2: MRQA_WHY must end '(#9509 changes bin/fly-pool.sh)', got '$why'"
[[ "$ex" == "RED: bin/fly-pool.sh has 74 raw state/ write(s), 56 at base 89f2fc154d60 — new state must be a DB row (bin/lib/jobs/*), a settings row, or a path classed cach"* ]] \
  && [ -n "$full" ] && [ "${full#"$ex"}" != "$full" ] && ok \
  || bad "R2: the excerpt must be a prefix of the fixture RED line, through 'a path classed cach', got '$ex'"
{ [ "$exb" = 160 ] || [ "$exb" = 162 ]; } && ok || bad "R2: the excerpt must be cut to 160 (160 bytes, or 160 characters = 162 bytes), got $exb bytes"

# R3 — a two-PR batch: the owner is the PR that changes the RED path, not the first.
out=$(attr "$LIB" 42977073139 8761 9487)
IFS='|' read -r v pr why <<<"$out"
[ "$v" = own ] && [ "$pr" = 9487 ] && [[ "$why" == *"(#9487 changes bin/lib/gh-cache.sh)" ]] && ok \
  || bad "R3: run 42977073139 with #8761 #9487 must be own #9487 on bin/lib/gh-cache.sh, got '$out'"

# R4 — the same red with only a PR that does not change the RED path still counts.
: > "$T/puts"
out=$(attr "$LIB" 42977073139 8761)
[ "$out" = "untouched||no failure-line path is a file this batch's PRs change" ] && ok \
  || bad "R4: run 42977073139 with #8761 alone must be untouched, got '$out'"
[ "$(cat "$T/puts")" = "main_red_qattr	$SLUG#42977073139	untouched" ] && ok || bad "R4: one 'untouched' put expected, got '$(cat "$T/puts")'"

# N1-N6 — near misses: not a failure line, so no path.
n=0
for line in "PRED: bin/x.sh" "GREEN: bin/x.sh" "red: bin/x.sh" "RED bin/x.sh" "note: RED: bin/x.sh" "RED: bin/x.sh.bak"; do
  n=$((n+1))
  got=$(paths "$LIB" "$line")
  [ -z "$got" ] && ok || bad "N$n: '$line' must print no path, got '$got'"
done

# P1-P2 — anchored positives, plain and indented with a :line suffix.
[ "$(paths "$LIB" "RED: bin/x.sh")" = bin/x.sh ] && ok || bad "P1: 'RED: bin/x.sh' must print bin/x.sh"
[ "$(paths "$LIB" "   RED: bin/x.sh:12 has 3 raw writes")" = bin/x.sh ] && ok || bad "P2: an indented RED line with :12 must print bin/x.sh"

# M1 — the pre-fix rule: drop the BH-9516 alternative and R1 goes back to untouched.
M="$T/mrqa-m1.sh"
sed -e 's/|^\[\[:space:\]\]\*RED: )'"'"'$/)'"'"'/' "$LIB" > "$M"
if cmp -s "$LIB" "$M"; then
  bad "M1: the mutant sed did not change the lib (the MRQA_FAIL_RE line moved?)"
else
  out=$(attr "$M" 42986242197 9508)
  [ "${out%%|*}" = untouched ] && ok || bad "M1: without the RED alternative R1 must be untouched, got '$out'"
fi

echo "main-red-queue-attr-red-line: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
