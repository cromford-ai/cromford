# shellcheck shell=bash
# bin/lib/after-stack.sh — BH-9922 scope 3: is a blocker's PR ready to stack on?
#
# WHY. On 2026-11-23 seven project-3 rows waited 2 hours behind TK-797's PR
# #1326. That PR was open and could merge soon. A waiting ticket can build on
# the head of its blocker's PR (the BH-1174 `stack_base` path) when that PR
# will most likely land as it is: open, every check run green, and in the
# merge queue.
#
# Sourced, never executed. Functions only; safe under `set -u`.
#
#   as_pr_ready <slug> <pr-number>
#     rc 0  ready. stdout `<head ref>\t<head sha>\t<html url>`.
#     rc 1  not ready (AS_WHY names why): not open, a fork head, no check run,
#           a check run not completed or not success|neutral|skipped, or not in
#           a merge queue (mc_pr_queued, bin/lib/mc/queue.sh). No merge-queue
#           reader loaded by the caller is not ready too.
#     rc 2  a read did not answer, or answered a shape this does not know, or
#           the check runs are on more than one page (AS_WHY names it).
#   as_branch_ready <slug> <branch>
#     The open PR whose head is <owner>:<branch>, then as_pr_ready on it.
#     AS_PR holds its number. rc 1 when no PR is open on the branch.
#
# "Every required check green" is read as "every check run on the head is
# success, neutral or skipped, and there is at least one". That is at least as
# strict as any required set, and needs no branch-protection read.
#
# READS. pool_rest_read (bin/fly-pool.sh: line 1 is the HTTP code) when the
# caller has it, else gh_rest GET (bin/lib/gh-rest.sh). No other network.
#
# TEST SEAM. AFTER_STACK_FAKE_FILE is a TSV
#   <slug>\t<pr number|branch>\t<ready|not|unreadable>\t<ref>\t<sha>[\t<pr number>]
# With it set, no read is made: a matching row answers, and no row is rc 2.
# The sixth column is the PR number a branch row stands for (AS_PR).

AS_WHY=""; AS_PR=""

# _as_get <path> — the body of one GET on stdout, rc 0 only on HTTP 200.
_as_get() {
  local out code
  if declare -F pool_rest_read >/dev/null 2>&1; then
    out=$(pool_rest_read "$1" "${POOL_SLUG_TOK:-}")
    code=$(head -n 1 <<<"$out")
    [ "$code" = 200 ] || return 2
    tail -n +2 <<<"$out"
    return 0
  fi
  if ! declare -F gh_rest >/dev/null 2>&1; then
    # shellcheck source=bin/lib/gh-rest.sh
    . "${BASH_SOURCE[0]%/*}/gh-rest.sh" 2>/dev/null || return 2
  fi
  gh_rest GET "$1" 2>/dev/null || return 2
}

# _as_fake <slug> <id> — the seam row; rc as as_pr_ready.
_as_fake() {
  local s i st ref sha _pr
  while IFS=$'\t' read -r s i st ref sha _pr; do
    [ "$s" = "$1" ] && [ "$i" = "$2" ] || continue
    case "$st" in
      ready) AS_PR="${AS_PR:-$2}"; printf '%s\t%s\t%s\n' "$ref" "$sha" "https://github.com/$1/pull/$AS_PR"; return 0 ;;
      not) AS_WHY="fake: not ready"; return 1 ;;
      *) AS_WHY="fake: unreadable"; return 2 ;;
    esac
  done < "$AFTER_STACK_FAKE_FILE"
  AS_WHY="fake: no row for $1 $2"
  return 2
}

# _as_queue_reader — rc 0 when mc_pr_queued can be called. This lib never loads
# the merge-conductor lib itself (about 45 files): the caller does. The pool
# has fp_mc_lib_load (bin/fly-pool.sh); the builder's stack plan gate
# (bin/lib/rb/gates.sh) loads the lib in the subshell that runs sw_pre.
_as_queue_reader() {
  declare -F mc_pr_queued >/dev/null 2>&1 && return 0
  declare -F fp_mc_lib_load >/dev/null 2>&1 && { fp_mc_lib_load >/dev/null 2>&1 || :; }
  declare -F mc_pr_queued >/dev/null 2>&1
}

