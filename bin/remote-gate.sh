#!/bin/bash
# bin/remote-gate.sh — run this repo's suites (or one command) on the shared
# Fly test host, from anywhere (BH-1205).
#
#   bin/remote-gate.sh <dir> tests/a.sh [tests/b.sh …]   suites, in parallel
#   bin/remote-gate.sh <dir> -- <command…>               one command, one copy
#   bin/remote-gate.sh --issue-cert [--force]            only the cert, then exit
#
#   --full        print every suite's log, not only the failing ones
#   --tail N      lines of log per suite (default 80)
#   -P n          suites in parallel (default 12)
#   --issue-cert  issue (or keep) the ssh cert and stop (BH-5210); by hand, run
#                 bin/issue-testhost-cert.sh, which takes --key/--org/--hours
#   --force       with --issue-cert: issue even when the cert is still fresh
#
# EXIT CODES, and they do not overlap:
#   0-124  the number of failing suites (or the command's own exit in `--` mode)
#   125    THE RUN COULD NOT HAPPEN — no flyctl, no route to Fly, a refused
#          upload, ssh's own rc 255, or a copy that failed on the host. Docker
#          uses 125 for the same thing, and it is above anything a suite count
#          can reach, so a caller can tell "two suites are red" from "nothing
#          ran" without parsing the output.
#   2      the command line was wrong (bad flag, no such directory, no suites).
#   130/143  interrupted: INT/TERM, after the cleanup (BH-1918). Never a pass.
# THAT IS THE WHOLE POINT: a gate that cannot reach its host must never print
# "0 suites, 0 failing" and exit 0, which is indistinguishable from a green
# branch to every caller that reads the code. The same goes for the other half,
# which the first 516-suite run got wrong: a runner that ran out of disk must
# not report 10 RED SUITES, because that is indistinguishable from a broken
# branch to the human reading it.
#
# WHY. A Mac drain ran its suites in local docker and the containers SIGKILLed
# each other past about ten of them (load 120), which is what forced the
# 5-agent limiter (#1193). The Fly host is one performance-16x machine, shared:
# 16 heavy suites concurrently finish in 28 s, one suite in 9 s.
# bin/run-tests-in-docker.sh stays for anyone without Fly access; this is the
# faster path when TESTHOST_APP is reachable.
#
# CONFIGURATION, ALL IN ONE PLACE (env, with the working defaults baked in):
#   TESTHOST_APP    the Fly app                        bh-testhost-example-org
#   TESTHOST_PORT   the local port flyctl proxy binds  10022
#   TESTHOST_KEY    the ssh key + <key>-cert.pub       $HOME/.fly/testhost-key
#   TESTHOST_ORG    the org that issues the cert       board-builders
#   TESTHOST_TARGET one machine's 6PN address, when    (unset: Fly picks)
#                   the app has several and a port should pin one
#   REMOTE_GATE_BASE the branch CI diffs against       main (BH-1527)
#   REMOTE_GATE_TRANSPORT openssh (proxy + cert) or     openssh
#                   fly-ssh (a pool route, BH-8335)
# and the run knobs: REMOTE_GATE_P, REMOTE_GATE_TAIL, REMOTE_GATE_FULL,
# REMOTE_GATE_PROXY_WAIT_S, REMOTE_GATE_CERT_MIN_H, REMOTE_GATE_ISSUE_HOURS.
# The cert reissue's time bound, REMOTE_GATE_CERT_ISSUE_TIMEOUT_S, is a settings
# row like the host-side thresholds below (BH-1836).
# The four HOST-SIDE thresholds are settings rows, not env defaults (BH-1597):
# REMOTE_GATE_TMPFS_SIZE, REMOTE_GATE_MIN_FREE_MB, REMOTE_GATE_FREE_FACTOR and
# REMOTE_GATE_SWEEP_MIN — see _rg_knobs below and docs/REMOTE-GATE.md.
# Nothing here lives in a session scratchpad: the prototype this file hardens
# kept its key, its proxy log and its job files in one agent session's temp
# tree, so it worked for exactly one agent.
#
# FOUR THINGS THE PROTOTYPE LEARNED THE HARD WAY, kept here on purpose:
#   1. Fly's SSH server execs argv WITHOUT a shell, so a job cannot be passed as
#      a command string — it travels over stdin to `bash -s`.
#   2. rsync must be -rlptD, not -a. `-a` carries ownership; a root-owned tree
#      then makes git refuse the repo ("dubious ownership") inside any suite
#      that isolates HOME, which reads as a broken branch rather than a broken
#      upload.
#   3. The upload is snapshotted as a real git repo on the host, because the
#      check-attr and `git archive` suites need one and .git is not uploaded.
#   4. rc 127 from `bash <suite>` means that suite is not on this branch. It is
#      not a failure of the code under test and the run says so.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)

# ── a pool machine's route (BH-8335) ────────────────────────────────────────
# bin/fly-pool.sh hands each pool machine a route of its own in the harness
# env dir (bin/lib/pool-testhost-route.sh): testhost.env, with a Fly SSH token
# scoped to the test-host app alone (flyctl tokens create ssh -a <app> -x <h>).
# The file is READ, never sourced: only the three keys below are taken, only
# with a value that has no $, backtick, backslash, quote or control character
# (TESTHOST_ROUTE_EXPIRES: digits only; REMOTE_GATE_TRANSPORT: openssh or
# fly-ssh), and a variable the caller already set wins over it. With no file
# (the hub, a laptop) nothing changes. REMOTE_GATE_ROUTE_ENV names another file.
RG_ROUTE_FILE="${REMOTE_GATE_ROUTE_ENV:-}"
[ -z "$RG_ROUTE_FILE" ] && [ -n "${HARNESS_ENV_DIR:-}" ] && RG_ROUTE_FILE="$HARNESS_ENV_DIR/testhost.env"
_rg_pool_route() {
  local line k v
  [ -n "$RG_ROUTE_FILE" ] && [ -r "$RG_ROUTE_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      REMOTE_GATE_TRANSPORT=*|FLY_API_TOKEN=*|TESTHOST_ROUTE_EXPIRES=*) ;;
      *) continue ;;
    esac
    k=${line%%=*}; v=${line#*=}
    case "$v" in ''|*[\$\`\\\"\']*|*[[:cntrl:]]*) continue ;; esac
    case "$k" in
      TESTHOST_ROUTE_EXPIRES) case "$v" in *[!0-9]*) continue ;; esac ;;
      REMOTE_GATE_TRANSPORT) case "$v" in openssh|fly-ssh) ;; *) continue ;; esac ;;
    esac
    [ -n "${!k:-}" ] && continue
    printf -v "$k" '%s' "$v"
    export "${k?}"
  done < "$RG_ROUTE_FILE"
  return 0
}
_rg_pool_route

# ── the transport (BH-8335) ─────────────────────────────────────────────────
#   openssh  (default: the hub, a laptop) `flyctl proxy` to port 22 plus
#            OpenSSH with the cert from `flyctl ssh issue <org>`.
#   fly-ssh  (a pool machine's route) every remote call is `flyctl ssh console
#            -a $TESTHOST_APP`, with the app-scoped SSH token in FLY_API_TOKEN.
#            flyctl gets a fresh cert per connection that only this app's
#            machines accept. No proxy, no key file, no `ssh issue`. rsync
#            goes through bin/lib/remote-gate-fly-rsh.sh, which refuses
#            anything but `rsync --server` to this app.
RG_TRANSPORT="${REMOTE_GATE_TRANSPORT:-openssh}"
case "$RG_TRANSPORT" in
  openssh|fly-ssh) ;;
  *) echo "remote-gate: REMOTE_GATE_TRANSPORT must be openssh or fly-ssh, got '$RG_TRANSPORT'" >&2; exit 2 ;;
esac

TESTHOST_APP="${TESTHOST_APP:-bh-testhost-example-org}"
TESTHOST_PORT="${TESTHOST_PORT:-10022}"
TESTHOST_KEY="${TESTHOST_KEY:-$HOME/.fly/testhost-key}"
TESTHOST_ORG="${TESTHOST_ORG:-board-builders}"
TESTHOST_TARGET="${TESTHOST_TARGET:-}"
RG_P="${REMOTE_GATE_P:-12}"
RG_TAIL="${REMOTE_GATE_TAIL:-80}"
RG_FULL="${REMOTE_GATE_FULL:-0}"
RG_WAIT_S="${REMOTE_GATE_PROXY_WAIT_S:-25}"
RG_CERT_MIN_H="${REMOTE_GATE_CERT_MIN_H:-2}"
RG_ISSUE_H="${REMOTE_GATE_ISSUE_HOURS:-72}"
RG_SUITE_TIMEOUT="${REMOTE_GATE_SUITE_TIMEOUT:-1500}"
RG_ISSUE_ONLY=0; RG_FORCE_ISSUE=0; RG_ISSUED=0; RG_ISSUE_TMP=""
# THE CAP ON WHAT ONE ISSUE MAY PRINT (BH-5210), a code constant on purpose:
# it is a safety ceiling, like _rg_bounded's 5 s KILL grace. A flyctl that
# looped for 44 h wrote 596 GB into a redirect. A row could only lower it and
# an env override could raise it past the bound, so it is neither.
RG_ISSUE_OUT_MAX=1048576

die2()      { echo "remote-gate: $*" >&2; exit 2; }     # your command line
die_infra() { echo "remote-gate: $*" >&2; exit 125; }   # the run could not happen
usage() {
  cat <<'USAGE'
usage:
  bin/remote-gate.sh [--full] [--tail N] [-P n] <dir> tests/a.sh [tests/b.sh ...]
  bin/remote-gate.sh [--full] [--tail N] [-P n] <dir> -- <command ...>
  bin/remote-gate.sh --issue-cert [--force]     (by hand: bin/issue-testhost-cert.sh)

Runs the suites (or the command) on the shared Fly test host, in a fresh copy of
<dir> per suite. Exit 0-124 = the number of failing suites, or the command's
exit. Exit 125 = the run could not happen (no flyctl, no route to Fly, upload
refused, a copy that failed on the host). Exit 2 = your command line was wrong.
Exit 130/143 = interrupted by INT/TERM.

  TESTHOST_APP  TESTHOST_PORT  TESTHOST_KEY  TESTHOST_ORG   where the host is
  TESTHOST_TARGET   one machine's 6PN address (unset: Fly picks one)
  REMOTE_GATE_BASE  the base branch; origin/<it> goes up with the tree (main)
  REMOTE_GATE_P  REMOTE_GATE_TAIL  REMOTE_GATE_FULL         how it runs
USAGE
}

# ── arguments ───────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --full)    RG_FULL=1; shift ;;
    --tail)    [ $# -ge 2 ] || die2 "--tail needs a number"; RG_TAIL="$2"; shift 2 ;;
    -P)        [ $# -ge 2 ] || die2 "-P needs a number"; RG_P="$2"; shift 2 ;;
    --issue-cert) RG_ISSUE_ONLY=1; shift ;;
    --force)   RG_FORCE_ISSUE=1; shift ;;
    --)        break ;;
    -*)        die2 "unknown flag '$1' (try --help)" ;;
    *)         break ;;
  esac
