#!/bin/bash
# tests/pool-testhost-route.bh-8335-test.sh — the Fly pool gives each machine
# its own short-lived route to the test host, so the selection gate runs on a
# pool build (BH-8335).
#
# THE BUG. The pool image had no flyctl and bin/fly-pool.sh shipped no Fly
# credential, so every pool build's gate.txt said
# `rc: could-not-run why=runner-rc-125`.
# THE BLOCK (lead verdict #4386, tenant-leak). The first fix shipped a cert
# from `flyctl ssh issue <org>`. That cert is org-wide: every machine in the
# org accepts it, so one project's build could open a root shell on another
# project's builder. The route is now a Fly SSH token scoped to the test-host
# app alone (`flyctl tokens create ssh -a <app> -x <h>h`), and nothing in the
# route path calls `ssh issue`.
#
# PINNED. The lib is bin/lib/pool-testhost-route.sh; flyctl and mput are PATH
# and function stubs (no network). The spawn and reuse blocks are lifted from
# the real bin/fly-pool.sh by their markers.
#   R1 ptr_hours: 6 with nothing set, 3 for a 7200 s deadline, 10 for
#      POOL_TESTHOST_TOKEN_HOURS=10, 72 for 500, and lane_knob gets the project.
#   R2 ptr_build: ONE file, testhost.env, mode 600, with exactly
#      REMOTE_GATE_TRANSPORT=fly-ssh, FLY_API_TOKEN and TESTHOST_ROUTE_EXPIRES.
#      The mint is `tokens create ssh -a <app> -x 6h -n pool-<label>`: app-
#      scoped and always with -x. No `ssh issue` call. The token is on no output.
#   R3 the lib's code names no `ssh issue`, no issue-testhost-cert.sh and no
#      deploy token, and every `tokens create` in it has -a and -x.
#   R4 the mint fails (rc 1) or prints no FlyV1 word: no file, rc 1, one reason.
#      The env credential fails and the flyctl session mints: rc 0.
#   R5 POOL_TESTHOST_ROUTE=0 or unset: no flyctl call, rc 3. The registry
#      default is 0 (the cromford row turns it on).
#   R6 ptr_push: testhost.env to /run/harness-env/testhost.env, nothing else.
#   R7 ptr_push with a failing mput: rc 1 and one say line.
#   S1 spawn block + push block: the file lands in $TMP, the push sends it,
#      and `shipped` is said only after the push returns 0.
#   S2 a failed route keeps OK, global.env and gh-token as they were.
#   S3 a failed route writes no ALERTS line; no say line, log or output in any
#      case carries the token.
#   S4 the knob off, or a pull spawn: no flyctl call.
#   S5 the reuse refresh: ptr_build then ptr_push, before the job.json.next mput.
#   D1 fly/Dockerfile's bake-flyctl block: bare ARG, bake_verify, /root/.fly/bin
#      on PATH, the flyctl_<v>_checksums.txt name, never `latest`.
#   D2 bake_deps lists flyctl, and with no row and no last bake the hub's
#      flyctl answers the version.
#   D3 fly/Dockerfile names no testhost-key, no ssh issue, no FLY_API_TOKEN.
#
# Run from anywhere: bash tests/pool-testhost-route.bh-8335-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
unset POOL_MODE TESTHOST_KEY FLY_API_TOKEN FLY_ACCESS_TOKEN REMOTE_GATE_ROUTE_ENV POOL_TESTHOST_ROUTE POOL_TESTHOST_TOKEN_HOURS LANE_REAP_DEADLINE_SECS FLY
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB="$REPO/bin/lib/pool-testhost-route.sh"
POOLSH="$REPO/bin/fly-pool.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$LIB" ] || { echo "FAIL: bin/lib/pool-testhost-route.sh does not exist"; exit 1; }

