#!/bin/bash
# tests/dequeue-watch-stub.bh-3719-test.sh — BH-3726 (BH-3719.0): the
# dequeue-watch contract slice: the lane's gates and switch, and every dqw_*
# jobs-client verb answering the fail-closed way (rc 1, nothing on stdout) with
# no worker. BH-3730 replaced the stub body with the real tick, so S4 and S7
# now pin the tick's empty case and the hub cron line; the tick itself is
# tests/dequeue-watch.bh-3719-test.sh.
#
#   S1 flags/dequeue-watch-off -> one log line ending ` off`, rc 0
#   S2 DEQUEUE_WATCH=0         -> ` disabled`
#   S3 the REAL bin/jobs-client.sh defines exactly the 8 dqw_* verbs, and each
#      returns rc 1 with an empty stdout
#   S4 default, no fleet.conf project -> one ` tick projects=0 …` line, and no
#      gh call in S1-S4
#   S5 flags/all-off           -> rc 0 and no log line (the gate runs first)
#   S7 bin/render-cron.sh hub renders rc 0 with exactly one dequeue-watch.sh line
#   S6 the model_routes seeds for dequeue.classify / stage.dequeue-classify,
#      loaded from the REAL worker/jobs/schema.sql into node:sqlite
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/dequeue-watch-stub.bh-3719-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LANE_SRC="$DIR/bin/dequeue-watch.sh"
MOD_SRC="$DIR/bin/lib/jobs/dequeue-watch.sh"
for f in "$LANE_SRC" "$MOD_SRC"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "dequeue-watch-stub: 0 passed, 1 failed"; exit 1; }
done

H="$T/h"
mkdir -p "$H" "$T/shim"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
printf '#!/bin/bash\necho "gh $*" >> "%s/gh.calls"\nexit 1\n' "$T" > "$T/shim/gh"
chmod +x "$T/shim/gh"
LOG="$H/logs/dequeue-watch.log"

# run_lane [VAR=val...] — the shipped entry, from the scratch harness, with a
# clean environment and no worker (JOBS_URL empty), so lane_switch reads the file.
run_lane() {
  env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL= HARNESS_TEST_SANDBOX=1 "$@" \
    bash "$H/bin/dequeue-watch.sh" > "$T/lane.out" 2> "$T/lane.err"
}
lines() { if [ -f "$LOG" ]; then wc -l < "$LOG"; else echo 0; fi; }
last()  { tail -n 1 "$LOG" 2>/dev/null; }

# S1 — the reader switch wins over the knob, and writes exactly one ` off` line.
mkdir -p "$H/flags"
touch "$H/flags/dequeue-watch-off"
b=$(lines)
run_lane DEQUEUE_WATCH=0; rc=$?
[ "$rc" = 0 ] && ok || bad "S1 $DIR/bin/dequeue-watch.sh with flags/dequeue-watch-off exited $rc"
[ "$(( $(lines) - b ))" = 1 ] && ok || bad "S1 expected exactly one log line, got $(( $(lines) - b ))"
if last | grep -Eq '^[0-9T:Z-]+ off$'; then ok; else bad "S1 last log line is '$(last)', wanted '<ts> off'"; fi
[ -s "$T/lane.out" ] && bad "S1 the stub wrote to stdout: $(cat "$T/lane.out")" || ok
rm -f "$H/flags/dequeue-watch-off"

# S2 — DEQUEUE_WATCH=0.
run_lane DEQUEUE_WATCH=0; rc=$?
[ "$rc" = 0 ] && ok || bad "S2 $DIR/bin/dequeue-watch.sh DEQUEUE_WATCH=0 exited $rc"
if last | grep -Eq '^[0-9T:Z-]+ disabled$'; then ok; else bad "S2 last log line is '$(last)', wanted '<ts> disabled'"; fi

# S4 — a default tick with no project is one ` tick projects=0` line, and no
# call reached gh in S1-S4.
b=$(lines)
run_lane; rc=$?
[ "$rc" = 0 ] && ok || bad "S4 $DIR/bin/dequeue-watch.sh default exited $rc"
[ "$(( $(lines) - b ))" = 1 ] && ok || bad "S4 expected exactly one log line, got $(( $(lines) - b ))"
if last | grep -Eq '^[0-9T:Z-]+ tick projects=0 '; then ok; else bad "S4 last log line is '$(last)', wanted '<ts> tick projects=0 …'"; fi
[ -e "$T/gh.calls" ] && bad "S4 the lane called gh with no project: $(cat "$T/gh.calls")" || ok

# S5 — the fleet master switch stops the lane before the switch and the body.
touch "$H/flags/all-off"
b=$(lines)
run_lane; rc=$?
[ "$rc" = 0 ] && ok || bad "S5 $DIR/bin/dequeue-watch.sh under flags/all-off exited $rc"
[ "$(lines)" = "$b" ] && ok || bad "S5 the lane wrote a log line under all-off: $(last)"
rm -f "$H/flags/all-off"

