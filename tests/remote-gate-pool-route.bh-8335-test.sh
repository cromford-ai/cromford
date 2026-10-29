#!/bin/bash
# tests/remote-gate-pool-route.bh-8335-test.sh — bin/remote-gate.sh on a pool
# machine reaches the test host with the app-scoped route bin/fly-pool.sh
# ships, and names a miss (BH-8335).
#
# THE BUG. Every pool build wrote `rc: could-not-run why=runner-rc-125` into
# gate.txt: the pool machine had no flyctl and no Fly credential, and the
# gate's one line ("flyctl is not on PATH") named none of the parts.
# THE BLOCK (lead verdict #4386). The first route used an org-wide
# `flyctl ssh issue` cert. The route is now a Fly SSH token scoped to the
# test-host app, and the gate reaches the host with `flyctl ssh console -a
# <app>` (transport fly-ssh): no proxy, no key file, no `ssh issue`.
#
# PINNED, through the REAL bin/remote-gate.sh and the REAL
# bin/lib/remote-gate-fly-rsh.sh (flyctl, ssh, rsync, nc and ssh-keygen are
# PATH shims; nothing talks to Fly):
#   G1 POOL_MODE=1, no flyctl, no route: exit 125 and ONE `pool test-host route
#      incomplete:` line with flyctl=MISSING and the route path.
#   F1 round trip: the REAL ptr_build writes the route; the gate reads it and
#      every remote call is `flyctl ssh console -a <app> --machine <id> -q -C …`
#      (one `-C hostname` probe picks <id>, BH-8725) with the
#      minted token in FLY_API_TOKEN and FLY_ACCESS_TOKEN unset. No `proxy`,
#      no `ssh issue`, no OpenSSH call. rsync goes through the wrapper, which
#      runs `rsync --server …` over `ssh console`.
#   F2 the job's own exit code comes back through the marker line (3 -> 3),
#      and the marker never reaches stdout.
#   F3 no marker (the connection failed): exit 125, never 0.
#   F4 the token reaches no stdout, stderr or temp file of the gate.
#   F5 --issue-cert on fly-ssh: exit 2, no flyctl call.
#   F6 POOL_MODE=1 on fly-ssh: token=MISSING, or token=expired, is named; the
#      token itself is never printed.
#   W  the rsync wrapper refuses another host, another user, a command other
#      than `rsync --server`, an argument with a shell character and a bad app
#      name, each with exit 2 and no flyctl call.
#   G5 hostile lines in the route file run nothing, do not change PATH, and are
#      ignored; only the three keys are taken (TESTHOST_KEY is no longer one).
#   G6 the hub (no POOL_MODE, no route file): openssh as before, no new line,
#      TESTHOST_KEY defaults to $HOME/.fly/testhost-key, no `ssh console`.
#
# Run from anywhere: bash tests/remote-gate-pool-route.bh-8335-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
unset POOL_MODE TESTHOST_KEY FLY_API_TOKEN FLY_ACCESS_TOKEN REMOTE_GATE_CERT_MIN_H REMOTE_GATE_ROUTE_ENV TESTHOST_ROUTE_EXPIRES REMOTE_GATE_TRANSPORT
REPO=$(cd "$(dirname "$0")/.." && pwd)
GATE="$REPO/bin/remote-gate.sh"
RSH="$REPO/bin/lib/remote-gate-fly-rsh.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$GATE" ] || { echo "FAIL: bin/remote-gate.sh does not exist"; exit 1; }
[ -x "$RSH" ] || { echo "FAIL: bin/lib/remote-gate-fly-rsh.sh does not exist or is not executable"; exit 1; }

FIX="$T/fix"; FB="$T/fakebin"; NOFLY="$T/nofly"
mkdir -p "$FIX" "$FB" "$NOFLY" "$T/h/flags" "$T/h/logs" "$T/h/env" "$T/home" "$T/tmp"
: > "$T/h/flags/lane-off-testhost-tick"
export FIX

