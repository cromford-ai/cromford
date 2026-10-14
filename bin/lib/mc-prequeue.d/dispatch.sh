#!/bin/bash
# gh-identity: app-token
# bin/lib/mc-prequeue.d/dispatch.sh — the pre-queue gate's resolver (BH-4548,
# #4545 child 2). Sourced by bin/lib/mc-prequeue.sh's hook loop, never executed.
#
# pq_resolve is the tracer's hook: on a miss or a pending entry for (PR, head,
# main) it dispatches .github/workflows/prequeue-gate.yml on the repo, and on a
# later tick reads that run's ONE prequeue-verdict annotation back into the
# cache. Its LAST stdout line is its word: proceed, hold, or red (with
# PQ_SUITES and PQ_MAIN set).
#
# Only a run that concluded success AND carries exactly one annotation that
# parses with PQ_VERDICT_RE AND names this head and this main becomes a verdict.
# Everything else is could-not-run: written with `alerted` in one atomic write,
# then one warn alert, then proceed. The tracer never asks the hook again about
# a could-not-run key, so the alert fires once per (head, main).
#
# A repo without the workflow proceeds silently (one probe per repo per tick).
# The root is MC_H; without it nothing is written and the answer is proceed.
#
# MAIN MOVED (BH-5572, knob MC_PREQUEUE_REUSE, default 1). On a miss, a
# verdict on the same (PR, head) for an older main still counts while it is
# younger than MC_PREQUEUE_FRESH_S, aged from when the conductor READ it (the
# file's mtime: pq_settle writes a terminal entry once). A red parks. Any other
# word counts only if the head still merges into main (pq_merge_test): clean
# proceeds, a conflict answers rebase, no answer falls back to the 0 rule. A
# head the conductor will refuse this tick anyway (pq_dispatch_veto) is not
# dispatched: the answer is defer. One PREQUEUE log line per decision.
# 0 = the rule before BH-5572: verdicts aged from dispatch, no merge test, no
# veto.
#
# FRESH AGAINST MAIN (BH-6335, knob MC_PREQUEUE_FRESH_COMMITS, default 3). A
# non-red verdict for an OLDER main counts, under either rule above, only when
# that main is at most K commits behind the current main (pq_main_behind: one
# compare read per pair, none for the same sha). More than K, a diverged pair,
# or a compare that cannot be read: the candidate is skipped with one
# `PREQUEUE reuse ... -> stale-commits behind=<n|unreadable> k=<K>` line, and
# with no other candidate the head is dispatched again and held. A red parks at
# any distance, as before.

PQ_WF=prequeue-gate.yml
PQ_VERDICT_RE='^(green|red|no-selection|conflict|could-not-run) main=([0-9a-f]{40}) head=([0-9a-f]{40}) suites=([^ ]*)( why=[^ ]+)?$'

# pq_run_title <num> <head> <main> — the workflow's run-name for that key.
pq_run_title() { printf 'prequeue pr=%s head=%s main=%s' "$1" "$2" "$3"; }

# pq_wf_present <slug> — sets _pq_wf to yes, no (404) or unknown (any other
#   failure, not memoised). The answer is memoised per tick in MC_TICK_DIR.
pq_wf_present() {
  local slug="$1" memo="" raw="" rc=0
  [ -n "${MC_TICK_ID:-}" ] && memo="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").pq-wf.${slug//\//_}"
  if [ -n "$memo" ] && [ -r "$memo" ]; then read -r _pq_wf < "$memo"; return 0; fi
  mc_rest_var raw gh_rest GET "repos/$slug/actions/workflows/$PQ_WF" || rc=$?
  case "$rc" in 0) _pq_wf=yes ;; 44) _pq_wf=no ;; *) _pq_wf=unknown; return 0 ;; esac
  [ -n "$memo" ] && mkdir -p "$MC_TICK_DIR" 2>/dev/null && printf '%s\n' "$_pq_wf" > "$memo" 2>/dev/null
  return 0
}

