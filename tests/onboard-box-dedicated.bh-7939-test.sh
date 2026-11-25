#!/bin/bash
# tests/onboard-box-dedicated.bh-7939-test.sh — the `box` station, path
# `dedicated` (bin/lib/onboard-box.sh obx_dedicated, reached through obs_box in
# bin/lib/onboard-stations.sh; BH-7975, slice BH-7939.1).
#
# Each case sources the REAL station lib in a fresh subshell inside its own
# scratch checkout $T/<case>/R. Fly and Tailscale answer from the fake seeds
# (tests/fixtures/vendor-fake/), or, in a real-mode case, from PATH stubs for flyctl
# and ssh that log their calls. bin/registry.sh is a stub with its own state
# file, so add-box, move-project and the show read-back round-trip. Cases
# share no file and run in any order. No clock, no network.
#   D1  fake Fly and Tailscale, db mode -> rc 0, the four sub-lines in order,
#       the registry writes and read-back, the bootstrap ssh to the tailnet IP
#   D2  an empty onboard.box_image row -> rc 1 `no box image set`, 0 Fly calls
#   D3  a registry row present -> provision and tailnet skipped, 0 Fly calls
#   D3b real mode, the machine exists with no registry row -> 0 `machine run`
#   D4  the have_box table: accepted rows reach ts_ip, refused rows 0 ssh calls
#   D5  a failing Tailscale fake -> rc 1 with the fake's error, 0 registry calls
#   D6  Tailscale off, no have_box -> rc 1 at tailnet before any Fly call (the
#       registry refuses an fdaa: tailnet_ip); with have_box -> ts_ip, rc 0
#   D7  catalog/fly-idle-signals.json: box-<p> is exempt, pool- and builder- keep theirs
#   D8  no Fly token -> rc 1 at provision; no TS key -> rc 1 at tailnet
#   D9  file mode -> register failed `needs REGISTRY_SOURCE=db`, no Fly call, 0 writes
#   D10 a read-back without the project -> register failed, 0 bootstrap ssh
#   D11 fm_state stays created -> provision failed at the timeout, 0 registry calls
#   D12 10 KB of bootstrap output: the 4096-byte tail holds every sub-line, and
#       the summary equals tests/fixtures/box-beats.bh-7975.txt
# Run: HARNESS_TEST_SANDBOX=1 bash tests/onboard-box-dedicated.bh-7939-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SEEDS="$DIR/tests/fixtures/vendor-fake"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has()   { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: no '$3' in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected '$3' in: $2"; else ok "$1"; fi; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }
count() { local n=0; [ -f "$1" ] && n=$(grep -c . "$1"); echo "$n"; }
TSIP=$(jq -r '.join["fdaa:0:1a2b:a7b:1::5"]' "$SEEDS/tailscale.json")
OWNIP=$(jq -r '.ip["acme-own-box"]' "$SEEDS/tailscale.json")
IMG=registry.fly.io/box-image:v1
TOK='fo1_tok-fixture-dedicated'
KEY='tskey-auth-fixture-dedicated'

# mk_case <name>: the checkout, its stubs, settings and fly.env.
mk_case() {
  local C="$T/$1"
  mkdir -p "$C/R/bin" "$C/stub" "$C/env" "$C/home"
  for L in bin/lib/onboard-stations.sh bin/lib/onboard-box.sh bin/lib/cron-lines.sh; do
    ( cd "$DIR" && scratch_install_closure "$L" "$C/R" ) >/dev/null || { bad "$1 could not install $L"; return 1; }
  done
  : > "$C/calls.log"; : > "$C/ssh.log"; : > "$C/fly.argv"; : > "$C/reg.state"
  printf 'FLY_ORG=fixture-org\nFLY_API_TOKEN=%s\nTS_AUTHKEY=%s\n' "$TOK" "$KEY" > "$C/env/fly.env"
  # bin/registry.sh: show prints the state file; add-box and move-project edit it.
  cat > "$C/R/bin/registry.sh" <<'S'
#!/bin/bash
echo "registry.sh $*" >> "$CALLS"
st="$CASE/reg.state"
case "$1" in
  show) echo "registry: version=7 boxes=1 projects=1"
        if [ -n "${REG_SHOW_DROP:-}" ]; then sed -E 's/projects=[^ ]*/projects=-/' "$st"; else cat "$st"; fi ;;
  add-box) grep -q "^$2 " "$st" || printf '%s %s %s projects=- lanes=0\n' "$2" "${2%-box}" "$4" >> "$st" ;;
  move-project) sed -i -E "s/^($4 [^ ]+ [^ ]+) projects=[^ ]*/\1 projects=$2/" "$st" ;;
