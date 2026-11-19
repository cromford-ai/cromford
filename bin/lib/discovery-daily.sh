#!/bin/bash
# bin/lib/discovery-daily.sh — BH-9795: the run of the discovery-daily lane.
# Sourced by bin/discovery-daily.sh, never executed. The caller sets DD_P (the
# project), ST_NOW (epoch) and ST_TMP (a private temp dir), then calls dd_run.
#
# SHARED CODE. This file sources bin/lib/sentry-triage.sh (BH-5620) and sets
# its parameters: ST_LANE=discovery-daily (log and ledger kinds),
# ST_MAX_ATTEMPTS, ST_OPEN_LABEL="" (every open issue), ST_RAW_DIR, ST_DAY.
# The ledger, cap, attempt, filing and comment code is that file's.
#
# dd_run, in this order:
#   1. claim discovery-daily-run/<project>/<date> (running, stale after
#      DISCOVERY_RUN_TIMEOUT_S + 60, terminal done). Held done or running: one
#      log line, return. Ledger outage: one warn discovery-daily-ledger, return.
#      Write discovery-daily-since/<project> {since: <date>} when absent.
#      Delete raw date dirs older than DISCOVERY_RAW_KEEP_D days.
#   2. for each source in DISCOVERY_SOURCES: dd_src_<src>_list <raw-dir>
#      (bin/lib/discovery/<src>.sh). rc 3 = not-configured (one log line);
#      rc 1 = the fetch failed (one warn discovery-daily-list).
#   3. the raw list stays in state/discovery-daily/<project>/<date>/.
#   4-8. dd_item per item, most events first: the code filter, the caps, ONE
#      model call, the rules table (bin/lib/discovery/rules.sh), the act. A
#      day cap stops the loop: the rest count as capped and come back tomorrow.
#   9. the run row done {counts, usd}, one log line, one Telegram summary.
#
# Ledger kinds (natural keys):
#   discovery-daily        <project>/<source>/<id>  the item row: retry |
#                          diagnosed | ticketed | noise | failed. Detail: the
#                          fetched fields, attempts, last_rc, answers, diagnosis
#                          (the draft), decision, action, issue, url, reason, why.
#   discovery-daily-day    <project>/<date>  {filed: [<src>/<id>], calls: n}
#   discovery-daily-run    <project>/<date>  running | done | failed {counts}
#   discovery-daily-since  <project>         active {since: <first run date>}
# Body marker: <!-- discovery: <source>/<id> --> on a ticket and on a comment.
#
# gh-rest: no-graphql
# shellcheck source=bin/lib/sentry-triage.sh
[ "$(type -t st_issue)" = function ] || . "$(dirname "${BASH_SOURCE[0]}")/sentry-triage.sh" || return 1
# shellcheck source=bin/lib/discovery/rules.sh
. "$(dirname "${BASH_SOURCE[0]}")/discovery/rules.sh" || return 1

ST_LANE=discovery-daily
ST_OPEN_LABEL=""

_dd_log() { _st_log "[${DD_P:-?}] $*"; }
_dd_alert() { "$(_st_root)/bin/lane-alert.sh" --severity warn --id "$1" discovery-daily "[$DD_P] $2" >/dev/null 2>&1 || true; }

