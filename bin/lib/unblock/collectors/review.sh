#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/collectors/review.sh — the PR unblock agent's review-family
# collector (UNB-2). It makes no model call and no GitHub write. Its one worker
# write is the change gate's commit of change marks (BH-10197, steps shadow and
# record), and the only file it writes is its lines in logs/unblock.log.
#
#   review.sh --project <p> --repo <owner/name>          (the CLI)
#   . review.sh; unblock_collect_review --project <p> --repo <owner/name>
#
# stdout: one JSON record per line, then one meta line, always last:
#   {"kind":"collector-meta","family":"review","repo":..,"prs_seen":N,
#    "truncated":bool,"unreadable":[..]}
# rc 0 = records printed (an unreadable input is named in the meta, not an rc);
# rc 2 = bad args, no root ($HARNESS, then $H), or a lib that does not load.
#
# Every record carries family "review", project, repo, pr, subject_kind "pr",
# subject "<repo>#<pr>" (the UNB-0 record fields the rules engine and act.sh
# read; act.sh refuses a decision with no project), head, stall_at and unknown
# (the names of the inputs that could not be read; each such field is null).
# The kinds, and the rule file that reads each (catalog/unblock-rules.d/):
#   lead-block-unrouted   U5  the standing verdict on the head is a lead BLOCK,
#                             and no CR review on the head and no findings
#                             comment on the head says it was routed.
#                             A whole report with 0 `- [BLOCK` lines (the same
#                             `^- \[BLOCK` test as bin/lead-review-land.sh) and
#                             no cap line gives NO record: land withholds it,
#                             and the queue family's U13-EMPTY is its one owner
#                             (BH-8554). The log line counts it as empty_owned.
#   lead-block-cap-only   U6  the same, and the report's only BLOCK reason is
#                             the outcome cap line (bin/lead-review.sh writes
#                             `- outcome cap: ...` from loc_cap): 0 `- [BLOCK` lines.
#   lead-request-stale    U7  a running lead review request whose heartbeat is
#                             older than UNBLOCK_LEAD_STALE_S.
#   stale-change-request  U11 a CHANGES_REQUESTED review on an old head that
#                             carries the review-verdict:block or tackler marker
#                             (or whose author is in UNBLOCK_CR_DISMISS_LOGINS),
#                             while the head stands MERGE or MERGE-WITH-NOTES.
#
# UNKNOWN IS NOT FALSE. A read that fails (gh_rest rc != 0, a worker answer that
# is not 2xx) sets its field to null and names it in `unknown`. A failed list
# read (pulls, search, lead-reviews) or a failed verdict read of one PR names
# the input in the meta `unreadable` list, and no record is built from it.
# A comment or review that carries `<!-- tackler:` is the agent's own output:
# it only ever says "already routed"; no finding is read from it.
#
# Knobs (environment; the lane registry fills them once UNB-0 ships it):
#   UNBLOCK_REVIEW_PR_MAX (100)   open PRs read per tick
#   UNBLOCK_REVIEW_PAR (6)        parallel per-PR reads
#   UNBLOCK_LEAD_STALE_S (900)    heartbeat age that makes a request stale
#   UNBLOCK_CR_DISMISS_LOGINS ()  comma list of logins whose CRs qualify for U11
#   UNBLOCK_REVIEW_BLOCK_LINES_MAX (60) `- [BLOCK` lines kept per record (block_lines)
#   UNBLOCK_NOW                   epoch seconds for "now" (test seam; default the clock)
#
# THE STEP (BH-10158): lane.unblock.gh_source (bin/lib/unblock/prr.sh). R1 and
# R2 go through ubp_read (keys <repo>#open@review and <repo>#cr): in step
# record the PR record answers them. The reviews and comments reads of R4 and
# R5 go through ubp_cached: in step record a PR with the same head and no `pr`
# wake since its last read is served from state/unblock-prr/, 0 GitHub calls.
# Steps off and shadow read GitHub as before.
#
# THE CHANGE GATE (BH-10197, bin/lib/unblock/change-gate.sh, site review). One
# check per tick runs beside R3. In step record a PR that is not due takes the
# compact CR reviews (rv) and the findings-comment test (fc) from its
# unblock_change_marks row: no reviews or comments read. A field the row lacks
# is read alone. A failed check in step record names change-gate#<pr> in the
# meta unreadable for each open PR, and no R4/R5 read or record is made for
# it (unknown, never unchanged). One commit at the end stores the marks of the
# PRs whose gated reads all succeeded. When the check answered, the log line
# ends with gate=<checked>/<skipped>.
#
# NO ROOT DEFAULT (D43): the root is $HARNESS, then $H; with neither it is rc 2.