FB="$T/fakebin"; mkdir -p "$FB" "$T/h/logs" "$T/h/flags" "$T/home"
TOKEN="FlyV1 fm2_fixture-token-8335"
# flyctl: every call is logged with whether a credential was in the env.
# MINT=ok|fail|notoken|session-only. `ssh issue` writes a pair, so a route
# that still issued would show in the outdir and in the call log.
cat > "$FB/flyctl" <<STUB
#!/bin/bash
echo "\$* cred=\${FLY_ACCESS_TOKEN:+set}" >> "\$CALLS"
case "\$1 \${2:-}" in
  "ssh issue")
    shift 3; printf 'k\n' > "\$1"; printf 'c\n' > "\$1-cert.pub"; exit 0 ;;
  "tokens create")
    case "\${MINT:-ok}" in
      ok) echo "$TOKEN"; exit 0 ;;
      fail) echo "Error: fixture mint refused"; echo "$TOKEN"; exit 1 ;;
      notoken) echo "Error: fixture says nothing useful"; exit 0 ;;
      session-only) [ -n "\${FLY_ACCESS_TOKEN:-}" ] && { echo "Error: not authorized"; exit 1; }
                    echo "$TOKEN"; exit 0 ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$FB/flyctl"

# run_lib <script> [env...] — the lib in a clean shell.
run_lib() {
  local script=$1; shift
  : > "$T/calls"
  LOUT=$(cd "$T" && env -i PATH="$FB:/usr/bin:/bin" HOME="$T/home" HARNESS="$T/h" JOBS_URL= CALLS="$T/calls" \
    TESTHOST_APP=fixture-app TESTHOST_ORG=fixture-org FLY_ACCESS_TOKEN=tok-fixture-pool "$@" \
    bash -c '. "$1"; '"$script" _ "$LIB" 2>"$T/lerr"); LRC=$?
  LERR=$(cat "$T/lerr")
  ALLOUT="$ALLOUT$LOUT$LERR$(grep '^SAY' "$T/calls" 2>/dev/null)"
}
ALLOUT=""
newout() { local d; d=$(mktemp -d "$T/out-XXXXXX"); chmod 700 "$d"; echo "$d"; }
mode() { stat -c %a "$1" 2>/dev/null; }
MINT_OK='tokens create ssh -a fixture-app -x 6h -n pool-BH-8335'

# ── R1 ──────────────────────────────────────────────────────────────────────
run_lib 'ptr_hours'; [ "$LOUT" = 6 ] && ok || bad "R1: no rows: want 6, got '$LOUT'"
run_lib 'ptr_hours' LANE_REAP_DEADLINE_SECS=7200; [ "$LOUT" = 3 ] && ok || bad "R1: 7200 s: want 3, got '$LOUT'"
run_lib 'ptr_hours' POOL_TESTHOST_TOKEN_HOURS=10; [ "$LOUT" = 10 ] && ok || bad "R1: knob 10: want 10, got '$LOUT'"
run_lib 'ptr_hours' POOL_TESTHOST_TOKEN_HOURS=500; [ "$LOUT" = 72 ] && ok || bad "R1: knob 500: want 72, got '$LOUT'"
run_lib 'lane_knob() { echo "$*" >> "$CALLS"; case "$2" in LANE_REAP_DEADLINE_SECS) echo 10800 ;; *) echo 0 ;; esac; }; ptr_hours' P=fixture-proj
[ "$LOUT" = 4 ] && ok || bad "R1: lane_knob 10800 s: want 4, got '$LOUT'"
grep -qx 'fly-pool POOL_TESTHOST_TOKEN_HOURS fixture-proj' "$T/calls" && grep -qx 'lane-reaper LANE_REAP_DEADLINE_SECS fixture-proj' "$T/calls" && ok \
  || bad "R1: lane_knob was not asked with the project: $(cat "$T/calls")"

