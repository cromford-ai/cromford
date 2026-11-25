#!/bin/bash
# tests/vendor-seams.bh-7939-test.sh — the Fly machines and Tailscale seams
# (bin/lib/vendor/fly-machines.sh, bin/lib/vendor/tailscale.sh; BH-7975, slice
# BH-7939.1).
#
# Each case sources the REAL seam in a child bash. Real mode runs against PATH
# stubs for flyctl and ssh that log their argv, env and stdin hash to the
# case's own files: 0 network calls. Fake mode answers from
# tests/fixtures/vendor-fake/*.json. VENDOR_CALL_LOG is the case's own file, so the
# budget suite's log never sees a line from here.
#   F1 fake mode: fm_create, fm_state, fm_private_ip answer the seed
#   F2 bad app, region, image or id -> rc 2, 0 stub calls
#   F3 real mode: the token is in the stub's env, never in argv, never left
#      set in the caller, and cut from the error text
#   F4 a machine with the name exists -> its id, 0 `machine run` calls
#   F5 an unseeded key -> rc 70 `not implemented`
#   F6 no token -> rc 3, 0 calls; no flyctl -> rc 127
#   F7 `secrets import` gets TS_AUTHKEY= on stdin only
#   T1 the ts_ip_ok table (plan Failure modes (b))
#   T2 ts_join real mode: the key is on stdin, not argv; --hostname; 1 call log line
#   T3 bad var name rc 2, empty var rc 3, bad host rc 2, each with 0 ssh calls
#   T4 a seeded error -> rc 1 with the text on stderr
#   T5 ts_ip fake and real; two lines -> rc 1
#   F8 fly_machines_run_help (BH-8640) still works beside the new functions:
#      fake mode answers a seeded run_help; real mode runs ${FLY:-fly}
# Run: HARNESS_TEST_SANDBOX=1 bash tests/vendor-seams.bh-7939-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FM="$DIR/bin/lib/vendor/fly-machines.sh"
TS="$DIR/bin/lib/vendor/tailscale.sh"
SEEDS="$DIR/tests/fixtures/vendor-fake"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: '$3' not in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected '$3' in: $2"; else ok; fi; }
count() { local n=0; [ -f "$1" ] && n=$(grep -c . "$1"); echo "$n"; }
TOK='fo1_tok-fixture-seams-77'
KEY='tskey-auth-fixture-seams-88'
TSIP=$(jq -r '.join["fdaa:0:1a2b:a7b:1::5"]' "$SEEDS/tailscale.json")
OWNIP=$(jq -r '.ip["acme-own-box"]' "$SEEDS/tailscale.json")

# mk <case>: the case dir with the flyctl and ssh stubs.
mk() {
  local C="$T/$1"
  mkdir -p "$C/bin" "$C/home"
  : > "$C/fly.argv"; : > "$C/fly.env"; : > "$C/ssh.argv"; : > "$C/calls.log"
  echo '[]' > "$C/list.json"
  cat > "$C/bin/flyctl" <<'S'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/fly.argv"
printf 'tok=%s\n' "${FLY_ACCESS_TOKEN:-}" >> "$STUB_DIR/fly.env"
if [ -n "${STUB_FAIL:-}" ]; then echo "Error: token $FLY_ACCESS_TOKEN rejected" >&2; exit 1; fi
case "$1 ${2:-}" in
  "status -a") exit "${STUB_STATUS_RC:-0}" ;;
  "apps create") exit 0 ;;
  "machine list") cat "$STUB_DIR/list.json"; exit 0 ;;
  "machine run") [ -f "$STUB_DIR/after-run.json" ] && cp "$STUB_DIR/after-run.json" "$STUB_DIR/list.json"; exit 0 ;;
  "secrets import") printf 'stdin=%s\n' "$(sha256sum | cut -c1-16)" >> "$STUB_DIR/fly.argv"; exit 0 ;;
esac
exit 0
S
  cat > "$C/bin/ssh" <<'S'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/ssh.argv"
