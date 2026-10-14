#!/bin/bash
# bin/lib/stale-parent.sh — a stacked child that still carries its parent's
# OLD commits (BH-5234). Sourced, never executed: no `set -e`, no `exit`, no
# output at source time.
#
# WHAT HAPPENED (#5010 / #5053, 2026-10-07). Child #5053 was cut from parent
# commits 6da7eac3 + be7d4731. The parent PR #5010 was force-pushed while the
# child sat on it — a pure rebase onto newer main, same patches, new shas — and
# then landed. mc_restack was handed the parent's pre-merge head, which is not
# in the child's history, so it answered rc 6 and nothing moved the child. It
# carried the old copies of the parent's commits next to the landed ones, and an
# add/add on every file the parent added.
#
# WHAT THIS FILE PROVES. A rewritten or landed copy of a commit keeps its
# `git patch-id --stable`, so the child's real fork point is the end of the
# longest leading run of its own first-parent commits whose patches are already
# on the base. Nothing here guesses: no proof, no fork point.
#
#   sp_fork_point <wt> <base-ref> <head>     rc 0 + sha · 1 none · 2 interleaved
#   sp_own_commits <wt> <fork> <head>        first-parent --no-merges, oldest first
#   sp_replay <wt> <onto> <fork> <head>      rc 0 · 1 conflict (files on stdout)
#                                            · 4 setup · 7 an own diff changed
#   sp_stale_commits <wt> <base-ref> <head>  TSV child_sha, main_sha, subject
#   sp_open_children <slug> <branch>         rc 0 proven list · 1 unreadable (why)
#   sp_is_rollout_wave <body>                rc 0 = a rollout wave child
#   sp_wait_mode [project]                   off | rollouts | all | plan
#
# Knobs: catalog/lanes.d/_lib.stale-parent.json, through lib_env_apply
# stale-parent (settings row > env > the registry default these fallbacks
# mirror). Root: ${HARNESS:-${H:-}}, nothing else.

_SP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# sp_knob <NAME> [project] — one of this lib's knobs, resolved through the lane
# gate in a subshell (its fail-closed exit cannot end the caller), as
# bin/lib/starved-ready.sh _sr_knobs does: settings row > env > the registry
# default below, which mirrors catalog/lanes.d/_lib.stale-parent.json. A value
# that is not valid for its knob is its default; sp_wait_mode says so in a log.
sp_knob() {
  local name="${1:-}" v
  v=$(
    exec 3>&1
    # shellcheck disable=SC2016 # expanded by the trap, at exit
    trap 'printf "%s" "${!name:-}" >&3' EXIT
    command -v lib_env_apply >/dev/null 2>&1 || . "$_SP_LIB/lane-gate.sh" >/dev/null 2>&1 || exit 0
    lib_env_apply stale-parent "${2:-}" >/dev/null 2>&1) || true
  case "$name" in
    STACK_WAIT_PARENT_MERGE) printf '%s\n' "${v:-plan}" ;;
    STACK_WAIT_CAP_H) case "$v" in ''|*[!0-9]*|0) printf '24\n' ;; *) [ "$v" -gt 336 ] && v=336; printf '%s\n' "$v" ;; esac ;;
    HOLD_PUSH_REWRITE_GUARD|STALE_PARENT_CHECK) case "$v" in 0) printf '0\n' ;; *) printf '1\n' ;; esac ;;
    STALE_PARENT_MAX_PRS) case "$v" in ''|*[!0-9]*|0) printf '30\n' ;; *) [ "$v" -gt 100 ] && v=100; printf '%s\n' "$v" ;; esac ;;
    STALE_PARENT_SCAN_MAX) case "$v" in ''|*[!0-9]*|0) printf '20\n' ;; *) printf '%s\n' "$v" ;; esac ;;
    *) printf '%s\n' "$v" ;;
  esac
}

# _sp_scan_max — STALE_PARENT_SCAN_MAX, a positive integer or 20.
_sp_scan_max() { sp_knob STALE_PARENT_SCAN_MAX; }

