#!/bin/bash
# tests/onboard-envelope.bh-7937-test.sh — BH-7968 (BH-7937.4): bin/onboard-run.sh
# consumes the AI-account envelope of its run with bin/envelope-consume.sh,
# through obe_consume in bin/lib/onboard-envelopes.sh.
# The consumer is a fake named by ONBOARD_ENVELOPE_CONSUME: it logs its argv
# to a file and exits with $FAKE_RC. Nothing here reads a real envelope.
#
#   E1 a run with ai_envelope and queued steps: the consumer runs once, argv = that id
#   E2 rc 0  -> `envelope <run> <id> applied`
#   E3 rc 3  -> `envelope <run> <id> gone`; obe_consume returns 0
#   E4 rc 1, 2, 4 -> `failed rc=<n>`, returns 0
#   E5 rc 75 -> `deferred rc=75`, returns 0
#   E6 no ai_envelope -> 0 calls, no `envelope` line
#   E7 an ai_envelope that is not a lower-case UUID -> 0 calls, `refused bad id`
#   E8 a run with no queued step -> 0 calls
#   E9 bin/onboard-run.sh with ONBOARD_RUN_LIB_ONLY=1 loads and defines obe_consume
#   E10 the run's project is not registered (the fake registry reader does not
#      list it): 0 calls, `held (project <p> not registered)`, returns 0
#   E11 the REAL lane: a run created through POST /api/onboarding/runs with
#      ai_envelope, run by bin/onboard-run.sh against the REAL jobs worker
#      (tests/lib/onboarding-worker.bh-7949.mjs) for a project that is not
#      registered yet: the consume is held before the first station, the
#      consumer runs once with the id right after the register station (which
#      registers the project), before the next station, and the run finishes done
#   E12 two calls in one process: the consumer runs once
# The real consumer and an unregistered project are pinned in
# tests/secrets-apply-held.bh-7968-test.sh (H1-H4).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/onboard-envelope.bh-7937-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$DIR/bin/onboard-run.sh"
LIB="$DIR/bin/lib/onboard-envelopes.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
[ -f "$SCRIPT" ] || { echo "FAIL setup: $SCRIPT missing"; exit 1; }

# Fixture ids are made at run time (no literal id in a test file).
UUID=$(tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid)
RUN="ob_$(head -c 10 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# The fake consumer: argv to $T/consume.log, exit $FAKE_RC.
mkdir -p "$T/fake" "$T/lib/logs"
# The fake registry reader: `--projects` prints $T/projects.
printf 'acme-os\n' > "$T/projects"
cat > "$T/fake/fleet-conf.sh" <<EOF
#!/bin/bash
[ "\$1" = --projects ] && cat "$T/projects"
exit 0
EOF
chmod +x "$T/fake/fleet-conf.sh"
cat > "$T/fake/envelope-consume.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/consume.log"
exit "\${FAKE_RC:-0}"
EOF
chmod +x "$T/fake/envelope-consume.sh"

# runjson <ai_envelope|-> [step-state] — a GET /api/onboarding/runs/<id> answer.
runjson() {
  jq -nc --arg a "$1" --arg s "${2:-queued}" '{run:{id:"'"$RUN"'", inputs:({project:"acme-os"} + (if $a == "-" then {} else {ai_envelope:$a} end))},
    steps:[{station:"register", state:$s}, {station:"prompt", state:$s}]}' > "$T/run.json"
}
# lib <rc> — source the lib, give it the runner's `line` logger, call obe_consume once.
lib() {
  : > "$T/consume.log"; rm -f "$T/lib/logs/onboard-run.log"
  ( export ONBOARD_ENVELOPE_CONSUME="$T/fake/envelope-consume.sh" ONBOARD_FLEET_CONF="$T/fake/fleet-conf.sh" FAKE_RC="$1"
    line() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$T/lib/logs/onboard-run.log"; }
    # shellcheck source=bin/lib/onboard-envelopes.sh
    . "$LIB" || exit 98
    declare -F obe_consume >/dev/null || exit 97
    obe_consume "$T/run.json" "$RUN"
    [ -z "${TWICE:-}" ] || obe_consume "$T/run.json" "$RUN" ); echo $? > "$T/lib.rc"
}
calls() { [ -s "$T/consume.log" ] && wc -l < "$T/consume.log" || echo 0; }
elines() { local n; n=$(grep -c " envelope " "$T/lib/logs/onboard-run.log" 2>/dev/null); echo "${n:-0}"; }
lastline() { tail -1 "$T/lib/logs/onboard-run.log" 2>/dev/null | cut -d' ' -f2-; }

echo "E1/E2: rc 0"
runjson "$UUID"; lib 0
[ "$(cat "$T/lib.rc")" = 0 ] && ok "E1 obe_consume returns 0" || bad "E1 rc=$(cat "$T/lib.rc")"
[ "$(calls)" = 1 ] && [ "$(cat "$T/consume.log")" = "$UUID" ] && ok "E1 the consumer ran once with exactly the id" || bad "E1 calls: $(cat "$T/consume.log")"
[ "$(lastline)" = "envelope $RUN $UUID applied" ] && ok "E2 log: applied" || bad "E2 log: $(lastline)"

