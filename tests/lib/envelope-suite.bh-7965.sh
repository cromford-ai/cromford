# tests/lib/envelope-suite.bh-7965.sh — the shared setup of the BH-7965 hub
# suites (envelope-keygen, envelope-consume, secrets-apply,
# secret-envelope-sweep, vendor-probe-budget). Sourced after tests/lib/scratch.sh,
# never run. Not a suite: tests/*.sh does not glob tests/lib/.
#
#   es_init                 scratch harness $H with the hub scripts and their
#                           closures, a scratch fleet.conf (demo 192.0.2.10,
#                           other 192.0.2.11), a PATH shim ssh, the fake vendor
#                           fixtures in $T/vf, and the env every script reads
#   es_srv <name> [VAR=v]   start tests/lib/envelope-worker.bh-7965.mjs; sets
#                           PORT and JOBS_URL; rc 3 when node:sqlite is missing
#   es_stop                 stop every worker es_srv started
#   es_seal <value> <scope> [pub.pem]  seal and POST one envelope; prints its id
#   es_get <sql>            rows of one SELECT, as JSON
#   es_box <ip>             the scratch box root the ssh shim writes for <ip>
#
# The ssh shim logs its argv (never stdin) to $T/ssh-argv.log, fails with 255
# for every ip in SSH_FAIL_IPS, and else runs the remote command with bash -c
# under ENVELOPE_REMOTE_HARNESS=<box root>, so the box root's env/ is the one
# written. Every value is a fixture: tokens say `fixture`, ips are 192.0.2.x.
# shellcheck shell=bash

ES_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ES_SRV="$ES_DIR/tests/lib/envelope-worker.bh-7965.mjs"
ES_HUB=tok-fixture-hub-7965
ES_PIDS=()

es_init() {
  # The jobs worker imports catalog/lanes.json and the llm-sites catalog.
  . "$ES_DIR/tests/lib/worker-catalogs.sh" || return 1
  worker_catalogs "$ES_DIR" || return 1
  H="$T/h"
  mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$T/keys" "$T/fakebin" "$T/vf" "$T/boxes" "$T/noetc"
  local s
  for s in bin/envelope-keygen.sh bin/envelope-consume.sh bin/secrets-apply.sh bin/secret-envelope-sweep.sh \
           bin/jobs-client.sh bin/lane-alert.sh bin/fleet-conf.sh \
           bin/lib/vendor/fake.sh bin/lib/vendor/claude.sh bin/lib/vendor/codex.sh \
           bin/lib/vendor/openrouter.sh bin/lib/vendor/fireworks.sh bin/lib/vendor/xai.sh; do
    ( cd "$ES_DIR" && scratch_install_closure "$s" "$H" ) >/dev/null 2>&1 || { echo "setup: could not install $s"; return 1; }
  done
  chmod +x "$H/bin/"*.sh "$H/bin/lib/vendor/"*.sh 2>/dev/null
  cat > "$T/fleet.conf" <<'EOF'
# fixture fleet.conf (BH-7965 suites)
demo   o/demo   https://demo.example.test   -  1  box-demo   192.0.2.10
other  o/other  https://other.example.test  -  2  box-other  192.0.2.11
EOF
  local v
  for v in claude codex openrouter fireworks xai; do
    printf '{"probe":{"accept":["tok-fixture-%s-good","tok-fixture-%s-good2"],"unreachable":["tok-fixture-%s-down"]}}\n' "$v" "$v" "$v" > "$T/vf/$v.json"
  done
  cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
# fixture ssh (tests/lib/envelope-suite.bh-7965.sh): argv to the log, stdin to the remote command.
printf '%s\n' "$*" >> "$ES_T/ssh-argv.log"
target=""; cmd="${!#}"
for a in "$@"; do case "$a" in root@*) target="${a#root@}" ;; esac; done
for f in ${SSH_FAIL_IPS:-}; do [ "$f" = "$target" ] && exit 255; done
box="$ES_T/boxes/$target"; mkdir -p "$box/env"
exec env -u HARNESS_ENV_DIR ETC_HARNESS_ENV="$ES_T/noetc" ENVELOPE_REMOTE_HARNESS="$box" bash -c "$cmd"
EOF
  chmod +x "$T/fakebin/ssh"
  export ES_T="$T" PATH="$T/fakebin:$PATH"
  export HARNESS="$H" FLEET_CONF="$T/fleet.conf" HARNESS_SECRET=fixture-harness-secret
  export ENVELOPE_HUB_TOKEN="$ES_HUB" ENVELOPE_KEY="$T/keys/envelope.key"
  export HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/vf"
  export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=hub
}

es_srv() {
  local n="$1"; shift
  : > "$T/$n.log"; : > "$T/$n.port"
  env FIXTURE_HUB_TOKEN="$ES_HUB" "$@" node "$ES_SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$! i
  ES_PIDS+=("$pid")
  for i in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  export JOBS_URL="http://127.0.0.1:$PORT"
}
es_stop() { local p; for p in "${ES_PIDS[@]}"; do kill "$p" 2>/dev/null; done; return 0; }

es_seal() {
  local value="$1" scope="$2" pub="${3:-$T/keys/pub.pem}" ct
  ct=$(printf '%s' "$value" | openssl pkeyutl -encrypt -pubin -inkey "$pub" -pkeyopt rsa_padding_mode:oaep \
        -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256 | base64 -w0) || return 1
  jq -nc --arg s "$scope" --arg c "$ct" '{scope:$s, ciphertext:$c}' \
    | curl -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' \
        --data-binary @- "$JOBS_URL/api/secrets/envelope" | jq -r '.id // empty'
}
es_get() { curl -sS -X POST "$JOBS_URL/__get" --data-binary "$1"; }
es_sql() { curl -sS -X POST "$JOBS_URL/__sql" --data-binary "$1" >/dev/null; }
es_box() { printf '%s\n' "$T/boxes/$1"; }
