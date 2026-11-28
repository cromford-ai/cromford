#!/bin/bash
# bin/staff-dispatcher-lever.sh — BH-9421 (BH-9187 C3): the dispatcher pilot.
# The hub lane staff-dispatcher-lever runs it every 15 minutes. It samples the
# dispatcher's metric ready_unqueued_2h and, only at level `act`, pulls the
# dispatcher's two levers through the existing queue API. It makes no model
# call and no GitHub call.
#
#   staff-dispatcher-lever.sh      one run (the cron line)
#
# THE METRIC ready_unqueued_2h = R + C:
#   R  build_queue rows in status `ready` whose enqueued_at is at least
#      STAFF_DSP_READY_AGE_MIN (120) minutes before the worker's as_of.
#   C  build_queue rows in status `claimed` whose claimed_at is at least
#      STAFF_DSP_CLAIM_AGE_MIN (30) minutes before as_of, with no `running`
#      job of kind `build` in the same project for the row's ticket_key (or
#      its ticket_id).
#
# A RUN, in this order:
#   1. KILL, before any read: flags staff-off-all, staff-kill-all,
#      staff-off-dispatcher, staff-kill-dispatcher (flag_active) = one
#      `killed by <flag>` line, exit 0.
#   2. lane_gate_or_exit / lane_env_apply staff-dispatcher-lever;
#      STAFF_DSP_LEVER_ENABLED=0 exits; flock -n locks/staff-dispatcher-lever.lock
#      (held = exit 0, never wait). The whole run is under timeout STAFF_DSP_RUN_TIMEOUT_S (D21).
#   3. GET /api/staff/agent?name=dispatcher: status not `active` = one line, exit.
#   4. Level: staff_level dispatcher (bin/lib/staff-contract.sh; rc 3 = the
#      fallback observe, logged level_fallback=1). Metric name: the row
#      staff.dispatcher.metric.
#   5. THREE reads: GET /api/queue?status=ready&limit=500,
#      GET /api/queue?status=claimed&limit=500 and
#      GET /api/jobs?status=running&kind=build&limit=500. A failed or
#      non-JSON read = one `unreadable` line, no sample, no action. An answer
#      that holds 500 rows is incomplete (D12): one `incomplete` line, no
#      sample, no action. The claimed read sends no stale_min, because the
#      worker filters stale_min AFTER its LIMIT and a truncated answer would
#      then look complete; the age is computed here against as_of.
#   6. POST /api/staff/levers/metric {agent, metric, value: R+C, detail}. A
#      failed post is one line; the run goes on.
#   7. Level `act` only, STAFF_DSP_LEVER_MAX > 0: candidates are the C rows by
#      claimed_at, then the R rows by enqueued_at. Up to STAFF_DSP_LEVER_MAX
#      NEW action rows per run; the rest is `deferred` to the next run.
#        enqueue guard (R rows), before any action row: a running build job
#        for the key, or `bin/triage-gate.sh <p> --buildable-strict <id>` not
#        printing exactly OK within STAFF_DSP_GATE_TIMEOUT_S = declined: one
#        line, no action row.
#        release guard (C rows), before any action row (BH-9421 lead BLOCK):
#        GET /api/jobs?project=<p>&ticket_id=<key>&kind=build&limit=50 (and
#        the same for the ticket_id when it differs). On the fly path the hub
#        claims the row and fly-pool closes it only when it collects the
#        result, so a FINISHED build leaves the row `claimed` with no running
#        job. A build job opened at or after claimed_at, whatever its status,
#        or any build job that finished less than STAFF_DSP_FINISH_GRACE_MIN
#        (20, two fly-pool cycles) before as_of, or a failed read = declined:
#        one line, no action row.
#        Action row FIRST: POST /api/staff/levers/actions with key
#        `<lever>|<dry|live>|<p>/<key>|<claimed_at|enqueued_at>`. 200 = new;
#        200 existing:true or 409 key_mismatch = `seen`, no queue write; any
#        other answer = `failed`, no queue write.
#        STAFF_DSP_LEVER_DRY_RUN=1 (the default) stops there. Else
#        release = queue_release_counted (PATCH /api/queue, count_attempt),
#        enqueue = queue_put (POST /api/queue, no status: promotes a ready row).
#   8. One summary line per run that read: level= metric= value= ready=
#      claimed_orphan= actions_new= seen= declined= failed= dry_run=
#      released= enqueued= deferred=
#
# OFF: STAFF_DSP_LEVER_ENABLED=0, the four kill flags, or the level row
# staff.dispatcher.level at observe (the C0 seed). Registry:
# catalog/lanes.d/staff-dispatcher-lever.json. Cron:
# cron/lanes/729-staff-dispatcher-lever.cron. Note:
# docs/notes/2026-11-10-BH-9421-dispatcher-lever.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
AGENT=dispatcher
METRIC_RE='^[a-z][a-z0-9_]{0,63}$'
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/staff-contract.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${STAFF_DSP_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$STAFF_DSP_FIXTURE"
fi
for f in _jobs_req flag_active setting_get queue_put queue_release_counted staff_level staff_action_post staff_metric_post jq; do
  command -v "$f" >/dev/null 2>&1 || { echo "staff-dispatcher-lever: $f missing (jobs-client, staff-contract or jq)" >&2; exit 1; }
done

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/staff-dispatcher-lever.log"
nowiso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(nowiso)" "$*" >> "$LOG"; }

# ═════ KILL: the first thing a run does ══════════════════════════════════════
for f in staff-off-all staff-kill-all "staff-off-$AGENT" "staff-kill-$AGENT"; do
  if flag_active "$f"; then log "killed by $f"; exit 0; fi
done

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit staff-dispatcher-lever
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply staff-dispatcher-lever

# knob_int <name> <value> <default> <min> <max>: out of range is one warn line
# and the default, never a silent clamp (D11). Each default is the registry
# knob of the same name (catalog/lanes.d/staff-dispatcher-lever.json).
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    log "warn: $1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}
[ "$(knob_int STAFF_DSP_LEVER_ENABLED "${STAFF_DSP_LEVER_ENABLED:-1}" 1 0 1)" = 0 ] && exit 0
READY_MIN=$(knob_int STAFF_DSP_READY_AGE_MIN "${STAFF_DSP_READY_AGE_MIN:-120}" 120 1 10080)
CLAIM_MIN=$(knob_int STAFF_DSP_CLAIM_AGE_MIN "${STAFF_DSP_CLAIM_AGE_MIN:-30}" 30 5 1440)
MAX=$(knob_int STAFF_DSP_LEVER_MAX "${STAFF_DSP_LEVER_MAX:-3}" 3 0 50)
DRY=$(knob_int STAFF_DSP_LEVER_DRY_RUN "${STAFF_DSP_LEVER_DRY_RUN:-1}" 1 0 1)
GATE_T=$(knob_int STAFF_DSP_GATE_TIMEOUT_S "${STAFF_DSP_GATE_TIMEOUT_S:-60}" 60 5 300)
GRACE=$(knob_int STAFF_DSP_FINISH_GRACE_MIN "${STAFF_DSP_FINISH_GRACE_MIN:-20}" 20 10 1440)
# The whole run is under this timeout. It re-execs after lane_env_apply so the
# settings row lane.staff-dispatcher-lever.staff_dsp_run_timeout_s applies;
# 600 is the documented fallback (the registry default).
RUN_T=$(knob_int STAFF_DSP_RUN_TIMEOUT_S "${STAFF_DSP_RUN_TIMEOUT_S:-600}" 600 60 3600)
if [ "${STAFF_DSP_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  STAFF_DSP_TIMED=1 exec timeout "$RUN_T" bash "$0" "$@"
fi
# The worker's own page cap on GET /api/queue and GET /api/jobs (queue.js,
# jobs.js: Math.min(..., 500)). An answer this long may hold more rows.
PAGE=500

exec 9>"$H/locks/staff-dispatcher-lever.lock" || exit 0
flock -n 9 || exit 0

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/staff-dsp-lever.XXXXXX") || { log "mktemp failed; nothing read"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT

# ═════ roster, level, metric name ════════════════════════════════════════════
row=$(_jobs_req GET "/api/staff/agent?name=$AGENT" 9>&-); rc=$?
if [ "$rc" != 0 ]; then log "roster row unreadable (rc=$rc); nothing read"; exit 0; fi
st=$(jq -r '.agent.status // ""' <<<"$row" 2>/dev/null)
if [ "$st" != active ]; then log "roster status '$st' is not active; nothing read"; exit 0; fi

LEVEL=$(staff_level "$AGENT" 9>&-); LRC=$?
LFB=""; [ "$LRC" = 0 ] || LFB=" level_fallback=1"
# The metric name is the row staff.dispatcher.metric (C0 seed); the fallback
# is that seed's value.
METRIC=$(setting_get "staff.$AGENT.metric" 9>&- 2>/dev/null) || METRIC=""
METRIC="${METRIC//[[:space:]]/}"
[[ $METRIC =~ $METRIC_RE ]] || METRIC=ready_unqueued_2h

# ═════ the three reads ═══════════════════════════════════════════════════════
read_list() { # read_list <name> <path> <array field>
  local out="$TMPD/$1.json" rc=0
  _jobs_req GET "$2" > "$out" 9>&- 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || ! jq -e --arg f "$3" '(.[$f] | type == "array") and (.as_of | type == "string")' "$out" >/dev/null 2>&1; then
    log "unreadable: $1 (GET $2 rc=$rc); no sample, no action"; exit 0
  fi
  if [ "$(jq --arg f "$3" '.[$f] | length' "$out")" -ge "$PAGE" ]; then
    log "incomplete: $1 holds $PAGE rows (the page cap); no sample, no action"; exit 0
  fi
}
read_list ready "/api/queue?status=ready&limit=$PAGE" queue
read_list claimed "/api/queue?status=claimed&limit=$PAGE" queue
read_list jobs "/api/jobs?status=running&kind=build&limit=$PAGE" jobs

# One jq pass: the candidates, each with its age decided on the worker's clock.
# A stamp jq cannot parse is never counted (it is not an age).
jq -n --slurpfile r "$TMPD/ready.json" --slurpfile c "$TMPD/claimed.json" --slurpfile j "$TMPD/jobs.json" \
  --argjson rmin "$READY_MIN" --argjson cmin "$CLAIM_MIN" '
  def ep: if type == "string" then (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) else null end;
  def nz: if . == null then "" else tostring end;
  [$j[0].jobs[] | select(.status == "running" and .kind == "build") | "\(.project)|\(.ticket_id | nz)"] as $run
  | def running($q): ($run | index("\($q.project)|\($q.ticket_key)")) != null
      or (($q.ticket_id | nz) != "" and ($run | index("\($q.project)|\($q.ticket_id | nz)")) != null);
  ($r[0].as_of | ep) as $rn | ($c[0].as_of | ep) as $cn
  | {
      claimed: [$c[0].queue[] | select(.status == "claimed") | (.claimed_at | ep) as $e
        | select($e != null and $cn != null and ($cn - $e) >= $cmin * 60) | select(running(.) | not)
        | {lever: "release", project, key: .ticket_key, id: (.ticket_id | nz), stamp: .claimed_at,
           by: (.claimed_by | nz), age: ((($cn - $e) / 60) | floor), running: false}]
        | sort_by(.stamp),
      ready: [$r[0].queue[] | select(.status == "ready") | (.enqueued_at | ep) as $e
        | select($e != null and $rn != null and ($rn - $e) >= $rmin * 60)
        | {lever: "enqueue", project, key: .ticket_key, id: (.ticket_id | nz), stamp: .enqueued_at,
           by: "", age: ((($rn - $e) / 60) | floor), running: running(.)}]
        | sort_by(.stamp)
    }' > "$TMPD/cand.json" 2>/dev/null \
  || { log "unreadable: candidate pass failed; no sample, no action"; exit 0; }
R=$(jq '.ready | length' "$TMPD/cand.json"); C=$(jq '.claimed | length' "$TMPD/cand.json")
VALUE=$((R + C))

# ═════ the sample, at every level ════════════════════════════════════════════
jq -cn --arg a "$AGENT" --arg m "$METRIC" --argjson v "$VALUE" --argjson r "$R" --argjson c "$C" \
  --argjson ra "$READY_MIN" --argjson ca "$CLAIM_MIN" \
  '{agent: $a, metric: $m, value: $v,
    detail: ({ready: $r, claimed_orphan: $c, ready_age_min: $ra, claim_age_min: $ca} | tojson)}' > "$TMPD/metric.json"
rc=0; ans=$(staff_metric_post "$TMPD/metric.json" 9>&-) || rc=$?
if [ "$rc" != 0 ] || [ "$(jq -r '.ok // false' <<<"$ans" 2>/dev/null)" != true ]; then
  log "metric post failed (rc=$rc); the sample is lost for this run"
fi

NEW=0; SEEN=0; DECL=0; FAILN=0; RELEASED=0; ENQUEUED=0; DEFERRED=0
DRYW=false; [ "$DRY" = 1 ] && DRYW=true
summary() {
  log "level=$LEVEL$LFB metric=$METRIC value=$VALUE ready=$R claimed_orphan=$C actions_new=$NEW seen=$SEEN declined=$DECL failed=$FAILN dry_run=$DRY released=$RELEASED enqueued=$ENQUEUED deferred=$DEFERRED"
}
if [ "$LEVEL" != act ] || [ "$MAX" = 0 ] || [ "$VALUE" = 0 ]; then summary; exit 0; fi

# release_busy <p> <key> <id> <claimed_at>: prints why the release must wait,
# or nothing. A job read it cannot use is a reason (fail closed).
CASOF=$(jq -r .as_of "$TMPD/claimed.json")
release_busy() {
  local q f="$TMPD/keyjobs.json" rc
  : > "$TMPD/keyjobs.all"
  for q in "$2" "$3"; do
    [ -n "$q" ] || continue
    [ "$q" = "$3" ] && [ "$3" = "$2" ] && continue   # the id is the key: read once
    rc=0
    _jobs_req GET "/api/jobs?project=$(jq -rn --arg v "$1" '$v|@uri')&ticket_id=$(jq -rn --arg v "$q" '$v|@uri')&kind=build&limit=50" > "$f" 9>&- 2>/dev/null || rc=$?
    if [ "$rc" != 0 ] || ! jq -e '.jobs | type == "array"' "$f" >/dev/null 2>&1; then
      printf 'build job read for %s failed (rc=%s)' "$q" "$rc"; return 0
    fi
    jq -c '.jobs[]' "$f" >> "$TMPD/keyjobs.all"
  done
  jq -rs --arg s "$4" --arg now "$CASOF" --argjson g "$GRACE" '
    def ep: if type == "string" then (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) else null end;
    ($s | ep) as $se | ($now | ep) as $n
    | [.[] | select(.kind == "build")
        | ((.created_at | ep) // 1e18) as $ce | ((.updated_at | ep) // $n) as $ue
        | if .status == "running" then "running build job \(.id)"
          elif $se == null or $ce >= $se then "build job \(.id) opened after the claim (\(.status)); fly-pool closes the row"
          elif $n == null or $ue > ($n - $g * 60) then "build job \(.id) finished \((($n - $ue) / 60) | floor)m ago, inside the \($g)m collect grace"
          else empty end] | first // ""' "$TMPD/keyjobs.all" 2>/dev/null \
    || printf 'build job check failed'
}

# ═════ the lever: claims first, then ready rows ══════════════════════════════
jq -c '.claimed[], .ready[]' "$TMPD/cand.json" > "$TMPD/rows"
TOTAL=$(wc -l < "$TMPD/rows"); DONE=0
while IFS= read -r c; do
  [ "$NEW" -lt "$MAX" ] || break
  DONE=$((DONE + 1))
  lever=$(jq -r .lever <<<"$c"); p=$(jq -r .project <<<"$c"); k=$(jq -r .key <<<"$c")
  id=$(jq -r .id <<<"$c"); stamp=$(jq -r .stamp <<<"$c"); age=$(jq -r .age <<<"$c"); by=$(jq -r .by <<<"$c")
  if [ "$lever" = release ]; then
    why=$(release_busy "$p" "$k" "$id" "$stamp")
    if [ -n "$why" ]; then
      log "declined release $p/$k: $(printf '%s' "$why" | tr '\n' ' ' | cut -c1-120)"
      DECL=$((DECL + 1)); continue
    fi
  fi
  if [ "$lever" = enqueue ]; then
    if [ "$(jq -r .running <<<"$c")" = true ]; then
      log "declined enqueue $p/$k: running build job"; DECL=$((DECL + 1)); continue
    fi
    out=""
    [ -x "$H/bin/triage-gate.sh" ] \
      && out=$(timeout "$GATE_T" "$H/bin/triage-gate.sh" "$p" --buildable-strict "${id:-$k}" 9>&- 2>/dev/null)
    if [ "$out" != OK ]; then
      [ -x "$H/bin/triage-gate.sh" ] || out="triage-gate.sh missing"
      log "declined enqueue $p/$k: gate: $(printf '%s' "${out:-no answer}" | tr '\n' ' ' | cut -c1-80)"
      DECL=$((DECL + 1)); continue
    fi
  fi
  mode=live; [ "$DRY" = 1 ] && mode=dry
  jq -cn --arg a "$AGENT" --arg l "$lever" --arg t "$p/$k" --argjson d "$DRYW" --arg m "$METRIC" \
    --argjson b "$VALUE" --arg key "$lever|$mode|$p/$k|$stamp" --argjson age "$age" --arg by "$by" \
    '{agent: $a, lever: $l, target: $t, dryRun: $d, metric: $m, metricBefore: $b, key: $key,
      detail: ({age_min: $age} + (if $by == "" then {} else {claimed_by: $by} end) | tojson)}' > "$TMPD/action.json"
  rc=0; ans=$(staff_action_post "$TMPD/action.json" 9>&-) || rc=$?
  if [ "$rc" = 9 ] && [ "$(jq -r '.error // ""' <<<"$ans" 2>/dev/null)" = key_mismatch ]; then
    SEEN=$((SEEN + 1)); continue
  fi
  if [ "$rc" != 0 ] || [ "$(jq -r '.ok // false' <<<"$ans" 2>/dev/null)" != true ]; then
    log "action post $lever $p/$k failed (rc=$rc); no queue write"; FAILN=$((FAILN + 1)); continue
  fi
  if [ "$(jq -r '.existing // false' <<<"$ans")" = true ]; then SEEN=$((SEEN + 1)); continue; fi
  NEW=$((NEW + 1))
  [ "$DRY" = 1 ] && continue
  if [ "$lever" = release ]; then
    rc=0; q=$(queue_release_counted "$p" "$k" "staff dispatcher: claimed by ${by:-?} at $stamp, no running build job for ${age}m" 9>&-) || rc=$?
    case "$rc:$q" in
      0:queued*) RELEASED=$((RELEASED + 1)) ;;
      0:failed*) log "release-cap $p/$k: $q (queue.release_attempt_max); the row is failed, not requeued" ;;
      *) log "lever release $p/$k failed after record (rc=$rc ${q:-no answer})" ;;
    esac
  else
    rc=0; q=$(queue_put "$p" "$k" "$id" "" "" '{"staff_dispatcher":"enqueue"}' 9>&-) || rc=$?
    case "$rc:$q" in
      0:queued) ENQUEUED=$((ENQUEUED + 1)) ;;
      0:duplicate) log "enqueue $p/$k: duplicate (another lane took it first)" ;;
      *) log "lever enqueue $p/$k failed after record (rc=$rc ${q:-no answer})" ;;
    esac
  fi
done < "$TMPD/rows"
DEFERRED=$((TOTAL - DONE))
summary
exit 0
