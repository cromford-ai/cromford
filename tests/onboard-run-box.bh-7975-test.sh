#!/bin/bash
# tests/onboard-run-box.bh-7975-test.sh — the runner's box path inputs
# (bin/onboard-run.sh _obr_box_inputs, _obr_dedicated_box, obs_run_cancelled;
# BH-7975, slice BH-7939.1), and end-to-end runs of the box station.
#   R1 the inputs.box mapping table (plan Failure modes (e)); have_box passes
#      through; tailscale `off` -> off, anything else -> on
#   R2 _obr_station clone, dedicated: BOX is the registry's answer; an empty
#      answer -> rc 1 and 0 obs_clone calls; shared keeps BOX
#   R3 obs_run_cancelled, the read-only cancel probe (plan Failure modes (f)):
#      rc 0 only for a 200 whose .run.state is not running; a running run, a
#      404, a 5xx, a transport failure, a non-JSON body and a body with no
#      .run are rc 1 (keep waiting); only GET requests, JOBS_ALERT=0 on each,
#      0 alert lines
#   R4 an unknown path through the real station lib -> `unknown box path
#      'Pool'`, rc 1, 0 vendor calls
#   R5 the REAL bin/onboard-run.sh over real curl against the REAL jobs worker
#      (tests/fixtures/onboarding-worker.bh-7975.mjs) and the real station lib, Fly
#      and Tailscale on the fake seeds: the seeded empty onboard.box_image row
#      fails the box step with `no box image set`; with the row set, the box
#      step ends done and its stored log_excerpt holds the four sub-lines.
#      R5c/R5d (comment IC_kwDOTh6ir88AAAABhMfEVA, keep started_at from the
#      first beat): a pool run waits 3 real 1 s polls, then sees OK. Exactly 1
#      `running` and 1 `done` box beat; started_at after poll 1 equals the end
#      value; finished_at - started_at >= 2 s; >= 3 run reads after the
#      running beat; 0 alert lines raised (the runner's own `--resolve` line
#      on its first good request is not an alert). A cancel through the worker's own cancel
#      route during poll 2 ends the tick with exit 0, `cancelled <id> at box`,
#      and no second running beat.
# R1-R4 source the runner with ONBOARD_RUN_LIB_ONLY=1.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/onboard-run-box.bh-7975-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$DIR/bin/onboard-run.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has()   { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: no '$3' in: $2"; fi; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }
count() { local n=0; [ -f "$1" ] && n=$(grep -c . "$1"); echo "$n"; }
TSIP=$(jq -r '.join["fdaa:0:1a2b:a7b:1::5"]' "$DIR/tests/fixtures/vendor-fake/tailscale.json")

# lib <code>: the runner's functions in a fresh subshell, nothing run.
lib() {
  ( export HARNESS="$T/lib-h"; mkdir -p "$HARNESS/logs"
    ONBOARD_RUN_LIB_ONLY=1 . "$SCRIPT" || exit 98
    eval "$1" ) 2>&1
}

# R1 — the mapping table.
r1() { # r1 <inputs-json> -> "<path>|<have_box>|<tailscale>"
  printf '%s' "$1" | jq '{run: {inputs: .}}' > "$T/r1.json"
  lib "_obr_box_inputs '$T/r1.json'; printf '%s|%s|%s' \"\$OBS_BOX_PATH\" \"\$OBS_HAVE_BOX\" \"\$OBS_TAILSCALE\"; bash -c 'printf \" exported=%s\" \"\$OBS_BOX_PATH\"'"
}
eq "R1 shared" "$(r1 '{"box":"shared"}')" "shared||on exported=shared"
eq "R1 empty" "$(r1 '{"box":""}')" "shared||on exported=shared"
eq "R1 missing" "$(r1 '{}')" "shared||on exported=shared"
eq "R1 pool" "$(r1 '{"box":"pool"}')" "pool||on exported=pool"
eq "R1 fly is pool" "$(r1 '{"box":"fly"}')" "pool||on exported=pool"
eq "R1 dedicated" "$(r1 '{"box":"dedicated","have_box":"acme-own-box"}')" "dedicated|acme-own-box|on exported=dedicated"
eq "R1 Pool stays" "$(r1 '{"box":"Pool"}')" "Pool||on exported=Pool"
eq "R1 'dedicated ' stays" "$(r1 '{"box":"dedicated "}')" "dedicated ||on exported=dedicated "
eq "R1 box stays" "$(r1 '{"box":"box"}')" "box||on exported=box"
eq "R1 tailscale off" "$(r1 '{"box":"dedicated","tailscale":"off"}')" "dedicated||off exported=dedicated"
eq "R1 tailscale Off is on" "$(r1 '{"box":"dedicated","tailscale":"Off"}')" "dedicated||on exported=dedicated"
eq "R1 tailscale false is on" "$(r1 '{"box":"dedicated","tailscale":false}')" "dedicated||on exported=dedicated"

