#!/bin/bash
# tests/rr-relay-rows.bh-7860-test.sh — THE RELAY JSON AS A LEDGER ROW (BH-7860,
# slice C0; the rest of C3 of #4157).
#
# A remote build's result reaches its owning box as a relay json,
# state/remote-results/<p>/<KEY>.json. bin/lib/rr-relay.sh gives that json an
# `rr-relay` ledger row, key <p>/<KEY>@<build-id> (the key rr-consumed uses):
# the writer parks it (status parked, detail the payload), and the consumer
# (rrc_json_consume) sets the status to its outcome. The hub's pending count in
# bin/fleet-status-push.sh asks the rr-consumed row before it counts a json.
# The files stay written and stay the input.
#
# Driven, not grepped: the REAL lib, the REAL rrc_json_consume, the REAL
# bin/fly-results-ingest.sh (real jobs client, curl stubbed) and the REAL
# bin/fleet-status-push.sh. The ledger is a stub over a per-test dir that keeps
# a parked detail when a PUT carries none (the worker's COALESCE). No network.
#
#   K rowkey   P park   C consumed   S consume settles   R round trip
#   I the ingest writer   F the status-push reader
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/rr-relay-rows.bh-7860-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset JOBS_BOX DLOG

H="$T/h"; P=project-3
RR="$H/state/remote-results/$P"
LEDGER="$T/ledger"
export LEDGER

# ── the stub client ──────────────────────────────────────────────────────────
# $LEDGER/<kind>/<urlencoded key> holds {status, detail}. A PUT with no detail
# keeps the stored one, as the worker's `detail=COALESCE(?, detail)` does.
# $LEDGER/.row-down -> every read rc 1; $LEDGER/.put-down -> every write rc 1.
cat > "$T/stub.sh" <<'SH'
_stub_f() { printf '%s/%s/%s' "$LEDGER" "$1" "$(printf '%s' "$2" | jq -sRr @uri)"; }
job_ledger_row() {
  [ -f "$LEDGER/.row-down" ] && return 1
  local f; f=$(_stub_f "$1" "$2")
  [ -f "$f" ] || return 2
  cat "$f"
}
job_ledger_put() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  [ -f "$LEDGER/.put-down" ] && return 1
  local f d="${4:-}"; f=$(_stub_f "$1" "$2")
  mkdir -p "$LEDGER/$1"
  [ -z "$d" ] && [ -f "$f" ] && d=$(jq -r '.detail // ""' "$f")
  jq -nc --arg s "$3" --arg d "$d" '{status:$s, detail:$d}' > "$f"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LEDGER/.puts"
}
SH

reset() {
  scratch_rm "$H"; scratch_rm "$LEDGER"
  mkdir -p "$H/logs" "$H/state" "$LEDGER"
}
seed() { mkdir -p "$LEDGER/$1"; jq -nc --arg s "$3" --arg d "${4:-}" '{status:$s, detail:$d}' > "$LEDGER/$1/$(printf '%s' "$2" | jq -sRr @uri)"; }
rowf() { printf '%s/%s/%s' "$LEDGER" "$1" "$(printf '%s' "$2" | jq -sRr @uri)"; }
puts() { local n; n=$(grep -c -- "$1" "$LEDGER/.puts" 2>/dev/null); echo "${n:-0}"; }
plog() { local n; n=$(grep -c -- "$1" "$H/logs/$P.log" 2>/dev/null); echo "${n:-0}"; }

# lib <cmd...> — the two libs with the stub client in a subshell (NOSTUB=1: none).
lib() {
  mkdir -p "$T/tmp"
  ( export HARNESS="$H" LOG="$H/logs/$P.log" STAMP=2026-10-21T00:00:00Z TMPDIR="$T/tmp"
    [ "${NOSTUB:-0}" = 1 ] || . "$T/stub.sh"
    . "$DIR/bin/lib/rr-relay.sh" || exit 9
    . "$DIR/bin/lib/rr-cursor.sh" || exit 9
    "$@" )
}
# payload <key> <build_dir> <machine_build_dir> [result] — the shape
# bin/fly-results-ingest.sh writes.
payload() {
  jq -nc --arg k "$1" --arg bd "$2" --arg mbd "$3" --arg r "${4:-PR_CREATED https://github.com/o/r/pull/1}" \
    '{key:$k,ticket_id:"1",result:$r,pr_url:"",tier:"",build_dir:$bd,machine_build_dir:$mbd,ingested_at:"2026-10-21 00:00:00Z",source:"fly"}'
}
fixture() { mkdir -p "$T/fx"; printf '%s\n' "$2" > "$T/fx/$1"; printf '%s' "$T/fx/$1"; }