printf 'stdin=%s\n' "$(sha256sum | cut -c1-16)" >> "$STUB_DIR/ssh.argv"
[ -z "${SSH_RC:-}" ] || { echo "ssh: connect to host failed" >&2; exit "$SSH_RC"; }
cat "$STUB_DIR/ts.out"
S
  chmod +x "$C/bin/flyctl" "$C/bin/ssh"
}
# run <case> <lib> <env...> -- <cmd...>: out|rc=|err=
run() {
  local C="$T/$1" lib="$2"; shift 2
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  local out rc
  out=$(env -u FLY_API_TOKEN -u FLY_ACCESS_TOKEN PATH="$C/bin:$PATH" HOME="$C/home" FLY_BIN_DIR="$C/none" FLY_SYSTEM_DIRS="" \
    STUB_DIR="$C" VENDOR_CALL_LOG="$C/calls.log" FLY_ORG=fixture-org HARNESS_VENDOR_FAKE=0 "${e[@]}" \
    bash -c '. "$1" || exit 98; shift; "$@"' _ "$lib" "$@" 2>"$C/err" </dev/null); rc=$?
  printf '%s|rc=%s|err=%s' "$out" "$rc" "$(cat "$C/err")"
}
sha16() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# F1 — fake mode answers the seed; 0 stub calls.
mk f1
eq "F1 fm_create" "$(run f1 "$FM" HARNESS_VENDOR_FAKE=1 -- fm_create box-acme-os box-acme-os registry.fly.io/box-image:v1 iad)" "e2860f1c4a7d98|rc=0|err="
eq "F1 fm_state" "$(run f1 "$FM" HARNESS_VENDOR_FAKE=1 -- fm_state box-acme-os e2860f1c4a7d98)" "started|rc=0|err="
eq "F1 fm_private_ip" "$(run f1 "$FM" HARNESS_VENDOR_FAKE=1 -- fm_private_ip box-acme-os e2860f1c4a7d98)" "fdaa:0:1a2b:a7b:1::5|rc=0|err="
eq "F1 0 flyctl calls" "$(count "$T/f1/fly.argv")" 0

# F2 — input refusals, before any call (real mode with a token: only the checks stop it).
mk f2
IMG=registry.fly.io/box-image:v1
f2c() { has "F2 fm_create $* rc 2" "$(run f2 "$FM" FLY_API_TOKEN="$TOK" -- fm_create "$@")" "|rc=2|"; }
f2c Box_A box-a "$IMG" iad
f2c box-a Bad_Name "$IMG" iad
f2c box-a box-a "$IMG" IAD
f2c box-a box-a "$IMG" iad1
f2c box-a box-a "foo bar" iad
f2c box-a box-a --rm iad
has "F2 fm_state bad id" "$(run f2 "$FM" FLY_API_TOKEN="$TOK" -- fm_state box-a xyz)" "|rc=2|"
has "F2 fm_private_ip bad app" "$(run f2 "$FM" FLY_API_TOKEN="$TOK" -- fm_private_ip Box_A e2860f1c4a7d98)" "|rc=2|"
has "F2 bad FLY_ORG" "$(run f2 "$FM" FLY_API_TOKEN="$TOK" FLY_ORG='a b' -- fm_create box-a box-a registry.fly.io/i:v1 iad)" "|rc=2|"
eq "F2 0 flyctl calls" "$(count "$T/f2/fly.argv")" 0
eq "F2 0 call log lines" "$(count "$T/f2/calls.log")" 0

# F3 — the token rides the env of the call only.
mk f3
echo '[{"id":"e2860f1c4a7d98","name":"box-acme-os","state":"started","private_ip":"fdaa:0:1a2b:a7b:1::5"}]' > "$T/f3/list.json"
r=$(run f3 "$FM" FLY_API_TOKEN="$TOK" -- bash -c '. "$0" || exit 98; fm_state box-acme-os e2860f1c4a7d98; echo "after=${FLY_ACCESS_TOKEN-unset}/${FLY_TOKEN_VAL-unset}"' "$FM")
has "F3 state answered" "$r" "started"
has "F3 FLY_ACCESS_TOKEN not left in the caller" "$r" "after=unset/unset"
eq "F3 the stub saw the token in env" "$(grep -c "^tok=$TOK$" "$T/f3/fly.env")" 1
eq "F3 the token is in no argv" "$(grep -cF "$TOK" "$T/f3/fly.argv")" 0
eq "F3 one call log line" "$(grep -cE '^[0-9]+ fly-machines machine-list$' "$T/f3/calls.log")" 1
r=$(run f3 "$FM" FLY_API_TOKEN="$TOK" STUB_FAIL=1 -- fm_state box-acme-os e2860f1c4a7d98)
has "F3 a stub failure is rc 1" "$r" "|rc=1|"
has "F3 the error names the cut token" "$r" "<token>"
hasnt "F3 the token is cut from the error" "$r" "$TOK"
# A project token wins over the org token (fly_token_resolve).
mk f3b
r=$(run f3b "$FM" FLY_API_TOKEN="$TOK" FLY_API_TOKEN_ACME_OS=fo1_tok-fixture-project -- fm_state box-acme-os e2860f1c4a7d98)
eq "F3 the project token wins" "$(grep -c '^tok=fo1_tok-fixture-project$' "$T/f3b/fly.env")" 1

