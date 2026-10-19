#!/bin/bash
# bin/archie-research.sh — BH-4065 (BH-3966.4): Archie's research scout. Archie
# reads what the world is doing with AI software factories, autonomous SDLC
# and agent harnesses, scores each find "does this apply to us?", and writes
# the good ones into the EXISTING Ideas ledger as gate_pending proposals with
# their source links. Nothing is posted to X or anywhere public.
#
#   archie-research.sh scan      the daily scan (cron 06:40Z)
#   archie-research.sh digest    the weekly digest beat (cron 07:10Z daily; it
#                                acts once per ISO week, for the week before)
#
# THE LEDGER is the jobs DB table archie_research (worker/jobs/src/routes/
# archie-research.js). Every billable call is preceded by a CLAIM of its key
# (attempts+1, written before the call: no claim, no call) and followed by a
# SETTLE: ok, empty or failed. ok and empty are terminal, so a claim on them is
# refused and nothing is bought twice. The keys are normalised once, in
# bin/lib/archie-research.sh: xq:<topic>:<day>, wq:<day>, x:<post id>,
# web:<sha40 of the canonical url>, sb:<sha16 of a scoring chunk>, digest:<week>.
#
# SCAN, in this order:
#   1. lane_gate_or_exit / lane_env_apply archie-research; NOW read once
#      (ARCHIE_NOW only under HARNESS_TEST_SANDBOX=1);
#      ARCHIE_RESEARCH_ENABLED=0 exits; flock -n locks/archie-research.lock
#      (held = exit 0, never wait); the run is under timeout 1800 (D21).
#   2. the day's spend from the ledger (GET /spend, every unpriced attempt at
#      ARCHIE_RESEARCH_RESERVE_USD). Unreadable: one log line and NO vendor
#      call (fail closed). Before EVERY billable call: spent + reserve over
#      ARCHIE_RESEARCH_USD_CAP_DAY stops every further one, with ONE ALERTS
#      line a day. Every agent-call (the web scan, each scoring chunk) gets
#      --max-budget-usd = min(ARCHIE_RESEARCH_LLM_MAX_USD, cap minus today's
#      spend), floored to the cent, and runs only when that is at least the
#      reserve (BH-4762). The vendor checks that bound between turns only, so
#      one turn can still overshoot it: 2026-10-06 billed $2.29 on a $0.50
#      bound. That is why scoring goes in small chunks.
#   3. X: one xAI x_search per topic (ARCHIE_RESEARCH_TOPICS, at most 10) per
#      day, POST <endpoint_url xai>/v1/responses, on ARCHIE_XAI_API_KEY ONLY.
#      That key must be set and differ from XAI_API_KEY and
#      GROK_CODE_XAI_API_KEY (the grok runner's): otherwise no X call, no
#      fallback to any other key, ONE ALERTS line a day. The key rides in a
#      0600 header file, never argv. The model is model_routes
#      archie-research.xsearch. A priced 26-column cost row is written after
#      every attempt (blank cost + UNPRICED: note when the answer has no usage).
#   4. web: one agent-call per day (stage archie-research, the claude runner
#      only, AGENT_CALL_TOOLS=WebSearch: the session has web search and no
#      other tool, no MCP server). It reads attacker-writable pages, so it gets
#      nothing that reads this box (Read/Glob/Grep, /etc/harness) and nothing
#      that sends a URL of its choosing (WebFetch); the denylist below is a
#      second layer under the allowlist, not the control. Its cost is read
#      back from logs/cost.csv by run id.
#      rc 74-79 billed nothing and hands the attempt back. The prompt asks for
#      site:youtube.com searches (title, channel, date, url) and new model
#      releases; with the X half off it also asks for site:x.com (BH-4762). A
#      video is recorded "transcript not read": the session cannot fetch.
#   5. the retry list: every item settled failed in the last 7 days that is
#      still under ARCHIE_RESEARCH_MAX_ATTEMPTS, fewest attempts first, as the
#      find it was (its stored raw, or title + url for an older row). Then the
#      new finds, normalised; one key is one entry. Each is claimed (an item
#      key that is ok or empty is refused, so it is never scored again), at
#      most ARCHIE_RESEARCH_MAX_ITEMS a run; the rest are `deferred`.
#   6. scoring in chunks of ARCHIE_RESEARCH_SCORE_BATCH finds, one agent-call
#      each (no tools at all), each claimed as sb:<hash of its items and their
#      attempt>. Each item settles ok with applies/score/why and, when it
#      applies, the stage/change/effect/cost it names (no stage = failed and
#      retried), or failed when the answer leaves it out. A chunk that billed
#      and failed fails its own items (attempt counted, retried next scan),
#      hands every later item back (attempt restored) and stops scoring for
#      the run. So does the cap, and so does the run deadline (no chunk starts
#      with under 330 s of the run's 1700 left).
#   7. proposals: every ok item of the last 7 days with applies, a score of at
#      least ARCHIE_RESEARCH_MIN_SCORE and no proposal yet gets ticket.html +
#      mockup.html (a sources sheet) under state/archie-research/<slug>/, an
#      entry in state/archie-research.ledger.json that also carries both bodies
#      (approve runs on the project's owning box, not here, and post-proposal.sh
#      writes them out from the row there), prow_put gate_pending
#      if_absent into product_proposals (project ARCHIE_RESEARCH_PROJECT), then
#      ONE kind:proposal beat, then the item's proposal_slug. A put or beat
#      that fails is retried by the next scan with no vendor call.
#   7b. the daily beat (BH-4762): when this run made at least one proposal,
#      ONE Telegram message from Archie (bin/archie-tg-send.sh, BH-4779; akey
#      archie-research:daily:<day>) naming
#      the count and the top one, signed Archie, then a per-day marker. No
#      proposal, no line. The lane never writes model_routes: a better model
#      becomes a proposal that names the role.
#   8. one line in logs/archie-research.log.
#
# DIGEST: claims digest:<ISO week before this one> (no vendor call), reads the
# week's rows and sends ONE Telegram message from Archie (bin/archie-tg-send.sh,
# BH-4779; akey archie-research:digest:<week>) with the counts, the spend and the top five
# finds, signed Archie. ok is written only after the send answered rc 0; a week
# with nothing scored is settled empty and sends nothing.
#
# OFF: ARCHIE_RESEARCH_ENABLED=0, flags/lane-off-archie-research, or
# bin/harness-ctl.sh off archie-research. Registry:
# catalog/lanes.d/archie-research.json. Note:
# docs/notes/2026-10-04-BH-4065-archie-research-scout.md and
# docs/notes/2026-10-06-BH-4762-archie-research-produces.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
HARNESS="$H"
SELF="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-}"
case "$MODE" in
  scan|digest) ;;
  *) echo "usage: archie-research.sh scan | archie-research.sh digest" >&2; exit 2 ;;
