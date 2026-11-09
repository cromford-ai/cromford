#!/bin/bash
# bin/testhost-tick.sh — the shared Fly test host's on-demand start and idle
# stop (BH-1205, lane `testhost-tick`).
#
#   bin/testhost-tick.sh            the cron tick: alert if the bh-ci runner
#                                   pool has been empty (or unreadable) for
#                                   CI_RUNNERS_ALERT_HOLD_MIN minutes, then
#                                   stop the host once it has been idle for
#                                   TESTHOST_IDLE_STOP_MIN
#   bin/testhost-tick.sh ensure     a run needs the host now: stamp the use and
#                                   start it if it is stopped
#   bin/testhost-tick.sh ensure --route-until <epoch>
#                                   the hub ships a pool test-host route that
#                                   lives until <epoch> (BH-8659): hold the idle
#                                   stop until then, ensure as above, and end
#                                   with one `ensure-result: <word>` line
#   bin/testhost-tick.sh used       stamp the use and nothing else
#   bin/testhost-tick.sh state [<id>] print the machine's Fly state, change nothing
#   bin/testhost-tick.sh busy       ask the host what is running, change nothing
#   bin/testhost-tick.sh idle [<id>] print the host's idle seconds (0 = busy), or
#                                   `unknown` with rc 2; change nothing
#
# EVERY MACHINE, EACH ON ITS OWN CLOCK (BH-9065). The app holds 4 hosts. The
# tick used to manage only `.[0]` and read one shared `testhost.last_used` row
# for it, so one gate run per window kept every host "in use": 0 stops in 7
# days. Now the tick visits every machine of the app. Each machine's idle clock
# is the settings row `testhost.last_used.<mid>`. The shared row is read only
# as the fallback for a machine with no row of its own, and the tick then
# copies that value into the machine's own row, so a later fresh shared row
# cannot keep that machine alive. `ensure` stamps the machine it picks or
# starts; a busy probe stamps the machine it probed. The stop needs, per
# machine: idle >= TESTHOST_IDLE_STOP_MIN, the probe says idle, no live route,
# and more machines started than TESTHOST_MIN_STARTED.
#
# WHY IT EXISTS. `bin/remote-gate.sh` runs the suite on one performance-16x
# machine shared by every agent in a drain (app `bh-testhost-example-org`, org
# board-builders). Left started, that machine bills all night for the 23 hours
# nobody is draining; stopped by hand, the next agent's gate run fails on a
# connection refused. So the machine follows the work: `ensure` before a run,
# and this tick stops it once the work stops.
#
# THE STOP NEEDS TWO WITNESSES, AND THE MACHINE IS THE SENIOR ONE.
#   1. `testhost.last_used`, a settings row, is ADVISORY: it says when somebody
#      last told us a run was starting. It is written by a gate run that HAS a
#      worker credential — and a Mac does not, so a full Mac drain can leave the
#      row untouched for hours while sixteen suites a minute run on the host.
#      A lane that stopped on that row alone would kill that drain, restart on
#      the next `ensure`, and kill it again thirty minutes later, for ever.
#   2. `_th_busy` ASKS THE MACHINE what is running (run directories INSIDE
#      /srv/tmp, /srv/tmp/runs and /srv/runs — never those roots themselves,
#      whose mtimes move on every run; live `bash tests/…` and `bash -s`). Busy means
#      no stop AND the row is refreshed, so the lane repairs its own bookkeeping
#      for the runners that cannot write it.
# Both must agree before anything is stopped, and every way of not knowing —
# an unreachable worker, an unreadable machine state, a failed probe — is
# treated as busy. The cost of not stopping is a machine that bills until the
# next tick; the cost of stopping wrongly is somebody's drain.
#
# `ensure` is the deliberate exception to the "worker answered" rule: there the
# start is what a human just asked for and the stamp is only bookkeeping, so a
# silent worker costs a loud line, not the run.
#
# A SHIPPED POOL ROUTE HOLDS THE STOP (BH-8659). A pool machine reaches the
# host with an app-scoped SSH token (bin/lib/pool-testhost-route.sh), which
# cannot start a machine. So the hub runs `ensure --route-until <expiry>` before
# each route ship, and that writes the settings row `testhost.route_until` (the
# latest expiry, a decimal epoch). While that row is in the future, the tick
# does not stop the host and `idle` answers 0, so bin/fly-idle-reaper.sh does
# not stop it either. A row we cannot read is "do not stop", as above.
#
# WHY flyctl AND NOT bin/fly-api.sh. fly-api.sh is the builder pool's HTTP
# client: it is keyed on `state/fly/<project>.json` and a per-PROJECT deploy
# token, neither of which a shared host has, and it hardcodes the hub's harness
# path so it cannot run from a Mac. This lane already requires flyctl for the
# gate's proxy and its ssh certificate, so start/stop go the same way
# bin/fly-machine-state.sh reads status: one CLI, already installed, already
# authenticated. Adding an HTTP path here would be the second Fly client, not
# the first.
#
# Knobs (registry: catalog/lanes.json, lane `testhost-tick`):
#   TESTHOST_APP             the Fly app             (bh-testhost-example-org)
#   TESTHOST_IDLE_STOP_MIN   minutes of idle before the stop   (10)
#   TESTHOST_MIN_STARTED     the tick never stops below this many started
#                            machines                           (0)
#   TESTHOST_SIZE            the size the lane expects; a machine that is not
#                            that size is logged, never resized  (performance-16x)
#   TESTHOST_BUSY_WINDOW_MIN how recent a run root's mtime must be to count as
#                            live work in the busy probe            (120)
#   CI_RUNNERS_ALERT_HOLD_MIN minutes the bh-ci pool must read empty (or
#                            unreadable) continuously before the tick alerts,
#                            0 = the pool check is off                (10)
#   TESTHOST_DISK_ALERT_PCT  alert testhost-disk-<machine> when a started
#                            machine's ROOT disk is above this percent, 0 = off;
#                            every started machine is probed and logged (85,
#                            registry default — no literal here, BH-1597)
#   TESTHOST_UNKNOWN_ALERT_TICKS consecutive ticks that read state=unknown
#                            before testhost-state-unknown is raised  (3)
# Machines: every machine of the app (BH-9065). `testhost.machine_id` (a
# settings row), if there is one, is the machine `ensure` prefers and the one
# `state` reads with no id; else the first machine in the app.
#
# THE SECOND THING THIS TICK DOES (BH-1210). Harness CI runs on the Fly `bh-ci`
# pool with NO GitHub-hosted fallback: when the machines are gone the jobs QUEUE
# rather than fail, so no PR turns red, nothing pages, and the drain just stops
# merging. `bin/ci-runners-status.sh` can answer that question; this lane is the
# */5 caller that turns the answer into one alert. It rides here rather than in
# a cron line of its own because the read is one REST call and this lane already
# runs on the hub at the right cadence with the settings rows the streak needs.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
# OFF-HUB, THE HARNESS IS THE REPO THIS SCRIPT LIVES IN. A Mac running the gate
# has no /root/harness, so every path below (env/, flags/, logs/, the settings
# client) resolved under a directory that does not exist and the use was never
# recorded — which is the input the idle stop reads. Falling back to the
# checkout is what lets a laptop stamp its own runs once its env/global.env
# carries HARNESS_SECRET and JOBS_URL. A directory that EXISTS is never
# overridden, so nothing changes on a box.
[ -d "$HARNESS" ] || HARNESS=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
H="$HARNESS"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")