# _sp_list <wt> <base-ref> <head> — the child's first-parent non-merge commits
# over the base, oldest first, capped at the scan max.
_sp_list() {
  local out
  out=$(git -C "$1" rev-list --reverse --first-parent --no-merges "$2..$3" 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  head -n "$(_sp_scan_max)" <<<"$out"
}

# _sp_pid <wt> <commit> — the commit's stable patch-id ("" for an empty diff)
_sp_pid() { git -C "$1" show --no-color "$2" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1; }

# _sp_base_pids <wt> <base-ref> <since-epoch> — "patch-id<TAB>sha" for every
# non-merge commit on the base committed since the child's oldest commit. A
# rewritten or landed copy is committed AFTER the child was cut, so the window
# is complete; an hour of slack covers a committer clock that ran behind.
_sp_base_pids() {
  git -C "$1" log --no-merges --no-color --since="@$(( $3 - 3600 ))" -p "$2" 2>/dev/null \
    | git patch-id --stable 2>/dev/null | awk '{print $1 "\t" $2}'
}

# _sp_cum_pid <wt> <first> <c> — the patch-id of everything from first^ to c:
# what a squash of first..c would carry.
_sp_cum_pid() {
  local from
  from=$(git -C "$1" rev-parse -q --verify "$2^" 2>/dev/null) || return 1
  git -C "$1" diff --no-color "$from" "$3" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1
}

# sp_fork_point <wt> <base-ref> <head>
#   rc 0  stdout = the last commit of the stale prefix (the child's own commits
#         start right after it)
#   rc 1  no stale prefix (nothing proven; also an empty range or a git failure)
#   rc 2  a stale commit sits AFTER one of the child's own: not a parent prefix
sp_fork_point() {
  local wt="$1" base="$2" head="$3" list first since pids c p n=0 end="" i
  list=$(_sp_list "$wt" "$base" "$head") || return 1
  [ -n "$list" ] || return 1
  first=$(head -n 1 <<<"$list")
  since=$(git -C "$wt" log -1 --format=%ct "$first" 2>/dev/null) || return 1
  pids=$(_sp_base_pids "$wt" "$base" "$since" | cut -f1 | sort -u)
  [ -n "$pids" ] || return 1
  # 1. The per-commit prefix: a rebased parent keeps every patch-id.
  local -a commits=() stale=()
  while IFS= read -r c; do
    commits+=("$c")
    p=$(_sp_pid "$wt" "$c")
    if [ -n "$p" ] && grep -qxF "$p" <<<"$pids"; then stale+=(1); else stale+=(0); fi
  done <<<"$list"
  while [ "$n" -lt "${#commits[@]}" ] && [ "${stale[$n]}" = 1 ]; do n=$((n + 1)); done
  [ "$n" -gt 0 ] && end="${commits[$((n - 1))]}"
  # 2. The squash form, only when no single commit matched: the longest prefix
  #    whose cumulative diff is one commit on the base.
  if [ -z "$end" ]; then
    for ((i = 0; i < ${#commits[@]}; i++)); do
      p=$(_sp_cum_pid "$wt" "$first" "${commits[$i]}")
      [ -n "$p" ] && grep -qxF "$p" <<<"$pids" && { end="${commits[$i]}"; n=$((i + 1)); }
    done
  fi
  # 3. Anything stale after the prefix is not a parent's prefix; refuse.
  for ((i = n; i < ${#commits[@]}; i++)); do
    [ "${stale[$i]}" = 1 ] && return 2
  done
  [ -n "$end" ] || return 1
  printf '%s\n' "$end"
}

# sp_own_commits <wt> <fork> <head> — the child's own commits, oldest first.
# Merges on its first-parent line (sync merges of the base) are not its own.
sp_own_commits() { git -C "$1" rev-list --reverse --first-parent --no-merges "$2..$3"; }

# sp_replay <wt> <onto> <fork> <head> — leaves <wt> on a detached head made of
# <onto> plus the child's own commits, cherry-picked in order with the
# conductor's identity (the authors are untouched).
#   rc 0  replayed, and every replayed commit has its original's patch-id
#   rc 1  a conflict: the unmerged files on stdout, the pick aborted
#   rc 4  setup failed (nothing to replay, a checkout git refused)
#   rc 7  a replayed commit's own diff changed: stdout names it. The caller must
#         not push this: the reviewed change is not the change it would publish.
sp_replay() {
  local wt="$1" onto="$2" fork="$3" head="$4" own c conf i=0 orig new
  own=$(sp_own_commits "$wt" "$fork" "$head" 2>/dev/null) || return 4
  [ -n "$own" ] || return 4
  git -C "$wt" checkout -q --detach "$onto" >/dev/null 2>&1 || return 4
  local -a gitid=(-c "user.name=${MC_GIT_NAME:-${HARNESS_MERGE_GIT_NAME:-box}}" \
                  -c "user.email=${MC_GIT_EMAIL:-${HARNESS_GIT_EMAIL:-box@users.noreply.github.com}}" \
                  -c commit.gpgsign=false)
  while IFS= read -r c; do
    if ! git -C "$wt" "${gitid[@]}" cherry-pick --allow-empty "$c" >/dev/null 2>&1; then
      conf=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)
      git -C "$wt" cherry-pick --abort >/dev/null 2>&1
      [ -n "$conf" ] && { printf '%s\n' "$conf"; return 1; }
      return 4
    fi
  done <<<"$own"
  # Compare in order: commit i from the top of the replay is own commit i.
  local n; n=$(wc -l <<<"$own")
  while IFS= read -r c; do
    new=$(git -C "$wt" rev-parse "HEAD~$((n - 1 - i))" 2>/dev/null) || return 4
    orig=$(_sp_pid "$wt" "$c"); i=$((i + 1))
    [ "$orig" = "$(_sp_pid "$wt" "$new")" ] || { printf '%s\n' "$c"; return 7; }
  done <<<"$own"
  return 0
}

# sp_stale_commits <wt> <base-ref> <head> — one TSV row per commit the head
# carries that is ALREADY on the base under another sha:
#   child_sha<TAB>main_sha<TAB>subject
# The base's copies are read from the base's own history, never from base..head,
# so a copy the child also reaches through a sync merge still counts (this is
# what `git cherry` misses). When no single commit matches, a leading run whose
# cumulative diff is one base commit (a squash-landed parent) is reported
# against that commit. rc 0 with or without rows; non-zero on a git failure.
sp_stale_commits() {
  local wt="$1" base="$2" head="$3" list first since map c p m i
  git -C "$wt" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1 || return 1
  git -C "$wt" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || return 1
  list=$(_sp_list "$wt" "$base" "$head") || return 1
  [ -n "$list" ] || return 0
  first=$(head -n 1 <<<"$list")
  since=$(git -C "$wt" log -1 --format=%ct "$first" 2>/dev/null) || return 1
  map=$(_sp_base_pids "$wt" "$base" "$since")
  [ -n "$map" ] || return 0
  local rows=""
  while IFS= read -r c; do
    p=$(_sp_pid "$wt" "$c"); [ -n "$p" ] || continue
    m=$(awk -F'\t' -v p="$p" '$1 == p {print $2; exit}' <<<"$map")
    [ -n "$m" ] && [ "$m" != "$c" ] || continue
    rows+="$c"$'\t'"$m"$'\t'"$(git -C "$wt" log -1 --format=%s "$c")"$'\n'
  done <<<"$list"
  if [ -z "$rows" ]; then
    local -a commits=(); local endi=-1 endm=""
    while IFS= read -r c; do commits+=("$c"); done <<<"$list"
    for ((i = 0; i < ${#commits[@]}; i++)); do
      p=$(_sp_cum_pid "$wt" "$first" "${commits[$i]}")
      [ -n "$p" ] || continue
      m=$(awk -F'\t' -v p="$p" '$1 == p {print $2; exit}' <<<"$map")
      [ -n "$m" ] && { endi=$i; endm=$m; }
    done
    for ((i = 0; i <= endi; i++)); do
      rows+="${commits[$i]}"$'\t'"$endm"$'\t'"$(git -C "$wt" log -1 --format=%s "${commits[$i]}")"$'\n'
    done
  fi
  printf '%s' "$rows"
}

# sp_open_children <slug> <branch> — the open PRs whose base is <branch>, one
# number a line. The same contract as _gpm_open_children: rc 0 means the list is
# PROVEN complete (possibly empty); rc 1 means it is not, and stdout says why.
# Read through gh_rest (bin/lib/gh-rest.sh): the caller's when it has one, else
# the file beside this one in a subshell, so the caller's functions are never
# redefined. Neither present: rc 1.
sp_open_children() {
  local slug="${1:-}" br="${2:-}" enc t rc=0 n
  case "$slug" in */*) ;; *) printf 'no repo slug to read the children of %s from' "${br:--}"; return 1 ;; esac
  [ -n "$br" ] || { printf 'no branch named'; return 1; }
  enc=$(jq -rn --arg r "$br" '$r|@uri' 2>/dev/null)
  [ -n "$enc" ] || { printf 'the branch could not be encoded for the open-PR query'; return 1; }
  t=$(mktemp "${TMPDIR:-/tmp}/sp-children.XXXXXX" 2>/dev/null) || { printf 'no temp file'; return 1; }
  if command -v gh_rest >/dev/null 2>&1; then
    gh_rest GET "repos/$slug/pulls?state=open&base=$enc&per_page=100" > "$t" 2>/dev/null || rc=$?
  elif [ -r "$_SP_LIB/gh-rest.sh" ]; then
    ( . "$_SP_LIB/gh-rest.sh" 2>/dev/null && gh_rest GET "repos/$slug/pulls?state=open&base=$enc&per_page=100" ) > "$t" 2>/dev/null || rc=$?
  else
    rm -f "$t"; printf 'bin/lib/gh-rest.sh is not beside bin/lib/stale-parent.sh'; return 1
  fi
  if [ "$rc" != 0 ]; then rm -f "$t"; printf 'the open-PR list of base %s answered rc %s' "$br" "$rc"; return 1; fi
  n=$(jq -r 'if type == "array" then length else empty end' "$t" 2>/dev/null)
  case "${n:-x}" in
    ''|*[!0-9]*) rm -f "$t"; printf 'the open-PR list of base %s is not a JSON array' "$br"; return 1 ;;
  esac
  if [ "$n" -ge 100 ]; then
    rm -f "$t"; printf 'the open-PR list of base %s came back a full page of %s' "$br" "$n"; return 1
  fi
  jq -r '.[].number // empty' "$t" 2>/dev/null
  rm -f "$t"
  return 0
}

# sp_is_rollout_wave <body> — rc 0 when the issue body is a rollout wave child
# (bin/lib/file-children.sh fc_child_footer writes `Rollout wave N of M:`).
sp_is_rollout_wave() { grep -qE '^Rollout wave [0-9]+ of [0-9]+:' <<<"${1:-}"; }

# sp_wait_mode [project] — STACK_WAIT_PARENT_MERGE: off | rollouts | all |
# plan. `plan` (BH-6389, bin/lib/stack-wait.sh) is `rollouts` plus: a child
# stacks only when its plan's `## Stack` files are disjoint from the parent's.
# An invalid value is `plan`, the registry default, with one line in
# logs/stale-parent.log: a settings outage never turns the wait off.
sp_wait_mode() {
  local v h
  v=$(sp_knob STACK_WAIT_PARENT_MERGE "${1:-}")
  case "$v" in
    off|rollouts|all|plan) printf '%s\n' "$v" ;;
    *)
      h="${HARNESS:-${H:-}}"
      if [ -n "$h" ]; then
        mkdir -p "$h/logs" 2>/dev/null
        printf '%s [%s] stale-parent: STACK_WAIT_PARENT_MERGE=%s is not off|rollouts|all|plan — using plan\n' \
          "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${1:--}" "$v" >> "$h/logs/stale-parent.log" 2>/dev/null
      fi
      printf 'plan\n' ;;
  esac
}
