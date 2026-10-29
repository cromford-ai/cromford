#!/bin/bash
# tests/remote-gate-fly-pin.bh-8725-test.sh — BH-8725: on the fly-ssh
# transport bin/remote-gate.sh pins ONE test-host machine per run.
#
# THE CAUSE. `flyctl ssh console -a <app>` with no --machine prints `No machine
# specified, using <id> in region sjc` on stdout. Through the rsync wrapper that
# line went into rsync's protocol stream (`protocol version mismatch -- is your
# shell clean?`), and each unpinned call could land on another machine of the
# app, so the run dir, the upload and the job were not on one machine.
#
# PINNED, through the REAL bin/remote-gate.sh and the REAL
# bin/lib/remote-gate-fly-rsh.sh (flyctl, rsync, nc, ssh, ssh-keygen are PATH
# shims; nothing talks to Fly):
#   R1 one `-C hostname` probe picks the machine; every other ssh console call
#      (prep, mkdir, job, both rsyncs) carries `--machine <id>`; exit 0.
#   R2 TESTHOST_MACHINE: no probe, every call pinned to it; a bad value is
#      exit 2 with no flyctl call.
#   R3 a probe with no machine id: exit 125, `could not pick one test-host
#      machine` with flyctl's last stderr line (never a token line), no mkdir
#      and no rsync.
#   R4 the wrapper adds `--machine` after `-a <app>`; a bad RG_FLY_MACHINE is
#      refused, exit 2, no flyctl call.
#   R5 a failed rsync: the 125 line names rsync's rc and its last stderr line.
#   R6 openssh (the hub): no probe, no --machine.
#
# Run from anywhere: bash tests/remote-gate-fly-pin.bh-8725-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
unset POOL_MODE TESTHOST_KEY FLY_API_TOKEN FLY_ACCESS_TOKEN REMOTE_GATE_ROUTE_ENV TESTHOST_ROUTE_EXPIRES REMOTE_GATE_TRANSPORT TESTHOST_MACHINE RG_FLY_MACHINE
REPO=$(cd "$(dirname "$0")/.." && pwd)
GATE="$REPO/bin/remote-gate.sh"
RSH="$REPO/bin/lib/remote-gate-fly-rsh.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$GATE" ] && [ -x "$RSH" ] || { echo "FAIL: bin/remote-gate.sh or its rsync wrapper is missing"; exit 1; }

FIX="$T/fix"; FB="$T/fakebin"
mkdir -p "$FIX" "$FB" "$T/h/flags" "$T/h/logs" "$T/home" "$T/tmp"
: > "$T/h/flags/lane-off-testhost-tick"
export FIX
ID1=0f1c7e5000aa01; ID2=0f1c7e5000aa02

# flyctl: every call is logged. `ssh console -C hostname` prints FAKE_HOST_OUT
# (printf %b; unset: the real two-line answer of an unpinned call). `bash -s`
# runs only the script's marker line, rc 0. `rsync --server` swallows stdin.
cat > "$FB/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 ${2:-}" in
  "proxy "*) : > "$FIX/proxy-up"; exit 0 ;;
  "ssh console")
    cmd=""; while [ $# -gt 0 ]; do [ "$1" = -C ] && { cmd=$2; break; }; shift; done
    case "$cmd" in
      hostname) [ -n "${FAKE_HOST_ERR:-}" ] && printf '%b\n' "$FAKE_HOST_ERR" >&2
        printf '%b\n' "${FAKE_HOST_OUT-No machine specified, using 0f1c7e5000aa01 in region sjc\n0f1c7e5000aa01}"; exit "${FAKE_HOST_RC:-0}" ;;
      "bash -s") in=$(mktemp "$FIX/in.XXXXXX"); cat > "$in"; { echo "(exit 0)"; tail -n 1 "$in"; } | bash; exit 0 ;;
      "rsync --server "*) cat > /dev/null; exit 0 ;;
    esac
    exit 1 ;;
esac
exit 0
STUB
cat > "$FB/nc" <<'STUB'
#!/bin/bash
[ -f "$FIX/proxy-up" ] && exit 0
exit 1
STUB
# rsync: FAKE_RSYNC_FAIL=1 prints rsync's real protocol error and exits 2;
# else it runs its -e the way rsync does.
cat > "$FB/rsync" <<'STUB'
#!/bin/bash
rsh=""; dest=""
while [ $# -gt 0 ]; do
  case "$1" in -e) rsh=$2; shift 2; continue ;; esac
  dest=$1; shift
done
echo "rsync -e $rsh" >> "$FIX/rsync-calls"
if [ "${FAKE_RSYNC_FAIL:-0}" = 1 ]; then
  echo "protocol version mismatch -- is your shell clean?" >&2
  echo "(see the rsync manpage for an explanation)" >&2
  echo "protocol version mismatch -- is your shell clean?" >&2
  exit 2
