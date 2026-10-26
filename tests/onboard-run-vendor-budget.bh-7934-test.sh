#!/bin/bash
# tests/onboard-run-vendor-budget.bh-7934-test.sh — BH-7934.2 (#7949), the
# scalable-tests budget (BH-7563 rule 6) for bin/onboard-run.sh: a full run in
# the PR suite makes 0 vendor calls. The only vendor the runner reaches is gh
# (obs_smoke's 1-issue read); every other request goes to the jobs worker,
# which here is the REAL worker on 127.0.0.1 (tests/lib/onboarding-worker.bh-7949.mjs).
#
#   V1  an all-pass run with the gh fake on PATH: 0 lines in vendor.log, and
#       every URL curl was given is http://127.0.0.1:<port>/...
#   V2  the same run with a tripwire gh (it logs `REAL gh <args>` and exits 1):
#       the budget check reports red, so V1 is not vacuous
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/onboard-run-vendor-budget.bh-7934-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/worker-catalogs.sh
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
"$DIR/bin/context-budgets-build.sh" --compose >/dev/null || { echo "setup: cannot compose catalog/context-budgets.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }
[ -f "$DIR/bin/onboard-run.sh" ] || { echo "FAIL setup: bin/onboard-run.sh missing"; exit 1; }
REAL_CURL=$(command -v curl)

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$H/prompts" "$T/stub"
: > "$H/env/global.env"
for L in bin/onboard-run.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$DIR/catalog/lanes.json" "$H/catalog/lanes.json"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/bash\necho 3\n' > "$H/bin/fleet-conf.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/postmerge-qa.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/healthcheck.sh"
# gh: the fake answers when ONBOARD_TEST_GH_FAKE is set; without it, every
# call is a vendor call and is logged as one (the tripwire).
cat > "$T/stub/gh" <<EOF
#!/bin/bash
if [ -n "\${ONBOARD_TEST_GH_FAKE:-}" ]; then printf 'HTTP/1.1 200 OK\\r\\n\\r\\n[]\\n'; exit 0; fi
echo "REAL gh \$*" >> "$T/vendor.log"; exit 1
EOF
# curl: logs every URL it is given, then runs the real curl.
cat > "$T/stub/curl" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in http://*|https://*) echo "\$a" >> "$T/curl.log" ;; esac; done
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$H/bin/"*.sh "$T/stub/gh" "$T/stub/curl"
echo "# acme-os" > "$H/prompts/acme-os.md"
export PATH="$T/stub:$PATH"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env" BOX_NAME=hub HARNESS_SECRET=tok-fixture-bh7949
export JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10
export ONBOARD_STATIONS_LIB="$DIR/tests/lib/onboard-stations-stub.bh-7949.sh" OBS_CALLS="$T/obs.calls"

: > "$T/srv.log"; : > "$T/srv.port"
node "$DIR/tests/lib/onboarding-worker.bh-7949.mjs" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
trap 'kill "$SPID" 2>/dev/null; __scratch_exit_trap' EXIT

# budget_ok — rc 0 when the run made 0 vendor calls: vendor.log is empty and
# every URL curl got is on the local worker.
budget_ok() {
  [ ! -s "$T/vendor.log" ] || return 1
  [ -s "$T/curl.log" ] || return 1
  ! grep -qv "^http://127\.0\.0\.1:$PORT/" "$T/curl.log"
}
# one_run <key> — a fresh run, then one runner tick on it; rc of the tick.
one_run() {
  local id
  : > "$T/vendor.log"; : > "$T/curl.log"; : > "$OBS_CALLS"
  id=$("$REAL_CURL" -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H "idempotency-key: $1" \
    -d '{"repo":"example-org/acme-os","project":"acme-os","tracker":"github-issues","box":"shared","prod":"https://acme.example.test"}' \
    "$JOBS_URL/api/onboarding/runs" | jq -r .id)
  : > "$T/curl.log"
  bash "$H/bin/onboard-run.sh" "$id" > "$T/out" 2>&1
}

echo "V1: an all-pass run makes 0 vendor calls"
ONBOARD_TEST_GH_FAKE=1 one_run key-fixture-v1; RC=$?
[ "$RC" = 0 ] && ok "V1 the run finished (exit 0)" || bad "V1 rc=$RC out=$(cat "$T/out")"
[ "$(grep -c . "$T/curl.log")" -ge 16 ] && ok "V1 curl carried the worker requests ($(grep -c . "$T/curl.log"))" || bad "V1 curl.log: $(cat "$T/curl.log")"
budget_ok && ok "V1 budget: 0 vendor calls, every request to 127.0.0.1" || bad "V1 vendor.log: $(cat "$T/vendor.log") curl: $(grep -v 127.0.0.1 "$T/curl.log")"

echo "V2: the tripwire gh turns the budget red"
one_run key-fixture-v2; RC=$?
grep -q '^REAL gh api -i -X GET repos/example-org/acme-os/issues' "$T/vendor.log" && ok "V2 the tripwire saw the gh call" || bad "V2 vendor.log: $(cat "$T/vendor.log")"
budget_ok && bad "V2 the budget check stayed green with a vendor call" || ok "V2 the budget check reports red"
[ "$RC" = 1 ] && ok "V2 the smoke station failed on the tripwire (exit 1)" || bad "V2 rc=$RC"

echo "onboard-run-vendor-budget.bh-7934: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
