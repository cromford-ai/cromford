#!/bin/bash
# shellcheck shell=bash
# module: locks after: log
# bin/lib/mc/locks.sh — BH-477: PR/merge/git locks, per-tick counters and spend budgets, the attempts ledger. Sourced by bin/lib/merge-conductor-lib.sh, never run.

# --- Locks: one per PR, one short one per project (2026-09-15) ---------------
# WHAT CHANGED AND WHY. The tick used to take ONE flock per project
# (locks/merge-conductor-<project>.lock) with `flock -n` and skip the WHOLE
# project when it was held. Measured 2026-09-15 21:00-23:00Z: 102 "an earlier
# conductor tick still holds this project's lock — skipped" lines in two hours
# (cromford 30, project-5 21, project-7 15, project-2 9,
# project-8 9, project-4 6, the rest 3 each). One slow PR — a rebase wait,
# a queue settle — cost its repo the next one to three ticks ENTIRELY, and
# every other PR on that repo with it.
#
# The lock is therefore sharded to the thing that actually needs serialising:
#   mc_pr_lock      one PR of one project. Classification, the rebase, the
#                   re-review dispatch and the deploy-verify read all run under
#                   it, so N PRs of one repo progress at once and a PR whose
#                   worker is still running costs only ITSELF a tick.
#   mc_merge_lock   the merge / merge-queue-enqueue CALL, and nothing else. Two
#                   PRs of one repo must not race main. Held for one gh call and
#                   released; everything the landing owes (the settle, the issue
#                   close, the deploy lane) happens outside it.
#   mc_git_lock     the project's SHARED GIT CHECKOUT (/root/repos/<project>, or
#                   the conductor's own clone) — the one piece of per-project
#                   state the funnel reads that is not a file this lib owns.
#                   mc_merge_tree, mc_patch_id and mc_no_overlap each do
#                   `remote set-url` + fetch + read + mc_git_auth_clear in it,
#                   and two of those at once means one worker clearing the
#                   remote's credentials out from under the other's fetch. Held
#                   for that one read (mc_git_locked); rc 99 = could not be had,
#                   which every caller reads as "not answered this tick",
#                   never as an answer.
# The other shared per-project state keeps the lock it already had: pr-state.tsv
# is rewritten whole under mc_row_put's flock, and attempts.txt, the re-review
# cap file and the log are append-only.
#
# A PR LOCK CAN NEVER WEDGE A PR. It is an fd the kernel releases when the
# worker exits, however it exits — there is no timestamp, no owner file and
# nothing to expire. The one way to hold it past your own life is to FORK A
# DAEMON INSIDE THE SECTION: a child inherits the fd and keeps the lock for its
# whole life (a deploy verifier did exactly that on project-5, 03:54-04:02Z on
# 2026-09-14). Every detached lane here is spawned with the lock fds CLOSED —
# `9>&- 8>&- 7>&-` on the setsid lines below — and any new one must be too.
MC_LOCK_DIR="$MC_H/locks"
MC_PR_PARALLEL="${MC_PR_PARALLEL:-0}"              # PR workers of ONE project at once; 0 = unlimited (the MC_REREVIEW_PARALLEL/MC_REBASE_PARALLEL convention)
MC_MERGE_LOCK_WAIT="${MC_MERGE_LOCK_WAIT:-120}"    # seconds a PR worker waits for its project's merge lock before giving up on this tick
MC_GIT_LOCK_WAIT="${MC_GIT_LOCK_WAIT:-180}"        # seconds it waits for the project's shared git checkout
MC_PR_LOCK_TTL_DAYS="${MC_PR_LOCK_TTL_DAYS:-14}"   # a PR lock file untouched for this long is GC'd (mc_pr_lock_gc)
MC_TICK_DIR="$MC_STATE_DIR/tick"                   # per-tick counters: the spend budgets and the tick metrics
mc_safe_name() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
mc_pr_lock()    { printf '%s/merge-conductor-%s-%s.lock' "$MC_LOCK_DIR" "$(mc_safe_name "$1")" "$(mc_safe_name "$2")"; }
mc_merge_lock() { printf '%s/merge-conductor-%s-merge.lock' "$MC_LOCK_DIR" "$(mc_safe_name "$1")"; }
mc_git_lock()   { printf '%s/merge-conductor-%s-git.lock' "$MC_LOCK_DIR" "$(mc_safe_name "$1")"; }
# mc_pr_lock_take — take the PR lock already open on fd 9. Every cron and
#   keyed worker asks with flock -n and skips a PR another worker holds. A run
#   started BY a worker that still holds that lock (the READY re-kick, BH-6000
#   part 3: kw_conductor from inside pr_worker) is launched with
#   MC_PR_LOCK_WAIT_S=<s>, an input set by its launcher, never a knob: it waits
#   up to <s> seconds for the launcher to finish and drop the lock, instead of
#   losing that race and skipping (lead review lr-6015). rc 0 taken.
mc_pr_lock_take() {
  local w="${MC_PR_LOCK_WAIT_S-}"
  case "$w" in ''|*[!0-9]*|0) flock -n 9 ;; *) flock -w "$w" 9 ;; esac
}

# --- The project lease (BH-6887, BH-6881.3) ----------------------------------
# The merge lock is also a D1 project lease (lane merge-conductor, one per
# project, bin/lib/project-lease.sh): a box flock cannot serialise the hub
# against a lane-run machine. The holder that took it exports
#   MC_LEASE_FENCE    the fence token it holds
#   MC_LEASE_PROJECT  the project the fence is for
#   MC_LEASE_HOLDER   its holder id
# to the command it runs, and each landing writer (mc_merge, mc_enqueue,
# conductor_settle, mc_close_shipped) calls mc_lease_fence_ok before its
# GitHub write. An outer owner (a per-project runner) may export the three
# itself; mc_merge_locked then takes no lease and releases none.
# Contract: docs/notes/2026-10-17-BH-6887-mc-lease-budget.md.
MC_LEASE_LANE=merge-conductor

# mc_lease_holder — this process's holder id: hub-<hostname> on the hub (one id
#   for every hub worker, which the hub flock already serialises), the
#   FLY_MACHINE_ID (else machine-<hostname>) on a lane-run machine. Reduced to
#   [A-Za-z0-9._-], 64 characters at most.
mc_lease_holder() {
  local h
  if [ "${MC_ON_MACHINE:-}" = 1 ]; then h="${FLY_MACHINE_ID:-machine-$(hostname 2>/dev/null)}"
  else h="hub-$(hostname 2>/dev/null)"; fi
  h="${h//[^A-Za-z0-9._-]/_}"
  printf '%s' "${h:0:64}"
}

# _mc_lease_lib — source the jobs client and the project-lease client when the
#   caller has not. rc 0 always; a caller checks for the function it needs.
_mc_lease_lib() {
  # shellcheck source=/dev/null
  declare -F _jobs_req >/dev/null || { [ -r "$MC_H/bin/jobs-client.sh" ] && . "$MC_H/bin/jobs-client.sh"; }
  # shellcheck source=/dev/null
  declare -F pjl_acquire >/dev/null || { [ -r "$MC_H/bin/lib/project-lease.sh" ] && . "$MC_H/bin/lib/project-lease.sh"; }
  return 0
}

# _mc_lease_acquire <project> — pjl_acquire's rc and its fence on stdout; rc 1
#   when there is no lease client.
_mc_lease_acquire() {
  declare -F pjl_acquire >/dev/null || return 1
  pjl_acquire "$MC_LEASE_LANE" "$1" "$(mc_lease_holder)"
}

# mc_lease_fence_ok — the fence check before a landing write. rc 0 = write.
#   With no MC_LEASE_FENCE held it does nothing. Else it renews the fence:
#   200 is rc 0; 409 `lost` is rc 99 ("nothing written, try next tick"); a
#   renew that could not be answered is rc 99 on a machine (it has no other
#   serialisation) and rc 0 on the hub (its flock still holds, and a D1
#   outage must not stop every landing). Prints nothing on stdout: callers
#   capture the writer's stdout.
mc_lease_fence_ok() {
  [ -n "${MC_LEASE_FENCE:-}" ] || return 0
  local p="${MC_LEASE_PROJECT:-}" h="${MC_LEASE_HOLDER:-}" rc=1
  [ -n "$h" ] || h=$(mc_lease_holder)
  _mc_lease_lib >/dev/null 2>&1
  if declare -F pjl_renew >/dev/null; then
    pjl_renew "$MC_LEASE_LANE" "$p" "$h" "$MC_LEASE_FENCE" >/dev/null 2>&1; rc=$?
  fi
  case "$rc" in
    0) return 0 ;;
    3) mc_log "$p project lease lost (fence $MC_LEASE_FENCE) — write stopped, next tick"; return 99 ;;
  esac
  if [ "${MC_ON_MACHINE:-}" = 1 ]; then
    mc_log "$p project lease renew unavailable on a lane-run machine — write stopped, next tick"; return 99
  fi
  mc_log "$p project lease renew unavailable — hub flock only"
  return 0
}

# mc_merge_locked <project> <command...> — run ONE merge-class call under the
#   project's merge lock and release it the moment the call returns. rc is the
#   command's own, except 99 = the lock could not be had, which every caller
#   treats as "nothing was written, try next tick" and never as a merge
#   failure.
#
#   THE LOCK IS TWO THINGS (BH-6887):
#     on the hub         the box flock (locks/merge-conductor-<project>-merge.lock,
#                        fd 8), within MC_MERGE_LOCK_WAIT seconds, and then the
#                        project lease. A lease held by another holder is 99.
#                        A lease that could not be answered (no jobs client, a
#                        D1 outage) runs the call under the flock only, as
#                        before the lease existed.
#     on a lane-run      (MC_ON_MACHINE=1) the project lease instead of the
#     machine            flock: this box's flock cannot serialise against the
#                        hub or another machine. A lease held elsewhere, or
#                        not answered, is 99. A direct merge (mc_merge) or a
#                        queue enqueue (mc_enqueue) runs only under a lease an
#                        outer owner holds (MC_LEASE_FENCE set); without one
#                        it writes its word (merge|enqueue) to
#                        MC_PR_DEFERRED_FILE and is 99, so the hub lands it.
#   A lease it took is exported to the command (MC_LEASE_FENCE/_PROJECT/
#   _HOLDER, as locals, so nothing leaks past the call) and released after.
#   With MC_LEASE_FENCE already set by an outer owner it takes no lease and
#   releases none; the writers renew that fence.
#   Inside a conductor worker the flock wait is also capped at the worker's
#   deadline less 15 s (mc_lock_wait_left, bin/lib/fanin.sh), and with less
#   than that left it is 99 at once, before the lock file is opened.
#
#   WHY IT IS A FUNCTION AROUND ONE CALL AND NOT A SECTION. fd 8 is opened and
#   closed inside it, and every caller invokes it as `$(mc_merge_locked ...)`,
#   so the fd lives only for the duration of that one command substitution and
#   nothing the worker forks AFTERWARDS can inherit it — not the settle's
#   deploy-verify lane, not the issue close, not a re-review. A daemon that
#   inherits a held flock holds it for its entire life (the 03:54-04:02Z
#   project-5 stall), and that is worth making unrepresentable rather than
#   merely avoiding. The lane spawns close fd 8 as well, belt and braces.
#
#   It is bounded and it is short by construction: what runs inside is one gh
#   call plus mc_merge's settle sleep, never a clone, a review or a deploy.
mc_merge_locked() {
  local proj="$1"; shift
  local rc w="${MC_MERGE_LOCK_WAIT:-120}" fence="" lrc=0
  if [ "${MC_ON_MACHINE:-}" = 1 ]; then
    if [ -n "${MC_LEASE_FENCE:-}" ]; then
      local -x MC_LEASE_PROJECT="$proj" MC_LEASE_HOLDER="${MC_LEASE_HOLDER:-$(mc_lease_holder)}"
      "$@"; return $?
    fi
    # A landing call with no lease owner around it lands nothing here (BH-6495):
    # pr_worker defers a READY PR on a machine (deferred=land), and this is the
    # second guard until a per-project runner holds the lease for the tick.
    case "${1:-}" in
      mc_merge)   [ -n "${MC_PR_DEFERRED_FILE:-}" ] && echo merge >> "$MC_PR_DEFERRED_FILE"; return 99 ;;
      mc_enqueue) [ -n "${MC_PR_DEFERRED_FILE:-}" ] && echo enqueue >> "$MC_PR_DEFERRED_FILE"; return 99 ;;
    esac
    _mc_lease_lib >/dev/null 2>&1
    fence=$(_mc_lease_acquire "$proj"); lrc=$?
    [ "$lrc" = 0 ] && { _mc_merge_leased "$proj" "$fence" "$@"; return $?; }
    if [ "$lrc" = 3 ]; then mc_log "$proj merge lease held by another holder — next tick"
    else mc_log "$proj merge lease unavailable on a lane-run machine — next tick"; fi
    return 99
  fi
  if command -v mc_lock_wait_left >/dev/null 2>&1; then w=$(mc_lock_wait_left "$w") || return 99; fi
  exec 8>>"$(mc_merge_lock "$proj")" || return 99
  flock -w "$w" 8 || { exec 8>&-; return 99; }
  if [ -n "${MC_LEASE_FENCE:-}" ]; then
    local -x MC_LEASE_PROJECT="$proj"
    "$@"; rc=$?
  else
    _mc_lease_lib >/dev/null 2>&1
    fence=$(_mc_lease_acquire "$proj"); lrc=$?
    case "$lrc" in
      0) _mc_merge_leased "$proj" "$fence" "$@"; rc=$? ;;
      3) flock -u 8; exec 8>&-
         mc_log "$proj merge lease held by another holder — next tick"
         return 99 ;;
      *) [ -n "${JOBS_URL:-}" ] && mc_log "$proj merge lease unavailable — hub flock only"
         "$@"; rc=$? ;;
    esac
  fi
  flock -u 8; exec 8>&-
  return "$rc"
}

