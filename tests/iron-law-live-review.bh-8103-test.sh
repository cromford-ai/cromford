#!/bin/bash
# tests/iron-law-live-review.bh-8103-test.sh — BH-8103: on a live harness box
# the review lane does not move a shared checkout and does not run suites.
#
# WHY. On 2026-10-23 00:18Z the merge conductor's re-review agent ran
# `git checkout -q pr8069` in /root/harness-checkout on the hub and then ran
# `bash tests/agent-call-call-guard.k3-test.sh` there as root. Family 7 of
# bin/iron-law-guard.sh refuses both on HARNESS_LANE=review on a live box.
#
# Driven as shipped: the real guard, fed a real PreToolUse payload on stdin.
#   L1-L6   live detection (HARNESS_LIVE, the checkout's .git, the lane)
#   C1-C17  rule review-checkout, and its near-miss allows
#   S1-S20  rule review-suite, and its near-miss allows
#   P1      a push on the review lane is still agent-push (family 2 unchanged)
# Every deny: rc 2, the reason on stderr, ONE family=actguard-review-<rule>
# findings line, 0 ALERTS lines. Every allow: rc 0, no findings line.
#
# Red run: GUARD_OVERRIDE=<a copy of origin/main's guard> fails C1 and S1.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/iron-law-live-review.bh-8103-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# This suite is itself run by harness lanes that export these.
unset HARNESS_LANE HARNESS_LANE_PROJECT HARNESS_TICKET HARNESS_LANE_WT WT BUILD_DIR HARNESS_LANE_BUILD_DIR

H="$T/h"
mkdir -p "$H/logs" "$H/bin/lib"
( cd "$DIR" && scratch_install_closure bin/iron-law-guard.sh "$H" ) >/dev/null \
  || { echo "setup: could not install bin/iron-law-guard.sh"; exit 1; }
GUARD="${GUARD_OVERRIDE:-$H/bin/iron-law-guard.sh}"
# P1's agent-push deny makes the guard's one hold read. No vendor call: gh and
# curl are stubs that fail and log, and the suite asserts the log stays empty.
mkdir -p "$T/fakebin"
for b in gh curl; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/vendor-calls.log"\nexit 1\n' "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done
export PATH="$T/fakebin:$PATH" FLEET_CONF="$T/fleet.conf"
: > "$T/fleet.conf"
FIND="$H/logs/findings.log"
ALERTS="$H/logs/ALERTS.log"

CO="$T/checkout";   mkdir -p "$CO/.git"          # a deploy checkout: live box
NOCO="$T/nocheckout"                             # no checkout: a Fly or CI box
SCR="$T/scratch";   mkdir -p "$SCR/clone"        # the lane's own space

# guard <lane> <HARNESS_LIVE|-> <checkout-path> <command> <cwd> -> prints rc;
# stderr in $T/err. The env is built from nothing the parent exported.
guard() {
  local lane="$1" live="$2" co="$3" cmd="$4" cwd="$5" pl
  pl=$(jq -nc --arg c "$cmd" --arg d "$cwd" \
    '{session_id:"s1",hook_event_name:"PreToolUse",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}')
  local -a e=(env -u HARNESS_LIVE -u HARNESS_LANE_WT HARNESS="$H" HARNESS_CHECKOUT="$co"
              HARNESS_LANE="$lane" HARNESS_LANE_PROJECT=cromford HARNESS_TICKET=BH-8103)
  [ "$live" = - ] || e+=(HARNESS_LIVE="$live")
  [ -n "${LANE_WT:-}" ] && e+=(HARNESS_LANE_WT="$LANE_WT")
  printf '%s' "$pl" | timeout 30 "${e[@]}" bash "$GUARD" >/dev/null 2>"$T/err"
  echo $?
}
nlines() { awk 'END { print NR }' "$1" 2>/dev/null || echo 0; }

# expect <id> <deny-rule|allow> <lane> <live> <checkout> <cwd> <command> [stderr-text]
expect() {
  local id="$1" want="$2" lane="$3" live="$4" co="$5" cwd="$6" cmd="$7" txt="${8:-}" rc
  : > "$FIND"; : > "$ALERTS"
  rc=$(guard "$lane" "$live" "$co" "$cmd" "$cwd")
  if [ "$want" = allow ]; then
    [ "$rc" = 0 ] && [ "$(nlines "$FIND")" = 0 ] && ok \
      || bad "$id must ALLOW (rc $rc, findings $(nlines "$FIND")): $cmd :: $(head -1 "$T/err")"
    return 0
  fi
  [ "$rc" = 2 ] && ok || { bad "$id must DENY $want (rc $rc): $cmd"; return 0; }
  [ "$(nlines "$FIND")" = 1 ] && grep -q "family=actguard-$want " "$FIND" && ok \
    || bad "$id one family=actguard-$want findings line: $(cat "$FIND")"
  [ "$(nlines "$ALERTS")" = 0 ] && ok || bad "$id wrote ALERTS: $(cat "$ALERTS")"
  grep -q 'BLOCKED by the harness act-time iron-law guard' "$T/err" && ok || bad "$id no deny reason on stderr"
  [ -z "$txt" ] || { grep -qF -- "$txt" "$T/err" && ok || bad "$id stderr lacks '$txt': $(cat "$T/err")"; }
  return 0
}

