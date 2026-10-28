#!/bin/bash
# bin/lib/pool-testhost-route.sh — a short-lived route to the Fly test host for
# ONE pool machine (BH-8335). Sourced by bin/fly-pool.sh, on the hub.
#
# The selection gate on a pool build (bin/selection-gate.sh) runs the suites
# through bin/remote-gate.sh, which needs a Fly credential that opens the test
# host. The pool image carries none. Without a route every pool build wrote
# `rc: could-not-run why=runner-rc-125`.
#
#   ptr_hours                  how long the route lives, in whole hours
#   ptr_build <outdir> <label> mint the route into <outdir>; rc 0 / 1 / 3
#   ptr_push <mid> <outdir>    start the test host if it is stopped, then mput
#                              the route file to /run/harness-env/
#   ptr_ensure_host <mid> <outdir>  the start part of ptr_push (BH-8659)
#
# THE CREDENTIAL IS SCOPED TO ONE APP (lead BLOCK #4386, the operator 2026-10-27). It
# is a Fly SSH token for the test-host app only:
#   flyctl tokens create ssh -a <TESTHOST_APP> -x <hours>h -n pool-<label>
# That token is an app-scoped read token plus the two mutations issueCertificate
# and addWireGuardPeer (flyctl internal/command/tokens/create.go, runSSH). On
# the machine, `flyctl ssh console -a <app>` uses it to get a cert that is
# valid for that one app (the allowed-apps critical option). It cannot deploy,
# set secrets, start or stop a machine, or open any other app's machines.
# RESIDUAL: the token can add a WireGuard peer to the org network. With a peer,
# a machine can reach other apps' 6PN ports, but their Fly ssh servers refuse a
# cert that is not issued for their app.
# NEVER `flyctl ssh issue` here: that cert is org-wide (issue.go passes
# appNames=nil), so every machine in the org accepts it. A machine-exec token
# (`tokens create machine-exec`) is narrower, but its 60 s per call and its
# buffered output cannot carry remote-gate's rsync upload and its long job.
#
# THE ROUTE IS ONE FILE, mode 600, on the machine's tmpfs:
#   testhost.env  three KEY=value lines that bin/remote-gate.sh READS (a
#                 whitelist, never `.`): REMOTE_GATE_TRANSPORT=fly-ssh,
#                 FLY_API_TOKEN=<the ssh token>, TESTHOST_ROUTE_EXPIRES=<epoch>
# It is the one Fly credential that leaves the hub (bin/fly-envbundle.sh keeps
# every other FLY_* on the hub). Nothing goes in the image.
#
# A failed mint writes no file and prints ONE `testhost route: not shipped
# (<why>)` line on stderr. The token never reaches stdout, stderr or a log line.
#
# THE HUB STARTS THE HOST (BH-8659). The route's token cannot start a machine,
# and bin/testhost-tick.sh stops the host when it is idle. So ptr_push first
# runs `bin/testhost-tick.sh ensure --route-until <expiry>` on the hub, with the
# hub's own Fly credential (env/fly.env, as the tick's cron resolves it). That
# starts a stopped host and holds the idle stop until the route expires. The
# start credential never goes to the machine. A start that is not confirmed
# costs one say line; the route still ships.
#
# A PRE-MINTED TOKEN (BH-8677). The hub's FLY_API_TOKEN is deploy-scoped, so
# `flyctl tokens create ssh` answers `Not authorized` there. ptr_build first
# reads <env dir>/testhost-route.env (harness_env_dir; mode 600, written by a
# person, read by whitelist, never `.`):
#   TESTHOST_ROUTE_TOKEN=FlyV1 <...>
#   TESTHOST_ROUTE_EXPIRES=<epoch seconds>
# minted on a workstation with
#   flyctl tokens create ssh -a bh-testhost-example-org -x 720h -n hub-testhost-route
# If the file is valid and expires more than ptr_hours away, its token ships
# with the build's own expiry (now + ptr_hours), never the file's, so the
# test-host hold stays the build's window; else the mint runs as before. The file's token is ONE credential
# shared by every pool machine for up to 30 days. Its scope is the same as a
# minted one: the test-host app only (issueCertificate + addWireGuardPeer, the
# RESIDUAL above). The hub holds no org token on purpose: an org token could
# mint for any app, and one leaked copy would open every app in the org. Under
# the knob POOL_TESTHOST_ROUTE_WARN_HOURS of life left, one ALERTS line per
# UTC day asks for a new token. A mint whose output says `Not authorized` names
# that cause in the reason line.
# Docs: docs/REMOTE-GATE.md "A pre-minted route token (BH-8677)".
#
# Root (D43): ${HARNESS:-${H:-}} for the knob reads, the env dir and the alert.

