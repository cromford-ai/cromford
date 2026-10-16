#!/bin/bash
# bin/dora-digest.sh [--window 24h|7d] [--no-send] [--print] [--out-dir DIR]
#
# THE DAILY DORA + UNIT-ECONOMICS DIGEST (2026-09-15). the operator asked three
# questions by hand in one day — "how's the project-5 drain", "cost per PR",
# "when do the max accounts hit caps" — and each one was answered by somebody
# grepping four logs and a csv. Those numbers are all written down already; what
# was missing was one lane that reads them on a schedule and says them out loud.
#
# WHAT IT COMPUTES, for the trailing window, per repo and as a fleet total:
#   PRs merged, lead time p50/p90, conflict rate, rebuild rate, lane deaths,
#   a change-failure proxy, $/PR and total $ (by repo and by auth account,
#   subscription-absorbed vs cash), the minutes this box spent running repo
#   suites per merged PR, and every account's weekly quota % with the instant it
#   resets.
#
# EVERY NUMBER NAMES ITS SOURCE. state/dora/<date>.json carries, per metric, the
# file (or route) it came from and the line/row counts that were read, so any
# figure in the Telegram message can be re-derived by hand from the same slice.
# That is the whole point: a digest nobody can check is a digest nobody believes
# the second it disagrees with a hunch.
#
# A MISSING SOURCE IS "n/a (source X absent)", NEVER A CRASH and never a zero.
# A zero merge count reads as "a quiet day"; an absent conductor log reads as
# "we do not know", and those must not look alike. The one thing that DOES page
# is both merge sources being unreadable at once — then the digest cannot
# measure the fleet's output at all, and silence would be indistinguishable from
# a green day (the lesson in docs/LESSONS.md, "stopping is an alert").
#
# SOURCES, in the order the digest trusts them:
#   merges + lead time  GET /api/metrics/dora?days=N on the harness-jobs worker
#                       (worker/jobs/src/index.js computeDora). THE MOST
#                       RELIABLE of the three candidates: it is keyed per PR off
#                       the `ledgers` kind=merge rows, and it derives lead time
#                       from jobs.created_at — the instant the ticket was
#                       claimed — rather than from a build directory's mtime,
#                       which a rebuild rewrites, or a log line, which rotates.
#                       logs/merge-conductor.log is the FALLBACK for the merge
#                       count (and always read anyway, for the conflict rate),
#                       and the digest says which one it used.
#   conflicts           logs/merge-conductor.log: DISTINCT PRs entering
#                       NEEDS_REBASE (the state the conductor enters on
#                       mergeState DIRTY).
#   rebuilds/deaths     logs/blocked-resolver.log: "REBUILD FRESH n of m",
#                       "ABANDONED", and park reasons naming a dead pool lane.
#   $                   state/cost/fleet-cost.csv (ts, project, cost_usd,
#                       billing_mode, auth_account — read BY HEADER NAME, not
#                       column index) for the window's spend; and
#                       state/cost/cost-per-pr.csv joined on the window's merged
#                       PR urls for the per-PR figures the rollup already priced.
#   box test minutes    builds/<dir>/pipeline.log: the STAGE-TIMING suite,
#                       suite-fix and suite-head lines bin/run-build.sh writes
#                       around every run of a repo's own suite, summed per
#                       project off the build dir's name.
#   quota               state/quota/<account>.json (bin/quota-poll.sh writes it;
#                       bin/quota-status.sh renders the same files interactively).
#   cash overage        logs/extra-usage-<account>.csv, last row plus the delta
#                       across the window.
#   conflicts block     bin/dora_conflicts.py (BH-6965): the conductor log, the
#                       resolver log, state/blocked-resolver/<p>/<key>.json
#                       attempts (fix-round-conflict ok|failed) and
#                       logs/repair-on-push.log (REPAIR and wake lines).
#
# OUTPUT:
#   1. state/dora/<date>.json          (state/dora/<date>-<window>.json when the
#                                       window is not the default)
#   2. state/dora/latest.txt           the plain-text message, verbatim
#   3. one fleet-topic beat carrying that text — the same
#      {kind:fleet_alert, project:fleet, triaged:true} pass-through
#      bin/alert-digest.sh and bin/cost-rollup.sh already use for a daily
#      digest. beat.sh has no plain "send this text" mode; triaged:true is the
#      established way a digest reaches the topic without going through alert
#      quarantine. --no-send writes the files and posts nothing.
#
# Cron: hub, daily 07:00Z (the line is in the PR body's fold-ins).
# Knobs (env, then the settings row conf.dora-digest.<key lowercased>[.<box>],
# then flags/dora-digest.conf as KEY=VALUE lines — env wins):
#   DORA_WINDOW=24h          the trailing window; <n>h or <n>d
#   DORA_SEND=1              0 = write the files, post no beat
#   DORA_LEDGER=1            0 = skip the worker read, use the conductor log
#   DORA_QUOTA_WARN_PCT=80   weekly % at which an account is called out
#   DORA_MAX_ROWS=12         repo lines in the message (the json is never cut)
#   DORA_TEXT_MAX_CHARS=3500 beat truncation; latest.txt is always complete
#   DORA_OUT_DIR=$H/state/dora
#   DORA_BUILDS_DIR=$H/builds  where builds/<dir>/pipeline.log is read for the
#                              STAGE-TIMING suite lines behind box test minutes
#   DORA_GH_BUDGET=1         0 (any value but 1) = skip bin/gh-budget-report.sh
#                            and the `github REST:` line
#   DORA_CONFLICTS_REBUILD_ALERT_PER_100=40  the conflicts alert threshold, read
#                            AFTER the settings row conflicts.rebuild_alert_per_100
#                            (BH-6965): rebuilds per 100 merges over the trailing
#                            24 h strictly over it writes one [dora-conflicts]
#                            ALERTS line a UTC day
#   QUOTA_DIR=$H/state/quota
# Kill switch: settings row switch.dora-digest-off.<box> or switch.dora-digest-off
# (1 = off), read by lane_switch (bin/lib/lane-switch.sh); flags/dora-digest-off
# decides only when neither row exists.
# Contract + how to re-derive every figure by hand: docs/DORA.md.
set -uo pipefail
# BH-1138: no __pycache__ next to bin/*.py. The interpreter writes bytecode
# beside any module it IMPORTS; gitignore has no say over a path that is
# already tracked, and a whole-tree `git add -A` then re-commits it — which
# is how bin/__pycache__/gate-selfwrite.cpython-312.pyc reached main twice.
# The staging exclusions in bin/lane-checkpoint.sh and bin/lander.sh are the
# belt; this is the brace, and the only half that means the file never exists.
export PYTHONDONTWRITEBYTECODE=1
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
BIN="$(cd "$(dirname "$0")" && pwd)"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$H/logs/dora-digest.log"
ALERTS="$H/logs/ALERTS.log"
say() { echo "$(STAMP) $*" >> "$LOG"; }

