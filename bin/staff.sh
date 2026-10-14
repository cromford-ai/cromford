#!/bin/bash
# bin/staff.sh — BH-5561 (BH-5556.4): the generic staff heartbeat. One script
# runs every staff agent on the roster (worker/jobs/schema.d/0010: staff_agents);
# what makes an agent different is its soul (prompts/staff/<name>-soul.md), its
# collector (bin/staff/<name>-collect.sh) and its roster row.
#
#   staff.sh tick <agent>   one heartbeat for one agent
#   staff.sh tick-all       the hub cron line: one tick per active agent, each
#                           in its own process, one after the other
#
# TICK, in this order:
#   1. <agent> must match ^[a-z][a-z0-9-]{1,39}$ (else rc 2). The tick runs
#      under timeout 600 (D21).
#   2. KILL, before any read: flags/staff-off-all, then flags/staff-off-<agent>
#      (flag_active: the pause_flags row decides, the file when there is no
#      row). Set = one `killed by <flag>` line in logs/staff.log, exit 0. No
#      roster read, collector, claim, model call or gh call comes before this.
#   3. lane_gate_or_exit / lane_env_apply staff; STAFF_ENABLED=0 exits; flock -n
#      locks/staff-<agent>.lock (held = skip, never wait).
#   4. GET /api/staff/agent?name=<agent>. Unreadable or not active: exit 0.
#   5. The soul must pass the agent-core parser (bin/staff-core.mjs soul). A
#      soul that fails is one log line and one warn beat (id staff-soul-<agent>).
#   6. COLLECT: bin/staff/<agent>-collect.sh prints JSONL, one item per line:
#      {"item":…, "title":…, "source":{"kind","url","labels"[,"filedBy"]},
#      "observedAt":…[, "class":…]}. Absent = 0 items, silent. rc != 0 =
#      unreadable, nothing claimed. A malformed line is counted and skipped; a
#      line with a staff:* label is dropped (output is never input). At most
#      STAFF_MAX_ITEMS lines are claimed; the rest come back next tick
#      (logged deferred=<n>).
#   7. CLAIM each line (POST /api/staff/findings/claim) BEFORE any spend. New =
#      200. Our own row still `claimed` = PENDING. Another agent's claim,
#      suppressed or staff_filed = dropped. agent_not_active stops the tick.
#   8. PENDING with state/staff/<agent>/acted/<fp>.json: the act already
#      happened and only the record was lost; the record is re-posted, nothing
#      else. PENDING with state/staff/<agent>/held/<fp>.json: the model already
#      decided `file a ticket` and GitHub refused the filing; only the filing
#      is retried (step 11), with no model call and no attempt count. PENDING
#      with neither joins the new set.
#   9. An item already at STAFF_MAX_ATTEMPTS model calls is recorded failed. If
#      nothing new is left the tick ends here, with 0 model calls.
#  10. Model route stage.staff-tick (model_routes; no route = no call, the
#      items stay claimed). ONE stage for every agent (the operator, 2026-10-12): the
#      agent rides as STAFF_AGENT and in AGENT_CALL_FP, never in the stage.
#      The attempt counters are written BEFORE the call. ONE agent-call, stage
#      staff-tick, project fleet, lane staff, budget STAFF_LLM_MAX_USD (as
#      AGENT_CALL_BUDGET_USD_STAFF_TICK). rc != 0: nothing recorded, retried next tick up to
#      the attempt cap. rc 0 with no parsable answer: billed and terminal,
#      every item recorded failed.
#  11. DECIDE per item with agent-core (bin/staff-core.mjs decide):
#      NEVER match = refused + ONE warn beat (id staff-never-<agent>-<fp12>);
#      refuse (automation, or the level above the cap) = one digest line in
#      logs/staff-digest.log; ask/allow on `file a ticket` = ONE GitHub issue
#      in STAFF_FILE_REPO, label staff:<agent>, body marker
#      <!-- staff-fp:<fp> --> (an open issue with the marker is reused, never
#      duplicated; a list that cannot be read files nothing); ask/allow on any
#      other action = digest line, verdict=unsupported. A filing GitHub
#      refuses (list unreadable, create not 201) is HELD: the decision goes to
#      state/staff/<agent>/held/<fp>.json, and later ticks retry the filing
#      from it with no model call until it files. A GitHub outage never buys a
#      second model call and never ends as `failed`.
#  12. The outcome goes to state/staff/<agent>/acted/<fp>.json first, then to
#      POST /api/staff/findings/record.
#  13. One summary line in logs/staff.log per tick that had work.
#
# OFF: STAFF_ENABLED=0, flags/staff-off-all, flags/staff-off-<agent>.
# Registry: catalog/lanes.d/staff.json. Cron: cron/lanes/729-staff.cron.
# Note: docs/notes/2026-10-10-BH-5561-staff-heartbeat.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-}"
AGENT="${2:-}"
NAME_RE='^[a-z][a-z0-9-]{1,39}$'
case "$MODE" in
  tick) [[ $AGENT =~ $NAME_RE ]] || { echo "staff: bad agent name '$AGENT'" >&2; exit 2; } ;;
  tick-all) ;;
  *) echo "usage: staff.sh tick <agent> | tick-all" >&2; exit 2 ;;
