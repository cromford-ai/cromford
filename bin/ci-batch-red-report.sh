#!/bin/bash
# bin/ci-batch-red-report.sh — why do merge-queue batches go red? One TSV row
# per failing suite over a window, and the case that explains most red batches
# (BH-8048).
#
# WHY. On 2026-10-22, 13 of 26 harness-ci.yml merge-queue batch runs in 24 h
# concluded failure, each about 265 runner-minutes that merge nothing, and the
# pre-queue gate had passed every one of those heads. Nothing named the failing
# suites per batch. This lane does, and it says which case holds:
#   A  the failing suites are suites the member PR's pre-queue gate did not run
#   B  the red batch went green on the same tree (no code change): a flake
#   C  neither explains most red batches
#
# usage: ci-batch-red-report.sh [--days N] [--dry-run]
#   --days N   the window (default CI_BATCH_RED_DAYS, 7)
#   --dry-run  read GitHub, print the TSV and the summary line on stdout; write
#              no record, no TSV and no log line
#
# PER TICK, each step a stop when it fails, rc 0 on every path:
#   1. bin/lib/gh-budget.sh says the bucket is low: one log line, no gh call,
#      latest.tsv untouched.
#   2. at most CI_BATCH_RED_PAGES pages (100 runs each) of the completed
#      harness-ci.yml runs created in the window, through gh_ci_api. Kept:
#      head_branch starting mergify/merge-queue/; conclusion failure = red,
#      success = green; any other conclusion is counted `ignored`. A page that
#      is unreadable: one log line, nothing written.
#   3. only when a red run is read this tick: the prequeue-gate.yml
#      workflow_dispatch runs, titled `prequeue pr=<n> head=<sha> main=<sha>`.
#      Unreadable = every gate of this tick is `?` (not a stop).
#   4. each run with no record at its current run_attempt, oldest first, at
#      most CI_BATCH_RED_MAX (the rest are `deferred`), gh_budget_low before
#      each (low = the rest are deferred):
#      - its jobs (filter=latest; a list longer than the pages read = a failed
#        read). The shard jobs are `Tests, traced (shard ...`. A red run: the
#        log of each FAILED shard. A green run: the log of EVERY shard. A log is
#        read with --allow-escape-sequences (without it gh prints nothing).
#      - `--- tests/[mc/]<x>.sh rc=<n>` at a line start (timestamp stripped):
#        `ran`, and `fail <suite> <rc>` when n != 0. `HIT <x>.sh ...` (the
#        trace-safety harness): `fail <suite> trace`. A failed job that is not a
#        shard and not a fan-in (`Pure-logic gate fixtures`, `Tests cannot touch
#        a real harness`), or a failed shard whose log names no failing suite:
#        `fail job:<name> other`.
#      - members: each `#<n>` in the first line of head_commit.message.
#      - red runs, per member: the newest gate run for that PR created before
#        the batch, its `gate` job, and that job's log. The suites the gate RAN
#        are its `impact-gate: done <suite> rc=` and `impact-gate: reused
#        <suite> from` lines, and any `--- <suite> rc=` line. (The verdict's
#        `suites=` field is the gate's FAILED suites, empty on a green verdict,
#        so it cannot say what the gate ran.) Any gate read failure: `?`.
#      - a jobs read or a needed shard log read that fails: one strike in
#        runs/<id>.strikes; the third strike writes the record `unread`.
#   5. latest.tsv (tmp + mv), from every record created in the window:
#        suite kind red_batches green_batches_since gate_missed retry_green prs
#      red_batches = red runs that list the suite failing; green_batches_since
#      = green runs created after its first red that ran it; gate_missed = red
#      runs where no readable member gate ran it (`?` when no member gate of
#      its red runs was readable; `-` for a job:<name> row); retry_green = red
#      runs whose tree is a green run's tree; prs = member PRs of its red runs.
#      One `unread` row counts the red runs recorded unread. Sorted by
#      red_batches descending, then suite.
#   6. the case, over the readable red runs (red, not unread). EXPLAINED-A: at
#      least one rc/trace failure, every member gate readable, and no failing
#      suite was run by a member gate. EXPLAINED-B: at least one rc/trace
#      failure and the tree is a green run's tree. case=A when share_a > 50 %,
#      B when share_b > 50 %, A+B when both, else C (and C with 0 readable red).
#   7. records and strike files created over CI_BATCH_RED_KEEP_DAYS days ago
#      are pruned.
#   8. one log line to logs/ci-batch-red.log:
#      ci-batch-red: repo=<r> days=<d> red=<n> green=<n> red_rate=<pct> unread=<u>
#        deferred=<k> case=<A|B|A+B|C> share_a=<pct> share_b=<pct> pruned=<p> ignored=<i>
#   9. once per ISO week (BH-8062), in logs/ci-batch-red-week.log (not the
#      tick log, which keeps one line a tick):
#      the last complete week (Mon 00:00Z to the next Mon 00:00Z, the week
#      before NOW's) with no marker state/ci-batch-red/week-<YYYY-Www> gets
#      one more line, counted from the records on disk (no gh read), then the
#      marker:
#      ci-batch-red-week: repo=<r> week=<YYYY-Www> red=<n> green=<n>
#        red_rate=<pct|-> target=<CI_BATCH_RED_TARGET_PCT> met=<yes|no|no-data>[ why=pruned]
#      met=yes when red_rate <= target. No batch in the week: red_rate=- and
#      met=no-data. A week that starts before the record retention cut
#      (CI_BATCH_RED_KEEP_DAYS) may have lost records: met=no-data why=pruned.
#      A dry run prints the line and writes no marker. Week markers whose week
#      started over CI_BATCH_RED_WEEK_KEEP_DAYS days ago are pruned in step 7.
#
# RECORD FORMAT, one file per run, $H/state/ci-batch-red/runs/<run_id>:
#   run <id> attempt <n> created <epoch> concl red|green tree <tree|-> prs <csv|-> [unread]
#   ran<TAB><suite>
#   fail<TAB><suite>|job:<name><TAB><rc>|trace|other
#   gate<TAB><pr><TAB><verdict>|?<TAB><csv of suites it ran>|-
# Strike file, runs/<run_id>.strikes: `strikes <n> created <epoch>`.
#
# KNOBS (lane ci-batch-red-report, catalog/lanes.d/ci-batch-red-report.json; a settings row,
# then env, then the default here; a value out of range is the default):
#   CI_BATCH_RED_DAYS       7  (1..30)   the window
#   CI_BATCH_RED_PAGES      5  (1..10)   100-run pages of each run list
#   CI_BATCH_RED_MAX       40  (1..200)  runs read per tick
#   CI_BATCH_RED_KEEP_DAYS 30  (7..90)   record retention
#   CI_BATCH_RED_TARGET_PCT 15 (1..100)  the weekly red-batch rate target (BH-8062)
#   CI_BATCH_RED_WEEK_KEEP_DAYS 90 (30..730) week marker retention (BH-8062)
#   CI_BATCH_RED_REPO          the repo read (default HARNESS_REPO); not settable
# Kill switch: bin/harness-ctl.sh off ci-batch-red-report (flags/lane-off-ci-batch-red-report)
# The lane id is the script name, as every cron lane's is (tests/lanes-registry-test.sh).
# Tests: tests/ci-batch-red-report.bh-8048-test.sh, tests/ci-batch-red-week.bh-8062-test.sh
set -uo pipefail
DRY=""; DAYS_ARG=""
usage() { echo "usage: ci-batch-red-report.sh [--days N] [--dry-run]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || usage; DAYS_ARG="$2"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,102p' "$0"; exit 0 ;;
    *) usage ;;
  esac
  shift
