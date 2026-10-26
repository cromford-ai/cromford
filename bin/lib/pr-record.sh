#!/bin/bash
# bin/lib/pr-record.sh — the fleet's own record of each fleet-owned PR
# (BH-8067). Sourced, never executed. Defines functions only.
#
# The record is one pr_records row per PR in the jobs D1, read and written
# through PUT and GET /api/pr-records (worker/jobs/src/routes/pr-records.js).
#
#   pr_record_put <owner/repo> <number> <fleet|webhook|github> <fields-json> [at]
#       One PUT. <fields-json> is a JSON object of record columns. The worker
#       replaces a column only when the stored value is not newer than <at>
#       (default: the worker's clock). Prints {row, applied, stale}, rc 0.
#       rc 1 and nothing on stdout on bad args or any failed request.
#
#   pr_record_get <owner/repo> <number> [field...]
#       The record's row as JSON on stdout. The default fields are
#       `state head_sha`. GitHub is read (one REST GET of the PR) only when:
#         unreadable   the jobs read failed (fail open to GitHub, as before)
#         unknown      the PR has no record
#         field:<f>    a requested field that a GitHub read fills is null.
#                      Case 2 (BH-8151): a webhook that names a change but
#                      does not carry the field stores it null (a push to
#                      the base nulls mergeable_state), and GitHub's own
#                      mergeable_state "unknown" is stored null, so the
#                      next get that asks for it reads GitHub again
#         stale        the record is older than PR_RECORD_MAX_AGE_S, or that
#                      knob is 0
#       After a GitHub read it writes what it read into the record (source
#       github) and prints the row the PUT returned. When that PUT fails it
#       prints the GitHub values (same keys) and still returns 0.
#       rc 0  a row was printed.
#       rc 2  bad args or an unknown field name: no request at all.
#       rc 44 GitHub says the PR does not exist: nothing printed, no write.
#       rc 75 GitHub did not answer: nothing printed, no write. The old row is
#             never printed as if it were fresh.
#       Each GitHub read appends one line to logs/pr-record.log:
#         <UTC> get <repo>#<n> reason=<reason> gh_rc=<rc> put=<ok|failed|skipped>
#       A row served from the record writes no line.
#
# The fields a GitHub read fills: state draft head_ref base_ref head_sha
# base_sha mergeable_state labels. checks, review_decision, queue_state and
# last_comment_id are stored and returned, but a null in them starts no GitHub
# read: writes (C1) and webhooks (C2) fill them. The webhook writer is
# worker/jobs/src/lib/pr-record-intake.js (checks entries are
# {status, conclusion, sha, at} keyed <check name>, suite:<app>, workflow:<name>).
#
#   pr_record_max_age
#       The resolved PR_RECORD_MAX_AGE_S as a non-negative integer on stdout.
#       bin/orphan-reconcile.sh bounds its stored open-PR list with it (BH-8271).
#
#   pr_record_peek <owner/repo> <number>
#       BH-8334: the record row as it is, plus age_s, as one JSON line, rc 0.
#       rc 1 and nothing on stdout on bad args, no row, or a failed read. ONE
#       jobs GET, never a GitHub call, never a write. A miss writes one
#       logs/pr-record.log line: peek <repo>#<n> miss=<unreadable|unknown>.
#       bin/lead-verdict.sh uses it when GitHub refused its head read for
#       quota; the caller judges the age.
#
#   pr_record_head_fallback_max_age
#       BH-8334: the resolved PR_RECORD_HEAD_FALLBACK_MAX_AGE_S (default 900,
#       0 = never) as a non-negative integer on stdout.
#
#   pr_record_list <owner/repo> <open|merged|closed> <out-file> [need-csv]
#       BH-8452: the record's list of the repo's PRs in that state. ONE jobs
#       GET (/api/pr-records?repo=&state=[&need=]), never a GitHub call, never
#       a write. rc 0: <out-file> holds the rows array (keys number title
#       head_ref head_sha base_ref author labels body mergeable_state
#       updated_at created_at url draft), nothing on stdout, no log line. The
#       list is trusted only when ALL hold: the last full GitHub list write
#       (its sync stamp) is 0..PR_RECORD_LIST_MAX_AGE_S seconds old on the
#       worker's clock, the page is not truncated, no record of the repo was
#       marked unknown by that last list write (`unknown` is 0: such a PR is
#       not in the rows, and a reader would take it as "no PR"), and no
#       <need-csv> field is null on a row. On rc 0, <out-file>.sync holds the
#       stamp's synced_at (ISO), so a caller can ask the wake feed what
#       changed since. Else rc 1, <out-file> and <out-file>.sync are empty, stdout is one word,
#       and logs/pr-record.log gets `list <repo> state=<s> miss=<word>`:
#         off          the knob is 0 (no request at all)
#         unreadable   the jobs read failed
#         malformed    the answer is not a list answer (an old worker)
#         no-sync      no full list was ever written for the repo
#         stale        the stamp is older than the knob, or in the future
#         truncated    more rows exist than the page holds
#         unknown      the last list write marked a record of the repo unknown
#         field:<f>    a needed field is null on a row
#       rc 2: bad args, no request.
#
#   pr_record_list_sync <owner/repo> <state> <rest-pulls-json-file> [at]
#       BH-8452: writes one FULL GitHub list read (a REST `pulls` array, the
#       shape gh_rest_pr_list_all prints) into the record: POST
#       /api/pr-record-lists. <at> is the ISO time the read started (default
#       the worker's clock). The worker marks an open record that is not in
#       the list unknown and stamps the list. Call it only with an uncut list.
#       rc 0 on a 200; else rc 1 and one `list-sync <repo> failed` log line.
#
#   pr_record_list_max_age
#       BH-8452: the resolved PR_RECORD_LIST_MAX_AGE_S (default 900, 0 = off).
#
# The knob PR_RECORD_MAX_AGE_S (catalog/lanes.d/_lib.pr-record.json) is read
# through lane_knob when the caller has it, else from the environment. So is
# PR_RECORD_HEAD_FALLBACK_MAX_AGE_S and PR_RECORD_LIST_MAX_AGE_S
# (catalog/lanes.d/_lib.pr-record.knobs.d/).
#
# The root is ${HARNESS:-${H:-}}; with no root the jobs client cannot load, so
# every put fails and every get reads GitHub.
[ -n "${_PRR_LOADED:-}" ] && return 0
_PRR_LOADED=1
_PRR_LIBDIR="${BASH_SOURCE[0]%/*}"
_PRR_FIELDS="state draft head_ref base_ref head_sha base_sha mergeable_state labels checks review_decision queue_state last_comment_id"
_PRR_GH_FIELDS="state draft head_ref base_ref head_sha base_sha mergeable_state labels"
_PRR_DEFAULT_MAX_AGE_S=900   # fallback only: the knob is PR_RECORD_MAX_AGE_S in catalog/lanes.d/_lib.pr-record.json
_PRR_DEFAULT_HEAD_FALLBACK_S=900   # fallback only: the knob is PR_RECORD_HEAD_FALLBACK_MAX_AGE_S in catalog/lanes.d/_lib.pr-record.knobs.d/
_PRR_DEFAULT_LIST_MAX_AGE_S=900   # fallback only: the knob is PR_RECORD_LIST_MAX_AGE_S in catalog/lanes.d/_lib.pr-record.knobs.d/

