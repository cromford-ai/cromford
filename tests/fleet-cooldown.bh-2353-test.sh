#!/bin/bash
# tests/fleet-cooldown.bh-2353-test.sh — BH-2353 (BH-2319.1): the worker
# backend of bin/lib/fleet-cooldown.sh and the cooldown_* client verbs in
# bin/lib/jobs/machines.sh. Sources the REAL seam and the REAL verbs; only
# _jobs_req is a stub, which records "<method> <path> <body>" to $T/calls and
# answers from $T/ans/<key> (+ <key>.rc), key = "<method> <path>" with every
# non-alphanumeric turned into _.
#
#   S1 fcd_put sends POST /api/cooldowns with the exact JSON body
#   S2 fcd_live is one GET per kind per process; a put drops that kind's memo
#   S3 FLEET_COOLDOWN_DB=0 sends no request
#   S4 a failed put: cooldown_put rc 2, fcd_put rc 0, one agent-rules.log line; live rc 2
#   S5 no client beside the lib: put 0, live/clear 2, list empty under set -euo pipefail;
#      a real (unconfigured) client beside it loads lazily and leaves the caller's options alone;
#      a client missing a module is never sourced (it would exit the caller)
#   S6 ssh/scp/rsync shadowed to fail: same answers, never called
#   S7 codex/default is not claude/default; a truncated list: hit 0, miss 2
#   S8 cooldown_clear and cooldown_list rcs; fcd_list prints live rows only, six fields
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/fleet-cooldown.bh-2353-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/fleet-cooldown.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Nothing here may reach a real worker: no secret, no URL, env dir in $T.
unset FLEET_COOLDOWN_DB FLEET_COOLDOWN_STORE HARNESS_SECRET JOBS_URL
export HARNESS="$T" HARNESS_ENV_DIR="$T/env" JOBS_BOX=testbox
mkdir -p "$T/logs" "$T/ans"
FUT=4102444800

