#!/bin/bash
# bin/cost-rows-push.sh [box-id] — EVERY box, every 10 minutes: mirror the rows
# logs/cost.csv has grown since the last run into the harness-jobs cost_rows
# table. the operator (2026-09-02): "move the rows to the DB as well."
#
# THE FILE STAYS THE TRUTH. bin/agent-call.sh keeps appending to cost.csv
# exactly as before and nothing here reads, rewrites or trims it; this is a
# one-way copy so a fleet-wide question ("what did account X spend this week")
# is one query instead of nine ssh sessions, and a box that dies takes its
# rows' readable copy with it no further than the last tick.
#
# Thin on purpose: the cursor, the chunking and the idempotency all live in
# bin/jobs-client.sh metric_cost_rows (the cursor is a file line number that
# advances only after a 2xx; the worker's PK makes a re-push a no-op). This
# wrapper adds the per-box identity, a lock so two ticks cannot interleave, one
# log line when something moved, silence when nothing did, and ONE alert on the
# third consecutive failure — the fail-open contract every other jobs-client
# producer keeps: a worker outage costs a delay, never a row.
#
# Box id from argv like extra-usage-track.sh (the cron line passes the id its
# file is named for), then state/box-id, then the hostname. NOT bare `hostname`
# first: every Orgo box answers "orgo-desktop", and a PK that starts with that
# would fold nine boxes' rows into one.
#
# ── THE POOL MACHINES PUSH THEMSELVES TOO (2026-09-14) ───────────────────────
# A Fly pool machine is volume-less: its rootfs, and with it logs/cost.csv, dies
# with the machine. It had no mirror loop at all, so $1,456 of pool spend in a
# day existed only as jobs.spent_usd per-job totals — no per-stage, per-model or
# per-account row anywhere. fly/builder-runner.sh now runs THIS script on the
# machine every COST_ROWS_PUSH_S seconds and once more at every terminal path,
# under the box id `pool-<project>-<machine-id>`, and bin/fly-pool.sh's reap
# runs it once more over the reaped build cost.csv under the SAME box id. Three
# writers, ONE identity, and the (box, row_hash) PK makes the overlap a no-op.
# Two flags exist for the machine and the reap alike, because both run this file:
#   COST_ROWS_PUSH=0   (env/global.env, or the environment)
#   switch.cost-rows-push-off[.<box>]  (a settings row; with no row,
#   flags/cost-rows-push-off            the file, as before)
#
# Modes (the cron shape above is unchanged and is the only one any cron uses):
#
#   cost-rows-push.sh <box>
#       The 10-minute mirror. Silent when nothing moved; one log line when
#       something did; one ALERT on the third consecutive failure.
#
#   cost-rows-push.sh --box <id> [--csv <path>] [--cursor <path>]
#       Push ONE named csv under an explicit box id and print
#       "pushed <n> (<m> dup)" on stdout for the caller to log. This is the
#       reap path: whatever a machine never got to send lands here, and what it
#       did send comes back as dup. It deliberately does NOT touch the cron
#       lane's failure streak — a failed reap push is fly-pool's line to write,
#       not a fleet alert about some box's 10-minute mirror.
#
#   cost-rows-push.sh --verify <box> [--csv <path>] [--cursor <path>]
#       The reconcile check: data rows in the file, where the cursor sits, how
#       many rows are still owed, and how many rows the DB actually holds for
#       that box. rc 0 reconciled, 1 rows still owed, 2 the DB could not be read
#       (unknown is not "empty", and never reported as one).
#
# NEVER FROM A TEST (BH-3223). Under HARNESS_TEST_SANDBOX=1 the mirror and push
# modes print one line on stderr and exit 0 with the cursor untouched; --verify
# only reads and keeps answering. A row whose project is the test fixture
# `testproj` is never sent (_metric_cost_rows_chunk skips it and still advances
# the cursor) and never counted as owed by --verify. Suites run on Fly pool
# machines had put ~750 stub-runner rows into the production cost_rows table.
#
# ONLY FLEET PROJECTS AND LANE NAMES (BH-3982). Before the push, the mirror
# builds an allow list from bin/fleet-conf.sh --projects plus the words of
# $COST_ROWS_LANE_PROJECTS (cost_row_allowed_projects in bin/lib/cost-row.sh),
# and _metric_cost_rows_chunk skips any row whose project is not on it, exact
# and case-sensitive, advancing the cursor past it like a testproj row. Prod
# had 274 fixture rows (lproj, gateproj, freeproj, otherproj) from pool test
# runs. A run that drops rows writes ONE log line with the count and up to five
# names; silence when none. FAIL-OPEN: no cost-row.sh, no fleet-conf.sh or an
# empty fleet.conf means no list and no filter. All three modes use the list
# (--box filters and logs like cron; --verify does not count a dropped row as
# owed), and a push with no list writes one `allow list unavailable` line per
# UTC day (BH-4007). cost.csv keeps every row, so a real row dropped by mistake
# comes back by fixing fleet.conf or the knob and running
# `echo 0 > state/cost-rows-push.cursor`; the (box,row_hash) PK makes the
# re-push of everything else a no-op.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