WINDOW=""; SEND=""; PRINT=0; OUTDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --window) WINDOW="${2:-}"; shift 2 ;;
    --window=*) WINDOW="${1#*=}"; shift ;;
    --no-send) SEND=0; shift ;;
    --send) SEND=1; shift ;;
    --print) PRINT=1; shift ;;
    --out-dir) OUTDIR="${2:-}"; shift 2 ;;
    --out-dir=*) OUTDIR="${1#*=}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "usage: dora-digest.sh [--window 24h|7d] [--no-send] [--print] [--out-dir DIR]" >&2; exit 2 ;;
  esac
done

mkdir -p "$H/logs" "$H/state" "$H/flags" 2>/dev/null
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# flags/dora-digest.conf — the per-box override file. Parsed, never sourced: this
# file is config, and a config file that can run code is a second entry point
# into the lane. Only DORA_*/QUOTA_DIR keys with a plain value are honoured, and
# a value already set in the environment (or on the command line) wins, so the
# operator's `--window 7d` is never quietly overridden by a file.
#
# The settings rows `conf.dora-digest.<key lowercased>[.<box>]` (BH-2411,
# bin/lib/conf-row.sh) go through the SAME check first, as the line
# `<KEY uppercased>=<value>`, so the environment still wins, a row wins over
# the file (the first export wins), and a row outside the namespace or with
# anything but a plain value is skipped exactly as a file line would be.
CONF="$H/flags/dora-digest.conf"
dora_conf_line() { # dora_conf_line <KEY=VALUE> — rc 0 when it was a knob line
  local L="$1" K V
  case "$L" in *=*) : ;; *) return 1 ;; esac
  K="${L%%=*}"; V="${L#*=}"
  # The key becomes a shell variable NAME, so it is validated as one rather
  # than sanitised: anything that is not an uppercase identifier in the
  # DORA_*/QUOTA_DIR namespace is skipped outright.
  case "$K" in
    DORA_[A-Z0-9_]*|QUOTA_DIR) : ;;
    *) return 1 ;;
  esac
  case "$K" in *[!A-Z0-9_]*) return 1 ;; esac
  case "$V" in *[!A-Za-z0-9._/:+-]*) return 1 ;; esac
  [ -n "${!K:-}" ] || export "$K=$V"
  return 0
}
# shellcheck source=lib/conf-row.sh
. "$BIN/lib/conf-row.sh" 2>/dev/null || true
if command -v conf_rows >/dev/null 2>&1; then
  DK=""
  while IFS=$'\t' read -r K V; do
    dora_conf_line "$(printf '%s' "$K" | tr '[:lower:]' '[:upper:]')=$V" && DK="$DK $K"
  done < <(conf_rows dora-digest "$H")
  # shellcheck disable=SC2086  # the key list, one word per key
  [ -n "$DK" ] && conf_row_note_file dora-digest "$CONF" $DK
