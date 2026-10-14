#!/bin/bash
# tests/pipeline-health-dispatch.bh-5941-test.sh — bin/pipeline-health.sh on the
# per-project runner (BH-5941): `--dispatch` starts one detached
# `pipeline-health.sh --project <p>` per project (bin/lib/project-lanes.sh) and
# then runs the fleet sections under locks/pipeline-health.lock. A project run
# runs only the per-project sections, on locks/pipeline-health-<p>.lock.
#
# Drives the REAL script against a scratch tree (tests/lib/ph-sections-fixture.sh)
# with projects pa and pb. The stub bin/queued-fly-relayed.sh (check 4 forks it
# once per uncommented dir) records "<project> <pid>" to qfr.<project>. On a
# project's first call it blocks while hold.<project> exists, 30 s at most. So a hold keeps one
# project's run alive on purpose, and qfr.<project> counts how many runs of that
# project reached check 4.
#   AT-1a  two overlapping dispatches never run one project twice
#   AT-1b  a hand run of a project whose dispatched run is live exits 0
#   AT-1c  --project of an unknown or unsafe name exits 2
#   AT-1d  a no-arg run still runs when a sections run holds the fleet lock
#          (main's rule), and skips when another full run holds the full lock
#   AT-1e  no bin/lib/project-lanes.sh: the dispatcher runs every section itself
#   AT-1f  --dispatch with --project is refused; a junk spread falls back to 540
#   AT-1g  the header, the note and the verification entry name the skip line
#          the code writes for a full run (lead review lr-5990 at 420d69827)
#   AT-3a  pa with 600 candidates does not delay pb
#   AT-3b  a held fleet lock stops neither the project runs nor the fleet part
#   AT-3c  each run retracts only the keys it owns
#   AT-3d  two project runs finishing together keep both keys and stamps
#   AT-3e  the fleet part of --dispatch runs a fleet section (hung machine)
#          and keeps an active hungmachine: key that still holds
# Every wait is bounded and polls a file; none is a fixed sleep.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-dispatch.bh-5941-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/ph-sections-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null && command -v flock >/dev/null \
  && command -v setsid >/dev/null || { echo "jq/python3/flock/setsid missing — skipping"; exit 0; }

