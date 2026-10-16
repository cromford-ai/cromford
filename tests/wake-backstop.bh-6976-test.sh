#!/bin/bash
# tests/wake-backstop.bh-6976-test.sh — BH-6976: the decision table of wb_due
# (bin/lib/wake-backstop.sh), the shared read-now-or-skip rule of the three
# converted pollers. prs_wake_seen is a table double (lines `kind key rc`, `*`
# matches anything, first match wins, no match rc 1) except in WB9, which runs
# the real one (bin/lib/pr-snapshot-wakes.sh) on a seeded changed.tsv.
#
#   WB1  WAKE_BACKSTOP=0 / backstop 0 -> rc 0 off
#   WB2  last 0 / empty / non-digit / ahead of now -> rc 0 no-state
#   WB3  age floor-1 -> rc 1 floor (a wake does not beat the floor)
#   WB4  age = backstop -> rc 0 backstop
#   WB5  no double: the lib loads pr-snapshot.sh itself, no _jobs_req -> no-feed
#   WB6  one key's answer is 2 -> rc 0 no-feed
#   WB7  a wake on the last of 3 keys -> rc 0 wake:issue:<k>
#   WB8  a wake on a key not in the file, a checks wake when asked issue -> rc 1 quiet
#   WB9  the real prs_wake_seen: a wake in the same minute as last -> rc 0;
#        a wake in the minute before -> rc 1 quiet
#   WB10 backstop 1200 reads as 1800: age 1500 rc 1 quiet, age 1800 rc 0 backstop,
#        one wake-backstop.log line per day
#   WB11 a `retry` line -> rc 0 retry past the floor, rc 1 floor inside it
#   WB12 201 keys -> rc 0 many-keys; 200 quiet keys -> rc 1 quiet
#   WB13 wb_knob with no settings row -> 1 / 1800 / 1800; a row of 0 -> 0
#   WB14 no keys file -> rc 0 no-keys; `-` takes the trailing keys
#   WB15 wb_cache_put / wb_cache_get round trip, an updatedAt that moved, a torn write
#   WB16 wb_gc deletes cache files older than 3 days and keeps the rest
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/wake-backstop.bh-6976-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/wake-backstop.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$LIB" ] || { echo "FAIL: $LIB is missing"; echo "wake-backstop: 0 passed, 1 failed"; exit 1; }

"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 && [ -s "$T/lanes.json" ] \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; echo "wake-backstop: 0 passed, 1 failed"; exit 1; }

L=1700000000
mkdir -p "$T/h"
# due [VAR=val...] -- <wb_due args> — one call in a clean env; sets OUT and RC.
# With $T/wake present, prs_wake_seen is the table double.
due() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  OUT=$(env -i PATH="$PATH" HOME="$T" T="$T" LIB="$LIB" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 \
    LANE_REGISTRY="$T/lanes.json" "${envs[@]}" bash -c '
      . "$LIB"
      if [ -f "$T/wake" ]; then
        prs_wake_seen() {
          local r
          printf "WAKE %s %s %s %s\n" "$@" >> "$T/wake.calls"
          r=$(awk -v k="$2" -v key="$3" '"'"'($1 == k || $1 == "*") && ($2 == key || $2 == "*") { print $3; exit }'"'"' "$T/wake")
          return "${r:-1}"
        }
      fi
      wb_due "$@"; rc=$?
      [ "$(type -t prs_wake_seen)" = function ] && echo loaded > "$T/loaded"
      exit "$rc"' _ "$@" 2>"$T/err")
  RC=$?
}
want() { # want <case> <rc> <word>
  [ "$RC" = "$2" ] && [ "$OUT" = "$3" ] && ok || bad "$1 wanted rc $2 '$3', got rc $RC '$OUT' ($(cat "$T/err"))"
}
printf '7\n8\n9\n' > "$T/keys3"
quiet() { printf '* * 1\n' > "$T/wake"; rm -f "$T/wake.calls"; }
quiet