# _mc_merge_leased <project> <fence> <command...> — run the command with the
#   lease it was given exported, then release that lease (rc ignored: a lease
#   not released expires at its TTL, project_lease.ttl_s).
_mc_merge_leased() {
  local proj="$1" fence="$2" rc; shift 2
  local -x MC_LEASE_FENCE="$fence" MC_LEASE_PROJECT="$proj" MC_LEASE_HOLDER
  MC_LEASE_HOLDER=$(mc_lease_holder)
  "$@"; rc=$?
  pjl_release "$MC_LEASE_LANE" "$proj" "$MC_LEASE_HOLDER" "$fence" >/dev/null 2>&1
  return "$rc"
}

# mc_git_locked <project> <command...> — the same contract as mc_merge_locked,
#   on fd 7 and the project's git lock, for the funnel reads that share one
#   checkout: mc_merge_tree, mc_patch_id (both rebind halves) and mc_no_overlap.
#   Each is a fetch and a read of a few hundred milliseconds; the wait is
#   MC_GIT_LOCK_WAIT so a repo with a dozen PRs in one tick queues rather than
#   fails, capped inside a worker at its deadline the same way. rc 99 = the lock
#   could not be had, and a caller that gets it must decline to act rather than
#   treat it as a negative answer.
mc_git_locked() {
  local proj="$1"; shift
  local rc w="${MC_GIT_LOCK_WAIT:-180}"
  if command -v mc_lock_wait_left >/dev/null 2>&1; then w=$(mc_lock_wait_left "$w") || return 99; fi
  exec 7>>"$(mc_git_lock "$proj")" || return 99
  flock -w "$w" 7 || { exec 7>&-; return 99; }
  "$@"; rc=$?
  flock -u 7; exec 7>&-
  return "$rc"
}


# --- Per-tick counters: the spend budgets and the tick metrics ---------------
# WHY A FILE AND NOT A VARIABLE. The three spend budgets (MC_REBASE_BUDGET,
# MC_REREVIEW_BUDGET, MC_MERGE_BUDGET) were bash variables decremented inside
# tick_project, which was exactly right while one project was one sequential
# loop. The PR workers of a project now run CONCURRENTLY, and a subshell gets a
# COPY of every variable — five workers would each spend "the last" rebase and
# the budget would mean nothing. The counter is a file incremented under its own
# flock, keyed by TICK ID so it starts at zero every tick and never needs a
# reset: mc_tick_gc drops yesterday's.
#
# The metrics counters ride the same mechanism for the same reason — they are
# written by the workers and read by the parent after they exit.
mc_tick_id() { printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"; }
# ONE FILE PER (TICK, PROJECT), `<name> <value>` a line. Not one file per
# counter: a box ticks 288 times a day across ten projects, and a file (plus a
# lock file) per counter per tick is tens of thousands of inodes a day in one
# flat directory for numbers that are three bytes long. One file also means one
# lock — and because it is rewritten IN PLACE rather than through a mv, the file
# can BE its own lock (an mv would leave every waiter holding the old inode).
mc_count_file() { # mc_count_file <project>
  printf '%s/%s.%s' "$MC_TICK_DIR" "$(mc_safe_name "${MC_TICK_ID:-notick}")" "$(mc_safe_name "$1")"
}
_mc_count_read() { # _mc_count_read <file> <name> -> the value, 0 when absent or junk
  local n; n=$(awk -v k="$2" '$1==k {print $2; exit}' "$1" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}
_mc_count_set() { # _mc_count_set <file> <name> <value> — CALLER HOLDS THE LOCK
  local rest; rest=$(awk -v k="$2" '$1!=k' "$1" 2>/dev/null)
  { [ -n "$rest" ] && printf '%s\n' "$rest"; printf '%s %s\n' "$2" "$3"; } > "$1"
}
mc_count_get() { _mc_count_read "$(mc_count_file "$1")" "$2"; }

# THE EJECTIONS THIS TICK MADE ITSELF (BH-636). The settle pass runs BEFORE the
# open pass, so a PR the queue threw out can be ejected and re-queued inside one
# tick — and that is wrong twice. The row would never show `queue-ejected` at
# all, so nobody reading it would know the batch failed; and the witness poll
# inside the requeue would be asking about a head whose Mergify check still says
# `failure` from the ejection seconds earlier, which reads as a live witness and
# would stamp the row QUEUED on a check that means the opposite. The ejection
# gets one tick to stand. Same (tick, project) keying and the same GC as the
# counters above.
mc_tick_eject_file() { printf '%s/%s.%s.ejected' "$MC_TICK_DIR" "$(mc_safe_name "${MC_TICK_ID:-notick}")" "$(mc_safe_name "$1")"; }
mc_tick_eject_note() { mkdir -p "$MC_TICK_DIR" 2>/dev/null; echo "$2 $3" >> "$(mc_tick_eject_file "$1")"; }
mc_tick_ejected_now() { grep -qxF "$2 $3" "$(mc_tick_eject_file "$1")" 2>/dev/null; }
mc_count_inc() { # mc_count_inc <project> <name> -> the new value
  local f; f=$(mc_count_file "$1"); mkdir -p "$MC_TICK_DIR" 2>/dev/null
  ( flock 9 2>/dev/null
    local n; n=$(_mc_count_read "$f" "$2"); n=$((n+1))
    _mc_count_set "$f" "$2" "$n"; printf '%s' "$n"
  ) 9>>"$f" 2>/dev/null
}

# --- BH-1486 follow-up: two digests and a read counter ----------------------
#
# _mc_digest_stream — a short, stable digest of STDIN. sha1 where there is one,
# cksum where there is not: a low-quality digest still separates the things
# below, it is only a worse hash.
_mc_digest_stream() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum | cut -c1-12
  elif command -v shasum >/dev/null 2>&1; then shasum -a 1 | cut -c1-12
  else cksum | tr -dc '0-9' | cut -c1-12
  fi
}

# _mc_key_digest <string> — the same, for a key that arrives as an argument.
#
# WHY A MEMO KEY NEEDS ONE AND A PR LOCK DOES NOT. mc_safe_name maps every
# character outside [A-Za-z0-9._-] to `_`. That is fine for the names it was
# written for — a project slug and a PR NUMBER — and it is not fine for a memo
# key, because a memo key carries BRANCH names: `ticket/x_y` and `ticket/x/y`
# are two branches that can both exist in one repo and both flatten to
# `ticket_x_y`. One stacked child would be served the OTHER branch's parent
# state, and the stacked arm acts on that answer by retargeting the PR — so the
# child lands on the wrong base, silently, and only on the repos unlucky enough
# to hold both names. The readable safe name stays, so an operator reading
# state/merge-conductor/tick/ can still tell what a file is about; the digest is
# what makes two different keys two different files.
_mc_key_digest() { printf '%s' "${1:-}" | _mc_digest_stream; }

# mc_tick_reads — "<reads> <counted> <cached>" for THIS project's tick, read out
#   of the ETag counter file the project subshell armed (GH_ETAG_COUNT_FILE,
#   bin/lib/gh-rest-etag.sh). Always three numbers, so a caller never has to
#   guard the split.
#
#   WHY IT IS NOT THE READ-MEMO LINE. `READ-MEMO … stack_hits= ci_skipped=
#   scan_skipped=` counts memo HITS — how often the conductor decided not to
#   ask. That is the right number for judging the memo and the wrong one for
#   judging the BILL: a hit on a read GitHub would have answered 304 saves a
#   round trip and no quota at all, and BH-1486's acceptance is counted calls
#   per tick. These three say what the tick actually spent.
#
#   WHAT EACH NUMBER IS:
#     counted  gh_rest GETs GitHub answered 2xx. These spend the installation's
#              6,600/h bucket, and they are the number the ticket is judged on.
#     cached   gh_rest GETs that answered 304 against a stored ETag. GitHub does
#              not count a 304 against the primary rate limit, so these are free.
#     reads    counted + cached: the reads the lane WANTED to make.
#
#   WHAT IT DOES NOT SEE, stated rather than papered over: a gh_rest GET GitHub
#   answered 403/429/404/5xx writes no counter line (the counter is armed inside
#   gh_rest's 2xx and 304 arms), and neither does a non-GET write nor a raw
#   `gh api` read such as mc_ci_state's actions/runs. So `counted` is a FLOOR on
#   what this tick spent, never a ceiling; logs/gh-rate.log and logs/ALERTS.log
#   are where a failed read shows up.
mc_tick_reads() {
  local cf fetched=0 cached=0
  cf="${GH_ETAG_COUNT_FILE:-}"
  if [ -n "$cf" ] && [ -r "$cf" ]; then
    fetched=$(grep -c '^fetched$' "$cf" 2>/dev/null) || fetched=0
    cached=$(grep -c '^cached$'  "$cf" 2>/dev/null) || cached=0
  fi
  case "$fetched" in ''|*[!0-9]*) fetched=0 ;; esac
  case "$cached"  in ''|*[!0-9]*) cached=0  ;; esac
  printf '%s %s %s' "$((fetched + cached))" "$fetched" "$cached"
}

