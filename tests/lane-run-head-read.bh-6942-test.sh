#!/bin/bash
# tests/lane-run-head-read.bh-6942-test.sh — BH-6942: a lane-run machine names
# the head-read error in its prof line, checks once at start which fleet repos
# it can read (bin/lib/lane-run-repos.sh), and refuses the merge-conductor-pr
# rows of a repo it cannot read at claim time, so the row stays queued for the
# hub.
#
# Driven through the REAL bin/lane-run-worker.sh --once and
# bin/merge-conductor-pr.sh over real curl against the REAL jobs worker
# (tests/lib/lane-runs-worker.bh-6124.mjs). gh is a stub that answers per repo
# from $T/mode-<x|y>; curl is a wrapper that records each request's arguments
# and then runs the real curl; lane-alert.sh is a stub that records each call.
#
#   H1  X 404, Y 200: the skip file holds `px.` only, one log line names
#       example-org/x and 404, one alert lane-run-repo-unreadable-px, the
#       summary says 1 of 2 repos readable; lrr_skip_json prints ["px."]
#   H2  X 403 rate limit, 000 network or 502: unknown, nothing refused, no
#       alert; X 401: unreadable 401-auth, refused
#   H3  the real worker with LANE_RUN_REPO_CHECK=1: the px row stays queued
#       with attempts 0 and no claimer, the py row runs done rc 0, and the
#       claim body carries skip_prefixes ["px."]
#   H4  merge-conductor-pr.sh: a 403 rate limit on the PR read prints
#       reason=head-read-rc75-403-rate-limit-via-default and exits 75; no
#       status line prints head-read-rc75-000-network-via-default
#   H5  the check off (LANE_RUN_REPO_CHECK=0, or unset with no
#       LANE_RUN_CODE_SYNC): no gh call, no skip file, no skip_prefixes in
#       the claim body; LANE_RUN_CODE_SYNC=1 alone turns it on
#   H6  a repo shared by two projects is read once and refuses both; a
#       project with repo `-` is not read
#   H7  fleet-conf.sh fails: no skip file (an old one is removed), one log
#       line, rc 0
#   H8  a refused row of an old head never blocks the new head (lead review
#       of #6960): the px row of head A is refused at claim and stays queued;
#       the head moves to B. Inside MC_FLY_QUEUE_STALE_S, mc_fly_enqueue for
#       B still answers 4 (the A row may yet be claimed). Past it, the A row
#       no longer counts as live: B is enqueued (rc 0), and the next tick
#       hands B to the hub (rc 8, no-capacity), so head B runs. Past
#       lane_run.refused_max_wait_s the next refusing claim ENDS rows A and B
#       (died, prof `withdrawn refused-at-claim`), and the hub reads B as rc 8
#       `withdrawn`, not as a machine failure (rc 7).
#   H9  3 pushes on an unreadable repo leave at most 1 live row (lead review
#       of #6960): for each head of PR #9, the hub enqueues it (rc 0), a
#       refusing claim past lane_run.refused_max_wait_s ends it, and the live
#       rows of px.9. are never more than 1; at the end there are 0.
#
# Run from anywhere: tests/lane-run-head-read.bh-6942-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
SRV="$DIR/tests/lib/lane-runs-worker.bh-6124.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v curl >/dev/null 2>&1 || { echo "SKIP: node, jq, flock or curl missing"; exit 0; }
REAL_CURL=$(command -v curl)

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$T/fakebin"
for L in bin/lane-run-worker.sh bin/project-lane-run.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/gh-app-auth.sh \
         bin/merge-conductor-pr.sh bin/lib/lane-run-repos.sh bin/lib/mc/fly-workers.sh bin/lib/lane-placement.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
FLEET='px example-org/x - - 2 box-px 192.0.2.1
py example-org/y - - 2 box-py 192.0.2.2
'
printf '%s' "$FLEET" > "$H/fleet.conf"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
printf '#!/bin/bash\necho "PROF ok x=1"\nexit 0\n' > "$H/bin/ok.sh"
chmod +x "$H/bin/lane-alert.sh" "$H/bin/ok.sh"

# The gh stub. $T/mode-<x|y>: 200 | 404 | 401 | 403rl | 502 | none (no status line).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
a="\$*"
case "\$a" in
  *"repos/example-org/x"*) m=\$(cat "$T/mode-x") ;;
  *"repos/example-org/y"*) m=\$(cat "$T/mode-y") ;;
  *) exit 1 ;;