cat > "$T/prelude.sh" <<EOF
. "$LIB" || exit 99
. "$DIR/bin/lib/jobs/machines.sh" || exit 99
_jobs_req() {
  local key; key=\$(printf '%s' "\$1 \$2" | tr -c 'A-Za-z0-9' _)
  printf '%s %s %s\n' "\$1" "\$2" "\${3:-}" >> "$T/calls"
  cat "$T/ans/\$key" 2>/dev/null
  return "\$(cat "$T/ans/\$key.rc" 2>/dev/null || echo 0)"
}
EOF
# run <script>: a fresh process (fresh memo) with the seam, the verbs and the stub.
run() { bash -c ". '$T/prelude.sh'; $1" 2>&1; }
answer() { printf '%s' "$2" > "$T/ans/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; }
answer_rc() { printf '%s' "$2" > "$T/ans/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _).rc"; }
# The box cache (state/fleet-cooldown, lead fix round) is dropped too: every
# section here pins what ONE process reads, and tests/fleet-cooldown-cache.bh-2353-test.sh
# pins what processes share.
reset() { rm -f "$T/calls" "$T/ans"/*; scratch_rm "$T/state"; : > "$T/logs/agent-rules.log"; }
calls() { cat "$T/calls" 2>/dev/null; }
row() { printf '{"kind":"%s","vendor":"%s","subject":"%s","until":%s,"since":null,"reason":"r","box":"hub","set_at":1}' "$@"; }

# ---------- S1 exact body -----------------------------------------------------
reset
answer "POST /api/cooldowns" '{"ok":true,"row":{}}'
out=$(run "fcd_put account claude a $FUT 100 r; echo rc=\$?")
[ "$out" = "rc=0" ] && ok || bad "S1 out: $out"
[ "$(calls | wc -l)" = 1 ] && ok || bad "S1 calls: $(calls)"
[ "$(calls | cut -d' ' -f1,2)" = "POST /api/cooldowns" ] && ok || bad "S1 method/path: $(calls)"
got=$(calls | cut -d' ' -f3- | jq -Sc . 2>/dev/null)
want=$(jq -Snc --argjson u "$FUT" '{kind:"account",vendor:"claude",subject:"a",until:$u,since:100,reason:"r",box:"testbox"}')
[ "$got" = "$want" ] && ok || bad "S1 body: $got want $want"
# No since, no reason: the keys are absent, not "" or 0.
reset; answer "POST /api/cooldowns" '{"ok":true,"row":{}}'
run "fcd_put lane openrouter hub $FUT" >/dev/null
got=$(calls | cut -d' ' -f3- | jq -Sc . 2>/dev/null)
want=$(jq -Snc --argjson u "$FUT" '{kind:"lane",vendor:"openrouter",subject:"hub",until:$u,box:"testbox"}')
[ "$got" = "$want" ] && ok || bad "S1 bare body: $got want $want"

# ---------- S2 memo -------------------------------------------------------------
S2_SCRIPT='for k in "account claude a" "account claude b" "account claude a" "model claude x" "model claude y"; do
  rc=0; fcd_live $k || rc=$?; printf "%s " "$rc"; done; echo'
s2_answers() {
  answer "GET /api/cooldowns?kind=account" "{\"rows\":[$(row account claude a $FUT)],\"truncated\":false}"
  answer "GET /api/cooldowns?kind=model" '{"rows":[],"truncated":false}'
  answer_rc "GET /api/cooldowns?kind=model" 0
}
reset; s2_answers
s2_out=$(run "$S2_SCRIPT")
[ "$s2_out" = "0 1 0 1 1 " ] && ok || bad "S2 rcs: [$s2_out]"
[ "$(calls | grep -c '^GET /api/cooldowns?kind=account ')" = 1 ] && ok || bad "S2 account GETs: $(calls)"
[ "$(calls | grep -c '^GET /api/cooldowns?kind=model ')" = 1 ] && ok || bad "S2 model GETs: $(calls)"
[ "$(calls | wc -l)" = 2 ] && ok || bad "S2 total calls: $(calls)"
# A successful put drops that kind's memo, so the process sees its own write.
reset; s2_answers; answer "POST /api/cooldowns" '{"ok":true,"row":{}}'
run "fcd_live account claude a; fcd_put account claude z $FUT; fcd_live account claude a; fcd_live model claude x; fcd_live model claude x" >/dev/null
[ "$(calls | grep -c '^GET /api/cooldowns?kind=account ')" = 2 ] && ok || bad "S2 put did not drop the memo: $(calls)"
[ "$(calls | grep -c '^GET /api/cooldowns?kind=model ')" = 1 ] && ok || bad "S2 put dropped another kind's memo: $(calls)"

# ---------- S3 FLEET_COOLDOWN_DB=0 ---------------------------------------------
reset; s2_answers
out=$(FLEET_COOLDOWN_DB=0 run "fcd_put account claude a $FUT; echo p=\$?; fcd_live account claude a; echo l=\$?; fcd_clear account claude a; echo c=\$?; echo \"[\$(fcd_list account)]\"")
[ "$out" = "$(printf 'p=0\nl=2\nc=2\n[]')" ] && ok || bad "S3 out: $out"
[ ! -e "$T/calls" ] && ok || bad "S3 sent a request: $(calls)"

# ---------- S4 failed put -------------------------------------------------------
reset
answer_rc "POST /api/cooldowns" 1
answer_rc "GET /api/cooldowns?kind=account" 1
out=$(run "rc=0; cooldown_put account claude a $FUT || rc=\$?; echo cp=\$rc; fcd_put account claude a $FUT; echo fp=\$?; rc=0; fcd_live account claude a || rc=\$?; echo l=\$rc")
[ "$out" = "$(printf 'cp=2\nfp=0\nl=2')" ] && ok || bad "S4 out: $out"
n=$(grep -c 'fleet-cooldown: put account/claude/a not recorded (rc 2)$' "$T/logs/agent-rules.log")
[ "$n" = 1 ] && ok || bad "S4 agent-rules.log lines=$n: $(cat "$T/logs/agent-rules.log")"
[ "$(wc -l < "$T/logs/agent-rules.log")" = 1 ] && ok || bad "S4 log has other lines"
# A 2xx that is not {ok:true} is not a recorded put either.
reset; answer "POST /api/cooldowns" '{"ok":false}'
out=$(run "rc=0; cooldown_put account claude a $FUT || rc=\$?; echo \$rc")
[ "$out" = 2 ] && ok || bad "S4 ok:false put rc: $out"

# ---------- S5 no client / real client ------------------------------------------
mkdir -p "$T/x/bin/lib" "$T/x/logs"
cp "$LIB" "$T/x/bin/lib/"
out=$(env -u HARNESS_SECRET HARNESS="$T/x" HARNESS_ENV_DIR="$T/x/env" bash -c '
  set -euo pipefail
  . "$1"
  fcd_put account claude a 4102444800; echo "put=$?"
  rc=0; fcd_live account claude a || rc=$?; echo "live=$rc"
  rc=0; fcd_clear account claude a || rc=$?; echo "clear=$rc"
  echo "list=[$(fcd_list account)]"
  echo survived' _ "$T/x/bin/lib/fleet-cooldown.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "S5 no-client rc=$rc: $out"
[ "$out" = "$(printf 'put=0\nlive=2\nclear=2\nlist=[]\nsurvived')" ] && ok || bad "S5 no-client out: $out"
grep -q 'fleet-cooldown: put account/claude/a not recorded' "$T/x/logs/agent-rules.log" 2>/dev/null \
  && ok || bad "S5 no-client put was not logged"

mkdir -p "$T/y/bin/lib" "$T/y/logs" "$T/y/env"
cp "$DIR/bin/jobs-client.sh" "$T/y/bin/"
cp -r "$DIR/bin/lib/jobs" "$T/y/bin/lib/"
cp "$LIB" "$DIR/bin/lib/env-path.sh" "$T/y/bin/lib/"
# JOBS_URL="" is "not configured": the real client answers without a network call.
out=$(env -u HARNESS_SECRET JOBS_URL="" HARNESS="$T/y" HARNESS_ENV_DIR="$T/y/env" bash -c '
  before=$(set +o)
  . "$1"
  command -v _jobs_req >/dev/null && echo "loaded-early"
  rc=0; fcd_live account claude a || rc=$?; echo "live=$rc"
  command -v cooldown_list >/dev/null && echo "client-loaded"
  [ "$before" = "$(set +o)" ] && echo "options-unchanged"
  rc=0; fcd_clear account claude a || rc=$?; echo "clear=$rc"
  fcd_put account claude a 4102444800; echo "put=$?"
  [ "$before" = "$(set +o)" ] && echo "options-unchanged"' _ "$T/y/bin/lib/fleet-cooldown.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "S5 real-client rc=$rc: $out"
[ "$out" = "$(printf 'live=2\nclient-loaded\noptions-unchanged\nclear=2\nput=0\noptions-unchanged')" ] \
  && ok || bad "S5 real-client out: $out"
out=$(env -u HARNESS_SECRET JOBS_URL="" HARNESS="$T/y" HARNESS_ENV_DIR="$T/y/env" bash -c '
  set -euo pipefail; . "$1"
  rc=0; fcd_live account claude a || rc=$?; echo "live=$rc"; echo survived' _ "$T/y/bin/lib/fleet-cooldown.sh" 2>&1)
[ "$out" = "$(printf 'live=2\nsurvived')" ] && ok || bad "S5 real-client set -e out: $out"

# A client whose modules did not all arrive would `exit 1` on source; the seam
# checks them first, so the caller lives and the answer is unknown.
cp -r "$T/y" "$T/z"; rm -f "$T/z/bin/lib/jobs/routing.sh"
out=$(env -u HARNESS_SECRET JOBS_URL="" HARNESS="$T/z" HARNESS_ENV_DIR="$T/z/env" bash -c '
  set -euo pipefail; . "$1"
  rc=0; fcd_live account claude a || rc=$?; echo "live=$rc"; echo survived' _ "$T/z/bin/lib/fleet-cooldown.sh" 2>&1)
[ "$out" = "$(printf 'live=2\nsurvived')" ] && ok || bad "S5 half-synced client out: $out"

# ---------- S6 no remote reads ----------------------------------------------------
mkdir -p "$T/shim"
for c in ssh scp rsync; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/remote"\nexit 1\n' "$c" "$T" > "$T/shim/$c"; chmod +x "$T/shim/$c"
done
reset; s2_answers
out=$(PATH="$T/shim:$PATH" run "$S2_SCRIPT; fcd_list account")
[ "$out" = "$s2_out
claude	a	$FUT		r	hub" ] && ok || bad "S6 answers changed: [$out]"
[ ! -e "$T/remote" ] && ok || bad "S6 a remote command ran: $(cat "$T/remote")"

# ---------- S7 negatives and truncation -------------------------------------------
reset
answer "GET /api/cooldowns?kind=account" "{\"rows\":[$(row account codex default $FUT)],\"truncated\":false}"
out=$(run 'rc=0; fcd_live account claude default || rc=$?; echo $rc')
[ "$out" = 1 ] && ok || bad "S7 codex/default made claude/default live: $out"
reset
answer "GET /api/cooldowns?kind=account" "{\"rows\":[$(row account claude a $FUT)],\"truncated\":true}"
out=$(run 'rc=0; cooldown_list account || rc=$?; echo "rc=$rc"; for s in a b; do rc=0; fcd_live account claude $s || rc=$?; echo "$s=$rc"; done')
[ "$out" = "claude	a	$FUT		r	hub
rc=2
a=0
b=2" ] && ok || bad "S7 truncated: [$out]"

# ---------- S8 clear/list rcs ------------------------------------------------------
reset
answer "POST /api/cooldowns/clear" '{"cleared":1}'
out=$(run 'rc=0; cooldown_clear account claude a || rc=$?; echo $rc')
[ "$out" = 0 ] && ok || bad "S8 cleared 1 rc: $out"
answer "POST /api/cooldowns/clear" '{"cleared":0}'
out=$(run 'rc=0; fcd_clear account claude a || rc=$?; echo $rc')
[ "$out" = 1 ] && ok || bad "S8 cleared 0 rc: $out"
answer "POST /api/cooldowns/clear" 'not json'
out=$(run 'rc=0; fcd_clear account claude a || rc=$?; echo $rc')
[ "$out" = 2 ] && ok || bad "S8 bad json clear rc: $out"
[ "$(calls | tail -1 | cut -d' ' -f3- | jq -Sc .)" = '{"kind":"account","subject":"a","vendor":"claude"}' ] \
  && ok || bad "S8 clear body: $(calls | tail -1)"
answer "GET /api/cooldowns?kind=lane" '{"rows":[],"truncated":false}'
out=$(run 'rc=0; cooldown_list lane || rc=$?; echo "rc=$rc"')
[ "$out" = "rc=1" ] && ok || bad "S8 empty list rc: $out"
answer "GET /api/cooldowns?kind=lane" '{"error":"x"}'
out=$(run 'rc=0; cooldown_list lane || rc=$?; echo "rc=$rc"')
[ "$out" = "rc=2" ] && ok || bad "S8 rowless answer rc: $out"
answer "GET /api/cooldowns?kind=account" "{\"rows\":[$(row account claude old 1),{\"kind\":\"account\",\"vendor\":\"claude\",\"subject\":\"t\",\"until\":$FUT,\"since\":5,\"reason\":\"a\\tb\\nc\",\"box\":null,\"set_at\":1}],\"truncated\":false}"
out=$(run 'fcd_list account; echo "rc=$?"')
[ "$(head -1 <<<"$out" | awk -F'\t' '{print NF "|" $1 "|" $2 "|" $4}')" = "6|claude|t|5" ] \
  && ok || bad "S8 fcd_list row: [$out]"
[ "$(printf '%s\n' "$out" | wc -l)" = 2 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "rc=0" ] \
  && ok || bad "S8 fcd_list printed an expired row or wrong rc: [$out]"

# ---------- sourcing stays side-effect free ---------------------------------------
mkdir -p "$T/empty"
out=$(cd "$T/empty" && bash -c 'set -euo pipefail; . "$1"; . "$1"; command -v _jobs_req || true' _ "$LIB" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "source rc=$rc out=[$out]"
[ -z "$(ls -A "$T/empty")" ] && ok || bad "source created files"

echo "fleet-cooldown.bh-2353: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
