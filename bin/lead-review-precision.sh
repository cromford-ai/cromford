#!/bin/bash
# bin/lead-review-precision.sh — BH-3548 (BH-3479.4): how often a lead MERGE
# turns out wrong. Daily at 05:40Z (cron/lanes/714-lead-review-precision.cron),
# on the hub only. No model call, no SSH.
#
# For each repo in LEAD_REVIEW_AUTO_REPOS (the BH-3479.0 contract knob on the
# lead-review-land lane), every PR merged in the last
# LEAD_REVIEW_PRECISION_WINDOW_DAYS days is looked up in /api/verdicts on its
# MERGED head. The newest `source=lead` row on that head whose note carries a
# `lead-review:` token is its lead verdict; a PR with none is not counted. A
# lead MERGE / MERGE-WITH-NOTES is scored bad when
#   reverted      a `Revert "…` commit on main since the window start names #N
#                 (#12 never matches #123), or
#   batch_failed  a check run on the head named `Queue:…` concluded failure or
#                 cancelled (filter=all, so a run a re-embark superseded counts).
# precision = (lead_merge - bad) / lead_merge, 3 decimals; null when n = 0.
#
# UNREADABLE IS NEVER CLEAN. A failed verdict, check-runs or commits read counts
# the PR `unreadable` and leaves it out of lead_merge. A failed PR-list page
# turns the whole repo into an `error` object with precision null: a partial list
# is never scored. A page cap sets `truncated`.
#
# Output: state/lead-review-precision/<YYYY-MM-DD>.json, written atomically and
# carrying no wall-clock field, so a same-day rerun over the same answers is
# byte-identical. One summary line per run in logs/lead-review-precision.log.
# When a repo has lead_merge >= LEAD_REVIEW_PRECISION_MIN_N and precision under
# LEAD_REVIEW_PRECISION_WARN, ONE warn beat a day (--id lead-precision-<day>,
# plus the warned-<day> flag written after lane-alert.sh succeeds).
#
# THE AUTHORITY GATE (BH-3683). For each scored repo in scope (it has live
# lead_protected_paths rows, bin/lib/lead-authority.sh; unreadable rows hold the
# repo with its authority unchanged) with no error,
# a precision and lead_merge >= LEAD_REVIEW_PRECISION_MIN_N:
#   precision < LEAD_REVIEW_AUTHORITY_MIN_PRECISION and the settings row
#     lead_authority.<owner>.<name> reads lane (or there is none): the row is
#     set to human:precision, so every lead MERGE on the repo is advice until a
#     --source human verdict publishes it, and ONE critical page goes out
#     (lead-authority-revoked-<owner_name>-<day>). Only the transition pages. A
#     failed row write pages nobody (next run retries); a written row whose page
#     failed leaves state/lead-review-precision/authority-page-owed-<owner_name>,
#     and the next run sends that page before anything else.
#   precision >= the threshold and the row reads human:precision: back to lane,
#     one warn beat (lead-authority-restored-<owner_name>-<day>).
#   The row reads human (an operator set it): never touched.
#   An unreadable row: nothing changes, one log line.
# A scored repo outside catalog scope is logged as scored but not governed.
# Kill switch: flags/lane-off-lead-review-precision.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165). Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off lead-review-precision.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lead-review-precision
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lead-review-precision
# The BH-3479.0 contract's reader: LEAD_REVIEW_AUTO_REPOS is a required knob of
# the lead-review-land lane, exported here even when no settings row exists.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lead-review-land

LOG="$H/logs/lead-review-precision.log"
STATE="$H/state/lead-review-precision"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) $*" >> "$LOG"; }

# shellcheck source=bin/lib/hub-box.sh
. "$H/bin/lib/hub-box.sh" 2>/dev/null || { log "missing bin/lib/hub-box.sh; lead-review-precision tick skipped"; exit 0; }
BOX=$(local_box_name)
if ! is_hub_box "$BOX"; then log "not the hub (${BOX:-unnamed}); lead-review-precision runs on the hub only"; exit 0; fi

# jobs-client.sh exits its caller on a missing module, so every piece is checked first.
for f in bin/jobs-client.sh bin/lib/jobs/req.sh bin/lib/gh-rest.sh; do
  [ -r "$H/$f" ] || { log "missing $f; lead-review-precision tick skipped"; exit 0; }
