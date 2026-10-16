#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm.sh — BH-4583 (BH-4574.1): Archie's factory-manager
# playbooks. Sourced by bin/archie-fm.sh (and its suite), never run: no
# `set -e`, no `exit`, nothing at source time.
#
# WAVE 1 KNOWS ONE CLASS, stacked-parent-merged: an open PR whose base is not
# the project's base branch, and whose base branch is the head of a PR that
# has MERGED. The conductor restacks the children of parents it merged itself
# (mc_stack_follow, bin/lib/mc/rebase.sh; _gpm_owe_restack for merge-sweep).
# A parent merged by anyone else (the Mergify queue, a console merge, a hand
# merge) leaves the child on the merged branch carrying the parent's
# pre-squash commits, and nothing owes it a restack. This lane does.
#
# THE PLAYBOOK (afm_act), after the lane has claimed the action's row:
#   observe  close the row `would` / would_restack. No git, no fetch, no PATCH,
#            no push, no conductor write.
#   on       a. a worktree of origin/<child> (the hub clone, else the
#               conductor's scratch clone, exactly as mc_restack does); the
#               head must still be the one the list read (else deferred);
#            b. the fork point: the parent's pre-merge head when it is in the
#               child's history, else (BH-4784, a stack of three) the head an
#               Archie restack of the parent recorded as `old_head` before it
#               replayed the parent (afm_fork_point). None recorded is failed
#               with ONE alert, never noop; a ledger that cannot be read is
#               deferred. The child must have commits of its own above the
#               fork point (else done / noop);
#            c. `git rebase --onto origin/<target> <fork-point>`: only the
#               child's own commits are replayed;
#            d. the repo's selected suites on the replayed tree (afm_suites),
#               as `nobody` in a snapshot under env -i (afm_isolated): PR code
#               never sees the lane's token or env;
#            e. green: retarget the PR FIRST (mc_retarget_base, REST), then
#               hold_push with the lease on the head the list read. The push is
#               the `synchronize` CI runs on, so it lands on the final base
#               (the BH-1670 order). A refused push puts the base BACK, so
#               the PR stays visible to the next tick (else failed + alert).
#               Conflict or red suites: retarget, NO push,
#               and the conductor park bin/blocked-resolver.sh drains with its
#               own capped fix-round ladder (mc_stack_follow's conflict arm).
#               A push records the PR's own open children (`children`, from
#               the tick's list read) so their later replay can be traced.
#
# THE DAY CAP (afm_cap_ok) counts today's mode=on rows whose action is
# restack or fix_round, whatever their outcome (a deferred row is one attempt,
# a noop wrote nothing). It is read once per tick at most after it is reached.
#
# A TICK KILLED between the retarget and the push (its outer `timeout -k`)
# leaves a PR on <target> that still carries the parent's pre-squash commits,
# which afm_classify no longer sees. afm_recover_load reads today's and
# yesterday's started/deferred restack rows, and afm_recover_classify matches
# a PR still on the row's `onto` with the row's `old_head`: it goes back
# through the ordinary claim ladder (stale started -> deferred -> reclaimed).
#
# THE SECOND PLAYBOOK, data-lane (BH-4927, BH-4920.4), runs on a PR the
# restack classifier leaves unclassified. afm_classify_data_lane finds the PR's
# build record (mc_record_for on its url) and reads it, and the PR's file list:
# a candidate is a review.md whose final round BLOCKed only on its unapplied
# migration (dl_candidate, bin/lib/data-lane.sh, against the PR's real files)
# at exactly this head (dl_reviewed_sha). afm_dl_act claims the row
# data-lane:<project>:<pr>:<head12> (`:observe` appended in observe mode, so an
# observed head can still be acted on once the project flips to `on`), then
# runs bin/data-lane-apply.sh ONCE, bounded, and closes the row from its rc and
# its outcome word. Observe closes `would` / would_apply and calls nothing. It
# writes no resolver, conductor or build state, and pushes nothing.
#
# EVERY ACTION IS A ROW in the jobs DB table archie_actions
# (worker/jobs/src/routes/archie-actions.js), claimed BEFORE any git or GitHub
# write. The key is stacked-parent-merged:<owner/repo>#<n>:<child-head>:
# <parent-head>:<mode>, so a second tick on the same state finds its own row and
# does nothing. No row, no action.
#
# Globals the caller sets: AFM_LOG (log file), NOW (epoch), DAY (UTC date),
# AFM_RETRY_S, AFM_MAX_ATT, AFM_SUITE_TIMEOUT_S, AFM_DEADLINE (the real epoch
# second past which this tick starts nothing; 0 = no deadline), and a
# `trap afm_on_term TERM` so a stopped tick cleans up after itself. Needs bin/jobs-client.sh
# (_jobs_req, setting_get), bin/lib/merge-conductor-lib.sh after mc_init, and
# bin/lib/gh-rest.sh (gh_rest_pr_list_var).
# gh-rest: no-graphql

AFM_PLAYBOOK=stacked-parent-merged
AFM_CAP_DEFAULT=20          # the documented fallback when archie.cap.<playbook> has no row
AFM_MODE_DEFAULT=on         # the documented fallback when no archie.manage row exists
AFM_ROW=""                  # the row this tick owns (the worker's JSON), set by afm_claim
AFM_ROUTE_ABSENT=0          # 1 once the worker answered 404 for /api/archie/actions
AFM_CAP_FULL=""             # the playbooks whose day cap this tick read as reached, space-separated (BH-4784 N3, per playbook since BH-4927)
AFM_OPEN_LIST="[]"          # the tick's open-PR list for the project, set by the caller
AFM_RECOVER=""              # killed-tick rows, set by afm_recover_load
AFM_TICK_SLACK_S=300        # setup + cleanup one action needs on top of its suite bound
AFM_DL_BOUND_S=360          # one data-lane apply: bin/data-lane-apply.sh's own POST is curl -m 300
AFM_DEADLINE=${AFM_DEADLINE:-0}
# What a stopped tick has to undo (afm_on_term): the worktree, the suite
# snapshot and its runner, and a retarget whose push has not landed.
AFM_CUR_REPO=""; AFM_CUR_WT=""; AFM_CUR_CLONED=""; AFM_CUR_SNAP=""; AFM_SUITE_PID=""; AFM_CUR_REVERT=""

# afm_time_left -> seconds before AFM_DEADLINE (a large number when there is none).
afm_time_left() {
  [ "${AFM_DEADLINE:-0}" -gt 0 ] 2>/dev/null || { printf '%s' 999999; return 0; }
  printf '%s' "$(( AFM_DEADLINE - $(date +%s) ))"
}

afm_log() { [ -n "${AFM_LOG:-}" ] && printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$AFM_LOG"; return 0; }

# _afm_req <method> <path> [body] — _jobs_req into a file, so JOBS_HTTP stays in
# this shell. Prints the body; rc is _jobs_req's (0 2xx, 9 409, 2 404, 1 other).
_afm_req() {
  local f rc
  f=$(mktemp "${TMPDIR:-/tmp}/afm-req.XXXXXX") || return 1
  _jobs_req "$@" > "$f"; rc=$?
  cat "$f"; rm -f "$f"
  return "$rc"
}

# afm_mode <project> -> on | observe | off on stdout, rc 0. rc 1: the settings
#   could not be read, and nothing is done for the project (no action without
#   the ledger either). archie.manage.<project> wins, then archie.manage, then
#   the fallback `on`. A value that is none of the three is one warn line and
#   observe: acting needs an explicit `on` or no row at all.
afm_mode() {
  local p="$1" key v rc
  key="archie.manage.$p"
  v=$(setting_get "$key"); rc=$?
  if [ "$rc" = 2 ]; then key=archie.manage; v=$(setting_get "$key"); rc=$?; fi
  case "$rc" in
    0) ;;
    2) printf '%s' "$AFM_MODE_DEFAULT"; return 0 ;;
    *) return 1 ;;
  esac
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in
    on|observe|off) printf '%s' "$v" ;;
    *) afm_log "warn: $key='$v' is not on, observe or off; $p is read as observe"
       printf observe ;;
  esac
  return 0
}

