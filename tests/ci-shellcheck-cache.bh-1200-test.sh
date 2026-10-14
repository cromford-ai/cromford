#!/bin/bash
# tests/ci-shellcheck-cache.bh-1200-test.sh — BH-1200: the lint job's ShellCheck
# is pinned, cached PER FILE, and never apt-installed.
#
# WHAT THIS IS GUARDING. The lint job was the critical path of the whole CI run
# at ~12 minutes, and on run 35593567939 the ShellCheck step was 11m42s of an
# 11m50s job. The ticket blamed `apt-get install shellcheck`; the measurement
# says otherwise — the same 367-file corpus takes 3m17s on an idle laptop with
# `user` time equal to `real`, so it is ShellCheck's own single-threaded work on
# a contended vCPU. bin/ci-shellcheck.sh therefore caches the FINDINGS per file
# (keyed on the reported version, the flags, the path and the file's sha256) and
# lints only the misses, in parallel.
#
# A CACHE THAT SKIPS WORK IS A GATE THAT CAN SKIP A FINDING, which is why this
# suite spends most of its length on correctness rather than on speed:
#
#   * a cache HIT must report byte-identical findings and the same exit code as
#     the cold run — a cache that is merely fast and slightly wrong is worse
#     than no cache, because CI stays green;
#   * a CHANGED file must be re-linted, and ONLY that file — proven by counting
#     the fake ShellCheck's invocations, not by reading the code;
#   * a different ShellCheck VERSION must invalidate everything, or a fleet that
#     upgrades its image replays verdicts nobody's binary produced;
#   * identical content at a DIFFERENT path must not be replayed under the first
#     path's name, or the findings would point at the wrong file;
#   * ShellCheck FAILING TO RUN (rc >= 2) must never be cached, or one broken
#     run pins a fake "clean" until somebody edits the file.
#
# …and on top of that, the assumption the whole design rests on is itself
# tested with the REAL binary in block F: per-file caching is sound at error
# severity because no error-level ShellCheck check depends on definitions imported
# from a sourced file. The day that stops being true this suite says so, rather
# than CI silently skipping a finding.
#
# No network, no secrets, no clock, no dice. Run from anywhere: exit 0 = pass.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
WF="${BH1200_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
SCRIPT="${BH1200_SCRIPT:-$DIR/bin/ci-shellcheck.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── A. the workflow calls it, and cannot reach apt for shellcheck ───────────
# Comments stripped and backslash continuations joined, the same reader
# tests/harness-ci-runners.bh-1206-test.sh uses: an assertion that matches the
# prose explaining a step is an assertion about nothing.
if [ -f "$WF" ]; then
  CODE=$(grep -v '^[[:space:]]*#' "$WF" | awk '
    { line = $0
      sub(/^[[:space:]]+/, "", line)
      if (held != "") { line = held " " line; held = "" }
      if (line ~ /\\$/) { sub(/[[:space:]]*\\$/, "", line); held = line; next }
      print line }
    END { if (held != "") print held }')

  case "$CODE" in
    *"bin/ci-shellcheck.sh"*) ok ;;
    *) bad "A: the workflow never calls bin/ci-shellcheck.sh — the lint step is still linting the corpus cold" ;;
  esac

  # THE TICKET'S OWN ACCEPTANCE: no apt-get for shellcheck, anywhere. Scoped to
  # the package list on the line, so the surviving `apt-get install -y -q age
  # zstd` is untouched and a future `apt-get install ... shellcheck ...` is not.
  STRAY=$(printf '%s\n' "$CODE" | grep -n 'apt-get install' | grep 'shellcheck' || true)
  if [ -z "$STRAY" ]; then ok
  else bad "A: the workflow still apt-get installs shellcheck (BH-1200 replaced it with a pinned, verified download):
