#!/bin/bash
# bin/decompose-parent-close.sh <project> [--cooled] [--dry-run]
#
# THE MASTER NOBODY CLOSES (the operator, 2026-09-15). bin/run-decompose.sh splits a
# ticket that plans too big: it files one child issue per slice carrying
# `Part of #<parent>` and the `Blocked-by:` chain between them, comments the plan
# on the parent, and then STRIPS ai-build from the parent so no builder picks the
# whole thing up again ("this issue stays open as the master"). Nothing in this
# harness ever closes that master. Today the operator closed #855, #880, #901, #921, #669
# and #670 by hand, and an open unlabelled parent is not cosmetic: every ticket
# whose body says `Blocked-by: #<parent>` stays chained behind it forever, which
# is exactly how #671 sat waiting on a #670 whose every child had merged.
#
# So: given a project, find the parents the children name, and close the ones
# whose children have ALL closed — with a comment on the thread listing each
# child and the PR that shipped it, because the client's record of a split is
# that thread and "closed, no reason given" is worse than left open.
#
# WHAT IT REFUSES TO TOUCH:
#   * a parent that still carries ai-build. The label IS the handoff
#     (prompts/project-5.md); a labelled issue is somebody's buildable ticket,
#     not a parked master, whatever a child's body says about it. It is read
#     from the parent's OWN record, not only from the ai-build list, because a
#     parent past the list's window is still labelled (BH-949, #594).
#   * a parent with any child still OPEN, or any child whose state this pass
#     could not read. Closing a master while a slice is still building is a
#     client reading "done" over unfinished work.
#   * a parent with any child closed other than COMPLETED (NOT_PLANNED, or no
#     readable reason), or any child that does not resolve to a MERGED PR —
#     by branch/title in the PR list, or named on the child's own thread. A
#     dropped slice is not a delivered one. Each refusal of a split whose
#     children have all closed is logged once as PARENT_CLOSE_SKIPPED.
#
# IN-APP BOARDS GET THE SAME JOB DONE FROM A BETTER SIGNAL (BH-815). `Part of`
# is a GitHub convention and they do not have it, so this used to exit 0 for
# them and their masters stayed open forever. What they have instead is the
# dependency primitive (docs/BOARD-API-CONTRACT.md, "Dependencies"): a parent is
# any ticket whose `children: [{id,key,status}]` is non-empty and whose own
# status is not `done`. Same refusals, restated for that shape — every child
# must be `done` in the list AND its own record must confirm it, because an
# unreadable child is an unknown and an unknown is not a closure. Same cooldown,
# same PARENT_CLOSE_MAX, same kill switch. The close is `POST
# /tickets/{id}/comments` then `POST /tickets/{id}/move {toStatus:"done"}`, both
# with an Idempotency-Key bound to (project, parent, call); a retry after a
# comment that landed finds its own sentence on the thread and retries only the
# move. It prints the parent KEY, not a number, which is why the numeric filter
# in bin/unblocked-children.sh never folds an in-app close into a GitHub
# closure set.
#
# IDEMPOTENT BY CONSTRUCTION: the second run reads the parent as CLOSED and does
# nothing. No model call, no launch, and the only write it makes is the close
# plus its comment.
#
# It prints the parent numbers it closed, one per line, and THAT is the other
# half of the job: bin/unblocked-children.sh folds them into the closure set of
# the very pass that called it, so the dependents of a parent closed here come
# out as UNBLOCKED lines in the same output (docs/EVENTS.md §5.4).
#
# Kill switch: REVDEP_WAKE=0 or flags/revdep-wake-off — the same one that turns
# off the reverse-dependency wake, because these are two halves of one behaviour.
#
# gh-rest: no-graphql
#
set -uo pipefail
PROJECT="${1:?usage: decompose-parent-close.sh <project> [--cooled] [--dry-run]}"
shift
COOLED=0; DRY=0
for a in "$@"; do
  case "$a" in
    --cooled)  COOLED=1 ;;
    --dry-run) DRY=1 ;;
    *) ;;
  esac
done
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
SELF="$(cd "$(dirname "$0")" && pwd)"
# Read by hand, like every other script here that is also run from a cron with a
# stripped environment and from an operator's shell.
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi

# shellcheck source=bin/lib/revdep-lib.sh
[ -r "$SELF/lib/revdep-lib.sh" ] && . "$SELF/lib/revdep-lib.sh" 2>/dev/null
command -v revdep_on >/dev/null 2>&1 || exit 0
[ "$(revdep_on "$HARNESS")" = 1 ] || exit 0

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
PC_LOG() { # PC_LOG <line> -> one line in this project's own log, never a secret
  mkdir -p "$HARNESS/logs" 2>/dev/null || true
  echo "$(STAMP) [$PROJECT] $1" >> "$HARNESS/logs/$PROJECT.log" 2>/dev/null || true
}

