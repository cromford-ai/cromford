#!/bin/bash
# tests/merge-sweep-reopen.bh-1601-test.sh — BH-1601: bin/merge-sweep.sh must
# permanently remember MERGED only. A settled CLOSED PR is logged and re-read
# live next pass, so a PR that is closed and later REOPENED with green CI gets
# swept and merged instead of being hidden by sweep_seen for ever.
#
# The real sweep is copied into a scratch tree and run whole (D2), as in
# tests/merge-sweep-identity.bh-800-test.sh.
# Run from anywhere: tests/merge-sweep-reopen.bh-1601-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/fakebin" "$T/env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

cp "$DIR/bin/merge-sweep.sh" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$T/bin/lib/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/" 2>/dev/null || true
cp "$DIR/bin/lib/gh-push-identity.sh" "$T/bin/lib/" 2>/dev/null || true
for stub in notify.sh heartbeat.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$stub"; chmod +x "$T/bin/$stub"; done
printf '#!/bin/bash\nexit 2\n' > "$T/bin/pre-arm-guards.sh"; chmod +x "$T/bin/pre-arm-guards.sh"
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 ${2:-}" in
  "--projects ") echo ts ;;
  "ts repo") echo "o/r" ;;
  "ts board_prefix") echo "/api/board" ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"

# $T/prstate is what GitHub says about pull/7 right now: OPEN, CLOSED or MERGED.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
PST=$(cat "$T/prstate")
case "$*" in
  "api repos/o/r -q .id") exit 0 ;;
  "api user -q .login")   echo operator; exit 0 ;;
  *"api -i -X GET repos/o/r/pulls/"*"v3.diff"*) restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/o/r/pulls/"*) restpr "$PST" headsha ticket/x main "" MERGEABLE CLEAN operator ;;
  *"--json state,isInMergeQueue"*) echo "$PST false" ;;
  *"--json state -q .state"*) echo "$PST" ;;
  *"pr diff"*) echo "+ const x = 1;" ;;
  *"--json mergeCommit"*) echo "" ;;
  *"pr merge"*) echo merged >> "$MERGE_SINK"; echo MERGED > "$T/prstate"; exit 0 ;;
  *"actions/runs"*) printf 'completed|success\n' ;;
  *) echo "" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
# The jobs worker: a ledger GET answers $T/ledger (a status word) when present,
# 404 otherwise; every other call is a 404.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
case "$*" in
  *"/api/ledger?"*) if [ -s "$T/ledger" ]; then printf '{"ledger":{"status":"%s"}}\n200\n' "$(cat "$T/ledger")"; exit 0; fi ;;
esac
printf '{}\n404\n'
SH
chmod +x "$T/fakebin/curl"

PR=https://github.com/o/r/pull/7
setup() {
  rm -rf "$T/builds"
  REC="$T/builds/pool-ts-TK-807-202609180007"; mkdir -p "$REC"
  echo "PR_CREATED $PR" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  : > "$REC/pipeline.log"
  : > "$T/state/merge-sweep-done.txt"; : > "$T/logs/merge-sweep.log"; : > "$T/logs/ALERTS.log"
  : > "$T/merges.txt"; : > "$T/gh.txt"; rm -f "$T/ledger"
}
sweep() {
  ( export PATH="$T/fakebin:$T/bin:$PATH" HARNESS="$T" T="$T" HARNESS_SECRET=s JOBS_URL=https://jobs.invalid JOBS_BOX=b \
           MERGE_SINK="$T/merges.txt" GH_SINK="$T/gh.txt"
    unset GH_TOKEN
    bash "$T/bin/sweep.sh" >/dev/null 2>"$T/err.txt" )
}
merges() { grep -c merged "$T/merges.txt" 2>/dev/null || true; }
done_rows() { grep -cxF "$PR" "$T/state/merge-sweep-done.txt" 2>/dev/null || true; }

# (1) closed -> not recorded -> reopened green -> merged and recorded next tick.
setup; echo CLOSED > "$T/prstate"
sweep
[ "$(done_rows)" = 0 ] && ok || bad "1: a settled CLOSED PR must not be written to merge-sweep-done.txt"
[ "$(merges)" = 0 ] && ok || bad "1: a CLOSED PR must not merge"
echo OPEN > "$T/prstate"; : > "$T/gh.txt"
sweep
grep -q "pulls/7" "$T/gh.txt" && ok || bad "1: pass 2 must re-read the reopened PR live"
[ "$(merges)" = 1 ] && ok || bad "1: a reopened green PR must merge on the next tick (merges=$(merges); log: $(tail -2 "$T/logs/merge-sweep.log"))"
[ "$(done_rows)" = 1 ] && ok || bad "1: the merge must be recorded"

# (2) stays closed -> no merge, no done row, still re-read every pass.
setup; echo CLOSED > "$T/prstate"
sweep; : > "$T/gh.txt"; sweep
grep -q "pulls/7" "$T/gh.txt" && ok || bad "2: a CLOSED PR is re-read live on the next pass"
[ "$(merges)" = 0 ] && ok || bad "2: a PR that stays CLOSED never merges"
[ "$(done_rows)" = 0 ] && ok || bad "2: a PR that stays CLOSED is never written to merge-sweep-done.txt"

# (3) a legacy ledger row with status closed does not suppress a re-read.
setup; echo closed > "$T/ledger"; echo OPEN > "$T/prstate"
sweep
grep -q "pulls/7" "$T/gh.txt" && ok || bad "3: a ledger row 'closed' must not hide the PR"
[ "$(merges)" = 1 ] && ok || bad "3: the reopened PR behind a closed ledger row merges"
# ...while a ledger row 'merged' still does.
setup; echo merged > "$T/ledger"; echo OPEN > "$T/prstate"
sweep
grep -q "pulls/7" "$T/gh.txt" && bad "3: a ledger row 'merged' must still suppress the read" || ok

# (4) MERGED is recorded exactly once, and stays remembered.
setup; echo MERGED > "$T/prstate"
sweep; : > "$T/gh.txt"; sweep
[ "$(done_rows)" = 1 ] && ok || bad "4: a MERGED PR is recorded exactly once (rows=$(done_rows))"
grep -q "pulls/7" "$T/gh.txt" && bad "4: a recorded MERGED PR must not be re-read" || ok

echo "merge-sweep-reopen.bh-1601: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
