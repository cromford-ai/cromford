#!/bin/bash
# bin/outcome-check.sh — did a merged perf PR move the metric it said it would?
# One hub lane, every 30 minutes.
#
# WHY (BH-6372, slice BH-6382). A perf/cost PR states its goal as one line,
# `Target metric: <id> from <a> to <b>`. Nothing checked that line after the
# merge. This lane measures the metric on live data at merge + DELAY_H. When
# the metric did not move toward the target, it files ONE issue on the PR's
# repo with the numbers and the PR link. It never builds and never labels.
#
# PER TICK, each step a stop when it fails:
#   1. no JOBS_URL or HARNESS_SECRET: log "not configured", exit 0, no read.
#   2. bin/lib/gh-budget.sh says the bucket is low: log, exit 0, no read.
#   3. `job_ledger_list merge 500`. Unreadable = rc 1, one log line, no POST.
#      Kept: status `merged`, updated_at inside OUTCOME_CHECK_LOOKBACK_H.
#   4. `job_ledger_list outcome-check 1000` (the worker's list cap): the
#      done-set. Unreadable = rc 1, one log line, no POST. Terminal statuses:
#      filed moved insufficient unmeasurable unparseable no-direction no-target
#      not-perf. Retried: wait, file-failed, filing.
#   5. candidates: merged rows with no terminal row and updated_at + DELAY_H
#      <= now, oldest first. At most OUTCOME_CHECK_MAX_PRS of them, and none
#      started after OUTCOME_CHECK_DEADLINE_S; the rest are logged `deferred`.
#   6. per PR (any failed read = skip, no row, retried next tick):
#      a. GET the PR. merged_at null = skip. merged_at + DELAY_H > now = skip
#         (GitHub's merged_at is the authority; the ledger time only filters).
#      b. perf? The first `closes|fixes|resolves|refs|part of #N` in the PR
#         body: pt_classify_issue on #N. No link: pt_classify on the PR's own
#         body, title and labels. rc 1 = `not-perf`. rc 3 = skip.
#      c. pt_parse_target on the PR body. No parse and a `Target metric:` line
#         = `unparseable` + one ALERTS line. No such line = `no-target`.
#      d. from == to = `no-direction`.
#      e. no bin/lib/outcome-metrics.d/<id>.sh = `unmeasurable` + one ALERTS line.
#      f. `om_<id> <merged_at> <now>` (OM_REPO = the PR's repo, 120 s cap). A
#         failed or malformed answer = skip.
#      g. n < MIN_SAMPLES: `wait` (put once), or at merge + MAX_WAIT_H
#         `insufficient` + one ALERTS line.
#      h. moved = |measured - to| < |from - to|: `moved`. Else file:
#         put `filing` -> search issues (open and closed) for the marker
#         `<!-- outcome-check: <repo>#<pr> -->` -> found: `filed` with its number
#         -> else POST the issue (no labels) -> `filed issue=<n>`. A failed put
#         before the POST = no POST. A failed or unverifiable search or POST =
#         `file-failed`. A failed put after the POST leaves `filing`, and the
#         next tick's search finds the issue.
#   7. one summary line.
# Every status is a `ledgers` row: kind outcome-check, key = the PR url, detail
# `<id> from <a> to <b> measured <m> n=<k>[ issue=<i>]`. The log line
# `outcome-check: <repo>#<pr> <id> from <a> to <b> measured <m> (n=<k>) -> <status>`
# and any ALERTS line are written only after that put returned 0.
# Worst case per tick: MAX_PRS x (PR read + 2 issue reads + 1 search + 1 POST)
# GitHub calls (250 at the defaults). A PR is read until it has a terminal row.
#
# usage: outcome-check.sh [--dry-run]    --dry-run reads and decides, prints each
#        would-be line; no put, no search, no POST, no ALERTS line. It is the
#        hub live probe `outcome-check-dry-run` (catalog/live-probes.tsv), so it
#        skips lane_gate_or_exit (no start-offset sleep, no liveness row) and
#        prints one line, not nothing, when the lane is paused or a tick holds
#        the lock.
# Kill switch: bin/harness-ctl.sh off outcome-check (flags/lane-off-outcome-check)
# Tests: tests/outcome-check.bh-6372-test.sh, tests/outcome-check-probe.bh-6463-test.sh
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# >>> lane gate (BH-1165)
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY=1
[ -z "${DRY:-}" ] && command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit outcome-check
if [ -n "$DRY" ] && command -v lane_paused >/dev/null 2>&1 && lane_paused outcome-check; then
  echo "paused: ${LANE_PAUSED_WHY:-?} — nothing read (dry run)"; exit 0
