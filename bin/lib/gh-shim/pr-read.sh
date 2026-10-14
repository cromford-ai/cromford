#!/bin/bash
# bin/lib/gh-shim/pr-read.sh — `gh pr view` and `gh pr list` as single REST
# reads (#769 chunk 2). Sourced by bin/gh-rest-shim step 6, never executed.
#
# WHY. `gh pr view --json state` is several GraphQL points; `GET /pulls/{n}` is
# one REST call out of the same bucket, and the PR_CREATED gate in
# bin/fly-pool.sh needs that answer while GraphQL is rate limited.
#
# THE SHAPE IS GRAPHQL'S, NOT REST'S. Every caller in this repo was written
# against gh's --json output, so enums are upper-case, `author.login` is
# `app/<name>` for Apps, and a field nobody can map sends the WHOLE call to the
# real binary (gshim_fields_ok) rather than coming back invented.
#
# mergeCommit ON AN OPEN PR IS null, ALWAYS. REST's merge_commit_sha is a
# test-merge sha on an open PR; bin/run-build.sh, bin/merge-queue.sh and
# bin/merge-sweep.sh read `.mergeCommit.oid` as "what landed", and a test-merge
# sha there is a lie that reads like a merge.
#
# SUB-FETCHES ARE ON DEMAND. files/comments/reviews/commits/statusCheckRollup
# each cost their own call, so they are fetched only when --json named them.

GSHIM_PR_FILTERING=0
GSHIM_PR_VIEW_FIELDS='number,url,title,body,state,headRefName,headRefOid,baseRefName,isDraft,labels,author,mergedAt,createdAt,updatedAt,closedAt,mergeable,mergeStateStatus,mergeCommit,mergedBy,additions,deletions,changedFiles,id,assignees,milestone,isCrossRepository,files,comments,reviews,commits,statusCheckRollup'

# The base map: everything a single GET /pulls/{n} can answer.
GSHIM_PR_BASE_MAP='{
  number: .number,
  url: .html_url,
  title: .title,
  body: .body,
  state: (if .merged_at != null then "MERGED" else (.state | gshim_up) end),
  headRefName: .head.ref,
  headRefOid: .head.sha,
  baseRefName: .base.ref,
  isDraft: .draft,
  labels: (.labels | gshim_labels),
  author: (.user | gshim_author),
  mergedAt: .merged_at,
  createdAt: .created_at,
  updatedAt: .updated_at,
  closedAt: .closed_at,
  mergeable: (if .mergeable == true then "MERGEABLE"
              elif .mergeable == false then "CONFLICTING"
              else "UNKNOWN" end),
  mergeStateStatus: (.mergeable_state | gshim_up),
  mergeCommit: (if .merged_at != null then {oid: .merge_commit_sha} else null end),
  mergedBy: (.merged_by | gshim_author),
  additions: .additions,
  deletions: .deletions,
  changedFiles: .changed_files,
  id: .node_id,
  assignees: [ (.assignees // [])[] | gshim_author ],
  milestone: (if .milestone == null then null else {title: .milestone.title, number: .milestone.number} end),
  isCrossRepository: (.head.repo.full_name != .base.repo.full_name)
}'

# gshim_pr_arg — the first positional of `pr view`/`pr list`, or nothing. Flags we
# do not know are skipped rather than read as an argument.
gshim_pr_arg() {
  local a
  for a in ${GSHIM_REST[@]+"${GSHIM_REST[@]}"} ; do
    case "$a" in -*) continue ;; *) printf '%s\n' "$a"; return 0 ;; esac
  done
  return 0
}

