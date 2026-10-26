#!/bin/bash
# bin/lib/gh-pr-list.sh — WHO the harness's own PRs are authored by, and the one
# `gh pr list` that finds all of them. Sourced, never executed.
#
# THE SILENCE THIS KILLS (2026-09-14). GitHub App installation tokens went live
# (bin/gh-token.sh, env/github-app.env) and a PR opened on an App token is
# authored by the App, not by the PAT's owner:
#   gh pr view 696 -R example-org/project-5 --json author
#   -> {"login":"app/cromford","is_bot":true}
# Eleven consumers discovered harness PRs with a hardcoded `--author operator`, so
# every App-authored PR was invisible to all of them: project-5 #696/#697 (both
# APPROVE on record, CI green) sat unmerged with not one merge-conductor log
# line, while #737 — same repo, same day, PAT-authored — was enqueued normally.
# The PAT login was never the definition of "ours"; it was the only login we had.
#
# REST PATH (BH-374). When every requested `--json` field is in the mappable
# set below, `harness_pr_list` pages GitHub REST `repos/{owner}/{repo}/pulls`
# once per page instead of one GraphQL `gh pr list` per author. Output uses the
# same GraphQL-ish field names consumers already expect, and the shape is
# identical to the per-author union so callers need no change. Any field outside
# the mappable set falls back to the per-author GraphQL loop.
#
# A READ WE COULD NOT MAKE IS NOT AN ANSWER (BH-782, the #768 incident). Until
# today a REST page that failed was RETRIED over the very `gh pr list` #768
# caught lying: under a GraphQL rate limit that call exits 0 and prints NOTHING,
# `${out:-[]}` turned the silence into `[]`, and an outage reached the caller as
# the FACT "this repo has no open PRs" — with rc 0. Five launch gates acted on
# it. Two rules replace that:
#   * a REST list failure is CLASSIFIED and RETURNED (44/75 via
#     bin/lib/gh-rest.sh), never retried over GraphQL;
#   * on the per-author path an author must exit 0 AND print something to count.
#     Every author silent is rc 1, not an empty list.
# The per-author path itself stays, for the fields REST list responses do not
# carry — since BH-1585 only behind GH_PR_LIST_GRAPHQL_FALLBACK (default off),
# because `files`, `mergeStateStatus` and `mergeable` are now read per PR over
# REST (LAZY FIELDS below) and only `isInMergeQueue` has no REST source at all.
#
# RETURN CODES (this is the contract callers read):
#   0   a list, as JSON. `[]` under rc 0 is a REAL empty.
#   44  HTTP 404 on the REST list — the token cannot see this repo.
#   75  any other unreadable answer: 403/429/other non-2xx, a network failure,
#       a 2xx with an empty or non-array body, or no contract lib on this box.
#   1   the per-author path was used and every author failed or answered empty.
#   65  REFUSED (BH-1585): the isInMergeQueue mergeQueue read came back 200 with
#       GraphQL `errors`. The only non-zero a caller may remember as a fact about
#       the repo; a 44/75 from the same read is a read that did not complete.
# Every non-zero is "list unavailable". No caller may read one as a state.
#
# gh-rest: no-graphql
#
# Mappable fields: number, url, title, body, headRefOid, headRefName,
# baseRefName, isDraft, state, labels, author, createdAt, updatedAt, mergedAt,
# closedAt, isCrossRepository
#
# LAZY FIELDS (BH-1585): mergeStateStatus, mergeable and files are not on a REST
# LIST row, so asking for one used to send the whole list to GraphQL — one
# `gh pr list --author` per author, 11 repos × 12 merge-conductor ticks an hour,
# ~400-580 of the GraphQL bucket's ~4,700/h. They are now read per PR over REST
# AFTER the list, only for the rows it returns: mergeStateStatus/mergeable from
# the single-PR GET's mergeable_state/mergeable (a draft costs no read: it is
# DRAFT), files from pulls/N/files (first 100, as `gh pr list --json files`).
# Every one is a gh_rest GET, so an unchanged PR answers 304 from the ETag
# cache. A per-PR read that fails makes the WHOLE list unavailable (its 44/75),
# never a row that says UNKNOWN: UNKNOWN is GitHub's word for "not computed
# yet", not ours for "could not ask".
#
# isInMergeQueue has no REST source at all: it is ONE GraphQL
# repository.mergeQueue read per base branch per list (_hpl_queued_nums), which
# merge-conductor asks for only on a native-queue repo. That keeps the native
# queue's ejection witness at one GraphQL call per queue repo per tick.
#
# THE PER-AUTHOR GRAPHQL FALLBACK IS OFF (BH-1585). A field outside every set
# above is answered 75 with no call at all. GH_PR_LIST_GRAPHQL_FALLBACK=1 (a
# `lib.gh-pr-list` settings row, catalog/lanes.d/_lib.json) turns the
# per-author `gh pr list` path back on for such a field.
#
# RATE LIMIT IS NOT "NO PRS" (BH-847). An App installation token carries its own
# small bucket, and when it emptied `harness_pr_list` returned rc 1 — so the
# caller logged "list failed this tick" and every PR on that repo was invisible,
# while the box still held two credentials that would have answered. A list that
# fails with a RATE-LIMIT shape is now retried ONCE on the next rung of the
# ladder bin/lib/gh-repo-token.sh owns (app -> default PAT -> admin), one
# logs/gh-pr-list.log line names the rung WORD that answered, and GH_TOKEN is put
# back to the caller's own before returning either way. A 404 is NOT a
# fall-through: an invisible repo keeps its existing alert path untouched.
#
# Environment:
#   GH_PR_LIST_REST_PAGES — how deep the REST walk may look, in pages of 100
#     rows: default 3, i.e. at most 300 raw rows before the author filter.
#
# THE WALK STOPS AT THE LIMIT (BH-1584, gh-reads audit 2026-09-23). It used to
# page until a short page or the cap and only then cut the answer to `limit`:
# merge-conductor's 30-row closed list read three full pages of 100 every tick,
# about 500 of its 640 GET R/pulls an hour. Now the walk ends on the first page
# that brings the KEPT rows up to `limit`. Pages stay full (per_page=100): the
# author filter runs on every REST row, so a page sized to `limit` almost never
# holds `limit` of ours — per_page=30 took project-9 (11 of ours in 300 closed)
# from 3 requests to 10 (#1591 review). At full pages a walk costs
# ceil(pos/100) requests, never more than before, and the SCAN DEPTH is
# unchanged (GH_PR_LIST_REST_PAGES pages of 100), so no caller gets a shorter
# answer. Closed, merged and all lists are sorted by `updated`, newest first: by
# `created`, an old PR that closed a minute ago sat below `limit` younger ones
# and was never listed. Open lists keep `created`. A PR updated mid-walk can
# shift one row across a page boundary under `updated`; with full pages nearly
# every walk is one request, and the next tick sees anything skipped.
#
#   harness_pr_authors        -> the author set, space separated, in list order
#   harness_pr_spellings      -> every spelling of every author, one per line
#   harness_pr_authors_csv    -> those spellings comma separated (SELF_ACTORS)
#   harness_pr_authors_json   -> those spellings as a JSON array (jq --argjson)
#   harness_pr_author_match <login>
#                             -> rc 0 when that login is one of ours, in any of
#                                its spellings (`app/x`, `x[bot]`, `x`)
#   harness_pr_list <owner/repo> <open|closed|merged> <json-fields> [limit]
#                             -> JSON array of PRs. REST is used when every
#                                requested field is mappable; otherwise one
#                                `gh pr list` per author is unioned by number.
#                                rc 0/44/75/1 per the table above; no output on
#                                any non-zero.
#
# THE SET IS ONE STRING, not a scatter of literals: HARNESS_PR_AUTHORS, default
# "operator app/cromford app/cromford-builders". A box that renames an
# App sets it once in env/global.env, or names GH_APP_SLUG in env/github-app.env
# or in an App profile's env/github-app-<profile>.env, and the `app/<slug>` form
# is derived here. Nothing else may hardcode a login.
#
# THE SECOND APP IS IN THE DEFAULT (BH-1668). BH-1578 moved pool builders onto
# cromford-builders, so from 2026-09-23 every pool-built PR was authored
# `cromford-builders[bot]`; neither env file names a slug, the filter below
# dropped them all, and merge-conductor logged `prs=0` on project-5 for 22 hours
# over 14 green, approved PRs. A login the set does not know is now reported
# (UNKNOWN-AUTHOR, _hpl_unknown_authors) instead of vanishing.
_HPL_H="${HARNESS:-/root/harness}"
# GitHub's own per_page ceiling for REST list endpoints — an API fact, not a
# tunable; GH_PR_LIST_REST_PAGES is counted in pages of this size.
_HPL_REST_PAGE_MAX=100
# BH-4080: the operator login is HARNESS_OPERATOR_LOGIN, from the deployment
# defaults home. Soft, beside this file then the harness copy, because a
# hundred-odd suites copy this lib alone: missing, the login is simply absent
# from the default set (the two Apps stay), never a guessed one.
for _P in "${HARNESS_DEPLOYMENT_FILE-}" "${BASH_SOURCE[0]%/*}/deployment.sh" "$_HPL_H/bin/lib/deployment.sh"; do
  # shellcheck source=bin/lib/deployment.sh
  [ -r "$_P" ] && . "$_P" && break
