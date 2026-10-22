#!/bin/bash
# tests/gh-rest-etag.bh-1322-test.sh — BH-1322: the ETag COUNTER file (the one
# _gh_etag_count appends to, named by GH_ETAG_COUNT_FILE) must not survive a
# lane that is killed before gh_rest_etag_report, and GH_ETAG_MAX_BYTES must
# bound BYTES, not characters.
#
# Two defects, both proven here against the pre-fix library:
#   1. the counter file lived in ${TMPDIR:-/tmp} and gh_rest_etag_report was
#      its only remover — a SIGKILLed tick leaked one file per tick, for ever;
#   2. `${#body}` under a UTF-8 locale is a CHARACTER count, so a multi-byte
#      body over the cap was cached anyway.
#
# Rows: A killed-before-report, B parent/child, C the EXIT-trap idiom under
# SIGTERM, D the TTL/junk backstop, E the three lanes' arming lines (guarded
# source pin), F the byte cap on a multi-byte body, G mutation checks (D1).
#
# Same stub-`gh` scaffold as tests/gh-rest-etag-test.sh (copied, not sourced:
# that suite is a whole-library contract and must stay runnable on its own).
#
# Run from anywhere: bash tests/gh-rest-etag.bh-1322-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/gh-rest.sh"
ELIB="$DIR/bin/lib/gh-rest-etag.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/tmp" "$T/bin" "$T/fx"
export TMPDIR="$T/tmp"
export PATH="$T/bin:$PATH"
export GH_STUB_DIR="$T"
COUNTS="$T/h/state/gh-etag/counts"

# ── the stub `gh` — identical shape to tests/gh-rest-etag-test.sh ───────────
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
D="$GH_STUB_DIR"
printf '%s\n' "$*" >> "$D/gh-calls.txt"
f=$(find "$D/fx" -maxdepth 1 -type f -name '[0-9][0-9]' 2>/dev/null | sort | head -1)
[ -n "$f" ] || exit 1
rc=0
[ -f "$f.rc" ] && rc=$(cat "$f.rc")
cat "$f"
rm -f "$f" "$f.rc"
exit "$rc"
STUB
chmod +x "$T/bin/gh"

FXN=0
fx() { # fx <status> [body] [etag]
  FXN=$((FXN + 1))
  local f rc
  f="$T/fx/$(printf '%02d' "$FXN")"
  { printf 'HTTP/2.0 %s Status\r\n' "$1"
    printf 'X-RateLimit-Remaining: 0\r\n'
    [ -n "${3:-}" ] && printf 'ETag: %s\r\n' "$3"
    printf '\r\n'
    printf '%s' "${2:-}"
  } > "$f"
  rc=0; case "$1" in 2*) rc=0 ;; *) rc=1 ;; esac
  printf '%s' "$rc" > "$f.rc"
}
reset() {
  rm -rf "$T/fx" "$T/h/state/gh-etag"
  mkdir -p "$T/fx"
  FXN=0
  rm -f "$T/gh-calls.txt" "$T/out"
  unset GH_ETAG GH_ETAG_TTL_H GH_ETAG_MAX GH_ETAG_MAX_BYTES GH_ETAG_COUNT_FILE GH_LIMIT_IDENTITY
}
cachefiles() { find "$T/h/state/gh-etag" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }
countfiles() { find "$COUNTS" -maxdepth 1 -type f -name "$1" 2>/dev/null | wc -l | tr -d ' '; }

if ! . "$LIB"; then
  bad "bin/lib/gh-rest.sh is missing or cannot be sourced — every row below is red"
fi
if ! command -v _gh_etag_count >/dev/null 2>&1; then
  bad "bin/lib/gh-rest-etag.sh did not load — gh-rest.sh sources it, so this is the library, not the test"
fi

# ══ A. armed, one read, SIGKILLed before the report ═════════════════════════
# The lane shape the ticket describes: a tick arms a counter file, takes one
# GET through the production entry point (gh_rest, with the stub `gh`), and is
# killed before it can call gh_rest_etag_report. Nothing in the lane removes
# the file, so the NEXT report from any lane on the box has to.
reset
fx 200 '{"a":1}' '"v1"'
rm -f "$T/a.err"
( export GH_ETAG_COUNT_FILE="$COUNTS/demo.$BASHPID"
  gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
  # guards a vacuous pass: the row proves nothing unless the read really did
  # write one `fetched` line to the armed file before the kill.
  [ -f "$GH_ETAG_COUNT_FILE" ] \
    || echo "A: the armed counter file $GH_ETAG_COUNT_FILE was never created by a counted GET" >> "$T/a.err"
  [ "$(grep -c '^fetched$' "$GH_ETAG_COUNT_FILE" 2>/dev/null)" = 1 ] \
    || echo "A: armed counter file does not hold exactly one 'fetched' line" >> "$T/a.err"
  kill -KILL $BASHPID )
