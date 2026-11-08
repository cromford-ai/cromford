#!/bin/bash
# bin/review-disprove-report.sh [--print] [--no-send] [--report-now] [--dry-stop]
#
# BH-9238 (C2 of BH-9047): THE 7-DAY DISPROVE REPORT LINE AND THE STOP RULE.
# Daily at 06:25Z on the hub (cron/lanes/718-review-disprove-report.cron). No
# model call. It reads GET /api/review-disprove (the rows dp_record writes,
# bin/lib/review-disprove.sh), GET /api/verdicts and GitHub REST (gh_rest).
#
# 1. THE REPORT. Over the last REVIEW_DISPROVE_REPORT_WINDOW_D days, per lane
#    (lead, conductor) and in total: BLOCK reviews checked, the share fully
#    disproved (every model BLOCK finding DISPROVED), and for each fully
#    disproved row what the next human/Opus read said (drr_next_read:
#    agreed-false | disagreed | pending | unreadable). It writes
#    state/review-disprove-report/latest.txt and <date>.json every run. It
#    posts ONE triaged fleet_alert beat (akey review-disprove-report:<date>)
#    only on weekday REVIEW_DISPROVE_REPORT_DOW (or with --report-now), only
#    when REVIEW_DISPROVE_REPORT_SEND = 1 (and no --no-send), and only when
#    there is at least one BLOCK. The lane never writes review.disprove.mode:
#    the operator decides enforce.
# 2. THE STOP RULE. Only when review.disprove.mode reads enforce, and only for
#    the projects whose dp_gate reads enforce: a row of the last
#    2 x REVIEW_DISPROVE_STOP_WINDOW_D days with mode enforce, verdict
#    BLOCK -> APPROVE|MERGE-WITH-NOTES and a DISPROVED finding at <path>:<n>[-<m>],
#    whose PR merged after the row, and a merged PR labelled
#    the main-red label (main_red_label_resolve, default fix-main-red; reverts carry it too) within
#    REVIEW_DISPROVE_STOP_WINDOW_D days of that merge, whose files change a
#    hunk within REVIEW_DISPROVE_STOP_SLACK_LINES of the finding's lines. Then,
#    in this order: setting review.disprove.<project>.enabled = 0 (re-read to
#    prove it), ledger row review_disprove_stop <repo>#<pr>@<head12>:<fix-pr>,
#    one critical lane-alert (--id review-disprove-stop-<project>). A pair with
#    a ledger row is skipped, so a project an operator turns back on is not
#    turned off again by the same pair. --dry-stop prints the decision and
#    writes nothing.
#
# AN UNREADABLE READ IS NEVER A COUNT. A worker that cannot answer is "n/a"
# (no beat, no stop check); a failed verdicts or compare read is "unreadable",
# never agreed; a failed GitHub read in the stop rule is "unreadable" and
# writes nothing (the next daily run tries again). Every path exits 0.
#
# Knobs (catalog/lanes.d/review-disprove-report.json; settings rows via lane_env_apply):
#   REVIEW_DISPROVE_REPORT_WINDOW_D   7   report window, days (1..90)
#   REVIEW_DISPROVE_REPORT_DOW        1   weekday of the beat, date +%u (1..7)
#   REVIEW_DISPROVE_REPORT_SEND       1   0 = files only
#   REVIEW_DISPROVE_REPORT_MAX_READS  40  next-read lookups per run (1..500)
#   REVIEW_DISPROVE_REPORT_KEEP_D     84  report files older than this are deleted (7..3650)
#   REVIEW_DISPROVE_STOP_WINDOW_D     7   days after a merge a fix PR counts (1..30)
#   REVIEW_DISPROVE_STOP_SLACK_LINES  10  line window around a finding (0..500)
#   REVIEW_DISPROVE_STOP_MAX_PRS      50  GitHub reads per run for the stop rule (1..500)
# The list limit is the settings row review.disprove.list_max (BH-9047, fallback 500).
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate. Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off review-disprove-report.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit review-disprove-report
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    review-disprove-report
# <<< lane gate

PRINT=0 SEND="" NOW_BEAT=0 DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --print) PRINT=1 ;;
    --no-send) SEND=0 ;;
    --report-now) NOW_BEAT=1 ;;
    --dry-stop) DRY=1 ;;
    *) echo "usage: review-disprove-report.sh [--print] [--no-send] [--report-now] [--dry-stop]" >&2; exit 2 ;;
  esac
  shift
