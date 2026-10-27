#!/bin/bash
# bin/lib/pg-test.sh — a throwaway Postgres for the repo's own suite run.
#
# WHAT. HARNESS_SUITE_RUN (bin/lib/rb/gates.sh, npm arm) sources this when it
# exists. For a project whose fly-pool knob POOL_TEST_POSTGRES resolves to 1,
# it starts a Postgres on 127.0.0.1 from the binaries the pool image bakes into
# /opt/pgtest (fly/Dockerfile, bake-pgtest; pin in bin/lib/pgtest-pin.sh), runs
# the project's setup command against it when one is set, and gives
# DATABASE_URL to that setup and the suite only. It stops and deletes the
# instance before the suite file's HARNESS_EXIT line.
#
# Per project, all fly-pool knobs (rows lane.fly-pool.<project>.<knob>):
#   POOL_TEST_POSTGRES        1 = on (default 0)
#   POOL_TEST_POSTGRES_MAJOR  the major the suite needs (default 16). A major
#                             the image does not hold is a could-not-start.
#   POOL_TEST_SETUP_CMD       empty (default) = no setup. Else exactly
#                             `npm run <script>` for a script the repo's own
#                             package.json declares; anything else is refused,
#                             because a settable row must never carry a command.
#   POOL_TEST_POSTGRES_MIN_FREE_MB  the free MB the data root must have (default
#                             512). The root is the one of /dev/shm and
#                             ${TMPDIR:-/tmp} that is a writable dir with the
#                             most free, and at least this much (a tie keeps
#                             that order). BH-8175: /tmp on a pool machine is a
#                             small overlay, and the suite hit ENOSPC there.
#   POOL_TEST_POSTGRES_SERIAL 1 = a selected suite runs one file at a time, each
#                             file on its own fresh cluster (default 0 = off).
#   POOL_TEST_PG_RERUN_MAX_FILES  the most failed files an ENOSPC red reruns
#                             (default 20; 0 = no rerun). More = no rerun.
#   POOL_TEST_PG_SERIAL_BUDGET_S  the seconds a one-file-at-a-time run may
#                             take in total (default 1500). A file past it is
#                             not run.
#
# WHY. The pool runner had no database. A repo whose unit suite needs
# DATABASE_URL (project-6-os: TK-3, TK-34, TK-35, TK-36) recorded HARNESS_EXIT: 1
# on every review, and the review blocks on a nonzero exit, while CI started
# Postgres 16 and passed.
#
# NEVER A REAL DATABASE. The URL is built from the literal 127.0.0.1 and
# checked by pgt_local_url before anything sees it. On a pool machine the
# box's whole project env is exported into the build (fly/builder-runner.sh
# load_env), so overriding DATABASE_URL alone is not enough: Prisma's
# directUrl, POSTGRES_URL*, PG* and the like can still name prod. pgt_env
# builds the env the two children get: every exported name that can carry a
# database address is unset, and DATABASE_URL and DIRECT_URL are the local URL.
# The build's own env is never touched, with the knob on or off.
#
# The lines it writes into the suite file:
#   HARNESS_PG: up (PostgreSQL <ver>, throwaway, <url>)
#   HARNESS_PG: could-not-start (<reason>)      the suite runs with no URL
#   HARNESS_PG: could-not-start (low disk: ...) pgt_start rc 2: the suite does
#                                               not run (HARNESS_EXIT: could-not-run)
#   HARNESS_PG: torn down
#   HARNESS_PG_SETUP: npm run <script> (rc=N) | none (<why>) | refused (<why>)
# (no HARNESS_PG_SETUP line when the start failed: there is nothing to set up)
# Only low disk is a stop: else the suite's own exit is still HARNESS_EXIT.
#
# ONE FILE AT A TIME (pgt_run_files). Each file gets the lines above for its own
# cluster, then:
#   HARNESS_PG_FILE: <file> (rc=N) | (rc=N, ENOSPC) | (not run: <why>)
# HARNESS_SUITE_RUN uses it for the serial run and for the one rerun of the files
# an ENOSPC red names, and writes around it:
#   HARNESS_PG_SERIAL: on (<n> file(s), one fresh cluster each) | off (<why>)
#   HARNESS_PG_SERIAL: green | red (rc=N) | could-not-run (<file>: <why>)
#   HARNESS_PG_RERUN: <n> failed file(s) after ENOSPC, once, one at a time, ...
#   HARNESS_PG_RERUN: green | red (rc=N) | could-not-run (<file>: <why>)