# ── R2 ──────────────────────────────────────────────────────────────────────
O=$(newout)
run_lib "ptr_build '$O' BH-8335" POOL_TESTHOST_ROUTE=1
[ "$LRC" = 0 ] && ok || bad "R2: rc $LRC: $LERR"
[ "$(mode "$O/testhost.env")" = 600 ] && ok || bad "R2: testhost.env mode '$(mode "$O/testhost.env")', want 600"
[ "$(ls -A "$O" | tr '\n' ' ')" = "testhost.env " ] && ok || bad "R2: want only testhost.env in the outdir: $(ls -A "$O" | tr '\n' ' ')"
KEYS=$(sed 's/=.*//' "$O/testhost.env" 2>/dev/null | tr '\n' ' ')
[ "$KEYS" = "REMOTE_GATE_TRANSPORT FLY_API_TOKEN TESTHOST_ROUTE_EXPIRES " ] && ok || bad "R2: testhost.env keys: '$KEYS'"
grep -qx 'REMOTE_GATE_TRANSPORT=fly-ssh' "$O/testhost.env" && ok || bad "R2: the transport is not fly-ssh"
grep -qx "FLY_API_TOKEN=$TOKEN" "$O/testhost.env" && ok || bad "R2: the minted token is not in testhost.env"
grep -qE '^TESTHOST_ROUTE_EXPIRES=[0-9]+$' "$O/testhost.env" && ok || bad "R2: no TESTHOST_ROUTE_EXPIRES epoch"
MINTS=$(grep '^tokens create' "$T/calls")
[ "$(grep -c . <<<"$MINTS")" = 1 ] && ok || bad "R2: want one mint, got: $MINTS"
case "$MINTS" in "$MINT_OK cred=set") ok ;; *) bad "R2: the mint is not an app-scoped ssh token with -x: $MINTS" ;; esac
grep -q -- ' -a fixture-app ' <<<"$MINTS" && grep -qE -- ' -x [0-9]+h ' <<<"$MINTS" && ok || bad "R2: the mint lacks -a <app> or -x <h>h: $MINTS"
grep -q 'deploy' <<<"$MINTS" && bad "R2: a deploy token was minted: $MINTS" || ok
grep -q '^ssh issue' "$T/calls" && bad "R2: the route still called flyctl ssh issue (org-wide cert): $(grep '^ssh' "$T/calls")" || ok
grep -q 'fm2_fixture' <<<"$LOUT$LERR" && bad "R2: the token reached stdout/stderr" || ok

# ── R3: no org-wide path left in the code ───────────────────────────────────
LIBCODE=$(grep -vE '^[[:space:]]*#' "$LIB")
grep -qE 'ssh[[:space:]]+issue' <<<"$LIBCODE" && bad "R3: the lib's code calls ssh issue" || ok
grep -q 'issue-testhost-cert' <<<"$LIBCODE" && bad "R3: the lib's code runs issue-testhost-cert.sh" || ok
grep -qE 'tokens[[:space:]]+create[[:space:]]+deploy' <<<"$LIBCODE" && bad "R3: the lib's code mints a deploy token" || ok
TC=$(grep -E 'tokens[[:space:]]+create' <<<"$LIBCODE")
[ -n "$TC" ] && ok || bad "R3: no tokens create in the lib"
while IFS= read -r l; do
  [ -n "$l" ] || continue
  grep -qE -- '(^|[[:space:]])-a[[:space:]]' <<<"$l" && grep -qE -- '(^|[[:space:]])-x[[:space:]]' <<<"$l" && ok \
    || bad "R3: a tokens create line has no -a or no -x: $l"
done <<<"$TC"

# ── R4 ──────────────────────────────────────────────────────────────────────
for m in fail notoken; do
  O=$(newout)
  run_lib "ptr_build '$O' BH-8335" POOL_TESTHOST_ROUTE=1 MINT=$m
  [ "$LRC" = 1 ] && ok || bad "R4 $m: rc $LRC, want 1"
  [ -z "$(ls -A "$O")" ] && ok || bad "R4 $m: files left: $(ls -A "$O" | tr '\n' ' ')"
  case "$m" in
    fail) grep -qx 'testhost route: not shipped (token mint rc 1)' <<<"$LERR" && ok || bad "R4 fail: reason: $LERR" ;;
    notoken) grep -qx 'testhost route: not shipped (token empty)' <<<"$LERR" && ok || bad "R4 notoken: reason: $LERR" ;;
  esac
  grep -q 'fm2_fixture' <<<"$LOUT$LERR" && bad "R4 $m: the token reached an output" || ok
done
O=$(newout)
run_lib "ptr_build '$O' BH-8335" POOL_TESTHOST_ROUTE=1 MINT=session-only
[ "$LRC" = 0 ] && grep -qx "FLY_API_TOKEN=$TOKEN" "$O/testhost.env" && ok || bad "R4 session: the session mint did not ship (rc $LRC): $LERR"
[ "$(grep '^tokens create' "$T/calls" | tr '\n' '|')" = "$MINT_OK cred=set|$MINT_OK cred=|" ] && ok \
  || bad "R4 session: want the env mint then the session mint: $(grep tokens "$T/calls")"

