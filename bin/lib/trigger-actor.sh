#!/bin/bash
# bin/lib/trigger-actor.sh — WHO MAY MAKE A TICKET BUILDABLE (BH-4490, #4475 wave 3).
# Sourced by the `# >>> trigger actor gate (BH-4490)` block of bin/lib/rb/gates.sh;
# defines functions only, and reads nothing at source time.
#
# The loop class this closes: a bot (or another agent) puts `ai-build` back on an
# issue, or moves an in-app ticket, and the harness builds on its say-so. TK-88
# ran to 213 comments that way and TK-135 ping-ponged. So the trigger itself is
# checked: the NEWEST `labeled ai-build` event on a GitHub-Issues board, the
# NEWEST `status_change` in an in-app ticket's `activity[]`.
#
# THE RULE (ta_decide), first hit wins:
#   1. the actor is the harness itself -> allow `self`. GitHub: hs_ours over
#      HARNESS_SELF_APPS (bin/lib/harness-self.sh, the existing trust list).
#      In-app: the board's harness display name (ta_self_names).
#   2. the settings row trigger.actors.<p> is set -> allow `listed` when the
#      actor matches an entry (case-insensitive; GitHub: the login; in-app: the
#      userId or the display name), else ignore `not-listed`, bots included.
#   3. no row -> GitHub: a Bot is ignored `bot`, a User is allowed
#      `human-default`. In-app: allowed `unarmed`, and the board is not read.
#   4. the row cannot be read -> unverifiable (the gate defers, fail closed).
#      So does a GitHub project whose self-app list resolves empty: without
#      it rule 1 cannot fire and our own label would read as a foreign bot.
# Row value: entries separated by spaces, or by commas when the value holds a
# comma (so a display name with a space can be listed: `u_7, Dana Ruiz`). The
# literal `off` unarms the project.
#
# OUTCOME RECORD: ledger kind `trigger-actor`, key "<p> <KEY>", status
# ignored|allowed, detail JSON {event, actor, why, source, commented, at}. ONE
# comment per ignore episode: the claim PUT (commented=pending) goes in BEFORE
# the comment is posted, a row already `ignored` posts nothing, and a listed
# trigger flips the row to `allowed` so the next ignore comments again. A
# comment that fails after the claim is not retried (at most once). A same-box
# race is a dedupe flock; two boxes on the very same tick can still post twice.
#
# Kill switch: lane_switch trigger-actor-off (catalog/switches.d).
# Root: ${HARNESS:-${H:-}} only (BH-2613); empty root -> deps not loaded, and
# ta_gate answers unverifiable rather than building a path from nothing.
# shellcheck shell=bash

# A test seam, not a business knob: how many 100-event pages a read may take.
PROJECT_2_EVENT_PAGES=10

# A TRANSIENT EVENTS READ IS RETRIED BEFORE THE BUILD DEFERS (BH-5021). BH-4973
# deferred on `events page 1 rc=75` with an empty reason, a 5xx that a few
# seconds would have fixed. A page answering rc 75 with GH_REST_REASON "",
# network, empty or cache-miss is read again up to PROJECT_2_EVENTS_RETRIES more times
# (default 2), sleeping the next value of PROJECT_2_EVENTS_RETRY_BACKOFF_S between
# tries (default "3 10", the last value reused). rate-limit and quota-reserve are
# never retried: seconds cannot refill the bucket and a retry spends more of it.
# Operational timings with env overrides (the PROJECT_2_EVENT_PAGES precedent), not
# business parameters; PROJECT_2_EVENTS_RETRIES=0 is the single read of before.
_ta_retries() {
  case "${PROJECT_2_EVENTS_RETRIES:-2}" in ''|*[!0-9]*) echo 2 ;; *) echo "${PROJECT_2_EVENTS_RETRIES:-2}" ;; esac
}
_ta_backoff() { # _ta_backoff <retry n, 1-based> -> seconds
  local list="${PROJECT_2_EVENTS_RETRY_BACKOFF_S:-3 10}" v last="" i=0
  for v in $list; do
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { list="3 10"; break; }
  done
  for v in $list; do
    i=$((i+1)); last="$v"
    [ "$i" -ge "$1" ] && break
  done
  echo "${last:-3}"
}

