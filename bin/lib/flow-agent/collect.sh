#!/bin/bash
# bin/lib/flow-agent/collect.sh — flow_collect <project>: one compact JSON
# record per open ticket of one project that is not in flight and not waiting
# on the client (BH-9924 slice BH-9956). Sourced by bin/flow-agent.sh after
# bin/jobs-client.sh and bin/lib/jobs/flow-agent.sh, never run.
#
# THE READS, in this order:
#   R1 the board's open tickets. A GitHub-issues project (fleet.conf column 4
#      is `-`): the open ai-build issues (gh_rest_issue_list, REST), key
#      <PFX>-<n> from preplan_key_prefix, id <n>. An in-app project: GET
#      <base><prefix>/boards, then /boards/<id>/tickets (board-creds.sh), the
#      tickets whose status is not done (the prefix is fleet.conf column 4). Jira/Linear: could-not-run.
#   R2 the open PRs of the repo (gh_rest_pr_list_all), at most
#      flow_agent.pr_list_pages pages of 100. R1 and R2 run in PARALLEL.
#   R3 ONE POST /api/waiting/state with the R1 set, cut to flow_agent.waiting_max.
# R1 or R3 failing is rc 1 and NO record, never an empty set (D9): the lane
# logs FA_COLLECT_WHY. R2 failing marks unread:["pr"] on every record. A full
# last PR page sets pr_truncated=1 (D12). FA_TRUNCATED is the count of open
# tickets past waiting_max (the lane puts it in its summary line).
# FA_BOARD_TRUNCATED=1 when the open-issue list filled all of its
# flow_agent.issue_list_pages pages: tickets past it were not read (the lane
# logs a board-truncated line).
#
# A RECORD (one line each):
#   {project, key, id, repo, title, url, verdict, verdict_current, waiting_on,
#    triaged_at, queue:{status,enqueued_at,finished_at}|null, live_job:false,
#    parked, open_pr:{number,head}|null, pr_truncated, edges:[{parent,kind}],
#    unread:[...], episode, updated_at, now}
# verdict is the triage_state verdict (trimmed, lowercased), else the board's;
# verdict_current is false when triage_state's verdict_hash is not its
# input_hash. episode is triaged_at of a current verdict, else updated_at.
# A ticket with a running job whose heartbeat is newer than the route's
# stale_claim_min is in flight: no record. waiting_on client or requester: no
# record. A PR belongs to KEY when its head is ticket/<key lowercased> or
# ticket/<key lowercased>-r<digits> (a prefix such as ticket/bh-99560 is not).
#
# Then every collect.d/*.sh is sourced in name order and its
# flow_collect_<area> <records-file> called (it edits the file in place). A
# collector that returns non-0 adds <area> to unread on every record.
#
# The root is HARNESS, then H (never a literal default, D43). The clock is
# FLOW_AGENT_NOW (epoch, a test seam), else the system clock.
# No `set -e`, no `exit`, no output at source time, `set -u` safe.
# gh-rest: no-graphql

FA_WAITING_MAX_DEFAULT=500     # settings row flow_agent.waiting_max
FA_PR_LIST_PAGES_DEFAULT=3     # settings row flow_agent.pr_list_pages
FA_ISSUE_LIST_PAGES_DEFAULT=5  # settings row flow_agent.issue_list_pages
FA_BOARD_TIMEOUT_S_DEFAULT=30  # settings row flow_agent.board_timeout_s: the curl --max-time of each in-app board read
FA_STALE_CLAIM_MIN_DEFAULT=30  # settings row waiting.stale_claim_min: POST /api/waiting/state answers it
                               # in .knobs; this is used only when the answer has no knobs
_FA_COLLECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)

# _fa_now — the epoch of this pass.
_fa_now() {
  local n="${FLOW_AGENT_NOW:-}"
  [ -n "$n" ] || n=$(date -u +%s)
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$n"
}