# gshim_pr_branch_num — the open-or-closed PR for the checked-out branch, the way
# `gh pr view` with no argument resolves one. No branch or no hit is an ERROR:
# passing the call through here would spend the GraphQL points the shim exists
# to save, on the one call it was built for.
gshim_pr_branch_num() {
  local br owner hits n
  br=$(git symbolic-ref --short -q HEAD 2>/dev/null) || br=""
  if [ -z "$br" ]; then
    echo "gh-rest-shim: not on a branch, so there is no pull request to view" >&2
    exit 1
  fi
  owner="${GSHIM_SLUG%%/*}"
  # The checked-out branch name is caller data too — see gshim_pr_list_rest.
  hits=$(gshim_api "repos/$GSHIM_SLUG/pulls?head=$(gshim_uri "$owner"):$(gshim_uri "$br")&state=all&per_page=1") || exit $?
  n=$(printf '%s' "$hits" | jq -r 'if type == "array" and length > 0 then .[0].number else "" end' 2>/dev/null)
  if [ -z "$n" ] || [ "$n" = "null" ]; then
    echo "no pull requests found for branch \"$br\"" >&2
    exit 1
  fi
  printf '%s\n' "$n"
}

gshim_cmd_pr_view() {
  local arg num body mapped sub
  arg=$(gshim_pr_arg)
  # gh's human renderer is not reproduced: without --json this call is the real
  # binary's, untranslated.
  [ -n "$GSHIM_FIELDS" ] || gshim_passthru untranslated
  gshim_slug "$arg"
  gshim_fields_ok "$GSHIM_PR_VIEW_FIELDS"
  num="$GSHIM_NUM"
  [ -n "$num" ] || num=$(gshim_pr_branch_num) || exit $?

  body=$(gshim_api "repos/$GSHIM_SLUG/pulls/$num") || exit $?
  mapped=$(printf '%s' "$body" | jq -c "$GSHIM_JQ_DEFS$GSHIM_PR_BASE_MAP") || exit 1

  # Every sub-fetch lands in a temp file (raw page, then mapped) and is attached
  # from there: a 150 KB comment thread as `--argjson` is E2BIG and prints
  # EMPTY with rc 0 (gshim_file). Every step is guarded, so a jq that fails is
  # an exit 1, never a silent null.
  local raw
  if gshim_wants files; then
    raw=$(gshim_file) || exit 1; sub=$(gshim_file) || exit 1
    gshim_paginate "repos/$GSHIM_SLUG/pulls/$num/files" 300 >"$raw" || exit $?
    jq -c '[ .[] | {path: .filename, additions: .additions, deletions: .deletions} ]' "$raw" >"$sub" || exit 1
    mapped=$(gshim_pr_attach "$mapped" files "$sub") || exit 1
  fi
  if gshim_wants comments; then
    sub=$(gshim_file) || exit 1
    gshim_fetch_comments "$GSHIM_SLUG" "$num" >"$sub" || exit $?
    mapped=$(gshim_pr_attach "$mapped" comments "$sub") || exit 1
  fi
  if gshim_wants reviews; then
    raw=$(gshim_file) || exit 1; sub=$(gshim_file) || exit 1
    gshim_paginate "repos/$GSHIM_SLUG/pulls/$num/reviews" 100 >"$raw" || exit $?
    jq -c "$GSHIM_JQ_DEFS"'
      [ .[] | {id: .node_id,
               author: (.user | gshim_author | if . == null then null else {login: .login} end),
               body: .body, state: .state,
               submittedAt: .submitted_at, commit: {oid: .commit_id}} ]' "$raw" >"$sub" || exit 1
    mapped=$(gshim_pr_attach "$mapped" reviews "$sub") || exit 1
  fi
  if gshim_wants commits; then
    raw=$(gshim_file) || exit 1; sub=$(gshim_file) || exit 1
    gshim_paginate "repos/$GSHIM_SLUG/pulls/$num/commits" 250 >"$raw" || exit $?
    jq -c '
      [ .[] | {oid: .sha,
               messageHeadline: (.commit.message | split("\n")[0]),
               messageBody: (.commit.message | split("\n") | .[1:] | join("\n")),
               committedDate: .commit.committer.date,
               authors: [{login: (.author.login // null), name: .commit.author.name, email: .commit.author.email}]} ]' \
      "$raw" >"$sub" || exit 1
    mapped=$(gshim_pr_attach "$mapped" commits "$sub") || exit 1
  fi
  if gshim_wants statusCheckRollup; then
    sub=$(gshim_file) || exit 1
    gshim_pr_rollup "$(printf '%s' "$body" | jq -r '.head.sha')" >"$sub" || exit $?
    mapped=$(gshim_pr_attach "$mapped" statusCheckRollup "$sub") || exit 1
  fi
  gshim_emit "$mapped"
}

# gshim_pr_attach <object> <key> <file> — the object with one more key, whose
# value is the ONE JSON document in <file>. The object arrives on stdin through
# a builtin printf and the value through --slurpfile, so neither is an argv
# entry: `--argjson v "$thread"` was the E2BIG that made `pr view --json
# comments` print EMPTY with rc 0 on any long thread. Written as a helper
# because five sub-fetches would otherwise repeat the same jq.
gshim_pr_attach() {
  printf '%s' "$1" | jq -c --arg k "$2" --slurpfile v "$3" '.[$k] = $v[0]'
}

# gshim_pr_rollup <sha> — check runs AND commit statuses, in gh's GraphQL shape.
# bin/review-autopilot.sh reads `.name // .context` and `.conclusion // .state`,
# so both kinds ride in one array and both are UPPER-CASE the way GraphQL
# answers them.
gshim_pr_rollup() {
  local sha="$1" runs statuses
  runs=$(gshim_file) || exit 1
  statuses=$(gshim_file) || exit 1
  # BOTH SIDES PAGE. A single per_page=100 read dropped check run 101 with no
  # error and rc 0, and bin/merge-conductor-lib.sh:2031 reads this array to find
  # the Mergify queue check: a check past row 100 read as "no queue check" on a
  # merge-gate path. Same gshim_paginate every other sub-fetch uses, so a head with
  # more runs than the ceiling can page EXITS instead of answering short.
  gshim_paginate "repos/$GSHIM_SLUG/commits/$sha/check-runs" 300 .check_runs >"$runs" || exit $?
  gshim_paginate "repos/$GSHIM_SLUG/commits/$sha/status" 300 .statuses >"$statuses" || exit $?
  jq -c -n --slurpfile r "$runs" --slurpfile s "$statuses" "$GSHIM_JQ_DEFS"'
    [ ($r[0] // [])[] | {
        __typename: "CheckRun", name: .name, status: (.status | gshim_up),
        conclusion: (.conclusion | gshim_up), startedAt: .started_at,
        completedAt: .completed_at, detailsUrl: .details_url, workflowName: null } ]
    + [ ($s[0] // [])[] | {
        __typename: "StatusContext", context: .context, state: (.state | gshim_up),
        targetUrl: .target_url, startedAt: .created_at } ]'
}

GSHIM_PR_LIST_FIELDS='number,url,title,body,state,headRefName,headRefOid,baseRefName,isDraft,labels,author,mergedAt,createdAt,updatedAt,closedAt,id'

GSHIM_PR_LIST_MAP='{
  number: .number,
  url: .html_url,
  title: .title,
  body: .body,
  state: (if .merged_at != null then "MERGED" else (.state | gshim_up) end),
  headRefName: .head.ref,
  headRefOid: .head.sha,
  baseRefName: .base.ref,
  isDraft: .draft,
  labels: (.labels | gshim_labels),
  author: (.user | gshim_author),
  mergedAt: .merged_at,
  createdAt: .created_at,
  updatedAt: .updated_at,
  closedAt: .closed_at,
  id: .node_id
}'

gshim_cmd_pr_list() {
  local state="open" head="" base="" author="" search="" labels=() i=0 a
  while [ "$i" -lt "${#GSHIM_REST[@]}" ]; do
    a="${GSHIM_REST[$i]}"
    case "$a" in
      --state)  state="${GSHIM_REST[$((i+1))]:-}"; i=$((i+2)) ;;
      --state=*) state="${a#--state=}"; i=$((i+1)) ;;
      --head)   head="${GSHIM_REST[$((i+1))]:-}"; i=$((i+2)) ;;
      --head=*) head="${a#--head=}"; i=$((i+1)) ;;
      --base)   base="${GSHIM_REST[$((i+1))]:-}"; i=$((i+2)) ;;
      --base=*) base="${a#--base=}"; i=$((i+1)) ;;
      --author) author="${GSHIM_REST[$((i+1))]:-}"; i=$((i+2)) ;;
      --author=*) author="${a#--author=}"; i=$((i+1)) ;;
      --search|-S) search="${GSHIM_REST[$((i+1))]:-}"; i=$((i+2)) ;;
      --search=*) search="${a#--search=}"; i=$((i+1)) ;;
      --label|-l) labels+=("${GSHIM_REST[$((i+1))]:-}"); i=$((i+2)) ;;
      --label=*) labels+=("${a#--label=}"); i=$((i+1)) ;;
      -*)       gshim_passthru "flag:$a" ;;
      *)        i=$((i+1)) ;;
    esac
  done
  gshim_slug ""
  gshim_fields_ok "$GSHIM_PR_LIST_FIELDS"

  # --state is validated HERE, before anything runs inside a command
  # substitution. gshim_passthru hands the original argv to the real gh and
  # takes over the process: fired from inside `rows=$(gshim_pr_list_rest …)` it
  # would have gh's answer captured into $rows and then fed to jq instead of
  # reaching the caller's stdout.
  case "$state" in ''|open|closed|all|merged) : ;; *) gshim_passthru "flag:--state" ;; esac

  # A filter applied AFTER the fetch has to over-fetch, or `--limit 30` with a
  # label filter answers 30 rows with the 4 that matched the first page.
  GSHIM_PR_FILTERING=0
  { [ "$state" = "merged" ] || [ -n "$author" ] || [ "${#labels[@]}" -gt 0 ]; } && GSHIM_PR_FILTERING=1

  local rows raw fetch nraw nrows lim
  lim="$GSHIM_LIMIT"
  case "$lim" in ''|*[!0-9]*) lim=30 ;; esac
  [ "$lim" -ge 1 ] || lim=30
  if [ -n "$search" ]; then
    rows=$(gshim_pr_list_search "$state" "$search" "$author" ${labels[@]+"${labels[@]}"}) || exit $?
    rows=$(gshim_pr_filter "$rows" "$state" "$author" ${labels[@]+"${labels[@]}"}) || exit 1
  else
    # A FILTERED REST LIST THAT COMES BACK SHORT IS NOT AN ANSWER. `merged`,
    # `--label` and `--author` are all applied AFTER the fetch, so a window that
    # came back full (`nraw == fetch`) with fewer than --limit rows surviving
    # proves only that the window was too narrow: `pr list --state merged
    # --limit 100` used to answer 80 rows rc 0 where real gh (GraphQL
    # `states: MERGED`) answers 100, and bin/board-invariants.sh:81,
    # bin/pr-owner-sweep.sh:261 and bin/lib/revdep-lib.sh:163 read that short
    # list as the whole set of merged PRs. The window doubles and the read runs
    # again, up to the drop ceiling; only a ceiling that still cannot fill
    # --limit exits — those same callers swallow a non-zero rc into `[]`, so
    # erring early would cost them more rows than answering short did.
    fetch="$GSHIM_LIMIT"
    gshim_pr_needs_overfetch && fetch=$(gshim_overfetch "$GSHIM_LIMIT")
    while :; do
      raw=$(gshim_pr_list_rest "$state" "$head" "$base" "$fetch") || exit $?
      rows=$(gshim_pr_filter "$raw" "$state" "$author" ${labels[@]+"${labels[@]}"}) || exit 1
      gshim_pr_needs_overfetch || break
      nraw=$(printf '%s' "$raw" | jq 'length') || exit 1
      nrows=$(printf '%s' "$rows" | jq 'length') || exit 1
      { [ "$nrows" -ge "$lim" ] || [ "$nraw" -lt "$fetch" ]; } && break
      fetch=$(gshim_widen "$fetch") || {
        echo "gh-rest-shim: only $nrows of $lim rows survive a full window — narrow the query" >&2
        exit 1
      }
    done
  fi
  rows=$(printf '%s' "$rows" | jq -c ".[:$GSHIM_LIMIT]") || exit 1

  if [ -n "$GSHIM_FIELDS" ] || [ -n "$GSHIM_JQ" ]; then
    gshim_emit "$rows"
  else
    # gh's non-TTY TSV. The triage duplicate-work check reads this as prose.
    printf '%s' "$rows" | jq -r '.[] | [ (.number|tostring), .title, .headRefName, .state, .createdAt ] | @tsv'
  fi
}

