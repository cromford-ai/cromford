#!/bin/bash
# bin/cost-rollup.sh — nightly cost-per-PR rollup (hub cron 04:45Z).
#
# Joins every AI call the fleet logged to the PR it produced, so per-PR
# economics is a number, not an archaeology session. Three outputs under
# state/cost/: fleet-cost.csv (all boxes' rows, deduped), cost-per-pr.csv
# (one row per PR with stage breakdown; its trailing fly_usd is the Fly
# machine time inside cost_usd, empty when the PR has no priced Fly row, never
# $0), summary.json (per-project 7d/30d
# aggregates incl. the triage-overhead share). One daily Telegram beat.
# WINDOWS_ONLY=1 (hourly cron :50) refreshes the 24h/7d/30d windows and the
# dashboard snapshot only — no PR stamping, no beats.
#
# Attribution: exact for builds that carry a per-build cost.csv (agent-call
# tees rows into the build dir since 2026-08-15); build dir -> PR URL from the
# jobs ledger (bin/lib/builds-of-record.sh, BH-2351), and from a hub dir's
# RESULT only when the ledger does not name that dir. Other boxes' builds are
# the cost_rows rows grouped by run_id and bound by the ledger alone (BH-2527).
# History before that stays project-level — stated, never guessed.
# Rows with tokens but no dollars are priced from catalog/model-prices.json
# (refreshed daily from the OpenRouter models API).
set -uo pipefail
# Overridable so the fixtures can drive the liveness block against a scratch
# tree; cron never sets it, so production resolves to the path it always had.
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-cost-rollup
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off cost-rollup.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit cost-rollup
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    cost-rollup
# BH-3322: where the watchdog lives; unset skips only the snapshot push below.
. "$H/bin/lib/watchdog-url.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/watchdog-url.sh" 2>/dev/null || { watchdog_url() { return 1; }; watchdog_secret() { return 1; }; }
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
CD="$H/state/cost"; mkdir -p "$CD"

# ── 0. One run at a time, and never forever (2026-09-15) ─────────────────────
# This lane is the ONLY writer of state/cost/, every dashboard dollar figure
# reads what it wrote, and until today it had neither a lock nor a deadline. An
# hourly cron with no lock and no timeout has one failure mode and it is silent:
# a run wedges on an unreachable box, the next hour's run starts anyway, and two
# collectors interleave writes to the same CSVs; or a run holds a half-written
# file for hours while every hourly tick after it stacks up behind the same hung
# ssh. Nothing in the fleet would have said so — the lane logs only on success.
#
# A LOCK HERE IS DEDUPE, NEVER A QUEUE (the operator 2026-09-13). A tick that finds the
# lock held exits 0 immediately; the work is hourly and idempotent, so the next
# tick does it. It does NOT wait, because waiting is how one wedged run becomes
# twenty wedged runs.
#
# >>> rollup timebox lock
# The deadline is a re-exec under `timeout` rather than a wrapper in cron,
# because the cron line is the one thing this script cannot ship a change to.
# Default 40 min: the run reaches no box (BH-2527) and its worker reads are
# paged, so this bounds a wedged request without cutting a slow read short.
if [ -z "${COST_ROLLUP_TIMEBOXED:-}" ] && command -v timeout >/dev/null 2>&1; then
  export COST_ROLLUP_TIMEBOXED=1
  exec timeout -k 60 "${COST_ROLLUP_TIMEOUT_S:-2400}" "$0" "$@"
fi
# The holder's pid + start sit BESIDE the lock (BH-4158), not under state/cost/:
# a pid means nothing off this box, so this is a local process fact, not state.
RUNMARK="$H/locks/cost-rollup.running"
LOCKF="$H/locks/cost-rollup.lock"
# FAIL OPEN, NEVER CLOSED. `exec 9>` on an unwritable path kills a non-
# interactive shell outright, and a bare `flock -n 9` on a box without
# util-linux returns non-zero — which reads as "someone else is running" and
# would make this lane exit 0 EVERY hour, forever, silently. Both are checked
# before the fd is opened, and a box that cannot lock runs WITHOUT one and says
# so: an overlapping rollup is a bad hour, a rollup that never runs again is a
# dead cost lane.
LOCKED=0
if command -v flock >/dev/null 2>&1 && mkdir -p "$H/locks" 2>/dev/null \
   && : 2>/dev/null > "$LOCKF"; then
  LOCKED=1
else
  echo "$(STAMP) cost-rollup: no flock, or locks/ is not writable — running WITHOUT a lock, so a concurrent run is possible" >> "$H/logs/agent-rules.log"
fi
if [ "$LOCKED" = 1 ]; then
  exec 9>"$LOCKF"
  if ! flock -n 9; then
    # WHO is holding it and SINCE WHEN, from the mark the holder wrote. A "skipped,
    # locked" line with no age on it cannot tell a healthy 3-minute overlap from a
    # run that has been wedged since breakfast, and those need opposite reactions.
    HOLD_PID=$(awk 'NR==1{print $1}' "$RUNMARK" 2>/dev/null)
    HOLD_AT=$(awk 'NR==1{print $2}' "$RUNMARK" 2>/dev/null)
    HOLD_AGE=0
    [ -f "$RUNMARK" ] && HOLD_AGE=$(( $(date +%s) - $(stat -c %Y "$RUNMARK" 2>/dev/null || date +%s) ))
    echo "$(STAMP) cost-rollup: skipped — pid ${HOLD_PID:-?} has held the lock since ${HOLD_AT:-?} (${HOLD_AGE}s)" >> "$H/logs/agent-rules.log"
    # Past 2x the cron interval the holder is not slow, it is stuck, and every
    # tick since has been a no-op. One line per day, naming the pid to kill.
    STALE_AFTER=$(( ${COST_ROLLUP_INTERVAL_S:-3600} * 2 ))
    if [ "$HOLD_AGE" -ge "$STALE_AFTER" ]; then
      LFLAG="$H/flags/alerted-cost-rollup-wedged-$(date -u +%Y%m%d)"
      if [ ! -f "$LFLAG" ]; then
        mkdir -p "$H/flags" 2>/dev/null && touch "$LFLAG" 2>/dev/null
        HARNESS="$H" "$H/bin/alert-line.sh" "[cost-rollup] a rollup run (pid ${HOLD_PID:-?}, started ${HOLD_AT:-?}) has held locks/cost-rollup.lock for $((HOLD_AGE/60))m — every hourly tick since has skipped, so state/cost/ is frozen at that run's start and every dashboard dollar figure is stale. Kill that pid; the next tick rebuilds everything (the rollup is idempotent)."
      fi
    fi
    exit 0
  fi
  # ONE TOKEN for the stamp, not STAMP()'s "date time" pair: the reader above
  # takes field 2, and a space in the value silently truncates it to the date.
  printf '%s %s\n' "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$RUNMARK"
  trap 'rm -f "$RUNMARK"' EXIT
  # The pre-BH-4158 mark, left by a run that died before its trap: we hold the
  # lock now, so nothing else can own it.
  rm -f "$CD/rollup-running"
fi
# <<< rollup timebox lock

# The box:project pairs whose projects the ledger pr binding below asks about,
# beside fleet.conf's. No box is reached at an address any more (BH-2527): the
# rows come from cost_rows and the meters from extra_usage_snapshots.
BOXPROJ="project-1:project-1 project-2:project-2 project-4:project-4 project-3:project-3 project-5:project-5 project-6:project-6 small:project-8"

# >>> ledger pr binding
# WHICH PR A BUILD DIR PRODUCED IS READ FROM THE LEDGER (BH-2351, slice 4 of
# BH-2312). The (result, pr_url) binding is written to the jobs ledger at build
# time; bor_list is its read side. Every project's rows land in $BOR_TSV, which
# the per-PR python below reads: a dir the ledger names gets its PR from there
# and its RESULT file is never opened.
#
# The ledger is the ONLY binding for a build that ran on another box (BH-2527:
# its RESULT is no longer tarred over ssh), so a project the ledger did not
# answer for, or a feed that hit its row cap, is named in agent-rules.log — its
# remote builds go unattributed this run rather than guessed. Hub dirs the
# ledger does not name still bind from their local RESULT. bor_list is called
# directly, not in $(...), so its BOR_TRUNCATED export is visible here.
BOR_TSV=$(mktemp)
for _P in "$(dirname "$0")/jobs-client.sh" "$H/bin/jobs-client.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
for _P in "$(dirname "$0")/lib/builds-of-record.sh" "$H/bin/lib/builds-of-record.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
BOR_PROJECTS=$( { awk '$1 != "" && $1 !~ /^#/ && $1 !~ /redirect/ { print $1 }' "$H/fleet.conf" 2>/dev/null
                  for B in $BOXPROJ; do echo "${B##*:}"; done; } | awk '!seen[$0]++')
BOR_SINCE=$(date -u -d '45 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || BOR_SINCE=""
BOR_N=0; BOR_MISS=""
if command -v bor_list >/dev/null 2>&1; then
  BOR_OUT=$(mktemp)
  for _BP in $BOR_PROJECTS; do
    BOR_N=$((BOR_N + 1))
    bor_list "$_BP" "$BOR_SINCE" > "$BOR_OUT" 2>/dev/null
    case $? in
      0|2) cat "$BOR_OUT" >> "$BOR_TSV" ;;
      *)   BOR_MISS="$BOR_MISS $_BP" ;;
    esac
    [ "${BOR_TRUNCATED-}" = 1 ] && BOR_MISS="$BOR_MISS $_BP(truncated)"
  done
  rm -f "$BOR_OUT"
fi
if [ "$BOR_N" -gt 0 ] && [ -z "$BOR_MISS" ]; then
  echo "$(STAMP) cost-rollup: ledger answered for all $BOR_N projects — PR binding from builds-of-record" >> "$H/logs/agent-rules.log"
elif [ "$BOR_N" -eq 0 ]; then
  echo "$(STAMP) cost-rollup: no builds-of-record reader or no projects — hub dirs bind from their RESULT, remote builds are not attributed this run" >> "$H/logs/agent-rules.log"
else
  echo "$(STAMP) cost-rollup: ledger did not answer for:$BOR_MISS — remote builds of those projects are not attributed this run, hub dirs the ledger does not name bind from their RESULT" >> "$H/logs/agent-rules.log"
fi
# <<< ledger pr binding

# ── 1. Collect fleet rows (idempotent merge) ─────────────────────────────────
#
# THE TABLE, AND NO TAILNET (BH-1032, BH-2527). Every row below has been
# mirrored into the harness-jobs `cost_rows` table since 2026-09-02, and written
# there at the moment of the call since BH-1032 — so the ssh sessions this loop
# used to open were re-reading a fact the DB already held, slower, and with the
# worst possible failure mode: a box that is unreachable reads as a box that
# spent nothing, and nothing downstream can tell that apart from a quiet box.
#
# The read is one call into bin/lib/cost-rows-read.sh, which answers in the
# CSV's own shape — so everything below this block is unchanged, down to the
# `sort -u`. When the table cannot be read (or the read is disarmed) there is
# no second source any more: the run ALERTS once a day and exits BEFORE it
# rewrites anything under state/cost/, so every dashboard keeps the last good
# numbers (stale but true) and the rollup's staleness checks page on their age.
# A fleet total built from the hub's own files alone would be a smaller number
# that reads as a cheaper fleet.
# >>> fleet row union
# (tests/rollup-from-rows-test.sh extracts this block VERBATIM and runs it —
# grepping a script for four strings proves it contains them, not that it
# produces the right file, and the double count below was green under exactly
# that kind of assertion.)
#
# cost_rollup_hash_lines [file...] — one sha256 per DATA line of each file (or
# of stdin), computed byte for byte the way the push side computes `row_hash`:
# bin/jobs-client.sh's _metric_cost_rows_chunk and bin/lib/cost-row.sh's
# _cost_row_emit_body both hash `line.rstrip("\r\n")` with the same codec and
# error handler. A third rendering of that hash would silently stop matching and
# the skip set below would quietly do nothing, so it stays this literal.
# Paths only, never stdin: the program itself arrives on stdin (`python3 -`), so
# a piped-in file would be read as part of the source and silently produce no
# hashes — a skip set that is empty is a guard that does nothing.  A path that
# does not exist (an unmatched glob) is skipped, which is what an empty
# builds/ looks like.
cost_rollup_hash_lines() {
  python3 - "$@" <<'PYHASH'
import hashlib, sys

for path in sys.argv[1:]:
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                raw = line.rstrip("\r\n")
                if not raw.strip() or raw.startswith("ts,host,"):
                    continue
                print(hashlib.sha256(raw.encode("utf-8", "replace")).hexdigest())
    except OSError:
        pass
PYHASH
}
TMP=$(mktemp -d)
cp "$H/logs/cost.csv" "$TMP/hub.csv" 2>/dev/null || true
# shellcheck source=bin/lib/cost-rows-read.sh
for _P in "$(dirname "$0")/lib/cost-rows-read.sh" "$H/bin/lib/cost-rows-read.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# Other boxes' build ledgers are NOT mirrored (BH-2527). Their rows are in the
# table already (every build-dir row is also a logs/cost.csv row the box pushes,
# and a pool machine's rows are pushed before its reap), each one carrying the
# build dir it belongs to in `run_id`, which is what the per-PR attribution
# below groups them by.
ROWS_FROM_DB=0
if command -v cost_rows_fetch >/dev/null 2>&1 && cost_rows_db_enabled; then
  # THE TWO COPIES ARE ONE CALL, AND `sort -u` CANNOT SEE THAT (BH-1032 review).
  # Every row below also exists as a line in a file this rollup already holds:
  # hub.csv, the hub's own build ledgers, the mirrored remote ones. `sort -u`
  # collapses them only when the TEXT matches — and a row the table has held
  # since 2026-09-02 has no `raw`, so it comes back RECONSTRUCTED from typed
  # columns: `1.250000` renders `1.25`, `0.000010` renders `1e-05`, and the
  # union keeps BOTH. That is one call counted twice in fleet-cost.csv,
  # cost-per-pr.csv and summary.json — a silently high number, which is the
  # exact shape of bug this lane exists to delete.
  #
  # So the file lines are hashed the way the push side hashes them (sha256 of
  # the verbatim line, bin/jobs-client.sh's _metric_cost_rows_chunk) and handed
  # to the reader as a skip set: a table row whose row_hash is already in a file
  # is not emitted. Exact — the hash IS the table's PK half, no formatting
  # guesswork — and the FILE's text wins. Rows the files do NOT carry (every
  # other box, a pool machine that died before its reap) come through from the
  # table.
  # The SAME two sources the union below reads, in one call. An unmatched
  # glob reaches the helper as a path that does not exist and is skipped.
  cost_rollup_hash_lines "$TMP/hub.csv" "$H"/builds/*/cost.csv \
    > "$TMP/file-hashes" 2>/dev/null || : > "$TMP/file-hashes"
  # The window is the widest any consumer of fleet-cost.csv asks for (30d) plus
  # a day of slack, so a row that arrived late still lands in the file the 30d
  # aggregate is taken over.
  DB_SINCE=$(date -u -d "${COST_ROLLUP_DB_DAYS:-31} days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || DB_SINCE=""
  if COST_ROWS_SKIP_HASHES="$TMP/file-hashes" cost_rows_fetch "$TMP/db.csv" "$DB_SINCE"; then
    ROWS_FROM_DB=1
    echo "$(STAMP) cost-rollup: collected $(( $(wc -l < "$TMP/db.csv") - 1 )) rows from cost_rows since ${DB_SINCE:-the beginning} that the files did not already carry ($(wc -l < "$TMP/file-hashes" | tr -d " ") file rows hashed) — no ssh" >> "$H/logs/agent-rules.log"
    # Kept past $TMP so section 1c can name the boxes the table is NOT hearing
    # from, and so an operator can read the same table by hand.
    # rm BEFORE the cp: a cp that fails while yesterday's file is still there
    # leaves 1c judging today's fleet against yesterday's answer, and a box that
    # stopped pushing this morning reads as present. No file is a fact 1c can
    # act on (it skips); a stale file is one it cannot.
    rm -f "$CD/cost-rows-boxes.tsv"
    cp "$TMP/db.csv.boxes" "$CD/cost-rows-boxes.tsv" 2>/dev/null || true
  fi
fi
if [ "$ROWS_FROM_DB" = 0 ]; then
  # NOTHING UNDER state/cost/ HAS BEEN WRITTEN YET, and nothing will be: the
  # last good run's files stay exactly as they are. One ALERT a day, because
  # every hourly tick of an outage would otherwise say the same thing.
  echo "$(STAMP) cost-rollup: cost_rows was unreadable or disarmed — no fleet rows, state/cost/ left as the last good run wrote it" >> "$H/logs/agent-rules.log"
  UFLAG="$H/flags/alerted-cost-rollup-db-unreadable-$(date -u +%Y%m%d)"
  if [ ! -f "$UFLAG" ]; then
    mkdir -p "$H/flags" 2>/dev/null && touch "$UFLAG" 2>/dev/null
    HARNESS="$H" "$H/bin/alert-line.sh" "[cost-rollup] cost_rows is unreadable (or COST_ROWS_FROM_DB / flags/cost-rows-from-db-off disarmed the read), so the rollup did not run: state/cost/ (summary.json, fleet-cost.csv, cost-per-pr.csv) still holds the last good run and every dashboard dollar figure is aging. The reason is in logs/agent-rules.log [cost-rows-read]; check the harness-jobs worker and run bin/cost-rows-push.sh --verify <box>."
  fi
  rm -rf "$TMP" "$BOR_TSV"
  exit 0
fi
# CANONICAL header, unconditionally. Taking it from hub.csv meant that while the
# hub still carried a 13-column file, every box's 14-field rows were read under
# a 13-column header and their billing_mode vanished into the restkey.
#
# It is the FULL header (2026-09-14), not the 14 columns it used to name: this
# file is read with csv.DictReader, and a name the header omits is not an empty
# field, it is a value parked in the restkey where nothing looks for it — which
# is how auth_account was invisible to every fleet-level reader here while
# agent-call.sh had been writing it since #173. The rows that are SHORT (a box
# whose header upgrade has not run) read the trailing names as None, and every
# reader below already goes through `.get(k) or 0` / `or ""`.
echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp" > "$CD/fleet-cost.csv"
{ tail -q -n +2 "$TMP"/*.csv 2>/dev/null
  cat "$H"/builds/*/cost.csv 2>/dev/null | grep -v "^ts,host"
} | sort -u >> "$CD/fleet-cost.csv"
rm -rf "$TMP"
# <<< fleet row union

