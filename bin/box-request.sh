#!/bin/bash
# bin/box-request.sh — the orchestrator's box and project verbs, with no model
# turn. bin/orchestrate.sh runs `intercept` in its `# >>> box request
# intercept` block, after Archie's intercept and before the turn claim.
#
#   box-request.sh intercept <text>   rc 0 = the reply is on stdout;
#                                     rc 1 = not a box verb, nothing requested
#   box-request.sh watch <launch-id>  report one launch's result once
#
# THE VERBS (the message, after poll-commands.sh's one `[telegram: from …]`
# attribution line, must be ONE line that starts with the verb):
#   /box launch <project> [--id <box>] [--account a] [--vcpus N] [--mem-gb N]
#               [--disk-gb N] [facts]      the placement rule, then the quote step
#   we need a box for <project>            the same (also `I need a new|dedicated box for`)
#   /box list                              read-only: Orgo computers + recent box commands
#   /project load <project> [facts] [--cap N]   the placement rule; read-only until a yes
#   yes | yes. | yes!                      only while this conversation has an open
#                                          offer younger than BOX_REQUEST_OFFER_S
# facts: --repo-mb N, --builds-day N, --desktop, --isolated. A fact not given is
# UNKNOWN, never zero, and the reply names it. The rule is the data file
# prompts/box-placement.json; it picks a place and holds no price.
#
# MONEY. A launch is two queued commands on the BH-5750 contract
# (worker/jobs/src/routes/box-commands.js). The quote step queues
# orgo_launch_quote (free: a dry run), waits for the hub's box-ops lane to
# finish it, and reads the monthly figure from the row's detail with the
# worker's own pattern (usd_mo=<n>). It writes an offer and asks for a yes. The
# launch step runs only on the offer owner's yes. It claims ledger
# box_launch/q<quote_id> (one compare-and-set) BEFORE it queues orgo_launch
# with that quote_id and confirm_monthly_usd = the recorded figure. A 409
# stale_quote gets a NEW quote and a new question; the old quote_id is never
# sent again. An unknown outcome is never resent.
#
# OWNER. Every queued command carries the owner's email as `actor`, and the
# worker checks it against BOX_OPS_OWNERS. The email comes from
# BOX_CHAT_OWNERS in env/global.env: a comma list of
# telegram:<username>=<email>, trimmed and lower-cased once, a leading @
# dropped. A username listed with two emails, or an entry that does not parse,
# is one ALERTS line and nobody resolves. Only a Telegram sender with a
# username resolves; Slack and Mission Control never do. Unset = nobody can
# queue from chat.
#
# STATE (jobs ledger): box_offer/<transport>:<chat>:<thread|0> holds the open
# offer (detail JSON); a new offer replaces the old one. box_launch/q<quote_id>
# is the launch dedupe: claimed → queued | refused, or claimed for good when
# the outcome is unknown.
#
# INPUT (set by bin/orchestrate.sh from the message sidecar): BOXREQ_TRANSPORT,
# BOXREQ_FROM_USER, BOXREQ_CHAT, BOXREQ_THREAD, BOXREQ_CMD_ID.
# KNOBS (env-templates/lanes/383-box-request.env.example), each a positive
# integer or the verb answers "not configured" with one ALERTS line:
#   BOX_REQUEST_QUOTE_WAIT_S (150) BOX_REQUEST_POLL_S (5) BOX_REQUEST_OFFER_S (900)
#   BOX_REQUEST_WATCH_S (3600) BOX_REQUEST_WATCH_POLL_S (30)
# WATCH. Started detached after a queued launch. It polls the hub's box
# commands until the row is ok or fail, then sends `<status> <box-launch:
# summary line>` through bin/archie-tg-send.sh box-launch-<id> (that script's
# ledger makes the send exactly once). Past BOX_REQUEST_WATCH_S: one ALERTS
# line, exit 1. locks/box-request-watch-<id>.lock (flock -n) is a dedupe only.
# Log: logs/box-request.log. Note: docs/notes/2026-10-14-BH-5751-box-requests.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" 2>/dev/null || { echo "box-request: cannot load bin/jobs-client.sh" >&2; exit 1; }

LOG="$H/logs/box-request.log"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
log() { printf '%s [box-request] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$LOG" 2>/dev/null; }
alert() { HARNESS="$H" "$H/bin/alert-line.sh" "[box-request] $*" >/dev/null 2>&1; }
# The clock. BOXREQ_NOW is the suite's seam, read only in the sandbox.
now_s() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${BOXREQ_NOW:-}" ]; then printf '%s\n' "$BOXREQ_NOW"
  else date -u +%s; fi
}

PLACEMENT="$H/prompts/box-placement.json"
PLANS="$H/catalog/orgo-plans.json"
NAME_RE='^[A-Za-z0-9._-]{1,64}$'
NOTHING="I queued nothing."

