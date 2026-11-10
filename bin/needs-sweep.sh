#!/bin/bash
# bin/needs-sweep.sh [--dry-run] — close the console build rows that ask for a
# person but are over (BH-9117). Hub only, daily at 05:35Z
# (cron/lanes/779-needs-sweep.cron). No LLM call.
#
# WHY. A builds row stays in a parked stage (plan_blocked, plan_deferred,
# plan_stale, plan_malformed) or in pr_created forever. No lane moves it when
# the ticket is rebuilt, merged or closed, and bin/sweep-stale-builds.sh takes
# non-parked stages only. NOW counted 3613 such rows on 2026-11-05.
#
# WHAT. Read the candidates (merged=0 rows in a NEEDS stage) from the console's
# Pages endpoint GET <console_pages_url>/api/needs-sweep/candidates, decide per
# row (ns_decide, first match wins), then POST the closes to
# /api/needs-sweep/apply in chunks of 100. The endpoint's UPDATE is guarded
# (still merged=0, still in a NEEDS stage, updated_at unchanged since the read)
# and the hub keeps no D1 access (BH-3905).
#
#   1 updated_at unreadable                          keep        undated
#   2 PR (github.com/../pull/N) merged (merged_at)   pr_merged   pr_merged
#   3 PR closed, merged_at null, closure settled     pr_closed   pr_closed
#   4 PR closed inside the settle window             keep        pr_unsettled
#     PR open, or the read failed / was capped       keep        pr_open | pr_unknown
#   5 no PR, a newer row for project + ticket        superseded  newer_row
#   6 no PR, older than console.needs.max_age_days   stale       aged
#   7 no PR, github-issues ticket is closed          stale       issue_closed
#   8 anything else                                  keep        live | ticket_unknown
#
# SETTLE (rule 3/4). mc_kick_ci closes a PR and reopens it seconds later
# (bin/lib/mc/settle.sh, 2026-09-15). pr_closed is terminal, so a closure is
# pr_closed only when mc_closed_settled says its closed_at is older than
# MC_CLOSED_SETTLE (the same window reconcile-prs and merge-sweep use). A
# younger one is kept and re-read on the next run. If settle.sh does not
# load, every closed PR is kept (pr_unsettled): this lane fails closed.
#
# The same apply call expires dead_letter commands older than the same window
# (commands_before = now - max_age_days).
#
# KNOBS (settings rows, read with setting_get; a missing or non-numeric row is
# the fallback): console.needs.max_age_days (14), console.needs.sweep_dry_run
# (1 = dry; an outage is dry), console.needs.sweep_max_rows (5000 changes per
# run), console.needs.sweep_max_reads (300 GitHub reads per run),
# console.needs.sweep_page_size (500 rows per candidates page),
# console.needs.sweep_apply_chunk (100 rows per apply call; keep it at or under
# the endpoint's NEEDS_SWEEP_APPLY_MAX), console.needs.sweep_http_timeout_s
# (30 s per console call). Seed:
# worker/jobs/schema.d/202611091634-bh-9117-needs-sweep-settings.sql.
#
# WRITES. logs/needs-sweep.log: one line per row that changes or would change,
#   <ts> <dry|apply> <id> <project> <ticket> <stage> -> <to> (<why>)
# and one summary line, also the detail of ONE ledger row per run
# (job_ledger_put needs_sweep run:<UTC stamp> dry|applied|partial|failed):
#   mode=<dry|apply> candidates=<n> superseded=<n> stale_aged=<n>
#   stale_issue_closed=<n> pr_merged=<n> pr_closed=<n> kept=<n>
#   changed=<n>|would=<n> commands=<n> reads=<n>[ INCOMPLETE]
# changed/would and commands are the endpoint's counts (D1 meta.changes), never
# the decided count. INCOMPLETE: a read cap or the row cap ended the run early.
#
# EXIT. 0 every run that finished (changes or not), not-configured, lock held;
# 2 bad arguments; 3 a fail-closed candidates read (ONE alert needs-sweep-read,
# nothing applied, ledger row failed). A refused apply chunk is ONE alert
# needs-sweep-apply, the run goes on, the ledger row says partial.
#
# Env: NS_NOW (epoch seconds) is a test seam for the clock.
# OFF: flags/lane-off-needs-sweep (bin/harness-ctl.sh off needs-sweep).
# Registry: catalog/lanes.d/needs-sweep.json.
# Doc: docs/notes/2026-11-05-BH-9117-needs-sweep.md.
#
# gh-rest: no-graphql
set -uo pipefail