# WB1
due WAKE_BACKSTOP=0 WAKE_BACKSTOP_NOW=$((L+5000)) -- o/r issue "$T/keys3" "$L" 600 1800; want WB1 0 off
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue "$T/keys3" "$L" 600 0; want WB1b 0 off
# WB2
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue "$T/keys3" 0 600 1800; want WB2 0 no-state
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue "$T/keys3" "" 600 1800; want WB2b 0 no-state
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue "$T/keys3" 12ab 600 1800; want WB2c 0 no-state
due WAKE_BACKSTOP_NOW=$((L-5)) -- o/r issue "$T/keys3" "$L" 0 1800; want WB2d 0 no-state
# WB3 — the floor holds even with a wake on a key
printf 'issue 7 0\n* * 1\n' > "$T/wake"
due WAKE_BACKSTOP_NOW=$((L+599)) -- o/r issue "$T/keys3" "$L" 600 1800; want WB3 1 floor
quiet
# WB4
due WAKE_BACKSTOP_NOW=$((L+1800)) -- o/r issue "$T/keys3" "$L" 600 1800; want WB4 0 backstop
due WAKE_BACKSTOP_NOW=$((L+1799)) -- o/r issue "$T/keys3" "$L" 600 1800; want WB4b 1 quiet
grep -q "^WAKE o/r issue 9 $L\$" "$T/wake.calls" && ok || bad "WB4b the feed was not asked about key 9 since last: $(cat "$T/wake.calls" 2>/dev/null)"
# WB5 — no double: the lib loads the real feed, which cannot tell without _jobs_req
rm -f "$T/wake" "$T/loaded"
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue "$T/keys3" "$L" 600 1800; want WB5 0 no-feed
[ -f "$T/loaded" ] && ok || bad "WB5 wb_due did not load prs_wake_seen from bin/lib/pr-snapshot.sh"
quiet
# WB6
printf 'issue 8 2\n* * 1\n' > "$T/wake"
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue "$T/keys3" "$L" 600 1800; want WB6 0 no-feed
# WB7
printf 'issue 9 0\n* * 1\n' > "$T/wake"
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue "$T/keys3" "$L" 600 1800; want WB7 0 wake:issue:9
printf 'pr 8 0\n* * 1\n' > "$T/wake"
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue,pr "$T/keys3" "$L" 600 1800; want WB7b 0 wake:pr:8
# WB8
printf 'issue 42 0\nchecks 7 0\n* * 1\n' > "$T/wake"
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue "$T/keys3" "$L" 600 1800; want WB8 1 quiet

# WB9 — the real prs_wake_seen on a seeded mirror (its clock is the box's own)
rm -f "$T/wake"
NOWR=$(date +%s); LR=$((NOWR - 10)); BK=$((LR - LR % 60))
SD="$T/h/state/pr-snapshot/o_r"; mkdir -p "$SD"
printf '%s\t1\t1\t%s\n' "$NOWR" "$((LR - 3600))" > "$SD/wakes.state"
echo 100 > "$SD/wakes.wm"
cat > "$T/jobs.sh" <<'EOF'
_jobs_req() { case "$2" in /api/settings) echo '{"settings":[]}' ;; *) return 1 ;; esac; }
EOF
printf 'issue\t8\t100\t%s\n' "$BK" > "$SD/changed.tsv"
OUT=$(env -i PATH="$PATH" HOME="$T" T="$T" LIB="$LIB" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 PR_SNAPSHOT=1 \
  PR_SNAPSHOT_TTL_S=600 LANE_REGISTRY="$T/lanes.json" bash -c '. "$T/jobs.sh"; . "$LIB"; wb_due "$@"' _ \
  o/r issue "$T/keys3" "$LR" 0 1800 2>"$T/err"); RC=$?
want WB9 0 wake:issue:8
printf 'issue\t8\t100\t%s\n' "$((BK - 1))" > "$SD/changed.tsv"
OUT=$(env -i PATH="$PATH" HOME="$T" T="$T" LIB="$LIB" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 PR_SNAPSHOT=1 \
  PR_SNAPSHOT_TTL_S=600 LANE_REGISTRY="$T/lanes.json" bash -c '. "$T/jobs.sh"; . "$LIB"; wb_due "$@"' _ \
  o/r issue "$T/keys3" "$LR" 0 1800 2>"$T/err"); RC=$?
want WB9b 1 quiet
quiet

# WB10
rm -f "$T/h/logs/wake-backstop.log"
due WAKE_BACKSTOP_NOW=$((L+1500)) -- o/r issue "$T/keys3" "$L" 600 1200; want WB10 1 quiet
due WAKE_BACKSTOP_NOW=$((L+1800)) -- o/r issue "$T/keys3" "$L" 600 1200; want WB10b 0 backstop
[ "$(grep -c 'backstop 1200 s is under the 1800 s floor' "$T/h/logs/wake-backstop.log" 2>/dev/null)" = 1 ] && ok \
  || bad "WB10 wanted one clamp line, got: $(cat "$T/h/logs/wake-backstop.log" 2>/dev/null)"
# WB11
printf '7\nretry\n' > "$T/keysr"
due WAKE_BACKSTOP_NOW=$((L+600)) -- o/r issue "$T/keysr" "$L" 600 1800; want WB11 0 retry
due WAKE_BACKSTOP_NOW=$((L+599)) -- o/r issue "$T/keysr" "$L" 600 1800; want WB11b 1 floor
# WB12
seq 1 201 > "$T/keys201"; seq 1 200 > "$T/keys200"
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue "$T/keys201" "$L" 600 1800; want WB12 0 many-keys
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue "$T/keys200" "$L" 600 1800; want WB12b 1 quiet

