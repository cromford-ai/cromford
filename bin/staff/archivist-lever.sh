#!/bin/bash
# bin/staff/archivist-lever.sh — the archivist staff agent's metric and its one
# lever (BH-10125, C4 of #9423). Hub only, hourly at :57
# (cron/lanes/787-staff-archivist-lever.cron). No LLM call, no git command.
#
# WHY. The staff contract (BH-9187, C0) says every staff agent owns ONE metric
# and is judged by whether it moved. The archivist owns
# causes_fixed_by_hand_twice: the count of distinct causes Archie fixed by hand
# at least staff.archivist.recur_n times in the last staff.archivist.window_days
# UTC days (target 0). Its lever files ONE ai-build issue per repeated cause, so
# the factory fixes the cause and Archie stops fixing it by hand.
#
# WHAT, in order (each step that stops writes one log line and exits 0):
#   1  load the libs; a missing function or no jq = `not-configured (<what>)`.
#   2  KILL, before any request: STAFF_ENABLED=0, then the flags staff-off-all,
#      staff-kill-all, staff-off-archivist, staff-kill-archivist =
#      `killed by <flag>`; then the lane gate (lane-off-staff-archivist-lever).
#   3  flock -n locks/staff-archivist-lever.lock (held = skip).
#   4  GET /api/staff/agent?name=archivist: the archivist must be active.
#   5  KNOBS: staff_level archivist, recur_n, window_days (over 30 = one warn
#      line and 7), file_max_day.
#   6  READ Archie's hand-fix log: the archie_actions rows of window_days UTC
#      days, through the BH-4587 reader (afi_read_days). A day not read in full,
#      or the route absent = causes_fixed_by_hand_twice=unreadable, no sample, no
#      action (an unreadable count is never 0).
#   7  COUNT: the BH-4587 occurrences and cause fingerprints (afi_occurrences),
#      then arch_repeated: one line per cause with >= recur_n occurrences.
#   8  SAMPLE: POST /api/staff/levers/metric {agent:archivist,
#      metric:causes_fixed_by_hand_twice}. That call settles the archivist's due
#      actions (C0). A failure: sample=failed, the run goes on.
#   9  GATE: act only at level file or act (anything else is observe:
#      would=<n>, 0 actions, 0 GitHub calls).
#  10  LISTS: the archie-fm-improve label list (state=all) and the open issues of
#      HARNESS_REPO (afi_issue_lists). Unreadable = lists=unreadable, no action.
#  11  PER repeated cause, highest count first:
#      a DEDUPE: a label-list issue with the cause's marker (any state), or any
#        open issue with it = already.
#      b CAP: label-list issues created today >= file_max_day = capped.
#      c RECORD BEFORE ACT: POST /api/staff/levers/actions, key
#        file:<fp>:<UTC day>. Only a new row files; existing or 409 = taken;
#        anything else = failed. So no issue exists without its ledger row.
#      d FILE through the tracker seam (tracker_create): labels ai-build,
#        archie-fm-improve, staff:archivist, and the BH-4587 marker, so
#        bin/archie-fm-improve.sh tracks the issue to its merged PR and never
#        files a second one. Filed = rc 0, HTTP 201 and an html_url.
#
# KNOBS (settings rows): staff.archivist.level (observe), staff.archivist.recur_n
# (2), staff.archivist.window_days (7, 1..30), staff.archivist.file_max_day (3).
# Env STAFF_ENABLED (0 = off). Seed:
# worker/jobs/schema.d/202611252047-bh-10125-archivist-lever.sql.
#
# WRITES. One summary line per run in logs/staff-archivist-lever.log:
#   <ts> level=<L> causes_fixed_by_hand_twice=<M|unreadable> occurrences=<n>
#   sample=<ok|failed|skipped> repeated=<n> filed=<n> already=<n> capped=<n>
#   taken=<n> would=<n> failed=<n>
# The rows: staff_metric_samples and staff_lever_actions through the C0 routes;
# the issues on HARNESS_REPO. No state/ file.
#
# EXIT. 0 every run that finished; 2 bad arguments.
# Env (test seams, honored only with HARNESS_TEST_SANDBOX=1): ARCHIVIST_NOW
#   (epoch seconds), ARCHIVIST_FIXTURE (a file sourced after the libs).
#   ARCHIVIST_LIB_ONLY=1 loads arch_action_verdict and arch_repeated and returns.
# OFF: flags/lane-off-staff-archivist-lever (bin/harness-ctl.sh off
#   staff-archivist-lever), or any staff kill flag above.
# Registry: catalog/lanes.d/staff-archivist-lever.json.
# Doc: docs/notes/2026-11-25-BH-10125-archivist.md.
# gh-rest: no-graphql
set -uo pipefail

