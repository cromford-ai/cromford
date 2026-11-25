#!/bin/bash
# tests/lib/fake-flow-world.bh-9924.sh — the fake world of the flow agent
# (BH-9924). Sourced AFTER tests/lib/scratch.sh (it needs T), never run.
# Every service is local: 0 network calls outside 127.0.0.1, 0 model calls.
#
#   ffw_start <epoch>        the REAL jobs worker on node:sqlite through
#                            tests/lib/hosted-board-worker.bh-8918.mjs (real
#                            routes, composed schema, /__sql hook), its clock
#                            pinned to <epoch>. Sets FFW_BASE and FFW_WLOG and
#                            exports JOBS_URL and HARNESS_SECRET. rc 3 = no
#                            node:sqlite (the suite SKIPs).
#   ffw_sql <sql> [param...] one fixture statement through /__sql; prints {rows}
#   ffw_gh                   a fake `gh` first on PATH. `gh api -i -X GET
#                            repos/<o>/<r>/issues|pulls ... -F page=<n>` serves
#                            $T/ffw-gh/<r>/<issues|pulls>.<n>.json (absent = []),
#                            or the status in $T/ffw-gh/<r>/<issues|pulls>.status.
#                            Every call is one line in $T/ffw-gh.log; anything
#                            else answers 404 and is logged too.
#   ffw_net_guard            a `curl` first on PATH that runs the real curl only
#                            for http://127.0.0.1 and logs any other URL to
#                            $T/ffw-net.log and fails (B1).
#   ffw_board                a fake in-app board on 127.0.0.1: GET <base>/x/boards
#                            serves $T/ffw-board/boards.json, GET
#                            <base>/x/boards/<id>/tickets $T/ffw-board/tickets.json.
#                            Sets FFW_BOARD_BASE.
#   ffw_stub_http <status|hang>  a server that answers every request with that
#                            status ({"error":"fixture"}) or never answers.
#                            Prints its base URL.
#   ffw_seed_ticket <project> <key> <verdict> <triaged_at> [queue_status] [job]
#                            a current triage_state row; a build_queue row when
#                            queue_status is not `-`; `running` adds a running
#                            job with a fresh heartbeat, `parked` a parked job.
#   ffw_stop                 kills every server it started.
# It then sources tests/lib/fake-flow-world.d/*.sh in name order (one fragment
# per sibling slice, BH-9924.2 to .9).

FFW_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FFW_PIDS=""
FFW_SECRET=fixture-harness-secret
FFW_REAL_CURL=$(command -v curl)

_ffw_wait_port() { # _ffw_wait_port <file> <pid>
  local _
  for _ in $(seq 1 200); do [ -s "$1" ] && break; kill -0 "$2" 2>/dev/null || break; sleep 0.05; done
  head -1 "$1" 2>/dev/null
}

ffw_start() {
  local epoch="${1:?epoch}" pid port
  FFW_WLOG="$T/ffw-worker.log"; : > "$FFW_WLOG"
  node "$FFW_DIR/hosted-board-worker.bh-8918.mjs" "$FFW_WLOG" "$epoch" > "$T/ffw-worker.port" 2> "$T/ffw-worker.err" &
  pid=$!; FFW_PIDS="$FFW_PIDS $pid"
  port=$(_ffw_wait_port "$T/ffw-worker.port" "$pid")
  if [ -z "$port" ]; then wait "$pid"; return $?; fi
  FFW_BASE="http://127.0.0.1:$port"
  export JOBS_URL="$FFW_BASE" HARNESS_SECRET="$FFW_SECRET"
  return 0
}

ffw_sql() {
  "$FFW_REAL_CURL" -sS -X POST "$FFW_BASE/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"
}

ffw_gh() {
  mkdir -p "$T/ffw-stub" "$T/ffw-gh"; : > "$T/ffw-gh.log"
  cat > "$T/ffw-stub/gh" <<EOF
#!/bin/bash
# fake gh (tests/lib/fake-flow-world.bh-9924.sh): fixture files, no network
D="$T/ffw-gh"
echo "\$*" >> "$T/ffw-gh.log"
[ "\$1" = api ] || { echo "fake gh: only api" >&2; exit 1; }
shift; m=GET; path=""; page=1
while [ \$# -gt 0 ]; do
  case "\$1" in
    -i) shift ;;
    -X) m="\$2"; shift 2 ;;
    -F|-f) case "\$2" in page=*) page="\${2#page=}" ;; esac; shift 2 ;;
    -H) shift 2 ;;
    *) [ -z "\$path" ] && path="\$1"; shift ;;
  esac
done
send() { printf 'HTTP/2 %s\r\nserver: fixture\r\n\r\n%s' "\$1" "\$2"; [ "\${1:0:1}" = 2 ] || exit 1; exit 0; }
[ "\$m" = GET ] || send 404 '{"message":"fixture refuses writes"}'
case "\$path" in
  repos/*/*/issues|repos/*/*/pulls)
    r=\$(echo "\$path" | cut -d/ -f3); kind=\${path##*/}
    if [ -f "\$D/\$r/\$kind.status" ]; then send "\$(cat "\$D/\$r/\$kind.status")" '{"message":"fixture"}'; fi
    if [ -f "\$D/\$r/\$kind.\$page.json" ]; then send 200 "\$(cat "\$D/\$r/\$kind.\$page.json")"; fi
    send 200 '[]' ;;
  *) send 404 '{"message":"Not Found"}' ;;