done
case "$RG_TAIL" in ''|*[!0-9]*) die2 "--tail wants a whole number, got '$RG_TAIL'" ;; esac
case "$RG_P"    in ''|*[!0-9]*) die2 "-P wants a whole number, got '$RG_P'" ;; esac
[ "$RG_P" -ge 1 ] || die2 "-P must be at least 1"

MODE=suites
if [ "$RG_ISSUE_ONLY" = 1 ]; then
  [ $# -eq 0 ] || die2 "--issue-cert takes no directory or command (got '$1')"
  case "$RG_ISSUE_H" in ''|*[!0-9]*) die2 "REMOTE_GATE_ISSUE_HOURS wants a whole number, got '$RG_ISSUE_H'" ;; esac
  [ "$RG_ISSUE_H" -ge 1 ] || die2 "REMOTE_GATE_ISSUE_HOURS must be at least 1"
  MODE=issue
else
  [ "$RG_FORCE_ISSUE" = 0 ] || die2 "--force only goes with --issue-cert"
  DIR="${1:-}"
  [ -n "$DIR" ] || { usage >&2; die2 "no directory given"; }
  shift
  [ -d "$DIR" ] || die2 "no such directory: $DIR"
  [ $# -ge 1 ] || die2 "nothing to run — give suite paths, or -- <command>"
  if [ "$1" = "--" ]; then
    shift
    [ $# -ge 1 ] || die2 "-- needs a command"
    MODE=cmd
  fi
fi

# _rg_pool_miss — on a pool machine (POOL_MODE=1), ONE line that names every
# part of the route and says which is missing. The exits below do not change:
# this line only says where to look. Nothing on the hub or a laptop. The token
# is named present, MISSING or expired, never printed.
_rg_pool_miss() {
  local fc rf kf cf tk miss=0
  [ "${POOL_MODE:-}" = 1 ] || return 0
  fc=$(command -v flyctl 2>/dev/null) || { fc=MISSING; miss=1; }
  if [ -n "$RG_ROUTE_FILE" ] && [ -r "$RG_ROUTE_FILE" ]; then rf="$RG_ROUTE_FILE (present)"
  else rf="${RG_ROUTE_FILE:-<no HARNESS_ENV_DIR>/testhost.env} (MISSING)"; miss=1; fi
  if [ "$RG_TRANSPORT" = fly-ssh ]; then
    if [ -z "${FLY_API_TOKEN:-}" ]; then tk=MISSING; miss=1
    elif [ -n "${TESTHOST_ROUTE_EXPIRES:-}" ] && [ "$TESTHOST_ROUTE_EXPIRES" -le "$(date +%s)" ]; then tk=expired; miss=1
    else tk=present; fi
    [ "$miss" = 1 ] || return 0
    echo "remote-gate: pool test-host route incomplete: flyctl=$fc route=$rf transport=fly-ssh token=$tk" >&2
    return 0
  fi
  if [ -r "$TESTHOST_KEY" ]; then kf="$TESTHOST_KEY (present)"; else kf="$TESTHOST_KEY (MISSING)"; miss=1; fi
  if [ -r "$TESTHOST_KEY-cert.pub" ]; then cf="$TESTHOST_KEY-cert.pub (present)"; else cf="$TESTHOST_KEY-cert.pub (MISSING)"; miss=1; fi
  [ "$miss" = 1 ] || return 0
  echo "remote-gate: pool test-host route incomplete: flyctl=$fc route=$rf transport=openssh key=$kf cert=$cf" >&2
}
_rg_pool_miss

if [ "$RG_TRANSPORT" = fly-ssh ]; then
  [ "$MODE" = issue ] && die2 "--issue-cert: the fly-ssh transport issues no cert (flyctl ssh console gets its own app-scoped cert per connection)"
  case "$TESTHOST_APP" in ''|*[!a-z0-9-]*) die2 "TESTHOST_APP '$TESTHOST_APP' is not a Fly app name" ;; esac
fi

command -v flyctl >/dev/null 2>&1 || die_infra "flyctl is not on PATH — install it, or use bin/run-tests-in-docker.sh"
[ "$MODE" = issue ] || command -v rsync >/dev/null 2>&1 || die_infra "rsync is not on PATH"

# ── the ssh certificate ─────────────────────────────────────────────────────
# Fly issues a cert that lives at most 72h. Reissuing on every run costs an API
# call per gate run; reissuing only once it has EXPIRED fails every run in the
# gap. So: reissue when the key is missing, when the cert is missing or
# unreadable, or when it has less than REMOTE_GATE_CERT_MIN_H hours left.
# ssh-keygen prints the window in LOCAL time, so it is parsed in local time.
#
# THE REISSUE MUST NOT HANG THE GATE (BH-1836). On 2026-09-23 `flyctl ssh issue
# ... --overwrite` onto the live key hung for 37 and 52 minutes and every gate
# stalled behind it, while the same issue to a NEW path finished in seconds. So:
#   - flyctl writes into a fresh temp dir BESIDE the key (same filesystem, so
#     the mv is a rename) and never gets --overwrite; the key and then the cert
#     are moved into place only once both exist, so a failed issue never
#     touches the pair in use.
#   - it runs with stdin on /dev/null, bounded by REMOTE_GATE_CERT_ISSUE_TIMEOUT_S
#     (a settings row, resolved in _rg_knobs) and killed past it.
#   - a failed, hung or empty issue keeps using the current cert while it has
#     any time left, with ONE warning line; only a missing or expired cert is
#     exit 125.
#   - one issuer at a time, under flock on <key>.issue.lock. A gate whose cert
#     is still valid never waits for it (someone is already reissuing); a gate
#     with none waits at most one issuer's bound, then re-reads the cert, so N
#     concurrent gates issue once.
#   - where flock is missing (a Mac, where lead agents run several gates at
#     once) the same lock is a mkdir of <key>.issue.lock.d (BH-1854). Unlocked,
#     two issuers finishing together could leave one's key beside the other's
#     cert: a pair that reads valid for 72 h and fails every auth.
#   - the watchdog kills the issue's whole process group, so a helper flyctl
#     started cannot outlive the gate (BH-1854).
#   - flyctl's output goes through `head -c RG_ISSUE_OUT_MAX` into the temp dir,
#     never to an unbounded file (BH-5210). A flyctl that loops writing is cut
#     off by SIGPIPE at the cap, or by the watchdog if it ignores that, and the
#     warning carries its last line, so a failure says why in one line.
#   - flyctl starts with SIGPIPE at its DEFAULT action (_rg_dfl_pipe). A
#     process started with SIGPIPE ignored passes that on through every exec,
#     and bash cannot undo it (`trap - PIPE` is a silent no-op for a signal
#     ignored at entry). The CI runners start their steps that way: there the
#     spewing flyctl got EPIPE, not SIGPIPE, at the cap and kept writing to the
#     timeout (PR #5221, dequeued 2026-10-08). With the reset, the cap stops it
#     whatever the caller's disposition was.
_rg_epoch() { # _rg_epoch <YYYY-MM-DDTHH:MM:SS> — local-time stamp to epoch
  [ -n "${1:-}" ] || return 1
  date -d "$1" '+%s' 2>/dev/null && return 0
  date -j -f '%Y-%m-%dT%H:%M:%S' "$1" '+%s' 2>/dev/null && return 0
  return 1
}

# Seconds, not hours, decide "still valid": integer hours read a cert that
# expired 30 minutes ago as 0, the same as one with 30 minutes left.
_rg_cert_secs_left() { # prints signed seconds left, rc 1 when it cannot be read
  local cert to now end
  cert="$TESTHOST_KEY-cert.pub"
  [ -r "$TESTHOST_KEY" ] && [ -r "$cert" ] || return 1
  to=$(ssh-keygen -L -f "$cert" 2>/dev/null | awk '/Valid:/{for(i=1;i<=NF;i++) if($i=="to") print $(i+1)}' | head -1)
  [ -n "$to" ] || return 1
  end=$(_rg_epoch "$to") || return 1
  now=$(date '+%s')
  echo $(( end - now ))
}

_rg_cert_hours_left() { # prints whole hours left, rc 1 when it cannot be read
  local secs
  secs=$(_rg_cert_secs_left) || return 1
  echo $(( secs / 3600 ))
}

# _rg_bounded <secs> <marker> <cmd…> — run cmd with stdin/stdout/stderr on
# /dev/null; past <secs> a watchdog touches <marker>, sends TERM, and KILL 5 s
# later. Returns cmd's rc, or 124 when the watchdog fired. Plain shell, no
# timeout(1): Macs run this gate and do not ship it. The watchdog's own fds are
# on /dev/null too, so nothing it leaves behind holds a caller's $(…) open.
# cmd starts in its OWN process group (job control on for that one fork), and
# the watchdog signals the group, so helpers cmd started die with it (BH-1854).
# Only the group is signalled, never the gate's own group. The group and the
# watchdog are published in RG_BOUNDED_PGID/RG_BOUNDED_WD while cmd runs, so a
# signal to the gate reaches them too (_rg_on_signal, BH-1918).
RG_BOUNDED_PGID=""; RG_BOUNDED_WD=""
_rg_bounded() {
  local secs=$1 mark=$2 pid wd rc m=""
  shift 2
  case $- in *m*) m=1 ;; esac
  set -m
  "$@" </dev/null >/dev/null 2>&1 &
  pid=$!; RG_BOUNDED_PGID=$pid
  [ -n "$m" ] || set +m
  ( s=""; trap '[ -n "$s" ] && kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$secs" & s=$!; wait "$s"
    : > "$mark"; kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 5 & s=$!; wait "$s"
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  wd=$!; RG_BOUNDED_WD=$wd
  wait "$pid"; rc=$?
  kill -TERM "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  RG_BOUNDED_PGID=""; RG_BOUNDED_WD=""
  # A helper cmd left behind after a timed-out run is killed now, not at +5 s.
  [ -e "$mark" ] && { kill -KILL -- "-$pid" 2>/dev/null; return 124; }
  return "$rc"
}

# _rg_cert_fallback <why> — the issue did not produce a new pair: go on with the
# current cert if it has any time left (one warning), else exit 125.
_rg_cert_fallback() {
  local secs
  secs=$(_rg_cert_secs_left) || secs=""
  if [ -n "$secs" ] && [ "$secs" -gt 0 ]; then
    echo "remote-gate: WARNING: could not reissue the ssh certificate for $TESTHOST_ORG ($1); using the current one, $((secs / 3600))h$((secs % 3600 / 60))m left" >&2
    return 0
  fi
  die_infra "could not reissue the ssh certificate for $TESTHOST_ORG ($1), and there is no still-valid one at $TESTHOST_KEY-cert.pub — is flyctl logged in (flyctl auth whoami)?"
}

# _rg_issue_said <capture file> — flyctl's last non-blank line, printable only
# and at most 200 characters, so the warning it goes into stays ONE line. A
# last line the cap cut in half is skipped when a whole one comes before it:
# the marker echoed after the output lands on that partial line's end.
_rg_issue_said() {
  [ -s "$1" ] || return 0
  { tail -c 4096 "$1" 2>/dev/null | tr -d '\r' | tr -cd '[:print:]\n'; echo '@@rg-end@@'; } \
    | awk '$0 == "@@rg-end@@" { next }
           /@@rg-end@@$/ { p = substr($0, 1, length($0) - 10); if (l == "" && p ~ /[^[:space:]]/) l = p; next }
           NF { l = $0 }
           END { printf "%s", substr(l, 1, 200) }'
}

# _rg_dfl_pipe — sets the caller's local dfl=() to a prefix that execs its
# command with SIGPIPE at the default action: GNU env's --default-signal, else
# perl. Neither present leaves it empty, and the watchdog stays the bound.
_rg_dfl_pipe() {
  if env --default-signal=PIPE true >/dev/null 2>&1; then
    dfl=(env --default-signal=PIPE)
  elif command -v perl >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # perl code, not shell
    dfl=(perl -e '$SIG{PIPE} = "DEFAULT"; exec { $ARGV[0] } @ARGV or exit 127')
  fi
  return 0
}

_rg_issue_cert() { # one issue into a temp dir, then the pair moved into place
  local tmp rc why out said capped=""
  echo "remote-gate: issuing a fresh ssh certificate for $TESTHOST_ORG ($1)" >&2
  if ! tmp=$(mktemp -d "$(dirname "$TESTHOST_KEY")/.testhost-issue.XXXXXX" 2>/dev/null); then
    _rg_cert_fallback "could not make a temp dir beside $TESTHOST_KEY"; return
  fi
  RG_ISSUE_TMP=$tmp; out="$tmp/.flyctl.out"
  local dfl=()
  _rg_dfl_pipe
  # shellcheck disable=SC2016 # $1, $2 and $@ are the inner bash's own arguments
  _rg_bounded "$RG_ISSUE_TIMEOUT_S" "$tmp/.timed-out" \
    bash -c 'set -o pipefail; o=$1 m=$2; shift 2; "$@" 2>&1 | head -c "$m" > "$o"' \
      rg-issue "$out" "$RG_ISSUE_OUT_MAX" \
      ${dfl[@]+"${dfl[@]}"} flyctl ssh issue "$TESTHOST_ORG" "$tmp/key" --hours "$RG_ISSUE_H"
  rc=$?
  [ "$({ wc -c < "$out"; } 2>/dev/null || echo 0)" -ge "$RG_ISSUE_OUT_MAX" ] && capped="$((RG_ISSUE_OUT_MAX / 1024)) KiB cap"
  if [ -e "$tmp/.timed-out" ]; then why="timed out after ${RG_ISSUE_TIMEOUT_S}s${capped:+, and its output reached the $capped}"
  elif [ -n "$capped" ]; then why="flyctl's output reached the $capped (rc $rc)"
  elif [ "$rc" -ne 0 ]; then why="flyctl exited $rc"
  elif [ ! -r "$tmp/key" ] || [ ! -r "$tmp/key-cert.pub" ]; then why="wrote no key/cert"
  else
    chmod 600 "$tmp/key" 2>/dev/null
    # The cert moves LAST: a key without its new cert fails auth, but a new
    # cert beside the old key would read as valid.
    if mv -f "$tmp/key" "$TESTHOST_KEY" && mv -f "$tmp/key-cert.pub" "$TESTHOST_KEY-cert.pub"; then
      rm -rf "$tmp"; RG_ISSUE_TMP=""; RG_ISSUED=1; return 0
    fi
    why="could not move the new key and cert to $TESTHOST_KEY"
  fi
  said=$(_rg_issue_said "$out")
  [ -n "$said" ] && why="$why; flyctl said: $said"
  rm -rf "$tmp"; RG_ISSUE_TMP=""
  _rg_cert_fallback "$why"
}

_rg_cert_fresh() { # rc 0 when the cert has more than REMOTE_GATE_CERT_MIN_H hours left
  local left
  [ "$RG_FORCE_ISSUE" = 1 ] && return 1   # --issue-cert --force: replace it anyway
  left=$(_rg_cert_hours_left) || return 1
  [ "$left" -gt "$RG_CERT_MIN_H" ] 2>/dev/null
}

# THE MKDIR LOCK (BH-1854), for where flock is missing. <key>.issue.lock.d is
# the lock; its owner file says "<pid> <epoch>". A lock is STALE when its pid
# is gone, or when it is older than TWICE one issuer's worst case (the bound,
# the KILL grace, slack): a live holder cannot still be issuing by then — a
# recycled pid or a wedged gate. Twice, so a waiter's own bounded wait (once
# the worst case) ends before it could judge a live holder stale: a held lock
# means 125 or the fallback, never a steal. A lock with no owner file yet is
# someone between mkdir and write, and an owner that does not parse is a torn
# read: both are LIVE until the dir itself is that old (BH-1918).
# A RECLAIM IS SERIALIZED by a second mkdir, <key>.issue.lock.d.reclaim, held
# for the few statements of the reclaim only (BH-1918). Under it the owner is
# re-read and re-judged, the stale lock is renamed to a tomb unique to this
# attempt and removed, and the lock is made afresh. A gate that judged stale
# from an old read re-judges under the mutex and sees the winner's live owner,
# so no one moves a lock it has not re-judged. Every take re-reads its own
# owner after writing it. A mutex older than a minute is a reclaimer that died
# mid-reclaim and is removed; the next poll retries.
# A reclaim tomb goes back only when it carries an owner: an owner-less one
# belongs to a gate whose owner write has lost its dir, so it holds nothing.
# A lock that is gone by the time we look after a failed mkdir was released,
# never stale: we retry rather than reclaim (BH-2049).
RG_ISSUE_LOCKD=""; RG_ISSUE_LOCK_TOKEN=""; RG_ISSUE_RECLAIMD=""
_rg_mlock_parse() { # _rg_mlock_parse <owner> — rc 0 when it is "<digits> <digits>"
  local p a
  case "$1" in *" "*) ;; *) return 1 ;; esac
  p=${1%% *}; a=${1#* }
  case "$p" in ""|*[!0-9]*) return 1 ;; esac
  case "$a" in ""|*[!0-9]*) return 1 ;; esac
}
_rg_mlock_owner() { # _rg_mlock_owner <dir> — the owner line, read again if torn
  local d=$1 own="" i
  for i in 1 2 3; do
    own=$(cat "$d/owner" 2>/dev/null)
    _rg_mlock_parse "$own" && break
  done
  printf '%s' "$own"
}
_rg_mlock_stale() { # _rg_mlock_stale <dir> <owner as read> — rc 0 when stale
  local d=$1 own=$2 pid max
  max=$(( 2 * (RG_ISSUE_TIMEOUT_S + 15) ))
  if ! _rg_mlock_parse "$own"; then
    [ -n "$(find "$d" -maxdepth 0 -mmin "+$(( (max + 59) / 60 ))" 2>/dev/null)" ]
    return
  fi
  pid=${own%% *}
  kill -0 "$pid" 2>/dev/null || return 0
  [ $(( $(date '+%s') - ${own#* } )) -gt "$max" ]
}
_rg_mlock_own() { # _rg_mlock_own <dir> — write our owner and read it back
  RG_ISSUE_LOCK_TOKEN="$$ $(date '+%s')"
  echo "$RG_ISSUE_LOCK_TOKEN" > "$1/owner" 2>/dev/null || return 1
  [ "$(cat "$1/owner" 2>/dev/null)" = "$RG_ISSUE_LOCK_TOKEN" ] || return 1
  RG_ISSUE_LOCKD=$1
}
_rg_mlock_unmutex() { [ -n "$RG_ISSUE_RECLAIMD" ] && rmdir "$RG_ISSUE_RECLAIMD" 2>/dev/null; RG_ISSUE_RECLAIMD=""; return 0; }
_rg_mlock_reclaim() { # _rg_mlock_reclaim <dir> — under the reclaim mutex
  local d=$1 m="$1.reclaim" own tomb rc=1
  if ! mkdir "$m" 2>/dev/null; then
    [ -n "$(find "$m" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$m" 2>/dev/null
    return 1
  fi
  RG_ISSUE_RECLAIMD=$m
  own=$(_rg_mlock_owner "$d")
  if [ -d "$d" ] && _rg_mlock_stale "$d" "$own"; then
    tomb="$d.tomb.$$.$RANDOM"
    if mv "$d" "$tomb" 2>/dev/null; then
      if [ "$(_rg_mlock_owner "$tomb")" = "$own" ]; then
        rm -rf "$tomb"
        echo "remote-gate: note — reclaimed a stale cert reissue lock (${own:-no owner})" >&2
        mkdir "$d" 2>/dev/null && _rg_mlock_own "$d" && rc=0
      else
        # Only a holder releasing its own lock and a plain taker between our
        # judge and our rename gets here. Put the lock back only when it carries
        # an owner (BH-2049); if a taker made a new one in between, or it has no
        # owner, the moved dir is no longer the lock and goes.
        [ -n "$(_rg_mlock_owner "$tomb")" ] && [ ! -e "$d" ] && mv "$tomb" "$d" 2>/dev/null
        [ -e "$tomb" ] && rm -rf "$tomb"
      fi
    fi
  fi
  _rg_mlock_unmutex
  return "$rc"
}
_rg_mlock_try() { # _rg_mlock_try <dir> — one attempt, reclaiming a stale lock
  local d=$1 own
  if mkdir "$d" 2>/dev/null; then
    _rg_mlock_own "$d"; return
  fi
  own=$(_rg_mlock_owner "$d")
  [ -d "$d" ] && _rg_mlock_stale "$d" "$own" || return 1
  _rg_mlock_reclaim "$d"
}
_rg_mlock_wait() { # _rg_mlock_wait <dir> <secs> — poll once a second
  local d=$1 left=$2
  until _rg_mlock_try "$d"; do
    [ "$left" -le 0 ] && return 1
    sleep 1; left=$((left - 1))   # determinism: ok a bounded poll for another gate's lock
  done
}
_rg_mlock_release() { # drops the lock only while it is still ours
  [ -n "$RG_ISSUE_LOCKD" ] || return 0
  [ "$(cat "$RG_ISSUE_LOCKD/owner" 2>/dev/null)" = "$RG_ISSUE_LOCK_TOKEN" ] && rm -rf "$RG_ISSUE_LOCKD"
  RG_ISSUE_LOCKD=""
  return 0
}

_rg_ensure_cert() {
  local secs lock why
  _rg_cert_fresh && return 0
  secs=$(_rg_cert_secs_left) || secs=""
  if [ -n "$secs" ]; then why="$((secs / 3600)) hours left"; else why="no readable cert"; fi
  mkdir -p "$(dirname "$TESTHOST_KEY")" 2>/dev/null
  lock="$TESTHOST_KEY.issue.lock"
  if ! command -v flock >/dev/null 2>&1; then
    _rg_ensure_cert_mkdir "$secs" "$why"; return
  fi
  if ! : >> "$lock" 2>/dev/null; then
    # Unlocked is still safe (own temp dir, rename into place); the cost of a
    # concurrent gate is a second issue. rg_prep degrades the same way.
    echo "remote-gate: note — $lock is not writable; reissuing without the lock" >&2
    _rg_issue_cert "$why"; return
  fi
  if [ -n "$secs" ] && [ "$secs" -gt 0 ]; then
    # Still valid: never wait. A held lock means another gate is reissuing.
    { if flock -n 8; then
        _rg_cert_fresh || _rg_issue_cert "$why"
      else
        echo "remote-gate: note — another gate is reissuing the ssh certificate; using the current one, $((secs / 3600))h$((secs % 3600 / 60))m left" >&2
      fi; } 8>"$lock"
    return 0
  fi
  # No usable cert: wait for the issuer in flight, at most its own bound plus
  # the KILL grace, then re-read — it has usually just written ours.
  { if flock -w "$((RG_ISSUE_TIMEOUT_S + 15))" 8; then
      _rg_cert_fresh || _rg_issue_cert "$why"
    else
      _rg_cert_fallback "another gate held $lock for more than $((RG_ISSUE_TIMEOUT_S + 15))s"
    fi; } 8>"$lock"
  return 0
}

# The flock branch above, on the mkdir lock: the same two modes.
_rg_ensure_cert_mkdir() { # <secs left or empty> <why>
  local secs=$1 why=$2 d="$TESTHOST_KEY.issue.lock.d"
  if [ -n "$secs" ] && [ "$secs" -gt 0 ]; then
    if _rg_mlock_try "$d"; then
      _rg_cert_fresh || _rg_issue_cert "$why"
      _rg_mlock_release
    else
      echo "remote-gate: note — another gate is reissuing the ssh certificate; using the current one, $((secs / 3600))h$((secs % 3600 / 60))m left" >&2
    fi
    return 0
  fi
  if _rg_mlock_wait "$d" "$((RG_ISSUE_TIMEOUT_S + 15))"; then
    _rg_cert_fresh || _rg_issue_cert "$why"
    _rg_mlock_release
  else
    _rg_cert_fallback "another gate held $d for more than $((RG_ISSUE_TIMEOUT_S + 15))s"
  fi
  return 0
}

# _rg_issue_only — --issue-cert: the cert and nothing else (BH-5210). The same
# lock, bound and fallback as a gate run; only the exit code is its own: 0 when
# a pair was issued or the cert is still fresh, 1 when the issue did not
# happen but the current cert is still valid (the fallback warned), and 125
# from the fallback itself when there is none.
_rg_issue_only() {
  local was_fresh=0 secs
  [ "$RG_FORCE_ISSUE" = 0 ] && _rg_cert_fresh && was_fresh=1
  _rg_ensure_cert
  if [ "$RG_ISSUED" = 1 ]; then
    echo "remote-gate: issued a new ssh certificate for $TESTHOST_ORG to $TESTHOST_KEY-cert.pub (key $TESTHOST_KEY, mode 600)" >&2
    return 0
  fi
  secs=$(_rg_cert_secs_left) || secs=0
  if [ "$RG_FORCE_ISSUE" = 0 ] && _rg_cert_fresh; then
    if [ "$was_fresh" = 1 ]; then
      echo "remote-gate: the ssh certificate at $TESTHOST_KEY-cert.pub is still valid, $((secs / 3600))h$((secs % 3600 / 60))m left; nothing issued (--force to replace it)" >&2
    else
      echo "remote-gate: another issuer just renewed the ssh certificate at $TESTHOST_KEY-cert.pub, $((secs / 3600))h$((secs % 3600 / 60))m left; nothing issued" >&2
    fi
    return 0
  fi
  return 1
}

# ── the machine, and the route to it ────────────────────────────────────────
# The lane owns the machine's power: bin/testhost-tick.sh stamps the use in D1
# and starts the host if the idle-stop tick put it away. It is best effort — a
# host that is already up does not need it, and a lane an operator has switched
# off must not make this script fail — but it is what keeps the cost story
# honest, because the tick will not stop a host whose last use it never saw.
_rg_wake() {
  local out
  [ -x "$SELF_DIR/testhost-tick.sh" ] || return 0
  out=$("$SELF_DIR/testhost-tick.sh" ensure 2>&1)
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/remote-gate: /' >&2
  # A RUN NOBODY RECORDED IS A RUN THE IDLE STOP CANNOT SEE, and this line is
  # the difference between "the host went away for no reason" and "I was told".
  # It is deliberately three lines and deliberately not buried in the tick's
  # own prefixed output: on a Mac with no worker credential this is the normal
  # case, and the machine's own busy probe is what protects the run instead.
  case "$out" in
    *"not recorded"*|*"did not answer"*)
      echo "remote-gate: ---------------------------------------------------------------" >&2
      echo "remote-gate: WARNING — this run is NOT recorded in testhost.last_used." >&2
      echo "remote-gate:   The idle-stop lane cannot see it from the row; it falls back to" >&2
      echo "remote-gate:   asking the host what is running. To record it, give this machine" >&2
      # The env dir is named as env/global.env, not as a path built from
      # $HARNESS: tests/env-path-test.sh scans bin/ for that spelling and
      # cannot tell a sentence from a lookup, and it is right not to try.
      echo "remote-gate:   a worker credential (HARNESS_SECRET + JOBS_URL in the harness" >&2
      echo "remote-gate:   env dir, env/global.env; HARNESS falls back to this checkout)." >&2
      echo "remote-gate:   docs/REMOTE-GATE.md explains it." >&2
      echo "remote-gate: ---------------------------------------------------------------" >&2 ;;
  esac
  return 0
}

_rg_port_open() {
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$TESTHOST_PORT" >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$TESTHOST_PORT") >/dev/null 2>&1
  fi
}

# The proxy is a background flyctl that outlives this run on purpose — the next
# gate run in the same drain reuses it. Self-heal: if the port is not open we
# start one and wait, bounded; a proxy that never comes up is exit 2 and says
# so, never a run against nothing.
_rg_ensure_proxy() {
  local waited=0 log
  _rg_port_open && return 0
  log="${TMPDIR:-/tmp}/remote-gate-proxy.log"
  # shellcheck disable=SC2086
  ( nohup flyctl proxy "$TESTHOST_PORT:22" $TESTHOST_TARGET -a "$TESTHOST_APP" >> "$log" 2>&1 & ) >/dev/null 2>&1
  while [ "$waited" -lt "$RG_WAIT_S" ]; do
    _rg_port_open && return 0
    sleep 1; waited=$((waited + 1))   # determinism: ok bounded poll for a port, not a fixed settle
  done
  die_infra "no route to the Fly test host: flyctl proxy $TESTHOST_PORT:22 -a $TESTHOST_APP did not open the port in ${RG_WAIT_S}s (tail $log; check flyctl auth whoami and that the machine is started — bin/testhost-tick.sh state)"
}

# ── the fly-ssh transport (BH-8335) ─────────────────────────────────────────
# _rg_fly_bash <script file> — run the script on the host with `bash -s` over
# `flyctl ssh console -a $TESTHOST_APP`, stdout streamed, and return the
# script's own exit code. flyctl's exit code is not used: it does not tell "the
# connection failed" from "the script failed". So the script goes up wrapped in
# a subshell, and one marker line after it prints the subshell's rc. The marker
# never reaches the caller's stdout. No marker means nothing can be concluded:
# rc 255, the same as OpenSSH's own "could not run anything".
# FLY_ACCESS_TOKEN is unset for flyctl, because it wins over FLY_API_TOKEN and
# the route's token is the credential this transport is for.
RG_FLY_MARK=""
_rg_fly_bash() {
  local f=$1 rcf rc
  [ -n "$RG_FLY_MARK" ] || RG_FLY_MARK="@@remote-gate-rc-$$-$(date +%s)@@"
  rcf=$(mktemp "${TMPDIR:-/tmp}/remote-gate-rc.XXXXXX") || return 255
  { printf '(\n'; cat "$f"; printf '\n)\nrg_rc=$?; printf "\\n%%s %%s\\n" %s "$rg_rc"\n' "$RG_FLY_MARK"; } \
    | env -u FLY_ACCESS_TOKEN flyctl ssh console -a "$TESTHOST_APP" -q -C "bash -s" \
    | awk -v m="$RG_FLY_MARK" -v rcf="$rcf" '
        $1 == m && NF == 2 { if (held && h != "") print h; held = 0; print $2 > rcf; close(rcf); next }
        { if (held) { print h; fflush() } h = $0; held = 1 }
        END { if (held) print h }'
  rc=$(cat "$rcf" 2>/dev/null); rm -f "$rcf"
  case "$rc" in ''|*[!0-9]*) return 255 ;; esac
  return "$rc"
}

# ── the git context (BH-1527) ───────────────────────────────────────────────
# CI checks out with fetch-depth 0, so `git merge-base HEAD origin/main` and
# `git diff origin/main...HEAD` work there. The upload excludes .git, and the
# host used to snapshot it as a fresh one-commit repo with no origin/main: every
# arm that diffs the branch against main printed "no merge base" or diffed
# against nothing, and passed (#1496 was green here and red on CI). So when <dir>
# is a checkout, a SHALLOW bare repo goes up beside the tree, holding HEAD and
# origin/<base> deep enough to reach their merge base, and the host puts the tree
# on top of it. RG_CTX_* stay empty for a plain directory, which keeps the old
# snapshot — and a suite that then looks for a base fails the run (the job).
RG_BASE="${REMOTE_GATE_BASE:-main}"
RG_CTX=""; RG_CTX_HEAD=""; RG_CTX_BASE=""; RG_CTX_MB=""

_rg_is_checkout() { # _rg_is_checkout <dir> — rc 0 when <dir> is the top of a git checkout with a commit
  local top
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$(cd "$top" && pwd -P)" = "$(cd "$1" && pwd -P)" ] || return 1
  git -C "$1" rev-parse --verify -q 'HEAD^{commit}' >/dev/null
}

_rg_resolve_base() { # prints the sha of origin/<base> (or <base>), rc 1 when neither resolves
  git -C "$DIR" rev-parse --verify -q "origin/$RG_BASE^{commit}" 2>/dev/null \
    || git -C "$DIR" rev-parse --verify -q "$RG_BASE^{commit}" 2>/dev/null
}

# Deep enough that the merge base is inside the shallow history from BOTH tips:
# no path from a tip to the merge base is longer than the commits between them.
_rg_ctx_depth() {
  local a b
  a=$(git -C "$DIR" rev-list --count "$RG_CTX_MB..$RG_CTX_HEAD")
  b=$(git -C "$DIR" rev-list --count "$RG_CTX_MB..$RG_CTX_BASE")
  [ "$a" -gt "$b" ] && echo $((a + 1)) || echo $((b + 1))
}

_rg_build_context() { # fills RG_CTX with a shallow bare repo; dies 125 on anything CI would not see
  _rg_is_checkout "$DIR" || return 0
  RG_CTX_HEAD=$(git -C "$DIR" rev-parse HEAD)
  RG_CTX_BASE=$(_rg_resolve_base) || die_infra "the base '$RG_BASE' resolves in $DIR neither as origin/$RG_BASE nor as $RG_BASE — git fetch origin $RG_BASE (REMOTE_GATE_BASE names another)"
  RG_CTX_MB=$(git -C "$DIR" merge-base HEAD "$RG_CTX_BASE" 2>/dev/null) \
    || die_infra "HEAD has no merge base with origin/$RG_BASE in $DIR (a shallow clone?) — the host cannot be given what CI sees; git fetch --unshallow"
  RG_CTX=$(mktemp -d "${TMPDIR:-/tmp}/remote-gate-ctx.XXXXXX") || die_infra "cannot create a temp dir in ${TMPDIR:-/tmp}"
  git init -q --bare "$RG_CTX/ctx.git" \
    && git -C "$RG_CTX/ctx.git" fetch -q --depth="$(_rg_ctx_depth)" \
         --upload-pack='git -c uploadpack.allowAnySHA1InWant=true upload-pack' \
         "file://$(cd "$DIR" && pwd -P)" "$RG_CTX_HEAD:refs/rg/head" "$RG_CTX_BASE:refs/remotes/origin/$RG_BASE" \
    && [ "$(git -C "$RG_CTX/ctx.git" merge-base refs/rg/head "refs/remotes/origin/$RG_BASE" 2>/dev/null)" = "$RG_CTX_MB" ] \
    || die_infra "could not build the git context to send (the shallow copy of HEAD and origin/$RG_BASE has no merge base $RG_CTX_MB)"
  _rg_say_context
}

_rg_say_context() {
  echo "remote-gate: git context — HEAD $RG_CTX_HEAD, base origin/$RG_BASE $RG_CTX_BASE, merge base $RG_CTX_MB" >&2
  [ "$RG_CTX_MB" = "$RG_CTX_BASE" ] && return 0
  echo "remote-gate: note — origin/$RG_BASE has moved on since this branch forked. CI tests the merge; the host tests the branch as it stands. Three-dot diffs (origin/$RG_BASE...HEAD) agree; a two-dot diff against origin/$RG_BASE also sees the newer $RG_BASE files. Rebase for an exact match." >&2
}

# ── the knobs the host side runs on (BH-1597) ───────────────────────────────
# Four thresholds decide what the job does to a SHARED host: how big a tmpfs to
# mount, how much free space a run needs, and how old litter must be before the
# sweep removes it. They are settings rows (lib.remote-gate.<env>, registry
# catalog/lanes.d/_lib.json) resolved HERE, on the machine running the gate,
# through bin/lib/lane-gate.sh's lib_env_apply — row, cached row, env, registry
# default, in that order — and baked into the job as values. The host has no
# worker credential and never reads a row. NO LITERAL LIVES IN THIS FILE: a knob
# that resolves to nothing is exit 125, never a guess.
#
# The registry is THIS checkout's, never the box's /root/harness copy: a builder
# box can run a harness older than the branch it is gating, and the knobs this
# job needs are the ones this checkout's registry declares. The settings rows
# and their cache still come from HARNESS (the box) when it exists, else from
# this checkout, which is how testhost-tick.sh finds a Mac's env too.
_rg_knob_int() { # _rg_knob_int <ENV> — dies 125 unless the resolved value is a whole number
  case "${!1:-}" in ''|*[!0-9]*)
    die_infra "the knob $1 resolved to '${!1:-}' — a whole number is required (settings row lib.remote-gate.$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'), default in catalog/lanes.d/_lib.json); nothing was sent to the host" ;;
  esac
}
_rg_knobs() {
  local reg HARNESS="${HARNESS:-/root/harness}"
  [ -d "$HARNESS" ] || HARNESS=$(cd "$SELF_DIR/.." && pwd)
  # shellcheck source=lib/lane-gate.sh
  . "$SELF_DIR/lib/lane-gate.sh" 2>/dev/null
  if [ -z "${LANE_REGISTRY:-}" ]; then
    # shellcheck source=lib/lanes-registry.sh
    reg=$( . "$SELF_DIR/lib/lanes-registry.sh" 2>/dev/null && lanes_json_path "$SELF_DIR/.." 2>/dev/null) || reg=""
  else reg="$LANE_REGISTRY"; fi
  command -v lib_env_apply >/dev/null 2>&1 && [ -n "$reg" ] && LANE_REGISTRY="$reg" lib_env_apply remote-gate
  _rg_knob_int REMOTE_GATE_MIN_FREE_MB
  _rg_knob_int REMOTE_GATE_FREE_FACTOR
  _rg_knob_int REMOTE_GATE_SWEEP_MIN
  _rg_knob_int REMOTE_GATE_LOCK_WAIT_S
  _rg_knob_int REMOTE_GATE_CERT_ISSUE_TIMEOUT_S
  [ "$REMOTE_GATE_CERT_ISSUE_TIMEOUT_S" -ge 1 ] || die_infra "REMOTE_GATE_CERT_ISSUE_TIMEOUT_S is 0 — the cert reissue would be killed before it started"
  RG_ISSUE_TIMEOUT_S="$REMOTE_GATE_CERT_ISSUE_TIMEOUT_S"
  [ "$REMOTE_GATE_LOCK_WAIT_S" -ge 1 ] || die_infra "REMOTE_GATE_LOCK_WAIT_S is 0 — the prep could never take the mount lock"
  _rg_sweep_floor
  _rg_knob_tmpfs
  return 0
}
# THE SWEEP AGE HAS A FLOOR IN CODE (#1604 review, I1). lib_env_apply clamps a
# settings ROW, but a value in the caller's own env wins as it stands — and the
# sweep runs on a SHARED host, so one builder with REMOTE_GATE_SWEEP_MIN=2 would
# make every sweep there a two-minute sweep. What the age protects is scratch
# the liveness arms cannot see: /tmp trees of gate runs from checkouts older than
# #1597 (no TMPDIR confinement) and scratch a suite reaches only through an env
# var. Those live at most as long as one suite may run, so the floor is the
# suite cap (REMOTE_GATE_SUITE_TIMEOUT) plus a fifth, rounded up to a minute:
# 1500 s -> 30 minutes. A lower value is raised to it, with a note.
_rg_sweep_floor() {
  local floor
  case "$RG_SUITE_TIMEOUT" in ''|*[!0-9]*) die_infra "REMOTE_GATE_SUITE_TIMEOUT is '$RG_SUITE_TIMEOUT' — a whole number of seconds is required" ;; esac
  floor=$(( (RG_SUITE_TIMEOUT * 6 / 5 + 59) / 60 ))
  [ "$REMOTE_GATE_SWEEP_MIN" -ge "$floor" ] && return 0
  echo "remote-gate: note — REMOTE_GATE_SWEEP_MIN=$REMOTE_GATE_SWEEP_MIN is under the floor of $floor minutes (the suite cap plus a fifth); the sweep uses $floor" >&2
  REMOTE_GATE_SWEEP_MIN=$floor
}
_rg_knob_tmpfs() {
  [[ "${REMOTE_GATE_TMPFS_SIZE:-}" =~ ^[1-9][0-9]*[kKmMgG]?$ ]] \
    || die_infra "the knob REMOTE_GATE_TMPFS_SIZE resolved to '${REMOTE_GATE_TMPFS_SIZE:-}' — a mount size (<digits>[kKmMgG]) is required (settings row lib.remote-gate.remote_gate_tmpfs_size); nothing was sent to the host"
  return 0
}

