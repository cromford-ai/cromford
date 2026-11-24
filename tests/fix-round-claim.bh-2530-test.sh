#!/bin/bash
# tests/fix-round-claim.bh-2530-test.sh — BH-2672 (BH-2530.2): the box lane that
# claims the fix rounds blocked-resolver queued for this box and runs each one
# detached, with no ssh from the hub.
#
# WHAT IS DRIVEN. The real bin/fix-round-claim.sh, copied into a scratch box
# harness beside the real jobs client, lib/fix-round-queue.sh, hub-box.sh,
# lane-gate.sh and env-path.sh, and run the way cron runs it (no args). The
# registry is composed from the checkout's catalog/lanes.d. The stubs:
#   curl                   a stateful fake worker over $T/rows.json:
#                          POST /api/fix-rounds/claim (oldest row for the box,
#                          queued, or claimed longer ago than stale_min against
#                          $T/now; bumps attempt), POST /api/fix-rounds/finish
#                          (CAS on claimed + claimed_by, or 409 when $T/finish409
#                          exists), GET /api/settings ($T/settings.json). Every
#                          other path is 404. Every request lands in curl.log.
#   bin/blocked-resolver.sh  records argv, stdin and GH_TOKEN per call, then plays
#                          $T/stub.mode: ok | die137 | crash-after-record |
#                          sleep (held until $T/stub.release) | other-project | weird.
#   bin/box-name.sh, bin/fleet-conf.sh, bin/gh-token.sh.
#
# CASES (a)-(n) are the plan's acceptance tests; e1-e6 are the re-offer guard's
# adversarial negatives (each must run the round); (o) a foreign record, (p) an
# unrecognised FIX_RESULT, (q) a malformed row, (r) FIX_ROUND_CLAIM_MAX default.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fix-round-claim.bh-2530-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq python3 flock setsid pkill base64; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

H="$T/h"
FAKE="$T/fakebin"
mkdir -p "$FAKE"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: could not compose the lane registry"; exit 1; }

# ── the fake worker ──────────────────────────────────────────────────────────
cat > "$T/worker.py" <<'PY'
import json, os, sys
T = os.environ["FRC_T"]
method, url, body = sys.argv[1], sys.argv[2], sys.argv[3]
path = url.split("://", 1)[-1]
path = path[path.index("/"):] if "/" in path else "/"
with open(f"{T}/curl.log", "a") as f: f.write(f"{method} {path}\n")
with open(f"{T}/bodies.log", "a") as f: f.write(f"{method} {path} {body}\n")
def out(code, obj): print(json.dumps(obj)); print(code, end=""); sys.exit(0)
rf = f"{T}/rows.json"
rows = json.load(open(rf)) if os.path.exists(rf) else []
now = int(open(f"{T}/now").read().strip())
if method == "POST" and path == "/api/fix-rounds/claim":
    b = json.loads(body); stale = b.get("stale_min")
    for r in sorted(rows, key=lambda r: r["id"]):
        if r["box"] != b["box"]: continue
        if r["status"] == "queued" or (r["status"] == "claimed" and isinstance(stale, int)
                                      and now - r["claimed_at"] >= stale * 60):
            r.update(status="claimed", claimed_by=b["box"], claimed_at=now, attempt=r["attempt"] + 1)
            json.dump(rows, open(rf, "w")); out(200, {"job": r})
    out(404, {"error": "no row to claim"})
if method == "POST" and path == "/api/fix-rounds/finish":
    b = json.loads(body)
    if os.path.exists(f"{T}/finish409"): out(409, {"error": "not claimed by you"})
    for r in rows:
        if r["id"] == b["id"] and r["status"] == "claimed" and r["claimed_by"] == b["box"]:
            r.update(status="done", result=b["result"], record_out=b.get("record_out"))
            json.dump(rows, open(rf, "w")); out(200, {"job": r})
    out(409, {"error": "not claimed by you"})
