# shellcheck shell=bash
# bin/merge-conductor.d/bh-10201-queue-return.sh - A PR THAT LEFT THE MERGE
# QUEUE IS ON RECORD, AND ONE PERSON IS TOLD WHEN IT DOES NOT COME BACK
# (BH-10201). Sourced by bin/merge-conductor.sh (the BH-7453 fragment block);
# functions only, no side effect at source time. No LLM call anywhere here.
#
# WHY. #10134 was queued by a person at 21:28Z on 2026-11-25. A builder pushed
# its branch at 23:10Z, Mergify dequeued it, and the settle arm removed the
# merge-queue label. The lane approved the new head at 23:24Z. The READY arm
# then held it at the lead fence (BH-1606) with no row, no alert and no new
# comment (a hold comment is one per PR and kind, not per head). Nobody knew for
# 9.5 hours. No record keyed on the PR said "this PR was in the queue".
#
# WHAT THIS DOES NOT DO: it never puts a PR in the queue. The conductor has one
# door for that, and each door holds gates: the re-entry arm for the same head
# (the BH-6161 pre-queue gate, the CR hold, the culprit marks) and the READY
# arm for a new head (the lead fence, the block gate, the client approval gate,
# the migration, prod-red and e2e-red holds). A requeue from here would go
# round all of them. So this fragment keeps the RECORD and does the TELLING.
#
# THE RECORD. One jobs-ledger row, kind `queue_return`, key `<slug>#<num>`,
# written where the settle arm removes the label. Status:
#   owed      the PR left the queue and the pass below watches it
#   ladder    the cause is a red batch (checks, batch-red, timeout): the
#             existing ejection ladder owns it, the pass never reads it
#   released  a person took it out (their own `unlabeled merge-queue`, a
#             standing changes-requested review, a hold, a human dequeue)
#   done      it is back in the queue, merged or closed
# A row stays `owed` after a person was told: a LATER head of the same PR that
# the lead fence holds gets its own alert (the #10134 class, one more time).
# Detail (JSON): left_head, cause, left_at (epoch s), queued_by, told[] (the
# heads a person was told about; they survive a second leave of the same PR),
# stale (1 after the stale alert of this leave: one per leave).
#
# THE PASS. mc_qr_pass runs once per project tick, after the settle pass. It
# reads what the conductor's own arms left on the earlier ticks (the row and
# the ready-why note), so those arms always act first. One ledger list read
# per project, one cached PR read per owed row. mc_qr_decide (PURE) answers
# one word per row:
#   done         MERGED or CLOSED, a queue label is back, or the row is QUEUED
#   released     a hold label, a ticket or PR hold, or a culprit mark
#   told         this head was told already: nothing more, the row stays owed
#   wait         the PR could not be read, main is red, or it is not due yet
#   lead-alert   the conductor's ready-why note for the live head says
#                lead-held: ONE warn alert and ONE PR comment, at once
#   stale-alert  not back after MC_QUEUE_RETURN_ALERT_MIN minutes: ONE warn
#                alert and ONE PR comment with the conductor's state and reason
# The told head is written to the row BEFORE the alert: a crash costs the alert, never
# a second one. A ledger that does not take the write sends nothing this tick.
#
# KNOBS (catalog/lanes.d/merge-conductor.knobs.d/, read through lane_knob):
#   MC_QUEUE_RETURN=1            0 = no row and no pass
#   MC_QUEUE_RETURN_ALERT_MIN=30 minutes out of the queue before the stale
#                                alert; 0 = no stale alert
# Log lines: QUEUE_RETURN_OWED <key> <h8> <status>, QUEUE_RETURN_CLOSED <key>
# <word>, QUEUE_RETURN_TOLD <key> <h8> <word>.

# _mc_qr_knob <ENV> <fallback> — the settings row lane.merge-conductor.<env
#   lower> through lane_knob, else the env var, else <fallback>. A value that
#   is not a non-negative integer reads as <fallback>. Rows:
#   lane.merge-conductor.mc_queue_return (fallback 1) and
#   lane.merge-conductor.mc_queue_return_alert_min (fallback 30).
_mc_qr_knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  printf '%s' "$v"
}

# mc_qr_owe_status <cause> <person-removed 0|1> — PURE. The status of a new
#   row. <cause> is bin/lib/mc-eject-cause.sh's word.
mc_qr_owe_status() {
  [ "${2:-0}" != 1 ] || { printf 'released'; return 0; }
  case "${1:-}" in
    checks|batch-red|timeout) printf 'ladder' ;;
    review) printf 'released' ;;
    *) printf 'owed' ;;
  esac
}

