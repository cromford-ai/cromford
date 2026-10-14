#!/bin/bash
# bin/lib/ticket-ownership.sh — ONE OWNER PER TICKET (BH-1526). Sourced, never
# executed. The one answer every lane that queues, splits, builds or merges a
# ticket asks before it spends anything on it.
#
# WHY IT EXISTS (2026-09-22). The pool raced lead-built tickets all day:
# BH-1486's pool PR #1497 merged ahead of the lead's #1495, which was then
# closed as superseded after a full build and review; BH-1484's pool PR #1500
# opened an hour after the lead's #1493 and would have merged over it on a
# tier-2 APPROVE; BH-1485 was split into five children minutes after filing
# while the lead built the parent. A body `HOLD:` line was the documented way
# to reserve a ticket, and only bin/fly-pool.sh's spawn gate ever read it: the
# enqueue, the pre-plan, the splitter, a build already running and all four
# merge lanes did not.
#
# THE HOLD IS bin/lib/hold.sh's, NEVER A SECOND PARSER. Everything here reads a
# ticket through hold_check and decides with hold_is_pause / hold_is_abandon.
# `held<TAB>closed` and `held<TAB>label-absent` are FACTS about an issue, not
# instructions on it, and they are deliberately NOT a hold here: a decomposed
# parent is de-labelled on purpose, and reading that as a HOLD would stop every
# child PR of every split from merging. Closed issues have their own gate
# (bin/run-build.sh's closed-issue skip).
#
# THE LEAD IS A SETTINGS ROW, NOT A LOGIN IN CODE (the operator, #1511: no hardcodes).
# `lead_pr_authors` (worker/jobs/schema.sql seeds it) is a space- or comma-
# separated list of GitHub logins. A lead-authored PR is exempt from the merge
# hold (the hold exists to reserve the ticket FOR that PR) and always wins the
# one-PR-per-ticket rule. An unreadable row means "nobody is the lead": the
# merge gate then holds the lead's PR too (the safe side), and the duplicate
# closer does nothing at all, because closing a PR needs to know whose it is.
#
# Entry points (rc 0 always means "the ticket says stop"):
#   to_build_hold <project> <ticket-id> [key]   queue / pre-plan / split / stage
#       rc 0 held (prints the hold verdict), 1 go, 2 could not read (prints it).
#       Only GitHub-Issues projects (fleet.conf board prefix "-") have a ticket
#       to read; a board project, a non-numeric ticket and a merge-conductor
#       RB-* rebase row all answer 1.
#   to_merge_hold <project> <owner/repo> <pr-number>
#       rc 0 do NOT merge this pass (prints one reason line), 1 merge as today.
#   to_lead_merge_hold <owner/repo> <pr> [head] [author]   (BH-1558)
#       rc 0 a lead PR with no lead/human MERGE row on its live head: do NOT
#       merge; 1 merge as today; 2 unreadable: not this pass. to_lane_lead_hold
#       is the lane call site (rc 0/2 = do not merge), in to_lane_hold's shape.
#   to_pr_author_head <owner/repo> <pr>  sets TO_PR_LOGIN / TO_PR_HEAD.
#   to_lane_lead_fence <project> <owner/repo> <pr> <head> <author> [log]
#       (BH-1606) to_lane_lead_hold plus the lane's outage alert: the call every
#       merge lane makes. rc as to_lane_lead_hold.
#   to_held_prune <owner/repo> <open-pr-number>…   (BH-1606) drops the
#       MERGE_HELD dedupe files of that repo's CLOSED PRs.
#   to_dedupe_open_prs <owner/repo>
#       closes every pool PR that duplicates another open PR's ticket, lead
#       first, then oldest. Sets TO_LOSERS (" slug#num …") for to_merge_hold.
#
# EVERY GITHUB CALL THIS FILE MAKES GOES THROUGH bin/lib/gh-rest.sh (BH-784):
# a merge-family decision is judged on the HTTP status line, never on an empty
# body, and each helper runs as a plain command with `> file || rc=$?` so its
# GH_REST_STATUS survives (#1496). The ticket reads themselves are hold_check's.
# The merge gate arms the repo's App token (gh_auth_for) inside the `$( )` every
# caller runs it in, so the token dies with that subshell; the duplicate closer
# runs on the identity the conductor already armed for the repo.
#
# WHAT "LEAD" CAN AND CANNOT TELL APART (review round 1, I-2). The lead is an
# AUTHOR, so a pool PR opened under the lead's own login (the PAT fallback in
# gh_default_auth_for_project, or a pool branch opened by hand) reads as lead:
# exempt from the merge hold and never closed as a duplicate. The damage is
# bounded to issues projects on a PAT fallback; the fix is the pool never
# authoring as the lead, not a branch-shape guess here.
#
# A `-rN` SUCCESSOR OPEN BESIDE ITS STILL-OPEN ORIGINAL is closed as the newer
# pool PR. In practice bin/blocked-resolver.sh closes the original before it
# rebuilds (its close "has to land" first), so the pair only exists when that
# order broke, and the older PR keeps the review it already had.
# gh-rest: no-graphql

to__h() { printf '%s' "${HARNESS:-/root/harness}"; }

