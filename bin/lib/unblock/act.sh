#!/bin/bash
# shellcheck shell=bash
# gh-identity: app-token
# bin/lib/unblock/act.sh — the unblock lane's ONE writer (BH-7726, UNB-4).
# Sourced by the lane tick, never run; nothing here runs on source.
#
#   ub_act <decision-record-json>
#     Takes one claimed, decided decision record. Applies every refusal gate,
#     then writes (act mode) or logs WOULD_<ACTION> (shadow). It never writes
#     the ledger row: the tick that claimed the decision records the outcome.
#
# INPUT, one JSON object:
#   {decision_key, project, repo, subject_kind, subject, pr, head, rule_id,
#    class, cites, action: {name, args}}
#   decision_key [A-Za-z0-9._:-]{1,128}; project [a-z0-9._-]+. A PR action
#   (post_block post_findings requeue queue_approve dismiss_review fix_round
#   lead_rerequest) also needs repo <owner>/<name>, pr > 0, head (40 hex).
#   action.args, per action:
#     post_block, post_findings  {lines: [non-empty strings]}
#     requeue                    {}
#     queue_approve              {verdict: MERGE|MERGE-WITH-NOTES}
#     dismiss_review             {review_id}
#     fix_round                  {brief, ticket?}
#     lead_rerequest             {request_id, priority, notes?}; request_id
#                                "none" = no reset, one new request (BH-8390)
#     launch_fastpath            {key} (BH-8390; not a PR action)
#     box_restart                {box_id, account?}
#     setting_set                {key, value, old, min, max, why}
#     send_card                  {card_id, text}
#
# OUTPUT: one stdout line `<outcome>\t<detail>`, and UB_ACT_OUTCOME and
#   UB_ACT_DETAIL set in the caller's shell (so call it in the caller's shell,
#   never inside $( )). Outcomes: would, done, failed, refused.
#   rc 0 = handled (any outcome). rc 1 = bad input: nothing read, nothing
#   written, both variables empty.
#   refused = a policy stop (never-auto, no opt-in, head moved, allowlist ...).
#   failed  = a read or a write that did not answer; the detail names it and,
#             for a sequence, the steps already done.
#   done    = only after the side effect answered rc 0.
#
# GATES, in this order, before any write:
#   1. never-auto class (spend production live-probe client-board merge deploy
#      governance) or never-auto action (merge force_push deploy pause_project)
#      -> refused, plus one warn alert id unblock-never-<key12>.
#   2. an action name not in the list above -> refused unknown-action.
#   3. the row unblock.project.<p>.mode (jobs-client.sh setting-get, trimmed):
#      absent, `off` or any other word -> refused no-opt-in; unreadable ->
#      failed; `shadow`, or `act` with UNBLOCK_ACT not 1 -> would; `act` with
#      UNBLOCK_ACT=1 -> act.
#   4. post_block and queue_approve: lead-verdict.sh must list `agent` in its
#      --source set, else refused verdict-source-agent-unavailable.
#   5. a PR action: the PR head is re-read (it must equal the record's head),
#      then the issue comments and the reviews are searched for the marker
#      <!-- tackler:<decision_key> -->. Found -> done marker-found.
#
# Every GitHub comment, review body and dismissal message carries the marker.
# Every verdict row is --source agent --reviewer tackler:<key12>.
# Log: one line per call in $HARNESS/logs/unblock.log:
#   <UTC> act <project> <subject> <rule_id> <action> <outcome> <detail>
#   (shadow: the action field reads WOULD_<ACTION_UPPER>).
#
# The caller loads what an arm needs and act.sh checks it before any write:
#   requeue, post_block   mc_requeue_mergify mc_requeued_mark mc_requeued_record
#                         / mc_dequeue_label (bin/lib/mc/*)
#   queue_approve         mc_enqueue_mergify
#   fix_round             fix_round_enqueue (bin/lib/fix-round-queue.sh)
#   setting_set           _jobs_req (bin/lib/jobs/req.sh), for the row's actor
#   every PR action       gh_auth_for / gh_auth_reset (bin/lib/gh-app-auth.sh):
#                         when loaded, the App token is armed before the first
#                         gh call and reset after the last one
#
# Knobs (env; the lane registers them, the code default is the fallback):
#   UNBLOCK_ACT  0   1 = act where the project's mode row says act
#   UB_NOW       -   epoch seconds, the clock seam for tests
#   UNBLOCK_FASTPATH_TIMEOUT_S 300  the wall-clock bound on launch_fastpath
#   UNBLOCK_NOTES_MAX_CHARS    300  the longest lead_rerequest notes accepted
#   UNBLOCK_DECLINE_MAX_CHARS  200  the decline reason kept in the detail
# Rows: unblock.project.<p>.mode; unblock.knob_allowlist (comma list, `*`
#   matches one dot-free segment). Absent -> the code list below. A key under
#   unblock.* or lane.unblock.* is refused whatever the row says.
#
# Hard limits at the writer: one box restart per box per hour (a stamp file
# under $HARNESS/state/unblock/, written BEFORE the restart); one tackler
# change per knob per 24 h (the settings row's own actor and updated_at).
#
# NO ROOT DEFAULT (D43): the root is $HARNESS, then $H; with neither ub_act
# returns 1 and builds no path.
#
# gh-rest: no-graphql