done
unset _P
HARNESS_PR_AUTHORS_DEFAULT="${HARNESS_OPERATOR_LOGIN:-} app/cromford app/cromford-builders"

# The REST contract (#780). Beside this file first, then the harness copy — the
# same two-rung source bin/triage-gate.sh uses for THIS file, so a worktree run
# and a live-box run pick the same library. Sourcing costs no API budget and
# cannot kill a caller; a box without it is handled at the call site, not here.
for _P in "${BASH_SOURCE[0]%/*}/gh-rest.sh" "$_HPL_H/bin/lib/gh-rest.sh"; do
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "$_P" ] && { . "$_P"; break; }
done
unset _P

# Each App's own login, when this box has Apps configured: env/github-app.env and
# every App profile, env/github-app-<profile>.env (BH-1578's second App). The
# files are READ, not sourced: sourcing them here would export GH_APP_* into
# every consumer that only wanted a list of PRs. GitHub slugs an App name the
# way it slugs anything — lowercase, runs of non-alphanumerics collapse to one
# dash. One login per line, hub App first, profiles in glob order.
_hpl_app_login() { _hpl_app_login_from "$_HPL_H/env/github-app.env" "$_HPL_H"/env/github-app-*.env; }
_hpl_app_login_from() { # _hpl_app_login_from <env-file>... — one app/<slug> per file that names one
  local f raw
  for f in "$@"; do
    [ -r "$f" ] || continue
    raw=$(sed -n 's/^\(export \)\{0,1\}GH_APP_SLUG=//p;s/^\(export \)\{0,1\}GH_APP_NAME=//p' \
          "$f" 2>/dev/null | tr -d "\"'" | head -n 1)
    [ -n "$raw" ] || continue
    raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    [ -n "$raw" ] && printf 'app/%s\n' "$raw"
  done
  return 0
}

harness_pr_authors() { # -> "<operator login> app/cromford app/cromford-builders ...", stable order, no duplicates
  local a out="" extra
  for a in ${HARNESS_PR_AUTHORS:-$HARNESS_PR_AUTHORS_DEFAULT} $(_hpl_app_login); do
    case " $out " in *" $a "*) continue ;; esac
    out="${out:+$out }$a"
  done
  printf '%s\n' "$out"
}

# A login stripped to the name GitHub would show without its plumbing:
# `app/cromford` and `cromford[bot]` are the SAME actor spelled by two
# different APIs (GraphQL, which `gh pr list --json author` uses, and REST,
# which `gh api repos/*/pulls` uses). Compare the bare names or the two never meet.
_hpl_bare() { local l="${1#app/}"; printf '%s' "${l%\[bot\]}"; }