# PGT_BIN_DIR is a test seam only. The image installs to /opt/pgtest (bake-pgtest block).
: "${PGT_BIN_DIR:=/opt/pgtest/bin}"
# PGT_ROOTS (the candidate data roots, in order) is a test seam only, like PGT_BIN_DIR.

# pgt_knob <ENV> — the fly-pool knob for $PROJECT: row, then env, then registry default.
# Resolved in a subshell so lane-gate.sh's globals never land in the caller.
pgt_knob() {
  local lg v="" self root
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="${HARNESS:-${H:-}}"
  for lg in ${root:+"$root/bin/lib/lane-gate.sh"} "$self/lane-gate.sh"; do
    [ -r "$lg" ] || continue
    v=$( . "$lg" 2>/dev/null && lane_knob fly-pool "$1" "${PROJECT:-}" 2>/dev/null )
    break
  done
  [ -n "$v" ] || v="${!1:-}"
  printf '%s' "$v"
}

# pgt_enabled — rc 0 only when POOL_TEST_POSTGRES resolves to exactly 1.
pgt_enabled() { [ "$(pgt_knob POOL_TEST_POSTGRES)" = 1 ]; }

# pgt_local_url <url> — rc 0 only for the exact shape pgt_start builds.
pgt_local_url() {
  [[ "${1:-}" =~ ^postgresql://harness@127\.0\.0\.1:[0-9]{4,5}/postgres$ ]]
}

# pgt_env — fill PGT_ENV with the `env` prefix for the setup script and the suite:
# `env -u <name>...` for every exported database-address name, then DATABASE_URL and
# DIRECT_URL set to PGT_URL. rc 1 (PGT_ENV empty) when PGT_URL is not the local shape.
pgt_env() {
  local n
  PGT_ENV=()
  pgt_local_url "${PGT_URL:-}" || return 1
  PGT_ENV=(env)
  while IFS= read -r n; do
    case "$n" in
      *DATABASE_URL*|*DIRECT_URL*|*DB_URL*|POSTGRES*|PG*|SUPABASE_DB*) PGT_ENV+=(-u "$n") ;;
    esac
  done < <(compgen -e)
  PGT_ENV+=("DATABASE_URL=$PGT_URL" "DIRECT_URL=$PGT_URL")
}

# _pgt_as <binary> <args...> — as nobody when root (initdb refuses root).
_pgt_as() {
  local b="$1"; shift
  if [ "$(id -u)" = 0 ]; then
    setpriv --reuid=nobody --regid=nogroup --clear-groups env LD_LIBRARY_PATH="$PGT_BIN_DIR/../lib" "$PGT_BIN_DIR/$b" "$@"
  else
    env LD_LIBRARY_PATH="$PGT_BIN_DIR/../lib" "$PGT_BIN_DIR/$b" "$@"
  fi
}

# pgt_root — print the candidate root that is a writable dir with the most free MB,
# and at least POOL_TEST_POSTGRES_MIN_FREE_MB. A tie keeps the earlier root. rc 1 when
# none, and what it prints instead names the min and what each root had.
pgt_root() {
  local r min mb why="" best="" bestmb=-1
  # The row lane.fly-pool.<project>.pool_test_postgres_min_free_mb; 512 is its fallback.
  min=$(pgt_knob POOL_TEST_POSTGRES_MIN_FREE_MB)
  [[ "$min" =~ ^[0-9]{1,7}$ ]] || min=512
  for r in ${PGT_ROOTS:-/dev/shm ${TMPDIR:-/tmp}}; do
    if [ ! -d "$r" ]; then why="$why, $r missing"; continue; fi
    if [ ! -w "$r" ]; then why="$why, $r not writable"; continue; fi
    mb=$(df -Pm -- "$r" 2>/dev/null | awk 'NR==2{print $4}')
    if ! [[ "$mb" =~ ^[0-9]+$ ]]; then why="$why, $r unreadable free space"; continue; fi
    if [ "$mb" -ge "$min" ]; then
      [ "$mb" -gt "$bestmb" ] && { best="$r"; bestmb="$mb"; }
      continue
    fi
    why="$why, $r $mb MB"
  done
  [ -n "$best" ] && { printf '%s' "$best"; return 0; }
  printf 'no root has %s MB free: %s' "$min" "${why#, }"
  return 1
}

# pgt_start <outfile> — rc 0: up, PGT_URL and PGT_DIR set. rc 1: not up, the reason is a
# `HARNESS_PG: could-not-start (...)` line, nothing left behind. rc 2: the same, and
# the reason is low disk (`could-not-start (low disk: ...)`): the suite must not run.
pgt_start() {
  local out="$1" w port n up=0 ver major have root
  PGT_URL=""; PGT_DIR=""
  for n in postgres initdb pg_ctl; do
    [ -x "$PGT_BIN_DIR/$n" ] || { echo "HARNESS_PG: could-not-start (no $n in $PGT_BIN_DIR)" >> "$out"; return 1; }
  done
  # The major the project asks for, against the major the image holds. Nothing
  # starts on a mismatch: a suite on the wrong major is not evidence.
  major=$(pgt_knob POOL_TEST_POSTGRES_MAJOR); [ -n "$major" ] || major=16
  [[ "$major" =~ ^[0-9]{1,3}$ ]] || { echo "HARNESS_PG: could-not-start (major '$major' is not a number)" >> "$out"; return 1; }
  ver=$(_pgt_as postgres --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
  have=${ver%%.*}
  [ "$have" = "$major" ] || { echo "HARNESS_PG: could-not-start (major $major is not in the image: it holds ${have:-an unreadable version})" >> "$out"; return 1; }
  root=$(pgt_root) || { echo "HARNESS_PG: could-not-start (low disk: $root)" >> "$out"; return 2; }
  w=$(mktemp -d "$root/pgtest.XXXXXX") || { echo "HARNESS_PG: could-not-start (no temp dir)" >> "$out"; return 1; }
  PGT_DIR="$w"
  [ "$(id -u)" = 0 ] && chown nobody:nogroup "$w"
  if ! _pgt_as initdb -D "$w/data" -U harness --auth=trust -E UTF8 --no-sync > "$w/initdb.log" 2>&1; then
    echo "HARNESS_PG: could-not-start (initdb failed: $(tail -1 "$w/initdb.log"))" >> "$out"; pgt_stop; return 1
  fi
  # A port in use answers the connect probe and is skipped. A port taken between
  # the probe and the start fails pg_ctl, and the loop tries the next one.
  for n in 0 1 2 3 4 5 6 7 8 9; do
    port=$(( 54320 + ( ($$ + n * 61) % 1000 ) ))
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && continue
    if _pgt_as pg_ctl -D "$w/data" -l "$w/pg.log" -w -t 30 \
         -o "-c listen_addresses=127.0.0.1 -p $port -k $w -c fsync=off" start > /dev/null 2>&1; then up=1; break; fi
  done
  [ "$up" = 1 ] || { echo "HARNESS_PG: could-not-start (pg_ctl start failed on 10 ports: $(tail -1 "$w/pg.log" 2>/dev/null))" >> "$out"; pgt_stop; return 1; }
  PGT_URL="postgresql://harness@127.0.0.1:$port/postgres"
  pgt_local_url "$PGT_URL" || { echo "HARNESS_PG: could-not-start (refused a non-local url)" >> "$out"; PGT_URL=""; pgt_stop; return 1; }
  echo "HARNESS_PG: up (PostgreSQL ${ver:-unknown}, throwaway, $PGT_URL)" >> "$out"
  return 0
}

# pgt_setup <outfile> — run the project's setup command against PGT_URL, if one is set.
# The row POOL_TEST_SETUP_CMD is empty by default (no setup). Its only accepted form is
# `npm run <script>`, with <script> declared in the repo's own package.json: the row
# picks which of the repo's scripts runs, and never carries a command of its own.
# rc is evidence, never a stop.
pgt_setup() {
  local out="$1" c s rc
  c=$(pgt_knob POOL_TEST_SETUP_CMD)
  [ -n "$c" ] || { echo "HARNESS_PG_SETUP: none (no setup command is set)" >> "$out"; return 0; }
  # A regex tests the whole value only with no newline in it, so a two-line value is refused first.
  case "$c" in *$'\n'*|*$'\r'*) echo "HARNESS_PG_SETUP: refused (a multi-line value is not \`npm run <script>\`)" >> "$out"; return 0 ;; esac
  [[ "$c" =~ ^npm\ run\ ([A-Za-z0-9][A-Za-z0-9:_.-]{0,63})$ ]] \
    || { echo "HARNESS_PG_SETUP: refused ('$c' is not \`npm run <script>\`)" >> "$out"; return 0; }
  s="${BASH_REMATCH[1]}"
  jq -e --arg s "$s" '.scripts[$s] // empty' package.json > /dev/null 2>&1 \
    || { echo "HARNESS_PG_SETUP: none (package.json declares no '$s' script)" >> "$out"; return 0; }
  pgt_env || { echo "HARNESS_PG_SETUP: refused (no local url)" >> "$out"; return 0; }
  "${PGT_ENV[@]}" timeout 300 npm run "$s" >> "$out" 2>&1; rc=$?
  echo "HARNESS_PG_SETUP: npm run $s (rc=$rc)" >> "$out"
}

# pgt_stop [outfile] — stop and delete the throwaway. Touches only a dir pgt_start made.
pgt_stop() {
  local w="${PGT_DIR:-}"
  case "$w" in */pgtest.??????) ;; *) PGT_DIR=""; return 0 ;; esac
  [ -f "$w/data/postmaster.pid" ] && _pgt_as pg_ctl -D "$w/data" -m immediate -w -t 20 stop > /dev/null 2>&1
  rm -rf -- "$w"
  PGT_DIR=""; PGT_URL=""
  [ -n "${1:-}" ] && echo "HARNESS_PG: torn down" >> "$1"
  return 0
}

