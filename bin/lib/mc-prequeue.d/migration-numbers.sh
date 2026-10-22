#!/bin/bash
# bin/lib/mc-prequeue.d/migration-numbers.sh — THE CONDUCTOR RE-CHECKS A READY
# HEAD'S MIGRATION NUMBERS RIGHT BEFORE IT QUEUES IT (BH-7671). Sourced by
# bin/lib/mc-prequeue.sh's hook loop, never executed; no side effect at source time.
#
# WHY. bin/lib/migration-renumber.sh renumbers at the build and at a conductor
# rebase. A merge that lands outside the conductor (a local batch, a Mergify
# batch) can take the number after the PR's last rebase: project-6 #2055 was
# queued with 0336 while main had taken 0336 one minute before.
#
# pq_gate calls pq_mignum <slug> <num> <url> <head> <main> after the restamp
# step, only when pq_mignum_wanted answers rc 0. It prints one word line:
#   none              no collision, no added migration, no local clone, or the
#                     check could not run (one could-not-run line a head)
#   pushed <sha> <n>  <n> files renumbered in one commit on the PR branch; the
#                     push answered 0 AND ls-remote shows <sha>. pq_gate holds.
#                     Nothing rebinds the approval: the new head is HEAD_MOVED
#                     and is re-reviewed before it queues
#   held <why>        a collision that was not fixed, or the check could not be
#                     read this tick. pq_gate holds, so the PR is not queued
#
# THE CHECK. The head's ADDED migrations against <main> and every QUEUED PR
# (MNR_HEAD=<head> MNR_OPEN_QUEUED_ONLY=1 mnr_check, read-only, under the git
# lock because the open-PR read fetches into the clone). A head that adds no
# migration stops at one local `git diff` with no lock and no REST read. Only
# sequential names count (mnr_seq_added): a head that adds only 14-digit
# timestamp migrations (BH-7875) stops there too.
# THE FIX. mnr_fix in a temp detached worktree at <head> (every open PR read,
# so the new number lands above all of them), then hold_push (it re-reads the
# ticket's HOLD and leases on <head>) and an ls-remote proof. Under
# REBASE_ON_POOL the hub pushes no PR branch (BH-486): one pool rebase per
# head, whose mnr_fix does the renumber.
#
# Terminal or not. A held answer whose cause will not change by itself (a
# decline, a push refusal, no branch) writes `mignumfail <key> <head>`, one
# refused line and one warn mc_alert; the next tick holds with no git and no
# line. A busy lock, a failed fetch and a HOLD are not terminal: one held line
# a head (`mignumheld`), asked again next tick. Log lines:
#   <key> MIGRATION_RECHECK <pushed|held|refused|could-not-run> head=<h12>
#     new=<n12|-> main=<m12> moves=<n> reason=<text>
#   <key> MIGRATION_RECHECK note head=<h12> reason=<the lib's stderr line>
#
# THE KNOB. MC_MIGRATION_RECHECK (lane merge-conductor, default 1, 0 = off).
# P, BR and KEY are the READY arm's variables (bin/merge-conductor.sh).

_pq_mn_dir="${BASH_SOURCE[0]%/*}"

# _pq_mn_knob -> MC_MIGRATION_RECHECK: the lane knob, else the env, else 1.
_pq_mn_knob() {
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob merge-conductor MC_MIGRATION_RECHECK "${P:-}" 2>/dev/null)
  [ -n "$v" ] || v="${MC_MIGRATION_RECHECK:-1}"
  printf '%s' "$v"
}

# pq_mignum_wanted — rc 0 = run the hook. No git and no network beyond the
#   settings read of mnr_conf: every repo with no migration_renumber.dir stops here.
pq_mignum_wanted() {
  [ "$(_pq_mn_knob)" != 0 ] || return 1
  [ "${ACTIONS:-0}" = 1 ] || return 1
  command -v mnr_conf >/dev/null 2>&1 || { [ -r "$_pq_mn_dir/../migration-renumber.sh" ] && . "$_pq_mn_dir/../migration-renumber.sh"; }
  command -v mnr_conf >/dev/null 2>&1 || return 1
  mnr_conf "${P:-}" 2>/dev/null
  [ -n "${MNR_C_DIR:-}" ] && [ "${MNR_C_MODE:-off}" != off ]
}

# _pq_mn_local <slug> -> the conductor's clone when it exists already: the hub
#   checkout, else the conductor's own clone. rc 1 = none.
_pq_mn_local() {
  local r="${MC_REPOS:-/root/repos}/${P:-}"
  [ -n "${P:-}" ] && [ -d "$r/.git" ] && { printf '%s' "$r"; return 0; }
  [ -n "${MC_H:-}" ] || return 1
  r="$MC_H/tmp/conductor/${1//\//_}"
  [ -d "$r/.git" ] && { printf '%s' "$r"; return 0; }
  return 1
}

# _pq_mn_line <key> <result> <head> <new> <main> <n> <reason>
_pq_mn_line() { mc_log "$1 MIGRATION_RECHECK $2 head=${3:0:12} new=${4:0:12} main=${5:0:12} moves=$6 reason=$7"; }