# S3 — the 8 verbs, through the REAL jobs-client (which sources $DIR/bin/lib/jobs/dequeue-watch.sh).
VERBS="dqw_event_record dqw_event_state dqw_events_list dqw_action_claim dqw_action_set dqw_actions_list dqw_rounds_count dqw_summary"
env -i PATH="$PATH" HOME="$T" HARNESS="$H" JOBS_URL= T="$T" VERBS="$VERBS" bash -c '
  . "$HARNESS/bin/jobs-client.sh" || { echo "source-failed"; exit 0; }
  head=0123456789abcdef0123456789abcdef01234567
  for v in $VERBS; do
    if ! declare -F "$v" >/dev/null; then echo "$v undefined"; continue; fi
    case "$v" in
      dqw_event_record) args=(o/r 12 "$head" 99 p "{}") ;;
      dqw_event_state)  args=(o/r 12 "$head" 99 "{\"class\":\"flake\"}") ;;
      dqw_events_list)  args=(o/r 12 2026-09-30T00:00:00Z fp) ;;
      dqw_action_claim) args=(o/r 12 "$head" flake requeue p) ;;
      dqw_action_set)   args=(o/r 12 "$head" flake done ref note requeue) ;;
      dqw_actions_list) args=(o/r 12 "$head" flake requeue claimed) ;;
      dqw_rounds_count) args=(o/r 12 flake) ;;
      dqw_summary)      args=(2026-09-30T00:00:00Z) ;;
    esac
    "$v" "${args[@]}" > "$T/out.$v"; echo "$v rc=$? bytes=$(wc -c < "$T/out.$v")"
  done
  echo "count=$(declare -F | grep -c " dqw_")"
' > "$T/s3.txt" 2>&1
for v in $VERBS; do
  if grep -qx "$v rc=1 bytes=0" "$T/s3.txt"; then ok
  else bad "S3 $v via $DIR/bin/jobs-client.sh: $(grep "^$v " "$T/s3.txt" || echo 'no answer') (want rc=1 bytes=0)"; fi
done
grep -qx "count=8" "$T/s3.txt" && ok || bad "S3 wanted exactly 8 dqw_ functions: $(grep '^count=\|source-failed' "$T/s3.txt")"

# S7 — the hub runs it: the hub render succeeds and carries exactly one dequeue-watch.sh line.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" hub > "$T/hub.cron" 2> "$T/hub.err"; rc=$?
[ "$rc" = 0 ] && ok || bad "S7 bin/render-cron.sh hub exited $rc: $(cat "$T/hub.err")"
[ "$(grep -c 'dequeue-watch\.sh' "$T/hub.cron")" = 1 ] && ok || bad "S7 the hub crontab carries $(grep -c 'dequeue-watch\.sh' "$T/hub.cron") dequeue-watch.sh lines, wanted 1"

# S6 — the seeds.
if ! node -e 'require("node:sqlite")' 2>/dev/null; then
  echo "SKIP: S6 node:sqlite is not available"
else
  node -e '
const { DatabaseSync } = require("node:sqlite");
const sql = require("fs").readFileSync(process.argv[1], "utf8");
const q = (db, role) => db.prepare("SELECT position, runner, model FROM model_routes WHERE project IS NULL AND role = ? ORDER BY position").all(role);
const db = new DatabaseSync(":memory:");
db.exec(sql);
for (const [role, src] of [["dequeue.classify", "lookback.cluster"], ["stage.dequeue-classify", "stage.execute"]]) {
  const rows = q(db, role), s = q(db, src)[0];
  console.log(`${role} n=${rows.length} pos=${rows[0]?.position} runner=${rows[0]?.runner} same=${!!s && rows[0]?.model === s.model}`);
}
// Tombstone: a fresh DB whose model_route_changes already names dequeue.classify.
const cut = sql.indexOf("-- ── BH-3719.0 (BH-3726)");
if (cut < 0) { console.log("block-missing"); process.exit(0); }
const db2 = new DatabaseSync(":memory:");
db2.exec(sql.slice(0, cut));
db2.exec("INSERT INTO model_route_changes (scope, project, role, position, actor, at) VALUES (\x27hub\x27, NULL, \x27dequeue.classify\x27, 0, \x27t\x27, \x272026-09-30T00:00:00Z\x27)");
db2.exec(sql.slice(cut));
console.log(`tombstoned n=${q(db2, "dequeue.classify").length}`);
' "$DIR/worker/jobs/schema.sql" > "$T/s6.txt" 2>&1
  for want in "dequeue.classify n=1 pos=0 runner=claude same=true" \
              "stage.dequeue-classify n=1 pos=0 runner=claude same=true" \
              "tombstoned n=0"; do
    grep -qxF "$want" "$T/s6.txt" && ok || bad "S6 wanted '$want' from $DIR/worker/jobs/schema.sql, got: $(tr '\n' '|' < "$T/s6.txt")"
  done
fi

echo "dequeue-watch-stub: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
