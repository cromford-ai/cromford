#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-watch/common.sh — BH-4586 (BH-4574.4): what the whole-factory
# watch shares. Sourced by bin/archie-fm-watch.sh, never run: no `set -e`, no
# `exit`, nothing at source time.
#
# A FINDING is one TSV line (afw_collect, sources.sh):
#   class \t subject \t incident \t project \t host \t alert_id \t opened_epoch \t evidence-json
# afw_lever maps it to exactly ONE lever from the fixed table below, and
# afw_handle claims an archie_actions row for it (wave 2's afq_claim) BEFORE the
# lever runs. The key is watch:<class>:<incident>:<lever>:<mode>, so a second
# tick on the same incident finds its own row and does nothing. When that row
# is older than archie.watch.escalate_s and the incident is still a finding,
# ONE watch-ticket row files ONE issue (afw_file_ticket).
#
# THE LEVER ALLOWLIST IS CODE, never a setting: kick_lane (review-rescue,
# fleet-propagate, main-red-bisect, cost-rollup, triage), run_cleanup
# (disk-clean, hub only), rerun_deploy (deployworkers, consolepages), ack_alert
# and file_ticket, plus note (no side effect: the row is the one-time record
# a model session reads). afw_pull refuses anything else before any write.
#
# The root is ${HARNESS:-${H:-}}; an empty root refuses (D43).
# Globals the caller sets: AFM_LOG, NOW, DAY, AFQ_RETRY_S, AFQ_ACTOR,
# AFW_DEADLINE, AFW_HOSTS (this box's names, space separated).
# gh-rest: no-graphql

# HARNESS_REPO comes from bin/lib/deployment.sh (BH-4080), sourced by the caller.
AFW_REPO_DEFAULT=${HARNESS_REPO:-}
AFW_KICK_LANES="review-rescue fleet-propagate main-red-bisect cost-rollup triage"
AFW_N_FINDINGS=0; AFW_N_PULLED=0; AFW_N_TICKETS=0; AFW_N_WOULD=0; AFW_N_CAPPED=0
AFW_N_SKIPPED=0; AFW_N_FAILED=0; AFW_INCOMPLETE=0
# AFW_N_NEW: rows this tick created (an incident no earlier tick saw). The
# model-session gate (afw_session) opens on it.
AFW_N_NEW=0; AFW_N_SESSIONS=0
# What the lever bodies hand back to afw_handle.
AFW_OUT=""; AFW_WHY=""; AFW_EV="{}"

afw_root() { printf '%s' "${HARNESS:-${H:-}}"; }
afw_log() { afm_log "$@"; }

# afw_cap_default <playbook> -> the documented fallback when the
#   archie.cap.<playbook> row is absent (the seeds in worker/jobs/schema.sql).
afw_cap_default() {
  case "$1" in
    watch-build-stuck) printf 20 ;; watch-review-unrescued) printf 10 ;; watch-pool-idle) printf 5 ;;
    watch-disk) printf 10 ;; watch-cron-install) printf 6 ;; watch-deploy-drift) printf 6 ;;
    watch-main-red) printf 10 ;; watch-pause-waiting) printf 5 ;; watch-triage-skip) printf 10 ;;
    watch-cost-anomaly) printf 10 ;; watch-ticket) printf 5 ;; watch-session) printf 12 ;;
    watch-owed-overdue) printf 20 ;; watch-metric-unreadable) printf 20 ;;
    *) printf 0 ;;
  esac
}

# afw_setting_default <key> -> the documented fallback of an archie.watch.* row.
afw_setting_default() {
  case "$1" in
    archie.watch.escalate_s) printf 7200 ;; archie.watch.rescue_grace_s) printf 3600 ;;
    archie.watch.cron_install_s) printf 1800 ;; archie.watch.pause_waiting_s) printf 7200 ;;
    archie.watch.inode_pct) printf 90 ;; archie.watch.alert_min_age_s) printf 3000 ;;
    *) return 1 ;;
  esac
}