# gshim_pr_list_rest <state> <head> <base> [fetch] — the mapped pull rows.
# `merged` is not a REST state: it is `closed` plus a merged_at filter, applied
# by gshim_pr_filter. <fetch> is the window the caller wants (limit*2 on a
# filtered query, widened by its retry loop), because slicing to --limit BEFORE
# the filter would answer 30 rows with 4. A filtered query pages under the DROP
# ceiling (gshim_paginate_wide); an unfiltered one keeps the plain ceiling,
# since nothing is dropped and --limit is already the ask.
gshim_pr_list_rest() {
  local state="$1" head="$2" base="$3" fetch="${4:-$GSHIM_LIMIT}" q raw owner
  # gshim_cmd_pr_list already rejected anything else (and did it OUTSIDE a
  # command substitution, which is why the passthru is not repeated here).
  case "$state" in merged) q="state=closed" ;; *) q="state=${state:-open}" ;; esac
  owner="${GSHIM_SLUG%%/*}"
  # A REFNAME IS NOT URL-SAFE. `&` and `#` are both legal in a git branch name,
  # so `--base 'x&state=all'` used to open a second query parameter (the shim
  # then asked a different question than gh and answered it confidently) and
  # `--head 'feature#1'` truncated the URL at a fragment. Same defect the
  # --search terms already fixed; the `:` between owner and ref stays literal
  # because that separator is the API's, not the caller's.
  [ -n "$head" ] && q="$q&head=$(gshim_uri "$owner"):$(gshim_uri "$head")"
  [ -n "$base" ] && q="$q&base=$(gshim_uri "$base")"
  if gshim_pr_needs_overfetch; then
    raw=$(gshim_paginate_wide "repos/$GSHIM_SLUG/pulls?$q" "$fetch") || exit $?
  else
    raw=$(gshim_paginate "repos/$GSHIM_SLUG/pulls?$q" "$fetch") || exit $?
  fi
  printf '%s' "$raw" | jq -c "$GSHIM_JQ_DEFS"'[ .[] | '"$GSHIM_PR_LIST_MAP"' ]'
}