_prr_root() { local r="${HARNESS:-${H:-}}"; [ -n "$r" ] || return 1; printf '%s' "$r"; }

_prr_log() {
  local root; root=$(_prr_root) || return 0
  mkdir -p "$root/logs" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$root/logs/pr-record.log" 2>/dev/null || true
}

# _prr_client — rc 0 when _jobs_req exists. Sources bin/jobs-client.sh when it
# does not, and restores nounset and pipefail, which the client switches on
# (the _alr_client pattern, bin/lib/alert-line-remote.sh). The client exits
# when a module is missing, so it is first sourced in a subshell.
_prr_client() {
  local root pf nu=0
  command -v _jobs_req >/dev/null 2>&1 && return 0
  root=$(_prr_root) || return 1
  [ -r "$root/bin/jobs-client.sh" ] || return 1
  ( . "$root/bin/jobs-client.sh" ) >/dev/null 2>&1 || return 1
  case $- in *u*) nu=1 ;; esac
  pf=$(set -o 2>/dev/null | awk '$1=="pipefail"{print $2}')
  # shellcheck source=bin/jobs-client.sh
  . "$root/bin/jobs-client.sh" >/dev/null 2>&1 || true
  [ "$pf" = off ] && set +o pipefail
  [ "$nu" = 0 ] && set +u
  command -v _jobs_req >/dev/null 2>&1
}

_prr_args_ok() { # <repo> <number>
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "${2:-}" =~ ^[1-9][0-9]{0,9}$ ]]
}

_prr_lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

pr_record_put() {
  local repo="${1:-}" n="${2:-}" src="${3:-}" fields="${4:-}" at="${5:-}" body out
  _prr_args_ok "$repo" "$n" || return 1
  case "$src" in fleet|webhook|github) ;; *) return 1 ;; esac
  jq -e 'type == "object" and length > 0' <<<"$fields" >/dev/null 2>&1 || return 1
  _prr_client || return 1
  body=$(jq -nc --arg r "$(_prr_lower "$repo")" --argjson n "$n" --arg s "$src" --argjson f "$fields" --arg at "$at" \
    '{repo:$r, number:$n, source:$s, fields:$f} + (if $at != "" then {at:$at} else {} end)' 2>/dev/null) || return 1
  out=$(_jobs_req PUT /api/pr-records "$body") || return 1
  jq -e '(.row | objects) and (.applied | arrays) and (.stale | arrays)' <<<"$out" >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

