#!/bin/bash
# tests/pool-toolchain-probe.bh-9435-test.sh — BH-9435 (T6): the daily pool
# toolchain probe, bin/pool-toolchain-probe.sh, and its pool-builder call site.
#
#   Q1  --run, pg ok + tsc ok: one `POOL_PROBE <p> pg=ok tsc=ok heap=<MB src>`
#       line, rc 0, no alert call (the hub's --check alerts)
#   Q2  CREATE EXTENSION vector fails: pg=fail:create-extension, rc 1
#   Q3  tsc exits 134: tsc=fail:134; the heap is the rebase_tsc_heap answer
#   Q4  both fail: one line naming both; start, npm ci and no-repo fail words
#   B1  --builder: today's claim (kind pool-toolchain-probe, key <p>:<UTC day>),
#       the checks, then ONE ledger PUT of fail with the verdict line as detail
#   B2  --builder, day already claimed (rc 3): no check runs
#   B3  --builder, ledger does not answer: no check runs
#   B4  --builder, row pool_probe_on_builder = 0: no claim, no check
#   C1  --check (the CLI): a fail row = exactly 1 warn alert naming the line; an
#       ok row = 1 resolve; running or no row = 0 alert calls; yesterday's row
#       is read when today has none
#   C2  --check, a row with both checks failed: still 1 alert, not 2
#   Q5  flags/lane-off-pool-toolchain-probe: --run, --builder and --check make 0
#       alert, 0 ledger, 0 postgres and 0 npx calls
#   Q7  POOL_TEST_POSTGRES off and no tsconfig.json: pg=off tsc=off, no pgt_start,
#       no npx, rc 0
#   Q9  the pg_ctl stop timeout is the knob POOL_PROBE_PG_STOP_TIMEOUT_S: no row
#       = -t 30, 45 = -t 45, abc or 0 = -t 30; no `-t <digits>` literal is left
#   Q10 the warm clone has a red ticket branch checked out (and a stale local
#       main): the probe type-checks origin/main, tsc=ok, at origin/main's sha
#   Q11 no origin/HEAD and no origin/main: tsc=fail:no-default-branch, the builder
#       PUTs fail, and --check on that row makes exactly 1 alert
#   Q12 origin/main only (no origin/HEAD symref): tsc=ok
#   Q13 100 MB free under DISK_HEADROOM_MIN_FREE_MB 8192: tsc=off:low-disk, no
#       clone, no npm ci, rc 0; the builder PUTs ok; --check resolves, 0 alerts
#   Q14 free equal to the min: the check runs (npm ci is called)
#   Q15 df fails: the check runs
#   Q8  sources: bash -n, the lane json, the cron fragment (hourly :47 --check
#       behind the hub lease), and fly/builder-runner.sh calls the probe on the
#       build path after warm_up and before the PR-adopt preflight
#
# pgt_start/pgt_stop/_pgt_as are function overrides (PTP_LIB_ONLY=1). pg_ctl
# and postgres are PGT_BIN_DIR stubs; npm, npx and df are PATH stubs (df answers
# STUB_DF_FREE MB, default 50000, or fails with STUB_DF_FAIL=1); jobs-client.sh
# and lane-alert.sh are stubs in the scratch harness. git is real, cloning a
# local repo over file://. No call leaves the box.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# The suite reads the UTC day the probe reads (ledger keys <p>:<day>); the run
# must not straddle 00:00Z (the guard TEST-CHANGE BH-6052 asks of a day read).
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 120 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$DIR/bin/pool-toolchain-probe.sh"
unset DISK_HEADROOM_MIN_FREE_MB POOL_PROBE_PG_STOP_TIMEOUT_S
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# world <name>: a fresh harness root, stubs and one repo per call (unique dirs).
world() {
  W="$T/$1"; scratch_rm "$W"; mkdir -p "$W/h/bin" "$W/h/flags" "$W/h/logs" "$W/stub" "$W/repos"
  cat > "$W/h/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$W/alerts.log"
EOF
  mkdir -p "$W/pgbin"
  cat > "$W/pgbin/pg_ctl" <<EOF
#!/bin/bash
echo "pg_ctl \$*" >> "$W/calls.log"; exit 0
EOF
  # postgres --single: the SQL arrives on stdin. STUB_SQL_FAIL=1 answers the
  # error the current image gives; else the row a pgvector cluster prints.
  cat > "$W/pgbin/postgres" <<EOF
#!/bin/bash
echo "postgres \$* :: \$(tr '\n' ' ')" >> "$W/calls.log"
if [ "\${STUB_SQL_FAIL:-0}" = 1 ]; then
  echo '2026-11-11 00:00:00.000 UTC [1] ERROR:  extension "vector" is not available'
else
  echo '	 1: v = "[1,2]"	(typeid = 16390, len = -1, typmod = -1, byval = f)'
fi
exit 0
EOF
  chmod +x "$W/pgbin/"*
  for s in npx npm; do
    cat > "$W/stub/$s" <<EOF
#!/bin/bash
echo "$s \$*" >> "$W/calls.log"
case "$s" in
  npx)  echo "NODE_OPTIONS=\$NODE_OPTIONS" >> "$W/calls.log"
        echo "tsc-sha \$(git rev-parse HEAD 2>/dev/null)" >> "$W/calls.log"
        [ -f BREAK ] && exit 2
        exit "\${STUB_TSC_RC:-0}" ;;
  npm)  exit "\${STUB_NPM_RC:-0}" ;;
