#!/bin/bash
# bin/lib/tracker/jira.sh — the Jira Cloud adapter of the tracker contract
# (bin/lib/tracker.sh, BH-4076). Functions trk_jira_*, context TRK_JIRA_*, set
# ONLY by trk_jira_context <project>. REST v3 through the scoped-token gateway
# https://api.atlassian.com/ex/jira/<cloudId>; Jira Server/Data Center is not
# supported and a site URL base is refused.
#
# Sourced, never executed: no `set -e`, no `exit`, nothing at source time.
#
# CONTEXT (trk_jira_context <project>). It first blanks every TRK_JIRA_*, so an
# inherited value can never widen an allowlist, then reads:
#   <env dir>/<project>.env   JIRA_BASE, JIRA_EMAIL, JIRA_API_TOKEN, JIRA_SITE
#                             (in a subshell; nothing else from it survives)
#   settings rows tracker_jira.<project>.<name>, all optional:
#     write_projects        project keys every verb may touch
#     comment_projects      keys where only comment/link_pr may write
#     read_projects         keys list/read may touch (on top of the two above)
#     label                 the build label the list filters on (ai-build)
#     waiting_on_field      customfield_<n> holding waitingOn (none: null)
#     triage_verdict_field  customfield_<n> holding triageVerdict (none: null)
#     status_map            alias=Jira Status;alias=Jira Status
# No row is the fallback, never a widening: no write row means no writes. A
# malformed row or a worker that did not answer fails the whole context (rc 1),
# and with no context every verb answers 1 before any request.
#
# THE SANDBOX GUARD. Every verb names an issue KEY (CROM-12; a numeric id is
# refused) and the key's project must be on the tier's allowlist: write
# (write_projects), comment (write + comment), read (all three). A key that
# fails sends nothing. A write then GETs the issue and refuses unless Jira's
# answer carries the same key in the same project: Jira answers a moved
# issue's old key with the new issue, and that issue may be a client's.
#
# THE TOKEN rides only on curl's argv, as a Basic header built here; a log line
# names $JIRA_EMAIL/$JIRA_API_TOKEN, never their values.
#
# HTTP to the contract's rcs: 2xx 0; 401/403 1 with a stderr line (an expired
# token is a config problem, not an absent ticket); other 4xx 1; 429, 5xx and
# no answer 75.
#
# label_remove of a label the issue does not carry is 44 and sends nothing; in
# a dry run it prints its DRYRUN line without that check, as the GitHub
# adapter does. link_pr is a `PR: <url>` comment (not a Jira remote link).

_trk_jira_dir() { dirname "${BASH_SOURCE[0]}"; }

_trk_jira_blank() {
  TRK_JIRA_PROJECT=""; TRK_JIRA_BASE=""; TRK_JIRA_EMAIL=""; TRK_JIRA_TOKEN=""; TRK_JIRA_SITE=""
  TRK_JIRA_TOKEN_VAR=JIRA_API_TOKEN
  TRK_JIRA_WRITE_PROJECTS=""; TRK_JIRA_COMMENT_PROJECTS=""; TRK_JIRA_READ_PROJECTS=""
  TRK_JIRA_LABEL=""; TRK_JIRA_WAITING_FIELD=""; TRK_JIRA_VERDICT_FIELD=""; TRK_JIRA_STATUS_MAP=""
}

_trk_jira_in() { # _trk_jira_in <word> <list…> — exact member
  local w="$1" x
  shift
  for x in "$@"; do [ "$x" = "$w" ] && return 0; done
  return 1
}

