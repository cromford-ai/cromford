#!/bin/bash
# bin/archie-overlook.sh — BH-5562 (BH-5556.5): Archie as the Overlooker of the
# staff agents. A hub lane with no model call. Archie stays the only voice to
# the user: the trip and duplicate beats go through bin/lane-alert.sh, and the
# weekly report goes through Archie's own send path (archie_beat_gate in
# bin/lib/archie-wake.sh, so quiet hours and Archie's beat cap apply).
#
#   archie-overlook.sh [run]   the cron line, every 15 minutes (8-58/15)
#
# RUN, in this order:
#   1. lane_gate_or_exit / lane_env_apply archie-overlook;
#      ARCHIE_OVERLOOK_ENABLED=0 exits; flock -n locks/archie-overlook.lock
#      (held = skip, never wait). NOW is read once (ARCHIE_NOW only under
#      HARNESS_TEST_SANDBOX=1).
#   2. ROSTER: GET /api/staff/agents. Unreadable = one log line, exit 0: nothing
#      paused, nothing read from GitHub. A name that does not match
#      ^[a-z][a-z0-9-]{1,39}$ is one log line and is skipped.
#   3. TRIPWIRES, per roster agent, over state/staff/<agent>/acted/*.json (the
#      files bin/staff.sh finish() writes) with an mtime in today's UTC day:
#        loop wire    one family (the class slug: lowercase, every run of
#                     characters outside [a-z0-9-] to "-", trim "-", 41 chars,
#                     empty or unparsable = unclassified) has
#                     STAFF_OVERLOOK_FAMILY_MAX (25) actions or more
#        filing wire  STAFF_OVERLOOK_FILE_MAX (10) acted files or more with
#                     outcome `filed`
#      Over a wire: skip when flag_active staff-off-<agent>; skip when ledger
#      archie_overlook trip-<agent>-<day> exists (a person cleared the flag
#      after today's trip). Else the ledger row `pending`, flag_set
#      staff-off-<agent>, ONE warn beat (lane-alert.sh --id
#      staff-trip-<agent>-<day>), then the row `paused`. flag_set can fail
#      after it wrote the flag file (the database PUT failed): the beat says
#      the agent is paused on this box but the row is missing. A row still
#      `pending` makes the next run call flag_set again, also when the flag is
#      active; lane-alert dedups the repeated beat by its id.
#   4. DUPLICATE SCAN, only when an acted file with outcome `filed` is newer than
#      state/archie-overlook/dupscan.stamp (else 0 GitHub reads). One open-issue
#      list per roster agent (label staff:<agent>, STAFF_FILE_REPO else the
#      harness repo). A <!-- staff-fp:<fp> --> marker on two or more open issues
#      is ONE warn beat (lane-alert.sh --id staff-dup-<fp12>) that names the
#      issues. Nothing is closed. A list that fails, or that reaches 1000 rows,
#      stops the scan and the stamp is NOT moved, so the next run tries again.
#   5. WEEKLY REPORT, on UTC weekday STAFF_OVERLOOK_REPORT_DOW (1 = Monday) when
#      ledger archie_overlook weekly-<GGGG>-W<VV> is not `sent`. One block per
#      accountable owner (sorted), one line per agent for the last 7 days:
#        - <agent>: filed <n>, digested <n>, precision <p>% (<agree> of <n>), spend $<x>
#      precision is agent-core precision() over the agent's issues closed in the
#      last 7 days (completed = agree, not_planned = overrule): `n/a` when none,
#      `unreadable` when the list failed. spend sums logs/cost.csv rows with
#      stage staff.<agent>; the staff-tick rows, which carry no agent, print
#      once under the title as `unattributed staff-tick spend $<x>`. The report goes
#      to state/archie-overlook/weekly-<week>.md, the ledger row is put
#      `pending`, then archie_beat_gate; rc 0 (sent or held for Archie's digest)
#      puts it `sent`, rc 1 leaves `pending` for the next run. A ledger that
#      cannot be read sends nothing. Report files older than 84 days are deleted
#      on each weekly run (one log line names the count).
#
# OFF: ARCHIE_OVERLOOK_ENABLED=0, flags/lane-off-archie-overlook,
# bin/harness-ctl.sh off archie-overlook. A paused staff agent resumes only
# when a person clears flags/staff-off-<agent>.
# Registry: catalog/lanes.d/archie-overlook.json.
# Cron: cron/lanes/729-archie-overlook.cron.
# Note: docs/notes/2026-10-15-BH-5562-archie-overlooker.md.
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
case "${1:-run}" in
  run) ;;
  *) echo "usage: archie-overlook.sh [run]" >&2; exit 2 ;;
