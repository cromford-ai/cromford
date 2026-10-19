#!/bin/bash
# bin/cost-reconcile.sh [--window 1h|24h|day [YYYY-MM-DD]] [--account <label>] [--dry-run]
#
# TWO MEASUREMENTS OF THE SAME MONEY, MADE TO AGREE (2026-09-14, cost fix 4).
#
# The account METER (Anthropic's own extra-usage figure, polled by
# bin/extra-usage-track.sh into extra_usage_snapshots) is the invoice. Our
# cost_rows are the per-call ledger every dashboard, PR cost and budget in this
# harness is built on. Nothing has ever compared them. The project-6 account ran
# to $23.8K of a $35K monthly cap with its meter unread for fifteen days, and the
# ledger said nothing was wrong, because the ledger cannot see an invoice and the
# invoice cannot see a lane.
#
# Per account, per window, this writes ONE row: what the meter moved, what our
# rows say we spent, and the gap. A gap over RECONCILE_GAP_PCT (default 10) on a
# metered account is one alert per day — that is the whole product. Everything
# else here exists to keep the comparison HONEST:
#
#   metered         the account is past its weekly credits, so the meter moves in
#                   cash and the comparison means something
#   credits-covered weekly utilization was under 100% at window start. Spend is
#                   subscription credits; the meter reads $0 and is RIGHT to. No
#                   dollar comparison is possible, and pretending otherwise would
#                   report a 100% gap every quiet week until nobody read it
#   no-login        the account holds no credential that can read its meter
#                   (project-2/project-3/project-4 run 1-year setup-tokens: HTTP 429 forever)
#   no-meter        no snapshot in the window — the poller itself is down
#   meter-reset     the meter zeroed inside the window, so last-minus-first is
#                   not a delta
#
# The account map (which cost_rows.auth_account labels and which jobs.box rows
# belong to which meter) is catalog/cost-accounts.json, not code.
#
# Kill: RECONCILE=0 in env/global.env, or the settings row
# switch.cost-reconcile-off[.<box>] (with no row, flags/cost-reconcile-off).
# Docs: docs/COST.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# +u around the source: an unbound reference inside global.env is FATAL under
# `set -u` and 2>/dev/null swallows the message, which is how a meter dies
# silently (see bin/extra-usage-track.sh's header for the five-day version).
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-cost-reconcile
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off cost-reconcile.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# Two cron lines, --window 1h hourly and --window 24h daily, meet at 04:50:
# the window is the one-run key (BH-7422), so neither turns the other away.
case " $* " in *" --window "*) LANE_RUN_KEY=${*#*--window }; LANE_RUN_KEY=w${LANE_RUN_KEY%% *} ;; *) LANE_RUN_KEY=w${RECONCILE_WINDOW:-24h} ;; esac
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit cost-reconcile
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    cost-reconcile
# BH-2433: the kill switch below is read through lane_switch, so a settings
# row switch.<name>[.<box>] settles it before the file does.
# shellcheck source=lib/lane-switch.sh
. "${HARNESS:-/root/harness}/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "${HARNESS:-/root/harness}/flags/$1" ]; }   # no lib: the file, as before

WINDOW="${RECONCILE_WINDOW:-24h}"; DAY=""; ONLY_ACCOUNT=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --window)  WINDOW="${2:-24h}"; shift; [ $# -gt 0 ] && shift
               case "$WINDOW" in day|day:*) : ;; *) continue ;; esac
               case "$WINDOW" in day:*) DAY="${WINDOW#day:}"; WINDOW=day ;; esac
               case "${1:-}" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) DAY="$1"; shift ;; esac ;;
    --account) ONLY_ACCOUNT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *)         echo "cost-reconcile.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

[ "${RECONCILE:-1}" = "0" ] && exit 0
lane_switch cost-reconcile-off file && exit 0

ACCOUNTS_FILE="${COST_ACCOUNTS_FILE:-$H/catalog/cost-accounts.json}"
LOG="$H/logs/cost-reconcile.log"
GAP_PCT="${RECONCILE_GAP_PCT:-10}"
# A FLOOR UNDER THE ALERT, because a percentage of a small number is noise: a
# $0.40 meter movement against $0.35 of rows is a 14% gap and means nothing. The
# alert is for money, so it starts at money.
MIN_METER="${RECONCILE_MIN_METER_USD:-1}"
# ...and a floor under the OBSERVED SPAN, for the same reason one notch over:
# the meter samples every 15 minutes and cost rows land every 10, so a window
# the meter only saw three minutes of is measuring clock skew, not money.
MIN_SPAN_MIN="${RECONCILE_MIN_SPAN_MIN:-30}"
PAGE_LIMIT="${RECONCILE_PAGE_LIMIT:-2000}"
MAX_PAGES="${RECONCILE_MAX_PAGES:-10}"
JOBS_LIMIT="${RECONCILE_JOBS_LIMIT:-500}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/state" "$H/flags" 2>/dev/null