done
case "$DAYS_ARG" in ''|[1-9]|[12][0-9]|30) ;; *) usage ;; esac
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; [ -n "$BIN" ] || BIN="$H/bin"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$BIN/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# >>> lane gate (BH-1165)
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit ci-batch-red-report
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply ci-batch-red-report
for _L in gh-budget.sh gh-ci-read.sh gh-repo-token.sh; do
  # shellcheck source=/dev/null
  if [ -r "$BIN/lib/$_L" ]; then . "$BIN/lib/$_L"; elif [ -r "$H/bin/lib/$_L" ]; then . "$H/bin/lib/$_L"; fi
done
NOW="${NOW:-$(date +%s)}"
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac
LOG="$H/logs/ci-batch-red.log"
STATE="$H/state/ci-batch-red"
[ -n "$DRY" ] || mkdir -p "$(dirname "$LOG")" 2>/dev/null
STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ'; }
log() { if [ -n "$DRY" ]; then echo "$*"; else echo "$(STAMP) $*" >> "$LOG" 2>/dev/null; fi; return 0; }
# The weekly line (step 9) has its own log, so the tick log keeps one line a tick.
WLOG="$H/logs/ci-batch-red-week.log"
wlog() { if [ -n "$DRY" ]; then echo "$*"; else echo "$(STAMP) $*" >> "$WLOG" 2>/dev/null; fi; return 0; }