# afm_cap_ok <project> -> rc 0 when the day cap leaves room for one more
#   mode=on action of the playbook. Anything unreadable is rc 1 (fail closed),
#   with one log line saying why. Used = today's mode=on rows with action
#   restack, repair (BH-4585), fix_round or apply (the data lane), any outcome
#   (count_by=action; an answer without the count_by echo is an older worker
#   and unreadable). A cap reached is
#   remembered for the rest of the tick (AFM_CAP_FULL): no second read, no
#   second line. The memo is PER PLAYBOOK (lead review of #4966): a full
#   data-lane cap never stops a restack or a rebase-repair, nor the reverse.
#   An unreadable count is not remembered, it is retried per PR.
afm_cap_ok() {
  local p="$1" cap rc resp used
  case " $AFM_CAP_FULL " in *" $AFM_PLAYBOOK "*) return 1 ;; esac
  cap=$(setting_get "archie.cap.$AFM_PLAYBOOK"); rc=$?
  case "$rc" in
    0) cap=$(printf '%s' "$cap" | tr -d '[:space:]') ;;
    2) cap=$AFM_CAP_DEFAULT ;;
    *) afm_log "$p: archie.cap.$AFM_PLAYBOOK unreadable (rc=$rc); nothing done"; return 1 ;;
  esac
  if ! [[ $cap =~ ^[0-9]+$ ]]; then
    afm_log "$p: archie.cap.$AFM_PLAYBOOK='$cap' is not a whole number; nothing done"; return 1
  fi
  if [ "$((10#$cap))" = 0 ]; then afm_log "$p: archie.cap.$AFM_PLAYBOOK=0, the playbook is off"; return 1; fi
  resp=$(_afm_req GET "/api/archie/actions?day=$DAY&playbook=$AFM_PLAYBOOK&limit=1&count_by=action"); rc=$?
  if [ "$rc" = 2 ]; then AFM_ROUTE_ABSENT=1; return 1; fi
  if [ "$rc" = 0 ] && [ "$(jq -r '.count_by // ""' <<<"$resp" 2>/dev/null)" != action ]; then
    afm_log "$p: today's $AFM_PLAYBOOK count unreadable: the worker does not count by action yet; nothing done"; return 1
  fi
  used=$(jq -r --arg pb "$AFM_PLAYBOOK" \
    '(.counts[$pb].on.restack // 0) + (.counts[$pb].on.repair // 0) + (.counts[$pb].on.fix_round // 0) + (.counts[$pb].on.apply // 0) | if type == "number" then . else empty end' \
    <<<"$resp" 2>/dev/null)
  if [ "$rc" != 0 ] || [ -z "$used" ]; then
    afm_log "$p: today's $AFM_PLAYBOOK count unreadable (rc=$rc http=${JOBS_HTTP:-none}); nothing done"; return 1
  fi
  if [ "$used" -ge "$((10#$cap))" ]; then
    afm_log "$p: cap reached ($used of $((10#$cap)) $AFM_PLAYBOOK actions today); nothing done"
    AFM_CAP_FULL="${AFM_CAP_FULL:+$AFM_CAP_FULL }$AFM_PLAYBOOK"; return 1
  fi
  return 0
}

# afm_cap_claim <project> <claim-cmd> [args...] -> <claim-cmd>'s rc (afm_claim
#   at every call site), or 100 when no claim was made: the cap is full or unreadable (afm_cap_ok said why), or
#   locks/archie-fm-cap-<playbook>.lock was not free within 30 s (one log
#   line). The lock (fd 5) is held around the read AND the claim, so two
#   project ticks at used = cap-1 can not both claim (BH-5944). It is never
#   held across an action.
afm_cap_claim() {
  local p="$1" lf w=30 rc
  shift
  [ -n "${AFM_H:-}" ] || { afm_log "$p: no harness root for the $AFM_PLAYBOOK cap lock; nothing done"; return 100; }
  [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${PL_TEST_LOCK_WAIT_S:-} =~ ^[0-9]+$ ]] && w=$PL_TEST_LOCK_WAIT_S
  lf="$AFM_H/locks/archie-fm-cap-$AFM_PLAYBOOK.lock"
  mkdir -p "$AFM_H/locks" 2>/dev/null
  if ! { exec 5>"$lf"; } 2>/dev/null; then
    afm_log "$p: the $AFM_PLAYBOOK cap lock could not be opened; nothing done"; return 100
  fi
  if ! flock -w "$w" 5; then
    exec 5>&-
    afm_log "$p: the $AFM_PLAYBOOK cap lock was not free in ${w}s; nothing done"; return 100
  fi
  if ! afm_cap_ok "$p"; then
    flock -u 5; exec 5>&-; return 100
  fi
  "$@"; rc=$?
  flock -u 5; exec 5>&-
  return "$rc"
}

# afm_classify <project> <slug> <pr-json> -> rc 0 stacked-parent-merged, and
#   AFM_PARENT=`<parent-num>\t<parent-url>\t<parent-head>\t<target>` (a
#   global, not stdout: GH_REST_STATUS must survive for the caller) and
#   AFM_CHILD_BASE=<this PR's base branch, the parent's head>; rc 1
#   unclassified; rc 2 the parent could not be read (GH_REST_STATUS says why).
#   The parent is the PR whose head is this PR's base branch. <target> is the
#   PARENT's own base, so a doubly stacked child goes to its grandparent branch
#   and is never flattened onto main.
# afm_harness_branch <ref> -> rc 0 when <ref> is a harness build branch,
#   ticket/<key>[-rN] (bin/lib/rb/gates.sh names them ticket/<lowercase key>,
#   a rebuild adds -r<n>). Anything else is someone else's branch.
afm_harness_branch() { [[ ${1:-} =~ ^ticket/[a-z][a-z0-9]*-[0-9]+(-r[0-9]+)?$ ]]; }