esac
exit "${REG_RC:-0}"
S
  # ssh: the tailscale calls answer TS_OUT; the bootstrap block is read and
  # answered with BOOT_BYTES of output.
  cat > "$C/stub/ssh" <<'S'
#!/bin/bash
echo "ssh $*" >> "$SSH_LOG"
case "$*" in
  *tailscale*) printf 'stdin=%s\n' "$(sha256sum | cut -c1-16)" >> "$SSH_LOG"; printf '%s\n' "${TS_OUT:-}"; exit 0 ;;
esac
cat >/dev/null
if [ -n "${BOOT_BYTES:-}" ]; then head -c "$BOOT_BYTES" /dev/zero | tr '\0' 'b' | fold -w 99; echo; fi
echo "bootstrap block ran"
exit "${SSH_RC:-0}"
S
  cat > "$C/stub/flyctl" <<'S'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/fly.argv"
case "$1 ${2:-}" in
  "status -a") exit 0 ;;
  "machine list") cat "$CASE/list.json" 2>/dev/null || echo '[]' ;;
esac
exit 0
S
  cat > "$C/stub/hostname" <<'S'
#!/bin/bash
echo not-the-box
S
  cat > "$C/stub/obx-sleep" <<'S'
#!/bin/bash
n=$(( $(cat "$CASE/sleep.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CASE/sleep.n"
echo $(( $(cat "$CASE/clock" 2>/dev/null || echo 0) + ${1:-0} )) > "$CASE/clock"
exit 0
S
  # The station's clock (OBX_NOW): epoch 1761562800 plus the seconds the
  # sleep stub was asked to sleep. A poll is the only thing that moves it.
  cat > "$C/stub/obx-now" <<'S'
#!/bin/bash
echo $(( 1761562800 + $(cat "$CASE/clock" 2>/dev/null || echo 0) ))
S
  chmod +x "$C/R/bin/registry.sh" "$C/stub/"*
  knobs "$1" "$IMG"
}
# knobs <case> <image> [provision_timeout_s]: the settings answer.
knobs() {
  jq -nc --arg i "$2" --arg t "${3:-600}" '{settings: [{key: "onboard.box_image", value: $i}, {key: "onboard.box_provision_timeout_s", value: $t}, {key: "onboard.box_poll_s", value: "1"}]}' > "$T/$1/settings.json"
}

# station <case> <code> [project]: the real lib in a fresh subshell.
station() {
  local C="$T/$1"
  (
    cd "$C/R" || exit 99
    export CALLS="$C/calls.log" SSH_LOG="$C/ssh.log" CASE="$C"
    PATH="$C/stub:$PATH"
    ROOT="$C/R"
    PROJECT="${3:-acme-os}" SLUG="Acme/${3:-acme-os}" REPO="Acme/${3:-acme-os}" PROD=- BOX=zzz-box PREFIX=AO BASE=main
    HARNESS_REPO=o/h
    export HARNESS_ENV_DIR="$C/env" HOME="$C/home" FLY_BIN_DIR="$C/none" FLY_SYSTEM_DIRS=""
    # MODE fake|real -> the one fake switch (BH-8555): fake = 1, real = 0.
    case "${MODE:-fake}" in fake) HARNESS_VENDOR_FAKE=1 ;; real) HARNESS_VENDOR_FAKE=0 ;; *) exit 99 ;; esac
    export HARNESS_VENDOR_FAKE VENDOR_CALL_LOG="$C/vendor.log" HARNESS_VENDOR_FAKE_DIR="$DIR/tests/fixtures/vendor-fake"
    export OBS_BOX_PATH=dedicated OBX_SLEEP="$C/stub/obx-sleep" OBX_NOW="$C/stub/obx-now" REGISTRY_SOURCE="${REGSRC-db}"
    unset REG_MODE FLY_API_TOKEN FLY_ORG TS_AUTHKEY
    _jobs_req() { cat "$CASE/settings.json"; }
    # shellcheck source=bin/lib/onboard-stations.sh
    . bin/lib/onboard-stations.sh || { echo "source failed"; exit 98; }
    eval "$2"
  ) 2>&1
}
writes() { grep -cE '^registry.sh (add-box|move-project)' "$T/$1/calls.log"; }

# D1 — the whole path on the fakes.
mk_case d1
out=$(station d1 'obs_box; echo "rc=$?"')
has "D1 rc 0" "$out" "rc=0"
eq "D1 sub-lines in path order" "$(grep -oE '^BEAT box\.[a-z_]+ [a-z]+' <<<"$(sed '/^== box summary ==$/,$d' <<<"$out")" | awk '!s[$0]++' | tr '\n' ' ')" \
  "BEAT box.provision running BEAT box.provision done BEAT box.tailnet running BEAT box.tailnet done BEAT box.register running BEAT box.register done BEAT box.bootstrap running BEAT box.bootstrap done "