echo "E3: rc 3"
lib 3
[ "$(cat "$T/lib.rc")" = 0 ] && [ "$(lastline)" = "envelope $RUN $UUID gone" ] && ok "E3 gone, returns 0" || bad "E3 rc=$(cat "$T/lib.rc") log=$(lastline)"

echo "E4: rc 1, 2, 4"
for rc in 1 2 4; do
  lib "$rc"
  [ "$(cat "$T/lib.rc")" = 0 ] && [ "$(lastline)" = "envelope $RUN $UUID failed rc=$rc" ] && ok "E4 rc $rc: failed rc=$rc, returns 0" || bad "E4 rc $rc: rc=$(cat "$T/lib.rc") log=$(lastline)"
done

echo "E5: rc 75"
lib 75
[ "$(cat "$T/lib.rc")" = 0 ] && [ "$(lastline)" = "envelope $RUN $UUID deferred rc=75" ] && ok "E5 deferred rc=75, returns 0" || bad "E5 rc=$(cat "$T/lib.rc") log=$(lastline)"

echo "E6: no ai_envelope"
runjson -; lib 0
[ "$(calls)" = 0 ] && [ "$(elines)" = 0 ] && [ "$(cat "$T/lib.rc")" = 0 ] && ok "E6 no call, no envelope line" || bad "E6 calls=$(calls) lines=$(elines)"

echo "E7: a bad id"
for b in "$(tr '[:lower:]' '[:upper:]' <<<"$UUID")" "${UUID//-/}" "../x" "$UUID x"; do
  runjson "$b"; lib 0
  [ "$(calls)" = 0 ] && [ "$(lastline)" = "envelope $RUN refused bad id" ] && [ "$(cat "$T/lib.rc")" = 0 ] \
    && ok "E7 '$b': no call, refused bad id" || bad "E7 '$b': calls=$(calls) log=$(lastline)"
done

echo "E8: no queued step"
runjson "$UUID" done; lib 0
[ "$(calls)" = 0 ] && [ "$(elines)" = 0 ] && ok "E8 no call" || bad "E8 calls=$(calls) lines=$(elines)"

echo "E9: the lane loads the lib"
( export HARNESS="$T/lib" ONBOARD_RUN_LIB_ONLY=1
  # shellcheck source=bin/onboard-run.sh
  . "$SCRIPT" || exit 98
  declare -F obe_consume >/dev/null || exit 97
  declare -F _obr_envelopes >/dev/null && exit 96
  exit 0 ); RC=$?
[ "$RC" = 0 ] && ok "E9 onboard-run.sh (lib only) defines obe_consume" || bad "E9 rc=$RC"

echo "E10: the project is not registered"
runjson "$UUID"; printf '' > "$T/projects"; lib 0
[ "$(calls)" = 0 ] && [ "$(lastline)" = "envelope $RUN $UUID held (project acme-os not registered)" ] && [ "$(cat "$T/lib.rc")" = 0 ] \
  && ok "E10 no call, held, returns 0" || bad "E10 calls=$(calls) log=$(lastline) rc=$(cat "$T/lib.rc")"
printf 'other\nacme-os-2\n' > "$T/projects"; lib 0
[ "$(calls)" = 0 ] && [ "$(lastline)" = "envelope $RUN $UUID held (project acme-os not registered)" ] \
  && ok "E10 a longer project name does not count as registered" || bad "E10 prefix: calls=$(calls) log=$(lastline)"
printf 'acme-os\n' > "$T/projects"

echo "E12: two calls in one process"
TWICE=1 lib 0
[ "$(calls)" = 1 ] && [ "$(elines)" = 1 ] && ok "E12 the consumer runs once" || bad "E12 calls=$(calls) lines=$(elines)"

# ── E11: the REAL lane over the REAL worker ───────────────────────────────────
echo "E11: the real lane"
command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || { echo "  skip E11: node or curl missing"; E11=skip; }
if [ "${E11:-}" != skip ]; then
  # shellcheck source=tests/lib/worker-catalogs.sh
  . "$DIR/tests/lib/worker-catalogs.sh" || exit 1
  worker_catalogs "$DIR" || exit 1
  "$DIR/bin/context-budgets-build.sh" --compose >/dev/null || { echo "setup: cannot compose catalog/context-budgets.json"; exit 1; }
  H="$T/h"
  mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$H/prompts" "$T/stub"
  : > "$H/env/global.env"
  for L in bin/onboard-run.sh bin/jobs-client.sh; do
    ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
  done
  cp "$DIR/catalog/lanes.json" "$H/catalog/lanes.json"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\n' "$T" > "$H/bin/lane-alert.sh"
  # The registry reader: `--projects` prints $T/x1.projects, which the
  # register station below writes, as the real obs_register writes the row.
  printf '' > "$T/x1.projects"
  printf '#!/bin/bash\n[ "$1" = --projects ] && cat "%s/x1.projects"\n[ "$2" = offset ] && echo 3\nexit 0\n' "$T" > "$H/bin/fleet-conf.sh"
  cat > "$T/x1-stations.sh" <<EOF