# ═════════════════════════════════════════════════════════════════════════════
# K — rrr_rowkey: the chain rrc_json_consume uses
# ═════════════════════════════════════════════════════════════════════════════
reset
F=$(fixture TK-1.json "$(payload TK-1 pool-project-3-TK-1-20261021 project-3-TK-1-m)")
eq "K1: build_dir is the build id" "$(lib rrr_rowkey "$F")" TK-1@pool-project-3-TK-1-20261021
F=$(fixture TK-1.json "$(payload TK-1 /root/harness/builds/x project-3-TK-1-m)")
eq "K2: a build_dir path -> its last segment" "$(lib rrr_rowkey "$F")" TK-1@x
F=$(fixture TK-1.json "$(payload TK-1 '' project-3-TK-1-m)")
eq "K3: no build_dir -> machine_build_dir" "$(lib rrr_rowkey "$F")" TK-1@project-3-TK-1-m
F=$(fixture TK-1.json "$(payload TK-1 '' '')")
eq "K4: neither -> the sha" "$(lib rrr_rowkey "$F")" "TK-1@$(sha256sum < "$F" | cut -c1-16)"
F=$(fixture TK-2.json "$(payload '' pool-b '')")
eq "K4: no .key -> the basename" "$(lib rrr_rowkey "$F")" TK-2@pool-b
F=$(fixture TK-1.json "$(payload TK-1 pool-a project-3-TK-1-m)")
eq "K4: an explicit build id wins" "$(lib rrr_rowkey "$F" pool-z)" TK-1@pool-z
F=$(fixture TK-9.json 'not json {')
eq "K4: not json -> basename and sha (the badjson key)" "$(lib rrr_rowkey "$F")" "TK-9@$(sha256sum < "$F" | cut -c1-16)"
lib rrr_rowkey "$T/fx/absent.json" >/dev/null; eq "K4: a missing file is rc 1" "$?" 1

# ═════════════════════════════════════════════════════════════════════════════
# P — rrr_park
# ═════════════════════════════════════════════════════════════════════════════
reset
lib rrr_park "$P" "$(payload TK-1 pool-project-3-TK-1-a project-3-TK-1-m)"; eq "P1: rc" "$?" 0
R=$(rowf rr-relay "$P/TK-1@pool-project-3-TK-1-a")
eq "P1: the row is parked" "$(jq -r .status "$R" 2>/dev/null)" parked
eq "P1: the detail is the payload" "$(jq -r '.detail | fromjson | .key' "$R" 2>/dev/null)" TK-1
eq "P1: the detail keeps the machine dir" "$(jq -r '.detail | fromjson | .machine_build_dir' "$R" 2>/dev/null)" project-3-TK-1-m
eq "P1: exactly one PUT" "$(puts rr-relay)" 1
[ -z "$(ls -A "$T/tmp" 2>/dev/null)" ] && ok || bad "P1: the temp file must be removed: $(ls -A "$T/tmp")"

reset
BIG=$(head -c 5000 /dev/zero | tr '\0' r)
lib rrr_park "$P" "$(payload TK-2 pool-project-3-TK-2-a '' "$BIG")"
R=$(rowf rr-relay "$P/TK-2@pool-project-3-TK-2-a")
eq "P2: a big payload still parks" "$(jq -r .status "$R" 2>/dev/null)" parked
eq "P2: .result cut to 1000 chars" "$(jq -r '.detail | fromjson | .result | length' "$R" 2>/dev/null)" 1000
eq "P2: the rest of the payload stays" "$(jq -r '.detail | fromjson | .build_dir' "$R" 2>/dev/null)" pool-project-3-TK-2-a
lib rrr_park "$P" "$(payload TK-3 pool-project-3-TK-3-a '' "$(head -c 900 /dev/zero | tr '\0' r)")"
eq "P2: a small payload is not cut" "$(jq -r '.detail | fromjson | .result | length' "$(rowf rr-relay "$P/TK-3@pool-project-3-TK-3-a")" 2>/dev/null)" 900

