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
#         fresh        the caller set PR_RECORD_FRESH=1 for this one call
#                      (BH-8735: the conductor's merged gate, right after its
#                      own queue_state PUT made a stale `open` row look new)
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
#   pr_record_list <owner/repo> <open|merged|closed> <out-file> [need-csv] [window-n]
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
#       BH-8481: rows also carry merged_at and reviews. With <window-n> (an
#       integer 1..5000) the GET adds &order=created&limit=<n>: the newest n
#       rows by GitHub's created_at, the window `gh pr list --limit n` returns.
#       Then truncated is not a miss (more than n exist, and the reader asked
#       for n). The worker answers 400 (unreadable) when n is above its
#       pr_records.list_limit row. Pass need `-` for no need and a window.
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
#   pr_record_list_sync_gql <owner/repo> <open|merged> <gh-json-file> [at]
#       BH-8481: pr_record_list_sync for a `gh pr list --json` (GraphQL) page,
#       the shape bin/pr-owner-sweep.sh reads. Keys: number title headRefName
#       headRefOid baseRefName author labels body createdAt updatedAt url
#       isDraft mergedAt latestReviews; a key the page lacks writes nothing.
#       author app/x (or a bot) is stored x[bot], the REST spelling.
#       latestReviews becomes reviews, keyed by the bare lowercase login, each
#       {state, commit_id, at}, only when the page holds the array. It never
#       writes mergeable_state: GraphQL's mergeable is not the REST value.
#       An open page must be the WHOLE open list (the worker marks an open
#       record not in it unknown); a merged page is a window (no mark).
#       rc 0 on a 200; else rc 1 and one `list-sync <repo> failed` log line.
#
#   pr_record_list_max_age
#       BH-8452: the resolved PR_RECORD_LIST_MAX_AGE_S (default 900, 0 = off).
#
#   pr_record_open_rest <owner/repo> <out-file> [window-n] [need-cross]
#       BH-9938 C1: pr_record_list <repo> open (with the window when given),
#       mapped to the REST pulls shape the open-list readers use: number title
#       html_url draft body mergeable_state created_at updated_at user.login
#       head.{ref,sha} base.ref base.repo.default_branch labels[].name. The
#       record holds no default branch, so the rows carry `main` only when the
#       default-branch memo of the repo says main. ONE jobs GET, never a GitHub
#       call. rc 0 and <out-file> on a hit, nothing on stdout. rc 1, an empty
#       <out-file> and one miss word on stdout: pr_record_list's word,
#       malformed, or field:default_branch (no memo, or a memo that is not
#       main). rc 2 bad args. user.type is Bot for an author stored as
#       <name>[bot] (the REST spelling), else User; state is open.
#       With the 4th argument `need-cross`, the rows also carry
#       head.repo.full_name and base.repo.full_name, from the cross-repo memo
#       (a fork PR's head repo never changes): base is <owner/repo>; head is
#       <owner/repo> for a PR the memo knows as same-repo, `fork` for one it
#       knows as a fork. A row the memo does not know is the miss field:cross:
#       the record never says "same repo" on its own.
#
#   pr_record_default_branch <owner/repo>
#       The default-branch memo (state/prr-default-branch/<owner>_<repo>) on
#       stdout, rc 0; rc 1 and nothing when there is none.
#   pr_record_default_branch_note <owner/repo> <rest-pulls-json-file> [full]
#       Writes the memo from the first row's base.repo.default_branch of a
#       GitHub list read (tmp + mv). A file with no such value writes nothing.
#       It also writes the cross-repo memo (<memo>.cross, lines <number> TAB
#       <true|false>) from each row's head and base repo full names: `full`
#       (the whole open list) replaces it, else the rows are merged in. Always
#       rc 0: the memos are a cache.
#
#   BH-9935 readers. Each makes ONE jobs GET of the row (the GET of
#   pr_record_peek); a miss writes one logs/pr-record.log line. A value is
#   printed only from an entry whose sha is the asked head (40 hex, any case).
#
#   pr_record_statuses <owner/repo> <number> [head] [row-head]
#       The record's commit statuses of <head> (default the row's head_sha):
#       {<context>: {state, description, sha, at}} on stdout, rc 0. Never a
#       GitHub call, never a write. rc 1 and one `statuses <repo>#<n>
#       miss=<unreadable|unknown|no-head|head|stale|none>` line; the word is
#       also in PRR_MISS_WHY (call it with `> file`, not in $( ), to keep it).
#       rc 2 bad args. BH-9938 C1: `stale` = the row is older than
#       PR_RECORD_FIELD_MAX_AGE_S (default 3900; 0 trusts no row). With
#       the 4th argument `row-head`, `head` = the row's head_sha is not the
#       asked <head> (the PR moved on: the lanes judge the head they hold).
#
#   pr_record_mergify <owner/repo> <number>
#       The newest Mergify queue payload the record holds: {state, code,
#       draft_pr, failing_checks, left_sha, comment_id, at, run_id}, rc 0, as
#       stored. run_id is the payload comment's first /actions/runs/<id> link
#       or null; a row written before BH-9938 has no run_id key. Never a
#       GitHub call, never a write. rc 1 and one `mergify <repo>#<n>
#       miss=<unreadable|unknown|stale|none>` line; the word is also in
#       PRR_MISS_WHY (call it with `> file`, not in $( ), to keep it). rc 2 bad
#       args. BH-9938 C1: `stale` as for pr_record_statuses
#       (PR_RECORD_FIELD_MAX_AGE_S).
#
#   pr_record_head_commit_time <owner/repo> <number> <head>
#       The commit time (ISO, UTC) of <head> on stdout, rc 0. From the record
#       when its head_commit.sha is <head>. Else ONE GitHub read
#       (repos/<r>/commits/<head>, .commit.committer.date), a PUT of
#       {"head_commit": {sha, at}} (source github; skipped when the jobs read
#       failed), then the print. rc 44 GitHub has no such commit; rc 75 GitHub
#       did not answer (nothing printed, no write); rc 2 bad args. One log line
#       per GitHub read: head-commit <repo>#<n> reason=<unreadable|unknown|sha>
#       gh_rc=<rc> put=<ok|failed|skipped>.
#
#   pr_record_files <owner/repo> <number> <head> <out-file>
#       The PR's changed paths, one per line, sorted (LC_ALL=C) and unique, in
#       <out-file>, rc 0. From the record when its files.sha is <head>: a head
#       sha never changes, so the list never needs a refresh and its age does
#       not matter. Else GitHub pulls/<n>/files (100 a page, at most 30 pages,
#       GitHub's own 3,000-file cap), then a PUT of {"files": {sha, paths}}
#       (source github; skipped when the jobs read failed). A list that fills
#       all 30 pages may be cut: it is printed but never stored. rc 75 GitHub
#       failed (<out-file> empty, no write); rc 2 bad args. One log line per
#       GitHub read: files <repo>#<n> reason=<unreadable|unknown|none|sha>
#       gh_rc=<rc> pages=<p> put=<ok|failed|skipped|skipped-cut>.
#
#   pr_record_label_list <owner/repo> <label> <out-file> [open|merged|closed]
#       The PRs in that state (default open) that carry exactly <label> (case
#       as stored), from the record: pr_record_list with need `labels`, then a
#       filter. Its trust rule and answers are pr_record_list's: rc 0 and the
#       rows array in <out-file> (<out-file>.sync holds the stamp), or rc 1 and
#       the miss word on stdout. rc 2 bad args.
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
_PRR_DEFAULT_FIELD_MAX_AGE_S=3900   # fallback only: the knob is PR_RECORD_FIELD_MAX_AGE_S in catalog/lanes.d/_lib.pr-record.knobs.d/

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
  # <fields-json> rides on stdin, never argv: a files list of 3,000 paths is
  # larger than Linux lets one argv string be (MAX_ARG_STRLEN, 128 KB).
  body=$(jq -c --arg r "$(_prr_lower "$repo")" --argjson n "$n" --arg s "$src" --arg at "$at" \
    '{repo:$r, number:$n, source:$s, fields:.} + (if $at != "" then {at:$at} else {} end)' <<<"$fields" 2>/dev/null) || return 1
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