# ── the jobs ────────────────────────────────────────────────────────────────
# Two shell programs, composed here and executed by the host: a small PREP job
# that runs before the upload, and the RUN job after it. RG_RUN_DIR is the run
# root: the host never sets it, so the baked-in path is what runs there;
# tests/remote-gate-test.sh sets it and executes these very programs locally,
# which is the only way to prove the thing that actually runs suites runs them.

# _rg_job_lib — the functions both jobs share, with the knobs baked in.
_rg_job_lib() {
  printf 'RG_SWEEP_MIN=%q RG_MIN_FREE_MB=%q RG_FREE_FACTOR=%q RG_TMPFS_SIZE=%q RG_LOCK_WAIT_S=%q\n' \
    "$REMOTE_GATE_SWEEP_MIN" "$REMOTE_GATE_MIN_FREE_MB" "$REMOTE_GATE_FREE_FACTOR" "$REMOTE_GATE_TMPFS_SIZE" "$REMOTE_GATE_LOCK_WAIT_S"
  cat <<'EOS'
# NOBODY ELSE CLEANS THIS HOST (BH-1221, widened by BH-1597). An ssh that drops
# mid-run used to leave its whole tree behind, suites mktemp'd under /tmp
# outside the run, and an older runner left loose rc-*/log-* files in /srv/tmp.
# On a 7.8 GB root that is ENOSPC for every builder on the box. So every run
# sweeps, and what it sweeps is:
#   any child of the run roots          /srv/tmp/runs/*  /srv/runs/*
#   the loose leftovers of old runners  /srv/tmp/{rc,log,cperr,runner}-*
#                                       /srv/tmp/<epoch>-<pid>*
#   suite scratch that escaped a run    /tmp/tmp.*  /tmp/scratch.*
# once it is older than REMOTE_GATE_SWEEP_MIN — and ONLY when nothing inside it
# is newer than that either, and no live process has it (or a path under it) as
# its cwd, holds a file under it open, or names it in its cmdline. The cmdline
# arm is the share-mirror leakcheck.py case: a live `leakcheck.py
# /tmp/scratch.X/mirror` with its cwd somewhere else entirely. Where /proc is
# absent the live list is empty and the age rules decide alone.
# THE ROOTS ARE A SEAM (BH-1221): RG_RUN_DIR set means a test is driving this job
# locally, and the sweep is the one part of it that reaches outside its own run,
# so it sweeps nothing unless RG_SWEEP_ROOTS (any-child roots), RG_SWEEP_SRVTMP
# and RG_SWEEP_TMP (the pattern roots) name the test's own fixtures. On the host
# none of them is set and the baked-in roots above are what is swept.
RG_SPLIT='@@remote-gate-sweep@@'
rg_live_refs() { # every path a live process holds: cwd, open fds, cmdline args (one per line)
  readlink /proc/[0-9]*/cwd /proc/[0-9]*/fd/* 2>/dev/null
  cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n'
  return 0
}
# rg_live_refs_under <path>... — the refs that mention any <path>. /proc is read
# FIRST and filtered after: a `rg_live_refs | grep -F <path>` pipeline has the
# grep alive, with <path> in its own cmdline, while /proc/*/cmdline is being
# read — so every path looked live to the check that was asking about it.
rg_live_refs_under() {
  local refs p pats=()
  for p in "$@"; do pats+=(-e "$p"); done
  [ "${#pats[@]}" -gt 0 ] || return 0
  refs=$(rg_live_refs)
  printf '%s\n' "$refs" | grep -F "${pats[@]}" 2>/dev/null
  return 0
}
# rg_unreferenced — reads "<refs>\n$RG_SPLIT\n<candidates>", prints the
# candidates no reference names. A reference names <d> when <d> occurs in it as
# a whole path: not preceded by a path character, and followed by the end, a
# `/`, or a character that cannot continue a name — so a live
# /srv/tmp/runs/12 never protects /srv/tmp/runs/1.
rg_unreferenced() {
  awk -v sep="$RG_SPLIT" '
    $0 == sep { cand = 1; next }
    !cand { if ($0 != "") ref[n++] = $0; next }
    { d = $0; hit = 0
      for (i = 0; i < n && !hit; i++) {
        s = ref[i]; off = 0
        while ((p = index(s, d)) > 0) {
          b = (off + p > 1) ? substr(ref[i], off + p - 1, 1) : ""
          a = substr(s, p + length(d), 1)
          if (b !~ /[A-Za-z0-9._\/-]/ && (a == "" || a == "/" || a !~ /[A-Za-z0-9._-]/)) { hit = 1; break }
          s = substr(s, p + 1); off += p
        }
      }
      if (!hit) print d }'
}
rg_sweep_run() { # rg_sweep_run "<any-child roots>" "<srv/tmp pattern root>" "<tmp pattern root>"
  local any="$1" srv="$2" tmp="$3" root refs d
  [ -n "$any$srv$tmp" ] || return 0
  # shellcheck disable=SC2086
  refs=$(rg_live_refs_under $any $srv $tmp)
  {
    printf '%s\n' "$refs"; printf '%s\n' "$RG_SPLIT"
    for root in $any; do
      [ -d "$root" ] && find "$root" -mindepth 1 -maxdepth 1 -mmin "+$RG_SWEEP_MIN" 2>/dev/null
    done
    [ -n "$srv" ] && [ -d "$srv" ] && find "$srv" -mindepth 1 -maxdepth 1 -mmin "+$RG_SWEEP_MIN" \
      \( -name 'rc-*' -o -name 'log-*' -o -name 'cperr-*' -o -name 'runner-*' \
         -o -name '[1-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*-[0-9]*' \) 2>/dev/null
    [ -n "$tmp" ] && [ -d "$tmp" ] && find "$tmp" -mindepth 1 -maxdepth 1 -mmin "+$RG_SWEEP_MIN" \
      \( -name 'tmp.*' -o -name 'scratch.*' \) 2>/dev/null
  } | rg_unreferenced | while IFS= read -r d; do
    [ -e "$d" ] || continue
    [ -z "$(find "$d" -mmin "-$RG_SWEEP_MIN" -print -quit 2>/dev/null)" ] || continue
    rm -rf "$d" 2>/dev/null
  done
  return 0
}
rg_sweep() {
  if [ -n "${RG_SWEEP_ROOTS:-}${RG_SWEEP_SRVTMP:-}${RG_SWEEP_TMP:-}" ]; then
    rg_sweep_run "${RG_SWEEP_ROOTS:-}" "${RG_SWEEP_SRVTMP:-}" "${RG_SWEEP_TMP:-}"
  elif [ -z "${RG_RUN_DIR:-}" ]; then
    rg_sweep_run "/srv/tmp/runs /srv/runs" /srv/tmp /tmp
  fi
  return 0
}
# rg_host_resources — what an OOM-killed or ENOSPC'd worker looks like from the
# host. A worker the kernel killed for memory and a full /srv/tmp produce the
# SAME symptom (no rc file) — /srv/tmp is a tmpfs once the prep has mounted it,
# and the root disk until then — and these numbers are the only thing that tells
# them apart. The fallbacks exist so the same job text answers off the host too,
# where free may be absent and /srv/tmp is not a path: `df -h .` then reports
# the filesystem the run is actually on.
rg_host_resources() {
  { free -m 2>/dev/null || grep -E '^(MemTotal|MemAvailable)' /proc/meminfo 2>/dev/null
    df -h /srv/tmp 2>/dev/null || df -h . 2>/dev/null
    df -h / 2>/dev/null | tail -n +2; } | sed 's/^/remote-gate:   /'
  return 0
}
rg_df() { # rg_df <path> — prints "<free MB> <mount point>", nothing when df cannot say
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print int($4 / 1024), $6; exit }'
}
EOS
}