INCIDENT='git checkout -q pr8069'

# ── live detection ──────────────────────────────────────────────────────────
echo "--- L"
# With no deploy checkout the shared tree in play is the harness itself.
expect L1 review-checkout review 1   "$NOCO" "$H"  "$INCIDENT"
expect L2 review-checkout review -   "$CO"   "$CO" "$INCIDENT"
expect L3 allow           review 0   "$CO"   "$CO" "$INCIDENT"
expect L4 allow           review -   "$NOCO" "$H"  "$INCIDENT"
expect L5 allow           review yes "$NOCO" "$H"  "$INCIDENT"
expect L6 allow           execute 1  "$CO"   "$CO" "$INCIDENT"

# ── review-checkout ─────────────────────────────────────────────────────────
echo "--- C"
rv() { expect "$1" "$2" review 1 "$CO" "$3" "$4" "${5:-}"; }
rv C1  review-checkout "$CO"  "$INCIDENT" "shared checkout"
rv C2  review-checkout "$SCR" "cd $CO && git checkout pr8069"
rv C3  review-checkout "$SCR" "git -C $CO switch pr8069"
rv C4  review-checkout "$CO"  "gh pr checkout 8069"
rv C5  review-checkout "$CO"  "rtk git checkout main"
rv C6  review-checkout "$H"   "git reset --hard origin/main"
rv C7  review-checkout "/root/repos/demo-bh8103" "git pull"
rv C8  review-checkout "$CO"  "git stash"
rv C9  review-checkout "$SCR" 'cd ${D:-/x} && git checkout pr8069'
rv C9b review-checkout ""     "git checkout pr8069"
rv C10 allow "$CO"  "git log --grep checkout"
rv C11 allow "$CO"  "git show pr8069:bin/x.sh"
rv C12 allow "$CO"  "git diff main...pr8069"
rv C13 allow "$CO"  "git worktree add $SCR/wt pr8069"
rv C14 allow "$SCR/clone" "git checkout pr8069"
rv C15 allow "$CO"  'echo "git checkout pr8069"'
rv C16 allow "$CO"  "git fetch origin pull/8069/head"
rv C16b allow "$CO" "git stash list"
# The agent-call cwd is the lane's own tree; when that IS the checkout (the
# 00:18Z shape), it does not make the checkout the lane's to move.
LANE_WT="$CO" rv C17 review-checkout "$CO" "$INCIDENT"
# A lane worktree strictly inside a protected root stays the lane's own.
mkdir -p "$H/builds/b1/wt"
LANE_WT="$H/builds/b1/wt" rv C17b allow "$H/builds/b1/wt" "git checkout pr8069"

# ── review-suite ────────────────────────────────────────────────────────────
echo "--- S"
rv S1  review-suite "$CO"  "bash tests/agent-call-call-guard.k3-test.sh" "not run here"
rv S2  review-suite "$SCR" "tests/x-test.sh"
rv S3  review-suite "$SCR" "./tests/mc/y.sh"
rv S4  review-suite "$SCR" "HARNESS_TEST_SANDBOX=1 bash tests/x.sh"
rv S5  review-suite "$SCR" "timeout 60 bash tests/x.sh"
rv S6  review-suite "$SCR" "bash -x tests/x.sh"
rv S7  review-suite "$SCR" "bash -c 'bash tests/x.sh'"
rv S8  review-suite "$SCR" 'for t in tests/*.sh tests/mc/*.sh; do bash "$t" || exit 1; done'
rv S9  review-suite "$SCR" "bin/test-impact-gate.sh --base origin/main"
rv S10 review-suite "$SCR" "bash /root/harness-checkout/tests/x.sh"
rv S11 review-suite "$SCR" "sh tests/x.sh"
rv S11b review-suite "$SCR" "cd $CO && bin/fast-lints.sh"
rv S11c review-suite "$SCR" 'for t in tests/*.sh; do HARNESS_TEST_SANDBOX=1 bash "$t"; done'
rv S12 allow "$SCR" "bash -n tests/x.sh"
rv S13 allow "$SCR" "cat tests/x.sh"
rv S14 allow "$SCR" "grep -n foo tests/*.sh"
rv S15 allow "$SCR" "shellcheck -S error tests/x.sh"
rv S16 allow "$SCR" "bash bin/render-rules.sh --check"
rv S16b allow "$SCR" 'for t in tests/*.sh; do bash -n "$t"; done'
rv S16c allow "$SCR" 'for f in tests/*.sh; do grep -c foo "$f"; done'
rv S16d allow "$SCR" 'echo "bash tests/x.sh"'
expect S17 allow review 0 "$CO" "$SCR" "bash tests/x.sh"
expect S18 allow execute 1 "$CO" "$SCR" "bash tests/x.sh"

# ── families 1-6 are unchanged on the review lane ───────────────────────────
echo "--- P"
: > "$FIND"
RC=$(guard review 1 "$CO" "git push origin ticket/bh-8103" "$SCR")
[ "$RC" = 2 ] && grep -q 'family=actguard-agent-push ' "$FIND" && ok \
  || bad "P1 a push on the review lane is still agent-push (rc $RC): $(cat "$FIND")"

[ -s "$T/vendor-calls.log" ] && bad "the suite reached gh/curl: $(cat "$T/vendor-calls.log")" || ok

echo "iron-law-live-review: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