# THE COOLDOWN IS FOR THE CALLERS IN THE HOT PATH. bin/unblocked-children.sh runs
# on every tick, bin/wake-loop.sh on every wake past the triage window, and the
# in-app release pass on every in-app tick; a parent that is not closable is not
# going to become closable in ninety seconds, and this pass costs a list call and
# a lookup per candidate parent. A hand run (no --cooled) is never held. It sits
# ABOVE the lane split so both lanes are paced by it.
MARK="$HARNESS/state/parent-close-$PROJECT.last"
COOL="${PARENT_CLOSE_COOLDOWN_S:-600}"
case "$COOL" in ''|*[!0-9]*) COOL=600 ;; esac
if [ "$COOLED" = 1 ] && [ "$COOL" -gt 0 ]; then
  LAST=0
  [ -r "$MARK" ] && LAST=$(tr -dc '0-9' < "$MARK" 2>/dev/null)
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  [ $(( $(date +%s) - LAST )) -ge "$COOL" ] || exit 0
  # THE WAKE BACKSTOP (BH-6976). Past the cooldown, a GitHub board's pass runs
  # only on an issue wake for a key in the keys file (the open children and
  # their parents of the last pass, or a `retry` line), or once the last pass is
  # PARENT_CLOSE_BACKSTOP_S old; bin/lib/wake-backstop.sh has the rule. A
  # quiet exit leaves MARK alone. In-app boards (no repo) keep the cooldown.
  PC_WREPO="${GH_ISSUES_REPO:-}"
  if [ -z "$PC_WREPO" ]; then
    # shellcheck source=bin/lib/dep-verify-lib.sh
    [ -r "$SELF/lib/dep-verify-lib.sh" ] && . "$SELF/lib/dep-verify-lib.sh" 2>/dev/null
    command -v dep_repo_for >/dev/null 2>&1 && PC_WREPO=$(dep_repo_for "$HARNESS" "$PROJECT" 2>/dev/null || true)
  fi
  if [ -n "$PC_WREPO" ]; then
    # jobs-client.sh EXITS the shell that sources it without its modules.
    # shellcheck source=bin/jobs-client.sh
    [ -r "$HARNESS/bin/jobs-client.sh" ] && [ -r "$HARNESS/bin/lib/jobs/req.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
    # shellcheck source=bin/lib/wake-backstop.sh
    [ -r "$SELF/lib/wake-backstop.sh" ] && . "$SELF/lib/wake-backstop.sh" 2>/dev/null
    if command -v wb_due >/dev/null 2>&1; then
      WB_RC=0
      WB_WHY=$(wb_due "$PC_WREPO" issue "$HARNESS/state/parent-close-$PROJECT.keys" "$LAST" "$COOL" \
                 "$(wb_knob PARENT_CLOSE_BACKSTOP_S)") || WB_RC=$?
      [ "$WB_RC" = 0 ] || exit 0
      case "$WB_WHY" in wake:*|backstop) PC_LOG "parent-close: pass on $WB_WHY" ;; esac
    fi
  fi
  mkdir -p "$HARNESS/state" 2>/dev/null || true
  date +%s > "$MARK" 2>/dev/null || true
fi

# The first sentence of the close comment, minus its count. It is the marker a
# retry recognises: a comment that landed while the move did not must not be
# posted twice, and the thread itself is the only place that fact is recorded.
PC_MARKER="parts of this one are in, so I am closing it."

