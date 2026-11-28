#!/bin/bash
# tests/prr-shadow-ready.bh-10211-test.sh — BH-10211 C0: bin/prr-shadow-ready.sh,
# the READY check a person reads before moving a lane's gh_source row to record.
#
# What is pinned (the decision rule):
#   READY     hours >= PRR_READY_HOURS (48) AND agreed >= PRR_READY_MIN_AGREED
#             (100) AND mismatch = 0 AND a readable counter. 48 h / 100 / 0 and
#             200 h / 5000 / 0 are READY, rc 0.
#   NOT READY 47 h; 99 agreed; 1 mismatch in the counter; 1 PRR_SHADOW line of
#             the lane in logs/prr-shadow.log at or after the window start. rc 1.
#   near miss a PRR_SHADOW line of lane=<lane>-x, or of the lane before the
#             window start, does not count. miss and skip do not block.
#   sum       agreed spread over 3 day files sums.
#   no data   no counter dir: NOT READY why=no-counter rc 2; a malformed file:
#             NOT READY why=unreadable rc 2.
#   --all     one line per gh_source lane (one per GH_SOURCE knob file); --md adds 2 header lines.
#   offline   neither new file holds a curl, gh, claude or PUT call.
# Run from anywhere: bash tests/prr-shadow-ready.bh-10211-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CHK="$DIR/bin/prr-shadow-ready.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -x "$CHK" ] || { echo "FAIL: $CHK missing or not executable"; exit 1; }

export HARNESS_TEST_SANDBOX=1
unset H PRR_READY_HOURS PRR_READY_MIN_AGREED PRR_COUNT_KEEP_DAYS
NOW=1795000000
U=$$
# shellcheck source=bin/lib/prr-count.sh
. "$DIR/bin/lib/prr-count.sh" || { echo "FAIL: prr-count.sh did not source"; exit 1; }
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# fixture <root> <lane> <hours> <agreed> [mismatch] — written with prr_count_add,
# so the format round-trips: 1 agree at NOW - hours*3600, the rest at NOW.
fixture() {
  local root="$1" lane="$2" h="$3" n="$4" m="${5:-0}" i
  mkdir -p "$root/logs"
  HARNESS="$root" PRR_COUNT_NOW=$((NOW - h*3600)) prr_count_add "$lane" agree
  for ((i=1; i<n; i++)); do HARNESS="$root" PRR_COUNT_NOW=$NOW prr_count_add "$lane" agree; done
  for ((i=0; i<m; i++)); do HARNESS="$root" PRR_COUNT_NOW=$NOW prr_count_add "$lane" mismatch; done
}
check() { # check <root> <lane> -> OUT, RC
  OUT=$(HARNESS="$root" PRR_COUNT_NOW=$NOW "$CHK" "$2" 2>&1); RC=$?
}
expect() { # expect <case> <want rc> <want word> <want substring...>
  local c="$1" wrc="$2" w="$3" s; shift 3
  [ "$RC" = "$wrc" ] && ok || bad "$c: rc want $wrc got $RC: $OUT"
  case "$w" in
    READY) [[ "$OUT" == *" READY "* ]] && [[ "$OUT" != *"NOT READY"* ]] && ok || bad "$c: want READY: $OUT" ;;
    *) [[ "$OUT" == *"NOT READY"* ]] && ok || bad "$c: want NOT READY: $OUT" ;;
  esac
  for s in "$@"; do [[ "$OUT" == *"$s"* ]] && ok || bad "$c: want '$s' in: $OUT"; done
}

case_root() { root="$T/r.$1"; mkdir -p "$root/logs"; }

# ---- READY side ----------------------------------------------------------------
case_root a; L="ra-$U"; fixture "$root" "$L" 48 100
check "$root" "$L"; expect "48h/100/0" 0 READY "hours=48" "agreed=100" "mismatch=0"
[[ "$OUT" == "$L READY "* ]] && ok || bad "48h/100/0: line starts '<lane> READY': $OUT"