# afw_setting <key> -> a whole number. An absent row is the default; an
#   unreadable or junk row is rc 1 and one log line (no action on a guess, D11).
#   Read once per tick (AFW_SET_<n> cache), so a junk row logs once.
afw_setting() {
  local k="$1" var v
  var="AFW_SET_$(printf '%s' "${k#archie.watch.}" | tr -c 'A-Za-z0-9' '_')"
  if [ -n "${!var+x}" ]; then
    [ -n "${!var}" ] || return 1
    printf '%s' "${!var}"; return 0
  fi
  if v=$(afq_setting_secs "$k" "$(afw_setting_default "$k")"); then
    printf -v "$var" '%s' "$v"; printf '%s' "$v"; return 0
  fi
  printf -v "$var" '%s' ""
  return 1
}

# afw_settings_load — read every archie.watch.* row ONCE, in the tick's own
#   shell, so the readers in $(...) below hit the cache and a junk row logs once.
afw_settings_load() {
  local k
  for k in escalate_s rescue_grace_s cron_install_s pause_waiting_s inode_pct alert_min_age_s; do
    afw_setting "archie.watch.$k" >/dev/null || true
  done
}

# afw_cap_ok <playbook> <project> -> rc 0 when today's cap leaves room for one
#   more mode=on action; anything unreadable is rc 1. Its own read, not wave
#   1's afm_cap_ok: since BH-4784 that one counts restack|fix_round actions
#   (count_by=action) and memoizes a full cap in AFM_CAP_FULL for the tick,
#   which would never cap a watch playbook and would leak one playbook's full
#   cap into the next (the same fix BH-4584 made to afq_cap_ok). This counts
#   today's mode=on done+requested rows of <playbook> (the worker's default
#   count, by outcome), with the playbook's documented default when the row
#   is absent.
afw_cap_ok() {
  local pb="$1" p="$2" cap rc resp used
  cap=$(setting_get "archie.cap.$pb"); rc=$?
  case "$rc" in
    0) cap=$(printf '%s' "$cap" | tr -d '[:space:]') ;;
    2) cap=$(afw_cap_default "$pb") ;;
    *) afw_log "$p: archie.cap.$pb unreadable (rc=$rc); nothing done"; return 1 ;;
  esac
  if ! [[ $cap =~ ^[0-9]+$ ]]; then
    afw_log "$p: archie.cap.$pb='$cap' is not a whole number; nothing done"; return 1
  fi
  if [ "$((10#$cap))" = 0 ]; then afw_log "$p: archie.cap.$pb=0, the playbook is off"; return 1; fi
  resp=$(_afm_req GET "/api/archie/actions?day=$DAY&playbook=$pb&limit=1"); rc=$?
  if [ "$rc" = 2 ]; then AFM_ROUTE_ABSENT=1; return 1; fi
  used=$(jq -r --arg pb "$pb" \
    '(.counts[$pb].on.done // 0) + (.counts[$pb].on.requested // 0) | if type == "number" then . else empty end' \
    <<<"$resp" 2>/dev/null)
  if [ "$rc" != 0 ] || [ -z "$used" ]; then
    afw_log "$p: today's $pb count unreadable (rc=$rc http=${JOBS_HTTP:-none}); nothing done"; return 1
  fi
  if [ "$used" -ge "$((10#$cap))" ]; then
    afw_log "$p: cap reached ($used of $((10#$cap)) $pb actions today); nothing done"; return 1
  fi
  return 0
}

# afw_is_hub_host <host> -> rc 0 when <host> names this box.
afw_is_hub_host() {
  local h
  [ -n "$1" ] || return 1
  for h in ${AFW_HOSTS:-}; do [ "$h" = "$1" ] && return 0; done
  return 1
}

# afw_inc_key <incident> -> the incident as it may sit inside a dedupe key
#   (KEY_RE in worker/jobs/src/routes/archie-actions.js); anything else, or a
#   value too long to fit, is h-<sha1/16>. The raw value rides in the evidence.
afw_inc_key() {
  if [[ $1 =~ ^[A-Za-z0-9._:/@-]{1,200}$ ]]; then printf '%s' "$1"
  else printf 'h-%s' "$(printf '%s' "$1" | sha1sum | cut -c1-16)"; fi
}

