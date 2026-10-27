#!/bin/bash
# tests/lane-ports-untriaged-sched.bh-8451-test.sh — BH-8451 (slice C3 of
# #7920): the untriaged lanes and the scheduler read a Linear project through
# the tracker contract. The SHIPPED scripts run in scratch trees
# (scratch_install_closure). Linear and the settings route are
# tests/lib/linear-stub.bh-7920.sh over tests/fixtures/lane-ports.bh-8451/linear/
# (see tests/lane-ports-linear.bh-8451-test.sh for the rows). The clock is
# pinned at 2026-10-21T12:00:00Z.
#
#   B1-B3  ut_trk_untriaged (bin/lib/untriaged-board-read.sh)
#   W1-W6  bin/untriaged-wake.sh with one GitHub project and one Linear project;
#          a front curl answers POST /api/wakes/nudge and hands every other
#          URL to the Linear stub
#   C1-C4  bin/scheduler.sh over real curl against the REAL jobs worker
#          (tests/lib/scheduler-shadow.bh-6978.mjs); only the Linear URL goes
#          to the stub
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-ports-untriaged-sched.bh-8451-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/linear-stub.bh-7920.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
DIR="$REPO"   # tests/lib/rendered.sh reads DIR
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset HARNESS_ENV_DIR GH_ISSUES_REPO
REAL_CURL=$(command -v curl)

KEY=lin-api-fixture-sentinel-8451
FIX="$REPO/tests/fixtures/lane-ports.bh-8451/linear"
NOW=$(date -u -d 2026-10-21T12:00:00Z +%s)   # determinism: ok a fixed instant, not the clock
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/state" "$H/logs" "$H/flags" "$H/catalog" "$T/shim" "$T/tmp"
for L in bin/untriaged-wake.sh bin/unblocked-children.sh bin/lib/untriaged-board-read.sh bin/jobs-client.sh bin/fleet-conf.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
cp "$(rendered_registry)" "$H/catalog/lanes.json"
cat > "$H/fleet.conf" <<'CONF'
gh1     o/gh1     -                  -  3
crolin  o/crolin  https://x.example  -  2
CONF
printf 'JOBS_URL=https://jobs.example\nHARNESS_SECRET=fixture-secret\nJOBS_RETRY_SLEEP=0\n' > "$H/env/global.env"
printf 'LINEAR_API_KEY=%s\nLINEAR_TEAM=CRO\n' "$KEY" > "$H/env/crolin.env"
linear_stub_setup "$T" "$FIX" || { echo "stub setup failed"; exit 1; }
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LS_KEY_EXPECT="$KEY" JOBS_SETTINGS_CACHE_S=0
linear_set tracker_adapter.crolin linear
linear_set tracker_linear.crolin.team CRO

# gh: REST issue reads for o/gh1 from $T/issues.json; every call is logged.
cat > "$T/shim/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/gh-calls.log"
case "$*" in "api repos/"*" -q .id") echo 1; exit 0 ;; esac
st="" lbl="" page=1 path=""
for a in "$@"; do
  case "$a" in state=*) st="${a#state=}" ;; labels=*) lbl="${a#labels=}" ;; page=*) page="${a#page=}" ;; repos/*) path="$a" ;; esac
done
case "$path" in repos/*/issues) ;; *) exit 1 ;; esac
[ "$page" = 1 ] || { printf 'HTTP/2 200\r\nx: 1\r\n\r\n[]'; exit 0; }
body=$(jq -c --arg st "$st" --arg l "$lbl" 'map(select($st == "all" or .state == $st) | select($l == "" or ([.labels[].name] | index($l))))' "$STUB_DIR/issues.json")
printf 'HTTP/2 200\r\nx: 1\r\n\r\n%s' "$body"
SH
# curl: the nudge route here; every other URL to the Linear stub's curl.
cat > "$T/shim/curl" <<'SH'
#!/bin/bash
url="" body="" prev=""
for a in "$@"; do
  [ "$prev" = --data-binary ] && body="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$url" in
  */api/wakes/nudge)
    printf '%s\n' "$body" >> "$STUB_DIR/attempts.jsonl"
    if [ "${STUB_TRK_400:-}" = 1 ] && printf '%s' "$body" | jq -e '.key | type == "string"' >/dev/null 2>&1; then
      printf '{"error":"key must be an integer"}\n400'; exit 0
    fi
    printf '%s\n' "$body" >> "$STUB_DIR/posts.jsonl"
    printf '{"inserted":1,"as_of":"x"}\n200'; exit 0 ;;
