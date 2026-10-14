#!/bin/bash
# tests/share-gitleaks-required.bh-2059-test.sh — BH-2059: CI RUNS THE GITLEAKS
# GATE OVER THE MIRROR, AND A RUNNER WITHOUT GITLEAKS IS RED, NEVER A SKIP.
#
# tests/share-publish-clean.bh-795-test.sh runs the publisher's gates over the
# mirror the committed tree would build. Its gitleaks arm SKIPPED when the binary
# was absent, and no CI step installed it, so every PR skipped it. #2032's
# fixture tokens read green in CI, and the share mirror had already frozen on the
# same class of failure three times (09-13, 09-15, 09-24).
#
#   A1 the shard job installs gitleaks behind a `ci-tool-present.sh gitleaks <V>`
#      guard and ends that step with the same call unguarded
#   A2 that V equals publish-cromford.yml's V (the rule sets differ between releases)
#   A3 the step pins a 64-hex sha256 and runs `sha256sum -c` before tar/install,
#      and that sha256 is in both KNOWN_PUBLIC_CHECKSUMS lists (the mirror guards)
#   A4 the install step comes before the step that runs the corpus
#   A5 the corpus step exports GITLEAKS_REQUIRED=1
#   A6 share-publish-clean with GITLEAKS_REQUIRED=1 and no gitleaks: rc 1 and a
#      FAIL line, before any sanitize work. With gitleaks present the guard is quiet.
#   A7 the same suite without GITLEAKS_REQUIRED gets past the guard (laptop path)
#   A8 the real gate refuses an unmarked `token=` literal (rc 1, names the file)
#      and passes the same shape with a fixture marker in the value
#
# A6/A7 drive the real suite with a python3 shim that fails, so the suite stops at
# its sanitize step: "reached sanitize" is the proof it got past the guard, and
# the full ~30-224 s mirror build is never paid here. share-publish-clean itself
# runs in full in CI anyway. No clock, no randomness, no network.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="$DIR/.github/workflows/harness-ci.yml"
PUB="$DIR/.github/workflows/publish-cromford.yml"
SUITE="$DIR/tests/share-publish-clean.bh-795-test.sh"
BASH_BIN=$(command -v bash)
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── A1-A5. the workflow ─────────────────────────────────────────────────────
# job_steps <job> -> "<step#>\t<line>" for the job's non-comment lines, with
# backslash continuations joined (same reader as tests/ci-pyyaml.bh-1741-test.sh).
# A job that is not there prints nothing, so an install in another job cannot
# satisfy these checks.
job_steps() {
  awk -v job="  $1:" '
    $0 == job { inj = 1; next }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    !inj { next }
    /^[[:space:]]*#/ { next }
    /^      - / { n++ }
    { line = $0; sub(/^[[:space:]]+/, "", line)
      if (held != "") { line = held " " line; held = "" }
      if (line ~ /\\$/) { sub(/[[:space:]]*\\$/, "", line); held = line; next }
      if (n) print n "\t" line }' "$WF"
}
S=$(job_steps tests-shard)
if [ -z "$S" ]; then
  bad "A1: job 'tests-shard' not found in $WF"