fi
if [ -r "$CONF" ]; then
  while IFS= read -r L; do
    dora_conf_line "$L" || continue
  done < "$CONF"
fi

# shellcheck source=lib/lane-switch.sh
. "$BIN/lib/lane-switch.sh" || exit 1
lane_switch dora-digest-off && exit 0

WINDOW="${WINDOW:-${DORA_WINDOW:-24h}}"
SEND="${SEND:-${DORA_SEND:-1}}"
OUTDIR="${OUTDIR:-${DORA_OUT_DIR:-$H/state/dora}}"
LEDGER="${DORA_LEDGER:-1}"
WARN_PCT="${DORA_QUOTA_WARN_PCT:-80}"
MAX_ROWS="${DORA_MAX_ROWS:-12}"
TEXT_MAX="${DORA_TEXT_MAX_CHARS:-3500}"
QUOTA_DIR="${QUOTA_DIR:-$H/state/quota}"

# A knob that is not a number would reach python as one and crash the run, or
# reach `head -c` and silently produce no message. Fall back loudly instead.
case "$MAX_ROWS" in ''|*[!0-9]*)
  say "DORA_MAX_ROWS='$MAX_ROWS' is not a number — using 12"; MAX_ROWS=12 ;; esac
case "$TEXT_MAX" in ''|*[!0-9]*)
  say "DORA_TEXT_MAX_CHARS='$TEXT_MAX' is not a number — using 3500"; TEXT_MAX=3500 ;; esac
case "$WARN_PCT" in ''|*[!0-9]*)
  say "DORA_QUOTA_WARN_PCT='$WARN_PCT' is not a number — using 80"; WARN_PCT=80 ;; esac