_UCR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_UCR_TMP=""

# The record reads (BH-10158). No lib: today's GitHub reads.
# shellcheck source=bin/lib/unblock/prr.sh
. "$_UCR_DIR/../prr.sh" 2>/dev/null || true
declare -F ubp_read >/dev/null || ubp_read() { local o="$2" g="$4"; shift 5; "$g" "$o" "$@"; }
declare -F ubp_cached >/dev/null || ubp_cached() { shift 5; "$@"; }
# The change gate (BH-10197). No lib: every PR is read (step off).
# shellcheck source=bin/lib/unblock/change-gate.sh
. "$_UCR_DIR/../change-gate.sh" 2>/dev/null || true
if ! declare -F ubg_check >/dev/null; then
  ubg_check() { return 3; }; ubg_skip() { return 1; }; ubg_stored() { return 1; }; ubg_fresh() { return 1; }
  ubg_put() { :; }; ubg_commit() { :; }; ubg_log() { :; }
fi

# The compact CHANGES_REQUESTED reviews (rv, BH-10197): every field U5, U6 and
# U11 read, with the body cut to the one marker it carries. The records use it
# for a fresh read and for a stored one alike, so they cannot differ.
_UCR_RVC='if type == "array" then [.[] | select(.state == "CHANGES_REQUESTED")
    | {id, state, commit_id, submitted_at, user: {login: (.user.login // null)},
       body: ((.body // "") as $t | if ($t | contains("<!-- review-verdict:block ")) then "<!-- review-verdict:block "
              elif ($t | contains("<!-- tackler:")) then "<!-- tackler:" else "" end)}][:100] else null end'
# fc: a findings comment on the head (the comments test of U5), from the comments.
_UCR_FC='if type == "array" then ($h[0:12]) as $h12 | any(.[]; (.body // "") as $t
    | ($t | contains("<!-- review-verdict:block " + $h))
      or (($t | contains("<!-- tackler:")) and ($t | contains($h12)))
      or (($t | test("(^|\\n)\\s*- \\[BLOCK")) and ($t | contains($h12)))) else null end'

_ucr_log() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s review: %s\n' "$(date -u +%FT%TZ)" "$*" >> "$h/logs/unblock.log" 2>/dev/null || true
}

_ucr_load() {
  declare -F gh_rest >/dev/null || . "$_UCR_DIR/../../gh-rest.sh" 2>/dev/null || return 1
  declare -F _jobs_req >/dev/null || . "$_UCR_DIR/../../../jobs-client.sh" 2>/dev/null || return 1
  declare -F br_rkey >/dev/null || . "$_UCR_DIR/../../br/record.sh" 2>/dev/null || return 1
  declare -F gh_rest >/dev/null && declare -F _jobs_req >/dev/null && declare -F br_rkey >/dev/null
}

# _ucr_gh <tmp> <out-file> <path>: one GitHub read. rc 0 = a 2xx JSON body in <out-file>.
_ucr_gh() {
  local rc=0
  echo r >> "$1/calls.rest"
  gh_rest GET "$3" > "$2" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] && jq -e . "$2" >/dev/null 2>&1
}

# The GitHub side of R1 and R2 (prr_read's github-fn): <out-file> <slug>.
_ucr_open_gh() { _ucr_gh "$_UCR_TMP" "$1" "repos/$2/pulls?state=open&per_page=100"; }
_ucr_cr_gh() { _ucr_gh "$_UCR_TMP" "$1" "search/issues?q=repo:$2+is:pr+is:open+review:changes_requested&per_page=100"; }

