#!/bin/bash
# gh-identity: raw-by-design — sourced by bin/lib/rb/pr.sh inside bin/run-build.sh, whose gates stage has ALREADY armed the repo identity (gh_default_auth_for_project); its one raw read (the open-PR check for the branch) belongs to that build, and a second mint here would override that choice.
# bin/lib/ticket-branch-resume.sh — A BUILD THAT FINDS ITS OWN TICKET BRANCH ON
# ORIGIN RESUMES IT INSTEAD OF BEING REFUSED (BH-7946).
# Sourced, never executed: no `set -e`, no `exit`, nothing runs at source time.
#
# WHY IT EXISTS. A pool build cuts ticket/<key> when the name is free on the
# remote (bin/lib/rb/gates.sh, the TAKEN check at the branch cut). That check
# runs once. When another writer creates the same name while the build runs,
# the PR push leases on "new" and the remote refuses it. The reap then writes a
# push-rejected terminal, and the stranded-ticket watch held the ticket for a
# human. BH-7519 (PR #7852): the pool started at 14:59Z, a Mac session created
# ticket/bh-7519 at 15:40Z, and the finished build was refused. TK-1556 is the
# same failure on project-6.
#
# THE RULE. Before the PR push, bin/lib/rb/pr.sh asks tbr_classify what the
# remote branch is. Only `own` (every commit names this ticket, no open PR)
# moves the build onto that branch, through tbr_resume; the PR stage then
# merges the base into it, verifies, and sends a fast-forward. Every other
# verdict keeps the refusal it had before. This file writes LOCAL refs only:
# it never sends anything to the remote, and it never removes a ref.
#
#   tbr_commit_own <key> <sha>
#     rc 0 the commit is this ticket's: its message names <key> as a whole key
#          (not a longer key, not a `.N` child key), or it touches a path under
#          .harness/specs/<key>/; rc 1 it is not; rc 2 a merge commit (skipped,
#          neither own nor foreign); rc 64 usage.
#   tbr_classify <branch> <key> <base-ref> <slug>
#     prints ONE line "<verdict>\t<remote-sha>\t<detail>", rc 0. The verdicts,
#     in the order they are checked:
#       tracked          refs/remotes/origin/<branch> is set: no read at all
#       unreadable       ls-remote failed / dirty-tree / fetch / pr-read /
#                        no-merge-base (the detail says which)
#       absent           the name is not on the remote
#       open-pr          an open PR has that head (the dispatcher's path)
#       ancestor         the remote head is already in HEAD
#       ancestor-of-base the remote holds nothing past <base-ref>
#       own              every non-merge commit past <base-ref> is this
#                        ticket's (detail commits=<n>)
#       foreign          one is not (detail "first=<sha> by <author>")
#   tbr_resume <branch> <remote-sha> <key>
#     keeps HEAD at refs/harness/superseded/<key>, checks <branch> out at
#     <remote-sha>, and sets refs/remotes/origin/<branch> to it so the lease is
#     that sha. Prints the superseded sha, rc 0. Any failed step puts the branch
#     back on the old head and returns rc 1.

tbr__say() { printf 'ticket-branch-resume: %s\n' "$*" >&2; return 0; }

# tbr__key_ok <key> — a ticket key: PREFIX-123 or a child PREFIX-123.4.
tbr__key_ok() { [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+(\.[0-9]+)*$ ]]; }