# req <method> <path> [body] — one jobs request in THIS shell, so JOBS_HTTP and
# JOBS_BODY stay readable. Sets RC (the _jobs_req contract: 0 2xx, 9 409, 2
# 404, 1 anything else) and BODY (the payload of any answer, or "").
req() {
  _jobs_req "$@" >/dev/null; RC=$?
  BODY="$JOBS_BODY"
}
http_of() { printf '%s' "${JOBS_HTTP:-no answer}"; }

# knobs — every knob a positive integer, or one ALERTS line and a reply.
knobs() {
  local k n v
  for k in BOX_REQUEST_QUOTE_WAIT_S:150 BOX_REQUEST_POLL_S:5 BOX_REQUEST_OFFER_S:900 \
           BOX_REQUEST_WATCH_S:3600 BOX_REQUEST_WATCH_POLL_S:30; do
    n="${k%%:*}"; v="${!n:-${k#*:}}"
    if ! [[ $v =~ ^[1-9][0-9]*$ ]]; then
      alert "$n '$v' is not a positive integer; box requests from chat are off until it is fixed"
      KNOB_BAD="$n"; return 1
    fi
    printf -v "$n" '%s' "$v"
  done
}
not_configured() { printf 'Box requests are not configured: %s. %s\n' "$KNOB_BAD" "$NOTHING"; }