# shellcheck disable=SC1091
. "${HARNESS}/bin/lib/lane-gate.sh" 2>/dev/null || . "$(dirname "$0")/lib/lane-gate.sh" 2>/dev/null || true
# BH-4080: HARNESS_REPO, the CI health row's repo when nothing else names one.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
# flyctl's path, PATH first and then the install directories (BH-6061).
# shellcheck source=bin/lib/fly-bin.sh
. "${HARNESS}/bin/lib/fly-bin.sh" 2>/dev/null || . "$(dirname "$0")/lib/fly-bin.sh" || exit 1
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit testhost-tick
# ...and the knobs, from the same registry (BH-1165). Without this the four
# TESTHOST_* rows an operator writes on the settings page are decoration: the
# page reports `source: settings` and the lane goes on reading its own default.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    testhost-tick

APP="${TESTHOST_APP:-bh-testhost-example-org}"
# Fallback 10 = the registry default of TESTHOST_IDLE_STOP_MIN
# (catalog/lanes.d/testhost-tick.json, settings row lane.testhost-tick.testhost_idle_stop_min).
IDLE_MIN="${TESTHOST_IDLE_STOP_MIN:-10}"
# Fallback 0 = the registry default of TESTHOST_MIN_STARTED
# (catalog/lanes.d/testhost-tick.knobs.d/TESTHOST_MIN_STARTED.json).
MIN_STARTED="${TESTHOST_MIN_STARTED:-0}"
WANT_SIZE="${TESTHOST_SIZE:-performance-16x}"
BUSY_WINDOW_MIN="${TESTHOST_BUSY_WINDOW_MIN:-120}"
VERB="${1:-tick}"

CI_HOLD_MIN="${CI_RUNNERS_ALERT_HOLD_MIN:-10}"
# NO LITERAL (BH-1597): a `required` registry knob, set by lane_env_apply above
# from the row, the cache, the env or the registry default. Unresolved (no gate
# library on this box) it is empty, and the disk check logs and alerts nothing.
DISK_ALERT_PCT="${TESTHOST_DISK_ALERT_PCT:-}"

case "$IDLE_MIN" in ''|*[!0-9]*) IDLE_MIN=10 ;; esac
case "$MIN_STARTED" in ''|*[!0-9]*) MIN_STARTED=0 ;; esac
case "$BUSY_WINDOW_MIN" in ''|*[!0-9]*) BUSY_WINDOW_MIN=120 ;; esac
case "$CI_HOLD_MIN" in ''|*[!0-9]*) CI_HOLD_MIN=10 ;; esac
UNKNOWN_TICKS="${TESTHOST_UNKNOWN_ALERT_TICKS:-3}"
case "$UNKNOWN_TICKS" in ''|*[!0-9]*|0) UNKNOWN_TICKS=3 ;; esac

log() {
  mkdir -p "$H/logs" 2>/dev/null || return 0
  printf '%s testhost-tick: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$H/logs/testhost-tick.log" 2>/dev/null
  return 0
}
# say is log + stdout, not a second writer. The cron line appends this lane's
# stdout to the same file log() writes, so an unlogged `echo` landed in the
# middle of the timestamped lines with no stamp of its own.
say() { log "$*"; echo "testhost-tick: $*"; }

# ── the worker (settings rows) ──────────────────────────────────────────────
# jobs-client.sh is sourced lazily and never fatally: off-hub (a Mac running
# `ensure` through the gate) there is no harness to source it from, and that is
# a lane with no bookkeeping, not a lane that refuses to work.
# shellcheck disable=SC1091
. "$HARNESS/bin/jobs-client.sh" 2>/dev/null || . "$(dirname "$0")/jobs-client.sh" 2>/dev/null || true

_th_get() { # _th_get <key> — rc 0 value, rc 2 no row, rc 1 no answer
  command -v setting_get >/dev/null 2>&1 || return 1
  setting_get "$1" 2>/dev/null
}
_th_set() { # _th_set <key> <value>
  command -v setting_set >/dev/null 2>&1 || return 1
  setting_set "$1" "$2" "testhost-tick" >/dev/null 2>&1
}

# ── Fly ─────────────────────────────────────────────────────────────────────
# The token, if this box has one, the way bin/fly-pool-rollout.sh resolves it:
# indirect expansion over a list of names, so a scoped token wins over the org
# one and neither becomes a `${NAME:-}` read that the registry would have to
# carry as an operator knob.
_th_token() {
  local v tok
  [ -r "$HENV/fly.env" ] && { set -a; . "$HENV/fly.env" 2>/dev/null || true; set +a; }
  for v in FLY_API_TOKEN_TESTHOST FLY_API_TOKEN FLY_ACCESS_TOKEN; do
    tok="${!v:-}"
    [ -n "$tok" ] && { printf '%s' "$tok"; return 0; }
  done
  return 1
}

# THE LOOKUP COMES BEFORE ANY CHECK (BH-6061). The old `command -v flyctl ||
# return 127` ran before /root/.fly/bin went on PATH, and cron's PATH has no
# /root/.fly/bin, so from cron every call here returned 127 and every tick read
# state=unknown for 13 days. fly_bin looks in PATH first, then the install
# directories, so a stub on PATH is never shadowed by an installed flyctl.
_th_fly() { # _th_fly <args...> — flyctl, with whatever credential this box has
  local tok bin
  bin=$(fly_bin) || return 127
  tok=$(_th_token) || tok=""
  if [ -n "$tok" ]; then
    FLY_ACCESS_TOKEN="$tok" FLY_API_TOKEN="$tok" "$bin" "$@"
  else
    "$bin" "$@"
  fi
}

# _th_fail_cause <output> <what failed> — set TH_CAUSE for a flyctl call that
# failed. The output's first line goes in, cut to 120 characters and with any
# token shape replaced, because the cause lands in an alert and in the log.
TH_CAUSE=""
_th_fail_cause() {
  local line
  if ! fly_bin >/dev/null 2>&1; then
    TH_CAUSE="flyctl not found (PATH, \$HOME/.fly/bin, /root/.fly/bin)"
    return 0
  fi
  line=$(printf '%s\n' "$1" | sed -n '/[^[:space:]]/{p;q;}' \
    | sed -E 's/FlyV1 [^ ]*/[redacted]/g; s/fm[0-9]_[A-Za-z0-9_-]*/[redacted]/g' | cut -c1-120)
  if grep -qiE 'unauthori|not authenticated|401|access token' <<<"$1"; then
    TH_CAUSE="auth failure: $line"
  else
    TH_CAUSE="$2: $line"
  fi
}

# _th_machine_load — set MID, rc 1 (TH_CAUSE says why) when the app has none
# we can see. It sets a global rather than printing so the cause survives;
# _th_machine is the printing form for callers inside $(…).
# _th_list_ids — set TH_IDS to every machine id of $APP (one per line, in the
# order Fly lists them), rc 1 (TH_CAUSE says why) when the list fails or is
# empty. An id that is not [a-z0-9] is dropped: it goes into flyctl argv and a
# settings key.
TH_IDS=""
_th_list_ids() {
  local out rc errf
  TH_IDS=""
  errf=$(mktemp) || errf=/dev/null
  out=$(_th_fly machine list -a "$APP" --json 2>"$errf"); rc=$?
  if [ "$rc" != 0 ]; then
    _th_fail_cause "$(cat "$errf" 2>/dev/null; printf '%s' "$out")" "no machine id: machine list failed"
    [ "$errf" = /dev/null ] || rm -f "$errf"
    return 1
  fi
  [ "$errf" = /dev/null ] || rm -f "$errf"
  TH_IDS=$(printf '%s' "$out" | jq -r '.[]? | .id // empty | select(test("^[a-z0-9]+$"))' 2>/dev/null)
  [ -n "$TH_IDS" ] || { TH_CAUSE="no machine id: $APP lists no machine"; return 1; }
  return 0
}

MID=""
_th_machine_load() {
  local id
  [ -n "$MID" ] && return 0
  id=$(_th_get testhost.machine_id) || id=""
  if [ -z "$id" ]; then
    _th_list_ids || return 1
    id=$(head -n 1 <<<"$TH_IDS")
  fi
  MID="$id"
}
_th_machine() { # print the machine id, rc 1 when the app has none we can see
  _th_machine_load || return 1
  printf '%s' "$MID"
}