# pq_dispatch <slug> <num> <head> <main> [suites] [fp] — rc 0 dispatched, 3
#   someone else holds or already wrote this key, 4 the pending entry could not
#   be written (nothing dispatched), 1 the dispatch was refused (recorded
#   could-not-run, alerted). pending is on disk BEFORE the call. fp is the
#   pq_key suffix for a named-suites run (BH-4550), so it never lands on the
#   plain gate's key.
pq_dispatch() {
  local slug="$1" num="$2" head="$3" main="$4" suites="${5:-}" path lk now
  path=$(pq_key "$slug" "$num" "$head" "$main" "${6:-}"); now=$(date +%s)
  lk="$MC_H/locks/prequeue-${slug//\//_}-$num-$head.lock"
  mkdir -p "${lk%/*}" 2>/dev/null; { : >> "$lk"; } 2>/dev/null || return 4
  (
    flock -n 9 || exit 3
    [ -n "$(pq_cache_get "$path")" ] && exit 3
    pq_cache_put "$path" pending "$now" - "" || exit 4
    mc_use_token "$slug"
    args=(-f "pr=$num" -f "head=$head" -f "main=$main"); [ -n "$suites" ] && args+=(-f "suites=$suites")
    # shellcheck disable=SC2207
    [ -z "$suites" ] && declare -F pq_invariants_args >/dev/null && args+=($(pq_invariants_args))
    # shellcheck disable=SC2207
    [ -z "$suites" ] && declare -F pq_learned_args >/dev/null && args+=($(pq_learned_args))
    gh workflow run "$PQ_WF" -R "$slug" --ref main "${args[@]}" >/dev/null 2>&1 && exit 0
    pq_cache_put "$path" could-not-run "$now" dispatch-refused "" alerted
    exit 1
  ) 9>"$lk"
}

# pq_parse_verdict <message> <head> <main> — "<verdict> <suites|-> [why]" for a
#   message about exactly this key, else "could-not-run - <why>".
pq_parse_verdict() {
  local v su why
  [[ "$1" =~ $PQ_VERDICT_RE ]] || { echo "could-not-run - malformed"; return 0; }
  v="${BASH_REMATCH[1]}"; su="${BASH_REMATCH[4]}"; why="${BASH_REMATCH[5]# why=}"
  [ "${BASH_REMATCH[3]}" = "$2" ] || { echo "could-not-run - stale-head"; return 0; }
  [ "${BASH_REMATCH[2]}" = "$3" ] || { echo "could-not-run - stale-main"; return 0; }
  [ "$v" = red ] && [ -z "$su" ] && { echo "could-not-run - red-without-suites"; return 0; }
  echo "$v ${su:--}${why:+ $why}"
}