esac
if [ "${ARCHIE_RESEARCH_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  ARCHIE_RESEARCH_TIMED=1 exec timeout 1800 bash "$0" "$@"
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
  . "$SELF/lib/endpoints.sh" 2>/dev/null || true
  . "$SELF/lib/cost-row.sh" 2>/dev/null || true
  . "$SELF/lib/archie.sh" 2>/dev/null || true
  . "$SELF/lib/archie-research.sh" 2>/dev/null || true
}
# The Ideas ledger's rows. Without the lib a proposal is not recorded (the
# stubs answer 1) and the next scan retries it, as every product lane does.
# shellcheck source=lib/proposal-rows.sh
[ -r "$HARNESS/bin/lib/proposal-rows.sh" ] && . "$HARNESS/bin/lib/proposal-rows.sh"
command -v prow_put >/dev/null 2>&1 || { prow_put() { return 1; }; prow_restore() { return 1; }; }
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_RESEARCH_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_RESEARCH_FIXTURE"
fi
for fn in _jobs_req ar_item_key archie_sign cost_row_emit endpoint_url; do
  command -v "$fn" >/dev/null 2>&1 || { echo "archie-research: $fn is missing (a lib did not load)" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
  || { echo "archie-research: jq and python3 are required" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$ARCHIE_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
DAY=$(date -u -d "@$NOW" +%F)
NOWISO=$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$H/logs" "$H/locks" "$H/state" 2>/dev/null
LOG="$H/logs/archie-research.log"
COST="$H/logs/cost.csv"
export HARNESS COST
log() { printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$MODE" "$*" >> "$LOG"; }
W=$(mktemp -d "${TMPDIR:-/tmp}/archie-research.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
# The web scan's ONLY tool (agent-call's allowlist), and the denylist under it.
SCAN_TOOLS=WebSearch
NO_WRITE_TOOLS=$'Bash\nWrite\nEdit\nMultiEdit\nNotebookEdit\nRead\nGlob\nGrep\nLS\nWebFetch\nTask\nAgent'

# knob_int <name> <value> <default> <min> <max> / knob_num <name> <value>
# <default> <max>: out of range is one warn line and the default, never a
# silent clamp (D11). knob_num keeps the string as written.
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    log "warn: $1=$v is outside $4..$5; using the default $3"; printf '%s' "$3"
  fi
}
knob_num() {
  local v=$2
  if [[ $v =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v a="$v" -v m="$4" 'BEGIN { exit !(a + 0 <= m + 0) }'; then
    printf '%s' "$v"
  else
    log "warn: $1=$v is not a number in 0..$4; using the default $3"; printf '%s' "$3"
  fi
}

# alert_once <tag> <text>: ONE ALERTS line per tag per day. The line goes
# first, the marker after it, so a crash between the two costs a duplicate.
alert_once() {
  local m="$H/state/archie-research.$1-$DAY"
  [ -e "$m" ] && return 0
  HARNESS="$H" "$H/bin/alert-line.sh" "$2" >/dev/null 2>&1 || true
  : > "$m" 2>/dev/null || true
}

# wreq <method> <path> [body]: _jobs_req in THIS shell (a 404's JOBS_BODY is
# what tells the route's own answer from a worker without it). WR is the
# answer, the error body on a non-2xx; the rc is _jobs_req's.
wreq() {
  local tmp rc
  WR=""
  tmp=$(mktemp "$W/req.XXXXXX") || return 1
  _jobs_req "$@" > "$tmp"; rc=$?
  WR=$(cat "$tmp"); rm -f "$tmp"
  [ "$rc" = 0 ] || WR="${JOBS_BODY:-}"
  return "$rc"
}

# claim <key> <kind> [source] [url] [title] -> rc 0 claimed (CLAIM_ATT is this
# attempt's number), 9 refused (CLAIM_WHY: terminal | attempt cap), 1 the
# ledger did not answer (no call).
claim() {
  local b rc
  CLAIM_ATT=""; CLAIM_WHY=""
  b=$(jq -nc --arg k "$1" --arg kind "$2" --arg s "${3:-}" --arg d "$DAY" --argjson m "$MAX_ATT" \
        --arg u "${4:-}" --arg t "${5:-}" \
    '{key: $k, kind: $kind, day: $d, max_attempts: $m}
     + (if $s == "" then {} else {source: $s} end)
     + (if $u == "" then {} else {url: $u} end)
     + (if $t == "" then {} else {title: $t[0:300]} end)') || return 1
  wreq POST /api/archie-research/claim "$b"; rc=$?
  case "$rc" in
    0) jq -e '.row.status == "claimed"' <<<"$WR" >/dev/null 2>&1 || return 1
       CLAIM_ATT=$(jq -r .row.attempts <<<"$WR"); return 0 ;;
    9) CLAIM_WHY=$(jq -r '.error // "refused"' <<<"$WR" 2>/dev/null); return 9 ;;
    *) log "warn: claim $1: the ledger did not answer (rc=$rc http=${JOBS_HTTP:-none})"; return 1 ;;
  esac
}

# settle <key> <ok|empty|failed> [extra-json]
settle() {
  local x="${3:-}" b rc
  [ -n "$x" ] || x='{}'
  b=$(jq -nc --arg k "$1" --arg s "$2" --argjson x "$x" '{key: $k, status: $s} + $x') || return 1
  wreq POST /api/archie-research/settle "$b"; rc=$?
  [ "$rc" = 0 ] || log "warn: settle $1 $2 not recorded (rc=$rc http=${JOBS_HTTP:-none})"
  return "$rc"
}

# money <usd|""> <in|""> <out|""> [tool_calls] -> the settle fields for a
# call's usage and cost. A blank stays absent: unpriced is never $0.
money() {
  jq -nc --arg c "${1:-}" --arg i "${2:-}" --arg o "${3:-}" --arg t "${4:-}" '
    {} + (if $i == "" then {} else {input_toks: ($i | tonumber)} end)
       + (if $o == "" then {} else {output_toks: ($o | tonumber)} end)
       + (if $t == "" then {} else {tool_calls: ($t | tonumber)} end)
       + (if $c == "" then {} else {cost_usd: ($c | tonumber)} end)'
}

spend_read() {
  wreq GET "/api/archie-research/spend?day=$DAY&reserve_usd=$RESERVE" || return 1
  SPENT=$(jq -r '.usd | numbers' <<<"$WR" 2>/dev/null)
  [[ $SPENT =~ ^[0-9]+(\.[0-9]+)?(e-?[0-9]+)?$ ]]
}
# spend_add <usd|"">: after a call, its price, or the reserve when unpriced.
spend_add() {
  SPENT=$(awk -v s="$SPENT" -v c="${1:-}" -v r="$RESERVE" 'BEGIN { printf "%.6f", s + (c == "" ? r : c) }')
}
# can_spend [max-usd]: rc 0 when one more call stays inside the cap. The call
# is counted at the reserve, or at its own ceiling when that is higher: an
# agent-call is capped at ARCHIE_RESEARCH_LLM_MAX_USD, not at the reserve, and
# checking it at the reserve would let it land the day past the cap.
can_spend() {
  local need
  need=$(awk -v r="$RESERVE" -v m="${1:-0}" 'BEGIN { print (m + 0 > r + 0) ? m : r }')
  # >>> cap check
  if awk -v s="$SPENT" -v r="$need" -v c="$CAP" 'BEGIN { exit !(s + r <= c + 0.0000001) }'; then
    return 0
  fi
  if [ "$CAP_HIT" = 0 ]; then
    log "cap reached (\$$(printf '%.6f' "$SPENT") spent + \$$need $([ "$need" = "$RESERVE" ] && echo reserve || echo 'call ceiling') > \$$CAP); no further billable call this run"
    alert_once cap "archie-research: the daily cap ARCHIE_RESEARCH_USD_CAP_DAY=\$$CAP is reached for $DAY (\$$(printf '%.2f' "$SPENT") spent, unpriced calls counted at \$$RESERVE). No more X searches, web scans or scoring calls today. If the cap is wrong, PUT /api/settings lane.archie-research.archie_research_usd_cap_day."
  fi
  CAP_HIT=1
  return 1
}
# call_ceiling -> what one agent-call may spend: the per-call knob or what is
# left of today's cap, whichever is lower, floored to the cent.
call_ceiling() { awk -v l="$LLM_USD" -v c="$CAP" -v s="$SPENT" 'BEGIN { r = c - s; v = (l + 0 < r) ? l + 0 : r; if (v < 0) v = 0; printf "%.2f", int(v * 100 + 1e-9) / 100 }'; }

# ac_cost <run_id> -> "usd<TAB>in<TAB>out" from the cost rows agent-call wrote
# under that run id (cost.csv col 23). usd is blank when there is no row or
# any row is unpriced.
ac_cost() {
  [ -r "$COST" ] || { printf '\t\t\n'; return 0; }
  awk -F, -v r="$1" '$23 == r { n++; if ($13 == "") b = 1; s += $13; i += $9; o += $10 }
    END { printf "%s\t%s\t%s\n", (n && !b) ? sprintf("%.6f", s) : "", n ? i : "", n ? o : "" }' "$COST"
}

# ── X: one search per topic per day ──────────────────────────────────────────
xsearch() {
  local topic="$1" key="$2" model="$3" base="$4" from="$5" pf body hdr resp code crc t0 dur parsed prc
  local in out tc cost note src rcf x fp
  pf="$W/xs.prompt"; body="$W/xs.body"; resp="$W/xs.resp"
  cat "$H/catalog/prompts/archie-research-xsearch.md" > "$pf" 2>/dev/null
  if ! ar_xai_body "$model" "$topic" "$from" "$pf" > "$body"; then
    log "topic $topic: request body could not be built; nothing sent"
    settle "$key" failed '{"note":"no-route","refund":true}' >/dev/null; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  hdr=$(mktemp "${TMPDIR:-/tmp}/archie-research-hdr.XXXXXX") || { settle "$key" failed '{"note":"refused","refund":true}' >/dev/null; return 0; }
  chmod 600 "$hdr"
  printf 'Authorization: Bearer %s\n' "$ARCHIE_XAI_API_KEY" > "$hdr"
  : > "$resp"
  t0=$(date +%s)
  X_CALLS=$((X_CALLS + 1))
  code=$(curl -sS -m 120 -o "$resp" -w '%{http_code}' -H @"$hdr" -H 'content-type: application/json' \
    --data-binary @"$body" "$base/v1/responses" 2>/dev/null); crc=$?
  rm -f "$hdr"
  dur=$(( $(date +%s) - t0 ))
  [[ $code =~ ^[0-9]{3}$ ]] || code=000
  parsed=$(ar_xai_parse "$resp"); prc=$?
  IFS=$'\t' read -r in out tc <<<"$(head -1 <<<"$parsed")"
  cost=$(ar_price "$model" "$in" "$out" "$tc") || cost=""
  if [ -z "$in$out" ]; then note="UNPRICED:no-usage"; src=none
  elif [ -z "$cost" ]; then note="UNPRICED:no-price"; src=result
  elif [ -z "$tc" ]; then note="xai:tool_calls=unknown"; src=result
  else note="xai:tool_calls=$tc"; src=result; fi
  if [ "$crc" != 0 ]; then rcf=$crc; elif [[ $code == 2* ]]; then rcf=0; else rcf=$code; fi
  # The cost row FIRST: a paid answer is in the ledger before anything acts on it.
  fp=$(printf '%s' "$ARCHIE_XAI_API_KEY" | sha256sum | cut -c1-12)
  [ -f "$COST" ] || printf '%s\n' "$COST_ROW_HDR" > "$COST"
  cost_row_emit "$(date -u +%FT%TZ),$(cost_csv_field "$(hostname)"),fleet,archie-xsearch,grok,$(cost_csv_field "$model"),$rcf,$dur,$in,$out,,,$cost,api,$fp,unknown,,$src,,$(COST_RUN_ID="archie-research:$key" cost_row_tags),$(cost_csv_field "$note"),archie-research," || true
  x=$(money "$cost" "$in" "$out" "$tc" | jq -c --rawfile r "$resp" '. + (if $r == "" then {} else {raw: $r[0:8000]} end)')
  if [ "$rcf" = 0 ] && [ "$prc" = 0 ]; then
    tail -n +2 <<<"$parsed" | jq -c '{source: "x", post_id, url, title: ((if .author == "" then "" else "@" + .author + ": " end) + .text)[0:120], text}' >> "$W/finds.jsonl"
    settle "$key" ok "$x" >/dev/null
  elif [ "$rcf" = 0 ] && [ "$prc" = 2 ]; then
    settle "$key" empty "$x" >/dev/null
  elif [ "$rcf" = 0 ]; then
    # A 2xx that does not parse was still billed: terminal, never bought again.
    settle "$key" empty "$(jq -c '. + {note: "unparseable"}' <<<"$x")" >/dev/null
    log "topic $topic: the X answer was billed but did not parse; recorded empty"
  else
    settle "$key" failed "$(jq -c --arg n "http=$code rc=$crc parse=$prc" '. + {note: $n}' <<<"$x")" >/dev/null
    log "topic $topic: X search failed (http=$code curl rc=$crc parse rc=$prc)"
  fi
  spend_add "$cost"
}

x_half() {
  local why="" model base from topic slug key rc
  local -a topics
  if [ -z "${ARCHIE_XAI_API_KEY:-}" ]; then why="ARCHIE_XAI_API_KEY is not set"
  elif [ "$ARCHIE_XAI_API_KEY" = "${XAI_API_KEY:-}" ]; then why="ARCHIE_XAI_API_KEY is the grok runner's XAI_API_KEY, the triage key"
  elif [ "$ARCHIE_XAI_API_KEY" = "${GROK_CODE_XAI_API_KEY:-}" ]; then why="ARCHIE_XAI_API_KEY is the grok runner's GROK_CODE_XAI_API_KEY"
  fi
  if [ -n "$why" ]; then
    X_OFF=1
    log "X half skipped: $why; no other key is ever used"
    alert_once xkey "archie-research: $why, so today's X searches were skipped (the web scan is asked to search X through web results instead). To turn X on: create a new xAI API key for Archie at console.x.ai with its own monthly spend limit, then put it in the hub env as ARCHIE_XAI_API_KEY (/etc/harness/env/global.env). Do not reuse the grok runner's XAI_API_KEY."
    return 0
  fi
  if ! model=$(lane_role_model archie-research.xsearch) || [ -z "$model" ]; then
    X_OFF=1
    log "X half skipped: no model route for archie-research.xsearch (rc 75); nothing guessed"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  if ! base=$(endpoint_url xai 2>/dev/null) || [ -z "$base" ]; then
    X_OFF=1
    log "X half skipped: endpoint_url xai did not resolve"; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  from=$(date -u -d "@$((NOW - 86400))" +%F)
  IFS='|' read -r -a topics <<<"$TOPICS"
  for topic in "${topics[@]:0:10}"; do
    topic="${topic#"${topic%%[![:space:]]*}"}"; topic="${topic%"${topic##*[![:space:]]}"}"
    slug=$(ar_topic_slug "$topic")
    [ -n "$slug" ] || continue
    TOPIC_N=$((TOPIC_N + 1))
    can_spend || break
    key="xq:$slug:$DAY"
    claim "$key" xquery x; rc=$?
    case "$rc" in
      0) xsearch "$topic" "$key" "$model" "$base" "$from" ;;
      9) ;;  # searched today already (terminal) or out of attempts
      *) SKIPPED=$((SKIPPED + 1)) ;;
    esac
  done
}

# ── web: one scan per day ────────────────────────────────────────────────────
web_half() {
  local model key rid pf raw rc usd in out x arr n t ceil e v
  if ! model=$(lane_role_model stage.archie-research) || [ -z "$model" ]; then
    log "web scan skipped: no model route for stage.archie-research (rc 75); nothing guessed"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  ceil=$(call_ceiling)
  can_spend "$ceil" || return 0
  key="wq:$DAY"
  claim "$key" webscan web; rc=$?
  case "$rc" in 0) ;; 9) return 0 ;; *) SKIPPED=$((SKIPPED + 1)); return 0 ;; esac
  rid="archie-research:$key:a$CLAIM_ATT"
  pf="$W/web.prompt"; raw="$W/web.answer"
  { cat "$H"/prompts/archie-soul.d/*.md 2>/dev/null; printf '\n'
    cat "$H/catalog/prompts/archie-research-scan.md" 2>/dev/null
    printf '\n## Topics\n'
    IFS='|' read -r -a ts <<<"$TOPICS"
    for t in "${ts[@]:0:10}"; do t="${t#"${t%%[![:space:]]*}"}"; [ -n "$t" ] && printf -- '- %s\n' "$t"; done
    if [ "$X_OFF" = 1 ]; then
      printf '\n## X is off today\n\nThe X search did not run, so also search X through the web: site:x.com queries for each topic. Give the post url.\n'
    fi
    printf '\nToday is %s.\n' "$DAY"
  } > "$pf"
  : > "$raw"
  WEB_CALLS=$((WEB_CALLS + 1))
  AGENT_CALL_LANE=archie-research AGENT_CALL_FP="archie-research:$key" COST_RUN_ID="$rid" \
    AGENT_CALL_RUNNERS=claude AGENT_CALL_TOOLS="$SCAN_TOOLS" AGENT_DISALLOWED_TOOLS="$NO_WRITE_TOOLS" \
    AGENT_CALL_BUDGET_USD_ARCHIE_RESEARCH="$ceil" \
    "$H/bin/agent-call.sh" archie-research fleet "$model" 600 "$raw" "@$pf" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then
    log "web scan: agent-call refused (rc=$rc, nothing billed); the attempt is handed back"
    settle "$key" failed '{"note":"refused","refund":true}' >/dev/null; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  IFS=$'\t' read -r usd in out <<<"$(ac_cost "$rid")"
  x=$(money "$usd" "$in" "$out")
  spend_add "$usd"
  if [ "$rc" != 0 ]; then
    log "web scan: agent-call failed (rc=$rc)"
    settle "$key" failed "$(jq -c --arg n "agent-call rc=$rc" '. + {note: $n}' <<<"$x")" >/dev/null; return 0
  fi
  if ! arr=$(ar_answer_array "$raw"); then
    # Billed all the same: terminal, so the day's scan is not bought again.
    log "web scan: the answer held no JSON array; recorded empty"
    settle "$key" empty "$(jq -c --rawfile r "$raw" '. + {note: "unparseable", raw: $r[0:8000]}' <<<"$x")" >/dev/null; return 0
  fi
  # A video (a YouTube url, or kind video) carries its channel and date in the
  # title, and says in its text that nobody read the transcript.
  n=0
  while IFS= read -r e; do
    v=false
    if ar_is_video "$(jq -r .url <<<"$e")" || [ "$(jq -r '.kind // ""' <<<"$e")" = video ]; then v=true; fi
    jq -c --argjson v "$v" '
      def s($x; $m): if ($x | type) == "string" and ($x | length) > 0 then $x[0:$m] else null end;
      {source: "web", url, video: $v,
       title: (((.title // "") | tostring)
               + (if $v then " (" + (["YouTube", s(.channel; 100), s(.published; 40)] | map(select(. != null)) | join(", ")) + ")" else "" end))[0:300],
       text: (if $v and .transcript_read != true
              then ((.summary // "") | tostring | .[0:920]) + " Video: transcript not read, judged from its title and description only."
              else (.summary // "") | tostring | .[0:1000] end)}' <<<"$e" >> "$W/finds.jsonl" && n=$((n + 1))
  done < <(jq -c '.[0:25][] | select(type == "object" and (.url | type) == "string")' <<<"$arr")
  x=$(jq -c --rawfile r "$raw" '. + {raw: $r[0:8000]}' <<<"$x")
  if [ "${n:-0}" -gt 0 ]; then settle "$key" ok "$x" >/dev/null; else settle "$key" empty "$x" >/dev/null; fi
}

# ── dedup, claim and score the finds ─────────────────────────────────────────
# handback <first-line>: every batch item from that line on never reached a
# model. Its attempt is handed back (refund) and the find is kept in raw, so the
# retry path offers it again next scan.
handback() {
  local it
  while IFS= read -r it; do
    settle "$(jq -r .key <<<"$it")" failed "$(jq -c '{note: "refused", refund: true, raw: (tojson | .[0:8000])}' <<<"$it")" >/dev/null
  done < <(tail -n +"$1" "$W/batch.jsonl")
}
# item_failed <item-json> <note>: a find whose scoring call billed: failed with
# the attempt counted, the find kept in raw for the retry path.
item_failed() {
  settle "$(jq -r .key <<<"$1")" failed "$(jq -c --arg n "$2" '{note: $n, raw: (tojson | .[0:8000])}' <<<"$1")" >/dev/null
}

# retry_list -> $W/retry.jsonl: the finds settled failed in the last 7 days that
# are still under the attempt cap, fewest attempts first, each as the find it
# was: its stored raw, or (a row from before BH-4762, raw NULL) its title and
# url. A list that cannot be read is one warn line: nothing extra is bought.
retry_list() {
  local from r k
  : > "$W/retry.jsonl"
  from=$(date -u -d "@$((NOW - 6 * 86400))" +%F)
  if wreq GET "/api/archie-research?from=$from&to=$DAY&kind=item&status=failed"; then  # >>> retry list
    jq -c --argjson m "$MAX_ATT" '[.rows[]? | select(.attempts < $m)] | sort_by(.attempts, .id) | .[]' <<<"$WR" > "$W/failed.jsonl" 2>/dev/null \
      || : > "$W/failed.jsonl"
  else
    log "warn: the failed finds could not be listed (http=${JOBS_HTTP:-none}); only new finds are scored this run"
    return 0
  fi
  while IFS= read -r r; do
    k=$(jq -r .dedupe_key <<<"$r")
    wreq GET "/api/archie-research?key=$k" || WR='{}'
    jq -c --arg k "$k" --argjson l "$r" '
      ((.row.raw // "") | try fromjson catch null) as $j
      | (if ($k | startswith("x:")) then "x" else "web" end) as $src
      | if ($j | type) == "object" and $j.key == $k
        then {key: $k, source: ($j.source // $l.source // $src), url: ($j.url // $l.url // ""),
              title: ($j.title // $l.title // ""), text: ($j.text // ""), video: ($j.video == true)}
        else {key: $k, source: ($l.source // $src), url: ($l.url // ""), title: ($l.title // ""), text: "", video: false} end' \
      <<<"$WR" >> "$W/retry.jsonl" 2>/dev/null
  done < "$W/failed.jsonl"
  [ -s "$W/retry.jsonl" ] && log "retry: $(grep -c . "$W/retry.jsonl") failed finds re-offered"
  return 0
}

score_finds() {
  local model it key rc bkey rid pf raw usd in out x ans n ok_n ceil nb nc ci first k later
  : > "$W/norm.jsonl"
  [ -s "$W/finds.jsonl" ] && ar_items_norm < "$W/finds.jsonl" > "$W/norm.jsonl"
  FINDS=$(grep -c . "$W/norm.jsonl")
  retry_list
  # The retries first, then today's finds; a key in both is claimed once.
  cat "$W/retry.jsonl" "$W/norm.jsonl" \
    | jq -c -s 'reduce .[] as $i ({seen: {}, out: []}; if .seen[$i.key] then . else .seen[$i.key] = true | .out += [$i] end) | .out[]' \
    > "$W/merged.jsonl"
  nb=$(grep -c . "$W/merged.jsonl")
  [ "$nb" -gt 0 ] || return 0
  # Nothing is claimed that cannot be scored this run: a claimed item waits
  # for its score and a later claim would count a second attempt.
  if ! model=$(lane_role_model stage.archie-research) || [ -z "$model" ]; then
    log "scoring skipped: no model route for stage.archie-research (rc 75); $nb finds deferred"
    DEFERRED=$nb; return 0
  fi
  if ! can_spend "$(call_ceiling)"; then DEFERRED=$nb; return 0; fi
  : > "$W/batch.jsonl"
  while IFS= read -r it; do
    if [ "$NEW" -ge "$MAX_ITEMS" ]; then DEFERRED=$((DEFERRED + 1)); continue; fi
    key=$(jq -r .key <<<"$it")
    CLAIM_SKIP=0
    claim "$key" item "$(jq -r .source <<<"$it")" "$(jq -r .url <<<"$it")" "$(jq -r .title <<<"$it")"; rc=$?
    case "$rc" in
      0) ;;
      9) CLAIM_SKIP=1 ;;  # >>> claim refused
      *) CLAIM_SKIP=1; SKIPPED=$((SKIPPED + 1)) ;;
    esac
    [ "$CLAIM_SKIP" = 1 ] && continue
    NEW=$((NEW + 1))
    jq -c --argjson a "${CLAIM_ATT:-1}" '{key, source, url, title, text, video: (.video == true), attempt: $a}' <<<"$it" >> "$W/batch.jsonl"
  done < "$W/merged.jsonl"
  [ "$DEFERRED" -gt 0 ] && log "$DEFERRED finds deferred past ARCHIE_RESEARCH_MAX_ITEMS=$MAX_ITEMS; a failed one is offered again next scan, a new one only if a later search returns it"
  [ -s "$W/batch.jsonl" ] || return 0

  nb=$(grep -c . "$W/batch.jsonl"); nc=$(( (nb + SCORE_BATCH - 1) / SCORE_BATCH ))
  for ((ci = 1; ci <= nc; ci++)); do
    first=$(( (ci - 1) * SCORE_BATCH + 1 ))
    sed -n "${first},$((first + SCORE_BATCH - 1))p" "$W/batch.jsonl" > "$W/chunk.jsonl"
    k=$(grep -c . "$W/chunk.jsonl")
    # A chunk gets 300 s; none starts unless it can finish inside the run.
    if [ $((SECONDS + 300 + 30)) -gt "$RUN_S" ]; then
      log "run deadline: $((nb - first + 1)) finds handed back"; handback "$first"; return 0
    fi
    ceil=$(call_ceiling)
    if ! can_spend "$ceil"; then
      log "scoring: $((nb - first + 1)) finds handed back (call ceiling \$$ceil, under the cap's headroom)"
      handback "$first"; return 0
    fi
    bkey="sb:$(jq -r '"\(.key):\(.attempt)"' "$W/chunk.jsonl" | sort | sha256sum | cut -c1-16)"
    claim "$bkey" batch; rc=$?
    if [ "$rc" != 0 ]; then
      # Nothing was bought. A ledger that did not answer (rc 1) hands each item's
      # attempt back, so a blip never uses up a find; a refusal (rc 9) counts it,
      # which is what moves the chunk key on (it hashes the attempts).
      log "scoring chunk $ci/$nc $bkey not claimed (rc=$rc ${CLAIM_WHY:-}); its $k items are left failed"
      while IFS= read -r it; do
        if [ "$rc" = 1 ]; then
          settle "$(jq -r .key <<<"$it")" failed "$(jq -c '{note: "refused", refund: true, raw: (tojson | .[0:8000])}' <<<"$it")" >/dev/null
        else
          item_failed "$it" "batch not claimed"
        fi
      done < "$W/chunk.jsonl"
      SKIPPED=$((SKIPPED + 1)); continue
    fi
    rid="archie-research:$bkey:a$CLAIM_ATT"
    pf="$W/score.prompt"; raw="$W/score.answer"
    { cat "$H"/prompts/archie-soul.d/*.md 2>/dev/null; printf '\n'
      cat "$H/catalog/prompts/archie-research-score.md" 2>/dev/null
      printf '\n## Finds\n'
      jq -sc 'map({key, source, url, title, text})' "$W/chunk.jsonl"
    } > "$pf"
    : > "$raw"
    SCORE_CALLS=$((SCORE_CALLS + 1))
    AGENT_CALL_LANE=archie-research AGENT_CALL_FP="archie-research:$bkey" COST_RUN_ID="$rid" \
      AGENT_CALL_RUNNERS=claude AGENT_CALL_NO_TOOLS=1 AGENT_DISALLOWED_TOOLS="$NO_WRITE_TOOLS" \
      AGENT_CALL_BUDGET_USD_ARCHIE_RESEARCH="$ceil" \
      "$H/bin/agent-call.sh" archie-research fleet "$model" 300 "$raw" "@$pf" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then
      log "scoring: agent-call refused (rc=$rc, nothing billed); $((nb - first + 1)) finds are handed back"
      settle "$bkey" failed '{"note":"refused","refund":true}' >/dev/null
      handback "$first"
      SKIPPED=$((SKIPPED + 1)); return 0
    fi
    IFS=$'\t' read -r usd in out <<<"$(ac_cost "$rid")"
    x=$(money "$usd" "$in" "$out")
    spend_add "$usd"
    ans=""
    [ "$rc" = 0 ] && ans=$(ar_answer_array "$raw")
    if [ -z "$ans" ]; then
      # Billed and unusable: this chunk's finds count the attempt and come back
      # next scan; nothing after it is bought this run.
      later=$((nb - first + 1 - k))
      log "scoring: chunk $ci/$nc failed (agent-call rc=$rc); its $k finds retry next scan, $later handed back"
      settle "$bkey" failed "$(jq -c --arg n "agent-call rc=$rc" '. + {note: $n}' <<<"$x")" >/dev/null
      while IFS= read -r it; do item_failed "$it" "scoring failed"; done < "$W/chunk.jsonl"
      handback $((first + k))
      return 0
    fi
    settle "$bkey" ok "$(jq -c --rawfile r "$raw" '. + {raw: $r[0:8000]}' <<<"$x")" >/dev/null
    # Only the chunk's own keys are read: a key the answer invents is ignored.
    # An entry that applies must name the stage it changes, or it is unusable.
    ok_n=0
    while IFS= read -r it; do
      key=$(jq -r .key <<<"$it")
      n=$(jq -c --arg k "$key" --argjson v "$(jq '.video == true' <<<"$it")" '
        def txt($v; $m): if ($v | type) == "string" and ($v | length) > 0 then $v[0:$m] else null end;
        [.[] | select(type == "object" and .key == $k)] | first
        | if . == null or (.applies | type) != "boolean" or (.score | type) != "number" or .score < 0 or .score > 10
          then {fail: "not in the scoring answer"}
          else
            ((.stage | select(type == "string" and IN("triage", "plan", "execute", "review", "merge", "cost", "model-routing"))) // null) as $st
            | ((.model_route | select(type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$"))) // null) as $mr
            | if .applies == true and $st == null then {fail: "no stage in the scoring answer"}
              else
                ([ (if $st then "Stage: " + $st else empty end),
                   (txt(.change; 500) | select(. != null) | "Change: " + .),
                   (txt(.effect; 500) | select(. != null) | "Expected effect: " + .),
                   (txt(.cost; 500) | select(. != null) | "Cost: " + .),
                   (if $mr then "Model route to change: " + $mr + " (a suggestion; Archie does not edit routing)" else empty end)
                 ] | join("\n")) as $extra
                | (txt(.proposal_summary; 2000) // "") as $base
                | {ok: ({applies, score, why: txt(.why; 1000), proposal_title: txt(.proposal_title; 300),
                         proposal_summary: txt((if $base != "" and $extra != "" then $base + "\n\n" + $extra else $base + $extra end); 2000),
                         note: (if $v then "video: transcript not read" else null end)}
                        | with_entries(select(.value != null)))}
              end
          end' <<<"$ans" 2>/dev/null)
      [ -n "$n" ] || n='{"fail":"not in the scoring answer"}'
      if jq -e 'has("ok")' <<<"$n" >/dev/null 2>&1; then
        settle "$key" ok "$(jq -c .ok <<<"$n")" >/dev/null && ok_n=$((ok_n + 1))
      else
        item_failed "$it" "$(jq -r '.fail // "not in the scoring answer"' <<<"$n")"
      fi
    done < "$W/chunk.jsonl"
    SCORED=$((SCORED + ok_n))
  done
}

# ── proposals into the existing Ideas ledger ────────────────────────────────
esc() { jq -rn --arg v "$1" '$v | @html'; }

# propose <row-json>: the files, the ledger entry, the product_proposals row,
# the proposal beat, then the item's slug. Each step only after the last one
# landed; anything that did not is retried by the next scan.
propose() {
  local r="$1" key url title summary why score slug dir entry detail payload
  key=$(jq -r .dedupe_key <<<"$r"); url=$(jq -r '.url // ""' <<<"$r")
  title=$(jq -r '.proposal_title // .title // .dedupe_key' <<<"$r")
  summary=$(jq -r '.proposal_summary // .title // ""' <<<"$r")
  why=$(jq -r '.why // ""' <<<"$r"); score=$(jq -r '.score' <<<"$r")
  [[ $url == https://* ]] || { log "item $key has no source url; no proposal"; return 0; }
  slug="archie-$(printf '%s' "$key" | sha256sum | cut -c1-12)"
  dir="$H/state/archie-research/$slug"
  mkdir -p "$dir" || return 0
  cat > "$dir/ticket.html" <<EOF
<h2>$(esc "$title")</h2>
<p>$(esc "$summary")</p>
<p><strong>Why it applies to us:</strong> $(esc "$why")</p>
<p><strong>Archie's score:</strong> $(esc "$score")/10</p>
<p><strong>Source:</strong> <a href="$(esc "$url")">$(esc "$url")</a></p>
$(if [[ $(jq -r '.note // ""' <<<"$r") == video* ]]; then printf '%s' '<p><strong>Note:</strong> this source is a video and its transcript was not read.</p>'; fi)
{{MOCKUP_BLOCK}}
EOF
  cat > "$dir/mockup.html" <<EOF
<h3>Sources</h3>
<ul>
<li><a href="$(esc "$url")">$(esc "$(jq -r '.title // .dedupe_key' <<<"$r")")</a></li>
</ul>
EOF
  [ -f "$LEDGER" ] || echo '[]' > "$LEDGER"
  jq -e 'type == "array"' "$LEDGER" >/dev/null 2>&1 || { log "warn: $LEDGER is not a JSON array; no proposal written"; return 0; }
  if ! jq -e --arg s "$slug" 'any(.[]; .slug == $s)' "$LEDGER" >/dev/null; then
    # The artifact bodies ride IN the record: approve runs on the project's
    # owning box, where $dir does not exist, and bin/post-proposal.sh writes
    # them out there from the row (prow_restore carries the record over).
    entry=$(jq -nc --arg s "$slug" --arg t "$title" --arg sm "$summary" --arg w "$why" --arg sc "$score" \
      --arg d "$dir" --arg u "$url" --arg k "$key" --arg now "$NOWISO" \
      --rawfile th "$dir/ticket.html" --rawfile mh "$dir/mockup.html" \
      '{slug: $s, title: $t, summary: $sm, source: "archie-research", department: "research",
        status: "gate_pending", rev: 1, dir: $d, links: [$u], why: $w, score: ($sc | tonumber? // null),
        artifacts: {ticket_html: $th, mockup_html: $mh},
        item_key: $k, created_at: $now, updated_at: $now}') \
      || { log "item $key: proposal $slug's files could not be read; retried next scan"; return 0; }
    jq -c --argjson e "$entry" '. + [$e]' "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
  fi
  if prow_put "$PROJECT" "$slug" "$LEDGER" gate_pending if_absent; then
    detail=$(printf 'Source: %s\n\nWhy it applies to us: %s\n\nScore: %s/10\n\n%s' "$url" "$why" "$score" "$summary")
    payload=$(jq -nc --arg p "$PROJECT" --arg s "$slug" --arg t "$title" --arg sm "$summary" --arg d "$detail" \
      '{kind: "proposal", pkey: ("prop:" + $p + ":" + $s), project: $p, slug: $s, title: $t, summary: $sm,
        department: "research", status: "gate_pending", rev: 1, detail: $d}')
    if BEAT_STRICT=1 "$H/bin/beat.sh" "$payload" >/dev/null 2>&1; then
      if settle "$key" ok "$(jq -nc --arg s "$slug" '{proposal_slug: $s}')" >/dev/null; then
        PROPOSALS=$((PROPOSALS + 1))
        # The daily beat's pick: title, score, stage (from the summary's Stage: line).
        jq -r --arg t "$title" '[($t | gsub("[\t\n]"; " ")), (.score | tostring),
            ((.proposal_summary // "") | (capture("(^|\n)Stage: (?<s>[a-z-]+)") | .s) // "")] | @tsv' <<<"$r" >> "$W/proposed.tsv"
      fi
    else
      log "item $key: proposal $slug recorded but its beat was not delivered; resent next scan"
    fi
  else
    log "item $key: proposal $slug not recorded in product_proposals (rc=$?); retried next scan"
  fi
}

proposals() {
  local from r
  from=$(date -u -d "@$((NOW - 7 * 86400))" +%F)
  if ! wreq GET "/api/archie-research?from=$from&to=$DAY&kind=item&status=ok"; then
    log "warn: the scored finds could not be listed (http=${JOBS_HTTP:-none}); proposals wait for the next scan"
    return 0
  fi
  [ "$(jq -r '.truncated == true' <<<"$WR")" = true ] && log "warn: more than 500 scored finds in 7 days; only the first 500 were considered for proposals"
  while IFS= read -r r; do
    propose "$r"
  done < <(jq -c --argjson m "$MIN_SCORE" \
    '.rows[]? | select(.applies == 1 and (.score // -1) >= $m and (.proposal_slug // "") == "")' <<<"$WR")
}

# daily_beat: ONE line to the operator on a day this lane proposed something. The
# marker is written only after the beat answered, so a failed beat is sent by
# the next run that day that also proposes; a run with no proposal sends none.
daily_beat() {
  local m="$H/state/archie-research.daily-$DAY" t sc st line rc
  [ "$PROPOSALS" -gt 0 ] && [ -s "$W/proposed.tsv" ] || return 0
  [ -e "$m" ] && return 0
  IFS=$'\t' read -r t sc st <<<"$(sort -t $'\t' -k2,2gr "$W/proposed.tsv" | head -1)"
  line=$(jq -rn --arg n "$PROPOSALS" --arg t "$t" --arg sc "$sc" --arg st "$st" \
    '"Archie found \($n) idea(s) worth a look today. Top: \($t) (\($sc)/10\(if $st == "" then "" else ", " + $st end)). They are on the Ideas screen as gate_pending."
     | gsub("\\s*[—–]\\s*"; ", ")')
  line=$(archie_sign "$line")
  if "$H/bin/archie-tg-send.sh" "archie-research:daily:$DAY" "$line" >/dev/null 2>&1; then
    : > "$m" 2>/dev/null || true
    log "daily beat sent ($PROPOSALS proposals)"
  else
    rc=$?
    log "daily beat not delivered (rc=$rc); no marker, so the next run today that proposes sends one"
  fi
}

scan() {
  TOPIC_N=0; X_CALLS=0; WEB_CALLS=0; SCORE_CALLS=0; FINDS=0; NEW=0; DEFERRED=0; SCORED=0; PROPOSALS=0
  SKIPPED=0; CAP_HIT=0; X_OFF=0
  : > "$W/finds.jsonl"; : > "$W/proposed.tsv"
  if ! spend_read; then
    log "spend unreadable (http=${JOBS_HTTP:-none}); no vendor call this run (no spend without the ledger)"
    exit 0
  fi
  x_half
  web_half
  score_finds
  proposals
  daily_beat
  log "topics=$TOPIC_N x_calls=$X_CALLS web_calls=$WEB_CALLS finds=$FINDS new=$NEW deferred=$DEFERRED scored=$SCORED proposals=$PROPOSALS spent=\$$(printf '%.6f' "$SPENT")/\$$CAP skipped=$SKIPPED"
}

# ── the weekly digest ────────────────────────────────────────────────────────
digest() {
  local t dow start end wk key rc body
  t=$((NOW - 7 * 86400))
  wk=$(date -u -d "@$t" +%G-W%V)
  dow=$(date -u -d "@$t" +%u)
  start=$(date -u -d "@$((t - (dow - 1) * 86400))" +%F)
  end=$(date -u -d "@$((t + (7 - dow) * 86400))" +%F)
  key="digest:$wk"
  claim "$key" digest; rc=$?
  case "$rc" in
    0) ;;
    9) [ "$CLAIM_WHY" = "attempt cap" ] && alert_once "digest-$wk" \
         "archie-research: the $wk research digest failed $MAX_ATT times and was not sent. Check logs/archie-research.log and logs/archie.log (bin/archie-tg-send.sh)."
       return 0 ;;
    *) return 0 ;;
  esac
  if ! wreq GET "/api/archie-research?from=$start&to=$end"; then
    log "digest $wk: the week's rows could not be read (http=${JOBS_HTTP:-none}); retried tomorrow"
    settle "$key" failed '{"note":"rows unreadable"}' >/dev/null; return 0
  fi
  body=$(jq -r --arg wk "$wk" --arg s "$start" --arg e "$end" '
    def ok_items: [.rows[] | select(.kind == "item" and .status == "ok" and .score != null)];
    if (ok_items | length) == 0 then empty else
    [.rows[] | select(.kind == "xquery" or .kind == "webscan")] as $q
    | [.rows[] | select(.kind == "item")] as $it
    | ([.rows[] | .cost_usd // 0] | add // 0) as $usd
    | ([.rows[] | select(.kind != "item" and .kind != "digest") | (.attempts - .priced) | select(. > 0)] | add // 0) as $unp
    | (ok_items | sort_by(-.score, .id) | .[0:5]) as $top
    | "Research digest for \($wk) (\($s) to \($e)).\n\n"
      + "Searched \($q | length) times (\([$q[] | select(.status == "empty")] | length) came back empty, \([$q[] | select(.status == "failed")] | length) failed). "
      + "Found \($it | length) new things, scored \(ok_items | length), proposed \([$it[] | select(.proposal_slug != null)] | length) to the Ideas screen. "
      + "Spent $\($usd * 100 | round / 100)\(if $unp > 0 then ", plus \($unp) unpriced calls" else "" end).\n\nTop finds:"
      + ($top | map("\n- \(.proposal_title // .title // .dedupe_key) (\(.score)/10)\n  \(.url // "no url")"
          + (if .proposal_slug then "\n  proposal \(.proposal_slug)" else "" end)) | join(""))
      + (if .truncated == true then "\n\nThe week had more rows than one read returns: these are from the first 500 only." else "" end)
    | gsub("\\s*[—–]\\s*"; ", ") | .[0:3990] end' <<<"$WR")
  if [ -z "$body" ]; then
    settle "$key" empty '{"note":"nothing scored this week"}' >/dev/null
    log "digest $wk: nothing scored, no beat"; return 0
  fi
  body=$(archie_sign "$body")
  if "$H/bin/archie-tg-send.sh" "archie-research:$key" "$body" >/dev/null 2>&1; then
    settle "$key" ok >/dev/null
    log "digest $wk: sent"
  else
    rc=$?
    settle "$key" failed "$(jq -nc --arg n "send rc=$rc" '{note: $n}')" >/dev/null
    log "digest $wk: not delivered (archie-tg-send.sh rc=$rc); retried tomorrow"
  fi
}

# The 06:40 scan and the 07:10 digest are two modes: the mode is the one-run
# key (BH-7422), so a long scan never turns the digest away.
LANE_RUN_KEY=${1:-scan}
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit archie-research
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie-research
case "${ARCHIE_RESEARCH_ENABLED:-1}" in
  0) exit 0 ;;
  1) ;;
  *) log "warn: ARCHIE_RESEARCH_ENABLED=${ARCHIE_RESEARCH_ENABLED} is not 0 or 1; using the default 1" ;;
esac
exec 9>"$H/locks/archie-research.lock" || exit 0
flock -n 9 || exit 0

CAP=$(knob_num ARCHIE_RESEARCH_USD_CAP_DAY "${ARCHIE_RESEARCH_USD_CAP_DAY:-3.00}" 3.00 100)
MAX_ATT=$(knob_int ARCHIE_RESEARCH_MAX_ATTEMPTS "${ARCHIE_RESEARCH_MAX_ATTEMPTS:-3}" 3 1 10)
RESERVE=$(knob_num ARCHIE_RESEARCH_RESERVE_USD "${ARCHIE_RESEARCH_RESERVE_USD:-0.25}" 0.25 10)
LLM_USD=$(knob_num ARCHIE_RESEARCH_LLM_MAX_USD "${ARCHIE_RESEARCH_LLM_MAX_USD:-0.50}" 0.50 10)
MAX_ITEMS=$(knob_int ARCHIE_RESEARCH_MAX_ITEMS "${ARCHIE_RESEARCH_MAX_ITEMS:-20}" 20 1 100)
MIN_SCORE=$(knob_int ARCHIE_RESEARCH_MIN_SCORE "${ARCHIE_RESEARCH_MIN_SCORE:-7}" 7 0 10)
SCORE_BATCH=$(knob_int ARCHIE_RESEARCH_SCORE_BATCH "${ARCHIE_RESEARCH_SCORE_BATCH:-6}" 6 1 25)
# Seconds the scan may spend before it stops starting scoring calls: inside the
# outer timeout 1800, and clear of the 07:10Z digest on the same lock.
RUN_S=1700
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_RUN_S:-} =~ ^[0-9]+$ ]]; then RUN_S=$ARCHIE_RUN_S; fi
TOPICS="${ARCHIE_RESEARCH_TOPICS:-AI software factories|autonomous SDLC|agent harnesses|improving AI dev loops|Anthropic and AI vendor releases|new AI model releases (Anthropic, OpenAI, Google, xAI, open-weight) and what they change for coding agents|automated SDLC and software factory talks on YouTube}"
PROJECT="${ARCHIE_RESEARCH_PROJECT:-cromford}"
[[ $PROJECT =~ ^[A-Za-z0-9._-]{1,128}$ ]] || { log "warn: ARCHIE_RESEARCH_PROJECT=$PROJECT is not a project name; using cromford"; PROJECT=cromford; }
LEDGER="$H/state/archie-research.ledger.json"

case "$MODE" in
  scan) scan ;;
  digest) digest ;;
esac
exit 0