# >>> inapp parent close
# Every request this lane makes, in two places, so the auth header and the
# 20-second ceiling are stated once. </dev/null because the candidate loop below
# reads a file on stdin and curl would eat it.
_pc_get() { # _pc_get <url> <outfile> -> the HTTP code on stdout
  local c
  c=$(curl -s -m 20 -o "$2" -w '%{http_code}' \
        -H "Authorization: Bearer $PC_TOKEN" -H "User-Agent: curl/8" \
        "$1" </dev/null 2>/dev/null) || c=""
  printf '%s' "${c:-000}"
}
_pc_post() { # _pc_post <url> <bodyfile> <idempotency-key> <outfile> -> HTTP code
  local c
  c=$(curl -s -m 30 -o "$4" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $PC_TOKEN" -H "Content-Type: application/json" \
        -H "Idempotency-Key: $3" -H "User-Agent: curl/8" \
        --data-binary @"$2" "$1" </dev/null 2>/dev/null) || c=""
  printf '%s' "${c:-000}"
}
# The board serves titles; they land inside an HTML comment body.
_pc_esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

# _pc_pr <child-key> <child-record-file> -> the PR that shipped it, or nothing.
#
# The child's own thread first (its close-out comment carries the link the
# client reads), then this box's build records. NEVER a guess: a child with no
# PR anywhere is listed by key alone, because a plausible-looking URL in a
# client-facing comment is worse than an honest gap (D26).
_pc_pr() {
  local url d first
  url=$(jq -r '[(.comments? // .ticket.comments? // .data.comments? // [])[]
                | {t: (.createdAt // .created_at // ""), b: (.body // "")}]
               | sort_by(.t) | reverse | map(.b) | join("\n")' "$2" 2>/dev/null \
        | grep -oE 'https://github\.com/[A-Za-z0-9._/-]+/pull/[0-9]+' | head -1)
  [ -n "$url" ] && { printf '%s' "$url"; return 0; }
  for d in $(ls -1dt "$HARNESS/builds/$PROJECT-$1"-*/ 2>/dev/null); do
    first=$(head -1 "$d/RESULT" 2>/dev/null)
    case "$first" in
      # FIELD TWO, not "everything after the first space". A RESULT line is
      # `PR_CREATED <url> | QUEUED: …` as often as it is bare (bin/run-build.sh),
      # and the note riding into a client-facing href is a broken link.
      "PR_CREATED http"*|"PR_MERGED http"*)
        set -- $first; printf '%s' "$2"; return 0 ;;
    esac
  done
  return 0
}

inapp_lane() {
  local bp bvar tmp bids bid n rc max examined
  bp=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null) || bp=""
  [ -n "$bp" ] && [ "$bp" != "-" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v curl >/dev/null 2>&1 || return 0
  [ -r "$HENV/$PROJECT.env" ] || return 0
  # Same discovery the generic in-app arm of bin/triage-gate.sh makes: the env
  # var NAME differs per project and is not derivable from the project name, so
  # the SUFFIX is the contract and <env dir>/<project>.env is the source. Values
  # never reach a log; bin/internal-token-for.sh logs variable names only.
  set -a; # shellcheck disable=SC1090
  . "$HENV/$PROJECT.env" 2>/dev/null; set +a
  bvar=$(grep -oE '^[A-Z_]+_(API|APP)_BASE' "$HENV/$PROJECT.env" 2>/dev/null | head -1)
  PC_BASE=""; [ -n "$bvar" ] && PC_BASE="${!bvar:-}"
  PC_TOKEN=$("$SELF/internal-token-for.sh" "$PROJECT" 2>/dev/null) || PC_TOKEN=""
  # NOT an error, and no log line: a board that has not adopted this is the
  # normal case on the fleet today and must stay completely silent.
  [ -n "$PC_BASE" ] && [ -n "$PC_TOKEN" ] || return 0
  PC_API="$PC_BASE$bp"

  tmp=$(mktemp -d) || return 0
  rc=$(_pc_get "$PC_API/boards" "$tmp/boards.json")
  [ "$rc" = 200 ] || { rm -rf "$tmp"; return 0; }
  bids=$(jq -r '(.boards? // .) | .[]?.id' "$tmp/boards.json" 2>/dev/null) || bids=""
  [ -n "$bids" ] || { rm -rf "$tmp"; return 0; }

  : > "$tmp/cands.tsv"
  n=0
  while IFS= read -r bid; do
    [ -n "$bid" ] || continue
    n=$((n + 1))
    rc=$(_pc_get "$PC_API/boards/$bid/tickets" "$tmp/list-$n.json")
    [ "$rc" = 200 ] || continue
    # A board that has not adopted the primitive carries `children` on no
    # ticket, so this selects nothing and the lane makes no write at all —
    # which is today's behaviour, reached without a capability negotiation.
    jq -r '(.tickets? // .) | .[]? | select(type == "object")
           | select((.children | type) == "array" and (.children | length) > 0)
           | select(((.status // "") | ascii_downcase) != "done")
           # A client-filed parent already in review is as closed as this lane
           # takes it (BH-3927). Dropped here, before any request, so it never
           # spends PARENT_CLOSE_MAX on every cooled run.
           | (((if (.reporter | type) == "object" then .reporter.userId else null end)
                // .reporterId // "") | tostring) as $rep
           | select((((.status // "") | ascii_downcase) == "review"
                     and $rep != "" and $rep != "null" and $rep != "system") | not)
           | [ (.id | tostring), (.key // (.id | tostring)),
               ([ .children[] | (.id | tostring) ] | join(" ")),
               ([ .children[] | ((.status // "") | ascii_downcase) ] | join(" ")) ]
           | @tsv' "$tmp/list-$n.json" 2>/dev/null >> "$tmp/cands.tsv"
  done <<<"$bids"

  max="${PARENT_CLOSE_MAX:-10}"
  case "$max" in ''|*[!0-9]*) max=10 ;; esac
  examined=0
  while IFS="$(printf '\t')" read -r pid pkey ckids cstats; do
    [ -n "$pid" ] || continue
    [ "$examined" -lt "$max" ] || break
    _inapp_close_one "$tmp" "$pid" "$pkey" "$ckids" "$cstats" && examined=$((examined + 1))
  done < "$tmp/cands.tsv"
  rm -rf "$tmp"
  return 0
}

# _inapp_close_one <tmpdir> <parentId> <parentKey> <childIds> <childStatuses>
#   rc 0 = a lookup was spent on this parent (that is what PARENT_CLOSE_MAX
#   bounds, exactly as the GitHub lane bounds `parent_state` calls).
_inapp_close_one() {
  local tmp="$1" pid="$2" pkey="$3" ckids="$4" cstats="$5"
  local st cid chttp cst ckey ctitle cpr lines nk phttp pst already body mhttp rep to
  # The cheap refusal first: every child done in the LIST costs no request.
  for st in $cstats; do [ "$st" = done ] || return 1; done
  [ -n "$ckids" ] || return 1

  # …then the expensive one. A child's own record has to be READABLE and has to
  # AGREE. HTTP 500, a 404, a status the list and the record disagree about:
  # every one of those is an unknown, and an unknown is not a closure (D9/D11).
  lines=""; nk=0
  for cid in $ckids; do
    chttp=$(_pc_get "$PC_API/tickets/$cid" "$tmp/child.json")
    [ "$chttp" = 200 ] || return 0
    cst=$(jq -r '((.status? // .ticket.status? // "") | ascii_downcase)' "$tmp/child.json" 2>/dev/null) || cst=""
    [ "$cst" = done ] || return 0
    ckey=$(jq -r '(.key? // .ticket.key? // "")' "$tmp/child.json" 2>/dev/null)
    [ -n "$ckey" ] && [ "$ckey" != null ] || ckey="$cid"
    ctitle=$(jq -r '(.title? // .ticket.title? // "")' "$tmp/child.json" 2>/dev/null)
    [ "$ctitle" = null ] && ctitle=""
    cpr=$(_pc_pr "$ckey" "$tmp/child.json")
    nk=$((nk + 1))
    if [ -n "$cpr" ]; then
      lines="$lines<li><a href=\"$(_pc_esc "$cpr")\">$(_pc_esc "$ckey${ctitle:+ $ctitle}")</a></li>"
    else
      lines="$lines<li>$(_pc_esc "$ckey${ctitle:+ $ctitle}")</li>"
    fi
  done

  phttp=$(_pc_get "$PC_API/tickets/$pid" "$tmp/parent.json")
  [ "$phttp" = 200 ] || return 0
  pst=$(jq -r '((.status? // .ticket.status? // "") | ascii_downcase)' "$tmp/parent.json" 2>/dev/null) || pst=""
  [ "$pst" = done ] && return 0
  # A client-filed parent goes to review, not done (BH-3927): the client checks
  # their own split. No reporter, or `system`, keeps today's done. A client
  # parent already in review is closed as far as this lane goes.
  rep=$(jq -r '(.reporter? // .ticket.reporter? // {}) | if type == "object" then (.userId // "") else "" end' "$tmp/parent.json" 2>/dev/null) || rep=""
  if [ -n "$rep" ] && [ "$rep" != null ] && [ "$rep" != system ]; then to=review; else to=done; fi
  [ "$pst" = review ] && [ "$to" = review ] && return 0
  ckey=$(jq -r '(.key? // .ticket.key? // "")' "$tmp/parent.json" 2>/dev/null)
  [ -n "$ckey" ] && [ "$ckey" != null ] && pkey="$ckey"
  [ -n "$pkey" ] || pkey="$pid"
  # DEDUPE BEFORE THE WRITE. A run whose comment landed and whose move did not
  # must finish the move without saying the same thing to the client twice.
  already=0
  jq -r '[(.comments? // .ticket.comments? // .data.comments? // [])[] | (.body // "")] | join("\n")' \
     "$tmp/parent.json" 2>/dev/null | grep -qF "$PC_MARKER" && already=1

  # Plain sentences, no em dashes, a direct link per part (rules/CLAUDE.md).
  body="<p>All $nk parts of this one are in, so I am closing it.</p><ul>$lines</ul><p>Nothing is left to build against this ticket. If something in the original ask did not make it into one of those parts, say so here and we will pick it up as its own ticket.</p>"
  jq -n --arg b "$body" '{body: $b}' > "$tmp/comment.json" 2>/dev/null || return 0
  printf '{"toStatus":"%s","sortOrder":999999}' "$to" > "$tmp/move.json"

  if [ "$DRY" = 1 ]; then
    printf 'DRYRUN POST %s\n%s\n' "$PC_API/tickets/$pid/comments" "$body" >&2
    printf 'DRYRUN POST %s {"toStatus":"%s"}\n' "$PC_API/tickets/$pid/move" "$to" >&2
    printf '%s\n' "$pkey"
    return 0
  fi

  if [ "$already" = 0 ]; then
    chttp=$(_pc_post "$PC_API/tickets/$pid/comments" "$tmp/comment.json" \
              "parent-close-$PROJECT-$pid-comment" "$tmp/resp.json")
    case "$chttp" in
      2??) : ;;
      *) PC_LOG "PARENT_CLOSE_FAILED $pkey — the close comment did not land (HTTP $chttp), so the move was not attempted"
         return 0 ;;
    esac
  fi
  mhttp=$(_pc_post "$PC_API/tickets/$pid/move" "$tmp/move.json" \
            "parent-close-$PROJECT-$pid-move" "$tmp/resp.json")
  # SUCCESS IS THE ECHO, not the status code: the board contract says the move
  # response carries the new status, and a 200 that did not move the ticket is a
  # failure wearing a success's clothes.
  case "$mhttp" in
    2??) if jq -e --arg to "$to" '[.. | strings] | index($to)' "$tmp/resp.json" >/dev/null 2>&1; then
           PC_LOG "PARENT_CLOSED $pkey (moved to $to) — every child of the split is done"
           # The key goes to stdout ONLY when the move really landed.
           printf '%s\n' "$pkey"
           return 0
         fi ;;
  esac
  PC_LOG "PARENT_CLOSE_FAILED $pkey — the close comment is on the thread but the move did not land (HTTP $mhttp)"
  return 0
}
# <<< inapp parent close

# shellcheck source=bin/lib/dep-verify-lib.sh
[ -r "$SELF/lib/dep-verify-lib.sh" ] && . "$SELF/lib/dep-verify-lib.sh" 2>/dev/null
repo="${GH_ISSUES_REPO:-}"
if [ -z "$repo" ] && command -v dep_repo_for >/dev/null 2>&1; then
  repo=$(dep_repo_for "$HARNESS" "$PROJECT" 2>/dev/null || true)
fi
# No GitHub repo means an in-app board (bin/lib/dep-verify-lib.sh resolves only
# the `-` rows), which is the other lane and not an absence of work.
[ -n "$repo" ] || { inapp_lane; exit 0; }

command -v gh >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
# The REST contract the close below goes through (#768): a comment and a close
# are two calls, and the close only counts once a fresh read says `closed`.
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$SELF/lib/gh-rest.sh" ] && . "$SELF/lib/gh-rest.sh"
# shellcheck source=bin/lib/gh-rest-list.sh
[ -r "$SELF/lib/gh-rest-list.sh" ] && . "$SELF/lib/gh-rest-list.sh"
# Whichever token can SEE this repo, for the reason bin/lib/gh-repo-token.sh
# exists: the hub's default PAT 404s on example-org/project-5, and an empty issue
# list there reads exactly like "no split has any children left".
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$SELF/lib/gh-repo-token.sh" ] && . "$SELF/lib/gh-repo-token.sh" 2>/dev/null
command -v gh_repo_use_token >/dev/null 2>&1 && { gh_repo_use_token "$repo" || exit 0; }
# Then the App token, AFTER the probe so the probe keeps its invisible-repo alert.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$SELF/lib/gh-app-auth.sh" ] && . "$SELF/lib/gh-app-auth.sh" 2>/dev/null
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$repo" || true

# The children are ai-build issues (the filer labels every one); the parents are
# not, which is the whole reason they need fetching by number below. 1000 rows
# is the REST paging ceiling bin/lib/gh-rest-list.sh already fixes (10 x 100),
# not a tunable: a split that falls past it reads as incomplete and is skipped,
# never closed (BH-949 — at 100 rows #594 fell out of the list and was closed
# three times with its ai-build label still on). state_reason is what tells a
# delivered child (COMPLETED) from one that was dropped (NOT_PLANNED).
# BH-1650: REST, upcased so the downstream "CLOSED"/"OPEN" comparisons hold; a
# failed page (403, 5xx) takes no action at all.
IL_T=$(mktemp) || exit 0
gh_rest_issue_list "$repo" all ai-build 1000 > "$IL_T" 2>/dev/null || { rm -f "$IL_T"; exit 0; }
ISSUES=$(jq -c 'map({number, state:(.state|ascii_upcase),
                     stateReason:((.state_reason // "")|ascii_upcase), title, body})' "$IL_T" 2>/dev/null) || { rm -f "$IL_T"; exit 0; }
rm -f "$IL_T"
[ -n "$ISSUES" ] || exit 0
# --state all, because the PR that shipped a closed child is merged: the open
# list cannot name it, and a close comment without the PR links is the half of
# this the client actually reads.
# REST as well, and in the shape the lookups below read (merged_at is the only
# REST field that says MERGED). A failed read leaves the list empty, which is
# never a close: every child then has to prove its merged PR on its own thread.
PL_T=$(mktemp) || exit 0
PRS="[]"
if gh_rest_pr_list_all "$repo" all 1000 > "$PL_T" 2>/dev/null; then
  PRS=$(jq -c 'map({number, url:.html_url, title, headRefName:(.head.ref // ""),
                    state:(if .merged_at then "MERGED" elif .state == "closed" then "CLOSED" else "OPEN" end)})' "$PL_T" 2>/dev/null) || PRS="[]"
fi
rm -f "$PL_T"
[ -n "$PRS" ] || PRS="[]"

TMP=$(mktemp -d) || exit 0
trap 'rm -rf "$TMP"' EXIT
printf '%s' "$ISSUES" > "$TMP/issues.json"
printf '%s' "$PRS"    > "$TMP/prs.json"

# THE TWO PIECES OF STATE THIS PASS KEEPS LIVE IN D1, THE FILE IS THE FALLBACK.
# The lookup cursor and the once-per-reason skip watermark are rows in the jobs
# DB's generic `ledgers` table (kind, key, status) through bin/jobs-client.sh,
# so a rebuilt hub or a second box running this pass picks up where the last one
# stopped. Every write also lands in the file, and a read the DB cannot answer
# (outage, no secret, no row yet) is answered from the file: losing both costs
# one repeated log line or one restart of the rotation, never an action.
# shellcheck source=bin/jobs-client.sh
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/comment-mark.sh
[ -r "$HARNESS/bin/lib/comment-mark.sh" ] && . "$HARNESS/bin/lib/comment-mark.sh"
pc_state_get() { # pc_state_get <kind> <key> <file> -> the stored value, D1 first
  local v
  # </dev/null: the skip loop below reads its file on stdin.
  if command -v job_ledger_get >/dev/null 2>&1 && v=$(job_ledger_get "$1" "$2" 2>/dev/null </dev/null); then
    printf '%s\n' "$v"; return 0
  fi
  cat "$3" 2>/dev/null
}
pc_state_put() { # pc_state_put <kind> <key> <file> <value> -> D1 row, then the file
  command -v job_ledger_put >/dev/null 2>&1 && job_ledger_put "$1" "$2" "$4" >/dev/null 2>&1 </dev/null
  mkdir -p "$(dirname "$3")" 2>/dev/null || true
  printf '%s\n' "$4" > "$3" 2>/dev/null || true
}

# A dry run neither reads nor moves the cursor: it starts from the lowest parent.
PC_CURSOR=""; CUR_FILE="$HARNESS/state/parent-close-cursor-$PROJECT"; CUR_OLD=""
if [ "$DRY" != 1 ]; then
  PC_CURSOR="$TMP/cursor"
  CUR_OLD=$(pc_state_get parent-close-cursor "$PROJECT" "$CUR_FILE" | tr -dc '0-9')
  printf '%s\n' "$CUR_OLD" > "$PC_CURSOR"
fi
PC_REPO="$repo" PC_TMP="$TMP" PC_CURSOR="$PC_CURSOR" PC_MAX="${PARENT_CLOSE_MAX:-10}" \
python3 - "$TMP/issues.json" "$TMP/prs.json" <<'PYEOF' >/dev/null 2>&1
import json, os, re, subprocess, sys

try:
    with open(sys.argv[1]) as f:
        issues = json.load(f)
    with open(sys.argv[2]) as f:
        prs = json.load(f)
except Exception:
    sys.exit(0)
if not isinstance(issues, list):
    sys.exit(0)
if not isinstance(prs, list):
    prs = []
repo = os.environ.get("PC_REPO", "")
tmp = os.environ.get("PC_TMP", "")
try:
    max_parents = int(os.environ.get("PC_MAX", "10"))
except Exception:
    max_parents = 10
cursor_path = os.environ.get("PC_CURSOR", "")

state = {}
reason = {}
for i in issues:
    if isinstance(i, dict) and "number" in i:
        state[int(i["number"])] = str(i.get("state", "")).upper()
        reason[int(i["number"])] = str(i.get("stateReason") or "").upper()
title = {int(i["number"]): str(i.get("title", "")) for i in issues
         if isinstance(i, dict) and "number" in i}

# "Part of #855", "Part of: #855", "> **Part of #855**" — the line the filer
# writes (bin/run-decompose.sh), read with the same markdown tolerance
# bin/unblocked-children.sh reads Blocked-by with.
part_re = re.compile(r"^[\s>*_\-#]*part[- ]of\b[^#\n]*#(\d+)", re.IGNORECASE | re.MULTILINE)
# "Order: 2 of 5" — the filer writes it on every child, and it is the only place
# the size of a split is recorded. It is the guard against a TRUNCATED view: the
# issue list above is --limit 1000, and a split whose children do not all fit in
# it would otherwise read as "every child I can see is closed".
order_re = re.compile(r"^[\s>*_\-#]*order\s*:?\s*\d+\s+of\s+(\d+)",
                      re.IGNORECASE | re.MULTILINE)

children = {}
declared = {}
for i in sorted(issues, key=lambda x: int(x.get("number", 0))):
    if not isinstance(i, dict) or "number" not in i:
        continue
    body = i.get("body") or ""
    for m in part_re.finditer(body):
        parent = int(m.group(1))
        children.setdefault(parent, []).append(int(i["number"]))
        om = order_re.search(body)
        if om:
            declared[parent] = max(declared.get(parent, 0), int(om.group(1)))


# BH-6976: the keys an issue wake must name for the next --cooled pass to run
# before its backstop: every OPEN child and the parent it names.
if tmp:
    try:
        with open(os.path.join(tmp, "keys"), "w") as f:
            for parent in sorted(children):
                opened = [k for k in sorted(set(children[parent])) if state.get(k) == "OPEN"]
                if opened:
                    f.write("".join("%d\n" % k for k in opened + [parent]))
    except Exception:
        pass


def _gh_json(args):
    """One `gh` read, parsed; None on ANY failure. Not read is not merged."""
    try:
        out = subprocess.run(["gh"] + args, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=60)
        if out.returncode != 0:
            return None
        return json.loads(out.stdout.decode("utf-8", "replace"))
    except Exception:
        return None


merged_in_list = {}
for p in prs:
    if isinstance(p, dict) and str(p.get("state", "")).upper() == "MERGED":
        try:
            merged_in_list[int(p.get("number"))] = p
        except Exception:
            pass
thread_pr_re = re.compile(r"https://github\.com/%s/pull/(\d+)" % re.escape(repo),
                          re.IGNORECASE)


def merged_pr_for(n):
    """The canonical URL of a MERGED PR that shipped issue <n>, or None.

    Two sources, merged only (BH-949: an open or unmerged PR is not a shipped
    part, and "closed without a PR" is not one either):
      1. the two names bin/run-build.sh gives its work — the branch
         `ticket/<key>-<n>` (plus the `-r<n>` retry suffix) and the PR title
         `<KEY>-<n>: <subject>` — matched on the ISSUE NUMBER so this stays free
         of the per-project key prefix, exactly as bin/unblocked-children.sh
         does it;
      2. the issue's own thread (#935): the close-out comment names the PR, and
         a PR merged by hand or rebuilt under another branch is only found
         there. Only THIS repo's `pull/<n>` is accepted, newest comment first,
         at most three distinct numbers, and each is confirmed merged (the list
         above, or `merged_at` on its own REST read).
    The URL returned is rebuilt from the verified number, never copied out of a
    comment.
    """
    br_re = re.compile(r"^ticket/[a-z0-9]+-%d(-r\d+)?$" % n, re.IGNORECASE)
    ti_re = re.compile(r"^[A-Za-z]+-%d:" % n)
    for p in merged_in_list.values():
        if br_re.match(str(p.get("headRefName", ""))) or ti_re.match(str(p.get("title", ""))):
            return "https://github.com/%s/pull/%d" % (repo, int(p["number"]))
    if not repo:
        return None
    comments = _gh_json(["api", "repos/%s/issues/%d/comments?per_page=100" % (repo, n)])
    if not isinstance(comments, list):
        return None
    tried = []
    for c in reversed(comments):
        if not isinstance(c, dict):
            continue
        for m in reversed(thread_pr_re.findall(str(c.get("body") or ""))):
            num = int(m)
            if num in tried:
                continue
            if len(tried) >= 3:
                return None
            tried.append(num)
            if num in merged_in_list:
                return "https://github.com/%s/pull/%d" % (repo, num)
            d = _gh_json(["api", "repos/%s/pulls/%d" % (repo, num)])
            if isinstance(d, dict) and isinstance(d.get("merged_at"), str) and d.get("merged_at"):
                return "https://github.com/%s/pull/%d" % (repo, num)
    return None


def parent_state(n):
    """OPEN / CLOSED / LABELLED / "" for a parent, fetched BY NUMBER.

    It is usually not in the list this pass works from — the size gate stripped
    ai-build when it decomposed the ticket — so "missing" carries no
    information at all and has to be asked for. A parent that still carries
    ai-build is somebody's buildable ticket even when it fell past the list
    (#594, BH-949), so its labels are read here too. Anything that is not a
    clean answer (no labels field, an unknown state) leaves the parent alone.
    """
    if not repo:
        return ""
    # REST (BH-1650), never `gh issue view`: that one spends the GraphQL bucket.
    # A pull request answers on this path too, and is never a parent.
    d = _gh_json(["api", "repos/%s/issues/%d" % (repo, n)])
    if not isinstance(d, dict) or d.get("pull_request") is not None:
        return ""
    if d.get("title") and int(d.get("number", 0) or 0) == n:
        title.setdefault(n, str(d.get("title")))
    s = str(d.get("state", "")).upper()
    if s == "CLOSED":
        return s
    if s != "OPEN":
        return ""
    labels = d.get("labels")
    if not isinstance(labels, list):
        return ""
    for l in labels:
        if not isinstance(l, dict) or not isinstance(l.get("name"), str):
            return ""
        if l["name"].strip().lower() == "ai-build":
            return "LABELLED"
    return "OPEN"


skips = []


# Every refusal the one list already paid for is decided first, for EVERY
# parent, so a labelled or dropped split is refused (and says so) however many
# lookups the tick has left.
candidates = []
for parent in sorted(children):
    kids = sorted(set(children[parent]))
    # Every child closed, and every child's state actually known. A child that
    # is not in the ai-build list at all (someone stripped its label, or it is
    # past the list's 1000) is an unknown, and an unknown is not a closure. A
    # split with a child still open is the normal wait, and logs nothing.
    if any(state.get(k) != "CLOSED" for k in kids):
        continue
    # A parent the ai-build list carries is a LABELLED issue, and the label is
    # the handoff: that is somebody's buildable ticket, not a parked master.
    if parent in state:
        skips.append((parent, "parent carries ai-build"))
        continue
    # A split of five whose list only carries four is not a split with four
    # closed children; it is a list we cannot draw a conclusion from.
    if declared.get(parent, 0) > len(kids):
        continue
    # CLOSED IS NOT SHIPPED (BH-949). A child closed NOT_PLANNED (or with no
    # reason this pass can read) was dropped, not delivered: #594's four parts
    # were all NOT_PLANNED and the master was closed over them three times.
    dropped = [k for k in kids if reason.get(k) != "COMPLETED"]
    if dropped:
        skips.append((parent, "child #%d closed %s"
                      % (dropped[0], reason.get(dropped[0]) or "unknown")))
        continue
    candidates.append(parent)

# THE BOUND IS ON LOOKUPS, not on closes. parent_state() and the PR reads behind
# it are requests, and a repo where fifty issues say "Part of #N" must not turn
# one tick into fifty of them. AND THE BOUND ROTATES: most candidates are masters
# closed long ago (each costs a view to find out), so a pass that always started
# from the lowest number would spend every tick on the same ten and never reach
# a newer split. The cursor (a D1 ledger row, the file as fallback) holds the
# last parent looked up; the next pass starts after it and wraps, so every
# candidate is reached within ceil(candidates / PARENT_CLOSE_MAX) passes.
# Losing it restarts from the top.
cursor = 0
try:
    with open(cursor_path) as f:
        cursor = int(f.read().strip() or 0)
except Exception:
    cursor = 0
rotated = [p for p in candidates if p > cursor] + [p for p in candidates if p <= cursor]

closable = []
looked_up = 0
last = None
for parent in rotated:
    if looked_up >= max_parents:
        break
    kids = sorted(set(children[parent]))
    last = parent
    looked_up += 1
    ps = parent_state(parent)
    if ps == "LABELLED":
        skips.append((parent, "parent carries ai-build"))
        continue
    if ps == "":
        skips.append((parent, "parent state unreadable"))
        continue
    if ps != "OPEN":
        continue
    # The client's record of a split is this thread, so the comment carries what
    # they would otherwise have to reconstruct: which part, and where it merged.
    # Plain sentences, no em dashes (the board voice in rules/CLAUDE.md). EVERY
    # part must resolve to a merged PR — a COMPLETED child with none anywhere
    # (finished by hand, folded into other work) leaves the master open and the
    # reason in the log, because the close comment would otherwise tell the
    # client a part shipped that this pass cannot show them.
    lines = []
    missing = None
    for k in kids:
        url = merged_pr_for(k)
        if not url:
            missing = k
            break
        t = title.get(k, "")
        label = "#%d%s" % (k, (" " + t) if t else "")
        lines.append("- %s, merged in %s" % (label, url))
    if missing is not None:
        skips.append((parent, "child #%d has no merged PR" % missing))
        continue
    body = ("All %d parts of this one are in, so I am closing it.\n\n%s\n\n"
            "Nothing is left to build against this ticket. If something in the "
            "original ask did not make it into one of those parts, say so here "
            "and we will pick it up as its own ticket."
            % (len(kids), "\n".join(lines)))
    try:
        with open(os.path.join(tmp, "close-%d.md" % parent), "w") as f:
            f.write(body)
    except Exception:
        continue
    closable.append(parent)

if last is not None and cursor_path:
    try:
        with open(cursor_path, "w") as f:
            f.write("%d\n" % last)
    except Exception:
        pass

# One line per refused parent; bash logs it only when the reason changed.
try:
    with open(os.path.join(tmp, "skips.tsv"), "w") as f:
        for p, why in skips:
            f.write("%d\t%s\n" % (p, why))
except Exception:
    pass

print("\n".join(str(p) for p in closable))
PYEOF
PYRC=$?
[ "$PYRC" = 0 ] || exit 0
if [ -n "$PC_CURSOR" ]; then
  CUR_NEW=$(tr -dc '0-9' < "$PC_CURSOR" 2>/dev/null)
  [ -n "$CUR_NEW" ] && [ "$CUR_NEW" != "$CUR_OLD" ] \
    && pc_state_put parent-close-cursor "$PROJECT" "$CUR_FILE" "$CUR_NEW"
fi

# WHY A MASTER STAYS OPEN, SAID ONCE (BH-949). A split whose children have all
# closed but which this pass refused is exactly the case someone will ask about,
# so the reason goes to the project log — once per change of reason, not every
# tick: the parent-close-skip ledger row for <project>#<N> (D1, with
# state/parent-close-skip-<project>-<N> as the fallback) holds the last reason
# logged, and losing it costs one repeated line, never an action. A dry run logs and leaves
# the watermark alone, so the real run after it still says why.
if [ -s "$TMP/skips.tsv" ]; then
  while IFS=$'\t' read -r N WHY; do
    case "$N" in ''|*[!0-9]*) continue ;; esac
    SMARK="$HARNESS/state/parent-close-skip-$PROJECT-$N"
    [ "$DRY" != 1 ] && [ "$(pc_state_get parent-close-skip "$PROJECT#$N" "$SMARK")" = "$WHY" ] && continue
    PC_LOG "PARENT_CLOSE_SKIPPED #$N — $WHY"
    [ "$DRY" != 1 ] && pc_state_put parent-close-skip "$PROJECT#$N" "$SMARK" "$WHY"
  done < "$TMP/skips.tsv"
fi

for f in "$TMP"/close-*.md; do
  [ -f "$f" ] || continue
  N=$(basename "$f" .md); N="${N#close-}"
  case "$N" in ''|*[!0-9]*) continue ;; esac
  if [ "$DRY" = 1 ]; then
    # The BODY, not the path: the temp dir is gone by the time anyone could read
    # it, and the comment is the half of this a human wants to check.
    printf 'DRYRUN comment + close #%s on %s:\n%s\n' "$N" "$repo" "$(cat "$f")" >&2
    printf '%s\n' "$N"
    continue
  fi
  # TWO CALLS, NOT ONE (BH-781). `gh issue close --comment` has no single REST
  # equivalent, so the comment goes first and the close second — a parent is
  # never announced closed on a comment that did not land, and gh_rest_close
  # returns 0 only after a fresh read says `closed`.
  #
  # AND THE COMMENT IS POSTED EXACTLY ONCE ACROSS RETRIES. Splitting one atomic
  # call into two loses what the atomic one had for free: `gh issue close
  # --comment` could not leave a comment behind without a close. POST 201 then
  # PATCH 403 (GitHub's secondary limit on consecutive content writes is exactly
  # this shape) leaves the parent OPEN, and the conductor rebuilds this list
  # every */5 tick — so without a marker the same client-visible close comment
  # lands again on every tick until the PATCH goes through. That is the TK-88
  # class (one bot comment 213 times in 5.5h on a client thread). The marker
  # follows the POST, never the attempt: a rate-limited tick that marked anyway
  # would close the parent later with no explanation on the thread at all. The
  # in-app lane above needs none of this — its Idempotency-Key already makes the
  # comment exactly-once.
  #
  # The marker is a D1 `commented` row as well as the file (BH-2317), so a wiped
  # hub does not post it again; bin/lib/comment-mark.sh has the read rule. A
  # bin/ without that lib (127) answers from the file, as before.
  CMARK="$HARNESS/state/parent-close-commented-$PROJECT-$N"
  CMKEY="parent-close $PROJECT $N"
  CRC=0; CMRC=0
  cm_has "$CMKEY" - "$CMARK" 2>/dev/null || CMRC=$?
  [ "$CMRC" = 127 ] && { [ -e "$CMARK" ] && CMRC=0; }
  if [ "$CMRC" != 0 ]; then
    if gh_rest_comment "$repo" "$N" "$f"; then
      mkdir -p "$HARNESS/state" 2>/dev/null || true
      cm_put "$CMKEY" - "$CMARK" 2>/dev/null || : > "$CMARK" 2>/dev/null || true
    else
      CRC=1
    fi
  fi
  if [ "$CRC" = 0 ] && gh_rest_close "$repo" "$N" issues; then
    mkdir -p "$HARNESS/logs" 2>/dev/null || true
    echo "$(STAMP) [$PROJECT] PARENT_CLOSED #$N — every child of the split is closed" \
      >> "$HARNESS/logs/$PROJECT.log" 2>/dev/null || true
    # The marker's whole job is "a comment is already on this thread and the
    # close has not landed yet". The close landed, so it is dropped: a parent
    # reopened and re-closed later gets its own explanation, not silence. The
    # skip watermark goes with it, so a reopened master's next refusal is logged.
    cm_clear "$CMKEY" "$CMARK" 2>/dev/null
    rm -f "$CMARK" "$HARNESS/state/parent-close-skip-$PROJECT-$N" 2>/dev/null || true
    command -v job_ledger_put >/dev/null 2>&1 \
      && job_ledger_put parent-close-skip "$PROJECT#$N" closed >/dev/null 2>&1
    # The number goes to stdout ONLY when the close really landed: the caller
    # folds it into its closure set, and a closure we only wished for would
    # release a chain behind a parent that is still open.
    printf '%s\n' "$N"
  else
    mkdir -p "$HARNESS/logs" 2>/dev/null || true
    echo "$(STAMP) [$PROJECT] PARENT_CLOSE_FAILED #$N — every child is closed but the close did not land" \
      >> "$HARNESS/logs/$PROJECT.log" 2>/dev/null || true
    PC_FAILED=1
  fi
done
# The keys file the next --cooled pass's wake gate reads (BH-6976). A failed
# close adds `retry`, so it is tried again after the cooldown, as before.
KF="$HARNESS/state/parent-close-$PROJECT.keys"
if [ "$DRY" != 1 ] && [ -f "$TMP/keys" ]; then
  [ "${PC_FAILED:-0}" = 1 ] && echo retry >> "$TMP/keys"
  mkdir -p "$HARNESS/state" 2>/dev/null || true
  cp "$TMP/keys" "$KF.tmp.$$" 2>/dev/null && mv -f "$KF.tmp.$$" "$KF" 2>/dev/null
  rm -f "$KF.tmp.$$" 2>/dev/null
fi
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
