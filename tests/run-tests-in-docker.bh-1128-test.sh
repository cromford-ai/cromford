#!/bin/bash
# tests/run-tests-in-docker.bh-1128-test.sh — the container image the shell
# suite runs in carries rsync, and the tag moves when the package list does.
#
# WHY (BH-1128, item 4). tests/harness-sync-branch-guard.bh-1099-test.sh,
# tests/harness-sync-stamps-test.sh and tests/harness-sync-catalog-reset.bh-1042-test.sh
# all open with `command -v rsync || { echo "... missing — skipping"; exit 0; }`,
# because the script they drive deploys with rsync. The image built by
# bin/run-tests-in-docker.sh installed no rsync, so on a Mac those three suites
# printed one skip line and exited 0 — a green run that had tested nothing about
# harness-sync. The tag matters as much as the package: the image is built once
# and kept (`docker image inspect` short-circuits the build), so an added
# package never reaches a machine that already holds the old tag.
#
# This suite reads the runner's own text because the runner has no other
# observable without a docker daemon; both checks fail loudly when the thing
# they read is missing, rather than passing on an empty extraction.
#
# Run from anywhere: tests/run-tests-in-docker.bh-1128-test.sh (exit 0 = pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$DIR/bin/run-tests-in-docker.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$RUNNER" ] || { echo "FAIL: $RUNNER is missing"; exit 1; }

# ── 1. the inline Dockerfile installs rsync ─────────────────────────────────
# Extract the heredoc body, not the whole file: a header sentence naming rsync
# must not satisfy this.
DF=$(sed -n "/<<'DOCKERFILE'/,/^DOCKERFILE$/p" "$RUNNER" | sed '1d;$d')
[ -n "$DF" ] && ok \
  || bad "1: could not extract the DOCKERFILE heredoc from $RUNNER (the check below would be vacuous)"
grep -q 'apt-get install' <<<"$DF" && ok \
  || bad "1: the extracted Dockerfile has no apt-get install line: $DF"
printf '%s\n' "$DF" | sed -n '/apt-get install/,/rm -rf/p' | grep -qw 'rsync' && ok \
  || bad "1: the image installs no rsync, so every harness-sync suite skips inside it: $DF"

# ── 2. the default image tag moved off the pre-rsync one ────────────────────
TAG_LINE=$(grep -n '^IMAGE=' "$RUNNER")
[ -n "$TAG_LINE" ] && ok || bad "2: no default IMAGE= line in $RUNNER"
grep -q 'cromford-tests:' <<<"$TAG_LINE" && ok \
  || bad "2: the default IMAGE does not name a cromford-tests tag: $TAG_LINE"
grep -q 'cromford-tests:trixie}' <<<"$(printf '%s\n' "$TAG_LINE")" && \
  bad "2: the default IMAGE is still cromford-tests:trixie — a machine that already built that tag reuses an image with no rsync: $TAG_LINE" \
  || ok
# trixie.2 is the apt-node-20 image: a machine holding it would keep running
# the worker/jobs node tests against a node with no node:sqlite.
grep -q 'cromford-tests:trixie\.2}' <<<"$(printf '%s\n' "$TAG_LINE")" && \
  bad "2: the default IMAGE is still cromford-tests:trixie.2 — a machine that already built that tag reuses an image whose node is Debian's node 20: $TAG_LINE" \
  || ok

echo "run-tests-in-docker.bh-1128-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
