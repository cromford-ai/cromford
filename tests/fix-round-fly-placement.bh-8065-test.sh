#!/bin/bash
# tests/fix-round-fly-placement.bh-8065-test.sh — BH-8065: a blocked-resolver
# fix round runs on a Fly pool machine when the settings row
# lane_placement.blocked-resolver-fix.<project> = fly says so, so the project
# box (box-project-6-os-1: rc 137) runs no --fix-here.
#
# WHAT IS DRIVEN. The real bin/fix-round-claim.sh (tick, --run-pool), the real
# bin/lib/fix-round-pool.sh, bin/lib/lane-placement.sh, the jobs client and
# bin/lib/fix-round-queue.sh, installed with scratch_install_closure into a
# scratch box harness. The real bin/lib/queue-row-job.sh maps the pool row to
# job.json, and the real _run_job / run_fixround_job of fly/builder-runner.sh
# run it. The real bin/fly-pool.sh reaps it. Stubs: curl (a fake jobs worker
# over fix_round_jobs, build_queue, routing and settings), bin/blocked-resolver.sh
# (records each --fix-here), bin/box-name.sh, bin/fleet-conf.sh, bin/gh-token.sh,
# flyctl. 0 network calls.
#
#   F1  row fly + routing pool|0: the tick puts ONE pool row FXR-<id>-<ck8>
#       (target fly, ticket_id <id>, meta kind fixround, identity only); no
#       --fix-here, no finish, the fix row stays claimed. ' FLY ' is fly too.
#   F2  re-offered while the pool row is queued, then claimed: nothing.
#   F3  re-offered while the pool row is done, then failed: ONE setup-blocked
#       finish that names the key; no second round.
#   F4  a pool row of another fix id only: the put happens.
#   F5  (c)-(k): no row, a lane row, the default row, halted, fly1, a box: row,
#       settings outage, another project's row, a hub_only row: ONE --fix-here
#       on the box and 0 queue POSTs.
#   F6  the queue read fails, then the put fails: nothing runs, nothing posts.
#   M1  put -> queue_row_job_file -> job.json -> _run_job -> --run-pool -> ONE
#       --fix-here with the row's args and record_in -> ONE finish as the
#       claiming box -> RESULT FIX_ROUND_FINISHED done finish=ok.
#   M2  --run-pool on a done, adopted, queued, other-box or other-id row:
#       FIX_ROUND_SKIPPED, nothing runs, nothing posts.
#   M3  the round dies rc 137 on the machine: ONE setup-blocked finish.
#   M4  warm-up fails: ONE setup-blocked finish, FIX_ROUND_SETUP_FAILED.
#   Q1-Q3 queue_row_job_file refuses a key/kind mismatch and a key that does
#       not name the meta's id and cap_key.
#   P1  the pool gates read FXR-12-abcdef01 as they read an LR- row, and the
#       project-3 ticket key TK-64 stays a ticket.
#   R1-R4 the fly-pool reap: FINISHED -> done, SETUP_FAILED -> failed, a key /
#       word mismatch -> failed + 1 alert, a dead machine and BUILD_DEFERRED ->
#       failed, not requeued, 1 alert each.
#   S1  the composed jobs schema seeds the project-6-os row (fly), and only it.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fix-round-fly-placement.bh-8065-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq python3 flock base64 sha256sum; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

H="$T/h"
FAKE="$T/fakebin"
mkdir -p "$FAKE"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: could not compose the lane registry"; exit 1; }

# ── the fake jobs worker ─────────────────────────────────────────────────────
cat > "$T/worker.py" <<'PY'
import json, os, sys, urllib.parse
T = os.environ["FRP_T"]
method, url, body = sys.argv[1], sys.argv[2], sys.argv[3]
path = url.split("://", 1)[-1]
path = path[path.index("/"):] if "/" in path else "/"
with open(f"{T}/curl.log", "a") as f: f.write(f"{method} {path} {body}\n")
def out(code, obj): print(json.dumps(obj)); print(code, end=""); sys.exit(0)
def load(n, d):
    p = f"{T}/{n}"
    return json.load(open(p)) if os.path.exists(p) else d
def save(n, v): json.dump(v, open(f"{T}/{n}", "w"))
u = urllib.parse.urlsplit(path); q = dict(urllib.parse.parse_qsl(u.query)); route = u.path
rows = load("rows.json", []); queue = load("queue.json", [])
now = int(open(f"{T}/now").read().strip())
if route == "/api/fix-rounds/claim" and method == "POST":
    b = json.loads(body); stale = b.get("stale_min")
    for r in sorted(rows, key=lambda r: r["id"]):
        if r["box"] != b["box"]: continue
        if r["status"] == "queued" or (r["status"] == "claimed" and isinstance(stale, int)
                                      and now - r["claimed_at"] >= stale * 60):
            r.update(status="claimed", claimed_by=b["box"], claimed_at=now, attempt=r["attempt"] + 1)
            save("rows.json", rows); out(200, {"job": r})
    out(404, {"error": "no row to claim"})
if route == "/api/fix-rounds/finish" and method == "POST":
    b = json.loads(body)
    for r in rows:
        if r["id"] == b["id"] and r["status"] == "claimed" and r["claimed_by"] == b["box"]:
            r.update(status="done", result=b["result"], record_out=b.get("record_out"))
            save("rows.json", rows); out(200, {"job": r})
    out(409, {"error": "not claimed by you"})
if route == "/api/fix-rounds" and method == "GET":
    sel = [r for r in sorted(rows, key=lambda r: r["id"])
           if ("project" not in q or r["project"] == q["project"]) and ("cap_key" not in q or r["cap_key"] == q["cap_key"])]
    out(200, {"fix_round_jobs": sel, "truncated": False})
if route == "/api/queue" and method == "GET":
    if os.path.exists(f"{T}/queue.fail"): out(500, {"error": "fixture outage"})
    sel = [r for r in queue if r["project"] == q.get("project", r["project"]) and r["ticket_key"] == q.get("key", r["ticket_key"])]
    out(200, {"queue": sel[: int(q.get("limit", "200"))]})