reset
: > "$LEDGER/.put-down"
lib rrr_park "$P" "$(payload TK-1 pool-a '')"; eq "P3: a failed PUT is rc 0" "$?" 0
eq "P3: one log line" "$(plog 'rr-relay row NOT written for TK-1@pool-a')" 1
rm -f "$LEDGER/.put-down"
( export HARNESS="$H" DLOG="$H/logs/dlog.log"; . "$T/stub.sh"; : > "$LEDGER/.put-down"
  . "$DIR/bin/lib/rr-relay.sh"; rrr_park "$P" "$(payload TK-1 pool-a '')" )
eq "P3: DLOG wins when set" "$(grep -c 'rr-relay row NOT written' "$H/logs/dlog.log" 2>/dev/null)" 1
rm -f "$LEDGER/.put-down"

reset
lib rrr_park ../x "$(payload TK-1 pool-a '')"; eq "P4: project ../x is refused" "$?" 1
lib rrr_park a/b "$(payload TK-1 pool-a '')"; eq "P4: project a/b is refused" "$?" 1
( unset HARNESS H; . "$T/stub.sh"; . "$DIR/bin/lib/rr-relay.sh"; rrr_park "$P" "$(payload TK-1 pool-a '')" ); eq "P4: no HARNESS root is refused" "$?" 1
eq "P4: a refused id writes no row" "$(puts rr-relay)" 0

reset
NOSTUB=1 lib rrr_park "$P" "$(payload TK-1 pool-a '')"; eq "P5: no client -> rc 0" "$?" 0
eq "P5: no client -> no row" "$(find "$LEDGER" -type f | wc -l | tr -d ' ')" 0
lib rrr_park "$P" 'not json'; eq "P6: a payload that is not json -> rc 0" "$?" 0
lib rrr_park "$P" '{"result":"x"}'; eq "P6: a payload with no key -> rc 0" "$?" 0
eq "P6: ...and no row" "$(puts rr-relay)" 0

# ═════════════════════════════════════════════════════════════════════════════
# C — rrr_consumed asks rr-consumed for this exact key
# ═════════════════════════════════════════════════════════════════════════════
reset
F=$(fixture TK-1.json "$(payload TK-1 pool-project-3-TK-1-a project-3-TK-1-m)")
seed rr-consumed "$P/TK-1@pool-project-3-TK-1-a" staged
OUT=$(lib rrr_consumed "$P" "$F"); eq "C1: a staged row -> rc 0" "$?" 0
eq "C1: prints the status" "$OUT" staged
seed rr-consumed "$P/TK-1@pool-project-3-TK-1-a" duplicate
eq "C1: duplicate" "$(lib rrr_consumed "$P" "$F")" duplicate
reset
F=$(fixture TK-1.json "$(payload TK-1 pool-project-3-TK-1-a project-3-TK-1-m)")
lib rrr_consumed "$P" "$F" >/dev/null; eq "C2: no row -> rc 2" "$?" 2
seed rr-consumed "$P/TK-1@pool-project-3-TK-1-a" staged; : > "$LEDGER/.row-down"
lib rrr_consumed "$P" "$F" >/dev/null; eq "C3: an unreadable row -> rc 1" "$?" 1
rm -f "$LEDGER/.row-down"
reset
F=$(fixture TK-1.json "$(payload TK-1 pool-project-3-TK-1-a project-3-TK-1-m)")
seed rr-consumed "$P/TK-1@pool-project-3-TK-1-OTHER" staged
seed rr-consumed "project-3/TK-1@pool-project-3-TK-1-a" staged
lib rrr_consumed "$P" "$F" >/dev/null; eq "C4: another build or another project's row -> rc 2" "$?" 2
NOSTUB=1 lib rrr_consumed "$P" "$F" >/dev/null; eq "C5: no client -> rc 1" "$?" 1
lib rrr_consumed ../x "$F" >/dev/null; eq "C5: a bad project -> rc 1" "$?" 1
lib rrr_consumed "$P" "$T/fx/absent.json" >/dev/null; eq "C5: a missing file -> rc 1" "$?" 1
seed rr-consumed "$P/TK-1@pool-project-3-TK-1-a" ""
lib rrr_consumed "$P" "$F" >/dev/null; eq "C5: a row with no status -> rc 1" "$?" 1

