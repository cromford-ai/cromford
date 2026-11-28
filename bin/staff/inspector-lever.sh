#!/bin/bash
# gh-identity: app-token
# bin/staff/inspector-lever.sh — the inspector staff agent's metric and its one
# lever (BH-9419, C1 of #9187). Hub only, hourly at :23
# (cron/lanes/781-staff-inspector-lever.cron). No LLM call.
#
# WHY. The staff contract (BH-9187, C0) says every staff agent owns ONE metric
# and is judged by whether it moved. The inspector owns hours_behind_main: the
# hours any project's production serves a sha behind main (Vercel), or the
# console Pages build trails main's last console-ui merge (target: below
# staff.inspector.target, 2). Its lever files a fix-main-red issue with the
# failing Vercel build step quoted, through the contract: one ledger row per
# action, and a later metric sample decides whether the metric fell.
#
# WHAT, in order (each step that stops writes one log line and exits 0):
#   1  load the libs; no jq, jobs client, staff-contract.sh, console-pages.sh,
#      served-sha-watch.sh, HARNESS_SECRET or Vercel token = `not-configured`.
#   2  KILL, before any request: STAFF_ENABLED=0, then the flags staff-off-all,
#      staff-kill-all, staff-off-inspector, staff-kill-inspector.
#   3  flock -n locks/staff-inspector-lever.lock.
#   4  GET /api/staff/agent?name=inspector: the inspector must be active.
#   5  METRIC = max(Vercel part, console part), hours, 2 decimals.
#      Vercel: the newest summary line of logs/served-sha-watch.log is at most
#      staff.inspector.fresh_min minutes old, and each vercel.conf project
#      counts (now - since) for a wait/alert state file (since =
#      .prodbehind.since, else .first_seen), 0 with no file. A state file older
#      than the window still counts with its clock (tag stale).
#      Console: the Cloudflare Pages production deployment's commit against
#      main's last first-parent console-ui commit in HARNESS_CHECKOUT (the
#      pipeline-health 8c rule); behind = the age of the oldest pending commit.
#      Any part unreadable: no sample and no action (never 0).
#   6  SAMPLE: POST /api/staff/levers/metric {agent:inspector,
#      metric:hours_behind_main}; it settles the due actions (C0).
#   7  GATE: level file or act (staff_level inspector; else observe). The
#      candidates are Vercel projects at or over the target, oldest first; the
#      newest production deployment must be ERROR. The console has no lever.
#      At most staff.inspector.lever_max_run lever actions per run.
#   8  DAY CAP: the scorecard's non-dry actions in 1 day must be under
#      staff.inspector.file_max_day; an unreadable scorecard acts on nothing.
#   9  QUOTE: the build log (/v3/deployments/<uid>/events): the step is the
#      last command; the quote is the last staff.inspector.quote_lines error or
#      stderr lines, each redacted, then cut to staff.inspector.quote_line_chars
#      chars. No quote, no action.
#  10  MODE: dry unless staff.inspector.lever_dry_run is exactly 0.
#  11  RECORD BEFORE ACT: POST /api/staff/levers/actions, key
#      fix-main-red:<p>@<since>[:dry]. A new row, or one recorded earlier
#      (existing, 409), delivers; anything else makes no GitHub call.
#  12  DELIVER: dry = one log line, 0 GitHub calls. Live = one list of the
#      staff:inspector issues (all states) per run; the episode marker on any
#      issue = already, the project marker on an open issue = open-reused,
#      else POST the issue. A failed delivery is retried on the next run.
#      The list reads at most staff.inspector.issue_list_max rows (at most
#      1000, the list lib's 10-page stop). A list that reaches the cap is
#      list-unreadable: the lever files nothing until the label holds fewer
#      issues or the row is raised (it never files on a list it could not
#      read to the end, so it never files a duplicate).
#      Only a new or failed record uses one of the run's lever_max_run slots:
#      an episode recorded earlier does not block the next project.
#
# KNOBS (settings rows): staff.inspector.level (observe), .target (2),
# .file_max_day (3), .lever_dry_run (1 = dry), .quote_lines (30), .fresh_min
# (20), .lever_max_run (1), .issue_list_max (1000), .quote_line_chars (300). Seeds: worker/jobs/schema.d/202611100721-bh-9187-
# staff-contract.sql and 202611121831-bh-9419-inspector-lever.sql. The HTTP
# timeout is SERVED_SHA_HTTP_TIMEOUT (through ssw_vapi). Env STAFF_ENABLED (0 =
# off), STAFF_FILE_REPO (else HARNESS_REPO), HARNESS_CHECKOUT.
#
# WRITES. One summary line per run in logs/staff-inspector-lever.log:
#   <ts> level=<L> hours=<M|unreadable> target=<T> vercel=<h> console=<h>
#   sample=<ok|failed|none> action=<none|recorded|recorded-earlier|failed|
#   log-unreadable|day-cap|scorecard-unreadable> dry=<0|1|-> project=<p|->
#   filed=<-|dry|new <url>|already|open-reused|list-unreadable|failed>
# The rows: staff_metric_samples and staff_lever_actions through the C0
# routes. GitHub issues on the filing repo, label staff:inspector. No state/
# file is written.
#
# EXIT. 0 every run that finished; 2 bad arguments.
# Env (sandbox test seams, HARNESS_TEST_SANDBOX=1 only): INSPECTOR_NOW (epoch
#   seconds), INSPECTOR_CF_BASE (the Cloudflare API base). INSPECTOR_LIB_ONLY=1
#   loads the insp_* functions and returns.
# OFF: flags/lane-off-staff-inspector-lever (bin/harness-ctl.sh off
#   staff-inspector-lever), or any staff kill flag above. Registry:
#   catalog/lanes.d/staff-inspector-lever.json.
# Doc: docs/notes/2026-11-12-BH-9419-inspector-lever.md.
set -uo pipefail

