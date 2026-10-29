#!/bin/bash
# bin/pm-groom.sh <project> [--force] — BH-7261 (BH-7244.3): the PM agent's
# weekly grooming brief. A per-project lane, Monday 11:0x UTC
# (cron/lanes/737-pm-groom.cron), two hours after run-product.
#
# ONE RUN:
#   1. lane_gate_or_exit / lane_env_apply pm-groom. run-product's switch
#      (lane_paused run-product <project>) and flags/product-paused-<project>
#      stop it too (rc 0, one log line).
#   2. flock -n locks/<project>-product.lock, the run-product lock: held is a
#      skip (rc 0), never a wait.
#   3. MODEL=$(lane_model PM_MODEL product.pm <project>). No route: rc 75, no
#      read, no claim, no call (bin/lib/model-route.sh writes the ALERTS line).
#   4. Reads: GET /api/settings/ for pm.stale_days (1..365, default 30),
#      pm.backlog_limit (1..1000, 1000; the worker caps a list at 1000), pm.moves_max (1..200, 50), pm.now_max
#      and pm.next_wave_max (1..50, 10), and the text cuts pm.summary_max_chars,
#      pm.reason_max_chars (the worker checks the same row), pm.score_why_max_chars
#      and pm.note_max_chars, the write caps pm.evidence_max and pm.body_max_chars
#      (the worker refuses past both), and the count caps pm.scores_max and
#      pm.stale_max (0..1000, 200); a value out of range is one warn line
#      and the default. Then GET /api/roadmap/ideas for the lanes `ideas` and
#      `next`. A failed read: one ALERTS line, rc 1, no claim, no call. A
#      truncated list sets stale_partial in the brief.
#   5. Stale: an idea whose updated_at is pm.stale_days days old or more. An
#      updated_at that does not parse is not stale (one warn line).
#   6. Evidence: the `ok` rows of the newest products/<project>/*/data-signals.json
#      (bin/pm-signals.sh), plus one stale.<idea_id> row per stale idea. A
#      not-configured or error row is never evidence.
#   7. CLAIM BEFORE THE SPEND: POST /api/pm/briefs/claim makes the (project,
#      week) row. Not won: a ready row with sent_tg=0 is sent again (no call);
#      anything else is "already billed", rc 0. --force (a person) re-claims a
#      claimed or failed row; a ready row is final.
#   8. ONE bin/agent-call.sh call (stage pm, role product.pm, no tools). A
#      non-zero rc or an answer that is not the schema: POST .../fail, one
#      ALERTS line, rc 0 (billed and final for the week).
#   9. Every move must name a backlog idea, start from its current lane, go to
#      another of ideas|next|discarded and cite at least one evidence id from
#      the list; anything else is dropped with one log line. A move to `now`
#      becomes a Now entry (text, no button). Evidence is cut to pm.evidence_max,
#      scores (highest first) to pm.scores_max and stale to pm.stale_max; a body
#      still over pm.body_max_chars loses half its scores, then half its stale
#      list, until it fits (scores_partial / stale_partial say so). POST
#      /api/pm/briefs writes the body and the moves (status ready, sent_mc=1). A
#      failed write after the call, or a body that cannot fit: one ALERTS line,
#      rc 1, the row stays claimed (billed), and the paid answer is kept in
#      state/pm-groom/<project>.failed-create.json (one file, overwritten).
#  10. bin/archie-tg-send.sh pm-brief:<project>:<week> sends the text, built
#      from the stored brief, with a Mission Control link per move. rc 0 then
#      POST .../sent sets sent_tg=1; any other rc leaves it 0, one ALERTS line, rc 0.
#      The cron runs once a week and each run has a new WEEK, so only a manual
#      rerun in the same ISO week resends an unsent brief.
#      After TG=sent, pmtb_send (bin/lib/pm-tg-buttons.sh, BH-8650) sends one
#      more message to the same chat: an Approve and a Reject button per move,
#      signed by the worker (GET /api/pm/moves/tg-keyboard), once per week
#      (ledger pm_tg_buttons). Its outcome is one log line; buttons=failed is
#      also one ALERTS line, and so is `ledger-write-failed`. The links in the
#      text stay the fallback. The settings row pm.tg_buttons_enabled (0..1,
#      seed and fallback 0) gates the call: 0 is one `buttons=skip disabled`
#      log line and no keyboard read. It stays 0 until cromford-console
#      forwards `pm:` callbacks to POST /api/pm/moves/tg, so no box sends a
#      button that does nothing.
#  11. One line in logs/pm-groom.log:
#      <ts> [<project>] week=<W> ideas=<n> stale=<n> moves=<n> dropped=<n> now=<n> call=0|1 tg=sent|failed|skip rc=<rc>
#
# It never calls gh, curl or a board API itself, and never drafts, posts or
# builds: an approve on Mission Control moves an idea's lane and nothing else.
#
# OFF: flags/lane-off-pm-groom or bin/harness-ctl.sh off pm-groom.
# Registry: catalog/lanes.d/pm-groom.json. Note: docs/notes/2026-10-20-BH-7261-pm-groom.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: pm-groom.sh <project> [--force]" >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage
P=$1
FORCE=0
if [ $# -eq 2 ]; then [ "$2" = --force ] || usage; FORCE=1; fi
[[ $P =~ ^[A-Za-z0-9._-]+$ ]] && [ "$P" != . ] && [ "$P" != .. ] || usage

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
  . "$SELF/lib/console-pages.sh" 2>/dev/null || true
  . "$SELF/lib/pm-tg-buttons.sh" 2>/dev/null || true
}
export AGENT_CALL_LANE=pm-groom
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit pm-groom "$P"
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply pm-groom "$P"

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/pm-groom.log"
log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$P" "$*" >> "$LOG"; }
# alert <text>: one ALERTS line through bin/alert-line.sh (it stamps the time).
alert() { HARNESS="$H" "$H/bin/alert-line.sh" --project "$P" "[$P] pm-groom: $*" >/dev/null 2>&1 || true; }
WEEK=-; NIDEAS=0; NSTALE=0; NMOVES=0; NDROP=0; NNOW=0; CALL=0; TG=skip
finish() {
  log "week=$WEEK ideas=$NIDEAS stale=$NSTALE moves=$NMOVES dropped=$NDROP now=$NNOW call=$CALL tg=$TG rc=$1"
  exit "$1"
}

