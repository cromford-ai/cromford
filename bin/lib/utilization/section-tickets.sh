#!/bin/bash
# shellcheck shell=bash
# bin/lib/utilization/section-tickets.sh — BH-4009 (BH-3988.1): the tickets
# section of a utilization snapshot. Sourced by bin/utilization-push.sh (every
# bin/lib/utilization/section-*.sh is), never run; reads the running builds
# through _jobs_req (bin/jobs-client.sh, which the collector has loaded).
#
# util_section_tickets <project>
#   Prints {tickets:{ready,blocked,held,parked,held_complete}, basis:{…}}, rc 0.
#   Every bucket is a count or null, NEVER a 0 standing in for a failed read
#   (D11), and every null bucket carries basis.<bucket>:"unmeasured".
#   held_complete is true when every candidate's hold was read, false when the
#   read budget ran out first, null when held is.
#   rc 1 and nothing printed when there is no project or no harness root
#   (${HARNESS:-${H:-}}: a lib never defaults to a path, D43).
#
# THE GITHUB-ISSUES LANE (fleet.conf board_prefix `-`): open issues labelled
# ai-build, PR items dropped, up to 3 pages of 100.
#   blocked  a body line starting (after list/quote marks) `Blocked-by` names a
#            bare #N that is in the list, or that a one-issue read does not say
#            is closed (open, 404, unreadable or past the read budget all count
#            as blocked: buildable only when every blocker is closed).
#   held     among the candidates (not blocked, no open PR whose head branch
#            carries <letters>-N, no running build of N), the ones
#            hold_classify (bin/lib/hold.sh) reads as held from the issue and
#            its comment thread. The thread is read with gh_rest and classified
#            here, not through hold_check, which can post a comment.
#   ready    the candidates that are not held; the ones past the read budget
#            count here, with held_complete false.
#   parked   null (no GitHub-Issues lane has a parked state).
# THE IN-APP LANE (board_prefix a path): one board list and one ticket list
# from the project's own API (fleet.conf prod + bin/internal-token-for.sh).
#   open     status not one of done closed cancelled canceled archived
#            rejected shipped review (a code constant: the board vocabulary).
#   blocked  .blocked == true.  parked: waitingOn client, or a triageVerdict
#            other than ready / empty (a blocked ticket is not also parked).
#   held     null: the ticket list carries no comments.
#   ready    open, not blocked or parked, with no open PR on the project repo
#            and no running build carrying its key.
# Any failed or capped read makes the buckets that depend on it null: the issue
# list all three, the PR list or the running-jobs read (500 rows is a cap,
# D12) ready, an unreadable hold thread held and ready.
#
# READS ONLY, AND BOUNDED (D21). Every GitHub call is a gh_rest GET marked
# GH_REST_OPTIONAL=1, so it yields to builds under the quota reserve. Per
# project and run: ≤3 issue pages, ≤3 PR pages, and at most
# UTIL_HOLD_READS_MAX (${UTIL_HOLD_READS_MAX:-30}, a lib.utilization-tickets
# settings row through lib_env_apply; the literal is the documented fallback)
# blocker-state and hold-thread reads between them.
# Registry: catalog/lanes.d/_lib.utilization-tickets.json.
# Doc: docs/notes/2026-10-03-BH-3988-ticket-buckets.md.

UTIL_TICKETS_PAGES=3
UTIL_TICKETS_CLOSED='done closed cancelled canceled archived rejected shipped review'

# _ut_pages <path with a query, no page> <out-file> — up to UTIL_TICKETS_PAGES
# pages of 100 merged into one array. rc 1 on any failed read, a page that is
# not an array, or a last page that is still full (capped, not a count).
_ut_pages() {
  local k t rc len
  t=$(mktemp "${TMPDIR:-/tmp}/util-tickets.XXXXXX") || return 1
  printf '[]\n' > "$2"
  for ((k = 1; k <= UTIL_TICKETS_PAGES; k++)); do
    rc=0; gh_rest GET "$1&per_page=100&page=$k" > "$t" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$t" >/dev/null 2>&1; then rm -f "$t"; return 1; fi
    jq -sc '.[0] + .[1]' "$2" "$t" > "$2.n" 2>/dev/null && mv "$2.n" "$2" || { rm -f "$t"; return 1; }
    len=$(jq 'length' "$t")
    [ "$len" -lt 100 ] && { rm -f "$t"; return 0; }
  done
  rm -f "$t"
  return 1
}