# pgt_serial — rc 0 only when POOL_TEST_POSTGRES_SERIAL resolves to exactly 1.
pgt_serial() { [ "$(pgt_knob POOL_TEST_POSTGRES_SERIAL)" = 1 ]; }

# pgt_failed_files <outfile> [from-line] — print the test files a red run names on
# `FAIL <path>` lines (the vitest and jest default reporters), from line from-line
# (default 1) on, deduped in first-seen order. A path counts only when it is
# relative, has no `..` part, ends in .test.<ext> or .spec.<ext>, and is a regular
# file under the cwd (the repo). rc 0 = a list, rc 1 = none (or the cap is 0),
# rc 2 = more than the cap (nothing printed), rc 3 = a FAIL line names a path that
# does not count (nothing printed): the rerun cannot run that file, so a green
# rerun of the rest must not read as the whole red run gone green (BH-8499 D9).
pgt_failed_files() {
  local out="$1" from="${2:-1}" cap p seen=() n=0 x dup drop=0
  # The row lane.fly-pool.<project>.pool_test_pg_rerun_max_files; 20 is its fallback.
  cap=$(pgt_knob POOL_TEST_PG_RERUN_MAX_FILES)
  [[ "$cap" =~ ^[0-9]{1,4}$ ]] || cap=20
  [[ "$from" =~ ^[0-9]+$ ]] && [ "$from" -ge 1 ] || from=1
  [ "$cap" -gt 0 ] || return 1
  while IFS= read -r p; do
    case "$p" in /*|..|../*|*/..|*/../*) drop=1; continue ;; esac
    [[ "$p" =~ \.(test|spec)\.[cm]?[jt]sx?$ ]] || { drop=1; continue; }
    [ -f "$p" ] && [ ! -L "$p" ] || { drop=1; continue; }
    dup=0; for x in ${seen[@]+"${seen[@]}"}; do [ "$x" = "$p" ] && { dup=1; break; }; done
    [ "$dup" = 1 ] && continue
    seen+=("$p"); n=$((n + 1))
  done < <(tail -n +"$from" "$out" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
             | sed -nE 's/^[[:space:]]*FAIL[[:space:]]+([^[:space:]]+).*$/\1/p')
  [ "$drop" = 0 ] || return 3
  [ "$n" -gt 0 ] || return 1
  [ "$n" -le "$cap" ] || return 2
  printf '%s\n' "${seen[@]}"
  return 0
}

# pgt_run_files <outfile> <script> <file>... — run `npm run <script> -- <file>` once per
# file, each on its own fresh cluster (pgt_start, pgt_setup, the run, pgt_stop), and
# write one HARNESS_PG_FILE line per file. All of it inside the budget knob
# POOL_TEST_PG_SERIAL_BUDGET_S. A start that fails stops the loop, and every
# file left is listed as not run. Returns 0 when every file is rc 0 with no ENOSPC in
# its own lines; else the first red rc (not ENOSPC, not 124 or 125) because a real
# failing test is evidence; else 125, "could not run" (ENOSPC, a timeout, a file not
# run), with PGT_RUN_WHY = "<file>: <why>" for the first such file and PGT_RUN_DISK =
# the first ENOSPC line. PGT_DIR is empty on every return.
pgt_run_files() {
  local out="$1" script="$2" f budget t0 rem rc n0 eno why red="" cnr=0 stop="" srs env=()
  shift 2
  PGT_RUN_WHY=""; PGT_RUN_DISK=""
  [ $# -gt 0 ] || { PGT_RUN_WHY="no file to run"; return 125; }
  # The row lane.fly-pool.<project>.pool_test_pg_serial_budget_s; 1500 (the single
  # run's timeout) is its fallback.
  budget=$(pgt_knob POOL_TEST_PG_SERIAL_BUDGET_S)
  [[ "$budget" =~ ^[0-9]{1,6}$ ]] && [ "$budget" -gt 0 ] || budget=1500
  t0=$(date +%s)
  for f in "$@"; do
    if [ -n "$stop" ]; then
      echo "HARNESS_PG_FILE: $f (not run: $stop)" >> "$out"; continue
    fi
    rem=$(( budget - ( $(date +%s) - t0 ) ))
    if [ "$rem" -le 0 ]; then
      echo "HARNESS_PG_FILE: $f (not run: budget spent)" >> "$out"
      cnr=1; [ -n "$PGT_RUN_WHY" ] || PGT_RUN_WHY="$f: budget spent"; continue
    fi
    pgt_start "$out"; srs=$?
    if [ "$srs" != 0 ]; then
      if [ "$srs" = 2 ]; then why="low disk"; else why="postgres could not start"; fi
      echo "HARNESS_PG_FILE: $f (not run: $why)" >> "$out"
      cnr=1; [ -n "$PGT_RUN_WHY" ] || PGT_RUN_WHY="$f: $why"
      stop="an earlier start failed"; continue
    fi
    pgt_setup "$out"
    env=(); pgt_env && env=("${PGT_ENV[@]}")
    n0=$(wc -l < "$out")
    ${env[@]+"${env[@]}"} timeout "$rem" npm run "$script" -- "$f" >> "$out" 2>&1; rc=$?
    eno=""
    [ "$rc" != 0 ] && eno=$(tail -n +"$((n0 + 1))" "$out" | grep -m1 -i 'no space left on device')
    pgt_stop "$out"
    if [ -n "$eno" ]; then
      echo "HARNESS_PG_FILE: $f (rc=$rc, ENOSPC)" >> "$out"
      cnr=1; [ -n "$PGT_RUN_WHY" ] || PGT_RUN_WHY="$f: ENOSPC"
      [ -n "$PGT_RUN_DISK" ] || PGT_RUN_DISK=$(printf '%s' "$eno" | tr -d '\r' | cut -c1-200)
      continue
    fi
    echo "HARNESS_PG_FILE: $f (rc=$rc)" >> "$out"
    case "$rc" in
      0) ;;
      124|125) cnr=1; [ -n "$PGT_RUN_WHY" ] || PGT_RUN_WHY="$f: rc=$rc (timed out or could not run)" ;;
      *) [ -n "$red" ] || red="$rc" ;;
    esac
  done
  PGT_DIR=""
  [ -n "$red" ] && return "$red"
  [ "$cnr" = 1 ] && return 125
  return 0
}

# pgt_verdict <pgt_run_files rc> — PGT_VERDICT_RC (what HARNESS_EXIT says) and
# PGT_VERDICT (the state word for the HARNESS_PG_SERIAL/HARNESS_PG_RERUN line).
pgt_verdict() {
  case "$1" in
    0)   PGT_VERDICT_RC=0; PGT_VERDICT=green ;;
    125) PGT_VERDICT_RC=could-not-run; PGT_VERDICT="could-not-run (${PGT_RUN_WHY:-no reason recorded})" ;;
    *)   PGT_VERDICT_RC="$1"; PGT_VERDICT="red (rc=$1)" ;;
  esac
}