esac
exec "$STUB_DIR/lstub/curl" "$@"
SH
chmod +x "$T/shim/gh" "$T/shim/curl"
export PATH="$T/shim:$PATH" STUB_DIR="$T" TMPDIR="$T/tmp"
jq -nc --arg c "$(date -u -d "@$((NOW - 40 * 60))" +%FT%TZ)" \
  '[{number: 5, state: "open", comments: 0, created_at: $c, updated_at: $c, closed_at: null, title: "t5", body: "", labels: [{name: "ai-build"}]}]' \
  > "$T/issues.json"
fresh() { linear_reset_log; rm -f "$LS_STATE/issues.json" "$T"/posts.jsonl "$T"/attempts.jsonl "$T/gh-calls.log" "$H/logs/untriaged-wake.log"; }
fail_linear() { echo '{"errors":[{"message":"fixture failure"}]}' > "$LS_STATE/issues.json"; }

# ── B: ut_trk_untriaged ──────────────────────────────────────────────────────
ut() { ( export HARNESS="$H"; . "$H/bin/lib/untriaged-board-read.sh"; ut_trk_untriaged crolin 1800 "$NOW" ) 2>/dev/null; }
fresh
out=$(ut); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(printf 'CRO-12\tCRO-12\t2026-10-21T10:00:00Z\tLedger export to CSV')" ] && ok \
  || bad "B1 exactly CRO-12 (rc=$rc): $(tr '\t\n' ' |' <<<"$out")"
for k in 13 14 15 16 17 18 19 20; do
  grep -q "^CRO-$k[[:space:]]" <<<"$out" && bad "B2 CRO-$k must not be untriaged"
done; ok
[ "$(linear_req_of TrkIssues | jq -r .variables.label)" = ai-build ] && ok || bad "B1 the list asks for the build label"
fresh; fail_linear
out=$(ut); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "B3 a failed list: rc 1, no output (rc=$rc out=$out)"

# ── W: untriaged-wake ────────────────────────────────────────────────────────
run() { env HARNESS="$H" UNTRIAGED_WAKE_NOW="$NOW" "$@" "$H/bin/untriaged-wake.sh" >/dev/null 2>&1; }
logl() { tail -1 "$H/logs/untriaged-wake.log" 2>/dev/null; }
fresh; run
grep -q 'seen=2 candidates=2 nudged=2 already=0 left=0$' <<<"$(logl)" && ok || bad "W1 the log line: $(logl)"
[ "$(sed -n 1p "$T/posts.jsonl" 2>/dev/null | jq -c '[.repo, .key]')" = '["o/gh1",5]' ] && ok || bad "W2 #5 is posted first: $(cat "$T/posts.jsonl" 2>/dev/null)"
P2=$(sed -n 2p "$T/posts.jsonl" 2>/dev/null)
[ "$(jq -r .repo <<<"$P2")" = o/crolin ] && [ "$(jq -c .key <<<"$P2")" = '"CRO-12"' ] && [ "$(jq -r .reason <<<"$P2")" = untriaged ] \
  && [ "$(jq -r .dedupe <<<"$P2")" = untriaged:cro-12 ] && ok || bad "W2 the Linear body: $P2"
printf '%s\n' "$P2" > "$T/w2-body.json"
grep -q 'o/crolin' "$T/gh-calls.log" 2>/dev/null && bad "W3 a GitHub read for the Linear project: $(grep o/crolin "$T/gh-calls.log")" || ok
[ "$(linear_req_count TrkIssues)" -ge 1 ] && [ "$(linear_req_count)" = "$(linear_req_count TrkIssues)" ] && ok \
  || bad "W5 the Linear stub saw only TrkIssues: $(cat "$LS_STATE/reqs" 2>/dev/null)"