# knob <ENV> <default> <min> <max> — lane_knob (row, env, registry default)
#   when the lane gate is loaded, else the env, else the default; a value that
#   is not a whole number in [min, max] is the default.
knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob ci-batch-red-report "$1" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  { [ "${#v}" -le 6 ] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; } || v="$2"
  printf '%s' "$v"
}
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$BIN/lib/deployment.sh}" 2>/dev/null || { log "ci-batch-red: deployment.sh unreadable — nothing read"; exit 0; }  # BH-4080: HARNESS_REPO
REPO="${CI_BATCH_RED_REPO:-${HARNESS_REPO:-}}"
[ -n "$REPO" ] || { log "ci-batch-red: no repo (CI_BATCH_RED_REPO, HARNESS_REPO) — nothing read"; exit 0; }
DAYS="${DAYS_ARG:-$(knob CI_BATCH_RED_DAYS 7 1 30)}"
PAGES=$(knob CI_BATCH_RED_PAGES 5 1 10)
MAX=$(knob CI_BATCH_RED_MAX 40 1 200)
KEEP_DAYS=$(knob CI_BATCH_RED_KEEP_DAYS 30 7 90)
# Fallback for the row lane.ci-batch-red-report.ci_batch_red_target_pct (BH-8062).
TARGET=$(knob CI_BATCH_RED_TARGET_PCT 15 1 100)
# Fallback for the row lane.ci-batch-red-report.ci_batch_red_week_keep_days (BH-8062).
WEEK_KEEP_DAYS=$(knob CI_BATCH_RED_WEEK_KEEP_DAYS 90 30 730)
CUT=$(( NOW - DAYS * 86400 ))
SINCE=$(date -u -d "@$CUT" '+%Y-%m-%dT%H:%M:%SZ')
# A gate run comes before its batch: the gate list reaches one day further back.
GSINCE=$(date -u -d "@$(( CUT - 86400 ))" '+%Y-%m-%dT%H:%M:%SZ')
SHARD='Tests, traced (shard'
FANIN='Pure-logic gate fixtures|Tests cannot touch a real harness'

# 1. the GitHub budget
if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low ci-batch-red-report; then
  log "ci-batch-red: skipped: GitHub budget low (bin/lib/gh-budget.sh) — no reads this tick"
  exit 0