UB_NEVER_CLASSES="spend production live-probe client-board merge deploy governance"
UB_NEVER_ACTIONS="merge force_push deploy pause_project"
UB_ACTIONS="post_block post_findings requeue queue_approve dismiss_review fix_round lead_rerequest box_restart setting_set send_card launch_fastpath"
UB_PR_ACTIONS="post_block post_findings requeue queue_approve dismiss_review fix_round lead_rerequest"
UB_KNOB_ALLOWLIST_DEFAULT="lane.fly-pool-tick.pool_tick_max_parallel,hub_load.shed,lane.fly-pool.*.pool_record_read,lane_placement.*,conductor_remote_spawn.*"
UB_MARKER_PAGES=5

_ub_root() { printf '%s' "${HARNESS:-${H:-}}"; }
# _ub_knob_int <value> <default> — a whole number from 1 to 999999, else the default.
_ub_knob_int() { if [[ ${1:-} =~ ^[1-9][0-9]{0,5}$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
_ub_now() { printf '%s' "${UB_NOW:-$(date -u +%s)}"; }
_ub_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

_ub_log() {
  local h; h=$(_ub_root)
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  echo "$(date -u -d "@$(_ub_now)" '+%Y-%m-%d %H:%M:%SZ') $*" >> "$h/logs/unblock.log" 2>/dev/null || true
}

# _ub_alert <lane-alert args…> — never fails the caller.
_ub_alert() { "$(_ub_root)/bin/lane-alert.sh" "$@" >/dev/null 2>&1 || true; }

# _ub_out <outcome> <detail> — set the result, log it, print it.
_ub_out() {
  UB_ACT_OUTCOME="$1" UB_ACT_DETAIL="$2"
  local a="$_UB_ACTION"
  [ "$1" = would ] && a="WOULD_$(printf '%s' "$_UB_ACTION" | tr '[:lower:]' '[:upper:]')"
  _ub_log "act $_UB_P $_UB_SUBJ $_UB_RULE $a $1 $2"
  printf '%s\t%s\n' "$1" "$2"
}

_ub_arg() { printf '%s' "$_UB_ARGS" | jq -r --arg f "$1" '.[$f] // "" | tostring'; }

# _ub_valid — rc 0 when the record is well formed. Reads nothing outside it.
_ub_valid() {
  local r="$1" f
  printf '%s' "$r" | jq -e 'type == "object" and (.action | type) == "object"' >/dev/null 2>&1 || return 1
  _UB_KEY=$(printf '%s' "$r" | jq -r '.decision_key // ""')
  _UB_P=$(printf '%s' "$r" | jq -r '.project // ""')
  _UB_ACTION=$(printf '%s' "$r" | jq -r '.action.name // ""')
  _UB_ARGS=$(printf '%s' "$r" | jq -c '.action.args // {} | if type == "object" then . else {} end')
  _UB_CLASS=$(printf '%s' "$r" | jq -r '.class // ""')
  _UB_RULE=$(printf '%s' "$r" | jq -r '.rule_id // "-"')
  _UB_SUBJ=$(printf '%s' "$r" | jq -r '.subject // "-"')
  _UB_SLUG=$(printf '%s' "$r" | jq -r '.repo // ""')
  _UB_PR=$(printf '%s' "$r" | jq -r '.pr // "" | tostring')
  _UB_HEAD=$(printf '%s' "$r" | jq -r '.head // ""')
  [[ "$_UB_KEY" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || return 1
  [[ "$_UB_P" =~ ^[a-z0-9._-]+$ ]] || return 1
  [[ "$_UB_ACTION" =~ ^[a-z_]+$ ]] || return 1
  _UB_RULE=$(printf '%s' "$_UB_RULE" | tr -c 'A-Za-z0-9._:-' '_')
  _UB_SUBJ=$(printf '%s' "$_UB_SUBJ" | tr -c 'A-Za-z0-9._:#/-' '_')
  _UB_K12="${_UB_KEY:0:12}"
  if _ub_in "$_UB_ACTION" "$UB_PR_ACTIONS"; then
    [[ "$_UB_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    [[ "$_UB_PR" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$_UB_HEAD" =~ ^[0-9a-f]{40}$ ]] || return 1
    _UB_URL="https://github.com/$_UB_SLUG/pull/$_UB_PR"
  fi
  case "$_UB_ACTION" in
    post_block|post_findings)
      printf '%s' "$_UB_ARGS" | jq -e '(.lines | type) == "array" and (.lines | length) > 0
        and all(.lines[]; type == "string" and length > 0)' >/dev/null 2>&1 || return 1 ;;
    queue_approve) case "$(_ub_arg verdict)" in MERGE|MERGE-WITH-NOTES) ;; *) return 1 ;; esac ;;
    dismiss_review) [[ "$(_ub_arg review_id)" =~ ^[1-9][0-9]*$ ]] || return 1 ;;
    lead_rerequest)
      [[ "$(_ub_arg request_id)" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
      [[ "$(_ub_arg priority)" =~ ^[1-9][0-9]*$ ]] || return 1
      f=$(_ub_arg notes)
      [ "${#f}" -le "$(_ub_knob_int "${UNBLOCK_NOTES_MAX_CHARS:-}" 300)" ] && [[ "$f" != *$'\n'* ]] || return 1 ;;
    launch_fastpath)
      [[ "$(_ub_arg key)" =~ ^([A-Z][A-Z0-9]*-)?[0-9]+([.][0-9]+)?$ ]] || return 1 ;;
    box_restart)
      [[ "$(_ub_arg box_id)" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
      f=$(_ub_arg account); [ -z "$f" ] || [[ "$f" =~ ^[A-Za-z0-9._@-]+$ ]] || return 1 ;;
    setting_set)
      for f in key value old min max; do [ -n "$(_ub_arg "$f")" ] || return 1; done
      [[ "$(_ub_arg key)" =~ ^[a-z0-9_.-]{1,64}$ ]] || [[ "$(_ub_arg key)" =~ ^[A-Z0-9_]{1,64}$ ]] || return 1 ;;
    send_card) [[ "$(_ub_arg card_id)" =~ ^[A-Za-z0-9._-]+$ ]] || return 1 ;;
  esac
  return 0
}

