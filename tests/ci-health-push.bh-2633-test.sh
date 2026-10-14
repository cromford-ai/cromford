#!/bin/bash
# tests/ci-health-push.bh-2633-test.sh — the box side of BH-2633 (BH-2517.2):
# bin/ci-minutes-watch.sh pushes each repo's minutes snapshot and
# bin/testhost-tick.sh pushes the runner-pool snapshot to PUT /api/ci-health.
#
# Both lanes run for real against a scratch $HARNESS. Their jobs-client.sh is a
# COPY OF THE REAL ONE (plus bin/lib/jobs/*.sh), so the real ci_health_put builds
# the body; only _jobs_req is swapped for a recorder whose rc is FAKE_JOBS_RC.
# Assertions are on the recorded requests, the lane's rc, its log and the page
# it sends, never on the lanes' source text.
#
#   M1  one PUT per readable repo, payload.est_24h = latest.json's .est, and no
#       extra GitHub read
#   M2  --dry-run pushes nothing
#   M3  an unread repo is {unread:true}, never est_24h 0
#   M4  a failed push: lane rc 0, ONE log line, the page still fires
#   M5  no jobs client at all: rc 0, no ci-health log line
#   R1  rc 0 pushes the pool's counts with rc 0
#   R2  rc 1 pushes the counts with rc 1
#   R3  rc 2 pushes {unreadable:true, rc:2}, never total 0, to CI_RUNNERS_SLUG
#   R4  a jobs client with no ci_health_put: no push, no push log line
#   R5  a failed push on rc 1 leaves the alert rows exactly as without it
#   R6  rc 0 with a body that does not parse pushes nothing, logs once
#   R7  CI_RUNNERS_ALERT_HOLD_MIN=0 pushes nothing
#
# Run from anywhere: tests/ci-health-push.bh-2633-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

# The recording jobs client: the real client, then _jobs_req replaced. Written
# into <bin>/jobs-client.sh with the real one beside it as jobs-client.real.sh.
install_client() { # install_client <bin-dir> [extra stub text]
  mkdir -p "$1/lib/jobs"
  cp "$DIR/bin/jobs-client.sh" "$1/jobs-client.real.sh"
  cp "$DIR"/bin/lib/jobs/*.sh "$1/lib/jobs/"
  cat > "$1/jobs-client.sh" <<'STUB'
. "$(dirname "${BASH_SOURCE[0]}")/jobs-client.real.sh" || return 1
_jobs_req() { # records <method> <path> <body>, one line per call
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$HARNESS/jobs-reqs.txt"
  return "${FAKE_JOBS_RC:-0}"
}
STUB
  [ -n "${2:-}" ] && printf '%s\n' "$2" >> "$1/jobs-client.sh"
  return 0
}
puts() { grep '^PUT /api/ci-health ' "$1/jobs-reqs.txt" 2>/dev/null | sed 's#^PUT /api/ci-health ##'; }
nputs() { puts "$1" | awk 'NF' | wc -l | tr -d ' '; }

# ════════════════════════ bin/ci-minutes-watch.sh ════════════════════════════
HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$HH/fx" "$T/stub"
cp "$DIR/bin/ci-minutes-watch.sh" "$DIR/bin/fleet-conf.sh" "$HH/bin/"
cp "$DIR/bin/lib/gh-ci-read.sh" "$DIR/bin/lib/page-critical.sh" "$HH/bin/lib/"
cat > "$HH/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$HARNESS/beats.txt"
SH
chmod +x "$HH/bin/beat.sh"
cat > "$HH/fleet.conf" <<'CONF'
a     Acme/a   - - 1 box-a 10.0.0.1
b     Acme/b   - - 2 box-a 10.0.0.1
c     Acme/c   - - 4 box-a 10.0.0.1
CONF
# The fake gh from tests/ci-minutes-watch.k1-test.sh: fixture files, -q applied
# with jq, every call recorded.
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
shift
P=""; Q=""; PG=1
while [ $# -gt 0 ]; do
  case "$1" in
    -X) shift 2 ;;
    -q|--jq) Q="$2"; shift 2 ;;
    -f) case "$2" in page=*) PG="${2#page=}" ;; esac; shift 2 ;;
    *) P="$1"; shift ;;
  esac
done
echo "$P page=$PG" >> "$HARNESS/gh-calls.txt"
R=$(sed -E 's#^repos/([^/]+)/([^/]+)/.*#\1_\2#' <<<"$P")
case "$P" in
  */actions/runs/*/jobs*) ID=$(sed -E 's#.*/runs/([0-9]+)/jobs.*#\1#' <<<"$P"); F="$HARNESS/fx/$R.jobs.$ID.json" ;;
  */actions/runs) F="$HARNESS/fx/$R.runs.$PG.json" ;;
  *) exit 1 ;;
