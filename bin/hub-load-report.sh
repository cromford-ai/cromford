#!/bin/bash
# bin/hub-load-report.sh — the hub load baseline, in one fixed format, so a
# before and an after are measured the same way and can be diffed.
#
# usage: bin/hub-load-report.sh [--since <ISO>] [--until <ISO>] [--cap N] [--tick-window S]
#   --since, --until   UTC, YYYY-MM-DDTHH:MM[:SS]Z. since is in, until is out.
#                      Default: the last 3600 s.
#   --cap N            the runnable cap. Default: settings row
#                      hub_load.max_runnable, else 8.
#   --tick-window S    the conductor full-tick window. Default:
#                      MC_FULL_TICK_BUDGET_S, else 1500.
#   -h, --help         this text.
#
# Read-only. It writes no file and makes no GitHub call. The one read off the
# box is the settings row for the cap (bin/jobs-client.sh setting_get, as
# bin/hub-load-sample.sh reads it); --cap skips it. It reads under $HARNESS:
#   state/hub-load/*.tsv     (bin/hub-load-sample.sh) runnable p50/p90/max and
#                            the mean share per <name>= column (a sample that
#                            does not list a name counts 0 for it), top 10
#   logs/gh-calls/*.log      (bin/lib/gh-limit-logger.sh) calls per caller,
#                            top 10. The files are pruned at 180 min, so a
#                            window that starts before the oldest line is
#                            marked partial(oldest=<ISO>)
#   logs/merge-conductor.log TICK lines (mc_tick_metrics): secs p50/p90/max and
#                            over_window (secs > the window); FANIN
#                            merge-conductor lines (_fanin_report): runs, runs
#                            with any deferred:window, the share of PRs
#                            deferred:window, runs with every PR deferred:window;
#                            WINDOW_DEFERRED lines (mc_window_defer)
#
# Output (stdout, rc 0):
#   hub-load-report since=<ISO> until=<ISO>
#   load samples=N runnable_p50= runnable_p90= runnable_max= cap=N(row|default|flag) over_cap=yes|no|NA
#   lane_share <name>=<pct> ...
#   gh_calls total=N <caller>=n ... [partial(oldest=<ISO>)]
#   conductor_ticks n= secs_p50= secs_p90= secs_max= tick_window=S over_window=
#   conductor_fanin runs= deferred_runs= deferred_run_share=% deferred_pr_share=% all_deferred_runs= window_deferred_lines=
# A value with no input is NA, never 0. A source that is missing adds
# "(missing: <path>)" at the end of its line. A bad flag: usage on stderr, rc 2.
# Doc: docs/notes/2026-10-18-BH-7397-hub-load-report.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '/^# usage:/,/^#   -h, --help/{s/^# \{0,1\}//;s/^usage: [^ ]*/usage: bin\/hub-load-report.sh/;p}' "$0"; }
die() { echo "hub-load-report: $1" >&2; usage >&2; exit 2; }
iso_epoch() { # iso_epoch <ISO> — epoch seconds, or rc 1
  [ -n "$1" ] || return 1
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z$ ]] || return 1
  date -u -d "$1" +%s 2>/dev/null
}

SINCE=""; UNTIL=""; CAP=""; TW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since)       [ $# -ge 2 ] || die "--since needs a value"; SINCE=$(iso_epoch "$2") || die "bad --since: $2"; shift 2 ;;
    --until)       [ $# -ge 2 ] || die "--until needs a value"; UNTIL=$(iso_epoch "$2") || die "bad --until: $2"; shift 2 ;;
    --cap)         [[ "${2:-}" =~ ^[1-9][0-9]{0,6}$ ]] || die "bad --cap: ${2:-}"; CAP=$2; shift 2 ;;
    --tick-window) [[ "${2:-}" =~ ^[1-9][0-9]{0,6}$ ]] || die "bad --tick-window: ${2:-}"; TW=$2; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done
NOW=$(date -u +%s)
[ -n "$UNTIL" ] || UNTIL=$NOW
[ -n "$SINCE" ] || SINCE=$((UNTIL - 3600))
[ "$SINCE" -lt "$UNTIL" ] || die "--since must be before --until"

