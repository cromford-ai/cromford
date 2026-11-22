#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/jobs.sh — BH-1194: the job row itself: claims and the double-build guard, the lane lifecycle, phases, heartbeats, rules and retry policy, artifacts, transcripts, verdicts, contracts, caps and the catalog, plus the hub ledgers of record. Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# job_open <project> <ticket_id> <kind> <stage> [lane] [meta-json] [issue_created_at]
#   issue_created_at (BH-482.0): ISO stamp of the GitHub issue; passed through
#           untouched, the worker validates; empty = absent from the body.
#   rc 0 -> prints the job id (claim is ours; the row carries the resolved cap)
#   rc 9 -> REFUSED. Work this box may not start right now. Two shapes, both of
#           them a CLEAN SKIP for the caller and never an error:
#             "IN_FLIGHT <box> <job-id>"  — the phase-1 double-build guard
#             "REFUSED <scope> :: <reason>" — a phase-6 concurrency rule, or a
#             retry of this same work already scheduled with a backoff still to
#             run. The reason is the row's own words, so a log line can say WHY
#             without a second round trip.
#           JOB_REFUSED carries the same reason for callers that do not capture
#           stdout. The CALLER decides; the documented default is skip and log.
#   rc 1 -> API unusable. Say nothing, behave exactly like today.
JOB_REFUSED=""
job_open() {
  local project="${1:-}" ticket="${2:-}" kind="${3:-}" stage="${4:-plan}" lane="${5:-}" meta="${6:-}" \
        issue_created_at="${7:-}"
  [ -n "$project" ] && [ -n "$kind" ] || return 1
  local body resp rc
  body=$(jq -nc --arg p "$project" --arg t "$ticket" --arg k "$kind" --arg b "$JOBS_BOX" \
    --arg s "$stage" --arg l "$lane" --arg m "$meta" --arg ic "$issue_created_at" \
    '{project:$p,kind:$k,box:$b,stage:$s}
     + (if $t == "" then {} else {ticket_id:$t} end)
     + (if $l == "" then {} else {lane:$l} end)
     + (if $m == "" then {} else {meta:$m} end)
     + (if $ic == "" then {} else {issue_created_at:$ic} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/jobs "$body"); rc=$?
  if [ "$rc" -eq 9 ]; then
    local refused reason scope
    refused=$(printf '%s' "$resp" | jq -r '.refused // false' 2>/dev/null)
    if [ "$refused" = "true" ]; then
      # A phase-6 rule refusal. It names the scope that bound and quotes the
      # rule's own reason, because a refusal a human cannot explain is a
      # refusal they will work around.
      scope=$(printf '%s' "$resp" | jq -r '.scope // "rule"' 2>/dev/null)
      reason=$(printf '%s' "$resp" | jq -r '.reason // "refused by a concurrency rule"' 2>/dev/null)
      JOB_REFUSED="$scope: $reason"
      printf 'REFUSED %s :: %s' "$scope" "$reason"
      return 9
    fi
    JOB_REFUSED="in flight on $(printf '%s' "$resp" | jq -r '.job.box // "?"' 2>/dev/null)"
    printf 'IN_FLIGHT %s %s' \
      "$(printf '%s' "$resp" | jq -r '.job.box // "?"' 2>/dev/null)" \
      "$(printf '%s' "$resp" | jq -r '.job.id // "?"' 2>/dev/null)"
    return 9
  fi
  [ "$rc" -eq 0 ] || return 1
  local id; id=$(printf '%s' "$resp" | jq -r '.job.id // empty' 2>/dev/null)
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# job_update <job_id> <key=value>...
#   keys: stage, status, spent_usd, spend_delta, budget_usd, meta
#   Spend arrives as spend_delta (this stage's cost); the worker does the sum,
#   so two stages finishing at once cannot lose one another's dollars.
job_update() {
  local id="${1:-}"; shift || true
  [ -n "$id" ] || return 1
  [ $# -gt 0 ] || return 1
  local body="{}" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      spent_usd|spend_delta|budget_usd)
        body=$(printf '%s' "$body" | jq -c --arg k "$k" --arg v "$v" \
          'if ($v|test("^-?[0-9]+([.][0-9]+)?$")) then .[$k] = ($v|tonumber) else . end' 2>/dev/null) ;;
      stage|status|meta)
        body=$(printf '%s' "$body" | jq -c --arg k "$k" --arg v "$v" '.[$k] = $v' 2>/dev/null) ;;
      *) continue ;;
    esac
    [ -n "$body" ] || return 1
  done
  [ "$body" = "{}" ] && return 1
  _jobs_req PATCH "/api/jobs/$id" "$body" > /dev/null
}

# job_result_put <job_id> <facts-json>
#   THE JOB'S FINAL PATCH (W2-B, 2026-09-14). A build that finishes on a pool
#   machine used to hand its terminal facts to the HUB, which handed them to the
#   owning box, which staged them for a session that read them back out of a
#   text file. Every one of those hops is a clock, and the hub is in the middle
#   of all of them. This is the same facts — result line, pr_url, sha, tier,
#   verdict, cost — written straight to the row the builder already holds, the
#   moment the build concludes. bin/lib/builder-direct.sh:bd_facts composes the
#   object, so what goes into the ledger and what the builder acts on cannot
#   come to disagree.
#
#   IT DOES NOT TOUCH `status`, and that is not an oversight. run-build.sh's
#   EXIT trap closes the row with the verdict the RESULT file carries, and a
#   second writer racing it could walk a job into `done` that the trap then has
#   to move out of — which JOB_TRANSITIONS correctly forbids. Facts here,
#   lifecycle there.
#
#   IDEMPOTENT ON REPLAY: a PATCH carrying the same object leaves the same row.
#   A result delivered twice (a resumed ingest, a re-run sweep) is one row with
#   one answer, which is exactly what the relay path could never promise.
#
#   rc 1 -> API unusable, or the facts are not json. Say nothing; the caller
#   keeps the file path it has always had.
job_result_put() {
  local id="${1:-}" facts="${2:-}"
  [ -n "$id" ] && [ -n "$facts" ] || return 1
  printf '%s' "$facts" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  job_update "$id" "meta=$facts"
}

# job_event <job_id> <stage> [verdict] [detail]
job_event() {
  local id="${1:-}" stage="${2:-}" verdict="${3:-}" detail="${4:-}"
  [ -n "$id" ] || return 1
  local body
  body=$(jq -nc --arg s "$stage" --arg v "$verdict" --arg a "$JOBS_BOX" --arg d "$detail" \
    '{actor:$a}
     + (if $s == "" then {} else {stage:$s} end)
     + (if $v == "" then {} else {verdict:$v} end)
     + (if $d == "" then {} else {detail:$d} end)' 2>/dev/null) || return 1
  _jobs_req POST "/api/jobs/$id/events" "$body" > /dev/null
}

# job_cap <lane>   e.g. job_cap execute/project-3/claude
#   Prints the lane's dollar cap and returns 0 ONLY when the catalog actually
#   has a matching lane. A tier fallback returns 1 on purpose: the caller's own
#   chain (catalog file, then the stage tier, plus the UNBUDGETED LANE alert)
#   already handles "nobody sized this lane", and answering with a tier number
#   here would hide that gap behind a confident-looking figure.
job_cap() {
  local lane="${1:-}" resp cap src
  [ -n "$lane" ] || return 1
  resp=$(_jobs_req GET "/api/catalog/$lane") || return 1
  src=$(printf '%s' "$resp" | jq -r '.source // empty' 2>/dev/null)
  [ "$src" = catalog ] || return 1
  cap=$(printf '%s' "$resp" | jq -r '.budget_usd // empty' 2>/dev/null)
  case "$cap" in ''|*[!0-9.]*) return 1 ;; esac
  printf '%s' "$cap"
}

# job_ledger_get <kind> <key>
#   rc 0 -> prints the row's status (it is in the DB)
#   rc 2 -> worker reachable, no such row (a real miss — caller may merge/apply)
#   rc 1 -> API unusable. For MERGE/APPLY the caller MUST fall back to the
#           file ledger rather than treat this as "not done". That is the
#           fail-CLOSED read: never merge blind just because the DB blinked.
job_ledger_get() {
  local kind="${1:-}" key="${2:-}" resp rc status
  [ -n "$kind" ] && [ -n "$key" ] || return 1
  local q
  q=$(jq -nr --arg k "$kind" --arg v "$key" '"kind="+($k|@uri)+"&key="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/ledger?$q"); rc=$?
  case "$rc" in
    0) status=$(printf '%s' "$resp" | jq -r '.ledger.status // empty' 2>/dev/null)
       [ -n "$status" ] || return 1
       printf '%s' "$status"; return 0 ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}

# job_ledger_row <kind> <key>
#   job_ledger_get for a caller that needs the DETAIL as well as the status
#   (BH-2317: the comment-dedup token, the resolver record's counters).
#   rc 0 -> prints one compact JSON line {status, detail} ("" for no detail)
#   rc 2 -> worker reachable, no such row
#   rc 1 -> API unusable, or a 2xx that carries no row status
job_ledger_row() {
  local kind="${1:-}" key="${2:-}" resp rc q
  [ -n "$kind" ] && [ -n "$key" ] || return 1
  q=$(jq -nr --arg k "$kind" --arg v "$key" '"kind="+($k|@uri)+"&key="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/ledger?$q"); rc=$?
  case "$rc" in
    0) printf '%s' "$resp" | jq -ce '.ledger | select((.status // "") != "") | {status, detail: (.detail // "")}' 2>/dev/null || return 1 ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}

# job_abandon_lifted <project> <KEY> <hold-verdict>
#   A PERSON'S RESUME LIFTS A RESOLVER ABANDON (example-org/project-6 #3720: a
#   RESUME of 2026-11-10 sat 8 days behind the `abandoned "<project> <KEY>"`
#   row, which only an operator's ledger-put could release). <hold-verdict> is
#   bin/lib/hold.sh's line for the ticket. rc 0, and the comment's time on
#   stdout, when it reads `clear<TAB>lifted-by-comment <at>` and <at> is LATER
#   than the row's updated_at: the person spoke after the ladder ended. rc 1
#   for everything else (no lift, a lift older than the abandon, a row that is
#   not `abandoned` or did not read), so the abandon stands. Both times are ISO
#   seconds Z (GitHub created_at, the worker's nowIso), so they compare as text.
#   A read only: bin/lib/rb/gates.sh is the one writer of `released`.
job_abandon_lifted() {
  local p="${1:-}" key="${2:-}" hv="${3:-}" at q resp ab
  case "$hv" in "clear"$'\t'"lifted-by-comment "*) ;; *) return 1 ;; esac
  at=${hv#*lifted-by-comment }; at=${at%%[[:space:]]*}
  [ -n "$p" ] && [ -n "$key" ] && [ -n "$at" ] || return 1
  q=$(jq -nr --arg v "$p $key" '"kind=abandoned&key="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/ledger?$q") || return 1
  ab=$(printf '%s' "$resp" | jq -r '.ledger | select(.status == "abandoned") | .updated_at // empty' 2>/dev/null)
  [ -n "$ab" ] && [[ "$at" > "$ab" ]] || return 1
  printf '%s' "$at"
}

# job_ledger_put <kind> <key> <status> [detail]
#   Write-through. rc 1 on outage — callers still append the file ledger.
job_ledger_put() {
  local kind="${1:-}" key="${2:-}" status="${3:-}" detail="${4:-}"
  [ -n "$kind" ] && [ -n "$key" ] && [ -n "$status" ] || return 1
  local body
  body=$(jq -nc --arg k "$kind" --arg v "$key" --arg s "$status" --arg a "$JOBS_BOX" --arg d "$detail" \
    '{kind:$k,key:$v,status:$s,actor:$a}
     + (if $d == "" then {} else {detail:$d} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/ledger "$body" >/dev/null
}

# job_ledger_claim <kind> <key> <status> <stale_s> [terminal-csv] [detail]
#   BH-5003: the compare-and-set job_ledger_put cannot give. The row is taken
#   when it is absent, or when its status is not in terminal-csv AND (it holds
#   a different status, or this same status older than stale_s on the WORKER's
#   clock). One statement on the worker, so two boxes never both win.
#   rc 0 -> claimed; prints the row's status
#   rc 3 -> not claimed; prints the holder's status
#   rc 2 -> the claim route did not answer its contract: a 404 (not deployed
#           yet), or a 2xx with no boolean .claimed. NEVER read as claimed —
#           the caller falls back to what it did before the route existed.
#   rc 1 -> API unusable (outage, auth, 4xx/5xx)
job_ledger_claim() {
  local kind="${1:-}" key="${2:-}" status="${3:-}" stale="${4:-}" term="${5:-}" detail="${6:-}" body resp rc claimed st
  [ -n "$kind" ] && [ -n "$key" ] && [ -n "$status" ] || return 1
  [[ "$stale" =~ ^[0-9]+$ ]] || return 1
  body=$(jq -nc --arg k "$kind" --arg v "$key" --arg s "$status" --arg a "${JOBS_BOX:-}" \
    --arg t "$term" --arg d "$detail" --argjson st "$stale" \
    '{kind:$k,key:$v,status:$s,stale_s:$st,
      terminal:($t | split(",") | map(select(. != "")))}
     + (if $a == "" then {} else {actor:$a} end)
     + (if $d == "" then {} else {detail:$d} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/ledger/claim "$body"); rc=$?
  case "$rc" in
    0) ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
  claimed=$(printf '%s' "$resp" | jq -r 'if (.claimed | type) == "boolean" then .claimed else "" end' 2>/dev/null)
  st=$(printf '%s' "$resp" | jq -r '.ledger.status // empty' 2>/dev/null)
  case "$claimed" in
    true)  printf '%s' "${st:-$status}"; return 0 ;;
    false) printf '%s' "$st"; return 3 ;;
    *)     return 2 ;;
  esac
}

# --- BH-397: hub ledgers of record client verbs -----------------------------
# These verbs back the five files/tables described in docs/DB-COORDINATION-SPEC.md.
# They keep the file as the ledger of record and use D1 as a warm read-side
# cache, failing open so a worker outage never blocks a lane.