# ── 1a. Reviews paid twice on an unchanged head (BH-3930) ────────────────────
# Every run, the hourly one too: summary.json is rewritten whole each time, so a
# key computed only daily would vanish 23 hours a day. A failed metric is an
# {"error": ...} object, never a zero-filled one; the daily block below turns it
# into ONE ALERTS line and never into a resolve.
# (tests/review-paid-unchanged.bh-3930-test.sh runs this block verbatim.)
# >>> review paid unchanged (BH-3930)
RPU_F="$CD/.review-paid-unchanged.json"; RPU_ERR=""
if [ ! -x "$H/bin/review-paid-unchanged.sh" ]; then
  RPU_ERR="bin/review-paid-unchanged.sh is not installed on this box"
  jq -nc --arg e "$RPU_ERR" '{error:$e}' > "$RPU_F.tmp"
elif ! "$H/bin/review-paid-unchanged.sh" "$CD/fleet-cost.csv" 7 "$(date -u +%s)" > "$RPU_F.tmp" 2> "$RPU_F.err"; then
  RPU_ERR=$(head -1 "$RPU_F.err"); [ -n "$RPU_ERR" ] || RPU_ERR="exited non-zero with no message"
  jq -nc --arg e "$RPU_ERR" '{error:$e}' > "$RPU_F.tmp"
fi
mv -f "$RPU_F.tmp" "$RPU_F"; rm -f "$RPU_F.err"
# <<< review paid unchanged

# ── 1b. Collect every box's extra-usage meter ────────────────────────────────
# One account per box: the meter of the box's DEFAULT login, read from the
# harness-jobs `extra_usage_snapshots` table (bin/lib/extra-usage-read.sh,
# BH-2527) under the label that login posts as. Boxes whose meter cannot be
# read, or that have none, are NOT silently zero: their file simply does not
# appear, and the aggregation below names them rather than summing them as $0.
#
# The box ids here are the cron/*.cron basenames, and a test asserts the two
# sets are equal in BOTH directions -- a box with a cron but no collection line
# writes a meter nobody reads, and a collection line with no cron waits forever
# for a file that is never written. Since BH-5747 the ids come from fleet.conf
# (bin/fleet-conf.sh --box-ids), the same registry the crons are rendered from,
# so a new box is collected with no edit here.
OD="$CD/overage"; mkdir -p "$OD"; rm -f "$OD"/*.csv "$OD/EXPECTED"
# The EXPECTED manifest is written by this same loop, so the aggregation below
# knows who SHOULD have reported without carrying a second copy of the box list.
# A box that is expected and absent gets NAMED; nothing missing is summed as $0.
echo hub >> "$OD/EXPECTED"
cp "$H/logs/extra-usage.csv" "$OD/hub.csv" 2>/dev/null || true
# These labels are the cron/*.cron basenames a parity test asserts against in
# both directions (tests/overage-per-box-test.sh runs the block below, and
# bin/box-lists-check.sh compares it with fleet.conf). Every box goes into
# EXPECTED whether or not its meter reads — "expected and absent" is the fact
# this loop exists to report, and dropping it from the manifest would turn a
# missing box into a silently smaller fleet.
for _P in "$(dirname "$0")/lib/extra-usage-read.sh" "$H/bin/lib/extra-usage-read.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# >>> overage boxes (BH-5747)
OVERAGE_BOXES=$("$(dirname "$0")/fleet-conf.sh" --box-ids 2>/dev/null | grep -vx hub || true)
# <<< overage boxes
[ -n "$OVERAGE_BOXES" ] || echo "$(STAMP) cost-rollup: fleet-conf.sh --box-ids named no box, so no box meter was collected this run" >> "$H/logs/agent-rules.log"
for EB in $OVERAGE_BOXES; do
  echo "$EB" >> "$OD/EXPECTED"
  if ! command -v extra_usage_fetch >/dev/null 2>&1; then
    echo "bin/lib/extra-usage-read.sh is missing on this box, so extra_usage_snapshots was not read" > "$OD/$EB.why"
    continue
  fi
  if ! extra_usage_fetch "$(extra_usage_label_for_box "$EB")" "$OD/$EB.csv"; then
    echo "extra_usage_snapshots unreadable from the harness-jobs worker" > "$OD/$EB.why"
    continue
  fi
  # The NAMED reason a box cannot report, from its newest poll. A login whose
  # token the usage endpoint refuses (status no-login) is a different fact from
  # a box that is simply quiet, and reporting both as absence is what made 8
  # inert trackers look like the one genuinely-absent box. A row from before
  # the status column existed (empty) is an ordinary poll.
  EST=$(awk -F, 'NR > 1 { st = $11; ts = $1 } END { if (st != "" && st != "ok") printf "latest poll status=%s at %s", st, ts }' "$OD/$EB.csv")
  [ -n "$EST" ] && echo "$EST" > "$OD/$EB.why"
  # A header and no rows is "never polled", which the aggregation names.
  [ "$(wc -l < "$OD/$EB.csv")" -gt 1 ] || rm -f "$OD/$EB.csv"
done

# ── 1c. Who is the cost TABLE hearing from? ──────────────────────────────────
# 1b names a box that was expected and did not report its METER. The same
# question has to be asked of cost_rows, because reading the table MOVED this
# lane's oldest failure mode rather than closing it: a box whose push lane is
# stuck — a frozen cursor, a missing HARNESS_SECRET, a \*/10 cron line that
# never landed — contributes zero rows, and a fleet file with no rows from it is
# indistinguishable from a box that spent nothing. "Unreachable reads as quiet",
# one layer in from the ssh sessions this slice deleted.
#
# THE EXPECTED SET IS 1b'S, not a new list. $OD/EXPECTED is written by the loop
# above, its labels are the cron/*.cron basenames, tests/cron-fleet-parity-test.sh
# holds those equal to the cron set in BOTH directions — and the ids cost_rows is
# keyed on are those same basenames (bin/lib/cost-row.sh's cost_row_box_id reads
# state/box-id, which bootstrap writes from cron_box_id_for; every cron push line
# passes the basename literally). A fifth hand-maintained fleet list here would
# be one edit away from lying about who is missing.
#
# TWO FACTS, TWO VOLUMES. Zero rows in the WHOLE window is unambiguous — no
# quiet box looks like that for 31 days — so it is an ALERT, once a day. Rows in
# the window but none in the last 24h is a LOG line: that is what a cursor that
# stopped yesterday looks like, and also what a genuinely idle box looks like,
# and paging a human for the second teaches them to ignore the first.
# >>> cost rows box presence
# -f, NOT -s, on the boxes file: an EMPTY one is the loudest fact this section
# has. cost_rows_fetch returns 0 on a window with no rows at all, so ROWS_FROM_DB
# is 1, and a 0-byte .boxes means not one box in the fleet pushed a row in 31
# days. Under -s that case skipped silently — the one shape that most deserves
# the absent-box ALERT was the one shape that could never raise it. The file's
# ABSENCE still skips: that is "we could not read" (disarmed, or a box without
# the reader), which section 1 already named.
if [ -f "$CD/cost-rows-boxes.tsv" ] && [ -s "$OD/EXPECTED" ]; then
  CUT24=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || CUT24=""
  SILENT=""; ABSENT=""
  while read -r EB; do
    [ -n "$EB" ] || continue
    ELAST=$(awk -F'\t' -v b="$EB" '$1==b{print $3; exit}' "$CD/cost-rows-boxes.tsv")
    if [ -z "$ELAST" ]; then ABSENT="$ABSENT $EB"; continue; fi
    if [ -n "$CUT24" ] && [ "$ELAST" \< "$CUT24" ]; then SILENT="$SILENT $EB(last $ELAST)"; fi
  done < "$OD/EXPECTED"
  [ -n "$SILENT" ] && echo "$(STAMP) cost-rollup: cost_rows carries nothing from the last 24h for:$SILENT — an idle box looks like this and so does a push lane that stopped; bin/cost-rows-push.sh --verify <box> tells them apart" >> "$H/logs/agent-rules.log"
  if [ -n "$ABSENT" ]; then
    PFLAG="$H/flags/alerted-cost-rows-absent-$(date -u +%Y%m%d)"
    if [ ! -f "$PFLAG" ]; then
      mkdir -p "$H/flags" 2>/dev/null && touch "$PFLAG" 2>/dev/null
      HARNESS="$H" "$H/bin/alert-line.sh" "[cost-rollup] cost_rows carries NO row at all for:$ABSENT — across the whole ${COST_ROLLUP_DB_DAYS:-31}-day window. Those boxes' spend is absent from fleet-cost.csv, summary.json and every \$/PR figure taken from them, and the file reads as if they were cheap rather than unheard. Run bin/cost-rows-push.sh --verify <box> on each (cursor, HARNESS_SECRET, the */10 cron line)."
    fi
  fi
fi
# <<< cost rows box presence

# ── 2. Roll up per PR + summarize ────────────────────────────────────────────
# stderr is CAPTURED, not discarded: when this block dies, the exception text is
# the only thing that says why, and cron sends the script's own stderr to
# /dev/null. Swallowing the vendor/interpreter error is how a crash becomes a
# blank line in a log.
# Refresh the repeat-family readout (and its state/repeat-family.json) BEFORE the
# rollup reads it, so summary.json never publishes yesterday's recurrence counts
# beside today's spend. One call: the script writes the file and prints the beat
# sentence, so the beat below and the JSON cannot word the same number twice.
# WHOSE PRs ARE OURS. Merged-PR throughput counts the harness author SET
# (bin/lib/gh-pr-list.sh, HARNESS_PR_AUTHORS), not one login: PRs opened on a
# GitHub App token are authored by the App, so a single-author search has
# under-counted throughput since bin/gh-token.sh went live (2026-09-14).
# shellcheck source=bin/lib/gh-pr-list.sh
for _P in "$(dirname "$0")/lib/gh-pr-list.sh" "$H/bin/lib/gh-pr-list.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# WHICH TOKEN CAN SEE THE REPO (2026-09-15). The author set answers "whose PRs
# are ours"; this answers "can this box count them at all". The hub's default
# PAT 404s on example-org/project-5, so every count taken with it came back an
# error that read as zero. Fail-open: an absent lib leaves the default token in
# place, exactly as before.
# shellcheck source=bin/lib/gh-repo-token.sh
for _P in "$(dirname "$0")/lib/gh-repo-token.sh" "$H/bin/lib/gh-repo-token.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# BH-4080: HARNESS_OPERATOR_LOGIN, the author fallback when gh-pr-list.sh is absent.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "$0")/lib/deployment.sh}" || exit 1
HARNESS_PR_AUTHORS_RESOLVED=$(command -v harness_pr_authors >/dev/null 2>&1 && harness_pr_authors)
export HARNESS_PR_AUTHORS_RESOLVED="${HARNESS_PR_AUTHORS_RESOLVED:-$HARNESS_OPERATOR_LOGIN}"

REPEAT_LINE=$("$H/bin/repeat-family.sh" --line 2>/dev/null) || REPEAT_LINE=""

# ── Merged-PR throughput, counted where the TOKEN can see it (2026-09-15) ────
# THE ZERO THAT WAS NOT A ZERO. This count used to be a `gh api search/issues`
# inside the python block, and its failure mode was the worst available one:
# the hub's default PAT cannot see example-org/project-5 (bin/lib/gh-repo-token.sh
# — the 10-hour project-5 loss), GitHub answers 422 with a JSON body, and
# `json.loads(...).get("total_count", 0)` read that error as ZERO MERGED PRs.
# project-5 shipped ~90 PRs on 2026-09-15 and summary.json said 0, which is
# also why cost_per_merged_pr_7d was null for the busiest repo in the fleet.
# A $/PR budget divides by this number; a silent zero would either divide by
# zero or, worse, read as "infinite $/PR" and page every half hour.
#
# So it moves into bash, where the token lib lives: each repo is asked with the
# token that can SEE it, and a count that could not be taken is the empty string
# — never 0. The python block below reads this file and keeps the two apart.
#
# TWO WINDOWS, BOTH BY MERGE DATE. 24h uses `merged:>=`, because the budget
# check divides 24h SPEND by the PRs that actually landed in those 24 hours, and
# a PR created yesterday and merged today belongs to today's throughput. 7d used
# `created:>=` until K1 (2026-09-24): a project that merged a PR opened nine
# days ago read as ZERO merged this week, which the zero-merge breaker in
# bin/pipeline-health.sh would pause. It is `merged:>=` now too.
# >>> merged pr counts
MERGED_TSV="$CD/merged-prs.tsv"
PR_AUTHOR_Q=$(for A in $HARNESS_PR_AUTHORS_RESOLVED; do printf 'author:%s+' "$A"; done)
PR_AUTHOR_Q="${PR_AUTHOR_Q%+}"
[ -n "$PR_AUTHOR_Q" ] || PR_AUTHOR_Q="author:$HARNESS_OPERATOR_LOGIN"
_merged_count() { # _merged_count <owner/repo> <qualifier> -> a number, or rc 1
  local slug="$1" qual="$2" out
  # </dev/null: this runs inside a `while read` over fleet.conf, and a child
  # that reads stdin eats the rest of the fleet.
  out=$(timeout 30 gh api "search/issues?q=repo:$slug+type:pr+$PR_AUTHOR_Q+is:merged+$qual" </dev/null 2>/dev/null) || return 1
  # `jq -e` is the whole point: an error body parses fine and has no
  # total_count, so .total_count is null and this returns rc 1 — unknown —
  # instead of the 0 that json.loads().get(...,0) used to hand back.
  printf '%s' "$out" | jq -e -r '.total_count' 2>/dev/null
}
CUT24=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
CUT7=$(date -u -d '7 days ago' '+%Y-%m-%d')
: > "$MERGED_TSV"
while read -r MP MSLUG _MREST; do
  case "$MP" in ''|\#*) continue ;; esac
  case "$MP" in *redirect*) continue ;; esac
  [ -n "$MSLUG" ] && [ "$MSLUG" != "-" ] || continue
  MTOK=default
  if type gh_repo_use_token >/dev/null 2>&1; then
    if gh_repo_use_token "$MSLUG" >/dev/null 2>&1; then
      MTOK=$(gh_repo_token_for "$MSLUG" 2>/dev/null || echo default)
    else
      MTOK=none
    fi
  fi
  M7=$(_merged_count "$MSLUG" "merged:>=$CUT7") || M7=""
  M24=$(_merged_count "$MSLUG" "merged:>=$CUT24") || M24=""
  type gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  printf '%s\t%s\t%s\t%s\n' "$MP" "$M7" "$M24" "$MTOK" >> "$MERGED_TSV"
done < "$H/fleet.conf"
# <<< merged pr counts

# >>> live cost block (BH-3481.2)
# What running sessions are spending right now, from GET /api/cost/live. A read
# that fails, 404s (route not deployed), or answers the wrong shape leaves the
# file empty, and python writes live = {"unreadable": true}: never zeros.
LIVE_F=$(mktemp)
if command -v _jobs_req >/dev/null 2>&1 \
   && _jobs_req GET "/api/cost/live?hours=24" > "$LIVE_F" 2>/dev/null \
   && jq -e '(.rows|type=="array") and (.truncated|type=="boolean")
             and ((.in_flight_usd|type)=="number" or .in_flight_usd==null)
             and (.unsettled_usd|type=="number")' "$LIVE_F" >/dev/null 2>&1; then :