# mc_tick_budget_take <project> <kind> <limit> — rc 0 when this worker may spend
#   one unit of <kind> (rebase|rereview|merge) this tick, rc 1 when the project's
#   budget is gone. The read and the increment are ONE critical section, so two
#   workers can never both take the last unit.
mc_tick_budget_take() {
  local p="$1" k="$2" lim="${3:-0}" f
  case "$lim" in ''|*[!0-9]*) lim=0 ;; esac
  [ "$lim" -gt 0 ] || return 1
  f=$(mc_count_file "$p"); mkdir -p "$MC_TICK_DIR" 2>/dev/null
  ( flock 9 2>/dev/null
    local n; n=$(_mc_count_read "$f" "budget-$k")
    [ "$n" -lt "$lim" ] || exit 1
    _mc_count_set "$f" "budget-$k" "$((n+1))"
  ) 9>>"$f" 2>/dev/null
}
# mc_tick_budget_give <project> <kind> — hand a taken unit back, for the action
#   that then did not happen (a spawn refused at its parallel cap, a merge lock
#   this worker could not get). Without it a refusal would cost the project a
#   rebase it never ran.
mc_tick_budget_give() {
  local f; f=$(mc_count_file "$1"); [ -f "$f" ] || return 0
  ( flock 9 2>/dev/null
    local n; n=$(_mc_count_read "$f" "budget-$2")
    [ "$n" -gt 0 ] && _mc_count_set "$f" "budget-$2" "$((n-1))"
  ) 9>>"$f" 2>/dev/null
  return 0
}
# mc_day_budget_take <project> <kind> <limit> — spend one unit of the D1
#   daily counter mc_budget (POST /api/mc-budget/take, BH-6887). The read and
#   the spend are ONE statement in the worker, so two boxes can never both take
#   the last unit. rc 0 = granted, and it prints the worker's UTC day for the
#   give; rc 3 = the day's limit is spent; rc 1 = anything else (no jobs
#   client, a transport failure, a non-200, an answer without a boolean
#   `granted` or a day). An outage is never rc 3.
mc_day_budget_take() {
  local out g day
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [[ ${3:-} =~ ^[1-9][0-9]*$ ]] || return 1
  _mc_lease_lib >/dev/null 2>&1
  declare -F _jobs_req >/dev/null || return 1
  out=$(_jobs_req POST /api/mc-budget/take \
    "$(jq -nc --arg p "$1" --arg k "$2" --argjson l "$3" '{project:$p,kind:$k,limit:$l}')") || return 1
  g=$(jq -r 'if .granted == true then "yes" elif .granted == false then "no" else "" end' <<<"$out" 2>/dev/null)
  day=$(jq -r '.day // empty' <<<"$out" 2>/dev/null)
  [[ $day =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  case "$g" in
    yes) printf '%s\n' "$day" ;;
    no)  return 3 ;;
    *)   return 1 ;;
  esac
}
# mc_day_budget_give <project> <kind> <day> — hand one unit of that day back,
#   for the spend that then did not happen. rc 0 = given, rc 1 otherwise. A
#   give that fails leaves the counter one high, which spends less.
mc_day_budget_give() {
  local out
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [[ ${3:-} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  _mc_lease_lib >/dev/null 2>&1
  declare -F _jobs_req >/dev/null || return 1
  out=$(_jobs_req POST /api/mc-budget/give \
    "$(jq -nc --arg p "$1" --arg k "$2" --arg d "$3" '{project:$p,kind:$k,day:$d}')") || return 1
  [ "$(jq -r '.given == true' <<<"$out" 2>/dev/null)" = true ]
}
# mc_tick_budget_left <project> <kind> <limit> — the CHEAP read the arms use as a
#   guard before doing any work at all. It is not a claim: the claim is the take.
mc_tick_budget_left() {
  local lim="${3:-0}"
  case "$lim" in ''|*[!0-9]*) lim=0 ;; esac
  [ "$lim" -gt 0 ] || return 1
  [ "$(mc_count_get "$1" "budget-$2")" -lt "$lim" ]
}

# mc_tick_metrics <project> <started-epoch> [finished-epoch]
#   ONE structured line per project per tick, and the same numbers as JSON in
#   state/merge-conductor/tick-<project>.json (last tick only) for an SLO/DORA
#   reader. The human log lines are untouched — this is the line a machine reads,
#   and `secs` is the number the per-PR lock shard exists to stop mattering.
#     prs       PRs of this project the tick looked at
#     locked    of those, skipped because another tick's worker holds that PR
#     merges    merged outright or handed to the repo's merge queue by this tick
#     rebases   detached rebases spawned (or run inline under MC_DETACHED_REBASE=0)
#     rereviews detached head-bound re-reviews spawned
#     budget_exhausted  actions refused because the project's per-tick budget was spent
#     stale_head_rerun_skipped  CI writes refused because the PR moved off the tick's head (BH-3804)
#   The land arm (BH-870) keeps six more counters on these same files —
#   landspawned, landcurrent, landconflict, landskipped, landdeferred,
#   landwould — and bin/merge-conductor.sh prints them in its own `LAND … ` line
#   instead of here, because they describe ONE event (a base sha that moved) and
#   not the tick. `rebases` counts a land rebase too: it is a rebase.
mc_tick_metrics() {
  local p="$1" t0="${2:-0}" t1="${3:-}" secs prs locked merges rebases rereviews exh f tmp
  local reads=0 counted=0 cachedr=0 sk
  [ -n "$t1" ] || t1=$(mc_now)
  case "$t0" in ''|*[!0-9]*) t0="$t1" ;; esac
  secs=$((t1 - t0)); [ "$secs" -ge 0 ] || secs=0
  prs=$(mc_count_get "$p" prs);           locked=$(mc_count_get "$p" locked)
  merges=$(mc_count_get "$p" merges);     rebases=$(mc_count_get "$p" rebases)
  rereviews=$(mc_count_get "$p" rereviews); exh=$(mc_count_get "$p" exhausted)
  sk=$(mc_count_get "$p" stale_head_rerun_skipped)
  read -r reads counted cachedr <<<"$(mc_tick_reads)"
  # The pause prefix (BH-1672): "PAUSED(merges) TICK …" on a tick a pause held.
  # Guarded because five other lanes source this lib without bin/lib/pause.sh.
  mc_log "$(command -v pause_label >/dev/null 2>&1 && pause_label "$p")TICK $p tick=${MC_TICK_ID:-notick} secs=$secs prs=$prs locked=$locked merges=$merges rebases=$rebases rereviews=$rereviews budget_exhausted=$exh reads=$reads counted=$counted cached=$cachedr stale_head_rerun_skipped=$sk"
  mkdir -p "$MC_STATE_DIR" 2>/dev/null
  f="$MC_STATE_DIR/tick-$(mc_safe_name "$p").json"; tmp="$f.tmp"
  jq -nc --arg t "${MC_TICK_ID:-notick}" --arg p "$p" --argjson st "$t0" --argjson fin "$t1" \
     --argjson secs "$secs" --argjson prs "$prs" --argjson locked "$locked" --argjson m "$merges" \
     --argjson rb "$rebases" --argjson rr "$rereviews" --argjson exh "$exh" \
     --argjson rd "$reads" --argjson rc "$counted" --argjson rcc "$cachedr" --argjson sk "$sk" \
     '{tick:$t,project:$p,started_at:$st,finished_at:$fin,duration_secs:$secs,prs_seen:$prs,prs_locked:$locked,merges:$m,rebases:$rb,rereviews:$rr,budget_exhausted:$exh,reads:$rd,reads_counted:$rc,reads_cached:$rcc,stale_head_rerun_skipped:$sk}' \
     > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
  return 0
}
# mc_pr_lock_gc — the per-PR lock FILES of PRs nothing has ticked in
#   MC_PR_LOCK_TTL_DAYS. One empty file per PR the conductor has ever seen is
#   one file per PR for ever, and locks/ is a flat directory shared with every
#   other lane on the box.
#
#   EACH IS DELETED UNDER ITS OWN LOCK, which is the only safe way to unlink a
#   lock file: a worker that opened this path a moment ago holds the same inode,
#   so taking the lock first means the name never disappears mid-tick — and
#   `-n` means this GC never waits on a live worker, it just leaves that file
#   for the next run. The merge and git locks (one per project, not per PR) do
#   not match the pattern and are never collected.
mc_pr_lock_gc() {
  local f
  [ -d "$MC_LOCK_DIR" ] || return 0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    flock -n "$f" rm -f "$f" 2>/dev/null || true
  done < <(find "$MC_LOCK_DIR" -maxdepth 1 -type f -name 'merge-conductor-*-[0-9]*.lock' -mtime "+${MC_PR_LOCK_TTL_DAYS:-14}" 2>/dev/null)
  return 0
}

# mc_tick_gc — counter files from earlier ticks. One tick writes a handful of
#   tiny files; a day of them is noise, a year of them is a directory nobody can
#   list. The metrics JSON is keyed by project and overwritten, so it stays.
mc_tick_gc() {
  [ -d "$MC_TICK_DIR" ] || return 0
  find "$MC_TICK_DIR" -maxdepth 1 -type f -mtime +0 -delete 2>/dev/null
  return 0
}

# mc_budget <STATE> -> seconds a PR may sit in that state before ONE alert
# (docs/MERGE-CONDUCTOR.md section 5). 0 = immediately. Terminal states never page
# by age; CLOSED pages once through mc_closed_alert instead.
mc_budget() {
  case "$1" in
    WAIT_CI) echo 1800 ;; WAIT_REVIEW) echo 3600 ;; HEAD_MOVED) echo 1800 ;;
    NEEDS_REBASE) echo 1800 ;; REBASING) echo 1200 ;; BLOCKED_HUMAN) echo 0 ;;
    # RED_TWICE ages like BLOCKED_HUMAN and pages like it too — which, for a
    # reason the resolver owns, means it does not page at all: mc_budget_check
    # logs the hand-off line and bin/blocked-resolver.sh alerts once, on
    # ABANDONED. The stuck detector (mc_stuck_check) is what pages if the
    # resolver never drains it.
    RED_TWICE) echo 0 ;;
    # ABANDONED is terminal and already alerted once, by the resolver, with the
    # whole attempt list. Ageing it would page forever about work nothing is
    # doing any more.
    ABANDONED) echo -1 ;;
    READY) echo 900 ;;
    # QUEUED is GitHub's own merge queue holding the PR. A queue with
    # max_entries_to_build 5 legitimately takes a while and an ALLGREEN group
    # that ejects a sibling rebuilds the ones behind it, so the budget is an
    # hour: long enough not to page on a healthy queue, short enough that a
    # WEDGED one (the shape nothing else in the fleet can see) still pages.
    QUEUED) echo 3600 ;;
    # NEEDS_HUMAN_VERDICT (BH-3777) waits on a person: la_human_needed beats on
    # entry in actions mode, and an hour on is one page whose reason carries the command — the
    # same hour QUEUED gave #3753/#3758, now in words that say what moves it.
    NEEDS_HUMAN_VERDICT) echo 3600 ;;
    # STACKED_WAIT is a child PR based on its parent's branch (2026-09-14,
    # stacked child builds). It is SUPPOSED to sit there: it waits for the
    # parent to merge, which is one chain level — 60-75 min on project-5 — plus
    # whatever the parent's own review costs. Four hours is long enough that a
    # healthy stack never pages and short enough that a parent nothing is
    # driving any more still surfaces.
    STACKED_WAIT) echo 14400 ;;
    *) echo -1 ;;
  esac
}


# --- BH-1025.0 / BH-2311.1: the attempts ledger is `pr_attempts` rows --------
# $MC_ATTEMPTS is a 396 KB file on ONE box that says which rebases and which
# re-reviews the fleet has already paid for. Lose it — a hub wipe, a state
# restore, the same PR handled from a different box — and every open PR is
# offered one more of each. So an attempt is a `pr_attempts` row, behind the
# `pr-state-rows` flag. Since BH-2311.1 (BH-2357) the ROW is written first and
# asked first, and the file is its warm cache. The file answers on its own only
# with the flag down, for a line no PR keys, or while the worker is down.
#
# WHAT IS NOT NEGOTIABLE HERE: an unreachable worker is never an answer by
# itself, neither "attempted" nor "not attempted". A read the worker cannot
# answer is answered by the FILE (a file hit is attempted, a file miss is not)
# and latches the twin off for the tick. Flag down is today's file path, byte
# for byte.

# mc_attempt_pr_key <line> -> "repo\tnumber\tkind\tsha"; rc 1 for any line that
# is not keyed on a PR. Only `<kind> <owner/repo>#<number> <sha…>` becomes a
# row; `identityalert hub gh-app 20260922`, `dvread project-5 abc123` and
# friends share the file and are file-only, because there is no PR to key them
# on. The sha is the whole TAIL, so `lanedown KEY HEAD EPOCH` round-trips.
mc_attempt_pr_key() {
  local line="${1:-}" kind key rest
  # A leading blank is not a line any writer here produces; refusing it keeps
  # `read`'s whitespace-stripping from inventing a key for a malformed line.
  case "$line" in ''|[[:space:]]*) return 1 ;; esac
  read -r kind key rest <<< "$line"
  [ -n "$kind" ] && [ -n "$rest" ] || return 1
  [[ "$key" =~ ^[^#[:space:]]+#[0-9]+$ ]] || return 1
  printf '%s\t%s\t%s\t%s' "${key%#*}" "${key##*#}" "$kind" "$rest"
}

# mc_attempt_put <line> [row-line] — the ROW first, then the FILE line
# (byte-identical to today), always. The row's rc is ignored past one log line
# a tick (mc_attempt_row_put): a lane must not fail because the side channel
# blinked. [row-line] is what the row stores when it is not <line> itself
# (mc_attempt_put_n's ` #<n>` counter suffix).
mc_attempt_put() {
  mc_attempt_row_put "${2:-$1}"
  echo "$1" >> "$MC_ATTEMPTS"
}

# mc_attempt_row_put <line> — the ROW half of mc_attempt_put, on its own, for a
# record whose file half is not attempts.txt (BH-1564: the head-lag record's
# file is state/merge-conductor/head-lag/<pr>, a read-through cache of its
# `headlag` rows). Same gate, same per-tick latch, always rc 0. A failed PUT is
# logged ONCE a tick (the noclobber `<tick>.pr-rows-putfail` marker; once a
# process with no MC_TICK_ID) and does NOT latch the twin off: the file line is
# still written, and the next read asks the row again.
mc_attempt_row_put() {
  type pr_rows_on >/dev/null 2>&1 && pr_rows_on || return 0
  local k repo num kind sha tick=""
  k=$(mc_attempt_pr_key "$1") || return 0
  if [ -n "${MC_TICK_ID:-}" ]; then
    tick="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID")"
    # Another worker of this tick already saw the worker down (mc_attempt_has).
    [ -e "$tick.pr-rows-down" ] && { pr_rows_trip; return 0; }
  fi
  IFS=$'\t' read -r repo num kind sha <<< "$k"
  if pr_attempt_put "$repo" "$num" "$kind" "$sha" >/dev/null 2>&1; then
    [ -n "$tick" ] && _mc_memo_add "$repo" "$num" "$kind" "$sha"
    return 0
  fi
  if [ -n "$tick" ]; then
    mkdir -p "$MC_TICK_DIR" 2>/dev/null
    ( set -C; : > "$tick.pr-rows-putfail" ) 2>/dev/null || return 0
    mc_log "pr-state-rows row write failed for '$1' — the file line is still written (logged once for tick $MC_TICK_ID)"
  else
    [ -n "${_MC_ROW_PUTFAIL:-}" ] && return 0
    _MC_ROW_PUTFAIL=1
    mc_log "pr-state-rows row write failed for '$1' — the file line is still written (logged once for this process)"
  fi
  return 0
}

# --- BH-4156: one attempt read per repo per tick -----------------------------
# Every mc_attempt_has / mc_attempt_rows of a PR-keyed line was its own GET
# /api/pr-attempts, per PR per line. tick_project now calls mc_tick_prefetch
# once per repo, before the workers start: ONE pr_attempt_batch read of the
# attempt rows of every PR the tick works, kept as a per-tick memo in
# MC_TICK_DIR:
#   <tick>.batch-<repo>.tsv        `<number>\t<kind>\t<sha>`, the route's order
#   <tick>.batch-<repo>.add        rows this tick wrote (mc_attempt_row_put and
#                                  the back-fill), oldest first
#   <tick>.batch-<repo>.covered    the numbers the answer covers
#   <tick>.batch-<repo>.uncovered  numbers mc_attempt_clear took back
# A PR is answered from the memo only when it is covered and not uncovered.
# Anything else reads per PR, exactly as before: no MC_TICK_ID, the flag down,
# a 404 (route not deployed), an outage, a number the route's row cap left
# out. Appends are one short line each, so parallel workers never lose one.
# mc_tick_gc deletes the memo files with the other tick files.

# _mc_memo_base <repo> — the memo path prefix for this tick; rc 1 with no tick.
_mc_memo_base() {
  [ -n "${MC_TICK_ID:-}" ] && [ -n "${1:-}" ] || return 1
  printf '%s/%s.batch-%s' "$MC_TICK_DIR" "$(mc_safe_name "$MC_TICK_ID")" "$(mc_safe_name "$1")"
}

# _mc_memo_clear_stamp <repo> <num> — the CROSS-TICK clear stamp. Keyed ticks
# run beside the full tick, and a worker can start minutes after its tick's
# prefetch. A clear in tick B un-covers the PR in B's memo only, so A's memo
# would still answer "attempted" from its snapshot and warm the cleared line
# back. mc_attempt_clear touches this stamp (no MC_TICK_ID needed), and
# _mc_memo_covered refuses a PR whose stamp is not older than its own snapshot.
# mc_tick_gc prunes stamps with the other tick files.
_mc_memo_clear_stamp() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  printf '%s/memo-cleared.%s.%s' "$MC_TICK_DIR" "$(mc_safe_name "$1")" "$(mc_safe_name "$2")"
}

