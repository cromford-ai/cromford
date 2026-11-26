#!/bin/bash
# tests/prr-step-lane.bh-9938-test.sh — BH-9938 slice C1 (C0 review note 1): a
# lane never runs under the PR-record step of the lane that started it.
#
# lane_env_apply exports a settings row and never unsets an inherited value
# (bin/lib/lane-gate.sh), so a child lane inherited its parent's GH_SOURCE.
#
#   P1  prr_step <lane> trusts GH_SOURCE only when GH_SOURCE_LANE is empty or
#       is <lane>; a value pinned for another lane reads <lane>'s own row
#   P2  prr_pin exports GH_SOURCE and GH_SOURCE_LANE; a child process asking
#       for another lane does not take the pinned value
#   P3  bin/wake-loop.sh launch(): the loop holds GH_SOURCE=record (its own
#       row, as lane_env_apply wake-loop exports it), the conductor's row is
#       shadow, and the conductor that launch() starts reads step shadow
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prr-step-lane.bh-9938-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }

# step <env...> -- <lane>: prr_step in a clean shell; the settings rows are
# merge-conductor=shadow and wake-loop=record.
step() {
  local e=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do e+=("$1"); shift; done
  shift
  env -i PATH="$PATH" HARNESS="$T" ${e[@]+"${e[@]}"} bash -c '
    setting_get() { case "$1" in lane.merge-conductor.gh_source) printf shadow ;; lane.wake-loop.gh_source) printf record ;; *) return 2 ;; esac; }
    . "$1/bin/lib/prr-shadow.sh" || exit 9
    prr_step "$2"' _ "$DIR" "$1"
}

# ── P1 ────────────────────────────────────────────────────────────────────────
eq "P1 no GH_SOURCE: the lane's own row" "$(step -- merge-conductor)" shadow
eq "P1 GH_SOURCE with no lane stamp is trusted (an operator or a test)" "$(step GH_SOURCE=record -- merge-conductor)" record
eq "P1 GH_SOURCE pinned for this lane is trusted" "$(step GH_SOURCE=off GH_SOURCE_LANE=merge-conductor -- merge-conductor)" off
eq "P1 GH_SOURCE pinned for another lane is not this lane's step" \
  "$(step GH_SOURCE=record GH_SOURCE_LANE=wake-loop -- merge-conductor)" shadow

# ── P2 ────────────────────────────────────────────────────────────────────────
GOT=$(env -i PATH="$PATH" HARNESS="$T" bash -c '
  setting_get() { case "$1" in lane.wake-loop.gh_source) printf record ;; *) return 2 ;; esac; }
  . "$1/bin/lib/prr-shadow.sh" || exit 9
  prr_pin wake-loop
  printf "%s %s " "$GH_SOURCE" "$GH_SOURCE_LANE"
  bash -c ". \"$1/bin/lib/prr-shadow.sh\"; setting_get() { printf shadow; }; prr_step merge-conductor"' _ "$DIR")
eq "P2 prr_pin exports the pair; a child lane reads its own row" "$GOT" "record wake-loop shadow"

# ── P3: wake-loop's launch() ──────────────────────────────────────────────────
WL="$DIR/bin/wake-loop.sh"
awk '/^launch\(\) \{/{on=1} on{print} on && /^\}/{exit}' "$WL" > "$T/launch.sh"
grep -q '^launch() {' "$T/launch.sh" && ok || bad "P3 launch() not found in bin/wake-loop.sh"
cat > "$T/conductor.sh" <<EOF
#!/usr/bin/env bash
setting_get() { case "\$1" in lane.merge-conductor.gh_source) printf shadow ;; *) return 2 ;; esac; }
. "$DIR/bin/lib/prr-shadow.sh"
printf '%s\n' "\$(prr_step merge-conductor)" > "$T/conductor.out.tmp" && mv "$T/conductor.out.tmp" "$T/conductor.out"
EOF
chmod +x "$T/conductor.sh"
rm -f "$T/conductor.out"
env -i PATH="$PATH" HARNESS="$T" GH_SOURCE=record T="$T" bash -c '
  say() { :; }; IS_HUB=1
  command -v setsid >/dev/null 2>&1 || setsid() { "$@"; }
  . "$T/launch.sh" || exit 9
  launch merge-conductor "$T/conductor.sh"'
i=0; until [ -s "$T/conductor.out" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
eq "P3 the launched conductor reads its own row, not the loop's GH_SOURCE" "$(cat "$T/conductor.out" 2>/dev/null)" shadow

echo "prr-step-lane.bh-9938: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