# dd_knobs: read every knob once per run. Out of range is one log line and the
# default (_st_knob_int). The ST_* names are the ones the shared code reads.
dd_knobs() {
  ST_MIN_EVENTS=$(_st_knob_int DISCOVERY_MIN_EVENTS "${DISCOVERY_MIN_EVENTS:-3}" 3 1 100000)
  ST_MAX_DAY=$(_st_knob_int DISCOVERY_TICKETS_DAY "${DISCOVERY_TICKETS_DAY:-5}" 5 0 50)
  ST_MAX_CALLS_DAY=$(_st_knob_int DISCOVERY_MAX_CALLS_DAY "${DISCOVERY_MAX_CALLS_DAY:-10}" 10 0 200)
  ST_LOOKBACK_H=$(_st_knob_int DISCOVERY_LOOKBACK_H "${DISCOVERY_LOOKBACK_H:-24}" 24 1 336)
  ST_HOTFIX_24H=$(_st_knob_int DISCOVERY_HOTFIX_24H "${DISCOVERY_HOTFIX_24H:-50}" 50 1 1000000)
  ST_MAX_ATTEMPTS=$(_st_knob_int DISCOVERY_MAX_ATTEMPTS "${DISCOVERY_MAX_ATTEMPTS:-3}" 3 1 10)
  DD_RAW_KEEP_D=$(_st_knob_int DISCOVERY_RAW_KEEP_D "${DISCOVERY_RAW_KEEP_D:-14}" 14 1 365)
  DD_RUN_TIMEOUT_S=$(_st_knob_int DISCOVERY_RUN_TIMEOUT_S "${DISCOVERY_RUN_TIMEOUT_S:-1500}" 1500 60 3600)
  DD_CALL_TIMEOUT_S=$(_st_knob_int DISCOVERY_CALL_TIMEOUT_S "${DISCOVERY_CALL_TIMEOUT_S:-300}" 300 30 1200)
  DD_DETAIL_MAX_BYTES=$(_st_knob_int DISCOVERY_DETAIL_MAX_BYTES "${DISCOVERY_DETAIL_MAX_BYTES:-12000}" 12000 1000 100000)
  DD_CAND_MATCH_CHARS=$(_st_knob_int DISCOVERY_CAND_MATCH_CHARS "${DISCOVERY_CAND_MATCH_CHARS:-60}" 60 10 300)
  DD_TICKET_TITLE_CHARS=$(_st_knob_int DISCOVERY_TICKET_TITLE_CHARS "${DISCOVERY_TICKET_TITLE_CHARS:-120}" 120 40 256)
  DD_ITEM_TITLE_CHARS=$(_st_knob_int DISCOVERY_ITEM_TITLE_CHARS "${DISCOVERY_ITEM_TITLE_CHARS:-300}" 300 40 2000)
  ST_MAX_USD="${DISCOVERY_MAX_USD:-0.50}"
  if ! [[ $ST_MAX_USD =~ ^[0-9]+(\.[0-9]+)?$ ]] || awk -v v="$ST_MAX_USD" 'BEGIN{exit !(v > 5)}'; then
    _st_log "warn: DISCOVERY_MAX_USD=$ST_MAX_USD is outside 0..5; using the default 0.50"
    ST_MAX_USD=0.50
  fi
}