# ns_epoch <updated_at> — epoch seconds of an ISO UTC time (…Z, optional
# fraction) or of a plain epoch number. rc 1 and nothing for anything else.
ns_epoch() {
  local v="${1:-}" s b
  if [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; then
    b="${v%%.*}"; b="${b%Z}Z"          # the fraction is dropped, the Z kept
    [ -n "$b" ] && [ "$b" != Z ] || return 1
    s=$(date -u -d "$b" +%s 2>/dev/null) || return 1
    [[ "$s" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$s"; return 0
  fi
  if [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then printf '%s\n' "${v%%.*}"; return 0; fi
  return 1
}

# ns_rule <id> <newest_id> <epoch|""> <pr> <issue> <now> <max_age_days> — the
# decision table on an epoch already read ("" = unreadable). Sets NS_TO and
# NS_WHY in this shell (no fork: the main loop calls it once or twice per row).
ns_rule() {
  local id="${1:-}" newest="${2:-}" t="${3:-}" pr="${4:-unknown}" issue="${5:-unknown}" now="${6:-}" days="${7:-}"
  NS_TO=keep
  if ! [[ "$t" =~ ^[0-9]+$ ]]; then NS_WHY=undated; return 0; fi
  case "$pr" in
    merged) NS_TO=pr_merged; NS_WHY=pr_merged; return 0 ;;
    closed_unmerged) NS_TO=pr_closed; NS_WHY=pr_closed; return 0 ;;
    unsettled) NS_WHY=pr_unsettled; return 0 ;;
    open) NS_WHY=pr_open; return 0 ;;
    none) ;;
    *) NS_WHY=pr_unknown; return 0 ;;
  esac
  if [[ "$newest" =~ ^[0-9]+$ ]] && [[ "$id" =~ ^[0-9]+$ ]] && [ "$newest" -gt "$id" ]; then
    NS_TO=superseded; NS_WHY=newer_row; return 0
  fi
  if [[ "$now" =~ ^[0-9]+$ ]] && [[ "$days" =~ ^[0-9]+$ ]] && [ $((now - t)) -gt $((days * 86400)) ]; then
    NS_TO=stale; NS_WHY=aged; return 0
  fi
  case "$issue" in
    closed) NS_TO=stale; NS_WHY=issue_closed ;;
    unknown) NS_WHY=ticket_unknown ;;
    *) NS_WHY=live ;;
  esac
  return 0
}

# ns_decide <id> <newest_id> <updated_at> <pr> <issue> <now> <max_age_days>
#   pr    none (no GitHub PR URL) | merged | closed_unmerged | unsettled | open | unknown
#   issue closed | open | unknown | na (not a github-issues ticket)
# Prints "<to> <why>"; to is keep | superseded | stale | pr_merged | pr_closed.
ns_decide() {
  local t
  t=$(ns_epoch "${3:-}") || t=""
  ns_rule "${1:-}" "${2:-}" "$t" "${4:-unknown}" "${5:-unknown}" "${6:-}" "${7:-}"
  echo "$NS_TO $NS_WHY"
}

# NS_EPOCH_JQ — ns_epoch in jq, for the page read: a number, an all-digit
# string or an ISO UTC time (…Z, optional fraction) -> epoch seconds, else "".
# shellcheck disable=SC2016
NS_EPOCH_JQ='def ns_epoch:
  if type == "number" then floor
  elif type == "string" then
    if test("^[0-9]+(\\.[0-9]+)?$") then (tonumber | floor)
    elif test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") then (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)
    else "" end
  else "" end;'

[ "${NS_LIB_ONLY:-}" = 1 ] && return 0 2>/dev/null

