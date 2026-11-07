# shellcheck shell=bash
# bin/lib/mc/fly-workers.sh — BH-6495 (BH-6047.5): the conductor's per-PR
# workers placed on lane-run machines. Sourced by bin/merge-conductor.sh and
# bin/merge-conductor-pr.sh, never run.
#
# With the switch on, the hub's tick_project does not start a local pr_worker
# for a PR. It enqueues ONE lane_runs row (lane merge-conductor-pr, project
# <project>.<pr>.<head12>), and a machine running bin/lane-run-worker.sh claims
# it and runs bin/merge-conductor-pr.sh, which is today's keyed tick for that
# one PR. The partial unique index lane_runs_live is the dedupe of a key.
#
#   mc_fly_workers_on <project>
#       rc 0 = on. conductor_workers_on_fly.<project> wins when it has a row,
#       else the fleet row conductor_workers_on_fly. Only the trimmed value 1
#       is on. No row, any other value or a settings outage is off.
#       BH-8238: with the switch on, a project the hub takes back from a
#       machine is off too: MC_PROJ_TAKEBACK=1 (the take-back tick of
#       bin/lib/mc/project-placement.sh), or the gate's mark
#       state/merge-conductor/project-fly/<project>.placed (placed fly or
#       box:<name>, so every hub tick of it is a fallback). A machine defers
#       land, rebase and re-review to the hub, so those PRs run here. Sets
#       MC_FLY_OFF_WHY and writes one `per-PR fly path off` mc_log line.
#   mc_fly_run_key <project> <pr> <head>
#       prints <project>.<pr>.<head12>. rc 1 when the pr is not a number, the
#       head is not 12+ lower-case hex, or the key is not a lane name
#       ([A-Za-z0-9._-]{1,64}).
#   mc_fly_deferred_for <rows-json> <key>
#       rc 0 + the word(s) when the newest `done` row of <key> in a prefix-read
#       answer carries a PROF line with deferred=<x>, x not `-`: the machine
#       left that PR's work to the hub (bin/merge-conductor-pr.sh). BH-9202:
#       a newest done row with state=READY and deferred=- (or no deferred
#       field) answers `hold`: a machine never lands, so the hub must.
#   mc_fly_failed_for <rows-json> <key>
#       rc 0 + a word (died | command-missing | rc=<n> | no-prof) when the
#       NEWEST row of <key> is finished and failed: status died, status failed
#       (the jobs worker's answer for rc != 0; rc 126/127 is command-missing),
#       a done row with an rc that is not 0 (75 = UNVERIFIABLE included; a
#       worker that still answers done), or no `PROF mc-pr` line. A machine that cannot
#       run the worker fails the same way on every try, so the hub must run
#       that head itself (lead review of #6624). rc 1 otherwise: no row, a live
#       newest row, a clean run, or a `died` row whose prof_line starts
#       `withdrawn ` (a row every machine refused at claim; mc_fly_stale_for).
#   mc_fly_stale_for <rows-json> <key> <now-epoch> <stale-s>
#       rc 0 + the age in seconds when the NEWEST row of <key> is queued and was
#       enqueued <stale-s> or more seconds ago: no machine took it (no
#       capacity, no fleet). rc 0 + the word `withdrawn` when the NEWEST row of
#       <key> is `died` with a prof_line that starts `withdrawn `: the jobs
#       worker ended it because the machines refused it at claim for
#       lane_run.refused_max_wait_s (BH-6942). rc 1 otherwise.
#       MC_FLY_QUEUE_STALE_S is the knob (default 600, the ticket's "unclaimed
#       for 10 min" rollback line).
#   mc_fly_enqueue <project> <slug> <pr> <head>
#       sets MC_FLY_KEY. rc 0 = enqueued (201), 3 = already live (409),
#       4 = a row of another head of this PR is live (MC_FLY_OTHER names it;
#       a queued row of another head past MC_FLY_QUEUE_STALE_S does not count),
#       5 = the machine deferred this head (MC_FLY_DEFERRED), 6 = no valid key,
#       7 = the machine run of this head failed (MC_FLY_FAILED), 8 = its row
#       waits unclaimed past MC_FLY_QUEUE_STALE_S (MC_FLY_STALE), 1 = the read
#       or the enqueue failed. Only rc 0 and 3 mean a row exists. BH-9202:
#       after the read, _mc_fly_ready_loop alerts once per (PR, head) when
#       MC_FLY_READY_LOOP_ALERT_N (default 3) done rows of the key end READY.
#   mc_fly_arm <project> <slug> <list-row>
#       the launch-loop decision for one row. rc 0 = handled here (enqueued or
#       skipped, accounted in fan-in): start no local worker. rc 1 = run the
#       local worker as today, after one `fallback=<word>` line. Reads
#       LAND_FIRE; counts into MC_FLY_N_ENQ, MC_FLY_N_SKIP and MC_FLY_N_FB,
#       and appends enq|skip|fb to MC_FLY_COUNT_FILE when it is set.
#   mc_fly_rereview_request <project> <slug> <pr> <head40> <url> <labels>
#       BH-9026: rc 5 with `rereview` in MC_FLY_DEFERRED asks the lead for a
#       review of the head (bin/lead-verdict.sh request), once per (PR, head),
#       for a repo in LEAD_REVIEW_AUTO_REPOS. A failed request parks the PR
#       BLOCKED_HUMAN rereview-request-failed with one alert, and mc_fly_arm
#       answers rc 0 (skipped:rereview-request-failed). Prints its outcome.
#   mc_fly_project_gate <project>
#       BH-6890: the per-project branch, which runs before the per-PR branch,
#       first in tick_project. With lane_placement.merge-conductor.<project>
#       = fly the whole project runs on a lane-run machine
#       (bin/lib/mc/project-placement.sh, mc_proj_gate; the stale bound is
#       MC_FLY_QUEUE_STALE_S). rc 0 = handled: the hub tick does nothing more
#       for this project. rc 1 = run today's hub tick (not placed fly, or a
#       hub fallback). rc 2 = a hub fallback for a finished row: run the whole
#       project on the hub this tick. rc 4 (BH-7635) = a deferred row that
#       names its PRs: run one keyed hub tick of MC_PROJ_TAKEBACK_KEYS only. A run on a machine (MC_ON_MACHINE=1) is
#       never gated: rc 1, and neither is the take-back's own full tick
#       (MC_PROJ_TAKEBACK=1).
#   mc_fly_project_none
#       rc 0 when the fresh box settings cache places no merge-conductor
#       project on fly: the hub tick reads no placement row per project.
#   mc_fly_launch <project> <slug> <list-row>
#       one row, for a `&` in the launch loop: mc_fly_arm, and when it answers
#       rc 1 the local worker (fanin_run_sub … mc_worker_bounded), as today.
#       Run in the background, the jobs-worker reads of N rows overlap inside
#       the same pr_slot_wait bound, instead of 2 reads per PR in sequence.
#
# The root is ${HARNESS:-${H:-}}. Defines functions only. Nothing runs on
# source; the jobs client and bin/lib/lane-placement.sh load on first use.

