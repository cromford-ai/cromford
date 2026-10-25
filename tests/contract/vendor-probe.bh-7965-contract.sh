#!/bin/bash
# contract-test
# tests/contract/vendor-probe.bh-7965-contract.sh — BH-7965 (BH-7937.2): the
# real-vendor contract suite for bin/lib/vendor/<v>.sh probe. NOT on the PR
# path (the PR loop is tests/*.sh tests/mc/*.sh): the nightly workflow runs it
# on main's head with the secrets VENDOR_CONTRACT_<V>_KEY. One worker: every
# case runs one after the other.
#
# Five cases per vendor (claude, codex, openrouter, fireworks, xai):
#   1 the good key proves (0)        2 tok-fixture-bad is refused (1)
#   3 empty stdin is refused (1)     4 an unknown verb exits 99
#   5 a key on argv is ignored: the probe reads stdin only, so it is refused (1)
#
# No key, or no CLI for claude/codex: SKIP with the reason, no alert (not
# configured is not a vendor failure). Exit 75 (5xx, 429, network, timeout):
# SKIP with the reason plus ONE alert for that vendor, and its remaining cases
# skip: a vendor outage is a vendor failure, never a code failure. Any other
# wrong answer is a FAIL. With no keys set: 25 SKIP lines, rc 0.
#
# Run: bash tests/contract/vendor-probe.bh-7965-contract.sh
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
unset HARNESS_VENDOR_FAKE HARNESS_VENDOR_FAKE_DIR
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP $1"; }
# One alert per vendor outage. On a GitHub runner a ::warning:: line; on a
# box, a fleet_alert beat through bin/beat.sh.
alert() {
  if [ "${GITHUB_ACTIONS:-}" != true ] && [ -x "$REPO/bin/beat.sh" ]; then
    "$REPO/bin/beat.sh" "$(jq -nc --arg l "$1" '{kind:"fleet_alert",akey:"vendor-contract",line:$l}')" >/dev/null 2>&1 \
      || echo "::warning::$1"
  else
    echo "::warning::$1"
  fi
}
CASES="good bad empty verb argv"
for v in claude codex openrouter fireworks xai; do
  VU=$(printf '%s' "$v" | tr '[:lower:]' '[:upper:]')
  kv="VENDOR_CONTRACT_${VU}_KEY"
  key="${!kv:-}"
  why=""
  [ -n "$key" ] || why="$kv is not set"
  if [ -z "$why" ]; then
    case "$v" in claude|codex) command -v "$v" >/dev/null 2>&1 || why="the $v CLI is not installed" ;; esac
  fi
  if [ -n "$why" ]; then
    for c in $CASES; do skip "$v $c: $why"; done
    continue
  fi
  down=""
  for c in $CASES; do
    if [ -n "$down" ]; then skip "$v $c: $down"; continue; fi
    case "$c" in
      good)  printf '%s' "$key" | "$REPO/bin/lib/vendor/$v.sh" probe >/dev/null 2>&1; rc=$?; want=0 ;;
      bad)   printf '%s' tok-fixture-bad | "$REPO/bin/lib/vendor/$v.sh" probe >/dev/null 2>&1; rc=$?; want=1 ;;
      empty) "$REPO/bin/lib/vendor/$v.sh" probe </dev/null >/dev/null 2>&1; rc=$?; want=1 ;;
      verb)  printf '%s' "$key" | "$REPO/bin/lib/vendor/$v.sh" frob >/dev/null 2>&1; rc=$?; want=99 ;;
      argv)  "$REPO/bin/lib/vendor/$v.sh" probe "$key" </dev/null >/dev/null 2>&1; rc=$?; want=1 ;;
    esac
    if [ "$rc" = 75 ] && [ "$want" != 75 ]; then
      down="the $v vendor did not answer (rc 75) on case $c"
      skip "$v $c: $down"
      alert "vendor contract: $down. A vendor failure, not a code failure."
      continue
    fi
    [ "$rc" = "$want" ] && ok "$v $c: rc $rc" || bad "$v $c: want $want, got $rc"
  done
done
echo "vendor-probe.bh-7965-contract: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