has "D1 provision done with the seeded id" "$out" "BEAT box.provision done e2860f1c4a7d98"
LIKE=$(cd "$T/d1/R" && bash -c '. bin/lib/cron-lines.sh && cron_box_id_for zzz-box')
eq "D1 add-box" "$(grep -c "^registry.sh add-box acme-os-box --ip $TSIP --like $LIKE --actor onboard-run$" "$T/d1/calls.log")" 1
eq "D1 move-project" "$(grep -c '^registry.sh move-project acme-os --box acme-os-box --actor onboard-run$' "$T/d1/calls.log")" 1
eq "D1 show read back after the writes" "$(grep -oE '^registry.sh (show|add-box|move-project)' "$T/d1/calls.log" | tail -1)" "registry.sh show"
eq "D1 the registry row" "$(grep '^acme-os-box ' "$T/d1/reg.state" | awk '{print $3, $4}')" "$TSIP projects=acme-os"
eq "D1 the bootstrap ssh went to the tailnet IP" "$(grep -c "root@$TSIP bash -s --" "$T/d1/ssh.log")" 1
eq "D1 the bootstrap ssh accepts the new host key" "$(grep -c -- "-o StrictHostKeyChecking=accept-new root@$TSIP bash -s --" "$T/d1/ssh.log")" 1
has "D1 register done" "$out" "BEAT box.register done acme-os-box $TSIP"
eq "D1 0 real Fly calls" "$(count "$T/d1/fly.argv")" 0

# D2 — no box image chosen: fail before any call.
mk_case d2
knobs d2 ""
out=$(MODE=real station d2 'obs_box; echo "rc=$?"')
has "D2 rc 1" "$out" "rc=1"
has "D2 no box image set" "$out" "BEAT box.provision failed no box image set"
eq "D2 0 Fly calls" "$(count "$T/d2/fly.argv")" 0
eq "D2 0 registry writes" "$(writes d2)" 0

# D3 — retry: the registry already has the box; real mode proves 0 Fly calls.
mk_case d3
echo "acme-os-box acme-os $TSIP projects=acme-os lanes=0" > "$T/d3/reg.state"
out=$(MODE=real station d3 'obs_box; echo "rc=$?"')
has "D3 rc 0" "$out" "rc=0"
has "D3 provision skipped" "$out" "BEAT box.provision skipped box acme-os-box already registered at $TSIP"
has "D3 tailnet skipped" "$out" "BEAT box.tailnet skipped box acme-os-box already registered at $TSIP"
eq "D3 0 Fly calls" "$(count "$T/d3/fly.argv")" 0
eq "D3 0 registry writes" "$(writes d3)" 0
has "D3 bootstrap ran" "$out" "BEAT box.bootstrap done"
eq "D3 bootstrap ssh to the registered IP" "$(grep -c "root@$TSIP bash" "$T/d3/ssh.log")" 1
# A box row that has the IP but not yet the project: register runs again.
mk_case d3c
echo "acme-os-box acme-os $TSIP projects=- lanes=0" > "$T/d3c/reg.state"
out=$(station d3c 'obs_box; echo "rc=$?"')
has "D3 half-registered rc 0" "$out" "rc=0"
eq "D3 half-registered: move-project runs" "$(grep -c '^registry.sh move-project acme-os' "$T/d3c/calls.log")" 1

# D3b — real mode: the machine exists in Fly, no registry row yet.
mk_case d3b
echo '[{"id":"e2860f1c4a7d98","name":"box-acme-os","state":"started","private_ip":"fdaa:0:1a2b:a7b:1::5"}]' > "$T/d3b/list.json"
out=$(MODE=real TS_OUT="$TSIP" station d3b 'obs_box; echo "rc=$?"')
has "D3b rc 0" "$out" "rc=0"
eq "D3b 0 machine run calls" "$(grep -c '^machine run' "$T/d3b/fly.argv")" 0
eq "D3b the join went to the private IP" "$(grep -c 'root@fdaa:0:1a2b:a7b:1::5' "$T/d3b/ssh.log")" 1
has "D3b the join set the tailnet hostname" "$(cat "$T/d3b/ssh.log")" "--hostname=acme-os-box"