# _prr_knob <ENV> <fallback> — a pr-record knob as a non-negative integer.
_prr_knob() {
  local v="" _LG_KIND=libs
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob pr-record "$1" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  # No lane_knob and no env: the registry default is not reachable here.
  [ -n "$v" ] || v=$2
  if ! [[ "$v" =~ ^[0-9]{1,9}$ ]]; then
    _prr_log "knob $1='$v' is not a non-negative integer: using $2"
    v=$2
  fi
  printf '%s' "$((10#$v))"
}

# _prr_max_age — the knob as a non-negative integer.
_prr_max_age() { _prr_knob PR_RECORD_MAX_AGE_S "$_PRR_DEFAULT_MAX_AGE_S"; }

pr_record_max_age() { _prr_max_age; }

pr_record_head_fallback_max_age() { _prr_knob PR_RECORD_HEAD_FALLBACK_MAX_AGE_S "$_PRR_DEFAULT_HEAD_FALLBACK_S"; }

pr_record_list_max_age() { _prr_knob PR_RECORD_LIST_MAX_AGE_S "$_PRR_DEFAULT_LIST_MAX_AGE_S"; }

pr_record_list() {
  local repo="${1:-}" st="${2:-}" outf="${3:-}" need="${4:-}" lr max q out why="" age
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  case "$st" in open|merged|closed) ;; *) return 2 ;; esac
  [ -n "$outf" ] || return 2
  [ -z "$need" ] || [[ "$need" =~ ^[a-z_]+(,[a-z_]+)*$ ]] || return 2
  : > "$outf" || return 2
  : > "$outf.sync" || return 2
  lr=$(_prr_lower "$repo")
  max=$(pr_record_list_max_age)
  q="/api/pr-records?repo=$lr&state=$st"
  [ -z "$need" ] || q="$q&need=$need"
  if [ "$max" = 0 ]; then
    why=off
  elif ! _prr_client || ! out=$(_jobs_req GET "$q"); then
    why=unreadable
  elif ! jq -e '(.rows | type) == "array" and (.truncated | type) == "boolean" and has("sync") and has("missing") and (.unknown | type) == "number"' <<<"$out" >/dev/null 2>&1; then
    why=malformed
  elif jq -e '.sync == null' <<<"$out" >/dev/null 2>&1; then
    why=no-sync
  else
    age=$(jq -r '.sync.age_s // empty' <<<"$out" 2>/dev/null)
    if ! [[ "$age" =~ ^[0-9]{1,12}$ ]] || [ "$age" -gt "$max" ]; then
      why=stale
    elif jq -e '.truncated' <<<"$out" >/dev/null 2>&1; then
      why=truncated
    elif ! jq -e '.unknown == 0' <<<"$out" >/dev/null 2>&1; then
      why=unknown
    elif ! jq -e '.missing == null' <<<"$out" >/dev/null 2>&1; then
      why="field:$(jq -r '.missing' <<<"$out" 2>/dev/null)"
    fi
  fi
  if [ -z "$why" ] && jq -c '.rows' <<<"$out" > "$outf" 2>/dev/null && [ -s "$outf" ] \
     && jq -r '.sync.synced_at | strings' <<<"$out" > "$outf.sync" 2>/dev/null && [ -s "$outf.sync" ]; then
    return 0
  fi
  [ -n "$why" ] || why=malformed
  : > "$outf"; : > "$outf.sync"
  _prr_log "list $lr state=$st miss=$why"
  printf '%s\n' "$why"
  return 1
}