esac
[ -r "$F" ] || exit 1
if [ -n "$Q" ]; then jq -c "$Q" "$F"; else cat "$F"; fi
SH
chmod +x "$T/stub/gh"
runs() { # runs <repo_key> <count> <first-id> <wall-seconds>
  local i out="" id
  for (( i = 0; i < $2; i++ )); do
    id=$(( $3 + i ))
    out="$out${out:+,}{\"id\":$id,\"workflow_id\":1,\"run_started_at\":\"$(iso $(( 7200 + $4 )))\",\"updated_at\":\"$(iso 7200)\"}"
  done
  echo "{\"total_count\":$2,\"workflow_runs\":[$out]}" > "$HH/fx/$1.runs.1.json"
}
jobs() { # jobs <repo_key> <id> <label> <n-jobs> <secs-each>
  local i out=""
  for (( i = 0; i < $4; i++ )); do
    out="$out${out:+,}{\"labels\":[\"$3\"],\"runner_name\":\"r$i\",\"started_at\":\"$(iso $(( 7200 + $5 )))\",\"completed_at\":\"$(iso 7200)\"}"
  done
  echo "{\"jobs\":[$out]}" > "$HH/fx/$1.jobs.$2.json"
}
# Acme/a est 180 (as in the k1 suite), Acme/b est 0 (GitHub-hosted only),
# Acme/c no fixture at all -> unread.
runs Acme_a 10 100 600
for id in $(seq 100 109); do jobs Acme_a "$id" monkci-ubuntu-24.04-4 3 330; done
runs Acme_b 4 200 600
for id in $(seq 200 203); do jobs Acme_b "$id" ubuntu-latest 2 600; done

mdrive() { # mdrive [--dry-run] — env assignments come from the caller's env
  rm -f "$HH/gh-calls.txt" "$HH/beats.txt" "$HH/jobs-reqs.txt" "$HH/logs/ci-minutes-watch.log" "$HH/state/page-critical.json"
  ( export HARNESS="$HH" FLEET_CONF="$HH/fleet.conf" NOW PATH="$T/stub:$PATH" CI_MINUTES_DAY_MAX="${DAYMAX:-1000}" CI_MINUTES_BILL_MULT=1
    bash "$HH/bin/ci-minutes-watch.sh" "$@" ) >"$T/out.txt" 2>&1
  MRC=$?
}
ghcalls() { if [ -f "$HH/gh-calls.txt" ]; then wc -l < "$HH/gh-calls.txt" | tr -d ' '; else echo 0; fi; }
mlog() { cat "$HH/logs/ci-minutes-watch.log" 2>/dev/null; }

# M5 first, while the scratch tree has no jobs client: silent skip.
mdrive
BASE_GH=$(ghcalls)
[ "$MRC" = 0 ] && ok || bad "M5: no jobs client must still exit 0 (rc=$MRC)"
grep -qi 'ci-health' <<<"$(mlog)" && bad "M5: no jobs client must log nothing about ci-health: $(mlog | grep -i ci-health)" || ok
[ -s "$HH/state/ci-minutes/latest.json" ] && ok || bad "M5: latest.json must still be written"