command -v jq >/dev/null 2>&1 || { echo "$(STAMP) cost-reconcile: jq missing" >> "$LOG"; exit 0; }
[ -r "$ACCOUNTS_FILE" ] || { echo "$(STAMP) cost-reconcile: no account map at $ACCOUNTS_FILE — nothing to reconcile" >> "$LOG"; exit 0; }
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh" 2>/dev/null || true
command -v _jobs_req >/dev/null 2>&1 || { echo "$(STAMP) cost-reconcile: jobs-client unavailable — cannot read the ledger" >> "$LOG"; exit 0; }

# ── the window ──────────────────────────────────────────────────────────────
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
case "$WINDOW" in
  1h)  START=$(date -u -d '1 hour ago'  +%Y-%m-%dT%H:%M:%SZ); END="$NOW"; WKEY=1h ;;
  24h) START=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ); END="$NOW"; WKEY=24h ;;
  day) [ -n "$DAY" ] || DAY=$(date -u +%F)
       START="${DAY}T00:00:00Z"; END="${DAY}T23:59:59Z"; WKEY="day:$DAY" ;;
  *)   echo "cost-reconcile.sh: --window must be 1h, 24h or day [YYYY-MM-DD]" >&2; exit 2 ;;
esac

T=$(mktemp -d "${TMPDIR:-/tmp}/cost-reconcile.XXXXXX") || exit 0
trap 'rm -rf "$T"' EXIT

urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1" 2>/dev/null || printf '%s' "$1"; }
api_get() { _jobs_req GET "$1" 2>/dev/null; }

# Page BACKWARDS through cost_rows. The read side answers newest-first with a
# hard limit, so a window wider than one page is walked by re-asking with
# until = the oldest ts this page carried. The aggregator dedupes on
# (box, row_hash), which is what makes the inclusive bound safe.
# WHAT THE WALK MANAGED, on two globals, because the account aggregation below
# does not care and the blank-cost pass (BH-1020) cannot work without it: "no
# rows came back" and "the read did not complete" are different facts, and a
# pass that reports a quiet hour on a failed fetch is the alarm that goes silent
# exactly when the ledger breaks. FETCH_CAPPED says the same thing about the
# page ceiling: a walk stopped by MAX_PAGES counted a floor, not a total.
FETCH_OK=1; FETCH_CAPPED=0
fetch_rows() { # fetch_rows <query-without-until> <out-prefix>
  local q="$1" pfx="$2" until="$END" page=0 got oldest body
  FETCH_OK=1; FETCH_CAPPED=0
  while [ "$page" -lt "$MAX_PAGES" ]; do
    body=$(api_get "$q&until=$(urlenc "$until")&limit=$PAGE_LIMIT") || { FETCH_OK=0; break; }
    printf '%s' "$body" > "$pfx-$page.json"
    got=$(jq '(.cost_rows // []) | length' "$pfx-$page.json" 2>/dev/null || echo 0)
    case "$got" in ''|*[!0-9]*) got=0 ;; esac
    [ "$got" -ge "$PAGE_LIMIT" ] || break
    oldest=$(jq -r '[.cost_rows[].ts] | min // empty' "$pfx-$page.json" 2>/dev/null)
    # A page that cannot advance the cursor would page forever on rows that all
    # share one second; stopping is the honest end of the walk.
    [ -n "$oldest" ] && [ "$oldest" != "$until" ] || break
    until="$oldest"; page=$((page+1))
    [ "$page" -ge "$MAX_PAGES" ] && FETCH_CAPPED=1
  done
}

ACCOUNTS=$(jq -r '.accounts | keys[]' "$ACCOUNTS_FILE" 2>/dev/null)
[ -n "$ACCOUNTS" ] || { echo "$(STAMP) cost-reconcile: account map has no accounts" >> "$LOG"; exit 0; }

# The jobs page is fetched ONCE for every account: it is the same 500 rows, and
# the aggregator selects by box pattern.
api_get "/api/jobs?limit=$JOBS_LIMIT" > "$T/jobs.json" 2>/dev/null || : > "$T/jobs.json"