fresh; fail_linear; run
grep -q 'nudged=1 .*could-not-run trk@crolin' <<<"$(logl)" && ok || bad "W4 a failed Linear list: $(logl)"
[ "$(jq -c '[.repo, .key]' "$T/posts.jsonl" 2>/dev/null)" = '["o/gh1",5]' ] && ok || bad "W4 gh1 is still nudged: $(cat "$T/posts.jsonl" 2>/dev/null)"
fresh; run STUB_TRK_400=1
grep -q 'nudged=1 .*could-not-run 400' <<<"$(logl)" && ok || bad "W6 a 400 for the string key: $(logl)"

# The writer/reader round trip: the body the lane posted is the body the
# worker test (worker/jobs/test/wakes-nudge-trk-key.bh-8451.test.js N1)
# inserts and reads back.
F4='[.repo, .key, .reason, .dedupe]'
[ "$(jq -c "$F4" "$T/w2-body.json" 2>/dev/null)" = "$(jq -c "$F4" "$REPO/tests/fixtures/lane-ports.bh-8451/nudge-body.json")" ] \
  && ok || bad "W2 the lane's body is not the worker test's body: $(cat "$T/w2-body.json" 2>/dev/null)"

# ── C: the scheduler against the real worker ─────────────────────────────────
SRV="$REPO/tests/lib/scheduler-shadow.bh-6978.mjs"
if ! command -v node >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
  echo "SKIP C1-C4: node or flock missing"
else
  S="$T/s"; mkdir -p "$S/bin/lib" "$S/logs" "$S/locks" "$S/state" "$S/env" "$S/flags" "$S/prompts" "$T/sfront"
  for L in bin/scheduler.sh bin/lib/scheduler.sh bin/jobs-client.sh bin/fleet-conf.sh; do
    ( cd "$REPO" && scratch_install_closure "$L" "$S" ) >/dev/null || bad "C setup: could not install $L"
  done
  echo 'crolin  o/crolin  https://x.example  -  2' > "$S/fleet.conf"
  printf 'LINEAR_API_KEY=%s\nLINEAR_TEAM=CRO\n' "$KEY" > "$S/env/crolin.env"
  : > "$S/env/global.env"
  cat > "$S/bin/lib/gh-rest.sh" <<SH
# gh_rest stub: every path logged; no PR for any branch, 404 (rc 44) for the rest.
gh_rest() { printf '%s %s\n' "\$1" "\$2" >> "$T/sgh.log"
  case "\$2" in repos/o/crolin/pulls\?*) echo '[]'; return 0 ;; esac
  return 44; }
SH
  printf '#!/bin/bash\nexit 0\n' > "$S/bin/overlap-schedule.sh"
  printf '#!/bin/bash\necho "unlimited (fixture)"\n' > "$S/bin/free-slots.sh"
  for s in run-build.sh fly-dispatch.sh ready-queue.sh; do printf '#!/bin/bash\nexit 0\n' > "$S/bin/$s"; done
  chmod +x "$S/bin/"*.sh
  cat > "$T/sfront/curl" <<SH
#!/bin/bash
for a in "\$@"; do case "\$a" in https://api.linear.app/*)
  if [ -e "$T/fail-all" ] && d=\$(printf '%s\n' "\$@" | sed -n 's/^@//p' | head -1) && [ -n "\$d" ] && ! grep -q 'nin' "\$d"; then exit 7; fi
  exec "$T/lstub/curl" "\$@" ;; esac; done