DRY_FLAG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_FLAG=1; shift ;;
    -h|--help) sed -n '2,63p' "$0"; exit 0 ;;
    *) echo "needs-sweep: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "needs-sweep: jq missing" >&2; exit 2; }

H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit needs-sweep
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply needs-sweep

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/needs-sweep.log"
now_s() { if [[ "${NS_NOW:-}" =~ ^[0-9]+$ ]]; then printf '%s\n' "$NS_NOW"; else date -u +%s; fi; }
NOW=$(now_s)
TS=$(date -u -d "@$NOW" +%FT%TZ)
log() { printf '%s %s\n' "$TS" "$*" >> "$LOG"; }
alert() { # alert <id> <text>
  local id="$1"; shift
  HARNESS="$H" "$H/bin/alert-line.sh" --severity warn --id "$id" "$*" >/dev/null 2>&1 || true
}

# shellcheck source=bin/lib/console-pages.sh
. "$H/bin/lib/console-pages.sh" 2>/dev/null || . "$SELF/lib/console-pages.sh" 2>/dev/null
command -v console_pages_url >/dev/null 2>&1 || { log "not-configured (no bin/lib/console-pages.sh)"; exit 0; }
[ -n "${HARNESS_SECRET:-}" ] || { log "not-configured (no HARNESS_SECRET)"; exit 0; }
BASE="$(console_pages_url)/api/needs-sweep"

exec 9>"$H/locks/needs-sweep.lock" || { log "lock file unwritable - not running"; exit 0; }
flock -n 9 || { log "another needs-sweep is running"; exit 0; }

# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/builds-merged-sweep.sh
BMS_LIB_ONLY=1 . "$H/bin/builds-merged-sweep.sh" 2>/dev/null \
  || { log "not-configured (no bin/builds-merged-sweep.sh)"; exit 0; }
# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh" 2>/dev/null
command -v gh_rest >/dev/null 2>&1 || { log "not-configured (no bin/lib/gh-rest.sh)"; exit 0; }
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh" 2>/dev/null
# shellcheck source=bin/lib/tracker.sh
[ -r "$H/bin/lib/tracker.sh" ] && . "$H/bin/lib/tracker.sh" 2>/dev/null
# shellcheck source=bin/lib/mc/settle.sh
[ -r "$H/bin/lib/mc/settle.sh" ] && . "$H/bin/lib/mc/settle.sh" 2>/dev/null
# settle.sh reads the clock through mc_now (bin/lib/mc/log.sh); here it is the run's clock.
command -v mc_now >/dev/null 2>&1 || mc_now() { printf '%s\n' "$NOW"; }