install_client "$HH/bin"

# M1: one PUT per readable repo, est_24h from latest.json
mdrive
[ "$MRC" = 0 ] && ok || bad "M1: rc=$MRC"
P=$(puts "$HH")
for R in Acme/a Acme/b; do
  N=$(printf '%s\n' "$P" | jq -c --arg r "$R" 'select(.repo == $r)' 2>/dev/null | wc -l | tr -d ' ')
  WANT=$(jq -r --arg r "$R" '.repos[] | select(.repo == $r) | .est' "$HH/state/ci-minutes/latest.json")
  GOT=$(printf '%s\n' "$P" | jq -r --arg r "$R" 'select(.repo == $r) | .payload.est_24h' 2>/dev/null)
  MET=$(printf '%s\n' "$P" | jq -r --arg r "$R" 'select(.repo == $r) | .metric' 2>/dev/null)
  [ "$N" = 1 ] && [ -n "$WANT" ] && [ "$GOT" = "$WANT" ] && [ "$MET" = minutes ] && ok \
    || bad "M1: $R wants ONE minutes PUT with est_24h=$WANT (got n=$N est_24h=$GOT metric=$MET): $P"
done
[ "$(printf '%s\n' "$P" | jq -r 'select(.repo == "Acme/a") | .payload.est_24h')" = 180 ] && ok \
  || bad "M1: Acme/a's est_24h must be 180 (the fixture's estimate)"
printf '%s\n' "$P" | jq -e 'select(.repo == "Acme/a") | .payload | has("day_max") and has("runner_match") and has("at") and has("note")' >/dev/null 2>&1 \
  && ok || bad "M1: the payload carries note, day_max, runner_match, at: $P"
[ "$(ghcalls)" = "$BASE_GH" ] && ok || bad "M1: the push must add no GitHub read ($(ghcalls) vs $BASE_GH)"
grep -q 'ci-health' <<<"$(mlog)" && bad "M1: a successful push is silent in the log: $(mlog | grep ci-health)" || ok

# M3: the unread repo
U=$(printf '%s\n' "$P" | jq -c 'select(.repo == "Acme/c")' 2>/dev/null)
[ "$(printf '%s' "$U" | awk 'NF' | wc -l | tr -d ' ')" = 1 ] && [ "$(jq -r '.payload.unread' <<<"$U")" = true ] \
  && [ "$(jq -r '.payload | has("est_24h")' <<<"$U")" = false ] && [ "$(jq -r '.metric' <<<"$U")" = minutes ] && ok \
  || bad "M3: Acme/c (unread) must be ONE PUT of {unread:true} with no est_24h: '$U'"
[ "$(nputs "$HH")" = 3 ] && ok || bad "M1/M3: three repos, three PUTs (got $(nputs "$HH"))"

# M2: --dry-run pushes nothing
mdrive --dry-run
[ "$MRC" = 0 ] && [ "$(nputs "$HH")" = 0 ] && ok || bad "M2: --dry-run must make zero PUTs (rc=$MRC, $(nputs "$HH") PUTs)"

# M4: every push fails, over the line — rc 0, one log line, the page still goes
DAYMAX=100 FAKE_JOBS_RC=1 mdrive
[ "$MRC" = 0 ] && ok || bad "M4: a failed push must not change the lane's rc (rc=$MRC)"
[ "$(mlog | grep -c 'ci-health push:')" = 1 ] && ok || bad "M4: want ONE 'ci-health push:' log line: $(mlog | grep ci-health)"
mlog | grep 'ci-health push:' | grep -q 'push failed.*3 of 3' && mlog | grep 'ci-health push:' | grep -q 'Acme/a' \
  && ok || bad "M4: the line says the push failed, how many and which: $(mlog | grep ci-health)"