fi
# shellcheck disable=SC2086
$rsh -l root localhost rsync --server -logDtpre.iLsfxCIvu --delete . "${dest#*:}" </dev/null
STUB
cat > "$FB/ssh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/ssh-calls"
case "$*" in *"bash -s"*) cat > /dev/null; exit 0 ;; esac
exit 0
STUB
printf '#!/bin/bash\necho "        Valid: from 2026-01-01T00:00:00 to 2099-01-01T00:00:00"\n' > "$FB/ssh-keygen"
chmod +x "$FB"/*

# The pool route file the way ptr_build writes it.
E="$T/env"; mkdir -p "$E"; chmod 700 "$E"
printf 'REMOTE_GATE_TRANSPORT=fly-ssh\nFLY_API_TOKEN=FlyV1 fm2_fixture-token-8725\n' > "$E/testhost.env"

# gate <env assignments...> -- <gate args...>; GOUT / GERR / GRC.
gate() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  rm -f "$FIX"/proxy-up "$FIX"/ssh-calls "$FIX"/fly-calls "$FIX"/rsync-calls "$FIX"/in.*
  GOUT=$(cd "$T" && env -i PATH="$FB:/usr/bin:/bin" HOME="$T/home" HARNESS="$T/h" JOBS_URL= FIX="$FIX" TMPDIR="$T/tmp" \
    TESTHOST_APP=fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org REMOTE_GATE_PROXY_WAIT_S=2 \
    ${envs[@]+"${envs[@]}"} bash "$GATE" "$@" 2>"$T/gerr"); GRC=$?
  GERR=$(cat "$T/gerr")
}
calls() { cat "$FIX/fly-calls" 2>/dev/null; }
SRC="$T/src"; mkdir -p "$SRC"; echo hi > "$SRC/f"

# ── R1 ──────────────────────────────────────────────────────────────────────
gate POOL_MODE=1 HARNESS_ENV_DIR="$E" -- "$SRC" -- true
[ "$GRC" = 0 ] && ok || bad "R1 exit $GRC, want 0: $GERR"
[ "$(grep -c -- '-C hostname$' "$FIX/fly-calls")" = 1 ] && grep -qx 'ssh console -a fixture -q -C hostname' "$FIX/fly-calls" \
  && ok || bad "R1 want exactly one unpinned '-C hostname' probe: $(calls)"
OTHER=$(grep -v -- '-C hostname$' "$FIX/fly-calls")
[ "$(grep -c '^ssh console -a fixture --machine 0f1c7e5000aa01 -q -C bash -s$' <<<"$OTHER")" = 3 ] && ok \
  || bad "R1 want 3 pinned 'bash -s' calls (prep, mkdir, job): $(calls)"
grep -q '^ssh console -a fixture --machine 0f1c7e5000aa01 -q -C rsync --server ' <<<"$OTHER" && ok || bad "R1 the rsync is not pinned: $(calls)"
[ "$(grep -c '^ssh console' <<<"$OTHER")" = "$(grep -c -- '--machine 0f1c7e5000aa01 ' <<<"$OTHER")" ] && ok || bad "R1 an unpinned call after the probe: $(calls)"
grep -qx 'remote-gate: fly-ssh: every call goes to test-host machine 0f1c7e5000aa01' <<<"$GERR" && ok || bad "R1 the pin line: $GERR"

# ── R2 ──────────────────────────────────────────────────────────────────────
gate POOL_MODE=1 HARNESS_ENV_DIR="$E" TESTHOST_MACHINE="$ID2" -- "$SRC" -- true
[ "$GRC" = 0 ] && ok || bad "R2 exit $GRC: $GERR"
grep -q -- '-C hostname' "$FIX/fly-calls" && bad "R2 TESTHOST_MACHINE set, but the probe ran: $(calls)" || ok
[ "$(grep -c '^ssh console' "$FIX/fly-calls")" -ge 4 ] && [ "$(grep -c '^ssh console' "$FIX/fly-calls")" = "$(grep -c -- '--machine 0f1c7e5000aa02 ' "$FIX/fly-calls")" ] \
  && ok || bad "R2 every call pinned to TESTHOST_MACHINE: $(calls)"
gate POOL_MODE=1 HARNESS_ENV_DIR="$E" 'TESTHOST_MACHINE=abc;id' -- "$SRC" -- true
[ "$GRC" = 2 ] && [ ! -s "$FIX/fly-calls" ] && ok || bad "R2 a bad TESTHOST_MACHINE: exit $GRC, want 2 and no flyctl call: $(calls)"

# ── R3 ──────────────────────────────────────────────────────────────────────
for out in '' 'No machine specified, using 0f1c7e5000aa01 in region sjc' 'abc' '873eddb0433018;id'; do
  gate POOL_MODE=1 HARNESS_ENV_DIR="$E" FAKE_HOST_OUT="$out" -- "$SRC" -- true
  [ "$GRC" = 125 ] && grep -q 'could not pick one test-host machine' <<<"$GERR" && ok || bad "R3 probe '$out': exit $GRC, want 125 + the line: $GERR"
  [ "$(grep -vc -- '-C hostname$' "$FIX/fly-calls")" = 0 ] && [ ! -s "$FIX/rsync-calls" ] && ok || bad "R3 probe '$out': calls after a failed pin: $(calls)"
done

# flyctl's own reason joins the line; a token line never does.
gate POOL_MODE=1 HARNESS_ENV_DIR="$E" FAKE_HOST_OUT='' FAKE_HOST_RC=1 \
  FAKE_HOST_ERR='Error: get app: Get "https://api.machines.dev/v1/apps/fixture": Forbidden' -- "$SRC" -- true
grep -qF '(the hostname probe printed no machine id, rc 1: Error: get app: Get "https://api.machines.dev/v1/apps/fixture": Forbidden) — nothing was sent to the host' <<<"$GERR" \
  && ok || bad "R3 the 125 line carries flyctl's reason: $GERR"
gate POOL_MODE=1 HARNESS_ENV_DIR="$E" FAKE_HOST_OUT='' FAKE_HOST_RC=1 FAKE_HOST_ERR='Error: bad token FlyV1 fm2_fixture-token-8725' -- "$SRC" -- true
[ "$GRC" = 125 ] && ! grep -q 'fm2_' <<<"$GERR" && ok || bad "R3 a token line from flyctl reached stderr: $GERR"
grep -q 'remote-gate-pin' <<<"$(ls "$T/tmp")" && bad "R3 the probe's stderr temp file was left: $(ls "$T/tmp")" || ok

# ── R4 ──────────────────────────────────────────────────────────────────────
wr() { rm -f "$FIX/fly-calls"; WOUT=$(env -i PATH="$FB:/usr/bin:/bin" FIX="$FIX" TESTHOST_APP=fixture ${WM+RG_FLY_MACHINE="$WM"} bash "$RSH" "$@" </dev/null 2>&1); WRC=$?; }
WM=$ID1 wr -l root localhost rsync --server -logDtpre.iLsfxC --delete . /srv/tmp/runs/1-2/base/
[ "$WRC" = 0 ] && grep -qx 'ssh console -a fixture --machine 0f1c7e5000aa01 -q -C rsync --server -logDtpre.iLsfxC --delete . /srv/tmp/runs/1-2/base/' "$FIX/fly-calls" \
  && ok || bad "R4 the wrapper argv (rc $WRC): $WOUT $(calls)"
for m in 'x y' 'abc' '0f1c7e5000aa01;id' 'ABCDEF0123456'; do
  WM="$m" wr -l root localhost rsync --server . /x/
  [ "$WRC" = 2 ] && [ ! -s "$FIX/fly-calls" ] && grep -q '^remote-gate-fly-rsh: refused:' <<<"$WOUT" && ok \
    || bad "R4 RG_FLY_MACHINE='$m' not refused (rc $WRC): $WOUT"
done

# ── R5 ──────────────────────────────────────────────────────────────────────
gate POOL_MODE=1 HARNESS_ENV_DIR="$E" FAKE_RSYNC_FAIL=1 -- "$SRC" -- true
[ "$GRC" = 125 ] && ok || bad "R5 exit $GRC, want 125"
grep -qxF 'remote-gate: the upload to the test host failed (rsync rc 2: protocol version mismatch -- is your shell clean?) — nothing ran' <<<"$GERR" \
  && ok || bad "R5 the 125 line names rsync's rc and reason: $GERR"
grep -q 'rsync' <<<"$(ls "$T/tmp")" && bad "R5 the rsync stderr temp file was left: $(ls "$T/tmp")" || ok

# ── R6 ──────────────────────────────────────────────────────────────────────
mkdir -p "$T/home/.fly"; printf 'k\n' > "$T/home/.fly/testhost-key"; printf 'c\n' > "$T/home/.fly/testhost-key-cert.pub"
gate -- "$SRC" -- true
[ "$GRC" = 0 ] && ok || bad "R6 the hub run exit $GRC: $GERR"
grep -q -- '-C hostname\|--machine' "$FIX/fly-calls" && bad "R6 openssh probed or pinned: $(calls)" || ok
grep -q 'every call goes to test-host machine' <<<"$GERR" && bad "R6 openssh printed the pin line" || ok

echo "remote-gate-fly-pin.bh-8725: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
