#!/bin/bash
# tests/pr-url-reconcile-per-project.bh-6894-test.sh — bin/pr-url-reconcile.sh
# per project (BH-6894, BH-6881.12). `--project <p>` walks only <p>'s build
# records; `--dispatch` starts one `--project <p>` run per project through
# pl_dispatch (bin/lib/project-lanes.sh); no flag is the fleet run of today.
# catalog/lane-run-inputs.d/pr-url-reconcile.{ro,rw} is the manifest pair.
#
# Drives the REAL script against a scratch harness root with a stub `gh` that
# answers every `pulls?head=` read with one open PR. Fleet: pa, pb, pa-x
# (pa-x is the prefix collision a `pa` run must never walk).
#   A1  --project pa links pa's three records (plain, pool-, fly-) and leaves
#       pa-x, pb and pa's superseded record byte for byte; summary project=pa
#   A2  no flag links every record; summary line has no project=
#   A3  a root built from the .ro snapshot list only gives pa the same result,
#       and every file the run writes is rw or on the NOT CARRIED list
#   A4  --dispatch, placement hub, spread unset: `started 2 project run(s)
#       (period 120s` and one project= summary line per project
#   A4f --dispatch, lane_placement.pr-url-reconcile=fly (worker stub): one
#       lane_runs row per project, no project run on the hub
#   A4n no bin/lib/project-lanes.sh: --dispatch falls back to the fleet run;
#       --project=pa takes its project lock by hand
#   A4s a junk spread logs one line and uses 120; an empty fleet starts nothing
#   A5  --dispatch --project pa: rc 2, nothing linked
#   A6  --project zz | '' | ../pa: rc 2, one log line each, nothing linked
#   A7  a held locks/pr-url-reconcile-pa.lock: rc 0, nothing linked
#   A7r a hand run while a runner-started run of pa is live: rc 0, still live
#   A8  a fleet run's exclusive lock: a project run exits 0, nothing linked
#   A9  --project pa and --project pb at once: both rc 0, both link
#   A10 the repo seeds lane_placement.pr-url-reconcile = hub, never fly
# Every wait is bounded and polls a file.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-url-reconcile-per-project.bh-6894-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null && command -v flock >/dev/null && command -v setsid >/dev/null \
  || { echo "SKIP: jq, flock or setsid missing"; exit 0; }

STAMPDIR=202610150000
unset REGISTRY_SOURCE JOBS_URL HARNESS_ENV_DIR PR_URL_RECONCILE_DISPATCH_SPREAD_SECS

# The stub gh. `api -i repos/o/<repo>/pulls?head=o:ticket/bh-<n>&state=open`
# answers 200 + one PR, https://github.com/o/<repo>/pull/<n>. While
# $STUBHUB/hold exists, a call writes $STUBHUB/inflight and waits (30 s max).
mkdir -p "$T/stubbin"
cat > "$T/stubbin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUBHUB/gh-calls.log"
if [ -f "$STUBHUB/hold" ]; then
  : > "$STUBHUB/inflight"; n=0
  while [ -f "$STUBHUB/hold" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
fi
p=$(grep -m1 '^repos/' < <(printf '%s\n' "$@"))
repo=$(sed -E 's#^repos/[^/]+/([^/]+)/.*#\1#' <<<"$p")
num=$(grep -oE 'head=[^&]*' <<<"$p" | grep -oE '[0-9]+$')
case "$p" in
  *state=open*) printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n[{"html_url":"https://github.com/o/%s/pull/%s"}]\n' "$repo" "$num" ;;
  *) printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n[]\n' ;;
esac
STUB
chmod +x "$T/stubbin/gh"