esac
EOF
  chmod +x "$T/ffw-stub/gh"
  case ":$PATH:" in *":$T/ffw-stub:"*) ;; *) export PATH="$T/ffw-stub:$PATH" ;; esac
}

ffw_net_guard() {
  mkdir -p "$T/ffw-stub"; : > "$T/ffw-net.log"
  cat > "$T/ffw-stub/curl" <<EOF
#!/bin/bash
# fake curl guard (tests/lib/fake-flow-world.bh-9924.sh): 127.0.0.1 only
for a in "\$@"; do
  case "\$a" in
    http://127.0.0.1:*|http://127.0.0.1/*) ;;
    http://*|https://*) echo "\$a" >> "$T/ffw-net.log"; exit 7 ;;
  esac
done
exec "$FFW_REAL_CURL" "\$@"
EOF
  chmod +x "$T/ffw-stub/curl"
  case ":$PATH:" in *":$T/ffw-stub:"*) ;; *) export PATH="$T/ffw-stub:$PATH" ;; esac
}

# _ffw_py <script> <port-file> — a python http server in the background.
_ffw_py() {
  python3 -c "$1" "${@:3}" > "$2" 2>/dev/null &
  FFW_PIDS="$FFW_PIDS $!"
  _ffw_wait_port "$2" "$!"
}

ffw_board() {
  local port
  mkdir -p "$T/ffw-board"
  port=$(_ffw_py '
import http.server, sys, os
D = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(os.path.join(D, "requests.log"), "a") as f: f.write(self.path + " " + self.headers.get("Authorization", "") + "\n")
        name = "boards.json" if self.path.endswith("/boards") else ("tickets.json" if self.path.endswith("/tickets") else None)
        st = os.path.join(D, "status")
        if name is None or os.path.exists(st):
            code = int(open(st).read().strip()) if os.path.exists(st) else 404
            self.send_response(code); self.end_headers(); self.wfile.write(b"{}"); return
        body = open(os.path.join(D, name), "rb").read()
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers(); self.wfile.write(body)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.timeout = 300
s.serve_forever()
' "$T/ffw-board.port" "$T/ffw-board")
  FFW_BOARD_BASE="http://127.0.0.1:$port"
}

ffw_stub_http() {
  local mode="${1:?status|hang}" port
  port=$(_ffw_py '
import http.server, sys, time
mode = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self):
        if mode == "hang":
            time.sleep(30); return
        self.send_response(int(mode)); self.send_header("content-type", "application/json"); self.end_headers()
        self.wfile.write(b"{\"error\":\"fixture\",\"outcome\":\"claimed\"}")
    do_GET = do_POST = do_PUT = answer
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
' "$T/ffw-stub-$mode.port" "$mode")
  printf 'http://127.0.0.1:%s\n' "$port"
}

ffw_seed_ticket() {
  local p="$1" k="$2" v="$3" at="$4" q="${5:--}" job="${6:-}" id
  ffw_sql "INSERT INTO triage_state (project, ticket_key, input_hash, verdict, waiting_on, verdict_hash, triaged_at, updated_at) VALUES (?,?,?,?,?,?,?,?)" \
    "$p" "$k" h1 "$v" team h1 "$at" "$at" >/dev/null
  if [ "$q" != - ]; then
    ffw_sql "INSERT INTO build_queue (project, ticket_key, status, enqueued_at, updated_at) VALUES (?,?,?,?,?)" "$p" "$k" "$q" "$at" "$at" >/dev/null
  fi
  id="job-$p-$k"
  case "$job" in
    running)
      ffw_sql "INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)" \
        "$id" "$p" "$k" build box-fixture execute running "$at" "$at" >/dev/null
      ffw_sql "INSERT INTO job_heartbeats (job_id, beat_at, box) VALUES (?,?,?)" "$id" "${FFW_NOW_ISO:-$at}" box-fixture >/dev/null ;;
    parked)
      ffw_sql "INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)" \
        "$id" "$p" "$k" build box-fixture execute parked "$at" "$at" >/dev/null ;;
  esac
}

ffw_stop() {
  local pid
  for pid in $FFW_PIDS; do kill "$pid" 2>/dev/null; done
  FFW_PIDS=""
}

# The sibling fragments, in name order.
for _ffw_f in "$FFW_DIR"/fake-flow-world.d/*.sh; do
  [ -f "$_ffw_f" ] || continue
  # shellcheck source=/dev/null
  . "$_ffw_f" || { echo "fake-flow-world: $_ffw_f did not load" >&2; return 1 2>/dev/null; }
  FFW_FRAGMENTS="${FFW_FRAGMENTS:-}${FFW_FRAGMENTS:+ }$(basename "$_ffw_f" .sh)"
done
unset _ffw_f