# _fa_board_gh <slug> <prefix> <pages> > tickets.json
_fa_board_gh() {
  local slug="$1" pfx="$2" pages="$3" raw rc=0
  raw=$(mktemp "${TMPDIR:-/tmp}/fa-issues.XXXXXX") || return 1
  gh_rest_issue_list "$slug" open ai-build "$((pages * 100))" > "$raw" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$raw"; return 1; fi
  jq -c --arg pfx "$pfx" 'if type != "array" then error("not a list") else
      map({key: ($pfx + "-" + (.number | tostring)), id: (.number | tostring), title: (.title // ""),
           url: (.html_url // null), updated_at: (.updated_at // .created_at // null),
           board_verdict: null, board_waiting_on: null}) end' "$raw" 2>/dev/null || rc=1
  rm -f "$raw"
  return "$rc"
}

# _fa_board_inapp <project> <root> <board-prefix> > tickets.json
_fa_board_inapp() {
  local p="$1" root="$2" pfx="$3" envf tv bv base tok boards bid bpfx raw rc=0 to
  to=$(fa_knob flow_agent.board_timeout_s "$FA_BOARD_TIMEOUT_S_DEFAULT")
  [ "${to:-0}" -ge 1 ] 2>/dev/null || to=$FA_BOARD_TIMEOUT_S_DEFAULT
  envf="$(harness_env_dir "$root" 2>/dev/null || printf '%s/env' "$root")/$p.env"
  tv=$(board_token_var "$p" "$envf" flow-agent) || return 1
  bv=$(board_base_var "$p" "$envf" flow-agent) || return 1
  base=$(board_env_value "$bv" "$envf"); tok=$(board_env_value "$tv" "$envf")
  [ -n "$base" ] && [ -n "$tok" ] || return 1
  [ -n "$pfx" ] || return 1
  boards=$(curl -s --fail --max-time "$to" -H "Authorization: Bearer $tok" "$base$pfx/boards" 2>/dev/null) || return 1
  bid=$(jq -r '(if type=="array" then .[0] else .boards[0] end) | .id // empty' <<<"$boards" 2>/dev/null)
  bpfx=$(jq -r '(if type=="array" then .[0] else .boards[0] end) | (.keyPrefix // .key_prefix // empty)' <<<"$boards" 2>/dev/null)
  [ -n "$bid" ] || return 1
  raw=$(mktemp "${TMPDIR:-/tmp}/fa-board.XXXXXX") || return 1
  curl -s --fail --max-time "$to" -H "Authorization: Bearer $tok" "$base$pfx/boards/$bid/tickets" > "$raw" 2>/dev/null || rc=1
  if [ "$rc" = 0 ]; then
    jq -c --arg bp "$bpfx" '
        if type == "array" then . elif type == "object" and (.tickets | type) == "array" then .tickets else error("not a board") end
        | map(select(((.status // "") | ascii_downcase) != "done"))
        | map({key: (if (.key | type) == "string" then .key
                     elif .number != null and $bp != "" then ($bp + "-" + (.number | tostring))
                     else ((.number // .id) | tostring) end),
               id: ((.id // .number) | tostring), title: (.title // ""), url: (.url // null),
               updated_at: (.updatedAt // .lastActivityAt // .createdAt // null),
               board_verdict: (.triageVerdict // .triage_verdict // null),
               board_waiting_on: (.waitingOn // .waiting_on // null)})' "$raw" 2>/dev/null || rc=1
  fi
  rm -f "$raw"
  return "$rc"
}

# _fa_prs <slug> <pages> > prs.json — [{number, head}] plus .truncated in a side file
_fa_prs() {
  local slug="$1" pages="$2" raw rc=0
  raw=$(mktemp "${TMPDIR:-/tmp}/fa-prs.XXXXXX") || return 1
  gh_rest_pr_list_all "$slug" open "$((pages * 100))" > "$raw" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$raw"; return 1; fi
  jq -c --argjson max "$((pages * 100))" 'if type != "array" then error("not a list") else
      {truncated: (if length >= $max then 1 else 0 end), prs: map({number, head: (.head.ref // "")})} end' "$raw" 2>/dev/null || rc=1
  rm -f "$raw"
  return "$rc"
}

flow_collect() {
  local p="${1:-}" root="${HARNESS:-${H:-}}" row slug col4 kind="" pfx now wmax prp isp W
  local r1rc r2rc state body f area
  FA_COLLECT_WHY=""; FA_TRUNCATED=0; FA_BOARD_TRUNCATED=0
  [ -n "$p" ] && [ -n "$root" ] || { FA_COLLECT_WHY="no-root"; return 1; }
  row=$(awk -v p="$p" '!/^[[:space:]]*(#|$)/ && $1 == p {print $2, $4; exit}' "$root/fleet.conf" 2>/dev/null)
  slug="${row%% *}"; col4="${row#* }"
  [ -n "$row" ] && [ -n "$slug" ] || { FA_COLLECT_WHY="no-fleet-row"; return 1; }
  if command -v tracker_kind >/dev/null 2>&1; then
    kind=$(HARNESS="$root" tracker_kind "$p" 2>/dev/null) || kind=""
  fi
  case "$kind" in jira|linear) FA_COLLECT_WHY="tracker-kind-unsupported"; return 1 ;; esac
  now=$(_fa_now) || { FA_COLLECT_WHY="clock"; return 1; }
  wmax=$(fa_knob flow_agent.waiting_max "$FA_WAITING_MAX_DEFAULT")
  prp=$(fa_knob flow_agent.pr_list_pages "$FA_PR_LIST_PAGES_DEFAULT")
  isp=$(fa_knob flow_agent.issue_list_pages "$FA_ISSUE_LIST_PAGES_DEFAULT")
  W=$(mktemp -d "${TMPDIR:-/tmp}/fa-collect.XXXXXX") || { FA_COLLECT_WHY="mktemp"; return 1; }

  # R1 and R2 are independent: two background reads, then one wait.
  if [ "$col4" = "-" ]; then
    pfx=$(preplan_key_prefix "$root" "$p" 2>/dev/null) || { rm -rf "$W"; FA_COLLECT_WHY="no-key-prefix"; return 1; }
    ( _fa_board_gh "$slug" "$pfx" "$isp" > "$W/tickets.json"; echo $? > "$W/r1.rc" ) &
  else
    ( _fa_board_inapp "$p" "$root" "$col4" > "$W/tickets.json"; echo $? > "$W/r1.rc" ) &
  fi
  ( _fa_prs "$slug" "$prp" > "$W/prs.json"; echo $? > "$W/r2.rc" ) &
  wait
  r1rc=$(cat "$W/r1.rc" 2>/dev/null); r2rc=$(cat "$W/r2.rc" 2>/dev/null)
  if [ "$r1rc" != 0 ] || ! jq -e 'type == "array"' "$W/tickets.json" >/dev/null 2>&1; then
    rm -rf "$W"; FA_COLLECT_WHY="board-read"; return 1
  fi
  if [ "$r2rc" != 0 ] || ! jq -e '.prs | type == "array"' "$W/prs.json" >/dev/null 2>&1; then
    printf '{"truncated":0,"prs":[],"unread":true}' > "$W/prs.json"
  fi
  if [ "$col4" = "-" ] && [ "$(jq 'length' "$W/tickets.json")" -ge "$((isp * 100))" ]; then FA_BOARD_TRUNCATED=1; fi
  FA_TRUNCATED=$(jq --argjson m "$wmax" 'if length > $m then length - $m else 0 end' "$W/tickets.json")
  jq -c --argjson m "$wmax" '.[:$m]' "$W/tickets.json" > "$W/t.json"

  # R3: one read of the D1 state for the whole set.
  body=$(jq -c --arg p "$p" '{tickets: map({project: $p, key, id})}' "$W/t.json") || { rm -rf "$W"; FA_COLLECT_WHY="state-body"; return 1; }
  if ! state=$(_jobs_req POST /api/waiting/state "$body") || ! printf '%s' "$state" > "$W/state.json" \
     || ! jq -e '(.triage | type) == "array"' "$W/state.json" >/dev/null 2>&1; then
    rm -rf "$W"; FA_COLLECT_WHY="state-read"; return 1
  fi

  if ! jq -c -n --arg p "$p" --arg repo "$slug" --argjson now "$now" --argjson stale0 "$FA_STALE_CLAIM_MIN_DEFAULT" \
      --slurpfile T "$W/t.json" --slurpfile S "$W/state.json" --slurpfile R "$W/prs.json" '
      def norm: if type == "string" and (gsub("^\\s+|\\s+$"; "") != "") then gsub("^\\s+|\\s+$"; "") | ascii_downcase else null end;
      def ep(s): (s // "" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // null;
      ($S[0]) as $s | ($R[0]) as $r | (($s.knobs.stale_claim_min // $stale0) * 60) as $stale
      | $T[0][]
      | . as $t | ($t.key) as $k | ($t.id // $t.key) as $i
      | ([$s.triage[] | select(.ticket_key == $k or .ticket_key == $i)][0]) as $tri
      | ([$s.queue[] | select(.ticket_key == $k or .ticket_key == $i)][0]) as $q
      | ([$s.live_jobs[] | select(.ticket_id == $k or .ticket_id == $i)
          | select(($now - (ep(.beat_at // .updated_at) // 0)) < $stale)] | length > 0) as $live
      | ([$s.parked_jobs[] | select(.ticket_id == $k or .ticket_id == $i)] | length > 0) as $parked
      | ([$s.edges[] | select(.child == $k or .child == $i) | {parent, kind}]) as $edges
      | ("ticket/" + ($k | ascii_downcase)) as $br
      | ([$r.prs[] | select(.head == $br or ((.head | startswith($br + "-r")) and (.head[($br | length) + 2:] | test("^[0-9]+$"))))][0]) as $pr
      | (if $tri != null then ($tri.input_hash == null or $tri.verdict_hash == $tri.input_hash) else ($t.board_verdict | norm) != null end) as $cur
      | (if $tri != null then ($tri.verdict | norm) else ($t.board_verdict | norm) end) as $v
      | (($t.board_waiting_on | norm) // ($tri.waiting_on | norm)) as $wo
      | select($live | not)
      | select(($wo == "client" or $wo == "requester") | not)
      | {project: $p, key: $k, id: $i, repo: $repo, title: ($t.title // ""), url: $t.url,
         verdict: $v, verdict_current: $cur, waiting_on: $wo,
         triaged_at: ($tri.triaged_at // null),
         queue: (if $q == null then null else {status: $q.status, enqueued_at: $q.enqueued_at, finished_at: $q.finished_at} end),
         live_job: false, parked: $parked,
         open_pr: (if $pr == null then null else {number: $pr.number, head: $pr.head} end),
         pr_truncated: ($r.truncated // 0), edges: $edges,
         unread: (if $r.unread == true then ["pr"] else [] end),
         episode: (if $cur and ($tri.triaged_at // null) != null then $tri.triaged_at else ($t.updated_at // "none") end),
         updated_at: $t.updated_at, now: $now}' > "$W/records.jsonl" 2>/dev/null; then
    rm -rf "$W"; FA_COLLECT_WHY="join"; return 1
  fi

  # collect.d: each area adds its fields; a failing one marks the area unread.
  for f in "$_FA_COLLECT_DIR"/collect.d/*.sh; do
    [ -f "$f" ] || continue
    area=$(basename "$f" .sh)
    # shellcheck source=/dev/null
    . "$f" 2>/dev/null || { _fa_mark_unread "$W/records.jsonl" "$area"; continue; }
    declare -F "flow_collect_$area" >/dev/null 2>&1 || continue
    "flow_collect_$area" "$W/records.jsonl" || _fa_mark_unread "$W/records.jsonl" "$area"
  done
  cat "$W/records.jsonl"
  rm -rf "$W"
  return 0
}

# _fa_mark_unread <records-file> <area> — adds <area> to unread on every record.
_fa_mark_unread() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fa-unread.XXXXXX") || return 0
  jq -c --arg a "$2" '.unread = ((.unread // []) + [$a] | unique)' "$1" > "$tmp" 2>/dev/null && mv "$tmp" "$1" || rm -f "$tmp"
  return 0
}