# pq_read_run <slug> <title> [<path>] — "<verdict> <run_id> <suites|-> [why]"
#   once the run titled exactly <title> completed; nothing while it has not (or
#   does not exist). rc 75 when a read failed. Given a cache path and a parsed
#   verdict, it also writes the invariant evidence next to it (BH-5439):
#   <path>.why (a red's why), <path>.fail (one `### <id>` block per
#   prequeue-invariant-fail message) and <path>.timing (the timing line, then
#   each slow line), and logs one PREQUEUE_INVARIANTS line per timing sidecar.
#   A sidecar that cannot be written is one log line; the verdict stands.
pq_read_run() {
  local slug="$1" t="$2" path="${3:-}" raw="" id st concl jid msgs='[]' n v
  local head main num why fail timing
  mc_rest_var raw gh_rest GET "repos/$slug/actions/workflows/$PQ_WF/runs?event=workflow_dispatch&per_page=30" || return 75
  read -r id st concl <<<"$(jq -r --arg t "$t" '[.workflow_runs[]? | select(.display_title == $t)]
    | sort_by(.created_at) | last // empty | "\(.id) \(.status) \(.conclusion // "-")"' <<<"$raw" 2>/dev/null)"
  [ -n "$id" ] && [ "$st" = completed ] || return 0
  [ "$concl" = success ] || { echo "could-not-run $id - $concl"; return 0; }
  mc_rest_var raw gh_rest GET "repos/$slug/actions/runs/$id/jobs" || return 75
  for jid in $(jq -r '.jobs[]?.id // empty' <<<"$raw" 2>/dev/null); do
    mc_rest_var raw gh_rest GET "repos/$slug/check-runs/$jid/annotations" || return 75
    msgs=$(jq -c --argjson a "$msgs" '$a + [.[]? | select(.title | IN("prequeue-verdict", "prequeue-invariant-timing",
      "prequeue-invariant-fail", "prequeue-invariant-slow")) | {title, message}]' <<<"$raw" 2>/dev/null) || return 75
  done
  n=$(jq '[.[] | select(.title == "prequeue-verdict")] | length' <<<"$msgs")
  [ "$n" = 1 ] || { echo "could-not-run $id - annotation-count-$n"; return 0; }
  head="${t#* head=}"; head="${head%% *}"; main="${t##* main=}"; num="${t#* pr=}"; num="${num%% *}"
  read -r st raw concl <<<"$(pq_parse_verdict "$(jq -r '.[] | select(.title == "prequeue-verdict") | .message' <<<"$msgs")" "$head" "$main")"
  if [ -n "$path" ] && [ "$st" != could-not-run ]; then
    why=""; [ "$st" = red ] && why="$concl"
    fail=$(jq -r '.[] | select(.title == "prequeue-invariant-fail") | .message
      | (index(": ") // -1) as $i | if $i < 0 then "### \(.)\n" else "### \(.[:$i])\n\(.[$i + 2:])\n" end' <<<"$msgs" 2>/dev/null)
    timing=$(jq -r '([.[] | select(.title == "prequeue-invariant-timing") | .message] | first // empty) as $t
      | if $t then ([$t] + [.[] | select(.title == "prequeue-invariant-slow") | .message]) | .[] else empty end' <<<"$msgs" 2>/dev/null)
    for v in why fail timing; do
      [ -n "${!v}" ] || continue
      printf '%s\n' "${!v}" > "$path.$v.tmp.$$" 2>/dev/null && mv -f "$path.$v.tmp.$$" "$path.$v" 2>/dev/null \
        || { rm -f "$path.$v.tmp.$$" 2>/dev/null; mc_log "$slug#$num prequeue: could not write the .$v sidecar for ${head:0:8} on main ${main:0:12}"; v=""; }
      [ "$v" = timing ] && mc_log "$slug#$num PREQUEUE_INVARIANTS head ${head:0:8} main ${main:0:12}: ${timing%%$'\n'*}"
    done
  fi
  echo "$st $id $raw${concl:+ $concl}"
}

# pq_alert <slug> <num> <url> <head> <main> <why> — the one warn alert for a
#   could-not-run key. Only ever called right after the write that set alerted.
pq_alert() {
  [ -x "$MC_H/bin/lane-alert.sh" ] || { mc_log "$1#$2 prequeue gate could-not-run ($6), no lane-alert.sh to say so"; return 0; }
  "$MC_H/bin/lane-alert.sh" --severity warn merge-conductor \
    "$1#$2 prequeue gate could-not-run on head ${4:0:12} main ${5:0:12} ($6): enqueued without it, the batch is the backstop: $3" >/dev/null 2>&1 || true
}

# pq_settle <slug> <num> <url> <head> <main> <path> <dispatched_at> — one
#   pending entry to its word, in _pq_word (red also sets PQ_SUITES, PQ_MAIN).
pq_settle() {
  local slug="$1" num="$2" url="$3" head="$4" main="$5" path="$6" at="$7" line="" v id su why
  _pq_word=hold
  line=$(pq_read_run "$slug" "$(pq_run_title "$num" "$head" "$main")" "$path")
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  if [ -z "$line" ]; then
    [ $(( $(date +%s) - at )) -lt "$(pq_knob MC_PREQUEUE_DEADLINE_S)" ] && return 0
    line="could-not-run - - deadline"
  fi
  read -r v id su why <<<"$line"
  [ "$su" = - ] && su=""
  _pq_word=proceed
  if [ "$v" = could-not-run ]; then
    why="${why:-unknown}"; [ "$id" != - ] && why="$why, run $id"
    if pq_cache_put "$path" could-not-run "$at" "${why%%,*}" "" alerted; then pq_alert "$slug" "$num" "$url" "$head" "$main" "$why"
    else mc_log "$slug#$num prequeue: could not record could-not-run for ${head:0:8} on main ${main:0:12} ($why)"; fi
    return 0
  fi
  pq_cache_put "$path" "$v" "$at" "$id" "$su" \
    || mc_log "$slug#$num prequeue: could not record $v for ${head:0:8} on main ${main:0:12}"
  [ "$v" = red ] && { PQ_SUITES="$su"; PQ_MAIN="$main"; _pq_word=red; }
  return 0
}

# pq_prune — at most once per tick: cache entries older than 7 days go.
pq_prune() {
  local m
  [ -n "${MC_TICK_ID:-}" ] && [ -n "${MC_TICK_DIR:-}" ] && [ -n "${MC_STATE_DIR:-}" ] || return 0
  mkdir -p "$MC_TICK_DIR" 2>/dev/null
  m="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").pq-pruned"
  ( set -C; : > "$m" ) 2>/dev/null || return 0
  [ -d "$MC_STATE_DIR/prequeue" ] && find "$MC_STATE_DIR/prequeue" -type f -mtime +7 -delete 2>/dev/null
  return 0
}

# pq_merge_test <slug> <num> <head> — rc 0 the head merges clean into main,
#   1 it conflicts (stdout: the paths), 2 this tick cannot tell (stdout: why).
#   mc_merge_tree fetches origin/main in this call, so the main it tests is the
#   one pq_gate read or a newer one, never an older one.
pq_merge_test() {
  local out rc=0
  [ "${MC_MERGE_TREE:-1}" != 0 ] || { printf 'merge test off, MC_MERGE_TREE=0'; return 2; }
  declare -F mc_merge_tree >/dev/null && declare -F mc_git_locked >/dev/null && [ -n "${P:-}" ] \
    || { printf 'no merge test in this shell'; return 2; }
  out=$(mc_git_locked "$P" mc_merge_tree "$1" "$P" "$3" "$2" 2>/dev/null) || rc=$?
  out=$(printf '%s' "$out" | tr '\n' ' '); out="${out% }"
  case "$rc" in
    0) return 0 ;;
    1) printf '%s' "$out"; return 1 ;;
    99) printf 'the git lock for %s was busy' "$P"; return 2 ;;
    *) printf '%s' "${out:-mc_merge_tree rc $rc}"; return 2 ;;
  esac
}