# ═════════════════════════════════════════════════════════════════════════════
# S — rrc_json_consume settles the rr-relay row
# ═════════════════════════════════════════════════════════════════════════════
consume_case() { # consume_case <outcome> -> the rr-relay row file
  reset; mkdir -p "$RR"
  local pl; pl=$(payload TK-1 pool-project-3-TK-1-a project-3-TK-1-m)
  lib rrr_park "$P" "$pl"
  printf '%s\n' "$pl" > "$RR/TK-1.json"
  lib rrc_json_consume "$P" "$RR/TK-1.json" "$1" pool-project-3-TK-1-a
  rowf rr-relay "$P/TK-1@pool-project-3-TK-1-a"
}
R=$(consume_case staged)
eq "S1: staged settles the row" "$(jq -r .status "$R" 2>/dev/null)" staged
eq "S1: the parked payload stays the detail" "$(jq -r '.detail | fromjson | .key' "$R" 2>/dev/null)" TK-1
[ -f "$RR/.handled/TK-1.json" ] && [ ! -e "$RR/TK-1.json" ] && ok || bad "S1: the json must still move to .handled"
eq "S1: the rr-consumed row is still written" "$(jq -r .status "$(rowf rr-consumed "$P/TK-1@pool-project-3-TK-1-a")" 2>/dev/null)" staged
R=$(consume_case duplicate)
eq "S2: duplicate settles the row" "$(jq -r .status "$R" 2>/dev/null)" duplicate
R=$(consume_case empty)
eq "S2: empty settles the row" "$(jq -r .status "$R" 2>/dev/null)" empty
reset; mkdir -p "$RR"; printf 'nope {' > "$RR/TK-9.json"
SHA=$(sha256sum < "$RR/TK-9.json" | cut -c1-16)
lib rrc_json_consume "$P" "$RR/TK-9.json" badjson
eq "S3: badjson row keyed on basename and sha" "$(jq -r .status "$(rowf rr-relay "$P/TK-9@$SHA")" 2>/dev/null)" badjson
reset; mkdir -p "$RR"; printf '%s\n' "$(payload TK-1 pool-a '')" > "$RR/TK-1.json"
lib rrc_json_consume "$P" "$RR/TK-1.json" bogus; eq "S3: an unknown outcome writes no row" "$(puts rr-relay)" 0

# ═════════════════════════════════════════════════════════════════════════════
# R — one key: the writer, the consumer, the reader
# ═════════════════════════════════════════════════════════════════════════════
reset; mkdir -p "$RR"
PL=$(payload TK-7 fly-project-3-TK-7-20261021000000 project-3-TK-7-m)
lib rrr_park "$P" "$PL"
printf '%s\n' "$PL" > "$RR/TK-7.json"; HUBC=$(fixture TK-7.json "$PL")
lib rrc_json_consume "$P" "$RR/TK-7.json" staged fly-project-3-TK-7-20261021000000
eq "R1: one rr-relay key for parked and staged" "$(find "$LEDGER/rr-relay" -type f | wc -l | tr -d ' ')" 1
eq "R1: the row ends staged" "$(jq -r .status "$(rowf rr-relay "$P/TK-7@fly-project-3-TK-7-20261021000000")" 2>/dev/null)" staged
eq "R1: the reader finds the consumer's row" "$(lib rrr_consumed "$P" "$HUBC")" staged

# ═════════════════════════════════════════════════════════════════════════════
# I — the real bin/fly-results-ingest.sh writes the row
# ═════════════════════════════════════════════════════════════════════════════
HI="$T/hi"
mkdir -p "$HI/bin" "$HI/env" "$HI/flags" "$HI/logs" "$HI/state/fly" "$HI/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-3_OS=tok-fixture-1\n' > "$HI/env/fly.env"
printf '#!/bin/bash\nexit 0\n' > "$HI/bin/beat.sh"
printf '#!/bin/bash\ncase "${1:-}" in --tailnet-ip) echo "$BOX_IP"; exit 0 ;; esac\nexit 1\n' > "$HI/bin/fleet-conf.sh"
chmod +x "$HI/bin/beat.sh" "$HI/bin/fleet-conf.sh"
scratch_install_closure bin/fly-results-ingest.sh "$HI" >/dev/null || bad "I setup: cannot install the ingest closure"
scratch_install_closure bin/jobs-client.sh "$HI" >/dev/null || bad "I setup: cannot install the jobs client closure"
cat > "$T/fakebin/flyctl" <<'SH'
#!/bin/bash
case "$*" in
  *echo*yes*)   echo yes ;;
  *cat*RESULT*) cat "$RESULT_SRC" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/flyctl"; cp "$T/fakebin/flyctl" "$T/fakebin/fly"