# _rg_compose_prep_job <file> <runroot> — the job that runs BEFORE the upload.
# THE TMPFS THE DOCS PROMISED WAS NEVER THERE (BH-1597): nothing provisioned it,
# so /srv/tmp was the 7.8 GB root overlay on all four machines. This job makes it
# real — and it has to run before the upload, because a tmpfs mounted over
# /srv/tmp hides everything already in it, this run's own tree included. It
# sweeps first, then, under a lock OUTSIDE /srv/tmp that every run's prep takes,
# mounts a REMOTE_GATE_TMPFS_SIZE tmpfs ONLY when /srv/tmp is not one already,
# holds nothing but an empty runs/, and no live process references it. The run
# dir is created under the same lock, so no other run can slip a tree in between
# the check and the mount. Anything else is ONE warning line, and the run goes
# on — on the root disk, exactly as before. It never fails the run: the plain
# `mkdir -p` that follows it is what decides whether the host is reachable.
# RG_TMPFS_ROOT is the seam: a test points it at a fixture (with findmnt and
# mount stubbed), a locally driven prep without it never looks at /srv at all.
_rg_compose_prep_job() {
  local f="$1" root="$2"
  { printf 'set -uo pipefail\nR="${RG_RUN_DIR:-%s}"\n' "$root"
    _rg_job_lib
    cat <<'EOS'
rg_tmpfs_warn() { # rg_tmpfs_warn <dir> <why>
  local free
  free=$(rg_df "$1" | awk '{ printf "%.1f", $1 / 1024 }')
  echo "remote-gate: WARNING — $1 is on the root disk (${free:-?} GB free): $2" >&2
}
rg_tmpfs_try() { # rg_tmpfs_try <dir> — runs under the lock
  local d="$1" left
  findmnt -n -t tmpfs "$d" >/dev/null 2>&1 && return 0
  left=$(find "$d" -mindepth 1 ! -path "$d/runs" -print -quit 2>/dev/null)
  [ -z "$left" ] || { rg_tmpfs_warn "$d" "not mounting a tmpfs over it, it holds live or unswept work ($left)"; return 0; }
  if [ -z "$({ rg_live_refs_under "$d"; printf '%s\n%s\n' "$RG_SPLIT" "$d"; } | rg_unreferenced)" ]; then
    rg_tmpfs_warn "$d" "not mounting a tmpfs over it, a live process is using it"; return 0
  fi
  mount -t tmpfs -o "size=$RG_TMPFS_SIZE" tmpfs "$d" 2>/dev/null \
    || { rg_tmpfs_warn "$d" "mount -t tmpfs -o size=$RG_TMPFS_SIZE failed"; return 0; }
  mkdir -p "$d/runs" 2>/dev/null
  echo "remote-gate: mounted a $RG_TMPFS_SIZE tmpfs on $d (it was on the root disk)" >&2
}
rg_prep() { # rg_prep <tmpfs dir, or empty> — the check, the mount and this run's dir, under one lock
  local d="$1"
  if [ -n "$d" ]; then
    mkdir -p "$d" 2>/dev/null
    if ! command -v findmnt >/dev/null 2>&1; then
      rg_tmpfs_warn "$d" "findmnt is not on this host, so whether it is a tmpfs cannot be told"
    elif ! findmnt -n -t tmpfs "$d" >/dev/null 2>&1; then
      # BOUNDED (#1604 review, I4): a holder wedged on /proc or on a mount must
      # not stall every later gate on the host. After REMOTE_GATE_LOCK_WAIT_S the
      # prep gives up on the mount — the WARNING path, the run goes on — and
      # never mounts without the lock (I2: with no flock at all, no mount).
      if ! command -v flock >/dev/null 2>&1; then
        rg_tmpfs_warn "$d" "flock is not on this host, and a mount without the lock could hide another run"
      else
        { if flock -w "$RG_LOCK_WAIT_S" 9; then rg_tmpfs_try "$d" && mkdir -p "$R/base"
          else rg_tmpfs_warn "$d" "the mount lock ${d%/}.mount.lock stayed busy for ${RG_LOCK_WAIT_S}s; not mounting this run"; fi
        } 9>"${d%/}.mount.lock"
      fi
    fi
  fi
  mkdir -p "$R/base"
}
if [ -n "${RG_TMPFS_ROOT:-}" ]; then RG_TD="$RG_TMPFS_ROOT"
elif [ -z "${RG_RUN_DIR:-}" ]; then RG_TD=/srv/tmp
else RG_TD=""; fi
rg_sweep
rg_prep "$RG_TD" || exit 125
EOS
  } > "$f"
}