# ---- WHO MAY ISSUE A VERDICT: a SEPARATE, NARROWER set (BH-1668) -----------
# Listing a PR and issuing a verdict are different trust. The builders App
# (cromford-builders) is the identity the POOL build boxes hold — the boxes
# where the LLM build agent runs — so it opens PRs and belongs in the author set
# above, but a `harness-review-autopilot` marker or a harness-footer review it
# posts must never count as a verdict: that would let a (prompt-injected) build
# approve its own PR. HARNESS_VERDICT_AUTHORS, default "app/cromford",
# is the set every verdict reader consults (bin/lib/mc/classify.sh
# mc_autopilot_verdict, bin/review-autopilot.sh, bin/review-prs.sh's own-review
# readers, bin/blocked-resolver.sh br_review_newest). Only the HUB App's slug
# (env/github-app.env) is unioned in — an App PROFILE file never grants verdict
# trust. The knob is registered in catalog/lanes.d/_lib.json with
# `settable: false`: a trust list is set in env/global.env by the operator,
# never by a settings row a worker credential could write.
# The set holds Apps only (BH-8419). The operator login (HARNESS_OPERATOR_LOGIN)
# is a PERSON: on PR #8351 the cap-notes lane read its CHANGES_REQUESTED as the
# harness's own and dismissed it. So harness_verdict_authors drops the operator
# login even when an env override lists it, and harness_verdict_author_match
# answers 0 only for an App spelling (`app/<slug>` or `<slug>[bot]`). "A PR the
# operator opened for the fleet" is harness_pr_author_match, which keeps it.
HARNESS_VERDICT_AUTHORS_DEFAULT="app/cromford"
harness_verdict_authors() { # -> "app/cromford ...", stable order, no duplicates, never the operator login
  local a out="" op
  op=$(_hpl_bare "${HARNESS_OPERATOR_LOGIN:-}")
  for a in ${HARNESS_VERDICT_AUTHORS:-$HARNESS_VERDICT_AUTHORS_DEFAULT} $(_hpl_app_login_from "$_HPL_H/env/github-app.env"); do
    [ -n "$op" ] && [ "$(_hpl_bare "$a")" = "$op" ] && continue
    case " $out " in *" $a "*) continue ;; esac
    out="${out:+$out }$a"
  done
  printf '%s\n' "$out"
}
harness_verdict_author_match() { # harness_verdict_author_match <login>; rc 0 = may issue a verdict
  local want a
  # Bot-only (BH-8419): a plain login is a person, whatever the set says.
  case "${1:-}" in app/?*|?*\[bot\]) ;; *) return 1 ;; esac
  want=$(_hpl_bare "${1:-}")
  [ -n "$want" ] || return 1
  for a in $(harness_verdict_authors); do
    [ "$(_hpl_bare "$a")" = "$want" ] && return 0
  done
  return 1
}
harness_verdict_authors_json() { # -> every spelling of every verdict author, JSON array
  local a bare
  for a in $(harness_verdict_authors); do
    printf '%s\n' "$a"
    case "$a" in app/*) bare=$(_hpl_bare "$a"); printf '%s[bot]\n%s\n' "$bare" "$bare" ;; esac
  done | jq -R . | jq -sc .
}

harness_pr_author_match() { # harness_pr_author_match <login>; rc 0 = one of ours
  local want a
  want=$(_hpl_bare "${1:-}")
  [ -n "$want" ] || return 1
  for a in $(harness_pr_authors); do
    [ "$(_hpl_bare "$a")" = "$want" ] && return 0
  done
  return 1
}

# Every spelling of every author, one per line: an App login appears three times
# (`app/x`, `x[bot]`, `x`) because GraphQL, REST and a git author name each pick
# a different one, and a consumer that compares strings has to be handed all of
# them rather than guess which API its data came from.
harness_pr_spellings() {
  local a bare
  for a in $(harness_pr_authors); do
    printf '%s\n' "$a"
    case "$a" in app/*) bare=$(_hpl_bare "$a"); printf '%s[bot]\n%s\n' "$bare" "$bare" ;; esac
  done
}

harness_pr_authors_csv() { # -> every spelling, comma separated (SELF_ACTORS et al)
  harness_pr_spellings | paste -sd, -
}

harness_pr_authors_json() { # -> every spelling as a JSON array (jq --argjson)
  harness_pr_spellings | jq -R . | jq -sc .
}

# Set by the two gh call sites below when the failure they saw was a rate limit,
# read by harness_pr_list to decide whether a second rung is worth a call.
_HPL_LIMITED=0

# NARROWLY (D10): "rate limit" anywhere in the text, or an HTTP 429. A bare 403 is
# a permission failure, a 404 is an invisible repo, and neither gets a retry.
_hpl_is_limited() { # _hpl_is_limited <text>
  local t
  t=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  [ -n "$t" ] || return 1
  case "$t" in
    *"rate limit"*|*"ratelimit"*) return 0 ;;
    *"http 429"*|*"too many requests"*) return 0 ;;
  esac
  return 1
}
# Read a gh stderr capture, classify it, and drop the file.
_hpl_note_stderr() { # _hpl_note_stderr <file>
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  _hpl_is_limited "$(cat "$f" 2>/dev/null)" && _HPL_LIMITED=1
  rm -f "$f"
  return 0
}

_hpl_log() {
  mkdir -p "$_HPL_H/logs" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$_HPL_H/logs/gh-pr-list.log" 2>/dev/null || true
}

# THE FILTER IS NEVER SILENT (BH-1668). An open PR on a harness branch
# (ticket/*) whose author is not in the set is dropped exactly as before — the
# set still decides what is ours — but it is no longer dropped quietly: every
# read logs one UNKNOWN-AUTHOR line naming the repo, the PRs and the logins, and
# the first such read of the day for a repo raises a fleet alert. That is the
# shape BH-1668 hid for 22 hours: a readable list that the filter emptied, which
# every lane downstream read as "no PRs". Open lists only: closed history holds
# PRs by anyone, forever, and none of them is waiting on us.
#   _hpl_unknown_authors <owner/repo> <page-file> <authors-bare-json>
_hpl_unknown_authors() {
  local slug="$1" page="$2" bare="$3" found flag line
  found=$(jq -r --argjson a "$bare" '
      [ .[]? | select((.head.ref // "") | startswith("ticket/"))
             | select(((.user.login // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "")) as $l | ($a | index($l)) | not)
             | "#\(.number) \(.user.login // "?")" ] | join(", ")' "$page" 2>/dev/null) || return 0
  [ -n "$found" ] || return 0
  line="$slug (open): UNKNOWN-AUTHOR harness-branch PR(s) dropped by the author filter: $found — every harness lane reads them as absent until the login is in HARNESS_PR_AUTHORS (or GH_APP_SLUG in env/github-app*.env)"
  _hpl_log "$line"
  mkdir -p "$_HPL_H/flags" 2>/dev/null
  flag="$_HPL_H/flags/alerted-pr-author-unknown-${slug//\//_}-$(date -u +%Y%m%d)"
  [ -f "$flag" ] && return 0
  touch "$flag" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [gh-pr-list] $line" >> "$_HPL_H/logs/ALERTS.log" 2>/dev/null
  [ -x "$_HPL_H/bin/beat.sh" ] && "$_HPL_H/bin/beat.sh" "$(jq -nc --arg akey "prauthorunknown:$slug" --arg l "[gh-pr-list] $line" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1
  return 0
}

# Return 0 only when every requested `--json` field is in the strictly mappable
# REST set. One unknown field keeps the safe per-author GraphQL path.
_hpl_rest_ok() {
  local f
  [ -n "${1:-}" ] || return 1
  for f in $(printf '%s' "$1" | tr ',' ' '); do
    case "$f" in
      number|url|title|body|headRefOid|headRefName|baseRefName|isDraft|state|labels|author|createdAt|updatedAt|mergedAt|closedAt|isCrossRepository) ;;
      mergeStateStatus|mergeable|files|isInMergeQueue) ;; # BH-1585: lazy, see _hpl_lazy_list
      *) return 1 ;;
    esac
  done
  return 0
}

# The REST rows in <file>, kept to HARNESS_PR_AUTHORS (and to merged_at for
# `merged`), mapped to the field names consumers use and cut to <req-json>'s
# keys. One copy, read by the page loop and by the snapshot path below.
_hpl_map_rows() { # _hpl_map_rows <state> <authors-bare-json> <req-json> <file>
  jq -n --arg state "$1" --argjson authors_bare "$2" --argjson req "$3" -f /dev/stdin "$4" <<'JQ'
input as $rows
| $rows
| map(
    . as $pr
    | select(
        .user.login as $l
        | ($l | sub("^app/"; "") | sub("\\[bot\\]$"; "")) as $bare
        | $authors_bare | index($bare)
      )
    | select(if $state == "merged" then (.merged_at != null) else true end)
    | ({
        number: $pr.number,
        url: $pr.html_url,
        title: $pr.title,
        body: $pr.body,
        headRefOid: $pr.head.sha,
        headRefName: $pr.head.ref,
        baseRefName: $pr.base.ref,
        isDraft: $pr.draft,
        author: {login: $pr.user.login, is_bot: ($pr.user.type == "Bot")},
        createdAt: $pr.created_at,
        updatedAt: $pr.updated_at,
        mergedAt: $pr.merged_at,
        closedAt: $pr.closed_at,
        labels: $pr.labels,
        isCrossRepository: (($pr.head.repo.full_name // null) != ($pr.base.repo.full_name // null)),
        state: (if $pr.merged_at then "MERGED" else ($pr.state | ascii_upcase) end)
      }) as $full
    | $req | reduce .[] as $k ({}; . + {($k): $full[$k]})
  )
JQ
}

# BH-4659 (BH-4656.1): a lane that exports HPL_SNAPSHOT=1 (merge-conductor,
# batch-resolve) lists through bin/lib/pr-snapshot.sh's shared snapshot. Only
# while that lib is loaded AND on (_prs_on: PR_SNAPSHOT=1, a TTL above 0), so
# PR_SNAPSHOT=0 puts back today's requests exactly, not just "no cache".
_hpl_snap_on() {
  [ "${HPL_SNAPSHOT:-}" = 1 ] && command -v prs_open_list >/dev/null 2>&1 \
    && command -v prs_pr_get >/dev/null 2>&1 && command -v _prs_on >/dev/null 2>&1 && _prs_on
}

# Page GitHub REST pulls for a single owner/repo/state and emit a JSON array
# mapped to the field names consumers already use. A failure is CLASSIFIED and
# RETURNED (44/75) — never retried over GraphQL, and never mapped to an empty
# list. See the RETURN CODES block in the header.
_hpl_rest_list() {
  local slug="${1:?owner/repo}" state="${2:?open|closed|merged}" fields="${3:?json fields}" limit="${4:-100}"
  local pages="${GH_PR_LIST_REST_PAGES:-3}" page rest_state sort page_file rc
  local per_page="$_HPL_REST_PAGE_MAX" bare_authors_json req_json page_mapped acc="[]" page_len cap_reached=0
  local log_slug="$slug ($state)" why

  # A state REST cannot express is a question we never asked GitHub, not an
  # answer we could not read: the per-author path is still the right one.
  case "$state" in
    open|closed|merged|all) : ;;
    *) _hpl_log "$log_slug: REST state '$state' not supported — falling back to gh pr list"
       _harness_pr_list_fallback "$slug" "$state" "$fields" "$limit"
       return $? ;;
  esac

  # A limit that is not a positive integer is a caller bug, not a question for
  # GitHub: refuse it before a single request is spent (rc 1, "list failed").
  case "$limit" in
    ''|*[!0-9]*) _hpl_log "$log_slug: limit '$limit' is not a positive integer — no request made"; return 1 ;;
  esac
  limit=$((10#$limit))
  [ "$limit" -gt 0 ] || { _hpl_log "$log_slug: limit 0 asks for nothing — no request made"; return 1; }

  # A missing contract lib is the same CLASS of answer as a 403: we cannot ask,
  # so we do not guess. 75, with the reason written down.
  if ! command -v gh_rest >/dev/null 2>&1; then
    _hpl_log "$log_slug: bin/lib/gh-rest.sh (the REST contract) is not readable on this box — list unavailable"
    return 75
  fi

  # GitHub REST has no 'merged' state; closed + merged_at != null is the filter.
  case "$state" in
    merged) rest_state="closed" ;;
    *) rest_state="$state" ;;
  esac
  # Closed-side lists by last activity (BH-1584); open lists as they always were.
  case "$state" in
    open) sort="created" ;;
    *) sort="updated" ;;
  esac

  bare_authors_json=$(harness_pr_authors | tr ' ' '\n' | while read -r a; do
    [ -n "$a" ] && printf "%s\n" "$(_hpl_bare "$a")"
  done | jq -R . | jq -sc .)

  req_json=$(printf '%s' "$fields" | jq -R 'split(",")')

  # The snapshot answers the open list in ONE read shared by every lane of the
  # tick. Its failures are a failed page's: classified, logged, returned.
  if [ "$state" = open ] && _hpl_snap_on; then
    page_file=$(mktemp); rc=0
    prs_open_list "$slug" "$page_file" || rc=$?
    if [ "$rc" != 0 ]; then
      rm -f "$page_file"
      case "${GH_REST_REASON:-}:${GH_REST_STATUS:-}" in
        rate-limit:*|*:429) _HPL_LIMITED=1 ;; # gh-mutate: rung-arm
      esac
      _hpl_log "$log_slug: REST list unavailable (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — not retried over GraphQL (#768)"
      return "$rc"
    fi
    if ! jq -e 'type == "array"' "$page_file" >/dev/null 2>&1; then # REST-ARRAY-GUARD
      rm -f "$page_file"
      _hpl_log "$log_slug: REST list unavailable (not an array) — a 2xx we cannot read is not an empty list"
      return 75
    fi
    _hpl_unknown_authors "$slug" "$page_file" "$bare_authors_json"
    # Today's page cap: the same first pages*per_page rows the loop would see.
    page_len=$(jq 'length' "$page_file") || { rm -f "$page_file"; return 1; }
    if [ "$page_len" -ge $((pages * per_page)) ]; then
      jq ".[:$((pages * per_page))]" "$page_file" > "$page_file.cap" && mv -f "$page_file.cap" "$page_file" || { rm -f "$page_file" "$page_file.cap"; return 1; }
      cap_reached=1
    fi
    acc=$(_hpl_map_rows "$state" "$bare_authors_json" "$req_json" "$page_file") || { rm -f "$page_file"; return 1; }
    rm -f "$page_file"
    if [ "$cap_reached" = 1 ] && [ "$(jq 'length' <<<"$acc")" -lt "$limit" ]; then
      _hpl_log "$log_slug: REST page cap reached after $pages pages of $per_page rows"
    fi
    printf '%s\n' "$acc" | jq ".[:$limit]" || return 1
    return 0
  fi

  for ((page=1; page<=pages; page++)); do
    page_file=$(mktemp); rc=0
    # `> file`, never `$( )`: GH_REST_STATUS is set in the shell that CALLS the
    # helper, and a command substitution takes it to the grave.
    gh_rest GET "repos/$slug/pulls?state=$rest_state&per_page=$per_page&sort=$sort&direction=desc&page=$page" \
      >"$page_file" || rc=$?
    if [ "$rc" != 0 ]; then
      rm -f "$page_file"
      # BH-847's rung ladder arms off _HPL_LIMITED, which used to come from gh's
      # stderr. gh_rest swallows stderr, so the limit shape is read from the
      # classified status instead — without this line the one-retry-on-the-next-
      # token-rung below silently stops firing.
      case "${GH_REST_REASON:-}:${GH_REST_STATUS:-}" in
        rate-limit:*|*:429) _HPL_LIMITED=1 ;; # gh-mutate: rung-arm
      esac
      _hpl_log "$log_slug: REST list unavailable (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — not retried over GraphQL (#768)"
      # gh-mutate: rest-failure-is-final
      return "$rc"
    fi

    if ! jq -e 'type == "array"' "$page_file" >/dev/null 2>&1; then # REST-ARRAY-GUARD
      why=$(jq -r '.message? // "not an array"' "$page_file" 2>/dev/null || echo "not an array")
      _hpl_is_limited "$why" && _HPL_LIMITED=1
      rm -f "$page_file"
      _hpl_log "$log_slug: REST list unavailable ($why) — a 2xx we cannot read is not an empty list"
      return 75
    fi

    page_len=$(jq 'length' "$page_file") || { rm -f "$page_file"; return 1; }
    [ "$state" = open ] && _hpl_unknown_authors "$slug" "$page_file" "$bare_authors_json"

    page_mapped=$(_hpl_map_rows "$state" "$bare_authors_json" "$req_json" "$page_file") || { rm -f "$page_file"; return 1; }
    rm -f "$page_file"

    acc=$(jq -s '.[0] + .[1]' <(printf '%s\n' "$acc") <(printf '%s\n' "$page_mapped")) || return 1

    # Enough kept rows, or a short page (GitHub has no more): either ends it.
    if [ "$(jq 'length' <<<"$acc")" -ge "$limit" ] || [ "$page_len" -lt "$per_page" ]; then
      break
    elif [ "$page" -eq "$pages" ]; then
      cap_reached=1
    fi
  done

  if [ "$cap_reached" = 1 ]; then
    _hpl_log "$log_slug: REST page cap reached after $pages pages of $per_page rows"
  fi

  printf '%s\n' "$acc" | jq ".[:$limit]" || return 1
}

_harness_pr_list_fallback() {
  local slug="${1:?owner/repo}" state="${2:?open|closed|merged}" fields="${3:?json fields}" limit="${4:-100}"
  local a out ok=0 acc="" joined err_file
  for a in $(harness_pr_authors); do
    err_file=$(mktemp)
    # EXIT 0 **AND** SOMETHING ON STDOUT (#768). A rate-limited GraphQL `gh pr
    # list` exits 0 and prints nothing; the old `${out:-[]}` read that silence
    # as "this author has no PRs" and one silent author was enough to answer the
    # whole call rc 0 with an empty list. An author that said nothing said
    # nothing.                                    # gh-mutate: empty-is-failure
    if out=$(gh pr list -R "$slug" --state "$state" --author "$a" --limit "$limit" --json "$fields" 2>"$err_file") && [ -n "$out" ]; then # gh-guard-allow: files/mergeStateStatus/mergeable/isInMergeQueue are GraphQL-only LIST fields (merge-conductor, rebase-train-ahead, batch-resolve, overlap-guard) — reached only for an unmappable field, never on a REST failure
      rm -f "$err_file"
      ok=1; acc="$acc$out"$'\n'
    else
      _hpl_note_stderr "$err_file"
      _hpl_log "$slug ($state): gh pr list --author $a failed or answered nothing — the rest of HARNESS_PR_AUTHORS still counts"
    fi
  done
  [ "$ok" = 1 ] || return 1
  # Union by PR number, FIRST-SEEN order: the same repo listed twice must give
  # the same array in the same order every tick, or a consumer keyed on "the
  # first N rows" would see work appear and disappear. `select(type=="array")`
  # keeps one author's non-array answer from poisoning the other's.
  joined=$(printf '%s' "$acc" | jq -s '
      reduce (.[] | select(type == "array") | .[]) as $p
        ({seen: {}, out: []};
         ($p.number | tostring) as $k
         | if .seen[$k] then . else .seen[$k] = true | .out += [$p] end)
      | .out' 2>/dev/null) && [ -n "$joined" ] || {
    _hpl_log "$slug ($state): the per-author lists would not union (jq) — treated as a failed list"
    return 1; }
  printf '%s\n' "$joined"
}

_hpl_run_list() { # _hpl_run_list <slug> <state> <fields> <limit>
  if _hpl_rest_ok "$3"; then
    if _hpl_wants_lazy "$3"; then _hpl_lazy_list "$1" "$2" "$3" "$4"
    else _hpl_rest_list "$1" "$2" "$3" "$4"; fi
  elif _hpl_fallback_on; then
    _harness_pr_list_fallback "$1" "$2" "$3" "$4"
  else
    _hpl_log "$1 ($2): '$3' asks for a field REST cannot carry and the GraphQL fallback is off (GH_PR_LIST_GRAPHQL_FALLBACK) — list unavailable, nothing asked (BH-1585)"
    return 75
  fi
}

# ---- BH-1585: the lazy fields ------------------------------------------------
_hpl_wants_lazy() { # rc 0 when the field set names a lazy field
  case ",$1," in *,mergeStateStatus,*|*,mergeable,*|*,files,*|*,isInMergeQueue,*) return 0 ;; esac
  return 1
}

# isInMergeQueue has NO REST source. It is the native merge queue's only
# witness (merge-conductor's ejection check reads it off the list), so it is ONE
# GraphQL read per base branch per list — repository.mergeQueue.entries — not
# one `gh pr list` per author. It goes through gh_rest, so it is ledgered, and
# the ledger files it under the graphql bucket (GitHub's x-ratelimit-resource
# header). A repo with no queue answers mergeQueue: null, which is "nothing
# queued". An answer with `errors`, or no repository, is rc 65 (REFUSED); a read
# that did not complete is 44/75. Neither is ever "not queued".
_HPL_MQ_QUERY='query($owner:String!,$name:String!,$branch:String!){repository(owner:$owner,name:$name){mergeQueue(branch:$branch){entries(first:100){nodes{pullRequest{number}}}}}}'
_hpl_queued_nums() { # _hpl_queued_nums <slug> <branch> <outfile> -> PR numbers, one per line
  local rc=0
  # HPL_READ_ROLE names the read for the ledger and for test stubs; it is in the
  # environment of THIS call only (a prefix assignment), never of anything else.
  HPL_READ_ROLE=list-mergequeue gh_rest POST graphql -f "query=$_HPL_MQ_QUERY" \
    -f "owner=${1%%/*}" -f "name=${1#*/}" -f "branch=$2" > "$3" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  # A 200 with `errors` (or no repository) is GitHub REFUSING the query: rc 65,
  # the one answer a caller may remember. Anything above is transport: 44/75.
  jq -e '(.errors // [] | length) == 0 and (.data.repository != null)' "$3" >/dev/null 2>&1 || return 65
  jq -r '.data.repository.mergeQueue.entries.nodes[]?.pullRequest.number // empty' "$3" > "$3.n" 2>/dev/null || return 75
  mv -f "$3.n" "$3"
}