# pr_owners_put <repo> <project> <state-json-file>
#   Write-through: PUT the PR owner state file to /api/pr-owners. An empty
#   `.prs` map is sent as `rows:[]` with `complete:true` — that is how D1 is
#   told the set is now empty.
#   rc 0 on 2xx, rc 1 on outage/5xx/auth/empty-secret, rc 2 on a real 404.
pr_owners_put() {
  local repo="${1:-}" project="${2:-}" file="${3:-}" rows body
  [ -n "$repo" ] && [ -n "$project" ] && [ -s "$file" ] || return 1
  rows=$(jq -c '.prs // {} | to_entries | map(.value + {number: (.key | tonumber)}) | sort_by(.number)' "$file" 2>/dev/null) || return 1
  # AN EMPTY MAP IS AN ANSWER, NOT A MISS. `complete:true` exists so D1 learns
  # the FULL set this box owns; a repo whose open PRs all closed must be able to
  # say "none". Returning rc 2 here sent no request at all, so the stale OWNED
  # rows survived in D1 forever and pr_owners_list resurrected them on a box
  # that had no file. rc 2 is reserved for a real "no rows" RESPONSE.
  [ -n "$rows" ] || return 1
  body=$(jq -nc --arg r "$repo" --arg p "$project" --arg a "$JOBS_BOX" \
    --argjson rows "$rows" \
    '{repo:$r,project:$p,actor:$a,complete:true,rows:$rows}' 2>/dev/null) || return 1
  _jobs_req PUT /api/pr-owners "$body"
}

# pr_owners_list <repo>
#   Read /api/pr-owners?repo=<repo>. Print file-shaped JSON.
#   rc 0 only when the response's .pr_owners array has >=1 element; rc 2 for
#   empty array, {"ok":true}, or a 200 payload with no array; rc 1 on outage.
#   NO limit= IS SENT. The 500-row ceiling is the route's own (it orders by
#   number and LIMITs 500 whatever the caller asks), so a client-side copy of
#   the number is a second place for it to drift.
pr_owners_list() {
  local repo="${1:-}" resp rc generated_at q
  [ -n "$repo" ] || return 1
  q=$(jq -nr --arg r "$repo" '"repo="+($r|@uri)') || return 1
  resp=$(_jobs_req GET "/api/pr-owners?$q"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if ! printf '%s' "$resp" | jq -e '.pr_owners | type == "array" and length > 0' >/dev/null 2>&1; then
    return 2
  fi
  # generated_at IS THE ROUTE'S as_of, not this box's clock. The overlay rule
  # callers follow is "the row wins when row.updated_at >= file.generated_at",
  # and both of those stamps are written by the worker; mixing in a local clock
  # compares two different clocks and decides a merge with the difference.
  # The local clock is the fallback for a payload that carries no as_of.
  generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s' "$resp" | jq -c --arg t "$generated_at" \
    '{generated_at: (.as_of // $t), prs: (.pr_owners | map({key: (.number|tostring), value: .}) | from_entries)}' 2>/dev/null
}

# _batch_put <endpoint> <project> <rows-json-file>
#   Shared helper for decisions_put / findings_put. POSTs the whole batch in
#   one call.
#
#   THE INPUT IS CLASSIFIED ONCE. "No lines to send" has exactly one answer —
#   rc 2 and no request — whether the rows file is absent, zero bytes, or `[]`.
#   Those are the same state (a tick with nothing new), and the zero-byte case
#   used to answer rc 1, which is the OUTAGE code: every caller that logs an
#   unreachable worker on rc 1 would have reported an outage on a quiet tick.
#   A file that parses but is not an array is BAD INPUT: rc 1, no request.
_batch_put() {
  local endpoint="${1:-}" project="${2:-}" file="${3:-}" rows type body
  [ -n "$endpoint" ] && [ -n "$project" ] && [ -n "$file" ] || return 1
  [ -s "$file" ] || return 2
  rows=$(jq -c '.' "$file" 2>/dev/null) || return 1
  type=$(printf '%s' "$rows" | jq -r 'type' 2>/dev/null)
  [ "$type" = array ] || return 1
  [ "$(printf '%s' "$rows" | jq -r 'length' 2>/dev/null)" != 0 ] || return 2
  body=$(jq -nc --arg p "$project" --arg a "$JOBS_BOX" --argjson rows "$rows" \
    '{project:$p,actor:$a,rows:$rows}' 2>/dev/null) || return 1
  _jobs_req POST "$endpoint" "$body"
}

# decisions_put <project> <rows-json-file>
# findings_put <project> <rows-json-file>
#   POST the batch to /api/decisions or /api/findings in one call.
#   Callers keep rows <= 200; these verbs do not split.
decisions_put() { _batch_put /api/decisions "$@"; }
findings_put()  { _batch_put /api/findings  "$@"; }

# log_rehydrate <decisions|findings> <file> [days=30] [project]
#   Recreate a local log file from the D1 append log. No network if the file is
#   already present and non-empty. Atomic write; log a summary line.
#   rc 2 when D1 has no usable rows; rc 1 on outage (file untouched).
#
#   THE ROUTE IS /api/<kind>, NOT /api/ledger. decisions and findings are their
#   own tables (worker/jobs/schema.sql), written by POST /api/decisions and
#   POST /api/findings and read back by GET on the same paths, which are the
#   only two routes that take `since` and answer `{rows, truncated, as_of}` —
#   the three things this verb's contract names. /api/ledger has none of them
#   and nothing ever writes kind=decisions rows into `ledgers`, so a rehydrate
#   pointed there answers "D1 has no rows" forever, on a worker that is working.
log_rehydrate() {
  local kind="${1:-}" file="${2:-}" days="${3:-30}" project="${4:-}"
  local since q resp rc written tmp truncated logged sel
  [ -n "$kind" ] && [ -n "$file" ] || return 1
  # `kind` becomes a path segment, so it is a closed set, not a string to pass through.
  case "$kind" in decisions|findings) ;; *) return 1 ;; esac
  [ -s "$file" ] && return 0
  case "$days" in ''|*[!0-9]*) days=30 ;; esac
  # THE CURSOR IS IN THE WRITERS' FORMAT, not ISO-8601, and that is the whole
  # point. The worker compares `stamp >= since` as STRINGS (listLines binds the
  # cursor straight into SQL), and the stamps these logs carry read
  # `2026-09-15 14:22:37Z` — a SPACE between date and time, from
  # bin/decision-log.sh and bin/findings-log.sh. A cursor with a `T` there is a
  # different string: 0x20 sorts before 0x54, so every row stamped on the
  # boundary day itself fell outside the window and a 30-day rehydrate silently
  # returned 29 (BH-1042, audit fact #29 — bin/repeat-family.sh read the short
  # log and answered NOT MEASURED while the rows existed).
  # `@uri` below encodes the space as %20, the worker's searchParams decodes it,
  # and `str(...,32)` keeps all 20 characters.
  since=$(date -u -d "-${days} days" '+%Y-%m-%d %H:%M:%SZ') || return 1
  q=$(jq -nr --arg s "$since" --argjson n 5000 \
    '"since="+($s|@uri)+"&limit="+($n|tostring)') || return 1
  [ -n "$project" ] && q="$q&project=$(jq -nr --arg p "$project" '($p|@uri)')"
  resp=$(_jobs_req GET "/api/$kind?$q"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # One selector, used for both the count and the bytes, so the summary line can
  # never disagree with the file. A row with no stamp or no line cannot be
  # written as `stamp + " " + line`; a line carrying an embedded newline would
  # land as two rows and break every reader that splits on newlines. Both are
  # dropped, and neither is counted.
  sel='[.rows[]? | select((.stamp // "") != "" and (.line // "") != "" and ((.line|index("\n")) == null))]'
  written=$(printf '%s' "$resp" | jq -r "$sel | length" 2>/dev/null)
  case "$written" in ''|*[!0-9]*|0) return 2 ;; esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/jobs-rehydrate.XXXXXX" 2>/dev/null) || { _jobs_log "log_rehydrate mktemp failed"; return 1; }
  printf '%s' "$resp" | jq -r "${sel}[] | \"\(.stamp) \(.line)\"" 2>/dev/null > "$tmp"
  if ! mkdir -p "$(dirname "$file")" 2>/dev/null || ! mv "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  # `truncated` is the WORKER's measurement (it fetches limit+1 rows to know),
  # never a guess from the row count we happened to receive.
  truncated=$(printf '%s' "$resp" | jq -r 'if (.truncated // false) then "true" else "false" end' 2>/dev/null)
  [ -n "$truncated" ] || truncated=false
  # Direct append, NOT _jobs_log: a successful rehydrate is not degraded mode,
  # and routing it through _jobs_log would burn the daily unreachable ALERT flag
  # and silence the next real outage.
  logged=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  mkdir -p "$JOBS_HARNESS/logs" 2>/dev/null
  echo "$logged [jobs-client] rehydrated $written $kind rows (truncated=$truncated)" >> "$JOBS_HARNESS/logs/jobs-client.log"
  return 0
}

# telegram_topics_get
#   GET /api/telegram-topics. Prints `{"topics":{...}}` — the FILE shape, not
#   the worker's envelope — and, like setting_get, prints nothing at all when
#   the answer is a miss.
#   rc 0 with rows, rc 2 when .topics is empty/missing, rc 1 on outage.
telegram_topics_get() {
  local resp rc topics
  resp=$(_jobs_req GET /api/telegram-topics); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  topics=$(printf '%s' "$resp" | jq -c '.topics // {}' 2>/dev/null) || return 1
  [ -n "$topics" ] && [ "$topics" != "{}" ] || return 2
  jq -nc --argjson t "$topics" '{topics:$t}' 2>/dev/null
}

# _topic_pair_ok <project> <thread_id>
#   The worker's own two rules, checked here so a bad pair never becomes a
#   request: project matches /^[a-z0-9_.-]{1,64}$/ and thread_id is a positive
#   integer. rc 0 when the pair is sendable.
_topic_pair_ok() {
  local project="${1:-}" thread_id="${2:-}"
  [ -n "$project" ] && [ "${#project}" -le 64 ] || return 1
  case "$project" in *[!a-z0-9_.-]*) return 1 ;; esac
  case "$thread_id" in ''|*[!0-9]*|0*) return 1 ;; esac
  return 0
}

# telegram_topic_set <project> <thread_id>
#   PUT one project->thread mapping to /api/telegram-topics.
#   thread_id GOES ON THE WIRE AS A JSON INTEGER. The file stores integers and
#   the route answers integers, so sending a string would make the
#   file -> seed -> GET -> file round trip depend on a coercion nothing
#   promises. Validated first, so the integer is one this box vouched for.
telegram_topic_set() {
  local project="${1:-}" thread_id="${2:-}" body
  _topic_pair_ok "$project" "$thread_id" || return 1
  body=$(jq -nc --arg p "$project" --argjson t "$thread_id" --arg a "$JOBS_BOX" \
    '{project:$p,thread_id:$t,actor:$a}' 2>/dev/null) || return 1
  _jobs_req PUT /api/telegram-topics "$body"
}

# telegram_topics_sync <file> [max_age_secs=600]
#   Reconcile <file> with D1. Mtime-throttled: a file younger than
#   max_age_secs is left untouched and costs no request. If the file is
#   missing or stale, fetch D1 and atomically write `{"topics":{...}}` to
#   <file>. If D1 is empty and a local file exists, seed D1 from the file
#   (root-map and .topics shapes), file untouched. rc 1 on outage.
#   THE FILE AND THE WINDOW ARE ARGUMENTS, not constants: sibling 5's
#   bin/poll-commands.sh passes its own path, and a hardcoded path silently
#   dropped it. The window is compared in SECONDS against the mtime; the
#   earlier `find -mmin -60` was six times the 600s this verb promises and
#   called a 20-minute-old file fresh.
telegram_topics_sync() {
  local file="${1:-}" max_age="${2:-600}" resp rc topics="" body="" tmp="" merged="" entries="" entry="" key="" val="" rc2=0 now=0 mtime=0
  [ -n "$file" ] || return 1
  case "$max_age" in ''|*[!0-9]*) max_age=600 ;; esac
  if [ -s "$file" ]; then
    now=$(date -u '+%s' 2>/dev/null); mtime=$(stat -c %Y "$file" 2>/dev/null) || mtime=0
    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
    # Unreadable mtime or clock reads as stale, never as fresh: an extra GET is
    # cheap, a file that never refreshes is the bug.
    [ "$now" -gt 0 ] && [ "$mtime" -gt 0 ] && [ "$((now - mtime))" -lt "$max_age" ] && return 0
  fi
  resp=$(_jobs_req GET /api/telegram-topics); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  topics=$(printf '%s' "$resp" | jq -c '.topics // {}' 2>/dev/null)
  if [ "$topics" != "{}" ] && [ -n "$topics" ]; then
    # The FILE shape, rebuilt from .topics — never the raw envelope. A worker
    # that answers {"ok":true,"topics":{...}} would otherwise land `ok` in the
    # file every caller parses.
    body=$(jq -nc --argjson t "$topics" '{topics:$t}' 2>/dev/null) || return 1
    tmp=$(mktemp "${TMPDIR:-/tmp}/topics.XXXXXX" 2>/dev/null) || { _jobs_log "telegram_topics_sync mktemp failed"; return 1; }
    printf '%s' "$body" > "$tmp"
    if mkdir -p "$(dirname "$file")" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null; then
      return 0
    fi
    rm -f "$tmp"; return 1
  fi
  # D1 empty and local file present: seed D1 from the file, both root and .topics shapes.
  [ -s "$file" ] || return 2
  merged=$(jq -nc --slurpfile f "$file" \
    '(($f[0] // {}) | del(.topics)) + (($f[0] // {}).topics // {}) | to_entries | map(select(.value != null)) | from_entries' 2>/dev/null) || return 1
  entries=$(printf '%s' "$merged" | jq -c 'to_entries[]?' 2>/dev/null) || return 1
  [ -n "$entries" ] || return 0
  while IFS= read -r entry; do
    key=$(printf '%s' "$entry" | jq -r '.key // empty' 2>/dev/null)
    val=$(printf '%s' "$entry" | jq -r '.value | tostring // empty' 2>/dev/null)
    # A ROW THE WORKER WOULD REFUSE IS NOT AN OUTAGE. One unusable entry — a
    # project name with a space, a null or non-integer thread id — used to be
    # PUT anyway, come back 400, burn the daily `harness-jobs unreachable`
    # ALERT through _jobs_log, and break the loop, so one bad line in the file
    # left every LATER project unseeded and paged about a healthy worker.
    # Skipped here with a line in the client log, and the loop carries on.
    if ! _topic_pair_ok "$key" "$val"; then
      mkdir -p "$JOBS_HARNESS/logs" 2>/dev/null
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [jobs-client] topics-sync skipping unusable entry ${key:-<empty>}=${val:-<null>}" \
        >> "$JOBS_HARNESS/logs/jobs-client.log"
      continue
    fi
    # A failed PUT of a VALID pair is the worker being unreachable or broken.
    # Stop: the rest of the map would fail the same way.
    telegram_topic_set "$key" "$val" >/dev/null 2>&1 || { rc2=1; break; }
  done <<< "$entries"
  return "$rc2"
}