exec "$REAL_CURL" "\$@"
SH
  chmod +x "$T/sfront/curl"
  : > "$T/srv.port"
  node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
  SPID=$!
  for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/srv.port")
  if [ -z "$PORT" ]; then
    echo "SKIP C1-C4: the worker did not start ($(head -3 "$T/srv.err"))"
  else
    W="http://127.0.0.1:$PORT"
    wsql() { "$REAL_CURL" -sS -X POST -d "$(jq -nc --arg s "$1" '{sql:$s}')" "$W/__sql" > /dev/null; }
    wset() { "$REAL_CURL" -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$W/__setting" > /dev/null; }
    sreset() {
      "$REAL_CURL" -sS -X POST "$W/__reset" > /dev/null
      wset tracker_adapter.crolin linear; wset tracker_linear.crolin.team CRO
      scratch_rm "$S/state/scheduler"; rm -f "$S/state/settings-cache.json" "$T/fail-all"
      : > "$S/logs/scheduler.log"; : > "$T/sgh.log"; linear_reset_log
      cp "$FIX/issues-all.json" "$LS_STATE/issues.json"
    }
    srun() { ( cd "$T" && PATH="$T/sfront:$PATH" HARNESS="$S" FLEET_CONF="$S/fleet.conf" JOBS_URL="$W" \
               HARNESS_SECRET=fixture-harness-secret JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
               SCHED_NOW="$NOW" bash "$S/bin/scheduler.sh" crolin ) > "$T/srun.out" 2>&1; }
    sched() { grep "SCHED ticket=$1 " "$S/logs/scheduler.log" | tail -1 | sed 's/^[^ ]* //'; }
    alls() { grep -c . "$LS_STATE/reqs" 2>/dev/null; }
    allreq() { local n c=0; for n in $(awk '$4 == "TrkIssues" {print $1}' "$LS_STATE/reqs" 2>/dev/null); do
                 grep -q nin "$LS_STATE/req-$n.json" || c=$((c + 1)); done; echo "$c"; }

    sreset; srun
    got=$(grep -o 'SCHED ticket=[^ ]*' "$S/logs/scheduler.log" | sed 's/SCHED ticket=//' | sort | tr '\n' ' ')
    [ "$got" = "CRO-12 CRO-15 CRO-16 CRO-17 CRO-18 CRO-19 CRO-20 " ] && ok \
      || bad "C1 the candidate set is the open build-labelled CRO keys: '$got' $(tail -2 "$T/srun.out") $(grep SCHED-TICK "$S/logs/scheduler.log")"
    grep -qE 'SCHED ticket=(ABC-3|CRO-3|cro-4|CRO-4|CRO-012|CRO-9|CRO-14) ' "$S/logs/scheduler.log" && bad "C1 an off-prefix, closed or unlabelled key is a candidate" || ok
    grep -q 'repos/o/crolin/issues' "$T/sgh.log" && bad "C1 a GitHub issue read for a Linear project: $(cat "$T/sgh.log")" || ok

    sreset
    wsql "INSERT INTO ticket_edges (project,parent,child,kind,source,at) VALUES ('crolin','9','12','hard','planner','2026-10-15T00:00:00Z')"
    wsql "INSERT INTO ticket_edges (project,parent,child,kind,source,at) VALUES ('crolin','21','15','hard','planner','2026-10-15T00:00:00Z')"
    srun
    [ "$(sched CRO-12)" = "SCHED ticket=CRO-12 ready=yes reason=" ] && ok || bad "C2 the closed parent CRO-9 clears CRO-12: '$(sched CRO-12)' $(grep SCHED-TICK "$S/logs/scheduler.log")"
    [ "$(sched CRO-15)" = "SCHED ticket=CRO-15 ready=unknown reason=parent #21 unreadable" ] && ok || bad "C2 a parent not in the list is unknown: '$(sched CRO-15)'"
    [ "$(allreq)" = 1 ] && ok || bad "C4 exactly one --state all list for two parents: $(allreq) of $(cat "$LS_STATE/reqs" 2>/dev/null | tr '\n' '|')"
    grep -q 'repos/o/crolin/issues' "$T/sgh.log" && bad "C4 a GitHub issue read: $(cat "$T/sgh.log")" || ok

    sreset
    wsql "INSERT INTO ticket_edges (project,parent,child,kind,source,at) VALUES ('crolin','9','12','hard','planner','2026-10-15T00:00:00Z')"
    : > "$T/fail-all"
    srun
    [ "$(sched CRO-12)" = "SCHED ticket=CRO-12 ready=unknown reason=parent #9 unreadable" ] && ok || bad "C3 a failed --state all list: the parent is unknown: '$(sched CRO-12)'"
    [ -n "$(sched CRO-16)" ] && ok || bad "C3 the open read still worked"
  fi
  kill "$SPID" 2>/dev/null
fi

echo "lane-ports-untriaged-sched: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