# The operator switch, resolved once per process through the settings contract
# (bin/lib/lane-gate.sh lib_env_apply, sourced lazily as bin/lib/wake-lanes.sh
# does). No row, no env: off.
_HPL_FB_RESOLVED=0
_hpl_fallback_on() {
  if [ "$_HPL_FB_RESOLVED" = 0 ]; then
    _HPL_FB_RESOLVED=1
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      local g
      for g in "${BASH_SOURCE[0]%/*}/lane-gate.sh" "$_HPL_H/bin/lib/lane-gate.sh"; do
        # shellcheck source=bin/lib/lane-gate.sh
        [ -r "$g" ] && { . "$g" 2>/dev/null; break; }
      done
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply gh-pr-list
  fi
  [ "${GH_PR_LIST_GRAPHQL_FALLBACK:-}" = 1 ]
}

# One per-PR GET into a file; the caller reads GH_REST_* from its own shell.
# HPL_READ_ROLE=list-lazy rides in the environment of this one call (a prefix
# assignment on a function is exported for its duration and no longer): it says
# "the list's own per-PR read", explicitly, to anything that has to tell it
# apart from a lane's decision read of the same path (tests/lib/gh-list-bridge.sh).
_hpl_pr_get() { # _hpl_pr_get <slug> <num> <sub-path-or-empty> <outfile>
  HPL_READ_ROLE=list-lazy gh_rest GET "repos/$1/pulls/$2${3:+/$3}" > "$4"
}