# _rg_job_header <runroot> — the RUN job's opening: the lib, the run dir, the
# host-side cleanup, suite scratch confined to the run, the sweep.
_rg_job_header() {
  printf 'set -uo pipefail\nR="${RG_RUN_DIR:-%s}"\n' "$1"
  _rg_job_lib
  cat <<'EOS'
[ -d "$R" ] || { echo "remote-gate: the run dir $R is gone from the host — nothing ran" >&2; exit 125; }
cd "$R" || exit 125
# THE HOST CLEANS UP AFTER ITSELF (BH-1597). The only trap used to be the
# CALLER's, which removes the job file on the laptop; when ssh dropped, or this
# bash was killed or hit a timeout, the host-side `rm -rf "$R"` at the end never
# ran and the tree waited for the sweep. Now EXIT removes the run, and HUP, INT,
# TERM and PIPE (a dropped ssh surfaces as a write to a dead stdout) first kill
# every process under the suite workers — so a suite does not go on writing into
# a tree that is being removed — then exit 125, which the EXIT trap turns into
# the rm. The explicit rm -rf lines below stay; this is the backstop. The work
# runs in the background and is waited for, because bash defers a trap until a
# FOREGROUND child returns, and a 25-minute suite would hold it that long.
RG_WORK=""
rg_tree() { # rg_tree <pid> — the pid and every descendant, parents first
  local c
  echo "$1"
  for c in $(pgrep -P "$1" 2>/dev/null); do rg_tree "$c"; done
}
rg_abort() {
  local round=0 pids
  trap '' HUP INT TERM PIPE
  while [ -n "$RG_WORK" ] && [ "$round" -lt 3 ]; do
    pids=$(rg_tree "$RG_WORK")
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || break
    round=$((round + 1))
  done
  exit 125
}
trap 'cd /; rm -rf "$R"' EXIT
trap rg_abort HUP INT TERM PIPE
# SUITE SCRATCH STAYS IN THE RUN (BH-1597). Suites mktemp, tests/lib/scratch.sh
# makes $TMPDIR/scratch.XXXXXX, and with TMPDIR unset all of it went to /tmp —
# outside the tree the rm above removes, so a suite that died or timed out left
# it for ever (805 MB for one share-mirror leakcheck). TMPDIR is the run's own
# tmp/ here, and each suite gets tmp/<n> below.
mkdir -p "$R/tmp" && export TMPDIR="$R/tmp"
rg_sweep
# rg_room <copies> <stream> — the pre-run free-space check. It needs
# max(REMOTE_GATE_MIN_FREE_MB, copies x du(base) x REMOTE_GATE_FREE_FACTOR) MB
# free on the run root's filesystem; short, it sweeps and measures again; still
# short, it is exit 125 and NOTHING RUNS. Starting -P copies with no idea
# whether they fit made a full disk into a runner failure mid-flight that also
# starved every other builder's run on the host. A df it cannot read is not a
# reason to refuse a run that has always worked: that is a note, and the run.
rg_room() {
  local copies="$1" out="$2" base_mb need got free fs
  base_mb=$(du -sk "$R/base" 2>/dev/null | awk '{ print int(($1 + 1023) / 1024) }')
  need=$(( copies * ${base_mb:-0} * RG_FREE_FACTOR ))
  [ "$need" -ge "$RG_MIN_FREE_MB" ] || need=$RG_MIN_FREE_MB
  got=$(rg_df "$R")
  [ -n "$got" ] || { echo "remote-gate: note — df could not read the free space under $R; the run goes ahead unchecked" >&2; return 0; }
  free=${got%% *}
  [ "$free" -ge "$need" ] && return 0
  rg_sweep
  got=$(rg_df "$R"); free=${got%% *}; fs=${got#* }
  [ -n "$got" ] && [ "$free" -ge "$need" ] && return 0
  { echo "remote-gate: RUNNER FAILURE — the test host has ${free:-?} MB free on ${fs:-?}, need $need; nothing ran"
    echo "remote-gate: This says nothing about the branch. Retry on another machine (TESTHOST_TARGET) or once the host drains:"
    rg_host_resources; } | if [ "$out" = 2 ]; then cat >&2; else cat; fi
  exit 125
}
git config --global --add safe.directory '*' >/dev/null 2>&1
EOS
  printf 'RG_CTX_HEAD=%q RG_CTX_BASE=%q RG_CTX_MB=%q RG_CTX_REF=%q\n' \
    "$RG_CTX_HEAD" "$RG_CTX_BASE" "$RG_CTX_MB" "refs/remotes/origin/$RG_BASE"
  cat <<'EOS'
# THE UPLOAD BECOMES A GIT REPO, because the check-attr and `git archive` suites
# need one. With a git context (BH-1527) the tree sits on the branch's own HEAD,
# with origin/<base> beside it and their merge base inside the shallow history —
# what CI's fetch-depth 0 checkout gives a suite. Uncommitted work in the upload
# is committed on top, as the one-commit snapshot always carried it; the tracked
# paths the upload excludes (.claude) come back from HEAD, so they do not read
# as deleted. A context that does not reproduce the client's merge base is a
# runner failure, never a run that diffs against nothing.
rg_git_c() { git -c user.email=gate@harness -c user.name=remote-gate "$@"; }
rg_snapshot() {
  local mb synth=""
  if [ -z "$RG_CTX_HEAD" ]; then
    { cd "$R/base" && git init -q && git add -A && rg_git_c commit -qm snapshot; } >/dev/null 2>&1
    return 0
  fi
  cd "$R/base" || return 1
  mv "$R/ctx.git" .git && git config core.bare false \
    && git update-ref --no-deref HEAD "$RG_CTX_HEAD" && git reset -q || return 1
  # AT ANY DEPTH, not only at the top. rsync --exclude <name> drops that name
  # wherever it appears, so a tracked tests/fixtures/x/.claude/nested.md is
  # missing from the upload exactly like a top-level .claude/ one — and with
  # top-level pathspecs here it stayed deleted, grew a synthetic commit on a
  # clean tree and showed up in every three-dot diff. The regex anchors on a
  # whole path segment, so a sibling my.claude-thing/ is untouched.
  git ls-files --deleted \
    | grep -E '(^|/)(\.claude|node_modules|\.codegraph)/' \
    | while IFS= read -r p; do git checkout -q HEAD -- "$p"; done
  [ -z "$(git status --porcelain)" ] \
    || { git add -A && rg_git_c commit -qm "remote-gate: the uncommitted work in the upload" \
           && synth=" (+ uncommitted work as $(git rev-parse HEAD))"; } || return 1
  mb=$(git merge-base HEAD "$RG_CTX_REF" 2>/dev/null)
  [ "$mb" = "$RG_CTX_MB" ] || { echo "remote-gate: the host's merge base is '${mb:-none}', the client's $RG_CTX_MB" >&2; return 1; }
  # THE REAL HEAD, and the snapshot commit LABELLED. Printing the synthetic sha
  # as HEAD put a sha in reports that exists on no branch and in no clone.
  echo "remote-gate: host git context — HEAD $RG_CTX_HEAD$synth, base ${RG_CTX_REF#refs/remotes/} $RG_CTX_BASE, merge base $mb"
}
( rg_snapshot ) || {
  echo "remote-gate: runner failure — the git context did not survive the trip to the host; nothing ran" >&2
  cd /; rm -rf "$R"; exit 125; }
# A SUITE THAT SAYS IT FOUND NO BASE IS BLIND, and fails the run whatever it
# exited. On CI that arm runs; here, a line like this was a silent pass.
RG_BLIND_RE='^[[:space:]]*(note:[[:space:]]*)?no merge base'
rg_blind() { grep -qiE "$RG_BLIND_RE" "$1" 2>/dev/null; }
rg_blind_say() { echo "remote-gate: BLIND — it printed 'no merge base': an arm that diffs against the base did not run, and on CI it would have. That fails this run."; }
RG_TO=$(command -v timeout || true)
EOS
}

_rg_compose_cmd_job() { # _rg_compose_cmd_job <file> <runroot> <command...>
  local f="$1" root="$2"; shift 2
  local q; printf -v q '%q ' "$@"
  { _rg_job_header "$root"
    cat <<EOS
rg_room 1 2
cp -a "\$R/base" "\$R/cmd" && cd "\$R/cmd" || {
  echo "remote-gate: runner failure — could not copy the tree on the host (memory or disk on the host?); the command never ran" >&2
  rg_host_resources >&2
  cd /; rm -rf "\$R"; exit 125; }
# STDERR STAYS STDERR. Under \`2>&1 | tee\` a caller capturing stdout got both
# streams, so \`remote-gate.sh . -- cmd 2>/dev/null\` could not be used to read a
# command's output. stderr is buffered and replayed after the command: the
# streams are correct, the interleaving is not preserved. The BLIND rule still
# reads BOTH files, because it did see stderr under 2>&1 and narrowing it would
# quietly loosen the rule.
# In the background and waited for, so a HUP/TERM reaches rg_abort at once.
( HARNESS_TEST_SANDBOX=1 $q 2>"\$R/cmd.err" | tee "\$R/cmd.log"
  echo "\${PIPESTATUS[0]}" > "\$R/cmd.rc" ) &
RG_WORK=\$!
wait "\$RG_WORK"
rc=\$(cat "\$R/cmd.rc" 2>/dev/null)
case "\$rc" in ''|*[!0-9]*) echo "remote-gate: runner failure — the command left no exit code" >&2; rc=125 ;; esac
cat "\$R/cmd.err" >&2
if rg_blind "\$R/cmd.log" || rg_blind "\$R/cmd.err"; then rg_blind_say; [ "\$rc" = 0 ] && rc=1; fi
cd /; rm -rf "\$R"
exit \$rc
EOS
  } > "$f"
}

