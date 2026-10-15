#!/bin/bash
# bin/fly-dispatch.sh [--drain <project>] — the Fly builder trial dispatcher.
# Runs on the HUB only, cron */2, flock-guarded. One machine per project, one
# job at a time — $FLY_DISPATCH_WIP from bin/lib/build-caps.sh, which is the one
# place that number lives now (2026-09-12).
#
# THAT CEILING IS A MACHINE, NOT A LOCK (2026-09-13, the no-serialize pass). This
# route owns ONE persistent builder per project and the runner takes its work from
# a single /run/harness/job.json, so a second job pushed in the same tick would
# overwrite the one being built. It is a resource cap, it is stated as a value
# ($FLY_DISPATCH_WIP) rather than implied by the code shape, and nothing here
# WAITS: a project already building is left alone and re-offered next tick. The
# parallel route is the pool (flags/fly-pool-<p> — bin/fly-pool.sh spawns one
# machine per job, up to bin/pool-cap.sh), and this dispatcher stands down
# entirely for a pool project. What DID serialize here was the per-project loops:
# every project's ssh drain and dispatch ran behind the previous project's. Both
# loops now run their projects concurrently. It used to be a comment here and a
# shape in the code below, which meant nothing could REPORT this route's ceiling
# and nothing would notice if the shape changed; bin/concurrency-plan.sh reads
# the same value, so the table and the dispatcher cannot come to disagree.
# Self-gating: only projects with a state/fly/<p>.json are considered, and
# flags/fly-disabled is a global kill switch.
#
# Per tick, for each provisioned+flagged project:
#   1. active job + RESULT present   -> hand to fly-results-ingest.sh
#   2. active job + machine stopped/heartbeat stale >10m + no RESULT
#                                    -> builder died: requeue attempt+1 (>=2 fail)
#   3. no active job + queue non-empty
#        - machine stopped -> start it (fly-api start), wait reachable
#        - machine started -> claim oldest job, build+push env bundle + job
#   4. no active job + empty queue + machine started >15m -> stop it (belt+braces)
#
# TRANSPORT (task brief, HARD-WON — OVERRIDES the plan's "tailnet ssh push"):
#   Push is Fly's ssh/sftp (`flyctl ssh sftp` + `flyctl ssh console -C`), NOT
#   tailnet ssh (Tailscale-SSH stalls in userspace mode). `fly sftp put` REFUSES
#   to overwrite AND swallows errors: ALWAYS put to a fresh temp path, then `mv`
#   into place via `flyctl ssh console -C`, and verify the outcome explicitly.
#   Connectivity over tailnet is used only for reachability CHECKS.
#
#   The env bundle is pulled from the project's OWNING watcher box at dispatch
#   time (fly-envbundle.sh, hub->box tailnet ssh), assembled in a mktemp dir, and
#   shredded immediately after the push — the hub never persists other projects'
#   secrets on disk.
set -uo pipefail

# Overridable so the queue-source loop below can be DRIVEN against a scratch
# tree (the same change run-build.sh, review-prs.sh and merge-sweep.sh took).
# Cron sets it nowhere, so production resolves to exactly the path it always has.
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
# shellcheck source=bin/lib/flag-on.sh
. "$HARNESS/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null || flag_on() { [ -f "$HARNESS/flags/$1-$2" ]; }

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-fly-dispatch
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off fly-dispatch.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fly-dispatch
# BH-2435: fly-disabled is a settings row before it is a file (lane-switch.sh).
. "${HARNESS:-/root/harness}/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "${HARNESS:-/root/harness}/flags/$1" ]; }
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fly-dispatch
export PATH="/root/.fly/bin:$PATH"   # flyctl lives here; cron PATH lacks it
FLYENV="$HENV/fly.env"
STATE_DIR="$HARNESS/state/fly"
QUEUE_ROOT="$HARNESS/state/build-queue"
BIN="$HARNESS/bin"

# The per-project WIP this route enforces, from the one file that states it.
# Fail-open to 1 — the value this dispatcher has always had — because an
# unreadable lib must not change how many jobs a hub will claim.
# shellcheck source=bin/lib/build-caps.sh
[ -r "$BIN/lib/build-caps.sh" ] && . "$BIN/lib/build-caps.sh" 2>/dev/null
FLY_DISPATCH_WIP="${FLY_DISPATCH_WIP:-1}"

# The hotfix lane's kill flag reaches the job pick below through the same lib
# every other caller reads (#368 F4), so HOTFIX_LANE=0 / flags/hotfix-lane-off
# really does put this dispatcher back to the alphabetical pick it had before
# the lane existed. FAIL-OPEN: a half-synced box with no lib leaves the lane on,
# which is only ever the behaviour a job file already asked for — this script
# never decides that a ticket is urgent, it only honours a flag already on it.
# shellcheck source=bin/lib/hotfix-lib.sh
[ -r "$BIN/lib/hotfix-lib.sh" ] && . "$BIN/lib/hotfix-lib.sh" 2>/dev/null
# BH-6350: the dispatch mode (normal | hotfix-only | paused), read per project in
# the next job pick. Absent, every project reads normal.
# shellcheck source=bin/lib/dispatch-mode.sh
[ -r "$BIN/lib/dispatch-mode.sh" ] && . "$BIN/lib/dispatch-mode.sh" 2>/dev/null
# One owner per ticket (BH-1526): the claim below asks the ticket's HOLD first.
# shellcheck source=bin/lib/ticket-ownership.sh
[ -r "$BIN/lib/ticket-ownership.sh" ] && . "$BIN/lib/ticket-ownership.sh" 2>/dev/null

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log()   { echo "$(STAMP) [fly-dispatch${1:+/$1}] ${2:-$1}"; }
DLOG="$HARNESS/logs/fly-dispatch.log"
say()   { echo "$(STAMP) [fly-dispatch/${1:-}] ${2:-}" | tee -a "$DLOG" >&2; }

command -v jq  >/dev/null 2>&1 || { echo "jq required"  >&2; exit 1; }
[ -f "$FLYENV" ] || { echo "$FLYENV missing — not the hub; dispatcher is hub-only" >&2; exit 0; }
FLY=$(command -v fly || command -v flyctl || true)

# global kill switch (mirrors automerge-disabled convention)
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && [ -d "$HARNESS/bin/lib/jobs" ] && . "$HARNESS/bin/jobs-client.sh"
# The row first, then flag_active (loaded just above) or the file.
if lane_switch fly-disabled; then
  say "" "$(lane_switch_src fly-disabled 2>/dev/null || echo flags/fly-disabled) present — no-op"; exit 0
fi