# <n>h / <n>d -> hours. A window nobody can parse is refused rather than guessed:
# every number below is labelled with it, and a mislabelled window is worse than
# no digest.
case "$WINDOW" in
  *h) N="${WINDOW%h}"; case "$N" in ''|*[!0-9]*) N="" ;; esac; HOURS="$N" ;;
  *d) N="${WINDOW%d}"; case "$N" in ''|*[!0-9]*) N="" ;; esac; [ -n "$N" ] && HOURS=$(( N * 24 )) || HOURS="" ;;
  *)  HOURS="" ;;
esac
if [ -z "${HOURS:-}" ] || [ "$HOURS" -le 0 ]; then
  echo "dora-digest.sh: --window must be <n>h or <n>d (got '$WINDOW')" >&2; exit 2
fi

NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
SINCE_ISO=$(date -u -d "$HOURS hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
  || SINCE_ISO=$(date -u -v-"${HOURS}"H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
[ -n "${SINCE_ISO:-}" ] || { echo "dora-digest.sh: cannot compute the window start" >&2; exit 2; }
# The worker's route takes whole days and clamps at 1; a 24h window is days=1.
DAYS=$(( (HOURS + 23) / 24 ))

mkdir -p "$OUTDIR" 2>/dev/null || { echo "dora-digest.sh: cannot create $OUTDIR" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dora-digest-XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# ---- the ledger read (best source for merges + lead time) --------------------
# Fail-open in the shape the rest of the fleet uses: no client, no secret, a
# worker outage or a body that is not json all land on "absent", and the python
# below falls back to the conductor log and says so in the payload.
DORA_JSON=""
if [ "$LEDGER" = 1 ] && [ -r "$H/bin/jobs-client.sh" ]; then
  # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh" 2>/dev/null
  if command -v _jobs_req >/dev/null 2>&1; then
    if _jobs_req GET "/api/metrics/dora?days=$DAYS" > "$WORK/dora.json" 2>/dev/null \
       && [ -s "$WORK/dora.json" ] \
       && jq -e '.projects' "$WORK/dora.json" >/dev/null 2>&1; then
      DORA_JSON="$WORK/dora.json"
    else
      say "ledger read failed (/api/metrics/dora?days=$DAYS, http=${JOBS_HTTP:-none}) — falling back to logs/merge-conductor.log for the merge count"
    fi
  fi
fi

# ---- project -> repo, from the one registry that records it ------------------
: > "$WORK/repos.tsv"
if [ -x "$BIN/fleet-conf.sh" ]; then
  while read -r P; do
    [ -n "$P" ] || continue
    R=$("$BIN/fleet-conf.sh" "$P" repo 2>/dev/null) || R=""
    printf '%s\t%s\n' "$P" "$R" >> "$WORK/repos.tsv"
  done < <("$BIN/fleet-conf.sh" --projects 2>/dev/null)
fi

# >>> gh budget (BH-6974)
# Who spends the GitHub REST budget: bin/gh-budget-report.sh, run once, its
# JSON on stdout. The merge count it divides by is the one this digest already
# read, so the worker answers the dora route once. A report that fails is
# "github REST: n/a (error)" and one log line, never a crash and never a page.
GH_BUDGET="${DORA_GH_BUDGET:-1}"
GHB_FILE=""; GHB_STATUS=off
if [ "$GH_BUDGET" = 1 ]; then
  M=""
  [ -n "$DORA_JSON" ] && M=$(jq -r '.totals.merged // empty' "$DORA_JSON" 2>/dev/null)
  case "$M" in *[!0-9]*) M="" ;; esac
  GHB_ARGS=(--window "$WINDOW" --json)
  [ -n "$M" ] && GHB_ARGS+=(--merged "$M")
  [ "$LEDGER" = 1 ] || GHB_ARGS+=(--local)
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 "$BIN/gh-budget-report.sh" "${GHB_ARGS[@]}" > "$WORK/gh-budget.json" 2>/dev/null; GHB_RC=$?
  else
    "$BIN/gh-budget-report.sh" "${GHB_ARGS[@]}" > "$WORK/gh-budget.json" 2>/dev/null; GHB_RC=$?
  fi
  if [ "$GHB_RC" = 0 ] && jq -e '.totals' "$WORK/gh-budget.json" >/dev/null 2>&1; then
    GHB_FILE="$WORK/gh-budget.json"; GHB_STATUS=ok
  else
    GHB_STATUS=error
    say "gh budget report failed rc=$GHB_RC (bin/gh-budget-report.sh ${GHB_ARGS[*]}) — the digest says github REST: n/a"
  fi
fi
# <<< gh budget

# >>> conflicts alert (BH-6965)
# The rebuild-rate threshold for the conflicts alert: the settings row
# conflicts.rebuild_alert_per_100, then env DORA_CONFLICTS_REBUILD_ALERT_PER_100
# (also the conf row conf.dora-digest.dora_conflicts_rebuild_alert_per_100),
# then 40 — ph_knob's order (bin/lib/pr-health.sh). The row is read only when a
# settings client is loaded (the ledger read above loads bin/jobs-client.sh).
# CF_SRC says which one decided: row | env | default.
# shellcheck source=lib/pr-health.sh
. "$BIN/lib/pr-health.sh" 2>/dev/null || true
CF_ENV="${DORA_CONFLICTS_REBUILD_ALERT_PER_100:-}"
if command -v ph_knob >/dev/null 2>&1; then
  ph_knob conflicts.rebuild_alert_per_100 DORA_CONFLICTS_REBUILD_ALERT_PER_100 40 > "$WORK/cf-threshold" 2>>"$LOG"
  CF_TH=$(cat "$WORK/cf-threshold" 2>/dev/null)
  [ "${PH_KNOB_SRC:-}" = row ] && CF_SRC=row || CF_SRC=""
else
  CF_TH=""; CF_SRC=""
fi
if [ -z "$CF_SRC" ]; then
  case "$CF_ENV" in ''|*[!0-9]*) CF_TH=40; CF_SRC=default ;; *) CF_TH="$CF_ENV"; CF_SRC=env ;; esac