# trk_jira_context <project> — rc 0 with TRK_JIRA_* set, or rc 1 with every
# TRK_JIRA_* blank and one stderr line saying why.
trk_jira_context() {
  local p="${1:-}" root="${HARNESS:-${H:-}}" d ep envd ef jc rows k v n
  local base email tok site wp="" cp="" rp="" label=ai-build wf="" vf="" smap=""
  local creds=()
  _trk_jira_blank
  [[ "$p" =~ ^[a-z0-9_.-]+$ ]] || { printf 'jira: %s is not a project name\n' "$(_trk_sq "$p")" >&2; return 1; }
  [ -n "$root" ] || { printf 'jira: no harness root (HARNESS) for %s\n' "$p" >&2; return 1; }
  d=$(_trk_jira_dir)
  ep="$d/../env-path.sh"; [ -r "$ep" ] || ep="$root/bin/lib/env-path.sh"
  if [ -r "$ep" ]; then
    # shellcheck source=/dev/null
    envd=$( . "$ep" && harness_env_dir "$root" ) || envd=""
  fi
  [ -n "${envd:-}" ] || envd="$root/env"
  ef="$envd/$p.env"
  [ -r "$ef" ] || { printf 'jira: %s has no env file %s\n' "$p" "$ef" >&2; return 1; }
  # shellcheck source=/dev/null
  mapfile -t creds < <( unset JIRA_BASE JIRA_EMAIL JIRA_API_TOKEN JIRA_SITE
                        set -a; . "$ef" >/dev/null 2>&1; set +a
                        printf '%s\n%s\n%s\n%s\n' "${JIRA_BASE:-}" "${JIRA_EMAIL:-}" "${JIRA_API_TOKEN:-}" "${JIRA_SITE:-}" )
  base="${creds[0]:-}"; email="${creds[1]:-}"; tok="${creds[2]:-}"; site="${creds[3]:-}"
  [[ "$base" =~ ^https://api\.atlassian\.com/ex/jira/[0-9a-fA-F-]{36}$ ]] \
    || { printf 'jira: %s JIRA_BASE must be https://api.atlassian.com/ex/jira/<cloudId> (a scoped token only works on the gateway)\n' "$ef" >&2; return 1; }
  [ -n "$email" ] || { printf 'jira: %s sets no JIRA_EMAIL\n' "$ef" >&2; return 1; }
  [ -n "$tok" ] || { printf 'jira: %s sets no JIRA_API_TOKEN\n' "$ef" >&2; return 1; }
  [[ "$site" =~ ^https://[a-z0-9-]+\.atlassian\.net$ ]] || site=""

  jc="$d/../../jobs-client.sh"; [ -r "$jc" ] || jc="$root/bin/jobs-client.sh"
  [ -r "$jc" ] || { printf 'jira: no bin/jobs-client.sh to read the %s settings rows\n' "$p" >&2; return 1; }
  # ONE subshell for every row: the client runs `set -uo pipefail` and exports
  # HARNESS_SECRET. A row that is there is `<name>\t<value>`; no row prints
  # nothing; the first outage stops the rest and fails the read.
  # shellcheck source=/dev/null
  rows=$( HARNESS="$root"; . "$jc" >/dev/null 2>&1 || exit 1
          for n in write_projects comment_projects read_projects label waiting_on_field triage_verdict_field status_map; do
            r=0; v=$(JOBS_ALERT=0 setting_get "tracker_jira.$p.$n" 2>/dev/null) || r=$?
            case "$r" in
              0) printf '%s\t%s\n' "$n" "$(printf '%s' "$v" | tr '\t\n' '  ')" ;;
              2) ;;
              *) exit 1 ;;
            esac
          done ) \
    || { printf 'jira: the settings rows tracker_jira.%s.* could not be read\n' "$p" >&2; return 1; }
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    case "$k" in
      write_projects|comment_projects|read_projects)
        # The charset first: the list is word-split below, and a `*` must
        # never reach a glob.
        [[ "$v" =~ ^[A-Z0-9_\ ]*$ ]] \
          || { printf 'jira: settings row tracker_jira.%s.%s holds %s, not Jira project keys\n' "$p" "$k" "$(_trk_sq "$v")" >&2; return 1; }
        for n in $v; do
          [[ "$n" =~ ^[A-Z][A-Z0-9_]{1,9}$ ]] \
            || { printf 'jira: settings row tracker_jira.%s.%s holds %s, not a Jira project key\n' "$p" "$k" "$(_trk_sq "$n")" >&2; return 1; }
        done
        v=$(printf '%s' "$v" | tr -s ' ' | sed 's/^ //; s/ $//')
        case "$k" in write_projects) wp="$v" ;; comment_projects) cp="$v" ;; *) rp="$v" ;; esac ;;
      label)
        [[ "$v" =~ ^[A-Za-z0-9_.:-]{1,100}$ ]] || { printf 'jira: settings row tracker_jira.%s.label is not a label\n' "$p" >&2; return 1; }
        label="$v" ;;
      waiting_on_field|triage_verdict_field)
        [[ "$v" =~ ^customfield_[0-9]+$ ]] || { printf 'jira: settings row tracker_jira.%s.%s is not a customfield_<n>\n' "$p" "$k" >&2; return 1; }
        if [ "$k" = waiting_on_field ]; then wf="$v"; else vf="$v"; fi ;;
      status_map)
        _trk_jira_smap_ok "$v" || { printf 'jira: settings row tracker_jira.%s.status_map is not alias=Status;alias=Status\n' "$p" >&2; return 1; }
        smap="$v" ;;
    esac
  done <<<"$rows"

  TRK_JIRA_PROJECT="$p"; TRK_JIRA_BASE="$base"; TRK_JIRA_EMAIL="$email"; TRK_JIRA_TOKEN="$tok"; TRK_JIRA_SITE="$site"
  TRK_JIRA_WRITE_PROJECTS="$wp"; TRK_JIRA_COMMENT_PROJECTS="$cp"; TRK_JIRA_READ_PROJECTS="$rp"
  TRK_JIRA_LABEL="$label"; TRK_JIRA_WAITING_FIELD="$wf"; TRK_JIRA_VERDICT_FIELD="$vf"; TRK_JIRA_STATUS_MAP="$smap"
  return 0
}

