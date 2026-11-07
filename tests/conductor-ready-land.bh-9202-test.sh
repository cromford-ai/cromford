#!/bin/bash
# tests/conductor-ready-land.bh-9202-test.sh — BH-9202: a machine run of
# merge-conductor-pr that ends with the PR's row READY is a landing the machine
# left to the hub (a machine never lands). The land step writes `land`; a READY
# row with no word (an earlier exit of the READY arm held it) now writes `hold`
# in the PROF deferred= words, so a held run and a land-step run still differ
# (bh-6889 T1c). The hub reads a READY done row with deferred=- as `hold` too,
# so it runs the PR's worker itself instead of enqueuing a new row every tick.
# One alert per (PR, head) at MC_FLY_READY_LOOP_ALERT_N READY rows.
#
#   D1..D11  mc_fly_deferred_for over each row of the plan's decision table
#   M1..M4b  bin/merge-conductor-pr.sh with a stub conductor: READY -> hold,
#            READY + prequeuegroup -> prequeuegroup, WAIT_CI -> -, no row ->
#            NONE -, READY + land (the land step) -> land
#   M5       M1's PROF line, stored as a done row, reads as `hold`
#   T1..T3   the REAL bin/merge-conductor.sh tick against the REAL jobs worker
#            (tests/lib/lane-runs-worker.bh-6124.mjs, fixture of
#            tests/conductor-rereview-request.bh-9026-test.sh): a READY
#            deferred=- row makes the hub run the PR (fallback line, worker
#            read) and enqueue no new row, over 2 ticks; WAIT_CI still enqueues
#   A1..A5   the tripwire: 3 READY rows of one head -> 1 alert, tick 2 still 1;
#            2 rows -> 0; 3 rows over 2 heads -> 0; knob abc -> 3 + one line;
#            knob 4 with 3 rows -> 0; a failed READY row does not count
#   U0..U2   _mc_fly_ready_loop alone: alerts on the hub, not on a machine
#            (MC_ON_MACHINE=1), silent rc 0 when mc_alert is not loaded
#   G1       no gh write verb
#
# Run from anywhere: tests/conductor-ready-land.bh-9202-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/lane-runs-worker.bh-6124.mjs"
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v setsid >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or setsid missing"; exit 0; }

# ============================================================================
echo "D: mc_fly_deferred_for, the hub reader"
K=cromford.9188.11d885ffbad4
drow() { jq -nc --arg p "$1" --arg s "$2" --arg l "$3" '{project:$p,status:$s,rc:0,prof_line:$l}'; }
dread() { # dread <rows-json-array> <key> -> "<word>|<rc>"
  local o rc
  o=$( . "$DIR/bin/lib/mc/fly-workers.sh" || exit 9; mc_fly_deferred_for "{\"rows\":$1}" "$2"); rc=$?
  printf '%s|%s' "$o" "$rc"
}
dcase() { # dcase <id> <want> <rows-json-array> [key]
  local got; got=$(dread "$3" "${4:-$K}")
  [ "$got" = "$2" ] && ok "$1 -> $2" || bad "$1 want '$2' got '$got'"
}
dcase D1 "hold|0" "[$(drow $K done 'PROF mc-pr state=READY reason=clean-approved-checks-green deferred=-')]"
dcase D2 "prequeuegroup|0" "[$(drow $K done 'PROF mc-pr state=READY reason=x deferred=prequeuegroup')]"
dcase D3 "land,rebase|0" "[$(drow $K done 'PROF mc-pr state=READY reason=x deferred=land,rebase')]"
dcase D4 "hold|0" "[$(drow $K done 'PROF mc-pr state=READY reason=x')]"
dcase D5 "|1" "[$(drow $K done 'PROF mc-pr state=WAIT_CI reason=ci-running deferred=-')]"
dcase D6 "|1" "[$(drow $K done 'PROF mc-pr state=HEAD_MOVED reason=head-moved deferred=-')]"
dcase D7a "|1" "[$(drow $K done 'PROF mc-pr state=NOTREADY reason=x deferred=-')]"
dcase D7b "|1" "[$(drow $K done 'PROF mc-pr state=READY_X reason=x deferred=-')]"
dcase D8 "|1" "[$(drow $K done 'PROF mc-pr state=QUEUED reason=READY-at deferred=-')]"
dcase D9 "hold|0" "[$(drow $K queued ''),$(drow $K done 'PROF mc-pr state=READY reason=x deferred=-')]"
dcase D10 "|1" "[$(drow cromford.91880.11d885ffbad4 done 'PROF mc-pr state=READY reason=x deferred=-')]"
dcase D11 "|1" "[$(drow cromford.9188.222222222222 done 'PROF mc-pr state=READY reason=x deferred=-')]"
dcase D12 "|1" "[$(drow $K done 'PROF mc-pr state=MERGED reason=x deferred=-'),$(drow $K done 'PROF mc-pr state=READY reason=x deferred=-')]"