# WB13 — the knobs, through the registry
knobs() {
  env -i PATH="$PATH" HOME="$T" T="$T" LIB="$LIB" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 \
    LANE_REGISTRY="$T/lanes.json" "$@" bash -c '[ -f "$T/settings" ] && . "$T/jobs-settings.sh"; . "$LIB"
      printf "%s %s %s" "$(wb_knob WAKE_BACKSTOP)" "$(wb_knob ORPHAN_WAKE_BACKSTOP_S)" "$(wb_knob PARENT_CLOSE_BACKSTOP_S)"' 2>/dev/null
}
rm -f "$T/settings"
k=$(knobs); [ "$k" = "1 1800 1800" ] && ok || bad "WB13 no settings row gave '$k', wanted '1 1800 1800'"
k=$(knobs ORPHAN_WAKE_BACKSTOP_S=x PARENT_CLOSE_BACKSTOP_S=''); [ "$k" = "1 1800 1800" ] && ok || bad "WB13b junk env gave '$k'"
cat > "$T/jobs-settings.sh" <<'EOF'
_jobs_req() { case "$2" in /api/settings*) cat "$T/settings" ;; *) return 1 ;; esac; }
EOF
echo '{"settings":[{"key":"lib.wake-backstop.wake_backstop","value":"0","actor":"operator"},{"key":"lib.wake-backstop.parent_close_backstop_s","value":"3600","actor":"operator"}]}' > "$T/settings"
rm -rf "$T/h/state/settings-cache.json" "$T/h/state/lane-gate"
k=$(knobs JOBS_BOX=test); [ "$k" = "0 1800 3600" ] && ok || bad "WB13c settings rows gave '$k', wanted '0 1800 3600'"
rm -f "$T/settings"; rm -rf "$T/h/state/settings-cache.json" "$T/h/state/lane-gate"

# WB14
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue "$T/nope" "$L" 600 1800; want WB14 0 no-keys
printf 'issue 5 0\n* * 1\n' > "$T/wake"
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue,pr - "$L" 0 1800 5; want WB14b 0 wake:issue:5
due WAKE_BACKSTOP_NOW=$((L+700)) -- o/r issue,pr - "$L" 0 1800 6; want WB14c 1 quiet
quiet

# WB15 — the cache helpers
cache() { # cache <fn> <args...> — prints rc
  env -i PATH="$PATH" HOME="$T" T="$T" LIB="$LIB" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 \
    LANE_REGISTRY="$T/lanes.json" WAKE_BACKSTOP_NOW="${CNOW:-$((L+600))}" CIN="${CIN:-}" bash -c '. "$LIB"
      prs_wake_seen() { local r; r=$(awk -v k="$2" -v key="$3" '"'"'($1 == k || $1 == "*") && ($2 == key || $2 == "*") { print $3; exit }'"'"' "$T/wake"); return "${r:-1}"; }
      "$@" < "${CIN:-/dev/null}"; echo $?' _ "$@" 2>/dev/null
}
CB="$T/h/state/orphan-reconcile/o_r/thread-7"
echo '[{"id":1}]' > "$T/body.json"
[ "$(CIN="$T/body.json" cache wb_cache_put "$CB" "$(printf '2026-10-01T00:00:00Z\t%s' "$L")")" = 0 ] && ok || bad "WB15 wb_cache_put failed"
[ "$(cat "$CB.json")" = '[{"id":1}]' ] && [ "$(cat "$CB.meta")" = "$(printf '2026-10-01T00:00:00Z\t%s' "$L")" ] && ok \
  || bad "WB15 the cache files are '$(cat "$CB.json" "$CB.meta" 2>&1)'"
[ "$(cache wb_cache_get "$CB" o/r issue,pr 7 1800 2026-10-01T00:00:00Z)" = 0 ] && ok || bad "WB15 a quiet cache did not hit"
[ "$(cache wb_cache_get "$CB" o/r issue,pr 7 1800 2026-10-02T00:00:00Z)" = 1 ] && ok || bad "WB15b an updatedAt that moved hit"
[ "$(cache wb_cache_get "$CB" o/r issue,pr 7 1800 '')" = 1 ] && ok || bad "WB15c an empty updatedAt hit"
[ "$(CNOW=$((L+1800)) cache wb_cache_get "$CB" o/r issue,pr 7 1800 2026-10-01T00:00:00Z)" = 1 ] && ok || bad "WB15d a cache at the backstop hit"
printf 'pr 7 0\n* * 1\n' > "$T/wake"
[ "$(cache wb_cache_get "$CB" o/r issue,pr 7 1800 2026-10-01T00:00:00Z)" = 1 ] && ok || bad "WB15e a pr wake for 7 hit"
quiet
rm -f "$CB.meta"
[ "$(cache wb_cache_get "$CB" o/r issue,pr 7 1800 2026-10-01T00:00:00Z)" = 1 ] && ok || bad "WB15f a cache with no meta hit"

# WB16
mkdir -p "$T/h/gc/o_r"
for f in old.json old.meta new.json new.meta; do : > "$T/h/gc/o_r/$f"; done
touch -d '5 days ago' "$T/h/gc/o_r/old.json" "$T/h/gc/o_r/old.meta"
cache wb_gc "$T/h/gc" >/dev/null
[ ! -e "$T/h/gc/o_r/old.json" ] && [ ! -e "$T/h/gc/o_r/old.meta" ] && [ -e "$T/h/gc/o_r/new.json" ] && [ -e "$T/h/gc/o_r/new.meta" ] && ok \
  || bad "WB16 wb_gc left: $(ls "$T/h/gc/o_r")"

echo "wake-backstop: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