# _ub_mode — prints act | shadow | no-opt-in | unreadable.
_ub_mode() {
  local v rc
  v=$("$(_ub_root)/bin/jobs-client.sh" setting-get "unblock.project.$_UB_P.mode" 2>/dev/null); rc=$?
  [ "$rc" = 2 ] && { echo no-opt-in; return 0; }
  [ "$rc" = 0 ] || { echo unreadable; return 0; }
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in act|shadow) echo "$v" ;; *) echo no-opt-in ;; esac
}

# _ub_agent_source_ok — rc 0 when lead-verdict.sh's usage lists `agent` in
# its --source set. Until the worker slice accepts it, no verdict row is posted.
_ub_agent_source_ok() {
  local set
  set=$(grep -m1 -o '\[--source [a-z|-]*\]' "$(_ub_root)/bin/lead-verdict.sh" 2>/dev/null) || return 1
  set="${set#\[--source }"; set="${set%\]}"
  case "|$set|" in *"|agent|"*) return 0 ;; esac
  return 1
}

# _ub_marker_in <path> — search up to UB_MARKER_PAGES pages of a list for the
# marker. Prints found | absent | unreadable | truncated.
_ub_marker_in() {
  local path="$1" pg=1 body n
  while [ "$pg" -le "$UB_MARKER_PAGES" ]; do
    body=$(gh api "$path?per_page=100&page=$pg" 2>/dev/null) || { echo unreadable; return 0; }
    printf '%s' "$body" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo unreadable; return 0; }
    printf '%s' "$body" | jq -e --arg m "$_UB_MARKER" 'any(.[]; (.body // "") | contains($m))' >/dev/null 2>&1 \
      && { echo found; return 0; }
    n=$(printf '%s' "$body" | jq 'length')
    [ "$n" -lt 100 ] && { echo absent; return 0; }
    pg=$((pg + 1))
  done
  echo truncated
}