done

LOG="$H/logs/review-disprove-report.log"
OUT_DIR="$H/state/review-disprove-report"
mkdir -p "$OUT_DIR" "$H/logs" 2>/dev/null
NOTES=""
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [review-disprove-report] $*" >> "$LOG"; }

# knob <OUT> <NAME> <lo> <hi> <fallback> — OUT = a whole number in lo..hi,
# else the fallback (a bad value is named in the run's log line).
knob() {
  local v="${!2:-}"
  if [ -z "$v" ]; then printf -v "$1" '%s' "$5"
  elif [[ "$v" =~ ^[0-9]{1,6}$ ]] && [ "$((10#$v))" -ge "$3" ] && [ "$((10#$v))" -le "$4" ]; then printf -v "$1" '%s' "$((10#$v))"
  else NOTES="$NOTES $2=$v(bad,using-$5)"; printf -v "$1" '%s' "$5"; fi
}
knob W_D    REVIEW_DISPROVE_REPORT_WINDOW_D 1 90 7       # fallback of knob REVIEW_DISPROVE_REPORT_WINDOW_D
knob DOW    REVIEW_DISPROVE_REPORT_DOW 1 7 1             # fallback of knob REVIEW_DISPROVE_REPORT_DOW
knob SEND_K REVIEW_DISPROVE_REPORT_SEND 0 1 1            # fallback of knob REVIEW_DISPROVE_REPORT_SEND
knob MAXR   REVIEW_DISPROVE_REPORT_MAX_READS 1 500 40    # fallback of knob REVIEW_DISPROVE_REPORT_MAX_READS
knob KEEP   REVIEW_DISPROVE_REPORT_KEEP_D 7 3650 84      # fallback of knob REVIEW_DISPROVE_REPORT_KEEP_D
knob SW     REVIEW_DISPROVE_STOP_WINDOW_D 1 30 7         # fallback of knob REVIEW_DISPROVE_STOP_WINDOW_D
knob SLACK  REVIEW_DISPROVE_STOP_SLACK_LINES 0 500 10    # fallback of knob REVIEW_DISPROVE_STOP_SLACK_LINES
knob MAXPRS REVIEW_DISPROVE_STOP_MAX_PRS 1 500 50        # fallback of knob REVIEW_DISPROVE_STOP_MAX_PRS
SEND="${SEND:-$SEND_K}"
# The fix-PR label: main_red_label_resolve (bin/lib/main-red-label.sh, BH-1770)
# reads the one knob lib.main-red-label.mc_main_red_label, then the env, then
# its documented fallback fix-main-red.
LABEL=""
if . "$H/bin/lib/main-red-label.sh" 2>/dev/null && command -v main_red_label_resolve >/dev/null 2>&1; then
  LABEL=$(main_red_label_resolve "$H" 2>/dev/null)
fi
[ -n "$LABEL" ] || LABEL="fix-main-red"
KNOBS="window=${W_D}d dow=$DOW send=$SEND_K max_reads=$MAXR stop_window=${SW}d slack=$SLACK max_prs=$MAXPRS keep=${KEEP}d label=$LABEL${NOTES:+ knob-notes:$NOTES}"

# The report files are rebuilt each run: older than KEEP days they go.
find "$OUT_DIR" -maxdepth 1 -type f -name '20*.json' -mtime +"$KEEP" -delete 2>/dev/null

# jobs-client.sh exits its caller on a missing module, so each piece is checked first.
for f in bin/jobs-client.sh bin/lib/jobs/req.sh bin/lib/gh-rest.sh bin/lib/review-disprove.sh bin/lib/review-disprove-report.sh; do
  [ -r "$H/$f" ] || { log "missing $f; tick skipped $KNOBS"; exit 0; }