# mk <name> [projects...] — H is a scratch root with the lane's closure, the
# runner, fleet.conf and an empty env dir. No jobs client: the ledger half and
# the placement read stay off unless a case installs it.
mk() {
  local n="$1" p i=1 f; shift
  H="$T/$n"; scratch_rm "$H"
  mkdir -p "$H/builds" "$H/logs" "$H/locks" "$H/flags" "$H/env" "$H/state"
  for f in bin/pr-url-reconcile.sh bin/project-lane-run.sh bin/fleet-conf.sh; do
    ( cd "$DIR" && scratch_install_closure "$f" "$H" ) >/dev/null || bad "setup: closure of $f"
  done
  rm -f "$H/bin/jobs-client.sh"
  : > "$H/fleet.conf"
  for p in "${@:-pa pb pa-x}"; do
    for p in $p; do printf '%s o/%s - - 2 box-%s 192.0.2.%s\n' "$p" "$p" "$p" "$i" >> "$H/fleet.conf"; i=$((i + 1)); done
  done
}
# rec <dir name> — a record whose create failed, with an APPROVE review.
rec() {
  mkdir -p "$H/builds/$1"
  printf 'PR_CREATE_FAILED: GraphQL: API rate limit already exceeded (fixture)\nTIER: 2\n' > "$H/builds/$1/RESULT"
  printf 'VERDICT: APPROVE\nTIER: 2\n' > "$H/builds/$1/review.md"
}
# fixture — pa (plain, pool-, fly-, one superseded), pa-x and pb.
fixture() {
  rec "pa-BH-1-$STAMPDIR"; rec "pool-pa-BH-2-$STAMPDIR"; rec "fly-pa-BH-3-$STAMPDIR"
  rec "pa-x-BH-4-$STAMPDIR"; rec "pb-BH-5-$STAMPDIR"
  rec "pa-BH-6-$STAMPDIR"; : > "$H/builds/pa-BH-6-$STAMPDIR/.blocked-resolver-superseded"
}
# run [args...] — one real run against $H; RC is its exit code.
run() {
  ( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBHUB="$H" PATH="$T/stubbin:$PATH"
    "$H/bin/pr-url-reconcile.sh" "$@" ) >"$H/out.txt" 2>"$H/err.txt"
  RC=$?
}
linked() { head -n 1 "$H/builds/$1/RESULT" | grep -q "^PR_CREATED https://github.com/o/$2/pull/$3 | RECONCILED "; }
untouched() { head -n 1 "$H/builds/$1/RESULT" | grep -q '^PR_CREATE_FAILED' && [ ! -e "$H/builds/$1/.pr-url-reconciled" ]; }
nlinked() { grep -l '^PR_CREATED ' "$H"/builds/*/RESULT 2>/dev/null | grep -c .; }
logn() { grep -cF -- "$1" "$H/logs/pr-url-reconcile.log" 2>/dev/null || true; }
wait_for() { local n=0; until eval "$2"; do n=$((n + 1)); [ "$n" -ge "$1" ] && return 1; sleep 0.1; done; }
# norm <file> — the RESULT with the reconcile timestamp blanked.
norm() { sed -E 's/RECONCILED [0-9T:-]+Z/RECONCILED <t>/' "$1"; }

# hold <lock file> <tag> [-s] — a background flock held until $T/<tag>.go goes away.
hold() {
  : > "$T/$2.go"
  ( exec 7>"$1"; flock ${3:-} 7 || exit 1; : > "$T/$2.held"
    n=0; while [ -f "$T/$2.go" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done ) &
  wait_for 100 '[ -f "$T/$2.held" ]'
}

echo "A1: --project pa touches only pa's records"
mk a1; fixture
for r in pa-x-BH-4 pb-BH-5 pa-BH-6; do cp "$H/builds/$r-$STAMPDIR/RESULT" "$T/a1.$r.before"; done
run --project pa
[ "$RC" = 0 ] && ok "A1 rc 0" || bad "A1 rc=$RC err=$(cat "$H/err.txt")"
linked "pa-BH-1-$STAMPDIR" pa 1 && linked "pool-pa-BH-2-$STAMPDIR" pa 2 && linked "fly-pa-BH-3-$STAMPDIR" pa 3 \
  && ok "A1 pa's plain, pool- and fly- records linked" || bad "A1 a pa record not linked: $(head -qn1 "$H"/builds/*pa-BH-[123]-*/RESULT)"
