#!/bin/bash
# bin/staff-outcomes.sh — BH-5563 (BH-5556.6): the staff outcome resolver. The
# hub lane staff-outcomes runs it hourly. It reads each filed staff finding's
# GitHub issue and posts the outcome to the worker, which closes the finding,
# demotes on an overrule and proposes promotions and noise suppressions
# (worker/jobs/src/routes/staff-outcomes.js). It makes no model call.
#
#   staff-outcomes.sh       one run (the cron line)
#
# A RUN, in this order:
#   1. KILL, before any read: flags/staff-off-all (flag_active) = one
#      `killed by staff-off-all` line in logs/staff-outcomes.log, exit 0.
#   2. lane_gate_or_exit / lane_env_apply staff-outcomes;
#      STAFF_OUTCOMES_ENABLED=0 exits; flock -n locks/staff-outcomes.lock (held
#      = skip, never wait). The whole run is under timeout 600 (D21).
#   3. The cursor state/staff-outcomes/cursor (an id, 0 when absent) is where
#      the read starts. GET /api/staff/outcomes/pending?after_id=<cursor> pages
#      the filed findings by id. An unreadable page = one log line, exit 0,
#      the cursor keeps what this run read. At the end of the list the cursor
#      goes back to 0, so a long list is read in rotation and never starved.
#   4. Per row: flags/staff-off-<agent> = skipped, no GitHub read. A
#      ticket_url that is not https://github.com/<o>/<r>/issues/<n> = skipped.
#      Else ONE gh_rest GET repos/<o>/<r>/issues/<n> (REST only). A non-2xx
#      answer (404 included) posts nothing: the row stays filed and is read
#      again next rotation. The issue maps to an outcome:
#        open                                   nothing posted (unresolved)
#        closed + label STAFF_NOISE_LABEL       noise (the label wins)
#        closed, state_reason completed         merged
#        closed, any other state_reason, null   rejected
#      The label match is exact after trim and lowercase.
#   5. POST /api/staff/outcomes {agent, fingerprint, outcome, ticket_url}.
#      Only a 200 counts as its outcome; a 200 existing:true counts as
#      replayed; a 409 is counted conflict and logged; any other failure is
#      counted failed and the next run posts it again (the route is
#      idempotent on the fingerprint). A new promotion or suppression id in
#      the answer is ONE line in logs/staff-digest.log.
#   6. At most STAFF_OUTCOMES_MAX GitHub reads per run; at the cap the cursor
#      is saved at the last id read.
#   7. One summary line when the run read or skipped a row:
#      read= merged= rejected= noise= unresolved= skipped= replayed= failed=
#      conflict= cursor=
#
# OFF: STAFF_OUTCOMES_ENABLED=0, flags/staff-off-all, flags/staff-off-<agent>
# for one agent's rows. Registry: catalog/lanes.d/staff-outcomes.json. Cron:
# cron/lanes/730-staff-outcomes.cron. Note:
# docs/notes/2026-10-14-BH-5563-staff-learning.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
NAME_RE='^[a-z][a-z0-9-]{1,39}$'
if [ "${STAFF_OUTCOMES_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  STAFF_OUTCOMES_TIMED=1 exec timeout 600 bash "$0" "$@"
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${STAFF_OUTCOMES_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$STAFF_OUTCOMES_FIXTURE"
fi
command -v _jobs_req >/dev/null 2>&1 && command -v _jobs_req_file >/dev/null 2>&1 \
  && command -v flag_active >/dev/null 2>&1 && command -v gh_rest >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { echo "staff-outcomes: jobs-client (_jobs_req, flag_active), gh_rest or jq missing" >&2; exit 1; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/staff-outcomes.log"
DIGEST="$H/logs/staff-digest.log"
nowiso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(nowiso)" "$*" >> "$LOG"; }

# ═════ KILL: the first thing a run does ══════════════════════════════════════
if flag_active staff-off-all; then log "killed by staff-off-all"; exit 0; fi

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit staff-outcomes
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply staff-outcomes

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
[ "$(knob_int STAFF_OUTCOMES_ENABLED "${STAFF_OUTCOMES_ENABLED:-1}" 1 0 1)" = 0 ] && exit 0
MAX=$(knob_int STAFF_OUTCOMES_MAX "${STAFF_OUTCOMES_MAX:-60}" 60 1 500)
LABEL=$(printf '%s' "${STAFF_NOISE_LABEL:-staff-noise}" | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
[ -n "$LABEL" ] || { log "warn: STAFF_NOISE_LABEL is blank; using the default staff-noise"; LABEL=staff-noise; }

exec 9>"$H/locks/staff-outcomes.lock" || exit 0
flock -n 9 || exit 0

ST="$H/state/staff-outcomes"
mkdir -p "$ST" || { log "cannot create $ST; nothing read"; exit 0; }
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/staff-outcomes.XXXXXX") || { log "mktemp failed; nothing read"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT
CUR=$(cat "$ST/cursor" 2>/dev/null)
[[ $CUR =~ ^[0-9]+$ ]] || CUR=0
START=$CUR

READ=0; MERGED=0; REJECTED=0; NOISE=0; UNRES=0; SKIPPED=0; REPLAYED=0; FAILEDN=0; CONFLICT=0
save_cursor() { printf '%s\n' "$1" > "$ST/cursor.tmp" && mv -f "$ST/cursor.tmp" "$ST/cursor"; }
finish() { # finish <cursor>: save it, then the one summary line
  save_cursor "$1"
  [ $((READ + SKIPPED)) -gt 0 ] || return 0
  log "read=$READ merged=$MERGED rejected=$REJECTED noise=$NOISE unresolved=$UNRES skipped=$SKIPPED replayed=$REPLAYED failed=$FAILEDN conflict=$CONFLICT cursor=$1"
}
ISSUE_RE='^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([0-9]+)$'

# resolve_row <json row>: one finding. Sets nothing on a skip.
resolve_row() {
  local r=$1 agent fp url issue out rc ans pid sid
  agent=$(jq -r '.agent // ""' <<<"$r"); fp=$(jq -r '.fingerprint // ""' <<<"$r"); url=$(jq -r '.ticket_url // ""' <<<"$r")
  if ! [[ $agent =~ $NAME_RE ]] || ! [[ $fp =~ ^[0-9a-f]{64}$ ]]; then
    log "row $(jq -r '.id' <<<"$r") is malformed; skipped"; SKIPPED=$((SKIPPED+1)); return 0
  fi
  if flag_active "staff-off-$agent"; then SKIPPED=$((SKIPPED+1)); return 0; fi
  if ! [[ $url =~ $ISSUE_RE ]]; then
    log "${fp:0:12} ticket_url is not a GitHub issue URL ($url); skipped"; SKIPPED=$((SKIPPED+1)); return 0
  fi
  READ=$((READ+1))
  rc=0
  # A plain call into a file, not $( ): GH_REST_STATUS must survive for the log line.
  gh_rest GET "repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/issues/${BASH_REMATCH[3]}" > "$TMPD/issue.json" 2>/dev/null || rc=$?
  issue=$(cat "$TMPD/issue.json" 2>/dev/null)
  if [ "$rc" != 0 ]; then
    log "${fp:0:12} issue read failed (rc=$rc HTTP ${GH_REST_STATUS:-}); retried next rotation"; UNRES=$((UNRES+1)); return 0
  fi
  out=$(jq -r --arg l "$LABEL" '
    if .state == "open" then "none"
    elif .state != "closed" then "none"
    elif ([.labels[]? | (if type == "object" then .name else . end) | strings
           | ascii_downcase | sub("^\\s+"; "") | sub("\\s+$"; "")] | index($l)) != null then "noise"
    elif .state_reason == "completed" then "merged"
    else "rejected" end' <<<"$issue" 2>/dev/null)
  case "$out" in
    merged|rejected|noise) ;;
    none) UNRES=$((UNRES+1)); return 0 ;;
    *) log "${fp:0:12} issue answer unparsable; retried next rotation"; UNRES=$((UNRES+1)); return 0 ;;
  esac
  jq -cn --arg a "$agent" --arg f "$fp" --arg o "$out" --arg u "$url" \
    '{agent: $a, fingerprint: $f, outcome: $o, ticket_url: $u}' > "$TMPD/post.json"
  rc=0
  ans=$(_jobs_req_file POST /api/staff/outcomes "$TMPD/post.json") || rc=$?
  case "$rc" in
    0) ;;
    9) log "${fp:0:12} $out answered 409 $(head -c 200 <<<"$ans")"; CONFLICT=$((CONFLICT+1)); return 0 ;;
    *) log "${fp:0:12} $out POST failed (rc=$rc); the next run posts it again"; FAILEDN=$((FAILEDN+1)); return 0 ;;
  esac
  if [ "$(jq -r '.ok // false' <<<"$ans" 2>/dev/null)" != true ]; then
    log "${fp:0:12} $out answer has no ok:true; the next run posts it again"; FAILEDN=$((FAILEDN+1)); return 0
  fi
  if [ "$(jq -r '.existing // false' <<<"$ans")" = true ]; then
    REPLAYED=$((REPLAYED+1))
  else
    case "$out" in
      merged) MERGED=$((MERGED+1)) ;;
      rejected) REJECTED=$((REJECTED+1)) ;;
      noise) NOISE=$((NOISE+1)) ;;
    esac
  fi
  pid=$(jq -r '.proposals.promotion_id // empty | numbers' <<<"$ans" 2>/dev/null)
  sid=$(jq -r '.proposals.suppression_id // empty | numbers' <<<"$ans" 2>/dev/null)
  [ -n "$pid" ] && printf '%s proposal promotion id=%s agent=%s to=%s fp=%s\n' "$(nowiso)" "$pid" "$agent" \
    "$(jq -r '.proposals.promotion_to // "?"' <<<"$ans")" "${fp:0:12}" >> "$DIGEST"
  [ -n "$sid" ] && printf '%s proposal suppression id=%s agent=%s class=%s fp=%s\n' "$(nowiso)" "$sid" "$agent" \
    "$(jq -r '.class // "?"' <<<"$ans")" "${fp:0:12}" >> "$DIGEST"
  return 0
}

# ═════ page the filed list from the cursor ═══════════════════════════════════
while :; do
  page=$(_jobs_req GET "/api/staff/outcomes/pending?after_id=$CUR&limit=50"); rc=$?
  if [ "$rc" != 0 ] || ! jq -e '.findings | type == "array"' <<<"$page" >/dev/null 2>&1; then
    log "pending list unreadable (rc=$rc) after_id=$CUR; stopped"
    [ "$CUR" = "$START" ] || finish "$CUR"
    exit 0
  fi
  jq -c '.findings[]' <<<"$page" > "$TMPD/rows"
  if [ ! -s "$TMPD/rows" ]; then finish 0; exit 0; fi
  while IFS= read -r r; do
    resolve_row "$r"
    id=$(jq -r '.id' <<<"$r")
    [[ $id =~ ^[0-9]+$ ]] && CUR=$id
    if [ "$READ" -ge "$MAX" ]; then finish "$CUR"; exit 0; fi
  done < "$TMPD/rows"
  if [ "$(jq -r '.truncated' <<<"$page")" != true ]; then finish 0; exit 0; fi
done