MC_FLY_LANE=merge-conductor-pr

_mc_fly_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _mc_fly_client — rc 0 when lp_enqueue, setting_get and _jobs_req exist.
_mc_fly_client() {
  local root
  if ! command -v lp_enqueue >/dev/null 2>&1; then
    root=$(_mc_fly_root)
    [ -n "$root" ] && [ -r "$root/bin/lib/lane-placement.sh" ] || return 1
    # shellcheck source=bin/lib/lane-placement.sh
    . "$root/bin/lib/lane-placement.sh" || return 1
  fi
  _lp_client
}

_mc_fly_trim() { printf '%s' "${1:-}" | tr -d '[:space:]'; }

mc_fly_workers_on() {
  local p="${1:-}" v rc
  _mc_fly_client || return 1
  if [ -n "$p" ] && _setting_key_ok "conductor_workers_on_fly.$p"; then
    v=$(setting_get "conductor_workers_on_fly.$p"); rc=$?
    case "$rc" in
      0) [ "$(_mc_fly_trim "$v")" = 1 ] || return 1 ;;
      2) v=$(setting_get conductor_workers_on_fly) && [ "$(_mc_fly_trim "$v")" = 1 ] || return 1 ;;
      *) return 1 ;;
    esac
  else
    v=$(setting_get conductor_workers_on_fly) && [ "$(_mc_fly_trim "$v")" = 1 ] || return 1
  fi
  _mc_fly_placed_off "$p" && return 1
  return 0
}