[ "$(jq -r '.severity' "$HH/beats.txt" 2>/dev/null)" = critical ] && ok || bad "M4: the page must still fire: $(cat "$HH/beats.txt" 2>/dev/null)"
[ "$(nputs "$HH")" = 3 ] && ok || bad "M4: a failure on one repo does not stop the others ($(nputs "$HH") PUTs)"

# ═══════════════════════ bin/testhost-tick.sh (cmd_ci_runners) ═══════════════
FIX="$T/fix"; TH="$T/th"
mkdir -p "$FIX/settings" "$T/fakebin" "$TH/bin/lib" "$TH/catalog" "$TH/flags" "$TH/logs" "$TH/state"
cp "$(rendered_registry)" "$TH/catalog/lanes.json"
scratch_install_closure bin/testhost-tick.sh "$TH" >/dev/null || { echo "FAIL: could not install the tick's closure"; exit 1; }
# The settings half of the client is files, as in tests/ci-runners-alert.bh-1210-test.sh.
SETTINGS_STUB='flag_sync() { return 1; }
setting_get() { [ -f "$FIX/settings/$1" ] || return 2; cat "$FIX/settings/$1"; }
setting_set() { printf "%s" "$2" > "$FIX/settings/$1"; printf "%s\n" "$1" >> "$FIX/settings-writes"; return 0; }'
install_client "$TH/bin" "$SETTINGS_STUB"
cp "$TH/bin/jobs-client.sh" "$FIX/client-real"
cat > "$TH/bin/ci-runners-status.sh" <<'STUB'
#!/bin/bash
[ -f "$FIX/ci-body" ] && cat "$FIX/ci-body"
exit "$(cat "$FIX/ci-rc" 2>/dev/null || echo 0)"
STUB
cat > "$TH/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/alert-calls"
exit 0
STUB
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$*" in
  *"machine list"*|*"machines list"*) echo '[{"id":"m1","name":"testhost-1","state":"stopped"}]' ;;