# util_heads_github <out-file> <repo> — the open PRs' head refs, lowercase, as a
# JSON array: _ut_pages of repos/<repo>/pulls?state=open (BH-10218 W4: the
# GitHub side of the utilization-push seam, kept beside the read). rc 1 on a
# failed or capped read, or a body jq cannot map.
util_heads_github() {
  local t rc=0
  t=$(mktemp "${TMPDIR:-/tmp}/util-tickets.XXXXXX") || return 1
  _ut_pages "repos/$2/pulls?state=open" "$t" || rc=1
  [ "$rc" = 0 ] && { jq -c '[.[] | (.head.ref // "") | tostring | ascii_downcase]' "$t" > "$1" 2>/dev/null || rc=1; }
  rm -f "$t" "$t.n"
  return "$rc"
}

# _ut_prr_arm — rc 0 when prr_read and the utilization-push seam are loaded;
# loads bin/lib/prr-shadow.sh and pins the step once per process.
_ut_prr_arm() {
  if ! command -v prr_read >/dev/null 2>&1; then
    # shellcheck source=bin/lib/prr-shadow.sh
    . "$(dirname "${BASH_SOURCE[0]}")/../prr-shadow.sh" 2>/dev/null || return 1
  fi
  if ! command -v util_heads_record >/dev/null 2>&1; then
    prr_seam_load utilization-push 2>/dev/null || return 1
  fi
  command -v prr_read >/dev/null 2>&1 && command -v util_heads_record >/dev/null 2>&1
}

# _ut_thread <repo> <n> <out-file> — the issue's comments, up to 10 pages.
_ut_thread() {
  local k t rc
  t=$(mktemp "${TMPDIR:-/tmp}/util-tickets.XXXXXX") || return 1
  printf '[]\n' > "$3"
  for ((k = 1; k <= 10; k++)); do
    rc=0; gh_rest GET "repos/$1/issues/$2/comments?per_page=100&page=$k" > "$t" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$t" >/dev/null 2>&1; then rm -f "$t"; return 1; fi
    jq -sc '.[0] + .[1]' "$3" "$t" > "$3.n" 2>/dev/null && mv "$3.n" "$3" || { rm -f "$t"; return 1; }
    [ "$(jq 'length' "$t")" -lt 100 ] && { rm -f "$t"; return 0; }
  done
  rm -f "$t"
  return 1
}

# _ut_print <ready> <blocked> <held> <parked> <held_complete> — JSON literals.
_ut_print() {
  jq -nc --argjson r "$1" --argjson b "$2" --argjson h "$3" --argjson p "$4" --argjson hc "$5" '
    {tickets:{ready:$r, blocked:$b, held:$h, parked:$p, held_complete:$hc},
     basis:({ready:$r, blocked:$b, held:$h, parked:$p} | with_entries(select(.value == null) | .value = "unmeasured"))}'
}