esac
EOF
  done
  cat > "$W/stub/df" <<EOF
#!/bin/bash
[ "\${STUB_DF_FAIL:-0}" = 1 ] && exit 1
echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
echo "stub 100000 1 \${STUB_DF_FREE:-50000} 1% /"
EOF
  # jobs-client.sh stub: the three ledger calls the probe makes. A claim answers
  # STUB_CLAIM_RC (0 claimed); a row is the file rows/<key> (rc 2 when absent).
  mkdir -p "$W/rows"
  cat > "$W/h/bin/jobs-client.sh" <<EOF
job_ledger_claim() { printf 'claim %s\n' "\$*" >> "$W/ledger.log"; echo "\${STUB_CLAIM_ST:-running}"; return "\${STUB_CLAIM_RC:-0}"; }
job_ledger_put()   { printf 'put %s\n' "\$*" >> "$W/ledger.log"; return 0; }
job_ledger_row()   { printf 'row %s\n' "\$*" >> "$W/ledger.log"; [ "\${STUB_ROW_RC:-}" != "" ] && return "\$STUB_ROW_RC"; [ -f "$W/rows/\$2" ] || return 2; cat "$W/rows/\$2"; }
EOF
  chmod +x "$W/h/bin/lane-alert.sh" "$W/stub/"*
  : > "$W/alerts.log"; : > "$W/calls.log"; : > "$W/ledger.log"
}
# repo <project> [ts]: a git repo under $W/repos with package.json, and
# tsconfig.json plus a workflow heap when ts is given.
repo() {
  local r="$W/repos/$1"
  mkdir -p "$r/.github/workflows"
  echo '{"name":"x","scripts":{}}' > "$r/package.json"
  echo '{}' > "$r/package-lock.json"
  if [ -n "${2:-}" ]; then
    echo '{"compilerOptions":{}}' > "$r/tsconfig.json"
    echo 'run: NODE_OPTIONS=--max-old-space-size=6144 npx tsc' > "$r/.github/workflows/ci.yml"
  fi
  git -C "$r" init -q && git -C "$r" add -A && git -C "$r" -c user.email=t@t -c user.name=t commit -qm init
  # The warm clone's view of origin: origin/main and the origin/HEAD symref.
  git -C "$r" update-ref refs/remotes/origin/main HEAD
  git -C "$r" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
# probe <project> [pg] [fn]: source the script as a lib, stub pgt_*, run one
# project through fn (default ptp_run; ptp_builder for the builder half).
probe() {
  local p="$1" pg="${2:-1}" fn="${3:-ptp_run}"
  (
    export HARNESS="$W/h" REPOS_ROOT="$W/repos" PATH="$W/stub:$PATH" LANE_GATE_DISABLE=1
    export TSC_HEAP_MEMINFO="$W/meminfo" PGT_BIN_DIR="$W/pgbin"
    POOL_TEST_POSTGRES="$pg"; export POOL_TEST_POSTGRES
    PTP_LIB_ONLY=1 . "$SCRIPT" || exit 99
    pgt_start() { echo "pgt_start" >> "$W/calls.log"; PGT_URL=postgresql://harness@127.0.0.1:54999/postgres; PGT_DIR="$W/pgtest.abcdef"; mkdir -p "$PGT_DIR/data"; return "${STUB_START_RC:-0}"; }
    _pgt_as() { local b="$1"; shift; "$PGT_BIN_DIR/$b" "$@"; }
    pgt_stop()  { echo "pgt_stop" >> "$W/calls.log"; PGT_DIR=""; PGT_URL=""; return 0; }
    "$fn" "$p"
  ) > "$W/out.txt" 2>&1
  echo $? > "$W/rc"
}
printf 'MemTotal:       16777216 kB\n' > "$T/meminfo"
n_alert() { grep -c -- '--severity warn' "$W/alerts.log"; }
n_resolve() { grep -c -- '--resolve' "$W/alerts.log"; }

[ -f "$SCRIPT" ] || { bad "bin/pool-toolchain-probe.sh exists"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# --- Q1 -------------------------------------------------------------------
world q1; cp "$T/meminfo" "$W/meminfo"; repo q1p ts
probe q1p
chk "Q1 rc 0" '[ "$(cat "$W/rc")" = 0 ]'
chk "Q1 verdict line" 'grep -qx "POOL_PROBE q1p pg=ok tsc=ok heap=11468 ram" "$W/out.txt"'
chk "Q1 no alert call from --run" '[ ! -s "$W/alerts.log" ]'
chk "Q1 single-user postgres ran CREATE EXTENSION vector" 'grep -q "^postgres --single .*CREATE EXTENSION IF NOT EXISTS vector; SELECT .\[1,2\].::vector" "$W/calls.log"'
chk "Q1 postmaster stopped before single-user mode" 'grep -A1 "^pg_ctl -D .* stop" "$W/calls.log" | grep -q "^postgres --single"'
chk "Q1 tsc ran at the heap" 'grep -q "NODE_OPTIONS=.*--max-old-space-size=11468" "$W/calls.log"'
chk "Q1 npm ci ran" 'grep -q "^npm ci" "$W/calls.log"'
chk "Q1 pgt_stop after start" '[ "$(grep -c "^pgt_stop" "$W/calls.log")" -ge 1 ]'
chk "Q1 verdict in the lane log" 'grep -q "POOL_PROBE q1p pg=ok tsc=ok" "$W/h/logs/pool-toolchain-probe.log"'

# --- Q2 -------------------------------------------------------------------
world q2; cp "$T/meminfo" "$W/meminfo"; repo q2p ts
STUB_SQL_FAIL=1 probe q2p
chk "Q2 verdict names pg=fail" 'grep -q "^POOL_PROBE q2p pg=fail:create-extension tsc=ok heap=" "$W/out.txt"'
chk "Q2 rc 1" '[ "$(cat "$W/rc")" = 1 ]'
chk "Q2 cluster torn down" 'grep -q "^pgt_stop" "$W/calls.log"'

# --- Q3 -------------------------------------------------------------------
world q3; cp "$T/meminfo" "$W/meminfo"; repo q3p ts
STUB_TSC_RC=134 probe q3p
chk "Q3 verdict names tsc=fail:134" 'grep -qx "POOL_PROBE q3p pg=ok tsc=fail:134 heap=11468 ram" "$W/out.txt"'
chk "Q3 rc 1" '[ "$(cat "$W/rc")" = 1 ]'

# --- Q4 -------------------------------------------------------------------
world q4; cp "$T/meminfo" "$W/meminfo"; repo q4p ts
STUB_SQL_FAIL=1 STUB_TSC_RC=2 probe q4p
chk "Q4 both fail in one line" 'grep -q "^POOL_PROBE q4p pg=fail:create-extension tsc=fail:2 " "$W/out.txt" && [ "$(grep -c "^POOL_PROBE" "$W/out.txt")" = 1 ]'
world q4b; cp "$T/meminfo" "$W/meminfo"; repo q4bp ts
STUB_START_RC=2 probe q4bp
chk "Q4b start rc 2 = pg=fail:start-rc2, no SQL run" 'grep -q "^POOL_PROBE q4bp pg=fail:start-rc2 " "$W/out.txt" && ! grep -q "^postgres" "$W/calls.log"'
world q4c; cp "$T/meminfo" "$W/meminfo"; repo q4cp ts
STUB_NPM_RC=1 probe q4cp
chk "Q4c npm ci red = tsc=fail:npm-ci-1, no npx" 'grep -q "tsc=fail:npm-ci-1 " "$W/out.txt" && ! grep -q "^npx" "$W/calls.log"'
world q4d; cp "$T/meminfo" "$W/meminfo"
probe q4dp
chk "Q4d no repo = tsc=fail:no-repo" 'grep -q "^POOL_PROBE q4dp pg=ok tsc=fail:no-repo " "$W/out.txt"'

# --- B1-B4: the builder half ---------------------------------------------
TODAY=$(date -u +%F)
world b1; cp "$T/meminfo" "$W/meminfo"; repo b1p ts
STUB_SQL_FAIL=1 probe b1p 1 ptp_builder
chk "B1 rc 0 (a probe never fails the job)" '[ "$(cat "$W/rc")" = 0 ]'
chk "B1 claim: kind, key, running, stale 7200, terminal ok,fail" 'grep -q "^claim pool-toolchain-probe b1p:$TODAY running 7200 ok,fail box=" "$W/ledger.log"'
chk "B1 the checks ran" 'grep -q "^pgt_start" "$W/calls.log" && grep -q "^npx" "$W/calls.log"'
chk "B1 exactly one PUT: fail + the verdict line" '[ "$(grep -c "^put " "$W/ledger.log")" = 1 ] && grep -q "^put pool-toolchain-probe b1p:$TODAY fail POOL_PROBE b1p pg=fail:create-extension tsc=ok heap=11468 ram$" "$W/ledger.log"'
chk "B1 claim before checks" '[ "$(head -1 "$W/ledger.log" | cut -d" " -f1)" = claim ]'
chk "B1 no alert call on the builder" '[ ! -s "$W/alerts.log" ]'
world b1ok; cp "$T/meminfo" "$W/meminfo"; repo b1okp ts
probe b1okp 1 ptp_builder
chk "B1ok a pass PUTs ok" 'grep -q "^put pool-toolchain-probe b1okp:$TODAY ok POOL_PROBE b1okp pg=ok tsc=ok heap=11468 ram$" "$W/ledger.log"'
world b2; cp "$T/meminfo" "$W/meminfo"; repo b2p ts
STUB_CLAIM_RC=3 STUB_CLAIM_ST=ok probe b2p 1 ptp_builder
chk "B2 claimed already: no check, no PUT" '[ ! -s "$W/calls.log" ] && ! grep -q "^put" "$W/ledger.log"'
chk "B2 one log line" 'grep -q "builder: b2p:$TODAY already claimed (ok)" "$W/h/logs/pool-toolchain-probe.log"'
world b3; cp "$T/meminfo" "$W/meminfo"; repo b3p ts
STUB_CLAIM_RC=1 probe b3p 1 ptp_builder
chk "B3 ledger down: no check, no PUT" '[ ! -s "$W/calls.log" ] && ! grep -q "^put" "$W/ledger.log"'
chk "B3 rc 0" '[ "$(cat "$W/rc")" = 0 ]'
world b4; cp "$T/meminfo" "$W/meminfo"; repo b4p ts
POOL_PROBE_ON_BUILDER=0 probe b4p 1 ptp_builder
chk "B4 on_builder 0: no claim, no check" '[ ! -s "$W/ledger.log" ] && [ ! -s "$W/calls.log" ]'

# --- C1-C2: the hub check, through the CLI --------------------------------
YDAY=$(date -u -d yesterday +%F)
check() { ( export HARNESS="$W/h" LANE_GATE_DISABLE=1; bash "$SCRIPT" --check ) > "$W/out.txt" 2>&1; echo $? > "$W/rc"; }
world c1
touch "$W/h/flags/fly-pool-alpha" "$W/h/flags/fly-pool-beta" "$W/h/flags/fly-pool-gamma" "$W/h/flags/fly-pool-delta" "$W/h/flags/fly-pool-app-alpha"
echo '{"status":"fail","detail":"POOL_PROBE alpha pg=fail:create-extension tsc=ok heap=11468 ram"}' > "$W/rows/alpha:$TODAY"
echo '{"status":"ok","detail":"POOL_PROBE beta pg=ok tsc=ok heap=11468 ram"}' > "$W/rows/beta:$YDAY"
echo '{"status":"running","detail":"box=x"}' > "$W/rows/gamma:$TODAY"
check
chk "C1 rc 0" '[ "$(cat "$W/rc")" = 0 ]'
chk "C1 exactly 1 warn alert, alpha, with the verdict line" '[ "$(n_alert)" = 1 ] && grep -qx -- "--id pool-toolchain-alpha --severity warn pool-toolchain-probe POOL_PROBE alpha pg=fail:create-extension tsc=ok heap=11468 ram" "$W/alerts.log"'
chk "C1 beta resolved from yesterday's row" '[ "$(n_resolve)" = 1 ] && grep -q -- "--resolve --id pool-toolchain-beta " "$W/alerts.log"'
chk "C1 gamma (running) and delta (no row): no alert call" '! grep -q "gamma\|delta" "$W/alerts.log"'
chk "C1 app-name flag is not a project" '! grep -q " app-alpha:" "$W/ledger.log"'
chk "C1 summary line" 'grep -q "check: alerts 1, resolves 1, no verdict 2, ledger down 0" "$W/h/logs/pool-toolchain-probe.log"'
world c2
touch "$W/h/flags/fly-pool-alpha"
echo '{"status":"fail","detail":"POOL_PROBE alpha pg=fail:create-extension tsc=fail:134 heap=11468 ram"}' > "$W/rows/alpha:$TODAY"
check
chk "C2 both fail: 1 alert line, not 2" '[ "$(wc -l < "$W/alerts.log")" = 1 ] && grep -q "pg=fail:create-extension tsc=fail:134" "$W/alerts.log"'
world c3
touch "$W/h/flags/fly-pool-alpha"
STUB_ROW_RC=1 check
chk "C3 ledger down: 0 alert calls, 1 down" '[ ! -s "$W/alerts.log" ] && grep -q "ledger down 1" "$W/h/logs/pool-toolchain-probe.log"'

# --- Q5 -------------------------------------------------------------------
world q5; cp "$T/meminfo" "$W/meminfo"; repo q5p ts
touch "$W/h/flags/lane-off-pool-toolchain-probe" "$W/h/flags/fly-pool-q5p"
echo '{"status":"fail","detail":"x"}' > "$W/rows/q5p:$TODAY"
( export HARNESS="$W/h" REPOS_ROOT="$W/repos" PATH="$W/stub:$PATH" LANE_GATE_DISABLE=1 POOL_TEST_POSTGRES=1 PGT_BIN_DIR="$W/pgbin"
  bash "$SCRIPT" --run q5p; echo "run=$?"; bash "$SCRIPT" --builder q5p; echo "builder=$?"; bash "$SCRIPT" --check; echo "check=$?" ) > "$W/out.txt" 2>&1
chk "Q5 every mode exits 0" 'grep -qx "run=0" "$W/out.txt" && grep -qx "builder=0" "$W/out.txt" && grep -qx "check=0" "$W/out.txt"'
chk "Q5 0 alert calls" '[ ! -s "$W/alerts.log" ]'
chk "Q5 0 ledger calls" '[ ! -s "$W/ledger.log" ]'
chk "Q5 0 postgres/npx/npm calls" '[ ! -s "$W/calls.log" ]'
chk "Q5 no verdict line" '! grep -q "^POOL_PROBE" "$W/out.txt"'

# --- Q7 -------------------------------------------------------------------
world q7; cp "$T/meminfo" "$W/meminfo"; repo q7p
probe q7p 0
chk "Q7 pg=off tsc=off" 'grep -q "^POOL_PROBE q7p pg=off tsc=off heap=" "$W/out.txt"'
chk "Q7 no pgt_start, no npx" '! grep -q "^pgt_start\|^npx" "$W/calls.log"'
chk "Q7 rc 0" '[ "$(cat "$W/rc")" = 0 ]'

# --- Q9: the stop timeout knob ------------------------------------------
world q9; cp "$T/meminfo" "$W/meminfo"; repo q9p ts
probe q9p
chk "Q9 no row: pg_ctl -t 30" 'grep -q "^pg_ctl -D .* -m fast -w -t 30 stop" "$W/calls.log"'
world q9b; cp "$T/meminfo" "$W/meminfo"; repo q9bp ts
POOL_PROBE_PG_STOP_TIMEOUT_S=45 probe q9bp
chk "Q9 value 45: pg_ctl -t 45" 'grep -q "^pg_ctl -D .* -m fast -w -t 45 stop" "$W/calls.log" && grep -q "^POOL_PROBE q9bp pg=ok " "$W/out.txt"'
for v in abc 0; do
  world "q9$v"; cp "$T/meminfo" "$W/meminfo"; repo "q9${v}p" ts
  POOL_PROBE_PG_STOP_TIMEOUT_S="$v" probe "q9${v}p"
  chk "Q9 value '$v': the fallback -t 30" 'grep -q "^pg_ctl -D .* -m fast -w -t 30 stop" "$W/calls.log"'
done
chk "Q9 no -t <digits> literal in the probe" '! grep -nE -- "-t [0-9]+" "$SCRIPT"'
chk "Q9 the lane json declares the knob, default 30" 'jq -e "[.knobs[] | select(.env==\"POOL_PROBE_PG_STOP_TIMEOUT_S\" and .default==30)] | length == 1" "$DIR/catalog/lanes.d/pool-toolchain-probe.json" >/dev/null'

# --- Q10-Q12: the default branch -----------------------------------------
world q10; cp "$T/meminfo" "$W/meminfo"; repo q10p ts
r="$W/repos/q10p"
git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin main tip"
git -C "$r" update-ref refs/remotes/origin/main HEAD
MAINSHA=$(git -C "$r" rev-parse refs/remotes/origin/main)
git -C "$r" reset -q --hard HEAD~1          # local main is stale (behind origin/main)
git -C "$r" checkout -q -b ticket/red
: > "$r/BREAK"; git -C "$r" add BREAK; git -C "$r" -c user.email=t@t -c user.name=t commit -qm "a red ticket branch"
probe q10p
chk "Q10 a red checked-out ticket branch is not checked: tsc=ok" 'grep -q "^POOL_PROBE q10p pg=ok tsc=ok " "$W/out.txt"'
chk "Q10 tsc ran at origin/main's sha" 'grep -qx "tsc-sha $MAINSHA" "$W/calls.log"'
chk "Q10 rc 0, no alert" '[ "$(cat "$W/rc")" = 0 ] && [ ! -s "$W/alerts.log" ]'

world q11; cp "$T/meminfo" "$W/meminfo"; repo q11p ts
git -C "$W/repos/q11p" symbolic-ref -d refs/remotes/origin/HEAD; git -C "$W/repos/q11p" update-ref -d refs/remotes/origin/main
probe q11p 1 ptp_builder
chk "Q11 no default branch: the builder PUTs fail:no-default-branch" 'grep -q "^put pool-toolchain-probe q11p:$TODAY fail POOL_PROBE q11p pg=ok tsc=fail:no-default-branch heap=- -$" "$W/ledger.log"'
chk "Q11 no npm ci, no npx" '! grep -q "^npm\|^npx" "$W/calls.log"'
touch "$W/h/flags/fly-pool-q11p"
echo "{\"status\":\"fail\",\"detail\":\"POOL_PROBE q11p pg=ok tsc=fail:no-default-branch heap=- -\"}" > "$W/rows/q11p:$TODAY"
: > "$W/alerts.log"; check
chk "Q11 --check: exactly 1 alert naming fail:no-default-branch" '[ "$(n_alert)" = 1 ] && grep -q "tsc=fail:no-default-branch" "$W/alerts.log"'

world q12; cp "$T/meminfo" "$W/meminfo"; repo q12p ts
git -C "$W/repos/q12p" symbolic-ref -d refs/remotes/origin/HEAD
probe q12p
chk "Q12 origin/main only: tsc=ok" 'grep -q "^POOL_PROBE q12p pg=ok tsc=ok " "$W/out.txt"'

# --- Q13-Q15: the disk check ---------------------------------------------
world q13; cp "$T/meminfo" "$W/meminfo"; repo q13p ts
STUB_DF_FREE=100 probe q13p 1 ptp_builder
chk "Q13 low disk: the builder PUTs ok with tsc=off:low-disk" 'grep -q "^put pool-toolchain-probe q13p:$TODAY ok POOL_PROBE q13p pg=ok tsc=off:low-disk heap=- -$" "$W/ledger.log"'
chk "Q13 no npm ci, no npx" '! grep -q "^npm\|^npx" "$W/calls.log"'
chk "Q13 rc 0" '[ "$(cat "$W/rc")" = 0 ]'
chk "Q13 one log line names both numbers" 'grep -q "q13p: tsc off: 100 MB free .* below DISK_HEADROOM_MIN_FREE_MB 8192" "$W/h/logs/pool-toolchain-probe.log"'
chk "Q13 no clone or temp dir is left" '! compgen -G "${TMPDIR:-/tmp}/ptp-q13p.*" >/dev/null'
touch "$W/h/flags/fly-pool-q13p"
echo "{\"status\":\"ok\",\"detail\":\"POOL_PROBE q13p pg=ok tsc=off:low-disk heap=- -\"}" > "$W/rows/q13p:$TODAY"
: > "$W/alerts.log"; check
chk "Q13 --check: 0 alerts, 1 resolve" '[ "$(n_alert)" = 0 ] && [ "$(n_resolve)" = 1 ]'

world q14; cp "$T/meminfo" "$W/meminfo"; repo q14p ts
STUB_DF_FREE=8192 probe q14p
chk "Q14 free = min: the check runs" 'grep -q "^npm ci" "$W/calls.log" && grep -q "^POOL_PROBE q14p pg=ok tsc=ok " "$W/out.txt"'
world q14b; cp "$T/meminfo" "$W/meminfo"; repo q14bp ts
STUB_DF_FREE=8191 probe q14bp
chk "Q14b free = min - 1: off:low-disk" 'grep -q "^POOL_PROBE q14bp pg=ok tsc=off:low-disk " "$W/out.txt"'

world q15; cp "$T/meminfo" "$W/meminfo"; repo q15p ts
STUB_DF_FAIL=1 probe q15p
chk "Q15 df fails: the check runs" 'grep -q "^npm ci" "$W/calls.log" && grep -q "^POOL_PROBE q15p pg=ok tsc=ok " "$W/out.txt"'

# --- Q8 -------------------------------------------------------------------
chk "Q8 bash -n" 'bash -n "$SCRIPT"'
LJ="$DIR/catalog/lanes.d/pool-toolchain-probe.json"
chk "Q8 lane json id/script/switch/cadence" 'jq -e ".id==\"pool-toolchain-probe\" and .script==\"bin/pool-toolchain-probe.sh\" and .switch.name==\"lane-off-pool-toolchain-probe\" and .cadence==\"47 * * * *\"" "$LJ" >/dev/null'
chk "Q8 lane json has the builder knobs, no POOL_PROBE_ARMED" 'jq -e "[.knobs[].env] | (index(\"POOL_PROBE_ON_BUILDER\") != null) and (index(\"POOL_PROBE_CLAIM_STALE_S\") != null) and (index(\"POOL_PROBE_ARMED\") == null)" "$LJ" >/dev/null'
CF=$(ls "$DIR"/cron/lanes/*-pool-toolchain-probe.cron 2>/dev/null | head -1)
chk "Q8 cron fragment hourly :47 --check behind the hub lease" '[ -n "$CF" ] && grep -q "^47 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/pool-toolchain-probe.sh --check" "$CF"'
BR="$DIR/fly/builder-runner.sh"
nw=$(grep -n -m1 '^  warm_up || { echo "BUILD_DEFERRED warm-up failed"' "$BR" | cut -d: -f1)
np=$(grep -n '^  pool_toolchain_probe "\$key"$' "$BR" | head -1 | cut -d: -f1)
na=$(grep -n 'PR-adopt preflight: retry of a build' "$BR" | head -1 | cut -d: -f1)
chk "Q8 builder-runner: the probe call sits after warm_up, before the PR-adopt preflight" '[ -n "$nw" ] && [ -n "$np" ] && [ -n "$na" ] && [ "$nw" -lt "$np" ] && [ "$np" -lt "$na" ]'
chk "Q8 builder-runner: pool_toolchain_probe runs --builder <project> on the runner's repos root, with its env dir" 'grep -qF "HARNESS_ENV_DIR=\"\$ENVDIR\" REPOS_ROOT=\"\${REPO%/*}\" PROJECT=\"\$PROJECT\" bash \"\$s\" --builder \"\$PROJECT\"" "$BR"'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