# br_owner — the sender's owner email on stdout. rc 0 resolved, rc 1 not an
# owner, rc 2 the map is broken (one ALERTS line).
br_owner() {
  local tr="${BOXREQ_TRANSPORT:-telegram}" u="${BOXREQ_FROM_USER:-}" e user email found="" bad=""
  local -A map=()
  u=$(printf '%s' "$u" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'); u="${u#@}"
  [ "$tr" = telegram ] && [ -n "$u" ] || return 1
  IFS=',' read -r -a ents <<< "${BOX_CHAT_OWNERS:-}"
  for e in "${ents[@]}"; do
    e=$(printf '%s' "$e" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [ -n "$e" ] || continue
    if ! [[ $e =~ ^telegram:@?([a-z0-9_]{1,64})=([a-z0-9._%+-]+@[a-z0-9.-]+)$ ]]; then
      bad="entry '$e' is not telegram:<username>=<email>"; break
    fi
    user="${BASH_REMATCH[1]}"; email="${BASH_REMATCH[2]}"
    if [ -n "${map[$user]:-}" ] && [ "${map[$user]}" != "$email" ]; then
      bad="username '$user' is listed with two emails"; break
    fi
    map[$user]="$email"
  done
  if [ -n "$bad" ]; then
    alert "BOX_CHAT_OWNERS: $bad; nobody can queue a box command from chat until it is fixed"
    return 2
  fi
  found="${map[$u]:-}"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# br_place <facts-json> — sets PLACE and PLACE_WHY. rc 2 = the rule file is
# broken; PLACE_ERR says why and one ALERTS line is written.
br_place() {
  local out
  PLACE=""; PLACE_WHY=""; PLACE_ERR=""
  if ! jq -e . "$PLACEMENT" >/dev/null 2>&1; then
    PLACE_ERR="prompts/box-placement.json is missing or is not JSON"
  else
    PLACE_ERR=$(jq -r '
      def facts: {repo_mb: "num", builds_day: "num", desktop: "bool", isolated: "bool"};
      def bad($i; $m): "rule \($i + 1): \($m)";
      if (.rules | type) != "array" or (.rules | length) == 0 then "rules must be a non-empty list"
      else (.rules | length) as $n
        | [ .rules | to_entries[] | .key as $i | .value as $r
            | if ($r | type) != "object" then bad($i; "is not an object")
              elif ($r.place | IN("shared", "fly", "dedicated") | not) then bad($i; "place must be shared, fly or dedicated")
              elif (($r.why | type) != "string") or ($r.why == "") then bad($i; "why must be a sentence")
              elif $i == $n - 1 then (if $r | has("when") then bad($i; "the last rule is the fallback and has no when") else empty end)
              elif ($r.when | type) != "object" then bad($i; "needs a when (only the last rule may omit it)")
              elif (facts | .[($r.when.fact // "") | tostring]) == null then bad($i; "unknown fact \($r.when.fact)")
              elif (facts | .[$r.when.fact]) == "bool" then
                (if ($r.when | keys) != ["fact", "is"] or ($r.when.is | type) != "boolean" then bad($i; "\($r.when.fact) takes {fact, is: true|false}") else empty end)
              elif ($r.when | keys) != ["fact", "gte"] or ($r.when.gte | type) != "number" or $r.when.gte < 0 then bad($i; "\($r.when.fact) takes {fact, gte: N}")
              else empty end ]
        | .[0] // "" end' "$PLACEMENT" 2>/dev/null) || PLACE_ERR="prompts/box-placement.json could not be read"
  fi
  if [ -n "$PLACE_ERR" ]; then
    alert "the placement rule file is broken: $PLACE_ERR; box and project requests are refused until it is fixed"
    return 2
  fi
  out=$(jq -r --argjson f "$1" '
    first(.rules[] | select(.when == null or (.when as $w | $f[$w.fact] as $x
      | $x != null and (if ($w | has("is")) then $x == $w.is else $x >= $w.gte end))))
    | "\(.place)\t\(.why)"' "$PLACEMENT" 2>/dev/null)
  PLACE="${out%%$'\t'*}"; PLACE_WHY="${out#*$'\t'}"
  [ -n "$PLACE" ] || { PLACE_ERR="no rule matched"; alert "the placement rule file is broken: $PLACE_ERR"; return 2; }
}
place_refusal() { printf 'The placement rule file is broken: %s. %s\n' "$PLACE_ERR" "$NOTHING"; }
# unknown_facts <facts-json> — "Unknown facts: a, b." or nothing.
unknown_facts() {
  jq -r '[to_entries[] | select(.value == null) | .key] | if length == 0 then empty else "Unknown facts: \(join(", ")) (send --repo-mb N, --builds-day N, --desktop or --isolated to set them)." end' <<< "$1"
}

# parse_args <arg>... — the flags of /box launch and /project load. Sets
# A_PROJECT A_ID A_ACCOUNT A_VCPUS A_MEM A_DISK A_CAP and FACTS (JSON). rc 1
# with ARG_ERR on anything it does not know.
parse_args() {
  A_PROJECT=""; A_ID=""; A_ACCOUNT=""; A_VCPUS=""; A_MEM=""; A_DISK=""; A_CAP=""; ARG_ERR=""
  local repo="" builds="" desk="" iso="" a v
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --id|--account|--vcpus|--mem-gb|--disk-gb|--repo-mb|--builds-day|--cap)
        [ $# -gt 0 ] || { ARG_ERR="$a needs a value"; return 1; }
        v="$1"; shift
        case "$a" in
          --id) [[ $v =~ ^[a-z][a-z0-9]{0,31}$ ]] || { ARG_ERR="--id must match [a-z][a-z0-9]{0,31}"; return 1; }; A_ID="$v" ;;
          --account) [[ $v =~ $NAME_RE ]] || { ARG_ERR="--account must match [A-Za-z0-9._-]{1,64}"; return 1; }; A_ACCOUNT="$v" ;;
          --repo-mb|--builds-day)
            [[ $v =~ ^(0|[1-9][0-9]{0,8})$ ]] || { ARG_ERR="$a must be a whole number"; return 1; }
            if [ "$a" = --repo-mb ]; then repo="$v"; else builds="$v"; fi ;;
          *)
            [[ $v =~ ^[1-9][0-9]{0,5}$ ]] || { ARG_ERR="$a must be a positive integer"; return 1; }
            case "$a" in --vcpus) A_VCPUS="$v" ;; --mem-gb) A_MEM="$v" ;; --disk-gb) A_DISK="$v" ;; --cap) A_CAP="$v" ;; esac ;;
        esac ;;
      --desktop) desk=true ;;
      --isolated) iso=true ;;
      -*) ARG_ERR="unknown flag $a"; return 1 ;;
      *)
        [ -z "$A_PROJECT" ] || { ARG_ERR="one project name only (got '$a' too)"; return 1; }
        [[ $a =~ $NAME_RE ]] || { ARG_ERR="the project name must match [A-Za-z0-9._-]{1,64}"; return 1; }
        A_PROJECT="$a" ;;
    esac
  done
  [ -n "$A_PROJECT" ] || { ARG_ERR="name the project"; return 1; }
  FACTS=$(jq -nc --arg r "$repo" --arg b "$builds" --arg d "$desk" --arg i "$iso" '{
    repo_mb: (if $r == "" then null else ($r | tonumber) end),
    builds_day: (if $b == "" then null else ($b | tonumber) end),
    desktop: (if $d == "" then null else true end),
    isolated: (if $i == "" then null else true end)}')
}

offer_key() { printf '%s:%s:%s' "${BOXREQ_TRANSPORT:-telegram}" "${BOXREQ_CHAT:-0}" "${BOXREQ_THREAD:-0}"; }
within() { # within <seconds> — "15 minutes" or "90 seconds"
  if [ $(( $1 % 60 )) = 0 ]; then printf '%s minutes' $(( $1 / 60 )); else printf '%s seconds' "$1"; fi
}

# offer_put <detail-json> — rc 0 when the ledger took it.
offer_put() {
  req PUT /api/ledger "$(jq -nc --arg k "$(offer_key)" --arg a "$OWNER" --arg d "$1" \
    '{kind: "box_offer", key: $k, status: "offered", actor: $a, detail: $d}')"
  [ "$RC" = 0 ]
}
offer_status() { # offer_status <status>
  req PUT /api/ledger "$(jq -nc --arg k "$(offer_key)" --arg s "$1" '{kind: "box_offer", key: $k, status: $s}')"
  [ "$RC" = 0 ] || log "offer $(offer_key) -> $1 not recorded (rc $RC, http $(http_of))"
}