if ! command -v harness_env_dir >/dev/null 2>&1; then
  # shellcheck source=bin/lib/env-path.sh
  . "${BASH_SOURCE[0]%/*}/env-path.sh" 2>/dev/null || true
fi

# _ptr_knob <lane> <ENV> — lane_knob with the pool's project, else the env.
_ptr_knob() {
  if command -v lane_knob >/dev/null 2>&1; then lane_knob "$1" "$2" "${P:-}"
  else printf '%s' "${!2:-}"; fi
}

# ptr_hours — the knob lane.fly-pool[.<project>].pool_testhost_token_hours; 0
# (its registry default) derives it from the build lane's deadline, the
# lane-reaper knob LANE_REAP_DEADLINE_SECS: ceil(deadline / 3600) + 1, so the
# token outlives the longest build the reaper allows. 16200 is that knob's
# registry default (catalog/lanes.d/lane-reaper.json), the fallback when it
# answers nothing. 1..72 is the knob's own registry range
# (catalog/lanes.d/fly-pool.knobs.d/POOL_TESTHOST_TOKEN_HOURS.json); a derived
# value is clamped to it too, so no token lives longer than three days.
ptr_hours() {
  local h d
  h=$(_ptr_knob fly-pool POOL_TESTHOST_TOKEN_HOURS)
  case "$h" in ''|*[!0-9]*) h=0 ;; esac
  if [ "$h" -eq 0 ]; then
    d=$(_ptr_knob lane-reaper LANE_REAP_DEADLINE_SECS)
    case "$d" in ''|*[!0-9]*|0) d=16200 ;; esac
    h=$(( (d + 3599) / 3600 + 1 ))
  fi
  [ "$h" -lt 1 ] && h=1
  [ "$h" -gt 72 ] && h=72
  printf '%s\n' "$h"
}

# _ptr_mint_timeout — the existing row lib.remote-gate.remote_gate_cert_issue_timeout_s
# (the bound on one Fly credential call), resolved by lib_env_apply as
# bin/remote-gate.sh resolves it, in a subshell so no other remote-gate knob
# lands in the pool's env. 60 is that knob's registry default
# (catalog/lanes.d/_lib.json).
_ptr_mint_timeout() {
  local t
  t=$( { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply remote-gate; } >/dev/null 2>&1
       printf '%s' "${REMOTE_GATE_CERT_ISSUE_TIMEOUT_S:-}" )
  case "$t" in ''|*[!0-9]*|0) t=60 ;; esac
  printf '%s\n' "$t"
}