if [ -s "$T/a.err" ]; then bad "$(cat "$T/a.err")"; else ok; fi
[ "$(countfiles 'demo.*')" = 1 ] \
  && ok || bad "A: a SIGKILLed lane must leave its counter file behind (that IS the leak) — found $(countfiles 'demo.*')"
gh_rest_etag_report other-lane
[ "$(countfiles 'demo.*')" = 0 ] \
  && ok || bad "A: the next gh_rest_etag_report must sweep the dead lane's counter file — $(countfiles 'demo.*') left"

# ══ B. parent/child: a child's kill never costs the parent its file ═════════
reset
export GH_ETAG_COUNT_FILE="$COUNTS/p.$BASHPID"
PFILE="$GH_ETAG_COUNT_FILE"
rm -f "$T/h/logs/gh-rate.log"
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/1 >/dev/null 2>&1
[ -f "$PFILE" ] || bad "B setup: the parent's own armed counter file was not written"
fx 200 '{"b":2}' '"v2"'
( export GH_ETAG_COUNT_FILE="$COUNTS/c.$BASHPID"
  gh_rest GET repos/o/r/pulls/2 >/dev/null 2>&1
  touch "$T/child-ready"
  sleep 30 ) &
CPID=$!
i=0; while [ ! -f "$T/child-ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
[ "$(countfiles 'c.*')" = 1 ] || bad "B setup: the child lane did not arm its own counter file"
kill -KILL "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null
_gh_etag_counts_sweep
[ "$(countfiles 'c.*')" = 0 ] \
  && ok || bad "B: the killed child's counter file survived the sweep"
[ -f "$PFILE" ] \
  && ok || bad "B: the sweep removed the LIVE parent's counter file"
gh_rest_etag_report p-lane
LINE=$(tail -1 "$T/h/logs/gh-rate.log" 2>/dev/null)
case "$LINE" in
  *"gh-etag lane=p-lane fetched=1 cached=0"*) ok ;;
  *) bad "B: report must still be the normal path — want 'gh-etag lane=p-lane fetched=1 cached=0', got '$LINE'" ;;
esac
[ ! -e "$PFILE" ] \
  && ok || bad "B: the parent's counter file was not cleared by its own report"
unset GH_ETAG_COUNT_FILE

# ══ C. the EXIT-trap idiom under SIGTERM (the normal-kill path) ═════════════
# No sweep runs in this row: the trap alone must clear the file, which is what
# the three arming lanes install. A `bash -c` child is the honest stand-in for
# a lane process — a subshell of this suite would share its traps.
reset
cat > "$T/lane.sh" <<'LANE'
#!/bin/bash
set -uo pipefail
. "$LIBPATH" || exit 9
export GH_ETAG_COUNT_FILE="$COUNTS/trapped.$$"
trap 'rm -f "$GH_ETAG_COUNT_FILE"' EXIT
gh_rest GET repos/o/r/pulls/3 >/dev/null 2>&1
touch "$READY"
# Idle until the test's SIGTERM lands. A foreground `sleep 30` here is a fixed
# wait standing in for a condition — the shape the determinism lint rejects —
# and it also holds the signal for whatever is left on it. Tick in a bounded
# loop instead: bash acts on the TERM inside one 0.05s tick, and if the
# deadline ever wins, the loop falls through and leaves a marker so the row
# FAILS loudly rather than green-ing on a self-exit the EXIT trap also cleans.
i=0
while [ "$i" -lt 600 ]; do sleep 0.05; i=$((i+1)); done
: > "$DEADLINE"
LANE
chmod +x "$T/lane.sh"
fx 200 '{"c":3}' '"v3"'
rm -f "$T/lane-ready" "$T/lane-deadline"
LIBPATH="$LIB" COUNTS="$COUNTS" READY="$T/lane-ready" DEADLINE="$T/lane-deadline" \
  bash "$T/lane.sh" &