. "$DIR/tests/lib/onboard-stations-stub.bh-7949.sh"
obs_register() { _obs_stub register && echo "\$PROJECT" >> "$T/x1.projects"; }
EOF
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/postmerge-qa.sh"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/healthcheck.sh"
  printf '#!/bin/bash\nprintf '"'"'HTTP/1.1 200 OK\\r\\n\\r\\n[]\\n'"'"'\n' > "$T/stub/gh"
  chmod +x "$H/bin/"*.sh "$T/stub/gh"
  echo "# acme-x1" > "$H/prompts/acme-x1.md"
  : > "$T/srv.log"; : > "$T/srv.port"
  node "$DIR/tests/lib/onboarding-worker.bh-7949.mjs" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
  SPID=$!
  for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/srv.port")
  if [ -z "$PORT" ]; then
    wait "$SPID"; [ "$?" = 3 ] && { echo "  skip E11: node:sqlite unavailable"; E11=skip; } || { echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1; }
  fi
fi
if [ "${E11:-}" != skip ]; then
  trap 'kill "$SPID" 2>/dev/null; __scratch_exit_trap' EXIT
  export JOBS_URL="http://127.0.0.1:$PORT" HARNESS_SECRET=tok-fixture-bh7949  # the secret tests/lib/onboarding-worker.bh-7949.mjs expects
  AUTH="authorization: Bearer $HARNESS_SECRET"
  BODY=$(jq -nc --arg a "$UUID" '{repo:"example-org/acme-x1", project:"acme-x1", tracker:"github-issues", box:"shared", ai_envelope:$a}')
  X=$(curl -sS -X POST -H "$AUTH" -H "idempotency-key: key-fixture-bh7968-x1" -H 'content-type: application/json' -d "$BODY" "$JOBS_URL/api/onboarding/runs" | jq -r '.id // empty')
  [ -n "$X" ] && ok "E11 the worker took a run with ai_envelope" || bad "E11 create failed: $BODY"
  : > "$T/consume.log"; : > "$T/obs.calls"
  ( export PATH="$T/stub:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" BOX_NAME=hub \
      JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10 \
      ONBOARD_STATIONS_LIB="$T/x1-stations.sh" OBS_CALLS="$T/obs.calls" \
      ONBOARD_ENVELOPE_CONSUME="$T/fake/envelope-consume.sh" FAKE_RC=0
    bash "$H/bin/onboard-run.sh" "$X" ) > "$T/x1.out" 2>&1; RC=$?
  [ "$RC" = 0 ] && ok "E11 the lane exits 0" || bad "E11 rc=$RC out=$(cat "$T/x1.out")"
  [ "$(calls)" = 1 ] && [ "$(cat "$T/consume.log")" = "$UUID" ] && ok "E11 the consumer ran once with the run's id" || bad "E11 calls: $(cat "$T/consume.log")"
  XL="$H/logs/onboard-run.log"
  grep -q " envelope $X $UUID applied$" "$XL" && ok "E11 log: envelope applied" || bad "E11 log: $(cat "$XL")"
  HE=$(grep -n " envelope $X $UUID held (project acme-x1 not registered)$" "$XL" | head -1 | cut -d: -f1)
  ST=$(grep -n " step $X " "$XL" | head -1 | cut -d: -f1)
  [ -n "$HE" ] && [ -n "$ST" ] && [ "$HE" -lt "$ST" ] && ok "E11 before the first station the consume is held (project not registered)" || bad "E11 held@$HE step@$ST"
  RG=$(grep -n " step $X register done " "$XL" | head -1 | cut -d: -f1)
  EN=$(grep -n " envelope $X $UUID applied$" "$XL" | head -1 | cut -d: -f1)
  NX=$(grep -n " step $X prompt " "$XL" | head -1 | cut -d: -f1)
  [ -n "$RG" ] && [ -n "$EN" ] && [ -n "$NX" ] && [ "$RG" -lt "$EN" ] && [ "$EN" -lt "$NX" ] \
    && ok "E11 the consume comes right after the register station" || bad "E11 order: register@$RG envelope@$EN prompt@$NX"
  grep -q " done $X acme-x1$" "$XL" && ok "E11 the run finished done" || bad "E11 log: $(cat "$XL")"
  : > "$T/consume.log"
  ( export PATH="$T/stub:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" BOX_NAME=hub JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_RETRIES=0 \
      ONBOARD_ENVELOPE_CONSUME="$T/fake/envelope-consume.sh"
    bash "$H/bin/onboard-run.sh" "$X" ) > "$T/x1b.out" 2>&1
  [ "$(calls)" = 0 ] && ok "E11 a second tick on the done run calls nothing" || bad "E11 second tick calls: $(cat "$T/consume.log")"
fi

echo "onboard-envelope: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