# dd_target_repo: the repo tickets go to. DISCOVERY_TARGET_REPO, else the
# project's fleet.conf repo. The knob is a settings row, so a value is used
# only when it is owner/repo AND fleet.conf names it in column 2. rc 1 = none.
dd_target_repo() {
  local fc="${FLEET_CONF:-$(_st_root)/fleet.conf}" want="${DISCOVERY_TARGET_REPO:-}"
  [ -n "$want" ] || want=$(awk -v p="$DD_P" 'NF && $1 !~ /^#/ && $1 == p {print $2; exit}' "$fc" 2>/dev/null)
  [[ $want =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  awk -v r="$want" 'NF && $1 !~ /^#/ && $2 == r {f=1} END {exit !f}' "$fc" 2>/dev/null || return 1
  printf '%s' "$want"
}

# dd_prune <state-dir>: delete date dirs older than DD_RAW_KEEP_D days (by name).
dd_prune() {
  local dir=$1 d n=0 ep
  [ -d "$dir" ] || { echo 0; return 0; }
  for d in "$dir"/*/; do
    d=${d%/}; [ -d "$d" ] || continue
    [[ ${d##*/} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    ep=$(date -u -d "${d##*/}" +%s 2>/dev/null) || continue
    if [ $(( (ST_NOW - ep) / 86400 )) -gt "$DD_RAW_KEEP_D" ]; then rm -rf "$d" && n=$((n + 1)); fi
  done
  echo "$n"
}

# dd_cost <run-id> [calls]: the usd sum of the cost.csv rows of this run id
# (col 23, cost col 13). "unpriced" when any row has a blank cost. No row: 0
# when the run made no call, "unknown" when it made calls (the rows are missing).
dd_cost() {
  local f c=${2:-0}; f="$(_st_root)/logs/cost.csv"
  [[ $c =~ ^[0-9]+$ ]] || c=0
  [ -r "$f" ] || { if [ "$c" -gt 0 ]; then echo unknown; else echo 0; fi; return 0; }
  awk -F, -v r="$1" -v c="$c" '$23 == r { n++; if ($13 == "") b = 1; s += $13 }
    END { if (!n) print (c > 0 ? "unknown" : 0); else if (b) print "unpriced"; else { v = sprintf("%.4f", s); sub(/0+$/, "", v); sub(/\.$/, "", v); print v } }' "$f"
}

# _dd_marker <src> <id>
_dd_marker() { printf '<!-- discovery: %s/%s -->' "$1" "$2"; }

# dd_prompt <item-json> <pf>: the prompt file. Every fetched text goes through
# ui_wrap. Sets DD_CANDS (the candidate numbers as a JSON array).
dd_prompt() {
  local item=$1 pf=$2 src id title cands
  src=$(jq -r .source <<<"$item"); id=$(jq -r .id <<<"$item"); title=$(jq -r '.title // ""' <<<"$item")
  rm -f "$ST_TMP/detail.json"
  "dd_src_${src}_detail" "$id" "$ST_TMP/detail.json" || true
  cands=$(st_candidates "${title:0:$DD_CAND_MATCH_CHARS}")
  DD_CANDS=$(jq -c 'map(.number)' <<<"$cands")
  { cat "$(_st_root)/catalog/prompts/discovery-daily.md"
    printf '\n%s\n\n## Questions\n' "$(ui_notice)"
    dd_rules_questions
    printf '\n## Item\n'
    { printf 'list line:\n%s\n\ndetail:\n' "$item"; head -c "$DD_DETAIL_MAX_BYTES" "$ST_TMP/detail.json" 2>/dev/null; printf '\n'; } | ui_wrap fetched-page
    printf '\n## Candidate open tickets\n'
    if [ "$(jq 'length' <<<"$cands")" = 0 ]; then echo "none"
    else jq -r '.[] | "#\(.number) \(.title)\n\(.body)\n"' <<<"$cands" | ui_wrap ticket-body; fi
  } > "$pf"
}

# _dd_reply <raw-file>: the reply as compact JSON, rc 1 empty, rc 2 not JSON.
_dd_reply() {
  local j
  [ -n "$(tr -d '[:space:]' < "$1")" ] || return 1
  # A fenced answer is accepted: the fence lines are dropped before the parse.
  j=$(sed '/^[[:space:]]*```/d' "$1" | jq -c . 2>/dev/null) || return 2
  jq -e 'type == "object"' <<<"$j" >/dev/null 2>&1 || return 2
  printf '%s\n' "$j"
}

# _dd_evidence <det>: the evidence lines, built from the FETCH only.
_dd_evidence() {
  jq -r '"Source: \(.source | ascii_upcase[0:1] + .[1:]) issue \(.id) (\(.url))",
    "Events: \(.count) total, \(.count_24h) in the last 24 h, first seen \(.first_seen // "unknown"), last seen \(.last_seen // "unknown")"' <<<"$1"
}

# dd_act <key> <detail>: act on detail.decision. No model call.
dd_act() {
  local key=$1 det=$2 dec src id n bf tf labels c24 now srcname rc
  dec=$(jq -r '.decision // ""' <<<"$det")
  src=$(jq -r .source <<<"$det"); id=$(jq -r .id <<<"$det")
  now=$(date -u -d "@$ST_NOW" +%FT%TZ)
  case "$dec" in
    noise\ *)
      _st_put "$key" noise "$det" "$(jq -nc --arg r "${dec#noise }" '{reason: $r}')" \
        || { _dd_log "ledger put noise for $key failed"; ST_OUT=skip; return 0; }
      _dd_log "$key noise: ${dec#noise }"; ST_OUT=noise ;;
    comment\ *)
      n=${dec#comment }; bf="$ST_TMP/comment.md"
      { printf 'The discovery lane found more events of this problem.\n\n'
        jq -r '.diagnosis.cause // ""' <<<"$det"
        printf '\n'; _dd_evidence "$det"
        printf '\n%s\n' "$(_dd_marker "$src" "$id")"
      } | _st_dash > "$bf"
      _st_comment_once "$key" "$n" "$bf" "$(_dd_marker "$src" "$id")" || { ST_OUT=skip; return 0; }
      det=$(jq -c --argjson n "$n" '. + {action: "commented", issue: $n}' <<<"$det")
      _st_save "$key" ticketed "$det" || _dd_log "ledger put ticketed for $key failed"
      _dd_log "$key commented on #$n"; ST_OUT=commented ;;
    ticket)
      rc=0; _st_day_capped || rc=$?
      if [ "$rc" = 2 ]; then ST_STOP=ledger; return 75; fi
      if [ "$rc" = 0 ]; then
        _dd_log "cap DISCOVERY_TICKETS_DAY=$ST_MAX_DAY reached; $key stays diagnosed"; ST_OUT=capped; return 0
      fi
      srcname=$(jq -r '.source | ascii_upcase[0:1] + .[1:]' <<<"$det")
      tf=$(printf '%s %s: %s' "$srcname" "$id" "$(jq -r '.diagnosis.title' <<<"$det")" | tr '\n' ' ' | _st_dash | cut -c1-"$DD_TICKET_TITLE_CHARS")
      bf="$ST_TMP/body.md"
      { printf '## Scope\n\n'; jq -r '.diagnosis.cause' <<<"$det"
        printf '\nProposed fix: %s\n\n' "$(jq -r '.diagnosis.proposed_fix // ""' <<<"$det")"
        _dd_evidence "$det"
        printf '\n## Acceptance tests\n\n'; jq -r '(.diagnosis.acceptance_tests // []) | if type == "array" then .[] else . end | "- \(.)"' <<<"$det"
        printf '\n## Out of scope\n\nOther errors of this project.\n\n'
        _dd_marker "$src" "$id"; printf '\n'
      } | _st_dash > "$bf"
      c24=$(jq -r '.count_24h // 0 | numbers? // 0 | floor' <<<"$det")
      labels='["ai-build"]'; [ "$c24" -ge "$ST_HOTFIX_24H" ] && labels='["ai-build","hotfix"]'
      if ! _st_create "$tf" "$bf" "$labels"; then
        _dd_log "$key create failed (HTTP ${GH_REST_STATUS:-000}); stays diagnosed"; ST_OUT=skip; return 0
      fi
      det=$(jq -c --argjson n "$ST_NUM" --arg u "$ST_URL" --arg at "$now" '. + {action: "filed", issue: $n, url: $u, filed_at: $at}' <<<"$det")
      _st_save "$key" ticketed "$det" \
        || _dd_log "ledger put ticketed for $key failed; the body marker heals it next run"
      _st_day_filed_add "$src/$id" || true
      _dd_log "$key filed #$ST_NUM $ST_URL"; ST_OUT=filed
      # The existing "Tracked in" note on the Sentry issue, once.
      [ "$src" = sentry ] && _st_writeback "$key" "$(jq -c --arg i "$id" '. + {sentry_id: $i}' <<<"$det")" "$ST_URL" ;;
    *)
      _st_put "$key" failed "$det" '{"why":"diagnosis-lost"}' \
        || { _dd_log "ledger put failed for $key failed"; ST_OUT=skip; return 0; }
      _dd_log "$key stored decision unreadable ('${dec:0:20}'); failed {why: diagnosis-lost}"; ST_OUT=failed ;;
  esac
  return 0
}

