#!/bin/bash
# tests/br-split-layout-test.sh — the layout contract for the bin/lib/br/ split
# (BH-1176, the first slice: ladder + record). The sibling slices that move the
# discovery reads, the gates and the rungs are judged by this same file.
#
# WHY THE SPLIT. bin/blocked-resolver.sh is a 3,778-line lane that 19 of the
# last 200 merges touched; it and its suite were 2 of the 5 files that produced
# 40 of one day's 53 merge conflicts. Two builds that touch two unrelated
# concerns conflict in one file neither ticket is about. The split moves the
# lane's sections into bin/lib/br/{ladder,record,…}.sh one slice at a time.
#
# WHAT IT PINS, AND WHY EACH ONE IS HERE.
#   1. the modules exist, parse, and source clean on their own — they are pure
#      function definitions, so neither needs the other and neither needs the
#      lane's globals to LOAD.
#   2. no function is defined by two modules. A name that moves twice is a
#      silent behaviour change: last one sourced wins.
#   3. nothing is misplaced and nothing is missing — the set a module defines is
#      EXACTLY the set tests/br/expected-map.tsv assigns it. Both directions,
#      because this slice is complete for its two modules.
#   4. A `lib` ROW IS DARK. That function is still defined inline in
#      bin/blocked-resolver.sh, BELOW the source loop, and the module's copy is
#      BYTE-IDENTICAL to the inline one. That is what "lands dark" means here:
#      the inline definition wins, the module is inert, and the cut is a pure
#      deletion whose diff this test will keep honest. A `mod` row is CUT
#      (BH-5241): the module defines it and bin/blocked-resolver.sh does not.
#   5. nothing runs on source. A module that did something on source would do it
#      on every tick of every project on every box the moment harness-sync ships
#      it, and the lane sources them before it has decided anything.
#   6. the loop is real and it is LOUD. A module the lane cannot read, or one it
#      reads and cannot use (a half-rsynced file: `rsync -a` in
#      bin/harness-sync.sh writes bin/ per FILE), must end the tick with one
#      ALERTS line — not carry on with half a classifier, which is a drain that
#      answers `none` to every park and logs like a quiet tick.
#
# HOW IT MEASURES. Runtime `declare -F` / `declare -f` after sourcing for the
# ownership questions, never a grep over source text: only bash can say what a
# file DEFINES. The darkness check is the opposite on purpose — it compares the
# two texts byte for byte, because "the module is a copy" is a claim about
# characters. Cases 6a–6c drive the REAL bin/blocked-resolver.sh against a
# scratch $HARNESS and assert on artifacts (exit code, ALERTS.log), never on
# what somebody typed.
#
# No clock, no network, no gh, no git. Nothing outside $T is written.
#
# Run from anywhere: tests/br-split-layout-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

BR="$DIR/bin/blocked-resolver.sh"
BRD="$DIR/bin/lib/br"
MAP="$DIR/tests/br/expected-map.tsv"
MODULES="discovery keys ladder record cap headgate"

# fn_body <file> <name> — the function's source as the file carries it:
# `^name() {` through the next `^}`. The same extraction five resolver suites
# already use on this script, so "byte-identical" here means identical to what
# those suites read — plus the one-line case those suites never needed, because
# `br_rkey() { …; }` and `br_file() { …; }` open and close on one line and the
# plain form would run on into the NEXT function looking for a bare `}`.
# The opening line is matched as a LITERAL PREFIX, never as a regex. `br_x() {`
# built into a dynamic regex needs \( \) \{ escaped, and gawk reads those three
# escapes back as the METACHARACTERS — so on any box whose awk is gawk the
# pattern matched nothing, every function read as "no longer defined inline",
# and case 4 (the whole darkness proof) went red for a reason that had nothing
# to do with the code. substr() has no such reading.
fn_body() {
  awk -v P="$2() {" '
    !f && substr($0, 1, length(P)) == P && /\}[[:space:]]*$/ { print; exit }
    substr($0, 1, length(P)) == P    { f=1 }
    f                                { print }
    f && /^\}$/                      { exit }' "$1"
}

# ── the two drivers ─────────────────────────────────────────────────────────
# fns.sh <brdir> <module...> — source the modules in order, print what they
# define (a new name, or a name whose body changed). rc 3 if a source fails, so
# a module that died can never read as "defines nothing".
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

