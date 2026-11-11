#!/bin/bash
# tests/br-one-pr-lock.bh-9369-test.sh — BH-9369 fix 6: a BR_ONLY_PR run takes
# its own lock, locks/blocked-resolver-<project>-pr-<n>.lock, and the sweep
# skips that PR's rows while the lock is held.
#
# THE BUG (hub, 2026-11-09). The conductor starts a one-PR run for a park whose
# fix round must start now (BH-6000). It took the PROJECT lock, so while the
# project's sweep ran (up to an hour) it logged "another tick is live" and
# exited: the fix round it was started for did not start.
#
#   A  the sweep lock is held: `BR_ONLY_PR=o/p1#7 blocked-resolver.sh p1`
#      starts, offers only #7, exits 0, and leaves .tick-budget-p1 and
#      .saturation-p1.tsv byte-identical (no SATURATED alert)
#   B  the -pr-7 lock is held: a sweep over #7 and #8 logs
#      `skip: one-PR run holds 7`, dispatches #8, not #7
#   C  a free -pr-7.lock file: #7 is dispatched; a held -pr-71 lock does not
#      skip #7
#   D  BR_ONLY_PR=o/p1#7x, or no project argument: exit 2, no lock file
#
# WHAT IS DRIVEN. Every case runs the real bin/blocked-resolver.sh end to end
# against a scratch $HARNESS (the rig of tests/blocked-resolver-overdue.bh-7555-test.sh).
# A lock is held by a background `sleep` that owns the flock. No vendor is
# called (BH-7563): gh is a local stub, GH_TOKEN is empty.
# Run from anywhere: tests/br-one-pr-lock.bh-9369-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" 2>/dev/null || true
# The fragment the sweep asks, named by its rooted path so the orphan check sees it.
[ -f "$DIR/bin/blocked-resolver.d/bh-9369-one-pr-lock.sh" ] || bad "0: bin/blocked-resolver.d/bh-9369-one-pr-lock.sh must exist"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
for L in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh \
         bin/lib/hold.sh bin/lib/gh-rest.sh $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
{ printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh agent-call.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-p1"

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
LOGF="$H/logs/blocked-resolver.log"
CONFLICT="conflict-unresolvable: CONFLICT (content): Merge conflict in src/a.ts"
ROWADD() { printf 'o/p1#%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\thttps://github.com/o/p1/pull/%s\n' \
             "$1" "$((NOW - 600))" "$CONFLICT" "$1" >> "$ROWS"; }
RUNRC=0
RUN() { RUNRC=0
        ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
          BR_SSH="$T/fakebin/br-ssh" BR_PER_TICK=10 BR_PER_TICK_P1=10 env "$@" \
          bash "$H/bin/blocked-resolver.sh" ${RUNARGS[@]+"${RUNARGS[@]}"} >>"$T/run.log" 2>&1 ) || RUNRC=$?; }
RUNARGS=(p1)
LOG() { cat "$LOGF" 2>/dev/null; }
DISPATCHED() { grep -qE "p1/o-p1-$1 \\[[^]]*\\] -> " "$LOGF"; }
# HOLD <lock name> — a background sleep owns the flock until UNHOLD.
HOLDER=""
HOLD() { ( exec 9>"$H/locks/$1"; flock -n 9 || exit 1; exec sleep 300 ) & HOLDER=$!
         local i; for i in $(seq 1 50); do
           ( exec 8<"$H/locks/$1"; flock -n 8 ) 2>/dev/null || return 0; sleep 0.1; done
         echo "setup: the holder did not take $1"; exit 1; }
UNHOLD() { [ -n "$HOLDER" ] && { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }; HOLDER=""; }
trap 'UNHOLD' EXIT
CLEAN() { UNHOLD
          scratch_rm "$ST" 2>/dev/null; mkdir -p "$ST"
          scratch_rm "$H/locks" 2>/dev/null; mkdir -p "$H/locks"
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          : > "$T/alerts.txt"; : > "$LOGF"; : > "$ROWS"; RUNARGS=(p1); }

# ============================================================================
# A. THE BUG. The sweep holds locks/blocked-resolver-p1.lock. The one-PR run
#    for #7 starts anyway, offers only #7, and writes no sweep tick file.
# ============================================================================
CLEAN
ROWADD 7; ROWADD 8
printf '3\n' > "$ST/.tick-budget-p1"
printf 'streak\t2\talerted\t0\nrungs\tp1\t9\n' > "$ST/.saturation-p1.tsv"
cp "$ST/.tick-budget-p1" "$T/budget-before"; cp "$ST/.saturation-p1.tsv" "$T/sat-before"
HOLD blocked-resolver-p1.lock
RUN BR_ONLY_PR='o/p1#7' BR_SATURATED_TICKS=1
UNHOLD
[ "$RUNRC" = 0 ] && ok || bad "A: the one-PR run exits 0 (rc $RUNRC)"
grep -q 'another tick is live' "$T/run.log" "$LOGF" 2>/dev/null \
  && bad "A: THE BUG: the one-PR run must not exit on the sweep's lock ($(grep -h 'another tick' "$T/run.log" "$LOGF" | tail -1))" || ok