util_section_tickets() {
  local p="${1:-}" root="${HARNESS:-${H:-}}" here bp repo uri out run='[]' run_ok=0 max d
  [ -n "$p" ] && [ -n "$root" ] || return 1
  here="$(dirname "${BASH_SOURCE[0]}")/.."
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply utilization-tickets "$p" >/dev/null 2>&1
  max="${UTIL_HOLD_READS_MAX:-30}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=30
  max=$((10#$max))
  # shellcheck disable=SC2034 # read by _gh_quota_gate inside gh_rest
  local GH_REST_OPTIONAL=1
  # shellcheck disable=SC1091
  command -v gh_rest >/dev/null 2>&1 || . "$here/gh-rest.sh" 2>/dev/null
  # shellcheck disable=SC1091
  command -v hold_classify >/dev/null 2>&1 || . "$here/hold.sh" 2>/dev/null
  command -v gh_rest >/dev/null 2>&1 || { _ut_print null null null null null; return 0; }

  bp=$("$root/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || { _ut_print null null null null null; return 0; }
  repo=$("$root/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || repo=""
  _gh_rest_args_ok "$repo" || repo=""
  uri=$(jq -rn --arg v "$p" '$v|@uri') || return 1

  # The running builds, keyed lowercase. A failed or capped read leaves run_ok 0.
  if command -v _jobs_req >/dev/null 2>&1 \
    && out=$(_jobs_req GET "/api/jobs?project=$uri&status=running&kind=build&limit=500" 2>/dev/null); then
    run=$(printf '%s' "$out" | jq -c 'if (.jobs|type) == "array" and (.jobs|length) < 500
      then [.jobs[] | (.ticket_id // "") | tostring | ascii_downcase | select(. != "")] else empty end' 2>/dev/null)
    if [ -n "$run" ]; then run_ok=1; else run='[]'; fi
  fi

  d=$(mktemp -d "${TMPDIR:-/tmp}/util-tickets.XXXXXX") || { _ut_print null null null null null; return 0; }
  local prs_ok=0
  # BH-10218 W4: the open PR heads through the prr-shadow seam (step row
  # lane.utilization-push.gh_source, default shadow). No seam: today's read.
  if [ -n "$repo" ]; then
    if _ut_prr_arm; then
      prr_read utilization-push "$repo#open" "$d/heads.json" util_heads_record util_heads_github util_heads_norm "$repo" && prs_ok=1
    else
      util_heads_github "$d/heads.json" "$repo" && prs_ok=1
    fi
  fi
  [ "$prs_ok" = 1 ] || printf '[]\n' > "$d/heads.json"
  printf '%s\n' "$run" > "$d/run.json"

  if [ -z "$bp" ] || [ "$bp" = - ]; then
    _ut_gh "$repo" "$max" "$d" "$prs_ok" "$run_ok"
  else
    _ut_board "$p" "$root" "$bp" "$d" "$prs_ok" "$run_ok"
  fi
  rm -rf "$d"
  return 0
}

# claimed_num — jq: is issue/ticket number $n taken by an open PR head or a
# running build? $heads and $run are lowercased string arrays.
UTIL_TICKETS_CLAIMED_JQ='
  def claimed_num($n):
    ($heads | any(test("(^|[^a-z0-9])[a-z]{1,6}-" + $n + "([^0-9]|$)")))
    or ($run | any(. == $n or test("^[a-z]{1,6}-" + $n + "$")));
'

# _ut_gh <repo> <max> <dir> <prs_ok> <run_ok> — the GitHub-Issues lane.
_ut_gh() {
  local repo="$1" max="$2" d="$3" prs_ok="$4" run_ok="$5" used=0 open n refs r st blocked=0 blk=' '
  local memo=' ' cands held=0 ready=0 skipped=0 rc
  if [ -z "$repo" ] || ! _ut_pages "repos/$repo/issues?labels=ai-build&state=open" "$d/raw.json"; then
    _ut_print null null null null null; return 0
  fi
  jq -c '[.[] | select(type == "object" and (has("pull_request") | not))]' "$d/raw.json" > "$d/issues.json" 2>/dev/null \
    || { _ut_print null null null null null; return 0; }
  open=" $(jq -r '[.[].number] | map(tostring) | join(" ")' "$d/issues.json") "
  # One line per issue that names blockers: "<n>\t<ref> <ref>…".
  while IFS=$'\t' read -r n refs; do
    [ -n "$n" ] || continue
    for r in $refs; do
      case "$open" in *" $r "*) blocked=$((blocked+1)); blk="$blk$n "; continue 2 ;; esac
      case "$memo" in
        *" $r:closed "*) continue ;;
        *" $r:"*) blocked=$((blocked+1)); blk="$blk$n "; continue 2 ;;
      esac
      st=unknown
      if [ "$used" -lt "$max" ]; then
        used=$((used+1))
        rc=0; gh_rest_issue_state "$repo" "$r" > "$d/state" 2>/dev/null || rc=$?
        st=unknown
        [ "$rc" = 0 ] && st=$(cat "$d/state")
        memo="$memo$r:$st "
      fi
      [ "$st" = closed ] && continue
      blocked=$((blocked+1)); blk="$blk$n "; continue 2
    done
  done < <(jq -r '.[] | . as $i
      | [ (.body // "") | tostring | split("\n")[] | sub("\r$"; "")
          | select(test("^[\\s>*_#-]*blocked[- ]by\\b"; "i"))
          | match("(?<![A-Za-z0-9_./-])#([0-9]+)"; "g") | .captures[0].string ] | unique
      | select(length > 0) | "\($i.number)\t\(join(" "))"' "$d/issues.json" 2>/dev/null)

  cands=$(jq -r --argjson heads "$(cat "$d/heads.json")" --argjson run "$(cat "$d/run.json")" --arg blk "$blk" \
    "$UTIL_TICKETS_CLAIMED_JQ"'
    [.[] | .number | tostring | . as $n | select(($blk | contains(" " + $n + " ")) | not) | select(claimed_num($n) | not)]
    | sort_by(tonumber) | .[]' "$d/issues.json" 2>/dev/null)

  for n in $cands; do
    if [ "$used" -ge "$max" ]; then skipped=$((skipped+1)); continue; fi
    used=$((used+1))
    jq -c --argjson n "$n" '.[] | select(.number == $n)' "$d/issues.json" > "$d/issue.json" 2>/dev/null
    if ! _ut_thread "$repo" "$n" "$d/thread.json"; then held=unreadable; break; fi
    rc=0; hold_classify "$d/issue.json" "$d/thread.json" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) ready=$((ready+1)) ;;
      1) held=$((held+1)) ;;
      *) held=unreadable; break ;;
    esac
  done

  if [ "$held" = unreadable ]; then _ut_print null "$blocked" null null null; return 0; fi
  local hc=true
  [ "$skipped" -gt 0 ] && hc=false
  ready=$((ready+skipped))
  if [ "$prs_ok" = 1 ] && [ "$run_ok" = 1 ]; then
    _ut_print "$ready" "$blocked" "$held" null "$hc"
  else
    _ut_print null "$blocked" "$held" null "$hc"
  fi
}

# _ut_board <project> <root> <prefix> <dir> <prs_ok> <run_ok> — the in-app lane.
_ut_board() {
  local p="$1" root="$2" bp="$3" d="$4" prs_ok="$5" run_ok="$6" base tok bid counts r b pk
  base=$("$root/bin/fleet-conf.sh" "$p" prod 2>/dev/null) || base=""
  [ "$base" = - ] && base=""
  tok=$("$root/bin/internal-token-for.sh" "$p" 2>/dev/null) || tok=""
  if [ -z "$base" ] || [ -z "$tok" ]; then _ut_print null null null null null; return 0; fi
  bid=$(curl -sf -m 30 -H "Authorization: Bearer $tok" -H "User-Agent: curl/8" "$base$bp/boards" 2>/dev/null \
    | jq -r 'if type == "array" then .[0].id else .boards[0].id end // empty' 2>/dev/null)
  if [ -z "$bid" ] || ! curl -sf -m 30 -H "Authorization: Bearer $tok" -H "User-Agent: curl/8" \
      "$base$bp/boards/$bid/tickets" > "$d/board.json" 2>/dev/null; then
    _ut_print null null null null null; return 0
  fi
  # "<ready> <blocked> <parked>", or nothing when the body is not a ticket list.
  counts=$(jq -r --argjson heads "$(cat "$d/heads.json")" --argjson run "$(cat "$d/run.json")" --arg closed "$UTIL_TICKETS_CLOSED" \
    "$UTIL_TICKETS_CLAIMED_JQ"'
    def esc: gsub("(?<c>[.^$*+?()\\[\\]{}|\\\\])"; "\\\(.c)");
    def claimed_key($k):
      ($heads | any(test("(^|[^a-z0-9])" + ($k|esc) + "([^0-9]|$)"))) or ($run | any(. == $k));
    ($closed | split(" ")) as $closed
    | (if type == "array" then . elif (.tickets|type) == "array" then .tickets else error("not a list") end)
    | map(select(type == "object")
          | select(((.status // "") | tostring | ascii_downcase) as $s | ($closed | index($s)) == null))
    | map(. + {_b: (.blocked == true),
               _p: (((.waitingOn // .waiting_on) == "client")
                    or (((.triageVerdict // .triage_verdict // "") | tostring) as $v | ($v != "ready" and $v != "")))})
    | [ (map(select((._b or ._p) | not)
             | ((.key // .number // "") | tostring | ascii_downcase) as $k
             | select(if $k == "" then true
                      elif ($k | test("^[0-9]+$")) then (claimed_num($k) | not)
                      else (claimed_key($k) | not) end)) | length),
        (map(select(._b)) | length),
        (map(select(._p and (._b | not))) | length) ]
    | map(tostring) | join(" ")' "$d/board.json" 2>/dev/null)
  if ! [[ "$counts" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then _ut_print null null null null null; return 0; fi
  read -r r b pk <<< "$counts"
  if [ "$prs_ok" = 1 ] && [ "$run_ok" = 1 ]; then _ut_print "$r" "$b" null "$pk" null
  else _ut_print null "$b" null "$pk" null; fi
}
