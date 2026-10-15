#!/bin/bash
# tests/lane-run-code-sync.bh-6817-test.sh — BH-6817 item 1: a lane-run
# machine runs current harness code. Before a claim, at most once every
# lane_run.code_check_s, bin/lane-run-worker.sh fetches main by git
# (bin/lib/lane-run-code.sh), swaps in bin/, catalog/ and fleet.conf, and
# re-execs itself.
#
# Driven through the REAL bin/lane-run-worker.sh --once on a scratch machine
# root made from the image tree (git archive of bin catalog fleet.conf, no
# HARNESS_COMMIT), against the REAL jobs worker
# (tests/lib/lane-runs-worker.bh-6124.mjs). LANE_RUN_CODE_URL=file:// points at
# a scratch git repo whose main the suite moves commit by commit.
#
#   S1  boot: the root syncs to A (HARNESS_COMMIT = A, `code unknown -> A12`
#       in the worker log and on stderr); the stage's composer writes
#       catalog/llm-sites.json and an old render the stage lacks is kept
#   S2  commit B adds bin/new-lane.sh; a row with args bin/new-lane.sh on a new
#       --once worker: `code A12 -> B12`, the row done rc 0, the script ran
#   S6  inside lane_run.code_check_s no second fetch; at the interval a swap;
#       an out-of-range row falls back to 120 s; a row of 30 is used
#   S3  an unreachable URL: the tree unchanged, 1 failure line, 1 alert, the
#       claim still runs; a second failure in the hour sends no second alert
#   S4  a commit whose bin/lane-run-worker.sh fails bash -n is not swapped
#   S5  no fetch without LANE_RUN_CODE_SYNC=1, with .git, with a populated
#       builds/, with lane_run.code_sync=0; the control syncs; then `current`
#
# Run from anywhere: tests/lane-run-code-sync.bh-6817-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
SRV="$DIR/tests/lib/lane-runs-worker.bh-6124.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v git >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or git missing"; exit 0; }
[ -f "$DIR/bin/lib/lane-run-code.sh" ] || { echo "FAIL: bin/lib/lane-run-code.sh is missing"; exit 1; }

# The source repo: the worker's closure, the sync lib, a stub alert writer, a
# stub composer, a fixture catalog file and fleet.conf, on branch main.
S="$T/src"
mkdir -p "$S/bin" "$S/catalog"
for L in bin/lane-run-worker.sh bin/project-lane-run.sh bin/fleet-conf.sh bin/jobs-client.sh \
         bin/lib/gh-app-auth.sh bin/lib/lane-run-code.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$S" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$S/fleet.conf"
printf '{"fixture":true}\n' > "$S/catalog/fixture.json"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$S/bin/lane-alert.sh"
cat > "$S/bin/llm-sites-build.sh" <<'EOF'
#!/bin/bash
# fixture composer: --compose --repo <dir>
while [ "$#" -gt 0 ]; do case "$1" in --repo) r="$2"; shift 2 ;; *) shift ;; esac; done
printf '{"composed":true}\n' > "$r/catalog/llm-sites.json"
EOF
chmod +x "$S/bin/"*.sh
git_s() { git -C "$S" -c user.email=fixture@example.invalid -c user.name=fixture "$@"; }
git_s init -q -b main . && git_s add -A && git_s commit -q -m A || { echo "setup: git repo"; exit 1; }
A=$(git_s rev-parse HEAD)

# The machine root: the image tree (no HARNESS_COMMIT), plus an old render.
M="$T/m"
mkdir -p "$M"
git_s archive HEAD bin catalog fleet.conf | tar -x -C "$M"
printf '{"old":"render"}\n' > "$M/catalog/context-budgets.json"
: > "$T/alerts.txt"

export HARNESS="$M" FLEET_CONF="$M/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret GH_TOKEN=tok-fixture-default
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box
export LANE_RUN_CODE_SYNC=1 LANE_RUN_CODE_URL="file://$S"
NOW0=1791000000

: > "$T/w.log"; : > "$T/w.port"
node "$SRV" "$T/w.log" > "$T/w.port" 2> "$T/w.err" &
PID=$!
trap 'kill "$PID" 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port")
if [ -z "$PORT" ]; then wait "$PID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }; echo "setup: worker did not start: $(cat "$T/w.err")"; exit 1; fi
export JOBS_URL="http://127.0.0.1:$PORT"