# post_cmd <json> — POST /api/box-commands. The worker's 403/400 are answers,
# not an outage, so the daily outage alert stays off for this call.
post_cmd() {
  JOBS_ALERT=0 req POST /api/box-commands "$1"
}

# br_quote — the quote step. Reads OWNER, A_PROJECT, A_ID, A_ACCOUNT, A_VCPUS,
# A_MEM, A_DISK, FACTS, REASON. Prints the reply.
br_quote() {
  local id taken acct spec vc mem disk qid row status detail fig start rec u
  [[ $A_PROJECT =~ $NAME_RE ]] || { echo "The project name must match [A-Za-z0-9._-]{1,64}. $NOTHING"; return 0; }
  id="$A_ID"
  if [ -z "$id" ]; then
    id=$(printf '%s' "$A_PROJECT" | tr '[:upper:]' '[:lower:]'); id="${id%-os}"
    id=$(printf '%s' "$id" | tr -cd 'a-z0-9' | cut -c1-32)
    [[ $id =~ ^[a-z][a-z0-9]{0,31}$ ]] || { echo "I cannot make a box id from '$A_PROJECT'. Send --id <box-id>. $NOTHING"; return 0; }
  fi
  [ "$id" != hub ] || { echo "Box id $id is taken. Send --id <new-id>. $NOTHING"; return 0; }
  if ! taken=$(HARNESS="$H" "$H/bin/fleet-conf.sh" --box-ids 2>/dev/null); then
    echo "I could not read the fleet's box ids from fleet.conf, so I cannot check that $id is free. $NOTHING"; return 0
  fi
  grep -qxF -- "$id" <<< "$taken" && { echo "Box id $id is taken. Send --id <new-id>. $NOTHING"; return 0; }
  # The account and the specs: catalog/orgo-plans.json, never a guess.
  acct="$A_ACCOUNT"
  if [ -z "$acct" ]; then
    local n; n=$(jq -r '.accounts | keys | length' "$PLANS" 2>/dev/null)
    [ "$n" = 1 ] || { echo "catalog/orgo-plans.json has ${n:-no readable} accounts. Send --account <name>. $NOTHING"; return 0; }
    acct=$(jq -r '.accounts | keys[0]' "$PLANS")
  fi
  jq -e --arg a "$acct" '.accounts[$a] | type == "object"' "$PLANS" >/dev/null 2>&1 \
    || { echo "Account $acct is not in catalog/orgo-plans.json. $NOTHING"; return 0; }
  vc="${A_VCPUS:-$(jq -r --arg a "$acct" '.accounts[$a].defaults.vcpus // ""' "$PLANS")}"
  mem="${A_MEM:-$(jq -r --arg a "$acct" '.accounts[$a].defaults.mem_gb // ""' "$PLANS")}"
  disk="${A_DISK:-$(jq -r --arg a "$acct" '.accounts[$a].defaults.disk_gb // ""' "$PLANS")}"
  for spec in vcpus:"$vc" mem-gb:"$mem" disk-gb:"$disk"; do
    [[ ${spec#*:} =~ ^[1-9][0-9]*$ ]] && continue
    echo "Send /box launch $A_PROJECT --${spec%%:*} N; the plan has no default ${spec%%:*}. $NOTHING"; return 0
  done
  br_place "$FACTS" || { place_refusal; return 0; }
  if [ "$PLACE" = dedicated ]; then rec="Placement rule: dedicated, because $PLACE_WHY."
  else rec="Placement rule: $PLACE, because $PLACE_WHY. You asked for a box, so this is the price of a dedicated one."; fi
  u=$(unknown_facts "$FACTS"); rec="$rec${u:+ $u}"
  post_cmd "$(jq -nc --arg t "$id" --arg a "$acct" --arg p "$A_PROJECT" --argjson v "$vc" --argjson m "$mem" \
    --argjson d "$disk" --arg r "$REASON" --arg o "$OWNER" \
    '{box: "hub", type: "orgo_launch_quote", target: $t, account: $a, project: $p, vcpus: $v, mem_gb: $m,
      disk_gb: $d, reason: $r, actor: $o, confirm: true}')"
  case "$RC:${JOBS_HTTP:-}" in
    0:*) qid=$(jq -r '.id // empty' <<< "$BODY" 2>/dev/null) ;;
    1:403) echo "The jobs worker says you are not an owner (BOX_OPS_OWNERS). $NOTHING"; log "quote $id refused: owner_only"; return 0 ;;
    9:*)
      if [ "$(jq -r '.error // ""' <<< "$BODY" 2>/dev/null)" = open_command_differs ]; then
        echo "Price check #$(jq -r '.id' <<< "$BODY") for $id is still open with other specs. Wait for it to finish, then send the request again. $NOTHING"
      else echo "The jobs worker did not take the quote (HTTP 409). $NOTHING"; fi
      return 0 ;;
    *) echo "The jobs worker did not take the quote (HTTP $(http_of)). $NOTHING"; log "quote $id not taken: rc $RC http $(http_of)"; return 0 ;;
  esac
  [[ $qid =~ ^[1-9][0-9]*$ ]] || { echo "The jobs worker answered the quote with no id. I cannot read its price. $NOTHING"; return 0; }
  log "quote #$qid queued for $id ($A_PROJECT) by $OWNER"
  # Wait for the hub's box-ops lane to finish the dry run.
  start=$SECONDS; status=""
  while :; do
    req GET "/api/box-commands?box=hub"
    if [ "$RC" = 0 ]; then
      row=$(jq -c --argjson q "$qid" '.commands[]? | select(.id == $q)' <<< "$BODY" 2>/dev/null)
      status=$(jq -r '.status // ""' <<< "${row:-null}" 2>/dev/null)
      case "$status" in ok|fail) break ;; esac
    fi
    if [ $(( SECONDS - start + BOX_REQUEST_POLL_S )) -gt "$BOX_REQUEST_QUOTE_WAIT_S" ]; then
      echo "The price check #$qid did not finish in ${BOX_REQUEST_QUOTE_WAIT_S}s. Send the same /box launch again; it reuses that check."
      log "quote #$qid not finished in ${BOX_REQUEST_QUOTE_WAIT_S}s"; return 0
    fi
    sleep "$BOX_REQUEST_POLL_S"
  done
  detail=$(jq -r '.detail // ""' <<< "$row")
  fig=""
  [ "$status" = ok ] && [[ $detail =~ (^|[^A-Za-z0-9_])usd_mo=([0-9]+(\.[0-9]+)?)([^A-Za-z0-9_.]|$) ]] && fig="${BASH_REMATCH[2]}"
  if [ -z "$fig" ]; then
    if [ "$status" = ok ]; then echo "The price check #$qid finished but named no monthly price: ${detail:0:300}. $NOTHING"
    else echo "The price check #$qid failed: ${detail:0:300}. $NOTHING"; fi
    log "quote #$qid $status with no figure"; return 0
  fi
  if ! offer_put "$(jq -nc --arg o "$OWNER" --argjson q "$qid" --arg f "$fig" --arg t "$id" --arg a "$acct" \
       --arg p "$A_PROJECT" --argjson v "$vc" --argjson m "$mem" --argjson d "$disk" --arg pl "$PLACE" \
       --argjson fa "$FACTS" --argjson at "$(now_s)" \
       '{kind: "launch", owner: $o, quote_id: $q, figure: $f, target: $t, account: $a, project: $p,
         vcpus: $v, mem_gb: $m, disk_gb: $d, place: $pl, cap: null, facts: $fa, at: $at}')"; then
    echo "$rec A dedicated box $id ($vc vCPU, $mem GB RAM, $disk GB disk) costs \$$fig/mo, but I could not save the offer (HTTP $(http_of)), so a yes would do nothing. Send the request again. $NOTHING"
    return 0
  fi
  log "offer $(offer_key): launch $id at \$$fig/mo, quote #$qid"
  echo "$rec A dedicated box $id ($vc vCPU, $mem GB RAM, $disk GB disk) costs \$$fig/mo. The price check is free. Reply yes within $(within "$BOX_REQUEST_OFFER_S") to launch it."
}