# 5000 locked writes are slow: this one fixture is written by hand, in the
# format the 48h case above round-trips through prr_count_add.
case_root b; L="rb-$U"; mkdir -p "$root/logs/prr-count/$L"
printf 'first\t%s\nlast\t%s\nagree\t5000\n' $((NOW - 200*3600)) "$NOW" > "$root/logs/prr-count/$L/$(date -u -d "@$NOW" +%F).tsv"
check "$root" "$L"; expect "200h/5000/0" 0 READY "hours=200" "agreed=5000"

# ---- NOT READY side ------------------------------------------------------------
case_root c; L="rc-$U"; fixture "$root" "$L" 47 100
check "$root" "$L"; expect "47h" 1 NOT "hours=47" "agreed=100" "why=hours<48"

case_root d; L="rd-$U"; fixture "$root" "$L" 48 99
check "$root" "$L"; expect "99 agreed" 1 NOT "agreed=99" "agreed<100"

case_root e; L="re-$U"; fixture "$root" "$L" 48 100 1
check "$root" "$L"; expect "1 counter mismatch" 1 NOT "mismatch=1" "mismatch>0"

case_root f; L="rf-$U"; fixture "$root" "$L" 48 100
printf '%s PRR_SHADOW lane=%s key=k record=1 github=1 only_record=0 only_github=0 changed=1\n' "$(iso $((NOW - 3600)))" "$L" > "$root/logs/prr-shadow.log"
check "$root" "$L"; expect "1 log line in window" 1 NOT "mismatch=1" "mismatch>0"

# ---- near misses ---------------------------------------------------------------
case_root g; L="rg-$U"; fixture "$root" "$L" 48 100
{ printf '%s PRR_SHADOW lane=%s-x key=k changed=1\n' "$(iso $((NOW - 3600)))" "$L"
  printf '%s PRR_SHADOW lane=%s key=k changed=1\n' "$(iso $((NOW - 49*3600)))" "$L"
  printf '%s PRR_MISS lane=%s key=k why=stale fallback=none\n' "$(iso $((NOW - 3600)))" "$L"; } > "$root/logs/prr-shadow.log"
HARNESS="$root" PRR_COUNT_NOW=$NOW prr_count_add "$L" miss stale
HARNESS="$root" PRR_COUNT_NOW=$NOW prr_count_add "$L" skip
check "$root" "$L"; expect "near misses" 0 READY "mismatch=0" "miss=1" "skip=1"

# ---- 3 day files sum -----------------------------------------------------------
case_root h; L="rh-$U"
HARNESS="$root" PRR_COUNT_NOW=$((NOW - 60*3600)) prr_count_add "$L" agree
for i in $(seq 1 49); do HARNESS="$root" PRR_COUNT_NOW=$((NOW - 30*3600)) prr_count_add "$L" agree; done
for i in $(seq 1 50); do HARNESS="$root" PRR_COUNT_NOW=$NOW prr_count_add "$L" agree; done
n=$(find "$root/logs/prr-count/$L" -name '*.tsv' | wc -l)
[ "$n" = 3 ] && ok || bad "sum: fixture wants 3 day files, got $n"
check "$root" "$L"; expect "3 files sum" 0 READY "agreed=100" "hours=60"

# ---- knobs ---------------------------------------------------------------------
OUT=$(HARNESS="$root" PRR_COUNT_NOW=$NOW PRR_READY_MIN_AGREED=101 "$CHK" "$L" 2>&1); RC=$?
expect "knob PRR_READY_MIN_AGREED=101" 1 NOT "agreed<101"
OUT=$(HARNESS="$root" PRR_COUNT_NOW=$NOW PRR_READY_HOURS=61 "$CHK" "$L" 2>&1); RC=$?
expect "knob PRR_READY_HOURS=61" 1 NOT "hours<61"

# The knob rows carry the ticket's numbers as defaults, and the code fallbacks match.
K="$DIR/catalog/lanes.d/_lib.prr-count.json"
for kv in PRR_READY_HOURS=48 PRR_READY_MIN_AGREED=100 PRR_COUNT_KEEP_DAYS=14 PRR_COUNT_LOCK_S=2; do
  got=$(jq -r --arg e "${kv%=*}" '.libs[] | select(.id == "prr-count") | .knobs[] | select(.env == $e) | .default' "$K" 2>/dev/null)
  [ "$got" = "${kv#*=}" ] && ok || bad "knob: ${kv%=*} default want ${kv#*=} got '$got'"