esac
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/archie-wake.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest-list.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_OVERLOOK_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_OVERLOOK_FIXTURE"
fi
command -v _jobs_req >/dev/null 2>&1 && command -v flag_active >/dev/null 2>&1 \
  && command -v archie_beat_gate >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { echo "archie-overlook: jobs-client, archie-wake or jq missing" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$ARCHIE_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/archie-overlook.log"
ST="$H/state/archie-overlook"
log() { printf '%s %s\n' "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit archie-overlook
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie-overlook

# knob_int <name> <value> <default> <min> <max>: out of range is one warn line
# and the default, never a silent clamp (D11).
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    log "warn: $1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}
[ "$(knob_int ARCHIE_OVERLOOK_ENABLED "${ARCHIE_OVERLOOK_ENABLED:-1}" 1 0 1)" = 0 ] && exit 0
FAMILY_MAX=$(knob_int STAFF_OVERLOOK_FAMILY_MAX "${STAFF_OVERLOOK_FAMILY_MAX:-25}" 25 2 1000)
FILE_MAX=$(knob_int STAFF_OVERLOOK_FILE_MAX "${STAFF_OVERLOOK_FILE_MAX:-10}" 10 1 1000)
DOW=$(knob_int STAFF_OVERLOOK_REPORT_DOW "${STAFF_OVERLOOK_REPORT_DOW:-1}" 1 1 7)
# BH-4080: the harness repo's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" || exit 1
REPO="${STAFF_FILE_REPO:-$HARNESS_REPO}"
if ! [[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then log "warn: STAFF_FILE_REPO=$REPO is not owner/repo; using $HARNESS_REPO"; REPO=$HARNESS_REPO; fi

exec 9>"$H/locks/archie-overlook.lock" || exit 0
flock -n 9 || exit 0
mkdir -p "$ST" || { log "cannot create $ST; nothing done"; exit 0; }
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/archie-overlook.XXXXXX") || { log "mktemp failed; nothing done"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT

DAY=$(date -u -d "@$NOW" +%Y-%m-%d)
DAY0=$((NOW - NOW % 86400))   # epoch days are 86400 s: today 00:00Z

# ═════ roster ════════════════════════════════════════════════════════════════
NAME_RE='^[a-z][a-z0-9-]{1,39}$'
roster=$(_jobs_req GET /api/staff/agents) || { log "roster unreadable (GET /api/staff/agents); nothing done"; exit 0; }
jq -r '.agents[]? | [.name // "", .accountable // ""] | @tsv' <<<"$roster" > "$TMPD/roster" 2>/dev/null \
  || { log "roster unparsable; nothing done"; exit 0; }
: > "$TMPD/names"
while IFS=$'\t' read -r n acc; do
  [[ $n =~ $NAME_RE ]] || { log "roster name '$n' is not a valid agent name; skipped"; continue; }
  printf '%s\t%s\n' "$n" "${acc:-unassigned}" >> "$TMPD/names"
done < "$TMPD/roster"

# acted_lines <agent> <from epoch> <to epoch>: the first line of each acted file
# with an mtime in [from, to), one line per file (bash read: no process per file).
acted_lines() {
  local d="$H/state/staff/$1/acted" f l
  [ -d "$d" ] || return 0
  while IFS= read -r -d '' f; do
    l=""; IFS= read -r l < "$f" || true
    printf '%s\n' "$l"
  done < <(find "$d" -maxdepth 1 -type f -name '*.json' -newermt "@$(($2 - 1))" ! -newermt "@$(($3 - 1))" -print0 2>/dev/null)
}
# One JSON summary from acted lines: {filed, digested, top: [family, count]}.
SUMMARY_JQ='
  def slug: (if type == "string" then . else "" end) | ascii_downcase
    | gsub("[^a-z0-9-]+"; "-") | gsub("^-+|-+$"; "") | .[0:41]
    | if . == "" then "unclassified" else . end;
  [inputs | (try fromjson catch null) | if type == "object" then . else {} end] as $r
  | {filed: ([$r[] | select(.outcome == "filed")] | length),
     digested: ([$r[] | select(.outcome == "digested")] | length),
     top: ([$r[] | .class | slug] | group_by(.) | map([.[0], length]) | max_by(.[1]) // ["", 0])}'

# ═════ tripwires ═════════════════════════════════════════════════════════════
TRIPS=0
while IFS=$'\t' read -r n _; do
  s=$(acted_lines "$n" "$DAY0" "$((DAY0 + 86400))" | jq -cRn "$SUMMARY_JQ") || continue
  fam=$(jq -r '.top[0]' <<<"$s"); famn=$(jq -r '.top[1]' <<<"$s"); filed=$(jq -r .filed <<<"$s")
  if [ "$famn" -ge "$FAMILY_MAX" ]; then
    why="did $famn \"$fam\" actions today (loop limit $FAMILY_MAX)"
  elif [ "$filed" -ge "$FILE_MAX" ]; then
    why="filed $filed tickets today (filing limit $FILE_MAX)"
  else
    continue
  fi
  st=$(job_ledger_get archie_overlook "trip-$n-$DAY" 2>/dev/null); lrc=$?
  # `pending`: an earlier run's flag_set failed. The file path writes the flag
  # file before its database PUT fails, so the flag can be active here; call
  # flag_set again until the row is written.
  if [ "$lrc" != 0 ] || [ "$st" != pending ]; then
    flag_active "staff-off-$n" && continue
    [ "$lrc" = 0 ] && continue
    [ "$lrc" = 2 ] || log "warn: ledger unreadable for trip-$n-$DAY; tripping without the dedup row"
    job_ledger_put archie_overlook "trip-$n-$DAY" pending >/dev/null 2>&1 \
      || log "warn: trip-$n-$DAY pending could not be written to the ledger"
  fi
  if flag_set "staff-off-$n" on "archie-overlook: $n $why" >/dev/null 2>&1; then
    text="Overlooker paused staff agent $n. It $why. Flag staff-off-$n written. A person must clear the flag to resume it."
    "$H/bin/lane-alert.sh" --id "staff-trip-$n-$DAY" --severity warn archie-overlook "$text" >/dev/null 2>&1 || true
    job_ledger_put archie_overlook "trip-$n-$DAY" paused >/dev/null 2>&1 \
      || log "warn: trip-$n-$DAY could not be written to the ledger"
    log "trip $n paused: $why"
  elif flag_active "staff-off-$n"; then
    text="Overlooker paused staff agent $n on this box. It $why. Flag staff-off-$n is on, but its database row could not be written. The next run tries again."
    "$H/bin/lane-alert.sh" --id "staff-trip-$n-$DAY" --severity warn archie-overlook "$text" >/dev/null 2>&1 || true
    log "trip $n: flag_set staff-off-$n failed after the flag file was written; the database row is missing: $why"
  else
    text="Overlooker could not pause staff agent $n. It $why. I could not write flag staff-off-$n. The next run tries again."
    "$H/bin/lane-alert.sh" --id "staff-trip-$n-$DAY" --severity warn archie-overlook "$text" >/dev/null 2>&1 || true
    log "trip $n: flag_set staff-off-$n failed; the flag is not written: $why"
  fi
  TRIPS=$((TRIPS + 1))
done < "$TMPD/names"

# ═════ duplicate scan ════════════════════════════════════════════════════════
STAMP="$ST/dupscan.stamp"
newfiled=0
while IFS=$'\t' read -r n _; do
  d="$H/state/staff/$n/acted"
  [ -d "$d" ] || continue
  hits=$(if [ -f "$STAMP" ]; then
      find "$d" -maxdepth 1 -type f -name '*.json' -newer "$STAMP" -print0 2>/dev/null
    else
      find "$d" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null
    fi | xargs -0 -r grep -l '"outcome":"filed"' 2>/dev/null)
  [ -n "$hits" ] && { newfiled=1; break; }
done < "$TMPD/names"
DUPS=0
if [ "$newfiled" = 1 ]; then
  : > "$STAMP.next"   # the scan's start: a filing written during the scan is seen next run
  : > "$TMPD/pairs"; scanned=1
  while IFS=$'\t' read -r n _; do
    grc=0
    gh_rest_issue_list "$REPO" open "staff:$n" 1000 > "$TMPD/open.json" 2>/dev/null || grc=$?
    if [ "$grc" != 0 ] || ! jq -e 'type == "array" and length < 1000' "$TMPD/open.json" >/dev/null 2>&1; then
      log "dup scan: open issue list for staff:$n unreadable (rc=$grc HTTP ${GH_REST_STATUS:-}); stamp not moved, the next run retries"
      scanned=0; break
    fi
    jq -r '.[] | .html_url as $u | (.body // "") | [scan("<!-- staff-fp:([0-9a-f]{64}) -->") | .[0]] | unique[] | [., $u] | @tsv' \
      "$TMPD/open.json" >> "$TMPD/pairs"
  done < "$TMPD/names"
  if [ "$scanned" = 1 ]; then
    while IFS=$'\t' read -r fp urls cnt; do
      "$H/bin/lane-alert.sh" --id "staff-dup-${fp:0:12}" --severity warn archie-overlook \
        "Overlooker found staff finding ${fp:0:12} on $cnt open issues: $urls. Close all but one." >/dev/null 2>&1 || true
      DUPS=$((DUPS + 1))
    done < <(sort -u "$TMPD/pairs" | jq -rRn '[inputs | split("\t")] | group_by(.[0])[] | select(length > 1)
      | [.[0][0], ([.[][1]] | join(" ")), length] | @tsv')
    mv -f "$STAMP.next" "$STAMP"
    log "dup scan: $DUPS duplicated fingerprint(s)"
  else
    rm -f "$STAMP.next"
  fi
fi

# ═════ weekly report ═════════════════════════════════════════════════════════
weekly() {
  local wk from from_iso st rc n acc s p spend un line report
  [ "$(date -u -d "@$NOW" +%u)" = "$DOW" ] || return 0
  wk=$(date -u -d "@$NOW" +%G-W%V)
  st=$(job_ledger_get archie_overlook "weekly-$wk" 2>/dev/null); rc=$?
  case "$rc" in
    0) [ "$st" = sent ] && return 0 ;;
    2) ;;
    *) log "weekly $wk: ledger unreadable; not sent, the next run tries again"; return 0 ;;
  esac
  from=$((NOW - 7 * 86400)); from_iso=$(date -u -d "@$from" +%Y-%m-%dT%H:%M:%SZ)
  # Spend per staff stage over the last 7 days (cost.csv: 1 ts, 4 stage, 13 cost_usd).
  awk -F, -v f="$from_iso" 'NR > 1 && $1 >= f && ($4 == "staff-tick" || $4 ~ /^staff\./) { s[$4] += $13 }
    END { for (k in s) printf "%s\t%.2f\n", k, s[k] }' "$H/logs/cost.csv" > "$TMPD/spend" 2>/dev/null || : > "$TMPD/spend"
  un=$(awk -F'\t' '$1 == "staff-tick" { print $2 }' "$TMPD/spend"); un=${un:-0.00}
  : > "$TMPD/lines"
  while IFS=$'\t' read -r n acc; do
    s=$(acted_lines "$n" "$from" "$((NOW + 1))" | jq -cRn "$SUMMARY_JQ")
    rc=0
    gh_rest_issue_list "$REPO" closed "staff:$n" 1000 > "$TMPD/closed.json" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'type == "array" and length < 1000' "$TMPD/closed.json" >/dev/null 2>&1; then
      p="precision unreadable"
    else
      p=$(jq -c --arg f "$from_iso" '[.[] | select((.closed_at // "") >= $f)
          | {verdict: (if .state_reason == "completed" then "agree" elif .state_reason == "not_planned" then "overrule" else "none" end)}]' \
          "$TMPD/closed.json" | node --input-type=module -e '
            const { precision } = await import(process.argv[1]);
            let raw = ""; for await (const c of process.stdin) raw += c;
            const o = JSON.parse(raw), p = precision(o);
            const a = o.filter((x) => x.verdict === "agree").length, n = o.filter((x) => x.verdict !== "none").length;
            console.log(p === null ? "precision n/a" : `precision ${Math.round(p * 100)}% (${a} of ${n})`);' \
          "$H/agent-core/src/learning.js" 2>/dev/null) || p="precision unreadable"
    fi
    spend=$(awk -F'\t' -v k="staff.$n" '$1 == k { print $2 }' "$TMPD/spend"); spend=${spend:-0.00}
    printf '%s\t- %s: filed %s, digested %s, %s, spend $%s\n' "$acc" "$n" "$(jq -r .filed <<<"$s")" \
      "$(jq -r .digested <<<"$s")" "$p" "$spend" >> "$TMPD/lines"
  done < "$TMPD/names"
  report=$({
    printf 'Staff weekly report %s (7 days to %s).\n' "$wk" "$DAY"
    printf 'unattributed staff-tick spend $%s\n' "$un"
    while IFS= read -r acc; do
      printf '\nOwner: %s\n' "$acc"
      awk -F'\t' -v a="$acc" '$1 == a { sub(/^[^\t]*\t/, ""); print }' "$TMPD/lines"
    done < <(cut -f1 "$TMPD/lines" | LC_ALL=C sort -u)
  } | sed 's/—/-/g')
  [ "${#report}" -gt 3500 ] && log "weekly $wk: the report is ${#report} chars; cut to 3500"
  report=${report:0:3500}
  printf '%s\n' "$report" > "$ST/weekly-$wk.md"
  n=$(find "$ST" -maxdepth 1 -type f -name 'weekly-*.md' -mtime +84 -print -delete 2>/dev/null | grep -c .)
  [ "$n" -gt 0 ] && log "weekly: deleted $n report file(s) older than 84 days"
  job_ledger_put archie_overlook "weekly-$wk" pending >/dev/null 2>&1 \
    || { log "weekly $wk: ledger not writable; not sent, the next run tries again"; return 0; }
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie
  archie_wake_init
  line=$(jq -nc --arg a "staff-weekly-$wk" --arg l "$report" '{akey: $a, line: $l}')
  # AW_GATE_LAST is archie_beat_gate's result (sent or queued), not an env knob.
  AW_GATE_LAST=""
  if archie_beat_gate "$line"; then
    job_ledger_put archie_overlook "weekly-$wk" sent >/dev/null 2>&1 \
      || log "warn: weekly $wk was ${AW_GATE_LAST:-sent} but could not be marked sent"
    log "weekly $wk ${AW_GATE_LAST:-sent}"
  else
    log "weekly $wk not sent (archie_beat_gate rc 1); pending, the next run tries again"
  fi
}
weekly
[ "$TRIPS" -gt 0 ] && log "run: trips=$TRIPS dups=$DUPS"
exit 0