# serialize dispatcher ticks
# Same hazard as fly-pool.sh: the flyctl agent must exist before fd 9 is open,
# or a `machine exec` inside the lock spawns it as a daemon that keeps the lock.
[ -n "$FLY" ] && "$FLY" agent start >/dev/null 2>&1 || true
"$HARNESS/bin/fly-lock-guard.sh" >/dev/null 2>&1 || true
exec 9>"$HARNESS/locks/fly-dispatch.lock"
flock -n 9 || { say "" "another tick holds the lock — skip"; exit 0; }
# WHERE THE QUEUE COMES FROM (2026-09-10, docs/DB-COORDINATION-SPEC.md).
#
# This loop is the reason the hub needs ssh into every box. A watcher decides a
# ticket is buildable and writes state/build-queue/<project>/<KEY>.json on
# ITSELF; the hub then ssh's in, `ls`'s the directory, `scp`'s each file back
# and `ssh rm`'s the original — every two minutes, per project, forever. A queue
# that lives on a box can only be read by reaching into the box.
#
# `build_queue` rows carry the same entries with no hop. What is materialised
# here is the SAME FILE the ssh pull produced, so everything downstream — this
# dispatcher, bin/fly-pool.sh, bin/healthcheck.sh — is untouched: only the
# SOURCE of the file changes.
#
# THE CLAIM IS THE HAND-OFF, and it has to be. A row left `queued` while the
# pool builds it would be materialised again on the next tick, and the pool
# would spawn a SECOND machine for a key it is already running. So the row is
# compare-and-swapped to `claimed` FIRST and the file is written only if that
# won; bin/fly-pool.sh closes it when the build ends.
#
# FAIL-OPEN AND FALL-THROUGH: an outage, an old client, or a project with no
# rows yet (which is what the transition looks like) all drop to the ssh pull
# below, unchanged. The ssh hop disappears for a project the moment its
# producers are writing rows — not before.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# The row -> job.json mapping, shared with bin/fly-pool.sh (BH-1026.3). Resolved
# off $HARNESS first and off this script's own directory second: the scratch
# trees in tests/fly-lane-db-test.sh run the CHECKOUT's script against a $HARNESS
# that may carry no lib at all.
# shellcheck source=bin/lib/queue-row-job.sh
. "$HARNESS/bin/lib/queue-row-job.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/queue-row-job.sh" 2>/dev/null \
  || say "" "bin/lib/queue-row-job.sh is missing — no queue file can be materialised from a row this tick"
