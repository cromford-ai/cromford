#!/bin/bash
# tests/fix-round-fly-retry.bh-10115-test.sh — BH-10115: a fix round the box
# re-offers after a timeout (BH-9906) is put on the Fly pool as
# FXR-<id>-<ck8>-r<n>. The hub mapping (bin/lib/queue-row-job.sh) refused that
# key, so the retry never ran. Row 2701, 2026-11-25: FXR-2701-640d5fc8-r1 was
# closed `fixround meta rejected (key)` and the box's stale re-offer finished
# the fix row setup-blocked with "no finish landed".
#
# WHAT IS DRIVEN. The real bin/fix-round-claim.sh (tick), bin/lib/fix-round-pool.sh,
# the jobs client, bin/lib/fix-round-queue.sh and bin/lib/queue-row-job.sh in a
# scratch box harness (scratch_install_closure), the real _run_job /
# run_fixround_job of fly/builder-runner.sh and the real BH-8896 fragment.
# Stubs: curl (a fake jobs worker), bin/blocked-resolver.sh (counts each
# --fix-here), bin/box-name.sh, bin/fleet-conf.sh, bin/gh-token.sh,
# bin/alert-line.sh. 0 network calls.
#
#   K1  the mapping accepts FXR-12-<ck8>, -r1 and -r12: rc 0, job.json fixround id 12.
#   K2  the mapping refuses -r0, -r, -r01, -R1, -r1x, -r1-r2, <ck8>r1, -x1,
#       another id, another cap_key and a bad charset: rc 3, no file, (key).
#   F1  a refused fixround meta posts ONE setup-blocked finish as the meta's
#       box; the reason names the key; the fix row is done; one alert; the
#       next claim tick posts nothing more.
#   F2  kind mismatch, id 12a, box b/1, a non-object meta: 0 finishes, rc 3.
#   F3  no jobs client in the shell: 0 requests, rc 3, one alert.
#   F4  the finish POST answers 500: rc 3, one alert, the row stays claimed,
#       and the next stale claim tick finishes it setup-blocked once.
#   E1  a fix row with one timeout_requeues entry: ONE pool row
#       FXR-12-<ck8>-r1, the mapping writes job.json, ONE --fix-here, ONE
#       finish, RESULT FIX_ROUND_FINISHED done finish=ok.
#   A1  frt_adopt_gate reads the -r1 pool row for a retried round, and the
#       unsuffixed row for a first round; frt_refund names the -r1 key.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fix-round-fly-retry.bh-10115-test.sh
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
    if os.path.exists(f"{T}/finish.fail"): out(500, {"error": "fixture outage"})
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

CK8R1="FXR-12-$CK8-r1"
TRQ='{"project":"p","attempts":[{"detail":"r1"}],"timeout_requeues":[{"head":"h1","kind":"verify-timeout","at":"2026-11-25T14:26:00Z","rc":124,"attempt":1,"last":"x"}]}'
GOOD=$(jq -nc --arg ck ck '{kind:"fixround", id:12, box:"b1", project:"p", cap_key:$ck, attempt:1, by:"fix-round-claim"}')
alerts() { local n; n=$(grep -c "fix-round meta is unusable" "$T/alerts" 2>/dev/null); echo "${n:-0}"; }

# qrj <dest> <key> <meta> — the mapping with NO jobs client (the BH-8065 Q shape), rc out
qrj() {
  ( export PATH="$FAKE:$PATH"
    queue_done() { printf '%s\n' "$*" >> "$T/qdone"; }
    . "$H/bin/lib/queue-row-job.sh"
    HARNESS="$H" queue_row_job_file p "$1" "$2" 12 0 "$3" > "$T/qrj.out" )
}
# qrjc <dest> <key> <meta> — the mapping as the hub runs it: the jobs client loaded
qrjc() {
  ( unset BOX_NAME JOBS_URL HARNESS_SECRET JOBS_BOX
    export HARNESS="$H" PATH="$FAKE:$PATH" JOBS_SETTINGS_CACHE_S=0
    . "$H/bin/jobs-client.sh" >/dev/null 2>&1
    . "$H/bin/lib/queue-row-job.sh"
    queue_row_job_file p "$1" "$2" 12 0 "$3" > "$T/qrj.out" )
}