LPID=$!
i=0; while [ ! -f "$T/lane-ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
[ "$(countfiles 'trapped.*')" = 1 ] \
  && ok || bad "C setup: the trapped lane never wrote a counter file (found $(countfiles 'trapped.*'))"
kill -TERM "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
[ ! -e "$T/lane-deadline" ] \
  && ok || bad "C setup: the lane outlived its idle deadline instead of dying to the SIGTERM — the row below proves nothing about the trap"
[ "$(countfiles 'trapped.*')" = 0 ] \
  && ok || bad "C: the EXIT trap must remove the counter file on SIGTERM, with no sweep involved"

# ══ D. the sweep's rules: dead pid, junk name, age — and a live pid stays ═══
reset
mkdir -p "$COUNTS"
printf 'fetched\n' > "$COUNTS/old.$$"
touch -t 202001010000 "$COUNTS/old.$$" 2>/dev/null || touch -d '2020-01-01' "$COUNTS/old.$$" 2>/dev/null
printf 'fetched\n' > "$COUNTS/live.$$"
printf 'fetched\n' > "$COUNTS/junk.notapid"
_gh_etag_counts_sweep
[ ! -e "$COUNTS/old.$$" ] \
  && ok || bad "D: a counter file older than GH_ETAG_TTL_H must go even when its pid is alive (recycled-pid backstop)"
[ -f "$COUNTS/live.$$" ] \
  && ok || bad "D: a fresh counter file whose pid is alive must survive the sweep"
[ ! -e "$COUNTS/junk.notapid" ] \
  && ok || bad "D: a name with no numeric pid suffix is never a valid counter file and must go"
rm -f "$COUNTS/live.$$"

# ══ E. lane pin (guarded source pin, D3): the three reporting lanes arm under
# the counts dir, none of them arms in $TMPDIR any more, and the conductor's
# per-project subshell keys on $BASHPID, not $$ ═════════════════════════════
for L in reconcile-prs merge-sweep merge-conductor; do
  F="$DIR/bin/$L.sh"
  if [ ! -r "$F" ]; then bad "E: bin/$L.sh is missing — the arming site cannot be pinned"; continue; fi
  [ "$(grep -c 'state/gh-etag/counts/' "$F")" -ge 1 ] \
    && ok || bad "E: bin/$L.sh does not arm GH_ETAG_COUNT_FILE under state/gh-etag/counts/"
  [ "$(grep -c 'gh-etag-count\.' "$F")" = 0 ] \
    && ok || bad "E: bin/$L.sh still names the old \$TMPDIR counter file (gh-etag-count.*)"
done
# BH-7879: the per-project subshell lives in mc_tick_fanout now.
MC="$DIR/bin/lib/mc/tick-scope.sh"
if [ -r "$MC" ]; then
  grep -q 'state/gh-etag/counts/merge-conductor\.\$P\.\$BASHPID' "$MC" \
    && ok || bad "E: merge-conductor's per-project subshell must key its counter file on \$BASHPID, not \$\$"
else
  bad "E: bin/lib/mc/tick-scope.sh is missing — the per-project pin cannot be checked"
fi

# ══ F. GH_ETAG_MAX_BYTES bounds BYTES, not characters ══════════════════════
UTF8_OK=0
if [ "$(LC_ALL=C.UTF-8 bash -c 's=é; echo ${#s}')" = 1 ]; then UTF8_OK=1; else echo "skip: no UTF-8 locale on this box — section F not run"; fi
if [ "$UTF8_OK" = 1 ]; then
  export LC_ALL=C.UTF-8
  reset
  export GH_ETAG_MAX_BYTES=8
  fx 200 'ééééé' '"vb1"'          # 5 characters, 10 bytes — over the cap
  gh_rest GET repos/o/r/pulls/11 >/dev/null 2>&1
  [ "$(cachefiles)" = 0 ] \
    && ok || bad "F: a 5-character/10-byte body must not be cached under GH_ETAG_MAX_BYTES=8 (the cap counts BYTES)"
  reset
  export GH_ETAG_MAX_BYTES=8
  fx 200 'éééé' '"vb2"'           # 4 characters, 8 bytes — exactly the cap
  gh_rest GET repos/o/r/pulls/12 >/dev/null 2>&1
  [ "$(cachefiles)" = 1 ] \
    && ok || bad "F: a body of exactly GH_ETAG_MAX_BYTES bytes must still be cached (the cap is inclusive)"
  [ "$LC_ALL" = C.UTF-8 ] \
    && ok || bad "F: the byte-measuring helper leaked its LC_ALL into the caller (LC_ALL=$LC_ALL)"
  unset GH_ETAG_MAX_BYTES
  unset LC_ALL
fi

# ══ G. mutation checks (D1): break the sweep's liveness test and the byte
# helper's locale, and the rows above must go red ═══════════════════════════
cat > "$T/core.sh" <<'CORE'
set -uo pipefail
LIB=$1; ELIB=$2; T=$3; LABEL=$4
export HARNESS="$T/h-$LABEL"
mkdir -p "$HARNESS/state" "$HARNESS/logs"
F=0
say() { F=$((F + 1)); echo "  core($LABEL): $1"; }
GH_REST_ETAG_LIB=""
. "$ELIB" || { echo "  core($LABEL): cannot source $ELIB"; exit 9; }
GH_REST_LIB=""
. "$LIB" || { echo "  core($LABEL): cannot source $LIB"; exit 9; }
CDIR="$HARNESS/state/gh-etag/counts"
rm -rf "$T/fx"; mkdir -p "$T/fx"
FXN=0
fx() {
  FXN=$((FXN + 1))
  local f rc
  f="$T/fx/$(printf '%02d' "$FXN")"
  { printf 'HTTP/2.0 %s Status\r\n' "$1"
    [ -n "${3:-}" ] && printf 'ETag: %s\r\n' "$3"
    printf '\r\n'
    printf '%s' "${2:-}"
  } > "$f"
  rc=0; case "$1" in 2*) rc=0 ;; *) rc=1 ;; esac
  printf '%s' "$rc" > "$f.rc"
}
ncount() { find "$CDIR" -maxdepth 1 -type f -name "$1" 2>/dev/null | wc -l | tr -d ' '; }