MODE=cron; BOX=""; CSV=""; CUR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --csv)    CSV="${2:-}"; [ "$MODE" = verify ] || MODE=push; shift 2 ;;
    --cursor) CUR="${2:-}"; shift 2 ;;
    --box)    BOX="${2:-}"; MODE=push;   shift 2 ;;
    --verify) BOX="${2:-}"; MODE=verify; shift 2 ;;
    --)       shift ;;
    -*)       echo "usage: cost-rows-push.sh [box] | --box <id> [--csv f] [--cursor f] | --verify <box> [--csv f] [--cursor f]" >&2; exit 2 ;;
    *)        BOX="$1"; shift ;;
  esac
done
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ "$MODE" != verify ]; then
  echo "cost-rows-push: HARNESS_TEST_SANDBOX=1, refusing to POST (BH-3223)" >&2
  exit 0
fi
# ── IDENTITY IS ASSERTED, NEVER GUESSED (BH-1043), THROUGH ONE RESOLVER (BH-1032)
# This used to end `|| BOX=$(hostname -s)`, and every Orgo box answers the image
# default "orgo-desktop": a box whose state/box-id had not landed yet wrote its
# rows under a name that is not a box, a PHANTOM appeared in every metrics table
# merging however many machines were in that state, and the push reported
# success while doing it. An explicit id (argv, or --box on the pool path) is a
# DECLARED identity and still wins; with neither, bin/lib/box-id.sh alerts once
# a day and this lane writes nothing. cost.csv is the truth and is untouched, so
# the rows are held, not lost — the first tick after state/box-id lands sends
# every one of them.
#
# AND IT IS THE SAME RESOLVER THE AT-SOURCE WRITER USES (BH-1032).
# bin/lib/cost-row.sh's cost_row_emit files its row under cost_row_box_id, and
# cost_row_box_id delegates to box_id_get — one chain, so the at-source row and
# this mirror row land on the same PK instead of splitting one call across two
# box keys (two rows, every fleet total inflated). box_id_require is still what
# ALERTS, so a box with no identity says so exactly once a day and writes
# nothing either way; the literal state/box-id read stays only as the fallback
# for a box whose sync has landed neither library.
if [ -z "$BOX" ]; then
  # shellcheck source=bin/lib/cost-row.sh
  for _P in "$(dirname "${BASH_SOURCE[0]}")/lib/cost-row.sh" "$H/bin/lib/cost-row.sh"; do
    # shellcheck source=/dev/null
    [ -r "$_P" ] && { . "$_P"; break; }
  done
  command -v cost_row_box_id >/dev/null 2>&1 && BOX=$(cost_row_box_id)
fi
if [ -z "$BOX" ]; then
  # shellcheck source=bin/lib/box-id.sh
  . "$H/bin/lib/box-id.sh" 2>/dev/null || true
  if command -v box_id_require >/dev/null 2>&1; then
    BOX=$(box_id_require cost-rows-push) || BOX=""
  else
    BOX=$(tr -dc 'A-Za-z0-9._-' < "$H/state/box-id" 2>/dev/null || true)
  fi
fi
if [ -z "$BOX" ]; then
  [ "$MODE" = push ]   && echo "pushed 0 (0 dup) — no box identity (\$BOX_ID / state/box-id); see logs/ALERTS.log"
  [ "$MODE" = verify ] && { echo "verify: no box identity (\$BOX_ID / state/box-id)"; exit 2; }
  exit 0
fi
CSV="${CSV:-$H/logs/cost.csv}"
CUR="${CUR:-$H/state/cost-rows-push.cursor}"
LOG="$H/logs/cost-rows-push.log"
FAILS="$H/state/cost-rows-push.fails"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/state" "$H/logs" "$H/locks" 2>/dev/null