# _ptr_mint <hours> <name> <scratch dir> — the app-scoped ssh token on stdout,
# rc as flyctl's (4: rc 0 and no token). ALWAYS with -x: flyctl's default
# expiry is 20 years. Bounded, stdin on /dev/null, stdout and stderr together
# capped at 64 KiB (a flyctl that loops writing is cut off, BH-5210), and only
# the `FlyV1 …` word kept (the bin/fly-pool-rollout.sh extract). Two
# credentials, in order: the one this tick already runs flyctl with, then the
# flyctl session, which is how bin/fly-pool-rollout.sh mints (env tokens could
# not always mint there, BH-666). A non-zero rc is a failed mint even when a
# FlyV1 word came out. The capture file is deleted before return.
_ptr_mint() {
  local h=$1 name=$2 d=$3 tmo app fly tok rc=4 try pre
  tmo=$(_ptr_mint_timeout)
  app="${TESTHOST_APP:-bh-testhost-example-org}"
  fly="${FLY:-flyctl}"
  for try in env session; do
    pre=(); [ "$try" = session ] && pre=(env -u FLY_ACCESS_TOKEN -u FLY_API_TOKEN)
    rm -f "$d/.ptr-mint.out" "$d/.ptr-mint.rc"
    ( umask 077
      ${pre[@]+"${pre[@]}"} timeout "$tmo" "$fly" tokens create ssh -a "$app" -x "${h}h" -n "$name" </dev/null 2>&1
      echo "$?" > "$d/.ptr-mint.rc" ) | ( umask 077; head -c 65536 > "$d/.ptr-mint.out" )
    rc=$(cat "$d/.ptr-mint.rc" 2>/dev/null); case "$rc" in ''|*[!0-9]*) rc=141 ;; esac
    tok=$(grep -oE 'FlyV1 [^[:space:]]+' "$d/.ptr-mint.out" 2>/dev/null | head -1)
    # The cause class rides out of this $(...) in a file: one word, no token text.
    grep -q 'Not authorized' "$d/.ptr-mint.out" 2>/dev/null \
      && ( umask 077; echo unauthorized > "$d/.ptr-mint.cause" )
    rm -f "$d/.ptr-mint.out" "$d/.ptr-mint.rc"
    if [ "$rc" = 0 ] && [ -n "$tok" ]; then printf '%s' "$tok"; return 0; fi
    [ "$rc" = 0 ] && rc=4
  done
  return "$rc"
}

# _ptr_route_file — the pre-minted token file, <env dir>/testhost-route.env.
_ptr_route_file() {
  local r="${HARNESS:-${H:-}}"
  if command -v harness_env_dir >/dev/null 2>&1; then
    printf '%s/testhost-route.env\n' "$(harness_env_dir "$r")"
  else
    printf '%s/env/testhost-route.env\n' "$r"
  fi
}

# _ptr_file_alert <expiry> <now> — one ALERTS line per UTC day, hub-wide (the
# file is one credential for every pool project). The day marker lives under
# state/testhost-route/, classed box-local in catalog/state-paths.json: it is
# this hub's own dedup mark, never a row. The day marker is made
# atomically first (set -C), so only the tick that makes it alerts; the other
# days' markers are deleted then. The token is never in the line.
_ptr_file_alert() {
  local exp=$1 now=$2 r="${HARNESS:-${H:-}}" dir day mk m when
  [ -n "$r" ] || return 0
  dir="$r/state/testhost-route"
  day=$(date -u -d "@$now" +%Y%m%d 2>/dev/null) || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  mk="$dir/alerted-testhost-route-token-$day"
  ( set -C; : > "$mk" ) 2>/dev/null || return 0
  for m in "$dir"/alerted-testhost-route-token-*; do
    [ "$m" = "$mk" ] || rm -f "$m"
  done
  when=$(date -u -d "@$exp" '+%Y-%m-%dT%H:%MZ' 2>/dev/null) || when=$exp
  [ -x "$r/bin/alert-line.sh" ] && "$r/bin/alert-line.sh" --project cromford --id pool-testhost-route-token \
    "[cromford] testhost route token expires $when; mint a new one: flyctl tokens create ssh -a ${TESTHOST_APP:-bh-testhost-example-org} -x 720h -n hub-testhost-route" \
    </dev/null >/dev/null 2>&1
  return 0
}