# ── K1: the mapping accepts the retry suffix ─────────────────────────────────
fresh; mkdir -p "$T/k"
for k in "$KEY" "$KEY-r1" "$KEY-r12"; do
  rm -f "$T/k/j.json" "$T/qdone"
  qrj "$T/k/j.json" "$k" "$GOOD"; rc=$?
  [ "$rc" = 0 ] && [ "$(jq -r '"\(.fixround.kind) \(.fixround.id)"' "$T/k/j.json" 2>/dev/null)" = "fixround 12" ] \
    && ok || bad "K1 $k: THE POINT: accepted as fix round 12: rc $rc $(cat "$T/qrj.out" "$T/qdone" 2>/dev/null)"
  [ "$(jq -r '.fixround | has("key")' "$T/k/j.json" 2>/dev/null)" = false ] && ok || bad "K1 $k: the fixround object does not change"
done

# ── K2: every other form is still refused ────────────────────────────────────
for k in "$KEY-r0" "$KEY-r" "$KEY-r01" "$KEY-R1" "$KEY-r1x" "$KEY-r1-r2" "${KEY}r1" "$KEY-x1" \
         "FXR-11-$CK8-r1" "FXR-12-00000000-r1" "$KEY-r1;rm" "$KEY-r 1" "$KEY-"; do
  rm -f "$T/k/r.json" "$T/qdone" "$T/alerts"
  qrj "$T/k/r.json" "$k" "$GOOD"; rc=$?
  [ "$rc" = 3 ] && [ ! -e "$T/k/r.json" ] && grep -qF "failed fixround meta rejected (key)" "$T/qdone" 2>/dev/null \
    && ok || bad "K2 '$k': refused (rc 3, no file, key): rc $rc $(cat "$T/qdone" 2>/dev/null)"
  [ "$(alerts)" = 1 ] && ok || bad "K2 '$k': one alert, got $(alerts)"
done

# ── F1: a refused fixround meta posts ONE finish with the reason ─────────────
fresh; fly_on
row 12 b1 claimed 1 null 1
qrow "FXR-12-00000000-r1" claimed
qrjc "$T/f1.json" "FXR-12-00000000-r1" "$GOOD"; rc=$?
[ "$rc" = 3 ] && [ ! -e "$T/f1.json" ] && ok || bad "F1 rc 3 and no file: rc $rc"
[ "$(finishes)" = 1 ] && ok || bad "F1 THE POINT: one finish, got $(finishes): $(cat "$T/curl.log")"
FIN=$(grep '^POST /api/fix-rounds/finish ' "$T/curl.log" | head -1 | sed 's/^POST \/api\/fix-rounds\/finish //')
[ "$(jq -r '"\(.id) \(.box)"' <<<"$FIN" 2>/dev/null)" = "12 b1" ] && ok || bad "F1 the finish names id 12 and box b1: $FIN"
RES=$(jq -r '.result' <<<"$FIN" 2>/dev/null)
WHY=$(printf '%s' "${RES#setup-blocked }" | base64 -d 2>/dev/null)
[ "${RES%% *}" = setup-blocked ] && [[ "$WHY" == *"FXR-12-00000000-r1"*"fixround meta rejected (key)"* ]] \
  && ok || bad "F1 the result is setup-blocked and the reason names the key: $RES / $WHY"
[ "$(rowf 12 .status)" = done ] && [ "$(rowf 12 .result)" = "$RES" ] && ok || bad "F1 the fix row is done: $(rowf 12 '[.status,.result]|@csv')"
[ "$(jq -r '.[] | select(.ticket_key == "FXR-12-00000000-r1") | "\(.status) \(.reason)"' "$T/queue.json")" = "failed fixround meta rejected (key)" ] \
  && ok || bad "F1 the pool row is closed failed: $(cat "$T/queue.json")"
[ "$(alerts)" = 1 ] && ok || bad "F1 one alert, got $(alerts)"
grep -q 'finish posted' "$T/qrj.out" && ok || bad "F1 the say line says the finish was posted: $(cat "$T/qrj.out")"
: > "$T/curl.log"
tick
[ "$(finishes)" = 0 ] && [ "$(puts)" = 0 ] && [ "$(stubs)" = 0 ] && ok \
  || bad "F1 the next claim tick does nothing more: finishes=$(finishes) puts=$(puts) stubs=$(stubs)"