# _pq_mn_notes <key> <head> <file> — the lib's stderr lines, one note line each.
_pq_mn_notes() {
  local l
  [ -s "$3" ] || return 0
  while IFS= read -r l; do
    [ -n "$l" ] && mc_log "$1 MIGRATION_RECHECK note head=${2:0:12} reason=$l"
  done < "$3"
}

# _pq_mn_held <key> <head> <main> <reason> — transient: one line a head.
_pq_mn_held() {
  mc_attempt_has "mignumheld $1 $2" 2>/dev/null || { mc_attempt_put "mignumheld $1 $2"; _pq_mn_line "$1" held "$2" - "$3" 0 "$4"; }
  printf 'held %s\n' "$4"
}

# _pq_mn_fail <key> <head> <main> <n> <reason> — terminal: mark, line, alert.
_pq_mn_fail() {
  mc_attempt_put "mignumfail $1 $2"
  _pq_mn_line "$1" refused "$2" - "$3" "$4" "$5"
  mc_alert "$1" MIGRATION_RECHECK "${2:0:12} adds migration ${_PQ_MN_FILE:-?} whose number ${_PQ_MN_WHY:-collides}; the conductor could not renumber it ($5) and holds it out of the queue. Renumber it (git mv + references) and push, or set MC_MIGRATION_RECHECK=0."
  printf 'held %s\n' "$5"
}

# _pq_mn_run <slug> <num> <head> <main> — the git half, under the git lock.
#   Sets _PQ_MN (none | cnr <why> | pool <n> | pushed <sha> <n> |
#   transient <why> | refused-<n> <why>), _PQ_MN_WHY and _PQ_MN_FILE.
_pq_mn_run() {
  local slug="$1" num="$2" head="$3" main="$4" repo="$MC_FUNNEL_WT" out rc=0 wt new n prc=0 remote_sha err
  _PQ_MN=""; _PQ_MN_WHY=""; _PQ_MN_FILE=""
  if ! git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null || ! git -C "$repo" cat-file -e "$main^{commit}" 2>/dev/null; then
    git -C "$repo" -c credential.helper= fetch -q origin main "$head" >/dev/null 2>&1 \
      || { _PQ_MN="transient the fetch of main and ${head:0:12} failed"; return 0; }
    git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null && git -C "$repo" cat-file -e "$main^{commit}" 2>/dev/null \
      || { _PQ_MN="transient ${head:0:12} or ${main:0:12} is not in the clone after the fetch"; return 0; }
  fi
  [ -n "$(mnr_seq_added "$repo" "$main" "$head")" ] || { _PQ_MN=none; return 0; }
  err=$(mktemp "${TMPDIR:-/tmp}/pq-mignum-err.XXXXXX") || { _PQ_MN="transient cannot make a temp file"; return 0; }
  out=$(MNR_HEAD="$head" MNR_OPEN_QUEUED_ONLY=1 mnr_check "$repo" "$main" "${P:-}" "${BR:-}" "$num" 2>"$err") || rc=$?
  _pq_mn_notes "${KEY:-$slug#$num}" "$head" "$err"; rm -f "$err"
  case "$rc" in
    0) _PQ_MN=none; return 0 ;;
    1) ;;
    *) _PQ_MN="cnr $(head -n 1 <<<"$out")"; return 0 ;;
  esac
  _PQ_MN_WHY=$(head -n 1 <<<"$out")
  _PQ_MN_FILE=$(sed -n 's/.*(\([^ ]*\) -> .*/\1/p; s/.*; no free number above [0-9]* for \([^ ]*\) .*/\1/p' <<<"$_PQ_MN_WHY" | head -n 1)
  n=$(grep -c . <<<"$out")
  [ -n "${BR:-}" ] || { _PQ_MN="refused-$n no branch name for this PR"; return 0; }
  if declare -F mc_pool_rebase_enabled >/dev/null && mc_pool_rebase_enabled "${P:-}"; then _PQ_MN="pool $n"; return 0; fi
  wt=$(mktemp -d "${TMPDIR:-/tmp}/pq-mignum.XXXXXX") || { _PQ_MN="transient cannot make a temp worktree"; return 0; }
  rmdir "$wt"
  git -C "$repo" worktree add -q --detach "$wt" "$head" >/dev/null 2>&1 || { _PQ_MN="transient git worktree add failed"; return 0; }
  # The fix reads every open PR (not only the queued), so the new number lands
  # above all of them.
  rc=0; out=$(MNR_OPEN_QUEUED_ONLY="" mnr_fix "$wt" "$main" "${P:-}" "$BR" "$num" 2>"$wt.err") || rc=$?
  _pq_mn_notes "${KEY:-$slug#$num}" "$head" "$wt.err"
  new=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  if [ "$rc" = 1 ] || [ "$rc" = 2 ]; then
    _PQ_MN="refused-$n mnr_fix rc $rc: $(head -n 1 <<<"$out")"
  elif [ -z "$out" ] || [ -z "$new" ] || [ "$new" = "$head" ]; then
    _PQ_MN="transient the renumber found nothing to move this tick"
  else
    n=$(grep -c . <<<"$out")
    command -v hold_push >/dev/null 2>&1 || { declare -F mc_hold_push_load >/dev/null && mc_hold_push_load; }
    if ! command -v hold_push >/dev/null 2>&1; then
      _PQ_MN="transient bin/lib/hold-push.sh is not loaded"
    else
      HOLD_PUSH_LOG="${MC_LOG:-}" hold_push -n "${P:-}" - "$wt" "$MC_REMOTE" HEAD "$BR" "$head" >/dev/null 2>"$wt.err" || prc=$?
      case "$prc" in
        0) remote_sha=$(git -C "$repo" -c credential.helper= ls-remote "$MC_REMOTE" "refs/heads/$BR" 2>/dev/null | awk 'NF {print $1; exit}')
           if [ "$remote_sha" = "$new" ]; then _PQ_MN="pushed $new $n"
           else _PQ_MN="refused-$n the push answered 0 but origin $BR is ${remote_sha:-unreadable}, not ${new:0:12}"; fi ;;
        3|4) _PQ_MN="transient $(tail -n 1 "$wt.err" 2>/dev/null | sed 's/^.*\[hold-push\] //')" ;;
        *) _PQ_MN="refused-$n the push was refused (rc $prc): $(tail -n 1 "$wt.err" 2>/dev/null | sed 's/^.*\[hold-push\] //')" ;;
      esac
    fi
  fi
  rm -f "$wt.err"
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || { rm -rf "$wt"; git -C "$repo" worktree prune >/dev/null 2>&1; }
  return 0
}