echo "U: _mc_fly_ready_loop guards"
R3="{\"rows\":[$(drow $K done "PROF mc-pr state=READY reason=x deferred=-"),$(drow $K done "PROF mc-pr state=READY reason=x deferred=-"),$(drow $K done "PROF mc-pr state=READY reason=x deferred=-")]}"
uloop() { # uloop <MC_ON_MACHINE> -> the mc_alert calls, with stub ledger fns
  ( . "$DIR/bin/lib/mc/fly-workers.sh" || exit 9
    mc_alert() { echo "alert $1"; }; mc_attempt_has() { return 1; }; mc_attempt_put() { :; }
    MC_ON_MACHINE="$1" _mc_fly_ready_loop cromford example-org/cromford 9188 11d885ffbad4aaaabbbbccccddddeeeeffff0000 "$R3" )
}
[ "$(uloop 0)" = "alert example-org/cromford#9188" ] && ok "U0 hub, 3 READY rows -> 1 alert" || bad "U0 got '$(uloop 0)'"
[ -z "$(uloop 1)" ] && ok "U1 MC_ON_MACHINE=1 -> no alert" || bad "U1 got '$(uloop 1)'"
out=$( ( . "$DIR/bin/lib/mc/fly-workers.sh" || exit 9
  _mc_fly_ready_loop cromford example-org/cromford 9188 11d885ffbad4aaaabbbbccccddddeeeeffff0000 "$R3"; echo "rc=$?" ) 2>&1)
[ "$out" = rc=0 ] && ok "U2 no mc_alert loaded -> rc 0, silent" || bad "U2 got '$out'"

# ============================================================================
echo "M: bin/merge-conductor-pr.sh writes hold for a READY row with no word"
M="$T/m"; mkdir -p "$M/bin" "$M/logs" "$M/state/merge-conductor" "$M/env" "$T/mbin"
for L in bin/merge-conductor-pr.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$M" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
printf 'cromford example-org/cromford - - 2 box-bh 192.0.2.1\n' > "$M/fleet.conf"
MH=8888777766665555444433332222111100009999
# The stub conductor: the PR's pr-state row from $T/m-state (READY | WAIT_CI |
# none) and, with $T/m-word, one deferred word.
cat > "$M/bin/merge-conductor.sh" <<EOF
#!/bin/bash
printf '%s|%s\n' "\$MC_ON_MACHINE" "\$MC_ONLY_PR" >> "$T/m-runs.txt"
s=\$(cat "$T/m-state")
[ -s "$T/m-word" ] && cat "$T/m-word" >> "\$MC_PR_DEFERRED_FILE"
[ "\$s" = none ] || printf 'example-org/cromford#7\t%s\t$MH\t-\t-\t-\tclean approved checks green\n' "\$s" \
  >> "\$HARNESS/state/merge-conductor/pr-state.tsv"
exit 0
EOF
chmod +x "$M/bin/merge-conductor.sh"
cat > "$T/mbin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i "*) printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n{"number":7,"head":{"sha":"$MH"}}\n' ;;
  *) echo 1 ;;
esac
exit 0
EOF
chmod +x "$T/mbin/gh"
mrun() { # mrun <state> <word|-> -> the PROF line
  : > "$M/state/merge-conductor/pr-state.tsv"; echo "$1" > "$T/m-state"
  if [ "$2" = - ]; then : > "$T/m-word"; else echo "$2" > "$T/m-word"; fi
  ( export PATH="$T/mbin:$PATH" HARNESS="$M" FLEET_CONF="$M/fleet.conf" GH_TOKEN=tok-fixture GH_ETAG=0
    "$M/bin/merge-conductor-pr.sh" cromford "example-org/cromford#7" "$MH" 2>/dev/null )
}
mcase() { local got; got=$(mrun "$2" "$3"); [ "$got" = "$4" ] && ok "$1 $2 + $3 -> $4" || bad "$1 want '$4' got '$got'"; }
mcase M1 READY - "PROF mc-pr state=READY reason=clean-approved-checks-green deferred=hold"
mcase M2 READY prequeuegroup "PROF mc-pr state=READY reason=clean-approved-checks-green deferred=prequeuegroup"
mcase M3 WAIT_CI - "PROF mc-pr state=WAIT_CI reason=clean-approved-checks-green deferred=-"
mcase M4 none - "PROF mc-pr state=NONE reason=- deferred=-"
mcase M4b READY land "PROF mc-pr state=READY reason=clean-approved-checks-green deferred=land"
grep -qx '1|example-org/cromford#7' "$T/m-runs.txt" && ok "M the conductor ran with MC_ON_MACHINE=1 for #7" \
  || bad "M runs: $(cat "$T/m-runs.txt" 2>/dev/null)"