grep -q 'one-PR run for o/p1#7: 1 of 1 candidate(s) are its rows' "$LOGF" && ok \
  || bad "A: the one-PR run sees only #7's row (log: $(LOG | grep -i 'one-PR' | head -3))"
DISPATCHED 7 && ok || bad "A: #7 is dispatched by the one-PR run (log: $(LOG | grep 'o-p1-7 ' | head -3))"
DISPATCHED 8 && bad "A: #8 belongs to the sweep, not to the one-PR run" || ok
cmp -s "$ST/.tick-budget-p1" "$T/budget-before" && ok || bad "A: .tick-budget-p1 is byte-identical ($(cat "$ST/.tick-budget-p1"))"
cmp -s "$ST/.saturation-p1.tsv" "$T/sat-before" && ok || bad "A: .saturation-p1.tsv is byte-identical ($(cat "$ST/.saturation-p1.tsv"))"
grep -q SATURATED "$T/alerts.txt" "$LOGF" 2>/dev/null && bad "A: a one-PR run writes no SATURATED alert" || ok
[ -e "$H/locks/blocked-resolver-p1-pr-7.lock" ] && ok || bad "A: the one-PR run took locks/blocked-resolver-p1-pr-7.lock"

# A second one-PR run of the SAME PR still exits at its own lock.
: > "$LOGF"; : > "$T/run.log"
HOLD blocked-resolver-p1-pr-7.lock
RUN BR_ONLY_PR='o/p1#7'
UNHOLD
grep -q 'another tick is live (locks/blocked-resolver-p1-pr-7.lock held)' "$T/run.log" && ok \
  || bad "A: a second one-PR run of #7 exits on the -pr-7 lock ($(tail -2 "$T/run.log"))"

# ============================================================================
# B. A one-PR run holds #7. The sweep skips #7 with one line and works #8.
# ============================================================================
CLEAN
ROWADD 7; ROWADD 8
HOLD blocked-resolver-p1-pr-7.lock
RUN
UNHOLD
grep -q 'p1/o-p1-7: skip: one-PR run holds 7$' "$LOGF" && ok \
  || bad "B: the sweep logs 'skip: one-PR run holds 7' (log: $(LOG | grep -E 'o-p1-7[ :]' | head -4))"
DISPATCHED 7 && bad "B: the sweep must not dispatch the held #7" || ok
DISPATCHED 8 && ok || bad "B: the sweep dispatches #8 (log: $(LOG | grep 'o-p1-8 ' | head -3))"
grep 'tick: candidates=' "$LOGF" | tail -1 | grep -qE ' rungs=1/' && ok \
  || bad "B: the tick's rung count excludes #7 (tick: $(grep 'tick: candidates=' "$LOGF" | tail -1))"

# ============================================================================
# C. A free -pr-7.lock file (a finished one-PR run): #7 is dispatched. A held
#    -pr-71 lock is another PR's: #7 is not skipped.
# ============================================================================
CLEAN
ROWADD 7
: > "$H/locks/blocked-resolver-p1-pr-7.lock"
HOLD blocked-resolver-p1-pr-71.lock
RUN
UNHOLD
DISPATCHED 7 && ok || bad "C: #7 is dispatched with a free lock file and another PR's held lock (log: $(LOG | grep -E 'o-p1-7[ :]' | head -3))"
grep -q 'skip: one-PR run holds' "$LOGF" && bad "C: no skip line" || ok

# ============================================================================
# D. A malformed BR_ONLY_PR, or no project: exit 2, no lock file.
# ============================================================================
CLEAN
ROWADD 7
RUN BR_ONLY_PR='o/p1#7x'
[ "$RUNRC" = 2 ] && ok || bad "D: BR_ONLY_PR=o/p1#7x exits 2 (rc $RUNRC)"
[ -z "$(ls -A "$H/locks")" ] && ok || bad "D: no lock file is created ($(ls "$H/locks"))"
RUNARGS=()
RUN BR_ONLY_PR='o/p1#7'
[ "$RUNRC" = 2 ] && ok || bad "D: BR_ONLY_PR with no project exits 2 (rc $RUNRC)"
[ -z "$(ls -A "$H/locks")" ] && ok || bad "D: no lock file with no project ($(ls "$H/locks"))"

echo "br-one-pr-lock.bh-9369: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
