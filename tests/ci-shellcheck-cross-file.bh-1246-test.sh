#!/bin/bash
# tests/ci-shellcheck-cross-file.bh-1246-test.sh — BH-1246: per-file ShellCheck
# caching must not silently drop cross-file findings if the severity is ever
# bumped.
#
# WHAT THIS GUARDS. The BH-1200 cache keys findings per file. That is SOUND at
# `--severity=error` because no error-level ShellCheck check depends on
# definitions imported from a sourced file, but it is NOT sound in general:
# with `--severity=warning` a sourcer that expands an array defined in a lib
# gets SC2128 when both files are checked together, but that finding vanishes
# when only the sourcer is checked. A future severity bump would turn a silent
# drop into a real bug, so this suite keeps a canary pair that goes red the
# moment the cross-file behavior changes at the severity the cache uses.
#
# The fixture uses only known codes (SC2128, SC2154, SC2034) so an unrelated
# ShellCheck warning is not mistaken for the cross-file signal.
#
# No network, no secrets, no clock, no dice. Run from anywhere: exit 0 = pass.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The real ShellCheck the lint job uses. If it is absent, the cache design
# cannot be validated at all.
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "FAIL: shellcheck is not on PATH — cannot verify the cross-file assumption"
  exit 1
fi
REAL=$(command -v shellcheck)
mkdir -p "$T/fixture"

# A lib that defines an array, and a sourcer that expands it without an index.
cat > "$T/fixture/lib.sh" <<'LIBEOF'
#!/bin/bash
arr=(one two three)
LIBEOF
cat > "$T/fixture/sourcer.sh" <<'SRCEOF'
#!/bin/bash
# shellcheck source=lib.sh
source ./lib.sh
echo "$arr"
SRCEOF
chmod +x "$T/fixture/lib.sh" "$T/fixture/sourcer.sh"

# ShellCheck resolves source-directive paths relative to the working directory,
# so all invocations run from inside the fixture directory.
cd "$T/fixture" || exit 1

# Full/warning mode must see the cross-file SC2128 on the sourcer.
FULL_WARN=$("$REAL" --severity=warning --format=gcc sourcer.sh lib.sh 2>&1 || true)
if grep -q "^sourcer.sh:.*SC2128" <<<"$FULL_WARN"; then ok
else bad "full warning mode should report SC2128 on the sourcer, got:\n$FULL_WARN"; fi

# The lib gets SC2034 (array appears unused) in full mode; we record it so the
# test does not fire on an unrelated warning later.
if grep -q "^lib.sh:.*SC2034" <<<"$FULL_WARN"; then ok
else bad "full warning mode should report SC2034 on the lib, got:\n$FULL_WARN"; fi

# Per-file/warning mode on the sourcer drops SC2128 (it becomes SC2154 because
# the variable is referenced but not assigned). The exact drop is what we care
# about, not the replacement code.
ONE_WARN=$("$REAL" --severity=warning --format=gcc sourcer.sh 2>&1 || true)
if grep -q "^sourcer.sh:.*SC2128" <<<"$ONE_WARN"; then
  bad "per-file warning mode still reports SC2128 — the cross-file finding is no longer dropped:\n$ONE_WARN"
else ok; fi

# The per-file warning must not be empty or report an unrelated code.
if grep -qE "SC2154|SC2034" <<<"$ONE_WARN"; then ok
else bad "per-file warning mode produced unexpected output:\n$ONE_WARN"; fi

# Error severity (the flags bin/ci-shellcheck.sh actually uses) must show no
# cross-file error today: full mode and per-file mode are identical and clean.
FLAGS=$(sed -n 's/^SC_FLAGS="\(.*\)"$/\1/p' "$DIR/bin/ci-shellcheck.sh" | head -1)
if [ -n "$FLAGS" ]; then ok
else bad "cannot read SC_FLAGS out of bin/ci-shellcheck.sh"; fi

# shellcheck disable=SC2086
FULL_ERR=$("$REAL" $FLAGS sourcer.sh lib.sh 2>&1 || true)
# shellcheck disable=SC2086
ONE_ERR=$("$REAL" $FLAGS sourcer.sh 2>&1 || true)

if [ -z "$FULL_ERR" ] && [ -z "$ONE_ERR" ]; then ok
else bad "error severity produced unexpected findings — per-file caching may not be sound at this severity:\nfull:\n$FULL_ERR\nper-file:\n$ONE_ERR"; fi

echo "ci-shellcheck-cross-file.bh-1246-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
