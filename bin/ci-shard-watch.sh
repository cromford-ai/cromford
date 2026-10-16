#!/bin/bash
# bin/ci-shard-watch.sh — page when a Harness CI test shard runs close to its
# 45-minute timeout (hub, cron every 5 min).
#
# WHY (BH-6876). The tests-shard job of .github/workflows/harness-ci.yml has a
# 45-minute timeout-minutes. A shard that hits it fails the whole run, and the
# merge-queue batch with it, after the full 45 minutes are billed. This lane
# sees a shard that is still running past CI_SHARD_ALERT_MIN minutes, so a
# person hears of it while the run can still finish, not after it fails.
#
# PER TICK, each step a stop when it fails:
#   1. bin/lib/gh-budget.sh says the bucket is low: log, exit 0, no alert change.
#   2. no token can read CI_SHARD_WATCH_REPO: log, exit 0, no read.
#   3. GET the in-progress runs of harness-ci.yml (50 a page, one page). A failed
#      read: log, exit 0, no alert change (an unknown is never a resolve).
#   4. for at most CI_SHARD_WATCH_MAX_RUNS of them, oldest first: GET the run's
#      latest-attempt jobs. A failed read makes that run unknown.
#   5. a job is SLOW when its name starts with "Tests, traced (shard", its
#      status is in_progress, started_at is set and NOW - started_at is at least
#      CI_SHARD_ALERT_MIN x 60 s.
#   6. any slow job: ONE critical lane-alert, id ci-shard-slow:<owner/repo>,
#      naming at most 5 jobs. No slow job, every run read and none deferred:
#      a --resolve of that id. Otherwise (an unknown or a deferred run): nothing.
# At most 1 + CI_SHARD_WATCH_MAX_RUNS GitHub reads per tick. Nothing local is
# written but the log line.
#
# usage: ci-shard-watch.sh [--dry-run]   --dry-run prints `would: alert|resolve ...`
#                                       and calls no lane-alert
# Clock seam (tests): CI_SHARD_WATCH_NOW=<epoch seconds>.
# Kill switch: bin/harness-ctl.sh off ci-shard-watch (flags/lane-off-ci-shard-watch)
# Tests: tests/ci-shard-watch.bh-6876-test.sh
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# >>> lane gate (BH-1165)
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit ci-shard-watch
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply ci-shard-watch
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; [ -n "$BIN" ] || BIN="$H/bin"
for _L in gh-budget.sh gh-ci-read.sh gh-repo-token.sh; do
  # shellcheck source=/dev/null
  if [ -r "$BIN/lib/$_L" ]; then . "$BIN/lib/$_L"; elif [ -r "$H/bin/lib/$_L" ]; then . "$H/bin/lib/$_L"; fi
done
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY=1
# The clock seam is a test hook, not a knob: no settings row carries it.
NOW="${CI_SHARD_WATCH_NOW-}"
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac
LOG="$H/logs/ci-shard-watch.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { echo "$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ') $*" >> "$LOG"; [ -n "$DRY" ] && echo "$*"; return 0; }
knob() { # knob <ENV> <default> — a positive integer, else the default (said on stderr)
  local v="${!1:-}"
  case "$v" in
    '') v="$2" ;;
    *[!0-9]*|0*) echo "ci-shard-watch: $1='$v' is not a positive integer — using the default $2" >&2; v="$2" ;;
  esac
  printf '%s' "$v"
}
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$BIN/lib/deployment.sh}" 2>/dev/null || true  # BH-4080: HARNESS_REPO
REPO="${CI_SHARD_WATCH_REPO:-${HARNESS_REPO:-}}"
MIN=$(knob CI_SHARD_ALERT_MIN 35)
MAX=$(knob CI_SHARD_WATCH_MAX_RUNS 10)
SHARD_PREFIX='Tests, traced (shard '
AID="ci-shard-slow:$REPO"

if [ -z "$REPO" ]; then log "not configured (no CI_SHARD_WATCH_REPO) — nothing read"; exit 0; fi
# 1. the GitHub budget
if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low ci-shard-watch; then
  log "repo=$REPO skipped: the GitHub API budget is low (bin/lib/gh-budget.sh) — no reads, no alert change"
  exit 0