# The merge-state read of one row. Under the snapshot (BH-4659) it is
# prs_pr_get, keyed on the row's head, updated_at and base: a PR that has not
# changed since the last read is answered from disk. A `-` in the key is a
# live read, counted a miss.
#   * CI moves blocked/unstable/has_hooks without touching the key: GitHub does
#     not bump updated_at on check-run or status events (BH-1486's memo), and
#     the wakes sibling that would invalidate on check_suite/status is not
#     landed. So a stored body in one of those states is never served: its key
#     is dropped first, prs_pr_get misses and reads GitHub live, and a WAIT_CI
#     row sees its own CI go green on the next tick (review F1). Only states CI
#     cannot change (clean, dirty, behind, draft) are answered from disk.
# BH-8457: a lane that exports HPL_PR_RECORD=1 (merge-conductor only) asks the
# PR record FIRST (prr_serve_state, bin/lib/pr-record-serve.sh): one jobs GET,
# no GitHub call. It serves any state, CI's included, while the record is at
# most PR_RECORD_SERVE_MAX_AGE_S old (default 120) at the list head, so a
# WAIT_CI row sees its CI go green within that window rather than on the next
# tick; the conductor's enqueue decision still reads the PR live. On a miss the
# read below runs unchanged, and a LIVE answer is written back into the record
# (prr_serve_note). A snapshot hit is not written back: it is a disk body, and
# the record must hold only what GitHub said at the time of the write.
_hpl_state_get() { # _hpl_state_get <slug> <num> <outfile> [head updated_at base]
  local sd rec=0 rc=0 cf="" hit=0
  if [ "${HPL_PR_RECORD:-}" = 1 ] && command -v prr_serve_state >/dev/null 2>&1; then
    rec=1
    prr_serve_state "$1" "$2" "${4:-}" "$3" && return 0
  fi
  if [ -n "${4:-}" ] && _hpl_snap_on; then
    if command -v _prs_dir >/dev/null 2>&1 && sd=$(_prs_dir "$1") \
       && jq -e '(.mergeable_state // "") | ascii_downcase | IN("blocked", "unstable", "has_hooks")' \
            "$sd/pr-$2.json" >/dev/null 2>&1; then
      rm -f "$sd/pr-$2.key"
    fi
    # Under the record, the snapshot's HIT/MISS word goes through a file of
    # this call's own first, so a hit is told apart from a live read.
    [ "$rec" = 1 ] && cf=$(mktemp 2>/dev/null)
    PRS_COUNT_FILE="${cf:-${PRS_COUNT_FILE:-}}" HPL_READ_ROLE=list-lazy prs_pr_get "$1" "$2" "$4" "${5:--}" "${6:--}" "$3" || rc=$?
    if [ -n "$cf" ]; then
      grep -q '^HIT ' "$cf" 2>/dev/null && hit=1
      [ -n "${PRS_COUNT_FILE:-}" ] && cat "$cf" >> "$PRS_COUNT_FILE" 2>/dev/null
      rm -f "$cf"
    fi
  else
    _hpl_pr_get "$1" "$2" "" "$3" || rc=$?
  fi
  [ "$rc" = 0 ] && [ "$rec" = 1 ] && [ "$hit" = 0 ] && prr_serve_note "$1" "$2" "$3"
  return "$rc"
}

