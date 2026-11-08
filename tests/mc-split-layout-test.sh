#!/bin/bash
# tests/mc-split-layout-test.sh — the layout contract for the bin/lib/mc/ split
# (BH-477, slice BH-680). This is the suite the three sibling slices (#681,
# #682, #684) are judged by, and it is imported by that exact path.
#
# WHAT IT PINS, AND WHY EACH ONE IS HERE. bin/lib/merge-conductor-lib.sh is a
# 4,530-line monolith that 14 production scripts source on every tick. The
# split moves its sections into bin/lib/mc/{log,locks,classify,queue,rebase,
# settle}.sh one slice at a time, and the only thing standing between "one
# slice landed" and "the conductor half-loads on a box" is this file:
#   1. the six modules exist and source clean behind log.sh
#   2. no function is defined by two modules (a name that moves twice is a
#      silent behaviour change: last one sourced wins)
#   3. nothing is misplaced — a function a module defines is the module
#      tests/mc/expected-map.d/ (the union of its fragments) assigns it to. The reverse (every mapped
#      function is defined) is NOT asserted here; it ships with the last slice.
#   4. every MC_* path global still resolves to its pre-split value. These name
#      live cross-run state; a module extraction that moved one would orphan a
#      state directory on every box, quietly.
#   5. a missing module is a LOUD failure. A bare `. missing.sh` returns 1 and
#      bash carries on, so a half-loaded conductor would classify PRs with
#      half a classifier. The loop must exit the caller instead.
#   6/7. the sources happen in a fixed order with log first, because log.sh
#      owns the globals and mc_log that every other module reads.
#
# HOW IT MEASURES. Runtime `declare -F` / `declare -f` after sourcing, never a
# grep over source text: the question is what a module DEFINES, and only bash
# can answer that (a function inside a case arm, a name built by eval, a
# redefinition of a name log already had). Module sets are compared by name AND
# body hash, so a module that re-defines one of log.sh's functions shows up as
# defining it too.
#
# No clock, no network, no gh, no git: three heredoc drivers and scratch copies
# of the lib under $T. Nothing outside $T is written.
#
# Run from anywhere: tests/mc-split-layout-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/merge-conductor-lib.sh"
MCD="$DIR/bin/lib/mc"
# The map is the union of tests/mc/expected-map.d/*.tsv (Lane E: one fragment
# per change, so two PRs never append to the same hunk). A fragment the
# assembler refuses is a finding here too; the rows it did read still load.
# shellcheck source=tests/lib/mc-expected-map.sh
. "$(dirname "$0")/lib/mc-expected-map.sh" || exit 1
MAP="$T/expected-map.tsv"
mc_expected_map "$DIR/tests/mc/expected-map.d" "$MAP" 2>"$T/map.err" && ok \
  || bad "3: tests/mc/expected-map.d must assemble: $(head -3 "$T/map.err" | tr '\n' ' ')"
MODULES="log locks classify queue rebase settle"
# BH-9239: tests/lib/scratch.sh unsets HARNESS, so bin/lib/mc/log.sh falls back to
# /root/harness, and bin/lib/mc/queue.sh sources the live gh-rest-list.sh and
# gh-policy-cache.sh into the measured set. The fns.sh calls pin HARNESS here.
NOH="$T/no-harness"; mkdir -p "$NOH"

# ── the three drivers ───────────────────────────────────────────────────────
# fns.sh <mcdir> <module...> — source the modules in order, print what they
# define (new name, or a name whose body changed). rc 3 if a source fails, so a
# module that died can never read as "defines nothing".
cat > "$T/fns.sh" <<'FNS'
#!/bin/bash
set -uo pipefail
d="$1"; shift
_dump() {
  local n
  for n in $(declare -F | awk '{print $3}'); do
    printf '%s\t%s\n' "$n" "$(declare -f "$n" | cksum)"
  done | sort
}
_before=$(_dump)
for m in "$@"; do
  # shellcheck source=/dev/null
  . "$d/$m.sh" || exit 3
done
_after=$(_dump)
comm -13 <(printf '%s\n' "$_before") <(printf '%s\n' "$_after") | cut -f1
FNS