cat > "$T/fakebin/ssh" <<'SH'
#!/bin/bash
printf 'ssh %s\n' "$*" >> "$SSH_SINK"
case "$*" in *remote-results*) cat > /dev/null; exit "${SSH_RC:-0}" ;; esac
exit 0
SH
chmod +x "$T/fakebin/ssh"
# The worker: every feed empty, a ledger GET is a 404, a ledger PUT is recorded.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET body=""
while [ $# -gt 1 ]; do
  case "$1" in -X) m="$2"; shift ;; --data-binary|-d|--data) body="$2"; shift ;; esac
  shift
done
URL="$1"
case "$m $URL" in
  "PUT "*/api/ledger) printf '%s\n' "$body" >> "$LEDGER_SINK"; printf '{"ok":true}\n200' ;;
  "GET "*/api/ledger*) printf '{}\n404' ;;
  *"/api/artifacts"*)  printf '{"artifacts":[]}\n200' ;;
  *) printf '{}\n200' ;;
esac
SH
chmod +x "$T/fakebin/curl"

iseed() { # iseed <RESULT line 1>
  local d; for d in "$HI/builds/fly-"* "$HI/state/remote-results"; do scratch_rm "$d"; done
  jq -nc '{key:"TK-9",ticket_id:"T1"}' > "$HI/state/fly/project-3-active.json"
  jq -nc '{app:"builder-project-3"}' > "$HI/state/fly/project-3.json"
  printf '%s\nTIER: 2\nBUILD_DIR: project-3-TK-9-m1\n' "$1" > "$T/result.src"
  : > "$T/ssh.txt"; : > "$T/ledger-puts.txt"; : > "$HI/logs/fly-dispatch.log"
}
hub() {
  ( export HARNESS="$HI" JOBS_HARNESS="$HI" HARNESS_SECRET=fixture-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_BEAT_SECS=3600 \
           RESULT_SRC="$T/result.src" SSH_SINK="$T/ssh.txt" LEDGER_SINK="$T/ledger-puts.txt" \
           BOX_IP="$BOX_IP" SSH_RC="${SSH_RC:-0}" PATH="$T/fakebin:$PATH"
    bash "$HI/bin/fly-results-ingest.sh" project-3 >/dev/null 2>&1 )
}
relay_rows() { jq -c 'select(.kind == "rr-relay")' "$T/ledger-puts.txt" 2>/dev/null; }

iseed 'PR_CREATED https://github.com/o/r/pull/9 | tier 2'; BOX_IP=local hub
J="$HI/state/remote-results/project-3/TK-9.json"
[ -s "$J" ] && ok || bad "I1: box local must still write the json file"
ROW=$(relay_rows)
eq "I1: one rr-relay PUT" "$(printf '%s' "$ROW" | grep -c .)" 1
eq "I1: status parked" "$(printf '%s' "$ROW" | jq -r .status 2>/dev/null)" parked
BD=$(jq -r .build_dir "$J" 2>/dev/null)
eq "I1: keyed <p>/<KEY>@<hub build dir>" "$(printf '%s' "$ROW" | jq -r .key 2>/dev/null)" "project-3/TK-9@$BD"
eq "I1: the detail is the json the file holds" "$(printf '%s' "$ROW" | jq -c '.detail | fromjson' 2>/dev/null)" "$(jq -c . "$J" 2>/dev/null)"

iseed 'PR_CREATED https://github.com/o/r/pull/9 | tier 2'; BOX_IP=192.0.2.9 SSH_RC=1 hub
eq "I2: a remote box with ssh down still parks the row" "$(relay_rows | jq -r .status 2>/dev/null)" parked
grep -q 'could not scp remote-result to 192.0.2.9 for TK-9' "$HI/logs/fly-dispatch.log" && ok \
  || bad "I2: the scp failure line must still print: $(tail -3 "$HI/logs/fly-dispatch.log")"