# afw_lever <class> <subject> <host> <alert_id> <evidence-json> -> "<lever>\t<arg>"
#   THE TABLE (plan.md, Finding classes). One lever per class, decided here and
#   nowhere else; the arg is checked again by the lever itself.
afw_lever() {
  local c="$1" subj="$2" host="$3" aid="$4" ev="$5" r
  r=$(afw_root)
  case "$c" in
    build-stuck)      printf 'ack_alert\t%s' "$aid" ;;
    review-unrescued) printf 'kick_lane\treview-rescue' ;;
    pool-idle)        printf 'file_ticket\t-' ;;
    disk)
      if afw_is_hub_host "$host"; then printf 'run_cleanup\thub'; else printf 'ack_alert\t%s' "$aid"; fi ;;
    cron-install)     printf 'kick_lane\tfleet-propagate' ;;
    deploy-drift)
      case "$aid" in
        ph-consolepagesdrift_*)
          if [ -n "$r" ] && [ -f "${AFW_HENV:-$r/env}/cloudflare.env" ]; then printf 'rerun_deploy\tconsolepages'
          else printf 'file_ticket\t-'; fi ;;
        *) printf 'rerun_deploy\tdeployworkers' ;;
      esac ;;
    main-red)         printf 'kick_lane\tmain-red-bisect' ;;
    pause-waiting)    printf 'file_ticket\t-' ;;
    triage-skip)      printf 'kick_lane\ttriage' ;;
    cost-anomaly)
      case "$aid" in
        ph-costrollupstale_hub) printf 'kick_lane\tcost-rollup' ;;
        *) printf 'ack_alert\t%s' "$aid" ;;
      esac ;;
    owed-overdue|metric-unreadable) printf 'note\t-' ;;
    *) return 1 ;;
  esac
  : "$subj" "$ev"
}

# afw_pull <lever> <arg> <class> <incident> <project> <subject> <alert_id> <evidence-json>
#   ONE case over the five lever names. Anything else is refused before any
#   write: rc 1, one log line, AFW_OUT=failed. Sets AFW_OUT done|requested|failed,
#   AFW_WHY, AFW_EV (what the lever saw, merged into the row's evidence).
afw_pull() {
  local lever="$1" arg="$2" c="$3" inc="$4" p="$5" subj="$6" aid="$7" ev="$8"
  AFW_OUT=failed; AFW_WHY=""; AFW_EV="{}"
  case "$lever" in
    kick_lane)    afw_kick_lane "$arg" "$p" "$c" "$inc" ;;
    run_cleanup)  afw_run_cleanup "$arg" ;;
    rerun_deploy) afw_rerun_deploy "$arg" "$aid" "$ev" ;;
    ack_alert)    afw_ack_alert "$aid" "$(afw_route_note "$c" "$aid")" ;;
    file_ticket)  afw_file_ticket "$c" "$inc" "$subj" "$ev" "" ;;
    note)         AFW_OUT=done; AFW_WHY="recorded once; the next model session tells the operator" ;;
    *)
      AFW_OUT=failed; AFW_WHY="refused lever '$lever': not on the allowlist"
      afw_log "refused lever '$lever' ($c $inc): not on the allowlist; nothing done"
      return 1 ;;
  esac
}

# afw_route_note <class> <alert_id> -> the ack note: who owns the condition.
afw_route_note() {
  case "$1" in
    build-stuck) printf 'archie-fm-watch: acked; the stuck build is owned by bin/blocked-resolver.sh and bin/lane-reaper.sh on their own cadence. A ticket follows if it is still open in %ss.' "$(afw_setting archie.watch.escalate_s || echo 7200)" ;;
    disk) printf 'archie-fm-watch: acked; that box frees its own disk with bin/disk-clean.sh (04:47Z daily). A ticket follows if it is still open in %ss.' "$(afw_setting archie.watch.escalate_s || echo 7200)" ;;
    cost-anomaly) printf 'archie-fm-watch: acked; the cost brake and the caps already act on this (bin/cost-reconcile.sh, bin/lib/budget-stop.sh, pipeline-health). A ticket follows if it is still open in %ss.' "$(afw_setting archie.watch.escalate_s || echo 7200)" ;;
    *) printf 'archie-fm-watch: acked (%s).' "$1" ;;
  esac
  : "$2"
}