fi
# <<< conflicts alert

DATE_TAG=$(date -u +%F)
case "$WINDOW" in 24h) OUT_JSON="$OUTDIR/$DATE_TAG.json" ;; *) OUT_JSON="$OUTDIR/$DATE_TAG-$WINDOW.json" ;; esac
OUT_TXT="$OUTDIR/latest.txt"

DORA_SINCE="$SINCE_ISO" DORA_UNTIL="$NOW_ISO" DORA_WINDOW_ARG="$WINDOW" \
DORA_HOURS="$HOURS" DORA_DAYS="$DAYS" DORA_LEDGER_FILE="${DORA_JSON:-}" \
DORA_REPOMAP="$WORK/repos.tsv" DORA_MC_LOG="$H/logs/merge-conductor.log" \
DORA_BR_LOG="$H/logs/blocked-resolver.log" DORA_COST_DIR="${DORA_COST_DIR:-$H/state/cost}" \
DORA_BUILDS_DIR="${DORA_BUILDS_DIR:-$H/builds}" \
DORA_QUOTA_DIR="$QUOTA_DIR" DORA_LOGS_DIR="$H/logs" DORA_WARN_PCT="$WARN_PCT" \
DORA_MAX_ROWS="$MAX_ROWS" DORA_OUT_JSON="$OUT_JSON" DORA_OUT_TXT="$OUT_TXT" \
DORA_SENTINEL="$WORK/unmeasurable" \
DORA_ROP_LOG="$H/logs/repair-on-push.log" DORA_BR_STATE="$H/state/blocked-resolver" \
DORA_CONFLICTS_ALERT_PER_100="$CF_TH" DORA_CONFLICTS_ALERT_SRC="$CF_SRC" \
DORA_CONFLICTS_ALERT_FILE="$WORK/conflicts-alert" \
DORA_GH_BUDGET_FILE="$GHB_FILE" DORA_GH_BUDGET_STATUS="$GHB_STATUS" \
  python3 "$BIN/dora-digest.py"