# R2 — the clone station on a dedicated box reads the box address first.
mkdir -p "$T/r2/bin"
cat > "$T/r2/bin/fleet-conf.sh" <<'S'
#!/bin/bash
echo "fleet-conf.sh $*" >> "$R2_CALLS"
[ "$1 $2" = "--tailnet-ip acme-os" ] && printf '%s\n' "${R2_ANSWER:-}"
exit 0
S
chmod +x "$T/r2/bin/fleet-conf.sh"
R2SET="ROOT='$T/r2' PROJECT=acme-os BOX=zzz-box; export R2_CALLS='$T/r2/calls'; obs_clone() { echo \"obs_clone BOX=\$BOX\" >> '$T/r2/calls'; }"
: > "$T/r2/calls"
out=$(R2_ANSWER="$TSIP" lib "$R2SET; export R2_ANSWER; OBS_BOX_PATH=dedicated; _obr_station clone; echo \"rc=\$? BOX=\$BOX\"")
has "R2 rc 0" "$out" "rc=0"
eq "R2 obs_clone ran on the registry address" "$(grep -c "^obs_clone BOX=$TSIP$" "$T/r2/calls")" 1
eq "R2 one registry read" "$(grep -c '^fleet-conf.sh --tailnet-ip acme-os$' "$T/r2/calls")" 1
: > "$T/r2/calls"
out=$(lib "$R2SET; OBS_BOX_PATH=dedicated; _obr_station clone; echo \"rc=\$?\"")
has "R2 empty answer rc 1" "$out" "rc=1"
has "R2 empty answer text" "$out" "no box address in the registry for acme-os"
eq "R2 empty answer: 0 obs_clone calls" "$(grep -c obs_clone "$T/r2/calls")" 0
: > "$T/r2/calls"
out=$(R2_ANSWER="$TSIP" lib "$R2SET; export R2_ANSWER; OBS_BOX_PATH=shared; _obr_station clone; echo \"rc=\$?\"")
eq "R2 shared keeps BOX" "$(cat "$T/r2/calls")" "obs_clone BOX=zzz-box"
: > "$T/r2/calls"
out=$(R2_ANSWER="$TSIP" lib "$R2SET; export R2_ANSWER; OBS_BOX_PATH=dedicated; obs_box() { echo \"obs_box BOX=\$BOX\" >> '$T/r2/calls'; }; _obr_station box")
eq "R2 the box station keeps BOX" "$(cat "$T/r2/calls")" "obs_box BOX=zzz-box"
: > "$T/r2/calls"
R2K="obs_clone() { echo \"obs_clone accept_new=\${OBS_SSH_ACCEPT_NEW:-0}\" >> '$T/r2/calls'; }"
lib "$R2SET; export R2_ANSWER='$TSIP'; $R2K; OBS_BOX_PATH=dedicated; _obr_station clone" >/dev/null
lib "$R2SET; export R2_ANSWER='$TSIP'; $R2K; OBS_BOX_PATH=shared; _obr_station clone" >/dev/null
eq "R2 accept-new on the dedicated clone only" "$(grep obs_clone "$T/r2/calls" | tr '\n' ' ')" "obs_clone accept_new=1 obs_clone accept_new=0 "