# Nothing to mirror yet (a box that has never made a call) is not an event.
# --verify still answers: "the file is empty" is a fact the check must report,
# not a reason to say nothing.
if [ ! -s "$CSV" ] && [ "$MODE" != verify ]; then
  [ "$MODE" = push ] && echo "pushed 0 (0 dup) — no rows at $CSV"
  exit 0
fi

# global.env is sourced HERE because cron does not — HARNESS_SECRET and JOBS_URL
# live there. `+u` around it: an unbound reference inside the env file must not
# kill the pusher silently (see extra-usage-track.sh for the incident).
# The env's own COST_ROWS_PUSH wins over the file's: a one-off
# `COST_ROWS_PUSH=0 cost-rows-push.sh ...` must not be overwritten by the
# default sitting in global.env.
_CRP="${COST_ROWS_PUSH:-}"
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-cost-rows-push
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off cost-rows-push.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# Only the cron mode is the tick (BH-7422). --box/--csv (a pool reap push) and
# --verify are helper calls and never take the one-run claim: a skipped reap
# push would lose that machine's cost rows.
[ "$MODE" = cron ] || LANE_SINGLE_RUN=0
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit cost-rows-push
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    cost-rows-push
[ -n "$_CRP" ] && COST_ROWS_PUSH="$_CRP"
# BH-2433: the kill switch below is read through lane_switch, so a settings
# row switch.<name>[.<box>] settles it before the file does.
# shellcheck source=lib/lane-switch.sh
. "${HARNESS:-/root/harness}/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "${HARNESS:-/root/harness}/flags/$1" ]; }   # no lib: the file, as before

# KILL SWITCH, machine and hub reap alike, because both run THIS file. --verify
# is read-only and keeps answering: with the mirror off the honest report is a
# growing `unpushed`, not silence.
# The message names what actually turned it off (D13): the env, the row that
# answered, or the file.
if [ "$MODE" != verify ]; then
  _OFF=""
  if [ "${COST_ROWS_PUSH:-1}" = 0 ]; then _OFF="COST_ROWS_PUSH=0"
  elif lane_switch cost-rows-push-off file; then
    case "${LANE_SWITCH_SRC:-legacy}" in
      box-row)   _OFF="settings $(_ls_box_key cost-rows-push-off)" ;;
      fleet-row) _OFF="settings switch.cost-rows-push-off" ;;
      *)         _OFF="flags/cost-rows-push-off" ;;
    esac
  fi
  if [ -n "$_OFF" ]; then
    [ "$MODE" = push ] && echo "pushed 0 (0 dup) — cost-rows-push is off ($_OFF)"
    exit 0
  fi
fi

# The client is repo-managed and rides every sync; a box without it is a box
# mid-bootstrap, and the next tick will find it. Say so once a day, not 144x.
if [ ! -f "$H/bin/jobs-client.sh" ]; then
  F="$H/flags/alerted-cost-rows-noclient-$(date -u +%Y%m%d)"
  [ -f "$F" ] || { mkdir -p "$H/flags" && touch "$F"; echo "$(STAMP) [$BOX] cost-rows-push: bin/jobs-client.sh missing — cost.csv rows are not reaching the DB" >> "$LOG"; }
  [ "$MODE" = push ] && echo "pushed 0 (0 dup) — bin/jobs-client.sh missing"
  [ "$MODE" = verify ] && echo "verify $BOX: bin/jobs-client.sh missing" && exit 2
  exit 0
fi
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh"

# BH-3982: the allow list and per-run drop log (see the header), for every
# mode. Built after the lane gate and lane_env_apply, so a
# COST_ROWS_LANE_PROJECTS settings row is already in the environment, and
# before --verify, which reads the list to know what is owed. --verify stays
# read-only: no drop log, no day flag, no log line.
COST_ROWS_ALLOW=""; COST_ROWS_DROP_LOG=""
if ! command -v cost_row_allowed_projects >/dev/null 2>&1; then
  for _P in "$(dirname "${BASH_SOURCE[0]}")/lib/cost-row.sh" "$H/bin/lib/cost-row.sh"; do
    # shellcheck source=/dev/null
    [ -r "$_P" ] && { . "$_P"; break; }
  done