# F4 — dedup before spend: a machine with the name already exists.
mk f4
echo '[{"id":"e2860f1c4a7d98","name":"box-acme-os","state":"stopped"}]' > "$T/f4/list.json"
eq "F4 existing name -> its id" "$(run f4 "$FM" FLY_API_TOKEN="$TOK" -- fm_create box-acme-os box-acme-os registry.fly.io/box-image:v1 iad)" "e2860f1c4a7d98|rc=0|err="
eq "F4 0 machine run calls" "$(grep -c '^machine run' "$T/f4/fly.argv")" 0
eq "F4 0 apps create calls (status answered)" "$(grep -c '^apps create' "$T/f4/fly.argv")" 0
# The create path: app missing -> apps create, machine run, id read back by name.
mk f4b
echo '[{"id":"e2860f1c4a7d98","name":"box-acme-os","state":"created"}]' > "$T/f4b/after-run.json"
eq "F4 new machine -> its id" "$(run f4b "$FM" FLY_API_TOKEN="$TOK" STUB_STATUS_RC=1 -- fm_create box-acme-os box-acme-os registry.fly.io/box-image:v1 iad)" "e2860f1c4a7d98|rc=0|err="
eq "F4 one apps create with the org" "$(grep -c '^apps create box-acme-os --org fixture-org$' "$T/f4b/fly.argv")" 1
eq "F4 one machine run" "$(grep -c '^machine run registry.fly.io/box-image:v1 -a box-acme-os --name box-acme-os --region iad --detach$' "$T/f4b/fly.argv")" 1
# A run that leaves no machine with the name is rc 1, never an id.
mk f4c
has "F4 no id after run -> rc 1" "$(run f4c "$FM" FLY_API_TOKEN="$TOK" -- fm_create box-acme-os box-acme-os registry.fly.io/box-image:v1 iad)" "|rc=1|"

# F5 — an unseeded key is rc 70.
mk f5
r=$(run f5 "$FM" HARNESS_VENDOR_FAKE=1 -- fm_state box-acme-os 0000000000abcd)
has "F5 unseeded rc 70" "$r" "|rc=70|"
has "F5 not implemented" "$r" "not implemented"
has "F5 ts unseeded rc 70" "$(run f5 "$TS" HARNESS_VENDOR_FAKE=1 TS_K="$KEY" -- ts_join unseeded-host TS_K)" "|rc=70|"

# F6 — no token: rc 3, 0 calls. No flyctl: rc 127.
mk f6
r=$(run f6 "$FM" -- fm_state box-acme-os e2860f1c4a7d98)
has "F6 no token rc 3" "$r" "|rc=3|"
has "F6 no token text" "$r" "no Fly token"
eq "F6 0 calls" "$(count "$T/f6/fly.argv")" 0
rm -f "$T/f6/bin/flyctl"
# A PATH with no flyctl at all (the budget suite puts a stub flyctl first on PATH).
r=$(run f6 "$FM" FLY_API_TOKEN="$TOK" PATH="$T/f6/bin:/usr/bin:/bin" -- fm_state box-acme-os e2860f1c4a7d98)
has "F6 no flyctl rc 127" "$r" "|rc=127|"
has "F6 no flyctl text" "$r" "flyctl not found"