M1L=$(mrun READY -)
dcase M5 "hold|0" "[$(drow cromford.7.${MH:0:12} done "$M1L")]" "cromford.7.${MH:0:12}"

# ============================================================================
# The real tick, as in tests/conductor-rereview-request.bh-9026-test.sh.
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
( export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" && fx_conductor_tick "$DIR" "$T" ) || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
( cd "$DIR" && scratch_install_closure bin/merge-conductor.sh "$T/h" ) >/dev/null || exit 1
( cd "$DIR" && scratch_install_closure bin/lib/mc/fly-workers.sh "$T/h" ) >/dev/null || exit 1
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
mkdir -p "$T/h/catalog" && jq '.lanes |= map(select(.id == "lead-review-land")) | .libs = []' \
  "$DIR/catalog/lanes.json" > "$T/h/catalog/lanes.json" || exit 1
printf 'cromford example-org/cromford https://bh.example /api/board 2 box-bh\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lv-calls.txt"\nexit 0\n' "$T" > "$T/h/bin/lead-verdict.sh"
chmod +x "$T/h/bin/lead-verdict.sh"

hd() { local s="$1aaaabbbbccccddddeeeeffff0000111122223333"; printf '%s' "${s:0:40}"; }
MAIN1=1111111111111111111111111111111111111111
setlist() { # setlist "<num> ..." — the open list of cromford
  local out="[" n
  for n in $1; do
    out="$out{\"number\":$n,\"url\":\"https://github.com/example-org/cromford/pull/$n\",\"headRefOid\":\"$(hd "$n")\",\"headRefName\":\"ticket/pb-$n\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\",\"labels\":[]},"
  done
  printf '%s\n' "${out%,}]" > "$T/list.json"
}
setlist ""
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*|*"-X PATCH"*|*"-X POST"*|*"-X PUT"*|*"-X DELETE"*)
    echo "WRITE VERB: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/cromford --state open"*) cat "$T/list.json" ;;
  *"pulls?state=closed"*) printf 'HTTP/2.0 200\r\n\r\n[]\n' ;;
  *"actions/runs?head_sha="*)
    a="\$*"; h="\${a##*head_sha=}"
    printf '%s\n' "\${h:0:2}" >> "$T/worker-reads.txt"
    printf 'in_progress|\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo fixture-token ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
echo "$MAIN1" > "$T/ctl-main-sha"
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case "\$*" in
  *--version*) echo "git version 2.45.0" ;;
  *ls-remote*"refs/heads/"*) printf '%s\trefs/heads/main\n' "\$(cat "$T/ctl-main-sha")" ;;
  *ls-remote*) echo "0000000000000000000000000000000000000000	HEAD" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"
: > "$T/gh-writes.txt"; : > "$T/c-alerts.txt"; : > "$T/lv-calls.txt"
CLOG="$T/h/logs/merge-conductor.log"; : > "$CLOG"

PIDS=()
srv() {
  local n="w${#PIDS[@]}"
  : > "$T/$n.log"; : > "$T/$n.port"
  env "$@" node "$SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
  local pid=$!; PIDS+=("$pid")
  for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/$n.port")
  if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  JOBS_URL="http://127.0.0.1:$PORT"
}
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
api() { curl -sS -X "$1" -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
          ${3:+-d "$3"} "$JOBS_URL$2"; }
ctick() {
  : > "$T/worker-reads.txt"; : > "$CLOG"
  ( cd "$T" && setsid -w env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=fixture-harness-secret \
      JOBS_URL="$JOBS_URL" JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
      MC_PR_PARALLEL=0 MC_KEYED_WAKE_MIN_S=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) 2>/dev/null || true
}
# ran_row <pr> <prof> [head40] [rc] — a finished run of the head (default the
# PR's list head, rc 0: done), through the real enqueue, claim and report routes.
ran_row() {
  local n="$1" h="${3:-$(hd "$1")}" key args id; key="cromford.$n.${h:0:12}"
  args=$(jq -nc --arg h "$h" --arg s "example-org/cromford#$n" '["bin/merge-conductor-pr.sh","cromford",$s,$h]')
  id=$(api POST /api/lane-runs "$(jq -nc --arg p "$key" --argjson a "$args" '{lane:"merge-conductor-pr",project:$p,args:$a}')" | jq -r .id)
  api POST /api/lane-runs/claim '{"machine":"m9"}' >/dev/null
  api POST "/api/lane-runs/$id/report" "$(jq -nc --arg pr "$2" --arg rc "${4:-0}" '{machine:"m9",rc:($rc|tonumber),prof:$pr}')" > "$T/report.json"
}
READYP='PROF mc-pr state=READY reason=clean-approved-checks-green deferred=-'
nrows() { api GET "/api/lane-runs/by-prefix?lane=merge-conductor-pr&project_prefix=cromford.$1.&limit=50" | jq '.rows | length'; }
alerts() { grep -c "cromford#$1 READY" "$T/c-alerts.txt"; }
fresh() { srv; setting conductor_workers_on_fly 1; }

