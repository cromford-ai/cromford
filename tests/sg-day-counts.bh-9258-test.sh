#!/bin/bash
# tests/sg-day-counts.bh-9258-test.sh — BH-9258 (#9061 Fix 4): sg_day_counts
# (bin/lib/sg-day-counts.sh) counts one UTC day of builds/pool-<P>-*/gate.txt
# per pool project: gates, rc0, rc1_attributed, rc1_unattributed, could_not_run.
#   C1 the class table (plan "Failure modes", near misses included)
#   C2 the day bounds: 23:59:59 yesterday no, 00:00:00 today yes, 00:00:00 tomorrow no
#   C3 the longest project prefix wins (project-6-os vs project-6)
#   C4 a local build dir (<P>-*) is not counted
#   C5 a dir of a project that is not in the list is not counted
#   C6 a gate.txt one level deeper is not counted
#   C7 no builds dir: {} and rc 0
#   C8 a project with no file gets zeros
#   C9 the output parses and holds exactly the six keys per project
# Run: HARNESS_TEST_SANDBOX=1 bash tests/sg-day-counts.bh-9258-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "sg-day-counts.bh-9258-test: SKIPPED — jq missing"; exit 0; }
# shellcheck source=bin/lib/sg-day-counts.sh
. "$DIR/bin/lib/sg-day-counts.sh" || { echo "FAIL: cannot source bin/lib/sg-day-counts.sh"; exit 1; }

D0=$(date -u -d '2026-11-08 00:00:00' +%s)
B="$T/builds"
N=0
gate() { # gate <dir under builds> <touch date> <line>...
  local d="$B/$1" when="$2"; shift 2
  mkdir -p "$d"; printf '%s\n' "head: 0000000000000000000000000000000000000000" "$@" > "$d/gate.txt"
  touch -d "$when" "$d/gate.txt"
}
cnt() { sg_day_counts "$B" "$D0" "$@"; }
five() { jq -r --arg p "$1" '.[$p] | "\(.gates) \(.rc0) \(.rc1_attributed) \(.rc1_unattributed) \(.could_not_run)"'; }
fresh() { [ -e "$B" ] && { scratch_rm "$B" || exit 1; }; mkdir -p "$B"; }
one() { # one <expected "g r0 ra ru cn"> <label> <line>... : one gate.txt of project p today
  fresh; N=$((N+1)); gate "pool-p-BH-$N-x" '2026-11-08 06:00:00Z' "${@:3}"
  local got; got=$(cnt p | five p)
  [ "$got" = "$1" ] && ok || bad "C1 $2: got '$got', want '$1'"
}

# ---- C1 ---- gates rc0 rc1_attributed rc1_unattributed could_not_run
one "1 1 0 0 0" "rc 0" 'rc: 0' 'red: -'
one "1 1 0 0 0" "rc 0 with baseline could-not-run" 'rc: 0' 'red: -' 'baseline: could-not-run: timeout'
one "1 0 1 0 0" "rc 1, no unattributed" 'rc: 1' 'red: tests/a.sh'
one "1 0 1 0 0" "rc 1, unattributed: -" 'rc: 1' 'red: tests/a.sh' 'unattributed: -'
one "1 0 0 1 0" "rc 1, unattributed list" 'rc: 1' 'red: tests/a.sh,tests/b.sh' 'unattributed: tests/a.sh,tests/b.sh'
one "1 0 1 0 0" "unattributed: in why: only" 'rc: 1' 'red: tests/a.sh' 'why: unattributed: tests/a.sh'
one "1 0 0 0 1" "rc could-not-run" 'rc: could-not-run' 'red: -'
one "1 0 0 0 1" "rc could-not-run: runner-rc-125" 'rc: could-not-run: runner-rc-125'
one "1 0 0 0 0" "rc off" 'rc: off'
one "1 0 0 0 0" "rc no-selection" 'rc: no-selection'
one "1 0 0 0 0" "no rc line" 'red: -'
one "1 0 0 0 0" "rc 10" 'rc: 10'

# ---- C2 ----
fresh
gate pool-p-BH-1-a '2026-11-07 23:59:59Z' 'rc: 0'
gate pool-p-BH-2-a '2026-11-08 00:00:00Z' 'rc: 0'
gate pool-p-BH-3-a '2026-11-08 23:59:59Z' 'rc: 1'
gate pool-p-BH-4-a '2026-11-09 00:00:00Z' 'rc: 0'
[ "$(cnt p | five p)" = "2 1 1 0 0" ] && ok || bad "C2 day bounds: $(cnt p)"
[ "$(cnt p | jq -r .p.day)" = "2026-11-08" ] && ok || bad "C2 day: $(cnt p)"

# ---- C3 ----
fresh
gate pool-project-6-os-TK-1-a '2026-11-08 06:00:00Z' 'rc: 0'
gate pool-project-6-TK-2-a '2026-11-08 06:00:00Z' 'rc: 1'
OUT=$(cnt project-6 project-6-os)
[ "$(five project-6 <<<"$OUT")" = "1 0 1 0 0" ] && ok || bad "C3 project-6: $OUT"
[ "$(five project-6-os <<<"$OUT")" = "1 1 0 0 0" ] && ok || bad "C3 project-6-os: $OUT"
OUT=$(cnt project-6-os project-6)
[ "$(five project-6 <<<"$OUT")" = "1 0 1 0 0" ] && ok || bad "C3 order does not matter: $OUT"

# ---- C4 C5 C6 ----
fresh
gate pool-cromford-BH-1-x '2026-11-08 06:00:00Z' 'rc: 0'
gate cromford-BH-2-x '2026-11-08 06:00:00Z' 'rc: 0'
gate pool-other-X-1 '2026-11-08 06:00:00Z' 'rc: 0'
gate pool-cromford-BH-3-x/selection-gate '2026-11-08 06:00:00Z' 'rc: 0'
OUT=$(cnt cromford)
[ "$(five cromford <<<"$OUT")" = "1 1 0 0 0" ] && ok || bad "C4/C6 local build or depth 3 counted: $OUT"
jq -e 'has("other") | not' <<<"$OUT" >/dev/null && ok || bad "C5 an unlisted project is in the output: $OUT"

# ---- C7 ----
OUT=$(sg_day_counts "$T/no-such-dir" "$D0" p); RC=$?
[ "$OUT" = "{}" ] && [ "$RC" = 0 ] && ok || bad "C7 no builds dir: rc=$RC out=$OUT"
OUT=$(sg_day_counts "$B" "not-a-number" p); RC=$?
[ "$OUT" = "{}" ] && [ "$RC" = 0 ] && ok || bad "C7 bad epoch: rc=$RC out=$OUT"

# ---- C8 C9 ----
fresh
gate pool-p-BH-1-a '2026-11-08 06:00:00Z' 'rc: 0'
OUT=$(cnt p q)
[ "$(five q <<<"$OUT")" = "0 0 0 0 0" ] && ok || bad "C8 zeros: $OUT"
jq -e 'keys == ["p","q"] and ([.[] | keys] | all(. == ["could_not_run","day","gates","rc0","rc1_attributed","rc1_unattributed"]))' \
  <<<"$OUT" >/dev/null && ok || bad "C9 keys: $OUT"
jq -e '[.[] | .gates, .rc0, .rc1_attributed, .rc1_unattributed, .could_not_run] | all(type == "number")' <<<"$OUT" >/dev/null \
  && ok || bad "C9 numbers: $OUT"

echo "sg-day-counts.bh-9258-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