# flyctl: `proxy` logs the token it was given; `ssh issue` writes a key + cert;
# `tokens create` prints a fixture token; `ssh console -C <cmd>` plays the
# host: `bash -s` keeps its stdin, prints one job line and runs ONLY the
# script's last line (the marker printf) after `(exit <rc>)`, where rc is
# FAKE_RC for the job (the script that calls rg_room) and 0 otherwise.
# FAKE_NOMARK=1 prints nothing (a dropped connection).
cat > "$FB/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 ${2:-}" in
  "proxy "*) echo "proxy FLY_API_TOKEN=${FLY_API_TOKEN:-}" >> "$FIX/proxy-env"; : > "$FIX/proxy-up"; exit 0 ;;
  "ssh issue") shift 3; printf 'k\n' > "$1"; printf 'c\n' > "$1-cert.pub"; exit 0 ;;
  "tokens create") echo "FlyV1 fm2_fixture-token-8335"; exit 0 ;;
  "ssh console")
    echo "console API=${FLY_API_TOKEN:-} ACCESS=${FLY_ACCESS_TOKEN:-}" >> "$FIX/console-env"
    cmd=""; while [ $# -gt 0 ]; do [ "$1" = -C ] && { cmd=$2; break; }; shift; done
    case "$cmd" in
      # The machine pin's probe (BH-8725): the real unpinned answer, the
      # `No machine specified` line first, then the hostname (the machine id).
      hostname) echo "No machine specified, using 0f1c7e5000aa01 in region sjc"; echo 0f1c7e5000aa01; exit 0 ;;
      "bash -s")
        n=$(ls "$FIX" | grep -c '^console-in\.'); in="$FIX/console-in.$n"; cat > "$in"
        [ "${FAKE_NOMARK:-0}" = 1 ] && exit 0
        rc=0; grep -q 'rg_room [0-9"]' "$in" && rc=${FAKE_RC:-0}
        echo "job-out-line"
        { echo "(exit $rc)"; tail -n 1 "$in"; } | bash
        exit 0 ;;
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
# rsync: logs its -e, then runs that remote shell the way rsync does.
cat > "$FB/rsync" <<'STUB'
#!/bin/bash
rsh=""; dest=""
while [ $# -gt 0 ]; do
  case "$1" in -e) rsh=$2; shift 2; continue ;; esac
  dest=$1; shift
done
echo "rsync -e $rsh" >> "$FIX/rsync-calls"
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
for b in nc rsync ssh ssh-keygen; do ln -s "$FB/$b" "$NOFLY/$b"; done

# gate <PATH-prefix dir> <env assignments...> -- <gate args...>; GOUT / GERR / GRC.
gate() {
  local pre=$1; shift
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  rm -f "$FIX"/proxy-up "$FIX"/proxy-env "$FIX"/ssh-calls "$FIX"/fly-calls "$FIX"/console-env "$FIX"/console-in.* "$FIX"/rsync-calls
  GOUT=$(cd "$T" && env -i PATH="$pre:/usr/bin:/bin" HOME="$T/home" HARNESS="$T/h" JOBS_URL= FIX="$FIX" TMPDIR="$T/tmp" \
    TESTHOST_APP=fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org REMOTE_GATE_PROXY_WAIT_S=2 \
    ${envs[@]+"${envs[@]}"} bash "$GATE" "$@" 2>"$T/gerr"); GRC=$?
  GERR=$(cat "$T/gerr")
}
nmiss() { grep -c 'pool test-host route incomplete:' <<<"$GERR"; }
SRC="$T/src"; mkdir -p "$SRC"; echo hi > "$SRC/f"

# ── G1 ──────────────────────────────────────────────────────────────────────
gate "$NOFLY" POOL_MODE=1 HARNESS_ENV_DIR="$T/env-g1" -- "$SRC" -- true
[ "$GRC" = 125 ] && ok || bad "G1: exit $GRC, want 125 (no flyctl)"
[ "$(nmiss)" = 1 ] && ok || bad "G1: want exactly one miss line, got $(nmiss): $GERR"
L=$(grep 'pool test-host route incomplete:' <<<"$GERR")
case "$L" in *"flyctl=MISSING"*) ok ;; *) bad "G1: line does not say flyctl=MISSING: $L" ;; esac
case "$L" in *"route=$T/env-g1/testhost.env (MISSING)"*) ok ;; *) bad "G1: line does not name the route path: $L" ;; esac
grep -q 'flyctl is not on PATH' <<<"$GERR" && ok || bad "G1: the old 125 reason line is gone: $GERR"