$STRAY"; fi

  # …and the reader is not vacuous: it must still SEE an apt-get install line,
  # or it would report "no shellcheck apt" forever on an empty file.
  if grep -q 'apt-get install' <<<"$CODE"; then ok
  else bad "A: no apt-get install line at all in the workflow — this check graded nothing"; fi

  # The cache has to persist between runs or the script is only ever cold. On a
  # self-hosted runner the homes are wiped between jobs (docs/CI-RUNNERS.md), so
  # persistence is actions/cache, not a directory on the machine.
  case "$CODE" in
    *"actions/cache@v"*) ok ;;
    *) bad "A: no actions/cache step — every run would start with an empty cache and lint all 367 files" ;;
  esac

  # restore-keys or the cache NEVER hits: the save key carries the commit sha so
  # each run saves a fresh entry, and a run restores the newest prefix match.
  case "$CODE" in
    *restore-keys*) ok ;;
    *) bad "A: the cache step has no restore-keys — an exact-key-only cache built per commit can never be restored" ;;
  esac

  # PARITY, the BH-1206 rule one level on: the key must name the version the
  # script pins. A cache keyed on a version nobody installs is a cache that
  # silently never hits, and it reads as correct.
  PIN=$(sed -n 's/^SHELLCHECK_PIN=//p' "$SCRIPT" | head -1)
  if [ -n "$PIN" ]; then ok; else bad "A: bin/ci-shellcheck.sh declares no SHELLCHECK_PIN"; fi
  if [ -n "$PIN" ] && grep -q "key:.*$PIN" <<<"$CODE"; then ok
  else bad "A: the actions/cache key does not name the pinned ShellCheck $PIN — a version bump would reuse the old cache"; fi

 # The cached path must be the directory the script actually writes to, or the
 # two halves cache nothing in common.
 DEFCACHE=$(sed -n 's/.*BH_SHELLCHECK_CACHE:-\${RUNNER_TEMP:-\/tmp}\/\([a-z-]*\)}.*/\1/p' "$SCRIPT" | head -1)
 if [ -n "$DEFCACHE" ]; then ok; else bad "A: cannot read the script's default cache directory name"; fi
  # BH-1246: the cache entry is findings only. The path is either the whole
  # directory (legacy) or a list covering results/ and fatal/; either way it
  # must name the script's cache dir and must actually cache the findings dirs.
  if [ -n "$DEFCACHE" ]; then
    PATHBLOCK=$(printf '%s\n' "$CODE" | grep -A3 '^path:')
    if grep -q "$DEFCACHE" <<<"$PATHBLOCK"; then ok
    else bad "A: the actions/cache path does not name the script's cache dir '$DEFCACHE' — nothing would be saved"; fi
    if grep -qE "$DEFCACHE/(results|fatal)" <<<"$PATHBLOCK"; then ok
    else bad "A: the actions/cache path does not include '$DEFCACHE/results' and '$DEFCACHE/fatal' — the binary would be cached too"; fi
  else bad "A: cannot read the script's default cache directory name"; fi
else
  bad "A: workflow not found at $WF"
fi

# ── A2. the sha256 pins are allowlisted for the PUBLIC MIRROR ──────────────
# A 64-hex literal is a secret as far as bin/share/leakcheck.py is concerned,
# and it is right about that — the shape of a release checksum and the shape of
# an API key are the same shape. So each pinned checksum is exempted BY EXACT
# LITERAL in two places, and this asserts the three copies agree.
#
# THE POINT IS WHERE THE FAILURE LANDS. Without this, bumping ShellCheck turns
# the share-mirror publish guard red with "this tree is public — none of these
# may ship", which reads like a leak and sends the next person looking for one.
# Here it fails as what it is: a pin that moved and two allowlists that did not.
for F in "$DIR/bin/share/mapping.py" "$DIR/bin/share/overlay/tests/no-client-identifiers-test.sh"; do
  if [ -f "$F" ]; then ok; else bad "A2: $F is missing — the mirror's allowlist cannot be checked"; continue; fi
  MISSING=""
  while read -r SUM; do
    [ -n "$SUM" ] || continue
    grep -q "$SUM" "$F" || MISSING="$MISSING $SUM"
  done <<EOF