# _th_read_state — sets TH_STATE (started|stopped|purged|…|unknown) and
# OBSERVED_SIZE. It SETS GLOBALS rather than printing, because a `$(…)` call
# runs in a subshell and everything the read learned about the machine's size
# would die with it — which is how a size-drift check becomes a function that
# can only ever report "no drift".
#
# A machine destroyed hours ago is PURGED from the API and answers "was not
# found in app" rather than destroyed — the same fact bin/fly-machine-state.sh
# carries, and the reason that string is matched here. The size the machine
# really is comes out of the same answer: CPU Kind plus vCPUs is what Fly calls
# performance-16x.
#
# Every unknown sets TH_CAUSE (BH-6061): an unknown with no cause is what let the
# cron PATH bug run for 13 days as a quiet "nothing to stop".
# _th_read_state [<id>] reads <id>, or with no id the machine _th_machine_load
# names.
TH_STATE=unknown
OBSERVED_SIZE=""
_th_read_state() {
  local id="${1:-}" out norm kind vcpu state
  TH_STATE=unknown; OBSERVED_SIZE=""; TH_CAUSE=""
  if [ -z "$id" ]; then
    _th_machine_load || return 0
    id="$MID"
  fi
  out=$(_th_fly machine status "$id" -a "$APP" </dev/null 2>&1) || { _th_fail_cause "$out" "API error"; return 0; }
  case "$out" in *"was not found in app"*) TH_STATE=purged; return 0 ;; esac
  state=$(printf '%s\n' "$out" | awk -F': *' '/^State:/{print $2; exit}' | tr -d '[:space:]')
  [ -n "$state" ] || { TH_CAUSE="no State: line in flyctl output"; return 0; }
  TH_STATE="$state"
  norm=$(printf '%s\n' "$out" | sed 's/│/|/g')
  kind=$(printf '%s\n' "$norm" | awk -F'|' '/CPU Kind/{gsub(/[ \t]/,"",$2); print $2; exit}')
  vcpu=$(printf '%s\n' "$norm" | awk -F'|' '/vCPUs/{gsub(/[ \t]/,"",$2); print $2; exit}')
  [ -n "$kind" ] && [ -n "$vcpu" ] && OBSERVED_SIZE="$kind-${vcpu}x"
  return 0
}

# _th_size_note — one line when the machine is not the size the lane says it is.
# It is a NOTE, never a resize: changing the shape of a machine other agents are
# connected to is not something a */5 cron gets to decide.
_th_size_note() { # _th_size_note [<id>]
  local m="${1:+ $1}"
  [ -n "$OBSERVED_SIZE" ] || return 0
  if [ "$OBSERVED_SIZE" = "$WANT_SIZE" ]; then
    log "size ok${m}: $OBSERVED_SIZE"
  else
    log "size drift: the machine${m} is $OBSERVED_SIZE, TESTHOST_SIZE says $WANT_SIZE (not resized — flyctl machine update --vm-size $WANT_SIZE${1:+ $1} -a $APP, when nobody is on it)"
  fi
}

# _th_stamp_use [<id>] — with an id, that machine's own clock
# (testhost.last_used.<id>, BH-9065); with none, the shared row. rc 0 written,
# rc 1 the worker did not take it.
_th_stamp_use() {
  _th_set "testhost.last_used${1:+.$1}" "$(date -u '+%s')"
}

# _th_route_max_s — the longest a route hold may reach past now: the registry
# max of POOL_TESTHOST_TOKEN_HOURS (a pool route token never lives longer), in
# seconds. 72 is that file's max, the fallback when it cannot be read
# (catalog/lanes.d/fly-pool.knobs.d/POOL_TESTHOST_TOKEN_HOURS.json).
_th_route_max_s() {
  local h
  h=$(jq -r '.max // empty' "$(dirname "${BASH_SOURCE[0]}")/../catalog/lanes.d/fly-pool.knobs.d/POOL_TESTHOST_TOKEN_HOURS.json" 2>/dev/null)
  case "$h" in ''|*[!0-9]*|0) h=72 ;; esac
  printf '%s\n' "$(( h * 3600 ))"
}

# _th_hold_route <epoch> — raise `testhost.route_until` to <epoch> (never lower
# it), clamped to now + _th_route_max_s. A value that is not a future epoch
# writes nothing. rc 0 always: the ensure runs either way.
_th_hold_route() {
  local want="${1:-}" now max cur
  now=$(date -u '+%s')
  case "$want" in ''|*[!0-9]*) want="" ;; esac
  # more than 12 digits would overflow bash arithmetic; it is far future anyway
  if [ -n "$want" ] && [ "${#want}" -le 12 ] && [ "$want" -le "$now" ]; then want=""; fi
  if [ -z "$want" ]; then
    say "ensure: --route-until '${1:-}' is not a future epoch — no route hold written"
    return 0
  fi
  max=$(( now + $(_th_route_max_s) ))
  if [ "${#want}" -gt 12 ] || [ "$want" -gt "$max" ]; then want="$max"; fi
  cur=$(_th_get testhost.route_until) || cur=""
  case "$cur" in ''|*[!0-9]*) cur="" ;; esac
  if [ -n "$cur" ] && [ "${#cur}" -le 12 ] && [ "$cur" -ge "$want" ] && [ "$cur" -le "$max" ]; then
    return 0
  fi
  _th_set testhost.route_until "$want" \
    || say "the worker did not take testhost.route_until — the idle stop cannot see this route"
  return 0
}

# _th_route_live — rc 0 a shipped pool route is live (testhost.route_until is
# in the future; TH_ROUTE_UNTIL holds it), rc 1 no live route (no row, a past
# row, a row that is not an epoch), rc 2 the worker did not answer.
TH_ROUTE_UNTIL=""
_th_route_live() {
  local v rc now
  TH_ROUTE_UNTIL=""
  v=$(_th_get testhost.route_until); rc=$?
  [ "$rc" = 1 ] && return 2
  [ "$rc" = 0 ] || return 1
  case "$v" in
    ''|*[!0-9]*) log "testhost.route_until is not an epoch ('$v') — no route hold"; return 1 ;;
  esac
  [ "${#v}" -le 12 ] || { log "testhost.route_until is out of range ('$v') — no route hold"; return 1; }
  now=$(date -u '+%s')
  [ "$v" -gt "$now" ] || return 1
  TH_ROUTE_UNTIL="$v"
  return 0
}