done
# shellcheck source=/dev/null
{ . "$H/bin/jobs-client.sh"; . "$H/bin/lib/gh-rest.sh"; }
# shellcheck source=/dev/null
. "$H/bin/lib/gh-app-auth.sh" 2>/dev/null || true

mkdir -p "$STATE" 2>/dev/null
# A tick dedupe, never a queue: a second run while one runs skips.
exec 9>"$STATE/tick.lock"; flock -n 9 || { log "another run holds $STATE/tick.lock; skipped"; exit 0; }
# shellcheck source=bin/lib/lead-authority.sh
LA_OK=0; [ -r "$H/bin/lib/lead-authority.sh" ] && . "$H/bin/lib/lead-authority.sh" && LA_OK=1

# BH-3683: a revocation page that was owed by an earlier run goes out first.
for OWED in "$STATE"/authority-page-owed-*; do
  [ -f "$OWED" ] || continue
  OID=$(head -1 "$OWED"); OMSG=$(sed -n '2,$p' "$OWED")
  if [ -n "$OID" ] && [ -n "$OMSG" ] && "$H/bin/lane-alert.sh" --severity critical --id "$OID" lead-review-precision "$OMSG"; then
    rm -f "$OWED"; log "owed page $OID sent"
  else
    log "owed page ${OID:-?} still not sent; retried next run"
  fi
done

DAYS="${LEAD_REVIEW_PRECISION_WINDOW_DAYS:-30}"
case "$DAYS" in ''|*[!0-9]*|0*) log "LEAD_REVIEW_PRECISION_WINDOW_DAYS='$DAYS' is not a positive integer; using 30"; DAYS=30 ;; esac
WARN="${LEAD_REVIEW_PRECISION_WARN:-0.9}"
awk -v w="$WARN" 'BEGIN { exit !(w ~ /^([0-9]+|[0-9]*\.[0-9]+)$/ && w + 0 <= 1) }' \
  || { log "LEAD_REVIEW_PRECISION_WARN='$WARN' is not a number in [0,1]; using 0.9"; WARN=0.9; }
AMIN="${LEAD_REVIEW_AUTHORITY_MIN_PRECISION:-0.8}"
awk -v w="$AMIN" 'BEGIN { exit !(w ~ /^([0-9]+|[0-9]*\.[0-9]+)$/ && w + 0 <= 1) }' \
  || { log "LEAD_REVIEW_AUTHORITY_MIN_PRECISION='$AMIN' is not a number in [0,1]; using 0.8"; AMIN=0.8; }
MIN_N="${LEAD_REVIEW_PRECISION_MIN_N:-5}"
case "$MIN_N" in ''|*[!0-9]*|0*) log "LEAD_REVIEW_PRECISION_MIN_N='$MIN_N' is not a positive integer; using 5"; MIN_N=5 ;; esac
MAXP="${LEAD_REVIEW_PRECISION_MAX_PAGES:-30}"
case "$MAXP" in ''|*[!0-9]*|0*) log "LEAD_REVIEW_PRECISION_MAX_PAGES='$MAXP' is not a positive integer; using 30"; MAXP=30 ;; esac
REPOS="${LEAD_REVIEW_AUTO_REPOS:-}"
[ -n "${REPOS// /}" ] || { log "LEAD_REVIEW_AUTO_REPOS is empty; nothing to score"; exit 0; }

NOW=$(date +%s)
DAY=$(date -u -d "@$NOW" +%F)
SINCE=$(date -u -d "@$((NOW - DAYS * 86400))" +%Y-%m-%dT%H:%M:%SZ)

W=$(mktemp -d "${TMPDIR:-/tmp}/lead-review-precision.XXXXXX") || { log "mktemp failed; run skipped"; exit 0; }
OUTF=""
trap 'rm -rf "$W"; [ -n "$OUTF" ] && rm -f "$OUTF"' EXIT
# Not a decision path: the quota reserve may refuse any read (rc 75 = unreadable).
export GH_REST_OPTIONAL=1

