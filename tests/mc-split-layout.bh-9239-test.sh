#!/bin/bash
# tests/mc-split-layout.bh-9239-test.sh — BH-9239: tests/mc-split-layout-test.sh
# must measure the repo's bin/lib/mc modules, not the live harness beside them.
#
# The defect: tests/lib/scratch.sh unsets HARNESS, so bin/lib/mc/log.sh sets
# MC_H=/root/harness, and bin/lib/mc/queue.sh (BH-1586) sources the LIVE
# gh-rest-list.sh and gh-policy-cache.sh when they are readable. On a box the
# fns.sh driver then counted 81 gh_* / _ghad_* functions as functions that
# mc/queue.sh defines, and check 3 went red. A GitHub runner has no
# /root/harness, so CI stayed green.
#
# Cases:
#   1. premise: a HARNESS that holds the gh-rest libs makes log+queue define
#      gh_rest_issue_comments (the leak path is real, on any host)
#   2. isolation: an empty HARNESS makes log+queue define neither
#      gh_rest_issue_comments nor gh_policy_read, and the source returns 0
#   3. wiring: every "$T/fns.sh" call in the layout suite (3 or more) carries
#      HARNESS="$NOH", and NOH is a dir under $T
#   4. production entry point: the layout suite itself exits 0 with "0 failed"
#
# No network, no gh, no git. Scratch dirs only.

# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
S="$T"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

MCD="$DIR/bin/lib/mc"
SUITE="$DIR/tests/mc-split-layout-test.sh"

# probe <harness-dir> — source log.sh then queue.sh with HARNESS=<dir>, print
# which of the two gh-rest names got defined, and the source rc.
probe() {
  HARNESS="$1" bash -c '
    . "$1/log.sh" || { echo "RC=log"; exit 0; }
    . "$1/queue.sh"; rc=$?
    declare -F gh_rest_issue_comments >/dev/null && echo "DEF=gh_rest_issue_comments"
    declare -F gh_policy_read >/dev/null && echo "DEF=gh_policy_read"
    echo "RC=$rc"
  ' _ "$MCD" 2>/dev/null
}

# ── 1. premise ──────────────────────────────────────────────────────────────
mkdir -p "$S/h"
for lib in bin/lib/gh-rest-list.sh bin/lib/gh-policy-cache.sh; do
  scratch_install_closure "$lib" "$S/h" >/dev/null || bad "1: could not install the closure of $lib"
done
OUT1=$(probe "$S/h")
case "$OUT1" in
  *DEF=gh_rest_issue_comments*) ok ;;
  *) bad "1: a HARNESS holding gh-rest-list.sh must make queue.sh define gh_rest_issue_comments (got: $(echo "$OUT1" | tr '\n' ' '))" ;;
esac

# ── 2. isolation ────────────────────────────────────────────────────────────
mkdir -p "$S/empty"
OUT2=$(probe "$S/empty")
case "$OUT2" in *DEF=*) bad "2: an empty HARNESS must define no gh-rest name (got: $(echo "$OUT2" | tr '\n' ' '))" ;; *) ok ;; esac
case "$OUT2" in *RC=0*) ok ;; *) bad "2: log.sh+queue.sh must source with rc 0 under an empty HARNESS (got: $(echo "$OUT2" | tr '\n' ' '))" ;; esac

# ── 3. wiring ───────────────────────────────────────────────────────────────
CALLS=$(grep -nE '"\$T/fns\.sh"' "$SUITE" | grep -vE '^[0-9]+:[[:space:]]*#|cat > "\$T/fns\.sh"')
NCALLS=$(printf '%s\n' "$CALLS" | grep -c .)
if [ "$NCALLS" -ge 3 ]; then ok; else bad "3: expected 3 or more \"\$T/fns.sh\" calls in the layout suite, found $NCALLS"; fi
UNPINNED=$(printf '%s\n' "$CALLS" | grep -v 'HARNESS="\$NOH" bash "\$T/fns\.sh"' | grep .)
if [ -z "$UNPINNED" ]; then ok; else bad "3: fns.sh call(s) without HARNESS=\"\$NOH\": $(echo "$UNPINNED" | tr '\n' ' ')"; fi
if grep -qE '^NOH="\$T/[^"]+"' "$SUITE"; then ok; else bad "3: NOH must be assigned under \$T in the layout suite"; fi

# ── 4. production entry point ───────────────────────────────────────────────
OUT4=$(HARNESS_TEST_SANDBOX=1 bash "$SUITE" 2>&1); RC4=$?
if [ "$RC4" -eq 0 ]; then ok; else bad "4: tests/mc-split-layout-test.sh must exit 0 (rc $RC4): $(grep '^FAIL' <<<"$OUT4" | sed -n 1,3p | tr '\n' ' ')"; fi
if grep -qE '^mc-split-layout-test: [0-9]+ passed, 0 failed$' <<<"$OUT4"; then ok; else bad "4: summary line must end '0 failed': $(echo "$OUT4" | tail -1)"; fi

echo "mc-split-layout.bh-9239-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