# _mc_memo_covered <repo> <num> — rc 0 when this tick's memo answers that PR.
_mc_memo_covered() {
  local b c
  b=$(_mc_memo_base "${1:-}") || return 1
  [ -f "$b.covered" ] && grep -qxF -- "${2:-}" "$b.covered" || return 1
  [ -f "$b.uncovered" ] && grep -qxF -- "$2" "$b.uncovered" && return 1
  # A clear at or after the snapshot (any tick): the PR reads per PR.
  c=$(_mc_memo_clear_stamp "$1" "$2") || return 1
  [ -e "$c" ] && ! [ "$c" -ot "$b.covered" ] && return 1
  return 0
}

# _mc_memo_rows <repo> <num> [kind] — the shas of that PR's rows (one kind, or
# every kind when empty), newest first: this tick's own writes, newest first,
# then the route's rows in the route's order. The order GET /api/pr-attempts
# answers in.
_mc_memo_rows() {
  local b
  b=$(_mc_memo_base "$1") || return 1
  { if [ -f "$b.add" ]; then tac "$b.add"; fi; if [ -f "$b.tsv" ]; then cat "$b.tsv"; fi; } 2>/dev/null \
    | N="$2" K="${3:-}" awk -F'\t' '$1 == ENVIRON["N"] && (ENVIRON["K"] == "" || $2 == ENVIRON["K"]) { print $3 }'
}

# _mc_memo_has <repo> <num> <kind> <sha> — rc 0 when the memo holds that row.
_mc_memo_has() {
  local b
  b=$(_mc_memo_base "$1") || return 1
  local f
  for f in "$b.tsv" "$b.add"; do
    [ -f "$f" ] && grep -qxF -- "$2"$'\t'"$3"$'\t'"$4" "$f" && return 0
  done
  return 1
}

# _mc_memo_add <repo> <num> <kind> <sha> — a row this tick wrote, so a later
# read in the same tick sees it. Only for a covered PR, and never twice (the
# PUT dedupes on the same key, so the DB keeps the first row's place).
_mc_memo_add() {
  local b
  _mc_memo_covered "$1" "$2" || return 0
  case "$3$4" in *$'\t'*|*$'\n'*|*$'\r'*) return 0 ;; esac
  _mc_memo_has "$1" "$2" "$3" "$4" && return 0
  b=$(_mc_memo_base "$1") || return 0
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$b.add" 2>/dev/null
  return 0
}

# mc_tick_prefetch <slug> <row…> — the one batch read for this repo this tick.
# <row> is a tick_project row, its number in field 1. Always rc 0: a 404 or an
# outage logs one line and leaves every PR to its per-PR read, which decides
# (and latches the twin off itself if the worker is really down).
mc_tick_prefetch() {
  local slug="${1:-}" b r rc
  local -a nums=()
  shift
  [ -n "$slug" ] && [ -n "${MC_TICK_ID:-}" ] || return 0
  type pr_rows_on >/dev/null 2>&1 && pr_rows_on || return 0
  declare -F pr_attempt_batch >/dev/null 2>&1 || return 0
  [ -e "$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").pr-rows-down" ] && return 0
  for r in "$@"; do r="${r%%$'\t'*}"; [[ "$r" =~ ^[0-9]+$ ]] && nums+=("$r"); done
  [ "${#nums[@]}" -gt 0 ] || return 0
  mkdir -p "$MC_TICK_DIR" 2>/dev/null
  b=$(_mc_memo_base "$slug") || return 0
  rm -f "$b.tsv" "$b.add" "$b.covered" "$b.uncovered" 2>/dev/null
  pr_attempt_batch "$slug" "$b.tsv.tmp" "$b.covered.tmp" "${nums[@]}"; rc=$?
  case "$rc" in
    0|1)
      # The rows land before the covered list: a reader that sees a number
      # covered always sees its rows.
      mv -f "$b.tsv.tmp" "$b.tsv" 2>/dev/null && mv -f "$b.covered.tmp" "$b.covered" 2>/dev/null
      [ "$rc" = 1 ] && mc_log "$slug: conductor-state batch read failed for part of ${#nums[@]} PR(s) — those PRs read per PR this tick" ;;
    2) mc_log "$slug: conductor-state route not deployed — per-PR reads this tick" ;;
  esac
  rm -f "$b.tsv.tmp" "$b.covered.tmp" 2>/dev/null
  return 0
}

# mc_attempt_has <line> — rc 0 when this line was already attempted, rc 1
# otherwise. With the flag up and a PR-keyed line the ROW is asked first:
#   rc 0 the row is there: attempted, and the file is warmed (never duplicated)
#   rc 2 a measured miss: the file decides, and a file hit back-fills the row
#        (rc ignored; the next ask then hits the row)
#   else an outage: the twin is latched off (this process and this tick) and the
#        FILE decides — never "attempted" or "not attempted" by default.
# Flag down, no PR key, or a tail ending ` #<n>` (the shape of a mc_attempt_put_n
# counter row, which a literal head must never read as a hit): the file alone.
#
# PER TICK (BH-1831). The conductor runs every PR as `pr_worker &`, so the
# process latch dies with the worker that tripped it. With MC_TICK_ID set two
# tick files in MC_TICK_DIR carry it across workers: `<tick>.pr-rows-down`
# latches the whole tick off after one outage (created with noclobber, so only
# its creator logs), and `<tick>.attempt-miss` memoises measured misses so a
# line costs at most one GET a tick. Both still consult the FILE, so the memo
# can never hide a fresh mc_attempt_put. Both die with the tick (a new
# MC_TICK_ID; mc_tick_gc prunes them). No MC_TICK_ID (blocked-resolver and
# other callers): one GET per call.
mc_attempt_has() {
  local k="" repo num kind sha rc tick=""
  if type pr_rows_on >/dev/null 2>&1 && pr_rows_on; then k=$(mc_attempt_pr_key "$1") || k=""; fi
  [[ "$k" =~ \ \#[0-9]+$ ]] && k=""
  if [ -z "$k" ]; then
    grep -qxF "$1" "$MC_ATTEMPTS" && return 0
    return 1
  fi
  if [ -n "${MC_TICK_ID:-}" ]; then
    tick="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID")"
    [ -e "$tick.pr-rows-down" ] && pr_rows_trip
    if [ -e "$tick.pr-rows-down" ] || { [ -f "$tick.attempt-miss" ] && grep -qxF "$1" "$tick.attempt-miss"; }; then
      grep -qxF "$1" "$MC_ATTEMPTS" 2>/dev/null && return 0
      return 1
    fi
    mkdir -p "$MC_TICK_DIR" 2>/dev/null
  fi
  IFS=$'\t' read -r repo num kind sha <<< "$k"
  if [ -n "$tick" ] && _mc_memo_covered "$repo" "$num"; then
    # BH-4156: this tick's batch read covers the PR. A memo hit is the row
    # answering, a memo miss is the measured miss: the same two arms below.
    if _mc_memo_has "$repo" "$num" "$kind" "$sha"; then rc=0; else rc=2; fi
  else
    # Called in THIS shell, never through `$( )`: pr_rows_trip has to latch in
    # a shell that outlives the call.
    pr_attempt_has "$repo" "$num" "$kind" "$sha" >/dev/null 2>&1; rc=$?
  fi
  case "$rc" in
    0) grep -qxF "$1" "$MC_ATTEMPTS" 2>/dev/null || echo "$1" >> "$MC_ATTEMPTS"
       return 0 ;;
    2) if grep -qxF "$1" "$MC_ATTEMPTS" 2>/dev/null; then
         pr_attempt_put "$repo" "$num" "$kind" "$sha" >/dev/null 2>&1 \
           && [ -n "$tick" ] && _mc_memo_add "$repo" "$num" "$kind" "$sha"
         return 0
       fi
       [ -n "$tick" ] && echo "$1" >> "$tick.attempt-miss"
       return 1 ;;
    *) pr_rows_trip
       if [ -n "$tick" ] && ( set -C; : > "$tick.pr-rows-down" ) 2>/dev/null; then
         mc_log "pr-state-rows unreachable — row reads/writes latched off for tick $MC_TICK_ID"
       fi
       grep -qxF "$1" "$MC_ATTEMPTS" 2>/dev/null && return 0
       return 1 ;;
  esac
}

# mc_attempt_rows <kind> <key> <out-file> — every row of <kind> for PR <key>,
# its sha tail one per line in <out-file> (BH-1564). rc 0 rows | rc 2 a
# MEASURED none | rc 1 rows not in use (flag down, bad kind/key/out-file) |
# rc 3 the worker could not answer (this call, this tick's latch, or this
# process's trip), with <out-file> left EMPTY. rc 3 is its own answer
# (BH-1891): an outage read as rc 1 looked like "never kicked" to the head-lag
# check. An outage latches the twin off exactly as mc_attempt_has does. Call it
# as a plain command, never through `$( )`. <kind> `*` lists every kind the PR
# has (BH-2357, read_memo_fp).
mc_attempt_rows() {
  local kind="$1" key="$2" out="$3" rc tick="" lk
  lk="$kind"; [ "$kind" = '*' ] && lk=""
  : > "$out" 2>/dev/null || return 1
  # Asked BEFORE pr_rows_on, which answers rc 1 after a trip too.
  [ "${_PR_ROWS_DOWN:-0}" = 1 ] && return 3
  type pr_rows_on >/dev/null 2>&1 && pr_rows_on || return 1
  [ -n "$kind" ] && [[ "$key" =~ ^[^#[:space:]]+#[0-9]+$ ]] || return 1
  if [ -n "${MC_TICK_ID:-}" ]; then
    tick="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID")"
    [ -e "$tick.pr-rows-down" ] && { pr_rows_trip; return 3; }
    mkdir -p "$MC_TICK_DIR" 2>/dev/null
    # BH-4156: a PR this tick's batch read covers is answered from the memo.
    if _mc_memo_covered "${key%#*}" "${key##*#}"; then
      _mc_memo_rows "${key%#*}" "${key##*#}" "$lk" > "$out"
      [ -s "$out" ] && return 0
      return 2
    fi
  fi
  pr_attempt_list "${key%#*}" "${key##*#}" "$lk" > "$out" 2>/dev/null; rc=$?
  case "$rc" in
    0) return 0 ;;
    2) : > "$out"; return 2 ;;
    *) : > "$out"; pr_rows_trip
       if [ -n "$tick" ] && ( set -C; : > "$tick.pr-rows-down" ) 2>/dev/null; then
         mc_log "pr-state-rows unreachable — row reads/writes latched off for tick $MC_TICK_ID"
       fi
       return 3 ;;
  esac
}

# --- BH-2311.0 / BH-2311.1: attempt verbs, rows first -------------------------
# What the call sites compute today with grep/awk, as four named verbs. With
# the flag up and a PR key they read the `pr_attempts` ROWS (BH-2357), turned
# back into the file lines they stand for; a measured none (rc 2) is an answer,
# zero, even with a stale file line. $MC_ATTEMPTS answers only when the rows
# cannot (flag down, not a PR key, an outage — mc_attempt_rows rc 1/3).
# <kinds> is one kind or a `|` list. Every match is field-exact on $1/$2 (and on
# $3, or on the whole tail from $3 on, given a head): `requeued` never matches
# `requeued2`, `o/r#12` never matches `o/r#123`, head `100` never matches
# `0100`. Values reach awk through ENVIRON, never -v.
_mc_attempt_awk() {  # <kinds> <key> <head|""> <awk action> [file, default $MC_ATTEMPTS]
  K="$1" KEY="$2" H="$3" awk 'function tl(s) { sub(/^[^ ]+ [^ ]+ /, "", s); return s }
    BEGIN { n = split(ENVIRON["K"], a, "|"); for (i = 1; i <= n; i++) w[a[i]] = 1 }
    ($1 in w) && $2 "" == ENVIRON["KEY"] && (ENVIRON["H"] == "" || $3 "" == ENVIRON["H"] || tl($0) == ENVIRON["H"]) {'"$4"'}' "${5:-$MC_ATTEMPTS}" 2>/dev/null
}

