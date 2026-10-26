#!/bin/bash
# bin/lib/tracker/linear.sh — the Linear adapter of the tracker contract
# (bin/lib/tracker.sh, BH-4077). Functions trk_linear_*. Every call is one POST
# of {query, variables} to Linear's GraphQL API.
#
# Sourced, never executed: no `set -e`, no `exit`, nothing at source time.
#
# CONTEXT (variables the caller sets, or trk_linear_context <project> below):
#   TRK_LINEAR_TOKEN      a Linear personal API key, sent as `Authorization: <key>`
#                         (no Bearer). Only ever on curl's argv.
#   TRK_LINEAR_TOKEN_VAR  its variable NAME, which is what a log shows
#   TRK_LINEAR_TEAM       the team key (CRO), for list only
#   TRK_LINEAR_API        default https://api.linear.app/graphql
#   TRK_LINEAR_LABEL      the label list filters on, default ai-build
#   TRK_LINEAR_STATES     optional JSON {"<contract status>": "<state name>"}
#   TRK_LINEAR_LIST_COMMENT_CAP  the comment ids one list row asks for, to
#                         count them (1..50; empty = 25, see trk_linear_list)
#
# IDS. A ticket id is the Linear identifier (CRO-12) or the issue UUID; id and
# key are both the identifier. A mutation needs the UUID and the team's states
# and labels, so every write reads the issue first (_trk_linear_issue). That
# read is sent even under TRK_DRY=1: reads are always sent.
#
# STATUS. transition takes todo|in_progress|review|done|closed. A name in
# TRK_LINEAR_STATES wins (case-insensitive; a name the team has no state for is
# rc 1, never a fallback). Otherwise by Linear state TYPE, lowest position
# first: todo=unstarted, in_progress=started, done=completed, closed=canceled,
# and review is the state named "In Review" (Linear's default). close_out moves
# to done unless told otherwise.
#
# What Linear does not have, the adapter says so: waitingOn and triageVerdict
# are null and no comment is internal. link_pr is a real attachment
# (attachmentLinkURL), which Linear de-duplicates by URL on the issue. Labels
# are never created: a name with no workspace or team label is rc 1.
#
# RETURN CODES are the contract's. A 429, a 5xx, no answer, or a RATELIMITED
# error (Linear sends it on a 400) is 75. Any other 4xx, a 200 whose `errors`
# is not empty (Entity not found), or a mutation that answered success:false is 1.

_TRK_LINEAR_STATUS_TYPE='{"todo":"unstarted","in_progress":"started","done":"completed","closed":"canceled"}'

_trk_linear_blank() {
  TRK_LINEAR_TOKEN=""; TRK_LINEAR_TOKEN_VAR=""; TRK_LINEAR_TEAM=""; TRK_LINEAR_LABEL=""; TRK_LINEAR_STATES=""
  TRK_LINEAR_LIST_COMMENT_CAP=""
}