# afw_route_absent [<body>] — called after a jobs-worker 404 (rc 2) on an
#   /api/archie/actions call. rc 0 when the ROUTE is absent; rc 1 when the 404
#   is the worker's ROW miss, {"error":"archie action not found"}
#   (worker/jobs/src/routes/archie-actions.js notFound("archie action")).
#   BH-8417: the real _jobs_req prints nothing on a 404. It keeps the body in
#   JOBS_BODY (lost when the call ran in a $( )) and in JOBS_BODY_FILE, which
#   bin/archie-fm-watch.sh sets for the tick, so the newest request's body is
#   read from that file. <body> is what the caller's $( ) printed.
afw_route_absent() {
  local b="${1:-}"
  if [ -n "${JOBS_BODY_FILE:-}" ] && [ -r "$JOBS_BODY_FILE" ]; then
    b+=$(head -c 200 "$JOBS_BODY_FILE" 2>/dev/null)
  else
    b+=${JOBS_BODY:-}
  fi
  case "$b" in *"archie action not found"*) return 1 ;; esac
  return 0
}

# afw_row_get <key> -> rc 0 and the row on stdout; rc 2 no row; rc 4 the route
#   is not deployed (the worker's own 404, not "no such row"); rc 1 unreadable.
#   Called in $( ): it signals by rc, never by a global.
afw_row_get() {
  local resp rc enc
  enc=$(jq -rn --arg k "$1" '$k | @uri') || return 1
  resp=$(_afm_req GET "/api/archie/actions?dedupe_key=$enc"); rc=$?
  case "$rc" in
    0) jq -ce '.action | select(type == "object")' <<<"$resp" 2>/dev/null || return 1 ;;
    2) afw_route_absent "$resp" && return 4
       return 2 ;;
    *) return 1 ;;
  esac
}

# afw_age_of <row-json> -> seconds since its updated_at (0 when unreadable:
#   never stale, so nothing escalates on a stamp it cannot read).
afw_age_of() {
  local upd ts
  upd=$(jq -r '.updated_at // ""' <<<"$1" 2>/dev/null)
  ts=""; [ -n "$upd" ] && ts=$(date -u -d "$upd" +%s 2>/dev/null)
  [[ $ts =~ ^[0-9]+$ ]] || ts=$NOW
  printf '%s' "$(( NOW - ts ))"
}

# afw_ready <lever> <arg> -> rc 0 when the lever can run on this box at all.
#   Not configured is NO claim (System invariants b), one log line.
afw_ready() {
  case "$1" in
    rerun_deploy|file_ticket)
      command -v gh_rest >/dev/null 2>&1 || { afw_log "$1: gh_rest is not loaded; no claim"; return 1; } ;;
    run_cleanup)
      local left; left=$(( ${AFW_DEADLINE:-0} - $(date +%s) ))
      [ "${AFW_DEADLINE:-0}" -gt 0 ] && [ "$left" -lt 960 ] && { afw_log "run_cleanup: ${left}s left in the tick, under 960; next tick"; return 1; } ;;
  esac
  return 0
}

