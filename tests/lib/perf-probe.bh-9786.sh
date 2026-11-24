# shellcheck shell=bash
# tests/lib/perf-probe.bh-9786.sh: the shared setup of the perf probe suites
# (BH-9786). Sourced, never executed:
#   . "$(dirname "$0")/lib/perf-probe.bh-9786.sh" || exit 1
# It sources tests/lib/scratch.sh (so T is the suite's scratch tree) and gives:
#   ppt_tree <name>            a scratch harness at $T/<name>/h with the closure
#                              of bin/perf-probe.sh, catalog/perf-probe.d,
#                              locks, logs, state, flags, a fixture env dir and
#                              a lane registry; sets PPT_H, PPT_D1, PPT_STUB
#   ppt_env_token <project>    the fixture token row for <project>
#   ppt_server_start <name>    the fake app on 127.0.0.1; sets PPT_PORT,
#                              PPT_BASE, PPT_LOG (JSON lines), PPT_STATE
#   ppt_server_stop            stop every fake server this suite started
#   ppt_state <json>           replace the fake app's answers
#   ppt_row <project> <json>   write catalog/perf-probe.d/<project>.json
#   ppt_jobs_stub              the jobs-client stub at $PPT_STUB: it applies the
#                              schema fragment to $PPT_D1 and runs the route's
#                              upsert SQL (SQL.upsert of perf-probe.js)
#   ppt_reqs [jq filter]       the fake log as JSON lines, filtered
#   ppt_lane [env ...]         run the real bin/perf-probe.sh of the tree
# Every case uses its own tree and project name. No $RANDOM; the clock is
# pinned by PERF_PROBE_NOW.
# A suite that sourced scratch.sh itself first keeps its tree (scratch.sh is
# not safe to source twice: it would make a second tree).
[ -n "${SCRATCH:-}" ] || . "$(dirname "${BASH_SOURCE[0]}")/scratch.sh" || return 1
PPT_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PPT_TOKEN=fixture-internal-token
PPT_NOW=2026-11-18T06:17:00Z
PPT_PIDS=()

ppt_tree() {
  PPT_H="$T/$1/h"
  mkdir -p "$PPT_H"/{catalog/perf-probe.d,locks,logs,state,flags,env/projects} || return 1
  scratch_install_closure bin/perf-probe.sh "$PPT_H" >/dev/null || return 1
  # The lane registry: the real perf-probe entry, as bin/lanes-build.sh nests it.
  jq '{lanes: [.]}' "$PPT_REPO/catalog/lanes.d/perf-probe.json" > "$PPT_H/lanes.json" || return 1
  PPT_D1="$T/$1/d1.sqlite"
  PPT_STUB="$T/$1/jobs-stub.sh"
  ppt_jobs_stub || return 1
}

ppt_env_token() {
  local up; up=$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  printf '%s_INTERNAL_API_TOKEN=%s\n' "$up" "$PPT_TOKEN" > "$PPT_H/env/projects/$1.env"
}

ppt_server_start() {
  local d="$T/$1/srv" i=0
  mkdir -p "$d" || return 1
  PPT_LOG="$d/requests.jsonl"; PPT_STATE="$d/state.json"
  : > "$PPT_LOG"; [ -f "$PPT_STATE" ] || echo '{"paths":{}}' > "$PPT_STATE"
  python3 -I "$PPT_REPO/tests/fixtures/perf-probe-fake-server.bh-9786.py" \
    --port-file "$d/port" --log "$PPT_LOG" --state "$PPT_STATE" ${PPT_HANDLERS:+--handlers "$PPT_HANDLERS"} \
    > "$d/server.out" 2>&1 &
  PPT_PIDS+=("$!")
  while [ ! -s "$d/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$d/port" ] || { echo "ppt_server_start: no port after 5s: $(cat "$d/server.out")" >&2; return 1; }
  PPT_PORT=$(cat "$d/port"); PPT_BASE="http://127.0.0.1:$PPT_PORT"
}

ppt_server_stop() {
  local p
  for p in "${PPT_PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  PPT_PIDS=()
}

ppt_state() { printf '%s\n' "$1" > "$PPT_STATE"; }

ppt_row() { printf '%s\n' "$2" > "$PPT_H/catalog/perf-probe.d/$1.json"; }

ppt_jobs_stub() {
  local sql="$T/perf-probe-upsert.sql"
  if [ ! -s "$sql" ]; then
    node --input-type=module -e "const m = await import(process.argv[1]); process.stdout.write(m.SQL.upsert);" \
      "$PPT_REPO/worker/jobs/src/routes/perf-probe.js" > "$sql" || return 1
  fi
  cat > "$PPT_STUB" <<STUB
#!/bin/bash
# jobs-client stub (tests/lib/perf-probe.bh-9786.sh): perf-probe results-put <json>
printf '%s\n' "\$*" >> "$PPT_STUB.calls"
[ -z "\${PPT_JOBS_RC:-}" ] || exit "\$PPT_JOBS_RC"
[ "\$1 \$2" = "perf-probe results-put" ] || exit 4
exec python3 -I - "$PPT_D1" "$PPT_REPO/worker/jobs/schema.d/202611241027-bh-9786-perf-probe.sql" "$sql" "\$3" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT, note TEXT, actor TEXT, updated_at TEXT)")
db.executescript(open(sys.argv[2]).read())
sql = open(sys.argv[3]).read()
b = json.loads(sys.argv[4])
for r in b["rows"]:
    db.execute(sql, (b["project"], r["route"], b["day"], b["kind"], b["run_key"], r.get("ttfb_ms"), r.get("total_ms"),
                     r.get("bytes"), r.get("status"), r["over_budget"], r["outcome"], r.get("loads"), r.get("breaks"),
                     "2026-11-18T06:17:00Z"))
db.commit()
print(json.dumps({"written": len(b["rows"])}))
PY
STUB
  chmod +x "$PPT_STUB"
}

ppt_reqs() { jq -c "${1:-.}" "$PPT_LOG" 2>/dev/null; }

# ppt_count <jq select expr> — how many fake-log lines match.
ppt_count() { jq -c "select($1)" "$PPT_LOG" 2>/dev/null | grep -c . ; }

# ppt_d1 <sql> — rows of the scratch D1 as '|'-joined lines.
ppt_d1() { python3 -I -c 'import sqlite3,sys
db=sqlite3.connect(sys.argv[1])
for r in db.execute(sys.argv[2]): print("|".join("" if v is None else str(v) for v in r))' "$PPT_D1" "$1" 2>/dev/null; }

# PPT_PAUSE_MS=unset leaves PERF_PROBE_PAUSE_MS out of the lane's env, so the
# lane reads it from the registry through lane_knob.
ppt_lane() {
  local -a pause=(PERF_PROBE_PAUSE_MS="${PPT_PAUSE_MS:-0}")
  [ "${PPT_PAUSE_MS:-}" = unset ] && pause=()
  env -u PERF_PROBE_PAUSE_MS HARNESS="$PPT_H" LANE_REGISTRY="$PPT_H/lanes.json" LANE_START_SPREAD_S=0 \
    PERF_PROBE_NOW="$PPT_NOW" PERF_PROBE_ALLOW_LOOPBACK=1 "${pause[@]}" \
    PERF_PROBE_JOBS_CLIENT="$PPT_STUB" "$@" bash "$PPT_H/bin/perf-probe.sh"
}