# knob <settings key> <fallback> — a whole number from the settings row, else the fallback.
knob() {
  local v=""
  command -v setting_get >/dev/null 2>&1 && v=$(JOBS_ALERT=0 setting_get "$1" 2>/dev/null)
  if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s\n' "$v"; else printf '%s\n' "$2"; fi
}
MAX_AGE_DAYS=$(knob console.needs.max_age_days 14)    # fallback; row console.needs.max_age_days
DRY_ROW=$(knob console.needs.sweep_dry_run 1)         # fallback; row console.needs.sweep_dry_run
MAX_ROWS=$(knob console.needs.sweep_max_rows 5000)    # fallback; row console.needs.sweep_max_rows
MAX_READS=$(knob console.needs.sweep_max_reads 300)   # fallback; row console.needs.sweep_max_reads
# Transport bounds; 0 is no bound for these, so 0 is the fallback too.
PAGE_SIZE=$(knob console.needs.sweep_page_size 500)          # fallback; row console.needs.sweep_page_size
APPLY_CHUNK=$(knob console.needs.sweep_apply_chunk 100)      # fallback; row console.needs.sweep_apply_chunk
HTTP_TIMEOUT=$(knob console.needs.sweep_http_timeout_s 30)   # fallback; row console.needs.sweep_http_timeout_s
[ "$PAGE_SIZE" -gt 0 ] || PAGE_SIZE=500
[ "$APPLY_CHUNK" -gt 0 ] || APPLY_CHUNK=100
[ "$HTTP_TIMEOUT" -gt 0 ] || HTTP_TIMEOUT=30
DRY=1; [ "$DRY_ROW" = 0 ] && DRY=0; [ "$DRY_FLAG" = 1 ] && DRY=1
MODE=dry; [ "$DRY" = 0 ] && MODE=apply
RUN_KEY="run:$(date -u -d "@$NOW" +%Y%m%dT%H%M%SZ)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/needs-sweep.XXXXXX") || { log "worker-failed (mktemp)"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

ledger() { # ledger <status> <summary>
  if command -v job_ledger_put >/dev/null 2>&1 && job_ledger_put needs_sweep "$RUN_KEY" "$1" "$2" 2>/dev/null; then return 0; fi
  log "ledger needs_sweep $RUN_KEY not written (status $1)"
}

# http <method> <url> [body file] — the HTTP code on stdout, the body in $WORK/resp.json.
# The bearer reaches curl on stdin (-H @-), never argv.
http() {
  local code
  if [ -n "${3:-}" ]; then
    code=$(printf 'Authorization: Bearer %s\n' "$HARNESS_SECRET" \
      | curl -sS --max-time "$HTTP_TIMEOUT" -X "$1" -H @- -H 'Content-Type: application/json' \
          --data-binary "@$3" -o "$WORK/resp.json" -w '%{http_code}' "$2" 2>/dev/null) || code="${code:-000}"
  else
    code=$(printf 'Authorization: Bearer %s\n' "$HARNESS_SECRET" \
      | curl -sS --max-time "$HTTP_TIMEOUT" -X "$1" -H @- -o "$WORK/resp.json" -w '%{http_code}' "$2" 2>/dev/null) || code="${code:-000}"
  fi
  printf '%s\n' "${code:-000}"
}

read_fail() { # read_fail <why> — fail closed: nothing applied, one alert, ledger failed
  log "candidates read failed ($1) - nothing applied"
  alert needs-sweep-read "[needs-sweep] the NEEDS candidates read failed at $BASE/candidates ($1). No build row was changed."
  ledger failed "mode=$MODE read-failed: $1"
  exit 3
}

# ── GitHub reads, deduped, one shared cap ─────────────────────────────────────
declare -A PR_CLASS=() ISSUE_STATE=() KIND=()
READS=0; INCOMPLETE=0
pr_class() { # pr_class <url> -> sets CLS
  local u="$1" slug rc body
  if [ -n "${PR_CLASS[$u]:-}" ]; then CLS="${PR_CLASS[$u]}"; return 0; fi
  if [ "$READS" -ge "$MAX_READS" ]; then CLS=unknown; INCOMPLETE=1; return 0; fi
  READS=$((READS+1))
  slug=$(printf '%s' "$u" | sed -E 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#')
  command -v gh_default_auth_for_slug >/dev/null 2>&1 && { gh_default_auth_for_slug "$slug" >/dev/null 2>&1 || true; }
  # Plain command into a file, never $( ): GH_REST_STATUS lives in this shell.
  rc=0; gh_rest GET "repos/$slug/pulls/${u##*/}" > "$WORK/pr.json" || rc=$?
  body=$(cat "$WORK/pr.json" 2>/dev/null)
  if [ "$rc" = 0 ]; then CLS=$(bms_classify "$body"); else CLS=unknown; fi
  # A closure inside the settle window can be a merge-conductor CI kick (SETTLE).
  if [ "$CLS" = closed_unmerged ]; then
    if ! command -v mc_closed_settled >/dev/null 2>&1 \
       || ! mc_closed_settled "$(printf '%s' "$body" | jq -r '.closed_at // ""' 2>/dev/null)"; then
      CLS=unsettled
    fi
  fi
  PR_CLASS[$u]="$CLS"
}
issue_state() { # issue_state <project> <ticket> -> sets IST
  local p="$1" k="$2" n rc body kind
  if [ -n "${ISSUE_STATE[$p|$k]:-}" ]; then IST="${ISSUE_STATE[$p|$k]}"; return 0; fi
  IST=unknown
  # One tracker_kind per project per run (it asks the jobs worker).
  if [ -n "$p" ] && [ -z "${KIND[$p]:-}" ] && command -v tracker_kind >/dev/null 2>&1; then
    KIND[$p]=$(tracker_kind "$p" 2>/dev/null) || KIND[$p]=-
    [ -n "${KIND[$p]}" ] || KIND[$p]=-
  fi
  kind="${KIND[$p]:--}"
  if [ -z "$k" ] || [ "$kind" = - ]; then IST=unknown
  elif [ "$kind" != github-issues ]; then IST=na
  elif ! n=$(trk_gh_issue_number "$p" "$k" 2>/dev/null); then IST=unknown
  elif ! tracker_context "$p" needs-sweep >/dev/null 2>&1 || [ -z "${TRK_SLUG-}" ]; then IST=unknown
  elif [ "$READS" -ge "$MAX_READS" ]; then IST=unknown; INCOMPLETE=1; return 0
  else
    READS=$((READS+1))
    rc=0; gh_rest GET "repos/$TRK_SLUG/issues/$n" > "$WORK/issue.json" || rc=$?
    body=$(cat "$WORK/issue.json" 2>/dev/null)
    if [ "$rc" = 0 ]; then
      IST=$(printf '%s' "$body" | jq -r 'if (.state == "closed" or .state == "open") then .state else "unknown" end' 2>/dev/null)
      [ -n "$IST" ] || IST=unknown
    fi
  fi
  ISSUE_STATE[$p|$k]="$IST"
}

# ── read, page by page, and decide ────────────────────────────────────────────
N_CAND=0; N_SUP=0; N_AGED=0; N_ICL=0; N_PRM=0; N_PRC=0; N_KEEP=0; N_DEC=0
: > "$WORK/decisions.jsonl"
AFTER=0
while :; do
  CODE=$(http GET "$BASE/candidates?after=$AFTER&limit=$PAGE_SIZE")
  case "$CODE" in 2??) ;; *) read_fail "HTTP $CODE$(jq -r '.error // empty | " " + .' "$WORK/resp.json" 2>/dev/null | head -c 200)" ;; esac
  jq -e '(.rows | type) == "array" and (.next_after | type) == "number" and (.done | type) == "boolean"' \
    "$WORK/resp.json" >/dev/null 2>&1 || read_fail "the answer carried no rows/next_after/done"
  NROWS=$(jq '.rows | length' "$WORK/resp.json")
  NEXT=$(jq -r '.next_after' "$WORK/resp.json")
  DONE=$(jq -r '.done' "$WORK/resp.json")
  if [ "$NROWS" -gt 0 ] && ! [ "$NEXT" -gt "$AFTER" ] 2>/dev/null; then read_fail "the cursor did not advance past $AFTER"; fi
  # One jq per page: the fields joined on \x1f (read collapses empty tab
  # fields), the epoch of updated_at, and updated_at as JSON for the apply body.
  jq -r "$NS_EPOCH_JQ"' .rows[] | [(.id | tostring), (.newest_id // "" | tostring), (.project // "" | tostring),
      (.ticket_key // "" | tostring), (.stage // "" | tostring), (.pr_url // "" | tostring),
      (.updated_at | ns_epoch | tostring), (.updated_at | tojson)] | join("\u001f")' "$WORK/resp.json" > "$WORK/page.tsv" \
    || read_fail "the rows could not be read"
  while IFS=$'\x1f' read -r id newest proj tk stage url ep atj; do
    [ "$N_DEC" -ge "$MAX_ROWS" ] && { INCOMPLETE=1; break; }
    [[ "$id" =~ ^[0-9]+$ ]] || read_fail "a row with no numeric id"
    N_CAND=$((N_CAND+1))
    CLS=none; IST=open
    if bms_pr_url_ok "$url"; then pr_class "$url"
    else
      # Rule 7 needs the ticket state only when rules 1-6 left the row live.
      ns_rule "$id" "$newest" "$ep" none open "$NOW" "$MAX_AGE_DAYS"
      [ "$NS_WHY" = live ] && issue_state "$proj" "$tk"
    fi
    ns_rule "$id" "$newest" "$ep" "$CLS" "$IST" "$NOW" "$MAX_AGE_DAYS"
    to="$NS_TO"; why="$NS_WHY"
    case "$to" in
      superseded) N_SUP=$((N_SUP+1)) ;;
      stale) if [ "$why" = aged ]; then N_AGED=$((N_AGED+1)); else N_ICL=$((N_ICL+1)); fi ;;
      pr_merged) N_PRM=$((N_PRM+1)) ;;
      pr_closed) N_PRC=$((N_PRC+1)) ;;
      *) N_KEEP=$((N_KEEP+1)); continue ;;
    esac
    N_DEC=$((N_DEC+1))
    log "$MODE $id ${proj:--} ${tk:--} $stage -> $to ($why)"
    printf '{"id":%s,"to":"%s","updated_at":%s,"why":"%s"}\n' "$id" "$to" "$atj" "$why" >> "$WORK/decisions.jsonl"
  done < "$WORK/page.tsv"
  [ "$DONE" = true ] && break
  # The row cap ends the read; the rest is next run's (INCOMPLETE).
  if [ "$N_DEC" -ge "$MAX_ROWS" ]; then INCOMPLETE=1; break; fi
  AFTER="$NEXT"