# insp_hours <now> <since> — (now - since) / 3600, 2 decimals.
insp_hours() { awk -v n="$1" -v s="$2" 'BEGIN { printf "%.2f\n", (n - s) / 3600 }'; }

# insp_vercel_hours <vercel.conf> <state-dir> <watch-log> <now> <fresh-min>
# rc 0: line 1 `watch_unreadable=<N>`, then per project
#   `<p> <hours> <since|-> <fresh|stale|none> <served|-> <head|->`.
# rc 1: one line `unreadable <reason>`. A project with no state file is 0; a
# state file jq cannot read, or with no clock, makes the whole part unreadable.
insp_vercel_hours() {
  local conf="${1:-}" sd="${2:-}" wl="${3:-}" now="${4:-}" fresh="${5:-}" line ts ep unr p _r f j v since chk served head tag out
  [[ $now =~ ^[0-9]+$ ]] && [[ $fresh =~ ^[0-9]+$ ]] || { echo "unreadable bad-arguments"; return 1; }
  [ -r "$conf" ] || { echo "unreadable no-vercel.conf"; return 1; }
  line=$(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z checked=[0-9]+ ' "$wl" 2>/dev/null | tail -1)
  [ -n "$line" ] || { echo "unreadable no-watch-summary"; return 1; }
  ts="${line%% checked=*}"
  ep=$(date -u -d "${ts%Z} UTC" +%s 2>/dev/null) || { echo "unreadable watch-summary-time"; return 1; }
  [ $((now - ep)) -le $((fresh * 60)) ] || { echo "unreadable watch-summary-age-$(((now - ep) / 60))m"; return 1; }
  unr=$(sed -n 's/.* unreadable=\([0-9][0-9]*\).*/\1/p' <<<"$line")
  out="watch_unreadable=${unr:-?}"
  while read -r p _r; do
    case "$p" in ''|'#'*) continue ;; esac
    f="$sd/$p.json"
    if [ ! -e "$f" ]; then out+=$'\n'"$p 0.00 - none - -"; continue; fi
    j=$(jq -ce 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null) \
      || { echo "unreadable state-file-$p"; return 1; }
    v=$(jq -r '.last_verdict // ""' <<<"$j")
    case "$v" in wait|alert) ;; *) echo "unreadable state-verdict-$p"; return 1 ;; esac
    since=$(jq -r '(.prodbehind.since // .first_seen) | if type == "number" then floor | tostring else "" end' <<<"$j")
    [[ $since =~ ^[0-9]+$ ]] || { echo "unreadable state-clock-$p"; return 1; }
    chk=$(jq -r '.checked_at | if type == "number" then floor | tostring else "" end' <<<"$j")
    tag=fresh; { [[ $chk =~ ^[0-9]+$ ]] && [ $((now - chk)) -le $((fresh * 60)) ]; } || tag=stale
    served=$(jq -r '.served // "" | if . == "" then "-" else . end' <<<"$j")
    head=$(jq -r '.head // "" | if . == "" then "-" else . end' <<<"$j")
    out+=$'\n'"$p $(insp_hours "$now" "$since") $since $tag ${served// /} ${head// /}"
  done < "$conf"
  printf '%s\n' "$out"
}