# afw_act <playbook> <key> <project> <repo> <mode> <lever> <arg> <why> <evidence> <class> <incident> <subject> <alert_id>
#   claim, then (mode on) pull and close. Counts into the AFW_N_* totals.
afw_act() {
  local pb="$1" key="$2" p="$3" repo="$4" mode="$5" lever="$6" arg="$7" why="$8" ev="$9"
  local c="${10}" inc="${11}" subj="${12}" aid="${13}" act rc out full
  act=$lever; [ "$mode" = on ] || act="would_$lever"
  if [ "$mode" = on ] && ! afw_cap_ok "$pb" "$p"; then
    [ "$AFM_ROUTE_ABSENT" = 1 ] && return 2
    AFW_N_CAPPED=$((AFW_N_CAPPED + 1)); return 0
  fi
  rc=0; afq_claim "$pb" "$key" "$p" "$repo" 0 "$mode" "$act" "$why" "$ev" || rc=$?
  case "$rc" in
    0) AFW_N_NEW=$((AFW_N_NEW + 1)) ;;
    2) return 2 ;;
    3) AFW_N_SKIPPED=$((AFW_N_SKIPPED + 1)); return 0 ;;
    *) AFW_N_FAILED=$((AFW_N_FAILED + 1)); return 0 ;;
  esac
  if [ "$mode" != on ]; then
    AFW_N_WOULD=$((AFW_N_WOULD + 1)); AFM_ROW=""; return 0
  fi
  afw_pull "$lever" "$arg" "$c" "$inc" "$p" "$subj" "$aid" "$ev"
  out=$AFW_OUT
  case "$out" in done|requested) ;; *) out=failed ;; esac
  full=$(jq -c --argjson a "$AFW_EV" '. + {lever: $a}' <<<"$ev" 2>/dev/null) || full=""
  afq_close "$pb" "$out" "" "${AFW_WHY:-}" "$full" \
    || afw_log "$c $inc: the $lever outcome ($out) could not be written; the row stays started"
  if [ "$out" = failed ]; then AFW_N_FAILED=$((AFW_N_FAILED + 1))
  elif [ "$lever" = file_ticket ]; then AFW_N_TICKETS=$((AFW_N_TICKETS + 1))
  else AFW_N_PULLED=$((AFW_N_PULLED + 1)); fi
  afw_log "$c $inc: $lever ${arg:+$arg }-> $out${AFW_WHY:+ ($AFW_WHY)}"
  AFM_ROW=""
  return 0
}

# afw_handle <finding-line> <mode> — one finding: its lever, or (the lever row
#   stale and the incident still here) its ONE escalation ticket. rc 2 the
#   ledger route is absent (the caller stops the tick).
afw_handle() {
  local line="$1" mode="$2" c subj inc p host aid opened ev lv lever arg ik key repo row out age esc tkey why rc
  IFS=$'\t' read -r c subj inc p host aid opened ev <<<"$line"
  [ "$aid" = - ] && aid=""
  lv=$(afw_lever "$c" "$subj" "$host" "$aid" "$ev") || { afw_log "no lever for class '$c'; nothing done"; return 0; }
  lever=${lv%%$'\t'*}; arg=${lv#*$'\t'}
  ik=$(afw_inc_key "$inc")
  key="watch:$c:$ik:$lever:$mode"
  repo=$(jq -r '.repo // empty' <<<"$ev" 2>/dev/null)
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || repo=$AFW_REPO_DEFAULT
  ev=$(jq -c --arg c "$c" --arg i "$inc" --arg s "$subj" '. + {class: $c, incident: $i, subject: $s}' <<<"$ev" 2>/dev/null) \
    || ev=$(jq -nc --arg c "$c" --arg i "$inc" --arg s "$subj" '{class: $c, incident: $i, subject: $s}')

  row=""; rc=0; row=$(afw_row_get "$key") || rc=$?
  case "$rc" in
    0) ;;
    2) row="" ;;
    4) AFM_ROUTE_ABSENT=1; return 2 ;;
    *) afw_log "$c $inc: the ledger row for $key could not be read; nothing done this tick"
       AFW_N_FAILED=$((AFW_N_FAILED + 1)); return 0 ;;
  esac
  if [ -n "$row" ]; then
    out=$(jq -r '.outcome // ""' <<<"$row")
    case "$out" in
      started)
        # Not ours: afq_claim closes it failed with one alert once it is stale.
        rc=0; afq_claim "watch-$c" "$key" "$p" "$repo" 0 "$mode" "$lever" "re-read" "$ev" || rc=$?
        [ "$rc" = 2 ] && return 2
        AFW_N_SKIPPED=$((AFW_N_SKIPPED + 1)); return 0 ;;
      done|requested|failed|would) ;;
      *) AFW_N_SKIPPED=$((AFW_N_SKIPPED + 1)); return 0 ;;
    esac
    # A ticket is the lever already: one that was filed is not escalated into a
    # second one. One that FAILED is retried once, under watch-ticket, after
    # escalate_s (the marker search keeps it from ever being a duplicate).
    # A note is never escalated: its row IS the one-time beat.
    [ "$lever" = note ] && { AFW_N_SKIPPED=$((AFW_N_SKIPPED + 1)); return 0; }
    if [ "$lever" = file_ticket ] && [ "$out" != failed ]; then AFW_N_SKIPPED=$((AFW_N_SKIPPED + 1)); return 0; fi
    esc=$(afw_setting archie.watch.escalate_s) || { AFW_N_SKIPPED=$((AFW_N_SKIPPED + 1)); return 0; }
    age=$(afw_age_of "$row")
    if [ "$age" -lt "$esc" ]; then AFW_N_SKIPPED=$((AFW_N_SKIPPED + 1)); return 0; fi
    tkey="watch:ticket:$c:$ik:$mode"
    afw_ready file_ticket - || { AFW_N_SKIPPED=$((AFW_N_SKIPPED + 1)); return 0; }
    why="still open ${age}s after $lever ($out)"
    ev=$(jq -c --arg l "$lever" --arg o "$out" --arg u "$(jq -r '.updated_at // ""' <<<"$row")" \
      '. + {escalated_from: {lever: $l, outcome: $o, at: $u}}' <<<"$ev")
    afw_act watch-ticket "$tkey" "$p" "$repo" "$mode" file_ticket - "$why" "$ev" "$c" "$inc" "$subj" "$aid"
    return $?
  fi
  afw_ready "$lever" "$arg" || { AFW_N_SKIPPED=$((AFW_N_SKIPPED + 1)); return 0; }
  afw_act "watch-$c" "$key" "$p" "$repo" "$mode" "$lever" "$arg" "$(afw_why "$c" "$subj")" "$ev" "$c" "$inc" "$subj" "$aid"
}

