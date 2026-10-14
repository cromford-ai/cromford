#!/bin/bash
# bin/prequeue-learned.sh — the learned list for the pre-queue gate (BH-6335):
# the tests/*.sh suites that failed merge-queue batches most often lately.
#
# WHY. The pre-queue gate (BH-4545) runs the suites the impact map selects for a
# PR's diff. On 2026-10-12 merge-queue batches failed on suites the map never
# selected for the PR that broke them. This lane keeps, per failed batch run of
# harness-ci.yml, the list of suites that failed in it. `--list` counts them over
# a window, and the conductor hook (bin/lib/mc-prequeue.d/learned.sh) passes the
# frequent ones to the gate as `learned` suites.
#
# usage:
#   prequeue-learned.sh --refresh                       (hub cron lane, :23/:53)
#   prequeue-learned.sh --list [--why] [--harness <dir>]
#
# --refresh, PER TICK, each step a stop when it fails, rc 0 on every path:
#   1. bin/lib/gh-budget.sh says the bucket is low: one log line, no read.
#   2. at most PREQUEUE_LEARNED_PAGES pages (100 runs each) of the completed
#      pull_request runs of harness-ci.yml created in the last
#      PREQUEUE_LEARNED_DAYS days, through gh_ci_api. Kept: head_branch starting
#      mergify/merge-queue/ and conclusion failure. A page that is unreadable or
#      not JSON: one log line, nothing written.
#   3. a run with a record is never read again. The rest, oldest first, at most
#      PREQUEUE_LEARNED_MAX a tick; the others are counted `deferred`.
#   4. per run, flaky_run_tests_strict (bin/lib/flaky.sh). rc 0: the P-tagged
#      names matching ^tests/(mc/)?[A-Za-z0-9._-]+\.sh$, deduped, written as the
#      record (tmp + mv). Any other rc: one strike in runs/<id>.strikes; the
#      third strike writes the record with `unreadable` and no suite line, so a
#      log that cannot be read is not read every tick for the whole window. A
#      record that cannot be written is one log line; the run is read again.
#   5. records and strike files created more than 30 days before NOW are pruned.
#   6. one log line to logs/prequeue-learned.log:
#      prequeue-learned: failed-batches=<n> recorded=<k> unread=<u> deferred=<d> pages=<p>
#      n = failed batch runs in the pages read; k = records written this tick
#      that hold data; u = log reads that failed this tick (strikes and the
#      unreadable records); d = runs left for a later tick; p = pages read.
#
# --list (the conductor hook's reader; never reads GitHub):
#   counts, per suite, the records created within PREQUEUE_LEARNED_DAYS days of
#   NOW. A record with a bad head line is skipped, with one stderr line that
#   counts them. An `unreadable` record counts nothing. Kept: count >=
#   PREQUEUE_LEARNED_MIN. Sorted by count descending, then name ascending; the
#   first PREQUEUE_LEARNED_TOP. Prints one comma-joined line, or nothing.
#   --why prints `<count>\t<suite>` rows instead, for EVERY suite in the window
#   (no MIN, no TOP cut), in the same order: the reasons behind the list.
#   Any read problem: rc 0 and no output, so the hook adds nothing.
#   --harness <dir> names the root (default $HARNESS, else /root/harness).
#
# RECORD FORMAT, one file per run, $H/state/prequeue-learned/runs/<run_id>:
#   run <run_id> created <epoch> attempt <n> [unreadable]
#   tests/a.sh
#   tests/mc/b.sh
# Strike file, runs/<run_id>.strikes: `strikes <n> created <epoch>`.
#
# KNOBS (lane prequeue-learned, catalog/lanes.d/prequeue-learned.json; a
# settings row, then env, then the default here; a bad value is the default):
#   PREQUEUE_LEARNED_MIN    20  a suite must fail this many distinct batches
#   PREQUEUE_LEARNED_DAYS    7  the window, for --list and the --refresh read
#   PREQUEUE_LEARNED_TOP    10  at most this many suites on the list
#   PREQUEUE_LEARNED_PAGES   5  run-list pages read per tick
#   PREQUEUE_LEARNED_MAX    20  run logs read per tick
#   PREQUEUE_LEARNED_REPO       the repo read (default HARNESS_REPO); not settable
# Worst case per tick: PAGES list reads + MAX log reads (each log read is the
# log and one jobs page).
# Kill switch: bin/harness-ctl.sh off prequeue-learned (flags/lane-off-prequeue-learned)
# stops --refresh. --list still reads what is on disk.
# Tests: tests/prequeue-learned.bh-6335-test.sh
set -uo pipefail
MODE=""; WHY=""; HAR=""
usage() { echo "usage: prequeue-learned.sh --refresh | --list [--why] [--harness <dir>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --refresh) MODE=refresh ;;
    --list) MODE=list ;;
    --why) WHY=1 ;;
    --harness) [ $# -ge 2 ] || usage; HAR="$2"; shift ;;
    -h|--help) sed -n '2,70p' "$0"; exit 0 ;;
    *) usage ;;
  esac
  shift