# ── F1: round trip through the real writer ──────────────────────────────────
E4="$T/env-f1"; mkdir -p "$E4"; chmod 700 "$E4"
W4=$(cd "$T" && env -i PATH="$FB:/usr/bin:/bin" HOME="$T/home" HARNESS="$T/h" JOBS_URL= FIX="$FIX" \
  TESTHOST_APP=fixture POOL_TESTHOST_ROUTE=1 \
  bash -c '. "$1/bin/lib/pool-testhost-route.sh" && ptr_build "$2" BH-8335' _ "$REPO" "$E4" 2>&1); W4RC=$?
[ "$W4RC" = 0 ] && ok || bad "F1: ptr_build rc $W4RC: $W4"
grep -q '^tokens create ssh -a fixture -x [0-9]*h ' "$FIX/fly-calls" && ok || bad "F1: the writer did not mint an app-scoped ssh token: $(cat "$FIX/fly-calls")"
gate "$FB" POOL_MODE=1 HARNESS_ENV_DIR="$E4" FLY_ACCESS_TOKEN=tok-fixture-other -- "$SRC" -- true
[ "$GRC" = 0 ] && ok || bad "F1: exit $GRC on the route ptr_build wrote: $GERR"
[ "$(nmiss)" = 0 ] && ok || bad "F1: the miss line printed on a complete route: $GERR"
[ "$(grep -c '^ssh console -a fixture -q -C hostname$' "$FIX/fly-calls")" = 1 ] && ok \
  || bad "F1: want one 'ssh console -a fixture -q -C hostname' machine pin probe: $(cat "$FIX/fly-calls")"
[ "$(grep -c '^ssh console -a fixture --machine 0f1c7e5000aa01 -q -C bash -s$' "$FIX/fly-calls")" = 3 ] && ok \
  || bad "F1: want 3 'ssh console -a fixture --machine 0f1c7e5000aa01 -q -C bash -s' calls (prep, mkdir, job): $(cat "$FIX/fly-calls")"
grep -q '^ssh console -a fixture --machine 0f1c7e5000aa01 -q -C rsync --server ' "$FIX/fly-calls" && ok || bad "F1: rsync did not go over ssh console: $(cat "$FIX/fly-calls")"
grep -qE '^(proxy|ssh issue)' "$FIX/fly-calls" && bad "F1: fly-ssh still ran proxy or ssh issue: $(grep -E '^(proxy|ssh issue)' "$FIX/fly-calls")" || ok
[ ! -s "$FIX/ssh-calls" ] && ok || bad "F1: fly-ssh still called OpenSSH: $(cat "$FIX/ssh-calls")"
grep -qx "rsync -e $REPO/bin/lib/remote-gate-fly-rsh.sh" "$FIX/rsync-calls" && ok || bad "F1: rsync -e is not the wrapper: $(cat "$FIX/rsync-calls")"
[ "$(sort -u "$FIX/console-env")" = "console API=FlyV1 fm2_fixture-token-8335 ACCESS=" ] && ok \
  || bad "F1: ssh console did not get the route token alone: $(sort -u "$FIX/console-env")"
grep -qx 'job-out-line' <<<"$GOUT" && ok || bad "F1: the job's stdout did not come through: $GOUT"

# ── F2 / F3 ─────────────────────────────────────────────────────────────────
gate "$FB" POOL_MODE=1 HARNESS_ENV_DIR="$E4" FAKE_RC=3 -- "$SRC" -- true
[ "$GRC" = 3 ] && ok || bad "F2: the job's rc 3 came back as $GRC: $GERR"
grep -q '@@remote-gate-rc' <<<"$GOUT$GERR" && bad "F2: the marker reached an output: $GOUT" || ok
gate "$FB" POOL_MODE=1 HARNESS_ENV_DIR="$E4" FAKE_NOMARK=1 -- "$SRC" -- true
[ "$GRC" = 125 ] && ok || bad "F3: no marker gave exit $GRC, want 125: $GERR"
grep -q 'flyctl ssh console -a fixture' <<<"$GERR" && ok || bad "F3: the 125 line does not name the transport: $GERR"