fi
command -v gh_ci_api >/dev/null 2>&1 || { log "ci-batch-red: gh-ci-read.sh not loaded — nothing read"; exit 0; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ci-batch-red.XXXXXX") || { log "ci-batch-red: mktemp failed — nothing read"; exit 0; }
trap 'rm -rf "$TMP"' EXIT
# A dry run reads and writes a copy of the records, so the real ones never move.
RUNS_DIR="$STATE/runs"
if [ -n "$DRY" ]; then
  mkdir -p "$TMP/runs"; [ -d "$RUNS_DIR" ] && cp -pr "$RUNS_DIR"/. "$TMP/runs/" 2>/dev/null
  RUNS_DIR="$TMP/runs"
fi
mkdir -p "$RUNS_DIR" 2>/dev/null || { log "ci-batch-red: cannot create $RUNS_DIR — nothing read"; exit 0; }
command -v gh_repo_use_token >/dev/null 2>&1 && { gh_repo_use_token "$REPO" 2>/dev/null \
  || { log "ci-batch-red: repo=$REPO: no token can read it — nothing read"; exit 0; }; }

# list_runs <workflow file> <since> <out> [extra -f args...] — every page into one array; rc 1 unreadable
list_runs() {
  local wf="$1" since="$2" out="$3" pg; shift 3
  echo '[]' > "$out"
  for (( pg = 1; pg <= PAGES; pg++ )); do
    if ! gh_ci_api "$REPO" -X GET "repos/$REPO/actions/workflows/$wf/runs" -f status=completed \
         "$@" -f "created=>=$since" -f per_page=100 -f "page=$pg" > "$TMP/page" 2>/dev/null \
       || ! jq -e '.workflow_runs | type == "array"' "$TMP/page" >/dev/null 2>&1; then
      return 1
    fi
    jq -c --slurpfile p "$TMP/page" '. + $p[0].workflow_runs' "$out" > "$out.n" && mv "$out.n" "$out"
    [ "$(jq '.workflow_runs | length' "$TMP/page")" -ge 100 ] || break
  done
  return 0
}

# 2. the batch run list
if ! list_runs harness-ci.yml "$SINCE" "$TMP/runs.json"; then
  log "ci-batch-red: repo=$REPO: runs page unreadable — nothing written this tick"
  exit 0
fi
# `<id> <created> <attempt> <red|green> <tree|-> <prs|->`, oldest first; `ignored <n>` last.
if ! jq -r '[unique_by(.id)[] | select((.head_branch // "") | startswith("mergify/merge-queue/"))] as $q
    | ($q | map(select(.conclusion == "failure" or .conclusion == "success"))
       | sort_by(.created_at // "", .id)[]
       | "\(.id) \((.created_at // "") | (try fromdateiso8601 catch 0)) \(.run_attempt // 1) \(if .conclusion == "failure" then "red" else "green" end) \(.head_commit.tree_id // "-") \(((.head_commit.message // "") | split("\n")[0] | [scan("#([0-9]+)")[0]] | unique_by(tonumber) | join(",")) as $p | if $p == "" then "-" else $p end)"),
      "ignored \($q | map(select(.conclusion != "failure" and .conclusion != "success")) | length)"' \
    "$TMP/runs.json" > "$TMP/list" 2>/dev/null; then
  log "ci-batch-red: repo=$REPO: run list did not parse — nothing written this tick"
  exit 0
fi
IGNORED=$(awk '$1 == "ignored" {print $2}' "$TMP/list")

# rec_attempt <id> — the attempt the record holds, 0 when none
rec_attempt() { awk 'NR == 1 && $1 == "run" && $3 == "attempt" { print $4 + 0; exit }' "$RUNS_DIR/$1" 2>/dev/null || true; }
: > "$TMP/todo"
while read -r id created attempt concl tree prs; do
  case "$id" in ''|*[!0-9]*) continue ;; esac
  a=$(rec_attempt "$id"); [ "${a:-0}" -ge "$attempt" ] && continue
  echo "$id $created $attempt $concl $tree $prs" >> "$TMP/todo"
done < "$TMP/list"
TODO=$(grep -c . < "$TMP/todo")

# 3. the gate run list, only when a red run is to be read: `<pr> <created> <run_id>`
GATES_OK=0; : > "$TMP/gates"
if head -n "$MAX" "$TMP/todo" | awk '$4 == "red" {f = 1} END {exit !f}'; then
  if list_runs prequeue-gate.yml "$GSINCE" "$TMP/gates.json" -f event=workflow_dispatch \
     && jq -r '.[] | ((.display_title // "") | capture("^prequeue pr=(?<pr>[0-9]+) head=[0-9a-f]{40}")) as $m
         | "\($m.pr) \((.created_at // "") | (try fromdateiso8601 catch 0)) \(.id)"' \
         "$TMP/gates.json" > "$TMP/gates" 2>/dev/null; then
    GATES_OK=1
  fi
fi

# filter_log — the lines this lane reads, from a job log on stdin:
#   `ran\t<suite>`, `fail\t<suite>\t<rc>`, `fail\t<suite>\ttrace`
filter_log() {
  local root="${BIN%/bin}"
  sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//; s/\r$//' \
  | awk -v root="$root" '
    function exists(p,   r) { r = (getline _ < p); close(p); return r >= 0 }
    match($0, /^--- tests\/(mc\/)?[A-Za-z0-9._-]+\.sh rc=[0-9]+( |$)/) {
      split($0, w, " "); s = w[2]; rc = substr(w[3], 4) + 0
      print "ran\t" s; if (rc != 0) print "fail\t" s "\t" rc; next
    }
    /^[[:space:]]*HIT [A-Za-z0-9._-]+\.sh / {
      split($0, w, " "); n = w[2]
      if (exists(root "/tests/" n)) s = "tests/" n
      else if (exists(root "/tests/mc/" n)) s = "tests/mc/" n
      else s = "tests/" n
      print "fail\t" s "\ttrace"
    }'
}
# gate_ran — from a gate job log on stdin, the suites it ran, sorted, comma-joined
gate_ran() {
  sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//; s/\r$//' \
  | sed -nE 's/^impact-gate: done (tests\/[A-Za-z0-9._\/-]+\.sh) rc=[0-9]+.*/\1/p;
             s/^impact-gate: reused (tests\/[A-Za-z0-9._\/-]+\.sh) from .*/\1/p;
             s/^--- (tests\/[A-Za-z0-9._\/-]+\.sh) rc=[0-9]+( .*)?$/\1/p' \
  | LC_ALL=C sort -u | paste -sd, -
}
# read_jobs <run_id> <out> — every page of the latest attempt's jobs; rc 1 on a failed or partial read
read_jobs() {
  local id="$1" out="$2" jp total
  echo '[]' > "$out"
  for (( jp = 1; jp <= PAGES; jp++ )); do
    gh_ci_api "$REPO" "repos/$REPO/actions/runs/$id/jobs?filter=latest&per_page=100&page=$jp" > "$TMP/jpage" 2>/dev/null </dev/null \
      && jq -e '.jobs | type == "array"' "$TMP/jpage" >/dev/null 2>&1 || return 1
    total=$(jq '.total_count // 0' "$TMP/jpage")
    jq -c --slurpfile p "$TMP/jpage" '. + $p[0].jobs' "$out" > "$out.n" && mv "$out.n" "$out"
    [ "$(jq length "$out")" -ge "$total" ] && return 0
    [ "$(jq '.jobs | length' "$TMP/jpage")" -ge 100 ] || return 1
  done
  return 1
}
# gate_line <pr> <batch created> — `gate\t<pr>\t<verdict|?>\t<csv|->`
gate_line() {
  local pr="$1" before="$2" gid jid lg v csv
  [ "$GATES_OK" = 1 ] || { printf 'gate\t%s\t?\t-\n' "$pr"; return; }
  gid=$(awk -v p="$pr" -v b="$before" '$1 == p && $2 < b && $2 >= best { best = $2; id = $3 } END { if (id != "") print id }' "$TMP/gates")
  [ -n "$gid" ] || { printf 'gate\t%s\t?\t-\n' "$pr"; return; }
  if read_jobs "$gid" "$TMP/gjobs" \
     && jid=$(jq -r 'map(select(.name == "gate"))[0].id // empty' "$TMP/gjobs") && [ -n "$jid" ] \
     && lg=$(gh_ci_api "$REPO" --allow-escape-sequences "repos/$REPO/actions/jobs/$jid/logs" 2>/dev/null </dev/null) && [ -n "$lg" ]; then
    v=$(printf '%s\n' "$lg" | sed -nE 's/.*prequeue-verdict::([a-z-]+).*/\1/p' | tail -n1)
    csv=$(printf '%s\n' "$lg" | gate_ran)
    printf 'gate\t%s\t%s\t%s\n' "$pr" "${v:-read}" "${csv:--}"
  else
    printf 'gate\t%s\t?\t-\n' "$pr"
  fi
}
# strike <id> <created> <head line> — a failed read; the third writes the record unread
strike() {
  local id="$1" created="$2" headl="$3" n
  UNREAD=$(( UNREAD + 1 ))
  n=$(awk '{print $2; exit}' "$RUNS_DIR/$id.strikes" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$(( n + 1 ))
  if [ "$n" -ge 3 ]; then
    if echo "$headl unread" > "$RUNS_DIR/.$id.tmp" 2>/dev/null && mv -f "$RUNS_DIR/.$id.tmp" "$RUNS_DIR/$id" 2>/dev/null; then
      rm -f "$RUNS_DIR/$id.strikes"
    else
      rm -f "$RUNS_DIR/.$id.tmp"; log "ci-batch-red: run $id: record write failed — it is read again next tick"
    fi
  else
    echo "strikes $n created $created" > "$RUNS_DIR/$id.strikes.tmp" 2>/dev/null \
      && mv -f "$RUNS_DIR/$id.strikes.tmp" "$RUNS_DIR/$id.strikes" 2>/dev/null
  fi
}

# 4. each run to read, up to MAX
DONE=0; DEFER=0; UNREAD=0
while read -r id created attempt concl tree prs; do
  [ -n "$id" ] || continue
  if [ "$DONE" -ge "$MAX" ]; then DEFER=$(( DEFER + 1 )); continue; fi
  if [ "$DONE" -gt 0 ] && command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low ci-batch-red-report; then
    DEFER=$(( DEFER + 1 )); DONE=$MAX; continue
  fi
  DONE=$(( DONE + 1 ))
  headl="run $id attempt $attempt created $created concl $concl tree $tree prs $prs"
  if ! read_jobs "$id" "$TMP/jobs"; then strike "$id" "$created" "$headl"; continue; fi
  : > "$TMP/body"; ok=1
  # Shards to read: every shard of a green run, the failed shards of a red one.
  while IFS=$'\t' read -r jid jconcl jname; do
    [ -n "$jid" ] || continue
    if [[ $jname == "$SHARD"* ]]; then
      [ "$concl" = green ] || [ "$jconcl" = failure ] || continue
      lg=$(gh_ci_api "$REPO" --allow-escape-sequences "repos/$REPO/actions/jobs/$jid/logs" 2>/dev/null </dev/null) || { ok=0; break; }
      [ -n "$lg" ] || { ok=0; break; }
      out=$(printf '%s\n' "$lg" | filter_log)
      [ -n "$out" ] && printf '%s\n' "$out" >> "$TMP/body"
      if [ "$jconcl" = failure ] && ! grep -q '^fail' <<<"$out"; then printf 'fail\tjob:%s\tother\n' "$jname" >> "$TMP/body"; fi
    elif [ "$jconcl" = failure ] && ! [[ $jname =~ ^($FANIN)$ ]]; then
      printf 'fail\tjob:%s\tother\n' "$jname" >> "$TMP/body"
    fi
  done < <(jq -r '.[] | [(.id | tostring), (.conclusion // ""), (.name // "")] | @tsv' "$TMP/jobs")
  [ "$ok" = 1 ] || { strike "$id" "$created" "$headl"; continue; }
  if [ "$concl" = red ] && [ "$prs" != - ]; then
    for pr in ${prs//,/ }; do gate_line "$pr" "$created" >> "$TMP/body"; done
  fi
  if { echo "$headl"; awk '!seen[$0]++' "$TMP/body"; } > "$RUNS_DIR/.$id.tmp" 2>/dev/null \
     && mv -f "$RUNS_DIR/.$id.tmp" "$RUNS_DIR/$id" 2>/dev/null; then
    rm -f "$RUNS_DIR/$id.strikes"
  else
    rm -f "$RUNS_DIR/.$id.tmp"; log "ci-batch-red: run $id: record write failed — it is read again next tick"
  fi
done < "$TMP/todo"

# 5-6. the TSV and the case, from every record in the window
RECS=()
for f in "$RUNS_DIR"/[0-9]*; do
  case "$f" in *.strikes|*.tmp) continue ;; esac
  [ -f "$f" ] && RECS+=("$f")
done
: > "$TMP/tsv"; : > "$TMP/sum"
if [ ${#RECS[@]} -gt 0 ]; then
  awk -v cut="$CUT" -v tsv="$TMP/tsv" -v sum="$TMP/sum" '
    function add(set, k, v) { if (index("," set[k] ",", "," v ",") == 0) set[k] = (set[k] == "" ? v : set[k] "," v) }
    FNR == 1 {
      split($0, h, " "); use = 0
      if (h[1] != "run" || h[5] != "created" || h[7] != "concl" || h[9] != "tree" || h[11] != "prs") next
      if (h[6] + 0 < cut) next
      use = 1; r = h[2]; R[r] = 1; C[r] = h[6] + 0; K[r] = h[8]; TR[r] = h[10]; P[r] = h[12]
      U[r] = (h[13] == "unread"); next
    }
    !use { next }
    { split($0, f, "\t") }
    f[1] == "ran"  { RAN[r, f[2]] = 1; next }
    f[1] == "fail" { if (!((r, f[2]) in FK)) { FN[r] = FN[r] SUBSEP f[2] } ; add(FK, r SUBSEP f[2], f[3]); next }
    f[1] == "gate" { NG[r]++; if (f[3] != "?") { NGR[r]++; n = split(f[4], g, ","); for (i = 1; i <= n; i++) GR[r, g[i]] = 1 } ; next }
    END {
      for (r in R) if (K[r] == "green") { ng++; if (TR[r] != "-") GT[TR[r]] = 1 } else { nr++; if (U[r]) { nu++; m = split(P[r], pp, ","); for (j = 1; j <= m; j++) if (pp[j] != "-") add(UP, "x", pp[j]) } }
      for (r in R) {
        if (K[r] != "red" || U[r]) continue
        rd++; nreal = 0; missall = 1; b = (TR[r] != "-" && (TR[r] in GT))
        n = split(substr(FN[r], 2), fs, SUBSEP)
        for (i = 1; i <= n; i++) {
          s = fs[i]; k = FK[r, s]; red[s]++; if (P[r] != "-") { m = split(P[r], pp, ","); for (j = 1; j <= m; j++) add(PR, s, pp[j]) }
          m = split(k, kk, ","); for (j = 1; j <= m; j++) add(KD, s, kk[j])
          if (!(s in first) || C[r] < first[s]) first[s] = C[r]
          if (b) retry[s]++
          if (s ~ /^job:/) continue
          nreal++
          if (NGR[r] > 0) { known[s] = 1; if (!((r, s) in GR)) missed[s]++ }
          if ((r, s) in GR) missall = 0
        }
        if (nreal > 0 && NG[r] > 0 && NGR[r] == NG[r] && missall) ea++
        if (nreal > 0 && b) eb++
      }
      for (s in red) {
        gs = 0; for (r in R) if (K[r] == "green" && !U[r] && C[r] > first[s] && ((r, s) in RAN)) gs++
        gm = (s ~ /^job:/) ? "-" : ((s in known) ? missed[s] + 0 : "?")
        # prs sorted numerically
        m = split(PR[s], pp, ","); ps = ""
        for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (pp[j] + 0 < pp[i] + 0) { t = pp[i]; pp[i] = pp[j]; pp[j] = t }
        for (i = 1; i <= m; i++) ps = ps (i > 1 ? "," : "") pp[i]
        m = split(KD[s], kk, ","); ks = ""
        for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (kk[j] < kk[i]) { t = kk[i]; kk[i] = kk[j]; kk[j] = t }
        for (i = 1; i <= m; i++) { kn = (kk[i] ~ /^[0-9]+$/) ? "rc" : kk[i]; if (index("," ks ",", "," kn ",") == 0) ks = ks (ks == "" ? "" : ",") kn }
        printf "%s\t%s\t%d\t%d\t%s\t%d\t%s\n", s, ks, red[s], gs, gm, retry[s] + 0, (ps == "" ? "-" : ps) > tsv
      }
      if (nu > 0) {
        m = split(UP["x"], pp, ","); ps = ""
        for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (pp[j] + 0 < pp[i] + 0) { t = pp[i]; pp[i] = pp[j]; pp[j] = t }
        for (i = 1; i <= m; i++) ps = ps (i > 1 ? "," : "") pp[i]
        printf "unread\t-\t%d\t-\t-\t-\t%s\n", nu, (ps == "" ? "-" : ps) > tsv
      }
      sa = rd ? int(ea * 100 / rd) : 0; sb = rd ? int(eb * 100 / rd) : 0
      cs = "C"
      if (rd > 0 && ea * 2 > rd && eb * 2 > rd) cs = "A+B"
      else if (rd > 0 && ea * 2 > rd) cs = "A"
      else if (rd > 0 && eb * 2 > rd) cs = "B"
      printf "%d %d %d %d %s %d %d\n", nr, ng, (nr + ng) ? int(nr * 100 / (nr + ng)) : 0, nu, cs, sa, sb > sum
    }' "${RECS[@]}" 2>/dev/null
fi
[ -s "$TMP/sum" ] || echo "0 0 0 0 C 0 0" > "$TMP/sum"
read -r NRED NGREEN RATE NUNREAD CASE SA SB < "$TMP/sum"
{ printf 'suite\tkind\tred_batches\tgreen_batches_since\tgate_missed\tretry_green\tprs\n'
  LC_ALL=C sort -t "$(printf '\t')" -k3,3nr -k1,1 "$TMP/tsv"; } > "$TMP/latest.tsv"

# 7. prune: records and strike files created over KEEP_DAYS days ago
OLD=$(( NOW - KEEP_DAYS * 86400 )); PRUNED=0
for f in "$RUNS_DIR"/[0-9]*; do
  [ -f "$f" ] || continue
  c=$(awk 'NR == 1 { for (i = 1; i < NF; i++) if ($i == "created") { print $(i + 1); exit } }' "$f" 2>/dev/null)
  case "$c" in ''|*[!0-9]*) continue ;; esac
  if [ "$c" -lt "$OLD" ]; then rm -f "$f" && PRUNED=$(( PRUNED + 1 )); fi
done
# Week markers (step 9) whose week started over WEEK_KEEP_DAYS days ago. A dry
# run deletes nothing.
if [ -z "$DRY" ]; then
  for f in "$STATE"/week-[0-9]*; do
    [ -f "$f" ] || continue
    c=$(awk 'NR == 1 && $3 == "start" { print $4 }' "$f" 2>/dev/null)
    case "$c" in ''|*[!0-9]*) continue ;; esac
    [ "$c" -lt $(( NOW - WEEK_KEEP_DAYS * 86400 )) ] && rm -f "$f"
  done
fi

# 8. the TSV and the tick's one line
LINE="ci-batch-red: repo=$REPO days=$DAYS red=$NRED green=$NGREEN red_rate=$RATE unread=$NUNREAD deferred=$DEFER case=$CASE share_a=$SA share_b=$SB pruned=$PRUNED ignored=${IGNORED:-0}"
if [ -n "$DRY" ]; then
  cat "$TMP/latest.tsv"
elif ! { cp "$TMP/latest.tsv" "$STATE/.latest.tsv.tmp" 2>/dev/null && mv -f "$STATE/.latest.tsv.tmp" "$STATE/latest.tsv" 2>/dev/null; }; then
  rm -f "$STATE/.latest.tsv.tmp" 2>/dev/null
  log "ci-batch-red: latest.tsv write failed in $STATE"
fi
# 9. the weekly line: the last complete ISO week, once (BH-8062), in its own
# log (logs/ci-batch-red-week.log).
WEEK_END=$(( NOW - NOW % 86400 - ($(date -u -d "@$NOW" +%u) - 1) * 86400 ))
WEEK_START=$(( WEEK_END - 7 * 86400 ))
WEEK=$(date -u -d "@$WEEK_START" +%G-W%V)
WMARK="$STATE/week-$WEEK"
if [ ! -e "$WMARK" ]; then
  read -r WRED WGREEN < <(awk -v s="$WEEK_START" -v e="$WEEK_END" '
    FNR == 1 && $1 == "run" && $5 == "created" && $7 == "concl" && $6 + 0 >= s && $6 + 0 < e {
      if ($8 == "red") r++; else if ($8 == "green") g++ }
    END { print r + 0, g + 0 }' /dev/null "$RUNS_DIR"/[0-9]* 2>/dev/null)
  WRED=${WRED:-0}; WGREEN=${WGREEN:-0}
  if [ "$WEEK_START" -lt "$OLD" ]; then
    # Step 7 deletes records created before OLD, so part of this week may be
    # gone: never a rate from a partial week.
    WRATE=-; MET="no-data why=pruned"
  elif [ $(( WRED + WGREEN )) = 0 ]; then
    WRATE=-; MET=no-data
  else
    WRATE=$(( WRED * 100 / (WRED + WGREEN) ))
    if [ "$WRATE" -le "$TARGET" ]; then MET=yes; else MET=no; fi
  fi
  wlog "ci-batch-red-week: repo=$REPO week=$WEEK red=$WRED green=$WGREEN red_rate=$WRATE target=$TARGET met=$MET"
  if [ -z "$DRY" ]; then
    { mkdir -p "$STATE" && echo "week $WEEK start $WEEK_START" > "$WMARK.tmp" && mv -f "$WMARK.tmp" "$WMARK"; } 2>/dev/null \
      || { rm -f "$WMARK.tmp" 2>/dev/null; log "ci-batch-red: week marker write failed in $STATE — the week line repeats next tick"; }
  fi
fi
log "$LINE"
exit 0
