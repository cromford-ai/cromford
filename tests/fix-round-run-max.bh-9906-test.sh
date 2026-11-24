#!/bin/bash
# tests/fix-round-run-max.bh-9906-test.sh — BH-9906: the box side of a fix
# round. bin/fix-round-claim.sh claimed up to FIX_ROUND_CLAIM_MAX rows a tick
# and never counted the rounds already running; one `timeout` bounded agent and
# verification together and missed nested process groups; a timed-out round
# finished setup-blocked and waited for a hub tick to be offered again.
#
# WHAT IS DRIVEN. The real bin/fix-round-claim.sh, installed with its closure
# into a scratch box harness, the way cron runs it (no args), as a runner
# (--run), as a pool machine (--run-pool) and as a drain (--drain). The stubs:
#   curl                     a stateful fake worker over $T/rows.json: claim,
#                            finish, requeue (409 when $T/requeue409 exists),
#                            GET /api/fix-rounds (project, cap_key, box, status
#                            filters), GET /api/settings. Every request is in
#                            curl.log; $T/down makes every request exit 7.
#   bin/blocked-resolver.sh  plays $T/stub.mode (see the case list below).
#   bin/lane-alert.sh, bin/beat.sh   append to alerts.log / beats.log.
#   bin/box-name.sh, bin/fleet-conf.sh, bin/gh-token.sh.
# No real vendor is called: Z1 asserts every request reached the fake worker.
#
# CASES: M1-M3 the run limit; D1-D2 the drain; R1 the re-offer table; R2 the
# re-offered row; C1 the cap; K1 the lock-held table; K2-K4 the session sweep
# and the worktree removal; S1 a refused requeue; S2 stale_min; P1-P3 the Fly
# pool; K5 the registry defaults; Q1-Q3 fix_round_requeue; Z1 no vendor call.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fix-round-run-max.bh-9906-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq python3 flock setsid base64 ps; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

H="$T/h"
# K2: a sleep length unique to this run (from its own scratch path), so a
# parallel run, or a stray of an older one, never reads as this run's
# survivor. GNU sleep takes a fraction.
NAP="999.$(printf '%s' "$T" | cksum | cut -d' ' -f1)"
FAKE="$T/fakebin"
mkdir -p "$FAKE"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: could not compose the lane registry"; exit 1; }
HH=1111111111111111111111111111111111111111

# ── the fake worker ──────────────────────────────────────────────────────────
cat > "$T/worker.py" <<'PY'
import json, os, sys
from urllib.parse import urlsplit, parse_qs
T = os.environ["FRC_T"]
method, url, body = sys.argv[1], sys.argv[2], sys.argv[3]
u = urlsplit(url if "://" in url else "http://x" + url)
path, q = u.path, parse_qs(u.query)
with open(f"{T}/curl.log", "a") as f: f.write(f"{method} {path}\n")
with open(f"{T}/bodies.log", "a") as f: f.write(f"{method} {path} {body}\n")
def out(code, obj): print(json.dumps(obj)); print(code, end=""); sys.exit(0)
rf = f"{T}/rows.json"
rows = json.load(open(rf)) if os.path.exists(rf) else []
now = int(open(f"{T}/now").read().strip())
def save(): json.dump(rows, open(rf, "w"))
if method == "POST" and path == "/api/fix-rounds/claim":
    b = json.loads(body); stale = b.get("stale_min")
    for r in sorted(rows, key=lambda r: r["id"]):
        if r["box"] != b["box"]: continue
        if r["status"] == "queued" or (r["status"] == "claimed" and isinstance(stale, int)
                                      and now - (r["claimed_at"] or now) >= stale * 60):
            r.update(status="claimed", claimed_by=b["box"], claimed_at=now, attempt=r["attempt"] + 1)
            save(); out(200, {"job": r})
    out(404, {"error": "no row to claim"})
if method == "POST" and path == "/api/fix-rounds/finish":
    b = json.loads(body)
    for r in rows:
        if r["id"] == b["id"] and r["status"] == "claimed" and r["claimed_by"] == b["box"]:
            r.update(status="done", result=b["result"], record_out=b.get("record_out"))
            save(); out(200, {"job": r})
    out(409, {"error": "not claimed by you"})
if method == "POST" and path == "/api/fix-rounds/requeue":
    b = json.loads(body)
    hit = [r for r in rows if r["id"] == b["id"]]
    if not hit: out(404, {"error": "no such fix round"})
    r = hit[0]
    if os.path.exists(f"{T}/requeue409") or r["status"] != "claimed" or r["claimed_by"] != b["box"]:
        out(409, {"error": "requeue refused", "refused": True, "scope": "fix-rounds", "job": r})
    r.update(status="queued", record_in=b.get("record_in"), enqueued_at=now, updated_at=now)
    save(); out(200, {"job": r})