# ── F4: the token in no output ──────────────────────────────────────────────
gate "$FB" POOL_MODE=1 HARNESS_ENV_DIR="$E4" -- "$SRC" -- true
grep -q 'fm2_fixture' <<<"$GOUT$GERR" && bad "F4: the token reached stdout/stderr" || ok
grep -rlq 'fm2_fixture' "$T/tmp" 2>/dev/null && bad "F4: the token reached a temp file: $(grep -rl fm2_fixture "$T/tmp")" || ok
for i in "$FIX"/console-in.*; do grep -q 'fm2_fixture' "$i" && bad "F4: the token went to the host in $i"; done; ok

# ── F5 ──────────────────────────────────────────────────────────────────────
gate "$FB" HARNESS_ENV_DIR="$E4" -- --issue-cert
[ "$GRC" = 2 ] && ok || bad "F5: --issue-cert on fly-ssh exit $GRC, want 2: $GERR"
[ ! -s "$FIX/fly-calls" ] && ok || bad "F5: --issue-cert on fly-ssh called flyctl: $(cat "$FIX/fly-calls")"

# ── F6 ──────────────────────────────────────────────────────────────────────
E6="$T/env-f6"; mkdir -p "$E6"; printf 'REMOTE_GATE_TRANSPORT=fly-ssh\n' > "$E6/testhost.env"
gate "$FB" POOL_MODE=1 HARNESS_ENV_DIR="$E6" -- "$SRC" -- true
grep -q 'route incomplete: .* transport=fly-ssh token=MISSING$' <<<"$GERR" && ok || bad "F6: no token=MISSING line: $GERR"
printf 'REMOTE_GATE_TRANSPORT=fly-ssh\nFLY_API_TOKEN=FlyV1 fm2_fixture-old\nTESTHOST_ROUTE_EXPIRES=1000\n' > "$E6/testhost.env"
gate "$FB" POOL_MODE=1 HARNESS_ENV_DIR="$E6" -- "$SRC" -- true
grep -q 'route incomplete: .* transport=fly-ssh token=expired$' <<<"$GERR" && ok || bad "F6: no token=expired line: $GERR"
grep -q 'fm2_fixture' <<<"$GOUT$GERR" && bad "F6: the miss line printed the token" || ok

# ── W: the rsync wrapper ────────────────────────────────────────────────────
wr() { rm -f "$FIX/fly-calls"; WOUT=$(env -i PATH="$FB:/usr/bin:/bin" FIX="$FIX" TESTHOST_APP="${WAPP-fixture}" bash "$RSH" "$@" </dev/null 2>&1); WRC=$?; }
wr -l root localhost rsync --server -logDtpre.iLsfxC --delete . /srv/tmp/runs/1-2/base/
[ "$WRC" = 0 ] && grep -qx 'ssh console -a fixture -q -C rsync --server -logDtpre.iLsfxC --delete . /srv/tmp/runs/1-2/base/' "$FIX/fly-calls" && ok \
  || bad "W: a good rsync line was not passed through (rc $WRC): $WOUT $(cat "$FIX/fly-calls" 2>/dev/null)"
wr root@localhost rsync --server . /srv/x/
[ "$WRC" = 0 ] && ok || bad "W: root@localhost was refused: $WOUT"
for args in "other.host rsync --server . /x/" "-l admin localhost rsync --server . /x/" "-p 22 localhost rsync --server . /x/" \
            "localhost bash -s" "localhost rsync . /x/" "localhost rsync --server . /x;touch" "localhost rsync --server . \$(id)" \
            "localhost rsync --server . a b|c"; do
  # shellcheck disable=SC2086
  wr $args
  [ "$WRC" = 2 ] && [ ! -s "$FIX/fly-calls" ] && grep -q '^remote-gate-fly-rsh: refused:' <<<"$WOUT" && ok \
    || bad "W: '$args' was not refused with rc 2 and no flyctl call (rc $WRC): $WOUT"
done
WAPP='bad app;x' wr localhost rsync --server . /x/
[ "$WRC" = 2 ] && [ ! -s "$FIX/fly-calls" ] && ok || bad "W: a bad TESTHOST_APP was not refused (rc $WRC)"
WAPP='' wr localhost rsync --server . /x/
[ "$WRC" = 2 ] && ok || bad "W: an empty TESTHOST_APP was not refused (rc $WRC)"