# run-product's own switch (all-off, lane-off-run-product, its project row) stops it too.
if command -v lane_paused >/dev/null 2>&1 && lane_paused run-product "$P"; then
  log "run-product is off (${LANE_PAUSED_WHY:-paused}); no brief"; exit 0
fi
if [ -f "$H/flags/product-paused-$P" ]; then log "flags/product-paused-$P is set; no brief"; exit 0; fi
command -v _jobs_req >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { alert "bin/jobs-client.sh or jq is missing; no brief"; exit 1; }

exec 8>"$H/locks/$P-product.lock"
flock -n 8 || { log "the product lock is held (a run-product cycle is active); skipped"; exit 0; }

command -v lane_model >/dev/null 2>&1 || { alert "bin/lib/lane-model.sh is missing; no call"; exit 75; }
MODEL=$(lane_model PM_MODEL product.pm "$P") || { log "no model route for product.pm; no read, no call"; finish 75; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${PM_GROOM_NOW:-}" ]; then NOW="$PM_GROOM_NOW"; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
[[ $NOW =~ ^[0-9]+$ ]] || { log "PM_GROOM_NOW=$NOW is not epoch seconds"; exit 2; }
WEEK=$(date -u -d "@$NOW" +%G-W%V)
TIMEOUT="${PM_GROOM_TIMEOUT_S:-300}"
if ! [[ $TIMEOUT =~ ^[0-9]+$ ]] || [ "$TIMEOUT" -lt 60 ] || [ "$TIMEOUT" -gt 1200 ]; then
  log "warn: PM_GROOM_TIMEOUT_S=$TIMEOUT is not an integer in 60..1200; using 300"; TIMEOUT=300
fi

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/pm-groom.XXXXXX") || { alert "mktemp failed; no brief"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT
PE=$(jq -rn --arg p "$P" '$p | @uri')

# req <out-file> <method> <path> [body]: one jobs request into a file; RC is its rc.
req() { RC=0; _jobs_req "$2" "$3" "${4:-}" > "$1" 2>/dev/null || RC=$?; }

# ── reads ────────────────────────────────────────────────────────────────────
# knob <key> <default> <lo> <hi>: one settings read into KNOB. A failed read is
# one ALERTS line, rc 1, no claim, no call; no row is the default; a value that
# is not an integer in lo..hi is one warn line and the default.
knob() {
  local v
  req "$TMPD/knob.json" GET "/api/settings/$1"
  [ "$RC" = 0 ] || { alert "pm-groom read failed: GET /api/settings/$1 rc=$RC; no claim, no call"; finish 1; }
  v=$(jq -r '.setting.value // empty' "$TMPD/knob.json" 2>/dev/null)
  KNOB=$2
  if [ -n "$v" ]; then
    if [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; then KNOB=$v
    else log "warn: $1=$v is not an integer in $3..$4; using $2"; fi
  fi
}
# Code fallbacks; each names its settings row (BH-7945).
knob pm.stale_days 30 1 365; STALE_DAYS=$KNOB
knob pm.backlog_limit 1000 1 1000; BACKLOG_LIMIT=$KNOB   # ideas read per lane
knob pm.moves_max 50 1 200; MOVES_MAX=$KNOB             # moves kept per brief
knob pm.now_max 10 1 50; NOW_MAX=$KNOB                  # Now entries kept per brief
knob pm.next_wave_max 10 1 50; NEXT_WAVE_MAX=$KNOB      # next_wave ids kept per brief
knob pm.summary_max_chars 1000 1 10000; SUMMARY_MAX=$KNOB # summary characters kept
knob pm.reason_max_chars 500 1 2000; REASON_MAX=$KNOB   # move and Now reason characters (the worker reads the same row)
knob pm.score_why_max_chars 200 1 2000; WHY_MAX=$KNOB   # score reason characters kept
knob pm.note_max_chars 300 1 5000; NOTE_MAX=$KNOB       # idea note characters in the prompt
knob pm.evidence_max 20 1 100; EVIDENCE_MAX=$KNOB       # evidence ids per move or Now entry (the worker reads the same row)
knob pm.body_max_chars 65536 1024 1048576; BODY_MAX=$KNOB # brief body characters as JSON (the worker reads the same row)
knob pm.scores_max 200 0 1000; SCORES_MAX=$KNOB         # score entries kept, highest score first
knob pm.stale_max 200 0 1000; STALE_MAX=$KNOB           # stale entries kept in the body, oldest first
knob pm.tg_buttons_enabled 0 0 1; TG_BUTTONS=$KNOB      # BH-8650: 1 sends the Telegram button message; seed 0 until the console forwards pm: callbacks
PARTIAL=false
for lane in ideas next; do
  req "$TMPD/lane-$lane.json" GET "/api/roadmap/ideas?project=$PE&lane=$lane&limit=$BACKLOG_LIMIT"
  if [ "$RC" != 0 ] || ! jq -e '.ideas | type == "array"' "$TMPD/lane-$lane.json" >/dev/null 2>&1; then
    alert "pm-groom read failed: GET /api/roadmap/ideas lane=$lane rc=$RC; no claim, no call"; finish 1
  fi
  [ "$(jq -r '.truncated // false' "$TMPD/lane-$lane.json")" = true ] && PARTIAL=true
done
# The backlog, one object per idea, with age_days (null when updated_at does not parse).
jq -s --argjson now "$NOW" --argjson nmax "$NOTE_MAX" '[.[].ideas[] | {id, title, lane, version, source, note: ((.note // "") | .[0:$nmax]), updated_at,
    age_days: ((.updated_at // "") | sub("\\.[0-9]+Z$"; "Z") | (fromdateiso8601? // null)
               | if . == null then null else (($now - .) / 86400 | floor) end)}]' \
  "$TMPD/lane-ideas.json" "$TMPD/lane-next.json" > "$TMPD/backlog.json" \
  || { alert "pm-groom: the backlog answer did not parse; no claim, no call"; finish 1; }
NIDEAS=$(jq 'length' "$TMPD/backlog.json")
while IFS=$'\t' read -r id ua; do
  [ -n "$id" ] && log "warn: idea $id has an updated_at that does not parse ($ua); not stale"
done < <(jq -r '.[] | select(.age_days == null) | [.id, (.updated_at // "")] | @tsv' "$TMPD/backlog.json")
jq --argjson sd "$STALE_DAYS" '[.[] | select(.age_days != null and .age_days >= $sd)
    | {idea_id: .id, title, lane, age_days}] | sort_by(-.age_days, .idea_id)' "$TMPD/backlog.json" > "$TMPD/stale-list.json"