if method == "GET" and path == "/api/fix-rounds":
    sel = [r for r in rows if all(r.get(k) == q[k][0] for k in ("project", "cap_key", "box", "status") if k in q)]
    out(200, {"fix_round_jobs": sel})
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
[ -e "$FRC_T/down" ] && exit 7
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
# The stub round. Modes ($T/stub.mode):
#   ok             record + FIX_RESULT done
#   sleep          held until $T/stub.release (bounded), then ok
#   verify-timeout record with .agent_done, a verify file ending UNIT_EXIT: 124,
#                  FIX_RESULT verify-timeout <b64>
#   rc124          the local record only, no FIX_RESULT, exit 124 (a killed round)
#   die137 / die1  no FIX_RESULT, exit 137 / 1
#   setup          FIX_RESULT setup-blocked <b64> from the round itself, rc 0
#   terminal       record + FIX_RESULT terminal
#   other-rc124    a record for project q only, no local record, exit 124
#   hang           prints FIX_WT <wt>, starts a `timeout 999 sleep $NAP` with its
#                  cwd in <wt> (its own process group), then sleeps 999
fresh() {
  pkill -f "$T/h/" 2>/dev/null; sleep 0.1
  scratch_rm "$H"
  rm -f "$T/rows.json" "$T/curl.log" "$T/bodies.log" "$T/settings.json" "$T/requeue409" "$T/down" \
        "$T"/stub.* "$T/alerts.log" "$T/beats.log" "$T/hang".*
  mkdir -p "$H/env" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/tmp"
  scratch_install_closure bin/fix-round-claim.sh "$H" >/dev/null || { echo "FAIL: closure of bin/fix-round-claim.sh"; exit 1; }
  scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "FAIL: closure of bin/jobs-client.sh"; exit 1; }
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\nJOBS_RETRIES=0\n' > "$H/env/global.env"
  printf 'b1\n' > "$T/boxname"; printf 'p\n' > "$T/projects"
  echo ok > "$T/stub.mode"
  echo 1700000000 > "$T/now"
  printf '#!/bin/bash\ncat "%s/boxname"\n' "$T" > "$H/bin/box-name.sh"
  cat > "$H/bin/fleet-conf.sh" <<EOF
#!/bin/bash
[ "\${1:-}" = --projects-on-box ] && { cat "$T/projects"; exit 0; }
[ "\${2:-}" = repo ] && echo o/r
exit 0
EOF
  printf '#!/bin/bash\necho "tok-$1"\n' > "$H/bin/gh-token.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\n' "$T" > "$H/bin/lane-alert.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beats.log"\n' "$T" > "$H/bin/beat.sh"
  cat > "$H/bin/blocked-resolver.sh" <<EOF
#!/bin/bash
T="$T"; H="$H"; HH="$HH"; NAP="$NAP"
EOF
  cat >> "$H/bin/blocked-resolver.sh" <<'EOF'
n=$(( $(cat "$T/stub.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/stub.n"
cat > "$T/stub.$n.stdin"
S="$H/state/blocked-resolver/p"; mkdir -p "$S"
rec() { # the record the round leaves: stdin's, or a fresh one, plus one attempt
  if [ -s "$T/stub.$n.stdin" ]; then jq -c --arg p "$1" '.project=$p | .attempts += [{"detail":"round ran"}]' "$T/stub.$n.stdin"
  else jq -nc --arg p "$1" '{project:$p, attempts:[{"detail":"round ran"}]}'; fi
}
b64() { printf '%s' "$1" | base64 -w0; }
case "$(cat "$T/stub.mode")" in
  ok) r=$(rec p); printf '%s' "$r" > "$S/ck.json"
      echo "FIX_RECORD $(b64 "$r")"; echo "FIX_RESULT done" ;;
  sleep) for _ in $(seq 1 300); do [ -e "$T/stub.release" ] && break; sleep 0.1; done
      echo "FIX_RECORD $(b64 "$(rec p)")"; echo "FIX_RESULT done" ;;
  verify-timeout)
      r=$(rec p | jq -c --arg h "$HH" '.agent_done = {head:$h, commit:"c0ffee", at:"t", ref:"r", ref_pushed:true}')
      printf '%s' "$r" > "$S/ck.json"
      printf '== unit ==\nboom\nTYPECHECK_EXIT: 0\nUNIT_EXIT: 124\n' > "$S/ck.fix-verify.txt"
      echo "FIX_RECORD $(b64 "$r")"; echo "FIX_RESULT verify-timeout $(b64 "unit ran out of the verify budget")" ;;
  rc124) rec p | jq -c --arg h "$HH" '.agent_done = {head:$h, commit:"c0ffee"}' > "$S/ck.json"; exit 124 ;;
  die137) exit 137 ;;
  die1) exit 1 ;;
  setup) echo "FIX_RESULT setup-blocked $(b64 "worktree add failed")" ;;
  terminal) echo "FIX_RECORD $(b64 "$(rec p)")"; echo "FIX_RESULT terminal" ;;
  other-rc124) echo "FIX_RECORD $(b64 "$(rec q)")"; exit 124 ;;
  hang)
      rec p > "$S/ck.json"
      wt="$H/tmp/brfix/brfix-hang"; mkdir -p "$wt"
      echo "FIX_WT $wt"
      ( cd "$wt" && exec timeout 999 sleep "$NAP" ) & echo $! > "$T/hang.timeout.pid"
      ( cd "$T" && exec timeout 998 sleep 998 ) & echo $! > "$T/hang.out.pid"   # cwd outside the tree: only the session sweep reaches it
      ps -o sid= -p $$ | tr -d ' ' > "$T/hang.sid"
      sleep 999 ;;   # determinism: ok the hung round the runner must kill at its bound; nothing waits on it