done
# shellcheck source=/dev/null
{ . "$H/bin/jobs-client.sh"; . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/review-disprove.sh"; . "$H/bin/lib/review-disprove-report.sh"; }
# shellcheck source=/dev/null
. "$H/bin/lib/gh-app-auth.sh" 2>/dev/null || true
# Not a decision path for the quota: the reserve may refuse any read (rc 75 = unreadable).
export GH_REST_OPTIONAL=1

W=$(mktemp -d "${TMPDIR:-/tmp}/review-disprove-report.XXXXXX") || { log "mktemp failed; run skipped $KNOBS"; exit 0; }
trap 'rm -rf "$W"' EXIT

NOW=$(date -u +%s)
DAY=$(date -u -d "@$NOW" +%F)
TODAY_DOW=$(date -u -d "@$NOW" +%u)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
SINCE_R=$(iso $((NOW - W_D * 86400)))
SINCE_S=$(iso $((NOW - 2 * SW * 86400)))
# One read covers both windows: it starts at the earlier one.
if [ "$((W_D))" -ge "$((2 * SW))" ]; then SINCE_READ="$SINCE_R"; else SINCE_READ="$SINCE_S"; fi
LIMIT=500
LM=$(dp_knob list_max 2>/dev/null) || LM=""                   # settings row review.disprove.list_max (fallback 500)
[[ "$LM" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$LM))" -ge 1 ] && [ "$((10#$LM))" -le 5000 ] && LIMIT=$((10#$LM))

MODE=$(dp_knob mode 2>/dev/null | tr '[:upper:]' '[:lower:]'); MODE="${MODE:-shadow}"
[ "$MODE" = enforce ] || MODE=shadow
HEAD_LINE="Disprove pass (BH-9047, mode $MODE): last ${W_D}d"

RESP=""
RESP=$(JOBS_ALERT=0 _jobs_req GET "/api/review-disprove?since=$SINCE_READ&limit=$LIMIT" 2>/dev/null) || RESP=""
# `[ -n ]` first: jq 1.6 exits 0 on `jq -e` over empty input.
if ! { [ -n "$RESP" ] && printf '%s' "$RESP" | jq -e '(.rows | type) == "array"' >/dev/null 2>&1; }; then
  TEXT="$HEAD_LINE
BLOCK reviews checked: n/a (GET /api/review-disprove was unreadable: worker down or HARNESS_SECRET missing on $(hostname 2>/dev/null))
stop-check: not run (no rows to read)"
  printf '%s\n' "$TEXT" > "$OUT_DIR/latest.txt"
  [ "$PRINT" = 1 ] && printf '%s\n' "$TEXT"
  log "day=$DAY blocks=n/a stop=not-run beat=not-sent $KNOBS"
  exit 0
fi
printf '%s' "$RESP" | jq -c '.rows' > "$W/rows.json"

# Truncated in a window: the answer holds LIMIT rows and its oldest row is
# still inside that window (rows past it may be missing).
NROWS=$(jq length "$W/rows.json")
OLDEST=$(jq -r 'map(.created_at) | min // ""' "$W/rows.json")
trunc_for() { if [ "$NROWS" -ge "$LIMIT" ] && [[ ! "$OLDEST" < "$1" ]]; then echo true; else echo false; fi; }
TR_R=$(trunc_for "$SINCE_R"); TR_S=$(trunc_for "$SINCE_S")

SUMMARY=$(drr_summary "$SINCE_R" "$TR_R" "$W_D" < "$W/rows.json")

# ── part 1b: the next read of each fully disproved BLOCK ─────────────────────
AG=0 DI=0 PE=0 UN=0 CAPN=0 i=0
while IFS= read -r ROW; do
  [ -n "$ROW" ] || continue
  i=$((i + 1))
  if [ "$i" -gt "$MAXR" ]; then CAPN=$((CAPN + 1)); continue; fi
  SLUG=$(jq -r .repo <<<"$ROW")
  command -v gh_default_auth_for_slug >/dev/null 2>&1 && { gh_default_auth_for_slug "$SLUG" >/dev/null 2>&1 || true; }
  case "$(drr_next_read "$SLUG" "$ROW")" in
    agreed-false) AG=$((AG + 1)) ;;
    disagreed) DI=$((DI + 1)) ;;
    pending) PE=$((PE + 1)) ;;
    *) UN=$((UN + 1)) ;;
  esac
done < <(drr_fully "$SINCE_R" < "$W/rows.json")
command -v gh_default_auth_reset >/dev/null 2>&1 && gh_default_auth_reset