# _th_busy — ASK THE MACHINE, do not infer from a row.
#   rc 0 = work is running (never stop)
#   rc 1 = provably idle
#   rc 2 = could not tell (never stop)
# BUSY_N carries the count.
#
# WHY THIS EXISTS AND WHY IT OUTRANKS THE ROW. `testhost.last_used` is written
# by whoever ran the gate — and a Mac has no worker credential, so a full Mac
# drain can leave the row untouched for hours while sixteen suites a minute run
# on the host. A stop decided from that row alone kills the drain and then does
# it again every thirty minutes, which is the exact failure the header calls the
# wrong default. So the row became ADVISORY (it says when we last heard about a
# run) and this probe is the evidence (it says what is running right now).
#
# What counts as work: a run root under /srv/tmp, /srv/tmp/runs or /srv/runs
# whose mtime is inside TESTHOST_BUSY_WINDOW_MIN — all three, because different
# runners on this host have used different roots and a stop must not depend on
# which one a colleague picked — or a live `bash tests/…` (a suite) or `bash -s`
# (a gate job arriving over ssh). The pgrep patterns are bracketed
# (`[b]ash`) so the probe cannot match its own command line and report itself
# as work.
#
# THE RUN ROOTS THEMSELVES ARE EXCLUDED, and that is not cosmetic: /srv/tmp/runs
# is a depth-1 child of /srv/tmp, and its own mtime moves every time a run
# directory is created or removed inside it. Listing it made an EMPTY host read
# `busy 1` for the whole TESTHOST_BUSY_WINDOW_MIN (120 minutes) after the last
# gate run, so TESTHOST_IDLE_STOP_MIN (30) never decided anything — the knob was
# overridden in the safe direction by a directory nobody was using (#1213
# review). A run INSIDE any of the three roots still counts.
#
# EVERY FAILURE IS BUSY. A probe that cannot reach the host, a flyctl without a
# certificate, a machine that answers something unparseable: all rc 2, all no
# stop. The cost of not stopping is a machine that bills until the next tick
# succeeds; the cost of stopping wrongly is somebody's drain.
#
# _th_busy [<machine-id>]: with an id the probe goes to that machine (the `idle`
# verb); with none it goes where flyctl picks, which is what the tick has always
# done.
BUSY_N=0
_th_busy() {
  local mid="${1:-}" out n probe
  BUSY_N=0
  probe='/bin/sh -c '"'"'d=$(find /srv/tmp /srv/tmp/runs /srv/runs -mindepth 1 -maxdepth 1 ! -path /srv/tmp/runs ! -path /srv/runs -mmin -'"$BUSY_WINDOW_MIN"' 2>/dev/null | wc -l); p=$(pgrep -fc "[b]ash tests/|[b]ash -s" 2>/dev/null); [ -n "$p" ] || p=0; echo TESTHOST_BUSY $((d+p))'"'"
  if [ -n "$mid" ]; then
    out=$(_th_fly ssh console -a "$APP" --machine "$mid" -C "$probe" </dev/null 2>&1) || return 2
  else
    out=$(_th_fly ssh console -a "$APP" -C "$probe" 2>&1) || return 2
  fi
  n=$(printf '%s\n' "$out" | awk '/^TESTHOST_BUSY /{print $2; exit}')
  case "$n" in ''|*[!0-9]*) return 2 ;; esac
  BUSY_N="$n"
  [ "$n" -gt 0 ] && return 0
  return 1
}

_th_record_state() { # _th_record_state <state>
  case "$1" in ''|unknown) return 0 ;; esac
  _th_set testhost.machine_state "$1" || return 1
  return 0
}

# ── the unknown-state streak (BH-6061) ──────────────────────────────────────
# A tick that cannot read the machine state stops nothing, which is the safe
# direction for one tick and a silent bill for many. So the streak is counted in
# state/testhost-tick/unknown-streak as `<count> <fired 0|1> <cause>`, and at
# TESTHOST_UNKNOWN_ALERT_TICKS one testhost-state-unknown alert names the cause.
# The file is box-local on purpose: losing it on a hub-lease move only delays
# the alert. SEND FIRST, STAMP SECOND, as everywhere in this lane.
_th_unknown_note() {
  local f n=0 fired=0 cause="" text
  f="$H/state/testhost-tick/unknown-streak"
  [ -f "$f" ] && read -r n fired cause < "$f"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  case "$fired" in 1) ;; *) fired=0 ;; esac
  if [ "$TH_STATE" != unknown ]; then
    [ -f "$f" ] || return 0
    if [ "$fired" = 1 ]; then
      if _ci_send_resolve testhost-state-unknown "testhost-tick reads $APP again: state $TH_STATE after $n unknown ticks."; then
        rm -f "$f"; log "testhost-state-unknown resolved (state $TH_STATE)"
      else
        log "could not send the testhost-state-unknown resolve — the streak file stays and the next tick retries"
      fi
    else
      rm -f "$f"
    fi
    return 0
  fi
  n=$(( n + 1 ))
  cause="${TH_CAUSE:-no cause recorded}"
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s %s %s\n' "$n" "$fired" "$cause" > "$f" 2>/dev/null || log "could not write $f — the unknown streak is not counted"
  [ "$fired" = 1 ] && return 0
  [ "$n" -ge "$UNKNOWN_TICKS" ] || return 0
  text="testhost-tick read state=unknown for $APP on $n ticks in a row. Cause: $cause. The idle stop cannot run while the state is unknown, so the host can bill with nobody on it. Run bin/testhost-tick.sh state on the hub to check."
  if _ci_send testhost-state-unknown warn "$text"; then
    printf '%s 1 %s\n' "$n" "$cause" > "$f" 2>/dev/null \
      || log "the testhost-state-unknown alert went out but $f was not stamped — the next tick may repeat it (--id dedup catches that)"
    say "state unknown on $n ticks in a row — alerted (testhost-state-unknown): $cause"
  else
    log "the testhost-state-unknown alert did not send — the next tick tries again"
  fi
  return 0
}

# ── the bh-ci runner pool (BH-1210) ─────────────────────────────────────────
# THREE OUTCOMES, AND THEY STAY APART. bin/ci-runners-status.sh answers rc 0
# (something is online), rc 1 (the pool answered and nothing is online) or rc 2
# (the read failed or did not parse). Collapsing rc 2 into rc 1 is the failure
# that hides the failure: a 403 on the Actions endpoint would page the fleet
# about a pool that is perfectly healthy, and the day the pool really went the
# page would be indistinguishable. So each has its own condition id, and a read
# we could not make never closes one we could.
#
# AND A TEN-MINUTE HOLD, because ephemeral runners consume their registration
# per job and re-register: a single read taken while a run is landing shows a
# chunk of the pool offline. That is churn. The streak lives in two settings
# rows, the same store the lane already keeps `testhost.last_used` in, so it
# survives a hub-lease move; `0` means no streak, `<epoch>` means one is open,
# `<epoch>:fired` means the alert has been sent and this outage is done talking.
#
# SEND FIRST, STAMP SECOND, everywhere below. "Stamped as alerted but never
# delivered" is an outage nobody hears about for ever; the reverse (delivered
# twice) is caught by --id dedup in bin/lib/alert-state.sh.
_ci_status_bin() { # print the status script, rc 1 when there is none to run
  local b
  for b in "$H/bin/ci-runners-status.sh" "$(dirname "$0")/ci-runners-status.sh"; do
    [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

_ci_send() { # _ci_send <id> <severity> <text> — rc 0 only when it really went
  [ -x "$H/bin/lane-alert.sh" ] || { log "bin/lane-alert.sh is not here — $1 cannot be sent"; return 1; }
  "$H/bin/lane-alert.sh" --severity "$2" --id "$1" testhost-tick "$3" >/dev/null 2>&1 || return 1
  return 0
}
_ci_send_resolve() { # _ci_send_resolve <id> <text>
  [ -x "$H/bin/lane-alert.sh" ] || return 1
  "$H/bin/lane-alert.sh" --resolve --id "$1" testhost-tick "$2" >/dev/null 2>&1 || return 1
  return 0
}

# _ci_hold <row-key> <now> — the streak clock for one condition.
#   rc 0  fire NOW (the hold has elapsed and nothing has been sent yet)
#   rc 1  say nothing (streak just started, still inside the hold, already
#         fired, or the worker would not answer)
# CI_SINCE and CI_MIN carry the open streak's epoch and its measured age.
CI_SINCE=0
CI_MIN=0
_ci_hold() {
  local key="$1" now="$2" row rc since fired age
  row=$(_th_get "$key"); rc=$?
  if [ "$rc" = 1 ]; then
    log "the worker did not answer for $key — no pool alerting this tick"
    return 1
  fi
  [ "$rc" = 2 ] && row=""
  fired=""
  case "$row" in
    *:fired) since="${row%%:*}"; fired=1 ;;
    *)       since="$row" ;;
  esac
  # An unreadable row is no streak, never a zero-second one: never compare a
  # string nobody validated with -ge.
  case "$since" in
    ''|0) since="" ;;
    *[!0-9]*) log "$key is not an epoch ('$row') — restarting the clock"; since=""; fired="" ;;
  esac
  if [ -z "$since" ]; then
    _th_set "$key" "$now" || { log "the worker would not take the $key stamp — the clock stays unstarted"; return 1; }
    return 1
  fi
  CI_SINCE="$since"
  age=$(( now - since ))
  # A clock that went backwards gives a negative age, which is simply not past
  # the hold. Wrong in the quiet direction, on purpose.
  CI_MIN=$(( age / 60 ))
  [ -n "$fired" ] && return 1
  [ "$age" -ge "$(( CI_HOLD_MIN * 60 ))" ] || return 1
  return 0
}