# insp_console_hours <checkout> <pages-project-json> <now> — the console part.
# rc 0: hours (0.00 when Pages serves main's console-ui). rc 1: `unreadable
# <reason>`. The field order and the age rule are pipeline-health block 8c's.
insp_console_hours() {
  local hco="${1:-}" f="${2:-}" now="${3:-}" dep want pend t
  [[ $now =~ ^[0-9]+$ ]] || { echo "unreadable bad-arguments"; return 1; }
  [ "$(jq -r '.success == true' "$f" 2>/dev/null)" = true ] || { echo "unreadable cloudflare-answer"; return 1; }
  dep=$(jq -r '.result.canonical_deployment.deployment_trigger.metadata.commit_hash // empty' "$f" 2>/dev/null)
  [ -n "$dep" ] || dep=$(jq -r 'if .result.latest_deployment.environment == "production"
    then .result.latest_deployment.deployment_trigger.metadata.commit_hash // empty else empty end' "$f" 2>/dev/null)
  [[ $dep =~ ^[0-9a-f]{7,40}$ ]] || { echo "unreadable no-commit-hash"; return 1; }
  want=$(console_pages_want "$hco" origin/main) || { echo "unreadable no-console-ui-commit-in-checkout"; return 1; }
  [ "$dep" = "$want" ] && { echo 0.00; return 0; }
  if ! git -C "$hco" cat-file -e "$dep^{commit}" 2>/dev/null; then
    t=$(git -C "$hco" log -1 --format=%ct "$want" 2>/dev/null)
  else
    pend=$(git -C "$hco" rev-list --first-parent "$dep..origin/main" -- console-ui 2>/dev/null) \
      || { echo "unreadable rev-list"; return 1; }
    [ -n "$pend" ] || { echo 0.00; return 0; }
    t=$(git -C "$hco" log -1 --format=%ct "${pend##*$'\n'}" 2>/dev/null)
  fi
  [[ $t =~ ^[0-9]+$ ]] || { echo "unreadable commit-time"; return 1; }
  insp_hours "$now" "$t"
}

# insp_action_verdict <http-code> <body-file> <rc> — the answer of
# POST /api/staff/levers/actions -> new | recorded-earlier | failed. A row
# recorded earlier (existing, or 409 key_mismatch: the same episode with
# another metricBefore) still delivers: the GitHub dedupe makes that safe.
insp_action_verdict() {
  local code="${1:-}" f="${2:-}" rc="${3:-1}"
  if [ "$code" = 409 ] && jq -e '.error == "key_mismatch"' "$f" >/dev/null 2>&1; then echo recorded-earlier; return 0; fi
  if [ "$rc" = 0 ] && [[ "$code" == 2?? ]] && [ -s "$f" ]; then
    if jq -e '.ok == true and .existing == true' "$f" >/dev/null 2>&1; then echo recorded-earlier; return 0; fi
    if jq -e '.ok == true and (.existing // false) == false and (.action.action_key | type) == "string"' "$f" >/dev/null 2>&1; then
      echo new; return 0
    fi
  fi
  echo failed
}

# insp_quote <events-json-file> <max-lines> [max-chars] — line 1: the failing
# step (the text of the last command event, `-` when none); then the last
# <max-lines> log lines that are stderr or say error/failed/ERR!. Each line is
# redacted FIRST (token shapes, Bearer credentials, and the values of names
# holding key/token/secret/password in any case), then cut to <max-chars>
# (default 300), so a secret that crosses the cut leaves no fragment; no
# triple backtick. rc 1: the log is not an event array, or no line matched.
insp_quote() {
  local f="${1:-}" n="${2:-30}" c="${3:-300}" q step
  [[ $n =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] || n=30
  [[ $c =~ ^[0-9]+$ ]] && [ "$c" -gt 0 ] || c=300
  jq -e 'type == "array"' "$f" >/dev/null 2>&1 || return 1
  step=$(jq -r '[.[] | select(type == "object" and .type == "command") | ((.payload.text // .text // "") | tostring)]
    | last // "-" | split("\n") | map(select(length > 0)) | last // "-"' "$f" 2>/dev/null) || return 1
  q=$(jq -r '.[] | select(type == "object" and (.type == "stdout" or .type == "stderr"))
    | .type as $t | ((.payload.text // .text // "") | tostring) | split("\n")[] | select(length > 0)
    | select($t == "stderr" or test("error|failed|ERR!"; "i"))' "$f" 2>/dev/null) || return 1
  [ -n "$q" ] || return 1
  { printf '%s\n' "$step"; tail -n "$n" <<<"$q"; } \
    | token_redact \
    | sed -E 's/((key|token|secret|password)[a-z_]*)=[^[:space:]]+/\1=<redacted>/Ig; s/(bearer)[[:space:]]+[^[:space:]]+/\1 <redacted>/Ig' \
    | cut -c1-"$c" | sed 's/```/'"'''"'/g'
}

# insp_deliver_verdict <list-file> <list-rc> <project> <since> [max] — before a POST:
#   already <url>      an issue in any state carries the episode marker
#   open-reused <url>  an open issue carries the project marker
#   file               nothing matches
#   list-unreadable    the list read failed, is not an array, or holds <max>
#                      rows (default 1000; above 1000 counts as 1000, the list
#                      lib's hard stop), so it may be cut short
insp_deliver_verdict() {
  local f="${1:-}" lrc="${2:-1}" p="${3:-}" since="${4:-}" max="${5:-1000}" u
  [[ $max =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ] || max=1000
  [ "$max" -le 1000 ] || max=1000
  [ "$lrc" = 0 ] && jq -e --argjson m "$max" 'type == "array" and length < $m' "$f" >/dev/null 2>&1 || { echo list-unreadable; return 0; }
  u=$(jq -r --arg m "<!-- inspector-fmr:$p@$since -->" \
    '[.[] | select((.body // "") | contains($m))] | sort_by(.number) | .[0].html_url // empty' "$f")
  [ -n "$u" ] && { echo "already $u"; return 0; }
  u=$(jq -r --arg m "<!-- inspector-fmr-project:$p -->" \
    '[.[] | select(.state == "open" and ((.body // "") | contains($m)))] | sort_by(.number) | .[0].html_url // empty' "$f")
  [ -n "$u" ] && { echo "open-reused $u"; return 0; }
  echo file
}

H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBD="$(cd "$SELF/.." && pwd)"
# shellcheck source=bin/lib/token-redact.sh
. "$H/bin/lib/token-redact.sh" 2>/dev/null || . "$LIBD/lib/token-redact.sh" 2>/dev/null
# shellcheck source=bin/lib/console-pages.sh
. "$H/bin/lib/console-pages.sh" 2>/dev/null || . "$LIBD/lib/console-pages.sh" 2>/dev/null

[ "${INSPECTOR_LIB_ONLY:-}" = 1 ] && return 0 2>/dev/null

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '3,83p' "$0"; exit 0 ;;
    *) echo "inspector-lever: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$LIBD/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/staff-inspector-lever.log"
NOW=$(date -u +%s)
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${INSPECTOR_NOW:-} =~ ^[0-9]+$ ]] && NOW=$INSPECTOR_NOW
TS=$(date -u -d "@$NOW" +%FT%TZ)
log() { printf '%s %s\n' "$TS" "$*" >> "$LOG"; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$LIBD/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit staff-inspector-lever
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply staff-inspector-lever

# ── 1 libs ────────────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || { log "not-configured (no jq)"; exit 0; }
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" 2>/dev/null || . "$LIBD/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/staff-contract.sh
. "$H/bin/lib/staff-contract.sh" 2>/dev/null || . "$LIBD/lib/staff-contract.sh" 2>/dev/null
# shellcheck source=bin/lib/served-sha-watch.sh
. "$H/bin/lib/served-sha-watch.sh" 2>/dev/null || . "$LIBD/lib/served-sha-watch.sh" 2>/dev/null
# _ssw_pb_newest: the newest production deployment, the rule the prodbehind page uses.
# shellcheck source=bin/lib/served-sha-watch.d/30-prodbehind.sh
. "$H/bin/lib/served-sha-watch.d/30-prodbehind.sh" 2>/dev/null || . "$LIBD/lib/served-sha-watch.d/30-prodbehind.sh" 2>/dev/null
# shellcheck source=bin/lib/endpoints.sh
. "$H/bin/lib/endpoints.sh" 2>/dev/null || . "$LIBD/lib/endpoints.sh" 2>/dev/null
for fn in _jobs_req _jobs_req_file flag_active setting_get; do
  command -v "$fn" >/dev/null 2>&1 || { log "not-configured (no bin/jobs-client.sh: $fn)"; exit 0; }
done
command -v staff_action_post >/dev/null 2>&1 || { log "not-configured (no bin/lib/staff-contract.sh)"; exit 0; }
for fn in console_pages_want console_pages_account_id token_redact ssw_vapi ssw_vercel_token _ssw_pb_newest endpoint_url; do
  command -v "$fn" >/dev/null 2>&1 || { log "not-configured (no $fn)"; exit 0; }
done
[ -n "${HARNESS_SECRET:-}" ] || { log "not-configured (no HARNESS_SECRET)"; exit 0; }

# ── 2 kill, before any request ────────────────────────────────────────────────
[ "${STAFF_ENABLED:-1}" = 0 ] && { log "killed by STAFF_ENABLED=0"; exit 0; }
for f in staff-off-all staff-kill-all staff-off-inspector staff-kill-inspector; do
  if flag_active "$f"; then log "killed by $f"; exit 0; fi
done

# ── 3 lock ────────────────────────────────────────────────────────────────────
exec 9>"$H/locks/staff-inspector-lever.lock" || { log "lock file unwritable - not running"; exit 0; }
flock -n 9 || { log "another inspector-lever run is running"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/inspector-lever.XXXXXX") || { log "worker-failed (mktemp)"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

# The Vercel reads (deployment list, build log) go through ssw_vapi: the token
# reaches curl on stdin, the timeout is SERVED_SHA_HTTP_TIMEOUT.
SSW_TOKEN=$(ssw_vercel_token) || SSW_TOKEN=""
[ -n "$SSW_TOKEN" ] || { log "not-configured (no Vercel CLI auth file)"; exit 0; }
SSW_BASE=$(endpoint_url vercel 2>/dev/null) || SSW_BASE=""
[ -n "$SSW_BASE" ] || { log "not-configured (no vercel endpoint)"; exit 0; }

# ── 4 roster ──────────────────────────────────────────────────────────────────
row=$(_jobs_req GET "/api/staff/agent?name=inspector"); rc=$?
[ "$rc" = 0 ] || { log "roster row unreadable or absent (rc=$rc); nothing ran"; exit 0; }
[ "$(jq -r '.agent.status // ""' <<<"$row" 2>/dev/null)" = active ] || { log "inspector is not active on the roster; nothing ran"; exit 0; }

L=- M=unreadable T=- VH=- CH=- SAMPLE=none ACTION=none DRY=- PROJ=- FILED=-
summary() { log "level=$L hours=$M target=$T vercel=$VH console=$CH sample=$SAMPLE action=$ACTION dry=$DRY project=$PROJ filed=$FILED"; }

# ── 5 metric ──────────────────────────────────────────────────────────────────
FRESH=$(staff_knob inspector fresh_min 20)          # fallback 20; row staff.inspector.fresh_min
if ! insp_vercel_hours "${SERVED_SHA_CONF:-$H/vercel.conf}" "$H/state/served-sha-watch" \
       "$H/logs/served-sha-watch.log" "$NOW" "$FRESH" > "$WORK/vercel.txt"; then
  log "vercel part unreadable ($(cut -d' ' -f2- "$WORK/vercel.txt")); no sample, no action"
  summary; exit 0
fi
VH=$(awk 'NR > 1 { if (m == "" || $2 + 0 > m + 0) m = $2 } END { print (m == "" ? "0.00" : m) }' "$WORK/vercel.txt")

CF_BASE=https://api.cloudflare.com/client/v4   # the URL pipeline-health block 8c reads
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${INSPECTOR_CF_BASE:-}" ] && CF_BASE=$INSPECTOR_CF_BASE
HCO="${HARNESS_CHECKOUT:-/root/harness-checkout}"
CF_WHY=""
CF_R=$( [ -r "$HENV/cloudflare.env" ] || exit 4
  set -a; . "$HENV/cloudflare.env" 2>/dev/null; set +a
  acct=$(console_pages_account_id "$HCO") || exit 3
  [ -n "${CLOUDFLARE_API_TOKEN-}" ] || exit 4
  SSW_BASE=$CF_BASE SSW_TOKEN=$CLOUDFLARE_API_TOKEN ssw_vapi GET "/accounts/$acct/pages/projects/$(console_pages_project)"
); CF_RC=$?
case "$CF_RC" in
  0) _ssw_body "$CF_R" > "$WORK/cf.json"
     CH=$(insp_console_hours "$HCO" "$WORK/cf.json" "$NOW") || { CF_WHY="${CH#unreadable }"; CH=-; } ;;
  3) CF_WHY="no Cloudflare account id" ;;
  4) CF_WHY="no CLOUDFLARE_API_TOKEN in env/cloudflare.env" ;;
  *) CF_WHY="Cloudflare HTTP $(_ssw_code "$CF_R")" ;;
esac
if [ -n "$CF_WHY" ]; then
  log "console part unreadable ($CF_WHY); no sample, no action"
  summary; exit 0
fi
M=$(awk -v a="$VH" -v b="$CH" 'BEGIN { printf "%.2f\n", (a + 0 > b + 0 ? a : b) }')

# ── 6 sample ──────────────────────────────────────────────────────────────────
DETAIL="vercel=$(awk 'NR > 1 { printf "%s%s:%s%s", (n++ ? "," : ""), $1, $2, ($4 == "stale" ? ":stale" : "") }' "$WORK/vercel.txt") console=$CH $(head -1 "$WORK/vercel.txt")"
jq -n --argjson v "$M" --arg d "${DETAIL:0:500}" \
  '{agent:"inspector", metric:"hours_behind_main", value:$v, detail:$d}' > "$WORK/sample.json"
if staff_metric_post "$WORK/sample.json" > "$WORK/sample.out" 2>/dev/null; then SAMPLE=ok; else SAMPLE=failed; fi

# ── 7 gate ────────────────────────────────────────────────────────────────────
L=$(staff_level inspector 2>/dev/null) || true
[ -n "$L" ] || L=observe
T=$(staff_knob inspector target 2)                  # fallback 2; row staff.inspector.target
case "$L" in file|act) ;; *) summary; exit 0 ;; esac
awk -v t="$T" 'NR > 1 && $2 + 0 >= t + 0' "$WORK/vercel.txt" | sort -k2,2gr -k1,1 > "$WORK/cand.txt"
[ -s "$WORK/cand.txt" ] || { summary; exit 0; }