# F7 — the Tailscale key is staged on stdin, never argv.
mk f7
echo '[{"id":"e2860f1c4a7d98","name":"box-acme-os","state":"created"}]' > "$T/f7/after-run.json"
run f7 "$FM" FLY_API_TOKEN="$TOK" TS_AUTHKEY="$KEY" FM_TS_KEY_VAR=TS_AUTHKEY -- fm_create box-acme-os box-acme-os registry.fly.io/box-image:v1 iad >/dev/null
eq "F7 one secrets import --stage" "$(grep -c '^secrets import -a box-acme-os --stage$' "$T/f7/fly.argv")" 1
eq "F7 the stdin is TS_AUTHKEY=<key>" "$(grep -c "^stdin=$(sha16 "TS_AUTHKEY=$KEY"$'\n')$" "$T/f7/fly.argv")" 1
eq "F7 the key is in no argv" "$(grep -cF "$KEY" "$T/f7/fly.argv")" 0
eq "F7 import before run" "$(grep -nE '^(secrets import|machine run)' "$T/f7/fly.argv" | cut -d: -f2 | cut -d' ' -f1 | tr '\n' ' ')" "secrets machine "
has "F7 a bad key var name is rc 2" "$(run f7 "$FM" FLY_API_TOKEN="$TOK" FM_TS_KEY_VAR='a;b' -- fm_create box-acme-os box-acme-os registry.fly.io/box-image:v1 iad)" "|rc=2|"

# T1 — the ts_ip_ok table.
tsok() { env bash -c '. "$1" || exit 98; ts_ip_ok "$2"' _ "$TS" "$1"; echo $?; }
# The first octet is joined at run time: the share mirror refuses a committed
# 100.x dotted quad other than the mapped stub (bin/share/mapping.py TAILNET_IPS).
C=100
for a in "$C.64.0.0" "$C.127.255.255" "$C.101.102.103"; do  # fixture-hygiene-allow: the 100.64/10 edges ts_ip_ok must accept
  eq "T1 accept $a" "$(tsok "$a")" 0
done
for a in "$C.63.255.255" "$C.128.0.0" 10.1.2.3 "$C.64.0.256" "$C.64.1" "$C.064.0.1" fd7a:115c:a1e0::1 "" "$C.64.0.1 " "x$C.64.0.1"; do  # fixture-hygiene-allow: refused rows around the 100.64/10 range
  eq "T1 refuse '$a'" "$(tsok "$a")" 1
done
eq "T1 refuse two lines" "$(tsok "$(printf '%s\n%s' "$TSIP" "$OWNIP")")" 1

# T2 — ts_join real mode: the key on stdin, the hostname, one call log line.
mk t2
printf '%s\n' "$TSIP" > "$T/t2/ts.out"
eq "T2 answer" "$(run t2 "$TS" TS_K="$KEY" -- ts_join fdaa:0:1a2b:a7b:1::5 TS_K acme-os-box)" "$TSIP|rc=0|err="
eq "T2 one ssh call" "$(grep -c '^-o BatchMode=yes' "$T/t2/ssh.argv")" 1
has "T2 ssh to root@<host>" "$(cat "$T/t2/ssh.argv")" "root@fdaa:0:1a2b:a7b:1::5"
has "T2 a new host key is accepted (no tty under cron)" "$(cat "$T/t2/ssh.argv")" "-o StrictHostKeyChecking=accept-new"
has "T2 --hostname" "$(cat "$T/t2/ssh.argv")" "--hostname=acme-os-box"
has "T2 the key is a file" "$(cat "$T/t2/ssh.argv")" '--auth-key="file:$f"'
eq "T2 the key is in no argv" "$(grep -cF "$KEY" "$T/t2/ssh.argv")" 0
eq "T2 the key is the stdin" "$(grep -c "^stdin=$(sha16 "$KEY"$'\n')$" "$T/t2/ssh.argv")" 1
eq "T2 one call log line" "$(grep -cE '^[0-9]+ tailscale join$' "$T/t2/calls.log")" 1
mk t2b
printf '%s\n' "$TSIP" > "$T/t2b/ts.out"
r=$(run t2b "$TS" TS_K="$KEY" SSH_RC=255 -- ts_join fdaa:0:1a2b:a7b:1::5 TS_K acme-os-box)
has "T2 an ssh failure is rc 1" "$r" "|rc=1|"
hasnt "T2 the key is not in the error" "$r" "$KEY"
printf '10.9.9.9\n' > "$T/t2b/ts.out"  # fixture-hygiene-allow: an answer outside 100.64/10 must be refused
has "T2 an answer outside the range is rc 1" "$(run t2b "$TS" TS_K="$KEY" -- ts_join fdaa:0:1a2b:a7b:1::5 TS_K acme-os-box)" "rc=1|err=tailscale: answer is not one 100.64/10 address"