_ta_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _ta_deps — load what is not already loaded. Every source is guarded on the
# function it provides, so a stub (or the prelude's own copy) is never replaced.
_ta_deps() {
  local r; r=$(_ta_root)
  [ -n "$r" ] || return 1
  # shellcheck source=bin/lib/harness-self.sh
  [ -n "${HARNESS_SELF_JQ_DEF:-}" ] || { [ -r "$r/bin/lib/harness-self.sh" ] && . "$r/bin/lib/harness-self.sh" 2>/dev/null; } || true
  if ! command -v gh_rest >/dev/null 2>&1 || ! command -v gh_rest_comment >/dev/null 2>&1; then
    # shellcheck source=bin/lib/gh-rest.sh
    [ -r "$r/bin/lib/gh-rest.sh" ] && . "$r/bin/lib/gh-rest.sh" 2>/dev/null || true
  fi
  # jobs-client.sh exits the shell it is sourced into when its modules are
  # missing, so it is only sourced beside a bin/lib/jobs/ that exists.
  if ! command -v setting_get >/dev/null 2>&1 && [ -d "$r/bin/lib/jobs" ]; then
    # shellcheck source=bin/jobs-client.sh
    [ -r "$r/bin/jobs-client.sh" ] && . "$r/bin/jobs-client.sh" 2>/dev/null || true
  fi
  if ! command -v lane_switch >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-switch.sh
    [ -r "$r/bin/lib/lane-switch.sh" ] && . "$r/bin/lib/lane-switch.sh" 2>/dev/null || true
  fi
  return 0
}

_ta_lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# ta_allowlist <p> — sets PROJECT_2_ROW (armed|absent|unreadable) and PROJECT_2_ALLOW (the
# lowercased entries, one per line). An unconfigured jobs client (no JOBS_URL
# or no HARNESS_SECRET) has no rows to read: absent, with PROJECT_2_NOTE saying so.
ta_allowlist() {
  local p="${1:-}" v rc=0
  PROJECT_2_ROW=unreadable; PROJECT_2_ALLOW=""
  command -v setting_get >/dev/null 2>&1 || { PROJECT_2_NOTE="no settings client"; return 0; }
  if command -v _setting_key_ok >/dev/null 2>&1 && ! _setting_key_ok "trigger.actors.$p"; then
    PROJECT_2_NOTE="trigger.actors.$p is not a legal settings key"; return 0
  fi
  v=$(setting_get "trigger.actors.$p" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    2) PROJECT_2_ROW=absent; return 0 ;;
    *) if [ -z "${JOBS_URL:-}" ] || [ -z "${HARNESS_SECRET:-}" ]; then
         PROJECT_2_ROW=absent; PROJECT_2_NOTE="jobs client not configured, no allowlist row"
       fi
       return 0 ;;
  esac
  v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if [ "$(_ta_lc "$v")" = off ] || [ -z "$v" ]; then PROJECT_2_ROW=absent; return 0; fi
  PROJECT_2_ROW=armed
  case "$v" in
    *,*) PROJECT_2_ALLOW=$(printf '%s' "$v" | tr ',' '\n') ;;
    *)   PROJECT_2_ALLOW=$(printf '%s' "$v" | tr -s '[:space:]' '\n') ;;
  esac
  PROJECT_2_ALLOW=$(printf '%s\n' "$PROJECT_2_ALLOW" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | tr '[:upper:]' '[:lower:]')
  return 0
}

# ta_self_names <p> — the display name an in-app board shows for the harness.
# The twin of the SELF_ACTORS column in bin/triage-gate.sh's project case table
# (and its generic arm); kept here so triage-gate.sh stays untouched.
ta_self_names() {
  case "${1:-}" in
    project-1)   printf '%s' "project-1 Team Harness" ;;
    project-2) printf '%s' "project-2 Harness" ;;
    project-3)       printf '%s' "project-3 AI Harness" ;;
    project-4)       printf '%s' "system-board Harness" ;;
    *)             printf '%s' "${BOARD_SELF_ACTORS:-System} Harness" ;;
  esac
}