# _ptr_file_route <hours> <now> — `<token> <expiry>` on stdout and rc 0 when
# the pre-minted file is a regular file, mode 600 (a symlink reads 777 and is
# refused), its LAST token line is `FlyV1 <word>`, its LAST expiry line is
# digits, and the expiry is more than <hours> away. Else rc 1. A file with
# less than the warn window left (expired too) writes the day's alert.
_ptr_file_route() {
  local h=$1 now=$2 f tok exp warn
  f=$(_ptr_route_file)
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(stat -c %a "$f" 2>/dev/null)" = 600 ] || return 1
  tok=$(sed -n 's/^TESTHOST_ROUTE_TOKEN=//p' "$f" 2>/dev/null | tail -n 1)
  exp=$(sed -n 's/^TESTHOST_ROUTE_EXPIRES=//p' "$f" 2>/dev/null | tail -n 1)
  [[ "$tok" =~ ^FlyV1\ [^[:space:]]+$ ]] || return 1
  [[ "$exp" =~ ^[0-9]{1,12}$ ]] || return 1
  exp=$((10#$exp))
  warn=$(_ptr_knob fly-pool POOL_TESTHOST_ROUTE_WARN_HOURS)
  # 48 is the registry default (catalog/lanes.d/fly-pool.knobs.d/POOL_TESTHOST_ROUTE_WARN_HOURS.json).
  case "$warn" in ''|*[!0-9]*|0) warn=48 ;; esac
  [ $((exp - now)) -lt $((warn * 3600)) ] && _ptr_file_alert "$exp" "$now"
  [ "$exp" -gt $((now + h * 3600)) ] || return 1
  printf '%s %s\n' "$tok" "$exp"
}

# ptr_build <outdir> <label> — the route into <outdir> (which must exist and
# be private: the spawn's /dev/shm bundle dir). rc 0: testhost.env, mode 600.
# The pre-minted file (_ptr_file_route) is read first; the mint runs only when
# it does not answer. rc 1: no file, one reason line on stderr. rc 3: the knob
# lane.fly-pool[.<project>].pool_testhost_route is not 1; nothing done.
ptr_build() {
  local out="${1:-}" label="${2:-}" h rc tok exp name now fr cause
  [ -n "$out" ] && [ -d "$out" ] || { echo "testhost route: not shipped (no outdir)" >&2; return 1; }
  [ "$(_ptr_knob fly-pool POOL_TESTHOST_ROUTE)" = 1 ] || return 3
  h=$(ptr_hours)
  now=${PTR_NOW:-$(date +%s)}
  rm -f "$out/testhost.env" "$out/.ptr-mint.cause"
  if fr=$(_ptr_file_route "$h" "$now"); then
    tok=${fr% *}; exp=${fr##* }
    # The route hold (testhost.route_until) follows this expiry, so it stays the
    # build's window. The file's token itself may live far longer (BH-8677 review).
    [ "$exp" -le $((now + h * 3600)) ] || exp=$((now + h * 3600))
  else
    name="pool-$(printf '%s' "$label" | tr -c 'A-Za-z0-9-' '-')"
    tok=$(_ptr_mint "$h" "${name:0:60}" "$out"); rc=$?
    cause=$(cat "$out/.ptr-mint.cause" 2>/dev/null); rm -f "$out/.ptr-mint.cause"
    if [ "$rc" != 0 ] || [ -z "$tok" ]; then
      if [ "$cause" = unauthorized ]; then
        echo "testhost route: not shipped (hub token cannot mint tokens; put a pre-minted token in env/testhost-route.env)" >&2
      elif [ "$rc" = 4 ]; then echo "testhost route: not shipped (token empty)" >&2
      else echo "testhost route: not shipped (token mint rc $rc)" >&2; fi
      return 1
    fi
    exp=$(( now + h * 3600 ))
  fi
  if ! ( umask 077
         printf 'REMOTE_GATE_TRANSPORT=fly-ssh\nFLY_API_TOKEN=%s\nTESTHOST_ROUTE_EXPIRES=%s\n' \
           "$tok" "$exp" > "$out/testhost.env" ); then
    rm -f "$out/testhost.env"
    echo "testhost route: not shipped (could not write testhost.env)" >&2
    return 1
  fi
  chmod 600 "$out/testhost.env"
  return 0
}

# ptr_expires <outdir> — the route's expiry as an ISO UTC stamp, for the say line.
ptr_expires() {
  local e
  e=$(sed -n 's/^TESTHOST_ROUTE_EXPIRES=//p' "${1:-}/testhost.env" 2>/dev/null | head -1)
  case "$e" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  date -u -d "@$e" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || printf '%s' "$e"
}

# _ptr_say <line> — say when the pool tick defines it, else stderr.
_ptr_say() {
  if declare -F say >/dev/null 2>&1; then say "$1"; else echo "testhost route: $1" >&2; fi
}

# ptr_ensure_host <mid> <outdir> — start the test host if it is stopped, and
# hold its idle stop until the route in <outdir>/testhost.env expires, through
# bin/testhost-tick.sh ensure --route-until. FLY_ACCESS_TOKEN and FLY_API_TOKEN
# are unset for it, so the tick uses the hub's test-host credential and never
# the pool project's token. It reads the LAST `ensure-result:` line:
#   was-started  nothing said
#   started-now  one line: the host was stopped and is started now
#   anything else (unknown, start-failed, no line, a timeout, no script) one
#                line: not confirmed. The gate may then record could-not-run.
# Bounded by the knob lane.fly-pool[.<project>].pool_testhost_ensure_timeout_s.
# rc 0 always: the route ships either way.
ptr_ensure_host() {
  local mid="${1:-}" out="${2:-}" exp t tick res rc app
  local -a flag=()
  exp=$(sed -n 's/^TESTHOST_ROUTE_EXPIRES=//p' "$out/testhost.env" 2>/dev/null | head -1)
  case "$exp" in ''|*[!0-9]*) ;; *) flag=(--route-until "$exp") ;; esac
  t=$(_ptr_knob fly-pool POOL_TESTHOST_ENSURE_TIMEOUT_S)
  # 120 is the registry default (catalog/lanes.d/fly-pool.knobs.d/POOL_TESTHOST_ENSURE_TIMEOUT_S.json).
  case "$t" in ''|*[!0-9]*|0) t=120 ;; esac
  tick="$(dirname "${BASH_SOURCE[0]}")/../testhost-tick.sh"
  app="${TESTHOST_APP:-bh-testhost-example-org}"
  if [ -f "$tick" ]; then
    res=$(env -u FLY_ACCESS_TOKEN -u FLY_API_TOKEN timeout "$t" bash "$tick" ensure ${flag[@]+"${flag[@]}"} </dev/null 2>/dev/null)
    rc=$?
  else
    res=""; rc=127
  fi
  res=$(printf '%s\n' "$res" | sed -n 's/^ensure-result: //p' | tail -n 1 | tr -cd 'A-Za-z0-9-' | cut -c1-40)
  case "$res" in
    was-started) ;;
    started-now) _ptr_say "$mid: test host $app was stopped — started it before the route ship" ;;
    *) _ptr_say "$mid: test host ensure did not confirm a started host (${res:-rc $rc}) — the route ships, the selection gate may record could-not-run" ;;
  esac
  return 0
}

# ptr_push <mid> <outdir> — ptr_ensure_host, then testhost.env to
# /run/harness-env/ through mput (which writes it mode 600). One file, so a
# failed push never leaves half a route. rc 1 and one `say` line on a failed
# push; the build always goes on, and the gate then names the missing part
# itself.
ptr_push() {
  local mid="${1:-}" out="${2:-}"
  ptr_ensure_host "$mid" "$out"
  if ! mput "$mid" "$out/testhost.env" /run/harness-env/testhost.env; then
    if declare -F say >/dev/null 2>&1; then
      say "$mid: testhost route push FAILED — the selection gate will record could-not-run"
    else
      echo "testhost route: push FAILED" >&2
    fi
    return 1
  fi
  return 0
}