else
  echo "$(STAMP) cost-rollup: /api/cost/live unreadable (http=${JOBS_HTTP:-none}) — summary.json live block marked unreadable, not zero" >> "$H/logs/agent-rules.log"
  : > "$LIVE_F"
fi
# <<< live cost block

# ── Final-bill dedup ledger: rows, not stamped.json (BH-4158) ───────────────
# "Has this PR had its Final AI bill comment?" is the ledgers row
# cost-final-bill/<PR URL>: pending = claimed, outcome unknown; stamped = gh
# answered rc 0; retry = the comment failed, bill it again. pending and stamped
# both count as done, so a crash between claim and comment is a missed bill,
# never a second client-visible comment.
#
# The legacy state/cost/stamped.json drains into rows here, COST_STAMP_IMPORT_CHUNK
# entries a run (a transport bound, D21), each one dropped from the file only
# after its PUT landed; the file goes when it is empty. Until then python reads
# it too, so an unimported entry is never billed. The first import copies the
# whole file to logs/ as the audit snapshot.
#
# The nightly run reads the whole kind through the lossless cursor into
# FB_KEYS. A failed or wrong-shape page, or the page ceiling, is FB_UNKNOWN=1:
# a partial set read as complete would re-bill every PR past the gap, so an
# unknown set bills nothing this run.
# >>> final bill ledger (BH-4158)
FB_KEYS=$(mktemp); FB_RETRY=$(mktemp); FB_UNKNOWN=0
if [ -f "$CD/stamped.json" ]; then
  ls "$H"/logs/cost-stamped-legacy-*.json >/dev/null 2>&1 \
    || cp "$CD/stamped.json" "$H/logs/cost-stamped-legacy-$(date -u +%Y%m%d).json" 2>/dev/null
  FB_CHUNK="${COST_STAMP_IMPORT_CHUNK:-200}"
  case "$FB_CHUNK" in ''|*[!0-9]*|0) FB_CHUNK=200 ;; esac
  FB_IMP=0; FB_STOP=""
  if ! FB_ROWS=$(jq -er --argjson n "$FB_CHUNK" 'to_entries[:$n][] | [.key, (.value|tostring)] | @tsv' "$CD/stamped.json" 2>/dev/null) \
     && ! jq -e 'type == "object" and length == 0' "$CD/stamped.json" >/dev/null 2>&1; then
    FB_STOP=", stopped: stamped.json unparseable, left in place"
  elif ! command -v job_ledger_put >/dev/null 2>&1; then
    FB_STOP=", stopped: ledger unreachable"
  else
    while IFS=$'\t' read -r FB_K FB_V <&3; do
      [ -n "$FB_K" ] || continue
      if job_ledger_put cost-final-bill "$FB_K" stamped "$FB_V"; then
        FB_IMP=$((FB_IMP + 1))
      else
        FB_STOP=", stopped: ledger unreachable"; break
      fi
    done 3<<<"$FB_ROWS"
  fi
  if [ "$FB_IMP" -gt 0 ]; then
    jq --argjson n "$FB_IMP" 'to_entries[$n:] | from_entries' "$CD/stamped.json" > "$CD/stamped.json.tmp" \
      && mv -f "$CD/stamped.json.tmp" "$CD/stamped.json"
  fi
  jq -e 'type == "object" and length == 0' "$CD/stamped.json" >/dev/null 2>&1 && rm -f "$CD/stamped.json"
  FB_LEFT=0
  [ -f "$CD/stamped.json" ] && FB_LEFT=$(jq -r 'length' "$CD/stamped.json" 2>/dev/null || echo '?')
  echo "$(STAMP) cost-rollup: final-bill import: $FB_IMP imported, $FB_LEFT remaining$FB_STOP" >> "$H/logs/agent-rules.log"
fi
if [ "${WINDOWS_ONLY:-0}" != 1 ]; then
  FB_B=""; FB_BK=""; FB_PG=0
  if ! command -v ledger_page >/dev/null 2>&1; then
    FB_UNKNOWN=1
  else
    while :; do
      FB_PG=$((FB_PG + 1))
      [ "$FB_PG" -le 50 ] || { FB_UNKNOWN=1; break; }
      FB_OUT=$(ledger_page cost-final-bill 1000 "$FB_B" "$FB_BK") || { FB_UNKNOWN=1; break; }
      FB_N=$(printf '%s' "$FB_OUT" | jq -er '.ledgers | if type == "array" then length else error end' 2>/dev/null) \
        || { FB_UNKNOWN=1; break; }
      printf '%s' "$FB_OUT" | jq -r '.ledgers[] | select(.status != "retry") | .key' >> "$FB_KEYS" 2>/dev/null \
        || { FB_UNKNOWN=1; break; }
      # Retry rows with their detail ("attempt <n> <ts>"): python counts attempts.
      printf '%s' "$FB_OUT" | jq -r '.ledgers[] | select(.status == "retry") | [.key, (.detail // "")] | @tsv' >> "$FB_RETRY" 2>/dev/null \
        || { FB_UNKNOWN=1; break; }
      [ "$FB_N" -ge 1000 ] || break
      FB_B=$(printf '%s' "$FB_OUT" | jq -r '.ledgers[-1].updated_at // empty')
      FB_BK=$(printf '%s' "$FB_OUT" | jq -r '.ledgers[-1].key // empty')
      [ -n "$FB_B" ] && [ -n "$FB_BK" ] || { FB_UNKNOWN=1; break; }
    done
  fi
  [ "$FB_UNKNOWN" = 1 ] && echo "$(STAMP) cost-rollup: final-bill ledger unreadable — no PR bills this run" >> "$H/logs/agent-rules.log"
fi
# Python's claim and stamp go through a child bin/jobs-client.sh. The client
# sets JOBS_URL as a plain shell variable, and a child that inherits an
# exported secret skips the env-file read, so it would answer "not configured".
[ -n "${HARNESS_SECRET:-}" ] && export HARNESS_SECRET
[ -n "${JOBS_URL+set}" ] && export JOBS_URL
[ -n "${JOBS_BOX+set}" ] && export JOBS_BOX
# <<< final bill ledger (BH-4158)

PYERR=$(mktemp)
COST_ROLLUP_BOR_TSV="$BOR_TSV" COST_ROLLUP_LIVE="$LIVE_F" COST_ROLLUP_RPU="$RPU_F" COST_STAMPED_KEYS="$FB_KEYS" COST_RETRY_ROWS="$FB_RETRY" COST_STAMPED_UNKNOWN="$FB_UNKNOWN" python3 - "$H" "$CD" 2>"$PYERR" <<'PY'
import csv, json, glob, os, re, sys, datetime, subprocess
H, CD = sys.argv[1], sys.argv[2]
now = datetime.datetime.utcnow()

def _prices_path():
    """The live table the daily refresh writes, else the committed fallback.

    BH-628 moved bin/update-model-prices.sh's output out of the git checkout and
    into $HARNESS/state/model-prices.json, because writing into a tracked file
    on a cron left the hub's checkout dirty and harness-sync refuses to deploy a
    dirty checkout. The checkout's catalog stays the committed fallback, so this
    resolves state first and changes nothing on a box that has no state file.
    """
    for p in (os.path.join(H, "state", "model-prices.json"),
              "/root/harness-checkout/catalog/model-prices.json",
              os.path.join(H, "catalog", "model-prices.json")):
        if os.path.exists(p):
            return p
    return ""

prices = {}
try:
    pt = json.load(open(_prices_path()))["per_token"]
    prices = {k: v for k, v in pt.items()}
except Exception:
    pass

def row_cost(r):
    c = r.get("cost_usd", "")
    try:
        if c not in ("", "0", "0.0", None) and float(c) > 0:
            return float(c)
    except ValueError:
        pass
    p = prices.get(r.get("model", ""), None)
    if not p:
        return 0.0
    def n(x):
        try: return float(x or 0)
        except ValueError: return 0.0
    # THE CACHE-WRITE RATE FOLLOWS THE TTL THE ROW SAYS WAS USED (P1). The
    # table's `cache_write` is the 5-minute (1.25x prompt) rate; a row whose
    # note carries cache_ttl=1h — observed by bin/agent-call.sh from the CLI
    # envelope's ephemeral_1h split — wrote at the 1-hour rate: the row's
    # `cache_write_1h` when the table has one, else 2x the prompt rate, the
    # derivation bin/lib/cost-row.sh's cost_price_tokens and
    # bin/transcript-cost.sh use. No tag, 5m or mixed = the 5-minute rate, as
    # before.
    cw_rate = p.get("cache_write") or 0
    # Plain string test, not `re`: tests extract this function into a module
    # that imports only csv/json/datetime/sys.
    if ";cache_ttl=1h;" in ";" + (r.get("note") or "") + ";":
        c1 = p.get("cache_write_1h")
        if isinstance(c1, (int, float)) and not isinstance(c1, bool):
            cw_rate = c1
        elif p.get("prompt"):
            cw_rate = p["prompt"] * 2.0
        else:
            cw_rate = cw_rate * 1.6
    total = (n(r.get("input_toks")) * (p.get("prompt") or 0)
             + n(r.get("output_toks")) * (p.get("completion") or 0)
             + n(r.get("cache_read")) * (p.get("cache_read") or 0)
             + n(r.get("cache_write")) * cw_rate)
    # THE PRICE CLIFF (BH-656). xAI bills the WHOLE request at 2x once it
    # exceeds 200,000 tokens, so every audit this file has ever produced
    # under-stated grok on the majority of the alert-triage lane's calls. The
    # cliff is data in the price table (`cliff_tokens`), the unit is
    # input + cache_read, and the comparison is STRICTLY greater — xAI's word is
    # "exceeding". Token-repricing branch only: a vendor-reported cost_usd
    # returned above is already the doubled figure and must never be doubled
    # again. `True` is an int in python and would read as a 1-token cliff, so
    # bools are excluded explicitly.
    cliff = p.get("cliff_tokens")
    if (isinstance(cliff, (int, float)) and not isinstance(cliff, bool) and cliff > 0
            and n(r.get("input_toks")) + n(r.get("cache_read")) > cliff):
        total *= 2
    return total

# per-build exact attribution — hub dirs from their cost.csv, every other box's
# builds from the table rows' run_id (BH-2527)
# THE LEDGER BINDS A BUILD DIR TO ITS PR (BH-2351). The shell's ledger pr
# binding block wrote bor_list's rows here: key, build_dir, box, updated_at,
# result_line, pr_url (or -), job_id. The PR is the pr_url column, else a URL in
# result_line. A dir the ledger names with neither is bound to None: the ledger
# is the record for that dir, so its RESULT file is not read either. No file (a
# caller that never set the variable) is an empty map, i.e. RESULT for every dir.
PR_RE = r"https://github\.com/\S+/pull/\d+"
bind = {}
try:
    with open(os.environ.get("COST_ROLLUP_BOR_TSV") or os.devnull, errors="replace") as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) < 6 or not f[1]:
                continue
            m = re.search(PR_RE, f[5]) or re.search(PR_RE, f[4])
            bind[f[1]] = m.group(0) if m else None
except OSError:
    pass

per_pr = {}
# The ledger's build_dir has the hub's pool-/fly- copy prefix stripped
# (bin/lib/builds-of-record.sh), so a dir name or run_id is stripped the same way.
def bare(n):
    return re.sub(r"^fly-", "", re.sub(r"^pool-", "", os.path.basename(n or "")))

def ni(x):
    try: return int(float(x or 0))
    except ValueError: return 0

def attribute(pr, dirname, rows):
    e = per_pr.setdefault(pr, {"pr": pr, "dirs": set(), "total": 0.0, "stages": {},
                               "in": 0, "out": 0, "cr": 0, "cw": 0, "accts": {}})
    for k, v in (("fly", 0.0), ("fly_s", 0), ("fly_n", 0), ("fly_unpriced", 0), ("tstages", {})):
        e.setdefault(k, v)
    e["dirs"].add(dirname)
    for r in rows:
        c = row_cost(r)
        e["total"] += c
        e["stages"][r.get("stage", "?")] = e["stages"].get(r.get("stage", "?"), 0.0) + c
        # FLY MACHINE TIME (BH-4021). A runner=fly row is the reap's bill for
        # the pool machine: in the total and stage_breakdown, but not AI
        # tokens and not paid by an Anthropic account, so it stays out of the
        # payer split and the token columns. An unpriced row (no machine size)
        # is counted, never shown as $0.
        if (r.get("runner") or "") == "fly":
            e["fly"] += c; e["fly_s"] += ni(r.get("duration_s")); e["fly_n"] += 1
            e["fly_unpriced"] += c == 0
            continue
        e["tstages"][r.get("stage", "?")] = e["tstages"].get(r.get("stage", "?"), 0.0) + c
        # WHICH ACCOUNT PAID (2026-09-02). auth_account is the 16th column
        # agent-call.sh has written since PR #173; a row from before it, or a
        # short row read under an upgraded header, has no label and counts as
        # "unknown" rather than vanishing from the breakdown.
        acct = (r.get("auth_account") or "").strip() or "unknown"
        e["accts"][acct] = e["accts"].get(acct, 0.0) + c
        # Survival-vendor rows (openrouter/fireworks) carry no Anthropic
        # prompt cache, so their raw input reads as "uncached" and poisons the
        # per-PR cache-hit rollup (TK-107: 21.9M uncached was mostly deepseek).
        # Their dollars stay in the total; their tokens stay out of the columns.
        if (r.get("runner") or "") in ("openrouter", "fireworks"):
            continue
        e["in"] += ni(r.get("input_toks")); e["out"] += ni(r.get("output_toks"))
        e["cr"] += ni(r.get("cache_read")); e["cw"] += ni(r.get("cache_write"))

hub_dirs = set()
for cc in glob.glob(f"{H}/builds/*/cost.csv"):
    d = os.path.dirname(cc)
    name = bare(d)
    hub_dirs.add(name)
    if name in bind:
        pr = bind[name]
        if not pr:
            continue
    else:
        res = os.path.join(d, "RESULT")
        if not os.path.exists(res):
            continue
        txt = open(res, errors="ignore").read()
        m = re.search(PR_RE, txt)
        if not m:
            continue
        pr = m.group(0)
    try:
        rows = list(csv.DictReader(open(cc)))
    except Exception:
        continue
    attribute(pr, os.path.basename(d), rows)

# EVERY OTHER BOX'S BUILDS, FROM THE TABLE (BH-2527). A remote build dir is no
# longer tarred over ssh; its rows are in fleet-cost.csv (read from cost_rows),
# each tagged with the build dir in run_id. They are grouped by that dir and
# bound ONLY through the ledger: the remote RESULT is not read, so a dir the
# ledger does not name is not attributed rather than guessed. A run_id that is
# a hub dir was billed above from its own cost.csv and is skipped here, and a
# row with no run_id belongs to no build (the same as before).
remote = {}
try:
    for r in csv.DictReader(open(f"{CD}/fleet-cost.csv")):
        name = bare(r.get("run_id"))
        if name and name not in hub_dirs:
            remote.setdefault(name, []).append(r)
except OSError:
    pass
for name, rows in remote.items():
    if bind.get(name):
        attribute(bind[name], name, rows)

with open(f"{CD}/cost-per-pr.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["pr_url", "cost_usd", "input_toks", "output_toks", "cache_read", "cache_write", "stage_breakdown", "build_dirs",
                "auth_account", "account_breakdown", "fly_usd"])
    for e in sorted(per_pr.values(), key=lambda x: -x["total"]):
        # auth_account is the DOMINANT label — the one carrying the largest
        # share of the PR's dollars — never "mixed": a bill needs a payer, and
        # account_breakdown beside it keeps the split honest. Ties break on the
        # label name so the file is stable across runs.
        accts = sorted(e["accts"].items(), key=lambda x: (-x[1], x[0])) or [("unknown", 0.0)]
        w.writerow([e["pr"], f'{e["total"]:.2f}', e["in"], e["out"], e["cr"], e["cw"],
                    ";".join(f"{k}:{v:.2f}" for k, v in sorted(e["stages"].items(), key=lambda x: -x[1])),
                    ";".join(sorted(e["dirs"])),
                    accts[0][0],
                    ";".join(f"{k}:{v:.2f}" for k, v in accts),
                    f'{e["fly"]:.2f}' if e["fly_n"] > e["fly_unpriced"] else ""])