# dd_item <item-json>: ONE item, every rule. Sets ST_OUT to below_min |
# terminal | healed | capped | filed | commented | noise | failed | skip and
# returns 0, or returns 75 with ST_STOP=ledger|open-list (no more calls).
dd_item() {
  local item=$1 src id cnt key row rc=0 st det n prior hit pf raw fp root arc text dec m
  ST_OUT=skip
  src=$(jq -r '.source // ""' <<<"$item"); id=$(jq -r '.id // "" | tostring' <<<"$item")
  if ! [[ $src =~ ^[a-z0-9-]+$ ]] || ! [[ $id =~ ^[0-9A-Za-z_-]+$ ]]; then _dd_log "skip an item with source '${src:0:20}' id '${id:0:40}'"; return 0; fi
  cnt=$(jq -r '.count // "" | tostring' <<<"$item")
  if ! [[ $cnt =~ ^[0-9]+$ ]]; then _dd_log "skip $src/$id: count '${cnt:0:20}' is not a number"; return 0; fi
  if [ "$cnt" -lt "$ST_MIN_EVENTS" ]; then ST_OUT=below_min; return 0; fi

  # The ledger, FIRST. An outage is never "no row".
  key="$DD_P/$src/$id"
  row=$(job_ledger_row discovery-daily "$key") || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 2 ] || { ST_STOP=ledger; return 75; }
  st=""; [ "$rc" = 0 ] && st=$(jq -r '.status // ""' <<<"$row")
  det='{}'; [ "$rc" = 0 ] && det=$(_st_detail "$row")
  det=$(jq -c --argjson i "$item" --argjson tl "$DD_ITEM_TITLE_CHARS" '. + ($i | {source, id: (.id | tostring), title: ((.title // "") | .[0:$tl]), url: (.url // ""),
    count: ((.count // 0) | tostring | tonumber? // 0), count_24h: (.count_24h // 0), first_seen, last_seen})' <<<"$det")
  n=$(jq -r '.attempts // 0 | numbers' <<<"$det"); [[ $n =~ ^[0-9]+$ ]] || n=0
  case "$st" in
    ticketed|noise|failed) ST_OUT=terminal; return 0 ;;
    retry)
      if [ "$n" -ge "$ST_MAX_ATTEMPTS" ]; then
        _st_put "$key" failed "$det" '{"why":"attempts"}' || { ST_STOP=ledger; return 75; }
        _dd_log "$key failed after $n attempts"; ST_OUT=failed
        _dd_alert discovery-daily-failed "discovery-daily: $key failed after $n model call attempts; no more calls for it"
        return 0
      fi ;;
  esac

  # The marker heal: an open issue already names this item. No call.
  st_open_list || { ST_STOP=open-list; return 75; }
  m=$(_dd_marker "$src" "$id")
  hit=$(jq -r --arg m "$m" '[.[] | select((.body // "") | contains($m))] | sort_by(.number) | .[0].number // empty' "$ST_OPEN")
  if [ -n "$hit" ]; then
    _st_put "$key" ticketed "$det" "$(jq -nc --argjson n "$hit" '{action: "healed", issue: $n}')" || { ST_STOP=ledger; return 75; }
    _dd_log "$key healed from the marker on #$hit"; ST_OUT=healed; return 0
  fi

  if [ "$st" = diagnosed ]; then dd_act "$key" "$det"; return; fi

  # Before the call: the per-call cap, the day caps, the route, the attempt.
  if ! awk -v v="$ST_MAX_USD" 'BEGIN{exit !(v > 0)}'; then
    _dd_log "cap off (DISCOVERY_MAX_USD=$ST_MAX_USD); $key not read"; ST_OUT=capped; DD_STOP_CAP=1; return 0
  fi
  rc=0; _st_day_capped || rc=$?
  if [ "$rc" = 2 ]; then ST_STOP=ledger; return 75; fi
  if [ "$rc" = 0 ]; then
    _dd_log "cap DISCOVERY_TICKETS_DAY=$ST_MAX_DAY reached; $key not read"; ST_OUT=capped; DD_STOP_CAP=1; return 0
  fi
  if [ -z "${ST_MODEL:-}" ]; then
    ST_MODEL=$(lane_role_model stage.discovery-daily 2>/dev/null) || ST_MODEL=""
    ST_RUNNER=$(lane_model_ladder stage.discovery-daily 2>/dev/null | awk -F'\t' 'NR==1{print $3}')
  fi
  if [ -z "$ST_MODEL" ] || [ "${ST_RUNNER:-}" != claude ]; then
    _dd_log "no route: stage.discovery-daily gives model '${ST_MODEL}' runner '${ST_RUNNER:-}', not claude; $key not read"
    ST_OUT=skip; return 0
  fi
  rc=0; _st_day_call || rc=$?
  if [ "$rc" = 2 ]; then ST_STOP=ledger; return 75; fi
  if [ "$rc" = 1 ]; then
    _dd_log "cap DISCOVERY_MAX_CALLS_DAY=$ST_MAX_CALLS_DAY reached; $key not read"; ST_OUT=capped; DD_STOP_CAP=1; return 0
  fi
  prior=$det
  det=$(_st_attempt_put "$key" "$det" "$n") \
    || { _dd_log "ledger put attempt for $key failed; no call"; ST_STOP=ledger; return 75; }

  pf="$ST_TMP/prompt.md"; raw="$ST_TMP/answer.txt"; : > "$raw"
  dd_prompt "$item" "$pf"
  fp=$(printf 'discovery-daily|%s' "$key" | sha256sum | cut -c1-64)
  root=$(_st_root); arc=0
  AGENT_CALL_LANE=discovery-daily AGENT_CALL_FP="$fp" AGENT_CALL_NO_TOOLS=1 AGENT_CALL_RUNNERS="$ST_RUNNER" AGENT_CALL_BUDGET_USD_DISCOVERY_DAILY="$ST_MAX_USD" COST_RUN_ID="$DD_RUN_ID" "$root/bin/agent-call.sh" discovery-daily "$DD_P" "$ST_MODEL" "$DD_CALL_TIMEOUT_S" "$raw" "@$pf" >/dev/null 2>&1 || arc=$?
  DD_CALLS=$((DD_CALLS + 1))
  if _st_after_call "$key" "$prior" "$det" "$n" "$arc"; then
    [ "$ST_OUT" = failed ] && _dd_alert discovery-daily-failed "discovery-daily: $key failed after $ST_MAX_ATTEMPTS model call attempts (last rc $arc); no more calls for it"
    return 0
  fi
  rc=0; text=$(_dd_reply "$raw") || rc=$?
  dec=""; [ "$rc" = 0 ] && dec=$(dd_rules_decide "$text" "$DD_CANDS")
  if [ "$rc" != 0 ] || [ "${dec%% *}" = invalid ] || [ -z "$dec" ]; then
    local why=bad-reply; [ "$rc" = 1 ] && why=empty-reply
    _st_put "$key" failed "$det" "$(jq -nc --arg w "$why" '{why: $w, last_rc: 0}')" || _dd_log "ledger put failed for $key failed"
    _dd_log "$key $why; failed (billed once, never re-called)"; ST_OUT=failed; return 0
  fi
  det=$(jq -c --argjson t "$text" --arg d "$dec" '. + {answers: ($t.answers // {}), diagnosis: (($t.draft // {}) | del(.source_id, .url, .id)), decision: $d, last_rc: 0}' <<<"$det")
  _st_save "$key" diagnosed "$det" || _dd_log "ledger put diagnosed for $key failed; acting once"
  dd_act "$key" "$det"
}