# _mc_attempt_row_lines <kinds> <key> <out> — the ROWS of every kind as the
# file lines they stand for, `<kind> <key> <sha>` with a mc_attempt_put_n
# ` #<n>` suffix stripped: each kind oldest first (the route lists newest
# first), kinds in the order given. rc 0 lines | rc 2 a measured none for every
# kind | rc 1 rows not in use | rc 3 some kind went unanswered, <out> EMPTY.
# A plain command, never `$( )`, for the same latch reason as mc_attempt_rows.
_mc_attempt_row_lines() {
  local key="$2" out="$3" k rows rc any=2
  : > "$out" 2>/dev/null || return 1
  rows=$(mktemp 2>/dev/null) || return 3
  for k in ${1//|/ }; do
    mc_attempt_rows "$k" "$key" "$rows"; rc=$?
    case "$rc" in
      0) any=0
         tac "$rows" | K="$k" KEY="$key" awk '{ sub(/ #[0-9]+$/, ""); print ENVIRON["K"] " " ENVIRON["KEY"] " " $0 }' >> "$out" ;;
      2) : ;;
      *) rm -f "$rows"; : > "$out"; return "$rc" ;;
    esac
  done
  rm -f "$rows"
  return "$any"
}

# _mc_attempt_read <kinds> <key> <head|""> <awk action> — _mc_attempt_awk over
# the rows when they answer (rc 0/2), over $MC_ATTEMPTS when they cannot.
_mc_attempt_read() {
  local f="" rc=1
  if type pr_rows_on >/dev/null 2>&1 && pr_rows_on && f=$(mktemp 2>/dev/null); then
    _mc_attempt_row_lines "$1" "$2" "$f"; rc=$?
  fi
  case "$rc" in
    0|2) _mc_attempt_awk "$1" "$2" "$3" "$4" "$f" ;;
    *)   _mc_attempt_awk "$1" "$2" "$3" "$4" ;;
  esac
  [ -n "$f" ] && rm -f "$f"
  return 0
}

# mc_attempt_lines <kinds> <key> <out-file> — every matching WHOLE line in
# <out-file>: from the rows, grouped by kind in the order given and oldest first
# inside a kind; from the file, file order. rc 0 lines | rc 2 a measured none
# (a missing ledger is "nothing written yet", as `grep -c … || true` reads it)
# | rc 1 bad args or an unwritable <out-file>. Call it as a plain command, never
# through `$( )`.
mc_attempt_lines() {
  local kinds="${1:-}" key="${2:-}" out="${3:-}"
  [ -n "$kinds" ] && [ -n "$key" ] && { : > "$out"; } 2>/dev/null || return 1
  _mc_attempt_read "$kinds" "$key" "" 'print' > "$out"
  [ -s "$out" ] || return 2
}

# mc_attempt_count <kinds> <key> [head] — the number of matching lines (rows
# first, see above); 0 on a measured none, a missing/unreadable ledger or empty
# args, as the old greps print. A head with a space in it is matched against
# the whole tail (`lanefail KEY HEAD EPOCH` counts per epoch). Always rc 0.
mc_attempt_count() {
  local n=""
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && n=$(_mc_attempt_read "$1" "$2" "${3:-}" 'c++} END {print c+0')
  echo "${n:-0}"
}

# mc_attempt_tail <kind> <key> <head> [first|last] — field 4 onward of the
# first (oldest) or last (default, newest) matching line, rows first as above,
# a row's ` #<n>` suffix stripped; nothing when none. rc 1, nothing printed, for
# a mode other than first/last.
mc_attempt_tail() {
  local mode="${4:-last}" act
  case "$mode" in
    first) act='t = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ ?/, "", t); print t; exit' ;;
    last)  act='t = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ ?/, "", t); l = t; f = 1} END {if (f) print l' ;;
    *) return 1 ;;
  esac
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 0
  _mc_attempt_read "$1" "$2" "$3" "$act"
  return 0
}

# mc_attempt_put_n <kind> <key> <head…> — records one more `<kind> <key>
# <head…>` through mc_attempt_put (row first, then the file line, byte-identical
# to the line the call sites append today). The route's PUT dedupes on (repo,
# number, kind, sha), so three identical shas would be ONE row: with the rows
# in use the row's sha is `<head…> #<n>`, n = 1 + mc_attempt_count of that head,
# and the readers above strip the suffix. rc 1 unless kind, key and at least one
# head are given.
mc_attempt_put_n() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ $# -ge 3 ] || return 1
  local IFS=' ' n
  if type pr_rows_on >/dev/null 2>&1 && pr_rows_on && mc_attempt_pr_key "$*" >/dev/null; then
    n=$(mc_attempt_count "$1" "$2" "${*:3}")
    mc_attempt_put "$*" "$* #$(( n + 1 ))"
  else
    mc_attempt_put "$*"
  fi
  return 0
}

# mc_attempted <kind> <key> <sha> — rc 0 if this (kind, PR, sha) was already
# tried; otherwise records it and rc 1. One rebase / one re-review per head.
mc_attempted() {
  mc_attempt_has "$1 $2 $3" && return 0
  mc_attempt_put "$1 $2 $3"
  return 1
}

# THE REVIEW LANE'S OWN FAILURES ARE COUNTED, NOT ADJUDICATED (2026-09-16).
# mc_attempted is a one-shot: it answers "has this head had its one X", which is
# exactly right for a rebase and exactly wrong for an outage. A 429 session limit
# is true of every call this box makes for the next hour and says nothing about
# the PR, so the answer is to ask again on the next tick — bounded, so that a
# lane that is down for good ends in one actionable ALERTS line instead of an
# unbounded spend loop. MC_RR_LANEFAIL_MAX reads for a re-review of ONE head.
MC_RR_LANEFAIL_MAX="${MC_RR_LANEFAIL_MAX:-5}"

# --- THE CLAUDE LANE'S HEALTH IS AN INPUT TO THE DECISION (BH-1019) ----------
# Counting per (PR, head) alone spends the whole cap against ONE outage: a 429
# session limit is true of every call this box makes for the next hour, so five
# reads of the same head bought five copies of the same refusal. The count is
# therefore keyed on (PR, head, LANE-HEALTH EPOCH) — the cap is "reads of this
# head while the lane was in this condition", and a lane that recovers is a new
# condition worth asking under.
#
# WHERE THE HEALTH COMES FROM. bin/claude-auth-check.sh probes `claude -p ok`
# end to end every hour and keeps state/claude-auth-down.txt: one line per box
# whose claude lane is down, the line removed when it answers again. The
# conductor runs on the hub, so `hub` is the line that describes the lane its
# re-reviews are bought on. MC_LANE_BOX names it for a box that is not the hub.
MC_LANE_DOWN_FILE="${MC_LANE_DOWN_FILE:-$MC_H/state/claude-auth-down.txt}"
MC_LANE_BOX="${MC_LANE_BOX:-hub}"

# ...BUT THAT MONITOR ONLY SEES HALF THE OUTAGES, AND NOT THE HALF THIS LANE
# MEETS (BH-1019 review). classify_probe in bin/claude-auth-check.sh writes the
# box's line on POSITIVE AUTH EVIDENCE — `not logged in`, 401, the oauth
# shapes. A 429 session limit, a weekly or monthly spend limit and exhausted
# usage credits produce no `ok` and no auth evidence, so they are classified
# `inconclusive` and the file is deliberately never touched. That is exactly the
# #818 outage class, and it is the hub's state as this ships:
#   2026-09-19 08:51:09Z [auth] hub AUTH PROBE INCONCLUSIVE: You've hit your
#   monthly spend limit · … your weekly limit resets Sep 23
# with no `hub` line in the file. A lane-health signal that cannot see a quota
# outage would have left this whole change asleep during one.
#
# So the conductor keeps its OWN marker beside the monitor's, and it is written
# from evidence the conductor already holds: the reason line of a lane failure.
# Down on an ACCOUNT FACT (no headroom, a restricted-lane refusal, or the
# vendor's own exhaustion words), up the moment ANY job on this box comes back
# with a Claude answer. `mc_claude_lane_down` is the OR of the two, so the epoch
# counts transitions of both sources and the spawn gate covers both classes.
MC_LANE_DOWN_MARKER="${MC_LANE_DOWN_MARKER:-$MC_STATE_DIR/lane-down}"

# mc_lane_account_fact <reason> -> rc 0 when this lane-failure reason is a fact
#   about the ACCOUNT rather than about one call: it will be just as true on the
#   next tick, for every PR on this box, until somebody tops up or the window
#   resets. Same vocabulary bin/agent-call.sh's ladder classifies on
#   (LADDER_EXHAUST_REGEX), plus the two markers that mean nothing was called.
#   ACCOUNT_EXHAUST_REGEX is ADDITIVE to the built-in list (BH-1090): an override
#   ORs with the defaults, it does not replace them.
_MC_LANE_EXHAUST_BUILTIN='usage credits|usage limit|session limit|weekly limit|monthly limit|out of credits|credit balance|spend limit|hit your [a-z0-9 -]*limit|quota exceeded|limit reached'
MC_LANE_EXHAUST_RE="${MC_LANE_EXHAUST_RE:-${ACCOUNT_EXHAUST_REGEX:-}${ACCOUNT_EXHAUST_REGEX:+|}${_MC_LANE_EXHAUST_BUILTIN}}"
mc_lane_account_fact() {
  local why="${1:-}"
  case "$why" in
    *AGENT_CALL_NO_HEADROOM*) return 0 ;;
    *AGENT_CALL_REFUSED*runners-restricted*) return 0 ;;
  esac
  grep -qiE "$MC_LANE_EXHAUST_RE" < <(printf '%s' "$why")
}