# ── R5 ──────────────────────────────────────────────────────────────────────
for kv in POOL_TESTHOST_ROUTE=0 POOL_TESTHOST_ROUTE=; do
  O=$(newout)
  run_lib "ptr_build '$O' BH-8335" "$kv"
  [ "$LRC" = 3 ] && ok || bad "R5 $kv: rc $LRC, want 3"
  [ ! -s "$T/calls" ] && ok || bad "R5 $kv: flyctl was called with the knob off: $(cat "$T/calls")"
  [ -z "$(ls -A "$O")" ] && [ -z "$LERR" ] && ok || bad "R5 $kv: knob off left files or printed: $LERR"
done
[ "$(jq -r .default "$REPO/catalog/lanes.d/fly-pool.knobs.d/POOL_TESTHOST_ROUTE.json" 2>/dev/null)" = 0 ] && ok \
  || bad "R5: the POOL_TESTHOST_ROUTE registry default is not 0 (the fleet must not mint for projects with no gate)"

# ── R6 / R7 ─────────────────────────────────────────────────────────────────
O=$(newout); echo x > "$O/testhost.env"
MPUT='mput() { echo "$1 $2 $3" >> "$CALLS"; [ "${MPUT_FAIL:-}" != "$(basename "$3")" ]; }; say() { echo "SAY $*" >> "$CALLS"; }; '
run_lib "${MPUT}ptr_push m-fixture '$O'"
[ "$LRC" = 0 ] && ok || bad "R6: rc $LRC"
[ "$(grep -v '^SAY' "$T/calls" | tr '\n' '|')" = "m-fixture $O/testhost.env /run/harness-env/testhost.env|" ] && ok \
  || bad "R6: pushes: $(cat "$T/calls")"
run_lib "${MPUT}ptr_push m-fixture '$O'" MPUT_FAIL=testhost.env
[ "$LRC" = 1 ] && ok || bad "R7: rc $LRC, want 1"
[ "$(grep -c '^SAY ' "$T/calls")" = 1 ] && grep -q '^SAY m-fixture: testhost route push FAILED' "$T/calls" && ok \
  || bad "R7: want one say line: $(cat "$T/calls")"

# ── S: the real spawn blocks ────────────────────────────────────────────────
BLOCK=$(sed -n '/^ *# >>> pool testhost route$/,/^ *# <<< pool testhost route$/p' "$POOLSH")
PUSHB=$(sed -n '/^ *# >>> pool testhost route push$/,/^ *# <<< pool testhost route push$/p' "$POOLSH")
REFR=$(sed -n '/^ *# >>> pool testhost route refresh$/,/^ *# <<< pool testhost route refresh$/p' "$POOLSH")
[ -n "$BLOCK" ] && grep -q 'ptr_build' <<<"$BLOCK" && ok || bad "S: the 'pool testhost route' block is not in bin/fly-pool.sh"
[ -n "$PUSHB" ] && grep -q 'ptr_push' <<<"$PUSHB" && ok || bad "S: the 'pool testhost route push' block is not in bin/fly-pool.sh"
[ -n "$REFR" ] && grep -q 'ptr_push' <<<"$REFR" && ok || bad "S: the 'pool testhost route refresh' block is not in bin/fly-pool.sh"
# The lib is sourced by the pool tick (a removed source line ships no route).
grep -qE '^\. "\$HARNESS/bin/lib/pool-testhost-route\.sh"' "$POOLSH" && ok || bad "S: bin/fly-pool.sh does not source the lib"
printf '%s\n' "$BLOCK" > "$T/spawn-block.sh"; printf '%s\n' "$PUSHB" > "$T/push-block.sh"; printf '%s\n' "$REFR" > "$T/refresh-block.sh"
STUBS='say() { echo "SAY $*" >> "$CALLS"; }; mput() { echo "MPUT $1 $3" >> "$CALLS"; [ "${MPUT_FAIL:-0}" != 1 ]; }; '
# spawn <env...> — TMP holds a bundle as the swap block leaves it; the spawn
# block runs, then (with MID) the push block.
spawn() {
  S_TMP=$(newout); printf 'GH_TOKEN=x\n' > "$S_TMP/global.env"; printf 'ghs_fixture\n' > "$S_TMP/gh-token"
  run_lib "${STUBS}OK=1; KEY=BH-8335; PULL=\${PULL:-0}; TMP='$S_TMP'; MID=m-fixture
    . '$T/spawn-block.sh'
    echo \"after-spawn OK=\$OK\" >> \"\$CALLS\"
    . '$T/push-block.sh'
    echo \"after-push OK=\$OK\" >> \"\$CALLS\"" "$@"
}
spawn POOL_TESTHOST_ROUTE=1
[ "$LRC" = 0 ] && ok || bad "S1: rc $LRC: $LERR"
[ "$(mode "$S_TMP/testhost.env")" = 600 ] && ok || bad "S1: $S_TMP/testhost.env not written mode 600"
[ ! -e "$S_TMP/testhost-key" ] && [ ! -e "$S_TMP/testhost-key-cert.pub" ] && ok || bad "S1: the spawn still wrote an ssh key or cert"
SEQ=$(grep -E '^(MPUT|SAY|after-)' "$T/calls" | sed 's/(expires .*)/(expires X)/' | tr '\n' '|')
[ "$SEQ" = "after-spawn OK=1|MPUT m-fixture /run/harness-env/testhost.env|SAY BH-8335: testhost route shipped to m-fixture (expires X)|after-push OK=1|" ] && ok \
  || bad "S1: sequence: $SEQ"
