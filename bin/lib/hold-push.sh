#!/bin/bash
# bin/lib/hold-push.sh — THE ONE WAY A LANE PUSHES TO A PR BRANCH (BH-2504).
# Sourced, never executed: no `set -e`, no `exit`, no output at source time.
#
# WHY IT EXISTS (2026-09-25). A lead put six tickets on HOLD to fix their PRs by
# hand, and six lanes pushed onto those branches anyway:
#   - bin/blocked-resolver.sh's fix round on #2481, 29 s after the HOLD (it read
#     the hold when its run started and never again), and on #2476 18 minutes
#     after it (the `review-changes-requested` rung never read the ticket);
#   - main-merge pushes on #2493, #2552 and #2586;
#   - a rebuild push on #2592, and a harness push on #2593.
# Every one of them had a lead fix agent working the same branch. That is two
# writers on one branch (#2182), and the lead lost the race each time.
#
# THE RULE, which tests/hold-push-ratchet.bh-2504-test.sh keeps true: a lane
# that writes a PR branch pushes through hold_push, and hold_push
#   1. reads the TICKET's hold (bin/lib/hold.sh: the line-anchored HOLD/RESUME
#      thread, the title, the body, and the `hold` label) IMMEDIATELY before
#      the push, never from a read taken when the round started;
#   2. pushes with `--force-with-lease=<branch>:<the sha the round started
#      from>`, so a lead commit that landed mid-round makes git refuse the push
#      instead of the lane overwriting it. There is no plain `-f` here at all.
# A refusal writes ONE line and pushes nothing; the caller throws its local
# round away, which every caller already does on a failed push.
#
# WHICH TICKET. The ticket a PR branch belongs to is a GitHub ISSUE only on the
# issues lanes (fleet.conf board_prefix "-"). On an in-app board the ticket
# lives on the board and there is no issue to read (fly-pool's 2026-09-21
# lesson: reading one froze every board project's pool), so the lease is the
# whole guard there. The caller names the issue when it knows it; otherwise it
# comes from the branch (`ticket/bh-2406-r2` -> 2406), the same parse
# mc_ticket_of_branch uses.
#
# UNREADABLE IS NOT CLEAR. A hold read that failed says nothing about whether a
# person just typed HOLD, so it pushes nothing (rc 4) and the lane retries on
# its next tick — the answer hold.sh gives everywhere else.
#
# NEVER REWRITE A PARENT UNDER ITS CHILDREN (BH-5234). #5010 was force-pushed
# while #5053 was stacked on it, and #5053 then carried the parent's OLD commits
# beside the landed ones. So a REWRITE push (the lease is not an ancestor of
# what is pushed) to a branch that open PRs are based on is refused (rc 5, one
# line naming them): merge instead, or let the conductor restack them. Only a
# rewrite reads the children (bin/lib/stale-parent.sh sp_open_children), and an
# unreadable list refuses it too (rc 4). mc_restack, the one sanctioned rewriter
# of a parent, passes HOLD_PUSH_CHILDREN=follow because it follows them itself.
# HOLD_PUSH_REWRITE_GUARD=0 (catalog/lanes.d/_lib.stale-parent.json) is the
# pre-BH-5234 push. No stale-parent lib beside this file: the guard is skipped,
# said once per process.
#
# NEVER RE-HEAD A QUEUED PR (BH-10201). #10134 was queued by a person at
# 21:28Z on 2026-11-25; build 50666 rebased and pushed its branch at 23:10Z,
# Mergify dequeued it (the head moved), and it stayed out for 9.5 hours. So a
# push to a branch whose open PR carries Mergify's `queued` or `checking` label
# is refused (rc 6, one line naming the PR): dequeue it first, then push, as
# mc_rebase already does (BH-8021). ONE read of `pulls?head=<owner>:<branch>`
# per push; a `new` lease reads nothing. A read that FAILS does not refuse the
# push (one line per process says the guard did not run): a push to a queued PR
# costs one dequeue, which the conductor puts on record and tells one person
# about (bin/merge-conductor.d/bh-10201-queue-return.sh), and an unread label
# must not throw away a lane's whole round.
# HOLD_PUSH_QUEUE_GUARD=0 (catalog/lanes.d/_lib.stale-parent.knobs.d/) is the
# pre-BH-10201 push.
#
#   hold_push [-n] [-u] <project> <ticket> <worktree> <remote> <src-ref> <branch> <lease>
#     -n        run git with `-c credential.helper=` (the token is in <remote>)
#     -u        set the upstream (`push -u`)
#     <ticket>  `owner/repo#N` (the issue, named), `N` (an issue of the
#               project's repo), `-` (derive it from <branch> on an issues
#               lane), or `none` (the caller knows it is a board ticket)
#     <lease>   the sha the round started from, or `new` for a branch that
#               must not exist on the remote yet. An empty lease is a usage
#               error, never "no lease".
#   rc 0 pushed · 1 git refused (the lease, or anything else git said no to)
#      3 HELD · 4 the hold, or a rewritten branch's children, could not be read
#      5 rewrite refused: the branch has open stacked children
#      6 refused: the branch's open PR is in the merge queue · 64 usage
#   Nothing on stdout (mc_rebase prints its new sha there). The one refusal
#   line goes to stderr and, when set, is appended to $HOLD_PUSH_LOG.