done

# ── apply, in chunks of the endpoint's batch bound ────────────────────────────
CMD_BEFORE=$(date -u -d "@$((NOW - MAX_AGE_DAYS * 86400))" +%FT%TZ)
CHANGED=0; COMMANDS=0; REFUSED=0
split -l "$APPLY_CHUNK" -d -a 4 "$WORK/decisions.jsonl" "$WORK/chunk." 2>/dev/null
CHUNKS=("$WORK"/chunk.*)
[ -e "${CHUNKS[0]}" ] || { : > "$WORK/chunk.0000"; CHUNKS=("$WORK/chunk.0000"); }
LAST=$(( ${#CHUNKS[@]} - 1 ))
for i in "${!CHUNKS[@]}"; do
  before=null; [ "$i" = "$LAST" ] && before="\"$CMD_BEFORE\""
  jq -sc --argjson apply "$([ "$DRY" = 0 ] && echo true || echo false)" --argjson before "$before" \
    '{apply:$apply, builds:., commands_before:$before}' "${CHUNKS[$i]}" > "$WORK/body.json"
  CODE=$(http POST "$BASE/apply" "$WORK/body.json")
  if [[ "$CODE" == 2?? ]] && jq -e '.ok == true and (.builds.changed | type) == "number" and (.commands.changed | type) == "number"' \
       "$WORK/resp.json" >/dev/null 2>&1; then
    CHANGED=$((CHANGED + $(jq -r '.builds.changed' "$WORK/resp.json")))
    COMMANDS=$((COMMANDS + $(jq -r '.commands.changed' "$WORK/resp.json")))
  else
    REFUSED=$((REFUSED+1))
    log "apply chunk $i refused (HTTP $CODE): $(head -c 200 "$WORK/resp.json" 2>/dev/null)"
  fi
done

COUNT_WORD=changed; [ "$DRY" = 1 ] && COUNT_WORD=would
SUMMARY="mode=$MODE candidates=$N_CAND superseded=$N_SUP stale_aged=$N_AGED stale_issue_closed=$N_ICL pr_merged=$N_PRM pr_closed=$N_PRC kept=$N_KEEP $COUNT_WORD=$CHANGED commands=$COMMANDS reads=$READS"
[ "$INCOMPLETE" = 1 ] && SUMMARY="$SUMMARY INCOMPLETE"
STATUS=dry; [ "$DRY" = 0 ] && STATUS=applied
if [ "$REFUSED" -gt 0 ]; then
  STATUS=partial
  SUMMARY="$SUMMARY refused_chunks=$REFUSED"
  alert needs-sweep-apply "[needs-sweep] $REFUSED of ${#CHUNKS[@]} apply call(s) to $BASE/apply were refused. See $LOG."
fi
log "summary $SUMMARY"
ledger "$STATUS" "$SUMMARY"
echo "$SUMMARY"
exit 0