CAP_SRC=flag
if [ -z "$CAP" ]; then
  CAP=8; CAP_SRC=default
  . "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
    || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
  HENV=$(harness_env_dir "$H")
  # shellcheck disable=SC1091
  [ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
  # shellcheck source=bin/jobs-client.sh
  if . "$SELF/jobs-client.sh" 2>/dev/null; then
    v=$(setting_get hub_load.max_runnable 2>/dev/null | tr -d '[:space:]')
    [[ "$v" =~ ^[1-9][0-9]{0,6}$ ]] && { CAP=$v; CAP_SRC=row; }
  fi
fi
if [ -z "$TW" ]; then
  TW="${MC_FULL_TICK_BUDGET_S:-1500}"
  [[ "$TW" =~ ^[1-9][0-9]{0,6}$ ]] || TW=1500
fi

ISO() { date -u -d "@$1" +%FT%TZ; }
LOGTS() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
S_ISO=$(ISO "$SINCE"); U_ISO=$(ISO "$UNTIL"); S_LOG=$(LOGTS "$SINCE"); U_LOG=$(LOGTS "$UNTIL")
# q: the quantile rule of bin/hub-load-baseline.sh (linear interpolation over
# the sorted values, 2 decimals, trailing zeros cut).
AWK_Q='function f(x,   s) { s = sprintf("%.2f", x); sub(/\.?0+$/, "", s); return s }
function q(p,   i, lo, hi) { if (m == 0) return "NA"; i = p * (m - 1); lo = int(i); hi = (lo + 1 < m) ? lo + 1 : lo
  return f(v[lo] + (i - lo) * (v[hi] - v[lo])) }
function pct(a, b) { return (b > 0) ? f(a * 100 / b) "%" : "NA" }'

printf 'hub-load-report since=%s until=%s\n' "$S_ISO" "$U_ISO"

# ── load and lane share ──────────────────────────────────────────────────────
HL="$H/state/hub-load"
shopt -s nullglob
TSVS=("$HL"/*.tsv)
LOADV=$(cat "${TSVS[@]}" /dev/null 2>/dev/null | awk -F'\t' -v a="$S_ISO" -v b="$U_ISO" '
  $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ && $1 >= a && $1 < b {
    n++
    for (k = 2; k <= NF; k++) {
      e = index($k, "="); if (!e) continue
      key = substr($k, 1, e - 1); x = substr($k, e + 1)
      if (key == "runnable") { if (x ~ /^[0-9]+(\.[0-9]+)?$/) print "R", x }
      else if (key != "steal" && key != "forks_s" && key != "cpu" && key != "samples" && x ~ /^[0-9]+(\.[0-9]+)?$/) sh[key] += x
    }
  }
  END { print "N", n + 0; for (key in sh) print "S", key, sh[key] }')
SAMPLES=$(awk '$1 == "N" { print $2 }' <<<"$LOADV")
read -r P50 P90 PMAX < <(awk '$1 == "R" { print $2 }' <<<"$LOADV" | LC_ALL=C sort -g | awk "$AWK_Q"'
  { v[m++] = $1 } END { print q(0.5), q(0.9), (m ? f(v[m - 1]) : "NA") }')
OVER=NA
[ "$P90" != NA ] && OVER=$(awk -v p="$P90" -v c="$CAP" 'BEGIN { print (p + 0 > c + 0) ? "yes" : "no" }')
MISS=""; [ ${#TSVS[@]} -gt 0 ] || MISS=" (missing: state/hub-load/*.tsv)"
printf 'load samples=%s runnable_p50=%s runnable_p90=%s runnable_max=%s cap=%s(%s) over_cap=%s%s\n' \
  "$SAMPLES" "$P50" "$P90" "$PMAX" "$CAP" "$CAP_SRC" "$OVER" "$MISS"
if [ "$SAMPLES" -gt 0 ]; then
  SHARE=$(awk -v n="$SAMPLES" '$1 == "S" { printf "%s\t%.1f\n", $2, $3 / n }' <<<"$LOADV" \
    | LC_ALL=C sort -t "$(printf '\t')" -k2,2gr -k1,1 | head -10 | awk -F'\t' '{ printf " %s=%s", $1, $2 }')
  printf 'lane_share%s\n' "${SHARE:- NA}"
else
  printf 'lane_share NA\n'
fi

# ── GitHub calls ─────────────────────────────────────────────────────────────
GHF=("$H/logs/gh-calls"/*.log)
if [ ${#GHF[@]} -eq 0 ]; then
  printf 'gh_calls total=NA (missing: logs/gh-calls/*.log)\n'
else
  GH=$(cat "${GHF[@]}" 2>/dev/null | awk -v a="$SINCE" -v b="$UNTIL" '
    $1 ~ /^[0-9]+$/ { if (old == "" || $1 + 0 < old) old = $1 + 0
                      if ($1 + 0 >= a && $1 + 0 < b) { n++; c[$2]++ } }
    END { print "O", (old == "" ? "" : old); print "T", n + 0; for (k in c) print "C", c[k], k }')
  OLD=$(awk '$1 == "O" { print $2 }' <<<"$GH")
  TOP=$(awk '$1 == "C" { print $2 "\t" $3 }' <<<"$GH" | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 | head -10 \
    | awk -F'\t' '{ printf " %s=%s", $2, $1 }')
  PART=""
  if [ -z "$OLD" ]; then PART=" partial(oldest=NA)"
  elif [ "$OLD" -gt "$SINCE" ]; then PART=" partial(oldest=$(ISO "$OLD"))"; fi
  printf 'gh_calls total=%s%s%s\n' "$(awk '$1 == "T" { print $2 }' <<<"$GH")" "$TOP" "$PART"
fi

# ── the merge conductor ──────────────────────────────────────────────────────
MCL="$H/logs/merge-conductor.log"
if [ ! -r "$MCL" ]; then
  printf 'conductor_ticks n=NA secs_p50=NA secs_p90=NA secs_max=NA tick_window=%s over_window=NA (missing: logs/merge-conductor.log)\n' "$TW"
  printf 'conductor_fanin runs=NA deferred_runs=NA deferred_run_share=NA deferred_pr_share=NA all_deferred_runs=NA window_deferred_lines=NA (missing: logs/merge-conductor.log)\n'
  exit 0
fi
# One pass over the window's lines: T <secs> per TICK, F <en> <dw> <all> per
# FANIN merge-conductor run, W per WINDOW_DEFERRED.
MC=$(awk -v a="$S_LOG" -v b="$U_LOG" '
  { ts = $1 " " $2 }
  ts < a || ts >= b { next }
  $3 ~ /TICK$/ { for (k = 4; k <= NF; k++) if ($k ~ /^secs=[0-9]+$/) { print "T", substr($k, 6); break }; next }
  $3 == "FANIN" && $4 == "merge-conductor" && match($0, /: enumerated [0-9]+ accounted [0-9]+ \(.*\)$/) {
    s = substr($0, RSTART, RLENGTH); split(s, w, " "); en = w[3] + 0
    t = s; sub(/^[^(]*\(/, "", t); sub(/\)$/, "", t)
    n = split(t, p, ", "); dw = 0; one = 0
    for (i = 1; i <= n; i++) { c = p[i]; sub(/.* /, "", c); o = p[i]; sub(/ [^ ]*$/, "", o)
      if (o == "deferred:window") { dw += c; one++ } }
    print "F", en, dw, (n == 1 && one == 1 && dw == en && en > 0) ? 1 : 0; next }
  $4 == "WINDOW_DEFERRED:" { print "W" }' "$MCL" 2>/dev/null)
read -r TN T50 T90 TMAX TOVER < <(awk '$1 == "T" { print $2 }' <<<"$MC" | LC_ALL=C sort -g | awk -v w="$TW" "$AWK_Q"'
  { v[m++] = $1; if ($1 > w) o++ } END { print m + 0, q(0.5), q(0.9), (m ? f(v[m - 1]) : "NA"), o + 0 }')
printf 'conductor_ticks n=%s secs_p50=%s secs_p90=%s secs_max=%s tick_window=%s over_window=%s\n' "$TN" "$T50" "$T90" "$TMAX" "$TW" "$TOVER"
awk "$AWK_Q"'
  $1 == "F" { r++; en += $2; dw += $3; if ($3 > 0) d++; all += $4 }
  $1 == "W" { wl++ }
  END { printf "conductor_fanin runs=%d deferred_runs=%d deferred_run_share=%s deferred_pr_share=%s all_deferred_runs=%d window_deferred_lines=%d\n",
          r, d, pct(d, r), pct(dw, en), all, wl }' <<<"$MC"
exit 0