done

# A settings row reaches the knob through lib_env_apply (registry + a fake
# _jobs_req: no network). lib.prr-count.prr_ready_min_agreed=101 -> NOT READY.
if "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 && [ -s "$T/lanes.json" ]; then
  cat > "$T/jobs.sh" <<'EOF2'
_jobs_req() { case "$2" in /api/settings*) cat "$T/settings" ;; *) return 1 ;; esac; }
EOF2
  srow() {
    printf '{"settings":[{"key":"lib.prr-count.prr_ready_min_agreed","value":"%s","actor":"operator"}]}' "$1" > "$T/settings"
    scratch_rm "$root/state/settings-cache.json"; scratch_rm "$root/state/lane-gate"
    OUT=$(env -i PATH="$PATH" HOME="$T" T="$T" CHK="$CHK" HARNESS="$root" HARNESS_TEST_SANDBOX=1 JOBS_BOX=test \
      PRR_COUNT_NOW=$NOW LANE_REGISTRY="$T/lanes.json" bash -c '. "$T/jobs.sh"; export -f _jobs_req; "$CHK" "$1"' _ "$L" 2>&1); RC=$?
  }
  srow 101; expect "settings row min_agreed=101" 1 NOT "agreed<101"
  srow 100; expect "settings row min_agreed=100" 0 READY "agreed=100"
else
  bad "knob: lanes-build.sh could not compose a registry for the settings-row case"
fi

# ---- no data -------------------------------------------------------------------
case_root i; L="ri-$U"
check "$root" "$L"; expect "no counter" 2 NOT "why=no-counter" "agreed=0"

case_root j; L="rj-$U"; fixture "$root" "$L" 48 100
printf 'agree\tlots\n' >> "$root/logs/prr-count/$L/$(date -u -d "@$NOW" +%F).tsv"
check "$root" "$L"; expect "malformed" 2 NOT "why=unreadable"

check "$root" '../x'; [ "$RC" = 2 ] && ok || bad "bad lane: want rc 2 got $RC: $OUT"

# ---- --all / --md --------------------------------------------------------------
case_root k
OUT=$(HARNESS="$root" PRR_COUNT_NOW=$NOW "$CHK" --all 2>&1); RC=$?
# The lane list is the knob files on this tree (7 at the ticket, 12 since
# BH-10157, BH-10158 and BH-10218 added gh_source lanes).
NL=$(find "$DIR/catalog/lanes.d" -path '*.knobs.d/GH_SOURCE.json' | wc -l)
[ "$NL" -ge 7 ] && ok || bad "--all: want 7 or more GH_SOURCE knob files, got $NL"
[ "$(grep -c 'NOT READY' <<<"$OUT")" = "$NL" ] && ok || bad "--all: want $NL lane lines: $OUT"
for l in dequeue-watch main-red-pr-pair merge-conductor pipeline-health pr-state-reconcile tickets-snapshot-push wake-loop; do
  grep -q "^$l NOT READY " <<<"$OUT" && ok || bad "--all: lane $l missing: $OUT"
done
[ "$RC" = 2 ] && ok || bad "--all with no counters: want rc 2 got $RC"
fixture "$root" merge-conductor 48 100
OUT=$(HARNESS="$root" PRR_COUNT_NOW=$NOW "$CHK" --all --md 2>&1); RC=$?
[ "$(grep -c '^| ' <<<"$OUT")" = $((NL + 2)) ] && ok || bad "--md: want $((NL + 2)) table lines: $OUT"
grep -q '^| merge-conductor | READY | 48 | 100 | 0 |' <<<"$OUT" && ok || bad "--md: merge-conductor READY row: $OUT"

# ---- offline -------------------------------------------------------------------
for f in "$CHK" "$DIR/bin/lib/prr-count.sh"; do
  grep -nE '(^|[^a-z_])(curl|gh|claude) |PUT' "$f" | grep -v '^[0-9]*:[[:space:]]*#' && bad "offline: $f holds a network or model call" || ok
done

echo "prr-shadow-ready: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