hold_push__dir() { cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd; }

hold_push__say() {
  local line
  line="$(date -u '+%Y-%m-%d %H:%M:%SZ') [hold-push] $*"   # determinism: ok a log line's own timestamp
  printf '%s\n' "$line" >&2
  [ -n "${HOLD_PUSH_LOG:-}" ] && printf '%s\n' "$line" >> "$HOLD_PUSH_LOG" 2>/dev/null
  return 0
}

# hold.sh beside this file, loaded once. Absent means the push cannot be
# checked, and an unchecked push is the incident this file exists to stop.
hold_push__load() {
  command -v hold_check >/dev/null 2>&1 && command -v hold_is_pause >/dev/null 2>&1 && return 0
  local d; d=$(hold_push__dir)
  # shellcheck source=bin/lib/hold.sh
  [ -r "$d/hold.sh" ] && . "$d/hold.sh" 2>/dev/null
  command -v hold_check >/dev/null 2>&1 && command -v hold_is_pause >/dev/null 2>&1
}

# hold__read_gh <out> <owner/repo> <n> — hold_read's GitHub read (BH-10199
# moved it here, unchanged): the issue, then its comment pages, 100 at a time
# up to 1000. <out> gets {"issue": {...}, "comments": [...]}. rc 0; 75 a read
# failed or the issue has no state (hold_read then asks hold_check); 3 more
# than 1000 comments; 4 the pages did not parse. irr_read calls it as its
# github-fn, so its GitHub calls are the same in every step.
hold__read_gh() {
  local out="${1:-}" slug="${2:-}" n="${3:-}" t ij acc='[]' page len rc
  [ -n "$out" ] || return 75
  : > "$out"
  t=$(mktemp "${TMPDIR:-/tmp}/hold-read-gh.XXXXXX" 2>/dev/null) || return 75
  rc=0; gh_rest GET "repos/$slug/issues/$n" > "$t" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "object" and has("state")' "$t" >/dev/null 2>&1; then
    rm -f "$t"; return 75
  fi
  ij=$(cat "$t")
  for page in 1 2 3 4 5 6 7 8 9 10; do
    rc=0; gh_rest GET "repos/$slug/issues/$n/comments?per_page=100&page=$page" > "$t" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$t" >/dev/null 2>&1; then
      rm -f "$t"; return 75
    fi
    acc=$(jq -sc '.[0] + .[1]' <(printf '%s\n' "$acc") "$t" 2>/dev/null) || { rm -f "$t"; return 4; }
    len=$(jq 'length' "$t")
    [ "$len" -lt 100 ] && break
    [ "$page" = 10 ] && { rm -f "$t"; return 3; }
  done
  rm -f "$t"
  { printf '%s\n' "$ij"; printf '%s\n' "$acc"; } | jq -sc '{issue: .[0], comments: .[1]}' > "$out" 2>/dev/null || return 4
  return 0
}

