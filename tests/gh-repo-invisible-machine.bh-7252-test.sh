#!/bin/bash
# tests/gh-repo-invisible-machine.bh-7252-test.sh — BH-7252 C1:
# gh_repo_invisible_alert (bin/lib/gh-repo-token.sh) on a lane-run machine.
# A machine's flags/ never rides back to the hub, so a flag kept there repeats
# the alert every tick, and a beat.sh fleet_alert from a machine reaches no
# hub. With LANE_RUN_ID set the once-a-day flag goes under GHRT_FLAG_DIR (the
# caller's write-back dir) and no beat is made; on the hub nothing changes.
#
#   G1  LANE_RUN_ID=r1, GHRT_FLAG_DIR=state/pipeline-health/pa: one call
#       writes the flag there, 1 alert-line call, 0 beat calls; a second call
#       the same day makes 0 calls; a flag from 3 days ago is pruned, the one
#       from yesterday stays; nothing is written under flags/
#   G1b LANE_RUN_ID=r1 and no GHRT_FLAG_DIR: the flag stays in flags/, still
#       0 beat calls
#   G2  LANE_RUN_ID unset: the flag goes in flags/, 1 alert-line call and 1
#       beat call (kind fleet_alert), as before; LANE_RUN_ID empty: the same
#   G3  the pipeline-health write-back carries the machine flag path
#       (lri_member_ok ... rw pipeline-health is rc 0)
#   G4  bin/pipeline-health.sh --project on a machine exports GHRT_FLAG_DIR
#       as state/pipeline-health/<p> (the real script's machine dedup block)
#
# The clock is GHRT_TODAY (read only under HARNESS_TEST_SANDBOX=1).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/gh-repo-invisible-machine.bh-7252-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
unset LANE_RUN_ID GHRT_FLAG_DIR GH_TOKEN

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/state" "$T/fakebin"
( cd "$REPO" && scratch_install_closure bin/lib/gh-repo-token.sh "$H" ) >/dev/null 2>&1 \
  || bad "setup: could not install bin/lib/gh-repo-token.sh"
# The hub flag goes through bin/lib/flags.sh, which loads bin/jobs-client.sh.
# This scratch has no worker, so call() sets JOBS_ALERT=0: the client's own
# "harness-jobs unreachable" day flag is not this suite's subject.
( cd "$REPO" && scratch_install_closure bin/jobs-client.sh "$H" ) >/dev/null 2>&1 \
  || bad "setup: could not install bin/jobs-client.sh"
# Recorders: alert-line.sh and beat.sh, one line per call.
printf '#!/bin/bash\nprintf "alert %%s\\n" "$*" >> "%s/calls"\n' "$T" > "$H/bin/alert-line.sh"
printf '#!/bin/bash\nprintf "beat %%s\\n" "$1" >> "%s/calls"\n' "$T" > "$H/bin/beat.sh"
# gh sees nothing: every repo is invisible to every token.
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
chmod +x "$H/bin/alert-line.sh" "$H/bin/beat.sh" "$T/fakebin/gh"

TODAY=20261017
# call [env...] — one gh_repo_invisible_alert call in a fresh shell.
call() {
  env PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_TEST_SANDBOX=1 GHRT_TODAY="$TODAY" JOBS_ALERT=0 "$@" \
    bash -c '. "$HARNESS/bin/lib/gh-repo-token.sh" && gh_repo_invisible_alert pipeline-health o/r "3 PRs skipped"' \
    > "$T/call.out" 2>&1
}
n() { grep -c "^$1 " "$T/calls" 2>/dev/null || true; }
reset() { rm -f "$T/calls"; scratch_rm "$H/flags" 2>/dev/null; scratch_rm "$H/state/pipeline-health" 2>/dev/null; mkdir -p "$H/flags"; return 0; }

# ── G1 machine, flag dir set ────────────────────────────────────────────────
reset
FD="$H/state/pipeline-health/pa"
mkdir -p "$FD"
touch "$FD/alerted-repo-invisible-pipeline-health-o_r-20261014" "$FD/alerted-repo-invisible-pipeline-health-o_r-20261016"
touch "$FD/alerted.json"
call LANE_RUN_ID=r1 GHRT_FLAG_DIR="$FD"
[ -f "$FD/alerted-repo-invisible-pipeline-health-o_r-$TODAY" ] && ok "G1 flag in GHRT_FLAG_DIR" \
  || bad "G1 no flag in $FD: $(ls "$FD") / $(cat "$T/call.out")"
[ "$(n alert)" = 1 ] && ok "G1 1 alert-line call" || bad "G1 alert calls: $(n alert)"
[ "$(n beat)" = 0 ] && ok "G1 0 beat calls on a machine" || bad "G1 beat calls: $(n beat)"
[ -z "$(ls -A "$H/flags")" ] && ok "G1 nothing under flags/" || bad "G1 flags/: $(ls "$H/flags")"
call LANE_RUN_ID=r1 GHRT_FLAG_DIR="$FD"
[ "$(n alert)" = 1 ] && [ "$(n beat)" = 0 ] && ok "G1 second call the same day: 0 calls" \
  || bad "G1 second call: alert=$(n alert) beat=$(n beat)"