# A project refusal posts its finish too.
fresh
row 12 b1 claimed 1 null 1
qrjc "$T/f1b.json" "$KEY" "$(jq -c '.project = "q"' <<<"$GOOD")"; rc=$?
[ "$rc" = 3 ] && [ "$(finishes)" = 1 ] && [ "$(rowf 12 .status)" = done ] && ok || bad "F1b a project refusal posts one finish: rc $rc finishes=$(finishes)"
# A nested meta collapses the same way.
fresh
row 12 b1 claimed 1 null 1
qrjc "$T/f1c.json" "FXR-11-$CK8" "$(jq -c '{kind:"fixround", fixround:.}' <<<"$GOOD")"; rc=$?
[ "$rc" = 3 ] && [ "$(finishes)" = 1 ] && ok || bad "F1c a nested meta posts one finish: rc $rc finishes=$(finishes)"

# ── F2: no finish when the meta names no usable id/box, or is not fixround ───
f2() { # f2 <case> <key> <meta>
  fresh; row 12 b1 claimed 1 null 1; rm -f "$T/alerts"
  qrjc "$T/f2.json" "$2" "$3"; local rc=$?
  [ "$rc" = 3 ] && [ "$(finishes)" = 0 ] && ok || bad "F2 $1: rc 3 and no finish: rc $rc finishes=$(finishes)"
  [ "$(rowf 12 .status)" = claimed ] && ok || bad "F2 $1: the row stays claimed"
  [ "$(alerts)" = 1 ] && ok || bad "F2 $1: one alert, got $(alerts)"
}
f2 "kind mismatch" "$KEY" '{"hotfix":true}'
f2 "leadreview meta" "$KEY" "$(jq -c '.kind = "leadreview"' <<<"$GOOD")"
f2 "id 12a" "$KEY" "$(jq -c '.id = "12a"' <<<"$GOOD")"
f2 "box b/1" "$KEY" "$(jq -c '.box = "b/1"' <<<"$GOOD")"
f2 "a non-object meta" "$KEY" '[1,2]'

# ── F3: no jobs client: no request, rc 3 kept ────────────────────────────────
fresh; row 12 b1 claimed 1 null 1; rm -f "$T/alerts"
qrj "$T/f3.json" "FXR-12-00000000" "$GOOD"; rc=$?
[ "$rc" = 3 ] && ok || bad "F3 rc 3: rc $rc"
[ ! -s "$T/curl.log" ] && ok || bad "F3 no request: $(cat "$T/curl.log")"
[ "$(alerts)" = 1 ] && ok || bad "F3 one alert, got $(alerts)"
grep -q 'finish not posted' "$T/qrj.out" && ok || bad "F3 the say line says no finish: $(cat "$T/qrj.out")"

# ── F4: the finish fails: the stale re-offer finishes the row once ───────────
fresh; fly_on
row 12 b1 claimed 1 null 120
qrow "$KEY" claimed
: > "$T/finish.fail"
qrjc "$T/f4.json" "$KEY" "$(jq -c '.project = "q"' <<<"$GOOD")"; rc=$?
[ "$rc" = 3 ] && [ "$(alerts)" = 1 ] && ok || bad "F4 rc 3 and one alert: rc $rc alerts=$(alerts)"
[ "$(finishes)" = 1 ] && [ "$(rowf 12 .status)" = claimed ] && ok || bad "F4 one failed finish, the row stays claimed: finishes=$(finishes) $(rowf 12 .status)"
grep -q 'finish not posted' "$T/qrj.out" && ok || bad "F4 the say line says the finish was not posted: $(cat "$T/qrj.out")"
rm -f "$T/finish.fail"; : > "$T/curl.log"
tick
[ "$(finishes)" = 1 ] && [ "$(puts)" = 0 ] && [ "$(stubs)" = 0 ] && ok || bad "F4 the stale re-offer posts ONE finish, no round: finishes=$(finishes) puts=$(puts) stubs=$(stubs)"
[ "$(rowf 12 .result | cut -d' ' -f1)" = setup-blocked ] && ok || bad "F4 the row is setup-blocked: $(rowf 12 .result)"