esac
exit 0
EOF
  chmod +x "$H"/bin/*.sh
}

ARGS='["p","rk","a reason","https://u/1","rec","tk"]'
R1J='{"project":"p","attempts":[{"detail":"r1"}]}'
# row <id> <box> <status> <attempt> <record_in json-string-or-null> [ck]
row() {
  local now; now=$(cat "$T/now")
  [ -f "$T/rows.json" ] || echo '[]' > "$T/rows.json"
  jq -c --argjson id "$1" --arg box "$2" --arg st "$3" --argjson at "$4" --argjson rin "$5" \
     --arg ck "${6:-ck}" --arg args "$ARGS" --argjson now "$now" \
    '. + [{id:$id, project:"p", cap_key:$ck, box:$box, args:$args, record_in:$rin, hotfix:0,
           status:$st, attempt:$at, enqueued_at:$now, updated_at:$now,
           claimed_by:(if $st=="claimed" then $box else null end),
           claimed_at:(if $st=="claimed" then $now else null end),
           result:null, record_out:null}]' "$T/rows.json" > "$T/rows.tmp" && mv "$T/rows.tmp" "$T/rows.json"
}
rowf() { jq -r --argjson id "$1" ".[] | select(.id==\$id) | $2" "$T/rows.json"; }
stubs() { cat "$T/stub.n" 2>/dev/null || echo 0; }
reqs() { local n; n=$(grep -c "${1:-fix-rounds}" "$T/curl.log" 2>/dev/null); echo "${n:-0}"; }
LOGF="$H/logs/fix-round-claim.log"
logc() { local n; n=$(grep -c -- "$1" "$LOGF" 2>/dev/null); echo "${n:-0}"; }
clean_env() { unset BOX_NAME JOBS_URL HARNESS_SECRET JOBS_BOX FIX_ROUND_CLAIM FIX_ROUND_CLAIM_MAX FIX_ROUND_RUN_MAX \
  FIX_ROUND_TIMEOUT_RETRIES FIX_ROUND_KILL_GRACE_S FIX_ROUND_SPAWN_WAIT_S FIX_ROUND_PASS_WAIT_S \
  BR_FIX_LANE_TIMEOUT BR_FIX_HOP_MARGIN BR_FIX_AGENT_TIMEOUT BR_FIX_VERIFY_TIMEOUT LANE_GATE_DISABLE GH_TOKEN \
  FIX_ROUND_CLAIM_FOREGROUND FRC_POOL_RUN FRC_AS_BOX FRC_IN_PASS; }
# frc [--fg] <args...> [-- env...] — the lane, as cron/a runner/a pool machine runs it.
frc() {
  local fg=0 a=() e=() x seen=0
  [ "${1:-}" = --fg ] && { fg=1; shift; }
  for x in "$@"; do if [ "$x" = -- ]; then seen=1; elif [ "$seen" = 1 ]; then e+=("$x"); else a+=("$x"); fi; done
  ( clean_env
    export HARNESS="$H" LANE_REGISTRY="$T/lanes.json" PATH="$FAKE:$PATH"
    [ "$fg" = 1 ] && export FIX_ROUND_CLAIM_FOREGROUND=1
    for kv in ${e[@]+"${e[@]}"}; do export "${kv?}"; done
    bash "$H/bin/fix-round-claim.sh" ${a[@]+"${a[@]}"} 2>&1 )
}
rowfile() { jq -c --argjson id "$1" '.[] | select(.id==$id)' "$T/rows.json" > "$T/row$1.json"; printf '%s' "$T/row$1.json"; }
hold() { # hold <lockfile> — a live flock holder in the background; prints its pid
  ( exec flock -o "$1" sleep 60 ) >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 50); do flock -n "$1" true 2>/dev/null || break; sleep 0.1; done
  echo "$pid"
}
waitfor() { # waitfor <secs> <cmd...> — poll a condition, bounded
  local n=$(( $1 * 10 )); shift
  for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 0.1; done; return 1
}
all_done() { [ "$(jq '[.[] | select(.status != "done")] | length' "$T/rows.json")" = 0 ]; }
no_runner() { ! pgrep -f "$H/bin/fix-round-claim.sh" >/dev/null 2>&1; }

# ── M1: FIX_ROUND_RUN_MAX=1, one round running: the tick claims nothing ──────
fresh
row 1 b1 queued 0 null ck1; row 2 b1 queued 0 null ck2; row 3 b1 queued 0 null ck3
HP=$(hold "$H/locks/fix-round-project-3-ck1.lock")
frc -- FIX_ROUND_RUN_MAX=1 >/dev/null
[ "$(reqs /api/fix-rounds/claim)" = 0 ] && ok || bad "M1 one running round, limit 1: claim calls $(reqs /api/fix-rounds/claim), want 0"
[ "$(stubs)" = 0 ] && ok || bad "M1 no runner started ($(stubs))"
[ "$(logc 'held back: 1 of 1 running')" = 1 ] && ok || bad "M1 one 'held back: 1 of 1 running' line: $(cat "$LOGF" 2>/dev/null)"
[ ! -s "$T/alerts.log" ] && ok || bad "M1 a held-back row raises no alert: $(cat "$T/alerts.log")"
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
# No round running: exactly one claim and one runner (the runner holds its lock
# before the tick counts again, so a second row waits).
echo sleep > "$T/stub.mode"
frc -- FIX_ROUND_RUN_MAX=1 >/dev/null
[ "$(reqs /api/fix-rounds/claim)" = 1 ] && ok || bad "M1 no running round: claim calls $(reqs /api/fix-rounds/claim), want 1"
waitfor 5 test -s "$T/stub.n"
[ "$(stubs)" = 1 ] && ok || bad "M1 one runner spawned ($(stubs))"
[ "$(jq '[.[] | select(.status == "queued")] | length' "$T/rows.json")" = 2 ] && ok || bad "M1 two rows stay queued: $(jq -c '[.[].status]' "$T/rows.json")"
# D1b: when it ends, the runner drains: the other rows are claimed with no tick.
touch "$T/stub.release"
waitfor 30 all_done && ok || bad "M1/D1b the runner's exit drain worked the queue: $(jq -c '[.[].status]' "$T/rows.json")"
waitfor 10 no_runner
[ "$(stubs)" = 3 ] && ok || bad "M1/D1b three rounds ran in turn ($(stubs))"
[ "$(logc 'drained on exit: claimed 1')" -ge 1 ] && ok || bad "M1/D1b a 'drained on exit: claimed 1' line: $(grep drain "$LOGF")"

# ── M2: limit 2, CLAIM_MAX 5, one running: exactly one claim ─────────────────
fresh
row 1 b1 queued 0 null ck1; row 2 b1 queued 0 null ck2; row 3 b1 queued 0 null ck3
HP=$(hold "$H/locks/fix-round-p-other.lock")
echo sleep > "$T/stub.mode"
frc -- FIX_ROUND_RUN_MAX=2 FIX_ROUND_CLAIM_MAX=5 >/dev/null
[ "$(reqs /api/fix-rounds/claim)" = 1 ] && ok || bad "M2 limit 2 with 1 running: claim calls $(reqs /api/fix-rounds/claim), want 1"
[ "$(logc 'held back: 2 of 2 running')" = 1 ] && ok || bad "M2 held back after the one claim: $(cat "$LOGF")"
touch "$T/stub.release"; kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
waitfor 30 all_done; waitfor 10 no_runner

# ── M3: per-project rows 3 and 1 on a two-project box: the limit is 1 ────────
fresh
printf 'p\nq\n' > "$T/projects"
echo '[{"key":"lane.fix-round-claim.p.fix_round_run_max","value":"3","actor":"op"},{"key":"lane.fix-round-claim.q.fix_round_run_max","value":"1","actor":"op"}]' > "$T/settings.json"
row 1 b1 queued 0 null ck1
HP=$(hold "$H/locks/fix-round-q-ck9.lock")
frc >/dev/null
[ "$(reqs /api/fix-rounds/claim)" = 0 ] && [ "$(logc 'held back: 1 of 1 running')" = 1 ] && ok \
  || bad "M3 the box limit is the minimum over its projects: claims $(reqs /api/fix-rounds/claim), log $(cat "$LOGF")"
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
# M3b: both rows 3 -> one held still leaves room.
echo '[{"key":"lane.fix-round-claim.p.fix_round_run_max","value":"3","actor":"op"},{"key":"lane.fix-round-claim.q.fix_round_run_max","value":"3","actor":"op"}]' > "$T/settings.json"
rm -f "$H/state/settings-cache.json"   # the 60 s settings cache holds the rows read above
HP=$(hold "$H/locks/fix-round-q-ck9.lock")
frc --fg >/dev/null
[ "$(reqs /api/fix-rounds/claim)" -ge 1 ] && [ "$(rowf 1 .status)" = done ] && ok || bad "M3b limit 3 with 1 running claims: $(reqs /api/fix-rounds/claim) row $(rowf 1 .status)"
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null

# ── D1: a runner that ends drains the queue (no tick run by the test) ───────
fresh
row 1 b1 claimed 1 null ck1; row 2 b1 queued 0 null ck2
frc --fg --run 1 "$(rowfile 1)" >/dev/null
FIN=$(grep -n 'POST /api/fix-rounds/finish' "$T/curl.log" | head -1 | cut -d: -f1)
CLM=$(grep -n 'POST /api/fix-rounds/claim' "$T/curl.log" | head -1 | cut -d: -f1)
[ -n "$FIN" ] && [ -n "$CLM" ] && [ "$CLM" -gt "$FIN" ] && ok || bad "D1 the claim call follows the finish: $(cat "$T/curl.log")"
[ "$(rowf 2 .status)" = done ] && [ "$(stubs)" = 2 ] && ok || bad "D1 row 2 ran from the drain: $(rowf 2 .status) stubs $(stubs)"

# ── D2: a pool machine does not drain ────────────────────────────────────────
fresh
row 1 b1 claimed 1 null ck; row 2 b1 queued 0 null ck2
OUT=$(frc --fg --run-pool 1 b1 p ck)
grep -q '^FIX_ROUND_FINISHED done finish=ok' <<<"$OUT" && ok || bad "D2 the pool round finished: $OUT"
[ "$(reqs /api/fix-rounds/claim)" = 0 ] && [ "$(rowf 2 .status)" = queued ] && ok || bad "D2 no drain claim on a pool machine: $(reqs /api/fix-rounds/claim) row2 $(rowf 2 .status)"

# ── R1: the re-offer table ───────────────────────────────────────────────────
# Each case: one claimed row, the drain held off (a live claim pass and a
# 0-second wait), one --run. Re-offered = one requeue call and the row queued.
r1() { # r1 <name> <mode> <want: requeue|finish> [record_in]
  fresh
  row 7 b1 claimed 1 "${4:-null}" ck
  echo "$2" > "$T/stub.mode"
  local hp; hp=$(hold "$H/locks/frc-claim-pass.lock")
  frc --run 7 "$(rowfile 7)" -- FIX_ROUND_PASS_WAIT_S=0 >/dev/null
  kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
  if [ "$3" = requeue ]; then
    [ "$(reqs /api/fix-rounds/requeue)" = 1 ] && [ "$(rowf 7 .status)" = queued ] && ok \
      || bad "R1 $1: re-offered (requeue calls $(reqs /api/fix-rounds/requeue), status $(rowf 7 .status), log $(tail -3 "$LOGF"))"
  else
    [ "$(reqs /api/fix-rounds/requeue)" = 0 ] && [ "$(rowf 7 .status)" = done ] && ok \
      || bad "R1 $1: not re-offered (requeue calls $(reqs /api/fix-rounds/requeue), status $(rowf 7 .status))"
  fi
}
r1 verify-timeout verify-timeout requeue
r1 rc124-no-result rc124 requeue
r1 own-setup-blocked setup finish
r1 rc137 die137 finish
r1 rc1 die1 finish
r1 done ok finish
r1 terminal terminal finish
CAPREC=$(jq -nc --arg h "$HH" '{project:"p",attempts:[],timeout_requeues:[{head:$h,kind:"verify",attempt:1,last:"UNIT_EXIT: 124"}]}')
r1 at-cap verify-timeout finish "$(jq -Rn --arg r "$CAPREC" '$r')"
r1 other-project other-rc124 finish
# R1 at-cap: the drain line is written once the pass lock is busy
grep -q 'drain: another claim pass' "$LOGF" && ok || bad "R1 a busy pass lock is one drain line: $(tail -2 "$LOGF")"

# ── R2: the re-offered row carries the record and the next claim is attempt 2 ─
fresh
row 8 b1 claimed 1 "$(jq -Rn --arg r "$R1J" '$r')" ck
echo verify-timeout > "$T/stub.mode"
HP=$(hold "$H/locks/frc-claim-pass.lock")
frc --run 8 "$(rowfile 8)" -- FIX_ROUND_PASS_WAIT_S=0 >/dev/null
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
RIN=$(rowf 8 .record_in)
[ "$(jq -r '.timeout_requeues | length' <<<"$RIN" 2>/dev/null)" = 1 ] && ok || bad "R2 record_in has one timeout_requeues entry: $RIN"
[ "$(jq -r '.timeout_requeues[0].head' <<<"$RIN" 2>/dev/null)" = "$HH" ] && ok || bad "R2 the entry is keyed by the agent's head"
[ "$(jq -r '.timeout_requeues[0].last' <<<"$RIN" 2>/dev/null)" = "UNIT_EXIT: 124" ] && ok || bad "R2 the entry names the last verify line: $(jq -c '.timeout_requeues' <<<"$RIN")"
[ "$(jq -r '.agent_done.head' <<<"$RIN" 2>/dev/null)" = "$HH" ] && ok || bad "R2 the agent record rides along to the next round"
[ "$(logc 're-offered after a timeout (attempt 2, timeout 1 of 2)')" = 1 ] && ok || bad "R2 the re-offer line: $(cat "$LOGF")"
grep -q 'fix_round_requeued' "$T/beats.log" 2>/dev/null && grep -q 'fix_round_verify_timeout' "$T/beats.log" && ok \
  || bad "R2 the feed beats fix_round_verify_timeout and fix_round_requeued: $(cat "$T/beats.log" 2>/dev/null)"
echo ok > "$T/stub.mode"
frc --fg >/dev/null
[ "$(rowf 8 .attempt)" = 2 ] && [ "$(rowf 8 .status)" = done ] && ok || bad "R2 the next claim is attempt 2: $(rowf 8 '[.attempt,.status]|@csv')"
[ "$(jq -r '.timeout_requeues | length' "$T/stub.2.stdin" 2>/dev/null)" = 1 ] && ok || bad "R2 the second round got the record on stdin"
[ ! -e "$H/bin/blocked-resolver.d" ] && ok || bad "R2 no hub code is in the scratch box"

# ── C1: N=2, the second timeout on one head is the cap: one alert ───────────
fresh
row 9 b1 claimed 1 "$(jq -Rn --arg r "$R1J" '$r')" ck
echo verify-timeout > "$T/stub.mode"
frc --fg --run 9 "$(rowfile 9)" >/dev/null
[ "$(stubs)" = 2 ] && ok || bad "C1 the drain re-ran the re-offered row at once ($(stubs) rounds)"
[ "$(rowf 9 .status)" = done ] && ok || bad "C1 the capped row is finished: $(rowf 9 .status)"
case "$(rowf 9 .result)" in "verify-timeout "*) ok ;; *) bad "C1 the capped row's result is verify-timeout: $(rowf 9 .result)" ;; esac
[ "$(reqs /api/fix-rounds/requeue)" = 1 ] && ok || bad "C1 exactly one re-offer: $(reqs /api/fix-rounds/requeue)"
[ "$(grep -c . "$T/alerts.log" 2>/dev/null)" = 1 ] && ok || bad "C1 exactly one alert line: $(cat "$T/alerts.log" 2>/dev/null)"
A=$(cat "$T/alerts.log" 2>/dev/null)
grep -q -- "--id fix-round-timeout-cap-p-ck-${HH:0:8}" <<<"$A" && ok || bad "C1 the alert id is keyed on (project, cap_key, head8): $A"
[ "$(grep -o 'UNIT_EXIT: 124' <<<"$A" | wc -l)" = 2 ] && grep -q 'attempt 1' <<<"$A" && grep -q 'attempt 2' <<<"$A" && ok \
  || bad "C1 the alert names both attempts and their last verify line: $A"
[ "$(logc "row 9 timeout cap reached")" = 1 ] && ok || bad "C1 one cap line: $(cat "$LOGF")"
[ "$(jq -r '.timeout_requeues | length' <<<"$(rowf 9 .record_out)" 2>/dev/null)" = 2 ] && ok || bad "C1 the finished record has both entries"
grep -q 'fix_round_timeout_cap' "$T/beats.log" 2>/dev/null && ok || bad "C1 the feed beats fix_round_timeout_cap"

# ── K1: the lock-held table ──────────────────────────────────────────────────
fresh
lh() { ( export HARNESS="$H"; . "$H/bin/lib/fix-round-reap.sh" 2>/dev/null || exit 9; "$@" ) >/dev/null 2>&1; echo $?; }
lrun() { ( export HARNESS="$H"; . "$H/bin/lib/fix-round-reap.sh" 2>/dev/null || exit 9; "$@" ) 2>/dev/null; }
L="$H/locks"
H1P=$(hold "$L/fix-round-p-a.lock"); H2P=$(hold "$L/fix-round-p-b.lock")
: > "$L/fix-round-p-gone.lock"
PP=$(hold "$L/frc-claim-pass.lock"); OP=$(hold "$L/fix-round-x.lock")
[ "$(lh frr_lock_held "$L/fix-round-p-a.lock")" = 0 ] && ok || bad "K1 a held lock is held"
[ "$(lh frr_lock_held "$L/fix-round-p-b.lock")" = 0 ] && ok || bad "K1 a second held lock is held"
[ "$(lh frr_lock_held "$L/fix-round-p-gone.lock")" = 1 ] && ok || bad "K1 a lock left by an exited runner is free"
[ "$(lrun frr_running "$L")" = 2 ] && ok || bad "K1 two runners: the pass lock and a one-dash name are not counted (got '$(lrun frr_running "$L")')"
[ "$(lh env FRR_PROC_LOCKS=/nonexistent bash -c ". '$H/bin/lib/fix-round-reap.sh'; frr_lock_held '$L/fix-round-p-gone.lock'")" = 1 ] && ok \
  || bad "K1 /proc/locks unreadable, a free file: free (the probe)"
[ "$(lh env FRR_PROC_LOCKS=/nonexistent bash -c ". '$H/bin/lib/fix-round-reap.sh'; frr_lock_held '$L/fix-round-p-a.lock'")" = 0 ] && ok \
  || bad "K1 /proc/locks unreadable, a held file: held (the probe)"
[ "$(lh frr_lock_held "$L/fix-round-p-a.lock")" = 0 ] && ok || bad "K1 the probe did not take the held lock away"
kill "$H1P" "$H2P" "$PP" "$OP" 2>/dev/null; wait 2>/dev/null

# ── K2: a round past its bound: the whole session is killed, the tree removed ─
fresh
row 11 b1 claimed 1 null ck
echo hang > "$T/stub.mode"
HP=$(hold "$H/locks/frc-claim-pass.lock")   # the drain stays off: this case is one round
S=$SECONDS
frc --run 11 "$(rowfile 11)" -- BR_FIX_LANE_TIMEOUT=6 BR_FIX_AGENT_TIMEOUT=2 BR_FIX_VERIFY_TIMEOUT=2 BR_FIX_HOP_MARGIN=1 FIX_ROUND_KILL_GRACE_S=2 FIX_ROUND_PASS_WAIT_S=0 >/dev/null
E=$((SECONDS - S))
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
[ "$E" -lt 30 ] && ok || bad "K2 the runner returned in ${E}s (bound 5s + grace)"
SID=$(cat "$T/hang.sid" 2>/dev/null)
[ -n "$SID" ] && [ -z "$(ps -eo pid=,sid= | awk -v s="$SID" '$2 == s')" ] && ok || bad "K2 no process is left in the round's session $SID: $(ps -eo pid=,sid=,args= | awk -v s="$SID" '$2 == s')"
TP=$(cat "$T/hang.timeout.pid" 2>/dev/null)
[ -n "$TP" ] && ! kill -0 "$TP" 2>/dev/null && ok || bad "K2 the nested timeout (its own process group) is gone"
pgrep -f "sleep $NAP\$" >/dev/null && bad "K2 this run's sleep $NAP is still alive" || ok   # determinism: ok a pgrep pattern, not a sleep
OP=$(cat "$T/hang.out.pid" 2>/dev/null)
[ -n "$OP" ] && ! kill -0 "$OP" 2>/dev/null && ok || bad "K2 a nested timeout outside the tree (same session) is swept"
LEFT=$(for c in /proc/[0-9]*/cwd; do l=$(readlink "$c" 2>/dev/null) || continue; case "$l" in "$H/tmp/brfix/brfix-hang"*) echo "$c" ;; esac; done)
[ -z "$LEFT" ] && ok || bad "K2 no process has its cwd under the worktree: $LEFT"
[ ! -e "$H/tmp/brfix/brfix-hang" ] && ok || bad "K2 the worktree is removed"
[ "$(rowf 11 .status)" = queued ] && ok || bad "K2 a round killed at its bound with rc 124 is re-offered: $(rowf 11 '[.status,.result]|@csv')"
grep -q 'session' "$LOGF" && ok || bad "K2 the sweep is logged"