# ── part 2: the stop rule ────────────────────────────────────────────────────
GH_N=0 ST_TRUNC=false ST_UN=0 ST_CAND=0 ST_STOP=0 ST_FAIL=0 ST_ENF=""
: > "$W/stopped"; : > "$W/handled"
# gh_get <path> <out> — one counted GitHub read for the stop rule. rc 3 = the
# read cap was hit (nothing sent), else gh_rest's rc.
gh_get() {
  [ "$GH_N" -ge "$MAXPRS" ] && { ST_TRUNC=true; return 3; }
  GH_N=$((GH_N + 1))
  local rc=0; gh_rest GET "$1" > "$2" 2>/dev/null || rc=$?
  return "$rc"
}
# fix_list <slug> — merged PRs with the label, "<number>\t<merged_at>", into
# $W/fix-<slug>; one paged list per repo per run. rc 1 unreadable, 3 cap.
fix_list() {
  local slug="$1" f="$W/fix-${1//\//_}" p=1 rc n last
  [ -f "$f.ok" ] && return 0
  [ -f "$f.bad" ] && return 1
  : > "$f"
  while :; do
    rc=0; gh_get "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$p" "$W/page" || rc=$?
    [ "$rc" = 3 ] && return 3
    { [ "$rc" = 0 ] && jq -e 'type == "array"' "$W/page" >/dev/null 2>&1; } || { : > "$f.bad"; return 1; }
    jq -r --arg l "$LABEL" '.[] | select(.merged_at != null and any(.labels[]?; .name == $l)) | [.number, .merged_at] | @tsv' "$W/page" >> "$f"
    n=$(jq length "$W/page"); last=$(jq -r '.[-1].updated_at // ""' "$W/page")
    if [ "$n" -lt 100 ] || { [ -n "$last" ] && [[ "$last" < "$SINCE_S" ]]; }; then : > "$f.ok"; return 0; fi
    p=$((p + 1))
  done
}
# fix_files <slug> <n> — the PR's file list into $W/files-<n>.json. rc 1 unreadable, 3 cap.
fix_files() {
  local f="$W/files-$2.json" p=1 rc n
  [ -f "$f" ] && return 0
  echo '[]' > "$f.acc"
  while :; do
    rc=0; gh_get "repos/$1/pulls/$2/files?per_page=100&page=$p" "$W/page" || rc=$?
    [ "$rc" = 0 ] || { rm -f "$f.acc"; [ "$rc" = 3 ] && return 3; return 1; }
    jq -e 'type == "array"' "$W/page" >/dev/null 2>&1 || { rm -f "$f.acc"; return 1; }
    jq -s '.[0] + .[1]' "$f.acc" "$W/page" > "$f.acc2" && mv -f "$f.acc2" "$f.acc"
    n=$(jq length "$W/page")
    [ "$n" -lt 100 ] && { mv -f "$f.acc" "$f"; return 0; }
    p=$((p + 1))
    [ "$p" -gt 30 ] && { rm -f "$f.acc"; return 1; }   # 3000 files is GitHub's own cap: a longer list is not complete
  done
}
ts() { [ -n "$1" ] || return 1; date -u -d "$1" +%s 2>/dev/null; }

# do_stop <project> <repo> <pr> <head> <loc> <fix> — the switch-off, in order.
do_stop() {
  local project="$1" repo="$2" pr="$3" head="$4" loc="$5" fix="$6" key note v grc=0 lkey
  key="review.disprove.$project.enabled"
  lkey="$repo#$pr@${head:0:12}:$fix"
  note="BH-9238 stop rule: $repo#$pr merged after an auto-dropped BLOCK at $loc; fix PR #$fix touched those lines within ${SW}d"
  echo "$project" >> "$W/handled"
  if [ "$DRY" = 1 ]; then
    echo "stop-check: would stop $project: $note (dry run: no setting, ledger row or alert written)"
    echo "$project" >> "$W/stopped"; ST_STOP=$((ST_STOP + 1)); return 0
  fi
  if setting_set "$key" 0 "$note" 2>/dev/null && v=$(setting_get "$key" 2>/dev/null) && [ "$(printf '%s' "$v" | tr -d '[:space:]')" = 0 ]; then
    job_ledger_put review_disprove_stop "$lkey" "done" "$note" 2>/dev/null \
      || log "ledger put review_disprove_stop $lkey failed; $project is off, so the next run skips it"
    "$H/bin/lane-alert.sh" --severity critical --id "review-disprove-stop-$project" review-disprove-report \
      "[review-disprove-report] the disprove pass for $project is turned off ($key = 0). $note. Check the finding at $loc before you set $key back to 1." \
      >/dev/null 2>&1 || log "lane-alert failed for $project"
    echo "$project" >> "$W/stopped"; ST_STOP=$((ST_STOP + 1))
    log "stop: $project turned off: $note"
  else
    grc=1
    "$H/bin/lane-alert.sh" --severity critical --id "review-disprove-stop-$project" review-disprove-report \
      "[review-disprove-report] the stop rule fired for $project but could not turn the pass off ($note). Set $key = 0 by hand (bin/harness-ctl.sh or PUT /api/settings)." \
      >/dev/null 2>&1 || log "lane-alert failed for $project"
    ST_FAIL=$((ST_FAIL + 1))
    log "stop: $project could NOT be turned off (setting write or re-read failed): $note"
  fi
  return "$grc"
}