# dd_source_list <src> <raw-dir> <items-out>: one source's list. rc as the adapter.
dd_source_list() {
  local src=$1 dir=$2 out=$3 f
  f="$(dirname "${BASH_SOURCE[0]}")/discovery/$src.sh"
  [[ $src =~ ^[a-z0-9-]+$ ]] && [ -r "$f" ] || { _dd_log "source '$src' has no adapter bin/lib/discovery/$src.sh"; return 3; }
  # shellcheck disable=SC1090
  . "$f" || return 1
  "dd_src_${src}_list" "$dir" >> "$out"
}

dd_run() {
  local day rc out since dir raw items src pruned usd sum status why text
  local -A C=([below_min]=0 [terminal]=0 [healed]=0 [filed]=0 [commented]=0 [noise]=0 [failed]=0 [capped]=0 [skip]=0)
  day=$(date -u -d "@$ST_NOW" +%F)
  ST_DAY="$DD_P/$day"; ST_CALLED=0; ST_STOP=""; ST_OPEN=""; ST_MODEL=""; ST_RUNNER=""
  DD_CALLS=0; DD_STOP_CAP=0; DD_RUN_ID="discovery-daily:$DD_P:$day"; DD_CANDS='[]'
  dd_knobs

  # 1. The run row, FIRST.
  out=$(job_ledger_claim discovery-daily-run "$DD_P/$day" running "$((DD_RUN_TIMEOUT_S + 60))" done); rc=$?
  case "$rc" in
    0) ;;
    3) if [ "$out" = done ]; then _dd_log "run $day already done; nothing read"
       else _dd_log "run $day is held ($out); nothing read"; fi
       return 0 ;;
    *) _dd_log "run row claim failed (rc $rc); nothing read"
       _dd_alert discovery-daily-ledger "discovery-daily: the jobs ledger did not answer the run claim for $day; nothing was read"
       return 0 ;;
  esac
  rc=0; since=$(job_ledger_row discovery-daily-since "$DD_P") || rc=$?
  if [ "$rc" = 2 ]; then
    job_ledger_put discovery-daily-since "$DD_P" active "$(jq -nc --arg d "$day" '{since: $d}')" \
      || _dd_log "ledger put discovery-daily-since/$DD_P failed"
  fi
  dir="$(_st_root)/state/discovery-daily/$DD_P"
  pruned=$(dd_prune "$dir")
  raw="$dir/$day"; mkdir -p "$raw" 2>/dev/null
  ST_RAW_DIR=$raw
  _dd_log "raw dir $raw; pruned=$pruned"

  # 2-3. The sources.
  items="$ST_TMP/items.jsonl"; : > "$items"
  local nc=0 lerr=0
  if ! ST_REPO=$(dd_target_repo); then
    _dd_log "no target repo: DISCOVERY_TARGET_REPO is not a fleet.conf repo (value not logged), or the project has no fleet.conf repo; nothing read"
    ST_REPO=""
  fi
  # DISCOVERY_SOURCES is a settings row: after the spaces go, the whole value
  # must match ^[a-z0-9,-]*$ or no source is read (one log line). Each name is
  # checked again and needs its adapter file (dd_source_list).
  local srcv; srcv=$(printf '%s' "${DISCOVERY_SOURCES:-}" | tr -d '[:space:]')
  if ! [[ $srcv =~ ^[a-z0-9,-]*$ ]]; then
    _dd_log "DISCOVERY_SOURCES is not ^[a-z0-9,-]*\$ (value not logged); no source read"
    srcv=""
  fi
  IFS=',' read -r -a srcs <<<"$srcv"
  for src in "${srcs[@]}"; do
    src=$(printf '%s' "$src" | tr -d '[:space:]'); [ -n "$src" ] || continue
    [ -n "$ST_REPO" ] || { nc=$((nc + 1)); continue; }
    rc=0; dd_source_list "$src" "$raw" "$items" || rc=$?
    case "$rc" in
      0) ;;
      3) _dd_log "$src not-configured"; nc=$((nc + 1)) ;;
      *) lerr=$((lerr + 1))
         _dd_alert discovery-daily-list "discovery-daily: the $src list failed: ${DD_SRC_ERR:-rc $rc}" ;;
    esac
  done
  local nread; nread=$(grep -c . "$items" 2>/dev/null) || nread=0

  # 4-8. The items, most events first.
  status=done; why=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$DD_STOP_CAP" = 1 ]; then C[capped]=$((C[capped] + 1)); continue; fi
    rc=0; dd_item "$line" || rc=$?
    if [ "$rc" = 75 ]; then
      status=failed; why=${ST_STOP:-ledger}
      _dd_log "the $why read failed; no more calls this run"
      [ "$why" = ledger ] && _dd_alert discovery-daily-ledger "discovery-daily: the jobs ledger is unreadable; the run of $day stopped"
      break
    fi
    [ -n "${C[$ST_OUT]+x}" ] && C[$ST_OUT]=$((C[$ST_OUT] + 1))
  done < <(jq -sc 'sort_by(-((.count // 0) | tostring | tonumber? // 0))[]' "$items" 2>/dev/null)

  # 9. The run row, the summary line, the Telegram text.
  usd=$(dd_cost "$DD_RUN_ID" "$DD_CALLS")
  local dropped=$((C[below_min] + C[terminal] + C[healed]))
  sum=$(jq -nc --argjson r "$nread" --argjson d "$dropped" --argjson nc "$nc" --argjson c "$DD_CALLS" \
    --argjson f "${C[filed]}" --argjson cm "${C[commented]}" --argjson no "${C[noise]}" --argjson fa "${C[failed]}" \
    --argjson ca "${C[capped]}" --argjson le "$lerr" --arg u "$usd" --arg w "$why" \
    '{read: $r, dropped_code: $d, not_configured: $nc, list_failed: $le, calls: $c, filed: $f, commented: $cm, noise: $no,
      failed: $fa, capped: $ca, usd: $u} + (if $w == "" then {} else {why: $w} end)')
  job_ledger_put discovery-daily-run "$DD_P/$day" "$status" "$sum" \
    || _dd_log "ledger put discovery-daily-run/$DD_P/$day $status failed"
  _dd_log "read=$nread dropped=$dropped not_configured=$nc calls=$DD_CALLS filed=${C[filed]} commented=${C[commented]} noise=${C[noise]} failed=${C[failed]} capped=${C[capped]} usd=$usd status=$status"
  text="Discovery $DD_P $day: read $nread, dropped by code $dropped, model calls $DD_CALLS, tickets filed ${C[filed]}, comments ${C[commented]}, noise ${C[noise]}, failed ${C[failed]}, capped ${C[capped]}, not configured $nc, cost $( [[ $usd =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "\$$usd" || echo "$usd")."
  [ "$status" = done ] || text="$text The run stopped: the $why read failed."
  rc=0; "$(_st_root)/bin/archie-tg-send.sh" "$DD_RUN_ID" "$text" </dev/null >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    2) _dd_log "summary not sent: no Telegram token or target (archie-tg-send rc 2)" ;;
    *) _dd_log "summary send failed (archie-tg-send rc $rc)" ;;
  esac
  return 0
}