afm_classify() {
  local p="$1" slug="$2" pr="$3" base pbase owner parents rc row _n _u _h _b
  AFM_PARENT=""; AFM_CHILD_BASE=""
  base=$(jq -r '.base.ref // ""' <<<"$pr")
  pbase=$(mc_project_base "$p")
  [ -n "$base" ] && [ "$base" != "$pbase" ] || return 1
  owner=${slug%%/*}
  rc=0; gh_rest_pr_list_var parents "$slug" all "$owner:$base" 1 || rc=$?
  [ "$rc" = 0 ] || return 2
  row=$(jq -r --arg b "$base" '[.[]? | select(.head.ref == $b)] | first // empty
    | select(.merged_at != null)
    | [(.number | tostring), (.html_url // ""), (.head.sha // ""), (.base.ref // "")] | @tsv' <<<"$parents" 2>/dev/null)
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r _n _u _h _b <<<"$row"
  [[ ${_h:-} =~ ^[0-9a-f]{40}$ ]] && [ -n "${_b:-}" ] || return 2
  AFM_PARENT="$row"; AFM_CHILD_BASE="$base"
  return 0
}

# afm_recover_load <project> — the killed-tick ledger (BH-4784 N5): today's and
#   the previous UTC day's mode=on restack rows still `started` or `deferred`
#   for <project>, as AFM_RECOVER lines `pr \t old_head \t parent_pr \t
#   parent_url \t parent_head \t onto \t child_base`. rc 1 (AFM_RECOVER
#   empty, one log line) when a day cannot be read: no recovery this tick,
#   never an action on half a ledger. A truncated day is logged and what was
#   read is used. Rows `requested` (a deliberate retarget without a push,
#   parked for bin/blocked-resolver.sh) and `failed` (already alerted) are
#   never recovered.
afm_recover_load() {
  local p="$1" d resp rc rows=""
  AFM_RECOVER=""
  for d in "$DAY" "$(date -u -d "@$((NOW - 86400))" +%F)"; do
    resp=$(_afm_req GET "/api/archie/actions?day=$d&project=$p&playbook=$AFM_PLAYBOOK&limit=500"); rc=$?
    if [ "$rc" != 0 ] || ! jq -e '.actions | type == "array"' <<<"$resp" >/dev/null 2>&1; then
      afm_log "$p: the restack ledger for $d could not be read (rc=$rc http=${JOBS_HTTP:-none}); no killed-tick recovery this tick"
      return 1
    fi
    [ "$(jq -r '.truncated == true' <<<"$resp")" = true ] \
      && afm_log "$p: the restack ledger for $d is a full page (500), truncated; recovery uses what was read"
    rows+=$(jq -r '.actions[] | select(.mode == "on" and .action == "restack" and (.outcome == "started" or .outcome == "deferred"))
      | .evidence as $e
      | select(($e.old_head // "" | test("^[0-9a-f]{40}$")) and ($e.parent_head // "" | test("^[0-9a-f]{40}$"))
               and (($e.parent_pr // "") | tostring | test("^[0-9]+$"))
               and ($e.parent_url // "") != "" and ($e.onto // "") != "" and ($e.child_base // "") != "")
      | [(.pr | tostring), $e.old_head, ($e.parent_pr | tostring), $e.parent_url, $e.parent_head, $e.onto, $e.child_base] | @tsv' \
      <<<"$resp" 2>/dev/null)$'\n'
  done
  AFM_RECOVER=$rows
  return 0
}

# afm_recover_classify <pr-json> -> rc 0 when AFM_RECOVER holds a row for this
#   PR, and the PR is still on the row's `onto` with the row's `old_head`: a
#   tick retargeted it and died before its push. Sets AFM_PARENT and
#   AFM_CHILD_BASE exactly as afm_classify does, from the row, so the claim
#   key is the row's own. rc 1 otherwise.
afm_recover_classify() {
  local pr="$1" n base head r_pr r_old r_pn r_pu r_ph r_onto r_cb
  AFM_PARENT=""; AFM_CHILD_BASE=""
  [ -n "${AFM_RECOVER//[$'\n']/}" ] || return 1
  n=$(jq -r '.number // ""' <<<"$pr"); base=$(jq -r '.base.ref // ""' <<<"$pr"); head=$(jq -r '.head.sha // ""' <<<"$pr")
  while IFS=$'\t' read -r r_pr r_old r_pn r_pu r_ph r_onto r_cb; do
    [ -n "$r_pr" ] && [ "$r_pr" = "$n" ] && [ "$r_onto" = "$base" ] && [ "$r_old" = "$head" ] || continue
    AFM_PARENT=$(printf '%s\t%s\t%s\t%s' "$r_pn" "$r_pu" "$r_ph" "$r_onto"); AFM_CHILD_BASE="$r_cb"
    return 0
  done <<<"$AFM_RECOVER"
  return 1
}

# afm_fork_point <slug> <parent-num> <worktree> -> rc 0 sets AFM_FORK (and
#   AFM_FORK_ROW, the row's id): the head the parent had before an Archie
#   restack replayed it, as that row recorded it (`old_head`), when it is in
#   the worktree HEAD's history. Of several (a parent restacked twice) the
#   nearest one, fewest commits to HEAD. rc 1 none recorded, or none in the
#   history; rc 2 the ledger could not be read (or a truncated read found
#   none): the caller defers, never fails, on rc 2.
afm_fork_point() {
  local slug="$1" pn="$2" wt="$3" resp rc c id k best="" bestn="" bestid=""
  AFM_FORK=""; AFM_FORK_ROW=""
  resp=$(_afm_req GET "/api/archie/actions?repo=$slug&pr=$pn&playbook=$AFM_PLAYBOOK&limit=500"); rc=$?
  { [ "$rc" = 0 ] && jq -e '.actions | type == "array"' <<<"$resp" >/dev/null 2>&1; } || return 2
  while IFS=$'\t' read -r c id; do
    [ -n "$c" ] || continue
    git -C "$wt" merge-base --is-ancestor "$c" HEAD >/dev/null 2>&1 || continue
    k=$(git -C "$wt" rev-list --count "$c..HEAD" 2>/dev/null) || continue
    if [ -z "$bestn" ] || [ "$k" -lt "$bestn" ]; then best=$c; bestn=$k; bestid=$id; fi
  done < <(jq -r '.actions[] | select(.mode == "on" and .action == "restack" and .outcome == "done")
      | select((.evidence.old_head // "") | test("^[0-9a-f]{40}$")) | [.evidence.old_head, (.id | tostring)] | @tsv' <<<"$resp" 2>/dev/null)
  if [ -z "$best" ]; then
    [ "$(jq -r '.truncated == true' <<<"$resp")" = true ] && return 2
    return 1
  fi
  AFM_FORK=$best; AFM_FORK_ROW=$bestid
  return 0
}

# afm_claim <key> <project> <slug> <n> <mode> <action> <why> <evidence-json>
#   POST the row with outcome=started BEFORE anything is written anywhere.
#   rc 0  this tick owns the row (new, or a stale `deferred` one reclaimed);
#         AFM_ROW is the row
#   rc 3  the row exists and is not ours to act on (done, would, requested,
#         failed, a fresh deferred/started); or it reached the attempt cap and
#         was closed `failed` here with ONE alert
#   rc 9  the key exists with a different payload (409), refused
#   rc 2  the route is not deployed (404): nothing is done anywhere this tick
#   rc 1  the worker did not answer
afm_claim() {
  local key="$1" p="$2" slug="$3" n="$4" mode="$5" action="$6" why="$7" ev="$8" body resp rc out att upd age ts
  AFM_ROW=""
  body=$(jq -nc --arg k "$key" --arg p "$p" --arg r "$slug" --argjson n "$n" --arg pb "$AFM_PLAYBOOK" \
    --arg m "$mode" --arg a "$action" --arg w "$why" --argjson e "$ev" \
    '{dedupe_key: $k, project: $p, repo: $r, pr: $n, playbook: $pb, mode: $m, action: $a,
      outcome: "started", why: $w, evidence: $e, actor: "archie-fm"}') || return 1
  resp=$(_afm_req POST /api/archie/actions "$body"); rc=$?
  case "$rc" in
    0) ;;
    2) AFM_ROUTE_ABSENT=1; return 2 ;;
    9) afm_log "$slug#$n: $key exists with a different payload (409); refused"; return 9 ;;
    *) afm_log "$slug#$n: the action could not be recorded (rc=$rc http=${JOBS_HTTP:-none}); nothing done"; return 1 ;;
  esac
  AFM_ROW=$(jq -c '.action // empty' <<<"$resp" 2>/dev/null)
  [ -n "$AFM_ROW" ] || { afm_log "$slug#$n: the worker's answer carried no row; nothing done"; return 1; }
  [ "$(jq -r '.created == true' <<<"$resp")" = true ] && return 0
  out=$(jq -r .outcome <<<"$AFM_ROW"); att=$(jq -r '.attempts // 1' <<<"$AFM_ROW"); upd=$(jq -r '.updated_at // ""' <<<"$AFM_ROW")
  # An unreadable stamp is age 0: never stale, so nothing is reclaimed on it.
  ts=""; [ -n "$upd" ] && ts=$(date -u -d "$upd" +%s 2>/dev/null)
  [[ $ts =~ ^[0-9]+$ ]] || ts=$NOW
  age=$(( NOW - ts ))
  case "$out" in
    started)
      # A tick that died mid-action left it started. Once it is stale it is
      # closed deferred, and the next tick reclaims it through the ladder below.
      if [ "$age" -ge "$AFM_RETRY_S" ]; then
        afm_close deferred "" "the tick that started it did not finish" \
          && afm_log "$slug#$n: a started row ${age}s old was closed deferred; retried next tick"
      fi
      AFM_ROW=""; return 3 ;;
    deferred)
      [[ $att =~ ^[0-9]+$ ]] || att=1
      if [ "$att" -ge "$AFM_MAX_ATT" ]; then
        local onto up
        onto=$(jq -r '.evidence.onto // "<base>"' <<<"$AFM_ROW"); up=$(jq -r '.evidence.parent_head // "<parent-head>"' <<<"$AFM_ROW")
        if [ "$AFM_PLAYBOOK" = data-lane ]; then
          onto=$(jq -r '.evidence.file // "<file>"' <<<"$AFM_ROW")
          if afm_close failed "" "deferred $att times"; then
            HARNESS="${AFM_H:-}" "${AFM_H:-}/bin/alert-line.sh" "archie-fm: $slug#$n data-lane apply of $onto deferred $att times; check logs/$p.log for data-lane lines: https://github.com/$slug/pull/$n" >/dev/null 2>&1 || true
            afm_log "$slug#$n: data-lane deferred $att times; closed failed, one alert"
          fi
          AFM_ROW=""; return 3
        fi
        local lastwhy
        lastwhy=$(jq -r '.why // "no reason recorded"' <<<"$AFM_ROW" | cut -c1-200)
        if afm_close failed "" "deferred $att times"; then
          if [ "$AFM_PLAYBOOK" = rebase-repair ]; then
            HARNESS="${AFM_H:-}" "${AFM_H:-}/bin/alert-line.sh" "archie-fm: $slug#$n rebase-repair could not run after $att tries ($lastwhy); bin/blocked-resolver.sh's fix round takes the park now. Check this box's isolated runner (setpriv, nobody, tmp space): https://github.com/$slug/pull/$n" >/dev/null 2>&1 || true
          else
          HARNESS="${AFM_H:-}" "${AFM_H:-}/bin/alert-line.sh" "archie-fm: $slug#$n stacked on a merged parent could not be restacked after $att tries. Run \`git rebase --onto origin/$onto $up\` on it and push: https://github.com/$slug/pull/$n" >/dev/null 2>&1 || true
          fi
          afm_log "$slug#$n: deferred $att times; closed failed, one alert"
        fi
        AFM_ROW=""; return 3
      fi
      [ "$age" -ge "$AFM_RETRY_S" ] || { AFM_ROW=""; return 3; }
      if afm_close started "" "" "" ; then
        afm_log "$slug#$n: deferred row reclaimed (attempt $(jq -r .attempts <<<"$AFM_ROW"))"
        return 0
      fi
      AFM_ROW=""; return 3 ;;
    *) AFM_ROW=""; return 3 ;;
  esac
}

# afm_close <outcome> [action] [why] [evidence-json] — the CAS on the owned row.
#   rc 0 written (AFM_ROW is the new row); rc 1 not written, logged.
afm_close() {
  local out="$1" action="${2:-}" why="${3:-}" ev="${4:-}" body resp rc
  [ -n "$AFM_ROW" ] || return 1
  body=$(jq -nc --argjson r "$AFM_ROW" --arg o "$out" --arg a "$action" --arg w "$why" --arg e "$ev" \
    '{id: $r.id, dedupe_key: $r.dedupe_key, expect_updated_at: $r.updated_at, outcome: $o}
     + (if $a == "" then {} else {action: $a} end)
     + (if $w == "" then {} else {why: $w} end)
     + (if $e == "" then {} else {evidence: ($e | fromjson)} end)') || return 1
  resp=$(_afm_req POST /api/archie/actions/outcome "$body"); rc=$?
  if [ "$rc" = 0 ] && jq -e '.action.id' <<<"$resp" >/dev/null 2>&1; then
    AFM_ROW=$(jq -c .action <<<"$resp"); return 0
  fi
  afm_log "$(jq -r '.repo + "#" + (.pr | tostring)' <<<"$AFM_ROW"): closing the row $out failed (rc=$rc http=${JOBS_HTTP:-none})"
  return 1
}

# afm_isolated <worktree> <target> <outfile> <bound-s> <cmd...> -> the
#   command's rc; 125 when it could not be run at all.
#   PR CODE NEVER RUNS AS THE LANE. The suites are the child PR's own code
#   (its package.json scripts, its bin/test-impact-gate.sh), unreviewed, and
#   the lane is root with the hub's env exported (env/global.env, the jobs
#   bearer, a GitHub token). So the run is bin/test-impact-gate.sh's
#   isolated_run shape: a SNAPSHOT of the replayed tree (git archive of
#   origin/<target>, then of HEAD, as two commits in a fresh repo, so a gate
#   that diffs against origin/<target> still can), owned by `nobody`, run
#   through setpriv under `env -i` with an explicit allowlist. Nothing of the
#   lane's environment, its .git/config or the hub clone reaches it. A hub
#   node_modules is COPIED into the snapshot (never linked: a suite must not
#   write a tree other hub work reads). The runner is backgrounded and waited
#   on, so a TERM to the tick reaches the trap at once (afm_on_term kills it).
#   ARCHIE_FM_SUITE_AS=self (HARNESS_TEST_SANDBOX=1 only) keeps the snapshot
#   and the env -i but skips the uid switch, for a suite that cannot setpriv.
afm_isolated() {
  local wt="$1" target="$2" out="$3" bound="$4" as=nobody w uid="" gid="" nm r
  shift 4
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ "${ARCHIE_FM_SUITE_AS:-}" = self ]; then as=self; fi
  if [ "$as" = nobody ]; then
    command -v setpriv >/dev/null 2>&1 || { echo "archie-fm: isolated runner: setpriv is not installed" >> "$out"; return 125; }
    uid=$(id -u nobody 2>/dev/null) && gid=$(id -g nobody 2>/dev/null) \
      || { echo "archie-fm: isolated runner: there is no 'nobody' user" >> "$out"; return 125; }
    setpriv --reuid="$uid" --regid="$gid" --clear-groups true >/dev/null 2>&1 \
      || { echo "archie-fm: isolated runner: setpriv cannot switch to nobody here" >> "$out"; return 125; }
  fi
  w=$(mktemp -d "${TMPDIR:-/tmp}/afm-suite-XXXXXX") || return 125
  AFM_CUR_SNAP="$w"
  if ! { mkdir -p "$w/repo" "$w/home" "$w/tmp" \
      && git -C "$wt" archive --format=tar "origin/$target" | tar -x -C "$w/repo" \
      && ( cd "$w/repo" && git init -q && git add -A \
           && git -c user.email=afm@harness -c user.name=afm -c commit.gpgsign=false commit -qm base --allow-empty \
           && git update-ref "refs/remotes/origin/$target" HEAD && git rm -rqf --ignore-unmatch . ) >/dev/null 2>&1 \
      && git -C "$wt" archive --format=tar HEAD | tar -x -C "$w/repo" \
      && ( cd "$w/repo" && git add -A \
           && git -c user.email=afm@harness -c user.name=afm -c commit.gpgsign=false commit -qm head --allow-empty ) >/dev/null 2>&1; }; then
    echo "archie-fm: isolated runner: could not snapshot the replayed tree" >> "$out"
    rm -rf "$w"; AFM_CUR_SNAP=""; return 125
  fi
  nm="${MC_REPOS:-/root/repos}/${AFM_PROJECT:-}/node_modules"
  if [ -f "$w/repo/package.json" ] && [ -n "${AFM_PROJECT:-}" ] && [ -d "$nm" ]; then
    cp -a --reflink=auto "$nm" "$w/repo/node_modules" 2>/dev/null \
      || { echo "archie-fm: isolated runner: could not copy $nm" >> "$out"; rm -rf "$w"; AFM_CUR_SNAP=""; return 125; }
  elif grep -q '"\(dev\)\{0,1\}[dD]ependencies"' "$w/repo/package.json" 2>/dev/null; then
    # No installed tree for a package with dependencies: the suites cannot run,
    # which is "could not run" (deferred), never "red" (review I5: a red here
    # parks the PR for paid fix rounds it does not need).
    echo "archie-fm: isolated runner: no node_modules at $nm for a package with dependencies" >> "$out"
    rm -rf "$w"; AFM_CUR_SNAP=""; return 125
  fi
  if [ "$as" = nobody ]; then
    chmod 711 "$w" && chown -R "$uid:$gid" "$w" \
      && setpriv --reuid="$uid" --regid="$gid" --clear-groups test -w "$w/repo" \
      || { echo "archie-fm: isolated runner: nobody cannot reach the snapshot (is ${TMPDIR:-/tmp} traversable?)" >> "$out"
           rm -rf "$w"; AFM_CUR_SNAP=""; return 125; }
    timeout -k 30 "$bound" setpriv --reuid="$uid" --regid="$gid" --clear-groups \
      env -i PATH="$PATH" HOME="$w/home" TMPDIR="$w/tmp" LANG=C.UTF-8 LC_ALL=C.UTF-8 HARNESS_TEST_SANDBOX=1 \
      bash -c 'cd "$1" || exit 125; shift; exec "$@"' _ "$w/repo" "$@" >> "$out" 2>&1 </dev/null 4>&- 5>&- 7>&- 8>&- 9>&- &
  else
    timeout -k 30 "$bound" \
      env -i PATH="$PATH" HOME="$w/home" TMPDIR="$w/tmp" LANG=C.UTF-8 LC_ALL=C.UTF-8 HARNESS_TEST_SANDBOX=1 \
      bash -c 'cd "$1" || exit 125; shift; exec "$@"' _ "$w/repo" "$@" >> "$out" 2>&1 </dev/null 4>&- 5>&- 7>&- 8>&- 9>&- &
  fi
  AFM_SUITE_PID=$!
  wait "$AFM_SUITE_PID"; r=$?
  AFM_SUITE_PID=""
  rm -rf "$w"; AFM_CUR_SNAP=""
  return "$r"
}

# afm_suites <worktree> <target> <outfile> -> rc 0 green, 1 red, 2 could not
#   run. AFM_SUITES names what ran (or `none`), AFM_SUITES_RED the red ones.
#   The pick is HARNESS_SUITE_RUN's (bin/lib/rb/gates.sh): package.json's
#   test:unit (with typecheck when declared), else its test, else the
#   checkout's own bin/test-impact-gate.sh, else nothing, and CI on the push
#   is the gate. Every run goes through afm_isolated, and is bounded by
#   AFM_SUITE_TIMEOUT_S or the time the tick has left, whichever is less.
#   AFM_SUITES_LOCAL is 0 only on that last path (no local suite exists).
afm_suites() {
  local wt="$1" target="$2" out="$3" rc cmd bound left
  AFM_SUITES=none; AFM_SUITES_RED=""; AFM_SUITES_LOCAL=1
  : > "$out"
  if grep -q '"test:unit"\|"test"' "$wt/package.json" 2>/dev/null; then
    AFM_SUITES=""
    for cmd in typecheck test:unit test; do
      grep -q "\"$cmd\"" "$wt/package.json" || continue
      [ "$cmd" = test ] && [[ $AFM_SUITES == *test:unit* ]] && continue
      left=$(( $(afm_time_left) - 60 )); bound=$AFM_SUITE_TIMEOUT_S
      [ "$left" -lt "$bound" ] && bound=$left
      [ "$bound" -gt 0 ] || { AFM_SUITES="${AFM_SUITES:+$AFM_SUITES, }npm run $cmd (no time left in the tick)"; return 2; }
      afm_isolated "$wt" "$target" "$out" "$bound" npm run "$cmd"; rc=$?
      AFM_SUITES="${AFM_SUITES:+$AFM_SUITES, }npm run $cmd (rc $rc)"
      case "$rc" in
        0) ;;
        124|125|126|127|137) return 2 ;;
        *) AFM_SUITES_RED="${AFM_SUITES_RED:+$AFM_SUITES_RED }npm-run-$cmd" ;;
      esac
    done
    [ -z "$AFM_SUITES_RED" ] || return 1
    return 0
  fi
  if [ -x "$wt/bin/test-impact-gate.sh" ]; then
    left=$(( $(afm_time_left) - 60 )); bound=$AFM_SUITE_TIMEOUT_S
    [ "$left" -lt "$bound" ] && bound=$left
    [ "$bound" -gt 0 ] || { AFM_SUITES="bin/test-impact-gate.sh (no time left in the tick)"; return 2; }
    afm_isolated "$wt" "$target" "$out" "$bound" bin/test-impact-gate.sh --base "origin/$target" --head HEAD; rc=$?
    AFM_SUITES="bin/test-impact-gate.sh --base origin/$target (rc $rc)"
    case "$rc" in
      0) return 0 ;;
      1) AFM_SUITES_RED=$(sed -n 's/^impact-gate: done \([^ ]*\) rc=[1-9][0-9]*$/\1/p' "$out" | tr '\n' ' ' | sed 's/ *$//')
         [ -n "$AFM_SUITES_RED" ] || AFM_SUITES_RED="bin/test-impact-gate.sh"
         return 1 ;;
      *) return 2 ;;
    esac
  fi
  AFM_SUITES="none (no gate in this repo); CI on the push is the gate"
  AFM_SUITES_LOCAL=0
  return 0
}

# afm_request_fix_round <slug> <n> <head> <reason> — the conductor park that
#   bin/blocked-resolver.sh drains (conflict-unresolvable / rebase-gate-red are
#   hand-offs, mc_handoff_owns): mechanical rung, then its capped fix round,
#   then a rebuild. Written with the head/reviewed/url columns the current row
#   carries, as mc_stack_follow writes it.
afm_request_fix_round() {
  local slug="$1" n="$2" head="$3" why="$4" key url row
  key="$slug#$n"; url="https://github.com/$slug/pull/$n"
  row=$(mc_row_get "$key")
  mc_transition "$key" BLOCKED_HUMAN "$why" "$head" "$(cut -f5 <<<"$row")" "$url" - UNKNOWN \
    "$(mc_record_for "$url" || true)" >/dev/null
}

# afm_restack <project> <slug> <n> <child-branch> <child-head> <parent-num>
#   <parent-url> <parent-head> <target> <child-base>
#   The on-mode playbook, steps a-e above. Prints nothing; sets AFM_RES_*:
#   rc 0 pushed (AFM_RES_NEW, AFM_RES_FORK, AFM_RES_FORK_FROM) | 1 noop
#   (AFM_RES_WHY) | 2 conflict (AFM_RES_FILES) | 3 red suites | 4 deferred
#   (AFM_RES_WHY) | 5 stranded: the push was refused after the retarget AND
#   the base could not be put back on <child-base> (AFM_RES_WHY) | 6 no fork
#   point: the parent's head is not in the child's history and no Archie
#   restack of the parent recorded one that is (AFM_RES_WHY; nothing was
#   written, the caller closes it failed with one alert). A deferred action always leaves the
#   PR on <child-base>, so the next tick classifies it again and the retry
#   ladder (and its one alert at the cap) can reach it; a PR retargeted but
#   not pushed is invisible to every later tick, so it is never left deferred.
afm_restack() {
  local p="$1" slug="$2" n="$3" br="$4" head="$5" pn="$6" purl="$7" phead="$8" target="$9" obase="${10:-}"
  local url="https://github.com/$slug/pull/$n" repo wt cloned="" remote ferr rerr conf own new src rc fork frc
  repo="${MC_REPOS:-/root/repos}/$p"
  AFM_RES_NEW=""; AFM_RES_WHY=""; AFM_RES_FILES=""; AFM_RES_OWN=0; AFM_PROJECT="$p"
  AFM_RES_FORK=""; AFM_RES_FORK_FROM=""; AFM_FORK_ROW=""
  [ -n "$obase" ] || { AFM_RES_WHY="the child's current base is unknown"; return 4; }
  mc_tmp_room "$url" archie-fm || { AFM_RES_WHY="tmp full"; return 4; }
  mc_git_auth "$slug" || { mc_git_auth_clear; AFM_RES_WHY="no configured token can read $slug"; return 4; }
  remote="$MC_REMOTE"
  if [ -d "$repo/.git" ]; then
    wt=$(mktemp -d "${TMPDIR:-/tmp}/afm-restack-XXXX") || { mc_git_auth_clear; AFM_RES_WHY="mktemp failed"; return 4; }
    git -C "$repo" remote set-url origin "$remote" >/dev/null 2>&1 || true
    ferr=$(git -C "$repo" -c credential.helper= fetch -q origin "$target" "$br" 2>&1 >/dev/null) || {
      AFM_RES_WHY="fetch on the hub clone failed: $(mc_git_fail_line "$ferr")"; rm -rf "$wt"; mc_git_auth_clear; return 4; }
    ferr=$(git -C "$repo" worktree add -f --detach "$wt" "origin/$br" 2>&1 >/dev/null) || {
      AFM_RES_WHY="worktree add failed: $(mc_git_fail_line "$ferr")"; rm -rf "$wt"; mc_git_auth_clear; return 4; }
  else
    wt="$MC_H/tmp/conductor/${slug//\//_}"; mkdir -p "$(dirname "$wt")"; cloned=1
    if [ ! -d "$wt/.git" ]; then
      ferr=$(git -c credential.helper= clone -q --filter=blob:none "$remote" "$wt" 2>&1 >/dev/null) || {
        AFM_RES_WHY="scratch clone failed: $(mc_git_fail_line "$ferr")"; mc_git_auth_clear; return 4; }
    else
      git -C "$wt" remote set-url origin "$remote" >/dev/null 2>&1 || true
    fi
    ferr=$(git -C "$wt" -c credential.helper= fetch -q origin "$target" "$br" 2>&1 >/dev/null) || {
      AFM_RES_WHY="fetch on the scratch clone failed: $(mc_git_fail_line "$ferr")"; mc_git_auth_clear; return 4; }
    git -C "$wt" checkout -q --detach "origin/$br" 2>/dev/null || { AFM_RES_WHY="checkout failed"; mc_git_auth_clear; return 4; }
  fi
  AFM_CUR_REPO="$repo"; AFM_CUR_WT="$wt"; AFM_CUR_CLONED="$cloned"
  # a. the lease: a head that moved since the list is somebody else's work.
  if [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" != "$head" ]; then
    AFM_RES_WHY="the head moved since the list read it"; mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 4
  fi
  # b. the fork point: the parent's pre-merge head when it is in this branch's
  #    history, else the head an Archie restack of the parent recorded before
  #    it replayed the parent (a stack of three). The branch must have commits
  #    of its own above it.
  fork="$phead"; AFM_RES_FORK_FROM=parent_head
  if ! git -C "$wt" merge-base --is-ancestor "$phead" HEAD >/dev/null 2>&1; then
    afm_fork_point "$slug" "$pn" "$wt"; frc=$?
    case "$frc" in
      0) fork="$AFM_FORK"; AFM_RES_FORK_FROM=ledger ;;
      2) AFM_RES_WHY="the restack ledger for #$pn could not be read"; mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 4 ;;
      *) AFM_RES_WHY="parent head not in child history, and no Archie restack of #$pn recorded a head that is"
         mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 6 ;;
    esac
  fi
  AFM_RES_FORK="$fork"
  own=$(git -C "$wt" rev-list --count "$fork..HEAD" 2>/dev/null)
  AFM_RES_OWN=${own:-0}
  if [ "${own:-0}" = 0 ]; then
    AFM_RES_WHY="no own commits"; mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 1
  fi
  # >>> afm replay
  # c. replay ONLY the commits above the fork point.
  rerr=$(git -C "$wt" -c user.name="${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}" -c user.email="${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}" \
           -c commit.gpgsign=false rebase --onto "origin/$target" "$fork" 2>&1 >/dev/null)
  rc=$?
  # <<< afm replay
  if [ "$rc" != 0 ]; then
    conf=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)
    git -C "$wt" rebase --abort >/dev/null 2>&1
    mc_rebase_cleanup "$repo" "$wt" "$cloned"
    if [ -n "$conf" ]; then AFM_RES_FILES=$(tr '\n' ' ' <<<"$conf" | sed 's/ *$//'); return 2; fi
    AFM_RES_WHY="rebase --onto refused: $(mc_git_err_line "${rerr:-(no stderr)}")"; return 4
  fi
  new=$(git -C "$wt" rev-parse HEAD)
  # d. the selected suites, on the replayed tree. The token is disarmed first
  #    (afm_isolated also runs them under env -i, as nobody) and re-armed only
  #    for the retarget and the push.
  mc_git_auth_clear
  src=$(mktemp "${TMPDIR:-/tmp}/afm-suites.XXXXXX") || { mc_rebase_cleanup "$repo" "$wt" "$cloned"; AFM_RES_WHY="mktemp failed"; return 4; }
  # A red made only of known flakes is run once more first (BH-4585).
  if command -v afm_suites_flaky >/dev/null 2>&1; then afm_suites_flaky "$wt" "$target" "$src" "$slug"; else afm_suites "$wt" "$target" "$src"; fi; rc=$?
  rm -f "$src"
  case "$rc" in
    1) mc_rebase_cleanup "$repo" "$wt" "$cloned"; return 3 ;;
    2) mc_rebase_cleanup "$repo" "$wt" "$cloned"; AFM_RES_WHY="the suites could not run: $AFM_SUITES"; return 4 ;;
  esac
  mc_git_auth "$slug" || { mc_rebase_cleanup "$repo" "$wt" "$cloned"; AFM_RES_WHY="no configured token can push $slug; nothing pushed"; return 4; }
  remote="$MC_REMOTE"
  # e. retarget FIRST, then the push (the push is the CI trigger).
  if ! mc_retarget_base "$slug" "$n" "$target"; then
    mc_rebase_cleanup "$repo" "$wt" "$cloned"; AFM_RES_WHY="the base PATCH to $target was refused; nothing pushed"; return 4
  fi
  AFM_CUR_REVERT=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$slug" "$n" "$obase" "$br" "$new" "$remote")
  # HOLD_PUSH_CHILDREN=follow (BH-5234): this restack records this branch's own
  # children and their heads in its row, and the next tick restacks them from
  # the ledger, so hold_push's rewrite guard does not refuse it.
  if ! { mc_hold_push_load && HOLD_PUSH_CHILDREN=follow HOLD_PUSH_LOG="${AFM_LOG:-}" hold_push -n "$p" - "$wt" "$remote" HEAD "$br" "$head" >/dev/null 2>&1; }; then
    AFM_CUR_REVERT=""
    mc_rebase_cleanup "$repo" "$wt" "$cloned"
    if mc_retarget_base "$slug" "$n" "$obase"; then
      AFM_RES_WHY="the push was refused (lease or hold); the base is back on $obase, so a later tick sees it again"; return 4
    fi
    AFM_RES_WHY="the push was refused (lease or hold) and the base could not be put back on $obase: the PR targets $target and still carries the parent's pre-squash commits"
    return 5
  fi
  AFM_CUR_REVERT=""
  mc_rebase_cleanup "$repo" "$wt" "$cloned"
  AFM_RES_NEW="$new"
  return 0
}

# afm_on_term — the TERM/INT/HUP trap bin/archie-fm.sh sets: a tick stopped
#   mid-action (its outer timeout, a kill) undoes what it started instead of
#   leaving it for the stale-row ladder. It kills the suite runner, removes the
#   snapshot and the worktree, puts a retarget whose push did not land back on
#   the child's base (the remote head is read first: a push that landed keeps
#   its retarget), and closes this tick's `started` row deferred, so the next
#   tick past ARCHIE_FM_RETRY_S retries it. A base it cannot put back is the
#   stranded case: the row closes failed with ONE alert.
afm_on_term() {
  local slug n obase br new remote cur
  trap - TERM INT HUP
  if [ -n "${AFM_SUITE_PID:-}" ]; then kill -TERM "$AFM_SUITE_PID" 2>/dev/null; wait "$AFM_SUITE_PID" 2>/dev/null; AFM_SUITE_PID=""; fi
  [ -n "${AFM_CUR_SNAP:-}" ] && rm -rf "$AFM_CUR_SNAP"
  AFM_CUR_SNAP=""
  if [ -n "${AFM_CUR_REVERT:-}" ]; then
    IFS=$'\t' read -r slug n obase br new remote <<<"$AFM_CUR_REVERT"
    cur=$(git -c credential.helper= ls-remote "$remote" "refs/heads/$br" 2>/dev/null | cut -f1)
    if [ "$cur" != "$new" ]; then
      if mc_retarget_base "$slug" "$n" "$obase"; then
        afm_log "$slug#$n: the tick was stopped between the retarget and the push; the base is back on $obase"
      else
        afm_strand "$slug" "$n" "the tick was stopped between the retarget and the push, and the base could not be put back on $obase"
      fi
    fi
    AFM_CUR_REVERT=""
  fi
  [ -n "${AFM_CUR_WT:-}" ] && mc_rebase_cleanup "$AFM_CUR_REPO" "$AFM_CUR_WT" "$AFM_CUR_CLONED"
  AFM_CUR_WT=""
  if [ -n "${AFM_ROW:-}" ] && [ "$(jq -r .outcome <<<"$AFM_ROW" 2>/dev/null)" = started ]; then
    afm_close deferred "" "the tick was stopped mid-action (its deadline or a signal); nothing pushed" \
      && afm_log "$(jq -r '.repo + "#" + (.pr | tostring)' <<<"$AFM_ROW"): the tick was stopped mid-action; the row is deferred"
  fi
  return 0
}

# afm_strand <slug> <n> <why> [hand-fix] — the one thing a later tick cannot
#   see: a PR retargeted onto its parent's base without the push that replays
#   it, or a child with no fork point to replay from. The owned row closes
#   failed and ONE alert says what to do by hand (<hand-fix>, else the rebase
#   onto the row's own onto and parent head).
afm_strand() {
  local slug="$1" n="$2" why="$3" fix="${4:-}" onto up
  onto=$(jq -r '.evidence.onto // "<base>"' <<<"${AFM_ROW:-null}" 2>/dev/null); up=$(jq -r '.evidence.parent_head // "<parent-head>"' <<<"${AFM_ROW:-null}" 2>/dev/null)
  [ -n "$fix" ] || fix="Run \`git rebase --onto origin/$onto $up\` on it and push"
  afm_close failed "" "$why" || true
  HARNESS="${AFM_H:-}" "${AFM_H:-}/bin/alert-line.sh" "archie-fm: $slug#$n $why. $fix: https://github.com/$slug/pull/$n" >/dev/null 2>&1 || true
  afm_log "$slug#$n: $why; closed failed, one alert"
}

# afm_act <project> <slug> <n> <mode> <child-branch> <child-head> <parent-num>
#   <parent-url> <parent-head> <target> <conductor-state> <child-base>
#   Claim, then observe or the playbook, then close the row. Sets AFM_RESULT,
#   one word for the tick's counters: restacked | fix_round | would | deferred
#   | noop | failed | none (nothing done: not ours, refused, or unrecorded). Not printed:
#   a caller's $( ) would lose AFM_ROUTE_ABSENT.
afm_act() {
  local p="$1" slug="$2" n="$3" mode="$4" br="$5" head="$6" pn="$7" purl="$8" phead="$9" target="${10}" cst="${11}" obase="${12:-}"
  local key ev rc why files kids
  AFM_RESULT=none
  key="$AFM_PLAYBOOK:$slug#$n:$head:$phead:$mode"
  ev=$(jq -nc --arg o "$target" --arg u "$phead" --arg h "$head" --argjson pn "$pn" --arg pu "$purl" --arg cs "$cst" --arg cb "$obase" \
    '{onto: $o, parent_head: $u, old_head: $h, parent_pr: $pn, parent_url: $pu, retarget: $o, conductor_state: $cs, child_base: $cb}')
  # >>> afm claim
  if [ "$mode" = on ]; then
    afm_cap_claim "$p" afm_claim "$key" "$p" "$slug" "$n" on restack "stacked on #$pn, which merged" "$ev"; rc=$?
  else
    afm_claim "$key" "$p" "$slug" "$n" observe would_restack "stacked on #$pn, which merged" "$ev"; rc=$?
  fi
  [ "$rc" = 0 ] || return 0
  # <<< afm claim
  # >>> afm observe
  if [ "$mode" != on ]; then
    afm_close would would_restack \
      "would rebase --onto origin/$target ${phead:0:12} and retarget to $target (observe mode)" "$ev" || true
    afm_log "$slug#$n: would restack onto $target (parent=#$pn, upstream ${phead:0:8}); observe mode, nothing written"
    AFM_RESULT=would; return 0
  fi
  # <<< afm observe
  afm_restack "$p" "$slug" "$n" "$br" "$head" "$pn" "$purl" "$phead" "$target" "$obase"; rc=$?
  AFM_CUR_WT=""
  case "$rc" in
    0)
      # The children of the branch just pushed, from the list this tick read
      # (at most 20: the evidence is bounded). Their replay later starts from
      # old_head, the head this push replaced (afm_fork_point).
      kids=$(jq -c --arg br "$br" '[.[]? | select(.base.ref == $br) | {pr: .number, head: .head.sha}] | .[0:20]' \
        <<<"${AFM_OPEN_LIST:-[]}" 2>/dev/null)
      [ -n "$kids" ] || kids="[]"
      ev=$(jq -c --arg nh "$AFM_RES_NEW" --argjson own "$AFM_RES_OWN" --arg s "$AFM_SUITES" --argjson ls "${AFM_SUITES_LOCAL:-1}" \
        --arg fp "$AFM_RES_FORK" --arg ff "$AFM_RES_FORK_FROM" --arg fr "${AFM_FORK_ROW:-}" --argjson kids "$kids" \
        '. + {new_head: $nh, own_commits: $own, suites: $s, local_suites: ($ls == 1), fork_point: $fp, fork_from: $ff,
              children: $kids} + (if $fr == "" then {} else {fork_row: ($fr | tonumber)} end)' <<<"$ev")
      afm_close done restack "replayed $AFM_RES_OWN own commit(s) onto $target, retargeted, pushed; CI pending" "$ev" || true
      afm_log "$slug#$n: restacked onto $target after parent=#$pn merged (${AFM_RES_NEW:0:8}); retargeted and pushed, CI pending$([ "${AFM_SUITES_LOCAL:-1}" = 0 ] && printf '; no local suites ran, CI is the gate')"
      jq -r '.[] | "\(.pr)\t\(.head)"' <<<"$kids" | while IFS=$'\t' read -r k _; do
        afm_log "$slug#$k is stacked on $br; it replays from ${head:0:12} when #$n merges"
      done
      AFM_RESULT=restacked ;;
    1)
      afm_close done noop "$AFM_RES_WHY" "$(jq -c --argjson own "$AFM_RES_OWN" '. + {own_commits: $own}' <<<"$ev")" || true
      afm_log "$slug#$n: $AFM_RES_WHY; nothing to restack"
      AFM_RESULT=noop ;;
    2|3)
      files="$AFM_RES_FILES"
      if [ "$rc" = 2 ]; then
        why="conflict-unresolvable: stacked child of parent=#$pn ($purl) — rebase --onto $target conflicts in: $files (archie-fm)"
        ev=$(jq -c --arg f "$files" '. + {conflicts: ($f | split(" "))}' <<<"$ev")
      else
        why="rebase-gate-red: stacked child of parent=#$pn replayed onto $target, suites red: $AFM_SUITES_RED (archie-fm)"
        ev=$(jq -c --arg s "$AFM_SUITES" --arg r "$AFM_SUITES_RED" '. + {suites: $s, suites_red: ($r | split(" "))}' <<<"$ev")
      fi
      mc_retarget_base "$slug" "$n" "$target" || afm_log "$slug#$n: retarget to $target refused (best effort; the park still goes in)"
      afm_request_fix_round "$slug" "$n" "$head" "$why"
      afm_close requested fix_round "$why" "$ev" || true
      afm_log "$slug#$n: $why; parked for bin/blocked-resolver.sh, nothing pushed"
      AFM_RESULT=fix_round ;;
    5)
      afm_strand "$slug" "$n" "$AFM_RES_WHY"
      AFM_RESULT=failed ;;
    6)
      afm_strand "$slug" "$n" "$AFM_RES_WHY" \
        "Find the commit it was cut from, run \`git rebase --onto origin/$target <fork-point>\` on it, retarget it to $target and push"
      AFM_RESULT=failed ;;
    *)
      afm_close deferred "" "$AFM_RES_WHY" "$ev" || true
      afm_log "$slug#$n: deferred: $AFM_RES_WHY"
      AFM_RESULT=deferred ;;
  esac
  return 0
}

# afm_classify_data_lane <project> <slug> <pr-json> <url> -> rc 0 a data-lane
#   candidate, and AFM_DL=`<build-dir>\t<path>\t<head>` (a global, as
#   AFM_PARENT); rc 1 not one; rc 2 the PR's file list could not be read
#   (GH_REST_STATUS says why). Cheapest first: the record and a DATA_LANE line
#   in its review cost no GitHub read, so an ordinary PR never pays one. A full
#   page of 100 files may be cut, and a path missing from it is rc 1 (fail
#   closed). Writes nothing anywhere.
afm_classify_data_lane() {
  local p="$1" slug="$2" pr="$3" url="$4" n head dir tmp rc cand
  AFM_DL=""
  type dl_candidate >/dev/null 2>&1 && type dl_reviewed_sha >/dev/null 2>&1 || return 1
  n=$(jq -r .number <<<"$pr"); head=$(jq -r '.head.sha // ""' <<<"$pr")
  [[ $n =~ ^[0-9]+$ ]] && [[ $head =~ ^[0-9a-f]{40}$ ]] || return 1
  dir=$(mc_record_for "$url") || return 1
  [ -r "$dir/review.md" ] && grep -q 'DATA_LANE:' "$dir/review.md" || return 1
  [ "$(dl_reviewed_sha "$dir")" = "$head" ] || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/afm-dl-files.XXXXXX") || return 2
  rc=0; gh_rest GET "repos/$slug/pulls/$n/files?per_page=100" > "$tmp" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; return 2; fi
  jq -r '.[].filename // empty' "$tmp" > "$tmp.names" 2>/dev/null
  rc=0; cand=$(dl_candidate "$dir/review.md" "$tmp.names") || rc=$?
  rm -f "$tmp" "$tmp.names"
  [ "$rc" = 0 ] || return 1
  AFM_DL=$(printf '%s\t%s\t%s' "$dir" "${cand#*$'\t'}" "$head")
  return 0
}

# afm_dl_act <project> <slug> <n> <mode> <head> <build-dir> <path>
#   Claim, then observe or ONE bin/data-lane-apply.sh, then close the row. The
#   playbook is local, so afm_cap_ok reads archie.cap.data-lane and counts only
#   data-lane rows, and afm_claim writes playbook data-lane. Sets AFM_RESULT:
#   applied | would | deferred | skipped | escalated | failed | none.
#   rc and word -> outcome: 0 + applied/already-applied done; 0 with any other
#   word deferred (the lane gate is off: it prints nothing and exits 0); 1 and 2
#   failed (the script ledgered and alerted; Archie does not alert again); 75,
#   124, 137 deferred; 3 skipped/not_candidate; 5 skipped/no_path (escalated);
#   anything else failed, a terminal row rather than a retry storm.
afm_dl_act() {
  local p="$1" slug="$2" n="$3" mode="$4" head="$5" dir="$6" file="$7"
  local AFM_PLAYBOOK=data-lane
  local key ev rc word out bound left
  AFM_RESULT=none
  key="data-lane:$p:$n:${head:0:12}"
  ev=$(jq -nc --arg d "$dir" --arg f "$file" --arg h "$head" '{build_dir: $d, file: $f, head: $h}')
  # >>> dl claim
  if [ "$mode" = on ]; then
    afm_cap_claim "$p" afm_claim "$key" "$p" "$slug" "$n" on apply "apply $file ahead of merge" "$ev"; rc=$?
  else
    afm_claim "$key:observe" "$p" "$slug" "$n" observe would_apply "apply $file ahead of merge" "$ev"; rc=$?
  fi
  [ "$rc" = 0 ] || return 0
  # <<< dl claim
  if [ "$mode" != on ]; then
    afm_close would would_apply "would apply $file ahead of merge (observe mode)" "$ev" || true
    afm_log "$slug#$n: data-lane: would apply $file ahead of merge; observe mode, nothing called"
    AFM_RESULT=would; return 0
  fi
  left=$(( $(afm_time_left) - 60 )); bound=$AFM_DL_BOUND_S
  [ "$left" -lt "$bound" ] && bound=$left
  if [ "$bound" -le 0 ] || ! out=$(mktemp "${TMPDIR:-/tmp}/afm-dl-out.XXXXXX"); then
    afm_close deferred "" "no time left in the tick, or no temp file; nothing called" "$ev" || true
    AFM_RESULT=deferred; return 0
  fi
  # Backgrounded and waited on, as a suite: a TERM to the tick reaches
  # afm_on_term at once, which kills the apply and closes this row deferred.
  timeout -k 10 "$bound" "${AFM_H:-}/bin/data-lane-apply.sh" "$p" "$n" "$dir" > "$out" 2>/dev/null </dev/null 4>&- 5>&- 8>&- 9>&- &
  AFM_SUITE_PID=$!
  wait "$AFM_SUITE_PID"; rc=$?
  AFM_SUITE_PID=""
  word=$(sed -n 1p "$out" | tr -d '[:space:]'); rm -f "$out"
  ev=$(jq -c --arg w "$word" --argjson rc "$rc" '. + {word: $w, rc: $rc}' <<<"$ev")
  case "$rc:$word" in
    0:applied|0:already-applied)
      afm_close done apply "applied $file ahead of merge ($word)" "$ev" || true
      afm_log "$slug#$n: data-lane: $file $word ahead of merge (head ${head:0:12})"
      AFM_RESULT=applied ;;
    0:*)
      afm_close deferred "" "bin/data-lane-apply.sh exited 0 with no outcome word (the data-lane lane is off)" "$ev" || true
      afm_log "$slug#$n: data-lane: the apply answered no outcome word (lane off); deferred"
      AFM_RESULT=deferred ;;
    1:*)
      afm_close failed apply "the apply of $file failed; bin/data-lane-apply.sh ledgered and alerted it" "$ev" || true
      afm_log "$slug#$n: data-lane: the apply of $file failed (${word:-no word}); closed failed"
      AFM_RESULT=failed ;;
    2:*)
      afm_close failed apply "check-migration-appliable flagged $file; it is never applied ahead of merge" "$ev" || true
      afm_log "$slug#$n: data-lane: $file flagged by the classifier; closed failed"
      AFM_RESULT=failed ;;
    75:*|124:*|137:*)
      afm_close deferred "" "bin/data-lane-apply.sh said come back later (rc $rc${word:+, $word})" "$ev" || true
      afm_log "$slug#$n: data-lane: the apply of $file deferred (rc $rc${word:+, $word})"
      AFM_RESULT=deferred ;;
    3:*)
      afm_close skipped not_candidate "bin/data-lane-apply.sh: not a data-lane candidate at ${head:0:12}" "$ev" || true
      afm_log "$slug#$n: data-lane: the apply said not a candidate at ${head:0:12}; skipped"
      AFM_RESULT=skipped ;;
    5:*)
      afm_close skipped no_path "no apply path for $p (DATA_LANE_APP_BASE or MIGRATION_TOKEN unset)" "$ev" || true
      afm_log "$slug#$n: data-lane: no apply path for $p; skipped, the resolver escalates it"
      AFM_RESULT=escalated ;;
    *)
      afm_close failed apply "bin/data-lane-apply.sh exited $rc (${word:-no word}); not understood, not retried" "$ev" || true
      afm_log "$slug#$n: data-lane: the apply exited $rc; closed failed"
      AFM_RESULT=failed ;;
  esac
  return 0
}