# ── K3/K4: the cwd check before the removal ──────────────────────────────────
fresh
WT="$H/tmp/brfix/brfix-k3"; mkdir -p "$WT"
( cd "$WT" && trap '' TERM && exec sleep 300 ) & K3P=$!
sleep 0.3
lrun frr_wt_remove "$WT" 2 >/dev/null; RC=$?
[ "$RC" = 0 ] && ! kill -0 "$K3P" 2>/dev/null && [ ! -e "$WT" ] && ok || bad "K3 a TERM-proof process in the tree is KILLed, then the tree is removed (rc $RC)"
wait "$K3P" 2>/dev/null
WT="$H/tmp/brfix/brfix-k4"; mkdir -p "$WT"
( cd "$WT" && exec sleep 300 ) & K4P=$!
sleep 0.3
( export HARNESS="$H" LOG="$T/k4.log"; . "$H/bin/lib/fix-round-reap.sh" || exit 9
  kill() { return 1; }   # this pid cannot be killed
  frr_wt_remove "$WT" 1 ) >/dev/null 2>>"$T/k4.err"; RC=$?
[ "$RC" = 1 ] && [ -d "$WT" ] && ok || bad "K4 an unkillable cwd process: the tree is left (rc $RC)"
[ "$(grep -c "$K4P" "$T/k4.err" 2>/dev/null)" -ge 1 ] && ok || bad "K4 one line names the pid: $(cat "$T/k4.err" 2>/dev/null)"
command kill "$K4P" 2>/dev/null; wait "$K4P" 2>/dev/null