# mc_lane_down_note <reason> — record the outage, ONCE, when the reason is an
#   account fact. The marker carries the reason so an operator reading state/
#   can see what is down without grepping a log.
# Path to the lane-down marker for an account. Default keeps the legacy path;
# routed accounts live in lane-down.d/ so a default-account canary ok does not
# clear them (BH-1090).
mc_lane_down_marker_path() {
  local acct="${1:-default}"
  # The name becomes a FILENAME. bin/account-pick.sh only ever prints path-safe
  # names, but this path must not depend on that: anything with a slash or a
  # leading dot is not a marker for an account we can name, so it is the
  # default account's marker rather than a write outside lane-down.d/.
  case "$acct" in ''|*/*|.*) acct=default ;; esac
  if [ "$acct" = "default" ]; then
    printf '%s\n' "$MC_LANE_DOWN_MARKER"
  else
    printf '%s.d/%s\n' "$MC_LANE_DOWN_MARKER" "$acct"
  fi
}

mc_lane_down_note() {
  local why="${1:-}" acct="${2:-default}"
  mc_lane_account_fact "$why" || return 1
  local mp
  mp=$(mc_lane_down_marker_path "$acct")
  [ -f "$mp" ] && return 0
  mkdir -p "$(dirname "$mp")" 2>/dev/null
  printf '%s\n' "$why" > "$mp" 2>/dev/null
  return 0
}

# mc_lane_up — a Claude model answered on this box, so whatever was exhausted is
#   not exhausted any more. Called from the one place that knows: mc_rereview,
#   past its lane-failure check. That is the EVENT the park and the cap wait for.
mc_lane_up() {
  local acct="${1:-default}" mp
  mp=$(mc_lane_down_marker_path "$acct")
  [ -f "$mp" ] && rm -f "$mp" 2>/dev/null
  return 0
}

# mc_claude_lane_down -> rc 0 when this box's claude lane is marked down, by
#   either source: the fleet monitor's line, or the conductor's own marker.
mc_claude_lane_down() {
  local mp
  mp=$(mc_lane_down_marker_path default)
  [ -f "$mp" ] && return 0
  grep -qxF "$MC_LANE_BOX" "$MC_LANE_DOWN_FILE" 2>/dev/null
}

# mc_lane_epoch -> a small integer that changes exactly when the claude lane
#   TRANSITIONS between up and down, and never otherwise. Not a clock and not
#   the marker's mtime (which moves when any other box is written): the epoch
#   is what makes "we already paid for this head under this outage" a fact that
#   expires on an event — the lane coming back — rather than on a timer.
#   Under the rereview lock, so two project workers cannot double-count a
#   transition; a failed write just leaves the epoch where it was, which costs
#   at most one extra read.
MC_LANE_ROUTED_RETRY_SECS="${MC_LANE_ROUTED_RETRY_SECS:-3600}"
case "$MC_LANE_ROUTED_RETRY_SECS" in ''|*[!0-9]*) MC_LANE_ROUTED_RETRY_SECS=3600 ;; esac

# mc_lane_down_for_account <account> -> rc 0 when that account's marker is set
#   and still current. The default account also checks the fleet monitor line so
#   existing behavior is preserved; a routed account's marker expires (and is
#   removed here) once it is older than MC_LANE_ROUTED_RETRY_SECS.
mc_lane_down_for_account() {
  local acct="${1:-default}" mp age
  mp=$(mc_lane_down_marker_path "$acct")
  # THE DEFAULT ACCOUNT IS UNCHANGED, and it is the only one that inherits the
  # fleet monitor's line — a routed account is a different credential and the
  # monitor says nothing about it. Asked through mc_claude_lane_down so there is
  # ONE definition of the default lane's health, and compared on the PATH so a
  # name mc_lane_down_marker_path had to reject cannot expire that marker.
  [ "$mp" = "$MC_LANE_DOWN_MARKER" ] && { mc_claude_lane_down; return $?; }
  [ -f "$mp" ] || return 1
  age=$(( $(date -u +%s) - $(mc_mtime "$mp") ))
  [ "$age" -lt "$MC_LANE_ROUTED_RETRY_SECS" ] && return 0
  # Expired: the release event. Removed here so the gate below lets exactly one
  # read through to ask, and that read decides what happens next.
  rm -f "$mp" 2>/dev/null
  return 1
}

# mc_lane_next_review_account -> prints the account that would pay for the next
#   `review claude <the resolved review model>` call. Falls back to `default`
#   when routing is off or account-pick cannot answer.
#
#   THE MODEL IS RESOLVED, NEVER A LITERAL (BH-998; rules/CLAUDE.md "AI model
#   config", pinned by tests/mc-rereview-model.bh-998-test.sh). review_model is
#   the same answer mc_rereview hands agent-call.sh, so the account this asks
#   about is the account that read actually buys. A literal here would ask
#   account-pick about one model while the read bought another, and the gate
#   would then consult the wrong account's marker — which is the whole defect
#   BH-1090 is closing, one layer up.
mc_lane_next_review_account() {
  local acct="default"
  if [ "${ACCOUNT_ROUTING:-0}" = 1 ] && [ -x "$MC_H/bin/account-pick.sh" ]; then
    local _pick="" _model=""
    _model=$(review_model "$MC_H" 2>/dev/null)
    _pick=$("$MC_H/bin/account-pick.sh" review claude "$_model" 2>/dev/null) &&
      acct=$(sed -n 's/^name=//p' <<<"$_pick" | head -1)
    [ -z "$acct" ] && acct="default"
  fi
  printf '%s\n' "$acct"
}

# mc_lane_down_for_next_review -> rc 0 when the account that would pay for the
#   next review is marked down. With routing off (or no account-pick.sh) the
#   account is `default`, so this asks exactly what mc_claude_lane_down asks:
#   the default marker OR the fleet monitor's line for this box.
mc_lane_down_for_next_review() {
  local acct
  acct=$(mc_lane_next_review_account)
  mc_lane_down_for_account "$acct"
}

mc_lane_epoch() {
  local f="$MC_STATE_DIR/lane-epoch" n=0 prev="" cur=up
  # THE ACCOUNT THAT WOULD PAY, not just the default one (BH-1090 review). The
  # cap this epoch bounds (MC_RR_LANEFAIL_MAX, and bin/blocked-resolver.sh's
  # BR_LANEFAIL_MAX) exists so reads spent against one outage are given back
  # when it ends. A routed-account outage that never moved the epoch stranded
  # both caps on a row nothing else would ever transition — the BH-1019 strand,
  # one layer down. Identical to mc_claude_lane_down whenever routing is off.
  mc_lane_down_for_next_review && cur=down
  if [ -r "$f" ]; then read -r n prev < "$f" 2>/dev/null || { n=0; prev=""; }; fi
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "${prev:-}" != "$cur" ]; then
    n=$(( n + 1 ))
    mkdir -p "$MC_RR_DIR" 2>/dev/null
    ( flock 9 2>/dev/null; printf '%s %s\n' "$n" "$cur" > "$f" ) 9>>"$MC_RR_DIR/.lock" 2>/dev/null
  fi
  printf '%s' "$n"
}

# The ledger row carries the epoch, so a count under one outage can never be
# read as a count under the next. Rows written before BH-1019 have two fields
# and match no epoch — they are simply not counted, which costs one cap's worth
# of reads once, on the deploy, and never again.
# Both go through the attempt verbs (BH-2357): the row is the record, and the
# count keys on the whole tail `<head> <epoch>`.
mc_rr_lanefail_note()  { mc_attempt_put_n lanefail "$1" "$2" "${3:-0}"; }
mc_rr_lanefail_count() { printf '%s' "$(mc_attempt_count lanefail "$1" "$2 ${3:-0}")"; }

# mc_attempt_clear <kind> <key> <sha> — FORGET one attempt, so a deterministic
#   re-kick may try it again (the stuck detector's NEEDS_REBASE/REBASING arm).
#   MC_ATTEMPTS is append-only everywhere else precisely because every project
#   ticks in its own subshell, so the one rewrite takes the same flock mc_row_put
#   takes, and it refuses to touch a file it cannot read rather than truncating
#   the fleet's whole attempt history.
#
#   THE ROW HAS TO GO TOO, AND IT IS THE HALF THAT BITES. This is the only
#   eraser in the ledger: the stuck detector (bin/merge-conductor.sh NEEDS_REBASE
#   arm), mc_handoff_human_release and the pool-rebase enqueue all clear a line
#   so that the next tick MAY act again. mc_attempt_has asks the row first and
#   warms the line back, so a file-only clear with the flag up forgets nothing: the respawn is skipped on that tick and on every tick
#   after it, silently, which is the BH-523/BH-764 failure this arm exists to
#   fix. Clearing the file empty is not an exit either — the whole point of the
#   twin is that the file can be lost while the rows stay.
mc_attempt_clear() {
  local tmp k repo num kind sha rc
  if [ -s "$MC_ATTEMPTS" ]; then
    tmp=$(mktemp) || return 1
    ( flock 9 2>/dev/null
      grep -vxF "$1 $2 $3" "$MC_ATTEMPTS" > "$tmp" 2>/dev/null
      [ -s "$tmp" ] || grep -qxF "$1 $2 $3" "$MC_ATTEMPTS" || { rm -f "$tmp"; exit 0; }
      mv -f "$tmp" "$MC_ATTEMPTS"
    ) 9>>"$MC_ATTEMPTS.lock" 2>/dev/null
    rm -f "$tmp"
  fi
  # BH-4156: the PR leaves this tick's memo BEFORE the row is deleted, so no
  # later read in the tick can answer "attempted" from the memo. The stamp does
  # the same for every OTHER tick's memo; it is touched again after the delete,
  # so a snapshot taken while the delete ran is refused too.
  k=$(mc_attempt_pr_key "$1 $2 $3") && {
    _mc_memo_covered "${k%%$'\t'*}" "$(cut -f2 <<<"$k")" \
      && echo "$(cut -f2 <<<"$k")" >> "$(_mc_memo_base "${k%%$'\t'*}").uncovered"
    mkdir -p "$MC_TICK_DIR" 2>/dev/null
    touch "$(_mc_memo_clear_stamp "${k%%$'\t'*}" "$(cut -f2 <<<"$k")")" 2>/dev/null
  }
  # Outside the subshell on purpose: pr_rows_trip below has to latch in a shell
  # that outlives the call.
  type pr_rows_on >/dev/null 2>&1 && pr_rows_on || return 0
  k=$(mc_attempt_pr_key "$1 $2 $3") || return 0
  IFS=$'\t' read -r repo num kind sha <<< "$k"
  pr_attempt_del "$repo" "$num" "$kind" "$sha" >/dev/null 2>&1; rc=$?
  # rc 0 the row is gone, rc 2 there was none: either way this attempt is
  # forgotten. Anything else and the row may still say "attempted" while the
  # file no longer does, so the twin goes BLIND for the rest of this process —
  # the file has forgotten, and the file is then the only thing asked. The next
  # tick clears again (the stuck arm re-fires while the PR is still stuck) and
  # may reach the row then. Unlike mc_attempt_put, this rc cannot be ignored:
  # there the file already said "attempted" and a lost row costs one extra
  # attempt, here a lost delete costs the respawn itself.
  case "$rc" in 0|2) : ;; *) pr_rows_trip ;; esac
  touch "$(_mc_memo_clear_stamp "$repo" "$num")" 2>/dev/null
  return 0
}


# --- THE LAND TRIGGER (BH-870) -----------------------------------------------
# WHAT WAS MISSING. Everything above is about a PR GitHub has ALREADY called
# DIRTY: mc_classify answers NEEDS_REBASE, the arm in bin/merge-conductor.sh
# asks merge_tree_clean, and a head that still merges cleanly is deliberately
# left alone. So a merge to main was an event this lane did not act on at all.
# An open PR stayed on the base it was cut from until it CONFLICTED, and the
# conflict is the expensive way to learn that main moved: by then the rebase is
# not mechanical any more and the ticket is on the resolver's ladder.
#
# The trigger is therefore the BASE SHA ITSELF, read once per project per tick
# with one authenticated ls-remote, compared with the last sha whose fan-out
# completed. A changed sha offers every open base-based PR of that repo one
# mechanical rebase; an unchanged sha does nothing at all. The state survives a
# restart so a sha that was already handled does not re-fire: with the
# pr-state-rows flag up it is the `ledgers` row kind=mc_land key=<project>
# (BH-2357), so it survives losing the box too, and the file per project is its
# cache; with the flag down it is the file alone.

# mc_land_main_sha <owner/repo> <base> — the 40-hex sha of refs/heads/<base> on
#   the remote, or rc 1 with EMPTY stdout. Every failure is rc 1: an unsafe ref
#   name, no token that can read the repo, a refused or timed-out ls-remote, and
#   an answer that is not a sha. The caller reads rc 1 as "this tick could not
#   tell", never as "main has not moved" (D9/D11) — inventing "unchanged" out of
#   an outage would silently skip the landing that outage straddled.
mc_land_main_sha() {
  local slug="$1" base="$2" out sha
  mc_ref_ok "$base" || return 1
  mc_git_auth "$slug" || { mc_git_auth_clear; return 1; }
  out=$(mc_git_bounded "${MC_MERGE_TREE_FETCH_SECS:-60}" \
          git -c credential.helper= ls-remote --exit-code "$MC_REMOTE" "refs/heads/$base" 2>/dev/null) || {
    mc_git_auth_clear; return 1; }
  mc_git_auth_clear
  sha=$(printf '%s\n' "$out" | awk 'NF {print $1; exit}')
  case "$sha" in
    *[!0-9a-f]*|"") return 1 ;;
  esac
  [ "${#sha}" = 40 ] || return 1
  printf '%s' "$sha"
}
# mc_land_file/_prev/_record — the cross-run state, one sha per project.
#   A MISSING RECORD IS A BASELINE, not a landing: the first tick after a
#   rollout records the sha and fans out nothing, because seven repos each
#   offering every open PR a rebase on the same */5 is the wrong first event.
#   mc_land_prev asks the ledger first (flag up) and prints its status when it
#   is a 40-hex sha; no row yet (rc 2), an outage (rc 1) or a status that is not
#   a sha fall to the file, so neither a rollout nor a blink re-baselines a
#   project. mc_land_record PUTs the ledger first (rc ignored past one log
#   line), then writes the file; a tick killed between the two leaves the ledger
#   newer, which the ledger-first read resolves. The file write is tmp + mv so a
#   tick killed mid-write leaves the OLD sha, which costs one repeated fan-out
#   (idempotent, see the attempts marker) rather than a sha nobody can read.
mc_land_file()   { printf '%s/%s' "$MC_LAND_DIR" "$(mc_safe_name "$1")"; }
mc_land_prev() {
  local s
  if type pr_rows_on >/dev/null 2>&1 && pr_rows_on && type job_ledger_get >/dev/null 2>&1 \
     && s=$(job_ledger_get mc_land "$1" 2>/dev/null) && [[ "$s" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' "$s"; return 0
  fi
  head -1 "$(mc_land_file "$1")" 2>/dev/null; return 0
}
mc_land_record() {
  local f tmp; f=$(mc_land_file "$1"); tmp="$f.tmp"
  if type pr_rows_on >/dev/null 2>&1 && pr_rows_on && type job_ledger_put >/dev/null 2>&1; then
    job_ledger_put mc_land "$1" "$2" >/dev/null 2>&1 \
      || mc_log "LAND watermark: ledgers mc_land/$1 write failed — the file still records ${2:0:8}"
  fi
  mkdir -p "$MC_LAND_DIR" 2>/dev/null
  printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f"
}
# mc_land_needed <owner/repo> <project> <head> <num> <mainsha>
#   May this head be brought current by a MECHANICAL rebase right now?
#     rc 0  yes — it does not contain <mainsha> and it merges clean
#     rc 1  no  — it already contains <mainsha>; there is nothing to replay
#     rc 2  no  — it conflicts; stdout is the conflicting paths (the existing
#                 NEEDS_REBASE path and the resolver's ladder own that PR)
#     rc 3  this tick could not tell; stdout says why. A DEFERRAL, never a skip.
#   mc_merge_tree does the fetching (both sides into the funnel clone) and leaves
#   MC_FUNNEL_WT pointing at it, so the ancestry question below is a local read.
#   The ancestry test runs SECOND on purpose: merge-tree is what puts main and
#   the head in the clone, and asking `merge-base --is-ancestor` before that
#   would answer about objects this box does not have.
#   mc_merge_tree's stdout goes through a FILE, not a command substitution: a
#   `$(...)` runs it in a subshell and MC_FUNNEL_WT — the checkout it just
#   fetched both sides into — would be set in a shell that is already gone, so
#   the ancestry read below would have nowhere to run and every PR would defer.
mc_land_needed() {
  local slug="$1" project="$2" head="$3" num="${4:-}" mainsha="$5" out rc tf
  tf=$(mktemp "${TMPDIR:-/tmp}/mc-land-XXXXXX" 2>/dev/null) || { printf 'no temp file for the merge test'; return 3; }
  mc_merge_tree "$slug" "$project" "$head" "$num" > "$tf" 2>/dev/null; rc=$?
  out=$(cat "$tf" 2>/dev/null); rm -f "$tf"
  case "$rc" in
    0) ;;
    1) printf '%s' "$out"; return 2 ;;
    *) printf '%s' "${out:-git merge-tree rc $rc}"; return 3 ;;
  esac
  [ -n "${MC_FUNNEL_WT:-}" ] || { printf 'no checkout to read ancestry in'; return 3; }
  if git -C "$MC_FUNNEL_WT" merge-base --is-ancestor "$mainsha" "$head" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}