gshim_pr_needs_overfetch() {
  [ "$GSHIM_PR_FILTERING" = "1" ]
}

# gshim_pr_list_search <state> <terms> <author> [label…] — GitHub's search index,
# the one answer REST list cannot give. Hits carry the issue shape, which covers
# every search-safe field; a request for a pull-only field (headRefName and
# kin) costs one GET /pulls/{n} per hit, bounded by --limit. --author and
# --label are qualifiers on q (gshim_author_q, gshim_label_q), not post-filters: a
# search answer has no over-fetch behind it, so `--limit N` counts matches.
gshim_pr_list_search() {
  local state="$1" terms="$2" author="$3"; shift 3
  local q hits nums n rowf mf files=()
  q="repo:$GSHIM_SLUG+is:pr"
  case "$state" in open) q="$q+is:open" ;; closed) q="$q+is:closed" ;; merged) q="$q+is:merged" ;; esac
  q="$q$(gshim_author_q "$author")$(gshim_label_q "$@")"
  q="$q+$(gshim_uri "$terms")"
  hits=$(gshim_file) || exit 1
  gshim_paginate "search/issues?q=$q" "$GSHIM_LIMIT" .items >"$hits" || exit $?
  # ONLY the three fields a search hit cannot carry. `isDraft` is the hit's
  # `.draft`, `mergedAt` its `.pull_request.merged_at` and `id` its `.node_id` —
  # all three are in the map below, so naming them in the trigger bought one
  # GET /pulls/{n} per hit for an answer already in hand. The callers that DO
  # pay, and should (bin/review-rescue.sh:175, bin/blocked-resolver.sh:1243-1246),
  # ask for headRefName; a caller asking only for hit-supplied fields now costs
  # the one search call and nothing else.
  # ONE MAPPED ROW PER TEMP FILE, joined by `jq -s`: an `--argjson` accumulator
  # over 30 hits with 6 KB bodies is E2BIG, and its "" with rc 0 read as "no
  # merged PR" to bin/blocked-resolver.sh — a landed ticket rebuilt.
  #
  # THE TSV PATH PAYS TOO. With no --json at all, field 3 of gh's own non-TTY
  # columns IS headRefName, and a search hit cannot carry it: the column printed
  # empty for every row. That TSV is the duplicate-work check every project
  # prompt hands a build lane (`gh pr list --state all --search "<KEY>"`,
  # prompts/cromford.md:51 and eight more), read as prose, so the branch
  # has to be there. Same per-hit cost as the --json path, same --limit cap.
  if grep -qE '(headRefName|headRefOid|baseRefName),' <<<"$GSHIM_FIELDS," ||
     { [ -z "$GSHIM_FIELDS" ] && [ -z "$GSHIM_JQ" ]; }; then
    nums=$(jq -r ".[:$GSHIM_LIMIT][].number" "$hits") || exit 1
    for n in $nums; do
      rowf=$(gshim_file) || exit 1
      mf=$(gshim_file) || exit 1
      gshim_api "repos/$GSHIM_SLUG/pulls/$n" >"$rowf" || exit $?
      jq -c "$GSHIM_JQ_DEFS$GSHIM_PR_LIST_MAP" "$rowf" >"$mf" || exit 1
      files+=("$mf")
    done
    if [ "${#files[@]}" -eq 0 ]; then printf '[]'; return 0; fi
    jq -c -s . "${files[@]}" || exit 1
    return 0
  fi
  jq -c "$GSHIM_JQ_DEFS"'
    [ .[] | {number: .number, url: .html_url, title: .title, body: .body,
             state: (if .pull_request.merged_at != null then "MERGED" else (.state | gshim_up) end),
             headRefName: null, headRefOid: null, baseRefName: null, isDraft: .draft,
             labels: (.labels | gshim_labels), author: (.user | gshim_author),
             mergedAt: .pull_request.merged_at, createdAt: .created_at,
             updatedAt: .updated_at, closedAt: .closed_at, id: .node_id} ]' "$hits" || exit 1
}