srv; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T"/w0.err)"; exit 1; }
ctick
grep -q 'cromford LAND baseline' "$CLOG" && ok "setup: the land baseline is recorded" \
  || bad "setup: no land baseline: $(grep LAND "$CLOG" | head -3)"

# ============================================================================
echo "T: a READY deferred=- row -> the hub runs the PR, no new row"
fresh; setlist "41"
ran_row 41 "$READYP"
for tk in 1 2; do
  ctick
  grep -qF "example-org/cromford#41 fallback=machine-deferred (hold) — this PR runs on the hub this tick" "$CLOG" \
    && ok "T$tk the fallback line names hold" || bad "T$tk log: $(grep 'cromford#41' "$CLOG" | tail -3)"
  grep -qx 41 "$T/worker-reads.txt" && ok "T$tk the hub worker read #41's CI" || bad "T$tk no hub worker read for #41"
  grep -q 'cromford#41 enqueued merge-conductor-pr' "$CLOG" && bad "T$tk enqueued a new row" || ok "T$tk no enqueue line"
  [ "$(nrows 41)" = 1 ] && ok "T$tk 1 lane_runs row for the key" || bad "T$tk rows: $(nrows 41)"
done
fresh; setlist "42"
ran_row 42 'PROF mc-pr state=WAIT_CI reason=ci-running deferred=-'
ctick
grep -q 'cromford#42 enqueued merge-conductor-pr' "$CLOG" && ok "T3 WAIT_CI still enqueues (today)" \
  || bad "T3 log: $(grep 'cromford#42' "$CLOG" | tail -3)"
[ "$(nrows 42)" = 2 ] && ok "T3 2 rows" || bad "T3 rows: $(nrows 42)"

# ============================================================================
echo "A: the READY loop tripwire"
fresh; setlist "43"; : > "$T/c-alerts.txt"
for _ in 1 2 3; do ran_row 43 "$READYP"; done
ctick
[ "$(alerts 43)" = 1 ] && grep -q "$(hd 43 | cut -c1-12)" "$T/c-alerts.txt" && ok "A1 3 READY rows -> 1 alert naming #43 and the head" \
  || bad "A1 alerts: $(cat "$T/c-alerts.txt"); err: $(tail -3 "$T/tick.err")"
ctick
[ "$(alerts 43)" = 1 ] && ok "A1 tick 2: still 1 alert" || bad "A1 tick 2 alerts: $(alerts 43)"
fresh; setlist "44"
for _ in 1 2; do ran_row 44 "$READYP"; done
ctick
[ "$(alerts 44)" = 0 ] && ok "A2 2 READY rows -> 0 alerts" || bad "A2 alerts: $(alerts 44)"
fresh; setlist "45"
ran_row 45 "$READYP" 4599999999999999999999999999999999999999
for _ in 1 2; do ran_row 45 "$READYP"; done
ctick
[ "$(alerts 45)" = 0 ] && ok "A3 3 READY rows over 2 heads -> 0 alerts" || bad "A3 alerts: $(alerts 45)"
fresh; setlist "46"
for _ in 1 2 3; do ran_row 46 "$READYP"; done
ctick MC_FLY_READY_LOOP_ALERT_N=abc
[ "$(alerts 46)" = 1 ] && ok "A4 knob abc -> threshold 3, 1 alert" || bad "A4 alerts: $(alerts 46)"
grep -q "MC_FLY_READY_LOOP_ALERT_N='abc' is not an integer >= 2; using 3" "$CLOG" && ok "A4 knob abc logs one line" \
  || bad "A4 no knob line"
fresh; setlist "47"
for _ in 1 2 3; do ran_row 47 "$READYP"; done
ctick MC_FLY_READY_LOOP_ALERT_N=4
[ "$(alerts 47)" = 0 ] && ok "A5 knob 4 with 3 rows -> 0 alerts" || bad "A5 alerts: $(alerts 47)"

fresh; setlist "48"
ran_row 48 "$READYP" "$(hd 48)" 1
for _ in 1 2; do ran_row 48 "$READYP"; done
ctick
[ "$(alerts 48)" = 0 ] && ok "A6 1 failed + 2 done READY rows -> 0 alerts (done rows only)" || bad "A6 alerts: $(alerts 48)"

# ============================================================================
echo "G: no network beyond the localhost worker"
[ ! -s "$T/gh-writes.txt" ] && ok "G1 no gh write" || bad "G1 gh writes: $(head -3 "$T/gh-writes.txt")"

echo "conductor-ready-land: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
