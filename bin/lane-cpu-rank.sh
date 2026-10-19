#!/bin/bash
# gh-identity: app-token
# gh-rest: no-graphql
# bin/lane-cpu-rank.sh — BH-7252 C0 (part of #7252): rank the hub lanes by
# CPU seconds per hour over one window and post the table ONCE to an issue.
# Hub only, daily at 14:05Z behind bin/hub-lease.sh check
# (cron/lanes/735-lane-cpu-rank.cron). No LLM call, no paid call.
#
# One run:
#   1. state/lane-cpu-rank/state-<issue> says `posted` or `gave-up`: stop. No
#      read, no network, no sampling.
#   2. Read the comments of issue <settings row lane_cpu_rank.issue, default
#      7252> on $HARNESS_REPO, as the App. A comment that holds
#      `<!-- lane-cpu-rank:<issue> -->` means it was posted: state `posted <ts>
#      found`, no sampling. So no hour of sampling is spent on a run that will
#      not post.
#   3. Read /proc/loadavg, run bin/lane-cpu-sample.sh --cpu-s over
#      LANE_CPU_RANK_SECONDS (3600) at LANE_CPU_RANK_INTERVAL_S (5), read
#      /proc/loadavg again. Sampler rc 0 or 1 is a table; any other rc
#      (2 = no ticks, 64 = bad input) is sample-failed.
#   4. For the top LANE_CPU_RANK_TOP (15) lanes: placement from lp_decide
#      (bin/lib/lane-placement.sh) and the lane_placement.<lane>.hub_only row,
#      or `not classified`. The `other` row (CPU under no bin/<name>.sh) comes
#      last; the lanes past the top are summed in one line.
#   5. Write the report to state/lane-cpu-rank/report.md (tmp + mv), then post
#      it as one comment that ends with the marker. rc 0: state `posted <ts>
#      <issue>`. The state is written only after the post returns rc 0.
#      The App token is armed again right before the post (BH-7406): an
#      installation token lives 1 h and the window is 1 h, so the token armed
#      for step 2 is dead by now and the post got 401 on the hub every day.
#   6. A failed read, sample or post: state `attempts <n>`. The 6th failure
#      writes `gave-up <ts> <reason>` and one bin/lane-alert.sh --log-only line.
#   The report states the hub load5 target, the before number and the after
#   numbers on the line after the Load line (BH-7526): settings rows
#   lane_cpu_rank.load5_target (code default 24), lane_cpu_rank.load5_before
#   and lane_cpu_rank.load5_before_at; `Target met: yes` only when load5 at
#   the start and at the end of the window are both under the target.
# To measure again (the "after" numbers): set lane_cpu_rank.issue to another
# issue, or delete state/lane-cpu-rank/state-<issue> AND the old comment.
#
# Log line (logs/lane-cpu-rank.log), exit 0 on every path:
#   <ts> rank=<posted|found|not-configured|read-failed|sample-failed|
#   post-failed|gave-up|skipped (running)> issue=<n>(row|default) rows=<n>
#   load5=<start>-><end>[ why=<cause>]
# why= is on a failed run only (BH-7406), one word: http-<status>/<reason>
# (read-failed, post-failed), sampler-rc-<rc>[:<first stderr line, 120 chars,
# spaces as _>] (sample-failed), or the first missing piece: HARNESS_REPO |
# gh_auth_for | gh_rest_issue_comments | gh_rest_comment (not-configured).
#
# Test seams, read only under HARNESS_TEST_SANDBOX=1: LANE_CPU_RANK_GH_LIB (a
# file that defines the GitHub functions; without it a sandbox run is
# not-configured), LANE_CPU_RANK_SAMPLER (a command run instead of
# bin/lane-cpu-sample.sh), LANE_CPU_RANK_LOADAVG (a file read instead of
# /proc/loadavg).
#
# OFF: flags/lane-off-lane-cpu-rank (bin/harness-ctl.sh off lane-cpu-rank).
# Doc: docs/notes/2026-10-17-BH-7252-lane-cpu-rank.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
SANDBOX=0; [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && SANDBOX=1

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lane-cpu-rank
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lane-cpu-rank

STAMP=$(date -u +%FT%TZ)
DIR_R="$H/state/lane-cpu-rank"
LOG="$H/logs/lane-cpu-rank.log"
REPORT="$DIR_R/report.md"
MAX_ATTEMPTS=6
ISSUE=7252; ISSUE_SRC=default
ROWS=0; L5A=NA; L5B=NA; WHY=""

# knob <value> <default> <min> <max> — the value when it is a whole number in
# range, else the default.
knob() {
  if [[ "$1" =~ ^[0-9]{1,6}$ ]] && [ "$((10#$1))" -ge "$3" ] && [ "$((10#$1))" -le "$4" ]; then
    printf '%s' "$((10#$1))"
  else printf '%s' "$2"; fi
}
SECS=$(knob "${LANE_CPU_RANK_SECONDS:-3600}" 3600 60 7200)
INTERVAL=$(knob "${LANE_CPU_RANK_INTERVAL_S:-5}" 5 1 60)
TOP=$(knob "${LANE_CPU_RANK_TOP:-15}" 15 1 50)

out() {
  printf '%s rank=%s issue=%s(%s) rows=%s load5=%s->%s%s\n' \
    "$STAMP" "$1" "$ISSUE" "$ISSUE_SRC" "$ROWS" "$L5A" "$L5B" "${WHY:+ why=$WHY}" >> "$LOG"
}

mkdir -p "$H/logs" "$H/locks" "$DIR_R" 2>/dev/null
# shellcheck source=bin/jobs-client.sh
LOADED=1; . "$SELF/jobs-client.sh" 2>/dev/null || LOADED=0
v=""
[ "$LOADED" = 1 ] && v=$(setting_get lane_cpu_rank.issue 2>/dev/null | tr -d '[:space:]')
if [[ "$v" =~ ^[1-9][0-9]{0,6}$ ]]; then ISSUE=$v; ISSUE_SRC=row; fi
# The hub load5 target and the before number (BH-7526). A row that is missing,
# unreadable or not a number uses the code default: target 24 (the BH-7252
# acceptance), before `not set`.
T5=24; T5_SRC="code default"; B5="not set"; B5_AT=""
v=""; [ "$LOADED" = 1 ] && v=$(setting_get lane_cpu_rank.load5_target 2>/dev/null | tr -d '[:space:]')
if [[ "$v" =~ ^[0-9]{1,4}(\.[0-9]{1,2})?$ ]] && awk -v t="$v" 'BEGIN { exit !(t + 0 > 0) }'; then
  T5=$v; T5_SRC="row lane_cpu_rank.load5_target"
fi
v=""; [ "$LOADED" = 1 ] && v=$(setting_get lane_cpu_rank.load5_before 2>/dev/null | tr -d '[:space:]')
[[ "$v" =~ ^[0-9]{1,4}(\.[0-9]{1,2})?$ ]] && B5=$v
v=""; [ "$LOADED" = 1 ] && v=$(setting_get lane_cpu_rank.load5_before_at 2>/dev/null | tr -d '[:space:]')
[[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] && [ "$B5" != "not set" ] && B5_AT=" at $v"
# shellcheck source=bin/lib/lane-placement.sh
. "$SELF/lib/lane-placement.sh" 2>/dev/null || true
STATE="$DIR_R/state-$ISSUE"
MARK="<!-- lane-cpu-rank:$ISSUE -->"

exec 7> "$H/locks/lane-cpu-rank.lock" 2>/dev/null || { out "skipped (no lock file)"; exit 0; }
flock -n 7 || { out "skipped (running)"; exit 0; }

# ── 1. terminal state ────────────────────────────────────────────────────────
read -r S_WORD S_REST < "$STATE" 2>/dev/null || S_WORD=""
case "$S_WORD" in
  posted|gave-up) out "$S_WORD"; exit 0 ;;
  attempts) ATTEMPTS=${S_REST%% *}; [[ "$ATTEMPTS" =~ ^[0-9]+$ ]] || ATTEMPTS=0 ;;
  *) ATTEMPTS=0 ;;