# ta_decide <p> <gh|board> <id1> <id2> <type> <app_slug> <self_name>
#   gh: id1 = login, type = actor.type, app_slug = performed_via_github_app.slug.
#   board: id1 = userId, id2 = display name, self_name = ta_self_names.
#   Reads PROJECT_2_ROW / PROJECT_2_ALLOW (ta_allowlist). Prints `allow <why>` rc 0 or
#   `ignore <why>` rc 1.
ta_decide() {
  local src="${2:-}" id1="${3:-}" id2="${4:-}" typ="${5:-}" slug="${6:-}" self="${7:-}"
  local l1 l2 tok
  l1=$(_ta_lc "$id1"); l2=$(_ta_lc "$id2")
  if [ "$src" = gh ]; then
    if [ -n "${HARNESS_SELF_JQ_DEF:-}" ] && command -v harness_self_apps_json >/dev/null 2>&1 \
       && jq -ne --arg l "$id1" --arg t "$typ" --arg s "$slug" --argjson apps "$(harness_self_apps_json)" \
            "$HARNESS_SELF_JQ_DEF"' {user:{login:$l, type:$t}, performed_via_github_app:{slug:$s}} | hs_ours($apps)' >/dev/null 2>&1; then
      echo "allow self"; return 0
    fi
  elif [ -n "$self" ] && [ -n "$l2" ] && [ "$l2" = "$(_ta_lc "$self")" ]; then
    echo "allow self"; return 0
  fi
  if [ "${PROJECT_2_ROW:-}" = armed ]; then
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      if [ "$tok" = "$l1" ] || { [ -n "$l2" ] && [ "$tok" = "$l2" ]; }; then echo "allow listed"; return 0; fi
    done <<<"${PROJECT_2_ALLOW:-}"
    echo "ignore not-listed"; return 1
  fi
  if [ "$src" = gh ]; then
    case "$l1" in *'[bot]') echo "ignore bot"; return 1 ;; esac
    [ "$(_ta_lc "$typ")" = bot ] && { echo "ignore bot"; return 1; }
    echo "allow human-default"; return 0
  fi
  echo "allow unarmed"; return 0
}