# _ucr_worker <tmp> <out-file> <path>: one jobs worker read. rc 0 = a 2xx JSON body.
_ucr_worker() {
  local rc=0
  echo w >> "$1/calls.worker"
  JOBS_ALERT=0 _jobs_req GET "$3" > "$2" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] && jq -e . "$2" >/dev/null 2>&1
}

# _ucr_par <max>: block until fewer than <max> background reads run.
_ucr_par() {
  while [ "$(jobs -rp | wc -l)" -ge "$1" ]; do wait -n 2>/dev/null || true; done
}

# _ucr_fix_round <h> <project> <slug> <pr> -> true | false | null
#   A blocked-resolver fix round holds locks/blocked-resolver-<project>-<rkey>.lock
#   (rkey = br_rkey "<slug>#<pr>") for its whole run. The probe opens the file
#   READ ONLY with flock -n and lets go at once: it never creates the file and
#   never waits. No file = no round has run for that key.
_ucr_fix_round() {
  local lk
  lk="$1/locks/blocked-resolver-$2-$(br_rkey "$3#$4").lock"
  [ -e "$lk" ] || { echo false; return; }
  [ -r "$lk" ] || { echo null; return; }
  if ( exec 9<"$lk" && flock -n 9 ) 2>/dev/null; then echo false; else echo true; fi
}