tbr_commit_own() {
  local key="${1:-}" sha="${2:-}" k msg n re paths
  tbr__key_ok "$key" && [ -n "$sha" ] || { tbr__say "usage: tbr_commit_own <key> <sha>"; return 64; }
  n=$(git rev-list --parents -n 1 "$sha" 2>/dev/null | wc -w) || return 1
  [ "$n" -ge 3 ] && return 2
  k=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  k=${k//./\\.}
  msg=$(git log -1 --format=%B "$sha" 2>/dev/null | tr '[:upper:]' '[:lower:]') || return 1
  # Word-bounded on the left; on the right not a digit, and a dot only when no
  # digit follows it — so BH-7946 matches "BH-7946: x" and "BH-7946." but
  # never BH-79460 or the child key BH-7946.2.
  re="(^|[^a-z0-9])${k}([^0-9.]|\.([^0-9]|$)|$)"
  [[ "$msg" =~ $re ]] && return 0
  paths=$(git diff-tree --root --no-commit-id --name-only -r "$sha" 2>/dev/null) || return 1
  grep -qF ".harness/specs/$key/" <<<"$paths" && return 0
  return 1
}

# tbr__author <sha> — the author name cut to 40 chars of [A-Za-z0-9._@ -].
tbr__author() {
  git log -1 --format=%an "$1" 2>/dev/null | tr -cd 'A-Za-z0-9._@ -' | cut -c1-40
}

tbr_classify() {
  local br="${1:-}" key="${2:-}" base="${3:-}" slug="${4:-}" t ls rsha n mb c own=0 first=""
  if [ -z "$br" ] || ! tbr__key_ok "$key" || [ -z "$base" ]; then
    tbr__say "usage: tbr_classify <branch> <key> <base-ref> <slug>"; return 64
  fi
  if t=$(git rev-parse -q --verify "refs/remotes/origin/$br" 2>/dev/null); then
    printf 'tracked\t%s\t\n' "$t"; return 0
  fi
  if ! ls=$(git ls-remote origin "refs/heads/$br" 2>/dev/null); then
    printf 'unreadable\t\tls-remote\n'; return 0
  fi
  [ -n "$ls" ] || { printf 'absent\t\t\n'; return 0; }
  rsha=${ls%%[[:space:]]*}
  if ! git diff --quiet HEAD 2>/dev/null; then
    printf 'unreadable\t%s\tdirty-tree\n' "$rsha"; return 0
  fi
  # A PRIVATE ref, not refs/remotes/...: a verdict that does not resume must
  # leave the lease at "new". The base is fetched too, so commits a writer took
  # from a newer base do not read as that writer's own work.
  if ! git fetch -q origin "+refs/heads/$br:refs/harness/tbr/$br" 2>/dev/null; then
    printf 'unreadable\t%s\tfetch\n' "$rsha"; return 0
  fi
  case "$base" in
    origin/*) git fetch -q origin "+refs/heads/${base#origin/}:refs/remotes/$base" 2>/dev/null \
                || { printf 'unreadable\t%s\tfetch-base\n' "$rsha"; return 0; } ;;
  esac
  rsha=$(git rev-parse -q --verify "refs/harness/tbr/$br^{commit}" 2>/dev/null) \
    || { printf 'unreadable\t\tfetch\n'; return 0; }
  # REST only (tests/gh-graphql-reads-lint.bh-1585-test.sh).
  n=""
  [ -n "$slug" ] && n=$(gh api "repos/$slug/pulls?head=${slug%%/*}:$br&state=open&per_page=1" --jq length 2>/dev/null)
  case "$n" in
    ''|*[!0-9]*) printf 'unreadable\t%s\tpr-read\n' "$rsha"; return 0 ;;
  esac
  [ "$n" -gt 0 ] && { printf 'open-pr\t%s\t\n' "$rsha"; return 0; }
  if git merge-base --is-ancestor "$rsha" HEAD 2>/dev/null; then
    printf 'ancestor\t%s\t\n' "$rsha"; return 0
  fi
  mb=$(git merge-base "$rsha" "$base" 2>/dev/null)
  if [ -z "$mb" ] && [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    timeout "${CHECKPOINT_UNSHALLOW_SECS:-900}" git fetch -q --unshallow origin 2>/dev/null \
      && mb=$(git merge-base "$rsha" "$base" 2>/dev/null)
  fi
  [ -n "$mb" ] || { printf 'unreadable\t%s\tno-merge-base\n' "$rsha"; return 0; }
  c=0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    c=$((c + 1))
    if tbr_commit_own "$key" "$t"; then
      own=$((own + 1))
    elif [ -z "$first" ]; then
      first="first=$t by $(tbr__author "$t")"
    fi
  done < <(git rev-list --reverse --no-merges "$base..$rsha" 2>/dev/null)
  [ "$c" = 0 ] && { printf 'ancestor-of-base\t%s\t\n' "$rsha"; return 0; }
  [ -z "$first" ] && [ "$own" = "$c" ] && { printf 'own\t%s\tcommits=%s\n' "$rsha" "$c"; return 0; }
  printf 'foreign\t%s\t%s\n' "$rsha" "${first:-first=unknown}"
  return 0
}

tbr_resume() {
  local br="${1:-}" rsha="${2:-}" key="${3:-}" old
  if [ -z "$br" ] || ! [[ "$rsha" =~ ^[0-9a-f]{40}$ ]] || ! tbr__key_ok "$key"; then
    tbr__say "usage: tbr_resume <branch> <remote-sha> <key>"; return 1
  fi
  old=$(git rev-parse -q --verify HEAD 2>/dev/null) || return 1
  git update-ref "refs/harness/superseded/$key" "$old" || return 1
  if git checkout -q -B "$br" "$rsha" 2>/dev/null \
     && git update-ref "refs/remotes/origin/$br" "$rsha" 2>/dev/null; then
    printf '%s\n' "$old"; return 0
  fi
  tbr__say "could not move $br onto $rsha — back on $old"
  git checkout -q -B "$br" "$old" 2>/dev/null
  return 1
}