# ── Final bill on the PR itself, once it is done (merged) ────────────────────
# One comment per PR, ever. Late work (fix rounds, re-reviews) tees into the
# same build dir, so the merge-time bill is complete.
# >>> final bill (BH-4158)
# The "already billed" set is the ledger keys the shell prefetched (every
# cost-final-bill row that is not `retry`) plus whatever the legacy
# stamped.json still holds; that file is only READ here, the shell drains it.
# Anything that makes the set uncertain bills nothing this run: a missed bill
# is a later night, a duplicate is a second comment on a client's PR.
done = set()
fb_unknown = os.environ.get("COST_STAMPED_UNKNOWN") == "1"
try:
    with open(os.environ["COST_STAMPED_KEYS"]) as fh:
        done.update(l.strip() for l in fh if l.strip())
except Exception:
    fb_unknown = True
try:
    with open(f"{CD}/stamped.json") as fh:
        done.update(json.load(fh).keys())
except FileNotFoundError:
    pass
except Exception:
    fb_unknown = True
dry = os.environ.get("STAMP_DRY") == "1"
# WINDOWS_ONLY=1 is the hourly window-refresh lane (cron :50): it recomputes
# the spend windows and re-pushes the snapshot so the 24h figure stays fresh,
# but PR-comment stamping stays a nightly-only write.
budget = 0 if os.environ.get("WINDOWS_ONLY") == "1" or fb_unknown else 30
fb_ts = now.isoformat() + "Z"
# A failed comment is retried on later nights, at most FB_MAX_ATTEMPTS times
# in all; then the row is `failed` (done for the prefetch) and one ALERTS line
# names the PR. Without the cap a PR whose comment always fails (archived
# repo, locked PR, lost token scope) holds one of the nightly slots forever.
# The count rides in the row's detail, "attempt <n> <ts>"; a retry row from
# before the count (detail is a bare timestamp) has had one attempt.
FB_MAX_ATTEMPTS = 3
fb_tries = {}
try:
    with open(os.environ.get("COST_RETRY_ROWS") or "/dev/null") as fh:
        for l in fh:
            k, _, d = l.rstrip("\n").partition("\t")
            w = d.split(" ")
            if k:
                fb_tries[k] = int(w[1]) if len(w) == 3 and w[0] == "attempt" and w[1].isdigit() else 1
except Exception:
    pass

def fb_put(pr, status, detail=None):
    try:
        return subprocess.run([f"{H}/bin/jobs-client.sh", "ledger-put", "cost-final-bill", pr, status, detail or fb_ts],
                              capture_output=True, text=True, timeout=60).returncode == 0
    except Exception:
        return False

