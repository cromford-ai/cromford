#!/bin/bash
# gh-identity: app-token
# gh-rest: no-graphql
# bin/lane-move.sh — BH-7252 C1 (part of #7252): move a hub lane's project runs
# to Fly lane-run after proof gates, check the hour after the move against the
# hour before, and move the lane back to the hub when the counts do not hold.
# Hub only, every 10 min behind bin/hub-lease.sh check
# (cron/lanes/736-lane-move.cron). No LLM call, no paid call.
#
# One pass over each module bin/lib/lane-move/<lane>.sh, found by filename (a
# later lane adds one module file and edits no list). The module contract is
# in bin/lib/lane-move/pipeline-health.sh. Each lane has a state file
# state/lane-move/<lane>; line 1 is one of
#   waiting <n> <why> | held <ts> <why> | flipped <epoch> load5=<x> [found] |
#   verified <ts> | rolled-back <ts> <why> | killed <ts> <actor> | gave-up <ts> <why>
# and line 2, after a verdict, is `post-attempts <n>`, `posted <ts> [found]`
# or `posted gave-up`. held, gave-up and a verdict with `posted` are terminal:
# a run reads the file and stops.
#
# Before the flip, in order (the first gate that fails stops the run):
#   g1  GET /api/settings/lane_placement.<lane>. `fly` (any actor): an
#       operator flipped it: state `flipped <updated_at> ... found`. `hub` by
#       actor `seed`: go on. Any other value or actor: `held` (an operator
#       chose; never overwritten). No row or no answer: `waiting`.
#   g2  a lane_placement.<lane>.hub_only row: `held`.
#   g3  GET /api/lane-runs/stats: the lane-run fleet has done work (sum of
#       done > 0), else `waiting no-fleet`.
#   g4  logs/lane-snapshot-publish.log has a `; <lane> placed` line at most
#       1800 s old (the hub publishes this lane's snapshots), else
#       `waiting no-publisher`.
#   g5  the module counts at least 1 finished run in [now-3600, now), else
#       `waiting lane-idle`. The counts go to state/lane-move/<lane>.before.tsv.
# Then setting_set lane_placement.<lane> fly; the state is `flipped` only
# after it returns rc 0 (else `waiting put-failed`). A wait counts runs; the
# LANE_MOVE_WAIT_MAX-th writes `gave-up` and one log-only lane-alert line.
#
# The check, at flip + LANE_MOVE_VERIFY_AFTER_S or later, over the after
# window [flip+1200, flip+4800):
#   - the row is not `fly` any more: `killed <ts> <actor>` (the kill row);
#   - else PASS when, for each project of before.tsv, after >= before - 1 and
#     at least one lane_runs row of exactly that project finished `done` in
#     the window; failed + died rows <= lane_move.<lane>.fail_max (default 0);
#     the window has at least one publisher line for the lane, with 0
#     conflicts and 0 failed. PASS: `verified`. FAIL: setting_set
#     lane_placement.<lane> hub, then `rolled-back` and one lane-alert warn
#     (--id lane-move-<lane>). A failed hub write leaves `flipped`, logs
#     rollback-failed, and the next run tries again.
# The report (state/lane-move/<lane>.report.md) is posted ONCE as an App
# comment on issue lane_move.<lane>.issue (default 7252); its last line is the
# marker <!-- lane-move:<lane>:<flip epoch> -->, and a comment that already
# holds it counts as posted. 6 failed posts write `posted gave-up` and one
# log-only lane-alert line.
#
# Kill row (no deploy): bin/jobs-client.sh setting-set lane_placement.<lane> hub
#
# Log line (logs/lane-move.log), exit 0 on every path:
#   <ts> lane=<lane|all> step=<waiting|held|flipped|found|verified|rolled-back|
#   rollback-failed|killed|posted|post-failed|gave-up|skipped (running)|
#   not-configured> why=<...>
#
# Test seams, read only under HARNESS_TEST_SANDBOX=1: LANE_MOVE_GH_LIB (a file
# that defines the GitHub functions; without it a sandbox run is
# not-configured), LANE_MOVE_NOW (epoch), LANE_MOVE_LOADAVG (a file read
# instead of /proc/loadavg), LANE_MOVE_MODULE_DIR.
#
# OFF: flags/lane-off-lane-move (bin/harness-ctl.sh off lane-move).
# Doc: docs/notes/2026-10-17-BH-7252-pipeline-health-move.md.
set -uo pipefail
export LC_ALL=C
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
SANDBOX=0; [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && SANDBOX=1

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lane-move
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lane-move

STAMP=$(date -u +%FT%TZ)
NOW=$(date -u +%s)
[ "$SANDBOX" = 1 ] && [[ "${LANE_MOVE_NOW:-}" =~ ^[0-9]{9,11}$ ]] && NOW=$LANE_MOVE_NOW
LOG="$H/logs/lane-move.log"
DIR_M="$H/state/lane-move"
MOD_DIR="$SELF/lib/lane-move"
[ "$SANDBOX" = 1 ] && [ -n "${LANE_MOVE_MODULE_DIR:-}" ] && MOD_DIR=$LANE_MOVE_MODULE_DIR
LOADAVG=/proc/loadavg
[ "$SANDBOX" = 1 ] && [ -n "${LANE_MOVE_LOADAVG:-}" ] && LOADAVG=$LANE_MOVE_LOADAVG
PUBLOG="$H/logs/lane-snapshot-publish.log"

# knob <value> <default> <min> <max> — the value when it is a whole number in
# range, else the default.
knob() {
  if [[ "$1" =~ ^[0-9]{1,6}$ ]] && [ "$((10#$1))" -ge "$3" ] && [ "$((10#$1))" -le "$4" ]; then
    printf '%s' "$((10#$1))"
  else printf '%s' "$2"; fi
}
VERIFY_AFTER=$(knob "${LANE_MOVE_VERIFY_AFTER_S:-5400}" 5400 4800 86400)
WAIT_MAX=$(knob "${LANE_MOVE_WAIT_MAX:-36}" 36 1 1000)
POST_MAX=6
BEFORE_S=3600; AFTER_FROM=1200; AFTER_TO=4800; FRESH_S=1800
ISSUE_DEFAULT=7252

out() { printf '%s lane=%s step=%s why=%s\n' "$STAMP" "$1" "$2" "${3:--}" >> "$LOG"; }

mkdir -p "$H/logs" "$H/locks" "$DIR_M" 2>/dev/null
exec 7> "$H/locks/lane-move.lock" 2>/dev/null || { out all "skipped (no lock file)"; exit 0; }
flock -n 7 || { out all "skipped (running)"; exit 0; }

# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" 2>/dev/null || true
# shellcheck source=bin/lib/lane-placement.sh
. "$SELF/lib/lane-placement.sh" 2>/dev/null || true
if [ "$SANDBOX" = 1 ]; then
  # shellcheck disable=SC1090
  [ -n "${LANE_MOVE_GH_LIB:-}" ] && [ -r "$LANE_MOVE_GH_LIB" ] && . "$LANE_MOVE_GH_LIB"
else
  # shellcheck source=bin/lib/deployment.sh
  . "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" 2>/dev/null || true
  # shellcheck source=bin/lib/gh-rest.sh
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  # shellcheck source=bin/lib/gh-rest-list.sh
  . "$SELF/lib/gh-rest-list.sh" 2>/dev/null || true
  # shellcheck source=bin/lib/gh-app-auth.sh
  . "$SELF/lib/gh-app-auth.sh" 2>/dev/null || true
fi
SLUG="${HARNESS_REPO:-}"
for f in _jobs_req setting_get setting_set _setting_key_ok lp_hub_only_reason \
         gh_auth_for gh_rest_issue_comments gh_rest_comment; do
  command -v "$f" >/dev/null 2>&1 || SLUG=""
done
[ -n "${JOBS_URL:+u}" ] && [ -n "${HARNESS_SECRET:+s}" ] || SLUG=""
[ -n "$SLUG" ] || { out all not-configured; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/lmv.XXXXXX") || { out all "skipped (mktemp)"; exit 0; }
trap 'command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset; rm -rf "$TMP"' EXIT

ts_of()  { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
iso_of() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
load5() {
  local a="" b="" rest
  read -r a b rest < "$LOADAVG" 2>/dev/null || true
  [[ "$b" =~ ^[0-9]+(\.[0-9]+)?$ ]] || b=NA
  printf '%s' "$b"
}

# row_read <key> — ROW_RAW, ROW_V (trimmed, lowercased), ROW_ACTOR, ROW_AT.
# rc 0 = a row, 2 = no row, 1 = no answer.
row_read() {
  local resp
  ROW_RAW=""; ROW_V=""; ROW_ACTOR=""; ROW_AT=""
  resp=$(_jobs_req GET "/api/settings/$1") || return 1
  jq -e 'type == "object" and has("setting")' >/dev/null 2>&1 <<<"$resp" || return 1
  jq -e '.setting == null' >/dev/null 2>&1 <<<"$resp" && return 2
  ROW_RAW=$(jq -r '.setting.value // ""' <<<"$resp")
  ROW_ACTOR=$(jq -r '.setting.actor // ""' <<<"$resp" | tr -d '[:space:]')
  ROW_AT=$(jq -r '.setting.updated_at // ""' <<<"$resp")
  ROW_V=$(printf '%s' "$ROW_RAW" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
  return 0
}

# lm_tick — one lane, in the module's subshell (LM_LANE and its functions set).
lm_tick() {
  local lane="$LM_LANE" s st before report l1="" l2="" w1 rest
  s=${lane//-/_}
  st="$DIR_M/$lane"; before="$DIR_M/$lane.before.tsv"; report="$DIR_M/$lane.report.md"
  { IFS= read -r l1; IFS= read -r l2; } < "$st" 2>/dev/null
  w1=${l1%% *}; rest=${l1#* }
  # state <line1> [line2] — the state file, tmp + mv.
  state() { { printf '%s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2"; } > "$st.tmp" && mv -f "$st.tmp" "$st"; }
  case "$w1" in
    held|gave-up) out "$lane" "$w1" terminal; return 0 ;;
    verified|rolled-back|killed)
      case "$l2" in posted*) out "$lane" "$w1" terminal; return 0 ;; esac
      lm_post; return 0 ;;
    flipped) lm_verify; return 0 ;;
    waiting) WAITN=${rest%% *}; [[ "$WAITN" =~ ^[0-9]+$ ]] || WAITN=0 ;;
    *) WAITN=0 ;;
  esac
  lm_preflip
}

# wait_on <why> — one more wait; the WAIT_MAX-th gives up.
wait_on() {
  local n=$((WAITN + 1))
  if [ "$n" -ge "$WAIT_MAX" ]; then
    state "gave-up $STAMP $1"
    "$SELF/lane-alert.sh" --log-only lane-move \
      "$lane was not moved to lane-run after $n checks; the last gate that failed: $1. To try again, delete state/lane-move/$lane on the hub." \
      >/dev/null 2>&1
    out "$lane" gave-up "$1"
  else
    state "waiting $n $1"
    out "$lane" waiting "$1"
  fi
}

# before_counts <flip epoch> — the module's counts for the hour before, to $TMP/before.
before_counts() { "lm_runs_done_$s" "$(($1 - BEFORE_S))" "$1" > "$TMP/before" 2>/dev/null; }

lm_preflip() {
  local rc reason stats done_n pub lts thr sum fe l5
  row_read "lane_placement.$lane"; rc=$?
  case "$rc" in 1) wait_on settings-unreadable; return ;; 2) wait_on no-row; return ;; esac
  if [ "$ROW_V" = fly ]; then
    # GNU date reads an empty string as today 00:00Z, so an empty updated_at is now.
    fe=""; [ -n "$ROW_AT" ] && fe=$(date -u -d "$ROW_AT" +%s 2>/dev/null)
    [[ "$fe" =~ ^[0-9]+$ ]] && [ "$fe" -le "$NOW" ] || fe=$NOW
    before_counts "$fe"
    cp "$TMP/before" "$before.tmp" && mv -f "$before.tmp" "$before"
    state "flipped $fe load5=$(load5) found"
    out "$lane" found "row fly by ${ROW_ACTOR:-unknown} at ${ROW_AT:-unknown}"
    return
  fi
  if [ "$ROW_V" != hub ] || [ "$ROW_ACTOR" != seed ]; then
    reason="operator row '$(printf '%s' "$ROW_RAW" | tr -d '\n' | cut -c1-64)' by ${ROW_ACTOR:-unknown}"
    state "held $STAMP $reason"; out "$lane" held "$reason"; return
  fi
  if reason=$(lp_hub_only_reason "$lane" 2>/dev/null); then
    reason="hub_only: $(printf '%s' "$reason" | tr -d '\n' | cut -c1-120)"
    state "held $STAMP $reason"; out "$lane" held "$reason"; return
  fi
  stats=$(_jobs_req GET /api/lane-runs/stats) || { wait_on stats-unreadable; return; }
  done_n=$(jq -r '[.lanes[]?.done // 0 | tonumber? // 0] | add // 0' <<<"$stats" 2>/dev/null)
  [[ "$done_n" =~ ^[0-9]+$ ]] || { wait_on stats-unreadable; return; }
  [ "$done_n" -gt 0 ] || { wait_on no-fleet; return; }
  pub=$("lm_publisher_lane_$s")
  lts=$(grep -F "; $pub placed " "$PUBLOG" 2>/dev/null | tail -1 | cut -c1-20)
  thr=$(ts_of "$((NOW - FRESH_S))")
  if ! [[ "$lts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || [[ "$lts" < "$thr" ]]; then
    wait_on no-publisher; return
  fi
  before_counts "$NOW"
  sum=$(awk -F '\t' '{ s += $2 } END { print s + 0 }' "$TMP/before")
  [ "$sum" -ge 1 ] || { wait_on lane-idle; return; }
  cp "$TMP/before" "$before.tmp" && mv -f "$before.tmp" "$before"
  l5=$(load5)
  if setting_set "lane_placement.$lane" fly "BH-7252: lane-move flip after proof gates; set hub to return it" >/dev/null 2>&1; then
    state "flipped $NOW load5=$l5"
    out "$lane" flipped "$sum runs in the hour before, load5=$l5"
  else
    wait_on put-failed
  fi
}

lm_verify() {
  local fe l5f l5n wf wt p b a resp okn fln ddn trunc v fmax pub plines pconf prej pfail
  local tot=0 reasons=() verdict why rows="" notes=""
  read -r _ fe l5f _ <<<"$l1"
  l5f=${l5f#load5=}
  [[ "$fe" =~ ^[0-9]+$ ]] || { out "$lane" flipped "bad state line"; return; }
  if [ "$NOW" -lt $((fe + VERIFY_AFTER)) ]; then
    out "$lane" flipped "check at $(iso_of $((fe + VERIFY_AFTER)))"; return
  fi
  row_read "lane_placement.$lane" || { out "$lane" flipped verify-read-failed; return; }
  wf=$((fe + AFTER_FROM)); wt=$((fe + AFTER_TO))
  "lm_runs_done_$s" "$wf" "$wt" > "$TMP/after" 2>/dev/null
  v=$(setting_get "lane_move.$lane.fail_max" 2>/dev/null | tr -d '[:space:]')
  fmax=$(knob "$v" 0 0 100000)
  while IFS=$'\t' read -r p b; do
    [[ "$p" =~ ^[A-Za-z0-9._-]+$ && "$b" =~ ^[0-9]+$ ]] || continue
    a=$(awk -F '\t' -v p="$p" '$1 == p { print $2 }' "$TMP/after")
    a=${a:-0}
    resp=$(_jobs_req GET "/api/lane-runs/by-prefix?lane=$lane&project_prefix=$p&limit=50") \
      || { out "$lane" flipped verify-read-failed; return; }
    # Only rows of exactly this project that finished in the window. The route
    # answers `failed` for a done row with rc != 0 (lib/lane-run-status.js).
    read -r okn fln ddn trunc < <(jq -r --arg p "$p" --argjson f "$wf" --argjson t "$wt" '
      [ .rows[]? | select(.project == $p)
        | ((.finished_at // "") | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch null)) as $e
        | select($e != null and $e >= $f and $e < $t) ] as $r
      | [ ($r | map(select(.status == "done" and ((.rc // 0) == 0))) | length),
          ($r | map(select(.status == "failed" or (.status == "done" and ((.rc // 0) != 0)))) | length),
          ($r | map(select(.status == "died")) | length),
          (if .truncated == true then 1 else 0 end) ] | @tsv' <<<"$resp" 2>/dev/null)
    [[ "$okn" =~ ^[0-9]+$ && "$fln" =~ ^[0-9]+$ && "$ddn" =~ ^[0-9]+$ ]] \
      || { out "$lane" flipped verify-read-failed; return; }
    [ "$trunc" = 1 ] && notes="$notes $p"
    tot=$((tot + fln + ddn))
    [ "$a" -ge $((b - 1)) ] || reasons+=("$p: after $a < before $b - 1")
    [ "$b" -lt 1 ] || [ "$okn" -ge 1 ] || reasons+=("$p: no done lane-run row in the window")
    rows+="| $p | $b | $a | $okn | $fln | $ddn |"$'\n'
  done < "$before"
  [ "$tot" -le "$fmax" ] || reasons+=("failed + died $tot > fail_max $fmax")
  pub=$("lm_publisher_lane_$s")
  read -r plines pconf prej pfail < <(grep -F "; $pub placed " "$PUBLOG" 2>/dev/null | awk -v f="$(ts_of "$wf")" -v t="$(ts_of "$wt")" '
    { ts = $1 " " $2; if (ts < f || ts >= t) next
      if (match($0, /[0-9]+ conflicts, [0-9]+ rejected, [0-9]+ failed/)) {
        split(substr($0, RSTART, RLENGTH), x, /[^0-9]+/); n++; c += x[1]; r += x[2]; e += x[3] } }
    END { print n + 0, c + 0, r + 0, e + 0 }')
  [ "${plines:-0}" -ge 1 ] || reasons+=("no $pub publisher line in the window")
  [ "${pconf:-0}" = 0 ] || reasons+=("publisher conflicts $pconf")
  [ "${pfail:-0}" = 0 ] || reasons+=("publisher failed $pfail")
  l5n=$(load5)
  if [ "$ROW_V" != fly ]; then verdict="KILLED (row '$ROW_RAW' by ${ROW_ACTOR:-unknown})"
  elif [ "${#reasons[@]}" = 0 ]; then verdict=PASS
  else verdict=FAIL; fi
  why=$(IFS=';'; printf '%s' "${reasons[*]}" | sed 's/;/; /g')
  {
    echo "Lane move check: $lane (BH-7252)."
    echo
    echo "Verdict: $verdict"
    [ "$verdict" != FAIL ] || echo "Reasons: $why."
    echo
    echo "Flip: $(iso_of "$fe")$(case "$l1" in *" found") echo " (an operator set the row)" ;; esac). Before window: $(iso_of $((fe - BEFORE_S))) to $(iso_of "$fe"). After window: $(iso_of "$wf") to $(iso_of "$wt") (UTC)."
    echo
    echo "| project | before runs | after runs | lane-run ok | failed | died |"
    echo "|---|---|---|---|---|---|"
    printf '%s' "$rows"
    echo
    echo "Publisher ($pub lines in the after window): ${plines:-0} lines, ${pconf:-0} conflicts, ${prej:-0} rejected, publisher failed ${pfail:-0}."
    echo "Failure budget: fail_max $fmax (settings row lane_move.$lane.fail_max)."
    [ -z "$notes" ] || echo "Incomplete: the lane_runs read was cut at 50 rows for:$notes. The ok/failed/died counts for those projects are a lower bound."
    echo "Hub load5 at the flip: $l5f. Hub load5 at the check: $l5n."
    echo
    echo "Runs are the finished runs the module counts (bin/lib/lane-move/$lane.sh). Lane-run ok/failed/died are lane_runs rows of that exact project that finished in the after window. PASS needs, for each project, after >= before - 1 and at least one ok row; failed + died <= fail_max; at least one publisher line, with no conflict and no failure."
    echo "Kill row (moves the lane back to the hub, no deploy): \`bin/jobs-client.sh setting-set lane_placement.$lane hub\`."
    echo "Source: bin/lane-move.sh on the hub."
    echo "<!-- lane-move:$lane:$fe -->"
  } > "$report.tmp" && mv -f "$report.tmp" "$report"
  case "$verdict" in
    KILLED*)
      state "killed $STAMP ${ROW_ACTOR:-unknown}"
      out "$lane" killed "row '$ROW_RAW' by ${ROW_ACTOR:-unknown}" ;;
    PASS)
      state "verified $STAMP"
      out "$lane" verified "${tot} failed+died, ${plines:-0} publisher lines" ;;
    FAIL)
      if ! setting_set "lane_placement.$lane" hub "BH-7252: lane-move rolled back: $(printf '%s' "$why" | cut -c1-300)" >/dev/null 2>&1; then
        out "$lane" rollback-failed "$why"; return
      fi
      state "rolled-back $STAMP $(printf '%s' "$why" | cut -c1-300)"
      "$SELF/lane-alert.sh" --severity warn --id "lane-move-$lane" lane-move \
        "$lane moved back to hub: $why. Report: state/lane-move/$lane.report.md on the hub." >/dev/null 2>&1
      out "$lane" rolled-back "$why" ;;
  esac
  l1=$(head -1 "$st"); l2=""
  lm_post
}

lm_post() {
  local issue v mark n
  v=$(setting_get "lane_move.$lane.issue" 2>/dev/null | tr -d '[:space:]')
  if [[ "$v" =~ ^[1-9][0-9]{0,6}$ ]]; then issue=$v; else issue=$ISSUE_DEFAULT; fi
  n=0; case "$l2" in "post-attempts "*) n=${l2#post-attempts }; [[ "$n" =~ ^[0-9]+$ ]] || n=0 ;; esac
  mark=$(tail -1 "$report" 2>/dev/null)
  if ! [[ "$mark" =~ ^\<\!--\ lane-move:${lane}:[0-9]+\ --\>$ ]]; then post_fail "no report"; return; fi
  gh_auth_for "$SLUG" >/dev/null 2>&1 || true
  if ! gh_rest_issue_comments "$SLUG" "$issue" 1000 > "$TMP/comments.json" 2>/dev/null \
     || ! jq -e 'type == "array"' "$TMP/comments.json" >/dev/null 2>&1; then
    post_fail read-failed; return
  fi
  if jq -e --arg m "$mark" 'any(.[]; (.body // "") | contains($m))' "$TMP/comments.json" >/dev/null 2>&1; then
    state "$l1" "posted $STAMP found"; out "$lane" posted "found on #$issue"; return
  fi
  gh_rest_comment "$SLUG" "$issue" "$report" >/dev/null 2>&1 || { post_fail post-failed; return; }
  state "$l1" "posted $STAMP"
  out "$lane" posted "#$issue"
}

# post_fail <why> — one failed post; the POST_MAX-th gives up.
post_fail() {
  n=$((n + 1))
  if [ "$n" -ge "$POST_MAX" ]; then
    state "$l1" "posted gave-up"
    "$SELF/lane-alert.sh" --log-only lane-move \
      "The lane-move report for $lane was not posted on #$issue after $n tries ($1). It is in state/lane-move/$lane.report.md on the hub." \
      >/dev/null 2>&1
    out "$lane" gave-up "post: $1"
  else
    state "$l1" "post-attempts $n"
    out "$lane" post-failed "$1"
  fi
}

N=0
for mod in "$MOD_DIR"/*.sh; do
  [ -r "$mod" ] || continue
  N=$((N + 1))
  (
    LM_LANE=""
    # shellcheck disable=SC1090
    . "$mod" || { out "$(basename "$mod" .sh)" not-configured "module does not load"; exit 0; }
    s=${LM_LANE//-/_}
    if [ "$(basename "$mod" .sh)" != "$LM_LANE" ] || ! [[ "$LM_LANE" =~ ^[a-z0-9][a-z0-9._-]{0,40}$ ]] \
       || ! command -v "lm_runs_done_$s" >/dev/null 2>&1 || ! command -v "lm_publisher_lane_$s" >/dev/null 2>&1; then
      out "$(basename "$mod" .sh)" not-configured "module contract"; exit 0
    fi
    lm_tick
  )
done
[ "$N" -gt 0 ] || out all not-configured "no module in ${MOD_DIR#"$H"/}"
exit 0