# _ub_pr_gates — the head gate, then the marker gate. rc 0 = go on and write;
# rc 1 = an outcome was already given.
_ub_pr_gates() {
  local cur s path
  cur=$(gh api "repos/$_UB_SLUG/pulls/$_UB_PR" 2>/dev/null | jq -r '.head.sha // ""' 2>/dev/null)
  [[ "$cur" =~ ^[0-9a-f]{40}$ ]] || { _ub_out failed head-unreadable; return 1; }
  [ "$cur" = "$_UB_HEAD" ] || { _ub_out refused head-moved; return 1; }
  for path in "repos/$_UB_SLUG/issues/$_UB_PR/comments" "repos/$_UB_SLUG/pulls/$_UB_PR/reviews"; do
    s=$(_ub_marker_in "$path")
    case "$s" in
      found) _ub_out done marker-found; return 1 ;;
      absent) ;;
      truncated) _ub_out failed marker-search-truncated; return 1 ;;
      *) _ub_out failed marker-unreadable; return 1 ;;
    esac
  done
  return 0
}

_ub_gh_reset() { command -v gh_auth_reset >/dev/null 2>&1 && { gh_auth_reset >/dev/null 2>&1 || true; }; return 0; }

# _ub_gh_write <method> <path> <json> — the body goes through a file, never argv.
_ub_gh_write() {
  local f rc
  f=$(mktemp "${TMPDIR:-/tmp}/ub-body.XXXXXX") || return 1
  printf '%s' "$3" > "$f"
  gh api -X "$1" "$2" --input "$f" >/dev/null 2>&1; rc=$?
  rm -f "$f"
  return "$rc"
}

_ub_body() {
  printf '%s' "$_UB_ARGS" | jq -r --arg r "$_UB_RULE" --arg m "$_UB_MARKER" \
    '"Unblock rule \($r):\n\n" + (.lines | join("\n")) + "\n\n" + $m'
}

# _ub_post_review <with-verdict 0|1> — post_block and post_findings.
_ub_post_review() {
  local body done_="" rc
  body=$(_ub_body)
  _ub_gh_write POST "repos/$_UB_SLUG/issues/$_UB_PR/comments" "$(jq -nc --arg b "$body" '{body: $b}')" \
    || { _ub_out failed comment-failed; return 0; }
  done_=comment
  _ub_gh_write POST "repos/$_UB_SLUG/pulls/$_UB_PR/reviews" \
    "$(jq -nc --arg b "$body" --arg h "$_UB_HEAD" '{commit_id: $h, event: "REQUEST_CHANGES", body: $b}')" \
    || { _ub_out failed "review-failed after $done_"; return 0; }
  done_="$done_,review"
  [ "$1" = 1 ] || { _ub_out done posted; return 0; }
  "$(_ub_root)/bin/lead-verdict.sh" post "$_UB_SLUG" "$_UB_PR" "$_UB_HEAD" BLOCK \
    --source agent --reviewer "tackler:$_UB_K12" --note "$_UB_RULE" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) ;;
    3) _ub_out refused "head-moved after $done_"; return 0 ;;
    *) _ub_out failed "verdict-failed rc $rc after $done_"; return 0 ;;
  esac
  mc_dequeue_label "$_UB_URL" >/dev/null 2>&1
  _ub_out done posted
}

