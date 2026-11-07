#!/bin/bash
# tests/pool-relay-rowfirst-test.sh — a reaped pool result travels as a ROW, and
# only falls back to ssh when the ledger did not take it.
#
# WHAT THIS IS ABOUT. When a fly machine finishes, bin/fly-pool.sh reaped the
# result and PUSHED it into the owning box: the json over ssh into `cat`, the
# RESULT/review/plan into the box's build dir, and a `touch` on its merge queue.
# The box has been PULLING the same result from the job row since #229, with the
# one-dir guard that stops both landing — so both paths ran and the guard
# deduped. This makes the push what it should be: a fallback.
#
# WHY DRIVEN AND NOT GREPPED. The headline claim is a NEGATIVE — no ssh happens
# on the healthy path — and the ssh stub therefore FAILS THE TEST if it is ever
# invoked. That cannot be asserted by reading the source, and it fails silently
# in production: the push works, so nothing would ever say the hop was still
# there.
# Run from anywhere: tests/pool-relay-rowfirst-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/h/env" \
         "$T/h/state/fly" "$T/h/state/fly-pool/project-3" "$T/h/state/remote-results/project-3" \
         "$T/h/builds" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" \
   "$DIR/bin/result-prefix-ok.sh" "$T/h/bin/"
cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# TEST-CHANGE (BH-1041): the reap asks bd_result_in_ledger for the three-way
# answer now, so the lib has to be on the fixture box. Without it the reap reads
# "no jobs client" and every case below falls to the ssh push.
cp "$DIR/bin/lib/builder-direct.sh" "$T/h/bin/lib/"
cp "$DIR/fleet.conf" "$T/h/fleet.conf"
printf 'HARNESS_SECRET=test-secret\n' > "$T/h/env/global.env"
: > "$T/h/env/fly.env"
printf '3\n' > "$T/h/flags/fly-pool-project-3"
printf 'pool-project-3\n' > "$T/h/flags/fly-pool-app-project-3"
printf '{"app":"pool-project-3"}\n' > "$T/h/state/fly/project-3.json"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\necho OPEN\n' > "$T/fakebin/gh"   # the PR verifies, so RESULT is not rewritten
# base64 DIALECTS, and this shim must not pick a side. GNU takes `-d FILE` and
# `-w0`; BSD takes `-D`, ignores a positional input (reading stdin instead) and
# spells the no-wrap flag `-b 0`. The scripts speak GNU. A shim that simply
# rewrote -d to -D made the artifact decodes silently produce EMPTY files on a
# laptop AND broke CI on Linux the other way — so it PROBES the host once and
# always feeds input on stdin, which both dialects accept.
cat > "$T/fakebin/base64" <<'STUB'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;                     # operand of a separated `-w 0`
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
STUB

# FLY_BIN_DIR (2026-09-11): bin/fly-pool.sh prepends the real flyctl directory
# to PATH absolutely, so on any box that HAS flyctl — the hub — the `fly` stub
# below was shadowed and this suite drove the real binary. Every case failed
# there and passed only where flyctl is absent, which is the opposite of a test.
# THE SSH STUB IS THE ASSERTION. Every invocation is recorded, and the healthy
# path is expected to leave that file empty.
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
echo "ssh $*" >> "$SSH_SINK"
exit 0
STUB

# flyctl: one machine with a finished RESULT, so the reap runs end to end.
# NOTE THE LOOSE PATTERNS. mexec wraps its command with `printf %q`, which on
# bash 3.2 escapes each space with a backslash — so `*"head -1 /run/harness/..."*`
# never matches and the whole reap silently does nothing. That is precisely the
# vacuous-pass shape this suite exists to avoid, so the matches are on single
# tokens and the base64 case is ordered FIRST.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *base64*RESULT*)    printf 'UFJfQ1JFQVRFRCBodHRwczovL2dpdGh1Yi5jb20vby9yL3B1bGwvNTUKVElFUjogMQo=\n' ;;
  *base64*review*)    printf 'VkVSRElDVDogQVBQUk9WRQo=\n' ;;   # VERDICT: APPROVE
  *base64*)           : ;;                       # the other artifact pulls: absent
  *head*RESULT*)      echo "PR_CREATED https://github.com/o/r/pull/55" ;;
  *ls*builds*)        echo "/data/harness/builds/project-3-TK-9-1" ;;
  *stat*heartbeat*)   echo 5 ;;                  # fresh, so the machine reads alive
  *) : ;;