# ledger_page <kind> <limit> [before] [before_key]
#   Raw JSON GET for a single ledger kind, paginated by `before`. Returns the
#   worker's response as-is; callers paginate by the last row's timestamp and,
#   with before_key (BH-2450), its key too. `before` alone skips rows sharing
#   the last row's second; the pair is a cursor that loses nothing.
ledger_page() {
  local kind="${1:-}" limit="${2:-100}" before="${3:-}" before_key="${4:-}" q
  [ -n "$kind" ] || return 1
  case "$limit" in ''|*[!0-9]*) limit=100 ;; esac
  q=$(jq -nr --arg k "$kind" --arg n "$limit" '"kind="+($k|@uri)+"&limit="+($n|@uri)') || return 1
  [ -n "$before" ] && q="$q&before=$(jq -nr --arg b "$before" '($b|@uri)')"
  [ -n "$before_key" ] && q="$q&before_key=$(jq -nr --arg b "$before_key" '($b|@uri)')"
  _jobs_req GET "/api/ledger?$q"
}

# --- BH-1025.0: pr_state_events / pr_attempts client verbs --------------------
# The row twin of state/merge-conductor/pr-state.tsv and attempts.txt. Every
# verb here is TRANSPORT: it makes its request and hands back _jobs_req's rc
# map verbatim (0 on 2xx, 2 on a real 404, 9 on 409, 1 on transport/5xx/no
# secret), exactly like job_ledger_get. None of them consults the flag — the
# gate lives in the CALLER (bin/lib/mc/locks.sh), so a sibling slice can still
# read rows while the conductor's own writes are dark.
#
# The routes child (#1386) answers `{"rows":[…]}` for a list and `{"count":N}`
# for a count. That shape is DEFINED here, because this is what the fixtures
# pin and a client that sniffed any top-level array would pin nothing.

# ONE RESOLUTION PER PROCESS, and one outage is enough (the lt_on / _LT_DOWN
# precedent in bin/lib/ledger-twin.sh). flag_active reconciles the file from the
# DB on every call, and the caller sits in a per-PR loop, so an uncached read
# would be one request per PR for an answer that cannot change inside a tick.
_PR_ROWS_ON=""
_PR_ROWS_DOWN=0
pr_rows_on() { # rc 0 when the pr-state-rows flag is up; rc 1 after pr_rows_trip
  [ "$_PR_ROWS_DOWN" = 1 ] && return 1
  if [ -z "$_PR_ROWS_ON" ]; then
    if declare -F flag_active >/dev/null 2>&1; then
      if flag_active pr-state-rows; then _PR_ROWS_ON=1; else _PR_ROWS_ON=0; fi
    elif [ -f "$JOBS_HARNESS/flags/pr-state-rows" ]; then
      _PR_ROWS_ON=1
    else
      _PR_ROWS_ON=0
    fi
  fi
  [ "$_PR_ROWS_ON" = 1 ]
}
# Latch the library off for the rest of the process. It MUST be called from the
# caller's own shell — a `$( )` subshell would set it and die with it, which is
# the bug bin/lib/ledger-twin.sh's _LT_DOWN comment exists to warn about.
pr_rows_trip() { _PR_ROWS_DOWN=1; }

# pr_state_event_put <repo> <number> <state> <since> <head> <reviewed> <reason> <url> <alerted>
#   One sighting of one PR. `alerted` defaults to '-' rather than to empty,
#   because the dedupe index is a plain column list and a NULL never collides.
pr_state_event_put() {
  local repo="${1:-}" num="${2:-}" state="${3:-}" since="${4:-}" head="${5:-}" \
        reviewed="${6:-}" reason="${7:-}" url="${8:-}" alerted="${9:-}" body
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$state" ] && [ -n "$since" ] || return 1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$alerted" ] || alerted='-'
  body=$(jq -nc --arg r "$repo" --argjson n "$num" --arg s "$state" --arg si "$since" \
    --arg h "$head" --arg rv "$reviewed" --arg rs "$reason" --arg u "$url" \
    --arg al "$alerted" --arg a "$JOBS_BOX" \
    '{repo:$r,number:$n,state:$s,since:$si,head:$h,reviewed:$rv,reason:$rs,url:$u,alerted:$al,actor:$a}' \
    2>/dev/null) || return 1
  _jobs_req POST /api/pr-state-events "$body" >/dev/null
}

# pr_state_page <limit> [before-id] [repo]
#   The CURRENT state of each PR (the pr_state view), raw JSON, paginated by
#   row id. rc 2 when the view answered no rows — which is a real answer, not
#   an outage, so a caller can tell "nothing to show" from "ask again later".
pr_state_page() {
  local limit="${1:-100}" before="${2:-}" repo="${3:-}" q resp rc n
  case "$limit" in ''|*[!0-9]*) limit=100 ;; esac
  q=$(jq -nr --arg n "$limit" '"limit="+($n|@uri)') || return 1
  [ -n "$before" ] && q="$q&before=$(jq -nr --arg b "$before" '($b|@uri)')"
  [ -n "$repo" ] && q="$q&repo=$(jq -nr --arg r "$repo" '($r|@uri)')"
  resp=$(_jobs_req GET "/api/pr-state?$q"); rc=$?
  case "$rc" in 0) : ;; 2) return 2 ;; *) return 1 ;; esac
  printf '%s' "$resp"
  n=$(printf '%s' "$resp" | jq -r '(.rows // []) | length' 2>/dev/null)
  case "$n" in ''|0) return 2 ;; esac
  return 0
}

# pr_state_events_page <state> <since-iso> <limit>
#   The EVENT log for one state, newest first, as TSV:
#     repo number state since head reviewed reason url alerted at
#   The ordering is done here, client-side, so it does not depend on a route
#   that does not exist yet. An absent or empty field prints '-', never blank:
#   a blank column in a TSV slides every field after it one place left.
pr_state_events_page() {
  local state="${1:-}" since="${2:-}" limit="${3:-100}" q resp rc out
  [ -n "$state" ] && [ -n "$since" ] || return 1
  case "$limit" in ''|*[!0-9]*) limit=100 ;; esac
  q=$(jq -nr --arg s "$state" --arg si "$since" --arg n "$limit" \
    '"state="+($s|@uri)+"&since="+($si|@uri)+"&limit="+($n|@uri)') || return 1
  resp=$(_jobs_req GET "/api/pr-state-events?$q"); rc=$?
  case "$rc" in 0) : ;; 2) return 2 ;; *) return 1 ;; esac
  out=$(printf '%s' "$resp" | jq -r '
    (.rows // []) | sort_by(.id) | reverse | .[]
    | [ .repo, .number, .state, .since, .head, .reviewed, .reason, .url, .alerted, .at ]
    | map(if . == null or . == "" then "-" else . end) | @tsv' 2>/dev/null) || return 1
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# pr_attempt_put <repo> <number> <kind> <sha> — "we have already tried this".
pr_attempt_put() {
  local repo="${1:-}" num="${2:-}" kind="${3:-}" sha="${4:-}" body
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$kind" ] && [ -n "$sha" ] || return 1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  body=$(jq -nc --arg r "$repo" --argjson n "$num" --arg k "$kind" --arg s "$sha" --arg a "$JOBS_BOX" \
    '{repo:$r,number:$n,kind:$k,sha:$s,actor:$a}' 2>/dev/null) || return 1
  _jobs_req PUT /api/pr-attempts "$body" >/dev/null
}

# pr_attempt_has <repo> <number> <kind> <sha>
#   rc 0 the row is there | rc 2 a real miss | rc 1 the worker is unusable.
#   Prints nothing: the answer IS the rc, and a caller that read stdout could
#   not tell an outage from a miss.
pr_attempt_has() {
  local repo="${1:-}" num="${2:-}" kind="${3:-}" sha="${4:-}" q
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$kind" ] && [ -n "$sha" ] || return 1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  q=$(jq -nr --arg r "$repo" --arg n "$num" --arg k "$kind" --arg s "$sha" \
    '"repo="+($r|@uri)+"&number="+($n|@uri)+"&kind="+($k|@uri)+"&sha="+($s|@uri)') || return 1
  _jobs_req GET "/api/pr-attempts?$q" >/dev/null
}

# pr_attempt_del <repo> <number> <kind> <sha> — FORGET one attempt. The row half
#   of mc_attempt_clear, which is the ONE deliberate eraser in this ledger: the
#   stuck detector clears a line so the next tick may spawn a fresh rebase. A
#   file-only erase plus a surviving row is not a forget at all — the next
#   mc_attempt_has reads the row and warms the line straight back, and the PR is
#   skipped for ever. So the row goes too.
#   rc 0 it is gone | rc 2 there was none (also a forget) | rc 1 unusable, which
#   the caller must NOT read as "forgotten".
pr_attempt_del() {
  local repo="${1:-}" num="${2:-}" kind="${3:-}" sha="${4:-}" q
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$kind" ] && [ -n "$sha" ] || return 1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  q=$(jq -nr --arg r "$repo" --arg n "$num" --arg k "$kind" --arg s "$sha" \
    '"repo="+($r|@uri)+"&number="+($n|@uri)+"&kind="+($k|@uri)+"&sha="+($s|@uri)') || return 1
  _jobs_req DELETE "/api/pr-attempts?$q" >/dev/null
}

# pr_attempt_count <repo> <number> <kind> — how many attempts of this kind this
#   PR has had, across every head. A 404 is a MEASURED zero and prints 0 at
#   rc 2; an outage prints NOTHING at rc 1, so no caller can read a blink as a
#   count it can act on (D11).
pr_attempt_count() {
  local repo="${1:-}" num="${2:-}" kind="${3:-}" q resp rc n
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$kind" ] || return 1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  q=$(jq -nr --arg r "$repo" --arg n "$num" --arg k "$kind" \
    '"repo="+($r|@uri)+"&number="+($n|@uri)+"&kind="+($k|@uri)') || return 1
  resp=$(_jobs_req GET "/api/pr-attempts?$q"); rc=$?
  case "$rc" in
    0) n=$(printf '%s' "$resp" | jq -r '.count // 0' 2>/dev/null)
       case "$n" in ''|*[!0-9]*) n=0 ;; esac
       printf '%s' "$n"; return 0 ;;
    2) printf '0'; return 2 ;;
    *) return 1 ;;
  esac
}

# pr_attempt_list <repo> <number> <kind> — the `sha` of every attempt row of
#   this kind this PR has, one per line (BH-1564: the head-lag record is a set
#   of `headlag` rows whose sha is "<tip> <fact> [n]", read back in one GET).
#   rc 0 and the lines | rc 2 a MEASURED none (a 200 with zero rows) | rc 1 an
#   outage, printing NOTHING, so no caller can read a blink as "no rows".
#   An EMPTY <kind> lists every kind the PR has (BH-2357: read_memo_fp totals
#   one head across kinds in one GET); the route leaves `kind` out of its WHERE.
pr_attempt_list() {
  local repo="${1:-}" num="${2:-}" kind="${3:-}" q resp rc out
  [ -n "$repo" ] && [ -n "$num" ] || return 1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  q=$(jq -nr --arg r "$repo" --arg n "$num" --arg k "$kind" \
    '"repo="+($r|@uri)+"&number="+($n|@uri)+(if $k == "" then "" else "&kind="+($k|@uri) end)') || return 1
  resp=$(_jobs_req GET "/api/pr-attempts?$q"); rc=$?
  [ "$rc" = 0 ] || return 1
  out=$(printf '%s' "$resp" | jq -r '.attempts | if type == "array" then .[] | .sha // empty else error end' 2>/dev/null) \
    || return 1
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# --- BH-4953 (BH-4950.0): PR gate facts and the needs-review worklist ----------
# Gate facts are `state='gate'` rows in pr_state_events (worker/jobs/src/lib/
# pr-gate.js). Unlike the verbs above these are NOT behind the `pr-state-rows`
# flag: that flag governs the conductor's twin of pr-state.tsv, not this.

# pr_gate_event_put <repo> <number> <source> <reason> [field=value ...]
#   One gate fact. <source> is the dedupe key (a delivery id or <field>@<sha>),
#   so a replay is a duplicate, not a second row. Each field must be one of the
#   twelve gate fields; an unknown name or a non-0/1 int is rc 1 and NOTHING is
#   sent, so a typo never becomes a silent no-op. rc is _jobs_req's.
pr_gate_event_put() {
  local repo="${1:-}" num="${2:-}" src="${3:-}" reason="${4:-}" kv f v body
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$src" ] && [ -n "$reason" ] || return 1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  shift 4
  body=$(jq -nc --arg r "$repo" --argjson n "$num" --arg s "$src" --arg rs "$reason" --arg a "$JOBS_BOX" \
    '{repo:$r,number:$n,state:"gate",since:$s,reason:$rs,actor:$a}' 2>/dev/null) || return 1
  for kv in "$@"; do
    f="${kv%%=*}"; v="${kv#*=}"
    [ "$f" != "$kv" ] || return 1
    case "$f" in
      draft|closed|held|hotfix)
        case "$v" in 0|1) ;; *) return 1 ;; esac
        body=$(printf '%s' "$body" | jq -c --arg f "$f" --argjson v "$v" '.[$f]=$v' 2>/dev/null) || return 1 ;;
      head|ci_green_sha|builder_approved_sha|lead_verdict_sha|lead_verdict_word|reviewing_sha|review_failed_sha|nudged_sha)
        body=$(printf '%s' "$body" | jq -c --arg f "$f" --arg v "$v" '.[$f]=$v' 2>/dev/null) || return 1 ;;
      *) return 1 ;;
    esac
  done
  _jobs_req POST /api/pr-state-events "$body" >/dev/null
}

# pr_gate_facts <repo> — the folded facts per PR, raw JSON. rc 0 on 2xx, 1
#   otherwise (a 404 here is an old worker without the route, not "no facts").
pr_gate_facts() {
  local repo="${1:-}" q resp
  [ -n "$repo" ] || return 1
  q=$(jq -nr --arg r "$repo" '"repo="+($r|@uri)') || return 1
  resp=$(_jobs_req GET "/api/pr-state/gate?$q") || return 1
  printf '%s' "$resp"
}