# R3 — the cancel probe: one read, never a write, never an alert.
R3SET="ID=ob_0123456789abcdef0123; alert() { echo \"alert \$*\" >> '$T/r3.alerts'; }"
: > "$T/r3.alerts"; : > "$T/r3.req"
r3() { # r3 <rc> <body> -> rc=<n> of obs_run_cancelled against a stub answer
  lib "$R3SET; _jobs_req() { echo \"\$1 \$2 alert=\${JOBS_ALERT:-1}\" >> '$T/r3.req'; printf '%s' '$2'; return $1; }; obs_run_cancelled; echo rc=\$?"
}
eq "R3 200 cancelled -> stop" "$(r3 0 '{"run":{"state":"cancelled"},"steps":[]}')" "rc=0"
eq "R3 200 failed -> stop" "$(r3 0 '{"run":{"state":"failed"},"steps":[]}')" "rc=0"
eq "R3 200 done -> stop" "$(r3 0 '{"run":{"state":"done"},"steps":[]}')" "rc=0"
eq "R3 200 running -> keep waiting" "$(r3 0 '{"run":{"state":"running"},"steps":[]}')" "rc=1"
eq "R3 404 -> keep waiting" "$(r3 2 '')" "rc=1"
eq "R3 5xx -> keep waiting" "$(r3 1 'upstream error')" "rc=1"
eq "R3 409 -> keep waiting (a read never gets one)" "$(r3 9 '{"error":"x"}')" "rc=1"
eq "R3 transport failure -> keep waiting" "$(lib "$R3SET; _jobs_req() { echo \"\$1 \$2 alert=\${JOBS_ALERT:-1}\" >> '$T/r3.req'; return 1; }; obs_run_cancelled; echo rc=\$?")" "rc=1"
eq "R3 200 non-JSON -> keep waiting" "$(r3 0 '<html>not json</html>')" "rc=1"
eq "R3 200 no .run -> keep waiting" "$(r3 0 '{"steps":[]}')" "rc=1"
eq "R3 every request is one GET of the run" "$(sort -u "$T/r3.req")" "GET /api/onboarding/runs/ob_0123456789abcdef0123 alert=0"
eq "R3 10 probes, 10 reads" "$(count "$T/r3.req")" 10
eq "R3 0 alert lines" "$(count "$T/r3.alerts")" 0
eq "R3 the runner defines no heartbeat" "$(lib 'declare -F obs_heartbeat >/dev/null && echo defined || echo absent')" "absent"

# R4 — an unknown path fails in the station, before any call.
mkdir -p "$T/r4/stub"; : > "$T/r4/calls"
for n in flyctl fly ssh tailscale curl; do printf '#!/bin/bash\necho %s >> "%s"\nexit 99\n' "$n" "$T/r4/calls" > "$T/r4/stub/$n"; chmod +x "$T/r4/stub/$n"; done
out=$(cd "$DIR" && PATH="$T/r4/stub:$PATH" lib ". '$DIR/bin/lib/onboard-stations.sh'; ROOT='$DIR' PROJECT=acme-os BOX=zzz-box; export VENDOR_CALL_LOG='$T/r4/calls'; OBS_BOX_PATH=Pool; _obr_station box; echo \"rc=\$?\"")
has "R4 rc 1" "$out" "rc=1"
has "R4 text" "$out" "unknown box path 'Pool'"
eq "R4 0 vendor calls" "$(count "$T/r4/calls")" 0