if method == "GET" and path == "/api/settings":
    s = json.load(open(f"{T}/settings.json")) if os.path.exists(f"{T}/settings.json") else []
    out(200, {"settings": s})
out(404, {"error": "not found"})
PY
cat > "$FAKE/curl" <<EOF
#!/bin/bash
export FRC_T="$T"
EOF
cat >> "$FAKE/curl" <<'EOF'
method=GET body="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
exec python3 "$FRC_T/worker.py" "$method" "$url" "$body"
EOF
chmod +x "$FAKE/curl"

# ── the scratch box harness ──────────────────────────────────────────────────
fresh() {
  scratch_rm "$H"
  rm -f "$T/rows.json" "$T/curl.log" "$T/bodies.log" "$T/settings.json" "$T/finish409" "$T"/stub.*
  mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/logs" "$H/state" "$H/flags" "$H/locks"
  cp "$DIR/bin/fix-round-claim.sh" "$H/bin/fix-round-claim.sh"
  cp "$DIR/bin/jobs-client.sh" "$H/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  cp "$DIR/bin/lib/fix-round-queue.sh" "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/lane-gate.sh" \
     "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/fix-round-reap.sh" "$H/bin/lib/"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\nJOBS_RETRIES=0\n' > "$H/env/global.env"
  printf 'b1\n' > "$T/boxname"
  echo ok > "$T/stub.mode"
  date +%s > "$T/now"
  printf '#!/bin/bash\ncat "%s/boxname"\n' "$T" > "$H/bin/box-name.sh"
  printf '#!/bin/bash\n[ "${2:-}" = repo ] && echo o/r\n' > "$H/bin/fleet-conf.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/gh-token.calls"\necho "tok-$1"\n' "$T" > "$H/bin/gh-token.sh"
  cat > "$H/bin/blocked-resolver.sh" <<EOF
#!/bin/bash
T="$T"; H="$H"
EOF
  cat >> "$H/bin/blocked-resolver.sh" <<'EOF'
n=$(( $(cat "$T/stub.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/stub.n"
printf '%s\0' "$@" > "$T/stub.$n.argv"
cat > "$T/stub.$n.stdin"
printf '%s' "${GH_TOKEN:-}" > "$T/stub.$n.tok"
rec() { # the record the round leaves: stdin's, or a fresh one, plus one attempt
  if [ -s "$T/stub.$n.stdin" ]; then jq -c --arg p "$1" '.project=$p | .attempts += [{"detail":"round ran"}]' "$T/stub.$n.stdin"
  else jq -nc --arg p "$1" '{project:$p, attempts:[{"detail":"round ran"}]}'; fi
}
case "$(cat "$T/stub.mode")" in
  ok) r=$(rec p); mkdir -p "$H/state/blocked-resolver/p"; printf '%s' "$r" > "$H/state/blocked-resolver/p/ck.json"
      echo "FIX_RECORD $(printf '%s' "$r" | base64 -w0)"; echo "FIX_RESULT done" ;;
  sleep) # held until the test releases it, bounded, so a tick that waits on it hangs
      for _ in $(seq 1 300); do [ -e "$T/stub.release" ] && break; sleep 0.1; done
      echo "FIX_RECORD $(rec p | base64 -w0)"; echo "FIX_RESULT done" ;;
  die137) exit 137 ;;
  crash-after-record)
      mkdir -p "$H/state/blocked-resolver/p"; rec p > "$H/state/blocked-resolver/p/ck.json"
      pkill -KILL -f "$H/bin/fix-round-claim.sh --run"; sleep 1; exit 0 ;;
  other-project) echo "FIX_RECORD $(rec q | base64 -w0)"; echo "FIX_RESULT done" ;;
  weird) echo "FIX_RECORD $(rec p | base64 -w0)"; echo "FIX_RESULT banana split" ;;