# mc_qr_events_read <label> [max] — PURE. stdin: the PR's issue events (JSON
#   array, oldest first). Prints `<person-removed 0|1>\t<queued_by>`.
#   person-removed is 1 when the newest `unlabeled <label>` event is a person's
#   and no later `labeled <label>` event exists. queued_by is `person:<login>`,
#   `conductor` (a bot put the label on) or `unknown`. A body that is not an
#   array, or one that holds <max> events (default 300: the read was cut and
#   the newest events are not in it), is `0\tunknown`.
mc_qr_events_read() {
  local out max="${2:-300}"
  case "$max" in ''|*[!0-9]*) max=300 ;; esac
  out=$(jq -r --arg l "${1:-merge-queue}" --argjson max "$max" '
    def person: ((.actor.type // "") == "User") and ((.actor.login // "") | endswith("[bot]") | not);
    if type != "array" or length >= $max then "0\tunknown" else
      [ .[] | select(type == "object" and (.label.name // "") == $l and (.event == "labeled" or .event == "unlabeled")) ] as $e
      | ($e | map(select(.event == "unlabeled")) | last) as $u
      | ($e | map(select(.event == "labeled")) | last) as $q
      | [ (if $u != null and ($u | person) and ($q == null or ($u.created_at // "") >= ($q.created_at // "")) then "1" else "0" end),
          (if $q == null then "unknown" elif ($q | person) then "person:" + ($q.actor.login // "?") else "conductor" end) ]
      | join("\t")
    end' 2>/dev/null) || out=""
  [ -n "$out" ] || out=$'0\tunknown'
  printf '%s\n' "$out"
}

# mc_qr_decide <pr-state> <in-queue 0|1> <row-state> <hold 0|1> <main-red 0|1>
#              <ready-why-kind> <age-min> <alert-min> <told 0|1> <stale-sent 0|1>
#   PURE, see the header. The first rule that holds answers.
mc_qr_decide() {
  local ps="${1:-}" inq="${2:-0}" rst="${3:-}" hold="${4:-0}" red="${5:-0}" kind="${6:-}" age="${7:-0}" lim="${8:-30}" told="${9:-0}" stale="${10:-0}"
  case "$ps" in
    MERGED|CLOSED) printf 'done'; return 0 ;;
    OPEN) ;;
    *) printf 'wait'; return 0 ;;
  esac
  [ "$inq" != 1 ] && [ "$rst" != QUEUED ] || { printf 'done'; return 0; }
  [ "$hold" != 1 ] || { printf 'released'; return 0; }
  [ "$told" != 1 ] || { printf 'told'; return 0; }
  [ "$red" != 1 ] || { printf 'wait'; return 0; }
  [ "$kind" != lead-held ] || { printf 'lead-alert'; return 0; }
  case "$age" in ''|*[!0-9]*) age=0 ;; esac
  case "$lim" in ''|*[!0-9]*) lim=30 ;; esac
  [ "$stale" != 1 ] && [ "$lim" -gt 0 ] && [ "$age" -ge "$lim" ] && { printf 'stale-alert'; return 0; }
  printf 'wait'
}

# mc_qr_clears <row-state> <ready-why-kind> <head> — PURE. Prints
#   `<the hold>\t<the ONE action that clears it, and who can do it>`, so the
#   person who reads the alert does not have to investigate. A ready-why kind
#   names the gate; with none, the conductor's row state does.
mc_qr_clears() {
  local rst="${1:-}" kind="${2:-}" h="${3:-}"
  case "$kind" in
    lead-held)   printf 'the lead fence (BH-1606)\ta lead or human MERGE on head %s, then `@mergifyio queue` on the PR — a repo lead does both' "$h"; return 0 ;;
    lead-unread) printf 'the lead fence (BH-1606), which could not be read\tno action: the conductor reads it again on its next tick; if it stays, a harness operator checks the lead_pr_authors settings row'; return 0 ;;
    dep-hold)    printf 'the PR-dependency gate\tmerge or close the PR that this one names as its dependency — its author or a lead'; return 0 ;;
    main-red)    printf 'the main-red hold\tno action on this PR: it goes back when main is green'; return 0 ;;
    iron-law)    printf 'the iron-law scan\tremove the flagged lines (the author), or a lead MERGE on head %s' "$h"; return 0 ;;
    migration)   printf 'the migration hold\tapply the named migrations in production (a harness operator); the conductor then re-checks'; return 0 ;;
    provenance)  printf 'the provenance gate\tno action: a claude head-bound re-review of head %s clears it (the review lane)' "$h"; return 0 ;;
  esac
  case "$rst" in
    HEAD_MOVED|WAIT_CI|REBASING|NEEDS_REBASE)
      printf 'no gate yet (conductor state %s)\tno action: the review lane and CI must pass on head %s, then the conductor queues it; if this stays, a lead reads the row reason' "$rst" "$h" ;;
    BLOCKED_HUMAN|BLOCKED_AGENT)
      printf 'a conductor park (state %s)\tthe row reason below names the cause; bin/blocked-resolver.sh owns the fix round, and a lead MERGE or a new head clears it' "$rst" ;;
    STACKED_WAIT)
      printf 'the stacked-PR wait\tmerge the parent PR — its author or a lead' ;;
    READY)
      printf 'a READY-arm hold with no recorded kind\ta lead reads the row reason below and the merge-conductor log for this PR' ;;
    *)
      printf 'no conductor row for this PR (state %s)\ta harness operator checks that the conductor lists this repo' "${rst:-none}" ;;
  esac
}