# R5 — the production entry point, end to end.
SRV="$DIR/tests/fixtures/onboarding-worker.bh-7975.mjs"
if ! command -v node >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "SKIP R5: node or curl missing"
else
  . "$DIR/tests/lib/worker-catalogs.sh" || exit 1
  worker_catalogs "$DIR" || exit 1
  H="$T/h"
  mkdir -p "$H/logs" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$H/prompts" "$T/stub" "$T/boxh"
  : > "$H/env/global.env"
  for L in bin/onboard-run.sh bin/jobs-client.sh bin/lib/onboard-stations.sh bin/lib/onboard-box.sh bin/lib/cron-lines.sh; do
    ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "R5 setup: could not install $L"
  done
  cp "$DIR/catalog/lanes.json" "$H/catalog/lanes.json"
  printf 'FLY_ORG=fixture-org\nFLY_API_TOKEN=fo1_tok-fixture-r5\nTS_AUTHKEY=tskey-auth-fixture-r5\n' > "$H/env/fly.env"
  cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/r5.alerts"
EOF
  cat > "$H/bin/registry.sh" <<'S'
#!/bin/bash
st="$R5_STATE"
case "$1" in
  show) echo "registry: version=1 boxes=1 projects=1"; cat "$st" ;;
  add-box) grep -q "^$2 " "$st" || printf '%s %s %s projects=- lanes=0\n' "$2" "${2%-box}" "$4" >> "$st" ;;
  move-project) sed -i -E "s/^($4 [^ ]+ [^ ]+) projects=[^ ]*/\1 projects=$2/" "$st" ;;
esac
exit 0
S
  cat > "$T/stub/ssh" <<'S'
#!/bin/bash
echo "ssh $*" >> "$R5_SSH"
cat >/dev/null
echo "bootstrap block ran"
S
  cat > "$T/stub/hostname" <<'S'
#!/bin/bash
echo not-the-box
S
  cat > "$T/stub/gh" <<'S'
