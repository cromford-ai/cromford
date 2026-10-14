#!/bin/bash
# tests/run-tests-in-docker-image.bh-5583-test.sh — the local test image runs
# GNU awk as `awk`, as CI does, and the tag moves with the package list.
#
# WHY (BH-5583). CI's shards run gawk. The image bin/run-tests-in-docker.sh
# builds is debian trixie, whose default `awk` is mawk, and the two parse an
# `awk -v` value differently: gawk turns `\(` into `(`, mawk keeps the
# backslash. tests/prompt-conflict-discipline.bh-5269-test.sh passed in the image
# and failed seven cases in merge batch #5686. The tag matters as much as the
# package: the image is built once and kept (`docker image inspect`
# short-circuits the build), so an added package never reaches a machine that
# already holds the old tag.
#
# Static: it reads the runner's own text, because the runner has no other
# observable without a docker daemon. Every extraction is checked non-empty
# first, so a moved heredoc fails here instead of passing on nothing.
#
# Run from anywhere: tests/run-tests-in-docker-image.bh-5583-test.sh (exit 0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$DIR/bin/run-tests-in-docker.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$RUNNER" ] || { echo "FAIL: $RUNNER is missing"; exit 1; }

# The heredoc body, not the whole file: a header sentence must not satisfy a
# check on what the image installs. APT is the install RUN up to its rm -rf.
DF=$(sed -n "/<<'DOCKERFILE'/,/^DOCKERFILE$/p" "$RUNNER" | sed '1d;$d')
APT=$(printf '%s\n' "$DF" | sed -n '/apt-get install/,/rm -rf/p')
# Non-comment lines of APT only: a `# update-alternatives ...` would not run.
APT_CODE=$(printf '%s\n' "$APT" | grep -v '^[[:space:]]*#')
# The package list alone: apt-get install up to the first `&&` line after it.
# `/usr/bin/gawk` on the update-alternatives line must not count as an install.
PKGS=$(printf '%s\n' "$APT_CODE" | sed -n '/apt-get install/,/^[[:space:]]*&&/p' | sed '$d')

# ── G0. guard: the extractions are not empty ────────────────────────────────
[ -n "$DF" ] && ok \
  || bad "G0: could not extract the DOCKERFILE heredoc from $RUNNER (every check below would be vacuous)"
[ -n "$APT" ] && printf '%s\n' "$APT" | tail -n1 | grep -q 'rm -rf' && ok \
  || bad "G0: could not extract the apt-get install RUN (apt-get install .. rm -rf) from the heredoc: $DF"
grep -qw 'rsync' <<<"$PKGS" && ok \
  || bad "G0: could not extract the package list from the install RUN: $APT"

# ── G1. the image installs gawk ─────────────────────────────────────────────
grep -qw 'gawk' <<<"$PKGS" && ok \
  || bad "G1: the image installs no gawk, so awk is trixie's mawk and parses awk -v unlike CI: $APT"

# ── G2. gawk IS awk, and the build fails closed if it is not ────────────────
grep -q 'update-alternatives --set awk /usr/bin/gawk' <<<"$APT_CODE" && ok \
  || bad "G2: the install RUN does not set the awk alternative to /usr/bin/gawk before rm -rf: $APT"
printf '%s\n' "$APT_CODE" | grep 'awk --version' | grep -q 'GNU Awk' && ok \
  || bad "G2: the install RUN does not check that awk --version says GNU Awk, so a mawk image could ship under the new tag: $APT"

# ── G3. the default tag moved to trixie.5 ───────────────────────────────────
TAG_LINE=$(grep '^IMAGE=' "$RUNNER")
[ -n "$TAG_LINE" ] && ok || bad "G3: no default IMAGE= line in $RUNNER"
grep -q ':trixie\.5}"$' <<<"$TAG_LINE" && ok \
  || bad "G3: the default IMAGE tag is not trixie.5, so a machine holding trixie.4 reuses its mawk image: $TAG_LINE"
grep -q ':trixie\.[234]}' <<<"$TAG_LINE" \
  && bad "G3: the default IMAGE still names an older tag (trixie.2/.3/.4): $TAG_LINE" || ok

# ── G4. the header names trixie.4 as the older mawk tag ─────────────────────
T4=$(grep -n 'trixie\.4' "$RUNNER")
[ -n "$T4" ] && ok || bad "G4: the header no longer names trixie.4 among the older tags"
T4_CODE=$(printf '%s\n' "$T4" | grep -v '^[0-9]*:#')
[ -z "$T4_CODE" ] && ok || bad "G4: a non-comment line names trixie.4: $T4_CODE"
grep -q 'mawk' <<<"$T4" && ok \
  || bad "G4: no header line names trixie.4 as the mawk-as-awk tag: $T4"

# ── G5. python3-yaml is still installed (BH-5583 body, I1) ──────────────────
grep -qw 'python3-yaml' <<<"$PKGS" && ok \
  || bad "G5: the image no longer installs python3-yaml: $APT"

# ── G6. the package comment block says why gawk is there ────────────────────
PKG=$(grep '^#   ' "$RUNNER")
[ -n "$PKG" ] && ok || bad "G6: could not read the package comment block (lines starting '#   ')"
printf '%s\n' "$PKG" | grep -E '^#   gawk ' | grep -Eq 'awk -v|mawk' && ok \
  || bad "G6: the package comment block has no gawk entry naming awk -v or mawk"

# ── G7. no file under bin/ or docs/ names an older tag as current (I3) ──────
HITS=$(grep -rnE 'trixie\.[234]\b' "$DIR/bin" "$DIR/docs" 2>/dev/null)
STRAY=$(printf '%s\n' "$HITS" | grep -v '^$' \
  | grep -v "^$DIR/docs/notes/" \
  | grep -v "^$RUNNER:[0-9]*:#")
[ -z "$STRAY" ] && ok \
  || bad "G7: an older trixie tag is named outside the runner's header comments and docs/notes: $STRAY"
grep -q 'IMAGE=' <<<"$HITS" \
  && bad "G7: an IMAGE= line names an older trixie tag: $HITS" || ok

echo "run-tests-in-docker-image.bh-5583-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