else
  STEP=$(printf '%s\n' "$S" | awk -F'\t' '$2 ~ /^if ! bin\/ci-tool-present\.sh gitleaks / { print $1; exit }')
  if [ -z "$STEP" ]; then
    bad "A1: the shard job has no step guarded by 'if ! bin/ci-tool-present.sh gitleaks'"
  else
    ok
    BODY=$(printf '%s\n' "$S" | awk -F'\t' -v s="$STEP" '$1 == s { print $2 }')
    grep -qx 'set -euo pipefail' <<<"$BODY" \
      && ok || bad "A1: the gitleaks step must run under set -euo pipefail"
    G_IF=$(printf '%s\n' "$BODY" | sed -n 's/^if ! bin\/ci-tool-present\.sh gitleaks \([0-9][0-9.]*\); then$/\1/p' | head -1)
    G_END=$(printf '%s\n' "$BODY" | tail -1 | sed -n 's/^bin\/ci-tool-present\.sh gitleaks \([0-9][0-9.]*\)$/\1/p')
    [ -n "$G_IF" ] && ok || bad "A1: the install must be guarded by 'if ! bin/ci-tool-present.sh gitleaks <version>; then' (step: $(printf '%s' "$BODY" | tr '\n' '|'))"
    [ -n "$G_END" ] && ok || bad "A1: the step must END with an unguarded 'bin/ci-tool-present.sh gitleaks <version>' (step: $(printf '%s' "$BODY" | tr '\n' '|'))"

    # A2. the pin pair. An empty extraction on either side is a FAIL, never a match.
    V_CI=$(printf '%s\n' "$BODY" | sed -n 's/^V=\([0-9][0-9.]*\).*/\1/p' | head -1)
    V_PUB=$(grep -v '^[[:space:]]*#' "$PUB" | sed -n 's/^[[:space:]]*V=\([0-9][0-9.]*\).*/\1/p' | head -1)
    if [ -z "$V_CI" ] || [ -z "$V_PUB" ]; then
      bad "A2: could not read both gitleaks pins (harness-ci.yml V='$V_CI', publish-cromford.yml V='$V_PUB')"
    elif [ "$V_CI" = "$V_PUB" ] && [ "$G_IF" = "$V_CI" ] && [ "$G_END" = "$V_CI" ]; then ok
    elif [ "$V_CI" = "$V_PUB" ]; then
      bad "A2: the guard checks '$G_IF' and the assert '$G_END', but the step downloads $V_CI — the guard can never be true"
    else bad "A2: CI installs gitleaks $V_CI but publish-cromford.yml publishes with $V_PUB — the two rule sets flag different fixtures"
    fi

    # A3. the checksum: a 64-hex literal, checked before anything is unpacked.
    grep -qE '^SHA=[0-9a-f]{64}$' <<<"$BODY" \
      && ok || bad "A3: the gitleaks step must pin a 64-hex sha256 literal (SHA=...)"
    LN_SUM=$(printf '%s\n' "$BODY" | grep -n 'sha256sum -c' | head -1 | cut -d: -f1)
    LN_TAR=$(printf '%s\n' "$BODY" | grep -n '^tar ' | head -1 | cut -d: -f1)
    LN_INS=$(grep -n 'install -m' <<<"$BODY" | head -1 | cut -d: -f1)
    if [ -z "$LN_SUM" ]; then bad "A3: the gitleaks step never runs sha256sum -c on the download"
    elif [ -z "$LN_TAR" ] || [ -z "$LN_INS" ]; then bad "A3: the gitleaks step has no tar/install line to order the checksum against"
    elif [ "$LN_SUM" -lt "$LN_TAR" ] && [ "$LN_SUM" -lt "$LN_INS" ]; then ok
    else bad "A3: sha256sum -c (line $LN_SUM) must run before tar ($LN_TAR) and install ($LN_INS)"
    fi
    printf '%s\n' "$BODY" | grep 'sha256sum -c' | grep -q '\$SHA' \
      && ok || bad "A3: sha256sum -c must check against the pinned \$SHA"

    # A3b. the pinned checksum is a 64-hex literal, which the mirror's leakcheck
    # refuses as a secret unless it is allowlisted by exact literal in BOTH the
    # publisher's list and the guard the mirror ships (the BH-1200 rule). Without
    # this the fix for a frozen mirror would freeze the mirror.
    SHA_CI=$(printf '%s\n' "$BODY" | sed -n 's/^SHA=\([0-9a-f]\{64\}\)$/\1/p' | head -1)
    for F in "$DIR/bin/share/mapping.py" "$DIR/bin/share/overlay/tests/no-client-identifiers-test.sh"; do
      if [ -z "$SHA_CI" ]; then bad "A3b: no SHA= literal to look for in $(basename "$F")"
      elif grep -q "[\"']${SHA_CI}[\"']," "$F"; then ok
      else bad "A3b: $(basename "$F") does not list the gitleaks checksum in KNOWN_PUBLIC_CHECKSUMS — the share publish will refuse harness-ci.yml as a leak"
      fi
    done

    # A4. before the corpus.
    LATER=$(printf '%s\n' "$S" | awk -F'\t' 'index($2, "bin/test-trace-safety.sh --gate") { print $1; exit }')
    if [ -z "$LATER" ]; then bad "A4: the shard job has no 'bin/test-trace-safety.sh --gate' step"
    elif [ "$STEP" -lt "$LATER" ]; then ok
    else bad "A4: gitleaks is installed at step $STEP, after the corpus step $LATER"
    fi
  fi
  # A5. the corpus step requires it.
  CORPUS=$(printf '%s\n' "$S" | awk -F'\t' 'index($2, "bin/test-trace-safety.sh --gate") { print $1; exit }')
  if [ -n "$CORPUS" ] && printf '%s\n' "$S" | awk -F'\t' -v s="$CORPUS" '$1 == s { print $2 }' \
       | grep -qx 'export GITLEAKS_REQUIRED=1'; then ok
  else bad "A5: the corpus step must 'export GITLEAKS_REQUIRED=1' so a missing gitleaks is red, not a skip"
  fi
fi

# ── A6-A7. the real share-publish-clean suite ───────────────────────────────
# no_gitleaks_path: PATH with every directory that holds gitleaks replaced by a
# shadow of itself that has everything else. Dropping /usr/local/bin whole would
# drop tools the suite needs on a runner that keeps gitleaks there.
no_gitleaks_path() {
  local out="" d i=0 f
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    i=$((i+1))
    if [ -e "$d/gitleaks" ]; then
      mkdir -p "$T/shadow/$i"
      for f in "$d"/*; do
        [ "${f##*/}" = gitleaks ] || ln -sf "$f" "$T/shadow/$i/" 2>/dev/null
      done
      d="$T/shadow/$i"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}