# pq_bg_issue — the issue the block gate reads beside the PR, by the READY
#   arm's own rule: only on an Issues board (fleet.conf board prefix `-`).
#   P, REC and BR are the READY arm's variables, read the way pq_knob reads P.
pq_bg_issue() {
  [ -n "${P:-}" ] && [ -n "${MC_H:-}" ] && declare -F mc_issue_of >/dev/null || return 0
  [ "$("$MC_H/bin/fleet-conf.sh" "$P" board_prefix 2>/dev/null)" = "-" ] || return 0
  mc_issue_of "${REC:-}" "${BR:-}"
}

# pq_dispatch_veto <slug> <num> <url> <head> — rc 0 and a reason on stdout
#   when a READY check after the gate will refuse this head this tick, so a
#   dispatch could never lead to an enqueue: a standing BLOCK, or a lead PR
#   with no lead MERGE row. A read that fails (rc 2) is no veto.
pq_dispatch_veto() {
  local rc=0
  if declare -F bg_scan_read >/dev/null && declare -F bg_enforce >/dev/null && bg_enforce; then
    ( bg_scan_read "$1" "$2" "$3" "$4" "$(pq_bg_issue)" ) >/dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ] && { printf 'standing BLOCK on the thread'; return 0; }
  fi
  rc=1
  if declare -F to_lead_merge_hold >/dev/null; then
    ( to_lead_merge_hold "$1" "$2" "$4" "" ) >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ] && { printf 'lead PR waiting on a lead MERGE row'; return 0; }
  fi
  return 1
}

# pq_main_behind <slug> <verdict-main> <main> — prints how many commits <main>
#   has that <verdict-main> lacks, and sets _pq_bn to it: 0 for the same sha
#   with no read, else one compare read (memoised per pair in _pq_behind for
#   this pq_resolve call, so call it in this shell, not in a $( )).
#   rc 1, nothing printed and _pq_bn empty when the read fails (rc 75 too), the
#   pair diverged or main is behind, or the answer is not a whole number.
pq_main_behind() {
  local slug="$1" vm="$2" m="$3" raw="" st n
  _pq_bn=""
  [ "$vm" = "$m" ] && { _pq_bn=0; echo 0; return 0; }
  # Outside pq_resolve there is no memo: a local one keeps the subscript a string.
  declare -p _pq_behind >/dev/null 2>&1 || local -A _pq_behind=()
  if [ -n "${_pq_behind[$vm.$m]+x}" ]; then n="${_pq_behind[$vm.$m]}"
  else
    n=""
    if mc_rest_var raw gh_rest GET "repos/$slug/compare/$vm...$m?per_page=1"; then
      read -r st n <<<"$(jq -r '"\(.status // "-") \(.ahead_by // "-")"' <<<"$raw" 2>/dev/null)"
      case "$st" in ahead|identical) ;; *) n="" ;; esac
      case "$n" in ''|*[!0-9]*) n="" ;; esac
    fi
    _pq_behind[$vm.$m]="$n"
  fi
  [ -n "$n" ] || return 1
  _pq_bn="$n"; echo "$n"
}