# The lane's own logger when it has one (the conductor's mc_log), else one line
# in logs/ticket-ownership.log. Never ALERTS: every decision here is a lane
# doing what the ticket said, which is not something a person must look at.
to__say() {
  if command -v mc_log >/dev/null 2>&1; then mc_log "$*"; return 0; fi
  local f; f="$(to__h)/logs/ticket-ownership.log"
  mkdir -p "${f%/*}" 2>/dev/null
  printf '%s [ticket-ownership] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$f" 2>/dev/null || true
}

# hold.sh beside this file first (a worktree run reads its own copy), then the
# harness copy. Idempotent; an absent library is "no hold to read", never a
# freeze — the answer bin/fly-pool.sh and mc_hold_keeps_pr already give.
to__load_hold() {
  command -v hold_check >/dev/null 2>&1 && command -v hold_is_pause >/dev/null 2>&1 && return 0
  local f
  for f in "$(dirname "${BASH_SOURCE[0]}")/hold.sh" "$(to__h)/bin/lib/hold.sh"; do
    # shellcheck source=bin/lib/hold.sh
    [ -r "$f" ] && { . "$f" 2>/dev/null; break; }
  done
  command -v hold_check >/dev/null 2>&1 && command -v hold_is_pause >/dev/null 2>&1
}

# gh-rest.sh beside this file first, then the harness copy. Idempotent (the lib
# guards its own re-source). Absent, no GitHub call is made at all.
to__load_rest() {
  command -v gh_rest >/dev/null 2>&1 && return 0
  local f
  for f in "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" "$(to__h)/bin/lib/gh-rest.sh"; do
    # shellcheck source=bin/lib/gh-rest.sh
    [ -r "$f" ] && { . "$f" 2>/dev/null; break; }
  done
  command -v gh_rest >/dev/null 2>&1
}