# ── S1: a requeue answered 409 is not a re-offer ─────────────────────────────
fresh
row 12 b1 claimed 1 null ck
echo verify-timeout > "$T/stub.mode"; touch "$T/requeue409"
HP=$(hold "$H/locks/frc-claim-pass.lock")
frc --run 12 "$(rowfile 12)" -- FIX_ROUND_PASS_WAIT_S=0 >/dev/null
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
[ "$(logc 're-offered')" = 0 ] && ok || bad "S1 a 409 requeue writes no re-offered line: $(cat "$LOGF")"
[ "$(logc 'row 12 finished: verify-timeout')" = 1 ] && [ "$(rowf 12 .status)" = done ] && ok || bad "S1 the round is finished instead: $(rowf 12 .status) $(cat "$LOGF")"

# ── S2: stale_min = ceil((agent + verify + margin) / 60) ─────────────────────
stale_of() { grep '/api/fix-rounds/claim' "$T/bodies.log" | head -1 | cut -d' ' -f3- | jq -c '.stale_min'; }
fresh; frc >/dev/null
[ "$(stale_of)" = 110 ] && ok || bad "S2 default stale_min $(stale_of), want 110 (3600+2700+300)"
fresh; frc -- BR_FIX_AGENT_TIMEOUT=3600 BR_FIX_VERIFY_TIMEOUT=2700 BR_FIX_HOP_MARGIN=300 >/dev/null
[ "$(stale_of)" = 110 ] && ok || bad "S2 3600+2700+300 stale_min $(stale_of), want 110"
fresh; frc -- BR_FIX_AGENT_TIMEOUT=100 BR_FIX_VERIFY_TIMEOUT=50 BR_FIX_HOP_MARGIN=10 >/dev/null
[ "$(stale_of)" = 3 ] && ok || bad "S2 100+50+10 stale_min $(stale_of), want 3"