NSTALE=$(jq 'length' "$TMPD/stale-list.json")

# ── evidence ─────────────────────────────────────────────────────────────────
SIG=""
for f in "$H/products/$P"/*/data-signals.json; do [ -f "$f" ] && SIG="$f"; done
SNAP=null
if [ -n "$SIG" ] && jq -e '.evidence | type == "array"' "$SIG" >/dev/null 2>&1; then
  jq -c '[.evidence[] | select(.status == "ok" and (.id | type) == "string")
          | {id, source, metric, value, window, link}]' "$SIG" > "$TMPD/signals.json"
  SNAP=$(jq -c '.snapshot_hash // null' "$SIG")
else
  log "no data-signals.json for $P; the evidence is the stale list only"
  echo '[]' > "$TMPD/signals.json"
fi
jq -c --slurpfile s "$TMPD/stale-list.json" '. + [$s[0][] | {id: ("stale." + .idea_id), source: "roadmap",
    metric: "days_since_update", value: .age_days, window: "", link: ""}]' "$TMPD/signals.json" > "$TMPD/evidence.json"

PROMPT_SRC="$H/prompts/product-stages/pm-groom.md"
[ -r "$PROMPT_SRC" ] || PROMPT_SRC="$SELF/../prompts/product-stages/pm-groom.md"
[ -r "$PROMPT_SRC" ] || { alert "prompts/product-stages/pm-groom.md is missing; no claim, no call"; finish 1; }
INPUT_FP=$({
  jq -r '.[] | "\(.id):\(.version)"' "$TMPD/backlog.json" | LC_ALL=C sort
  printf 'stale_days=%s\nsnapshot=%s\n' "$STALE_DAYS" "$SNAP"
  sha256sum < "$PROMPT_SRC" | cut -c1-64
} | sha256sum | cut -c1-64)

# ── the send (from the stored brief) ─────────────────────────────────────────
# send <brief-get.json>: the Telegram text, then /sent on rc 0. Sets TG.
send() {
  local base text rc=0
  base=$(command -v console_pages_url >/dev/null 2>&1 && console_pages_url) || base=""
  text=$(jq -r --arg base "$base" --arg p "$P" --arg pe "$PE" '
    def link(q): if $base == "" then "Mission Control > Roadmap > \($p) > Weekly brief" else "\($base)/roadmap/\($pe)?view=brief&week=\(.week)\(q)" end;
    . as $d | ($d.brief.body // {}) as $b
    | ["PM brief \($p) \($d.week)", ($b.summary // ""),
       "\(($b.stale // []) | length) stale idea(s)\(if $b.stale_partial then " (the backlog read was cut; older ideas may be missing)" else "" end).",
       (if ($d.moves | length) > 0 then "Moves to approve or reject:" else "No moves proposed." end)]
      + [$d.moves[] | .id as $mid | "- \(.title // .idea_id): \(.from_col) -> \(.to_col). \(.reason // "")\n  \($d | link("&move=" + $mid))"]
      + (if (($b.now // []) | length) > 0 then ["Now proposals:"] + [$b.now[] | "- \(.title // .idea_id): \(.reason // "")"] else [] end)
      + ["Brief: \($d | link(""))"]
    | join("\n")' "$1")
  "$H/bin/archie-tg-send.sh" "pm-brief:$P:$WEEK" "$text" </dev/null >/dev/null 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then
    TG=failed; alert "Telegram send failed for the $WEEK brief (archie-tg-send rc=$rc); sent_tg stays 0; the weekly cron does not resend it, run bin/pm-groom.sh $P again this ISO week to resend (no call)"
    return 0
  fi
  req "$TMPD/sent.json" POST /api/pm/briefs/sent "$(jq -nc --arg p "$P" --arg w "$WEEK" '{project:$p, week:$w, channel:"tg"}')"
  if [ "$RC" = 0 ]; then TG=sent
    if [ "$TG_BUTTONS" != 1 ]; then log "buttons=skip disabled (settings pm.tg_buttons_enabled=$TG_BUTTONS)"
    elif command -v pmtb_send >/dev/null 2>&1; then BT=$(pmtb_send "$P" "$WEEK"); log "$BT"; case "$BT" in
      buttons=failed*) alert "the $WEEK brief went out, but its Telegram buttons did not ($BT); the Mission Control links still work";;
      *ledger-write-failed) alert "the $WEEK Telegram buttons went out, but the pm_tg_buttons ledger row did not land ($BT); a rerun this week can send a second keyboard";;
    esac; fi
  else TG=failed; alert "the $WEEK brief was sent to Telegram but POST /api/pm/briefs/sent failed rc=$RC; sent_tg stays 0"; fi
}
# brief_get: GET the week's brief into $TMPD/brief.json. rc 1 when it cannot be read.
brief_get() {
  req "$TMPD/brief.json" GET "/api/pm/briefs?project=$PE&week=$WEEK"
  [ "$RC" = 0 ] && jq -e '.brief.status == "ready"' "$TMPD/brief.json" >/dev/null 2>&1
}

# ── claim before the spend ───────────────────────────────────────────────────
req "$TMPD/claim.json" POST /api/pm/briefs/claim "$(jq -nc --arg p "$P" --arg w "$WEEK" --arg fp "$INPUT_FP" \
  --arg m "$MODEL" --argjson f "$FORCE" '{project:$p, week:$w, input_fp:$fp, model:$m} + (if $f == 1 then {force:true} else {} end)')"
[ "$RC" = 0 ] || { alert "pm-groom: POST /api/pm/briefs/claim rc=$RC; no call"; finish 1; }
if [ "$(jq -r '.claimed' "$TMPD/claim.json")" != true ]; then
  st=$(jq -r '.brief.status // "none"' "$TMPD/claim.json")
  if [ "$st" = ready ] && [ "$(jq -r '.brief.sent_tg // 0' "$TMPD/claim.json")" = 0 ]; then
    log "the $WEEK brief is ready and not sent; sending it again (no call)"
    if brief_get; then
      NMOVES=$(jq '.moves | length' "$TMPD/brief.json"); NNOW=$(jq '(.brief.body.now // []) | length' "$TMPD/brief.json")
      send "$TMPD/brief.json"; finish 0
    fi
    alert "the $WEEK brief could not be read back for the resend (rc=$RC)"; finish 1
  fi
  log "already billed for $WEEK (brief $st); no call"
  TG=skip; finish 0
fi

# ── the one call ─────────────────────────────────────────────────────────────
PROMPT="$TMPD/prompt.md"
{
  cat "$PROMPT_SRC"
  printf '\n## Input\n\nPROJECT: %s\nWEEK: %s\nSTALE_DAYS: %s\nNEXT_WAVE_MAX: %s\n' "$P" "$WEEK" "$STALE_DAYS" "$NEXT_WAVE_MAX"
  printf '\nBACKLOG (lanes ideas and next):\n'; jq -c '.[] | {id, title, lane, source, note, updated_at, age_days}' "$TMPD/backlog.json"
  printf '\nSTALE (computed; %s or more days with no change):\n' "$STALE_DAYS"; jq -c '.[]' "$TMPD/stale-list.json"
  printf '\nEVIDENCE (cite these ids only):\n'; jq -c '.[]' "$TMPD/evidence.json"
} > "$PROMPT"
OUT="$TMPD/answer.txt"; : > "$OUT"; rc=0
CALL=1
AGENT_CALL_LANE=pm-groom AGENT_CALL_ROLE=product.pm AGENT_CALL_FP="pm-groom:$P:$WEEK" AGENT_CALL_NO_TOOLS=1 \
  "$H/bin/agent-call.sh" pm "$P" "$MODEL" "$TIMEOUT" "$OUT" "@$PROMPT" </dev/null >/dev/null 2>&1 || rc=$?
fail_brief() {
  req "$TMPD/fail.json" POST /api/pm/briefs/fail "$(jq -nc --arg p "$P" --arg w "$WEEK" --arg e "$1" '{project:$p, week:$w, error:$e}')"
  alert "brief failed for $WEEK: $1$( [ "$RC" = 0 ] || printf ' (and POST /api/pm/briefs/fail rc=%s)' "$RC")"
}
if [ "$rc" != 0 ]; then fail_brief "agent-call rc=$rc"; finish 0; fi
ans=$(grep -E '^[[:space:]]*\{' "$OUT" | tail -1)
jq -e 'type == "object"' <<<"$ans" >/dev/null 2>&1 || ans=$(sed '/^[[:space:]]*```/d' "$OUT" | jq -c . 2>/dev/null | tail -1)
if ! jq -e '(.summary | type) == "string" and (.moves | type) == "array"' <<<"$ans" >/dev/null 2>&1; then
  fail_brief "the answer is not the brief schema"; finish 0
fi

# ── check the answer ─────────────────────────────────────────────────────────
# One record per proposed move, in answer order: {ok, why, move}. Text is cut
# to the pm.reason_max_chars row the worker also checks; code points above
# U+FFFF are dropped, so the jq length is the worker's JS length.
jq -c --slurpfile bl "$TMPD/backlog.json" --slurpfile ev "$TMPD/evidence.json" --argjson mmax "$MOVES_MAX" --argjson rmax "$REASON_MAX" --argjson emax "$EVIDENCE_MAX" '
  def clean(n): tostring | explode | map(select(. < 65536)) | implode | gsub("[\r\n]+"; " ") | gsub("—"; "-") | .[0:n];
  ($bl[0] | map({key: .id, value: .}) | from_entries) as $ideas
  | ($ev[0] | map({key: .id, value: true}) | from_entries) as $evok
  | def cite: [(.evidence // [])[]? | select(type == "string" and $evok[.])] | unique | .[0:$emax];
  reduce (.moves[]? | select(type == "object")) as $m ({seen: {}, out: []};
    (($m.idea_id // "") | tostring) as $id | $ideas[$id] as $i | ($m | cite) as $c
    | (($m.to_col // "") | tostring) as $to
    | (if $i == null then "idea \($id | .[0:80]) is not in the backlog"
       elif ($m.from_col // "") != $i.lane then "idea \($id) is in \($i.lane), not \(($m.from_col // "") | tostring | .[0:20])"
       elif $to == "now" then null
       elif ($to | IN("ideas", "next", "discarded") | not) then "to_col \($to | .[0:20]) is not ideas|next|discarded"
       elif $to == $i.lane then "idea \($id) is already in \($to)"
       elif ($c | length) == 0 then "idea \($id) cites no evidence id from the list"
       elif .seen[$id] then "idea \($id) has a move already"
       else null end) as $why
    | if $why then .out += [{ok: false, why: $why}]
      elif $to == "now" then
        if ($c | length) == 0 then .out += [{ok: false, why: "now proposal for \($id) cites no evidence id from the list"}]
        else .out += [{ok: true, now: {idea_id: $id, title: $i.title, reason: (($m.reason // "") | clean($rmax)), evidence: $c}}] end
      elif (.out | map(select(.ok and .move)) | length) >= $mmax then .out += [{ok: false, why: "more than \($mmax) moves"}]
      else .seen[$id] = true
        | .out += [{ok: true, move: {idea_id: $id, from_col: $i.lane, to_col: $to, reason: (($m.reason // "") | clean($rmax)), evidence: $c}}] end)
  | .out[]' <<<"$ans" > "$TMPD/checked.jsonl"
while IFS= read -r why; do
  [ -n "$why" ] && log "dropped a move: $why"
done < <(jq -r 'select(.ok | not) | .why' "$TMPD/checked.jsonl")
NDROP=$(jq -s 'map(select(.ok | not)) | length' "$TMPD/checked.jsonl")
jq -s '[.[] | select(.ok and .move) | .move]' "$TMPD/checked.jsonl" > "$TMPD/moves.json"
jq -c --slurpfile bl "$TMPD/backlog.json" --slurpfile ev "$TMPD/evidence.json" --slurpfile ck <(jq -s . "$TMPD/checked.jsonl") \
  --slurpfile st "$TMPD/stale-list.json" --argjson partial "$PARTIAL" --argjson snap "$SNAP" \
  --argjson nowmax "$NOW_MAX" --argjson nwmax "$NEXT_WAVE_MAX" --argjson smax "$SUMMARY_MAX" \
  --argjson rmax "$REASON_MAX" --argjson wmax "$WHY_MAX" --argjson emax "$EVIDENCE_MAX" \
  --argjson scmax "$SCORES_MAX" --argjson stmax "$STALE_MAX" '
  def clean(n): tostring | explode | map(select(. < 65536)) | implode | gsub("[\r\n]+"; " ") | gsub("—"; "-") | .[0:n];
  ($bl[0] | map({key: .id, value: .}) | from_entries) as $ideas
  | ($ev[0] | map({key: .id, value: true}) | from_entries) as $evok
  | ([(.scores // [])[]? | select(type == "object" and $ideas[(.idea_id // "") | tostring] and (.score | type) == "number" and .score >= 0 and .score <= 100)
      | {idea_id: (.idea_id | tostring), score, why: ((.why // "") | clean($wmax))}] | unique_by(.idea_id) | sort_by(-.score, .idea_id)) as $sc
  | {summary: (.summary | clean($smax)),
     stale: $st[0][0:$stmax], stale_partial: ($partial or (($st[0] | length) > $stmax)),
     scores: $sc[0:$scmax], scores_partial: (($sc | length) > $scmax),
     now: ([$ck[0][] | select(.ok and .now) | .now]
           + [(.now // [])[]? | select(type == "object") | ((.idea_id // "") | tostring) as $id | select($ideas[$id])
              | {idea_id: $id, title: $ideas[$id].title, reason: ((.reason // "") | clean($rmax)),
                 evidence: ([(.evidence // [])[]? | select(type == "string" and $evok[.])] | unique | .[0:$emax])}
              | select((.evidence | length) > 0)]) | unique_by(.idea_id) | .[0:$nowmax],
     next_wave: ([(.next_wave // [])[]? | tostring | select($ideas[.])] | reduce .[] as $x ([]; if index($x) then . else . + [$x] end) | .[0:$nwmax]),
     snapshot_hash: $snap}' <<<"$ans" > "$TMPD/body.json"
# The body must fit pm.body_max_chars, the cap the worker refuses past (a 400
# after a paid call). blen is the length JSON.stringify gives: a code point
# above U+FFFF is 2 UTF-16 units. Over the cap: halve the scores, then the stale
# list (each sets its *_partial flag), until it fits or both are empty.
blen() { jq -c . "$1" | jq -Rr 'explode | map(if . > 65535 then 2 else 1 end) | add // 0'; }
while [ "$(blen "$TMPD/body.json")" -gt "$BODY_MAX" ]; do
  if [ "$(jq '.scores | length' "$TMPD/body.json")" -gt 0 ]; then
    jq '.scores = .scores[0:((.scores | length) / 2 | floor)] | .scores_partial = true' "$TMPD/body.json" > "$TMPD/body.next"
  elif [ "$(jq '.stale | length' "$TMPD/body.json")" -gt 0 ]; then
    jq '.stale = .stale[0:((.stale | length) / 2 | floor)] | .stale_partial = true' "$TMPD/body.json" > "$TMPD/body.next"
  else break; fi
  mv -f "$TMPD/body.next" "$TMPD/body.json"
done
NNOW=$(jq '.now | length' "$TMPD/body.json")
[ "$(jq '.scores_partial' "$TMPD/body.json")" = true ] && log "warn: the scores were cut to $(jq '.scores | length' "$TMPD/body.json") (pm.scores_max=$SCORES_MAX, pm.body_max_chars=$BODY_MAX)"

# keep_answer: the paid answer and the body outlive the trap. One file per
# project, overwritten by the next failed write, so it never grows.
keep_answer() {
  local d="$H/state/pm-groom"
  mkdir -p "$d" 2>/dev/null && jq -n --arg w "$WEEK" --rawfile a "$OUT" --slurpfile b "$TMPD/body.json" --slurpfile m "$TMPD/moves.json" \
    '{week:$w, answer:$a, body:$b[0], moves:$m[0]}' > "$d/$P.failed-create.json.tmp" 2>/dev/null \
    && mv -f "$d/$P.failed-create.json.tmp" "$d/$P.failed-create.json" && printf '%s' "$d/$P.failed-create.json"
}
if [ "$(blen "$TMPD/body.json")" -gt "$BODY_MAX" ]; then
  alert "the $WEEK brief body is over pm.body_max_chars=$BODY_MAX with no scores or stale left to cut; no write, the brief stays claimed (billed); the answer is kept in $(keep_answer)"
  finish 1
fi

req "$TMPD/create.json" POST /api/pm/briefs "$(jq -nc --arg p "$P" --arg w "$WEEK" --slurpfile b "$TMPD/body.json" \
  --slurpfile m "$TMPD/moves.json" '{project:$p, week:$w, body:$b[0], moves:$m[0]}')"
if [ "$RC" != 0 ]; then
  alert "create failed after call: POST /api/pm/briefs rc=$RC for $WEEK; the brief stays claimed (billed), --force by a person re-runs it; the answer is kept in $(keep_answer)"
  finish 1
fi
NMOVES=$(jq '.moves | length' "$TMPD/create.json")
jq '{week: .brief.week, brief, moves}' "$TMPD/create.json" > "$TMPD/brief.json"
send "$TMPD/brief.json"
finish 0