[ ! -e "$FD/alerted-repo-invisible-pipeline-health-o_r-20261014" ] && ok "G1 the 3-day-old flag is pruned" \
  || bad "G1 20261014 flag still there"
[ -e "$FD/alerted-repo-invisible-pipeline-health-o_r-20261016" ] && ok "G1 yesterday's flag stays" \
  || bad "G1 20261016 flag gone"
[ -e "$FD/alerted.json" ] && ok "G1 the prune leaves other files" || bad "G1 alerted.json deleted"

# ── G1b machine, no flag dir ────────────────────────────────────────────────
reset
call LANE_RUN_ID=r1
[ -f "$H/flags/alerted-repo-invisible-pipeline-health-o_r-$TODAY" ] && [ "$(n alert)" = 1 ] && [ "$(n beat)" = 0 ] \
  && ok "G1b no GHRT_FLAG_DIR: flags/, 1 alert, 0 beat" || bad "G1b: flags=$(ls "$H/flags") alert=$(n alert) beat=$(n beat)"

# ── G2 hub ──────────────────────────────────────────────────────────────────
for mode in unset empty; do
  reset
  if [ "$mode" = unset ]; then call GHRT_FLAG_DIR="$H/state/pipeline-health/pa"
  else call LANE_RUN_ID= GHRT_FLAG_DIR="$H/state/pipeline-health/pa"; fi
  [ -f "$H/flags/alerted-repo-invisible-pipeline-health-o_r-$TODAY" ] && ok "G2 ($mode) flag in flags/" \
    || bad "G2 ($mode) flags/: $(ls "$H/flags") / $(cat "$T/call.out")"
  [ ! -e "$H/state/pipeline-health/pa" ] && ok "G2 ($mode) GHRT_FLAG_DIR ignored on the hub" || bad "G2 ($mode) wrote under GHRT_FLAG_DIR"
  [ "$(n alert)" = 1 ] && [ "$(n beat)" = 1 ] && ok "G2 ($mode) 1 alert, 1 beat" || bad "G2 ($mode) alert=$(n alert) beat=$(n beat)"
  grep '^beat ' "$T/calls" 2>/dev/null | cut -d' ' -f2- | jq -e '.kind == "fleet_alert" and .akey == "repoinvisible:pipeline-health:o/r"' >/dev/null 2>&1 \
    && ok "G2 ($mode) the beat is a fleet_alert" || bad "G2 ($mode) beat: $(grep '^beat' "$T/calls")"
done

# ── G3 the write-back carries the flag ──────────────────────────────────────
if ( export HARNESS="$H" LRI_MANIFEST_DIR="$REPO/catalog/lane-run-inputs.d"
     . "$REPO/bin/lib/lane-run-inputs.sh" || exit 9
     lri_member_ok pa "state/pipeline-health/pa/alerted-repo-invisible-pipeline-health-o_r-$TODAY" - rw pipeline-health ); then
  ok "G3 lri_member_ok accepts the machine flag path"
else bad "G3 lri_member_ok refused state/pipeline-health/pa/alerted-repo-invisible-*"; fi

# ── G4 the real script exports GHRT_FLAG_DIR on a machine ───────────────────
# The machine dedup block of bin/pipeline-health.sh, cut from the shipped file
# and run with LANE_RUN_ID set, then unset.
BLOCK=$(sed -n '/^# >>> machine dedup/,/^# <<< machine dedup/p' "$REPO/bin/pipeline-health.sh")
if [ -z "$BLOCK" ]; then bad "G4 no machine dedup block in bin/pipeline-health.sh"
else
  mkdir -p "$T/g4"; : > "$T/g4/fleet.conf"; echo '{}' > "$T/g4/health-alerted.json"
  mkdir -p "$T/g4/state"; cp "$T/g4/health-alerted.json" "$T/g4/state/"
  # shellcheck disable=SC2016 # expanded by the inner bash
  got=$(env -u GHRT_FLAG_DIR LANE_RUN_ID=r1 H="$T/g4" PH_MODE=project PH_PROJECT=pa NOW=1760000000 DEDUP=x \
        bash -c "$BLOCK"$'\nprintf "%s" "${GHRT_FLAG_DIR:-}"; bash -c '"'"'printf "|%s" "${GHRT_FLAG_DIR:-}"'"'" 2>/dev/null)
  [ "$got" = "$T/g4/state/pipeline-health/pa|$T/g4/state/pipeline-health/pa" ] \
    && ok "G4 machine: GHRT_FLAG_DIR=state/pipeline-health/pa, exported" || bad "G4 machine: got '$got'"
  got=$(env -u GHRT_FLAG_DIR -u LANE_RUN_ID H="$T/g4" PH_MODE=project PH_PROJECT=pa NOW=1760000000 DEDUP=x \
        bash -c "$BLOCK"$'\nprintf "%s" "${GHRT_FLAG_DIR:-}"' 2>/dev/null)
  [ -z "$got" ] && ok "G4 hub: GHRT_FLAG_DIR not set" || bad "G4 hub: got '$got'"
fi

echo "gh-repo-invisible-machine: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