# A push-rejected pool terminal is never claimed (BH-6821). Absent lib = no guard.
# shellcheck source=bin/lib/pool-claim-guard.sh
. "$HARNESS/bin/lib/pool-claim-guard.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-claim-guard.sh" 2>/dev/null || true
# THE REGISTRY ANSWERS THIS (2026-09-11). This was one of nine copies of the
# same table across bin/ — a box that moved had to be found in all nine, and
# until fleet.conf grew a `tailnet_ip` column it genuinely could not answer.
# Unknown prints nothing and returns 1: callers fail closed rather than ssh
# to `root@`, which hangs instead of erroring.
owner_ip() {
  "$HARNESS/bin/fleet-conf.sh" --tailnet-ip "$1" 2>/dev/null
}
# rows_custody_sweep <project> — THE LEDGER OUTRANKS THE LEFTOVER FILE, hub-
# locally (BH-1026.3). With the rows path taking the ssh drain out of the tick,
# nothing else would ever remove a state/build-queue/<p>/<KEY>.json this hub
# itself materialised on an earlier (flag-off) tick — and bin/fly-pool.sh would
# launch from it a second time.
#
# THE CUSTODY TEST IS THE DRAIN'S, and it is a CLOSED LIST: claimed/done/failed
# mean this hub already took custody of the work, while `queued`, `ready`,
# `dropped` and "no row at all" (rc 2) all mean nothing in the DB owns a launch
# for this key — so the file is left exactly where it is. BH-1033 is why that is
# not "anything that is not queued": `ready` is bin/run-build.sh's outage
# fallback, written under an alert that says verbatim "The build is NOT lost",
# and deleting one loses a build whose only record says it is safe.
#
# It is a FUNCTION rather than a block inside the loop on purpose: the drain's
# own copy of this test is lifted by tests/ready-queue-rows-test.sh on the shape
# `^    if command -v queue_status `, and a second block wearing that shape four
# spaces deep earlier in the file is lifted instead of the drain's.
rows_custody_sweep() {
  local p="$1" f k st rc
  command -v queue_status >/dev/null 2>&1 || return 0
  for f in "$QUEUE_ROOT/$p"/*.json; do
    [ -f "$f" ] || continue
    case "$f" in *.failed.json) continue;; esac
    k=$(basename "$f" .json)
    st=$(queue_status "$p" "$k" 2>/dev/null); rc=$?
    [ "$rc" -eq 0 ] || continue
    case "$st" in
      queued|ready|dropped) : ;;
      *) rm -f "$f"
         say "$p" "dropped $(basename "$f") — the coordination DB says $k is $st, not queued" ;;
    esac
  done
}
# ONE PROJECT'S QUEUE NEVER WAITS FOR ANOTHER'S (the operator, 2026-09-13: "we never lock
# and serialize"). Each project's materialise+drain is an ssh round trip per queue
# file into a different box; run in sequence, a slow or unreachable box delayed
# every project behind it in the same tick, which is the tick's own deadline spent
# on someone else's network. They are independent — different rows, different
# directories, different boxes — so they run concurrently and the loop waits for
# all of them before the dispatch half begins.
command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }
for FLAG in "$HARNESS"/flags/builder-fly-*; do
  [ -e "$FLAG" ] || continue
  P=$(basename "$FLAG" | sed 's/^builder-fly-//')
  ( # per-project subshell: `continue` would have no loop here, so the one
    # early-out below is an `exit 0` out of the subshell instead.
  mkdir -p "$HARNESS/state/build-queue/$P"
  # >>> rows-only (BH-1026.3)
  # WITH THE FLAG ON THE ROW IS THE ONLY SOURCE. Everything below this block —
  # the materialise that writes state/build-queue/<p>/<KEY>.json, and the ssh
  # drain that lists, scps and rm's the owning box's copy — exists because the
  # queue used to live in a directory on the box that decided it. A `build_queue`
  # row carries the same entry with no hop, so under the flag this tick reads the
  # rows, writes NO queue file, takes NO ssh hop, and `exit 0`s out of the
  # per-project subshell before either of them. The two blocks below are left at
  # their own indentation deliberately: they are the flag-off path, unchanged.
  #
  # AN OUTAGE IS NOT AN EMPTY QUEUE (D9/D11). Only rc 1 — the list did not answer
  # — falls through to the flag-off path; rc 0 with no rows is a REAL answer and
  # the rows path runs on it (the custody sweep still has work to do). The flag
  # itself already refuses to read ON from an unreadable settings row, so
  # `CURL_MODE=down` resolves OFF and behaves exactly as flag-off.
  ROWS_ONLY=0; RLIST=""
  if command -v build_queue_rows_only_on >/dev/null 2>&1 && build_queue_rows_only_on \
     && command -v queue_list >/dev/null 2>&1; then
    RLIST=$(queue_list "$P" queued fly 2>/dev/null)
    [ "$?" -ne 1 ] && ROWS_ONLY=1
  fi
  if [ "$ROWS_ONLY" = 1 ]; then
    # (a) Per queued row: the two guards the materialise carried, and nothing
    # else. No claim — bin/fly-pool.sh and dispatch_project claim at the point
    # they are about to spend a machine, which is what makes "a refused claim
    # spawns nothing" true.
    while IFS="$(printf '\t')" read -r _RP RK RTID _RST _RTG RATT _RCB _REN _RRSN RMETA; do
      [ -n "${RK:-}" ] || continue
      # Already live on a pool machine: the same guard the ssh pull learned the
      # hard way (2026-08-13, TK-70 re-queued mid-build).
      grep -ls "\"key\": *\"$RK\"" "$HARNESS/state/fly-pool/$P/"*.json >/dev/null 2>&1 && continue
      # The rebase-meta refusal, asked with no file written: a row whose rebase
      # object is unusable is closed FAILED here rather than dispatched as an
      # ordinary build of ticket $RTID.
      if command -v queue_row_job_file >/dev/null 2>&1; then
        RSAY=$(queue_row_job_file "$P" - "$RK" "$RTID" "$RATT" "$RMETA"); RRC=$?
        [ "$RRC" = 3 ] && say "$P" "$RSAY"
      fi
    done <<ROWFEED
$RLIST
ROWFEED
    # (b) The hub-local half of "the ledger outranks the leftover file" — see
    # rows_custody_sweep above the loop.
    rows_custody_sweep "$P"
    exit 0
  fi
  # <<< rows-only
  ROWS=""
  command -v queue_list >/dev/null 2>&1 && ROWS=$(queue_list "$P" queued fly 2>/dev/null)
  if [ -n "$ROWS" ]; then
    while IFS="$(printf '\t')" read -r _RP RK RTID _RST _RTG RATT _RCB _REN _RRSN RMETA; do
      [ -n "${RK:-}" ] || continue
      [ -f "$HARNESS/state/build-queue/$P/$RK.json" ] && continue
      # Already live on a pool machine: the same guard the ssh pull learned the
      # hard way (2026-08-13, TK-70 re-queued mid-build).
      grep -ls "\"key\": *\"$RK\"" "$HARNESS/state/fly-pool/$P/"*.json >/dev/null 2>&1 && continue
      # THE CLAIM IS THE HAND-OFF: a row left `queued` while the pool builds it
      # would be materialised again next tick and get a SECOND machine. The file
      # is written only if the compare-and-swap won.
      command -v queue_row_job_file >/dev/null 2>&1 || continue
      # A PUSH-REJECTED TERMINAL IS NOT CLAIMED (BH-6821). fly-pool's terminal
      # gate re-arms it on a moved head or a RETRY, or closes the row failed. On
      # a pool project it gets the hub file it reads, with no claim taken.
      RWHY=""
      command -v pool_claim_guard >/dev/null 2>&1 && { RWHY=$(pool_claim_guard "$P" "$RK") || true; }
      if [ -n "$RWHY" ]; then
        say "$P" "refused claim of $RK: $RWHY — fly-pool's terminal gate owns its re-arm"
        # Only when absent (the loop head already skips a present file; this
        # keeps the write one-shot if that check moves). rc 3 is a refused meta
        # (row closed FAILED): say it, never swallow it.
        if flag_on fly-pool "$P" && [ ! -f "$HARNESS/state/build-queue/$P/$RK.json" ]; then
          RRC=0; RSAY=$(queue_row_job_file "$P" "$HARNESS/state/build-queue/$P/$RK.json" \
                          "$RK" "$RTID" "$RATT" "$RMETA" 2>/dev/null) || RRC=$?
          [ "$RRC" = 0 ] || say "$P" "hub job file for $RK not written (rc $RRC)${RSAY:+: $RSAY}"
        fi
        continue
      fi
      RCRC=0; queue_claim "$P" fly "$RK" >/dev/null 2>&1 || RCRC=$?
      if [ "$RCRC" != 0 ]; then
        say "$P" "claim of $RK refused (rc $RCRC): row is $(queue_status "$P" "$RK" 2>/dev/null || echo unreadable)"
        continue
      fi
      # The field extraction, the rebase normalisation and the charset refusal
      # all live in bin/lib/queue-row-job.sh now (BH-1026.3) — this path and the
      # pool's read one copy of them. rc 3 is the refusal (row closed FAILED, one
      # ALERTS line, no file); rc 1 is a jq/mv that failed, and the claim this
      # loop won has to be handed back.
      RSAY=$(queue_row_job_file "$P" "$HARNESS/state/build-queue/$P/$RK.json" \
                                "$RK" "$RTID" "$RATT" "$RMETA"); RRC=$?
      case "$RRC" in
        0) say "$P" "queued job $RK taken from the coordination DB (no ssh hop)" ;;
        3) say "$P" "$RSAY" ;;
        *) # The claim landed but the file did not: hand the row back rather than
           # leave a build claimed by a hub that never wrote it down.
           queue_release "$P" "$RK" "hub could not materialise the queue file" >/dev/null 2>&1 || true ;;
      esac
    done <<ROWFEED
$ROWS
ROWFEED
  fi
  # THE DRAIN RUNS EVERY TICK, rows or no rows — this used to `continue` past it
  # whenever anything was queued in the DB, and that was a double-build bug.
  # bin/run-build.sh on a watcher still writes state/build-queue/<p>/<KEY>.json,
  # and this drain is the ONLY thing that removes it. Skipping the drain on a
  # busy project let those files pile up; the first quiet tick then pulled them
  # all at once, by which time their builds had been reaped — so neither the
  # hub-file test nor the live-in-pool guard below matched, and the pool spawned
  # a SECOND machine per key. That is the TK-70 shape (2026-08-13) arriving by a
  # new road. The hub->box hop CANNOT go away until the producer stops writing
  # the box file; until then this drain is load-bearing every single tick.
  IP=$(owner_ip "$P" || true)
  [ -n "$IP" ] && [ "$IP" != local ] || exit 0
  for RF in $(timeout 20 ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@$IP" "ls /root/harness/state/build-queue/$P/ 2>/dev/null" || true); do
    [ -n "$RF" ] || continue
    [ -f "$HARNESS/state/build-queue/$P/$RF" ] && { timeout 20 ssh -n -o BatchMode=yes "root@$IP" "rm -f /root/harness/state/build-queue/$P/$RF"; continue; }
    # Drop a fetched job whose key is already building on a pool machine —
    # this path bypassed run-build's dedup and re-queued TK-70 mid-build
    # (2026-08-13); the leftover dup would spawn a second build post-reap.
    K="${RF%.json}"; K="${K%.failed}"
    if grep -ls "\"key\": *\"$K\"" "$HARNESS/state/fly-pool/$P/"*.json >/dev/null 2>&1; then
      timeout 20 ssh -n -o BatchMode=yes "root@$IP" "rm -f /root/harness/state/build-queue/$P/$RF"
      say "$P" "dropped $RF from $IP — $K already live in pool"
      continue
    fi
    # >>> the ledger outranks the leftover file
    # THE LEDGER OUTRANKS THE LEFTOVER FILE. A box file whose row is claimed,
    # done or failed is a producer's write that this hub has already taken
    # custody of — pulling it would re-queue work that is running or finished.
    # Only "no row at all" (rc 2) and an outage (rc 1) fall through to the pull,
    # and both mean the same thing to this loop: nothing in the DB claims to own
    # this file, so it is real work and today's behaviour is correct.
    #
    # ...AND CUSTODY IS A CLOSED LIST, NOT "anything that is not queued"
    # (BH-1033 fix round 2). `ready` and `dropped` joined the status vocabulary
    # with this slice and NEITHER is custody: `ready` is "triage says buildable,
    # nobody has launched it" and `dropped` is "a queue line was consumed". The
    # box file this loop is looking at is written in exactly one place —
    # bin/run-build.sh's outage fallback, when queue_put failed — under an alert
    # that says verbatim "The build is NOT lost". With `ready` treated as
    # custody, the common sequence (stale-owed writes a ready row, a watcher
    # launches the key, the row write fails in a D1 outage, the file is written,
    # the worker comes back) ends with this drain deleting that file: a build
    # lost, with the only record saying it was safe. So the three
    # nobody-owns-a-launch words fall through to the pull, exactly as rc 2 does.
    if command -v queue_status >/dev/null 2>&1; then
      KST=$(queue_status "$P" "$K" 2>/dev/null); KRC=$?
      if [ "$KRC" -eq 0 ]; then
        case "$KST" in
          queued|ready|dropped) : ;;
          *)
            timeout 20 ssh -n -o BatchMode=yes "root@$IP" "rm -f /root/harness/state/build-queue/$P/$RF"
            say "$P" "dropped $RF from $IP — the coordination DB says $K is $KST, not queued"
            continue
            ;;
        esac
      fi
    fi
    # <<< the ledger outranks the leftover file
    # Pull to a dot-prefixed temp then mv into place: fly-pool runs on the same
    # */2 cron and its *.json glob must never see a mid-transfer file — it read
    # TK-730.json as empty and quarantined a valid job (2026-08-17).
    TMP="$HARNESS/state/build-queue/$P/.$RF.pull"
    if timeout 20 scp -q "root@$IP:/root/harness/state/build-queue/$P/$RF" "$TMP" 2>/dev/null; then
      mv "$TMP" "$HARNESS/state/build-queue/$P/$RF"
      timeout 20 ssh -n -o BatchMode=yes "root@$IP" "rm -f /root/harness/state/build-queue/$P/$RF"
      say "$P" "pulled queued job $RF from $IP"
    else
      rm -f "$TMP"
    fi
  done
  ) &
