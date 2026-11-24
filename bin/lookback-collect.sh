#!/bin/bash
# lookback-collect.sh — BH-1795.1: the repeat-failure collector of the weekly
# `lookback` hub lane. bin/lookback.sh runs it as
#   lookback-collect.sh --days "${LOOKBACK_DAYS:-7}" --out state/lookback/<date>/bundle.json
# and it can be run by hand the same way:
#   lookback-collect.sh [--since <iso>] [--days N] --out <file>
#
# It reads a window (from --since, else NOW - days; to = NOW, one clock read)
# of five kinds of repeat failure and writes ONE bundle, the shape documented in
# bin/lib/lookback-common.sh, through <out>.tmp + mv so no reader sees half a file:
#   (a) reopen          logs/reopens.csv rows dated inside the window
#   (b) abandoned       ledgers(kind=abandoned) rows with status abandoned and
#                       updated_at in the window, plus blocked-resolver records
#                       (state/blocked-resolver/<p>/<rkey>.json, mtime in the
#                       window) with outcome ABANDONED; one item per project+ticket,
#                       the ledger row wins
#       parked          the same records with outcome CI_PARKED
#   (c) fix_rounds      the same records with fixrounds >= 2 or
#                       rereviews >= LOOKBACK_REREVIEW_MIN (2)
#   (d) alert_family    GET /api/alerts rows seen in the window, summed per
#                       family and project; count >= LOOKBACK_ALERT_MIN (3)
#   (e) postmerge_fail  `POST-MERGE PROD QA FAILED for` lines of logs/ALERTS.log
#       revert          commits whose subject starts `Revert ` or `Rollback` in
#                       each fleet repo (the bin/rule-miner.sh query)
# Item files[]: the newest builds/<p>-<ticket>-*/changed-files.txt, else the
# PR's GitHub file list (first 100), else [] — never a guessed path.
# A reopen item also carries pr (the PR GET /api/ticket-status picks for the
# ticket, bin/lib/lookback-reopen.sh lrd_pr_map), comment ({at, author, text}
# of the client's newest comment around the reopen, or null) and
# comment_status (saved | no-comment | unreadable | other-day | none, from the
# reopen_reason row of bin/lib/reopen-reason.sh, lrd_comment).
# sources.reopen.detail = {pr_lookup: ok | <why per project>, with_pr,
# with_comment}. A failed PR lookup leaves pr "" and is not .incomplete.
#
# Every source read records {ok, n, truncated, error?} under .sources. A read
# that fails is ok:false and makes .incomplete true; it is never read as zero.
# A skipped record (unparseable json) is named in that source's error and makes
# .incomplete true too. Over LOOKBACK_BUNDLE_MAX_ITEMS (400) items the newest are
# kept and .truncated/.incomplete are true.
#
# rc: 0 bundle written and at least one source read; 1 bundle written but NO
# source could be read; 2 usage (no --out, bad --since/--days, a non-integer knob).
# It writes nothing but the bundle: no ALERTS line, no ledger row. $0 spend.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
# The lane's settings rows (LOOKBACK_*) when this runs by hand; the driver has
# already gated the lane, so only lane_env_apply is called. Fail-open.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lookback
set -a; . "$HENV/global.env" 2>/dev/null; set +a
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lookback
# shellcheck source=lib/lookback-common.sh
. "$HARNESS/bin/lib/lookback-common.sh" || exit 1
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# shellcheck source=lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"   # App token per repo; unarmed box untouched
# The reopen item's PR and client comment. Fail-open: absent = today's item.
# shellcheck source=lib/reopen-reason.sh
[ -r "$HARNESS/bin/lib/reopen-reason.sh" ] && . "$HARNESS/bin/lib/reopen-reason.sh"
# shellcheck source=lib/lookback-reopen.sh
[ -r "$HARNESS/bin/lib/lookback-reopen.sh" ] && . "$HARNESS/bin/lib/lookback-reopen.sh"