# pr_record_field_max_age — the resolved PR_RECORD_FIELD_MAX_AGE_S (BH-9938 C1).
pr_record_field_max_age() { _prr_knob PR_RECORD_FIELD_MAX_AGE_S "$_PRR_DEFAULT_FIELD_MAX_AGE_S"; }

pr_record_head_fallback_max_age() { _prr_knob PR_RECORD_HEAD_FALLBACK_MAX_AGE_S "$_PRR_DEFAULT_HEAD_FALLBACK_S"; }

pr_record_list_max_age() { _prr_knob PR_RECORD_LIST_MAX_AGE_S "$_PRR_DEFAULT_LIST_MAX_AGE_S"; }

pr_record_list() {
  local repo="${1:-}" st="${2:-}" outf="${3:-}" need="${4:-}" win="${5:-}" lr max q out why="" age
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  case "$st" in open|merged|closed) ;; *) return 2 ;; esac
  [ -n "$outf" ] || return 2
  [ "$need" != - ] || need=""
  [ -z "$need" ] || [[ "$need" =~ ^[a-z_]+(,[a-z_]+)*$ ]] || return 2
  [ -z "$win" ] || { [[ "$win" =~ ^[1-9][0-9]{0,3}$ ]] && [ "$win" -le 5000 ]; } || return 2
  : > "$outf" || return 2
  : > "$outf.sync" || return 2
  lr=$(_prr_lower "$repo")
  max=$(pr_record_list_max_age)
  q="/api/pr-records?repo=$lr&state=$st"
  [ -z "$need" ] || q="$q&need=$need"
  [ -z "$win" ] || q="$q&order=created&limit=$win"
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
    elif [ -z "$win" ] && jq -e '.truncated' <<<"$out" >/dev/null 2>&1; then
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