for r in pa-BH-1 pool-pa-BH-2 fly-pa-BH-3; do
  [ -e "$H/builds/$r-$STAMPDIR/.pr-url-reconciled" ] || bad "A1 $r has no .pr-url-reconciled marker"
done
for r in pa-x-BH-4 pb-BH-5 pa-BH-6; do
  if cmp -s "$T/a1.$r.before" "$H/builds/$r-$STAMPDIR/RESULT" && [ ! -e "$H/builds/$r-$STAMPDIR/.pr-url-reconciled" ]; then
    ok "A1 $r RESULT byte-identical, no marker"
  else bad "A1 $r was touched: $(head -n1 "$H/builds/$r-$STAMPDIR/RESULT")"; fi
done
grep -q 'repos/o/pa-x/\|repos/o/pb/' "$H/gh-calls.log" && bad "A1 the pa run read another project's repo: $(cat "$H/gh-calls.log")" \
  || ok "A1 no GitHub read for pa-x or pb"
[ "$(logn 'tick: walked=3 links=3 alerts=0 skipped=1 unwalked=0 cap=50 deadline=240s project=pa')" = 1 ] \
  && ok "A1 summary line: walked=3 links=3 skipped=1 project=pa" || bad "A1 summary: $(grep 'tick:' "$H/logs/pr-url-reconcile.log")"
for r in pa-BH-1 pool-pa-BH-2 fly-pa-BH-3; do norm "$H/builds/$r-$STAMPDIR/RESULT" > "$T/a1.$r.after"; done

echo "A2: no flag is the fleet run of today"
mk a2; fixture
run
[ "$RC" = 0 ] && ok "A2 rc 0" || bad "A2 rc=$RC"
linked "pa-x-BH-4-$STAMPDIR" pa-x 4 && linked "pb-BH-5-$STAMPDIR" pb 5 && linked "pa-BH-1-$STAMPDIR" pa 1 \
  && [ "$(nlinked)" = 5 ] && ok "A2 all five live records linked" || bad "A2 linked=$(nlinked)"
grep -q 'tick: walked=5 links=5 alerts=0 skipped=1 unwalked=0 cap=50 deadline=240s$' "$H/logs/pr-url-reconcile.log" \
  && ok "A2 summary line ends at deadline=240s (no project=)" || bad "A2 summary: $(grep 'tick:' "$H/logs/pr-url-reconcile.log")"

echo "A3: the manifest snapshot is enough for a pa run"
mk a3full; fixture; FULL="$H"
mk a3; S="$H"; scratch_rm "$S/builds"; mkdir -p "$S/builds"
cp "$FULL/fleet.conf" "$S/fleet.conf"
LIST=$( export HARNESS="$FULL" LRI_LANE=pr-url-reconcile LRI_MANIFEST_DIR="$DIR/catalog/lane-run-inputs.d"
  . "$DIR/bin/lib/lane-run-inputs.sh" && _lri_list pa ro 0 ); LRC=$?
[ "$LRC" = 0 ] && [ -n "$LIST" ] && ok "A3 _lri_list pa ro rc 0, $(grep -c . <<<"$LIST") members" || bad "A3 _lri_list rc=$LRC list='$LIST'"
grep -q $'\tbuilds/pa-x-\|\tbuilds/pb-' <<<"$LIST" && bad "A3 the pa snapshot carries another project's record: $LIST" \
  || ok "A3 the pa snapshot carries no pa-x or pb record"
while IFS=$'\t' read -r t rel; do
  [ -n "$rel" ] || continue
  if [ "$t" = d ]; then mkdir -p "$S/$rel"; else mkdir -p "$S/$(dirname "$rel")"; cp -p "$FULL/$rel" "$S/$rel"; fi