usage() { echo "usage: lookback-collect.sh [--since <iso>] [--days N] --out <file>${1:+ ($1)}" >&2; exit 2; }
SINCE=""; DAYS="${LOOKBACK_DAYS:-7}"; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 || usage ;;
    --days)  DAYS="${2:-}"; shift 2 || usage ;;
    --out)   OUT="${2:-}"; shift 2 || usage ;;
    *) usage "unknown argument $1" ;;
  esac
done
[ -n "$OUT" ] || usage "--out is required"
int() { case "$2" in ''|*[!0-9]*) usage "$1 must be a whole number, got '$2'" ;; esac; }
int LOOKBACK_ALERT_MIN "${LOOKBACK_ALERT_MIN:=3}"
int LOOKBACK_REREVIEW_MIN "${LOOKBACK_REREVIEW_MIN:=2}"
int LOOKBACK_BUNDLE_MAX_ITEMS "${LOOKBACK_BUNDLE_MAX_ITEMS:=400}"

NOW=$(date -u +%s)
TO_S=$NOW
if [ -n "$SINCE" ]; then
  FROM_S=$(date -u -d "$SINCE" +%s 2>/dev/null) || usage "--since '$SINCE' is not a date"
  [ "$FROM_S" -le "$NOW" ] || usage "--since '$SINCE' is in the future"
else
  int --days "$DAYS"
  FROM_S=$((NOW - DAYS * 86400))
fi
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
FROM=$(iso "$FROM_S"); TO=$(iso "$TO_S")

US=$'\x1f'   # field separator of every internal row: tab is IFS whitespace, and
             # `read` collapses empty tab fields, which would shift a column