# spawn_watch <launch-id> — the detached watcher. BOXREQ_SPAWN_LOG is the
# suite's seam (sandbox only): it records the spawn instead.
spawn_watch() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${BOXREQ_SPAWN_LOG:-}" ]; then
    printf 'watch %s\n' "$1" >> "$BOXREQ_SPAWN_LOG"; return 0
  fi
  setsid -f "$SELF/box-request.sh" watch "$1" </dev/null >>"$LOG" 2>&1
}

# br_launch <offer-detail-json> — the launch step, after the owner's yes.
br_launch() {
  local o="$1" qid fig lid claimed err code
  qid=$(jq -r '.quote_id' <<< "$o"); fig=$(jq -r '.figure' <<< "$o")
  [[ $qid =~ ^[1-9][0-9]*$ ]] && [[ $fig =~ ^[0-9]+(\.[0-9]+)?$ ]] \
    || { echo "The open offer has no usable quote. Send the /box launch again. $NOTHING"; return 0; }
  # THE SPEND GATE: one compare-and-set per quote, before the POST.
  req POST /api/ledger/claim "$(jq -nc --arg k "q$qid" --arg a "$OWNER" \
    '{kind: "box_launch", key: $k, status: "claimed", stale_s: 86400, terminal: ["queued", "refused"], actor: $a}')"
  [ "$RC" = 0 ] || { echo "I could not reach the jobs ledger. $NOTHING"; log "launch q$qid: ledger claim failed (rc $RC)"; return 0; }
  claimed=$(jq -r '.claimed' <<< "$BODY" 2>/dev/null)
  [ "$claimed" = true ] || { echo "This launch is already being queued."; log "launch q$qid: claim lost"; return 0; }
  post_cmd "$(jq -c --arg r "$REASON" --arg ow "$OWNER" '{box: "hub", type: "orgo_launch", target, account, project,
      vcpus, mem_gb, disk_gb, quote_id, confirm_monthly_usd: .figure, reason: $r, actor: $ow, confirm: true}' <<< "$o")"
  err=$(jq -r '.error // ""' <<< "${BODY:-null}" 2>/dev/null); code="${JOBS_HTTP:-}"
  ledger_launch() { req PUT /api/ledger "$(jq -nc --arg k "q$qid" --arg s "$1" --arg d "$2" '{kind: "box_launch", key: $k, status: $s, detail: $d}')"
    [ "$RC" = 0 ] || log "launch q$qid -> $1 not recorded (rc $RC)"; }
  case "$RC:$code:$err" in
    0:*)
      lid=$(jq -r '.id // empty' <<< "$BODY" 2>/dev/null)
      ledger_launch queued "${lid:-?}"
      offer_status accepted
      [[ $lid =~ ^[1-9][0-9]*$ ]] && spawn_watch "$lid"
      log "launch #${lid:-?} queued from quote #$qid at \$$fig/mo by $OWNER"
      echo "Launch #${lid:-?} is queued at \$$fig/mo. I will send the summary line when it finishes." ;;
    9:*:stale_quote)
      ledger_launch refused stale_quote
      offer_status stale
      log "launch q$qid: stale_quote, quoting again"
      A_PROJECT=$(jq -r .project <<< "$o"); A_ID=$(jq -r .target <<< "$o"); A_ACCOUNT=$(jq -r .account <<< "$o")
      A_VCPUS=$(jq -r .vcpus <<< "$o"); A_MEM=$(jq -r .mem_gb <<< "$o"); A_DISK=$(jq -r .disk_gb <<< "$o")
      FACTS=$(jq -c '.facts // {repo_mb: null, builds_day: null, desktop: null, isolated: null}' <<< "$o")
      echo "The price expired, so I checked it again. $(br_quote)" ;;
    9:*)
      ledger_launch refused "${err:-409}"
      echo "The jobs worker refused the launch (HTTP 409 ${err:-conflict}). $NOTHING" ;;
    1:403:*|1:400:*)
      ledger_launch refused "${err:-$code}"
      if [ "$code" = 403 ]; then echo "The jobs worker says you are not an owner (BOX_OPS_OWNERS). $NOTHING"
      else echo "The jobs worker refused the launch (HTTP 400 $err). $NOTHING"; fi ;;
    *)
      log "launch q$qid: unknown outcome (rc $RC http ${code:-no answer}); the claim stays and nothing is resent"
      echo "I do not know if the launch was queued (HTTP ${code:-no answer}). I will not send it again. Check /box list." ;;
  esac
}