fi
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply outcome-check
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; [ -n "$BIN" ] || BIN="$H/bin"
NOW="${NOW:-$(date +%s)}"
LOG="$H/logs/outcome-check.log"
mkdir -p "$(dirname "$LOG")" "$H/locks" 2>/dev/null
STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) $*" >> "$LOG"; [ -n "$DRY" ] && echo "$*"; return 0; }
for _L in gh-budget.sh gh-app-auth.sh; do
  # shellcheck source=/dev/null
  if [ -r "$BIN/lib/$_L" ]; then . "$BIN/lib/$_L"; elif [ -r "$H/bin/lib/$_L" ]; then . "$H/bin/lib/$_L"; fi
done
# shellcheck source=bin/lib/gh-rest.sh
. "$BIN/lib/gh-rest.sh" || { log "bin/lib/gh-rest.sh did not load — nothing read"; exit 1; }
# shellcheck source=bin/lib/perf-ticket.sh
. "$BIN/lib/perf-ticket.sh" || { log "bin/lib/perf-ticket.sh did not load — nothing read"; exit 1; }
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$BIN/lib/deployment.sh}" || exit 1  # BH-4080: HARNESS_REPO
JC="$BIN/jobs-client.sh"; [ -r "$JC" ] || JC="$H/bin/jobs-client.sh"
# shellcheck source=/dev/null
. "$JC" 2>/dev/null || true
exec 9>"$H/locks/outcome-check.lock"
if ! flock -n 9; then
  [ -n "$DRY" ] && echo "skipped: a tick holds locks/outcome-check.lock — nothing read (dry run)"
  exit 0
fi
knob() { # knob <ENV> <default> — row/env via lane_env_apply, else the default; a positive integer
  local v="${!1:-}"
  case "$v" in ''|*[!0-9]*|0) v="$2" ;; esac
  printf '%s' "$v"
}
DELAY_H=$(knob OUTCOME_CHECK_DELAY_H 6)
LOOKBACK_H=$(knob OUTCOME_CHECK_LOOKBACK_H 48)
MIN_SAMPLES=$(knob OUTCOME_CHECK_MIN_SAMPLES 5)
MAX_WAIT_H=$(knob OUTCOME_CHECK_MAX_WAIT_H 24)
MAX_PRS=$(knob OUTCOME_CHECK_MAX_PRS 50)
DEADLINE_S=$(knob OUTCOME_CHECK_DEADLINE_S 600)
OMD="$BIN/lib/outcome-metrics.d"
NOW_ISO=$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')
SINCE=$(date -u -d "@$(( NOW - LOOKBACK_H * 3600 ))" '+%Y-%m-%dT%H:%M:%SZ')
TERMINAL="filed moved insufficient unmeasurable unparseable no-direction no-target not-perf"

# 1. no worker to record into
if ! command -v jobs_configured >/dev/null 2>&1 || ! jobs_configured || [ -z "${HARNESS_SECRET:-}" ]; then
  log "not configured (JOBS_URL/HARNESS_SECRET unset) — nothing checked"
  exit 0
fi
# 2. the GitHub budget
if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low outcome-check; then
  log "skipped: the GitHub API budget is low (bin/lib/gh-budget.sh) — no reads this tick"
  exit 0
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/outcome-check.XXXXXX") || { log "mktemp failed — nothing read"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

# 3. the merges in the lookback
if ! job_ledger_list merge 500 > "$TMP/merge"; then
  log "ledger unreadable (kind merge, http=${JOBS_HTTP:-none}) — nothing checked, no POST"
  exit 1
fi
# 4. the done-set
if ! job_ledger_list outcome-check 1000 > "$TMP/done"; then
  log "ledger unreadable (kind outcome-check, http=${JOBS_HTTP:-none}) — nothing checked, no POST"
  exit 1
fi
declare -A CUR=()
while IFS=$'\t' read -r k s _; do
  [ -n "$k" ] && CUR[$k]="$s"
done < "$TMP/done"
# 5. the candidates, oldest first: <updated_at> TAB <url>
SEEN=0
: > "$TMP/cand"
while IFS=$'\t' read -r k s _ u; do
  [ "$s" = merged ] && [ -n "$u" ] && [ "$u" != - ] && [[ "$u" > "$SINCE" || "$u" = "$SINCE" ]] || continue
  SEEN=$(( SEEN + 1 ))
  case " $TERMINAL " in *" ${CUR[$k]:-none} "*) continue ;; esac
  ue=$(date -u -d "$u" +%s 2>/dev/null) || continue
  [ $(( ue + DELAY_H * 3600 )) -le "$NOW" ] || continue
  printf '%s\t%s\n' "$u" "$k" >> "$TMP/cand"
done < "$TMP/merge"
sort -o "$TMP/cand" "$TMP/cand"
CAND=$(wc -l < "$TMP/cand" | tr -d ' ')