grep -q '^ssh issue' "$T/calls" && bad "S1: the spawn called flyctl ssh issue" || ok
spawn POOL_TESTHOST_ROUTE=1 MPUT_FAIL=1
grep -q 'shipped' "$T/calls" && bad "S1: 'shipped' said after a failed push: $(cat "$T/calls")" || ok
grep -q '^after-push OK=1$' "$T/calls" && ok || bad "S1: a failed route push changed OK"

spawn POOL_TESTHOST_ROUTE=1 MINT=fail
grep -q '^after-push OK=1$' "$T/calls" && ok || bad "S2: a failed route changed OK: $(cat "$T/calls")"
[ "$(cat "$S_TMP/global.env")" = "GH_TOKEN=x" ] && [ "$(cat "$S_TMP/gh-token")" = "ghs_fixture" ] && ok || bad "S2: the bundle changed"
[ ! -e "$S_TMP/testhost.env" ] && ok || bad "S2: a route file left after a failure"
grep -q '^MPUT' "$T/calls" && bad "S2: a failed route pushed something" || ok
[ "$(grep -c '^SAY BH-8335: testhost route: not shipped (token mint rc 1) — the selection gate will record could-not-run$' "$T/calls")" = 1 ] && ok \
  || bad "S2: want one not-shipped say line: $(grep SAY "$T/calls")"
[ ! -e "$T/h/logs/ALERTS.log" ] && ok || bad "S3: a failed route wrote ALERTS: $(cat "$T/h/logs/ALERTS.log")"
spawn POOL_TESTHOST_ROUTE=1 MINT=notoken
[ ! -e "$T/h/logs/ALERTS.log" ] && ok || bad "S3: an empty mint wrote ALERTS"
grep -q 'not shipped (token empty)' "$T/calls" && ok || bad "S3: the empty mint was not said"

spawn POOL_TESTHOST_ROUTE=0
grep -qE '^(ssh|tokens)' "$T/calls" && bad "S4: knob off still called flyctl: $(cat "$T/calls")" || ok
grep -q '^SAY' "$T/calls" && bad "S4: knob off said something: $(grep SAY "$T/calls")" || ok
spawn POOL_TESTHOST_ROUTE=1 PULL=1
grep -qE '^(ssh|tokens)' "$T/calls" && bad "S4: a pull spawn called flyctl" || ok

# S5: the reuse refresh, then the order inside next_job_or_destroy.
run_lib "${STUBS}MID=m-fixture; NKEY=BH-8336
  . '$T/refresh-block.sh'" POOL_TESTHOST_ROUTE=1
SEQ=$(grep -E '^(MPUT|SAY)' "$T/calls" | sed 's/(expires .*)/(expires X)/' | tr '\n' '|')
[ "$SEQ" = "MPUT m-fixture /run/harness-env/testhost.env|SAY BH-8336: testhost route refreshed on m-fixture (expires X)|" ] && ok \
  || bad "S5: refresh sequence: $SEQ"
