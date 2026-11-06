# shellcheck shell=bash
# tests/lib/ledger-worker-fake.bh-9064.sh — SOURCED by the BH-9064 shell suites, never
# executed. A fake `curl` that sends the agent-call ledger and call-guard routes
# to the REAL jobs worker on a node:sqlite file (tests/lib/ledger-worker-fake.bh-9064.mjs),
# so a suite drives bin/agent-call.sh, the client and the route together with no
# network. Every other worker path is a transport failure (curl rc 7): the
# fail-open world the other agent-call suites run in.
#
#   lwf_install <fakebin> <db-file>   write the fake curl; export LWF_DB/LWF_MJS
#   lwf_sql <statement> [<bind>...]   run one statement on the file (JSON rows out)
#   LWF_MODE=down                     every ledger request is a transport failure
#   LWF_MODE=404                      the worker has no ledger route (a box synced
#                                     ahead of the worker deploy)
#   LWF_MODE=500                      every ledger request answers a 500
#   LWF_MODE=garbage                  every ledger request answers 200 with no JSON
#   LWF_MODE=slow                     the worker answers after LWF_SLEEP_S (3) s; a
#                                     curl -m under that is a timeout (rc 28)
#   LWF_REQS=<file>                   each ledger request is appended there
LWF_MJS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ledger-worker-fake.bh-9064.mjs"
export LWF_MJS

lwf_install() {
  local fb="$1"
  export LWF_DB="$2"
  mkdir -p "$fb"
  cat > "$fb/curl" <<'EOF'
#!/bin/bash
url="" data="" method=GET maxt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -m) maxt="$2"; shift 2 ;;
    --connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */api/agent-call-ledger*) ;;
  */api/call-guard*) [ "${LWF_CALL_GUARD:-1}" = 1 ] || exit 7 ;;
  *) exit 7 ;;
esac
case "${LWF_MODE:-up}" in
  down) exit 7 ;;
  404|500|garbage|slow) case "$url" in */api/agent-call-ledger*)
    [ -n "${LWF_REQS:-}" ] && printf '%s %s\n' "$method" "${url#*/api/}" >> "$LWF_REQS"
    case "$LWF_MODE" in
      404) printf '{"error":"unknown endpoint","worker":"harness-jobs"}\n404'; exit 0 ;;
      500) printf '{"error":"boom"}\n500'; exit 0 ;;
      garbage) printf '<html>not json</html>\n200'; exit 0 ;;
      slow) if [ -n "$maxt" ] && [ "$maxt" -lt "${LWF_SLEEP_S:-3}" ]; then sleep "$maxt"; exit 28; fi
            sleep "${LWF_SLEEP_S:-3}" ;;
    esac ;; esac ;;
esac
[ -n "${LWF_REQS:-}" ] && printf '%s %s\n' "$method" "${url#*/api/}" >> "$LWF_REQS"
bf=""
if [ -n "$data" ]; then
  bf=$(mktemp "${TMPDIR:-/tmp}/lwf-body.XXXXXX")
  case "$data" in @*) cat "${data#@}" > "$bf" ;; *) printf '%s' "$data" > "$bf" ;; esac
fi
node "$LWF_MJS" "$LWF_DB" "$method" "$url" ${bf:+"$bf"}
rc=$?
[ -n "$bf" ] && rm -f "$bf"
exit "$rc"
EOF
  chmod +x "$fb/curl"
}

lwf_sql() { node "$LWF_MJS" "$LWF_DB" --sql "$@"; }