TMP=$(mktemp -d "${TMPDIR:-/tmp}/lookback-collect.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/items.jsonl"; : > "$TMP/sources.jsonl"

# epoch <time> — seconds, or rc 1 for anything date cannot read.
epoch() { [ -n "$1" ] && date -u -d "$1" +%s 2>/dev/null; }
# row — a jq array as ONE $US-separated line; a field's own newlines, tabs and
# separators become spaces, so a line is always one record.
JQ_ROW='def row: map(tostring | gsub("[\\n\\r\\t\u001f]"; " ")) | join("\u001f"); '
in_window() { [ -n "$1" ] && [ "$1" -ge "$FROM_S" ] && [ "$1" -le "$TO_S" ]; }

# source_record <name> <ok> <n> <truncated> [error] [detail-json-object]
source_record() {
  local det="${6:-}"
  jq -e 'type == "object"' <<<"${det:-null}" >/dev/null 2>&1 || det=null
  jq -nc --arg name "$1" --argjson ok "$2" --argjson n "$3" --argjson tr "$4" --arg e "${5:-}" --argjson det "$det" \
    '{name:$name, ok:$ok, n:$n, truncated:$tr} + (if $e == "" then {} else {error:$e} end)
     + (if $det == null then {} else {detail:$det} end)' >> "$TMP/sources.jsonl"
}

# item_files <project> <ticket> <pr-url> — a JSON array of paths.
item_files() {
  local p="$1" t="$2" pr="$3" d f="" slug n
  if [ -n "$t" ]; then
    for d in "$HARNESS/builds/$p-$t-"*/; do
      [ -s "$d/changed-files.txt" ] && f="$d/changed-files.txt"
    done
    if [ -n "$f" ]; then jq -Rsc 'split("\n") | map(select(. != ""))' "$f"; return; fi
  fi
  if [[ "$pr" =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]] && command -v gh >/dev/null 2>&1; then
    slug="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
    gh_for "$slug"
    if f=$(gh api "repos/$slug/pulls/$n/files?per_page=100" --jq '.[].filename' 2>/dev/null); then
      printf '%s' "$f" | jq -Rsc 'split("\n") | map(select(. != "")) | .[:100]'; return
    fi
  fi
  echo '[]'
}

# emit <source> <at-epoch> <project> <ticket> <pr> <lane> <reason> [extra-json-object]
# The extra object is merged into the item; it never changes the id.
emit() {
  local id files extra="${8:-}"
  jq -e 'type == "object"' <<<"${extra:-null}" >/dev/null 2>&1 || extra='{}'
  id=$(printf '%s|%s|%s|%s|%s' "$1" "$3" "$4" "$5" "$7" | sha1sum | cut -c1-12)
  files=$(item_files "$3" "$4" "$5")
  jq -nc --arg id "$id" --arg s "$1" --arg at "$(iso "$2")" --arg p "$3" --arg t "$4" --arg pr "$5" \
    --argjson files "${files:-[]}" --arg lane "$6" --arg r "$7" --argjson extra "$extra" \
    '{id:$id, source:$s, at:$at, project:$p, ticket:$t, pr:$pr, files:$files, lane:$lane, reason:$r} + $extra' >> "$TMP/items.jsonl"
}

# gh_for <owner/repo> — that repo's App token when this box mints them. The
# reset first, so a repo with no installation never inherits the last repo's token.
gh_for() {
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$1" || true
}

jobs_ready() { # jobs_ready — rc 0 when the worker can be asked; else prints why
  if ! declare -F _jobs_req >/dev/null; then echo "jobs client not installed"; return 1; fi
  if [ -z "${JOBS_URL:-}" ]; then echo "jobs not configured (JOBS_URL empty)"; return 1; fi
  return 0
}

# (a) reopen — logs/reopens.csv, `date` is %Y%m%d, so the window is by day.
# Pass 1 reads the in-window rows; pass 2 asks ticket-status once per project
# per chunk for the PRs; pass 3 emits each row with its PR and client comment.
src_reopen() {
  local f="$HARNESS/logs/reopens.csv" n=0 fd td d p k from to why="" pr extra wp=0 wc=0 detail
  if [ ! -e "$f" ]; then source_record reopen true 0 false; return; fi
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then source_record reopen false 0 false "logs/reopens.csv unreadable"; return; fi
  fd=$(date -u -d "@$FROM_S" +%Y%m%d); td=$(date -u -d "@$TO_S" +%Y%m%d)
  : > "$TMP/reopen.rows"; : > "$TMP/reopen.pr"
  while IFS=, read -r d p k from to; do
    [[ "$d" =~ ^[0-9]{8}$ ]] || continue
    [ "$d" -ge "$fd" ] && [ "$d" -le "$td" ] || continue
    printf "%s$US%s$US%s$US%s$US%s\n" "$d" "$p" "$k" "$from" "$to" >> "$TMP/reopen.rows"
  done < "$f"
  if [ -s "$TMP/reopen.rows" ]; then
    if ! declare -F lrd_pr_map >/dev/null; then
      why="bin/lib/lookback-reopen.sh not loaded"
    elif ! why=$(jobs_ready); then
      :
    else
      why=""
      while IFS= read -r p; do
        awk -F"$US" -v p="$p" '$2 == p { print $3 }' "$TMP/reopen.rows" > "$TMP/reopen.keys"
        if lrd_pr_map "$p" "$TMP/reopen.keys" "$TMP/reopen.pr1"; then :; else why="${why:+$why; }$p: $LRD_WHY"; fi
        awk -F'\t' -v p="$p" -v OFS='\t' '{ print p, $1, $2 }' "$TMP/reopen.pr1" >> "$TMP/reopen.pr"
      done < <(cut -d"$US" -f2 "$TMP/reopen.rows" | sort -u)
    fi
  fi
  while IFS="$US" read -r d p k from to; do
    pr=$(awk -F'\t' -v p="$p" -v k="$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')" '$1 == p && $2 == k { print $3; exit }' "$TMP/reopen.pr")
    if declare -F lrd_comment >/dev/null; then extra=$(lrd_comment "$p" "$k" "$d"); else extra=""; fi
    jq -e 'type == "object" and has("comment_status")' <<<"${extra:-null}" >/dev/null 2>&1 \
      || extra='{"comment":null,"comment_status":"none"}'
    emit reopen "$(epoch "${d:0:4}-${d:4:2}-${d:6:2}T00:00:00Z")" "$p" "$k" "$pr" reopen "reopened: $from -> $to" "$extra"
    n=$((n + 1))
    [ -n "$pr" ] && wp=$((wp + 1))
    [ "$(jq -r .comment_status <<<"$extra")" = saved ] && wc=$((wc + 1))
  done < "$TMP/reopen.rows"
  detail=$(jq -nc --arg why "$why" --argjson wp "$wp" --argjson wc "$wc" \
    '{pr_lookup: (if $why == "" then "ok" else $why end), with_pr: $wp, with_comment: $wc}')
  source_record reopen true "$n" false "" "$detail"
}

# The blocked-resolver records in the window, read once into $TMP/br.rows:
# project, ticket, outcome, fixrounds, rereviews, at-epoch, pr, reason ($US-separated).
BR_OK=true; BR_ERR=""
read_br() {
  local dir="$HARNESS/state/blocked-resolver" f p rkey row t at bad=0
  : > "$TMP/br.rows"
  [ -e "$dir" ] || return 0
  if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then BR_OK=false; BR_ERR="state/blocked-resolver unreadable"; return 0; fi
  while IFS= read -r f; do
    p=$(basename "$(dirname "$f")"); rkey=$(basename "$f" .json)
    row=$(jq -r "$JQ_ROW"'[(.outcome // ""), (.fixrounds // 0), (.rereviews // 0), (.updated // ""),
                  ([(.attempts // [])[] | .url // empty] | last // ""),
                  ((.attempts // []) | last | .reason // "")] | row' "$f" 2>/dev/null) || { bad=$((bad + 1)); continue; }
    [ -n "$row" ] || { bad=$((bad + 1)); continue; }
    if [ -s "$dir/$p/$rkey.tkey" ]; then t=$(head -1 "$dir/$p/$rkey.tkey"); else t="${rkey#"$p"-}"; fi
    IFS="$US" read -r o fr rr up url why <<<"$row"
    at=$(epoch "$up") || at=$(stat -c %Y "$f")
    printf "%s$US%s$US%s$US%s$US%s$US%s$US%s$US%s\n" "$p" "$t" "$o" "$fr" "$rr" "$at" "$url" "$why" >> "$TMP/br.rows"
  done < <(find "$dir" -mindepth 2 -maxdepth 2 -name '*.json' -newermt "@$FROM_S" 2>/dev/null | sort)
  [ "$bad" -gt 0 ] && BR_ERR="$bad unparseable record(s) skipped"
  return 0
}

# (b) abandoned — the ledger first (it wins), then the records.
src_abandoned() {
  local why rc n=0 tr=false key st up at p t pr
  : > "$TMP/abandoned.keys"
  if why=$(jobs_ready); then
    # _jobs_req in THIS shell, not job_ledger_list in a $(...): JOBS_HTTP is
    # what tells an outage from an empty table, and a 200 that is not a
    # {ledgers:[...]} body is an outage too, never zero rows.
    _jobs_req GET "/api/ledger?kind=abandoned&limit=1000" > "$TMP/ledger.json"; rc=$?
    if [ "$rc" = 0 ] && jq -e '.ledgers | type == "array"' "$TMP/ledger.json" >/dev/null 2>&1; then
      while IFS="$US" read -r key st up; do
        [ "$st" = abandoned ] || continue
        at=$(epoch "$up") && in_window "$at" || continue
        p="${key%% *}"; t="${key#* }"
        pr=$(awk -F"$US" -v p="$p" -v t="$t" '$1 == p && $2 == t && $7 != "" { u = $7 } END { print u }' "$TMP/br.rows")
        emit abandoned "$at" "$p" "$t" "$pr" blocked-resolver abandoned
        printf '%s|%s\n' "$p" "$t" >> "$TMP/abandoned.keys"
        n=$((n + 1))
      done < <(jq -r "$JQ_ROW"'.ledgers[] | [(.key // ""), (.status // ""), (.updated_at // "")] | row' "$TMP/ledger.json")
      # 1000 rows (the route's ceiling) and the oldest still in the window:
      # there may be more the read never saw.
      if [ "$(jq '.ledgers | length' "$TMP/ledger.json")" -ge 1000 ] \
         && at=$(epoch "$(jq -r '.ledgers | last | .updated_at // ""' "$TMP/ledger.json")") && in_window "$at"; then
        tr=true
      fi
      source_record abandoned true "$n" "$tr"
    else
      source_record abandoned false 0 false "ledger http=${JOBS_HTTP:-none}"
    fi
  else
    source_record abandoned false 0 false "$why"
  fi
}

# (b) parked + the records' ABANDONED items, and (c) fix_rounds.
src_br() {
  local nb=0 nf=0 p t o fr rr at pr why
  if [ "$BR_OK" != true ]; then
    source_record br_records false 0 false "$BR_ERR"; source_record fix_rounds false 0 false "$BR_ERR"; return
  fi
  while IFS="$US" read -r p t o fr rr at pr why; do
    case "$o" in
      ABANDONED)
        if ! grep -qxF "$p|$t" "$TMP/abandoned.keys"; then
          emit abandoned "$at" "$p" "$t" "$pr" blocked-resolver "${why:-$o}"; nb=$((nb + 1))
        fi ;;
      CI_PARKED) emit parked "$at" "$p" "$t" "$pr" blocked-resolver "${why:-$o}"; nb=$((nb + 1)) ;;
    esac
    case "$fr$rr" in *[!0-9]*) continue ;; esac
    if [ "$fr" -ge 2 ] || [ "$rr" -ge "$LOOKBACK_REREVIEW_MIN" ]; then
      emit fix_rounds "$at" "$p" "$t" "$pr" blocked-resolver "$fr fix rounds, $rr re-reviews"; nf=$((nf + 1))
    fi
  done < "$TMP/br.rows"
  source_record br_records true "$nb" false "$BR_ERR"
  source_record fix_rounds true "$nf" false "$BR_ERR"
}

# (d) alert_family — the per-row list, summed per family and project.
src_alerts() {
  local why rc n=0 tr=false fam p cnt last line at
  if ! why=$(jobs_ready); then source_record alert_family false 0 false "$why"; return; fi
  alerts_list --since "$((TO_S - FROM_S))" --limit 500 > "$TMP/alerts.tsv"; rc=$?
  if [ "$rc" != 0 ]; then source_record alert_family false 0 false "alerts http=${JOBS_HTTP:-none}"; return; fi
  grep -qx '#truncated' "$TMP/alerts.tsv" && tr=true
  while IFS="$US" read -r fam p cnt last line; do
    [ "$cnt" -ge "$LOOKBACK_ALERT_MIN" ] || continue
    at=$(epoch "$last") && in_window "$at" || continue
    line=$(printf '%s' "$line" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:]{8}Z? //' | cut -c1-300)
    emit alert_family "$at" "$p" "" "" "${fam%%:*}" "$fam x$cnt: $line"
    n=$((n + 1))
  done < <(grep -v '^#' "$TMP/alerts.tsv" | jq -R 'split("\t")' | jq -rs "$JQ_ROW"'
    map({family: (if .[1] == "" then .[0] else .[1] end), project: .[3],
         count: ((.[5] | tonumber?) // 1), last_seen: .[7], line: (.[12] // "" | gsub("\\\\[nt]"; " "))})
    | group_by([.family, .project])[]
    | (max_by(.last_seen)) as $l
    | [$l.family, $l.project, (map(.count) | add), $l.last_seen, $l.line] | row')
  source_record alert_family true "$n" "$tr"
}

# (e) postmerge_fail — only the FAILED shape bin/postmerge-qa.sh writes;
# NOT RUN and BLOCKED are not defect claims.
src_postmerge() {
  local f="$HARNESS/logs/ALERTS.log" n=0 l at
  local re='^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z) \[([^]]+)\] POST-MERGE PROD QA FAILED for ([^ ]+) \(([0-9a-f]*), ([^)]*)\): (.*)$'
  if [ ! -e "$f" ]; then source_record postmerge_fail true 0 false; return; fi
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then source_record postmerge_fail false 0 false "logs/ALERTS.log unreadable"; return; fi
  while IFS= read -r l; do
    [[ "$l" =~ $re ]] || continue
    at=$(epoch "${BASH_REMATCH[1]}") && in_window "$at" || continue
    emit postmerge_fail "$at" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}" postmerge-qa "$(printf '%s' "${BASH_REMATCH[6]}" | cut -c1-300)"
    n=$((n + 1))
  done < <(grep -F 'POST-MERGE PROD QA FAILED for' "$f")
  source_record postmerge_fail true "$n" false
}

# (e) revert — per fleet repo, deduped on the slug, as bin/rule-miner.sh does.
src_revert() {
  local fc="$HARNESS/bin/fleet-conf.sh" n=0 tr=false failed="" P SLUG ps d subj at
  if [ ! -x "$fc" ] || ! command -v gh >/dev/null 2>&1; then source_record revert false 0 false "gh unavailable"; return; fi
  if ! ps=$("$fc" --projects 2>/dev/null); then source_record revert false 0 false "fleet-conf.sh --projects failed"; return; fi
  while IFS=$'\t' read -r P SLUG; do
    gh_for "$SLUG"
    if ! gh api "repos/$SLUG/commits?since=$FROM&per_page=100" > "$TMP/commits.json" 2>/dev/null \
       || ! jq -e 'type == "array"' "$TMP/commits.json" >/dev/null 2>&1; then
      failed="${failed:+$failed }$SLUG"; continue
    fi
    [ "$(jq length "$TMP/commits.json")" -ge 100 ] && tr=true
    while IFS="$US" read -r d subj; do
      at=$(epoch "$d") && in_window "$at" || continue
      emit revert "$at" "$P" "" "" revert "$subj"
      n=$((n + 1))
    done < <(jq -r "$JQ_ROW"'.[] | (.commit.message | split("\n")[0]) as $s | select($s | test("^(Revert |Rollback)"))
                     | [(.commit.committer.date // .commit.author.date // ""), $s] | row' "$TMP/commits.json")
  done < <(while IFS= read -r P; do
             [ -n "$P" ] || continue
             SLUG=$("$fc" "$P" repo 2>/dev/null) || continue
             [ -n "$SLUG" ] && [ "$SLUG" != "-" ] || continue
             printf '%s\t%s\n' "$P" "$SLUG"
           done <<<"$ps" | sort -u -k2,2)
  if [ -n "$failed" ]; then source_record revert false "$n" "$tr" "gh failed for $failed"
  else source_record revert true "$n" "$tr"; fi
}

read_br
src_reopen
src_abandoned
src_br
src_alerts
src_postmerge
src_revert

mkdir -p "$(dirname "$OUT")"
jq -n --arg from "$FROM" --arg to "$TO" --argjson max "$LOOKBACK_BUNDLE_MAX_ITEMS" \
  --slurpfile items "$TMP/items.jsonl" --slurpfile src "$TMP/sources.jsonl" '
  ($items | length > $max) as $cut
  | (if $cut then ($items | sort_by(.at) | reverse | .[:$max]) else $items end
     | sort_by([.source, .project, .ticket])) as $kept
  | {window: {from: $from, to: $to},
     items: $kept,
     sources: ($src | map({(.name): (del(.name))}) | add // {}),
     truncated: $cut,
     incomplete: ($cut or ($src | any(.ok == false or .truncated or has("error"))))}' > "$OUT.tmp" \
  && mv "$OUT.tmp" "$OUT" || { rm -f "$OUT.tmp"; echo "lookback-collect: could not write $OUT" >&2; exit 1; }
jq -e '.sources | any(.ok)' "$OUT" >/dev/null 2>&1 || exit 1
exit 0