done
[ -n "$MODE" ] || usage
H="${HAR:-${HARNESS:-/root/harness}}"
export HARNESS="$H"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; [ -n "$BIN" ] || BIN="$H/bin"
NOW="${NOW:-$(date +%s)}"
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac
RUNS_DIR="$H/state/prequeue-learned/runs"
KEEP_DAYS=30
HEAD_RE='^run [0-9]+ created [0-9]+ attempt [0-9]+( unreadable)?$'
SUITE_RE='^tests/(mc/)?[A-Za-z0-9._-]+\.sh$'

# knob <ENV> <default> — a positive integer: lane_knob (row, env, registry
# default) when the lane gate is loaded, else the env, else the default.
knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob prequeue-learned "$1" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*|0) v="$2" ;; esac
  printf '%s' "$v"
}

# list_main — the --list reader. Nothing here leaves this box.
list_main() {
  local min days top cut files=() f out
  min=$(knob PREQUEUE_LEARNED_MIN 20)
  days=$(knob PREQUEUE_LEARNED_DAYS 7)
  top=$(knob PREQUEUE_LEARNED_TOP 10)
  cut=$(( NOW - days * 86400 ))
  [ -d "$RUNS_DIR" ] || return 0
  for f in "$RUNS_DIR"/[0-9]*; do
    case "$f" in *.strikes|*.tmp) continue ;; esac
    [ -f "$f" ] && files+=("$f")
  done
  [ ${#files[@]} -gt 0 ] || return 0
  # One awk over every record: rows `<count>\t<suite>`, and a last row
  # `#bad\t<n>` for the records with a bad head line.
  out=$(awk -v cut="$cut" -v hre="$HEAD_RE" -v sre="$SUITE_RE" '
    FNR == 1 {
      use = 0; split("", seen)
      if ($0 !~ hre) { bad++; next }
      if ($4 + 0 >= cut && $0 !~ / unreadable$/) use = 1
      next
    }
    use && $0 ~ sre && !($0 in seen) { seen[$0] = 1; c[$0]++ }
    END { for (s in c) printf "%d\t%s\n", c[s], s; printf "#bad\t%d\n", bad + 0 }
  ' "${files[@]}" 2>/dev/null) || return 0
  local nbad
  nbad=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "#bad" {print $2}')
  [ "${nbad:-0}" -gt 0 ] 2>/dev/null \
    && echo "prequeue-learned: skipped $nbad record(s) with a bad head line in $RUNS_DIR" >&2
  out=$(printf '%s\n' "$out" | grep -v '^#bad' | grep -v '^$' | sort -t "$(printf '\t')" -k1,1nr -k2,2)
  [ -n "$out" ] || return 0
  if [ -n "$WHY" ]; then
    printf '%s\n' "$out"
  else
    out=$(printf '%s\n' "$out" | awk -F'\t' -v m="$min" '$1 + 0 >= m {print $2}' | head -n "$top" | paste -sd, -)
    [ -n "$out" ] && printf '%s\n' "$out"
  fi
  return 0
}

if [ "$MODE" = list ]; then
  # HARNESS is the harness named, so lane_knob reads ITS settings rows.
  # shellcheck disable=SC1091
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$BIN/lib/lane-gate.sh" 2>/dev/null || true
  list_main
  exit 0
fi

# ── --refresh ────────────────────────────────────────────────────────────────
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$BIN/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# >>> lane gate (BH-1165)
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit prequeue-learned
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply prequeue-learned
for _L in gh-budget.sh gh-ci-read.sh gh-repo-token.sh flaky.sh; do
  # shellcheck source=/dev/null
  if [ -r "$BIN/lib/$_L" ]; then . "$BIN/lib/$_L"; elif [ -r "$H/bin/lib/$_L" ]; then . "$H/bin/lib/$_L"; fi
done
LOG="$H/logs/prequeue-learned.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) $*" >> "$LOG" 2>/dev/null; return 0; }
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$BIN/lib/deployment.sh}" 2>/dev/null || { log "prequeue-learned: deployment.sh unreadable — nothing read"; exit 0; }  # BH-4080: HARNESS_REPO
REPO="${PREQUEUE_LEARNED_REPO:-$HARNESS_REPO}"
[ -n "$REPO" ] || { log "prequeue-learned: no repo (PREQUEUE_LEARNED_REPO, HARNESS_REPO) — nothing read"; exit 0; }
MAX=$(knob PREQUEUE_LEARNED_MAX 20)
DAYS=$(knob PREQUEUE_LEARNED_DAYS 7)
PAGES=$(knob PREQUEUE_LEARNED_PAGES 5)
SINCE=$(date -u -d "@$(( NOW - DAYS * 86400 ))" '+%Y-%m-%dT%H:%M:%SZ')

# 1. the GitHub budget
if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low prequeue-learned; then
  log "prequeue-learned: skipped, the GitHub API budget is low (bin/lib/gh-budget.sh) — no reads this tick"
  exit 0