_ub_requeue() {
  local out rc
  if [ -n "$(mc_requeued_mark "$_UB_SLUG#$_UB_PR" "$_UB_HEAD" 2>/dev/null)" ]; then
    _ub_out done already-requeued; return 0
  fi
  mc_requeued_record "$_UB_SLUG#$_UB_PR" "$_UB_HEAD" >/dev/null 2>&1 \
    || { _ub_out failed requeued-mark-unwritable; return 0; }
  out=$(mc_requeue_mergify "$_UB_SLUG" "$_UB_URL" "$_UB_HEAD" 2>/dev/null); rc=$?
  case "$rc" in
    0) _ub_out done requeued ;;
    2) _ub_out done merged-meanwhile ;;
    3) _ub_out failed requeue-unacknowledged ;;
    4) _ub_out refused human-verdict-required ;;
    *) out="${out%%$'\n'*}"; _ub_out failed "requeue rc $rc: ${out//$'\t'/ }" ;;
  esac
}

_ub_queue_approve() {
  local v rc h
  v=$(_ub_arg verdict); h=$(_ub_root)
  "$h/bin/lead-verdict.sh" post "$_UB_SLUG" "$_UB_PR" "$_UB_HEAD" "$v" \
    --source agent --reviewer "tackler:$_UB_K12" --note "$_UB_RULE" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) ;;
    3) _ub_out refused head-moved; return 0 ;;
    *) _ub_out failed "verdict-failed rc $rc"; return 0 ;;
  esac
  mc_enqueue_mergify "$_UB_SLUG" "$_UB_URL" "$_UB_HEAD" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) echo "$(date -u -d "@$(_ub_now)" '+%Y-%m-%d %H:%M:%SZ') $_UB_URL ${_UB_HEAD:0:12} queued under the operator standing approval by tackler, decision $_UB_KEY rule $_UB_RULE" \
         >> "$h/logs/merge-conductor-backstop.log" 2>/dev/null
       _ub_out done queued ;;
    2) _ub_out done merged-meanwhile ;;
    4) _ub_out refused "human-verdict-required after verdict" ;;
    *) _ub_out failed "enqueue rc $rc after verdict" ;;
  esac
}

_ub_dismiss() {
  local id cid msg
  id=$(_ub_arg review_id)
  cid=$(gh api "repos/$_UB_SLUG/pulls/$_UB_PR/reviews/$id" 2>/dev/null | jq -r '.commit_id // ""' 2>/dev/null)
  [ -n "$cid" ] || { _ub_out failed review-unreadable; return 0; }
  [ "$cid" = "$_UB_HEAD" ] && { _ub_out refused review-binds-head; return 0; }
  msg="Dismissed by the unblock lane (rule $_UB_RULE): this review was on ${cid:0:12}, the head is now ${_UB_HEAD:0:12}. $_UB_MARKER"
  _ub_gh_write PUT "repos/$_UB_SLUG/pulls/$_UB_PR/reviews/$id/dismissals" \
    "$(jq -nc --arg m "$msg" '{message: $m, event: "DISMISS"}')" \
    || { _ub_out failed dismiss-failed; return 0; }
  _ub_out done dismissed
}

_ub_fix_round() {
  local h box rec out
  h=$(_ub_root)
  box=$("$h/bin/box-for.sh" "$_UB_P" 2>/dev/null)
  if [ -z "$box" ] || [ "$box" = local ] || { declare -F is_hub_box >/dev/null && is_hub_box "$box"; }; then
    _ub_out failed no-box; return 0
  fi
  rec=$(printf '%s' "$_UB_ARGS" | jq -c --arg k "$_UB_KEY" --arg pr "$_UB_PR" --arg head "$_UB_HEAD" \
    --arg r "$_UB_RULE" --arg c "$_UB_CLASS" \
    '{unblock: {decision_key: $k, pr: ($pr | tonumber), head: $head, rule_id: $r, class: $c, brief: (.brief // "")}}')
  if out=$(fix_round_enqueue "$_UB_P" "unblock-$_UB_PR-${_UB_HEAD:0:12}-$_UB_RULE" "$box" 0 "$rec" \
             "$_UB_P" "unblock-$_UB_PR-${_UB_HEAD:0:12}" unblock "$_UB_URL" - "$(_ub_arg ticket | grep . || echo -)" 2>/dev/null); then
    if printf '%s' "$out" | jq -e '.duplicate == true' >/dev/null 2>&1; then _ub_out done duplicate
    else _ub_out done "queued $(printf '%s' "$out" | jq -r '.id // "-"' 2>/dev/null)"; fi
  else
    _ub_out failed fix-round-enqueue-failed
  fi
}

