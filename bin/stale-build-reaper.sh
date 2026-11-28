#!/bin/bash
# bin/stale-build-reaper.sh — mark a dead build dead within the hour (BH-9484,
# items 4 and 7 of #9406).
#
#   stale-build-reaper.sh [--dry-run] [--minutes N] [--now EPOCH]
#
# --now pins the clock in epoch seconds (a test or a replay); default the real clock.
#
# WHY THIS EXISTS. bin/sweep-stale-builds.sh closes abandoned console build rows
# once a day, after 24 hours. A build that died in planning or executing reads
# as "building" for that whole day: the ticket looks owned, and its running job
# row keeps its file claim. This lane asks the same question every 10 minutes,
# with a threshold of STALE_REAPER_MINUTES (default 60).
#
# A ROW IS DEAD when all of these are true:
#   - the console row is in stage `planning` or `executing`, and its updated_at
#     is at least STALE_REAPER_MINUTES old;
#   - no build_queue row of (project, key) is `queued` or `claimed`;
#   - no live machine row carries (project, key) (with fly_machines_rows on), or
#     no pool file on this box does (flag off);
#   - no build dir on this box changed inside the window;
#   - no running job row of (project, key), of any kind, had activity inside the
#     window. This fourth source is stricter than the sweep: a build on another
#     box can beat its job row while its console row is quiet.
#
# FAIL CLOSED, the sweep's rule. If the feed or any evidence source cannot be
# read, or a read comes back as a full page, the live set is UNKNOWN. The tick
# makes 0 changes and exits 3. The first refusal of an outage writes ONE alert
# line and the latch state/stale-build-reaper/evidence-down; later refusals log
# only. The first complete read removes the latch. Every source is read on
# every tick, also when the feed is empty, so the latch always clears.
#
# OBSERVE FIRST (item 7). Unless STALE_REAPER_ACT is exactly 1, the lane writes
# one `OBSERVE would reap` line per dead row and changes nothing. With the PR
# step on (STALE_REAPER_OPEN_PR=1, the default), the line ends ` pr=<outcome>`:
# what act mode would do about the build's branch (`would-open <br> ...`,
# `none ...`, `unknown ...`), from at most 3 GitHub REST reads per dead row.
# STALE_REAPER_OPEN_PR=0 is ` pr=off` and no GitHub read.
#
# ACT, per dead row, up to STALE_REAPER_MAX per tick (the rest are DEFERRED to
# the next tick, never dropped):
#   a. close each running `build` job row of (project, key) that was quiet for
#      the whole window: job_update <id> status=failed. That frees its claim
#      (GET /api/file-claims counts a claim only while its job is running).
#   b. the PR step (item 5, bin/lib/stale-build-pr.sh, in a subshell): when
#      the newest ticket/<key>[-rN] branch holds finished commits, no PR in any
#      state, and a tip newer than the build start, open the PR from it through
#      the item 3 path (pool rebase when behind main, lead review, pr_created
#      beat). An opened PR skips step c: the pr_created beat moves the console
#      row, and one alert and one REAPED line name the PR.
#   c. POST /api/builds/close {"closed":[bkey]}: the console sets stage=stale.
#   d. only after ok:true: one alert line and one REAPED log line (both carry
#      the PR step's outcome). A refused POST is one REFUSED line; one alert
#      per tick names the refused count.
# The PR step never changes the exit code. PR steps per tick are capped at
# STALE_REAPER_MAX in both modes.
#
# EXIT CODES. The cron line sends output to /dev/null; the alert line is the
# operator signal. The rc is for a human or a test running it directly.
#   0  clean, observe, or a no-op: no console env, lock held, lane off,
#      0 candidates
#   1  usage: an unknown argument
#   3  a fail-closed refusal: the feed or an evidence source unreadable, a full
#      page, or no bin/jobs-client.sh. 0 POSTs, 0 PATCHes.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165). Off switch: bin/harness-ctl.sh off stale-build-reaper.
# lane_env_apply puts this lane's settings rows (catalog/lanes.d/stale-build-reaper.json)
# into the environment the ${KNOB:-default} reads below use. Both fail open.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit stale-build-reaper
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    stale-build-reaper