STOP_STATE=""
if [ "$MODE" != enforce ]; then
  STOP_STATE="off (mode $MODE)"
else
  drr_candidates "$SINCE_S" < "$W/rows.json" > "$W/cands.tsv"
  # The projects that gate enforce now; candidates of other projects are dropped.
  for P in $(cut -f6 "$W/cands.tsv" | sort -u); do
    [ "$(dp_gate "$P" 2>/dev/null)" = enforce ] && ST_ENF="$ST_ENF $P"
  done
  awk -F'\t' -v keep="$ST_ENF" 'BEGIN { n = split(keep, a, " "); for (i = 1; i <= n; i++) k[a[i]] = 1 } k[$6]' \
    "$W/cands.tsv" > "$W/cands-enf.tsv"
  ST_CAND=$(cut -f1-3 "$W/cands-enf.tsv" | sort -u | wc -l | tr -d ' ')
  # One candidate = one (repo, pr, head, created_at, project) with its locs.
  while IFS=$'\t' read -r REPO PR HEADSHA CREATED PROJECT; do
    [ -n "$REPO" ] || continue
    grep -qxF "$PROJECT" "$W/handled" && continue
    [ "$ST_TRUNC" = true ] && break
    rc=0; gh_get "repos/$REPO/pulls/$PR" "$W/pull" || rc=$?
    [ "$rc" = 3 ] && break
    if [ "$rc" != 0 ] || ! jq -e 'type == "object"' "$W/pull" >/dev/null 2>&1; then ST_UN=$((ST_UN + 1)); continue; fi
    MERGED=$(jq -r '.merged_at // ""' "$W/pull")
    [ -n "$MERGED" ] || continue
    MS=$(ts "$MERGED"); CS=$(ts "$CREATED")
    [ -n "$MS" ] && [ -n "$CS" ] && [ "$MS" -gt "$CS" ] || continue
    rc=0; fix_list "$REPO" || rc=$?
    [ "$rc" = 3 ] && break
    [ "$rc" = 0 ] || { ST_UN=$((ST_UN + 1)); continue; }
    HIT=0 CUN=0
    while IFS=$'\t' read -r FIX FM; do
      [ -n "$FIX" ] && [ "$FIX" != "$PR" ] || continue
      FS=$(ts "$FM"); [ -n "$FS" ] || continue
      [ "$FS" -ge "$MS" ] && [ "$FS" -le $((MS + SW * 86400)) ] || continue
      LKEY="$REPO#$PR@${HEADSHA:0:12}:$FIX"
      lrc=0; job_ledger_row review_disprove_stop "$LKEY" >/dev/null 2>&1 || lrc=$?
      [ "$lrc" = 0 ] && continue
      [ "$lrc" = 2 ] || { CUN=1; continue; }
      rc=0; fix_files "$REPO" "$FIX" || rc=$?
      [ "$rc" = 3 ] && break
      [ "$rc" = 0 ] || { CUN=1; continue; }
      while IFS=$'\t' read -r LOC; do
        LP="${LOC%:*}"; LR="${LOC##*:}"; LN="${LR%-*}"; LM_="${LR#*-}"
        if drr_file_touch "$W/files-$FIX.json" "$LP" "$LN" "$LM_" "$SLACK"; then
          do_stop "$PROJECT" "$REPO" "$PR" "$HEADSHA" "$LOC" "$FIX"; HIT=1; break
        fi
      done < <(awk -F'\t' -v r="$REPO" -v p="$PR" -v h="$HEADSHA" '$1 == r && $2 == p && $3 == h { print $5 }' "$W/cands-enf.tsv")
      [ "$HIT" = 1 ] && break
    done < <(sort -t$'\t' -k2,2 "$W/fix-${REPO//\//_}")
    [ "$HIT" = 0 ] && [ "$CUN" = 1 ] && ST_UN=$((ST_UN + 1))
  done < <(cut -f1-4,6 "$W/cands-enf.tsv" | awk '!seen[$0]++')
  ENF_LIST=$(printf '%s' "$ST_ENF" | sed 's/^ //'); ENF_LIST="${ENF_LIST:-none}"
  STOP_STATE="enforce on for ${ENF_LIST// /, }; $ST_CAND candidate(s), $ST_STOP stopped, $ST_FAIL failed to stop, $ST_UN unreadable$([ "$ST_TRUNC" = true ] && echo ", truncated at $MAXPRS GitHub reads")"
  [ "$DRY" = 1 ] && STOP_STATE="$STOP_STATE (dry run)"