# _ci_close <row-key> <id> <text> — clear a streak, and resolve the condition if
# one was ever announced. A streak that never reached the hold was never told to
# anybody, so it is thrown away in silence: retracting something nobody heard is
# the same noise with one sign flipped (bin/lane-alert.sh says so too, and is
# silent on an unknown id — this keeps the lane from making the call at all).
_ci_close() {
  local key="$1" id="$2" text="$3" row rc
  row=$(_th_get "$key"); rc=$?
  [ "$rc" = 1 ] && return 1
  [ "$rc" = 2 ] && row=""
  case "$row" in ''|0) return 0 ;; esac
  case "$row" in
    *:fired) ;;
    *) _th_set "$key" 0 || log "the worker would not clear $key after the streak ended"
       log "$id: the streak ended before the ${CI_HOLD_MIN}m hold — clock cleared, nobody was told"
       return 0 ;;
  esac
  if _ci_send_resolve "$id" "$text"; then
    _th_set "$key" 0 || log "the resolve for $id went out but the worker would not clear $key"
    log "$id resolved"
  else
    log "could not send the $id resolve — $key keeps its value and the next tick retries"
  fi
  return 0
}

# _ci_counts <json> — the numbers for the alert text, rc 1 when the body did
# not parse. A body we cannot read ships an alert WITHOUT counts rather than
# with invented ones; the rc from the status script is what is authoritative.
CI_TOTAL=""; CI_ONLINE=""; CI_OFFLINE=""; CI_REPO=""; CI_LABEL=""
_ci_counts() {
  local tsv
  CI_TOTAL=""; CI_ONLINE=""; CI_OFFLINE=""; CI_REPO=""; CI_LABEL=""
  command -v jq >/dev/null 2>&1 || return 1
  tsv=$(printf '%s' "$1" | jq -r '
    if (type != "object") or (has("total")|not) then empty
    else [(.total|tostring), (.online|tostring), (.offline|tostring), (.repo//""), (.label//"")] | @tsv end' 2>/dev/null)
  [ -n "$tsv" ] || return 1
  IFS=$'\t' read -r CI_TOTAL CI_ONLINE CI_OFFLINE CI_REPO CI_LABEL <<< "$tsv"
  [ -n "$CI_TOTAL" ] || return 1
  return 0
}

# _ci_health_push <out> <rc> — the pool snapshot to the worker's ci_health table
# as (repo, "runners") (BH-2633). Best-effort: always rc 0, and it sets none of
# the CI_* values the alert branches use. No ci_health_put (off-hub, no
# jobs client) is a silent skip. rc 2 is {unreadable:true}, never total 0; an
# rc 0/1 body that did not parse sends nothing, because the rc says the pool
# answered and any counts would be invented.
_ci_health_push() {
  local out="$1" rc="$2" repo payload
  command -v ci_health_put >/dev/null 2>&1 || return 0
  # CI_REPO is _ci_counts' parse of the body; with no body (rc 2) it is the
  # status script's own default repo (bin/ci-runners-status.sh).
  repo="${CI_REPO:-${CI_RUNNERS_SLUG:-$HARNESS_REPO}}"
  if [ "$rc" = 2 ]; then
    payload='{"unreadable":true,"rc":2}'
  else
    payload=$(printf '%s' "$out" | jq -c --argjson rc "$rc" '
      if (type == "object") and has("total") then {label, total, online, idle, busy, offline, rc: $rc} else empty end' 2>/dev/null)
    if [ -z "$payload" ]; then
      log "ci-health: the pool answered rc $rc but its counts did not parse — no runners snapshot sent"
      return 0
    fi
  fi
  ci_health_put "$repo" runners "$payload" \
    || log "ci-health: runners snapshot push failed for $repo (rc $rc) — the alert check below is unaffected"
  return 0
}

cmd_ci_runners() {
  local bin out rc now where text back
  [ "$CI_HOLD_MIN" = 0 ] && return 0
  now=$(date -u '+%s')
  if bin=$(_ci_status_bin); then
    out=$("$bin" --json 2>/dev/null); rc=$?
  else
    # NOT BEING ABLE TO RUN THE READ IS "NOTHING IS KNOWN", never "no runners".
    out=""; rc=2
    log "bin/ci-runners-status.sh is not here or not executable — the pool is unreadable, not empty"
  fi
  case "$rc" in 0|1|2) ;; *) rc=2 ;; esac
  _ci_counts "$out" || true
  _ci_health_push "$out" "$rc"
  where="${CI_REPO:-the repo}${CI_LABEL:+ (label $CI_LABEL)}"

  case "$rc" in
    0)
      # THE RC IS THE ANSWER, the body is only wording. rc 0 means at least one
      # runner is online, so a body that came back saying 0 (or did not parse at
      # all) must not make the resolve say "0 of 74 online" — a close that reads
      # like an outage is a status line that is false in the state it renders.
      back="at least one"
      case "$CI_ONLINE" in ''|0) ;; *) back="$CI_ONLINE" ;; esac
      log "bh-ci pool: $back of ${CI_TOTAL:-?} runners online — nothing to say"
      _ci_close ci_runners.empty_since ci-runners-empty \
        "bh-ci runners are back: $back of ${CI_TOTAL:-?} registered runners online on $where. Harness CI jobs run again."
      _ci_close ci_runners.unreadable_since ci-runners-unreadable \
        "bin/ci-runners-status.sh can read the bh-ci pool again."
      ;;
    1)
      # The read WORKED, so whatever we could not read before, we can now.
      _ci_close ci_runners.unreadable_since ci-runners-unreadable \
        "bin/ci-runners-status.sh can read the bh-ci pool again."
      if _ci_hold ci_runners.empty_since "$now"; then
        if [ -n "$CI_TOTAL" ]; then
          text="bh-ci runner pool EMPTY for ${CI_MIN}m: 0 of $CI_TOTAL registered runners online on $where."
        else
          text="bh-ci runner pool EMPTY for ${CI_MIN}m: bin/ci-runners-status.sh answered rc 1 and its body did not parse, so there are no counts."
        fi
        # WHAT AN EMPTY POOL COSTS DEPENDS ON WHERE CI_RUNNER POINTS (BH-1323).
        # The gate has run on MonkCI since 2026-09-22, so an empty Fly pool is
        # the FALLBACK fleet being down, not a stopped drain. Saying "the drain
        # stops merging" unconditionally is a page that is false in the state it
        # now renders in most of the time. The page also may not recommend a
        # value bin/ci-runner-known.sh refuses, which the hosted image it used
        # to name now is: the lint job turns the next run red on one.
        text="$text What that costs depends on CI_RUNNER. While CI_RUNNER names the Fly pool, harness CI jobs queue instead of failing, no PR turns red, and the drain stops merging. While it names MonkCI (\"monkci-ubuntu-24.04-4\", current since 2026-09-22), the gate runs elsewhere and this is the fallback fleet being down."
        text="$text Check the Fly app bh-ci-runners-example-org, and flip CI_RUNNER only to a fleet bin/ci-runner-known.sh accepts. The pool may also be cold on purpose: a warm minimum leaves two machines started and their runners registered, which this page does not fire on, but a pool stopped the rest of the way down reaches exactly this state (docs/CI-RUNNERS.md, Warm minimum). To stop paging on a pool that is meant to be cold: bin/harness-ctl.sh set testhost-tick CI_RUNNERS_ALERT_HOLD_MIN 0."
        if _ci_send ci-runners-empty critical "$text"; then
          _th_set ci_runners.empty_since "${CI_SINCE}:fired" \
            || log "the pool alert went out but the worker would not stamp ci_runners.empty_since — the next tick may repeat it (--id dedup catches that)"
          say "bh-ci pool has been EMPTY for ${CI_MIN}m — alerted (ci-runners-empty)"
        else
          log "the ci-runners-empty alert did not send — ci_runners.empty_since stays unstamped so the next tick tries again"
        fi
      else
        log "bh-ci pool: nothing online (rc 1), streak since ${CI_SINCE} (${CI_MIN}m of a ${CI_HOLD_MIN}m hold)"
      fi
      ;;
    2)
      # ci_runners.empty_since is deliberately left ALONE here: a read we could
      # not make is not evidence the pool came back, and closing on it would
      # retract a true alert on a broken token.
      if _ci_hold ci_runners.unreadable_since "$now"; then
        text="bin/ci-runners-status.sh has not been able to read the bh-ci pool for ${CI_MIN}m (rc 2: the Actions endpoint failed or did not parse). While that holds, the \"no runners\" alert cannot fire at all, so a real pool outage would be silent. Check the token's repo administration scope, then run bin/ci-runners-status.sh by hand."
        if _ci_send ci-runners-unreadable warn "$text"; then
          _th_set ci_runners.unreadable_since "${CI_SINCE}:fired" \
            || log "the unreadable alert went out but the worker would not stamp ci_runners.unreadable_since"
          say "the bh-ci pool has been unreadable for ${CI_MIN}m — alerted (ci-runners-unreadable)"
        else
          log "the ci-runners-unreadable alert did not send — the row stays unstamped so the next tick tries again"
        fi
      else
        log "bh-ci pool: unreadable (rc 2), streak since ${CI_SINCE} (${CI_MIN}m of a ${CI_HOLD_MIN}m hold)"
      fi
      ;;
  esac
  return 0
}