LOG="$HARNESS/logs/stale-build-reaper.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { mkdir -p "$HARNESS/logs"; echo "$(STAMP) [reaper] $*" >> "$LOG"; }
alert() { bash "$HARNESS/bin/alert-line.sh" "$@" >/dev/null 2>&1 || true; }

# knob <NAME> <default> <min> — a positive integer >= min, else the default
# with one log line.
knob() {
  local n="$1" d="$2" lo="$3" v
  v="${!n:-$d}"
  case "$v" in ''|*[!0-9]*) say "knob $n=\"$v\" is not a positive integer, using $d"; v="$d" ;; esac
  if [ "$v" -lt "$lo" ]; then say "knob $n=$v is under $lo, using $d"; v="$d"; fi
  printf '%s' "$v"
}

DRY=0; ARG_MIN=""; ARG_NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --minutes) ARG_MIN="${2:-}"; shift ;;
    --now) ARG_NOW="${2:-}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done
# shellcheck disable=SC2034  # read through ${!n} in knob()
[ -n "$ARG_MIN" ] && STALE_REAPER_MINUTES="$ARG_MIN"

# Settings rows, lane stale-build-reaper (catalog/lanes.d/stale-build-reaper.json).
# Each literal is the documented fallback of its row.
ACT=0; [ "${STALE_REAPER_ACT:-0}" = 1 ] && [ "$DRY" = 0 ] && ACT=1   # row STALE_REAPER_ACT, default 0 (observe)
MINUTES=$(knob STALE_REAPER_MINUTES 60 60)                          # row STALE_REAPER_MINUTES, default 60
MAX=$(knob STALE_REAPER_MAX 20 1)                                   # row STALE_REAPER_MAX, default 20
HTTP_T=$(knob STALE_REAPER_HTTP_TIMEOUT_S 60 1)                     # row STALE_REAPER_HTTP_TIMEOUT_S, default 60
PAGE=$(knob STALE_REAPER_PAGE 500 1)                                # row STALE_REAPER_PAGE, default 500 (worker cap)
COUNT_TTL=$(knob STALE_REAPER_COUNT_TTL_MIN 30 0)                   # row STALE_REAPER_COUNT_TTL_MIN, default 30; 0 = do not publish (BH-10119)
[ "$PAGE" -le 500 ] || { say "knob STALE_REAPER_PAGE=$PAGE is over the worker cap 500, using 500"; PAGE=500; }
WIN_S=$((MINUTES * 60))
HOURS=$((MINUTES / 60))
MODE=observe; [ "$ACT" = 1 ] && MODE=act

[ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || { say "no CONSOLE_URL/HARNESS_SECRET, not running"; exit 0; }
mkdir -p "$HARNESS/locks" 2>/dev/null
exec 9>"$HARNESS/locks/stale-build-reaper.lock" 2>/dev/null || true
flock -n 9 2>/dev/null || { say "another reaper tick is running"; exit 0; }

LATCH_DIR="$HARNESS/state/stale-build-reaper"
LATCH="$LATCH_DIR/evidence-down"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/stale-build-reaper.XXXXXX") || { say "mktemp failed, not running"; exit 3; }
trap 'rm -rf "$WORK"' EXIT
LIVE="$WORK/live"; STALEJ="$WORK/stale-jobs"; : > "$LIVE"; : > "$STALEJ"

# refuse <why> — fail closed: 0 changes, one alert per outage, rc 3.
refuse() {
  say "REFUSING: $1 — the live set is UNKNOWN, 0 changes this tick"
  if [ -f "$LATCH" ]; then
    say "evidence outage already alerted (latch $LATCH), no new alert"
  else
    alert --id stale-build-reaper.evidence "[stale-build-reaper] $1, reaper tick skipped (0 changes) — see logs/stale-build-reaper.log"
    mkdir -p "$LATCH_DIR" 2>/dev/null && : > "$LATCH"
  fi
  exit 3
}

# ---------- 1. the feed ----------
FEED=$(curl -sS --max-time "$HTTP_T" -H "Authorization: Bearer $HARNESS_SECRET" \
  "$CONSOLE_URL/api/builds/stale?hours=$HOURS" 2>&1)
jq -e '.builds | type == "array"' >/dev/null 2>&1 <<<"$FEED" \
  || refuse "stale-build feed unreadable (body: $(head -c 200 <<<"$FEED" | tr '\n' ' '))"

# ---------- 2. the live set: 4 sources, as <project>\t<key> ----------
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
command -v queue_list >/dev/null 2>&1 || refuse "no bin/jobs-client.sh on this box (queue evidence unknown)"
# The PR step (item 5). A static source line, so the scratch closure finds it.
# shellcheck source=bin/lib/stale-build-pr.sh
. "$HARNESS/bin/lib/stale-build-pr.sh" 2>/dev/null
OPEN_PR=0; [ "${STALE_REAPER_OPEN_PR:-1}" = 1 ] && OPEN_PR=1   # row STALE_REAPER_OPEN_PR, default 1; only 1 is on
if [ "$OPEN_PR" = 1 ] && ! command -v sbp_open >/dev/null 2>&1; then
  OPEN_PR=0; say "PR step off: bin/lib/stale-build-pr.sh is missing"
fi
SBP_TIMEOUT_S="$HTTP_T"   # each GitHub read of the PR step, row STALE_REAPER_HTTP_TIMEOUT_S
PRSTEPS=0

# pr_step <observe|act> <bkey> <project> <key> <stage> — prints the PR step's
# one outcome line. ALWAYS a subshell: the ppr globals, the GitHub token and an
# `exit` inside a sourced lib stay out of this script. TMPDIR=$WORK, so the
# step's scratch dir goes with the EXIT trap.
pr_step() {
  local out="$WORK/sbp.out"
  : > "$out"
  if [ "$1" = act ]; then
    ( TMPDIR="$WORK"; sbp_open "$3" "$4" "$5" "$2" "$out" ) </dev/null >/dev/null 2>&1
  else
    ( TMPDIR="$WORK"; sbp_decide "$3" "$4" "$2"; printf '%s\n' "$SBP_OUT" > "$out" ) </dev/null >/dev/null 2>&1
  fi
  if [ -s "$out" ]; then head -n 1 "$out" | tr -d '\r'; else printf 'failed the PR step ended with no outcome\n'; fi
}
# pr_outcome <observe|act> <bkey> <project> <key> <stage> — the capped PR step.
# Sets PR in THIS shell (a $(...) would lose the PRSTEPS count).
pr_outcome() {
  if [ "$OPEN_PR" != 1 ]; then PR=off; return 0; fi
  if [ "$PRSTEPS" -ge "$MAX" ]; then PR='not-read (over STALE_REAPER_MAX)'; return 0; fi
  PRSTEPS=$((PRSTEPS+1))
  PR=$(pr_step "$@")
}

# 2a. build_queue rows, queued and claimed. A full page may be truncated.
for QST in queued claimed; do
  QROWS=$(queue_list "" "$QST" "" "" "$PAGE" 2>/dev/null) || refuse "build_queue read failed for status=$QST"
  N=$(printf '%s\n' "$QROWS" | grep -c . || true)
  [ "${N:-0}" -lt "$PAGE" ] || refuse "build_queue status=$QST returned a full page ($N of $PAGE)"
  printf '%s\n' "$QROWS" | awk -F'\t' 'NF>=2 && $1 != "" && $2 != "" { printf "K\t%s\t%s\n", $1, $2 }' >> "$LIVE"
done

# 2b. the machines rows (flag on), or this box's pool files (flag off, 2c).
POOL_FILES=1
if command -v machines_rows_on >/dev/null 2>&1 && machines_rows_on; then
  POOL_FILES=0
  MROWS=$(machines_list "" live 2>/dev/null) || refuse "machines rows unreadable"
  N=$(printf '%s\n' "$MROWS" | grep -c . || true)
  [ "${N:-0}" -lt "$PAGE" ] || refuse "machines rows returned a full page ($N of $PAGE)"
  # machines_list TSV: machine_id project app role key ...
  printf '%s\n' "$MROWS" | awk -F'\t' 'NF>=5 && $2 != "" && $5 != "" { printf "K\t%s\t%s\n", $2, $5 }' >> "$LIVE"
fi

# 2c. this box's files (queue and pool files here, build dirs just below). The queue and pool globs appear only in the for word
# lists, never in an assignment (bin/state-paths-guard.sh, comment 6881818946).
emit_json_keys() { # emit_json_keys <dir/> — K records from <dir>/*.json
  local D="$1" P F
  [ -d "$D" ] || return 0
  P=$(basename "$D")
  for F in "$D"*.json; do
    [ -f "$F" ] || continue
    jq -r --arg p "$P" 'select(type=="object") | ["K", $p, (.key // "")] | @tsv' "$F" 2>/dev/null
  done
}
{
  for D in "$HARNESS"/state/build-queue/*/; do emit_json_keys "$D"; done
  if [ "$POOL_FILES" = 1 ]; then
    for D in "$HARNESS"/state/fly-pool/*/; do emit_json_keys "$D"; done
  fi
} >> "$LIVE"
# Build dirs changed inside the window, by name (matched per candidate below).
DIRS="$WORK/dirs"
find "$HARNESS/builds" -maxdepth 1 -mindepth 1 -type d -mmin "-$MINUTES" 2>/dev/null \
  | while read -r B; do basename "$B"; done > "$DIRS"

# 2d. running job rows. Fresh activity of any kind holds (project, key); a quiet
# `build` row is a claim to free in act mode.
# job_rows TSV: id project kind stage box ticket_id activity_age_s ...
JROWS=$(job_rows running "$PAGE" 2>/dev/null) || refuse "running job rows unreadable"
N=$(printf '%s\n' "$JROWS" | grep -c . || true)
[ "${N:-0}" -lt "$PAGE" ] || refuse "running job rows returned a full page ($N of $PAGE)"
printf '%s\n' "$JROWS" | awk -F'\t' -v w="$WIN_S" -v sj="$STALEJ" '
  NF>=7 && $2 != "" && $6 != "" && $6 != "-" {
    if (($7 + 0) < w) printf "K\t%s\t%s\n", $2, $6
    else if ($3 == "build") printf "%s\t%s\t%s\n", $2, $6, $1 >> sj
  }' >> "$LIVE"

awk -F'\t' '$1 == "K" && $2 != "" && $3 != "" { printf "%s\t%s\n", $2, $3 }' "$LIVE" | sort -u > "$LIVE.k"
mv -f "$LIVE.k" "$LIVE"

# dir_live <project> <key> — rc 0 when a fresh build dir is <p>-<key>-<ts>
# (or pool-/fly- prefixed), <ts> holding no hyphen. Matched on the exact
# (project, key), so a project name that is a prefix of another cannot steal it.
dir_live() {
  local b pre r
  while IFS= read -r b; do
    for pre in "$1-$2-" "pool-$1-$2-" "fly-$1-$2-"; do
      case "$b" in
        "$pre"*) r="${b#"$pre"}"; case "$r" in ''|*-*) ;; *) return 0 ;; esac ;;
      esac
    done
  done < "$DIRS"
  return 1
}