# to_issue_repo <project> — the repo whose ISSUES are this project's tickets, or
# rc 1 for an in-app board project (its holds live on the board).
to_issue_repo() {
  local p="${1:-}" h s
  [ -n "$p" ] || return 1
  h=$(to__h)
  [ "$("$h/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)" = "-" ] || return 1
  s="${GH_ISSUES_REPO:-}"
  [ -n "$s" ] || s=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  case "$s" in */*) printf '%s' "$s" ;; *) return 1 ;; esac
}

# to_hold_verdict <owner/repo> <issue> — hold_check's line on stdout;
# rc 0 pause or abandon, 1 anything else, 2 unreadable.
to_hold_verdict() {
  local v
  to__load_hold || { printf 'clear\tno hold library on this box\n'; return 1; }
  v=$(hold_check "${1:-}" "${2:-}" 2>/dev/null)
  [ -n "$v" ] || v='unreadable	the hold check printed nothing'
  printf '%s\n' "$v"
  case "$v" in unreadable*) return 2 ;; esac
  if hold_is_pause "$v" || hold_is_abandon "$v"; then return 0; fi
  return 1
}

to_build_hold() {
  local p="${1:-}" t="${2:-}" k="${3:-}" n slug
  case "$k" in RB-*) return 1 ;; esac
  case "$t" in
    ''|*[!0-9]*) n=$(printf '%s' "$k" | sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p') ;;
    *) n="$t" ;;
  esac
  [ -n "$n" ] || return 1
  slug=$(to_issue_repo "$p") || return 1
  to_hold_verdict "$slug" "$n"
}

# to_pr_identity <head-ref> — the ticket a build branch belongs to, child
# segments kept: ticket/bh-1486 and ticket/bh-1486-local and ticket/bh-1486-r2
# are all BH-1486, while ticket/bh-1510-0-local and ticket/bh-1510.0 are
# BH-1510-0 — a split child is its own ticket, never a duplicate of its parent.
# Only `ticket/…` refs: a train, a design or a mergify branch owns no ticket.
to_pr_identity() {
  local b="${1:-}" t
  case "$b" in ticket/*) ;; *) return 1 ;; esac
  t=$(printf '%s' "${b#ticket/}" | tr '[:lower:]' '[:upper:]')
  [[ "$t" =~ ^([A-Z][A-Z0-9]*-[0-9]+)(([.-][0-9]+)*)(-|$) ]] || return 1
  printf '%s%s' "${BASH_REMATCH[1]}" "$(printf '%s' "${BASH_REMATCH[2]}" | tr . -)"
}

# to_pr_issue <pr-json> — the issue a PR was built for: its body's closing
# keyword first (every harness PR carries `Closes #<n>`, which is also the only
# way to find a split child's own issue), else its first line-anchored
# `Refs #<n>` (a partial build says Refs, BH-5798), else the plain KEY in its
# head ref.
to_pr_issue() {
  local pj="${1:-}" n id
  n=$(printf '%s' "$pj" | jq -r '[(.body // "") | match("(?i)(?<![A-Za-z])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?[ \t]+#(?<n>[0-9]+)"; "g")
         | .captures[] | select(.name == "n") | .string] | first // empty' 2>/dev/null)
  [ -n "$n" ] || n=$(printf '%s' "$pj" | jq -r '[(.body // "") | match("(?i)(?:^|\n)[ \t#*_`]*refs[*_: \t]+#(?<n>[0-9]+)"; "g")
         | .captures[] | select(.name == "n") | .string] | first // empty' 2>/dev/null)
  if [ -z "$n" ]; then
    id=$(to_pr_identity "$(printf '%s' "$pj" | jq -r '.head.ref // ""' 2>/dev/null)") || return 1
    n=$(printf '%s' "$id" | sed -nE 's/^[A-Z][A-Z0-9]*-([0-9]+)$/\1/p')
  fi
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# to_lead_authors — the `lead_pr_authors` row, memoised in TO_LEAD_AUTHORS.
# to__lead_load fills the memo in THIS shell (never call it inside `$( )`, or
# every later question re-reads the row); a caller that already holds the row
# may set TO_LEAD_AUTHORS itself.
#
# TO_LEAD_RC (BH-1558) says whether the row was READ: 0 only when setting_get
# answered rc 0 with a non-blank list, 2 for everything else. setting_get's rc 0
# IS "the worker answered 2xx and the body carried .setting.value" (it parses
# that key and answers rc 2 when it is absent), so this is the genuine-worker-
# answer test without a second parser of the settings route. Its rc 2 is NOT
# "nobody is the lead" here (#1603 review F2): _jobs_req maps ANY 404 to it — a
# mistyped JOBS_URL host behind Cloudflare ("error code: 1042"), a proxy — and a
# 200 HTML page, a null row and an emptied row land there too. The row is
# seeded, so every one of those is "unknown" and the lead-PR merge fence holds
# on it. The other callers keep their "unreadable = nobody" reading (the list
# is empty either way). A caller that sets TO_LEAD_AUTHORS itself has read it.
to__lead_load() {
  if [ -n "${TO_LEAD_AUTHORS+x}" ]; then
    [ -n "${TO_LEAD_RC:-}" ] && return 0
    if [ -n "$TO_LEAD_AUTHORS" ]; then TO_LEAD_RC=0; else TO_LEAD_RC=2; fi
    return 0
  fi
  local v="" rc=1
  if command -v setting_get >/dev/null 2>&1; then
    v=$(setting_get lead_pr_authors 2>/dev/null); rc=$?
  elif [ -x "$(to__h)/bin/jobs-client.sh" ]; then
    v=$("$(to__h)/bin/jobs-client.sh" setting-get lead_pr_authors 2>/dev/null); rc=$?
  fi
  [ "$rc" = 0 ] || v=""
  # TRIMMED BEFORE ANYONE ASKS "IS IT EMPTY" (review round 1, I-1): a row of
  # " , " survived as whitespace, read as a lead list that matched nobody, and
  # the duplicate closer then closed the lead's own newer PR.
  TO_LEAD_AUTHORS=$(printf '%s' "$v" | tr ',\t\r\n' '    ' | sed -E 's/^ +//; s/ +$//; s/ +/ /g')
  if [ -n "$TO_LEAD_AUTHORS" ]; then TO_LEAD_RC=0; else TO_LEAD_RC=2; fi
}
to_lead_authors() { to__lead_load; printf '%s' "$TO_LEAD_AUTHORS"; }

# to_is_lead <login> — `app/x`, `x[bot]` and `x` are one actor spelled by two
# APIs (bin/lib/gh-pr-list.sh's _hpl_bare), so bare names are compared.
to_is_lead() {
  local want="${1#app/}" a
  want="${want%\[bot\]}"
  [ -n "$want" ] || return 1
  to__lead_load
  for a in $TO_LEAD_AUTHORS; do
    a="${a#app/}"; a="${a%\[bot\]}"
    [ "$a" = "$want" ] && return 0
  done
  return 1
}

# to_pr_thread_hold <owner/repo> <pr> — the PR's OWN thread, judged by
# bin/lib/hold.sh (hold_check_thread): stdout its verdict line; rc 0 held (a
# pause or an abandon), 1 clear, 2 unreadable. The same rc shape as
# to_hold_verdict, so the two read alike at the call site.
to_pr_thread_hold() {
  local v rc
  to__load_hold || { printf 'unreadable\tno hold library on this box\n'; return 2; }
  to__load_rest || { printf 'unreadable\tno REST contract lib on this box\n'; return 2; }
  command -v hold_check_thread >/dev/null 2>&1 || { printf 'unreadable\tthis box'"'"'s hold library cannot read a PR thread\n'; return 2; }
  v=$(hold_check_thread "${1:-}" "${2:-}"); rc=$?
  printf '%s\n' "$v"
  case "$rc" in 1) return 0 ;; 0) return 1 ;; esac
  return 2
}

to_merge_hold() {
  local p="${1:-}" slug="${2:-}" num="${3:-}" pj n v rc
  case " ${TO_LOSERS:-} " in
    *" $slug#$num "*)
      printf 'closed this tick as a duplicate: its ticket already has an open PR (one PR per ticket)\n'; return 0 ;;
  esac
  # The repo's own App token: the hub's default PAT 404s on some repos, and a
  # 404 here would hold every PR there for ever. Every caller runs this inside
  # `$( )`, so the armed token dies with the subshell.
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$slug"
  # A HOLD ON THE PR ITSELF, FIRST AND FOR EVERY PROJECT (BH-1668, review of
  # #1926 blocking 1). project-5 #3214 was held by a comment on the PR while its
  # ticket carried nothing, and this function read only the ticket. A board
  # project's PR has no GitHub ticket to read, but a HOLD on its PR binds it all
  # the same. It sits before the lead exemption too: the lead's own PR is exempt
  # from the TICKET hold (the ticket is reserved for it), never from a HOLD
  # somebody wrote on that PR. RESUME on the PR lifts it; unreadable holds.
  v=$(to_pr_thread_hold "$slug" "$num"); rc=$?
  case "$rc" in
    0) printf 'the PR itself is held (%s) — a HOLD on the PR does not merge; RESUME on the PR lifts it\n' "${v#*	}"; return 0 ;;
    2) printf 'the PR thread could not be read for a HOLD (%s) — not merged this pass, the next pass asks again\n' "${v#*	}"; return 0 ;;
  esac
  to_issue_repo "$p" >/dev/null || return 1
  local f prc=0
  f=$(mktemp "${TMPDIR:-/tmp}/to-pr.XXXXXX" 2>/dev/null) || f=""
  if [ -z "$f" ] || ! to__load_rest; then
    [ -n "$f" ] && rm -f "$f"
    printf 'the PR could not be read to find its ticket (no REST contract lib on this box) — not merged this pass\n'; return 0
  fi
  gh_rest GET "repos/$slug/pulls/$num" > "$f" 2>/dev/null || prc=$?
  pj=$(cat "$f" 2>/dev/null); rm -f "$f"
  if [ "$prc" != 0 ] || [ -z "$pj" ]; then
    printf 'the PR could not be read to find its ticket (HTTP %s) — not merged this pass, the next pass asks again\n' "${GH_REST_STATUS:-000}"; return 0
  fi
  to_is_lead "$(printf '%s' "$pj" | jq -r '.user.login // ""' 2>/dev/null)" && return 1
  n=$(to_pr_issue "$pj") || return 1
  v=$(to_hold_verdict "$slug" "$n"); rc=$?
  case "$rc" in
    0) printf 'ticket #%s is held (%s) — a held ticket'"'"'s PR does not merge; RESUME on the ticket lifts it\n' "$n" "${v#*	}"; return 0 ;;
    2) printf 'the hold on ticket #%s could not be read (%s) — not merged this pass, the next pass asks again\n' "$n" "${v#*	}"; return 0 ;;
  esac
  return 1
}

# ONE MERGE_HELD LINE PER (PR, HEAD, REASON), NOT PER TICK (#1603 review N). A
# held ticket or a lead PR waiting on its lead is re-asked every tick for as
# long as it stays open; the line that says why is news once. One file per
# (log, PR, kind) holding the last key written — bounded by the open PRs, and
# cleared when the lane passes the PR, so a hold that returns is written again.
# to__held_once <log|-> <slug> <num> <kind> <key> — rc 0 write it (recorded),
#   rc 1 the last line written for this (log, PR, kind) was this same key.
#
# THE FILE NAME SAYS WHOSE IT IS (BH-1606): <owner>%<repo>#<num>.<cksum of log
# and kind>. "Cleared when the lane passes the PR" never happens for a PR that
# CLOSES while held, so to_held_prune has to be able to tell which PR a file is
# about without reading it — the old bare cksum name could not.
to__held_dir() { printf '%s/state/ticket-ownership/held' "$(to__h)"; }
to__held_file() {
  local s="${2//\//%}"
  printf '%s/%s#%s.%s' "$(to__held_dir)" "$s" "$3" \
    "$(printf '%s|%s' "$1" "$4" | cksum | cut -d' ' -f1)"
}
to__held_once() {
  local f; f=$(to__held_file "$1" "$2" "$3" "$4")
  [ -r "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "${5:-}" ] && return 1
  mkdir -p "${f%/*}" 2>/dev/null && printf '%s' "${5:-}" > "$f" 2>/dev/null
  return 0
}
to__held_clear() { rm -f "$(to__held_file "$1" "$2" "$3" "$4")" 2>/dev/null; return 0; }

# to_held_prune <owner/repo> <open-pr-number>… — drop the dedupe files of this
# repo's PRs that are no longer open (BH-1606, #1603 round-2 review). A PR in
# the list keeps its files and costs nothing. A PR NOT in it is asked over REST
# once, because a lane's open list can be partial (a page limit, drafts left
# out): only an answer that says closed/merged removes its files, and an
# unreadable answer keeps them for the next pass. A pre-BH-1606 file (a bare
# cksum, nothing says whose) is removed; the worst that costs is one repeated
# MERGE_HELD line. Never fails its caller.
to_held_prune() {
  local slug="${1:-}" dir f b key num st open=" " n
  [ -n "$slug" ] || return 0
  shift
  for n in "$@"; do open="$open$n "; done
  dir=$(to__held_dir); [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    case "$b" in *'#'*) ;; *) rm -f "$f" 2>/dev/null; continue ;; esac
    key="${b%.*}"; [ "${key%#*}" = "${slug//\//%}" ] || continue
    num="${key##*#}"
    case "$open" in *" $num "*) continue ;; esac
    st=$(to__pr_state "$slug" "$num") || continue
    [ "$st" = open ] || rm -f "$f" 2>/dev/null
  done
  return 0
}

# to__pr_state <owner/repo> <pr> — prints open / closed off the PR's own REST
# answer; rc 1 when it could not be read (keep the file, ask next pass).
to__pr_state() {
  local f prc=0 st
  to__load_rest || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/to-state.XXXXXX" 2>/dev/null) || return 1
  gh_rest GET "repos/$1/pulls/$2" > "$f" 2>/dev/null || prc=$?
  st=$(jq -r '.state // ""' "$f" 2>/dev/null); rm -f "$f"
  [ "$prc" = 0 ] && [ -n "$st" ] || return 1
  printf '%s' "$st"
}

# to_lane_hold <project> <owner/repo> <pr> [log-file] — to_merge_hold plus its
# ONE log line (the lane's file, else to__say), so a lane's call site is one
# line: `command -v to_lane_hold … && to_lane_hold … && continue`.
to_lane_hold() {
  local why
  why=$(to_merge_hold "${1:-}" "${2:-}" "${3:-}") || { to__held_clear "${4:--}" "${2:-}" "${3:-}" ticket; return 1; }
  to__held_once "${4:--}" "${2:-}" "${3:-}" ticket "$why" || return 0
  if [ -n "${4:-}" ]; then
    printf '%s [%s] %s#%s MERGE_HELD: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${1:-}" "${2:-}" "${3:-}" "$why" >> "$4"
  else
    to__say "${2:-}#${3:-} MERGE_HELD: $why"
  fi
  return 0
}

# ── THE LEAD-PR MERGE FENCE (BH-1558) ───────────────────────────────────────
# A lead PR is exempt from the HOLD above, so the HOLD cannot stop a lane from
# merging the lead's own PR before the lead says so. On 2026-09-22 23:46Z
# bin/review-prs.sh approved and auto-merged lead PR #1547 at its pre-guard
# head while the lead's Mac review had asked for one more commit. The rule: a
# lead-authored PR merges ONLY on a lead/human MERGE or MERGE-WITH-NOTES verdict
# row standing on its exact live head (bin/lib/verdicts.sh, BH-1525), or by the
# lead directly. A box review's APPROVE is information, never a clearance.
#
# THE READER IS verdicts.sh's vd_standing, never a second one: it binds the row
# to the full head sha and answers rc 2 on anything it could not read.

# verdicts.sh beside this file first, then the harness copy. Idempotent.
to__load_verdicts() {
  command -v vd_standing >/dev/null 2>&1 && return 0
  local f
  for f in "$(dirname "${BASH_SOURCE[0]}")/verdicts.sh" "$(to__h)/bin/lib/verdicts.sh"; do
    # shellcheck source=bin/lib/verdicts.sh
    [ -r "$f" ] && { . "$f" 2>/dev/null; break; }
  done
  command -v vd_standing >/dev/null 2>&1
}

# to_pr_author_head <owner/repo> <pr> — sets TO_PR_LOGIN and TO_PR_HEAD from
# the PR, read over REST on the repo's own token; rc 1 when it could not be
# read. A plain command, never `$( )`, so GH_REST_STATUS survives for the reason.
# It ARMS the repo's token in the shell that runs it: a lane calls it inside
# `$( )` (bin/run-build.sh's tier-1 gate reads its one head that way).
# BH-1606: it also sets TO_PR_TITLE / TO_PR_REF (the merge-train question) and
# TO_PR_READ=<slug>#<num> once the read answered, so one read serves both.
to_pr_author_head() {
  local slug="$1" num="$2" f prc=0
  TO_PR_LOGIN=""; TO_PR_HEAD=""; TO_PR_TITLE=""; TO_PR_REF=""; TO_PR_READ=""
  to__load_rest || return 1
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$slug"
  f=$(mktemp "${TMPDIR:-/tmp}/to-lead.XXXXXX" 2>/dev/null) || return 1
  gh_rest GET "repos/$slug/pulls/$num" > "$f" 2>/dev/null || prc=$?
  TO_PR_LOGIN=$(jq -r '.user.login // ""' "$f" 2>/dev/null)
  TO_PR_HEAD=$(jq -r '.head.sha // ""' "$f" 2>/dev/null)
  TO_PR_TITLE=$(jq -r '.title // ""' "$f" 2>/dev/null)
  TO_PR_REF=$(jq -r '.head.ref // ""' "$f" 2>/dev/null); rm -f "$f"
  [ "$prc" = 0 ] && [ -n "$TO_PR_LOGIN" ] || return 1
  TO_PR_READ="$slug#$num"
}

# train-shape.sh beside this file first, then the harness copy. Idempotent.
to__load_train() {
  command -v train_is_train >/dev/null 2>&1 && return 0
  local f
  for f in "$(dirname "${BASH_SOURCE[0]}")/train-shape.sh" "$(to__h)/bin/lib/train-shape.sh"; do
    # shellcheck source=bin/lib/train-shape.sh
    [ -r "$f" ] && { . "$f" 2>/dev/null; break; }
  done
  command -v train_is_train >/dev/null 2>&1
}

# to_lead_merge_hold <owner/repo> <pr> [head] [author]
#   rc 0 do NOT merge: a lead PR with no lead/human MERGE standing on this head
#        (a risk-tier MERGE counts only with reviewer risk-tier:rules-text:<box>)
#   rc 1 merge as today: not a lead PR, or such a MERGE stands on this head
#   rc 2 do NOT merge this pass: the lead row, the PR or the verdicts table
#        could not be read — the next pass asks again (the gh-rest rc-75 rule)
#   Prints `<kind><TAB><reason>`: kind is held (rc 0), pr / lead-row / verdicts
#   (rc 2, which read failed), or cleared (rc 1, a lead PR whose MERGE stands —
#   a non-lead PR prints nothing). A held lead PR shaped like a merge train
#   carries the TO_TRAIN_MARK suffix (BH-1606) — never a clearance, only the
#   cue for to_lane_lead_hold's one alert. A missing author or head is read from the PR
#   itself, and then the head is the LIVE one. Pass the head the caller will PIN
#   its merge to (--match-head-commit): a verdict read on one head and a merge
#   of another is the race #1603's review F1 names.
#   Run it inside `$( )`: the PR read arms the repo's token for that subshell.
to_lead_merge_hold() {
  local slug="${1:-}" num="${2:-}" head="${3:-}" who="${4:-}" line rc v by
  if [ -z "$who" ]; then
    to_pr_author_head "$slug" "$num" || { printf 'pr\tthe PR could not be read to tell whether it is a lead PR (HTTP %s) — not merged this pass, the next pass asks again\n' "${GH_REST_STATUS:-000}"; return 2; }
    who="$TO_PR_LOGIN"; [ -n "$head" ] || head="$TO_PR_HEAD"
  fi
  to__lead_load
  if [ "${TO_LEAD_RC:-2}" != 0 ]; then
    printf 'lead-row\tthe lead_pr_authors settings row did not come back as a worker answer with a lead list, so whether this is a lead PR cannot be told — not merged this pass, the next pass asks again\n'; return 2
  fi
  to_is_lead "$who" || return 1
  [ -n "$head" ] || { to_pr_author_head "$slug" "$num" && head="$TO_PR_HEAD"; }
  to__load_verdicts || { printf 'verdicts\tlead PR by %s: no verdict reader on this box, so no lead verdict can be read — not merged\n' "$who"; return 2; }
  line=$(vd_standing "$slug" "$num" "$head"); rc=$?
  case "$rc" in
    1) printf 'held\tlead PR by %s: no lead/human verdict stands on head %s — a lead PR merges only on a lead MERGE row for its live head, never on a box review%s\n' "$who" "${head:0:12}" "$(to__train_mark "$slug" "$num")"; return 0 ;;
    0) ;;
    *) printf 'verdicts\tlead PR by %s: the verdicts table could not be read for head %s — not merged this pass, the next pass asks again\n' "$who" "${head:0:12}"; return 2 ;;
  esac
  v=$(cut -f1 <<<"$line"); by=""
  # BH-5022: a risk-tier row stands for every other lane, but it is a rules
  # sign-off with no reader behind it, so it never clears a lead-authored PR.
  # BH-5325: except a rules-text sign-off (reviewer risk-tier:rules-text:<box>,
  # field 6): a rules-only diff whose render check passed on the head.
  case "$(cut -f2 <<<"$line")" in
    lead|human) ;;
    risk-tier)
      case "$(cut -f6 <<<"$line")" in
        risk-tier:rules-text:*) by=" (risk-tier rules-text)" ;;
        *) printf 'held\tlead PR by %s: a risk-tier sign-off never clears a lead PR (head %s)%s\n' "$who" "${head:0:12}" "$(to__train_mark "$slug" "$num")"; return 0 ;;
      esac ;;
    *) printf 'held\tlead PR by %s: the standing verdict on head %s is not a lead/human row — not merged%s\n' "$who" "${head:0:12}" "$(to__train_mark "$slug" "$num")"; return 0 ;;
  esac
  case "$v" in MERGE|MERGE-WITH-NOTES) printf 'cleared\t%s on head %s%s\n' "$v" "${head:0:12}" "$by"; return 1 ;; esac
  printf 'held\tlead PR by %s: the standing lead verdict on head %s is %s — not merged%s\n' "$who" "${head:0:12}" "${v:-unknown}" "$(to__train_mark "$slug" "$num")"
  return 0
}

# A LEAD-AUTHORED PR SHAPED LIKE A TRAIN IS FENCED LIKE ANY LEAD PR (BH-1606,
# #1624 round-2 review B1, rule A). Round 2 exempted it by shape, and the shape
# is a title prefix OR a branch prefix anyone can type: a lead hand PR titled
# "Merge train…" or pushed to train/… auto-merged on a box APPROVE with no lead
# row, the #1547 hole again. So the shape is NEVER a clearance. It only makes
# the hold LOUD: a real train opened under the lead's login (39 of them on
# 2026-09-21/22) would otherwise sit held in silence with every member behind
# it, so to_lane_lead_hold raises one alert per (PR, head) saying how to clear
# it. Trains the harness opens itself are opened as the App (bin/batch-resolve.sh
# refuses otherwise), so they are not lead PRs and never reach this.
TO_TRAIN_MARK=' [lead-authored train: held like any lead PR — reopen it under the App identity, or post a lead MERGE row on this head]'
# to__train_mark <slug> <num> — prints TO_TRAIN_MARK when the PR looks like a
#   merge train (bin/lib/train-shape.sh, read off the PR), nothing otherwise —
#   including when the shape cannot be read or no recogniser is on this box.
to__train_mark() {
  to__load_train || return 0
  [ "${TO_PR_READ:-}" = "$1#$2" ] || to_pr_author_head "$1" "$2" || return 0
  train_is_train "$TO_PR_TITLE" "$TO_PR_REF" && printf '%s' "$TO_TRAIN_MARK"
  return 0
}

# to__train_alert <slug> <num> <head> <why> — ONE alert per (PR, head), shared by
#   every lane on this box (the dedupe file is keyed on no lane's log), never
#   fatal. A new head is a new alert; the same head on the next tick is not.
to__train_alert() {
  local slug="$1" num="$2" head="${3:-}" why="$4" key
  key="${head:-$why}"
  to__held_once - "$slug" "$num" train-alert "$key" || return 0
  [ -x "$(to__h)/bin/lane-alert.sh" ] || return 0
  "$(to__h)/bin/lane-alert.sh" --severity warn \
    --id "lead-authored-train:$slug#$num:${head:0:12}" ticket-ownership \
    "$slug#$num is a lead-authored PR shaped like a merge train and is HELD by every merge lane: $why" >/dev/null 2>&1 || true
  return 0
}

# to_lane_lead_hold <project> <owner/repo> <pr> <head> <author> [log-file] —
# to_lead_merge_hold plus its ONE log line (deduped per PR, head and reason), in
# to_lane_hold's shape. rc 0 held, rc 2 unreadable (both mean: do not merge this
# pass), rc 1 merge. Sets, in the caller's shell, TO_LEAD_KIND (the kind above)
# and TO_LEAD_CLEARED=1 when the PR is a lead PR cleared by a lead row — the
# caller must then keep a failed merge away from any lane with no lead fence.
to_lane_lead_hold() {
  local out rc why
  TO_LEAD_CLEARED=0
  out=$(to_lead_merge_hold "${2:-}" "${3:-}" "${4:-}" "${5:-}"); rc=$?
  TO_LEAD_KIND="${out%%$'\t'*}"; why="${out#*$'\t'}"
  if [ "$rc" = 1 ]; then
    [ "$TO_LEAD_KIND" = cleared ] && TO_LEAD_CLEARED=1
    to__held_clear "${6:--}" "${2:-}" "${3:-}" lead
    return 1
  fi
  # BH-1606 rule A: a held lead PR shaped like a train is held LOUDLY — one
  # alert per (PR, head), before the per-lane log dedupe can swallow it.
  if [ "$rc" = 0 ]; then
    case "$why" in *"$TO_TRAIN_MARK"*) to__train_alert "${2:-}" "${3:-}" "${4:-}" "$why" ;; esac
  fi
  to__held_once "${6:--}" "${2:-}" "${3:-}" lead "${4:-}|$out" || return "$rc"
  if [ -n "${6:-}" ]; then
    printf '%s [%s] %s#%s MERGE_HELD lead-pr: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${1:-}" "${2:-}" "${3:-}" "$why" >> "$6"
  else
    to__say "${2:-}#${3:-} MERGE_HELD lead-pr: $why"
  fi
  return "$rc"
}

# to_lane_lead_fence <project> <owner/repo> <pr> <head> <author> [log-file] —
# THE CALL EVERY MERGE LANE MAKES (BH-1606): to_lane_lead_hold, plus the outage
# signal. rc, TO_LEAD_KIND and TO_LEAD_CLEARED are to_lane_lead_hold's.
#
# AN UNREADABLE FENCE FEEDS THE BLOCK GATE'S STREAK (#1603 review F3), because a
# fence that stands ahead of the gate would otherwise swallow the one loud
# signal the lane had. The kind is the reason: `verdicts` and `lead-row` are one
# fact about this box and lane, not one per PR, so bg_streak_note raises ONE
# lane-wide alert per outage window for them (#1603 round 2); `pr` (this PR
# could not be read) stays per PR. A lead PR merely WAITING on its lead (rc 0)
# is not an outage and is silent. Callers ask it AHEAD of their block gate: a
# clean gate scan clears the streak, and on a lane that scanned first every
# tick of an outage would start the count again.
to_lane_lead_fence() {
  local rc
  to_lane_lead_hold "$@"; rc=$?
  [ "$rc" = 2 ] && command -v bg_streak_note >/dev/null 2>&1 \
    && bg_streak_note "${2:-}" "${3:-}" "${4:-}" 2 "${TO_LEAD_KIND:-unknown}"
  return "$rc"
}

# to__close_dup <slug> <loser> <winner> <identity> <why> — close, explain, record.
# The CLOSE goes first: a closed PR leaves the open list, so a comment that
# failed is one missing explanation, never the same comment on every tick.
to__close_dup() {
  local slug="$1" n="$2" w="$3" id="$4" why="$5" f crc=0
  if [ "${TO_DEDUPE_DRY:-0}" = 1 ]; then
    to__say "$slug#$n would be CLOSED as a duplicate of #$w for $id — $why (observe mode: nothing written)"
    return 0
  fi
  gh_rest_close "$slug" "$n" pulls >/dev/null 2>&1 || crc=$?
  if [ "$crc" != 0 ]; then
    to__say "$slug#$n duplicate of $id not closed: the close was refused (HTTP ${GH_REST_STATUS:-000}) — the next tick tries again"
    return 1
  fi
  TO_LOSERS="${TO_LOSERS:-} $slug#$n"
  f=$(mktemp "${TMPDIR:-/tmp}/to-dup.XXXXXX" 2>/dev/null) || f=""
  if [ -n "$f" ]; then
    printf 'Closing this one: ticket %s already has an open pull request, #%s, and a ticket gets one pull request. %s\n\nNothing here is lost. The branch is still there if anything in it is worth keeping.\n' \
      "$id" "$w" "$why" > "$f"
    crc=0
    gh_rest_comment "$slug" "$n" "$f" >/dev/null 2>&1 || crc=$?
    [ "$crc" = 0 ] || to__say "$slug#$n closed as a duplicate of #$w, but the explaining comment did not land (HTTP ${GH_REST_STATUS:-000})"
    rm -f "$f"
  fi
  command -v job_ledger_put >/dev/null 2>&1 \
    && job_ledger_put ticket_pr_owner "$slug#$id" closed-duplicate "closed #$n, kept #$w: $why" >/dev/null 2>&1
  # The conductor's closed-unmerged pass must not page "rebuild or close the
  # issue" about a PR this rule closed on purpose.
  command -v mc_transition >/dev/null 2>&1 \
    && mc_transition "$slug#$n" CLOSED "closed-duplicate of #$w ($id)" "-" "-" "https://github.com/$slug/pull/$n" "-" "-" "" >/dev/null 2>&1
  to__say "$slug#$n CLOSED as a duplicate of #$w for $id — $why"
  return 0
}

to_dedupe_open_prs() {
  local slug="${1:-}" f lrc=0 rows heads id prev="" line num ref base login created
  local -a group=()
  [ -n "$slug" ] || return 0
  to__lead_load
  if [ -z "$TO_LEAD_AUTHORS" ]; then
    to__say "$slug: one-PR-per-ticket check skipped — the lead_pr_authors settings row could not be read, and closing a PR needs to know whose it is"
    return 0
  fi
  to__load_rest || { to__say "$slug: one-PR-per-ticket check skipped — no REST contract lib on this box"; return 0; }
  f=$(mktemp "${TMPDIR:-/tmp}/to-open.XXXXXX" 2>/dev/null) || return 0
  # ONE page of 100: no fleet repo carries that many open PRs, and a list that
  # was cut short can only miss a pairing, never invent one.
  gh_rest_pr_list "$slug" open "" 100 > "$f" 2>/dev/null || lrc=$?
  if [ "$lrc" != 0 ]; then
    rm -f "$f"; to__say "$slug: one-PR-per-ticket check skipped — the open-PR list did not answer (HTTP ${GH_REST_STATUS:-000})"; return 0
  fi
  rows=$(jq -r '.[]? | select(type == "object")
          | [(.number | tostring), (.head.ref // ""), (.base.ref // ""), (.user.login // ""), (.created_at // "")] | @tsv' "$f" 2>/dev/null)
  rm -f "$f"
  heads=$(printf '%s\n' "$rows" | cut -f2)
  # identity, created, number, login — sorted so each ticket's PRs are adjacent
  # and oldest first inside the group. A STACKED PR (its base is another open
  # PR's head for the same ticket, review round 1) is one piece of that work,
  # never a duplicate of it, so it never enters the pairing.
  rows=$(while IFS=$'\t' read -r num ref base login created; do
           id=$(to_pr_identity "$ref") || continue
           if [ -n "$base" ] && grep -qxF -- "$base" <<<"$heads" \
              && [ "$(to_pr_identity "$base" 2>/dev/null)" = "$id" ]; then continue; fi
           printf '%s\t%s\t%010d\t%s\n' "$id" "$created" "$num" "$login"
         done <<<"$rows" | LC_ALL=C sort)
  while IFS= read -r line || [ -n "$prev" ]; do
    id="${line%%$'\t'*}"
    if [ -n "$prev" ] && [ "$id" != "$prev" ]; then
      to__dedupe_group "$slug" "$prev" "${group[@]}"
      group=()
    fi
    [ -n "$line" ] || break
    group+=("$line"); prev="$id"
  done <<<"$rows"
  return 0
}

# to__dedupe_group <slug> <identity> <row>… — one ticket's open PRs, oldest
# first. The winner is the oldest LEAD PR if there is one, else the oldest PR.
# A lead PR is never closed by this rule, whatever its age.
to__dedupe_group() {
  local slug="$1" id="$2" r num login winner="" wlead=0 why
  shift 2
  [ "$#" -gt 1 ] || return 0
  for r in "$@"; do
    IFS=$'\t' read -r _ _ num login <<<"$r"
    if to_is_lead "$login"; then winner=$((10#$num)); wlead=1; break; fi
  done
  if [ -z "$winner" ]; then IFS=$'\t' read -r _ _ num _ <<<"$1"; winner=$((10#$num)); fi
  for r in "$@"; do
    IFS=$'\t' read -r _ _ num login <<<"$r"
    num=$((10#$num))
    [ "$num" = "$winner" ] && continue
    to_is_lead "$login" && continue
    if [ "$wlead" = 1 ]; then why="#$winner is the lead's build, and a lead pull request wins over a pool one whichever opened first."
    else why="#$winner opened first, so it stays and the newer one closes."; fi
    to__close_dup "$slug" "$num" "$winner" "$id" "$why"
  done
  return 0
}