# trk_linear_context <project> — the twin of trk_jira_context. It reads:
#   <env dir>/<project>.env   LINEAR_API_KEY (required), LINEAR_TEAM,
#                             LINEAR_LABEL, LINEAR_STATES (in a subshell;
#                             nothing else from it survives)
#   settings rows tracker_linear.<project>.team|label|states, all optional. A
#     row wins over the env value. A row team and an env team that disagree is
#     rc 1: a wrong team lists another team's tickets. Under TRK_DRY=1 no row
#     is read (the tracker_adapter contract), so the env values decide.
#   settings row tracker_linear.<project>.list_comment_cap, optional: an
#     integer 1..50, else rc 1. It sets TRK_LINEAR_LIST_COMMENT_CAP.
# rc 0 with TRK_LINEAR_TOKEN, TRK_LINEAR_TOKEN_VAR=LINEAR_API_KEY,
# TRK_LINEAR_TEAM and (when set) TRK_LINEAR_LABEL / TRK_LINEAR_STATES /
# TRK_LINEAR_LIST_COMMENT_CAP. rc 1
# with every one of them blank and one stderr line that names the variable or
# the row, never a value. TRK_LINEAR_API is left alone.
trk_linear_context() {
  local p="${1:-}" root="${HARNESS:-${H:-}}" d ep envd="" ef jc rows k v n r
  local tok team label states rteam="" rlabel="" rstates="" rcap="" got=0
  local vals=()
  _trk_linear_blank
  [[ "$p" =~ ^[a-z0-9_.-]+$ ]] || { printf 'linear: %s is not a project name\n' "$(_trk_sq "$p")" >&2; return 1; }
  [ -n "$root" ] || { printf 'linear: no harness root (HARNESS) for %s\n' "$p" >&2; return 1; }
  d="$(dirname "${BASH_SOURCE[0]}")"
  ep="$d/../env-path.sh"; [ -r "$ep" ] || ep="$root/bin/lib/env-path.sh"
  if [ -r "$ep" ]; then
    # shellcheck source=/dev/null
    envd=$( . "$ep" && harness_env_dir "$root" ) || envd=""
  fi
  [ -n "$envd" ] || envd="$root/env"
  ef="$envd/$p.env"
  [ -r "$ef" ] || { printf 'linear: %s has no env file %s\n' "$p" "$ef" >&2; return 1; }
  # shellcheck source=/dev/null
  mapfile -t vals < <( unset LINEAR_API_KEY LINEAR_TEAM LINEAR_LABEL LINEAR_STATES
                       set -a; . "$ef" >/dev/null 2>&1; set +a
                       printf '%s\n' "${LINEAR_API_KEY:-}" "${LINEAR_TEAM:-}" "${LINEAR_LABEL:-}" \
                         "$(printf '%s' "${LINEAR_STATES:-}" | tr '\n\t' '  ')" )
  tok="${vals[0]:-}"; team="${vals[1]:-}"; label="${vals[2]:-}"; states="${vals[3]:-}"
  [ -n "$tok" ] || { printf 'linear: %s sets no LINEAR_API_KEY\n' "$ef" >&2; return 1; }

  if ! _trk_dry; then
    jc="$d/../../jobs-client.sh"; [ -r "$jc" ] || jc="$root/bin/jobs-client.sh"
    [ -r "$jc" ] || { printf 'linear: no bin/jobs-client.sh to read the %s settings rows\n' "$p" >&2; return 1; }
    # ONE subshell for every row, as trk_jira_context does.
    # shellcheck source=/dev/null
    rows=$( HARNESS="$root"; . "$jc" >/dev/null 2>&1 || exit 1
            for n in team label states list_comment_cap; do
              r=0; v=$(JOBS_ALERT=0 setting_get "tracker_linear.$p.$n" 2>/dev/null) || r=$?
              case "$r" in
                0) printf '%s\t%s\n' "$n" "$(printf '%s' "$v" | tr '\t\n' '  ')" ;;
                2) ;;
                *) exit 1 ;;
              esac
            done ) \
      || { printf 'linear: the settings rows tracker_linear.%s.* could not be read\n' "$p" >&2; return 1; }
    while IFS=$'\t' read -r k v; do
      case "$k" in
        team) rteam="$v"; got=1 ;;
        label) rlabel="$v" ;;
        states) rstates="$v" ;;
        list_comment_cap) rcap="$v" ;;
      esac
    done <<<"$rows"
  fi
  if [ -n "$rcap" ] && ! { [[ "$rcap" =~ ^[0-9]{1,2}$ ]] && [ "$rcap" -ge 1 ] && [ "$rcap" -le 50 ]; }; then
    printf 'linear: settings row tracker_linear.%s.list_comment_cap is not an integer 1..50\n' "$p" >&2; return 1
  fi
  if [ "$got" = 1 ]; then
    [[ "$rteam" =~ ^[A-Z][A-Z0-9_]{0,9}$ ]] || { printf 'linear: settings row tracker_linear.%s.team is not a Linear team key\n' "$p" >&2; return 1; }
    if [ -n "$team" ] && [ "$team" != "$rteam" ]; then
      printf 'linear: settings row tracker_linear.%s.team and LINEAR_TEAM in %s name different teams\n' "$p" "$ef" >&2
      return 1
    fi
    team="$rteam"
  fi
  [ -n "$rlabel" ] && label="$rlabel"
  [ -n "$rstates" ] && states="$rstates"
  [[ "$team" =~ ^[A-Z][A-Z0-9_]{0,9}$ ]] || { printf 'linear: %s has no Linear team key (LINEAR_TEAM or tracker_linear.%s.team)\n' "$ef" "$p" >&2; return 1; }
  if [ -n "$label" ] && ! [[ "$label" =~ ^[A-Za-z0-9_.:-]{1,100}$ ]]; then
    printf 'linear: the label for %s (LINEAR_LABEL or tracker_linear.%s.label) is not a label\n' "$p" "$p" >&2; return 1
  fi
  if [ -n "$states" ] && ! printf '%s' "$states" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'linear: the states for %s (LINEAR_STATES or tracker_linear.%s.states) are not a JSON object\n' "$p" "$p" >&2; return 1
  fi
  TRK_LINEAR_TOKEN="$tok"; TRK_LINEAR_TOKEN_VAR=LINEAR_API_KEY; TRK_LINEAR_TEAM="$team"
  TRK_LINEAR_LABEL="$label"; TRK_LINEAR_STATES="$states"; TRK_LINEAR_LIST_COMMENT_CAP="$rcap"
  return 0
}