NOW=$(date +%s)
mk() { # mk <dir> — the fixture tree, two projects, the runner and the qfr stub
  local d="$1"; phs_mktree "$d"
  printf 'pa\to/pa\npb\to/pb\n' > "$d/fleet.conf"
  mkdir -p "$d/builds"
  ln -sf "$DIR/bin/project-lane-run.sh" "$d/bin/project-lane-run.sh"
  ln -sf "$DIR/bin/lib/project-lanes.sh" "$d/bin/lib/project-lanes.sh"
  ln -sf "$DIR/bin/lib/closeout-terminal.sh" "$d/bin/lib/closeout-terminal.sh"
  cat > "$d/bin/queued-fly-relayed.sh" <<'QFR'
#!/bin/bash
echo "$1 $$" >> "$HARNESS/qfr.$1"
# Only a project's FIRST call blocks, so a hold costs one wait, not one per dir.
[ "$(grep -c . "$HARNESS/qfr.$1")" -le 1 ] || exit 1
n=0
while [ -f "$HARNESS/hold.$1" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
exit 1
QFR
  chmod +x "$d/bin/queued-fly-relayed.sh"
}
seed() { # seed <dir> <project> <count> — uncommented 2h-old build dirs
  local d="$1" p="$2" c="$3" i
  for i in $(seq 1 "$c"); do
    mkdir -p "$d/builds/$p-X-$i-202610100000"
    printf 'PR_CREATED https://github.com/o/%s/pull/%s\n' "$p" "$i" > "$d/builds/$p-X-$i-202610100000/RESULT"
  done
  touch -d "@$(( NOW - 7200 ))" "$d"/builds/"$p"-X-*/RESULT
}
ph() { # ph <dir> [args...] — one REAL run; RC is its exit code
  local d="$1"; shift
  ( export HARNESS="$d"; phs_env; export PH_DISPATCH_SPREAD_SECS="${SPREAD:-0}"
    "$d/bin/pipeline-health.sh" "$@" ) >"$d/out.txt" 2>"$d/err.txt"
  RC=$?
}
lines() { [ -s "$1" ] && grep -c . "$1" || echo 0; }
cnt() { grep -cF -- "$2" "$1" 2>/dev/null || true; }
wait_for() { # wait_for <tenths> <cmd...> — poll until cmd succeeds, bounded
  local n=0 max="$1"; shift
  until "$@"; do n=$((n + 1)); [ "$n" -ge "$max" ] && return 1; sleep 0.1; done
  return 0
}
qfr_is() { [ "$(lines "$1/qfr.$2")" = "$3" ]; }
done_is() { [ "$(cnt "$1/logs/pipeline-health.log" "pipeline-health project $2: run done")" -ge "$3" ]; }
has() { grep -qxF "$2" "$1/state/health-active.txt"; }
stamp_ok() { [ "$(jq -r .n "$1/state/health-active.stamp" 2>/dev/null)" = "$(wc -l < "$1/state/health-active.txt")" ]; }

echo "--- AT-1a: two overlapping dispatches never run one project twice"
D="$T/a1"; mk "$D"; seed "$D" pa 1; seed "$D" pb 1
touch "$D/hold.pa" "$D/hold.pb"
ph "$D" --dispatch; R1=$RC
ph "$D" --dispatch; R2=$RC
[ "$R1" = 0 ] && [ "$R2" = 0 ] && ok || bad "AT-1a: dispatch rc $R1/$R2, err=$(cat "$D/err.txt")"
wait_for 300 qfr_is "$D" pa 1 && wait_for 300 qfr_is "$D" pb 1 \
  && ok || bad "AT-1a: the held runs never reached check 4: pa=$(lines "$D/qfr.pa") pb=$(lines "$D/qfr.pb") cron=$(cat "$D/logs/pipeline-health-cron.log" 2>/dev/null)"
wait_for 300 grep -qs 'a run of pb is still live' "$D/logs/pipeline-health-cron.log"
[ "$(cnt "$D/logs/pipeline-health-cron.log" 'a run of pa is still live')" = 1 ] \
  && [ "$(cnt "$D/logs/pipeline-health-cron.log" 'a run of pb is still live')" = 1 ] \
  && ok || bad "AT-1a: want one 'still live' line per project: $(cat "$D/logs/pipeline-health-cron.log" 2>/dev/null)"
qfr_is "$D" pa 1 && qfr_is "$D" pb 1 && ok || bad "AT-1a: a project ran twice: pa=$(lines "$D/qfr.pa") pb=$(lines "$D/qfr.pb")"

echo "--- AT-1b: a hand run while the dispatched run is live"
ph "$D" --project pa
[ "$RC" = 0 ] && ok || bad "AT-1b: rc=$RC, want 0"
grep -q 'pipeline-health: a run of pa is still live (locks/pipeline-health-pa.lock held)' "$D/out.txt" \
  && ok || bad "AT-1b: no 'still live' line on stdout: $(cat "$D/out.txt")"
qfr_is "$D" pa 1 && ok || bad "AT-1b: the hand run reached check 4: qfr.pa=$(lines "$D/qfr.pa")"

echo "--- AT-3d: two project runs finish together"
rm -f "$D/hold.pa" "$D/hold.pb"
wait_for 600 done_is "$D" pa 1 && wait_for 600 done_is "$D" pb 1 \
  && ok || bad "AT-3d: the runs never finished: $(grep 'run done' "$D/logs/pipeline-health.log")"
qfr_is "$D" pa 1 && qfr_is "$D" pb 1 && ok || bad "AT-1a: a project ran twice after the holds: pa=$(lines "$D/qfr.pa") pb=$(lines "$D/qfr.pb")"
has "$D" uncommented:pa:1 && has "$D" uncommented:pb:1 \
  && ok || bad "AT-3d: one run lost the other's key: $(cat "$D/state/health-active.txt")"
jq -e '.["uncommented:pa:1"] > 0 and .["uncommented:pb:1"] > 0' "$D/state/health-alerted.json" >/dev/null 2>&1 \
  && ok || bad "AT-3d: health-alerted.json is broken or lost a stamp: $(cat "$D/state/health-alerted.json")"
stamp_ok "$D" && ok || bad "AT-3d: stamp n does not match ACTIVE"

echo "--- AT-1c: --project of an unknown or unsafe name"
D="$T/c1"; mk "$D"
ph "$D" --project nosuch
[ "$RC" = 2 ] && ok || bad "AT-1c: --project nosuch rc=$RC, want 2"
[ "$(cnt "$D/logs/pipeline-health.log" "nosuch")" = 1 ] && ok || bad "AT-1c: want one log line naming nosuch: $(cat "$D/logs/pipeline-health.log" 2>/dev/null)"
ph "$D" --project ../x
[ "$RC" = 2 ] && ok || bad "AT-1c: --project ../x rc=$RC, want 2"
[ ! -e "$D/state/health-active.stamp" ] && ok || bad "AT-1c: a refused run still ran the epilogue"

echo "--- AT-1f: exclusive flags, and a junk spread"
ph "$D" --dispatch --project pa
[ "$RC" = 2 ] && ok || bad "AT-1f: --dispatch --project rc=$RC, want 2"
grep -q 'exclusive' "$D/err.txt" && ok || bad "AT-1f: no stderr line for the flag clash: $(cat "$D/err.txt")"
D="$T/f1"; mk "$D"; : > "$D/fleet.conf"
SPREAD=abc ph "$D" --dispatch
[ "$RC" = 0 ] && ok || bad "AT-1f: junk spread rc=$RC"
grep -q "PH_DISPATCH_SPREAD_SECS='abc' is not a whole number — using 540" "$D/logs/pipeline-health.log" \
  && ok || bad "AT-1f: no fallback line for a junk spread: $(cat "$D/logs/pipeline-health.log")"

echo "--- AT-1g: the docs name the full-run skip line the code writes"
FL='full run skipped, another full run is in flight'
for f in bin/pipeline-health.sh docs/notes/2026-10-11-BH-5941-pipeline-health-per-project.md docs/verification-map/entries/BH-5941.md; do
  grep -qF "$FL" "$DIR/$f" && ok || bad "AT-1g: $f does not name '$FL'"
  # A bare "run skipped, a run is in flight" is the line no code path writes now.
  STALE=$(grep -E 'run skipped, a run is in flight' "$DIR/$f" | grep -vE '(full|sections) run skipped' || true)
  [ -z "$STALE" ] && ok || bad "AT-1g: $f still names the removed line 'run skipped, a run is in flight': $STALE"
done

echo "--- AT-1d: a held fleet lock (a sections run) does not skip a no-arg run; a held full lock does"
D="$T/d1"; mk "$D"; seed "$D" pb 1
exec 8>"$D/locks/pipeline-health.lock"; flock -n 8 || bad "AT-1d setup: could not take the lock"
ph "$D"
exec 8>&-
[ "$RC" = 0 ] && ok || bad "AT-1d: rc=$RC, want 0"
grep -q 'run skipped' "$D/logs/pipeline-health.log" 2>/dev/null \
  && bad "AT-1d: a sections run's lock skipped the full run: $(cat "$D/logs/pipeline-health.log")" || ok
[ "$(lines "$D/qfr.pb")" = 1 ] && ok || bad "AT-1d: the full run did not reach check 4 under a held fleet lock"
D="$T/d1b"; mk "$D"; seed "$D" pb 1
printf 'uncommented:pa:9\n' > "$D/state/health-active.txt"
cp "$D/state/health-active.txt" "$D/active.before"
exec 8>"$D/locks/pipeline-health-full.lock"; flock -n 8 || bad "AT-1d setup: could not take the full lock"
ph "$D"
exec 8>&-
[ "$RC" = 0 ] && ok || bad "AT-1d: rc=$RC under a held full lock, want 0"
grep -q 'full run skipped, another full run is in flight' "$D/logs/pipeline-health.log" \
  && ok || bad "AT-1d: no 'full run skipped' line: $(cat "$D/logs/pipeline-health.log" 2>/dev/null)"
cmp -s "$D/active.before" "$D/state/health-active.txt" && ok || bad "AT-1d: ACTIVE changed under a held full lock: $(cat "$D/state/health-active.txt")"
[ "$(lines "$D/qfr.pb")" = 0 ] && ok || bad "AT-1d: the skipped full run still ran check 4"

echo "--- AT-3a: pa with 600 candidates does not delay pb"
D="$T/a3"; mk "$D"; seed "$D" pa 600; seed "$D" pb 1
touch "$D/hold.pa"
ph "$D" --dispatch
[ "$RC" = 0 ] && ok || bad "AT-3a: dispatch rc=$RC err=$(cat "$D/err.txt")"
done_is "$D" pa 1 && bad "AT-3a: pa finished before the dispatcher returned" || ok
grep -q 'pipeline-health dispatch: started 2 project run(s)' "$D/logs/pipeline-health.log" \
  && ok || bad "AT-3a: no dispatch summary line: $(cat "$D/logs/pipeline-health.log")"
wait_for 600 done_is "$D" pb 1 && ok || bad "AT-3a: pb never finished: $(cat "$D/logs/pipeline-health-cron.log" 2>/dev/null)"
[ -f "$D/hold.pa" ] && ! done_is "$D" pa 1 && ok || bad "AT-3a: pa was not still held when pb finished"
has "$D" uncommented:pb:1 && ok || bad "AT-3a: pb's key is not in ACTIVE while pa is held: $(cat "$D/state/health-active.txt")"
rm -f "$D/hold.pa"
wait_for 1200 done_is "$D" pa 1 && ok || bad "AT-3a: pa never finished"
has "$D" uncommented:pa:600 && has "$D" uncommented:pb:1 && ok || bad "AT-3a: keys after both runs: $(cat "$D/state/health-active.txt")"

echo "--- AT-3b: a held fleet lock stops neither the project runs nor the fleet part"
D="$T/b3"; mk "$D"; seed "$D" pa 1; seed "$D" pb 1
exec 8>"$D/locks/pipeline-health.lock"; flock -n 8 || bad "AT-3b setup: could not take the lock"
ph "$D" --dispatch
[ "$RC" = 0 ] && ok || bad "AT-3b: rc=$RC"
wait_for 600 done_is "$D" pb 1 && wait_for 600 done_is "$D" pa 1 \
  && ok || bad "AT-3b: the project runs did not finish under a held fleet lock: $(cat "$D/logs/pipeline-health-cron.log" 2>/dev/null)"
exec 8>&-
[ "$(cnt "$D/logs/pipeline-health.log" 'run skipped')" = 0 ] \
  && ok || bad "AT-3b: a held fleet lock (a sections run) must not skip the fleet part: $(cat "$D/logs/pipeline-health.log")"
has "$D" uncommented:pb:1 && ok || bad "AT-3b: pb's key is missing: $(cat "$D/state/health-active.txt")"

echo "--- AT-3c: each run retracts only the keys it owns"
D="$T/c3"; mk "$D"
printf 'hubsyncstall:hub\nuncommented:gone:1\nuncommented:pa:3\nuncommented:pb:2\n' > "$D/state/health-active.txt"
ph "$D" --project pa
[ "$RC" = 0 ] && ok || bad "AT-3c: --project pa rc=$RC err=$(cat "$D/err.txt")"
[ "$(cnt "$D/logs/pipeline-health.log" 'RESOLVED')" = 1 ] && grep -q 'RESOLVED uncommented:pa:3' "$D/logs/pipeline-health.log" \
  && ok || bad "AT-3c: the pa run must resolve only uncommented:pa:3: $(grep RESOLVED "$D/logs/pipeline-health.log")"
has "$D" hubsyncstall:hub && has "$D" uncommented:gone:1 && has "$D" uncommented:pb:2 \
  && ok || bad "AT-3c: the pa run dropped a key it does not own: $(cat "$D/state/health-active.txt")"
has "$D" uncommented:pa:3 && bad "AT-3c: uncommented:pa:3 is still active" || ok
stamp_ok "$D" && ok || bad "AT-3c: stamp n does not match ACTIVE after the pa run"
# The fleet part next. Both project runs are held in check 4, so only the
# fleet part can touch ACTIVE until the holds go.
seed "$D" pa 1; seed "$D" pb 1; touch "$D/hold.pa" "$D/hold.pb"
ph "$D" --dispatch
grep -q 'RESOLVED uncommented:gone:1' "$D/logs/pipeline-health.log" \
  && ok || bad "AT-3c: the fleet part did not retract the removed project's key: $(grep RESOLVED "$D/logs/pipeline-health.log")"
has "$D" uncommented:pb:2 && ok || bad "AT-3c: the fleet part dropped pb's key: $(cat "$D/state/health-active.txt")"
grep -q 'RESOLVED uncommented:pb:2' "$D/logs/pipeline-health.log" && bad "AT-3c: the fleet part retracted pb's key" || ok
stamp_ok "$D" && ok || bad "AT-3c: stamp n does not match ACTIVE after the fleet part"
rm -f "$D/hold.pa" "$D/hold.pb"
wait_for 600 done_is "$D" pa 2 && wait_for 600 done_is "$D" pb 1 || bad "AT-3c: the held runs never finished"

echo "--- AT-3e: --dispatch runs the fleet sections (hung machine liveness)"
D="$T/e3"; mk "$D"; : > "$D/fleet.conf"
# Two machines spawned 4h ago (> 3.5h) and never reaped. One key is already
# active, so a fleet part that skips the section would post RESOLVED for it.
# No flags/fly-pool-app-<p>, so the liveness probe never runs flyctl.
printf '%s [pool/pa] spawned 0123456789abcd for pa X-1\n%s [pool/pa] spawned 00112233445566 for pa X-2\n' \
  "$(date -u -d "@$(( NOW - 14400 ))" '+%Y-%m-%d %H:%M:%SZ')" "$(date -u -d "@$(( NOW - 14400 ))" '+%Y-%m-%d %H:%M:%SZ')" \
  > "$D/logs/fly-pool.log"
printf '#!/bin/bash\necho started\n' > "$D/bin/fly-machine-state.sh"; chmod +x "$D/bin/fly-machine-state.sh"
printf 'hungmachine:00112233445566\n' > "$D/state/health-active.txt"
ph "$D" --dispatch
[ "$RC" = 0 ] && ok || bad "AT-3e: rc=$RC err=$(cat "$D/err.txt")"
has "$D" hungmachine:0123456789abcd && ok || bad "AT-3e: the fleet part did not fire hungmachine:0123456789abcd: $(cat "$D/state/health-active.txt")"
has "$D" hungmachine:00112233445566 && ok || bad "AT-3e: the fleet part dropped a live hungmachine key: $(cat "$D/state/health-active.txt")"
grep -q 'RESOLVED hungmachine:' "$D/logs/pipeline-health.log" \
  && bad "AT-3e: the fleet part posted a false RESOLVED: $(grep RESOLVED "$D/logs/pipeline-health.log")" || ok
stamp_ok "$D" && ok || bad "AT-3e: stamp n does not match ACTIVE"

echo "--- AT-1e: no project-lanes.sh — the dispatcher runs every section"
D="$T/e1"; mk "$D"; seed "$D" pb 1
rm -f "$D/bin/lib/project-lanes.sh"
ph "$D" --dispatch
[ "$RC" = 0 ] && ok || bad "AT-1e: rc=$RC"
grep -q 'project-lanes.sh not loaded — this tick runs every section in one process' "$D/logs/pipeline-health.log" \
  && ok || bad "AT-1e: no fail-open line: $(cat "$D/logs/pipeline-health.log")"
has "$D" uncommented:pb:1 && ok || bad "AT-1e: the fail-open run did not fire uncommented:pb:1: $(cat "$D/state/health-active.txt")"

echo "pipeline-health-dispatch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