# A complete read: the outage, if any, is over.
if [ -f "$LATCH" ]; then rm -f "$LATCH"; say "evidence readable again, latch removed"; fi

# ---------- 3. candidates and the subtraction ----------
NOW="$ARG_NOW"; case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac   # --now, else the real clock
CAND=0; HELD=0; SKIPPED=0; REAPED=0; DEFERRED=0; REFUSED=0; OPENED=0
SURV="$WORK/survivors"; : > "$SURV"
# Unit separator, not tab: a tab IFS collapses an empty field (an empty bkey
# would shift every field after it).
while IFS=$'\x1f' read -r BKEY PROJ TKEY STAGE UPD; do
  case "$STAGE" in planning|executing) ;; *) continue ;; esac
  if [ -z "$BKEY" ] || [ -z "$TKEY" ] || [ -z "$PROJ" ]; then
    say "SKIP empty bkey/project/ticket_key (bkey=$BKEY project=$PROJ ticket=$TKEY)"; SKIPPED=$((SKIPPED+1)); continue
  fi
  # An empty value is never handed to date -d (GNU answers today 00:00Z for "").
  case "$UPD" in
    '') TS="" ;;
    *[!0-9]*) TS=$(date -u -d "$UPD" +%s 2>/dev/null) || TS="" ;;
    *) TS="$UPD" ;;
  esac
  if [ -z "$TS" ]; then
    say "SKIP unparsable updated_at $BKEY ($PROJ $TKEY) updated_at=$UPD"; SKIPPED=$((SKIPPED+1)); continue
  fi
  AGE_S=$((NOW - TS))
  [ "$AGE_S" -ge "$WIN_S" ] || continue
  CAND=$((CAND+1))
  if grep -qxF "$(printf '%s\t%s' "$PROJ" "$TKEY")" "$LIVE" || dir_live "$PROJ" "$TKEY"; then
    say "HOLD $BKEY ($PROJ $TKEY) — still live"; HELD=$((HELD+1)); continue
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$BKEY" "$PROJ" "$TKEY" "$STAGE" "$UPD" "$((AGE_S / 60))" >> "$SURV"
done < <(jq -r '.builds[] | [(.bkey // ""), (.project // ""), (.ticket_key // ""), (.stage // ""), (.updated_at // "" | tostring)]
               | map(gsub("[\u001f\n]"; " ")) | join("\u001f")' <<<"$FEED")

[ "$CAND" -gt 0 ] || say "feed returned 0 candidates older than ${MINUTES}m in planning/executing — nothing reaped"

# ---------- 4. observe or act ----------
while IFS=$'\t' read -r BKEY PROJ TKEY STAGE UPD AGE_M; do
  [ -n "$BKEY" ] || continue
  if [ "$ACT" != 1 ]; then
    pr_outcome observe "$BKEY" "$PROJ" "$TKEY" "$STAGE"
    say "OBSERVE would reap $BKEY project=$PROJ ticket=$TKEY stage=$STAGE updated_at=$UPD age_min=$AGE_M pr=$PR"
    continue
  fi
  if [ $((REAPED + REFUSED)) -ge "$MAX" ]; then   # the cap counts close POSTs
    say "DEFERRED $BKEY ($PROJ $TKEY) — over STALE_REAPER_MAX=$MAX this tick, next tick"; DEFERRED=$((DEFERRED+1)); continue
  fi
  # a. free the claim through its authority, the job row
  CLAIM=""
  while IFS=$'\t' read -r JP JK JID; do
    [ "$JP" = "$PROJ" ] && [ "$JK" = "$TKEY" ] && [ -n "$JID" ] || continue
    if job_update "$JID" status=failed "meta=STALE_REAPED $BKEY age_min=$AGE_M" >/dev/null 2>&1; then
      CLAIM="${CLAIM:+$CLAIM, }claim released job=$JID"
    else
      CLAIM="${CLAIM:+$CLAIM, }claim left job=$JID to bin/jobs-watchdog.sh"
    fi
  done < "$STALEJ"
  CLAIM="${CLAIM:-claim none}"
  # b. the PR step. Opened: no close POST (the pr_created beat moves the row;
  #    a close would set it stale), one alert, one REAPED line.
  pr_outcome act "$BKEY" "$PROJ" "$TKEY" "$STAGE"
  case "$PR" in
    "opened "*)
      PURL="${PR#opened }"; PURL="${PURL%% *}"
      PRB=$(sed -n 's/.* \(rebase=[^ ]*\).*/\1/p' <<<"$PR"); PRV=$(sed -n 's/.* \(review=[^ ]*\).*/\1/p' <<<"$PR")
      alert --id "stale-build-reaper.$PROJ.$TKEY" --project "$PROJ" \
        "[stale-build-reaper] $PROJ $TKEY: build $BKEY died in $STAGE (${AGE_M} min quiet); opened $PURL from its branch (${PRB:-rebase=none}, ${PRV:-review=none}); $CLAIM"
      say "REAPED $BKEY project=$PROJ ticket=$TKEY was_stage=$STAGE updated_at=$UPD age_min=$AGE_M $CLAIM pr=$PR"
      REAPED=$((REAPED+1)); OPENED=$((OPENED+1))
      continue ;;
  esac
  # c. mark dead
  BODY=$(jq -nc --arg b "$BKEY" '{closed: [$b]}')
  RESP=$(curl -sS --max-time "$HTTP_T" -X POST -H "Authorization: Bearer $HARNESS_SECRET" \
    -H 'Content-Type: application/json' -d "$BODY" "$CONSOLE_URL/api/builds/close" 2>&1)
  if jq -e '.ok == true' >/dev/null 2>&1 <<<"$RESP"; then
    # d. one alert, only after the console said ok
    alert --id "stale-build-reaper.$PROJ.$TKEY" --project "$PROJ" \
      "[stale-build-reaper] $PROJ $TKEY: build $BKEY marked dead (stage=$STAGE, ${AGE_M} min quiet; no queue row, no machine, no fresh job, no fresh build dir; $CLAIM); PR: $PR"
    say "REAPED $BKEY project=$PROJ ticket=$TKEY was_stage=$STAGE updated_at=$UPD age_min=$AGE_M $CLAIM pr=$PR"
    REAPED=$((REAPED+1))
  else
    say "REFUSED $BKEY ($PROJ $TKEY) by the console: $(head -c 200 <<<"$RESP" | tr '\n' ' ') ($CLAIM) pr=$PR"
    REFUSED=$((REFUSED+1))
  fi
