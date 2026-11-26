#!/bin/bash
# bin/prr-sweep.sh tick | project <project> | raise [--dry-run] | report — BH-9939 (BH-9926 wave 7):
# the slow safety sweep of the PR record (bin/lib/pr-record.sh).
#
# WHY. Since BH-9926 the lanes read PR facts from the record, and webhooks
# write the record. A lost webhook leaves a wrong field until something reads
# GitHub again. This lane is that read: for each fleet repo it compares the
# record with GitHub for the open PRs and repairs each difference.
#
# tick (cron/lanes/787-prr-sweep.cron, every 5 minutes, hub only). It trims
# the ledger, starts one `project <project>` run per fleet project through the
# per-project runner (pl_dispatch, bin/lib/project-lanes.sh: its own lock,
# start offset and App token for each project), then runs the raise step.
#
# project <project>. The cron line is a clock; PRR_SWEEP_INTERVAL_MIN decides.
# The project's repo is swept when its last sweep
# (state/prr-sweep/last/<owner>_<repo>) is that old. Two projects on one repo
# share that stamp and a lock, so the repo is swept one time. Per repo:
#   record   GET /api/pr-records?repo=&state=open, the rows as they are. The
#            trust rule of pr_record_list does not apply to a compare.
#   github   gh_rest_pr_list_all <repo> open: 1 call for each 100 open PRs.
#   fields   head_sha head_ref base_ref draft title labels (labels as a set).
#            One pr_record_put <repo> <n> github <fields> <sweep start> per PR
#            with a difference. A PR GitHub has and the record lacks is a
#            `state` difference (all fields are written).
#   gone     a PR the record calls open and GitHub's complete list does not
#            hold: 1 pulls/<n> read (pr_record_get, PR_RECORD_FRESH=1), which
#            writes the state.
#   checks   gh_rest GET repos/<r>/actions/runs?created=>=<since>, 100 a page,
#            at most PRR_SWEEP_RUNS_PAGES pages; <since> is 2 intervals before
#            the sweep start. For each open PR head with a run in the answer,
#            the newest run of each workflow (by start time, then attempt) is
#            compared with the record entry `workflow:<name>` of that head. A
#            missing or different entry is 1 PUT of the merged checks object.
#   statuses GitHub has no list read for commit statuses, so the sweep reads
#            commits/<head>/status for a bounded set: first each PR whose
#            record holds a pending status on its head, or that changed since
#            the last sweep (the PR's updated_at, or a run on its head); then
#            PRR_SWEEP_STATUS_ROTATE other PRs by rotation (cursor
#            state/prr-sweep/cursor/<owner>_<repo>). A missing or different
#            context is 1 PUT of the merged statuses object. A context that
#            only the record holds is left.
#   sync     pr_record_list_sync <repo> open <list> <sweep start>, only for an
#            uncut list. It renews the list sync stamp of the repo. The same
#            list goes to pr_record_default_branch_note (the default-branch
#            and cross-repo memos of BH-9938 C1).
# The gone reads and the status reads together are at most
# PRR_SWEEP_PR_READS_MAX for a repo in one sweep. 50 open PRs with no change
# cost 5 GitHub calls: 1 list, 1 runs page, 2 rotation reads, and 1 rate_limit
# read when the budget memo of bin/lib/gh-budget.sh is cold.
#
# NEWER ONLY. Every write carries the sweep start as its time. The worker
# replaces a field only when its stored time is not newer, and answers which
# fields it applied. An applied field is a fix: 1 PRR_SWEEP_FIX line and 1
# ledger row. A refused field is 1 PRR_SWEEP_STALE line and no fix.
#
# THE TRUST WINDOW. pr_record_list trusts the record's list while the sync
# stamp is at most PR_RECORD_LIST_MAX_AGE_S old (lib pr-record). That window
# must be the sweep interval plus PRR_SWEEP_LIST_SLACK_S, or a lane in step
# `record` reads GitHub between two sweeps. When the resolved window is
# smaller, the sweep uses the interval `window - slack` and logs one
# PRR_SWEEP_WINDOW line per sweep of a repo. A window of 0 (list trust off)
# changes nothing.
#
# THE LEDGER. state/prr-sweep/fixes.tsv, `<epoch> TAB <repo> TAB <n> TAB
# <field>`, written under flock, trimmed at each tick to PRR_SWEEP_QUIET_DAYS + 1 days. When a repo
# has more than PRR_SWEEP_FIX_ALERT_24H rows in 24 hours, one alert fires
# (lane-alert id prr-sweep-fixes:<repo>): a webhook is missing. The alert is
# resolved by the first sweep that counts the limit or less.
#
# raise [--dry-run] (also the last step of each tick). For each lane with a
# seam file in bin/lib/prr-shadow.d/: when its step (settings row
# lane.<id>.gh_source) is `record`, the first sweep on this box
# (state/prr-sweep/first-sweep) is PRR_SWEEP_QUIET_DAYS old, each repo the lane
# tried (state/prr-sweep/attempt/<owner>_<repo>) has a completed sweep in each
# of the last PRR_SWEEP_QUIET_DAYS 24-hour windows (state/prr-sweep/sweeps.tsv,
# `<epoch> TAB <owner>_<repo>`: "0 fixes" from a sweep that did not run is not
# evidence), the ledger has 0
# fixes in that window, the registry has the knob CADENCE_BACKSTOP_MIN_<LANE>
# (lib cadence-backstop, the lane's timed full tick interval) and the lane had
# no raise in that window (state/prr-sweep/raise/<lane>), the row
# lib.cadence-backstop.cadence_backstop_min_<lane> is set to its value times
# PRR_SWEEP_RAISE_FACTOR, at most the knob's max. One PRR_SWEEP_RAISE line. The
# wake path does not read that row. A lane without such a knob prints `no
# interval row`. Nothing lowers a row again: that is an operator edit.
#
# report. One line per repo with ledger rows (`repo=<r> fixes_24h=<n>
# fixes_7d=<n>`), one per tried repo (`swept=<owner>_<repo> days=<n>/<days>`)
# and one per seam lane (`lane=<l> step=<s> fixes_7d=<n>
# interval=<key>=<value>|none`).
#
# KNOBS (catalog/lanes.d/prr-sweep.json, rows lane.prr-sweep.<name>; each
# literal below is the documented fallback of its knob):
#   PRR_SWEEP_INTERVAL_MIN 60 (0 = off), PRR_SWEEP_FIX_ALERT_24H 20 (0 = no
#   alert), PRR_SWEEP_PR_READS_MAX 10, PRR_SWEEP_STATUS_ROTATE 2,
#   PRR_SWEEP_RUNS_PAGES 3 (0 = no checks compare), PRR_SWEEP_LIST_SLACK_S 300,
#   PRR_SWEEP_QUIET_DAYS 7, PRR_SWEEP_RAISE_FACTOR 2 (1 = no raise).
#   PRR_SWEEP_NOW (epoch) is the test clock.
#
# LOGS. logs/prr-shadow.log:
#   <UTC> PRR_SWEEP_FIX repo=<r> n=<n> field=<f>
#   <UTC> PRR_SWEEP_STALE repo=<r> n=<n> field=<f>
#   <UTC> PRR_SWEEP_WINDOW window_s=<w> interval_s=<i> used_s=<u>   (one per sweep of a repo)
#   <UTC> PRR_SWEEP_RAISE lane=<l> key=<k> from=<a> to=<b>
# logs/prr-sweep.log: one line per swept repo,
#   <repo> open=<n> fixes=<n> stale=<n> gh_calls=<n> pr_reads=<n> sync=<ok|failed|skipped>
# Hub only. Kill switch: flags/lane-off-prr-sweep (bin/harness-ctl.sh off prr-sweep).
# Doc: docs/notes/2026-11-26-BH-9939-prr-sweep.md; docs/EVENTS.md section 8.3.
#
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