grep -q -- 'tokens create ssh -a fixture-app -x 6h -n pool-BH-8336 ' "$T/calls" && ok || bad "S5: the refresh did not mint an app-scoped token for its key: $(grep tokens "$T/calls")"
run_lib "${STUBS}MID=m-fixture; NKEY=BH-8336
  . '$T/refresh-block.sh'" POOL_TESTHOST_ROUTE=1 MINT=fail
grep -q '^MPUT' "$T/calls" && bad "S5: a failed refresh pushed" || ok
grep -q "^SAY BH-8336: testhost route: not shipped (token mint rc 1) — m-fixture keeps the route it has$" "$T/calls" && ok || bad "S5: refresh failure line: $(grep SAY "$T/calls")"
NJF=$(awk '/^next_job_or_destroy\(\)/{f=1} f&&/^}/{exit} f' "$POOLSH")
RL=$(grep -n '# >>> pool testhost route refresh' <<<"$NJF" | cut -d: -f1)
JL=$(grep -n 'mput "\$MID" "\$NJ" /run/harness/job.json.next' <<<"$NJF" | cut -d: -f1)
[ -n "$RL" ] && [ -n "$JL" ] && [ "$RL" -lt "$JL" ] && ok || bad "S5: the refresh is not before the job.json.next mput in next_job_or_destroy (refresh='$RL' job='$JL')"

# S3 (all cases): no say line, stdout, stderr or log file carried the token.
grep -q 'fm2_fixture' <<<"$ALLOUT" && bad "S3: the token reached a say line or an output" || ok
grep -rlq 'fm2_fixture' "$T/h/logs" 2>/dev/null && bad "S3: the token reached a log under logs/" || ok

# ── D: the image ────────────────────────────────────────────────────────────
DF="$REPO/fly/Dockerfile"
DB=$(awk '$0 == "# >>> bake-flyctl" {f=1; next} $0 == "# <<< bake-flyctl" {f=0} f' "$DF")
[ -n "$DB" ] && ok || bad "D1: no bake-flyctl block in fly/Dockerfile"
[ "$(sed -n 1p <<<"$DB")" = "ARG FLYCTL_VERSION" ] && ok || bad "D1: the block must open with a bare ARG FLYCTL_VERSION"
grep -qF 'bake_verify flyctl "$FLYCTL_VERSION"' <<<"$DB" && ok || bad "D1: no bake_verify flyctl"
grep -q '^ENV PATH=/root/.fly/bin:\$PATH' <<<"$DB" && ok || bad "D1: /root/.fly/bin is not on ENV PATH"
grep -qF '/flyctl_${FLYCTL_VERSION}_checksums.txt' <<<"$DB" && ok || bad "D1: the checksum file is not flyctl_<v>_checksums.txt"
grep -qi 'latest' <<<"$DB" && bad "D1: the block names latest" || ok
DF_CODE=$(grep -vE '^[[:space:]]*#' "$DF")
[ -n "$DF_CODE" ] && ok || bad "D3: could not read fly/Dockerfile"
grep -qE 'testhost-key|ssh[[:space:]]+issue|FLY_API_TOKEN' <<<"$DF_CODE" && bad "D3: fly/Dockerfile carries a route part" || ok
mkdir -p "$T/d2bin"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "flyctl v0.4.119 linux/amd64 Commit: fixture BuildDate: 2026-10-01T00:00:00Z"\n' > "$T/d2bin/flyctl"
chmod +x "$T/d2bin/flyctl"
D2=$(env -i PATH="$T/d2bin:/usr/bin:/bin" bash -c '. "$1/bin/lib/cli-version.sh"; . "$1/bin/lib/bake-deps.sh"
  bake_deps | grep -x "flyctl FLYCTL_VERSION flyctl" || echo NO-ROW
  bake_dep_resolve flyctl flyctl ""' _ "$REPO" 2>/dev/null)
[ "$(sed -n 1p <<<"$D2")" = "flyctl FLYCTL_VERSION flyctl" ] && ok || bad "D2: bake_deps does not list flyctl: $D2"
[ "$(sed -n 2p <<<"$D2")" = "0.4.119" ] && ok || bad "D2: no row + no last bake did not fall back to the hub's flyctl: $D2"

echo "pool-testhost-route.bh-8335: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