esac
case "\$a" in
  *"-i "*)
    case "\$m" in
      200) printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n{"id":1,"head":{"sha":"none"}}\n' ;;
      404) printf 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
      401) printf 'HTTP/2.0 401 Unauthorized\r\n\r\n{"message":"Bad credentials"}\n'; exit 1 ;;
      403rl) printf 'HTTP/2.0 403 Forbidden\r\n\r\n{"message":"API rate limit exceeded for installation ID 1."}\n'; exit 1 ;;
      502) printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n{"message":"Server Error"}\n'; exit 1 ;;
      none) exit 1 ;;
    esac ;;
  *) [ "\$m" = 200 ] && { echo 1; exit 0; }; exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/curl-calls.txt"
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$T/fakebin/curl"

export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret GH_TOKEN=tok-fixture-default GH_ETAG=0
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box
unset LANE_RUN_CODE_SYNC FLY_MACHINE_ID

PID=""
: > "$T/w.log"; : > "$T/w.port"
node "$SRV" "$T/w.log" > "$T/w.port" 2> "$T/w.err" &
PID=$!
trap 'kill "$PID" 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port")
if [ -z "$PORT" ]; then wait "$PID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }; echo "setup: worker did not start: $(cat "$T/w.err")"; exit 1; fi
export JOBS_URL="http://127.0.0.1:$PORT"

