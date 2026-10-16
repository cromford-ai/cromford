#!/bin/bash
# bin/review-tighten.sh — SDLC item 2: STEER BY OUTCOMES, NOT ACTIVITY.
#
# Everything else in this fleet steers on ACTIVITY. The sweep merges what was
# approved, the miner counts what reviewers said, the cost rollup prices what
# ran. None of it asks the only question that matters after a merge: is this
# repo's recent work HOLDING? bin/outcome-metrics.sh answers that per PR. This
# lane turns those answers into ONE mechanical decision:
#
#   a repo whose trailing-window revert/reopen rate crosses the threshold stops
#   auto-merging harness PRs, and parks them for the orchestrator's judged
#   merge, until the rate comes back down.
#
# IT ONLY EVER TIGHTENS. There is no branch in this file that merges anything,
# loosens any gate, widens any budget, or grants any autonomy. The two writes it
# makes are the flag (park / release) and its own measurement row. Auto-merging
# MORE because a repo looks healthy is exactly the decision a mechanical
# detector should never be trusted with, so it is not implemented — a repo at a
# 0% revert rate gets today's behaviour and nothing better.
#
# THE RATE
#   denominator  PRs the fleet MERGED inside the window, from the harness-jobs
#                merge ledger (kind=merge, status=merged) — the fleet's own
#                record of what it landed, never a GitHub re-scrape.
#   numerator    how many of THOSE PRs carry a `reverted` or `reopened` finding
#                in the metrics ledger. DISTINCT PRs, not finding rows: a PR
#                that was reverted AND reopened is one merge that did not hold,
#                and counting rows would let a rate exceed 1.
#   main-red     `merged_then_red` findings are counted and reported in the
#                evidence but are NOT in the numerator. The brief is the
#                revert/reopen rate; a red main is often the NEXT commit's
#                fault, and including it would tighten repos on someone else's
#                CI. Reported, not acted on.
#
#   The rate is deliberately BIASED LOW. Outcomes arrive days after a merge
#   (bin/outcome-metrics.sh rechecks for OUTCOME_RECHECK_DAYS), so the newest
#   merges in the window are counted as good simply because nothing has gone
#   wrong yet. That under-reports, which for a detector that can only park
#   things is the right direction to be wrong in.
#
# THRESHOLDS ARE DB-DRIVEN (review_gate_thresholds, scope = repo slug or '*').
# The constants below are the DOCUMENTED FALLBACK for an empty table or an
# unreachable worker, and they are the values the table ships empty against:
#   window 14 days · min 5 merges · tighten at >=20% · clear at <=10%
# Tighten and clear are two different numbers ON PURPOSE. One threshold would
# flap a repo in and out of the park as a single revert ages out of the window;
# between the two the gate HOLDS whatever it already decided.
#
# MIN_MERGES IS THE STARVATION GUARD. One revert out of one merge is a 100%
# rate and means nothing. Without a floor, the first bad outcome on a quiet
# repo would park its entire backlog.
#
# WHAT IT WRITES
#   * the SWITCH — a pause_flags row named review-tighten-<repo> through
#     bin/jobs-client.sh's flag rail, which write-throughs to flags/ so a repo
#     stays parked across a worker outage. bin/merge-sweep.sh and
#     bin/merge-queue.sh read it with review_tighten_active.
#   * the MEASUREMENT — a review_gate row per repo, EVERY run, including the
#     runs that change nothing. The console's OUTCOMES screen renders these.
#   * ONE ALERTS.log line per TRANSITION (park, and release), never per run and
#     never per PR — a lane that pages every ten minutes trains people to skim.
#
# IT NEVER ACTS BLIND. No merge ledger means no denominator, which means no
# measurement: the run logs why and exits, leaving every existing flag exactly
# as it was. A flag is never cleared on missing evidence, only on evidence that
# the rate came down.
#
# Cron: hub, daily 05:45Z — after bin/outcome-metrics.sh (Mondays 05:20Z) so a
# Monday run reads that morning's findings, and daily because the window slides
# every day whether or not new findings landed.
# Knobs: REVIEW_TIGHTEN_DRY=1 measures and prints, writes nothing.
#        REVIEW_TIGHTEN_LEDGER_MAX (500) how far back the merge ledger is read.
# Kill switch: the settings row switch.review-tighten-disabled[.<box>], read
# through lane_switch (bin/lib/lane-switch.sh); with no row, flag_active
# review-tighten-disabled (a pause_flags row reconciled into the file, then the
# file), or the bare file when the jobs client cannot be loaded.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-review-tighten
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off review-tighten.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit review-tighten
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    review-tighten
BIN="$(cd "$(dirname "$0")" && pwd)"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$H/logs/review-tighten.log"
ALERTS="$H/logs/ALERTS.log"
CSV="$H/logs/outcome-metrics.csv"
DRY="${REVIEW_TIGHTEN_DRY:-0}"
LEDGER_MAX="${REVIEW_TIGHTEN_LEDGER_MAX:-500}"