as_pr_ready() {
  local slug="${1:-}" n="${2:-}" pj ref sha url st repo cj total got bad
  AS_WHY=""
  [ -n "$slug" ] && [[ "$n" =~ ^[0-9]+$ ]] || { AS_WHY="no slug or PR number"; return 2; }
  if [ -n "${AFTER_STACK_FAKE_FILE:-}" ]; then AS_PR="$n"; _as_fake "$slug" "$n"; return; fi
  pj=$(_as_get "repos/$slug/pulls/$n") || { AS_WHY="PR #$n read did not answer"; return 2; }
  st=$(jq -r '.state // empty' 2>/dev/null <<<"$pj")
  [ -n "$st" ] || { AS_WHY="PR #$n read gave no state"; return 2; }
  [ "$st" = open ] || { AS_WHY="PR #$n is $st"; return 1; }
  [ "$(jq -r '.merged // false' 2>/dev/null <<<"$pj")" = true ] && { AS_WHY="PR #$n is merged"; return 1; }
  repo=$(jq -r '.head.repo.full_name // empty' 2>/dev/null <<<"$pj")
  [ "$repo" = "$slug" ] || { AS_WHY="PR #$n head is not on $slug (${repo:-none})"; return 1; }
  ref=$(jq -r '.head.ref // empty' 2>/dev/null <<<"$pj")
  sha=$(jq -r '.head.sha // empty' 2>/dev/null <<<"$pj")
  url=$(jq -r '.html_url // empty' 2>/dev/null <<<"$pj")
  [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$sha" =~ ^[0-9a-f]{7,64}$ ]] && [ -n "$url" ] \
    || { AS_WHY="PR #$n read gave no head ref, sha or url"; return 2; }
  cj=$(_as_get "repos/$slug/commits/$sha/check-runs?per_page=100") || { AS_WHY="check runs of #$n did not answer"; return 2; }
  total=$(jq -r '.total_count // empty' 2>/dev/null <<<"$cj")
  got=$(jq -r '(.check_runs // null) | if type == "array" then length else empty end' 2>/dev/null <<<"$cj")
  case "$total$got" in ''|*[!0-9]*) AS_WHY="check runs of #$n: unknown shape"; return 2 ;; esac
  [ "$total" = "$got" ] || { AS_WHY="check runs of #$n: $total runs, $got on one page"; return 2; }
  [ "$got" -ge 1 ] || { AS_WHY="PR #$n has no check run"; return 1; }
  bad=$(jq -r '[.check_runs[] | select(.status != "completed" or ((.conclusion // "") | IN("success","neutral","skipped") | not))] | length' 2>/dev/null <<<"$cj")
  case "$bad" in ''|*[!0-9]*) AS_WHY="check runs of #$n: unknown shape"; return 2 ;; esac
  [ "$bad" = 0 ] || { AS_WHY="PR #$n has $bad check run(s) not green"; return 1; }
  _as_queue_reader || { AS_WHY="no merge-queue reader on this box"; return 1; }
  mc_pr_queued "$url" "$sha" || { AS_WHY="PR #$n is green but not in the merge queue"; return 1; }
  printf '%s\t%s\t%s\n' "$ref" "$sha" "$url"
  return 0
}

as_branch_ready() {
  local slug="${1:-}" br="${2:-}" lj n
  AS_WHY=""; AS_PR=""
  [ -n "$slug" ] && [[ "$br" =~ ^[A-Za-z0-9._/-]+$ ]] || { AS_WHY="no slug or branch"; return 2; }
  if [ -n "${AFTER_STACK_FAKE_FILE:-}" ]; then
    AS_PR=$(awk -F'\t' -v s="$slug" -v b="$br" '$1==s && $2==b {print $6; exit}' "$AFTER_STACK_FAKE_FILE" 2>/dev/null)
    _as_fake "$slug" "$br"; return
  fi
  lj=$(_as_get "repos/$slug/pulls?state=open&head=${slug%%/*}:$br&per_page=1") || { AS_WHY="open PR read for $br did not answer"; return 2; }
  n=$(jq -r 'if type == "array" then (.[0].number // "none") else empty end' 2>/dev/null <<<"$lj")
  case "$n" in
    none) AS_WHY="no open PR on $br"; return 1 ;;
    ''|*[!0-9]*) AS_WHY="open PR read for $br: unknown shape"; return 2 ;;
  esac
  AS_PR="$n"
  as_pr_ready "$slug" "$n"
}

# pool_after_stack_ready <job-file> <blocker> — BH-9922: rc 0 when the row may
# stack on its blocker's open PR: POOL_AFTER_STACK_QUEUED is 1, the row has no
# stack_base yet, the tick knows the PR number, and as_pr_ready
# (above) answers rc 0. Called by pool_after_gate in bin/fly-pool.sh; it reads
# that file's _POOL_PR_NUM and POOL_SLUG. Sets _PAS_PR and _PAS_REF. One
# answer per blocker per tick (_PAS_CACHE); any other answer is rc 1 and the
# row is held as before.
declare -gA _PAS_CACHE=()
pool_after_stack_ready() {
  local jf="$1" other="$2" n v rc
  _PAS_PR=""; _PAS_REF=""
  # POOL_AFTER_STACK_QUEUED: catalog/lanes.d/fly-pool.knobs.d/POOL_AFTER_STACK_QUEUED.json; 1 is its fallback.
  [ "${POOL_AFTER_STACK_QUEUED:-1}" = 1 ] || return 1
  command -v as_pr_ready >/dev/null 2>&1 || return 1
  [ -z "$(jq -r '.stack_base // empty' "$jf" 2>/dev/null)" ] || return 1
  n="${_POOL_PR_NUM[$other]:-}"; [[ "$n" =~ ^[0-9]+$ ]] || return 1
  v="${_PAS_CACHE[$other]:-}"
  if [ -z "$v" ]; then
    rc=0; v=$(as_pr_ready "$POOL_SLUG" "$n" 2>/dev/null) || rc=$?
    v="$rc"$'\t'"${v%%$'\t'*}"
    _PAS_CACHE[$other]="$v"
  fi
  [ "${v%%$'\t'*}" = 0 ] || return 1
  _PAS_REF="${v#*$'\t'}"; _PAS_PR="$n"
  [[ "$_PAS_REF" =~ ^[A-Za-z0-9._/-]+$ ]]
}