# hold_read <owner/repo> <n> — hold_check's answer (stdout line, rc 0/1/2),
# read through the REST contract (bin/lib/gh-rest.sh) when the lane has loaded
# it: the caller's armed token and ETag-revalidated. When that read fails, or the
# lane has no gh_rest at all (the pool's run-build, the lander), hold_check reads
# it exactly as before. Either way the verdict is hold_classify's, so there is
# one reading of what a hold is.
hold_read() {
  local slug="${1:-}" n="${2:-}" t ij acc='[]' rc
  hold_push__load || { printf 'unreadable\tbin/lib/hold.sh is not beside bin/lib/hold-push.sh\n'; return 2; }
  if ! command -v gh_rest >/dev/null 2>&1 || ! command -v hold_classify >/dev/null 2>&1; then
    hold_check "$slug" "$n"; return $?
  fi
  t=$(mktemp "${TMPDIR:-/tmp}/hold-read.XXXXXX" 2>/dev/null) || { printf 'unreadable\tno temp file\n'; return 2; }
  # BH-10199: a lane that set IRR_LANE reads the thread through the issue
  # record (bin/lib/issue-record.sh irr_read, its step GH_SOURCE_ISSUES); any
  # other caller reads GitHub exactly as before (hold__read_gh).
  rc=0
  if [ -n "${IRR_LANE:-}" ] && command -v irr_read >/dev/null 2>&1; then
    irr_read thread hold__read_gh "$slug" "$n" "$t" || rc=$?
  else
    hold__read_gh "$t" "$slug" "$n" || rc=$?
  fi
  case "$rc" in
    0) ij=$(jq -c '.issue' "$t" 2>/dev/null); acc=$(jq -c '.comments' "$t" 2>/dev/null) ;;
    3) rm -f "$t"; printf 'unreadable\t%s#%s has more than 1000 comments\n' "$slug" "$n"; return 2 ;;
    4) rm -f "$t"; printf 'unreadable\tthe thread of %s#%s did not parse\n' "$slug" "$n"; return 2 ;;
    # The contract could not answer (an outage, its quota reserve, a cache
    # miss). hold_check is the older reader of the same thing, and its answer
    # carries gh's own words when it cannot read either — so it gets the last say.
    *) rm -f "$t"; hold_check "$slug" "$n"; return $? ;;
  esac
  rm -f "$t"
  local v vrc
  v=$(hold_classify "$ij" "$acc"); vrc=$?
  printf '%s\n' "$v"
  # The ambiguity note (BH-3435), as hold_check does: verdict and rc unchanged.
  case "$v" in "held	hold:comment"*|"held	hold:title"*|"held	hold:body"*)
    hold_ambiguous_note "$slug" "$n" "$ij" "$acc" >/dev/null 2>&1 </dev/null ;;
  esac
  return "$vrc"
}

# hold_push_ticket <project> <branch> — the GitHub issue number the branch's
# ticket is, on an issues lane; rc 1 (nothing printed) on a board project, an
# unknown project, or a branch that names no ticket.
hold_push_ticket() {
  local p="${1:-}" b="${2:-}" conf t
  [ -n "$p" ] && [ "$p" != - ] && [ -n "$b" ] || return 1
  conf="$(hold_push__dir)/../fleet-conf.sh"
  [ "$(bash "$conf" "$p" board_prefix 2>/dev/null)" = "-" ] || return 1
  t=$(tr '[:lower:]' '[:upper:]' <<<"${b##*/}")
  [[ "$t" =~ ^[A-Z][A-Z0-9]*-([0-9]+) ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# hold_push_verdict <project> <ticket|-> <branch> — is this branch's ticket held
# right now? stdout "<held|clear|unreadable>\t<why>"; rc 0 clear, 1 held,
# 2 unreadable. Only an instruction holds (a pause or an ABANDON): `closed` and
# `label-absent` are facts about the issue, and a push to an open PR whose issue
# was de-labelled is none of this guard's business.
hold_push_verdict() {
  local p="${1:-}" n="${2:-}" b="${3:-}" slug="" v
  case "$n" in
    none) printf 'clear\tno GitHub issue behind %s (the caller says its ticket lives on a board)\n' "${b:-the branch}"; return 0 ;;
    */*"#"*) slug="${n%#*}"; n="${n##*#}" ;;
    ''|-) n=$(hold_push_ticket "$p" "$b") || n="" ;;
  esac
  case "$n" in
    ''|*[!0-9]*) printf 'clear\tno GitHub issue behind %s (a board ticket, or no ticket in the branch name)\n' "${b:-the branch}"; return 0 ;;
  esac
  [ -n "$slug" ] || slug=$(bash "$(hold_push__dir)/../fleet-conf.sh" "$p" repo 2>/dev/null)
  case "$slug" in */*) ;; *) printf 'unreadable\tno repo for project %s in fleet.conf\n' "${p:--}"; return 2 ;; esac
  # Loaded HERE, not inside the read: the read runs in a subshell (hold_check
  # arms the repo's App token, and that must not outlive it — hold.sh: the
  # caller owns the reset), and hold_is_pause below needs the functions too.
  hold_push__load || { printf 'unreadable\tbin/lib/hold.sh is not beside bin/lib/hold-push.sh\n'; return 2; }
  v=$(hold_read "$slug" "$n" 2>/dev/null)
  case "$v" in
    unreadable*|'') printf '%s\n' "${v:-unreadable	the hold check printed nothing} ($slug#$n)"; return 2 ;;
  esac
  if hold_is_pause "$v" || hold_is_abandon "$v"; then printf '%s (%s#%s)\n' "$v" "$slug" "$n"; return 1; fi
  printf 'clear\t%s (%s#%s)\n' "${v#*	}" "$slug" "$n"
  return 0
}