# ── every machine's disk (BH-1597) ──────────────────────────────────────────
# ALL FOUR testhosts have a 7.8 GB root overlay, and testhost-2 went from 74% to
# 87% with thirteen runs live before anybody knew: the first signal was a
# builder's gate dying on ENOSPC. The tick already reaches the app over `flyctl
# ssh console`, so every STARTED machine in the app (not only the one the lane
# owns — the gate pins any of them) gets one df a tick: a log line with its root
# and /srv/tmp use and /srv/tmp's filesystem type, and the condition
# testhost-disk-<name> (warn, bin/lane-alert.sh) while its root is ABOVE
# TESTHOST_DISK_ALERT_PCT. A stopped machine is not probed (its disk is not
# filling, and the probe would be a failed ssh every tick). An answer that does
# not parse raises nothing and resolves nothing; it is logged. The resolve is
# sent only for a condition this lane raised (state/testhost-disk/<name>), so a
# healthy fleet costs no alert call at all.
# The probe is plain sh with no nested quotes: flyctl splits -C like a shell and
# Fly's ssh server execs it without one.
TH_DISK_PROBE='/bin/sh -c '"'"'set -- $(df -P / 2>/dev/null | tail -n 1); r=${5:-?}; set -- $(df -P /srv/tmp 2>/dev/null | tail -n 1); s=${5:-?}; f=$(findmnt -n -o FSTYPE /srv/tmp 2>/dev/null); echo TESTHOST_DISK $r $s ${f:-none}'"'"
_th_disk_flag() { printf '%s/state/testhost-disk/%s' "$H" "$1"; }
_th_disk_one() { # _th_disk_one <id> <name>
  local id="$1" name="$2" out root srv fs flag text
  # </dev/null IS LOAD-BEARING (#1604 review, B1): this runs inside cmd_disk's
  # `while read` over the machine list, and flyctl ssh console forwards stdin —
  # without it the first probe swallows the rest of the list and only the first
  # machine is ever probed. tests/testhost-tick.bh-1597-test.sh's stub reads
  # stdin the same way, so dropping this turns that suite red.
  out=$(_th_fly ssh console -a "$APP" --machine "$id" -C "$TH_DISK_PROBE" </dev/null 2>&1)
  read -r root srv fs <<< "$(printf '%s\n' "$out" | awk '/^TESTHOST_DISK /{ print $2, $3, $4; exit }')"
  root="${root%\%}"; srv="${srv%\%}"
  case "$root" in ''|*[!0-9]*)
    log "disk $name ($id): unreadable — the probe did not answer with a df ($(printf '%s' "$out" | tail -n 1 | cut -c1-120))"
    return 0 ;;
  esac
  log "disk $name ($id): root $root% /srv/tmp ${srv:-?}% (${fs:-none})"
  case "$DISK_ALERT_PCT" in ''|*[!0-9]*|0) return 0 ;; esac
  flag=$(_th_disk_flag "$name")
  if [ "$root" -gt "$DISK_ALERT_PCT" ]; then
    text="testhost $name ($id) root disk at $root% (alert above $DISK_ALERT_PCT%, a 7.8 GB overlay); /srv/tmp at ${srv:-?}% on ${fs:-none}. Gate runs on it will hit ENOSPC. bin/remote-gate.sh sweeps litter older than REMOTE_GATE_SWEEP_MIN and mounts /srv/tmp as a tmpfs once nothing is on it (docs/REMOTE-GATE.md); meanwhile pin gates to another machine with TESTHOST_TARGET."
    if _ci_send "testhost-disk-$name" warn "$text"; then
      mkdir -p "$(dirname "$flag")" 2>/dev/null && : > "$flag" 2>/dev/null
      say "disk $name at $root% (above $DISK_ALERT_PCT%) — alerted (testhost-disk-$name)"
    else
      log "the testhost-disk-$name alert did not send — the next tick tries again"
    fi
  elif [ -f "$flag" ]; then
    _ci_send_resolve "testhost-disk-$name" "testhost $name root disk back at $root% (at or under $DISK_ALERT_PCT%)." \
      && rm -f "$flag" && log "testhost-disk-$name resolved"
  fi
  return 0
}
cmd_disk() {
  local list id name state
  list=$(_th_fly machine list -a "$APP" --json 2>/dev/null) \
    || { log "disk: flyctl could not list the machines of $APP — no disk check this tick"; return 0; }
  printf '%s' "$list" | jq -r '.[]? | [.id, (.name // .id), (.state // "")] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r id name state; do
        [ -n "$id" ] || continue
        if [ "$state" != started ]; then log "disk $name ($id): $state — not probed"; continue; fi
        _th_disk_one "$id" "$name"
      done
  return 0
}

# ── the verbs ───────────────────────────────────────────────────────────────
# THE STOP NEEDS BOTH: a row that says nobody has started a run for a while,
# AND the machine itself saying nothing is running. Either one alone has been
# wrong in the field — the row because a Mac cannot write it, the probe because
# "nothing this second" is also what the gap between two suites looks like.
#
# PER MACHINE (BH-9065). The tick reads every machine's state, then decides
# each started machine on its own clock. The order of the witnesses: the clock
# and the window first (no Fly call), then the route row, then
# TESTHOST_MIN_STARTED, then the busy probe (one ssh), then the stop. A stop is
# counted (and logged `stopped after`) only when a state read after it says
# stopped.