esac
exit 0
EOF
  chmod +x "$H"/bin/*.sh
}

ARGS='["p","rk","a reason with spaces","https://u/1","rec","tk"]'
R1='{"project":"p","attempts":[{"detail":"r1"}]}'
# row <id> <box> <status> <attempt> <record_in json-string-or-null> [ck] [claimed_min_ago]
row() {
  local ago="${7:-}" now; now=$(cat "$T/now")
  [ -f "$T/rows.json" ] || echo '[]' > "$T/rows.json"
  jq -c --argjson id "$1" --arg box "$2" --arg st "$3" --argjson at "$4" --argjson rin "$5" \
     --arg ck "${6:-ck}" --arg args "$ARGS" --arg ago "$ago" --argjson now "$now" \
    '. + [{id:$id, project:"p", cap_key:$ck, box:$box, args:$args, record_in:$rin, hotfix:0,
           status:$st, attempt:$at,
           claimed_by:(if $st=="claimed" then $box else null end),
           claimed_at:(if $ago=="" then null else ($now - ($ago|tonumber)*60) end),
           result:null, record_out:null}]' "$T/rows.json" > "$T/rows.tmp" && mv "$T/rows.tmp" "$T/rows.json"
}
rowf() { jq -r --argjson id "$1" ".[] | select(.id==\$id) | $2" "$T/rows.json"; }
local_rec() { mkdir -p "$H/state/blocked-resolver/p"; printf '%s' "$1" > "$H/state/blocked-resolver/p/ck.json"; }
stubs() { cat "$T/stub.n" 2>/dev/null || echo 0; }
reqs() { local n; n=$(grep -c "${1:-fix-rounds}" "$T/curl.log" 2>/dev/null); echo "${n:-0}"; }

# tick [env assignments...] — the lane as cron runs it.
tick() {
  ( unset BOX_NAME JOBS_URL HARNESS_SECRET JOBS_BOX FIX_ROUND_CLAIM FIX_ROUND_CLAIM_MAX FIX_ROUND_RUN_MAX \
          BR_FIX_LANE_TIMEOUT BR_FIX_HOP_MARGIN BR_FIX_AGENT_TIMEOUT BR_FIX_VERIFY_TIMEOUT LANE_GATE_DISABLE GH_TOKEN
    export HARNESS="$H" LANE_REGISTRY="$T/lanes.json" PATH="$FAKE:$PATH" FIX_ROUND_CLAIM_FOREGROUND=1
    for kv in "$@"; do export "${kv?}"; done
    bash "$H/bin/fix-round-claim.sh" >/dev/null 2>&1 )
}

# ── (a) one claim under a settings MAX of 1; the round runs with the row ─────
fresh
row 1 b1 queued 0 "$(jq -Rn --arg r "$R1" '$r')"
row 2 b1 queued 0 null ck2
echo '[{"key":"lane.fix-round-claim.fix_round_claim_max","value":"1","actor":"op"}]' > "$T/settings.json"
tick; RC=$?
[ "$RC" -eq 0 ] && ok || bad "(a) rc=$RC"
[ "$(reqs /api/fix-rounds/claim)" = 1 ] && ok || bad "(a) claim requests $(reqs /api/fix-rounds/claim), want 1"
[ "$(stubs)" = 1 ] && ok || bad "(a) stub ran $(stubs) times, want 1"
if [ -f "$T/stub.1.argv" ]; then
  GOT=$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read().split("\0")[:-1]))' "$T/stub.1.argv")
  [ "$(jq -c . <<<"$GOT")" = "$(jq -c '["--fix-here"] + .' <<<"$ARGS")" ] && ok || bad "(a) stub argv $GOT"
  [ "$(cat "$T/stub.1.stdin")" = "$R1" ] && ok || bad "(a) stub stdin '$(cat "$T/stub.1.stdin")'"
  # Never print the value: a failure here must not echo whatever token the runner had.
  [ "$(cat "$T/stub.1.tok")" = "tok-o/r" ] && ok || bad "(a) the round's GH_TOKEN is not the one gh-token.sh minted for o/r"
else bad "(a) the round never ran"; fi
[ "$(rowf 1 .status)" = "done" ] && [ "$(rowf 1 .result)" = "done" ] && ok || bad "(a) row 1 $(rowf 1 '[.status,.result]|@csv')"
[ "$(rowf 1 .record_out | jq -c .attempts 2>/dev/null)" = '[{"detail":"r1"},{"detail":"round ran"}]' ] && ok || bad "(a) record_out '$(rowf 1 .record_out)'"
[ "$(rowf 2 .status)" = queued ] && ok || bad "(a) row 2 $(rowf 2 .status), want queued"
# (n) the token never reaches the lane's log
grep -q 'tok-o/r' "$H/logs/fix-round-claim.log" 2>/dev/null && bad "(n) GH token in the log" || ok
grep -q 'row 1' "$H/logs/fix-round-claim.log" 2>/dev/null && ok || bad "(a) no log line for row 1"

# ── (r) FIX_ROUND_CLAIM_MAX default 2 claims two of three ────────────────────
fresh
row 1 b1 queued 0 null ck1; row 2 b1 queued 0 null ck2; row 3 b1 queued 0 null ck3
tick
[ "$(reqs /api/fix-rounds/claim)" = 2 ] && [ "$(rowf 3 .status)" = queued ] && [ "$(stubs)" = 2 ] && ok \
  || bad "(r) claims $(reqs /api/fix-rounds/claim) stubs $(stubs) row3 $(rowf 3 .status)"

# ── (b) a row for another box is not ours ────────────────────────────────────
fresh
row 1 b2 queued 0 null
tick; RC=$?
[ "$RC" -eq 0 ] && [ "$(reqs /api/fix-rounds/claim)" = 1 ] && [ "$(rowf 1 .status)" = queued ] && [ "$(stubs)" = 0 ] && ok \
  || bad "(b) rc=$RC claims $(reqs /api/fix-rounds/claim) status $(rowf 1 .status) stubs $(stubs)"
[ -s "$H/logs/fix-round-claim.log" ] && bad "(b) a tick with nothing to claim logged: $(cat "$H/logs/fix-round-claim.log")" || ok

# ── (c) the hub never claims ─────────────────────────────────────────────────
fresh
row 1 box-hub queued 0 null
echo box-hub > "$T/boxname"
tick; RC=$?
[ "$RC" -eq 0 ] && [ ! -s "$T/curl.log" ] && [ "$(stubs)" = 0 ] && ok || bad "(c) rc=$RC requests $(cat "$T/curl.log" 2>/dev/null) stubs $(stubs)"

# ── (d) no FIX_RESULT is setup-blocked, never done ───────────────────────────
fresh
row 1 b1 queued 0 null
echo die137 > "$T/stub.mode"
tick
RES=$(rowf 1 .result)
case "$RES" in "setup-blocked "*) ok ;; *) bad "(d) result '$RES'" ;; esac
printf '%s' "${RES#setup-blocked }" | base64 -d 2>/dev/null | grep -qF 'gave no FIX_RESULT (rc=137)' && ok \
  || bad "(d) reason '$(printf '%s' "${RES#setup-blocked }" | base64 -d 2>/dev/null)'"

# ── (e) a re-offered row whose round already ran here is finished, not re-run ─
fresh
row 1 b1 claimed 1 "$(jq -Rn --arg r "$R1" '$r')" ck 200
L2='{"project":"p","attempts":[{"detail":"r1"},{"detail":"r2"}]}'
local_rec "$L2"
tick
[ "$(stubs)" = 0 ] && ok || bad "(e) the round ran again ($(stubs))"
[ "$(rowf 1 .attempt)" = 2 ] && [ "$(rowf 1 .status)" = "done" ] && [ "$(rowf 1 .result)" = "done" ] && ok \
  || bad "(e) row $(rowf 1 '[.attempt,.status,.result]|@csv')"
[ "$(rowf 1 .record_out)" = "$L2" ] && ok || bad "(e) record_out '$(rowf 1 .record_out)'"

# ── (e1-e6) the guard must NOT short-circuit ─────────────────────────────────
neg() { # neg <name> <seed-fn>
  fresh; "$2"; tick
  [ "$(stubs)" = 1 ] && ok || bad "($1) the round did not run ($(stubs)); row $(rowf 1 '[.attempt,.status,.result]|@csv')"
}
e1() { row 1 b1 queued 0 "$(jq -Rn --arg r "$R1" '$r')"; local_rec "$L2"; }
e2() { row 1 b1 claimed 1 "$(jq -Rn --arg r "$R1" '$r')" ck 200; }
e3() { row 1 b1 claimed 1 "$(jq -Rn --arg r "$R1" '$r')" ck 200; local_rec '{"project":"q","attempts":[{},{},{},{},{}]}'; }
e4() { row 1 b1 claimed 1 "$(jq -Rn --arg r "$R1" '$r')" ck 200; local_rec "$R1"; }
e5() { row 1 b1 claimed 1 "$(jq -Rn --arg r "$R1" '$r')" ck 200; local_rec '{"project":"p","attempts":[{},{},'; }
e6() { row 1 b1 claimed 1 null ck 200; local_rec '{"project":"p","attempts":[]}'; }
neg e1 e1; neg e2 e2; neg e3 e3; neg e4 e4; neg e5 e5; neg e6 e6
[ -f "$T/stub.1.stdin" ] && [ ! -s "$T/stub.1.stdin" ] && ok || bad "(e6) a null record_in did not reach the round as empty stdin"

# ── (f) a live runner owns the park: --run exits, posts nothing ──────────────
fresh
row 1 b1 claimed 1 null ck 0
jq -c '.[0]' "$T/rows.json" > "$T/row1.json"
flock "$H/locks/fix-round-p-ck.lock" sleep 20 & HOLD=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$H/locks/fix-round-p-ck.lock" true && sleep 0.2 || break; done
( export HARNESS="$H" LANE_REGISTRY="$T/lanes.json" PATH="$FAKE:$PATH"; unset BOX_NAME JOBS_URL HARNESS_SECRET GH_TOKEN
  bash "$H/bin/fix-round-claim.sh" --run 1 "$T/row1.json" >/dev/null 2>&1 ); RC=$?
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
[ "$RC" -eq 0 ] && [ "$(stubs)" = 0 ] && [ "$(reqs /api/fix-rounds/finish)" = 0 ] && [ "$(rowf 1 .status)" = claimed ] && ok \
  || bad "(f) rc=$RC stubs $(stubs) finishes $(reqs /api/fix-rounds/finish) status $(rowf 1 .status)"
grep -q 'a live runner owns p/ck' "$H/logs/fix-round-claim.log" 2>/dev/null && ok || bad "(f) no log line"

# ── (g) a runner killed after the round wrote its record ─────────────────────
fresh
row 1 b1 queued 0 "$(jq -Rn --arg r "$R1" '$r')"
echo crash-after-record > "$T/stub.mode"
tick
[ "$(rowf 1 .status)" = claimed ] && [ "$(rowf 1 .attempt)" = 1 ] && [ "$(stubs)" = 1 ] && ok \
  || bad "(g) tick 1: row $(rowf 1 '[.status,.attempt]|@csv') stubs $(stubs)"
# The round inherits the runner's lock fd and outlives the kill by its sleep, so
# a tick that lands before it exits reads "a live runner owns p/ck". This case is
# about a round that has ended: wait (bounded) for its lock to come free.
for _ in $(seq 1 100); do flock -n "$H/locks/fix-round-p-ck.lock" true && break; sleep 0.1; done
echo ok > "$T/stub.mode"
echo $(( $(cat "$T/now") + 600 )) > "$T/now"
tick
[ "$(rowf 1 .status)" = claimed ] && [ "$(rowf 1 .attempt)" = 1 ] && [ "$(stubs)" = 1 ] && ok \
  || bad "(g) tick 2 inside stale_min: row $(rowf 1 '[.status,.attempt]|@csv') stubs $(stubs)"
echo $(( $(cat "$T/now") + 6000 )) > "$T/now"
tick
[ "$(rowf 1 .status)" = "done" ] && [ "$(rowf 1 .attempt)" = 2 ] && [ "$(rowf 1 .result)" = "done" ] && [ "$(stubs)" = 1 ] && ok \
  || bad "(g) tick 3 past stale_min: row $(rowf 1 '[.status,.attempt,.result]|@csv') stubs $(stubs)"
[ "$(rowf 1 .record_out | jq -c .attempts 2>/dev/null)" = '[{"detail":"r1"},{"detail":"round ran"}]' ] && ok \
  || bad "(g) record_out '$(rowf 1 .record_out)'"

# ── (h) the lane switch ──────────────────────────────────────────────────────
fresh
row 1 b1 queued 0 null
touch "$H/flags/lane-off-fix-round-claim"
tick; RC=$?
[ "$RC" -eq 0 ] && [ "$(reqs)" = 0 ] && [ "$(stubs)" = 0 ] && ok || bad "(h) rc=$RC fix-round requests $(reqs) stubs $(stubs)"

# ── (i) FIX_ROUND_CLAIM=0 ────────────────────────────────────────────────────
fresh
row 1 b1 queued 0 null
tick FIX_ROUND_CLAIM=0; RC=$?
[ "$RC" -eq 0 ] && [ "$(reqs)" = 0 ] && [ "$(stubs)" = 0 ] && ok || bad "(i) rc=$RC fix-round requests $(reqs) stubs $(stubs)"

# ── (j) not configured: one line, no request ─────────────────────────────────
fresh
row 1 b1 queued 0 null
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=\n' > "$H/env/global.env"
tick; RC=$?
N=$(grep -c 'not configured' "$H/logs/fix-round-claim.log" 2>/dev/null); N=${N:-0}
[ "$RC" -eq 0 ] && [ "$N" = 1 ] && [ "$(reqs)" = 0 ] && ok || bad "(j) rc=$RC not-configured lines $N requests $(reqs)"

# ── (k) the stale cutoff in the claim body ───────────────────────────────────
# TEST-CHANGE (BH-9906): the cutoff is ceil((BR_FIX_AGENT_TIMEOUT +
# BR_FIX_VERIFY_TIMEOUT + BR_FIX_HOP_MARGIN) / 60), the box's new round bound;
# BR_FIX_LANE_TIMEOUT + BR_FIX_HOP_MARGIN is only the fallback when the agent
# or verify knob is not a number. Every old case is kept on the fallback path.
stale_of() { grep '/api/fix-rounds/claim' "$T/bodies.log" | head -1 | cut -d' ' -f3- | jq -c '.stale_min'; }
fresh; tick
[ "$(stale_of)" = 110 ] && ok || bad "(k) default stale_min $(stale_of), want 110 (3600+2700+300)"
fresh; tick BR_FIX_AGENT_TIMEOUT=60 BR_FIX_VERIFY_TIMEOUT=60 BR_FIX_HOP_MARGIN=60
[ "$(stale_of)" = 3 ] && ok || bad "(k) 60+60+60 stale_min $(stale_of), want 3"
fresh; tick BR_FIX_AGENT_TIMEOUT=61 BR_FIX_VERIFY_TIMEOUT=60 BR_FIX_HOP_MARGIN=60
[ "$(stale_of)" = 4 ] && ok || bad "(k) 61+60+60 stale_min $(stale_of), want 4 (ceil, not floor)"
fresh; tick BR_FIX_AGENT_TIMEOUT=junk BR_FIX_LANE_TIMEOUT=60 BR_FIX_HOP_MARGIN=60
[ "$(stale_of)" = 2 ] && ok || bad "(k) fallback 60+60 stale_min $(stale_of), want 2"
fresh; tick BR_FIX_AGENT_TIMEOUT=junk BR_FIX_LANE_TIMEOUT=61 BR_FIX_HOP_MARGIN=60
[ "$(stale_of)" = 3 ] && ok || bad "(k) fallback 61+60 stale_min $(stale_of), want 3 (ceil, not floor)"
fresh; tick BR_FIX_AGENT_TIMEOUT=junk BR_FIX_LANE_TIMEOUT=junk
[ "$(stale_of)" = null ] && ok || bad "(k) junk timeouts stale_min $(stale_of), want absent"

# ── (l) the runner is detached: the tick does not wait for it ────────────────
fresh
row 1 b1 queued 0 null
echo sleep > "$T/stub.mode"
S=$(date +%s%N)
( unset BOX_NAME JOBS_URL HARNESS_SECRET FIX_ROUND_CLAIM_FOREGROUND GH_TOKEN
  export HARNESS="$H" LANE_REGISTRY="$T/lanes.json" PATH="$FAKE:$PATH"
  bash "$H/bin/fix-round-claim.sh" >/dev/null 2>&1 )
E=$(( ($(date +%s%N) - S) / 1000000 ))
[ "$E" -lt 2500 ] && [ "$(rowf 1 .status)" != "done" ] && ok \
  || bad "(l) the tick took ${E}ms and left $(rowf 1 .status), the round is held until released"
touch "$T/stub.release"
for _ in $(seq 1 60); do [ "$(rowf 1 .status)" = "done" ] && break; sleep 0.25; done
[ "$(rowf 1 .status)" = "done" ] && [ "$(stubs)" = 1 ] && ok || bad "(l) the detached round never finished: $(rowf 1 .status)"
# TEST-CHANGE (BH-9906): the detached runner now makes one claim pass (its
# drain) after its finish. Wait for it to exit, bounded, so the next case's
# fresh tree is not claimed from by this case's runner.
for _ in $(seq 1 100); do pgrep -f "$H/bin/fix-round-claim.sh" >/dev/null 2>&1 || break; sleep 0.1; done

# ── (m) a 409 on finish is logged once and not retried ───────────────────────
fresh
row 1 b1 queued 0 null
touch "$T/finish409"
tick
[ "$(reqs /api/fix-rounds/finish)" = 1 ] && ok || bad "(m) finish requests $(reqs /api/fix-rounds/finish)"
[ "$(grep -c ': 409 on finish' "$H/logs/fix-round-claim.log" 2>/dev/null)" = 1 ] && ok || bad "(m) 409 log lines: $(cat "$H/logs/fix-round-claim.log" 2>/dev/null)"

# ── (o) a record for another project is dropped, the result kept ─────────────
fresh
row 1 b1 queued 0 null
echo other-project > "$T/stub.mode"
tick
[ "$(rowf 1 .result)" = "done" ] && [ "$(rowf 1 .record_out)" = null ] && ok || bad "(o) row $(rowf 1 '[.result,.record_out]|@json')"

# ── (p) an unrecognised FIX_RESULT is setup-blocked ──────────────────────────
fresh
row 1 b1 queued 0 null
echo weird > "$T/stub.mode"
tick
RES=$(rowf 1 .result)
printf '%s' "${RES#setup-blocked }" | base64 -d 2>/dev/null | grep -qF 'unrecognised FIX_RESULT: banana split' && ok || bad "(p) result '$RES'"

# ── (q) a malformed row never reaches a path or the round ────────────────────
fresh
row 1 b1 queued 0 null ../etc
tick
RES=$(rowf 1 .result)
[ "$(stubs)" = 0 ] && ok || bad "(q) the round ran for a malformed row"
printf '%s' "${RES#setup-blocked }" | base64 -d 2>/dev/null | grep -qF 'malformed' && ok || bad "(q) result '$RES'"
[ -e "$H/locks/fix-round-p-../etc.lock" ] && bad "(q) a lock under a traversed path" || ok

echo "fix-round-claim: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