esac
exit 0
STUB
chmod +x "$T/fakebin"/* "$TH/bin/ci-runners-status.sh" "$TH/bin/lane-alert.sh"
export FIX

tdrive() { # tdrive — pool from pool(), extra env from the caller
  rm -f "$TH/jobs-reqs.txt" "$FIX/alert-calls" "$FIX/fly-calls" "$FIX/settings-writes" "$TH/logs/testhost-tick.log" "$FIX"/settings/*
  scratch_rm "$TH/state/lane-gate" >/dev/null 2>&1 || true
  printf '%s' "$((NOW - 60))" > "$FIX/settings/testhost.last_used"
  rm -f "$FIX/settings-writes"
  env PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" HARNESS="$TH" TESTHOST_APP=bh-testhost-fixture \
    CI_RUNNERS_ALERT_HOLD_MIN="${HOLD:-10}" bash "$TH/bin/testhost-tick.sh" tick >"$T/tout.txt" 2>&1
  TRC=$?
}
pool() { printf '%s\n' "$1" > "$FIX/ci-rc"; printf '%s\n' "$2" > "$FIX/ci-body"; }
tlog() { cat "$TH/logs/testhost-tick.log" 2>/dev/null; }
onlyput() { puts "$TH" | head -1; }

# R1
pool 0 '{"repo":"F/bh","label":"bh-ci","total":4,"online":3,"idle":2,"busy":1,"offline":1}'
tdrive
B=$(onlyput)
[ "$TRC" = 0 ] && [ "$(nputs "$TH")" = 1 ] && [ "$(jq -r '.repo' <<<"$B")" = F/bh ] && [ "$(jq -r '.metric' <<<"$B")" = runners ] \
  && [ "$(jq -cS '.payload' <<<"$B")" = '{"busy":1,"idle":2,"label":"bh-ci","offline":1,"online":3,"rc":0,"total":4}' ] && ok \
  || bad "R1: rc 0 pushes the counts exactly (rc=$TRC n=$(nputs "$TH")): $B"
grep -q 'ci-health' <<<"$(tlog)" && bad "R1: a successful push is silent: $(tlog | grep ci-health)" || ok

# R2
pool 1 '{"repo":"F/bh","label":"bh-ci","total":4,"online":0,"idle":0,"busy":0,"offline":4}'
tdrive
B=$(onlyput)
[ "$TRC" = 0 ] && [ "$(nputs "$TH")" = 1 ] && [ "$(jq -r '.payload.rc' <<<"$B")" = 1 ] && [ "$(jq -r '.payload.total' <<<"$B")" = 4 ] \
  && [ "$(jq -r '.payload.online' <<<"$B")" = 0 ] && ok || bad "R2: rc 1 pushes counts with rc 1: $B"
WRITES_OK=$(sort "$FIX/settings-writes" 2>/dev/null | tr '\n' ' ')

# R3
pool 2 ''
CI_RUNNERS_SLUG=F/slug tdrive
B=$(onlyput)
[ "$TRC" = 0 ] && [ "$(nputs "$TH")" = 1 ] && [ "$(jq -r '.repo' <<<"$B")" = F/slug ] \
  && [ "$(jq -cS '.payload' <<<"$B")" = '{"rc":2,"unreadable":true}' ] && ok \
  || bad "R3: rc 2 pushes {unreadable:true, rc:2} and no total, to CI_RUNNERS_SLUG: $B"
tdrive
[ "$(jq -r '.repo' <<<"$(onlyput)")" = example-org/cromford ] && ok || bad "R3: no slug set -> the status script's default repo: $(onlyput)"

# R6: rc 0, a body that does not parse: no push, one line
pool 0 'not json'
tdrive
[ "$TRC" = 0 ] && [ "$(nputs "$TH")" = 0 ] && [ "$(tlog | grep -c 'ci-health:.*did not parse')" = 1 ] && ok \
  || bad "R6: an unparsed rc-0 body pushes nothing and logs once (n=$(nputs "$TH")): $(tlog | grep ci-health)"

# R7: the check switched off makes no read and no push
pool 0 '{"repo":"F/bh","label":"bh-ci","total":4,"online":3,"idle":2,"busy":1,"offline":1}'
HOLD=0 tdrive
[ "$TRC" = 0 ] && [ "$(nputs "$TH")" = 0 ] && ok || bad "R7: HOLD_MIN=0 must push nothing ($(nputs "$TH"))"

# R5: a failed push on rc 1 leaves the alert rows as they were, and the tick goes on
pool 1 '{"repo":"F/bh","label":"bh-ci","total":4,"online":0,"idle":0,"busy":0,"offline":4}'
FAKE_JOBS_RC=1 tdrive
W=$(sort "$FIX/settings-writes" 2>/dev/null | tr '\n' ' ')
[ "$TRC" = 0 ] && [ -n "$WRITES_OK" ] && [ "$W" = "$WRITES_OK" ] && grep -Eq '^[0-9]+$' "$FIX/settings/ci_runners.empty_since" && ok \
  || bad "R5: settings writes with a failed push '$W' must equal those without '$WRITES_OK'"
[ "$(tlog | grep -c 'ci-health:.*push failed')" = 1 ] && ok || bad "R5: ONE 'push failed' line: $(tlog | grep ci-health)"
[ -s "$FIX/fly-calls" ] && ok || bad "R5: cmd_tick must carry on to the Fly half after a failed push"

# R4: a jobs client without ci_health_put
printf '%s\n' "$SETTINGS_STUB" > "$TH/bin/jobs-client.sh"
pool 0 '{"repo":"F/bh","label":"bh-ci","total":4,"online":3,"idle":2,"busy":1,"offline":1}'
tdrive
[ "$TRC" = 0 ] && [ "$(nputs "$TH")" = 0 ] && ! grep -q 'ci-health' <<<"$(tlog)" && ok \
  || bad "R4: no ci_health_put is a silent skip (rc=$TRC): $(tlog | grep ci-health)"
cp "$FIX/client-real" "$TH/bin/jobs-client.sh"

echo "ci-health-push.bh-2633: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