# pq_fresh_ok <slug> <num> <head> <verdict-main> <main> <age> <verdict> — rc 0
#   when a non-red candidate's main is at most MC_PREQUEUE_FRESH_COMMITS behind;
#   else one stale-commits log line and rc 1. A red is always rc 0. Inside
#   pq_resolve the answer is memoised per verdict main in _pq_fok, so the
#   dispatch-time and the read-time pass log a stale candidate once.
pq_fresh_ok() {
  local b k
  [ "$7" = red ] && return 0
  declare -p _pq_fok >/dev/null 2>&1 || local -A _pq_fok=()
  [ -n "${_pq_fok[$4]+x}" ] && return "${_pq_fok[$4]}"
  k=$(pq_knob MC_PREQUEUE_FRESH_COMMITS)
  if pq_main_behind "$1" "$4" "$5" >/dev/null && [ "$_pq_bn" -le "$k" ]; then _pq_fok[$4]=0; return 0; fi
  b="$_pq_bn"
  pq_reuse_log "$2" "$3" "$4" "$5" "$6" "$7" "stale-commits behind=${b:-unreadable} k=$k"
  _pq_fok[$4]=1
  return 1
}

# pq_reuse_log <num> <head> <verdict-main> <main> <age> <verdict> <outcome>
pq_reuse_log() {
  mc_log "PREQUEUE reuse #$1 head=${2:0:12} verdict-main=${3:0:12} current-main=${4:0:12} age=${5}s verdict=$6 -> $7"
}