fi
if command -v cost_row_allowed_projects >/dev/null 2>&1; then
  COST_ROWS_ALLOW=$(cost_row_allowed_projects 2>/dev/null | tr '\n' ' ')
  if [ "$MODE" != verify ]; then
    if [ -z "${COST_ROWS_ALLOW// /}" ]; then
      # Fail-open is silent in the push itself; say it once a UTC day here.
      F="$H/flags/alerted-cost-rows-noallow-$(date -u +%Y%m%d)"
      [ -f "$F" ] || { mkdir -p "$H/flags" && touch "$F"; echo "$(STAMP) [$BOX] cost-rows-push: allow list unavailable (fleet-conf.sh --projects answered nothing) — not filtering" >> "$LOG"; }
    fi
    COST_ROWS_DROP_LOG=$(mktemp "${TMPDIR:-/tmp}/cost-rows-drop.XXXXXX" 2>/dev/null) || COST_ROWS_DROP_LOG=""
    trap 'rm -f "${COST_ROWS_DROP_LOG:-}"' EXIT
  fi
fi
export COST_ROWS_ALLOW COST_ROWS_DROP_LOG

# ── --verify: local file vs what the DB actually holds ───────────────────────
# Counts the file the same way the pusher reads it (header, blank and
# impossible-width lines are not rows), so "unpushed" means rows the DB is
# genuinely owed rather than lines nobody was ever going to send.
if [ "$MODE" = verify ]; then
  read -r VROWS VBEFORE < <(python3 - "$CSV" "$(tr -dc '0-9' < "$CUR" 2>/dev/null)" <<'PYEOF'
import csv, itertools, sys
import os
allow = set(os.environ.get("COST_ROWS_ALLOW", "").split())
path = sys.argv[1]
cur = int(sys.argv[2] or 0)
total = after = 0
try:
    with open(path, newline="", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            raw = line.rstrip("\r\n")
            if not raw.strip() or raw.startswith("ts,host,"):
                continue
            f = next(csv.reader([raw]))
            # THE CEILING TRACKS THE ROW, NOT A SNAPSHOT OF IT (BH-1032). This
            # said `or len(f) > 16` — the width a row had before the transcript
            # wave appended session_id/row_source/result_usd, the four
            # attribution tags and `note`. Every row written since then is 24
            # columns wide, so --verify counted ZERO data rows on every box and
            # reported `unpushed=0` no matter how far behind the mirror was:
            # the one check that exists to notice a stuck cursor could not see a
            # single modern row. The floor is what the pusher itself uses
            # (_metric_cost_rows_chunk skips a row narrower than 13 and TAKES
            # the known columns of a wider one), so the two now agree on what a
            # row is.
            if len(f) < 13:
                continue
            # BH-3223: the pusher never sends a test fixture row, so it is
            # not owed either.
            if f[2] == "testproj":
                continue
            # BH-3982: nor is a row the allow list drops. An empty list
            # counts every row, the same fail-open as the pusher.
            if allow and f[2] not in allow:
                continue
            total += 1
            if n > cur:
                after += 1
except OSError:
    pass
print(total, after)
PYEOF
  ) || { VROWS=0; VBEFORE=0; }
  VCUR=$(tr -dc '0-9' < "$CUR" 2>/dev/null); VCUR="${VCUR:-0}"
  VSENT=$((VROWS - VBEFORE))
  # limit is the worker's own ceiling for this route; a pool machine's build is
  # a few dozen rows, so the cap only bites on a box-wide verify and the report
  # says so rather than pretending 2000 is the answer.
  VDB=unknown
  if VRESP=$(_jobs_req GET "/api/metrics/cost-rows?box=$BOX&limit=2000" 2>/dev/null); then
    VDB=$(printf '%s' "$VRESP" | grep -o '"row_hash"' | wc -l | tr -dc '0-9')
    VDB="${VDB:-0}"
  fi
  echo "verify $BOX: csv=$CSV data_rows=$VROWS cursor=$VCUR pushed_local=$VSENT unpushed=$VBEFORE db_rows=$VDB"
  [ "$VDB" = unknown ] && exit 2
  [ "$VBEFORE" -eq 0 ] && [ "$VDB" -ge "$VSENT" ] && exit 0
  exit 1
fi

# One pusher per box at a time. A 10-minute tick that overlaps a slow first
# backfill would read the same cursor twice; the PK would absorb the duplicate
# but the log would say the rows were pushed twice, which is not true.
# The reap's lock is named for the BOX it is pushing (a pool machine), never the
# box-wide one: a hub reap must not be skipped because the hub's own 10-minute
# mirror happens to be mid-push, and vice versa.
LOCKF="$H/locks/cost-rows-push.lock"
[ "$MODE" = push ] && LOCKF="$H/locks/cost-rows-push-$(printf '%s' "$BOX" | tr -dc 'A-Za-z0-9._-').lock"
exec 9>"$LOCKF"
flock -n 9 || { [ "$MODE" = push ] && echo "pushed 0 (0 dup) — another push for $BOX holds the lock"; exit 0; }

_drop_line() {
  [ "$MODE" != verify ] && [ -s "${COST_ROWS_DROP_LOG:-}" ] || return 0
  local n names
  n=$(wc -l < "$COST_ROWS_DROP_LOG" | tr -dc '0-9')
  names=$(sort -u "$COST_ROWS_DROP_LOG" | head -5 | tr '\n' ' '); names="${names% }"
  echo "$(STAMP) [$BOX] dropped $n row(s) whose project is not in fleet.conf or COST_ROWS_LANE_PROJECTS ($names) — BH-3982" >> "$LOG"
}

BEFORE=$(tr -dc '0-9' < "$CUR" 2>/dev/null); BEFORE="${BEFORE:-0}"
if OUT=$(metric_cost_rows "$CSV" "$CUR" "$BOX"); then
  _drop_line
  # "<pushed> <cursor> <inserted>". INS is what the worker reported as actually
  # NEW; the rest of what we sent was already there — a machine's own push, a
  # resend after a failure, a cursor reset. Reported as `dup` rather than
  # hidden, because on the reap path the dup count IS the evidence that the
  # dying machine's own loop had been working.
  read -r PUSHED AFTER INS <<<"$OUT"
  PUSHED="${PUSHED:-0}"; AFTER="${AFTER:-$BEFORE}"; INS="${INS:-0}"
  DUP=$((PUSHED - INS)); [ "$DUP" -lt 0 ] && DUP=0
  if [ "$MODE" = push ]; then
    echo "pushed $PUSHED ($DUP dup)"
    [ "${PUSHED:-0}" -gt 0 ] && echo "$(STAMP) [$BOX] pushed $PUSHED rows ($DUP dup) from $CSV (cursor $BEFORE -> $AFTER)" >> "$LOG"
    exit 0
  fi
  rm -f "$FAILS"
  # Silent when nothing new: a quiet tick is the normal tick.
  if [ "${PUSHED:-0}" -gt 0 ] || [ "$AFTER" != "$BEFORE" ]; then
    echo "$(STAMP) [$BOX] pushed $PUSHED rows (cursor $BEFORE -> $AFTER of $(wc -l < "$CSV" | tr -dc '0-9') lines)" >> "$LOG"
  fi
else
  _drop_line
  AFTER=$(tr -dc '0-9' < "$CUR" 2>/dev/null); AFTER="${AFTER:-0}"
  if [ "$MODE" = push ]; then
    echo "pushed 0 (0 dup) — push FAILED (http=${JOBS_HTTP:-none})"
    echo "$(STAMP) [$BOX] push FAILED from $CSV (cursor $BEFORE -> $AFTER, http=${JOBS_HTTP:-none}) — the caller owns the retry" >> "$LOG"
    exit 1
  fi
  N=$(tr -dc '0-9' < "$FAILS" 2>/dev/null); N=$((${N:-0} + 1))
  echo "$N" > "$FAILS"
  echo "$(STAMP) [$BOX] push FAILED (consecutive: $N; cursor $BEFORE -> $AFTER, http=${JOBS_HTTP:-none}) — will retry next tick" >> "$LOG"
  # The third failure in a row is a lane that is down, not a blink. Exactly one
  # alert per streak: the counter keeps climbing and only 3 fires it.
  if [ "$N" -eq 3 ]; then
    echo "$(STAMP) [$BOX] cost-rows-push: 3 consecutive failed pushes to $JOBS_URL/api/metrics/cost-rows (cursor stuck at $AFTER of $(wc -l < "$CSV" | tr -dc '0-9') lines, http=${JOBS_HTTP:-none}). cost.csv is intact; the DB mirror is stale. Check the harness-jobs worker deploy + HARNESS_SECRET; see $LOG." >> "$H/logs/ALERTS.log"
  fi
fi
exit 0