RC=$?
if [ "$RC" -ne 0 ]; then
  say "digest FAILED rc=$RC (window $WINDOW) — nothing written"
  echo "$(STAMP) [dora-digest] the daily DORA/unit-economics digest crashed (rc=$RC, window $WINDOW) — nobody is reporting merges, \$/PR or account caps today. Re-run by hand: HARNESS=$H $BIN/dora-digest.sh --window $WINDOW --no-send --print" >> "$ALERTS"
  exit "$RC"
fi

# The one thing that pages: neither merge source could be read, so the digest
# has no output number at all. A quiet day and an unreadable fleet must not look
# alike. Once per day, the same flag discipline bin/outcome-metrics.sh uses.
# The digest itself says so by touching the sentinel, rather than this line
# re-reading the payload through jq: a box without jq must still page.
if [ -f "$WORK/unmeasurable" ]; then
  FLAG="$H/flags/alerted-dora-digest-$(date -u +%Y%m%d)"
  if [ ! -f "$FLAG" ]; then
    touch "$FLAG" 2>/dev/null
    echo "$(STAMP) [dora-digest] MERGES UNMEASURABLE for the $WINDOW window: the harness-jobs /api/metrics/dora route and $H/logs/merge-conductor.log were both unreadable, so today's digest reports n/a where the fleet's output belongs. Needs: HARNESS_SECRET in env/global.env + the worker reachable, or the conductor log back on this box." >> "$ALERTS"
  fi
fi

# >>> conflicts alert line (BH-6965)
# One line a UTC day when a project's rebuilds per 100 merges over the trailing
# 24 h is over the threshold. The digest writes the text (every project over,
# in one line); bin/alert-line.sh writes it (the alerts row now, then
# ALERTS.log on every path). The day flag goes through bin/lib/flags.sh
# (flag_has / flag_set; the file flags/alerted-dora-conflicts-<YYYYMMDD> on
# every path), set before the line, as the alert above orders it. The read is
# --cached (the local file): no worker request on a day the flag is already
# set, so a worker outage adds no ALERTS line of its own here.
if [ -s "$WORK/conflicts-alert" ]; then
  # shellcheck source=lib/flags.sh
  . "$BIN/lib/flags.sh" 2>/dev/null || true
  CFLAG="alerted-dora-conflicts-$(date -u +%Y%m%d)"
  if ! flag_has --cached "$CFLAG" 2>/dev/null; then
    flag_set "$CFLAG" on "dora-digest: conflicts alert sent" >/dev/null 2>&1
    HARNESS="$H" "$BIN/alert-line.sh" --id dora-conflicts "$(head -1 "$WORK/conflicts-alert")" >/dev/null 2>&1 || true
  fi
fi
# <<< conflicts alert line

TEXT=$(head -c "$TEXT_MAX" "$OUT_TXT" 2>/dev/null)
[ "$PRINT" = 1 ] && printf '%s\n' "$TEXT"

if [ "$SEND" = 1 ] && [ -n "$TEXT" ] && [ -x "$H/bin/beat.sh" ]; then
  "$H/bin/beat.sh" "$(jq -nc --arg akey "dora-digest:$WINDOW:$DATE_TAG" --arg l "$TEXT" \
    '{kind:"fleet_alert",project:"fleet",triaged:true,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  SENT=sent
else
  SENT=not-sent
fi

say "window=$WINDOW merged=$(jq -r '.fleet.merged // "n/a"' "$OUT_JSON" 2>/dev/null) repos=$(jq -r '.repos | length' "$OUT_JSON" 2>/dev/null) cost_usd=$(jq -r '.fleet.cost.total_usd // "n/a"' "$OUT_JSON" 2>/dev/null) json=$OUT_JSON beat=$SENT"
exit 0