fi

SUMMARY=$(jq -c --argjson ag "$AG" --argjson di "$DI" --argjson pe "$PE" --argjson un "$UN" --argjson cap "$CAPN" \
  --arg mode "$MODE" --arg day "$DAY" --arg ss "$STOP_STATE" --argjson cand "$ST_CAND" --argjson stp "$ST_STOP" \
  --argjson fl "$ST_FAIL" --argjson sun "$ST_UN" --argjson st "$ST_TRUNC" --argjson srt "$TR_S" --argjson dry "$DRY" \
  '. + {day: $day, mode: $mode,
        next_read: {agreed_false: $ag, disagreed: $di, pending: $pe, unreadable: $un, not_read_cap: $cap},
        stop: {state: $ss, candidates: $cand, stopped: $stp, failed: $fl, unreadable: $sun,
               truncated: ($st or $srt), dry_run: ($dry == 1)}}' <<<"$SUMMARY")

TEXT=$(jq -r --arg head "$HEAD_LINE" --arg maxr "$MAXR" '
  def frac(p): "\(p.fully_disproved) of \(p.blocks) (\(if p.share == null then "n/a" else "\(p.share)%" end))";
  $head,
  "BLOCK reviews checked: \(.total.blocks) (lead \(.lead.blocks), conductor \(.conductor.blocks))\(if .truncated then " (truncated: the read hit its row limit)" else "" end)",
  "fully disproved \(frac(.total)); lead \(frac(.lead)), conductor \(frac(.conductor))",
  "next read of the fully disproved: \(.next_read.agreed_false) agreed false, \(.next_read.disagreed) disagreed, \(.next_read.pending) pending, \(.next_read.unreadable) unreadable\(if .next_read.not_read_cap > 0 then ", \(.next_read.not_read_cap) not read (cap \($maxr))" else "" end)",
  "findings: \(.total.confirmed) confirmed, \(.total.disproved) disproved, \(.total.kept) kept (protected), \(.total.unchecked) unchecked; cost \(if .total.cost_usd == null then "n/a" else "\(.total.cost_usd * 100 | round / 100) USD" end)",
  "stop-check: \(.stop.state)\(if .stop.truncated and (.stop.state | test("truncated") | not) and (.stop.state | startswith("off") | not) then ", truncated: the read hit its row limit" else "" end)"' <<<"$SUMMARY")

printf '%s\n' "$TEXT" > "$OUT_DIR/latest.txt"
printf '%s\n' "$SUMMARY" > "$OUT_DIR/$DAY.json"
[ "$PRINT" = 1 ] && printf '%s\n' "$TEXT"

SENT=not-sent
BLOCKS=$(jq -r .total.blocks <<<"$SUMMARY")
if [ "$SEND" = 1 ] && [ "$BLOCKS" != 0 ] && { [ "$NOW_BEAT" = 1 ] || [ "$TODAY_DOW" = "$DOW" ]; } && [ -x "$H/bin/beat.sh" ]; then
  if "$H/bin/beat.sh" "$(jq -nc --arg akey "review-disprove-report:$DAY" --arg l "$TEXT" \
      '{kind:"fleet_alert",project:"fleet",triaged:true,akey:$akey,line:$l}')" >/dev/null 2>&1; then SENT=sent
  else SENT=failed; fi
fi
log "day=$DAY mode=$MODE blocks=$BLOCKS fully=$(jq -r .total.fully_disproved <<<"$SUMMARY") share=$(jq -r '.total.share // "n/a"' <<<"$SUMMARY") next=$AG/$DI/$PE/$UN cap=$CAPN stop=[$STOP_STATE] beat=$SENT $KNOBS"
exit 0