$(sed -n 's/^SHELLCHECK_SHA256_[a-z0-9_]*=//p' "$SCRIPT")
EOF
  if [ -z "$MISSING" ]; then ok
  else bad "A2: $(basename "$F") does not allowlist the pinned checksum(s)$MISSING — the mirror publish will refuse this tree as a leak"; fi
done

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT is missing or not executable (BH-1200)"
  echo "ci-shellcheck-cache.bh-1200-test: $PASS passed, $((FAIL+1)) failed"
  exit 1
fi
ok

# ── the fake ShellCheck ─────────────────────────────────────────────────────
# Hermetic: no real binary, no network, and — the point — an INVOCATION COUNTER.
# "was this file re-linted?" is the only question that matters here, and it is
# answered by counting calls, never by reading the cache directory.
mkdir -p "$T/fakebin" "$T/corpus"
cat > "$T/fakebin/shellcheck" <<'FAKE'
#!/bin/bash
# --version, or lint. Appends one line per invocation to $FAKE_COUNT.
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: %s\nlicense: GPLv3\n' "${FAKE_VERSION:-0.11.0}"
  exit 0
fi
F="${*: -1}"
echo "$F" >> "$FAKE_COUNT"
if grep -q 'FAKE_TOOL_FAILURE' "$F" 2>/dev/null; then
  echo "shellcheck: could not read $F" >&2
  exit 2
fi
if grep -q 'FAKE_FINDING' "$F" 2>/dev/null; then
  echo "$F:1:1: error: fake finding for $(grep -c 'FAKE_FINDING' "$F") marker(s) [SC9999]"
  exit 1
fi
exit 0
FAKE
chmod 755 "$T/fakebin/shellcheck"

# TRIPWIRES. The script must never reach a package manager, sudo or the network
# when a binary was handed to it. Each of these records that it was called and
# then fails, so "it worked anyway" is not a way to pass.
for TRAP in apt-get sudo curl; do
  cat > "$T/fakebin/$TRAP" <<TRIP
#!/bin/sh
echo "$TRAP \$*" >> "\$TRIPWIRE"
exit 7
TRIP
  chmod 755 "$T/fakebin/$TRAP"
done
export TRIPWIRE="$T/tripwire"

printf 'echo one\n'                 > "$T/corpus/a.sh"
printf 'echo two\n'                 > "$T/corpus/b.sh"
printf '# FAKE_FINDING\necho x\n'   > "$T/corpus/c.sh"
printf 'echo four\n'                > "$T/corpus/d.sh"

COUNT="$T/count"
: > "$COUNT"
CACHE="$T/cache"