done
wait


set -a; . "$FLYENV"; set +a

# --- helpers ------------------------------------------------------------------
tok_var() { echo "FLY_API_TOKEN_$(echo "$1" | tr '[:lower:].-' '[:upper:]__')"; }

app_for() { jq -r '.app // ""' "$STATE_DIR/$1.json" 2>/dev/null; }

# beat once per (kind,project,key) per tick — deduped by the console's akey.
beat() { "$BIN/beat.sh" "$1" >/dev/null 2>&1 || true; }

fleet_alert() { # fleet_alert <project> <akey-suffix> <line>
  "$HARNESS/bin/alert-line.sh" "[$1] $3"
  beat "$(jq -nc --arg p "$1" --arg akey "flydispatch:$2:$(date -u +%Y%m%d%H)" --arg l "$3" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')"
}

# flyctl ssh/sftp use the per-app deploy token as FLY_ACCESS_TOKEN.
fly_env() { # fly_env <project>  -> exports FLY_ACCESS_TOKEN + APP for flyctl ssh
  local p="$1" tv; tv=$(tok_var "$p")
  APP=$(app_for "$p")
  FLY_ACCESS_TOKEN="${!tv:-}"
  [ -n "$APP" ] && [ -n "$FLY_ACCESS_TOKEN" ] || return 1
  export FLY_ACCESS_TOKEN
}

# console -C wrapper: run a command on the builder, return its output/exit.
bssh() { # bssh <project> <remote-command>
  "$FLY" ssh console -a "$APP" -C "/bin/sh -c $(printf '%q' "$2")" 2>>"$DLOG"
}

# staged put: sftp to a fresh temp path, then mv into place via console; verify.
# push_file <project> <localpath> <destpath>
push_file() {
  local p="$1" local_f="$2" dest="$3" tmp
  tmp="/run/harness/.stage.$$.$RANDOM.$(basename "$dest")"
  # fly sftp put reads the local path and writes the remote path; give it a
  # fresh temp name it will not refuse. Then mv over the (maybe-existing) dest.
  if ! "$FLY" ssh sftp put -a "$APP" "$local_f" "$tmp" >>"$DLOG" 2>&1; then
    say "$p" "sftp put FAILED for $dest (tmp=$tmp)"; return 1
  fi
  # explicit outcome check: temp must exist and be non-empty, then atomic mv.
  local sz
  sz=$(bssh "$p" "mkdir -p $(dirname "$dest"); [ -s '$tmp' ] && wc -c < '$tmp' || echo 0" | tr -dc '0-9')
  if [ -z "$sz" ] || [ "$sz" = "0" ]; then
    say "$p" "staged temp missing/empty after put ($tmp -> $dest)"; bssh "$p" "rm -f '$tmp'" >/dev/null 2>&1 || true; return 1
  fi
  if ! bssh "$p" "mv -f '$tmp' '$dest'" >/dev/null 2>&1; then
    say "$p" "mv $tmp -> $dest FAILED"; return 1
  fi
  return 0
}

# is the builder reachable over tailnet (connectivity CHECK only, not transport).
reachable() { # reachable <project>
  # Resolve the builder's tailnet IP from `tailscale status` — the hub does not
  # resolve MagicDNS names (2026-07-31 e2e finding), so ping by IP.
  local ip
  ip=$(tailscale status 2>/dev/null | awk -v h="builder-$1" '$2 == h {print $1; exit}')
  [ -n "$ip" ] || return 1
  timeout 20 tailscale ping -c 1 --timeout 5s "$ip" >/dev/null 2>&1
}