pr_record_list_sync() {
  local repo="${1:-}" st="${2:-}" inf="${3:-}" at="${4:-}" lr body out
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [ -n "$st" ] && [ -r "$inf" ] || return 1
  lr=$(_prr_lower "$repo")
  body=$(jq -c --arg r "$lr" --arg s "$st" --arg at "$at" '
    {repo: $r, state: $s,
     rows: [ .[] | {number, fields: ({state: $s, draft, title, author: .user.login, body: (.body // ""),
       pr_created_at: .created_at, url: .html_url, pr_updated_at: .updated_at,
       head_ref: .head.ref, head_sha: .head.sha, base_ref: .base.ref, base_sha: .base.sha,
       labels: [ (.labels // [])[] | .name ]} | with_entries(select(.value != null)))} ]}
    + (if $at != "" then {at: $at} else {} end)' "$inf" 2>/dev/null)
  if [ -z "$body" ] || ! _prr_client || ! out=$(_jobs_req POST /api/pr-record-lists "$body") \
     || ! jq -e '.synced_at | strings' <<<"$out" >/dev/null 2>&1; then
    _prr_log "list-sync $lr failed"
    return 1
  fi
  return 0
}

pr_record_peek() {
  local repo="${1:-}" n="${2:-}" lr out
  _prr_args_ok "$repo" "$n" || return 1
  lr=$(_prr_lower "$repo")
  if ! _prr_client || ! out=$(_jobs_req GET "/api/pr-records?repo=$lr&number=$n") \
     || ! jq -e 'has("row")' <<<"$out" >/dev/null 2>&1; then
    _prr_log "peek $lr#$n miss=unreadable"
    return 1
  fi
  if ! jq -ce 'select((.row | type) == "object") | .row + {age_s: .age_s}' <<<"$out" 2>/dev/null; then
    _prr_log "peek $lr#$n miss=unknown"
    return 1
  fi
}

# _prr_map — a GitHub pulls object on stdin -> the record columns it fills,
# with the absent ones left out. GitHub's mergeable_state "unknown" (it has
# not computed it yet) maps to null and is kept: the record stores NULL, so
# the next get that asks for mergeable_state reads GitHub again (case 2).
_prr_map() {
  jq -c 'select(type == "object") | . as $p |
    ({state: (if .merged_at then "merged" else .state end),
     draft: .draft,
     head_ref: .head.ref, base_ref: .base.ref,
     head_sha: .head.sha, base_sha: .base.sha,
     mergeable_state: .mergeable_state,
     labels: (if (.labels | type) == "array" then [.labels[].name] else null end)}
    | with_entries(select(.value != null and .value != "")))
    + (if $p.mergeable_state == "unknown" then {mergeable_state: null} else {} end)' 2>/dev/null
}

pr_record_get() {
  local repo="${1:-}" n="${2:-}" lr f out row="" reason="" age max tmp grc=0 mapped put=skipped
  _prr_args_ok "$repo" "$n" || return 2
  shift 2
  local want=("$@")
  [ "${#want[@]}" -gt 0 ] || want=(state head_sha)
  for f in ${want[@]+"${want[@]}"}; do
    case " $_PRR_FIELDS " in *" $f "*) ;; *) return 2 ;; esac
  done
  lr=$(_prr_lower "$repo")
  max=$(_prr_max_age)
  if _prr_client && out=$(_jobs_req GET "/api/pr-records?repo=$lr&number=$n") \
     && jq -e 'has("row")' <<<"$out" >/dev/null 2>&1; then
    row=$(jq -c '.row' <<<"$out")
    if [ "$row" = null ]; then
      reason=unknown
    else
      for f in ${want[@]+"${want[@]}"}; do
        case " $_PRR_GH_FIELDS " in *" $f "*) ;; *) continue ;; esac
        if jq -e --arg f "$f" '.[$f] == null' <<<"$row" >/dev/null 2>&1; then reason="field:$f"; break; fi
      done
      if [ -z "$reason" ]; then
        age=$(jq -r '.age_s // empty' <<<"$out")
        if [ "$max" = 0 ] || ! [[ "$age" =~ ^-?[0-9]+$ ]] || [ "$age" -gt "$max" ]; then reason=stale; fi
      fi
    fi
  else
    reason=unreadable
  fi
  if [ -z "$reason" ]; then printf '%s\n' "$row"; return 0; fi

  command -v gh_rest >/dev/null 2>&1 || . "$_PRR_LIBDIR/gh-rest.sh" 2>/dev/null
  if ! command -v gh_rest >/dev/null 2>&1; then
    _prr_log "get $lr#$n reason=$reason gh_rc=75 put=skipped (gh-rest.sh did not load)"
    return 75
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/pr-record.XXXXXX") || return 75
  gh_rest GET "repos/$lr/pulls/$n" > "$tmp" || grc=$?
  if [ "$grc" = 0 ]; then
    mapped=$(_prr_map < "$tmp")
    [ -n "$mapped" ] || grc=75
  fi
  rm -f "$tmp"
  if [ "$grc" != 0 ]; then
    [ "$grc" = 44 ] || grc=75
    _prr_log "get $lr#$n reason=$reason gh_rc=$grc put=skipped"
    return "$grc"
  fi
  # A jobs read that failed would fail the write too: skip it, do not wait twice.
  if [ "$reason" != unreadable ] && [ "$mapped" != "{}" ] && out=$(pr_record_put "$lr" "$n" github "$mapped"); then
    put=ok
    jq -c '.row' <<<"$out"
  else
    [ "$reason" = unreadable ] || put=failed
    printf '%s\n' "$mapped"
  fi
  _prr_log "get $lr#$n reason=$reason gh_rc=0 put=$put"
  return 0
}