_rg_compose_suites_job() { # _rg_compose_suites_job <file> <runroot> <suite...>
  local f="$1" root="$2"; shift 2
  { _rg_job_header "$root"
    echo "cat > \"\$R/suites\" <<'RG_SUITES'"
    printf '%s\n' "$@"
    echo "RG_SUITES"
    cat <<EOS
rg_n=\$(grep -c . "\$R/suites")
if [ "\$rg_n" -lt $RG_P ]; then rg_room "\$rg_n" 1; else rg_room $RG_P 1; fi
# In the background and waited for, so a HUP/TERM reaches rg_abort at once
# (a foreground pipeline would hold the trap until the slowest suite returned).
(
n=0
while IFS= read -r s; do
  [ -n "\$s" ] || continue
  n=\$((n + 1)); printf '%s\t%s\n' "\$n" "\$s"
done < "\$R/suites" \\
 | RG_R="\$R" RG_BLIND_RE="\$RG_BLIND_RE" RG_TO="\$RG_TO" RG_T="$RG_SUITE_TIMEOUT" xargs -P $RG_P -L1 bash -c '
     n=\$0; s=\$1
     # Each suite its own scratch inside the run (BH-1597), gone with its copy.
     export TMPDIR="\$RG_R/tmp/\$n"; mkdir -p "\$TMPDIR"
     # A COPY THAT FAILED IS NOT A RED SUITE. It leaves a marker and no rc file,
     # and the summary below turns that into a runner failure. The first
     # whole-corpus run on a full disk reported ten red suites this way, which
     # reads exactly like a broken branch.
     if ! cp -a "\$RG_R/base" "\$RG_R/run-\$n" 2>"\$RG_R/cperr-\$n"; then
       echo "could not copy the tree (memory or disk on the host?)" > "\$RG_R/runner-\$n"
       rm -rf "\$RG_R/run-\$n" 2>/dev/null
       echo "RUNNER-FAILURE \$s"; exit 0
     fi
     cd "\$RG_R/run-\$n" || { echo "could not enter the copy" > "\$RG_R/runner-\$n"; echo "RUNNER-FAILURE \$s"; exit 0; }
     if [ -n "\$RG_TO" ]; then
       HARNESS_TEST_SANDBOX=1 "\$RG_TO" "\$RG_T" bash "\$s" > "\$RG_R/log-\$n" 2>&1
     else
       HARNESS_TEST_SANDBOX=1 bash "\$s" > "\$RG_R/log-\$n" 2>&1
     fi
     rc=\$?; echo "\$rc" > "\$RG_R/rc-\$n"
     # THE COPY GOES BACK NOW, not at the end of the run. The prototype left
     # every per-suite copy on disk until the whole run finished, so a
     # whole-corpus run was 500-odd copies of the tree at once: the host filled
     # up, later suites failed on ENOSPC and their logs were gone by the time
     # the summary read them — 433 "failures" that were the runner, not the
     # branch. With the copy removed here, at most -P of them exist at a time.
     cd /; rm -rf "\$RG_R/run-\$n" "\$TMPDIR"
     if grep -qiE "\$RG_BLIND_RE" "\$RG_R/log-\$n" 2>/dev/null; then echo "BLIND \$s (printed no merge base, rc \$rc)"
     elif [ "\$rc" = 0 ]; then echo "PASS \$s"; else echo "FAIL \$s (rc \$rc)"; fi'
) &
RG_WORK=\$!
wait "\$RG_WORK"
fails=0; runner=0; n=0
while IFS= read -r s; do
  [ -n "\$s" ] || continue
  n=\$((n + 1))
  # NO rc FILE MEANS THE SUITE NEVER REPORTED — the copy failed, the worker was
  # killed, the disk filled. That is the runner, not the branch, and counting it
  # as a red suite is the lie this whole block exists to stop.
  if [ ! -f "\$R/rc-\$n" ]; then
    runner=\$((runner + 1))
    echo; echo "===== \$s (RUNNER FAILURE) ====="
    echo "remote-gate: \$(cat "\$R/runner-\$n" 2>/dev/null || echo 'the suite never reported an exit code')"
    cat "\$R/cperr-\$n" 2>/dev/null | tail -3
    continue
  fi
  rc=\$(cat "\$R/rc-\$n" 2>/dev/null)
  blind=0; rg_blind "\$R/log-\$n" && blind=1
  if [ "\$rc" != 0 ] || [ "\$blind" = 1 ] || [ "$RG_FULL" = 1 ]; then
    { [ "\$rc" != 0 ] || [ "\$blind" = 1 ]; } && fails=\$((fails + 1))
    echo; echo "===== \$s (rc \$rc) ====="
    [ "\$blind" = 1 ] && rg_blind_say
    [ "\$rc" = 127 ] && echo "remote-gate: rc 127 — that suite is not on this branch (nothing ran)"
    tail -$RG_TAIL "\$R/log-\$n" 2>/dev/null
  fi
done < "\$R/suites"
cd /; rm -rf "\$R"
echo
if [ "\$runner" -gt 0 ]; then
  echo "remote-gate: RUNNER FAILURE — \$runner of \$n suites never ran (\$fails of the rest failed)."
  echo "remote-gate: This says nothing about the branch. Retry with a smaller -P, or check memory or disk on the host:"
  rg_host_resources
  exit 125
fi
echo "remote-gate: \$n suites, \$fails failing"
[ "\$fails" -gt 124 ] && fails=124
exit \$fails
EOS
  } > "$f"
}