# br_fly <offer-detail-json> — the Fly pool half of a /project load yes.
br_fly() {
  local p cap type body
  p=$(jq -r .project <<< "$1"); cap=$(jq -r '.cap // ""' <<< "$1")
  if [ -e "$H/flags/fly-pool-$p" ]; then
    if [ -z "$cap" ]; then offer_status accepted; echo "$p is already in the Fly pool. Nothing to queue."; return 0; fi
    type=fly_pool_cap
    body=$(jq -nc --arg p "$p" --argjson c "$cap" --arg r "$REASON" --arg o "$OWNER" \
      '{box: "hub", type: "fly_pool_cap", target: $p, cap: $c, reason: $r, actor: $o, confirm: true}')
  else
    type=fly_onboard
    body=$(jq -nc --arg p "$p" --arg c "$cap" --arg r "$REASON" --arg o "$OWNER" \
      '{box: "hub", type: "fly_onboard", target: $p, reason: $r, actor: $o, confirm: true}
       + (if $c == "" then {} else {cap: ($c | tonumber)} end)')
  fi
  post_cmd "$body"
  local id code="${JOBS_HTTP:-}" err
  id=$(jq -r '.id // "?"' <<< "${BODY:-null}" 2>/dev/null); err=$(jq -r '.error // ""' <<< "${BODY:-null}" 2>/dev/null)
  case "$RC:$code" in
    0:*) offer_status accepted
         log "$type #$id queued for $p by $OWNER"
         echo "Queued $type #$id for $p. The hub's box-ops lane runs it." ;;
    1:403) offer_status refused; echo "The jobs worker says you are not an owner (BOX_OPS_OWNERS). $NOTHING" ;;
    1:400|9:*) offer_status refused; echo "The jobs worker refused $type (HTTP $code $err). $NOTHING" ;;
    *) offer_status unknown
       echo "I do not know if $type was queued (HTTP ${code:-no answer}). I will not send it again. Check /box list." ;;
  esac
}