# The documented code fallback. Kept as four named constants rather than inline
# numbers so a reader can see at a glance what the table is overriding.
FB_WINDOW=14
FB_MIN_MERGES=5
FB_TIGHTEN=0.20
FB_CLEAR=0.10

mkdir -p "$H/logs" "$H/state" "$H/locks" "$H/flags" 2>/dev/null

# global.env carries HARNESS_SECRET; cron does not source it. Before the kill
# switch, because the kill switch is a flag lookup and the lookup wants the
# coordination client (the ordering merge-sweep.sh and outcome-metrics.sh use).
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    review-tighten
# shellcheck source=/dev/null
[ -r "$BIN/jobs-client.sh" ] && . "$BIN/jobs-client.sh"
# shellcheck source=lib/lane-switch.sh
. "$BIN/lib/lane-switch.sh" || exit 1
lane_switch review-tighten-disabled && exit 0
if command -v flock >/dev/null 2>&1; then
  exec 9>"$H/locks/review-tighten.lock"; flock -n 9 || exit 0
fi

WORK=$(mktemp -d /tmp/review-tighten-XXXXXX) || exit 1
trap 'rm -rf "$WORK"' EXIT

# ── 1. The denominator: what the fleet merged ────────────────────────────────
# No client, no ledger, or an empty ledger all mean the same thing here: this
# run has no denominator and therefore no measurement. It changes nothing.
MERGES="$WORK/merges.tsv"; : > "$MERGES"
if command -v job_ledger_list >/dev/null 2>&1; then
  job_ledger_list merge "$LEDGER_MAX" 2>/dev/null \
    | awk -F'\t' 'NF>=4 && $2=="merged" && $1 ~ /^https:\/\/github\.com\/[^ ]+\/pull\/[0-9]+/' \
    > "$MERGES"
fi
if [ ! -s "$MERGES" ]; then
  echo "$(STAMP) no merged-PR ledger available — nothing measured, every gate left exactly as it was" >> "$LOG"
  exit 0
fi

# ── 2. The numerator's raw material: the outcome findings ────────────────────
# DB first, because that is where the metrics ledger lives now; the CSV
# bin/outcome-metrics.sh writes FIRST is the fallback, so a worker outage
# degrades the source and never the measurement. Which one was used is logged.
# BH-7123 wave B: a merge judged under review.mode cowboy or off is a sprint,
# not a signal. bin/lib/review-judged.sh reads the hub's lead report of each
# merged PR (else the verdict row's report: token); a cowboy/off merge leaves
# both the numerator and the denominator, so a sprint never teaches the lane to
# tighten. Unreachable = kept, as before.
CB_SKIPPED=0
if . "$BIN/lib/review-judged.sh" 2>/dev/null && command -v rj_pr_mode >/dev/null 2>&1; then
  KEEP="$WORK/merges.keep"; : > "$KEEP"
  while IFS=$'\t' read -r PRU PRREST; do
    [ -n "$PRU" ] || continue
    PRREPO=$(sed -E 's|^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+).*|\1|' <<<"$PRU")
    PRNUM=$(sed -E 's|^https://github\.com/[^/]+/[^/]+/pull/([0-9]+).*|\1|' <<<"$PRU")
    case "$(rj_pr_mode "$PRREPO" "$PRNUM" 2>/dev/null)" in
      cowboy|off) CB_SKIPPED=$((CB_SKIPPED+1)); continue ;;
    esac
    printf '%s\t%s\n' "$PRU" "$PRREST" >> "$KEEP"
  done < "$MERGES"
  mv -f "$KEEP" "$MERGES"
  if [ ! -s "$MERGES" ]; then
    echo "$(STAMP) every merged PR in the ledger was judged under cowboy/off (cowboy_skipped=$CB_SKIPPED) — nothing measured, every gate left exactly as it was" >> "$LOG"
    exit 0
  fi
fi

OUTCOMES="$WORK/outcomes.tsv"; : > "$OUTCOMES"
OUT_SRC="ledger"
if command -v metric_outcomes_list >/dev/null 2>&1; then
  metric_outcomes_list 1000 2>/dev/null > "$OUTCOMES"