# page_list <path without &page=> <jq filter over one page> <out> — every page
# through a file, in-window rows appended to <out>. rc 0 = complete, 1 = read
# failed (ERR says why), and PAGE_TRUNC=true when MAXP stopped it inside the window.
page_list() {
  local base="$1" filter="$2" out="$3" p=1 rc n last
  PAGE_TRUNC=false
  while :; do
    rc=0; gh_rest GET "$base&page=$p" > "$W/page" || rc=$?
    [ "$rc" = 0 ] || { ERR="HTTP $GH_REST_STATUS"; return 1; }
    jq -e 'type == "array"' "$W/page" >/dev/null 2>&1 || { ERR="unparseable page $p"; return 1; }
    jq -c --arg s "$SINCE" "$filter" "$W/page" >> "$out" || { ERR="unparseable page $p"; return 1; }
    n=$(jq length "$W/page"); last=$(jq -r '.[-1].updated_at // .[-1].commit.committer.date // ""' "$W/page")
    [ "$n" -lt 100 ] && return 0
    [ -n "$last" ] && [[ "$last" < "$SINCE" ]] && return 0
    p=$((p + 1))
    [ "$p" -gt "$MAXP" ] && { PAGE_TRUNC=true; return 0; }
  done
}

# score_repo <slug> — prints the repo's JSON object on stdout.
score_repo() {
  local slug="$1" trunc=false err="" pr head vt verdict msgs rc bf rv
  : > "$W/merged"; : > "$W/entries"; : > "$W/leads"; : > "$W/reverts"
  command -v gh_default_auth_for_slug >/dev/null 2>&1 && { gh_default_auth_for_slug "$slug" || true; }
  ERR=""
  if ! page_list "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
       '.[] | select(.merged_at != null and .merged_at >= $s) | [.number, .head.sha]' "$W/merged"; then
    err="pulls unreadable ($ERR)"; : > "$W/merged"
  fi
  trunc=$PAGE_TRUNC
  # a) the lead verdict on each merged head
  while IFS=$'\t' read -r pr head; do
    [ -n "$pr" ] || continue
    vt="$W/v-$pr"
    if ! JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$slug&pr=$pr&head=$head" > "$vt" 2>/dev/null \
       || ! verdict=$(jq -er --arg h "$head" 'if (.rows | type) != "array" then error("no rows") else . end
            | [.rows[] | select(.source == "lead" and .head_sha == $h
            and ((.note // "") | test("(^| )lead-review:")))] | max_by(.id) | .verdict // "none"' "$vt" 2>/dev/null); then
      jq -nc --argjson pr "$pr" --arg h "$head" '{pr:$pr, verdict:"unreadable", head:$h, reverted:null, batch_failed:null, unreadable:true}' >> "$W/entries"
      continue
    fi
    case "$verdict" in
      none) ;;
      MERGE|MERGE-WITH-NOTES) printf '%s\t%s\t%s\n' "$pr" "$head" "$verdict" >> "$W/leads" ;;
      *) jq -nc --argjson pr "$pr" --arg h "$head" --arg v "$verdict" '{pr:$pr, verdict:$v, head:$h, reverted:null, batch_failed:null}' >> "$W/entries" ;;
    esac
  done < <(jq -r '@tsv' "$W/merged" | sort -u -n)
  # b) main's revert commits, read only when there is a lead MERGE to score
  msgs=ok
  if [ -s "$W/leads" ]; then
    if ! page_list "repos/$slug/commits?sha=main&since=$SINCE&per_page=100" \
         '.[] | .commit.message // "" | select(startswith("Revert \""))' "$W/reverts"; then
      msgs=bad; err="${err:+$err; }commits unreadable ($ERR)"
    fi
    [ "$PAGE_TRUNC" = true ] && trunc=true
  fi
  # c) each lead MERGE: batch failure on its head, revert naming it
  while IFS=$'\t' read -r pr head verdict; do
    [ -n "$pr" ] || continue
    rc=1
    if [ "$msgs" = ok ]; then
      rc=0; gh_rest GET "repos/$slug/commits/$head/check-runs?per_page=100&filter=all" > "$W/checks" || rc=$?
      [ "$rc" = 0 ] && { bf=$(jq '[.check_runs[] | select((.name // "" | startswith("Queue:")) and (.conclusion == "failure" or .conclusion == "cancelled"))] | length > 0' "$W/checks" 2>/dev/null) || rc=1; }
      case "${bf:-}" in true|false) ;; *) rc=1 ;; esac
    fi
    if [ "$rc" != 0 ]; then
      jq -nc --argjson pr "$pr" --arg h "$head" --arg v "$verdict" '{pr:$pr, verdict:$v, head:$h, reverted:null, batch_failed:null, unreadable:true}' >> "$W/entries"
      continue
    fi
    rv=$(jq -s --arg n "$pr" 'any(.[]; test("#" + $n + "([^0-9]|$)"))' "$W/reverts")
    jq -nc --argjson pr "$pr" --arg h "$head" --arg v "$verdict" --argjson rv "$rv" --argjson bf "$bf" \
      '{pr:$pr, verdict:$v, head:$h, reverted:$rv, batch_failed:$bf, scored:true}' >> "$W/entries"
  done < "$W/leads"
  command -v gh_default_auth_reset >/dev/null 2>&1 && gh_default_auth_reset
  jq -sc --arg repo "$slug" --argjson days "$DAYS" --argjson trunc "$trunc" --arg err "$err" '
    [.[] | select(.scored)] as $s | ($s | length) as $n
    | ([$s[] | select(.reverted or .batch_failed)] | length) as $bad
    | {repo:$repo, window_days:$days, error:(if $err == "" then null else $err end),
       lead_merge:$n, reverted:([$s[] | select(.reverted)] | length),
       batch_failed:([$s[] | select(.batch_failed)] | length),
       unreadable:([.[] | select(.unreadable)] | length),
       precision:(if $n == 0 then null else (((($n - $bad) / $n) * 1000) | round) / 1000 end),
       truncated:$trunc,
       prs:(sort_by(.pr) | map({pr, verdict, head, reverted, batch_failed}))}' "$W/entries"
}