# ── P1-P2: the pool key; P3: a pool round's re-offer word ────────────────────
fresh
pk() { ( export HARNESS="$H"; . "$H/bin/lib/fix-round-pool.sh" || exit 9; frp_key "$@" ) 2>/dev/null; }
CK8=$(printf '%s' ck | sha256sum | cut -c1-8)
[ "$(pk 5 ck 1)" = "FXR-5-$CK8-r1" ] && ok || bad "P1 a re-offered round has its own pool key: $(pk 5 ck 1)"
[ "$(pk 5 ck 0)" = "FXR-5-$CK8" ] && [ "$(pk 5 ck)" = "FXR-5-$CK8" ] && ok || bad "P2 no re-offer: the key is unchanged: $(pk 5 ck 0) / $(pk 5 ck)"
P1KEY=$( ( export HARNESS="$H"; . "$H/bin/lib/fix-round-pool.sh" || exit 9
  frc_log() { :; }; _jobs_req() { echo '{"queue":[]}'; }; queue_put() { echo queued; }
  frp_put 5 b1 p ck 2 1; echo "$FRP_KEY" ) 2>/dev/null)
[ "$P1KEY" = "FXR-5-$CK8-r1" ] && ok || bad "P1 frp_put uses the re-offer count: $P1KEY"
fresh
row 13 b1 claimed 1 null ck
echo verify-timeout > "$T/stub.mode"
OUT=$(frc --run-pool 13 b1 p ck)
grep -q '^FIX_ROUND_FINISHED verify-timeout finish=requeued$' <<<"$OUT" && ok || bad "P3 the pool word for a re-offered round: $OUT"
[ "$(rowf 13 .status)" = queued ] && ok || bad "P3 the pool machine re-offered the row: $(rowf 13 .status)"

