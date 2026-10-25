#!/bin/bash
# tests/br-neighbors-test.sh — the resolver's contract with the scripts AROUND
# it. Sections 4, 5 and 7 of the old tests/blocked-resolver-test.sh, moved here
# verbatim by BH-1196.
#
# WHY THEY ARE ONE SUITE AND WHY IT IS NOT NAMED FOR A MODULE. None of these
# three drives a bin/lib/br/ module. Each one pins something a NEIGHBOUR must do
# for the resolver's decisions to mean anything: the iron-law ACCEPT marker has
# to be read by BOTH mergers (a marker only one of them honours is a PR that
# unparks in the conductor and parks again in the sweep, for ever);
# bin/fly-pool.sh must not park a row on an unearned second death; and no script
# in the family may still WRITE a park-for-a-human string, because the whole
# point of this lane is that there is nobody to park for.
#
# Sections carried (original numbering, from tests/blocked-resolver-test.sh):
#   4.  the iron-law ACCEPT marker is honored by both mergers
#   5.  fly-pool's death rule
#   7.  the scripts this change touched must not tell anybody to do it by hand
# Run from anywhere: tests/br-neighbors-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The whole fixture — scratch tree, br modules, sibling libs, the stubbed PATH
# and the RUN/ROW/ROWST/STATEJSON/SPENT helpers — is tests/lib/fixture-harness.sh
# (BH-1196). What is installed and why is documented there.
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE, in the suite's own text,
# so bin/test-impact.sh still selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$H/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes

# ============================================================================
# 4. The iron-law ACCEPT marker is HONORED by both mergers that must honor it.
#    Asserted by driving each one, because a marker only one of them reads is a
#    PR that unparks in the conductor and parks again in the sweep, for ever.
# ============================================================================
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$H/builds/tproj-TK-9-202609130001"
REC="$H/builds/tproj-TK-9-202609130001"
printf 'PR_CREATED https://github.com/o/tproj/pull/9\n' > "$REC/RESULT"
printf 'findings\nVERDICT: APPROVE\n' > "$REC/review.md"
printf -- '+++ b/src/x.tsx\n+  window.confirm("really?")\n' > "$T/prdiff"
# The sweep: mergeState CLEAN, verdict APPROVE, one iron-law hit in the diff.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # The sweep's decision reads are REST now (BH-784): ONE pull object carries the
  # state, the merge state, the author and the head sha the three arms below used
  # to answer separately, and the diff comes back behind the v3.diff Accept
  # header. The diff arm is matched FIRST — both are GET .../pulls/9 and they
  # differ only by that header.
  # BOTH SIT ABOVE THE SHARED "-i -X" ARM ON PURPOSE. tests/lib/gh-rest-stub.sh
  # answers a pull with state, head, base and title only — no mergeable_state and
  # no author — which is exactly what the sweep needs here, so delegating this
  # PR's read to it leaves the sweep skipping on mergeState=UNKNOWN and this
  # section green on a sweep that never scanned a diff.
  *"v3.diff"*) restpr --raw 200; cat "$T/prdiff" 2>/dev/null ;;
  *"api -i -X GET repos/o/tproj/pulls/9"*) restpr OPEN "$SHA" ticket/TK-9 main "" MERGEABLE CLEAN operator ;;
  # bin/blocked-resolver.sh reads, comments and closes over REST (#783): the
  # gh-api-dash-i envelope is answered once, in tests/lib/gh-rest-stub.sh.
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*) printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merged.txt"; exit 0 ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
SWEEP() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" bash "$H/bin/merge-sweep.sh" >/dev/null 2>&1 ) || true; }
: > "$H/state/merge-sweep-done.txt"; : > "$H/logs/merge-sweep.log"
SWEEP
grep -q 'iron-law red-flag line' "$H/logs/merge-sweep.log" && ok || bad "without the marker the sweep must still park on an iron-law hit"
: > "$REC/iron-law-accepted-$SHA"
: > "$H/state/merge-sweep-done.txt"; : > "$H/logs/merge-sweep.log"
SWEEP
# BH-7804: the marker file is no ACCEPT any more; only the ironlaw-head-accept
# row is (tests/ironlaw-head-accept.bh-4157-test.sh S1-S3 drive the row).
grep -q 'iron-law red-flag line' "$H/logs/merge-sweep.log" && ok || bad "a legacy iron-law-accepted-<sha> file must not unpark: the sweep still parks (log: $(tail -2 "$H/logs/merge-sweep.log"))"
grep -q 'ADJUDICATED ACCEPT' "$H/logs/merge-sweep.log" && bad "the sweep must not read iron-law-accepted-<sha> ($(grep 'ADJUDICATED ACCEPT' "$H/logs/merge-sweep.log"))" || ok
rm -f "$REC/iron-law-accepted-$SHA"
# The conductor does not read the file name either; its head ACCEPT check is
# mc_ila_accept (guarded: an absent reader must fail, not pass).
grep -q 'mc_ila_accept' "$H/bin/merge-conductor.sh" && ok || bad "bin/merge-conductor.sh must call mc_ila_accept"
grep -q 'iron-law-accepted-' "$H/bin/merge-conductor.sh" && bad "bin/merge-conductor.sh must not read iron-law-accepted-<head>" || ok