pr_record_list_sync_gql() {
  local repo="${1:-}" st="${2:-}" inf="${3:-}" at="${4:-}" lr body out
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [ -r "$inf" ] || return 1
  case "$st" in open|merged) ;; *) return 1 ;; esac
  lr=$(_prr_lower "$repo")
  # The checks are the worker's (routes/pr-records.js VALUE_FIELDS): a review
  # entry it would refuse is left out here, so one odd reviewer cannot fail
  # the whole page.
  body=$(jq -c --arg r "$lr" --arg s "$st" --arg at "$at" '
    def nofrac: if type == "string" then sub("\\.[0-9]+Z$"; "Z") else . end;
    def bare: ascii_downcase | ltrimstr("app/") | rtrimstr("[bot]");
    def who: (.login // null) as $l
      | if ($l | type) != "string" or $l == "" then null
        elif ($l | startswith("app/")) or .is_bot == true then ($l | ltrimstr("app/") | rtrimstr("[bot]")) + "[bot]"
        else $l end;
    def rev: if (.latestReviews | type) != "array" then null else
      [ .latestReviews[]? | select(type == "object")
        | {key: ((.author.login // "") | bare),
           value: {state, commit_id: ((.commit.oid // "") | ascii_downcase | if test("^[0-9a-f]{40}$") then . else null end),
                   at: ((.submittedAt // null) | nofrac | if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then . else null end)}}
        | select((.key | test("^[a-z0-9-]{1,39}$"))
                 and (.value.state | IN("APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", "PENDING"))) ]
      | .[:100] | from_entries end;
    {repo: $r, state: $s,
     rows: [ .[] | {number, fields: ({state: $s, title, head_ref: .headRefName, head_sha: (.headRefOid // null | if type == "string" then ascii_downcase else . end),
       base_ref: .baseRefName, author: (.author | if type == "object" then who else null end),
       labels: (if (.labels | type) == "array" then [ .labels[] | .name ] else null end),
       body: (if has("body") then (.body // "") else null end),
       pr_created_at: (.createdAt | nofrac), pr_updated_at: (.updatedAt | nofrac), url,
       draft: .isDraft, merged_at: (.mergedAt | nofrac), reviews: rev}
       | with_entries(select(.value != null)))} ]}
    + (if $at != "" then {at: $at} else {} end)' "$inf" 2>/dev/null)
  if [ -z "$body" ] || ! _prr_client || ! out=$(_jobs_req POST /api/pr-record-lists "$body") \
     || ! jq -e '.synced_at | strings' <<<"$out" >/dev/null 2>&1; then
    _prr_log "list-sync $lr failed"
    return 1
  fi
  return 0
}

# _prr_row <lower-repo> <number> — the row plus age_s as one JSON line. ONE
# jobs GET, no log line. rc 0; rc 1 the read failed; rc 3 the PR has no record.
_prr_row() {
  local out
  _prr_client && out=$(_jobs_req GET "/api/pr-records?repo=$1&number=$2") \
    && jq -e 'has("row")' <<<"$out" >/dev/null 2>&1 || return 1
  jq -ce 'select((.row | type) == "object") | .row + {age_s: .age_s}' <<<"$out" 2>/dev/null || return 3
}

# _prr_why <rc of _prr_row> — its miss word.
_prr_why() { if [ "$1" = 1 ]; then printf unreadable; else printf unknown; fi; }

pr_record_peek() {
  local repo="${1:-}" n="${2:-}" lr rc=0
  _prr_args_ok "$repo" "$n" || return 1
  lr=$(_prr_lower "$repo")
  _prr_row "$lr" "$n" || rc=$?
  [ "$rc" = 0 ] && return 0
  _prr_log "peek $lr#$n miss=$(_prr_why "$rc")"
  return 1
}

_prr_sha_ok() { [[ "${1:-}" =~ ^[0-9a-fA-F]{40}$ ]]; }

_prr_db_file() { # _prr_db_file <owner/repo> — the memo path; rc 1 no root or a bad slug
  local root s
  root=$(_prr_root) || return 1
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  s=$(_prr_lower "${1//\//_}")
  printf '%s/state/prr-default-branch/%s' "$root" "$s"
}

pr_record_default_branch() {
  local f v
  f=$(_prr_db_file "${1:-}") || return 1
  v=$(head -1 "$f" 2>/dev/null)
  [[ "$v" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  printf '%s\n' "$v"
}

pr_record_default_branch_note() {
  local f v rows
  f=$(_prr_db_file "${1:-}") || return 0
  jq -e 'type == "array"' "${2:-/dev/null}" >/dev/null 2>&1 || return 0
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  # The cross-repo memo: only rows that name both repos are known.
  rows=$(jq -r '.[] | select((.number | type) == "number" and (.head.repo.full_name | type) == "string"
          and (.base.repo.full_name | type) == "string")
        | "\(.number)\t\((.head.repo.full_name | ascii_downcase) != (.base.repo.full_name | ascii_downcase))"' "$2" 2>/dev/null)
  if [ "${3:-}" = full ] || [ -n "$rows" ]; then
    { [ "${3:-}" = full ] || cat "$f.cross" 2>/dev/null; printf '%s\n' "$rows"; } \
      | awk -F'\t' 'NF == 2 && $1 ~ /^[0-9]+$/ && ($2 == "true" || $2 == "false") { v[$1] = $2 }
                    END { for (n in v) print n "\t" v[n] }' | sort -n > "$f.cross.tmp.$$" 2>/dev/null \
      && mv -f "$f.cross.tmp.$$" "$f.cross" 2>/dev/null
    rm -f "$f.cross.tmp.$$" 2>/dev/null
  fi
  v=$(jq -r '.[0].base.repo.default_branch // empty' "$2" 2>/dev/null)
  [[ "$v" =~ ^[A-Za-z0-9._/-]+$ ]] || return 0
  [ "$(head -1 "$f" 2>/dev/null)" = "$v" ] && return 0
  printf '%s\n' "$v" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
  rm -f "$f.tmp.$$" 2>/dev/null
  return 0
}

pr_record_open_rest() {
  local repo="${1:-}" out="${2:-}" win="${3:-}" cross="${4:-}" tmp why rc=0 db cf cmap="{}"
  [ -n "$out" ] && [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 2
  : > "$out" 2>/dev/null || return 2
  db=$(pr_record_default_branch "$repo") || db=""
  if [ "$db" != main ]; then echo field:default_branch; return 1; fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/prr-open.XXXXXX") || { echo unreadable; return 1; }
  if [ -n "$win" ]; then why=$(pr_record_list "$repo" open "$tmp" - "$win") || rc=$?
  else why=$(pr_record_list "$repo" open "$tmp") || rc=$?; fi
  if [ "$rc" != 0 ]; then rm -f "$tmp" "$tmp.sync"; echo "${why:-unreadable}"; return 1; fi
  if [ "$cross" = need-cross ]; then
    cf="$(_prr_db_file "$repo").cross"
    cmap=$(awk -F'\t' 'NF == 2 { printf "%s\"%s\":%s", (n++ ? "," : "{"), $1, $2 } END { print (n ? "}" : "{}") }' "$cf" 2>/dev/null) || cmap="{}"
    jq -e . >/dev/null 2>&1 <<<"$cmap" || cmap="{}"
    if ! jq -e --argjson c "$cmap" 'all(.[]; ($c[(.number | tostring)] | type) == "boolean")' "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp" "$tmp.sync"; echo field:cross; return 1
    fi
  fi
  # draft: the worker stores INTEGER 0/1 (routes/pr-records.js); REST is a
  # boolean, and jq reads 0 as true, so it is mapped here.
  if ! jq -c --arg db "$db" --arg repo "$repo" --arg cross "$cross" --argjson c "$cmap" '[.[] | {number, title, html_url: .url,
        state: "open",
        draft: (if .draft == 1 or .draft == true then true elif .draft == 0 or .draft == false then false else null end),
        body, mergeable_state, created_at, updated_at,
        user: {login: .author, type: (if ((.author // "") | endswith("[bot]")) then "Bot" else "User" end)},
        head: ({ref: .head_ref, sha: .head_sha}
               + (if $cross == "need-cross" then {repo: {full_name: (if $c[(.number | tostring)] then "fork" else $repo end)}} else {} end)),
        base: {ref: .base_ref, repo: ({default_branch: $db} + (if $cross == "need-cross" then {full_name: $repo} else {} end))},
        labels: [(.labels // [])[] | {name: .}]}]' "$tmp" > "$out" 2>/dev/null; then
    rm -f "$tmp" "$tmp.sync"; : > "$out"; echo malformed; return 1
  fi
  rm -f "$tmp" "$tmp.sync"
  return 0
}

# _prr_row_fresh <row-json> — rc 0 when the row's age_s is a whole number no
# older than PR_RECORD_FIELD_MAX_AGE_S (default 3900). A knob of 0 trusts no
# row. BH-9938 C1.
_prr_row_fresh() {
  local age max
  age=$(jq -r '.age_s // empty' <<<"${1:-}" 2>/dev/null)
  [[ "$age" =~ ^[0-9]+$ ]] || return 1
  max=$(pr_record_field_max_age)
  [ "$max" -gt 0 ] && [ "$age" -le "$max" ]
}

pr_record_statuses() {
  local repo="${1:-}" n="${2:-}" head="${3:-}" strict="${4:-}" lr row out rc=0 why=""
  _prr_args_ok "$repo" "$n" || return 2
  [ -z "$head" ] || _prr_sha_ok "$head" || return 2
  lr=$(_prr_lower "$repo")
  row=$(_prr_row "$lr" "$n") || rc=$?
  if [ "$rc" != 0 ]; then
    why=$(_prr_why "$rc")
  else
    [ -n "$head" ] || head=$(jq -r '.head_sha | strings' <<<"$row" 2>/dev/null)
    if ! _prr_sha_ok "$head"; then
      why=no-head
    elif [ "$strict" = row-head ] && [ "$(jq -r '.head_sha // "" | ascii_downcase' <<<"$row" 2>/dev/null)" != "$(_prr_lower "$head")" ]; then
      why=head
    elif ! _prr_row_fresh "$row"; then
      why=stale
    elif ! out=$(jq -ce --arg h "$(_prr_lower "$head")" '.statuses | objects
          | with_entries(select((.value | type) == "object" and .value.sha == $h)) | select(length > 0)' <<<"$row" 2>/dev/null); then
      why=none
    fi
  fi
  if [ -n "$why" ]; then _prr_log "statuses $lr#$n miss=$why"; PRR_MISS_WHY=$why; return 1; fi
  printf '%s\n' "$out"
}

pr_record_mergify() {
  local repo="${1:-}" n="${2:-}" lr row out rc=0 why=""
  _prr_args_ok "$repo" "$n" || return 2
  lr=$(_prr_lower "$repo")
  row=$(_prr_row "$lr" "$n") || rc=$?
  if [ "$rc" != 0 ]; then why=$(_prr_why "$rc")
  elif ! _prr_row_fresh "$row"; then why=stale
  elif ! out=$(jq -ce '.mergify_queue | objects' <<<"$row" 2>/dev/null); then why=none
  fi
  if [ -n "$why" ]; then _prr_log "mergify $lr#$n miss=$why"; PRR_MISS_WHY=$why; return 1; fi
  printf '%s\n' "$out"
}

# _prr_gh_load — rc 0 when gh_rest is defined (sourced from bin/lib/gh-rest.sh when not).
_prr_gh_load() {
  command -v gh_rest >/dev/null 2>&1 || . "$_PRR_LIBDIR/gh-rest.sh" 2>/dev/null
  command -v gh_rest >/dev/null 2>&1
}

pr_record_head_commit_time() {
  local repo="${1:-}" n="${2:-}" head="${3:-}" lr row at="" rc=0 reason grc=0 put=skipped tmp
  _prr_args_ok "$repo" "$n" && _prr_sha_ok "$head" || return 2
  lr=$(_prr_lower "$repo"); head=$(_prr_lower "$head")
  row=$(_prr_row "$lr" "$n") || rc=$?
  if [ "$rc" = 0 ]; then
    at=$(jq -r --arg h "$head" '.head_commit | objects | select(.sha == $h) | .at | strings' <<<"$row" 2>/dev/null)
    if [ -n "$at" ]; then printf '%s\n' "$at"; return 0; fi
    reason=sha
  else
    reason=$(_prr_why "$rc")
  fi
  if ! _prr_gh_load; then
    _prr_log "head-commit $lr#$n reason=$reason gh_rc=75 put=skipped (gh-rest.sh did not load)"
    return 75
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/pr-record.XXXXXX") || return 75
  gh_rest GET "repos/$lr/commits/$head" > "$tmp" || grc=$?
  if [ "$grc" = 0 ]; then
    at=$(jq -r '.commit.committer.date | strings | sub("\\.[0-9]+Z$"; "Z")
                | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$tmp" 2>/dev/null)
    [ -n "$at" ] || grc=75
  fi
  rm -f "$tmp"
  if [ "$grc" != 0 ]; then
    [ "$grc" = 44 ] || grc=75
    _prr_log "head-commit $lr#$n reason=$reason gh_rc=$grc put=skipped"
    return "$grc"
  fi
  # A jobs read that failed would fail the write too: skip it.
  if [ "$reason" != unreadable ]; then
    if pr_record_put "$lr" "$n" github "$(jq -nc --arg s "$head" --arg a "$at" '{head_commit: {sha: $s, at: $a}}')" >/dev/null; then put=ok; else put=failed; fi
  fi
  _prr_log "head-commit $lr#$n reason=$reason gh_rc=0 put=$put"
  printf '%s\n' "$at"
}

pr_record_files() {
  local repo="${1:-}" n="${2:-}" head="${3:-}" outf="${4:-}" lr row rc=0 reason grc=0 put=skipped p=0 c=100 raw page fields
  _prr_args_ok "$repo" "$n" && _prr_sha_ok "$head" && [ -n "$outf" ] || return 2
  : > "$outf" || return 2
  lr=$(_prr_lower "$repo"); head=$(_prr_lower "$head")
  row=$(_prr_row "$lr" "$n") || rc=$?
  if [ "$rc" = 0 ]; then
    if jq -e --arg h "$head" '.files | objects | .sha == $h and ((.paths | type) == "array")' <<<"$row" >/dev/null 2>&1; then
      jq -r '.files.paths[] | strings' <<<"$row" | LC_ALL=C sort -u > "$outf"
      return 0
    fi
    if jq -e '.files | objects' <<<"$row" >/dev/null 2>&1; then reason=sha; else reason=none; fi
  else
    reason=$(_prr_why "$rc")
  fi
  if ! _prr_gh_load; then
    _prr_log "files $lr#$n reason=$reason gh_rc=75 pages=0 put=skipped (gh-rest.sh did not load)"
    return 75
  fi
  raw=$(mktemp "${TMPDIR:-/tmp}/pr-record.XXXXXX") || return 75
  page=$(mktemp "${TMPDIR:-/tmp}/pr-record.XXXXXX") || { rm -f "$raw"; return 75; }
  # 30 pages of 100 is GitHub's own 3,000-file cap on pulls/<n>/files.
  while [ "$grc" = 0 ] && [ "$c" -ge 100 ] && [ "$p" -lt 30 ]; do
    p=$((p + 1))
    gh_rest GET "repos/$lr/pulls/$n/files" -F per_page=100 -F "page=$p" > "$page" || grc=$?
    [ "$grc" = 0 ] || break
    c=$(jq -r 'if type == "array" then length else error("not a list") end' "$page" 2>/dev/null) || { grc=75; break; }
    jq -r '.[].filename | strings' "$page" >> "$raw" 2>/dev/null || { grc=75; break; }
  done
  if [ "$grc" != 0 ]; then
    rm -f "$raw" "$page"
    [ "$grc" = 44 ] || grc=75
    _prr_log "files $lr#$n reason=$reason gh_rc=$grc pages=$p put=skipped"
    return "$grc"
  fi
  LC_ALL=C sort -u "$raw" > "$outf"
  rm -f "$raw" "$page"
  if [ "$c" -ge 100 ]; then
    put=skipped-cut   # all 30 pages were full: the list may be cut, so it is never stored
  elif [ "$reason" != unreadable ]; then
    fields=$(jq -R -s -c --arg s "$head" '{files: {sha: $s, paths: (split("\n") | map(select(. != "")))}}' "$outf")
    if pr_record_put "$lr" "$n" github "$fields" >/dev/null; then put=ok; else put=failed; fi
  fi
  _prr_log "files $lr#$n reason=$reason gh_rc=0 pages=$p put=$put"
  return 0
}

pr_record_label_list() {
  local repo="${1:-}" label="${2:-}" outf="${3:-}" st="${4:-open}" rc=0
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [ -n "$label" ] && [ -n "$outf" ] || return 2
  case "$st" in open|merged|closed) ;; *) return 2 ;; esac
  pr_record_list "$repo" "$st" "$outf" labels || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  if ! jq -c --arg l "$label" '[ .[] | select((.labels | type) == "array" and any(.labels[]; . == $l)) ]' "$outf" > "$outf.tmp" 2>/dev/null \
     || ! mv "$outf.tmp" "$outf"; then
    rm -f "$outf.tmp"; : > "$outf"; : > "$outf.sync"
    _prr_log "label-list $(_prr_lower "$repo") state=$st miss=malformed"
    printf 'malformed\n'
    return 1
  fi
  return 0
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
      if [ -z "$reason" ] && [ "${PR_RECORD_FRESH:-0}" = 1 ]; then reason=fresh; fi
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
