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
#   ptr_push <mid> <outdir>    mput the route file to /run/harness-env/
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
# Root (D43): ${HARNESS:-${H:-}} for the knob reads only.

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
    rm -f "$d/.ptr-mint.out" "$d/.ptr-mint.rc"
    if [ "$rc" = 0 ] && [ -n "$tok" ]; then printf '%s' "$tok"; return 0; fi
    [ "$rc" = 0 ] && rc=4
  done
  return "$rc"
}

# ptr_build <outdir> <label> — the route into <outdir> (which must exist and
# be private: the spawn's /dev/shm bundle dir). rc 0: testhost.env, mode 600.
# rc 1: no file, one reason line on stderr. rc 3: the knob
# lane.fly-pool[.<project>].pool_testhost_route is not 1; nothing done.
ptr_build() {
  local out="${1:-}" label="${2:-}" h rc tok exp name
  [ -n "$out" ] && [ -d "$out" ] || { echo "testhost route: not shipped (no outdir)" >&2; return 1; }
  [ "$(_ptr_knob fly-pool POOL_TESTHOST_ROUTE)" = 1 ] || return 3
  h=$(ptr_hours)
  rm -f "$out/testhost.env"
  name="pool-$(printf '%s' "$label" | tr -c 'A-Za-z0-9-' '-')"
  tok=$(_ptr_mint "$h" "${name:0:60}" "$out"); rc=$?
  if [ "$rc" != 0 ] || [ -z "$tok" ]; then
    if [ "$rc" = 4 ]; then echo "testhost route: not shipped (token empty)" >&2
    else echo "testhost route: not shipped (token mint rc $rc)" >&2; fi
    return 1
  fi
  exp=$(( ${PTR_NOW:-$(date +%s)} + h * 3600 ))
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

# ptr_push <mid> <outdir> — testhost.env to /run/harness-env/ through mput
# (which writes it mode 600). One file, so a failed push never leaves half a
# route. rc 1 and one `say` line on a failed push; the build always goes on,
# and the gate then names the missing part itself.
ptr_push() {
  local mid="${1:-}" out="${2:-}"
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