# D4 — "I have a box": the address table, real mode (ssh counts).
for a in "$OWNIP" acme-own-box acme-box.tail1234.ts.net; do
  mk_case d4a
  out=$(MODE=real TS_OUT="$OWNIP" station d4a "OBS_HAVE_BOX='$a' obs_box; echo \"rc=\$?\"")
  has "D4 accept '$a' rc 0" "$out" "rc=0"
  has "D4 accept '$a' provision skipped" "$out" "BEAT box.provision skipped I have a box: $a"
  eq "D4 accept '$a' first ssh is ts_ip on it" "$(head -1 "$T/d4a/ssh.log" | grep -c "root@$a .*tailscale ip -4")" 1
  eq "D4 accept '$a' 0 Fly calls" "$(count "$T/d4a/fly.argv")" 0
  eq "D4 accept '$a' bootstrap on the given address" "$(grep -c "root@$a bash -s --" "$T/d4a/ssh.log")" 1
  rm -rf "$T/d4a"
done
BIG=$(printf 'a%.0s' $(seq 1 63)); LONG="$BIG.$BIG.$BIG.$BIG.ab"
C=100  # the first octet joined at run time: the share mirror refuses a committed 100.x dotted quad
for a in 'acme box' 'a;rm -rf /' '$(id)' '-oProxyCommand=x' "$C.64.0.1/24" 'ACME..box' "$LONG" '10.0.0.5'; do  # fixture-hygiene-allow: refused have_box rows, one outside 100.64/10
  mk_case d4r
  out=$(MODE=real TS_OUT="$OWNIP" OBS_HAVE_BOX="$a" station d4r 'export OBS_HAVE_BOX; obs_box; echo "rc=$?"')
  has "D4 refuse '${a:0:20}' rc 1" "$out" "rc=1"
  has "D4 refuse '${a:0:20}' text" "$out" "BEAT box.provision failed invalid box address"
  eq "D4 refuse '${a:0:20}' 0 ssh calls" "$(count "$T/d4r/ssh.log")" 0
  rm -rf "$T/d4r"
done

# D5 — the Tailscale fake fails.
mk_case d5
out=$(station d5 'obs_box; echo "rc=$?"' tsfail-os)
has "D5 rc 1" "$out" "rc=1"
has "D5 tailnet failed with the fake's error" "$out" "BEAT box.tailnet failed tailscale up: auth key expired"
eq "D5 0 registry calls" "$(grep -c '^registry.sh' "$T/d5/calls.log")" 1
eq "D5 the one registry call is the retry read" "$(grep -c '^registry.sh show' "$T/d5/calls.log")" 1
eq "D5 0 bootstrap ssh" "$(count "$T/d5/ssh.log")" 0

# D6 — Tailscale off. A new machine could never register its fdaa: address
# (the registry validator takes only a dotted IPv4), so it is refused before
# the spend: 0 Fly calls, 0 ssh calls, 0 registry writes.
mk_case d6
out=$(MODE=real station d6 'OBS_TAILSCALE=off; obs_box; echo "rc=$?"')
has "D6 rc 1" "$out" "rc=1"
has "D6 tailnet failed with the reason" "$out" "BEAT box.tailnet failed Tailscale off needs an existing box (have_box)"
hasnt "D6 no provision started" "$out" "BEAT box.provision running"
eq "D6 0 Fly calls" "$(count "$T/d6/fly.argv")" 0
eq "D6 0 ssh calls" "$(count "$T/d6/ssh.log")" 0
eq "D6 0 registry writes" "$(writes d6)" 0
# With "I have a box" the box already has a tailnet address: the path runs.
mk_case d6b
out=$(MODE=real TS_OUT="$OWNIP" station d6b "OBS_TAILSCALE=off; OBS_HAVE_BOX='$OWNIP' obs_box; echo \"rc=\$?\"")
has "D6 have_box rc 0" "$out" "rc=0"
eq "D6 have_box registry ip" "$(grep '^acme-os-box ' "$T/d6b/reg.state" | awk '{print $3}')" "$OWNIP"
eq "D6 have_box 0 Fly calls" "$(count "$T/d6b/fly.argv")" 0