esac

# ── 2. GitHub, as the App: posted already? ───────────────────────────────────
if [ "$SANDBOX" = 1 ]; then
  # shellcheck disable=SC1090
  [ -n "${LANE_CPU_RANK_GH_LIB:-}" ] && [ -r "$LANE_CPU_RANK_GH_LIB" ] && . "$LANE_CPU_RANK_GH_LIB"
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
[ -n "$SLUG" ] || WHY=HARNESS_REPO
for f in gh_auth_for gh_rest_issue_comments gh_rest_comment; do
  command -v "$f" >/dev/null 2>&1 && continue
  SLUG=""; [ -n "$WHY" ] || WHY=$f
done
[ -n "$SLUG" ] || { out not-configured; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/lcr.XXXXXX") || { out "skipped (mktemp)"; exit 0; }
trap 'command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset; rm -rf "$TMP"' EXIT
gh_auth_for "$SLUG" >/dev/null 2>&1 || true

# fail <outcome> — count one failed attempt; the last one gives up and alerts.
fail() {
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    printf 'gave-up %s %s\n' "$STAMP" "$1" > "$STATE"
    "$SELF/lane-alert.sh" --log-only lane-cpu-rank \
      "The hub lane CPU table was not posted on #$ISSUE after $ATTEMPTS tries ($1). The last report is in state/lane-cpu-rank/report.md on the hub. Post it by hand, or delete state/lane-cpu-rank/state-$ISSUE to try again." \
      >/dev/null 2>&1
    out gave-up
  else
    printf 'attempts %s\n' "$ATTEMPTS" > "$STATE"
    out "$1"
  fi
  exit 0
}

if ! gh_rest_issue_comments "$SLUG" "$ISSUE" > "$TMP/comments.json" 2>/dev/null \
   || ! jq -e 'type == "array"' "$TMP/comments.json" >/dev/null 2>&1; then
  WHY="http-${GH_REST_STATUS:-000}/${GH_REST_REASON:-none}"
  fail read-failed
fi
if jq -e --arg m "$MARK" 'any(.[]; (.body // "") | contains($m))' "$TMP/comments.json" >/dev/null 2>&1; then
  printf 'posted %s found\n' "$STAMP" > "$STATE"
  out found; exit 0
fi

# ── 3. the window ────────────────────────────────────────────────────────────
LOADAVG=/proc/loadavg
[ "$SANDBOX" = 1 ] && [ -n "${LANE_CPU_RANK_LOADAVG:-}" ] && LOADAVG=$LANE_CPU_RANK_LOADAVG
SAMPLER="$SELF/lane-cpu-sample.sh"
[ "$SANDBOX" = 1 ] && [ -n "${LANE_CPU_RANK_SAMPLER:-}" ] && SAMPLER=$LANE_CPU_RANK_SAMPLER
# loadavg <prefix> — sets <prefix>1 and <prefix>5 (NA when unreadable).
loadavg() {
  local a="" b="" rest
  read -r a b rest < "$LOADAVG" 2>/dev/null || true
  [[ "$a" =~ ^[0-9]+(\.[0-9]+)?$ ]] || a=NA
  [[ "$b" =~ ^[0-9]+(\.[0-9]+)?$ ]] || b=NA
  printf -v "${1}1" '%s' "$a"; printf -v "${1}5" '%s' "$b"
}
loadavg LA; L5A=$LA5
W_START=$(date -u +%FT%TZ)
"$SAMPLER" --seconds "$SECS" --interval "$INTERVAL" --cpu-s --lane lane-cpu-sample --max-pct 100 \
  > "$TMP/sample.out" 2> "$TMP/sample.err"
SRC=$?
W_END=$(date -u +%FT%TZ)
loadavg LB; L5B=$LB5
if [ "$SRC" != 0 ] && [ "$SRC" != 1 ]; then
  e=$(head -1 "$TMP/sample.err" 2>/dev/null | tr -c 'A-Za-z0-9._:/=-' '_' | cut -c1-120)
  e=${e%_}
  WHY="sampler-rc-$SRC${e:+:$e}"
  fail sample-failed
fi

# ── 4. the rows ──────────────────────────────────────────────────────────────
# sample.out rows: <share>\t<lane>\t<cpu_s_h>, largest first; the verdict line
# has no tab and is skipped.
OTHER_SHARE=0.0; OTHER_CPU=0.0; REST_N=0; REST_CPU=0
: > "$TMP/rows.md"
while IFS=$'\t' read -r share lane cpu; do
  [[ "$share" =~ ^[0-9]+\.[0-9]$ && "$cpu" =~ ^[0-9]+\.[0-9]$ && "$lane" =~ ^[A-Za-z0-9._-]+$ ]] || continue
  if [ "$lane" = other ]; then OTHER_SHARE=$share; OTHER_CPU=$cpu; continue; fi
  if [ "$ROWS" -ge "$TOP" ]; then
    REST_N=$((REST_N + 1)); REST_CPU=$((REST_CPU + 10#${cpu%.*} * 10 + 10#${cpu#*.})); continue
  fi
  ROWS=$((ROWS + 1))
  LP_PLACE=hub; LP_WHY=""
  command -v lp_decide >/dev/null 2>&1 && lp_decide "$lane"
  reason=""
  command -v lp_hub_only_reason >/dev/null 2>&1 && reason=$(lp_hub_only_reason "$lane" 2>/dev/null)
  # One table cell: no pipe, no newline.
  reason=$(printf '%s' "$reason" | tr '|\n\r' '/  ')
  [ -n "$reason" ] || reason="not classified"
  printf '| %s | %s | %s | %s | %s | %s |\n' "$ROWS" "$lane" "$cpu" "$share" "$LP_PLACE" "$reason" >> "$TMP/rows.md"
done < "$TMP/sample.out"

# ── 5. the report, then the comment ──────────────────────────────────────────
# Target met: yes only when both load5 reads are numbers and both are under
# the target (strict); a read that is NA is unknown, never yes.
if [ "$LA5" = NA ] || [ "$LB5" = NA ]; then MET=unknown
elif awk -v a="$LA5" -v b="$LB5" -v t="$T5" 'BEGIN { exit !(a + 0 < t + 0 && b + 0 < t + 0) }'; then MET=yes
else MET=no; fi
{
  echo "Hub lane CPU, ranked by CPU seconds per hour (BH-7252 C0)."
  echo
  echo "Window: $W_START to $W_END (UTC). Host: $(hostname 2>/dev/null || echo unknown). Interval: $INTERVAL s."
  echo "Load (load1/load5): start $LA1/$LA5, end $LB1/$LB5."
  echo "Hub load5 target: under $T5 ($T5_SRC). Before: $B5$B5_AT. After: start $LA5, end $LB5. Target met: $MET."
  echo
  echo "| rank | lane | CPU s/h | share % | placement | hub-only reason |"
  echo "|---|---|---|---|---|---|"
  cat "$TMP/rows.md"
  echo "| - | other | $OTHER_CPU | $OTHER_SHARE | - | not a lane |"
  echo
  [ "$REST_N" = 0 ] || echo "Lanes not shown: $REST_N ($((REST_CPU / 10)).$((REST_CPU % 10)) CPU s/h)."
  echo "CPU s/h is utime + stime of the lane's process tree, reaped children included, scaled to one hour. 3600 CPU s/h is one core busy all hour. Placement is lp_decide now; the reason is the lane_placement.<lane>.hub_only row."
  echo "Source: bin/lane-cpu-sample.sh --cpu-s on the hub, bin/lane-cpu-rank.sh."
  echo "$MARK"
} > "$TMP/body.md"
cp "$TMP/body.md" "$REPORT.tmp" && mv -f "$REPORT.tmp" "$REPORT"
gh_auth_for "$SLUG" >/dev/null 2>&1 || true
if ! gh_rest_comment "$SLUG" "$ISSUE" "$TMP/body.md" >/dev/null 2>&1; then
  WHY="http-${GH_REST_STATUS:-000}/${GH_REST_REASON:-none}"
  fail post-failed
fi
printf 'posted %s %s\n' "$STAMP" "$ISSUE" > "$STATE"
out posted
exit 0