# request_id "none" (BH-8390, U13-RESTAMP): the head has no request row, so
# there is nothing to reset; only the request goes out. notes, when set, go
# out as --notes.
# After a reset the request answers 409 (UNIQUE repo, pr, head_sha), so the
# notes do not reach a reset row yet: follow-up #8512 (reset --notes).
_ub_lead_rerequest() {
  local lv rc err rid notes after="after reset"
  local -a extra=()
  lv="$(_ub_root)/bin/lead-verdict.sh"
  rid=$(_ub_arg request_id); notes=$(_ub_arg notes)
  [ -n "$notes" ] && extra=(--notes "$notes")
  if [ "$rid" = none ]; then
    after="with no reset"
  else
    "$lv" reset "$rid" >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ] || { _ub_out failed "reset rc $rc"; return 0; }
  fi
  err=$("$lv" request "$_UB_SLUG" "$_UB_PR" "$_UB_HEAD" --priority "$(_ub_arg priority)" "${extra[@]+"${extra[@]}"}" 2>&1 >/dev/null); rc=$?
  if [ "$rc" = 0 ]; then _ub_out done requested
  elif grep -q 'HTTP 409' <<<"$err"; then _ub_out done already-requested
  else _ub_out failed "request rc $rc $after"
  fi
}

# launch_fastpath (BH-8390, U13-STARVE): bin/launch-fastpath.sh <project>
# <key>. It is deterministic, takes its own launch lock and declines anything
# it is not sure of (a blocker open, an owner, a hold). rc 0 = launched; a
# decline is `refused` with its FASTPATH-DECLINED reason from logs/<p>.log.
_ub_launch_fastpath() {
  local h key out rc why
  h=$(_ub_root); key=$(_ub_arg key)
  [ -x "$h/bin/launch-fastpath.sh" ] || { _ub_out failed fastpath-missing; return 0; }
  out=$(timeout "$(_ub_knob_int "${UNBLOCK_FASTPATH_TIMEOUT_S:-}" 300)" "$h/bin/launch-fastpath.sh" "$_UB_P" "$key" 2>/dev/null); rc=$?
  if [ "$rc" = 0 ]; then _ub_out done launched; return 0; fi
  # The script's contract: exit 1, the declined key AS GIVEN on stdout, and
  # one `FASTPATH-DECLINED <KEY> :: <reason>` line in logs/<p>.log; in
  # dispatch mode hotfix-only there is no per-key line, only one
  # `DISPATCH-MODE hotfix-only: ... (<KEYS>)` line for the run.
  if [ "$rc" = 1 ] && grep -qxF -- "$key" <<<"$out"; then
    why=$(grep -F -e "FASTPATH-DECLINED $key " -e "DISPATCH-MODE hotfix-only:" "$h/logs/$_UB_P.log" 2>/dev/null | tail -n 1 \
      | sed -e 's/^.*FASTPATH-DECLINED [^ ]* :: //' -e 's/^.*\(DISPATCH-MODE hotfix-only\).*$/\1/' \
      | tr -c 'A-Za-z0-9 ._:/#=-' ' ' | cut -c1-"$(_ub_knob_int "${UNBLOCK_DECLINE_MAX_CHARS:-}" 200)" | sed 's/ *$//')
    _ub_out refused "declined: ${why:-no reason logged}"; return 0
  fi
  _ub_out failed "fastpath rc $rc"
}