# _th_clock <mid> <shared> — set TH_LU to the machine's idle-clock epoch and
# TH_LU_SRC to own|shared. <shared> is the shared row's value ("" = no row).
#   rc 0 TH_LU is set
#   rc 1 the worker did not answer (no action on this machine)
#   rc 2 no row anywhere: the machine's own clock was started now (no action)
#   rc 3 a row that is not an epoch (no action)
TH_LU=""; TH_LU_SRC=""
_th_clock() {
  local mid="$1" shared="$2" key v rc
  TH_LU=""; TH_LU_SRC=""
  key="testhost.last_used.$mid"
  v=$(_th_get "$key"); rc=$?
  if [ "$rc" = 1 ]; then
    say "the worker did not answer for $key — no action on $mid this tick"
    return 1
  fi
  if [ "$rc" = 0 ] && [ -n "$v" ]; then
    case "$v" in *[!0-9]*) say "$key is not an epoch ('$v') — no action on $mid"; return 3 ;; esac
    TH_LU="$v"; TH_LU_SRC=own
    return 0
  fi
  if [ -n "$shared" ]; then
    case "$shared" in *[!0-9]*) say "testhost.last_used is not an epoch ('$shared') — no action on $mid (it has no row of its own)"; return 3 ;; esac
    # THE FALLBACK IS READ ONCE. The shared value goes into the machine's own
    # row, so from the next tick on a fresh shared row (any gate run) cannot
    # keep this machine started. That was the defect.
    _th_set "$key" "$shared" || log "the worker would not take $key — $mid reads the shared row again next tick"
    TH_LU="$shared"; TH_LU_SRC=shared
    return 0
  fi
  # SELF-HEALING, not silence. With no row the old lane did nothing for ever,
  # so the machine it exists to stop was never stopped. Starting the clock here
  # costs one settings write and still stops nothing this tick.
  say "no testhost.last_used row for $mid — starting its clock now, no action on $mid this tick"
  _th_stamp_use "$mid" || say "the worker would not take the first stamp of $mid either — its idle stop stays off"
  return 2
}

# _th_states — read the state of every id in TH_IDS. Sets TH_ST (lines
# `<mid> <state>`), TH_STARTED (count), TH_ANY_UNKNOWN (0|1, TH_UNKNOWN_CAUSE).
TH_ST=""; TH_STARTED=0; TH_ANY_UNKNOWN=0; TH_UNKNOWN_CAUSE=""
_th_states() {
  local mid
  TH_ST=""; TH_STARTED=0; TH_ANY_UNKNOWN=0; TH_UNKNOWN_CAUSE=""
  while IFS= read -r mid; do
    [ -n "$mid" ] || continue
    _th_read_state "$mid"
    _th_size_note "$mid"
    TH_ST="${TH_ST}${mid} ${TH_STATE}"$'\n'
    case "$TH_STATE" in
      started) TH_STARTED=$((TH_STARTED + 1)) ;;
      unknown) [ "$TH_ANY_UNKNOWN" = 1 ] || TH_UNKNOWN_CAUSE="$mid: ${TH_CAUSE:-no cause recorded}"; TH_ANY_UNKNOWN=1 ;;
    esac
  done <<<"$TH_IDS"
}

# _th_record_app_state — the one `testhost.machine_state` row: started when any
# machine is started, else the first known state.
_th_record_app_state() {
  local agg="" mid st
  while read -r mid st; do
    [ -n "$mid" ] || continue
    [ "$st" = started ] && { agg=started; break; }
    [ -z "$agg" ] && [ "$st" != unknown ] && agg="$st"
  done <<<"$TH_ST"
  _th_record_state "${agg:-unknown}" || true
}

cmd_tick() {
  local shared rc now idle brc rrc="" mid st crc
  # FIRST, and on purpose: every branch below this returns early (a worker
  # outage, no row, a machine that is not started, a use inside the idle
  # window), so a pool check placed after them would almost never run.
  cmd_ci_runners
  shared=$(_th_get testhost.last_used); rc=$?
  if [ "$rc" = 1 ]; then
    say "the worker did not answer for testhost.last_used — no machine action this tick"
    return 0
  fi
  [ "$rc" = 0 ] || shared=""
  # Every machine's disk, before any branch below can return (BH-1597). After
  # the worker check on purpose: a tick that cannot reach the worker makes no
  # Fly call at all, which tests/testhost-tick-test.sh section 2 pins.
  cmd_disk
  if ! _th_list_ids; then
    TH_STATE=unknown
    _th_unknown_note
    log "state=unknown — nothing to stop ($TH_CAUSE)"
    return 0
  fi
  _th_states
  _th_record_app_state
  # The unknown streak is one per tick, not one per machine: unknown when the
  # state of any machine could not be read.
  if [ "$TH_ANY_UNKNOWN" = 1 ]; then TH_STATE=unknown; TH_CAUSE="$TH_UNKNOWN_CAUSE"; else TH_STATE="read ($TH_STARTED started)"; fi
  _th_unknown_note
  now=$(date -u '+%s')
  while read -r mid st; do
    [ -n "$mid" ] || continue
    if [ "$st" != started ]; then
      log "$mid state=$st — nothing to stop"
      continue
    fi
    _th_clock "$mid" "$shared"; crc=$?
    [ "$crc" = 0 ] || continue
    idle=$(( now - TH_LU ))
    if [ "$idle" -lt "$(( IDLE_MIN * 60 ))" ]; then
      log "$mid in use ${idle}s ago (window ${IDLE_MIN}m, $TH_LU_SRC row) — left started"
      continue
    fi
    # A shipped pool route holds the stop until it expires (BH-8659). One read
    # per tick: the row is the app's, not a machine's.
    if [ -z "$rrc" ]; then _th_route_live; rrc=$?; fi
    if [ "$rrc" = 0 ]; then
      log "a pool test-host route is live until $(date -u -d "@$TH_ROUTE_UNTIL" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || printf '%s' "$TH_ROUTE_UNTIL") — $mid left started"
      continue
    fi
    if [ "$rrc" = 2 ]; then
      say "could not read testhost.route_until — NOT stopping $mid; a route we cannot see is treated as live"
      continue
    fi
    if [ "$TH_STARTED" -le "$MIN_STARTED" ]; then
      log "$mid idle ${idle}s but only $TH_STARTED machine(s) started and TESTHOST_MIN_STARTED=$MIN_STARTED — left started"
      continue
    fi
    # The row says idle. Ask the machine before believing it.
    _th_busy "$mid"; brc=$?
    if [ "$brc" = 0 ]; then
      # Real work, and nobody recorded it — so record it, on THIS machine's
      # clock. This is what keeps a Mac drain (which cannot write the row) from
      # being stopped a window into itself.
      say "the row said $mid idle ${idle}s but the host is BUSY ($BUSY_N live run(s)/process(es)) — not stopping, and refreshing testhost.last_used.$mid"
      _th_stamp_use "$mid" || true
      continue
    fi
    if [ "$brc" = 2 ]; then
      say "could not ask $APP machine $mid what is running (ssh probe failed) — NOT stopping; a host we cannot see is treated as busy"
      continue
    fi
    say "$mid idle ${idle}s (window ${IDLE_MIN}m) and the host reports no live runs — stopping it ($APP)"
    if _th_fly machine stop "$mid" -a "$APP" </dev/null >/dev/null 2>&1; then
      _th_read_state "$mid"
      if [ "$TH_STATE" = stopped ]; then
        TH_STARTED=$(( TH_STARTED - 1 ))
        TH_ST=$(printf '%s\n' "$TH_ST" | sed "s/^$mid started\$/$mid stopped/")
        log "stopped after ${idle}s idle: $mid (state now $TH_STATE)"
      else
        say "flyctl accepted the stop of $mid but its state reads $TH_STATE — not counted as stopped; the next tick tries again"
      fi
    else
      say "flyctl could not stop $mid — it is still running and will be tried again next tick"
      log "stop FAILED for $mid after ${idle}s idle"
    fi
  done <<<"$TH_ST"
  _th_record_app_state
  return 0
}