# afw_why <class> <subject> -> the row's one-line why.
afw_why() {
  case "$1" in
    build-stuck) printf 'a build is stuck past its stage SLA (%s)' "$2" ;;
    review-unrescued) printf 'a reaped or blocked build was never rescued (%s)' "$2" ;;
    pool-idle) printf 'pool machines are idle but billed (%s)' "$2" ;;
    disk) printf 'disk, tmpfs or inodes over threshold on %s' "$2" ;;
    cron-install) printf 'a merged lane is not in the crontab (%s)' "$2" ;;
    deploy-drift) printf 'a deploy is not on main (%s)' "$2" ;;
    main-red) printf 'main is red on %s' "$2" ;;
    pause-waiting) printf 'paused with work waiting (%s)' "$2" ;;
    triage-skip) printf 'a board has untriaged tickets (%s)' "$2" ;;
    cost-anomaly) printf 'a cost or quota anomaly (%s)' "$2" ;;
    owed-overdue) printf 'an OWED TO OPERATOR line is past its expected-by (%s)' "$2" ;;
    metric-unreadable) printf 'an initiative metric is unreadable (%s)' "$2" ;;
    *) printf '%s (%s)' "$1" "$2" ;;
  esac
}

# afw_session — the ONE model session a tick may start (the operator, 2026-10-06: the
#   bash sweep runs every tick at $0; a model session only when the findings
#   set has something new, or every 3h to walk the owed ledger). It runs after
#   the findings loop, on a plain tick only.
#   GATE: AFW_N_NEW > 0 is key watch:session:new:<tick minute>:<mode>; else the
#   key is watch:session:owed:<UTC 3h block>:<mode>, so the walk runs once per
#   block. An existing row is no session. Then the day cap archie.cap.watch-session
#   (seed 12, 0 = off), the prompt catalog/prompts/archie-watch.md (BH-4760;
#   absent = no session, nothing claimed) and the model route stage.archie.
#   The row is claimed BEFORE the call. Observe mode writes would_session only.
#   An answer with a line `SAY: beat` or `SAY: report` goes to the operator through
#   bin/archie-tg-send.sh, keyed on the row's key (exactly once). Any other
#   answer (`NONE`, only `SAY: none` findings, or blank) is silence: the row
#   closes done and nothing is sent.
afw_session() {
  local mode key reason r pf raw model rc text out why ev left
  r=$(afw_root); [ -n "$r" ] || return 0
  mode=$(afm_mode hub) || { afw_log "session: archie.manage unreadable; no session"; return 0; }
  [ "$mode" = off ] && return 0
  if [ "${AFW_N_NEW:-0}" -gt 0 ]; then
    reason=new; key="watch:session:new:$(date -u -d "@$NOW" +%Y%m%dT%H%M):$mode"
  else
    reason=owed; key="watch:session:owed:$(date -u -d "@$(( NOW / 10800 * 10800 ))" +%Y%m%dT%H):$mode"
  fi
  if [ ! -s "$r/catalog/prompts/archie-watch.md" ]; then
    afw_log "session: catalog/prompts/archie-watch.md is absent (BH-4760); no session ($reason)"; return 0
  fi
  rc=0; afw_row_get "$key" >/dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) ;;
    *) afw_log "session: the ledger row $key could not be read (rc=$rc); no session"; return 0 ;;
  esac
  if [ "$mode" = on ]; then
    afw_cap_ok watch-session hub || return 0
    if ! command -v lane_role_model >/dev/null 2>&1 || ! model=$(lane_role_model stage.archie) || [ -z "$model" ]; then
      afw_log "session: no model route for stage.archie; no session, nothing guessed"; return 0
    fi
    left=$(( ${AFW_DEADLINE:-0} - $(date +%s) ))
    if [ "${AFW_DEADLINE:-0}" -gt 0 ] && [ "$left" -lt 400 ]; then
      afw_log "session: ${left}s left in the tick, under 400; next tick"; return 0
    fi
  fi
  ev=$(jq -nc --arg r "$reason" --argjson n "${AFW_N_NEW:-0}" --argjson f "${AFW_N_FINDINGS:-0}" \
    '{reason: $r, new_rows: $n, findings: $f}')
  why="model session: $reason (new rows ${AFW_N_NEW:-0}, findings ${AFW_N_FINDINGS:-0})"
  rc=0; afq_claim watch-session "$key" hub "$AFW_REPO_DEFAULT" 0 "$mode" \
    "$([ "$mode" = on ] && echo session || echo would_session)" "$why" "$ev" || rc=$?
  [ "$rc" = 0 ] || return 0
  if [ "$mode" != on ]; then AFW_N_WOULD=$((AFW_N_WOULD + 1)); AFM_ROW=""; return 0; fi
  pf=$(mktemp "${TMPDIR:-/tmp}/afw-prompt.XXXXXX") || { afq_close watch-session failed "" "mktemp failed" "$ev"; AFM_ROW=""; return 0; }
  raw=$(mktemp "${TMPDIR:-/tmp}/afw-answer.XXXXXX") || { rm -f "$pf"; afq_close watch-session failed "" "mktemp failed" "$ev"; AFM_ROW=""; return 0; }
  { cat "$r"/prompts/archie-soul.d/*.md 2>/dev/null
    printf '\n'
    cat "$r/catalog/prompts/archie-watch.md"
    printf '\n## Why this session\n%s\n\n## Findings this tick (class, subject, incident, project, host, alert, opened, evidence)\n' "$why"
    cat "${AFW_FINDINGS:-/dev/null}" 2>/dev/null
  } > "$pf"
  AFW_N_SESSIONS=$((AFW_N_SESSIONS + 1))
  AGENT_CALL_LANE=archie AGENT_CALL_FP="$key" \
    "$r/bin/agent-call.sh" archie fleet "$model" 300 "$raw" "@$pf" >/dev/null 2>&1
  rc=$?
  text=$(cat "$raw" 2>/dev/null)
  rm -f "$pf" "$raw" "$raw".*
  if [ "$rc" != 0 ]; then
    out=failed; why="the model call rc=$rc$([ "$rc" -ge 74 ] && [ "$rc" -le 79 ] && echo ' (refused, nothing billed)')"
  elif [[ $text =~ ^[[:space:]]*$ ]]; then
    out=done; why="answered blank: nothing for the operator"
  elif ! grep -qE '^SAY:[[:space:]]*(beat|report)[[:space:]]*$' <<<"$text"; then
    out=done; why="answered; no SAY: beat or report line, nothing for the operator"
  else
    rc=0; HARNESS="$r" "$r/bin/archie-tg-send.sh" "$key" "$text" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then out=done; why="answered; sent to the operator"
    else out=failed; why="answered; archie-tg-send.sh rc=$rc"; fi
  fi
  afq_close watch-session "$out" "" "$why" "$ev" \
    || afw_log "session $key: the outcome ($out) could not be written; the row stays started"
  afw_log "session $key ($reason): $out ($why)"
  AFM_ROW=""
  return 0
}