# D7 — the idle reaper's own lookup on the catalog.
REG="$DIR/catalog/fly-idle-signals.json"
sig() { jq -r --arg a "$1" '
    if .apps[$a] then .apps[$a].source
    else [.prefixes | to_entries[] | .key as $k | select($k != "" and ($a | startswith($k)))]
         | sort_by(.key | length) | last | .value.source // "metrics" end' "$REG"; }
eq "D7 box-acme-os is exempt" "$(sig box-acme-os)" exempt
has "D7 the exemption has a reason" "$(jq -r '.prefixes["box-"].reason // ""' "$REG")" "BH-7975"
eq "D7 pool- keeps pool" "$(sig pool-acme-os)" pool
eq "D7 builder- keeps builder" "$(sig builder-acme-os)" builder
eq "D7 an unlisted app is still metrics" "$(sig unlisted-acme)" metrics

# D8 — no Fly token; no Tailscale key.
mk_case d8
printf 'FLY_ORG=fixture-org\n' > "$T/d8/env/fly.env"
out=$(MODE=real station d8 'obs_box; echo "rc=$?"')
has "D8 no token rc 1" "$out" "rc=1"
has "D8 no token text" "$out" "BEAT box.provision failed no Fly token"
eq "D8 no token: 0 Fly calls" "$(count "$T/d8/fly.argv")" 0
mk_case d8b
printf 'FLY_ORG=fixture-org\nFLY_API_TOKEN=%s\n' "$TOK" > "$T/d8b/env/fly.env"
echo '[{"id":"e2860f1c4a7d98","name":"box-acme-os","state":"started","private_ip":"fdaa:0:1a2b:a7b:1::5"}]' > "$T/d8b/list.json"
out=$(MODE=real station d8b 'obs_box; echo "rc=$?"')
has "D8 no key rc 1" "$out" "rc=1"
has "D8 no key text" "$out" "BEAT box.tailnet failed no Tailscale auth key"
eq "D8 no key: 0 ssh calls" "$(count "$T/d8b/ssh.log")" 0
# A project key wins over the org key.
mk_case d8c
printf 'FLY_ORG=fixture-org\nFLY_API_TOKEN=%s\nTS_AUTHKEY=%s\nTS_AUTHKEY_ACME_OS=tskey-auth-fixture-project\n' "$TOK" "$KEY" > "$T/d8c/env/fly.env"
echo '[{"id":"e2860f1c4a7d98","name":"box-acme-os","state":"started","private_ip":"fdaa:0:1a2b:a7b:1::5"}]' > "$T/d8c/list.json"
MODE=real TS_OUT="$TSIP" station d8c 'obs_box' >/dev/null
eq "D8 the project key is the one joined" "$(grep -c "^stdin=$(printf '%s\n' tskey-auth-fixture-project | sha256sum | cut -c1-16)$" "$T/d8c/ssh.log")" 1
eq "D8 nothing on argv holds a key" "$(grep -c 'tskey-' "$T/d8c/ssh.log" "$T/d8c/fly.argv" | awk -F: '{s+=$2} END {print s}')" 0

# D9 — file mode: refused before any spend.
mk_case d9
out=$(REGSRC= MODE=real station d9 'obs_box; echo "rc=$?"')
has "D9 rc 1" "$out" "rc=1"
has "D9 text" "$out" "BEAT box.register failed dedicated box needs REGISTRY_SOURCE=db"
eq "D9 0 registry writes" "$(writes d9)" 0
eq "D9 0 Fly calls" "$(count "$T/d9/fly.argv")" 0

# D10 — the read-back lacks the project.
mk_case d10
out=$(REG_SHOW_DROP=1 station d10 'export REG_SHOW_DROP; obs_box; echo "rc=$?"')
has "D10 rc 1" "$out" "rc=1"
has "D10 register failed" "$out" "BEAT box.register failed"
eq "D10 0 bootstrap ssh" "$(count "$T/d10/ssh.log")" 0

# D11 — the machine never reaches started.
mk_case d11
knobs d11 "$IMG" 3
out=$(station d11 'obs_box; echo "rc=$?"' slow-os)
has "D11 rc 1" "$out" "rc=1"
has "D11 provision failed with the state" "$out" "BEAT box.provision failed state created after 3s"
eq "D11 polled to the timeout" "$(cat "$T/d11/sleep.n")" 3
eq "D11 0 registry calls past the retry read" "$(grep -c '^registry.sh' "$T/d11/calls.log")" 1

# D12 — a long bootstrap: the excerpt tail still holds every sub-line.
mk_case d12
out=$(BOOT_BYTES=10240 station d12 'export BOOT_BYTES; obs_box; echo "rc=$?"')
has "D12 rc 0" "$out" "rc=0"
TAILX=$(printf '%s\n' "$out" | tail -c 4096)
for s in provision tailnet register bootstrap; do has "D12 tail holds box.$s" "$TAILX" "BEAT box.$s done"; done
eq "D12 the summary equals the shared fixture" "$(sed -n '/^== box summary ==$/,/^rc=/p' <<<"$out" | sed '1d;$d' | sed "s/$TSIP/@TS_IP@/g")" "$(cat "$DIR/tests/fixtures/box-beats.bh-7975.txt")"

echo "onboard-box-dedicated.bh-7939: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