# cmd_ensure [--route-until <epoch>] — with the flag (the hub's pool route
# ship, BH-8659) the hold is written FIRST, so a tick that runs between the
# start and the ship already sees it, and the verb ends with one line
# `ensure-result: was-started|started-now|unknown|start-failed` that
# bin/lib/pool-testhost-route.sh reads. Without the flag the output is as it
# was (bin/remote-gate.sh's caller reads it).
#
# WHICH MACHINE (BH-9065). A started machine, if there is one: the
# `testhost.machine_id` row's machine first, else the first started one in list
# order. That machine's own clock is stamped. With none started, ONE stopped
# machine is started (the pinned one first, else the first in list order) and
# stamped. The shared row is stamped too: it is the fallback clock of a machine
# that has no row yet.
cmd_ensure() {
  local route="" res rc=0 pref pick="" cand="" mid st
  if [ "${1:-}" = --route-until ]; then route=1; _th_hold_route "${2:-}"; fi
  _th_stamp_use || say "the worker did not answer — this run is not recorded in testhost.last_used"
  pref=$(_th_get testhost.machine_id) || pref=""
  case "$pref" in *[!a-z0-9]*) pref="" ;; esac
  if _th_list_ids; then
    _th_states
  elif [ -n "$pref" ]; then
    TH_IDS="$pref"; _th_states
  else
    TH_ST=""
  fi
  while read -r mid st; do
    [ -n "$mid" ] || continue
    case "$st" in
      started) { [ -z "$pick" ] || [ "$mid" = "$pref" ]; } && pick="$mid" ;;
      unknown|purged|destroyed|destroying) ;;
      *) { [ -z "$cand" ] || [ "$mid" = "$pref" ]; } && cand="$mid" ;;
    esac
  done <<<"$TH_ST"
  if [ -n "$pick" ]; then
    _th_record_state started || true
    _th_stamp_use "$pick" || log "the worker did not take testhost.last_used.$pick"
    res=was-started
  elif [ -z "$cand" ]; then
    say "Fly did not answer with a machine state for $APP — not starting anything blind"
    res=unknown
  else
    st=$(printf '%s\n' "$TH_ST" | awk -v m="$cand" '$1 == m {print $2; exit}')
    # The stdout words are the contract bin/remote-gate.sh relays (BH-8659 E5);
    # the machine id goes to the log only.
    say "starting $APP (state was $st)"; log "starting machine $cand"
    if _th_fly machine start "$cand" -a "$APP" </dev/null >/dev/null 2>&1; then
      _th_stamp_use "$cand" || log "the worker did not take testhost.last_used.$cand"
      _th_read_state "$cand"
      _th_record_state "$TH_STATE" || true
      log "started $cand on demand (state now $TH_STATE)"
      res=started-now
    else
      say "flyctl could not start the machine — the run that asked for it will fail to connect"
      log "start FAILED for $cand"
      res=start-failed; rc=1
    fi
  fi
  [ -n "$route" ] && printf 'ensure-result: %s\n' "$res"
  return "$rc"
}

# cmd_idle [<machine-id>] — READ-ONLY, for bin/fly-idle-reaper.sh: it stamps
# nothing and stops nothing. Prints the idle seconds (now minus the machine's
# own testhost.last_used.<id> row; the shared row when it has none, BH-9065),
# 0 when the machine says it is busy, or `unknown` with rc 2 when either witness
# cannot answer. It needs the same witnesses as the stop, so the reaper and
# this tick can never disagree about whether the host is in use. A live pool
# route (testhost.route_until in the future, BH-8659) is busy: 0. With
# TESTHOST_MIN_STARTED > 0, a started machine at or under that count is busy
# (0) too, so the reaper never stops what the tick keeps.
cmd_idle() {
  local mid="${1:-}" lu now idle brc rc m st
  case "$mid" in *[!a-z0-9]*) echo unknown; return 2 ;; esac
  rc=2
  if [ -n "$mid" ]; then
    lu=$(_th_get "testhost.last_used.$mid"); rc=$?
    [ "$rc" = 1 ] && { echo unknown; return 2; }
  fi
  if [ "$rc" != 0 ] || [ -z "$lu" ]; then
    lu=$(_th_get testhost.last_used) || { echo unknown; return 2; }
  fi
  case "$lu" in ''|*[!0-9]*) echo unknown; return 2 ;; esac
  _th_route_live
  case "$?" in
    0) echo 0; return 0 ;;
    2) echo unknown; return 2 ;;
  esac
  if [ "$MIN_STARTED" -gt 0 ] && [ -n "$mid" ]; then
    _th_list_ids || { echo unknown; return 2; }
    _th_states
    st=""
    while read -r m st; do [ "$m" = "$mid" ] && break; st=""; done <<<"$TH_ST"
    [ "$TH_ANY_UNKNOWN" = 1 ] && { echo unknown; return 2; }
    if [ "$st" = started ] && [ "$TH_STARTED" -le "$MIN_STARTED" ]; then echo 0; return 0; fi
  fi
  _th_busy "$mid"; brc=$?
  case "$brc" in
    0) echo 0 ;;
    1) now=$(date -u '+%s'); idle=$(( now - lu )); [ "$idle" -lt 0 ] && idle=0; echo "$idle" ;;
    *) echo unknown; return 2 ;;
  esac
  return 0
}

RC=0
case "$VERB" in
  tick|"")  cmd_tick; RC=$? ;;
  # THE RC IS THE VERB'S. `ensure` returns 1 when the start failed, and the old
  # `exit 0` below threw that away — the file said one thing and did another.
  ensure)   cmd_ensure "${2:-}" "${3:-}"; RC=$? ;;
  used)     _th_stamp_use || { say "the worker did not answer — use not recorded"; RC=0; } ;;
  state)    case "${2:-}" in *[!a-z0-9]*) echo unknown; RC=2 ;; *) _th_read_state "${2:-}"; printf '%s\n' "$TH_STATE" ;; esac ;;
  # A READ, and the one an operator actually wants before touching the host:
  # "is anybody on it right now?". It is also how the probe that decides the
  # stop gets exercised against the live machine without stopping anything.
  busy)     _th_busy; BRC=$?
            case "$BRC" in
              0) printf 'busy %s\n' "$BUSY_N" ;;
              2) printf 'unknown\n' ;;
              *) printf 'idle\n' ;;
            esac ;;
  idle)     cmd_idle "${2:-}"; RC=$? ;;
  -h|--help|help)
    echo "usage: testhost-tick.sh [tick|ensure [--route-until <epoch>]|used|state [<machine-id>]|busy|idle [<machine-id>]]"
    echo "  tick    check the bh-ci runner pool (alert after CI_RUNNERS_ALERT_HOLD_MIN minutes"
    echo "          empty or unreadable), log every started machine's disk (alert above"
    echo "          TESTHOST_DISK_ALERT_PCT), then stop each test host once it has been idle"
    echo "          TESTHOST_IDLE_STOP_MIN minutes on its own clock (never below TESTHOST_MIN_STARTED)"
    echo "  ensure  stamp the use and start the host if it is stopped (bin/remote-gate.sh calls this)"
    echo "          --route-until <epoch>: first hold the idle stop until <epoch> (a pool route"
    echo "          ship), then end with one 'ensure-result: <word>' line"
    echo "  used    stamp the use and nothing else"
    echo "  state   print the machine's Fly state, change nothing"
    echo "  busy    ask the host what is running (run roots + live suites), change nothing"
    echo "  idle    print the host's idle seconds (0 = busy), or 'unknown' with rc 2; change nothing" ;;
  *) echo "testhost-tick: unknown verb '$VERB' (tick|ensure|used|state|busy|idle)" >&2; exit 2 ;;
esac
exit "$RC"