# globals.sh <lib> — source the lib and print the MC_* path globals it resolved.
# rc 3 if the lib never got far enough to define the classifier.
cat > "$T/globals.sh" <<'GLOB'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$1" || exit 3
command -v mc_classify >/dev/null || exit 3
for v in MC_LOG MC_STATE_DIR MC_ROWS MC_ATTEMPTS MC_RR_DIR MC_RB_DIR MC_DV_DIR \
         MC_HANDOFF_DIR MC_HANDOFF_REL_DIR MC_HANDOFF_HUMAN_DIR MC_STUCK_DIR \
         MC_BATCH_DIR MC_BATCH_STATE_DIR MC_TICK_DIR MC_LOCK_DIR; do
  printf '%s=%s\n' "$v" "${!v-}"
done
GLOB

# source-lib.sh <lib> — source the lib and report whether the caller survived.
cat > "$T/source-lib.sh" <<'SRC'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$1"
printf 'ORDER=%s\n' "${_mc_order:-}"
echo CONTINUED
SRC

# lib_copy <dir> — a fixture-shaped scratch tree: <dir>/bin/lib/ holds a copy of
# the lib, <dir>/bin/lib/mc/ the modules, so the loop's BASH_SOURCE resolution
# is what is under test and not $HARNESS.
lib_copy() {
  mkdir -p "$1/bin/lib/mc" || return 1
  cp "$LIB" "$1/bin/lib/" || return 1
  cp "$MCD"/*.sh "$1/bin/lib/mc/" 2>/dev/null
  # BH-5240: the shim loads through mc/load.sh, whose order is mc/MODULES (the
  # file prod reads), so the headerless fakes of check 6 still load in order.
  cp "$MCD/MODULES" "$1/bin/lib/mc/" 2>/dev/null
  return 0
}

# ── 1. the six modules exist, parse, and source clean behind log.sh ─────────
for m in $MODULES; do
  [ -f "$MCD/$m.sh" ] && ok || bad "1: bin/lib/mc/$m.sh must exist"
done
for m in $MODULES; do
  bash -n "$MCD/$m.sh" 2>/dev/null && ok || bad "1: bin/lib/mc/$m.sh must pass bash -n"
done
for m in $MODULES; do
  HARNESS="$NOH" bash "$T/fns.sh" "$MCD" log "$m" >/dev/null 2>&1 && ok \
    || bad "1: bin/lib/mc/$m.sh must source clean behind log.sh"
done

# ── 2. no function is defined by two modules ────────────────────────────────
SETS="$T/sets"; mkdir -p "$SETS"
SETS_OK=1
if HARNESS="$NOH" bash "$T/fns.sh" "$MCD" log > "$SETS/log.raw" 2>/dev/null; then
  sort "$SETS/log.raw" > "$SETS/log.txt"
else
  SETS_OK=0; : > "$SETS/log.txt"
fi
for m in locks classify queue rebase settle; do
  if HARNESS="$NOH" bash "$T/fns.sh" "$MCD" log "$m" > "$SETS/with-$m.raw" 2>/dev/null; then
    sort "$SETS/with-$m.raw" > "$SETS/with-$m.txt"
    comm -13 "$SETS/log.txt" "$SETS/with-$m.txt" > "$SETS/$m.txt"
  else
    SETS_OK=0; : > "$SETS/$m.txt"
  fi
done
if [ "$SETS_OK" = 1 ]; then ok; else bad "2: every module must source behind log.sh before its function set can be read"; fi
DUPS=$(cat "$SETS/log.txt" "$SETS"/locks.txt "$SETS"/classify.txt "$SETS"/queue.txt \
           "$SETS"/rebase.txt "$SETS"/settle.txt | grep -v '^$' | sort | uniq -d)
[ -z "$DUPS" ] && ok || bad "2: defined by more than one module: $(printf '%s' "$DUPS" | tr '\n' ' ')"

# ── 3. nothing misplaced: a module defines only what the map assigns it ─────
# Guard the map itself first: a truncated or missing map would make the rows
# below vacuous rather than red.
if [ -s "$MAP" ] && grep -qxF "$(printf 'log\tmc_stamp\tlib')" "$MAP"; then ok
else bad "3: $MAP must exist and assign the lib's functions (log/mc_stamp row missing)"; fi
MIS=0
for m in $MODULES; do
  while read -r n; do
    [ -n "$n" ] || continue
    if ! grep -qxE "$(printf '%s\t%s\t(lib|driver)' "$m" "$n")" "$MAP"; then
      MIS=$((MIS+1))
      echo "  misplaced: $n is defined by mc/$m.sh; the map says '$(awk -F'\t' -v n="$n" '$2==n{print $1}' "$MAP")'"
    fi
  done < "$SETS/$m.txt"
done
[ "$MIS" -eq 0 ] && ok || bad "3: $MIS function(s) defined by a module the map does not assign them to"

# ── 4. every MC_* path global still resolves to its pre-split value ─────────
lib_copy "$T/h" || bad "4: could not build the fixture-shaped copy"
GOUT="$T/globals.out"
HARNESS="$T/h" bash "$T/globals.sh" "$T/h/bin/lib/merge-conductor-lib.sh" \
  > "$GOUT" 2>"$T/globals.err"
GRC=$?
if [ "$GRC" -eq 0 ]; then ok; else bad "4: the fixture-shaped copy must source (rc=$GRC): $(tail -2 "$T/globals.err" | tr '\n' ' ')"; fi
while IFS= read -r want; do
  [ -n "$want" ] || continue
  grep -qxF "$want" "$GOUT" && ok || bad "4: $want (got '$(grep "^${want%%=*}=" "$GOUT")')"
done <<WANT
MC_LOG=$T/h/logs/merge-conductor.log
MC_STATE_DIR=$T/h/state/merge-conductor
MC_ROWS=$T/h/state/merge-conductor/pr-state.tsv
MC_ATTEMPTS=$T/h/state/merge-conductor/attempts.txt
MC_RR_DIR=$T/h/state/merge-conductor/rereview
MC_RB_DIR=$T/h/state/merge-conductor/rebase
MC_DV_DIR=$T/h/state/merge-conductor/deploy-verify
MC_HANDOFF_DIR=$T/h/state/merge-conductor/handoff
MC_HANDOFF_REL_DIR=$T/h/state/merge-conductor/handoff-released
MC_HANDOFF_HUMAN_DIR=$T/h/state/merge-conductor/handoff-human
MC_STUCK_DIR=$T/h/state/merge-conductor/stuck
MC_BATCH_DIR=$T/h/state/merge-conductor/batch-hold
MC_BATCH_STATE_DIR=$T/h/state/batch-resolve
MC_TICK_DIR=$T/h/state/merge-conductor/tick
MC_LOCK_DIR=$T/h/locks
WANT
[ "$(grep -c '^MC_' "$GOUT")" = 15 ] && ok || bad "4: 15 path globals expected, got $(grep -c '^MC_' "$GOUT")"

# ── 5. a missing module is loud, not fail-open ──────────────────────────────
lib_copy "$T/c5" || bad "5: could not build the scratch copy"
rm -f "$T/c5/bin/lib/mc/queue.sh"
OUT5=$(HARNESS=/root/harness bash "$T/source-lib.sh" "$T/c5/bin/lib/merge-conductor-lib.sh" 2>"$T/c5.err")
RC5=$?
[ "$RC5" -ne 0 ] && ok || bad "5: sourcing the lib with mc/queue.sh removed must exit nonzero (rc=$RC5)"
case "$OUT5" in
  *CONTINUED*) bad "5: the caller ran on after a missing module — a half-loaded conductor" ;;
  *)           ok ;;
esac

# ── 6/7. fixed order, log first ─────────────────────────────────────────────
lib_copy "$T/c6" || bad "6: could not build the scratch copy"
for m in $MODULES; do
  printf '_mc_order="${_mc_order:-}%s "\n' "$m" > "$T/c6/bin/lib/mc/$m.sh"
done
OUT6=$(HARNESS=/root/harness bash "$T/source-lib.sh" "$T/c6/bin/lib/merge-conductor-lib.sh" 2>"$T/c6.err")
RC6=$?
ORDER=$(printf '%s\n' "$OUT6" | sed -n 's/^ORDER=//p')
[ "$RC6" -eq 0 ] && ok || bad "6: a complete module set must source cleanly (rc=$RC6): $(tail -2 "$T/c6.err" | tr '\n' ' ')"
[ "$ORDER" = "log locks classify queue rebase settle " ] && ok \
  || bad "6: modules must be sourced in the fixed order, got '$ORDER'"
case "$OUT6" in
  *CONTINUED*) ok ;;
  *)           bad "6: the caller must survive a complete module set" ;;
esac
[ "${ORDER%% *}" = log ] && ok || bad "7: log.sh must be sourced first, got '${ORDER%% *}'"

echo "mc-split-layout-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