# hold_push_rewrite_guard <project> <wt> <remote> <src> <branch> <lease> —
# rc 0 the push may go; 4 a rewrite whose children could not be read; 5 a
# rewrite of a branch with open children. The lease is already validated ('' =
# a new branch, never a rewrite).
hold_push_rewrite_guard() {
  local p="$1" wt="$2" remote="$3" src="$4" br="$5" lease="$6" slug kids rc=0
  [ -n "$lease" ] || return 0
  if git -C "$wt" cat-file -e "$lease^{commit}" 2>/dev/null \
     && git -C "$wt" merge-base --is-ancestor "$lease" "$src" 2>/dev/null; then
    return 0
  fi
  [ "${HOLD_PUSH_CHILDREN:-}" = follow ] && return 0
  if ! command -v sp_open_children >/dev/null 2>&1; then
    local d; d=$(hold_push__dir)
    # shellcheck source=bin/lib/stale-parent.sh
    [ -r "$d/stale-parent.sh" ] && . "$d/stale-parent.sh" 2>/dev/null
  fi
  if ! command -v sp_open_children >/dev/null 2>&1; then
    [ -n "${_HOLD_PUSH_NO_SP_SAID:-}" ] || hold_push__say "bin/lib/stale-parent.sh is not beside bin/lib/hold-push.sh — rewrite pushes are not checked for open stacked children (BH-5234)"
    _HOLD_PUSH_NO_SP_SAID=1
    return 0
  fi
  [ "$(sp_knob HOLD_PUSH_REWRITE_GUARD "$p")" = 0 ] && return 0
  slug=$(bash "$(hold_push__dir)/../fleet-conf.sh" "$p" repo 2>/dev/null)
  case "$slug" in
    */*) ;;
    *) slug=$(git -C "$wt" remote get-url "$remote" 2>/dev/null || printf '%s' "$remote")
       slug=$(sed -nE 's#^(https://([^@/]*@)?github\.com/|git@github\.com:)([^/]+/[^/]+)$#\3#p' <<<"$slug"); slug="${slug%.git}" ;;
  esac
  kids=$(sp_open_children "$slug" "$br") || rc=$?
  if [ "$rc" != 0 ]; then
    hold_push__say "NOT rewriting $br: its open stacked children could not be read (${kids:-no reason given}); retried next tick"
    return 4
  fi
  [ -n "$kids" ] || return 0
  hold_push__say "NOT rewriting $br: open stacked children $(printf '#%s ' $kids | sed 's/ $//') would keep its old commits (BH-5234) — merge instead, or let the conductor restack them"
  return 5
}

# hold_push_queue_guard <project> <wt> <remote> <branch> <lease> — rc 0 the
# push may go; 6 the branch's open PR carries `queued` or `checking` (BH-10201).
# The lease is already validated ('' = a new branch, which has no PR). The knob
# is the settings row lib.stale-parent.hold_push_queue_guard through sp_knob,
# else the env var; the code fallback is 1 (on).
hold_push_queue_guard() {
  local p="$1" wt="$2" remote="$3" br="$4" lease="$5" d slug enc q t rc=0 hit knob
  [ -n "$lease" ] || return 0
  d=$(hold_push__dir)
  if ! command -v sp_knob >/dev/null 2>&1; then
    # shellcheck source=bin/lib/stale-parent.sh
    [ -r "$d/stale-parent.sh" ] && . "$d/stale-parent.sh" 2>/dev/null
  fi
  if command -v sp_knob >/dev/null 2>&1; then knob=$(sp_knob HOLD_PUSH_QUEUE_GUARD "$p")
  else knob="${HOLD_PUSH_QUEUE_GUARD:-}"; fi
  [ "$knob" = 0 ] && return 0
  slug=$(bash "$d/../fleet-conf.sh" "$p" repo 2>/dev/null)
  case "$slug" in
    */*) ;;
    *) slug=$(git -C "$wt" remote get-url "$remote" 2>/dev/null || printf '%s' "$remote")
       slug=$(sed -nE 's#^(https://([^@/]*@)?github\.com/|git@github\.com:)([^/]+/[^/]+)$#\3#p' <<<"$slug"); slug="${slug%.git}" ;;
  esac
  # No GitHub repo behind the remote (a local path): there is no PR to read.
  case "$slug" in */*) ;; *) return 0 ;; esac
  enc=$(jq -rn --arg r "$br" '$r|@uri' 2>/dev/null)
  t=$(mktemp "${TMPDIR:-/tmp}/hold-push-queue.XXXXXX" 2>/dev/null) || t=""
  [ -n "$enc" ] && [ -n "$t" ] || rc=64
  if [ "$rc" = 0 ]; then
    q="repos/$slug/pulls?head=${slug%%/*}:$enc&state=open&per_page=10"
    if command -v gh_rest >/dev/null 2>&1; then
      gh_rest GET "$q" > "$t" 2>/dev/null || rc=$?
    elif [ -r "$d/gh-rest.sh" ]; then
      # shellcheck source=bin/lib/gh-rest.sh
      ( . "$d/gh-rest.sh" 2>/dev/null && gh_rest GET "$q" ) > "$t" 2>/dev/null || rc=$?
    else
      rc=127
    fi
  fi
  if [ "$rc" = 0 ] && ! jq -e 'type == "array"' "$t" >/dev/null 2>&1; then rc=65; fi
  if [ "$rc" != 0 ]; then
    [ -n "$t" ] && rm -f "$t"
    [ -n "${_HOLD_PUSH_NO_QUEUE_SAID:-}" ] || hold_push__say "the queue guard did not run for $br: its open PR could not be read (rc $rc) — pushed without the merge-queue check (BH-10201)"
    _HOLD_PUSH_NO_QUEUE_SAID=1
    return 0
  fi
  hit=$(jq -r '[.[] | select([.labels[]?.name] | any(. == "queued" or . == "checking")) | .number] | first // empty' "$t" 2>/dev/null)
  rm -f "$t"
  [ -n "$hit" ] || return 0
  hold_push__say "QUEUED — NOT pushing $br: its open PR #$hit is in the merge queue (label queued/checking), and a push would take it out (BH-10201) — dequeue it first, then push; the local round is discarded"
  return 6
}

hold_push() {
  local cfg=() up=() p n wt remote src br lease v rc
  while [ $# -gt 0 ]; do
    case "$1" in
      -n) cfg=(-c credential.helper=); shift ;;
      -u) up=(-u); shift ;;
      *) break ;;
    esac
  done
  [ $# -eq 7 ] || { hold_push__say "usage: hold_push [-n] [-u] <project> <ticket|-> <wt> <remote> <src> <branch> <lease>"; return 64; }
  p="$1"; n="$2"; wt="$3"; remote="$4"; src="$5"; br="${6#refs/heads/}"; lease="$7"
  case "$br" in ''|main|master|HEAD) hold_push__say "refused: '$br' is not a PR branch"; return 64 ;; esac
  case "$lease" in
    new) lease="" ;;
    *[!0-9a-f]*|'') hold_push__say "refused: push to $br with lease '${lease}' — a sha or 'new' is required"; return 64 ;;
  esac
  v=$(hold_push_verdict "$p" "$n" "$br"); rc=$?
  case "$rc" in
    1) hold_push__say "HOLD — NOT pushing $br: the ticket says ${v#*	}; the local round is discarded"; return 3 ;;
    2) hold_push__say "NOT pushing $br: the ticket's hold could not be read (${v#*	}); retried next tick"; return 4 ;;
  esac
  hold_push_rewrite_guard "$p" "$wt" "$remote" "$src" "$br" "$lease" || return $?
  hold_push_queue_guard "$p" "$wt" "$remote" "$br" "$lease" || return $?
  # HARNESS_LANE is dropped for this one git (BH-2741): a codex lane's PATH
  # shim and pre-push hook judge every push in the session's process tree, and
  # bin/iron-law-guard.sh refuses any push from a guarded lane (rule
  # agent-push). This push is the sanctioned one, and its hold was read just above.
  # A subshell `unset`, not `env -u`: `env` would exec the git binary and skip a
  # caller's `git` function.
  if ( unset HARNESS_LANE
       git -C "$wt" ${cfg[@]+"${cfg[@]}"} push -q ${up[@]+"${up[@]}"} \
         "--force-with-lease=$br:$lease" "$remote" "$src:refs/heads/$br" ); then
    return 0
  fi
  hold_push__say "git refused the push to $br (lease ${lease:-new}: the branch moved since the round started, or git said no) — nothing overwritten"
  return 1
}