# pr_slot_wait — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# pr_slot_wait — the MC_PR_PARALLEL ceiling, enforced between forks. 0 (the
#   default) is unlimited and this returns at once; above it the dispatcher
#   waits for ONE worker of this project to finish before forking the next.
#   PRPIDS is pruned of the dead here, so the wait is always on live pids.
pr_slot_wait() {
  local cap="${MC_PR_PARALLEL:-0}" alive pid
  case "$cap" in ''|*[!0-9]*) cap=0 ;; esac
  [ "$cap" -gt 0 ] || return 0
  while :; do
    alive=()
    for pid in "${PRPIDS[@]:-}"; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive+=("$pid")
    done
    PRPIDS=("${alive[@]:-}")
    [ "${#alive[@]}" -ge "$cap" ] || return 0
    # `wait -n <pid...>` is bash 5.1+ (the fleet and CI are 5.2). Older bash
    # rejects the pid list, and the fallback — wait for the OLDEST worker — is
    # the same ceiling in a marginally less optimal order.
    wait -n "${alive[@]}" 2>/dev/null || wait "${alive[0]}" 2>/dev/null || true
  done
}

# hotfix_pending_file — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# ---- this tick's hotfix PRs (BH-369) ----------------------------------------
# One file per (tick, project), one PR number a line, written BEFORE the first
# worker of the project starts and a line dropped when that PR's worker exits by
# any path. It answers one question, for a plain PR that is about to bypass a
# silent queue and merge directly: is an emergency of this repo still in flight
# in this tick? It is READ, never waited on (the operator, 2026-09-13 — "we never lock
# and serialise"), so a hotfix costs a plain PR one tick, never a stall.
#
# Keyed by TICK ID like the spend budgets, and for the same two reasons: it
# starts empty every tick without a reset, and two OVERLAPPING ticks cannot
# defer each other's PRs. mc_tick_gc already collects the directory.
hotfix_pending_file() { printf '%s/%s.hotfix-%s' "$MC_TICK_DIR" "$(mc_safe_name "${MC_TICK_ID:-notick}")" "$(mc_safe_name "$1")"; }

# identity_verdict_file — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# identity_verdict_file <"slug base"> — the per-TICK cache of "can this identity
#   push to that branch". A FILE and not an array because the PR workers are
#   subshells: an array would buy a protection read once per PR instead of once
#   per repo (D21). Those subshells run CONCURRENTLY (MC_PR_PARALLEL 0 =
#   unlimited is the default), so the file is written and read under a flock on
#   itself. It lives in MC_TICK_DIR, which mc_tick_gc already prunes.
identity_verdict_file() { printf '%s/%s.idv-%s' "$MC_TICK_DIR" "$(mc_safe_name "${MC_TICK_ID:-notick}")" "$(mc_safe_name "$1")"; }