NOGL=$(no_gitleaks_path)
# python3 that fails: the suite stops at sanitize, which is proof it got past
# the guard, without paying for a mirror build.
mkdir -p "$T/stop" "$T/fakegl"
printf '#!%s\necho "python3 shim: stop here" >&2\nexit 97\n' "$BASH_BIN" > "$T/stop/python3"
printf '#!%s\necho "gitleaks version 8.30.1"\n' "$BASH_BIN" > "$T/fakegl/gitleaks"
chmod +x "$T/stop/python3" "$T/fakegl/gitleaks"

if PATH="$NOGL" command -v gitleaks >/dev/null 2>&1; then
  bad "A6: could not build a PATH without gitleaks — the absent case was not tested"
else
  env GITLEAKS_REQUIRED=1 PATH="$T/stop:$NOGL" "$BASH_BIN" "$SUITE" > "$T/a6.out" 2>&1; RC=$?
  [ "$RC" = 1 ] && ok || bad "A6: GITLEAKS_REQUIRED=1 with no gitleaks must exit 1 (got $RC: $(head -5 "$T/a6.out"))"
  grep -q '^FAIL: gitleaks-gate: GITLEAKS_REQUIRED is set' "$T/a6.out" \
    && ok || bad "A6: the suite must print 'FAIL: gitleaks-gate: GITLEAKS_REQUIRED is set …' (got: $(head -5 "$T/a6.out"))"
  grep -q 'SKIP gitleaks-gate' "$T/a6.out" && bad "A6: a required gitleaks must never be a SKIP" || ok
  grep -q 'sanitize.py exited' "$T/a6.out" && bad "A6: the guard must fire before any sanitize work" || ok

  # The guard is keyed on the binary too: required AND present is quiet.
  env GITLEAKS_REQUIRED=1 PATH="$T/stop:$T/fakegl:$NOGL" "$BASH_BIN" "$SUITE" > "$T/a6b.out" 2>&1
  if grep -q 'GITLEAKS_REQUIRED is set' "$T/a6b.out"; then
    bad "A6: gitleaks on PATH must satisfy the guard (got: $(head -5 "$T/a6b.out"))"
  elif grep -q 'sanitize.py exited' "$T/a6b.out"; then ok
  else bad "A6: with gitleaks present the suite must reach sanitize (got: $(head -5 "$T/a6b.out"))"
  fi

  # A7. a laptop: not required, no gitleaks. The guard stays quiet.
  env -u GITLEAKS_REQUIRED PATH="$T/stop:$NOGL" "$BASH_BIN" "$SUITE" > "$T/a7.out" 2>&1
  if grep -q 'GITLEAKS_REQUIRED is set' "$T/a7.out"; then
    bad "A7: without GITLEAKS_REQUIRED the guard must not fire (got: $(head -5 "$T/a7.out"))"
  elif grep -q 'sanitize.py exited' "$T/a7.out"; then ok
  else bad "A7: without GITLEAKS_REQUIRED the suite must reach sanitize (got: $(head -5 "$T/a7.out"))"
  fi
  env GITLEAKS_REQUIRED= PATH="$T/stop:$NOGL" "$BASH_BIN" "$SUITE" > "$T/a7b.out" 2>&1
  grep -q 'GITLEAKS_REQUIRED is set' "$T/a7b.out" \
    && bad "A7: an EMPTY GITLEAKS_REQUIRED is not a requirement (got: $(head -5 "$T/a7b.out"))" || ok
fi

# ── A8. the gate itself refuses an unmarked token ───────────────────────────
# The values are assembled at run time: a whole credential-shaped literal in
# this file would itself trip the mirror's gitleaks gate, which is this ticket.
if command -v gitleaks >/dev/null 2>&1; then
  mkdir -p "$T/m/tests" "$T/c/tests"
  printf 'token=%s%s\n' "q8Zr4LmN2vXw" "7TpK9sYb3HcJ" > "$T/m/tests/x-test.sh"
  python3 "$DIR/bin/share/gitleaks-gate.py" "$T/m" > "$T/a8.out" 2>&1; RC=$?
  [ "$RC" = 1 ] && ok || bad "A8: an unmarked token= literal must be refused, rc 1 (got $RC: $(cat "$T/a8.out"))"
  grep -q 'tests/x-test.sh' "$T/a8.out" && ok || bad "A8: the refusal must name tests/x-test.sh (got: $(cat "$T/a8.out"))"
  # Negative control: the same shape with a fixture marker inside the value.
  printf 'token=%s%s%s\n' "q8Zr4LmN2vXw" "fixture" "7TpK9sYb3HcJ" > "$T/c/tests/x-test.sh"
  python3 "$DIR/bin/share/gitleaks-gate.py" "$T/c" > "$T/a8c.out" 2>&1; RC=$?
  [ "$RC" = 0 ] && ok || bad "A8: a token= value carrying a fixture marker must pass, rc 0 (got $RC: $(cat "$T/a8c.out"))"
elif [ -n "${GITLEAKS_REQUIRED:-}" ]; then
  bad "A8: GITLEAKS_REQUIRED is set but gitleaks is not on PATH"
else
  SKIP=$((SKIP+1))
  echo "SKIP A8: gitleaks not on PATH (CI installs 8.30.1 and sets GITLEAKS_REQUIRED)"
fi

echo "share-gitleaks-required.bh-2059-test: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