: > "$W/repos"
for SLUG in $REPOS; do
  [[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { log "LEAD_REVIEW_AUTO_REPOS entry '$SLUG' is not owner/repo; skipped"; continue; }
  score_repo "$SLUG" >> "$W/repos" || log "$SLUG: could not build its result; left out of $DAY.json"
done

FILE="$STATE/$DAY.json"
OUTF=$(mktemp "$STATE/.$DAY.XXXXXX") || { log "mktemp in $STATE failed; nothing written"; exit 0; }
if ! jq -sS --arg day "$DAY" --argjson days "$DAYS" '{day:$day, window_days:$days, repos:.}' "$W/repos" > "$OUTF" \
   || ! mv -f "$OUTF" "$FILE"; then
  log "could not write $FILE; nothing recorded"; exit 0
fi
OUTF=""

log "day=$DAY window=${DAYS}d $(jq -r '[.repos[] | "\(.repo) lead_merge=\(.lead_merge) reverted=\(.reverted) batch_failed=\(.batch_failed) unreadable=\(.unreadable) precision=\(.precision // "null") truncated=\(.truncated)\(if .error then " error=\(.error)" else "" end)"] | join("; ")' "$FILE")"

LOW=$(jq -r --argjson w "$WARN" --argjson m "$MIN_N" \
  '[.repos[] | select(.precision != null and .lead_merge >= $m and .precision < $w)
    | "\(.repo) precision \(.precision) over n=\(.lead_merge) (reverted \(.reverted), batch_failed \(.batch_failed))"] | join("; ")' "$FILE")
if [ -n "$LOW" ] && [ ! -e "$STATE/warned-$DAY" ]; then
  if "$H/bin/lane-alert.sh" --severity warn --id "lead-precision-$DAY" lead-review-precision \
       "[lead-review-precision] lead MERGE precision under $WARN over the last ${DAYS} days: $LOW. Detail: state/lead-review-precision/$DAY.json"; then
    : > "$STATE/warned-$DAY"
  else
    log "lane-alert.sh failed; the warn is retried next run"
  fi
fi

# BH-3683: the authority gate (header). One repo per line off the day file.
[ "$LA_OK" = 1 ] || { log "bin/lib/lead-authority.sh did not load; the authority gate is skipped"; exit 0; }
while IFS=$'\t' read -r SLUG P N E; do
  [ -n "$SLUG" ] || continue
  SC=0; la_scope "$SLUG" || SC=$?
  case "$SC" in
    0) ;;
    1) log "$SLUG: scored but not governed: no live lead_protected_paths rows (add one on SETTINGS → PROTECTED PATHS to gate it)"; continue ;;
    *) log "$SLUG: protected paths unreadable (jobs worker, no fresh cache); held: authority unchanged"; continue ;;
  esac
  if [ "$E" != - ] || [ "$P" = null ] || [ "$N" -lt "$MIN_N" ]; then
    log "$SLUG: authority unchanged: precision $P, n=$N (min $MIN_N), error $E"; continue
  fi
  K=$(_la_key "$SLUG") || { log "$SLUG: no legal settings key; authority unchanged"; continue; }
  KEY="lead_authority.$K"; ON=$(printf '%s' "$SLUG" | tr 'A-Z/' 'a-z_')
  CUR=""; GRC=0; CUR=$(setting_get "$KEY") || GRC=$?
  case "$GRC" in
    0) CUR=$(printf '%s' "$CUR" | tr -d '[:space:]') ;;
    2) CUR=lane ;;
    *) log "$SLUG: the authority row $KEY could not be read; authority unchanged"; continue ;;
  esac
  LOWP=$(awk -v p="$P" -v t="$AMIN" 'BEGIN { print (p + 0 < t + 0) ? 1 : 0 }')
  if [ "$LOWP" = 1 ] && [ "$CUR" = lane ]; then
    # BH-4145: under lead_authority_mode=lane (the default) la_decide never reads
    # $KEY, so writing human:precision would withhold nothing and the critical
    # page below would be false. The drop is still in the day's warn above; the
    # lane stays the authority. An unreadable mode keeps the revocation (it holds).
    MRC=0; _la_mode "$SLUG" || MRC=$?
    if [ "$MRC" = 0 ] && [ "$LA_MODE" = lane ]; then
      log "$SLUG: precision $P < $AMIN over n=$N; lead_authority_mode=lane ($LA_MODE_SRC), so nothing is withheld and $KEY is left alone"
      continue
    fi
    if ! setting_set "$KEY" human:precision "BH-3683: precision $P < $AMIN over n=$N on $DAY"; then
      log "$SLUG: precision $P < $AMIN but could not write the authority row $KEY; no page, retried next run"; continue
    fi
    log "$SLUG: precision $P < $AMIN over n=$N; $KEY set to human:precision"
    PID="lead-authority-revoked-$ON-$DAY"
    PMSG="$SLUG lead lane authority REVOKED: precision $P under $AMIN over the last $DAYS days (n=$N); every protected and unprotected PR now needs a --source human verdict. Detail: state/lead-review-precision/$DAY.json. Restore: bin/jobs-client.sh setting-set $KEY lane"
    if ! "$H/bin/lane-alert.sh" --severity critical --id "$PID" lead-review-precision "$PMSG"; then
      printf '%s\n%s\n' "$PID" "$PMSG" > "$STATE/authority-page-owed-$ON" \
        && log "$SLUG: the revocation page failed; owed, sent first next run" \
        || log "$SLUG: the revocation page failed and the owed marker could not be written"
    fi
  elif [ "$LOWP" = 0 ] && [ "$CUR" = human:precision ]; then
    if setting_set "$KEY" lane "BH-3683: precision recovered $P >= $AMIN"; then
      log "$SLUG: precision $P >= $AMIN; $KEY back to lane"
      "$H/bin/lane-alert.sh" --severity warn --id "lead-authority-restored-$ON-$DAY" lead-review-precision \
        "$SLUG lead lane authority restored: precision $P >= $AMIN over n=$N. $KEY is lane again." \
        || log "$SLUG: the restore beat failed"
    else
      log "$SLUG: precision $P >= $AMIN but could not write $KEY back to lane; retried next run"
    fi
  fi
done < <(jq -r '.repos[] | [.repo, (.precision // "null" | tostring), (.lead_merge | tostring), (.error // "-")] | @tsv' "$FILE")
exit 0