grep -q 'remote-results/project-3/TK-9.json' "$T/ssh.txt" && ok || bad "I2: the ssh must still be tried"

iseed 'PR_CREATED https://github.com/o/r/pull/9 | tier 2 | CLOSED-OUT: posted'; BOX_IP=local hub
[ ! -e "$HI/state/remote-results/project-3/TK-9.json" ] && ok || bad "I3: a delivered result writes no json"
grep -q 'bookkeeping only' "$HI/logs/fly-dispatch.log" && ok || bad "I3: the delivered branch must run: $(tail -3 "$HI/logs/fly-dispatch.log")"
eq "I3: a delivered result writes no rr-relay row" "$(relay_rows | grep -c .)" 0

# ═════════════════════════════════════════════════════════════════════════════
# F — the real bin/fleet-status-push.sh pending count asks rr-consumed
# ═════════════════════════════════════════════════════════════════════════════
FH="$T/fh"
mkdir -p "$FH/bin" "$FH/logs" "$FH/state" "$FH/flags" "$FH/env" "$FH/builds" "$T/fpbin"
printf 'HARNESS_SECRET=fixture-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$FH/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$FH/bin/beat.sh"; chmod +x "$FH/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fpbin/curl"; chmod +x "$T/fpbin/curl"
# The jobs client: the stub ledger functions when sourced, nothing else.
{ printf '#!/bin/bash\n'; cat "$T/stub.sh"; printf '[ "${BASH_SOURCE[0]}" = "$0" ] || return 0\nexit 2\n'; } > "$FH/bin/jobs-client.sh"
chmod +x "$FH/bin/jobs-client.sh"
scratch_install_closure bin/fleet-status-push.sh "$FH" >/dev/null || bad "F setup: cannot install the status-push closure"
scratch_install_closure bin/fleet-conf.sh "$FH" >/dev/null || bad "F setup: cannot install fleet-conf"
cat > "$FH/fleet.conf" <<'EOF'
project-3 Org/project-3 https://a.example /api/board 2 box-project-3-1
EOF
OLD=$(date -d '2 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-2H +%Y%m%d%H%M)
FRR="$FH/state/remote-results/project-3"
fseed() {
  scratch_rm "$FRR"; scratch_rm "$LEDGER"; mkdir -p "$FRR" "$LEDGER"
  payload TK-1 pool-project-3-TK-1-a project-3-TK-1-m > "$FRR/TK-1.json"
  payload TK-2 pool-project-3-TK-2-a project-3-TK-2-m > "$FRR/TK-2.json"
  touch -t "$OLD" "$FRR/TK-1.json" "$FRR/TK-2.json"
}
fpush() { rm -f "$T/PUSH.json"; PATH="$T/fpbin:$PATH" HARNESS="$FH" FLEET_CONF="$FH/fleet.conf" bash "$FH/bin/fleet-status-push.sh" >/dev/null 2>&1
          jq -r '.remote_results_pending."project-3" // "absent"' "$T/PUSH.json" 2>/dev/null; }

fseed; seed rr-consumed "project-3/TK-1@pool-project-3-TK-1-a" staged
eq "F1: a json with an rr-consumed row is not pending" "$(fpush)" 1
fseed
eq "F1: with no rows both are pending (F1 can fail)" "$(fpush)" 2
fseed; seed rr-consumed "project-3/TK-1@pool-project-3-TK-1-a" staged; : > "$LEDGER/.row-down"
eq "F2: an unreadable row counts the json" "$(fpush)" 2
fseed; seed rr-consumed "project-3/TK-1@pool-project-3-TK-1-a" staged
mv "$FH/bin/jobs-client.sh" "$T/jc.off"
eq "F3: no jobs client counts the json" "$(fpush)" 2
mv "$T/jc.off" "$FH/bin/jobs-client.sh"
fseed; seed rr-consumed "project-3/TK-1@pool-project-3-TK-1-a" staged
seed rr-consumed "project-3/TK-1@pool-project-3-TK-1-OTHER" staged
eq "F4: another project's or another build's row counts the json" "$(fpush)" 2

echo "rr-relay-rows: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