esac
exit 0
STUB
chmod +x "$T/h/bin/beat.sh" "$T/fakebin"/* "$T/h/bin/result-prefix-ok.sh"

# curl: the artifact feed is what decides row-vs-ssh. FEED_HAS_KEY=1 means the
# ledger carries this build's result.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
[ "${CLIENT_DOWN:-0}" = 1 ] && exit 7
case "$URL" in
  */api/artifacts\?*)
    if [ "${FEED_HAS_KEY:-0}" = 1 ]; then
      printf '%s\n200\n' '{"artifacts":[{"job_id":"j1","artifact_kind":"result","artifact_ref":"PR_CREATED https://github.com/o/r/pull/55","box":"pool-machine-1","ticket_id":"9","updated_at":"2026-09-11T01:00:00Z","detail":"{\"build_dir\":\"project-3-TK-9-1\",\"key\":\"TK-9\",\"job_status\":\"done\"}"}]}'
    else
      printf '{"artifacts":[]}\n200\n'
    fi ;;
  */api/merge-queue)
    if [ "${MQ_FAIL:-0}" = 1 ]; then printf 'boom\n500\n'; else
      printf '{"merge":{"project":"project-3","pr":55,"status":"queued"},"duplicate":false}\n201\n'; fi ;;
  *)                 printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin/curl"

reap() { # reap <FEED_HAS_KEY> [CLIENT_DOWN] [MQ_FAIL]
  rm -rf "$T/h/builds"/* ; : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$T/h/logs/fly-pool.log"
  printf '{"machine":"m1","key":"TK-9","ticket_id":"9","attempt":0}\n' > "$T/h/state/fly-pool/project-3/m1.json"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           FLEET_CONF="$T/h/fleet.conf" REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" \
           FEED_HAS_KEY="$1" CLIENT_DOWN="${2:-0}" MQ_FAIL="${3:-0}" FLY_API_TOKEN_PROJECT_3_OS=tok \
           FLY_BIN_DIR="$T/fakebin"
    bash "$DIR/bin/fly-pool.sh" project-3 >/dev/null 2>&1 )
}
relayed() { ls -d "$T/h/builds/pool-project-3-TK-9-"*/RELAYED 2>/dev/null | head -1; }

# ══ 1. THE ROW CARRIES IT — AND NO ssh HAPPENS ══════════════════════════════
reap 1
[ ! -s "$T/ssh.txt" ] \
  && ok || bad "THE POINT: with the result in the ledger, no ssh may happen. Got: $(cat "$T/ssh.txt")"
[ -n "$(relayed)" ] && ok || bad "custody still has to be marked RELAYED for the close-out checks"
grep -q 'no ssh push; the box pulls it' "$T/h/logs/fly-pool.log" \
  && ok || bad "the log must say the row carried it: $(cat "$T/h/logs/fly-pool.log")"
grep -q 'POST https://jobs.invalid/api/merge-queue' "$T/req.txt" \
  && ok || bad "a tier-1 APPROVE must be enqueued as a merge_queue ROW, not an ssh touch"
grep -q 'merge-queue' "$T/ssh.txt" 2>/dev/null \
  && bad "the merge-queue touch must NOT happen on the row path" || ok