fi
if ! command -v gh_ci_api >/dev/null 2>&1 || ! command -v flaky_run_tests_strict >/dev/null 2>&1; then
  log "prequeue-learned: gh-ci-read.sh or flaky.sh not loaded — nothing read"
  exit 0
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/prequeue-learned.XXXXXX") || { log "prequeue-learned: mktemp failed — nothing read"; exit 0; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$RUNS_DIR" 2>/dev/null || { log "prequeue-learned: cannot create $RUNS_DIR — nothing read"; exit 0; }
command -v gh_repo_use_token >/dev/null 2>&1 && { gh_repo_use_token "$REPO" 2>/dev/null \
  || { log "prequeue-learned: repo=$REPO: no token can read it — nothing read"; exit 0; }; }

# 2. the run list
echo '[]' > "$TMP/runs"; NPG=0
for (( pg = 1; pg <= PAGES; pg++ )); do
  if ! gh_ci_api "$REPO" -X GET "repos/$REPO/actions/workflows/harness-ci.yml/runs" -f status=completed \
       -f event=pull_request -f "created=>=$SINCE" -f per_page=100 -f "page=$pg" > "$TMP/page" 2>/dev/null \
     || ! jq -e '.workflow_runs | type == "array"' "$TMP/page" >/dev/null 2>&1; then
    log "prequeue-learned: repo=$REPO: runs page $pg unreadable — nothing recorded this tick"
    exit 0
  fi
  NPG=$pg
  jq -c --slurpfile p "$TMP/page" '. + $p[0].workflow_runs' "$TMP/runs" > "$TMP/runs.n" && mv "$TMP/runs.n" "$TMP/runs"
  [ "$(jq '.workflow_runs | length' "$TMP/page")" -ge 100 ] || break
done
# Failed merge-queue batches, oldest first: `<id> <created epoch> <attempt>`.
if ! jq -r '[unique_by(.id)[]
      | select(((.head_branch // "") | startswith("mergify/merge-queue/")) and (.conclusion // "") == "failure")]
    | sort_by(.created_at // "", .id)[]
    | "\(.id) \((.created_at // "") | (try fromdateiso8601 catch 0)) \(.run_attempt // 1)"' \
    "$TMP/runs" > "$TMP/failed" 2>/dev/null; then
  log "prequeue-learned: repo=$REPO: run list did not parse — nothing recorded this tick"
  exit 0
fi

# 3-4. each unrecorded run, up to MAX
NFAIL=0; REC=0; UNREAD=0; DEFER=0; DONE=0
while read -r id created attempt; do
  case "$id" in ''|*[!0-9]*) continue ;; esac
  NFAIL=$(( NFAIL + 1 ))
  [ -f "$RUNS_DIR/$id" ] && continue
  if [ "$DONE" -ge "$MAX" ]; then DEFER=$(( DEFER + 1 )); continue; fi
  DONE=$(( DONE + 1 ))
  tmpf="$RUNS_DIR/.$id.tmp"
  if flaky_run_tests_strict "$REPO" "$id" > "$TMP/names" 2>/dev/null; then
    if { echo "run $id created $created attempt $attempt"
         awk -F'\t' -v sre="$SUITE_RE" '$1 == "P" && $2 ~ sre && !seen[$2]++ {print $2}' "$TMP/names"
       } > "$tmpf" 2>/dev/null && mv -f "$tmpf" "$RUNS_DIR/$id" 2>/dev/null; then
      REC=$(( REC + 1 )); rm -f "$RUNS_DIR/$id.strikes"
    else
      rm -f "$tmpf" 2>/dev/null
      log "prequeue-learned: run $id: record write failed — it is read again next tick"
    fi
    continue
  fi
  UNREAD=$(( UNREAD + 1 ))
  n=$(awk '{print $2; exit}' "$RUNS_DIR/$id.strikes" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$(( n + 1 ))
  if [ "$n" -ge 3 ]; then
    if echo "run $id created $created attempt $attempt unreadable" > "$tmpf" 2>/dev/null \
       && mv -f "$tmpf" "$RUNS_DIR/$id" 2>/dev/null; then
      rm -f "$RUNS_DIR/$id.strikes"
    else
      rm -f "$tmpf" 2>/dev/null
      log "prequeue-learned: run $id: record write failed — it is read again next tick"
    fi
  else
    echo "strikes $n created $created" > "$RUNS_DIR/$id.strikes.tmp" 2>/dev/null \
      && mv -f "$RUNS_DIR/$id.strikes.tmp" "$RUNS_DIR/$id.strikes" 2>/dev/null
  fi
done < "$TMP/failed"

# 5. prune: records and strike files created over KEEP_DAYS days ago
OLD=$(( NOW - KEEP_DAYS * 86400 ))
for f in "$RUNS_DIR"/[0-9]*; do
  [ -f "$f" ] || continue
  c=$(awk 'NR == 1 { for (i = 1; i < NF; i++) if ($i == "created") { print $(i + 1); exit } }' "$f" 2>/dev/null)
  case "$c" in ''|*[!0-9]*) continue ;; esac
  [ "$c" -lt "$OLD" ] && rm -f "$f"
done

# 6. the tick's one line
log "prequeue-learned: failed-batches=$NFAIL recorded=$REC unread=$UNREAD deferred=$DEFER pages=$NPG"
exit 0