# ── run ─────────────────────────────────────────────────────────────────────
JOB=""; PREP=""
_rg_cleanup() { _rg_mlock_release; _rg_mlock_unmutex; [ -n "$RG_ISSUE_TMP" ] && rm -rf "$RG_ISSUE_TMP"; [ -n "$JOB" ] && rm -f "$JOB"; [ -n "$PREP" ] && rm -f "$PREP"; [ -n "$RG_CTX" ] && rm -rf "$RG_CTX"; return 0; }
# INT AND TERM END THE GATE (BH-1918). Cleaning up and carrying on was the old
# trap: a TERM inside the cert issue made `wait` return 143, which read as
# "flyctl exited 143", so the gate fell back to its current cert and ran the job
# with the lock already released, and the hung flyctl lived on. Now the signal
# goes to the issue's process group (plus a TERM, because the helpers a
# non-interactive flyctl wrapper puts in the background ignore INT), the
# watchdog is stopped so it never fires at a recycled pgid, and the gate exits
# 130/143. The EXIT trap does the cleanup.
_rg_on_signal() { # _rg_on_signal <signal name> <exit code>
  trap '' INT TERM
  if [ -n "$RG_BOUNDED_PGID" ]; then
    kill -"$1" -- "-$RG_BOUNDED_PGID" 2>/dev/null || kill -"$1" "$RG_BOUNDED_PGID" 2>/dev/null
    [ "$1" = TERM ] || kill -TERM -- "-$RG_BOUNDED_PGID" 2>/dev/null
  fi
  [ -n "$RG_BOUNDED_WD" ] && kill -TERM "$RG_BOUNDED_WD" 2>/dev/null
  exit "$2"
}
trap _rg_cleanup EXIT
trap '_rg_on_signal INT 130' INT
trap '_rg_on_signal TERM 143' TERM
_rg_knobs
[ "$MODE" = issue ] && { _rg_issue_only; exit $?; }
_rg_build_context
[ "$RG_TRANSPORT" = openssh ] && _rg_ensure_cert
_rg_wake
[ "$RG_TRANSPORT" = openssh ] && _rg_ensure_proxy