pq_mignum() {
  local slug="${1:-}" num="${2:-}" url="${3:-}" head="${4:-}" main="${5:-}" key lr rc=0 new n why
  key="${KEY:-$slug#$num}"
  pq_mignum_wanted || { echo none; return 0; }
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [[ "$main" =~ ^[0-9a-f]{40}$ ]] || { echo none; return 0; }
  # A terminal answer or a pool rebase for this head was already given: no git.
  if mc_attempt_has "mignumfail $key $head" 2>/dev/null; then
    echo "held the migration number check failed earlier for this head"; return 0
  fi
  if mc_attempt_has "mignumpool $key $head" 2>/dev/null; then
    echo "held a renumber rebase is queued on the pool"; return 0
  fi
  lr=$(_pq_mn_local "$slug") || { echo none; return 0; }
  # Cheapest first, with no credential, lock or fetch: both commits are in the
  # clone and the head adds no migration.
  if git -C "$lr" cat-file -e "$head^{commit}" 2>/dev/null && git -C "$lr" cat-file -e "$main^{commit}" 2>/dev/null \
     && [ -z "$(mnr_seq_added "$lr" "$main" "$head")" ]; then
    echo none; return 0
  fi
  if ! declare -F mc_funnel_repo >/dev/null || ! mc_funnel_repo "$slug" "${P:-}"; then
    _pq_mn_held "$key" "$head" "$main" "no clone of $slug could be had"; return 0
  fi
  mc_git_locked "${P:-}" _pq_mn_run "$slug" "$num" "$head" "$main" || rc=$?
  declare -F mc_git_auth_clear >/dev/null && mc_git_auth_clear
  if [ "$rc" = 99 ]; then _pq_mn_held "$key" "$head" "$main" "the git lock for ${P:-?} was busy"; return 0; fi
  case "${_PQ_MN:-}" in
    none) echo none ;;
    cnr\ *)
      mc_attempt_has "mignumcnr $key $head" 2>/dev/null \
        || { mc_attempt_put "mignumcnr $key $head"; _pq_mn_line "$key" could-not-run "$head" - "$main" 0 "${_PQ_MN#cnr }"; }
      echo none ;;
    pushed\ *)
      read -r _ new n <<<"$_PQ_MN"
      _pq_mn_line "$key" pushed "$head" "$new" "$main" "$n" "$_PQ_MN_WHY"
      printf 'pushed %s %s\n' "$new" "$n" ;;
    pool\ *)
      rc=0; mc_pool_rebase_enqueue "$slug" "${P:-}" "$BR" "$head" "$url" || rc=$?
      if [ "$rc" = 6 ]; then
        mc_attempt_put "mignumpool $key $head"
        _pq_mn_line "$key" held "$head" - "$main" "${_PQ_MN#pool }" "a renumber rebase is queued on the pool: $_PQ_MN_WHY"
        echo "held a renumber rebase is queued on the pool"
      else
        _pq_mn_held "$key" "$head" "$main" "the pool rebase queue did not answer (rc $rc)"
      fi ;;
    transient\ *) _pq_mn_held "$key" "$head" "$main" "${_PQ_MN#transient }" ;;
    refused-*)
      why="${_PQ_MN#refused-}"
      _pq_mn_fail "$key" "$head" "$main" "${why%% *}" "${why#* }" ;;
    *) _pq_mn_held "$key" "$head" "$main" "the migration number check gave no answer (rc $rc)" ;;
  esac
  return 0
}