#!/bin/bash
exit 0
S
  printf '#!/bin/bash\nexit 0\n' > "$T/stub/obx-sleep"
  chmod +x "$H/bin/"*.sh "$T/stub/"*
  : > "$T/srv.log"; : > "$T/srv.port"; : > "$T/r5.alerts"; : > "$T/r5.ssh"; : > "$T/r5.reg"
  node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
  SPID=$!
  for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/srv.port")
  if [ -z "$PORT" ]; then
    wait "$SPID"; if [ "$?" = 3 ]; then echo "SKIP R5: node:sqlite unavailable"; else bad "R5 worker did not start: $(cat "$T/srv.err")"; fi
  else
    trap 'kill "$SPID" 2>/dev/null; __scratch_exit_trap' EXIT
    U="http://127.0.0.1:$PORT"; AUTH="authorization: Bearer tok-fixture-bh7975"
    newrun() { # newrun <key> -> a run id with only its box step queued, box=dedicated
      local id
      id=$(curl -sS -X POST -H "$AUTH" -H "idempotency-key: $1" -H 'content-type: application/json' \
        -d '{"repo":"example-org/acme-os","project":"acme-os","tracker":"github-issues","box":"shared"}' "$U/api/onboarding/runs" | jq -r .id)
      curl -sS -X POST -d "{\"id\":\"$id\",\"patch\":{\"box\":\"dedicated\"}}" "$U/__inputs" >/dev/null
      curl -sS -X POST -d "{\"id\":\"$id\",\"station\":\"box\"}" "$U/__only" >/dev/null
      echo "$id"
    }
    boxf() { curl -sS -H "$AUTH" "$U/api/onboarding/runs/$1" | jq -r --arg f "$2" '.steps[] | select(.station == "box") | .[$f] // "null"'; }
    runner() {
      env PATH="$T/stub:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" BOX_NAME=hub HARNESS_SECRET=tok-fixture-bh7975 \
        JOBS_URL="$U" JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10 \
        HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$DIR/tests/fixtures/vendor-fake" VENDOR_CALL_LOG="$T/r5.vendor" REGISTRY_SOURCE=db OBX_SLEEP="${R5_SLEEP:-$T/stub/obx-sleep}" \
        R5_STATE="$T/r5.reg" R5_SSH="$T/r5.ssh" bash "$H/bin/onboard-run.sh" "$1" > "$T/r5.out" 2>&1
    }
    # R5a — the seeded row: no box image chosen yet.
    A=$(newrun key-fixture-r5a)
    runner "$A"; RC=$?
    eq "R5a exit 1" "$RC" 1
    eq "R5a box failed" "$(boxf "$A" state)" failed
    has "R5a the excerpt says why" "$(boxf "$A" log_excerpt)" "BEAT box.provision failed no box image set"
    eq "R5a 0 ssh calls" "$(count "$T/r5.ssh")" 0
    # R5b — the row set through the worker's own settings route.
    curl -sS -X PUT -H "$AUTH" -H 'content-type: application/json' \
      -d '{"key":"onboard.box_image","value":"registry.fly.io/box-image:v1","actor":"onboard-run-box-test"}' "$U/api/settings" > "$T/r5.put"
    eq "R5b the image row reads back" "$(curl -sS -H "$AUTH" "$U/api/settings" | jq -r '.settings[] | select(.key == "onboard.box_image") | .value')" "registry.fly.io/box-image:v1"
    B=$(newrun key-fixture-r5b)
    runner "$B"; RC=$?
    eq "R5b exit 0" "$RC" 0
    [ "$RC" = 0 ] || tail -n 20 "$T/r5.out"
    eq "R5b box done" "$(boxf "$B" state)" done
    EX=$(boxf "$B" log_excerpt)
    for s in provision tailnet register bootstrap; do has "R5b the stored excerpt holds box.$s" "$EX" "BEAT box.$s done"; done
    eq "R5b the stored summary equals the shared fixture" "$(sed -n '/^== box summary ==$/,$p' <<<"$EX" | sed '1d' | sed "s/$TSIP/@TS_IP@/g")" "$(cat "$DIR/tests/fixtures/box-beats.bh-7975.txt")"
    eq "R5b the registry row" "$(awk '$1 == "acme-os-box" {print $3, $4}' "$T/r5.reg")" "$TSIP projects=acme-os"
    eq "R5b the bootstrap ran on the tailnet IP" "$(grep -c "root@$TSIP " "$T/r5.ssh")" 1
    eq "R5 0 real vendor calls" "$(count "$T/r5.vendor")" 0

    # R5c — a pool run waits 3 real polls (onboard.box_poll_s = 1). The beat
    # log must hold ONE running beat for box: a second one would move the
    # step's started_at, and SetupLine's box duration would show only the last
    # poll (comment IC_kwDOTh6ir88AAAABhMfEVA).
    curl -sS -X PUT -H "$AUTH" -H 'content-type: application/json' \
      -d '{"key":"onboard.box_poll_s","value":"1","actor":"onboard-run-box-test"}' "$U/api/settings" > /dev/null
    cat > "$T/stub/obx-sleep-real" <<'S'