api() { "$REAL_CURL" -sS -X "$1" -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' ${3:+-d "$3"} "$JOBS_URL$2"; }
enq() { api POST /api/lane-runs "$(jq -nc --arg l "$1" --arg p "$2" --arg c "$3" '{lane:$l,project:$p,args:[$c]}')" | jq -r .id; }
drow() { "$REAL_CURL" -sS "$JOBS_URL/__lane_runs" | jq -c --argjson id "$1" '.rows[] | select(.id == $id)'; }
SKIP="$H/state/lane-run-worker/skip-prefixes"
WLOG="$H/logs/lane-run-worker.log"
reset() { : > "$T/gh-calls.txt"; : > "$T/alerts.txt"; : > "$T/curl-calls.txt"; rm -f "$SKIP" "$WLOG"; echo "$1" > "$T/mode-x"; echo "$2" > "$T/mode-y"; }
# check — lrr_check in a subshell of the machine tree, as the worker runs it.
check() { ( . "$H/bin/lib/lane-run-repos.sh" || exit 9; lrr_check ) > "$T/check.out" 2> "$T/check.err"; CRC=$?; }
skipjson() { ( . "$H/bin/lib/lane-run-repos.sh" || exit 9; lrr_skip_json ); }
nalert() { grep -c -- "--id lane-run-repo-unreadable-$1 " "$T/alerts.txt"; }
export LANE_RUN_REPO_CHECK=1

# ============================================================================
echo "H1: X answers 404, Y answers 200"
reset 404 200
check
[ "$CRC" = 0 ] && ok "H1 lrr_check rc 0" || bad "H1 rc=$CRC $(cat "$T/check.err")"
[ "$(cat "$SKIP" 2>/dev/null)" = "px." ] && ok "H1 the skip file holds px. only" || bad "H1 skip file: '$(cat "$SKIP" 2>/dev/null)'"
[ "$(grep -c 'example-org/x' "$WLOG" 2>/dev/null)" = 1 ] && grep -q 'example-org/x.*unreadable 404' "$WLOG" \
  && ok "H1 one log line names example-org/x and 404" || bad "H1 log: $(cat "$WLOG" 2>/dev/null)"
! grep -q 'example-org/y' "$WLOG" && ok "H1 no log line for the readable repo" || bad "H1 log: $(cat "$WLOG")"
grep -q 'repo check: 1 of 2 repos readable, 1 unreadable, 0 unknown' "$WLOG" && ok "H1 the summary says 1 of 2 repos readable" \
  || bad "H1 summary: $(cat "$WLOG" 2>/dev/null)"
grep -q 'example-org/x.*unreadable 404' "$T/check.err" && ok "H1 the line goes to stderr too (the Fly log)" || bad "H1 stderr: $(cat "$T/check.err")"
[ "$(grep -c . "$T/alerts.txt")" = 1 ] && [ "$(nalert px)" = 1 ] && grep -q -- '--severity warn' "$T/alerts.txt" \
  && grep -q 'example-org/x' "$T/alerts.txt" && ok "H1 one warn alert, id lane-run-repo-unreadable-px, naming the repo" \
  || bad "H1 alerts: $(cat "$T/alerts.txt")"
[ "$(skipjson)" = '["px."]' ] && ok "H1 lrr_skip_json prints [\"px.\"]" || bad "H1 json: $(skipjson)"
[ "$(grep -c -- '-i -X GET repos/example-org/x$' "$T/gh-calls.txt")" = 1 ] && [ "$(grep -c -- '-i -X GET repos/example-org/y$' "$T/gh-calls.txt")" = 1 ] \
  && ok "H1 one classified REST read per repo" || bad "H1 gh calls: $(cat "$T/gh-calls.txt")"
grep -q 'tok-fixture' "$WLOG" "$T/alerts.txt" "$T/check.err" && bad "H1 a token value reached a log" || ok "H1 no token value in the log, stderr or alert"

# ============================================================================
echo "H2: transient errors are unknown, a 401 is unreadable"
for m in 403rl:403-rate-limit none:000-network 502:502-; do
  reset "${m%%:*}" 200
  check
  [ -f "$SKIP" ] && [ ! -s "$SKIP" ] && [ "$(skipjson)" = '[]' ] && ok "H2 ${m%%:*}: the skip file is empty, nothing refused" \
    || bad "H2 ${m%%:*}: skip file '$(cat "$SKIP" 2>/dev/null)' json $(skipjson)"
  grep -q "example-org/x.*unknown ${m#*:}" "$WLOG" && ok "H2 ${m%%:*}: logged unknown ${m#*:}" || bad "H2 ${m%%:*}: log $(cat "$WLOG" 2>/dev/null)"
  grep -q 'repo check: 1 of 2 repos readable, 0 unreadable, 1 unknown' "$WLOG" && ok "H2 ${m%%:*}: the summary counts it unknown" \
    || bad "H2 ${m%%:*}: summary $(cat "$WLOG" 2>/dev/null)"
  [ ! -s "$T/alerts.txt" ] && ok "H2 ${m%%:*}: no alert" || bad "H2 ${m%%:*}: alerts $(cat "$T/alerts.txt")"
done
reset 401 200
check
[ "$(cat "$SKIP" 2>/dev/null)" = "px." ] && grep -q 'example-org/x.*unreadable 401-auth' "$WLOG" && [ "$(nalert px)" = 1 ] \
  && ok "H2 401: unreadable 401-auth, refused, one alert" || bad "H2 401: skip '$(cat "$SKIP" 2>/dev/null)' log $(cat "$WLOG" 2>/dev/null)"

# ============================================================================
echo "H3: the real worker refuses the px row at claim and runs the py row"
reset 404 200
H12=aaaabbbbcccc
IDX=$(enq merge-conductor-pr "px.1.$H12" bin/ok.sh)
IDY=$(enq merge-conductor-pr "py.2.$H12" bin/ok.sh)
"$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/work.out" 2>&1; WRC=$?
[ "$WRC" = 0 ] && ok "H3 the loop exits 0" || bad "H3 rc=$WRC $(cat "$T/work.out")"
RX=$(drow "$IDX"); RY=$(drow "$IDY")
[ "$(jq -r .status <<<"$RX")" = queued ] && [ "$(jq -r .attempts <<<"$RX")" = 0 ] && [ "$(jq -r .claimed_by <<<"$RX")" = null ] \
  && ok "H3 the px row stays queued, attempts 0, no claimer" || bad "H3 px row: $RX"
[ "$(jq -r .status <<<"$RY")" = done ] && [ "$(jq -r .rc <<<"$RY")" = 0 ] && [ "$(jq -r .prof_line <<<"$RY")" = "PROF ok x=1" ] \
  && ok "H3 the py row ran: done rc 0" || bad "H3 py row: $RY"
CLAIMS=$(grep '/api/lane-runs/claim' "$T/curl-calls.txt")
[ -n "$CLAIMS" ] && grep -q '"skip_prefixes":\["px."\]' <<<"$CLAIMS" \
  && ok "H3 the claim body carries skip_prefixes [\"px.\"]" || bad "H3 claims: $(grep claim "$T/curl-calls.txt")"
grep -q 'unreadable 404' "$T/work.out" && ok "H3 the worker's stderr carries the check line" || bad "H3 stderr: $(cat "$T/work.out")"

# ============================================================================
echo "H4: the prof line names the head-read error"
HEAD40=0123456789abcdef0123456789abcdef01234567
reset 403rl 200
OUT=$("$H/bin/merge-conductor-pr.sh" px "example-org/x#7" "$HEAD40" 2>/dev/null); rc=$?
[ "$rc" = 75 ] && [ "$OUT" = "PROF mc-pr state=UNVERIFIABLE reason=head-read-rc75-403-rate-limit-via-default deferred=-" ] \
  && ok "H4 403 rate limit: reason=head-read-rc75-403-rate-limit-via-default, exit 75" || bad "H4 rc=$rc out=$OUT"
reset none 200
OUT=$("$H/bin/merge-conductor-pr.sh" px "example-org/x#7" "$HEAD40" 2>/dev/null); rc=$?
[ "$rc" = 75 ] && [ "$OUT" = "PROF mc-pr state=UNVERIFIABLE reason=head-read-rc75-000-network-via-default deferred=-" ] \
  && ok "H4 no status line: reason=head-read-rc75-000-network-via-default, exit 75" || bad "H4 rc=$rc out=$OUT"
reset 404 200
OUT=$("$H/bin/merge-conductor-pr.sh" px "example-org/x#7" "$HEAD40" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$OUT" = "PROF mc-pr state=ABSENT reason=pr-absent deferred=-" ] \
  && ok "H4 a 404 is still ABSENT, exit 0" || bad "H4 404 rc=$rc out=$OUT"

# ============================================================================
echo "H5: the check off"
reset 404 200
IDY=$(enq merge-conductor-pr "py.3.$H12" bin/ok.sh)
LANE_RUN_REPO_CHECK=0 "$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/work.out" 2>&1; WRC=$?
[ "$WRC" = 0 ] && [ "$(jq -r .status <<<"$(drow "$IDY")")" = done ] && ok "H5 the worker runs as today" || bad "H5 rc=$WRC row $(drow "$IDY")"
[ ! -s "$T/gh-calls.txt" ] && ok "H5 no gh call" || bad "H5 gh calls: $(cat "$T/gh-calls.txt")"
[ ! -e "$SKIP" ] && ok "H5 no skip file" || bad "H5 skip file exists"
CLAIMS=$(grep '/api/lane-runs/claim' "$T/curl-calls.txt")
[ -n "$CLAIMS" ] && ! grep -q skip_prefixes <<<"$CLAIMS" \
  && ok "H5 the claim body has no skip_prefixes" || bad "H5 claims: $(grep claim "$T/curl-calls.txt")"
[ ! -s "$T/alerts.txt" ] && ok "H5 no alert" || bad "H5 alerts: $(cat "$T/alerts.txt")"
en() { ( . "$H/bin/lib/lane-run-repos.sh" || exit 9; lrr_enabled ); }
( unset LANE_RUN_REPO_CHECK LANE_RUN_CODE_SYNC; en ); r1=$?
( unset LANE_RUN_REPO_CHECK; LANE_RUN_CODE_SYNC=1 en ); r2=$?
( LANE_RUN_REPO_CHECK=0 LANE_RUN_CODE_SYNC=1 en ); r3=$?
[ "$r1" = 1 ] && ok "H5 unset, no LANE_RUN_CODE_SYNC: off" || bad "H5 unset rc=$r1"
[ "$r2" = 0 ] && ok "H5 LANE_RUN_CODE_SYNC=1 alone: on (the lane-run machine)" || bad "H5 code sync rc=$r2"
[ "$r3" = 1 ] && ok "H5 LANE_RUN_REPO_CHECK=0 wins over LANE_RUN_CODE_SYNC=1" || bad "H5 override rc=$r3"

# ============================================================================
echo "H6: a shared repo is read once and refuses both projects; repo - is not read"
printf '%spz example-org/x - - 2 box-pz 192.0.2.3\npn - - - 2 box-pn 192.0.2.4\n' "$FLEET" > "$H/fleet.conf"
reset 404 200
check
[ "$(sort "$SKIP" 2>/dev/null | tr '\n' ' ')" = "px. pz. " ] && ok "H6 the skip file holds px. and pz." || bad "H6 skip: $(cat "$SKIP" 2>/dev/null)"
[ "$(grep -c -- '-i -X GET repos/example-org/x$' "$T/gh-calls.txt")" = 1 ] && ok "H6 example-org/x read once" || bad "H6 gh: $(cat "$T/gh-calls.txt")"
[ "$(nalert px)" = 1 ] && [ "$(nalert pz)" = 1 ] && ok "H6 one alert per refused project" || bad "H6 alerts: $(cat "$T/alerts.txt")"
grep -q 'repo check: 1 of 2 repos readable, 1 unreadable, 0 unknown' "$WLOG" && ok "H6 the summary counts distinct repos" || bad "H6 summary: $(cat "$WLOG")"
[ "$(skipjson | jq -c 'sort')" = '["px.","pz."]' ] && ok "H6 lrr_skip_json prints both" || bad "H6 json $(skipjson)"
printf '%s' "$FLEET" > "$H/fleet.conf"

# ============================================================================
echo "H7: fleet-conf.sh fails"
H7="$T/h7"; cp -a "$H" "$H7"
printf '#!/bin/bash\nexit 1\n' > "$H7/bin/fleet-conf.sh"
mkdir -p "$H7/state/lane-run-worker"; echo "py." > "$H7/state/lane-run-worker/skip-prefixes"; rm -f "$H7/logs/lane-run-worker.log"
reset 404 200
( export HARNESS="$H7" FLEET_CONF="$H7/fleet.conf"; . "$H7/bin/lib/lane-run-repos.sh" || exit 9; lrr_check ) > /dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$H7/state/lane-run-worker/skip-prefixes" ] && ok "H7 rc 0 and no skip file (the old one removed)" \
  || bad "H7 rc=$rc skip: $(cat "$H7/state/lane-run-worker/skip-prefixes" 2>/dev/null)"
[ "$(grep -c 'repo check' "$H7/logs/lane-run-worker.log" 2>/dev/null)" = 1 ] && grep -q 'repo check: fleet-conf.sh' "$H7/logs/lane-run-worker.log" \
  && ok "H7 one log line names fleet-conf.sh" || bad "H7 log: $(cat "$H7/logs/lane-run-worker.log" 2>/dev/null)"
[ ! -s "$T/gh-calls.txt" ] && [ ! -s "$T/alerts.txt" ] && ok "H7 no gh call, no alert" || bad "H7 gh/alerts"
[ "$( export HARNESS="$H7"; . "$H7/bin/lib/lane-run-repos.sh" && lrr_skip_json)" = '[]' ] && ok "H7 lrr_skip_json prints []" || bad "H7 json"

# ============================================================================
echo "H8: a refused row of head A does not block head B"
reset 404 200
HA=aaaa1111bbbb2222cccc3333dddd4444eeee5555; HB=ffff6666aaaa7777bbbb8888cccc9999dddd0000
KA="px.8.${HA:0:12}"; KB="px.8.${HB:0:12}"
IDA=$(enq merge-conductor-pr "$KA" bin/ok.sh)
"$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/work.out" 2>&1
[ "$(jq -r .status <<<"$(drow "$IDA")")" = queued ] && [ "$(jq -r .attempts <<<"$(drow "$IDA")")" = 0 ] \
  && ok "H8 setup: the head A row is refused and stays queued" || bad "H8 setup: $(drow "$IDA") $(cat "$T/work.out")"
# fe [VAR=value...] <head> — mc_fly_enqueue for PR #8 of px in the hub's shell; prints "rc<n> <other>".
fe() { ( env "${@:1:$#-1}" bash -c '. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1; . "$HARNESS/bin/lib/mc/fly-workers.sh" || exit 9
         mc_fly_enqueue px example-org/x 8 "$1"; r=$?; printf "rc%s %s" "$r" "$MC_FLY_OTHER"' _ "${@: -1}" ) 2>/dev/null; }
OUT=$(fe MC_FLY_QUEUE_STALE_S=600 "$HB")
[ "$OUT" = "rc4 $KA" ] && ok "H8 control: inside the stale window the A row still blocks B (rc 4)" || bad "H8 control: '$OUT'"
OUT=$(fe MC_FLY_QUEUE_STALE_S=0 "$HB")
[ "$OUT" = "rc0 " ] && ok "H8 past the stale window B is enqueued (rc 0)" || bad "H8 past stale: '$OUT' (want rc0)"
NB=$("$REAL_CURL" -sS "$JOBS_URL/__lane_runs" | jq --arg k "$KB" '[.rows[] | select(.project == $k and .status == "queued")] | length')
[ "$NB" = 1 ] && ok "H8 one queued row for head B" || bad "H8 head B rows: $NB"
OUT=$(fe MC_FLY_QUEUE_STALE_S=0 "$HB")
[ "${OUT%% *}" = rc8 ] && ok "H8 the next tick hands head B to the hub (rc 8, no-capacity)" || bad "H8 next tick: '$OUT' (want rc8)"

# setting <key> <value> — the fixture's settings row.
setting() { "$REAL_CURL" -sS -X PUT -H 'content-type: application/json' -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$JOBS_URL/__setting" >/dev/null; }
# feo <pr> <head> — mc_fly_enqueue in the hub's shell with MC_FLY_QUEUE_STALE_S=1; prints "rc<n> <stale>".
feo() { ( MC_FLY_QUEUE_STALE_S=1 bash -c '. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1; . "$HARNESS/bin/lib/mc/fly-workers.sh" || exit 9
         mc_fly_enqueue px example-org/x "$1" "$2"; r=$?; printf "rc%s %s" "$r" "$MC_FLY_STALE"' _ "$1" "$2" ) 2>/dev/null; }
# past_wait — wait until 2 clock seconds have passed (the fixture's jobs worker
# reads the same clock), so a row enqueued before the call waited past
# lane_run.refused_max_wait_s=1. A bounded loop on the condition, at most 50 polls.
past_wait() { local e n=0; e=$(( $(date -u +%s) + 2 )); while [ "$(date -u +%s)" -lt "$e" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; }
livec() { "$REAL_CURL" -sS "$JOBS_URL/__lane_runs" | jq --arg p "$1" '[.rows[] | select((.project | startswith($p)) and (.status == "queued" or .status == "claimed"))] | length'; }
# Past lane_run.refused_max_wait_s (1 s here) the next refusing claim ends rows A and B.
setting lane_run.refused_max_wait_s 1
past_wait
"$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/work.out" 2>&1
RA=$(drow "$IDA")
[ "$(jq -r .status <<<"$RA")" = died ] && [[ $(jq -r .prof_line <<<"$RA") == "withdrawn refused-at-claim machine=m1 "* ]] \
  && ok "H8 row A is no longer queued: died, withdrawn refused-at-claim" || bad "H8 row A: $RA"
[ "$(livec px.8.)" = 0 ] && ok "H8 no live row of PR #8 is left" || bad "H8 live rows of px.8.: $(livec px.8.)"
OUT=$(feo 8 "$HB")
[ "$OUT" = "rc8 withdrawn" ] && ok "H8 the hub reads the withdrawn B row as no-capacity (rc 8), not a machine failure" || bad "H8 withdrawn B: '$OUT' (want rc8 withdrawn)"

echo "H9: 3 pushes on an unreadable repo leave at most 1 live row"
MAXLIVE=0; H9OK=1
for HH in 1111aaaa2222bbbb3333cccc4444dddd5555eeee 6666ffff7777aaaa8888bbbb9999cccc0000dddd abab1212cdcd3434efef5656abab7878cdcd9090; do
  OUT=$(feo 9 "$HH")
  [ "${OUT%% *}" = rc0 ] || { H9OK=0; bad "H9 head ${HH:0:12}: the hub did not enqueue it: '$OUT'"; }
  N=$(livec px.9.); [ "$N" -gt "$MAXLIVE" ] && MAXLIVE=$N
  past_wait
  "$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/work.out" 2>&1
  N=$(livec px.9.); [ "$N" -gt "$MAXLIVE" ] && MAXLIVE=$N
done
[ "$H9OK" = 1 ] && ok "H9 the hub enqueued each of the 3 heads (rc 0)"
[ "$MAXLIVE" -le 1 ] && ok "H9 at most 1 live row of PR #9 at any step (max $MAXLIVE)" || bad "H9 live rows of px.9. reached $MAXLIVE (want <= 1)"
[ "$(livec px.9.)" = 0 ] && ok "H9 after the last refusing claim no live row of PR #9 is left" || bad "H9 live rows at the end: $(livec px.9.)"
ND=$("$REAL_CURL" -sS "$JOBS_URL/__lane_runs" | jq '[.rows[] | select((.project | startswith("px.9.")) and .status == "died" and (.prof_line | startswith("withdrawn refused-at-claim ")))] | length')
[ "$ND" = 3 ] && ok "H9 the 3 rows ended died, withdrawn" || bad "H9 withdrawn rows: $ND (want 3)"

echo "lane-run-head-read: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