fi
if [ ! -s "$OUTCOMES" ] && [ -s "$CSV" ]; then
  OUT_SRC="csv"
  # date,repo,pr,outcome,evidence -> repo,pr,outcome,day. python's csv reader,
  # because the evidence column is free text assembled from commit subjects.
  python3 - "$CSV" > "$OUTCOMES" <<'PYF' 2>/dev/null
import csv, sys
with open(sys.argv[1], newline="") as fh:
    for r in csv.DictReader(fh):
        repo = (r.get("repo") or "").strip()
        pr = (r.get("pr") or "").strip()
        out = (r.get("outcome") or "").strip()
        if repo and pr and out:
            print("\t".join([repo, pr, out, (r.get("date") or "-").strip()]))
PYF
fi
[ -s "$OUTCOMES" ] || OUT_SRC="empty"

# ── 3. Resolve each repo's thresholds, then measure it against them ──────────
# The thresholds come first because the WINDOW is one of them: a repo with its
# own scope row can be measured over a different number of days than the fleet
# default, and the cutoff cannot be computed before that is known.
REPOS=$(sed -E 's|^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+.*|\1|' "$MERGES" | sort -u)
WINDOWS="$WORK/windows.tsv"; : > "$WINDOWS"
declare -A TH_WIN TH_MIN TH_TIGHTEN TH_CLEAR TH_SCOPE
for REPO in $REPOS; do
  W="$FB_WINDOW"; M="$FB_MIN_MERGES"; T="$FB_TIGHTEN"; C="$FB_CLEAR"; SC="fallback"
  if command -v review_gate_thresholds >/dev/null 2>&1; then
    if ROW=$(review_gate_thresholds "$REPO" 2>/dev/null); then
      IFS=$'\t' read -r R_SCOPE R_W R_M R_T R_C <<<"$ROW"
      # A row with a field the worker somehow let through empty falls back
      # FIELD BY FIELD rather than wholesale: a missing clear_rate must not
      # silently restore a window somebody deliberately changed.
      [ -n "${R_W:-}" ] && W="$R_W"
      [ -n "${R_M:-}" ] && M="$R_M"
      [ -n "${R_T:-}" ] && T="$R_T"
      [ -n "${R_C:-}" ] && C="$R_C"
      [ -n "${R_SCOPE:-}" ] && SC="$R_SCOPE"
    fi
  fi
  case "$W" in ''|*[!0-9]*) W="$FB_WINDOW" ;; esac
  case "$M" in ''|*[!0-9]*) M="$FB_MIN_MERGES" ;; esac
  TH_WIN[$REPO]="$W"; TH_MIN[$REPO]="$M"; TH_TIGHTEN[$REPO]="$T"; TH_CLEAR[$REPO]="$C"; TH_SCOPE[$REPO]="$SC"
  CUT=$(date -u -d "$W days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$W"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  printf '%s\t%s\n' "$REPO" "$CUT" >> "$WINDOWS"
done

# One python pass over both ledgers. Prints repo, merges, bad, red, rate.
COUNTS="$WORK/counts.tsv"
python3 - "$MERGES" "$OUTCOMES" "$WINDOWS" > "$COUNTS" <<'PYF'
import sys

merges_f, outcomes_f, windows_f = sys.argv[1:4]

def repo_of(pr):
    # https://github.com/<owner>/<name>/pull/<n> -> "<owner>/<name>"
    parts = pr.split("/")
    return "/".join(parts[3:5]) if len(parts) >= 6 else ""

windows = {}
for line in open(windows_f):
    p = line.rstrip("\n").split("\t")
    if len(p) == 2 and p[1]:
        windows[p[0]] = p[1]

# The merged set, per repo, inside that repo's own window. A ledger row with no
# timestamp is EXCLUDED rather than assumed recent: it would inflate a
# denominator with a merge nobody can place in time.
merged = {r: set() for r in windows}
for line in open(merges_f):
    p = line.rstrip("\n").split("\t")
    if len(p) < 4:
        continue
    pr, updated = p[0], p[3]
    r = repo_of(pr)
    cut = windows.get(r)
    if not cut or not updated or updated == "-":
        continue
    if updated >= cut:
        merged[r].add(pr)

# Numerator: DISTINCT merged PRs carrying a revert/reopen finding. main-red is
# counted separately and reported, never added to the rate.
BAD = {"reverted", "reopened"}
bad = {r: set() for r in windows}
red = {r: set() for r in windows}
try:
    fh = open(outcomes_f)
except OSError:
    fh = []
for line in fh:
    p = line.rstrip("\n").split("\t")
    if len(p) < 3:
        continue
    repo, pr, outcome = p[0], p[1], p[2]
    # The finding's own repo field is ignored in favour of the PR url's: the
    # two agree today, and the url is the key the denominator is built on.
    r = repo_of(pr) or repo
    if r not in merged or pr not in merged[r]:
        continue
    if outcome in BAD:
        bad[r].add(pr)
    elif outcome == "merged_then_red":
        red[r].add(pr)

for r in sorted(windows):
    n = len(merged[r])
    b = len(bad[r])
    rate = (b / n) if n else 0.0
    print("\t".join([r, str(n), str(b), str(len(red[r])), "%.4f" % rate]))
PYF

# ── 4. Decide, one repo at a time ────────────────────────────────────────────
TIGHTENED=0; CLEARED=0; HELD=0; MEASURED=0
while IFS=$'\t' read -r REPO N BAD RED RATE; do
  [ -n "$REPO" ] || continue
  MEASURED=$((MEASURED+1))
  W="${TH_WIN[$REPO]}"; M="${TH_MIN[$REPO]}"; T="${TH_TIGHTEN[$REPO]}"
  C="${TH_CLEAR[$REPO]}"; SC="${TH_SCOPE[$REPO]}"

  ACTIVE=0
  command -v review_tighten_active >/dev/null 2>&1 && review_tighten_active "$REPO" && ACTIVE=1

  # awk rather than bash arithmetic: these are rates, and bash has no floats.
  if [ "$N" -lt "$M" ]; then
    DECISION=insufficient
  elif awk -v r="$RATE" -v t="$T" 'BEGIN{exit !(r >= t)}'; then
    DECISION=tighten
  elif awk -v r="$RATE" -v c="$C" 'BEGIN{exit !(r <= c)}'; then
    DECISION=clear
  else
    DECISION=hold
  fi

  PCT=$(awk -v r="$RATE" 'BEGIN{printf "%.0f", r*100}')
  EVIDENCE="$BAD of $N PRs merged in the last ${W}d were reverted or reopened (${PCT}%); ${RED} also turned main red; thresholds tighten>=${T} clear<=${C} min_merges=${M} from ${SC}"

  WANT="$ACTIVE"
  case "$DECISION" in
    tighten) WANT=1 ;;
    clear)   WANT=0 ;;
    # hold and insufficient leave the switch exactly where it is. A repo that
    # went quiet does not get released just because nothing merged.
  esac

  if [ "$DRY" = 1 ]; then
    echo "$(STAMP) DRY $REPO merges=$N bad=$BAD red=$RED rate=$RATE decision=$DECISION active=$ACTIVE want=$WANT" >> "$LOG"
  else
    command -v review_gate_put >/dev/null 2>&1 && \
      review_gate_put "$REPO" "$WANT" "$RATE" "$BAD" "$N" "$W" "$T" "$C" "$M" "$SC" "$DECISION" "$EVIDENCE" \
      >/dev/null 2>&1 || true
    if [ "$WANT" != "$ACTIVE" ] && command -v review_tighten_set >/dev/null 2>&1; then
      if [ "$WANT" = 1 ]; then
        review_tighten_set "$REPO" on "$EVIDENCE" >/dev/null 2>&1 || true
        TIGHTENED=$((TIGHTENED+1))
        echo "$(STAMP) [review-tighten] $REPO TIGHTENED: $EVIDENCE. Harness PRs on this repo now PARK instead of auto-merging — bin/merge-sweep.sh and bin/merge-queue.sh skip them until the rate comes down, so they need a judged merge. This is a POLICY park, not a defect: the resolver deliberately does not rebuild its way out of it, because a rebuild would not move the revert rate. Clears itself when the rate is at or under ${C}; to release it: bin/jobs-client.sh review-tighten-set $REPO off \"<why>\"." >> "$ALERTS"
      else
        review_tighten_set "$REPO" off "$EVIDENCE" >/dev/null 2>&1 || true
        CLEARED=$((CLEARED+1))
        echo "$(STAMP) [review-tighten] $REPO RELEASED: $EVIDENCE. Auto-merge for this repo's harness PRs is back on." >> "$ALERTS"
      fi
    else
      case "$DECISION" in hold|insufficient) HELD=$((HELD+1)) ;; esac
    fi
  fi
done < "$COUNTS"

echo "$(STAMP) measured=$MEASURED tightened=$TIGHTENED cleared=$CLEARED held=$HELD outcomes_source=$OUT_SRC cowboy_skipped=$CB_SKIPPED$([ "$DRY" = 1 ] && echo " dry=1")" >> "$LOG"
exit 0