# pq_resolve <slug> <num> <url> <head> <main> <path> — the tracer's hook.
pq_resolve() {
  local slug="$1" num="$2" url="$3" head="$4" main="$5" path="$6" pre f m st at rest now fresh
  local best="" bm="" bat=-1 sib="" keep_main="$PQ_MAIN" keep_suites="$PQ_SUITES"
  local reuse vt age rbest="" rbm="" rvt=-1 rage=0 mt mrc veto
  local -A _pq_behind=() _pq_fok=()
  [ -n "${MC_H:-}" ] && [ -n "${MC_STATE_DIR:-}" ] || { echo proceed; return 0; }
  pq_prune
  pq_wf_present "$slug"
  case "$_pq_wf" in
    no) echo proceed; return 0 ;;
    unknown) mc_log "$slug#$num prequeue: the $PQ_WF probe was unreadable, enqueued without the gate this tick"; echo proceed; return 0 ;;
  esac
  read -r st at _ <<<"$(pq_cache_get "$path")"
  if [ "$st" = pending ]; then pq_settle "$slug" "$num" "$url" "$head" "$main" "$path" "$at"; echo "$_pq_word"; return 0; fi
  # A miss. Settle this head's other pending entries first, then act on its
  # newest completed one inside FRESH_S, before paying for a new run.
  pre="${path%_*}_"
  for f in "$pre"*; do
    m="${f#"$pre"}"; [[ "$m" =~ ^[0-9a-f]{40}$ ]] && [ "$f" != "$path" ] || continue
    read -r st at _ <<<"$(pq_cache_get "$f")"
    [ "$st" = pending ] && pq_settle "$slug" "$num" "$url" "$head" "$m" "$f" "$at"
  done
  PQ_MAIN="$keep_main"; PQ_SUITES="$keep_suites"
  now=$(date +%s); fresh=$(pq_knob MC_PREQUEUE_FRESH_S); reuse=$(pq_knob MC_PREQUEUE_REUSE)
  # best: the newest verdict inside FRESH_S by dispatch time (the rule before
  # BH-5572). rbest: the newest inside FRESH_S by the time it was read (mtime).
  for f in "$pre"*; do
    m="${f#"$pre"}"; [[ "$m" =~ ^[0-9a-f]{40}$ ]] || continue
    read -r st at rest <<<"$(pq_cache_get "$f")"
    case "$at" in ''|*[!0-9]*) continue ;; esac
    # BH-6161: after a queue ejection, a verdict dispatched before it is not reused.
    [ "${PQ_MIN_AT:-0}" -gt 0 ] 2>/dev/null && [ "$at" -lt "$PQ_MIN_AT" ] && continue
    if [ $((now - at)) -lt "$fresh" ]; then
      case "$st" in
        pending) sib="$m" ;;
        green|red|no-selection|conflict|could-not-run)
          [ "$at" -gt "$bat" ] && pq_fresh_ok "$slug" "$num" "$head" "$m" "$main" "$((now - at))" "$st" \
            && { bat="$at"; best="$st $rest"; bm="$m"; } ;;
      esac
    fi
    [ "$reuse" != 0 ] || continue
    case "$st" in green|red|no-selection|conflict|could-not-run) ;; *) continue ;; esac
    vt=$(stat -c %Y "$f" 2>/dev/null); case "$vt" in ''|*[!0-9]*) continue ;; esac
    age=$((now - vt)); [ "$age" -ge 0 ] && [ "$age" -lt "$fresh" ] || continue
    [ "$vt" -gt "$rvt" ] && pq_fresh_ok "$slug" "$num" "$head" "$m" "$main" "$age" "$st" \
      && { rvt="$vt"; rbest="$st $rest"; rbm="$m"; rage="$age"; }
  done
  if [ -n "$rbest" ]; then
    read -r st _ rest <<<"$rbest"
    rest="${rest#alerted}"; rest="${rest# }"
    if [ "$st" = red ] && [ -n "$rest" ]; then
      pq_reuse_log "$num" "$head" "$rbm" "$main" "$rage" "$st" red
      # PQ_PATH is the entry the red was read from (BH-5438): sidecars go next to it.
      PQ_SUITES="$rest"; PQ_MAIN="$rbm"; PQ_PATH="$pre$rbm"; echo red; return 0
    fi
    mt=$(pq_merge_test "$slug" "$num" "$head"); mrc=$?
    case "$mrc" in
      0) pq_reuse_log "$num" "$head" "$rbm" "$main" "$rage" "$st" proceed; echo proceed; return 0 ;;
      1) PQ_WHY="head ${head:0:8} conflicts with main ${main:0:12}: ${mt:-paths not named}"
         pq_reuse_log "$num" "$head" "$rbm" "$main" "$rage" "$st" rebase; echo rebase; return 0 ;;
    esac
    # No answer: the dispatch-time rule below decides, as it did before.
    pq_reuse_log "$num" "$head" "$rbm" "$main" "$rage" "$st" "merge-test-unanswered ($mt)"
  fi
  if [ -n "$best" ]; then
    read -r st _ rest <<<"$best"
    rest="${rest#alerted}"; rest="${rest# }"
    [ "$st" = red ] && [ -n "$rest" ] && { PQ_SUITES="$rest"; PQ_MAIN="$bm"; PQ_PATH="$pre$bm"; echo red; return 0; }
    echo proceed; return 0
  fi
  if [ -n "$sib" ]; then
    PQ_WHY="prequeue run for main ${sib:0:12} still running; its verdict is read on a later tick"; echo hold; return 0
  fi
  # A run the conductor could never act on this tick is not paid for. Nothing
  # is written, so the first tick without the refusal dispatches as usual.
  if [ "$reuse" != 0 ] && veto=$(pq_dispatch_veto "$slug" "$num" "$url" "$head"); then
    mc_log "PREQUEUE skip-dispatch #$num head=${head:0:12} current-main=${main:0:12} reason=$veto"
    PQ_WHY="prequeue not dispatched: $veto"; echo defer; return 0
  fi
  pq_dispatch "$slug" "$num" "$head" "$main"
  case "$?" in
    0) PQ_WHY="$PQ_WF dispatched for main ${main:0:12}; its verdict is read on a later tick"; echo hold ;;
    3) PQ_WHY="prequeue dispatch for ${head:0:8} is in another worker's hands"; echo hold ;;
    1) pq_alert "$slug" "$num" "$url" "$head" "$main" dispatch-refused; echo proceed ;;
    *) pq_alert "$slug" "$num" "$url" "$head" "$main" cache-unwritable; echo proceed ;;
  esac
}