_ub_box_restart() {
  local h id acct stamp last now rc
  h=$(_ub_root); id=$(_ub_arg box_id); acct=$(_ub_arg account); now=$(_ub_now)
  stamp="$h/state/unblock/restart-$id.at"
  last=$(cat "$stamp" 2>/dev/null)
  if [[ "$last" =~ ^[0-9]+$ ]] && [ $((now - last)) -lt 3600 ]; then
    _ub_out refused restart-within-hour; return 0
  fi
  mkdir -p "$h/state/unblock" && printf '%s\n' "$now" > "$stamp" \
    || { _ub_out failed restart-stamp-unwritable; return 0; }
  if [ -n "$acct" ]; then timeout 600 "$h/bin/box-ops.sh" restart "$id" --account "$acct" --apply >/dev/null 2>&1; rc=$?
  else timeout 600 "$h/bin/box-ops.sh" restart "$id" --apply >/dev/null 2>&1; rc=$?
  fi
  _ub_alert --critical --severity critical --id "unblock-restart-$id" unblock \
    "unblock restarted box $id (box-ops rc $rc), decision $_UB_KEY, rule $_UB_RULE."
  if [ "$rc" = 0 ]; then _ub_out done restarted; else _ub_out failed "box-ops rc $rc"; fi
}

# _ub_knob_allowed <key> <comma-list> — `*` matches one dot-free segment.
_ub_knob_allowed() {
  local key="$1" pat re
  case "$key" in unblock.*|lane.unblock.*) return 1 ;; esac
  local IFS=,
  for pat in $2; do
    pat=$(printf '%s' "$pat" | tr -d '[:space:]')
    [ -n "$pat" ] || continue
    re=$(printf '%s' "$pat" | sed -e 's/[][\\.^$+?(){}|]/\\&/g' -e 's/\*/[^.]+/g')
    [[ "$key" =~ ^${re}$ ]] && return 0
  done
  return 1
}

_ub_setting_set() {
  local h key value old mn mx why list rc row actor at t
  h=$(_ub_root)
  key=$(_ub_arg key); value=$(_ub_arg value); old=$(_ub_arg old)
  mn=$(_ub_arg min); mx=$(_ub_arg max); why=$(_ub_arg why)
  list=$("$h/bin/jobs-client.sh" setting-get unblock.knob_allowlist 2>/dev/null); rc=$?
  case "$rc" in
    0) ;;
    2) list="$UB_KNOB_ALLOWLIST_DEFAULT" ;;
    *) _ub_out failed allowlist-unreadable; return 0 ;;
  esac
  _ub_knob_allowed "$key" "$list" || { _ub_out refused knob-not-allowed; return 0; }
  local num='^-?[0-9]+([.][0-9]+)?$'
  if ! [[ "$value" =~ $num && "$mn" =~ $num && "$mx" =~ $num ]] \
     || ! awk -v v="$value" -v a="$mn" -v b="$mx" 'BEGIN { exit !(v + 0 >= a + 0 && v + 0 <= b + 0) }'; then
    _ub_out refused out-of-range; return 0
  fi
  declare -F _jobs_req >/dev/null || { _ub_out failed jobs-libs-not-loaded; return 0; }
  row=$(_jobs_req GET "/api/settings/$key" 2>/dev/null) || { _ub_out failed setting-row-unreadable; return 0; }
  printf '%s' "$row" | jq -e 'type == "object"' >/dev/null 2>&1 || { _ub_out failed setting-row-unreadable; return 0; }
  actor=$(printf '%s' "$row" | jq -r '.setting.actor // ""')
  at=$(printf '%s' "$row" | jq -r '.setting.updated_at // ""')
  if [ "${actor#tackler:}" != "$actor" ]; then
    [ -n "$at" ] || { _ub_out failed setting-row-unreadable; return 0; }
    t=$(date -u -d "$at" +%s 2>/dev/null) || { _ub_out failed setting-row-unreadable; return 0; }
    [ $(( $(_ub_now) - t )) -lt 86400 ] && { _ub_out refused knob-changed-today; return 0; }
  fi
  JOBS_BOX="tackler:$_UB_K12" "$h/bin/jobs-client.sh" setting-set "$key" "$value" \
    "${why:-unblock rule $_UB_RULE}; roll back by setting $old" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ]; then _ub_out done set; else _ub_out failed "setting-set rc $rc"; fi
}