#!/bin/bash
# One real poll. Poll 1 records the box step's started_at; poll R5_CANCEL_AT
# cancels the run through the worker's own route; poll 3 writes the verdict.
sleep "$1"
n=$(( $(cat "$R5_N" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$R5_N"
[ "$n" != 1 ] || curl -sS -H "authorization: Bearer tok-fixture-bh7975" "$R5_U/api/onboarding/runs/$R5_ID" \
  | jq -r '.steps[] | select(.station == "box") | .started_at' > "$R5_N.started"
if [ "$n" = "${R5_CANCEL_AT:-0}" ]; then
  curl -sS -X POST -H "authorization: Bearer tok-fixture-bh7975" -H 'content-type: application/json' \
    -d '{}' "$R5_U/api/onboarding/runs/$R5_ID/cancel" > "$R5_N.cancel"
fi
[ "$n" != 3 ] || printf '2026-11-02 00:00:00Z [fly-onboard/acme-os] FLY_ONBOARD acme-os OK: fixture\n' >> "$R5_H/logs/fly-pool-rollout.log"
exit 0
S
    chmod +x "$T/stub/obx-sleep-real"
    mkdir -p "$H/fly"
    poolrun() { # poolrun <key> <cancel-at> -> run id; the runner's rc in $T/r5.rc
      local id
      id=$(newrun "$1")
      curl -sS -X POST -d "{\"id\":\"$id\",\"patch\":{\"box\":\"pool\"}}" "$U/__inputs" >/dev/null
      : > "$T/srv.log"; : > "$T/r5.alerts"; rm -f "$T/r5.n" "$T/r5.n.started"; : > "$H/logs/fly-pool-rollout.log"
      R5_N="$T/r5.n" R5_U="$U" R5_ID="$id" R5_H="$H" R5_CANCEL_AT="$2" R5_SLEEP="$T/stub/obx-sleep-real" runner "$id"
      echo "$?" > "$T/r5.rc"
      echo "$id"
    }
    secs() { date -u -d "$1" +%s 2>/dev/null || echo "bad:$1"; }
    C=$(poolrun key-fixture-r5c 0)
    eq "R5c exit 0" "$(cat "$T/r5.rc")" 0
    [ "$(cat "$T/r5.rc")" = 0 ] || tail -n 20 "$T/r5.out"
    eq "R5c box done" "$(boxf "$C" state)" done
    eq "R5c 3 real polls" "$(cat "$T/r5.n" 2>/dev/null)" 3
    eq "R5c (a) exactly 1 running beat for box" "$(grep -c "/runs/$C/beat 200 station=box state=running\$" "$T/srv.log")" 1
    eq "R5c (a) exactly 1 done beat for box" "$(grep -c "/runs/$C/beat 200 station=box state=done\$" "$T/srv.log")" 1
    eq "R5c (a) no box beat other than those two" "$(grep -c "/runs/$C/beat .* station=box " "$T/srv.log")" 2
    S1=$(cat "$T/r5.n.started" 2>/dev/null); SE=$(boxf "$C" started_at); FE=$(boxf "$C" finished_at)
    eq "R5c (b) started_at after poll 1 equals started_at at the end" "$S1" "$SE"
    D=$(( $(secs "$FE") - $(secs "$SE") ))
    if [ "$D" -ge 2 ] 2>/dev/null; then ok "R5c (c) the box duration covers the whole wait (${D}s)"; else bad "R5c (c) finished_at - started_at = '$D' ($SE .. $FE), want >= 2"; fi
    RB=$(awk -v id="$C" '$0 ~ "/runs/" id "/beat 200 station=box state=running$" {on=1; next} on && $1 == "GET" && $2 == "/api/onboarding/runs/" id' "$T/srv.log" | grep -c .)
    if [ "$RB" -ge 3 ]; then ok "R5c (d) $RB run reads after the running beat"; else bad "R5c (d) $RB run reads after the running beat, want >= 3"; fi
    eq "R5c (e) 0 alert lines raised" "$(grep -vc -- '^--resolve ' "$T/r5.alerts")" 0
    eq "R5c the queue holds the project once" "$(grep -cE '^acme-os ' "$H/fly/onboard-queue.conf")" 1

    # R5d — a cancel during poll 2: the next probe reads it, the tick exits 0.
    : > "$H/fly/onboard-queue.conf"
    E=$(poolrun key-fixture-r5d 2)
    eq "R5d exit 0" "$(cat "$T/r5.rc")" 0
    has "R5d the cancel route answered" "$(cat "$T/r5.n.cancel" 2>/dev/null)" '"state":"cancelled"'
    has "R5d the runner logged the cancel" "$(cat "$H/logs/onboard-run.log")" "cancelled $E at box"
    eq "R5d 2 polls, then stop" "$(cat "$T/r5.n" 2>/dev/null)" 2
    eq "R5d no second running beat" "$(grep -c "/runs/$E/beat 200 station=box state=running\$" "$T/srv.log")" 1
    eq "R5d the run reads cancelled" "$(curl -sS -H "$AUTH" "$U/api/onboarding/runs/$E" | jq -r .run.state)" cancelled
    eq "R5d 0 alert lines raised" "$(grep -vc -- '^--resolve ' "$T/r5.alerts")" 0
  fi
fi

echo "onboard-run-box.bh-7975: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