# ── 8 day cap ─────────────────────────────────────────────────────────────────
CAP=$(staff_knob inspector file_max_day 3)          # fallback 3; row staff.inspector.file_max_day
MAXRUN=$(staff_knob inspector lever_max_run 1)      # fallback 1; row staff.inspector.lever_max_run
QN=$(staff_knob inspector quote_lines 30)           # fallback 30; row staff.inspector.quote_lines
QC=$(staff_knob inspector quote_line_chars 300)     # fallback 300; row staff.inspector.quote_line_chars
LISTMAX=$(staff_knob inspector issue_list_max 1000) # fallback 1000; row staff.inspector.issue_list_max
[ "$LISTMAX" -le 1000 ] || LISTMAX=1000             # the list lib stops at 10 pages (1000 rows)
sc=$(_jobs_req GET "/api/staff/levers/scorecard?agent=inspector&days=1"); rc=$?
DONE=$(jq -r '.actions | if type == "number" and . >= 0 then floor | tostring else empty end' <<<"$sc" 2>/dev/null)
if [ "$rc" != 0 ] || ! [[ ${DONE:-} =~ ^[0-9]+$ ]]; then
  ACTION=scorecard-unreadable; log "scorecard unreadable (rc=$rc); no action"; summary; exit 0
fi