esac
if [ "$MODE" = tick ] && [ "${STAFF_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  STAFF_TIMED=1 exec timeout 600 bash "$0" "$@"
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
  . "$SELF/lib/lane-model.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest-list.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${STAFF_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$STAFF_FIXTURE"
fi
command -v _jobs_req >/dev/null 2>&1 && command -v _jobs_req_file >/dev/null 2>&1 \
  && command -v flag_active >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { echo "staff: jobs-client (_jobs_req, flag_active) or jq missing" >&2; exit 1; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/staff.log"
DIGEST="$H/logs/staff-digest.log"
nowiso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s agent=%s %s\n' "$(nowiso)" "${AGENT:-all}" "$*" >> "$LOG"; }

# ═════ KILL: the first thing either mode does ════════════════════════════════
if flag_active staff-off-all; then log "killed by staff-off-all"; exit 0; fi

if [ "$MODE" = tick-all ]; then
  roster=$(_jobs_req GET /api/staff/agents) || { log "roster unreadable (GET /api/staff/agents); nothing ran"; exit 0; }
  names=$(jq -r '.agents[]? | select(.status == "active") | .name' <<<"$roster" 2>/dev/null) \
    || { log "roster unparsable; nothing ran"; exit 0; }
  for n in $names; do
    [[ $n =~ $NAME_RE ]] || { log "roster name '$n' is not a valid agent name; skipped"; continue; }
    bash "$0" tick "$n"
  done
  exit 0
fi

if flag_active "staff-off-$AGENT"; then log "killed by staff-off-$AGENT"; exit 0; fi

# ═════ gate, knobs, lock ═════════════════════════════════════════════════════
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit staff
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply staff

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
[ "$(knob_int STAFF_ENABLED "${STAFF_ENABLED:-1}" 1 0 1)" = 0 ] && exit 0
MAX_ITEMS=$(knob_int STAFF_MAX_ITEMS "${STAFF_MAX_ITEMS:-20}" 20 1 100)
MAX_ATT=$(knob_int STAFF_MAX_ATTEMPTS "${STAFF_MAX_ATTEMPTS:-2}" 2 1 10)
COLLECT_T=$(knob_int STAFF_COLLECT_TIMEOUT_S "${STAFF_COLLECT_TIMEOUT_S:-120}" 120 10 600)
USD="${STAFF_LLM_MAX_USD:-0.60}"
if ! [[ $USD =~ ^[0-9]+(\.[0-9]+)?$ ]]; then log "warn: STAFF_LLM_MAX_USD=$USD is not a number; using the default 0.60"; USD=0.60; fi
# BH-4080: the harness repo's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" || exit 1
REPO="${STAFF_FILE_REPO:-$HARNESS_REPO}"
if ! [[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then log "warn: STAFF_FILE_REPO=$REPO is not owner/repo; using $HARNESS_REPO"; REPO=$HARNESS_REPO; fi

exec 9>"$H/locks/staff-$AGENT.lock" || exit 0
flock -n 9 || exit 0

STATE="$H/state/staff/$AGENT"
mkdir -p "$STATE/acted" "$STATE/attempts" "$STATE/held" || { log "cannot create $STATE; nothing claimed"; exit 0; }
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/staff.XXXXXX") || { log "mktemp failed; nothing claimed"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT

# ═════ roster row and soul ═══════════════════════════════════════════════════
row=$(_jobs_req GET "/api/staff/agent?name=$AGENT"); rc=$?
case "$rc" in
  0) ;;
  2) log "not on the staff roster (404); nothing ran"; exit 0 ;;
  *) log "roster row unreadable (rc=$rc); nothing ran"; exit 0 ;;
esac
STATUS=$(jq -r '.agent.status // ""' <<<"$row" 2>/dev/null)
LEVEL=$(jq -r '.agent.autonomy // ""' <<<"$row" 2>/dev/null)
CAP=$(jq -r '.agent.cap // ""' <<<"$row" 2>/dev/null)
SOUL=$(jq -r '.agent.soul // ""' <<<"$row" 2>/dev/null)
[ "$STATUS" = active ] || exit 0

command -v node >/dev/null 2>&1 || { log "node is not installed; the soul cannot be read; nothing ran"; exit 0; }
soul_fail() {
  log "soul $SOUL failed the agent-core parser: $1; nothing ran"
  "$H/bin/lane-alert.sh" --id "staff-soul-$AGENT" --severity warn staff \
    "$AGENT soul $SOUL failed the agent-core parser: $1" >/dev/null 2>&1 || true
  exit 0
}
case "$SOUL" in
  prompts/*.md) [[ $SOUL == *..* ]] && soul_fail "the path leaves the harness" ;;
  *) soul_fail "the roster names no soul under prompts/" ;;
esac
SJ=$(node "$SELF/staff-core.mjs" soul "$H/$SOUL" 2>/dev/null) || soul_fail "staff-core.mjs did not run"
[ "$(jq -r '.ok' <<<"$SJ" 2>/dev/null)" = true ] || soul_fail "$(jq -r '.errors | join("; ")' <<<"$SJ" 2>/dev/null)"
NEVER=$(jq -c '.never' <<<"$SJ")

# ═════ collect ═══════════════════════════════════════════════════════════════
COL="$H/bin/staff/$AGENT-collect.sh"
[ -x "$COL" ] || exit 0
crc=0
timeout "$COLLECT_T" "$COL" > "$TMPD/raw" 2>/dev/null || crc=$?
if [ "$crc" != 0 ]; then log "collector rc=$crc; nothing claimed"; exit 0; fi
# One classified line per input line: ok, staff (a staff:* label) or bad.
grep -v '^[[:space:]]*$' "$TMPD/raw" | jq -cR '
  (try fromjson catch null) as $o
  | if ($o | type) != "object" or $o.item == null then {k: "bad"}
    elif ([$o.source.labels[]? | strings | ascii_downcase | ltrimstr(" ") | startswith("staff:")] | any) then {k: "staff"}
    else {k: "ok", o: $o} end' > "$TMPD/class" 2>/dev/null
BADN=$(grep -c '"k":"bad"' "$TMPD/class")
STAFFN=$(grep -c '"k":"staff"' "$TMPD/class")
jq -c 'select(.k == "ok") | .o' "$TMPD/class" > "$TMPD/items"
TOTAL=$(grep -c . "$TMPD/items")
DEFERRED=0
[ "$TOTAL" -gt "$MAX_ITEMS" ] && DEFERRED=$((TOTAL - MAX_ITEMS))
[ "$BADN" -gt 0 ] && log "collector printed $BADN malformed line(s); skipped"
[ "$STAFFN" -gt 0 ] && log "dropped $STAFFN staff-filed item(s) before the claim"

# ═════ claim ═════════════════════════════════════════════════════════════════
COLLECTED=0; NEWN=0; PENDN=0; REPLAYED=0; CALLS=0
DIGESTED=0; FILED=0; REFUSED=0; UNSUPPORTED=0; FAILED=0; HELD=0
# A tick that claimed nothing of its own writes no line.
summary() {
  [ $((NEWN + PENDN + DEFERRED + BADN)) -gt 0 ] || return 0
  log "level=$LEVEL collected=$COLLECTED new=$NEWN pending=$PENDN replayed=$REPLAYED deferred=$DEFERRED model_calls=$CALLS digested=$DIGESTED filed=$FILED refused=$REFUSED unsupported=$UNSUPPORTED failed=$FAILED held=$HELD"
}
: > "$TMPD/new"
while IFS= read -r line; do
  COLLECTED=$((COLLECTED+1))
  jq -c --arg a "$AGENT" '{agent: $a, item, title, source, observedAt}' <<<"$line" > "$TMPD/claim.json"
  resp=$(_jobs_req_file POST /api/staff/findings/claim "$TMPD/claim.json"); rc=$?
  fp=$(jq -r '.fingerprint // ""' <<<"$resp" 2>/dev/null)
  state=""
  case "$rc" in
    0) state=new ;;
    9)
      case "$(jq -r '.error // ""' <<<"$resp" 2>/dev/null)" in
        already_claimed)
          [ "$(jq -r '"\(.finding.agent)/\(.finding.status)"' <<<"$resp" 2>/dev/null)" = "$AGENT/claimed" ] && state=pending ;;
        suppressed|staff_filed) ;;
        agent_not_active) log "the claim says the agent is not active; tick stopped, claimed items stay claimed"; summary; exit 0 ;;
        *) log "claim answered 409 $(head -c 200 <<<"$resp"); skipped" ;;
      esac ;;
    *) log "claim failed (rc=$rc); the item comes back next tick" ;;
  esac
  [ -n "$state" ] || continue
  [[ $fp =~ ^[0-9a-f]{64}$ ]] || { log "claim answered no fingerprint; skipped"; continue; }
  if [ "$state" = pending ]; then
    PENDN=$((PENDN+1))
    if [ -f "$STATE/acted/$fp.json" ]; then
      jq -c --arg a "$AGENT" --arg f "$fp" '{agent: $a, fingerprint: $f} + .' "$STATE/acted/$fp.json" > "$TMPD/rec.json"
      _jobs_req_file POST /api/staff/findings/record "$TMPD/rec.json" >/dev/null \
        && REPLAYED=$((REPLAYED+1)) || log "record replay ${fp:0:12} failed (rc=$?)"
      continue
    fi
    # A decided filing GitHub refused: retry the filing only, no model call.
    if [ -s "$STATE/held/$fp.json" ]; then printf '%s\n' "$fp" >> "$TMPD/held"; continue; fi
  else
    NEWN=$((NEWN+1))
  fi
  jq -c --arg f "$fp" '{fingerprint: $f, title, class: (.class // .source.kind), source, item}' <<<"$line" >> "$TMPD/new"
done < <(head -n "$MAX_ITEMS" "$TMPD/items")

# finish <fp> <outcome> <class> <recommendation> [ticket_url mode]: the acted
# file first, then the record. A lost record replays from the acted file.
finish() {
  local fp=$1
  jq -cn --arg o "$2" --arg c "$3" --arg r "$4" --arg u "${5:-}" --arg m "${6:-}" '
    {outcome: $o, class: $c[0:200], recommendation: $r[0:500]}
    + (if $u == "" then {} else {ticket_url: $u, mode: $m} end)' > "$STATE/acted/$fp.json" \
    || { log "cannot write the acted file for ${fp:0:12}; not recorded"; return 1; }
  jq -c --arg a "$AGENT" --arg f "$fp" '{agent: $a, fingerprint: $f} + .' "$STATE/acted/$fp.json" > "$TMPD/rec.json"
  _jobs_req_file POST /api/staff/findings/record "$TMPD/rec.json" >/dev/null \
    || log "record ${fp:0:12} $2 failed (rc=$?); the next tick re-posts it"
}

# ═════ act helpers ═════════════════════════════════════════════════════════════
LISTED=0
digest() { # digest <verdict> <action> <fp> <title> <url>
  printf '%s agent=%s level=%s verdict=%s action="%s" fp=%s title="%s" url=%s\n' "$(nowiso)" "$AGENT" "$LEVEL" \
    "$1" "$(tr -d '"\n' <<<"$2")" "${3:0:12}" "$(tr -d '"\n' <<<"$4")" "$5" >> "$DIGEST"
}
# file_issue <row json> -> ISSUE_URL; rc 1 = nothing filed. Called in this
# shell, never in a $( ), so the one open-issue list per tick is kept.
file_issue() {
  local r=$1 fp url grc=0 num
  ISSUE_URL=""
  fp=$(jq -r .fingerprint <<<"$r")
  if [ "$LISTED" = 0 ]; then
    gh_rest_issue_list "$REPO" open "staff:$AGENT" 1000 > "$TMPD/open.json" 2>/dev/null || grc=$?
    if [ "$grc" != 0 ] || ! jq -e 'type == "array" and length < 1000' "$TMPD/open.json" >/dev/null 2>&1; then
      LISTED=2; log "open issue list unreadable (rc=$grc HTTP ${GH_REST_STATUS:-}); nothing filed this tick"
    else
      LISTED=1
    fi
  fi
  [ "$LISTED" = 1 ] || return 1
  url=$(jq -r --arg m "<!-- staff-fp:$fp -->" \
    '[.[] | select((.body // "") | contains($m))] | sort_by(.number) | .[0].html_url // empty' "$TMPD/open.json")
  [ -n "$url" ] && { ISSUE_URL=$url; return 0; }
  { jq -r .body <<<"$r"; printf '\nSource: %s\n\n<!-- staff-fp:%s -->\n' "$(jq -r .url <<<"$r")" "$fp"; } \
    | sed 's/—/-/g' > "$TMPD/issue-body"
  jq -n --arg t "$(jq -r '.title[0:80]' <<<"$r" | sed 's/—/-/g')" --rawfile b "$TMPD/issue-body" --arg l "staff:$AGENT" \
    '{title: $t, body: $b, labels: [$l]}' > "$TMPD/issue.json"
  grc=0
  gh_rest POST "repos/$REPO/issues" --input "$TMPD/issue.json" > "$TMPD/created" 2>/dev/null || grc=$?
  num=$(jq -e '.number | numbers' "$TMPD/created" 2>/dev/null) || num=""
  url=$(jq -r '.html_url // ""' "$TMPD/created" 2>/dev/null)
  if [ "$grc" != 0 ] || [ "${GH_REST_STATUS:-}" != 201 ] || [ -z "$num" ] || [ -z "$url" ]; then
    log "issue create for ${fp:0:12} failed (rc=$grc HTTP ${GH_REST_STATUS:-}); the finding stays claimed"
    return 1
  fi
  ISSUE_URL=$url
}
# hold <fp> <row json> <mode> <class> <title>: GitHub refused a decided
# filing. The decision is kept, so a later tick files it with no model call.
hold() {
  jq -cn --argjson r "$2" --arg m "$3" --arg c "$4" --arg t "$5" '{row: $r, mode: $m, class: $c, ftitle: $t}' \
    > "$STATE/held/$1.json.tmp" 2>/dev/null && mv -f "$STATE/held/$1.json.tmp" "$STATE/held/$1.json" \
    || log "cannot write the held filing for ${1:0:12}; the next tick asks the model again"
  HELD=$((HELD+1))
}

# ═════ held filings: the filing again, never the model ═════════════════════
: >> "$TMPD/held"
while IFS= read -r fp; do
  hf="$STATE/held/$fp.json"
  r=$(jq -c '.row // empty' "$hf" 2>/dev/null)
  if [ -z "$r" ]; then log "held filing ${fp:0:12} unreadable; removed, the next tick asks the model"; rm -f "$hf"; continue; fi
  if file_issue "$r"; then
    finish "$fp" filed "$(jq -r .class "$hf")" "$(jq -r .ftitle "$hf")" "$ISSUE_URL" "$(jq -r .mode "$hf")" && rm -f "$hf"
    FILED=$((FILED+1))
  else
    HELD=$((HELD+1))
  fi
done < "$TMPD/held"

# ═════ the attempt cap ═══════════════════════════════════════════════════════
: > "$TMPD/todo"
while IFS= read -r it; do
  fp=$(jq -r .fingerprint <<<"$it")
  att=$(cat "$STATE/attempts/$fp" 2>/dev/null); [[ $att =~ ^[0-9]+$ ]] || att=0
  if [ "$att" -ge "$MAX_ATT" ]; then
    log "finding ${fp:0:12} reached $att model attempts; recorded failed"
    finish "$fp" failed "$(jq -r .class <<<"$it")" "$(jq -r .title <<<"$it")"
    FAILED=$((FAILED+1))
  else
    printf '%s\n' "$it" >> "$TMPD/todo"
  fi
done < "$TMPD/new"

TODO=$(grep -c . "$TMPD/todo")
[ "$TODO" -gt 0 ] || { summary; exit 0; }

# ═════ one model turn ════════════════════════════════════════════════════════
# One literal stage for every agent (stage-route-seed, lane-stage-ratchet): the
# agent rides as STAFF_AGENT and in AGENT_CALL_FP, never in the stage name.
STAGE=staff-tick
model=$(lane_role_model "stage.$STAGE" 2>/dev/null); rc=$?
if [ "$rc" != 0 ] || [ -z "$model" ]; then
  log "no model route stage.$STAGE (rc=$rc); nothing guessed; $TODO item(s) stay claimed"
  summary; exit 0
fi
while IFS= read -r fp; do
  att=$(cat "$STATE/attempts/$fp" 2>/dev/null); [[ $att =~ ^[0-9]+$ ]] || att=0
  printf '%s\n' "$((att+1))" > "$STATE/attempts/$fp" \
    || { log "cannot write the attempt for ${fp:0:12}; no model call"; summary; exit 0; }
done < <(jq -r .fingerprint "$TMPD/todo")
pf="$TMPD/prompt.md"; raw="$TMPD/answer"
{ cat "$H/$SOUL"; printf '\n\n'; cat "$H/catalog/prompts/staff-tick.md" 2>/dev/null; printf '\n## Items\n'
  jq -sc '.' "$TMPD/todo"; } > "$pf"
callfp=$(jq -r .fingerprint "$TMPD/todo" | sort | sha256sum | cut -c1-64)
# agent-call's _budget_for reads AGENT_CALL_BUDGET_USD_<STAGE>: STAFF_TICK.
env AGENT_CALL_LANE=staff STAFF_AGENT="$AGENT" AGENT_CALL_FP="staff:$AGENT:$callfp" AGENT_CALL_BUDGET_USD_STAFF_TICK="$USD" \
  "$H/bin/agent-call.sh" staff-tick fleet "$model" 300 "$raw" "@$pf" >/dev/null 2>&1
rc=$?
CALLS=1
if [ "$rc" != 0 ]; then
  log "agent-call rc=$rc; $TODO item(s) stay claimed and retry up to $MAX_ATT attempts"
  summary; exit 0
fi
dec=$(sed '/^[[:space:]]*```/d' "$raw" 2>/dev/null | awk '!p && index($0,"{"){ $0=substr($0,index($0,"{")); p=1 } p' \
  | jq -cn 'first(inputs) | select(type == "object" and (.decisions | type) == "array") | .decisions' 2>/dev/null)
if [ -z "$dec" ]; then
  log "agent-call answered rc 0 with no parsable decisions (model_empty); $TODO item(s) recorded failed"
  while IFS= read -r it; do
    finish "$(jq -r .fingerprint <<<"$it")" failed "$(jq -r .class <<<"$it")" "$(jq -r .title <<<"$it")"
    FAILED=$((FAILED+1))
  done < "$TMPD/todo"
  summary; exit 0
fi
ignored=$(jq -n --argjson d "$dec" --slurpfile t "$TMPD/todo" \
  '[$d[] | objects | .fingerprint] - [$t[].fingerprint] | length')
[ "${ignored:-0}" -gt 0 ] && log "the answer had $ignored decision(s) for unknown fingerprints; ignored"
# One row per item: its decision (action `none` when the answer skipped it).
jq -c --argjson d "$dec" '. as $i
  | ([$d[] | objects | select(.fingerprint == $i.fingerprint)] | .[0] // {}) as $x
  | {fingerprint, class, ftitle: .title, url: (.source.url // ""),
     action: (if ($x.action | type) == "string" then $x.action else "none" end),
     title: (if ($x.title | type) == "string" and $x.title != "" then $x.title else .title end),
     body: (if ($x.body | type) == "string" then $x.body else "" end)}' "$TMPD/todo" > "$TMPD/rows"
jq -sc --arg l "$LEVEL" --arg c "$CAP" --argjson n "$NEVER" \
  '{level: $l, cap: $c, never: $n, decisions: [.[] | {fingerprint, action}]}' "$TMPD/rows" \
  | node "$SELF/staff-core.mjs" decide > "$TMPD/verdicts" 2>/dev/null \
  || { log "staff-core.mjs decide failed; $TODO item(s) stay claimed"; summary; exit 0; }

# ═════ act ═══════════════════════════════════════════════════════════════════
while IFS= read -r r; do
  fp=$(jq -r .fingerprint <<<"$r")
  v=$(jq -c --arg f "$fp" '[.items[] | select(.fingerprint == $f)][0] // {}' "$TMPD/verdicts")
  verdict=$(jq -r '.verdict // "refuse"' <<<"$v")
  action=$(jq -r .action <<<"$r"); ftitle=$(jq -r .ftitle <<<"$r"); class=$(jq -r .class <<<"$r")
  if [ "$(jq -r '.never // false' <<<"$v")" = true ]; then
    "$H/bin/lane-alert.sh" --id "staff-never-$AGENT-${fp:0:12}" --severity warn staff \
      "$AGENT proposed \"$action\" for \"$ftitle\". It is on the NEVER list. I refused it. Finding ${fp:0:12}." >/dev/null 2>&1 || true
    finish "$fp" refused "$class" "$ftitle"; REFUSED=$((REFUSED+1))
  elif [ "$verdict" = refuse ]; then
    digest refuse "$action" "$fp" "$ftitle" "$(jq -r .url <<<"$r")"
    finish "$fp" digested "$class" "$ftitle"; DIGESTED=$((DIGESTED+1))
  elif [ "$(jq -r '.executable // false' <<<"$v")" = true ]; then
    [ "$verdict" = allow ] && mode=auto || mode=ask
    if file_issue "$r"; then
      finish "$fp" filed "$class" "$ftitle" "$ISSUE_URL" "$mode"; FILED=$((FILED+1))
    else
      hold "$fp" "$r" "$mode" "$class" "$ftitle"
    fi
  else
    digest unsupported "$action" "$fp" "$ftitle" "$(jq -r .url <<<"$r")"
    finish "$fp" unsupported "$class" "$ftitle"; UNSUPPORTED=$((UNSUPPORTED+1))
  fi
done < "$TMPD/rows"
summary
exit 0