# BH-8457: HPL_LAZY_ONLY="<n> <n> …" (merge-conductor's keyed tick) limits the
# merge-state read to those PR numbers. Unset = every row, as before; set and
# empty = no row. Whole words only: "12" never matches 1 or 123.
_hpl_lazy_in_scope() { # _hpl_lazy_in_scope <num>
  [ -n "${HPL_LAZY_ONLY+x}" ] || return 0
  case " ${HPL_LAZY_ONLY//,/ } " in *" $1 "*) return 0 ;; esac
  return 1
}

# One row's lazy fields, appended to <acc> as `,"k":v` pairs.
#   * A failed merge-state read degrades THAT ROW only (review round 1):
#     mergeStateStatus UNVERIFIABLE + mergeable UNKNOWN. Its consumers are
#     decision lanes that can wait a tick (merge-conductor skips the row,
#     rebase-train-ahead holds its mark), so the repo is not blinded.
#   * A failed FILES read fails the WHOLE list (review round 2, B2). Every files
#     consumer (overlap-guard, rebase-train-ahead, run-build's pre-launch check)
#     reads "no files" as "touches nothing" — a null there fails OPEN (a
#     colliding build launches, a mark advances past a PR for good) — and every
#     one of them already handles an unreadable list safely.
#   * A row outside HPL_LAZY_ONLY (BH-8457) is not read: UNKNOWN/UNKNOWN, and
#     it is not degraded.
# rc 0, or the files read's rc. _HPL_DEGRADED counts degraded rows and
# _HPL_DEGRADED_LIMITED those whose read hit a rate limit.
_hpl_lazy_row() { # _hpl_lazy_row <slug> <num> <isDraft> <fields> <scratch> <acc> [head updated_at base]
  local slug=$1 n=$2 d=$3 fields=$4 one=$5 acc=$6
  case ",$fields," in *,mergeStateStatus,*|*,mergeable,*)
    if [ "$d" = true ]; then printf ',"mergeStateStatus":"DRAFT","mergeable":"UNKNOWN"' >> "$acc"
    elif ! _hpl_lazy_in_scope "$n"; then printf ',"mergeStateStatus":"UNKNOWN","mergeable":"UNKNOWN"' >> "$acc"
    elif _hpl_state_get "$slug" "$n" "$one" "${7:-}" "${8:-}" "${9:-}" \
         && jq -j '",\"mergeStateStatus\":\((.mergeable_state // "unknown") | ascii_upcase | tojson),\"mergeable\":\(if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end | tojson)"' "$one" >> "$acc" 2>/dev/null; then :
    else
      printf ',"mergeStateStatus":"UNVERIFIABLE","mergeable":"UNKNOWN"' >> "$acc"
      _HPL_DEGRADED=$((_HPL_DEGRADED + 1))
      case "${GH_REST_REASON:-}:${GH_REST_STATUS:-}" in
        rate-limit:*|*:429) _HPL_DEGRADED_LIMITED=$((_HPL_DEGRADED_LIMITED + 1)) ;;
      esac
      _hpl_log "$slug: #$n merge-state read unverifiable (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — that PR reads UNVERIFIABLE this tick, the rest of the list stands (BH-1585)"
    fi ;;
  esac
  case ",$fields," in *,files,*)
    local frc=0
    _hpl_pr_get "$slug" "$n" "files?per_page=100" "$one" || frc=$?
    if [ "$frc" = 0 ]; then
      jq -j '",\"files\":\(if type == "array" then map({path: .filename, additions, deletions}) else error("not a list") end | tojson)"' "$one" >> "$acc" 2>/dev/null || frc=75
    fi
    if [ "$frc" != 0 ]; then
      _hpl_log "$slug: #$n files read unverifiable (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — the list is unavailable: a files list with a hole in it would read as 'touches nothing' (BH-1585)"
      return "$frc"
    fi ;;
  esac
  return 0
}