done < "$SURV"

# ---------- 5. publish the dead count (BH-10119) ----------
# The kanban's `building_stale` reads this row (console-ui/functions/_lib/
# stale-overlay.js) while now <= valid_until. Only a complete tick reaches
# here: a refuse() exited above, so an unknown live set publishes nothing and
# the old row expires. A reaped row has left the build stage; a DEFERRED or
# REFUSED row still counts. A failed PUT logs one line and changes no rc.
if [ "$COUNT_TTL" -eq 0 ]; then
  say "count publish off (STALE_REAPER_COUNT_TTL_MIN=0)"
else
  NSURV=$(grep -c . "$SURV" || true)
  LEFT=$(( ${NSURV:-0} - REAPED )); [ "$LEFT" -ge 0 ] || LEFT=0
  AT=$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)
  VALID_UNTIL=$(date -u -d "@$((NOW + COUNT_TTL * 60))" +%Y-%m-%dT%H:%M:%SZ)
  DETAIL=$(jq -nc --argjson s "$LEFT" --argjson h "$HELD" --argjson c "$CAND" --argjson w "$MINUTES" \
    --arg m "$MODE" --arg at "$AT" --arg vu "$VALID_UNTIL" \
    '{stale:$s, held:$h, candidates:$c, window_min:$w, mode:$m, at:$at, valid_until:$vu}')
  if job_ledger_put building_stale fleet "$LEFT" "$DETAIL" >/dev/null 2>&1; then
    say "count published stale=$LEFT held=$HELD valid_until=$VALID_UNTIL"
  else
    say "count publish failed (jobs worker), the row expires at its valid_until"
  fi
fi

[ "$REFUSED" -eq 0 ] || alert --id stale-build-reaper.refused \
  "[stale-build-reaper] the console refused $REFUSED build close(s) this tick — see logs/stale-build-reaper.log"
say "mode=$MODE candidates=$CAND held=$HELD skipped=$SKIPPED reaped=$REAPED deferred=$DEFERRED refused=$REFUSED opened=$OPENED"
exit 0