# killed-before-report: the dead lane's file must not survive the next report
rm -f "$T/core-$LABEL.err"
fx 200 '{"a":1}' '"v1"'
( export GH_ETAG_COUNT_FILE="$CDIR/demo.$BASHPID"
  gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
  [ -f "$GH_ETAG_COUNT_FILE" ] || echo "armed counter file missing" >> "$T/core-$LABEL.err"
  kill -KILL $BASHPID )
[ -s "$T/core-$LABEL.err" ] && say "$(cat "$T/core-$LABEL.err")"
[ "$(ncount 'demo.*')" = 1 ] || say "the killed lane left no counter file to sweep"
gh_rest_etag_report core-lane
[ "$(ncount 'demo.*')" = 0 ] || say "a dead pid's counter file survived the report's sweep"

# byte cap on a multi-byte body, only where a UTF-8 locale exists
if [ "${UTF8_OK:-0}" = 1 ]; then
  export LC_ALL=C.UTF-8
  rm -rf "$HARNESS/state/gh-etag"
  rm -f "$T/fx"/*; FXN=0
  export GH_ETAG_MAX_BYTES=8
  fx 200 'ééééé' '"vb1"'
  gh_rest GET repos/o/r/pulls/11 >/dev/null 2>&1
  N=$(find "$HARNESS/state/gh-etag" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 0 ] || say "a 10-byte body was cached under an 8-byte cap"
  unset GH_ETAG_MAX_BYTES LC_ALL
fi
exit "$F"
CORE
mkdir -p "$T/mut"
export GH_STUB_DIR="$T"
export UTF8_OK
if UTF8_OK="$UTF8_OK" bash "$T/core.sh" "$LIB" "$ELIB" "$T" real >"$T/core.log" 2>&1; then ok
else bad "G: the mutation runner is red against the REAL libraries: $(cat "$T/core.log")"; fi

mut() { # mut <n> <label> <sed expression on the etag lib>
  local n=$1 label=$2 expr=$3 dst
  dst="$T/mut/m$n.sh"
  cp "$ELIB" "$dst" 2>/dev/null || { bad "G: mutant $n ($label): no library to mutate"; return; }
  sed -i "$expr" "$dst"
  if cmp -s "$ELIB" "$dst"; then
    bad "G: mutant $n ($label): the mutation changed nothing — the row it guards is untested"
    return
  fi
  if UTF8_OK="$UTF8_OK" bash "$T/core.sh" "$LIB" "$dst" "$T" "m$n" >/dev/null 2>&1; then
    bad "G: mutant $n ($label): the suite stayed GREEN under the mutation"
  else
    echo "mutant $n caught ($label)"; ok
  fi
}
mut 1 'the counts sweep treats every pid as alive' \
  's|if \[ -d "/proc/\$pid" \] \|\| kill -0 "\$pid" 2>/dev/null; then|if true; then|'
if [ "$UTF8_OK" = 1 ]; then
  mut 2 'the byte helper measures characters again' 's/local LC_ALL=C$/local LC_ALL=C.UTF-8/'
fi

echo "gh-rest-etag.bh-1322: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