# ── 10 mode ───────────────────────────────────────────────────────────────────
# A missing, non-numeric or unreadable value is dry; only exactly 0 files.
DRY_ROW=$(JOBS_ALERT=0 setting_get staff.inspector.lever_dry_run 2>/dev/null) || DRY_ROW=""
DRY_ROW="${DRY_ROW//[[:space:]]/}"                  # fallback 1; row staff.inspector.lever_dry_run
DRY=1; [ "$DRY_ROW" = 0 ] && DRY=0

# The filing repo (bin/staff.sh's rule), read only on a live delivery.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$LIBD/lib/deployment.sh}" 2>/dev/null || true
REPO="${STAFF_FILE_REPO:-${HARNESS_REPO:-}}"
LISTED=0

# deliver <p> <since> <title> <body-file> — sets FILED.
deliver() {
  local p="$1" since="$2" title="$3" bf="$4" lrc=0 v grc=0 url
  if [ "$LISTED" = 0 ]; then
    if ! [[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then FILED=failed; log "filing repo '${REPO:0:60}' is not owner/repo"; return; fi
    # shellcheck source=bin/lib/gh-app-auth.sh
    . "$H/bin/lib/gh-app-auth.sh" 2>/dev/null || . "$LIBD/lib/gh-app-auth.sh" 2>/dev/null
    # The tracker seam (BH-7919): the GitHub Issues adapter reads the list and
    # creates the issue; it sources bin/lib/gh-rest.sh and gh-rest-list.sh.
    # shellcheck source=bin/lib/tracker/github-issues.sh
    . "$H/bin/lib/tracker/github-issues.sh" 2>/dev/null || . "$LIBD/lib/tracker/github-issues.sh" 2>/dev/null
    { declare -F trk_gh_list_raw && declare -F trk_gh_create; } >/dev/null 2>&1 \
      || { FILED=failed; log "no bin/lib/tracker/github-issues.sh"; return; }
    command -v gh_default_auth_for_slug >/dev/null 2>&1 && { gh_default_auth_for_slug "$REPO" >/dev/null 2>&1 || true; }
    TRK_SLUG="$REPO" TRK_LIST_STATE=all TRK_LIST_LABEL=staff:inspector \
      trk_gh_list_raw "$LISTMAX" > "$WORK/issues.json" 2>/dev/null || lrc=$?
    LISTED=1; LIST_RC=$lrc
  fi
  v=$(insp_deliver_verdict "$WORK/issues.json" "$LIST_RC" "$p" "$since" "$LISTMAX")
  case "$v" in
    already*|open-reused*) FILED=${v%% *}; log "$p: $v"; return ;;
    list-unreadable) FILED=list-unreadable; log "issue list unreadable (rc=$LIST_RC HTTP ${GH_REST_STATUS:-}); nothing filed"; return ;;
  esac
  jq -n --arg t "$title" --rawfile b "$bf" '{title:$t, body:$b, labels:["staff:inspector"]}' > "$WORK/issue.json"
  TRK_SLUG="$REPO" trk_gh_create "$WORK/issue.json" "$WORK/created" 2>/dev/null || grc=$?
  url=$(jq -r '.html_url // ""' "$WORK/created" 2>/dev/null)
  if [ "$grc" != 0 ] || [ "${GH_REST_STATUS:-}" != 201 ] || [ -z "$url" ]; then
    FILED=failed; log "issue create for $p failed (rc=$grc HTTP ${GH_REST_STATUS:-}); the next run retries"; return
  fi
  FILED="new $url"
}