# br_yes — rc 1 unless this conversation has an open, young offer.
br_yes() {
  local row o kind owner at age me rc
  req GET "/api/ledger?kind=box_offer&key=$(jq -rn --arg k "$(offer_key)" '$k | @uri')"
  [ "$RC" = 0 ] || return 1
  [ "$(jq -r '.ledger.status // ""' <<< "$BODY" 2>/dev/null)" = offered ] || return 1
  row="$BODY"
  o=$(jq -r '.ledger.detail // ""' <<< "$row")
  jq -e 'type == "object"' <<< "$o" >/dev/null 2>&1 || return 1
  kind=$(jq -r '.kind // ""' <<< "$o"); owner=$(jq -r '.owner // ""' <<< "$o"); at=$(jq -r '.at // ""' <<< "$o")
  [[ $at =~ ^[0-9]+$ ]] || return 1
  knobs || { not_configured; return 0; }
  age=$(( $(now_s) - at ))
  [ "$age" -ge 0 ] && [ "$age" -le "$BOX_REQUEST_OFFER_S" ] || return 1
  me=$(br_owner); rc=$?
  if [ "$rc" != 0 ] || [ -z "$owner" ] || [ "$me" != "$owner" ]; then
    log "yes on $(offer_key) from '${BOXREQ_FROM_USER:-}' (${BOXREQ_TRANSPORT:-telegram}) refused: not $owner"
    echo "Only $owner can approve this. $NOTHING"; return 0
  fi
  OWNER="$me"; REASON="chat: yes to the $kind offer for $(jq -r .project <<< "$o")"
  case "$kind" in
    launch) br_launch "$o" ;;
    project)
      case "$(jq -r .place <<< "$o")" in
        dedicated)
          offer_status accepted
          A_PROJECT=$(jq -r .project <<< "$o"); A_ID=""; A_ACCOUNT=""; A_VCPUS=""; A_MEM=""; A_DISK=""
          FACTS=$(jq -c .facts <<< "$o")
          br_quote ;;
        fly) br_fly "$o" ;;
        shared)
          offer_status accepted
          echo "$(jq -r .project <<< "$o") fits the shared box. Adding it is a fleet.conf PR; there is no queue command for it. $NOTHING" ;;
        *) echo "The open offer names no place. $NOTHING" ;;
      esac ;;
    *) return 1 ;;
  esac
}

# br_project — /project load. Writes an offer, queues nothing.
br_project() {
  br_place "$FACTS" || { place_refusal; return 0; }
  local u; u=$(unknown_facts "$FACTS")
  if ! offer_put "$(jq -nc --arg o "$OWNER" --arg p "$A_PROJECT" --arg pl "$PLACE" --arg c "$A_CAP" \
       --argjson fa "$FACTS" --argjson at "$(now_s)" \
       '{kind: "project", owner: $o, quote_id: null, figure: null, target: $p, account: null, project: $p,
         vcpus: null, mem_gb: null, disk_gb: null, place: $pl,
         cap: (if $c == "" then null else ($c | tonumber) end), facts: $fa, at: $at}')"; then
    echo "Placement rule for $A_PROJECT: $PLACE, because $PLACE_WHY. I could not save the offer (HTTP $(http_of)), so a yes would do nothing. $NOTHING"
    return 0
  fi
  log "offer $(offer_key): project $A_PROJECT -> $PLACE"
  echo "Placement rule for $A_PROJECT: $PLACE, because $PLACE_WHY.${u:+ $u} Reply yes within $(within "$BOX_REQUEST_OFFER_S") to go ahead."
}