# ta_gh_trigger <slug> <num> <out> — the newest `labeled ai-build` event as
# `id<TAB>login<TAB>type<TAB>app_slug<TAB>created_at`, or an empty <out>.
#   rc 0 read (empty <out> = no such event), rc 2 unverifiable (PROJECT_2_NOTE says
#   why: a page that was not rc 0, or the page cap reached on a full page),
#   rc 3 no GitHub here (no gh, or gh_rest refused the arguments).
# A read that needed retries says so in PROJECT_2_READ_NOTE (`events page 1 retried 1`),
# kept apart from PROJECT_2_NOTE, which ta_gate's ignore line reads as its own reason.
# Each page is read through a FILE inside a subshell that arms the identity,
# so GH_REST_REASON survives (gh-rest.sh's contract) and GH_TOKEN does not.
# A 401 (GH_REST_STATUS, kept beside the reason) is named `token-401 events
# page N`: the machine's token is dead, not the ticket (BH-5025.2).
ta_gh_trigger() {
  local slug="$1" n="$2" out="$3" pg=1 rc cnt pf hits tries retries
  : > "$out"
  command -v gh >/dev/null 2>&1 || { PROJECT_2_NOTE="no gh on this box"; return 3; }
  command -v gh_rest >/dev/null 2>&1 || { PROJECT_2_NOTE="gh-rest lib missing"; return 2; }
  pf="$out.page"; hits="$out.hits"; : > "$hits"; PROJECT_2_READ_NOTE=""
  retries=$(_ta_retries)
  while [ "$pg" -le "$PROJECT_2_EVENT_PAGES" ]; do
    tries=0
    while :; do
      rc=0
      ( command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$slug" >/dev/null 2>&1
        r=0; gh_rest GET "repos/$slug/issues/$n/events?per_page=100&page=$pg" > "$pf" 2>/dev/null || r=$?
        printf '%s' "${GH_REST_REASON:-}" > "$pf.reason"; printf '%s' "${GH_REST_STATUS:-}" > "$pf.status"; exit "$r" ) || rc=$?
      [ "$rc" = 75 ] && [ "$tries" -lt "$retries" ] || break
      case "$(cat "$pf.reason" 2>/dev/null)" in ''|network|empty|cache-miss) ;; *) break ;; esac
      tries=$((tries+1))
      sleep "$(_ta_backoff "$tries")"
    done
    if [ "$rc" != 0 ]; then
      if [ "$rc" = 75 ] && [ "$(cat "$pf.reason" 2>/dev/null)" = bad-args ]; then
        PROJECT_2_NOTE="gh_rest refused repos/$slug/issues/$n"; rm -f "$pf" "$pf.reason" "$pf.status" "$hits"; return 3
      fi
      if [ "$rc" = 75 ] && [ "$(cat "$pf.status" 2>/dev/null)" = 401 ]; then
        PROJECT_2_NOTE="token-401 events page $pg (GitHub answered 401: this machine's token is dead, not the ticket)"
      else
        PROJECT_2_NOTE="events page $pg rc=$rc $(cat "$pf.reason" 2>/dev/null)"
      fi
      [ "$tries" -gt 0 ] && PROJECT_2_NOTE="$PROJECT_2_NOTE (after $tries retries)"
      rm -f "$pf" "$pf.reason" "$pf.status" "$hits"; return 2
    fi
    [ "$tries" -gt 0 ] && PROJECT_2_READ_NOTE="${PROJECT_2_READ_NOTE:+$PROJECT_2_READ_NOTE, }events page $pg retried $tries"
    cnt=$(jq -e 'if type == "array" then length else error("not a list") end' "$pf" 2>/dev/null) \
      || { PROJECT_2_NOTE="events page $pg is not a JSON list"; rm -f "$pf" "$pf.reason" "$pf.status" "$hits"; return 2; }
    jq -c '.[] | select(.event == "labeled" and (.label.name // "") == "ai-build")' "$pf" >> "$hits" 2>/dev/null
    [ "$cnt" -ge 100 ] || break
    pg=$((pg+1))
  done
  rm -f "$pf" "$pf.reason" "$pf.status"
  if [ "$pg" -gt "$PROJECT_2_EVENT_PAGES" ]; then
    PROJECT_2_NOTE="events cap: $PROJECT_2_EVENT_PAGES full pages read"; rm -f "$hits"; return 2
  fi
  jq -rs 'sort_by([((.created_at // "1970-01-01T00:00:00Z") | fromdateiso8601), (.id // 0)]) | last // empty
          | [(.id|tostring), (.actor.login // ""), (.actor.type // ""), (.performed_via_github_app.slug // ""), (.created_at // "")] | @tsv' \
    "$hits" > "$out" 2>/dev/null || { PROJECT_2_NOTE="events unparseable"; rm -f "$hits"; return 2; }
  rm -f "$hits"
  return 0
}

# THE RE-ARM (BH-6957): an explicit human comment newer than an ignored label
# lets the build start, so the pool's pre-spawn check (bin/lib/pool-actor-gate.sh)
# and the builder answer the same. The vocabulary is the twin of POOL_REARM_RE /
# POOL_REARM_NEG_RE in bin/fly-pool.sh: SHORT, EXPLICIT, CAPITALISED, and a
# negation or condition in front of the word is not an instruction. Lower case
# is harness prose and never re-arms, so _ta_post's comment must never carry
# one of these words in capitals (a PAT-posted copy would re-arm itself).
PROJECT_2_REARM_RE='(?<![A-Za-z])(RETRY|REBUILD|RESUME|UNHOLD)(?![A-Za-z])'
PROJECT_2_REARM_NEG_RE='(?i:(?<![A-Za-z])(not|never|don\x27?t|do\s+not|until|unless|before|once|if|when)(\W+\w+){0,3}\W+(retry|rebuild|resum|unhold))'

# _ta_rearm_at <slug> <num> <since> <out> — the issue comments created after
# <since> (the ignored label's created_at) whose author is not a Bot and whose
# body is a re-arm, newest first, as `id<TAB>login<TAB>type<TAB>app_slug`.
# Who may re-arm is ta_decide's answer on the author, asked by ta_gate.
#   rc 0 read (empty <out> = none), rc 2 not read (PROJECT_2_REARM_NOTE says why).
# Read in the identity-arming subshell shape of ta_gh_trigger, one try a page.
_ta_rearm_at() {
  local slug="$1" n="$2" since="$3" out="$4" pg=1 rc cnt pf hits
  : > "$out"; PROJECT_2_REARM_NOTE=""
  [ -n "$since" ] || { PROJECT_2_REARM_NOTE="the label event has no created_at"; return 2; }
  command -v gh_rest >/dev/null 2>&1 || { PROJECT_2_REARM_NOTE="gh-rest lib missing"; return 2; }
  pf="$out.page"; hits="$out.hits"; : > "$hits"
  while [ "$pg" -le "$PROJECT_2_EVENT_PAGES" ]; do
    rc=0
    ( command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$slug" >/dev/null 2>&1
      r=0; gh_rest GET "repos/$slug/issues/$n/comments?per_page=100&since=$since&page=$pg" > "$pf" 2>/dev/null || r=$?
      printf '%s' "${GH_REST_REASON:-}" > "$pf.reason"; exit "$r" ) || rc=$?
    if [ "$rc" != 0 ]; then
      PROJECT_2_REARM_NOTE="comments page $pg rc=$rc $(cat "$pf.reason" 2>/dev/null)"
      rm -f "$pf" "$pf.reason" "$hits"; return 2
    fi
    cnt=$(jq -e 'if type == "array" then length else error("not a list") end' "$pf" 2>/dev/null) \
      || { PROJECT_2_REARM_NOTE="comments page $pg is not a JSON list"; rm -f "$pf" "$pf.reason" "$hits"; return 2; }
    jq -c --arg since "$since" --arg re "$PROJECT_2_REARM_RE" --arg neg "$PROJECT_2_REARM_NEG_RE" '
      ($since | fromdateiso8601) as $s
      | .[] | select(type == "object")
      | select(((.created_at // "") | (try fromdateiso8601 catch 0)) > $s)
      | select((((.user // {}).type // "") | tostring | ascii_downcase) != "bot")
      | select(((.body // "") | tostring) | test($re))
      | select((((.body // "") | tostring) | test($neg)) | not)' "$pf" >> "$hits" 2>/dev/null \
      || { PROJECT_2_REARM_NOTE="comments page $pg unparseable"; rm -f "$pf" "$pf.reason" "$hits"; return 2; }
    [ "$cnt" -ge 100 ] || break
    pg=$((pg+1))
  done
  rm -f "$pf" "$pf.reason"
  if [ "$pg" -gt "$PROJECT_2_EVENT_PAGES" ]; then
    PROJECT_2_REARM_NOTE="comments cap: $PROJECT_2_EVENT_PAGES full pages read"; rm -f "$hits"; return 2
  fi
  jq -rs 'sort_by([((.created_at // "1970-01-01T00:00:00Z") | fromdateiso8601), (.id // 0)]) | reverse | .[]
          | [(.id|tostring), ((.user // {}).login // ""), ((.user // {}).type // ""), (.performed_via_github_app.slug // "")] | @tsv' \
    "$hits" > "$out" 2>/dev/null || { PROJECT_2_REARM_NOTE="comments unparseable"; rm -f "$hits"; return 2; }
  rm -f "$hits"
  return 0
}

# ta_board_trigger <raw-ticket-json> <out> — the newest status_change of an
# in-app ticket as `id<TAB>userId<TAB>name`, or an empty <out>. Ordered by
# createdAt (or created_at / at); entries without a time keep array order.
# No `activity` array at all -> empty <out> and PROJECT_2_NOTE=no-activity.
ta_board_trigger() {
  local raw="$1" out="$2"
  : > "$out"
  if ! jq -e '(.activity // .ticket.activity) | type == "array"' "$raw" >/dev/null 2>&1; then
    PROJECT_2_NOTE=no-activity; return 0
  fi
  jq -r '(.activity // .ticket.activity) | to_entries
         | map(select(.value.type == "status_change"))
         | sort_by([(.value.createdAt // .value.created_at // .value.at // ""), .key]) | last // empty | .value
         | [(.id // "" | tostring),
            (if (.actor|type) == "object" then (.actor.userId // "") else "" end | tostring),
            (if (.actor|type) == "object" then (.actor.name // "") elif (.actor|type) == "string" then .actor else "" end)] | @tsv' \
    "$raw" > "$out" 2>/dev/null || { : > "$out"; return 2; }
  return 0
}

_ta_detail() { # _ta_detail <event> <actor> <why> <source> <commented>
  jq -nc --arg e "$1" --arg a "$2" --arg w "$3" --arg s "$4" --arg c "$5" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{event:$e, actor:$a, why:$w, source:$s, commented:$c, at:$t}'
}

_ta_html() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

# _ta_post <source> <slug|prefix> <ticket> <actor> <build> — rc 0 posted.
_ta_post() {
  local src="$1" where="$2" t="$3" actor="$4" b="$5" r f prod tok resp
  r=$(_ta_root)
  if [ "$src" = gh ]; then
    f="$b/trigger-actor-comment.md"
    printf '%s\n' "We didn't start a build for this one. The \`ai-build\` label was added by \`$actor\`, and only the people on this project's trigger list (or the harness itself) can start a build. If it should be built, someone on the list can take the label off and put it back." > "$f" || return 1
    ( command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$where" >/dev/null 2>&1
      gh_rest_comment "$where" "$t" "$f" ) >/dev/null 2>&1
    return $?
  fi
  prod=$("$r/bin/fleet-conf.sh" "$PROJECT_2_P" prod 2>/dev/null) || prod=""
  tok=$("$r/bin/internal-token-for.sh" "$PROJECT_2_P" 2>/dev/null) || tok=""
  [ -n "$prod" ] && [ "$prod" != - ] && [ -n "$tok" ] || return 1
  resp=$(curl -s --max-time 25 -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -H "User-Agent: curl/8" \
    -X POST -d "$(jq -nc --arg b "<p>We didn't start a build for this one. The last status change was made by $(_ta_html "$actor"), who isn't on this project's list of people who can start a build. If it should be built, someone on the list can move it again.</p>" '{body:$b}')" \
    "$prod$where/tickets/$t/comments" 2>/dev/null) || return 1
  printf '%s' "$resp" | jq -e '(.comment // .id // .data) != null' >/dev/null 2>&1
}

# ta_record <p> <KEY> <ticket> <source> <slug-or-prefix> <event> <actor> <why> <build>
#   The ignore path: claim, comment once, record. rc 0 recorded (PROJECT_2_COMMENTED
#   1 when this call posted the comment), rc 2 unverifiable (nothing posted).
ta_record() {
  local p="$1" k="$2" t="$3" src="$4" where="$5" ev="$6" actor="$7" why="$8" b="$9"
  local r fd row rc=0 st prev cm
  PROJECT_2_COMMENTED=0
  r=$(_ta_root); [ -n "$r" ] || { PROJECT_2_NOTE="no harness root"; return 2; }
  command -v job_ledger_row >/dev/null 2>&1 && command -v job_ledger_put >/dev/null 2>&1 \
    || { PROJECT_2_NOTE="no ledger client"; return 2; }
  mkdir -p "$r/locks" 2>/dev/null
  exec {fd}>"$r/locks/trigger-actor-$p-$k.lock" || { PROJECT_2_NOTE="lock unwritable"; return 2; }
  if ! flock -n "$fd"; then exec {fd}>&-; PROJECT_2_NOTE="lock busy"; return 2; fi
  row=$(job_ledger_row trigger-actor "$p $k" 2>/dev/null) || rc=$?
  if [ "$rc" = 1 ]; then exec {fd}>&-; PROJECT_2_NOTE="ledger unreadable"; return 2; fi
  st=""; prev=""
  [ "$rc" = 0 ] && { st=$(printf '%s' "$row" | jq -r '.status // ""' 2>/dev/null); prev=$(printf '%s' "$row" | jq -r '.detail | (fromjson? // {}) | .commented // ""' 2>/dev/null); }
  if [ "$st" = ignored ]; then
    # A repeat, or another untrusted trigger in the same episode: no comment.
    job_ledger_put trigger-actor "$p $k" ignored "$(_ta_detail "$ev" "$actor" "$why" "$src" "${prev:-yes}")" >/dev/null 2>&1 \
      || PROJECT_2_NOTE="detail refresh failed"
    exec {fd}>&-; return 0
  fi
  job_ledger_put trigger-actor "$p $k" ignored "$(_ta_detail "$ev" "$actor" "$why" "$src" pending)" >/dev/null 2>&1 \
    || { exec {fd}>&-; PROJECT_2_NOTE="ledger claim failed"; return 2; }
  if PROJECT_2_P="$p" _ta_post "$src" "$where" "$t" "$actor" "$b"; then cm=yes; PROJECT_2_COMMENTED=1
  else cm=failed; PROJECT_2_NOTE="comment post failed, not retried"; fi
  job_ledger_put trigger-actor "$p $k" ignored "$(_ta_detail "$ev" "$actor" "$why" "$src" "$cm")" >/dev/null 2>&1 || true
  exec {fd}>&-
  return 0
}

# _ta_allowed <p> <KEY> <source> <event> <actor> <why> — an allowed trigger
# closes an open ignore episode. No row, or any other row: nothing written.
_ta_allowed() {
  local row st
  command -v job_ledger_row >/dev/null 2>&1 || return 0
  row=$(job_ledger_row trigger-actor "$1 $2" 2>/dev/null) || return 0
  st=$(printf '%s' "$row" | jq -r '.status // ""' 2>/dev/null)
  [ "$st" = ignored ] || return 0
  job_ledger_put trigger-actor "$1 $2" allowed "$(_ta_detail "$4" "$5" "$6" "$3" -)" >/dev/null 2>&1 || true
}

# ta_gate <p> <KEY> <ticket> <build> — the whole decision for one build.
#   rc 0 build (PROJECT_2_LINE = `allow <why> actor=<a> event=<id>`), rc 1 ignored
#   (commented once, recorded), rc 2 unverifiable (PROJECT_2_LINE says why).
ta_gate() {
  local p="$1" k="$2" t="${3:-}" b="$4" r bp n slug f dec why id actor typ app lat uid name self prod tok rc src where
  local cid clogin ctyp capp rearm_note=""
  PROJECT_2_LINE=""; PROJECT_2_NOTE=""; PROJECT_2_READ_NOTE=""; PROJECT_2_COMMENTED=0
  _ta_deps || { PROJECT_2_LINE="no harness root"; return 2; }
  r=$(_ta_root)
  command -v lane_switch >/dev/null 2>&1 || { PROJECT_2_LINE="lane-switch lib missing, the trigger-actor-off switch cannot be read"; return 2; }
  if lane_switch trigger-actor-off; then PROJECT_2_LINE="allow switched-off (lane_switch trigger-actor-off)"; return 0; fi
  ta_allowlist "$p"
  if [ "$PROJECT_2_ROW" = unreadable ]; then PROJECT_2_LINE="allowlist row trigger.actors.$p unreadable${PROJECT_2_NOTE:+: $PROJECT_2_NOTE}"; return 2; fi
  bp=$("$r/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || bp=""
  f="$b/trigger-actor.tsv"
  if [ "$bp" = - ]; then
    [ -n "${HARNESS_SELF_JQ_DEF:-}" ] || { PROJECT_2_LINE="harness-self lib missing, the harness's own identity cannot be told"; return 2; }
    # An EMPTY list is the same blindness: harness-self.sh resolves nothing to
    # `[]` (fail-open for its other readers), and here `[]` would read our own
    # App's label as a foreign bot, refused with a public comment.
    case "$(harness_self_apps_json 2>/dev/null)" in
      ''|'[]') PROJECT_2_LINE="harness self-app list empty (HARNESS_SELF_APPS unresolved, catalog/lanes.json?), the harness's own identity cannot be told"; return 2 ;;
    esac
    n=$(printf '%s' "$k" | sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p')
    [ -n "$n" ] || case "$t" in ''|*[!0-9]*) ;; *) n="$t" ;; esac
    slug="${GH_ISSUES_REPO:-$("$r/bin/fleet-conf.sh" "$p" repo 2>/dev/null || true)}"
    if [ -z "$n" ] || [ -z "$slug" ]; then PROJECT_2_LINE="allow no-trigger (no issue number or repo for $k)"; return 0; fi
    rc=0; ta_gh_trigger "$slug" "$n" "$f" || rc=$?
    case "$rc" in
      0) ;;
      3) PROJECT_2_LINE="allow no-trigger (${PROJECT_2_NOTE})"; return 0 ;;
      *) PROJECT_2_LINE="events read: ${PROJECT_2_NOTE:-failed}"; return 2 ;;
    esac
    if [ ! -s "$f" ]; then PROJECT_2_LINE="allow no-trigger (no labeled ai-build event on $slug#$n)"; return 0; fi
    # A tab is an IFS whitespace character, so `read` would fold an empty
    # app_slug and shift created_at into it: split on \037 instead.
    IFS=$'\037' read -r id actor typ app lat < <(tr '\t' '\037' < "$f")
    dec=$(ta_decide "$p" gh "$actor" "" "$typ" "$app" "")
    src=gh; where="$slug"; t="$n"
    # An ignored label stands unless a newer explicit re-arm comment comes from
    # someone ta_decide allows as a person (never `self`: the harness cannot
    # re-arm itself). A comments read that fails keeps the ignore.
    case "$dec" in
      ignore*)
        if _ta_rearm_at "$slug" "$n" "$lat" "$f.rearm"; then
          while IFS=$'\037' read -r cid clogin ctyp capp; do
            [ -n "$cid" ] || continue
            case "$(ta_decide "$p" gh "$clogin" "" "$ctyp" "$capp" "")" in
              "allow listed"|"allow human-default") id="comment-$cid"; actor="$clogin"; dec="allow rearm"; break ;;
            esac
          done < <(tr '\t' '\037' < "$f.rearm")
        else
          rearm_note="re-arm read: $PROJECT_2_REARM_NOTE"
        fi
        rm -f "$f.rearm" ;;
    esac
  elif [ -n "$bp" ]; then
    if [ "$PROJECT_2_ROW" != armed ]; then PROJECT_2_LINE="allow unarmed (no trigger.actors.$p row, in-app board not read)"; return 0; fi
    prod=$("$r/bin/fleet-conf.sh" "$p" prod 2>/dev/null) || prod=""
    tok=$("$r/bin/internal-token-for.sh" "$p" 2>/dev/null) || tok=""
    if [ -z "$prod" ] || [ "$prod" = - ] || [ -z "$tok" ] || [ -z "$t" ]; then
      PROJECT_2_LINE="board read: no prod origin, token or ticket id for $p"; return 2
    fi
    curl -s --fail --max-time 25 -H "Authorization: Bearer $tok" -H "User-Agent: curl/8" \
      -o "$f.raw" "$prod$bp/tickets/$t" 2>/dev/null && jq -e 'type == "object"' "$f.raw" >/dev/null 2>&1 \
      || { rm -f "$f.raw"; PROJECT_2_LINE="board read of ticket $t failed"; return 2; }
    ta_board_trigger "$f.raw" "$f" || { rm -f "$f.raw"; PROJECT_2_LINE="board activity unparseable"; return 2; }
    rm -f "$f.raw"
    if [ ! -s "$f" ]; then
      PROJECT_2_LINE="allow no-trigger (${PROJECT_2_NOTE:-no status_change on ticket $t})"; return 0
    fi
    IFS=$'\t' read -r id uid name < "$f"
    self=$(ta_self_names "$p")
    dec=$(ta_decide "$p" board "$uid" "$name" "" "" "$self")
    actor="${name:-$uid}"; src=board; where="$bp"
  else
    PROJECT_2_LINE="allow no-board (no board_prefix for $p)"; return 0
  fi
  why="${dec#* }"
  case "$dec" in
    allow*)
      _ta_allowed "$p" "$k" "$src" "$id" "$actor" "$why"
      PROJECT_2_LINE="allow $why actor=$actor event=$id${PROJECT_2_NOTE:+ ($PROJECT_2_NOTE)}${PROJECT_2_READ_NOTE:+ ($PROJECT_2_READ_NOTE)}"; return 0 ;;
  esac
  rc=0; ta_record "$p" "$k" "$t" "$src" "$where" "$id" "$actor" "$why" "$b" || rc=$?
  if [ "$rc" != 0 ]; then PROJECT_2_LINE="outcome record: ${PROJECT_2_NOTE:-failed}"; return 2; fi
  if [ "$PROJECT_2_COMMENTED" = 1 ]; then
    PROJECT_2_LINE="ignored $why actor=$actor event=$id — commented once, recorded in ledger trigger-actor \"$p $k\""
  else
    PROJECT_2_LINE="ignored $why actor=$actor event=$id — no new comment (${PROJECT_2_NOTE:-same episode, already commented}), recorded in ledger trigger-actor \"$p $k\""
  fi
  [ -z "$rearm_note" ] || PROJECT_2_LINE="$PROJECT_2_LINE ($rearm_note)"
  return 1
}
