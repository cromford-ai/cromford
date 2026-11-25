# shellcheck shell=bash
# tests/lib/perf-probe-warm.bh-9792.sh: the shared setup of the warm-up and
# keep-warm suites (BH-9792). Sourced, never executed:
#   . "$(dirname "$0")/lib/perf-probe-warm.bh-9792.sh" || exit 1
# It sources tests/lib/perf-probe.bh-9786.sh (and through it scratch.sh) and
# gives:
#   pwt_tree <name>        ppt_tree <name>, plus the closures of
#                          bin/perf-probe-warm.sh and bin/perf-probe-keepwarm.sh,
#                          a lane registry with the three perf-probe lanes, the
#                          gh stub dir PWT_GH and the warm jobs stub PWT_JC
#   pwt_server <name>      ppt_server_start with the repo's fake handlers plus
#                          a sequence handler: state {"seq": {"<path>":
#                          [{"status":..,"delay_ms":..}, ...]}} answers the
#                          n-th request of <path> with item n (the last item
#                          repeats). A path in state.paths wins over seq.
#   pwt_gh <kind> <status> <body>   the gh stub's answer for kind
#                          deployments | statuses
#   pwt_gh_calls           the API paths the gh stub saw, one per line
#   pwt_lane <script> [env ...]     run the tree's bin/<script> like ppt_lane
#   pwt_warm_rows <project>         perf_probe_warm rows of the scratch D1
# Every case uses its own tree and project name; the clock is pinned.
[ -n "${PPT_REPO:-}" ] || . "$(dirname "${BASH_SOURCE[0]}")/perf-probe.bh-9786.sh" || return 1

pwt_tree() {
  ppt_tree "$1" || return 1
  scratch_install_closure bin/perf-probe-warm.sh "$PPT_H" >/dev/null || return 1
  scratch_install_closure bin/perf-probe-keepwarm.sh "$PPT_H" >/dev/null || return 1
  jq -s '{lanes: .}' "$PPT_REPO/catalog/lanes.d/perf-probe.json" "$PPT_REPO/catalog/lanes.d/perf-probe-warm.json" \
    "$PPT_REPO/catalog/lanes.d/perf-probe-keepwarm.json" > "$PPT_H/lanes.json" || return 1
  PWT_GH="$T/$1/gh"
  mkdir -p "$PWT_GH/bin" || return 1
  : > "$PWT_GH/calls"
  cat > "$PWT_GH/bin/gh" <<GH
#!/bin/bash
# gh stub (tests/lib/perf-probe-warm.bh-9792.sh): gh api -i -X <m> <path> ...
p=""; for a in "\$@"; do case "\$a" in repos/*) p=\$a ;; esac; done
printf '%s\n' "\$p" >> "$PWT_GH/calls"
case "\$p" in */statuses*) k=statuses ;; */deployments*) k=deployments ;; *) k=other ;; esac
st=\$(cat "$PWT_GH/\$k.status" 2>/dev/null); [ -n "\$st" ] || st=404
printf 'HTTP/2.0 %s X\r\ncontent-type: application/json\r\n\r\n' "\$st"
cat "$PWT_GH/\$k.json" 2>/dev/null
case "\$st" in 2*) exit 0 ;; *) exit 1 ;; esac
GH
  chmod +x "$PWT_GH/bin/gh"
  PWT_JC="$T/$1/jobs-warm-stub.sh"
  _pwt_jobs_stub || return 1
}

_pwt_jobs_stub() {
  local sql="$T/perf-probe-warm-sql.json" frag
  frag=$(printf '%s\n' "$PPT_REPO"/worker/jobs/schema.d/*-bh-9792-perf-probe-warm.sql | head -n 1)
  if [ ! -s "$sql" ]; then
    node --input-type=module -e "const m = await import(process.argv[1]); process.stdout.write(JSON.stringify(m.SQL));" \
      "$PPT_REPO/worker/jobs/src/routes/perf-probe-warm.js" > "$sql" || return 1
  fi
  cat > "$PWT_JC" <<STUB
#!/bin/bash
# warm jobs-client stub (tests/lib/perf-probe-warm.bh-9792.sh): perf-probe
# warm-get <project> | warm-put <json> on the scratch D1 through the route's
# own SQL; results-put goes to the tracer stub. PWT_RC_<op> forces an rc.
printf '%s\n' "\$*" >> "$PWT_JC.calls"
op=\${2:-}; v="PWT_RC_\${op//-/_}"
[ -z "\${!v:-}" ] || exit "\${!v}"
case "\$1 \$op" in
  "perf-probe results-put") exec "$PPT_STUB" "\$@" ;;
  "perf-probe warm-get"|"perf-probe warm-put") ;;
  *) exit 4 ;;
esac
exec python3 -I - "$PPT_D1" "$frag" "$sql" "\$op" "\${3:-}" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript(open(sys.argv[2]).read())
sql = json.load(open(sys.argv[3]))
if sys.argv[4] == "warm-get":
    db.row_factory = sqlite3.Row
    r = db.execute(sql["latest"], (sys.argv[5],)).fetchone()
    print(json.dumps({"row": dict(r) if r else None}))
else:
    b = json.loads(sys.argv[5])
    c = db.execute(sql["insert"], (b["project"], b["deployment_id"], b["outcome"], b.get("routes", 0), b.get("over", 0),
                                   "2026-11-18T06:17:00Z"))
    db.commit()
    print(json.dumps({"created": c.rowcount}))
PY
STUB
  chmod +x "$PWT_JC"
}

pwt_server() {
  local hd="$T/$1/handlers"
  mkdir -p "$hd" || return 1
  cp "$PPT_REPO"/tests/fixtures/perf-probe-fake.d/*.py "$hd/" || return 1
  cat > "$hd/aa_seq.py" <<'PY'
# The sequence handler of the BH-9792 suites (tests/lib/perf-probe-warm.bh-9792.sh).
import time
COUNT = {}


def handle(req, state):
    seq = (state.get("seq") or {}).get(req["path"])
    if not seq:
        return None
    n = COUNT.get(req["path"], 0)
    COUNT[req["path"]] = n + 1
    spec = seq[min(n, len(seq) - 1)]
    if spec.get("delay_ms"):
        time.sleep(spec["delay_ms"] / 1000.0)
    return {"status": spec.get("status", 200), "body": "seq"}
PY
  PPT_HANDLERS="$hd" ppt_server_start "$1"
}

pwt_gh() { printf '%s\n' "$2" > "$PWT_GH/$1.status"; printf '%s\n' "$3" > "$PWT_GH/$1.json"; }

pwt_gh_calls() { grep -v '^$' "$PWT_GH/calls" 2>/dev/null; }

pwt_lane() {
  local s="$1"; shift
  env -u PERF_PROBE_PAUSE_MS HARNESS="$PPT_H" LANE_REGISTRY="$PPT_H/lanes.json" LANE_START_SPREAD_S=0 \
    PERF_PROBE_NOW="$PPT_NOW" PERF_PROBE_ALLOW_LOOPBACK=1 PERF_PROBE_PAUSE_MS=0 GH_ETAG=0 PERF_PROBE_HEALTH_WAIT_S=2 PERF_PROBE_HEALTH_POLL_S=1 \
    PATH="$PWT_GH/bin:$PATH" PERF_PROBE_JOBS_CLIENT="$PWT_JC" "$@" bash "$PPT_H/bin/$s"
}

pwt_warm_rows() { ppt_d1 "SELECT deployment_id,outcome,routes,over FROM perf_probe_warm WHERE project='$1' ORDER BY warmed_at, deployment_id"; }