# pr_needs_review <repo> — the lead-review worklist as TSV:
#     number head url hotfix nudged approved_at
#   rc 0 rows | rc 2 a MEASURED none (a 200 with `rows: []`) | rc 1 an outage,
#   printing NOTHING. The route never 404s, so a 404 is an old worker and reads
#   as rc 1, never as "nothing to review" (D11). An empty field prints '-'.
pr_needs_review() {
  local repo="${1:-}" q resp n out
  [ -n "$repo" ] || return 1
  q=$(jq -nr --arg r "$repo" '"repo="+($r|@uri)') || return 1
  resp=$(_jobs_req GET "/api/pr-state/needs-review?$q") || return 1
  n=$(printf '%s' "$resp" | jq -er '.rows | if type == "array" then length else error end' 2>/dev/null) \
    || return 1
  [ "$n" = 0 ] && return 2
  out=$(printf '%s' "$resp" | jq -r '.rows[]
    | [ .number, .head, .url, .hotfix, .nudged, .approved_at ]
    | map(if . == null or . == "" then "-" else tostring end) | @tsv' 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

# merge_ledger_has <pr-url>
#   rc 0 when either ledger kind says this PR merged | rc 2 when both are real
#   misses | rc 1 when EITHER read was an outage. Never "not merged" on a
#   blink: the caller acts on rc 2 by doing the work again, and doing a merge
#   again is not free. A row that exists with some other status (`closed`, from
#   bin/reconcile-prs.sh) is a real miss, not an outage.
merge_ledger_has() {
  local url="${1:-}" st rc1 rc2
  [ -n "$url" ] || return 1
  st=$(job_ledger_get merge "$url"); rc1=$?
  [ "$rc1" -eq 0 ] && [ "$st" = merged ] && return 0
  st=$(job_ledger_get pr_merged "$url"); rc2=$?
  [ "$rc2" -eq 0 ] && [ "$st" = merged ] && return 0
  { [ "$rc1" -eq 1 ] || [ "$rc2" -eq 1 ]; } && return 1
  return 2
}

# --- Phase 3: heartbeats ------------------------------------------------------
# job_heartbeat <job_id> [note]
#   One POST, no body worth speaking of. THE POINT IS DETECTION, NOT PREVENTION:
#   rc=137 is the OS ending the process and nothing running inside it gets a say,
#   so the only thing that can be fixed is the silence afterwards. A row whose
#   last beat is 40 minutes old is a killed run; a row with no row at all is
#   what we had on 2026-08-27 17:48Z, when two detached sessions died blank.
job_heartbeat() {
  local id="${1:-}" note="${2:-}" body
  [ -n "$id" ] || return 1
  body=$(jq -nc --arg b "$JOBS_BOX" --arg n "$note" \
    '{box:$b} + (if $n == "" then {} else {note:$n} end)' 2>/dev/null) || return 1
  _jobs_req POST "/api/jobs/$id/heartbeat" "$body" >/dev/null
}

# job_beat_start <job_id> [interval-secs] -> prints the loop's pid (or nothing)
#   Cost is per WALL-CLOCK MINUTE of a claimed row, never per token: one call
#   every ~150s for as long as the stage runs, whatever it is spending.
#
#   The loop watches the pid that started it and exits when that process is
#   gone. Without that, a SIGKILLed parent would leave an immortal beater
#   keeping a dead job's row fresh forever — a watchdog that can be lied to by
#   the very failure it exists to catch.
#
#   IT MUST NOT CARRY THE CALLER'S LOCKS (2026-09-12). A fork inherits every
#   open descriptor, and in bin/run-build.sh those include the box's slot flock
#   (fd 8+) and the per-key flock (fd 7). job_beat_stop kills the LOOP — but the
#   loop's `sleep` was a foreground child, so it was orphaned still holding
#   them, and an flock lives exactly as long as a descriptor holding it. The
#   slot therefore stayed locked for the rest of the interval (150s by default)
#   after the build had finished, and the next ticket was answered
#   "BUILD_DEFERRED all N slots busy" — a refusal that lands BEFORE the DB
#   claim, so nothing in the jobs ledger explains it (a live project-5 pool
#   machine, ALERTS.log 2026-09-12 22:56Z; same shape as the flyctl agent that
#   inherited fd 8 in bin/fly-pool.sh). The beater needs no descriptor above
#   stderr, so it sheds every one of them before its first sleep.
_job_beat_shed_fds() { # close every inherited fd >= 3 in the CURRENT shell
  local fd list
  # /dev/fd is the portable enumeration — a symlink to /proc/self/fd on Linux,
  # the real thing on macOS. The fixed sweep after it covers an image where
  # neither is readable; closing an fd that was never open is a silent no-op,
  # so listing more than exist costs nothing.
  list=$(ls /dev/fd 2>/dev/null || ls "/proc/$$/fd" 2>/dev/null)
  for fd in $list 3 4 5 6 7 8 9 10 11 12; do
    case "$fd" in ''|*[!0-9]*) continue ;; esac
    # >= 3 never touches stdin/stdout/stderr; < 200 leaves bash's own script
    # descriptor (255) alone, which is not ours to close.
    { [ "$fd" -ge 3 ] && [ "$fd" -lt 200 ]; } || continue
    eval "exec $fd>&-" 2>/dev/null || true
  done
  return 0
}
job_beat_start() {
  local id="${1:-}" iv="${2:-${JOBS_BEAT_SECS:-150}}" me=$$
  [ -n "$id" ] || return 1
  ( _job_beat_shed_fds
    # The sleep runs in the BACKGROUND and is waited on, so the TERM from
    # job_beat_stop takes it down with the loop. bash runs a trap the moment a
    # signal arrives during `wait`; while a FOREGROUND child ran it would not,
    # which is how the orphan was made in the first place.
    _sp=""
    trap '[ -n "$_sp" ] && kill "$_sp" 2>/dev/null; exit 0' TERM
    while kill -0 "$me" 2>/dev/null; do
      sleep "$iv" & _sp=$!
      wait "$_sp" 2>/dev/null
      kill -0 "$me" 2>/dev/null || break
      job_heartbeat "$id" "beat" >/dev/null 2>&1 || true
    done
    [ -n "$_sp" ] && kill "$_sp" 2>/dev/null
    exit 0 ) >/dev/null 2>&1 &
  printf '%s' "$!"
}

# job_beat_stop [pid] — end a beater started above. Safe to call with nothing.
#   The loop traps TERM and takes its own sleep with it, so the kill below is
#   normally the whole story. The children are read FIRST anyway, because an
#   orphan is reparented the instant the loop dies and no ppid query can find it
#   afterwards — that covers a kill that raced the trap, and a beater started by
#   an older copy of this file that is still sleeping on the caller's locks.
job_beat_stop() {
  local pid="${1:-}" kids kid
  [ -n "$pid" ] || return 0
  kids=$(_job_beat_kids "$pid")
  kill "$pid" 2>/dev/null || true
  for kid in $kids; do kill "$kid" 2>/dev/null || true; done
  return 0
}
_job_beat_kids() { # _job_beat_kids <pid> -> the pids whose parent is <pid>
  pgrep -P "$1" 2>/dev/null && return 0
  ps -A -o pid=,ppid= 2>/dev/null | awk -v p="$1" '$2==p {print $1}'
}

# job_stale <minutes> — open rows whose last sign of life is older than N
# minutes, as TSV: id, project, kind, stage, box, ticket, age_s, budget, spent.
# The threshold is the CALLER'S policy (bin/jobs-watchdog.sh owns it); the clock
# is the worker's, because box clocks drift and a fly builder's is whatever its
# image booted with.
#
# Phase 6 appends an eleventh column, `attempts`, at the END so an older
# bin/jobs-watchdog.sh reading ten fields is unaffected in every field it uses
# (its last `read` variable would simply carry the extra value into the alert's
# last-beat text). The watchdog needs it because "one alert per job" has to
# become "one alert per ATTEMPT" the moment a job can be retried.
job_stale() {
  local mins="${1:-10}" resp
  resp=$(_jobs_req GET "/api/jobs?status=running&limit=500&stale_min=$mins") || return 1
  printf '%s' "$resp" | jq -r '
    .jobs[]? | [ .id, .project, .kind, .stage, .box, (.ticket_id // "-"),
                 ((.activity_age_s // 0) | floor), (.budget_usd // 0), (.spent_usd // 0),
                 (.last_beat_at // "-"), (.attempts // 1) ] | @tsv' 2>/dev/null
}

# job_rows <status> [limit] — every row in <status>, in job_stale's EXACT column
# order, so one `read` line serves both feeds. job_stale answers the watchdog's
# heartbeat question ("running, and quiet for N minutes"); this answers the
# ledger-hygiene one ("what is sitting in <status> at all"), which has no age
# filter because a row parked in queued_for_retry is not stale, it is stuck.
# Read-only; the caller decides what a row in that state means.
job_rows() {
  local status="${1:-running}" limit="${2:-500}" resp
  case "$status" in *[!a-z_]*) return 1 ;; esac
  case "$limit" in ''|*[!0-9]*) limit=500 ;; esac
  resp=$(_jobs_req GET "/api/jobs?status=$status&limit=$limit") || return 1
  printf '%s' "$resp" | jq -r '
    .jobs[]? | [ .id, .project, .kind, .stage, .box, (.ticket_id // "-"),
                 ((.activity_age_s // 0) | floor), (.budget_usd // 0), (.spent_usd // 0),
                 (.last_beat_at // "-"), (.attempts // 1) ] | @tsv' 2>/dev/null
}

# job_builds_running <project> [limit]
#   The running BUILD rows for one project, with the board ticket id their meta
#   carries: `<id>\t<ticket_key>\t<meta_ticket_id>\t<box>\t<kind>`, one per row.
#
# This is the only question that can be answered about a build running on
# ANOTHER box, and the board id is the only thing that makes it answerable:
# `ticket_id` on a jobs row is the build KEY, so two keys for one board ticket
# look like two unrelated builds from the outside. bin/lib/ticket-identity.sh is
# the consumer (BH-866).
#
# rc 1 on transport failure, printing NOTHING — never a partial list a caller
# could read as "nothing else is running" (D12). A guard that says "all clear"
# during an outage is worse than one that says nothing.
job_builds_running() {
  local project="${1:-}" limit="${2:-500}" q resp
  [ -n "$project" ] || return 1
  case "$limit" in ''|*[!0-9]*) limit=500 ;; esac
  q=$(jq -nr --arg p "$project" '"project="+($p|@uri)') || return 1
  resp=$(_jobs_req GET "/api/jobs?$q&status=running&limit=$limit") || return 1
  printf '%s' "$resp" | jq -r '
    .jobs[]? | select((.kind // "") == "build")
    | [ .id, (.ticket_id // "-"),
        (((.meta // {}) | if type == "string" then (fromjson? // {}) else . end
                        | (.ticket_id // "-")) | tostring),
        (.box // "-"), (.kind // "-") ] | @tsv' 2>/dev/null
}

# --- Phase 4: the ONE lane lifecycle -----------------------------------------
# Every enrolled lane does the same four things — claim, heartbeat, spend,
# close — and through phase 3 each caller spelled all four out for itself.
# run-build.sh, run-triage.sh and bin/orc-job.sh each grew their own copy, and
# by the third the copies had already drifted: one exported JOB_ID (so
# agent-call.sh could attribute spend to the row) and one did not; one beat
# immediately and one waited a full 150s interval for its first beat, which is
# the difference between a run killed in its first two minutes being judgeable
# and being a row that never beat. Phase 4 enrolls another six callers, so the
# lifecycle becomes ONE pair of functions here rather than six more
# transcriptions of it.
#
# Fail-open exactly like everything else in this file: with the worker
# unreachable job_lane_open leaves JOB_ID empty, job_lane_close is a no-op, and
# the caller runs precisely as it does today.
JOB_ID="${JOB_ID:-}"
JOB_BEAT="${JOB_BEAT:-}"

# job_lane_open <lane> [key] [kind] [meta-json]
#   lane is <stage>/<project>/<runner> — the SAME string the budget catalog is
#   keyed by, so "this lane has a declared ceiling" and "this lane can claim a
#   row" are one fact with one spelling, not two that can disagree.
#   Sets JOB_ID (EXPORTED, so bin/agent-call.sh posts each stage's spend onto
#   this row without the caller doing anything) and JOB_BEAT.
#     rc 0 -> claimed.
#     rc 9 -> in flight on another box; JOB_INFLIGHT holds "IN_FLIGHT <box>
#             <id>". The CALLER decides, and only a keyed claim can ever see
#             this (the worker does not guard ticketless rows).
#     rc 1 -> no claim. Say nothing, behave exactly as before.
#
#   IT SETS VARIABLES, SO IT MUST NOT BE CALLED IN A COMMAND SUBSTITUTION.
#   `CLAIM=$(job_lane_open ...)` runs it in a SUBSHELL, where JOB_ID and
#   JOB_BEAT are set and then thrown away with the subshell — the claim opens,
#   the beater is orphaned, and the row is never closed, which is the exact
#   silent-row failure this layer exists to remove. That is why the 409 detail
#   lands in JOB_INFLIGHT instead of on stdout: there is no reason left to
#   capture this function's output.
JOB_INFLIGHT=""
job_lane_open() {
  local lane="${1:-}" key="${2:-}" kind="${3:-}" meta="${4:-}" stage project claim rc
  JOB_INFLIGHT=""; JOB_REFUSED=""
  [ -n "$lane" ] || return 1
  stage="${lane%%/*}"
  project="${lane#*/}"; project="${project%%/*}"
  [ -n "$stage" ] && [ -n "$project" ] || return 1
  # A fleet-wide lane is written <stage>/*/<runner> in the catalog, but "*" is
  # not a project any row should carry — the console groups by it.
  [ "$project" = "*" ] && project=fleet
  claim=$(job_open "$project" "$key" "${kind:-$stage}" "$stage" "$lane" "$meta"); rc=$?
  case "$rc" in
    0) JOB_ID="$claim"; export JOB_ID
       # A first beat NOW, not one interval from now: a run killed inside its
       # first 150s must still be a row that beat once, because "never beat" is
       # the class bin/jobs-watchdog.sh deliberately refuses to judge.
       job_heartbeat "$JOB_ID" start >/dev/null 2>&1 || true
       JOB_BEAT=$(job_beat_start "$JOB_ID") || JOB_BEAT=""
       return 0 ;;
    9) # A refused claim owns NOTHING, so it must not leave a stale JOB_ID
       # behind: bin/agent-call.sh posts spend onto whatever row JOB_ID names,
       # and a caller refused on its second lane would otherwise bill it to the
       # first one's row.
       JOB_ID=""; export JOB_ID; JOB_BEAT=""
       # job_open ran in a command substitution above, so its own JOB_REFUSED
       # went with the subshell — the reason is recovered from what it printed.
       JOB_INFLIGHT="$claim"
       case "$claim" in
         "REFUSED "*) JOB_REFUSED="${claim#REFUSED }"; JOB_REFUSED="${JOB_REFUSED/ :: /: }" ;;
         *)           JOB_REFUSED="$claim" ;;
       esac
       return 9 ;;
    *) JOB_ID=""; JOB_BEAT=""; return 1 ;;
  esac
}

# job_lane_close [rc] [detail] — close the claim with the run's REAL rc.
# Safe with no claim (the fail-open path) and safe to call twice, so it can sit
# in an EXIT trap and still be called explicitly on the normal path.
job_lane_close() {
  local rc="${1:-0}" detail="${2:-}" st
  [ -n "${JOB_BEAT:-}" ] && { job_beat_stop "$JOB_BEAT"; JOB_BEAT=""; }
  [ -n "${JOB_ID:-}" ] || return 0
  case "$rc" in 0) st=done ;; *) st=failed ;; esac
  job_update "$JOB_ID" "status=$st" stage=done >/dev/null 2>&1 || true
  job_event "$JOB_ID" done "$st" "rc=$rc${detail:+ $detail}" >/dev/null 2>&1 || true
  JOB_ID=""; export JOB_ID
  return 0
}

# --- Phase 5: per-PHASE tracking ---------------------------------------------
# A JOB is the claim; a PHASE is what happened inside it. Through phase 4 a
# failed build left one row saying "failed" and no record of WHICH stage died,
# on which runner, having spent what — so recovery started by reading a build
# dir on whichever box happened to still have it.
#
# COORDINATION STAYS PER JOB. Opening a phase never guards, never 409s and never
# waits: there is exactly one claim per job and these are child records of it.
# A phase that could block a stage would turn one decision point into three, and
# a network blip between plan and execute would strand a build that is already
# paid for. Every helper here is fail-open like the rest of this file — with the
# worker unreachable JOB_PHASE_ID stays empty, every close is a no-op, and the
# stage runs exactly as it does today with one line in logs/jobs-client.log.
JOB_PHASE_ID="${JOB_PHASE_ID:-}"

# job_phase_open <phase> [runner] [model] [note] [job_id]
#   Sets JOB_PHASE_ID (and prints NOTHING, for the same reason job_lane_open
#   prints nothing: a helper whose result is a VARIABLE must not invite
#   `X=$(job_phase_open ...)`, which runs it in a subshell and throws the id
#   away — leaving a phase row open forever, which is the exact silence this
#   table exists to remove).
#   Defaults to the ambient JOB_ID, which run-build.sh exports, so bin/agent-call.sh
#   opens a phase on the right claim without being told about it.
job_phase_open() {
  local phase="${1:-}" runner="${2:-}" model="${3:-}" note="${4:-}" job="${5:-${JOB_ID:-}}" body resp id
  JOB_PHASE_ID=""
  [ -n "$phase" ] && [ -n "$job" ] || return 1
  body=$(jq -nc --arg p "$phase" --arg r "$runner" --arg m "$model" --arg n "$note" \
    '{phase:$p}
     + (if $r == "" then {} else {runner:$r} end)
     + (if $m == "" then {} else {model:$m} end)
     + (if $n == "" then {} else {note:$n} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST "/api/jobs/$job/phases" "$body") || return 1
  id=$(printf '%s' "$resp" | jq -r '.phase.id // empty' 2>/dev/null)
  case "$id" in ''|*[!0-9]*) return 1 ;; esac
  JOB_PHASE_ID="$id"
  return 0
}

# job_phase_close [rc] [spend_usd] [note] [phase_id]
#   rc 0 -> the phase is `done`; ANY other rc -> `failed`, WITH THE REAL RC
#   STORED. A stage killed at 137 or budget-stopped says so on its own row, so
#   "which phase died and how" is one query instead of a hunt through one box's
#   ALERTS tail. Non-integer rc is dropped rather than coerced — an invented 1
#   would read as a vendor error the stage never had.
job_phase_close() {
  local rc="${1:-0}" spend="${2:-}" note="${3:-}" pid="${4:-${JOB_PHASE_ID:-}}" st body ret
  [ -n "$pid" ] || return 1
  case "$rc" in 0) st=done ;; *) st=failed ;; esac
  body=$(jq -nc --arg s "$st" --arg r "$rc" --arg u "$spend" --arg n "$note" \
    '{status:$s}
     + (if ($r|test("^-?[0-9]+$")) then {rc:($r|tonumber)} else {} end)
     + (if ($u|test("^-?[0-9]+([.][0-9]+)?$")) then {spend_usd:($u|tonumber)} else {} end)
     + (if $n == "" then {} else {note:$n} end)' 2>/dev/null) || return 1
  local resp; resp=$(_jobs_req PATCH "/api/phases/$pid" "$body"); ret=$?
  # rc 9 here is a PHASE-7 refusal, not an outage: either an outcome contract
  # the stage did not satisfy (the worker has already recorded the phase as
  # contract_unmet with the reason on it — nothing is left open) or an illegal
  # transition. Log it so a human reading jobs-client.log sees WHY a `done`
  # became something else, and hand the rc back; every caller in this fleet
  # closes a phase best-effort, so this never changes what a stage returns.
  if [ "$ret" -eq 9 ]; then
    _jobs_log "phase $pid close refused: $(printf '%s' "$resp" | jq -r '.reason // .error // "refused"' 2>/dev/null)"
  fi
  [ "$pid" = "${JOB_PHASE_ID:-}" ] && JOB_PHASE_ID=""
  return "$ret"
}

# job_phase_close_open <job_id> <status> [rc] [note]
#   Close EVERY phase still marked running on a job, and print their names.
#   Two callers, both of them cleaning up after a death rather than causing one:
#   run-build.sh's EXIT hook (a stage whose own process was killed never got to
#   close its row) and bin/jobs-watchdog.sh (a job it has just judged orphaned).
#   Printing is safe here — there is no state to lose — and it is how the
#   watchdog names the phase in its alert without a second round trip.
job_phase_close_open() {
  local job="${1:-}" status="${2:-failed}" rc="${3:-}" note="${4:-}" body resp
  [ -n "$job" ] || return 1
  body=$(jq -nc --arg s "$status" --arg r "$rc" --arg n "$note" \
    '{status:$s}
     + (if ($r|test("^-?[0-9]+$")) then {rc:($r|tonumber)} else {} end)
     + (if $n == "" then {} else {note:$n} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST "/api/jobs/$job/phases/close" "$body"); local ret=$?
  # rc 9 = a phase-7 contract breach. The phases WERE closed (as contract_unmet,
  # with the reason on each row), so the names still exist and the caller still
  # wants them for its alert — returning nothing here would turn "closed, but
  # not as done" into "closed nothing", which is the silence phase 5 removed.
  case "$ret" in
    0) ;;
    9) _jobs_log "phase close on $job landed contract_unmet: $(printf '%s' "$resp" | jq -r '[.breaches[]?.reason] | join("; ")' 2>/dev/null)" ;;
    *) return 1 ;;
  esac
  printf '%s' "$resp" | jq -r '[.phases[]?.phase] | join(",")' 2>/dev/null
  return 0
}

# --- Phase 6: rules and retry policy -----------------------------------------
# Phase 3 could see a death and refused to act on it, on purpose: a blind
# relaunch raced the double-build guard. Phase 6 enforces that guard INSIDE the
# claim, so a BOUNDED retry is finally safe to express — but the bound is a DB
# row, per lane, and the decision is the worker's. Nothing in this file decides
# whether work re-runs; it asks, and it prints the answer.
#
# Fail-open like everything else here: with the worker unreachable every helper
# below returns 1 and prints nothing, and bin/jobs-watchdog.sh degrades to the
# phase-5 behaviour it has today.

# job_retry_judge <job_id> [detail] [actor]
#   Ask the DB what happens to a dead claim. ONE call, and it is the DB that
#   decides — the same policy applied to every box, rather than a threshold each
#   caller re-implements. Prints TSV: decision, attempts, max_attempts,
#   next_attempt_at, reason. Decision is exactly one of:
#     queued_for_retry — within policy; the LANE'S OWN NEXT TICK picks it up
#     parked           — the policy ran out of attempts; a human's problem now
#     orphaned         — no policy for the lane (today's behaviour), or a
#                        KILL_STOP/BUDGET_STOP death, which is terminal
#   NOTHING HERE RUNS ANYTHING. The watchdog's hands go as far as writing a
#   status; a queued row is executed by the cron that owns that lane, which is
#   what keeps one claim path and one place where work can start.
job_retry_judge() {
  local id="${1:-}" detail="${2:-}" actor="${3:-$JOBS_BOX}" body resp
  [ -n "$id" ] || return 1
  body=$(jq -nc --arg d "$detail" --arg a "$actor" \
    '{} + (if $d == "" then {} else {detail:$d} end)
        + (if $a == "" then {} else {actor:$a} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST "/api/jobs/$id/retry" "$body") || return 1
  # The decision must be one this caller knows how to act on. A 200 that does
  # not carry one is not an answer — treat it as an outage and let the caller
  # fall back to the phase-5 behaviour rather than print a "?" verdict into an
  # alert, which is how a page comes to say nothing at all.
  printf '%s' "$resp" | jq -e -r '
    if (.decision == "queued_for_retry" or .decision == "parked" or .decision == "orphaned")
    then [ .decision, (.attempts // 0), (.max_attempts // "-"),
           (.next_attempt_at // "-"), (.reason // "") ] | @tsv
    else empty end' 2>/dev/null
}

# job_requeue <job_id> <detail> [max_attempts] [actor]
#   THE OTHER HALF OF job_retry_judge. That one answers "this claim died, what
#   now" for a row that was BEATING. This one answers it for a row that never
#   beat and has simply outlived its class TTL — the SILENT class, which the
#   watchdog has always reported and never acted on, and which left ten triage
#   rows claimed-and-abandoned in 24h on 2026-09-15 with nothing re-offering
#   their tickets.
#   Prints TSV: decision, attempts, max_attempts, reason. Decision is one of:
#     queued_for_retry — requeued; the LANE'S OWN NEXT TICK takes it over
#     parked           — the requeue cap ran out; blocked-resolver owns it
#     held             — deliberately NOT requeued (a ticketless lane tick, or
#                        a ticket that already has another live row). The reason
#                        names which, so the log can say it.
#     already          — the row is no longer running; nothing was written.
#   The CAP is the caller's (catalog/ledger-ttl.conf) and the DECISION is the
#   worker's, same split as every other helper here. Fail-open: no worker, no
#   answer, rc 1, and the watchdog degrades to reporting exactly as today.
job_requeue() {
  local id="${1:-}" detail="${2:-}" max="${3:-3}" actor="${4:-$JOBS_BOX}" body resp
  [ -n "$id" ] || return 1
  case "$max" in ''|*[!0-9]*) max=3 ;; esac
  body=$(jq -nc --arg d "$detail" --arg a "$actor" --argjson m "$max" \
    '{max_attempts:$m}
     + (if $d == "" then {} else {detail:$d} end)
     + (if $a == "" then {} else {actor:$a} end)' 2>/dev/null) || return 1
  resp=$(_jobs_req POST "/api/jobs/$id/requeue" "$body") || return 1
  # Same rule as job_retry_judge: a 200 that does not carry a decision this
  # caller knows how to act on is not an answer, and printing "?" into an alert
  # is how a page comes to say nothing at all.
  printf '%s' "$resp" | jq -e -r '
    if (.decision == "queued_for_retry" or .decision == "parked"
        or .decision == "held" or .decision == "already")
    then [ .decision, (.attempts // 0), (.max_attempts // "-"), (.reason // "") ] | @tsv
    else empty end' 2>/dev/null
}

# job_ticket_abandoned <project> <ticket_key>
#   BH-2406: did an operator ABANDON this ticket? The one question the resume
#   pass, the pool's requeue and the blocked-resolver all ask before they
#   re-offer a ticket. Answered from the ticket's NEWEST BUILD row: a later
#   attempt opens a newer build row, and that un-finalizes the ticket. Only a
#   build row: triage-shard, lead-review, orc-job and migration-autopilot open
#   rows under the same ticket key, and a newer one of those is not an attempt
#   (review of #2481), so it must not un-abandon the ticket.
#   rc 0 -> the newest build row is `abandoned`; prints its job id
#   rc 1 -> it is not (another status, no row at all, or an answer for a
#           different ticket or kind: a worker older than the ticket_id / kind
#           filters answers a newer row, and that must never read as a match)
#   rc 2 -> the worker did not answer or answered something unreadable, AND
#           this box has no cached ABANDON for the key (BH-2505); callers fall
#           back to today's behaviour.
#   THE ABANDON SURVIVES AN OUTAGE ON THE BOX THAT SAW IT (BH-2505). Each good
#   read refreshes $JOBS_HARNESS/state/abandoned-tickets/<project>/<key>, one
#   file holding the job id: an abandoned answer writes it, an empty answer or a
#   newest build row for this ticket in any other status deletes it, and an
#   answer about another ticket or kind leaves it alone. When the worker then
#   fails to answer, a cached key answers rc 0 with that job id. No JOBS_HARNESS
#   (a bare-sourced library; bin/jobs-client.sh always sets it) or a project or
#   key that is not a plain name means no cache at all, read or write.
job_ticket_abandoned() {
  local project="${1:-}" key="${2:-}" q resp cf jid
  [ -n "$project" ] && [ -n "$key" ] || return 2
  cf=$(_jta_cache_path "$project" "$key") || cf=""
  q=$(jq -nr --arg p "$project" --arg k "$key" '"project="+($p|@uri)+"&ticket_id="+($k|@uri)+"&kind=build"') || { _jta_cache_get "$cf"; return; }
  resp=$(_jobs_req GET "/api/jobs?$q&limit=1") || { _jta_cache_get "$cf"; return; }
  printf '%s' "$resp" | jq -e '.jobs | type == "array"' >/dev/null 2>&1 || { _jta_cache_get "$cf"; return; }
  if jid=$(printf '%s' "$resp" | jq -e -r --arg k "$key" '
       .jobs[0] // empty | select(.ticket_id == $k and .kind == "build" and .status == "abandoned") | .id' 2>/dev/null); then
    _jta_cache_put "$cf" "$jid"
    printf '%s\n' "$jid"
    return 0
  fi
  # Authoritative "not abandoned" clears the key; a row about another ticket or
  # kind (an older worker ignoring the filters) says nothing about this one.
  if [ -n "$cf" ] && printf '%s' "$resp" | jq -e --arg k "$key" '
       (.jobs | length) == 0 or (.jobs[0].ticket_id == $k and .jobs[0].kind == "build")' >/dev/null 2>&1; then
    rm -f "$cf" 2>/dev/null || true
  fi
  return 1
}

# _jta_cache_path <project> <key> — the key's cache file, or rc 1 when there is
# no cache: JOBS_HARNESS unset, or a name that could leave the cache dir.
_jta_cache_path() {
  [ -n "${JOBS_HARNESS:-}" ] || return 1
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  printf '%s' "$JOBS_HARNESS/state/abandoned-tickets/$1/$2"
}

# _jta_cache_get <file> — rc 0 and the cached job id, or rc 2 (no file, or one
# that does not hold a plain id).
_jta_cache_get() {
  local jid
  [ -n "${1:-}" ] && [ -f "$1" ] || return 2
  jid=$(head -1 "$1" 2>/dev/null)
  [[ "$jid" =~ ^[A-Za-z0-9._:-]+$ ]] || return 2
  printf '%s\n' "$jid"
}

# _jta_cache_put <file> <job-id> — atomic write; every failure is ignored.
_jta_cache_put() {
  local cf="${1:-}" jid="${2:-}" tmp
  [ -n "$cf" ] && [[ "$jid" =~ ^[A-Za-z0-9._:-]+$ ]] || return 0
  [ "$(head -1 "$cf" 2>/dev/null)" = "$jid" ] && return 0
  mkdir -p "${cf%/*}" 2>/dev/null || return 0
  tmp=$(mktemp "${cf%/*}/.jta.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$jid" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cf" 2>/dev/null; then return 0; fi
  rm -f "$tmp" 2>/dev/null || true
}

# job_rules — print the concurrency rules as TSV
# (scope, selector, kind, max, note, updated_at).
#
# updated_at is the sixth column since BH-1300 and is the ONLY durable trace a
# rule-set leaves: the verb PUTs /api/rules and the worker stamps the row, no
# ledger entry is written anywhere. bin/concurrency-ceiling-watch.sh needs it to
# tell a deliberate lowering from a schema seed resurrecting a cap. Every
# existing reader takes columns 1-5 by index (caps_rule's awk $1..$4,
# fleet-status-push's jq .[0..3] behind select(length >= 4)), so the column is
# additive for them; an older client that prints five is handled as "no
# evidence" by the watch rather than as approval.
job_rules() {
  local resp
  resp=$(_jobs_req GET /api/rules) || return 1
  printf '%s' "$resp" | jq -r '.rules[]? | [.scope,.selector,.kind,.max_concurrent,(.note // ""),(.updated_at // "")] | @tsv' 2>/dev/null
}

# job_rule_set <scope> <selector> <kind> <max> [note]
job_rule_set() {
  local scope="${1:-}" sel="${2:-*}" kind="${3:-*}" max="${4:-}" note="${5:-}" body
  [ -n "$scope" ] && [ -n "$max" ] || return 1
  case "$max" in ''|*[!0-9]*) return 1 ;; esac
  body=$(jq -nc --arg s "$scope" --arg sel "$sel" --arg k "$kind" --argjson m "$max" --arg n "$note" \
    '{scope:$s,selector:$sel,kind:$k,max_concurrent:$m}
     + (if $n == "" then {} else {note:$n} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/rules "$body" >/dev/null
}

# job_rule_unset <scope> [selector] [kind] — remove the row. No row = unlimited
# for that scope; there is no number that spells unlimited (0 is a freeze).
job_rule_unset() {
  local scope="${1:-}" sel="${2:-*}" kind="${3:-*}" body
  [ -n "$scope" ] || return 1
  body=$(jq -nc --arg s "$scope" --arg sel "$sel" --arg k "$kind" '{scope:$s,selector:$sel,kind:$k}' 2>/dev/null) || return 1
  _jobs_req DELETE /api/rules "$body" >/dev/null
}

# job_retry_policy <lane> — the policy that WOULD apply, resolved on the same
# lane ladder the budget catalog uses. Prints TSV (lane, max_attempts,
# backoff_seconds, escalate_allowed) and returns 1 when the lane has no policy,
# which is the normal case and means "detection only, as before phase 6".
job_retry_policy() {
  local lane="${1:-}" resp
  [ -n "$lane" ] || return 1
  resp=$(_jobs_req GET "/api/retry-policies/$lane") || return 1
  printf '%s' "$resp" | jq -e -r '
    if .policy then [.policy.lane,.policy.max_attempts,.policy.backoff_seconds,.policy.escalate_allowed] | @tsv
    else empty end' 2>/dev/null
}

# job_retry_policy_set <lane> <max_attempts> [backoff_seconds] [escalate 0|1] [note]
job_retry_policy_set() {
  local lane="${1:-}" max="${2:-}" backoff="${3:-300}" esc="${4:-0}" note="${5:-}" body
  [ -n "$lane" ] && [ -n "$max" ] || return 1
  case "$max$backoff" in ''|*[!0-9]*) return 1 ;; esac
  body=$(jq -nc --arg l "$lane" --argjson m "$max" --argjson b "$backoff" \
    --argjson e "$([ "$esc" = 1 ] && echo 1 || echo 0)" --arg n "$note" \
    '{lane:$l,max_attempts:$m,backoff_seconds:$b,escalate_allowed:$e}
     + (if $n == "" then {} else {note:$n} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/retry-policies "$body" >/dev/null
}

# --- Phase 7: outcome contracts, artifacts, verdicts, explicit caps ----------
# Phases 5 and 6 recorded that a stage RAN and how it ended. Neither recorded
# what it left BEHIND, so a plan stage that exited 0 having written no plan file
# closed `done` exactly like one that did the work. Phase 7 gives a phase a
# CONTRACT — the artifact it must produce — and gives the artifacts a home the
# whole fleet can read, which is what lets bin/merge-sweep.sh act on a verdict
# recorded by a box it has never met.
#
# Fail-open like everything else in this file: with the worker unreachable every
# helper returns 1, prints nothing, and its caller behaves exactly as it does
# today. With the contract tables EMPTY — which is how they ship — none of this
# changes a single decision.

# job_artifact_put <kind> <ref> [detail-json] [job_id]
#   Record what this job produced. kind is plan_file | pr_url | verdict |
#   merge_sha | evidence | anything an operator writes a contract for. Defaults to the
#   ambient JOB_ID, which run-build.sh exports.
#   An empty ref is refused by the worker on purpose: a blank artifact that
#   satisfies a contract is worse than having no contract at all.
job_artifact_put() {
  local kind="${1:-}" ref="${2:-}" detail="${3:-}" job="${4:-${JOB_ID:-}}" body
  [ -n "$kind" ] && [ -n "$ref" ] && [ -n "$job" ] || return 1
  body=$(jq -nc --arg k "$kind" --arg r "$ref" --arg d "$detail" --arg a "$JOBS_BOX" \
    --arg p "${JOB_PHASE_ID:-}" \
    '{artifact_kind:$k,artifact_ref:$r,actor:$a}
     + (if $d == "" then {} else {detail:$d} end)
     + (if ($p|test("^[0-9]+$")) then {phase_id:($p|tonumber)} else {} end)' 2>/dev/null) || return 1
  _jobs_req PUT "/api/jobs/$job/artifacts" "$body" >/dev/null
}

# job_artifact_feed <kind> <project> [since] [limit]
#   THE REVERSE OF job_artifacts: not "what did this job produce" but "which
#   builds of this project produced an artifact of this kind, anywhere in the
#   fleet". It is what replaces a RESULT arriving by scp — the owning box asks
#   for the results rather than waiting to be handed them.
#
#   TSV: job_id, ref, box, ticket_id, updated_at, detail.
#   `detail` is LAST because it is the only field that can be long; a reader
#   taking the first five columns is unaffected by what rides in it.
#   THE BOX COLUMN IS LOAD-BEARING: a sweep must skip its OWN builds, or it
#   stages a second copy of a close-out it has already posted.
#   rc 1 -> outage; the caller falls back to the directory it has always read.
job_artifact_feed() {
  local kind="${1:-}" project="${2:-}" since="${3:-}" limit="${4:-100}" q resp
  [ -n "$kind" ] && [ -n "$project" ] || return 1
  case "$limit" in ''|*[!0-9]*) limit=100 ;; esac
  q="kind=$kind&project=$project&limit=$limit"
  [ -n "$since" ] && q="$q&since=$since"
  resp=$(_jobs_req GET "/api/artifacts?$q") || return $?
  printf '%s' "$resp" | jq -r '.artifacts[]? | [ .job_id, .artifact_ref, (.box // "-"),
    (.ticket_id // "-"), (.updated_at // "-"), (.detail // "-") ] | @tsv' 2>/dev/null
}

# job_evidence_put <build-dir> [tier] [why-note] [job_id]
#   SDLC item 2: the deterministic evidence for one build, as a row. The render
#   itself belongs to bin/evidence-summary.sh — this only carries it, so the PR
#   body, the file fallback (evidence.md) and the ledger can never disagree
#   about what the build's checks said.
#
#   ONE ROW PER JOB, kind `evidence`, upserted like every other artifact: the
#   ref is the one-line digest (suite/gate verdicts/QA counts/tier), the detail
#   is the same facts as JSON, under the worker's 4000-char detail cap by
#   construction (counts and single-word verdicts, with the free text bounded by
#   the renderer). NO SECRETS: nothing here reads a repo file, an env value or a
#   transcript — only the build dir's own counts and verdict words.
#
#   Fail-open like the rest of this file: a renderer that is missing or errors
#   returns 1 and the caller carries on with its PR exactly as before.
job_evidence_put() {
  local build="${1:-}" tier="${2:-}" note="${3:-}" job="${4:-${JOB_ID:-}}" bin detail ref
  [ -n "$build" ] && [ -d "$build" ] && [ -n "$job" ] || return 1
  bin="$JOBS_HARNESS/bin/evidence-summary.sh"
  [ -x "$bin" ] || return 1
  detail=$("$bin" --json "$build" "$tier" "$note" 2>/dev/null) || return 1
  [ -n "$detail" ] || return 1
  ref=$(printf '%s' "$detail" | jq -r '.digest // ""' 2>/dev/null)
  [ -n "$ref" ] || return 1
  job_artifact_put evidence "$ref" "$detail" "$job"
}

# job_transcript_put <body-file> [stage] [runner] [model] [source] [attempt] [truncated] [redactions] [job_id]
#   Push ONE attempt's rendered, scrubbed conversation to the ledger, so the
#   console can answer "what was this session actually doing".
#
#   THE BODY FILE IS ALREADY RENDERED AND ALREADY SCRUBBED. This helper does not
#   look at it beyond handing it to jq: bin/transcript-push.sh owns the render
#   (bin/transcript-render.sh) and the redaction (bin/transcript-scrub.sh), and
#   putting a second, weaker copy of the secret rules here would be the shape of
#   guard this repo keeps finding inert.
#
#   FAIL-OPEN like everything else in this file, and this one matters more than
#   most: a transcript is a NICE-TO-HAVE side channel on a stage that has
#   already done its work. A push that fails must cost the stage exactly nothing.
#   --rawfile + _jobs_req_file keep a 150KB body off the argv of both jq and
#   curl; see _jobs_req_file for why that is a correctness point, not a tidy-up.
job_transcript_put() {
  local file="${1:-}" stage="${2:-}" runner="${3:-}" model="${4:-}" source="${5:-}" \
        attempt="${6:-1}" truncated="${7:-0}" redactions="${8:-0}" job="${9:-${JOB_ID:-}}"
  [ -n "$file" ] && [ -s "$file" ] && [ -n "$job" ] || return 1
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/jobs-transcript.XXXXXX") || return 1
  jq -n --rawfile b "$file" --arg s "$stage" --arg r "$runner" --arg m "$model" \
    --arg src "$source" --arg a "$JOBS_BOX" --arg p "${JOB_PHASE_ID:-}" \
    --arg n "$attempt" --arg t "$truncated" --arg x "$redactions" \
    '{body:$b,actor:$a}
     + (if $s == "" then {} else {stage:$s} end)
     + (if $r == "" then {} else {runner:$r} end)
     + (if $m == "" then {} else {model:$m} end)
     + (if $src == "" then {} else {source:$src} end)
     + (if ($p|test("^[0-9]+$")) then {phase_id:($p|tonumber)} else {} end)
     + (if ($n|test("^[0-9]+$")) then {attempt:($n|tonumber)} else {} end)
     + (if ($t|test("^[0-9]+$")) then {truncated:($t|tonumber)} else {} end)
     + (if ($x|test("^[0-9]+$")) then {redactions:($x|tonumber)} else {} end)' \
    > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  _jobs_req_file POST "/api/jobs/$job/transcript" "$tmp" >/dev/null
  local ret=$?
  rm -f "$tmp"
  return "$ret"
}

# job_transcripts [job_id] — TSV of phase_id, attempt, stage, runner, source,
#   bytes for one job. The INDEX, never the bodies: this is for a human at a
#   terminal asking what is on file, and printing four 150KB transcripts into a
#   shell is not that.
job_transcripts() {
  local job="${1:-${JOB_ID:-}}" resp
  [ -n "$job" ] || return 1
  resp=$(_jobs_req GET "/api/jobs/$job/transcripts") || return 1
  printf '%s' "$resp" | jq -r '.transcripts[]? | [.phase_id,.attempt,(.stage//"-"),(.runner//"-"),(.source//"-"),(.bytes//0)] | @tsv' 2>/dev/null
}

# job_transcript_get <job_id> [phase_id=0] [attempt=1] — ONE body, raw on stdout.
#   The counterpart to job_transcript_put, and BH-531 is why it exists: a
#   watcher box has to pull a blocked build's plan.md back out of the ledger and
#   write it to disk beside the staged RESULT. So stdout is the BODY and nothing
#   else — the caller redirects it straight into the file it is staging.
#     rc 0 -> the body is on stdout, byte-for-byte as it was stored, and
#             JOBS_TRANSCRIPT_TRUNCATED says whether the ledger kept only its tail
#     rc 1 -> no such row (the worker's 404), an outage, or a stored body that is
#             empty. All three print NOTHING: a box that wrote an error page into
#             plan.md and quoted it to a client would be worse than one that
#             wrote nothing at all, so "no body" has exactly one shape here.
JOBS_TRANSCRIPT_TRUNCATED=0
job_transcript_get() {
  local job="${1:-}" p="${2:-0}" a="${3:-1}" resp body
  JOBS_TRANSCRIPT_TRUNCATED=0
  [ -n "$job" ] || return 1
  # Digits only, and REFUSED rather than coerced to a default: both of these go
  # straight into a query string, and a caller that handed over junk asked for a
  # row it cannot name — answering with (0,1) would hand it somebody else's.
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  case "$a" in ''|*[!0-9]*) return 1 ;; esac
  resp=$(_jobs_req GET "/api/jobs/$job/transcript?phase_id=$p&attempt=$a") || return 1
  # jq -j, plus the X trick, because the body is a FILE: `$(…)` eats trailing
  # newlines and `jq -r` adds one, and between them a staged plan.md would not
  # be what the builder wrote.
  body=$(printf '%s' "$resp" | jq -j '.transcript.body // empty' 2>/dev/null; printf X)
  body="${body%X}"
  [ -n "$body" ] || return 1
  case "$(printf '%s' "$resp" | jq -r '.transcript.truncated // 0' 2>/dev/null)" in
    1) JOBS_TRANSCRIPT_TRUNCATED=1 ;;
  esac
  printf '%s' "$body"
}

# job_transcript_get_source <job_id> <source> — the same body, addressed by KIND.
#   A reader of a blocking artifact knows what it wants (plan_md) and not which
#   slot it landed on, so the index answers that first. The index is ordered
#   phase_id ASC, attempt ASC and a re-push upserts its own slot, so the last
#   match is the newest row of that source.
job_transcript_get_source() {
  local job="${1:-}" src="${2:-}" slot p a
  JOBS_TRANSCRIPT_TRUNCATED=0
  [ -n "$job" ] && [ -n "$src" ] || return 1
  slot=$(job_transcripts "$job" \
    | awk -F'\t' -v s="$src" '$5==s{p=$1;a=$2;f=1} END{if(!f)exit 1; print p"\t"a}') || return 1
  [ -n "$slot" ] || return 1
  IFS="$(printf '\t')" read -r p a <<< "$slot"
  job_transcript_get "$job" "$p" "$a"
}

# job_artifacts [job_id] — TSV of kind, ref, phase_id for one job.
job_artifacts() {
  local job="${1:-${JOB_ID:-}}" resp
  [ -n "$job" ] || return 1
  resp=$(_jobs_req GET "/api/jobs/$job/artifacts") || return 1
  printf '%s' "$resp" | jq -r '.artifacts[]? | [.artifact_kind,.artifact_ref,(.phase_id // "-")] | @tsv' 2>/dev/null
}

# job_artifact_detail <kind> [job_id] — the raw `detail` of one artifact kind
# (BH-2532.0). Printed verbatim with printf '%s': a detail is often JSON, and
# the caller parses it, not this reader.
#   rc 0 -> printed the detail
#   rc 3 -> the worker answered and there is no such row, or it has no detail
#           (an unknown job is 200 with `artifacts: []`; a 404 reads the same)
#   rc 1 -> the worker could not be asked, or its answer did not parse. Never
#           read as "absent": a body we could not read says nothing about rows.
job_artifact_detail() {
  local kind="${1:-}" job="${2:-${JOB_ID:-}}" resp rc detail
  [ -n "$kind" ] && [ -n "$job" ] || return 1
  resp=$(_jobs_req GET "/api/jobs/$job/artifacts"); rc=$?
  case "$rc" in
    0) ;;
    2) return 3 ;;
    *) return 1 ;;
  esac
  # The X trick keeps a detail's trailing newlines, which `$(…)` would eat.
  detail=$(printf '%s' "$resp" | jq -j --arg k "$kind" \
    '[.artifacts[]? | select(.artifact_kind == $k) | .detail // ""] | first // ""' 2>/dev/null) \
    || return 1
  [ -n "$detail" ] || return 3
  printf '%s' "$detail"
}

# job_verdict <pr-url>
#   The build verdict for a PR, from the ledger rather than from a build record
#   on one box's disk. Prints TSV: verdict, tier, provenance, merge_sha, job_id,
#   reviewed_sha (SDLC item 1 — the head the approval is bound to; "-" when the
#   row predates it, which every reader treats as "no claim", never as a
#   mismatch). New fields are APPENDED, so a reader of the first five is unchanged.
#     rc 0 -> the ledger holds a verdict for this PR
#     rc 2 -> worker reachable, NO job recorded this PR. A REAL answer: the
#             caller falls back to scraping its local build record, which is
#             exactly what it did before phase 7.
#     rc 1 -> outage. Same fallback, and never "no verdict, so do not merge" —
#             the local record is the same evidence, so degrading to it is
#             byte-identical to today rather than a starved PR.
#
#   A PROVISIONAL ROW IS rc 2 (BH-858). bin/run-build.sh now records the verdict
#   when the REVIEW settles — minutes before the PR exists, and several demoters
#   before the tier is final — and that row carries `settled:false`. Answering it
#   here would let a merge lane act on a tier QA had not judged yet, so it reads
#   as "the ledger has nothing to say about this one", which is the answer every
#   caller already handles by scraping its build record. ABSENT FIELD, absent
#   `.artifacts`, unparseable detail -> settled: every row already in the ledger
#   keeps its meaning, which is what makes the change additive.
job_verdict() {
  local pr="${1:-}" resp rc
  [ -n "$pr" ] || return 1
  local q; q=$(jq -nr --arg v "$pr" '"pr="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/verdict?$q"); rc=$?
  case "$rc" in
    2) return 2 ;;
    0) ;;
    *) return 1 ;;
  esac
  # Read out of the .artifacts[] already in this response — the same place
  # job_verdict_headbound reads from, so no second call and no worker change.
  [ "$(printf '%s' "$resp" | jq -r '
    ([.artifacts[]? | select(.artifact_kind == "verdict") | .detail // ""] | first // "")
    | if . == "" then "settled"
      else (try (fromjson | (if .settled == false then "provisional" else "settled" end))
            catch "settled") end' 2>/dev/null)" = provisional ] && return 2
  local row
  row=$(printf '%s' "$resp" | jq -r '
    if .verdict then [ .verdict, (.tier // "-"), (.provenance // "-"),
                       (.merge_sha // "-"), (.job_id // "-"),
                       (if (.reviewed_sha // "") == "" then "-" else .reviewed_sha end) ] | @tsv
    else empty end' 2>/dev/null)
  # A job that recorded its PR but not yet its verdict is the SAME real answer
  # as no job at all — rc 2, "the ledger has nothing to say about this one" —
  # and the caller scrapes its build record exactly as it did before phase 7.
  # Returning 0 with a blank line here would hand a merge gate an empty verdict.
  [ -n "$row" ] || return 2
  printf '%s' "$row"
}

# job_verdict_headbound <pr-url>
#   The head-bound gate's one-word answer for this PR — n/a | reapproved |
#   blocked | no-verdict — or nothing when the ledger has no row, no verdict
#   artifact, or a row written before the field existed. Silence is always "no
#   claim", never "blocked": a reader that guessed would park a PR nobody
#   refused.
#
#   A SEPARATE CALL RATHER THAN A SEVENTH FIELD ON job_verdict. That TSV is read
#   positionally by bin/merge-sweep.sh, bin/merge-queue.sh and the conductor
#   lib; appending a column would silently glue it onto whichever variable those
#   callers listed last. Additive is the only safe shape.
#
#   It reads the verdict artifact's own detail JSON out of the /api/verdict
#   response rather than a flattened top-level field, so it works against the
#   worker exactly as deployed today.
job_verdict_headbound() {
  local pr="${1:-}" resp q
  [ -n "$pr" ] || return 1
  q=$(jq -nr --arg v "$pr" '"pr="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/verdict?$q") || return 1
  printf '%s' "$resp" | jq -r '
    ([.artifacts[]? | select(.artifact_kind == "verdict") | .detail // ""] | first // "")
    | if . == "" then empty
      else (try (fromjson | .headbound // empty) catch empty) end' 2>/dev/null
}

# job_verdict_state <job-id>
#   Is this JOB's verdict settled? Prints `settled` or `provisional`, a TAB, and
#   the sha the row is bound to (`-` when it names none).
#     rc 0 -> one of those two words is on stdout
#     rc 2 -> the job has no verdict artifact at all (nobody judged it yet)
#     rc 1 -> outage, or no job id. Never "no verdict": an outage that read as an
#             absent judgement is the D11 conflation this repo keeps paying for.
#
#   KEYED ON THE JOB, NOT THE PR, and that is the whole reason it exists
#   (BH-858). `/api/verdict?pr=` resolves through the `pr_url` artifact, and a
#   build whose `gh pr create` died never wrote one — so the pr-keyed read cannot
#   find exactly the records the hub lanes are trying to repair.
job_verdict_state() {
  local job="${1:-}" resp state
  [ -n "$job" ] || return 1
  resp=$(_jobs_req GET "/api/jobs/$job/artifacts") || return 1
  # ONE jq pass: no verdict artifact prints nothing (rc 2), and a verdict row
  # whose detail is absent or unparseable is a row written before the field
  # existed — settled, the same rule job_verdict applies.
  state=$(printf '%s' "$resp" | jq -r '
    ([.artifacts[]? | select(.artifact_kind == "verdict")] | first // empty)
    | (try ((.detail // "") | fromjson) catch {}) as $o
    | (if ($o | type) == "object" then $o else {} end) as $o
    | [ (if $o.settled == false then "provisional" else "settled" end),
        (if (($o.reviewed_sha // "") | tostring) == "" then "-"
         else ($o.reviewed_sha | tostring) end) ] | @tsv' 2>/dev/null)
  [ -n "$state" ] || return 2
  printf '%s\n' "$state"
}

# job_for_record <project> <record-basename>
#   The job id that wrote a given build directory, read out of the `result`
#   artifact feed — every terminal, PR_CREATE_FAILED included, records its
#   `build_dir` there. It is how a hub lane holding a build record on disk
#   reaches the ledger row behind it without a new file, a new column or a change
#   to the Fly relay, and it is the only path that also resolves records stranded
#   BEFORE any of this shipped.
#
#   MEMOISED PER PROCESS: one feed call per project per run, so a 50-record walk
#   costs one request rather than fifty. AN OUTAGE IS NEVER CACHED — rc 1 leaves
#   the cache empty and the next call asks again.
#     rc 0 -> the job id is on stdout.  rc 2 -> the feed does not name that dir.
#     rc 1 -> outage, or a missing argument.
job_for_record() {
  local project="${1:-}" rec="${2:-}" var setvar feed hit
  [ -n "$project" ] && [ -n "$rec" ] || return 1
  # `pool-` / `fly-` are the HUB's copy markers on a relayed build dir; the
  # builder recorded the name it used locally, without them.
  rec="${rec#pool-}"; rec="${rec#fly-}"
  var="_JFR_$(printf '%s' "$project" | tr -c 'A-Za-z0-9' '_')"
  setvar="${var}_SET"
  if [ "${!setvar-}" != 1 ]; then
    feed=$(job_artifact_feed result "$project" "" "${JOB_FOR_RECORD_LIMIT:-500}") || return 1
    # One awk pass, not one jq per row: the map is <build_dir>\t<job_id>, with
    # the hub's copy prefix stripped on this side too, so both spellings of the
    # same build answer the same job.
    printf -v "$var" '%s' "$(printf '%s\n' "$feed" | awk -F'\t' '
      NF >= 6 {
        if (match($6, /"build_dir":"[^"]*"/)) {
          b = substr($6, RSTART + 13, RLENGTH - 14)
          sub(/^pool-/, "", b); sub(/^fly-/, "", b)
          if (b != "") print b "\t" $1
        }
      }')"
    printf -v "$setvar" '%s' 1
  fi
  feed="${!var-}"
  # The feed is newest first, so the first match is the most recent job to claim
  # this dir — the right answer when a resumed job re-registered the same build.
  hit=$(printf '%s\n' "$feed" | awk -F'\t' -v r="$rec" '$1 == r { print $2; exit }')
  [ -n "$hit" ] || return 2
  printf '%s' "$hit"
}

# job_verdict_rebind <pr-url> <sha>
#   Move a HEAD-BOUND approval (SDLC item 1) onto a sha a MECHANICAL mover just
#   produced — the rebase train's verified rebase, the merge queue's own rebase.
#   Those rebases carry the tree a reviewer already read onto a newer base; they
#   are not fix commits nobody saw. Without a rebind every PR either mover
#   touches would fail the head-bound check on the next sweep tick and need a
#   hand merge, which is the starvation class the train exists to kill.
#
#   REBINDS, NEVER CLAIMS. rc 2 when the row carries no reviewed_sha: a build
#   from before item 1 shipped makes no claim about its head, and inventing one
#   here would turn "the old behaviour" into a gate the fleet never opted into.
#   Only a row that ALREADY names a reviewed sha can have it moved.
#
#   The rest of the verdict detail (tier, provenance, record, note) is read back
#   and rewritten verbatim — the artifact upserts on (job_id, artifact_kind), so
#   a put that dropped those fields would silently erase the merge sweep's tier
#   and provenance inputs.
#     rc 0 -> rebound. rc 2 -> no claim to move. rc 1 -> no row, or an outage.
job_verdict_rebind() {
  local pr="${1:-}" sha="${2:-}" resp rc job word detail
  [ -n "$pr" ] && [ -n "$sha" ] || return 1
  local q; q=$(jq -nr --arg v "$pr" '"pr="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/verdict?$q"); rc=$?
  [ "$rc" = 0 ] || return 1
  job=$(printf '%s' "$resp" | jq -r '.job_id // ""' 2>/dev/null)
  word=$(printf '%s' "$resp" | jq -r '.verdict // ""' 2>/dev/null)
  [ -n "$job" ] && [ -n "$word" ] || return 1
  [ -n "$(printf '%s' "$resp" | jq -r '.reviewed_sha // ""' 2>/dev/null)" ] || return 2
  detail=$(printf '%s' "$resp" | jq -r --arg s "$sha" '
    ([.artifacts[]? | select(.artifact_kind == "verdict") | .detail // ""] | first // "") as $d
    | (try ($d | fromjson) catch {}) as $o
    | (if ($o | type) == "object" then $o else {} end)
    | .reviewed_sha = $s | tojson' 2>/dev/null)
  [ -n "$detail" ] || return 1
  job_artifact_put verdict "$word" "$detail" "$job"
}

# --- BH-1024: the ledger as the FIRST home of the verdict and the reviewed sha -
# Today the same two facts live in four places — this artifact, a build record's
# `reviewed-sha` file, the `apverdict` lines in the conductor's attempts.txt and
# `.sha` in state/<project>.pr-reviews.json. The three files are on ONE box, so
# a lane elsewhere cannot see them, and a stale one costs either a second paid
# review or a parked PR. These readers let a lane ask the ledger FIRST. They are
# inert until an operator flips the flag row, and the files stay exactly where
# they are as the write-through cache and the fallback.

# verdict_single_home_on — rc 0 when the ledger is the first reader.
#   Resolution order is the gh-budget pattern (bin/lib/gh-budget.sh:72-88):
#   settings('verdict_single_home') first, then $VERDICT_SINGLE_HOME as the
#   documented env fallback, then the literal 0. THE DEFAULT IS OFF, and off is
#   today's behaviour byte for byte, which is what makes this landable dark.
#
#   MEMOISED PER PROCESS (the job_for_record rule): a tick that asks per PR must
#   not buy a settings read per PR. AN OUTAGE IS NEVER CACHED — a worker that
#   blinks for one tick must not pin three lanes onto one answer for the rest of
#   the process. An outage reads the SAME env fallback a missing row does (0 on
#   every box that has not set VERDICT_SINGLE_HOME), which is the honest
#   description of this code: it is not a rule that an unreachable worker always
#   reads OFF. A box that sets the env to 1 and loses the worker reads ON and
#   every ledger call under it then returns rc 1, which every caller treats as
#   "buy the read" — the same answer it gives today.
_VSH=0; _VSH_SET=0
verdict_single_home_on() {
  local val="" rc cacheable=1
  if [ "${_VSH_SET:-0}" = 1 ]; then [ "${_VSH:-0}" = 1 ]; return $?; fi
  if command -v setting_get >/dev/null 2>&1; then
    val=$(setting_get verdict_single_home 2>/dev/null); rc=$?
    case "$rc" in
      0) ;;
      2) val="" ;;
      *) val=""; cacheable=0 ;;
    esac
  fi
  [ -n "$val" ] || val="${VERDICT_SINGLE_HOME:-0}"
  case "$val" in 1|on|true|yes) val=1 ;; *) val=0 ;; esac
  [ "$cacheable" = 1 ] && { _VSH="$val"; _VSH_SET=1; }
  [ "$val" = 1 ]
}

# job_verdict_covers <pr-url> <sha> [source] [word]
#   Is there ALREADY a settled verdict bound to exactly this head — and, when a
#   source or a verdict word is named, written by that lane / saying that word?
#   One GET, and the question every file-based dedupe in this fleet was really
#   asking.
#     rc 0 -> covered: a settled row whose reviewed_sha IS this sha
#     rc 2 -> a REAL no: no row, no verdict, a provisional one, a different sha,
#             a different source, or a different verdict word
#     rc 1 -> outage, or a missing argument
#
#   THE WORD FILTER IS NOT DECORATION. "Covered" and "approved" are different
#   facts: a caller that skips work on a BLOCK bound to this head has skipped it
#   on a reviewer saying NO. mc_ap_consumed asks for APPROVE for exactly that
#   reason; a caller that wants either word simply leaves it empty.
#
#   SILENCE IS NEVER "COVERED". Every caller treats rc != 0 as "buy the read",
#   which is byte-identical to what it does today, so an outage can only cost a
#   review that would have been bought anyway — never a skipped one.
#
#   EXACT STRING EQUALITY on the sha, deliberately: an abbreviated head or a
#   prefix is not the sha a reviewer read, and a prefix match here would quietly
#   widen a head-bound gate into a branch-bound one.
job_verdict_covers() {
  local pr="${1:-}" sha="${2:-}" src="${3:-}" word="${4:-}" resp rc q
  [ -n "$pr" ] && [ -n "$sha" ] || return 1
  q=$(jq -nr --arg v "$pr" '"pr="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/verdict?$q"); rc=$?
  case "$rc" in
    2) return 2 ;;
    0) ;;
    *) return 1 ;;
  esac
  # ONE jq pass over the verdict artifact's own detail — the same place
  # job_verdict and job_verdict_headbound read from, so no second call and no
  # worker change. An unparseable detail reads as an empty object, which claims
  # no sha and therefore covers nothing.
  printf '%s' "$resp" | jq -e --arg s "$sha" --arg src "$src" --arg w "$word" '
    ([.artifacts[]? | select(.artifact_kind == "verdict") | .detail // ""] | first // "") as $d
    | (try ($d | fromjson) catch {}) as $o
    | (if ($o | type) == "object" then $o else {} end) as $o
    | ((.verdict // "") != "")
      and ($w == "" or ((.verdict // "") | tostring) == $w)
      and ($o.settled != false)
      and ((($o.reviewed_sha // .reviewed_sha // "") | tostring) == $s)
      and ($src == "" or (($o.source // "") | tostring) == $src)' >/dev/null 2>&1 || return 2
  return 0
}

# job_verdict_history <pr-url>
#   Every round this PR's verdict went through, oldest first, as TSV: verdict,
#   reviewed_sha, tier, provenance, source, created_at, job_id. The standing row
#   says what a merge acts on NOW; this says how it got there, which the artifact
#   upsert used to erase.
#
#   `job_id` is the LAST column and it is not decoration: the rounds are keyed on
#   the PR, not on one job (review-prs opens a fresh `review-verdict` job per
#   reviewed (PR, sha)), so one PR's history can carry rounds from a build, a
#   review lane claim and a re-review. Without the column an operator cannot tell
#   whose round they are reading. Appended at the END so a caller cutting the
#   first fields keeps working.
#     rc 0 -> rows on stdout.  rc 2 -> no job recorded this PR.  rc 1 -> outage.
job_verdict_history() {
  local pr="${1:-}" resp rc q
  [ -n "$pr" ] || return 1
  q=$(jq -nr --arg v "$pr" '"pr="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/verdict/history?$q"); rc=$?
  case "$rc" in
    2) return 2 ;;
    0) ;;
    *) return 1 ;;
  esac
  printf '%s' "$resp" | jq -r '.rounds[]? | [ .verdict, (.reviewed_sha // "-"), (.tier // "-"),
    (.provenance // "-"), (.source // "-"), (.created_at // "-"), (.job_id // "-") ] | @tsv' 2>/dev/null
}

# job_ledger_list <kind> [limit] — the whole ledger for one kind, newest first,
#   as TSV: key, status, job_id, updated_at.
#
#   job_ledger_get answers ONE key, which is the right shape for the merge and
#   apply gates (they hold the key and ask "is this done"). An OUTCOME reader
#   holds no key: it wants "which PRs did the fleet merge lately" and would
#   otherwise have to re-scrape GitHub for a list the ledger already has. The
#   read is deliberately a LIST and never a write — nothing here can flip a
#   ledger row, so a reporting lane cannot un-merge or re-open anything.
#
#   rc 1 on outage or an empty table, printing nothing, like every other helper
#   here. A caller that needs the file fallback (state/merge-sweep-done.txt)
#   still has it; a caller that only reports simply reports nothing that run.
job_ledger_list() {
  local kind="${1:-}" limit="${2:-200}" resp
  [ -n "$kind" ] || return 1
  case "$limit" in ''|*[!0-9]*) limit=200 ;; esac
  local q; q=$(jq -nr --arg k "$kind" --arg n "$limit" '"kind="+($k|@uri)+"&limit="+($n|@uri)') || return 1
  resp=$(_jobs_req GET "/api/ledger?$q") || return 1
  printf '%s' "$resp" | jq -r '.ledgers[]? | [.key, .status, (.job_id // "-"), (.updated_at // "-")] | @tsv' 2>/dev/null
}

# job_pr_facts <pr-url> — everything the ledger knows about one PR, in one
#   round trip: TSV of job_id, project, ticket_id, verdict, merge_sha, tier,
#   repairs (SDLC item 3 — the build's repair-round count, "-" when the row
#   predates it), scope (SDLC item 4 — the scope gate's verdict on the diff,
#   "-" when the row predates it, which is NOT the same fact as in-scope).
#   New fields are APPENDED, so a reader of the first six is unchanged.
#
#   job_verdict already reads /api/verdict, but it exists to answer a MERGE GATE
#   and so returns rc 2 ("nothing to say") for a job that recorded its PR and no
#   verdict — correct there, useless to a reader that wants the job's project
#   and ticket in order to attribute an outcome. Same endpoint, same one call,
#   different question; the two are kept apart rather than overloading the
#   gate's rc contract, which bin/merge-sweep.sh depends on.
#
#   Absent fields print "-" rather than empty, so a TSV reader never has a field
#   silently collapse into its neighbour.
#     rc 0 -> the ledger knows this PR
#     rc 2 -> worker reachable, no job recorded it (a REAL answer)
#     rc 1 -> outage
job_pr_facts() {
  local pr="${1:-}" resp rc row
  [ -n "$pr" ] || return 1
  local q; q=$(jq -nr --arg v "$pr" '"pr="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/verdict?$q"); rc=$?
  case "$rc" in
    2) return 2 ;;
    0) ;;
    *) return 1 ;;
  esac
  row=$(printf '%s' "$resp" | jq -r '
    [ (.job_id // "-"), (.job.project // "-"), (.job.ticket_id // "-"),
      (.verdict // "-"), (.merge_sha // "-"), (if .tier == null then "-" else (.tier|tostring) end),
      (if .repairs == null then "-" else (.repairs|tostring) end),
      (if (.scope // "") == "" then "-" else .scope end) ]
    | @tsv' 2>/dev/null)
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

# job_contracts — TSV of phase, artifact_kind, pattern.
job_contracts() {
  local resp
  resp=$(_jobs_req GET /api/contracts) || return 1
  printf '%s' "$resp" | jq -r '.contracts[]? | [.phase,.artifact_kind,(.pattern // ""),(.note // "")] | @tsv' 2>/dev/null
}

# job_contract_set <phase> <artifact_kind> [pattern] [note]
job_contract_set() {
  local phase="${1:-}" kind="${2:-}" pattern="${3:-}" note="${4:-}" body
  [ -n "$phase" ] && [ -n "$kind" ] || return 1
  body=$(jq -nc --arg p "$phase" --arg k "$kind" --arg x "$pattern" --arg n "$note" \
    '{phase:$p,artifact_kind:$k}
     + (if $x == "" then {} else {pattern:$x} end)
     + (if $n == "" then {} else {note:$n} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/contracts "$body" >/dev/null
}

# job_cap_row <lane> — the cap AND whether it was set explicitly.
#   Prints "<usd><TAB><0|1>". rc 1 on a tier fallback or an outage, exactly like
#   job_cap, so "nobody sized this lane" still reaches the UNBUDGETED LANE alert.
#
#   job_cap is left ALONE, printing the bare number it always has. A box syncs
#   bin/ as a whole but not atomically with every other box, and a new client
#   under an OLD bin/agent-call.sh must keep answering the shape that script
#   parses — a cap that arrives as "12.50\t1" and is compared numerically is a
#   budget bug wearing a feature's clothes.
job_cap_row() {
  local lane="${1:-}" resp cap src exp
  [ -n "$lane" ] || return 1
  resp=$(_jobs_req GET "/api/catalog/$lane") || return 1
  src=$(printf '%s' "$resp" | jq -r '.source // empty' 2>/dev/null)
  [ "$src" = catalog ] || return 1
  cap=$(printf '%s' "$resp" | jq -r '.budget_usd // empty' 2>/dev/null)
  case "$cap" in ''|*[!0-9.]*) return 1 ;; esac
  exp=$(printf '%s' "$resp" | jq -r 'if (.explicit // 0) == 1 then 1 else 0 end' 2>/dev/null)
  case "$exp" in 0|1) ;; *) exp=0 ;; esac
  printf '%s\t%s' "$cap" "$exp"
}

# job_cap_explicit <lane> <0|1> [reason] — mark a lane's cap as set on purpose.
# A the operator-edited row: the deploy-time catalog sync never touches this table, so
# an explicit cap survives every re-sync of catalog/context-budgets.json.
job_cap_explicit() {
  local lane="${1:-}" flag="${2:-}" reason="${3:-}" body
  [ -n "$lane" ] && [ -n "$flag" ] || return 1
  case "$flag" in 0|1|on|off|true|false) ;; *) return 1 ;; esac
  case "$flag" in on|true) flag=1 ;; off|false) flag=0 ;; esac
  body=$(jq -nc --arg l "$lane" --argjson e "$flag" --arg a "$JOBS_BOX" --arg r "$reason" \
    '{lane:$l,explicit:$e,actor:$a} + (if $r == "" then {} else {reason:$r} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/cap-flags "$body" >/dev/null
}

# catalog_sync [file] — push catalog/context-budgets.json into budget_catalog.
# Run on hot-deploy from the checkout; the worker derives the per-lane dollars
# so every box reads numbers computed one way.
catalog_sync() {
  local f="${1:-}"
  [ -n "$f" ] || for f in /root/harness-checkout/catalog/context-budgets.json \
                          "$JOBS_HARNESS/catalog/context-budgets.json"; do
    [ -r "$f" ] && break
  done
  [ -r "$f" ] || { _jobs_log "catalog_sync: no context-budgets.json found"; return 1; }
  _jobs_req PUT /api/catalog "$(cat "$f")"
}

# catalog_probe [file] — READ-ONLY: does harness-jobs still hold the rows the
# manifest declares? Asks GET /api/catalog/<lane> for ONE lane the file names.
#
#   rc 0  the worker served that lane from `budget_catalog` (prints the lane it
#         matched, for a by-hand check)
#   rc 2  the worker ANSWERED and has no catalog row on that lane's ladder — a
#         reset table, or a box that never synced
#   rc 1  no answer, or the manifest declares no lane with a numeric ceiling
#
# WHY IT EXISTS (BH-1042, audit fact #30). bin/harness-sync.sh only ever pushes
# when `state/catalog-synced` differs from the manifest's tree sha, and nothing
# asked the DB whether the rows were still there. Wipe the table with the stamp
# left behind and nobody re-pushes: every lane falls back to the catalog file,
# forever, with no line anywhere saying so. rc 1 and rc 2 are deliberately
# different facts — an outage is not a reset, and only rc 2 may void a stamp.
#
# THE KEY IS THE WORKER'S, not a guess: `catalogEntries()` in
# worker/jobs/src/index.js writes `<stage>/<project // "*">/*` for a lane with a
# numeric `ceiling_tokens`, so that is what is asked for. A LESS specific ladder
# row answering `catalog` is still a hit — the table is not reset, which is the
# only question here.
catalog_probe() {
  local f="${1:-}" lane resp
  [ -n "$f" ] || for f in /root/harness-checkout/catalog/context-budgets.json \
                          "$JOBS_HARNESS/catalog/context-budgets.json"; do
    [ -r "$f" ] && break
  done
  [ -r "$f" ] || { _jobs_log "catalog_probe: no context-budgets.json found"; return 1; }
  lane=$(jq -r 'first(.lanes[]? | select((.ceiling_tokens | type) == "number")
                | ((.stage // "") | tostring) + "/" + ((.project // "*") | tostring) + "/*")
                // empty' "$f" 2>/dev/null) || lane=""
  case "$lane" in ''|/*) return 1 ;; esac
  resp=$(_jobs_req GET "/api/catalog/$lane") || return 1
  if [ "$(printf '%s' "$resp" | jq -r '.source // ""' 2>/dev/null)" = catalog ]; then
    printf '%s' "$resp" | jq -r '.matched // ""' 2>/dev/null
    return 0
  fi
  return 2
}