# ── E1: a retried round runs once on the pool and finishes once ──────────────
fresh; fly_on
row 12 b1 queued 1 "$(jq -Rn --arg r "$TRQ" '$r')"
tick
[ "$(puts)" = 1 ] && ok || bad "E1 one pool put, got $(puts): $(LOGF)"
PUT=$(grep '^POST /api/queue ' "$T/curl.log" | tail -1 | sed 's/^POST \/api\/queue //')
[ "$(jq -r '.key' <<<"$PUT" 2>/dev/null)" = "$CK8R1" ] && ok || bad "E1 the retry's pool key is $CK8R1: $PUT"
M=$(jq -r '.meta' <<<"$PUT")
printf 'builder-p\n' > "$T/boxname"
: > "$T/curl.log"
MD="$T/m/e1"; machine e1 "$CK8R1" "$M"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.fixround.id' "$MD/job.json" 2>/dev/null)" = 12 ] && ok || bad "E1 THE POINT: the mapping writes job.json for $CK8R1: rc $rc"
[ "$(stubs)" = 1 ] && ok || bad "E1 ONE --fix-here, got $(stubs)"
[ "$(finishes)" = 1 ] && ok || bad "E1 ONE finish, got $(finishes)"
[ "$(head -1 "$MD/RESULT" 2>/dev/null)" = "FIX_ROUND_FINISHED done finish=ok" ] && ok || bad "E1 RESULT: $(cat "$MD/RESULT" 2>/dev/null)"
[ "$(rowf 12 .status) $(rowf 12 .result)" = "done done" ] && ok || bad "E1 the fix row is done: $(rowf 12 '[.status,.result]|@csv')"

# ── A1: the BH-8896 adopt gate reads the live pool row of a retried round ────
a1() { # a1 <record_in json or null> <pool rows json> — prints "rc key wrong"
  ( say() { printf '%s\n' "$*" >> "$T/a1.say"; }
    _jobs_req() { printf '%s\n' "$2" >> "$T/a1.req"; printf '%s' "$POOLQ"; }
    H="$T/none"
    # shellcheck disable=SC1090
    . "$DIR/bin/blocked-resolver.d/bh-8896-fix-round-tree.sh"
    POOLQ="$2"
    ROW=$(jq -nc --argjson rin "$1" '{id:12, claimed_by:"pool:m1", result:"done", record_in:(if $rin == null then null else ($rin|tojson) end)}')
    frt_adopt_gate p rk why ck "$ROW"; echo "$? ${FRT_KEY:-} $FRT_WRONG" )
}
rm -f "$T/a1.req" "$T/a1.say"
Q=$(jq -nc --arg k "$CK8R1" '{queue:[{ticket_key:$k, status:"queued", reason:""}]}')
[ "$(a1 "$TRQ" "$Q")" = "1 $CK8R1 0" ] && ok || bad "A1 a retried round's queued -r1 row holds the adopt: $(a1 "$TRQ" "$Q") $(cat "$T/a1.say")"
grep -qF "key=$CK8R1&" "$T/a1.req" && ok || bad "A1 the gate reads the -r1 row: $(cat "$T/a1.req")"
[ "$(a1 null "$Q")" = "0 $KEY 0" ] && ok || bad "A1 a first round reads $KEY, not the -r1 row: $(a1 null "$Q")"
[ "$(a1 '{"timeout_requeues":[]}' "$Q")" = "0 $KEY 0" ] && ok || bad "A1 0 entries reads $KEY"
QW=$(jq -nc --arg k "$CK8R1" '{queue:[{ticket_key:$k, status:"failed", reason:"wrong-tree: x"}]}')
[ "$(a1 "$TRQ" "$QW")" = "0 $CK8R1 1" ] && ok || bad "A1 a wrong-tree -r1 row is FRT_WRONG: $(a1 "$TRQ" "$QW")"
# frt_refund names the live key the gate read.
RF2=$( ST="$T/a1st"; mkdir -p "$ST/p"
  say() { printf '%s\n' "$*"; }; br_event() { :; }; STAMP() { echo 2026-11-25T00:00:00Z; }
  br_json_edit() { printf '%s\n' "$*" > "$T/a1.edit"; }
  H="$T/none"
  # shellcheck disable=SC1090
  . "$DIR/bin/blocked-resolver.d/bh-8896-fix-round-tree.sh"
  FRT_KEY="$CK8R1"; frt_refund p ck rk why https://u/1 12 terminal )
[[ "$RF2" == *"pool row $CK8R1)"* ]] && grep -qF -- "--arg k $CK8R1" "$T/a1.edit" && ok || bad "A1 frt_refund names $CK8R1: $RF2 / $(cat "$T/a1.edit" 2>/dev/null)"

echo "fix-round-fly-retry.bh-10115: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