# _mc_qr_events <slug> <num> — ONE events read (gh_rest_issue_events, at most
#   300 events), answered by mc_qr_events_read. A failed read is `0\tunknown`:
#   an unread thread never releases a row.
_mc_qr_events() {
  local raw=""
  mc_rest_var raw gh_rest_issue_events "$1" "$2" 300 || raw=""
  [ -n "$raw" ] || raw='{}'
  mc_qr_events_read "${MC_MERGIFY_LABEL:-merge-queue}" 300 <<<"$raw"
}

# mc_qr_owe <slug> <key> <left-head> <cause> — the settle arm calls it in merge
#   mode, after it removed the label and named the cause. One events read, one
#   ledger row read (the told heads), one ledger write. Always rc 0.
mc_qr_owe() {
  local slug="${1:-}" key="${2:-}" left="${3:-}" cause="${4:-}" rm=0 by=unknown st prev told detail
  [ "$(_mc_qr_knob MC_QUEUE_RETURN 1)" != 0 ] || return 0
  [ -n "$slug" ] && [ -n "$key" ] && [ -n "$left" ] || return 0
  command -v job_ledger_put >/dev/null 2>&1 || return 0
  [ -n "$cause" ] || cause=unknown
  IFS=$'\t' read -r rm by <<<"$(_mc_qr_events "$slug" "${key##*#}")"
  st=$(mc_qr_owe_status "$cause" "${rm:-0}")
  prev=$(job_ledger_row queue_return "$key" 2>/dev/null) || prev=""
  [ -n "$prev" ] || prev='{}'
  told=$(jq -c '((.detail // "") | fromjson? // {}) | (.told // []) | if type == "array" then . else [] end' <<<"$prev" 2>/dev/null) || told=""
  [ -n "$told" ] || told='[]'
  detail=$(jq -nc --arg lh "$left" --arg c "$cause" --arg by "${by:-unknown}" --arg at "$(mc_now)" --argjson told "$told" \
    '{left_head: $lh, cause: $c, left_at: ($at | tonumber? // 0), queued_by: $by, told: $told}' 2>/dev/null) || return 0
  if job_ledger_put queue_return "$key" "$st" "$detail"; then
    mc_log "QUEUE_RETURN_OWED $key ${left:0:8} $st — left the merge queue, cause $cause, queued by ${by:-unknown} (BH-10201)"
  else
    mc_log "QUEUE_RETURN_OWED $key ${left:0:8} NOT recorded — the jobs ledger did not take the row; nothing watches this leave (BH-10201)"
  fi
  return 0
}

# _mc_qr_tell <slug> <key> <live-head> <word> <detail-json> <text> — the mark,
#   then the alert, then the PR comment. rc 0 always.
_mc_qr_tell() {
  local slug="$1" key="$2" live="$3" word="$4" detail="$5" text="$6" body
  detail=$(jq -c --arg h "$live" --arg w "$word" '.told = (((.told // []) + [$h]) | unique)
    | if $w == "stale-alert" then .stale = 1 else . end' <<<"$detail" 2>/dev/null) || return 0
  if ! job_ledger_put queue_return "$key" owed "$detail"; then
    mc_log "$key ${live:0:8} queue return: the told mark was not recorded — no alert this tick, asked again next tick (BH-10201)"
    return 0
  fi
  mc_alert "$key" QUEUE_RETURN "$text"
  mc_log "QUEUE_RETURN_TOLD $key ${live:0:8} $word — $text"
  body="The merge conductor: this PR ${text} The conductor does not put it back in the queue by itself while that hold stands. (BH-10201, one comment per head.)"
  mc_issue_comment "$slug" "${key##*#}" "$body" >/dev/null 2>&1 \
    || mc_log "$key ${live:0:8} queue return: the PR comment could not be posted — the alert is the only notice this head gets (BH-10201)"
  return 0
}

# mc_qr_pass <project> <slug> — see the header. Reads the tick's $MAIN_RED (the
#   red flag in force, or empty), $ACTIONS and $KILL. A row whose leave this
#   tick made is not read until the next tick. Always rc 0.
mc_qr_pass() {
  local p="${1:-}" slug="${2:-}" resp rows row key n detail left cause at by j ps live labels inq hold kind rst rwhy told age lim word red=0 now url text gate fix stale
  [ "$(_mc_qr_knob MC_QUEUE_RETURN 1)" != 0 ] || return 0
  [ "${ACTIONS:-0}" = 1 ] && [ "${KILL:-0}" != 1 ] || return 0
  [ -n "$slug" ] && command -v _jobs_req >/dev/null 2>&1 || return 0
  # 200 is the route's default page; owed rows live for minutes, not days.
  resp=$(_jobs_req GET "/api/ledger?kind=queue_return&status=owed&limit=200" 2>/dev/null) || return 0
  rows=$(jq -c --arg p "$slug#" '.ledgers[]? | select((.key // "") | startswith($p))
    | {key, detail: ((.detail // "") | fromjson? // {})}' <<<"$resp" 2>/dev/null) || return 0
  [ -n "$rows" ] || return 0
  lim=$(_mc_qr_knob MC_QUEUE_RETURN_ALERT_MIN 30); now=$(mc_now)
  [ -z "${MAIN_RED:-}" ] || red=1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    key=$(jq -r '.key' <<<"$row" 2>/dev/null); n="${key##*#}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    mc_only_has "$key" || continue
    detail=$(jq -c '.detail' <<<"$row" 2>/dev/null)
    IFS=$'\t' read -r left cause at by <<<"$(jq -r '[(.left_head // "-"), (.cause // "unknown"), ((.left_at // 0) | tostring), (.queued_by // "unknown")] | @tsv' <<<"$detail" 2>/dev/null)"
    # A leave this tick made gets one tick to stand (the BH-636 rule): the
    # tick's PR read can still carry the label the settle arm just removed.
    mc_tick_ejected_now "$p" "$key" "$left" 2>/dev/null && continue
    url="https://github.com/$slug/pull/$n"
    j=$(mc_pr_view "$url" '"\(.STATE) \(.head.sha) \(.LABELS)"' 2>/dev/null) || j=""
    ps=""; live=""; labels=""
    read -r ps live labels <<<"$j"
    inq=0; hold=0; told=0; stale=0; kind=""; rst=""; rwhy=""
    grep -qE "(^|,)(${MC_MERGIFY_LABEL:-merge-queue}|queued|checking)(,|\$)" <<<"$labels" && inq=1
    grep -qE '(^|,)hold(,|$)' <<<"$labels" && hold=1
    IFS=$'\t' read -r _ rst _ _ _ _ rwhy _ <<<"$(mc_row_get "$key")"
    if [ -n "$live" ]; then
      kind=$(mc_ready_why_kind "$key" "$live" 2>/dev/null)
      jq -e --arg h "$live" '(.told // []) | index($h) != null' <<<"$detail" >/dev/null 2>&1 && told=1
    fi
    jq -e '(.stale // 0) == 1' <<<"$detail" >/dev/null 2>&1 && stale=1
    case "$kind" in ticket-hold|pr-hold|hold-label) hold=1 ;; esac
    mc_attempt_has "dqwculprit $key $left" 2>/dev/null && hold=1
    case "$at" in ''|*[!0-9]*) at=$now ;; esac
    age=$(( (now - at) / 60 )); [ "$age" -ge 0 ] || age=0
    word=$(mc_qr_decide "$ps" "$inq" "$rst" "$hold" "$red" "$kind" "$age" "$lim" "$told" "$stale")
    case "$word" in
      done|released)
        job_ledger_put queue_return "$key" "$word" "$detail" \
          && mc_log "QUEUE_RETURN_CLOSED $key $word — it left the merge queue on ${left:0:8} (cause ${cause:-unknown}); PR ${ps:-unread}, conductor row ${rst:-none} (BH-10201)" ;;
      lead-alert|stale-alert)
        [ -n "$rwhy" ] || rwhy=$(mc_ready_why_last "$key" "$live" 2>/dev/null)
        IFS=$'\t' read -r gate fix <<<"$(mc_qr_clears "$rst" "$kind" "$live")"
        text="left the merge queue $age minutes ago on head ${left} (cause ${cause:-unknown}, queued by ${by:-unknown}) and is not back. Held on head ${live} by ${gate}${rwhy:+: $rwhy}. What clears it: ${fix}. $url"
        _mc_qr_tell "$slug" "$key" "$live" "$word" "$detail" "$text" ;;
    esac
  done <<<"$rows"
  return 0
}
