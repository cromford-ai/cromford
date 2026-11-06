#!/bin/bash
# tests/workflow-download-artifact-pin.bh-9060-test.sh — BH-9060: every
# actions/download-artifact step names a fixed version at or above 4.1.3.
#
# THE DEFECT THIS PINS. GHSA-cxww-7g56-2vh6 is fixed in download-artifact
# 4.1.3. The moving `@v4` tag gives a scanner no fixed version to read, so
# Aikido reported both workflows as high. A ref is good when it is a full
# `vX.Y.Z` at or above 4.1.3 (numeric compare) or a 40-hex commit SHA.
#
#   P1  harness-ci.yml and harness-nightly.yml parse with yaml.safe_load
#   P2  the checker over .github/workflows/*.yml reports 0 bad refs
#   P3  the checker finds at least 9 download-artifact steps (zero is a fail)
#   P4  scratch fixtures: @v4, @v4.1, @v4.1.2 are bad; @v4.1.3, @v4.3.0,
#       @v4.10.0, @v4.1.10 and a 40-hex SHA are good (@v4.1.10 is lower
#       than 4.1.3 as a string, so it pins the numeric compare);
#       upload-artifact@v4 is ignored
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/workflow-download-artifact-pin.bh-9060-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
finish() { echo "workflow-download-artifact-pin.bh-9060: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

CI_WF="$DIR/.github/workflows/harness-ci.yml"
NIGHTLY_WF="$DIR/.github/workflows/harness-nightly.yml"
for f in "$CI_WF" "$NIGHTLY_WF"; do
  [ -f "$f" ] && ok || bad "setup: $f is missing"
done
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { bad "PyYAML missing on a CI runner"; finish; }
  echo "workflow-download-artifact-pin.bh-9060: PyYAML missing — skipped on this dev machine"; exit 0
fi

# check <workflow files...> — prints `<n> download-artifact steps, <m> bad`,
# then one `bad: <file> <job> <ref>` per bad step. rc 2 when a file does not parse.
cat > "$T/check.py" <<'PY'
import re, sys, yaml
SEMVER = re.compile(r'^v(\d+)\.(\d+)\.(\d+)$')
SHA = re.compile(r'^[0-9a-f]{40}$')
MIN = (4, 1, 3)
n = 0; bad = []
for path in sys.argv[1:]:
    try:
        doc = yaml.safe_load(open(path))
    except yaml.YAMLError as e:
        print(f"unparsed: {path}: {e}"); sys.exit(2)
    for job, j in ((doc or {}).get("jobs") or {}).items():
        for s in (j.get("steps") or []):
            uses = str(s.get("uses", ""))
            if not uses.startswith("actions/download-artifact@"):
                continue
            n += 1
            ref = uses.split("@", 1)[1].strip()
            m = SEMVER.match(ref)
            good = bool(SHA.match(ref)) or (m is not None and tuple(int(x) for x in m.groups()) >= MIN)
            if not good:
                bad.append(f"bad: {path} {job} {ref}")
print(f"{n} download-artifact steps, {len(bad)} bad")
for b in bad: print(b)
PY

# ── P1. both workflows parse
for f in "$CI_WF" "$NIGHTLY_WF"; do
  P1OUT=$(python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$f" 2>&1); P1RC=$?
  [ "$P1RC" -eq 0 ] && ok || bad "P1: $f does not parse as YAML [$P1OUT]"
done

# ── P2 + P3. the real tree
REAL=$(python3 "$T/check.py" "$DIR"/.github/workflows/*.yml 2>&1); REALRC=$?
head -n1 <<<"$REAL"
[ "$REALRC" -eq 0 ] && ok || bad "P2: the checker could not read the workflows [$REAL]"
RN=$(sed -nE '1s/^([0-9]+) download-artifact steps.*/\1/p' <<<"$REAL")
RM=$(sed -nE '1s/.*, ([0-9]+) bad$/\1/p' <<<"$REAL")
[ "$RM" = 0 ] && ok || bad "P2: every download-artifact ref must be vX.Y.Z >= 4.1.3 or a 40-hex SHA [$REAL]"
[ -n "$RN" ] && [ "$RN" -ge 9 ] && ok || bad "P3: expected at least 9 download-artifact steps, found '${RN}' [$REAL]"

# ── P4. mutation fixtures
mkdir -p "$T/p4"
cat > "$T/p4/fixture.yml" <<'YML'
name: fixture
on: push
jobs:
  bad-major:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
  bad-minor:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4.1
  bad-below:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4.1.2
  good-fix:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4.1.3
  good-new:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4.3.0
  good-numeric:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4.10.0
  good-patch:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4.1.10
  good-sha:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093
  near-miss:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
YML
FX=$(python3 "$T/check.py" "$T/p4/fixture.yml" 2>&1)
[ "$(head -n1 <<<"$FX")" = "8 download-artifact steps, 3 bad" ] && ok \
  || bad "P4: 8 download steps (upload-artifact ignored), 3 bad [$FX]"
for job in bad-major bad-minor bad-below; do
  grep -qE "^bad: .* $job " <<<"$FX" && ok || bad "P4: $job must be reported [$FX]"
done
for job in good-fix good-new good-numeric good-patch good-sha near-miss; do
  grep -qE "^bad: .* $job " <<<"$FX" && bad "P4: $job must not be reported [$FX]" || ok
done

finish