# quiet.sh <brdir> <harness> <module...> — source the modules with $HARNESS
# pointed at a scratch tree and print nothing of its own. Whatever reaches
# stdout/stderr, and whatever appears under the tree, is the module's doing.
cat > "$T/quiet.sh" <<'QUIET'
#!/bin/bash
set -uo pipefail
d="$1"; H="$2"; shift 2
for m in "$@"; do
  # shellcheck source=/dev/null
  . "$d/$m.sh" || exit 3
done
exit 0
QUIET

# ── 1. the modules exist, parse, and source clean on their own ──────────────
for m in $MODULES; do
  [ -f "$BRD/$m.sh" ] && ok || bad "1: bin/lib/br/$m.sh must exist"
done
for m in $MODULES; do
  bash -n "$BRD/$m.sh" 2>/dev/null && ok || bad "1: bin/lib/br/$m.sh must pass bash -n"
done
for m in $MODULES; do
  bash "$T/fns.sh" "$BRD" "$m" >/dev/null 2>&1 && ok \
    || bad "1: bin/lib/br/$m.sh must source clean on its own"
done

# ── 2/3. ownership: no overlap, nothing misplaced, nothing missing ──────────
SETS="$T/sets"; mkdir -p "$SETS"
SETS_OK=1
for m in $MODULES; do
  if bash "$T/fns.sh" "$BRD" "$m" > "$SETS/$m.raw" 2>/dev/null; then
    sort "$SETS/$m.raw" > "$SETS/$m.txt"
  else
    SETS_OK=0; : > "$SETS/$m.txt"
  fi