# gshim_pr_filter <rows> <state> <author> [label…] — the three filters REST cannot
# express: merged (closed AND merged_at), every label present (gh's --label is
# AND), and the author on its bare login so `app/x`, `x[bot]` and `x` all match
# the same account (bin/lib/gh-pr-list.sh does the same).
gshim_pr_filter() {
  local rows="$1" state="$2" author="$3"; shift 3
  local want=() a bare
  for a in "$@"; do
    IFS=, read -r -a bare <<<"$a"
    want+=("${bare[@]}")
  done
  # A DROPPED ROW AND A FAILED jq LOOK IDENTICAL FROM HERE. Each step below
  # narrows the set, so a jq that dies mid-filter leaves `rows` empty and this
  # function still returned 0 through its final printf — an empty list read by
  # bin/board-invariants.sh and bin/pr-owner-sweep.sh as "no PRs match", which
  # is exactly the confident wrong answer the widening loop above exists to
  # prevent. Every step returns 1 instead, and every call site already carries
  # `|| exit 1`.
  if [ "$state" = "merged" ]; then
    rows=$(printf '%s' "$rows" | jq -c '[ .[] | select(.mergedAt != null) ]') || return 1
  fi
  if [ "${#want[@]}" -gt 0 ]; then
    rows=$(printf '%s' "$rows" | jq -c --argjson w "$(printf '%s\n' "${want[@]}" | jq -R . | jq -sc .)" '
      [ .[] | select(([ (.labels // [])[].name ]) as $have | all($w[]; . as $l | $have | index($l) != null)) ]') || return 1
  fi
  if [ -n "$author" ]; then
    bare="${author#app/}"; bare="${bare%\[bot\]}"
    rows=$(printf '%s' "$rows" | jq -c --arg a "$bare" '
      [ .[] | select(((.author.login // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "")) == $a) ]') || return 1
  fi
  printf '%s' "$rows"
}