if route == "/api/queue" and method == "POST":
    if os.path.exists(f"{T}/queuepost.fail"): out(500, {"error": "fixture outage"})
    b = json.loads(body)
    for r in queue:
        if r["project"] == b["project"] and r["ticket_key"] == b["key"] and r["status"] in ("queued", "claimed"):
            out(200, {"queued": r, "duplicate": True})
    queue = [r for r in queue if not (r["project"] == b["project"] and r["ticket_key"] == b["key"])]
    r = {"project": b["project"], "ticket_key": b["key"], "ticket_id": b.get("ticket_id"), "status": "queued",
         "target": b.get("target"), "attempt": b.get("attempt", 0), "meta": b.get("meta"), "reason": None}
    queue.append(r); save("queue.json", queue); out(200, {"queued": r, "duplicate": False})
if route == "/api/queue" and method == "PATCH":
    b = json.loads(body)
    for r in queue:
        if r["project"] == b["project"] and r["ticket_key"] == b["key"]:
            r.update(status=b["status"], reason=b.get("reason"))
    save("queue.json", queue); out(200, {"ok": True})
if route.startswith("/api/routing/") and method == "GET":
    rt = load("routing.json", {}).get(route[len("/api/routing/"):])
    if rt is None: out(404, {"error": "no routing row"})
    out(200, {"routing": rt})
if route.startswith("/api/settings"):
    if os.path.exists(f"{T}/settings.fail"): out(500, {"error": "fixture outage"})
    s = load("settings.json", [])
    if route == "/api/settings": out(200, {"settings": s})
    k = route[len("/api/settings/"):]
    hit = [x for x in s if x["key"] == k]
    if hit: out(200, {"setting": hit[0]})
    out(404, {"error": "no such setting"})
out(404, {"error": "not found"})
PY
cat > "$FAKE/curl" <<EOF
#!/bin/bash
export FRP_T="$T"
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
exec python3 "$FRP_T/worker.py" "$method" "$url" "$body"
EOF
chmod +x "$FAKE/curl"