fi
# 2. a token that can read the repo
if command -v gh_repo_use_token >/dev/null 2>&1 && ! gh_repo_use_token "$REPO" 2>/dev/null; then
  log "repo=$REPO not configured: no token can read it — nothing read"
  exit 0
fi
command -v gh_ci_api >/dev/null 2>&1 || gh_ci_api() { shift; gh api "$@"; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ci-shard-watch.XXXXXX") || { log "mktemp failed — nothing read"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

# 3. the in-progress runs
if ! gh_ci_api "$REPO" "repos/$REPO/actions/workflows/harness-ci.yml/runs?status=in_progress&per_page=50" > "$TMP/runs" 2>/dev/null \
   || ! jq -e '.workflow_runs | type == "array"' "$TMP/runs" >/dev/null 2>&1; then
  log "repo=$REPO: the in-progress run list is unreadable — no alert change"
  exit 0
fi
# A run past the one page read is deferred too: unread is unknown.
read -r NRUNS TOTAL <<<"$(jq -r '"\(.workflow_runs | length) \(.total_count // 0)"' "$TMP/runs")"
case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac
[ "$TOTAL" -ge "$NRUNS" ] || TOTAL="$NRUNS"
DEFER=$(( TOTAL - NRUNS )); [ "$NRUNS" -gt "$MAX" ] && DEFER=$(( DEFER + NRUNS - MAX ))

# 4 + 5. each run, oldest first, up to MAX; one TSV row per slow job
READ=0; UNREAD=0; : > "$TMP/slow"
while IFS= read -r ID; do
  [ -n "$ID" ] || continue
  if ! gh_ci_api "$REPO" "repos/$REPO/actions/runs/$ID/jobs?filter=latest&per_page=100" > "$TMP/jobs" 2>/dev/null \
     || ! jq -e '.jobs | type == "array"' "$TMP/jobs" >/dev/null 2>&1; then
    UNREAD=$(( UNREAD + 1 )); continue
  fi
  READ=$(( READ + 1 ))
  jq -r --arg p "$SHARD_PREFIX" --argjson now "$NOW" --argjson lim "$(( MIN * 60 ))" --arg id "$ID" '
    .jobs[]
    | select(((.name // "") | startswith($p)) and .status == "in_progress" and ((.started_at // "") != ""))
    | ((.started_at | fromdateiso8601? // null)) as $s
    | select($s != null and ($now - $s) >= $lim)
    | [$id, ((.name | ltrimstr($p) | capture("^(?<n>[0-9]+)").n) // "?"),
       ((($now - $s) / 60) | floor), (if (.runner_name // "") == "" then "-" else .runner_name end)]
    | @tsv' "$TMP/jobs" >> "$TMP/slow" 2>/dev/null
done < <(jq -r '.workflow_runs | sort_by(.run_started_at // "", .id) | .[:'"$MAX"'][] | .id' "$TMP/runs")

SLOW=$(grep -c . "$TMP/slow")
ACTION=none
if [ "$SLOW" -gt 0 ]; then
  ACTION=raise
  TEXT="$SLOW CI shard job(s) past $MIN min (limit 45): $(head -5 "$TMP/slow" \
    | awk -F'\t' '{ printf "%srun %s shard %s %s min [%s]", (NR > 1 ? "; " : ""), $1, $2, $3, $4 }')"
  [ "$SLOW" -gt 5 ] && TEXT="$TEXT; +$(( SLOW - 5 )) more"
  if [ -n "$DRY" ]; then echo "would: alert --id $AID --severity critical ci-shard-watch: $TEXT"
  else "$H/bin/lane-alert.sh" --id "$AID" --severity critical ci-shard-watch "$TEXT" >/dev/null 2>&1 || true; fi
elif [ "$UNREAD" = 0 ] && [ "$DEFER" = 0 ]; then
  ACTION=resolve
  TEXT="no CI shard job past $MIN min ($NRUNS in-progress run(s) read)"
  if [ -n "$DRY" ]; then echo "would: resolve --id $AID ci-shard-watch: $TEXT"
  else "$H/bin/lane-alert.sh" --resolve --id "$AID" ci-shard-watch "$TEXT" >/dev/null 2>&1 || true; fi
fi
log "repo=$REPO runs=$TOTAL read=$READ deferred=$DEFER slow=$SLOW action=$ACTION${DRY:+ [dry-run]}"
exit 0