# The one PR in hand. record() writes its row, then its log line.
REPO=""; PRN=""; URL=""; MID=""; FROM=""; TO=""; M=""; N=""
DEC=0; FILED=0; WAITING=0; SKIP=0; DEFER=0
record() { # record <status> [issue] — rc 1 when the put failed
  local s="$1" iss="${2:-}" line
  line="outcome-check: $REPO#$PRN ${MID:--} from ${FROM:--} to ${TO:--} measured ${M:--} (n=${N:--}) -> $s"
  if [ -n "$DRY" ]; then echo "$line (dry run)"; return 0; fi
  if ! job_ledger_put outcome-check "$URL" "$s" "${MID:--} from ${FROM:--} to ${TO:--} measured ${M:--} n=${N:--}${iss:+ issue=$iss}"; then
    log "ledger write failed: $REPO#$PRN status $s (http=${JOBS_HTTP:-none}) — retried next tick"
    return 1
  fi
  log "$line${iss:+ issue=$iss}"
}
decided() { # decided <status> [issue] [alert text] — a terminal row, then its one ALERTS line
  record "$1" "${2:-}" || { SKIP=$(( SKIP + 1 )); return 1; }
  DEC=$(( DEC + 1 ))
  if [ -n "${3:-}" ] && [ -z "$DRY" ]; then
    HARNESS="$H" "$H/bin/alert-line.sh" --id "outcome-check-$REPO-$PRN" "[outcome-check] $3" >/dev/null 2>&1 || true
  fi
  return 0
}

file_issue() { # the filing order: filing -> marker search -> POST -> filed
  local mark="<!-- outcome-check: $REPO#$PRN -->" title="outcome-check: $REPO#$PRN did not move $MID toward its target" hit num
  if [ -n "$DRY" ]; then decided filed; return; fi
  record filing || { SKIP=$(( SKIP + 1 )); return; }
  if ! gh_rest GET search/issues -f "q=repo:$REPO is:issue in:title \"outcome-check: $REPO#$PRN\"" -f per_page=100 > "$TMP/search" \
     || ! hit=$(jq -er --arg m "$mark" '[.items[]? | select((.body // "") | contains($m)) | .number] | first // ""' "$TMP/search" 2>/dev/null); then
    log "$REPO#$PRN: issue search unverifiable (HTTP $GH_REST_STATUS $GH_REST_REASON) — no POST"
    record file-failed; SKIP=$(( SKIP + 1 )); return
  fi
  if [ -n "$hit" ]; then
    decided filed "$hit" && FILED=$(( FILED + 1 )); return
  fi
  {
    echo "$mark"
    echo "PR: $URL"
    echo "Metric: $MID"
    echo "Target: from $FROM to $TO"
    echo "Measured: $M (n=$N) over $MAT to $NOW_ISO"
    echo
    echo "The metric did not move toward the target."
    echo "Check the PR's change, or correct its target."
  } > "$TMP/issue.md"
  num=""
  if gh_rest POST "repos/$REPO/issues" -f "title=$title" -F "body=@$TMP/issue.md" > "$TMP/post"; then
    num=$(jq -r '.number // empty' "$TMP/post" 2>/dev/null)
  fi
  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    log "$REPO#$PRN: issue POST failed (HTTP $GH_REST_STATUS $GH_REST_REASON) — retried next tick"
    record file-failed; SKIP=$(( SKIP + 1 )); return
  fi
  if decided filed "$num"; then FILED=$(( FILED + 1 ))
  else log "$REPO#$PRN: issue #$num is open but its row stays filing — the next tick's marker search finds it"; fi
}

