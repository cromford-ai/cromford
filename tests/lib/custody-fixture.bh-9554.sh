# shellcheck shell=bash
# tests/lib/custody-fixture.bh-9554.sh — the shared set-up of the three BH-9554
# custody suites. Sourced after tests/lib/scratch.sh (it needs $T), never run.
#
#   custody_fixture_start   builds a scratch harness $H with the REAL
#                           bin/jobs-client.sh, bin/jobs-client.d/bh-9554-custody.sh
#                           and bin/lib/jobs/custody.sh, starts
#                           tests/lib/custody.bh-9554.mjs (the real jobs worker
#                           on node:sqlite) and exports JOBS_URL to it. It
#                           exits 0 with a SKIP line when node, jobs or curl is
#                           missing or node:sqlite is absent.
#   jc <args...>            runs `bash $H/bin/jobs-client.sh <args...>`;
#                           stdout in $T/out, stderr in $T/err, rc in $RC
#   hook <method> <path> [json]   one fixture hook request; prints the body
#   uniq_key <n>            a ticket key unique to this run: T-<pid>-<n>
CF_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CF_SRV="$CF_REPO/tests/lib/custody.bh-9554.mjs"

custody_fixture_start() {
  command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
    || { echo "SKIP: node, jq or curl missing"; exit 0; }
  H="$T/h"
  mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" || exit 1
  : > "$H/env/global.env"
  local f
  for f in bin/jobs-client.sh bin/jobs-client.d/bh-9554-custody.sh; do
    ( cd "$CF_REPO" && scratch_install_closure "$f" "$H" ) >/dev/null 2>&1 || { echo "setup: could not install $f"; exit 1; }
  done
  [ -f "$H/bin/lib/jobs/custody.sh" ] || { echo "setup: the closure has no bin/lib/jobs/custody.sh"; exit 1; }
  export HARNESS="$H" JOBS_HARNESS="$H" HARNESS_ENV_DIR="$H/env"
  export HARNESS_SECRET=fixture-harness-secret
  export JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
  : > "$T/srv.log"; : > "$T/srv.port"
  node "$CF_SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
  CF_PID=$!
  local _i
  for _i in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$CF_PID" 2>/dev/null || break; sleep 0.05; done
  CF_PORT=$(head -1 "$T/srv.port")
  if [ -z "$CF_PORT" ]; then
    wait "$CF_PID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
    echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
  fi
  export JOBS_URL="http://127.0.0.1:$CF_PORT"
  CF_URL="$JOBS_URL"
  trap 'kill "$CF_PID" 2>/dev/null' EXIT
}

jc() {
  bash "$H/bin/jobs-client.sh" "$@" > "$T/out" 2> "$T/err"
  RC=$?
}

hook() {
  if [ -n "${3:-}" ]; then
    curl -sS -X "$1" -H 'content-type: application/json' -d "$3" "$CF_URL$2"
  else
    curl -sS -X "$1" "$CF_URL$2"
  fi
}

uniq_key() { printf 'T-%s-%s' "$$" "$1"; }