SSH_OPTS="-i $TESTHOST_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $TESTHOST_PORT"
# rsync's remote shell. fly-ssh: the wrapper, which reads TESTHOST_APP.
RG_RSH="ssh $SSH_OPTS"
if [ "$RG_TRANSPORT" = fly-ssh ]; then RG_RSH="$SELF_DIR/lib/remote-gate-fly-rsh.sh"; export TESTHOST_APP; fi
# _rg_remote_bash <script file> — the script on the host under `bash -s`.
_rg_remote_bash() {
  if [ "$RG_TRANSPORT" = fly-ssh ]; then _rg_fly_bash "$1"; return; fi
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "root@localhost" bash -s < "$1"
}
# The run id is unique per run so two agents draining at once never share a
# tree; $$ and the clock are enough, and the host removes the tree at the end.
RUN_ID="$(date '+%s')-$$"
# THE RUNS GO UNDER /srv/tmp, which the prep job below makes a tmpfs when it can
# (BH-1597). / on these hosts is a 7.8 GB overlay shared with the image, the
# toolchain and everybody else's leftovers; one base is ~50 MB and a -P 12 run
# holds a dozen copies, so runs on the root disk hit ENOSPC with eight agents on
# the box. Until #1597 NOTHING mounted that tmpfs — this comment said /srv/tmp
# was one, and every run landed on the root disk. Where the prep cannot mount it
# (live work already there) the run says so in one line and goes on there,
# behind the job's free-space check. The tick's busy probe looks in both
# /srv/tmp/runs and /srv/runs because other runners have used both.
RUN_ROOT="/srv/tmp/runs/$RUN_ID"

# The prep: sweep, then the tmpfs and this run's dir under one host-side lock.
# It never decides the run — a prep that fails is one note, and the plain mkdir
# after it is what says whether the host is reachable at all.
PREP=$(mktemp "${TMPDIR:-/tmp}/remote-gate-prep.XXXXXX") || die_infra "cannot create a temp file in ${TMPDIR:-/tmp}"
_rg_compose_prep_job "$PREP" "$RUN_ROOT"
_rg_remote_bash "$PREP" >&2 \
  || echo "remote-gate: note — the host-side prep (sweep, tmpfs) did not finish (rc $?); the run goes on without it" >&2

# UNDER THE MOUNT LOCK (#1604 review, I2): when the prep did not finish, this
# is the run's only mkdir, and an unlocked one could land between another run's
# emptiness check and its mount — hidden under the tmpfs, a loud 125 later.
# (After a prep that finished, the dir exists and this is a no-op.) argv, not a
# shell string: Fly's ssh server execs it without one.
# fly-ssh sends the same argv as a one-line script (RUN_ROOT is digits, - and /).
if [ "$RG_TRANSPORT" = fly-ssh ]; then
  MKJOB=$(mktemp "${TMPDIR:-/tmp}/remote-gate-mkdir.XXXXXX") || die_infra "cannot create a temp file in ${TMPDIR:-/tmp}"
  printf 'flock -w %s /srv/tmp.mount.lock mkdir -p %s\n' "$REMOTE_GATE_LOCK_WAIT_S" "$RUN_ROOT/base" > "$MKJOB"
  _rg_fly_bash "$MKJOB" >/dev/null 2>&1; MKRC=$?; rm -f "$MKJOB"
else
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "root@localhost" flock -w "$REMOTE_GATE_LOCK_WAIT_S" /srv/tmp.mount.lock \
      mkdir -p "$RUN_ROOT/base" >/dev/null 2>&1; MKRC=$?
fi
[ "$MKRC" = 0 ] \
  || die_infra "cannot create the run dir on the test host over $([ "$RG_TRANSPORT" = fly-ssh ] && echo "flyctl ssh console -a $TESTHOST_APP" || echo "the proxy on port $TESTHOST_PORT") (ssh failed, or the mount lock stayed busy ${REMOTE_GATE_LOCK_WAIT_S}s) — the machine may be stopped: bin/testhost-tick.sh state"

# WHAT GOES UP IS WHAT THE GATE NEEDS (#1604 review, I6). From a checkout that
# is the tracked files as they stand on disk plus the untracked files git does
# not ignore — what CI checks out, plus the uncommitted work — never ignored
# bulk: the lead's Mac checkout carried 100 MB of ignored refs/, which made a
# 154 MB base and, by the free-space rule, a 5.5 GB need for a -P 12 run. The
# free-space check measures du of the base that actually landed, so it follows.
# A plain directory (not a checkout) still goes up whole.
# NUL-separated end to end (ls-files -z, rsync --from0), so no file name can
# split an entry. An entry ending in "/" is an UNTRACKED NESTED REPO, which
# ls-files reports as one directory (the Mac's refs/remotes/pr/<n>/, ~100 MB):
# under --files-from rsync would recurse into it and send it whole, so it is
# skipped. (A tracked submodule is listed without the slash and still goes up.)
RG_UPLOAD_FROM=()
if [ -n "$RG_CTX" ]; then
  git -C "$DIR" ls-files -z -co --exclude-standard 2>/dev/null | while IFS= read -r -d '' f; do
    case "$f" in */) continue ;; esac
    if [ -e "$DIR/$f" ] || [ -L "$DIR/$f" ]; then printf '%s\0' "$f"; fi   # a deleted tracked file stays deleted
  done > "$RG_CTX/upload.list" \
    || die_infra "could not list the files to upload from $DIR (git ls-files) — nothing ran"
  RG_UPLOAD_FROM=(--from0 --files-from="$RG_CTX/upload.list")
fi
# shellcheck disable=SC2086
rsync -rlptD --delete -e "$RG_RSH" ${RG_UPLOAD_FROM[@]+"${RG_UPLOAD_FROM[@]}"} \
  --exclude .git --exclude node_modules --exclude .claude --exclude .codegraph \
  "$DIR/" "root@localhost:$RUN_ROOT/base/" >/dev/null 2>&1 \
  || die_infra "the upload to the test host failed (rsync) — nothing ran"
if [ -n "$RG_CTX" ]; then
  # shellcheck disable=SC2086
  rsync -rlptD --delete -e "$RG_RSH" "$RG_CTX/ctx.git/" "root@localhost:$RUN_ROOT/ctx.git/" >/dev/null 2>&1 \
    || die_infra "the upload of the git context to the test host failed (rsync) — nothing ran"
fi

JOB=$(mktemp "${TMPDIR:-/tmp}/remote-gate-job.XXXXXX") || die_infra "cannot create a temp file in ${TMPDIR:-/tmp}"
if [ "$MODE" = cmd ]; then
  _rg_compose_cmd_job "$JOB" "$RUN_ROOT" "$@"
else
  _rg_compose_suites_job "$JOB" "$RUN_ROOT" "$@"
fi

_rg_remote_bash "$JOB"
RC=$?
# 255 is ssh's own "I could not run anything", not a suite count and not a
# command's exit. Reporting it as either is the silent-pass shape this gate
# exists to make impossible.
[ "$RC" = 255 ] && die_infra "the ssh connection to the test host dropped (rc 255) — nothing can be concluded about this branch"
exit "$RC"