# ── K5: the registry defaults ────────────────────────────────────────────────
kd() { jq -r --arg e "$1" '[.. | objects | select(.env? == $e) | .default][0] // "missing"' "$T/lanes.json"; }
[ "$(kd FIX_ROUND_RUN_MAX)" = 1 ] && [ "$(kd FIX_ROUND_TIMEOUT_RETRIES)" = 2 ] && [ "$(kd FIX_ROUND_KILL_GRACE_S)" = 60 ] \
  && [ "$(kd FIX_ROUND_SPAWN_WAIT_S)" = 10 ] && [ "$(kd FIX_ROUND_PASS_WAIT_S)" = 30 ] && [ "$(kd BR_FIX_VERIFY_TIMEOUT)" = 2700 ] \
  && ok || bad "K5 defaults: $(for k in FIX_ROUND_RUN_MAX FIX_ROUND_TIMEOUT_RETRIES FIX_ROUND_KILL_GRACE_S FIX_ROUND_SPAWN_WAIT_S FIX_ROUND_PASS_WAIT_S BR_FIX_VERIFY_TIMEOUT; do printf '%s=%s ' "$k" "$(kd "$k")"; done)"

# ── Q1-Q3: fix_round_requeue ─────────────────────────────────────────────────
fresh
row 14 b1 claimed 1 null ck
q() { ( clean_env; export HARNESS="$H" PATH="$FAKE:$PATH"; set -a; . "$H/env/global.env"; set +a
        . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/fix-round-queue.sh" || exit 8
        fix_round_requeue "$@" >/dev/null ) 2>/dev/null; echo $?; }
[ "$(q 14 b1 '{"project":"p"}')" = 0 ] && [ "$(rowf 14 .status)" = queued ] && [ "$(rowf 14 .record_in)" = '{"project":"p"}' ] && ok \
  || bad "Q1 a 200 is rc 0 and the record travels byte for byte: $(rowf 14 '[.status,.record_in]|@json')"
[ "$(q 14 b1 '{"project":"p"}')" = 9 ] && ok || bad "Q2 a 409 (the row is queued now) is rc 9"
touch "$T/down"
[ "$(q 14 b1 '{}')" = 1 ] && ok || bad "Q3 an outage is rc 1"
rm -f "$T/down"

# ── Z1: no vendor call: every request reached the fake worker ────────────────
[ -z "$(grep -v '^\(GET\|POST\) /api/' "$T/curl.log" 2>/dev/null)" ] && ok || bad "Z1 a request left the fake worker: $(grep -v '^\(GET\|POST\) /api/' "$T/curl.log")"

pkill -f "$T/h/" 2>/dev/null
echo "fix-round-run-max.bh-9906: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