run() { # run [env-overrides...] → rc; stdout+stderr in $T/run.out
  ( PATH="$T/fakebin:$PATH" \
    SHELLCHECK_BIN="$T/fakebin/shellcheck" FAKE_COUNT="$COUNT" \
    "$SCRIPT" --cache-dir "$CACHE" --jobs 2 "$T/corpus"/*.sh >"$T/run.out" 2>&1 )
  echo $?
}
calls() { grep -c . "$COUNT" 2>/dev/null || echo 0; }

# ── B. cold, warm, and the bytes in between ────────────────────────────────
RC1=$(run); OUT1=$(cat "$T/run.out"); N1=$(calls)

case "$OUT1" in
  *"ShellCheck 0.11.0"*) ok ;;
  *) bad "B: the run does not PRINT the ShellCheck version it used (the ticket asks for it): $OUT1" ;;
esac
if [ "$RC1" = 1 ]; then ok; else bad "B: a corpus with a finding must exit 1, got rc=$RC1: $OUT1"; fi
case "$OUT1" in
  *"c.sh:1:1: error: fake finding"*) ok ;;
  *) bad "B: the cold run did not report the finding in c.sh: $OUT1" ;;
esac
if [ "$N1" = 4 ]; then ok; else bad "B: the cold run linted $N1 of 4 files"; fi

# THE HIT MUST BE THE SAME ANSWER, not merely a fast one. Findings and exit
# code both, compared byte for byte against the cold run.
RC2=$(run); OUT2=$(cat "$T/run.out"); N2=$(calls)
if [ "$N2" = 4 ]; then ok; else bad "B: the warm run re-linted $((N2-4)) file(s) — the cache did not hit"; fi
if [ "$RC2" = "$RC1" ]; then ok; else bad "B: a cache hit changed the exit code ($RC1 cold, $RC2 warm)"; fi
F1=$(printf '%s\n' "$OUT1" | grep 'SC9999' || true)
F2=$(printf '%s\n' "$OUT2" | grep 'SC9999' || true)
if [ "$F1" = "$F2" ] && [ -n "$F1" ]; then ok
else bad "B: a cache hit reported different findings than the cold run:
  cold: $F1
  warm: $F2"; fi
case "$OUT2" in
  *"4 files, 4 from cache, 0 linted"*) ok ;;
  *) bad "B: the warm run does not report a full cache hit: $OUT2" ;;
esac

# ── C. invalidation: the half that makes the cache safe ────────────────────
# ONE changed file re-lints ONE file. A whole-corpus key would have re-linted
# all four here, which is why the key is per file.
printf 'echo two changed\n# FAKE_FINDING\n' > "$T/corpus/b.sh"
RC3=$(run); OUT3=$(cat "$T/run.out"); N3=$(calls)
if [ "$((N3-N2))" = 1 ]; then ok; else bad "C: a one-file edit re-linted $((N3-N2)) files — the key is not per file"; fi
case "$OUT3" in
  *"b.sh:1:1: error: fake finding"*) ok ;;
  *) bad "C: the CHANGED file was not re-linted — its new finding is missing: $OUT3" ;;
esac
if [ "$RC3" = 1 ]; then ok; else bad "C: rc after the edit must be 1, got $RC3"; fi

# Reverting the content hits the cache again: the key is the CONTENT, not a
# modification time or a run counter.
printf 'echo two\n' > "$T/corpus/b.sh"
RC4=$(run); N4=$(calls)
if [ "$N4" = "$N3" ]; then ok; else bad "C: reverting a file's contents did not hit its original cache entry"; fi
if [ "$RC4" = 1 ]; then ok; else bad "C: rc after the revert must be 1 (c.sh still has a finding), got $RC4"; fi

# A DIFFERENT VERSION invalidates everything. An image upgraded under a warm
# cache would otherwise replay verdicts the new binary never produced.
N5BEFORE=$(calls)
( PATH="$T/fakebin:$PATH" SHELLCHECK_BIN="$T/fakebin/shellcheck" FAKE_COUNT="$COUNT" FAKE_VERSION=0.12.0 \
  "$SCRIPT" --cache-dir "$CACHE" --jobs 2 "$T/corpus"/*.sh >"$T/run.out" 2>&1 )
RC5=$?; OUT5=$(cat "$T/run.out"); N5=$(calls)
if [ "$((N5-N5BEFORE))" = 4 ]; then ok
else bad "C: a different ShellCheck version re-linted $((N5-N5BEFORE)) of 4 files — the key does not include the version"; fi
case "$OUT5" in
  *"ShellCheck 0.12.0"*) ok ;;
  *) bad "C: the run did not report the version it actually used: $OUT5" ;;
esac
if [ "$RC5" = 1 ]; then ok; else bad "C: rc under the new version must be 1, got $RC5"; fi

# IDENTICAL CONTENT AT A DIFFERENT PATH is a different verdict, because the
# finding names the file. Replaying a.sh's record for e.sh would print the
# wrong filename in CI and send a reader to a clean file.
cp "$T/corpus/c.sh" "$T/corpus/e.sh"
( PATH="$T/fakebin:$PATH" SHELLCHECK_BIN="$T/fakebin/shellcheck" FAKE_COUNT="$COUNT" FAKE_VERSION=0.12.0 \
  "$SCRIPT" --cache-dir "$CACHE" --jobs 2 "$T/corpus"/*.sh >"$T/run.out" 2>&1 )
OUT6=$(cat "$T/run.out")
E=$(printf '%s\n' "$OUT6" | grep -c 'e\.sh:1:1: error' || true)
C=$(printf '%s\n' "$OUT6" | grep -c 'c\.sh:1:1: error' || true)
if [ "$E" = 1 ] && [ "$C" = 1 ]; then ok
else bad "C: identical content at two paths must produce one finding EACH, named for its own file (c=$C e=$E):
$OUT6"; fi
rm -f "$T/corpus/e.sh"

# ── D. the tool failing to run is not a verdict ────────────────────────────
# rc >= 2 must be loud and must not be cached, or one broken run pins a fake
# clean until someone edits the file.
printf '# FAKE_TOOL_FAILURE\n' > "$T/corpus/d.sh"
RC7=$(run); OUT7=$(cat "$T/run.out")
if [ "$RC7" = 2 ]; then ok; else bad "D: ShellCheck exiting >= 2 must fail the step with rc 2, got $RC7: $OUT7"; fi
case "$OUT7" in
  *"FAILED TO RUN"*) ok ;;
  *) bad "D: a tool failure must say so rather than look like a finding: $OUT7" ;;
esac
N7=$(calls)
RC8=$(run); N8=$(calls)
if [ "$((N8-N7))" -ge 1 ]; then ok
else bad "D: the failed file was CACHED — a broken run would pin its verdict forever"; fi
if [ "$RC8" = 2 ]; then ok; else bad "D: the repeat run of a failing tool must still be rc 2, got $RC8"; fi
printf 'echo four\n' > "$T/corpus/d.sh"

# ── E. it never reaches apt, sudo or the network ───────────────────────────
if [ ! -f "$TRIPWIRE" ]; then ok
else bad "E: the script called a package manager, sudo or curl:
$(cat "$TRIPWIRE")"; fi
# …in EXECUTABLE text. Comments are exempt on purpose, the same way the pool
# labels are exempt in tests/harness-ci-runners.bh-1206-test.sh: the header has
# to be able to say that apt was removed and why, and a rule that cannot tell a
# call from an explanation of its absence is a rule people delete.
STRAY=$(grep -vn '^[[:space:]]*#' "$SCRIPT" | grep 'apt-get' || true)
if [ -z "$STRAY" ]; then ok
else bad "E: bin/ci-shellcheck.sh CALLS apt-get — the pinned download replaced it:
$STRAY"; fi

# The cache defaults INSIDE $RUNNER_TEMP. docs/CI-RUNNERS.md: a job may write
# under $RUNNER_TEMP or the checkout and nowhere else — twelve runners share a
# 7.8 GB rootfs and a few hundred stray megabytes is a machine-wide outage.
( PATH="$T/fakebin:$PATH" RUNNER_TEMP="$T/rt" SHELLCHECK_BIN="$T/fakebin/shellcheck" FAKE_COUNT="$COUNT" \
  "$SCRIPT" --jobs 1 "$T/corpus/a.sh" >"$T/run.out" 2>&1 )
case "$(cat "$T/run.out")" in
  *"cache $T/rt/"*) ok ;;
  *) bad "E: with RUNNER_TEMP set the cache must live under it: $(cat "$T/run.out")" ;;
esac

# Misuse is rc 2, never 0: a lint that silently passes when it was handed
# nothing is the most expensive green in the file.
( PATH="$T/fakebin:$PATH" SHELLCHECK_BIN="$T/fakebin/shellcheck" FAKE_COUNT="$COUNT" \
  "$SCRIPT" --cache-dir "$CACHE" >"$T/run.out" 2>&1 )
if [ "$?" = 2 ]; then ok; else bad "E: naming no files must be rc 2 (usage), not a pass"; fi

# ── F. the assumption, checked against the REAL binary ─────────────────────
# Per-file caching is only sound at `--severity=error` because no error-level
# ShellCheck check depends on definitions imported from a sourced file. That is
# an assumption about somebody else's program, so it is measured rather than
# believed: one invocation over the corpus must produce exactly what the
# per-file invocations produce, concatenated in order.
if command -v shellcheck >/dev/null 2>&1; then
  REAL=$(command -v shellcheck)
  mkdir -p "$T/real"
  printf 'x=1\necho $x\n'                    > "$T/real/r1.sh"
  printf 'cd /tmp\nrm -rf "$UNSET_VAR"/x\n'  > "$T/real/r2.sh"
  printf 'echo "fine"\n'                     > "$T/real/r3.sh"
  printf 'case x in\nesac\n'                 > "$T/real/r4.sh"
  # The exact flags the script uses, read off the script so the two cannot drift.
  FLAGS=$(sed -n 's/^SC_FLAGS="\(.*\)"$/\1/p' "$SCRIPT" | head -1)
  if [ -n "$FLAGS" ]; then ok; else bad "F: cannot read SC_FLAGS out of $SCRIPT"; fi
  # shellcheck disable=SC2086
  ONE=$("$REAL" $FLAGS "$T/real"/r*.sh 2>&1)
  MANY=""
  for F in "$T/real"/r*.sh; do
    # shellcheck disable=SC2086
    MANY="$MANY$("$REAL" $FLAGS "$F" 2>&1)
"
  done
  MANY=$(printf '%s' "$MANY" | grep . || true)
  ONE=$(printf '%s' "$ONE" | grep . || true)
  if [ "$ONE" = "$MANY" ]; then ok
  else bad "F: ShellCheck $("$REAL" --version | sed -n 's/^version: //p') does NOT decompose per file — per-file caching is UNSOUND with these flags:
  one invocation:
$ONE
  file by file:
$MANY"; fi

  # …and the script itself, against the real binary, reports exactly those
  # findings — cold, then from cache.
  RRC1=$( ( SHELLCHECK_BIN="$REAL" "$SCRIPT" --cache-dir "$T/realcache" --jobs 2 "$T/real"/r*.sh >"$T/r1.out" 2>&1 ); echo $? )
  RRC2=$( ( SHELLCHECK_BIN="$REAL" "$SCRIPT" --cache-dir "$T/realcache" --jobs 2 "$T/real"/r*.sh >"$T/r2.out" 2>&1 ); echo $? )
  G1=$(grep 'SC[0-9]' "$T/r1.out" || true)
  G2=$(grep 'SC[0-9]' "$T/r2.out" || true)
  if [ "$G1" = "$ONE" ]; then ok
  else bad "F: the cold run's findings differ from a plain ShellCheck invocation:
  script: $G1
  plain : $ONE"; fi
  if [ "$G1" = "$G2" ] && [ "$RRC1" = "$RRC2" ]; then ok
  else bad "F: with the REAL binary a cache hit differed from the cold run (rc $RRC1 vs $RRC2):
  cold: $G1
  warm: $G2"; fi
  if grep -q '4 files, 4 from cache, 0 linted' "$T/r2.out"; then ok
  else bad "F: the real-binary second run was not a full cache hit: $(tail -1 "$T/r2.out")"; fi
else
  echo "NOTE: shellcheck is not on PATH — block F (the real-binary equivalence proof) did not run"
  bad "F: no shellcheck on PATH, so the assumption per-file caching rests on was not checked"
fi

echo "ci-shellcheck-cache.bh-1200-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