# trk_jira_cloud_id <site> — the cloudId of a Jira Cloud site
# (<name>.atlassian.net, no scheme), from one GET https://<site>/_edge/tenant_info.
# rc 0 with the UUID on stdout; 75 on 429, 5xx or no answer; 1 for a site that
# is not <name>.atlassian.net (nothing sent) or any other answer.
trk_jira_cloud_id() {
  local site="${1:-}" out code id rc=1
  [[ "$site" =~ ^[a-z0-9-]+\.atlassian\.net$ ]] || { printf 'jira: %s is not <name>.atlassian.net\n' "$(_trk_sq "$site")" >&2; return 1; }
  out=$(mktemp "${TMPDIR:-/tmp}/trk-jira.XXXXXX") || return 1
  code=$(curl -sS --max-time 30 -H "Accept: application/json" -o "$out" -w '%{http_code}' \
    "https://$site/_edge/tenant_info" 2>>"${TRK_ERR:-/dev/null}") || true
  case "$code" in
    2??) id=$(jq -r '.cloudId // empty' "$out" 2>/dev/null)
         if [[ "$id" =~ ^[0-9a-fA-F-]{36}$ ]]; then printf '%s\n' "$id"; rc=0
         else printf 'jira: %s answered no cloudId\n' "$site" >&2; fi ;;
    429|5??|000|'') printf 'jira: %s/_edge/tenant_info answered %s\n' "$site" "${code:-000}" >&2; rc=75 ;;
    *) printf 'jira: %s/_edge/tenant_info answered %s\n' "$site" "$code" >&2 ;;
  esac
  rm -f "$out"
  return "$rc"
}

# trk_jira_context_fields <site> <email> <token> <project key> <status_map> —
# the context from the onboarding sheet's fields (BH-7936), for a project that
# has no env file or settings rows yet. The gateway base comes from
# trk_jira_cloud_id; every allowlist is the one project key; the label is the
# default ai-build. rc 0 with TRK_JIRA_* set; rc 1 (or 75 from the cloudId
# read) with every TRK_JIRA_* blank and one stderr line. trk_jira_context is
# unchanged and stays the reader for a registered project.
trk_jira_context_fields() {
  local site="${1:-}" email="${2:-}" tok="${3:-}" key="${4:-}" smap="${5:-}" cid rc=0
  _trk_jira_blank
  [[ "$site" =~ ^[a-z0-9-]+\.atlassian\.net$ ]] || { printf 'jira: site %s is not <name>.atlassian.net\n' "$(_trk_sq "$site")" >&2; return 1; }
  [ -n "$email" ] || { printf 'jira: no email\n' >&2; return 1; }
  [ -n "$tok" ] || { printf 'jira: no API token\n' >&2; return 1; }
  [[ "$key" =~ ^[A-Z][A-Z0-9_]{1,9}$ ]] || { printf 'jira: %s is not a Jira project key\n' "$(_trk_sq "$key")" >&2; return 1; }
  [ -n "$smap" ] && _trk_jira_smap_ok "$smap" || { printf 'jira: the status map is not alias=Status;alias=Status\n' >&2; return 1; }
  cid=$(trk_jira_cloud_id "$site") || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  TRK_JIRA_PROJECT="$key"; TRK_JIRA_BASE="https://api.atlassian.com/ex/jira/$cid"
  TRK_JIRA_EMAIL="$email"; TRK_JIRA_TOKEN="$tok"; TRK_JIRA_SITE="https://$site"
  TRK_JIRA_WRITE_PROJECTS="$key"; TRK_JIRA_LABEL=ai-build; TRK_JIRA_STATUS_MAP="$smap"
  return 0
}

_trk_jira_smap_ok() { # every `;`-separated entry is alias=Jira Status
  local e
  local IFS=';'
  for e in $1; do [[ "$e" =~ ^[a-z0-9_-]+=[^=]+$ ]] || return 1; done
  return 0
}

# _trk_jira_guard <KEY> <read|comment|write> — the text check, before any
# request. rc 1 and one stderr line on a refusal.
_trk_jira_guard() {
  local key="${1:-}" tier="${2:-}" pre list
  [ -n "${TRK_JIRA_BASE:-}" ] || { printf 'jira: no context loaded (trk_jira_context)\n' >&2; return 1; }
  [[ "$key" =~ ^([A-Z][A-Z0-9_]{1,9})-[1-9][0-9]*$ ]] || { printf 'jira: %s is not a Jira issue key\n' "$(_trk_sq "$key")" >&2; return 1; }
  pre="${BASH_REMATCH[1]}"
  case "$tier" in
    write) list="${TRK_JIRA_WRITE_PROJECTS:-}" ;;
    comment) list="${TRK_JIRA_WRITE_PROJECTS:-} ${TRK_JIRA_COMMENT_PROJECTS:-}" ;;
    read) list="${TRK_JIRA_WRITE_PROJECTS:-} ${TRK_JIRA_COMMENT_PROJECTS:-} ${TRK_JIRA_READ_PROJECTS:-}" ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC2086
  _trk_jira_in "$pre" $list && return 0
  printf "jira: %s is in project %s, not on %s's %s allowlist\n" "$key" "$pre" "${TRK_JIRA_PROJECT:-}" "$tier" >&2
  return 1
}