# br_list — /box list. Read-only, no owner check.
br_list() {
  local out=""
  req GET /api/orgo-computers
  if [ "$RC" = 0 ]; then
    out=$(jq -r '"Orgo computers:", (if (.computers | length) == 0 then "- none recorded" else empty end),
      (.computers[] | "- \(.name // .orgo_id) (\(.account)): \(.status // "?"), \(.cpu // "?") vCPU, \(.ram_gb // "?") GB RAM, \(.disk_gb // "?") GB disk\(if .gone_at then ", gone since \(.gone_at)" else "" end)"),
      (if .truncated then "(the list is cut; more computers exist)" else empty end)' <<< "$BODY")
  else out="Orgo computers: the jobs worker did not answer (HTTP $(http_of)). Nothing listed."; fi
  req GET "/api/box-commands?box=hub"
  if [ "$RC" = 0 ]; then
    out="$out"$'\n'$(jq -r '[.commands[]? | select(.type | test("^(orgo|fly)_"))] as $c
      | "Box commands (newest 10 of the last 50 hub commands):",
        (if ($c | length) == 0 then "- none" else empty end),
        ($c[0:10][] | "- #\(.id) \(.type) \(.target) \(.status)\(if .finished_at then " \(.finished_at)" else "" end)")' <<< "$BODY")
  else out="$out"$'\n'"Box commands: the jobs worker did not answer (HTTP $(http_of)). Nothing listed."; fi
  printf '%s\n' "$out"
}

USAGE="Use: /box launch <project> [--id <box>] [--account a] [--vcpus N --mem-gb N --disk-gb N] [--repo-mb N --builds-day N --desktop --isolated], /box list, or /project load <project> [facts] [--cap N]."

# intercept <text>
intercept() {
  local t="$1" first lc toks rc
  # poll-commands.sh puts one attribution line above a chat message.
  first="${t%%$'\n'*}"
  if [[ $t == *$'\n'* ]] && [[ $first =~ ^\[(telegram|slack):\ from\ .*\]$ ]]; then t="${t#*$'\n'}"; fi
  t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
  [[ $t == *$'\n'* ]] && return 1
  lc=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
  case "$lc" in
    yes|yes.|yes!) br_yes; return $? ;;
  esac
  REASON="chat: ${t:0:80}"
  if [[ $lc =~ ^/box([[:space:]]|$) ]]; then
    read -r -a toks <<< "$t"
    case "${toks[1]:-}" in
      list) [ "${#toks[@]}" = 2 ] || { echo "$USAGE"; return 0; }; br_list; return 0 ;;
      launch) parse_args "${toks[@]:2}" || { echo "$ARG_ERR. $USAGE $NOTHING"; return 0; } ;;
      *) echo "$USAGE"; return 0 ;;
    esac
  elif [[ $lc =~ ^/project([[:space:]]|$) ]]; then
    read -r -a toks <<< "$t"
    [ "${toks[1]:-}" = load ] || { echo "$USAGE"; return 0; }
    parse_args "${toks[@]:2}" || { echo "$ARG_ERR. $USAGE $NOTHING"; return 0; }
  else
    local s="${t%[.!]}" sl
    sl=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
    [[ $sl =~ ^(we|i)[[:space:]]+need[[:space:]]+a[[:space:]]+(new[[:space:]]+|dedicated[[:space:]]+)?box[[:space:]]+for[[:space:]]+([a-z0-9._-]{1,64})$ ]] || return 1
    parse_args "${s:$(( ${#s} - ${#BASH_REMATCH[3]} ))}" || return 1
  fi
  knobs || { not_configured; return 0; }
  OWNER=$(br_owner); rc=$?
  [ "$rc" = 0 ] || { log "${lc%% *} from '${BOXREQ_FROM_USER:-}' (${BOXREQ_TRANSPORT:-telegram}) refused: not an owner"; echo "Only an owner can ask for this. $NOTHING"; return 0; }
  if [[ $lc =~ ^/project ]]; then br_project; else br_quote; fi
  return 0
}

# watch <launch-id>
watch() {
  local id="${1:-}" start row status detail line text
  [[ $id =~ ^[1-9][0-9]*$ ]] || { echo "usage: box-request.sh watch <launch-id>" >&2; return 64; }
  knobs || return 1
  exec 9>"$H/locks/box-request-watch-$id.lock"
  flock -n 9 || return 0
  start=$SECONDS
  while :; do
    req GET "/api/box-commands?box=hub"
    if [ "$RC" = 0 ]; then
      row=$(jq -c --argjson q "$id" '.commands[]? | select(.id == $q)' <<< "$BODY" 2>/dev/null)
      status=$(jq -r '.status // ""' <<< "${row:-null}" 2>/dev/null)
      if [ "$status" = ok ] || [ "$status" = fail ]; then
        detail=$(jq -r '.detail // ""' <<< "$row")
        line=$(grep -o 'box-launch: box=.*' <<< "$detail" | head -1)
        text="$status ${line:-${detail:0:300}}"
        if HARNESS="$H" "$H/bin/archie-tg-send.sh" "box-launch-$id" "launch #$id: $text" 9>&-; then
          log "launch #$id $status reported"; return 0
        fi
        log "launch #$id $status: the Telegram send failed, retrying on the next poll"
      fi
    fi
    if [ $(( SECONDS - start + BOX_REQUEST_WATCH_POLL_S )) -gt "$BOX_REQUEST_WATCH_S" ]; then
      alert "launch #$id did not finish in ${BOX_REQUEST_WATCH_S}s; nothing was reported"
      return 1
    fi
    sleep "$BOX_REQUEST_WATCH_POLL_S"
  done
}

case "${1:-}" in
  intercept) shift; intercept "${1:-}"; exit $? ;;
  watch) shift; watch "${1:-}"; exit $? ;;
  *) echo "usage: box-request.sh intercept <text> | watch <launch-id>" >&2; exit 64 ;;
esac