done <<<"$LIST"
( cd "$S" && find . -type f ! -path './bin/*' -exec sha256sum {} + | sort ) > "$T/a3.before"
run --project pa
[ "$RC" = 0 ] && ok "A3 rc 0 on the snapshot root" || bad "A3 rc=$RC err=$(cat "$H/err.txt")"
for r in pa-BH-1 pool-pa-BH-2 fly-pa-BH-3; do
  norm "$S/builds/$r-$STAMPDIR/RESULT" | cmp -s - "$T/a1.$r.after" \
    && ok "A3 $r RESULT equals A1's" || bad "A3 $r RESULT differs: $(head -n1 "$S/builds/$r-$STAMPDIR/RESULT")"
done
[ ! -e "$S/builds/pa-BH-6-$STAMPDIR/.pr-url-reconciled" ] && head -n1 "$S/builds/pa-BH-6-$STAMPDIR/RESULT" | grep -q '^PR_CREATE_FAILED' \
  && ok "A3 the superseded record stays unlinked (its marker rode in the snapshot)" || bad "A3 the superseded record was linked"
( cd "$S" && find . -type f ! -path './bin/*' -exec sha256sum {} + | sort ) > "$T/a3.after"
CHANGED=$(comm -13 "$T/a3.before" "$T/a3.after" | awk '{print $2}' | sed 's#^\./##')
OUTSIDE=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    # NOT CARRIED (the .rw header): the lane log rides back as the lane log;
    # the stderr log, gh-rate.log, ALERTS.log, locks, the lane-gate cache and
    # the stub's own files stay put.
    logs/pr-url-reconcile.log|logs/pr-url-reconcile.stderr.log|logs/ALERTS.log|logs/gh-rate.log) continue ;;
    locks/*|state/lane-gate/*|gh-calls.log|out.txt|err.txt) continue ;;
  esac
  ( export HARNESS="$S" LRI_MANIFEST_DIR="$DIR/catalog/lane-run-inputs.d"
    . "$DIR/bin/lib/lane-run-inputs.sh" && lri_member_ok pa "$rel" - rw pr-url-reconcile ) || OUTSIDE="$OUTSIDE $rel"
done <<<"$CHANGED"
[ -n "$CHANGED" ] && [ -z "$OUTSIDE" ] && ok "A3 every written file is rw or NOT CARRIED ($(grep -c . <<<"$CHANGED") files)" \
  || bad "A3 written outside the rw list:${OUTSIDE:- (nothing written)}"

echo "A4: --dispatch with placement hub starts one run per project"
mk a4 ub xa
rec "ub-BH-7-$STAMPDIR"; rec "xa-BH-8-$STAMPDIR"
run --dispatch
[ "$RC" = 0 ] && ok "A4 dispatch rc 0" || bad "A4 rc=$RC err=$(cat "$H/err.txt")"
[ "$(logn 'pr-url-reconcile dispatch: started 2 project run(s) (period 120s, no cap)')" = 1 ] \
  && ok "A4 dispatch line: started 2 project run(s), period 120s (the default)" || bad "A4 dispatch line: $(cat "$H/logs/pr-url-reconcile.log")"
[ "$(logn 'placed: 0 fly, 2 hub')" = 1 ] && ok "A4 placed: 0 fly, 2 hub" || bad "A4 placement: $(cat "$H/logs/pr-url-reconcile.log")"
wait_for 300 '[ "$(logn "project=ub")" = 1 ] && [ "$(logn "project=xa")" = 1 ]' \
  && ok "A4 one project= summary line for ub and one for xa" \
  || bad "A4 project lines: $(grep 'tick:' "$H/logs/pr-url-reconcile.log") cron=$(cat "$H/logs/pr-url-reconcile-cron.log" 2>/dev/null)"
linked "ub-BH-7-$STAMPDIR" ub 7 && linked "xa-BH-8-$STAMPDIR" xa 8 && ok "A4 both projects' records linked" || bad "A4 records not linked"
grep -q 'lane-placement' "$H/logs/ALERTS.log" 2>/dev/null && bad "A4 a lane-placement alert" || ok "A4 no lane-placement alert"
grep -q 'tick:.*deadline=240s$' "$H/logs/pr-url-reconcile.log" && bad "A4 the dispatcher also ran a fleet walk" || ok "A4 no fleet summary line"

echo "A4f: --dispatch with placement fly enqueues lane_runs rows"
# The worker imports the composed catalogs (CI composes them before the suites).
command -v node >/dev/null 2>&1 && { [ -f "$DIR/catalog/lanes.json" ] || "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null; } \
  && "$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || echo "  note: could not compose catalog/lanes.json or llm-sites.json"
if command -v node >/dev/null 2>&1; then
  mk a4f pa pb; fixture
  ( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$H" ) >/dev/null || bad "setup: jobs-client closure"
  : > "$T/w.log"; : > "$T/w.port"
  node "$DIR/tests/lib/lane-runs-worker.bh-6124.mjs" "$T/w.log" > "$T/w.port" 2> "$T/w.err" &
  WPID=$!
  wait_for 200 '[ -s "$T/w.port" ] || ! kill -0 $WPID 2>/dev/null'
  PORT=$(head -n1 "$T/w.port")
  if [ -z "$PORT" ]; then
    wait "$WPID"; echo "  note A4f skipped: the worker stub did not start (rc $?, node:sqlite missing?)"
  else
    JU="http://127.0.0.1:$PORT"
    curl -sS -X PUT "$JU/__setting" -d '{"key":"lane_placement.pr-url-reconcile","value":"fly"}' >/dev/null
    ( export JOBS_URL="$JU" HARNESS_SECRET=fixture-harness-secret JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 \
        JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box PR_URL_RECONCILE_DISPATCH_SPREAD_SECS=0
      run --dispatch; echo "$RC" > "$T/a4f.rc" )
    [ "$(cat "$T/a4f.rc")" = 0 ] && ok "A4f dispatch rc 0" || bad "A4f rc=$(cat "$T/a4f.rc") err=$(cat "$H/err.txt")"
    ROWS=$(curl -sS "$JU/__lane_runs" | jq -c '[.rows[] | select(.lane == "pr-url-reconcile") | {project, args}]')
    [ "$(jq 'length' <<<"$ROWS")" = 2 ] && [ "$(jq -r '[.[].project] | sort | join(",")' <<<"$ROWS")" = pa,pb ] \
      && ok "A4f one lane_runs row for pa and one for pb" || bad "A4f rows: $ROWS log=$(cat "$H/logs/pr-url-reconcile.log")"
    [ "$(jq -c '[.[].args] | unique' <<<"$ROWS")" = '[["bin/pr-url-reconcile.sh","--project"]]' ] \
      && ok "A4f each row runs bin/pr-url-reconcile.sh --project" || bad "A4f args: $ROWS"
    [ "$(logn 'placed: 2 fly, 0 hub (lane_placement.pr-url-reconcile=fly)')" = 1 ] \
      && ok "A4f placed: 2 fly, 0 hub" || bad "A4f placement: $(cat "$H/logs/pr-url-reconcile.log")"
    [ "$(logn 'project=')" = 0 ] && [ ! -e "$H/logs/pr-url-reconcile-cron.log" ] && [ "$(nlinked)" = 0 ] \
      && ok "A4f no project run on the hub" || bad "A4f a hub run happened: $(grep 'tick:' "$H/logs/pr-url-reconcile.log")"
  fi
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
else
  echo "  note A4f skipped: node is not installed"
fi

echo "A4n: no project-lanes.sh — --dispatch runs the fleet walk"
mk a4n; fixture; rm -f "$H/bin/lib/project-lanes.sh"
run --dispatch
[ "$RC" = 0 ] && [ "$(nlinked)" = 5 ] && ok "A4n rc 0, all five records linked" || bad "A4n rc=$RC linked=$(nlinked)"
[ "$(logn 'project-lanes.sh not loaded — this tick walks every project in one process')" = 1 ] \
  && ok "A4n one log line names the fallback" || bad "A4n log: $(cat "$H/logs/pr-url-reconcile.log")"

run --project=pa
[ "$RC" = 0 ] && grep -q 'tick: walked=0 links=0 .* project=pa$' "$H/logs/pr-url-reconcile.log" \
  && ok "A4n --project=pa with no lib takes its own lock and runs as a project run" || bad "A4n --project=pa rc=$RC: $(grep 'tick:' "$H/logs/pr-url-reconcile.log")"
mk a4n2; fixture; rm -f "$H/bin/lib/project-lanes.sh"
hold "$H/locks/pr-url-reconcile-pa.lock" a4n
run --project=pa
rm -f "$T/a4n.go"; wait
[ "$RC" = 0 ] && [ "$(nlinked)" = 0 ] && [ "$(logn 'a run of pa is still live (locks/pr-url-reconcile-pa.lock held) — exiting')" = 1 ] \
  && ok "A4n with no lib a held project lock still stops a pa run" || bad "A4n held lock with no lib: rc=$RC linked=$(nlinked)"

echo "A4s: a junk spread falls back to 120; an empty fleet starts nothing"
mk a4s; : > "$H/fleet.conf"
PR_URL_RECONCILE_DISPATCH_SPREAD_SECS=abc run --dispatch
[ "$RC" = 0 ] && ok "A4s rc 0" || bad "A4s rc=$RC"
[ "$(logn "PR_URL_RECONCILE_DISPATCH_SPREAD_SECS='abc' is not a whole number — using 120")" = 1 ] \
  && ok "A4s one log line for the junk spread" || bad "A4s log: $(cat "$H/logs/pr-url-reconcile.log")"
[ "$(logn 'pr-url-reconcile dispatch: fleet.conf named no project')" = 1 ] \
  && ok "A4s an empty fleet.conf logs that no run started" || bad "A4s log: $(cat "$H/logs/pr-url-reconcile.log")"

echo "A5: --dispatch and --project are exclusive"
mk a5; fixture
run --dispatch --project pa
[ "$RC" = 2 ] && [ "$(nlinked)" = 0 ] && ok "A5 rc 2, nothing linked" || bad "A5 rc=$RC linked=$(nlinked)"
grep -q 'exclusive' "$H/err.txt" && ok "A5 stderr names the clash" || bad "A5 stderr: $(cat "$H/err.txt")"

echo "A6: an unknown or unsafe project"
mk a6; fixture
for P in zz '' ../pa; do
  run --project "$P"
  [ "$RC" = 2 ] && ok "A6 --project '$P' rc 2" || bad "A6 --project '$P' rc=$RC"
  [ "$(logn "--project '$P' is not a project in fleet.conf — no run")" = 1 ] && ok "A6 one log line for '$P'" \
    || bad "A6 log for '$P': $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"
done
[ "$(nlinked)" = 0 ] && [ ! -s "$H/gh-calls.log" ] && ok "A6 nothing linked, no GitHub read" || bad "A6 linked=$(nlinked)"
ls "$H"/locks/pr-url-reconcile*.lock >/dev/null 2>&1 && bad "A6 a refused run opened a lock: $(ls "$H/locks")" || ok "A6 no lock opened"

echo "A7: a held project lock"
mk a7; fixture
hold "$H/locks/pr-url-reconcile-pa.lock" a7
run --project pa
rm -f "$T/a7.go"; wait
[ "$RC" = 0 ] && [ "$(nlinked)" = 0 ] && ok "A7 rc 0, nothing linked" || bad "A7 rc=$RC linked=$(nlinked)"
[ "$(logn 'a run of pa is still live (locks/pr-url-reconcile-pa.lock held) — exiting')" = 1 ] \
  && ok "A7 the log line names the lock" || bad "A7 log: $(cat "$H/logs/pr-url-reconcile.log")"

echo "A7r: a hand run while a runner-started run of pa is live"
mk a7r; fixture; : > "$H/hold"
( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBHUB="$H" PATH="$T/stubbin:$PATH"
  "$H/bin/project-lane-run.sh" pr-url-reconcile pa 0 "$H/bin/pr-url-reconcile.sh" --project ) >"$T/a7r.out" 2>&1 &
RPID=$!
wait_for 200 '[ -f "$H/inflight" ]' && ok "A7r the runner's run reached GitHub" || bad "A7r the runner's run never reached gh: $(cat "$T/a7r.out")"
run --project pa
[ "$RC" = 0 ] && [ "$(logn 'a run of pa is still live (locks/pr-url-reconcile-pa.lock held) — exiting')" = 1 ] \
  && ok "A7r the hand run exits 0 on the runner's lock" || bad "A7r rc=$RC log=$(cat "$H/logs/pr-url-reconcile.log")"
rm -f "$H/hold"; wait "$RPID"
[ "$(logn 'project=pa')" = 1 ] && ok "A7r exactly one pa run walked" || bad "A7r pa summary lines: $(logn 'project=pa')"

echo "A8: a fleet run's exclusive lock"
mk a8; fixture
hold "$H/locks/pr-url-reconcile.lock" a8
run --project pa
rm -f "$T/a8.go"; wait
[ "$RC" = 0 ] && [ "$(nlinked)" = 0 ] && ok "A8 rc 0, nothing linked" || bad "A8 rc=$RC linked=$(nlinked)"
[ "$(logn 'project pa: a fleet run holds locks/pr-url-reconcile.lock — exiting')" = 1 ] \
  && ok "A8 the log line names the fleet lock" || bad "A8 log: $(cat "$H/logs/pr-url-reconcile.log")"

echo "A9: two project runs at once"
mk a9; fixture; : > "$H/hold"
( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBHUB="$H" PATH="$T/stubbin:$PATH"
  "$H/bin/pr-url-reconcile.sh" --project pa; echo $? > "$T/a9.pa" ) >/dev/null 2>&1 &
( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBHUB="$H" PATH="$T/stubbin:$PATH"
  "$H/bin/pr-url-reconcile.sh" --project pb; echo $? > "$T/a9.pb" ) >/dev/null 2>&1 &
wait_for 200 'grep -qs "repos/o/pa/" "$H/gh-calls.log" && grep -qs "repos/o/pb/" "$H/gh-calls.log"' \
  && ok "A9 both runs were inside GitHub at the same time" || bad "A9 the runs did not overlap: $(cat "$H/gh-calls.log" 2>/dev/null)"
rm -f "$H/hold"; wait
[ "$(cat "$T/a9.pa")" = 0 ] && [ "$(cat "$T/a9.pb")" = 0 ] && ok "A9 both rc 0" || bad "A9 rc pa=$(cat "$T/a9.pa") pb=$(cat "$T/a9.pb")"
linked "pa-BH-1-$STAMPDIR" pa 1 && linked "pb-BH-5-$STAMPDIR" pb 5 && untouched "pa-x-BH-4-$STAMPDIR" \
  && ok "A9 pa and pb linked, pa-x untouched" || bad "A9 linked=$(nlinked)"

echo "A10: the placement seed is hub"
SEED=$(cat "$DIR"/worker/jobs/schema.d/*.sql)
[ "$(grep -cE "'lane_placement\.pr-url-reconcile'[[:space:]]*,[[:space:]]*'hub'" <<<"$SEED")" = 1 ] \
  && ok "A10 exactly one lane_placement.pr-url-reconcile = hub row" || bad "A10 no single hub seed row"
grep -qE "'lane_placement\.pr-url-reconcile'[[:space:]]*,[[:space:]]*'fly'" <<<"$SEED" \
  && bad "A10 a fragment places pr-url-reconcile on fly" || ok "A10 no fragment sets it to fly"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