_trk_linear_ok() { # _trk_linear_ok <id> — a key to send and a well-formed id
  [ -n "${TRK_LINEAR_TOKEN:-}" ] || return 1
  [[ "${1:-}" =~ ^[A-Za-z0-9]+-[0-9]+$ || "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# _trk_linear_w <mutation> <detail> — the logged form of a write: the mutation,
# its non-secret variables, the key's variable name. Never the key or a body.
_trk_linear_w() { _trk_logw "linear graphql $1 $2 auth=\$${TRK_LINEAR_TOKEN_VAR:-TOKEN}"; }

# _trk_linear_gql <query> <variables jq expr> [jq args…] — the one HTTP call.
# The request body is built by jq (so a --rawfile body never rides argv) into
# TRK_REQ_FILE or a temp file. `.data` on stdout, rc per the table above.
_trk_linear_gql() {
  local q="$1" expr="$2" req resp code rc=0 msg
  shift 2
  [ -n "${TRK_LINEAR_TOKEN:-}" ] || return 1
  if [ -n "${TRK_REQ_FILE:-}" ]; then req="$TRK_REQ_FILE"
  else req=$(mktemp "${TMPDIR:-/tmp}/trk-linear.XXXXXX") || return 1; fi
  resp=$(mktemp "${TMPDIR:-/tmp}/trk-linear.XXXXXX") || { [ -n "${TRK_REQ_FILE:-}" ] || rm -f "$req"; return 1; }
  if ! jq -n --arg q "$q" "$@" "{query: \$q, variables: ($expr)}" > "$req" 2>/dev/null; then
    [ -n "${TRK_REQ_FILE:-}" ] || rm -f "$req"; rm -f "$resp"; return 1
  fi
  code=$(curl -sS --max-time 30 -X POST -H "Content-Type: application/json" \
    -H "Authorization: $TRK_LINEAR_TOKEN" --data-binary "@$req" -o "$resp" -w '%{http_code}' \
    "${TRK_LINEAR_API:-https://api.linear.app/graphql}" 2>>"${TRK_ERR:-/dev/null}") || code=000
  [ -n "${TRK_REQ_FILE:-}" ] || rm -f "$req"
  case "$code" in
    2??) ;;
    429|5??|000) rc=75 ;;
    *) rc=1 ;;
  esac
  jq -e 'any((.errors // [])[]?; .extensions.code == "RATELIMITED")' "$resp" >/dev/null 2>&1 && rc=75
  if [ "$rc" = 0 ] && ! jq -e '(.errors // []) == [] and (.data | type == "object")' "$resp" >/dev/null 2>&1; then rc=1; fi
  if [ "$rc" != 0 ]; then
    msg=$(jq -r '[(.errors // [])[]?.message] | join("; ")' "$resp" 2>/dev/null)
    printf 'tracker: linear answered HTTP %s%s\n' "$code" "${msg:+: $msg}" >> "${TRK_ERR:-/dev/null}"
    rm -f "$resp"; return "$rc"
  fi
  jq -c '.data' "$resp"
  rm -f "$resp"
  return 0
}

# _trk_linear_issue <id> — the issue as a mutation needs it: UUID, labels, team
# key and the team's workflow states. Compact JSON, or the call's rc.
_trk_linear_issue() {
  local d
  _trk_linear_ok "${1:-}" || return 1
  d=$(_trk_linear_gql 'query TrkIssueMeta($id: String!) { issue(id: $id) { id identifier state { id } labels(first: 250) { nodes { id name } } team { key states(first: 100) { nodes { id name type position } } } } }' \
    '{id: $id}' --arg id "$1") || return $?
  printf '%s' "$d" | jq -ce '.issue | select(type == "object" and (.id | type == "string" and length > 0))' 2>/dev/null || return 1
}