# arch_action_verdict <http-code> <body-file> <rc> — the answer of
# POST /api/staff/levers/actions -> run | taken | failed. Only a new row is
# run: existing or 409 is this cause's filing already recorded today, and
# anything else fails closed.
arch_action_verdict() {
  local code="${1:-}" f="${2:-}" rc="${3:-1}"
  if [ "$code" = 409 ]; then echo taken; return 0; fi
  if [ "$rc" = 0 ] && [[ "$code" == 2?? ]] && [ -s "$f" ]; then
    if jq -e '.ok == true and .existing == true' "$f" >/dev/null 2>&1; then echo taken; return 0; fi
    if jq -e '.ok == true and (.existing // false) == false and (.action.action_key | type) == "string"' "$f" >/dev/null 2>&1; then
      echo run; return 0
    fi
  fi
  echo failed
}

# arch_repeated <occ-file> <since-epoch> <recur_n> — the BH-4587 occurrences
# (afi_occurrences) with t > since, grouped by fingerprint. One line per cause
# with at least recur_n of them: fp<TAB>count<TAB>cause, count desc, then fp.
arch_repeated() {
  jq -sr --argjson a "$2" --argjson n "$3" '
    [.[] | select(.t > $a)] | group_by(.fp)
    | map({fp: .[0].fp, n: length, c: .[0].c}) | map(select(.n >= $n))
    | sort_by(-.n, .fp) | .[] | "\(.fp)\t\(.n)\t\(.c)"' "$1"
}

[ "${ARCHIVIST_LIB_ONLY:-}" = 1 ] && return 0 2>/dev/null

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,66p' "$0"; exit 0 ;;
    *) echo "archivist-lever: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
LIBD="$(cd "$SELF/.." && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$LIBD/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/staff-archivist-lever.log"
NOW=$(date -u +%s)
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIVIST_NOW:-} =~ ^[0-9]+$ ]] && NOW=$ARCHIVIST_NOW
TS=$(date -u -d "@$NOW" +%FT%TZ)
DAY=$(date -u -d "@$NOW" +%F)
log() { printf '%s %s\n' "$TS" "$*" >> "$LOG"; }

# ── 1 libs ────────────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || { log "not-configured (no jq)"; exit 0; }
# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "$LIBD/lib/deployment.sh" 2>/dev/null || true
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$LIBD/lib/lane-gate.sh" 2>/dev/null || true
  . "$H/bin/jobs-client.sh" 2>/dev/null || . "$LIBD/jobs-client.sh" 2>/dev/null || true
  . "$H/bin/lib/gh-rest.sh" 2>/dev/null || . "$LIBD/lib/gh-rest.sh" 2>/dev/null || true
  . "$H/bin/lib/archie-fm.sh" 2>/dev/null || . "$LIBD/lib/archie-fm.sh" 2>/dev/null || true
  . "$H/bin/lib/archie-fm-queue/common.sh" 2>/dev/null || . "$LIBD/lib/archie-fm-queue/common.sh" 2>/dev/null || true
  . "$H/bin/lib/archie-fm-improve/common.sh" 2>/dev/null || . "$LIBD/lib/archie-fm-improve/common.sh" 2>/dev/null || true
  . "$H/bin/lib/archie-fm-improve/tickets.sh" 2>/dev/null || . "$LIBD/lib/archie-fm-improve/tickets.sh" 2>/dev/null || true
  . "$H/bin/lib/staff-contract.sh" 2>/dev/null || . "$LIBD/lib/staff-contract.sh" 2>/dev/null || true
  . "$H/bin/lib/tracker.sh" 2>/dev/null || . "$LIBD/lib/tracker.sh" 2>/dev/null || true
}
command -v tracker_load >/dev/null 2>&1 && tracker_load github-issues >/dev/null 2>&1
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIVIST_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIVIST_FIXTURE"
fi
for fn in _jobs_req _jobs_req_file _afm_req flag_active setting_get gh_rest afi_read_days afi_occurrences \
          afi_issue_lists afi_issue_of afi_open_hit afi_occ_lines afi_marker staff_level staff_knob \
          staff_action_post staff_metric_post tracker_create; do
  command -v "$fn" >/dev/null 2>&1 || { log "not-configured (no $fn)"; exit 0; }
done
declare -F trk_gh_create >/dev/null 2>&1 || { log "not-configured (the github-issues tracker adapter did not load)"; exit 0; }
[ -n "${HARNESS_REPO:-}" ] || { log "not-configured (no HARNESS_REPO)"; exit 0; }
AFM_LOG="$LOG"; AFQ_ACTOR=staff-archivist-lever; AFI_REPO=$HARNESS_REPO