# ============================================================================
# 5. fly-pool's death rule: a row enqueued at attempt>=1 must NOT park on its
#    FIRST death. This is the exact shape of the bug — the 2026-09-13 rebuild
#    wave enqueued nine keys at attempt 2, and every one of them would have
#    parked the moment its machine died once.
# ============================================================================
POOL="$H/state/fly-pool/tproj"; mkdir -p "$POOL" "$H/state/fly"
echo '{"app":"pool-tproj"}' > "$H/state/fly/tproj.json"
echo 3 > "$H/flags/fly-pool-tproj"; echo pool-tproj > "$H/flags/fly-pool-app-tproj"
printf 'FLY_API_TOKEN_TPROJ=t\n' > "$H/env/fly.env"
mkdir -p "$T/flybin"
# A machine that is GONE: `machine status` prints nothing, which is the loop's
# "dead" branch.
printf '#!/bin/bash\nexit 0\n' > "$T/flybin/fly"; chmod +x "$T/flybin/fly"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf 'put %s\n' "\$*" >> "$T/pool-queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/pool-queue.txt"; return 0; }
queue_claim() { return 0; }
queue_list() { return 1; }
EOF
POOLRUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/flybin" POOL_SPAWN=0 \
    bash "$H/bin/fly-pool.sh" tproj >/dev/null 2>&1 ) || true; }
# attempt 2 (what an enqueuer put on the row), deaths 0 (nothing observed yet).
echo '{"machine":"m1","key":"TK-9","ticket_id":"9","attempt":2,"deferrals":0,"deaths":0}' > "$POOL/m1.json"
: > "$T/pool-queue.txt"
POOLRUN
# A requeue CLOSES the dead attempt before re-enqueueing, so "queue_done failed"
# alone is not the park — the park is the one whose reason says so, plus the
# .failed.json the resolver reads.
grep -q 'parked for the blocked-resolver' "$T/pool-queue.txt" && bad "the FIRST observed death of a row enqueued at attempt>=1 must NOT park it (got: $(cat "$T/pool-queue.txt"))" || ok
grep -q 'put tproj TK-9' "$T/pool-queue.txt" && ok || bad "the first death must requeue (got: $(cat "$T/pool-queue.txt"))"
[ -f "$H/state/build-queue/tproj/TK-9.failed.json" ] && bad "the first death must not write a .failed.json" || ok
grep -q '"deaths":1' "$H/state/build-queue/tproj/TK-9.json" 2>/dev/null && ok || bad "the requeued row must carry deaths:1"
# The SECOND observed death does park.
echo '{"machine":"m2","key":"TK-9","ticket_id":"9","attempt":3,"deferrals":0,"deaths":1}' > "$POOL/m2.json"
: > "$T/pool-queue.txt"
POOLRUN
grep -q 'done tproj TK-9 failed' "$T/pool-queue.txt" && ok || bad "the SECOND observed death must close the row failed (got: $(cat "$T/pool-queue.txt"))"
grep -q 'parked for the blocked-resolver' "$T/pool-queue.txt" && ok || bad "the park reason must name the blocked-resolver, not a human"
[ -f "$H/state/build-queue/tproj/TK-9.failed.json" ] && ok || bad "the second death must write the .failed.json the resolver reads"

# ============================================================================
# 7. The scripts this change touched must not tell anybody to do it by hand.
# ============================================================================
# CODE, not prose: a comment explaining what the old wording was, and the
# backward-compatible matcher that still RECOGNISES rows carrying it, are both
# correct. What must be gone is any line that WRITES one of these words.
for f in blocked-resolver.sh merge-conductor.sh merge-sweep.sh fly-pool.sh jobs-watchdog.sh \
         review-rescue.sh rebase-train.sh lib/resume-dead.sh; do
  HITS=$(grep -nE "parked for a human|needs a human|merge by hand|resolve by hand|review by hand|enqueue by hand|needs a human rebase" "$DIR/bin/$f" 2>/dev/null \
         | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '^[0-9]+:[[:space:]]*case ' || true)
  [ -z "$HITS" ] && ok || bad "bin/$f still WRITES a park-for-a-human string: $HITS"
done

echo "br-neighbors-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