# ── G5: hostile lines ───────────────────────────────────────────────────────
E5="$T/env-g5"; mkdir -p "$E5"
{
  printf '%s\n' "# a comment line"
  printf 'TESTHOST_KEY=%s/stolen-key\n' "$T"
  printf 'FLY_API_TOKEN=$(touch %s/pwned)\n' "$T"
  printf 'FLY_API_TOKEN=`touch %s/pwned2`\n' "$T"
  printf 'PATH=/tmp/x\n'
  printf 'export FLY_API_TOKEN=tok-fixture-export\n'
  printf ' FLY_API_TOKEN=tok-fixture-space\n'
  printf 'TESTHOST_ROUTE_EXPIRES=1;touch %s/pwned3\n' "$T"
  printf 'REMOTE_GATE_TRANSPORT=evil\n'
  printf 'REMOTE_GATE_TRANSPORT="fly-ssh"\n'
} > "$E5/testhost.env"
sed -n '/^RG_ROUTE_FILE=/,/^_rg_pool_route$/p' "$GATE" > "$T/reader.sh"
grep -q '^_rg_pool_route$' "$T/reader.sh" && ok || bad "G5: could not cut the route reader out of bin/remote-gate.sh"
R5=$(env -i PATH="$NOFLY:/usr/bin:/bin" HOME="$T/home" HARNESS_ENV_DIR="$E5" bash -c '
  . "$1"
  printf "PATH=%s\nKEY=%s\nTOK=%s\nEXP=%s\nTR=%s\n" "$PATH" "${TESTHOST_KEY-unset}" "${FLY_API_TOKEN-unset}" "${TESTHOST_ROUTE_EXPIRES-unset}" "${REMOTE_GATE_TRANSPORT-unset}"' _ "$T/reader.sh")
[ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ] && [ ! -e "$T/pwned3" ] && ok || bad "G5: a hostile line executed"
grep -qx "PATH=$NOFLY:/usr/bin:/bin" <<<"$R5" && ok || bad "G5: PATH changed: $R5"
grep -qx 'KEY=unset' <<<"$R5" && ok || bad "G5: TESTHOST_KEY was taken from the route file: $R5"
grep -qx 'TOK=unset' <<<"$R5" && ok || bad "G5: a hostile FLY_API_TOKEN line was taken: $R5"
grep -qx 'EXP=unset' <<<"$R5" && ok || bad "G5: TESTHOST_ROUTE_EXPIRES with a ; was taken: $R5"
grep -qx 'TR=unset' <<<"$R5" && ok || bad "G5: a bad or quoted REMOTE_GATE_TRANSPORT was taken: $R5"
gate "$FB" REMOTE_GATE_TRANSPORT=evil -- "$SRC" -- true
[ "$GRC" = 2 ] && ok || bad "G5: an env REMOTE_GATE_TRANSPORT=evil gave exit $GRC, want 2"

# ── G6: the hub ─────────────────────────────────────────────────────────────
mkdir -p "$T/home/.fly"; printf 'k\n' > "$T/home/.fly/testhost-key"; printf 'c\n' > "$T/home/.fly/testhost-key-cert.pub"
gate "$FB" -- "$SRC" -- true
[ "$GRC" = 0 ] && ok || bad "G6: the hub run exit $GRC: $GERR"
[ "$(nmiss)" = 0 ] && ok || bad "G6: the hub printed the miss line: $GERR"
grep -q -- "-i $T/home/.fly/testhost-key " "$FIX/ssh-calls" && ok || bad "G6: the hub key is not \$HOME/.fly/testhost-key"
grep -q '^proxy ' "$FIX/fly-calls" && ok || bad "G6: the hub did not open the proxy"
grep -q '^ssh console' "$FIX/fly-calls" && bad "G6: the hub used ssh console" || ok
grep -q "^rsync -e ssh -i $T/home/.fly/testhost-key " "$FIX/rsync-calls" && ok || bad "G6: the hub rsync -e is not OpenSSH: $(cat "$FIX/rsync-calls")"
for pm in 0 true "1 " yes; do
  gate "$NOFLY" POOL_MODE="$pm" -- "$SRC" -- true
  [ "$(nmiss)" = 0 ] && ok || bad "G6: POOL_MODE='$pm' printed the miss line"
done
rm -rf "$T/home/.fly"

echo "remote-gate-pool-route.bh-8335: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