api() { curl -sS -X "$1" -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' ${3:+-d "$3"} "$JOBS_URL$2"; }
enq() { api POST /api/lane-runs "$(jq -nc --arg l "$1" --arg p "$2" --arg c "$3" '{lane:$l,project:$p,args:[$c]}')" | jq -r .id; }
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
unsetting() { curl -sS -X DELETE "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" '{key:$k}')" >/dev/null; }
drow() { curl -sS "$JOBS_URL/__lane_runs" | jq -c --argjson id "$1" '.rows[] | select(.id == $id)'; }
# work <now> [env...] — one --once machine on M, the clock pinned.
work() { local now="$1"; shift
  mkdir -p "$M/logs"; rm -f "$M/logs/lane-run-worker.log"
  env "$@" LANE_RUN_NOW="$now" "$M/bin/lane-run-worker.sh" --once --machine m1 > "$T/work.out" 2> "$T/work.err"; WRC=$?; }
wlog() { cat "$M/logs/lane-run-worker.log" 2>/dev/null; }
hc() { head -n 1 "$M/HARNESS_COMMIT" 2>/dev/null; }
# commit <msg> <cmd> — run cmd in the source repo, then commit it on main.
commit() { ( cd "$S" && eval "$2" ) && git_s add -A && git_s commit -q -m "$1" && git_s rev-parse HEAD; }
treesum() { ( cd "$M" && find bin catalog fleet.conf -type f -exec md5sum {} + 2>/dev/null | sort | md5sum ); }
nfail_alerts() { grep -c -- '--id lane-run-code-sync ' "$T/alerts.txt"; }

# ============================================================================
echo "S1: boot syncs to A"
[ ! -e "$M/HARNESS_COMMIT" ] && ok "S1 setup: the image root has no HARNESS_COMMIT" || bad "S1 setup"
work "$NOW0"
[ "$WRC" = 0 ] && ok "S1 the loop exits 0" || bad "S1 rc=$WRC $(cat "$T/work.err")"
[ "$(hc)" = "$A" ] && ok "S1 HARNESS_COMMIT = A" || bad "S1 HARNESS_COMMIT: $(hc); log: $(wlog)"
grep -q "code unknown -> ${A:0:12}\$" <<<"$(wlog)" && ok "S1 the worker log has 'code unknown -> A12'" || bad "S1 log: $(wlog)"
grep -q "code unknown -> ${A:0:12}" "$T/work.err" && ok "S1 the line is on stderr (flyctl logs)" || bad "S1 stderr: $(cat "$T/work.err")"
[ "$(cat "$M/catalog/llm-sites.json" 2>/dev/null)" = '{"composed":true}' ] && ok "S1 the stage's composer wrote catalog/llm-sites.json" \
  || bad "S1 llm-sites.json: $(cat "$M/catalog/llm-sites.json" 2>&1)"
[ "$(cat "$M/catalog/context-budgets.json" 2>/dev/null)" = '{"old":"render"}' ] && [ -f "$M/catalog/fixture.json" ] \
  && ok "S1 an old render the stage lacks is kept, the committed file is there" || bad "S1 catalog: $(ls "$M/catalog")"
[ -z "$(ls -d "$M"/state/lane-run-code/stage-* "$M"/state/lane-run-code/old-* 2>/dev/null)" ] && ok "S1 no stage or old copy left" \
  || bad "S1 left: $(ls "$M/state/lane-run-code")"

# ============================================================================
echo "S2: after a main change to bin/, a new machine runs the new file"
B=$(commit B "printf '#!/bin/bash\ntouch \"$T/new-lane-ran\"\necho \"PROF new-lane ok\"\n' > bin/new-lane.sh && chmod +x bin/new-lane.sh")
[ ! -e "$M/bin/new-lane.sh" ] && ok "S2 setup: the machine does not have bin/new-lane.sh yet" || bad "S2 setup"
ID=$(enq new-lane p1 bin/new-lane.sh)
work $((NOW0 + 120))
grep -q "code ${A:0:12} -> ${B:0:12}\$" <<<"$(wlog)" && ok "S2 the log shows 'code A12 -> B12'" || bad "S2 log: $(wlog)"
D=$(drow "$ID")
[ "$(jq -r .status <<<"$D")" = done ] && [ "$(jq -r .rc <<<"$D")" = 0 ] && ok "S2 the row is done rc 0" || bad "S2 row: $D; log: $(wlog)"
[ -e "$T/new-lane-ran" ] && ok "S2 the new script ran" || bad "S2 the new script did not run"
[ "$(hc)" = "$B" ] && ok "S2 HARNESS_COMMIT = B" || bad "S2 HARNESS_COMMIT: $(hc)"

# ============================================================================
echo "S6: the check interval"
C=$(commit C "printf '#!/bin/bash\nexit 0\n' > bin/c.sh && chmod +x bin/c.sh")
work $((NOW0 + 120 + 119))
[ "$(hc)" = "$B" ] && ! grep -q 'code ' <<<"$(wlog)" && ok "S6 at 119 s: no fetch" || bad "S6 119: $(hc) $(wlog)"
setting lane_run.code_check_s 5
work $((NOW0 + 120 + 119))
[ "$(hc)" = "$B" ] && ok "S6 an out-of-range row (5) falls back to 120 s" || bad "S6 row 5: $(hc) $(wlog)"
work $((NOW0 + 120 + 120))
[ "$(hc)" = "$C" ] && grep -q "code ${B:0:12} -> ${C:0:12}" <<<"$(wlog)" && ok "S6 at 120 s: the swap to C" || bad "S6 120: $(hc) $(wlog)"
setting lane_run.code_check_s 30
work $((NOW0 + 240 + 30))
grep -q "code current ${C:0:12}" <<<"$(wlog)" && ok "S6 a row of 30 is used; main unchanged answers current" || bad "S6 row 30: $(wlog)"
unsetting lane_run.code_check_s
NOW1=$((NOW0 + 10000))

# ============================================================================
echo "S3: an unreachable URL"
SUM=$(treesum)
ID=$(enq okay p1 bin/c.sh)
work "$NOW1" LANE_RUN_CODE_URL="file://$T/nope"
[ "$(treesum)" = "$SUM" ] && [ "$(hc)" = "$C" ] && ok "S3 the tree is unchanged" || bad "S3 tree changed: $(hc)"
[ "$(grep -c 'code sync failed: git fetch of main failed' <<<"$(wlog)")" = 1 ] && ok "S3 one failure line" || bad "S3 log: $(wlog)"
[ "$(nfail_alerts)" = 1 ] && ok "S3 one alert" || bad "S3 alerts: $(cat "$T/alerts.txt")"
[ "$(jq -r .status <<<"$(drow "$ID")")" = done ] && ok "S3 the claim still ran" || bad "S3 row: $(drow "$ID")"
work $((NOW1 + 120)) LANE_RUN_CODE_URL="file://$T/nope"
grep -q 'code sync failed' <<<"$(wlog)" && [ "$(nfail_alerts)" = 1 ] && ok "S3 a second failure in the hour: no second alert" \
  || bad "S3 second: $(nfail_alerts) $(wlog)"

# ============================================================================
echo "S4: a commit that fails bash -n is not swapped"
SUM=$(treesum)
Dc=$(commit D "printf 'if then fi (\n' >> bin/lane-run-worker.sh")
work $((NOW1 + 240))
[ "$(hc)" = "$C" ] && [ "$(treesum)" = "$SUM" ] && ok "S4 not swapped" || bad "S4 swapped: $(hc)"
grep -q "code sync failed: ${Dc:0:12} refused: bin/lane-run-worker.sh is missing or fails bash -n" <<<"$(wlog)" \
  && ok "S4 the log names the refused file" || bad "S4 log: $(wlog)"
[ -z "$(ls -d "$M"/state/lane-run-code/stage-* 2>/dev/null)" ] && ok "S4 the stage is removed" || bad "S4 stage left"
E=$(commit E "git checkout -q HEAD~1 -- bin/lane-run-worker.sh")

# ============================================================================
echo "S5: the guards"
NOW2=$((NOW1 + 1000))
g5() { # g5 <name> <now> [env...] — no fetch: HARNESS_COMMIT and checked.at unchanged
  local name="$1" now="$2" at; shift 2
  at=$(cat "$M/state/lane-run-code/checked.at")
  work "$now" "$@"
  [ "$(hc)" = "$C" ] && [ "$(cat "$M/state/lane-run-code/checked.at")" = "$at" ] && [ "$WRC" = 0 ] \
    && ok "S5 $name: no fetch" || bad "S5 $name: $(hc) $(wlog)"
}
g5 "LANE_RUN_CODE_SYNC unset" "$NOW2" LANE_RUN_CODE_SYNC=
mkdir "$M/.git"; g5 ".git present" "$NOW2"; rmdir "$M/.git"
mkdir -p "$M/builds/x"; g5 "builds/ populated" "$NOW2"; scratch_rm "$M/builds"
setting lane_run.code_sync 0; g5 "lane_run.code_sync=0" "$NOW2"
setting lane_run.code_sync 1
work "$NOW2"
[ "$(hc)" = "$E" ] && ok "S5 control: row 1, every guard clear -> the swap to E" || bad "S5 control: $(hc) $(wlog)"
unsetting lane_run.code_sync
work $((NOW2 + 120))
grep -q "code current ${E:0:12}" <<<"$(wlog)" && [ "$(hc)" = "$E" ] && ok "S5 no row = on; main unchanged -> current" || bad "S5 current: $(wlog)"
# The pure gate, the token-free half: an empty root refuses.
( HARNESS="" H="" ; . "$M/bin/lib/lane-run-code.sh" && ! lrc_enabled && ! lrc_due && ! lrc_sync >/dev/null ) \
  && ok "S5 an empty root: every function answers rc 1" || bad "S5 empty root"

echo "lane-run-code-sync: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