# ── per candidate: deploy state, quote, record, deliver ───────────────────────
ACTED=0 LIVE=0
while read -r p h since _tag served head; do
  [ "$ACTED" -lt "$MAXRUN" ] || break
  team=$(awk -v p="$p" '$1 == p { print $2; exit }' "${SERVED_SHA_CONF:-$H/vercel.conf}")
  pid=$(awk -v p="$p" '$1 == p { print $3; exit }' "${SERVED_SHA_CONF:-$H/vercel.conf}")
  nd=$(_ssw_pb_newest "$team" "$pid") || { log "$p: newest production deployment unreadable; no action"; continue; }
  read -r dstate uid _dsha <<<"$nd"
  [ "$dstate" = ERROR ] || { log "$p: behind ${h}h, newest production deployment is $dstate; no action"; continue; }
  # Dry actions do not count; a dry run still stops at the cap, so a move to
  # live files what the dry run said it would.
  if [ $((DONE + LIVE)) -ge "$CAP" ]; then
    ACTION=day-cap; PROJ=$p; log "day cap: $((DONE + LIVE)) live actions in 1 day, cap $CAP; no action"; break
  fi
  PROJ=$p
  ev=$(ssw_vapi GET "/v3/deployments/$uid/events?builds=1&limit=-1&teamId=$team"); erc=$?
  _ssw_body "$ev" > "$WORK/events.json"
  if [ "$erc" != 0 ] || ! insp_quote "$WORK/events.json" "$QN" "$QC" > "$WORK/quote.txt"; then
    ACTION=log-unreadable; log "$p: build log of $uid unreadable or has no error line (HTTP $(_ssw_code "$ev")); no action"; continue
  fi
  step=$(head -1 "$WORK/quote.txt")
  title="fix-main-red: $p prod ${served:0:8} behind main ${head:0:8} for ${h}h"
  title=$(printf '%s' "${title:0:80}" | sed 's/—/-/g')
  key="fix-main-red:$p@$since"; [ "$DRY" = 1 ] && key="$key:dry"
  jq -n --argjson dry "$([ "$DRY" = 1 ] && echo true || echo false)" --argjson m "$M" --arg p "$p" --arg k "$key" \
    --arg d "fix-main-red $([ "$DRY" = 1 ] && echo dry || echo live) $p behind ${h}h deployment $uid" \
    '{agent:"inspector", lever:"fix-main-red", target:$p, dryRun:$dry, metric:"hours_behind_main",
      metricBefore:$m, key:$k, detail:$d}' > "$WORK/action.json"
  JOBS_HTTP=""
  staff_action_post "$WORK/action.json" > "$WORK/action.out" 2>/dev/null; arc=$?
  # A record made earlier does not use a slot: an episode already recorded
  # must not keep the next project from its first action.
  case "$(insp_action_verdict "${JOBS_HTTP:-}" "$WORK/action.out" "$arc")" in
    new) ACTION=recorded; ACTED=$((ACTED + 1)); [ "$DRY" = 0 ] && LIVE=$((LIVE + 1)) ;;
    recorded-earlier) ACTION=recorded-earlier ;;
    *) ACTION=failed; ACTED=$((ACTED + 1)); log "lever action not recorded (rc=$arc HTTP ${JOBS_HTTP:-none}); no issue"; continue ;;
  esac
  if [ "$DRY" = 1 ]; then
    FILED=dry; log "dry $title; step: $step; $(($(wc -l < "$WORK/quote.txt") - 1)) quoted lines"
    continue
  fi
  {
    printf 'The inspector staff agent (BH-9419) found production behind main.\n\n'
    printf -- '- Project: %s\n- Prod serves: %s\n- Main head: %s\n' "$p" "$served" "$head"
    printf -- '- Behind for: %s h (since %s)\n' "$h" "$(date -u -d "@$since" +%FT%TZ)"
    printf -- '- Newest production deployment: %s (ERROR)\n\n' "$uid"
    printf 'The failing step:\n\n```\n%s\n```\n\n' "$step"
    printf 'The last %s error lines of the build log:\n\n```text\n' "$(($(wc -l < "$WORK/quote.txt") - 1))"
    tail -n +2 "$WORK/quote.txt"
    printf '```\n\nLogs: `vercel inspect %s --logs --scope %s`\n\n' "$uid" "$team"
    printf '<!-- inspector-fmr:%s@%s -->\n<!-- inspector-fmr-project:%s -->\n' "$p" "$since" "$p"
  } | sed 's/—/-/g' > "$WORK/body.md"
  deliver "$p" "$since" "$title" "$WORK/body.md"
done < "$WORK/cand.txt"

summary
exit 0