# trk_linear_list — the team's issues with the label, at most 10 pages of 100.
# The filter is built from parts: the team; the label (TRK_LIST_LABEL, else
# TRK_LINEAR_LABEL, else ai-build); the open states unless TRK_LIST_STATE=all;
# and `updatedAt >= $since` only when TRK_LIST_SINCE is set, which is the only
# time $since is declared (GraphQL refuses a declared variable it does not
# use). commentCount is the number of comment ids on the row's first page, or
# null when that page has more: no count we did not measure.
# THE COMMENT CAP is a knob: settings row tracker_linear.<p>.list_comment_cap
# (trk_linear_context), fallback 25. 25, and the bound of 50, keep
# issues(first: 100) x (labels(first: 50) + comments) under Linear's 10,000
# point query complexity limit; the nightly vendor contract suite checks it.
trk_linear_list() {
  local d all after=null page=0 more=true cc q sf uf decl=""
  [[ "${TRK_LINEAR_TEAM:-}" =~ ^[A-Za-z0-9_]{1,16}$ ]] && [ -n "${TRK_LINEAR_TOKEN:-}" ] || return 1
  cc="${TRK_LINEAR_LIST_COMMENT_CAP:-25}"   # fallback of settings row tracker_linear.<p>.list_comment_cap
  if ! [[ "$cc" =~ ^[0-9]{1,2}$ ]] || [ "$cc" -lt 1 ] || [ "$cc" -gt 50 ]; then
    printf 'tracker: linear list comment cap %s is not 1..50 (tracker_linear.<p>.list_comment_cap)\n' "$(_trk_sq "$cc")" >&2
    return 1
  fi
  sf=', state: { type: { nin: ["completed", "canceled"] } }'
  [ "${TRK_LIST_STATE:-}" = all ] && sf=""
  uf=""
  if [ -n "${TRK_LIST_SINCE:-}" ]; then uf=', updatedAt: { gte: $since }'; decl=', $since: DateTimeOrDuration'; fi
  q="query TrkIssues(\$team: String!, \$label: String!, \$after: String, \$cc: Int!$decl) { issues(first: 100, after: \$after, filter: { team: { key: { eq: \$team } }, labels: { some: { name: { eqIgnoreCase: \$label } } }$sf$uf }) { nodes { identifier title url updatedAt state { name type } labels(first: 50) { nodes { name } } comments(first: \$cc) { nodes { id } pageInfo { hasNextPage } } } pageInfo { hasNextPage endCursor } } }"
  all='[]'
  while [ "$more" = true ]; do
    if [ "$page" -ge 10 ]; then
      printf 'tracker: linear list for team %s still has pages after %s, incomplete\n' "$TRK_LINEAR_TEAM" "$page" >&2
      return 1
    fi
    d=$(_trk_linear_gql "$q" \
      '{team: $team, label: $label, after: $after, cc: $cc} + (if $since == "" then {} else {since: $since} end)' \
      --arg team "$TRK_LINEAR_TEAM" --arg label "${TRK_LIST_LABEL:-${TRK_LINEAR_LABEL:-ai-build}}" --argjson after "$after" \
      --argjson cc "$cc" --arg since "${TRK_LIST_SINCE:-}") || return $?
    all=$(printf '%s' "$d" | jq -ce --argjson a "$all" '.issues.nodes as $n | if ($n | type) == "array" then $a + $n else error end' 2>/dev/null) || return 1
    more=$(printf '%s' "$d" | jq -r '.issues.pageInfo.hasNextPage == true')
    after=$(printf '%s' "$d" | jq -c '.issues.pageInfo.endCursor // null')
    [ "$more" = true ] && [ "$after" = null ] && return 1
    page=$((page+1))
  done
  printf '%s' "$all" | jq -c "${_TRK_ISO_JQ:-}"'[.[] | {id: .identifier, key: .identifier, title: (.title // ""),
    status: (.state.name // null), labels: [(.labels.nodes // [])[].name], waitingOn: null,
    triageVerdict: null, url: (.url // null), updatedAt: (.updatedAt | trk_iso),
    state: (if (.state.type // "") == "completed" or (.state.type // "") == "canceled" then "closed" else "open" end),
    commentCount: (if (.comments | type) != "object" or (.comments.nodes | type) != "array" or .comments.pageInfo.hasNextPage == true
                   then null else (.comments.nodes | length) end)}]'
}

# trk_linear_read <id> — the issue and its whole thread, oldest comment first.
# A thread longer than one page is a PARTIAL read and answers 1.
trk_linear_read() {
  local d
  _trk_linear_ok "${1:-}" || return 1
  d=$(_trk_linear_gql 'query TrkIssue($id: String!) { issue(id: $id) { identifier title description url state { name type } labels(first: 250) { nodes { name } } comments(first: 250) { nodes { body createdAt user { name displayName } botActor { name } } pageInfo { hasNextPage } } } }' \
    '{id: $id}' --arg id "$1") || return $?
  if printf '%s' "$d" | jq -e '.issue.comments.pageInfo.hasNextPage == true' >/dev/null 2>&1; then
    printf 'tracker: linear %s has more than 250 comments, the thread was not read to the end\n' "$1" >&2
    return 1
  fi
  printf '%s' "$d" | jq -ce '.issue | select(type == "object") | {id: .identifier, key: .identifier,
    title: (.title // ""), body: (.description // ""), status: (.state.name // null),
    state: (if (.state.type // "") == "completed" or (.state.type // "") == "canceled" then "closed" else "open" end),
    labels: [(.labels.nodes // [])[].name], waitingOn: null, triageVerdict: null, url: (.url // null),
    comments: [(.comments.nodes // []) | sort_by(.createdAt)[] | {
      author: (.user.displayName // .user.name // .botActor.name // null), body: (.body // ""),
      createdAt: (.createdAt // null), internal: false}]}' 2>/dev/null || return 1
}

trk_linear_comment() {
  local id="${1:-}" f="${2:-}" m d
  _trk_linear_ok "$id" && [ -r "$f" ] || return 1
  m=$(_trk_linear_issue "$id") || return $?
  _trk_linear_w commentCreate "issue=$id body=@$f"
  _trk_dry && return 0
  d=$(_trk_linear_gql 'mutation TrkComment($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success comment { id } } }' \
    '{id: $id, body: $body}' --arg id "$(printf '%s' "$m" | jq -r .id)" --rawfile body "$f") || return $?
  printf '%s' "$d" | jq -e '.commentCreate.success == true and ((.commentCreate.comment.id // "") != "")' >/dev/null 2>&1 || return 1
  return 0
}

# trk_linear_transition <id> <status> — rc 0 only when Linear's answer says the
# issue is now in the target state: a 200 that did not move it is a failure.
trk_linear_transition() {
  local id="${1:-}" s="${2:-}" m want="" sid d
  case "$s" in todo|in_progress|review|done|closed) ;; *) return 3 ;; esac
  _trk_linear_ok "$id" || return 1
  if [ -n "${TRK_LINEAR_STATES:-}" ]; then
    want=$(printf '%s' "$TRK_LINEAR_STATES" | jq -er --arg s "$s" 'if type == "object" then (.[$s] // "") else error end' 2>/dev/null) \
      || { printf 'tracker: TRK_LINEAR_STATES is not a JSON object\n' >&2; return 1; }
  fi
  m=$(_trk_linear_issue "$id") || return $?
  if [ -n "$want" ]; then
    sid=$(printf '%s' "$m" | jq -r --arg w "$want" '[.team.states.nodes[]? | select((.name | ascii_downcase) == ($w | ascii_downcase))] | if length == 1 then .[0].id else empty end')
    [ -n "$sid" ] || { printf 'tracker: linear team %s has no single state named %s (TRK_LINEAR_STATES.%s)\n' "$(printf '%s' "$m" | jq -r '.team.key // "?"')" "$(_trk_sq "$want")" "$s" >&2; return 1; }
  elif [ "$s" = review ]; then
    sid=$(printf '%s' "$m" | jq -r '[.team.states.nodes[]? | select((.name | ascii_downcase) == "in review")] | if length == 1 then .[0].id else empty end')
  else
    sid=$(printf '%s' "$m" | jq -r --arg s "$s" --argjson t "$_TRK_LINEAR_STATUS_TYPE" \
      '[.team.states.nodes[]? | select(.type == $t[$s])] | sort_by(.position) | .[0].id // empty')
  fi
  [ -n "$sid" ] || { printf 'tracker: linear team %s has no state for %s\n' "$(printf '%s' "$m" | jq -r '.team.key // "?"')" "$s" >&2; return 1; }
  _trk_linear_w issueUpdate "issue=$id stateId=$sid status=$s"
  _trk_dry && return 0
  d=$(_trk_linear_gql 'mutation TrkUpdate($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { state { id } } } }' \
    '{id: $id, stateId: $stateId}' --arg id "$(printf '%s' "$m" | jq -r .id)" --arg stateId "$sid") || return $?
  printf '%s' "$d" | jq -e --arg s "$sid" '.issueUpdate.success == true and .issueUpdate.issue.state.id == $s' >/dev/null 2>&1 || return 1
  return 0
}

_trk_linear_label_ok() { [ -n "${1:-}" ] && [ "${#1}" -le 100 ]; }

# trk_linear_label_add <id> <label> — a workspace label, or one of the issue's
# own team. One match exactly; the adapter never creates a label.
trk_linear_label_add() {
  local id="${1:-}" l="${2:-}" m d lid
  _trk_linear_ok "$id" && _trk_linear_label_ok "$l" || return 1
  m=$(_trk_linear_issue "$id") || return $?
  d=$(_trk_linear_gql 'query TrkLabels($name: String!) { issueLabels(first: 50, filter: { name: { eqIgnoreCase: $name } }) { nodes { id name team { key } } } }' \
    '{name: $name}' --arg name "$l") || return $?
  lid=$(printf '%s' "$d" | jq -r --arg l "$l" --arg team "$(printf '%s' "$m" | jq -r '.team.key // ""')" \
    '[.issueLabels.nodes[]? | select((.name | ascii_downcase) == ($l | ascii_downcase) and (.team == null or .team.key == $team))]
     | if length == 1 then .[0].id else empty end')
  [ -n "$lid" ] || { printf 'tracker: linear has no single label %s for this team\n' "$(_trk_sq "$l")" >&2; return 1; }
  _trk_linear_w issueAddLabel "issue=$id label=$l"
  _trk_dry && return 0
  d=$(_trk_linear_gql 'mutation TrkAddLabel($id: String!, $labelId: String!) { issueAddLabel(id: $id, labelId: $labelId) { success } }' \
    '{id: $id, labelId: $labelId}' --arg id "$(printf '%s' "$m" | jq -r .id)" --arg labelId "$lid") || return $?
  printf '%s' "$d" | jq -e '.issueAddLabel.success == true' >/dev/null 2>&1 || return 1
  return 0
}

# trk_linear_label_remove <id> <label> — 44 when the issue does not carry it,
# and nothing is sent. The write is logged (and a dry run answers 0) before
# that check, the same order the GitHub adapter's DELETE has.
trk_linear_label_remove() {
  local id="${1:-}" l="${2:-}" m d lid
  _trk_linear_ok "$id" && _trk_linear_label_ok "$l" || return 1
  m=$(_trk_linear_issue "$id") || return $?
  lid=$(printf '%s' "$m" | jq -r --arg l "$l" '[.labels.nodes[]? | select((.name | ascii_downcase) == ($l | ascii_downcase))] | .[0].id // empty')
  _trk_linear_w issueRemoveLabel "issue=$id label=$l"
  _trk_dry && return 0
  [ -n "$lid" ] || return 44
  d=$(_trk_linear_gql 'mutation TrkRemoveLabel($id: String!, $labelId: String!) { issueRemoveLabel(id: $id, labelId: $labelId) { success } }' \
    '{id: $id, labelId: $labelId}' --arg id "$(printf '%s' "$m" | jq -r .id)" --arg labelId "$lid") || return $?
  printf '%s' "$d" | jq -e '.issueRemoveLabel.success == true' >/dev/null 2>&1 || return 1
  return 0
}

# trk_linear_link_pr <id> <pr-url> — a PR attachment titled `PR #<n> <owner/repo>`.
trk_linear_link_pr() {
  local id="${1:-}" url="${2:-}" m d repo
  [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]] || return 1
  repo="${BASH_REMATCH[1]}"
  _trk_linear_ok "$id" || return 1
  m=$(_trk_linear_issue "$id") || return $?
  _trk_linear_w attachmentLinkURL "issue=$id url=$url"
  _trk_dry && return 0
  d=$(_trk_linear_gql 'mutation TrkAttach($id: String!, $url: String!, $title: String) { attachmentLinkURL(issueId: $id, url: $url, title: $title) { success attachment { id } } }' \
    '{id: $id, url: $url, title: $title}' --arg id "$(printf '%s' "$m" | jq -r .id)" --arg url "$url" --arg title "PR #${url##*/} $repo") || return $?
  printf '%s' "$d" | jq -e '.attachmentLinkURL.success == true and ((.attachmentLinkURL.attachment.id // "") != "")' >/dev/null 2>&1 || return 1
  return 0
}

# trk_linear_close_out <id> <bodyfile> [<status>] — the comment, THEN the move.
# A comment that did not post stops it.
trk_linear_close_out() {
  trk_linear_comment "${1:-}" "${2:-}" || return $?
  trk_linear_transition "${1:-}" "${3:-done}"
}