# The REST list without the lazy fields (plus number and isDraft, which the
# per-PR reads need), then one read per returned row for what it asked, then
# exactly the requested keys. A failed per-PR read degrades that row only
# (_hpl_lazy_row); a failed PAGE or mergeQueue read still fails the list.
_hpl_lazy_list() { # _hpl_lazy_list <slug> <state> <fields> <limit>
  local slug=$1 state=$2 fields=$3 limit=$4 base f n d b rc=0 tmp one acc qn hd upd bref snapf=""
  # Under the snapshot the per-PR key rides the list too (BH-4659).
  _hpl_snap_on && snapf=",headRefOid,updatedAt"
  # The record (BH-8457) is keyed on the list head too.
  [ "${HPL_PR_RECORD:-}" = 1 ] && snapf="$snapf,headRefOid"
  base=$(printf '%s' "number,isDraft,baseRefName$snapf,$fields" | tr ',' '\n' | grep -vxE 'mergeStateStatus|mergeable|files|isInMergeQueue' | awk 'NF && !s[$0]++' | paste -sd, -)
  tmp=$(mktemp) || return 75; one=$(mktemp) || { rm -f "$tmp"; return 75; }
  acc=$(mktemp) || { rm -f "$tmp" "$one"; return 75; }
  qn=$(mktemp) || { rm -f "$tmp" "$one" "$acc"; return 75; }
  _hpl_rest_list "$slug" "$state" "$base" "$limit" > "$tmp" || rc=$?
  [ "$rc" = 0 ] || { rm -f "$tmp" "$one" "$acc" "$qn"; return "$rc"; }
  : > "$acc"; : > "$qn"
  case ",$fields," in *,isInMergeQueue,*)
    # One read per distinct base branch among the rows — one, in practice.
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      _hpl_queued_nums "$slug" "$b" "$one" || { rc=$?; break; }
      cat "$one" >> "$qn"
    done < <(jq -r '[.[] | (.baseRefName // "main")] | unique[]' "$tmp")
    if [ "$rc" != 0 ]; then
      _hpl_log "$slug ($state): the mergeQueue read for isInMergeQueue failed (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — list unavailable (BH-1585)"
      rm -f "$tmp" "$one" "$acc" "$qn"; return "$rc"
    fi ;;
  esac
  _HPL_DEGRADED=0; _HPL_DEGRADED_LIMITED=0; local nrows=0
  # Empty cells are `-`: a tab is IFS whitespace, so `read` would fold an empty
  # one and shift every column after it.
  while IFS=$'\t' read -r n d hd upd bref; do
    [ -n "$n" ] || continue
    printf '{"number":%s' "$n" >> "$acc"
    case ",$fields," in *,isInMergeQueue,*)
      if grep -qxF "$n" "$qn"; then printf ',"isInMergeQueue":true' >> "$acc"
      else printf ',"isInMergeQueue":false' >> "$acc"; fi ;;
    esac
    nrows=$((nrows + 1))
    _hpl_lazy_row "$slug" "$n" "$d" "$fields" "$one" "$acc" "$hd" "$upd" "$bref" || { rc=$?; break; }
    printf '}\n' >> "$acc"
  done < <(jq -r '.[] | [.number, (.isDraft // false | tostring),
      (.headRefOid, .updatedAt, .baseRefName | (. // "") | tostring | if . == "" then "-" else . end)] | @tsv' "$tmp")
  # THE RUNG LADDER STILL ARMS (BH-847, review round 2). A degraded read that
  # hit a rate limit, or a list whose EVERY non-draft row came back degraded,
  # is the token's bucket talking, not one PR: the list fails with 75 and sets
  # _HPL_LIMITED, so harness_pr_list retries once on the next rung, and a
  # caller never reads an all-UNVERIFIABLE answer as a successful list (which
  # would close a blind streak on a repo it could not see). Rows outside
  # HPL_LAZY_ONLY are not counted: they were never read (BH-8457).
  if [ "$rc" = 0 ] && [ "$_HPL_DEGRADED" -gt 0 ] \
     && { [ "$_HPL_DEGRADED_LIMITED" -gt 0 ] || [ "$_HPL_DEGRADED" -ge "$(jq --arg only "${HPL_LAZY_ONLY-}" --arg set "${HPL_LAZY_ONLY+x}" \
            '[.[] | select((.isDraft // false) | not)
                  | (.number | tostring) as $n
                  | select($set == "" or ((" " + ($only | gsub(","; " ")) + " ") | contains(" " + $n + " ")))] | length' "$tmp")" ]; }; then
    [ "$_HPL_DEGRADED_LIMITED" -gt 0 ] && _HPL_LIMITED=1
    _hpl_log "$slug ($state): $_HPL_DEGRADED of $nrows per-PR reads degraded (${_HPL_DEGRADED_LIMITED} rate-limited) — the list is unavailable this tick (BH-1585)"
    rc=75
  fi
  if [ "$rc" != 0 ]; then
    case "${GH_REST_REASON:-}:${GH_REST_STATUS:-}" in
      rate-limit:*|*:429) _HPL_LIMITED=1 ;;
    esac
    rm -f "$tmp" "$one" "$acc" "$qn"; return "$rc"
  fi
  rm -f "$qn"
  f=$(printf '%s' "$fields" | jq -R 'split(",")')
  jq -s --argjson req "$f" --slurpfile extra "$acc" \
    '.[0] as $rows | ($extra | map({key: (.number|tostring), value: .}) | from_entries) as $x
     | $rows | map(. + ($x[(.number|tostring)] // {}) | . as $r | $req | reduce .[] as $k ({}; . + {($k): $r[$k]}))' \
    "$tmp" || rc=75
  rm -f "$tmp" "$one" "$acc"
  return "$rc"
}

harness_pr_list() { # harness_pr_list <owner/repo> <open|closed|merged> <json-fields> [limit]
  local slug="${1:?owner/repo}" state="${2:?open|closed|merged}" fields="${3:?json fields}" limit="${4:-100}"
  local rc cur next out_file entry_set="${GH_TOKEN+x}" entry_tok="${GH_TOKEN:-}"
  # The list runs with its stdout REDIRECTED rather than captured in $(...):
  # _HPL_LIMITED is set by the gh call sites, and a command substitution would
  # leave the classifier's answer behind in a dead subshell.
  out_file=$(mktemp)
  _HPL_LIMITED=0
  _hpl_run_list "$slug" "$state" "$fields" "$limit" >"$out_file"; rc=$?
  if [ "$rc" = 0 ]; then
    cat "$out_file"; rm -f "$out_file"
    return 0
  fi
  # ONE retry, and only on a limit shape. Everything else — 404, bad credentials,
  # a permission refusal, a timeout — returns exactly what it returned before, so
  # the caller's single gh_repo_list_failed still fires once.
  if [ "$_HPL_LIMITED" = 1 ] && command -v gh_repo_next_rung >/dev/null 2>&1; then
    cur=$(gh_repo_current_rung 2>/dev/null || echo unknown)
    # NOT `next=$(...)`: the call exports the next rung's token, and a command
    # substitution would leave that export in a subshell and retry on the same
    # credential that was just rate-limited.
    if gh_repo_next_rung "$slug" >/dev/null 2>&1; then
      next="${_GHRT_RUNG:-next}"
      _hpl_log "$slug ($state): list rate-limited on the $cur rung — retrying once on the $next rung"
      _HPL_LIMITED=0
      _hpl_run_list "$slug" "$state" "$fields" "$limit" >"$out_file"; rc=$?
      [ "$rc" = 0 ] && _hpl_log "$slug ($state): answered by the $next rung"
    fi
  fi
  # The rung is a detail of THIS call: leaving it exported would move every later
  # gh call in the caller's tick onto a credential it did not choose.
  if [ -n "$entry_set" ]; then export GH_TOKEN="$entry_tok"; else unset GH_TOKEN; fi
  # The CLASSIFIED rc, not a flattened 1 (BH-782): every caller already spells
  # this call so that any non-zero is "list unavailable", and a caller that
  # wants to say WHICH kind of unavailable (overlap-guard does) cannot invent
  # the difference afterwards.
  [ "$rc" = 0 ] || { rm -f "$out_file"; return "$rc"; }
  cat "$out_file"; rm -f "$out_file"
  return 0
}