# ── 2 kill, before any request ────────────────────────────────────────────────
[ "${STAFF_ENABLED:-1}" = 0 ] && { log "killed by STAFF_ENABLED=0"; exit 0; }
for f in staff-off-all staff-kill-all staff-off-archivist staff-kill-archivist; do
  if flag_active "$f"; then log "killed by $f"; exit 0; fi
done
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit staff-archivist-lever
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply staff-archivist-lever

# ── 3 lock ────────────────────────────────────────────────────────────────────
exec 9>"$H/locks/staff-archivist-lever.lock" || { log "lock file unwritable - not running"; exit 0; }
flock -n 9 || { log "another archivist-lever run is running"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/archivist-lever.XXXXXX") || { log "worker-failed (mktemp)"; exit 0; }
trap 'rm -rf "$WORK"' EXIT
AFI_ROWS="$WORK/rows.jsonl"; AFI_IMP="$WORK/imp.jsonl"; AFI_OCC="$WORK/occ.jsonl"
AFI_LBL="$WORK/lbl.jsonl"; AFI_OPEN="$WORK/open.jsonl"
: > "$AFI_ROWS"; : > "$AFI_IMP"; : > "$AFI_OCC"; : > "$AFI_LBL"; : > "$AFI_OPEN"

# ── 4 roster ──────────────────────────────────────────────────────────────────
row=$(_jobs_req GET "/api/staff/agent?name=archivist"); rc=$?
[ "$rc" = 0 ] || { log "roster row unreadable or absent (rc=$rc); nothing ran"; exit 0; }
[ "$(jq -r '.agent.status // ""' <<<"$row" 2>/dev/null)" = active ] || { log "archivist is not active on the roster; nothing ran"; exit 0; }

L=- M=unreadable OCC=- SAMPLE=skipped REP=0 FILED=0 ALREADY=0 CAPPED=0 TAKEN=0 WOULD=0 FAILED=0
summary() {
  log "level=$L causes_fixed_by_hand_twice=$M occurrences=$OCC sample=$SAMPLE repeated=$REP filed=$FILED already=$ALREADY capped=$CAPPED taken=$TAKEN would=$WOULD failed=$FAILED"
}

# ── 5 knobs ───────────────────────────────────────────────────────────────────
L=$(staff_level archivist 2>/dev/null) || true
[ -n "$L" ] || L=observe
RECUR=$(staff_knob archivist recur_n 2)        # fallback 2; row staff.archivist.recur_n
WIN=$(staff_knob archivist window_days 7)      # fallback 7; row staff.archivist.window_days
if [ "$WIN" -gt 30 ]; then
  log "warn: staff.archivist.window_days=$WIN is over 30; using the fallback 7"; WIN=7
fi
CAP=$(staff_knob archivist file_max_day 3)     # fallback 3; row staff.archivist.file_max_day

# ── 6 read Archie's hand-fix log ──────────────────────────────────────────────
rc=0; afi_read_days "$(( NOW - (WIN - 1) * 86400 ))" "$WIN" || rc=$?
# AFI_INCOMPLETE: set to 0 by common.sh at source time, 1 by afi_read_days on a bad day.
if [ "$rc" != 0 ] || [ "$AFI_INCOMPLETE" = 1 ]; then
  log "the archie_actions rows of the last $WIN days could not be read in full (rc=$rc); no sample, no action"
  summary; exit 0
fi

# ── 7 count ───────────────────────────────────────────────────────────────────
afi_occurrences
SINCE=$(( NOW - WIN * 86400 ))
arch_repeated "$AFI_OCC" "$SINCE" "$RECUR" > "$WORK/repeated.tsv" 2>/dev/null || {
  log "the occurrences could not be counted; no sample, no action"; summary; exit 0; }
OCC=$(jq -s --argjson a "$SINCE" '[.[] | select(.t > $a)] | length' "$AFI_OCC")
M=$(grep -c . "$WORK/repeated.tsv"); REP=$M

# ── 8 sample ──────────────────────────────────────────────────────────────────
jq -n --argjson v "$M" --arg d "repeated=$M occurrences=$OCC window_days=$WIN recur_n=$RECUR" \
  '{agent:"archivist", metric:"causes_fixed_by_hand_twice", value:$v, detail:$d}' > "$WORK/sample.json"
if staff_metric_post "$WORK/sample.json" > "$WORK/sample.out" 2>/dev/null; then SAMPLE=ok; else SAMPLE=failed; fi

# ── 9 gate ────────────────────────────────────────────────────────────────────
if [ "$L" != file ] && [ "$L" != act ]; then WOULD=$M; summary; exit 0; fi
[ "$M" = 0 ] && { summary; exit 0; }

# ── 10 lists ──────────────────────────────────────────────────────────────────
if ! afi_issue_lists; then
  log "lists=unreadable; no action this run"; summary; exit 0
fi
FILED_TODAY=$(jq -s --arg d "$DAY" '[.[] | select((.created // "") | startswith($d))] | length' "$AFI_LBL")

# ── 11 per repeated cause ─────────────────────────────────────────────────────
WD=$WIN
while IFS=$'\t' read -r fp cnt c; do
  [ -n "$fp" ] || continue
  # a dedupe
  if [ -n "$(afi_issue_of "$fp")" ] || [ -n "$(afi_open_hit "$fp")" ]; then ALREADY=$((ALREADY + 1)); continue; fi
  # b cap
  if [ "$FILED_TODAY" -ge "$CAP" ]; then
    CAPPED=$((CAPPED + 1)); log "$fp: cap reached ($FILED_TODAY of $CAP issues today); it waits for the next UTC day"; continue
  fi
  # c record before act
  jq -n --arg fp "$fp" --argjson m "$M" --arg k "file:$fp:$DAY" --arg d "${c:0:200}" \
    '{agent:"archivist", lever:"file-ticket", target:$fp, dryRun:false, metric:"causes_fixed_by_hand_twice",
      metricBefore:$m, key:$k, detail:$d}' > "$WORK/action.json"
  JOBS_HTTP=""
  staff_action_post "$WORK/action.json" > "$WORK/action.out" 2>/dev/null; arc=$?
  case "$(arch_action_verdict "${JOBS_HTTP:-}" "$WORK/action.out" "$arc")" in
    run) ;;
    taken) TAKEN=$((TAKEN + 1)); log "$fp: the filing for $DAY is already recorded; not filed again"; continue ;;
    *) FAILED=$((FAILED + 1)); log "$fp: lever action not recorded (rc=$arc HTTP ${JOBS_HTTP:-none}); not filed"; continue ;;
  esac
  # d file
  occ=$(afi_occ_of "$fp" "$SINCE")
  pb=$(jq -r '.[-1].pb' <<<"$occ")
  {
    printf 'Archie fixed the same thing by hand %s times in the last %s days. The archivist files it once, so the factory fixes the cause.\n\n' "$cnt" "$WD"
    printf 'Cause: `%s`\n' "$c"
    printf 'Fingerprint: `%s`\n\n' "$fp"
    printf '## What happened\n\n'
    afi_occ_lines "$occ" 10
    printf '\n## Acceptance tests\n\n'
    printf -- '- A fixture that reproduces this cause (`%s`) is handled by the owning lane, and no `archie_actions` row of playbook `%s` is written for it.\n' "$c" "$pb"
    printf -- '- After the fix merges, the recurrence count of fingerprint `%s` stays 0. Archie checks that and reopens this issue if it comes back.\n\n' "$fp"
    printf 'Archie'"'"'s improve loop (bin/archie-fm-improve.sh) tracks this issue to its merged PR and checks the cause stopped.\n\n'
    afi_marker "$fp"; printf '\n'
  } | sed 's/—/-/g' > "$WORK/body.md"
  jq -n --arg t "Archivist: ${c:0:120} fixed by hand $cnt times in $WD days" --rawfile b "$WORK/body.md" \
    '{title: ($t | gsub("—"; "-")), body: $b, labels: ["ai-build", "archie-fm-improve", "staff:archivist"]}' > "$WORK/issue.json"
  : > "$WORK/created.json"
  GH_REST_STATUS=""
  rc=0; TRK_SLUG="$HARNESS_REPO" tracker_create "$WORK/issue.json" "$WORK/created.json" || rc=$?
  url=$(jq -r '.html_url // empty' "$WORK/created.json" 2>/dev/null)
  if [ "$rc" = 0 ] && [ "${GH_REST_STATUS:-}" = 201 ] && [ -n "$url" ]; then
    FILED=$((FILED + 1)); FILED_TODAY=$((FILED_TODAY + 1))
    log "$fp: filed $url ($c, $cnt in $WD days)"
  else
    FAILED=$((FAILED + 1))
    log "$fp: filing answered HTTP ${GH_REST_STATUS:-000} (rc=$rc); the ledger row stays, retried on a later UTC day"
  fi
done < "$WORK/repeated.tsv"

summary
exit 0