# _mc_fly_placed_off <project> — rc 0 when the hub runs this project's PRs
# itself (BH-8238): a take-back tick, or the gate's .placed mark (the path of
# _mc_proj_dir in bin/lib/mc/project-placement.sh). Sets MC_FLY_OFF_WHY and
# logs one line.
_mc_fly_placed_off() {
  local p="$1" f w=""
  MC_FLY_OFF_WHY=""
  if [ "${MC_PROJ_TAKEBACK:-}" = 1 ]; then
    w=take-back
  elif [ -n "$p" ] && [[ $p != */* ]]; then
    f="$(_mc_fly_root)/state/merge-conductor/project-fly/$p.placed"
    [ -f "$f" ] && { w=$(head -n 1 "$f" 2>/dev/null); w="placed ${w:-fly}"; }
  fi
  [ -n "$w" ] || return 1
  MC_FLY_OFF_WHY="$w"
  command -v mc_log >/dev/null 2>&1 \
    && mc_log "$p per-PR fly path off: $p is placed fly ($w) — the hub runs this tick's PRs itself"
  return 0
}

mc_fly_run_key() {
  local p="${1:-}" n="${2:-}" head="${3:-}" key
  [[ $n =~ ^[0-9]+$ ]] && [[ $head =~ ^[0-9a-f]{12} ]] || return 1
  key="$p.$n.${head:0:12}"
  [[ $key =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 1
  printf '%s' "$key"
}

mc_fly_deferred_for() {
  local d
  # BH-9202: a row that ends READY with no word is a landing the machine left
  # to the hub (a machine never lands), so it reads as `hold`.
  d=$(printf '%s' "${1:-}" | jq -r --arg k "${2:-}" \
    'first(.rows[]? | select(.project == $k and .status == "done")) | .prof_line // ""
     | ((capture("(^| )deferred=(?<d>[^ ]+)").d // "") as $w
        | if $w != "" and $w != "-" then $w
          elif test("(^| )state=READY( |$)") then "hold"
          else "" end)' 2>/dev/null) || return 1
  [ -n "$d" ] && [ "$d" != - ] || return 1
  printf '%s' "$d"
}

mc_fly_failed_for() {
  local d
  d=$(printf '%s' "${1:-}" | jq -r --arg k "${2:-}" '
    first(.rows[]? | select(.project == $k)) // {} |
    if (.status // "") == "died" and ((.prof_line // "") | startswith("withdrawn ")) then ""
    elif (.status // "") == "died" then "died"
    elif (.status // "") == "failed" then
      (if (.rc == 126 or .rc == 127) then "command-missing" else "rc=\(.rc)" end)
    elif (.status // "") != "done" then ""
    elif (.rc != null and .rc != 0) then "rc=\(.rc)"
    elif ((.prof_line // "") | test("(^| )PROF mc-pr ")) | not then "no-prof"
    else "" end' 2>/dev/null) || return 1
  [ -n "$d" ] || return 1
  printf '%s' "$d"
}

mc_fly_stale_for() {
  local a
  a=$(printf '%s' "${1:-}" | jq -r --arg k "${2:-}" --argjson now "${3:-0}" --argjson st "${4:-600}" '
    first(.rows[]? | select(.project == $k)) // {} |
    if (.status // "") == "died" and ((.prof_line // "") | startswith("withdrawn ")) then "withdrawn"
    elif (.status // "") != "queued" then ""
    else ((.enqueued_at // "") | try fromdateiso8601 catch null) as $t |
      if $t == null then "" elif ($now - $t) >= $st then ($now - $t | tostring) else "" end
    end' 2>/dev/null) || return 1
  [ -n "$a" ] || return 1
  printf '%s' "$a"
}

mc_fly_enqueue() {
  local p="${1:-}" slug="${2:-}" n="${3:-}" head="${4:-}" root rows rc
  MC_FLY_KEY=""; MC_FLY_OTHER=""; MC_FLY_DEFERRED=""; MC_FLY_FAILED=""; MC_FLY_STALE=""
  MC_FLY_KEY=$(mc_fly_run_key "$p" "$n" "$head") || return 6
  _mc_fly_client || return 1
  root=$(_mc_fly_root)
  # One read of this PR's rows, newest first. The trailing dot keeps #12 from
  # matching #123.
  rows=$(_jobs_req GET "/api/lane-runs/by-prefix?lane=$MC_FLY_LANE&project_prefix=$p.$n.&limit=50") || return 1
  printf '%s' "$rows" | jq -e '.rows | type == "array"' >/dev/null 2>&1 || return 1
  # A failed run first: its row is terminal, so lp_enqueue would add a new one
  # and the next machine fails the same way, tick after tick, with nobody told.
  if MC_FLY_FAILED=$(mc_fly_failed_for "$rows" "$MC_FLY_KEY"); then return 7; fi
  _mc_fly_ready_loop "$p" "$slug" "$n" "$head" "$rows"
  if MC_FLY_DEFERRED=$(mc_fly_deferred_for "$rows" "$MC_FLY_KEY"); then return 5; fi
  # No machine took the row in time (no capacity, or no fleet at all): the hub
  # works the PR rather than leave it waiting. A machine that claims the row
  # later lands nothing (MC_ON_MACHINE), so the overlap is reads, not a merge.
  local st="${MC_FLY_QUEUE_STALE_S:-600}"
  [[ $st =~ ^[0-9]+$ ]] || st=600
  if MC_FLY_STALE=$(mc_fly_stale_for "$rows" "$MC_FLY_KEY" "$(date -u +%s)" "$st"); then return 8; fi
  # A cut answer could hide a live row: ask again for the live rows alone,
  # which the index holds to one per key.
  if [ "$(printf '%s' "$rows" | jq -r '.truncated' 2>/dev/null)" != false ]; then
    rows=$(_jobs_req GET "/api/lane-runs/by-prefix?lane=$MC_FLY_LANE&project_prefix=$p.$n.&live=1&limit=50") || return 1
    [ "$(printf '%s' "$rows" | jq -r '.truncated' 2>/dev/null)" = false ] || return 1
  fi
  # A queued row of another head that waited MC_FLY_QUEUE_STALE_S or longer
  # does not count (lead review of #6960): every machine may refuse it at
  # claim (BH-6942 skip_prefixes), so counting it could skip this PR for up to
  # lane_run.refused_max_wait_s, until a refusing claim ends that row (died,
  # withdrawn). A claimed row still counts.
  MC_FLY_OTHER=$(printf '%s' "$rows" | jq -r --arg k "$MC_FLY_KEY" --argjson now "$(date -u +%s)" --argjson st "$st" \
    'first(.rows[] | select(.project != $k and (.status == "claimed" or (.status == "queued"
       and ((((.enqueued_at // "") | try fromdateiso8601 catch null) as $t | $t == null or ($now - $t) < $st))))))
     | .project' 2>/dev/null)
  [ -n "$MC_FLY_OTHER" ] && return 4
  lp_enqueue "$MC_FLY_LANE" "$MC_FLY_KEY" "$root/bin/merge-conductor-pr.sh" "$p" "$slug#$n" "$head"; rc=$?
  case "$rc" in 0|3) return "$rc" ;; esac
  return 1
}

mc_fly_arm() {
  local p="$1" slug="$2" row="$3" num head why rc
  MC_FLY_DEFERRED=""; MC_FLY_FAILED=""; MC_FLY_STALE=""
  num="${row%%$'\t'*}"
  head=$(printf '%s' "$row" | cut -f3)
  if [ "${LAND_FIRE:-0}" = 1 ]; then
    # The land fan-out records its sha only when every worker of this tick
    # answered (BH-870), so a land-fire tick stays whole on the hub.
    why=land-fire
  else
    mc_fly_enqueue "$p" "$slug" "$num" "$head"; rc=$?
    case "$rc" in
      0|3)
        fanin_account "$slug#$num" enqueued:fly
        if [ "$rc" = 3 ]; then
          mc_log "$slug#$num enqueued merge-conductor-pr $MC_FLY_KEY (already live) — no local worker this tick"
        else
          mc_log "$slug#$num enqueued merge-conductor-pr $MC_FLY_KEY — no local worker this tick"
        fi
        hotfix_pending_is "$p" "$num" 2>/dev/null && hotfix_pending_drop "$p" "$num"
        MC_FLY_N_ENQ=$(( ${MC_FLY_N_ENQ:-0} + 1 )); _mc_fly_count enq
        return 0 ;;
      4)
        fanin_account "$slug#$num" skipped:fly-live-other-head
        mc_log "$slug#$num skipped:fly-live-other-head — $MC_FLY_OTHER is still live, so ${head:0:12} is enqueued after it is done; no local worker this tick"
        hotfix_pending_is "$p" "$num" 2>/dev/null && hotfix_pending_drop "$p" "$num"
        MC_FLY_N_SKIP=$(( ${MC_FLY_N_SKIP:-0} + 1 )); _mc_fly_count skip
        return 0 ;;
      5)
        why=machine-deferred
        # BH-9026: a machine that left the re-review of a moved head to the
        # hub created no lead review request, so a repo whose merge needs the
        # lead's verdict waited for a person. Ask the lead in this tick.
        if [[ ,$MC_FLY_DEFERRED, == *,rereview,* ]]; then
          local rr
          rr=$(mc_fly_rereview_request "$p" "$slug" "$num" "$head" "$(printf '%s' "$row" | cut -f2)" "$(printf '%s' "$row" | cut -f10)")
          if [ "$rr" = failed ]; then
            fanin_account "$slug#$num" skipped:rereview-request-failed
            mc_log "$slug#$num skipped:rereview-request-failed — BLOCKED_HUMAN for ${head:0:12}; no local worker this tick, the next tick asks the lead again"
            MC_FLY_N_SKIP=$(( ${MC_FLY_N_SKIP:-0} + 1 )); _mc_fly_count skip
            return 0
          fi
        fi ;;
      6) why=key-too-long ;;
      7) why=machine-failed ;;
      8) why=no-capacity ;;
      *) why=enqueue-failed ;;
    esac
  fi
  MC_FLY_N_FB=$(( ${MC_FLY_N_FB:-0} + 1 )); _mc_fly_count fb
  mc_log "$slug#$num fallback=$why${MC_FLY_DEFERRED:+ ($MC_FLY_DEFERRED)}${MC_FLY_FAILED:+ ($MC_FLY_FAILED at ${MC_FLY_KEY:-?})}$(_mc_fly_stale_note) — this PR runs on the hub this tick"
  return 1
}

# mc_fly_rereview_request <project> <slug> <pr> <head40> <url> <labels-csv>
# (BH-9026) — the lead review request for a head a machine deferred with
# `deferred=rereview`. Prints one word: requested | exists | skip | failed.
# Only a repo in LEAD_REVIEW_AUTO_REPOS (lead-review-land's knob) is asked;
# for any other repo the conductor's own re-review is the reviewer. The call
# is bin/lead-verdict.sh request, with --priority for a hotfix-labelled PR.
# The marker `rrleadreq <slug>#<pr> <head>` is written only AFTER the call
# answered created or 409 (the worker's UNIQUE(repo, pr, head_sha)), so a
# later tick makes no call, and a lost marker costs one 409. Any other answer
# writes no marker: one FAILED line, the PR BLOCKED_HUMAN
# rereview-request-failed, and one alert per (PR, head) (`rrleadreqfail`).
mc_fly_rereview_request() {
  local p="$1" slug="$2" n="$3" head="$4" url="${5:--}" labels="${6:--}"
  local auto repo lv pri="" out err rc id why note="" c409=0
  [ "${MC_ON_MACHINE:-}" = 1 ] && { echo skip; return 0; }
  if ! [[ $head =~ ^[0-9a-f]{40}$ ]]; then
    mc_log "$slug#$n rereview request skipped: head '${head:0:40}' is not 40 hex"
    echo skip; return 0
  fi
  auto=$(command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lead-review-land >/dev/null 2>&1 \
           && printf '%s' "${LEAD_REVIEW_AUTO_REPOS:-}")
  if [ -z "${auto//[[:space:],]/}" ]; then
    mc_log "$slug#$n rereview request not decided for ${head:0:12}: LEAD_REVIEW_AUTO_REPOS unreadable"
    echo skip; return 0
  fi
  local inlist=0
  for repo in ${auto//,/ }; do
    [ "${repo,,}" = "${slug,,}" ] && { inlist=1; break; }
  done
  [ "$inlist" = 1 ] || { echo skip; return 0; }
  mc_attempt_has "rrleadreq $slug#$n $head" && { echo skip; return 0; }
  if command -v hotfix_labels_csv_has >/dev/null 2>&1 && hotfix_labels_csv_has "$labels"; then
    # Fallback of the settings row lane.merge-conductor.mc_rereview_request_hotfix_priority.
    pri="${MC_REREVIEW_REQUEST_HOTFIX_PRIORITY:-500}"
    if ! [[ $pri =~ ^[0-9]{1,4}$ ]] || [ "$((10#$pri))" -lt 1 ] || [ "$((10#$pri))" -gt 1000 ]; then
      mc_log "$slug#$n MC_REREVIEW_REQUEST_HOTFIX_PRIORITY='$pri' is not an integer 1..1000; using 500"
      pri=500
    fi
    pri=$((10#$pri))
  fi
  lv="$MC_H/bin/lead-verdict.sh"
  err=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/mc-rr.$$.$n")
  if [ -x "$lv" ]; then
    out=$("$lv" request "$slug" "$n" "$head" ${pri:+--priority "$pri"} \
      --notes "pool deferred rereview of ${head:0:12} (BH-9026)" 2>"$err" </dev/null); rc=$?
  else
    out=""; rc=127; echo "$lv is missing" > "$err"
  fi
  # lr_post_lead writes the bare line `HTTP <code>` to stderr on a non-2xx.
  grep -qx 'HTTP 409' "$err" 2>/dev/null && c409=1
  why=$(tr '\n' ' ' < "$err" 2>/dev/null | sed 's/[[:space:]]*$//'); rm -f "$err"
  id=$(printf '%s\n' "$out" | sed -n 's/^requested lead review #\([^ ]*\) on .*/\1/p' | head -n 1)
  if [ -n "$id" ]; then
    [ "$rc" = 0 ] || note=" (priority not stored)"
    mc_attempt_put "rrleadreq $slug#$n $head"
    mc_log "$slug#$n rereview requested $id for ${head:0:12} (pool deferred)$note"
    echo requested; return 0
  fi
  if [ "$rc" != 0 ] && [ "$c409" = 1 ]; then
    mc_attempt_put "rrleadreq $slug#$n $head"
    mc_log "$slug#$n rereview request exists for ${head:0:12} (pool deferred)"
    echo exists; return 0
  fi
  [ "$rc" = 0 ] && why="no request id in the answer: ${out:0:120}"
  why="${why:0:200}"
  mc_log "$slug#$n rereview request FAILED for ${head:0:12} (pool deferred): ${why:-rc=$rc}"
  mc_transition "$slug#$n" BLOCKED_HUMAN "rereview-request-failed" "$head" - "$url" - - - >/dev/null
  if ! mc_attempt_has "rrleadreqfail $slug#$n $head"; then
    mc_attempt_put "rrleadreqfail $slug#$n $head"
    mc_alert "$slug#$n" BLOCKED_HUMAN "lead review request for ${head:0:12} failed (${why:-rc=$rc}); the next tick asks again. By hand: bin/lead-verdict.sh request $slug $n $head"
  fi
  echo failed; return 0
}

# _mc_fly_ready_loop <project> <slug> <pr> <head> <rows-json> — BH-9202: the
# tripwire for a READY head that machine rows do not land. When the rows of
# this head's key hold MC_FLY_READY_LOOP_ALERT_N or more `done` rows whose PROF
# line says state=READY, one mc_alert per (PR, head); the attempt marker
# `flyreadyloop <slug>#<pr> <head>` is written after the alert. Hub only, and
# only where mc_alert and the attempts ledger are loaded. Always rc 0.
_mc_fly_ready_loop() {
  local p="$1" slug="$2" n="$3" head="$4" rows="$5" key lim c
  [ "${MC_ON_MACHINE:-}" = 1 ] && return 0
  command -v mc_alert >/dev/null 2>&1 && command -v mc_attempt_has >/dev/null 2>&1 \
    && command -v mc_attempt_put >/dev/null 2>&1 || return 0
  key=$(mc_fly_run_key "$p" "$n" "$head") || return 0
  # Fallback of the settings row lane.merge-conductor.mc_fly_ready_loop_alert_n.
  lim="${MC_FLY_READY_LOOP_ALERT_N:-3}"
  if ! [[ $lim =~ ^[0-9]{1,3}$ ]] || [ "$((10#$lim))" -lt 2 ]; then
    command -v mc_log >/dev/null 2>&1 \
      && mc_log "$slug#$n MC_FLY_READY_LOOP_ALERT_N='$lim' is not an integer >= 2; using 3"
    lim=3
  fi
  lim=$((10#$lim))
  c=$(printf '%s' "$rows" | jq -r --arg k "$key" \
    '[.rows[]? | select(.project == $k and .status == "done"
       and ((.prof_line // "") | test("(^| )state=READY( |$)")))] | length' 2>/dev/null) || return 0
  [[ $c =~ ^[0-9]+$ ]] && [ "$c" -ge "$lim" ] || return 0
  mc_attempt_has "flyreadyloop $slug#$n $head" && return 0
  mc_alert "$slug#$n" READY "$c machine rows of ${head:0:12} ended READY with no landing ($key); the hub runs this PR itself (fallback=machine-deferred). If it still does not land, the hub log names the gate."
  mc_attempt_put "flyreadyloop $slug#$n $head"
  return 0
}

# _mc_fly_stale_note — the fallback line's note for rc 8: the age of a queued
# row, or that the jobs worker ended a refused row (MC_FLY_STALE=withdrawn).
_mc_fly_stale_note() {
  case "${MC_FLY_STALE:-}" in
    '') ;;
    withdrawn) printf ' (%s withdrawn: refused at claim by every machine)' "${MC_FLY_KEY:-?}" ;;
    *) printf ' (%s unclaimed for %ss)' "${MC_FLY_KEY:-?}" "$MC_FLY_STALE" ;;
  esac
}

# _mc_fly_count enq|skip|fb — one word per row into MC_FLY_COUNT_FILE, the
# tally a backgrounded mc_fly_launch cannot return through a variable.
_mc_fly_count() {
  [ -n "${MC_FLY_COUNT_FILE:-}" ] || return 0
  printf '%s\n' "$1" >> "$MC_FLY_COUNT_FILE" 2>/dev/null
  return 0
}

# _mc_fly_pp — source bin/lib/mc/project-placement.sh once; rc 1 when absent.
_mc_fly_pp() {
  local root
  command -v mc_proj_gate >/dev/null 2>&1 && return 0
  root=$(_mc_fly_root)
  [ -n "$root" ] && [ -r "$root/bin/lib/mc/project-placement.sh" ] || return 1
  # shellcheck source=bin/lib/mc/project-placement.sh
  . "$root/bin/lib/mc/project-placement.sh"
}

# mc_fly_project_none — rc 0 when the fresh settings cache places no project
# of merge-conductor on fly (mc_proj_none_fly): the hub tick skips the gate.
mc_fly_project_none() {
  _mc_fly_pp || return 1
  mc_proj_none_fly
}

mc_fly_project_gate() {
  local p="${1:-}" st
  [ "${MC_ON_MACHINE:-}" = 1 ] && return 1
  # The take-back's own full tick (mc_proj_takeback_full): the hub runs it.
  [ "${MC_PROJ_TAKEBACK:-}" = 1 ] && return 1
  _mc_fly_pp || return 1
  st="${MC_FLY_QUEUE_STALE_S:-600}"
  [[ $st =~ ^[0-9]+$ ]] || st=600
  mc_proj_gate "$p" "$st"
}

mc_fly_launch() {
  local p="$1" slug="$2" row="$3"
  mc_fly_arm "$p" "$slug" "$row" && return 0
  fanin_run_sub "$slug#${row%%$'\t'*}" mc_fanin_outcome mc_worker_bounded "$row"
}