# unclaim_job <project> <key> <active-file> <qdir> <rows-only>
# THE TWO WAYS A WON CLAIM IS HANDED BACK — an env bundle that would not build
# and a push that did not land. With the flag off the job file goes back to the
# queue directory, exactly as it always has. With it on there is no queue
# directory to go back to: the row is RELEASED (back to `queued`, claimant and
# machine cleared by the worker) and the write-through cache is removed, or the
# next tick reads a cache for a build nothing is running.
unclaim_job() {
  local p="$1" key="$2" active="$3" qdir="$4" rows_only="${5:-0}"
  if [ "$rows_only" = 1 ]; then
    rm -f "$active"
    command -v queue_release >/dev/null 2>&1 \
      && { queue_release "$p" "$key" "hub could not hand the job to the builder" >/dev/null 2>&1 || true; }
    return 0
  fi
  mv "$active" "$qdir/$key.json" 2>/dev/null || true
}

# --- one project --------------------------------------------------------------
dispatch_project() {
  local p="$1"
  if command -v routing_builder >/dev/null 2>&1; then
    case "$(routing_builder "$p" 2>/dev/null)" in fly1) ;; *) return 0 ;; esac
  else
    flag_on builder-fly "$p" || return 0   # only flagged projects
  # Wave 3: the pool owns this project's queue when its flag is set. Stand down
  # ENTIRELY — a half-active dispatcher with no APP/token exported "claims" jobs
  # it can never push, starts the builder for nothing, and misreads the runner's
  # 10-min idle-exit as died-mid-build (the 2026-08-12 project-3 TK-49/62/64 loop).
    flag_on fly-pool "$p" && return 0
  fi
  local sf="$STATE_DIR/$p.json"; [ -f "$sf" ] || return 0
  # >>> rows-only (BH-1026.3) — resolved ONCE per project, for the same reason
  # the top loop resolves it once: rc 1 (the list did not answer) is the only
  # value that falls back to the files, and a second resolution mid-function is
  # a second answer to one question.
  local rows_only=0 rlist="" rlrc=1
  if command -v build_queue_rows_only_on >/dev/null 2>&1 && build_queue_rows_only_on \
     && command -v queue_list >/dev/null 2>&1; then
    rlist=$(queue_list "$p" queued fly 2>/dev/null); rlrc=$?
    [ "$rlrc" -ne 1 ] && rows_only=1
  fi
  # <<< rows-only
  local active="$STATE_DIR/$p-active.json"
  local qdir="$QUEUE_ROOT/$p"; mkdir -p "$qdir"

  if ! fly_env "$p"; then
    say "$p" "missing app or $(tok_var "$p") — cannot dispatch"; return 0
  fi
  local st; st=$("$BIN/fly-api.sh" "$p" state 2>/dev/null || echo unknown)

  # --- (1) active job with a RESULT ready -> ingest ---------------------------
  if [ -f "$active" ]; then
    if [ "$st" = "started" ]; then
      if grep -q yes <<<"$(bssh "$p" "[ -f /run/harness/RESULT ] && echo yes || echo no" 2>/dev/null)"; then
        say "$p" "RESULT present on builder — invoking results ingest"
        "$BIN/fly-results-ingest.sh" "$p" || say "$p" "results-ingest returned nonzero"
        return 0
      fi
    fi

    # --- (2) died mid-build? machine stopped/failed OR heartbeat stale --------
    local dead=0 reason=""
    if [ "$st" = "stopped" ] || [ "$st" = "failed" ]; then dead=1; reason="machine $st"; fi
    if [ "$dead" = "0" ] && [ "$st" = "started" ]; then
      # heartbeat staleness: builder-runner touches /run/harness/heartbeat every 60s.
      local hbage
      hbage=$(bssh "$p" 'now=$(date +%s); h=$(stat -c %Y /run/harness/heartbeat 2>/dev/null || echo 0); echo $((now-h))' 2>/dev/null | tr -dc '0-9')
      if [ -n "$hbage" ] && [ "$hbage" -gt 600 ]; then dead=1; reason="heartbeat stale ${hbage}s"; fi
    fi
    if [ "$dead" = "1" ]; then
      local key attempt ticket; key=$(jq -r '.key // ""' "$active")
      attempt=$(jq -r '.attempt // 0' "$active"); ticket=$(jq -r '.ticket_id // ""' "$active")
      local next=$((attempt + 1))
      say "$p" "builder died mid-build ($reason) key=$key attempt=$attempt -> requeue attempt=$next"
      rm -f "$active"
      # ...and the ingest's relay hold for this key, if it had one (BH-1041).
      # The flag exists to keep the "held on the builder" line to one per key;
      # it is cleared by the ingest on any non-deferred completion, and this is
      # the other way a key leaves the active row. Left behind, it silences the
      # line for the rebuilt attempt of the same key — the next outage on the
      # key that most recently survived one would be the one nobody sees.
      [ -n "$key" ] && rm -f "$STATE_DIR/$p-$key.relay-deferred"
      # UNDER THE FLAG THE ROW IS THE REQUEUE (BH-1026.3). These two writes are
      # the only place this lane records a death, and the rows path never reads
      # $qdir — so left as files they would be a park nobody can see and a retry
      # nobody runs. The `failed` reason is the exact shape br_from_queue keys on
      # (`died N times`), and the requeue is close-then-enqueue for the reason
      # bin/fly-pool.sh's QROW states: enqueueing over a still-`claimed` row is a
      # duplicate by design.
      if [ "$next" -ge 2 ]; then
        # attempt>=2: give up, mark .failed, alert once.
        if [ "$rows_only" = 1 ]; then
          queue_done "$p" "$key" failed "died $next times ($reason) — parked for the blocked-resolver" >/dev/null 2>&1 || true
        else
          jq -nc --arg k "$key" --arg t "$ticket" --argjson a "$next" --arg r "$reason" --arg ts "$(STAMP)" \
            '{key:$k,ticket_id:$t,attempt:$a,reason:$r,failed_at:$ts}' > "$qdir/$key.failed.json"
        fi
        fleet_alert "$p" "failed:$key" "Fly build $key failed after $next attempts ($reason) — marked .failed; drop flags/builder-fly-$p to route $p builds locally while investigating."
      else
        # requeue with attempt+1 so the runner's PR-adopt preflight catches a
        # build that already opened its PR instead of duplicating it.
        if [ "$rows_only" = 1 ]; then
          # NOT "died N times": that phrase is br_from_queue's park trigger, and
          # this row is being re-offered, not parked.
          queue_done "$p" "$key" failed "builder died mid-build ($reason) — requeued as attempt $next" >/dev/null 2>&1 || true
          queue_put  "$p" "$key" "$ticket" fly "$next" >/dev/null 2>&1 || true
        else
          jq -nc --arg t "$ticket" --arg k "$key" --argjson a "$next" --arg ts "$(STAMP)" \
            '{ticket_id:$t,key:$k,attempt:$a,enqueued_at:$ts}' > "$qdir/$key.json"
        fi
      fi
      return 0
    fi
    # active job, machine started, no RESULT, heartbeat fresh -> still building.
    say "$p" "active job in progress (state=$st) — waiting"
    return 0
  fi

  # --- no active job ----------------------------------------------------------
  # A HOTFIX JOB IS TAKEN FIRST (#368). This lane carries ONE job per project at
  # a time (FLY_DISPATCH_WIP=1 — "that ceiling is a machine, not a lock"), so
  # which file it picks IS the ordering, and an emergency behind an alphabetical
  # accident would wait a whole build for it.
  # INITIALISED, not just declared. `set -u` is on (line 44) and the region below
  # only ASSIGNS next_job when the lane is on: with flags/hotfix-lane-off set, a
  # bare `local next_job` makes the very next line expand an unset variable and
  # abort this project's subshell — no pick, no alphabetical fallback, and the
  # `|| say` at the call site never runs either, so the kill switch would silently
  # stop dispatching instead of restoring the pre-#368 pick it promises.
  local next_job=""
  # >>> next job pick
  # `hf_on` is deliberately NOT `local`: tests/hotfix-cap-exempt-test.sh sources
  # this region in a bare subshell to drive it under the kill flag, and `local`
  # outside a function is an error there.
  hf_on=1; command -v hotfix_lane_on >/dev/null 2>&1 && hf_on=$(hotfix_lane_on "$HARNESS")
  #
  # A HELD TICKET IS SKIPPED, NEVER WAITED ON (BH-1526 review, S-1). The pick
  # is hotfixes first, then everything, oldest first — and the first row whose
  # ticket is NOT held wins. Asking only at the claim, as round 0 did, returned
  # from the whole project when the oldest row was held, so one HOLD stalled
  # every other queued ticket behind it for as long as the HOLD stood. A held
  # row stays queued (it is only skipped this tick), so a RESUME makes it
  # buildable again with nothing to re-enqueue. The reading is bin/lib/hold.sh's;
  # a read that did not answer is not a hold and the row is offered as before.
  # `_nj*` are deliberately not `local`, for the bare-subshell reason above.
  #
  # DISPATCH MODE hotfix-only (BH-6350) skips a job dm_job_admit refuses, the
  # same way as a HOLD: it stays queued, and one line per tick names them all.
  # `DM_MODE` stays set for the rows pick below.
  DM_MODE=normal; _njdm=""
  command -v dm_read >/dev/null 2>&1 && dm_read "$p"
  for _nj in $( { [ "$hf_on" = 1 ] && grep -l '"hotfix": *true' "$qdir"/*.json 2>/dev/null | grep -v '\.failed\.json$' | sort
                  ls -1 "$qdir"/*.json 2>/dev/null | grep -v '\.failed\.json$' | sort; } | awk '!seen[$0]++' ); do
    _njt=$(jq -r '.ticket_id // ""' "$_nj" 2>/dev/null) || _njt=""
    if [ -n "$_njt" ] && command -v to_build_hold >/dev/null 2>&1 \
       && _njh=$(to_build_hold "$p" "$_njt" "$(basename "$_nj" .json)"); then
      say "$p" "HOLD, skipping $(basename "$_nj" .json) (${_njh#*	}) — it stays queued; the next unheld row is offered instead"
      continue
    fi
    if command -v dm_job_admit >/dev/null 2>&1 && ! dm_job_admit "$_nj"; then
      _njdm="$_njdm $(basename "$_nj" .json)"; continue
    fi
    next_job="$_nj"; break
  done
  [ -n "$_njdm" ] && say "$p" "DISPATCH-MODE hotfix-only, skipping:$_njdm — they stay queued"
  # <<< next job pick

  # >>> rows pick (BH-1026.3)
  # The region above is the FILE pick and is left exactly as it is —
  # tests/hotfix-cap-exempt-test.sh sources it by those two marker lines. Under
  # the flag its answer is replaced here, from the rows: the hotfix row first
  # (same rule, same kill flag), then the list order, which the worker returns as
  # `enqueued_at ASC` — the oldest queued row, which is what `sort | head -1`
  # approximated with filenames.
  #
  # IT IS STILL A FILE PATH, and deliberately so: everything between here and
  # the claim — the client-court guard, the overlap guard, `basename … .json`,
  # the env bundle, `push_file "$active"` — reads the job as a FILE, and three
  # of those are marked regions other suites source verbatim. So the picked row
  # is materialised into a PRIVATE per-project scratch directory (dot-prefixed,
  # invisible to every `*.json` glob in this file, rebuilt from scratch each
  # tick) rather than into state/build-queue/<p>/, which is the directory the
  # ticket is removing. Nothing else ever reads it: it is `mv`d onto
  # <p>-active.json the instant the claim is won, and a tick that returns early
  # leaves at most one stale file behind that the next tick deletes.
  local row_key="" rowdir="$STATE_DIR/.rowjob-$p"
  if [ "$rows_only" = 1 ]; then
    next_job=""
    rm -rf "$rowdir"; mkdir -p "$rowdir"
    local _rk _rtid _ratt _rmeta _rhot _rtid_pick="" _ratt_pick="" _rmeta_pick="" _rdm="" _rcg=""
    while IFS="$(printf '\t')" read -r _ _rk _rtid _ _ _ratt _ _ _ _rmeta; do
      [ -n "${_rk:-}" ] || continue
      # A key already live on a pool machine is not queued work (TK-70,
      # 2026-08-13): the file path never saw one because the pool moves the file
      # away at spawn, and the row path has to say so itself.
      grep -ls "\"key\": *\"$_rk\"" "$HARNESS/state/fly-pool/$p/"*.json >/dev/null 2>&1 && continue
      # A push-rejected terminal is skipped, never claimed (BH-6821).
      if command -v pool_claim_guard >/dev/null 2>&1 && ! _rcg=$(pool_claim_guard "$p" "$_rk"); then
        say "$p" "refused claim of $_rk: $_rcg — fly-pool's terminal gate owns its re-arm"
        continue
      fi
      # Dispatch mode (BH-6350): the row form of the file pick's skip above.
      if command -v dm_meta_admit >/dev/null 2>&1 && ! dm_meta_admit "$_rtid" "${_rmeta:-}"; then
        _rdm="$_rdm $_rk"; continue
      fi
      _rhot=$(printf '%s' "${_rmeta:-}" | jq -r '.hotfix // false' 2>/dev/null)
      if [ "$hf_on" = 1 ] && [ "$_rhot" = true ]; then
        row_key="$_rk"; _rtid_pick="$_rtid"; _ratt_pick="$_ratt"; _rmeta_pick="$_rmeta"; break
      fi
      [ -n "$row_key" ] && continue
      row_key="$_rk"; _rtid_pick="$_rtid"; _ratt_pick="$_ratt"; _rmeta_pick="$_rmeta"
    done <<ROWPICK
$rlist
ROWPICK
    [ -n "$_rdm" ] && say "$p" "DISPATCH-MODE hotfix-only, skipping rows:$_rdm — they stay queued"
    if [ -n "$row_key" ] && command -v queue_row_job_file >/dev/null 2>&1; then
      # rc 3 (an unusable rebase object) has already closed the row and said so
      # once in the top loop; there is simply nothing to dispatch this tick.
      queue_row_job_file "$p" "$rowdir/$row_key.json" "$row_key" \
        "$_rtid_pick" "$_ratt_pick" "$_rmeta_pick" >/dev/null \
        && next_job="$rowdir/$row_key.json"
    fi
  fi
  # <<< rows pick

  if [ -z "$next_job" ]; then
    # (4) queue empty + machine started a while -> stop (belt-and-braces; runner
    # idle-exits on its own after 10m, this covers a stuck-awake machine).
    if [ "$st" = "started" ]; then
      say "$p" "queue empty, machine started — requesting stop (belt-and-braces)"
      "$BIN/fly-api.sh" "$p" stop >/dev/null 2>&1 || true
    fi
    return 0
  fi

  # queue has work.
  if [ "$st" != "started" ]; then
    say "$p" "queue non-empty, machine $st — starting builder"
    local final; final=$("$BIN/fly-api.sh" "$p" start 2>/dev/null); local rc=$?
    if [ "$rc" != "0" ] || [ "$final" != "started" ]; then
      say "$p" "start did not reach 'started' (got '$final') — retry next tick"
      return 0
    fi
    # wait until reachable over tailnet before pushing (up to ~60s).
    local w=0
    until reachable "$p"; do
      [ "$w" -ge 60 ] && { say "$p" "started but unreachable 60s — alerting, retry next tick"; \
        fleet_alert "$p" "unreach:$p" "Fly builder $p started but stayed unreachable 60s"; return 0; }
      sleep 5; w=$((w + 5))
    done
    say "$p" "builder reachable (start latency ~${w}s)"
  fi

  # Harness runtime on the volume must match the repo before any job runs
  # (medic 2026-07-31: missing /data/harness/bin dead-ended TK-41 in 2 min).
  "$BIN/fly-sync-harness.sh" "$p" >>"$DLOG" 2>&1 || { say "$p" "harness sync FAILED — not dispatching"; return 0; }

  # machine up + no active job -> claim the oldest queued job and push it.
  #
  # THE WIP GATE, SAID OUT LOUD (2026-09-12). This route's ceiling was only ever
  # the SHAPE of the code — one <p>-active.json, so at most one claim — which
  # meant bin/concurrency-plan.sh had nothing to read and a future edit that
  # claimed a second job would have broken the ceiling silently. The count is
  # against the same $FLY_DISPATCH_WIP the plan reports; with it at 1 this is
  # exactly the behaviour above (the [ -f "$active" ] branch has already
  # returned), so nothing changes today and a drift becomes visible.
  # UNDER THE FLAG THE CLAIM IS THE IN-FLIGHT ANSWER, not the file. The file is
  # the write-through cache and a reaper (or a hand) can remove it while the row
  # still says a build is running — and that gap is a second machine on a key
  # that is already building (the TK-70 shape). build_queue_active_key answers
  # the UNION of the rows and the file, one line per active key, so it can only
  # ever add one, never hide one.
  local inflight
  if [ "$rows_only" = 1 ] && command -v build_queue_active_key >/dev/null 2>&1; then
    inflight=$(build_queue_active_key "$p" 2>/dev/null | grep -c . | tr -d ' ')
  else
    inflight=$(ls -1 "$STATE_DIR/$p-active.json" 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [ "${inflight:-0}" -ge "$FLY_DISPATCH_WIP" ]; then
    say "$p" "at the single-machine dispatcher's wip of $FLY_DISPATCH_WIP — not claiming"
    return 0
  fi
  local key; key=$(basename "$next_job" .json)
  # >>> client-court guard (BH-411): read ticket id and refuse to hand a queued
  # job to a builder when the ticket is waiting on the client, not ready, or
  # whose newest comment is from the harness/system.
  local ticket_id
  ticket_id=$(jq -r '.ticket_id // ""' "$next_job" 2>/dev/null) || ticket_id=""
  # client-court gate body:
  # client, not ready, or whose newest comment is from the harness/system must
  # not be handed to a builder. The gate is fail-open OK, so a broken fetch
  # never blocks a legitimate dispatch. Leave the job in the queue; the triage
  # tick will re-evaluate the ticket.
  if [ -n "$ticket_id" ]; then
    local gb
    gb=$("$BIN/triage-gate.sh" "$p" --buildable "$ticket_id" 2>/dev/null) || gb="OK"
    case "$gb" in
      BLOCKED*) say "$p" "client-court, leaving $key queued ($gb)"; return 0 ;;
    esac
  fi
  # <<< client-court guard

  # OVERLAP GUARD (docs/SCHEDULER.md, 2026-09-15): a ticket whose planned files
  # collide with a build already running or with an open harness PR is left in
  # the queue and re-offered next tick — BUILD_DEFERRED semantics, no wait, no
  # queue. Fail-open with ONE exception (BH-782): the guard exits 0 on its kill
  # flag and on every question it could not ask, EXCEPT an open-PR list that
  # came back unreadable with no cached copy — that exits 1 with
  # `DEFER <KEY> gh unknown …`, because the half that went missing is the one
  # holding work already written. Non-zero is handled below exactly as a files
  # DEFER is: left queued, re-offered next tick. Do not "fix" a non-zero rc here
  # into a launch.
  # STACK_BASE rides in from the job just picked: under rows-only that job
  # lives in $STATE_DIR/.rowjob-<p>/, where the guard's own fallback
  # (state/build-queue/<p>/<KEY>.json) cannot see it, and a stacked child would
  # then defer against its own parent's PR every tick.
  local og="" og_sb=""
  og_sb=$(jq -r '.stack_base // empty' "$next_job" 2>/dev/null) || og_sb=""
  if [ -x "$BIN/overlap-guard.sh" ] && ! og=$(STACK_BASE="$og_sb" "$BIN/overlap-guard.sh" "$p" "$key" 2>/dev/null); then
    say "$p" "overlap guard: $og — leaving $key queued for the next tick"; return 0
  fi
  # THE CLAIM IS THE METERED SEAM (BH-1026.3). With the flag on the compare-and-
  # swap on the row happens HERE — at the point the file path does its `mv`, and
  # before one byte of env bundle is pulled or one machine is pushed to. rc 9
  # (another claimant won) and rc 2 (no `queued` row for this key any more —
  # someone closed it between the list and the claim) are both CLEAN SKIPS: the
  # row is the source, so "the row is not queued" is a real answer and never a
  # reason to dispatch anyway. rc 1 is an outage after a successful list, and an
  # outage falls back rather than spawning speculatively.
  if [ "$rows_only" = 1 ]; then
    local crc=0
    queue_claim "$p" fly "$key" "$(jq -r '.machine_id // ""' "$sf" 2>/dev/null)" >/dev/null 2>&1 || crc=$?
    if [ "$crc" != 0 ]; then
      rm -f "$next_job"
      say "$p" "$key: the queue row refused this claim (rc $crc; row is $(queue_status "$p" "$key" 2>/dev/null || echo unreadable)) — nothing dispatched, re-offered next tick"
      return 0
    fi
  fi
  say "$p" "claiming job $key -> active"
  # A WON CLAIM THAT NEVER REACHED THE CACHE IS STILL A WON CLAIM (BH-1026.3).
  # With the flag off $next_job is still sitting in $qdir and the next tick
  # re-offers it, so there is nothing to undo. With the flag on it is in
  # $rowdir, which this function rebuilds from scratch every tick — so the row
  # has to be handed back here, or the key reads as in flight with nothing
  # building it until the 6h stale-claim sweep.
  mv "$next_job" "$active" || {
    [ "$rows_only" = 1 ] && unclaim_job "$p" "$key" "$next_job" "$qdir" 1
    say "$p" "could not claim $next_job"; return 0; }

  # build the env bundle (pulled from owning box), push bundle + job, then shred.
  local tmp; tmp=$(mktemp -d /dev/shm/flyenv.XXXXXX 2>/dev/null || mktemp -d)
  chmod 700 "$tmp"
  if ! "$BIN/fly-envbundle.sh" "$p" "$tmp" >/dev/null 2>>"$DLOG"; then
    say "$p" "env bundle build FAILED — un-claiming $key (retry next tick)"
    unclaim_job "$p" "$key" "$active" "$qdir" "$rows_only"
    rm -rf "$tmp"; return 0
  fi

  local ok=1
  push_file "$p" "$tmp/global.env"     "/run/harness-env/global.env" || ok=0
  push_file "$p" "$tmp/$p.env"         "/run/harness-env/$p.env"      || ok=0
  # Codex fallback auth (2026-08-01): codex authenticates via ~/.codex files,
  # not env — without them the builder's RUNNER_*_FALLBACK=codex fires
  # unauthenticated and dies silently (TK-41 EXECUTE_EMPTY). Pull from the
  # owning box per dispatch; rootfs is ephemeral so this re-ships every boot.
  box_ip=$(owner_ip "$p" || true)
  if [ -n "$box_ip" ] && [ "$box_ip" != local ]; then
    timeout 20 scp -q "root@$box_ip:/root/.codex/auth.json" "$tmp/codex-auth.json" 2>/dev/null || true
    timeout 20 scp -q "root@$box_ip:/root/.codex/config.toml" "$tmp/codex-config.toml" 2>/dev/null || true
  else
    cp /root/.codex/auth.json "$tmp/codex-auth.json" 2>/dev/null || true
    cp /root/.codex/config.toml "$tmp/codex-config.toml" 2>/dev/null || true
  fi
  if [ -s "$tmp/codex-auth.json" ]; then
    bssh "$p" "mkdir -p /root/.codex" >/dev/null 2>&1
    push_file "$p" "$tmp/codex-auth.json" "/root/.codex/auth.json" || say "$p" "codex auth push failed (fallback will be claude-only)"
    [ -s "$tmp/codex-config.toml" ] && push_file "$p" "$tmp/codex-config.toml" "/root/.codex/config.toml"
  fi
  # The build's model routes as this box resolved them (BH-1572): a builder that
  # cannot reach the worker at job start builds on these rather than deferring.
  # In a subshell, so the resolver never changes this script's shell; a failure
  # here costs that outage cover and nothing else.
  if ( . "$HARNESS/bin/lib/model-route.sh" 2>/dev/null && model_routes_bundle "$p" "$tmp/model-routes.tsv" ) >/dev/null 2>&1; then
    push_file "$p" "$tmp/model-routes.tsv" "/run/harness-env/model-routes.tsv" \
      || say "$p" "model-routes bundle push failed — the builder resolves its own ladders at job start"
  fi
  # job file LAST — the runner keys off job.json appearing/mtime-changing.
  if [ "$ok" = "1" ]; then
    push_file "$p" "$active"           "/run/harness/job.json"        || ok=0
  fi

  # shred the local bundle immediately (secrets never linger on the hub disk).
  shred -u "$tmp"/*.env 2>/dev/null || rm -f "$tmp"/*.env
  rm -rf "$tmp"

  if [ "$ok" != "1" ]; then
    say "$p" "push FAILED for $key — un-claiming (retry next tick), one beat"
    unclaim_job "$p" "$key" "$active" "$qdir" "$rows_only"
    fleet_alert "$p" "push:$key" "Fly push failed for $key — requeued, will retry next tick"
    return 0
  fi

  say "$p" "dispatched $key to builder-$p (env + job pushed)"
  beat "$(jq -nc --arg p "$p" --arg k "$key" \
    '{kind:"build",project:$p,ticket_key:$k,stage:"fly_dispatched",host:("builder-"+$p)}')"
}

# --- --drain: print the queue as run-build invocations for the watcher --------
if [ "${1:-}" = "--drain" ]; then
  P="${2:?usage: fly-dispatch.sh --drain <project>}"
  qd="$QUEUE_ROOT/$P"
  for f in "$qd"/*.json; do
    [ -f "$f" ] || continue
    case "$f" in *.failed.json) continue;; esac
    t=$(jq -r '.ticket_id // ""' "$f"); k=$(jq -r '.key // ""' "$f")
    echo "/root/harness/bin/run-build.sh $P $t $k"
  done
  exit 0
fi

# --- main: every provisioned project, none of them queued behind another -------
#
# 2026-09-13 ("we never lock and serialize"): these ran one after another, and a
# single project can hold the tick for a minute on its own (`fly-api start` then
# up to 60s of reachability polling) — time every later project simply lost. They
# share nothing: their own machine, their own app token, their own active file and
# queue directory. So each gets a subshell, which also means one project's
# exported FLY_ACCESS_TOKEN can no longer leak into the next one's calls, and the
# tick waits for all of them.
[ -d "$STATE_DIR" ] || exit 0
for sf in "$STATE_DIR"/*.json; do
  [ -f "$sf" ] || continue
  proj=$(basename "$sf" .json)
  case "$proj" in *-active) continue;; esac   # skip the active-job sidecar files
  ( dispatch_project "$proj" || say "$proj" "dispatch_project returned nonzero" ) &
done
wait