unblock_collect_review() {
  local h="${HARNESS:-${H:-}}" project="" slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) project="${2:-}"; shift 2 ;;
      --repo) slug="${2:-}"; shift 2 ;;
      *) echo "review.sh: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$h" ] || { echo "review.sh: no root (\$HARNESS or \$H)" >&2; return 2; }
  [[ $project =~ ^[A-Za-z0-9._-]+$ ]] && [[ $slug =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || { echo "usage: review.sh --project <p> --repo <owner/name>" >&2; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "review.sh: jq is required" >&2; return 2; }
  _ucr_load || { echo "review.sh: bin/lib/gh-rest.sh, bin/jobs-client.sh or bin/lib/br/record.sh did not load" >&2; return 2; }

  local prmax="${UNBLOCK_REVIEW_PR_MAX:-100}" par="${UNBLOCK_REVIEW_PAR:-6}" stale="${UNBLOCK_LEAD_STALE_S:-900}"
  local now="${UNBLOCK_NOW:-}" logins="${UNBLOCK_CR_DISMISS_LOGINS:-}"
  local blmax="${UNBLOCK_REVIEW_BLOCK_LINES_MAX:-60}"
  { [[ $blmax =~ ^[0-9]+$ ]] && [ "$blmax" -ge 1 ] && [ "$blmax" -le 1000 ]; } || blmax=60
  [[ $prmax =~ ^[1-9][0-9]*$ ]] || prmax=100
  [[ $par =~ ^[1-9][0-9]*$ ]] || par=6
  [[ $stale =~ ^[1-9][0-9]*$ ]] || stale=900
  [[ $now =~ ^[0-9]+$ ]] || now=$(date -u +%s)

  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/unblock-review.XXXXXX") || { echo "review.sh: mktemp failed" >&2; return 2; }
  : > "$tmp/calls.rest"; : > "$tmp/calls.worker"; : > "$tmp/out.jsonl"
  _UCR_TMP=$tmp
  declare -F ubp_prepare >/dev/null && ubp_prepare
  local -a unreadable=()
  local truncated=false

  # R1 the open PRs, R2 the PRs with a CHANGES_REQUESTED review, R6 the running
  # lead review requests. Three reads, in parallel.
  ubp_read "$slug#open@review" "$tmp/pulls.json" ub_open_record _ucr_open_gh ub_open_norm "$slug" \
    && jq -e . "$tmp/pulls.json" >/dev/null 2>&1 && echo 0 > "$tmp/pulls.ok" &
  ubp_read "$slug#cr" "$tmp/search.json" ub_cr_record _ucr_cr_gh ub_cr_norm "$slug" \
    && jq -e . "$tmp/search.json" >/dev/null 2>&1 && echo 0 > "$tmp/search.ok" &
  _ucr_worker "$tmp" "$tmp/running.json" "/api/lead-reviews?status=running&repo=$slug" && echo 0 > "$tmp/running.ok" &
  wait

  local prs="[]" crset="[]"
  if [ -f "$tmp/pulls.ok" ] && prs=$(jq -c --argjson m "$prmax" 'if type == "array" then [.[] | {pr: .number, head: .head.sha}] | .[:$m] else error("x") end' "$tmp/pulls.json" 2>/dev/null); then
    [ "$(jq 'length' "$tmp/pulls.json")" -ge 100 ] && truncated=true
    [ "$(jq 'length' <<<"$prs")" -lt "$(jq 'length' "$tmp/pulls.json")" ] && truncated=true
  else
    prs="[]"; unreadable+=(pulls)
  fi
  if [ -f "$tmp/search.ok" ] && crset=$(jq -c 'if (.items | type) == "array" then [.items[].number] else error("x") end' "$tmp/search.json" 2>/dev/null); then
    [ "$(jq -r '.incomplete_results // false' "$tmp/search.json")" = true ] && truncated=true
    [ "$(jq 'length' <<<"$crset")" -ge 100 ] && truncated=true
  else
    crset=""; unreadable+=(search)
  fi

  # The change gate: one check, beside R3 (independent reads).
  local g="$tmp/gate" gunk=0 v nc fresh fc
  mkdir -p "$g"
  if [ -f "$tmp/pulls.ok" ]; then
    jq -c --argjson m "$prmax" '.[:$m][] | ((.head.sha // "") | ascii_downcase) as $h | select($h != "")
        | ([(.head.ref // "") | capture("^ticket/bh-(?<n>[1-9][0-9]{0,8})(-r[0-9]+)?$"; "i").n] | first) as $i
        | {pr: .number, head: $h} + (if $i == null then {} else {issue: ($i | tonumber)} end)' "$tmp/pulls.json" > "$g/items.jsonl" 2>/dev/null
  else
    : > "$g/items.jsonl"
  fi
  ubg_check "$slug" review "$g/items.jsonl" "$g" &

  # R3 the verdict of each open PR on its head (standing + history rows).
  local pr head
  while IFS=$'\t' read -r pr head; do
    [ -n "$pr" ] || continue
    _ucr_par "$par"
    { _ucr_worker "$tmp" "$tmp/vd-$pr.json" "/api/verdicts?repo=$slug&pr=$pr&head=$head" && echo 0 > "$tmp/vd-$pr.ok"; } &
  done < <(jq -r '.[] | [.pr, .head] | @tsv' <<<"$prs")
  wait
  [ "$(cat "$g/status" 2>/dev/null)" = unknown ] && gunk=1

  # R4 for a lead BLOCK: the report, the reviews and the comments. R5 for a
  # MERGE* PR in the CR set: the reviews.
  local sv ss job
  while IFS=$'\t' read -r pr head; do
    [ -n "$pr" ] || continue
    if [ ! -f "$tmp/vd-$pr.ok" ]; then unreadable+=("verdicts#$pr"); continue; fi
    # Rule 1 (BH-10197): a failed check in step record is unknown: no read.
    if [ "$gunk" = 1 ]; then unreadable+=("change-gate#$pr"); continue; fi
    sv=$(jq -r '.standing.verdict // ""' "$tmp/vd-$pr.json"); ss=$(jq -r '.standing.source // ""' "$tmp/vd-$pr.json")
    nc=$(ubg_fresh "$g" "$pr") || nc=""
    if [ "$sv" = BLOCK ] && [ "$ss" = lead ]; then
      job=$(jq -r '.standing.note // ""' "$tmp/vd-$pr.json" | grep -oE '(^| )lead-job:[^ ]+' | head -1 | sed 's/.*lead-job://')
      echo "$job" > "$tmp/job-$pr"
      ubg_skip "$g" "$pr" rv fc
      v=$(ubg_stored "$g" "$pr" rv) && { printf '%s\n' "$v" > "$tmp/rv-$pr.json"; echo 0 > "$tmp/rv-$pr.ok"; }
      v=$(ubg_stored "$g" "$pr" fc) && printf '%s\n' "$v" > "$tmp/fc-$pr"
      _ucr_par "$par"
      { [ -z "$job" ] || { _ucr_worker "$tmp" "$tmp/art-$pr.json" "/api/jobs/$job/artifacts" && echo 0 > "$tmp/art-$pr.ok"; }
        [ -f "$tmp/rv-$pr.ok" ] || { UBP_FRESH=$nc ubp_cached "$slug" "$pr" "$head" reviews "$tmp/rv-$pr.json" \
          _ucr_gh "$tmp" "$tmp/rv-$pr.json" "repos/$slug/pulls/$pr/reviews?per_page=100" && echo 0 > "$tmp/rv-$pr.ok" && : > "$tmp/rv-$pr.fresh"; }
        [ -f "$tmp/fc-$pr" ] || { UBP_FRESH=$nc ubp_cached "$slug" "$pr" "$head" comments "$tmp/cm-$pr.json" \
          _ucr_gh "$tmp" "$tmp/cm-$pr.json" "repos/$slug/issues/$pr/comments?per_page=100" && echo 0 > "$tmp/cm-$pr.ok"; }; } &
    elif [[ $sv == MERGE* ]] && [ -n "$crset" ] && jq -e --argjson n "$pr" 'index($n) != null' <<<"$crset" >/dev/null; then
      ubg_skip "$g" "$pr" rv
      v=$(ubg_stored "$g" "$pr" rv) && { printf '%s\n' "$v" > "$tmp/rv-$pr.json"; echo 0 > "$tmp/rv-$pr.ok"; }
      if [ ! -f "$tmp/rv-$pr.ok" ]; then
        _ucr_par "$par"
        { UBP_FRESH=$nc ubp_cached "$slug" "$pr" "$head" reviews "$tmp/rv-$pr.json" \
            _ucr_gh "$tmp" "$tmp/rv-$pr.json" "repos/$slug/pulls/$pr/reviews?per_page=100" && echo 0 > "$tmp/rv-$pr.ok" && : > "$tmp/rv-$pr.fresh"; } &
      fi
    fi
  done < <(jq -r '.[] | [.pr, .head] | @tsv' <<<"$prs")
  wait

  # The records.
  local base fr detail report readable reviews rec
  local -a eowned=()
  while IFS=$'\t' read -r pr head; do
    [ -n "$pr" ] && [ -f "$tmp/vd-$pr.ok" ] && [ "$gunk" = 0 ] || continue
    sv=$(jq -r '.standing.verdict // ""' "$tmp/vd-$pr.json"); ss=$(jq -r '.standing.source // ""' "$tmp/vd-$pr.json")
    base=$(jq -nc --arg proj "$project" --arg r "$slug" --argjson p "$pr" --arg h "$head" \
      '{family: "review", project: $proj, repo: $r, pr: $p, subject_kind: "pr", subject: "\($r)#\($p)", head: $h}')
    reviews=null; [ -f "$tmp/rv-$pr.ok" ] && { reviews=$(jq -c "$_UCR_RVC" "$tmp/rv-$pr.json" 2>/dev/null) || reviews=null; }
    [ -n "$reviews" ] || reviews=null
    fresh='{}'; [ -f "$tmp/rv-$pr.fresh" ] && [ "$reviews" != null ] && fresh=$(jq -c --argjson v "$reviews" '{rv: $v}' <<<"$fresh")
    if [ "$sv" = BLOCK ] && [ "$ss" = lead ]; then
      job=$(cat "$tmp/job-$pr" 2>/dev/null)
      # The report: readable only when the artifact holds a whole body (a cut
      # artifact or an empty-run marker is unknown, never "no BLOCK lines").
      report=null
      if [ -f "$tmp/art-$pr.ok" ]; then
        detail=$(jq -r '[.artifacts[]? | select(.artifact_kind == "lead_review_report") | .detail // ""] | first // ""' "$tmp/art-$pr.json" 2>/dev/null)
        report=$(jq -c 'if (.body | type) == "string" and .truncated != true then .body else null end' <<<"$detail" 2>/dev/null) || report=null
        [ -n "$report" ] || report=null
      fi
      # fc from the comments read now, else from the row (BH-10197).
      fc=null
      if [ -f "$tmp/cm-$pr.ok" ]; then
        fc=$(jq -c --arg h "$head" "$_UCR_FC" "$tmp/cm-$pr.json" 2>/dev/null) || fc=null
        [ -n "$fc" ] || fc=null
        [ "$fc" != null ] && fresh=$(jq -c --argjson v "$fc" '. + {fc: $v}' <<<"$fresh")
      elif [ -f "$tmp/fc-$pr" ]; then
        fc=$(jq -c 'if type == "boolean" then . else null end' "$tmp/fc-$pr" 2>/dev/null) || fc=null
        [ -n "$fc" ] || fc=null
      fi
      [ "$reviews" != null ] && [ "$fc" != null ] && ubg_put "$g" "$pr" "$head" "$fresh"
      fr=$(_ucr_fix_round "$h" "$project" "$slug" "$pr")
      readable=true; [ "$report" = null ] && readable=null
      rec=$(jq -c --argjson b "$base" --argjson st "$(jq -c .standing "$tmp/vd-$pr.json")" --arg job "$job" \
            --argjson body "$report" --argjson rv "${reviews:-null}" --argjson fc "$fc" \
            --argjson fr "$fr" --argjson readable "$readable" --argjson blmax "$blmax" -n '
        ($b.head) as $h
        | (if $body == null then null else [$body | split("\n")[] | select(test("^- \\[BLOCK"))] end) as $bl
        | (if $body == null then null else ([$body | split("\n")[] | select(test("^- outcome cap: "))] | first // null) end) as $cap
        | (if $rv == null then null else any($rv[]; .state == "CHANGES_REQUESTED" and .commit_id == $h) end) as $cr
        | if $cr == true or $fc == true then empty
          elif $body != null and ($bl | length) == 0 and $cap == null then "empty-owned" else
          ($cap != null and $bl != null and ($bl | length) == 0) as $caponly
          | $b + {
              kind: (if $caponly then "lead-block-cap-only" else "lead-block-unrouted" end),
              stall_at: $st.created_at,
              unknown: ([if $job == "" or $body == null then "report" else empty end,
                         if $rv == null then "reviews" else empty end,
                         if $fc == null then "comments" else empty end,
                         if $fr == null then "fix_round" else empty end]),
              verdict_id: $st.id, job_id: (if $job == "" then null else $job end),
              report_readable: $readable,
              block_lines: (if $bl == null then null else $bl[:$blmax] end),
              block_lines_truncated: (if $bl == null then null else ($bl | length) > $blmax end),
              cap_line: $cap, cap_only_candidate: $caponly,
              cr_on_head: $cr, findings_comment_on_head: $fc, fix_round_running: $fr }
            + (if $caponly then {metric: ($cap | capture("\\((?<m>[^)]*)\\) on ").m // null)} else {} end)
          end')
      if [ "$rec" = '"empty-owned"' ]; then eowned+=("$pr"); elif [ -n "$rec" ]; then printf '%s\n' "$rec" >> "$tmp/out.jsonl"; fi
    elif [[ $sv == MERGE* ]] && [ -f "$tmp/rv-$pr.ok" ] && [ "$reviews" != null ]; then
      ubg_put "$g" "$pr" "$head" "$fresh"
      jq -c --argjson b "$base" --argjson rv "$reviews" --arg sv "$sv" --arg logins "$logins" -n '
        ($logins | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $ls
        | $rv[] | select(.state == "CHANGES_REQUESTED" and .commit_id != $b.head)
        | (.body // "") as $t | (.user.login // "") as $who
        | (if ($t | contains("<!-- review-verdict:block ")) then "review-verdict"
           elif ($t | contains("<!-- tackler:")) then "tackler" else null end) as $mk
        | ($ls | index($who) != null) as $listed
        | select($mk != null or $listed)
        | $b + {kind: "stale-change-request", stall_at: .submitted_at, unknown: [],
                review_id: .id, review_commit: .commit_id, review_author: $who,
                review_marker: $mk, review_author_listed: $listed, standing_verdict: $sv}' >> "$tmp/out.jsonl"
    elif [[ $sv == MERGE* ]] && [ -n "$crset" ] && jq -e --argjson n "$pr" 'index($n) != null' <<<"$crset" >/dev/null; then
      unreadable+=("reviews#$pr")
    elif [[ $sv != MERGE* ]] || [ -n "$crset" ]; then
      # No gated read is needed for this PR this tick.
      ubg_put "$g" "$pr" "$head" '{}'
    fi
  done < <(jq -r '.[] | [.pr, .head] | @tsv' <<<"$prs")
  [ "$gunk" = 1 ] || ubg_commit "$g"

  # U7: a running request whose heartbeat is older than the stale limit, on an
  # open PR. head_current says whether it still reviews the PR's head.
  if [ -f "$tmp/running.ok" ] && jq -e '(.requests | type) == "array"' "$tmp/running.json" >/dev/null 2>&1; then
    [ "$(jq -r '.truncated // false' "$tmp/running.json")" = true ] && truncated=true
    jq -c --argjson prs "$prs" --arg proj "$project" --arg r "$slug" --argjson now "$now" --argjson lim "$stale" '
      def ep: if type == "string" then (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) else null end;
      .requests[] | select(.status == "running" and .repo == $r)
      | . as $q | ($prs | map(select(.pr == $q.pr)) | first) as $open | select($open != null)
      | ((.heartbeat_at // .updated_at) as $hb | {hb: $hb, ep: ($hb | ep)}) as $beat
      | select($beat.ep != null and ($now - $beat.ep) > $lim)
      | {family: "review", project: $proj, repo: $r, pr: .pr, subject_kind: "pr", subject: "\($r)#\(.pr)",
         head: $open.head, kind: "lead-request-stale",
         stall_at: $beat.hb, unknown: [], request_id: .id, request_head: .head_sha,
         heartbeat_age_s: ($now - $beat.ep),
         attempts: ((.reset_count // 0) + (.stale_reclaims // 0)),
         priority: .priority, head_current: (.head_sha == $open.head)}' "$tmp/running.json" >> "$tmp/out.jsonl"
  else
    unreadable+=(lead-reviews)
  fi

  local nrec nunk nrest nwork
  nrec=$(grep -c . "$tmp/out.jsonl"); nunk=$(jq -s '[.[].unknown | length] | add // 0' "$tmp/out.jsonl")
  nrest=$(grep -c . "$tmp/calls.rest"); nwork=$(grep -c . "$tmp/calls.worker")
  cat "$tmp/out.jsonl"
  jq -nc --arg r "$slug" --argjson n "$(jq 'length' <<<"$prs")" --argjson t "$truncated" \
    --argjson u "$(printf '%s\n' ${unreadable[@]+"${unreadable[@]}"} | jq -R . | jq -sc 'map(select(. != ""))')" \
    '{kind: "collector-meta", family: "review", repo: $r, prs_seen: $n, truncated: $t, unreadable: $u}'
  local gtail=""
  # gate=<checked>/<skipped> only when the check answered.
  [ -f "$g/ans.json" ] && gtail=" gate=$(jq '.items | length' "$g/ans.json" 2>/dev/null)/$(find "$g" -maxdepth 1 -name 'skip-*' | wc -l)"
  ubg_log "$g" "$([ "$gunk" = 1 ] && grep -c . "$g/items.jsonl" || echo 0)"
  _ucr_log "$slug prs=$(jq 'length' <<<"$prs") records=$nrec unknown=$nunk rest=$nrest worker=$nwork${unreadable[*]:+ unreadable=${unreadable[*]}}${eowned[*]:+ empty_owned=${#eowned[@]}:$(IFS=,; echo "${eowned[*]}")}$gtail"
  rm -rf "$tmp"
  return 0
}

# ub_collect_review <project> <repo> — the UNB-0 collector contract entry
# (bin/lib/unblock/collect.sh calls ub_collect_<family> with these two args).
# Without it the tick logged "unwired review (no ub_collect_review defined)"
# and collected nothing (lead BLOCK #4214). The tick gets the stall records
# only: the collector-meta line is not a stall record (its counts and the
# unreadable list are already in the collector's logs/unblock.log line). A
# non-zero rc is passed on, so the tick counts the family FAILED.
ub_collect_review() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 2
  local out rc=0
  out=$(unblock_collect_review --project "$1" --repo "$2") || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s\n' "$out" | grep -v -e '^{"kind":"collector-meta"' -e '^[[:space:]]*$' || true
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  unblock_collect_review "$@"
  exit $?
fi