CMD="${1:-tick}"; DRY=0
USAGE="usage: bin/prr-sweep.sh tick | project <project> | raise [--dry-run] | report"
case "$CMD" in
  tick|report) [ $# -le 1 ] || { echo "$USAGE" >&2; exit 2; } ;;
  project) P="${2:-}"; case "$P" in ''|.*|*[!A-Za-z0-9._-]*) echo "$USAGE" >&2; exit 2 ;; esac ;;
  raise) case "${2:-}" in '') ;; --dry-run) DRY=1 ;; *) echo "$USAGE" >&2; exit 2 ;; esac ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac

# >>> lane gate (BH-1165). Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off prr-sweep.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
case "${CMD:-tick}" in tick|project) command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit prr-sweep ;; esac
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply prr-sweep

LOG="$H/logs/prr-sweep.log"
STATE="$H/state/prr-sweep"
LEDGER="$STATE/fixes.tsv"
SWEEPS="$STATE/sweeps.tsv"
log() { mkdir -p "$H/logs" 2>/dev/null; echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$LOG"; }
slog() { mkdir -p "$H/logs" 2>/dev/null; printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$H/logs/prr-shadow.log" 2>/dev/null || true; }

# knob <ENV> <fallback> <min> <max> — a lane knob as an integer in range, else the fallback.
knob() {
  local v="${!1:-}"
  if [ -z "$v" ]; then printf '%s' "$2"; return 0; fi
  if ! [[ "$v" =~ ^[0-9]{1,9}$ ]] || [ "$((10#$v))" -lt "$3" ] || [ "$((10#$v))" -gt "$4" ]; then
    log "knob $1='$v' is not an integer in $3..$4: using $2"; printf '%s' "$2"; return 0
  fi
  printf '%s' "$((10#$v))"
}
# The second argument of each call is the fallback of the knob of that name in catalog/lanes.d/prr-sweep.json.
INTERVAL_MIN=$(knob PRR_SWEEP_INTERVAL_MIN 60 0 1440)
ALERT_24H=$(knob PRR_SWEEP_FIX_ALERT_24H 20 0 100000)
PR_READS_MAX=$(knob PRR_SWEEP_PR_READS_MAX 10 0 1000)
STATUS_ROTATE=$(knob PRR_SWEEP_STATUS_ROTATE 2 0 1000)
RUNS_PAGES=$(knob PRR_SWEEP_RUNS_PAGES 3 0 10)
LIST_SLACK_S=$(knob PRR_SWEEP_LIST_SLACK_S 300 0 3600)
QUIET_DAYS=$(knob PRR_SWEEP_QUIET_DAYS 7 1 90)
RAISE_FACTOR=$(knob PRR_SWEEP_RAISE_FACTOR 2 1 10)
QUIET_S=$((QUIET_DAYS * 86400))

now() { if [[ "${PRR_SWEEP_NOW:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$PRR_SWEEP_NOW"; else date -u +%s; fi; }
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
safe() { printf '%s' "$1" | tr '/' '_'; }
# ledger_count <since-epoch> [repo] — the ledger rows newer than <since-epoch>.
ledger_count() {
  [ -r "$LEDGER" ] || { echo 0; return 0; }
  awk -F'\t' -v s="$1" -v r="${2:-}" '$1 ~ /^[0-9]+$/ && $1 > s && (r == "" || $2 == r) { n++ } END { print n + 0 }' "$LEDGER"
}

# sweep_days <now> <owner>_<repo> — how many of the last PRR_SWEEP_QUIET_DAYS 24-hour windows hold a completed sweep of the repo.
sweep_days() {
  [ -r "$SWEEPS" ] || { echo 0; return 0; }
  awk -F'\t' -v n="$1" -v r="$2" -v d="$QUIET_DAYS" '$1 ~ /^[0-9]+$/ && $2 == r && $1 <= n && $1 > n - d * 86400 { b[int((n - $1) / 86400)] = 1 }
    END { c = 0; for (k in b) c++; print c + 0 }' "$SWEEPS"
}

for f in bin/jobs-client.sh bin/lib/pr-record.sh; do
  [ -r "$H/$f" ] || { log "missing $f; prr-sweep $CMD skipped"; exit 0; }
done
# shellcheck source=/dev/null
{ . "$H/bin/jobs-client.sh"; . "$H/bin/lib/pr-record.sh"; }
set +e   # the jobs client turns errexit on; this lane handles each rc itself

# seam_lanes — the lanes that read the record through a seam file.
seam_lanes() { local s; for s in "$H"/bin/lib/prr-shadow.d/*.sh; do [ -r "$s" ] && basename "$s" .sh; done; }
# lane_step <lane> — record, shadow or off; `shadow` (the fallback of the knob GH_SOURCE) when the row is absent.
lane_step() {
  local v rc=0
  v=$(setting_get "lane.$1.gh_source" 2>/dev/null) || rc=$?
  case "$rc:$v" in 0:record|0:shadow|0:off) printf '%s' "$v" ;; 2:*) printf shadow ;; *) printf unknown ;; esac
}
# interval_row <lane> — "<settings key> TAB <current> TAB <max>" of the lane's
# timed full tick interval; rc 1 when the registry has no such knob or the row is unreadable.
interval_row() {
  local env reg meta def max key cur rc=0
  env="CADENCE_BACKSTOP_MIN_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
  reg="${LANE_REGISTRY:-}"
  [ -n "$reg" ] || { command -v _lg_registry >/dev/null 2>&1 && reg=$(_lg_registry 2>/dev/null); }
  [ -n "$reg" ] || reg="$H/catalog/lanes.json"
  meta=$(jq -r --arg e "$env" '.libs[]? | select(.id == "cadence-backstop") | .knobs[]? | select(.env == $e) | "\(.default)\t\(.max)"' "$reg" 2>/dev/null)
  IFS=$'\t' read -r def max <<<"$meta"
  [[ "$def" =~ ^[0-9]+$ ]] && [[ "$max" =~ ^[0-9]+$ ]] || return 1
  key="lib.cadence-backstop.$(printf '%s' "$env" | tr 'A-Z' 'a-z')"
  cur=$(setting_get "$key" 2>/dev/null) || rc=$?
  case "$rc" in 0) ;; 2) cur=$def ;; *) return 1 ;; esac
  [[ "$cur" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s\t%s\n' "$key" "$cur" "$max"
}

do_report() {
  local n lane row key cur max
  n=$(now)
  if [ -r "$LEDGER" ]; then
    awk -F'\t' -v d="$((n - 86400))" -v w="$((n - QUIET_S))" '$1 ~ /^[0-9]+$/ && $1 > w { b[$2]++; if ($1 > d) a[$2]++ }
      END { for (r in b) printf "repo=%s fixes_24h=%d fixes_%dd=%d\n", r, a[r] + 0, '"$QUIET_DAYS"', b[r] }' "$LEDGER" | LC_ALL=C sort
  fi
  for row in "$STATE"/attempt/*; do
    [ -e "$row" ] && echo "swept=${row##*/} days=$(sweep_days "$n" "${row##*/}")/$QUIET_DAYS"
  done
  for lane in $(seam_lanes); do
    if row=$(interval_row "$lane"); then IFS=$'\t' read -r key cur max <<<"$row"; row="$key=$cur"; else row=none; fi
    echo "lane=$lane step=$(lane_step "$lane") fixes_${QUIET_DAYS}d=$(ledger_count "$((n - QUIET_S))") interval=$row"
  done
}

# why <text> — a "no raise" reason: printed by the raise command, not by a tick (288 ticks a day).
why() { [ "$CMD" = tick ] || echo "raise: $*"; }
# ledger_add <epoch> <repo> <n> <field> — one row, under the ledger lock (the project runs write side by side).
ledger_add() {
  ( flock -w 10 8 || exit 0; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$LEDGER" ) 8>"$LEDGER.lock"
}
do_raise() {
  local n first age fixes lane row key cur max new mark last f c
  n=$(now)
  [ "$RAISE_FACTOR" -gt 1 ] || { why "PRR_SWEEP_RAISE_FACTOR is 1; no raise"; return 0; }
  first=$(head -c 20 "$STATE/first-sweep" 2>/dev/null | tr -dc '0-9')
  [ -n "$first" ] || { why "no sweep ran on this box yet; no raise"; return 0; }
  age=$((n - first))
  [ "$age" -ge "$QUIET_S" ] || { why "the first sweep is ${age}s old, under $QUIET_DAYS days; no raise"; return 0; }
  # "0 fixes" counts only when the sweep ran: each tried repo needs a completed
  # sweep in each 24-hour window. A lane that was off, or a repo whose list
  # read fails, stops the raise.
  for f in "$STATE"/attempt/*; do
    [ -e "$f" ] || continue
    c=$(sweep_days "$n" "${f##*/}")
    [ "$c" -ge "$QUIET_DAYS" ] || { why "${f##*/}: a sweep completed in $c of the last $QUIET_DAYS days; no raise"; return 0; }
  done
  fixes=$(ledger_count "$((n - QUIET_S))")
  [ "$fixes" = 0 ] || { why "$fixes sweep fixes in $QUIET_DAYS days; no raise"; return 0; }
  for lane in $(seam_lanes); do
    [ "$(lane_step "$lane")" = record ] || continue
    row=$(interval_row "$lane") || { why "$lane: no interval row"; continue; }
    IFS=$'\t' read -r key cur max <<<"$row"
    new=$((cur * RAISE_FACTOR)); [ "$new" -le "$max" ] || new=$max
    [ "$new" -gt "$cur" ] || { why "$lane: $key=$cur is at its limit"; continue; }
    mark="$STATE/raise/$lane"
    last=$(head -c 20 "$mark" 2>/dev/null | tr -dc '0-9')
    if [ -n "$last" ] && [ $((n - last)) -lt "$QUIET_S" ]; then why "$lane: raised $((n - last))s ago; no raise"; continue; fi
    if [ "$DRY" = 1 ]; then echo "raise: $lane: would set $key $cur -> $new (dry run)"; continue; fi
    if setting_set "$key" "$new" "BH-9939 prr-sweep: 0 sweep fixes in $QUIET_DAYS days, was $cur" >/dev/null 2>&1; then
      mkdir -p "$STATE/raise" 2>/dev/null; printf '%s\n' "$n" > "$mark"
      slog "PRR_SWEEP_RAISE lane=$lane key=$key from=$cur to=$new"
      echo "raise: $lane: set $key $cur -> $new"
    else
      echo "raise: $lane: the settings write of $key failed; the next tick retries"
    fi
  done
}

case "$CMD" in
  report) do_report; exit 0 ;;
  raise) mkdir -p "$STATE" 2>/dev/null; do_raise; exit 0 ;;
esac

# ---- tick and project ---------------------------------------------------------
# shellcheck source=bin/lib/hub-box.sh
. "$H/bin/lib/hub-box.sh" 2>/dev/null || { log "missing bin/lib/hub-box.sh; prr-sweep $CMD skipped"; exit 0; }
BOX=$(local_box_name)
if ! is_hub_box "$BOX"; then log "not the hub (${BOX:-unnamed}); prr-sweep runs on the hub only"; exit 0; fi
[ "$INTERVAL_MIN" -gt 0 ] || exit 0
mkdir -p "$STATE/last" "$STATE/cursor" "$STATE/alerted" "$STATE/lock" "$STATE/attempt" 2>/dev/null

if [ "$CMD" = tick ]; then
  # shellcheck source=bin/lib/project-lanes.sh
  . "$H/bin/lib/project-lanes.sh" 2>/dev/null
  command -v pl_dispatch >/dev/null 2>&1 || { log "missing bin/lib/project-lanes.sh; prr-sweep tick skipped"; exit 0; }
  # Retention: ledger and sweep rows older than the raise window plus one day
  # go, and so does the attempt stamp of a repo the lane no longer tries.
  for f in "$LEDGER" "$SWEEPS"; do
    [ -s "$f" ] || continue
    ( flock -w 10 8 || exit 0
      awk -F'\t' -v s="$(( $(now) - QUIET_S - 86400 ))" '$1 ~ /^[0-9]+$/ && $1 > s' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
    ) 8>"$LEDGER.lock"
  done
  find "$STATE/attempt" -type f -mmin +$(( (QUIET_DAYS + 1) * 1440 )) -delete 2>/dev/null
  # 300 s is the period of this lane's cron line: the runs start spread over one period.
  log "$(pl_dispatch prr-sweep 300 "$H/bin/prr-sweep.sh" project 2>&1)"
  do_raise >> "$LOG" 2>&1
  exit 0
fi

# ---- project <project>: one repo ----------------------------------------------
for f in bin/lib/gh-rest.sh bin/lib/gh-rest-list.sh; do
  [ -r "$H/$f" ] || { log "missing $f; prr-sweep project $P skipped"; exit 0; }
done
# shellcheck source=/dev/null
{ . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/gh-rest-list.sh"; }
# shellcheck source=bin/lib/gh-budget.sh
. "$H/bin/lib/gh-budget.sh" 2>/dev/null || true
# shellcheck source=bin/lib/gh-app-auth.sh
. "$H/bin/lib/gh-app-auth.sh" 2>/dev/null || true
set +e

SLUG="${PL_SLUG:-}"
[ -n "$SLUG" ] || SLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null)
[[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 0
RKEY=$(safe "$(printf '%s' "$SLUG" | tr 'A-Z' 'a-z')")
# A sweep dedupe, never a queue: a second run for the same repo skips.
exec 7>"$STATE/lock/$RKEY"; flock -n 7 || exit 0
W=$(mktemp -d "${TMPDIR:-/tmp}/prr-sweep.XXXXXX") || { log "mktemp failed; sweep of $SLUG skipped"; exit 0; }
trap 'rm -rf "$W"' EXIT

# The interval in use (header, THE TRUST WINDOW).
INTERVAL_S=$((INTERVAL_MIN * 60)); USED_S=$INTERVAL_S; WINDOW_NOTE=""
WIN=$(pr_record_list_max_age 2>/dev/null)
if [[ "$WIN" =~ ^[0-9]+$ ]] && [ "$WIN" -gt 0 ] && [ "$WIN" -lt $((INTERVAL_S + LIST_SLACK_S)) ]; then
  USED_S=$((WIN - LIST_SLACK_S)); [ "$USED_S" -gt 0 ] || USED_S=0
  WINDOW_NOTE="PRR_SWEEP_WINDOW window_s=$WIN interval_s=$INTERVAL_S used_s=$USED_S"
fi
# Cron starts a tick some seconds late; without this a 60 minute interval on a
# 5 minute line is 65 minutes (the rule of bin/lib/cadence-backstop.sh).
JITTER_S=30
T0=$(now)

GH_CALLS=0; FIXES=0; STALE=0; PR_READS=0
# put_fix <repo> <n> <fields-json> <at> [count-only-field] — one record write.
# Each applied field is a fix, each refused field one STALE line. With
# <count-only-field>, only that field is counted and logged.
put_fix() {
  local repo="$1" n="$2" fields="$3" at="$4" only="${5:-}" res f
  res=$(pr_record_put "$repo" "$n" github "$fields" "$at" 2>/dev/null) || { PARTIAL=1; log "$repo#$n: the record write failed; the next sweep retries"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -z "$only" ] || [ "$f" = "$only" ] || continue
    FIXES=$((FIXES + 1))
    ledger_add "$T0" "$repo" "$n" "$f"
    slog "PRR_SWEEP_FIX repo=$repo n=$n field=$f"
  done < <(jq -r '.applied[]' <<<"$res" 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -z "$only" ] || [ "$f" = "$only" ] || continue
    STALE=$((STALE + 1))
    slog "PRR_SWEEP_STALE repo=$repo n=$n field=$f"
  done < <(jq -r '.stale[]' <<<"$res" 2>/dev/null)
  return 0
}

# sweep_repo <owner/repo> <last-sweep epoch or 0> — rc 0 when the sweep compared
# everything; rc 2 when a compare or a write failed (PARTIAL=1), which renews the
# interval stamp but is not a completed sweep, so it never counts toward a raise;
# rc 1 when a list was unreadable.
sweep_repo() {
  local repo="$1" last="$2" lr s start since out complete=1 n kind fields row head p c budget cur picks sync=skipped
  lr=$(printf '%s' "$repo" | tr 'A-Z' 'a-z'); s=$(safe "$lr")
  GH_CALLS=0; FIXES=0; STALE=0; PR_READS=0; PARTIAL=0
  start=$(iso "$T0")
  [ "$last" -gt 0 ] || last=$((T0 - 2 * USED_S))
  since=$(iso $((T0 - 2 * USED_S)))

  # The record's open rows, as they are.
  if ! out=$(_jobs_req GET "/api/pr-records?repo=$lr&state=open") || ! jq -e '(.rows | type) == "array"' <<<"$out" >/dev/null 2>&1; then
    log "$lr: the record's open list is unreadable; the next tick retries"; return 1
  fi
  jq -c '.rows' <<<"$out" > "$W/rec.json"
  local rec_cut; rec_cut=$(jq -r '.truncated == true' <<<"$out" 2>/dev/null)
  # GitHub's open list. 1000 rows is the pager's own stop (ten pages, bin/lib/gh-rest-list.sh).
  gh_rest_pr_list_all "$repo" open 1000 > "$W/gh.json" 2>/dev/null || { log "$lr: GitHub's open list is unreadable (rc $?, ${GH_REST_REASON:-}); the next tick retries"; return 1; }
  c=$(jq 'length' "$W/gh.json" 2>/dev/null) || { log "$lr: GitHub's open list is not a list"; return 1; }
  GH_CALLS=$((GH_CALLS + c / 100 + 1))
  [ "$c" -lt 1000 ] || { complete=0; PARTIAL=1; }

  # The PR fields, one JSON line per PR with a difference.
  jq -c --slurpfile rec "$W/rec.json" '
    def gh: {state: "open", draft: (.draft == true), title: .title, head_ref: .head.ref,
             head_sha: ((.head.sha // "") | ascii_downcase), base_ref: .base.ref, labels: ([.labels[]?.name] | sort)};
    def rc: {state: "open", draft: (.draft == true or .draft == 1), title: .title, head_ref: .head_ref,
             head_sha: ((.head_sha // "") | ascii_downcase), base_ref: .base_ref, labels: ((.labels // []) | sort)};
    ($rec[0] | map({key: (.number | tostring), value: .}) | from_entries) as $R
    | (map({key: (.number | tostring), value: .}) | from_entries) as $G
    | ($G | to_entries[] | .key as $n | (.value | gh | with_entries(select(.value != null))) as $g
        | if $R[$n] == null then {n: $n, kind: "new", fields: $g}
          else ($R[$n] | rc) as $r | ($g | with_entries(select($r[.key] != .value))) as $d
            | if ($d | length) > 0 then {n: $n, kind: "diff", fields: $d} else empty end end),
      ($R | keys[] | select($G[.] == null) | {n: ., kind: "gone", fields: {}})' "$W/gh.json" > "$W/diff.jsonl" 2>/dev/null \
    || { log "$lr: the compare failed; the next tick retries"; return 1; }
  budget=$PR_READS_MAX
  while IFS= read -r row; do
    n=$(jq -r '.n' <<<"$row"); kind=$(jq -r '.kind' <<<"$row"); fields=$(jq -c '.fields' <<<"$row")
    case "$kind" in
      diff) put_fix "$lr" "$n" "$fields" "$start" ;;
      # A cut record page cannot say "the record lacks this PR".
      new) [ "$rec_cut" = true ] || put_fix "$lr" "$n" "$fields" "$start" state ;;
      gone)
        # Only a complete list can say "not open". One GitHub read, which writes the state.
        [ "$complete" = 1 ] || continue
        # Out of per-PR reads: this PR's state is not compared, so the sweep is partial.
        [ "$budget" -gt 0 ] || { PARTIAL=1; continue; }
        budget=$((budget - 1)); PR_READS=$((PR_READS + 1)); GH_CALLS=$((GH_CALLS + 1))
        out=$(PR_RECORD_FRESH=1 pr_record_get "$lr" "$n" state 2>/dev/null) || { PARTIAL=1; continue; }
        case "$(jq -r '.state // empty' <<<"$out" 2>/dev/null)" in
          merged|closed)
            FIXES=$((FIXES + 1)); ledger_add "$T0" "$lr" "$n" state
            slog "PRR_SWEEP_FIX repo=$lr n=$n field=state" ;;
        esac ;;
    esac
  done < "$W/diff.jsonl"

  # The record rows of the open PRs (checks and statuses are not in the list read).
  : > "$W/rows.jsonl"
  while IFS= read -r n; do
    out=$(_jobs_req GET "/api/pr-records?repo=$lr&number=$n" 2>/dev/null) && jq -ce '.row | objects' <<<"$out" >> "$W/rows.jsonl" 2>/dev/null \
      || { PARTIAL=1; log "$lr#$n: the record row is unreadable; checks and statuses not compared for it"; }
  done < <(jq -r '.[].number' "$W/gh.json")

  # Checks: the workflow runs since <since>.
  echo '[]' > "$W/runs.json"; p=0; c=100
  while [ "$p" -lt "$RUNS_PAGES" ] && [ "$c" -ge 100 ]; do
    p=$((p + 1)); GH_CALLS=$((GH_CALLS + 1))
    gh_rest GET "repos/$repo/actions/runs" -f "created=>=$since" -F per_page=100 -F "page=$p" > "$W/runs.page" 2>/dev/null \
      || { PARTIAL=1; log "$lr: the workflow runs are unreadable (rc $?, ${GH_REST_REASON:-}); checks not compared"; echo '[]' > "$W/runs.json"; break; }
    c=$(jq '.workflow_runs | length' "$W/runs.page" 2>/dev/null) || { PARTIAL=1; c=0; break; }
    jq -c -s '.[0] + .[1].workflow_runs' "$W/runs.json" "$W/runs.page" > "$W/runs.tmp" 2>/dev/null && mv -f "$W/runs.tmp" "$W/runs.json"
  done
  # One line per PR with a checks difference: {n, checks: <the merged object>}.
  # A workflow name the worker refuses (a quote, a backslash, a control
  # character, over 100 characters with its prefix) is left out. The merged
  # object keeps at most 100 names (the worker's CHECKS_MAX), the head's first.
  jq -c -n --slurpfile gh "$W/gh.json" --slurpfile runs "$W/runs.json" --arg at "$start" '
    ([inputs] | map({key: (.number | tostring), value: .}) | from_entries) as $rows
    | ($runs[0] | map(select((.name | type) == "string" and (.name | test("^[^\"\\\\\\p{Cc}]{1,91}$")))
        | {h: ((.head_sha // "") | ascii_downcase), k: "workflow:\(.name)", t: (.run_started_at // .created_at // ""),
           a: (.run_attempt // 1), s: (.status // ""), c: .conclusion})
        | group_by([.h, .k]) | map(sort_by(.t, .a) | last)) as $new
    | $gh[0][] | (.number | tostring) as $n | ((.head.sha // "") | ascii_downcase) as $h
    | ($rows[$n].checks | if type == "object" then . else {} end) as $old
    | [$new[] | select(.h == $h) | select(($old[.k] | type) != "object" or (($old[.k].sha // "") | ascii_downcase) != $h
          or $old[.k].status != .s or $old[.k].conclusion != .c)] as $d
    | select(($d | length) > 0 and $rows[$n] != null)
    | ($old + ($d | map({key: .k, value: {status: .s, conclusion: .c, sha: $h, at: $at}}) | from_entries)) as $m
    | {n: $n, checks: ($m | to_entries | sort_by(if ((.value.sha // "") | ascii_downcase) == $h then 0 else 1 end) | .[:100] | from_entries)}' \
    "$W/rows.jsonl" > "$W/checks.jsonl" 2>/dev/null || : > "$W/checks.jsonl"
  while IFS= read -r row; do
    put_fix "$lr" "$(jq -r '.n' <<<"$row")" "$(jq -c '{checks}' <<<"$row")" "$start" checks
  done < "$W/checks.jsonl"

  # Statuses: the PRs to read, first the ones with a reason, then the rotation.
  cur=$(head -c 12 "$STATE/cursor/$s" 2>/dev/null | tr -dc '0-9'); [ -n "$cur" ] || cur=0
  picks=$(jq -r -n --slurpfile gh "$W/gh.json" --slurpfile runs "$W/runs.json" --argjson last "$last" --argjson cur "$cur" \
      --argjson budget "$budget" --argjson rot "$STATUS_ROTATE" '
    ([inputs] | map({key: (.number | tostring), value: .}) | from_entries) as $rows
    | ([$runs[0][] | (.head_sha // "") | ascii_downcase] | unique) as $rh
    | [$gh[0][] | select(.draft != true) | ((.head.sha // "") | ascii_downcase) as $h | select($h | test("^[0-9a-f]{40}$"))
        | {n: .number, h: $h,
           why: (if any(($rows[.number | tostring].statuses // {})[]?; type == "object" and .state == "pending" and ((.sha // "") | ascii_downcase) == $h) then 1
                 elif ((.updated_at // "") | (try fromdateiso8601 catch 0)) > $last or ($rh | index($h)) != null then 1 else 0 end)}] as $all
    | ([$all[] | select(.why == 1)] | sort_by(.n) | .[:$budget]) as $first
    | ([$all[] | select(.why == 0)] | sort_by(.n)) as $rest
    | (([$rest[] | select(.n > $cur)] + [$rest[] | select(.n <= $cur)]) | .[:([$rot, $budget - ($first | length)] | min | if . < 0 then 0 else . end)]) as $turn
    | ($first[] | "\(.n)\t\(.h)\t0"), ($turn[] | "\(.n)\t\(.h)\t1")' "$W/rows.jsonl" 2>/dev/null)
  while IFS=$'\t' read -r n head p; do
    [ -n "$n" ] || continue
    PR_READS=$((PR_READS + 1)); GH_CALLS=$((GH_CALLS + 1))
    [ "$p" = 1 ] && printf '%s\n' "$n" > "$STATE/cursor/$s"
    gh_rest GET "repos/$repo/commits/$head/status" -F per_page=100 > "$W/status.json" 2>/dev/null || { PARTIAL=1; continue; }
    # The merged statuses object when a context is missing or its state differs; else nothing.
    fields=$(jq -c --slurpfile rows "$W/rows.jsonl" --argjson n "$n" --arg h "$head" --arg at "$start" '
      ([$rows[] | select(.number == $n)] | first) as $r | select($r != null)
      | ($r.statuses | if type == "object" then . else {} end) as $old
      | [.statuses[]? | select((.context | type) == "string" and (.context | test("^[^\"\\\\\\p{Cc}]{1,100}$"))
            and (.state | IN("pending", "success", "failure", "error")))
          | select(($old[.context] | type) != "object" or (($old[.context].sha // "") | ascii_downcase) != $h or $old[.context].state != .state)] as $d
      | select(($d | length) > 0)
      | {statuses: (($old + ($d | map({key: .context, value: {state, description: ((.description // null) | if type == "string" then .[:1024] else null end), sha: $h, at: $at}}) | from_entries))
          | to_entries | sort_by(if ((.value.sha // "") | ascii_downcase) == $h then 0 else 1 end) | .[:100] | from_entries)}' "$W/status.json" 2>/dev/null)
    [ -n "$fields" ] && put_fix "$lr" "$n" "$fields" "$start" statuses
  done <<<"$picks"

  # The list write renews the sync stamp. Only an uncut list is a full list.
  if [ "$complete" = 1 ]; then
    if pr_record_list_sync "$lr" open "$W/gh.json" "$start" >/dev/null 2>&1; then sync=ok; else sync=failed; PARTIAL=1; fi
    # BH-9938 C1: each GitHub list read also writes the default-branch memo and
    # the cross-repo memo, which pr_record_open_rest needs to serve the list.
    command -v pr_record_default_branch_note >/dev/null 2>&1 && pr_record_default_branch_note "$repo" "$W/gh.json" full
  fi
  log "$lr open=$(jq 'length' "$W/gh.json") fixes=$FIXES stale=$STALE gh_calls=$GH_CALLS pr_reads=$PR_READS sync=$sync partial=$PARTIAL"

  # The 24-hour limit: one alert while a repo is above it.
  if [ "$ALERT_24H" -gt 0 ]; then
    c=$(ledger_count "$((T0 - 86400))" "$lr")
    if [ "$c" -gt "$ALERT_24H" ]; then
      "$H/bin/lane-alert.sh" --severity warn --id "prr-sweep-fixes:$lr" prr-sweep \
        "prr-sweep: $c sweep fixes for $lr in 24 hours, above the limit $ALERT_24H (lane.prr-sweep.prr_sweep_fix_alert_24h). A webhook of that repo is missing or late. Run bin/doorbell-coverage-check.sh and read the PRR_SWEEP_FIX lines in logs/prr-shadow.log." >/dev/null 2>&1 \
        && : > "$STATE/alerted/$s"
    elif [ -e "$STATE/alerted/$s" ]; then
      "$H/bin/lane-alert.sh" --resolve --id "prr-sweep-fixes:$lr" prr-sweep \
        "prr-sweep: $c sweep fixes for $lr in 24 hours, at or under the limit $ALERT_24H." >/dev/null 2>&1 \
        && rm -f "$STATE/alerted/$s"
    fi
  fi
  [ "$PARTIAL" = 0 ] || return 2
  return 0
}

SF="$STATE/last/$RKEY"
LAST=$(head -c 20 "$SF" 2>/dev/null | tr -dc '0-9'); [ -n "$LAST" ] || LAST=0
if [ "$LAST" -gt 0 ] && [ "$LAST" -le "$T0" ] && [ $((T0 - LAST)) -lt $((USED_S - JITTER_S)) ]; then exit 0; fi
if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low prr-sweep >/dev/null 2>&1; then log "budget low; $SLUG skipped this tick"; exit 0; fi
[ -z "$WINDOW_NOTE" ] || slog "$WINDOW_NOTE"
[ -s "$STATE/first-sweep" ] || printf '%s\n' "$T0" > "$STATE/first-sweep"
: > "$STATE/attempt/$RKEY"
# The runner armed the repo's App token (pl_token). A run by hand arms it here.
[ -n "${PL_LANE:-}" ] || { command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$SLUG" || true; }; }
sweep_repo "$SLUG" "$LAST"; RC=$?
# rc 0: a completed sweep (one sweeps.tsv row, which the raise counts).
# rc 2: partial; the interval stamp holds the next try off, but no sweeps.tsv row.
case "$RC" in
  0) printf '%s\n' "$T0" > "$SF"
     ( flock -w 10 8 || exit 0; printf '%s\t%s\n' "$T0" "$RKEY" >> "$SWEEPS" ) 8>"$LEDGER.lock" ;;
  2) printf '%s\n' "$T0" > "$SF" ;;
esac
exit 0