_ub_send_card() {
  local text n
  text=$(_ub_arg text); n=${#text}
  if [ "$n" -eq 0 ] || [ "$n" -gt 900 ]; then _ub_out failed card-invalid; return 0; fi
  "$(_ub_root)/bin/lane-alert.sh" --critical --severity critical --id "unblock-$(_ub_arg card_id)" unblock "$text" >/dev/null 2>&1
  _ub_out done sent
}

ub_act() {
  UB_ACT_OUTCOME="" UB_ACT_DETAIL=""
  local h mode w
  h=$(_ub_root)
  [ -n "$h" ] || return 1
  [ "$#" -eq 1 ] || return 1
  _ub_valid "$1" || return 1
  _UB_MARKER="<!-- tackler:$_UB_KEY -->"

  # 1. never-auto
  for w in "$_UB_CLASS" "$_UB_ACTION"; do
    if _ub_in "$w" "$UB_NEVER_CLASSES $UB_NEVER_ACTIONS"; then
      _ub_alert --severity warn --id "unblock-never-$_UB_K12" unblock \
        "unblock refused a never-auto decision ($w) for $_UB_SUBJ, rule $_UB_RULE, decision $_UB_KEY. Nothing was written."
      _ub_out refused "never-auto:$w"; return 0
    fi
  done
  # 2. unknown action
  _ub_in "$_UB_ACTION" "$UB_ACTIONS" || { _ub_out refused unknown-action; return 0; }
  # 3. mode
  mode=$(_ub_mode)
  case "$mode" in
    no-opt-in) _ub_out refused no-opt-in; return 0 ;;
    unreadable) _ub_out failed mode-unreadable; return 0 ;;
  esac
  if [ "$mode" != act ] || [ "${UNBLOCK_ACT:-0}" != 1 ]; then
    _ub_out would "WOULD_$(printf '%s' "$_UB_ACTION" | tr '[:lower:]' '[:upper:]')"; return 0
  fi
  # the caller's libs, checked before any read or write
  case "$_UB_ACTION" in
    requeue)
      for w in mc_requeue_mergify mc_requeued_mark mc_requeued_record; do
        declare -F "$w" >/dev/null || { _ub_out failed conductor-libs-not-loaded; return 0; }
      done ;;
    post_block) declare -F mc_dequeue_label >/dev/null || { _ub_out failed conductor-libs-not-loaded; return 0; } ;;
    queue_approve) declare -F mc_enqueue_mergify >/dev/null || { _ub_out failed conductor-libs-not-loaded; return 0; } ;;
    fix_round) declare -F fix_round_enqueue >/dev/null || { _ub_out failed fix-round-libs-not-loaded; return 0; } ;;
  esac
  # 4. the verdict source
  case "$_UB_ACTION" in
    post_block|queue_approve)
      _ub_agent_source_ok || { _ub_out refused verdict-source-agent-unavailable; return 0; } ;;
  esac
  # 5. head and marker, under the App identity when the caller loaded it
  if _ub_in "$_UB_ACTION" "$UB_PR_ACTIONS"; then
    command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$_UB_SLUG" >/dev/null 2>&1 || true; }
    _ub_pr_gates || { _ub_gh_reset; return 0; }
  fi
  case "$_UB_ACTION" in
    post_block)     _ub_post_review 1 ;;
    post_findings)  _ub_post_review 0 ;;
    requeue)        _ub_requeue ;;
    queue_approve)  _ub_queue_approve ;;
    dismiss_review) _ub_dismiss ;;
    fix_round)      _ub_fix_round ;;
    lead_rerequest) _ub_lead_rerequest ;;
    box_restart)    _ub_box_restart ;;
    setting_set)    _ub_setting_set ;;
    send_card)      _ub_send_card ;;
    launch_fastpath) _ub_launch_fastpath ;;
  esac
  _ub_in "$_UB_ACTION" "$UB_PR_ACTIONS" && _ub_gh_reset
  return 0
}