# hotfix_pending_write — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
hotfix_pending_write() { # hotfix_pending_write <project> <num>...
  local f; f=$(hotfix_pending_file "$1"); shift
  [ $# -gt 0 ] || return 0
  mkdir -p "$MC_TICK_DIR" 2>/dev/null
  # Rewritten in place under its own flock on fd 6, like the counter file: fds
  # 7, 8 and 9 are the git, merge and per-PR locks, and a settle forks children.
  ( flock 6 2>/dev/null; printf '%s\n' "$@" > "$f" ) 6>>"$f" 2>/dev/null
  return 0
}

# hotfix_pending_drop — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
hotfix_pending_drop() { # hotfix_pending_drop <project> <num> — its worker is done
  local f; f=$(hotfix_pending_file "$1"); [ -f "$f" ] || return 0
  ( flock 6 2>/dev/null
    local rest; rest=$(grep -vxF -- "$2" "$f" 2>/dev/null)
    if [ -n "$rest" ]; then printf '%s\n' "$rest" > "$f"; else : > "$f"; fi
  ) 6>>"$f" 2>/dev/null
  return 0
}

# hotfix_pending_is — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
hotfix_pending_is() { # rc 0 when THIS PR is one of the tick's hotfixes
  grep -qxF -- "$2" "$(hotfix_pending_file "$1")" 2>/dev/null
}

# hotfix_pending_others — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
hotfix_pending_others() { # prints "#41 #42", rc 1 when no OTHER hotfix is in flight
  local f out; f=$(hotfix_pending_file "$1"); [ -s "$f" ] || return 1
  out=$(grep -vxF -- "$2" "$f" 2>/dev/null | sed 's/^/#/' | tr '\n' ' ')
  out="${out% }"; [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# tick_memo_file — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# ---- the read memo (BH-1486) -----------------------------------------------
# ONE TICK USED TO MAKE THE SAME GITHUB READ SEVERAL TIMES, and every tick made
# again the reads whose answer could not have changed. Three of them, measured
# on the hub:
#   * the stack-parent list (`pulls?state=all&head=owner:<base>`) — once per
#     STACKED child, so two children of one parent branch bought the same list
#     twice in the same tick, three children three times;
#   * the check-run list (`actions/runs?head_sha=`) — once per open PR, every
#     tick, for ever, including on heads whose CI finished green hours ago;
#   * the PR diff for the iron-law scan — once per READY PR, every tick, on a
#     diff nobody had pushed to.
# So there are TWO stores, and they are deliberately different things:
#   tick_memo_file <kind> <key>   PER TICK, under $MC_TICK_DIR and keyed by
#     $MC_TICK_ID like the spend budgets and the hotfix marker — it starts
#     empty every tick without a reset, two OVERLAPPING ticks cannot read each
#     other's, and mc_tick_gc already collects the directory.
#   read_memo_file <kind> <KEY>   ACROSS TICKS, under $MC_STATE_DIR/read-memo,
#     keyed on the PR and bounded three ways: the head sha, the PR's
#     `updated_at`, and a fingerprint of this conductor's OWN CI writes for
#     that head. read_memo_gc drops what stopped being asked for.
#
# WHAT IS NEVER STORED, and why each one matters (D11 — absent is not
# unchanged, and a refused read is not a state):
#   * an answer for a PR whose `updated_at` is UNKNOWN (the list did not carry
#     it, so the tsv says `-`): there is no second key to compare, so the memo
#     is simply off for that PR and every read is made exactly as it is today.
#   * a NON-TERMINAL CI word (`pending`, `none`, `unavailable`): those are the
#     answers that change without anybody touching the PR.
#   * a scan whose diff could not be READ: an unread diff is not a clean diff.
#   * `NONE` from a stack-parent read: mc_stack_parent answers NONE both for
#     "there is no parent PR" and for "GitHub would not tell us", so storing it
#     would cache a refusal.
#
# AND A CHECK RUN COMPLETING DOES NOT BUMP `updated_at`. GitHub bumps it on
# commits, comments, reviews, labels and base/state edits — not on check-run or
# status events. Taken literally, "unchanged sha + unchanged updated_at means do
# not re-read the check runs" would therefore leave a WAIT_CI row blind to its
# own CI going green until some unrelated event touched the PR. Hence: only
# TERMINAL answers are memoised, the memo expires after MC_READ_MEMO_TTL_SECS
# (default 900 s = three cron fires), and any CI write this conductor makes on
# that head — a kick, a rerun, a red mark, a restack — moves the attempts
# fingerprint and invalidates it on the next tick. MC_READ_MEMO=0 is the
# operator kill switch.
# THE TICK MEMO'S FILE NAME CARRIES A DIGEST OF THE RAW KEY (BH-1486 follow-up),
# because mc_safe_name alone cannot keep two of ITS keys apart: it is keyed on a
# BRANCH. mc_safe_name maps every character outside
# [A-Za-z0-9._-] to `_`, which is right for the names it was written for — a
# project slug and a PR NUMBER — and wrong for these, which carry BRANCH names:
# `ticket/x_y` and `ticket/x/y` are two branches that can both exist in one repo
# and both flatten to `ticket_x_y`. A stacked child would be served the OTHER
# branch's parent state, and the stacked arm ACTS on that answer by retargeting
# the PR — so the child lands on the wrong base, silently, and only on the repos
# unlucky enough to hold both names. The readable safe name stays so an operator
# can still tell what a file is about; the digest is what makes two different
# keys two different files. Entries written before this are simply missed once.
tick_memo_file() { # tick_memo_file <kind> <key>
  printf '%s/%s.memo-%s-%s-%s' "$MC_TICK_DIR" "$(mc_safe_name "${MC_TICK_ID:-notick}")" \
    "$(mc_safe_name "${1:-}")" "$(mc_safe_name "${2:-}")" "$(_mc_key_digest "${1:-}|${2:-}")"
}

# read_memo_dir — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
read_memo_dir()  { printf '%s/read-memo' "$MC_STATE_DIR"; }

# read_memo_file — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# read_memo_file needs NO digest: its key is `<slug>#<PR number>`, and a number
# cannot collide under mc_safe_name the way a branch name can. Only the tick
# memo above is keyed on a branch, so only it pays for one.
read_memo_file() { printf '%s/%s.%s' "$(read_memo_dir)" "$(mc_safe_name "${2:-}")" "$(mc_safe_name "${1:-}")"; }

# read_memo_fp — moved from bin/merge-conductor.sh (BH-477 / BH-685); same name, and since BH-2357 it counts the rows too.
# read_memo_fp <KEY> <HEAD> — how many times this conductor has recorded doing
#   something to CI on this (PR, head). Every one of those writes appends a
#   `<kind> <key> <head>` line to $MC_ATTEMPTS (cikick, red, flakealert,
#   cirerun, restack…), so the COUNT moving is exactly "we touched this head
#   since the answer was memoised" — which is the one way a terminal CI answer
#   can legitimately change while sha and updated_at stand still.
#   With the flag up (BH-2357) the count is the `pr_attempts` rows of <KEY>
#   whose sha starts with <HEAD>, every kind in one list GET, PLUS the file's
#   count: some writers (cirerun, requeued…) still append the file alone, and a
#   touch in either store must move the number. The file loses nothing and the
#   rows still count after the file is lost. An outage (rows rc 1/3) is the
#   file's count alone. Only equality is ever compared, so the sum is safe.
read_memo_fp() {
  local n r=0 f rc
  n=$(awk -v k="${1:-}" -v h="${2:-}" '$2==k && $3==h {n++} END {print n+0}' "$MC_ATTEMPTS" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if type pr_rows_on >/dev/null 2>&1 && pr_rows_on && f=$(mktemp 2>/dev/null); then
    mc_attempt_rows '*' "${1:-}" "$f"; rc=$?
    [ "$rc" = 0 ] && r=$(H="${2:-}" awk '$1 "" == ENVIRON["H"] {n++} END {print n+0}' "$f" 2>/dev/null)
    rm -f "$f"
    case "$r" in ''|*[!0-9]*) r=0 ;; esac
  fi
  printf '%s' "$(( n + r ))"
}

# read_memo_get — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# read_memo_get <kind> <KEY> <HEAD> <UPDATED> <FP> — prints the stored answer
#   and rc 0 ONLY when every one of these holds. Anything else is rc 1 with
#   nothing printed, which every caller reads as "make the read".
read_memo_get() {
  local kind="${1:-}" key="${2:-}" head="${3:-}" upd="${4:-}" fp="${5:-}" f ttl line age
  local sh su sf se sa
  [ "${MC_READ_MEMO:-1}" != 0 ] || return 1
  ttl="${MC_READ_MEMO_TTL_SECS:-900}"
  case "$ttl" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ttl" -gt 0 ] || return 1
  [ -n "$kind" ] && [ -n "$key" ] && [ -n "$head" ] && [ -n "$upd" ] || return 1
  f=$(read_memo_file "$kind" "$key")
  [ -r "$f" ] || return 1
  # A TORN FILE IS A MISS. One line, exactly five fields: anything else is a
  # write somebody interrupted, and a memo read out of half a record is the
  # "an empty answer standing in for a state" shape this whole file refuses.
  [ "$(awk 'END {print NR}' "$f" 2>/dev/null)" = 1 ] || return 1
  line=$(head -n 1 "$f" 2>/dev/null)
  [ "$(awk '{print NF}' <<<"$line")" = 5 ] || return 1
  read -r sh su sf se sa <<<"$line"
  [ "$sh" = "$head" ] && [ "$su" = "$upd" ] && [ "$sf" = "$fp" ] || return 1
  case "$se" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(mc_now) - se ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ] || return 1
  printf '%s' "$sa"
}

# read_memo_put — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# read_memo_put <kind> <KEY> <HEAD> <UPDATED> <FP> <answer> — tmp + `mv -f`,
#   the _gh_etag_on_2xx writer shape, with $BASHPID in the tmp name because $$
#   is the same in every subshell of one tick and the PR workers ARE subshells.
#   Refuses silently when the PR's updated_at is unknown: there would be no
#   second key to invalidate the entry on.
read_memo_put() {
  local kind="${1:-}" key="${2:-}" head="${3:-}" upd="${4:-}" fp="${5:-}" ans="${6:-}" d f tmp
  [ "${MC_READ_MEMO:-1}" != 0 ] || return 0
  [ -n "$kind" ] && [ -n "$key" ] && [ -n "$head" ] && [ -n "$upd" ] && [ -n "$ans" ] || return 0
  # THE FINGERPRINT IS AN OPAQUE TOKEN, not a bare integer (BH-1486 follow-up).
  # It used to be a count and nothing else, and refusing anything non-numeric
  # meant the scan memo's richer fingerprint below would have been dropped here
  # SILENTLY — stored never, read never, and indistinguishable in review from a
  # memo that simply never hit. The charset is still closed, so a token carrying
  # a space (which would tear the five-field record) or a newline is refused
  # exactly as before; lower-case letters and `.` join the digits the counts are
  # made of. THE LETTER RANGE IS a-z AND NOT a-f: the scan fingerprint's base
  # component is the WORD `nobase` when the tick could not read the base tip,
  # and a hex-only charset refused it — silently, on the put side only, so the
  # memo stored nothing and hit nothing on every box whose base read is
  # degraded. Caught by tests/conductor-read-memo.bh-1486-test.sh section C,
  # which is what an existing suite is for.
  case "$fp" in ''|*[!0-9a-z.]*) return 0 ;; esac
  d=$(read_memo_dir); mkdir -p "$d" 2>/dev/null || return 0
  f=$(read_memo_file "$kind" "$key"); tmp="$f.tmp.$BASHPID"
  printf '%s %s %s %s %s\n' "$head" "$upd" "$fp" "$(mc_now)" "$ans" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# scanner_fp — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# --- THE SCAN MEMO'S KEY COVERS THE SCANNER AND THE BASE (BH-1486 follow-up) --
#
# `scan` is the one memoised answer that is NOT a property of the PR alone, and
# the (head, updated_at, attempts) key does not reach either of the two other
# things it depends on:
#
#   THE SCANNER. mc_iron_law_scan is not a pure function of the diff bytes. It
#   is its own grep PLUS every `CHECK-HIT` line bin/checks-run.sh produces, and
#   checks-run reads the catalog at checks/*/check.sh. Deploy a new iron-law
#   check to the hub and nothing in the key moves — so a PR sitting in READY
#   goes on replaying the count the OLD catalog produced, and can merge carrying
#   a violation of a check that was live when it merged. The TTL bounds that to
#   three cron fires; it does not remove it, and "the check that was deployed to
#   stop this merged anyway" is not a fifteen-minute-sized problem.
#
#   THE BASE. A PR's `.diff` is merge-base(base, head)..head. When the project
#   base moves the merge base moves with it, so the patch GitHub serves can
#   change with the head sha, the updated_at and the attempts count all standing
#   still. LAND_SHA is that tip, and the tick already reads it once per project.
#
# scanner_fp digests the scanner itself: checks-run, the classifier that holds
# the inline patterns, and every check in the catalog — file names included, so
# ADDING a check moves it as surely as editing one. About 21 KB read once per
# project per tick.
scanner_fp() {
  # `$MC_H` and not `${MC_H:-…}`: bin/lib/mc/log.sh sets it for every run of
  # this script, and the `:-` form is what lanes-registry section 7 reads as an
  # operator knob the registry has to carry.
  local h="$MC_H" f
  { for f in "$h/bin/checks-run.sh" "$h/bin/lib/mc/classify.sh"; do
      printf '\0%s\0' "$f"; [ -r "$f" ] && cat "$f"
    done
    for f in "$h"/checks/*/check.sh; do
      [ -r "$f" ] || continue
      printf '\0%s\0' "$f"; cat "$f"
    done
  } 2>/dev/null | _mc_digest_stream
}

# scan_memo_fp — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# scan_memo_fp <attempts-fp> <scanner-fp> [base-sha] — the scan memo's
#   fingerprint, or rc 1 when the attempts count or the SCANNER is unknown. An
#   empty fingerprint turns the memo off for that PR at both ends, which is the
#   answer this lane gives to an unknown it cannot afford to guess at.
#
#   THE SCANNER IS MANDATORY AND THE BASE IS NOT, and the asymmetry is the whole
#   design. A scanner we cannot identify might be a NEWER one, and replaying a
#   count the old catalog produced would let a PR merge past a check that was
#   live when it merged — an unsafe replay, in the direction that matters.
#
#   A stale BASE cannot do that. The scan counts hits among the diff's ADDED
#   lines, and moving the merge base forward can only REMOVE added lines from a
#   PR's patch (the ones the base now carries itself); it can never introduce a
#   `+` line the PR did not author. So a count replayed across a base move can
#   only be too HIGH — it parks a PR that would now pass, and a park is the
#   fail-safe direction. It is also triply covered already: a base move sets
#   LAND_FIRE and offers every open PR a rebase, a restack moves the attempts
#   count, and the whole entry expires at MC_READ_MEMO_TTL_SECS. So the base
#   SHARPENS the key when the tick could read it and never vetoes it: `nobase`
#   is a real token two unreadable ticks share, and sharing it costs at most an
#   over-count that clears itself.
scan_memo_fp() {
  local a="${1:-}" sc="${2:-}" base="${3:-}" b=nobase
  case "$a"  in ''|*[!0-9]*) return 1 ;; esac
  case "$sc" in ''|*[!0-9a-f]*) return 1 ;; esac
  case "$base" in ''|*[!0-9a-f]*) ;; *) b=$(printf '%s' "$base" | cut -c1-12) ;; esac
  printf '%s.%s.%s' "$a" "$sc" "$b"
}

# read_memo_gc — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# read_memo_gc — entries nothing has asked for in three days, the same rule and
#   the same reason as mc_pr_files_gc: the head they are keyed on is long gone.
read_memo_gc() {
  local d; d=$(read_memo_dir)
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -type f -mtime +3 -delete 2>/dev/null
  return 0
}

# stack_parent_memo — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# stack_parent_memo <project> <slug> <base-ref> — mc_stack_parent, ONCE per
#   tick per (slug, base ref), shared by every PR worker of the tick through a
#   file because those workers are concurrent subshells and a shell variable
#   would buy the list once per CHILD instead of once per parent.
#
#   THE LOCK IS A DEDUPE WITH A DEADLINE, NEVER A QUEUE (the operator, 2026-09-13). It
#   guards ONE list read; a worker that cannot get it inside 20 s reads
#   unmemoised, which is exactly today's behaviour, and never waits on a
#   sibling worker's lifetime. The fd is 8 — 6 is the hotfix marker, 7 the git
#   lock, 9 this PR's own lock — and it is closed when the subshell exits, so
#   no detached lane can inherit it.
stack_parent_memo() {
  local p="${1:-}" slug="${2:-}" br="${3:-}" f out
  f=$(tick_memo_file stack "$slug#$br")
  if [ -s "$f" ]; then
    mc_count_inc "$p" stackmemo >/dev/null
    cat "$f" 2>/dev/null
    return 0
  fi
  mkdir -p "$MC_TICK_DIR" 2>/dev/null
  out=$( ( flock -w 20 8 2>/dev/null || exit 0
           if [ -s "$f" ]; then mc_count_inc "$p" stackmemo >/dev/null; cat "$f"; exit 0; fi
           o=$(mc_stack_parent "$slug" "$br")
           case "$o" in
             OPEN*|MERGED*|CLOSED*)
               printf '%s' "$o" > "$f.tmp.$BASHPID" 2>/dev/null \
                 && mv -f "$f.tmp.$BASHPID" "$f" 2>/dev/null
               rm -f "$f.tmp.$BASHPID" 2>/dev/null ;;
           esac
           printf '%s' "$o" ) 8>"$f.lock" 2>/dev/null )
  [ -n "$out" ] || out=$(mc_stack_parent "$slug" "$br")
  printf '%s' "$out"
}

# tick_secs_for — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# tick_secs_for <project> — MC_TICK_SECS for this project, through the lane
#   registry (settings row first, then the environment, then the registry
#   default of 0). Anything unparseable is 0, which is "tick on every cron
#   fire" — today's behaviour, and the fail-open answer.
tick_secs_for() {
  local v
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor MC_TICK_SECS "${1:-}" 2>/dev/null)
  else v="${MC_TICK_SECS:-0}"; fi
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}

# ticket_dedupe_for — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# ticket_dedupe_for <project> — 1 when the one-PR-per-ticket rule is on for
#   this project (BH-1526). The registered knob, per-project row first; with
#   no lane_knob on the box the answer is the env, else 0: off is the default.
ticket_dedupe_for() {
  local v
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor MC_TICKET_DEDUPE "${1:-}" 2>/dev/null)
  else v="${MC_TICKET_DEDUPE:-0}"; fi
  [ "$v" = 1 ] && printf 1 || printf 0
}

# budget_spent — moved verbatim from bin/merge-conductor.sh (BH-477 / BH-685); same name, same body.
# budget_spent <project> <kind> <key> — ONE counted, logged refusal. The tick
#   metrics line's budget_exhausted field is this counter: an operator reading
#   "merges=0 budget_exhausted=4" knows the flags were on and the cap was the
#   thing in the way, which the old silent `continue` never said.
budget_spent() {
  mc_count_inc "$1" exhausted >/dev/null
  mc_log "$3 $2 deferred — $1 has spent this tick's $2 budget"
  return 0
}

# ── UNVERIFIABLE STREAK (BH-1634) ────────────────────────────────────────────
# Here, beside the other knob readers and per-PR state files, because the
# driver keeps only its five dispatch names (BH-685; tests/mc/driver-complete).
# A row the open list marks UNVERIFIABLE (its per-PR merge-state read failed,
# BH-1585) is skipped each tick. A PR whose read keeps failing would be skipped
# for ever with nothing but a log line, so each skip adds one to that PR's
# streak and the MC_UNVERIFIABLE_ALERT_TICKS-th consecutive one writes ONE
# alert. A tick that reads the row as a real state clears the streak, so a
# later streak alerts again. A held tick or a tick whose whole list failed
# reaches no row, so it neither counts nor clears.
# The state file, one line: <count> <alerted 0|1>.

# unverif_ticks_for <project> — the registered knob; 0 (or unreadable) is off.
unverif_ticks_for() {
  local v
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor MC_UNVERIFIABLE_ALERT_TICKS "${1:-}" 2>/dev/null)
  else v="${MC_UNVERIFIABLE_ALERT_TICKS:-}"; fi
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}
unverif_file() { printf '%s/unverifiable/%s' "$MC_STATE_DIR" "$(mc_safe_name "$1")"; }
unverif_gc() { find "$MC_STATE_DIR/unverifiable" -maxdepth 1 -type f -mtime +3 -delete 2>/dev/null; return 0; }

# unverif_note <project> <key> <url> — adds this tick to the streak and prints
#   the new count. Under the file's own lock (the worker has not taken the PR's
#   lock yet), and alerted=1 is persisted BEFORE mc_alert: a send that fails
#   loses one alert, it never repeats one.
unverif_note() {
  local p="$1" key="$2" url="$3" f n c=0 a=0
  f=$(unverif_file "$key")
  mkdir -p "${f%/*}" 2>/dev/null || { printf '0'; return 0; }
  n=$(unverif_ticks_for "$p")
  (
    flock -x 8
    IFS=$'\t' read -r c a < "$f" 2>/dev/null
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    [ "$a" = 1 ] || a=0
    c=$((c + 1))
    printf '%s\t%s\n' "$c" "$a" > "$f.tmp.$BASHPID" && mv -f "$f.tmp.$BASHPID" "$f"
    if [ "$n" -gt 0 ] && [ "$c" -ge "$n" ] && [ "$a" = 0 ]; then
      printf '%s\t1\n' "$c" > "$f.tmp.$BASHPID" && mv -f "$f.tmp.$BASHPID" "$f" \
        && mc_alert "$key" UNVERIFIABLE "merge state unreadable for $c consecutive ticks (the open list's per-PR read failed each time); the conductor has skipped it every tick: $url"
    fi
    printf '%s' "$c"
  ) 8>"$f.lock"
}
# unverif_clear <key> — the row read as a real state: the streak is over.
unverif_clear() { local f; f=$(unverif_file "$1"); [ -e "$f" ] && rm -f "$f" "$f.lock"; return 0; }