done
if [ "$SETS_OK" = 1 ]; then ok; else bad "2: every module must source before its function set can be read"; fi
DUPS=$(cat "$SETS"/*.txt | grep -v '^$' | sort | uniq -d)
[ -z "$DUPS" ] && ok || bad "2: defined by more than one module: $(printf '%s' "$DUPS" | tr '\n' ' ')"

# Guard the map first: a truncated or missing map would make every row below
# vacuous rather than red.
if [ -s "$MAP" ] && grep -qxF "$(printf 'ladder\tbr_action\tmod')" "$MAP"; then ok
else bad "3: $MAP must exist and assign the lane's functions (ladder/br_action row missing)"; fi

MIS=0
for m in $MODULES; do
  while read -r n; do
    [ -n "$n" ] || continue
    if ! grep -qxF "$(printf '%s\t%s\tlib' "$m" "$n")" "$MAP" \
       && ! grep -qxF "$(printf '%s\t%s\tmod' "$m" "$n")" "$MAP"; then
      MIS=$((MIS+1))
      echo "  misplaced: $n is defined by br/$m.sh; the map says '$(awk -F'\t' -v n="$n" '$2==n{print $1}' "$MAP")'"
    fi
  done < "$SETS/$m.txt"
done
[ "$MIS" -eq 0 ] && ok || bad "3: $MIS function(s) defined by a module the map does not assign them to"

# …and the reverse. mc/'s layout suite defers this to its last slice; here the
# slice is COMPLETE for these two modules, so a mapped function that never
# arrived is a finding now rather than three slices from now.
MISSING=0
for m in $MODULES; do
  while IFS=$'\t' read -r mod n _; do
    case "$mod" in "$m") ;; *) continue ;; esac
    grep -qxF "$n" "$SETS/$m.txt" || { MISSING=$((MISSING+1)); echo "  missing: the map assigns $n to br/$m.sh, which does not define it"; }
  done < <(grep -v '^#' "$MAP")
done
[ "$MISSING" -eq 0 ] && ok || bad "3: $MISSING mapped function(s) are not defined by the module the map assigns them to"

# ── 4. a `lib` row is DARK: the module's copy is byte-identical to the inline ──
# one, and the inline one is still there. Delete the inline copy without saying
# so and this goes red; change either copy alone and this goes red. A `mod` row
# is CUT: the module carries it and the inline copy is gone, so putting one back
# inline goes red too.
DARK=0; DARKN=0
while IFS=$'\t' read -r mod n origin; do
  [ -n "$n" ] || continue
  DARKN=$((DARKN+1))
  inline=$(fn_body "$BR" "$n")
  modbody=$(fn_body "$BRD/$mod.sh" "$n")
  if [ "$origin" = mod ]; then
    if [ -n "$inline" ]; then
      DARK=$((DARK+1)); echo "  not cut: $n is a 'mod' row but bin/blocked-resolver.sh still defines it inline"
    elif [ -z "$modbody" ]; then
      DARK=$((DARK+1)); echo "  not cut: bin/lib/br/$mod.sh carries no '^$n() {' … '^}' block"
    fi
  elif [ -z "$inline" ]; then
    DARK=$((DARK+1)); echo "  not dark: $n is no longer defined inline in bin/blocked-resolver.sh (the cut happened without updating tests/br/expected-map.tsv)"
  elif [ -z "$modbody" ]; then
    DARK=$((DARK+1)); echo "  not dark: bin/lib/br/$mod.sh carries no '^$n() {' … '^}' block"
  elif [ "$inline" != "$modbody" ]; then
    DARK=$((DARK+1)); echo "  not dark: $n differs between bin/blocked-resolver.sh and bin/lib/br/$mod.sh"
    diff <(printf '%s\n' "$inline") <(printf '%s\n' "$modbody") | head -12
  fi
done < <(grep -v '^#' "$MAP")
[ "$DARKN" -ge 18 ] && ok || bad "4: the map carries $DARKN function rows, expected at least 18 — a shrunken map makes this check vacuous"
[ "$DARK" -eq 0 ] && ok || bad "4: $DARK of $DARKN mapped functions are not a byte-identical copy of the inline one (lib) or not cut from the driver (mod)"

# ── 5. nothing runs on source ───────────────────────────────────────────────
Q="$T/q"; mkdir -p "$Q/logs" "$Q/state" "$Q/flags" "$Q/locks"
QOUT=$(HARNESS="$Q" bash "$T/quiet.sh" "$BRD" "$Q" $MODULES 2>"$T/q.err")
QRC=$?
[ "$QRC" -eq 0 ] && ok || bad "5: sourcing the modules must succeed (rc=$QRC): $(tail -2 "$T/q.err" | tr '\n' ' ')"
[ -z "$QOUT" ] && ok || bad "5: sourcing the modules printed to stdout: $QOUT"
[ ! -s "$T/q.err" ] && ok || bad "5: sourcing the modules printed to stderr: $(tail -2 "$T/q.err" | tr '\n' ' ')"
[ -z "$(ls -A "$Q/state" 2>/dev/null)" ] && ok || bad "5: sourcing the modules wrote into state/: $(ls -A "$Q/state")"
[ -z "$(ls -A "$Q/logs"  2>/dev/null)" ] && ok || bad "5: sourcing the modules wrote into logs/: $(ls -A "$Q/logs")"

# ── 6. the lane really sources them, and refuses when it cannot ─────────────
# The scratch harness the three cases below share. It is the smallest tree
# bin/blocked-resolver.sh will start in: the four libs it hard-requires, a
# fleet.conf, and stubs for everything it may reach. No project is named on the
# command line, so the drain has nothing to do and the run is over in one pass.
H="$T/h"
mkdir -p "$H/bin/lib/br" "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/flags" \
         "$H/locks" "$H/env" "$H/builds" "$H/state/merge-conductor" "$T/fakebin"
cp "$BR" "$H/bin/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/rebuild-ledger.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$BRD"/*.sh "$H/bin/lib/br/"
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh agent-call.sh run-build.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
run_lane() { # run_lane -> rc; the lane's own stdout/stderr land in $T/lane.out
  ( unset HARNESS; HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
      bash "$H/bin/blocked-resolver.sh" nosuchproject ) > "$T/lane.out" 2>&1
}

# 6a — the loop is REAL. A canary is the direct proof that record.sh was
# sourced, apart from the functions it defines.
# It goes into the SCRATCH copy of a module, never the shipped one.
: > "$H/logs/ALERTS.log"
printf 'printf %%s canary > "%s/br-sourced"\n' "$T" >> "$H/bin/lib/br/record.sh"
rm -f "$T/br-sourced"
run_lane; RC6A=$?
cp "$BRD/record.sh" "$H/bin/lib/br/record.sh"
[ -s "$T/br-sourced" ] && ok \
  || bad "6a: bin/blocked-resolver.sh never sourced bin/lib/br/*.sh — the loop is missing or sits behind an earlier exit (lane rc=$RC6A: $(tail -2 "$T/lane.out" | tr '\n' ' '))"
[ "$RC6A" -eq 0 ] && ok || bad "6a: a tick with every module present must not refuse (rc=$RC6A): $(tail -3 "$T/lane.out" | tr '\n' ' ')"

# 6b — a module it cannot READ ends the tick, loudly and once.
: > "$H/logs/ALERTS.log"
mv "$H/bin/lib/br/ladder.sh" "$T/ladder.aside"
run_lane; RC6B=$?
mv "$T/ladder.aside" "$H/bin/lib/br/ladder.sh"
[ "$RC6B" -eq 1 ] && ok || bad "6b: a tick with bin/lib/br/ladder.sh unreadable exited $RC6B, not 1 — it did not refuse"
N6B=$(grep -cF "RESOLVER MODULE MISSING: bin/lib/br/ladder.sh" "$H/logs/ALERTS.log" 2>/dev/null)
[ "${N6B:-0}" = 1 ] && ok \
  || bad "6b: a refused tick wrote ${N6B:-0} 'RESOLVER MODULE MISSING: bin/lib/br/ladder.sh' lines to logs/ALERTS.log, expected exactly 1"

# 6c — a module it can READ but cannot USE ends the tick too. This is the
# likelier half: bin/harness-sync.sh rsyncs per FILE, so a tick that fires
# mid-sync reads a TRUNCATED module. `[ -r ]` is true for it, the source fails,
# and a loop that discards the source's exit status would carry on with the
# classifier half-loaded and log rc=0.
: > "$H/logs/ALERTS.log"
cp "$BRD/ladder.sh" "$T/ladder.whole"
# Cut one line INTO the first function body, so the truncation is an unclosed
# brace whatever the module grows to. Half the file is not good enough: a module
# whose middle happens to fall in a comment block truncates to something that
# still parses, and the three checks below would then be asserting nothing.
TRUNC_AT=$(awk '/^br_[a-z_]*\(\) \{/{print NR+1; exit}' "$T/ladder.whole")
head -n "${TRUNC_AT:-1}" "$T/ladder.whole" > "$H/bin/lib/br/ladder.sh"
# Guard: the fixture has to be genuinely unusable, or the two checks below pass
# against a file the lane was right to accept and prove nothing.
if [ -r "$H/bin/lib/br/ladder.sh" ] && ! bash -n "$H/bin/lib/br/ladder.sh" 2>/dev/null; then ok
else bad "6c: the truncated bin/lib/br/ladder.sh still parses (or is unreadable) — this fixture does not test a half-rsynced file"; fi
run_lane; RC6C=$?
cp "$T/ladder.whole" "$H/bin/lib/br/ladder.sh"
[ "$RC6C" -eq 1 ] && ok \
  || bad "6c: a tick with bin/lib/br/ladder.sh truncated exited $RC6C, not 1 — the loop discarded the source's exit status and failed open"
N6C=$(grep -cF "RESOLVER MODULE MISSING: bin/lib/br/ladder.sh" "$H/logs/ALERTS.log" 2>/dev/null)
[ "${N6C:-0}" = 1 ] && ok \
  || bad "6c: a tick with a truncated module wrote ${N6C:-0} 'RESOLVER MODULE MISSING' lines to logs/ALERTS.log, expected exactly 1"

# 6d — the module list is a LITERAL. tests and the sibling slices read it off
# this line; a computed one would be the lane running code inside every reader.
grep -qxF 'BR_MODULES="discovery keys ladder record cap headgate"' "$BR" && ok \
  || bad "6d: bin/blocked-resolver.sh must carry the literal BR_MODULES line, got: $(grep -m1 '^BR_MODULES=' "$BR")"

# ── 7. the fixture rule, ratcheted ──────────────────────────────────────────
# Every suite that copies bin/blocked-resolver.sh into a scratch tree must also
# carry bin/lib/br/, or the copy refuses its own tick (case 6b) and the suite
# reads as a behaviour failure in whatever it was actually asserting. The same
# shape as tests/jobs-client-modules.bh-1194-test.sh case 5, and here for the
# same reason: a NEW fixture must not be able to reintroduce the failure the
# refusal exists to report. The rebase onto main found exactly one such fixture
# (tests/blocked-resolver.bh-1047-test.sh, added by #1103 while this branch was
# open), which is what a hand sweep catches once and a ratchet catches forever.
#
# Only a cp whose SOURCE is the real lane counts. The skip is br_modules_install
# (the one call that installs them) or the PATH itself, which is what the suite
# that drives the refusal and the suite that copies the modules by hand carry.
MISS=""
for t in "$DIR"/tests/*.sh; do
  grep -qE 'br_modules_install|bin/lib/br' "$t" && continue
  sed -e :a -e '/\\$/N; s/\\\n/ /; ta' "$t" \
    | awk '/(^|[;&|(]|[[:space:]])cp[[:space:]]/ {
             for (i = 1; i < NF; i++) if ($i ~ /bin\/blocked-resolver\.sh"?$/) { found = 1 }
           } END { exit found ? 0 : 1 }' \
    && MISS="$MISS $(basename "$t")"
done
[ -z "$MISS" ] && ok || bad "7: these fixtures copy bin/blocked-resolver.sh without bin/lib/br/*.sh:$MISS"

echo "br-split-layout-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