for e in sorted(per_pr.values(), key=lambda x: -x["total"]):
    if e["pr"] in done or budget <= 0:
        continue
    budget -= 1
    try:
        st = subprocess.run(["gh", "pr", "view", e["pr"], "--json", "state", "-q", ".state"],
                            capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception:
        continue
    if st != "MERGED":
        continue
    stages = ", ".join(f"{k} ${v:.2f}" for k, v in sorted(e["tstages"].items(), key=lambda x: -x[1])) or "none"
    mins = round(e["fly_s"] / 60)
    if e["fly_n"] == 0:
        fly = "Fly machine time: not recorded for this PR (not a pool build, or built before BH-3989)"
    elif e["fly_unpriced"] == e["fly_n"]:
        fly = f"Fly machine time: {mins} min, not priced (machine size unknown)"
    else:
        fly = f"Fly machine time: ${e['fly']:.2f} ({mins} min)"
        if e["fly_unpriced"]:
            fly += f" (+{e['fly_unpriced']} unpriced segment(s))"
    body = (f"Final bill: **${e['total']:.2f}**. AI tokens: ${e['total'] - e['fly']:.2f} - "
            f"{e['in']/1000:.0f}k in / {e['out']/1000:.0f}k out "
            f"(cache: {e['cr']/1e6:.1f}M read, {e['cw']/1e6:.1f}M write). "
            f"Stages: {stages}. {fly}. API-list-equivalent pricing for tokens; Fly at "
            f"catalog/fly-prices.json list price; per-call rows in "
            f"{';'.join(sorted(e['dirs']))} on the build box.")
    if dry:
        print(f"DRY-STAMP {e['pr']}: {body}")
        continue
    # Claim BEFORE the send. No claim, no comment, and no later PR either: the
    # ledger that would remember them is not answering.
    if not fb_put(e["pr"], "pending"):
        with open(f"{H}/logs/agent-rules.log", "a") as fh:
            fh.write(f"{now:%Y-%m-%d %H:%M:%S}Z cost-rollup: final-bill claim for {e['pr']} NOT written — no more PR bills this run\n")
        break
    try:
        rc = subprocess.run(["gh", "pr", "comment", e["pr"], "--body", body],
                            capture_output=True, text=True, timeout=30).returncode
    except Exception:
        rc = None
    # A failed stamped/retry/failed put leaves the row pending: done, so never a duplicate.
    if rc == 0:
        fb_put(e["pr"], "stamped")
        continue
    n = fb_tries.get(e["pr"], 0) + 1
    if n < FB_MAX_ATTEMPTS:
        fb_put(e["pr"], "retry", f"attempt {n} {fb_ts}")
        continue
    fb_put(e["pr"], "failed", f"attempt {n} {fb_ts}")
    try:
        subprocess.run([f"{H}/bin/alert-line.sh",
                        f"[cost-rollup] the final-bill comment on {e['pr']} failed {n} times; no more attempts. "
                        f"The row is cost-final-bill/{e['pr']} status failed. Check the repo and token access, "
                        f"then post the bill by hand or delete the row to retry."],
                       env={**os.environ, "HARNESS": H}, capture_output=True, text=True, timeout=30)
    except Exception:
        pass
# <<< final bill (BH-4158)

# CASH vs NOTIONAL (2026-08-24). row_cost() is NOTIONAL — what the call would
# cost at retail, which is the right number for comparing lanes and the wrong
# number for "what did we spend". cash_of() answers the second question.
#
# A subscription row contributes $0 cash: the compute was already paid for by a
# flat fee, so counting it as spend inflated the fleet figure by ~$1,940/7d.
# A metered row contributes its full notional cost, because for those lanes
# retail IS the invoice.
METERED_VENDORS = {"openrouter", "fireworks"}
def billing_of(r):
    """The row's billing mode, including when the header lagged behind the rows.

    A 14-field row read under a 13-column header puts billing_mode into
    DictReader's restkey list, not the named field — so a row that DID report
    its mode reads as unclassifiable and prices at $0 cash. The header fix in
    agent-call.sh stops that happening going forward; this recovers it anyway,
    because a box whose header upgrade has not run yet must not silently zero.
    """
    b = (r.get("billing_mode") or "").strip()
    if b:
        return b
    extra = r.get(None)
    if isinstance(extra, list) and extra:
        cand = (extra[0] or "").strip()
        if cand in ("metered", "subscription", "unknown"):
            return cand
    return ""

def cash_of(r):
    b = billing_of(r)
    if b == "metered":
        return row_cost(r)
    if b in ("subscription",):
        return 0.0
    # No billing_mode: a row written before the column existed. Only the vendors
    # with NO subscription tier can be classified safely from the runner alone —
    # claude/codex/grok are genuinely ambiguous (the same runner is flat-rate on
    # one box and per-token on another), and guessing either way is worse than
    # counting it as unknown. Guessing subscription hides real cash; guessing
    # metered invents spend that was never billed.
    if r.get("runner", "") in METERED_VENDORS:
        return row_cost(r)
    return 0.0

def is_unknown_billing(r):
    b = billing_of(r)
    return b not in ("metered", "subscription") and r.get("runner", "") not in METERED_VENDORS

# project-level aggregates from the fleet file
def agg(days):
    cut = (now - datetime.timedelta(days=days)).isoformat()
    out = {}
    for r in csv.DictReader(open(f"{CD}/fleet-cost.csv")):
        if r["ts"] < cut:
            continue
        p = out.setdefault(r["project"], {"total": 0.0, "triage": 0.0, "build": 0.0, "product": 0.0, "calls": 0, "unpriced": 0, "cash": 0.0, "unknown_billing": 0, "stages": {}})
        c = row_cost(r)
        p["total"] += c; p["calls"] += 1
        p["cash"] += cash_of(r)
        if is_unknown_billing(r):
            p["unknown_billing"] += 1
        # A call the ledger cannot price (grok reports no tokens; unknown model)
        # must be COUNTED, not silently $0 — a lane billed off-ledger (xAI
        # wallet) would otherwise read as free.
        #
        # A REFUSED ROW IS NOT AN UNPRICED CALL (BH-1141). row_source=refused is
        # the gate's record of a call that never happened: its $0 is the answer,
        # not a gap in the price table. A disabled lane on a */2 cron would
        # otherwise add 720 "unpriced calls" a day to the very number the
        # cost-capture-parity rule watches, and train everyone to ignore it.
        # row_source=settled (BH-2604) is the triage no-signal settle's row: a
        # session not bought, so its $0 is the answer too. So is
        # row_source=unbilled (BH-3222): a canary that failed with no usage.
        if c == 0 and r.get("row_source", "") not in ("refused", "settled", "unbilled"):
            p["unpriced"] += 1
        p["stages"][r["stage"]] = p["stages"].get(r["stage"], 0.0) + c
        if r["stage"] == "triage":
            p["triage"] += c
        elif r["stage"] in ("plan", "execute", "review", "fix", "preplan", "decompose",
                            "execute-advisor", "fix-advisor"):
            p["build"] += c
        # Product-ideation machine (ideate/preplan-prd/mockup/signals/synth) is
        # PRODUCT spend, not PR-delivery spend (the operator 2026-08-19): it lives in
        # its own bucket and comes OUT of cost-per-PR, so a project running
        # ideation doesn't read as expensive at shipping tickets.
        if r["stage"] in ("ideate", "prd", "mockup", "signals", "synth"):
            p["product"] += c
    return out

def unpriced_pairs(days=1):
    """Which runner/model pairs are behind the rows the ledger could not price.

    unpriced_calls_24h has been a bare COUNT on the dashboard, and a count with
    no name on it is not actionable: twenty unpriced calls sat there for a week
    and paged nobody. Every row here is real spend that reads as $0.00, which is
    the same shape as the grok lane that burned ~$460 in two days while its cost
    column stayed blank — the parser looked correct and simply never matched.

    Two causes, and the fix differs: a model with NO price-table entry needs a
    row in catalog/model-prices.json, while a pair reporting NO TOKENS at all
    needs its runner to start capturing usage. So both are counted, and which
    one a pair is stays attached to it.

    BH-1361: a no-price-table pair also carries the SLUG to add. The map the
    daily refresh prices from is catalog/model-slugs.json now, so closing this
    alert is one data line — but only if someone knows which OpenRouter slug
    prices the model, which used to mean reading a 400-entry API list by hand.
    The refresh writes that list to state/openrouter-models.json; this is the
    best fuzzy match in it, or None. Never a guess dressed as an answer: below
    the cutoff the alert says <slug?> and points at the list.
    """
    _ids = []

    def _suggest(model):
        try:
            import os, difflib
            if not _ids:
                try:
                    with open(os.path.join(H, "state", "openrouter-models.json")) as fh:
                        _ids.append([i for i in (json.load(fh).get("ids") or [])
                                     if isinstance(i, str)])
                except Exception:
                    # state/ is hub-only and the file lands at 04:30Z, so a box
                    # without one is ordinary. Remembered as empty so a missing
                    # file is read once, not once per pair.
                    _ids.append([])
            ids = _ids[0]
            if not ids:
                return None
            if model in ids:
                return model
            def norm(s):
                return s.lower().replace(".", "-").rsplit("/", 1)[-1]
            target, best, ratio = norm(model), None, 0.0
            for i in ids:
                r = difflib.SequenceMatcher(None, target, norm(i)).ratio()
                if r > ratio:
                    best, ratio = i, r
            return best if ratio >= 0.6 else None
        except Exception:
            return None

    cut = (now - datetime.timedelta(days=days)).isoformat()
    out = {}
    for r in csv.DictReader(open(f"{CD}/fleet-cost.csv")):
        if r["ts"] < cut or row_cost(r) != 0:
            continue
        toks = 0
        for k in ("input_toks", "output_toks", "cache_read", "cache_write"):
            try:
                toks += int(float(r.get(k) or 0))
            except (TypeError, ValueError):
                pass
        # A call that FAILED WITHOUT CONSUMING TOKENS was never billed. Every
        # attempt appends a row, so a 429, a timeout or a failover lands here
        # with rc!=0, no tokens and no cost — unpriced because nothing happened,
        # not because the ledger cannot price it. Counting those fires this
        # alert on a bad afternoon at the vendor and sends someone to
        # model-prices.json to add a row for a model that is already there.
        # rc alone is not the test: a call that failed AFTER consuming tokens
        # was billed for them and still needs pricing.
        rcv = (r.get("rc") or "").strip()
        if toks == 0 and rcv not in ("", "0"):
            continue
        key = (r.get("runner") or "?", r.get("model") or "?")
        e = out.setdefault(key, {"calls": 0, "tokens": 0, "in_price_table": key[1] in prices})
        e["calls"] += 1
        e["tokens"] += toks
    return sorted(
        ({"runner": k[0], "model": k[1], "calls": v["calls"], "tokens": v["tokens"],
          "in_price_table": v["in_price_table"],
          # A priced model needs no slug: its row exists and the parse is the
          # problem, so naming a catalog line would send the fix to the wrong file.
          "suggested_slug": None if v["in_price_table"] else _suggest(k[1])}
         for k, v in out.items()),
        key=lambda x: (-x["calls"], x["runner"], x["model"]))

def ledger_unpriced_pairs(days=1):
    """The runner/model pairs whose billed rows the ledger STORED with no cost.

    BH-2306. unpriced_pairs() asks whether the ROLLUP can price a row, and
    row_cost() re-prices a blank cost_usd from its tokens, so a row stored blank
    for a model the catalog prices reads as priced there. D1 stores that row as
    NULL, and every D1 reader (the llm-spend caps, the Costs page) counts it as
    $0. Over 700 such rows on 2026-09-18..21 paged nobody. This keys on the
    stored value instead: blank cost_usd, not refused, and billed (the same
    never-billed rule and token sum as unpriced_pairs). `priceable` says whether
    the catalog could have priced it, which is what tells the call site failing
    apart from a missing catalog row. BH-2416: a zero-token row prices at $0
    whatever the catalog holds, so `in_catalog` says whether the price table has
    the model at all (the lookup row_cost makes) and `no_usage` counts the calls
    that reported no tokens; the alert uses them to send a known model with no
    usage to the runner's usage parse, not to the catalog. Runner and model are
    trimmed once here; the shell alert uses them verbatim as the seen-set key.
    """
    cut = (now - datetime.timedelta(days=days)).isoformat()
    out = {}
    for r in csv.DictReader(open(f"{CD}/fleet-cost.csv")):
        if r["ts"] < cut or (r.get("cost_usd") or "").strip() != "":
            continue
        if (r.get("row_source") or "").strip() in ("refused", "settled", "unbilled"):
            continue
        toks = 0
        for k in ("input_toks", "output_toks", "cache_read", "cache_write"):
            try:
                toks += int(float(r.get(k) or 0))
            except (TypeError, ValueError):
                pass
        if toks == 0 and (r.get("rc") or "").strip() not in ("", "0"):
            continue
        key = ((r.get("runner") or "").strip() or "?", (r.get("model") or "").strip() or "?")
        e = out.setdefault(key, {"calls": 0, "tokens": 0, "priceable": False,
                                 "in_catalog": bool(prices.get(key[1])), "no_usage": 0})
        e["calls"] += 1
        e["tokens"] += toks
        if toks == 0:
            e["no_usage"] += 1
        if row_cost(dict(r, model=key[1])) > 0:
            e["priceable"] = True
    return sorted(
        ({"runner": k[0], "model": k[1], "calls": v["calls"], "tokens": v["tokens"],
          "priceable": v["priceable"], "in_catalog": v["in_catalog"],
          "no_usage": v["no_usage"]} for k, v in out.items()),
        key=lambda x: (-x["calls"], x["runner"], x["model"]))

# Real projects come from fleet.conf; everything else (alert-triage, bench,
# probes) rolls into "other" — named, never hidden: the first dry-run found
# $1k/7d of alert-triage spend invisible to every per-project view.
def fold_other(s, fleet):
    """Fold every non-fleet project into one named "other" bucket, in place.

    Sums whatever numeric fields the aggregate carries instead of a hardcoded
    list. The list version silently dropped "cash" and "unknown_billing" when
    the cash split added them, so a metered non-fleet lane contributed $0 to
    fleet cash and its untagged rows were invisible to the health count — the
    exact "invisible to every per-project view" failure this bucket exists to
    prevent, reintroduced one field at a time. Deriving the fields from the
    data makes the next added field carry through on its own.
    """
    other = {"stages": {}}
    for k in [k for k in s if k not in fleet]:
        v = s.pop(k)
        for f2, val in v.items():
            # Numeric only, as the docstring says. Without this a future
            # string-valued aggregate field raises TypeError HERE, before
            # json.dump — so the rollup produces no summary.json at all rather
            # than a degraded one, and every box's dashboard figure goes stale
            # fleet-wide. Latent today; the blast radius is what makes the
            # guard worth three characters.
            if f2 == "stages" or not isinstance(val, (int, float)) or isinstance(val, bool):
                continue
            other[f2] = other.get(f2, 0) + val
        for st, sc in v.get("stages", {}).items():
            other["stages"][st] = other["stages"].get(st, 0.0) + sc
    s["other"] = other
    return s

# Merged-PR throughput, as counted in bash above with the token that can SEE
# each repo. An EMPTY field is a count that could not be taken, and it stays
# None all the way to summary.json — never 0. The distinction is the whole
# reason that loop moved: a repo the token cannot see used to report zero
# merged PRs, which reads as "this project shipped nothing" on every screen and
# makes any $/PR figure either null or infinite.
# `merged = {}` stays its own line, spelled exactly like that: it is the upper
# anchor tests/unknown-billing-window-test.sh grabs the aggregation block up to
# (grab("def agg(days):", "merged = {}")), and folding it into a tuple assignment
# makes that extraction raise "substring not found" and fail all 14 assertions at
# once. Same load-bearing-ordering rule as the overage block further down.
merged = {}
merged_24h = {}
merged_token = {}
def _cnt(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return None
try:
    for line in open(f"{CD}/merged-prs.tsv"):
        f = line.rstrip("\n").split("\t")
        if not f or not f[0]:
            continue
        merged[f[0]] = _cnt(f[1] if len(f) > 1 else "")
        merged_24h[f[0]] = _cnt(f[2] if len(f) > 2 else "")
        merged_token[f[0]] = (f[3] if len(f) > 3 else "") or "default"
except FileNotFoundError:
    pass

# Goodhart pairing (2026-08-23): throughput never ships without its betrayal
# metric. reopen-metrics.sh (04:15Z, before this rollup) counts tickets that
# regressed from review/done — the "resolved tickets, doubled churn" failure
# mode. Surface it NEXT TO merged-PR throughput, never in a separate report.
reopen = {}
try:
    reopen = json.load(open(f"{H}/state/reopen-rate.json"))
except Exception:
    pass

# Same pairing, one loop further out: reopens ask whether a shipped TICKET held,
# repeat-families ask whether a mined RULE held. bin/repeat-family.sh wrote the
# file moments ago (the --line call above); an absent one loads as {} rather
# than raising, because a rollup that dies here takes summary.json — and every
# box's dashboard figure — with it.
# >>> repeat family json
repeat_families = {}
try:
    repeat_families = json.load(open(f"{H}/state/repeat-family.json"))
except Exception:
    pass
# <<< repeat family json

s1, s7, s30 = agg(1), agg(7), agg(30)
fleet = set(merged.keys())
for s in (s1, s7, s30):
    fold_other(s, fleet)
# ACCOUNT-LEVEL overage (logs/extra-usage.csv, hub-only). extra_used_usd is the
# real invoice meter: once the weekly subscription allowance is exhausted and
# extra usage is enabled, Claude calls bill CASH at API rates. No per-row signal
# can see this — the row looks identical either side of the threshold — so it is
# read from the account meter and attributed at FLEET level only.
#
# Deliberately NOT split per project. The meter is one number for the whole
# account; any per-project apportionment would be an invention dressed as data,
# and the whole point of this change is to stop presenting one kind of number as
# another. A project's cash figure stays honest at metered-lane spend, and the
# overage sits beside it at the fleet level where it is actually measured.
#
# Summed as POSITIVE DELTAS between consecutive samples rather than
# last-minus-first: the meter resets on the weekly boundary, and max-minus-min
# across a reset would report a negative or a wildly wrong number. A reset shows
# up as a negative step, which contributes zero.
def overage_delta(days):
    cut = (now - datetime.timedelta(days=days)).isoformat()
    try:
        rows = [r for r in csv.DictReader(open(f"{H}/logs/extra-usage.csv"))]
    except Exception:
        return None          # no meter on this box -> unknown, not zero
    prev, total, seen = None, 0.0, False
    for r in sorted(rows, key=lambda x: x.get("ts", "")):
        try: v = float(r.get("extra_used_usd") or 0)
        except ValueError: continue
        if r.get("ts", "") >= cut:
            seen = True
            if prev is not None and v > prev:
                total += v - prev
            elif prev is not None and v < prev:
                # A weekly reset. The drop itself is not spend, but whatever the
                # new week had already accumulated by this first post-reset
                # sample IS, and dropping it silently understates. Bounded by one
                # sampling interval either way; erring toward counting it.
                total += v
        prev = v
    return round(total, 2) if seen else None

# THE WEEKLY FIGURE IS READ ABSOLUTE, NOT AS A DELTA (2026-08-24).
#
# extra_used_usd is CUMULATIVE for the current weekly window — the tracker
# writes used_credits / 10^decimal_places straight from the account endpoint.
# So the latest sample IS the week's overage, and no arithmetic is needed to
# get it. overage_delta() above summed the movement BETWEEN samples, which
# measures only what accrued while the tracker happened to be running: it
# started ~90 minutes before the first rollup with the meter already at
# $18,835, and duly reported $4.33 against a real $18,863. Three orders of
# magnitude low, on the largest dollar figure in the system, and shaped like a
# healthy small number rather than a broken one.
#
# Reading it absolute also needs NO reset handling: the meter zeroes at the
# weekly boundary, so the latest value is "since the latest reset" by
# construction. That makes this simpler than the delta it replaces, not more
# complex — the delta needed reset arithmetic precisely because it was
# reconstructing a total the meter already had.
#
# SCOPE, stated because it is a real limit: this watches ONE account, the
# hub's. Boxes with extra usage disabled cannot overage at all, but any OTHER
# account with it enabled is invisible here.
def read_overage_meter(path=None):
    """Absolute account-overage state from the latest meter sample.

    None when there is no meter to read — a missing meter and a quiet week are
    indistinguishable as numbers and must not read the same.
    """
    try:
        rows = [r for r in csv.DictReader(open(path or f"{H}/logs/extra-usage.csv"))]
    except Exception:
        return None
    good = []
    for r in sorted(rows, key=lambda x: x.get("ts", "")):
        try:
            float(r.get("extra_used_usd") or "")
        except (TypeError, ValueError):
            continue         # malformed row: skip it, never take the rollup down
        good.append(r)
    if not good:
        return None
    last = good[-1]
    resets = (last.get("weekly_resets_at") or "").strip()
    # THE POST-RESET BLIND WINDOW. The meter is cumulative since the weekly
    # reset, but the newest SAMPLE can predate the reset it names: a 03:58
    # sample stamped resets_at 04:00, read at 04:05, describes a window that
    # has ENDED. Reporting it hands over the whole previous week as "this
    # week", in the confident direction, and nothing contradicts it — every
    # row shares the stale stamp, so prior_window_excluded_usd stays null and
    # the block is self-consistently describing the wrong week.
    #
    # A window with no sample yet is the same class as a missing meter:
    # unknown, which is neither zero nor the last week's total. So the live
    # figure goes null and the dashboard's gate closes on it.
    #
    # An UNPARSEABLE stamp is a third case: freshness cannot be checked, but
    # blanking the whole cash line over a parse quirk would be a self-inflicted
    # outage. Report the number and mark it unverified.
    # NORMALISED TO NAIVE UTC before comparing. The tracker writes the
    # endpoint's own stamp, which is TZ-AWARE with an offset
    # ("2026-08-27T03:59:59.110228+00:00"), while `now` is naive utcnow().
    # Comparing the two raises TypeError, and this comparison sits outside the
    # ValueError guard below, so it killed the entire python block: no
    # summary.json written, the STALE one pushed, success logged.
    #
    # Deliberately NOT solved by making `now` aware. `now` is concatenated with
    # a literal "Z" in TWO places — generated_at (~line 457) and the
    # stamped.json values (~line 158) — so an aware value emits "...+00:00Z",
    # which is malformed. generated_at is what the dashboard's staleness fields
    # are derived from, so that one is load-bearing. Normalising the single
    # parsed value is the surgical fix.
    #
    # CORRECTED 2026-08-24: an earlier version of this comment gave a THIRD
    # reason — that the window cutoffs would silently widen, since they are
    # compared as strings against "Z"-suffixed row timestamps and "+" sorts
    # before "Z". That is FALSE, and it was settled by measurement rather than
    # by re-reading: 40,000 boundary-straddling rows plus constructed
    # exact-second ties give ZERO disagreements between a naive and an aware
    # cutoff. The fractional "." — or, at an exact second, the end of the
    # shorter string — always decides before the +-vs-Z ordinal can arbitrate.
    # The decision above stands on the two reasons that are real. Left in place
    # because a comment three PRs deep gets read as an established property,
    # and the next person to touch this deserves to know which claim was
    # checked and which was merely plausible.
    stale, verified = False, True
    try:
        rs = datetime.datetime.fromisoformat(resets.replace("Z", "+00:00")) if resets else None
        if rs is not None and rs.tzinfo is not None:
            rs = rs.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    except ValueError:
        rs = None
    if resets and rs is None:
        verified = False
    elif rs is not None and rs <= now:
        stale = True
    # Whatever the PREVIOUS window had reached before the reset. Reported, not
    # added: it belongs to a different billing window and part of it may fall
    # outside the 7d cost window entirely, so folding it in would overstate as
    # surely as the delta understated. Surfaced so the exclusion is visible
    # rather than silent.
    prior = None
    for r in reversed(good):
        if (r.get("weekly_resets_at") or "").strip() != resets:
            prior = round(float(r["extra_used_usd"]), 2)
            break
    def flag(k):
        return (last.get(k) or "").strip() in ("1", "true", "True")
    measured = round(float(last["extra_used_usd"]), 2)
    return {
        # None when the only sample describes a window that has already ended.
        "used_usd": None if stale else measured,
        "window_stale": stale,
        "window_verified": verified,
        # Kept, but demoted out of the live field: the reading stays
        # explainable instead of going mysteriously blank.
        "last_window_usd": measured if stale else None,
        "observed_at": last.get("ts", ""),
        "weekly_resets_at": resets,
        "extra_usage_enabled": flag("extra_enabled"),
        "in_overage": flag("in_overage"),
        # As observed: this means "a cap was HIT", not "a cap exists". The CSV
        # carries no limit value, so nothing downstream can honestly render
        # "no spend cap" from it.
        "spend_limit_reached": flag("spend_limit_reached"),
        # How far back the meter is actually observed. Any delta figure is
        # bounded by this, so publishing it is what stops a short tracking
        # history reading as a small bill.
        "tracking_since": good[0].get("ts", ""),
        "samples": len(good),
        "prior_window_excluded_usd": prior,
    }

# ── $/PR BY REPO AND BY THE ACCOUNT THAT PAID (2026-09-15) ───────────────────
# per_pr already knows both: the PR url names the repo, and accts names every
# account whose dollars went into that PR. Neither was ever published, so the
# console and the daily digest could show fleet spend per project but could not
# answer "which login is paying for this" without re-reading a 3MB CSV.
#
# THE WINDOW COMES FROM THE BUILD DIR. cost-per-pr.csv has no usable time column
# (docs/COST.md, "pr_costs has no usable time column"), so a PR is placed by the
# stamp on the build dir that produced it. A PR with no dated dir cannot be put
# in any window and is COUNTED in `undated` rather than quietly dropped into or
# out of the figure.
#
# AN ACCOUNT'S `prs` IS PRs IT CONTRIBUTED TO, not PRs it owns. A build that
# failed over from a subscription login to an API key bills both, so these
# counts sum to MORE than the number of PRs. Stated here because a reader adding
# the column up and getting the wrong total will otherwise assume the data is
# broken.
def _pr_stamp(e):
    st = [m for d in e["dirs"] for m in re.findall(r"(\d{12})", d)]
    return max(st) if st else None

def per_pr_grouped(days, key):
    """[{<key>, prs, cost_usd, cost_per_pr}], costliest first, plus undated count."""
    cut = (now - datetime.timedelta(days=days)).strftime("%Y%m%d%H%M")
    out, undated = {}, 0
    for e in per_pr.values():
        st = _pr_stamp(e)
        if st is None:
            undated += 1
            continue
        if st < cut:
            continue
        if key == "account":
            pairs = list(e["accts"].items())
        else:
            m = re.search(r"github\.com/[^/]+/([^/]+)/pull/", e["pr"])
            pairs = [(m.group(1), e["total"])] if m else []
        for k, c in pairs:
            r = out.setdefault(k, {"k": k, "prs": 0, "cost_usd": 0.0})
            r["prs"] += 1
            r["cost_usd"] += c
    rows = [{key: r["k"], "prs": r["prs"], "cost_usd": round(r["cost_usd"], 2),
             "cost_per_pr": round(r["cost_usd"] / r["prs"], 2) if r["prs"] else None}
            for r in sorted(out.values(), key=lambda x: -x["cost_usd"])]
    return rows, undated

summary = {"generated_at": now.isoformat() + "Z", "prices_updated": None, "projects": {}}
try:
    summary["prices_updated"] = json.load(open(_prices_path()))["updated_at"]
except Exception:
    pass
def project_row(a1, a7, a30, m, reopens, m24=None, tok="default"):
    """One project's summary entry, from its 24h / 7d / 30d aggregates.

    A function rather than an inline dict so a test can pin WHICH aggregate
    feeds which field. The units either side of this seam were covered while
    the seam itself was not, and the 24h/7d pair is where that matters most:
    if the 24h count silently became the 7d count, the caption would read
    "rows are STILL being written untagged" forever, inverting the signal the
    metric exists to give and sending someone after a sync problem that does
    not exist.
    """
    deliver7 = a7.get("total", 0) - a7.get("product", 0)
    # The 24h delivery figure the $/PR budget divides. Same definition as the 7d
    # one — product-ideation spend out, everything that goes into shipping a PR
    # in — so the budget in catalog/cost-caps.conf means the same thing on both
    # windows and a project cannot read cheap on one and expensive on the other.
    deliver1 = a1.get("total", 0) - a1.get("product", 0)
    return {
        # 24h is a true zero when the project logged no rows in the window —
        # measured-and-empty, unlike an unavailable project (absent entirely).
        "cost_24h": round(a1.get("total", 0), 2),
        "unpriced_calls_24h": a1.get("unpriced", 0),
        "cost_7d": round(a7.get("total", 0), 2), "cost_30d": round(a30.get("total", 0), 2),
        "product_7d": round(a7.get("product", 0), 2),
        "triage_share_7d": round(a7.get("triage", 0) / deliver7, 2) if deliver7 else None,
        "merged_prs_7d": m,
        # cost-per-PR is DELIVERY cost: product-ideation spend excluded
        "cost_per_merged_pr_7d": round(deliver7 / m, 2) if m else None,
        "stages_7d": {k: round(v, 2) for k, v in sorted(a7.get("stages", {}).items(), key=lambda x: -x[1])},
        "unpriced_calls_7d": a7.get("unpriced", 0),
        "build_per_merged_pr_7d": round(a7.get("build", 0) / m, 2) if m else None,
        "reopens_14d": reopens,
        # Cash = metered lanes only. A subscription-only project reads $0 here
        # and its real API-equivalent in cost_*; both are true, and they answer
        # different questions.
        "cash_cost_24h": round(a1.get("cash", 0), 2),
        "cash_cost_7d": round(a7.get("cash", 0), 2),
        "unknown_billing_calls_7d": a7.get("unknown_billing", 0),
        # The HEALTH number. See cash_note(): 7d alone cannot tell a clearing
        # legacy backlog from rows that are still landing untagged today.
        "unknown_billing_calls_24h": a1.get("unknown_billing", 0),
        # ── the $/PR budget inputs (2026-09-15) ──────────────────────────────
        # merged_prs_* is None when the count could NOT BE TAKEN — a repo this
        # box's token cannot see. None is not 0: bin/pipeline-health.sh skips
        # the rate check on None and names the project once a day, where a 0
        # would have made the rate infinite and paged every half hour.
        "delivery_cost_24h": round(deliver1, 2),
        # The 24h stage split, so the budget alert can name the three stages
        # that moved instead of saying "over budget" and sending someone to a
        # 3MB CSV. stages_7d has always been here; the alert is about a 24h
        # rate, and quoting a 7d breakdown beside a 24h number is how two true
        # figures make one wrong story.
        "stages_24h": {k: round(v, 2) for k, v in sorted(a1.get("stages", {}).items(), key=lambda x: -x[1])},
        "merged_prs_24h": m24,
        "cost_per_merged_pr_24h": round(deliver1 / m24, 2) if m24 else None,
        # Which token answered, so "unknown" carries its reason: `none` means no
        # token on this box can see the repo, `default`/`admin` means the search
        # itself failed (rate limit, weather) and the next hour may well succeed.
        "merged_prs_token": tok,
        "merged_prs_status": "ok" if (m is not None or m24 is not None) else "unknown",
    }

for p in sorted(set(list(s7) + list(s30))):
    summary["projects"][p] = project_row(
        s1.get(p, {}), s7.get(p, {}), s30.get(p, {}),
        merged.get(p), (reopen.get(p) or {}).get("reopens_14d"),
        merged_24h.get(p), merged_token.get(p, "default"))
# Fleet totals. cost_24h/cost_7d per project stay exactly as they were — the UI
# reads them and they remain NOTIONAL — and everything here is additive.
# $/PR two ways, published for the console's cost panel and the daily digest.
# By REPO answers "which product is expensive"; by ACCOUNT answers "which login
# is paying", and the second question had no answer anywhere until now.
for _w, _d in (("24h", 1), ("7d", 7)):
    _rows, _und = per_pr_grouped(_d, "repo")
    summary[f"cost_per_pr_by_repo_{_w}"] = _rows
    _rows, _ = per_pr_grouped(_d, "account")
    summary[f"cost_per_pr_by_account_{_w}"] = _rows
    summary[f"cost_per_pr_undated_{_w}"] = _und
summary["cost_per_pr_note"] = (
    "Attributed per-PR dollars: a PR is placed in the window by the stamp on the build dir "
    "that produced it, and cost_per_pr_undated_* counts the PRs with no dated dir, which are "
    "in no window at all. An account's `prs` counts PRs it CONTRIBUTED to, so the by-account "
    "counts sum to more than the number of PRs whenever a build billed two logins. These are "
    "NOT the same figure as projects[].cost_per_merged_pr_*, which divides a project's whole "
    "delivery spend (triage, abandoned builds, fix rounds) by its merged PRs and is the number "
    "catalog/cost-caps.conf budgets against.")
summary["fleet_notional_7d"] = round(sum(v.get("cost_7d", 0) or 0 for v in summary["projects"].values()), 2)
summary["fleet_cash_7d"] = round(sum(v.get("cash_cost_7d", 0) or 0 for v in summary["projects"].values()), 2)
summary["fleet_unknown_billing_calls_7d"] = sum(
    v.get("unknown_billing_calls_7d", 0) or 0 for v in summary["projects"].values())
summary["fleet_unknown_billing_calls_24h"] = sum(
    v.get("unknown_billing_calls_24h", 0) or 0 for v in summary["projects"].values())
# Fleet-wide unpriced calls, and the runner/model pairs behind them. Additive:
# the per-project unpriced_calls_* fields are untouched. The shell alert at the
# end of this script reads these two and is the reason they exist — a number on
# a dashboard nobody diffs is how twenty unpriced calls went a week unnoticed.
summary["fleet_unpriced_calls_24h"] = sum(
    v.get("unpriced_calls_24h", 0) or 0 for v in summary["projects"].values())
summary["fleet_unpriced_pairs_24h"] = unpriced_pairs(1)
# BH-2306: the pairs D1 holds as NULL, which the line above cannot see when the
# catalog prices the model. Read by the "new unpriced pair" alert below.
summary["fleet_ledger_unpriced_pairs_24h"] = ledger_unpriced_pairs(1)
# How many models the price table actually loaded. It is read from a hardcoded
# path inside a bare except, so a wrong path yields prices={} silently — and
# then EVERY token-bearing row in the fleet reads as unpriced with no price-table
# entry. Without this number the alert cannot tell "one new model needs a price
# row" from "the price table is gone", and it would name the whole fleet.
summary["prices_loaded"] = len(prices)
# Additive, fleet-level: recurrence is a property of a finding FAMILY, which
# crosses projects by construction, so it cannot sit in a project row.
summary["repeat_families"] = repeat_families
def runner_input_stats(days=7):
    """Per-runner input-token distribution — the number that settles WHERE the
    context is coming from.

    Keyed on CONTEXT per call (input_toks + cache_read), not input_toks alone.

    grok triage measured 620K mean / 3.7M max input tokens per call while the
    entire assembled triage prompt is under ~25K tokens (largest SOP 17KB,
    queue head -40, dirs head -20). A 25-150x gap means the tokens are NOT the
    prompt: they accumulate inside the agentic session, and the row's
    input_toks is that session's final cumulative figure.

    over_200k_share is the one that costs money directly: past 200K prompt
    tokens xAI bills the WHOLE request at double rate, so the share of calls
    over the cliff is a price multiplier, not a curiosity.

    ⚠️ UNIT MISMATCH, STATED. xAI's 200K is a PER-REQUEST prompt threshold, and
    input_toks is the session's CUMULATIVE figure across every request in the
    tool loop. So this share is "sessions whose cumulative prompt tokens passed
    200K", which is not the same question. A 25-turn session averaging 60K per
    request reads 1.5M cumulative and counts here, while no single request ever
    crossed the cliff. It errs in the SAFE direction — a session that really did
    cross is always counted, because a crossing request alone exceeds 200K — but
    a high share is "over the conservative bound", NEVER "confirmed doubled
    bills". Measuring the real thing needs per-request prompt tokens, which the
    fleet does not capture from any runner today.
    """
    cut = (now - datetime.timedelta(days=days)).isoformat()
    per = {}
    try:
        rows = list(csv.DictReader(open(f"{CD}/fleet-cost.csv")))
    except Exception:
        return {}
    for r in rows:
        if r.get("ts", "") < cut:
            continue
        # CONTEXT, not input_toks. For claude the context lives in cache_read
        # and input_toks reads ~57 fleet-wide, so a ceiling join on input_toks
        # compares 57 against an 80,000 ceiling and can never fire — a guard
        # that is inert for most of the manifest. input + cache_read is the
        # only figure comparable across runners.
        try:
            v = int(float(r.get("input_toks") or 0)) + int(float(r.get("cache_read") or 0))
        except ValueError:
            continue
        if v <= 0:
            continue        # unpriced/uncaptured rows would drag the mean to zero
        # KEYED ON (runner, stage, project). Runner alone collides: medic and
        # alert-triage are both claude/triage with very different jobs, so a
        # runner-keyed join judges every claude lane against the strictest
        # ceiling any claude lane declares — and reports a build lane
        # legitimately at 400K as a breach. A guard that fires when nothing is
        # wrong is the alarm that always rings, which this repo already paid to
        # learn once.
        key = (r.get("runner", "?"), r.get("stage", "?"), r.get("project", "?"))
        per.setdefault(key, []).append((v, int(float(r.get("input_toks") or 0))))
    out = {}
    for key, pairs in per.items():
        runner, stage, project = key
        vals = [c for c, _ in pairs]
        prompt_toks = [p for _, p in pairs]
        vals.sort()
        n = len(vals)
        row = {
            "runner": runner, "stage": stage, "project": project,
            "calls": n,
            "mean_input": int(sum(vals) / n),
            "p95_input": vals[min(n - 1, int(n * 0.95))],
            "max_input": vals[-1],
        }
        # THE CLIFF IS A GROK FACT, computed on PROMPT tokens alone. xAI doubles
        # the whole request past 200K PROMPT tokens; cache_read is not prompt,
        # and including it made a normal claude lane read 1.0 — "100% over a
        # cliff it does not have". Reported only where it means something.
        if runner == "grok":
            row["over_200k_share"] = round(sum(1 for t in prompt_toks if t > 200000) / n, 3)
            row["_cliff_basis"] = (
                "input_toks only (the xAI prompt cliff); mean_input is input+cache_read. "
                "CUMULATIVE, NOT PER-REQUEST: xAI's 200K is a per-request prompt threshold "
                "while input_toks is the session total across the tool loop, so this is a "
                "CONSERVATIVE bound — a real crossing is always counted, but a share above 0 "
                "means 'over the conservative bound', not 'confirmed doubled bills'.")
        out[f"{runner}/{stage}/{project}"] = row
    return out

def ceiling_breaches(stats):
    """Lanes running over their DECLARED ceiling, from catalog/context-budgets.json.

    This is what makes the manifest live rather than documentation. A declared
    budget nobody joins against actuals is a number in a file — which is the
    same shape as the config that could not reach its script and the column
    that was inert on every box.

    Returns (breaches, status). The SPLIT is the point: an empty list is
    "checked, all lanes within budget", and that is a different fact from
    "could not check". Returning [] for both made an unreadable manifest
    indistinguishable from a clean bill of health — the exact None-vs-0
    distinction this wave built three times elsewhere, violated inside the
    change that documents it. [] IS "all fine" to any consumer.

    The path is an env seam rather than a hardcoded absolute, because the
    hardcoded version could not be driven by any test — and an untestable path
    is where this class of bug lives. That is not incidental to the bug; it is
    why it survived.
    """
    import os
    path = os.environ.get("CONTEXT_BUDGETS",
                          "/root/harness-checkout/catalog/context-budgets.json")
    try:
        lanes = json.load(open(path))["lanes"]
    except Exception:
        return None, f"manifest unreadable at {path} — ceilings NOT checked"
    # A lane is judged against ITS OWN ceiling, matched on (runner, stage) plus
    # project where the lane pins one. The previous version took the strictest
    # ceiling for the whole runner, so medic's 80K governed every claude lane
    # and a build lane legitimately at 400K reported as a breach.
    # THE ONE RESOLVER. Whatever answers "is this over budget?" must be the same
    # code that answers "is this budgeted at all?" — two keys for one question
    # is how a row satisfies both by matching neither. Keyed on runner+stage
    # alone, completeness read "claude/triage exists" as budgeted while
    # ceiling_for returned None and exempted it: thousands of rows a week
    # invisible to both guards.
    #
    # A lane may leave `runner` or `project` unpinned, meaning "any". The MOST
    # SPECIFIC match wins, so pinning medic does not exempt every other
    # project's triage — the failure mode of narrowing a key without checking
    # what the narrowing now excludes.
    def ceiling_for(runner, stage, project):
        cands = []
        for l in lanes:
            if l.get("stage") != stage:
                continue
            if l.get("runner") not in (None, runner):
                continue
            if l.get("project") not in (None, project):
                continue
            if not isinstance(l.get("ceiling_tokens"), (int, float)):
                continue
            # PROJECT OUTWEIGHS RUNNER, deliberately. Equal weights make a
            # runner-only lane and a project-only lane both score 1, and the
            # tie then resolves by min(ceiling) — so the strictest lane
            # silently governs a workload it does not describe. That is #86's
            # false alarm one level up, arriving as a DEFAULT rather than a
            # decision: equal weights are a tie-break nobody designed.
            #
            # The asymmetry is real, not arbitrary. `project` identifies the
            # WORKLOAD — what this lane is doing and therefore what context it
            # legitimately needs. `runner` only names the executor, and the
            # same workload keeps its budget when the failover fires (which is
            # exactly why project-triage is runner-agnostic). So a lane pinned
            # to the workload always beats one pinned only to the machinery.
            spec = 2 * (1 if l.get("project") else 0) + (1 if l.get("runner") else 0)
            # PER-RUNNER CEILING, for a fact that really is about the executor:
            # past 200K prompt tokens xAI bills the WHOLE request at double
            # rate. That is not a property of the job, so it cannot live in the
            # job's ceiling — but it must still bind, because the failover
            # ladder is stage-agnostic (tiers 3/3b/4 fire for ANY stage, and
            # the orchestrator's own survival list is "codex grok"), so every
            # lane in this manifest is grok-reachable. A lane declares
            # runner_ceilings only where the executor changes the number.
            rc = (l.get("runner_ceilings") or {}).get(runner)
            cands.append((spec, rc if isinstance(rc, (int, float)) else l["ceiling_tokens"]))
        if not cands:
            return None
        best = max(s for s, _ in cands)
        return min(c for s, c in cands if s == best)

    out = []
    for key, st in (stats or {}).items():
        cap = ceiling_for(st.get("runner"), st.get("stage"), st.get("project"))
        # No matching lane means UNBUDGETED, which the manifest completeness
        # test catches separately — it is not a breach and must not be reported
        # as one.
        if cap and st.get("mean_input", 0) > cap:
            out.append(f"{key} mean {st['mean_input']} > its declared ceiling {int(cap)}")
    return out, "checked"

def overage_accounts():
    """Every box's account meter, keyed by box id, plus the fleet total.

    Extra usage is being enabled on project-2/project-3/project-4, which removes the error a
    cap hit used to raise: the call now BILLS instead of failing over, so
    nothing throws and the failover cascade never fires. This per-account view
    is what replaces that error as the signal, which is why a missing account
    must never read as $0 — a silent zero here is indistinguishable from a
    quiet week on an account that is actually burning.

    Summed: only meters that are BOTH present and freshness-verified. Anything
    else is named in the note. The Mac is deliberately not in this set (it
    bills a personal login and no box polls it) and the note says so, because
    "fleet total" invites the reading that it covers everything that spends.
    """
    accounts, missing, unsummed, unavailable = {}, [], [], {}
    try:
        expected = [l.strip() for l in open(f"{CD}/overage/EXPECTED") if l.strip()]
    except Exception:
        expected = []
    for box in expected:
        st = read_overage_meter(f"{CD}/overage/{box}.csv")
        if st is None:
            # NAMED where the box said why. "token lacks user:profile scope" is
            # a permanent capability gap; "unreachable" is transient; silence is
            # a third thing. Collapsing them into one absence is what this fix
            # exists to end.
            why = ""
            try:
                why = open(f"{CD}/overage/{box}.why").read().strip()
            except Exception:
                pass
            unavailable[box] = why or "no meter reported (unreachable, or never polled)"
            missing.append(box)
            continue
        accounts[box] = {
            "meter_usd": st["used_usd"],
            "enabled": st["extra_usage_enabled"],
            "in_overage": st["in_overage"],
            "resets_at": st["weekly_resets_at"],
            "window_verified": st["window_verified"],
            "observed_at": st["observed_at"],
            "tracking_since": st["tracking_since"],
        }
        if st["used_usd"] is None or not st["window_verified"]:
            unsummed.append(box)
    total = round(sum(a["meter_usd"] for a in accounts.values()
                      if a["meter_usd"] is not None and a["window_verified"]), 2)
    note = f"sum of {len(accounts) - len(unsummed)} verified account meter(s)"
    if missing:
        note += ("; NOT INCLUDED (no meter reported, could be unreachable or "
                 f"untracked — NOT zero): {', '.join(sorted(missing))}")
    if unsummed:
        note += ("; NOT INCLUDED (reported but the current window has no "
                 f"observation yet, or its reset stamp is unparseable): {', '.join(sorted(unsummed))}")
    note += ("; the Mac's own Claude usage is NOT in this figure — no box polls "
             "it, so fleet-wide spend is larger than this by an unmeasured amount")
    # Emitted so the dashboard can say WHY a box has no meter rather than
    # rendering it identically to a box that simply had a quiet week.
    for box, why in unavailable.items():
        accounts.setdefault(box, {})["meter_unavailable"] = why
    return accounts, total, note

def overage_fields(state, delta_24h):
    """The summary's overage block.

    A function so a test can pin WHICH source feeds cash_overage_7d. The unit
    (read_overage_meter) and the reading (cash_note) were both covered while
    wiring was not, and reverting just this line to overage_delta(7) restores
    the entire $18.8K-vs-$4.33 bug with every other test still green. Untested
    wiring between tested units is where this keeps hiding.
    """
    # A stale window nulls the STATE as well as the number: enabled/in_overage/
    # resets_at all describe the week that ended, and "in overage" carried over
    # from a closed window is a claim about right now that we cannot make.
    live = state if (state and not state.get("window_stale")) else None
    meter = live["used_usd"] if live else None
    return {
        # THE GATE FIELD. New name on purpose: the dashboard gates its whole
        # cash line on this being non-null, so a snapshot written by a pre-fix
        # rollup renders "measuring" instead of a plausible-looking wrong
        # dollar figure. Reusing an existing field would have made merge and
        # deploy order matter across three layers; a new field makes it
        # irrelevant in every ordering.
        "overage_meter_usd": meter,
        # The ACTIONABLE half, as one object. A number says how bad it got;
        # this says it is still happening. Key names are the published
        # contract the console already passes through — do not rename.
        "overage_state": ({
            "enabled": live["extra_usage_enabled"],
            "in_overage": live["in_overage"],
            "resets_at": live["weekly_resets_at"],
            # "a cap was HIT", NOT "a cap exists". The tracker carries no limit
            # value, so no consumer can honestly render "no spend cap" from
            # this field alone.
            "spend_limit_reached": live["spend_limit_reached"],
        } if live else None),
        # 24h stays a DELTA — "what accrued today" is a real question and the
        # meter's movement is the only way to answer it. It is bounded by how
        # long the tracker has been up, so overage_tracking_since ships beside
        # it; without that, a tracker started an hour ago reports a tiny number
        # that looks like a quiet day — the same bug the 7d figure just had.
        "cash_overage_24h": delta_24h,
        # BACK-COMPAT ALIAS of overage_meter_usd, derived from it in the same
        # breath rather than recomputed, so the two can never drift apart.
        # Existing consumers read this name; new ones should read the gate
        # field. It is the ABSOLUTE weekly meter, not a 7d delta — the weekly
        # window and the 7d cost window are the same LENGTH and not the same
        # WINDOW, which the note states rather than letting the name imply.
        "cash_overage_7d": meter,
        "overage_tracking_since": state["tracking_since"] if state else None,
        "overage_observed_at": state["observed_at"] if state else None,
        "overage_samples": state["samples"] if state else 0,
        "prior_window_excluded_usd": state["prior_window_excluded_usd"] if state else None,
    }

_ost = read_overage_meter()
# Kept AFTER the read_overage_meter() line: three test files anchor their
# function extraction on it, and inserting executable statements above it drags
# them into the extracted module. Ordering here is load-bearing for the suite,
# not for the logic.
_oacct, _ototal, _onote = overage_accounts()
summary["runner_input_stats_7d"] = runner_input_stats(7)
_breaches, _bstatus = ceiling_breaches(summary["runner_input_stats_7d"])
summary["context_ceiling_breaches"] = _breaches
summary["context_ceiling_check"] = _bstatus
summary["overage_accounts"] = _oacct
summary["fleet_overage_total_usd"] = _ototal
summary["fleet_overage_total_note"] = _onote

# The one number that answers "what did the fleet actually spend": metered-lane
# cash plus account overage. None-safe — a missing meter leaves the overage
# unknown, and an unknown must not silently read as zero in the total.
# Folded from the METER, not from any delta: the delta contribution is what
# made this total read $4.33 instead of $18,863. A function, not an inline
# expression, so a test can pin WHICH source it adds — swapping the meter for
# the 24h delta here restores the entire understatement on the headline number
# with every other assertion still green, which is exactly how it survived the
# first time.
def fleet_cash_total(metered_cash, overage):
    """Metered-lane cash + account overage.

    Takes the whole overage block and picks the field ITSELF rather than
    accepting a number, so the choice of source is inside the function a test
    can see. Extracting the arithmetic alone was not enough: the caller could
    still hand it the 24h delta and every assertion stayed green, because a
    unit test of the arithmetic cannot see which key was passed in.
    """
    meter = (overage or {}).get("overage_meter_usd")
    if meter is None:
        return None      # unknown overage must not silently read as zero
    return round(metered_cash + meter, 2)

_ofields = overage_fields(_ost, overage_delta(1))
summary.update(_ofields)
summary["fleet_cash_7d_total"] = fleet_cash_total(summary["fleet_cash_7d"], _ofields)
_ov = summary["overage_meter_usd"]
def cash_note(overage, unk7, unk24, state=None):
    """The caption on the headline cash figure.

    A confident total sitting next to thousands of unclassifiable rows is the
    failure this wave exists to end, so the caveat rides on the number itself
    rather than in a field nobody reads. The 24h count is what makes the
    caveat ACTIONABLE instead of alarming: rows written before billing_mode
    existed can only ever sit in the 7d tail, so

      7d high + 24h at zero  -> the legacy backlog is aging out. Expected
                                after the rollout; no action.
      24h staying high       -> rows are STILL landing untagged: a box whose
                                13->14 column header upgrade never ran, or a
                                runner nobody classified. That is a lane we
                                cannot price, and it needs a human.
    """
    note = ("metered-lane cash (7d of cost rows) + account overage (the CURRENT WEEKLY "
            "window's absolute meter, a different window of the same length)"
            if overage is not None else
            "UNKNOWN: no extra-usage meter on this box, so account overage could not be read; "
            "fleet_cash_7d covers metered lanes only and excludes any subscription overage")
    if overage is not None and state:
        if state.get("in_overage"):
            note += ("; ACCOUNT IS IN OVERAGE RIGHT NOW — the weekly allowance is exhausted "
                     "and every Claude call on this account is billing cash at API rates until "
                     + (state.get("weekly_resets_at") or "the weekly reset"))
        if state.get("prior_window_excluded_usd"):
            note += (f"; EXCLUDES ${state['prior_window_excluded_usd']} from the previous weekly "
                     "window, which reset inside this 7d span — that spend was real but belongs "
                     "to a different billing window, so this figure is low by up to that amount")
    if unk7:
        note += (f"; CAVEAT: {unk7} call(s) in the 7d window could not be classified as "
                 "metered or subscription, so cash is a LOWER BOUND — any real spend "
                 "among them is missing from this figure")
        note += ("; of those, NONE were written in the last 24h — legacy rows from before "
                 "the billing_mode column, aging out of the window on their own"
                 if not unk24 else
                 f"; {unk24} of them landed in the last 24h — rows are STILL being written "
                 "untagged, so this is not a clearing backlog: check that every box synced "
                 "the agent-call.sh header upgrade, and that no new runner is unclassified")
    return note

_unk = summary["fleet_unknown_billing_calls_7d"]
# EMITTED UNDER BOTH NAMES. The dashboard reads `cash_note`; this file had only
# ever written `fleet_cash_7d_total_note`, so every caveat this wave added —
# LOWER BOUND, IN OVERAGE, the excluded prior window — was composed carefully
# and then never reached a screen. Nothing errored: the SPA fell back to its
# own generated text, so the snapshot looked healthy and the note simply was
# not the one we wrote. The old name is kept because it ships in existing
# snapshots; both come from the same call, so they cannot diverge.
_note_text = cash_note(
    _ov, _unk, summary["fleet_unknown_billing_calls_24h"], _ost)
summary["cash_note"] = _note_text
summary["fleet_cash_7d_total_note"] = _note_text

# BH-3481.2: live spend, additive. `rows` is a count, not the rows: this file
# is pushed to the watchdog KV and stays small. An unreadable read carries no
# numbers at all, so nothing downstream can read it as $0 in flight.
def live_block(path, fallback_as_of):
    try:
        d = json.load(open(path)) if path and os.path.getsize(path) else None
    except Exception:
        d = None
    if not isinstance(d, dict):
        return {"unreadable": True}
    return {"in_flight_usd": d.get("in_flight_usd"), "unsettled_usd": d.get("unsettled_usd"),
            "rows": len(d.get("rows") or []), "truncated": bool(d.get("truncated")),
            "as_of": d.get("as_of") or fallback_as_of}
summary["live"] = live_block(os.environ.get("COST_ROLLUP_LIVE", ""), summary.get("generated_at"))

# BH-3930: bin/review-paid-unchanged.sh's answer, or its {"error": ...}. A file
# that does not parse as an object is an error too, never a zero-filled dict.
try:
    _rpu = json.load(open(os.environ.get("COST_ROLLUP_RPU") or os.devnull))
except Exception:
    _rpu = None
summary["review_paid_unchanged"] = _rpu if isinstance(_rpu, dict) else {"error": "unreadable result"}

json.dump(summary, open(f"{CD}/summary.json", "w"), indent=1)

lines = []
for p, v in summary["projects"].items():
    if v["merged_prs_7d"]:
        lines.append(f'{p.replace("-os","")}: ${v["cost_per_merged_pr_7d"]}/PR ({v["merged_prs_7d"]} merged, triage {int((v["triage_share_7d"] or 0)*100)}%)')
print(" | ".join(lines))
PY
PYRC=$?

# ---- THE PYTHON BLOCK MUST NOT FAIL QUIETLY ---------------------------------
# This script is `set -uo pipefail` but NOT `-e`, so a dead python block used to
# fall straight through: summary.json was never rewritten, the STALE file got
# pushed to the watchdog KV, and the run logged "summary written". A dashboard
# showing last hour's numbers is indistinguishable from one showing this hour's,
# so the failure was invisible for as long as nobody diffed generated_at.
#
# That is this codebase's recurring species — a path that cannot succeed,
# reporting success — sitting on the script's own success line. Any future
# exception in that block, for any reason, is now loud and pushes nothing.
# stderr goes to a FILE, not through a process substitution: `2> >(tee ...)`
# runs asynchronously, so reading the file immediately after can race the
# writer and produce an empty error tail — a diagnostic that is missing
# exactly when it is needed. Cron discards stderr anyway, so nothing is lost
# by capturing it outright and replaying it below.
if [ "$PYRC" -ne 0 ]; then
  cat "$PYERR" >&2
  ERRTAIL=$(tail -c 2000 "$PYERR" 2>/dev/null | tr '\n' ' ')
  echo "$(STAMP) cost-rollup: python rollup FAILED rc=$PYRC — summary.json NOT regenerated, snapshot NOT pushed. ${ERRTAIL}" >> "$H/logs/agent-rules.log"
  FLAG="$H/flags/alerted-cost-rollup-crash-$(date -u +%Y%m%d)"
  [ -f "$FLAG" ] || { touch "$FLAG"; HARNESS="$H" "$H/bin/alert-line.sh" "[cost-rollup] rollup CRASHED (rc=$PYRC) — the dashboard is serving a STALE cost snapshot. ${ERRTAIL}"; }
  rm -f "$PYERR" "$BOR_TSV" "$LIVE_F" "$FB_KEYS" "$FB_RETRY"
  exit 1
fi
rm -f "$PYERR" "$BOR_TSV" "$LIVE_F" "$FB_KEYS" "$FB_RETRY"

# ── LIVENESS: the lane says when it last succeeded (2026-09-15) ──────────────
# The rollup logs one line per run into logs/agent-rules.log and nothing reads
# it, so "the hourly refresh stopped" has always been a fact you could only
# learn by stat-ing four files and doing timezone arithmetic in your head — and
# on 2026-09-15 someone did exactly that, read a 10:50 LOCAL mtime as 10:50Z,
# and reported a five-hour stall in a lane that was running fine. A machine-
# readable, unambiguously-UTC stamp is the fix for both halves: the detector in
# bin/pipeline-health.sh pages when this stamp ages past 2x the cron interval,
# and a human reading it cannot mistake which clock it is in.
#
# WRITTEN HERE, not at the end of the script: this is the instant the windows
# were genuinely refreshed. Everything below (the watchdog push, the beats, the
# ledger mirror) is fail-open delivery with its own alerts, and letting one of
# those mark the whole lane dead would page for the wrong thing. A CRASHED
# python block exits above without touching this stamp, which is the point.
#
# A ROW, NOT A FILE (BH-4158): the ledgers row cost-rollup/last-success, detail
# = the ISO-Z stamp. A put that fails costs one log line and nothing else:
# pipeline-health takes the newest of this row and summary.json's mtime, and
# the python block above just rewrote summary.json.
# >>> rollup last success
LS_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
LS_RC=127
command -v job_ledger_put >/dev/null 2>&1 && { job_ledger_put cost-rollup last-success ok "$LS_TS"; LS_RC=$?; }
[ "$LS_RC" = 0 ] || echo "$(STAMP) cost-rollup: last-success row NOT written ($LS_RC) — pipeline-health reads summary.json's mtime this run" >> "$H/logs/agent-rules.log"
rm -f "$CD/last-success"
# <<< rollup last success

# ---- push the rollup to the watchdog KV (Mission Control's cost panel) -------
# Mirrors bin/tickets-snapshot-push.sh: the dashboard reads real spend from this
# snapshot rather than from any box, so a box going away never takes the number
# with it. Additive — the headline fleet_alert beats below are unchanged.
#
# Fail-quiet but NEVER silent: a dead push means a stale dollar figure, and a
# stale dollar figure looks exactly like a cheap week. The console flags
# spend_stale past 26h, so the staleness is visible either way; this log line is
# what tells you WHICH end broke.
if [ -s "$CD/summary.json" ]; then
  CS=$(watchdog_secret "$HENV") || CS=""
  if [ -z "$CS" ]; then
    echo "$(STAMP) cost-rollup: no watchdog secret — cost snapshot NOT pushed" >> "$H/logs/agent-rules.log"
  # global.env loads only further down (the metrics push), and cron exports no
  # env, so WATCHDOG_URL is read from it here, in a subshell that changes nothing
  # else. Not configured is not a failed push: no FAILED line, no alert (BH-3322).
  elif ! CWD=$( { [ -f "$HENV/global.env" ] && set -a && . "$HENV/global.env"; set +a; } 2>/dev/null
                watchdog_url cost-rollup "$H"); then
    echo "$(STAMP) cost-rollup: WATCHDOG_URL not set, cost snapshot NOT pushed" >> "$H/logs/agent-rules.log"
  elif ! watchdog_curl "$CS" -sf -m 30 -X POST -H 'Content-Type: application/json' \
       --data-binary @"$CD/summary.json" \
       "$CWD/api/cost-snapshot" >/dev/null 2>&1; then
    echo "$(STAMP) cost-rollup: cost-snapshot push to watchdog FAILED — Mission Control spend figure will go stale" >> "$H/logs/agent-rules.log"
    FLAG="$H/flags/alerted-cost-snapshot-$(date -u +%Y%m%d)"
    [ -f "$FLAG" ] || { touch "$FLAG"; HARNESS="$H" "$H/bin/alert-line.sh" "[cost-rollup] cost-snapshot push to watchdog FAILED — dashboard spend will go stale"; }
  fi
else
  echo "$(STAMP) cost-rollup: summary.json missing or empty — nothing pushed" >> "$H/logs/agent-rules.log"
fi

if [ "${WINDOWS_ONLY:-0}" != "1" ]; then
BEAT_LINE=$(python3 -c "
import json
s=json.load(open('$CD/summary.json'))
parts=[]
for p,v in s['projects'].items():
    if v.get('merged_prs_7d'):
        ro = f\", {v['reopens_14d']} reopen{'s' if v['reopens_14d']!=1 else ''}/14d\" if v.get('reopens_14d') is not None else ''
        parts.append(f\"{p.replace('-os','')}: \${v['cost_per_merged_pr_7d']}/PR x{v['merged_prs_7d']} (triage {int((v['triage_share_7d'] or 0)*100)}%{ro})\")
print('7d cost-per-PR — ' + ' | '.join(parts))" 2>/dev/null)
[ -n "$BEAT_LINE" ] && "$H/bin/beat.sh" "$(jq -nc --arg akey "costrollup:$(date -u +%F)" --arg l "$BEAT_LINE" \
  '{kind:"fleet_alert",project:"fleet",triaged:true,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
STAGE_LINE=$(python3 -c "
import json
s=json.load(open('$CD/summary.json'))
tot={}; m=0
for p,v in s['projects'].items():
    if p=='other': continue
    m+=v.get('merged_prs_7d') or 0
    for k,c in (v.get('stages_7d') or {}).items(): tot[k]=tot.get(k,0)+c
if m:
    order=['plan','execute','review','fix','triage']
    parts=[f'{k} \${tot[k]/m:.2f}' for k in order if k in tot]
    build=sum(tot.get(k,0) for k in ('plan','execute','review','fix','preplan'))
    print(f'7d per merged PR — build \${build/m:.2f} ({\" | \".join(parts[:4])}) vs triage \${tot.get(\"triage\",0)/m:.2f}')" 2>/dev/null)
[ -n "$STAGE_LINE" ] && "$H/bin/beat.sh" "$(jq -nc --arg akey "coststages:$(date -u +%F)" --arg l "$STAGE_LINE"   '{kind:"fleet_alert",project:"fleet",triaged:true,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
[ -n "$REPEAT_LINE" ] && "$H/bin/beat.sh" "$(jq -nc --arg akey "repeatfamily:$(date -u +%F)" --arg l "$REPEAT_LINE" '{kind:"fleet_alert",project:"fleet",triaged:true,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
# Reviews paid twice on an unchanged head (BH-3930): one beat line a day, and a
# warn while yesterday AND the day before both had one; otherwise resolve. An
# error is one ALERTS line and nothing else: unknown is not zero, so it never
# resolves. lane-alert dedupes by id, so no flags/ file.
# (tests/review-paid-unchanged.bh-3930-test.sh runs this block verbatim.)
# >>> review paid unchanged beat
RPU_TODAY="${RPU_TODAY:-$(date -u +%F)}"
RPU_OUT=""
if [ -z "${RPU_ERR:-}" ]; then
  RPU_OUT=$(python3 - "$CD/summary.json" "$RPU_TODAY" <<'PYRPU'
import datetime, json, sys
try:
    m = json.load(open(sys.argv[1]))["review_paid_unchanged"]
    assert isinstance(m, dict) and "error" not in m and isinstance(m.get("total_by_day"), dict)
except Exception:
    sys.exit(3)
t = datetime.date.fromisoformat(sys.argv[2])
y, b = (t - datetime.timedelta(days=1)).isoformat(), (t - datetime.timedelta(days=2)).isoformat()
yd = (m.get("days") or {}).get(y) or {}
parts = [f"{k}={v}" for k, v in sorted(yd.items()) if v]
# "yesterday" is yesterday's exempt rows only, never the window's
ex = (m.get("exempt_by_day") or {}).get(y) or {}
line = ("review_paid_unchanged yesterday: " + (" ".join(parts) or "none")
        + " (exempt: " + " ".join(f"{r}={ex.get(r, 0)}" for r in ("rereq", "stepup", "noverdict")) + ")")
top = "; ".join(f"{e.get('key')} {e.get('lane')} x{e.get('calls')} ${e.get('usd')}" for e in (m.get("top") or [])[:5])
# A day the metric did not report is unknown, not 0: error path, no resolve.
ty, tb = m["total_by_day"].get(y), m["total_by_day"].get(b)
if not isinstance(ty, int) or not isinstance(tb, int):
    sys.exit(3)
print("\t".join([str(ty), str(tb), line, top or "none"]))
PYRPU
) || RPU_ERR="summary.json carries no review_paid_unchanged result for $RPU_TODAY's yesterday and the day before"
fi
if [ -n "${RPU_ERR:-}" ]; then
  HARNESS="$H" "$H/bin/alert-line.sh" "[cost-rollup] review_paid_unchanged did not compute: $RPU_ERR; summary.json carries {\"error\": ...}, not a zero"
else
  IFS=$'\t' read -r RPU_Y RPU_Y2 RPU_LINE RPU_TOP <<<"$RPU_OUT"
  "$H/bin/beat.sh" "$(jq -nc --arg akey "reviewpaid:$RPU_TODAY" --arg l "$RPU_LINE" '{kind:"fleet_alert",project:"fleet",triaged:true,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  if [ "${RPU_Y:-0}" -gt 0 ] && [ "${RPU_Y2:-0}" -gt 0 ]; then
    "$H/bin/lane-alert.sh" --id review-paid-unchanged --severity warn cost-rollup \
      "review paid twice on an unchanged head: yesterday $RPU_Y, day before $RPU_Y2. top: $RPU_TOP" >/dev/null 2>&1 || true
  else
    "$H/bin/lane-alert.sh" --resolve --id review-paid-unchanged cost-rollup \
      "review_paid_unchanged: no two-day run (yesterday ${RPU_Y:-0}, day before ${RPU_Y2:-0})" >/dev/null 2>&1 || true
  fi
fi
# <<< review paid unchanged beat
fi
PR_ROWS=$(($(wc -l < "$CD/cost-per-pr.csv" 2>/dev/null || echo 1) - 1))
[ "$PR_ROWS" -ge 0 ] 2>/dev/null || PR_ROWS=0
echo "$(STAMP) cost-rollup${WINDOWS_ONLY:+ (windows-only)}: $PR_ROWS PR rows, summary written" >> "$H/logs/agent-rules.log"

# ── A ZERO-ROW SWEEP IS AN ALERT, NOT A LOG LINE (2026-08-29) ────────────────
# The per-PR cost lane is the only place the fleet learns what a PR actually
# cost, and its failure mode is silence: the rollup exits 0, rewrites the file
# with a header and no rows, and says so once in agent-rules.log where nobody
# reads it. Every row here needs a build dir with BOTH a cost.csv and a PR
# binding (a ledger row, or for a dir the ledger does not name, a RESULT
# holding a PR url), so a change to either — a builds/ prune, a binding that stops
# carrying the url, cost_rows rows arriving without run_id — empties the whole file
# without erroring. One ALERTS line per day, because the CSV is a full rewrite
# and a day of zeroes is a broken lane rather than a quiet one.
if [ "$PR_ROWS" -eq 0 ]; then
  ZFLAG="$H/flags/alerted-costperpr-empty-$(date -u +%Y%m%d)"
  if [ ! -f "$ZFLAG" ]; then
    mkdir -p "$H/flags" 2>/dev/null && touch "$ZFLAG" 2>/dev/null
    HARNESS="$H" "$H/bin/alert-line.sh" "[cost-rollup] cost-per-pr.csv came out EMPTY — no hub build dir under builds/ has a cost.csv and a PR binding (ledger or RESULT), and no cost_rows run_id is bound by the ledger. Per-PR cost attribution is dark (cache-hit-report.sh reads this file too)."
  fi
fi

# ── AN UNPRICED CALL IS SPEND WE CANNOT SEE (2026-09-10) ────────────────────
# unpriced_calls_24h has been on the dashboard as a bare count since the cash
# split shipped, and on 2026-09-10 twenty of them had been sitting there for a
# week without paging anyone. An unpriced row is not a missing row: the call was
# made, the vendor billed it, and the ledger records $0.00 — so a lane running
# entirely on an unpriced model reads as free, which is precisely how the grok
# lane burned ~$460 in two days with the xAI invoice as the only symptom.
#
# The line names the RUNNER/MODEL pairs, because the count alone is not
# actionable and the two causes need different fixes: a model missing from
# catalog/model-prices.json needs a price row, a pair reporting no tokens at all
# needs its runner to capture usage. One line per day (flags/alerted-unpriced-
# <date>), like the other daily alerts here — the windows refresh hourly and a
# repeat every hour is how an alert stops being read.
# >>> unpriced call alert
if [ -s "$CD/summary.json" ]; then
  UNPRICED_N=$(jq -r '.fleet_unpriced_calls_24h // 0' "$CD/summary.json" 2>/dev/null)
  PRICES_N=$(jq -r '.prices_loaded // 0' "$CD/summary.json" 2>/dev/null)
  # ABSENT is not zero. A summary.json written by the previous version of this
  # script carries neither field, and reading a missing prices_loaded as 0 would
  # declare the price table dead on the first run after a deploy; reading a
  # missing pairs list as "empty" would go silent instead. Both are answered
  # with the raw count and no breakdown, which is what the old alert did.
  HAS_PRICES=$(jq -r 'has("prices_loaded")' "$CD/summary.json" 2>/dev/null)
  HAS_PAIRS=$(jq -r 'has("fleet_unpriced_pairs_24h")' "$CD/summary.json" 2>/dev/null)
  # Rows the pairs actually account for — the BILLED ones. Never-billed
  # failures are excluded upstream, so this is smaller than the dashboard count
  # whenever the vendor had a bad afternoon.
  PAIR_N=$(jq -r '[(.fleet_unpriced_pairs_24h // [])[].calls] | add // 0' "$CD/summary.json" 2>/dev/null)
  for V in UNPRICED_N PRICES_N PAIR_N; do
    eval "case \"\$$V\" in ''|*[!0-9]*) $V=0 ;; esac"
  done
  UFLAG="$H/flags/alerted-unpriced-$(date -u +%Y%m%d)"
  ULINE=""
  if [ "$HAS_PRICES" = true ] && [ "$PRICES_N" -eq 0 ] && [ "$UNPRICED_N" -gt 0 ]; then
    # THE TABLE, NOT THE MODELS. With prices={} every token-bearing row in the
    # fleet reads as "no price-table entry", so naming runners here would send
    # someone to add price rows that already exist. One cause, one fix.
    ULINE="the model price table loaded ZERO models, so all $UNPRICED_N call(s) in the last 24h read as unpriced and every cost figure is notional. This is the TABLE, not the models: check catalog/model-prices.json exists at the path cost-rollup.sh reads and that its daily OpenRouter refresh is running."
  elif [ "$HAS_PAIRS" != true ] && [ "$UNPRICED_N" -gt 0 ]; then
    ULINE="$UNPRICED_N call(s) in the last 24h are UNPRICED — that spend is real and reads as \$0.00 on every cost view. No runner/model breakdown in this summary (written before the breakdown shipped); the next rollup will name them."
  elif [ "$PAIR_N" -gt 0 ]; then
    # BH-1361: each no-price-entry pair carries the LINE to add. The map is data
    # (catalog/model-slugs.json), so the operator — or an auto-fix lane — closes
    # this with one edit instead of reading the OpenRouter list by hand. A pair
    # whose suggested_slug is null or absent (a summary written by the previous
    # rollup) gets the key and an honest placeholder, never an invented slug.
    NOPRICE=$(jq -r '[(.fleet_unpriced_pairs_24h // [])[]
                      | select(.in_price_table == false and .tokens > 0)
                      | "\(.runner)/\(.model) (\(.calls) call(s), \(.tokens) tokens) "
                        + "[add to catalog/model-slugs.json: \"\(.model)\": "
                        + (if (.suggested_slug // null) == null
                           then "\"<slug?>\" (no close openrouter match — pick the id from https://openrouter.ai/api/v1/models)"
                           else "\"\(.suggested_slug)\"" end) + "]"]
                     | join(", ")' "$CD/summary.json" 2>/dev/null)
    NOTOKENS=$(jq -r '[(.fleet_unpriced_pairs_24h // [])[]
                       | select(.tokens == 0)
                       | "\(.runner)/\(.model) (\(.calls) call(s))"]
                      | join(", ")' "$CD/summary.json" 2>/dev/null)
    PRICED=$(jq -r '[(.fleet_unpriced_pairs_24h // [])[]
                     | select(.in_price_table == true and .tokens > 0)
                     | "\(.runner)/\(.model) (\(.calls) call(s))"]
                    | join(", ")' "$CD/summary.json" 2>/dev/null)
    ULINE="$PAIR_N call(s) in the last 24h are UNPRICED — that spend is real and reads as \$0.00 on every cost view."
    [ -n "$NOPRICE" ]  && ULINE="$ULINE No price-table entry: $NOPRICE — the 04:30Z refresh prices it from that line; land the refreshed row in catalog/model-prices.json for the fallback."
    [ -n "$NOTOKENS" ] && ULINE="$ULINE No tokens reported: $NOTOKENS — the runner is not capturing usage."
    [ -n "$PRICED" ]   && ULINE="$ULINE Priced model, still \$0: $PRICED — the usage parse is landing on the wrong JSON path."
    # The family this belongs to, and what its absence means. The call sites
    # page on the FIRST unpriced call now (cost_parity_alert in
    # bin/lib/cost-row.sh writes a [cost-parity] line on the box that made the
    # call), so this line arriving with no [cost-parity] line behind it says the
    # box has not synced the guard — which is a different fix from the two above.
    ULINE="$ULINE Family: cost-capture parity, docs/COST.md#cost-capture-parity. Check that box's own ALERTS.log for a [cost-parity] line; if there is none, it has not synced the call-site guard."
    # Say what was left out, so the line reconciles against the dashboard number
    # instead of looking like one of them is wrong.
    EXCL=$((UNPRICED_N - PAIR_N))
    [ "$EXCL" -gt 0 ] && ULINE="$ULINE (${EXCL} further zero-token failure(s) in the window were never billed and are excluded.)"
  fi
  if [ -n "$ULINE" ] && [ ! -f "$UFLAG" ]; then
    mkdir -p "$H/flags" 2>/dev/null && touch "$UFLAG" 2>/dev/null
    HARNESS="$H" "$H/bin/alert-line.sh" "[cost-rollup] $ULINE"
  fi
fi
# <<< unpriced call alert

# ── A NEW PAIR STORED UNPRICED IS A CAP THAT UNDERCOUNTS (BH-2306) ──────────
# The block above asks whether the rollup can price a row. This one asks what
# the ledger STORED: a billed row with a blank cost_usd is NULL in D1, and the
# llm-spend caps and the Costs page read it as $0 even when the catalog prices
# its model. Over 700 of those on 2026-09-18..21 paged nobody.
#
# It pages once per NEW runner/model pair. The seen-set is D1 `ledgers`, kind
# unpriced_pair, key runner|model, so a pair that paged once never pages here
# again (the block above still pages daily for a pair the catalog can't price).
# The ledger answer is three-way: rc 0 known, rc 2 new, anything else
# UNVERIFIED — alerted, tagged, and never marked. Write, then mark: the line
# goes through bin/alert-line.sh, which exits 0 whether or not its append
# landed, so the flag and the puts happen only once the exact line reads back
# from the last 200 lines of ALERTS.log (BH-2364). An append that failed marks
# nothing, and the pair pages again tomorrow rather than going silent.
# flags/alerted-unpriced-new-<date> makes it one line a day; a pair first seen
# after that line waits for the next day's first run.
# >>> new unpriced pair alert
if [ -s "$CD/summary.json" ] \
   && [ "$(jq -r 'has("fleet_ledger_unpriced_pairs_24h")' "$CD/summary.json" 2>/dev/null)" = true ]; then
  NFLAG="$H/flags/alerted-unpriced-new-$(date -u +%Y%m%d)"
  NPAIRS=$(jq -r '.fleet_ledger_unpriced_pairs_24h[]?
                  | [.runner, .model, (.calls|tostring), (.tokens|tostring), (.priceable|tostring),
                     (.in_catalog // .priceable|tostring), (.no_usage // 0|tostring)]
                  | @tsv' "$CD/summary.json" 2>/dev/null)
  if [ -n "$NPAIRS" ] && [ ! -f "$NFLAG" ]; then
    if ! command -v job_ledger_get >/dev/null 2>&1 && [ -f "$H/bin/jobs-client.sh" ]; then
      # shellcheck source=/dev/null
      . "$H/bin/jobs-client.sh"
    fi
    NPARTS=""; NMARK=()
    while IFS=$'\t' read -r -u 3 NR NM NC NT NP NIC NNU; do
      [ -n "$NR" ] || continue
      NK="$NR|$NM"
      NRC=1
      if command -v job_ledger_get >/dev/null 2>&1; then
        job_ledger_get unpriced_pair "$NK" >/dev/null 2>&1; NRC=$?
      fi
      [ "$NRC" = 0 ] && continue
      # BH-2416: three facts, not one. Calls with no usage go to the runner's
      # usage parse; only a model the price table lacks is told to add a row.
      NWHY=""
      if [ "${NNU:-0}" -gt 0 ] 2>/dev/null; then
        case "$NR" in
          claude) NPARSE="bin/agent-call.sh run_attempt claude branch (.usage from the result JSON)" ;;
          codex|openrouter|fireworks) NPARSE="bin/codex-usage.sh (called from bin/agent-call.sh run_attempt)" ;;
          grok) NPARSE="bin/grok-usage.sh" ;;
          *) NPARSE="no usage parser mapped for runner $NR; start at bin/agent-call.sh run_attempt" ;;
        esac
        NWHY="$NNU call(s) reported no usage — runner $NR returned no token counts; fix its usage parse: $NPARSE"
      fi
      if [ "$NC" -gt "${NNU:-0}" ] 2>/dev/null && [ "$NIC" = true ]; then
        if [ "$NP" = true ]; then
          NWHY="$NWHY${NWHY:+; }catalog prices it — the writer on that box is not pricing at the call site (bin/lib/cost-row.sh cost_row_price); check the box has synced"
        else
          NWHY="$NWHY${NWHY:+; }in catalog/model-prices.json but its row prices these tokens at \$0 — check that row's rates"
        fi
      fi
      if [ "$NIC" != true ]; then
        NWHY="$NWHY${NWHY:+; }not in catalog/model-prices.json — add a price row"
      fi
      NPART="$NR/$NM ($NC call(s), $NT tokens, $NWHY)"
      if [ "$NRC" = 2 ]; then
        NMARK+=("$NK"$'\t'"$NC"$'\t'"$NT")
      else
        NPART="$NPART (seen-set unreadable)"
      fi
      NPARTS="$NPARTS${NPARTS:+; }$NPART"
    done 3<<<"$NPAIRS"
    if [ -n "$NPARTS" ]; then
      NSTAMP=$(STAMP)
      NTEXT="[cost-rollup] NEW UNPRICED PAIR(S): $NPARTS; the cost ledger stores these as NULL, so llm-spend caps and the Costs page read them as \$0."
      HARNESS="$H" ALERT_LINE_STAMP="$NSTAMP" "$H/bin/alert-line.sh" "$NTEXT"
      if tail -n 200 "$H/logs/ALERTS.log" 2>/dev/null | grep -qxF -- "$NSTAMP $NTEXT"; then
        mkdir -p "$H/flags" 2>/dev/null && touch "$NFLAG" 2>/dev/null
        for NE in ${NMARK[@]+"${NMARK[@]}"}; do
          IFS=$'\t' read -r NK NC NT <<<"$NE"
          job_ledger_put unpriced_pair "$NK" alerted "first_alerted=$(STAMP) calls=$NC tokens=$NT" >/dev/null 2>&1 || true
        done
      fi
    fi
  fi
fi
# <<< new unpriced pair alert

# ── Push the sweep to the harness-jobs metrics ledger (2026-08-29) ───────────
# FAIL-OPEN, after the file. state/cost/cost-per-pr.csv stays the local record
# and stays what bin/cache-hit-report.sh reads; this is the copy anything that
# is not the hub can reach. One batched request for the whole sweep, upserted on
# pr_url, so re-pushing unchanged rows every hour is a no-op.
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    cost-rollup
if [ -f "$H/bin/jobs-client.sh" ] && [ "$PR_ROWS" -gt 0 ]; then # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh"
  command -v metric_pr_costs >/dev/null 2>&1 && \
  metric_pr_costs "$CD/cost-per-pr.csv" || true
fi