check_one() {
  local re='^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)$' me linked cls crc out mrc
  REPO=""; PRN=""; MID=""; FROM=""; TO=""; M=""; N=""; MAT=""
  [[ "$URL" =~ $re ]] || { log "skip $URL: not a PR url"; SKIP=$(( SKIP + 1 )); return; }
  REPO="${BASH_REMATCH[1]}"; PRN="${BASH_REMATCH[2]}"
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$REPO"
  # a. the PR, and GitHub's merged_at
  if ! gh_rest GET "repos/$REPO/pulls/$PRN" > "$TMP/pr" || ! MAT=$(jq -r '.merged_at // ""' "$TMP/pr" 2>/dev/null); then
    log "skip $REPO#$PRN: PR read failed (HTTP $GH_REST_STATUS $GH_REST_REASON)"; SKIP=$(( SKIP + 1 )); return
  fi
  [ -n "$MAT" ] || { log "skip $REPO#$PRN: GitHub has no merged_at"; SKIP=$(( SKIP + 1 )); return; }
  me=$(date -u -d "$MAT" +%s 2>/dev/null) || { log "skip $REPO#$PRN: merged_at '$MAT' unreadable"; SKIP=$(( SKIP + 1 )); return; }
  [ $(( me + DELAY_H * 3600 )) -le "$NOW" ] || { SKIP=$(( SKIP + 1 )); return; }
  jq -r '.body // ""' "$TMP/pr" > "$TMP/body"
  # b. perf?
  linked=$(grep -oiE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?|refs?|part of):?[[:space:]]+#[0-9]+' "$TMP/body" | head -1 | grep -oE '[0-9]+$')
  if [ -n "$linked" ]; then
    cls=$(pt_classify_issue "$REPO" "$linked" 2>/dev/null); crc=$?
  else
    cls=$(pt_classify "$TMP/body" "$(jq -r '.title // ""' "$TMP/pr")" "$(jq -r '[.labels[]?.name] | join(",")' "$TMP/pr")" 2>/dev/null); crc=$?
  fi
  case "$crc" in
    0) ;;
    1) decided not-perf; return ;;
    *) log "skip $REPO#$PRN: perf classifier unknown (rc $crc${linked:+, issue #$linked})"; SKIP=$(( SKIP + 1 )); return ;;
  esac
  # c. the target line
  if ! out=$(pt_parse_target "$TMP/body"); then
    if grep -qE '^[[:space:]]*(- )?Target metric:' "$TMP/body"; then
      decided unparseable "" "$REPO#$PRN ($URL): perf PR ($cls) has a 'Target metric:' line that does not parse as '<id> from <n> to <n>'. Fix the line on the PR."
    else
      decided no-target
    fi
    return
  fi
  read -r MID FROM TO <<<"$out"
  # d. a target with no direction
  if awk -v a="$FROM" -v b="$TO" 'BEGIN { exit !(a + 0 == b + 0) }'; then decided no-direction; return; fi
  # e. a metric with no measurer
  if [ ! -r "$OMD/$MID.sh" ]; then
    decided unmeasurable "" "$REPO#$PRN ($URL): metric '$MID' has no measurer bin/lib/outcome-metrics.d/$MID.sh. Add one, or correct the target."
    return
  fi
  # f. measure
  out=$(OM_REPO="$REPO" timeout 120 bash -c '. "$1" 2>/dev/null; . "$2" || exit 3; shift 2; "$@"' om "$JC" "$OMD/$MID.sh" "om_${MID//-/_}" "$MAT" "$NOW_ISO" 2>/dev/null); mrc=$?
  if [ "$mrc" != 0 ] || ! [[ "$out" =~ ^(-?[0-9]+(\.[0-9]+)?|-)\ ([0-9]+)$ ]] || { [ "${BASH_REMATCH[1]}" = - ] && [ "${BASH_REMATCH[3]}" != 0 ]; }; then
    log "skip $REPO#$PRN: measurer $MID failed (rc $mrc, output '${out:0:80}') — retried next tick"; SKIP=$(( SKIP + 1 )); return
  fi
  M="${BASH_REMATCH[1]}"; N="${BASH_REMATCH[3]}"
  # g. enough samples?
  if [ "$N" -lt "$MIN_SAMPLES" ]; then
    if [ "$NOW" -ge $(( me + MAX_WAIT_H * 3600 )) ]; then
      decided insufficient "" "$REPO#$PRN ($URL): metric '$MID' had $N samples (need $MIN_SAMPLES) $MAX_WAIT_H h after the merge. The outcome is not measured."
    else
      if [ "${CUR[$URL]:-}" = wait ] || record wait; then WAITING=$(( WAITING + 1 )); else SKIP=$(( SKIP + 1 )); fi
    fi
    return
  fi
  # h. moved, or file
  if awk -v m="$M" -v f="$FROM" -v t="$TO" 'function abs(x) { return x < 0 ? -x : x }
       BEGIN { exit !(abs(m - t) < abs(f - t)) }'; then
    decided moved
  else
    file_issue
  fi
}

# 6. each candidate, up to MAX_PRS and the deadline
START=$SECONDS; I=0
while IFS=$'\t' read -r _ URL; do
  I=$(( I + 1 ))
  if [ "$I" -gt "$MAX_PRS" ] || [ $(( SECONDS - START )) -ge "$DEADLINE_S" ]; then DEFER=$(( DEFER + 1 )); continue; fi
  check_one
done < "$TMP/cand"
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset

# 7. the summary
[ "$DEFER" -gt 0 ] && log "deferred $DEFER to next tick (OUTCOME_CHECK_MAX_PRS=$MAX_PRS, OUTCOME_CHECK_DEADLINE_S=$DEADLINE_S)"
log "seen=$SEEN candidates=$CAND decided=$DEC filed=$FILED waiting=$WAITING skipped=$SKIP deferred=$DEFER${DRY:+ (dry run, nothing written)}"
exit 0