# _trk_jira_same <KEY> — stdin is an issue Jira answered; rc 0 only when it is
# that key in that key's project.
_trk_jira_same() {
  local key="$1" got
  got=$(jq -r '[.key // "", .fields.project.key // ""] | join(" ")' 2>/dev/null) || got=""
  [ "$got" = "$key ${key%-*}" ] && return 0
  printf 'jira: %s answered as %s, refused\n' "$key" "$(_trk_sq "$got")" >&2
  return 1
}

# _trk_jira_http <METHOD> <path> [<json file>] — the one curl call. The body is
# on stdout for a 2xx; rc per the table in the header. Reads go out even under
# TRK_DRY; a write's caller logs and returns before it gets here.
_trk_jira_http() {
  local m="$1" path="$2" data="${3:-}" out code auth rc=1
  [ -n "${TRK_JIRA_BASE:-}" ] && [ -n "${TRK_JIRA_TOKEN:-}" ] || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/trk-jira.XXXXXX") || return 1
  auth=$(printf '%s:%s' "${TRK_JIRA_EMAIL:-}" "$TRK_JIRA_TOKEN" | base64 | tr -d '\n')
  local args=(-sS --max-time 30 -X "$m" -H "Accept: application/json" -o "$out" -w '%{http_code}')
  [ -n "$data" ] && args+=(-H "Content-Type: application/json" --data-binary "@$data")
  code=$(curl "${args[@]}" -H "Authorization: Basic $auth" "$TRK_JIRA_BASE$path" 2>>"${TRK_ERR:-/dev/null}") || true
  case "$code" in
    2??) cat "$out"; rc=0 ;;
    401|403) printf 'jira: %s %s answered %s: check $JIRA_EMAIL/$%s for %s\n' "$m" "$path" "$code" "${TRK_JIRA_TOKEN_VAR:-JIRA_API_TOKEN}" "${TRK_JIRA_PROJECT:-}" >&2; rc=1 ;;
    429|5??|000|'') rc=75 ;;
    *) rc=1 ;;
  esac
  rm -f "$out"
  return "$rc"
}

_trk_jira_logw() { # _trk_jira_logw <METHOD> <path>
  _trk_logw "curl -X $1 $2 auth=Basic(\$JIRA_EMAIL:\$${TRK_JIRA_TOKEN_VAR:-JIRA_API_TOKEN})"
}

# _trk_jira_write_guard <KEY> <comment|write> — the text check, then the guard
# GET; the issue (project, labels, status) is left in _TRK_JIRA_ISSUE.
_trk_jira_write_guard() {
  local key="$1" rc=0
  _TRK_JIRA_ISSUE=""
  _trk_jira_guard "$key" "$2" || return 1
  _TRK_JIRA_ISSUE=$(_trk_jira_http GET "/rest/api/3/issue/$key?fields=project,labels,status") || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s' "$_TRK_JIRA_ISSUE" | _trk_jira_same "$key" || return 1
}