# The hub json stays: nothing was pushed, so nothing has provably arrived, and
# it is the only other copy until the box reads the row.
[ -f "$T/h/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "the hub json must be kept on the row path"
[ -z "$(grep -c 'COORDINATION DB DEGRADED' "$T/h/logs/ALERTS.log" 2>/dev/null | grep -v '^0$')" ] \
  && ok || bad "the healthy path must not alert"

# ══ 2. THREE FAILURES, THREE MESSAGES, THREE ACTIONS ═══════════════════════
# "The ledger did not take it" was one sentence for three different faults, and
# they have different remedies: a dead worker, a build that never recorded its
# result, and a merge enqueue that failed while the result travelled fine. One
# message sends a human to look for the wrong thing.

# (a) THE FEED ANSWERED AND THE KEY IS NOT IN IT -> full push.
rm -f "$T/h/flags"/alerted-pool-relay-* "$T/h/logs/ALERTS.log"
reap 0
grep -q 'NO RESULT ROW' "$T/h/logs/ALERTS.log" \
  && ok || bad "a missing result row must say so: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
grep -q 'LEDGER UNREADABLE' "$T/h/logs/ALERTS.log" \
  && bad "an answered-but-empty ledger is not an unreadable one" || ok
grep -q 'remote-results' "$T/ssh.txt" && ok || bad "(a) must push the json: $(cat "$T/ssh.txt")"
grep -q 'builds/' "$T/ssh.txt"        && ok || bad "(a) must push the artifacts"
# ...but NOT the merge-queue touch: the #224 row took that hand-off, and the two
# faults are independent. A result that could not be recorded says nothing about
# whether the merge enqueue worked.
grep -q 'merge-queue' "$T/ssh.txt" \
  && bad "(a) must not touch the merge queue when the merge ROW succeeded" || ok

# (a2) BOTH failed — the result is missing AND the merge row did not take. Then
# both go, and the alert names the result fault, which is the bigger one.
rm -f "$T/h/flags"/alerted-pool-relay-* "$T/h/logs/ALERTS.log"
reap 0 0 1
grep -q 'remote-results' "$T/ssh.txt" && ok || bad "(a2) must push the result"
grep -q 'merge-queue' "$T/ssh.txt"    && ok || bad "(a2) must ALSO touch the merge queue"
grep -q 'NO RESULT ROW' "$T/h/logs/ALERTS.log" \
  && ok || bad "(a2) must report the result fault, the one that loses a close-out"

# (b) THE FEED COULD NOT BE READ -> HELD, not pushed, and a DIFFERENT message.
# TEST-CHANGE (BH-1041): this case asserted the REVERSE — "(b) must push the
# json" / "must push the artifacts". Pushing on an unknown is the defect the
# ticket fixes: the row usually IS there, the box then stages the build from
# both doors, and a client's ticket gets two close-out comments. Unknown is
# still not absent, so the message stays distinct from NO RESULT ROW; what
# changed is that nothing travels until the ledger answers.
rm -f "$T/h/flags"/alerted-pool-relay-* "$T/h/logs/ALERTS.log"
reap 1 1
grep -q 'LEDGER UNREADABLE' "$T/h/logs/ALERTS.log" \
  && ok || bad "an unreadable ledger must say so: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
grep -q 'NO RESULT ROW' "$T/h/logs/ALERTS.log" \
  && bad "an unreadable ledger must NOT be reported as a missing row" || ok
grep -q 'remote-results' "$T/ssh.txt" \
  && bad "(b) must NOT push the json on an unknown: $(cat "$T/ssh.txt")" || ok
grep -q 'builds/' "$T/ssh.txt" \
  && bad "(b) must NOT push the artifacts on an unknown" || ok
ls -d "$T/h/builds/pool-project-3-TK-9-"*/RELAY_DEFERRED >/dev/null 2>&1 \
  && ok || bad "(b) must park the result with a RELAY_DEFERRED marker for the retry"
[ -z "$(relayed)" ] \
  && ok || bad "(b) nothing was delivered, so custody may NOT be stamped RELAYED"
[ -f "$T/h/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "(b) the hub json is the only other copy — it must be kept"

# (c) THE RESULT ROW IS THERE AND ONLY THE MERGE ROW FAILED -> the result is
# already travelling, so re-pushing it would duplicate work in flight. ONLY the
# merge-queue touch goes.
rm -f "$T/h/flags"/alerted-pool-relay-* "$T/h/logs/ALERTS.log"
reap 1 0 1
grep -q 'MERGE-QUEUE ROW FAILED' "$T/h/logs/ALERTS.log" \
  && ok || bad "a failed merge row must say so: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
grep -q 'merge-queue' "$T/ssh.txt" \
  && ok || bad "(c) must send the merge-queue touch: $(cat "$T/ssh.txt")"
grep -q 'remote-results' "$T/ssh.txt" \
  && bad "(c) must NOT re-push the result — it is in the ledger and already travelling" || ok
grep -q 'builds/' "$T/ssh.txt" \
  && bad "(c) must NOT re-push the artifacts" || ok
[ -f "$T/h/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "(c) keeps the hub json, exactly as the row path does"
[ -n "$(relayed)" ] && ok || bad "(c) still marks custody"

# ══ 3. THE PER-DAY DEDUPE IS PER REASON ════════════════════════════════════
# A merge-row failure must not silence a dead ledger, or the other way round:
# they are different outages and the second one would go unseen all day.
rm -f "$T/h/flags"/alerted-pool-relay-* "$T/h/logs/ALERTS.log"
reap 0            # no result row
reap 0            # again, same day
N=$(grep -c 'NO RESULT ROW' "$T/h/logs/ALERTS.log" 2>/dev/null | head -1)
[ "$N" = 1 ] && ok || bad "the same reason must page once a day, got $N"
reap 1 0 1        # a DIFFERENT reason, same day
N=$(grep -c 'MERGE-QUEUE ROW FAILED' "$T/h/logs/ALERTS.log" 2>/dev/null | head -1)
[ "$N" = 1 ] && ok || bad "a different reason must page on its own flag, got $N"
ls "$T/h/flags"/alerted-pool-relay-noresultrow-project-3-* >/dev/null 2>&1 \
  && ok || bad "the dedupe flag must carry the reason"
ls "$T/h/flags"/alerted-pool-relay-mergerow-project-3-* >/dev/null 2>&1 \
  && ok || bad "each reason needs its own dated flag"

# ══ 4. NO SECRETS ═══════════════════════════════════════════════════════════
grep -rq test-secret "$T/h/logs" 2>/dev/null && bad "HARNESS_SECRET leaked into a log" || ok

echo "pool-relay-rowfirst-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