ROWS_OUT="$T/reconcile-rows.jsonl"; : > "$ROWS_OUT"
for A in $ACCOUNTS; do
  [ -n "$ONLY_ACCOUNT" ] && [ "$A" != "$ONLY_ACCOUNT" ] && continue
  AD="$T/$(printf '%s' "$A" | tr -dc 'A-Za-z0-9._-')"; mkdir -p "$AD"
  # 1. the meter
  api_get "/api/metrics/extra-usage?box=$(urlenc "$A")&limit=1000" > "$AD/meter.json" 2>/dev/null || : > "$AD/meter.json"
  # 2. our rows, by the account labels this account owns
  I=0
  while read -r LBL; do
    [ -n "$LBL" ] || continue
    fetch_rows "/api/metrics/cost-rows?auth_account=$(urlenc "$LBL")&since=$(urlenc "$START")" "$AD/rows$I"
    I=$((I+1))
  done < <(jq -r --arg a "$A" '.accounts[$a].auth_accounts // [] | .[]' "$ACCOUNTS_FILE" 2>/dev/null)
  # 3. the boxes whose UNLABELLED anthropic rows belong to this account —
  #    counted nowhere, reported as unattributed, never silently folded in.
  I=0
  while read -r BX; do
    [ -n "$BX" ] || continue
    fetch_rows "/api/metrics/cost-rows?box=$(urlenc "$BX")&since=$(urlenc "$START")" "$AD/boxrows$I"
    I=$((I+1))
  done < <(jq -r --arg a "$A" '.accounts[$a].boxes.cost_rows // [] | .[]' "$ACCOUNTS_FILE" 2>/dev/null)

  ROW=$(RC_ACCOUNT="$A" RC_DIR="$AD" RC_START="$START" RC_END="$END" RC_WKEY="$WKEY" \
        RC_JOBS="$T/jobs.json" RC_MAP="$ACCOUNTS_FILE" python3 - <<'PYEOF'
import datetime, fnmatch, glob, json, os

A     = os.environ["RC_ACCOUNT"]
D     = os.environ["RC_DIR"]
START = os.environ["RC_START"]
END   = os.environ["RC_END"]
WKEY  = os.environ["RC_WKEY"]

def load(p):
    try:
        with open(p) as fh:
            return json.load(fh)
    except Exception:
        return {}

cfg = load(os.environ["RC_MAP"])
acct = (cfg.get("accounts") or {}).get(A) or {}
anthropic = set(cfg.get("anthropic_runners") or ["claude"])
labels = set(acct.get("auth_accounts") or [])
job_pats = ((acct.get("boxes") or {}).get("jobs")) or []
# jobs.box and cost_rows.box are two names for ONE machine (the hub is
# box-hub in jobs and hub in cost rows). The no-double-count rule below
# keys on the machine, so it needs the translation or it can never fire for a
# box box — and every lane's spend gets counted twice, once from its
# job row and once from the cost rows that job wrote.
aliases = cfg.get("box_aliases") or {}

def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None

# ── the meter ───────────────────────────────────────────────────────────────
snaps = [s for s in (load(f"{D}/meter.json").get("snapshots") or [])
         if START <= (s.get("ts") or "") <= END]
snaps.sort(key=lambda s: s.get("ts") or "")
# A row with a reading is a measurement; a row with a status and no reading is a
# report that there was nothing to measure. They are different facts.
good = [s for s in snaps if num(s.get("extra_used_usd")) is not None
        and (s.get("status") or "ok") == "ok"]

state = note = None
m_start = m_end = m_delta = wk_start = wk_end = None
# Without a meter there is no span to narrow to, so the rows are reported over
# the whole window — visible, and never compared against a meter that is absent.
span_start, span_end = START, END
if not snaps:
    state, note = "no-meter", "no extra_usage_snapshots row in the window"
elif not good:
    statuses = {(s.get("status") or "unknown") for s in snaps}
    if statuses <= {"no-login"}:
        state, note = "no-login", "every poll in the window reported no readable login"
    else:
        state, note = "no-meter", "polls in the window carried no meter reading (%s)" % ",".join(sorted(statuses))
else:
    first, last = good[0], good[-1]
    m_start, m_end = num(first.get("extra_used_usd")), num(last.get("extra_used_usd"))
    wk_start, wk_end = num(first.get("weekly_pct")), num(last.get("weekly_pct"))
    m_delta = round(m_end - m_start, 2)
    # THE COMPARISON SPANS WHAT THE METER ACTUALLY SAW, not the window we asked
    # for. The project-6 meter's first sample ever was 19:31Z on 2026-09-14; a
    # 24h run that afternoon compared 40 minutes of meter against 24 hours of
    # rows and reported a -1146% gap. Both sides now cover the same clock, and
    # the span rides on the row so a reader never has to re-derive it.
    span_start, span_end = first.get("ts"), last.get("ts")
    if wk_start is not None and wk_start < 100:
        # THE HONEST CASE, and the common one. Under the weekly cap the account
        # spends CREDITS: the dollar meter does not move, and a $0 meter against
        # $600 of rows is not a discrepancy, it is the plan working.
        state = "credits-covered"
        note = "weekly utilization %.0f%% at window start — spend is subscription credits, the meter has no $ to compare" % wk_start
    elif m_end < m_start:
        state, note = "meter-reset", "the meter fell inside the window (weekly/monthly reset) — last-minus-first is not a delta"
    else:
        state = "metered"
        if len(good) < 2:
            note = "one sample in the window — a delta needs two"

# ── our own rows ────────────────────────────────────────────────────────────
seen = set()
rows_usd = 0.0
rows_n = 0
unattributed = 0.0
boxes_with_rows = set()

def walk(pattern, labelled):
    global rows_usd, rows_n, unattributed
    for path in sorted(glob.glob(pattern)):
        for r in (load(path).get("cost_rows") or []):
            key = (r.get("box"), r.get("row_hash"))
            if key in seen:
                continue
            seen.add(key)
            # Non-Anthropic runners (grok, openrouter, fireworks, codex) are on
            # other bills entirely; summing them against a Claude meter would
            # invent a gap out of a vendor we are not measuring.
            if (r.get("runner") or "") not in anthropic:
                continue
            # WHICH MACHINES PUSH ROWS is decided over the whole WINDOW, not the
            # meter span: a box that pushed at 09:58 and at 10:12 still pushes
            # rows at 10:05, and treating it as row-less for one span would add
            # its job total on top of rows it has already reported.
            boxes_with_rows.add(r.get("box"))
            ts = r.get("ts") or ""
            if not (span_start <= ts <= span_end):
                continue
            usd = num(r.get("cost_usd")) or 0.0
            acc = r.get("auth_account") or ""
            if acc in labels:
                rows_usd += usd
                rows_n += 1
            elif not labelled and acc in ("", "unknown"):
                unattributed += usd

walk(f"{D}/rows*-*.json", True)
walk(f"{D}/boxrows*-*.json", False)

# ── pool jobs that have no rows yet ─────────────────────────────────────────
# A machine with no cost_rows in this window still spent money, and its jobs row
# carries spent_usd, so it is counted HERE — and ONLY while it has no rows of its
# own. The moment a box pushes rows, the rows win and the same dollars stop being
# counted twice. Pool machines push their own rows since #337, so this half now
# covers the remainder it was always meant to: a machine SIGKILLed before its
# reap, and spend older than the row pipeline.
jobs_usd = 0.0
jobs_n = 0

def iso(v):
    try:
        return datetime.datetime.strptime(v, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except Exception:
        return None

sp_a, sp_b = iso(span_start), iso(span_end)
for j in (load(os.environ["RC_JOBS"]).get("jobs") or []):
    box = j.get("box") or ""
    if not any(fnmatch.fnmatch(box, p) for p in job_pats):
        continue
    # THE SAME MACHINE, UNDER ITS OTHER NAME. A box that pushes cost_rows has
    # already reported this spend per call; its job row is the same dollars with
    # less detail, and the rows win. This half of the sum is for pool machines
    # only, and it disappears the day they push rows of their own.
    if aliases.get(box, box) in boxes_with_rows:
        continue
    a, b = iso(j.get("created_at") or ""), iso(j.get("updated_at") or j.get("created_at") or "")
    if a is None or b is None or b < a:
        continue
    if b < sp_a or a > sp_b:
        continue
    spent = num(j.get("spent_usd")) or 0.0
    # PRORATED over the overlap, and stated as the approximation it is. A jobs
    # row carries one running total and no timeline, so a build that started
    # before the window would otherwise drop its whole spend into it. Linear is
    # an assumption; counting it all, or none of it, is a bigger one. Every
    # machine that pushes rows drops out of this sum entirely, so the
    # approximation shrinks as the row pipeline covers more of the fleet.
    life = (b - a).total_seconds()
    if life <= 0:
        share = 1.0
    else:
        overlap = (min(b, sp_b) - max(a, sp_a)).total_seconds()
        share = max(0.0, min(1.0, overlap / life))
    jobs_usd += spent * share
    jobs_n += 1

ours = round(rows_usd + jobs_usd, 2)
gap = gap_pct = None
if state == "metered" and m_delta is not None:
    gap = round(m_delta - ours, 2)
    if m_delta > 0:
        gap_pct = round(100.0 * gap / m_delta, 1)

out = {
    "account": A, "window_key": WKEY, "window_start": START, "window_end": END,
    "state": state, "meter_start_usd": m_start, "meter_end_usd": m_end,
    "meter_delta_usd": m_delta, "rows_usd": round(rows_usd, 2), "jobs_usd": round(jobs_usd, 2),
    "unattributed_usd": round(unattributed, 2), "rows_count": rows_n, "jobs_count": jobs_n,
    "gap_usd": gap, "gap_pct": gap_pct,
    "weekly_pct_start": wk_start, "weekly_pct_end": wk_end,
    "span_start": span_start, "span_end": span_end, "note": note,
}
print(json.dumps(out))
PYEOF
  ) || ROW=""
  [ -n "$ROW" ] || { echo "$(STAMP) cost-reconcile: [$A] aggregation failed" >> "$LOG"; continue; }

  STATE=$(printf '%s' "$ROW" | jq -r '.state // "unknown"')
  GAP=$(printf '%s' "$ROW" | jq -r '.gap_usd // "" | tostring')
  GAPP=$(printf '%s' "$ROW" | jq -r '.gap_pct // "" | tostring')
  MDELTA=$(printf '%s' "$ROW" | jq -r '.meter_delta_usd // "" | tostring')
  NOTE=$(printf '%s' "$ROW" | jq -r '.note // ""')

  # ── the alert ─────────────────────────────────────────────────────────────
  # Only on a metered account (the other states have no dollars to disagree
  # about), only above the money floor, once per account per day.
  ALERTED=0
  if [ "$STATE" = metered ] && [ -n "$GAPP" ] && [ "$GAPP" != null ]; then
    # The row decides, not the shell: every threshold is read from the
    # environment and every value from the JSON, so nothing here can be
    # mis-quoted into a comparison that silently passes.
    if printf '%s' "$ROW" | RC_MIN_METER="$MIN_METER" RC_GAP_PCT="$GAP_PCT" RC_MIN_SPAN="$MIN_SPAN_MIN" python3 -c '
import datetime, json, os, sys
r = json.load(sys.stdin)
def iso(v):
    try: return datetime.datetime.strptime(v or "", "%Y-%m-%dT%H:%M:%SZ")
    except Exception: return None
a, b = iso(r.get("span_start")), iso(r.get("span_end"))
span_min = (b - a).total_seconds() / 60 if a and b else 0
# A SHORT SPAN IS NOT A GAP. Rows are pushed every 10 minutes and the meter is
# sampled every 15, so over a few minutes the skew between the two clocks is
# most of the difference. Below the floor the comparison is not wrong, it is
# just not yet evidence, and an alert built on it is the alarm that always rings.
delta = abs(r.get("meter_delta_usd") or 0)
gap = abs(r.get("gap_pct") or 0)
sys.exit(0 if (span_min >= float(os.environ["RC_MIN_SPAN"])
               and delta >= float(os.environ["RC_MIN_METER"])
               and gap > float(os.environ["RC_GAP_PCT"])) else 1)
' 2>/dev/null; then
      AFLAG="$H/flags/alerted-cost-reconcile-$(printf '%s' "$A" | tr -dc 'A-Za-z0-9._-')-$(date -u +%Y%m%d)"
      if [ ! -f "$AFLAG" ]; then
        touch "$AFLAG" 2>/dev/null
        ALERTED=1
        MSG="COST RECONCILE [$A] $WKEY: the meter moved \$$MDELTA but our rows account for \$$(printf '%s' "$ROW" | jq -r '(.rows_usd + .jobs_usd)') — gap \$$GAP (${GAPP}%), over the ${GAP_PCT}% threshold. Either spend is running through a lane that writes no cost row, or the account map in catalog/cost-accounts.json is missing a label. Meter span $(printf '%s' "$ROW" | jq -r '.span_start') .. $(printf '%s' "$ROW" | jq -r '.span_end') (window $WKEY)."
        if [ -x "$H/bin/lane-alert.sh" ]; then
          "$H/bin/lane-alert.sh" cost-reconcile "$MSG" >/dev/null 2>&1 || \
            HARNESS="$H" "$H/bin/alert-line.sh" "[cost-reconcile] $MSG"
        else
          HARNESS="$H" "$H/bin/alert-line.sh" "[cost-reconcile] $MSG"
        fi
      fi
    fi
  fi

  ROW=$(printf '%s' "$ROW" | jq -c --argjson al "$ALERTED" '.alerted = $al')
  printf '%s\n' "$ROW" >> "$ROWS_OUT"
  # ONE line per (account, window), written BEFORE the push: the file is the
  # copy that survives a worker outage.
  echo "$(STAMP) cost-reconcile [$A] $WKEY $(printf '%s' "$ROW" | jq -r '"state=\(.state) meter_delta=$\(.meter_delta_usd // "n/a") rows=$\(.rows_usd) (\(.rows_count) rows) jobs=$\(.jobs_usd) (\(.jobs_count) jobs) unattributed=$\(.unattributed_usd) gap=$\(.gap_usd // "n/a") (\(.gap_pct // "n/a")%) alerted=\(.alerted)"')${NOTE:+ :: $NOTE}" >> "$LOG"
done

# ── the blank-cost flood ────────────────────────────────────────────────────
# >>> blank-cost alert
# WHO IS WRITING MONEY NOBODY CAN SEE (BH-1020). The account loop above compares
# dollars against a meter and can only do that for Anthropic. This pass asks a
# different question of the same rows, for every runner: how many calls
# SUCCEEDED and landed with an empty cost_usd. That is the shape the 2026-09-17
# audit found — 1,987 rows, about $3.5K in three days, from the codex-driven
# lanes whose tokens were captured and never priced — and nothing counted it.
#
# The write-time pricer (bin/lib/cost-row.sh's cost_row_price) is the fix; this
# is how the hub learns the fix is not reaching a box, or that a model is
# missing from catalog/model-prices.json. Both look identical from here, so the
# line names both.
#
# HOURLY ONLY. The threshold is "more than N in an hour"; running it on the 24h
# sweep would read a whole day's total as one hour's flood and page about a
# number that was never over anything.
BLANK_MAX="${RECONCILE_BLANK_ROWS_MAX:-20}"
case "$BLANK_MAX" in ''|*[!0-9]*) BLANK_MAX=20 ;; esac
if [ "$WKEY" = 1h ] && [ "$BLANK_MAX" -gt 0 ]; then
  BD="$T/blank"; mkdir -p "$BD"
  # No account filter and no box filter: a runner that writes blanks does it on
  # whichever box is out of sync, and the count is a fleet count.
  fetch_rows "/api/metrics/cost-rows?since=$(urlenc "$START")" "$BD/rows"
  CAPNOTE=""
  [ "$FETCH_CAPPED" = 1 ] && CAPNOTE=" pages=$MAX_PAGES capped"
  if [ "$FETCH_OK" != 1 ]; then
    # A READ THAT DID NOT COMPLETE IS NOT A QUIET HOUR. Saying `clean` here is
    # the one thing this pass must never do: the next hour re-reads the same
    # shape, and a flood that lasts an hour lasts the next one too.
    echo "$(STAMP) cost-reconcile blank-cost 1h unread — the cost-rows read did not complete, so this hour is evidence of nothing" >> "$LOG"
  else
    BLANK_TSV=$(RC_DIR="$BD" python3 - <<'PYEOF'
import glob, json, os

D = os.environ["RC_DIR"]
seen = set()
per = {}
models = {}

for path in sorted(glob.glob(f"{D}/rows-*.json")):
    try:
        with open(path) as fh:
            rows = json.load(fh).get("cost_rows") or []
    except Exception:
        continue
    for r in rows:
        # Dedupe on (box, row_hash) exactly as the account aggregation does —
        # the page walk's `until` bound is inclusive, so a row can arrive twice.
        key = (r.get("box"), r.get("row_hash"))
        if key in seen:
            continue
        seen.add(key)
        # A FAILED call was never billed, and a row whose rc we do not have is
        # not evidence that it was. Both stay out of a count that pages.
        if str(r.get("rc")) != "0":
            continue
        # Blank is NULL or empty, never 0: a row priced at 0.000000 is a vendor
        # saying the call was free, which is a measurement and not a hole.
        usd = r.get("cost_usd")
        if usd is not None and str(usd).strip() != "":
            continue
        runner = (r.get("runner") or "").strip() or "unknown"
        model = (r.get("model") or "").strip() or "unknown"
        per[runner] = per.get(runner, 0) + 1
        models.setdefault(runner, {})
        models[runner][model] = models[runner].get(model, 0) + 1

for runner in sorted(per):
    # The model to look up first: most rows, ties broken by name so two runs on
    # the same data name the same model.
    top = sorted(models[runner].items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
    print("%s\t%d\t%s" % (runner.replace("\t", " "), per[runner], top.replace("\t", " ")))
PYEOF
    ) || BLANK_TSV=""
    if [ -z "$BLANK_TSV" ]; then
      echo "$(STAMP) cost-reconcile blank-cost 1h clean$CAPNOTE" >> "$LOG"
    else
      while IFS=$'\t' read -r BRUN BNUM BMOD; do
        [ -n "$BRUN" ] && [ -n "$BNUM" ] || continue
        BFLAG="$H/flags/alerted-cost-blank-$(printf '%s' "$BRUN" | tr -c 'A-Za-z0-9._-' '_')-$(date -u +%Y%m%d)"
        BALERTED=0
        # STRICTLY greater — the ticket's word is "more than 20" — and once per
        # runner per UTC day, like every other daily alert here.
        [ "$BNUM" -gt "$BLANK_MAX" ] && [ ! -f "$BFLAG" ] && BALERTED=1
        # The log line is written FIRST and is written for every runner with a
        # blank row, alerting or not: it is the copy that proves the pass ran,
        # and it is where a count climbing toward the threshold is visible.
        echo "$(STAMP) cost-reconcile blank-cost 1h runner=$BRUN blank=$BNUM alerted=$BALERTED$CAPNOTE" >> "$LOG"
        if [ "$BALERTED" = 1 ]; then
          BMSG="BLANK COST [$BRUN] 1h: blank=$BNUM rc=0 rows from this runner landed with an empty cost_usd in the last hour (top model $BMOD), over the ${BLANK_MAX}-row threshold. That spend reads as \$0.00 on every cost view. Either the box writing them has not synced the write-time pricer (cost_row_price in bin/lib/cost-row.sh — check bin/harness-sync.sh ran there), or $BMOD has no rate in catalog/model-prices.json. The box's own [cost-parity] lines in ALERTS.log say which. Family note: docs/COST.md#cost-capture-parity."
          # The line is sent BEFORE the flag is touched, so a crash between the
          # two costs a duplicate line tomorrow rather than a page nobody gets.
          if [ -x "$H/bin/lane-alert.sh" ]; then
            "$H/bin/lane-alert.sh" cost-reconcile "$BMSG" >/dev/null 2>&1 || \
              HARNESS="$H" "$H/bin/alert-line.sh" "[cost-reconcile] $BMSG"
          else
            HARNESS="$H" "$H/bin/alert-line.sh" "[cost-reconcile] $BMSG"
          fi
          touch "$BFLAG" 2>/dev/null
        fi
      done <<EOF
$BLANK_TSV
EOF
    fi
  fi
fi
# <<< blank-cost alert

# >>> openrouter reconcile (BH-3983)
# THE OTHER INVOICE. The account loop above can only check Anthropic, because
# only Anthropic has an extra-usage meter. OpenRouter has its own: the hourly
# vendor_spend rows bin/vendor-spend-pull.sh writes. or_ledger_compare
# (bin/lib/openrouter-ledger.sh, BH-3998) puts that delta next to the sum of
# our runner=openrouter cost rows over the vendor's own span. This block
# alerts when the two disagree by more than RECONCILE_OR_GAP_PCT (15) AND
# RECONCILE_OR_MIN_USD (20), both strict, once a UTC day.
#
# DAILY ONLY (24h and day:*), so the hourly sweep never reads a partial day.
# RECONCILE_OR=0 turns it off. --account narrows only the account loop; this
# block ignores it. It sits after every early exit above (RECONCILE=0, the
# cost-reconcile-off switch, no jq, no account map, no jobs client, an empty
# account list), so those still end the run before it.
#
# scope=account is the whole OpenRouter account, product-app and personal keys
# included. OPENROUTER_RECONCILE_KEYS (key NAMES, never secrets) narrows it to
# the harness keys. Only state=ok can alert: unread is a failed read, never a
# quiet day, and no-meter / meter-reset have no delta to compare. The state
# word is the lib's, not the account loop's `metered` vocabulary.
#
# Every run that passes the gate writes ONE log line, whatever came back. The
# pushed row uses account "openrouter": the reconcile handler takes any label
# (worker/jobs/src/routes/usage.js:79). An account literally named openrouter
# in catalog/cost-accounts.json would share this block's day flag; none exists.
case "${RECONCILE_OR:-1}" in ''|*[!0-9]*) OR_ON=1 ;; *) OR_ON="${RECONCILE_OR:-1}" ;; esac
case "$WKEY" in 24h|day:*) : ;; *) OR_ON=0 ;; esac
if [ "$OR_ON" -ne 0 ]; then
  OR_PCT="${RECONCILE_OR_GAP_PCT:-15}"; case "$OR_PCT" in ''|*[!0-9]*) OR_PCT=15 ;; esac
  OR_MIN="${RECONCILE_OR_MIN_USD:-20}"; case "$OR_MIN" in ''|*[!0-9]*) OR_MIN=20 ;; esac
  # shellcheck source=lib/openrouter-ledger.sh
  . "$H/bin/lib/openrouter-ledger.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/openrouter-ledger.sh" 2>/dev/null
  if ! command -v or_ledger_compare >/dev/null 2>&1; then
    # A box whose bin/ sync has not landed the lib yet: one line, never an alert.
    echo "$(STAMP) cost-reconcile openrouter $WKEY state=no-lib alerted=0" >> "$LOG"
  else
    ORL=$(or_ledger_compare "$START" "$END" "${OPENROUTER_RECONCILE_KEYS:-}" 2>>"$LOG")
    # rc 1 is unread, and the line still carries what came back, so the rc is
    # not read here: the tokens are.
    ORL_scope=""; ORL_state=""; ORL_vendor_usd=""; ORL_rows_usd=""; ORL_rows_n=""
    ORL_unpriced_n=""; ORL_killed_n=""; ORL_span=""
    for tok in $ORL; do
      case "$tok" in
        scope=*|state=*|vendor_usd=*|rows_usd=*|rows_n=*|unpriced_n=*|killed_n=*|span=*)
          printf -v "ORL_${tok%%=*}" '%s' "${tok#*=}" ;;
      esac
    done
    OR_PARSED=1; [ -n "$ORL_state" ] || { OR_PARSED=0; ORL_state=unread; }
    OR_SPAN_A="${ORL_span%%..*}"; OR_SPAN_B="${ORL_span#*..}"
    # python decides, so the shell never compares floats.
    OR_TSV=$(ORS="$ORL_state" ORV="$ORL_vendor_usd" ORR="$ORL_rows_usd" ORP="$OR_PCT" ORM="$OR_MIN" python3 -c '
import os
try:
    assert os.environ["ORS"] == "ok"
    v, r = float(os.environ["ORV"]), float(os.environ["ORR"])
except Exception:
    print("n/a\tn/a\t0"); raise SystemExit
gap = v - r
pct = abs(gap) / v * 100 if v else (0.0 if r == 0 else 100.0)
over = abs(gap) > float(os.environ["ORM"]) and pct > float(os.environ["ORP"])
print("%.2f\t%.1f\t%d" % (gap, pct, 1 if over else 0))
' 2>/dev/null) || OR_TSV=$'n/a\tn/a\t0'
    IFS=$'\t' read -r OR_GAP OR_GAPP OR_OVER <<<"$OR_TSV"
    OR_ALERTED=0; OR_WOULD=""
    OR_FLAG="$H/flags/alerted-cost-reconcile-openrouter-$(date -u +%Y%m%d)"
    if [ "$OR_OVER" = 1 ] && [ "$DRY" = 1 ]; then
      OR_WOULD=" would alert"
    elif [ "$OR_OVER" = 1 ] && [ ! -f "$OR_FLAG" ]; then
      OR_MSG="OPENROUTER RECONCILE $WKEY (scope=$ORL_scope): OpenRouter billed \$$ORL_vendor_usd over $ORL_span, our openrouter rows price \$$ORL_rows_usd ($ORL_rows_n rows, $ORL_unpriced_n unpriced, $ORL_killed_n killed). Gap \$$OR_GAP ($OR_GAPP%), over $OR_PCT% and \$$OR_MIN. Run bin/openrouter-audit.sh --since $OR_SPAN_A --until $OR_SPAN_B to see where it went."
      [ "$ORL_scope" = account ] && OR_MSG="$OR_MSG This is the whole OpenRouter account, so product-app and personal keys are included. Set OPENROUTER_RECONCILE_KEYS to the harness key names to compare only those."
      # Sent BEFORE the flag is touched, like the blank-cost alert: a crash
      # between the two costs a duplicate line tomorrow, not a lost page.
      # Through bin/alert-line.sh (kind:alert), not the lane-alert path: BH-2364
      # caps that path's call count in this file
      # (tests/alert-line-wave-cost-health.bh-2314-test.sh E4).
      HARNESS="$H" "$H/bin/alert-line.sh" "[cost-reconcile] $OR_MSG"
      touch "$OR_FLAG" 2>/dev/null
      OR_ALERTED=1
    fi
    echo "$(STAMP) cost-reconcile openrouter $WKEY scope=${ORL_scope:-n/a} state=$ORL_state vendor=\$${ORL_vendor_usd:-n/a} rows=\$${ORL_rows_usd:-n/a} (${ORL_rows_n:-n/a}) unpriced=${ORL_unpriced_n:-n/a} gap=\$$OR_GAP ($OR_GAPP%) alerted=$OR_ALERTED$OR_WOULD" >> "$LOG"
    if [ "$OR_PARSED" = 1 ]; then
      jq -nc --arg wk "$WKEY" --arg ws "$START" --arg we "$END" --arg st "$ORL_state" \
        --arg v "$ORL_vendor_usd" --arg r "$ORL_rows_usd" --arg n "$ORL_rows_n" \
        --arg g "$OR_GAP" --arg gp "$OR_GAPP" --arg sa "$OR_SPAN_A" --arg sb "$OR_SPAN_B" \
        --argjson al "$OR_ALERTED" \
        --arg note "scope=$ORL_scope unpriced=${ORL_unpriced_n:-n/a} killed=${ORL_killed_n:-n/a}" \
        'def n: (tonumber? // null);
         {account: "openrouter", window_key: $wk, window_start: $ws, window_end: $we, state: $st,
          meter_delta_usd: ($v|n), rows_usd: ($r|n), rows_count: ($n|n), gap_usd: ($g|n),
          gap_pct: ($gp|n), span_start: (if $sa == "" then null else $sa end),
          span_end: (if $sb == "" then null else $sb end), alerted: $al, note: $note}' \
        >> "$ROWS_OUT" 2>/dev/null
    fi
  fi
fi
# <<< openrouter reconcile

# ── one request for the whole run ───────────────────────────────────────────
# The log line above is written first and is written either way: a worker outage
# costs a DB row, never the measurement.
if [ "$DRY" = 0 ] && [ -s "$ROWS_OUT" ]; then
  BODY="$T/body.json"
  jq -sc '{rows: .}' "$ROWS_OUT" > "$BODY" 2>/dev/null
  if [ -s "$BODY" ]; then
    # _jobs_req_file when the box has it (the body outgrows an argv element at
    # fleet scale), the string form on a box whose bin/ sync has not landed yet.
    if command -v _jobs_req_file >/dev/null 2>&1; then
      _jobs_req_file POST /api/metrics/reconcile "$BODY" >/dev/null 2>&1 || PUSH_FAILED=1
    else
      _jobs_req POST /api/metrics/reconcile "$(cat "$BODY")" >/dev/null 2>&1 || PUSH_FAILED=1
    fi
    [ "${PUSH_FAILED:-0}" = 1 ] && \
      echo "$(STAMP) cost-reconcile: the reconcile rows did not reach the worker (the log lines above are the copy)" >> "$LOG"
  fi
fi
exit 0