# The jq the reads share: ADF to text, and a custom-field value to a string.
# shellcheck disable=SC2016
_TRK_JIRA_JQ='
def adf:
  if type == "string" then .
  elif type != "object" then ""
  else .type as $t
  | if $t == "text" then
      (.text // "") as $x
      | ([.marks[]? | select(.type == "link") | .attrs.href] | first) as $h
      | if $h != null and $h != $x then "\($x) (\($h))" else $x end
    elif $t == "hardBreak" then "\n"
    elif $t == "mention" then (.attrs.text // ("@" + (.attrs.id // "")))
    elif $t == "emoji" then (.attrs.text // .attrs.shortName // "")
    elif $t == "date" then (.attrs.timestamp // "")
    elif $t == "status" then (.attrs.text // "")
    elif $t == "inlineCard" or $t == "blockCard" or $t == "embedCard" then (.attrs.url // "")
    elif $t == "paragraph" or $t == "heading" then [.content[]? | adf] | join("")
    elif $t == "bulletList" then [.content[]? | "- " + (adf | gsub("\n"; "\n  "))] | join("\n")
    elif $t == "orderedList" then
      ((.attrs.order // 1) | tonumber? // 1) as $o
      | [(.content // []) | to_entries[] | "\(.key + $o). " + (.value | adf | gsub("\n"; "\n   "))] | join("\n")
    elif $t == "listItem" then [.content[]? | adf] | join("\n")
    elif $t == "codeBlock" then "```" + (.attrs.language // "") + "\n" + ([.content[]? | adf] | join("")) + "\n```"
    elif $t == "blockquote" then [.content[]? | adf] | join("\n\n") | "> " + gsub("\n"; "\n> ")
    elif $t == "rule" then "---"
    elif $t == "tableRow" then [.content[]? | adf] | join(" | ")
    elif $t == "tableCell" or $t == "tableHeader" then [.content[]? | adf] | join(" ")
    elif $t == "table" then [.content[]? | adf] | join("\n")
    else [.content[]? | adf] | join("\n\n")
    end
  end;
def fval:
  if . == null then null
  elif type == "object" then (.value // .name // .displayName // null)
  elif type == "array" then (map(if type == "object" then (.value // .name // "") else tostring end) | join(", "))
  else tostring end
  | if . == null or . == "" then null else tostring end;
def fld($f): if $f == "" then null else (.fields[$f] | fval) end;
def jurl($site; $k): if $site == "" then null else "\($site)/browse/\($k)" end;
'

# _trk_jira_fields — the issue fields every read asks for.
_trk_jira_fields() {
  local f="summary,status,labels,project"
  [ -n "${TRK_JIRA_WAITING_FIELD:-}" ] && f="$f,$TRK_JIRA_WAITING_FIELD"
  [ -n "${TRK_JIRA_VERDICT_FIELD:-}" ] && f="$f,$TRK_JIRA_VERDICT_FIELD"
  printf '%s' "$f"
}

# _trk_jira_fetch <KEY> <issue file> <comments file> — the read tier: the
# issue (checked to be that key in that project) and its WHOLE thread as one
# JSON array. A thread of 200 or more is a partial read and answers 1.
_trk_jira_fetch() {
  local key="$1" isf="$2" cmf="$3" rc=0 at=0 total=0 page n pages=0 cap=200
  _trk_jira_guard "$key" read || return 1
  _trk_jira_http GET "/rest/api/3/issue/$key?fields=$(_trk_jira_fields),description" > "$isf" || return $?
  _trk_jira_same "$key" < "$isf" || return 1
  printf '[]' > "$cmf"
  while :; do
    page=$(_trk_jira_http GET "/rest/api/3/issue/$key/comment?startAt=$at&maxResults=100&orderBy=created") || { rc=$?; return "$rc"; }
    total=$(printf '%s' "$page" | jq -r '.total // empty' 2>/dev/null)
    n=$(printf '%s' "$page" | jq -r '(.comments // []) | length' 2>/dev/null)
    case "$total" in ''|*[!0-9]*) return 1 ;; esac
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$total" -ge "$cap" ]; then
      printf 'jira: %s has %s comments, the thread was not read to the end\n' "$key" "$total" >&2
      return 1
    fi
    printf '%s' "$page" | jq -c --slurpfile have "$cmf" '$have[0] + (.comments // [])' > "$cmf.n" 2>/dev/null && mv "$cmf.n" "$cmf" || return 1
    at=$((at + n)); pages=$((pages + 1))
    [ "$at" -ge "$total" ] && return 0
    if [ "$n" = 0 ] || [ "$pages" -ge 2 ]; then
      printf 'jira: %s comment paging stopped at %s of %s, the thread was not read to the end\n' "$key" "$at" "$total" >&2
      return 1
    fi
  done
}

# trk_jira_myself — the connection probe's one read (BH-7924): a single GET
# /rest/api/3/myself. It proves the gateway base, email and token are
# accepted and prints nothing on stdout. rc 0, or _trk_jira_http's rc (1 with
# its 401/403 stderr line, 75 rate-limited or no answer). Needs the context
# (trk_jira_context or trk_jira_context_fields).
trk_jira_myself() {
  local d
  d=$(_trk_jira_http GET /rest/api/3/myself) || return $?
  printf '%s' "$d" | jq -e '.accountId | type == "string" and length > 0' >/dev/null 2>&1 || return 1
  return 0
}

trk_jira_read() {
  local key="${1:-}" isf cmf rc=0
  isf=$(mktemp "${TMPDIR:-/tmp}/trk-jira.XXXXXX") || return 1
  cmf=$(mktemp "${TMPDIR:-/tmp}/trk-jira.XXXXXX") || { rm -f "$isf"; return 1; }
  _trk_jira_fetch "$key" "$isf" "$cmf" || rc=$?
  if [ "$rc" = 0 ]; then
    jq -c --slurpfile cs "$cmf" --arg wf "${TRK_JIRA_WAITING_FIELD:-}" --arg vf "${TRK_JIRA_VERDICT_FIELD:-}" \
        --arg site "${TRK_JIRA_SITE:-}" "$_TRK_JIRA_JQ"'
      {id: .key, key: .key, title: (.fields.summary // ""), body: ((.fields.description // "") | adf),
       status: (.fields.status.name // null),
       state: (if .fields.status.statusCategory.key == "done" then "closed" else "open" end),
       labels: [(.fields.labels // [])[] | tostring],
       waitingOn: fld($wf), triageVerdict: fld($vf), url: jurl($site; .key),
       comments: [$cs[0][] | {author: (.author.displayName // .author.accountId // null),
                              body: ((.body // "") | adf), createdAt: (.created // null),
                              internal: ((.jsdPublic == false) or (.visibility != null))}]}' "$isf" 2>/dev/null || rc=1
  fi
  rm -f "$isf" "$cmf" "$cmf.n"
  return "$rc"
}

# trk_jira_gate_raw <KEY> — the board-shaped object bin/triage-gate.sh's
# buildable_gate parses. A comment written by the token's own account
# (/myself) is ours, and so is internal. A failed /myself does not throw the
# issue away: the fields are already read, so the object is still printed with
# ticket.ownUnknown = true, and the gate lets waitingOn/triageVerdict block
# before it treats the newest-comment check as unreadable.
trk_jira_gate_raw() {
  local key="${1:-}" isf cmf me rc=0
  isf=$(mktemp "${TMPDIR:-/tmp}/trk-jira.XXXXXX") || return 1
  cmf=$(mktemp "${TMPDIR:-/tmp}/trk-jira.XXXXXX") || { rm -f "$isf"; return 1; }
  _trk_jira_fetch "$key" "$isf" "$cmf" || rc=$?
  if [ "$rc" = 0 ]; then
    me=$(_trk_jira_http GET /rest/api/3/myself | jq -r '.accountId // empty' 2>/dev/null) || me=""
    jq -c --slurpfile cs "$cmf" --arg wf "${TRK_JIRA_WAITING_FIELD:-}" --arg vf "${TRK_JIRA_VERDICT_FIELD:-}" \
        --arg me "$me" "$_TRK_JIRA_JQ"'
      {ticket: {key: .key, waitingOn: fld($wf), triageVerdict: fld($vf), ownUnknown: ($me == "")},
       comments: [$cs[0][] | {author: {name: (.author.displayName // ""), userId: (.author.accountId // "")},
                              createdAt: (.created // ""),
                              isInternal: ((.jsdPublic == false) or (.visibility != null) or ($me != "" and (.author.accountId // "") == $me))}]}' "$isf" 2>/dev/null || rc=1
  fi
  rm -f "$isf" "$cmf" "$cmf.n"
  return "$rc"
}

# trk_jira_list — open issues carrying the build label in the readable
# projects, newest first. At most 4 pages of 50; a 4th page that still has a
# nextPageToken is rc 1 ("list incomplete"), never a silent truncation.
# TRK_LIST_LABEL (else TRK_JIRA_LABEL) is the label; TRK_LIST_STATE=all drops
# the open clause; TRK_LIST_SINCE adds `updated >= "<the day before, UTC>"`:
# JQL reads a date in the API user's time zone, so the server clause is a day
# wide and a day early, and bin/lib/tracker.sh makes the exact cut.
trk_jira_list() {
  local keys="" k jql req acc page tok="" pages=0 rc=0 fields day
  [ -n "${TRK_JIRA_BASE:-}" ] || return 1
  for k in ${TRK_JIRA_WRITE_PROJECTS:-} ${TRK_JIRA_COMMENT_PROJECTS:-} ${TRK_JIRA_READ_PROJECTS:-}; do
    case " $keys " in *" $k "*) ;; *) keys="${keys:+$keys }$k" ;; esac
  done
  [ -n "$keys" ] || { printf 'jira: %s has no readable project keys\n' "${TRK_JIRA_PROJECT:-}" >&2; return 1; }
  # shellcheck disable=SC2086
  jql="project in ($(printf '"%s",' $keys | sed 's/,$//')) AND labels = \"${TRK_LIST_LABEL:-${TRK_JIRA_LABEL:-ai-build}}\""
  [ "${TRK_LIST_STATE:-}" = all ] || jql="$jql AND statusCategory != Done"
  if [ -n "${TRK_LIST_SINCE:-}" ]; then
    day=$(jq -rn --arg s "$TRK_LIST_SINCE" '$s | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 - 86400 | strftime("%Y-%m-%d")' 2>/dev/null)
    [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    jql="$jql AND updated >= \"$day\""
  fi
  jql="$jql ORDER BY updated DESC"
  fields="$(_trk_jira_fields),updated,comment"
  req=$(mktemp "${TMPDIR:-/tmp}/trk-jira.XXXXXX") || return 1
  acc='[]'
  while :; do
    jq -n --arg jql "$jql" --arg f "$fields" --arg t "$tok" \
      '{jql: $jql, maxResults: 50, fields: ($f | split(","))} + (if $t == "" then {} else {nextPageToken: $t} end)' > "$req" || { rc=1; break; }
    page=$(_trk_jira_http POST /rest/api/3/search/jql "$req") || { rc=$?; break; }
    acc=$(printf '%s' "$page" | jq -c --argjson a "$acc" '$a + (.issues // error("no issues"))' 2>/dev/null) || { rc=1; break; }
    pages=$((pages + 1))
    tok=$(printf '%s' "$page" | jq -r 'if .isLast == true then "" else (.nextPageToken // "") end' 2>/dev/null) || tok=""
    [ -z "$tok" ] && break
    if [ "$pages" -ge 4 ]; then
      printf 'jira: list incomplete, %s pages and Jira still has more\n' "$pages" >&2
      rc=1; break
    fi
  done
  rm -f "$req"
  [ "$rc" = 0 ] || return "$rc"
  # A row outside the readable projects means the search did not do what it
  # was told; fail rather than hand it on.
  printf '%s' "$acc" | jq -e --arg ks " $keys " 'all(.[]; ((.key // "") | split("-")[0]) as $p | ($ks | contains(" " + $p + " ")))' >/dev/null 2>&1 \
    || { printf 'jira: the search answered an issue outside %s\n' "$keys" >&2; return 1; }
  printf '%s' "$acc" | jq -c --arg wf "${TRK_JIRA_WAITING_FIELD:-}" --arg vf "${TRK_JIRA_VERDICT_FIELD:-}" \
      --arg site "${TRK_JIRA_SITE:-}" "${_TRK_ISO_JQ:-}$_TRK_JIRA_JQ"'
    [.[] | {id: .key, key: .key, title: (.fields.summary // ""), status: (.fields.status.name // null),
            labels: [(.fields.labels // [])[] | tostring], waitingOn: fld($wf), triageVerdict: fld($vf),
            url: jurl($site; .key), updatedAt: (.fields.updated | trk_iso),
            state: (if .fields.status.statusCategory.key == "done" then "closed" else "open" end),
            commentCount: (.fields.comment.total | if type == "number" then . else null end)}]' 2>/dev/null
}

# _trk_jira_adf <text file> <out file> — {"body": ADF} from plain text: blank
# lines split paragraphs, a single newline is a hardBreak, an http(s) URL is a
# text node with a link mark.
_trk_jira_adf() {
  jq -n --rawfile t "$1" '
    def segs: . as $s
      | [match("https?://[^\\s]*[^\\s.,;:!?)\\]]"; "g")] as $ms
      | (reduce $ms[] as $m ({pos: 0, out: []};
          .out += [{type: "text", text: $s[.pos:$m.offset]},
                   {type: "text", text: $m.string, marks: [{type: "link", attrs: {href: $m.string}}]}]
          | .pos = $m.offset + $m.length)) as $r
      | ($r.out + [{type: "text", text: $s[$r.pos:]}]) | map(select(.text != ""));
    def para: split("\n") | map(segs) as $ls
      | {type: "paragraph", content: ([range(0; $ls | length) as $i | (if $i > 0 then [{type: "hardBreak"}] else [] end) + $ls[$i]] | add // [])};
    ($t | gsub("\r"; "") | sub("\\s+$"; "") | sub("^\\s+"; "")) as $x
    | if $x == "" then error("empty body") else . end
    | {body: {type: "doc", version: 1, content: [$x | splits("\n[ \t]*\n\\s*") | select(. != "") | para]}}' > "$2" 2>/dev/null
}

# _trk_jira_post_comment <KEY> <text file> — no guard: the caller guarded.
_trk_jira_post_comment() {
  local key="$1" f="$2" req rc=0
  [ -r "$f" ] || return 1
  req=$(mktemp "${TMPDIR:-/tmp}/trk-jira.XXXXXX") || return 1
  _trk_jira_adf "$f" "$req" || { rm -f "$req"; return 1; }
  _trk_jira_logw POST "/rest/api/3/issue/$key/comment"
  if _trk_dry; then rm -f "$req"; return 0; fi
  _trk_jira_http POST "/rest/api/3/issue/$key/comment" "$req" >/dev/null || rc=$?
  rm -f "$req"
  return "$rc"
}

trk_jira_comment() {
  local key="${1:-}" f="${2:-}"
  [ -r "$f" ] || return 1
  _trk_jira_write_guard "$key" comment || return $?
  _trk_jira_post_comment "$key" "$f"
}

# _trk_jira_status_name <status> — a status_map alias to its Jira status name;
# anything else is taken as the name itself.
_trk_jira_status_name() {
  local s="$1" e
  local IFS=';'
  for e in ${TRK_JIRA_STATUS_MAP:-}; do
    [ "${e%%=*}" = "$s" ] && { printf '%s' "${e#*=}"; return 0; }
  done
  printf '%s' "$s"
}

# _trk_jira_pick <KEY> <status name, or "" for the done category> — reads only.
# Prints `<transition id>\t<to.name>`; rc 3 when no transition leads there, 1
# when more than one distinct one does (never pick one).
_trk_jira_pick() {
  local key="$1" want="$2" t ids
  t=$(_trk_jira_http GET "/rest/api/3/issue/$key/transitions") || return $?
  ids=$(printf '%s' "$t" | jq -c --arg w "$want" '[(.transitions // [])[]
           | select(if $w == "" then .to.statusCategory.key == "done" else ((.to.name // "") | ascii_downcase) == ($w | ascii_downcase) end)
           | {id: (.id | tostring), to: .to.name}] | unique_by(.id)' 2>/dev/null) || return 1
  case "$(printf '%s' "$ids" | jq length)" in
    0) printf 'jira: no transition from %s to %s\n' "$key" "${want:-a done status}" >&2; return 3 ;;
    1) printf '%s' "$ids" | jq -r '.[0] | "\(.id)\t\(.to)"' ;;
    *) printf 'jira: %s has more than one transition to %s, refusing to pick\n' "$key" "${want:-a done status}" >&2; return 1 ;;
  esac
}

# _trk_jira_move <KEY> <transition id> <to name> — the POST, then a GET that
# must show the new status: a 204 that did not move the issue is rc 1.
_trk_jira_move() {
  local key="$1" id="$2" to="$3" req rc=0 now
  req=$(mktemp "${TMPDIR:-/tmp}/trk-jira.XXXXXX") || return 1
  jq -n --arg id "$id" '{transition: {id: $id}}' > "$req" || { rm -f "$req"; return 1; }
  _trk_jira_logw POST "/rest/api/3/issue/$key/transitions"
  if _trk_dry; then rm -f "$req"; return 0; fi
  _trk_jira_http POST "/rest/api/3/issue/$key/transitions" "$req" >/dev/null || rc=$?
  rm -f "$req"
  [ "$rc" = 0 ] || return "$rc"
  now=$(_trk_jira_http GET "/rest/api/3/issue/$key?fields=status") || return $?
  now=$(printf '%s' "$now" | jq -r '.fields.status.name // empty' 2>/dev/null)
  [ "$(printf '%s' "$now" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$to" | tr '[:upper:]' '[:lower:]')" ] && return 0
  printf 'jira: %s accepted the transition to %s but is %s\n' "$key" "$to" "$(_trk_sq "$now")" >&2
  return 1
}

trk_jira_transition() {
  local key="${1:-}" s="${2:-}" pick rc=0
  [ -n "$s" ] || return 3
  _trk_jira_write_guard "$key" write || return $?
  pick=$(_trk_jira_pick "$key" "$(_trk_jira_status_name "$s")") || return $?
  _trk_jira_move "$key" "${pick%%$'\t'*}" "${pick#*$'\t'}" || rc=$?
  return "$rc"
}

_trk_jira_label_ok() { [[ "${1:-}" =~ ^[^[:space:]]{1,255}$ ]]; }

_trk_jira_label() { # _trk_jira_label <add|remove> <KEY> <label>
  local op="$1" key="$2" l="$3" req rc=0
  _trk_jira_label_ok "$l" || return 1
  _trk_jira_write_guard "$key" write || return $?
  req=$(mktemp "${TMPDIR:-/tmp}/trk-jira.XXXXXX") || return 1
  jq -n --arg op "$op" --arg l "$l" '{update: {labels: [{($op): $l}]}}' > "$req" || { rm -f "$req"; return 1; }
  _trk_jira_logw PUT "/rest/api/3/issue/$key"
  if _trk_dry; then rm -f "$req"; return 0; fi
  if [ "$op" = remove ] && ! printf '%s' "$_TRK_JIRA_ISSUE" | jq -e --arg l "$l" '(.fields.labels // []) | index($l) != null' >/dev/null 2>&1; then
    rm -f "$req"; return 44
  fi
  _trk_jira_http PUT "/rest/api/3/issue/$key" "$req" >/dev/null || rc=$?
  rm -f "$req"
  return "$rc"
}
trk_jira_label_add()    { _trk_jira_label add "${1:-}" "${2:-}"; }
trk_jira_label_remove() { _trk_jira_label remove "${1:-}" "${2:-}"; }

trk_jira_link_pr() {
  local key="${1:-}" url="${2:-}" f rc=0
  [[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]] || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/trk-jira.XXXXXX") || return 1
  printf 'PR: %s\n' "$url" > "$f"
  trk_jira_comment "$key" "$f" || rc=$?
  rm -f "$f"
  return "$rc"
}

# trk_jira_close_out <KEY> <bodyfile> [<status>] — the transition is resolved
# FIRST, with reads only (the given status, else the `done` alias, else the one
# transition into a done-category status), so a close-out that cannot move the
# issue posts nothing. Then the comment, then the move. A failed comment stops
# it.
trk_jira_close_out() {
  local key="${1:-}" f="${2:-}" s="${3:-}" want pick
  [ -r "$f" ] || return 1
  _trk_jira_write_guard "$key" write || return $?
  if [ -n "$s" ]; then want=$(_trk_jira_status_name "$s")
  else
    want=$(_trk_jira_status_name "done")
    [ "$want" = "done" ] && want=""
  fi
  pick=$(_trk_jira_pick "$key" "$want") || return $?
  _trk_jira_post_comment "$key" "$f" || return 1
  _trk_jira_move "$key" "${pick%%$'\t'*}" "${pick#*$'\t'}"
}