# T3 — refusals before ssh.
mk t3
has "T3 bad var name" "$(run t3 "$TS" -- ts_join acme-box 'bad-name')" "|rc=2|"
r=$(run t3 "$TS" TS_K= -- ts_join acme-box TS_K)
has "T3 empty var rc 3" "$r" "|rc=3|"
has "T3 empty var text" "$r" "tailscale: TS_K is not set"
for h in 'acme box' 'a;rm -rf /' '$(id)' '-oProxyCommand=x' 'ACME..box'; do
  has "T3 bad host '$h'" "$(run t3 "$TS" TS_K="$KEY" -- ts_join "$h" TS_K)" "|rc=2|"
done
has "T3 bad ts hostname" "$(run t3 "$TS" TS_K="$KEY" -- ts_join acme-box TS_K 'Bad_Host')" "|rc=2|"
has "T3 ts_ip bad host" "$(run t3 "$TS" -- ts_ip '$(id)')" "|rc=2|"
eq "T3 0 ssh calls" "$(count "$T/t3/ssh.argv")" 0

# T4 — a seeded error is rc 1 with its text.
mk t4
r=$(run t4 "$TS" HARNESS_VENDOR_FAKE=1 TS_K="$KEY" -- ts_join fdaa:0:1a2b:a7b:1::6 TS_K acme-os-box)
eq "T4 seeded error" "$r" "|rc=1|err=tailscale up: auth key expired"
eq "T4 fake join answer" "$(run t4 "$TS" HARNESS_VENDOR_FAKE=1 TS_K="$KEY" -- ts_join fdaa:0:1a2b:a7b:1::5 TS_K acme-os-box)" "$TSIP|rc=0|err="
eq "T4 0 ssh calls in fake mode" "$(count "$T/t4/ssh.argv")" 0

# T5 — ts_ip fake and real; two lines are refused.
mk t5
eq "T5 fake ts_ip" "$(run t5 "$TS" HARNESS_VENDOR_FAKE=1 -- ts_ip acme-own-box)" "$OWNIP|rc=0|err="
printf '%s\n' "$OWNIP" > "$T/t5/ts.out"
eq "T5 real ts_ip" "$(run t5 "$TS" -- ts_ip acme-own-box)" "$OWNIP|rc=0|err="
eq "T5 ts_ip sends no stdin" "$(grep -c "^stdin=$(sha16 '')$" "$T/t5/ssh.argv")" 1
eq "T5 one ts ip call log line" "$(grep -cE '^[0-9]+ tailscale ip$' "$T/t5/calls.log")" 1
printf '%s\n%s\n' "$OWNIP" "$TSIP" > "$T/t5/ts.out"
has "T5 two lines rc 1" "$(run t5 "$TS" -- ts_ip acme-own-box)" "|rc=1|"

# F8 — the BH-8640 function is not broken by the new source lines.
mk f8
mkdir -p "$T/f8/seeds"
printf '{"run_help": "  --rootfs-size string   fixture help"}\n' > "$T/f8/seeds/fly-machines.json"
has "F8 run_help fake" "$(run f8 "$FM" HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/f8/seeds" -- fly_machines_run_help 5)" "--rootfs-size string   fixture help|rc=0|err="
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$STUB_DIR/fly.argv"\necho "  --rootfs-size string"\n' > "$T/f8/bin/fly-help"; chmod +x "$T/f8/bin/fly-help"
has "F8 run_help real" "$(run f8 "$FM" FLY="$T/f8/bin/fly-help" -- fly_machines_run_help 5)" "--rootfs-size string|rc=0"
eq "F8 run_help real argv" "$(cat "$T/f8/fly.argv")" "machine run --help"

echo "vendor-seams.bh-7939: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