# ── the scratch harness (the box, and the machine runs the same tree) ────────
fresh() {
  scratch_rm "$H"
  rm -f "$T"/rows.json "$T"/queue.json "$T"/curl.log "$T"/settings.json "$T"/routing.json "$T"/*.fail "$T"/stub.* "$T/alerts"
  mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/flags" "$H/locks"
  printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.invalid\nJOBS_RETRIES=0\n' > "$H/env/global.env"
  printf 'b1\n' > "$T/boxname"
  echo ok > "$T/stub.mode"
  date +%s > "$T/now"
  echo '[]' > "$T/queue.json"
  printf '#!/bin/bash\ncat "%s/boxname"\n' "$T" > "$H/bin/box-name.sh"
  printf '#!/bin/bash\n[ "${2:-}" = repo ] && echo o/r\n' > "$H/bin/fleet-conf.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/gh-token.calls"\n[ -e "%s/gh-token.empty" ] || echo "tok-fixture-$1"\n' "$T" "$T" > "$H/bin/gh-token.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\n' "$T" > "$H/bin/alert-line.sh"
  cat > "$H/bin/blocked-resolver.sh" <<EOF
#!/bin/bash
T="$T"
EOF
  cat >> "$H/bin/blocked-resolver.sh" <<'EOF'
n=$(( $(cat "$T/stub.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/stub.n"
printf '%s\0' "$@" > "$T/stub.$n.argv"
cat > "$T/stub.$n.stdin"
printf '%s' "${GH_TOKEN:-}" > "$T/stub.$n.tok"
r=$(jq -nc '{project:"p", attempts:[{"detail":"round ran"}]}')
case "$(cat "$T/stub.mode")" in
  ok) echo "FIX_RECORD $(printf '%s' "$r" | base64 -w0)"; echo "FIX_RESULT done" ;;
  die137) exit 137 ;;
esac
exit 0
EOF
  chmod +x "$H"/bin/*.sh
  for s in bin/fix-round-claim.sh bin/jobs-client.sh bin/lib/fix-round-pool.sh bin/lib/lane-placement.sh bin/lib/queue-row-job.sh; do
    [ -r "$DIR/$s" ] || continue
    scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
  done
}

ARGS='["p","rk","a reason with spaces","https://u/1","rec","tk"]'
R1='{"project":"p","attempts":[{"detail":"r1"}]}'
CK8=$(printf '%s' ck | sha256sum | cut -c1-8)
KEY="FXR-12-$CK8"
# row <id> <box> <status> <attempt> <record_in json-string-or-null> [claimed_min_ago] [claimed_by]
row() {
  local ago="${6:-}" now; now=$(cat "$T/now")
  [ -f "$T/rows.json" ] || echo '[]' > "$T/rows.json"
  jq -c --argjson id "$1" --arg box "$2" --arg st "$3" --argjson at "$4" --argjson rin "$5" \
     --arg args "$ARGS" --arg ago "$ago" --argjson now "$now" --arg by "${7:-$2}" \
    '. + [{id:$id, project:"p", cap_key:"ck", box:$box, args:$args, record_in:$rin, hotfix:0,
           status:$st, attempt:$at,
           claimed_by:(if $st=="claimed" or $st=="done" then $by else null end),
           claimed_at:(if $ago=="" then null else ($now - ($ago|tonumber)*60) end),
           result:null, record_out:null}]' "$T/rows.json" > "$T/rows.tmp" && mv "$T/rows.tmp" "$T/rows.json"
}
rowf() { jq -r --argjson id "$1" ".[] | select(.id==\$id) | $2" "$T/rows.json"; }
# qrow <key> <status> [reason] — one build_queue row
qrow() {
  jq -c --arg k "$1" --arg s "$2" --arg r "${3:-}" \
    '. + [{project:"p", ticket_key:$k, ticket_id:"12", status:$s, target:"fly", attempt:0, meta:"{}", reason:(if $r == "" then null else $r end)}]' \
    "$T/queue.json" > "$T/queue.tmp" && mv "$T/queue.tmp" "$T/queue.json"
}
setting() { # setting <key> <value>
  [ -f "$T/settings.json" ] || echo '[]' > "$T/settings.json"
  jq -c --arg k "$1" --arg v "$2" '. + [{key:$k, value:$v, actor:"op"}]' "$T/settings.json" > "$T/settings.tmp" && mv "$T/settings.tmp" "$T/settings.json"
}
routing() { jq -nc --arg b "$1" --argjson h "${2:-0}" '{p:{builder:$b, halted:$h}}' > "$T/routing.json"; }
fly_on() { setting lane_placement.blocked-resolver-fix.p "${1:-fly}"; routing pool 0; }
stubs() { cat "$T/stub.n" 2>/dev/null || echo 0; }
cnt() { local n; n=$(grep -c -- "$1" "$T/curl.log" 2>/dev/null); echo "${n:-0}"; }
puts() { cnt '^POST /api/queue '; }
finishes() { cnt '^POST /api/fix-rounds/finish '; }
LOGF() { cat "$H/logs/fix-round-claim.log" 2>/dev/null; }

# tick [env assignments...] — the lane as cron runs it (foreground runner).
tick() {
  ( unset BOX_NAME JOBS_URL HARNESS_SECRET JOBS_BOX FIX_ROUND_CLAIM FIX_ROUND_CLAIM_MAX \
          BR_FIX_LANE_TIMEOUT BR_FIX_HOP_MARGIN LANE_GATE_DISABLE GH_TOKEN
    export HARNESS="$H" LANE_REGISTRY="$T/lanes.json" PATH="$FAKE:$PATH" FIX_ROUND_CLAIM_FOREGROUND=1 \
           JOBS_SETTINGS_CACHE_S=0 LANE_GATE_CACHE_S=0
    for kv in "$@"; do export "${kv?}"; done
    bash "$H/bin/fix-round-claim.sh" >/dev/null 2>&1 )
}
# runpool <args...> — the machine's verb, as run_fixround_job runs it; stdout to $T/rp.out
runpool() {
  ( unset BOX_NAME JOBS_URL HARNESS_SECRET JOBS_BOX GH_TOKEN
    export HARNESS="$H" LANE_REGISTRY="$T/lanes.json" PATH="$FAKE:$PATH" JOBS_SETTINGS_CACHE_S=0 LANE_GATE_CACHE_S=0
    bash "$H/bin/fix-round-claim.sh" --run-pool "$@" > "$T/rp.out" 2>/dev/null )
}

# ── F1: the row places the round on the pool; nothing runs on the box ────────
fresh; fly_on
row 12 b1 queued 0 "$(jq -Rn --arg r "$R1" '$r')"
tick
[ "$(puts)" = 1 ] && ok || bad "F1 pool puts=$(puts) (want 1): $(LOGF)"
PUT=$(grep '^POST /api/queue ' "$T/curl.log" | tail -1 | sed 's/^POST \/api\/queue //')
[ "$(jq -r '"\(.project) \(.key) \(.target) \(.ticket_id)"' <<<"$PUT" 2>/dev/null)" = "p $KEY fly 12" ] && ok || bad "F1 the put names p, $KEY, fly and the fix id: $PUT"
M=$(jq -r '.meta' <<<"$PUT" 2>/dev/null)
[ "$(jq -r '"\(.kind) \(.id) \(.box) \(.project) \(.cap_key) \(.attempt) \(.by)"' <<<"$M" 2>/dev/null)" = "fixround 12 b1 p ck 1 fix-round-claim" ] \
  && ok || bad "F1 the meta carries kind, id, box, project, cap_key, attempt: $M"
[ "$(jq -r 'has("args") or has("record_in")' <<<"$M" 2>/dev/null)" = false ] && ok || bad "F1 the meta carries no args and no record_in: $M"
[ "$(stubs)" = 0 ] && ok || bad "F1 THE POINT: no --fix-here on the box, got $(stubs)"
[ "$(finishes)" = 0 ] && ok || bad "F1 no finish, got $(finishes)"
[ "$(rowf 12 .status)" = claimed ] && [ "$(rowf 12 .claimed_by)" = b1 ] && ok || bad "F1 the fix row stays claimed by b1: $(rowf 12 '[.status,.claimed_by]|@csv')"
LOGF | grep -q "row 12 p/ck: queued on the Fly pool as $KEY" && ok || bad "F1 no queued line: $(LOGF)"
cp "$T/queue.json" "$T/queue-f1.json"
# ' FLY ' is the same answer (lp_placement trims and lowercases).
fresh; fly_on ' FLY '
row 12 b1 queued 0 null
tick
[ "$(puts)" = 1 ] && [ "$(stubs)" = 0 ] && ok || bad "F1b ' FLY ' places the round on the pool: puts=$(puts) stubs=$(stubs)"

# ── F2: re-offered while the pool row is queued, then claimed: nothing ───────
for st in queued claimed; do
  fresh; fly_on
  row 12 b1 claimed 1 null 100
  qrow "$KEY" "$st"
  tick
  [ "$(rowf 12 .attempt)" = 2 ] && ok || bad "F2 ($st) the row was re-offered: attempt $(rowf 12 .attempt)"
  [ "$(puts)" = 0 ] && [ "$(stubs)" = 0 ] && [ "$(finishes)" = 0 ] && ok \
    || bad "F2 ($st) THE POINT: nothing runs, nothing posts: puts=$(puts) stubs=$(stubs) finishes=$(finishes)"
  [ "$(rowf 12 .status)" = claimed ] && ok || bad "F2 ($st) the fix row stays claimed"
  LOGF | grep -q "$KEY is $st on the Fly pool" && ok || bad "F2 ($st) no in-flight line: $(LOGF)"
done
# attempt 3 with the pool row queued: still nothing.
fresh; fly_on
row 12 b1 claimed 2 null 100
qrow "$KEY" queued
tick
[ "$(puts)" = 0 ] && [ "$(stubs)" = 0 ] && [ "$(finishes)" = 0 ] && ok || bad "F2 attempt 3: nothing runs"

# ── F3: re-offered while the pool row is done, then failed: one finish ───────
for st in done failed; do
  fresh; fly_on
  row 12 b1 claimed 1 null 100
  qrow "$KEY" "$st" "FIX_ROUND_SKIPPED the row is not claimed by b1"
  tick
  [ "$(puts)" = 0 ] && [ "$(stubs)" = 0 ] && ok || bad "F3 ($st) no put, no round: puts=$(puts) stubs=$(stubs)"
  [ "$(finishes)" = 1 ] && ok || bad "F3 ($st) THE POINT: one finish, got $(finishes)"
  RES=$(rowf 12 .result)
  [ "${RES%% *}" = setup-blocked ] && ok || bad "F3 ($st) the finish is setup-blocked: $RES"
  WHY=$(printf '%s' "${RES#setup-blocked }" | base64 -d 2>/dev/null)
  [[ "$WHY" == *"the Fly pool already ran this round as $KEY ($st: FIX_ROUND_SKIPPED"*"not run a second time"* ]] && ok || bad "F3 ($st) the reason names the key: $WHY"
done

# ── F4: a pool row of another fix id only: the put happens ───────────────────
fresh; fly_on
row 12 b1 queued 0 null
qrow "FXR-11-$CK8" done "FIX_ROUND_FINISHED done finish=ok"
tick
[ "$(puts)" = 1 ] && [ "$(stubs)" = 0 ] && [ "$(finishes)" = 0 ] && ok || bad "F4 another id's row is not this round's: puts=$(puts) stubs=$(stubs) finishes=$(finishes)"
[ "$(jq -r --arg k "$KEY" '[.[] | select(.ticket_key == $k)][0].status' "$T/queue.json")" = queued ] && ok || bad "F4 $KEY was put: $(cat "$T/queue.json")"

# ── F5: every other answer is the box, as before ─────────────────────────────
f5() { # f5 <case> — the fixture is already set; one round here, no queue POST
  row 12 b1 queued 0 null
  tick
  [ "$(stubs)" = 1 ] && ok || bad "F5 $1: THE POINT: one --fix-here on the box, got $(stubs): $(LOGF | tail -3)"
  [ "$(puts)" = 0 ] && ok || bad "F5 $1: no pool row put"
  [ "$(rowf 12 .result)" = done ] && ok || bad "F5 $1: the box finished the row done: $(rowf 12 .result)"
}
fresh; routing pool 0; f5 "(c) no row"
grep -q '^GET /api/queue' "$T/curl.log" && bad "F5 (c) no pool row is read with no placement row" || ok
fresh; routing pool 0; setting lane_placement.blocked-resolver-fix fly; f5 "(d) a lane row only"
fresh; routing pool 0; setting lane_placement.default fly; f5 "(e) the default row"
fresh; fly_on; routing pool 1; f5 "(f) halted routing"
LOGF | grep -q "lane_placement.blocked-resolver-fix.p=fly, but its routing is 'pool|1', not pool|0" && ok || bad "F5 (f) no routing line: $(LOGF)"
fresh; fly_on; routing fly1 0; f5 "(g) fly1 routing"
fresh; routing pool 0; setting lane_placement.blocked-resolver-fix.p box:box-project-6-os-1; f5 "(h) a box: row"
fresh; fly_on; : > "$T/settings.fail"; f5 "(i) settings unreadable"
fresh; routing pool 0; setting lane_placement.blocked-resolver-fix.project-3 fly; f5 "(j) another project's row"
fresh; routing pool 0; setting lane_placement.blocked-resolver-fix.hub_only "reads hub state"; f5 "(k) a hub_only row"

# ── F6: the queue read fails, then the put fails: nothing ────────────────────
fresh; fly_on
row 12 b1 queued 0 null
: > "$T/queue.fail"
tick
[ "$(stubs)" = 0 ] && [ "$(finishes)" = 0 ] && [ "$(puts)" = 0 ] && ok || bad "F6 a queue read outage runs nothing: stubs=$(stubs) finishes=$(finishes) puts=$(puts)"
[ "$(rowf 12 .status)" = claimed ] && ok || bad "F6 the row stays claimed"
[ "$(LOGF | grep -c "$KEY: its pool row is unreadable")" = 1 ] && ok || bad "F6 one unreadable line: $(LOGF)"
fresh; fly_on
row 12 b1 queued 0 null
: > "$T/queuepost.fail"
tick
[ "$(stubs)" = 0 ] && [ "$(finishes)" = 0 ] && ok || bad "F6 a failed put runs nothing: stubs=$(stubs) finishes=$(finishes)"
[ "$(rowf 12 .status)" = claimed ] && ok || bad "F6 the row stays claimed after a failed put"
[ "$(LOGF | grep -c "$KEY: the queue put failed")" = 1 ] && ok || bad "F6 one put-failed line: $(LOGF)"

# ── M1: the machine half, end to end ─────────────────────────────────────────
RF="$T/runner-fns.sh"
awk '/^_run_job\(\) \{/,/^\}/; /^run_fixround_job\(\) \{/,/^\}/; /^fixround_setup_result\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$RF"
machine() { # machine <case> <key> <meta> [warm_up rc] — queue_row_job_file, then _run_job
  local d="$T/m/$1"; scratch_rm "$d" 2>/dev/null; mkdir -p "$d"
  ( . "$H/bin/lib/queue-row-job.sh"; HARNESS="$H" queue_row_job_file p "$d/job.json" "$2" 12 0 "$3" >/dev/null ) || return 1
  ( unset BOX_NAME JOBS_URL HARNESS_SECRET JOBS_BOX
    export PATH="$FAKE:$PATH" LANE_REGISTRY="$T/lanes.json" JOBS_SETTINGS_CACHE_S=0 LANE_GATE_CACHE_S=0 GH_TOKEN=tok-fixture-inherited
    JOB="$d/job.json" RESULT_FILE="$d/RESULT" HARNESS="$H" PROJECT=p REPO="$T/repos/p" ENVDIR="$H/env" SINK="$d/sink" WRC="${4:-0}"
    log() { :; }; beat() { printf 'beat %s\n' "$*" >> "$SINK"; }; warm_up() { printf 'warm_up\n' >> "$SINK"; return "$WRC"; }
    load_env() { :; }; model_routes_warm() { :; }; start_heartbeat() { :; }; stop_heartbeat() { :; }
    slot_preflight() { printf 'BUILD PATH\n' >> "$SINK"; return 1; }
    # shellcheck source=/dev/null
    . "$RF"
    cd "$T" && _run_job )
  MD="$d"
}
fresh; fly_on
row 12 b1 queued 0 "$(jq -Rn --arg r "$R1" '$r')"
tick
M=$(grep '^POST /api/queue ' "$T/curl.log" | tail -1 | sed 's/^POST \/api\/queue //' | jq -r '.meta')
printf 'builder-p\n' > "$T/boxname"
: > "$T/curl.log"
machine m1 "$KEY" "$M"
[ "$(jq -r '.fixround | "\(.kind) \(.id) \(.box) \(.project) \(.cap_key) \(.attempt)"' "$MD/job.json" 2>/dev/null)" = "fixround 12 b1 p ck 1" ] \
  && ok || bad "M1 job.json carries the fixround object: $(cat "$MD/job.json" 2>/dev/null)"
[ "$(head -1 "$MD/RESULT" 2>/dev/null)" = "FIX_ROUND_FINISHED done finish=ok" ] && ok || bad "M1 RESULT: $(cat "$MD/RESULT" 2>/dev/null) log: $(LOGF | tail -3)"
[ "$(stubs)" = 1 ] && ok || bad "M1 THE POINT: one --fix-here on the machine, got $(stubs)"
if [ -f "$T/stub.1.argv" ]; then
  GOT=$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read().split("\0")[:-1]))' "$T/stub.1.argv")
  [ "$(jq -c . <<<"$GOT")" = "$(jq -c '["--fix-here"] + .' <<<"$ARGS")" ] && ok || bad "M1 the round's argv: $GOT"
  [ "$(cat "$T/stub.1.stdin")" = "$R1" ] && ok || bad "M1 the round's stdin: $(cat "$T/stub.1.stdin")"
  [ "$(cat "$T/stub.1.tok")" = "tok-fixture-o/r" ] && ok || bad "M1 the round's GH_TOKEN is the minted one"
fi
[ "$(finishes)" = 1 ] && ok || bad "M1 one finish, got $(finishes)"
FIN=$(grep '^POST /api/fix-rounds/finish ' "$T/curl.log" | head -1 | sed 's/^POST \/api\/fix-rounds\/finish //')
[ "$(jq -r '"\(.id) \(.box) \(.result)"' <<<"$FIN" 2>/dev/null)" = "12 b1 done" ] && ok || bad "M1 the finish names the claiming box b1 and done: $FIN"
[ "$(jq -r '.record_out | fromjson | .attempts[0].detail' <<<"$FIN" 2>/dev/null)" = "round ran" ] && ok || bad "M1 the finish carries FIX_RECORD: $FIN"
[ "$(rowf 12 .status)" = done ] && ok || bad "M1 the fix row is done"
grep -q 'BUILD PATH' "$MD/sink" 2>/dev/null && bad "M1 the job never reaches the build path" || ok
grep -q '"stage":"fixround_done"' "$MD/sink" 2>/dev/null && ok || bad "M1 the runner beats fixround_done: $(cat "$MD/sink" 2>/dev/null)"
# The minted token is empty on the machine: the inherited one stays.
fresh; fly_on; row 12 b1 queued 0 null; tick
M=$(grep '^POST /api/queue ' "$T/curl.log" | tail -1 | sed 's/^POST \/api\/queue //' | jq -r '.meta')
: > "$T/gh-token.empty"
machine m1b "$KEY" "$M"
[ "$(cat "$T/stub.1.tok" 2>/dev/null)" = "tok-fixture-inherited" ] && ok || bad "M1b an empty mint keeps the machine's GH_TOKEN"

# ── M2: --run-pool on a row that is not claimed by the box: skipped ──────────
m2() { # m2 <case> — the rows are set
  : > "$T/curl.log"; rm -f "$T/stub.n"
  runpool 12 b1 p ck
  [[ "$(head -1 "$T/rp.out")" == "FIX_ROUND_SKIPPED "* ]] && ok || bad "M2 $1: FIX_ROUND_SKIPPED, got: $(cat "$T/rp.out")"
  [ "$(stubs)" = 0 ] && [ "$(finishes)" = 0 ] && ok || bad "M2 $1: THE POINT: nothing runs, nothing posts: stubs=$(stubs) finishes=$(finishes)"
}
fresh; row 12 b1 done 1 null; m2 "done"
fresh; row 12 b1 adopted 1 null; m2 "adopted"
fresh; row 12 b1 queued 1 null; m2 "queued"
fresh; row 12 b2 claimed 1 null 1; m2 "claimed by b2"
fresh; row 13 b1 claimed 1 null 1; m2 "another id"
fresh; row 12 b1 claimed 1 null 1
: > "$T/curl.log"; runpool 12 b1 p ck
[ "$(head -1 "$T/rp.out")" = "FIX_ROUND_FINISHED done finish=ok" ] && [ "$(stubs)" = 1 ] && ok || bad "M2 the claimed row runs: $(cat "$T/rp.out") stubs=$(stubs)"

# ── M3: the round dies rc 137 on the machine ─────────────────────────────────
fresh; row 12 b1 claimed 1 null 1
echo die137 > "$T/stub.mode"
runpool 12 b1 p ck
[ "$(head -1 "$T/rp.out")" = "FIX_ROUND_FINISHED setup-blocked finish=ok" ] && ok || bad "M3 RESULT: $(cat "$T/rp.out")"
[ "$(finishes)" = 1 ] && ok || bad "M3 one finish, got $(finishes)"
WHY=$(rowf 12 .result | sed 's/^setup-blocked //' | base64 -d 2>/dev/null)
[[ "$WHY" == *"gave no FIX_RESULT (rc=137)"* ]] && ok || bad "M3 the reason: $WHY"

# ── M4: warm-up fails: one setup-blocked finish ──────────────────────────────
fresh; fly_on; row 12 b1 queued 0 null; tick
M=$(grep '^POST /api/queue ' "$T/curl.log" | tail -1 | sed 's/^POST \/api\/queue //' | jq -r '.meta')
: > "$T/curl.log"
machine m4 "$KEY" "$M" 1
[[ "$(head -1 "$MD/RESULT" 2>/dev/null)" == "FIX_ROUND_SETUP_FAILED "* ]] && ok || bad "M4 RESULT: $(cat "$MD/RESULT" 2>/dev/null)"
[ "$(stubs)" = 0 ] && ok || bad "M4 no round after a failed warm-up"
[ "$(finishes)" = 1 ] && ok || bad "M4 THE POINT: one finish, got $(finishes)"
WHY=$(rowf 12 .result | sed 's/^setup-blocked //' | base64 -d 2>/dev/null)
[[ "$(rowf 12 .result)" == "setup-blocked "* && "$WHY" == *"warm-up failed"* ]] && ok || bad "M4 the finish is setup-blocked with the reason: $(rowf 12 .result) / $WHY"
runpool 12 b1 p ck --blocked "warm-up failed"
[[ "$(head -1 "$T/rp.out")" == "FIX_ROUND_SKIPPED "* ]] && [ "$(finishes)" = 1 ] && ok || bad "M4 a second --blocked on a done row posts nothing: $(cat "$T/rp.out") finishes=$(finishes)"

# ── Q1-Q3: the row mapping refuses what it cannot run ────────────────────────
qrj() { # qrj <dest> <key> <meta> -> rc
  ( queue_done() { printf '%s\n' "$*" >> "$T/qdone"; }
    . "$DIR/bin/lib/queue-row-job.sh"
    HARNESS="$H" queue_row_job_file p "$1" "$2" 12 0 "$3" >/dev/null )
}
GOOD=$(jq -nc --arg ck ck '{kind:"fixround", id:12, box:"b1", project:"p", cap_key:$ck, attempt:1, by:"fix-round-claim"}')
mkdir -p "$T/q"
qrj "$T/q/ok.json" "$KEY" "$GOOD"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.fixround.kind' "$T/q/ok.json" 2>/dev/null)" = fixround ] && ok || bad "Q0 a good FXR row is a fixround job: rc $rc"
qref() { # qref <case> <key> <meta> <field>
  local rc; rm -f "$T/qdone" "$T/q/r.json" "$T/alerts"
  qrj "$T/q/r.json" "$2" "$3"; rc=$?
  [ "$rc" = 3 ] && [ ! -e "$T/q/r.json" ] && grep -q "failed fixround meta rejected ($4)" "$T/qdone" 2>/dev/null && ok \
    || bad "$1 refused (rc 3, no file, row failed naming $4): rc $rc $(cat "$T/qdone" 2>/dev/null)"
  [ "$(grep -c "fix-round meta is unusable" "$T/alerts" 2>/dev/null)" = 1 ] && ok || bad "$1 one alert: $(cat "$T/alerts" 2>/dev/null)"
}
qref "Q1 fixround meta on an LR key" "LR-12-abcdef01" "$GOOD" key
qref "Q2 leadreview meta on an FXR key" "$KEY" '{"kind":"leadreview"}' kind
qref "Q2 build meta on an FXR key" "$KEY" '{"hotfix":true}' kind
qref "Q3 a key whose ck8 is not the cap_key's" "FXR-12-00000000" "$GOOD" key
qref "Q3 a key whose id is not the meta's" "FXR-11-$CK8" "$GOOD" key
qref "Q3 a project that is not the row's" "$KEY" "$(jq -c '.project = "q"' <<<"$GOOD")" project
qref "Q3 a box with a slash" "$KEY" "$(jq -c '.box = "b/1"' <<<"$GOOD")" box
qref "Q3 an id that is not a number" "$KEY" "$(jq -c '.id = "12a"' <<<"$GOOD")" id

# ── P1: the pool gates read an FXR row as they read an LR row ────────────────
FX1="FXR-12-abcdef01"
bash "$DIR/bin/result-prefix-ok.sh" "FIX_ROUND_FINISHED done finish=ok" && ok || bad "P1 FIX_ROUND_FINISHED is a RESULT"
bash "$DIR/bin/result-prefix-ok.sh" "FIX_ROUND_SETUP_FAILED x" && ok || bad "P1 FIX_ROUND_SETUP_FAILED is a RESULT"
bash "$DIR/bin/result-prefix-ok.sh" "FIX_ROUNDX" && bad "P1 FIX_ROUNDX is not a RESULT" || ok
( . "$DIR/bin/lib/docker-pool-host.sh" >/dev/null 2>&1; dph_key_ok "$FX1" ) && bad "P1 dph_key_ok refuses FXR-*" || ok
( . "$DIR/bin/lib/docker-pool-host.sh" >/dev/null 2>&1; dph_key_ok TK-64 ) && ok || bad "P1 dph_key_ok keeps TK-64 a ticket key"
gate_actor() { ( say() { printf 'say %s\n' "$*"; }; HARNESS="$T/none"; . "$DIR/bin/lib/pool-actor-gate.sh"; pool_actor_gate "$T/q/ok.json" "$1" 12 ); }
[ -z "$(gate_actor "$FX1")" ] && ok || bad "P1 pool_actor_gate passes FXR-* with no check: $(gate_actor "$FX1")"
[ -n "$(gate_actor TK-64)" ] && ok || bad "P1 pool_actor_gate checks TK-64"
budget() { ( pool_spawn_decision() { return 1; }; pdc_spawn() { :; }; . "$DIR/bin/lib/pool-decide.sh"; pdc_start 0 "$T/q/ok.json" "$1" 12 0 0 ""; echo "$PDC_BUDGET_N" ); }
[ "$(budget "$FX1")" = 0 ] && ok || bad "P1 an FXR row spends no tick budget: $(budget "$FX1")"
[ "$(budget TK-64)" = 1 ] && ok || bad "P1 TK-64 spends tick budget: $(budget TK-64)"
orphan() { ( . "$DIR/bin/lib/pool-orphan-rows.sh"; pool_orphan_row_verdict claimed fly hub hub "$1" 99999 60 0 0 0 absent ); }
[ "$(orphan "$FX1")" = "$(printf 'keep\tfixround')" ] && ok || bad "P1 an FXR row is kept by the orphan sweep: $(orphan "$FX1")"
[ "$(orphan TK-64)" = release ] && ok || bad "P1 TK-64 is released by the orphan sweep: $(orphan TK-64)"
due() { ( . "$DIR/bin/lib/pool-stall.sh"; pool_inflight_hold_due 12 "$1" ok 1 k1 k0 0 5 ); }
[ "$(due "$FX1")" = "$(printf 'skip\tfixround')" ] && ok || bad "P1 an FXR row is no issue to read: $(due "$FX1")"
[ "$(due TK-64)" = read ] && ok || bad "P1 TK-64 is read: $(due TK-64)"
step() { ( SINK="$T/stepsink"; rm -f "$SINK"; MF="$T/q/ok.json" HARNESS="$H" TICKET=12 KEY="$1"
  pool_hold_check() { echo check >> "$SINK"; return 1; }; pool_hold_list_prime() { echo prime >> "$SINK"; }
  . "$DIR/bin/lib/pool-stall.sh"; pool_inflight_hold_step; [ -s "$SINK" ] && echo asked || echo quiet ); }
[ "$(step "$FX1")" = quiet ] && ok || bad "P1 pool_inflight_hold_step asks nothing of an FXR row"
[ "$(step TK-64)" = asked ] && ok || bad "P1 pool_inflight_hold_step asks about TK-64"
hold() { ( SINK="$T/holdsink"; rm -f "$SINK"
  . "$DIR/bin/lib/ticket-ownership.sh" 2>/dev/null
  to_issue_repo() { echo o/r; }; to_hold_verdict() { echo "verdict $*" >> "$SINK"; return 1; }
  to_build_hold p "$2" "$1"; [ -s "$SINK" ] && echo asked || echo quiet ); }
[ "$(hold "$FX1" 12)" = quiet ] && ok || bad "P1 to_build_hold reads no issue 12 for an FXR row"
[ "$(hold TK-64 "")" = asked ] && ok || bad "P1 to_build_hold reads TK-64's issue"
admit() { ( DM_MODE=hotfix-only; . "$DIR/bin/lib/dispatch-mode.sh" 2>/dev/null
  dm_allow_has() { return 1; }; dm_job_admit "$1" ) && echo yes || echo no; }
[ "$(admit "$T/q/ok.json")" = yes ] && ok || bad "P1 dm_job_admit admits a fixround job in hotfix-only mode"
jq -nc '{ticket_id:"64",key:"TK-64",attempt:0}' > "$T/q/fr64.json"
[ "$(admit "$T/q/fr64.json")" = no ] && ok || bad "P1 dm_job_admit holds TK-64 in hotfix-only mode"
awk '/^pool_spawn_decision\(\) \{/,/^\}/' "$DIR/bin/fly-pool.sh" > "$T/psd.sh"
P1OUT=$( SINK="$T/p1sink"; export SINK
  say() { printf '%s\n' "$*"; }
  for f in pool_tick_budget_spent psr_marker_has psr_marker_put psr_marker_clear hold_check pool_hold_check pool_spawn_cap_check; do
    eval "$f() { printf '%s\n' $f >> \"\$SINK\"; return 1; }"
  done
  _POOL_ROWS_DECIDED=1; . "$T/psd.sh"; pool_spawn_decision "$T/q/ok.json" "$FX1" 12; echo "rc=$?" )
case "$P1OUT" in *"fix-round row"*"rc=0"*) ok ;; *) bad "P1 an FXR row passes the ticket spawn gates: $P1OUT" ;; esac
[ -s "$T/p1sink" ] && bad "P1 no ticket gate is asked of an FXR row: $(tr '\n' ' ' < "$T/p1sink")" || ok

# ── R1-R4: bin/fly-pool.sh's reap and death arms on an FXR row ───────────────
PH="$T/p"
mkdir -p "$PH/bin/lib" "$PH/logs" "$PH/flags" "$PH/locks" "$PH/env" "$PH/builds" "$PH/state/fly" \
         "$PH/state/fly-pool/tproj" "$PH/state/remote-results/tproj" "$PH/state/build-queue/tproj" "$T/pbin" "$T/relay"
cat > "$PH/bin/jobs-client.sh" <<EOF
queue_done() { printf 'done %s\n' "\$*" >> "$T/psink"; return 0; }
queue_put() { printf 'put %s\n' "\$*" >> "$T/psink"; echo queued; return 0; }
queue_status() { echo claimed; return 0; }
_jobs_req() { printf 'req %s\n' "\$*" >> "$T/psink"; cat "$T/prow.json" 2>/dev/null; }
EOF
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$PH/bin/"
scratch_install_closure bin/fly-pool.sh "$PH" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
scratch_install_closure bin/alert-line.sh "$PH" >/dev/null || { echo "closure install of bin/alert-line.sh failed"; exit 1; }
printf 'HARNESS_SECRET=fixture-secret\n' > "$PH/env/global.env"
printf 'FLY_API_TOKEN_TPROJ=tok-fixture-1\n' > "$PH/env/fly.env"
printf 'tproj example-org/mk - - 0 local\n' > "$PH/fleet.conf"
printf '3\n' > "$PH/flags/fly-pool-tproj"; printf 'pool-tproj\n' > "$PH/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$PH/state/fly/tproj.json"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/pbeat"\nexit 0\n' "$T" > "$PH/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/pbin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/pbin/flock"; printf '#!/bin/bash\nexit 0\n' > "$T/pbin/sleep"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/pgh"\nexit 1\n' "$T" > "$T/pbin/gh"
cat > "$T/pbin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/pfly"
case "\$*" in
  *"machine status"*) echo "State: \$(cat "$T/pmstate" 2>/dev/null || echo started)"; exit 0 ;;
  *"ssh console"*"head"*"RESULT"*) head -1 "$T/relay/RESULT" 2>/dev/null; exit 0 ;;
  *"ssh console"*"base64"*"RESULT"*) [ -s "$T/relay/RESULT" ] && base64 -w0 "$T/relay/RESULT"; exit 0 ;;
  *"ssh console"*) exit 0 ;;
  *"machines list"*) echo '[]' ;;
esac
exit 0
FLY
chmod +x "$PH/bin/beat.sh" "$PH/bin/result-prefix-ok.sh" "$T/pbin"/*
jq -nc --arg k "$FX1" '{queue:[{project:"tproj",ticket_key:$k,ticket_id:"12",status:"claimed",target:"fly",attempt:0,meta:"{}"}]}' > "$T/prow.json"
preap() { # preap <key> <result-file-or-empty> [machine-state]
  local p
  for p in "$PH/builds"/* "$PH/state/build-queue/tproj"/* "$PH/logs/ALERTS.log" \
           "$T/psink" "$T/pbeat" "$T/pgh" "$T/pfly" "$T/relay/RESULT" "$T/pmstate"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  [ -n "$2" ] && cp "$2" "$T/relay/RESULT"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$T/pmstate"
  : > "$PH/logs/fly-pool.log"
  jq -nc --arg k "$1" '{machine:"m1",key:$k,ticket_id:"12",attempt:0}' > "$PH/state/fly-pool/tproj/m1.json"
  ( export PATH="$T/pbin:$PATH" HARNESS="$PH" FLEET_CONF="$PH/fleet.conf" FLY_API_TOKEN_TPROJ=tok-fixture-1 \
           FLY_BIN_DIR="$T/pbin" POOL_SPAWN=0 GH_TOKEN="" POOL_PR_VERIFY_SLEEP=0
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
}
alerts() { local n; n=$(grep -c "$1" "$PH/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
printf 'FIX_ROUND_FINISHED done finish=ok\n' > "$T/r1"
preap "$FX1" "$T/r1"
grep -q "^done tproj $FX1 done FIX_ROUND_FINISHED done finish=ok" "$T/psink" 2>/dev/null && ok || bad "R1 THE POINT: the row is closed done: $(cat "$T/psink" 2>/dev/null) $(tail -5 "$PH/logs/fly-pool.log")"
ls "$PH/state/remote-results/tproj/"* >/dev/null 2>&1 && bad "R1 a fix-round RESULT is never a remote result" || ok
grep -E 'pulls|issues|comments' "$T/pgh" 2>/dev/null && bad "R1 no PR read and no board comment: $(cat "$T/pgh")" || ok
grep -q "^put tproj $FX1" "$T/psink" 2>/dev/null && bad "R1 no requeue" || ok
grep -q "pool fix round reaped for $FX1" "$PH/logs/fly-pool.log" && ok || bad "R1 the reap line: $(tail -5 "$PH/logs/fly-pool.log")"
printf 'FIX_ROUND_SKIPPED the row is not claimed by b1\n' > "$T/r1s"
preap "$FX1" "$T/r1s"
grep -q "^done tproj $FX1 done FIX_ROUND_SKIPPED" "$T/psink" 2>/dev/null && ok || bad "R1 SKIPPED closes the row done: $(cat "$T/psink" 2>/dev/null)"
printf 'FIX_ROUND_SETUP_FAILED warm-up failed finish=ok\n' > "$T/r2"
preap "$FX1" "$T/r2"
grep -q "^done tproj $FX1 failed FIX_ROUND_SETUP_FAILED" "$T/psink" 2>/dev/null && ok || bad "R2 SETUP_FAILED closes the row failed: $(cat "$T/psink" 2>/dev/null)"
[ "$(alerts "$FX1")" = 0 ] && ok || bad "R2 a setup failure the machine reported is no alert"
printf 'PR_CREATED https://github.com/example-org/mk/pull/55\n' > "$T/r3"
preap "$FX1" "$T/r3"
grep -q "^done tproj $FX1 failed" "$T/psink" 2>/dev/null && ok || bad "R3 a build word on an FXR key fails the row: $(cat "$T/psink" 2>/dev/null)"
ls "$PH/state/remote-results/tproj/"* >/dev/null 2>&1 && bad "R3 a build word on an FXR key is never read as a build" || ok
[ "$(alerts "$FX1")" = 1 ] && ok || bad "R3 one alert for the mismatch: $(cat "$PH/logs/ALERTS.log" 2>/dev/null)"
jq -nc '{queue:[{project:"tproj",ticket_key:"TP-77",ticket_id:"77",status:"claimed",target:"fly",attempt:0,meta:"{}"}]}' > "$T/prow.json"
preap TP-77 "$T/r1"
grep -q "^done tproj TP-77 failed" "$T/psink" 2>/dev/null && ok || bad "R3 a fix-round word on a ticket key fails the row: $(cat "$T/psink" 2>/dev/null)"
[ "$(alerts TP-77)" = 1 ] && ok || bad "R3 one alert for a fix-round word on a ticket key: $(cat "$PH/logs/ALERTS.log" 2>/dev/null)"
jq -nc --arg k "$FX1" '{queue:[{project:"tproj",ticket_key:$k,ticket_id:"12",status:"claimed",target:"fly",attempt:0,meta:"{}"}]}' > "$T/prow.json"
preap "$FX1" "" stopped
grep -q "^done tproj $FX1 failed" "$T/psink" 2>/dev/null && ok || bad "R4 a dead FXR machine fails the row: $(cat "$T/psink" 2>/dev/null)"
grep -q "^put tproj $FX1" "$T/psink" 2>/dev/null && bad "R4 a dead FXR row is never requeued" || ok
grep -qE "^done tproj $FX1 failed .*(died|deferred) [0-9]+ times" "$T/psink" 2>/dev/null && bad "R4 the reason is no blocked-resolver trigger" || ok
[ "$(alerts "$FX1")" = 1 ] && ok || bad "R4 one alert for a dead FXR machine: $(cat "$PH/logs/ALERTS.log" 2>/dev/null)"
printf 'BUILD_DEFERRED slot held\n' > "$T/r4"
preap "$FX1" "$T/r4"
grep -q "^done tproj $FX1 failed" "$T/psink" 2>/dev/null && ok || bad "R4 BUILD_DEFERRED on an FXR row fails it: $(cat "$T/psink" 2>/dev/null)"
grep -q "^put tproj $FX1" "$T/psink" 2>/dev/null && bad "R4 BUILD_DEFERRED on an FXR row is never requeued" || ok
[ "$(alerts "$FX1")" = 1 ] && ok || bad "R4 one alert for an FXR BUILD_DEFERRED: $(cat "$PH/logs/ALERTS.log" 2>/dev/null)"

# ── S1: the composed jobs schema seeds project-6-os, and only it ────────────
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || { echo "FAIL: schema render"; exit 1; }
SEED=$(grep -c "('lane_placement.blocked-resolver-fix.project-6-os','fly'," "$DIR/worker/jobs/schema.sql")
[ "$SEED" = 1 ] && ok || bad "S1 one seed row lane_placement.blocked-resolver-fix.project-6-os=fly, got $SEED"
grep -q "INSERT OR IGNORE INTO settings.*" "$DIR/worker/jobs/schema.d/"*-bh-8065-blocked-resolver-fix-project-6-fly.sql && ok || bad "S1 the seed is INSERT OR IGNORE (an operator value stays)"
ALL=$(grep -c "'lane_placement.blocked-resolver-fix" "$DIR/worker/jobs/schema.sql")
[ "$ALL" = 1 ] && ok || bad "S1 no lane row and no other project row is seeded: $ALL rows"

echo "fix-round-fly-placement.bh-8065: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
